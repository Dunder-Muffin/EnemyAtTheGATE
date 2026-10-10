-- =======================================================================
-- MAGE EYE HELPERS - machinery behind AnteNPCs/GK_MageEye.lua
-- Live eyes: Warden (standalone) + Barrier (support). The Beholder's five WELDED eyes are a
-- different animal - pinned to a mage's shoulders and fired from its tick - and live with the rest
-- of that set in AnteNPCs/GK_MageBeholderHelpers.lua.
--
--   * Can't switch the beam off - Lasers.SetActive(false) is re-undone by the pawn's own 0.5s
--     server loop, so per-tick suppression only flickers. Blank its reach instead: MaxDistance = 1
--     traces 1cm and the loop has nothing to draw.
--   * It force-gibs itself - Server_PerformDeathSequence -> DestroyEye -> TryGibbingNPC(force)
--     drops the gib-salvage row regardless of HasDroppedLoot. Use AVU.ClearGibLoot, not ClearLoot.
--   * 10 HP on ALL SIX LIMBS, not head-only like a Pest. Set all six, or a stray limb hit overflows
--     into a 10hp torso.
--   * `Invincible` != unkillable. The black hole grenade bypasses the damage pipeline entirely
--     (fix: AVU.SetInvulnerable's "blackholeimmune" tag). The nuke vac is unfixable - it whitelists
--     SK_MageEyeDrone by mesh path and hard-destroys any match with no immunity check.
--   * NO CombatState - never set on this NPC, so any "is it fighting" helper built on it
--     (Utils.IsActorReadyToAttack included) reads false forever. Real signal is StationaryTarget:
--     what native CanFireLaser gates on, and what replicates to the client.
--   * HOVER. Z sits above the floor and nothing corrects vertical drift, so a one-shot Z nudge
--     HOLDS (XY does not - the BT re-paths). Nav-project before dropping loot or spawning under one.
--   * PERF: each eye is a full OnTick actor - half-rate polls, memoized keys, latched cosmetics.
--   Decode: [[anteup2-beholder-eyes]] (the native eye decode; the Beholder set adds AnNotes/AnteNPCs/Beholder.md)
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local ENUMS = require("AnteData.Enums")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local AVM = require("AnteUtils.AVMath")
local Lasers = require("AnteUtils.Lasers")

local LogDebug = Utils.LogDebug

local MUTE_LASER = true   -- silence the channel laser's emitter hum + hit hiss on the renderer

local H = {}

-- RENDERER: eye fullname -> last glow tag written. Material params don't replicate (each machine
-- paints its own), and a 10Hz tick must not rewrite 10x/sec - hence the latch, keyed via AVU.CachedFullName.
local glowState = {}


-- =======================================================================
-- SHARED
-- =======================================================================

local function eyeStationaryTarget(eye)
    local t
    pcall(function() t = eye.StationaryTarget end)
    return Utils.IsActorValid(t) and t or nil
end


