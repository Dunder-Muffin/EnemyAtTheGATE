-- =======================================================================
-- GATEKEEPER NEOPHYTE  (Gatekeeper_Phyter = NPC_Gatekeeper_Grunt)
--   * Chain: NPC_Gatekeeper_Grunt -> NPC_Gatekeeper_Parent -> NPC_Soldier_Grunt, so it is an
--     ORDER GRUNT under the hood and inherits the Order's one ability
--   * Machinery: AnteNPCs/GK_NeophyteHelpers.lua
-- =======================================================================
-- ABILITY MAP - NPC_Gatekeeper_Grunt (row "Gatekeeper_Phyter")
--   0 Idle - none
--   1 GRENADE - the Grunt throw (projectile_fraggrenade, 10s CD, LoS-gated) on the GK's own
--       Anim_GKChieftain_Throw_Montage. AVU.DisableGrenades == AVU.DisableAbility(actor, 1).
--       * The mimed minion toss reuses that montage: the grenade only spawns on the
--         "GrenadeRelease" notify, so a fast play rate releases nothing.
--   2 - EMPTY      3 - EMPTY   (free to claim)
--   * NOT slots: BodyShield + DBNO self-revive come from NPC_Gatekeeper_Parent;
--     EvadesProjectiles is a native flag.
-- =======================================================================


---@diagnostic disable: undefined-field, undefined-global

local ENUMS = require("AnteData.Enums")
local H = require("AnteNPCs.GK_NeophyteHelpers")

local V = {}

-- Shared preloads: the two throw montages, the skink 'gun' mesh (static SM_SquidTest; the SK is
-- unanimated), and the goo lob's first-shot latency insurance.
--   * The knife-throw clip is warmed on both difficulties. It only plays in hard mode, but the
--     def.Assets list is read before the flag matters and one resident montage is cheap.
local NEO_ASSETS = {
    ENUMS.Anims.GK_GRENADE_THROW,
    ENUMS.Anims.INTERFECTOR_THROW_KNIVES,
    ENUMS.Components.SM_SQUID,
    ENUMS.SOUNDS.BIOCANNON_FIRE,
}


-- =======================================================================
-- NEOPHYTE TRAINER
--   * Weaker Phyter that mimes a throw and lobs one 'pet' Pest when it aggros
--       - Shield Pest or the weaker Enlightened Pest; one only, and it dies with the trainer
--       - Pets can be tamed
--   * GK rifle replaced by the skink gun: five goo lobs, ~1.5s pause between bursts
--   * [HARD] The throw becomes a three-pest volley on the Grenadier's borrowed triple-throw
--       animation - its own minion down the middle, two pool pests either side - and the burst
--       gains a sixth lob with wider jitter
--   * [HARD] Its shell is up out of combat, so catching it mid-patrol isn't a free burst
-- =======================================================================

-- [HARD] The volley's two extra pests, alongside the variant's own minion. Mixed registered
-- variants and plain DT_NPCList rows - AVU.SummonVariant dispatches between them.
local POOL_TRAINER = { "Pest_Electro", "Magma Pest", "Leyak Pest", "Razor Pest", "Chonky Pest" }

-- MINION PLAN - what this variant throws, and what that throw needs kept warm.
--   * Stats records the plan per-actor. The throw (OnEnterCombat/OnTick) reads it back.
--   * Alt + PrimaryChance = a coin flip on the variant's OWN minion. No Alt means always Primary.
--   * Gun picks which round the skink spits (H.GUN_GOO / H.GUN_FROST); default is the goo.
--   * Pool is the hard-mode pair; Stats rolls two out of it and adds their classes to Warm.
--   * Warm is the THROW's own asset set, not the def's. A def.Assets preload does not pin
--     (CLAUDE.md S3), so OnTick re-warms the minion classes until they're actually thrown.
local PLAN_TRAINER = {
    Primary = "Shield Pest",           -- built on an ORDINARY Pest (PestHelpers.ShieldPest*)
    Alt = "Enlightened GK Pest",
    PrimaryChance = 0.6,
    Pool = POOL_TRAINER,
    Warm = { ENUMS.NpcClasses["Pest"], ENUMS.NpcClasses["Pest_Enlightened"],
             ENUMS.ProjectileClasses.BioBall, ENUMS.SOUNDS.BIOCANNON_FIRE },
}

-- A body whose STATS step bailed still gets a throw, on the Trainer's plan.
H.FallbackPlan = PLAN_TRAINER

-- Body tint. The GK texture is very dark, hence the big Color multiplier.
local LOOK_TRAINER = { Color = FVector(25, 20, 20), EmissiveColor = FVector(0, 0, 25),
                        Emissive = 100, Shield = FVector(1, 1, 1) }

