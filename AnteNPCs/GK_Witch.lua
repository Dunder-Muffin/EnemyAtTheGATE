-- =======================================================================
-- Gatekeeper Witch (row "Gatekeeper_Witch")
--
-- MUST-KNOWS
--   * Native kit: shotgun hitscan burst (1s cd), launching melee kick, jetpack leaps, projectile
--     dodge (EvadesProjectiles), medic revive. No grenade
--   * The grenade slot is a RED HERRING - CanThrowGrenades gates the ability slots, so NEVER
--     DisableGrenades on this base
--
-- ABILITY MAP
--   0 Idle - none    1 "grenade" slot = the ability-enable flag, no throw
--   2 - empty stub (cd 45); the medic-revive path rides it
--   3 JETPACK LEAP to the blackboard TargetLocation
--   NOT slots: shotgun (Grunt_FireBurst), kick (Broadcast_MeleeAttackImpact launch), dodge,
--   jetpack fire trail (Apocalyptic-only)
--
-- Machinery: AnteNPCs/GK_WitchHelpers.lua   Decode notes: AnNotes/AnteNPCs/GKWitch.md
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local ENUMS = require("AnteData.Enums")
local G = require("AnteData.Items").Global
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local ASSETS = require("AnteCore.AssetManager")
local H = require("AnteNPCs.GK_WitchHelpers")

local V = {}


-- =======================================================================
-- WARRIOR WITCH  (the kiter)
-- * "Damage before it gets to you": native shotgun chip + a light kick.
-- * The kick lands, shoves + concusses, and the backflip fires a slow plasma ball down the line
--     they were shoved along - flip and ball on one beat (WW_SWING_FIRE_MS).
-- * Between kicks she boosts in on diagonal jetpack hops (H.WarriorDash) instead of walking.
-- * Small fast-regen body shield. Breaking it while she charges in flings her back and staggers
--     her for half a second after she lands; re-break it between volleys.
-- * [HARD] That shell is up out of combat too, so the opening volley isn't free.
-- * Design history (v1-v7) + backflip post-mortem: AnNotes/AnteNPCs/GKWitch.md
-- =======================================================================

local WW_BODY_COLOR = FVector(6, 2, 1)
local WW_HELM_COLOR = FVector(4, 2, 1)

local WW_CHASE_RANGE   = 800   -- Warrior lunges from 8m (the shared default is 15m)
-- Fireball and backflip share ONE beat, deliberately: the flip is a bicycle kick and the ball
-- leaving with it is the moment the move reads from. What makes it land on a shoved target is the
-- ball being SLOW (WW_JET), not late - trailing it behind the flip just reads as a second attack.
-- The family value (H.KICK_SWING_FIRE_MS) keeps the Mother's Warrior aspect on the same beat.
local WW_SWING_FIRE_MS = H.KICK_SWING_FIRE_MS
local WWF_DELAY_MS     = 600   -- flip starts this long after the swing broadcast
local WW_RELOAD_RATE   = 2.5

