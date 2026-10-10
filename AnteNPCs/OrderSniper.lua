-- =======================================================================
-- Sniper variants (base "Grunt_Sniper" = NPC_Soldier_Grunt_Sniper)
--
-- MUST-KNOWS
--   * Base: 200 damage/shot, own Bullet_Sniper type (severe bleed, no DBNO), fast laser lock
--     (faster in Apocalyptic).
--   * AIM IS A LADDER, NOT AN ACQUISITION. The cone is `(Accuracy_RequiredFailedHits - misses)`
--     degrees plus a small steady/sprint term, and the miss count resets on every LANDED hit -
--     so it re-walks its rounds in after each one. Cover counts as a miss, which tightens it.
--     H.SetAccuracy is the one place to set it; H.LockOnFast is "skip the ladder entirely".
--     Natively nothing re-opens it for LOSING you: H.SightResetTick is ours, and every sniper
--     with a ladder worth breaking (Twilight, Tracker, Tracer) runs it.
--   * [RENDERER] actor.Laser is a plain Niagara sight, not a ULaserComponent - no trace, no
--     damage, no replication. Recolor via Lasers.RecolorSight; ClientVisuals re-runs it per renderer.
--   * Almost no cosmetic surface: never wears a helmet. The rifle takes a DiffuseColor wash
--     (H.TintRifle), a mesh swap, or SetGlass - never a plain Color. See the helpers file.
--
-- ABILITY MAP
--   0 Idle - none
--   1 GRENADE - inherited and intact, but CanThrowGrenades=false blocks the BT from firing it.
--       Broadcast_CombatAbility1() from Lua still works.
--   2/3 - EMPTY
--   GOTCHA: CanThrowGrenades feeds AdditionalAbilityCheck, which ignores slot index - it blocks
--   EVERY BT-driven slot on a sniper, not just the grenade. Drive slot 2/3 ideas from OnTick instead.
--   Laser, lock-on, Accuracy_* are part of the ranged path, not ability slots.
--
-- Machinery: AnteNPCs/OrderSniperHelpers.lua
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local G = require("AnteData.Items").Global
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local Lasers = require("AnteUtils.Lasers")
local H = require("AnteNPCs.OrderSniperHelpers")
local GRP = require("AnteNPCs.OrderGroupeHelpers")   -- the shared wash/fade kit

local LogDebug = Utils.LogDebug

local BULLET_GENERIC = ENUMS.DamageType.BulletGeneric

