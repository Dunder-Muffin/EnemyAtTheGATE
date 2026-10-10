-- =======================================================================
-- GATEKEEPER MAGE EYE (row "Gatekeeper_MageEye") - every LIVE eye variant, in one file
--   * STANDALONE - spawner-fielded, owner-less, fights on its own account (Warden Eye)
--   * SUPPORT - summoned BY a mage (GK_Mage.lua) and tied to it (OwningMage / LifetimeOwner). A
--     mage's moveset, not an enemy in its own right, so it never appears in SpawnerData:
--       Barrier Eye <- Barrier Mage  (channels the beam that keeps the mage invulnerable)
--   * WELDED - spawned as a SUBACTOR on its mage's clavicle or head and fired from ITS tick, so it
--     never moves, never perceives and never acts on its own (Beholder Crimson/Azure/Verdant/
--     Amber/Violet Eye). Their scale is the ATTACH's, so these five carry no def.BodyScale
--   * Four eye quirks (all decoded in the helpers - read it first):
--       can't switch the beam off; force-gibs itself; 10 HP on all six limbs;
--       `Invincible` does NOT make it unkillable
--   * An eye never sets CombatState, so IsActorReadyToAttack is FALSE forever on one
--   * ITS COLLISION IS TINY and BodyScale can't fix that (it scales collision and visual together)
--     - both eyes carry a def.HitPad; see EYE_HIT_PAD below and AVU.PadHitbox
--   Machinery: AnteNPCs/GK_MageEyeHelpers.lua
--   Decode: [[anteup2-beholder-eyes]]; the Beholder set also has AnNotes/AnteNPCs/Beholder.md
-- =======================================================================
-- ABILITY MAP - NPC_Gatekeeper_MageEye
--   0-3 ALL EMPTY - no Cooldown_* overrides, and the DT row has HasRangedAttack = false, so the
--     native ranged pipeline is off too. AVU.DisableAbility is a NO-OP on an eye
--   * NOT a slot: its ONE attack is the LaserComponent beam, driven OFF-TREE by the pawn's own 0.5s
--     server loop (CanFireLaser -> NPCEnraged -> laser timeline). An owner-less eye is therefore
--     permanently enraged and lasers anything it sees
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local ENUMS = require("AnteData.Enums")
local G = require("AnteData.Items").Global
local AVU = require("AnteUtils.AVUtils")
local Lasers = require("AnteUtils.Lasers")
local ItemSpawner = require("AnteCore.ItemSpawner")
local H = require("AnteNPCs.GK_MageEyeHelpers")
local BH = require("AnteNPCs.GK_MageBeholderHelpers")

local V = {}

-- HITBOX PAD (both eyes). SK_MageEyeDrone's physics asset is a 3.7-radius core sphyl plus four
-- small arm sphyls, inside a mesh with 31x19x19 bounds - most of the visible drone is empty air.
-- EYE_HIT_PAD=35 (actor-local units) centres a sphere just past the orb's silhouette; def.BodyScale
-- multiplies it like everything else. See AVU.PadHitbox.
-- Every eye hit was already a TORSO hit (no bone is in the humanoid limb lists), so the pad is free.
local EYE_HIT_PAD = 35


-- =======================================================================
-- WARDEN EYE  (standalone)
-- * A lone eye that patrols, and calls in reinforcements if it detects an enemy
-- * Its laser is suppressed - the tell is its own emissive going dark red once it spots you
-- * Survive its fuse and it portals in reinforcements (2 Phyters or 1 Mage) and despawns with
--     nothing; shoot it down first and it drops scrap
-- =======================================================================

V["Warden Eye"] = {
    Id = 100,
    Base = "Gatekeeper_MageEye",
    Assets = H.WARDEN_ASSETS,   -- reinforcement classes, emerge burst, the desat emissive

    -- Appearance
    BodyScale = 2.2,
    HitPad = EYE_HIT_PAD,
    Visuals = function(actor, assets)
        AVU.SetMeshTextureParam(actor, "EmissiveTexture", H.WARDEN_EM_TEX)
        H.EyeGlow(actor, "idle", H.EM_IDLE, H.EM_INTENSITY)
    end,
    ClientTick = true,   -- the alert glow reads the replicated StationaryTarget

    -- Stats
    BasicStats = {
        HpHead = 200,   -- 10
        HpTorso = 200,   -- 10
        WalkSpeed = 250, -- 600
        SprintSpeed = 250, -- 600
    },
    TimeDilation = 0.3,
    HardMode = {
        BasicStats = { HpHead = 250, HpTorso = 250, WalkSpeed = 300, SprintSpeed = 300 },
        TimeDilation = 0.4,
    },
    -- Belt AND braces: zero damage in case a frame slips through the per-tick LaserActive
    -- suppression (OnTick re-mutes it every 5 ticks).
    Stats = function(actor, opts)
        Lasers.Tune(actor, { Damage = 0, Bounces = 0 })
    end,

    -- Triggers
    OnTick = H.WardenTick,
    OnDamageTaken = H.WardenHurt,   -- being shot counts as being spotted

    OnDeath = function(actor)
        local at = H.WardenDeath(actor)   -- cleanup + a nav-projected drop point (it HOVERS)
        if not at then return end

        ItemSpawner.DropPool({
            { G.LODESTONE_FRAGMENT, 1 },
            { G.MAGNETIC_ALLOY, 2 },
        }, nil, at, 75)
    end,
}


