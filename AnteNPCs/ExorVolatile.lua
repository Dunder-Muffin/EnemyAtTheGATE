-- =======================================================================
-- VOLATILE EXOR (row "Exor_Volatile") - melee, high HP, big leap, radiation aura, native
-- self-destruct at low health.
--
-- ABILITY MAP: 0 Idle | 1 Leap | 2,3 EMPTY
--   Leap  - the BT fires it at a target 900uu+ away, off Cooldown_CombatAbility1 (clock starts at
--           the LANDING). The arc is bytecode, with no distance or speed property:
--           GravityScale is the only DISTANCE lever (H.LeapDamp), and def.LeapSpeed the only
--           SPEED one (CombatHooks scales the launch velocity). Landing applies Debuff_Concussed
--           near players; def.NoLeapConcussion strips it.
--   Melee - PerformMultiSwipe, a Sharp/Blunt 2-hit gated by a delay, not animSpeed.
--   Boom  - SelfDetonateHealthPercentage/Chance gate PerformSelfDetonation (1.2s telegraph, then
--           gibs + blasts).
--
-- No NPC-dealt engine AoE anywhere in this file. Acid blood debuffs players and point-hits NPCs one
-- at a time, off-hook. The inherited RadiationZone timer re-entering ProcessDamage in a crowd
-- crashed; AVU.ClearRadiationZone (in Stats) clears it. The self-destruct blast is a native
-- one-shot, not a timer, so it's safe.
--
-- Variants: Acidic Exor (slow/fragile, acid bleed on physical hits, ranged acid burst in hard
-- mode) | Exor Hunter (dull senses, slow swings; keeps one Killer standing at all times) |
-- Exor Killer (the twin - rushes in once, then leaps; never summons/detonates).
--
-- Machinery: AnteNPCs/ExorVolatileHelpers.lua
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local ENUMS = require("AnteData.Enums")
local G = require("AnteData.Items").Global
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local ASSETS = require("AnteCore.AssetManager")
local H = require("AnteNPCs.ExorVolatileHelpers")

local LogDebug = Utils.LogDebug

local V = {}


-- =======================================================================
-- ACIDIC EXOR
-- * Slower and larger
-- * Physical damage (sharp/blunt/bullet) sprays acid blood: acid burn on players, an Acid hit on
--     nearby NPCs of other factions (pets included)
-- * [HARD] Tankier and harder-hitting, and it answers kiting with the acid burst (SPIT)
-- =======================================================================

local DRIP_FX    = ENUMS.Effects.BUFF_FLASK_CORROSIVE
local DRIP_BONE  = "spine2"
local DRIP_SCALE = FVector(2, 2, 2)

