-- =======================================================================
-- Exor Volatile helpers - the machinery behind AnteNPCs/ExorVolatile.lua: the Acidic Exor's acid
-- retaliation + [HARD] acid burst, and the Hunter/Killer twin system (spawn placement, the
-- Hunter's post-swing pause, the Killer's spend-once rush).
--
-- MUST-KNOWS
--   * No NPC-dealt engine AoE anywhere here. Acid blood debuffs players, and hits NPCs with a
--     per-victim point hit off-hook - never a radial (see the def file header).
--   * twinState covers the WHOLE async chain (EQS placement + spawn) behind one `pending` latch,
--     or a retry landing mid-chain would start a second Killer.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local AVM = require("AnteUtils.AVMath")
local ASSETS = require("AnteCore.AssetManager")
local PROJ = require("AnteCore.Projectile")
local Placement = require("AnteCore.Placement")

local LogDebug = Utils.LogDebug

local H = {}


-- =======================================================================
-- ACIDIC EXOR - acid blood retaliation, and [HARD] the ranged acid burst that answers kiting.
-- =======================================================================

local RETALIATE_TYPES = { Sharp = true, Blunt = true, Bullet = true }
local ACID_THROTTLE_TICKS = 10

local ACID_RADIUS    = 500
local ACID_BURN_SECS = 3
local CORROSIVE_SECS = 30

local SPRAY_FX    = ENUMS.Effects.ACID_MACE_IMPACT
local SPRAY_SCALE = FVector(3, 3, 3)

-- Re-loaded at USE (a preload doesn't pin). Named BY ROW NAME, so loading the DamageType alone
-- doesn't pull the buff object in.
local ACID_DEPS = {
    ENUMS.BuffObjects.AcidBurn,
    ENUMS.BuffObjects.HPDamage,
    ENUMS.DamageType.Acid,
    SPRAY_FX,
}

-- Acid blood on NPCs: one plain-Acid point hit per body in ACID_RADIUS (AVU.PointDamageOffHook
-- over a fresh list), never a radial. Plain Acid carries no debuff, so no DoT timer lands on an NPC;
-- players keep the AcidBurn/Corrosive debuffs instead.
local ACID_SPLASH = {
    Damage     = { Normal = 40, Hard = 60 },
    MaxVictims = 6,
}

local lastAcidBurstTick = {}   -- actor key -> FAST_TICK of the last acid retaliation

-- [HARD] THE ACID BURST - the answer to kiting a body this slow. A rooted double swing that
-- flings the Thumper Shotgun's ricocheting acid rounds, one handful per hand.
local SPIT = {
    BeatTicks = 70,     -- one burst per 7s
    MinDist   = 500,
    MaxDist   = 3000,
    Pellets   = 3,      -- per hand
    Damage    = 75,
    SpreadDeg = 10,     -- cone width: mildly inaccurate
    Velocity  = 2000,   -- the round's own row speed
    LifeSpanS = 4,      -- only a pellet that hits nothing gets here
    Radius    = 160,    -- spawn dist along the aim ray: clears the scaled-up capsule
    AimZ      = 20,     -- height above the target's FEET, not its origin
    -- Actor scale, so the round's collision sphere grows with it (the row's own radius is 4). Its
    -- Niagara is local-space and should follow, but the system also exposes a User.Scale param -
    -- if the tracer stays small in game, that param is the lever, not the transform.
    Scale     = FVector(5, 5, 5),
}

-- The montage's beats in ANIM seconds, converted to real ms so they move with TimeDilation the
-- way the montage itself does. Left hand is deliberately ahead of its own anim beat: the two
-- handfuls should read as one burst, and a full swing between them lets the target walk out of
-- the second.
local SPIT_TDI        = 0.8
local SPIT_RIGHT_MS   = math.floor(100 / SPIT_TDI)
local SPIT_LEFT_MS    = math.floor(250 / SPIT_TDI)
local SPIT_RECOVER_MS = math.floor(1200 / SPIT_TDI)

-- Warmed at combat entry AND at each burst - not in def.Assets, since nothing here is touched by
-- the mutation and in normal mode the burst never fires at all. Both resolves are non-loading, so
-- a cold one is a silent whiff rather than a hitch. The round's class is absent: PROJ.Queue loads
-- that itself, per shot.
local SPIT_DEPS = { ENUMS.Anims.EXOR_VOLATILE_MELEE, ENUMS.DamageType.AcidAccuracy }

-- The round's OWN dep: the row's DamageType, latent-loaded at spawn. A cold one lands untyped.
local SPIT_ROUND_DEPS = { ENUMS.DamageType.AcidAccuracy }


