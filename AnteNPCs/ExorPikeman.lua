-- =======================================================================
-- Exor Pikeman variants - a SOUL-BONDED PAIR. (Def schema: AnteNPCs/Pest.lua.)
-- Base-class decode + bond mechanics: see AnNotes/AnteNPCs/ExorPikeman.md.
--
-- MUST-KNOWS:
--   * Pikeman family uses the "_Cha" beam FX set (EXOR_BEAM_CHA / EXOR_CHARGEUP_CHA), not plain Exor.
--   * FX ride NetMulticasts or the client-FX channel. A multicast FindObject's its Niagara
--     (non-loading), so a non-resident system silently spawns nothing - keep PAIR_FX complete.
--   * Spawns go through AVU.SummonVariant (off-hook).
--
-- To test (neither has a wild spawner): /spawn Exor Spiritwalker, then aggro it - the Wraith arrives.
--
-- ABILITY MAP - two bases in this file, slots differ per variant. Slots 0-2 unused on both.
--
-- PIKEMAN (row "Exor_Pikeman") -> Sentinel
--   3 PIKE_ABILITY_TELEPORT - blink to target +100 Z. Cooldown_CombatAbility3 forced 0, BT
--       alone paces it. AVU.DisableAbility(actor, 3) pins it off.
-- ALLY (row "Exor_Pikeman_Ally") -> Wraith
--   3 - native no-op (Broadcast_CombatAbility3 is just EndAbility_DoCombatReset(false)). BT
--       still fires the slot but the Wraith never teleports natively.
--
-- Not slots (shared): the charged psychic beam is the RANGED attack. The spear body-check is a
-- collision-sphere overlap (launch + 22 sharp dmg, 0.65s re-arm). Squad ENRAGE
-- (Squad_MemberDead -> NPCEnraged) halves every windup and skips the ranged cooldown entirely.
--
-- Machinery: AnteNPCs/ExorPikemanHelpers.lua
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local ENUMS = require("AnteData.Enums")
local G = require("AnteData.Items").Global
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local H = require("AnteNPCs.ExorPikemanHelpers")

local V = {}

-- Every Niagara any multicast below FindObject's, preloaded via both variants' Assets.
-- EXOR_BLINK_CHA is the Sentinel's own native teleport ability, not the transpose.
local PAIR_FX = {
    ENUMS.Effects.EXOR_BEAM_CHA, ENUMS.Effects.EXOR_SHOCKWAVE_CHA,
    ENUMS.Effects.EXOR_SHOCKWAVE, ENUMS.Effects.EXOR_CHARGEUP_CHA, ENUMS.Effects.EXOR_BLINK_CHA,
    ENUMS.Effects.LIGHTNING_ELECTRICDAM, ENUMS.Effects.PORTAL_RIFT_BLUEFADE,
}

-- Spear appearance
local SPEAR_CYAN = {
    Color = FVector(0.2, 1.6, 3), DiffuseColor = FVector(0.2, 1.6, 3),
    EmissiveColor = FVector(0, 1.2, 2.5), Emissive = 25,
}
local SPEAR_CRIMSON = {
    Color = FVector(3, 0.15, 0.2), DiffuseColor = FVector(3, 0.15, 0.2),
    EmissiveColor = FVector(2.5, 0, 0.15), Emissive = 25,
}


