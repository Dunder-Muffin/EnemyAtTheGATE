-- =======================================================================
-- AssetManager - async loading of game assets
-- 
-- Why this exists:
--   * LoadAsset() must run on the game thread or it will crash
--   * We need to be extremely careful with assets as UE can GC them
--   * Multiple callers may want the same asset while it is still loading;
--     they are parked in Waiters and all called back when it lands.
--
-- NOTE: the Cache is just a hint that an asset is likely to exist in memory.
--   * Cached entries are wrappers: the underlying asset can be GCed while
--     IsValid() on the stale wrapper still returns true.
--
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local Utils = require("AnteUtils.Utils")
local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local SCHEMA = require("AnteData.Schema")
local TAP = require("AnteCore.TestTap")

local ASSETS = {}
ASSETS.Cache = {}
ASSETS.Loading = {}
ASSETS.Waiters = {}

-- path -> true while AnteCore/AssetKeeper holds a live hard-ref component for it (same table as
-- the keeper's pinnedPaths, written/cleared there). A pinned asset can't GC, so its cached
-- wrapper is as trustable as a /Script/ class.
-- This matters because every StaticFindObject on this UE4SS build is a full UObject-array walk,
-- ~20-30ms flat even on a hit ([[anteup2-ue4ss-findobject-scan-crash]]). Trusting pinned paths
-- turns hot-path lookups (pipeline LoadAssets, Visuals re-resolves, attach helpers) into table
-- hits instead.
ASSETS.Pinned = {}

-- path -> true for objects the GAME hard-refs for the life of the world. Third trusted category
-- alongside /Script/ and Pinned, and the only one that covers a DataTable (no component UPROPERTY
-- can hold one, so it is unpinnable).
--
-- NOT the §3 timing bet. §3's "a preload does not stick" is true when WE are the only ref: GC
-- takes the asset the moment our batch ends. Here the ref is the GAME's, held by an always-loaded
-- class, so liveness isn't ours to maintain and there's no window to lose.
-- Each entry is therefore a VERIFIABLE CLAIM, not a guess - a wrong one is an AV, not a slow
-- lookup. Verify before adding, cite the evidence, keep the list short.
--
-- SAFETY RAILS:
--   * An entry is only POPULATED by a successful StaticFindObject - the first lookup per world
--     still walks and proves residency. We never fabricate a wrapper.
--   * ASSETS.ResetWorld (from Utils.ResetState) drops them on teardown. ASSETS.Cache is otherwise
--     never cleared, and a trusted entry surviving into the next world would be exactly the freed
--     cross-world pointer §3 exists to prevent.
ASSETS.Immortal = {
    -- Hard-refd by Abiotic_Item_Dropped_C's CDO defaults (ItemDataRow.DataTable, decompiled
    -- Abiotic_Item_Dropped.cpp:48 + :179), so it lives as long as that class does.
    ["/Game/Blueprints/Items/ItemTable_Global.ItemTable_Global"] = true,
    -- Hard-refd by Abiotic_PlayerCharacter_C, Abiotic_Survival_GameMode_C and NPC_Base_ParentBP_C
    -- (22 BPs baked the class ref); all three are loaded for the whole world.
    ["/Game/Blueprints/Items/Abiotic_Item_Dropped.Abiotic_Item_Dropped_C"] = true,
    -- BP function-library CDO. Its class is a baked import of essentially every BP in the game.
    ["/Game/Blueprints/Libraries/AbioticFunctionLibrary.Default__AbioticFunctionLibrary_C"] = true,
    -- The NPC parent class (ENUMS.BASE_PARENT_NPC), resolved by every AVU.GetNearbyNpcs. Hard-refd by
    -- Abiotic_Survival_GameMode_C and Abiotic_PlayerCharacter_C (Cast<> imports, and the player's typed
    -- `Companion` property) on both builds, and it is the super of every NPC class.
    ["/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C"] = true,
    -- Hard-refd by NPC_Base_ParentBP_C's CDO default GrenadeData.DataTable (decompiled
    -- NPC_Base_ParentBP.cpp:139), and NPC_Base is loaded for the whole world (see above).
    ["/Game/Blueprints/DataTables/DT_Projectiles.DT_Projectiles"] = true,
}

