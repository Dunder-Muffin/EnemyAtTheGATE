-- =======================================================================
-- Sniper helpers - the machinery behind AnteNPCs/OrderSniper.lua
--
-- MUST-KNOWS
--   * [RENDERER] Almost no cosmetic surface: helmet is a NO-OP override. What's left: body mesh,
--     laser, mesh/material SWAPS on actor.Gun (see PraetorRifle), and the rifle's DiffuseColor
--     (see TintRifle - its master declares no "Color"/"Tint", which is why tint looked dead here).
--   * `/dumpmat` lists params WRITTEN, not EXPOSED - a name showing up there is not proof you can set it.
--   * [RENDERER] Ships 4 HealthTextures, so injury stages rebuild the torso material and drop
--     tint. Re-assert from OnDamageTaken (authority/host) AND ClientTick (clients get no damage hook).
--   * Vanish is shared via H.SniperVanish(actor, target, cfg). Stun carries past the hop; the
--     laser RAMPS back as the "recharging" tell (brightness is the only lever - the FSM stomps HideLaser).
--   * SetColorParameter's name arg MUST be an FName - a raw string AVs uncatchably.
--   * Soldier BT rules apply here - see CLAUDE.md [[anteup2-soldier-bt-flee-accuracy]].
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local NpcSpawner = require("AnteCore.NpcSpawner")
local GRP = require("AnteNPCs.OrderGroupeHelpers")   -- the shared wash/fade kit
local ASSETS = require("AnteCore.AssetManager")
local Placement = require("AnteCore.Placement")

local LogDebug = Utils.LogDebug
local LogBad = Utils.LogBad

local H = {}


-- The whole ranged identity of a sniper, in one call. Every field here is a pawn property that
-- BeginPlay difficulty-scales, so this only sticks from OnReady/Stats - after it has run.
--
-- The shot cone is `(Misses - landedMissCount) + steady-or-sprint`, floored at 0, in DEGREES.
-- The miss count resets to 0 on every LANDED hit and on any combat-state flip, so a sniper walks
-- its rounds in, connects, and starts over - that cycle is the mechanic, not an acquisition delay.
-- A round that eats cover counts as a miss, so hiding tightens its aim.
--   Misses    how many degrees wide the cone opens after a hit; also how many shots it takes to
--             converge, since each miss narrows it by one.
--   Sprint    {min,max} degrees added while the target sprints or has just been acquired - the
--             only knob that makes running away worth anything.
--   Steady    the cone added when the target is standing still.
--   Cooldown  seconds between shots.
function H.SetAccuracy(actor, opts)
    if Utils.IsActorInvalid(actor) then return end
    if opts.Misses   then pcall(function() actor.Accuracy_RequiredFailedHits = opts.Misses end) end
    if opts.Steady   then pcall(function() actor.Accuracy_Default = opts.Steady end) end
    if opts.Cooldown then pcall(function() actor.RangedAttack_Cooldown = opts.Cooldown end) end
    if opts.Sprint then
        -- In place: writing the whole FVector2D back would go through UE4SS struct marshalling.
        pcall(function()
            local r = actor.Accuracy_FastMovementRange
            r.X = opts.Sprint[1]; r.Y = opts.Sprint[2]
        end)
    end
end


-- Shared aim/cadence setup. Zeroes the forced-miss counter so the first shot lands, and sets the
-- refire cooldown.
--   * `perfect` also zeroes the aim SPREAD (Accuracy_Default + FastMovementRange): the vanish
--     snipers fire once then leave, so they must not whiff. The others keep the base spread.
function H.LockOnFast(actor, cooldownSec, perfect)
    H.SetAccuracy(actor, {
        Misses   = 0,
        Cooldown = cooldownSec,
        Steady   = perfect and 0 or nil,
        Sprint   = perfect and { 0, 0 } or nil,
    })
end


-- =======================================================================
-- BREAKING SIGHT RESETS THE AIM - the shared counterplay for a zeroed-in sniper.
--
-- `FailedHits` is a blackboard int, not a pawn field, and the only things that clear it are a
-- landed hit and a combat-state flip (the sniper OVERRIDES the grunt's ToggleCombatStateFX to
-- write 0 rather than the grunt's 99, so the cover-branch bug doesn't reach this family). Nothing
-- reads line of sight. So without this a sniper that has walked its rounds in keeps that aim
-- through cover, and ducking buys you nothing.
--
-- Cheap because we ask the tree, not the world: `CanSeeTarget` is a real
-- CheckLineOfSightToLocations result that BTS_ChooseBestTarget already maintains (~1s) on
-- BT_Attack_Soldier_Sniper - the same key the sniper's own firing branch is gated on. A
-- LineOfSightTo call would be a fresh trace per beat instead.
--
-- Pinned, not edge-triggered: it cannot fire while blind, so holding 0 needs no state of ours.
local SIGHT_RECHECK_TICKS = 4   -- 0.5s at 100ms/tick, under every sniper's refire


-- [AUTHORITY] The write itself, for a tick that has already gated its own cadence.
-- `== false` is deliberate: nil means the blackboard could not be read (a controller mid-possess),
-- and that must not count as blind.
function H.ResetAimOnBlind(actor)
    if not actor.CombatState then return end
    if AVU.GetBlackboardBool(actor, "CanSeeTarget") == false then
        AVU.SetBlackboardInt(actor, "FailedHits", 0)
    end
end


--- [AUTHORITY, def.OnTick] The whole beat, for a sniper that wants nothing else on tick.
function H.SightResetTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    if totalTicks % SIGHT_RECHECK_TICKS ~= 0 then return end
    H.ResetAimOnBlind(actor)
end


-- =======================================================================
-- TWILIGHT SNIPER
-- The rifle body is M_AbioticItems_Master, whose base-colour multiply is DiffuseColor - "Color"
-- and "Tint" are not declared on it and write nothing. The glass slots ignore DiffuseColor in
-- turn, so the scope keeps its own look and the spray is safe.
-- =======================================================================

