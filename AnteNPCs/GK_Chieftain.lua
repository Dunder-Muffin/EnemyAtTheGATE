-- =======================================================================
-- Gatekeeper Chieftain - NPC_Gatekeeper_Chieftain
--
-- MUST-KNOWS
--   * On top of Gatekeeper_Phyter, a grab-headbutt melee and dbno self-revive (6s)
--   * OverrideSoldierFireLogic is the switch for "fires something else" - see the helpers file.
--
-- ABILITY MAP
--   0 Idle
--   1 GRENADE - Throw grenade
--   NOT slots: the grab headbutt, dodges, DBNO self-revive
-- 
-- Decode notes: [[anteup2-chieftain-decode]]
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local ENUMS = require("AnteData.Enums")
local G = require("AnteData.Items").Global
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local ASSETS = require("AnteCore.AssetManager")
local ItemSpawner = require("AnteCore.ItemSpawner")
local H = require("AnteNPCs.GK_ChieftainHelpers")

local V = {}


-- =======================================================================
-- ESOTERIC CHIEFTAIN
-- * Unconventional tech - skink gun, tinctures, and an electron grenade
-- * Drinks two tinctures, once on aggro and once on shield break:
--     > Giganto: +melee and size
--     > Speedy:  +time dilation
--     > Phasing: near-invisible, but takes more damage
--     > Storm:   a one-time 7m electric stun nova
-- * Stronger shield, weaker body HP, and the shell is up before it ever aggros
-- * Swings and grabs half again as fast, on the shared melee tempo
-- * Spawn its Skink weapon when it dies
-- =======================================================================

local COMBAT_DRINK_DELAY_MS = 2000   -- delay on the first (aggro) tincture attempt

