-- =======================================================================
-- Exor Monk helpers - the machinery behind AnteNPCs/ExorMonk.lua: the pushback nova both Magi
-- share, the Magus beam barrage, the frost weakness both Exorrior bodies carry, and the Shadow
-- Monk's decoy blink.
--
-- MUST-KNOWS
--   * H.ByMode reads STATE.HardModeNoMercy at USE time. Never cache what it returns - the flag
--     settles at world load, after this file is required, and /auhard flips it live.
--   * Every book here is keyed by Utils.ActorKey, so nothing collects them on its own: each
--     variant's OnDeath calls the matching H.*Forget.
--   * The nova PARKS the body (SetBtStunned). Its release is a queued work item PLUS a tick
--     backstop, because a starved queue would otherwise leave a body planted for good.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local ENUMS = require("AnteData.Enums")
local STATE = require("AnteCore.State")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local AVM = require("AnteUtils.AVMath")
local ASSETS = require("AnteCore.AssetManager")

local LogDebug = Utils.LogDebug

local H = {}

-- The shared Monk poll beat. Utils.ActorKey is a GetFullName, so every variant takes its key ONCE
-- per beat and passes it down rather than reading it on every tick.
local MONK_POLL = 20   -- ~2s

-- Pick the hard-mode value out of a { Normal =, Hard = } pair.
function H.ByMode(t) return STATE.HardModeNoMercy and t.Hard or t.Normal end


-- =======================================================================
-- CADENCE KNOBS the defs write in their own Stats step.
--
-- THE EXORRIOR AND THE EXORRIOR MAGUS SHARE A CADENCE, NUMBER FOR NUMBER - the two are meant to
-- read as the same body fighting differently, so only HP and damage separate them. That is why
-- they share one cadence table rather than each carrying its own copy.
--   * NPC_Exor_Monk channels for `AttackWindupTime * ApocalypticAttackSpeed` and the native beam
--     lands at the end of it, so each Cast is that product and the speed dial is derived from it.
--   * EXORM_WINDUP is the class default, written anyway: absolute values mean a /reload onto a
--     live body can't leave an older number in place.
-- =======================================================================

-- Magus channel shoots beams over its whole Windup attack and does not use ApocAttack
--   (Windup - 0.1s) [HARD] shortens its windup interval
H.MAGUS_WINDUP = { Normal = 2.5, Hard = 2 }

-- Both Exorrior bodies, in ms after the windup: Cast = the beam lands, Blink = the teleport fires.
-- A frosted body moves onto its mode's Frosted row for good (see FROST WEAKNESS).
local EXORRIOR_CADENCE = {
    Normal = { Cast = 2000, Blink = 600, Frosted = { Cast = 2500, Blink = 800 } },
    Hard   = { Cast = 1600, Blink = 700, Frosted = { Cast = 2000, Blink = 600 } },
}
H.EXORM_WINDUP = 2

local function exorriorCadence(frosted)
    local row = H.ByMode(EXORRIOR_CADENCE)
    return frosted and row.Frosted or row
end

-- ApocalypticAttackSpeed for that cadence.
function H.ExorriorAttackSpeed(frosted)
    return exorriorCadence(frosted).Cast / (H.EXORM_WINDUP * 1000)
end