-- Both DataTable claims above rest on FDataTableRowHandle.DataTable pointers in class defaults, which
-- the native layout's typed handles don't have. There the evidence is the ENGINE row registry,
-- UABFRowRegistrySubsystem.BaseTables (a TArray<UDataTable*> UPROPERTY on an engine subsystem, alive
-- for the process): /au-schema listed ItemTable_Global in it, but NOT DT_Projectiles, which is also
-- cold at InitMod. So on native DT_Projectiles is untrusted and re-resolved per call.
if SCHEMA.Native then
    ASSETS.Immortal["/Game/Blueprints/DataTables/DT_Projectiles.DT_Projectiles"] = nil
end

-- path -> true once a load has resolved it in this world. Tells a reload (collected since its last
-- use, the GC tell) from a first resolve in the cold-load log. Reset per world.
ASSETS.Seen = {}

-- Since boot, for /pins. A probe MISS is a full UObject-array walk on every UE4SS build (on -1012 a
-- hit walks too), so Misses is the number SETTINGS.CORE.ASSET_PROBE exists to drive down.
--   * Resident = a loader trip that handed back the object it had last time: a probe skipped.
ASSETS.Stats = { Probes = 0, Misses = 0, Resident = 0, First = 0, Reloads = 0 }

-- [Utils.ResetState] Drop the TRUSTED cache entries on world teardown. Untrusted /Game/ paths need
-- no clearing - they re-resolve through StaticFindObject on every lookup and are self-correcting.
function ASSETS.ResetWorld()
    for path in pairs(ASSETS.Immortal) do ASSETS.Cache[path] = nil end
    ASSETS.Seen = {}
end

-- The by-path lookup: the live object or nil. Bare on purpose - see the pcall count in
-- [[anteup2-ue4ss-findobject-scan-crash]] forensics.
local function probe(path)
    Utils.Crumb("sfo:" .. path)   -- past the free paths: this is the UObject-array walk
    Utils.TraceLookup(path)
    local S = ASSETS.Stats
    S.Probes = S.Probes + 1
    local obj = StaticFindObject(path)
    if obj and IsValid(obj) then return obj end
    S.Misses = S.Misses + 1
    return nil
end

function ASSETS.StatsLine()
    local S = ASSETS.Stats
    local mode = SETTINGS.CORE and SETTINGS.CORE.ASSET_PROBE or "never"
    return string.format("ASSETS - probe mode %s: %d probes, %d missed (walks) | loader: %d resident, "
        .. "%d first resolves, %d reloads", tostring(mode), S.Probes, S.Misses, S.Resident, S.First, S.Reloads)
end


-- =======================================================================
-- Resolve a loaded object by path. Returns nil rather than triggering a load.
--
-- Only /Script/, Pinned and Immortal cache entries are trustable. A cached /Game/ asset
-- (UNiagaraSystem, USkeletalMesh, UStaticMesh, ...) can be GCed after caching, and IsValid() on
-- the stale wrapper can still return true. Handing that wrapper to a setter reads a garbage
-- param: an AV in Niagara's SetAsset (FNiagaraParameterStore, uncatchable by pcall), or a garbage
-- bone count in SetSkeletalMeshAsset -> SkinnedMeshComponent::AllocateTransformData -> OOM alloc.
--
-- StaticFindObject is authoritative: it returns the live object by path, or nil, never a freed
-- pointer. /Game/ assets are re-resolved this way every call, falling back to the cache on miss.
--
-- ALWAYS COME THROUGH HERE - never call bare StaticFindObject for a /Script/ path.
--   * On this UE4SS build every StaticFindObject is a full UObject-array WALK (~20-30ms even when
--     resident), and each walk risks tripping a dangling Outer and AV-ing
--     ([[anteup2-ue4ss-findobject-scan-crash]]).
--   * /Script/ CDOs and native classes never GC, so the fast-path below trusts the cache outright:
--     first call walks, every later call is a table read. A bare repeated StaticFindObject on a
--     /Script/ path re-walks forever for no reason.
--   * Same result, same nil-on-miss as a bare call - this is a pure drop-in.
-- =======================================================================