V["Neophyte Trainer"] = {
    Id = 91,
    Base = "Gatekeeper_Phyter",
    Assets = {
        ENUMS.NpcClasses["Pest_Enlightened"],
        ENUMS.NpcClasses["Pest"],   -- the Shield Pest is built on an ORDINARY Pest (PestHelpers.ShieldPest*)
        ENUMS.ProjectileClasses.BioBall,   -- first-lob latency insurance (async-loaded, never a deadlock)
        table.unpack(NEO_ASSETS),
    },

    -- Appearance
    Visuals = function(actor) H.Visuals(actor, LOOK_TRAINER) end,

    -- Stats
    BasicStats = {
        HpHead = 200,   -- 250
        HpTorso = 250,   -- 300
        -- WalkSpeed = 130,
        SprintSpeed = 500, --600
        -- MeleeDamage = 100,
        RangedDamage = 30,   -- 40; now the per-lob damage
        -- Shield = 100   -- 225
    },

    HardMode = { BasicStats = { HpHead=250, HpTorso=300 } },

    -- STATIC dilation, so no MirrorTimeDilation (that's for dilation that changes at runtime).
    TimeDilation = 0.9,

    Stats = function(actor) H.Stats(actor, PLAN_TRAINER) end,

    -- Triggers
    OnEnterCombat = H.EnterCombat,
    OnRangedAttack = H.RangedAttack,
    OnTick = H.Tick,
    OnDeath = H.Death,
}


-- =======================================================================
-- NEOPHYTE TAMER
--   * Trainer variant that throws a Flurry Pest, and is a bit tougher
--   * Carries the FROST SKINK: snowballs for the same damage, and every hit drags the player's
--       temperature meter down a step. It never freezes outright - the native ladder does that
--       only if you stand in it, and cold gear tiers it down (H.FrostHit)
--   * [HARD] Same three-pest volley, off a pool that trades the Magma Pest for the Volatile and
--       Snow ones - the Flurry Pest stays its centre throw
--   * [HARD] Its shell is up out of combat, so catching it mid-patrol isn't a free burst
-- =======================================================================

-- [HARD] The volley's two extra pests. Same shape as the Trainer's pool above.
local POOL_TAMER = { "Pest_Snow", "Pest_Carbonated", "Pest_Electro", "Anterazor Pest", "Enlightened Pest", "Laser Pest",
                      "Leyak Pest", "Chonky Signal Pest" }

-- Same PLAN_* shape as the Trainer's, above.
local PLAN_TAMER = {
    Primary = "Flurry Pest",           -- the zigzag snow pest (AnteNPCs/PestSnow)
    Pool = POOL_TAMER,
    Gun = H.GUN_FROST,                 -- the frost skink: snowballs that chill instead of burn
    Warm = { ENUMS.NpcClasses["Pest_Snow"],
             ENUMS.ProjectileClasses.Snowball, ENUMS.SOUNDS.BIOCANNON_FIRE },
}

-- Body tint. Whiteout with a cyan cast, so the frost skink reads as the cold one.
local LOOK_TAMER = { Color = FVector(1, 8, 30), EmissiveColor = FVector(0, 6, 25),
                      Emissive = 100, Shield = FVector(0.5, 0.85, 1),
                      Skink = { Color = FVector(2.4, 3.0, 3.2) } }

V["Neophyte Tamer"] = {
    Id = 156,
    Base = "Gatekeeper_Phyter",
    Assets = {
        ENUMS.NpcClasses["Pest_Snow"],    -- the Flurry Pest's base
        ENUMS.ProjectileClasses.Snowball,
        table.unpack(NEO_ASSETS),
    },

    -- Appearance
    Visuals = function(actor) H.Visuals(actor, LOOK_TAMER) end,

    -- Stats
    BasicStats = {
        HpHead = 300,   -- 250
        HpTorso = 300,   -- 300
        -- WalkSpeed = 130,
        SprintSpeed = 500, --600
        MeleeDamage = 125, --100
        RangedDamage = 30,   -- 40; per-lob damage
        -- Shield = 100   -- 225
    },

    HardMode = { BasicStats = { HpHead = 350, HpTorso = 350 } },

    TimeDilation = 0.9,

    Stats = function(actor) H.Stats(actor, PLAN_TAMER) end,

    -- Triggers
    OnEnterCombat = H.EnterCombat,
    OnRangedAttack = H.RangedAttack,
    OnTick = H.Tick,
    OnDeath = H.Death,

    -- The chill rides the SNOWBALL, so OnDealtDamage has to be opted in to projectile hits -
    -- a projectile's damage causer is the projectile, not the NPC that fired it.
    ProjectileDealtDamage = true,
    OnDealtDamage = H.FrostHit,
}


return V
