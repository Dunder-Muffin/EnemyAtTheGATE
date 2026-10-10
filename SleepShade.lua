-- =======================================================================
-- SleepShade [AUTHORITY] - the one-time jumpscare at home (Event_Base_SleepShade).
-- A player who lies down near their Crafting Bench and stays asleep a few seconds gets an Event
-- Roaming Shade 10m out, in front of the bed, locked onto them.
--   * Owns its gate: a 1s watcher reads IsSleeping off each player while the story window is open.
--     Polled, not hooked - on the server the sleep toggle's OnRep is a local call.
--   * "In front" is the bed's SleepSocket yaw, which the sleeper's view yaw is pinned to.
--   * The Shade is its own alarm: the game's sleep timer wakes anyone with a hostile inside a
--     12m x 12m box around them.
--   * ONE-TIME per world (StoryData.SleepShadeDone), spent only when the spawn is issued - a sleep
--     with nowhere to put the Shade waits for the next one.
--   Dev: "/event Base_SleepShade" runs it now on a sleeping player (or any player): no window,
--   bench or roll, and no latch spent. Decode: AnNotes/Modules/Events.md "Sleep Shade".
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local FileIO = require("AnteCore.FileIO")
local BENCHES = require("AnteCore.BenchCache")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local AVM = require("AnteUtils.AVMath")
local EVU = require("ModuleStory.EventUtils")

local Log = Utils.Log
local LogDebug = Utils.LogDebug

local SS = {}


local CFG = {
    Enabled = true,
    Variant = "Event Roaming Shade",

    -- Story window, exclusive both ends: after Salem (45), before Reactors (70).
    StoryMin = 45,
    StoryMax = 70, --999

    Chance   = 1.0,    -- rolled once per qualifying sleep
    AsleepMs = 5000,
    WatchMs  = 1000,

    -- At home = a player-deployed Crafting Bench inside this footprint.
    BenchMetres  = 100,
    BenchZMetres = 20,

    -- The spot: bearings are degrees off the bed's facing, best first. The front arc is tried
    -- first and must also be in the sleeper's sight; after that, any bearing will do.
    Distances   = { 1000, 750 },
    FrontArc    = { 0, 25, -25, 50, -50 },
    Bearings    = { 0, 25, -25, 50, -50, 80, -80, 115, -115, 150, -150, 180 },
    FloorZ      = 150,    -- nav projection window: keeps the spot on the sleeper's storey
    MaxPathUU   = 2500,   -- a longer walk is the far side of a wall, not 10m away
    EyeZ        = 60,     -- sight trace from above the sleeper's capsule centre...
    BodyZ       = 100,    -- ...to about the Shade's chest
    SearchGapMs = 120,    -- one candidate per pass

    LockDelayMs = 1200,   -- the fresh body needs its controller before a lock sticks
    LockHoldMs  = 30000,
}


-- =======================================================================
-- RUNTIME - per world, cleared by SS.Reset
-- =======================================================================

local watching = false
local sleepers = {}                            -- ActorKey -> { since = NowMs, tried = bool }
local search = { active = false, token = 0 }   -- a Reset bumps the token, orphaning a search


local function spent()
    local d = STATE.StoryData or {}
    return d.SleepShadeDone == true
end

local function inWindow(story)
    story = story or 0
    return story > CFG.StoryMin and story < CFG.StoryMax
end

local function isAsleep(p)
    local asleep = false
    pcall(function() asleep = p.IsSleeping == true and p.IsDead ~= true end)
    return asleep
end

local function actorLoc(actor)
    local loc
    pcall(function() loc = actor:K2_GetActorLocation() end)
    return loc
end

-- By key, never a held wrapper: the search spans several drains.
local function findPlayer(key)
    for _, p in ipairs(Utils.LivePlayers()) do
        if Utils.ActorKey(p) == key then return p end
    end
    return nil
end


-- =======================================================================
-- THE SPOT
-- =======================================================================

-- In bed, the view yaw is pinned to the bed's SleepSocket; out of bed, the body's own facing.
local function facingYaw(p)
    local yaw
    pcall(function()
        local bed = p.CurrentBed
        if IsValid(bed) and IsValid(bed.SleepSocket) then
            yaw = bed.SleepSocket:K2_GetComponentRotation().Yaw
        end
    end)
    if not yaw then pcall(function() yaw = p:K2_GetActorRotation().Yaw end) end
    return yaw
