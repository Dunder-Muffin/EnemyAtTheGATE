-- =======================================================================
-- Exor (row "Exor")
--
-- MUST-KNOWS
--   * Quill arm: projectile_exorspike, MaxBurstFire=5, 0.25s between shots, 2s between bursts,
--     backstep dodge after.
--   * Every variant inherits a RadiationZone child component - AVU.ClearRadiationZone in Stats
--     avoids the damage-timer-in-a-crowd crash.
--
-- ABILITY MAP - NPC_Monster_Exor
--   0 Idle - none. Slots 1/3 (grenade/blink) only exist on Exor_Armored.
--
-- Machinery: AnteNPCs/ExorHelpers.lua
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local G = require("AnteData.Items").Global
local AVU = require("AnteUtils.AVUtils")
local H = require("AnteNPCs.ExorHelpers")

local V = {}


-- =======================================================================
-- ANTEGRAV EXOR
-- Ceilings in combat, grounds when its target strays too far, and 50/50 flips gravity on a hit.
-- [HARD] a short clip so each reload throws a big slow quill that tracks you.
-- =======================================================================

local ANTEGRAV_HARD_AMMO = 9   -- [HARD] 3 volleys of MaxBurstFire; native 20

V["Antegrav Exor"] = {
    Id = 14,
    Base = "Exor",
    -- The seeker's class + its row's DamageType, loaded at mutation rather than on the first
    -- reload: a cold projectile class blocking-loads, and landing that on the reload beat stalled
    -- the body mid-fight. Pipeline pins these after the first spawn; H's per-shot Preload re-warms.
    Assets = { ENUMS.ProjectileClasses.QuillSpear, ENUMS.DamageType.SharpExorQuill },

    -- Appearance
    Tint = { Color = FVector(0.2, 0.3, 0.7), EmissiveColor = FVector(0, 0.15, 1), Emissive = 150 },

    -- Stats
    BasicStats = {
        -- HpHead = 350,
        -- HpTorso = 175,
        -- WalkSpeed = 180,
        -- SprintSpeed = 400,
        -- MeleeDamage = 70,
        RangedDamage = 50,   -- 75
    },
    TimeDilation = 1.2,
    MirrorTimeDilation = true,   -- the hard reload retime rides CustomTimeDilation - mirror or it's server-only
    HardMode = {
        BasicStats = { HpTorso=250, MeleeDamage=100, RangedDamage = 70 },
    },
    Stats = function(actor, opts)
        local move = actor.CharacterMovement
        if IsNotValid(move) then return end

        -- Start rightside up; H.GravTick owns the flip cycle from here.
        move:SetGravityDirection(FVector(0, 0, -1))
        move.GravityScale = 1.0

        actor.MaxBurstFire = 3   -- 5
        actor.RangedAttack_Cooldown = STATE.HardModeNoMercy and 0.9 or 1   -- 2

        if STATE.HardModeNoMercy then
            actor.MaxAmmo = ANTEGRAV_HARD_AMMO
            actor.MaxAmmoCount = ANTEGRAV_HARD_AMMO
            pcall(function() actor.CurrentAmmoCount = ANTEGRAV_HARD_AMMO end)   -- spawns with 20 otherwise
        end

        AVU.SetSightSenseDelayed(actor, 3000, 4500, 360)   -- ceiling walker: wide sight or it loses aggro overhead
        AVU.ClearRadiationZone(actor)
    end,

    -- Triggers
    OnTick = H.GravTick,
    OnReload = H.AntegravReload,   -- [HARD] throws a seeker quill, then reloads faster
    OnDamageTaken = H.AntegravDamageTaken,
    OnDeath = function(actor) AVU.RestoreGravity(actor) end,
}


-- =======================================================================
-- MAGMA EXOR
-- Quills replaced with the magma skink's ball; each reload lobs a fire-mortar shell that leaves a
-- burning patch. Cold/fire immune.
-- =======================================================================

V["Magma Exor"] = {
    Id = 15,
    Base = "Exor",
    Assets = { ENUMS.Components.SM_LASER_GRENADE },

    -- Appearance
    BodyScale = 1.2,
    Tint = { Color = FVector(0.8, 0.3, 0), EmissiveColor = FVector(0.7, 0.1, 0), Emissive = 120 },

    -- Stats
    BasicStats = {
        -- HpHead = 350,
        -- HpTorso = 175,
        -- WalkSpeed = 180,
        -- SprintSpeed = 400,
        -- MeleeDamage = 70,
        -- RangedDamage = 75,
    },
    DebuffsImmune = { ENUMS.Debuffs.Frost, ENUMS.Debuffs.Frost2, ENUMS.Debuffs.Frost3,
                      ENUMS.Debuffs.Ignited, ENUMS.Debuffs.IgnitedHoly },
    TimeDilation = 0.8,
    HardMode = {
        BasicStats = { HpHead = 350, HpTorso = 250 },   -- 350 / 175
        TimeDilation = 0.9,
    },
    Stats = function(actor, opts)
        actor.MaxAmmo = 8
        actor.MaxAmmoCount = 8
        actor.MaxBurstFire = 4   -- 5
        actor.RangedAttack_Cooldown = STATE.HardModeNoMercy and 1.5 or 2   -- 2
        pcall(function() actor.CurrentAmmoCount = actor.MaxAmmoCount end)

        AVU.SetProjectileRow(actor, "ExorProjectile", ENUMS.ProjectileRows.MagmaSkinkBall)
        AVU.ClearRadiationZone(actor)
    end,

    -- Triggers
    OnReload = H.MagmaReload,
    OnDeath = function(actor) AVU.DropLoot(actor, { Row = G.GEL, Amount = 3, MinStory = 34 }) end,
    OnGibbed = function(actor) AVU.DropLoot(actor, { Row = G.DISTILLATION_BOILING, Amount = 4 }) end,
}