-- =======================================================================
-- PUSHBACK NOVA - shared by BOTH Magi, in normal and hard.
--
-- The punctuation on a beam-caster's rhythm: every Nth attack it stops casting, blinks in close,
-- detonates, and throws everyone off it.
--
--   1. PARK    - SetBtStunned, the no-FX lever, so the tree stops driving it. Our own blink and
--                montage are direct calls and run right through it.
--   2. BLINK   - one hop, landing SHORT of the target rather than on top of it, so the wind-up
--                has a stage and the shove has somewhere to throw people.
--   3. WIND UP - the Volatile Exor's detonation montage, slowed. Purely a telegraph.
--   4. SHOVE   - the blast, NOVA.Swing after the blink. The burst starts NOVA.FxLead earlier,
--                because that system opens with a long build-up and would otherwise bloom after
--                the hit had already landed.
--   5. RECOVER - the detonate montage ends on a HELD final frame, so the body would stand frozen
--                in it for the rest of the park. Just after the blast it is stopped and the Exor
--                aggro clip covers the handover back to the tree.
-- The park outlasts all of it, so the body is still planted when the shove goes off.
--
-- COUNTED IN WINDUP ATTACKS, because that is the beat we can actually see. One
-- Broadcast_WindupAttack is one Server_DoRangedAttack (NPC_Exor_Monk Label_3067 -> Label_2046),
-- so the same count means different things per variant: the Exor Magus casts once per attack,
-- while ApocalypticMonk makes the Exorrior Magus cast THREE times. Each cfg's Every is in windups.
-- The count resets when the fight does, so every engagement opens on the same rhythm.
-- =======================================================================

local NOVA = {
    LeadIn   = 400,    -- ms after the attack lands before it plants
    Hold     = 3000,   -- ms it may neither move nor attack. Kept just past the shove.
    TpMin    = 100,    -- how close this tries to get before charging its nova attack
    TpMax    = 300,    -- 
    Swing    = { Normal = 2000, Hard = 1500 },  -- blink -> shove: the window to get clear
    FxLead   = 1400,   -- ms the burst leads the shove by, so its build-up peaks on the hit.
                       -- The burst fires at Swing - FxLead after the blink, floored at 0: any
                       -- value at or above Swing is the same burst-on-landing, however large.
    AnimRate = 0.7,
    Radius   = 600,    -- nova damage radius
    Knock    = 900,   -- nova knockback
    KnockUp  = 300,
    StunS    = 1,      -- nova stun
    FxSecs   = 6,      -- client-FX lifetime; the burst runs at a third speed, so be generous
    FxScale  = 3.5,    -- burst size, sent over the wire (AVU.SendClientFX) so /reload can tune it
    Chest    = "Spine2",
    Roar     = "EXOR_NOVA_ROAR",   -- client-FX key: the Volatile Exor's leap cry
    RecoverLag   = 400,   -- ms after the shove before the detonate pose is dropped
    RecoverBlend = 0.4,   -- seconds to blend that pose out
}

-- Pinned on the first windup of each cycle (novaArm) and re-loaded right before the nova fires:
-- minutes can pass between mutation and the nova, a preload only beats GC by timing, and an
-- unpinned path is a full UObject walk per load (CLAUDE.md 3). Debuff_ParryStun names its logic
-- object and its body overlay by ROW - loading neither follows from naming the debuff.
local NOVA_DEPS = {
    ENUMS.Effects.SHADOW_IMPACT_LITE, ENUMS.Anims.EXOR_VOLATILE_DETONATE, ENUMS.DamageType.Blunt,
    ENUMS.BuffObjects.Stunned, ENUMS.Effects.M_PARRY_INDICATOR, ENUMS.Anims.EXOR_AGGRO,
    ENUMS.SOUNDS.EXOR_VOLATILE_LEAP,
}

-- Each Magus' share of the nova, in WINDUPS (see the block header for why the two counts differ).
--   * Exor Magus: ApocalypticMonk off, so one windup is one attack.
--   * Exorrior Magus: ApocalypticMonk on, so 9 = three attacks, 6 = two.
local MAGUS_NOVA = {
    Label  = "Exor Magus",
    Every  = { Normal = 5,  Hard = 3 },
    Damage = { Normal = 75, Hard = 125 },
}
local EXORM_NOVA = {
    Label  = "Exorrior Magus",
    Every  = { Normal = 9,   Hard = 6 },
    Damage = { Normal = 100, Hard = 150 },
}

local novaHold  = {}   -- actor key -> NowMs the park lifts
local novaCount = {}   -- actor key -> windups since the last nova (or since the fight began)

