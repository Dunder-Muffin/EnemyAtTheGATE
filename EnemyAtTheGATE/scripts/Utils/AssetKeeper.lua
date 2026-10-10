-- =======================================================================================
-- AssetKeeper - pins a small hot-set of assets against garbage collection.
-- Ported from AnteUp2's AnteCore/AssetKeeper; same mechanism, much smaller list.
--
-- WHY
--   * AssetManager caches a WRAPPER, never a hard ref, so UE GCs the asset the moment
--     nothing else refs it - and then GetIfValid returns nil until an async reload.
--     That's the "first portal of the session doesn't render" class of bug, and it comes
--     back every time the asset cycles out.
--   * A live component whose asset UPROPERTY points at the asset IS a hard ref. One
--     hidden, inert component per asset pins it for the whole loaded world.
--   * A pinned path is also TRUSTED by ASSETS.GetIfValid, so its lookups stop paying the
--     StaticFindObject UObject-array walk (~20-30 ms each on this build) - and stop
--     rolling the dice on that walk hitting a dangling Outer and AVing.
--   * GC reachability is global, not spatial. There is no range and nothing to saturate.
--
-- COST: memory. Each pin holds one asset (and for a CLASS pin, its CDO's defaults).
-- The curated list below is tiny; the class pins are capped (see MAX_CLASS_PINS).
--
-- LIFECYCLE: Establish on InitMod / ClientBootstrap, Release on StopMod.
--   * RENDERER-ONLY. Everything here targets FX and spawn assets on a machine that draws;
--     a dedicated server has no renderer and pins nothing.
--   * Per-machine and LOCAL - a runtime AddComponentByClass does not replicate.
--
-- ANCHOR: the Survival GameState. It lives for the whole world (survives death, respawn
-- and sublevel streaming), and components are added with bManualAttachment = true because
-- it is an AInfo with no scene root - a registered, owned component hard-refs its asset
-- without ever being attached or drawn.
--
-- NOTE: no `require("Utils.Utils")` here. Utils requires this file, so pulling it back in
-- would be a cycle. Logging is local.
-- =======================================================================================

---@diagnostic disable: undefined-field, undefined-global, param-type-mismatch

local AFUtils = require("AFUtils.AFUtils")
local STATE   = require("Data.STATE")
local Enums   = require("Data.Enums")
local ASSETS  = require("Utils.AssetManager")

local KEEPER = {}

local function log(msg)    print("[GATE] " .. tostring(msg) .. "\n") end
local function logBad(msg) print("[GATE][ERR] " .. tostring(msg) .. "\n") end


-- Native component classes. Always resident, never GC'd, so GetIfValid fast-paths them.
local CLASS_FOR = {
    NIAGARA = "/Script/Niagara.NiagaraComponent",
    -- UAudioComponent.Sound is a UPROPERTY, so setting it is a hard ref
    SOUND   = "/Script/Engine.AudioComponent",
    -- ChildActorClass (TSubclassOf<AActor>) is a UPROPERTY = a hard ref to the UCLASS.
    -- Written directly, POST-registration, so CreateChildActor never runs and no child
    -- actor is ever spawned. Pinning a class also pins its CDO and the CDO's own hard
    -- defaults (meshes, damage types) as one unit.
    CLASS   = "/Script/Engine.ChildActorComponent",
}


-- =======================================================================================
-- THE CURATED SET - the assets GATE re-resolves constantly and cannot afford to lose.
--
-- These are the portal doorways and their hold-open loops. They are:
--   * looked up on EVERY portal drop, on every renderer
--   * resolved through the deliberately non-loading GetIfValid, so a GC'd one is simply
--     SKIPPED - a portal that silently doesn't appear or is silent
-- Five small assets, pinned once per world. This is the case pinning is for.
-- =======================================================================================
KEEPER.KEEP = {
    { Enums.FX.PORTAL_DOOR,             "NIAGARA" },   -- GK rift doorway
    { Enums.FX.PORTAL_NIGHTREALM_DOOR,  "NIAGARA" },   -- Nightrealm doorway
    { Enums.FX.PORTAL_FRIENDLY,         "NIAGARA" },   -- rat portal
    { Enums.SOUNDS.PORTAL_SALEM,        "SOUND"   },   -- GK portal loop
    { Enums.SOUNDS.PORTAL_NIGHTREALM,   "SOUND"   },   -- Nightrealm portal loop
}

-- Cap on LAZY class pins (KEEPER.PinClass, called from Utils.SpawnNpc). Each NPC class
-- holds its CDO's default meshes and anim refs, so this is the one pin kind with real
-- weight - tens of MB across a full set, not hundreds. An assault touches a handful of
-- classes; this bound covers several assaults' worth and then stops growing. Past the
-- cap, new classes simply pay the normal lookup.
local MAX_CLASS_PINS = 24

local heldComponents = {}    -- live pin components, destroyed on Release
local classPins      = 0
local unpinnable     = {}    -- paths proven un-holdable: never retried
local established    = false

local pinnedPaths = ASSETS.Pinned   -- THE SAME TABLE, by reference. Cache-trust must
                                    -- appear exactly when the hard ref does, and vanish
                                    -- exactly when Release drops it.


-- Add one hidden, inert pin component to `anchor` holding `asset`. Returns it, or nil.
local function pin(anchor, asset, kind)
    local compClass = ASSETS.GetIfValid(CLASS_FOR[kind])
    if not compClass or IsNotValid(compClass) then return nil end

    -- bManualAttachment = true: the GameState has no scene root to attach to. A created,
    -- registered, owned component is all the pin needs.
    local ok, comp = pcall(function()
        return anchor:AddComponentByClass(compClass, true, FTransform(), false)
    end)
    if not ok or not comp or IsNotValid(comp) then return nil end

    -- Inert: no tick, no collision, invisible.
    pcall(function() comp:SetComponentTickEnabled(false) end)
    pcall(function() comp:SetVisibility(false, false) end)
    if IsNotValid(comp) or IsNotValid(asset) then return nil end

    if kind == "NIAGARA" then
        pcall(function() comp:SetAutoActivate(false) end)   -- hold the ref, never emit
        pcall(function() comp:SetAsset(asset, false) end)
        pcall(function() comp:Deactivate() end)

    elseif kind == "SOUND" then
        pcall(function() comp:SetAutoActivate(false) end)   -- hold the ref, never play
        pcall(function() comp:SetSound(asset) end)
        pcall(function() comp:Stop() end)

    elseif kind == "CLASS" then
        -- Direct field write, not SetChildActorClass - the setter would spawn a child.
        -- READ BACK: a silent no-op write would mark the path trusted in ASSETS.Pinned
        -- with no ref actually behind it, which is worse than not pinning at all.
        local held = false
        pcall(function()
            local name = asset:GetFullName()
            comp.ChildActorClass = asset
            held = comp.ChildActorClass:GetFullName() == name
        end)
        if not held then
            pcall(function() comp:K2_DestroyComponent(comp) end)
            return nil
        end
    end

    return comp
end


local function anchorActor()
    local gs = AFUtils.GetSurvivalGameState()
    if not gs or IsNotValid(gs) then return nil end
    return gs
end


-- =======================================================================================
-- PinClass - lazily pin an already-loaded asset by path (used for NPC classes).
--
-- Called from Utils.SpawnNpc once a class has actually loaded, so the first spawn of a
-- class pays the normal lookup and every later one is a trusted table hit. Cheap and
-- silent: no load, no retry, and a path that can't be held is remembered so it is never
-- attempted again.
--
-- ALL ROLES, unlike the KEEP set above. What this buys is the avoided object-array walk
-- per spawn, and a dedicated server spawns just as many NPCs as a host does - it simply
-- has no use for the portal FX.
-- =======================================================================================
function KEEPER.PinClass(path)
    if not path or pinnedPaths[path] or unpinnable[path] then return end
    if classPins >= MAX_CLASS_PINS then return end

    local anchor = anchorActor()
    if not anchor then return end

    local asset = ASSETS.GetIfValid(path)
    if not asset then return end

    local comp = pin(anchor, asset, "CLASS")
    if not comp then
        unpinnable[path] = true
        return
    end

    heldComponents[#heldComponents + 1] = comp
    pinnedPaths[path] = true
    classPins = classPins + 1
end


-- =======================================================================================
-- Establish - load the KEEP set for this world, then pin it.
--   * Idempotent, renderer-only.
--   * Pins on the LoadAsset callback, which AssetManager already runs on the game thread.
-- =======================================================================================
function KEEPER.Establish()
    if established then return end
    if STATE.Role == "DEDICATED" then return end
    if not anchorActor() then return end        -- world not up yet; caller retries

    established = true

    for _, entry in ipairs(KEEPER.KEEP) do
        local path, kind = entry[1], entry[2]
        if path and not pinnedPaths[path] then
            ASSETS.LoadAsset(path, function(asset)
                if not asset or IsNotValid(asset) then
                    logBad("AssetKeeper - could not load " .. tostring(path))
                    return
                end
                local anchor = anchorActor()     -- re-fetch: the world may have gone
                if not anchor then return end
                if pinnedPaths[path] then return end

                local comp = pin(anchor, asset, kind)
                if comp then
                    heldComponents[#heldComponents + 1] = comp
                    pinnedPaths[path] = true
                    log("AssetKeeper - pinned " .. path)
                else
                    unpinnable[path] = true
                    logBad("AssetKeeper - pin FAILED for " .. tostring(path))
                end
            end)
        end
    end
end


-- Release every pin and reset for the next world. Most components are already invalid at
-- teardown (the anchor died with the world), so the IsValid guard makes those no-ops.
function KEEPER.Release()
    for _, comp in ipairs(heldComponents) do
        pcall(function() if IsValid(comp) then comp:K2_DestroyComponent(comp) end end)
    end
    heldComponents = {}
    classPins      = 0
    established    = false

    -- Cleared IN PLACE: pinnedPaths IS ASSETS.Pinned, and the cache-trust must die with
    -- the pins that justified it.
    for p in pairs(pinnedPaths) do pinnedPaths[p] = nil end
end


return KEEPER