V["Warrior Witch"] = {
    Id = 130,
    Base = "Gatekeeper_Witch",
    Assets = H.WARRIOR_ASSETS,   -- plasma ball + its impact chain, concussion, reload/flip montages

    -- Appearance
    -- [RENDERER] Crimson war paint (material swaps don't replicate).
    Visuals = function(actor)
        pcall(function()
            local mesh = Utils.GetValidMesh(actor)
            if mesh then mesh:SetVectorParameterValueOnMaterials(FName("Color"), WW_BODY_COLOR) end
        end)
        pcall(function() AVU.TintComponent(actor.Helmet, { Color = WW_HELM_COLOR }) end)
    end,

    -- Stats
    BasicStats = {
        HpHead   = 200,   -- 250
        HpTorso  = 300,   -- 250   (higher shield)
        WalkSpeed   = 200,   -- 200
        SprintSpeed = 500,  -- 600 -- ground only speed
        MeleeDamage = 80,    -- 50
        MeleeAttackRange = 200,   -- 150   (H.WarriorLoadout mirrors this onto the blackboard)
        RangedDamage = 16,   -- 20/pellet base
        RangedAttackCooldown = H.WW_SHOTGUN_CD,   -- 1
        -- Shield = 100 (fast regen)   -- 150
    },
    HardMode = { BasicStats = { HpHead = 250, MeleeDamage = 120, SprintSpeed = 555 } },
    TimeDilation = 1.2,
    MirrorTimeDilation = true,   -- the reload retime rides CustomTimeDilation - mirror or it is server-only
    Stats = H.WarriorLoadout,

    -- Triggers
    -- Shield-break poll + its recoil (every tick), the tree's reposition counters held down,
    -- long-range gap-close/un-stall and the mid-range strafe boost, plus an off-peak keep-warm (S3).
    OnTick = function(actor, totalTicks)
        if Utils.IsActorInvalid(actor) then return "REMOVE" end
        if totalTicks % 600 == 11 then ASSETS.WarmPinned(H.WARRIOR_ASSETS) end
        H.WarriorShieldPoll(actor)
        H.WarriorRecoilTick(actor)
        if totalTicks % 5 ~= 0 then return end
        H.WarriorAggression(actor)
        H.Aggro(actor, WW_CHASE_RANGE)
        H.WarriorDash(actor)
    end,

    -- KICK SWING (hit or miss): fireball + backflip on one beat, but queued INDEPENDENTLY - each
    -- owns its own gate (chained, the ball's 900ms gate silently ate flips - AnNotes/AnteNPCs/GKWitch.md).
    --   * The montage is re-warmed here: PlayMontageReplicated is a silent no-op on a GC'd asset.
    OnMeleeSwing = function(actor)
        if Utils.IsActorInvalid(actor) then return end
        ASSETS.WarmPinned({ ENUMS.Anims.INTERFECTOR_DODGE_BACK })
        Utils.QueueWork(function() H.WarriorKickSwing(actor, { Jet = true }) end, WW_SWING_FIRE_MS)
        Utils.QueueWork(function() H.WarriorBackflip(actor) end, WWF_DELAY_MS)
    end,

    OnMeleeImpact = H.WarriorImpact,

    -- Faster reload via CustomTimeDilation (montage rate is server-local); safe since a reload locks in place.
    OnReload = function(actor) AVU.ReloadDilation(actor, WW_RELOAD_RATE) end,

    OnDeath = function(actor)
        H.WarriorCleanup(actor)
        AVU.DropLoot(actor, {
            Pool = {
                { G.HEXWOOD, 2 },
                { G.SCRAP_ARCANE, 1 },
                { G.TRANSCENDIUM, 2 },
            }, Radius = 40,
        })
    end,
}


-- =======================================================================
-- STORM WITCH  (airborne electric)
-- * An electro-gun replaces the shotgun: one hitscan bolt per attack.
-- * IT DOES NOT BRAWL. H.StormStandoff holds the tree's melee gate shut, so reaching a target
--     means jetpacking somewhere else - and every one of those hops is another nova and another
--     grenade window. Slow on foot and floaty in the air; the fight happens at range.
-- * Electric nova on a takeoff, and on a connecting kick without the stun.
--     Damages players only; NPC radial damage can freeze the hooks (CLAUDE.md S6).
-- * From the top of the arc it throws a shock pulse grenade at a fuzzed point near its target:
--     a flat bullet-fast shot that lands inert and rings every 2s until it burns out. Two live
--     at once, so there is no single spot to stand.
-- * [HARD] Its shell is up out of combat, so the opening volley isn't free.
-- * Most of her health is the shell: 550 (700 hard) over 250 + 250.
-- =======================================================================

V["Storm Witch"] = {
    Id = 132,
    Base = "Gatekeeper_Witch",
    Assets = H.STORM_ASSETS,   -- bolt/nova FX + damage type, electrothrower + crystal crown

    -- Appearance
    Visuals = H.StormLook,

    -- Stats
    BasicStats = {
        HpHead   = 150,   -- 250
        HpTorso  = 150,   -- 250
        WalkSpeed   = 160,   -- 200
        SprintSpeed = 350,   -- 600 -- only affects ground speed
        MeleeDamage = 50,    -- 50
        RangedDamage = 40,   -- 20/pellet - attack is instead one electricity arc
        -- Shield = 550 (hard 700), --150
    },
    HardMode = {
        RangedDamage = 60
    },
    Stats = H.StormLoadout,

    -- Triggers
    -- Keep the bolt/nova deps warm off-peak; hold the melee gate shut so arrival means a hop; and
    -- keep the pressure on - the shared gap-closer + stall backstop reels her in after a long arc.
    OnTick = function(actor, totalTicks)
        if Utils.IsActorInvalid(actor) then return "REMOVE" end
        if totalTicks % 600 == 23 then ASSETS.WarmPinned(H.STORM_ASSETS) end
        if totalTicks % 5 ~= 0 then return end
        H.StormStandoff(actor)
        H.Aggro(actor)
    end,

    OnRangedAttack = H.StormRangedAttack,   -- the suppressed shotgun's replacement bolt
    OnMeleeImpact = H.StormImpact,          -- stunless nova on a connecting kick...
    OnJetpack = H.StormJetpack,             -- ...and on a deliberate takeoff, plus the shock grenade

    OnDeath = function(actor)
        H.StormCleanup(actor)
        AVU.DropLoot(actor, {
            Pool = {
                { G.CAPACITOR, 3 },
                { G.TRANSCENDIUM, 1 },
                { G.PROJECTION_MATRIX, 1 },
            }, Radius = 40,
        })
    end,
}


-- =======================================================================
-- PLAGUE WITCH
-- * Throws a mini-Pestilence down from the top of its jetpack arc (10s cd, max 3 alive).
--     It lands parked for 3s (2s in hard) before it aggros, so the drop is readable
-- * Fires homing quill bolts instead of shotgun shells, and each one hits HARDER the more
--     debuffs its target is already carrying - 20 on a clean target, up to 120 at 7+
-- * Drops a 24s bee cloud every ~12s in combat, at a fuzzed point near its target
-- * [HARD] Its shell is up out of combat, so the opening volley isn't free.
-- =======================================================================

V["Plague Witch"] = {
    Id = 133,
    Base = "Gatekeeper_Witch",
    Assets = H.PLAGUE_ASSETS,   -- bee/spore FX, quill class + rifle, fungal armour pieces

    -- Appearance
    Visuals = H.PlagueLook,

    -- Stats
    BasicStats = {
        HpHead   = 250,   -- 250
        HpTorso  = 250,   -- 250
        WalkSpeed   = 200,   -- 200
        SprintSpeed = 500,   -- 600
        MeleeDamage = 50,    -- 50
        RangedDamage = 20,   -- 20/pellet base (one hard-homing quill per attack)
        -- RangedAttackCooldown - PW_QUILL_CD_TCK
        -- Shield = 150
    },
    -- RangedDamage is the CLEAN-target rung of the quill ladder (PW_QUILL_DMG in the helpers,
    -- picked per shot); a HardMode override has to move both.
    HardMode = {
        BasicStats = {
            HpHead   = 350,      -- 250
            HpTorso  = 350,      -- 250
            SprintSpeed = 600,   -- 500
            RangedDamage = 30,   -- 20
        },
    },
    -- Its own cloud must never sting it (faction already protects it; belt and braces).
    DebuffsImmune = { ENUMS.Debuffs.BeeSwarm },
    Stats = H.PlagueLoadout,

    -- Triggers
    -- Keep the kit warm off-peak + the periodic bee cloud (2/s poll).
    OnTick = function(actor, totalTicks)
        if Utils.IsActorInvalid(actor) then return "REMOVE" end
        if totalTicks % 600 == 37 then ASSETS.WarmPinned(H.PLAGUE_ASSETS) end
        if totalTicks % 5 ~= 0 then return end
        H.PlagueCloudPoll(actor)
    end,

    OnRangedAttack = H.PlagueRangedAttack,   -- the suppressed shotgun's replacement quill
    OnJetpack = H.PlagueJetpack,             -- the apex mini toss

    OnDeath = function(actor)
        H.PlagueCleanup(actor)
        AVU.DropLoot(actor, {
            Pool = {
                { G.LODESTONE_FRAGMENT, 1 },
                { G.MUSHROOM, 2 },
                { G.HEXWOOD, 3 },
            }, Count = 2, Radius = 40,
        })
    end,
}

return V