-- [AUTHORITY] Let it fight again.
local function novaRelease(actor, key)
    if not novaHold[key] then return end
    novaHold[key] = nil
    -- Never clear a REAL stun that landed on top of ours - it owns the bool now.
    if not AVU.HasGameplayTag(actor, "Modifier.Stunned") then AVU.SetBtStunned(actor, false) end
end

-- [AUTHORITY] The burst, on the chest. It rides the client-FX channel, not BroadcastFX, purely so
-- it can be slowed and sized.
local function novaBurst(actor)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end

    local burst = actor:K2_GetActorLocation()
    local mesh = Utils.GetValidMesh(actor)
    if mesh then
        pcall(function()
            local s = mesh:GetSocketLocation(FName(NOVA.Chest))
            burst = FVector(s.X, s.Y, s.Z)
        end)
    end
    AVU.SendClientFX(burst, "EXOR_NOVA_BURST", NOVA.FxSecs, nil, nil, NOVA.FxScale)
end

-- [AUTHORITY] The shove itself, centred on the FEET so it reads as horizontal.
--   * Debuff_ParryStun is the quiet player stun. Every stun grants Modifier.Stunned (the real
--     input lock), but the electric screen wash is keyed off Buff.Zapped, which only the Zapped
--     rows carry - so this one locks the player without painting their UI.
--   * BlastDamage is the S6-safe AoE: players only, so nothing re-enters our own damage hooks.
local function novaShove(actor, cfg)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end

    AVU.BlastDamage(actor, actor:K2_GetActorLocation(), {
        Radius = NOVA.Radius, Damage = H.ByMode(cfg.Damage),
        DamageType = ENUMS.DamageType.Blunt,
        Knockback = NOVA.Knock, KnockbackUp = NOVA.KnockUp,
        Debuff = ENUMS.Debuffs.ParryStun, DebuffSeconds = NOVA.StunS,
    })
    LogDebug(cfg.Label .. " - pushback nova", SETTINGS.DEBUG_NPC_ACTIONS)
end

-- [AUTHORITY] Shake off the detonate pose once the blast is spent. The stop is the replicated one
-- so clients leave the pose too, and it is also what ends the locked-in-place window the montage
-- opened; the aggro clip then plays unlocked, so the tree can move the body straight through it.
local function novaRecover(actor)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end

    AVU.StopMontageReplicated(actor, ENUMS.Anims.EXOR_VOLATILE_DETONATE, NOVA.RecoverBlend)
    AVU.PlayMontageReplicated(actor, ENUMS.Anims.EXOR_AGGRO, 1, false)
end

local function novaBlink(actor, cfg)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end

    -- OnDone fires on every exit path, so a blink that finds no navmesh point still winds up and
    -- still shoves - the sequence is committed the moment the body plants.
    -- MaxDistSq is lifted because the helper's default guards against a WILD navmesh result, and
    -- this destination is already pinned to NOVA.TpMax of the target: the long hop IS the point,
    -- and the default would reject it exactly when the Magus has been casting from range.
    AVU.TeleportNearTarget(actor, {
        Radius = NOVA.TpMax, MinRadius = NOVA.TpMin, MaxDistSq = 1e8,
        OnDone = function()
            if Utils.IsActorInvalid(actor) or actor.IsDead then return end

            -- Land facing whoever it came for: a blink keeps the rotation it left with, and the
            -- park means nothing turns the body again until the shove is over.
            local target = actor:GetCurrentCombatTarget()
            if Utils.IsActorValid(target) then AVU.FaceTarget(actor, target) end

            AVU.PlayMontageReplicated(actor, ENUMS.Anims.EXOR_VOLATILE_DETONATE, NOVA.AnimRate, true)
            AVU.SendClientFX(actor:K2_GetActorLocation(), NOVA.Roar, 3)   -- the wind-up's voice

            local swing = H.ByMode(NOVA.Swing)
            Utils.QueueWork(function() novaBurst(actor) end, math.max(0, swing - NOVA.FxLead))
            Utils.QueueWork(function() novaShove(actor, cfg) end, swing)
            Utils.QueueWork(function() novaRecover(actor) end, swing + NOVA.RecoverLag)
        end,
    })
