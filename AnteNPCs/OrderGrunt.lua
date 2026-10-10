-- =======================================================================
-- Order Grunt (NPC_Soldier_Grunt) - the SMG soldier (bursts + frag ability)
--
-- MUST-KNOWS
--   * Grunt_Guard / Grunt_Guard_Offduty are SUBCLASSES (same skeleton + NPCData), so a base "Grunt"
--     variant mutates them safely - hence GRUNT_BASES as AltBases rather than a twin def. A variant
--     that WANTS one of those bodies still needs SpawnAs on the spawner (see the Velites).
--   * Burst tuning is GruntBurstCount + GruntBurstTimeBetweenShots - but BOTH ARE DEAD on the two
--     Guard rows: NPC_Grunt_Guard overrides Grunt_FireBurst with a fixed 2-4 round pistol volley on
--     half-second beats, reading neither. Nothing in Lua reshapes that volley; the only suppression
--     is OverrideSoldierFireLogic, which leaves the body firing nothing at all.
--   * SPLIT RULE: each variant's Stats block and its SHORT triggers live INLINE below, so a variant
--     reads top-to-bottom in one place. Helpers hold only the long machinery.
--
-- ABILITY MAP - NPC_Soldier_Grunt (row "Grunt" + every GRUNT_BASES AltBase)
--   0 Idle - none
--   1 GRENADE - the ONE ability the whole Order line has. Throws GrenadeData
--       (projectile_fraggrenade) via Broadcast_ThrowGrenade; the projectile actually spawns on the
--       montage's "GrenadeRelease" anim notify. LoS-gated, 10s cd, and on use it also applies
--       AI_Cooldown_AllyGrenade (4s) to every friendly within 1000uu - the native "one grenade per
--       squad at a time" rule. AVU.DisableGrenades(actor) == AVU.DisableAbility(actor, 1).
--       Implemented here and INHERITED by every Order/Groupe class (Shotgun/Breacher, Sniper,
--       Medic, Captain, the Groupe reskins).
--   2 - EMPTY      3 - EMPTY   (free to claim on any Order variant)
--   GOTCHA: the Sniper's and Medic's controllers set CanThrowGrenades = false, and the inherited
--   AdditionalAbilityCheck IGNORES the slot index - so that one bool blocks EVERY slot on them.
--   NOT a slot: the rifle burst (Grunt_FireBurst, 4 hitscan shots) is the ranged path.
--
-- Machinery: AnteNPCs/OrderGruntHelpers.lua
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local G = require("AnteData.Items").Global
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local H = require("AnteNPCs.OrderGruntHelpers")

local LogDebug = Utils.LogDebug

local GRUNT_BASES = { "Grunt_Guard", "Grunt_Guard_Offduty" }

-- The Breacher's BT: advance to melee, keep firing, stop to reload. Same soldier family and
-- blackboard, so it swaps onto any Grunt-class pawn, incl. the Trooper subclass.
-- Used by the SUPPRESSOR from OnReady, post-spawn on the authority, after the controller has
-- possessed and started the native grunt BT. See AnNotes/AnteNPCs/OrderGrunt.md for why the Centurion
-- no longer uses it.
local BREACHER_BT = "/Game/Blueprints/AI/Soldier/BT_Main_Soldier_Shotgun.BT_Main_Soldier_Shotgun"

local V = {}


-- =======================================================================
-- VELITES GUARD
-- * Fast hit-and-runner with lighter armor, built on the OFF-DUTY GUARD body: every spawner
--     carries SpawnAs="Grunt_Guard_Offduty", so it wears that kit and carries its pistol
-- * Runs a duty cycle (10s/5s on/off. 12s/3s on hard)
--     > While on, it tries to keep distance, moves around, and takes quick shots
--     > While off, it acts more like a Grunt
-- * A hit has a 50% chance to make it 'stagger' sideways which acts as a strafe
-- * Reloads at 2x speed, 4x on hard, and sits the maneuver stack out for that window
-- * Ropes in on scripted spawns, like the Centurion
-- =======================================================================