-- =======================================================================
-- BARRIER EYE  (support - Barrier Mage)
-- * Deals no damage: it channels a harmless ORANGE laser at its mage while the mage fights
-- * The MAGE decides the barrier (a live owned eye near it = invulnerable); the eye just draws the
--     visible tether and stays alive
-- * If the mage dies with the eye up, it's released to its native berserk (a real damaging laser)
--     instead of despawning
-- =======================================================================

V["Barrier Eye"] = {
    Id = 99,
    Base = "Gatekeeper_MageEye",
    Assets = H.BARRIEREYE_ASSETS,

    -- Appearance
    BodyScale = 1.2,
    HitPad = EYE_HIT_PAD,
    Tint = {
        Color = FVector(0.8, 0.3, 0.1),
        EmissiveColor = FVector(1, 0.1, 0),
        Emissive = 15,
    },
    Visuals = function(actor, assets)
        Lasers.SetStyle(actor, H.CHANNEL_LASER)
    end,
    ClientTick = true,   -- the renderer re-mutes the channel laser (audio recreates on each toggle)
    -- On the DEF so both ends resolve it from one place: colour never replicates, so the client's
    -- OnRep_LaserActive looks it up off the variant tag.
    LaserStyle = H.CHANNEL_LASER,

    -- Stats
    BasicStats = {
        HpHead = 60,   -- 10
        HpTorso = 60,   -- 10
        -- WalkSpeed = 600,
        -- SprintSpeed = 600,
    },
    TimeDilation = 0.33,
    Stats = function(actor, opts)
        Lasers.Tune(actor, { Damage = 0, Bounces = 0 })
        -- Finer trace cadence so the channel tracks the mage smoothly (the default is coarse, and
        -- re-aiming faster than the trace redraws nothing). Set BEFORE it ever activates.
        Lasers.SetTraceInterval(actor, 0.1)

        AVU.ClearLoot(actor, true)
        AVU.ClearGibLoot(actor)   -- it force-gibs itself; ClearLoot alone does NOT stop the salvage
    end,

    -- Triggers
    OnTick = H.BarrierEyeTick,
    OnDeath = H.BarrierEyeDeath,
}


-- =======================================================================
-- BEHOLDER EYES  (welded - Beholder Mage)
-- * An arsenal of SIX colours, of which a Beholder wears two (three in hard mode): red sweep,
--     blue stunning seeker, green acid, orange fire, violet psychic seeker, rose summoner
-- * Each colour is a DIFFERENT WEAPON, and the mage is just the health bar
-- * Bolted to a shoulder (or, in hard mode, hovering over the head), pinned, and silent until
--     their mage's tick tells them to fire - no BT, no perception, no beam of their own
-- * INVULNERABLE, each in a faint energy shell of its own colour, because an enemy that eats every
--     bullet without a tell reads as a bug rather than a mechanic
-- * ONE shape, six colours, built in a loop so the shared half can never drift between them
-- * They have NO AI CONTROLLER - the mage's beat is the only thing that makes them act
-- * They carry NO OnTick and NO BodyScale: the mage owns their clock, the weld owns their size
-- Machinery: AnteNPCs/GK_MageBeholderHelpers.lua
-- =======================================================================

-- Ids live in the helpers (BH.EYE_IDS): the mage decodes a welded eye's colour back off its
-- VariantTag when it adopts one, so both ends have to read them from one place.
for name, id in pairs(BH.EYE_IDS) do
    local eyeType = BH.EYE_TYPES[name]

    -- Its own list, not eyeType.Assets: that table is the MAGE's warm set and must not grow a
    -- renderer-only entry. The shell material is what Visuals reaches for a beat after mutation.
    local assets = { AVU.SHIELD_SHELL_MAT, ENUMS.Anims.MAGEEYE_CLOSE, ENUMS.Anims.MAGEEYE_OPEN }
    for _, a in ipairs(eyeType.Assets) do assets[#assets + 1] = a end

    V["Beholder " .. name .. " Eye"] = {
        Id = id,
        Base = "Gatekeeper_MageEye",
        Assets = assets,

        -- Appearance
        Tint = eyeType.Tint,       -- before Visuals, so the shell lands on an already-coloured eye
        Visuals = function(actor) BH.EyeShell(actor, eyeType) end,

        -- Stats
        -- HP is listed for the record only - EyeChassis makes it Invincible, and the mage dying
        -- is what removes it.
        BasicStats = {
            HpHead = 200, HpTorso = 200,   -- 10 / 10 (all six limbs are 10 on this row)
            HpLeftArm = 200, HpRightArm = 200, HpLeftLeg = 200, HpRightLeg = 200,
        },
        -- They share one airspace with each other's payloads, and a frozen or burning eye reads as
        -- broken rather than as friendly fire.
        DebuffsImmune = BH.EYE_IMMUNE,
        Stats = function(actor) BH.EyeChassis(actor, eyeType) end,
    }
end


return V