end

local function novaStart(actor, key, cfg)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end
    if novaHold[key] then return end

    novaHold[key] = Utils.NowMs() + NOVA.Hold
    AVU.SetBtStunned(actor, true)
    Utils.QueueWork(function() novaRelease(actor, key) end, NOVA.Hold)

    -- TeleportNearTarget queues its own work item, so a cold load calling back inside its EIGT
    -- flush still only does a table insert here - the blink itself lands on a clean tick.
    ASSETS.LoadAsync(NOVA_DEPS, function() novaBlink(actor, cfg) end)
end

-- [AUTHORITY] Count one windup. On the Nth, book the nova for just after this cast lands -
-- `afterMs` is when the variant's own volley finishes, so each one passes its own number.
local function novaArm(actor, key, cfg, afterMs)
    local n = (novaCount[key] or 0) + 1
    if n == 1 then ASSETS.WarmPinned(NOVA_DEPS) end   -- free after the first pin; beats the nova by cycles
    if n < H.ByMode(cfg.Every) then
        novaCount[key] = n
        return
    end
    novaCount[key] = 0
    Utils.QueueWork(function() novaStart(actor, key, cfg) end, afterMs + NOVA.LeadIn)
end

-- [AUTHORITY] Tick backstop: lift a park whose own release work item never drained.
local function novaSweep(actor, key)
    local until_ = novaHold[key]
    if until_ and Utils.NowMs() >= until_ then novaRelease(actor, key) end
end

-- Cheap gate for the tick backstop: an ActorKey is a GetFullName, and almost always nothing
-- anywhere is parked.
local function novaAnyParked() return next(novaHold) ~= nil end

-- [AUTHORITY] Fresh rhythm per engagement: a fight that ended mid-attack must not carry a
-- part-counted attack into the next one. Both Magi hang this on OnExitCombat.
function H.NovaResetCount(actor)
    local key = Utils.ActorKey(actor)
    if key then novaCount[key] = nil end
end


-- =======================================================================
-- MAGUS BEAM BARRAGE - the Exor Magus' single channel, fired as many weak beams.
--   WARMUP beams close in: each fires within a shrinking cone around the aim line (first wildly
--     off, last nearly on target).
--   MAIN beams re-aim at the player's live position each shot but scatter wide horizontally, so
--     strafing can't dodge the volley outright.
-- =======================================================================

-- WARMUP fires within a shrinking cone around the aim line (first wildly off, last nearly on
-- target). MAIN re-aims at the player's live position each shot but scatters wide, so strafing
-- can't dodge the volley outright.
local MAGUS_BARRAGE = {
    WarmupMs     = { 100, 500, 900 },   -- when each warmup beam fires (ms after windup)
    WarmupAngles = { 75, 50, 25 },        -- cone half-angle (deg) per warmup beam - closing in
    Count      = 8,     -- main beams
    Start      = 1700,  -- ms after windup the barrage begins
    Step       = 100,   -- ms between main beams
    MainSpread = 200,   -- main: WIDE horizontal +/- scatter around the tracked player (fewer land)
    MainZ      = 60,    -- main: small vertical +/- scatter (stay near body height)
    MinDist    = 200,   -- a target this close takes the native beam alone
}

-- Per-beam damage, dealt via ApplyRadialDamage AT the beam endpoint instead of the native hitscan
-- (why: see AVU.CastPsychicBeam). Obstacle check traces Magus eye -> beam endpoint; a
-- world-geometry hit blocks the beam, on the game's own sight channel (ENUMS.Trace.VISIBILITY).
local MAGUS_BEAM = {
    Damage = { Normal = 25, Hard = 40 },
    Radius = 120,   -- native beam 200
    EyeZ   = 80,    -- trace start height above the Magus root (approx eye/muzzle)
    TraceChannel = ENUMS.Trace.VISIBILITY,
}

