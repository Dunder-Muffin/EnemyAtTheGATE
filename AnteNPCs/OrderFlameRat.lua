-- =======================================================================
-- ORDER - FLAME RATS  (base row "Grunt_FlameRat", class NPC_FlameRat)
-- + THE PURIFIED CELL (Purifier 142 + Purified Grunt/Breacher/Rat 143-145 - grunt/labrat
--   bases, but the FlameRat IS the mechanic, so the cell lives here)
-- + Event Purifier 154 - the same trooper at wave difficulty (see its banner)
--
-- MUST-KNOWS  (class decode: AnNotes/AnteNPCs/OrderFlameRat.md; cell: AnNotes/AnteNPCs/OrderPurified.md;
--              machinery: OrderFlameRatHelpers.lua; event: Event_INQ_PurifiedAssault)
--   * The spray is NOT the projectile: real damage is a SphereTrace from Gun:GetForwardVector(),
--     tuned by three plain actor props - SprayDistance 800, SprayRadius 40,
--     FlamethrowerSprayDamage 5. Type is Fire_Holy; a pitched-down gun floors the lane.
--   * Spray LoS is native (same C++ pair as melee swings) - do NOT add a wall check.
--   * Server_DoRangedAttack is the ONE reliably hookable point on this class. ProcessSprayAttack,
--     the backpack fns and KamikazeRunToTarget go via EX_LocalVirtualFunction, which bypasses
--     UE4SS's ProcessEvent hook entirely (the Tarasque trap).
--   * NEVER fire the weapon from Lua (S6 kill-path deadlock).
--   * NEVER root one (MOVE_None): a rooted NPC that still needs its attack tree HANGS that tree -
--     BT_Main_FlameRat's fire path fails every MoveTo against the soldier 450uu distance floor.
--   * NEVER touch MaxAmmoCount: the reload branch is the only LockedInPlaceMontage setter -
--     the documented FlameRat wedge (what broke the first Cinderlord, since scrapped).
-- =======================================================================
-- ABILITY MAP - NPC_FlameRat (extends NPC_Base_ParentBP directly)
--   0 Idle - none   1/3 - EMPTY
--   2 KAMIKAZE - charge, dive, detonate the backpack
--     (Projectile_Grenade_Nuke_DefenseBot, DamageFromWeapon 800, gibs itself)
--   NOT a slot: the flamethrower (ranged channel) and the BACKPACK WEAK POINT (hits on
--     BackpackHitbox route into BackpackHealth 170; at 0 it enrages, hisses 5s, nukes).
--
-- ABILITY MAP - the Purified cell's other bases:
--   NPC_Soldier_Grunt (row "Grunt") / NPC_Soldier_Grunt_Shotgun (row "Grunt_Shotgun"):
--     0 Idle - none   1 GRENADE (kept native)   2/3 - EMPTY
--   NPC_LabRat_Garage (row "Grunt_LabRat_Mechanic", LabRat family - NOT a Grunt subclass):
--     0 IDLE ENVIRONMENT SCAN (cosmetic, kept)   1/2/3 - EMPTY
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local AVU = require("AnteUtils.AVUtils")
local ENUMS = require("AnteData.Enums")
local G = require("AnteData.Items").Global
local H = require("AnteNPCs.OrderFlameRatHelpers")

local V = {}

local ABILITY_KAMIKAZE = 2


-- =======================================================================
-- EVENT FLAMERAT (Id 141) - the surviving mobile FlameRat. The scripted-burst Cinderlord was
-- SCRAPPED (it wedged on its own reload); this is event use only, via Event_INQ_NightRealm.
--   * Stock statline. Kamikaze off + InvincibleToNPCs, and nothing else.
-- =======================================================================

-- S6 debuff-preload trap: the spray's Ignited_Holy is soft-ref'd BY ROW NAME.
local EFR_ASSETS = {
    ENUMS.BuffObjects.IgnitedHoly,
    ENUMS.BuffObjects.HPDamage,
    ENUMS.DamageType.FireHoly,
}

