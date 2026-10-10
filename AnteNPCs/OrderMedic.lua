-- =======================================================================
-- ORDER - MEDICS  (base "Grunt_Medic" = NPC_Soldier_Grunt_Medic)
--
-- MUST-KNOWS
--   * [AUTHORITY] Heal buffs DO work on NPCs: BuffObject_HealOverTime(_Faster) casts its
--     target to AAbiotic_Character_ParentBP_C (NPC_Base inherits it) -> Server_HealRandomLimb.
--   * DEAD END - bleeding an ally to lure the native medic AI. Allies fled the damage, it
--     only fired on already-damaged allies, and it stalled if the AI wouldn't path to the
--     bled ally. Replaced by the active chase below.
--   * DBNO allies are left to the native medic revive AI (GetNearbyNpcs excludes DBNO/dead).
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local ENUMS = require("AnteData.Enums")
local G = require("AnteData.Items").Global
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local ASSETS = require("AnteCore.AssetManager")

local LogDebug = Utils.LogDebug

local V = {}

-- =======================================================================
-- ABILITY MAP - NPC_Soldier_Grunt_Medic (row "Grunt_Medic", extends NPC_Soldier_Grunt)
--   0 Idle - none.  1 GRENADE - inherited but DISABLED (CanThrowGrenades = false; medics
--       never throw).  2/3 - EMPTY.
--   CanThrowGrenades = false feeds AdditionalAbilityCheck, which ignores the slot index, so it
--       blocks every slot here, not just the grenade. Drive new behavior from OnTick.
--   NOT a slot: REVIVE is its own BT task (BTT_ReviveAlly -> AttemptMedicRevive). 2.75s
--       montage, then revives a DBNO ally or strips Bleeding off a standing one. Ally pick
--       is a 5s controller poll (range 2000) into blackboard AllyTarget.
-- =======================================================================

-- =======================================================================
-- DIOSCORIDIAN
--   * A fast, low-DPS squad healer that actively runs to a wounded ally and treats it
--   * Its patients are the squad it AGGROED WITH: one ally scan on combat entry builds a
--     roster, and everything after that is a walk over that table
--   * Treatment = heal-over-time buff + a restorative-flask burst + the treat montage
--   * Re-asserts its own move toward the ally each tick to beat the combat BT, then
--     cools down and rejoins the fight
-- =======================================================================

-- The restorative flask's own heal-over-time buff (HealOverTime_Faster). Applied
-- DIRECTLY to the ally so the heal lands regardless of the flask AoE's filter.
local HEAL_BUFF = "Buff_Flask_UnstableHeal"

-- Who counts as "my squad" when the fight opens. MaxZ is ~one storey - the overlap is a true
-- 3D sphere, and a medic should not run upstairs for a garrison it never fought with.
local HEAL_ROSTER = { Range = 2000, MaxZ = 600 }

-- The heal loop itself: treat range, give-up time, cadence.
local HEAL_LOOP = {
    FxScale = FVector(0.6, 0.6, 0.6),   -- the restorative burst at the ally's feet, smaller than a thrown flask's
    Range      = 250,   -- treat once this close to the ally
    ReachTicks = 70,    -- give up approaching after ~7s (ally fled / unreachable)
    Cooldown   = 40,    -- ~4s between heals
    PickEvery  = 10,    -- ~1s between patient picks (a table walk now, not an overlap)
}

-- medic -> { target=, expires= } the ally it's running to treat (weak keys: GC'd medics drop)
local healTargets = setmetatable({}, { __mode = "k" })
-- medic -> FAST_TICK it may look for a new heal target again (post-heal cooldown)
local healCooldown = setmetatable({}, { __mode = "k" })
-- medic key -> the allies this fight opened with. ActorKey, NOT the wrapper: the combat hook
-- that fills it and the tick that reads it see different registrations of the same body.
local healRoster = {}