-- =======================================================================
-- EXOR SPIRITWALKER  (Id 86, base "Exor_Pikeman")  - the energy-immune body half
--   * [AUTHORITY] Beam suppressed (see Stats) -> spear + teleport bruiser, lower damage.
--   * Calls its bonded Wraith on entering combat; either death kills both.
--   * Owns the transpose swap timer (one side drives it so the pair can't double-swap).
-- =======================================================================

V["Exor Spiritwalker"] = {
    Id = 86,
    Base = "Exor_Pikeman",
    Assets = PAIR_FX,

    -- Appearance
    BodyScale = 1.1,   -- actor scale (capsule + mesh), so the bigger body is a bigger hitbox
    Tint = {
        Color = FVector(3, 0.5, 0.5), EmissiveColor = FVector(0, 1, 2), Emissive = 40,
        Components = { Spear_Hand = SPEAR_CYAN },
    },

    -- Stats
    BasicStats = {
        HpHead = 400,   -- 600
        HpTorso = 600,  -- 500
        -- HpLeftArm = 325, HpRightArm = 325, HpLeftLeg = 325, HpRightLeg = 325,
        WalkSpeed = 150,   -- 180 (a little slower)
        SprintSpeed = 470, -- 570
        MeleeDamage = 60,  -- ?
        HasRangedAttack = false,   -- primary beam suppressor: the BT shouldn't pick the ranged branch
    },

    HardMode = {
        BasicStats = { HpHead = 500, HpTorso = 700, MeleeDamage = 80 },
    },

    Stats = function(actor, opts)
        -- Direct spear-collision knockback hit (separate from NPCData.MeleeDamage).
        pcall(function() actor.SpearCollisionDamage = 15 end)   -- 22

        -- BEAM SUPPRESSION, three layers (HasRangedAttack=false above only gates the BT's ranged
        -- branch - it doesn't stop a loop already in flight):
        --   * RangedAttack_OnCooldown=true holds the loop. Native only clears it after firing, so
        --     a manual true STICKS - re-assert it each tick (H.SpiritwalkerTick).
        --   * RadialForce.Radius=0: any beam that slips through hits nobody.
        --   * A long RangedAttack_Cooldown starves the branch even if picked.
        pcall(function() actor.RangedAttack_OnCooldown = true end)
        pcall(function()
            if IsValid(actor.RadialForce) then actor.RadialForce.Radius = 0 end
        end)
        pcall(function() actor.RangedAttack_Cooldown = 30 end)   -- 2
    end,

    -- Triggers
    OnTick = H.SpiritwalkerTick,
    OnDamageTaken = H.SpiritwalkerDamageTaken,
    OnEnterCombat = H.SpiritwalkerEnterCombat,

    OnDeath = function(actor)
        if Utils.IsActorInvalid(actor) then return end
        H.KillPartner(actor)
        AVU.DropLoot(actor, {
            { Row = G.TRANSCENDIUM, Amount = 1 },
        })
    end,
}


-- =======================================================================
-- EXOR WRAITH  (Id 87, base "Exor_Pikeman_Ally")  - the physical-immune caster half
--   * [AUTHORITY] Immune to physical, weak to holy. Native teleport already neutered by its own BP.
--   * No melee (spear damage zeroed + melee montages held on cooldown): a pure caster.
--   * One beam per channel: slow windup, cast often. Native beam neutralized (RadialForce=0);
--     our scripted beam is the real hit. OnWindupAttack resolves via the parent Pikeman's
--     Broadcast_WindupAttack (the Ally doesn't override it) and is filtered by variant name.
--   * The aim point locks and telegraphs before the beam lands, so stepping off it dodges.
--   * No gib path on its BP: drops loot and rifts away on death instead (H.WraithVanish).
-- =======================================================================

local WRAITH_WINDUP_S   = 2.8    -- slow, telegraphed channel (native 2)
local WRAITH_COOLDOWN_S = 0.75   -- ...but it casts again quickly (native 2)

V["Exor Wraith"] = {
    Id = 87,
    Base = "Exor_Pikeman_Ally",
    Assets = PAIR_FX,

    -- Appearance
    BodyScale = 1.0,
    Tint = {
        Color = FVector(0.5, 0.9, 1.0), EmissiveColor = FVector(4, 0.5, 1), Emissive = 120,
        Components = { Spear_Hand = SPEAR_CRIMSON },
    },

    -- Stats
    BasicStats = {
        HpHead = 400,   -- 700
        HpTorso = 600,  -- 400
        -- HpLeftArm = 175, HpRightArm = 175, HpLeftLeg = 175, HpRightLeg = 175,
        WalkSpeed = 150,   -- 180 (less mobile)
        SprintSpeed = 450, -- 570
        MeleeDamage = 0,   -- caster
    },

    HardMode = {
        BasicStats = { HpHead = 500, HpTorso = 700 },
    },

    Stats = function(actor, opts)
        -- Zero the native beam's blast radius: kills its damage, keeps the windup/visual. Our own
        -- scripted beam (own radius) is the real attack.
        pcall(function()
            if IsValid(actor.RadialForce) then actor.RadialForce.Radius = 0 end
        end)
        -- The spear overlap deals SpearCollisionDamage on CONTACT, independent of the melee
        -- cooldown - so zero it too, or the "no melee" caster still stabs whatever it touches.
        pcall(function() actor.SpearCollisionDamage = 0 end)
        pcall(function() actor.AttackWindupTime = WRAITH_WINDUP_S end)
        pcall(function() actor.RangedAttack_Cooldown = WRAITH_COOLDOWN_S end)
    end,

    -- Triggers
    -- Hold the melee montages on cooldown (AVU.SuppressMelee re-arms MeleeAttack_OnCooldown; it
    -- lapses, so re-apply ~1s). Pairs with SpearCollisionDamage=0 above.
    OnTick = function(actor, totalTicks)
        if Utils.IsActorInvalid(actor) then return "REMOVE" end
        if totalTicks % 10 ~= 0 then return end
        if actor.IsDead then return end
        AVU.SuppressMelee(actor)
    end,

    OnDamageTaken = H.WraithDamageTaken,
    OnWindupAttack = H.WraithWindup,

    -- No OnGibbed (no gib path on this BP - it could never fire): drop here, then rift the body away.
    OnDeath = function(actor)
        if Utils.IsActorInvalid(actor) then return end
        H.KillPartner(actor)

        H.WraithVanish(actor)
    end,
}

return V
