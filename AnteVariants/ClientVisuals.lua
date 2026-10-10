-- =======================================================================
-- ClientVisuals - applies a variant's visual effects (size, meshes, ...) on each renderer,
-- because the server doesn't replicate any of them.
--   * Each NPC carries a variant Id, embedded by NpcManager in its Walk/SprintSpeed FRACTION
--     (200.22 -> Id 22), which we decode here.
--   * Actors we've handled are marked in STATE.ClientSeenActors. A spawner unloading them
--     between levels produces NEW actors, so those get redecorated.
--   * GetFullName is the stable per-actor key - a wrapper is NOT stable.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local ENUMS = require("AnteData.Enums")
local Pipeline = require("AnteCore.Pipeline")
local AVU = require("AnteUtils.AVUtils")
local Lasers = require("AnteUtils.Lasers")
local VariantTag = require("AnteVariants.VariantTag")
local VariantSignal = require("AnteVariants.VariantSignal")
local Utils = require("AnteUtils.Utils")
local VARIANTS = require("AnteVariants.Variants")
local TAP = require("AnteCore.TestTap")   -- AnTest's client suite counts tagged / dressed / given up, by actor

local Log = Utils.Log
local LogDebug = Utils.LogDebug

local NPC_CLASS_NAME = "NPC_Base_ParentBP_C"          -- FindAllOf short name (seed + safety sweep)
local NPC_CLASS_PATH = ENUMS.BASE_PARENT_NPC          -- full path (NotifyOnNewObject)

-- NPCs are picked up EVENT-DRIVEN (NotifyOnNewObject), not by polling: the FindAllOf sweep is
-- O(all UObjects) and used to run every 2s forever, a recurring combat-independent hitch. It is
-- now a slow SAFETY NET for whatever the notify misses, plus a one-shot seed at Register.
local SAFETY_SCAN_MS   = 15000  -- fast-pass cadence while the world is still streaming in
local SAFETY_FAST_PASSES = 3
local SAFETY_SLOW_MS   = 300000 -- then a heartbeat: the prune, and a self-heal for a missed notify
local scansDone = 0
local DECODE_RETRY_MS  = 1000   -- per-actor decode retry (the variant tag replicates a beat late)
local VISUAL_RETRY_MS  = 2000   -- re-examine after a failed visuals pipeline
local MAX_DECODE_ATTEMPTS = 10  -- Retries on the same actor before assuming its not a variant
local MAX_VISUAL_ATTEMPTS = 3   -- Visuals-pipeline failures on the same actor before giving up
local MAX_NOTREADY_WAITS = 20   -- x DECODE_RETRY_MS a FRESH actor may read invalid before we let go

-- Id -> variant, built once from the variant registry (variants carry .Id/.Name)
local getVariantById = {}
for _, variant in pairs(VARIANTS) do
    if variant.Id then getVariantById[variant.Id] = variant end
end

-- Hoisted so the scan can pcall(fn, npc) - the pcall(function() ... end) form captures `npc` and
-- allocates a fresh closure per NPC per scan.
local function npcFullName(o) return o:GetFullName() end
local function npcIsDead(o) return o.IsDead == true end

local CV = {}

-- Rebuild the Id->def map after a /reload (VariantReload). The registry is refilled IN PLACE with
-- fresh def tables, so the load-time snapshot above would keep handing STALE defs to the decode
-- path and visuals would ignore every reloaded knob.
function CV.RebuildIdMap()
    for id in pairs(getVariantById) do getVariantById[id] = nil end
    for _, variant in pairs(VARIANTS) do
        if variant.Id then getVariantById[variant.Id] = variant end
    end
end

-- key -> true while a bounded examine/retry chain is queued, so the notify and the safety sweep
-- can't run two chains on one actor. Reset per world in Register.
local retrying = {}
local examineWithRetry   -- fwd (examineNpc re-queues itself through it after a visuals failure)


