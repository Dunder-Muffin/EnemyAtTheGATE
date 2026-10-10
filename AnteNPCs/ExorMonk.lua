-- =======================================================================
-- Exor Monk variants. See AnteNPCs/Pest.lua header for the def schema.
--
-- MUST-KNOWS
--   * Exor Monk variants override the Windup attack
--   * ApocalypticMonk - if set, reduces AttackWindupTime by 30% and makes it fire 3 shots instead of 1
--   * One Exor type has a permanent debuff when hit with a freeze (Slushie)
--
-- ABILITY MAP - NPC_Exor_Monk (row "Exor_Monk", extends NPC_Monster_Exor)
--   Slot 3 TELEPORT: blink to target +100Z (Broadcast_TeleportFX)
--     * No cooldown, BT controls its teleports
--
-- Machinery: AnteNPCs/ExorMonkHelpers.lua
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local ENUMS = require("AnteData.Enums")
local G = require("AnteData.Items").Global
local AVU = require("AnteUtils.AVUtils")
local H = require("AnteNPCs.ExorMonkHelpers")

local V = {}


-- =======================================================================
-- EXOR MAGUS
-- * Armored head, slightly faster
-- * Its single channel fires a spiral of many lower-damage beams
-- * Every few casts it breaks off for the shared PUSHBACK NOVA
-- * [HARD] - much tankier, a harder-hitting beam, and a shorter cast (the barrage retimes with it)
-- =======================================================================

V["Exor Magus"] = {
    Id = 8,
    Base = "Exor_Monk",
    -- Preloaded off-hook (S2): Broadcast_BeamAttack spawns BEAM + SHOCKWAVE;
    --   CHARGEUP is the native windup FX.
    Assets = {
        ENUMS.Components.SM_EXOR_SKULL,
        ENUMS.Effects.EXOR_BEAM, ENUMS.Effects.EXOR_SHOCKWAVE, ENUMS.Effects.EXOR_CHARGEUP,
    },

    -- Appearance
    -- Actor scale (capsule + mesh) so the bigger body is a bigger hitbox.
    BodyScale = { X = 1, Y = 1.2, Z = 1.2 },
    Tint = { Color = FVector(0.5, 2, 4), EmissiveColor = FVector(0.5, 0.5, 1), Emissive = 50 },
    Visuals = function(actor, assets)
        -- Pass PATH -> resolved fresh at use-time (no captured wrapper)
        AVU.AttachStaticMesh(actor, ENUMS.Components.SM_EXOR_SKULL, "Head", {
            Location = FVector(10, -15, -25),
            Rotation = FRotator(0, 180, 27),
            Scale = FVector(1.25, 1.25, 1.25),
        })
    end,

    -- Stats
    BasicStats = {
        HpHead = 160,   -- 140
        HpTorso = 100, --85
        -- WalkSpeed = 180,
        -- SprintSpeed = 700,
        -- MeleeDamage = 50,
        RangedDamage = 70,   -- 110
    },
    TimeDilation = 1.2,
    HardMode = {
        BasicStats = { HpHead = 220, HpTorso = 150 },   -- 160 / 100
    },
    Stats = function(actor, opts)
        actor.ApocalypticMonk = false
        actor.AttackWindupTime = H.ByMode(H.MAGUS_WINDUP)
    end,

    -- Triggers
    OnTick = H.MagusTick,
    OnWindupAttack = H.MagusWindup,
    OnExitCombat = H.NovaResetCount,
    OnDeath = H.MagusForget,

    OnGibbed = function(actor)
        AVU.DropLoot(actor, {
            { Row = G.DISTILLATION_ALIEN, 4 },
        })
    end,
}


-- =======================================================================
-- EXORRIOR
-- * Higher melee, lower ranged; teleports during its burst.
-- * Spiked forearms - the Exor's own quill cluster worn as armbands
-- * Wears the Armored Exor's plating, tinted apart from the body
-- * [HARD] - tankier, quicker on its feet, and a visibly shorter cast
-- * FROST WEAKNESS: a Slushie slows it for good - movement, cast and blink. [HARD] drops to normal's pace.
-- =======================================================================