end

-- The navmesh beside the sleeper. The body lies on the mattress, and a bed can carve the mesh
-- under itself, so the bed's own root is the second try.
local function floorUnder(p)
    local loc = actorLoc(p)
    local spot = loc and Utils.ProjectToNav(loc, 300, 0)
    if spot then return spot end
    pcall(function()
        local bed = p.CurrentBed
        if IsValid(bed) then spot = Utils.ProjectToNav(bed:K2_GetActorLocation(), 300, 0) end
    end)
    return spot
end

local function candidates()
    local list = {}
    for _, b in ipairs(CFG.FrontArc) do
        for _, d in ipairs(CFG.Distances) do list[#list + 1] = { Bearing = b, Dist = d, Sight = true } end
    end
    for _, b in ipairs(CFG.Bearings) do
        for _, d in ipairs(CFG.Distances) do list[#list + 1] = { Bearing = b, Dist = d, Sight = false } end
    end
    return list
end

-- A navmesh point on this bearing that connects to the bed by a short walk, or nil. An
-- unavailable path query (nil) passes on the straight-line distance alone.
local function reachableSpot(plan, c)
    local dir = AVM.RotateYaw(FVector(1, 0, 0), plan.yaw + c.Bearing)
    local raw = FVector(plan.floor.X + dir.X * c.Dist, plan.floor.Y + dir.Y * c.Dist, plan.floor.Z)
    local spot = Utils.ProjectToNav(raw, CFG.FloorZ, 0)
    if not spot then return nil end
    local walk = Utils.NavPathLength(plan.floor, spot)
    if walk == false or (walk and walk > CFG.MaxPathUU) then return nil end
    return spot
end

-- IsPathBlocked fails open, which here only costs a Shade placed out of view.
local function inSight(p, spot)
    local eye = actorLoc(p)
    if not eye then return true end
    return not AVU.IsPathBlocked(p, FVector(eye.X, eye.Y, eye.Z + CFG.EyeZ),
        FVector(spot.X, spot.Y, spot.Z + CFG.BodyZ), { p }, 3)
end

-- One candidate. The nav result is cached per bearing and distance, so the second sweep over the
-- front arc (sight no longer required) makes no second query.
local function tryCandidate(plan, c, p)
    local ck = c.Bearing .. "|" .. c.Dist
    local spot = plan.reach[ck]
    if spot == nil then
        spot = reachableSpot(plan, c) or false
        plan.reach[ck] = spot
    end
    if not spot then return nil end
    if c.Sight and not inSight(p, spot) then return nil end
    if not AVU.SpotClearOfDeployables(spot) then
        plan.reach[ck] = false
        return nil
    end
    return spot
end


-- =======================================================================
-- THE SCARE
-- =======================================================================

local function sendShade(p, spot, c, why, latch)
    if latch then
        local d = STATE.StoryData or {}
        if d.SleepShadeDone then return end
        d.SleepShadeDone = true
        FileIO.SaveStoryData()
    end

    local key = Utils.ActorKey(p)
    local at = actorLoc(p)
    local yaw = at and Utils.RotatorToTarget(spot, at).Yaw or nil
    Log(("Story EVENT - SLEEP SHADE (%s): %.0fm out, %d degrees off the bed's facing"):format(
        tostring(why), c.Dist / 100, c.Bearing))

    EVU.SpawnAt(CFG.Variant, spot, {
        Exact = true,
        Yaw = yaw,
        callback = function(npc)
            local target = key and findPlayer(key)
            if target then
                AVU.LockAggro(npc, target, { DelayMs = CFG.LockDelayMs, HoldMs = CFG.LockHoldMs })
            end
            -- A script spawn belongs to no spawner group, so nothing else would ever unload it.
            AVU.SelfCleanWhenAlone(npc, { Label = "Sleep Shade" })
        end,
    })
end

-- [AUTHORITY] Find a spot around `player` and send the Shade. Returns whether a search began.
--   `latch` = the story gate: spend the once-ever flag as the spawn goes out.
function SS.Start(player, why, latch)
    if not Utils.IsAuthority() then return false end
    if search.active then Log("Sleep Shade - already looking for a spot"); return false end
    if EVU.LatchStops(spent(), "Sleep Shade", "already happened in this world") then return false end

    local key = Utils.ActorKey(player)
    local yaw = facingYaw(player)
    local floor = floorUnder(player)
    if not key or not yaw or not floor then
        Log("Sleep Shade - no floor or facing to measure from, skipped")
        return false
    end

    -- A sleeper who wakes mid-search cancels it; a manual run on someone awake doesn't care.
    local wasAsleep = isAsleep(player)
    local plan = { yaw = yaw, floor = floor, list = candidates(), reach = {}, i = 0 }
    search.active = true
    search.token = search.token + 1
    local token = search.token

    local function pass()
        if token ~= search.token or not STATE.ModEnabled then return end
        local p = findPlayer(key)
        if not p or (wasAsleep and not isAsleep(p)) then
            search.active = false
            LogDebug("Sleep Shade - the sleeper woke before a spot was found", SETTINGS.DEBUG_STORY)
            return
        end

        plan.i = plan.i + 1
        local c = plan.list[plan.i]
        if not c then
            search.active = false
            Log("Sleep Shade - no reachable spot around the bed, waiting for another sleep")
            return
        end

        local spot = tryCandidate(plan, c, p)
        if not spot then
            Utils.QueueWork(pass, CFG.SearchGapMs)
            return
        end
        search.active = false
        sendShade(p, spot, c, why, latch)
    end
    Utils.QueueWork(pass, 0)
    return true
end


-- =======================================================================
-- THE GATE
-- =======================================================================

-- The first player asleep AsleepMs at home, or nil. Each sleep gets one look: the bench and the
-- roll don't change while they lie there.
local function pickSleeper(now)
    local seen, pick = {}, nil
    for _, p in ipairs(Utils.LivePlayers()) do
        local key = Utils.ActorKey(p)
        if key then
            seen[key] = true
            if not isAsleep(p) then
                sleepers[key] = nil
            else
                local rec = sleepers[key]
                if not rec then
                    rec = { since = now }
                    sleepers[key] = rec
                end
                if not pick and not rec.tried and now - rec.since >= CFG.AsleepMs then
                    rec.tried = true
                    if not BENCHES.NearAny(actorLoc(p), CFG.BenchMetres, CFG.BenchZMetres) then
                        LogDebug("Sleep Shade - a player is asleep away from any bench", SETTINGS.DEBUG_STORY)
                    elseif math.random() >= CFG.Chance then
                        LogDebug("Sleep Shade - asleep at a bench, but the roll passed them over", SETTINGS.DEBUG_STORY)
                    else
                        pick = p
                    end
                end
            end
        end
    end
    for key in pairs(sleepers) do
        if not seen[key] then sleepers[key] = nil end
    end
    return pick
end

local function watch()
    if not watching or not STATE.ModEnabled then watching = false; return end
    if spent() or not inWindow(STATE.StoryProgress) then
        watching, sleepers = false, {}
        return
    end
    if not search.active then
        local p = pickSleeper(Utils.NowMs())
        if p then SS.Start(p, "asleep at a bench", true) end
    end
    Utils.QueueWork(watch, CFG.WatchMs)
end

-- [AUTHORITY, StoryManager.Tick] Keep the sleep watcher running while the window is open.
function SS.GateTick(story)
    if not CFG.Enabled or watching then return end
    if spent() or not inWindow(story) then return end
    watching = true
    LogDebug("Sleep Shade - watching for a sleeper at home", SETTINGS.DEBUG_STORY)
    Utils.QueueWork(watch, 0)
end

-- [AUTHORITY, dev handle] Run it now on a sleeping player, else on the first player.
function SS.RunNow()
    local target
    for _, p in ipairs(Utils.LivePlayers()) do
        if isAsleep(p) then target = p; break end
    end
    target = target or Utils.LivePlayers()[1]
    if not target then Log("Sleep Shade - no player to run it on"); return end
    SS.Start(target, "manual", false)
end

-- [AUTHORITY] Per world, from StoryManager.Register: the watcher and any search died with the
-- WorkQueue.
function SS.Reset()
    watching = false
    sleepers = {}
    search.active = false
    search.token = search.token + 1
end


return SS
