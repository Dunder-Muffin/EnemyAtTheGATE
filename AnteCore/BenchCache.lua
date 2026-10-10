-- =======================================================================
-- BenchCache [AUTHORITY] - where the players' Crafting Benches are, as plain coordinates, so
-- "is this spot at someone's base" never costs an overlap. Shared by the Director (no packs inside
-- a base) and the Sleep Shade (a sleeper at home).
--   * One FindAllOf per world and per in-game day, then NotifyOnNewObject for anything built or
--     streamed in later. Removal isn't hooked: a stale entry lasts until the daily rebuild.
--   * Only a bench a PLAYER deployed counts. The map ships its own (the Canaan blacksmith hut's
--     Repair Bench), and those are scenery, not a home.
--   * Built on the first question each world (STATE.BenchCacheArmed, cleared by ResetState).
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local Utils = require("AnteUtils.Utils")

local LogDebug = Utils.LogDebug

local BC = {}

-- FindAllOf on the parent catches every subclass; NotifyOnNewObject needs each concrete class.
local BENCH_PARENT_CLASS = "AbioticDeployed_CraftingBench_ParentBP_C"
local BENCH_CLASSES = {
    ENUMS.DeployedObjs.CRAFTING_BENCH_DEFAULT, ENUMS.DeployedObjs.CRAFTING_BENCH_REPAIR,
    ENUMS.DeployedObjs.CRAFTING_BENCH_UPGRADE, ENUMS.DeployedObjs.CRAFTING_BENCH_SIGNAL,
    ENUMS.DeployedObjs.BENCH_AMMO,            ENUMS.DeployedObjs.BENCH_COOKING,
}

local NOTIFY_SETTLE_MS = 250     -- a just-constructed bench has no transform yet
local DAY_CHECK_MS     = 10000   -- how often a question also looks for a new in-game day

local benchLocs = {}             -- array of {X,Y,Z}
local benchDay = nil             -- in-game day of the last rebuild
local nextDayCheckMs = 0
local notifyArmed = false        -- NotifyOnNewObject can't unregister: once per session

local function debugOn()
    return SETTINGS.DEBUG_DIRECTOR or SETTINGS.DEBUG_STORY
end

local function actorLoc(actor)
    local loc
    pcall(function() loc = actor:K2_GetActorLocation() end)
    return loc
end

-- DeployedByPlayer is a class default of false, set at deploy and kept in the deployable's save
-- data, so a restored base reads right.
local function isPlayerBench(obj)
    local mine = false
    pcall(function() mine = obj.DeployedByPlayer == true end)
    return mine
end

-- Dedupe by rounded coords: a stream-in re-constructs the same bench.
local function addBench(loc)
    local x, y, z = math.floor(loc.X + 0.5), math.floor(loc.Y + 0.5), math.floor(loc.Z + 0.5)
    for _, b in ipairs(benchLocs) do
        if b.X == x and b.Y == y and b.Z == z then return false end
    end
    benchLocs[#benchLocs + 1] = { X = x, Y = y, Z = z }
    return true
end

-- The one FindAllOf. The origin skip drops the class default object, which FindAllOf also returns.
local function rebuild(day)
    benchLocs = {}
    local ok, found = pcall(FindAllOf, BENCH_PARENT_CLASS)
    if ok and found then
        for _, b in ipairs(found) do
            local loc = (Utils.IsActorValid(b) and isPlayerBench(b)) and actorLoc(b) or nil
            if loc and (loc.X ~= 0 or loc.Y ~= 0) then addBench(loc) end
        end
    end
    benchDay = day
    LogDebug("BenchCache - rebuilt: " .. #benchLocs .. " player benches", debugOn())
end

local function armNotify()
    if notifyArmed then return end
    notifyArmed = true
    for _, path in ipairs(BENCH_CLASSES) do
        pcall(NotifyOnNewObject, path, function(obj)
            -- Construction time: pure QueueWork here; the transform read runs later on the drain.
            Utils.QueueWork(function()
                if not STATE.BenchCacheArmed or Utils.IsActorInvalid(obj) then return end
                if not isPlayerBench(obj) then return end
                local loc = actorLoc(obj)
                if loc and (loc.X ~= 0 or loc.Y ~= 0) and addBench(loc) then
                    LogDebug("BenchCache - bench added at " .. Utils.PrintRoundedLocation(loc), debugOn())
                end
            end, NOTIFY_SETTLE_MS)
        end)
    end
end

-- [AUTHORITY] Build this world's cache if it isn't yet; rebuild on a new in-game day. Cheap once
-- built, and every question below calls it.
function BC.Ensure()
    local now = Utils.NowMs()
    if not STATE.BenchCacheArmed then
        STATE.BenchCacheArmed = true
        nextDayCheckMs = now + DAY_CHECK_MS
        rebuild(Utils.GetCurrentDay())
        armNotify()
        return
    end
    if now < nextDayCheckMs then return end
    nextDayCheckMs = now + DAY_CHECK_MS
    local day = Utils.GetCurrentDay()
    if day and day ~= benchDay then rebuild(day) end
end

-- [AUTHORITY] Is `loc` inside a base's footprint: a player bench within xyMetres across, and no
-- more than zMetres above or below (another storey)?
function BC.NearAny(loc, xyMetres, zMetres)
    if not loc then return false end
    BC.Ensure()
    local xy = xyMetres * 100
    local xySq, zTol = xy * xy, zMetres * 100
    for _, b in ipairs(benchLocs) do
        if math.abs(loc.Z - b.Z) <= zTol and Utils.DistSqXY(loc, b) < xySq then return true end
    end
    return false
end

-- [AUTHORITY] How many benches this world has cached, building the cache first if needed.
function BC.Count()
    BC.Ensure()
    return #benchLocs
end

return BC