function H.TintRifle(actor, diffuse)
    if not Utils.HasRenderer() then return end
    if Utils.IsActorInvalid(actor) then return end
    local gun
    pcall(function() gun = actor.Gun end)
    if IsNotValid(gun) then return end

    AVU.TintComponent(gun, { DiffuseColor = diffuse })
end


-- [AUTHORITY] The grunt family rolls a backpack at BeginPlay; this takes it back off. The flag is
-- replicated and OnRep_HasBackpack is what hides the component, so it has to go out the native way.
-- Also used by the Assault Sniper.
function H.NoBackpack(actor)
    AVU.SetReplicatedProp(actor, "HasBackpack", false)
end


-- =======================================================================
-- ASSAULT SNIPER  [RENDERER] - the Breacher's marching pose.
--
-- BS_Sniper_CombatRun carries the rifle up across the chest while moving - fine for a sniper that
-- never moves - so a beam drawn from the muzzle to the target cuts across the body instead of
-- running down the barrel. The Breacher's walk levels the weapon, and both are GruntRework
-- blendspaces on one skeleton, so it is a straight swap.
--
-- THE TORSO SKIN is deliberately a mismatch. This body wears SK_Sniper_Torso, the one grunt-family
-- torso outside the *_Rework UV set, so no other family's skin maps to it properly - the Groupe
-- one read as no change at all (ENUMS.Components.T_TORSO_GROUPE). The Breacher GEAR sheet stretches
-- across it instead, and the stretch is what makes the camo. Try the swap before ruling it out; a
-- loose map on a busy mesh can land somewhere good.
--
-- THE RESUPPLY KIT is the rest of it. An attached prop brings its own mesh and material, so
-- the UV question never arises - and it says what the variant now IS: the one sniper that burns a
-- magazine and has to stop and reload. H.NoBackpack first, so the native pack roll can't leave
-- some of them wearing two.
-- =======================================================================

-- Rotation is an FRotator(Pitch, Yaw, Roll) - an FVector there throws inside the attach and
-- strands it with NO location, scale or tint, which reads as "it spawned rotated and rotation
-- does nothing". Location is BONE-LOCAL and per skeleton: on SK_Human_Skeleton's `head` it is
-- +Z forward, -Y up ([[af-head-bone-local-axes]]).
--   * DiffuseColor per entry, since the kit is item-master meshes and the body wash rarely suits
--     both. Falls back to the body colour.
local ASSAULT_KIT = {
    { Mesh = ENUMS.Components.SM_HIKING_PACK, Socket = "backpack",
      Location = FVector(0, 0, -10), Rotation = FRotator(0, 90, 0), Scale = FVector(0.9, 0.9, 0.9),
      DiffuseColor = FVector(0.1, 0.05, 0) },

    { Mesh = ENUMS.Components.SM_NVG_NOSTRAPS, Socket = "head",
      Location = FVector(0, -7, 5), Rotation = FRotator(90, 0, 90), Scale = FVector(0.8, 0.8, 0.8),
      DiffuseColor = FVector(0.1, 0.05, 0) },
}

-- The merged body is four independently addressable slots: 0 torso, 1 class gear, 2 head, 3 legs,
-- all on M_AbioticCharacter_Master. This one skins the TORSO with the Breacher's gear sheet.
local ASSAULT_TORSO = {
    Slot    = 0,
    Texture = ENUMS.Components.T_GEAR_BREACHER,
    Color   = FVector(0.2, 0.15, 0.2),
}

H.ASSAULT_KIT_ASSETS = {
    ENUMS.Components.SM_HIKING_PACK,
    ENUMS.Components.SM_NVG_NOSTRAPS,
    ASSAULT_TORSO.Texture,   -- def.Assets, or the skin misses wherever no Breacher is loaded
}


function H.AssaultLook(actor, cfg)
    if not Utils.HasRenderer() or Utils.IsActorInvalid(actor) then return end
    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return end

    -- Change its weapon movements to better match a sniper rifle
    pcall(function()
        local bs = ASSETS.GetIfValid(cfg.Walk)
        if IsNotValid(bs) then LogBad("Assault Sniper - march blendspace not resident") return end
        actor.CombatBlendspace = bs
        actor.AltCombatBlendspace = bs   -- the grunt swaps to this one mid-fight; point both
        mesh:SetAnimationMode(0, true)
    end)

    -- Pass the PATH: AttachStaticMesh re-resolves per attach, so a shared mesh can't go stale.
    for _, p in ipairs(ASSAULT_KIT) do
        AVU.AttachStaticMesh(actor, p.Mesh, p.Socket, {
            Location = p.Location,
            Rotation = p.Rotation,
            Scale = p.Scale,
            DiffuseColor = p.DiffuseColor or cfg.Body,
        })
    end

    AVU.TintSlot(mesh, ASSAULT_TORSO.Slot,
                 { Texture = ASSAULT_TORSO.Texture, Color = ASSAULT_TORSO.Color })
end


local RANGED = ENUMS.NpcData.RangedDamage

-- Health damage by the target's fatigue tier (rested / >=30 / >=60 / >=90).
local function twilightDamage(fatigue, cfg)
    local t = STATE.HardModeNoMercy and cfg.Damage.Hard or cfg.Damage.Normal
    fatigue = fatigue or 0
    if fatigue >= 90 then return t[4]
    elseif fatigue >= 60 then return t[3]
    elseif fatigue >= 30 then return t[2]
    else return t[1] end
end