-- Client-side jump distance that reads as the teleport (both vanish snipers' warp mirrors).
local WARP_MIRROR_JUMP = 1200

-- Sight range for the VANISH snipers (Groupe + Praetorium), absolute sets applied in Stats.
--   * Class default 20000uu/200m is a per-frame trace budget, not a fight range - halving it is a
--     free perf win indoors.
--   * LoseSightRadius must stay above Radius or a target drops the instant it's acquired.
--     SetSightConfig only grows it automatically, so a cut needs LoseRadius set explicitly (1.5x here).
--   * Cone stays at the native 120 degrees for these two. Only the Library Sniper changes it
--     (see LIB_SIGHT_*).
local VANISH_SIGHT_RADIUS = 10000   -- 100m
local VANISH_SIGHT_LOSE   = 15000

local V = {}


-- =======================================================================
-- TWILIGHT SNIPER 
-- Rapid fire sniper that deals stamina damage and raises fatigue. 
--   * Its bullets deal more damage to tired scientists.
--   * It takes about 3 shots to zero in on a target, and sprinting is mildly effective
--   * The shot inaccuracy resets each time it loses sight of its target - OURS, not native
--     (H.TwilightTick). Nothing in the base clears the ladder between a landed hit and a
--     combat flip, so breaking cover is otherwise no answer to a sniper already zeroed in.
-- =======================================================================

local TWILIGHT = {
    Cooldown = 0.75,   -- 1.25 base, then difficulty-scaled up
    HardCooldown = 0.6,
    Misses = 3,        -- opening cone in degrees, and shots to converge
    Steady = 0.15,     -- stand still and it will not miss twice
    Sprint = { 3, 6 },  -- 0.5-1.0 base: running is the counterplay, so make it worth something
    SightRadius = 8000,
    SightLose = 12000,
    RecheckTicks = 5,  -- fatigue-tier re-pick AND the sight check; under the refire (100ms/tick,
                       -- so 0.5s vs a 0.75s cooldown) so no shot lands on a stale tier or ladder

    -- Per landed hit. ModifyStat_Stamina clamps at 0 and applies no threshold debuff, so there is
    -- no stat-floor cold-load to preload against (unlike Hunger/Thirst).
    Fatigue = { Normal = 10, Hard = 20 },
    Stamina = { Normal = 12, Hard = 25 },

    -- Health damage by the target's fatigue tier (rested / >=30 / >=60 / >=90). The first entry
    -- must match BasicStats.RangedDamage (and its HardMode override) - it is the resting shot.
    Damage = {
        Normal = { 50, 85, 115, 150 },
        Hard   = { 75, 130, 190, 250 },
    },

    -- Medium purple over a dark-green body: green held under 1, red/blue pushed well past it.
    Body = FVector(3, 0.6, 4.5),
    Laser = FLinearColor(1.5, 0, 3, 1),
    -- Deep purple over the rifle's grey-green. DiffuseColor: the gun's master has no "Color".
    GunDiffuse = FVector(0.45, 0.1, 0.9),
}

V["Twilight Sniper"] = {
    Id = 52,
    Base = "Grunt_Sniper",
    -- FatigueExhausted buff object - preload here is for residency only (does not pin, see S3).
    -- The re-load that actually guards the cold-load hazard is in OnDealtDamage below.
    Assets = { BULLET_GENERIC, ENUMS.BuffObjects.FatigueExhausted },

    -- Appearance
    Tint = { Color = TWILIGHT.Body },
    Visuals = function(actor, assets)
        Lasers.RecolorSight(actor, TWILIGHT.Laser)
        H.TintRifle(actor, TWILIGHT.GunDiffuse)
    end,

    -- Stats
    BasicStats = {
        HpHead = 90,    -- 60
        HpTorso = 90,   -- 90
        RangedDamage = 50,   -- 200
        RangedAttackCooldown = TWILIGHT.Cooldown,
    },
    -- RangedDamage tracks TWILIGHT.Damage's resting tier; OnTick re-picks the tier from there.
    HardMode = { NoAggroAnim = true, BasicStats = { HpHead = 130, HpTorso = 130, RangedDamage = 75 } },
    Stats = function(actor, opts)
        AVU.ChangeDamageType(actor, BULLET_GENERIC)   -- drop the heavy bleed
        AVU.SetSightConfig(actor, { Radius = TWILIGHT.SightRadius, LoseRadius = TWILIGHT.SightLose })
        H.NoBackpack(actor)                           -- bare-backed: the pack is the Tracker's tell
    end,

    -- Triggers
    -- BasicStats writes NPCData, which BeginPlay has already copied and scaled - the pawn field is
    -- the one the shot reads, so the cadence has to be set again here.
    OnReady = function(actor)
        H.SetAccuracy(actor, {
            Misses   = TWILIGHT.Misses,
            Steady   = TWILIGHT.Steady,
            Sprint   = TWILIGHT.Sprint,
            Cooldown = STATE.HardModeNoMercy and TWILIGHT.HardCooldown or TWILIGHT.Cooldown,
        })
    end,
    -- Combat entry re-opens the cone: ToggleCombatStateFX zeroes the blackboard COUNTER. It does
    -- not touch Accuracy_*, which the difficulty switch writes once in BeginPlay - so this is a
    -- cheap re-assert, not the thing that makes the numbers stick.
    OnEnterCombat = function(actor)
        H.SetAccuracy(actor, { Misses = TWILIGHT.Misses, Steady = TWILIGHT.Steady,
                               Sprint = TWILIGHT.Sprint })
    end,

    -- [AUTHORITY] Keep shot damage synced to the target's current fatigue tier; see H.TwilightTick.
    OnTick = function(actor, totalTicks) return H.TwilightTick(actor, totalTicks, TWILIGHT) end,

    -- [AUTHORITY] No bleed (stripped in Stats) - pump fatigue instead. See H.TwilightDealtDamage
    -- and AnNotes/AnteNPCs/OrderSniper.md for the full decode (the EIGT hop + the stat-ceiling preload trap).
    OnDealtDamage = function(attacker, victim) H.TwilightDealtDamage(attacker, victim, TWILIGHT) end,

    OnDeath = function(actor)
        AVU.DropLoot(actor, { Pool = {
            { G.AMMO_308, 4 },
        } })
    end,
}


-- =======================================================================
-- TRACKER SNIPER
-- Weaker damage, lower rate of fire, but accurate and marks a player and spawns Order
--   * Mark lasts 30s and spawns a Grunt_Guard every 12s
--   * Always wears the Captain's radio pack (the mark's visible source) and drops it on death.
--   * One shot to zero in, and breaking its line of sight takes that shot back
--     (H.SightResetTick - the Twilight's counterplay, same beat).
-- =======================================================================

local TRACKER = {
    Cooldown     = 3.5,   -- 4
    HardCooldown = 3,
    Misses       = 1,     -- 0 (pinpoint from the first round): now it opens one degree wide
    DebuffSec    = 30,
}

V["Tracker Sniper"] = {
    Id = 53,
    Base = "Grunt_Sniper",
    Assets = { BULLET_GENERIC, ENUMS.Components.SM_RADIO_PACK },

    -- Appearance
    Tint = { Color = FVector(6, 6, 0.5) },
    Visuals = function(actor, assets)
        Lasers.RecolorSight(actor, FLinearColor(3, 3, 0, 1))
        H.RadioPackLook(actor)
    end,

    -- Stats
    BasicStats = {
        HpHead = 90, --60
        HpTorso = 120, -- 90
        -- WalkSpeed = 130,
        -- SprintSpeed = 500,
        -- MeleeDamage = 50,
        RangedDamage = 90,   -- 200
    },
    HardMode = {
        NoAggroAnim = true,
        BasicStats = { HpHead = 120, HpTorso = 150, RangedDamage = 120 },   -- 90 / 120 / 90
    },
    Stats = function(actor, opts)
        AVU.ChangeDamageType(actor, BULLET_GENERIC)   -- drop the heavy bleed
    end,

    -- Triggers
    -- SetAccuracy, not LockOnFast: the ladder is wanted here now, just a one-rung one.
    -- Steady/Sprint stay at the class defaults (0.2 / 0.5-1.0 degrees).
    OnReady = function(actor)
        H.SetAccuracy(actor, {
            Misses   = TRACKER.Misses,
            Cooldown = STATE.HardModeNoMercy and TRACKER.HardCooldown or TRACKER.Cooldown,
        })
        H.WearRadioPack(actor)
    end,
    OnTick = H.SightResetTick,
    OnDealtDamage = function(attacker, victim)
        if not Utils.IsPlayer(victim) then return end
        Utils.ApplyBuffLinked(victim, ENUMS.Debuffs.ReaperTrack, TRACKER.DebuffSec, nil)
        H.EnsureTrackingLoop()
        LogDebug("Tracker Sniper - tagged target", SETTINGS.DEBUG_NPC_ACTIONS)
    end,

    OnDeath = function(actor)
        AVU.DropLoot(actor, { Row = G.BACKPACK_RADIO, Amount = 1 })
    end,
}


-- =======================================================================
-- TRACER SNIPER  (a stronger Tracker)
-- Higher damage, faster refire, same yellow marker laser.
--   * [AUTHORITY] Reinforcements arrive via the LEYAK EQS - navigable points OUT of the player's
--     line of sight - instead of dropping on top of them.
--   * One per interval, concurrent-capped, and it gives up on a player the EQS keeps missing.
--   * Same always-on radio pack as the Tracker, dropped on death.
--   * Same one-rung ladder and sight reset as the Tracker.
-- =======================================================================

local TRACER = {
    Cooldown     = 2.7,   -- 3
    HardCooldown = 2.4,
    Misses       = 1,     -- 0 (pinpoint from the first round): now it opens one degree wide
    DebuffSec    = 30,
}

local TRACER_SIGHT      = 14000   -- 140m, down from the sniper's native 200m: it holds its own
local TRACER_SIGHT_LOSE = 16000   -- approach instead of opening on anything across the zone

V["Tracer Sniper"] = {
    Id = 119,
    Base = "Grunt_Sniper",
    Assets = { BULLET_GENERIC, ENUMS.Components.SM_RADIO_PACK },

    -- Appearance
    Tint = { Color = FVector(0.9, 0.9, 0.2) },
    Visuals = function(actor, assets)
        Lasers.RecolorSight(actor, FLinearColor(1, 1, 0, 1))
        H.RadioPackLook(actor)
    end,

    -- Stats
    BasicStats = {
        HpHead = 120,    -- 60
        HpTorso = 150,   -- 90
        RangedDamage = 125,   -- 200
    },
    HardMode = {
        NoAggroAnim = true,
        BasicStats = { RangedDamage = 150 },   -- 125 (HP already reads as its hard value)
    },
    Stats = function(actor, opts)
        AVU.ChangeDamageType(actor, BULLET_GENERIC)   -- drop the heavy bleed
        AVU.SetSightConfig(actor, { Radius = TRACER_SIGHT, LoseRadius = TRACER_SIGHT_LOSE })
    end,

    -- Triggers
    OnReady = function(actor)
        H.SetAccuracy(actor, {
            Misses   = TRACER.Misses,
            Cooldown = STATE.HardModeNoMercy and TRACER.HardCooldown or TRACER.Cooldown,
        })
        H.WearRadioPack(actor)
    end,
    OnTick = H.SightResetTick,
    OnDealtDamage = function(attacker, victim)
        if not Utils.IsPlayer(victim) then return end
        H.TagTarget(victim, TRACER.DebuffSec)
        LogDebug("Tracer Sniper - tagged target", SETTINGS.DEBUG_NPC_ACTIONS)
    end,

    OnDeath = function(actor)
        AVU.DropLoot(actor, { Row = G.BACKPACK_RADIO, Amount = 1 })
    end,
}


-- =======================================================================
-- ASSAULT SNIPER
-- A sniper that moves like a Breacher and marches towards its target
--   * Uses the Breacher's BT and will stop and reload like one
--   * Fires semi-frequently with medium accuracy ('2 shot' miss accuracy)
--   * Sight reduced to be medium distance (250m -> 40m)
--   * Borrows the Breacher's walk so the sight laser runs down the barrel instead of across its
--     chest (H.AssaultLook). Its torso wears a deliberately mis-mapped Breacher gear sheet as camo.
--
-- The two knobs that make it a march instead of a charge:
--   * SPRINT SPEED. In combat WantsToSprint() is just CombatState, so DefaultSprintSpeed is the
--     only speed that matters, and the sniper row ships 500 against the Breacher's 160.
--   * FACING. BTS_FireWhileMoving will not pull the trigger below a 0.9 dot to its target, so a
--     body that orients to its VELOCITY stops firing the moment it has to path around anything.
--     bUseControllerDesiredRotation turns it to face the target instead (the Suppressor's fix).
-- =======================================================================

local BREACHER_BT = "/Game/Blueprints/AI/Soldier/BT_Main_Soldier_Shotgun.BT_Main_Soldier_Shotgun"

local ASSAULT = {
    -- Assault sniper
    Cooldown = 1.5,      -- 2
    Misses = 2,
    Steady = 0.2,
    Sprint = { 1, 2 },   -- aim cone while the TARGET runs, not a speed
    SightRadius = 4000,
    SightLose = 5000,
    MarchSpeed = 170,    -- 500. The Breacher marches at 160
    TurnRate = 220,      -- degrees/sec, so pathing around cover does not break the firing dot
    ChaseSecs = 6,       -- the Breacher's LastSawTargetCheatDuration; base default is 2
    Body = FVector(0.2, 0.3, 0.1),
    -- DiffuseColor MULTIPLIES, so near-black is a low triple, not a dark colour. Slightly cool so
    -- it reads as gunmetal rather than a silhouette. The scope's glass slots have no DiffuseColor,
    -- so the spray leaves the lenses alone.
    GunDiffuse = FVector(0.15, 0.15, 0.18),
    Walk = ENUMS.Anims.BS_BREACHER_RUN,
    Laser = FLinearColor(3, 0.1, 0.1, 1),
}

V["Assault Sniper"] = {
    Id = 179,
    Base = "Grunt_Sniper",
    Assets = { BULLET_GENERIC, BREACHER_BT, ASSAULT.Walk, table.unpack(H.ASSAULT_KIT_ASSETS) },

    -- Appearance
    Tint = { Color = ASSAULT.Body },
    Visuals = function(actor, assets)
        Lasers.RecolorSight(actor, ASSAULT.Laser)
        H.TintRifle(actor, ASSAULT.GunDiffuse)
        H.NoBackpack(actor)        -- adding one
        H.AssaultLook(actor, ASSAULT)
    end,

    -- Stats
    BasicStats = {
        HpHead = 120,   -- 60
        HpTorso = 150,   -- 90
        RangedDamage = 60,   -- 200. Shock trooper: it wins on cadence, not per-shot
        RangedAttackCooldown = ASSAULT.Cooldown,
        SprintSpeed = ASSAULT.MarchSpeed,   -- the combat speed; walk stays the row's 130
    },
    HardMode = { NoAggroAnim = true, BasicStats = { HpHead = 150, HpTorso = 190, RangedDamage = 75 } },
    Stats = function(actor, opts)
        AVU.ChangeDamageType(actor, BULLET_GENERIC)
        AVU.SetSightConfig(actor, { Radius = ASSAULT.SightRadius, LoseRadius = ASSAULT.SightLose })

        -- Face the target while walking, not the direction of travel (see FACING, above).
        pcall(function()
            local move = actor.CharacterMovement
            if IsNotValid(move) then return end
            move.RotationRate = FRotator(0, ASSAULT.TurnRate, 0)
            move.bUseControllerDesiredRotation = true
        end)
    end,

    -- Triggers
    -- The swap has to wait for OnReady: the controller possesses and starts the native sniper tree
    -- during spawn, and RunBehaviorTree replaces whatever is already running.
    OnReady = function(actor)
        H.SetAccuracy(actor, {
            Misses   = ASSAULT.Misses,
            Steady   = ASSAULT.Steady,
            Sprint   = ASSAULT.Sprint,
            Cooldown = ASSAULT.Cooldown,
        })
        -- Keep walking at where you went for a few seconds after cover breaks sight - the
        -- Breacher's own value. The controller keeps the sniper class either way.
        pcall(function()
            local c = actor.NPC_Controller
            if IsNotValid(c) then c = actor:GetController() end
            if IsValid(c) then c.LastSawTargetCheatDuration = ASSAULT.ChaseSecs end
        end)
        AVU.RunBehaviorTree(actor, BREACHER_BT)
    end,
    OnEnterCombat = function(actor)
        H.SetAccuracy(actor, { Misses = ASSAULT.Misses, Steady = ASSAULT.Steady,
                               Sprint = ASSAULT.Sprint })
    end,

    OnDeath = function(actor)
        AVU.DropLoot(actor, { Pool = {
            { G.AMMO_308, 3 },
            { G.MILITARY_ELEC, 2 },
        } })
    end,
}


-- =======================================================================
-- GROUPE SNIPER
-- Elusive sniper - one shot, then it vanishes and repositions
--   * Out of LoS EQS after firing if possible
--   * Its laser slowly regains visibility during its cooldown (actor is otherwise stunned), and
--     reaches full a couple of seconds before it can fire - that gap is the player's warning
--   * A hop that finds no firing line hops AGAIN rather than stranding it (H.SniperRelocateTick)
-- =======================================================================

V["Groupe Sniper"] = {
    Id = 75,
    Base = "Grunt_Sniper",
    Assets = H.GROUPE_ASSETS,   -- snow-explosion burst + break cue

    -- Appearance
    Visuals = function(actor, assets)
        GRP.Wash(actor, H.GROUPE_WASH_STRENGTH)   -- bright snow-white wash
        GRP.FadeIn(actor)
        H.SniperLaser(actor, 1, H.GROUPE_LASER)   -- full resting brightness; the vanish ramps it 0 -> 1
    end,
    ClientTick = true,   -- the warp mirror (see OnTick)

    -- Stats
    BasicStats = {
        -- HpHead = 60,
        -- HpTorso = 90,
        RangedDamage = 120,   -- 200
    },
    HardMode = {
        NoAggroAnim = true,
        BasicStats = { HpHead = 120, HpTorso = 150 },
    },
    TimeDilation = 0.8,
    MirrorTimeDilation = true,   -- clients must see the slow sweep too
    -- Perfect aim + refire cadence: it fires once then leaves, so it must not whiff. The cadence
    -- is the vanish lock (H.GroupeLockS) - the post-hop stun outlasts any cooldown we set here,
    -- so one number owns both, and it is the hard-mode dial.
    Stats = function(actor, opts)
        H.LockOnFast(actor, H.GroupeLockS(), true)
        AVU.SetSightConfig(actor, { Radius = VANISH_SIGHT_RADIUS, LoseRadius = VANISH_SIGHT_LOSE })
    end,

    -- Triggers
    -- [AUTHORITY] the dud-hop watchdog; it idles on a table read until a hop's window lapses.
    -- [RENDERER] Client mirror: render the ice-cloud burst where it vanished from (a teleport is
    -- just a replicated position jump) and re-assert the wash.
    OnTick = function(actor, totalTicks)
        if Utils.IsActorInvalid(actor) then return "REMOVE" end
        if Utils.IsAuthority() then
            if actor.IsDead then return "REMOVE" end
            if totalTicks % H.RELOC_WATCH_TICKS == 0 then
                H.SniperRelocateTick(actor, H.GROUPE_VANISH)
            end
            return
        end
        AVU.WarpMirrorTick(actor, H.GROUPE_FX, WARP_MIRROR_JUMP,
            ENUMS.SOUNDS.STALACTITE_BREAK, H.GROUPE_PUFF_SCALE)
        if totalTicks % 20 == 0 then GRP.Wash(actor, H.GROUPE_WASH_STRENGTH) end
    end,
    -- re-assert (a bytecode switch resets RequiredFailedHits)
    OnEnterCombat = function(actor) H.LockOnFast(actor, H.GroupeLockS(), true) end,
    OnDealtDamage = function(attacker, victim) H.SniperVanish(attacker, victim, H.GROUPE_VANISH) end,
    -- [RENDERER] Taking a hit rebuilds the torso material, reapply the wash. Param write ~free.
    OnDamageTaken = function(actor) GRP.Wash(actor, H.GROUPE_WASH_STRENGTH) end,

    OnDeath = function(actor)
        H.ClearVanishState(actor)
        AVU.DropLoot(actor, { Pool = {
            { G.AMMO_308, 3 },
        } })
    end,
}


-- =======================================================================
-- PRAETORIUM SNIPER  (the Groupe's vanish crossed with the Tracer's tag)
-- Gold blowout wash + dark-gold laser, U1 rifle with a gold scope. Slow sweep, 6s refire.
--   * [AUTHORITY] Every landed shot fades it out to a far LoS perch (fallback: an out-of-LoS
--     EQS cover point) behind a SMOKE burst, stunned 6s (Groupe: 8s).
--   * [AUTHORITY] The hit also tags the target for 15s - about ONE EQS-placed reinforcement, not
--     a stream. It feeds the same loop as the Tracer, so the two stack rather than compete.
-- =======================================================================

local PRAE_SHOT_CD_S  = 6    -- refire cadence; also drives BasicStats.RangedAttackCooldown
local PRAE_DEBUFF_SEC = 15   -- ReaperTrack tag (Tracer: 30) - roughly ONE reinforcement

V["Praetorium Sniper"] = {
    Id = 139,
    Base = "Grunt_Sniper",
    NoAggroAnim = true,
    Assets = H.PRAE_ASSETS,   -- smoke burst + poof cue, U1 rifle mesh, gold lens

    -- Appearance (H.PraetorLook re-asserts this exact wash - keep them the same value)
    Tint = { Color = H.PRAE_WASH },
    Visuals = function(actor, assets)
        H.PraetorLook(actor)
        H.PraetorRifle(actor)                    -- one-shot: U1 rifle + gold scope (NOT re-asserted)
        GRP.FadeIn(actor)                  -- opacity only - no white wash
        H.SniperLaser(actor, 1, H.PRAE_LASER)    -- full resting brightness; the vanish ramps 0 -> 1
    end,
    ClientTick = true,   -- the warp mirror + look re-assert (see OnTick)

    -- Stats
    BasicStats = {
        HpHead = 125, --60
        HpTorso = 150, --90
        RangedDamage = 150,   -- 200
        RangedAttackCooldown = PRAE_SHOT_CD_S,
    },
    HardMode = { BasicStats = { HpHead = 175, HpTorso = 200, RangedDamage = 180 } },
    TimeDilation = 0.8,
    MirrorTimeDilation = true,   -- clients must see the slow sweep too
    Stats = function(actor, opts)
        AVU.ChangeDamageType(actor, BULLET_GENERIC)   -- drop the heavy bleed + BlocksDBNO
        H.LockOnFast(actor, PRAE_SHOT_CD_S, true)     -- fires ONCE then vanishes: it must not whiff
        AVU.SetSightConfig(actor, { Radius = VANISH_SIGHT_RADIUS, LoseRadius = VANISH_SIGHT_LOSE })
    end,

    -- Triggers
    -- [RENDERER] Client mirror: the smoke burst where it vanished from + the look re-assert.
    -- Authority has no per-tick work here; the vanish itself is event-driven.
    OnTick = function(actor, totalTicks)
        if Utils.IsAuthority() then return "REMOVE" end
        if Utils.IsActorInvalid(actor) then return "REMOVE" end
        AVU.WarpMirrorTick(actor, ENUMS.Effects.NIAGARA_SMOKESCREEN, WARP_MIRROR_JUMP,
            ENUMS.SOUNDS.AIR_POOF, H.PRAE_SMOKE_SCALE)
        if totalTicks % 20 == 0 then H.PraetorLook(actor) end
    end,
    OnEnterCombat = function(actor) H.LockOnFast(actor, PRAE_SHOT_CD_S, true) end,

    -- [AUTHORITY] A shot landed: tag the target (short - one reinforcement's worth) AND vanish.
    OnDealtDamage = function(attacker, victim)
        if Utils.IsPlayer(victim) then
            H.TagTarget(victim, PRAE_DEBUFF_SEC)
            LogDebug("Praetorium Sniper - tagged target", SETTINGS.DEBUG_NPC_ACTIONS)
        end
        H.SniperVanish(attacker, victim, H.PRAE_VANISH)
    end,

    -- [RENDERER] Damage-stage textures rebuild the torso material and drop the tint - re-assert
    -- it (def.Tint only runs once, at mutation). Nothing to do on a dedicated server.
    OnDamageTaken = function(actor)
        if not Utils.HasRenderer() then return end
        if Utils.IsActorInvalid(actor) then return end
        AVU.TintMesh(actor, { Color = H.PRAE_WASH })
    end,

    OnDeath = function(actor)
        AVU.DropLoot(actor, { Pool = {
            { G.AMMO_308, 3 },
            { G.TACTICAL_SCRAP, 3 },
        } })
    end,
}


-- =======================================================================
-- PRAETORIUM LIBRARY SNIPER  (Praetorium look/stats, Groupe's plain vanish)
-- Same as the Praetorium Sniper, but: no tag, and it vanishes to a FIXED perch (the library
-- column tops - no LoS ring/EQS can reach them) instead of a queried one, stunned 6s.
--   * Claims perches the other fixed-perch sniper isn't on, so the pair never stacks and neither
--     re-picks the perch it just fired from. Softer (100 vs 150 dmg) since there are two, always
--     repositioning.
--   * 360-degree sight, short range: it can perch facing any direction, so the native 120-degree
--     cone would leave it blind (see LIB_SIGHT_*). Perch list + coords: H.LIB_SPOTS + SpawnerData.
-- =======================================================================

local LIB_SHOT_CD_S = 6   -- refire cadence; also drives BasicStats.RangedAttackCooldown

-- Sight
local LIB_SIGHT_DEGREES = 360
local LIB_SIGHT_RADIUS  = 10000   -- 100m (class native 20000)
local LIB_SIGHT_LOSE    = 15000   --

V["Praetorium Library Sniper"] = {
    Id = 155,
    Base = "Grunt_Sniper",
    NoAggroAnim = true,
    Assets = H.PRAE_ASSETS,   -- smoke burst + poof cue, U1 rifle mesh, gold lens

    -- Appearance (identical to the Praetorium Sniper)
    Tint = { Color = H.PRAE_WASH },
    Visuals = function(actor, assets)
        H.PraetorLook(actor)
        H.PraetorRifle(actor)                    -- one-shot: U1 rifle + gold scope (NOT re-asserted)
        GRP.FadeIn(actor)                  -- opacity only - no white wash
        H.SniperLaser(actor, 1, H.PRAE_LASER)    -- full resting brightness; the vanish ramps 0 -> 1
    end,
    ClientTick = true,   -- the warp mirror + look re-assert (see OnTick)

    -- Stats
    BasicStats = {
        HpHead = 120, --60
        HpTorso = 150, --90
        RangedDamage = 120,   -- 200 (Praetorium Sniper: 150)
        RangedAttackCooldown = LIB_SHOT_CD_S,
    },
    HardMode = { BasicStats = { HpHead = 250, HpTorso = 350, RangedDamage = 150 } },
    TimeDilation = 0.8,
    MirrorTimeDilation = true,   -- clients must see the slow sweep too
    Stats = function(actor, opts)
        AVU.ChangeDamageType(actor, BULLET_GENERIC)   -- drop the heavy bleed + BlocksDBNO
        H.LockOnFast(actor, LIB_SHOT_CD_S, true)      -- fires ONCE then vanishes: it must not whiff
        AVU.SetSightConfig(actor, {                   -- absolute: replaces the class 120deg/200m
            Degrees    = LIB_SIGHT_DEGREES,
            Radius     = LIB_SIGHT_RADIUS,
            LoseRadius = LIB_SIGHT_LOSE,
        })
    end,

    -- Triggers
    OnReady = function(actor) H.RegisterPerchSniper(actor) end,   -- so the perch picker sees it

    -- [RENDERER] Client mirror: the smoke burst where it vanished from + the look re-assert.
    OnTick = function(actor, totalTicks)
        if Utils.IsAuthority() then return "REMOVE" end
        if Utils.IsActorInvalid(actor) then return "REMOVE" end
        AVU.WarpMirrorTick(actor, ENUMS.Effects.NIAGARA_SMOKESCREEN, WARP_MIRROR_JUMP,
            ENUMS.SOUNDS.AIR_POOF, H.PRAE_SMOKE_SCALE)
        if totalTicks % 20 == 0 then H.PraetorLook(actor) end
    end,
    OnEnterCombat = function(actor) H.LockOnFast(actor, LIB_SHOT_CD_S, true) end,

    -- [AUTHORITY] A shot landed: just move. No tag, no reinforcement loop.
    OnDealtDamage = function(attacker, victim) H.SniperVanish(attacker, victim, H.LIB_VANISH) end,

    -- [RENDERER] Damage-stage textures rebuild the torso material and drop the tint - re-assert
    -- it (def.Tint only runs once, at mutation). Nothing to do on a dedicated server.
    OnDamageTaken = function(actor)
        if not Utils.HasRenderer() then return end
        if Utils.IsActorInvalid(actor) then return end
        AVU.TintMesh(actor, { Color = H.PRAE_WASH })
    end,

    OnDeath = function(actor)
        AVU.DropLoot(actor, { Pool = {
            { G.AMMO_308, 3 },
            { G.TACTICAL_SCRAP, 3 },
        } })
    end,
}

return V