-- Keep-warm: re-load the drink/boon/projectile set off-peak (~1/min) - trades the round-5 cold-burst hitch for a quiet reload (preload doesn't pin, §3).
local KEEPWARM_TICKS = 600
local KEEPWARM = {
    ENUMS.Anims.GK_DBNO_HEAL,
    ENUMS.Components.SM_FLASK_CONSUMABLE,
    ENUMS.Effects.TINCTURE_ELECTRIC_PASSIVE,   -- speedy tincture body aura
    ENUMS.BuffObjects.Stunned,                 -- the drink's hold-stun
    ENUMS.Effects.LIGHTNING_PURPLE,            -- + its purple-lightning BodyParticleEffect
    ENUMS.Effects.TINCTURE_GIGANTO_POOF,       -- shared drink-end smoke+glitter burst
    ENUMS.Effects.TINCTURE_ELECTRIC_BURST,     -- storm tincture nova (ClientFX ELECTRIC_NOVA)
    ENUMS.DamageType.Electric,                 -- + its damage type (never fire untyped)
    ENUMS.ProjectileClasses.MagmaFireball,     -- first-lob warmth too
    ENUMS.ProjectileClasses.GrenadeElectron,
}

V["Esoteric Chieftain"] = {
    Id = 125,
    Base = "Gatekeeper_Chieftain",
    Assets = {
        ENUMS.Components.SM_SQUID,          -- static squid weapon mesh (the SK is unanimated; see ENUMS)
        ENUMS.Components.M_SQUID_MAGMA,     -- red/magma material override for the gun
        ENUMS.Components.SM_FLASK_CONSUMABLE,
        ENUMS.Anims.GK_DBNO_HEAL,
        
        ENUMS.ProjectileClasses.MagmaFireball,  -- FireRanged_Projectile async-loads (no deadlock risk but stutters)
        ENUMS.ProjectileClasses.GrenadeElectron,
        ENUMS.SOUNDS.BIOCANNON_FIRE,               -- squid squeal (assigned in Visuals)
        ENUMS.Components.SM_ARMOR_CHEST_CRYSTAL,   -- cascade chest plate
        ENUMS.Effects.TINCTURE_ELECTRIC_PASSIVE,   -- speedy tincture body aura
        ENUMS.Effects.TINCTURE_GIGANTO_POOF,       -- shared drink-end smoke+glitter burst
        -- Storm nova FX: listed here AND in the helpers' fire-time deps.
        --   * def.Assets preloads on renderers too (clients spawn the ClientFX locally).
        --   * The fire-time LoadAsync only warms the authority.
        ENUMS.Effects.TINCTURE_ELECTRIC_BURST,
        -- Measured for the melee release valve (AVU.MeleeReleaseTicks).
        ENUMS.Anims.GKCHIEF_GRAB, ENUMS.Anims.GKCHIEF_MELEE,
    },

    -- Appearance
    Tint = { Color = FVector(4, 2, 0.5) },
    Visuals = function(actor, assets)
        H.Gear(actor)
    end,

    -- Stats
    BasicStats = {
        HpHead = 250,   -- 350
        HpTorso = 250,  -- 450
        WalkSpeed = 150,   -- 150
        SprintSpeed = 500,   -- 650
        MeleeDamage = 100,   -- 85 (headbutt 2x)
        RangedDamage = 125,   -- 65
        -- Shield = 500   -- 350
    },
    HardMode = {
        BasicStats = { HpHead = 300, HpTorso = 350, MeleeDamage = 125, RangedDamage = 150 },
    },
    MirrorTimeDilation = true,
    Stats = function(actor, opts)
        H.ArmSkinkGun(actor) -- kills the hitscan pistol, swaps the grenade row
        AVU.SetBodyShield(actor, { Max = 500 })
        AVU.ShieldAlwaysOn(actor)   -- no free window before it aggros
        H.MeleeTempo(actor)       -- the tinctures re-assert this, so it survives a dilation change
    end,

    -- Triggers
    -- The melee release valve every tick, then the ~2/s shield poll and the off-peak keep-warm.
    OnTick = function(actor, totalTicks)
        if Utils.IsActorInvalid(actor) then return "REMOVE" end
        H.MeleeReleaseTick(actor)

        if totalTicks % KEEPWARM_TICKS == 7 then
            ASSETS.WarmPinned(KEEPWARM)
        end
        if totalTicks % 5 ~= 0 then return end
        H.ShieldBreakPoll(actor)
    end,

    OnMeleeSwing = H.MeleeSwing,   -- stamps the swing; the tick fires the release valve

    -- Tincture 1 (retries; the BT isn't always overridden).
    OnEnterCombat = function(actor)
        Utils.QueueWork(function() H.TryCombatDrink(actor) end, COMBAT_DRINK_DELAY_MS)
    end,

    OnRangedAttack = H.RangedAttack,    -- the hitscan is off, so this is the actual shot

    -- While phased, re-apply the fade on every hit - a damage-stage material rebuild (HealthTextures) resets opacity to solid. Deferred off-hook (§2).
    OnDamageTaken = function(actor)
        local key = Utils.ActorKey(actor)
        if not key or not H.Phased[key] then return end
        Utils.QueueWork(function()
            if H.Phased[key] then H.ApplyPhaseLook(actor) end
        end, 0)
    end,

    OnDeath = function(actor)
        H.ChieftainDeath(actor)

        -- Two sibling pool entries - each needs its own outer braces (DropLoot warns if missing).
        AVU.DropLoot(actor, {
            { Pool = {
                { G.TINCTURE_RESTORATIVE },
                { G.TINCTURE_GIGANTO },
                { G.TINCTURE_PHASING },
            }, Count = 1, Radius = 125 },
            { Pool = {
                { G.TRANSCENDIUM, 2 },
                { G.RES_GROWTH, 2 },
                { G.NEUTRINO_MAPPER, 1 },
                { G.BLACK_GUNK, 3 },
                { G.DIGITAL_ORE, 2 },
                { G.DIGITAL_GOLD, 1 },
                { G.YETI_FUR, 2 },
                { G.DISTILLATION_OCCULT, 4 },
                { G.DISTILLATION_UNSTABLE, 4 },
            }, Count = 2, Radius = 25 },
        })
    end,
}


-- =======================================================================
-- GATEKEEPER PROVISIONER
--   * Chieftain with an oversized pack that drops a loot spill bag
--   * Specific to the Shadow boss fight (ModuleShadow/ShadowStorms)
--       > Drops Ammo, healing supplies
--   * [HARD] Its shell is up out of combat - no free burst before the storm reaches it
-- =======================================================================

-- The supply drop - place these items in a corpse bag. Overstacked slots misrender.
local PROV_DROPS = {
    { G.FLASK_RESTORATIVE, 3 },
    { G.FLASK_CHARGING, 2 },
    { G.HEALING_SYRINGE, 3 },
    { G.HEALING_SYRINGE, 3 },
    { G.AMMO_9MM, 90 },
    { G.AMMO_357, 36 },
    { G.AMMO_556, 90 },
    { G.AMMO_12G, 24 },
    { G.FRAG_GRENADE, 4 },
    { G.COATING_REFORGING, 1 },
    { G.COATING_SOMNIVOROUS, 1 },
    { G.COATING_ACID, 1 },
}

V["Gatekeeper Provisioner"] = {
    Id = 174,
    Base = "Gatekeeper_Chieftain",
    Assets = {},

    -- Appearance
    Tint = { Color = FVector(1.8, 1.6, 0.7) },
    Visuals = function(actor, assets)
        -- Strong backpack tint
        H.ProvisionerGear(actor)
    end,

    -- Stats
    BasicStats = {
        -- HpHead = 350,
        -- HpTorso = 450,
        -- WalkSpeed = 150,
        -- SprintSpeed = 650,
        -- MeleeDamage = 85,   (headbutt 2x)
        -- RangedDamage = 65,
        -- Shield = 350
    },
    Stats = H.HardShieldStance,   -- [HARD] shell up before it aggros

    -- Triggers
    -- The whole point of the variant: a pre-filled loot spill bag where it fell. Location captured
    -- by value - never let deferred work re-deref the dying actor.
    OnDeath = function(actor)
        local deathLoc
        pcall(function()
            local l = actor:K2_GetActorLocation()
            deathLoc = FVector(l.X, l.Y, l.Z)
        end)
        if not deathLoc then return end
        ItemSpawner.DropSpillBag(deathLoc, PROV_DROPS)
        Utils.LogDebug("Gatekeeper Provisioner - supply bag dropped", SETTINGS.DEBUG_NPC_ACTIONS)
    end,
}


-- =======================================================================
-- GATEKEEPER WARCHIEF - HARD MODE (SpawnerData's SD.HardVariants fallback)
-- The plain Chieftain, escalated - it keeps every native move and gets more out of each.
-- * Swings and grabs half again as fast, and stops standing around after a grab it missed
-- * Its grenade comes as a three-frag volley fanned across the ground you are standing on
-- * Its hardlight shell is up from the moment it spawns, so there is no free window before aggro
-- * Reads as a plain Chieftain until you see the gold pistol
-- =======================================================================

V["Gatekeeper Warchief"] = {
    Id = 187,
    Base = "Gatekeeper_Chieftain",
    Assets = H.WAR_ASSETS,   -- the two melee clips it measures, the volley animation and its frag

    -- Appearance
    -- No body wash on purpose: the gold pistol is the whole tell.
    Visuals = function(actor, assets)
        H.WarchiefGear(actor)
    end,

    -- Stats
    -- Limb HP writes don't reduce effective HP on this base (the DT row wins) - durability here is
    -- the body SHIELD, which H.WarLoadout raises.
    BasicStats = {
        MeleeDamage = 100,   -- 85; the grab headbutt lands twice this, then a tenth of it on a head
        RangedDamage = 85,   -- 65
    },
    Stats = function(actor, opts)
        H.WarLoadout(actor)
    end,

    -- Triggers
    OnMeleeSwing = H.MeleeSwing,   -- stamps the swing; the tick fires the release valve
    OnTick = H.WarTick,
    OnThrow = H.WarThrow,          -- PRE: takes the throw's montage slot and lobs three
}

return V
