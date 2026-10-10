-- =======================================================================
-- Utils - logging, validity checks, coordinates, scheduling, net role.
--
-- Threading rules (hard-won, see AnteUp/EnemyAtTheGATE history):
--   * RegisterHook callbacks run on the game thread - safe for BP calls.
--   * ExecuteWithDelay callbacks fire on WORKER threads - never touch
--     actors there. Use Utils.QueueWork (drained by TickManager on the
--     game thread) or Utils.DelayedGameThread instead.
--   * Creating/attaching components off the game thread corrupts UE
--     animation/Chaos state and crashes much later - hard to diagnose.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local UEHelpers = require("UEHelpers")
local AFUtils = require("AFUtils.AFUtils")
local ENUMS = require("AnteData.Enums")
local SCHEMA = require("AnteData.Schema")
-- AVMath is PURE (its only require is ENUMS), so it is safe this low in the stack - no cycle.
local AVM = require("AnteUtils.AVMath")
local TAP = require("AnteCore.TestTap")   -- AnTest counters; no requires of its own

local Utils = {}


-- ==========================================================
-- Logging
-- ==========================================================

function Utils.Log(msg)
    print("[AnteU] " .. tostring(msg) .. "\n")
end

function Utils.LogBad(msg)
    print("[AnteU][ERR] " .. tostring(msg) .. "\n")
    -- Grouped by shape: numbers and hex addresses vary per line, the message does not.
    if TAP.on then
        local s = tostring(msg)
        TAP.Count("bad", (s:sub(1, 90):gsub("0x%x+", "#"):gsub("%d+", "#")), s)
    end
end

-- Log only when the matching SETTINGS.DEBUG_* flag is on
function Utils.LogDebug(msg, condition)
    if condition then
        print("[AnteU][DEBUG] " .. tostring(msg) .. "\n")
    end
end


-- ==========================================================
-- MIRROR LOG (SETTINGS_DEBUG.DEBUG_MIRROR_LOG) - tee every line this mod prints into
-- saved/logs/AnteUp2-mirror.log, rotating the three previous launches behind it (.1 .2 .3).
--   * ue4ss.log is truncated on every launch. A hosted dedicated server that auto-restarts on a
--     crash therefore destroys the one line that names the fatal work item (the FT crumbs) before
--     anyone can copy it. This file is what survives that.
--   * Wraps the GLOBAL print once, so Profiler / main.lua lines that don't route through
--     Utils.Log are mirrored too. The raw fn and the handle are parked in _G so a /reload neither
--     re-wraps nor re-rotates. Each UE4SS mod has its own Lua state - other mods are untouched.
--   * Cost: one write + flush per line. Flush per line is the point (the last line before a crash
--     must reach disk); it is far below a millisecond per second at the freeze-trace line rate.
--   * Every line carries wall-clock time and FAST_TICK, so it lines up with the profiler's
--     "(tick N)" stamps and the game log's own timestamps.
-- ==========================================================

local function startMirrorLog()
    if _G.__ANTE_MIRROR then return end
    local okS, S = pcall(require, "Settings")
    if not okS or type(S) ~= "table" or not S.DEBUG_MIRROR_LOG then return end

    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    local dir = (src:match("(.+[\\/])") or "./") .. "../../saved/logs/"
    local cur = dir .. "AnteUp2-mirror.log"

    local function openLog()
        pcall(function()
            os.remove(dir .. "AnteUp2-mirror.3.log")
            os.rename(dir .. "AnteUp2-mirror.2.log", dir .. "AnteUp2-mirror.3.log")
            os.rename(dir .. "AnteUp2-mirror.1.log", dir .. "AnteUp2-mirror.2.log")
            os.rename(cur, dir .. "AnteUp2-mirror.1.log")
        end)
        return io.open(cur, "w")
    end
    local f = openLog()
    if not f then
        pcall(function() os.execute('mkdir "' .. dir .. '" 2>nul') end)
        f = openLog()
    end
    if not f then
        print("[AnteU][ERR] mirror log could not be opened at " .. cur .. "\n")
        return
    end

    local rawPrint = _G.__ANTE_RAW_PRINT or print
    _G.__ANTE_RAW_PRINT = rawPrint
    _G.__ANTE_MIRROR = f
    print = function(...)
        rawPrint(...)
        local n = select("#", ...)
        local parts = {}
        for i = 1, n do parts[i] = tostring((select(i, ...))) end
        local line = table.concat(parts, "\t")
        if line:sub(-1) ~= "\n" then line = line .. "\n" end
        -- A failed write (disk full, handle gone) must never take the log call down with it.
        pcall(function()
            f:write(os.date("%Y-%m-%d %H:%M:%S"), " [t", tostring(STATE.FAST_TICK or 0), "] ", line)
            f:flush()
        end)
    end
    print("[AnteU] mirror log -> " .. cur .. "\n")
end
startMirrorLog()


-- ==========================================================
-- Net role
-- * IsServer/IsDedicatedServer come from AFUtils.BaseUtils (globals).
-- * Role is detected once per world in InitMod and cached in STATE,
--   because the answer can change between worlds (SP -> join a server).
-- ==========================================================

function Utils.DetectRole()
    if IsDedicatedServer() then
        STATE.Role = "DEDICATED"
    elseif IsServer() then
        STATE.Role = "HOST"      -- single player or listen-server host
    else
        STATE.Role = "CLIENT"    -- joined someone else's game
    end
    return STATE.Role
end

-- Authority runs the real NPCs: stats, behavior, spawn decisions
function Utils.IsAuthority()
    return STATE.Role == "HOST" or STATE.Role == "DEDICATED"
end

function Utils.IsClient()
    return STATE.Role == "CLIENT"
end

-- Anything visual is pointless on a dedicated server
function Utils.HasRenderer()
    return STATE.Role ~= "DEDICATED"
end


-- ==========================================================
-- Replication (push model)
-- * This build runs with push-model networking: a replicated property is
--   sent to clients ONLY if explicitly marked dirty after a write. The
--   game's own setters do this; when WE write a replicated property from
--   Lua we must mark it ourselves or the change stays server-only.
-- * Only works on properties that are actually replicated (have a rep
--   index). Non-replicated fields (NPCData.*, actor scale) can't be
--   pushed this way - they have no network channel at all.
-- ==========================================================
local pushHelper

function Utils.MarkReplicatedDirty(actor, propName)
    if IsNotValid(actor) then return end

    if IsNotValid(pushHelper) then
        pushHelper = StaticFindObject("/Script/Engine.Default__NetPushModelHelpers")
    end
    if IsNotValid(pushHelper) then
        Utils.LogBad("MarkReplicatedDirty - NetPushModelHelpers unavailable")
        return
    end

    pushHelper:MarkPropertyDirty(actor, FName(propName))
end


-- ==========================================================
-- Departed-actor registry - characters that have run EndPlay, by wrapper ADDRESS.
--   * IsValid passes a freed slot, and IsActorValid's first BP call on one is a native AV.
--     A destroy and its GC purge can both land between two fast ticks (a teleport or zone
--     hop forces the GC), so no tick ever sees the "destroyed but still allocated" state.
--     EndPlay is the only signal that always arrives first.
--   * The address needs no deref, so the lookup is safe on a wrapper of any age.
--   * Stamped from CombatHooks' EndPlay hooks, forgotten from its BeginPlay hook: a new
--     actor allocated at a recycled address must not read as gone.
--   * Stamps are FAST_TICKs, so ResetState drops them with the world.
-- ==========================================================
local departed = { at = {}, who = {}, count = 0, ttl = 300 }   -- ttl in ticks (~30s)

