-- =======================================================================
-- OrderRook
-- 
--   * ProcessDamage blocks damage of any type when HitComponent == Shield
--       - Radial ignores this
--       - Can swap/scale mesh which affects how much the shield helps
--   * When its health drops below 60%, it gains AI_TurtleMode buff
--       - Buff is reapplied everytime its damaged
--       - Can't be made immune to self-applied buffs
--   * (?) MeleeAttack_OnCooldown [TO CHANGE] - I thought cooldown didn't increase its attack frequency, if we have to manually reset it something like * Native attack speed by setting MeleeAttack_OnCooldown by hand
-- 
-- =======================================================================
-- ABILITY MAP - Trooper_Shield (NPC_OrderGrunt_Shield < NPC_Groupe_Shield < NPC_Soldier_Grunt)
--   1 GRENADE - unreachable
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local ENUMS = require("AnteData.Enums")
local G = require("AnteData.Items").Global
local AVU = require("AnteUtils.AVUtils")
local H = require("AnteNPCs.OrderRookHelpers")

local V = {}


-- =======================================================================
-- SHIELD GRUNT
--   * Native loot is suppressed and replaced - the Opprimo table hands out a guaranteed Riot
--     Shield and Sensor, which is far too much for a common body
-- =======================================================================

V["Shield Grunt"] = {
    Id = 124,
    Base = "Trooper_Shield",
    NoAggroAnim = true,
    Assets = {},

    -- Appearance
    Tint = { Color = FVector(2, 0.7, 0.3) },

    -- Stats
    BasicStats = {
        HpHead = 120,        -- 150
        HpTorso = 150,       -- 200
        -- WalkSpeed = ,     --?
        -- SprintSpeed = ,   --?
        MeleeDamage = 60,    -- 75
        -- MeleeAttackRange = , --?
    },
    HardMode = { BasicStats = { HpHead = 200, HpTorso = 200, MeleeDamage = 100 } },

    Stats = function(actor)
        AVU.ClearLoot(actor, true)   -- preserveGib: a gib kill still pays its trooper salvage
    end,

    OnDeath = function(actor)
        AVU.DropLoot(actor, { Pool = {
            { G.METAL_SCRAP, 3 },
            { G.REBAR, 2 },
        } })
    end,
}


-- =======================================================================
-- SHIELD EMBOLON
-- A more aggressive Rook with a Lodespear
--   * Has 3 phases in combat - GUARD/PRESS/AGGRO (stances)
--       > GUARD - normal defensive behavior in turtle mode
--       > PRESS - turtle mode but moves to attack
--       > AGGRO - tries to melee, faster attack speed
-- =======================================================================

V["Shield Embolon"] = {
    Id = 136,
    Base = "Trooper_Shield",
    NoAggroAnim = true,

    -- Its weapon applies Debuff_Ignited_Holy
    Assets = { ENUMS.DamageType.FireHoly, ENUMS.BuffObjects.IgnitedHoly, ENUMS.BuffObjects.HPDamage,
               ENUMS.Components.SM_SPEAR_LODE, ENUMS.Components.SM_BANNER_HANGING,
               ENUMS.Components.M_BANNER_ORDER, ENUMS.Components.M_GLASS_LENS_GOLD },

    -- Appearance
    Tint = { Color = FVector(8, 4, 0.3) },
    Visuals = H.EmbVisuals,

    -- Stats
    BasicStats = {
        HpHead = 150,        -- 150
        HpTorso = 200,       -- 200
        WalkSpeed = 300,     -- 200 (Phase changes overwrite these)
        SprintSpeed = 300,   -- 350
        MeleeDamage = 100,    -- 75 (1s melee speed, 2-2.5s bash speed)
        MeleeAttackRange = 250, --300
    },
    HardMode = { BasicStats = { HpHead = 250, HpTorso = 250, MeleeDamage = 150 } },

    Stats = function(actor)
        -- Replaced knife with a Lodespear
        AVU.ChangeDamageType(actor, ENUMS.DamageType.FireHoly, true)
    end,

    -- Triggers
    OnReady = H.EmbReady,
    OnMeleeSwing = H.EmbSwing,
    OnTick = H.EmbTick,
    OnDealtDamage = H.EmbShove,

    OnDeath = function(actor)
        AVU.DropLoot(actor, { Pool = {
            { G.SCRAP_KEVLAR, 2 },
            { G.TACTICAL_SCRAP, 1 },
            { G.MILITARY_ELEC },
            { G.MONEY },
        } })
    end,
}


return V