V["Event FlameRat"] = {
    Id = 141,
    Base = "Grunt_FlameRat",
    HardMode = { NoAggroAnim = true },
    Assets = EFR_ASSETS,

    -- Triggers
    OnReady = function(actor)
        AVU.DisableAbility(actor, ABILITY_KAMIKAZE)
        AVU.SetInvincibleToNPCs(actor, true)
    end,
}


-- =======================================================================
-- THE PURIFIED CELL (Ids 142-145). Machinery: AnteNPCs/OrderFlameRatHelpers.lua;
-- notes: AnNotes/AnteNPCs/OrderPurified.md; the blockade event: Event_INQ_PurifiedAssault.
-- =======================================================================

-- The Breacher's advance-to-melee BT, swapped onto the Purified Grunt (same soldier
-- family/blackboard - the proven Grunt Shade / Suppressor swap).
local BREACHER_BT = "/Game/Blueprints/AI/Soldier/BT_Main_Soldier_Shotgun.BT_Main_Soldier_Shotgun"

-- Shared white/yellow body wash (the LabRat/Sapper-suit read on the dark grunt kit).
local PURIFIED_TINT = { Color = FVector(9, 9, 8), EmissiveColor = FVector(1, 0.85, 0.4), Emissive = 30 }

-- Wards spawn near-empty so the Purifier's hose visibly has a job to do.
local SPAWN_SHIELD_FRAC = 0.25


-- ----- shared by BOTH Purifiers (V["Purifier"] and V["Event Purifier"]) -----
-- Named locals rather than one def reaching into the other's table: the two are the same trooper
-- at two difficulties, and ONLY the numbers should ever diverge. Anything cosmetic or behavioural
-- that lands here is automatically true of both, which is the point.

local PURIFIER_TINT = { Color = FVector(12, 12, 0.8), EmissiveColor = FVector(1, 0, 0), Emissive = 40 }

local function purifierLook(actor, assets)
    pcall(function() AVU.TintComponent(actor.Gun, { Color = FVector(2.2, 2.0, 1.2) }) end)
    H.AttachShell(actor)
end

local function purifierDrops(actor)
    AVU.DropLoot(actor, { Pool = {
        { G.TACTICAL_SCRAP, 3 },
        { G.FLASK_HOLY, 1 },
    } })
end


-- =======================================================================
-- PURIFIER (Id 142, Grunt_FlameRat) - blockade holy-fire support. Yellow-white suit; hoses its
-- own cell, and that holy fire is what keeps their shields charged.
--   * Preacher-style shield: 300 HP, self-regens after 12s (it IS the battery).
--   * Never reloads (ammo pinned); kamikaze disabled. DEAF + ~10m sight so bait one at a time.
--   * 400 HP backpack weak point (native 170). Ignites the nearest Purified ward every 5s combat/7s idle.
--   * Portals in (H.PurifierStats' HideForArrival + OnReady's AVU.PortalArrival) - shared with the
--     Purified Rat and the Sapper rats.
-- =======================================================================

V["Purifier"] = {
    Id = 142,
    Base = "Grunt_FlameRat",
    NoAggroAnim = true,
    Assets = H.PURIFIER_ASSETS,

    -- Appearance
    Tint = PURIFIER_TINT,
    Visuals = purifierLook,

    -- Stats
    BasicStats = {
        HpHead = 600, --1000
        HpTorso = 600, --800
        -- HpBackpack = 400, --200
        WalkSpeed = 100, --130
        SprintSpeed = 150, --220
        -- MeleeDamage = 60,
        RangedDamage = 20, --33
        -- Shield = 300 (added; the FlameRat line has none)
    },
    HardMode = { BasicStats = { HpHead = 800, HpTorso = 800, RangedDamage = 30 } },
    -- Preacher shield (300/12s) + beefed backpack + dialed-down senses (deaf, ~10m sight).
    Stats = function(actor, opts) H.PurifierStats(actor) end,

    -- Triggers
    OnReady = function(actor)
        AVU.DisableAbility(actor, ABILITY_KAMIKAZE)
        AVU.PortalArrival(actor)   -- the rift it walks out of; H.PurifierStats hid it for this
    end,
    -- Ammo pin + anchor re-kick + wedge watchdog + the blessing pass. See the helpers.
    OnTick = H.PurifierTick,
    OnDamageTaken = H.PurifierReleaseAnchor,
    OnDeath = purifierDrops,
}


