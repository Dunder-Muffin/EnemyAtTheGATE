-- =======================================================================
-- Order Captain variants (base "Grunt_Captain" = NPC_Soldier_Captain)
--
-- ABILITY MAP - NPC_Soldier_Captain (row "Grunt_Captain", extends NPC_Soldier_Grunt)
--   0 Idle - none
--   1 GRENADE - inherited UNCHANGED from the Grunt (projectile_fraggrenade, 10s CD, LoS-gated,
--       applies the 4s squad-wide AI_Cooldown_AllyGrenade on use). There is no captain-specific
--       controller, so CanThrowGrenades stays true - captains DO throw.
--       AVU.DisableGrenades(actor) == AVU.DisableAbility(actor, 1).
--   2 - EMPTY      3 - EMPTY   (free to claim)
--   NOT a slot: the magnum pattern is the ranged path (Grunt_FireBurst: 1 shot, 0.35s gap, then up
--   to 3 follow-ups each on a 50% coin flip; MaxAmmoCount 6).
--
-- Machinery: AnteNPCs/OrderCaptainHelpers.lua   (ported/adapted from AnteUp1 AUOrderCaptain)
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local ENUMS = require("AnteData.Enums")
local G = require("AnteData.Items").Global
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local H = require("AnteNPCs.OrderCaptainHelpers")

local V = {}


-- =======================================================================
-- COMMANDER
-- Stationary backline officer that anchors a defensive squad instead of fighting.
--   * Drops a cement-bag barricade + radios on spawn.
--   * Calls in ONE reinforcement at a time, re-summoned when it dies, up to 3 in its life.
--   * Watches a wide arc out to 35m - it is the squad's eyes, not its rifle.
--   * No melee, no grenades - it summons instead.
--   * [HARD] opens the fight with a call-in, then keeps 2 standing, up to 4 in its life.
-- =======================================================================

-- A SensesConfig write blinds the body ~10s and can deregister perception mid-drain, hence the
-- delay (AnNotes/AnteSystems/NPCPerception.md).
local COMMANDER_SIGHT = { Degrees = 270, Radius = 3500, DelayMs = 4000 }

V["Commander"] = {
    Id = 31,
    Base = "Grunt_Captain",
    Assets = H.COMMANDER_ASSETS,   -- barricade + radio deployables, call-in montage

    -- Appearance
    Tint = {
        Color = FVector(6, 3, 4), EmissiveColor = FVector(0, 0.5, 2), Emissive = 15,
        Components = { Helmet = { Color = FVector(0.1, 0.2, 2) } },   -- blue beret, not the body's red
    },

    -- Stats
    BasicStats = {
        -- HpHead = 150,
        -- HpTorso = 200,
        WalkSpeed = 0, -- 130
        SprintSpeed = 0,   -- 500 
        -- MeleeDamage = 50,
        -- RangedDamage = 50,
        MeleeAttackRange = 1,   -- 150; zeroed for good, or it swings at its own sandbags
    },
    HardMode = { NoAggroAnim = true, BasicStats = { HpHead = 200, HpTorso = 250, RangedDamage = 70 } },
    Stats = function(actor, opts)
        AVU.DisableGrenades(actor)   -- it summons instead

        AVU.SetSightConfig(actor, COMMANDER_SIGHT)
    end,

    -- Triggers
    OnReady = H.CommanderDeploy,
    OnTick = H.CommanderTick,
    OnEnterCombat = H.CommanderAggro,   -- [HARD] the opening call-in
    OnDeath = H.CommanderDeath,
}


-- =======================================================================
-- TRIDENT
-- Net-launcher officer: one net per magazine, then it empties the magnum into whatever it stuck.
--   * The net is a REAL projectile - the engine decides the hit, so cover and corners stop it and
--     nothing else does. A clean hit is a 2.5s full stun, on players AND NPCs, and no damage.
--   * Its magazine IS its rhythm: net -> magnum burst -> reload -> net. Quick reloads.
--   * Combat-rolls when hit. Immune to nets itself.
--   * Tint + bare head: no "green beret" asset exists (only chef hats / hardhats).
-- =======================================================================

-- 5 rounds: the net burns one, the Captain's native burst (2 shots + up to 3 coin-flipped
-- follow-ups, all bytecode - GruntBurstCount is inert on this base) spends the rest, then the BT
-- reloads and the next full magazine re-arms the net.
local TRIDENT_AMMO        = 5