-- Shorten the leap. There is no distance member - the arc is bytecode, and GravityScale is the
-- only lever that reaches it: solved at 1g but flown at Ng, so it lands short (range ~ 1/N).
local function leapDamp(actor, gravityScale)
    if Utils.IsActorInvalid(actor) then return end
    local move = actor.CharacterMovement
    if IsNotValid(move) then return end
    pcall(function() move.GravityScale = gravityScale end)
end


-- Debuffs on nearby players, an Acid hit on nearby NPCs of another faction (ACID_SPLASH), + FX.
-- Runs off-hook; ACID_DEPS re-loaded because a preload doesn't stick.
local function acidRetaliate(actor, loc, faction)
    if not loc then return end

    ASSETS.LoadAsync(ACID_DEPS, function()
        -- +100 Z = feet -> torso height. Scale is an FVector (a bare number silently fails MakeTransform).
        AVU.BroadcastFX(FVector(loc.X, loc.Y, loc.Z + 100), SPRAY_FX, nil, SPRAY_SCALE)

        AVU.BuffPlayersInRadius(loc, ACID_RADIUS, {
            { Buff = ENUMS.Debuffs.AcidBurn,       Secs = ACID_BURN_SECS },
            { Buff = ENUMS.Debuffs.FlaskCorrosive, Secs = CORROSIVE_SECS },
        })

        if Utils.IsActorInvalid(actor) then return end
        if IsNotValid(ASSETS.GetIfValid(ENUMS.DamageType.Acid)) then return end   -- never fire untyped
        local dmg = STATE.HardModeNoMercy and ACID_SPLASH.Damage.Hard or ACID_SPLASH.Damage.Normal
        local hit = 0
        for _, npc in ipairs(AVU.GetNearbyNpcs(loc, ACID_RADIUS, { ignoreActor = actor })) do
            local f
            pcall(function() f = npc.Faction end)
            if f ~= faction and not Utils.IsDeadSafe(npc) then
                AVU.PointDamageOffHook(actor, npc, dmg, ENUMS.DamageType.Acid)
                hit = hit + 1
                if hit >= ACID_SPLASH.MaxVictims then break end
            end
        end
        if hit > 0 then
            LogDebug("Acidic Exor - acid blood splashed " .. hit .. " NPC(s)", SETTINGS.DEBUG_NPC_ACTIONS)
        end
    end)
end


-- One hand's rounds: re-aimed at the release (the target has had most of a second to move), then
-- scattered off that line. Meshless class, so the visible round is its own Niagara.
local function acidSpitHand(actor, bone)
    if not Utils.IsActorReadyToAttack(actor) then return end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end

    local t = target:K2_GetActorLocation()
    if not t then return end

    local from
    local mesh = actor.Mesh
    if IsValid(mesh) then
        -- Copied out of the socket call: a returned struct is not ours to hold.
        pcall(function()
            local s = mesh:GetSocketLocation(FName(bone))
            from = FVector(s.X, s.Y, s.Z)
        end)
    end
    from = from or actor:K2_GetActorLocation()

    -- Aimed low, off the target's FEET rather than its origin - a round that comes in flat at
    -- ankle height skips off the floor instead of sailing past, which is the whole point of a
    -- bouncing shot. CapsuleHalfHeight reads the live capsule, so a crouched player still gets it.
    local footZ = t.Z - AVU.CapsuleHalfHeight(target)
    local aim = Utils.Direction(from, FVector(t.X, t.Y, footZ + SPIT.AimZ))

    -- One muzzle for the handful, out along the aim ray so nothing spawns inside the body.
    local muzzle = FVector(from.X + aim.X * SPIT.Radius,
                           from.Y + aim.Y * SPIT.Radius,
                           from.Z + aim.Z * SPIT.Radius)

    for _ = 1, SPIT.Pellets do
        local dx, dy, dz = AVM.ScatterDir(aim.X, aim.Y, aim.Z, SPIT.SpreadDeg)
        if dx then
            PROJ.Queue(muzzle, FVector(dx, dy, dz), ENUMS.ProjectileClasses.ShotgunBounceShot, nil, {
                NoProjectileHit = true,
                Owner = actor,
                Instigator = actor,
                VelocityOverride = true,
                Velocity = SPIT.Velocity,
                LifeSpan = SPIT.LifeSpanS,
                Damage = SPIT.Damage,
                Scale = SPIT.Scale,
                DamageTypeClass = ENUMS.DamageType.AcidAccuracy,
                Preload = SPIT_ROUND_DEPS,
                SerializeTicks = 0,   -- one handful, one instant - not a stream
            })
        end
    end