V["Velites Guard"] = {
    Id = 24,
    -- Base is the body this is BUILT for, and it is also what a bodyless summon spawns
    -- (SummonVariant -> def.Base), so /spawn has to land on the off-duty guard too.
    Base = "Grunt_Guard_Offduty",
    AltBases = GRUNT_BASES,
    -- The off-duty class ships SkipSpawnFX; NpcSpawner flips it back on for the Soldier_Grunt rope.
    RopeSpawn = true,
    Assets = H.VELITES_ASSETS,   -- NVGs + stagger anims; the body's own kit is class-default

    -- Appearance
    -- Tint lands first and Visuals' wash overrides Color on every slot - the emissive here is
    -- what survives, and it is the lens glow.
    Tint = { Color = FVector(2, 2, 0.5), EmissiveColor = FVector(0, 0, 0.4), Emissive = 120 },
    Visuals = H.VelitesLook,
    TimeDilation = H.VELITES_TDI,
    MirrorTimeDilation = true,   -- the reload retime rides CustomTimeDilation - mirror or it's server-only

    -- Stats
    BasicStats = {
        HpHead = 120,   -- 175
        HpTorso = 150,   -- 200
        -- WalkSpeed = 130,
        SprintSpeed = 550,   -- 500
        -- MeleeDamage = 50,
        RangedDamage = 30,   -- 35
        MeleeAttackRange = 1,
    },
    HardMode = { BasicStats = { HpHead = 175, HpTorso = 175, RangedDamage = 40 } },
    Stats = function(actor)
        local move = actor.CharacterMovement
        if IsNotValid(move) then return end

        H.ForceNoBackpack(actor)   -- no helmet to force: the off-duty body never rolls one

        -- Small clip, so the retimed reload is something the player actually sees: at 2-4 rounds
        -- a volley this is ~4 volleys between reloads rather than ~10.
        actor.CurrentAmmoCount = 12
        actor.MaxAmmoCount = 12

        -- Avoid melee; put some spacing between attacks. The volley SHAPE is not ours to set -
        -- the Guard parent's Grunt_FireBurst is fixed and reads neither GruntBurst knob.
        actor.RangedAttack_Cooldown = 1

        AVU.DisableGrenades(actor)

        move.bUseControllerDesiredRotation = true   -- snappy turn + move-and-shoot

        -- Prevent crouch
        AVU.SetCanCrouch(actor, false)

        -- No natural staggers
        pcall(function() actor.StaggerCooldown = 99999 end)
    end,

    -- Triggers
    OnTick = H.VelitesTick,
    OnDamageTaken = H.VelitesDodge,
    OnReload = H.VelitesReload,

    OnDeath = function(actor)
        AVU.DropLoot(actor, { Pool = {
            { G.SCRAP_LEATHER },
            { G.MONEY, 1 },
        }, Radius = 125 })
    end,
}


-- =======================================================================
-- GRENADIER GUARD
-- * Slow, reduced SMG; lobs grenades on scripted beats at mid range
-- * A hard hit can stagger it into cooking off 2-3 live grenades, and it drops one when downed (75%)
-- * Caught in an electrified net it panics and cooks one off where it stands
-- * [HARD] the LAST beat of each 15s cycle is a BARRAGE: three arc-solved frags fanned across the
--     target, thrown on the Interfector knife-throw animation, with the rifle locked out for the
--     duration so its own burst can't cut the throw short (the BARRAGE table in the helpers)
-- =======================================================================