V["Exorrior"] = {
    Id = 9,
    Base = "Exor_Monk",
    Assets = { ENUMS.Components.SM_EXOR_QUILLSTATE, ENUMS.Components.SK_EXOR_ARMOR },

    -- Appearance
    -- Actor scale (capsule + mesh) so the bigger body is a bigger hitbox.
    BodyScale = { X = 1.2, Y = 1.2, Z = 1 },
    -- Body only - the armor is its own component and takes its own Color below.
    Tint = { Color = FVector(3, 2, 0), EmissiveColor = FVector(4, 0, 0), Emissive = 30 },
    Visuals = function(actor, assets)
        -- Multiplies a purple texture, so it shifts toward red/magenta well and yellow/green poorly.
        AVU.AttachSkeletalMesh(actor, ENUMS.Components.SK_EXOR_ARMOR, "root", {
            LeaderPose = true,
            Color = FVector(3, 0.5, 0.2),
            Scale = FVector(1.05, 1.05, 1.05),
        })
        AVU.AttachStaticMesh(actor, ENUMS.Components.SM_EXOR_QUILLSTATE, "r_arm1", {
            Location = FVector(-10, -5, 0),
            Rotation = FRotator(90, 0, 90),
            Scale = FVector(1.2, 2.1, 1.2),
            DiffuseColor = FVector(3, 0.1, 0.5),
        })
        AVU.AttachStaticMesh(actor, ENUMS.Components.SM_EXOR_QUILLSTATE, "l_arm2", {
            Location = FVector(0, -18, 0),
            Rotation = FRotator(0, 90, 30),
            Scale = FVector(0.5, 1.2, 1.2),
            DiffuseColor = FVector(3, 0.1, 0.5),
        })
    end,

    -- Stats
    BasicStats = {
        HpHead = 150,   -- 140
        HpTorso = 150,   -- 85
        -- WalkSpeed = 180,
        -- SprintSpeed = 700,
        MeleeDamage = 120,   -- 50
        RangedDamage = 100,  -- 110
    },
    TimeDilation = 1.1,
    HardMode = {
        BasicStats = { HpHead = 200, HpTorso = 200, RangedDamage = 125 },
    },
    Stats = function(actor, opts)
        actor.ApocalypticMonk = true
        actor.ApocalypticAttackSpeed = H.ExorriorAttackSpeed()
        actor.AttackWindupTime = H.EXORM_WINDUP
    end,

    -- Triggers
    OnTick = H.ExorriorTick,
    OnWindupAttack = H.ExorriorBlink,
    OnDeath = H.ExorriorForget,

    OnGibbed = function(actor)
        AVU.DropLoot(actor, {
            { Row = G.EXOR_ARM },
        })
    end,
}


-- =======================================================================
-- EXORRIOR MAGUS (Exorrior body + Magus beam)
-- * The Exorrior's cadence exactly - blink mid-cast, same channel, same speed dial - but the
--   cast is the Magus beam, and it carries the HP and damage of a heavier body.
-- * Each cast lands as three beams: the native one plus a flank beam either side (skipped
--   point-blank). ApocalypticMonk makes one attack three such casts, each behind its own blink.
-- * Wears the Pikeman's armored skin rather than the Monk's robe
-- * Frost slows it for good, cast and blink included, same as the Exorrior.
-- * Every few casts it breaks off for the shared PUSHBACK NOVA.
-- * [HARD] - a shorter cast, a harder beam, and the nova comes round twice as often.
-- =======================================================================

local EXORM_BEAM_DAMAGE = H.EXORM_BEAM_DAMAGE   -- shared with the flank beams