-- =======================================================================
-- ANTEFIRE EXOR
-- Magma's mortar mechanics plus the Antegrav's gravity cycle, but its own scripted plasma bolt
-- instead of the native 5500uu shot (H.AntefireRangedAttack - the row's speed can't be dodged and
-- nothing on the native path can slow it).
-- [HARD] the mortar flies flat and fast instead of lobbing, and the reload is quicker.
-- =======================================================================

V["Antefire Exor"] = {
    Id = 90,
    Base = "Exor",
    -- The scripted bolt's whole set, loaded at mutation and pinned by Pipeline so the first shot
    -- of a fight is never a cold load. H.AntefireRangedAttack re-warms the same paths per shot.
    Assets = {
        ENUMS.ProjectileClasses.PlasmaBall,
        ENUMS.DamageType.FirePlasma,
        ENUMS.BuffObjects.IgnitedPlasma,
        ENUMS.BuffObjects.HPDamage,
        ENUMS.Effects.PLASMA_PROJECTILE,   -- the mortar comet
    },

    -- Appearance
    BodyScale = 1.1,
    Tint = { Color = FVector(0.2, 0.3, 0.8), EmissiveColor = FVector(0, 0, 0.7), Emissive = 120 },

    -- Stats
    BasicStats = {
        HpHead = 350, --350
        HpTorso = 350, --175
        -- WalkSpeed = 180,
        -- SprintSpeed = 400,
        MeleeDamage = 100,
        RangedDamage = 70,   -- 75
    },
    DebuffsImmune = { ENUMS.Debuffs.Frost, ENUMS.Debuffs.Frost2, ENUMS.Debuffs.Frost3,
                      ENUMS.Debuffs.Ignited, ENUMS.Debuffs.IgnitedHoly, ENUMS.Debuffs.IgnitedPlasma },
    TimeDilation = 1.15,
    MirrorTimeDilation = true,   -- the hard reload retime rides CustomTimeDilation - mirror or it's server-only
    HardMode = {
        BasicStats = { HpHead = 400, HpTorso = 450, MeleeDamage = 125, RangedDamage = 90 },
        TimeDilation = 1.3,
    },
    Stats = function(actor, opts)
        local move = actor.CharacterMovement
        if IsNotValid(move) then return end

        -- Start rightside up; H.GravTick owns the flip cycle from here.
        move:SetGravityDirection(FVector(0, 0, -1))
        move.GravityScale = 1.0

        -- Shorter bursts + a lowered clip so it reloads (and lobs plasma mortars) often.
        actor.MaxBurstFire = STATE.HardModeNoMercy and 6 or 4   -- 5
        actor.RangedAttack_Cooldown = STATE.HardModeNoMercy and 0.5 or 1   -- 2
        actor.MaxAmmo = STATE.HardModeNoMercy and 6 or 8
        actor.MaxAmmoCount = STATE.HardModeNoMercy and 6 or 8
        pcall(function() actor.CurrentAmmoCount = actor.MaxAmmoCount end)   -- spawns with 20 otherwise

        AVU.SetSightSenseDelayed(actor, 3000, 4500, 360)   -- ceiling walker: wide sight or it loses aggro overhead

        H.AntefireProjectile(actor)   -- the slow plasma row (or the scripted-bolt fallback)
        AVU.ClearRadiationZone(actor)
    end,

    -- Triggers
    OnTick = H.GravTick,
    OnRangedAttack = H.AntefireRangedAttack,
    OnReload = H.AntefireReload,
    OnDamageTaken = H.AntefireDamageTaken,
    OnDeath = function(actor) AVU.RestoreGravity(actor) end,   -- corpse shouldn't stick to the ceiling
    OnGibbed = function(actor) AVU.DropLoot(actor, { Row = G.DISTILLATION_BOILING, Amount = 6 }) end,
}


-- =======================================================================
-- EXOR SUPERIOR - HARD MODE (SpawnerData's SD.HardVariants fallback)
-- The plain Exor, escalated - it looks native and keeps every native move.
-- * Tougher torso, a slightly faster body, and a sixth quill in every burst
-- * Reloads half again as fast, and throws the Antegrav's slow seeker quill each time it does
-- =======================================================================

V["Exor Superior"] = {
    Id = 188,
    Base = "Exor",
    Assets = { ENUMS.ProjectileClasses.QuillSpear, ENUMS.DamageType.SharpExorQuill },   -- the seeker, as on the Antegrav

    -- Stats
    BasicStats = {
        HpTorso = 250,   -- 175
    },
    TimeDilation = 1.1,
    MirrorTimeDilation = true,   -- the reload retime rides CustomTimeDilation - mirror or it's server-only
    Stats = function(actor, opts)
        actor.MaxBurstFire = 6   -- 5
        actor.MaxAmmoCount = 24   -- 20
        pcall(function() actor.CurrentAmmoCount = 24 end) 

        AVU.ClearRadiationZone(actor)
    end,

    -- Triggers
    OnReload = H.SuperiorReload,   -- faster reload + a seeker quill
}


return V
