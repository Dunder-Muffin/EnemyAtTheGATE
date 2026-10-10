-- =======================================================================
-- ORDER - BREACHERS  (base "Grunt_Shotgun" = NPC_Soldier_Grunt_Shotgun)
--
-- MUST-KNOWS
--   * The breacher walks its target down firing a hitscan shotgun spread and stands still
--     to reload. Exact numbers in the ABILITY MAP below.
--   * The pellet count/spread and the 1s gap between attacks are hardcoded in Grunt_FireBurst
--     - not stats we can set. What IS reachable is the beat before it: the shared soldier
--     Server_DoRangedAttack fires def.OnRangedAttack once per shell, PRE, so CurrentAmmoCount
--     there is still the pre-shot count. The Skirmisher's dance hangs off that.
--   * Machinery lives in AnteNPCs/OrderBreacherHelpers.lua.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local AVU = require("AnteUtils.AVUtils")
local ENUMS = require("AnteData.Enums")
local G = require("AnteData.Items").Global
local H = require("AnteNPCs.OrderBreacherHelpers")

local V = {}

-- =======================================================================
-- ABILITY MAP - NPC_Soldier_Grunt_Shotgun (row "Grunt_Shotgun", extends NPC_Soldier_Grunt)
--   0 Idle - none
--   1 GRENADE - inherited UNCHANGED from the Grunt (projectile_fraggrenade, 10s CD,
--       LoS-gated). Its controller does NOT set CanThrowGrenades = false, so breachers
--       really do throw frags. AVU.DisableGrenades(actor) == AVU.DisableAbility(actor, 1).
--   2 - EMPTY      3 - EMPTY   (free to claim)
-- NOT a slot: the shotgun blast is the ranged path (Grunt_FireBurst = 10 hitscan pellets
-- at BulletSpread 20, MaxAmmoCount 8, then a 1s recovery).
-- =======================================================================

-- =======================================================================
-- SWEEPER
--   * Tankier, shrugs off staggers, and extended clip with a fast reload
--   * Has a very slow turn rate 
-- =======================================================================

V["Sweeper"] = {
    Id = 34,
    Base = "Grunt_Shotgun",
    NoAggroAnim = true,
    Assets = {},

    -- Appearance
    -- Bigger body scales up the hitbox too, not just the model.
    BodyScale = 1.1,
    -- No baseline dilation; the flag is here so OnReload's ReloadDilation reaches clients.
    MirrorTimeDilation = true,
    Tint = { Color = FVector(0.25, 0.05, 0.05) },
    Visuals = function(actor, assets)
        -- Larger shotgun
        pcall(function()
            if IsValid(actor.Gun) then actor.Gun:SetRelativeScale3D(FVector(1.5, 1.5, 1.5)) end
        end)
    end,

    -- Stats
    BasicStats = {
        HpHead = 225,   -- 150
        HpTorso = 175,   -- 200
        WalkSpeed = 160,   -- 130
        SprintSpeed = 160,   -- 160
        -- MeleeDamage = 60,
        RangedDamage = 37,   -- 33
    },
    TimeDilation = 0.85,
    HardMode = {
        BasicStats = { HpHead = 300, HpTorso=225, WalkSpeed=200, SprintSpeed=200, RangedDamage = 42 },   -- 200 / 150 / 35
    },
    Stats = function(actor, opts)
        local move = actor.CharacterMovement
        if IsNotValid(move) then return end

        -- Much slower turn rate
        move.RotationRate = FRotator(0, STATE.HardModeNoMercy and 150 or 125, 0)

        actor.CurrentAmmoCount = 10
        actor.MaxAmmoCount = 10

        -- Long stagger cooldown = it can only be staggered every 20s; arm it immediately
        actor.StaggerCooldown = 20
        actor:ForceStaggerOnCooldown()

        AVU.DisableGrenades(actor)
    end,

    -- Triggers
    -- Faster reload; needs MirrorTimeDilation above to reach clients.
    OnReload = function(actor) AVU.ReloadDilation(actor, 1.3) end,

    OnDeath = function(actor)
        AVU.DropLoot(actor, {
            { Pool = {
                { G.MILITARY_ELEC, 2 },
                { G.AMMO_12G, 2 },
            } },
            -- Heavier armor salvage once past Anteverse B (StoryProgress >= 34).
            { Pool = { { G.SCRAP_KEVLAR, 2 } }, MinStory = 34 },
        })
    end,
}


-- =======================================================================
-- SKIRMISHER
--   * A fast, lighter, weaker breacher that refuses to close: it gives ground inside 8m and
--     rolls clear of anything that reaches swinging range
--   * Its shotgun is a dance - it rolls aside off the opening shell, sometimes off the third,
--     and hops backwards as the clip runs dry
--   * Small clip, so it reloads often - and stands still while it does (its opening)
--   * Sidesteps incoming projectiles outright, on a long cooldown
-- =======================================================================

V["Skirmisher"] = {
    Id = 35,
    Base = "Grunt_Shotgun",
    Assets = {
        ENUMS.Anims.GK_DODGE_LEFT,
        ENUMS.Anims.GK_DODGE_RIGHT,
        ENUMS.Anims.GK_DODGE_BACK,
        ENUMS.Anims.GRUNT_STAGGER_BACK,
    },

    -- Appearance
    BodyScale = 0.95,
    Tint = { Color = FVector(0.7, 0.2, 1) },

    -- Stats
    BasicStats = {
        HpHead = 200,   -- 150
        HpTorso = 150,   -- 200
        WalkSpeed = 200,   -- 130
        SprintSpeed = 300,   -- 160
        -- MeleeDamage = 60,
        RangedDamage = 27,   -- 33
    },
    TimeDilation = 0.9,
    MirrorTimeDilation = true,   -- the reload retime rides CustomTimeDilation - mirror or it is server-only
    HardMode = {
        NoAggroAnim = true,
        TimeDilation = 1.0,
        BasicStats = {
            HpHead = 250, HpTorso = 200,
            WalkSpeed = 350, SprintSpeed = 350,
            RangedDamage = 33,
        },
    },
    Stats = H.SkirmisherStats,

    -- Triggers
    OnTick = H.SkirmisherTick,
    OnRangedAttack = H.SkirmisherShot,
    OnReload = H.SkirmisherReload,

    OnDeath = function(actor)
        AVU.DropLoot(actor, {
            { Pool = {
                { G.SCRAP_LEATHER, 2 },
            } },
            { Pool = { { G.CARBON_PLATING, 1 } }, MinStory = 34 },
        })
    end,
}



return V