-- =======================================================================
-- EVENT PURIFIER (Id 154, Grunt_FlameRat) - the Purifier as a WAVE UNIT, not a boss.
--   * Identical to V["Purifier"] (same helpers/OnTick/bait window/drops) - only HP and shield differ.
--   * The cell Purifier's 300-pt self-regen shield is built for solo baiting; a wave fight can't
--     sustain enough holy output to break it before it regens. Dropped to 50 pts + a proper limb
--     spread instead of an all-in-head/torso pool.
-- =======================================================================

V["Event Purifier"] = {
    Id = 154,
    Base = "Grunt_FlameRat",
    HardMode = { NoAggroAnim = true },
    Assets = H.PURIFIER_ASSETS,

    -- Appearance (the SAME locals as the Purifier - it should read as the same trooper)
    Tint = PURIFIER_TINT,
    Visuals = purifierLook,

    -- Stats. Absolute values, so they hold whatever the base row says.
    BasicStats = {
        HpHead = 200,   -- 1000 base / 600 on the Purifier
        HpTorso = 200,   -- 800 base / 600 on the Purifier
        HpLeftArm = 100,
        HpRightArm = 100,
        HpLeftLeg = 100,
        HpRightLeg = 100,
        WalkSpeed = 100, --130
        SprintSpeed = 150, --220
        -- MeleeDamage = 60,
        RangedDamage = 20, --33
        -- Shield = 50 (added; turned down so it stays killable)
    },
    -- The Purifier kit with the shield pool turned down (50, not 300). Regen time is unchanged:
    -- at this size the 12s window is a lull to push through, not a wall.
    Stats = function(actor, opts) H.PurifierStats(actor, H.SHIELD_EVENT_PURIFIER) end,

    -- Triggers (all shared with the Purifier)
    OnReady = function(actor)
        AVU.DisableAbility(actor, ABILITY_KAMIKAZE)
        AVU.PortalArrival(actor)   -- the same arrival as the cell's Purifier, deliberately
    end,
    OnTick = H.PurifierTick,
    OnDamageTaken = H.PurifierReleaseAnchor,
    OnDeath = purifierDrops,
}


-- =======================================================================
-- PURIFIED GRUNT (Id 143, Grunt) - the line infantry of the cell.
--   * Grunt Shade statline on a white/gold body; relentless advance on the Breacher's BT
--     (advance to melee, keep firing, stop only to reload).
--   * 200 HP holy-fed shield, spawns quarter-charged. No normal-path drops (gib loot kept).
-- =======================================================================

V["Purified Grunt"] = {
    Id = 143,
    Base = "Grunt",
    AltBases = { "Grunt_Guard", "Grunt_Guard_Offduty" },
    Assets = H.PURIFIED_ASSETS,
    TimeDilation = 0.9,

    -- Appearance
    Tint = PURIFIED_TINT,
    Visuals = function(actor, assets) H.PurifiedLook(actor) end,

    -- Stats (the Grunt Shade line: 2x HP, capped sprint)
    BasicStats = {
        -- HpHead = 175,
        -- HpTorso = 200,
        -- WalkSpeed = 130,
        SprintSpeed = 400,   -- 500
        -- MeleeDamage = 50,
        RangedDamage = 30, --35
        -- Shield = 200, spawns part-charged, no regen - only holy damage refills it
    },
    HardMode = { NoAggroAnim = true, BasicStats = { HpHead = 300, HpTorso = 300, RangedDamage = 30 } },
    Stats = function(actor, opts) H.PurifiedStats(actor, H.SHIELD_SMALL, SPAWN_SHIELD_FRAC) end,

    -- Triggers
    OnReady = function(actor) AVU.RunBehaviorTree(actor, BREACHER_BT) end,
    OnDamageTaken = H.PurifiedHit,
}


