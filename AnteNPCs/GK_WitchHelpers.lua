-- =======================================================================
-- Witch helpers - the machinery behind AnteNPCs/GK_Witch.lua
--
-- MUST-KNOWS (whys + decode detail: AnNotes/AnteNPCs/GKWitch.md, memory [[anteup2-witch-decode]])
--   * The grenade slot is a RED HERRING: CanThrowGrenades gates the ability slots (jetpack +
--     revive), not a throw. NEVER DisableGrenades on this base.
--   * Shield break must be POLLED (OnRep_ShieldBroken is unhookable on host), gated on
--     IsShieldComponentEnabled so a disengage doesn't read as a break.
--   * The hitscan gun CAN fire projectiles: LastRangedAttackLocation + a repointed GrenadeData ->
--     FireRanged_Projectile (AVU.FireProjectileRow).
--   * RangedAttack_OnCooldown SELF-CLEARS in 0.1s - hold it per tick (holdRangedCd), or the BT
--     re-runs the attack task and plays fire FX/sound with no shot behind it.
--   * After any scripted impulse, release the BT once GROUNDED (releaseWhenGrounded) or the witch
--     stalls waiting on a CombatReset - EndAbility_DoCombatReset self-skips while falling, so a
--     fixed-delay release fired midair is simply lost.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local G = require("AnteData.Items").Global
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local AVM = require("AnteUtils.AVMath")
local ASSETS = require("AnteCore.AssetManager")
local PROJ = require("AnteCore.Projectile")
local ProjectileRows = require("AnteCore.ProjectileRows")
local HIVE = require("AnteNPCs.PeccarySowHelpers")    -- the shared bee-cloud kit

local LogDebug = Utils.LogDebug

local H = {}


-- =======================================================================
-- SHARED
-- =======================================================================

-- Hold the soldier ranged gate CLOSED for `ticks` WQ ticks (~100ms each), then open it.
--   * A chain, because one write self-clears in ~0.1s and never covers a cadence window.
--   * Generation-guarded so back-to-back shots don't leave a stale chain clearing the new hold.
local cdHoldGen = {}   -- ActorKey -> hold generation

local function holdRangedCd(actor, ticks)
    local key = Utils.ActorKey(actor)
    if not key then return end
    cdHoldGen[key] = (cdHoldGen[key] or 0) + 1
    local gen = cdHoldGen[key]
    local function hop(left)
        if cdHoldGen[key] ~= gen then return end
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        if left <= 0 then
            pcall(function() actor.RangedAttack_OnCooldown = false end)
            return
        end
        pcall(function() actor.RangedAttack_OnCooldown = true end)
        Utils.QueueWork(function() hop(left - 1) end, 100)
    end
    hop(ticks)
end


-- Clear the burst flag + fire the BT reset valve once the witch is on the ground; while she's still
-- falling, re-queue (300ms apart, `tries` bounded).
local function releaseWhenGrounded(actor, tries)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end
    local falling = false
    pcall(function() falling = actor.CharacterMovement:IsFalling() end)
    if falling and tries > 0 then
        Utils.QueueWork(function() releaseWhenGrounded(actor, tries - 1) end, 300)
        return
    end
    pcall(function() actor.PerformingRangedBurst = false end)
    AVU.ReleaseSoldierBT(actor)
end


-- =======================================================================
-- WARRIOR WITCH
-- =======================================================================

-- Kick combo (native FireRanged_Projectile, fired on a connecting kick)
local WW_FIREBALL_ROW  = ENUMS.ProjectileRows.MageFireball   -- Fire_Plasma, ignites (off-hook impact)
local WW_FIREBALL_DMG  = 80

-- Can't chain melee, but kept just in case of a duplicate melee attack
local WW_KICK_CD_MS    = 350
local WW_AIM_Z         = 45    -- aim the fireball at centre mass

-- After kicking - launches a fireball from its jet while backflipping
local WW_JET = {
    Speed     = 1300,   -- row is 1500 
    Gravity   = 0,      -- row is 0.1
    Dmg       = 60,
    LifeSpanS = 4,
    Scale     = FVector(0.6, 0.6, 0.6),   -- visual only
    Muzzle    = "r_weapon_ranged1",   -- the gun, not NPC_Base's "head" default
    Ahead     = 90,     -- spawn this far down the aim ray, clear of her own capsule
    AimZ      = 15, -- 0 is ~torso level while grounded
    Lead      = 200,    -- fire this far past the target
}

-- Uses a mage plasma fireball as part of its jetpack attack, get the debuff deps
local WW_JET_DEPS = { ENUMS.Components.AREA_PLASMA_FIRE, ENUMS.DamageType.FirePlasma,
                      ENUMS.BuffObjects.IgnitedPlasma, ENUMS.BuffObjects.HPDamage }

-- The kick backflip knockback and delay (WWF_DELAY_MS, the kick to backflip gap)
local WW_BACKFLIP = {
    Back         = 800, 
    Up           = 700,
    CdTicks      = 8,     -- delay between flips (0.8s)
    AnimRate     = 1,     -- Dodge_Back montage rate
    ReleaseTries = 8,     -- grounded-release attempts, 300ms apart (~2.4s of falling covered)
}

-- =======================================================================
-- THE FAMILY KICK PROFILE (H.KickDamp) - shared by EVERY witch variant that kicks
-- =======================================================================
-- The native kick launch is HARDCODED: ScaledLaunchCharacter(dir * 1200, Z=200). No field to tune.
--   * Horizontal ADDS to the native shove. A counter-impulse back along the kick line SUBTRACTS.
--     We pass the CUT, so net back = 1200 - cut.
--   * Z is OVERRIDDEN outright (AVU.KnockbackFrom also passes bZOverride=true), so KICK_NET_UP
--     replaces the native 200 directly.
-- Per-variant overrides ride H.KickDamp's opts; these are the family defaults.
local KICK_NATIVE_HORIZ = 1200   -- native knockback
local KICK_NET_BACK     = 200    -- what we want left of it
local KICK_NET_UP       = 400    -- replaces the native
local WW_KNOCK_DELAY_MS = 100    -- after the impact broadcast, so the native launch has landed

-- Knockback effect on the witch's kick attack
local WW_KICK = { Back = 850, Up = 150, ConcussS = 4 }

-- The fireball as a RANGED attack (H.WarriorRangedAttack) - the suppressed shotgun's replacement,
-- used by anything that would rather lob than spray (the Mother's Warrior aspect while hovering).
local WW_FIRE_CD_TCK   = 15    -- FAST_TICKs between fireballs (~1.5s) - THE cadence, see the header
local WW_FIRE_DELAY_MS = 350   -- after Server_DoRangedAttack, so the ball leaves with the montage

local WW_SHOTGUN_CD  = 1      -- RangedAttackCooldown (1.0 base - hardcap?)
local WW_GRAVITY     = 1.3    -- 0.5 base - heavier = shorter jetpack arcs
local WW_AMMO        = 20     -- 8 base. Every reload inside 300uu makes her jetpack away FIRST
                              --   (tree branch 0), so a small clip is a melee tax
-- How long the frozen kick line stays usable, in FAST_TICKs. The shove reads it ~100ms after the
-- impact and the ball ~60ms after that; anything older belongs to the previous kick.
local WW_LINE_TTL    = 8

-- =======================================================================
-- THE KICK'S REACH AND TIMING - why it used to whiff on anyone walking backwards
-- =======================================================================
-- The damage sweep is a WORLD-time Delay(MeleeHitApex) while the montage runs on the body's own
-- clock (MeleeAttackPlayRate x CustomTimeDilation). At rate 1.35 / TD 0.9 the foot reached the
-- target at 0.54s and the sweep fired at the native 0.66 - a tenth of a second of free backpedal,
-- every kick. Divide the apex by the combined rate and the two land together.
-- Reach is the other half: the sweep is a 20uu needle RangeToMeleeAttack + MeleeRangeTraceExtra
-- long from the capsule, and RangeToMeleeAttack is also where the BT decides to swing at all.
local WW_MELEE = {
    Rate        = 1.5,
    TD          = 0.9,    -- MIRRORS def.TimeDilation; the pipeline writes that AFTER Stats(), so
                          --   it cannot be read live here
    NativeApex  = 0.66,
    TraceExtra  = 170,    -- 100 native -> a 370uu sweep, so the commit range is inside the needle
    TraceRadius = 45,     -- 20 native - a pencil catches nobody who is already leaning away
}
WW_MELEE.Apex = WW_MELEE.NativeApex / (WW_MELEE.Rate * WW_MELEE.TD)

-- THE STRAFE BOOST - her answer to being kited between kicks.
-- JetpackToLocation is the pawn's own leap primitive (arc-solve + ScaledLaunchCharacter + the
-- jetpack FX over OnRep_JetpackActive), and calling it directly costs no ability slot, so the
-- BT's 9s takeoff cooldown still holds the orbiting down. Aimed short of the target and offset
-- sideways, it reads as a boost-strafe rather than a leap-away.
--   * IT MUST LAND HER INSIDE MELEE RANGE. A boost that stops short is just another hop before
--     the same walk-in, so StopShort and Side are a PAIR: their hypotenuse is where she lands
--     relative to the target, and it has to stay under WW_MELEE.Range.
local WW_DASH = {
    Min       = 400,    -- inside this she is already swinging
    Max       = 800,    -- past this the H.Aggro lunge owns the gap (WW_CHASE_RANGE)
    StopShort = 120,    -- land this far short of the target along the approach...
    Side      = 150,    -- ...and this far to one side, alternating - the strafe read
    Overshoot = WW_GRAVITY,   -- the arc solve is handed gravity 1 and she falls at WW_GRAVITY, so
                              --   her airtime is 1/WW_GRAVITY of the solve: aim that much further
    CdTicks   = 22,     -- FAST_TICKs between boosts (~2.2s)
}

-- Small shield with a fast regen; breaking it flings her backward.
local WW_SHIELD  = { Max = 100, Regen = 25, RegenTime = 2, RegenTimeZero = 2.5, ShowFX = true }
local WW_RETREAT = { Horiz = 1200, Up = 400, CdTicks = 50 }