-- Has this ally lost any health? The roster is built before anyone is hurt, so the damage test
-- lives here rather than in the scan.
local function isWounded(npc)
    local ok, hp, maxhp = pcall(function()
        return npc:GetTotalHealth(), npc:GetMaxTotalHealth()
    end)
    return ok and hp and maxhp and hp < maxhp
end


V["Dioscoridian"] = {
    Id = 30,
    Base = "Grunt_Medic",
    Assets = { ENUMS.Components.SM_GLOWSTICK, ENUMS.Effects.FLASK_RESTORATIVE_BURST },

    -- Appearance
    Tint = {
        Color = FVector(12, 18, 18),
        -- Emissive = 20,
        -- EmissiveColor = FVector(15, 12, 15),
        Components = { "Helmet", "Gun" },
    },
    Visuals = function(actor, assets)
        local mesh = Utils.GetValidMesh(actor)
        if not mesh then return end
        mesh:SetScalarParameterValueOnMaterials(FName("Glass Opacity"), 0.85)

        -- Glowstick vials (chest + arm)
        local vial = ENUMS.Components.SM_GLOWSTICK
        AVU.AttachStaticMesh(actor, vial, "Spine2", {
            Location = FVector(-11, -35, 24), Rotation = FRotator(90, 355, 90),
            Scale = FVector(0.8, 0.8, 0.8), Color = FVector(1, 0.1, 0),
        })
        AVU.AttachStaticMesh(actor, vial, "Spine2", {
            Location = FVector(-1, -33, 26), Rotation = FRotator(90, 0, 90),
            Scale = FVector(0.8, 0.8, 0.8), Color = FVector(0.25, 0.1, 0),
        })
    end,

    -- Stats
    BasicStats = {
        HpHead = 140,   -- 120
        HpTorso = 180,   -- 150
        -- WalkSpeed = 130,
        SprintSpeed = 450,   -- 600
        -- MeleeDamage = 50,
        RangedDamage = 30,   -- 25
    },
    HardMode = { NoAggroAnim = true, BasicStats = { HpHead = 200, HpTorso = 250, SprintSpeed = 500 } },
    -- A medic that bleeds out mid-treatment is the one thing it cannot fix.
    DebuffsImmune = { ENUMS.Debuffs.Bleeding, ENUMS.Debuffs.SevereBleeding },
    TimeDilation = 1.2,
    Stats = function(actor, opts)
        -- The heal burst is multicast BY ASSET, so it has to be resident on the AUTHORITY - and a
        -- dedicated server runs no LoadAssets step for a def with no OnReady. Pinned, because the
        -- first heal can be minutes away.
        ASSETS.WarmPinned({ ENUMS.Effects.FLASK_RESTORATIVE_BURST })

        -- Single-shot bursts, big magazine (rarely reloads, low DPS)
        actor.GruntBurstCount = 3
        actor.GruntBurstTimeBetweenShots = 0.25
        actor.CurrentAmmoCount = 100
        actor.MaxAmmoCount = 100

        AVU.SetCanCrouch(actor, false)
    end,

    -- Triggers
    -- One SphereOverlap per fight - this marks who this will try to heal
    OnEnterCombat = function(actor)
        if Utils.IsActorInvalid(actor) then return end
        local key = Utils.ActorKey(actor)
        if not key then return end
        local loc = actor:K2_GetActorLocation()
        if not loc then return end

        healRoster[key] = AVU.GetNearbyNpcs(loc, HEAL_ROSTER.Range, {
            faction = actor.Faction, ignoreActor = actor, maxZ = HEAL_ROSTER.MaxZ,
        })
        LogDebug("Dioscoridian - roster of " .. #healRoster[key], SETTINGS.DEBUG_NPC_ACTIONS)
    end,

    OnExitCombat = function(actor)
        local key = Utils.ActorKey(actor)
        if key then healRoster[key] = nil end
    end,

    -- Heal loop: pick a wounded ally off the roster, RUN to it (overriding the combat BT), treat
    -- it, cool down, repeat. ~2/s so the approach override stays ahead of the BT's pull to the
    -- player.
    OnTick = function(actor, totalTicks)
        if Utils.IsActorInvalid(actor) then return "REMOVE" end
        if actor.IsDead or actor.IsDBNO or actor.Stunned then return end
        if totalTicks % 5 ~= 0 then return end

        local key = AVU.CachedFullName(actor)
        -- Out of combat there is nothing to heal-chase, and the roster belongs to the fight that
        -- built it: drop both and idle until it re-aggros.
        if not actor.CombatState then
            healTargets[actor] = nil
            if key then healRoster[key] = nil end
            return
        end

        local actorLoc = actor:K2_GetActorLocation()
        local m = healTargets[actor]

        if m then
            local target = m.target
            -- Drop the run if the ally is gone/down/dead or we've been chasing too long.
            if Utils.IsActorInvalid(target) or target.IsDead or target.IsDBNO
               or totalTicks > m.expires then
                healTargets[actor] = nil
                return
            end

            local tLoc = target:K2_GetActorLocation()
            if Utils.DistSq(actorLoc, tLoc) <= HEAL_LOOP.Range * HEAL_LOOP.Range then
                -- Reached the ally -> treat: heal-over-time buff + flask burst + the treat
                -- montage (AttemptMedicRevive also revives if the ally happens to be DBNO).
                Utils.AddBuff(target, HEAL_BUFF, false, 0, 0)
                Utils.RemoveBuff(target, ENUMS.Debuffs.Bleeding)   -- cure a bleed if it had one
                pcall(function() actor:AttemptMedicRevive(target) end)

                -- The restorative flask's own burst, played at the ally's feet on every machine.
                --   The heal is the buff above; a real flask only ever added this picture, and cost
                --   a projectile spawn in our drain to do it.
                AVU.BroadcastFX(FVector(tLoc.X, tLoc.Y, tLoc.Z - 80), ENUMS.Effects.FLASK_RESTORATIVE_BURST,
                    nil, HEAL_LOOP.FxScale)

                healTargets[actor] = nil
                healCooldown[actor] = totalTicks + HEAL_LOOP.Cooldown
                LogDebug("Dioscoridian - treated ally (heal + flask)", SETTINGS.DEBUG_NPC_ACTIONS)
            else
                -- Approach: re-assert a move toward the ally each tick to beat the combat BT.
                AVU.MoveOrder(actor, tLoc, HEAL_LOOP.Range * 0.6)
            end
            return
        end

        -- No target: pick a wounded ally off the roster (cooldown- + interval-gated). The walk
        -- rebuilds the roster around its survivors, so dead squadmates stop being held here.
        if totalTicks < (healCooldown[actor] or 0) then return end
        if totalTicks % HEAL_LOOP.PickEvery ~= 0 then return end

        local roster = key and healRoster[key]
        if not roster then return end

        local live, wounded = {}, {}
        for _, npc in ipairs(roster) do
            if Utils.IsActorValid(npc) and Utils.IsActorAlive(npc) then
                live[#live + 1] = npc
                if not npc.IsDBNO and isWounded(npc) then wounded[#wounded + 1] = npc end
            end
        end
        healRoster[key] = live
        if #wounded == 0 then return end

        local target = wounded[math.random(1, #wounded)]
        healTargets[actor] = { target = target, expires = totalTicks + HEAL_LOOP.ReachTicks }
        LogDebug("Dioscoridian - moving to heal ally", SETTINGS.DEBUG_NPC_ACTIONS)
    end,

    OnDeath = function(actor)
        local key = Utils.ActorKey(actor)
        if key then healRoster[key] = nil end
        AVU.DropLoot(actor, {
            { Pool = { { G.HEALING_SYRINGE, 1 } }, Radius = 125 },
            { Pool = {
                { G.ACID_SYRINGE, 1 },
                { G.DISTILLATION_VIGOROUS, 1 },
                { G.BANDAGE_T2, 1 },
            }, Count = 1, Radius = 125 },
        })
    end,
}

return V