-- Thin wrapper over the shared safe beam path (AVU.CastPsychicBeam - the WHY lives there).
-- Keeps the Magus defaults + the "magusBeam" breadcrumb label.
--   * The MinDist gate sits here so it reads each beam's own fire time, never the windup's: a
--     target that closes in mid-channel stops the rest of the barrage.
local function fireBeam(actor, target, loc, alwaysShow)
    if Utils.DistSqXY(actor:K2_GetActorLocation(), target:K2_GetActorLocation())
        <= MAGUS_BARRAGE.MinDist * MAGUS_BARRAGE.MinDist then return end

    AVU.CastPsychicBeam(actor, target, loc, {
        Dmg = H.ByMode(MAGUS_BEAM.Damage), Radius = MAGUS_BEAM.Radius,
        EyeZ = MAGUS_BEAM.EyeZ, Channel = MAGUS_BEAM.TraceChannel,
        AlwaysShow = alwaysShow, Crumb = "magusBeam",
    })
end

-- One warmup beam: a random forward direction inside beam k's cone.
local function warmupBeam(actor, k)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end

    local origin = actor:K2_GetActorLocation()
    local tgt = target:K2_GetActorLocation()
    local dx, dy, dz = tgt.X - origin.X, tgt.Y - origin.Y, tgt.Z - origin.Z
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    if dist < 1 then return end

    -- Rotate the aim direction by a random angle within the cone, then project to ~range.
    local loc = tgt
    pcall(function()
        local km = ASSETS.GetIfValid("/Script/Engine.Default__KismetMathLibrary")
        if not km then return end
        local cone = km:RandomUnitVectorInConeInDegrees(FVector(dx / dist, dy / dist, dz / dist),
            MAGUS_BARRAGE.WarmupAngles[k] or 0)
        loc = FVector(origin.X + cone.X * dist, origin.Y + cone.Y * dist, origin.Z + cone.Z * dist)
    end)

    fireBeam(actor, target, loc, true)  -- warmup: always show the visual (damage still gated)
end

-- One main beam: the player's live position, scattered wide.
local function mainBeam(actor)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end

    fireBeam(actor, target,
        AVM.ScatterPoint(target:K2_GetActorLocation(), MAGUS_BARRAGE.MainSpread, MAGUS_BARRAGE.MainZ))
end

-- [AUTHORITY] def.OnWindupAttack - warmup beams that close in, then a locked-on barrage, with the
-- nova following the last beam in.
function H.MagusWindup(actor)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end

    local key = Utils.ActorKey(actor)
    if not key or novaHold[key] then return end   -- parked: no cast at all

    -- ONE ratio for the whole schedule, so the barrage keeps its shape inside a shorter cast.
    local t = STATE.HardModeNoMercy and (H.MAGUS_WINDUP.Hard / H.MAGUS_WINDUP.Normal) or 1

    for k = 1, #MAGUS_BARRAGE.WarmupMs do
        Utils.QueueWork(function() warmupBeam(actor, k) end, MAGUS_BARRAGE.WarmupMs[k] * t)
    end
    for i = 1, MAGUS_BARRAGE.Count do
        Utils.QueueWork(function() mainBeam(actor) end,
            (MAGUS_BARRAGE.Start + i * MAGUS_BARRAGE.Step) * t)
    end

    novaArm(actor, key, MAGUS_NOVA,
        (MAGUS_BARRAGE.Start + MAGUS_BARRAGE.Count * MAGUS_BARRAGE.Step) * t)
end

-- [AUTHORITY] def.OnTick - nothing but the nova backstop, and only while something somewhere is
-- actually parked.
function H.MagusTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    if totalTicks % MONK_POLL ~= 0 or not novaAnyParked() then return end
    novaSweep(actor, Utils.ActorKey(actor))