V["Grenadier Guard"] = {
    Id = 25,
    Base = "Grunt",
    AltBases = GRUNT_BASES,
    Assets = H.GRENADIER_ASSETS,   -- bandolier frags + breacher torso textures

    -- Appearance
    -- Actor scale (capsule + mesh) so the body size matches the hitbox; wide X/Y sells the bulk.
    BodyScale = { X = 1.25, Y = 1.25, Z = 1.05 },
    Tint = { Color = FVector(5, 8, 2) },
    Visuals = H.GrenadierLook,

    -- Stats
    BasicStats = {
        HpHead = 175,   -- 175
        HpTorso = 250,   -- 200
        -- WalkSpeed = 130,
        SprintSpeed = 350,   -- 500
        -- MeleeDamage = 50,
        -- RangedDamage = 35,
    },
    TimeDilation = 0.9,
    MirrorTimeDilation = true,   -- so the sped-up throw shows on clients
    Stats = function(actor)
        local move = actor.CharacterMovement
        if IsNotValid(move) then return end

        -- Facing: GrenadierTick calls AVU.FaceTarget during a burst or throw. That drives the
        -- CONTROL rotation, which only reaches the body if the movement component listens to it.
        -- bOrientRotationToMovement stays ON: the CMC only prefers it while accelerating, so the
        -- body walks facing its move direction and turns to face the target once planted.
        move.bUseControllerDesiredRotation = true
        move.RotationRate = FRotator(0, 120, 0)   -- heavy body: slower than the Suppressor's 150

        actor.MaxAmmoCount = 12
        actor.CurrentAmmoCount = 12

        actor.GruntBurstCount = 3
        actor.GruntBurstTimeBetweenShots = 0.2
        actor[ENUMS.NpcData.RangedAttackCooldown] = 4

        AVU.DisableGrenades(actor)   -- grenades are driven by the tick, not the native ability
    end,

    -- Triggers
    OnTick = H.GrenadierTick,
    OnDamageTaken = H.GrenadierHit,

    -- Cooks off a live grenade when downed (75%), delayed so it lands as the grunt drops.
    OnDBNO = function(actor)
        if Utils.IsActorInvalid(actor) then return end
        if math.random() >= 0.75 then return end
        Utils.QueueWork(function()
            if Utils.IsActorValid(actor) then AVU.DropGrenades(actor, 1, 0) end
        end, 600)
        LogDebug("Grenadier Guard - DBNO cook-off", SETTINGS.DEBUG_NPC_ACTIONS)
    end,

    OnDeath = function(actor)
        AVU.DropLoot(actor, { Pool = {
            { G.FRAG_GRENADE },
        }, Radius = 125 })
    end,
}


-- =======================================================================
-- SUPPRESSOR GRUNT
-- * Advancing suppressor, driven by the Breacher's BT
-- * Slow reload
-- * Always helmeted and packed - the kit is the silhouette, not a 50/20% roll
-- * [HARD] longer bursts (15), a bigger clip (45) and a shorter re-burst gap
-- =======================================================================

-- Near-black lid, gunmetal SMG, orange pack, all multiplying their own texture. The helmet reads
-- Color (character master); the gun and pack ride M_AbioticItems_Master, where Color is inert and
-- DiffuseColor is the tint. [[af-abioticitems-master-diffusecolor]]
local SUPP_LOOK = {
    Helmet = FVector(0, 0, 0),
    Gun    = FVector(0.1, 0.03, 0.01),
    Pack   = FVector(1.7, 0.7, 0.12),
}