-- =======================================================================
-- Per-NPC examination. `key` is the actor's GetFullName, computed once by the caller and also used
-- to prune state. Returns "RETRY" while the actor isn't classifiable yet (row name or variant tag
-- not replicated), nil once resolved or given up on.
-- =======================================================================
local function examineNpc(npc, key)

    if STATE.ClientSeenActors[key] then return end
    -- A pipeline already in flight (it can sit in ACTOR_READY for seconds): don't start a second
    -- one and don't keep retrying while it runs.
    if STATE.ClientVisualsPending[key] then return end

    -- Base row name (class-default, present client-side), for the integrity check below.
    -- nil while the actor isn't ready - retry later.
    local rowName = Utils.GetActorRowName(npc)
    if not rowName then return "RETRY" end

    -- Skip TRUE corpses only, not IsActorAlive: a freshly-streamed NPC whose health/mesh hasn't
    -- replicated reads as "not alive" (GetTotalHealth 0) but isn't a corpse. The old gate marked
    -- those vanilla forever on the first scan, worst on grouped spawns scanned mid-arrival. Fall
    -- through to the tag retry; VISUALS still WaitFor's a valid mesh.
    local isDead = false
    local okDead, dead = pcall(npcIsDead, npc)
    if okDead then isDead = dead end
    if isDead then
        STATE.ClientSeenActors[key] = true
        return
    end

    -- Derive the variant ID off the replicated WalkSpeed
    local id = VariantTag.Decode(npc)
    local variant = id and getVariantById[id]

    -- Tag may not have replicated yet; retry a few times, then give up
    if not variant then
        local attempts = (STATE.ClientTagAttempts[key] or 0) + 1
        STATE.ClientTagAttempts[key] = attempts
        if attempts >= MAX_DECODE_ATTEMPTS then
            STATE.ClientSeenActors[key] = true   -- vanilla
            STATE.ClientTagAttempts[key] = nil
            return
        end
        return "RETRY"
    end

    -- Integrity check: a speed modifier can make the decode land on a wrong Id. Accept the
    -- variant's Base OR an AltBase, matching the server's NpcManager check - so client visuals
    -- still apply to e.g. a Grunt_Guard mutated by a base-"Grunt" variant.
    if not VariantTag.AcceptsBase(variant, rowName) then
        if TAP.on then TAP.Count("cvmismatch", key, (variant.Name or "?") .. " on " .. tostring(rowName)) end
        LogDebug(string.format("Client: tag %d (%s) but NPC is %s - skipping",
            id, variant.Name or "?", rowName), SETTINGS.DEBUG_CLIENT)
        STATE.ClientSeenActors[key] = true
        STATE.ClientTagAttempts[key] = nil
        return
    end

    STATE.ClientTagAttempts[key] = nil

    -- Nothing to apply -> done with this actor for good. This gate MUST list every renderer-side
    -- thing a def can declare, not just Visuals(): a variant with def.Tint / BodyScale /
    -- TimeDilation and no Visuals function was written off as vanilla and never decorated. A
    -- missed BodyScale in particular leaves a client capsule that bobs against position rep.
    if not (variant.Visuals or variant.Tint or variant.BodyScale or variant.NavRadius
            or variant.HitPad or variant.TimeDilation or variant.MirrorTimeDilation
            or variant.NoHitReaction) then
        STATE.ClientSeenActors[key] = true
        return
    end

    LogDebug(string.format("Client: applying %s visuals (tag %d)",
        variant.Name or "?", id), SETTINGS.DEBUG_CLIENT)
    if TAP.on then TAP.Count("cvtagged", key, variant.Name) end

    -- DO NOT mark ClientSeenActors yet - the pipeline can still fail (ACTOR_READY times out on an
    -- unreplicated mesh or a backed-up WorkQueue), and marking up front left a timed-out NPC
    -- permanently vanilla, never re-examined while loaded. Hold it "pending", mark Seen only once
    -- VISUALS lands, release on failure so a later scan retries (bounded by MAX_VISUAL_ATTEMPTS).
    STATE.ClientVisualsPending[key] = true

    local function onVisualsFail()
        STATE.ClientVisualsPending[key] = nil
        local fails = (STATE.ClientVisualsFails[key] or 0) + 1
        STATE.ClientVisualsFails[key] = fails
        if TAP.on then TAP.Count("cvfail", key, variant.Name) end
        if fails >= MAX_VISUAL_ATTEMPTS then
            if TAP.on then TAP.Count("cvgaveup", key, variant.Name) end
            STATE.ClientSeenActors[key] = true   -- give up; don't retry this actor forever
            STATE.ClientVisualsFails[key] = nil
            LogDebug(string.format("Client: %s visuals failed %dx - giving up",
                variant.Name or "?", fails), SETTINGS.DEBUG_CLIENT)
            return
        end
        -- Retry directly rather than waiting on the slow safety sweep.
        Utils.QueueWork(function() examineWithRetry(npc, key) end, VISUAL_RETRY_MS)
    end

    Pipeline.Run({
        -- A body the server takes away mid-wait ends here quietly (an IsLevelAway body still waits:
        -- it is the same actor when its level comes back).
        Pipeline.WaitFor("ACTOR_READY", function(ctx)
            return Utils.GetValidMesh(ctx.actor) ~= nil
        end, 5000, function(ctx)
            local gone = Utils.IsActorInvalid(ctx.actor) and not Utils.IsLevelAway(ctx.actor)
            if not gone then pcall(function() gone = ctx.actor:IsActorBeingDestroyed() end) end
            if not gone then return false end
            STATE.ClientVisualsPending[key] = nil
            LogDebug("Client: " .. (variant.Name or "?") .. " left play before its mesh was ready",
                SETTINGS.DEBUG_CLIENT)
            return true
        end),

        -- The NPC has usually existed server-side a while by the time it replicates in, so a
        -- short settle is enough.
        Pipeline.Delay("SETTLE", 500),

        Pipeline.LoadAssets(),

        Pipeline.Do("VISUALS", function(ctx)
            -- Died / streamed out mid-pipeline: release the pending hold (the scan's prune drops
            -- its other keys) and don't mark Seen - a respawn gets a fresh key.
            if Utils.IsActorInvalid(ctx.actor) then
                STATE.ClientVisualsPending[key] = nil
                return
            end

            -- def.Tint FIRST, then Visuals() - NpcManager's order on the server, so a Visuals()
            -- that overrides part of the tint behaves identically on both ends.
            if variant.Tint then AVU.TintMesh(ctx.actor, variant.Tint) end
            if variant.Visuals then variant.Visuals(ctx.actor, ctx.assets or {}) end

            -- def.NoHitReaction (NpcManager STATS on the authority): the impact-FX multicast runs
            -- the flinch on every machine, so this client blanks its own copy.
            if variant.NoHitReaction then AVU.DisableHitReaction(ctx.actor) end

            -- Pets: re-fire the size writer so this client's UpdateMeshScale hook re-applies
            -- def.PetScaleMult now the tag exists. Mesh scale doesn't replicate, so each client
            -- scales its own copy, and the redeploy's UpdateMeshScale ran before the tag arrived.
            if variant.PetScaleMult then
                local okpm, PM = pcall(require, "ModulePets.PetManager")
                if okpm and PM and PM.SchedulePetScale then PM.SchedulePetScale(ctx.actor) end
            end

            -- TRUE actor scale (capsule + mesh) - the SAME value the server applied (NpcManager
            -- BODYSCALE), so this capsule matches the authority's. Mismatched capsules bob
            -- against position replication.
            if variant.BodyScale then AVU.SetBodyScale(ctx.actor, variant.BodyScale) end

            -- Movement footprint (NpcManager NAVRADIUS) - after the scale, which it divides back
            -- out. Capsule size isn't replicated either, and a client capsule of a different width
            -- fights position rep exactly like a mismatched BodyScale does.
            if variant.NavRadius then AVU.SetNavRadius(ctx.actor, variant.NavRadius) end

            -- Invisible hit sphere (NpcManager HITPAD). A runtime component doesn't replicate and
            -- the weapon trace runs on the SHOOTER, so each client builds its own or a client-side
            -- shot still has to find the tiny native physics asset.
            if variant.HitPad then
                local p = variant.HitPad
                if type(p) == "table" then
                    AVU.PadHitbox(ctx.actor, p.Radius, p)
                else
                    AVU.PadHitbox(ctx.actor, p)
                end
            end

            -- CustomTimeDilation doesn't replicate, so set it here too.
            if variant.TimeDilation then ctx.actor.CustomTimeDilation = variant.TimeDilation end

            -- DYNAMIC CustomTimeDilation - mirror a CTD that changes over time. The server encodes
            -- it via AVU.SetTimeDilation; we poll it on a client tick and stop on death.
            if variant.MirrorTimeDilation then
                AVU.RegisterOnTickActor(ctx.actor, function(actor)
                    if Utils.IsActorInvalid(actor) then return "REMOVE" end
                    if actor.IsDead then return "REMOVE" end
                    local tdi = VariantSignal.Read(actor, VariantSignal.TDI)
                    if tdi and tdi > 0 then actor.CustomTimeDilation = tdi end
                end)
            end

            -- Client-side cosmetic tick (e.g. the Phase Peccary fade). The server registers
            -- def.OnTick for gameplay; pure clients get it only here, only via ClientTick.
            if variant.ClientTick and variant.OnTick then
                AVU.RegisterOnTickActor(ctx.actor, variant.OnTick, "def")
            end

            -- Landed. NOW this actor is done with (and any earlier failures are moot).
            if TAP.on then TAP.Count("cvdressed", key, variant.Name) end
            STATE.ClientVisualsPending[key] = nil
            STATE.ClientVisualsFails[key] = nil
            STATE.ClientSeenActors[key] = true
        end),
    }, { actor = npc, name = variant.Name, paths = variant.Assets or {} }, onVisualsFail)