end

function H.MagusForget(actor)
    local key = Utils.ActorKey(actor)
    if not key then return end
    novaHold[key], novaCount[key] = nil, nil
end


-- =======================================================================
-- FROST WEAKNESS - shared by both Exorrior bodies. A Slushie hit slows the body for good.
--
-- The slow is an ABSOLUTE CustomTimeDilation write, not a multiplier off the live value: Stats
-- re-runs on every save-restore / re-mutate and a read-multiply would compound (CLAUDE.md 3).
-- It is a raw write rather than AVU.SetTimeDilation because mirroring it would rubber-band a
-- moving client proxy, and position replicates anyway.
--
-- Time dilation alone never reaches the cast: that is a BP latent Delay, ticked on WORLD delta (the
-- same reason the peccary charge windup ignores it, AnNotes/AnteNPCs/Peccary.md). So the latch also moves
-- the body onto its Frosted cadence - the cast through ApocalypticAttackSpeed, the blink through
-- the latch book the windup handlers read.
-- =======================================================================

-- Hard lands less slowed: a hard Exorrior is meant to still be a threat after you freeze it once.
local FROST_TDI = { Normal = 0.65, Hard = 0.8 }   -- both bodies run def.TimeDilation 1.1
local FROST_BUFFS = { ENUMS.Debuffs.Frost, ENUMS.Debuffs.Frost2, ENUMS.Debuffs.Frost3 }

local frostedDone      = {}   -- Exorrior:       actor key -> true, latched on the first Frost hit
local exormFrostedDone = {}   -- Exorrior Magus: its own book, same shape

-- True on the beat a Frost buff first shows on a body not already latched.
local function frostPoll(actor, key, latchTbl)
    if not key or latchTbl[key] then return false end

    for _, buff in ipairs(FROST_BUFFS) do
        if Utils.ActorHasBuff(actor, buff) then return true end
    end
    return false
end