end


-- The whole beat: root for the swing, then a handful of rounds on each frame a hand comes round.
-- Rooted rather than montage-locked - nothing on this base clears LockedInPlaceMontage outside the
-- leap, so latching it here would park the body for good. Faced BEFORE the montage: a rooted NPC
-- does not re-orient (MOVE_None leaves the movement component nothing to turn).
local function acidSpitVolley(actor, target)
    ASSETS.WarmPinned(SPIT_DEPS)

    AVU.RootInPlace(actor, SPIT_RECOVER_MS)
    AVU.FaceTarget(actor, target)
    AVU.PlayMontageReplicated(actor, ENUMS.Anims.EXOR_VOLATILE_MELEE, 1, false)

    Utils.QueueWork(function() acidSpitHand(actor, "r_hand") end, SPIT_RIGHT_MS)
    Utils.QueueWork(function() acidSpitHand(actor, "l_hand") end, SPIT_LEFT_MS)

    LogDebug("Acidic Exor - acid burst", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- =======================================================================
-- EXOR HUNTER / KILLER - "keep exactly one Killer standing" twin system.
-- =======================================================================

local TWIN_VARIANT = "Exor Killer"

local TWIN_FIRST_MS      = 2000    -- first attempt, 2s into combat
local TWIN_RETRY_TICKS   = 20      -- re-attempt every 2s while it has none standing
local TWIN_PENDING_TICKS = 100     -- give up on a placement/spawn that never called back (10s)
local TWIN_SPAWN_RADIUS  = 3000    -- 30m from the TARGET
local TWIN_ZLIFT         = 100     -- EQS points sit on the ground; lift to capsule-centre
local TWIN_AGGRO_DELAY_MS = 800
local TWIN_ORPHAN_CHECK_TICKS = 50      -- released-Killer self-clean poll (~5s)
local TWIN_ORPHAN_RANGE       = 15000   -- 150m = the game's own NPC unload distance
local TWIN_STALE_TICKS        = 1800    -- drop the entry of a Hunter that streamed out (3min)

-- Breathing room after a Killer dies, so the kill is worth something.
local TWIN_REPLACE_TICKS      = 80   -- 8s
local TWIN_REPLACE_TICKS_HARD = 10   -- 1s

local twinState = {}   -- Hunter key -> { twin, pending, pendingUntil, readyAt, at }


-- Leyak EQS points the target cannot see, taking the one farthest from the parent (a pincer, not
-- a pile-up). This only ever reorders candidates - it never rejects them all.
local function findTwinSpot(parent, target, cb)
    if Utils.IsActorInvalid(target) then return cb(nil) end
    local ok, tLoc = pcall(function() return target:K2_GetActorLocation() end)
    if not ok or not tLoc then return cb(nil) end

    Placement.FindStalkerPoint(target, { Origin = tLoc, MaxDist = TWIN_SPAWN_RADIUS }, function(points)
        if not points or #points == 0 then return cb(nil) end

        local pLoc
        if Utils.IsActorValid(parent) then
            pcall(function() pLoc = parent:K2_GetActorLocation() end)
        end

        local best, bestD = points[1], -1
        for i = 1, #points do
            local d = pLoc and Utils.DistSq(pLoc, points[i]) or 0
            if d > bestD then best, bestD = points[i], d end
        end
        cb(FVector(best.X, best.Y, best.Z + TWIN_ZLIFT))   -- lift or it sinks into the floor
    end)
end


-- Twin setup (authority, after the mutation): match faction, tie its lifetime to the Hunter
-- (released to fight on if the Hunter dies), and put it on the target.
local function onTwinSpawned(twin, parent, target)
    if Utils.IsActorInvalid(twin) then return end

    AVU.SkipSpawnFX(twin)

    local fac
    pcall(function() fac = parent.Faction end)
    if fac ~= nil then AVU.SetFaction(twin, fac) end

    AVU.WatchSummonLifetime(twin, parent, {
        ReleaseOnParentDeath = true,
        OrphanRange = TWIN_ORPHAN_RANGE,
        CheckTicks  = TWIN_ORPHAN_CHECK_TICKS,
        Label = "Exor Killer",
    })

    AVU.ForceAggro(twin, target, TWIN_AGGRO_DELAY_MS)
    LogDebug("Exor Hunter - Killer placed out of LoS", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- One beat of the "keep exactly one Killer standing" contract. While its Killer lives this is two
-- table reads; when that Killer dies the replacement waits out TWIN_REPLACE_TICKS. `pending`
-- covers the WHOLE async chain - EQS placement AND the spawn - or a retry landing between the two
-- would start a second Killer. It expires on a deadline rather than a queued watchdog, so nothing
-- can strand it. Entries are pruned by staleness: a Hunter that streams out never runs OnDeath.
local function tryTwin(parent)
    if Utils.IsActorInvalid(parent) or parent.IsDead then return end

    local key = parent:GetFullName()
    local now = STATE.FAST_TICK

    local st = twinState[key]
    if not st then
        for k, e in pairs(twinState) do
            if now - e.at > TWIN_STALE_TICKS then twinState[k] = nil end
        end
        st = {}
        twinState[key] = st
    end
    st.at = now

    if st.pending then
        if now < st.pendingUntil then return end
        st.pending = false   -- the placement or the spawn never called back
    end

    if st.twin then
        local alive = Utils.IsActorValid(st.twin)
        if alive then pcall(function() alive = st.twin.IsDead ~= true end) end
        if alive then return end
        -- It just died: start the replacement clock rather than the replacement.
        st.twin = nil
        st.readyAt = now + (STATE.HardModeNoMercy and TWIN_REPLACE_TICKS_HARD or TWIN_REPLACE_TICKS)
        return
    end
    if st.readyAt and now < st.readyAt then return end

    local inCombat = false
    pcall(function() inCombat = parent.CombatState == true end)
    if not inCombat then return end

    -- AVU.GetCurrentTarget, not raw GetCurrentCombatTarget: that reads nil for a beat after the
    -- combat flip, which would make the first attempt silently no-op.
    local target = AVU.GetCurrentTarget(parent)
    if not target then return end

    st.pending, st.pendingUntil, st.readyAt = true, now + TWIN_PENDING_TICKS, nil

    findTwinSpot(parent, target, function(spot)
        local s = twinState[key]
        if not spot then
            if s then s.pending = false end
            LogDebug("Exor Hunter - no out-of-LoS spot, retrying", SETTINGS.DEBUG_NPC_ACTIONS)
            return
        end
        if Utils.IsActorInvalid(parent) or parent.IsDead then
            if s then s.pending = false end
            return
        end

        AVU.SummonVariant(TWIN_VARIANT, spot, { SkipSpawnFX = true }, function(twin)
            onTwinSpawned(twin, parent, target)
            local s2 = twinState[key]
            if not s2 then return end
            s2.pending = false
            if Utils.IsActorValid(twin) then s2.twin = twin end
        end)
    end)
end


-- =======================================================================
-- THE HUNTER'S POST-SWING PAUSE - there is no cadence property on this chassis: the BT waits out
-- the montage's RAW length and swings again. The lever is the BT `Stunned` bool, which ABORTS the
-- tree's own wait rather than stacking with it, so budget the whole gap.
-- =======================================================================

local PACE = {
    Swing = 12,    -- let the 2-hit swipe land first (its hits are at 0.1s and 0.55s)
    Hold  = 18,    -- THE DIAL: how long it stands there afterwards
    Stale = 120,   -- a Hunter that died mid-pause never clears its own entry
}

local paceState = {}   -- Hunter key -> { at = swing tick, held = tick the pause began }

-- [AUTHORITY, def.OnMeleeSwing] Stamp a swing. One stamp per sequence: a re-stamp while a pause is
-- already pending is ignored, so a second swing cannot extend an in-flight hold.
local function paceArm(actor)
    local key = Utils.ActorKey(actor)
    if not key then return end

    local now = STATE.FAST_TICK
    for k, st in pairs(paceState) do
        if now - st.at > PACE.Stale then paceState[k] = nil end
    end

    if paceState[key] then return end
    paceState[key] = { at = now }
end

-- [AUTHORITY, def.OnTick] Drive the pause. One table probe when nothing is pending.
local function paceTick(actor)
    if next(paceState) == nil then return end
    local key = Utils.ActorKey(actor)
    local st = key and paceState[key]
    if not st then return end

    local now = STATE.FAST_TICK
    if not st.held then
        if now - st.at < PACE.Swing then return end
        st.held = now
        AVU.SetBtStunned(actor, true)
        return
    end

    if now - st.held < PACE.Hold then return end
    paceState[key] = nil
    -- Don't yank a REAL stun that landed on top of ours - it writes the same shared bool and its
    -- own Server_OnBuffRemove is what should clear it. Ours just expires and hands the flag over.
    if not AVU.HasGameplayTag(actor, "Modifier.Stunned") then AVU.SetBtStunned(actor, false) end
end


-- =======================================================================
-- THE KILLER'S RUSH - spent on its first swing or leap, never restored. The grace matters: the
-- leap branch outranks melee from 900uu out, so without it a Killer placed 30m away pounces on
-- its first BT beat and the rush is never seen.
-- =======================================================================

local KILLER_SLOW_SPEED = 300   -- def.BasicStats.SprintSpeed starts at KILLER_RUSH_SPEED (1500)

-- The live speed IS the flag: SetMoveSpeed writes the VariantTag fraction on top of the integer,
-- so the read comes back as KILLER_SLOW_SPEED plus a fraction below 1.
local function killerSlowed(actor)
    local cur
    pcall(function() cur = actor.NPCData[ENUMS.NpcData.SprintSpeed] end)
    return cur ~= nil and cur < KILLER_SLOW_SPEED + 1
end

local function killerCommitSlow(actor)
    if Utils.IsActorInvalid(actor) or killerSlowed(actor) then return end
    AVU.SetMoveSpeed(actor, KILLER_SLOW_SPEED, KILLER_SLOW_SPEED)
    LogDebug("Exor Killer - rush spent, leaping from here", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- =======================================================================
-- Entry points - bare references from ExorVolatile.lua
-- =======================================================================

H.LeapDamp = leapDamp
H.PaceArm = paceArm
H.KillerCommitSlow = killerCommitSlow

-- [HARD] The burst's first beat can land within 7s of aggro, and both of its resolves are
-- non-loading - warm them here so the opening burst isn't a mimed swing.
function H.AcidicEnterCombat(actor)
    if STATE.HardModeNoMercy then ASSETS.WarmPinned(SPIT_DEPS) end
end

-- [HARD] The acid burst, at a target it can see but cannot reach.
function H.AcidicTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    if not STATE.HardModeNoMercy or totalTicks % SPIT.BeatTicks ~= 0 then return end
    if not Utils.IsActorReadyToAttack(actor) then return end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end

    local d = Utils.DistSq(actor:K2_GetActorLocation(), target:K2_GetActorLocation())
    if d < SPIT.MinDist * SPIT.MinDist or d > SPIT.MaxDist * SPIT.MaxDist then return end

    if AVU.CanSeeActor(actor, target) then acidSpitVolley(actor, target) end
end

-- Acid blood splashes everything nearby when it takes physical damage. Deferred off-hook - the
-- caller is inside ProcessDamage, and dealing damage from there re-enters it.
function H.AcidicDamageTaken(victim, damage, dmgType)
    local hitType = AVU.RetaliateGate(victim, damage, dmgType, RETALIATE_TYPES,
        lastAcidBurstTick, ACID_THROTTLE_TICKS)
    if not hitType then return end

    local loc = victim:K2_GetActorLocation()
    if not loc then return end
    local faction
    pcall(function() faction = victim.Faction end)
    Utils.QueueWork(function() acidRetaliate(victim, loc, faction) end, 0)
    LogDebug("Acidic Exor - acid blood (" .. hitType .. ")", SETTINGS.DEBUG_NPC_ACTIONS)
end

function H.AcidicDeath(actor)
    if Utils.IsActorInvalid(actor) then return end
    lastAcidBurstTick[Utils.ActorKey(actor) or ""] = nil
    -- Stop the leak before the corpse/ragdoll frees the component under a live system. Renderer-
    -- local, so on a dedicated server this is a no-op and MP clients keep theirs to corpse-despawn.
    AVU.EndAttachedNiagara(actor)
end

function H.HunterTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return "REMOVE" end
    paceTick(actor)
    if totalTicks % TWIN_RETRY_TICKS ~= 0 then return end
    tryTwin(actor)
end

-- No OnEnterCombat on the Killer, so a Killer can never summon its own.
function H.HunterEnterCombat(actor)
    Utils.QueueWork(function() tryTwin(actor) end, TWIN_FIRST_MS)
end

function H.HunterDeath(actor)
    if Utils.IsActorInvalid(actor) then return end
    local key = actor:GetFullName()
    twinState[key], paceState[key] = nil, nil
end

-- Watches for the leap that ends the rush; a swing does the same through H.KillerCommitSlow.
-- Retires itself the moment the rush is spent - this is a one-shot, not ongoing work.
function H.KillerTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return "REMOVE" end
    if totalTicks % 2 ~= 0 then return end
    if killerSlowed(actor) then return "REMOVE" end

    local lunging = false
    pcall(function() lunging = actor.IsLunging == true end)
    if not lunging then return end
    killerCommitSlow(actor)
    return "REMOVE"
end

return H