V["Exorrior Magus"] = {
    Id = 69,
    Base = "Exor_Monk",
    -- Skull mask, arm spikes, the body reskin, and the beam-FX systems Broadcast_BeamAttack
    -- spawns, preloaded so nothing cold-loads nested in the tick-hook drain (see the Magus note).
    -- The nova's own assets are re-loaded at fire time instead.
    Assets = {
        ENUMS.Components.SM_EXOR_SKULL, ENUMS.Components.SM_EXOR_QUILLSTATE,
        ENUMS.Components.T_EXOR_PIKEMAN_02,
        ENUMS.Effects.EXOR_BEAM, ENUMS.Effects.EXOR_SHOCKWAVE, ENUMS.Effects.EXOR_CHARGEUP,
    },

    -- Appearance
    BodyScale = { X = 1.35, Y = 1.35, Z = 1.25 },
    -- Exorrior orange tint/glow.
    Tint = { Color = FVector(1, 0.7, 1), EmissiveColor = FVector(2, 1.5, 0.2), Emissive = 50 },
    Visuals = function(actor, assets)
        -- Pikeman skin on the Monk body
        AVU.SetMeshTextureParam(actor, "Texture", ENUMS.Components.T_EXOR_PIKEMAN_02, 0)

        AVU.AttachStaticMesh(actor, ENUMS.Components.SM_EXOR_SKULL, "Head", {
            Location = FVector(10, -15, -32),
            Rotation = FRotator(0, 180, 27),
            Scale = FVector(1.25, 1.25, 1.25),
            DiffuseColor = FVector(0.7, 0.5, 1.2),
        })
        -- The Exorrior's quill armbands
        AVU.AttachStaticMesh(actor, ENUMS.Components.SM_EXOR_QUILLSTATE, "r_arm1", {
            Location = FVector(-10, -5, 0),
            Rotation = FRotator(90, 0, 90),
            Scale = FVector(1.2, 2.4, 1.2),
            DiffuseColor = FVector(12, 1, 5),
        })
        AVU.AttachStaticMesh(actor, ENUMS.Components.SM_EXOR_QUILLSTATE, "r_arm2", {
            Location = FVector(0, 0, 0),
            Rotation = FRotator(0, 90, 30),
            Scale = FVector(1, 1.2, 1.2),
            DiffuseColor = FVector(12, 1, 5),
            -- DiffuseColor = FVector(10, 5, 0.6),
        })
        AVU.AttachStaticMesh(actor, ENUMS.Components.SM_EXOR_QUILLSTATE, "l_arm2", {
            Location = FVector(0, -18, 0),
            Rotation = FRotator(0, 90, 30),
            Scale = FVector(0.5, 1.2, 1.2),
            DiffuseColor = FVector(12, 1, 5),
            -- DiffuseColor = FVector(10, 5, 0.6),
        })
    end,

    -- Stats
    BasicStats = {
        HpHead = 200,   -- 140
        HpTorso = 200,   -- 85
        -- WalkSpeed = 180,
        -- SprintSpeed = 700,
        MeleeDamage = 100,   -- 50
        RangedDamage = EXORM_BEAM_DAMAGE.Normal,   -- 110
    },
    TimeDilation = 1.1,   -- the Exorrior's, like everything else about its cadence
    HardMode = {
        BasicStats = { HpHead = 250, HpTorso = 300, RangedDamage = EXORM_BEAM_DAMAGE.Hard },
    },
    Stats = function(actor, opts)
        actor.ApocalypticMonk = true
        actor.ApocalypticAttackSpeed = H.ExorriorAttackSpeed()
        actor.AttackWindupTime = H.EXORM_WINDUP
    end,

    -- Triggers
    OnTick = H.ExormTick,
    OnWindupAttack = H.ExormWindup,
    OnExitCombat = H.NovaResetCount,
    OnDeath = H.ExormForget,

    OnGibbed = function(actor)
        AVU.DropLoot(actor, {
            { Row = G.DISTILLATION_ALIEN, Amount = 6 },
            { Row = G.EXOR_ARM, Amount = 1 },
        })
    end,
}


-- =======================================================================
-- EXOR SHADOW MONK - HARD MODE (SpawnerData's SD.HardVariants fallback)
-- Near-native stats (-20 beam damage), hotter pink glow, plus a DECOY BLINK:
-- each teleport re-fires Broadcast_TeleportFX at fake destinations, painting
-- extra identical trails that replicate free to every client.
-- No Assets: the decoy reuses FX the real blink just spawned, already warm.
-- =======================================================================

-- Pinker + hotter than the native faint-pink glow ("minor visual" - no scale/attach).
local SHADOW_TINT_COLOR    = FVector(3, 0.5, 1.6)
local SHADOW_TINT_EMISSIVE = FVector(1, 0.25, 0.75)
local SHADOW_TINT_STRENGTH = 200    -- Magus glows at 150

V["Exor Shadow Monk"] = {
    Id = 176,
    Base = "Exor_Monk",
    Assets = {},

    -- Appearance
    Tint = { Color = SHADOW_TINT_COLOR, EmissiveColor = SHADOW_TINT_EMISSIVE, Emissive = SHADOW_TINT_STRENGTH },

    -- Stats
    BasicStats = {
        HpHead = 180, -- 140
        HpTorso = 120, -- 85
        RangedDamage = 90,   -- 110
    },

    -- Triggers
    OnTeleport = H.ShadowTeleport,
}

return V