local function applyFrostSlow(actor, key, latchTbl, label)
    if latchTbl[key] then return end
    latchTbl[key] = true

    pcall(function() actor.CustomTimeDilation = H.ByMode(FROST_TDI) end)
    pcall(function() actor.ApocalypticAttackSpeed = H.ExorriorAttackSpeed(true) end)
    LogDebug(label .. " - frost weakness latched (permanently slowed)", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- =======================================================================
-- EXORRIOR - blinks mid-channel; frost is its one lasting weakness.
-- =======================================================================

-- Wrapper-keyed and weak: this book is read only from OnWindupAttack, which hands back a stable
-- wrapper. Its frost latch is string-keyed because OnTick and OnWindupAttack see different ones.
local teleportOn = setmetatable({}, { __mode = "k" })

-- [AUTHORITY] def.OnWindupAttack - one blink to a navigable point near the target, mid-channel.
-- RealTime pins the delay to real milliseconds: without it the helper scales the wait BY
-- CustomTimeDilation, so a frosted body would blink SOONER than a healthy one.
function H.ExorriorBlink(actor)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end

    -- One teleport at a time; the guard is cleared on every exit path via OnDone.
    if teleportOn[actor] then return end
    teleportOn[actor] = true
    local key = Utils.ActorKey(actor)
    AVU.TeleportNearTarget(actor, {
        Delay = exorriorCadence(key and frostedDone[key]).Blink, RealTime = true,
        OnDone = function() teleportOn[actor] = nil end,
    })
end

-- [AUTHORITY] def.OnTick - poll for a frost hit, then stop ticking: the slow is permanent and
-- there is nothing else on this body's beat.
function H.ExorriorTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    if totalTicks % MONK_POLL ~= 0 then return end

    local key = Utils.ActorKey(actor)
    if not frostPoll(actor, key, frostedDone) then return end
    applyFrostSlow(actor, key, frostedDone, "Exorrior")
    return "REMOVE"
end

function H.ExorriorForget(actor)
    local key = Utils.ActorKey(actor)
    if key then frostedDone[key] = nil end
end


-- =======================================================================
-- EXORRIOR MAGUS - the Exorrior's blink and cadence, casting the Magus beam, plus the nova.
-- =======================================================================

local exormTeleportOn = {}   -- actor key -> teleport in flight (read from OnTick too, so not the wrapper)

-- The native beam (NPCData.RangedDamage), and what each flank beam deals.
H.EXORM_BEAM_DAMAGE = { Normal = 70, Hard = 100 }

-- FLANK BEAMS - one either side of the native beam, landing with it, so a cast reads as a
-- three-beam volley. A small sidestep clears the native beam; a flat-out strafe runs into a flank.
--   * The flanks hang off a point LOCKED LockMs before they land. Measured from the live target
--     they would land Gap away from it whatever it did, and could never hit anyone.
--   * Reach from the locked point is Gap +/- (Radius + a capsule, ~160), with falloff toward the
--     edge. A player covers 500 uu/s walking and 685 sprinting, so LockMs sets how far out a
--     strafer has got and Gap sets which of them the flank is centred on.
local EXORM_FAN = {
    Gap     = 320,   -- uu beside the locked point each flank lands
    LockMs  = 500,   -- how long before landing the aim point is frozen; 0 = aim at the live target
    MinDist = 200,   -- a blink that landed this close casts the native beam alone
}

-- [AUTHORITY] Fired from where the body stands NOW (it has blinked since the windup), at the point
-- locked a moment ago. The close-range gate reads the live target, not the locked point.
local function exormFlankBeams(actor, key, locked)
    if Utils.IsActorInvalid(actor) or actor.IsDead or novaHold[key] then return end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end

    local origin = actor:K2_GetActorLocation()
    if Utils.DistSqXY(origin, target:K2_GetActorLocation()) <= EXORM_FAN.MinDist * EXORM_FAN.MinDist then return end

    local tgt = locked or target:K2_GetActorLocation()
    for _, side in ipairs({ 1, -1 }) do
        AVU.CastPsychicBeam(actor, target, AVM.PerpendicularPoint(origin, tgt, EXORM_FAN.Gap, side), {
            Dmg = H.ByMode(H.EXORM_BEAM_DAMAGE), Radius = MAGUS_BEAM.Radius,
            EyeZ = MAGUS_BEAM.EyeZ, Channel = MAGUS_BEAM.TraceChannel,
            AlwaysShow = true, Crumb = "exormFlank",
        })
    end
end

-- [AUTHORITY] def.OnWindupAttack - blink, then let the native beam fire with a flank beam either
-- side of it. Every Nth windup ends an attack the nova follows in on.
function H.ExormWindup(actor)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end

    local key = Utils.ActorKey(actor)
    if not key or novaHold[key] then return end   -- parked: no cast at all

    local cadence = exorriorCadence(exormFrostedDone[key])
    if not exormTeleportOn[key] then
        exormTeleportOn[key] = true
        AVU.TeleportNearTarget(actor, {
            Delay = cadence.Blink, RealTime = true,
            OnDone = function() exormTeleportOn[key] = nil end,
        })
    end
    local lockMs = math.min(EXORM_FAN.LockMs, cadence.Cast)
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        local target = actor:GetCurrentCombatTarget()
        if Utils.IsActorInvalid(target) then return end
        local t = target:K2_GetActorLocation()
        local locked = FVector(t.X, t.Y, t.Z)
        Utils.QueueWork(function() exormFlankBeams(actor, key, locked) end, lockMs)
    end, cadence.Cast - lockMs)
    novaArm(actor, key, EXORM_NOVA, cadence.Cast)
end