-- Who at? StationaryTarget (the eye's own signal) first, generic path as backstop - the
-- controller's 0.25s refresh can lag a fresh acquisition by a few ticks.
local function eyeTarget(eye)
    if Utils.IsActorInvalid(eye) then return nil end
    return eyeStationaryTarget(eye) or AVU.GetCurrentTarget(eye)
end


-- [RENDERER] Drive an eye's EMISSIVE, latched so a 10Hz tick only touches the material on a real
-- state flip. `tag` = the stable per-visual-state string the latch compares.
local function eyeGlow(eye, tag, color, intensity)
    if Utils.IsActorInvalid(eye) or not color then return end

    local key = AVU.CachedFullName(eye)
    if not key then return end

    if glowState[key] == tag then return end
    glowState[key] = tag

    AVU.TintMesh(eye, { EmissiveColor = color, Emissive = intensity })
end
H.EyeGlow = eyeGlow   -- the Warden's Visuals lights its idle glow from the def file


local function forgetEyeGlow(key)
    if key then glowState[key] = nil end
end


-- =======================================================================
-- WARDEN EYE  (standalone - no owner, fielded by a spawner)
-- =======================================================================

local function byMode(t) return STATE.HardModeNoMercy and t.Hard or t.Normal end

local WARDEN_ALERT_TICKS   = { Normal = 50, Hard = 40 }   -- aggroed time before it summons
local WARDEN_PATROL_TICKS  = 100
local WARDEN_PATROL_RADIUS = 1000   -- one hop
local WARDEN_LEASH         = 1000   -- past this from home the next hop heads back: ~20m of roam

local BREACH_EMERGE_MS     = 2000
local BREACH_PORTAL_MS     = 3500
local BREACH_DROP_RADIUS   = 400   -- loot fuzz, and the fallback floor search
local BREACH_FLOOR_EXTENT  = 400   -- how far under the hovering eye to look for the floor
local BREACH_PHYTER_CHANCE = 0.7

-- The squad has to read as walking out of ONE doorway. PortalSummon fans its arrivals 137 degrees
-- apart on a circle of this radius, so the gap between any two is roughly twice it - 16 puts the
-- Phyter pair about 30uu apart, close enough that they depenetrate into a huddle at the portal.
local BREACH_SPREAD        = 16

-- Laser suppressed, so the TELL is its own emissive going dark red once it spots you (no light
-- component, no skeleton sockets = a real spotlight is impossible on this NPC).
local WARDEN_EM_TEX = ENUMS.Components.T_MAGEEYE_EMISSIVE_DESAT
local EM_IDLE      = FVector(1, 0.1, 0)
local EM_ALERT     = FVector(0.5, 0, 0)
local EM_INTENSITY = 15

-- Shared with the def's Visuals (GK_MageEye.lua); the tick below keeps using the locals.
H.WARDEN_EM_TEX, H.EM_IDLE, H.EM_INTENSITY = WARDEN_EM_TEX, EM_IDLE, EM_INTENSITY

-- fullname -> { Home = FVector, AlertAt = tick, Breached = bool, Hurt = bool, Woke = bool }
local wardenState = {}

-- Created on demand: a warden can be shot before its first tick pass, and a dropped Hurt latch is
-- a fuse that silently never starts.
local function wardenRow(eye, key)
    local st = wardenState[key]
    if not st then
        st = { Home = eye:K2_GetActorLocation(), AlertAt = nil, Breached = false }
        wardenState[key] = st
    end
    return st
end

-- The breach portal warms itself (ClientEffects); we only need the reinforcement classes, emerge
-- burst, and the desat emissive (resident before Visuals).
H.WARDEN_ASSETS = { ENUMS.NpcClasses["Gatekeeper_Phyter"], ENUMS.NpcClasses["Gatekeeper_Mage"],
                    AVU.PORTAL_FX, AVU.PORTAL_SFX, WARDEN_EM_TEX }


-- [AUTHORITY] Wander. The BT's own EQS query needs context EQ_TargetContext_OwningMage, which
-- returns nothing with no mage - so a standalone eye would just hover in place. We drive it
-- instead: a nav-projected point near home, leashed to the level.
local function wardenPatrol(eye, st)
    if AVU.IsNoPatrol(eye) then return end   -- a NoPatrol placement holds its post
    local here = eye:K2_GetActorLocation()
    if not here or not st.Home then return end

    -- Leash: if it has drifted, the next hop goes back toward home instead of further out.
    local origin = (AVM.DistXY(st.Home, here) > WARDEN_LEASH) and st.Home or here

    local at = Utils.GetSpawnPoint(origin, WARDEN_PATROL_RADIUS)
    if not at then return end

    pcall(function()
        local c = eye:GetController()
        if IsValid(c) then c:MoveToLocation(at, 100, true, true, true, true, nil, true) end
    end)
end


-- [AUTHORITY] Give a hurt-but-blind warden something to point at, so a shot from cover reads like a
-- real acquisition: the native enrage spin plays and the alert glow lights. One-shot by the caller's
-- latch - re-entering combat on a cadence just replays the aggro montage and parks the body.
local function wardenWake(eye)
    local here = eye:K2_GetActorLocation()
    local target = here and Utils.NearestPlayer(here)
    if not target then return end

    AVU.ForceAggro(eye, target)
    LogDebug("Warden Eye - hit while blind, waking onto the nearest player", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- [AUTHORITY] Survived the window: open the portal, then vanish. Reinforcements walk out 2s later;
-- the warden goes immediately - calling them in was its whole job.
local function wardenBreach(eye)
    local target = AVU.GetCurrentTarget(eye)
    local key = eye:GetFullName()
    local eyeLoc = eye:K2_GetActorLocation()

    -- GROUND THE ARRIVALS: the warden HOVERS, so spawning at its own Z drops them in from the air.
    -- Straight DOWN, so the squad lands under the doorway it supposedly stepped out of -
    -- GetSpawnPoint means "somewhere near here" and was scattering them a room's width away.
    local at = Utils.ProjectToNav(eyeLoc, BREACH_FLOOR_EXTENT)
                 or Utils.GetSpawnPoint(eyeLoc, BREACH_DROP_RADIUS)
    if not at then
        LogDebug("Warden Eye - BREACH: no nav point under it, skipping", SETTINGS.DEBUG_NPC_ACTIONS)
        return
    end

    LogDebug("Warden Eye - BREACH: opening a portal", SETTINGS.DEBUG_NPC_ACTIONS)

    -- The rift opens ON the warden (where it hovers) while the squad walks out on the floor below,
    -- so draw it separately - hence Rift = false in the summon, or it draws a second one below.
    if eyeLoc then AVU.PortalDrop(eyeLoc, { OpenMs = BREACH_PORTAL_MS }) end

    -- A pair of Phyters, or a single Mage. No LifetimeOwner - they must outlive the warden.
    local squad = (math.random() < BREACH_PHYTER_CHANCE)
        and { { Npc = "Gatekeeper_Phyter", Count = 2 } }
        or  { "Gatekeeper_Mage" }

    AVU.PortalSummon(at, squad, {
        Spread = BREACH_SPREAD,
        Rift = false,
        EmergeFX = false,   -- no per-arrival spawn burst on the summons
        EmergeMs = BREACH_EMERGE_MS,
        OpenMs = BREACH_PORTAL_MS,
        Attack = target,
        FactionFrom = eye,
    })

    -- REGISTER THE DEFEAT. It's DESTROYED, not killed (no death sequence -> no OnDeath, no loot),
    -- and a plain destroy reads to the AIDirector as a stream-out, so the spawner re-pops another
    -- Warden almost at once. RefreshSpawnerCooldown records a kill while it's still spawner-linked.
    AVU.RefreshSpawnerCooldown(eye)

    -- Same for a PLACED warden: PlacedSpawn can't tell an invalid wrapper from a stream-out, so it
    -- deliberately doesn't cooldown - it re-places on your next approach. Lazy-require = no cycle.
    pcall(function() require("ModuleStory.EventUtils").MarkPlacedDefeated(eye) end)

    Utils.QueueWork(function()
        wardenState[key] = nil
        Lasers.Forget(eye)
        forgetEyeGlow(key)
        if Utils.IsActorValid(eye) then pcall(function() eye:K2_DestroyActor() end) end
    end, 250)
end


function H.WardenTick(actor, ticks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    if ticks % 5 ~= 0 then return end

    -- Has it acquired someone? (StationaryTarget replicates, so the client can read it too.)
    local spotted = false
    pcall(function() spotted = IsValid(actor.StationaryTarget) end)
    if Utils.HasRenderer() then
        eyeGlow(actor, spotted and "alert" or "idle",
                spotted and EM_ALERT or EM_IDLE, EM_INTENSITY)
    end

    if not Utils.IsAuthority() then return end

    local key = actor:GetFullName()
    if Utils.IsDeadSafe(actor) then
        wardenState[key] = nil
        forgetEyeGlow(key)
        return "REMOVE"
    end

    -- Suppress the laser: owner-less = permanently enraged, tries to fire every 0.25s. NPCEnraged
    -- left alone so it still plays the aggro animation.
    Lasers.SetActive(actor, false)

    local st = wardenRow(actor, key)

    if not (spotted or st.Hurt) then
        st.AlertAt = nil
        if ticks % WARDEN_PATROL_TICKS == 0 then wardenPatrol(actor, st) end
        return
    end

    -- Spotted (or shot): start (or continue) the fuse.
    if st.Breached then return end
    if st.Hurt and not st.Woke then
        st.Woke = true
        wardenWake(actor)
    end
    if not st.AlertAt then
        st.AlertAt = ticks
        LogDebug("Warden Eye - target acquired, breaching soon", SETTINGS.DEBUG_NPC_ACTIONS)
        return
    end

    if ticks - st.AlertAt >= byMode(WARDEN_ALERT_TICKS) then
        st.Breached = true
        wardenBreach(actor)
        return "REMOVE"
    end
end


-- Damage IS a detection: a hit starts the same breach fuse that spotting a player does, and the
-- latch sticks, so ducking back into cover can't reset it. Only a table write here - this rides the
-- ProcessDamage hook, so the aggro that follows waits for the next tick pass.
function H.WardenHurt(actor)
    if not Utils.IsAuthority() or Utils.IsActorInvalid(actor) then return end
    wardenRow(actor, actor:GetFullName()).Hurt = true
end


-- Clean up and return the nav-projected drop point (it HOVERS, so loot must not spawn at its Z).
function H.WardenDeath(actor)
    if Utils.IsActorInvalid(actor) then return nil end
    local key = actor:GetFullName()

    wardenState[key] = nil
    Lasers.Forget(actor)
    forgetEyeGlow(key)

    local loc = actor:K2_GetActorLocation()
    if not loc or loc.X == 0 then return nil end
    return Utils.GetSpawnPoint(loc, BREACH_DROP_RADIUS) or loc
end


-- =======================================================================
-- BARRIER EYE  (support - summoned by the Barrier Mage)
-- =======================================================================

local CHANNEL_ZOFF = 120   -- aim the channel laser at the mage's upper body

-- STRAGGLER LEASH. An eye that lags too far behind a moving mage cuts itself loose, so it can't
-- live on as an uncounted extra the mage then replaces. Held INSIDE the mage's 25m scan range, so
-- a live eye is always one the mage can still see.
local EYE_LEASH_SQ = 2200 * 2200

-- Channel beam style (orange). Drives the sustain channel, and the native berserk after the mage
-- dies. Exported so both ends resolve it from one place - no laser colour property replicates.
-- Server applies it when lighting the beam; client's OnRep_LaserActive reads the tag.
H.CHANNEL_LASER = { Color = Lasers.COLOR.ORANGE }

H.BARRIEREYE_ASSETS = { Lasers.FX_BEAM, Lasers.FX_END, Lasers.FX_RECV, AVU.PORTAL_FX, AVU.PORTAL_SFX }

-- AUTHORITY: eye fullname -> true once we've seen its mage dead. Lets a released eye outlive the
-- corpse: "mage wrapper invalid" before the latch means stream-out (destroy me); after the latch
-- it just means the corpse faded (keep fighting).
--   * On `H` because H.BarrierEyeDeath clears it. One table, two scopes - the local below is an
--     alias, not a second table. Don't reassign either name.
H.eyeReleased = {}
local eyeReleased = H.eyeReleased

-- Memoized OwningMage fullname, keyed by the EYE (an eye's mage never changes) - costs no
-- GetFullName after warmup. Not AVU.CachedFullName(mage): `actor.OwningMage` returns a fresh
-- wrapper each read, so that memo would always miss.
local eyeMageKeyCache = setmetatable({}, { __mode = "k" })
local function eyeMageKey(eye, mage)
    local k = eyeMageKeyCache[eye]
    if k then return k end
    local ok, name = pcall(function() return mage:GetFullName() end)
    if ok and name then eyeMageKeyCache[eye] = name; return name end
    return nil
end


-- Channels the orange sustain laser at its mage while the mage fights.
--   * Perf: GetFullName only on rare death/handoff paths; Mute re-checked every 5 ticks; aim only
--     at the trace rate (per-tick aiming was a measurable hitch).
--   * NO facing override - native AI already faces the eye. AimAt only rotates the LaserComponent;
--     a FaceTarget call here would just fight the AI.
function H.BarrierEyeTick(actor, ticks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end

    -- The channel laser's audio comp is recreated on each beam toggle, so re-mute it (renderer).
    if ticks % 5 == 0 and Utils.HasRenderer() and MUTE_LASER then
        Lasers.Mute(actor)
    end

    if not Utils.IsAuthority() then return end

    -- Dead: kill the beam (death doesn't touch LaserActive, so it would hang).
    if Utils.IsDeadSafe(actor) then
        Lasers.SetActive(actor, false)
        eyeReleased[actor:GetFullName()] = nil
        return "REMOVE"
    end

    local mage
    pcall(function() mage = actor.OwningMage end)

    -- Mage gone (stream-out): destroy the eye, unless we already released it to fight on alone.
    if Utils.IsActorInvalid(mage) then
        if eyeReleased[actor:GetFullName()] then return "REMOVE" end
        pcall(function() actor:K2_DestroyActor() end)
        return "REMOVE"
    end

    -- Mage DIED with the eye still up: hand it to its native berserk, once. Restore the damage
    -- Stats zeroed, or the released laser doesn't bite.
    if Utils.IsDeadSafe(mage) then
        local key = actor:GetFullName()
        if not eyeReleased[key] then
            eyeReleased[key] = true
            Lasers.Tune(actor, { Damage = nil, Restore = true })
            LogDebug("Barrier Eye - mage died, releasing beam to the native enrage",
                SETTINGS.DEBUG_NPC_ACTIONS)
        end
        return
    end

    -- STRAGGLER LEASH (see the knob). Best-effort: a streamed-out eye can't self-clean, but then
    -- it isn't near the mage to be counted either.
    local ml, el
    pcall(function() ml = mage:K2_GetActorLocation() end)
    pcall(function() el = actor:K2_GetActorLocation() end)
    if ml and el and Utils.DistSq(ml, el) > EYE_LEASH_SQ then
        Lasers.SetActive(actor, false)
        pcall(function() actor:K2_DestroyActor() end)
        return "REMOVE"
    end

    -- HEARTBEAT. Stamp the mage's ping table so it counts us WITHOUT a SphereOverlap (~40ms hitch).
    -- In AND out of combat, so the barrier holds while idle. Memoized keys + one table write/tick.
    local mk = eyeMageKey(actor, mage)
    local ek = AVU.CachedFullName(actor)
    local pings = STATE.BarrierPings
    if mk and ek and pings then
        local t = pings[mk]
        if not t then t = {}; pings[mk] = t end
        t[ek] = STATE.FAST_TICK
    end

    -- Out of combat: no channel (the beam only sustains during a fight).
    local fighting = false
    pcall(function() fighting = mage.CombatState == true end)
    if not fighting then
        Lasers.SetActive(actor, false)
        return
    end

    -- CHANNEL. Beam lit, aimed at the mage; every 2 ticks = the trace rate.
    Lasers.SetActive(actor, true)
    if ticks % 2 == 0 then
        Lasers.AimAt(actor, mage, CHANNEL_ZOFF)
    end
end


-- [OnDeath] Stop the beam and forget the release latch.
function H.BarrierEyeDeath(actor)
    if Utils.IsActorInvalid(actor) then return end
    local key = actor:GetFullName()

    Lasers.SetActive(actor, false)   -- stop the beam asap
    eyeReleased[key] = nil
    Lasers.Forget(actor)
end


return H