end


-- =======================================================================
-- Examine an actor, re-queueing while it isn't classifiable yet (row name / variant tag replicate
-- a beat after the actor). Bounded by MAX_DECODE_ATTEMPTS inside examineNpc, and guarded by
-- `retrying` so the notify and the safety sweep can't both drive one actor.
-- =======================================================================
-- `fresh` (the notify path): an actor that reads invalid is WAITED for, not dropped. A client NPC
-- replicates in ahead of its level when the player teleports back into a sector, and
-- IsActorValid asks the level - so for a few seconds a good body reads invalid. Dropping it
-- there left it vanilla until the 5-minute safety scan happened to come round.
function examineWithRetry(npc, key, fresh)
    if Utils.IsDeparted(npc) or IsNotValid(npc) then return end
    if not fresh and Utils.IsActorInvalid(npc) then return end
    if not key then
        local ok, k = pcall(npcFullName, npc)
        if not ok or not k then return end
        key = k
    end
    -- Cheap early-outs before we allocate a retry chain
    if retrying[key] or STATE.ClientSeenActors[key] or STATE.ClientVisualsPending[key] then return end

    local waits = 0
    local function step()
        retrying[key] = nil
        if not STATE.ModEnabled then return end
        if Utils.IsActorInvalid(npc) then
            if not fresh or not Utils.IsLevelAway(npc) then return end
            waits = waits + 1
            if waits > MAX_NOTREADY_WAITS then return end
            retrying[key] = true
            Utils.QueueWork(step, DECODE_RETRY_MS)
            return
        end
        if waits > 0 then
            LogDebug(string.format("Client: %s arrived ahead of its level; examined after %ds",
                tostring(key:match("([^%.]+)$") or key), waits), SETTINGS.DEBUG_CLIENT)
            waits = 0
        end

        local ok, status = pcall(examineNpc, npc, key)
        if not ok then
            Utils.LogBad("Client examine error: " .. tostring(status))
            return
        end
        if status == "RETRY" then
            retrying[key] = true
            Utils.QueueWork(step, DECODE_RETRY_MS)
        end
    end
    step()