V["Suppressor Grunt"] = {
    Id = 27,
    Base = "Grunt",
    NoAggroAnim = true,
    AltBases = GRUNT_BASES,
    Assets = {},

    -- Appearance
    -- Actor scale (capsule + mesh) so the body size matches the hitbox.
    BodyScale = { X = 1.05, Y = 1.05, Z = 1.1 },
    Tint = {
        Color = FVector(0.1, 0.1, 0.3),
        Components = {
            Helmet   = { Color = SUPP_LOOK.Helmet },
            Gun      = { DiffuseColor = SUPP_LOOK.Gun },
            backpack = { Slot = 0, DiffuseColor = SUPP_LOOK.Pack },   -- lowercase: the real field name
        },
    },
    Visuals = function(actor)
        pcall(function()
            if IsValid(actor.Gun) then actor.Gun:SetRelativeScale3D(FVector(1.3, 1.3, 1.3)) end
        end)
    end,

    -- Stats
    BasicStats = {
        HpHead = 150,   -- 175
        HpTorso = 250,   -- 200
        WalkSpeed = H.SUPP_WALK,       -- 130 (base)
        SprintSpeed = H.SUPP_SPRINT,   -- 500
        -- MeleeDamage = 50,
        RangedDamage = 30,   -- 35
    },
    TimeDilation = 0.9,
    MirrorTimeDilation = true,   -- the reload retime rides CustomTimeDilation - mirror or it is server-only
    Stats = function(actor)
        local move = actor.CharacterMovement
        if IsNotValid(move) then return end

        move.RotationRate = FRotator(0, 150, 0)
        move.bUseControllerDesiredRotation = true

        H.ForceHelmet(actor)     -- both are native rolls; this one is also a head-hit halving
        H.ForceBackpack(actor)

        -- Short bursts with only a little cooldown between them
        local hard = STATE.HardModeNoMercy
        actor.GruntBurstCount = hard and 15 or 12
        actor.CurrentAmmoCount = hard and 45 or 27
        actor.MaxAmmoCount = hard and 45 or 27
        actor.GruntBurstTimeBetweenShots = hard and 0.1 or 0.13
        actor[ENUMS.NpcData.RangedAttackCooldown] = hard and 1.25    or 1.5

        AVU.DisableGrenades(actor)

        -- Prevent crouch
        AVU.SetCanCrouch(actor, false)
    end,

    -- Triggers
    OnReady = function(actor) AVU.RunBehaviorTree(actor, BREACHER_BT) end,
    OnTick = H.SuppressorTick,
    OnReload = function(actor) AVU.ReloadDilation(actor, STATE.HardModeNoMercy and 0.75 or 0.6) end, --slow reload

    OnDeath = function(actor)
        AVU.DropLoot(actor, { Pool = {
            { G.AMMO_9MM, 3 },
            { G.GUNPOWDER },
            { G.MONEY },
        } })
    end,
}


-- =======================================================================
-- CENTURION GRUNT
-- * Semi-elite - higher health
-- * More aggressive, takes cover less
-- * Swings 50% faster, and fires its own melee release so the extra speed is real
-- * 3s into a fight it radios its target's position in, pulling nearby Order onto them
-- * [HARD] tougher, faster, and hits harder at both ranges
-- =======================================================================


V["Centurion Grunt"] = {
    Id = 123,
    Base = "Trooper",
    NoAggroAnim = true,
    RopeSpawn = true, -- Add repel spawn animation (non-spawner ones)
    Assets = H.CENTURION_ASSETS,

    -- Appearance
    Tint = { Color = FVector(0.5, 0.2, 0) },
    Visuals = function(actor, assets)
        AVU.SetHelmet(actor, {
            Color = FVector(3, 1.3, 0.2),
            LensMaterial = ENUMS.Components.M_GLASS_LENS_RED,
        })
    end,

    -- Stats
    BasicStats = {
        HpHead = 200,   -- 100
        HpTorso = 200,  -- 150
        --WalkSpeed = 200,
        SprintSpeed = 500,   -- 600
        MeleeDamage = 75,   -- 50
        RangedDamage = 25,   -- 25
    },
    HardMode = { BasicStats = { HpHead = 250, HpTorso = 250, SprintSpeed = 600,
                                MeleeDamage = 100, RangedDamage = 30 } },
    DebuffsImmune = { ENUMS.Debuffs.Bleeding },
    TimeDilation = 0.85,
    Stats = function(actor)
        local move = actor.CharacterMovement
        if IsNotValid(move) then return end

        move.RotationRate = FRotator(0, 150, 0)
        move.bUseControllerDesiredRotation = true

        H.ForceHelmet(actor)   -- the dark-gold helmet is its signature
        H.CenturionMeleeTempo(actor)   -- 1.5x swing; OnTick supplies the release valve

        -- Hardened here, not in HardMode.BasicStats: this stat is written below, and Stats() wins.
        local rangedCd = STATE.HardModeNoMercy and 1.3 or 1.5   -- 1.5

        actor.MaxAmmoCount = 20
        actor.CurrentAmmoCount = 20
        actor.GruntBurstCount = 5
        actor.GruntBurstTimeBetweenShots = 0.2
        actor[ENUMS.NpcData.RangedAttackCooldown] = rangedCd
        actor.RangedAttack_Cooldown = rangedCd

        AVU.DisableGrenades(actor)
        AVU.ClearLoot(actor, true)   -- it drops future loot otherwise; OnDeath takes over
    end,

    -- Triggers
    -- No OnReady: runs the NATIVE soldier tree. H.CenturionTick's bravery counters supply the
    -- forward pressure instead - see AnNotes/AnteNPCs/OrderGrunt.md.
    OnTick = H.CenturionTick,   -- pins FailedHits/MeleeCounter to 0, the squad mark, the release
    OnMeleeSwing = H.CenturionSwing,
    OnEnterCombat = H.CenturionAggro,   -- arms the fight's one call-out

    OnDeath = function(actor)
        H.CenturionDeath(actor)
        AVU.DropLoot(actor, { Pool = {
            { G.AMMO_556, 4 },
            { G.MILITARY_ELEC, 2 },
            { G.SCRAP_KEVLAR },
            { G.MONEY, 2 },
            { G.TACTICAL_SCRAP, 1, MinStory = 81 },
        } })
    end,
}


