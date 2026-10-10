-- =======================================================================
-- PEST VARIANTS
--
-- Def schema + the BasicStats convention: CLAUDE.md section 1. File-relevant reminders:
--   * SpawnDelay - extra wait before Visuals/attachments; attaching during a slow spawn anim can
--     chaos-crash (defaults to AVU.SpawnAnimDelay(Base)).
--   * Visuals is [RENDERER] only (never dedicated) - cosmetics; Stats/OnTick/On* are [AUTHORITY].
--   * Pests are HEAD-ONLY for HP (Torso + limbs are 0), so no BasicStats block here has HpTorso.
--
-- ABILITY MAP - NPC_Monster_Pest (rows "Pest", "Pest_Carbonated" = Chonky, "Pest_Volatile" = Signal)
--   0 Idle - none
--     * No Pest variant uses a slot; only Pest_Leyak does (1 = an EQS teleport).
--   NOT slots:
--     * Leap - melee channel (Server_DoMeleeAttack -> Server_InstantlyLunge, PestLeapVelocity 1000)
--     * Carbonated knockback - melee-IMPACT hook
--       (Broadcast_MeleeAttackImpact -> Server_AoeKnockback)
--
-- Machinery: AnteNPCs/PestHelpers.lua
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local ENUMS = require("AnteData.Enums")
local G = require("AnteData.Items").Global
local STATE = require("AnteCore.State")
local AVU = require("AnteUtils.AVUtils")
local H = require("AnteNPCs.PestHelpers")

local V = {}

