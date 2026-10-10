-- =======================================================================
-- CRYSTALLISK (Assassin)
--   * The look rides an overlay material, not a body tint - see CrystalliskHelpers for why.
-- =======================================================================
-- ABILITY MAP - NPC_Assassin
--   0 Idle
--   1 death animation
--
-- Not slots: DecloakBeforeFiringDelay / RecloakAfterFiringDelay are ranged-fire timing knobs.
-- Machinery: AnteNPCs/CrystalliskHelpers.lua   Full decode: AnNotes/AnteNPCs/Crystallisk.md
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local ENUMS = require("AnteData.Enums")
local STATE = require("AnteCore.State")
local G = require("AnteData.Items").Global
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local H = require("AnteNPCs.CrystalliskHelpers")

local V = {}


-- =======================================================================
-- OBSIDILISK
--   * Low health, shatters into mini crystallisks on death (5 in hard mode, 3 otherwise)
--   * Shardlings have a large death animation - we hide the body for it
-- =======================================================================

V["Obsidilisk"] = {
    Id = 28,
    Base = "Assassin",
    Assets = { ENUMS.Effects.NIAGARA_ASSASSIN_TRACER, H.OVERLAY_MAT, ENUMS.Anims.ASSASSIN_POWER_MELEE },
    SpawnDelay = 100,

    -- Appearance
    -- BodyScale = 1.2,
    Visuals = function(actor, assets)
        AVU.SetVisualScale(actor, FVector(1.2, 1.2, 1.2))
        H.SetOverlay(actor)
    end,
    ClientTick = true,   -- opt pure clients into running OnTick (for the overlay re-seat)

    -- Stats
    BasicStats = {
        HpHead = 5,   -- 50
        HpTorso = 5,   -- 100
        HpLeftArm = 50,   -- 100
        HpRightArm = 50,   -- 100
        HpLeftLeg = 50,   -- 100
        HpRightLeg = 50,   -- 100
        -- WalkSpeed = 90,
        SprintSpeed = 550,   -- 900
        -- MeleeDamage = 40,
        -- RangedDamage = 72,
    },

    Stats = function(actor, opts)
        H.StayDecloaked(actor, 1)
        AVU.ClearLoot(actor, true) -- no drops, its spawns drop items
    end,

    -- Triggers
    OnTick = H.OverlayTick,

    -- Shatter into Shardlings
    OnDeath = function(actor)
        if Utils.IsActorInvalid(actor) then return end

        local loc = actor:K2_GetActorLocation()
        if not loc then return end

        Utils.QueueWork(function() H.ShatterIntoShardlings(loc) end, 900)
    end,
}


-- =======================================================================
-- SHARDLING - spawns after Obsidilisk dies.
-- =======================================================================

local SHARD_TD = { Normal = 1.15, Hard = 1.3 }

V["Shardling"] = {
    Id = 29,
    Base = "Assassin",
    Assets = { ENUMS.Effects.NIAGARA_ASSASSIN_TRACER, H.OVERLAY_MAT, ENUMS.Anims.ASSASSIN_POWER_MELEE },
    SpawnDelay = 100,   -- shrink fast so it doesn't pop in full-size
    TimeDilation = SHARD_TD.Normal,

    -- Appearance
    Visuals = function(actor, assets)
        AVU.SetVisualScale(actor, FVector(H.SHARD_SCALE, H.SHARD_SCALE, H.SHARD_SCALE))
        H.SetOverlay(actor)
    end,
    ClientTick = true,

    -- Stats
    BasicStats = {
        HpHead = 30,   -- 50
        HpTorso = 30,   -- 100
        HpLeftArm = 5,   -- 100
        HpRightArm = 5,   -- 100
        HpLeftLeg = 5,   -- 100
        HpRightLeg = 5,   -- 100
        WalkSpeed = 200,   -- 90
        SprintSpeed = 500,   -- 900
        RangedDamage = 40,   -- 72
    },

    HardMode = {
        BasicStats = { HpHead = 50, HpTorso = 50, RangedDamage = 55 },
        TimeDilation = SHARD_TD.Hard,
    },

    Stats = function(actor, opts)
        H.StayDecloaked(actor, 1.5)
        AVU.ClearLoot(actor)

        -- The melee sweep fires on a WORLD-time apex while the swing animates on CustomTimeDilation,
        -- so a sped-up body checks past the contact pose and whiffs. Divide the apex back out.
        local td = STATE.HardModeNoMercy and SHARD_TD.Hard or SHARD_TD.Normal
        pcall(function()
            actor.MeleeHitApex = 0.25 / td
            actor.PowerMeleeHitApex = 0.3 / td
        end)
    end,

    -- Triggers
    OnTick = H.OverlayTick,

    -- Hide the body on death. Its anim is fullsize.
    OnDeath = function(actor)
        AVU.DropLoot(actor, { Pool = {
            { G.POWDERED_CRYSTAL, 1 },
            { G.THROWING_CRYSTAL, 2 },
        }, Radius = 125 })

        AVU.HideOnDeath(actor)
    end,
}


-- =======================================================================
-- GRAVILISK
--   * Inverted gravity: moves and attacks from the ceiling. AI can't path a WALL, so it only
--     works on a ceiling above navigable floor.
--   * Uncloaked, native assassin look (no dark-crystal overlay), ranged intact.
-- =======================================================================

local CRAWL_GRAV_SCALE = 1

V["Gravilisk"] = {
    Id = 117,
    Base = "Assassin",
    Assets = { ENUMS.Effects.NIAGARA_ASSASSIN_TRACER },
    SpawnDelay = 100,

    -- Appearance
    Visuals = function(actor, assets)
        AVU.SetVisualScale(actor, FVector(1.1, 1.1, 1.1))
    end,

    -- Stats
    BasicStats = {
        HpHead = 50,   -- 50
        HpTorso = 75,   -- 100
        HpLeftArm = 25,   -- 100
        HpRightArm = 25,   -- 100
        HpLeftLeg = 25,   -- 100
        HpRightLeg = 25,   -- 100
        RangedDamage = 80,   -- 72
        -- WalkSpeed = 90,   Sprint = 900, Melee = 40, Ranged = 72
    },

    HardMode = {
        BasicStats = { HpHead = 100, HpTorso = 125, RangedDamage = 100 },
    },

    Stats = function(actor, opts)
        H.StayDecloaked(actor, 1)  -- force visible, until it attacks
        AVU.SetSightSense(actor, 3000, 3000, 360)
        -- AVU.DisableAbility(actor, 1)
        Utils.QueueWork(function() H.StartCrawl(actor, CRAWL_GRAV_SCALE) end, 300)   -- slight delay
    end,

    -- Triggers
    OnTick = function(actor, totalTicks)
        if Utils.IsActorInvalid(actor) then return "REMOVE" end
        if actor.IsDead then return end
        -- reassert the flip periodically - combat anims can fight it
        if totalTicks % 50 == 0 then
            if Utils.IsActorInvalid(actor) or actor.IsDead then return "REMOVE" end
            AVU.SetCeilingGravity(actor, true, { UpScale = CRAWL_GRAV_SCALE, NudgeZ = 0 })
        end
    end,

    -- Restore normal gravity. Keeps a dying/ragdolling body sane and a stream-out re-use clean.
    OnDeath = function(actor)
        AVU.RestoreGravity(actor)
        AVU.DropLoot(actor, { Pool = {
            { G.THROWING_CRYSTAL, 3 },
        }, Radius = 125 })
    end,
}


return V
