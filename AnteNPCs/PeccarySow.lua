-- =======================================================================
-- Peccary Sow variant (base "Sow" = NPC_Peccary_Sow).
-- 
--
-- The Sow is the tail-throw peccary that lobs projectile_carbunclebomb. The Hive Sow carries an
-- alien beehive on the tail and turns that ranged throw into a bee-swarm delivery:
--   1. it throws -> we wait the bomb's travel, then drop a spore "cloud" WHERE THE TARGET WAS
--      WHEN IT FIRED, so the cloud is dodgeable (it lands where the bomb was aimed, not where
--      the player ran to);
--   2. after an escape window, players/NPCs within RADIUS of the cloud get Debuff_BeeSwarm,
--      re-stung every interval until the cloud expires.
-- The machinery is shared with the tamed pet form and lives in AnteNPCs/PeccarySowHelpers.
--
-- MUST-KNOWS
--   * A CLASS HOOK, not OnDealtDamage: the carbunclebomb's damage doesn't attribute its
--     DamageCauser to the Sow, so ProcessDamage can't see it. We hook
--     NPC_Peccary_Sow_C:Server_DoRangedAttack (CombatHooks "Sow") -> OnRangedAttack.
--   * ApplyBuffLinked, not AddBuff: Server_TryApplyBuff (AddBuff) gates on Is_Locally_Controlled
--     and silently no-ops when a server script buffs a PLAYER; ApplyBuffLinked calls
--     Server_ApplyBuff directly (the beehive's own path).
--   * BeeSwarm REQUIRES a valid LinkedActor - it self-removes / disperses >2000u from it. Stings
--     link to the OWNER sow (the cloud is location-anchored, not an actor).
--   * [RENDERER] the spore + BEE_SWARM visuals ride the ClientFX channel (SendClientFX ->
--     SpawnLocalNiagara in AnteVariants/ClientEffects): each renderer spawns its own local
--     Niagara, because a server-spawned custom particle system doesn't replicate.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local G = require("AnteData.Items").Global
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local HIVE = require("AnteNPCs.PeccarySowHelpers")    -- the shared bee-cloud kit

local LogDebug = Utils.LogDebug

local V = {}

-- =======================================================================
-- ABILITY MAP - NPC_Peccary_Sow (row "Sow", extends NPC_Monster_Peccary)
--   0 PLANT_CARBUNCLE - the base peccary IDLE plant, with CarbuncleSpawnClass swapped to
--       the TAINTED carbuncle. Cooldown_IdleAbility = 150s (pre-armed at ~75-88% on
--       spawn); suppressed by a "Buff.Follower" tag (tamed sows don't plant), by a
--       "nodeploy"/"nocarbuncle" surface tag, and by a 1-per-1000uu density cap.
--       AVU.DisableAbility(actor, 0) pins it off.
--   1 CHARGE - the base peccary stampede, unmodified (WalkSpeed 4500, 4s, 12s CD).
--       AVU.DisableAbility(actor, 1) pins it off.
--   2 - EMPTY      3 - EMPTY   (free to claim)
-- NOT a slot: the Sow's BOMB LOB is the RANGED path (Server_DoRangedAttack ->
-- FireRanged_Projectile with row "projectile_carbunclebomb"); milking is an interact
-- (HarvestingComponent / LongInteractWith_A).
-- =======================================================================

-- The slots to pin OFF (see the ABILITY MAP).
local ABILITY_PLANT_CARBUNCLE = 0
local ABILITY_CHARGE          = 1


-- =======================================================================
-- HIVE SOW  (base "Sow")
-- * Replaces its attack with a lingering bee cloud
-- * Melee and standing in a bee cloud apply a 2s bee sting debuff
-- * Throws on a floor cadence, so the cloud keeps coming even when it is walked down
-- * Holds throwing distance rather than chasing; no stampede (that only delivered it into melee)
-- =======================================================================

-- The throw is ROW-DRIVEN (FireRanged_Projectile(actor.ProjectileRow)); the bee CLOUD (OnRangedAttack)
-- is the real attack, the thrown ball is pure noise. An INVALID row name makes FireRanged_Projectile
-- skip the spawn silently (throw anim + bee cloud still play) - point it at a valid DT_Projectiles
-- row (e.g. gravity-0 "projectile_electroncrystal") instead for a real, hard-to-notice bolt.
local HIVE_SOW_PROJECTILE = "None"   -- invalid row -> FireRanged_Projectile spawns nothing

local HIVE_SOW_YAW_RATE = 410   -- 360

-- [HARD] A shorter escape window before a cloud starts stinging (the shared kit's default is 2000ms).
local HIVE_SOW_HARD_APPLY_DELAY = 1500

V["Hive Sow"] = {
    Id = 22,
    Base = "Sow",
    Assets = { ENUMS.Components.SM_BEEHIVE,
               ENUMS.Effects.SPORES_PECCARY_SHAKE,
               ENUMS.Effects.BEES },
    TamedVariant = "Tamed Hive Sow",        -- PetManager re-mutates a tamed Hive Sow into the pet form

    -- Appearance
    Tint = { Color = FVector(0.9, 0.7, 0.2), EmissiveColor = FVector(0.8, 0.9, 0), Emissive = 15 },
    -- [RENDERER] honey tint + beehive prop + bee swarm on the tail.
    Visuals = function(actor, assets)
        -- Beehive on the tail tip (cosmetic)
        AVU.AttachStaticMesh(actor, ENUMS.Components.SM_BEEHIVE, "Tail4", {
            Location = FVector(0, 0, 0),
            Rotation = FRotator(90, 90, 0),
            Scale = FVector(0.75, 0.75, 0.75),
        })

        -- REDUCE_VISUALS: hide the tail bee swarm niagara
        if not SETTINGS.GAMEPLAY.REDUCE_VISUALS then
            AVU.AttachNiagara(actor, ENUMS.Effects.BEES, "Tail3", {})
        end
    end,

    -- Stats
    BasicStats = {
        HpHead = 300,   -- 150
        HpTorso = 200,   -- 100
        WalkSpeed = 250,   -- 200
        SprintSpeed = 600,   -- 900
        MeleeDamage = 90,   -- 65
        -- RangedDamage = 15,
    },
    -- Faster ranged cadence, stronger melee as a deterrent, BeeSwarm-immune.
    DebuffsImmune = { ENUMS.Debuffs.BeeSwarm },
    HardMode = {
        TimeDilation = 1.1,
    },
    Stats = function(actor, opts)
        local npcData = actor.NPCData
        if IsNotValid(npcData) then return end

        -- Written here, so the hard value is picked here (BasicStats cannot reach this field).
        actor.RangedAttack_Cooldown = STATE.HardModeNoMercy and 1 or 1.5

        -- The tightest pounce window the tree allows: it opens at this + a hardcoded 200, so 1
        -- means the sow has to be touching you to swing (native 250 lets it lunge from 450).
        npcData[ENUMS.NpcData.MeleeAttackRange] = 1

        -- Replace the thrown projectile (see HIVE_SOW_PROJECTILE)
        AVU.SetProjectileRow(actor, "ProjectileRow", HIVE_SOW_PROJECTILE, true)

        -- Bump BeeSwarm's NPC damage NOW (at spawn) so the CDO is tuned before the first sting creates
        -- a buff instance at the stock 0.2. (Doing it lazily on first sting was too late.)
        HIVE.TuneBeeDamage()

        AVU.DisableAbility(actor, ABILITY_PLANT_CARBUNCLE)
        -- The stampede is a gap-closer: it lands the sow in the band where its tree can only melee,
        -- which is the one place the bee cloud is not its attack.
        AVU.DisableAbility(actor, ABILITY_CHARGE)

        -- Snappier yaw: the throw opens with TurnTowardsTarget, so a slow turn spends the windup
        -- facing the wrong way.
        local move = actor.CharacterMovement
        if IsValid(move) then
            pcall(function() move.RotationRate = FRotator(0, HIVE_SOW_YAW_RATE, 0) end)
        end
    end,

    -- Triggers
    -- * KeepRange() - plants it at throwing distance instead of letting it run players down
    -- * ForceThrow() - a floor on the bee cloud, for when something walks it down anyway
    OnTick = function(actor, totalTicks)
        if Utils.IsActorInvalid(actor) then return "REMOVE" end
        if totalTicks % 5 ~= 0 then return end
        HIVE.KeepRange(actor)
        HIVE.ForceThrow(actor)
    end,

    -- The tail-throw bee cloud (shared with the tamed Hive Sow; see AnteNPCs/PeccarySowHelpers).
    -- ForceThrow re-enters this hook too, so its clouds take the same [HARD] window.
    OnRangedAttack = function(actor)
        HIVE.RangedAttack(actor, STATE.HardModeNoMercy and { ApplyDelay = HIVE_SOW_HARD_APPLY_DELAY } or nil)
    end,

    -- 2s bee swarm on melee
    OnDealtDamage = function(attacker, victim) HIVE.MeleeSting(victim, attacker) end,

    OnDeath = function(actor)
        HIVE.Forget(actor)
        AVU.DropLoot(actor, {
            { Pool = {
                { G.HONEY, 2 },
                { G.WAX, 2 },
            } },
            { Pool = {
                { G.HONEY, 1 },
                { G.HONEY, 2 },
                { G.WAX, 1 },
                { G.WAX, 2 },
            }, Count = 1 },
        })
    end,
}


-- =======================================================================
-- ABILITY MAP - NPC_Monster_Peccary_Snow (row "Peccary_Snow", extends NPC_Monster_Peccary)
--   0 PLANT_CARBUNCLE - the base peccary IDLE plant, CarbuncleSpawnClass swapped to the TAINTED
--       carbuncle (same as the Sow). AVU.DisableAbility(actor, 0) pins it off.
--   1 CHARGE - the base peccary stampede, PLUS a Snow-only override: Server_EndChargeImpact
--       applies Debuff_Frost (1.75s) to every character inside AOE_RadialForce.Radius that it has
--       line of sight to. Its ChargeDamageType is Cold (base peccary is Psychic).
--   2 - EMPTY      3 - EMPTY
-- =======================================================================


-- =======================================================================
-- WHITEOUT PECCARY  (base "Peccary_Snow")
-- Longer charge cooldown but causes a whiteout when charging up
--   * Drops a short WHITEOUT on its TARGET the instant the charge windup starts (AVU.TriggerBlizzard) 
-- =======================================================================

-- Creates a snowstorm when charging
local WHITEOUT_STORM_S    = 3
local WHITEOUT_STORM_SIZE = 2000   -- half-extents (the Yeti's regular smash-storm size)

-- Charge pacing
local WHITEOUT_CHARGE_CD    = 15     -- 12 native
local WHITEOUT_CHARGE_TICKS = 150

-- Charge band (uu). Too close and the stampede has no run-up; too far and it arrives spent.
local WHITEOUT_MIN = 600
local WHITEOUT_MAX = 3000
local WHITEOUT_MIN_SQ = WHITEOUT_MIN * WHITEOUT_MIN
local WHITEOUT_MAX_SQ = WHITEOUT_MAX * WHITEOUT_MAX

-- Ice-ball cadence between charges (native RangedAttack_Cooldown on this row is longer).
local WHITEOUT_RANGED_CD = 2.5

-- Projectile replacement: one frost shell per throw.
local WHITEOUT_SHELL = {
    Count      = 1,
    Damage     = 45,
    MaxRange   = 4000,
    FreezeSecs = 2,
    Socket     = "RangedSocket",   -- the peccary's ProjectileFireSocket
}
-- THROW_MS: the native fire sequence is turn -> 0.5s -> AboutToThrow -> 0.5s -> fire, so the
-- shell leaves at ~1s to land on the tail-throw animation rather than the hook.
local WHITEOUT_THROW_MS = 1000

-- Invalid row = FireRanged_Projectile skips the spawn
local WHITEOUT_NO_BALL = "None"

local lastWhiteoutCharge = {}   -- ActorKey -> FAST_TICK of last forced charge

-- [AUTHORITY] Force the charge when our gate says it is due.
--   * No cooldown check exists anywhere on this path, so the gate is ours - same period as
--     Cooldown_CombatAbility1 so we never double up with the BT.
--   * DelayedGameThread keeps the montage/movement writes out of the tick-hook drain
--     ([[anteup2-velites-reentrancy-crash]]); a 0ms delay is NOT a thread hop, hence 50.
local CHARGE_HOP_MS = 50

local function whiteoutTryCharge(actor, target)
    local key = Utils.ActorKey(actor)
    if not key then return end
    if not AVU.CooldownReady(lastWhiteoutCharge, key, WHITEOUT_CHARGE_TICKS) then return end

    local dsq = Utils.DistSq(actor:K2_GetActorLocation(), target:K2_GetActorLocation())
    if dsq < WHITEOUT_MIN_SQ or dsq > WHITEOUT_MAX_SQ then
        LogDebug(string.format("Whiteout Peccary - charge ready but %.0fuu is outside the band",
            math.sqrt(dsq)), SETTINGS.DEBUG_NPC_ACTIONS)
        return
    end

    Utils.DelayedGameThread(CHARGE_HOP_MS, function()
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        if actor.IsStampeding then return end          -- already running one
        actor:Broadcast_CombatAbility1()
        LogDebug("Whiteout Peccary - forced charge fired", SETTINGS.DEBUG_NPC_ACTIONS)
    end)
end

V["Whiteout Peccary"] = {
    Id = 153,
    Base = "Peccary_Snow",
    -- Warm the FULL blizzard dep set (the first storm blocking-loads otherwise, S2) + the
    -- frost-shell deps (must be warm BEFORE the first throw, S2/S3).
    Assets = (function()
        local a = {}
        for _, p in ipairs(AVU.BLIZZARD_ASSETS) do a[#a + 1] = p end
        for _, p in ipairs(AVU.FROST_SHELL_DEPS) do a[#a + 1] = p end
        return a
    end)(),

    -- Appearance
    BodyScale = { X = 1.15, Y = 1.15, Z = 1.1 },
    Tint = { Color = FVector(5, 5, 5), EmissiveColor = FVector(0.4, 0.75, 1), Emissive = 20 },

    -- Stats
    BasicStats = {
        HpHead = 350,   -- 400
        HpTorso = 300,   -- 300
        WalkSpeed = 175,  -- 200
        SprintSpeed = 650, --900
        MeleeDamage = 90,   -- 65
        RangedDamage = 70 -- 15,
    },
    HardMode = {
        BasicStats = { HpHead=400, HpTorso=350, SprintSpeed=800, RangedDamage=100 }
    },
    DebuffsImmune = { ENUMS.Debuffs.Frost, ENUMS.Debuffs.Frost2, ENUMS.Debuffs.Frost3,
                      ENUMS.Debuffs.Frost4, ENUMS.Debuffs.Frost5, ENUMS.Debuffs.FlaskBlizzard },
    Stats = function(actor, opts)
        -- Long charge cooldown, fast throw in between (the charge reads Cooldown_CombatAbility1
        -- when it cools ITSELF down, so the field write is enough).
        pcall(function() actor.Cooldown_CombatAbility1 = WHITEOUT_CHARGE_CD end)
        pcall(function() actor.RangedAttack_Cooldown = WHITEOUT_RANGED_CD end)

        -- Frost shell replaces the short-falling ice ball
        AVU.SetProjectileRow(actor, "ProjectileRow", WHITEOUT_NO_BALL, true)

        -- PINNED before the first throw
        AVU.WarmFrostShells()

        AVU.DisableAbility(actor, ABILITY_PLANT_CARBUNCLE)
        
        local move = actor.CharacterMovement
        if IsValid(move) then
            pcall(function() move.MaxAcceleration = move.MaxAcceleration * 0.6 end)
        end

    end,

    -- Triggers
    OnCharge = function(actor)
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        local target = actor:GetCurrentCombatTarget()
        local at = Utils.IsActorInvalid(target) and actor or target
        local loc = at:K2_GetActorLocation()
        if not loc then return end
        AVU.TriggerBlizzard(loc, { Duration = WHITEOUT_STORM_S, Size = WHITEOUT_STORM_SIZE })
        LogDebug("Whiteout Peccary - snowstorm on charge target", SETTINGS.DEBUG_NPC_ACTIONS)
    end,

    -- One frost shell that actually reaches (see the knobs), delayed to land on the tail-throw
    -- animation rather than the hook.
    OnRangedAttack = function(actor)
        Utils.QueueWork(function()
            if Utils.IsActorInvalid(actor) or actor.IsDead then return end
            AVU.FrostShells(actor, WHITEOUT_SHELL)
        end, WHITEOUT_THROW_MS)
    end,

    -- Charge as soon as our gate opens. 5-tick cadence is ample - the gate itself is 150 ticks.
    OnTick = function(actor, totalTicks)
        if totalTicks % 5 ~= 0 then return end
        if Utils.IsActorInvalid(actor) then return "REMOVE" end
        if not actor.CombatState then return end
        if actor.IsStampeding then return end

        local target = actor:GetCurrentCombatTarget()
        if Utils.IsActorInvalid(target) then return end

        whiteoutTryCharge(actor, target)
    end,
}


return V