-- [AUTHORITY] Two gated field writes per beat, no damage dealt here: keep shot damage synced to
-- the target's current fatigue so the next shot lands at the right tier, and reset the aim ladder
-- while the target is out of sight. `cfg` is the def's TWILIGHT table (Damage/RecheckTicks).
function H.TwilightTick(actor, totalTicks, cfg)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    if totalTicks % cfg.RecheckTicks ~= 0 then return end

    if not actor.CombatState then return end

    H.ResetAimOnBlind(actor)

    local target = actor:GetCurrentCombatTarget()
    if not Utils.IsPlayer(target) then return end

    local fatigue = 0
    pcall(function() fatigue = target.CurrentFatigue or 0 end)
    local npcData = actor.NPCData
    if IsValid(npcData) then npcData[RANGED] = twilightDamage(fatigue, cfg) end
end


-- [AUTHORITY] No bleed (stripped in Stats) - pump fatigue instead. `cfg` is the def's TWILIGHT
-- table (Fatigue/Stamina).
--   * EIGT off-hook: ModifyStat_Fatigue called directly from the ProcessDamage hook re-enters
--     ProcessEvent.
--   * STAT-CEILING TRAP: crossing 90% fatigue applies Debuff_Exhausted by row name, whose buff
--     object is otherwise never resident - a cold blocking load, state-dependent so it looks
--     intermittent. LoadAsync it FIRST so the modify's callback finds it resident.
--   * See AnNotes/AnteNPCs/OrderSniper.md for the full decode.
function H.TwilightDealtDamage(attacker, victim, cfg)
    if not Utils.IsPlayer(victim) then return end
    local hard = STATE.HardModeNoMercy
    local fatigue = hard and cfg.Fatigue.Hard or cfg.Fatigue.Normal
    local stamina = hard and cfg.Stamina.Hard or cfg.Stamina.Normal
    ASSETS.LoadAsync({ ENUMS.BuffObjects.FatigueExhausted }, function()
        ExecuteInGameThread(function()
            if Utils.IsActorInvalid(victim) then return end
            pcall(function() victim:ModifyStat_Fatigue(fatigue) end)
            pcall(function() victim:ModifyStat_Stamina(-stamina) end)
        end)
    end)
    LogDebug("Twilight Sniper - +fatigue, -stamina", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- =======================================================================
-- TRACKER SNIPER
-- [AUTHORITY] The tag loop is sniper-INDEPENDENT once started: it scans for tagged players, so
-- spawns keep coming for the debuff's duration even if the sniper that tagged them dies.
-- =======================================================================

local TRACK_INTERVAL   = 12000       -- ms between checks (some overlap; the tag gets refreshed)
local TRACK_REINFORCE  = "Grunt_Guard"
local TRACK_TD_SECONDS = 2           -- brief 3x time dilation to speed the spawn-in
local TRACK_MAX_ALIVE  = 3           -- concurrent reinforcements per tagged player (Commander cap precedent)

local trackingActive = false
-- player fullname -> array of live reinforcements. Keyed by fullname (NOT the wrapper - LivePlayers
-- hands back a fresh one each loop, [[anteup2-actor-wrapper-identity]]).
local trackUnits = {}


-- Prune dead/invalid reinforcements for `key` (in place) and return the surviving array.
local function liveTrackUnits(key)
    local list = trackUnits[key]
    if not list then list = {}; trackUnits[key] = list end
    local n = 0
    for i = 1, #list do
        local g = list[i]
        local alive = Utils.IsActorValid(g)
        if alive then pcall(function() alive = not g.IsDead end) end
        if alive then n = n + 1; list[n] = g end
    end
    for i = #list, n + 1, -1 do list[i] = nil end
    return list
end


-- One random Order grunt on a tracked player, capped so a sustained tag can't pile them up.
local function spawnReinforcements(player)
    if Utils.IsActorInvalid(player) then return end

    local key
    pcall(function() key = player:GetFullName() end)
    if not key then return end

    local list = liveTrackUnits(key)
    if #list >= TRACK_MAX_ALIVE then
        LogDebug("Tracker Sniper - at reinforcement cap (" .. TRACK_MAX_ALIVE .. "), holding", SETTINGS.DEBUG_NPC_ACTIONS)
        return
    end

    local loc = player:K2_GetActorLocation()
    if not loc then return end

    -- Geometry-checked (no sight leg: the point is around the PLAYER, cover is fine). A pass with no
    -- clear point skips rather than dropping a body into the nearest wall; the loop re-fires.
    local pt = AVU.PickClearSpawnPoint(player, loc, 500, 200, 6)
    if not pt then
        LogDebug("Tracker Sniper - no clear spot for reinforcements this pass", SETTINGS.DEBUG_NPC_ACTIONS)
        return
    end
    NpcSpawner.SpawnNpc(TRACK_REINFORCE, pt, {
        callback = function(npc)
            if Utils.IsActorInvalid(npc) then return end
            list[#list + 1] = npc   -- counts against this player's cap until it dies (same array ref)
            AVU.SetTimeDilation(npc, 3)
            AVU.ForceAggro(npc, player)
            Utils.QueueWork(function()
                if Utils.IsActorValid(npc) then AVU.SetTimeDilation(npc, 1) end
            end, TRACK_TD_SECONDS * 1000)
        end,
    })
    LogDebug("Tracker Sniper - reinforcements on tagged player", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- Start the tag loop (idempotent). Armed by the Tracker's OnDealtDamage.
function H.EnsureTrackingLoop()
    if trackingActive then return end
    trackingActive = true

    local function loop()
        if not STATE.ModEnabled then trackingActive = false; return end
        local any = false
        -- GameState player array (O(players)), not FindAllOf (O(all UObjects)).
        for _, p in ipairs(Utils.LivePlayers()) do
            if Utils.ActorHasBuff(p, ENUMS.Debuffs.ReaperTrack) then
                any = true
                spawnReinforcements(p)
            end
        end
        if any then Utils.QueueWork(loop, TRACK_INTERVAL) else trackingActive = false end
    end

    Utils.QueueWork(loop, TRACK_INTERVAL)
end


-- =======================================================================
-- TRACER SNIPER
-- [AUTHORITY] Same tag as the Tracker, but reinforcements are placed through the LEYAK EQS
-- (navigable points OUT of the player's line of sight) instead of dropping on top of them.
--   * One per interval, concurrent-capped, and bounded to a few EQS misses before it gives up on
--     a player (perf).
-- =======================================================================

local TRACER_INTERVAL    = 12000   -- ms between reinforcement checks per tagged player
local TRACER_MAX_ALIVE   = 3
local TRACER_TD_SECONDS  = 2
-- Mixed table: plain Order rows (spawned raw) AND AnteUp variants (mutated) - tracerSummonOne
-- routes each name to the right spawner.
local TRACER_SUMMONS     = { "Grunt", "Grunt", "Grunt_Captain", "Grunt_Shotgun",
                             "Velites Guard", "Grenadier Guard", "Suppressor Grunt",
                             "Trident", "Skirmisher" }
local TRACER_EQS_MIN     = 800     -- placement band from the tagged player
local TRACER_EQS_MAX     = 3500
local TRACER_EQS_RETRIES = 5       -- consecutive misses before the loop gives up on a player

local tracerActive = false
local tracerUnits  = {}   -- player fullname -> array of live reinforcements (cap accounting)
local tracerFails  = {}   -- player fullname -> consecutive EQS-placement misses


local function liveTracerUnits(key)
    local list = tracerUnits[key]
    if not list then list = {}; tracerUnits[key] = list end
    local n = 0
    for i = 1, #list do
        local u = list[i]
        local alive = Utils.IsActorValid(u)
        if alive then pcall(function() alive = not u.IsDead end) end
        if alive then n = n + 1; list[n] = u end
    end
    for i = #list, n + 1, -1 do list[i] = nil end
    return list
end


-- Spawn ONE summon-table entry at `pt`, aimed at `player`. Mixed dispatcher: a registered variant
-- goes through SummonVariant (mutated + tagged), a plain Order row through SpawnNpc.
local function tracerSummonOne(name, pt, player, list)
    local isVariant = require("AnteVariants.Variants")[name] ~= nil
    local function onSpawned(npc)
        if Utils.IsActorInvalid(npc) then return end
        list[#list + 1] = npc
        AVU.SetTimeDilation(npc, 3)
        if Utils.IsActorValid(player) then AVU.ForceAggro(npc, player) end
        Utils.QueueWork(function()
            if Utils.IsActorValid(npc) then AVU.SetTimeDilation(npc, 1) end
        end, TRACER_TD_SECONDS * 1000)
    end
    if isVariant then
        AVU.SummonVariant(name, pt, { SpawnDelay = 250, SkipSpawnFX = true }, onSpawned)
    else
        NpcSpawner.SpawnNpc(name, pt, { SkipSpawnFX = true, callback = onSpawned })
    end
end


local function tracerSpawn(player)
    if Utils.IsActorInvalid(player) then return end
    local key
    pcall(function() key = player:GetFullName() end)
    if not key then return end

    if #liveTracerUnits(key) >= TRACER_MAX_ALIVE then return end   -- at cap: hold

    local ploc = player:K2_GetActorLocation()
    if not ploc then return end

    Placement.FindStalkerPoint(player, { Origin = ploc, MaxDist = TRACER_EQS_MAX }, function(points)
        -- Prefer a point at least TRACER_EQS_MIN out (not right on the player); else take any.
        local pt
        for _, p in ipairs(points or {}) do
            if Utils.DistSq(ploc, p) >= TRACER_EQS_MIN * TRACER_EQS_MIN then pt = p; break end
        end
        pt = pt or (points and points[1])
        if not pt then
            tracerFails[key] = (tracerFails[key] or 0) + 1
            LogDebug("Tracer Sniper - no EQS point (miss " .. tostring(tracerFails[key]) .. ")", SETTINGS.DEBUG_NPC_ACTIONS)
            return
        end
        tracerFails[key] = 0

        -- Re-check the cap: FindStalkerPoint is async, so another spawn may have landed meanwhile.
        local list = liveTracerUnits(key)
        if #list >= TRACER_MAX_ALIVE then return end
        tracerSummonOne(TRACER_SUMMONS[math.random(1, #TRACER_SUMMONS)], pt, player, list)
        LogDebug("Tracer Sniper - reinforcement via Leyak EQS", SETTINGS.DEBUG_NPC_ACTIONS)
    end)
end


local function ensureTracerLoop()
    if tracerActive then return end
    tracerActive = true

    local function loop()
        if not STATE.ModEnabled then tracerActive = false; return end
        local any = false
        for _, p in ipairs(Utils.LivePlayers()) do
            if Utils.ActorHasBuff(p, ENUMS.Debuffs.ReaperTrack) then
                any = true
                local key
                pcall(function() key = p:GetFullName() end)
                -- Skip a player the EQS has repeatedly failed for (perf); a fresh tag resets it.
                if key and (tracerFails[key] or 0) < TRACER_EQS_RETRIES then
                    tracerSpawn(p)
                end
            end
        end
        if any then Utils.QueueWork(loop, TRACER_INTERVAL) else tracerActive = false end
    end

    Utils.QueueWork(loop, TRACER_INTERVAL)
end


-- Tag a player and make sure the EQS reinforcement loop is running. Shared with the Praetorium
-- Sniper (a shorter tag), so the two stack rather than compete.
function H.TagTarget(victim, seconds)
    Utils.ApplyBuffLinked(victim, ENUMS.Debuffs.ReaperTrack, seconds, nil)
    local key
    pcall(function() key = victim:GetFullName() end)
    if key then tracerFails[key] = 0 end   -- re-arm the EQS retries on a fresh tag
    ensureTracerLoop()
end


-- =======================================================================
-- RADIO PACK  (Tracker / Tracer snipers - the pack they drop on death)
-- The grunt family rolls its backpack at BeginPlay (20% chance) and gates the component on the
-- replicated HasBackpack, so wearing one is a two-part job: force the flag on authority, dress
-- the component on every renderer.
-- =======================================================================

local RADIO_PACK_TINT  = FVector(0.25, 0.12, 0.05)
local RADIO_PACK_SCALE = FVector(1.3, 1.3, 1)

-- [AUTHORITY] Force the pack on. OnRep_HasBackpack is what actually unhides the component, so
-- the flag has to go out the native way (value + dirty + OnRep) or it reaches nobody.
function H.WearRadioPack(actor)
    AVU.SetReplicatedProp(actor, "HasBackpack", true)
end

-- [RENDERER] Dress it: the Captain's radio pack, retinted, slightly oversized. None of this
-- replicates, so every renderer runs it for itself.
function H.RadioPackLook(actor)
    if not Utils.HasRenderer() then return end
    if Utils.IsActorInvalid(actor) then return end
    local pack
    pcall(function() pack = actor.backpack end)
    if IsNotValid(pack) then return end

    AVU.SwapStaticMesh(pack, ENUMS.Components.SM_RADIO_PACK)
    AVU.TintSlot(pack, 0, { Color = RADIO_PACK_TINT })
    pcall(function() pack:SetRelativeScale3D(RADIO_PACK_SCALE) end)
end


-- =======================================================================
-- SHARED VANISH KIT  (Groupe Sniper, Praetorium Sniper)
-- Cycle: laser closes in -> ONE shot -> stagger + fade out -> burst FX -> teleport to a far LoS
-- perch -> fade back in, stunned, laser ramping black to full.
--   * Perch pick is two-tier: far LoS ring first (FindLosPoint); if a dense interior has none,
--     fall back to the Leyak EQS (FindStalkerPoint - out of LoS but pathable) so it ducks into
--     cover instead of standing stunned in the open.
--   * Fade uses the shared AVUtils kit (GroupeFadeOut/In): pure opacity + gun/helmet visibility,
--     independent of the Groupe's white wash, so a dark variant can use it untinted.
--   * A hop is not guaranteed a firing line. Variants that set cfg.RelocateMax get the dud-hop
--     watchdog (H.SniperRelocateTick) - a bounded re-vanish so a stranded sniper is never a
--     spectator for the rest of the fight.
--   * FIXED-PERCH variants (cfg.Spots, e.g. the Praetorium Library Sniper) skip the LoS ring/EQS
--     entirely and pick from a hand-authored list instead (pickFreePerch, below) - see the
--     "FIXED-PERCH VANISH" section at the bottom of this file for that list + registry.
-- =======================================================================

local GROUPE_HOP_ZLIFT    = 60     -- teleport Z lift (30 clipped feet into slopes)
local LASER_RAMP          = { 0.1, 0.25, 0.5, 0.7, 1.0 }   -- beam brightness over the post-hop stun
local LASER_READY_LEAD_MS = 2500   -- ramp finishes this long BEFORE the stun ends, so this is the
                                   --   warning window: full beam = it is about to be able to shoot
local PUFF_LEAD_MS        = 1500   -- burst plays this long BEFORE the hop (it covers the exit);
                                   --   a short-lived burst overrides it with cfg.PuffLead
local HOP_ADVANCE_MS      = 200    -- fire the teleport this much sooner (tighter cloud->vanish sync)
local RELOC_MIN           = 1500   -- teleport band: far / in LoS
local RELOC_MAX           = 3500   --
local RELOC_MAX_ZDELTA    = 2500   -- reject perches >~25m above/below the target (cliff guard)
local RELOC_EQS_MIN       = 800    -- fallback (Leyak EQS, out-of-LoS): prefer points at least this
                                   --   far from the target; else take the query's best
-- Plain {r,g,b} tables, NOT FLinearColors: sniperLaser scales them by the ramp fraction, so it
-- builds the struct at write time.
local LASER_RED = { 1, 0, 0 }   -- the native sight colour (kit default)

-- Re-vanish watchdog: a hop that lands somewhere with no shot leaves the sniper aiming at a wall,
-- so give it another hop rather than a dead cycle. Opt-in per variant (cfg.RelocateMax).
local RELOC_GRACE_S     = 2   -- firing window allowed after the stun before the hop counts as a dud
local RELOC_WATCH_TICKS = 5   -- watchdog cadence, in FAST_TICKs (~10Hz)

H.RELOC_WATCH_TICKS = RELOC_WATCH_TICKS

local lastRelocateTick = {}   -- ActorKey -> FAST_TICK
local relocWatch = {}         -- ActorKey -> { Chain, Deadline }, armed per hop by SniperVanish

-- GROUPE sniper
--   * The stun outlasts RangedAttack_Cooldown, so the lock IS the refire cadence - one number.
local GROUPE_LOCK_S      = 7   -- stunned after the hop - the "long pause"
local GROUPE_LOCK_HARD_S = 6
local GROUPE_FX = ENUMS.Effects.NIAGARA_SNOWMAN_GROUNDPOUND   -- ~1s snow explosion
local GROUPE_PUFF_SCALE = 1.5   -- the burst is already a wide cloud at native size
local GROUPE_PUFF_LEAD  = 1000
local GROUPE_LASER = { 3, 0, 0 }   -- bright red; >1 blooms, the kit default is the flat native red

-- PRAETORIUM sniper
local PRAE_LOCK_S      = 6
local PRAE_SMOKE_SCALE = 1.5
-- Gold blowout wash
local PRAE_WASH  = FVector(16, 10, 0.5)
local PRAE_LASER = { 1.0, 0.62, 0.05 }   -- dark gold sight/beam

-- Exported for the defs (the burst scales + laser colour are shared with the vanish cfgs below).
H.GROUPE_WASH_STRENGTH = 18
H.GROUPE_FX = GROUPE_FX
H.GROUPE_PUFF_SCALE = GROUPE_PUFF_SCALE
H.GROUPE_LASER = GROUPE_LASER
H.PRAE_SMOKE_SCALE = PRAE_SMOKE_SCALE
H.PRAE_WASH = PRAE_WASH
H.PRAE_LASER = PRAE_LASER

H.GROUPE_ASSETS = { GROUPE_FX, ENUMS.SOUNDS.STALACTITE_BREAK }
H.PRAE_ASSETS = { ENUMS.DamageType.BulletGeneric, ENUMS.Effects.NIAGARA_SMOKESCREEN,
                  ENUMS.SOUNDS.AIR_POOF, ENUMS.Components.SK_SNIPER_RIFLE_U1,
                  ENUMS.Components.M_GLASS_LENS_GOLD }

H.GROUPE_VANISH = {
    Label     = "Groupe Sniper",
    LockS     = GROUPE_LOCK_S,
    LockHardS = GROUPE_LOCK_HARD_S,
    -- Extra hops per shot: it gets one more chance (two in hard) to find a firing line before it
    -- settles and waits. See SniperRelocateTick.
    RelocateMax     = 1,
    RelocateMaxHard = 2,
    FX       = GROUPE_FX,
    Sound    = ENUMS.SOUNDS.STALACTITE_BREAK,
    Scale    = GROUPE_PUFF_SCALE,
    PuffLead = GROUPE_PUFF_LEAD,
    Laser    = GROUPE_LASER,
    Reassert = function(actor) GRP.Wash(actor, H.GROUPE_WASH_STRENGTH) end,
}


-- The Groupe's live post-hop lock in seconds. Its shot cadence is set from the same number
-- (H.LockOnFast in the def's Stats), so the two can never drift.
function H.GroupeLockS()
    return STATE.HardModeNoMercy and GROUPE_LOCK_HARD_S or GROUPE_LOCK_S
end

H.PRAE_VANISH = {
    Label    = "Praetorium Sniper",
    LockS    = PRAE_LOCK_S,
    FX       = ENUMS.Effects.NIAGARA_SMOKESCREEN,
    Sound    = ENUMS.SOUNDS.AIR_POOF,
    Scale    = PRAE_SMOKE_SCALE,
    Laser    = PRAE_LASER,
    Reassert = function(actor) H.PraetorLook(actor) end,
}


-- [RENDERER] Laser brightness. `color` is the resting {r,g,b} (default = the native red).
--   * frac 0..1 scales BOTH the RGB and the alpha of the sight + beam colours toward the resting
--     look (frac=1), so it covers additive AND translucent beam materials.
function H.SniperLaser(actor, frac, color)
    if Utils.IsActorInvalid(actor) then return end
    local laser = actor.Laser
    if IsNotValid(laser) then return end
    color = color or LASER_RED
    local r, g, b = color[1], color[2], color[3]
    pcall(function()
        laser:SetColorParameter(FName("Color"), FLinearColor(r * frac, g * frac, b * frac, frac))
    end)
    pcall(function()
        laser:SetColorParameter(FName("BeamColor"), FLinearColor(r * frac, g * frac, b * frac, 0.35 * frac))
    end)
end


-- FIXED-PERCH registry (used by H.SniperVanish below when cfg.Spots is set - the Praetorium
-- Library Sniper). A perch is TAKEN if any live fixed-perch sniper is standing on it; the mover
-- is in the registry too, so that one test also stops it re-picking the perch it's already on.
-- Shared by every cfg.Spots variant - harmless, since perch lists thousands of uu apart can never
-- block each other. See "FIXED-PERCH VANISH" at the bottom of this file for H.LIB_SPOTS.
local PERCH_CLEAR = 700   -- a perch within this (uu) of a live fixed-perch sniper is taken.
                          --   They perch and don't roam, so a small radius is enough - and it
                          --   must stay under HALF the closest perch pair (library: 1479uu).

local perchSnipers = {}   -- ActorKey -> sniper. Pruned on each pick, so a kill/stream-out frees
                          --   its perch on the next hop. Keyed (not a weak wrapper table) because
                          --   OnReady's wrapper is not the one the vanish path holds.


-- [AUTHORITY] Let the perch picker see this sniper. Called from a fixed-perch variant's OnReady.
function H.RegisterPerchSniper(actor)
    local key = Utils.ActorKey(actor)
    if key then perchSnipers[key] = actor end
end


-- A random perch from cfg.Spots that no live fixed-perch sniper occupies; nil = all taken.
local function pickFreePerch(cfg)
    local occupied = {}
    for key, s in pairs(perchSnipers) do
        local alive = Utils.IsActorValid(s)
        if alive then pcall(function() alive = not s.IsDead end) end
        if not alive then
            perchSnipers[key] = nil
        else
            local loc = s:K2_GetActorLocation()
            if loc then occupied[#occupied + 1] = loc end
        end
    end

    local free = {}
    for _, spot in ipairs(cfg.Spots) do
        local taken = false
        for _, loc in ipairs(occupied) do
            if Utils.DistSq(loc, spot) < PERCH_CLEAR * PERCH_CLEAR then taken = true; break end
        end
        if not taken then free[#free + 1] = spot end
    end

    if #free == 0 then return nil end
    return free[math.random(1, #free)]
end


-- [RENDERER] The origin burst (niagara + SoundCue), spawned LOCALLY on host/SP.
--   * Clients get this off the warp mirror, which is why this is not a BroadcastFX.
local function vanishBurst(loc, cfg)
    if not Utils.HasRenderer() or not loc then return end
    local s = cfg.Scale or 1
    AVU.SpawnLocalNiagara(loc, cfg.FX, { Lifetime = 3000, Scale = FVector(s, s, s) })
    if not cfg.Sound then return end
    pcall(function()
        local snd = ASSETS.GetIfValid(cfg.Sound)
        local UEHelpers = require("UEHelpers")
        local gs = UEHelpers.GetGameplayStatics()
        local world = Utils.GetWorld()
        if IsValid(snd) and gs and IsValid(world) then
            gs:PlaySoundAtLocation(world, snd, loc, FRotator(0, 0, 0), 1.0, 1.0, 0.0, nil, nil, nil, nil)
        end
    end)
end


-- [AUTHORITY] The vanish continuation once a destination exists: fade out, burst over the exit,
-- teleport, fade back in. Shared by the sync LoS-perch path and the async EQS fallback.
-- getTarget is SniperVanish's Utils.CarryActor getter for the shot's victim.
local function vanishHop(actor, getTarget, cfg, spot, fadeMs)
    GRP.FadeOut(actor)   -- to invisible over 2.5s (body + gun + helmet)

    -- Burst a beat BEFORE the hop - it covers the exit. (Clients key theirs off the position jump.)
    local old = actor:K2_GetActorLocation()
    if old then
        Utils.QueueWork(function() vanishBurst(old, cfg) end,
            math.max(fadeMs - (cfg.PuffLead or PUFF_LEAD_MS), 0))
    end

    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        pcall(function()
            actor:K2_SetActorLocation(FVector(spot.X, spot.Y, spot.Z + GROUPE_HOP_ZLIFT), false, {}, true)
        end)
        -- It KEEPS attacking this target after the hop - arrive already facing it.
        local target = getTarget()
        if target then AVU.FaceTarget(actor, target) end
        GRP.FadeIn(actor)
        if cfg.Reassert then cfg.Reassert(actor) end
        LogDebug(cfg.Label .. " - relocated behind the burst", SETTINGS.DEBUG_NPC_ACTIONS)
    end, math.max(fadeMs - HOP_ADVANCE_MS, 0))
end


-- [AUTHORITY] Vanish sequence: stun the sniper, fade it out and hide the laser, find a relocation
-- point, hop there, fade back in with the laser ramping up until its cooldown is ready.
--   * cfg: Label / LockS + LockHardS (post-hop stun seconds, also the re-vanish cooldown) /
--     FX + Sound + Scale + PuffLead (origin burst) / Laser (resting colour) / Reassert (re-apply on
--     fade-in) / RelocateMax + RelocateMaxHard (opt into the dud-hop watchdog).
--   * `chained` marks a hop the watchdog asked for, so it counts against the cap instead of
--     resetting it - a hop earned by a landed shot always starts the count over.
function H.SniperVanish(actor, target, cfg, chained)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end
    local key = Utils.ActorKey(actor)
    if not key then return end
    -- The shot's victim can be anything it hit - a bot's fan, a bag wall, a radio - and only a
    -- character carries a departed stamp. The re-aim steps below run seconds later, so they take it
    -- through CarryActor rather than reading a wrapper that may have been collected.
    local getTarget = Utils.CarryActor(target)

    local lockS = (STATE.HardModeNoMercy and cfg.LockHardS) or cfg.LockS

    -- The re-vanish cooldown acts as a stun
    local cdTicks = lockS * 10
    if not AVU.CooldownReady(lastRelocateTick, key, cdTicks) then return end

    -- S3 GC insurance (a preload doesn't pin) + SpawnLocalNiagara silently SKIPS a cold asset:
    -- re-load ~1.3s ahead of the burst. Host/SP only; clients warm theirs through ClientVisuals.
    if Utils.HasRenderer() then
        local warm = { cfg.FX }
        if cfg.Sound then warm[#warm + 1] = cfg.Sound end
        ASSETS.WarmPinned(warm)
    end

    -- STUN + laser-out FIRST, unconditionally - even with no perch the sniper must not rapid-fire.
    local fadeMs = GRP.FADE_OUT_MS
    Utils.AddBuff(actor, ENUMS.Debuffs.ParryStun, true, fadeMs / 1000 + lockS)
    H.SniperLaser(actor, 0, cfg.Laser)

    -- Arm the dud-hop watchdog for the window that opens when the stun ends.
    if cfg.RelocateMax then
        local st = (chained and relocWatch[key]) or { Chain = 0 }
        if chained then st.Chain = st.Chain + 1 end
        st.Deadline = STATE.FAST_TICK + math.floor((fadeMs / 1000 + lockS + RELOC_GRACE_S) * 10)
        relocWatch[key] = st
    end

    -- Ramp the beam back over the stun
    -- Reface the target each step - its stunned and can't rotate
    local rampMs = math.max(lockS * 1000 - LASER_READY_LEAD_MS, 1000)
    for i, frac in ipairs(LASER_RAMP) do
        Utils.QueueWork(function()
            if Utils.IsActorInvalid(actor) then return end
            H.SniperLaser(actor, frac, cfg.Laser)
            local t = getTarget()
            if t then AVU.FaceTarget(actor, t) end
        end, fadeMs + rampMs * i / #LASER_RAMP)
    end

    -- FIXED-PERCH variants (cfg.Spots): hand-authored coords, no LoS ring and no EQS fallback.
    -- Both queries want a navigable point, and these perches deliberately are not.
    if cfg.Spots then
        local perch = pickFreePerch(cfg)
        if perch then
            vanishHop(actor, getTarget, cfg, perch, fadeMs)
        else
            LogDebug(cfg.Label .. " - every fixed perch is taken; stunned in place", SETTINGS.DEBUG_NPC_ACTIONS)
        end
        return
    end

    local spot = Utils.IsActorValid(target) and AVU.FindLosPoint(target, {
        Actor = actor, MinDist = RELOC_MIN, MaxDist = RELOC_MAX, MaxZDelta = RELOC_MAX_ZDELTA, Tries = 16
    }) or nil
    if spot then
        vanishHop(actor, getTarget, cfg, spot, fadeMs)
        return
    end

    -- FALLBACK (dense interior, no far LoS perch): ask the Leyak EQS for a point out of the
    -- target's LoS but still pathable to it, so the sniper ducks into cover instead of standing
    -- stunned in the open. Async, so it starts a beat later than the sync path - the stun is
    -- already running either way.
    if Utils.IsActorInvalid(target) then
        LogDebug(cfg.Label .. " - no target for a perch; stunned in place", SETTINGS.DEBUG_NPC_ACTIONS)
        return
    end
    local tLoc = target:K2_GetActorLocation()
    Placement.FindStalkerPoint(target, { Origin = tLoc, MaxDist = RELOC_MAX }, function(points)
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        -- Prefer a point at least RELOC_EQS_MIN out (not right on the target); else the query's best.
        local pt
        for _, p in ipairs(points or {}) do
            if tLoc and Utils.DistSq(tLoc, p) >= RELOC_EQS_MIN * RELOC_EQS_MIN then pt = p; break end
        end
        pt = pt or (points and points[1])
        if not pt then
            LogDebug(cfg.Label .. " - no LoS perch or EQS point; stunned in place", SETTINGS.DEBUG_NPC_ACTIONS)
            return
        end
        LogDebug(cfg.Label .. " - falling back to an out-of-LoS EQS point", SETTINGS.DEBUG_NPC_ACTIONS)
        vanishHop(actor, getTarget, cfg, pt, fadeMs)
    end)
end


-- [AUTHORITY] The dud-hop watchdog, one call per RELOC_WATCH_TICKS from the variant's OnTick.
-- A hop that finds no firing line strands the sniper aiming at a wall for the rest of the fight,
-- so once its stun has been over for RELOC_GRACE_S with nothing landed it vanishes again - the
-- same trick, spent as if the shot had connected.
--   * The cap is PER SHOT: a landed hit comes back through SniperVanish unchained and clears it.
--   * Disarms on no combat target, so a sniper that has lost the fight stops repositioning.
-- Cheap in the common case: one memoized-key table read, and nothing else until the deadline.
function H.SniperRelocateTick(actor, cfg)
    local key = AVU.CachedFullName(actor)
    local st = key and relocWatch[key]
    if not st or STATE.FAST_TICK < st.Deadline then return end

    local cap = (STATE.HardModeNoMercy and cfg.RelocateMaxHard) or cfg.RelocateMax or 0
    local target = st.Chain < cap and AVU.GetCurrentTarget(actor) or nil
    if not target then
        relocWatch[key] = nil
        return
    end

    LogDebug(cfg.Label .. " - hop landed no shot; relocating again", SETTINGS.DEBUG_NPC_ACTIONS)
    H.SniperVanish(actor, target, cfg, true)
end


-- Drop a sniper's vanish bookkeeping. Both tables are string-keyed, so a body that dies or streams
-- out never collects itself - call this from OnDeath.
function H.ClearVanishState(actor)
    local key = Utils.ActorKey(actor)
    if not key then return end
    lastRelocateTick[key] = nil
    relocWatch[key] = nil
end


-- =======================================================================
-- PRAETORIUM SNIPER
-- =======================================================================

-- [RENDERER] One call so Visuals / OnDamageTaken / ClientTick / the post-hop fade-in all
-- reassert the same look. Deliberately NOT doing per-slot gold leggings (tried; the whole-body
-- wash read better).
function H.PraetorLook(actor)
    if not Utils.HasRenderer() then return end   -- pure cosmetics: nothing to do on a dedicated server
    if Utils.IsActorInvalid(actor) then return end
    AVU.TintMesh(actor, { Color = PRAE_WASH })   -- re-assert: def.Tint only runs once, at mutation
end


-- [RENDERER, ONE-SHOT] Both levers here are mesh/material SWAPS, mesh first (it replaces material
-- slots, so glass must follow). A wash would be H.TintRifle instead.
--   * Mesh -> the shipped U1 skin.
--   * Glass -> the shipped gold lens MI. Rifle has TWO lens slots (front+rear) sharing the
--     helmet's master material - use LensAll or the scope comes out two-tone.
-- Not re-applied on tick: the swap sticks, and the health-texture rebuild only touches the body.
function H.PraetorRifle(actor)
    if not Utils.HasRenderer() then return end
    if Utils.IsActorInvalid(actor) then return end
    local gun
    pcall(function() gun = actor.Gun end)
    if IsNotValid(gun) then return end

    AVU.SwapSkeletalMesh(gun, ENUMS.Components.SK_SNIPER_RIFLE_U1)
    AVU.SetGlass(gun, { LensMaterial = ENUMS.Components.M_GLASS_LENS_GOLD, LensAll = true })
end


-- =======================================================================
-- FIXED-PERCH VANISH  (Praetorium Library Sniper)
-- [AUTHORITY] Same vanish, but the destination comes from a HAND-AUTHORED list instead of the
-- LoS ring / Leyak EQS: the library's column tops are exactly what those queries can't return
-- (that's why the placed spawns up there were commented out - see SpawnerData's Library block).
-- The registry + picker (pickFreePerch, perchSnipers) live above, next to H.SniperVanish, which
-- needs them; this section is just the data and the registration entry point.
-- =======================================================================

-- Library perches (V_Inq). The first two double as the pair's placed spawn coords - see
-- SpawnerData's "* Library" block, which owns the spawn yaws.
H.LIB_SPOTS = {
    FVector(100130, 34050, 1780),
    FVector(102520, 34470, 1130),
    FVector(101510, 33790, 2650),
    FVector(104000, 32890, 1780),
    FVector(103170, 35120, 2650),
    FVector(101440, 32320, 2500),
    FVector(105680, 34600, 2680),
    FVector(103200, 35130, 2660),
    FVector(99270, 33200, 2090),
}

H.LIB_VANISH = {
    Label    = "Praetorium Library Sniper",
    LockS    = PRAE_LOCK_S,
    FX       = ENUMS.Effects.NIAGARA_SMOKESCREEN,
    Sound    = ENUMS.SOUNDS.AIR_POOF,
    Scale    = PRAE_SMOKE_SCALE,
    Laser    = PRAE_LASER,
    Reassert = function(actor) H.PraetorLook(actor) end,
    Spots    = H.LIB_SPOTS,   -- presence of this field IS the "skip LoS/EQS" switch
}

return H