end


-- =======================================================================
-- A brand-new NPC object appeared (NotifyOnNewObject). UE REUSES full names, so any state under
-- this key belongs to a RETIRED actor: drop it, or the fresh actor inherits a stale "seen" mark
-- and silently never gets its visuals.
-- =======================================================================
local function onNewNpc(npc)
    if not STATE.ModEnabled then return end
    if Utils.IsDeparted(npc) or IsNotValid(npc) then return end   -- not IsActorInvalid: see examineWithRetry

    local ok, key = pcall(npcFullName, npc)
    if not ok or not key then return end

    STATE.ClientSeenActors[key] = nil
    STATE.ClientTagAttempts[key] = nil
    STATE.ClientVisualsPending[key] = nil
    STATE.ClientVisualsFails[key] = nil
    retrying[key] = nil

    examineWithRetry(npc, key, true)
end


-- =======================================================================
-- SAFETY SWEEP (was the 2s main loop). FindAllOf is O(all UObjects), so it is a STARTUP job:
-- a few fast passes catch NPCs that predate Register while the world streams in, then a slow
-- heartbeat prunes per-actor state down to loaded NPCs (bounded tables) and self-heals a missed
-- notify. Everything built after the notify arms comes through the notify.
-- =======================================================================
function CV.Scan()
    local npcs = FindAllOf(NPC_CLASS_NAME)
    if not npcs then return 0 end

    local present = {}
    local seeded = 0

    for _, npc in ipairs(npcs) do
        local ok, key = pcall(npcFullName, npc)
        if ok and key then
            present[key] = true
            if not (retrying[key] or STATE.ClientSeenActors[key] or STATE.ClientVisualsPending[key]) then
                seeded = seeded + 1
            end
            -- No-ops for the (overwhelmingly common) already-seen actor.
            examineWithRetry(npc, key)
        end
    end

    -- Drop state for actors no longer loaded
    for key in pairs(STATE.ClientSeenActors) do
        if not present[key] then STATE.ClientSeenActors[key] = nil end
    end
    for key in pairs(STATE.ClientTagAttempts) do
        if not present[key] then STATE.ClientTagAttempts[key] = nil end
    end
    -- Prune pending/fail keys too - a stale "pending" for an unloaded actor blocks a same-named
    -- replacement from ever being examined.
    for key in pairs(STATE.ClientVisualsPending) do
        if not present[key] then STATE.ClientVisualsPending[key] = nil end
    end
    for key in pairs(STATE.ClientVisualsFails) do
        if not present[key] then STATE.ClientVisualsFails[key] = nil end
    end
    return seeded