-- =======================================================================
-- PURIFIED BREACHER (Id 144, Grunt_Shotgun) - the shock half of the line.
--   * Breacher Shade statline (2x HP); keeps the native shotgun push.
--   * 200 HP holy-fed shield, spawns quarter-charged. No normal-path drops (gib loot kept).
-- =======================================================================

V["Purified Breacher"] = {
    Id = 144,
    Base = "Grunt_Shotgun",
    Assets = H.PURIFIED_ASSETS,

    -- Appearance
    Tint = PURIFIED_TINT,
    Visuals = function(actor, assets) H.PurifiedLook(actor) end,

    -- Stats (the Breacher Shade line: 2x HP)
    BasicStats = {
        HpHead = 200,   -- 150  (2x)
        HpTorso = 200,   -- 200  (2x)
        -- WalkSpeed = 130,
        -- SprintSpeed = 160,
        -- MeleeDamage = 60,
        RangedDamage = 20, --33
        -- Shield = 200, spawns part-charged, no regen - only holy damage refills it
    },
    HardMode = { NoAggroAnim = true, BasicStats = { HpHead = 400, HpTorso = 250, RangedDamage = 30 } },
    Stats = function(actor, opts) H.PurifiedStats(actor, H.SHIELD_SMALL, SPAWN_SHIELD_FRAC) end,

    -- Triggers
    OnDamageTaken = H.PurifiedHit,
}


-- =======================================================================
-- PURIFIED RAT (Id 145, Grunt_LabRat_Mechanic - the garage rat) - the slow anointed anchor.
--   * Sprint cut to 400 (600) with a double 400 HP shield: it soaks while the line moves up.
--   * No normal-path drops; RemainingLootDrops=0 also kills the BT loot drip (gib loot kept).
--   * Keeps its backpack: the LabRat has the component but no HasBackpack bool to clear, and
--     the pack IS its silhouette anyway.
--   * ARRIVES THROUGH A RIFT: hidden until OnReady's AVU.PortalArrival (Stats calls HideForArrival
--     first) - shared with the Sapper rats, Mad and Rocket.
-- =======================================================================

V["Purified Rat"] = {
    Id = 145,
    Base = "Grunt_LabRat_Mechanic",
    AltBases = { "Grunt_LabRat" },
    Assets = H.PURIFIED_RAT_ASSETS,   -- the cell kit + the portal step-out montage
    TimeDilation = 0.9,

    -- Appearance (no helmet on this base - SetHelmet no-ops; the wash + shell carry it)
    Tint = PURIFIED_TINT,
    Visuals = function(actor, assets) H.PurifiedLook(actor) end,

    -- Stats
    BasicStats = {
        HpHead = 120,
        HpTorso = 200,
        WalkSpeed = 130,    -- 130
        SprintSpeed = 300,  -- 600
        MeleeDamage = 80, -- 65
        -- RangedDamage = 35,
        -- Shield = 400, spawns part-charged, no regen - only holy damage refills it
    },
    HardMode = { NoAggroAnim = true, BasicStats = { HpHead = 300, HpTorso = 300, MeleeDamage = 120, SprintSpeed = 350 } },
    Stats = function(actor, opts)
        H.PurifiedStats(actor, H.SHIELD_BIG, SPAWN_SHIELD_FRAC)
        AVU.HideForArrival(actor)   -- OnReady's portal reveals it; here so it never stands visible first
    end,

    -- Triggers
    -- The yellow teleporter-pad rift + the step-out montage, replacing the plain Anteverse pop it
    -- arrived on. Same arrival as its Sapper cousins, the Mad and Rocket Rats.
    OnReady = function(actor) AVU.PortalArrival(actor) end,
    OnDamageTaken = H.PurifiedHit,
}

return V