-- =======================================================================
-- SPECULATORES
-- * Ropes in on spawn, and when its target kites out past 15m ([HARD] 10m) it winches itself UP
--     the rope, vanishes for a beat, and drops back down at a fresh LoS point near them
-- * Sees out to 35m
-- * Keeps its grenades - a frag lobbed from the flank is the point of it
-- * The rope + climb pose are mirrored on every renderer off one replicated flag
-- =======================================================================

local SPEC_CHECK_TICKS = 50   -- authority: consider a relocate every ~5s
-- Delayed: a SensesConfig write blinds the body ~10s (the Commander's reasoning, AnNotes/AnteSystems/NPCPerception.md).
local SPEC_SIGHT = { Radius = 3500, DelayMs = 4000 }

V["Speculatores"] = {
    Id = 135,
    Base = "Trooper",
    NoAggroAnim = true,
    RopeSpawn = true,     -- ropes in on scripted spawns (see the Centurion note)
    ClientTick = true,    -- pure clients run OnTick too - that's where the rope mirror lives
    Assets = H.SPECULATORES_ASSETS,   -- rope mesh + material, fastrope loop, gold lens

    -- Appearance
    Tint = { Color = FVector(8, 4, 0.2) },
    Visuals = function(actor, assets)
        AVU.SetHelmet(actor, {
            Color = FVector(8, 4, 0.2),
            LensMaterial = ENUMS.Components.M_GLASS_LENS_GOLD,
        })
    end,

    -- Stats
    BasicStats = {
        HpHead = 250, --100
        HpTorso = 300, --150
        -- WalkSpeed = 200,
        -- SprintSpeed = 600,
        MeleeDamage = 125,
        RangedDamage = 25,   -- 25
    },
    HardMode = { BasicStats = { HpHead = 300, HpTorso = 350, MeleeDamage=150, RangedDamage = 40 } },
    Stats = function(actor)
        H.ForceHelmet(actor)
        actor.RangedAttack_Cooldown = 0.5
        AVU.SetSightConfig(actor, SPEC_SIGHT)
    end,

    -- Triggers
    -- Renderer half: rope show/hide mirrored off the replicated flag, every tick (two prop reads).
    -- Authority half: the relocate driver, every ~5s. Both bodies live in the helpers.
    OnTick = function(actor, totalTicks)
        if Utils.IsActorInvalid(actor) then return "REMOVE" end
        if Utils.HasRenderer() then H.SpecRopeMirror(actor, totalTicks) end
        if not Utils.IsAuthority() then return end
        if totalTicks % SPEC_CHECK_TICKS ~= 0 then return end
        H.SpecDrive(actor, totalTicks)
    end,

    OnDeath = function(actor)
        AVU.DropLoot(actor, { Pool = {
            { G.AMMO_556, 4 },
            { G.TACTICAL_SCRAP, 1, MinStory=81 },
            { G.SCRAP_KEVLAR },
        } })
    end,
}

return V