-- [HARD] Razor/Anterazor evade: past MinDist, the leap becomes a 2-leg Flurry weave
-- (H.ZigLeap) - one side hop, then the dive at the target. Under it, the normal leap stands.
-- The shape is H.HARD_EVADE in PestHelpers, shared with the tamed Razor.
local RAZOR_RECOVER_HOLD = 12   -- [HARD] Razor post-leap pause in ticks (the Anterazor keeps PestHelpers' 17)


-- =======================================================================
-- RAZOR PEST
-- A fast, short ranged pest with a bleed attack
--   * 80% chance to proc Bleed on hit
--   * Coil leap - its leap moves it slightly backwards before launching forward
--   * Net + bleed + FEAR immune. Drops quills
--   * [HARD] - +health, faster, sharp/bullet resist. Does an evasive jump before leaping, and
--     recovers on the ground for ~1.2s after every leap (no FX - see PestHelpers' RECOVER block)
-- =======================================================================

V["Razor Pest"] = {
    Id = 1,
    Base = "Pest",
    Assets = { ENUMS.Components.SM_QUILL },
    TamedVariant = "Tamed Razor Pest",   -- its PET form; PetManager re-mutates a tamed Razor here

    -- Appearance
    -- Actor scale = capsule + mesh, so the bigger body is a bigger hitbox.
    BodyScale = { X = 1.1, Y = 1.1, Z = 1.2 },
    Tint = { Color = FVector(0.5, 0.3, 0.3), EmissiveColor = FVector(1, 0, 0), Emissive = 20 },
    Visuals = function(actor, assets)
        H.AttachQuillRow(actor, FVector(1, 0, 0))
    end,

    -- Stats
    BasicStats = {
        HpHead = 35,   -- 25
        -- WalkSpeed = 150,
        -- SprintSpeed = 150,
        MeleeDamage = 10,   -- 35
        -- RangedDamage = 15,
        MeleeAttackRange = 500,
    },
    DebuffsImmune = { ENUMS.Debuffs.Netted, ENUMS.Debuffs.NettedCannon, ENUMS.Debuffs.Bleeding,
                      ENUMS.Debuffs.Fear },
    TimeDilation = 1.9,
    -- [HARD] resistances live in NpcResistances.HardMode; the evade in OnLeapWindup below.
    HardMode = {
        BasicStats = { HpHead = 60, MeleeDamage = 40, MeleeAttackRange=750 }, 
    },
    Stats = function(actor, opts)
        local move = actor.CharacterMovement
        if IsNotValid(move) then return end

        move.MaxAcceleration = move.MaxAcceleration * 0.7
        move:SetGravityDirection(FVector(0, 0, -1)) --grav direction
        move.GravityScale = 0.3 -- grav strength
        H.ScaleLeap(actor, 0.5)
    end,

    -- Triggers
    -- Up-and-back, hang, dive (PestHelpers' COIL_* knobs).
    -- [HARD] past 2m: a side-hop weave REPLACES the coil for that leap (under 2m/off-hard, coil
    -- stands). Every leap also arms a post-leap pause (H.RecoverArm) that REPLACES the tree's own
    -- ~1.2s wait - see PestHelpers' RECOVER block before retuning.
    OnLeapWindup = function(actor)
        if STATE.HardModeNoMercy then
            H.RecoverArm(actor, RAZOR_RECOVER_HOLD)
            if H.ZigLeap(actor, H.HARD_EVADE) then return end
        end
        H.CoilLeap(actor)
    end,

    -- [HARD] drives that pause. Off-hard there is nothing to drive, so the entry unregisters
    -- itself on its first fire rather than costing a lookup 10x/s per Razor forever.
    OnTick = function(actor)
        if not STATE.HardModeNoMercy then return "REMOVE" end
        H.RecoverTick(actor)
    end,

    -- 80% bleed on hit, halved by Thick Skinned.
    OnDealtDamage = function(attacker, victim)
        H.RazorBleed(victim, { Bleed = 80 })
    end,

    OnGibbed = function(actor)
        AVU.DropLoot(actor, { Row = G.QUILL, Amount = 2 })
    end,
}


-- =======================================================================
-- CHONKY PEST
-- A tanky Carbonated Pest. Deals blunt damage. Heavy with a low leap
--   * 50% chance to proc leg fractures on hit
--   * Blunt damage, no special carbonated pest attack (the pet form does)
--   * [HARD] - double health (a wall you have to chew through, not a faster one)
-- =======================================================================
local CHONKY_SPECIAL_OFF = 99999

local function chonkyDisarmSpecial(actor)
    pcall(function() actor.SpecialAttackDamage = 0 end)
    pcall(function() actor.SpecialAttackRadius = 0 end)
    pcall(function() actor.KnockbackStrength = 0 end)
    pcall(function() actor.KnockbackFriendlies = false end)
    pcall(function() actor.SpecialAttackCooldown = CHONKY_SPECIAL_OFF end)
    pcall(function() actor:StartSpecialAttackCooldown() end)   -- <- the line that actually does it
end

V["Chonky Pest"] = {
    Id = 2,
    Base = "Pest_Carbonated",
    Assets = { ENUMS.DamageType.Blunt },
    TamedVariant = "Tamed Chonky Pest",

    -- Appearance
    Tint = { Color = FVector(1, 0.8, 0.6), EmissiveColor = FVector(1, 0.7, 0), Emissive = 30 },
    Visuals = function(actor, assets)
        AVU.SetVisualScale(actor, FVector(1.7, 2, 1.7))
    end,

    -- Stats
    BasicStats = {
        HpHead = 75,   -- 25
        WalkSpeed = 100,   -- 150
        SprintSpeed = 250,   -- 150
        MeleeDamage = 50,   -- 35
        -- RangedDamage = 15,
        MeleeAttackRange = 800,
    },
    DebuffsImmune = { ENUMS.Debuffs.Bleeding, ENUMS.Debuffs.SevereBleeding },
    TimeDilation = 0.6,   
    HardMode = {
        BasicStats = { HpHead = 150, MeleeDamage = 70, SprintSpeed = 300 }, 
    },
    Stats = function(actor, opts)
        local move = actor.CharacterMovement
        if IsNotValid(move) then return end

        actor.RangedAttack_Cooldown = 0

        chonkyDisarmSpecial(actor)   -- no carbonation AoE at all (see the banner)

        AVU.ChangeDamageType(actor, ENUMS.DamageType.Blunt, true)

        H.ScaleLeap(actor, 2)
        move:SetGravityDirection(FVector(0, 0, -1))
        move.GravityScale = 20
    end,

    -- Triggers
    OnDealtDamage = function(attacker, victim)
        H.MaybeFractureLeg(victim, 50)
    end,

    OnGibbed = function(actor)
        AVU.DropLoot(actor, { Row = G.SCRAP_BIO, Amount = 3 })
    end,
}


-- =======================================================================
-- ANTEGRAV PEST
-- A smaller pest that flips gravity every 5s
--   * The upside-down mesh flip is server-side only for the moment (doesn't replicate)
--   * [HARD] - +health/damage and a longer pounce
-- =======================================================================

-- The ceiling flip is a 180 degree rotation - a negative scale can cause a render crash.
local ANTEGRAV_SCALE = FVector(0.9, 0.9, 0.9)

-- Pounce reach comes from BOTH speed and gravity (airtime) - see AnNotes/AnteNPCs/Pest.md.
local ANTEGRAV_FLIP = { PoseScale = ANTEGRAV_SCALE, DownScale = 0.9 }   -- 1.5 default
local ANTEGRAV_LEAP = { Normal = 1.0, Hard = 1.3 }                      -- x H.LEAP_BASE

V["Antegrav Pest"] = {
    Id = 3,
    Base = "Pest",
    Assets = {},

    -- Appearance
    Tint = { Color = FVector(0.1, 0.3, 0.3), EmissiveColor = FVector(0, 0, 1), Emissive = 200 },
    Visuals = function(actor, assets)
        AVU.SetVisualScale(actor, ANTEGRAV_SCALE)
    end,

    -- Stats
    BasicStats = {
        HpHead = 30, --25
        WalkSpeed = 300,   -- 150
        SprintSpeed = 500,   -- 150
        MeleeDamage = 30,   -- 35
        -- RangedDamage = 15,
        MeleeAttackRange = 1000,
    },
    DebuffsImmune = { ENUMS.Debuffs.ShockTrap, ENUMS.Debuffs.Zapped },
    HardMode = {
        BasicStats = { HpHead = 60, MeleeDamage = 45, MeleeAttackRange = 1000 }, 
    },
    Stats = function(actor, opts)
        AVU.LockTaming(actor)   -- bespoke variant, no pet form -> not pheromone-tameable

        local move = actor.CharacterMovement
        if IsNotValid(move) then return end

        -- ASK BEFORE CLIMBING. This is the ONE flip the tick-side verify cannot save us from: it
        -- learns by TRYING, so a rooftop spawn climbs ~67m and falls back before the 2.5s deadline
        -- lands. One upward trace here answers it up front, and a negative verdict is recorded for
        -- the whole room so PeriodicGravFlip keeps this pest (and its packmates) grounded too.
        if AVU.CeilingProbeSpawn(actor) then
            move:SetGravityDirection(FVector(0, 0, 1))
            move.GravityScale = 2.5
        else
            -- Grounded for good here, but on the FLOOR gravity the pounce is tuned against, not
            -- the native 1 - DownScale is the reach dial (travel = speed x airtime, see AnNotes/Pest).
            move:SetGravityDirection(FVector(0, 0, -1))
            move.GravityScale = ANTEGRAV_FLIP.DownScale
        end
        H.ScaleLeap(actor, STATE.HardModeNoMercy and ANTEGRAV_LEAP.Hard or ANTEGRAV_LEAP.Normal)

        -- Big sight radius or it avoids aggro while on the ceiling
        AVU.SetSightSense(actor, 3000, 3000, 360)
    end,

    -- Triggers
    -- PoseScale re-asserts ANTEGRAV_SCALE so the mesh keeps its shrunk size through each flip.
    OnTick = function(actor, totalTicks)
        return AVU.PeriodicGravFlip(actor, totalTicks, ANTEGRAV_FLIP)
    end,

    -- Corpse shouldn't stick to the ceiling
    OnDeath = function(actor)
        AVU.RestoreGravity(actor)
    end,
}


-- =======================================================================
-- SIGNAL PEST (Pest_Volatile body)
-- Self-destructs when it hits a target, creating a lure effect on all nearby enemies
--   * Far vision, 360 degrees
--   * Debuffs with Stinky and Stalker spawns a Pest to move to the position
--   * [HARD] - Applies Sick and spawns a Pest variant
-- =======================================================================

V["Signal Pest"] = {
    Id = 4,
    Base = "Pest_Volatile",
    Assets = H.SIGNAL_ASSETS,

    -- Appearance
    BodyScale = 0.9,
    Tint = { Color = FVector(1, 0.5, 1), EmissiveColor = FVector(1, 0.5, 0), Emissive = 50 },

    -- Stats
    BasicStats = {
        HpHead = 10,   -- 200
        -- WalkSpeed = 150,
        -- SprintSpeed = 150,
        MeleeDamage = 1,   -- 150
        -- RangedDamage = 15,
        MeleeAttackRange = 2000,
    },
    HardMode = {
        BasicStats = { MeleeDamage = 45 },   -- 1
        TimeDilation = 1.2,                  -- 1.0 
    },
    Stats = function(actor, opts)
        AVU.LockTaming(actor)   -- not tameable
        H.VolatileBaseSetup(actor)

        local move = actor.CharacterMovement
        if IsNotValid(move) then return end

        AVU.SetSightSense(actor, 3000, 3000, 360)   -- sees all, hears average

        move:SetGravityDirection(FVector(0, 0, -1))
        move.GravityScale = 0.4
        H.ScaleLeap(actor, 1.8)
    end,

    -- Triggers
    -- Mark -> die -> lure. Killed before it connects it marks nothing and never lures.
    OnDealtDamage = H.SignalHit,
    OnDeath = H.SignalNoise,

    OnGibbed = function(actor)
        AVU.DropLoot(actor, { Row = G.DISTILLATION_FLESHY, Amount = 6 })
    end,
}


-- =======================================================================
-- CHONKY SIGNAL PEST 
-- Chonky Pest that has the self-destruct and lure of the Signal Pest
--   * Faster, causes 2 fractures
--   * Signal spawns 2 Pests instead of one
--   * [HARD] - Applies Sick and spawns Pest variants
-- =======================================================================

V["Chonky Signal Pest"] = {
    Id = 6,
    Base = "Pest_Volatile",
    Assets = H.SIGNAL_ASSETS,

    -- Appearance
    BodyScale = { X = 1.7, Y = 1.85, Z = 1.7 },
    Tint = { Color = FVector(1, 0.5, 0), EmissiveColor = FVector(0.6, 0.1, 0), Emissive = 50 },

    -- Stats
    BasicStats = {
        HpHead = 80,  
        WalkSpeed = 300,   -- 150
        SprintSpeed = 300, -- 150
        MeleeDamage = 20, 
        MeleeAttackRange = 250,
    },
    HardMode = {
        BasicStats = { HpHead=180, MeleeDamage=50, SprintSpeed=400, MeleeAttackRange=500 },
        TimeDilation = 1.7,
    },
    TimeDilation = 1.5,
    Stats = function(actor, opts)
        AVU.LockTaming(actor)   -- bespoke variant, no pet form -> not pheromone-tameable
        H.VolatileBaseSetup(actor)

        local move = actor.CharacterMovement
        if IsNotValid(move) then return end

        -- High gravity + a normal leap = a fast, LOW lunge (barely leaves the ground).
        move:SetGravityDirection(FVector(0, 0, -1))
        move.GravityScale = 4
        H.ScaleLeap(actor, 1.0)

        -- Sees far so it can pick a target across the room and rush it (Signal trait).
        AVU.SetSightSense(actor, 5000, 5000, 360)
    end,

    -- Triggers
    -- Fracture is unconditional (not a roll) because it only ever lands one hit; then the
    -- shared mark -> die -> lure.
    OnDealtDamage = function(attacker, victim)
        H.FractureBothLegs(victim)
        H.SignalHitPack(attacker, victim)
    end,

    OnDeath = H.SignalNoise,

    OnGibbed = function(actor)
        AVU.DropLoot(actor, {
            { Row = G.SCRAP_BIO, Amount = 4 },
            { Row = G.DISTILLATION_FLESHY, Amount = 6 },
        })
    end,
}


-- =======================================================================
-- ANTERAZOR PEST
-- Razor Pest with Antegrav mechanics
--   * Every hit bleeds: 90% bleed / 10% heavy bleed (hard 67 / 33), each halved by Thick Skinned
--   * [HARD] - +stats. One side hop before the dive, then the Razor's post-leap pause
-- =======================================================================

local ANTERAZOR_BLEED = {
    Normal = { Bleed = 90, Severe = 10 },
    Hard   = { Bleed = 67, Severe = 33 },
}

-- The Razor evade with a stronger follow-up lunge: its 1.5 gravity flattens the shared arc into a
-- ~2m skid. ~25 degree launch at 1.2x speed = up to ~10m of reach.
local ANTERAZOR_EVADE = { MinDist = 200, MaxLegs = 2, DiveLiftDeg = 12, DiveMult = 1 }

V["Anterazor Pest"] = {
    Id = 89,
    Base = "Pest",
    Assets = { ENUMS.Components.SM_QUILL, ENUMS.BuffObjects.Bleeding, ENUMS.BuffObjects.SevereBleeding },

    -- Appearance
    -- Actor scale = capsule + mesh, so the bigger body is a bigger hitbox.
    BodyScale = { X = 1.1, Y = 1.1, Z = 1.2 },
    Tint = { Color = FVector(0.1, 0.2, 0.3), EmissiveColor = FVector(0.1, 0.2, 1), Emissive = 200 },
    Visuals = function(actor, assets)
        H.AttachQuillRow(actor, FVector(0.4, 0, 1))
    end,

    -- Stats
    BasicStats = {
        HpHead = 70,   -- 25
        WalkSpeed = 200,
        SprintSpeed = 300,
        MeleeDamage = 25,
        -- RangedDamage = 15,
        MeleeAttackRange = 1000,
    },
    DebuffsImmune = { ENUMS.Debuffs.Netted, ENUMS.Debuffs.NettedCannon, ENUMS.Debuffs.Bleeding,
                      ENUMS.Debuffs.Fear },
    TimeDilation = 1.5,

    HardMode = {
        BasicStats = { HpHead=90, MeleeDamage=50, SprintSpeed=400, MeleeAttackRange=1500 },
        TimeDilation = 1.7,
    },

    Stats = function(actor, opts)
        AVU.LockTaming(actor)   -- not tameable

        local move = actor.CharacterMovement
        if IsNotValid(move) then return end

        move.MaxAcceleration = move.MaxAcceleration * 0.6
        move:SetGravityDirection(FVector(0, 0, -1))
        move.GravityScale = 1.5
        H.ScaleLeap(actor, 0.8)

        AVU.CeilingProbeSpawn(actor)

        -- Big sight radius or it never aggros while on the ceiling (Antegrav)
        AVU.SetSightSense(actor, 3000, 3000, 360)
    end,

    -- Triggers
    -- [HARD] RecoverTick drives the post-leap pause; without it the tree re-leaps on landing.
    OnTick = function(actor, totalTicks)
        if STATE.HardModeNoMercy then H.RecoverTick(actor) end
        return AVU.PeriodicGravFlip(actor, totalTicks)
    end,

    -- [HARD] the Razor evade: past 2m, one side hop before the dive, then the pause. No coil
    -- fallback - the Anterazor's normal leap is native, so off-hard this handler is a no-op.
    OnLeapWindup = function(actor)
        if not STATE.HardModeNoMercy then return end
        H.RecoverArm(actor)
        H.ZigLeap(actor, ANTERAZOR_EVADE)
    end,

    OnDealtDamage = function(attacker, victim)
        H.RazorBleed(victim, STATE.HardModeNoMercy and ANTERAZOR_BLEED.Hard or ANTERAZOR_BLEED.Normal)
    end,

    -- Corpse shouldn't stick to the ceiling (Antegrav)
    OnDeath = function(actor)
        AVU.RestoreGravity(actor)
    end,

    OnGibbed = function(actor)
        AVU.DropLoot(actor, { Row = G.QUILL, Amount = 2 })
    end,
}


-- =======================================================================
-- SHIELD PEST  (Base Pest)
-- A pest behind an absorb shield, currently used by the Neophyte Trainer as a summon.
--   * Built on the plain Pest base on purpose: the game's NPC_Monster_ShieldPest class is
--     incomplete and complicates taming, so we roll our own shell + pool
--   * TAMEABLE, and keeping it that way takes one extra line - the absorb shield otherwise makes
--     it immune to the pheromone flask (see AVU.ClearShieldAbsorbLatch for the native why)
-- =======================================================================

local SHIELD_PEST_HP    = 150   -- the absorb pool (separate from its 50 head HP)
local SHIELD_PEST_REGEN = 5     -- per second, out of combat

V["Shield Pest"] = {
    Id = 92,
    Base = "Pest",
    Assets = H.SHIELD_PEST_ASSETS,
    TamedVariant = "Tamed Shield Pest",   -- its PET form (ModulePets/TamedPests)

    -- Appearance
    Tint = { Color = FVector(2, 0.5, 2), EmissiveColor = FVector(0.4, 0.2, 0.4), Emissive = 70 },
    Visuals = function(actor, assets)
        H.ShieldPestGear(actor, { Color = FVector(0.8, 0.3, 1) })   -- the energy shell
    end,

    -- Stats
    BasicStats = {
        HpHead = 50,   -- 25 (head-only pest); the shield pool is the rest of its staying power
        -- WalkSpeed = 150,
        -- SprintSpeed = 150,
        MeleeDamage = 60, --35
        -- RangedDamage = 15,
        -- Shield = 150 (added; a plain Pest has none)
    },
    HardMode = {
        SprintSpeed = 250,
        MeleeDamage = 90,
    },
    DebuffsImmune = { ENUMS.Debuffs.Netted, ENUMS.Debuffs.NettedCannon, ENUMS.Debuffs.Bleeding },

    -- Triggers
    -- [AUTHORITY] The absorb layer lives in OnReady (dedicated too) - gameplay, not cosmetics.
    OnReady = function(actor, assets)
        H.ShieldPestShield(actor, { Max = SHIELD_PEST_HP, Regen = SHIELD_PEST_REGEN })
    end,

    -- KEEP IT TAMEABLE. An absorbed hit latches BodyShieldAbsorbedLastHit, and a buff-carrying
    -- projectile's AoE loop skips any target that flag is set on - so once you shoot this pest, the
    -- pheromone flask stops working on it for good. Un-stick it after every hit.
    OnDamageTaken = function(actor)
        AVU.ClearShieldAbsorbLatch(actor)
    end,
}

return V
