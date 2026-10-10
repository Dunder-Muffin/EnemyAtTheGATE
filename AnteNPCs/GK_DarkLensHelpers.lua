-- =======================================================================
-- GK_DarkLensHelpers - the SHARED layer under the DarkLens boss fights.
--   * Chieftain fight -> AnteNPCs/GK_DarkLensPatriarchHelpers.lua
--   * Witch fight     -> AnteNPCs/GK_DarkLensWitchHelpers.lua
--   * Heavy fight     -> AnteNPCs/GK_DarkLensJotunHelpers.lua
--   * Mage fight      -> AnteNPCs/GK_DarkLensMageHelpers.lua (its "death flag" is
--                        Residence_Fracture_Complete, not its own _Dead flag; doubles as
--                        DL.RESPAWN_STORY)
-- Nothing fight-specific lives here. Full decode of the black-hole guard, arena prop guard,
-- respawn timer and arena damage guard: AnNotes/AnteNPCs/GKDarkLensShared.md.
--
-- MUST-KNOWS (each has its own section below):
--   * Every boss OnDeath must call `DL.FlagBackstop` - a death outside Server_OnKilledBy /
--     Server_PerformDeathSequence (a fall, an ally's stray AoE) sets no world flag and silently
--     stalls the questline.
--   * A world flag can NEVER be un-set, so a dead boss's spawner is disabled forever -
--     `DL.RespawnBoss` spawns the body directly instead. Every OnDeath must also call
--     `DL.NoteBossDeath` to start the timed-respawn clock (see the RESPAWN section).
--   * `DL.ArmWatcher` adopts and force-aggros any boss body already standing in the world at load
--     (a body has no spawn event to hook).
--   * All three fought bosses are stagger/hard-CC-immune via one call: `AVU.CCImmune(actor)`.
--   * `DL.ArmPropGuard` makes arena furniture inert (undismantleable, undamageable, untargetable) -
--     see the ARENA PROPS section for why that needs both a sweep and a hook, on every role.
--
-- A fight owns ONE cfg table and hands it to every call here (cfg._ref caches the boss wrapper, so
-- the shared layer owns that cache and the fight file never holds one of its own).
--   StateKey      STATE field guarding the watcher loop ("DarkLensArmed") - ResetState clears it
--   Label         log prefix ("DarkLens Chieftain")
--   Boss          what to call the boss in a log line ("Patriarch")
--   Flag          its Fracture_DL_<X>_Dead row name
--   ClassKey      ENUMS.NpcClasses key of the boss CLASS (scan + preload)
--   Variant       the variant name to mutate it into
--   Center        arena centre (adoption scans + the wake gate)
--   Area          its DL.ARENAS floor plan - the damage guard's "is a player in the room" anchor
--   ScanRadius    boss scan radius
--   WakeSq        a player this close (squared) to Center wakes the watcher's real work
--   AggroSq       a player this close (squared) to the BOSS forces aggro
--   CanForceAggro optional fn(boss) -> false = don't force aggro this beat (the sealed Mage, so
--                   ForceAggro's CombatState write doesn't open fire from inside its own bubble)
--   WatchMs       watcher cadence AT ITS FASTEST - backs off to NAP/IDLE_WATCH_MS when idle
--   ActiveStory   optional story floor below which the watcher idles (default DL.ACTIVE_STORY)
--   SpawnerClass  its NPCSpawn_* class name, for the reset respawn
--   Home          fallback spawn point when the spawner can't be read
--   RespawnStory  optional story floor for the timed respawn (default DL.RESPAWN_STORY; the
--                   Mage passes 0 - see the RESPAWN section)
--   GuardRange    arena-guard radius (default DL.GUARD_RANGE = 30m; the Mage's arena wants 5000)
--   PropRadius    overlap radius for the prop guard, big enough to reach every corner of Area
--                   (the polygon decides; this is only the query). Unset = opt out of the prop guard.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local SCHEMA = require("AnteData.Schema")
local ASSETS = require("AnteCore.AssetManager")
local FileIO = require("AnteCore.FileIO")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local LogDebug = Utils.LogDebug

local DL = {}

DL.WORLDFLAGS_DT = "/Game/Blueprints/DataTables/DT_WorldFlags.DT_WorldFlags"


-- =======================================================================
-- THE ARENAS - one floor plan per fight, walked in-game and dumped corner by corner.
--
-- Polygons, not radii: the four arenas sit packed close inside Facility_Fracture, so a circle big
-- enough to cover one spills into its neighbour. Rough bounding quads (winding/convexity don't
-- matter - crossing-number test), each fight only ever tests its OWN plan. Z is carried on the
-- points but never read (Utils.LocInArea) - there's tens of metres of headroom, and the Mother
-- hovers. Anything scoped to "this actor is in its own arena" keys off these: the damage guard
-- below, and each fight's "am I home" spawn check.
-- =======================================================================
DL.ARENAS = {
    -- The Chieftain's overlook and the floor below it (Fallow Patriarch + Phyters).
    Patriarch = { Points = {
        FVector(-38810, 83810, 2870), FVector(-43540, 82980, 2880),
        FVector(-44230, 86300, 2610), FVector(-39480, 87500, 2760),
    } },
    -- The Heavy's yard, south-west of the Patriarch's (Jotun of the Fallow + its Steed).
    Jotun = { Points = {
        FVector(-41865, 81795, 2625), FVector(-40645, 77776, 2569),
        FVector(-35734, 78869, 2380), FVector(-37212, 82801, 2474),
    } },
    -- The Witch's upper platform (Mother of the Fallow + acolytes). She fights ~10m off the deck.
    Mother = { Points = {
        FVector(-30286, 86349, 3625), FVector(-33795, 89740, 3705),
        FVector(-30089, 93993, 3643), FVector(-26368, 90133, 3557),
    } },
    -- The Mage's (Magus of the Fallow), the largest of the four - it overlaps the Jotun's and
    -- Mother's in plan, separated only by HEIGHT, which the Z-free test doesn't model (a player on
    -- the Mother's platform above reads "in the room" - a permissive miss, not a broken fight). If
    -- that ever needs to be exact, this is the entry that wants MinZ/MaxZ.
    Mage = { Points = {
        FVector(-30432, 81442, 2385), FVector(-32285, 89968, 3450),
        FVector(-38763, 90147, 3908), FVector(-36980, 80369, 2674),
    } },
}

local DIRECT_SPAWN_LIFT = 90    -- ground point -> capsule centre, or the body spawns half-buried
local DEAD_SCAN_EVERY   = 10    -- watcher beats between arena scans once the boss has died (30s)

-- THE WATCHER'S CADENCE LADDER. Four fights polling every WatchMs for the whole session adds up
-- fast, including for a wing of the map the save hasn't reached yet. So the beat is chosen per
-- tick from how close the world actually is to needing it (see watchTick); nothing is ever
-- latched off.
DL.ACTIVE_STORY   = 92          -- Residence_IceWallRemoved - the Fracture is not reachable before
                                --   this, so there is no body to adopt. cfg.ActiveStory overrides.
local IDLE_WATCH_MS = 120000    -- beat while the story gate is shut (two int reads, but it logs)
local NAP_WATCH_MS  = 10000     -- beat while the story is past it but no player is near the arena
local STORY_WARMUP_BEATS = 5    -- beats before the story gate is trusted at all (see watchTick):
                                --   must outlast StoryManager's 10s recompute, and 5 x 3s does


-- =======================================================================
-- BOSS REFERENCE - cached wrapper, re-scanned when it goes stale
-- =======================================================================

-- The live boss, or nil. Re-scans only when the cached wrapper is gone/dead, so the common path
-- is a table read rather than a class overlap.
function DL.Boss(cfg)
    local boss = cfg._ref and cfg._ref.actor
    if Utils.IsActorValid(boss) and not boss.IsDead then return boss end

    cfg._ref = nil
    local hits = AVU.GetNearbyActorsOfClass(cfg.Center, cfg.ScanRadius,
        ENUMS.NpcClasses[cfg.ClassKey])
    for i = 1, #hits do
        local a = hits[i]:get()
        if Utils.IsActorValid(a) and not a.IsDead then
            cfg._ref = { actor = a }
            return a
        end
    end
    return nil
end


function DL.SetBoss(cfg, actor)
    cfg._ref = Utils.IsActorValid(actor) and { actor = actor } or nil
end


function DL.ForgetBoss(cfg)
    cfg._ref = nil
end


-- =======================================================================
-- BLACK-HOLE GUARD - the one attack that DELETES a boss
--
-- The black-hole grenade's pull component kills by `Server_OnKilledBy` + `K2_DestroyActor()` once
-- an owner is within 200uu - no ProcessDamage, so HP/shield/Invincible/DBNO are never consulted and
-- our OnDeath never runs. The native immunity tag is inverted (immune = immune to being MOVED, not
-- killed) and a TArray we can't append to from Lua anyway. Fix: hook the component's tick PRE and,
-- for the four boss rows only, park the body just outside the kill radius so the native distance
-- check takes the launch branch instead of the delete branch. Full decode: AnNotes/AnteNPCs/GKDarkLensShared.md.
-- =======================================================================

local BH_COMPONENT_CLASS = "/Game/Blueprints/Environment/Hazards/BlackHole/"
    .. "BP_BlackHoleComponent_Character.BP_BlackHoleComponent_Character_C"
local BH_TICK_HOOK = BH_COMPONENT_CLASS .. ":ReceiveTick"

local BH_KILL_RADIUS = 200    -- native: <= this from the FX component = swallowed
local BH_HOLD_RADIUS = 320    -- where we park it instead (margin for one frame of drift)

local BH_PROTECTED = {
    DarkLens_Chieftain = true,   -- Fallow Patriarch
    DarkLens_Witch     = true,   -- Mother of the Fallow
    DarkLens_Heavy     = true,   -- Jotun of the Fallow
    DarkLens_Mage      = true,   -- not ours, but its death gates the Fracture chain too
}

local bhGuardArmed = false   -- module-local: a RegisterHook cannot be undone, and STATE is
                             -- world-scoped (a reload would double-register)

-- [PRE, authority] One caught character, one frame.
local function blackHoleTick(comp)
    if not STATE.ModEnabled or not Utils.IsAuthority() then return end   -- the swallow is server-side
    if IsNotValid(comp) then return end

    local owner
    pcall(function() owner = comp:GetOwner() end)
    if Utils.IsActorInvalid(owner) then return end
    local row = Utils.GetActorRowName(owner)   -- nil on players/props - the cheap reject
    if not row or not BH_PROTECTED[row] then return end

    local hole, centre, oLoc
    pcall(function() hole = comp.LinkedBlackHole end)
    if IsNotValid(hole) then return end
    -- The native check measures to the FX COMPONENT, not the actor - match it exactly.
    pcall(function() local l = hole.ParticleFX:K2_GetComponentLocation(); centre = FVector(l.X, l.Y, l.Z) end)
    pcall(function() local l = owner:K2_GetActorLocation(); oLoc = FVector(l.X, l.Y, l.Z) end)
    if not centre or not oLoc then return end
    if Utils.DistSq(centre, oLoc) > (BH_KILL_RADIUS * BH_KILL_RADIUS) then return end

    -- Push OUT along the horizontal offset and keep the body's own Z: the native test is a 3D
    -- distance, so clearing the radius in XY alone already clears it. A body sitting dead centre
    -- has no offset to use - fall back to its facing.
    local hx, hy = oLoc.X - centre.X, oLoc.Y - centre.Y
    local h = math.sqrt(hx * hx + hy * hy)
    if h < 1 then
        pcall(function() local f = owner:GetActorForwardVector(); hx, hy = f.X, f.Y end)
        h = math.sqrt(hx * hx + hy * hy)
        if h < 0.01 then hx, hy, h = 1, 0, 1 end
    end

    local rot
    pcall(function() local r = owner:K2_GetActorRotation(); rot = FRotator(r.Pitch, r.Yaw, r.Roll) end)
    pcall(function()
        owner:K2_SetActorLocationAndRotation(
            FVector(centre.X + (hx / h) * BH_HOLD_RADIUS,
                    centre.Y + (hy / h) * BH_HOLD_RADIUS, oLoc.Z),
            rot or FRotator(0, 0, 0), false, {}, true)
    end)
    -- ...and let go of it. The game destroys this same component from inside this same tick on its
    -- own bail paths, so doing it here is its own pattern; the 2s sweep will re-grab the boss.
    pcall(function() comp:K2_DestroyComponent(comp) end)

    LogDebug("DarkLens - " .. row .. " pulled free of a black hole", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- Armed from DL.ArmWatcher, so every DarkLens fight gets it and none of them has to know.
--   * The component class is NOT resident until a black hole grenade has gone off, and a raw
--     RegisterHook on an unloaded class THROWS (the DefenseBot-suppressor lesson) - so load it
--     first, then pcall-register.
local function armBlackHoleGuard()
    if bhGuardArmed then return end
    bhGuardArmed = true

    ASSETS.LoadAsync({ BH_COMPONENT_CLASS }, function()
        ASSETS.WarmPinned({ BH_COMPONENT_CLASS })   -- a class that unloads takes its hook with it
        local ok, err = pcall(RegisterHook, BH_TICK_HOOK,
            function(self) blackHoleTick(self:get()) end,   -- PRE: before the native distance test
            function() end)
        if ok then
            LogDebug("DarkLens - black-hole guard registered", SETTINGS.DEBUG_NPC_ACTIONS)
        else
            bhGuardArmed = false   -- let the next fight's ArmWatcher retry
            Utils.LogBad("DarkLens - black-hole guard FAILED: " .. tostring(err))
        end
    end)
end


-- =======================================================================
-- ARENA PROPS - the dressing in a DarkLens room is INERT
--
-- Level-placed deployables in these rooms are ordinary packageable furniture (not player-built),
-- so untouched a player can dismantle the room mid-fight, splash damage flattens the cover, and
-- NPCs FIXATE on them (BT_CheckObstruction locks TargetActor onto any furniture an NPC walks into).
-- Two mechanisms, because those problems gate in two different places: a per-actor SWEEP
-- (bCanBeDamaged/CanBePackaged/CanBeNPCTarget = false, run on EVERY role because CanBePackaged
-- doesn't replicate) plus a POST-HOOK on CanLoseDurability (the only lever BT_CheckObstruction's
-- fixation check reads that isn't already false). "Is this one of ours" is the prop's LOCATION
-- against the registered floor plans, not identity. Full decode: AnNotes/AnteNPCs/GKDarkLensShared.md.
-- =======================================================================

-- The deployable PARENT: the overlap catches every subclass, and CanLoseDurability is declared
-- here (Furniture inherits it), so this one path is both the scan class and the hook target.
local PROP_CLASS = ENUMS.DeployedObjs.BASE
local PROP_DURABILITY_HOOK = PROP_CLASS .. ":CanLoseDurability"

local PROP_FIRST_MS = 2000         -- first pass after arming (see DL.ArmPropGuard)
local PROP_SWEEP_MS = 30000        -- re-sweep cadence while a player is near an armed arena
local PROP_WAKE_SQ  = 6000 * 6000  -- ...and the "is anyone near it" gate. Wider than the watcher's
                                   --   wake: a prop must be inert BEFORE the fight starts, and a
                                   --   sublevel streams in well outside aggro range.

local propAreas = {}         -- [1..n] floor plans the obstruction hook forces CanLoseDurability off in
local propHookArmed = false  -- module-local: a RegisterHook cannot be undone (STATE is world-scoped)
local propGuardLogged = false


-- Force CanLoseDurability false for any deployable standing in a registered arena. That is the last
-- gate BT_CheckObstruction consults once DeployedByPlayer is false, so a false here is the whole
-- fixation fix - the NPC never writes the prop into TargetActor at all.
--   * The answer is the callback's RETURN value: CanLoseDurability's result is never a callback
--     param ([[ue4ss-hook-return-value-override]]), which left this guard dead until 2026-10-01.
--     nil = leave the native answer alone.
local function propDurabilityHook(Self)
    if not STATE.ModEnabled or #propAreas == 0 then return nil end

    local actor = Self and Self:get()
    if IsNotValid(actor) then return nil end

    -- PLAYER-BUILT IS NEVER OURS. Someone can put a base down in any of these rooms, and an NPC
    -- breaking through a player's wall is the native behaviour working - the arena dressing is the
    -- only thing being protected here. Same reject in the sweep.
    local mine = false
    pcall(function() mine = actor.DeployedByPlayer == true end)
    if mine then return nil end

    local loc
    pcall(function() loc = actor:K2_GetActorLocation() end)
    if not loc then return nil end

    for i = 1, #propAreas do
        if Utils.LocInArea(loc, propAreas[i]) then
            if not propGuardLogged then
                propGuardLogged = true
                LogDebug("DarkLens - arena prop held inert (CanLoseDurability -> false)", SETTINGS.DEBUG_NPC_ACTIONS)
            end
            return false
        end
    end
    return nil
end


-- Armed once per session from the first DL.ArmPropGuard.
--   * The class is resident wherever deployables exist, but not necessarily YET, and a raw
--     RegisterHook on an unloaded class THROWS (the black-hole guard's lesson) - load, then
--     pcall-register.
local function armPropObstructionHook()
    if propHookArmed then return end
    propHookArmed = true

    ASSETS.LoadAsync({ PROP_CLASS }, function()
        ASSETS.WarmPinned({ PROP_CLASS })   -- a class that unloads takes its hook with it
        -- Both slots: the false is absolute, and the one that runs after the body is what sticks.
        local ok, err = pcall(RegisterHook, PROP_DURABILITY_HOOK, propDurabilityHook, propDurabilityHook)
        if ok then
            LogDebug("DarkLens - arena prop obstruction guard registered", SETTINGS.DEBUG_NPC_ACTIONS)
        else
            propHookArmed = false   -- let the next fight's ArmPropGuard retry
            Utils.LogBad("DarkLens - prop obstruction guard FAILED: " .. tostring(err))
        end
    end)
end


-- Sterilise every deployable standing inside `area`. Returns how many it touched.
--   * The overlap is a sphere (SphereOverlapActors' only shape) but the POLYGON decides - these
--     rooms are packed side by side and the sphere alone reaches into the neighbour's yard.
--   * Writes are idempotent, so there's no "done" book; a prop that streams in later is picked up
--     by the next pass for free. Three separate pcalls: CanBePackaged/CanBeNPCTarget live on the
--     FURNITURE subclass, so a plain deployable (lamp, barricade) throws on those but still needs
--     bCanBeDamaged.
local function sterilisePropsIn(center, radius, area)
    local hits = AVU.GetNearbyActorsOfClass(center, radius, PROP_CLASS) or {}
    local n = 0
    for i = 1, #hits do
        -- Overlap out-param elements can arrive as RemoteUnrealParam; unwrap when they do.
        local a = hits[i]
        local okg, inner = pcall(function() return hits[i]:get() end)
        if okg and inner then a = inner end

        if IsValid(a) then
            -- Player-built stays the player's - see propDurabilityHook.
            local mine, loc = false, nil
            pcall(function() mine = a.DeployedByPlayer == true end)
            if not mine then pcall(function() loc = a:K2_GetActorLocation() end) end
            if loc and Utils.LocInArea(loc, area) then
                pcall(function() a.bCanBeDamaged = false end)
                pcall(function() a.CanBePackaged = false end)
                pcall(function() a.CanBeNPCTarget = false end)
                n = n + 1
            end
        end
    end
    return n
end


local function propTick(cfg)
    -- Same story floor as the watcher: nothing to sterilise in a wing the save can't reach.
    if (STATE.StoryProgress or 0) < (cfg.ActiveStory or DL.ACTIVE_STORY) then return end

    -- Cheapest gate first: with nobody near the room its sublevel is almost certainly not even
    -- streamed in, and an overlap over an empty scene is still an overlap.
    local _, distSq = Utils.NearestPlayer(cfg.Center)
    if not distSq or distSq > PROP_WAKE_SQ then return end

    local n = sterilisePropsIn(cfg.Center, cfg.PropRadius, cfg.Area)
    if n ~= cfg._propCount then
        cfg._propCount = n
        LogDebug(cfg.Label .. " - " .. n .. " arena prop(s) made inert", SETTINGS.DEBUG_NPC_ACTIONS)
    end
end


local function propLoop(cfg)
    if not STATE.ModEnabled then STATE[cfg.StateKey .. "Props"] = false return end
    local ok, err = pcall(propTick, cfg)
    if not ok then Utils.LogBad(cfg.Label .. " prop guard error: " .. tostring(err)) end
    Utils.QueueWork(function() propLoop(cfg) end, PROP_SWEEP_MS)
end


-- Armed from each fight's Register() alongside DL.ArmWatcher, on EVERY ROLE (see the section
-- header for why the sweep is not authority-only). A fight with no cfg.PropRadius opts out.
function DL.ArmPropGuard(cfg)
    if not cfg.PropRadius or not cfg.Area then return end

    -- The floor plan is registered even if the loop is already up: the hook is shared across
    -- fights and each one contributes its own room. Dedup by identity - these are the module-level
    -- DL.ARENAS tables, so the same fight always presents the same one.
    local known = false
    for i = 1, #propAreas do
        if propAreas[i] == cfg.Area then known = true break end
    end
    if not known then propAreas[#propAreas + 1] = cfg.Area end

    if Utils.IsAuthority() then armPropObstructionHook() end   -- BT_CheckObstruction is server-side

    local key = cfg.StateKey .. "Props"
    if STATE[key] then return end
    STATE[key] = true
    -- First pass SOON, not a full cadence away: a relog standing in the arena must not spend 30s
    -- with a packable, breakable room. Still a beat, so it lands on a clean drain after init.
    Utils.QueueWork(function() propLoop(cfg) end, PROP_FIRST_MS)
    LogDebug(cfg.Label .. " - arena prop guard armed", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- =======================================================================
-- RESPAWN ON A TIMER - the minibosses come back once the Fracture is done
--
-- Ours, not the spawner's: NPCSpawn_DARKLENS_* is DisablePermanentlyFlag'd by the boss's death
-- flag, and a world flag can never be un-set, so the spawner is gone for good. `DL.RespawnBoss`
-- spawns a fresh body directly instead (same path /dlreset already used) - flag chain, loot and
-- compendium all unaffected. Gate is three cheap reads on the watcher's beat: story floor -> the
-- in-game day has passed -> no player standing on the spot. The day is persisted
-- (StoryData.DarkLensRespawnDay) since the cooldown is day-scale and outlives the session.
-- cfg.RespawnStory overrides the floor per fight - the Mage sets 0 since its death flag IS the
-- story flag, so it's eligible on the calendar alone. Full decode: AnNotes/AnteNPCs/GKDarkLensShared.md.
-- =======================================================================

DL.RESPAWN_STORY = 97      -- Residence_Fracture_Complete: the Fracture is done, so its bosses are
                           --   free to be a farmable fight rather than a one-shot set piece
DL.RESPAWN_DAYS  = 3       -- in-game days between a kill and the next body
local RESPAWN_CLEAR_SQ = 2000 * 2000   -- never pop a boss inside 20m of a player; wait a beat

local function respawnDayMap()
    STATE.StoryData = STATE.StoryData or {}
    STATE.StoryData.DarkLensRespawnDay = STATE.StoryData.DarkLensRespawnDay or {}
    return STATE.StoryData.DarkLensRespawnDay
end


-- Stamp "this boss may return on day X". Called at death, and lazily by the watcher for a boss
-- that died before any of this existed (so an old save starts its clock on the next visit rather
-- than handing the player a boss the moment they walk in).
function DL.NoteBossDeath(cfg)
    local day = Utils.GetCurrentDay()
    if not day then return end
    respawnDayMap()[cfg.Flag] = day + DL.RESPAWN_DAYS
    FileIO.SaveStoryData()
    LogDebug(string.format("%s - dead; may respawn on day %d", cfg.Label, day + DL.RESPAWN_DAYS),
        SETTINGS.DEBUG_NPC_ACTIONS)
end


-- Cheap half of the gate: story + calendar only, no scans and no actor reads.
local function respawnDue(cfg)
    if (STATE.StoryProgress or 0) < (cfg.RespawnStory or DL.RESPAWN_STORY) then return false end
    local day = Utils.GetCurrentDay()
    if not day then return false end

    local ready = respawnDayMap()[cfg.Flag]
    if not ready then
        -- First sight of a boss that died without a stamp (an older save, or a kill the game
        -- credited while we were not loaded). Start the clock now.
        DL.NoteBossDeath(cfg)
        return false
    end
    return day >= ready
end


-- Expensive half: we already know it is due and that no boss is in the arena.
local function respawnNow(cfg, pLoc)
    if pLoc and Utils.DistSq(pLoc, cfg.Home or cfg.Center) <= RESPAWN_CLEAR_SQ then return end

    -- A player who just teleported in is inside WakeSq before the arena has streamed. Wait a beat
    -- (before the re-stamp below, so waiting costs nothing).
    if not Utils.IsLocationLoaded(cfg.Home or cfg.Center) then return end

    -- Re-stamp BEFORE spawning, so a spawn that quietly fails waits its turn instead of retrying
    -- every 3 seconds forever. A spawn that WORKS parks the wrapper in cfg._ref, and the watcher
    -- goes back to its normal adopt/aggro upkeep from the next tick.
    respawnDayMap()[cfg.Flag] = (Utils.GetCurrentDay() or 0) + DL.RESPAWN_DAYS
    FileIO.SaveStoryData()

    Utils.Log(string.format("%s - %d-day respawn: the %s returns", cfg.Label, DL.RESPAWN_DAYS,
        cfg.Boss))
    DL.RespawnBoss(cfg, "story respawn")
end


-- =======================================================================
-- ARENA WATCHER (authority) - adoption + the out-of-combat aggro check
-- =======================================================================

local function watchTick(cfg)
    -- GATE 0 - THE STORY. Every DarkLens arena is behind the Residence ice wall; before that comes
    -- down there's no body to adopt and no player who could be in the room. Two int reads, cheap.
    --
    -- THE WARM-UP: `STATE.StoryProgress` inits to 0 and only becomes real on StoryManager's first
    -- flag marshal, so a finished save looks fresh for the first seconds of a load. Reading that 0
    -- as "too early" would idle the watcher a full IDLE_WATCH_MS on exactly the load where a player
    -- relogs inside an arena - so the gate is skipped for the first few beats, long enough to
    -- outlast SM's 10s recompute.
    cfg._beats = (cfg._beats or 0) + 1
    local story = STATE.StoryProgress or 0
    if cfg._beats > STORY_WARMUP_BEATS and story < (cfg.ActiveStory or DL.ACTIVE_STORY) then
        return "story"
    end

    -- GATE 1 - is a player near the arena at all (GameState list walk, no scans).
    local player = Utils.NearestPlayer(cfg.Center)
    if not player then return "far" end
    local pLoc
    pcall(function() pLoc = player:K2_GetActorLocation() end)
    if not pLoc or Utils.DistSq(pLoc, cfg.Center) > cfg.WakeSq then return "far" end

    -- The death flag no longer ends the watcher: it can never be un-set, so once true it says
    -- nothing about whether a body stands there NOW - a fresh one can come back on a timer.
    -- `respawnDue` is cheap (int/table reads), so it's free every beat; when nothing is due and we
    -- hold no live wrapper, drop to a SLOW scan rather than stop (a respawned boss from an earlier
    -- visit still needs adoption/aggro upkeep, and cfg._ref doesn't survive a relog).
    local dead = Utils.HasWorldFlag(cfg.Flag) == true
    local due = false
    if dead then
        due = respawnDue(cfg)
        if not due and not cfg._ref then
            cfg._slowTick = (cfg._slowTick or 0) + 1
            if cfg._slowTick % DEAD_SCAN_EVERY ~= 0 then return end
        end
    end

    local boss = DL.Boss(cfg)
    if not boss then
        if due then respawnNow(cfg, pLoc) end
        return
    end

    -- Adopt: mutate the untagged boss (VariantTag = "did our pipeline finish", never DisplayName).
    -- Lazy requires - NpcManager/VariantTag at the top of this file is a load-time cycle.
    local tagged
    pcall(function() tagged = require("AnteVariants.VariantTag").Decode(boss) ~= nil end)
    if not tagged then
        LogDebug(cfg.Label .. " - adopting the " .. cfg.Boss, SETTINGS.DEBUG_NPC_ACTIONS)
        pcall(function() require("AnteVariants.NpcManager").MutateActor(cfg.Variant, boss, {}) end)
        return   -- let the pipeline land before poking aggro
    end

    -- The AISense fix: sitting out of combat with a player close -> force the fight.
    local inCombat
    pcall(function() inCombat = boss.CombatState == true end)
    if inCombat then return end
    if cfg.CanForceAggro and not cfg.CanForceAggro(boss) then return end   -- (the sealed Mage)
    local bLoc
    pcall(function() bLoc = boss:K2_GetActorLocation() end)
    if bLoc and Utils.DistSq(pLoc, bLoc) <= cfg.AggroSq then
        LogDebug(cfg.Label .. " - player close, forcing " .. cfg.Boss .. " aggro",
            SETTINGS.DEBUG_NPC_ACTIONS)
        AVU.ForceAggro(boss, player, 200)
    end
end


-- watchTick reports how awake the arena is, and that picks the NEXT beat. The gates are re-asked
-- from scratch every time, so a run that crosses the story floor - or a player who walks in - is
-- picked up on the following beat and the loop climbs straight back to cfg.WatchMs. Nothing here
-- can turn the watcher OFF; the slowest state is still a poll.
local function watchLoop(cfg)
    if not STATE.ModEnabled then STATE[cfg.StateKey] = false return end
    local ok, state = pcall(watchTick, cfg)
    if not ok then
        Utils.LogBad(cfg.Label .. " watcher error: " .. tostring(state))
        state = nil   -- an erroring tick keeps the normal cadence; don't slow-roll a broken fight
    end

    local ms = cfg.WatchMs
    if state == "story" then ms = IDLE_WATCH_MS
    elseif state == "far" then ms = NAP_WATCH_MS end
    Utils.QueueWork(function() watchLoop(cfg) end, ms)
end


-- Armed from main.lua each world load (the StoryManager.Register pattern); idempotent via
-- STATE[cfg.StateKey], which ResetState clears when the WorkQueue (and our queued loop item) is
-- wiped on teardown.
function DL.ArmWatcher(cfg)
    if STATE[cfg.StateKey] then return end
    if not Utils.IsAuthority() then return end
    STATE[cfg.StateKey] = true

    -- The cfg is a MODULE-level table, so it outlives the world; STATE[cfg.StateKey] is what
    -- ResetState clears, which makes this the one place per world load that can wipe it.
    --   * _ref holds a boss WRAPPER - an old world's would be a freed pointer (S3).
    --   * _beats is the story-gate warm-up (watchTick); a used-up count would let a second world
    --     load in one session judge itself on the PREVIOUS world's StoryProgress.
    cfg._ref, cfg._beats, cfg._slowTick = nil, nil, nil

    Utils.QueueWork(function() watchLoop(cfg) end, cfg.WatchMs)
    armBlackHoleGuard()   -- shared, once per session (see the black-hole section)
    LogDebug(cfg.Label .. " - arena watcher armed", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- =======================================================================
-- DEATH FLAG BACKSTOP
-- =======================================================================

-- [OnDeath] Set the boss's world flag ourselves if the native death paths didn't. Checked after
-- they have had time to run, then verified - a silent failure here is a stuck questline, so it
-- logs loudly either way.
function DL.FlagBackstop(cfg)
    Utils.QueueWork(function()
        if Utils.HasWorldFlag(cfg.Flag) ~= false then return end
        Utils.LogBad("DarkLens - " .. cfg.Flag .. " missing after " .. cfg.Boss
            .. " death; setting it")
        pcall(function()
            local wfs = Utils.GetWorldFlagSubsystem()
            if IsValid(wfs) then
                wfs:SetWorldFlag(SCHEMA.MakeHandle(cfg.Flag, { DataTablePath = DL.WORLDFLAGS_DT }),
                    true, nil)
            end
        end)
        Utils.QueueWork(function()
            if Utils.HasWorldFlag(cfg.Flag) == false then
                Utils.LogBad("DarkLens - " .. cfg.Flag
                    .. " backstop FAILED; the Fracture chain may be stuck")
            end
        end, 1000)
    end, 2500)
end


-- =======================================================================
-- RESPAWN (the /dlreset path)
-- =======================================================================

-- Put a fresh boss on the field.
--   * The spawner is asked FIRST so a world that can still field it keeps its authored placement;
--     its live location is logged (cheapest way to verify an arena coord).
--   * Once the death flag is set the spawner is disabled forever, so the fallback spawns the body
--     directly - still a real boss mutated through the normal variant path.
--   * The class preload is not enough on its own - these rows are in NpcSpawner's OFFHOOK_ROWS.
function DL.RespawnBoss(cfg, note, onSpawned)
    ASSETS.LoadAsync({ ENUMS.NpcClasses[cfg.ClassKey] }, function()
        local sp, spLoc
        pcall(function()
            local all = FindAllOf(cfg.SpawnerClass)
            sp = all and all[1]
        end)

        if IsValid(sp) then
            pcall(function() local l = sp:K2_GetActorLocation(); spLoc = FVector(l.X, l.Y, l.Z) end)
            -- Spawner-side liveness: >0 = its NPC exists somewhere off-arena (these bosses never
            -- despawn at 300km DespawnDistance) - don't double-spawn.
            local cur = -1
            pcall(function() cur = sp:GetCurrentSpawnedCount() end)
            if spLoc then
                Utils.Log(string.format("%s reset: spawner at %.0f,%.0f,%.0f (count %d)",
                    cfg.Label, spLoc.X, spLoc.Y, spLoc.Z, cur))
            end
            if cur and cur > 0 then
                Utils.Log(cfg.Label .. " reset: spawner reports its boss ALIVE - not respawning")
                return
            end
            if Utils.HasWorldFlag(cfg.Flag) ~= true then
                -- OUT-PARAM RULE (CLAUDE.md 3): a table per out, or the pcall'd call no-ops.
                local ok = pcall(function() sp:TrySpawnNPC(false, true, false, {}, {}, {}, {}) end)
                if ok then
                    Utils.Log(string.format("%s reset: spawner respawn requested (%s)",
                        cfg.Label, tostring(note)))
                    return
                end
                Utils.Log(cfg.Label .. " reset: spawner respawn FAILED - spawning directly")
            end
        end

        -- cfg.Home wins over the spawner's own coordinate - a measured spot, vs. the authored mark
        -- placed for an on-foot, unscaled native spawn (the Jotun arrives mounted and can't).
        local base = cfg.Home or spLoc
        local at = FVector(base.X, base.Y, base.Z + DIRECT_SPAWN_LIFT)
        AVU.SummonVariant(cfg.Variant, at, {}, function(npc)
            DL.SetBoss(cfg, npc)
            if onSpawned then pcall(onSpawned, npc) end
        end)
        Utils.Log(string.format("%s reset: spawning a fresh %s directly at %.0f,%.0f,%.0f (%s)",
            cfg.Label, cfg.Boss, at.X, at.Y, at.Z, tostring(note)))
    end)
end


-- =======================================================================
-- ARENA GUARD - a hit from outside the arena does nothing
-- =======================================================================

-- These arenas are wide open (seen and shot from outside), so a hit landing while no player is
-- inside is zeroed. A damage-time check, not an `Invincible` latch: Invincible is already owned
-- elsewhere (the Patriarch's barrier, the Mage's default seal) and a hit is not evidence a player
-- is close (the whole point of an open arena is shooting in from outside). Errs VULNERABLE: two
-- anchors, either counts (cfg.Area for "in the room", plus a radius around the boss itself to
-- catch one pulled past the rim), and anything unmeasurable reads as occupied. Full decode:
-- AnNotes/AnteNPCs/GKDarkLensShared.md.
DL.GUARD_RANGE = 3000   -- 30m, the size of these arenas. cfg.GuardRange overrides (the Mage: 5000)
local GUARD_CACHE_MS = 400   -- a player cannot cross the whole radius inside this

local guardCache = {}   -- actorKey -> { at = Utils.NowMs() ms, out = bool }

-- True = nobody is in the arena, so this hit should be ignored.
function DL.OutOfArena(cfg, actor)
    if Utils.IsActorInvalid(actor) then return false end

    -- Per-hit hook: a DoT tick or a shotgun spread asks this many times a second, so the answer
    -- is cached for a beat. Keyed by ActorKey - ProcessDamage hands back a fresh wrapper.
    local key = Utils.ActorKey(actor)
    local now = Utils.NowMs()
    if key and now > 0 then
        local c = guardCache[key]
        if c and (now - c.at) < GUARD_CACHE_MS then return c.out end
    end

    local range = cfg.GuardRange or DL.GUARD_RANGE
    local rangeSq = range * range
    local measured, inside = false, false

    local bLoc
    pcall(function() local l = actor:K2_GetActorLocation(); bLoc = FVector(l.X, l.Y, l.Z) end)
    if bLoc then
        measured = true
        local p, d = Utils.NearestPlayer(bLoc)
        if p and d and d <= rangeSq then inside = true end
    end
    if not inside and cfg.Area then
        measured = true
        if Utils.AnyPlayerInArea(cfg.Area) then inside = true end
    end

    local out = measured and not inside   -- unmeasurable -> treat the arena as occupied
    if key and now > 0 then guardCache[key] = { at = now, out = out } end
    if out then
        LogDebug(cfg.Label .. " - hit ignored, no player in the arena", SETTINGS.DEBUG_NPC_ACTIONS)
    end
    return out
end


-- Drop a boss's cached answer (death / reset). Not required for correctness - the entry expires
-- on its own - but it keeps the table from holding dead keys for the life of the world.
function DL.ForgetGuard(actor)
    local key = actor and Utils.ActorKey(actor)
    if key then guardCache[key] = nil end
end


-- Log line for the reset paths: a set flag means the spawner is gone for good.
function DL.NoteFlagLocked(cfg)
    if Utils.HasWorldFlag(cfg.Flag) ~= true then return end
    Utils.Log(cfg.Label .. " reset: " .. cfg.Flag .. " is set and world flags cannot be un-set - "
        .. "its spawner is disabled for good, so this is a direct spawn")
end


return DL