function ASSETS.GetIfValid(path)
    -- A nil path is a caller naming an ENUMS key that doesn't exist - almost always a new entry
    -- after a /reload, which never re-runs Enums. Bare StaticFindObject THROWS on it, so swallow it
    -- here and let the caller take its normal miss path.
    if type(path) ~= "string" then return nil end

    local cached = ASSETS.Cache[path]

    -- Native classes, KEEPER-pinned assets and game-owned immortals - trust these, they can't be
    -- GCed (pinned = a live component hard-refs the asset; immortal = the GAME hard-refs it).
    -- See ASSETS.Pinned / ASSETS.Immortal above.
    if cached and IsValid(cached)
        and (ASSETS.Pinned[path] or ASSETS.Immortal[path] or path:sub(1, 8) == "/Script/") then
        return cached
    end

    -- In cache, so try StaticFindObject as a trusted obj
    local obj = probe(path)
    if obj then
        ASSETS.Cache[path] = obj
        return obj
    end

    -- StaticFindObject returned nothing - clear our cache entry;
    --   this asset is no longer in memory.
    if cached then ASSETS.Cache[path] = nil end
    return nil
end


-- The asset only when handing it back is FREE: a cache hit the keeper has pinned (or a /Script/
-- class or game-immortal object) - a table read, nothing to load, no UObject-array walk. nil
-- means "not for free right now", not "not resident": take the LoadAsync path instead.
-- For code that runs INSIDE a hook and wants to act on the same frame when it can (the Salii's
-- parry flourish) but must never pay a scan or a load there.
function ASSETS.GetIfPinned(path)
    if type(path) ~= "string" then return nil end
    local cached = ASSETS.Cache[path]
    if cached and IsValid(cached)
        and (ASSETS.Pinned[path] or ASSETS.Immortal[path] or path:sub(1, 8) == "/Script/") then
        return cached
    end
    return nil
end