-- LEVEL PROXY - a welded NPC subactor answers "is my level loaded" with its CARRIER's answer.
--   * The game's IsLevelLoaded reads FALSE for one on a dedicated server: it has no OwningLevel and
--     a neutered capsule that overlaps no level volume, and the location fallback that carries it
--     on a host does not there. IsActorValid then threw every fresh Beholder eye away unconfigured.
--   * It lives and streams with its carrier anyway, so the carrier's level IS its level - and
--     asking the carrier keeps a stream-out reading both halves invalid together, as before.
--   * Keyed by address, dropped at the subactor's EndPlay (NoteDeparted) and with the world.
--   * A carrier that leaves play FIRST (destroyed, streamed out) ORPHANS its passengers instead: an
--     orphan answers as a live body of its own, so its cleanup can see it and destroy it. Still
--     pointing at the departed carrier, it read invalid for good, and every cleanup passed it by
--     (a destroyed Beholder's eyes hung frozen in the air); past the stamp's life it read the
--     freed carrier.
local levelProxy = { of = {}, carrierAt = {}, count = 0 }
local ORPHANED = {}

local function wrapperAddr(obj)
    local addr
    pcall(function() if obj.GetAddress then addr = obj:GetAddress() end end)
    return addr
end

-- Returns true for a FRESH stamp. False = this address was already stamped this tick (the other
-- hook slot, or the parent's EndPlay hook on the same body), so the caller can skip the rest of
-- its per-departure work.
function Utils.SetLevelProxy(sub, carrier)
    local addr = wrapperAddr(sub)
    if not addr or carrier == nil then return end
    if levelProxy.of[addr] == nil then levelProxy.count = levelProxy.count + 1 end
    levelProxy.of[addr] = carrier
    levelProxy.carrierAt[addr] = wrapperAddr(carrier)
end

-- True once a welded passenger's carrier has left play. Deref-free, and it never expires, unlike
-- the carrier's own departed stamp.
function Utils.CarrierDeparted(sub)
    return levelProxy.count > 0 and levelProxy.of[wrapperAddr(sub)] == ORPHANED
end

function Utils.NoteDeparted(actor)
    local addr = wrapperAddr(actor)
    if not addr then return false end
    if levelProxy.of[addr] ~= nil then
        levelProxy.of[addr], levelProxy.carrierAt[addr] = nil, nil
        levelProxy.count = levelProxy.count - 1
    end
    if levelProxy.count > 0 then
        for sub, at in pairs(levelProxy.carrierAt) do
            if at == addr then levelProxy.of[sub], levelProxy.carrierAt[sub] = ORPHANED, nil end
        end
    end

    local now = STATE.FAST_TICK
    local prev = departed.at[addr]
    if prev == now then return false end
    if prev == nil then
        departed.count = departed.count + 1
        if departed.count > 256 then   -- bound: drop expired entries
            local n = 0
            for a, t in pairs(departed.at) do
                if (now - t) >= departed.ttl then
                    departed.at[a], departed.who[a] = nil, nil
                else
                    n = n + 1
                end
            end
            departed.count = n + 1
        end
    end
    departed.at[addr] = now

    -- Dev logging only: who this was, read while it is still live.
    --   * Raw field reads, NOT Utils.GetActorName: that validity-checks, and this address was
    --     stamped two lines up, so it caught itself and logged a nameless line per departure.
    if require("Settings").DEBUG_NPC_ACTIONS then
        departed.who[addr] = Utils.GetActorClassName(actor)
        pcall(function()
            local name = actor.NPCData[ENUMS.NpcData.DisplayName]:ToString()
            if name and name ~= "" then departed.who[addr] = name end
        end)
    end
    return true
end

function Utils.ForgetDeparted(actor)
    if departed.count == 0 then return end
    local addr = wrapperAddr(actor)
    if addr and departed.at[addr] ~= nil then
        departed.at[addr], departed.who[addr] = nil, nil
        departed.count = departed.count - 1
    end
end

-- First caller outside the files in `skip`, as "File.lua:123". Exact basenames: "AVUtils.lua"
-- ends in "Utils.lua".
local function callerOutside(skip)
    for lvl = 3, 12 do
        local info = debug.getinfo(lvl, "Sl")
        if not info then break end
        local base = info.short_src:match("[^\\/]+$")
        if info.what ~= "C" and not skip[base] then
            return base .. ":" .. tostring(info.currentline)
        end
    end
    return "?"
end
local THIS_FILE = { ["Utils.lua"] = true }
local LOOKUP_HELPERS = { ["Utils.lua"] = true, ["AssetManager.lua"] = true }

function Utils.IsDeparted(actor)
    if departed.count == 0 then return false end
    local addr = wrapperAddr(actor)
    local t = addr and departed.at[addr]
    if t == nil or (STATE.FAST_TICK - t) >= departed.ttl then return false end
    if TAP.on then TAP.Count("departed", callerOutside(THIS_FILE), departed.who[addr]) end

    -- Each of these is a deferred touch of an actor that had already left play. Back-to-back
    -- repeats for one address fold into a single line.
    --   * The NAME is the body that departed at this address. If the caller is plainly working
    --     on something else, a live actor inherited the stamp (BeginPlay never cleared it).
    if departed.said ~= addr and require("Settings").DEBUG_NPC_ACTIONS then
        departed.said = addr
        Utils.LogDebug(string.format("IsDeparted - stale wrapper caught: %s, left play %d ticks ago, via %s",
            tostring(departed.who[addr] or "?"), STATE.FAST_TICK - t, callerOutside(THIS_FILE)), true)
    end
    return true
end


-- ==========================================================
-- Validity checks
-- ==========================================================

function Utils.IsActorValid(actor)
    if IsNotValid(actor) then return false end
    if Utils.IsDeparted(actor) then return false end   -- before any deref

    -- pcall'd: this is the FIRST touch of every deferred callback's captured wrapper.
    --   * The read itself must not be the deref that blows up on a stale one (CLAUDE.md 3).
    --   * pcall can't stop a freed-slot AV, but it does catch wrapper-level Lua errors -
    --     the common failure. An unreadable field = treat the actor as gone.
    local okData, npcData = pcall(function() return actor.NPCData end)
    if not okData then return false end

    -- NPCs in unloaded levels linger as objects; treat them as invalid.
    -- BP call, so only safe because all our code paths run on the game thread.
    if IsValid(npcData) then
        if levelProxy.count > 0 then
            local carrier = levelProxy.of[wrapperAddr(actor)]
            if carrier == ORPHANED then return true end   -- ours, in the persistent level
            if carrier ~= nil then return Utils.IsActorValid(carrier) end
        end
        local ok, levelLoaded = pcall(function()
            return actor:IsLevelLoaded(false)
        end)
        if not ok or not levelLoaded then return false end
    end

    return true
end

function Utils.IsActorInvalid(actor)
    return not Utils.IsActorValid(actor)
end

-- True for a LIVE actor whose level merely reads unloaded - the one TRANSIENT way to fail
-- IsActorValid. "Invalid" then means hands off for now, not gone.
--   * A script-spawned body (summon, PlacedSpawn, welded passenger) lives in the persistent
--     level. On a dedicated server it survives every player leaving its sector, reads invalid
--     while they are away, and is perfectly good again when one comes back.
--   * A client NPC replicates in AHEAD of its level when a player teleports into a sector.
--   * Anything that DROPS state on IsActorInvalid (a tick returning "REMOVE", a roster prune)
--     has to ask this first, or that body comes back as a statue.
function Utils.IsLevelAway(actor)
    if IsNotValid(actor) or Utils.IsDeparted(actor) then return false end
    local okData, npcData = pcall(function() return actor.NPCData end)
    if not okData or not IsValid(npcData) then return false end

    if levelProxy.count > 0 then
        local carrier = levelProxy.of[wrapperAddr(actor)]
        if carrier == ORPHANED then return false end
        if carrier ~= nil then return Utils.IsLevelAway(carrier) end
    end
    local ok, loaded = pcall(function() return actor:IsLevelLoaded(false) end)
    return ok and loaded == false
end

-- Guarded "is this actor dead / not worth touching" read. True if dead, or if IsDead can't be
-- read at all (treat an unreadable field as gone).
--   * Callers bail on dead victims at the top of the damage hooks: a corpse standing in an
--     environmental DoT (fire, electrified water, acid) still fires ProcessDamage every tick for
--     seconds after death, dereffing dying-actor props. This skips that.
--   * Shrinks exposure only - pcall catches Lua errors, not an AV on a genuinely freed slot.
--   * The killing blow itself is unaffected: IsDead only flips AFTER our pre-hook runs.
function Utils.IsDeadSafe(actor)
    local ok, dead = pcall(function() return actor.IsDead == true end)
    if not ok then return true end
    return dead
end

-- Returns actor.Mesh only if both actor and mesh are usable.
--   * The GetWorld call is pcall'd: on a CLIENT a replicated actor's mesh wrapper can exist before
--     its class is fully known, and UE4SS then errors "Function 'GetWorld' not available"
--     (seen in TraderMirror's skin apply).
function Utils.GetValidMesh(actor)
    if Utils.IsActorInvalid(actor) then return nil end

    -- pcall'd for the same reason as IsActorValid's NPCData read: this polls captured
    -- wrappers (the ACTOR_READY WaitFor) and the read must not be the stale-wrapper deref.
    local okM, mesh = pcall(function() return actor.Mesh end)
    if not okM or IsNotValid(mesh) then return nil end
    local ok, world = pcall(function() return mesh:GetWorld() end)
    if not ok or not world then return nil end

    return mesh
end

function Utils.IsComponentValid(comp)
    if IsNotValid(comp) then return false end

    local owner = comp:GetOwner()
    if IsNotValid(owner) then return false end

    if comp:IsBeingDestroyed() then return false end
    if owner:IsActorBeingDestroyed() then return false end

    return true
end

function Utils.IsComponentInvalid(comp)
    return not Utils.IsComponentValid(comp)
end

function Utils.IsActorAlive(actor)
    if IsNotValid(actor) then return false end
    if not actor.RootComponent then return false end
    if actor.IsDead then return false end
    if actor.IsDBNO then return false end

    local ok, hp = pcall(function() return actor:GetTotalHealth() end)
    if not ok or not hp or hp <= 0 then return false end

    return true
end

-- The DayNightManager (world time/day/weather singleton), or nil. Cached per world;
-- re-found if the cached wrapper goes invalid (world reload).
local dayMgr
function Utils.GetDayNightManager()
    if IsNotValid(dayMgr) then dayMgr = FindFirstOf("DayNightManager_C") end
    if IsNotValid(dayMgr) then return nil end
    return dayMgr
end

-- Current in-game day (int) from the DayNightManager, or nil if unreadable.
--   * tonumber on every read here: a field the object lacks reads as a TrivialObject, not nil.
function Utils.GetCurrentDay()
    local mgr = Utils.GetDayNightManager()
    if not mgr then return nil end
    local ok, day = pcall(function() return mgr.CurrentDay end)
    return ok and tonumber(day) or nil
end

-- Current in-game HOUR (0-23), or nil if unreadable.
--   * Derived from CurrentTimeInSeconds, which is seconds-since-midnight and is the same field
--     the clock, the announcer and the assault hour-gate all read. LastKnownHour exists but is a
--     REPLICATION mirror that only updates on the hour boundary, so it lags by up to an hour.
--   * Floored, so 18.9 reads as 18 - which is what a ">= 18 means tomorrow" rule wants.
function Utils.GetCurrentHour()
    local mgr = Utils.GetDayNightManager()
    if not mgr then return nil end
    local ok, secs = pcall(function() return mgr.CurrentTimeInSeconds end)
    secs = ok and tonumber(secs)
    if not secs then return nil end
    return math.floor((secs % 86400) / 3600)
end

-- In-game hours since day 0 (fractional), or nil if unreadable. The clock for ROLLING cooldowns.
--   * Monotonic: the day ticks over exactly as the time of day wraps to 0, and sleep advances both.
--   * Counts play time, not wall time - a world that isn't running doesn't count down.
function Utils.GetGameHours()
    local mgr = Utils.GetDayNightManager()
    if not mgr then return nil end
    local ok, day, secs = pcall(function() return mgr.CurrentDay, mgr.CurrentTimeInSeconds end)
    day, secs = ok and tonumber(day), ok and tonumber(secs)
    if not day or not secs then return nil end
    return day * 24 + (secs % 86400) / 3600
end

-- ==========================================================
-- Actor names
-- ==========================================================

-- Fold an FName-derived row name back to its canonical spelling (the ENUMS.NpcClasses key).
--   * An FName COMPARES case-insensitively, but ToString() returns whatever spelling the engine's
--     name table happened to register FIRST that process - not DT_NPCList's spelling, and it can
--     vary between sessions (see CLAUDE.md law 1). Left uncorrected, a `==` or table-key comparison
--     can silently fail (a whole NPC family stops mutating).
--   * Row names are used as table keys everywhere (SpawnerData, NpcGroupings, def.Base/AltBases),
--     so canonicalise ONCE here rather than case-folding every comparison; both roles read through
--     this, so server and client agree. A row not in the roster passes through unchanged.
local canonRow                 -- lowercase row -> canonical row (built once, on first use)
local canonMemo = {}           -- raw row -> canonical row (skips the :lower() on the hot path)
function Utils.CanonicalRowName(row)
    if not row then return nil end

    local hit = canonMemo[row]
    if hit then return hit end

    if not canonRow then
        canonRow = {}
        for key in pairs(ENUMS.NpcClasses) do canonRow[key:lower()] = key end
    end

    local canon = canonRow[row:lower()] or row
    canonMemo[row] = canon
    -- Once per odd spelling per session: silent correction here would hide the next occurrence
    -- of this from us entirely, and the memo means it can't spam.
    if canon ~= row then
        Utils.Log(string.format("row name '%s' -> '%s' (FName casing; see Utils.CanonicalRowName)",
            row, canon))
    end
    return canon
end

-- The NPC's base game identifier (DT_NPCList row name, e.g. "Pest", "Pest_Carbonated", "Exor_Monk").
--   * A CLASS-DEFAULT property: present on every instance on both server and client, and we never
--     overwrite it (unlike DisplayName) - the stable key for "what base NPC is this"
--     (spawn decisions, variant def.Base). See [[af-replication-facts]].
--   * Canonicalised (see Utils.CanonicalRowName) - the raw FName casing is not trustworthy.
--   * Returns nil if unavailable.
function Utils.GetActorRowName(actor)
    if Utils.IsActorInvalid(actor) then return nil end

    local ok, row = pcall(SCHEMA.NpcRowName, actor)
    if ok and row then return Utils.CanonicalRowName(row) end
    return nil
end

-- True if `actor` is a player pawn (Abiotic_PlayerCharacter).
--   * Gates effects that should only hit players (e.g. an NPC's OnDealtDamage debuffing the victim).
--   * Matches by GetFullName (cheap, no class lookup) - players' full path contains "PlayerCharacter".
function Utils.IsPlayer(actor)
    if Utils.IsActorInvalid(actor) then return false end
    local ok, isP = pcall(function()
        local fn = actor:GetFullName()
        return fn ~= nil and tostring(fn):find("PlayerCharacter") ~= nil
    end)
    return ok and isP == true
end

-- NPC display name (NPCData) or nil if not an NPC / not ready yet
function Utils.GetActorNPCName(actor)
    if Utils.IsActorInvalid(actor) then return nil end

    local npcData = actor.NPCData
    if IsNotValid(npcData) then return nil end

    local name = npcData[ENUMS.NpcData.DisplayName]
    if not name then return nil end

    return name:ToString()
end

-- Leaf class name of an actor/object, e.g. "NPC_Monster_ShieldPest_C". nil if unreadable.
--   * The identity of last resort: some NPCs are a distinct CLASS while sharing another row's
--     row name + DisplayName (the native ShieldPest reads row "Pest") - neither
--     GetActorRowName nor GetActorNPCName can tell them apart, only the class can.
function Utils.GetActorClassName(actor)
    -- A null UObject arrives from a hook as a WRAPPER, not as nil (a BP that blanks a param before
    -- Supering hands us one), and GetClass reads ClassPrivate off it with no check of its own - an
    -- access violation no pcall can catch. IsValid, not IsActorValid: a level-away body still has a
    -- readable class, and non-actors resolve through here too.
    if IsNotValid(actor) then return nil end
    local ok, cls = pcall(function() return actor:GetClass():GetFName():ToString() end)
    if ok and cls and cls ~= "" then return cls end
    return nil
end

-- NPC display name, falling back to class name (NPCData may not be
-- initialized yet at hook fire time)
function Utils.GetActorName(actor)
    local name = Utils.GetActorNPCName(actor)
    if name then return name end

    return Utils.GetActorClassName(actor) or "?"
end


-- Stable per-INSTANCE key for a UObject actor (its full path name).
--   * Use to key any per-actor Lua table written and read across DIFFERENT hook fires or hook
--     sources: UE4SS hands out a FRESH wrapper for the same UObject per hook invocation (and
--     FindAllOf returns fresh wrappers), so the wrapper itself is NOT a stable table key - a value
--     stored under one wrapper won't be found under another (anteup2-actor-wrapper-identity note).
--   * Returns nil if the actor can't be named (callers should treat nil as "skip").
--   * NOTE: a table keyed by GetFullName should be a PLAIN table, not weak-keyed - string keys
--     aren't collected the way the wrapper (userdata) keys were; clear entries explicitly if needed.
function Utils.ActorKey(actor)
    local ok, name = pcall(function() return actor:GetFullName() end)
    return ok and name or nil
end


-- A damage type's object path (contains the class name, e.g. "...DamageType_Psychic_Holy...") -
-- match against it with :find(). Handy in OnDamageTaken/OnDealtDamage to branch on the hit's type.
function Utils.DamageTypeName(dt)
    if not dt then return nil end
    local ok, n = pcall(function() return dt:GetFullName() end)
    return ok and n or nil
end


-- ==========================================================
-- Combat / subactors (AUTHORITY)
-- ==========================================================

-- FRotator that points from `origin` toward `target` (yaw + pitch).
function Utils.RotatorToTarget(origin, target)
    local dx = (target.X or 0) - (origin.X or 0)
    local dy = (target.Y or 0) - (origin.Y or 0)
    local dz = (target.Z or 0) - (origin.Z or 0)
    local yaw = math.deg(math.atan(dy, dx))
    local pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy)))
    return FRotator(pitch, yaw, 0)
end

-- A point `distance` units past `b` along the a->b direction (overshoot,
-- e.g. to make a lunge aim through the target).
function Utils.PointAheadOfVector(a, b, distance)
    local dir = Utils.Direction(a, b)
    return FVector(b.X + dir.X * distance, b.Y + dir.Y * distance, b.Z + dir.Z * distance)
end

-- True if any player is within `distance` of `loc`.
function Utils.IsPlayerNearby(loc, distance)
    if not loc then return false end
    distance = distance or 5000
    local distSq = distance * distance
    -- Iterate the GameState's player array (O(players)), never FindAllOf("Abiotic_PlayerCharacter_C")
    -- - that scans the ENTIRE UObject array (O(all objects)), prohibitive per-tick in a dense sector.
    local gs = STATE.GameState
    if IsNotValid(gs) then return false end
    local players = gs.PlayerCharacterInGame
    if not players then return false end
    for i = 1, #players do
        local p = players[i]
        if IsValid(p) then
            local ok, pl = pcall(function() return p:K2_GetActorLocation() end)
            if ok and pl and Utils.DistSq(loc, pl) < distSq then return true end
        end
    end
    return false
end

-- THE ONE CLOCK EVERY MACHINE AGREES ON. The GameState's replicated server time - the server's own
-- world time, and on a client the same value reconstructed from the replicated delta.
--   * Use it for anything a client must compute IN PHASE with the server (the Phase Peccary's fade
--     is the reference): FAST_TICK is a per-process counter with a per-actor registration offset,
--     so two machines ticking the same handler are never on the same beat.
--   * Returns nil if the GameState isn't up yet - callers skip that tick.
function Utils.ServerTimeSeconds()
    local gs = STATE.GameState
    if IsNotValid(gs) then return nil end
    local ok, t = pcall(function() return gs:GetServerWorldTimeSeconds() end)
    return ok and tonumber(t) or nil
end


-- Array of live player pawns (GameState array, never FindAllOf which scans all UObjects). For "iterate
-- every player" callers; use AnyPlayer/RandomPlayer/NearestPlayer when you only need one.
function Utils.LivePlayers()
    local gs = STATE.GameState
    local players = gs and gs.PlayerCharacterInGame
    local live = {}
    if players then
        for i = 1, #players do
            if IsValid(players[i]) then live[#live + 1] = players[i] end
        end
    end
    return live
end

-- Living subset of an actor ref list (drops dead/gone wrappers). Handy for scripted set-pieces that
-- hold refs across timed beats - some of the cast will have died by the time a later beat fires.
function Utils.LivingActors(list)
    local out = {}
    for _, a in ipairs(list or {}) do
        if Utils.IsActorValid(a) then out[#out + 1] = a end
    end
    return out
end

-- Is the SUBLEVEL containing `loc` streamed in? The game's own ground truth
-- (ULevelManagerSubsystem::IsLocationLoaded), not a proxy.
--   * Spawning into an unloaded sector yields an unmutated base NPC (IsActorValid rejects it, see
--     the PlacedSpawns stacking bug) - ASK FIRST instead of spawn-then-check. SphereOverlapActors
--     also reports "empty" there. Player proximity is not a substitute: a level border can leave a
--     nearby coord unstreamed.
--   * Cached via getSingleton: a WORLD subsystem, stable within a world (cleared by
--     Utils.ResetState on teardown, per CLAUDE.md 3) - a raw per-call resolve was several
--     StaticFindObjects deep for one call that matters.
function Utils.IsLocationLoaded(loc)
    if not loc then return false end

    -- Utils.GetLevelManager (not the local getSingleton): a table lookup resolves at CALL time,
    -- so this works despite being defined ABOVE the singleton cache.
    local mgr = Utils.GetLevelManager()
    if IsNotValid(mgr) then return false end

    local ok, loaded = pcall(function() return mgr:IsLocationLoaded(loc) end)
    return ok and loaded == true
end

-- Is any sublevel mid-load right now? The game's own narrative/trader spawns wait this out
-- (Abiotic_AIDirector, NPCSpawn_Narrative). Unreadable = false, so a caller never stalls on it.
function Utils.IsAnyLevelLoading()
    local mgr = Utils.GetLevelManager()
    if IsNotValid(mgr) then return false end
    local ok, loading = pcall(function() return mgr:IsAnyLevelLoading() end)
    return ok and loading == true
end

-- True only if a player is within `radius` of `loc` (= that sector is streamed in).
--   * Spatial scripts that spawn/kill at fixed coords guard on this, so a FORCE-RUN (debug keybind /
--     chat) while the target area is UNLOADED is a safe no-op instead of operating on a dead level
--     (which has crashed).
--   * `name` (optional) is only used to name the skipped thing in the log.
function Utils.AreaLoaded(loc, radius, name)
    if Utils.IsPlayerNearby(loc, radius) then return true end
    Utils.Log(string.format("%s skipped (no player near the target area - not loaded)",
        name and ("Story EVENT - " .. name) or "Area-gated action"))
    return false
end

-- First live player, or nil. (GameState array, never FindAllOf.)
function Utils.AnyPlayer()
    local gs = STATE.GameState
    local players = gs and gs.PlayerCharacterInGame
    if not players then return nil end
    for i = 1, #players do
        if IsValid(players[i]) then return players[i] end
    end
    return nil
end

-- First live player who has actually FINISHED character creation, or nil.
--   * Utils.AnyPlayer goes true the moment a pawn exists - on a NEW world that's still the JOB /
--     TRAIT SELECT screen. Anything placed in that window spawns, logs cleanly, and is then
--     silently discarded ([[anteup2-worldinit-dropped-items]]). Use this for anything that grants
--     or places world state at startup; plain AnyPlayer is fine for "is anyone here at all".
--   * Reads `Abiotic_PlayerState.HasSetUpSkills` - the game's own server-written, replicated
--     answer (also restored from a save, so a loaded world reads it true immediately).
function Utils.AnyPlayerInPlay()
    local gs = STATE.GameState
    local players = gs and gs.PlayerCharacterInGame
    if not players then return nil end
    for i = 1, #players do
        local p = players[i]
        if IsValid(p) then
            local ready
            pcall(function()
                local ps = p.MyPlayerState
                ready = IsValid(ps) and ps.HasSetUpSkills == true
            end)
            if ready then return p end
        end
    end
    return nil
end

-- A random live player, or nil.
function Utils.RandomPlayer()
    local live = Utils.LivePlayers()
    if #live == 0 then return nil end
    return live[math.random(1, #live)]
end

-- Nearest live player to `loc` (returns the player and its distSq), or nil.
function Utils.NearestPlayer(loc)
    if not loc then return nil end
    local gs = STATE.GameState
    local players = gs and gs.PlayerCharacterInGame
    if not players then return nil end
    local best, bestSq
    for i = 1, #players do
        local p = players[i]
        if IsValid(p) then
            local ok, pl = pcall(function() return p:K2_GetActorLocation() end)
            if ok and pl then
                local d = Utils.DistSq(loc, pl)
                if not bestSq or d < bestSq then best, bestSq = p, d end
            end
        end
    end
    return best, bestSq
end

-- Normalized HORIZONTAL forward (facing) of an actor as an FVector(x, y, 0), or nil.
function Utils.HorizontalForward(actor)
    if Utils.IsActorInvalid(actor) then return nil end
    local ok, fwd = pcall(function() return actor:GetActorForwardVector() end)
    if not ok or not fwd then return nil end
    local m = math.sqrt(fwd.X * fwd.X + fwd.Y * fwd.Y)
    if m < 0.01 then return nil end
    return FVector(fwd.X / m, fwd.Y / m, 0)
end

-- Per-world SINGLETON cache (nav system, world-flag subsystem, ...).
--   * FindFirstOf scans ALL UObjects and these callers can run per-tick / per-spawn-wave, so cache
--     the singleton by class name. Within a world these are stable.
--   * GC-SAFE: re-found if the wrapper goes invalid mid-world (unlikely), and the whole cache is
--     CLEARED in Utils.ResetState on world teardown - never carry a freed cross-world pointer
--     (IsValid LIES on a reused slot - the cache-across-worlds hazard from the freed-asset crashes).
local singletonCache = {}
local function getSingleton(className)
    local c = singletonCache[className]
    if IsNotValid(c) then c = FindFirstOf(className); singletonCache[className] = c end
    return c
end
local function getNavSystem() return getSingleton("NavigationSystemV1") end

-- =======================================================================
-- Cached UWorld - USE THIS, NEVER UEHelpers.GetWorld() on any path that can repeat.
--   * UEHelpers.GetWorld() derives the world via an uncached FindAllOf("PlayerController") -
--     O(all UObjects), measured ~29ms per call flat regardless of caller (CLAUDE.md 2).
--   * Cached like the subsystems above: stable within a world, dropped by Utils.ResetState on
--     teardown so a freed cross-world pointer is never handed back (CLAUDE.md 3).
-- =======================================================================
function Utils.GetWorld()
    local w = singletonCache.__world
    if IsNotValid(w) then
        w = UEHelpers.GetWorld()   -- the ONE place in the mod allowed to call this
        singletonCache.__world = w
    end
    return w
end

-- Cached WorldFlagSubsystem (world flags = server data). Shared by Utils.HasWorldFlag + StoryManager.
function Utils.GetWorldFlagSubsystem() return getSingleton("WorldFlagSubsystem") end

-- Cached LevelManagerSubsystem (streaming truth: IsLocationLoaded / GetLevelAtLocation).
-- Backs Utils.IsLocationLoaded, which PlacedSpawns calls per candidate placement per pass -
-- profiling put the old uncached resolve at ~30ms per anchor (EventUtils' work-budget note).
function Utils.GetLevelManager() return getSingleton("LevelManagerSubsystem") end

-- Cached AIDirectorSubsystem (the REAL spawner->NPC link - spawner.CurrentNPCs is dead legacy).
-- Shared by SpawnerHooks' save-restore heal walk, which runs per spawner stream-in and on the
-- cooldown heartbeat - an uncached resolve there was a measurable per-walk cost.
function Utils.GetAIDirector() return getSingleton("AIDirectorSubsystem") end

-- Cached UAISense_Hearing (the engine sense object that owns ReportNoiseEvent). Backs
-- AVU.ReportNoise, which is a per-EVENT call - an uncached FindFirstOf on a gunshot cadence is
-- exactly the hidden-scan family CLAUDE.md 2 bans.
function Utils.GetHearingSense() return getSingleton("AISense_Hearing") end

-- The nav system, cached like the rest. EXPORTED because AVU.FindLosPoint was resolving it with a
-- raw FindFirstOf on every call - the hidden-scan family (CLAUDE.md 2): a full UObject walk behind
-- a convenience accessor, on a helper a pack of NPCs can each call every few seconds.
function Utils.GetNavSystem() return getNavSystem() end

-- The AI Director ACTOR (Abiotic_AIDirector_C) - NOT Utils.GetAIDirector, the SUBSYSTEM. Two
-- distinct objects with confusable names; the assault API (IsAssaultHappening,
-- ServerForceBeginAssault, TargetAssaultBench, Assault_CurrentPhase) lives on this one. Cached
-- like the rest; re-resolves if the director is destroyed and respawned mid-world.
function Utils.GetAIDirectorActor() return getSingleton("Abiotic_AIDirector_C") end

-- The Security Reaper director (ReaperDirector_Security_C) - the level actor that owns the one
-- scheduled Reaper in Facility_Security (its `SpawnedReaper` pointer; AnNotes/AnteNPCs/Reaper.md). Exists
-- in that ONE map, so a miss re-scans on the next call - callers on a repeatable path must keep
-- their own negative cache (ShadesHelpers does, keyed by world name).
function Utils.GetReaperDirector() return getSingleton("ReaperDirector_Security_C") end

-- Navmesh floor Z under `loc` (its X/Y, searching around its Z), minus optional `sink`.
-- nil if the nav query fails. Cheap floor-follow for actors sliding over hilly terrain.
function Utils.GroundZ(loc, sink)
    if not loc then return nil end
    local world = GetWorld()
    if IsNotValid(world) then return nil end
    local navSys = getNavSystem()
    if IsNotValid(navSys) then return nil end
    local out = FVector()
    local ok = navSys:K2_ProjectPointToNavigation(world, loc, out, nil, nil, FVector(150, 150, 600))
    if ok then return out.Z - (sink or 0) end
    return nil
end

-- Streaming-level name at a world location ("V_Salem", etc.), or nil. Strips a Package.Level
-- path down to the leaf level name.
local levelNameSoftNoted = false

function Utils.GetLevelName(loc)
    if not loc then return nil end
    -- Native layout: GetLevelAtLocation also RETURNS a TSoftObjectPtr<UWorld>, and marshalling it back
    -- is a soft read - only safe on a proven UE4SS build (Utils.SoftRefsSafe).
    if SCHEMA.Native and not Utils.SoftRefsSafe() then
        if not levelNameSoftNoted then
            levelNameSoftNoted = true
            Utils.Log("GetLevelName - off on this game build + UE4SS (its call returns a soft pointer)")
        end
        return nil
    end
    local AFL = AFUtils.GetAbioticFunctionLibrary()
    if IsNotValid(AFL) then return nil end
    local out = {}
    local ok = pcall(function() AFL:GetLevelAtLocation(loc, Utils.GetWorld(), out) end)
    if not ok then return nil end
    local f = out.LevelName
    if not f then return nil end
    local s = (f.ToString and f:ToString()) or tostring(f)
    local _, _, leaf = string.find(s, "%.([^%.]+)$")
    return leaf or s
end

-- Set of level names players are currently in, MEMOIZED per FAST_TICK (backs AnyPlayerInLevel
-- below = "any live player standing in the named level", exact match on Utils.GetLevelName).
--   * GetLevelName is a per-location BP spatial query (~tens of ms), and AnyPlayerInLevel is called
--     many times per StoryManager tick (once per PlacedSpawn + the Hexed Tree gate) - without this
--     the tick would run GetLevelAtLocation N-times-per-player and stutter.
--   * A synchronous tick keeps FAST_TICK constant, so all of its calls share one computation;
--     the next tick recomputes.
local playerLevelsTick, playerLevelsSet
local function getPlayerLevels()
    if playerLevelsSet and playerLevelsTick == STATE.FAST_TICK then return playerLevelsSet end
    local set = {}
    local gs = STATE.GameState
    local players = gs and gs.PlayerCharacterInGame
    if players then
        for i = 1, #players do
            local p = players[i]
            if IsValid(p) then
                local ok, loc = pcall(function() return p:K2_GetActorLocation() end)
                if ok and loc then
                    local name = Utils.GetLevelName(loc)
                    if name then set[name] = true end
                end
            end
        end
    end
    playerLevelsTick, playerLevelsSet = STATE.FAST_TICK, set
    return set
end

-- [UNUSED] no live callers; EventUtils moved to proximity checks instead (level-presence went
-- true too early - see EventUtils.lua DarkFusion note).
function Utils.AnyPlayerInLevel(name)
    if not name then return false end
    return getPlayerLevels()[name] == true
end

-- True if any live player's location is inside the axis-aligned box [min..max] (each a {X,Y,Z} table).
--   * Pure arithmetic per player - no GetLevelName/GetLevelAtLocation spatial query - so it's
--     ~microseconds where AnyPlayerInLevel is ~tens of ms.
--   * Use as a level-presence proxy when the levels are spaced far enough apart that a generous
--     bounding box can't overlap a neighbour (the Hexed Tree / Canaan gate).
--   * `min`/`max` are pre-sorted by the caller.
function Utils.AnyPlayerInBox(min, max)
    if not min or not max then return false end
    local gs = STATE.GameState
    local players = gs and gs.PlayerCharacterInGame
    if not players then return false end
    for i = 1, #players do
        local p = players[i]
        if IsValid(p) then
            local ok, l = pcall(function() return p:K2_GetActorLocation() end)
            if ok and l
                and l.X >= min.X and l.X <= max.X
                and l.Y >= min.Y and l.Y <= max.Y
                and l.Z >= min.Z and l.Z <= max.Z then
                return true
            end
        end
    end
    return false
end

-- =======================================================================
-- AREAS - "is this actor/player inside that authored space"
--
-- An AREA is a FLOOR PLAN: the corner points of a room, walked in order, and nothing else.
--     local ARENA = { Points = { FVector(-38810, 83810, 2870), FVector(-43540, 82980, 2880),
--                                FVector(-44230, 86300, 2610), FVector(-39480, 87500, 2760) } }
--     if Utils.ActorInArea(boss, ARENA) then ... end
--
--   * Z is ignored by default (an infinitely tall prism) - most spaces this covers are tall ones
--     (an overlook ledge, a hovering boss). Set `MinZ`/`MaxZ` to opt into a slab.
--   * A radius doesn't work here: a circle around a hand-picked centre either clips a real room's
--     corners or spills into the next one. Four walked corners describe the actual space instead.
--   * Winding/shape don't matter (AVM.PointInPoly2D is a crossing-number test). Pure arithmetic
--     per point - no spatial query, safe on any cadence.
-- =======================================================================

-- True if `loc` is inside `area`. nil area / fewer than 3 corners = false.
function Utils.LocInArea(loc, area)
    if not loc or not area then return false end
    if area.MinZ and (loc.Z or 0) < area.MinZ then return false end
    if area.MaxZ and (loc.Z or 0) > area.MaxZ then return false end
    return AVM.PointInPoly2D(area.Points, loc.X or 0, loc.Y or 0)
end

-- True if `actor` is inside `area`. An actor we cannot read reads as OUTSIDE - callers use this to
-- decide whether an arena-scoped mechanic may run, and "skip it" is the safe answer.
function Utils.ActorInArea(actor, area)
    if Utils.IsActorInvalid(actor) or not area then return false end
    local loc
    pcall(function() loc = actor:K2_GetActorLocation() end)
    return Utils.LocInArea(loc, area)
end

-- The FIRST live player standing inside `area`, or nil. Walks the GameState list (same cheap read
-- as Utils.AnyPlayerInBox), so it is fine on a per-hit path behind a short cache.
--   * Returns the PLAYER because "who is in the room" is what a scripted beat actually wants (an
--     arrival that locks onto whoever came in). Utils.AnyPlayerInArea is this, asked as a yes/no.
function Utils.PlayerInArea(area)
    if not area then return nil end
    local gs = STATE.GameState
    local players = gs and gs.PlayerCharacterInGame
    if not players then return nil end
    for i = 1, #players do
        local p = players[i]
        if IsValid(p) then
            local ok, l = pcall(function() return p:K2_GetActorLocation() end)
            if ok and Utils.LocInArea(l, area) then return p end
        end
    end
    return nil
end

-- True if ANY live player stands inside `area`.
function Utils.AnyPlayerInArea(area)
    return Utils.PlayerInArea(area) ~= nil
end


-- [AUTHORITY] Show an on-screen WARNING message to every player (the purple/red banner).
--   * Client_DisplayWarningMessage is a client RPC on the player pawn, so calling it server-side
--     reaches each client.
--   * `color` is an AFUtils.CriticalityLevels value (caller passes it; pcall'd so a bad/missing
--     enum just no-ops).
function Utils.BroadcastWarning(msg, color)
    for _, p in ipairs(Utils.LivePlayers()) do
        pcall(function() p:Client_DisplayWarningMessage(FText(msg), color, false) end)
    end
end


-- Capture -> re-resolve: the GC-safe way to carry a UObject across an async hop (EIGT / delayed work).
--   * A captured WRAPPER can be freed + slot-reused before the callback runs, and IsValid LIES then
--     (the GC family; pcall can't catch the resulting native AV - the Crash2-SpawnStressTest stack).
--   * So: take the object's PATH while it's alive, then StaticFindObject it at use-time - a freed
--     object resolves to nil, never a stale pointer (same defense as ASSETS.GetIfValid).
function Utils.ObjectPath(obj)
    if IsNotValid(obj) then return nil end
    local full
    pcall(function() full = obj:GetFullName() end)
    if not full then return nil end
    return full:match("^%S+ (.+)$") or full   -- strip the "ClassName " prefix
end

-- LOOKUP TRACE (SETTINGS_DEBUG.DEBUG_LOOKUP_TRACE): one "FT sfo" line BEFORE each by-path lookup,
-- naming the path and the first caller outside the lookup helpers.
--   * A crash inside a lookup is otherwise silent: its crumb (STATE.LastWork) prints only on a freeze.
--   * Every print reaches the mirror log, which survives a hosted server's restart.
function Utils.TraceLookup(path)
    if TAP.on then
        -- A lookup inside one of Utils' own game-thread hops has no caller outside the helpers;
        -- its breadcrumb ("EIGT buffapply ...") names the hop instead.
        local via = callerOutside(LOOKUP_HELPERS)
        if via == "?" then via = tostring(STATE.LastWork or "?"):match("^%S+%s+%S+") or "?" end
        TAP.Count("lookup", via, path)
    end
    if not require("Settings").DEBUG_LOOKUP_TRACE then return end
    Utils.LogDebug("FT sfo " .. tostring(path) .. " via " .. callerOutside(LOOKUP_HELPERS), true)
end

function Utils.ResolveByPath(path)
    if not path then return nil end
    Utils.TraceLookup(path)
    local obj
    pcall(function() obj = StaticFindObject(path) end)
    if obj and obj:IsValid() then return obj end
    return nil
end

-- =======================================================================
-- UE4SS build id - the 8-char Git SHA, or nil when it can't be read (treat nil as "unknown").
--   * UE4SS.GetVersion() reads 3.0.1 on every experimental build, so the only place the build
--     shows is the header of UE4SS.log. Read once per process.
-- =======================================================================
local ue4ssBuild   -- nil = not read yet, false = unreadable, string = the SHA

function Utils.UE4SSBuild()
    if ue4ssBuild ~= nil then return ue4ssBuild or nil end
    ue4ssBuild = false
    pcall(function()
        local src = debug.getinfo(1, "S").source
        if src:sub(1, 1) == "@" then src = src:sub(2) end
        -- AnteUtils -> scripts -> AnteUp2 -> Mods -> the UE4SS root, where the log lives.
        local f = io.open((src:match("(.+[\\/])") or "./") .. "../../../../UE4SS.log", "r")
        if not f then return end
        for _ = 1, 12 do
            local line = f:read("l")
            if not line then break end
            local sha = line:match("Git SHA #(%x+)")
            if sha then ue4ssBuild = sha:lower() break end
        end
        f:close()
    end)
    return ue4ssBuild or nil
end

-- =======================================================================
-- UE4SS build NUMBER (the -NNN in a release name) for the builds we know, keyed by the first 7
-- characters of the logged SHA: -553 logs 7, later builds 8. The number is the commit count past the
-- v3.0.1 tag (GitHub compare API). The -1136 dll logs its parent commit, f6d5f942.
-- The log's "Beta #N" is 0 on every build, so the SHA is the only identity there is.
-- =======================================================================
local UE4SS_BUILD_NUMBERS = {
    c68f4f7 = 553, a4b3968 = 556,
    ["272ce2f"] = 954, c838a8a = 1012, f6d5f94 = 1136,
}

-- RE-UE4SS PR #1058 (merged at -593) made UDataTable:FindRow return a LIVE UScriptStruct instead of
-- a Lua COPY, and let AddRow clone from one. Every row feature here writes in place, so on an older
-- build each edit lands in a throwaway table - and GetRowNames still answers, so ASSETS' capability
-- probe cannot tell the two apart.
local ROW_API_MIN_BUILD = 593
local rowApiSafe   -- decided once per process

function Utils.UE4SSBuildNumber()
    local sha = Utils.UE4SSBuild()
    return sha and UE4SS_BUILD_NUMBERS[sha:sub(1, 7)] or nil
end

-- May this machine use the UDataTable row API? The hard gate in front of ASSETS.HasDataTableApi: a
-- known build decides outright, CORE.DATATABLE_ROWS forces it either way, and an unlisted build
-- falls through to the capability probe.
function Utils.RowApiSafe()
    if rowApiSafe ~= nil then return rowApiSafe end
    local want
    pcall(function() want = require("Settings").CORE.DATATABLE_ROWS end)
    local build, number = Utils.UE4SSBuild(), Utils.UE4SSBuildNumber()
    local label = "UE4SS build " .. tostring(build or "unknown") .. (number and (" = v3.0.1-" .. number) or "")
    if want == true or want == false then
        rowApiSafe = want
        Utils.Log("RowApi - forced " .. (want and "ON" or "OFF") .. " by CORE.DATATABLE_ROWS (" .. label .. ")")
    elseif number then
        rowApiSafe = number >= ROW_API_MIN_BUILD
        if rowApiSafe then
            Utils.Log("RowApi - ON (" .. label .. ")")
        else
            Utils.LogBad("RowApi - OFF: " .. label .. " predates the in-place row API (v3.0.1-"
                .. ROW_API_MIN_BUILD .. "). Custom items, custom projectile rows and item retunes are skipped")
        end
    else
        rowApiSafe = true
        Utils.Log("RowApi - " .. label .. " is not a known build; the DataTable capability probe decides")
    end
    return rowApiSafe
end

-- =======================================================================
-- Soft-object properties (a TSoftObjectPtr field) on this UE4SS build:
--   * A READ hands back a TSoftObjectPtr userdata that has never yielded a path on this build
--     (every reader in the mod came back nil), so nothing can verify what a field names.
--   * The SETTER copies a whole TSoftObjectPtr out of the right-hand userdata with NO type check.
--     FSoftObjectPath is not a Lua global (the call throws inside its pcall and nothing is
--     written), and a nil right-hand side makes the setter read uninitialised stack memory - an
--     access violation that depends on what the stack held, so it passes on one machine and kills
--     another (the 2026-09-15 dedicated Charge Peccary crash, inside SetStaggerImmune).
--   * BOTH DIRECTIONS ARE BUILD-DEPENDENT. A read and a write each copy the whole pointer
--     through UE4SS's own model of its layout, and builds after v3.0.1-1012 model it 8 bytes off
--     for this engine: the copy takes its string length from whatever member FOLLOWS the field,
--     so it dies or not by the neighbour's bytes, and a write also runs past the property. No Lua
--     error, uncatchable. So every soft access sits behind Utils.SoftRefsSafe, which passes only
--     a build the copy is proven on.
-- So the one sound write is a genuine TSoftObjectPtr value, and the one guaranteed-blank source is
-- a field the NPC base class default never sets. Read once, kept as a Lua-owned copy.
-- =======================================================================
local SOFT_REF_PROVEN_BUILDS = { c838a8ac = true }   -- v3.0.1-1012
local softRefsSafe                                    -- decided once per process

-- May Lua touch a soft-object property on this machine? CORE.SOFT_REF_WRITES forces it either
-- way; "auto" passes only a proven build, so an unknown or unreadable one fails safe.
function Utils.SoftRefsSafe()
    if softRefsSafe ~= nil then return softRefsSafe end
    local want
    pcall(function() want = require("Settings").CORE.SOFT_REF_WRITES end)
    local build = Utils.UE4SSBuild()
    if want == true or want == false then
        softRefsSafe = want
        Utils.Log("SoftRefs - forced " .. (want and "ON" or "OFF") .. " by CORE.SOFT_REF_WRITES (UE4SS build "
            .. tostring(build or "unknown") .. ")")
    else
        softRefsSafe = (build ~= nil and SOFT_REF_PROVEN_BUILDS[build] == true)
        if softRefsSafe then
            Utils.Log("SoftRefs - ON (UE4SS build " .. build .. ")")
        else
            Utils.Log("SoftRefs - OFF: UE4SS build " .. tostring(build or "unknown") .. " is not proven for "
                .. "soft-object writes. Dodge-roll, stagger and aggro clips play as vanilla; nothing else changes.")
        end
    end
    return softRefsSafe
end

local SOFT_BLANK_FIELD = "BackstepAnimation"   -- unset on Default__NPC_Base_ParentBP_C (FModel export)
local softBlank                                 -- the donor userdata, resolved on first use

local function softBlankDonor()
    if softBlank ~= nil then return softBlank end
    local cdo = Utils.ResolveByPath(ENUMS.BASE_PARENT_NPC_CDO)
    if not cdo then return nil end
    local v
    pcall(function() v = cdo[SOFT_BLANK_FIELD] end)
    if type(v) ~= "userdata" then return nil end
    softBlank = v
    return v
end

-- Blank a SOFT-OBJECT property. `field` must be a TSoftObjectPtr (check the header dump): the
-- setter for a hard object reference would swallow the same userdata as a garbage pointer, so a
-- field that reads back as a live object wrapper is refused. True = the write went through.
function Utils.BlankSoftRef(obj, field)
    if obj == nil or not field then return false end
    if not Utils.SoftRefsSafe() then return false end   -- before ANY soft read, the donor's included
    local donor = softBlankDonor()
    if donor == nil then return false end

    -- A hard reference reads back as a UObject wrapper, whose members resolve; a soft one is opaque.
    local hard = false
    pcall(function()
        local cur = obj[field]
        if cur ~= nil then
            local ok, member = pcall(function() return cur.IsValid end)
            hard = ok and member ~= nil
        end
    end)
    if hard then return false end

    local ok = pcall(function() obj[field] = donor end)
    return ok
end

-- Freeze breadcrumb for one NON-LOADING native step inside traced work (an OnTick handler, a
-- WorkQueue item, LoadAsset's preamble). Appends to STATE.LastWork so the watchdog line keeps the
-- item that was running AND names the step it wedged in.
--   * LastWork ONLY - the drain and OnTick wrappers own LastWorkDone, and a premature `true` there
--     mislabels a later wedge as "not mod work".
--   * Capped: a long warm list would otherwise grow the string without bound.
function Utils.Crumb(tag)
    local lw = STATE.LastWork
    if lw and #lw >= 300 then lw = lw:sub(1, 120) .. " ..." end
    STATE.LastWork = (lw and (lw .. " > ") or "") .. tag
end

-- =======================================================================
-- BUFF LOOKUP (SETTINGS.CORE.BUFF_LOOKUP) - what a buff op carries across its off-hook hop.
--   * PATH: the component's path, re-found in the hop. A full UObject walk per op, plus one for a
--     linked actor - the FindObject-scan AV's exposure, paid on every sting and strip.
--   * WRAPPER: the actor wrappers themselves, gated in the hop by Utils.IsActorValid. Its departed
--     check is address-only, and every character stamps it at EndPlay (NPCs and players, see
--     CombatHooks). Only characters qualify; anything else stays on PATH.
--   * VERIFY: a WRAPPER op that re-finds by path FIRST, applies through what the path found, and
--     scores what the wrapper check would have done. A departure the registry missed trips every
--     op back to PATH for the session.
-- Counters and the test set: /au-bufftest (AnDebug/BuffProbe).
-- =======================================================================
local BL = { tripped = nil, force = nil, stats = {}, playersStamped = false }

function BL.stat(key) BL.stats[key] = (BL.stats[key] or 0) + 1 end

-- "path" | "wrapper" | "verify" for one op on `buff`, decided when the op is queued.
function BL.mode(buff)
    if BL.tripped then return "path" end
    local cfg
    pcall(function() cfg = require("Settings").CORE.BUFF_LOOKUP end)
    if type(cfg) ~= "table" then cfg = {} end
    local mode = BL.force
    if not mode then
        if cfg.Mode == "all" then
            mode = "wrapper"
        elseif cfg.Mode == "rows" and buff and type(cfg.Rows) == "table" then
            local want = tostring(buff):lower()
            for _, r in ipairs(cfg.Rows) do
                if tostring(r):lower() == want then mode = "wrapper" break end
            end
        end
    end
    if mode == "wrapper" and cfg.Verify then return "verify" end
    return mode or "path"
end

-- An NPC or a player: the classes whose EndPlay stamps the departed registry. Players only once
-- their stamp hooks are known to be registered (Utils.ArmPlayerStamps).
function BL.stamped(a)
    local npc = false
    pcall(function() npc = IsValid(a.NPCData) end)
    if npc then return true end
    if not BL.playersStamped then return false end
    local fn
    pcall(function() fn = a:GetFullName() end)
    return fn ~= nil and tostring(fn):find("Abiotic_PlayerCharacter_C", 1, true) ~= nil
end

function BL.comp(actor)
    local comp
    pcall(function() comp = actor.BuffDebuffComponent end)
    if IsNotValid(comp) then return nil end
    return comp
end

function BL.trip(who)
    BL.stat("verifyUnstamped")
    if BL.tripped then return end
    BL.tripped = tostring(who or "?")
    Utils.LogBad("BuffLookup - " .. BL.tripped .. " was gone but never stamped as departed; "
        .. "every buff op is back on the by-path lookup until restart")
end

function BL.wrapperHop(actor, linkedActor, linkPath, apply)
    if not Utils.IsActorValid(actor) then BL.stat("wrapperSkipped") return end
    local comp = BL.comp(actor)
    if not comp then BL.stat("wrapperSkipped") return end
    local link
    if linkPath then
        link = Utils.ResolveByPath(linkPath)   -- a non-character link: no stamp to trust
    elseif linkedActor ~= nil and Utils.IsActorValid(linkedActor) then
        link = linkedActor
    end
    BL.stat("wrapper")
    apply(comp, link)
end

-- Path first, so a wrapper the registry failed to stamp is never touched.
function BL.verifyHop(actor, linkedActor, compPath, linkPath, who, apply)
    local viaPath = Utils.ResolveByPath(compPath)
    local gone = Utils.IsDeparted(actor)
    if not viaPath then
        if gone then BL.stat("verifyAgreeGone") else BL.trip(who) end
        return
    end
    if gone then
        -- The path still finds a destroyed body until GC collects it, so ask the body. Only one
        -- that is NOT being destroyed is a stamp WRAPPER would have wrongly skipped.
        local dying = true
        pcall(function() dying = viaPath:GetOwner():IsActorBeingDestroyed() == true end)
        BL.stat(dying and "verifyAgreeGone" or "verifyStaleStamp")
    else
        local comp = BL.comp(actor)
        if comp and wrapperAddr(comp) == wrapperAddr(viaPath) then BL.stat("verifyMatch")
        else BL.stat("verifyMismatch") end
    end
    local link = linkPath and Utils.ResolveByPath(linkPath) or nil
    if linkedActor ~= nil and not link and not Utils.IsDeparted(linkedActor) then
        BL.trip("the linked actor of " .. tostring(who))
    end
    apply(viaPath, link)
end

-- /au-bufftest reads and steers these.
function Utils.BuffLookupStatus()
    local cfg
    pcall(function() cfg = require("Settings").CORE.BUFF_LOOKUP end)
    return { cfg = cfg, tripped = BL.tripped, force = BL.force, stats = BL.stats }
end
function Utils.BuffLookupReset() BL.stats, BL.tripped = {}, nil end
function Utils.SetBuffLookupForce(mode) BL.force = mode end   -- "wrapper" | "verify" | "path" | nil
function Utils.ArmPlayerStamps() BL.playersStamped = true end   -- CombatHooks, once the player hooks register
function Utils.PlayerStampsArmed() return BL.playersStamped end

-- Does this actor's EndPlay stamp the departed registry? Then its wrapper may cross an off-hook hop,
-- gated there by Utils.IsActorValid, instead of travelling as a path (Utils.CarryActor).
function Utils.StampsDeparture(actor) return BL.stamped(actor) end

-- Carry an actor across an off-hook hop (EIGT, DelayedGameThread, QueueWork). Call it where the actor
-- was just validated; it returns a getter for the hop side: the live actor, or nil once it left play.
--   * A character (StampsDeparture) crosses as its wrapper, gated by IsActorValid - no UObject walk.
--   * Anything else crosses as a path and is re-found by it (a walk), as every hop used to do.
--   * The stamps exist only where CombatHooks registered (the authority) and last departed.ttl
--     (~30 s): a client takes the path, and a hop longer than that should too.
local function noActor() return nil end
function Utils.CarryActor(actor)
    if IsNotValid(actor) then return noActor end   -- a null hook param is a wrapper, not nil
    if BL.stamped(actor) and Utils.IsAuthority() then
        return function() return Utils.IsActorValid(actor) and actor or nil end
    end
    local path = Utils.ObjectPath(actor)
    if not path then return noActor end
    return function() return Utils.ResolveByPath(path) end
end

-- Shared buff plumbing: run `apply(comp, link)` OFF-HOOK (ExecuteInGameThread, all roles), with the
-- actor's BuffDebuffComponent (+ optional linked actor) found again inside the hop - see BUFF LOOKUP.
--   * Off-hook because a buff's first apply can blocking-load and hang the game thread.
--   * Found again because a wrapper held across the hop can be freed = native AV (Utils.ObjectPath).
local function applyBuffOffHook(actor, linkedActor, apply, label, buff)
    -- BOTH bails used to be SILENT, which is the worst shape for this function: a buff that never
    -- applies looks identical to a buff that applied and did nothing, and the two have completely
    -- different fixes. They are one-line logs now (DEBUG_NPC_ACTIONS).
    --   * IsActorValid opens with an actor.NPCData read - fine on NPCs, and a PLAYER has no such
    --     field, so this is exactly the sort of place a player-only failure hides.
    if Utils.IsActorInvalid(actor) then
        Utils.LogDebug("buff " .. (label or "apply") .. " - SKIPPED: actor reads invalid",
            require("Settings").DEBUG_NPC_ACTIONS)
        return
    end

    -- The stamps exist only on the authority (CombatHooks registers there), so a client's op and an
    -- unstamped class take the path.
    local mode = BL.mode(buff)
    if mode ~= "path" and not (BL.stamped(actor) and Utils.IsAuthority()) then mode = "path" end

    if mode == "wrapper" then
        if not BL.comp(actor) then
            Utils.LogDebug("buff " .. (label or "apply") .. " - SKIPPED: no BuffDebuffComponent on "
                .. tostring(Utils.GetActorName(actor)), require("Settings").DEBUG_NPC_ACTIONS)
            return
        end
        local linkPath = (linkedActor ~= nil and not BL.stamped(linkedActor))
            and Utils.ObjectPath(linkedActor) or nil
        ExecuteInGameThread(function()
            STATE.LastWork = "EIGT " .. (label or "buffapply") .. " (wrapper) " .. tostring(buff)
            STATE.LastWorkDone = false
            BL.wrapperHop(actor, linkedActor, linkPath, apply)
            STATE.LastWorkDone = true
        end)
        return
    end

    local compPath = Utils.ObjectPath(actor.BuffDebuffComponent)
    if not compPath then
        Utils.LogDebug("buff " .. (label or "apply") .. " - SKIPPED: no BuffDebuffComponent path on "
            .. tostring(Utils.GetActorName(actor)), require("Settings").DEBUG_NPC_ACTIONS)
        return
    end
    local linkPath = linkedActor and Utils.ObjectPath(linkedActor) or nil
    local who = (mode == "verify") and (Utils.GetActorName(actor) or compPath) or nil

    ExecuteInGameThread(function()
        -- Freeze breadcrumb (DEBUG_FREEZE_TRACE watchdog): a buff apply cold-loads its buff
        -- object by ROW NAME (the debuff-preload trap, CLAUDE.md 6) - if the process hangs in
        -- here the watchdog names the component. `label` distinguishes apply from remove.
        STATE.LastWork = "EIGT " .. (label or "buffapply") .. " " .. compPath
        STATE.LastWorkDone = false
        if mode == "verify" then
            BL.verifyHop(actor, linkedActor, compPath, linkPath, who, apply)
        else
            BL.stat("path")
            local comp = Utils.ResolveByPath(compPath)
            if comp then
                local link = linkPath and Utils.ResolveByPath(linkPath) or nil
                apply(comp, link)
            end
        end
        STATE.LastWorkDone = true
    end)
end

-- Apply a buff/debuff via Server_TryApplyBuff. limb 0 = all bones. LinkedActor (optional) - some buffs
-- need one (Debuff_BeeSwarm fades if the target gets 20m from the source).
function Utils.AddBuff(actor, buff, overrideDuration, newDuration, limb, linkedActor)
    applyBuffOffHook(actor, linkedActor, function(comp, link)
        pcall(function()
            comp:Server_TryApplyBuff(FName(buff), nil, overrideDuration or false, newDuration or 0, limb or 0, link)
        end)
    end, nil, buff)
end

-- [AUTHORITY] Apply a buff via the DIRECT Server_ApplyBuff path.
--   * Server_TryApplyBuff (AddBuff) routes on Is_Locally_Controlled and NO-OPS when a server applies
--     to a player - NPC->player debuffs (BeeSwarm) never land through AddBuff; use this instead.
--   * NO `duration` = the row's own default, untouched. That is the only way to get a row whose
--     timing is part of its design (bNoExpiration, or a buff object that retimes itself on apply
--     like Bleeding's 10s NPC clamp) to behave the way the game applies it.
--   * `beforeApply` (optional) runs in the same game-thread step, just before the apply, for a write
--     the new buff instance has to see (the Hive Sow's per-owner damage modifier on the CDO).
local buffHandleLib
function Utils.ApplyBuffLinked(actor, buff, duration, linkedActor, limb, beforeApply)
    applyBuffOffHook(actor, linkedActor, function(comp, link)
        if IsNotValid(buffHandleLib) then
            buffHandleLib = StaticFindObject("/Script/AbioticFactor.Default__BuffDebuffHandleFunctionLibrary")
        end
        if IsNotValid(buffHandleLib) then
            Utils.LogBad("ApplyBuffLinked - BuffDebuffHandleFunctionLibrary not found")
            return
        end
        if beforeApply then pcall(beforeApply) end
        pcall(function()
            local handle = buffHandleLib:MakeBuffDebuffRowHandle(FName(buff))
            -- (handle, OverrideDefaultDuration, NewDuration, Limb, LinkedActor, bool)
            comp:Server_ApplyBuff(handle, duration ~= nil, duration or 0, limb or 0, link, false)
        end)
    end, nil, buff)
end

-- [AUTHORITY] Apply `buff` to EVERY live player. Uses the DIRECT Server_ApplyBuff path (like
-- ApplyBuffLinked) because Server_TryApplyBuff NO-OPS server->player.
--   * `duration` (seconds) defaults to -1 = apply with the buff row's OWN default duration and then
--     leave it alone.
--   * `duration > 0` = override the duration AND schedule strips afterwards (at 1x/2x/3x the duration),
--     so a scripted buff can never leak and outlive its welcome.
-- Players who ALREADY have the buff are SKIPPED, so we never strip one that wasn't ours (e.g. someone
-- wearing the trinket that grants it). Returns how many players were buffed.
-- [UNUSED] no live callers; listed in EventUtils' toolbox header, kept as API.
function Utils.BuffAllPlayers(buff, duration)
    duration = duration or -1
    local override = duration > 0

    local ours, count = {}, 0
    for _, p in ipairs(Utils.LivePlayers()) do
        if not Utils.ActorHasBuff(p, buff) then
            local fn
            pcall(function() fn = p:GetFullName() end)
            if fn then ours[fn] = true end
            count = count + 1

            applyBuffOffHook(p, nil, function(comp)
                if IsNotValid(buffHandleLib) then
                    buffHandleLib = StaticFindObject("/Script/AbioticFactor.Default__BuffDebuffHandleFunctionLibrary")
                end
                if IsNotValid(buffHandleLib) then
                    Utils.LogBad("BuffAllPlayers - BuffDebuffHandleFunctionLibrary not found")
                    return
                end
                pcall(function()
                    local handle = buffHandleLib:MakeBuffDebuffRowHandle(FName(buff))
                    -- (handle, OverrideDefaultDuration, NewDuration, Limb, LinkedActor, bool)
                    comp:Server_ApplyBuff(handle, override, override and duration or 0, 0, nil, false)
                end)
            end, nil, buff)
        end
    end

    if override and count > 0 then
        for mult = 1, 3 do
            Utils.QueueWork(function()
                for _, p in ipairs(Utils.LivePlayers()) do
                    local fn
                    pcall(function() fn = p:GetFullName() end)
                    if fn and ours[fn] and Utils.ActorHasBuff(p, buff) then
                        Utils.RemoveBuff(p, buff)
                        Utils.Log("BuffAllPlayers - stripped lingering '" .. tostring(buff) .. "'")
                    end
                end
            end, duration * 1000 * mult)
        end
    end

    Utils.Log(string.format("BuffAllPlayers - '%s' on %d player(s)%s",
        tostring(buff), count, override and (" for " .. duration .. "s") or ""))
    return count
end

-- Every buff/debuff currently on an actor, read straight off the component's live
-- `CurrentBuffs` array: { { Row = "Debuff_LegFracture", Limb = 7 }, ... }.
--   * Reading the array beats asking `HasBuff?`: that BP wrapper answers through a bool and a
--     TArray OUT-PARAM, and an out-param call that doesn't land is a silent no-op (CLAUDE.md 3).
--     The array is a plain property, and it carries the limb we need anyway.
--   * Limbs matter because the bone and bleed rows are stored PER LIMB (ParentLimb = LeftLeg,
--     RightArm...), never on AllBones - see Utils.RemoveBuff.
--   * Row names are FNames, whose casing is not stable, so callers match folded.
function Utils.ActorBuffs(actor)
    local out = {}
    if Utils.IsActorInvalid(actor) then return out end
    pcall(function()
        local comp = actor.BuffDebuffComponent
        if IsNotValid(comp) then return end
        local cur = comp.CurrentBuffs
        if not cur then return end
        for i = 1, #cur do
            local entry = cur[i]
            local name = entry.BuffRow.RowName:ToString()
            -- ParentLimb is a uint8 enum: usually a plain number, a wrapper on some builds.
            local raw = entry.ParentLimb
            if type(raw) == "userdata" then
                local okGet, got = pcall(function() return raw:get() end)
                if okGet then raw = got end
            end
            if name then
                out[#out + 1] = { Row = name, Limb = tonumber(raw) or 0 }
            end
        end
    end)
    return out
end

-- The limbs an actor carries one named row on, as an EBodyLimbs array (empty = it doesn't have
-- it). A whole-body buff reports { 0 } (AllBones); fractures, breaks and bleeds report the
-- leg/arm they landed on. `limb` narrows the answer to that one limb.
function Utils.ActorBuffLimbs(actor, buff, limb)
    local want, limbs = tostring(buff):lower(), {}
    for _, e in ipairs(Utils.ActorBuffs(actor)) do
        if e.Row:lower() == want and (limb == nil or e.Limb == limb) then
            limbs[#limbs + 1] = e.Limb
        end
    end
    return limbs
end

-- True if the actor currently has the named buff/debuff (no limb = on any limb).
function Utils.ActorHasBuff(actor, buff, limb)
    return #Utils.ActorBuffLimbs(actor, buff, limb) > 0
end


-- How many DEBUFFS an actor is carrying - the "how wrecked is this target" number a variant can
-- scale off (the Plague Witch's quill ladder). Works on players and NPCs alike.
--
-- A row is a debuff if it is NAMED one. There is no runtime flag for it: DT_BuffsDebuffs' BuffType
-- reads `Buff` for debuffs too, and its Severity column only lives on the row, which would mean a
-- DataTable resolve per lookup. The naming is consistent enough to key off instead.
-- Distinct ROWS, not entries - a bleed filed on three limbs is one debuff, not three.
--
-- What the exclusions are: rows that are named Debuff_ but are really bookkeeping - the combat
-- markers everyone in a fight wears, the character traits a player picked at creation, the
-- temperature-resisted pips, and the "recently X" cooldown flags. Counting those would hand out a
-- free tier or two for standing in a cold room with the wrong trait.
-- Everything a player can SEE in their debuff bar does count, survival ladder included: hungry,
-- thirsty, tired, cold, overloaded. A worn-down player is a softer target, which is the point.
-- Add a row here to take it back out of the count.
local DEBUFF_SKIP_PREFIX = { "debuff_trait_", "debuff_incombat" }
local DEBUFF_SKIP = {
    ["debuff_chilly_resisted"] = true, ["debuff_cold_resisted"] = true,
    ["debuff_warm_resisted"] = true,   ["debuff_hot_resisted"] = true,
    ["debuff_heatstroke_resisted"] = true, ["debuff_hypothermia_resisted"] = true,
    ["debuff_wading"] = true, ["debuff_underwater"] = true, ["debuff_stuffysuit"] = true,
    ["debuff_bloody"] = true,          -- the minor smear; Bloodsoaked ("Filthy") is the real one
    ["debuff_damaged"] = true, ["debuff_despawnwhendisabled"] = true,
    ["debuff_recentkizz"] = true, ["debuff_recentleginjury"] = true,
    ["debuff_composerattacked"] = true, ["debuff_containmentbotattacked"] = true,
    ["debuff_exorallycooldown"] = true,
}

function Utils.CountDebuffs(actor)
    local seen, count = {}, 0
    for _, e in ipairs(Utils.ActorBuffs(actor)) do
        local row = e.Row:lower()
        if not seen[row] and row:sub(1, 7) == "debuff_" and not DEBUFF_SKIP[row] then
            local skip = false
            for _, pre in ipairs(DEBUFF_SKIP_PREFIX) do
                if row:sub(1, #pre) == pre then skip = true; break end
            end
            seen[row] = true
            if not skip then count = count + 1 end
        end
    end
    return count
end


-- GC-HARDENED causer resolves (FIRST-SIGHT CACHE).
--   * Timer-driven DoT ticks (acid pools, burns) keep passing their DamageCauser long after that
--     actor - usually a PROJECTILE destroyed at impact - is freed; IsValid LIES on the reused slot,
--     and dereferencing it is a native AV pcall can't catch.
--   * So both helpers resolve ONCE while the causer is provably alive, cache by wrapper ADDRESS (no
--     UObject deref), and serve the cached string on every later tick. Caches are size-capped.
--   * A reused address would serve the old actor's name, and the name picks the variant def for
--     OnDealtDamage - so a death or EndPlay evicts it (Utils.ForgetCauserAddr, from CombatHooks).
--     A causer that leaves without either (a destroyed projectile) can still be served stale.

-- Causer's INSTIGATOR name = the pawn that FIRED a projectile/grenade (a variant-name lookup on the
-- projectile causer itself would miss). Returns (name|nil, freshThisCall) - `fresh` = the causer is
-- alive RIGHT NOW (usable e.g. as a blast origin for knockback); cached ticks are not.
local causerInstCache, causerInstCount = {}, 0   -- addr -> instigator name (false = none)
function Utils.DamageCauserInstigatorName(causer)
    if not causer then return nil, false end
    local addr
    pcall(function() if causer.GetAddress then addr = causer:GetAddress() end end)
    if addr and causerInstCache[addr] ~= nil then
        local v = causerInstCache[addr]
        if v == false then return nil, false end
        return v, false
    end

    if not IsValid(causer) then return nil, false end
    local name
    pcall(function()
        local inst = causer:GetInstigator()
        if inst and IsValid(inst) then name = Utils.GetActorName(inst) end
    end)
    if addr then
        causerInstCount = causerInstCount + 1
        if causerInstCount > 512 then causerInstCache, causerInstCount = {}, 1 end
        causerInstCache[addr] = name or false
    end
    return name, true
end

-- Causer's OWN name (GC-hardened, same first-sight cache). An unresolved "?" is returned UNCACHED so it
-- retries next tick (the name may just not be ready yet).
--   * Second return = the causer's "#1234" instance suffix, resolved on the same first sight. Two
--     bodies of one variant otherwise log identical lines, and an interleaved pair reads exactly
--     like one body attacking twice as fast. LOG ONLY - the name alone is the variant registry key.
local causerNameCache, causerNameCount = {}, 0
local causerIdCache = {}   -- addr -> instance suffix, written and dropped with causerNameCache
function Utils.DamageCauserName(causer)
    if not causer then return nil end
    local addr
    pcall(function() if causer.GetAddress then addr = causer:GetAddress() end end)
    if addr and causerNameCache[addr] then return causerNameCache[addr], causerIdCache[addr] end

    if not IsValid(causer) then return nil end
    local name
    pcall(function() name = Utils.GetActorName(causer) end)
    if not name or name == "?" then return name end
    local id = ""
    pcall(function()
        local inst = causer:GetFullName():match("_(%d+)$")
        if inst then id = "#" .. inst:sub(-4) end
    end)
    if addr then
        causerNameCount = causerNameCount + 1
        if causerNameCount > 512 then causerNameCache, causerIdCache, causerNameCount = {}, {}, 1 end
        causerNameCache[addr], causerIdCache[addr] = name, id
    end
    return name, id
end

-- Forget an address in both caches. CombatHooks calls this when the actor there dies or leaves play,
-- so the next actor allocated at that address doesn't inherit its name (and, through the name, its
-- variant def for OnDealtDamage). NpcManager calls it when a body mutates, since the name it was
-- first seen under is stale then too. No deref. Nothing re-resolves the dead causer early either: its
-- lingering DoT ticks are squashed to nil before either lookup (CombatHooks' dead-address stamp).
function Utils.ForgetCauserAddr(addr)
    if not addr then return end
    causerNameCache[addr], causerIdCache[addr], causerInstCache[addr] = nil, nil, nil
end

-- True if a damage INSTIGATOR is an AI controller, i.e. the hit came from an NPC rather than a
-- player. The game asks the same question the same way (ProcessDamage's InvincibleToNPCs early-out
-- is ClassIsChildOf(Instigator, Abiotic_AI_Controller_ParentBP_C)); every AI controller in the game
-- carries "AI_Controller" in its path, and the player's is Abiotic_PlayerController_C.
--   * Cached by ADDRESS, because a per-hit GetFullName is a real cost in a crowd. A controller
--     outlives its fights, so this derefs about once per NPC.
local aiInstCache, aiInstCount = {}, 0
function Utils.IsAIInstigator(instigator)
    if not instigator then return false end
    local addr
    pcall(function() if instigator.GetAddress then addr = instigator:GetAddress() end end)
    if addr and aiInstCache[addr] ~= nil then return aiInstCache[addr] end

    if not IsValid(instigator) then return false end
    local isAI = false
    pcall(function()
        local fn = instigator:GetFullName()
        isAI = fn ~= nil and tostring(fn):find("AI_Controller") ~= nil
    end)
    if addr then
        aiInstCount = aiInstCount + 1
        if aiInstCount > 512 then aiInstCache, aiInstCount = {}, 1 end
        aiInstCache[addr] = isAI
    end
    return isAI
end

-- Rich damage debug line (gate the call with SETTINGS.DEBUG_DAMAGE_NPC / _PLAYER).
--   * damageType is a the processDamage hook param
--   * damageCauser is nil for buff/radiant/environmental damage
function Utils.LogDamage(victim, causer, damageType)
    if Utils.IsActorInvalid(victim) then return end

    -- Damage-type name (display name, else the row FName)
    local typeStr = "?"
    local dt = damageType
    if dt and dt.get then dt = dt:get() end
    if dt and IsValid(dt) then
        pcall(function()
            typeStr = dt.DamageTypeDisplayName:ToString()
            -- No display name (Bleeding, FallDamage...): the CDO name reads
            -- "Default__DamageType_Bleeding_C" - keep just the type word.
            if typeStr == "" then
                typeStr = dt:GetFName():ToString():gsub("^Default__", ""):gsub("^DamageType_", ""):gsub("_C$", "")
            end
        end)
    end

    -- Raw incoming damage for this hit
    local damage = 0
    pcall(function()
        damage = victim.LastPointDamage.IncomingDamage_13_40FC659E429FC966D1A7919E7D20512A or 0
    end)
    damage = math.floor(damage + 0.5)

    -- Source: the causing actor, or a [type/no-causer] tag for buff/environmental.
    -- DamageCauserName = the GC-hardened cached resolve (see above) - never a fresh
    -- DisplayName deref on a possibly-freed DoT causer.
    local srcName, srcId = Utils.DamageCauserName(causer)
    local source = srcName and (srcName .. (srcId or "")) or ("[" .. typeStr .. " / no causer]")

    -- HP remaining. GetTotalHealth() is the AUTHORITATIVE read - it sums the limb map, which is
    -- what the damage pipeline actually writes.
    --   * Do NOT switch this to printing CurrentHealth_Head/_Torso: nothing in the game's BP source
    --     writes those two properties. They're a stale replicated snapshot that lags the limb map
    --     and can make health look like it bounces back up mid-fight. Still printed as a secondary.
    --   * MAX is printed beside it because the limb map is populated LAZILY - until a hit actually
    --     reaches health, all three reads show the DT row's numbers, not this variant's. So
    --     `hp=1750/1000` is a body whose health has never been touched, NOT a 1750 HP NPC. Reading
    --     that as the real pool is what makes an un-statted body and a shielded one look identical.
    local hp, maxHp = -1, -1
    pcall(function() hp = math.floor((victim:GetTotalHealth() or 0) + 0.5) end)
    pcall(function() maxHp = math.floor((victim:GetMaxTotalHealth() or 0) + 0.5) end)
    local headHP, torsoHP = -1, -1
    pcall(function() headHP  = math.floor((victim.CurrentHealth_Head  or 0) + 0.5) end)
    pcall(function() torsoHP = math.floor((victim.CurrentHealth_Torso or 0) + 0.5) end)

    -- A body shield eats the WHOLE hit (CLAUDE.md 5), so an absorbed hit never reaches the limb
    -- map and the HP above does not move. Naming it is the difference between "this NPC shrugged
    -- off 9 damage" and "this NPC has a shield up" - the read of the numbers, not the numbers.
    local shieldStr = ""
    pcall(function()
        local sc = victim.BodyShieldComponent
        if IsValid(sc) and sc.IsShieldComponentEnabled then
            local cur = math.floor((sc.CurrentShieldHitPoints or 0) + 0.5)
            if cur > 0 then shieldStr = string.format(" shield=%d", cur) end
        end
    end)
    local absorbed = false
    pcall(function() absorbed = victim.BodyShieldAbsorbedLastHit == true end)

    -- WHICH ONE. Two NPCs of the same variant produce two identical labels, and their interleaved
    -- lines read as one actor's health jumping around. The instance suffix off GetFullName
    -- ("..._C_2147482309") is unique per actor, so a per-actor series is legible at a glance.
    local id = ""
    pcall(function()
        local fn = victim:GetFullName()
        local inst = fn and fn:match("_(%d+)$")
        if inst then id = "#" .. inst:sub(-4) end
    end)

    Utils.Log(string.format("[%s%s hp=%d/%d (%d|%d)%s] - %s %d %s damage from %s",
        Utils.GetActorName(victim) or "?", id, hp, maxHp, headHP, torsoHP, shieldStr,
        absorbed and "SHIELD ate" or "took", damage, typeStr, source))
end

-- Remove a buff/debuff from an actor (server-side). *** OFF-HOOK, exactly like AddBuff. ***
--   * A remove is not cheaper than an apply: it runs the buff's own end logic, and
--     MakeBuffDebuffRowHandle does a DT row lookup - buff objects load BY ROW NAME (the
--     debuff-preload trap, CLAUDE.md 6), so a cold one blocking-loads and deadlocks in-hook.
--   * Routing through applyBuffOffHook also re-resolves the component BY PATH across the EIGT
--     boundary, so a freed wrapper can never reach the setter (§3).
--   * `limb` (EBodyLimbs, default AllBones) - the limb-scoped rows (fractures, breaks, bleeds)
--     are stored per limb and the game removes them by naming that limb, so pass the value
--     Utils.ActorBuffLimbs reported rather than assuming a whole-body row.
function Utils.RemoveBuff(actor, buff, limb)
    local onLimb = limb or 0
    applyBuffOffHook(actor, nil, function(comp)
        -- Server_ForceRemoveBuff takes an FName BuffID (+ a nil struct handle) - same shape as
        -- AddBuff's Server_TryApplyBuff.
        --   * The other overload, Server_RemoveBuff, takes ONLY an FBuffDebuffRowHandle STRUCT -
        --     passing it an FName silently no-ops, which is why RemoveBuff never worked
        --     (player stun, Big Bot Unstun...).
        -- Args: BuffID, BuffRow(nil), RemoveEntireStack, Limb, ForceRemoveTraits
        pcall(function() comp:Server_ForceRemoveBuff(FName(buff), nil, true, onLimb, false) end)
        -- ALSO try the STRUCT overload: some buffs (e.g. Debuff_BeeSwarm, a linked HPDamage
        -- buff) ignore ForceRemoveBuff and only respond to Server_RemoveBuff(handle) - which is
        -- exactly how BeeSwarm removes itself in its own tick. Build the handle like ApplyBuffLinked.
        pcall(function()
            if IsNotValid(buffHandleLib) then
                buffHandleLib = StaticFindObject("/Script/AbioticFactor.Default__BuffDebuffHandleFunctionLibrary")
            end
            if IsValid(buffHandleLib) then
                local handle = buffHandleLib:MakeBuffDebuffRowHandle(FName(buff))
                comp:Server_RemoveBuff(handle, true, onLimb, false)
            end
        end)
    end, "buffremove", buff)
end

-- [AUTHORITY] Teleport a PLAYER, OFF-HOOK. The ONE place that calls the native TeleportPlayer;
-- fire-and-forget (the hop is deferred - no return value), it LOGS failures instead.
--   * MUST be off-hook (a §2 deadlock, not a nicety): a PLAYER teleport engages level-streaming /
--     freeze-jail / loading-screen machinery, which cold-loads - inside a hook that's a re-entrant
--     freeze with no crash dump. There is no safe "short in-arena hop"; every caller is safe by
--     construction because the EIGT lives here, once.
--   * `rot` is the ACTOR rotation; the camera (control rotation) is pushed separately below.
function Utils.TeleportPlayer(player, loc, rot, opts)
    if Utils.IsActorInvalid(player) or not loc then return end
    opts = opts or {}

    local force      = opts.Force ~= false          -- default TRUE (a scripted teleport is forced)
    local skipAdjust = opts.SkipAdjustment == true  -- default false = collision-aware K2_TeleportTo
    local exitChairs = opts.ExitChairs ~= false     -- default TRUE (never strand a seated player)

    -- Capture as plain NUMBERS + a path: a wrapper (player, FVector, FRotator) captured across
    -- the EIGT boundary can be freed, and IsValid lies about it (§3) - re-resolve the player BY
    -- PATH inside the hop and rebuild the vectors there.
    local x, y, z = loc.X, loc.Y, loc.Z
    local pitch, yaw, roll = 0, 0, 0
    if rot then pitch, yaw, roll = (rot.Pitch or 0), (rot.Yaw or 0), (rot.Roll or 0) end

    local path = Utils.ObjectPath(player)
    if not path then return end

    -- Stamp the ledger at the DECISION, not after the hop: a second yanker deciding this frame has
    -- to see the claim, and the hop is a frame away. A declined teleport costs one quiet debounce.
    local tkey = Utils.ActorKey(player)
    if tkey then STATE.PlayerTeleportTicks[tkey] = STATE.FAST_TICK end

    ExecuteInGameThread(function()
        local p = Utils.ResolveByPath(path)
        if IsNotValid(p) then return end

        local dest = FVector(x, y, z)
        local face = FRotator(pitch, yaw, roll)      -- FRotator is (Pitch, Yaw, Roll)

        -- TeleportPlayer(DestLocation, DestRotation, Force, SkipAdjustment, ExitChairs) -> bool
        --   * Its failure paths are SILENT: it bails without moving anyone if the player is
        --     currently GRABBED (it just breaks the grab), and a pcall'd call returning false
        --     looks exactly like success - so log both.
        local ok, moved = pcall(function()
            return p:TeleportPlayer(dest, face, force, skipAdjust, exitChairs)
        end)
        if not ok then
            Utils.LogBad("TeleportPlayer - call errored: " .. tostring(moved))
            return
        end
        if moved == false then
            Utils.LogBad("TeleportPlayer - declined by the game (player grabbed?)")
            return
        end

        -- The camera follows the CONTROL rotation, not the actor rotation - push it too.
        pcall(function()
            local c = p:GetController()
            if c and c:IsValid() then c:Client_ForceControlRotation(face) end
        end)
    end)
end

-- True when an NPC is alive and able to act (not dead/DBNO/stunned, in combat)
function Utils.IsActorReadyToAttack(actor)
    return Utils.IsActorValid(actor)
        and not actor.IsDead
        and not actor.IsDBNO
        and not actor.Stunned
        and actor.CombatState == true
end

-- Return the actors attached to `actor` (e.g. subactors like the Chopinator).
-- Returns a (possibly empty) array of wrappers; index with a:get().
function Utils.GetAttachedActors(actor)
    if Utils.IsActorInvalid(actor) then return {} end
    local attached = {}
    pcall(function() actor:GetAttachedActors(attached, false, true) end)
    return attached
end

-- Kill (not destroy) the NPC subactors attached to `actor`. Deployable
-- subactors (no IsDead) are left for the caller to destroy.
function Utils.KillAttachedActors(actor)
    for _, a in ipairs(Utils.GetAttachedActors(actor)) do
        local sub = a:get()
        -- pcall the whole block: deployable subactors (Chopinator) may not
        -- have an IsDead property, and reading/writing a missing one can throw.
        pcall(function()
            if sub and Utils.IsActorValid(sub) and not sub.IsDead and not sub.Invincible then
                sub.IsDead = true
                sub:OnRep_IsDead()
            end
        end)
    end
end

-- Destroy the actors attached to `actor` (hide + decollide first). Used to
-- clean up deployable subactors (Chopinator) when their carrier dies.
function Utils.DestroyAttachedActors(actor)
    for _, a in ipairs(Utils.GetAttachedActors(actor)) do
        local sub = a:get()
        if sub and Utils.IsActorValid(sub) then
            pcall(function()
                sub:SetActorHiddenInGame(true)
                sub:SetActorEnableCollision(false)
                sub:K2_DestroyActor()
            end)
        end
    end
end


-- ==========================================================
-- Coordinates
-- ==========================================================

function Utils.RoundedLocation(loc)
    return FVector(
        math.floor((loc.X or 0) + 0.5),
        math.floor((loc.Y or 0) + 0.5),
        math.floor((loc.Z or 0) + 0.5)
    )
end

function Utils.PrintRoundedLocation(loc)
    local r = Utils.RoundedLocation(loc)
    return r.X .. "," .. r.Y .. "," .. r.Z
end

function Utils.DistSq(a, b)
    local dx = (a.X or 0) - (b.X or 0)
    local dy = (a.Y or 0) - (b.Y or 0)
    local dz = (a.Z or 0) - (b.Z or 0)
    return dx * dx + dy * dy + dz * dz
end

function Utils.WithinDistance(a, b, targetDistance)
    return Utils.DistSq(a, b) <= targetDistance * targetDistance
end

-- HORIZONTAL (XY-only) squared distance - ignores Z entirely.
--   * Use whenever the two actors are at very different HEIGHTS but you only care how far apart
--     they are on the FLOOR PLAN: a ceiling-clinging NPC vs a player below it, a turret on a
--     catwalk, a drop/aggro radius in a room with a variable-height ceiling.
--   * A plain 3D DistSq would add the (arbitrary) ceiling height into the distance, so a tall room
--     silently shrinks the effective radius - a player directly underneath can read as "far away".
--   * Same squared units as Utils.DistSq (compare against d*d).
function Utils.DistSqXY(a, b)
    local dx = (a.X or 0) - (b.X or 0)
    local dy = (a.Y or 0) - (b.Y or 0)
    return dx * dx + dy * dy
end

-- Trivial wrapper over DistSqXY (trader placement / walk-in arrival checks).
function Utils.WithinDistanceXY(a, b, targetDistance)
    return Utils.DistSqXY(a, b) <= targetDistance * targetDistance
end

-- Unit vector of v (FVector). Returns (0,0,0) for a near-zero vector.
function Utils.GetSafeNormal(v)
    local mag = math.sqrt((v.X or 0)^2 + (v.Y or 0)^2 + (v.Z or 0)^2)
    if mag < 0.0001 then return FVector(0, 0, 0) end
    return FVector(v.X / mag, v.Y / mag, v.Z / mag)
end

-- Normalized direction FROM origin TOWARD destination.
function Utils.Direction(origin, destination)
    return Utils.GetSafeNormal(FVector(
        (destination.X or 0) - (origin.X or 0),
        (destination.Y or 0) - (origin.Y or 0),
        (destination.Z or 0) - (origin.Z or 0)
    ))
end

-- Random point in a square around origin (no navmesh check)
function Utils.FuzzLocation(origin, radius)
    local x = origin.X + math.random(-radius, radius)
    local y = origin.Y + math.random(-radius, radius)
    return FVector(math.floor(x + 0.5), math.floor(y + 0.5), math.floor(origin.Z + 0.5))
end

-- Find a reachable navmesh point within [minRadius, radius] of origin (a real nav-path query - the
-- same one the game's Leyak/stalker placement uses; safer than driving EQS from Lua).
--   * Synchronous; reads a single FVector out-param.
--   * Falls back to ring-point projection then FuzzLocation, so it NEVER returns nil.
--   * `yaw` (optional, degrees) = the FACING to spawn with. It doesn't affect where the point is
--     chosen; it just comes back as a ready-to-use FRotator in the SECOND return value, so a caller
--     can hand it straight to a spawn's opts.Rotation:
--         local spot, rot = Utils.GetSpawnPoint(origin, 150, nil, nil, nil, nil, yaw)
--         NpcSpawner.SpawnNpc(row, spot, { Rotation = rot, ... })
--     Grab a yaw in-game with the [CTRL][L] location keybind, which prints it. Omit it and the
--     second return is nil, so every existing single-return caller is unaffected.
function Utils.GetSpawnPoint(origin, radius, minRadius, retries, maxZDelta, zClearance, yaw)
    retries    = retries    or 25
    minRadius  = minRadius  or 0
    maxZDelta  = maxZDelta  or 250
    zClearance = zClearance or 100

    if minRadius >= radius then minRadius = 0 end
    if radius <= 0 then radius = 1000 end

    local rot = yaw and FRotator(0, yaw, 0) or nil

    local world = GetWorld()
    if IsNotValid(world) then return Utils.FuzzLocation(origin, radius), rot end

    local navSys = getNavSystem()
    if IsNotValid(navSys) then return Utils.FuzzLocation(origin, radius), rot end

    -- Snap origin to the navmesh so distance checks are meaningful
    local searchCenter = FVector(origin.X, origin.Y, origin.Z)
    local snapped = FVector()
    local snappedOk = navSys:K2_ProjectPointToNavigation(
        world, origin, snapped, nil, nil, FVector(600, 600, 600))
    if snappedOk then searchCenter = snapped end

    -- Reachable-point query (result has a nav path from center)
    for _ = 1, retries do
        local candidate = FVector()
        local ok = navSys:K2_GetRandomReachablePointInRadius(
            world, searchCenter, candidate, radius, nil, nil)
        if ok then
            local zDiff = math.abs(candidate.Z - searchCenter.Z)
            if Utils.DistSq(candidate, searchCenter) >= minRadius * minRadius
                and zDiff <= maxZDelta then
                candidate.Z = candidate.Z + zClearance
                return candidate, rot
            end
        end
    end

    -- Fallback: projected ring point
    for _ = 1, retries do
        local angle = math.random() * math.pi * 2
        local dist = math.random(minRadius, radius)
        local pt = FVector(
            searchCenter.X + math.cos(angle) * dist,
            searchCenter.Y + math.sin(angle) * dist,
            searchCenter.Z + 50)

        local projected = FVector()
        local ok = navSys:K2_ProjectPointToNavigation(
                    world, pt, projected, nil, nil, FVector(300, 300, 400))
        if ok and math.abs(projected.Z - searchCenter.Z) <= maxZDelta then
            projected.Z = projected.Z + zClearance
            return projected, rot
        end
    end

    if snappedOk then
        snapped.Z = snapped.Z + zClearance
        return snapped, rot
    end
    return Utils.FuzzLocation(origin, radius), rot
end


-- Drop a HAND-AUTHORED point straight onto the navmesh beneath it. Returns the point (+ zClearance),
-- or nil if there is no navmesh within the vertical extent.
-- *** THIS IS THE ONE TO USE FOR A SCRIPTED COORD. Utils.GetSpawnPoint IS NOT. ***
--   * GetSpawnPoint means "put a body somewhere near here": it snaps to the navmesh with a +/-600
--     Z extent (the floor above/below on a multi-storey map) and then picks a RANDOM reachable
--     point within `radius` - wrong for an exact authored coord.
--   * zExtent defaults to 150 (less than a storey) so a miss returns nil instead of lying; for a
--     spawn, falling back to the authored point is usually right (EVU.SpawnAt's Exact path does).
function Utils.ProjectToNav(loc, zExtent, zClearance)
    if not loc then return nil end
    zExtent    = zExtent    or 150
    zClearance = zClearance or 100

    local world = GetWorld()
    if IsNotValid(world) then return nil end

    local navSys = getNavSystem()
    if IsNotValid(navSys) then return nil end

    local out = FVector()
    local ok = navSys:K2_ProjectPointToNavigation(
        world, loc, out, nil, nil, FVector(200, 200, zExtent))
    if not ok then return nil end

    return FVector(out.X, out.Y, out.Z + zClearance)
end


-- Walking distance between two navmesh points: "can something get from here to there", which
-- being on the navmesh does not answer (a sealed room, a mezzanine).
--   * Returns the length; FALSE for no complete path (none, or partial - the pathfinder gave up
--     short); NIL when the query itself is unavailable, so the caller picks how to fail.
--   * FindPathToLocationSynchronously, not GetPathLength: that one has a double& out-param, and an
--     out-param call that omits its outs is a silent no-op. Precedent: EnemyAtTheGATE's HasPathTo.
--   * Both points must be FVector userdata - the params are const-ref.
function Utils.NavPathLength(fromLoc, toLoc)
    if not fromLoc or not toLoc then return nil end

    local world = GetWorld()
    if IsNotValid(world) then return nil end

    local navSys = getNavSystem()
    if IsNotValid(navSys) then return nil end

    local ok, len = pcall(function()
        local path = navSys:FindPathToLocationSynchronously(world, fromLoc, toLoc, nil, nil)
        if not path or IsNotValid(path) or not path:IsValid() or path:IsPartial() then return false end
        return path:GetPathLength()
    end)
    if not ok then return nil end
    return len
end



-- ==========================================================
-- WorldFlag/Story related
-- ==========================================================

-- Get Current world difficulty (0=Easy, 3=Apocalyptic)
--   Using this because some NPCs will act differently. e.g. Pests leap slower
local DIFFICULTY_LIB = "/Game/Blueprints/Libraries/AbioticFunctionLibrary.Default__AbioticFunctionLibrary_C"
function Utils.GetDifficulty()
    -- Through ASSETS (immortal-listed) so the CDO resolve is a table hit after the first call -
    -- a bare StaticFindObject here re-walked the whole UObject array per call. Lazy require:
    -- AssetManager requires Utils.
    local lib = require("AnteCore.AssetManager").GetIfValid(DIFFICULTY_LIB)
    if IsNotValid(lib) then return 3 end

    local world = GetWorld()
    if IsNotValid(world) then return 3 end

    -- GetCurrentDifficulty(WorldContext, int32& out) - UE4SS returns the out
    local ok, diff = pcall(function() return lib:GetCurrentDifficulty(world) end)
    if ok and type(diff) == "number" then return diff end
    return 3
end

function Utils.HasWorldFlag(name)
    local row = SCHEMA.MakeHandle(name,
        { DataTablePath = "/Game/Blueprints/DataTables/DT_WorldFlags.DT_WorldFlags" })
    local worldFlagSubsystem = Utils.GetWorldFlagSubsystem()
    if IsNotValid(worldFlagSubsystem) then return end

    local world = Utils.GetWorld()
    if not world then return end

    return worldFlagSubsystem:HasWorldFlag(world, row)
end

-- ==========================================================
-- Spawner identity
-- * Spawner object names differ between sessions, but their placed
--   location is constant - so the location IS the spawner's name.
-- ==========================================================

-- "X,Y,Z" with negatives stripped, e.g. (-18751, 11181, 10) -> "18751,11181,10"
function Utils.GetSpawnerName(spawner)
    if IsNotValid(spawner) then return nil end

    local loc = Utils.RoundedLocation(spawner:K2_GetActorLocation())
    return math.abs(loc.X) .. "," .. math.abs(loc.Y) .. "," .. math.abs(loc.Z)
end


-- ==========================================================
-- Scheduling (Queues and Delayed work)
-- ==========================================================

-- How far ahead of FAST_TICK a stagger cursor may legitimately sit (~60s). A world-load spawn
-- wave is the widest real burst and is nowhere near this; anything past it is a broken cursor.
local SLOT_MAX_BACKLOG_TICKS = 600


-- Default way to defer actor work
--   * Schedule fn to run after delayMs on the game thread
--   * `quiet` = a known-benign REPEATER (a self-rearming poll). It still gets its src label and
--     still leaves the freeze breadcrumb, so a stall inside it is still named - it just doesn't
--     write the per-item "FT wq" LINE. Without this a 250ms poll writes 4 lines/sec forever and
--     buries the one line that matters in a freeze log. Use it ONLY for loops whose body is a
--     couple of property reads; anything that can spawn, load or damage stays loud.
function Utils.QueueWork(fn, delayMs, quiet)
    if not fn then return end
    local ticks = math.max(1, math.ceil((delayMs or 0) / 100))
    local item = {
        fn     = fn,
        fireAt = STATE.FAST_TICK + ticks,
        quiet  = quiet or nil,
    }
    -- Label the item by the queued function's source line (getinfo runs once per queue) -
    -- for the profiler's cost attribution AND the freeze-trace pre-log/breadcrumb
    -- (TickManager drain), which needs the label even when profiling is off.
    local PROF = require("AnDebug.Profiler")
    if PROF.Enabled or require("Settings").DEBUG_FREEZE_TRACE then item.src = PROF.SrcOf(fn) end
    table.insert(STATE.WorkQueue, item)
end

-- Claim the next free slot on a FAST_TICK stagger cursor. Returns the advanced cursor and the
-- QueueWork delay that lands on it, so a caller's only state is the cursor itself.
--   * The cursor is a FAST_TICK, and FAST_TICK restarts at 0 every world. A cursor carried over
--     from the previous world therefore names a tick this world reaches hours from now, and every
--     spawn queued against it parks in the WorkQueue forever. ResetState zeroes the three live
--     cursors; SLOT_MAX_BACKLOG_TICKS is the net under that, and also caps a genuine runaway.
function Utils.ClaimSlotTick(cursor, spacing, maxBacklogTicks)
    local now = STATE.FAST_TICK
    cursor = cursor or 0
    local maxAhead = maxBacklogTicks or SLOT_MAX_BACKLOG_TICKS
    if cursor > now + maxAhead then
        Utils.LogBad(string.format(
            "Stagger cursor was %d ticks ahead of tick %d - snapping to now (stale cross-world cursor, or a runaway queue)",
            cursor - now, now))
        cursor = now
    end
    cursor = math.max(cursor, now) + (spacing or 1)
    return cursor, (cursor - now) * 100
end

-- REAL elapsed ms (wall time since process start; MSVC os.clock, ~1ms resolution).
--   * USE THIS FOR ANY DEADLINE A SELF-RESCHEDULING QueueWork LOOP ENFORCES. Counting passes
--     ("500ms cadence x N") measures the DRAIN, not the clock: the drain is newest-first and
--     capped at SETTINGS.CORE.WORKQUEUE_MAX_PER_TICK, so under load a 500ms pass takes seconds -
--     a hold timer counting passes instead of wall time can run several times its intended length.
--   * NOT a game clock: it keeps running while the game is paused, and it is per-process, so it is
--     no good for anything persisted. For a cadence in WQ ticks, use STATE.FAST_TICK.
function Utils.NowMs()
    if os and os.clock then return os.clock() * 1000 end
    return STATE.FAST_TICK * 100   -- no wall clock: fall back to the nominal tick count
end

-- UE4SS's own game-thread delay (3.0.1 builds from -1136 on). nil on an older UE4SS.
local gameThreadDelay = type(ExecuteInGameThreadWithDelay) == "function" and ExecuteInGameThreadWithDelay or nil

-- Delay, then run on the game thread, on a clean engine-tick pump. Slightly riskier than QueueWork
-- for held pointers (extra hop) but works when the tick isn't running yet.
--   * IT IS ALSO THE ONLY REAL ESCAPE FROM A HOOK FRAME. That is what makes a BeginPlay that
--     blocking-loads survivable - see NpcSpawner's OFFHOOK_ROWS (the Reaper wedge).
--   * ExecuteInGameThreadWithDelay never leaves the game thread. The older route, ExecuteWithDelay
--     and then ExecuteInGameThread from the worker, made UE4SS push the callback onto the game
--     thread's shared hook Lua stack FROM THE WORKER, while game-thread C code could be mid-way
--     through that stack - a dedicated server died in an error traceback reading a key as a table.
--     It is kept only for a UE4SS without the new call.
--   * UE4SS rejects a float delay ("No overload found"), and a division always makes one.
--   * Call it from the game thread: from a worker, the new call makes the same push.
function Utils.DelayedGameThread(ms, fn)
    if not fn then return end
    local delay = math.max(0, math.floor((tonumber(ms) or 0) + 0.5))
    local function run()
        local ok, err = pcall(fn)
        if not ok then Utils.LogBad("[DelayedGameThread] " .. tostring(err)) end
    end
    -- It throws when neither of its engine hooks is available; boot (MAIN.Start) must still run then.
    if gameThreadDelay and pcall(gameThreadDelay, delay, run) then return end
    ExecuteWithDelay(delay, function() ExecuteInGameThread(run) end)
end

-- [UNUSED] no live callers; thin pcall'd EIGT wrapper, kept as API.
function Utils.RunOnGameThread(fn)
    ExecuteInGameThread(function()
        local ok, err = pcall(fn)
        if not ok then Utils.LogBad("[GameThread] " .. tostring(err)) end
    end)
end

-- =======================================================================
-- FREEZE-TRACE LINE - the "FT wq/eigt <src>" pre-log that names a wedged item if the watchdog can't.
--   * One line per source per FREEZE_TRACE_LINE_GAP_SEC. Runs in between fold into a count on that
--     source's next line, so a 4/s poll no longer buries the rare item the trace exists to name.
--   * Only the LINE folds. Callers still stamp STATE.LastWork on every run, so a folded repeater
--     that wedges is still named by the watchdog.
--   * Timed on os.clock, since FAST_TICK restarts every world.
-- =======================================================================
local traceLines = {}   -- "wq <src>" -> { t, folded }

function Utils.FreezeTraceLine(kind, src)
    local key = kind .. " " .. (src or "?")
    local gap = require("Settings").FREEZE_TRACE_LINE_GAP_SEC or 30
    local now = os.clock()
    local e = traceLines[key]
    if e and gap > 0 and now - e.t < gap then
        e.folded = e.folded + 1
        return
    end
    local folded = e and e.folded or 0
    if e then e.t, e.folded = now, 0 else traceLines[key] = { t = now, folded = 0 } end
    Utils.LogDebug("FT " .. key .. (folded > 0 and ("  (+" .. folded .. " folded)") or ""), true)
end

-- =======================================================================
-- EIGT FREEZE-TRACE. ExecuteInGameThread callbacks run on UE4SS's own engine-tick pump, not through
-- any hooked UFunction - so unlike the WQ drain (which pre-logs "FT wq <src>") a crash inside one
-- died anonymous, with no log line and no Lua strings in the minidump
-- ([[anteup2-ue4ss-findobject-scan-crash]]). Under DEBUG_FREEZE_TRACE the global is wrapped once so
-- every EIGT callback pre-logs "FT eigt <file:line>" and stamps STATE.LastWork like the WQ drain,
-- naming itself if it wedges or crashes. Flag off = the raw global runs untouched.
--   * The raw fn is parked in _G so /reload re-wraps the ORIGINAL, not a layer on a layer.
--   * SrcOf runs once at schedule time; the pcall logs a traced callback's own error (with source)
--     instead of surfacing as UE4SS's anonymous "[Lua] error", and keeps LastWorkDone honest.
if not _G.__ANTE_RAW_EIGT then _G.__ANTE_RAW_EIGT = ExecuteInGameThread end
local rawEIGT = _G.__ANTE_RAW_EIGT
ExecuteInGameThread = function(fn)
    if not fn or not require("Settings").DEBUG_FREEZE_TRACE then return rawEIGT(fn) end
    local src = require("AnDebug.Profiler").SrcOf(fn)
    rawEIGT(function()
        Utils.FreezeTraceLine("eigt", src)
        STATE.LastWork = "EIGT " .. src
        STATE.LastWorkDone = false
        local ok, err = pcall(fn)
        STATE.LastWorkDone = true
        if not ok then Utils.LogBad("EIGT error (" .. src .. "): " .. tostring(err)) end
    end)
end


-- ==========================================================
-- Replicated particle FX (shows on clients + listen host; the dedicated
-- server has no renderer so it only spawns/replicates the actor).
--   * Uses the game's own ReplicatedParticleFX_BP actor; its ActivateFX is a reliable NetMulticast
--     that plays a Niagara + sound on every client.
--   * The game only ever PLACES these in levels, so a runtime spawn must be forced always-relevant
--     + awake or it never reaches clients.
-- ==========================================================

local REPLICATED_FX_CLASS = "/Game/Blueprints/Environment/Effects/ReplicatedParticleFX_BP.ReplicatedParticleFX_BP_C"

-- Game thread. fxClass is loaded; `assets` maps any override path -> asset.
local function spawnReplicatedFXActor(fxClass, location, opts, assets)
    local world = Utils.GetWorld()
    local gs    = UEHelpers.GetGameplayStatics()
    local kMath = UEHelpers.GetKismetMathLibrary()
    if IsNotValid(world) or not gs or not kMath then return nil end

    local rotation  = opts.Rotation or FRotator(0, 0, 0)
    local scale     = opts.Scale or FVector(1, 1, 1)
    local transform = kMath:MakeTransform(location, rotation, scale)

    -- 2 = AdjustIfPossibleButAlwaysSpawn
    local actor = gs:BeginDeferredActorSpawnFromClass(world, fxClass, transform, 2, nil, 0)
    if IsNotValid(actor) then
        Utils.LogBad("CreateEffect - deferred spawn failed")
        return nil
    end

    -- Force replication relevancy BEFORE FinishSpawning: bAlwaysRelevant defeats
    -- distance culling, NetDormancy=1 (DORM_Awake) keeps a cold-spawned actor
    -- from staying dormant and never reaching clients.
    pcall(function() actor.bAlwaysRelevant = true end)
    pcall(function() actor.NetDormancy = 1 end)

    -- Optional asset overrides (applied before BeginPlay's SetAsset). If a
    -- prop isn't replicated, remote clients fall back to the BP default (portal
    -- burst + portal_spawn sound) - fine for "show something at a location".
    if opts.Particle and IsValid(assets[opts.Particle]) then
        pcall(function() actor.ParticleEffect = assets[opts.Particle] end)
    end
    if opts.Sound and IsValid(assets[opts.Sound]) then
        pcall(function() actor.SoundToPlay = assets[opts.Sound] end)
    end

    -- Sound-only: clear the default portal-burst Niagara so BeginPlay's SetAsset(nil)
    -- has nothing to render and ActivateFX's PortalFX:Activate() is a no-op (the
    -- multicast still plays SoundToPlay). Use for a replicated SFX with no visual tell.
    if opts.NoParticle then
        pcall(function() actor.ParticleEffect = nil end)
    end

    actor = gs:FinishSpawningActor(actor, transform, 0)
    if IsNotValid(actor) then return nil end

    pcall(function() actor:SetReplicates(true) end)
    pcall(function() actor:FlushNetDormancy() end)

    -- ActivateFX is a reliable NetMulticast, but multicasts aren't buffered:
    -- a client whose actor channel isn't open yet when it fires MISSES it. Delay
    -- so the fresh actor replicates to nearby clients first.
    Utils.QueueWork(function()
        if IsValid(actor) then pcall(function() actor:ActivateFX() end) end
    end, opts.ActivateDelay or 800)

    -- Self-ending: auto-destroy after Lifetime (replicated destroy ends it on
    -- clients too). Omit Lifetime to own the cleanup via the returned actor /
    -- OnReady + Utils.EndEffect (e.g. close it when a buff/phase ends).
    if opts.Lifetime then
        Utils.QueueWork(function() Utils.EndEffect(actor) end, opts.Lifetime)
    end

    return actor
end

-- Spawn a replicated particle FX at a world location. AUTHORITY-only (it's a
-- replicated actor). opts:
--   Particle      - Niagara path override (default = BP portal burst)
--   Sound         - SoundWave path override (default = BP portal sound). NOTE the
--                   actor's SoundToPlay is typed USoundWave* - a SoundCue won't bind.
--                   ActivateFX plays it at a HARD-CODED volume 1.0, no attenuation.
--   NoParticle    - suppress the portal-burst visual (sound-only replicated SFX)
--   Rotation, Scale
--   Lifetime      - ms before auto-destroy (nil = caller owns cleanup)
--   ActivateDelay - ms before the ActivateFX multicast (default 800)
--   OnReady(actor)- gets the spawned actor (or nil); use it to EndEffect later
function Utils.CreateEffect(location, opts)
    if not Utils.IsAuthority() then return end
    if not location then return end
    opts = opts or {}
    local onReady = opts.OnReady or function(_) end

    -- Lazy require: AssetManager requires Utils, so a top-level require cycles.
    local ASSETS = require("AnteCore.AssetManager")

    local toLoad = { REPLICATED_FX_CLASS }
    if opts.Particle then toLoad[#toLoad + 1] = opts.Particle end
    if opts.Sound then toLoad[#toLoad + 1] = opts.Sound end

    ASSETS.LoadAsync(toLoad, function(results)
        local fxClass = results[REPLICATED_FX_CLASS]
        if IsNotValid(fxClass) then
            Utils.LogBad("CreateEffect - FX class failed to load")
            onReady(nil)
            return
        end

        local function doSpawn()
            local actor = spawnReplicatedFXActor(fxClass, location, opts, results)
            onReady(actor)
        end

        -- Dedicated Server - spawn off ProcessSpawns_Quick hook 
		--   * BeginPlay-SetAsset can deadlock
		-- Host/Client - use the work queue to run this off a clean game thread
        if STATE.Role == "DEDICATED" then
            ExecuteInGameThread(doSpawn)
        else
            Utils.QueueWork(doSpawn, 0)
        end
    end)
end

-- End a Utils.CreateEffect actor: stop its looping Niagara, then destroy it.
-- The replicated destroy ends the effect on clients too. AUTHORITY-only.
function Utils.EndEffect(actor)
    if Utils.IsActorInvalid(actor) then return end
    pcall(function()
        if IsValid(actor.PortalFX) then actor.PortalFX:Deactivate() end
    end)
    pcall(function() actor:K2_DestroyActor() end)
end


-- ==========================================================
-- State reset - called when leaving a world
-- ==========================================================

function Utils.ResetState()
    -- Persistent fields (hook/loop registration, Role) are NOT reset
    STATE.ModInitCalled = false
    STATE.ModEnabled = false
    STATE.WorldName = ""
    STATE.IsPaused = false
    STATE.GameState = nil
    singletonCache = {}   -- drop cached per-world singletons (nav/worldflags) so the next world re-finds (no stale slot)
    dayMgr = nil          -- same: the old world's DayNightManager, which IsNotValid can't tell is freed
    departed.at, departed.who, departed.count, departed.said = {}, {}, 0, nil   -- FAST_TICK stamps: a survivor reads as newly departed
    TAP.Stop()            -- a test's steps die with the WorkQueue below, so nothing else would stop it

    -- Same reason, for the AssetManager's TRUSTED cache entries (ASSETS.Immortal): they skip the
    -- StaticFindObject re-resolve, so one surviving into the next world IS a freed cross-world
    -- pointer. Lazy require - AssetManager requires Utils, so a top-level require here cycles.
    pcall(function() require("AnteCore.AssetManager").ResetWorld() end)

    -- And the ClientFX teardown book, for the identical reason: it HOLDS COMPONENT WRAPPERS (that is
    -- what buys it one UObject-array walk per effect instead of ~50ms each), so an entry surviving
    -- into the next world is a freed cross-world pointer. Lazy require - ClientFX requires Utils.
    pcall(function() require("AnteUtils.ClientFX").ResetBook() end)

    -- Ceiling-verify map: its verdicts are old-world COORDS, and its freshness stamps are
    -- FAST_TICKs - which restart at 0 below, so a survivor would also read as newly-stamped
    -- forever (the BarrierPings clock hazard). Lazy require - AVUtils requires Utils.
    pcall(function() require("AnteUtils.AVUtils").ResetCeilingMap() end)

    -- And the subactor book (AVAttach), which HOLDS the subactor + carrier WRAPPERS strongly - that
    -- is the whole point of it, since the OnTick entry it backs up is wiped a few lines below. Same
    -- reason as the two above: an entry surviving into the next world is a freed cross-world
    -- pointer, and the sweep would hand it to K2_DestroyActor.
    pcall(function() require("AnteUtils.AVUtils").ResetSubactorBook() end)

    -- The three spawn-stagger cursors, for the same clock hazard as the ping tables below - but
    -- failing the other way. They are FAST_TICKs, FAST_TICK restarts at 0 on the next line, and a
    -- cursor left at the old world's final tick makes every NPC, item and projectile queue against
    -- a tick hours away: nothing spawns again for the rest of the session.
    pcall(function() require("AnteCore.NpcSpawner").ResetSlotCursor() end)
    pcall(function() require("AnteCore.ItemSpawner").ResetSlotCursor() end)
    pcall(function() require("AnteCore.Projectile").ResetSlotCursor() end)

    -- And the damage-scaling one-pass book, whose stamps are FAST_TICKs for the same reason: a
    -- survivor reads as stamped on the new world's first frame, and the hit it matches would go
    -- through unresisted.
    pcall(function() require("AnteVariants.CombatHooks").ResetScalePass() end)

    STATE.FAST_TICK = 0
    STATE.WorkQueue = {}        -- closures here capture actors strongly
    STATE.OnTickActors = {}     -- holds NPC wrappers strongly
    STATE.AggroBait = nil       -- pooled AttackMove bait: drop the old-world wrapper (re-spawned on next use)
    STATE.OnTickCombatStart = {}
    STATE.ShieldWalls = {}      -- same clock hazard, and the records hold component wrappers
    STATE.BarrierPings = {}     -- FAST_TICK resets to 0, so stale ping timestamps would read as "fresh"
    STATE.FallowPings = {}      -- same clock hazard as BarrierPings
    STATE.PlayerTeleportTicks = {}   -- same, and a survivor would read as the FAR FUTURE: yanks off forever
    STATE.SpawnerState = {}
    STATE.ArtilleryProfiles = {}   -- ActorKey-keyed, so old-world keys would never be collected
    STATE.SowRetreats = {}         -- same
    STATE.ClientSeenActors = {}
    STATE.ClientTagAttempts = {}
    STATE.ClientVisualsPending = {}
    STATE.ClientVisualsFails = {}
    STATE.ClientScanArmed = false
    STATE.ClientEffectsArmed = false
    STATE.PetManagerArmed = false
    STATE.WinterArmed = false
    STATE.DarkLensArmed = false -- its queued watcher loop just got wiped with the WorkQueue
    STATE.DarkLensArmedProps = false -- same, for that arena's prop guard (every role)
    STATE.DarkLensWitchArmed = false -- same, for the witch-arena watcher
    STATE.DarkLensJotunArmed = false -- same, for the heavy-arena watcher
    -- Shadow boss module: its director/boss/storm wrappers are per-world (its storm poll just got
    -- wiped with the WorkQueue). Lazy require - the module requires Utils.
    STATE.ShadowBossArmed = false
    pcall(function() require("ModuleShadow.ShadowBoss").Reset() end)

    -- Defense-bot projectile suppressor windows: FAST_TICK resets to 0 on world change, so a
    -- stale deadline from the old world would read as "armed" for its first ~seconds.
    STATE.SuppressDefenseBotUntil = 0
    STATE.SuppressDefBotClassUntil = {}

    -- Hard-mode weapon nerfs: pure Lua data, but drop it anyway so a world where the
    -- setting is off never inherits the last world's scales. HardMode.Register re-sets it.
    STATE.HardModeTypeScale = nil
    STATE.HardModeNoEnd = nil
    STATE.HardModeNoMercy = nil
    STATE.WeaknessStaggerGate = nil
    STATE.NoAggroAnimActors = {}
    STATE.NoBackstepActors = {}
    STATE.StaggerImmuneActors = {}
    levelProxy.of, levelProxy.carrierAt, levelProxy.count = {}, {}, 0

    -- Story events re-arm next world load; StoryData is reloaded by FileIO on Register.
    STATE.StoryArmed = false
    STATE.DirectorArmed = false -- its loop item just got wiped with the WorkQueue
    STATE.BenchCacheArmed = false -- the next world rebuilds its bench coords on first use
    STATE.StoryData = {}

    -- (Big Bot is a PlacedSpawn now - its live ref rides STATE.PlacedSpawnActors, cleared below.
    -- STATE.BigBotSpawnedEnemies is deliberately NOT reset: the welcome party is once per SESSION.)

    -- Hexed Tree stalker: disarm + drop the old-world tree ref so it can GC. Winter likewise:
    -- its loop's WorkQueue item just got wiped, so a stale armed-flag would block the re-arm
    -- (Winter.GateTick checks it) and kill the whiteouts for the whole next world.
    STATE.HexedTreeArmed = false
    STATE.HexedTreeManual = false
    STATE.HexedTreeActor = nil
    -- Its respawn/creak clocks are module-locals, and they are FAST_TICKs: one left over from the
    -- last world reads as a deadline hours out, so no tree would ever spawn again.
    pcall(function() require("AnteNPCs.HexedTreeStalker").ResetWorld() end)
    STATE.WinterArmed = false

    -- Synthetic-spawner live refs + last-known positions (the day-cooldown lives in StoryData,
    -- reloaded by FileIO). Old-world coords would send the next world's dedupe scan to a ghost anchor.
    STATE.PlacedSpawnActors = {}
    STATE.PlacedSpawnLastPos = {}

    -- Dev spawn-on-demand traders (drop the refs so old-world wrappers can GC).
    STATE.SpawnedTraders = {}

    -- Screen-tint blackout: the world change wipes the WorkQueue and so kills the re-assert beat.
    -- Leaving the flag set would invert the toggle AND leave the beat dead (the blackFogOn wart).
    STATE.ScreenTintOn = false
    STATE.ScreenTintColor = nil
    STATE.ScreenTintUntil = nil   -- a timed tint's deadline died with its beat

    Utils.Log("State reset")
end

return Utils