-- SHIELD-BREAK RECOIL - the shove has to STOP her, not just nudge her.
--   * Only while she is charging in: on the ground, not jetpacking, target within Range. There is
--     no blackboard "wants to melee" key - the attack tree's melee branch is just "close enough +
--     MeleeCounter low", and WarriorAggression pins that counter, so grounded-and-close IS the
--     run-in. A break mid-flight is left alone.
--   * The BT is parked (AVU.SetBtStunned) from the break until she has been back on her feet for
--     LandTicks: without it the chase MoveTo re-issues the instant the hop lands and air control
--     steers her straight back in. MinTicks is the floor, MaxTicks the escape if "landed" never reads.
--   * Our own gap-closers (H.Aggro's lunge, WarriorDash) stay off for NoChaseTicks - the retreat
--     leaves her past their trigger range, and they used to launch her straight back.
local WW_RECOIL = {
    Range        = 1200,
    MinTicks     = 8,    -- 0.8s parked at the least
    LandTicks    = 5,    -- ...and 0.5s after touching down: the stagger
    MaxTicks     = 30,
    NoChaseTicks = 30,   -- 3s from the break
}

-- Gap-closer. NOTE: an impulse that interrupts an attack can stall the witch (the BT waits
-- on a CombatReset) - that's what the stall backstop below exists for.
local WW_LUNGE_RANGE = 1500   -- >15m from the target (the default; Storm keeps this)
local WW_LUNGE_HORIZ = 1000
local WW_LUNGE_UP    = 200
local WW_LUNGE_CD_MS = 1500
local WW_STUCK_EPS   = 30     -- moved less than this...
local WW_STUCK_POLLS = 8      -- ...for this many consecutive in-combat polls (4s) = stalled

-- First-shot warmth only: FireRanged_Projectile async-loads by design
-- (cold = a delayed first shot, never a deadlock).
--   * The tick keep-warm reloads them off-peak (CLAUDE.md S3).
--   * The flip montage is here because PlayMontageReplicated skips a cold asset SILENTLY.
--   * The concussion's logic lives in a BuffLogic_ACTOR that nothing else in a session loads.
H.WARRIOR_ASSETS = { ENUMS.ProjectileClasses.MageFireball,
                     ENUMS.Anims.GKWITCH_RELOAD, ENUMS.Anims.INTERFECTOR_DODGE_BACK,
                     ENUMS.BuffObjects.ConcussedActor }
for _, dep in ipairs(WW_JET_DEPS) do H.WARRIOR_ASSETS[#H.WARRIOR_ASSETS + 1] = dep end

H.WW_SHOTGUN_CD = WW_SHOTGUN_CD

-- Kick -> fireball gap, shared by every witch that throws one (Warrior, the Mother's Warrior
-- aspect, the Warrior Acolyte). It trails the swing so the fireball leaves AFTER the kick has
-- connected and the target has been shoved - fire it too early and it flies past a target the
-- kick has not moved yet.
H.KICK_SWING_FIRE_MS = 600   -- was 400

-- Per-actor state, keyed by Utils.ActorKey
local wwKickMs     = {}   -- key -> last kick-fireball time (os.clock ms)
local wwFireTick   = {}   -- key -> FAST_TICK of the last RANGED fireball (the manual cadence gate)
local wwKnockMs    = {}   -- key -> last on-hit shove time (os.clock ms)
local wwFlipTick   = {}   -- key -> FAST_TICK of the last backflip
local wwShieldPrev = {}   -- key -> last polled CurrentShieldHitPoints (break detect)
local wwLungeMs    = {}   -- key -> last gap-closer time (os.clock ms)
local wwRecoil     = {}   -- key -> { at = FAST_TICK of the break, landed = FAST_TICK? } while parked
local wwRecoilAt   = {}   -- key -> FAST_TICK of the last recoil (the gap-closer hold)
local wwLastPos    = {}   -- key -> last polled location (stall detect)
local wwStuck      = {}   -- key -> consecutive not-moving polls
local wwKickLine   = {}   -- key -> the bearing the last kick launched its target along
local wwDashTick   = {}   -- key -> FAST_TICK of the last strafe boost
local wwDashSide   = {}   -- key -> which way the last boost went (alternates)
local dashCallDead = false   -- one-shot: JetpackToLocation refused to resolve


-- The bearing the native kick launched its target along, frozen at the impact broadcast, or nil
-- if the last one is too old to trust. Everything the combo does afterwards has to use THIS and
-- not a live re-derivation: the shove lands 100ms later and the backflip 60ms after that, and by
-- then the witch has moved - which put the shove and the ball a few degrees off the line the
-- target was actually travelling, and a few degrees is a clean miss.
local function wwKickBearing(key)
    local line = key and wwKickLine[key]
    if not line then return nil end
    if (STATE.FAST_TICK - line.Tick) > WW_LINE_TTL then return nil end
    return line
end


-- THE FAMILY KICK PROFILE: re-shapes the native launch into a back-and-UP pop (see the knob block
-- above for the why and the arithmetic). `profile` = { Back, Up, ConcussS }, all optional.
--   * Direction re-derived from LIVE positions, so it follows wherever the kick actually sent them.
--   * Own gate - the kick can multi-hit point blank.
--   * `towards = true` + a POSITIVE cut = back along the kick line: it subtracts from the shove
--     rather than adding a second one. A profile asking for MORE than the native 1200 flips the
--     sign, which adds instead - the same call either way.
--   * The concussion is players-only: an NPC would dispatch its own OnDamageTaken from here.
local function wwKickDamp(actor, profile)
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return end
    if not Utils.IsAuthority() then return end

    local key = Utils.ActorKey(actor)
    local now = (os and os.clock and os.clock() * 1000) or 0   -- 0 = no clock, gate can't run
    if key and now > 0 and not AVU.CooldownReady(wwKnockMs, key, WW_KICK_CD_MS, { Now = now }) then return end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) or Utils.IsDeadSafe(target) then return end

    local al
    pcall(function() al = actor:K2_GetActorLocation() end)
    if not al then return end

    profile = profile or {}
    local cut = KICK_NATIVE_HORIZ - (profile.Back or KICK_NET_BACK)
    local up = profile.Up or KICK_NET_UP
    local line = wwKickBearing(key)
    if line then
        -- Straight back down the frozen line, so the cut subtracts from the native launch instead
        -- of steering it. OverrideXY false = it ADDS; the Z leg replaces outright either way.
        AVU.KnockbackVelocity(target, FVector(-line.DX * cut, -line.DY * cut, up),
            { OverrideXY = false })
    else
        AVU.KnockbackFrom(target, al, cut, up, true)
    end
    if profile.ConcussS and Utils.IsPlayer(target) then
        Utils.ApplyBuffLinked(target, ENUMS.Debuffs.Concussed, profile.ConcussS)
    end
    LogDebug("Warrior Witch - kick shove (hit)", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- The deferred fireball fired by H.WarriorRangedAttack, CD-gated via holdRangedCd (file header).
local function wwFireBall(actor)
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) or Utils.IsDeadSafe(target) then return end
    local aim
    pcall(function()
        local t = target:K2_GetActorLocation()
        aim = FVector(t.X, t.Y, t.Z + WW_AIM_Z)
    end)
    if not aim then return end

    local dmg = WW_FIREBALL_DMG
    pcall(function() dmg = actor.NPCData[ENUMS.NpcData.RangedDamage] or dmg end)
    AVU.FireProjectileRow(actor, WW_FIREBALL_ROW, dmg, aim)
    LogDebug("Warrior Witch - ranged fireball", SETTINGS.DEBUG_NPC_ACTIONS)

    holdRangedCd(actor, WW_FIRE_CD_TCK - 3)
    Utils.QueueWork(function() AVU.ReleaseSoldierBT(actor) end, 600)
end


-- Is she charging in? See WW_RECOIL.
local function wwChargingIn(actor)
    local grounded, jet = false, true
    pcall(function()
        jet = actor.JetpackActive == true
        grounded = actor.CharacterMovement:IsMovingOnGround() == true
    end)
    if jet or not grounded then return false end
    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return false end
    local aLoc, tLoc
    pcall(function() aLoc = actor:K2_GetActorLocation(); tLoc = target:K2_GetActorLocation() end)
    return (aLoc and tLoc and AVM.DistXY(aLoc, tLoc) <= WW_RECOIL.Range) or false
end

-- Shield broke while charging in: park the tree, fling her backward, hold her down (WW_RECOIL).
--   * AVU.Jump self-cooldowns here, so a rapid re-break can't chain retreats.
local function wwRetreat(actor)
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return end
    local key = Utils.ActorKey(actor)
    if not key or not wwChargingIn(actor) then return end

    -- Park FIRST, so the tree has let go of its MoveTo before the launch - otherwise it keeps
    -- steering her into the target through the hop.
    AVU.SetBtStunned(actor, true)
    -- Zero residual velocity - a running start leaves velocity the launch alone doesn't cancel.
    pcall(function() actor.CharacterMovement:StopMovementImmediately() end)
    local hopped = AVU.Jump(actor, {
        Dir = "back",
        Distance = WW_RETREAT.Horiz,
        Up = WW_RETREAT.Up,
        Cooldown = WW_RETREAT.CdTicks,
        CooldownKey = "witchretreat",
    })
    if not hopped then
        if not AVU.HasGameplayTag(actor, "Modifier.Stunned") then AVU.SetBtStunned(actor, false) end
        return
    end
    wwRecoil[key] = { at = STATE.FAST_TICK }
    wwRecoilAt[key] = STATE.FAST_TICK
    LogDebug("Warrior Witch - shield broke, recoiling", SETTINGS.DEBUG_NPC_ACTIONS)
end

-- [AUTHORITY, every tick] End a recoil once she has been down for WW_RECOIL.LandTicks. One table
-- probe when there is none.
--   * STALL FIX on release: the recoil aborts whatever the BT was mid-doing. If that was a burst,
--     the native burst-end never runs and the BT waits on a CombatReset forever - so clear it and
--     release. The tick stall backstop catches any miss.
function H.WarriorRecoilTick(actor)
    local key = Utils.ActorKey(actor)
    local st = key and wwRecoil[key]
    if not st then return end

    local now = STATE.FAST_TICK
    local held = now - st.at
    if not st.landed and held >= 3 then   -- the launch reads "grounded" for a tick or two
        local grounded = false
        pcall(function() grounded = actor.CharacterMovement:IsMovingOnGround() == true end)
        if grounded then st.landed = now end
    end
    local done = (st.landed and now - st.landed >= WW_RECOIL.LandTicks and held >= WW_RECOIL.MinTicks)
        or held >= WW_RECOIL.MaxTicks
    if not done then return end

    wwRecoil[key] = nil
    -- A real stun that landed during the recoil owns the shared bool now (see AVU.SetBtStunned).
    if not AVU.HasGameplayTag(actor, "Modifier.Stunned") then AVU.SetBtStunned(actor, false) end
    pcall(function() actor.PerformingRangedBurst = false end)
    AVU.ReleaseSoldierBT(actor)
end

-- True while a recent recoil should keep our own gap-closers off her (WW_RECOIL.NoChaseTicks).
local function wwRecoiling(key)
    local at = key and wwRecoilAt[key]
    return at ~= nil and at <= STATE.FAST_TICK and STATE.FAST_TICK - at < WW_RECOIL.NoChaseTicks
end


-- [HARD] Shared by all three witches: the shell stays up out of combat, so catching one before
-- it has seen you is no longer a free opening volley.
function H.HardShieldStance(actor)
    if STATE.HardModeNoMercy then AVU.ShieldAlwaysOn(actor) end
end


function H.WarriorLoadout(actor)
    pcall(function() actor.RangedAttack_Cooldown = WW_SHOTGUN_CD end)   -- live mirror of BasicStats
    -- The kick: faster chain, an apex that lands with the foot, and a sweep wide enough to catch
    -- someone already walking away (see the WW_MELEE block for the arithmetic).
    pcall(function()
        actor.MeleeAttackPlayRate = WW_MELEE.Rate      -- a montage rate, so it replicates for free
        actor.MeleeHitApex = WW_MELEE.Apex
        actor.MeleeRangeTraceExtra = WW_MELEE.TraceExtra
        actor.MeleeTraceRadius = WW_MELEE.TraceRadius
    end)
    -- BasicStats moved the stat; the tree reads the blackboard COPY, written once on possess, so
    -- mirror whatever it landed on. Repeated once late in case the controller had no board yet.
    local function mirrorMeleeRange()
        local range
        pcall(function() range = actor.NPCData[ENUMS.NpcData.MeleeAttackRange] end)
        if range then AVU.SetBlackboardFloat(actor, "RangeToMeleeAttack", range) end
    end
    mirrorMeleeRange()
    Utils.QueueWork(function()
        if Utils.IsActorValid(actor) then mirrorMeleeRange() end
    end, 1500)
    -- NO JETPACK COOLDOWN IS WRITTEN, deliberately. Cooldown_CombatAbility3 is only ever read by
    -- SetAbilityOnCooldown, and nothing on the soldier line calls it for slot 3 - the takeoff is
    -- ungated on this base, which is why she orbits. H.WarriorAggression is the real lever.
    pcall(function() actor.MaxAmmoCount = WW_AMMO end)
    pcall(function() actor.CurrentAmmoCount = WW_AMMO end)
    -- Kill the native projectile DODGE.
    --   * PerformEvadeAbility jetpacks her to a RANDOM navigable point when attacked (the "gets
    --     hit midair, flies far in a random direction") and it fought our retreat impulse.
    --   * The shield-break retreat IS her reposition now.
    pcall(function() actor.EvadesProjectiles = false end)
    pcall(function() actor.LeaveFireWithJetpack = false end)   -- the kick fireball is the fire driver
    -- Write BOTH gravity fields: the game seeds GravityScale from DefaultGravityScale.
    pcall(function() actor.DefaultGravityScale = WW_GRAVITY end)
    pcall(function() actor.CharacterMovement.GravityScale = WW_GRAVITY end)

    AVU.SetBodyShield(actor, WW_SHIELD)
    H.HardShieldStance(actor)

    -- DELIBERATELY NOT TOUCHED: CanThrowGrenades / DisableGrenades (see the header).
end


-- KICK CONNECTS. Freeze the launch bearing HERE, in the impact broadcast, before anything else
-- has moved - the shove and the fire jet both read it (see wwKickBearing). The fireball itself is
-- not queued here; it rides the SWING, hit or miss.
function H.WarriorImpact(actor)
    if Utils.IsActorInvalid(actor) then return end

    local key = Utils.ActorKey(actor)
    local target = key and actor:GetCurrentCombatTarget()
    if key and Utils.IsActorValid(target) then
        local a, t
        pcall(function() a = actor:K2_GetActorLocation() end)
        pcall(function() t = target:K2_GetActorLocation() end)
        if a and t then
            local dx, dy = t.X - a.X, t.Y - a.Y
            local d = math.sqrt(dx * dx + dy * dy)
            if d > 1 then
                wwKickLine[key] = { DX = dx / d, DY = dy / d, OX = a.X, OY = a.Y,
                                    Tick = STATE.FAST_TICK }
            end
        end
    end

    H.KickDamp(actor, WW_KICK)
end


function H.WarriorCleanup(actor)
    local key = Utils.ActorKey(actor)
    if not key then return end
    wwKickMs[key] = nil; wwKnockMs[key] = nil; wwFlipTick[key] = nil; wwFireTick[key] = nil
    wwShieldPrev[key] = nil
    wwLungeMs[key] = nil; wwLastPos[key] = nil; wwStuck[key] = nil
    wwDashTick[key] = nil; wwDashSide[key] = nil; wwKickLine[key] = nil
    -- Orphan any in-flight cooldown-hold chain (a gen mismatch bails its next hop).
    cdHoldGen[key] = (cdHoldGen[key] or 0) + 1
end


-- The SLOW fire jet: the same plasma ball, spawned by us so we own its speed (the native gun path
-- takes every travel property from the row). Fired down a frozen line at centre mass - no homing,
-- no droop - so it chases a target the kick has already launched and catches them late in the arc.
local function wwFireJet(actor, target, key)
    local muzzle, aim
    pcall(function() muzzle = actor.Mesh:GetSocketLocation(FName(WW_JET.Muzzle)) end)
    if not muzzle or (muzzle.X == 0 and muzzle.Y == 0 and muzzle.Z == 0) then
        pcall(function()
            local a = actor:K2_GetActorLocation()
            muzzle = FVector(a.X, a.Y, a.Z + 80)
        end)
    end
    -- Down the frozen kick line, at the distance they have already reached plus a lead. On a
    -- MISS there is no line, and aiming at where they stand is right.
    local line = wwKickBearing(key)
    pcall(function()
        local t = target:K2_GetActorLocation()
        if line then
            local dx, dy = t.X - line.OX, t.Y - line.OY
            local d = math.sqrt(dx * dx + dy * dy) + WW_JET.Lead
            aim = FVector(line.OX + line.DX * d, line.OY + line.DY * d, t.Z + WW_JET.AimZ)
        else
            aim = FVector(t.X, t.Y, t.Z + WW_JET.AimZ)
        end
    end)
    if not muzzle or not aim then return end

    -- The native gun off the slow row. It reads the muzzle socket and the aim at spawn: the gun
    --   socket stays set from here on, so her other native shots leave the gun too (they used to
    --   leave NPC_Base's "head" default). AimZ is already in `aim`, so no native offset on top.
    --   Falls through to the scripted ball when it will not fire: row not ready, or stunned.
    pcall(function()
        actor.ProjectileFireSocket = FName(WW_JET.Muzzle)
        actor.RangedTarget_VerticalOffset = 0
    end)
    if ProjectileRows.Fire(actor, ENUMS.ProjectileRows.WitchJetFireball, WW_JET.Dmg, aim) then return end

    local dir = Utils.Direction(muzzle, aim)
    if dir.X == 0 and dir.Y == 0 and dir.Z == 0 then return end   -- muzzle inside the target
    local from = FVector(muzzle.X + dir.X * WW_JET.Ahead,
                         muzzle.Y + dir.Y * WW_JET.Ahead,
                         muzzle.Z + dir.Z * WW_JET.Ahead)

    PROJ.Queue(from, dir, ENUMS.ProjectileClasses.MageFireball, nil, {
        Owner = actor,                 -- Instigator defaults to Owner, and the impact patch's
                                       --   IgnoreInstigatorAndAllies needs it set to deal damage
        Damage = WW_JET.Dmg,
        Velocity = WW_JET.Speed,
        MaxSpeed = WW_JET.Speed,       -- the row caps at 1500; pin it or BeginPlay ramps back up
        GravityScale = WW_JET.Gravity,
        LifeSpan = WW_JET.LifeSpanS,
        Scale = WW_JET.Scale,
        DamageTypeClass = ENUMS.DamageType.FirePlasma,
        Preload = WW_JET_DEPS,
        _traceName = "witchFireJet",
    })
end


-- The kick-SWING payload: a plasma ball at centre mass, CD-gated so a rapid kick chain isn't a
-- projectile firehose. `opts.Jet` picks the slow self-fired ball (the Warrior); without it the
-- shot goes out through the native gun at the row's own 1500, which is what the Mother's Warrior
-- aspect and the Warrior Acolyte still throw.
function H.WarriorKickSwing(actor, opts)
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return end
    if not Utils.IsAuthority() then return end

    local key = Utils.ActorKey(actor)
    local now = (os and os.clock and os.clock() * 1000) or 0   -- 0 = no clock, gate can't run
    if key and now > 0 and not AVU.CooldownReady(wwKickMs, key, WW_KICK_CD_MS, { Now = now }) then return end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end

    if opts and opts.Jet then
        wwFireJet(actor, target, key)
        LogDebug("Warrior Witch - fire jet (swing)", SETTINGS.DEBUG_NPC_ACTIONS)
        return
    end

    local mass
    pcall(function()
        local t = target:K2_GetActorLocation()
        mass = FVector(t.X, t.Y, t.Z + WW_AIM_Z)
    end)
    if not mass then return end

    AVU.FireProjectileRow(actor, WW_FIREBALL_ROW, WW_FIREBALL_DMG, mass)
    LogDebug("Warrior Witch - kick fireball (swing)", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- [OnRangedAttack] the suppressed shotgun's replacement - see the knob block above for who uses
-- it. Manual cadence gate first (OverrideSoldierFireLogic kills the native one) + holdRangedCd.
function H.WarriorRangedAttack(actor)
    if Utils.IsActorInvalid(actor) or not Utils.IsAuthority() then return end
    local key = Utils.ActorKey(actor)
    if not key then return end
    if not AVU.CooldownReady(wwFireTick, key, WW_FIRE_CD_TCK) then return end
    Utils.QueueWork(function() wwFireBall(actor) end, WW_FIRE_DELAY_MS)
end


-- [AUTHORITY] call from any kicking witch's OnMeleeImpact - defers to wwKickDamp so the native
-- launch has landed first. `profile` (optional) overrides the family Back / Up / ConcussS.
function H.KickDamp(actor, profile)
    if Utils.IsActorInvalid(actor) then return end
    Utils.QueueWork(function() wwKickDamp(actor, profile) end, WW_KNOCK_DELAY_MS)
end


-- The FAKE backflip: a back+up hop wearing the Interfector's back-dodge montage.
--   * ONE gate covers montage AND impulse so they always ship together (three stacked silent
--     gates used to drop ~half the flips - post-mortem in AnNotes/AnteNPCs/GKWitch.md).
--   * AVU.Jump cancels the in-flight MoveTo (else the controller drives through the impulse)
--     but runs at Cooldown=0 - the cadence is owned here.
function H.WarriorBackflip(actor)
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return end
    if not Utils.IsAuthority() then return end

    local key = Utils.ActorKey(actor)
    if not key then return end
    if not AVU.CooldownReady(wwFlipTick, key, WW_BACKFLIP.CdTicks) then return end

    -- The LOOK first: unlocked (lockInPlace=false) so the launch carries her through it, replicated
    -- so clients see it too.
    AVU.PlayMontageReplicated(actor, ENUMS.Anims.INTERFECTOR_DODGE_BACK, WW_BACKFLIP.AnimRate, false)

    pcall(function() actor.CharacterMovement:StopMovementImmediately() end)
    local hopped = AVU.Jump(actor, {
        Dir = "back",
        Distance = WW_BACKFLIP.Back,
        Up = WW_BACKFLIP.Up,
        Cooldown = 0,                 -- this function owns the cadence
        CooldownKey = "witchflip",    -- so it can never share AVU.Jump's bare key
    })
    if not hopped then
        -- No readable threat to hop away FROM - shove her straight backwards along her own facing,
        -- so the montage never plays over a stationary body.
        pcall(function()
            local f = actor:GetActorForwardVector()
            actor:LaunchCharacter(FVector(-f.X * WW_BACKFLIP.Back, -f.Y * WW_BACKFLIP.Back, WW_BACKFLIP.Up), true, true)
        end)
    end

    Utils.QueueWork(function() releaseWhenGrounded(actor, WW_BACKFLIP.ReleaseTries) end, 500)
    LogDebug("Warrior Witch - backflip", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- [AUTHORITY, cadenced from OnTick] THE STRAFE BOOST - a short diagonal jetpack hop that closes
-- ground while sliding sideways, so the walk-in between kicks stops being a straight line to shoot
-- at. See the WW_DASH block for why this rides JetpackToLocation rather than the ability slot.
--   * Grounded only, and never mid-swing: a launch through the kick throws it off the target and
--     leaves the BT waiting on a CombatReset.
--   * Landing point is short of the target and offset to alternating sides, lifted by Overshoot
--     because the arc solve assumes normal gravity and she is heavy.
function H.WarriorDash(actor)
    if not Utils.IsAuthority() then return end
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return end

    local key = Utils.ActorKey(actor); if not key then return end
    if wwRecoiling(key) then return end

    local busy = true
    pcall(function()
        busy = actor.PerformingMeleeAttack or actor.LockedInPlaceMontage
            or actor.JetpackActive or actor.CharacterMovement:IsFalling()
    end)
    if busy then return end

    local inCombat = false
    pcall(function() inCombat = actor.CombatState == true end)
    if not inCombat then return end
    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) or Utils.IsDeadSafe(target) then return end

    local aLoc, tLoc
    pcall(function() aLoc = actor:K2_GetActorLocation() end)
    pcall(function() tLoc = target:K2_GetActorLocation() end)
    if not aLoc or not tLoc then return end
    local dist = AVM.DistXY(aLoc, tLoc)
    if dist < WW_DASH.Min or dist > WW_DASH.Max then return end
    -- Last, so a boost she was never going to take doesn't burn the window.
    if not AVU.CooldownReady(wwDashTick, key, WW_DASH.CdTicks) then return end

    local dx, dy = (tLoc.X - aLoc.X) / dist, (tLoc.Y - aLoc.Y) / dist
    local side = -(wwDashSide[key] or -1)
    wwDashSide[key] = side
    -- Where she should END UP: just short of the target, one capsule's width to the side
    -- (perpendicular = UE +90deg CCW of forward = (-uy, ux)).
    local wantX = tLoc.X - dx * WW_DASH.StopShort - dy * WW_DASH.Side * side
    local wantY = tLoc.Y - dy * WW_DASH.StopShort + dx * WW_DASH.Side * side
    -- The whole travel vector is overshot, not just its forward leg, or the sideways half lands
    -- short and the arc curls in.
    local land = FVector(aLoc.X + (wantX - aLoc.X) * WW_DASH.Overshoot,
                         aLoc.Y + (wantY - aLoc.Y) * WW_DASH.Overshoot,
                         tLoc.Z)

    -- A name that won't resolve fails IDENTICALLY to a boost she declined, so say so once.
    if not pcall(function() actor:JetpackToLocation(land) end) then
        if not dashCallDead then
            dashCallDead = true
            Utils.LogBad("Warrior Witch - JetpackToLocation did not resolve; strafe boost is dead")
        end
        return
    end

    Utils.QueueWork(function() releaseWhenGrounded(actor, WW_BACKFLIP.ReleaseTries) end, 500)
    LogDebug("Warrior Witch - strafe boost (" .. math.floor(dist) .. "uu)", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- [AUTHORITY, cadenced from OnTick] Hold the two blackboard counters the attack tree uses to
-- decide it would rather reposition than fight.
--   * FailedHits >= 3 is a whole branch ABOVE melee, and a shotgun spraying 15/10/3 degrees trips
--     it within seconds of any firefight - it is most of the "3-4 hops before it commits".
--   * MeleeCounter >= 1 sends an in-range body to relocate instead of swinging. It self-clears in
--     the melee sequence, so this is belt and braces.
-- Neither is exposed as a property and the tree asset is not ours to edit; zeroing them is how the
-- branch stops firing for one NPC.
function H.WarriorAggression(actor)
    if not Utils.IsAuthority() then return end
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return end
    AVU.SetBlackboardInt(actor, "FailedHits", 0)
    AVU.SetBlackboardInt(actor, "MeleeCounter", 0)
end


-- A >0 -> <=0 transition on an ENABLED shield component = a real break (AVU.ShieldBreakPoll owns
-- both of those rules; wwRetreat's own AVU.Jump cooldown is what rate-limits a rapid re-break).
-- Polled every tick: at the old 0.5s cadence she was often already into the kick by the time the
-- break was seen.
function H.WarriorShieldPoll(actor)
    local key = Utils.ActorKey(actor)
    if not key or actor.IsDead or actor.IsDBNO then return end

    if AVU.ShieldBreakPoll(actor, wwShieldPrev, key) then
        Utils.QueueWork(function() wwRetreat(actor) end, 0)   -- break -> retreat off-hook
    end
end


-- [AUTHORITY] Keep her near melee (RangedAttackRange does nothing on this base), and break a stall.
--   * An impulse landing during a shotgun attack freezes the witch - poll her position and
--     unblock her if she stops moving for long enough.
--   * Shared: Warrior passes its own 8m chase range, Storm takes the 15m default.
function H.Aggro(actor, lungeRange)
    if not Utils.IsAuthority() then return end
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return end
    lungeRange = lungeRange or WW_LUNGE_RANGE

    local inCombat = false
    pcall(function() inCombat = actor.CombatState == true end)
    if not inCombat then return end
    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end

    local key = Utils.ActorKey(actor); if not key then return end
    if wwRecoiling(key) then return end   -- the recoil owns her (Warrior only; nobody else stamps it)
    local aLoc, tLoc
    pcall(function() aLoc = actor:K2_GetActorLocation() end)
    pcall(function() tLoc = target:K2_GetActorLocation() end)
    if not aLoc or not tLoc then return end
    local dist = AVM.DistXY(aLoc, tLoc)
    local now = (os and os.clock and os.clock() * 1000) or 0   -- 0 = no clock, gate can't run

    -- 1) GAP-CLOSER (LaunchCharacter overrides velocity, so no pre-stop needed; the BT already wants
    -- to go this way, so it doesn't fight the impulse).
    if dist > lungeRange then
        if now == 0 or AVU.CooldownReady(wwLungeMs, key, WW_LUNGE_CD_MS, { Now = now }) then
            AVU.LaunchCharacterFrom(actor, tLoc, WW_LUNGE_HORIZ, WW_LUNGE_UP, true)
            LogDebug("Warrior Witch - lunge in (" .. math.floor(dist) .. "uu)", SETTINGS.DEBUG_NPC_ACTIONS)
        end
        wwStuck[key] = 0   -- moving now, not stuck
        wwLastPos[key] = aLoc
        return
    end

    -- 2) STALL BACKSTOP: in range but frozen in place.
    local last = wwLastPos[key]
    wwLastPos[key] = aLoc
    local moved = last and AVM.DistXY(last, aLoc) or 999
    wwStuck[key] = (moved < WW_STUCK_EPS) and ((wwStuck[key] or 0) + 1) or 0
    if (wwStuck[key] or 0) >= WW_STUCK_POLLS then
        wwStuck[key] = 0
        pcall(function() actor.PerformingRangedBurst = false end)
        AVU.ReleaseSoldierBT(actor)
        AVU.LaunchCharacterFrom(actor, tLoc, 250, 150, true)   -- tiny nudge to un-plant
        LogDebug("Warrior Witch - un-stalled", SETTINGS.DEBUG_NPC_ACTIONS)
    end
end


-- =======================================================================
-- STORM WITCH
-- =======================================================================

local SW_BOLT = {
    DelayMs = 350,    -- after Server_DoRangedAttack, so the bolt syncs with the fire montage
    Range   = 2000,   -- hitscan cap
    CdTicks = 20,     -- FAST_TICKs between bolts - the REAL cadence (see the header)
}

-- Gravity affects airtime
local SW_GRAVITY = 0.75    -- 0.5 base

-- How close she lets anyone get before the tree relocates her instead. See H.StormLoadout.
local SW_STANDOFF = 600   -- 150 native
local SW_SHIELD = { Normal = 550, Hard = 700 }   -- 150; most of her health

local SW_PULSE = {
    Radius  = 200,   -- nova reach (the tincture's native burst is 290)
    Dmg     = 50,
    StunS   = 1,
    CdTicks = 50,    -- min FAST_TICKs between novas (kick + takeoff share it)
    FxScale = 2.5,   -- the ring is authored for a pest; this reads as a 2m burst
}

-- Shock pulse grenade - throws these in midair near the target. Pulses stun radius in an area for x seconds
--
-- * Grenade uses 2 projectiles - as the actors don't replicate movement it
--   may land in different locations per client. The second projectile spawned is
--   its actual position
local SW_GRENADE = {
    -- Throw
    Fuzz        = 200,    -- landing spread around the target
    Range       = 2500,   -- won't throw at a really far enemy (25m)
    AfterMs     = 1000,   -- after Broadcast_CombatAbility3 (0.6s crouch + ~0.5s climb = the apex)
    MinRise     = 140,    -- must be this far above the takeoff Z, or a flat hop doesn't read as
                          --   "thrown down from the air"
    MaxAlive    = 3,
    CdTicks     = 70,     -- grenade cooldown
    CdTicksHard = 30,     -- 
    StartTicks  = 0,      -- grace cooldown before the first grenade (none)
    Row         = ENUMS.ProjectileRows.PlasmaBall,
    Speed       = 1500,   -- flat and fast: it arrives like a bullet, not a lob
    RestZ       = 10,     -- how far above the floor the shell settles, so it isn't half-buried
    -- The shell
    ShellSecs   = 12,
    Scale       = 1.5,    -- on top of the item row's own world scale
    Color       = FVector(0.2, 2.6, 3.2),
    Emissive    = 5,
    -- Shock pulses
    FirstMs     = 2000,   -- quiet arming beat before the first one
    EveryMs     = 2000,
    RingSecs    = 2,      -- client-FX lifetime; the burst itself is about a second
    RingScale   = 2,      -- overrides the registry entry's own, so it tunes through /reload
    Radius      = 275,    -- fx is about this big
    Dmg         = 50,
    StunS       = 1,
}

-- Everything the two shots resolve for themselves: the class, plus the mesh soft-ref the item row
-- hands to SetProjectileMesh (that one would otherwise blocking-load inside the spawn drain).
local SW_GRENADE_DEPS = { ENUMS.ProjectileClasses.ThrownWeapon, ENUMS.Components.SM_GRENADE_NULL }

-- A ring fires up to 12s after the throw, well past what a spawn-time preload guarantees.
local SW_RING_DEPS = { ENUMS.DamageType.Electric, ENUMS.BuffObjects.Stunned }

local SW_BODY_COLOR = FVector(0.25, 0.5, 1.6)   -- storm blue
local SW_HELM_COLOR = FVector(0.3, 0.4, 1.2)

-- Crystal crown, worn OVER the witch hat
local SW_CROWN_LOC   = FVector(0, -3, 5)
local SW_CROWN_ROT   = FRotator(90, 0, 90)
local SW_CROWN_SCALE = FVector(0.8, 0.8, 0.8)     -- shrunk so the witch hat still reads
local SW_CROWN_COLOR = FVector(0.15, 1.4, 1.6)    -- cyan pull over the native light purple

-- LIGHTNING_STUN (blue) - the pulse applies Debuff_Zapped; purple is ZappedPurple.
--   * The ring itself needs no entry: every ClientFX registry system is kept warm on renderers by
--     ClientEffects' own sweep, and the server never draws it.
local SW_PULSE_DEPS = { ENUMS.BuffObjects.Stunned, ENUMS.Effects.LIGHTNING_STUN,
                        ENUMS.DamageType.Electric }

H.STORM_ASSETS = { ENUMS.DamageType.Electric, ENUMS.BuffObjects.Stunned,
                   ENUMS.Effects.LIGHTNING_STUN,
                   ENUMS.Effects.TECHSPEAR_BEAM, ENUMS.Effects.TECHSPEAR_IMPACT,
                   ENUMS.ProjectileClasses.ThrownWeapon, ENUMS.Components.SM_GRENADE_NULL,
                   ENUMS.Components.SM_ELECTROTHROWER, ENUMS.Components.SM_ARMOR_HELMET_CRYSTAL }

local swBoltTick    = {}   -- key -> FAST_TICK of the last bolt (the manual cadence gate)
local swPulseTick   = {}   -- key -> FAST_TICK of the last nova
local swGrenadeTick = {}   -- key -> FAST_TICK of the last shock grenade (pre-seeded for the grace)
local swShells      = {}   -- key -> array of FAST_TICKs each live shell expires on


-- The lightning bolt: hand-rolled hitscan on the current combat target.
--   * Single VALIDATED target, never ApplyRadialDamage from a variant (CLAUDE.md S6); beam +
--     impact ride the client-FX channel.
--   * Electric carries no DebuffsCanApply, so no debuff preload is needed.
local function swFireBolt(actor)
    if not Utils.IsAuthority() then return end
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) or Utils.IsDeadSafe(target) then return end

    -- Muzzle -> centre mass. Gun socket when readable, else chest height.
    local from, tl
    pcall(function()
        local gun = actor.Gun
        if IsValid(gun) then local m = gun:GetSocketLocation(FName("Muzzle")); from = FVector(m.X, m.Y, m.Z) end
    end)
    pcall(function()
        local al = actor:K2_GetActorLocation()
        if not from then from = FVector(al.X, al.Y, al.Z + 55) end
        local t = target:K2_GetActorLocation()
        tl = FVector(t.X, t.Y, t.Z + 45)
    end)
    if not from or not tl then return end
    if Utils.DistSq(from, tl) > SW_BOLT.Range * SW_BOLT.Range then return end

    -- LoS from the muzzle (ignore both ends - the ray finishes inside the target's capsule). A
    -- blocked shot just fizzles; the BT's own repositioning fixes the angle.
    if AVU.IsPathBlocked(actor, from, tl, { actor, target }) then
        Utils.QueueWork(function() AVU.ReleaseSoldierBT(actor) end, 300)
        return
    end

    -- Never fire untyped (a non-DamageType class deals a silent ZERO).
    if IsNotValid(ASSETS.GetIfValid(ENUMS.DamageType.Electric)) then return end
    local dmg = 40
    pcall(function() dmg = actor.NPCData[ENUMS.NpcData.RangedDamage] or dmg end)
    -- §6 kill-path hop: the target can be a pet-war NPC, and an in-drain kill wedges
    -- (2026-07-27 Chonky family) - hence PointDamageOffHook.
    AVU.PointDamageOffHook(actor, target, dmg, ENUMS.DamageType.Electric)
    AVU.SendClientBeam(from, tl, "TECH_LIGHTNING", 1)
    AVU.SendClientFX(tl, "TECH_ZAP", 2)
    LogDebug("Storm Witch - bolt", SETTINGS.DEBUG_NPC_ACTIONS)

    -- Hold the native gate across our cadence window; opens a few ticks before the FAST_TICK gate.
    holdRangedCd(actor, SW_BOLT.CdTicks - 3)
    Utils.QueueWork(function() AVU.ReleaseSoldierBT(actor) end, 600)
end


-- The shock nova on her own body. `noStun` drops the debuff and keeps the damage.
--   * Same ring the grenade fires, so one visual reads as one mechanic wherever it comes from.
--   * Deps preloaded first, and BlastDamage does the damage - other radial paths can freeze
--     on non-players (CLAUDE.md S6).
local function swPulse(actor, noStun)
    if not Utils.IsAuthority() then return end
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return end

    local key = Utils.ActorKey(actor)
    if not key then return end
    if not AVU.CooldownReady(swPulseTick, key, SW_PULSE.CdTicks) then return end

    ASSETS.LoadAsync(SW_PULSE_DEPS, function()
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        local al
        pcall(function() local l = actor:K2_GetActorLocation(); al = FVector(l.X, l.Y, l.Z) end)
        if not al then return end

        AVU.SendClientFX(al, "SHOCK_RING", 2, 0, nil, SW_PULSE.FxScale)
        AVU.BlastDamage(actor, al, {
            Radius = SW_PULSE.Radius, Damage = SW_PULSE.Dmg,
            DamageType = ENUMS.DamageType.Electric, RequireLoS = true,
            Debuff = (not noStun) and ENUMS.Debuffs.Zapped or nil,
            DebuffSeconds = SW_PULSE.StunS,
        })
        LogDebug("Storm Witch - nova", SETTINGS.DEBUG_NPC_ACTIONS)
    end)
end


-- One ring: the burst on every renderer, then a players-only blast in the same spot. The blast is
-- AVU.BlastDamage rather than any radial primitive for the usual reason (CLAUDE.md S6) - a variant
-- that fans engine damage across a crowd of NPCs re-enters our own hooks on a freed body.
local function swPulseRing(spot, owner)
    if Utils.IsActorInvalid(owner) or owner.IsDead then return end
    AVU.SendClientFX(spot, "SHOCK_RING", SW_GRENADE.RingSecs, 0, nil, SW_GRENADE.RingScale)
    AVU.BlastDamage(owner, spot, {
        Radius = SW_GRENADE.Radius, Damage = SW_GRENADE.Dmg,
        DamageType = ENUMS.DamageType.Electric, RequireLoS = true,
        Debuff = ENUMS.Debuffs.Zapped, DebuffSeconds = SW_GRENADE.StunS,
    })
end


-- Ring cadence, bounded by the shell's own lifetime. `elapsedMs` is NOMINAL, not measured, so a
-- starved drain shifts the rings later without ever adding one after the shell is gone.
-- Stops with the witch, like the Plague cloud - the blast needs a live instigator to be credited to.
local function swRingLoop(spot, owner, elapsedMs)
    if Utils.IsActorInvalid(owner) or owner.IsDead then return end
    swPulseRing(spot, owner)
    local nextMs = elapsedMs + SW_GRENADE.EveryMs
    if nextMs < SW_GRENADE.ShellSecs * 1000 then
        Utils.QueueWork(function() swRingLoop(spot, owner, nextMs) end, SW_GRENADE.EveryMs)
    end
end


-- The shell that lands: a still, collision-free grenade sitting at `spot` until it burns out.
--   * Collision off makes it truly inert - no bounce, no detonation, nothing to pick up. Server
--     side is the only side that decides an impact (both funnels are IsServer gated), so one
--     write covers every machine.
--   * The 1.5x scale and the cyan are renderer-local (neither actor scale nor a material param
--     replicates); the SHELL ITSELF is the item row's mesh, which does.
local function swPlantGrenade(spot, owner)
    ASSETS.WarmPinned(SW_RING_DEPS)

    PROJ.Queue(FVector(spot.X, spot.Y, spot.Z), FVector(0, 0, 1),
        ENUMS.ProjectileClasses.ThrownWeapon, nil, {
            Owner = owner, Instigator = owner,
            Item = { Table = G.BASE, Row = G.NULL_GRENADE },
            -- Not 0: a zero override reads as "unset" and falls through to the row's own launch.
            VelocityOverride = true, Velocity = 1,
            Damage = 0,
            LifeSpan = SW_GRENADE.ShellSecs,
            Scale = FVector(SW_GRENADE.Scale, SW_GRENADE.Scale, SW_GRENADE.Scale),
            NoTravelAudio = true,
            Preload = SW_GRENADE_DEPS,
            PreFinish = function(proj)
                pcall(function() proj.ProjectileDataRowHandle.RowName = FName(SW_GRENADE.Row) end)
            end,
            PostFinish = function(proj)
                pcall(function() proj.ProjectileCollision:SetCollisionEnabled(0) end)
            end,
            OnSpawned = function(proj)
                local function tint()
                    if Utils.IsActorInvalid(proj) then return end
                    pcall(function()
                        AVU.TintComponent(proj.SM_Appearance, {
                            DiffuseColor = SW_GRENADE.Color, Emissive = SW_GRENADE.Emissive,
                            EmissiveColor = SW_GRENADE.Color, EmissiveMultiply = 3,
                        })
                    end)
                end
                tint()
                Utils.QueueWork(tint, 200)   -- again once SetAlternateProjectileMesh has run
            end,
        })

    Utils.QueueWork(function() swRingLoop(spot, owner, SW_GRENADE.FirstMs) end, SW_GRENADE.FirstMs)
    LogDebug("Storm Witch - shock grenade planted", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- The throw: one flat, fast shot at `spot`, and the shell it becomes on arrival.
--   * Both halves pay PROJ's ~100ms serialize slot, so scheduling the plant at the raw flight time
--     lands it exactly as the flier arrives.
local function swThrowGrenade(actor, spot)
    local from
    pcall(function()
        local gun = actor.Gun
        if IsValid(gun) then local m = gun:GetSocketLocation(FName("Muzzle")); from = FVector(m.X, m.Y, m.Z) end
    end)
    pcall(function()
        if not from then local al = actor:K2_GetActorLocation(); from = FVector(al.X, al.Y, al.Z) end
    end)
    if not from then return end

    local dir = FVector(spot.X - from.X, spot.Y - from.Y, spot.Z - from.Z)
    local flightMs = math.floor(math.sqrt(Utils.DistSq(from, spot)) / SW_GRENADE.Speed * 1000 + 0.5)

    PROJ.Queue(from, dir, ENUMS.ProjectileClasses.ThrownWeapon, nil, {
        Owner = actor, Instigator = actor,
        Item = { Table = G.BASE, Row = G.NULL_GRENADE },
        VelocityOverride = true, Velocity = SW_GRENADE.Speed,
        MaxSpeed = SW_GRENADE.Speed,   -- server-side backstop if the row repoint above didn't take
        Damage = 0,
        -- The landing spot is decided in Lua, not by the impact, so the flier is on a timer: it is
        -- gone a beat after the shell arrives, whether or not anything stopped it on the way.
        LifeSpan = flightMs / 1000 + 0.4,
        Scale = FVector(SW_GRENADE.Scale, SW_GRENADE.Scale, SW_GRENADE.Scale),
        NoTravelAudio = true,
        Preload = SW_GRENADE_DEPS,
        PreFinish = function(proj)
            pcall(function() proj.ProjectileDataRowHandle.RowName = FName(SW_GRENADE.Row) end)
        end,
    })

    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) then return end
        swPlantGrenade(spot, actor)
    end, flightMs)
    LogDebug("Storm Witch - shock grenade away", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- Live shells, counted from their EXPIRY TICKS rather than a roster of projectile wrappers - the
-- shell's life is a fixed LifeSpan we set ourselves, so arithmetic knows exactly when it is gone
-- and nothing has to hold an actor across twelve seconds.
local function swAliveShells(key)
    local list = swShells[key]
    if not list then return 0 end
    local now, kept = STATE.FAST_TICK, {}
    for i = 1, #list do
        if list[i] > now then kept[#kept + 1] = list[i] end
    end
    swShells[key] = kept
    return #kept
end


-- All the throw gates, checked at FIRE time: still airborne, risen far enough above the captured
-- takeoff Z, cooldown (seeded short on the first attempt), roster cap, and a live target in range.
--   * opts.Grounded drops the two AIR gates - for a thrower that isn't paying for the shot with a
--     hover (the Mother's Storm aspect). opts.CdTicks overrides the sister's own cadence.
local function swTryGrenade(actor, key, takeoffZ, opts)
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return end
    if not Utils.IsAuthority() then return end
    opts = opts or {}

    if not opts.Grounded then
        local airborne = false
        pcall(function() airborne = actor.JetpackActive == true end)
        if not airborne then return end
    end

    local al
    pcall(function() local l = actor:K2_GetActorLocation(); al = FVector(l.X, l.Y, l.Z) end)
    if not al then return end
    if not opts.Grounded and takeoffZ and (al.Z - takeoffZ) < SW_GRENADE.MinRise then return end

    -- Seed the start grace on the first attempt, then PEEK - the stamp is only spent once every
    -- gate below has passed too.
    local cd = opts.CdTicks
        or (STATE.HardModeNoMercy and SW_GRENADE.CdTicksHard or SW_GRENADE.CdTicks)
    local now = STATE.FAST_TICK
    if not swGrenadeTick[key] then swGrenadeTick[key] = now - (cd - SW_GRENADE.StartTicks) end
    if not AVU.CooldownReady(swGrenadeTick, key, cd, { Peek = true }) then return end
    if swAliveShells(key) >= SW_GRENADE.MaxAlive then return end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) or Utils.IsDeadSafe(target) then return end
    local tl
    pcall(function() tl = target:K2_GetActorLocation() end)
    if not tl then return end
    if Utils.DistSq(al, tl) > SW_GRENADE.Range * SW_GRENADE.Range then return end

    swGrenadeTick[key] = now
    local list = swShells[key] or {}
    list[#list + 1] = now + SW_GRENADE.ShellSecs * 10   -- FAST_TICKs, ~10/s
    swShells[key] = list

    -- Aim at the floor near their feet: navmesh Z under the fuzzed point, else a body height below
    -- the capsule centre. Plain table - it outlives this tick by 12 seconds (CLAUDE.md S3).
    local fuzz = Utils.FuzzLocation(tl, SW_GRENADE.Fuzz)
    local floorZ = Utils.GroundZ(fuzz) or (tl.Z - 80)
    swThrowGrenade(actor, { X = fuzz.X, Y = fuzz.Y, Z = floorZ + SW_GRENADE.RestZ })
end


-- [RENDERER] Storm-blue paint, crystal crown, Electrothrower in hand,
-- plus the tincture's looping body lightning.
--   * Gun hidden, its SM attached at the same socket - the Chieftain squid pattern.
function H.StormLook(actor)
    pcall(function()
        local mesh = Utils.GetValidMesh(actor)
        if mesh then mesh:SetVectorParameterValueOnMaterials(FName("Color"), SW_BODY_COLOR) end
    end)
    pcall(function() AVU.TintComponent(actor.Helmet, { Color = SW_HELM_COLOR }) end)

    -- actor.Helmet is deliberately left visible - both should read.
    AVU.AttachStaticMesh(actor, ENUMS.Components.SM_ARMOR_HELMET_CRYSTAL, "head", {
        Location = SW_CROWN_LOC, Rotation = SW_CROWN_ROT, Scale = SW_CROWN_SCALE,
        Color = SW_CROWN_COLOR,
    })

    -- Electrothrower
    pcall(function()
        local gun = actor.Gun
        if IsNotValid(gun) then return end
        gun:SetVisibility(false, false)
        local sock = gun:GetAttachSocketName()
        AVU.AttachStaticMesh(actor, ENUMS.Components.SM_ELECTROTHROWER,
            sock and sock:ToString() or "None", {
                Location = FVector(0, 0, 7), Rotation = FVector(0, 0, 0), Scale = FVector(1, 1, 1),
            })
    end)

    -- The bolt's bang.
    --   * WeaponFireSound is per-instance and does NOT replicate, so it lives in Visuals.
    --   * The suppressed burst still multicasts Broadcast_DoRangedAttackFX, which plays it.
    pcall(function()
        local cue = ASSETS.GetIfValid(ENUMS.SOUNDS.ELECTROTHROWER_FIRE)
        if IsValid(cue) then actor.WeaponFireSound = cue end
    end)
    if not SETTINGS.GAMEPLAY.REDUCE_VISUALS then
        AVU.AttachNiagara(actor, ENUMS.Effects.TINCTURE_ELECTRIC_PASSIVE, "Spine2", {})
    end
end


-- The suppressed shotgun's replacement shot.
--   * Manual cadence gate first - see the file header (OverrideSoldierFireLogic kills the native one).
function H.StormRangedAttack(actor)
    if Utils.IsActorInvalid(actor) or not Utils.IsAuthority() then return end
    local key = Utils.ActorKey(actor)
    if not key then return end
    if not AVU.CooldownReady(swBoltTick, key, SW_BOLT.CdTicks) then return end
    Utils.QueueWork(function() swFireBolt(actor) end, SW_BOLT.DelayMs)
end


-- [AUTHORITY, cadenced from OnTick] Throw from wherever she stands, on the CALLER's clock.
-- For a thrower whose hovers are too rare to carry the ability: the Mother changes aspect on every
-- landing, so a Storm takeoff is the moment she stops being Storm.
--   * Shares swGrenadeTick and the live-shell cap with the apex throw, so the two can't double up.
function H.StormGroundGrenade(actor, cdTicks)
    if Utils.IsActorInvalid(actor) or not Utils.IsAuthority() then return end
    local key = Utils.ActorKey(actor)
    if not key then return end
    swTryGrenade(actor, key, nil, { Grounded = true, CdTicks = cdTicks })
end


-- The nova fires on a CONNECTING kick, STUNLESS: the native kick already launches you across the
-- room, and rooting you where you land is a second disable off the same contact.
function H.StormImpact(actor)
    if Utils.IsActorInvalid(actor) then return end
    Utils.QueueWork(function() swPulse(actor, true) end, 0)
end


-- ...and on deliberate jetpack takeoffs: the nova timed to the lift (~0.6s after the crouch),
-- then the shock grenade thrown down from the top of the arc.
function H.StormJetpack(actor)
    if Utils.IsActorInvalid(actor) then return end
    Utils.QueueWork(function() swPulse(actor) end, 600)

    if not Utils.IsAuthority() then return end
    local key = Utils.ActorKey(actor)
    if not key then return end
    local takeoffZ
    pcall(function() takeoffZ = actor:K2_GetActorLocation().Z end)
    Utils.QueueWork(function() swTryGrenade(actor, key, takeoffZ) end, SW_GRENADE.AfterMs)
end


-- [AUTHORITY] Her Stats(), split out so the blackboard write below has somewhere to live.
--   * SW_STANDOFF is the whole reason she stops walking people down. The tree reads
--     RangeToMeleeAttack as BOTH the chase MoveTo's acceptance radius and the "swing now" gate, so
--     one number decides how close she gets AND what she does on arrival - and with MeleeCounter
--     held (H.StormStandoff) arrival always means "jetpack somewhere else".
--   * BasicStats.MeleeAttackRange is deliberately NOT raised with it: that one moves the damage
--     SWEEP, and a kick that reaches 6m looks absurd on the rare swing that slips through.
function H.StormLoadout(actor)
    pcall(function() actor.OverrideSoldierFireLogic = true end)
    pcall(function() actor.LeaveFireWithJetpack = false end)   -- the nova replaces the fire trail
    -- Write BOTH gravity fields: the game seeds GravityScale from DefaultGravityScale.
    pcall(function() actor.DefaultGravityScale = SW_GRAVITY end)
    pcall(function() actor.CharacterMovement.GravityScale = SW_GRAVITY end)

    -- Written here for the earliest possible effect; the tick poll is what makes it stick, since
    -- STATS can land before the controller has a blackboard at all.
    AVU.SetBlackboardFloat(actor, "RangeToMeleeAttack", SW_STANDOFF)

    -- Ahead of the stance: its CombatActivateBodyShield refills Current from this Max.
    AVU.SetBodyShield(actor, { Max = STATE.HardModeNoMercy and SW_SHIELD.Hard or SW_SHIELD.Normal })
    H.HardShieldStance(actor)
end


-- [AUTHORITY, cadenced from OnTick] The inverse of H.WarriorAggression: hold MeleeCounter AT the
-- gate so the attack tree's melee branch always takes its OTHER arm, a jetpack relocate
-- (BT_FindJetpackCombatLocation, which fires CombatAbility3 - so every one of these is another
-- OnJetpack, another nova and another grenade window).
--   * Both relocate subtrees reset the counter at their top, so this has to be re-asserted rather
--     than written once; the leak is a kick every so often, which is fine.
--   * The standoff radius rides along - a re-possess would otherwise drop it back to vanilla.
function H.StormStandoff(actor)
    if not Utils.IsAuthority() then return end
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return end
    AVU.SetBlackboardInt(actor, "MeleeCounter", 1)
    AVU.SetBlackboardFloat(actor, "RangeToMeleeAttack", SW_STANDOFF)
end


function H.StormCleanup(actor)
    local key = Utils.ActorKey(actor)
    if not key then return end
    swBoltTick[key] = nil; swPulseTick[key] = nil
    swGrenadeTick[key] = nil; swShells[key] = nil
end


-- =======================================================================
-- PLAGUE WITCH
-- =======================================================================

local PW_THROW_RANGE     = 2000   -- Summon throw range
local PW_THROW_CD_TCK    = 130    -- Cooldown between throwing summon
local PW_THROW_START_TCK = 50     -- Initial cooldown
local PW_MAX_ALIVE       = 3      -- Max summons
local PW_THROW_AFTER_MS  = 1100   -- after it jumps how long to wait to summon (Broadcast_CombatAbility3 (0.6s crouch + 0.5s climb)
local PW_THROW_MIN_RISE  = 140    -- must be this far above the takeoff spot to summon

local PW_CLOUD_CD_TCK    = 40   -- cooldown between bee clouds
local PW_CLOUD_START_TCK = 10    -- initial cooldown
local PW_CLOUD_SECONDS   = 13    -- cloud lifetime 
local PW_CLOUD_FUZZ      = 150   -- cloud created near target

-- The toss (Neophyte Trainer numbers, scaled to a midair thrower)
local PW_TOSS = {
    Up          = 350,    -- upward launch component (Neophyte uses 500 from the ground)
    Min         = 600,    -- horizontal launch speed clamp (scales with distance)
    Max         = 1800,
    PauseMs     = 3500,   -- inert after the toss, so a mini dropped on a player is readable
    PauseHardMs = 2500,
    HoldAgainMs = 400,    -- re-park once the mutation has landed
}

local PW_QUILL_CD_TCK   = 10    -- cooldown between quills (~1s; the homing does the rest)
local PW_QUILL_DELAY_MS = 300   -- after Server_DoRangedAttack (sync with the fire montage)
local PW_QUILL_ROW      = ENUMS.ProjectileRows.QuillRifle   -- hard-homing GREEN quill (2000 cap)

-- Quill damage by how many debuffs the target has
-- * Mini Pestilence will apply 6
local PW_QUILL_DMG = {
    Normal = { 20, 40, 60, 80, 100 },
    Hard   = { 30, 60, 90, 120, 150 },
}

local function pwQuillDamage(target)
    local t = STATE.HardModeNoMercy and PW_QUILL_DMG.Hard or PW_QUILL_DMG.Normal
    local n = Utils.CountDebuffs(target)
    if n >= 7 then return t[5], n
    elseif n >= 5 then return t[4], n
    elseif n >= 3 then return t[3], n
    elseif n >= 1 then return t[2], n
    else return t[1], n end
end

-- Bee-cloud client FX (ClientFX playback skips a cold miss), the quill class (first-shot
-- latency insurance) and the attach meshes.
--   * Also the tick keep-warm list - a def.Assets preload doesn't pin.
--   * Each exorspike row ships its OWN class, so the class here must track PW_QUILL_ROW.
H.PLAGUE_ASSETS = { ENUMS.Effects.BEE_SWARM, ENUMS.Effects.SPORES_PECCARY_SHAKE,
                    ENUMS.ProjectileClasses.QuillRifle, ENUMS.Components.SM_QUILLRIFLE,
                    ENUMS.SOUNDS.EXOR_FIRE,
                    ENUMS.Components.SM_ARMOR_CHEST_HEX, ENUMS.Components.SM_PECCARY_HELM_MUSH }

local pwThrowTick = {}   -- key -> FAST_TICK of the last mini toss (pre-seeded for the start grace)
local pwCloudTick = {}   -- key -> FAST_TICK of the last cloud (nil until first aggro seeds the grace)
local pwQuillTick = {}   -- key -> FAST_TICK of the last quill (the manual cadence gate)
local pwMinis     = {}   -- key -> array of live mini wrappers (pruned each poll)


-- Prune the roster (dead/gibbed/unloaded minis fall out) and return the live count.
local function pwAliveMinis(key)
    local list = pwMinis[key]
    if not list then return 0 end
    local kept = {}
    for i = 1, #list do
        local m = list[i]
        if Utils.IsActorValid(m) and not Utils.IsDeadSafe(m) then kept[#kept + 1] = m end
    end
    pwMinis[key] = kept
    return #kept
end


-- Park a tossed mini's tree so it arrives inert. Written twice - the second lands after the
-- mutation, the same insurance the faction copy runs on.
local function pwHoldMini(mini)
    AVU.SetBtStunned(mini, true)
    Utils.QueueWork(function()
        if Utils.IsActorValid(mini) then AVU.SetBtStunned(mini, true) end
    end, PW_TOSS.HoldAgainMs)
end


-- TOSS a Mini Pestilence at the target (the Neophyte throw, from midair).
-- Spawned through the spawner (SkipSpawnFX + downrange Rotation), flung with a distance-scaled
-- launch, faction copied from the witch, LockAggro'd onto her target - full whys: AnNotes/AnteNPCs/GKWitch.md.
local function pwThrowMini(actor, key, target, targetLoc)
    local fac, origin, yaw
    pcall(function() fac = actor.Faction end)
    pcall(function()
        local al = actor:K2_GetActorLocation()
        origin = FVector(al.X, al.Y, al.Z)
        local rot = Utils.RotatorToTarget(al, targetLoc)
        yaw = FRotator(0, rot.Yaw, 0)
    end)
    if not origin then return end
    local landing = FVector(targetLoc.X, targetLoc.Y, targetLoc.Z + 30)

    AVU.SummonVariant("Mini Pestilence", origin,
        { SpawnDelay = 250, SkipSpawnFX = true, Rotation = yaw }, function(mini)
        if Utils.IsActorInvalid(mini) then return end
        local list = pwMinis[key] or {}
        list[#list + 1] = mini
        pwMinis[key] = list

        if fac ~= nil then
            AVU.SetFaction(mini, fac)
            Utils.QueueWork(function()
                if Utils.IsActorValid(mini) then AVU.SetFaction(mini, fac) end
            end, 1500)
        end
        AVU.WatchSummonLifetime(mini, actor, { ReleaseOnParentDeath = true, Label = "Mini Pestilence" })

        -- THE TOSS: horizontal speed scales with distance (clamped) so it flies roughly AT the
        -- target rather than a fixed-length lob.
        local ml = mini:K2_GetActorLocation()
        if ml then
            AVU.LaunchCharacterFrom(mini, landing,
                AVM.TossSpeed(ml, landing, PW_TOSS.Min, PW_TOSS.Max), PW_TOSS.Up, true)
        end
        -- LANDING GRACE: the mini arcs in inert, so a body dropped on top of a player is
        -- readable before it lunges. The Stunned bool parks only the TREE, so the launch, the
        -- arc and the landing all still play out - a movement-side hold would eat them.
        local pause = (STATE.HardModeNoMercy and PW_TOSS.PauseHardMs) or PW_TOSS.PauseMs
        pwHoldMini(mini)
        Utils.QueueWork(function()
            if Utils.IsActorInvalid(mini) then return end
            -- A real stun that landed on top owns the shared bool; leave it to clear itself.
            if not AVU.HasGameplayTag(mini, "Modifier.Stunned") then AVU.SetBtStunned(mini, false) end
            -- LockAggro > a one-shot ForceAggro: it re-asserts across the hold window (the
            -- Symphonist pattern). It rides the release, so the hold covers the charge that
            -- follows rather than being spent on the pause.
            if Utils.IsActorValid(target) then AVU.LockAggro(mini, target, { HoldMs = 5000 }) end
        end, pause)
    end)
    LogDebug("Plague Witch - mini pestilence tossed", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- All the throw gates live here, checked at FIRE time:
--   * still airborne, risen far enough above the captured takeoff Z,
--   * cooldown (seeded short on the first attempt), roster cap, and a live target in range.
local function pwTryThrow(actor, key, takeoffZ, opts)
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return end
    if not Utils.IsAuthority() then return end
    opts = opts or {}

    if not opts.Grounded then
        local airborne = false
        pcall(function() airborne = actor.JetpackActive == true end)
        if not airborne then return end
    end

    local al
    pcall(function() local l = actor:K2_GetActorLocation(); al = FVector(l.X, l.Y, l.Z) end)
    if not al then return end
    if not opts.Grounded and takeoffZ and (al.Z - takeoffZ) < PW_THROW_MIN_RISE then return end

    -- Seed the start grace on the first attempt, then PEEK - the stamp is only spent once every
    -- gate below has passed too.
    local cd = opts.CdTicks or PW_THROW_CD_TCK
    local now = STATE.FAST_TICK
    if not pwThrowTick[key] then
        pwThrowTick[key] = now - (cd - PW_THROW_START_TCK)
    end
    if not AVU.CooldownReady(pwThrowTick, key, cd, { Peek = true }) then return end
    if pwAliveMinis(key) >= PW_MAX_ALIVE then return end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) or Utils.IsDeadSafe(target) then return end
    local tl
    pcall(function() tl = target:K2_GetActorLocation() end)
    if not tl then return end
    if Utils.DistSq(al, tl) > PW_THROW_RANGE * PW_THROW_RANGE then return end

    pwThrowTick[key] = now
    pwThrowMini(actor, key, target, tl)
end


-- One homing quill via the native gun (AVU.FireProjectileRow), at the target's debuff tier.
--   * Holds RangedAttack_OnCooldown across the window, then releases the BT ranged task - see the
--     file header (a one-shot write self-clears too soon).
local function pwFireQuill(actor, cdTicks)
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) or Utils.IsDeadSafe(target) then return end
    local aim
    pcall(function()
        local t = target:K2_GetActorLocation()
        aim = FVector(t.X, t.Y, t.Z + 45)
    end)
    if not aim then return end

    local dmg, debuffs = pwQuillDamage(target)
    AVU.FireProjectileRow(actor, PW_QUILL_ROW, dmg, aim)
    LogDebug("Plague Witch - quill (" .. debuffs .. " debuffs -> " .. dmg .. ")",
             SETTINGS.DEBUG_NPC_ACTIONS)

    holdRangedCd(actor, (cdTicks or PW_QUILL_CD_TCK) - 3)
    Utils.QueueWork(function() AVU.ReleaseSoldierBT(actor) end, 600)
end


-- [AUTHORITY] Her Stats(), alongside the Warrior's and the Storm's.
function H.PlagueLoadout(actor)
    -- Quill rifle: suppress the pellet burst (OnRangedAttack fires the quill instead)
    pcall(function() actor.OverrideSoldierFireLogic = true end)
    pcall(function() actor.ProjectileFireSocket = FName("r_weapon_ranged1") end)
    pcall(function() actor.LeaveFireWithJetpack = false end)   -- the bee cloud replaces it

    H.HardShieldStance(actor)
end


-- [RENDERER] Plague paint + the fungal kit
function H.PlagueLook(actor)
    pcall(function()
        local mesh = Utils.GetValidMesh(actor)
        if mesh then mesh:SetVectorParameterValueOnMaterials(FName("Color"), FVector(0.9, 1.1, 0.25)) end
    end)

    pcall(function() AVU.TintComponent(actor.Helmet, { Color = FVector(0.7, 0.8, 0.2) }) end)
    AVU.AttachStaticMesh(actor, ENUMS.Components.SM_PECCARY_HELM_MUSH, "head", {
        Location = FVector(0, 10, 0), Rotation = FRotator(75, 90, 0), Scale = FVector(1.1, 1.1, 1.1),
        Color = FVector(2.8, 1.0, 0.2),
    })
    AVU.AttachStaticMesh(actor, ENUMS.Components.SM_ARMOR_CHEST_HEX, "spine2", {
        Location = FVector(0, 15, 0), Rotation = FRotator(90, 90, 0), Scale = FVector(1.35, 1.35, 1.35),
        EmissiveColor = FVector(2.6, 0.85, 0.15),
    })

    pcall(function()
        local gun = actor.Gun
        if IsNotValid(gun) then return end
        gun:SetVisibility(false, false)
        local sock = gun:GetAttachSocketName()
        AVU.AttachStaticMesh(actor, ENUMS.Components.SM_QUILLRIFLE,
            sock and sock:ToString() or "None", {
                Location = FVector(0, 0, 0), Rotation = FRotator(0, 0, 0), Scale = FVector(1.15, 1.15, 1.15),
                -- Item meshes ride M_AbioticItems_Master, which has no "Color" - DiffuseColor is its tint.
                DiffuseColor = FVector(0.2, 0.4, 0),
            })
    end)
    -- The quill's bark: the Quill Rifle item's own FireSound. Per-instance, doesn't replicate.
    pcall(function()
        local cue = ASSETS.GetIfValid(ENUMS.SOUNDS.EXOR_FIRE)
        if IsValid(cue) then actor.WeaponFireSound = cue end
    end)
end


-- The suppressed shotgun's replacement quill (manual cadence - see the Storm bolt).
--   * cdTicks lets a caller fire slower than the sister does; it also sets the BT hold, so the
--     tree stops offering shots the gate would only reject.
function H.PlagueRangedAttack(actor, cdTicks)
    if Utils.IsActorInvalid(actor) or not Utils.IsAuthority() then return end
    local key = Utils.ActorKey(actor)
    if not key then return end
    local cd = cdTicks or PW_QUILL_CD_TCK
    if not AVU.CooldownReady(pwQuillTick, key, cd) then return end
    Utils.QueueWork(function() pwFireQuill(actor, cd) end, PW_QUILL_DELAY_MS)
end


-- Deliberate takeoff -> the mini toss, scheduled at the ARC APEX.
--   * Airborne + minimum-RISE are checked at FIRE time so a flat hop doesn't throw
--     (the old 2/s poll caught her near the ground - AnNotes/AnteNPCs/GKWitch.md).
function H.PlagueJetpack(actor)
    if Utils.IsActorInvalid(actor) or not Utils.IsAuthority() then return end
    local key = Utils.ActorKey(actor)
    if not key then return end
    local takeoffZ
    pcall(function() takeoffZ = actor:K2_GetActorLocation().Z end)
    Utils.QueueWork(function() pwTryThrow(actor, key, takeoffZ) end, PW_THROW_AFTER_MS)
end


-- [AUTHORITY, cadenced from OnTick] The mini toss from the ground, on the CALLER's clock - the
-- Storm grenade's situation exactly (see H.StormGroundGrenade). Shares the roster cap.
function H.PlagueGroundThrow(actor, cdTicks)
    if Utils.IsActorInvalid(actor) or not Utils.IsAuthority() then return end
    local key = Utils.ActorKey(actor)
    if not key then return end
    pwTryThrow(actor, key, nil, { Grounded = true, CdTicks = cdTicks })
end


function H.PlagueCleanup(actor)
    local key = Utils.ActorKey(actor)
    if not key then return end
    pwThrowTick[key] = nil; pwCloudTick[key] = nil
    pwQuillTick[key] = nil; pwMinis[key] = nil
end


-- The periodic bee cloud: every PW_CLOUD_CD_TCK while in combat.
--   * The first one PW_CLOUD_START_TCK after the first in-combat poll (the toss's start-grace pattern).
--   * Dropped at a fuzzed point near the target, so the spot is unpredictable.
function H.PlagueCloudPoll(actor, cdTicks)
    if not Utils.IsAuthority() then return end
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return end
    local key = Utils.ActorKey(actor)
    if not key then return end

    local inCombat = false
    pcall(function() inCombat = actor.CombatState == true end)
    if not inCombat then return end

    -- Seed the start grace on the first in-combat poll, then PEEK (the toss's pattern above).
    local cd = cdTicks or PW_CLOUD_CD_TCK
    local now = STATE.FAST_TICK
    if not pwCloudTick[key] then
        pwCloudTick[key] = now - (cd - PW_CLOUD_START_TCK)
    end
    if not AVU.CooldownReady(pwCloudTick, key, cd, { Peek = true }) then return end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) or Utils.IsDeadSafe(target) then return end
    local tl
    pcall(function() tl = target:K2_GetActorLocation() end)
    if not tl then return end

    pwCloudTick[key] = now
    local fuzz = Utils.FuzzLocation(tl, PW_CLOUD_FUZZ)
    local spot = { X = fuzz.X, Y = fuzz.Y, Z = fuzz.Z }   -- plain table across the tick (S3)
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        HIVE.DropCloud(spot, actor, { Seconds = PW_CLOUD_SECONDS })
        LogDebug("Plague Witch - bee cloud", SETTINGS.DEBUG_NPC_ACTIONS)
    end, 0)
end

return H