-- =======================================================================
-- Capability probe: does this UE4SS build expose the injected UDataTable row API
-- (FindRow/AddRow/GetRowNames - added between builds v3.0.1-553 and -954)?
--   * Reading `dt.FindRow` is not a safe test on an old build. A missing member can read nil,
--     THROW (escapes a bare caller), or return SELF (truthy - the "return self on a missing
--     field" bug, fixed only in -1012). The only trustworthy probe is CALLING the API under
--     pcall: GetRowNames is read-only, arg-free, and errors cleanly whenever the API is absent.
--   * Latched in STATE.HasDataTableApi. Persistent - a UE4SS build can't change mid-process, and
--     ResetState must not force a re-probe. A nil dt does NOT latch: "nothing to probe yet" is
--     not a verdict.
--   * false turns GetDataTable below into a permanent nil, feature-detecting OFF every DataTable
--     consumer at this one choke point (trader shop, custom items, bobblehead items, Coworker
--     rewards, stowed-pet regen). main.lua InitMod reads the flag to warn the player once.
--   * Utils.RowApiSafe goes FIRST and is the hard gate. Builds before -593 do answer GetRowNames -
--     their FindRow just returns a Lua copy - so this probe only decides for an unlisted build.
-- =======================================================================
function ASSETS.HasDataTableApi(dt)
    if STATE.HasDataTableApi ~= nil then return STATE.HasDataTableApi end
    if not Utils.RowApiSafe() then
        STATE.HasDataTableApi = false
        return false
    end
    if not dt then return false end
    local ok, names = pcall(function() return dt:GetRowNames() end)
    STATE.HasDataTableApi = (ok and names ~= nil) or false
    if not STATE.HasDataTableApi then
        Utils.LogBad("ASSETS - UDataTable row API probe FAILED (UE4SS older than v3.0.1-593?); "
            .. "all DataTable features are disabled")
    end
    return STATE.HasDataTableApi
end


-- =======================================================================
-- Resolve a DataTable by path - the ONE way to get a DT (replaces six identical hand-rolled
-- StaticFindObject helpers, each paying a full ~25ms UObject walk per call). ItemTable_Global is
-- in ASSETS.Immortal, so after the first resolve per world this is a table hit.
--   * `load` does the SYNCHRONOUS LoadAsset retry the setup paths need. It's a BLOCKING load -
--     init-time callers only, never from a hook or a WorkQueue drain (CLAUDE.md §2).
--   * Returns nil if unresolvable, or if this UE4SS build lacks the injected row API (the probe
--     above). Every caller's existing nil-check IS the old-UE4SS feature gate - a returned dt is
--     proven safe for bare dt:FindRow / dt.AddRow use.
-- =======================================================================
function ASSETS.GetDataTable(path, load)
    ASSETS.HasDataTableApi(nil)   -- latches a known-old build's verdict before any resolve or load
    if STATE.HasDataTableApi == false then return nil end
    local dt = ASSETS.GetIfValid(path)
    if (not dt or not ASSETS.HasDataTableApi(dt)) and load then
        -- Logged BEFORE the call: a load that wedges holds the Lua state, so the freeze watchdog
        -- can't name it and this is the last line.
        Utils.Log("ASSETS - blocking-loading DataTable " .. path)
        pcall(function() LoadAsset(path) end)
        dt = ASSETS.GetIfValid(path)
    end
    if not dt or not ASSETS.HasDataTableApi(dt) then return nil end
    return dt
end

-- Keep a resident DataTable alive for the rest of the process: add it to the game instance's
-- ReferencedAssets (a TArray<UObject*> the game fills with defaults and never reads back).
--   * Native layout: a table reached only through typed row handles has no hard owner. One loaded
--     at the menu is collected by the map load's GC and comes back without the rows we added.
--   * The game instance lives as long as the process, so this is once per path. Returns true when
--     the table is held (read back).
local heldTables = {}
local gameInstance

function ASSETS.HoldTable(path)
    if heldTables[path] then return true end
    local dt = ASSETS.GetDataTable(path)
    if not dt then return false end
    local held = false
    pcall(function()
        if not (gameInstance and gameInstance:IsValid()) then
            gameInstance = nil
            for _, gi in ipairs(FindAllOf("Abiotic_GameInstance_C") or {}) do
                if gi:IsValid() and not gi:GetFullName():find("Default__", 1, true) then gameInstance = gi; break end
            end
        end
        local arr = gameInstance.ReferencedAssets
        local n = arr:GetArrayNum()
        arr[n + 1] = dt
        held = arr:GetArrayNum() == n + 1 and arr[n + 1]:GetFullName() == dt:GetFullName()
    end)
    if held then
        heldTables[path] = true
        Utils.Log("ASSETS - holding " .. (path:match("%.([^%.]+)$") or path) .. " for the process")
    else
        Utils.LogBad("ASSETS - could not hold " .. tostring(path) .. " (game instance ReferencedAssets)")
    end
    return held
end

-- Hand `fn(dt)` a DataTable without ever blocking the caller, so it is safe from InitMod and hooks.
--   * Resident -> now. Not resident -> loaded off-hook (Utils.DelayedGameThread) and handed over
--     there, a moment later. dt is nil if it can't be loaded or the row API is missing.
--   * The native layout resolves some tables lazily through typed row handles, so a table
--     that was always resident at InitMod on the old build (DT_Projectiles) can be cold there.
function ASSETS.WithDataTable(path, fn)
    local dt = ASSETS.GetDataTable(path)
    if dt or STATE.HasDataTableApi == false then return fn(dt) end
    Utils.DelayedGameThread(0, function() fn(ASSETS.GetDataTable(path, true)) end)
end


-- =======================================================================
-- Every live copy of an item row, as a list of { Table = name, Row = row }.
--   * ItemTable_Global is a CompositeDataTable that COPIES its ten parents' rows at load, and an
--     inventory slot reads through whichever table its handle names (GetItemInSlot ->
--     GetDataTableRowFromName, fresh every call). recipe_electrothrower and recipe_sceptre_tech
--     name ItemTable_Weapons; most recipes name the composite. An edit to a NATIVE row has to land
--     in every copy, or the items made through the other path stay vanilla.
--   * Parents come off the composite's own ParentTables (hard refs, so no lookup). If that can't be
--     read, ItemTable_Weapons is the only parent covered - said once.
--   * A row the mod ADDED (CustomItems) lives only in the composite, which is also the table its
--     items are made through.
--   * Register-time only: GetDataTable with load=true can block.
-- =======================================================================
local ITEM_TABLE_GLOBAL = "/Game/Blueprints/Items/ItemTable_Global.ItemTable_Global"
local ITEM_TABLE_WEAPONS = "/Game/Blueprints/Items/ItemTable_Weapons.ItemTable_Weapons"
local parentsUnreadableNoted = false

function ASSETS.ItemRowCopies(rowName)
    local copies = {}
    local composite = rowName and ASSETS.GetDataTable(ITEM_TABLE_GLOBAL, true)
    if not composite then return copies end

    local function take(dt, name)
        pcall(function()
            local row = dt:FindRow(rowName)
            if row and row:IsValid() then copies[#copies + 1] = { Table = name, Row = row } end
        end)
    end

    take(composite, "ItemTable_Global")
    local parents = 0
    pcall(function()
        local list = composite.ParentTables
        for i = 1, #list do
            local name = "?"
            pcall(function() name = list[i]:GetFName():ToString() end)
            parents = parents + 1
            take(list[i], name)
        end
    end)
    if parents == 0 then
        if not parentsUnreadableNoted then
            parentsUnreadableNoted = true
            Utils.LogBad("ASSETS - ItemTable_Global.ParentTables unreadable; item-row edits reach "
                .. "ItemTable_Weapons as the only parent")
        end
        local weapons = ASSETS.GetDataTable(ITEM_TABLE_WEAPONS, true)
        if weapons then take(weapons, "ItemTable_Weapons") end
    end
    return copies
end

-- Native layout: copy a row we ADDED to ItemTable_Global into every parent table that holds its
-- donor, and return those tables' names.
--   * Each item family (FoodAndGibs, Deployables_Small, Plants...) resolves its typed handles in its
--     own parent table, so a Global-only row is invisible to that family and the game's lookups
--     miss silently (the farming plot never planted).
--   * The copy is AddRow from our live Global row - an engine struct copy - so call this after the
--     row is fully built (scalars, soft copies, tags). Idempotent.
--   * Parent tables are hard refs of the composite, so they are resident whenever it is.
function ASSETS.MirrorItemRow(rowName, donorName)
    local out = {}
    if not SCHEMA.Native or not rowName or not donorName then return out end
    local composite = ASSETS.GetDataTable(ITEM_TABLE_GLOBAL)
    if not composite then return out end
    local src
    pcall(function() src = composite:FindRow(rowName) end)
    if not (src and src:IsValid()) then return out end

    pcall(function()
        local list = composite.ParentTables
        for i = 1, #list do
            pcall(function()
                local dt = list[i]
                if not dt:IsValid() then return end
                local donor = dt:FindRow(donorName)
                if not (donor and donor:IsValid()) then return end
                local mine = dt:FindRow(rowName)
                if not (mine and mine:IsValid()) then
                    dt:AddRow(rowName, src)
                    mine = dt:FindRow(rowName)
                end
                if mine and mine:IsValid() then out[#out + 1] = dt:GetFName():ToString() end
            end)
        end
    end)
    return out
end

-- Absolute scalar writes into one struct - a row, or an item actor's ItemData - by dotted field path
-- (SCHEMA.Item.WeaponData .. "." .. SCHEMA.Weapon.DamagePerHit). Walks to the leaf's parent and sets
-- the leaf in place: never a whole-struct write, which mangles the soft pointers alongside
-- (CLAUDE.md 3). Each value is read back.
-- Returns `missed` ("Field=readback ..." or nil) and `was` (path -> value before the write).
function ASSETS.WriteStructScalars(struct, scalars)
    local missed, was = nil, {}
    for path, value in pairs(scalars or {}) do
        local now
        pcall(function()
            local node, leaf = struct, nil
            for part in path:gmatch("[^.]+") do
                if leaf then node = node[leaf] end
                leaf = part
            end
            was[path] = node[leaf]
            node[leaf] = value
            now = node[leaf]
        end)
        local landed = (type(value) == "number" and type(now) == "number" and math.abs(now - value) < 1e-3)
            or (type(value) ~= "number" and now == value)
        if not landed then
            missed = (missed or "") .. " " .. (path:match("([^.]+)$") or path) .. "=" .. tostring(now)
        end
    end
    return missed, was
end

-- The same writes into EVERY copy of an item row (ASSETS.ItemRowCopies). Returns the table names
-- written clean, the first copy's `was`, and `missed` ("[Table: Field=readback ]" or nil).
-- No copies at all = no row by that name, or no row API on this build: the caller logs it.
function ASSETS.SetItemRowScalars(rowName, scalars)
    local tables, was, missed = {}, nil, nil
    for _, copy in ipairs(ASSETS.ItemRowCopies(rowName)) do
        local m, w = ASSETS.WriteStructScalars(copy.Row, scalars)
        was = was or w
        if m then
            missed = (missed or "") .. " [" .. copy.Table .. ":" .. m .. " ]"
        else
            tables[#tables + 1] = copy.Table
        end
    end
    return tables, was or {}, missed
end


-- =======================================================================
-- Load an asset asynchronously.
--   * if successful, runs the passed callback fn
--   * else, returns nil
--   * callback(asset, wasCold) - wasCold is true unless the asset is known to have been resident:
--     a probe hit, or a loader trip that handed back the same object as last time. A probe miss, a
--     first resolve and a reload are all cold. NpcSpawner reads it to send a cold class off-hook.
--
-- Whether an untrusted path is probed (StaticFindObject) is SETTINGS.CORE.ASSET_PROBE:
--   * On UE4SS -1136 a probe HIT is a hash lookup, but a MISS falls back to the full UObject-array
--     walk ([[anteup2-ue4ss-findobject-scan-crash]]), and on -1012 every probe walks.
--   * UE4SS's LoadAsset resolves through the engine's asset registry, so a resident asset comes back
--     from it without any walk - just one EIGT hop later instead of inline. "never" sends every
--     top-level /Game/ path there; "seen" only those with no cache entry; "always" none.
--   * The miss "never" removes: a path resolved once, collected before its delayed pin landed, then
--     asked for again (a def.Assets path on the variant's next mutation).
--   * The registry knows only top-level /Game/ assets. /Script/ paths, subobjects (':') and CDOs are
--     always probed.
-- =======================================================================

local function loaderCanResolve(path)
    return path:sub(1, 6) == "/Game/" and not path:find(":", 1, true)
        and not path:find("Default__", 1, true)
end

local function shouldProbe(path, cached)
    if not loaderCanResolve(path) then return true end
    local mode = SETTINGS.CORE and SETTINGS.CORE.ASSET_PROBE
    if mode == "always" then return true end
    if mode == "seen" then return cached ~= nil end
    return false
end

function ASSETS.LoadAsset(path, callback)

    -- Like ASSETS.GetIfValid() - trust /Script/, KEEPER-pinned and game-immortal cache items
    -- Utils.Crumb stamps each native step of this non-loading preamble: wedges have sat in this
    -- window with no cold load logged, so the next one names the call it is in.
    local cached = ASSETS.Cache[path]
    if cached then Utils.Crumb("isvalid:" .. path) end
    if cached and IsValid(cached)
        and (ASSETS.Pinned[path] or ASSETS.Immortal[path] or path:sub(1, 8) == "/Script/") then
        callback(cached)
        return
    end

    local probed = shouldProbe(path, cached)
    if probed then
        local live = probe(path)
        if live then
            ASSETS.Cache[path] = live
            callback(live)
            return
        end
    end
    -- An unprobed trip compares the loader's answer against this address: same object = it never
    -- left. GetAddress reads the wrapper, not the object, so a stale one is safe here.
    --   * A reload that lands on the freed object's exact address reads as resident. Only the log
    --     label and NpcSpawner's hop are affected, and its class pin closes that window in 4s.
    local prevAddr
    if cached and not probed then pcall(function() prevAddr = cached:GetAddress() end) end
    -- drop the invalid wrapper before reloading
    if cached then ASSETS.Cache[path] = nil end

    -- Already loading: park the callback
    if ASSETS.Loading[path] then
        ASSETS.Waiters[path] = ASSETS.Waiters[path] or {}
        table.insert(ASSETS.Waiters[path], callback)
        return
    end

    ASSETS.Loading[path] = true
    ASSETS.Waiters[path] = { callback }

    Utils.Crumb("eigt-dispatch:" .. path)
    ExecuteInGameThread(function()
        -- Freeze breadcrumb (SETTINGS.DEBUG_FREEZE_TRACE reporting; see TickManager).
        --   * A cold LoadAsset here is a BLOCKING load - if the process hangs inside it,
        --     the watchdog names the asset.
        STATE.LastWork = "EIGT LoadAsset " .. path
        STATE.LastWorkDone = false

        local t0 = os.clock()
        local asset, found, loaded = LoadAsset(path)
        STATE.LastWorkDone = true

        local wasCold = false
        if found and loaded and IsValid(asset) then
            ASSETS.Cache[path] = asset
            -- Logging the path makes GC measurable: the same path loading twice in one world
            -- means it was collected in between, which is what AssetKeeper exists to prevent.
            -- UE4SS's own "Asset loaded" line carries no path.
            --   * Probed = the probe missed, so it genuinely wasn't resident.
            --   * Unprobed: the same object as last time was resident (no line); a path seen
            --     earlier in this world is a reload; anything else is a first resolve, which may
            --     have been resident all along - the time tells those apart (a real load takes ms).
            local S = ASSETS.Stats
            local ms = (os.clock() - t0) * 1000
            local addr
            if prevAddr then pcall(function() addr = asset:GetAddress() end) end
            if probed then
                wasCold = true
                if TAP.on then TAP.Count("coldload", path) end
                Utils.LogDebug("ASSETS cold-load: " .. path, SETTINGS.DEBUG_ASSET_LOADS)
            elseif prevAddr and addr == prevAddr then
                S.Resident = S.Resident + 1
            elseif ASSETS.Seen[path] then
                wasCold = true
                S.Reloads = S.Reloads + 1
                if TAP.on then TAP.Count("reload", path) end
                Utils.LogDebug(string.format("ASSETS cold-load (reload, %.1f ms): %s", ms, path),
                    SETTINGS.DEBUG_ASSET_LOADS)
            else
                wasCold = true
                S.First = S.First + 1
                Utils.LogDebug(string.format("ASSETS cold-load (first resolve, %.1f ms): %s", ms, path),
                    SETTINGS.DEBUG_ASSET_LOADS)
            end
            ASSETS.Seen[path] = true
        else
            Utils.LogBad("ASSETS failed to load: " .. path)
            ASSETS.Cache[path] = nil
        end

        local waiters = ASSETS.Waiters[path] or {}
        ASSETS.Loading[path] = nil
        ASSETS.Waiters[path] = nil

        STATE.LastWork = "EIGT LoadAsset-cb " .. path
        STATE.LastWorkDone = false
        for _, cb in ipairs(waiters) do
            local ok, err = pcall(cb, ASSETS.Cache[path], wasCold)
            if not ok then
                Utils.LogBad("ASSETS callback error: " .. tostring(err))
            end
        end
        STATE.LastWorkDone = true
    end)
end


-- =======================================================================
-- Load all assets in paths, then calls finalCallback(results) when done
--   passes results - a table of path->asset mappings, or nil
-- =======================================================================

-- =======================================================================
-- WarmPinned - "keep these resident, and stop paying to check". [the re-warm shape]
--
-- The §3 re-warm (`LoadAsync(DEPS, function() end)` right before an ability fires, because a
-- def.Assets preload does not stick) is correct but it is NOT free: every unpinned path in it is
-- a StaticFindObject, i.e. a full UObject-array walk (~15-25ms) EVEN ON A HIT, and these sites
-- run per attack or on a tick gate. Pinning turns the same call into a table read forever after.
--
-- Same shape as Pipeline's def.Assets pin, for the same reasons:
--   * Pinned on the next drain item from the load's own results (KEEPER.PinLoaded, ~1 ms a path):
--     a GC can land between a load and its use, and nothing holds an unpinned asset there.
--     A delayed PinPaths follows as the backstop.
--   * Free from the second call onward - both dedupe against pinned + known-unpinnable paths.
--   * ASSET_KEEPER-gated inside the keeper, so with it off this is exactly LoadAsync + an empty
--     callback, which is what it replaced.
-- Use LoadAsync directly when the callback actually does something with the assets, and call
-- PinSoon(paths, results) from inside that callback for the same pin.
-- =======================================================================

local PIN_DELAY_MS = 4000

-- The pin half of WarmPinned, for a LoadAsync whose callback does real work. Pass that callback's
-- `results` to pin on the next drain item; without them only the delayed backstop runs.
function ASSETS.PinSoon(paths, results)
    if not paths or #paths == 0 then return end
    local KEEPER = require("AnteCore.AssetKeeper")
    if results then
        for path, asset in pairs(results) do pcall(KEEPER.PinLoaded, path, asset) end
    end
    Utils.QueueWork(function()
        pcall(function() KEEPER.PinPaths(paths) end)
    end, PIN_DELAY_MS)
end

function ASSETS.WarmPinned(paths)
    if not paths or #paths == 0 then return end
    ASSETS.LoadAsync(paths, function(results) ASSETS.PinSoon(paths, results) end)
end


function ASSETS.LoadAsync(paths, finalCallback)
    local remaining = #paths
    local results = {}
    local cold = {}   -- path -> true for each path this call had to cold-load

    if remaining == 0 then
        finalCallback(results, cold)
        return
    end

    for _, path in ipairs(paths) do
        ASSETS.LoadAsset(path, function(asset, wasCold)
            results[path] = asset
            if wasCold then cold[path] = true end
            remaining = remaining - 1
            if remaining == 0 then
                finalCallback(results, cold)
            end
        end)
    end
end

return ASSETS
