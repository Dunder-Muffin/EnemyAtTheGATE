-- =======================================================================
-- Clericus (NPC_Clericus)
--
-- MUST-KNOWS
--   * The parry is NATIVE and there is NO shield: `IsShieldBlocking` (+ MarkReplicatedDirty) is
--     the whole arming lever, the empty OverrideProjectileBlock stub is our hook.
--   * PROJECTILES ONLY, in a +/-60 deg front arc - NPC_Base_ParentBP's ProcessDamage never reads
--     the flag, so hitscan/lasers/melee land normally.
--   * The MeleeAttacks map is EMPTY, which stalls a melee tree after ONE swing. Helpers.MeleeSwing
--     supplies the montage AND the BT release it owed.
--   * Montages must be LabRat clips - AnimBP_Clericus is DefaultSlot + DeathSlot only, and an
--     off-graph slot plays silently.
--   * The stock BT only flees, so OnReady swaps in the LabRat garage tree.
--
-- ABILITY MAP - NPC_Clericus (row "Clericus")
--   Bare reskin of NPC_Base_ParentBP: no ability slots (0-3 are empty parent stubs), no ranged
--   attack, no melee montages.
--
-- Machinery: AnteNPCs/OrderClericusHelpers.lua   Decode notes: scripts/AnNotes/AnteNPCs/OrderClericus.md
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local ENUMS = require("AnteData.Enums")
local AVU = require("AnteUtils.AVUtils")
local H = require("AnteNPCs.OrderClericusHelpers")
local G = require("AnteData.Items").Global

local V = {}


-- =======================================================================
-- SALII
-- * Deep-blue-robed swordsman that parries projectiles out of the air and sends them back
-- * The deflected shot is re-owned, so it damages whoever fired it
-- * Except a player's item shot (thrown weapon, bolt, disc): it flies back past them and drops its item
-- * Parry drops for 2s after each deflect, and while dead/DBNO
-- * No cower: its ~2s scientist aggro/startle reaction is deleted, so it engages immediately
-- * Don't read every flourish as a parry - the swing and the deflect share one montage
-- =======================================================================

local GARAGE_BT = "/Game/Blueprints/AI/LabRat/BT_Main_LabRat_Garage.BT_Main_LabRat_Garage"
local SALII_ROBE = FVector(0.05, 0.05, 0.25)

V["Salii"] = {
    Id = 140,
    Base = "Clericus",
    NoAggroAnim = true,

    Assets = {
        ENUMS.Components.SM_SWORD,
        ENUMS.Anims.LABRAT_MELEE,
        ENUMS.SOUNDS.SABER_DEFLECT,
        ENUMS.DamageType.Sharp,
    },

    -- Appearance
    -- Robe slot only; the face, legs and hands are their own slots and stay stock.
    Tint = { Components = { Mesh = { Slot = "M_ORD_Clericus", Color = SALII_ROBE } } },
    Visuals = function(actor, assets)
        AVU.AttachStaticMesh(actor, ENUMS.Components.SM_SWORD, "r_hand", {
            Location = FVector(0, 0, 0),
            Rotation = FRotator(0, 0, 0),
            Scale = FVector(1.2, 1.2, 1.3),
        })
    end,

    -- Stats
    BasicStats = {
        HpHead = 150,        -- 50
        HpTorso = 225,       -- 100
        -- WalkSpeed = 300,
        SprintSpeed = 500,   -- 600
        MeleeDamage = 60,    -- 15
        -- RangedDamage = 15,   (no ranged attack; the row value is dead data)
        MeleeAttackRange = 200
    },
    HardMode = {
        BasicStats = { HpHead = 200, HpTorso = 250, SprintSpeed = 575 }
    },
    TimeDilation = 1.2,

    -- Triggers
    -- Runs after the controller has possessed and started the stock tree, so the swap is clean.
    OnReady = function(actor)
        H.ArmParry(actor)
        AVU.RunBehaviorTree(actor, GARAGE_BT)

        -- No built in damage type
        AVU.ChangeDamageType(actor, ENUMS.DamageType.Sharp, true)
    end,

    -- re-assert: brings the parry back after its cooldown, drops it while dead/DBNO.
    OnTick = function(actor, totalTicks)
        if totalTicks % 5 ~= 0 then return end
        H.ArmParry(actor)
    end,

    -- Fires every swing, hit or miss (the multicast runs before the hit test).
    OnMeleeSwing = H.MeleeSwing,
    OnProjectileBlocked = H.Deflect,
    
    OnDeath = function(actor)
        AVU.DropLoot(actor, { Pool = {
            { G.SCRAP_SILVER, 2 },
        } })
    end,
}

return V
