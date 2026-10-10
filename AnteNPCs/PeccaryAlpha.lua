-- =======================================================================
-- Peccary Alpha variants (base "Peccary_Alpha" = NPC_Peccary_Alpha).
-- Near-empty reskin of NPC_Monster_Peccary (row name, red material, 1.5x mesh, bigger capsule) -
-- every ability/stat/FX is inherited, so it charges and plants Carbuncles via the same fields.
--   * HAND-PLACED mini-boss - no spawner emits it; arrives via /spawn or a scripted placement.
--   * Base row: HP_Head 400 / HP_Torso 60, Walk 200 / Sprint 900, Melee 50, weak to Blunt.
-- Machinery: AnteNPCs/PeccaryHelpers.lua (H.MagmaChargeType/FX, H.MagmaIgnite, H.MagmaRetaliate -
-- the "MAGMA PECCARY (wild)" section there).
-- Deep: AnNotes/AnteNPCs/Peccary.md S4 - native charge field defaults and the re-theme.
-- =======================================================================
-- ABILITY MAP
--   0 PLANT_CARBUNCLE - idle plant, Cooldown_IdleAbility 150s.
--   1 CHARGE - stampede ending in a radial blast; type/FX re-themed via ChargeDamageType /
--       ChargeImpactParticle / ChargeBlastImpactParticle / ChargeLoopParticle (see PeccaryHelpers).
--   2-3 EMPTY
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local ENUMS = require("AnteData.Enums")
local G = require("AnteData.Items").Global
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local H = require("AnteNPCs.PeccaryHelpers")

local V = {}


-- =======================================================================
-- MAGMA PECCARY
-- Living-magma reskin of the Alpha mini-boss.
--   * Immune to Ignited/IgnitedHoly/IgnitedPlasma (it IS fire); still weak to Blunt.
--   * Charge blast + "too hot to handle" retaliation (melee it, it bursts) re-themed to
--     Explosive / players-only Fire - native Fire-on-NPCs re-enters our damage hook in a crowd.
--   * Bite: a chance to ignite the player hit.
-- =======================================================================

-- The idle ability to pin OFF (slot 0 = the base peccary Carbuncle plant; see the ABILITY MAP).
local ABILITY_PLANT_CARBUNCLE = 0

-- The bite's chance to set a struck player alight (H.MagmaIgnite does the actual apply).
local BITE_IGNITE_CHANCE = 0.25
local BITE_IGNITE_SECS   = 4

-- Everything the charge re-theme touches (H.MagmaRetaliate re-loads its own slice right before
-- firing - a preload doesn't stick, CLAUDE.md S3).
local MAGMA_DEPS = {
    -- PECCARY_CHARGE_START is MEASURED, not played, by H.QuickCharge - it only has to be resident
    -- for the length read, and a cold read there just falls back to the native windup.
    ENUMS.Anims.PECCARY_CHARGE_START,
    ENUMS.Effects.FIRE_DRIPPING,           -- spine flame (matches the tamed form)
    ENUMS.Effects.CAMPFIRE_BASIC,          -- the charge windup flame
    ENUMS.Effects.MAGMAPEST_EXPLOSION,     -- the charge blast + the retaliation burst
    ENUMS.DamageType.Explosive,            -- the charge blast's type (non-DoT; see H.MagmaChargeType)
    ENUMS.DamageType.Fire,                 -- the bite/retaliation type + what Ignited's DoT deals (players only)
    ENUMS.BuffObjects.Ignited,             -- Debuff_Ignited's logic object (named by row -> not auto-pulled)
    ENUMS.BuffObjects.HPDamage,            -- its parent class
}

V["Magma Peccary"] = {
    Id = 112,
    Base = "Peccary_Alpha",
    Assets = MAGMA_DEPS,
    -- TAMEABLE (Peccary_Alpha is a DT_Pets base): flask/feed it and PetManager re-mutates it into
    -- the owner-safe pet form (benefit: faster cooking). See ModulePets/TamedPeccary.
    TamedVariant = "Tamed Magma Peccary",

    -- Appearance
    BodyScale = { X = 0.9, Y = 0.6, Z = 0.8 },
    Tint = { Color = FVector(6, 3, 1), Emissive = 3, EmissiveColor = FVector(7, 3, 1) },
    -- [RENDERER] the fire cosmetics
    Visuals = function(actor, assets)
        -- Every renderer re-themes: the multicast FX reads these members LOCALLY at impact, so an
        -- authority-only set would leave clients seeing purple.
        H.MagmaChargeFX(actor)

        -- REDUCE_VISUALS: skip the flame (particles are the priciest cosmetic).
        if not SETTINGS.GAMEPLAY.REDUCE_VISUALS then
            -- Dripping flame on the dorsal quill ridge (matches the tamed form).
            AVU.AttachNiagara(actor, ENUMS.Effects.FIRE_DRIPPING, "Quill8", {
                Location = FVector(-25, 10, 0),
                Scale = FVector(0.6, 0.6, 0.6),
            })
        end
    end,

    -- Stats
    BasicStats = {
        HpHead  = 300,   -- 400
        HpTorso = 300,   -- ?
        -- WalkSpeed = 200,
        SprintSpeed = 600, --900
        MeleeDamage = 60,   -- 50
        -- MeleeAttackRange = 150,
        -- HasRangedAttack = false,
    },
    DebuffsImmune = { ENUMS.Debuffs.Ignited, ENUMS.Debuffs.IgnitedHoly, ENUMS.Debuffs.IgnitedPlasma },
    HardMode = {
        BasicStats = { HpHead = 350, HpTorso = 350, MeleeDamage = 90 }, 
    },
    Stats = function(actor, opts)
        -- NOT LockTaming'd: this variant HAS a pet form (TamedVariant), so it's left tameable.

        -- Stop the idle Carbuncle plant (slot 0) - an actor-count sink that does little.
        -- AVU.DisableAbility pins the ability's cooldown off.
        AVU.DisableAbility(actor, ABILITY_PLANT_CARBUNCLE)

        -- [AUTHORITY] charge blast -> EXPLOSIVE, not Fire (no DoT in a crowd; see H.MagmaChargeType).
        H.MagmaChargeType(actor)
    end,

    -- Triggers
    -- [HARD] Cut the charge telegraph (H.MAGMA_CHARGE). The cooldown is untouched - this is about
    -- how much warning the windup gives, not how often the charge comes.
    OnCharge = H.MagmaPeccaryCharge,

    -- The bite: a chance to ignite the struck PLAYER (never an NPC - its Ignited DoT would re-enter
    -- our damage hook from a timer tick). Re-apply from the charge blast is harmless (BlockedByExisting).
    OnDealtDamage = function(attacker, victim)
        if Utils.IsActorInvalid(victim) then return end
        if IsValid(victim.NPCData) then return end   -- NPC victim -> skip (players only)
        if math.random() >= BITE_IGNITE_CHANCE then return end
        H.MagmaIgnite(victim, BITE_IGNITE_SECS)
    end,

    -- "Too hot to handle": melee it and it bursts, igniting nearby players (H.MagmaRetaliate).
    OnDamageTaken = H.MagmaRetaliate,

    OnDeath = H.MagmaForget,

    OnGibbed = function(actor)
        AVU.DropLoot(actor, { Pool = {
            { G.GEL, 2 },
            { G.PECCARY_LEG_COOKED, 1 },
        } })
    end,
}


return V