-- [AUTHORITY] def.OnTick - the frost poll and the nova backstop share one beat.
function H.ExormTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    if totalTicks % MONK_POLL ~= 0 then return end

    local key = Utils.ActorKey(actor)
    if not key then return end

    if frostPoll(actor, key, exormFrostedDone) then
        applyFrostSlow(actor, key, exormFrostedDone, "Exorrior Magus")
    end
    novaSweep(actor, key)
end

function H.ExormForget(actor)
    local key = Utils.ActorKey(actor)
    if not key then return end
    exormFrostedDone[key], exormTeleportOn[key] = nil, nil
    novaHold[key], novaCount[key] = nil, nil
end


-- =======================================================================
-- SHADOW MONK DECOY BLINK - every real teleport paints extra identical trails.
--
-- TWO trails per blink, one to each side, each with its own rolled yaw. Independent angles
-- matter: a fixed +/-90 puts both decoys on ONE axis, so whenever that axis happens to point at
-- or away from the camera BOTH foreshorten to a dot and the blink reads as having painted no
-- decoy. Two different angles can't hide together.
-- =======================================================================

-- MinLen: the monk blinks onto its target, so a close-quarters blink is only a few metres - long
-- enough for the real trail (you watch the body arrive), too short for a decoy to read.
local SHADOW_DECOY = {
    YawMin = 40, YawMax = 130,
    MinLen = 500,   -- 5m
    GapMs  = 120,   -- stagger the pair so they don't share one frame
}

-- Our decoy call dispatches through the same Broadcast_TeleportFX hook.
-- This latch lets the handler tell its own echo apart from a real blink.
local shadowDecoyOn = {}   -- actor key -> true while a decoy call is in flight

-- Fire one decoy: the same native multicast, aimed sideways off the real blink.
-- `side` is +1/-1; the angle itself is rolled per call so the pair never shares an axis.
-- Runs on the WorkQueue drain; the echo latch is cleared right after the call returns
-- (the local dispatch of a multicast is synchronous, so the echo has already been seen).
local function shadowDecoy(actor, key, px, py, pz, nx, ny, nz, side)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end

    local dx, dy = nx - px, ny - py
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1 then return end   -- zero-length blink: nothing to mirror

    -- Match the real blink's reach, but never paint a trail too short to read.
    if len < SHADOW_DECOY.MinLen then
        local k = SHADOW_DECOY.MinLen / len
        dx, dy = dx * k, dy * k
    end

    local yaw = SHADOW_DECOY.YawMin + math.random() * (SHADOW_DECOY.YawMax - SHADOW_DECOY.YawMin)
    local aim = AVM.RotateYaw(FVector(dx, dy, 0), side * yaw)

    shadowDecoyOn[key] = true
    pcall(function()
        actor:Broadcast_TeleportFX(FVector(px, py, pz), FVector(px + aim.X, py + aim.Y, nz))
    end)
    shadowDecoyOn[key] = nil
end

-- [AUTHORITY] def.OnTeleport - queue a decoy trail to each side of the real direction.
-- The endpoint args are the hook's param WRAPPERS, so copy the scalars before deferring.
function H.ShadowTeleport(actor, PreviousLocation, NewLocation)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end

    local key = Utils.ActorKey(actor)
    if not key then return end
    if shadowDecoyOn[key] then return end   -- our own echo, not a real blink

    local px, py, pz, nx, ny, nz
    local ok = pcall(function()
        local p, n = PreviousLocation:get(), NewLocation:get()
        px, py, pz, nx, ny, nz = p.X, p.Y, p.Z, n.X, n.Y, n.Z
    end)
    if not ok or not px or not nx then return end

    -- Never call a native multicast from inside its own hook (re-entrancy).
    -- Hop one drain instead (~0.1s after the real trail - close enough to read as simultaneous).
    Utils.QueueWork(function() shadowDecoy(actor, key, px, py, pz, nx, ny, nz, 1) end, 0)
    Utils.QueueWork(function() shadowDecoy(actor, key, px, py, pz, nx, ny, nz, -1) end,
        SHADOW_DECOY.GapMs)
end


return H
