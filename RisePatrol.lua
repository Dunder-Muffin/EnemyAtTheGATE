-- =======================================================================
-- RisePatrol [AUTHORITY] - the ongoing Order sweep of V_RISE (Event_Rise_Ongoing_Patrol).
-- While anyone is inside the tower the Order keeps feeding bodies in, and its grip tightens with
-- the headcount: one or two patrol, a few start walking the players down, a full squad hunts.
--   * Presence is a coordinate box, like the Canaan and Voussoir gates - V_RISE is an isolated
--     coordinate island, so a padded AABB beats a level-name spatial query.
--   * Arrival is quiet for CFG.GraceMs, so walking in isn't met at the door. Leaving disarms and
--     despawns the sweep; coming back starts the grace over.
--   * ONE self-rescheduling beat. Each beat spawns at most one body and re-issues the pack's
--     orders off the CURRENT headcount, so pressure tracks the fight rather than a script.
--   * Hard mode (NoMercy) is read at beat time: quicker cadence, a wider pool, one more body,
--     and the escalation thresholds drop.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local ENUMS = require("AnteData.Enums")

local Log = Utils.Log
local LogBad = Utils.LogBad
local LogDebug = Utils.LogDebug

local RP = {}

-- Box boundary for V_RISE, minus the roof (Z ~=2400)
local RISE_BOX = {
    min = { X = -153000, Y = -328500, Z = -2000 },
    max = { X = -144500, Y = -318500, Z =  1800 },
}

local CFG = {
    GraceMs         = 180000,       -- silence after the first arrival
    SpawnRing       = { 800, 2500 },-- where a body lands relative to its player
    Retries         = 5,            -- nav candidates before a beat gives up and skips its spawn
    SpawnWatchdogMs = 4000,         -- a search that calls back neither way stops holding its slot
}

-- The two difficulty tiers. Escalation reads the count ALIVE AT THE BEAT: at Investigate the pack
-- walks the players down, at Hunt it locks on. Below both, the bodies are left to their own AI.
-- A name repeated in a Pool is that many times as likely - the roll is uniform over the array.
local TIERS = {
    Normal = {
        EveryMs = 120000, MaxAlive = 4, Investigate = 3, Hunt = 4,
        Pool = { "Grunt", "Grunt_Guard", "Grunt_Guard", "Grunt_Guard", "Grunt_Captain",
                 "Suppressor Grunt" },
    },
    Hard = {
        EveryMs = 100000, MaxAlive = 5, Investigate = 2, Hunt = 4,
        Pool = { "Grunt", "Grunt_Guard", "Grunt_Guard", "Grunt_Guard", "Grunt_Captain",
                 "Suppressor Grunt", "Trident", "Sweeper", "Skirmisher", "Grenadier Guard" },
    },
}

-- Every body this sweep has fielded: actor key -> npc, pruned in place by liveCount. Plain table
-- (string keys), and cleared IN PLACE - a spawn in flight holds this exact reference as its Track.
local roster = {}
local pendingArm   = false   -- the grace delay is queued
local spawnPending = false   -- a search is in flight and still owns a slot against the cap
local validated    = false
-- Generation counter: every queued beat carries the token it was scheduled under and bails once
-- that no longer matches, so a stop-then-start can never leave two beats running at double rate.
local gen = 0

local beat


-- =======================================================================
-- Presence
-- =======================================================================

local function inBox(loc)
    local mn, mx = RISE_BOX.min, RISE_BOX.max
    return loc.X >= mn.X and loc.X <= mx.X
       and loc.Y >= mn.Y and loc.Y <= mx.Y
       and loc.Z >= mn.Z and loc.Z <= mx.Z
end