end

local function scanLoop()
    -- Loop until the mod shuts down; Register() re-arms on the next InitMod. ResetState clears
    -- ClientScanArmed because wiping the WorkQueue also kills the pending re-arm.
    if not STATE.ModEnabled then
        STATE.ClientScanArmed = false
        return
    end

    local ok, seeded = pcall(CV.Scan)
    if not ok then Utils.LogBad("Client scan loop error: " .. tostring(seeded)) end

    -- Past the seed passes, a catch means the notify missed one: worth knowing about.
    if ok and scansDone >= SAFETY_FAST_PASSES and (seeded or 0) > 0 then
        Log("ClientVisuals - safety scan seeded " .. seeded .. " NPC(s) the notify did not deliver")
    end
    scansDone = scansDone + 1
    Utils.QueueWork(scanLoop, (scansDone < SAFETY_FAST_PASSES) and SAFETY_SCAN_MS or SAFETY_SLOW_MS)
end

-- LASER RECOLOR (pure CLIENT). LaserColor (EPaintColor) + CurrentLaserColor don't replicate, so a
-- joined client builds every beam from the DEFAULT red. We recolor on OnRep_LaserActive via the
-- game's own Local_ChangeLaserColor (EPaintColor -> beam material + "BeamColor" param).
--   * Default is a RANDOM colour per client - it needn't match the server.
--     SETTINGS.GAMEPLAY.CLIENT_LASER_COLOR pins one value everywhere (the host's FireLaserBurst agrees),
--     except for variants declaring `LaserStyle = Lasers.RANDOM` to opt out (the Laser Pests).
--   * Scoped to NPC-OWNED beams, so the placed game laser grids are untouched.
local LASER_ONREP_HOOK = "/Game/Blueprints/Lasers/LaserComponent.LaserComponent_C:OnRep_LaserActive"

local function registerLaserRecolor()
    if STATE.ClientLaserHookArmed then return end   -- once per UE4SS session (persistent flag)
    STATE.ClientLaserHookArmed = true

    -- PRE hook: set the color BEFORE the native activate, so the beam powers on already tinted.
    pcall(RegisterHook, LASER_ONREP_HOOK, function(self)
        local comp = self:get()
        if IsNotValid(comp) then return end
        pcall(function()
            if not comp.LaserActive then return end                 -- only when turning ON
            local owner = comp:GetOwner()
            if IsNotValid(owner) or not Utils.GetActorRowName(owner) then return end   -- our NPC lasers only

            -- The SAME resolver the server ran when it built this beam (opts.Style is server-only,
            -- so there's nothing to pass): the owner's def.LaserStyle, else CLIENT_LASER_COLOR. Both
            -- ends agree without the style replicating. Lasers.RANDOM and "nothing declared" both
            -- land on a fresh roll - per-machine BY DESIGN, since the mismatch is the chaos.
            local style = Lasers.ResolveStyle(owner)
            if not style or style == Lasers.RANDOM then style = Lasers.RandomStyle() end
            Lasers.SetStyle(comp, style)
        end)
    end)
    Log("ClientVisuals - laser recolor hook registered")
end

-- Event-driven NPC pickup: fires the moment a replicated NPC is constructed here, so visuals land
-- immediately instead of up to a scan interval later. Once per UE4SS session (a NotifyOnNewObject
-- can't be unregistered), hence the persistent STATE flag.
-- NEVER touch the object inside the notify - queue it (the Coworker precedent).
local function registerNpcNotify()
    if STATE.ClientNpcNotifyArmed then return end
    STATE.ClientNpcNotifyArmed = true

    pcall(NotifyOnNewObject, NPC_CLASS_PATH, function(npc)
        Utils.QueueWork(function() onNewNpc(npc) end, 0)
    end)
    Log("ClientVisuals - NPC notify registered")
end

function CV.Register()
    registerLaserRecolor()
    registerNpcNotify()

    retrying = {}   -- per-world: stale chains died with the WorkQueue wipe
    scansDone = 0   -- a new world = a new set of pre-existing NPCs to catch up on

    if STATE.ClientScanArmed then return end
    STATE.ClientScanArmed = true

    -- Seed soon (NPCs loaded before we armed the notify), then drop to the slow safety cadence.
    -- The notify carries the steady-state work.
    Utils.QueueWork(scanLoop, 500)
    Log("ClientVisuals registered")
end

return CV