-- def.Assets: the drip aura, plus what the acid retaliation needs resident (BuffObjects.AcidBurn
-- is named BY ROW NAME, so loading the DamageType alone wouldn't pull it in).
local ACID_ASSETS = {
    DRIP_FX,
    ENUMS.BuffObjects.AcidBurn, ENUMS.BuffObjects.HPDamage, ENUMS.DamageType.Acid,
    ENUMS.Effects.ACID_MACE_IMPACT,   -- the retaliation spray; BroadcastFX needs it resident
}

-- Self-destruct - always explode at 25% head or torso health.
local BOOM_HP_PCT = 0.25
local BOOM_CHANCE = 1
local BLAST_MELEE = 80   -- -> 240 inner / 80 outer edge

-- Warmed by OnSelfDetonate 1.2s ahead so nothing cold-loads at the blast. The blast DamageType
-- applies Debuff_AcidBurn via DebuffsCanApply, so its buff object must be warm too.
local VOLATILE_EXPLODE_FX = "/Game/Blueprints/Environment/Effects/VolatileExorExplode_FX_BP.VolatileExorExplode_FX_BP_C"
local DETONATE_DEPS = {
    VOLATILE_EXPLODE_FX, ENUMS.Anims.EXOR_VOLATILE_DETONATE, ENUMS.DamageType.AcidVolatile,
    ENUMS.BuffObjects.AcidBurn, ENUMS.BuffObjects.HPDamage,
}

local ACID_LEAP_COOLDOWN = 12    -- 5
local ACID_LEAP_GRAVITY  = 1.75  -- 1.0 (see H.LeapDamp)

V["Acidic Exor"] = {
    Id = 109,
    Base = "Exor_Volatile",
    Assets = ACID_ASSETS,

    BodyScale = 1.2,   -- actor scale: hitbox grows with the body
    NavRadius = AVU.NATIVE_NAV_RADIUS.Humanoid,   -- the body wedged in doorways
    Tint = { Color = FVector(0.2, 0.8, 0.3), EmissiveColor = FVector(0.2, 0.7, 0), Emissive = 30 },

    -- [RENDERER] Acid permanently sheeting off its back. Path, not assets[...]: re-resolved at use.
    Visuals = function(actor, assets)
        if not SETTINGS.GAMEPLAY.REDUCE_VISUALS then
            AVU.AttachNiagara(actor, DRIP_FX, DRIP_BONE, { Scale = DRIP_SCALE })
        end
    end,

    BasicStats = {
        HpHead  = 800,   -- 1100
        HpTorso = 800,   -- 1100
        WalkSpeed   = 125,   -- 150
        SprintSpeed = 200,   -- 850
        MeleeDamage = 35,    -- 50
        MeleeAttackRange = 190,   -- 150
    },
    HardMode = {
        BasicStats = { HpHead = 1000, HpTorso = 1000, SprintSpeed = 250, MeleeDamage = 45 },
    },
    DebuffsImmune = { ENUMS.Debuffs.AcidBurn },
    TimeDilation = 0.8,

    Stats = function(actor, opts)
        pcall(function() actor.Cooldown_CombatAbility1 = ACID_LEAP_COOLDOWN end)
        H.LeapDamp(actor, ACID_LEAP_GRAVITY)
        pcall(function() actor.SelfDetonateChance = BOOM_CHANCE end)
        pcall(function() actor.SelfDetonateHealthPercentage = BOOM_HP_PCT end)
        AVU.ClearRadiationZone(actor)   -- the timer-in-a-crowd crash
    end,

    -- Triggers
    OnEnterCombat = H.AcidicEnterCombat,   -- [HARD] warms the acid-burst deps
    OnTick = H.AcidicTick,                 -- [HARD] the acid burst
    OnDamageTaken = H.AcidicDamageTaken,   -- acid blood on a physical hit

    -- PRE-hook on PerformSelfDetonation, so this fires at the start of the 1.2s telegraph: warm
    -- what the blast touches, and set its damage (read x3 at +1.2s).
    OnSelfDetonate = function(actor)
        if Utils.IsActorInvalid(actor) then return end
        ASSETS.WarmPinned(DETONATE_DEPS)
        pcall(function() actor.NPCData[ENUMS.NpcData.MeleeDamage] = BLAST_MELEE end)
        LogDebug("Acidic Exor - self-destruct armed (blast in ~1.2s)", SETTINGS.DEBUG_NPC_ACTIONS)
    end,

    OnDeath = H.AcidicDeath,

    OnGibbed = function(actor)
        AVU.DropLoot(actor, {
            { Row = G.DISTILLATION_UNSTABLE, Amount = 4 },
        })
    end,
}


-- =======================================================================
-- EXOR HUNTER
-- A slow, dull-sensed tank whose job is finding you, not killing you: once it has a target it
-- stands an Exor Killer up out of that target's line of sight, and replaces the Killer a few
-- seconds after each one dies. The fight ends when the Hunter does.
--   * Dull senses are the POINT - short sight, narrow cone, deaf - so a player can walk around
--     an encounter instead of only fighting through it.
--   * Hunter: rare leaps, slow swings. Killer: constant leaps, and a rush it spends once.
-- =======================================================================

local HUNTER_LEAP_COOLDOWN = 30   -- 5 (bait: leaps rarely)

-- The Hunter's senses, all three deliberately below native. Sight is 2000uu / 170 degrees on this
-- chassis, and the mod's own floor puts every NPC on SETTINGS.GAMEPLAY.AI_SENSE.HearingRange.
--   * Deafness has to be an exact 0 - the hearing sweep and the spawn top-up raise anything
--     between 1 and the floor straight back, and read 0 as deliberate.
--   * Eyesight 1 undoes the global multiplier the STATS step gives every Antevariant, and has to
--     land after it, because that call retries itself off-hook when the controller is late.
--   * Deferred: a SensesConfig write inside the mutation drain can deregister perception outright,
--     and each of the two setters re-registers the listener (~10s of sight). That outage is the
--     price of a permanent nerf, and here it lands on a body meant to be oblivious.
local HUNTER_SENSES = {
    Radius     = 1000,   -- 2000
    LoseRadius = 2000,   -- 3000
    Degrees    = 120,    -- 170 (the TOTAL cone, not the half-angle UE stores)
}
local HUNTER_EYESIGHT    = 1
local HUNTER_SENSE_DELAY = 4000   -- ms; clears the whole mutation pipeline

V["Exor Hunter"] = {
    Id = 110,
    Base = "Exor_Volatile",
    Assets = {},

    BodyScale = 1.1,
    Tint = { Color = FVector(5, 6, 5), EmissiveColor = FVector(0.7, 0.15, 0.15), Emissive = 10 },

    BasicStats = {
        HpHead  = 1200,   -- 1100
        HpTorso = 1200,   -- 1100
        WalkSpeed   = 130,   -- 150
        SprintSpeed = 300,   -- 850
        MeleeDamage = 30,    -- 50
    },
    HardMode = {
        BasicStats = { HpHead = 1600, HpTorso = 1800, MeleeDamage = 50 },
    },
    TimeDilation = 0.7,
    NoLeapConcussion = true,
    Stats = function(actor, opts)
        if Utils.IsActorInvalid(actor) then return end
        -- Never detonate
        pcall(function() actor.SelfDetonateChance = 0.0 end)
        pcall(function() actor.SelfDetonateHealthPercentage = -1.0 end)
        pcall(function() actor.Cooldown_CombatAbility1 = HUNTER_LEAP_COOLDOWN end)
        AVU.ClearRadiationZone(actor)
        Utils.QueueWork(function()
            if Utils.IsActorInvalid(actor) then return end
            AVU.SetEyesight(actor, HUNTER_EYESIGHT)
            AVU.SetHearingSense(actor, 0, 0)
            AVU.SetSightConfig(actor, HUNTER_SENSES)
        end, HUNTER_SENSE_DELAY)
    end,

    -- Triggers
    OnTick = H.HunterTick,
    OnMeleeSwing = H.PaceArm,
    OnEnterCombat = H.HunterEnterCombat,
    OnDeath = H.HunterDeath,

    OnGibbed = function(actor)
        AVU.DropLoot(actor, { Row = G.PLUTONIC_BLOOD, Amount = 4 })
        AVU.DropLoot(actor, { Row = G.DISTILLATION_UNNERVING, Amount = 3 })
    end,
}


-- The twin. No OnEnterCombat, so a Killer can never summon its own. Felt speed ~= SprintSpeed *
-- TimeDilation. Tint: EmissiveColor+Emissive drive the glowing spines; the rest of the pustules
-- are baked into the base-color texture, so Color is their only lever.
local KILLER_RUSH_SPEED = 1500   -- spent once (see H's rush section); slows to 300 after
local KILLER_RUSH_GRACE = 3      -- seconds of no leaping, ~= the run in from the far edge of placement
local KILLER_LEAP_COOLDOWN = 2   -- 5 (ambusher; the clock starts at the LANDING)

V["Exor Killer"] = {
    Id = 111,
    Base = "Exor_Volatile",
    Assets = {},

    BodyScale = 0.7,
    Tint = { Color = FVector(0.3, 0.4, 0.3), EmissiveColor = FVector(0, 0, 0), Emissive = 15 },

    BasicStats = {
        HpHead  = 300,   -- 1100
        HpTorso = 500,   -- 1100
        HpLeftArm = 100, HpRightArm = 100, HpLeftLeg = 100, HpRightLeg = 100,   -- 800
        -- Walk == sprint: an NPC in combat always uses the sprint figure, and a stat recalc would
        -- otherwise re-snap the body to whichever of the two it was not using.
        WalkSpeed   = KILLER_RUSH_SPEED,
        SprintSpeed = KILLER_RUSH_SPEED,   -- 850
        MeleeDamage = 60,    -- 50
    },
    HardMode = {
        BasicStats = { HpHead = 400, HpTorso = 600, MeleeDamage = 70 },
    },
    TimeDilation = 1.1,
    NoLeapConcussion = true,
    LeapSpeed = 0.7,   -- fraction of the native launch speed
    -- Never detonate: chance 0 makes PerformSelfDetonation unreachable; the -1 gate is belt-and-braces.
    Stats = function(actor, opts)
        if Utils.IsActorInvalid(actor) then return end
        pcall(function() actor.SelfDetonateChance = 0.0 end)
        pcall(function() actor.SelfDetonateHealthPercentage = -1.0 end)
        pcall(function() actor.Cooldown_CombatAbility1 = KILLER_LEAP_COOLDOWN end)
        pcall(function() actor:SetAbilityOnCooldown(1, true, KILLER_RUSH_GRACE) end)
        AVU.ClearRadiationZone(actor)
        -- A body the Hunter replaces forever must not become a farm: no death drop and no gib
        -- salvage, but still gibbable (preserveGib keeps CanBeGibbed; ClearGibLoot blanks the payout).
        AVU.ClearLoot(actor, true)
        AVU.ClearGibLoot(actor)
    end,

    -- Watches for the leap that ends the rush; a swing does the same through OnMeleeSwing.
    OnTick = H.KillerTick,
    OnMeleeSwing = H.KillerCommitSlow,
}


return V