-- The living players inside the tower. A corpse anchors no spawn and is no one to hunt, so a
-- full wipe reads the same as an empty level and the sweep packs up.
local function playersInRise()
    local here = {}
    for _, p in ipairs(Utils.LivePlayers()) do
        if not Utils.IsDeadSafe(p) then
            local loc
            pcall(function() loc = p:K2_GetActorLocation() end)
            if loc and inBox(loc) then here[#here + 1] = p end
        end
    end
    return here
end

-- Nearest of `list` to `loc`, with its position (the orders below need both).
local function nearestIn(list, loc)
    local best, bestLoc, bestD
    for _, p in ipairs(list) do
        local pl
        pcall(function() pl = p:K2_GetActorLocation() end)
        if pl then
            local d = Utils.DistSq(loc, pl)
            if not bestD or d < bestD then best, bestLoc, bestD = p, pl, d end
        end
    end
    return best, bestLoc
end


-- =======================================================================
-- The sweep
-- =======================================================================

local function liveCount()
    local n = 0
    for key, npc in pairs(roster) do
        if Utils.IsActorInvalid(npc) or Utils.IsDeadSafe(npc) then roster[key] = nil else n = n + 1 end
    end
    return n
end

local function spawnOne(here, tier)
    local player = here[math.random(#here)]
    local loc
    pcall(function() loc = player:K2_GetActorLocation() end)
    if not loc then return end

    spawnPending = true
    Utils.QueueWork(function() spawnPending = false end, CFG.SpawnWatchdogMs)

    AVU.SpawnReinforcements({
        Npcs = tier.Pool, Origin = loc, Count = 1,
        MinDist = CFG.SpawnRing[1], MaxDist = CFG.SpawnRing[2],
        Retries = CFG.Retries,
        Track = roster,
        Label = "RisePatrol",
        OnSpawned = function(npc)
            spawnPending = false
            LogDebug("RisePatrol - " .. tostring(Utils.GetActorRowName(npc)) .. " joins the sweep",
                SETTINGS.DEBUG_STORY)
        end,
        OnFail = function()
            spawnPending = false
            LogDebug("RisePatrol - no usable spot near a player, skipping this spawn", SETTINGS.DEBUG_STORY)
        end,
    })
end

-- Re-issued every beat rather than latched: the pack's orders follow the headcount, so killing one
-- body genuinely eases the pressure back down a step.
--   * Investigate is the point-of-interest walk - a standing destination the BT re-arms, so they
--     close in without being aggroed onto anyone.
--   * Hunt is a bare lock: it lapses the moment the NPC lands a hit, which is "it came for YOU,
--     then it fights normally".
local function escalate(alive, here, tier)
    if alive < tier.Investigate then return end
    local hunt = alive >= tier.Hunt

    for _, npc in pairs(roster) do
        local nloc
        pcall(function() nloc = npc:K2_GetActorLocation() end)
        if nloc then
            local target, tloc = nearestIn(here, nloc)
            if target then
                if hunt then AVU.LockAggro(npc, target) else AVU.SetPointOfInterest(npc, tloc) end
            end
        end
    end

    LogDebug("RisePatrol - " .. (hunt and "HUNT" or "INVESTIGATE") .. " on " .. alive .. " alive",
        SETTINGS.DEBUG_STORY)
end

function beat(token)
    if token ~= gen then return end
    if not STATE.ModEnabled or not STATE.RisePatrolArmed then STATE.RisePatrolArmed = false; return end

    local tier = STATE.HardModeNoMercy and TIERS.Hard or TIERS.Normal
    -- The manual override drops the box test, so a dev can watch the sweep run anywhere.
    local here = STATE.RisePatrolManual and Utils.LivePlayers() or playersInRise()

    if #here > 0 then
        local alive = liveCount() + (spawnPending and 1 or 0)
        if alive < tier.MaxAlive then spawnOne(here, tier) end
        escalate(alive, here, tier)
    end

    Utils.QueueWork(function() beat(token) end, tier.EveryMs)
end


-- =======================================================================
-- Arm / disarm
-- =======================================================================

local function validate()
    if validated then return end
    validated = true
    local VARIANTS = require("AnteVariants.Variants")   -- lazy: the defs reach back into ModuleStory
    for tierName, tier in pairs(TIERS) do
        for _, name in ipairs(tier.Pool) do
            if not VARIANTS[name] and not ENUMS.NpcClasses[name] then
                LogBad(("RisePatrol - %s pool: unknown spawn '%s' (not a variant or an NpcClasses row)")
                    :format(tierName, tostring(name)))
            end
        end
    end
end

function RP.Start()
    if STATE.RisePatrolArmed then return end
    STATE.RisePatrolArmed = true
    for k in pairs(roster) do roster[k] = nil end   -- last sweep's dead are not this one's headcount
    validate()
    gen = gen + 1
    local token = gen
    Utils.QueueWork(function() beat(token) end, 0)
    Log("RisePatrol - the Order starts sweeping V_RISE")
end

function RP.Stop(reason)
    STATE.RisePatrolArmed = false
    gen = gen + 1                   -- orphan the beat already in flight
    local pulled = 0
    for key, npc in pairs(roster) do
        if Utils.IsActorValid(npc) then
            pcall(function() npc:K2_DestroyActor() end)
            pulled = pulled + 1
        end
        roster[key] = nil
    end
    Log(("RisePatrol - sweep ended (%s), %d pulled"):format(tostring(reason), pulled))
end

-- Presence gate, called from StoryManager.Tick. No story flag: the box walk is pure arithmetic
-- over the player list, and V_RISE is only reachable once the story has opened it anyway.
function RP.GateTick()
    if not STATE.ModEnabled or STATE.RisePatrolManual then return end

    if #playersInRise() > 0 then
        if STATE.RisePatrolArmed or pendingArm then return end
        pendingArm = true
        Utils.QueueWork(function()
            pendingArm = false
            if not STATE.RisePatrolManual and #playersInRise() > 0 then RP.Start() end
        end, CFG.GraceMs)
    else
        pendingArm = false
        if STATE.RisePatrolArmed then RP.Stop("nobody left in V_RISE") end
    end
end

-- Debug handle ("/event Rise_Ongoing_Patrol"): a MANUAL override that ignores the V_RISE gate,
-- so the sweep can be watched anywhere.
function RP.Toggle()
    STATE.RisePatrolManual = not STATE.RisePatrolManual
    if STATE.RisePatrolManual then RP.Start() else RP.Stop("stopped by hand") end
end

-- Per-world reset. A teardown wipes the WorkQueue with the grace delay or a beat still queued, so
-- a flag left set here would kill the sweep for the whole next world.
function RP.Reset()
    STATE.RisePatrolArmed = false
    STATE.RisePatrolManual = false
    pendingArm, spawnPending = false, false
    gen = gen + 1
    for k in pairs(roster) do roster[k] = nil end
end


return RP