V["Trident"] = {
    Id = 43,
    Base = "Grunt_Captain",
    NoAggroAnim = true,
    Assets = H.TRIDENT_ASSETS,   -- net gun + net class + its debuff/damagetype, reload + dodge anims

    -- Appearance
    Tint = {
        Color = FVector(0.6, 0.4, 0.2), EmissiveColor = FVector(1, 0, 1), Emissive = 15,
        Components = { Helmet = { Color = FVector(0.1, 1.5, 0.2) } },   -- green beret, not the body wash
    },
    Visuals = H.TridentGear,   -- magnum hidden, pistol-sized net launcher in its place

    -- Stats
    BasicStats = {
        -- HpHead = 150,
        -- HpTorso = 200,
        -- WalkSpeed = 130,
        SprintSpeed = 450,   -- 500 (mobile vs the stationary Commander)
        -- MeleeDamage = 50,
        -- RangedDamage = 50,
    },
    -- Reload retime lives in H.TridentReload - Stats-side writes beat BasicStats.
    HardMode = { BasicStats = { HpHead = 200, HpTorso = 250, SprintSpeed = 500, RangedDamage = 80 } },
    DebuffsImmune = { ENUMS.Debuffs.Netted, ENUMS.Debuffs.NettedCannon },
    TimeDilation = 1.2,
    MirrorTimeDilation = true,
    Stats = function(actor, opts)
        actor.CurrentAmmoCount = TRIDENT_AMMO
        actor.MaxAmmoCount = TRIDENT_AMMO

        AVU.DisableGrenades(actor)
        H.TridentArmNet(actor)   -- first magazine owes a net; every later one is armed by OnReload
    end,

    -- Triggers
    -- No OnTick: the net rides the gun's own firing cycle now, so the BT paces it.
    OnRangedAttack = H.TridentRangedAttack,

    OnReload = H.TridentReload,   -- retimes the reload and rearms the net

    OnDamageTaken = H.TridentDodge,

    OnDeath = function(actor)
        H.TridentDeath(actor)
        AVU.DropLoot(actor, { Pool = {
            { G.STEELCABLE, 1 },
            { G.MONEY_STACK, 1 },
        } })
    end,
}


-- =======================================================================
-- SIGNIFER
-- Backpedaling standard-bearer: banner pole on its back, Preacher helm for a cap.
--   * KEEPS its magnum and fires while kiting to a 15-25m LoS band around the closest player.
--   * Radios in rope-rappelling Tiro Troopers (max 2 alive) to fight for it, but only while a
--     player is inside 15m - it calls from the near edge of its own kite band.
--   * No melee, no grenades - it summons instead.
-- =======================================================================

V["Signifer"] = {
    Id = 137,
    Base = "Grunt_Captain",
    NoAggroAnim = true,
    Assets = H.SIGNIFER_ASSETS,   -- call-in montage, banner pole + cloth, Preacher helm

    -- Appearance
    Tint = { Color = FVector(0.25, 0.18, 0), EmissiveColor = FVector(7, 0, 0.25), Emissive = 3 },
    Visuals = function(actor, assets)
        H.SigniferDress(actor)
    end,

    -- Stats
    BasicStats = {
        HpHead = 300,           -- 150
        HpTorso = 300,          -- 200
        WalkSpeed = 100,        -- 130
        SprintSpeed = 350,      -- 500
        -- MeleeDamage = 50,
        RangedDamage = 70,     -- 50
        MeleeAttackRange = 1,   -- 150; suppressed via AVU.SuppressMelee too
    },
    HardMode = { BasicStats = { HpHead = 350, HpTorso = 400, SprintSpeed = 450, RangedDamage = 100 } },
    Stats = function(actor, opts)
        pcall(function() actor.CanLoseHelmet = false end)   -- keep the Preacher helm from popping off
        AVU.DisableGrenades(actor)   -- it summons instead
        AVU.SetCanCrouch(actor, false)   -- stop crouch-idle foot-slide
    end,

    -- Triggers
    OnTick = H.SigniferTick,

    OnDeath = function(actor)
        AVU.DropLoot(actor, { Pool = {
            { G.TACTICAL_SCRAP, 2, MinStory=81 },
            { G.AMMO_357, 4 },
        } })
    end,
}


-- =======================================================================
-- TIRO TROOPER  (Signifier reinforcement)
-- Weak, slow gold/black Shock Trooper with a red visor
--   * Base "Trooper_Shotgun" (< Groupe_Shotgunner < Grunt_Shotgun < NPC_Soldier_Grunt): the
--     rope-spawn machinery is inherited from Soldier_Grunt, so RopeSpawn works as on "Trooper".
--   * 10-pellet instant shotgun blast, with a clean AdjustRangedAccuracy passthrough if we ever
--     want to widen the spread.
--   * HealthTextures = {} so the gold wash is never overwritten.
--   * Ability map for this base: AnteNPCs/OrderGrunt.lua.
-- =======================================================================

local TIRO_BLACK = FVector(0.08, 0.08, 0.08)   -- helmet (the black accent)

V["Tiro Trooper"] = {
    Id = 138,
    Base = "Trooper_Shotgun",
    NoAggroAnim = true,
    RopeSpawn = true,   -- native fast-rope spawn-in (NpcSpawner re-enables the gates pre-BeginPlay)
    Assets = { ENUMS.Components.M_GLASS_LENS_RED },

    -- Appearance
    Tint = { Color = FVector(0.15, 0.05, 0) },
    Visuals = function(actor, assets)
        -- no gun tint
        AVU.SetHelmet(actor, { Color = TIRO_BLACK, LensMaterial = ENUMS.Components.M_GLASS_LENS_RED })
    end,

    -- Stats (base "Trooper_Shotgun": the trio's slow tank-ish shotgunner)
    BasicStats = {
        HpHead = 200,       -- 100
        HpTorso = 150,      -- 150
        WalkSpeed = 130,
        SprintSpeed = 130,  -- 160
        -- MeleeDamage = 50,
        RangedDamage = 20,  -- 25x10
    },
    HardMode = { BasicStats = { HpHead = 300, HpTorso = 200, SprintSpeed = 200 } },

    -- Triggers
    OnReady = function(actor)
        AVU.ClearLoot(actor)   -- conscripts drop nothing (covers the gib path too)
    end,
}

return V
