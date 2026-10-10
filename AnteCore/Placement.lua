-- =======================================================================
-- Placement - navigable spawn-point selection using the game's EQS
--
-- Uses EQ_FindLeyakLocation query (Leyak/Reaper stalker placement)
--    * navigable points around a context actor, out of LOS
--    * We can't create new EQS assets from Luas
--    * Runs async, so we poll GetQueryResultsAsLocations until its ready
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local UEHelpers = require("UEHelpers")
local ASSETS = require("AnteCore.AssetManager")
local Utils = require("AnteUtils.Utils")

local Log = Utils.Log
local LogBad = Utils.LogBad
local LogDebug = Utils.LogDebug

-- Static BlueprintCallable lives on the EnvQueryManager CDO
local MANAGER_CDO = "/Script/AIModule.Default__EnvQueryManager"
local EQ_FIND_LEYAK = "/Game/Blueprints/EQS/EQ_FindLeyakLocation.EQ_FindLeyakLocation"
local RUNMODE_ALL_MATCHING = 3   -- EEnvQueryRunMode::AllMatching

local PL = {}


-- =======================================================================
-- Find reachable navigable points near actor
--   opts     : Origin + MaxDist (filter results to within MaxDist),
--               TimeoutMs (default 1500)
--   callback : called once with an array of FVector results. Can be empty
-- =======================================================================
function PL.FindStalkerPoint(actor, opts, callback)
    if not Utils.IsAuthority() then return end
    if Utils.IsActorInvalid(actor) then return end
    if not callback then return end
    opts = opts or {}

    -- Through the loader, never a by-path probe: the query is an EnvQuery no pin kind can hold, and
    -- with no Leyak or Reaper around it is unloaded, so every probe was a full walk. Resident, the
    -- loader hands it back one hop later; the run itself goes on a clean drain item.
    local getActor = Utils.CarryActor(actor)
    ASSETS.LoadAsset(EQ_FIND_LEYAK, function(query)
        Utils.QueueWork(function()
            local a = getActor()
            if a and IsValid(query) then PL.RunStalkerQuery(a, query, opts, callback) end
        end, 0)
    end)
end

function PL.RunStalkerQuery(actor, query, opts, callback)

    local manager = ASSETS.GetIfValid(MANAGER_CDO)
    local world = Utils.GetWorld()
    if not manager or IsNotValid(manager) or IsNotValid(world) then return end

    local ok, wrapper = pcall(function()
        return manager:RunEQSQuery(world, query, actor, RUNMODE_ALL_MATCHING, nil)
    end)
    if not ok or IsNotValid(wrapper) then
        LogBad("FindStalkerPoint - RunEQSQuery failed: " .. tostring(wrapper))
        return
    end

    -- Poll for results
    local timeoutMs = opts.TimeoutMs or 1500
    local start = os.clock() * 1000

    local function poll()
        if IsNotValid(wrapper) then return end

        -- The bool is the "finished" flag: true once the query is done, even with nothing found.
        -- (Nil if this UE4SS build doesn't hand a return value back; the timeout then covers it.)
        local locations = {}
        local gotOk, finished = pcall(function()
            return wrapper:GetQueryResultsAsLocations(locations)
        end)

        -- Returns locations in wrappers, :get() to get FVectors
        --   Copy results into a clean FVector 
        if gotOk and #locations > 0 then
            local foundPoints = {}
            for i = 1, #locations do
                local raw = locations[i]
                local parsedOk, loc = pcall(function()
                    local v = raw
                    if type(v) == "userdata" then
                        local okGet, got = pcall(function() return v:get() end)
                        if okGet and got then v = got end
                    end
                    return FVector(v.X, v.Y, v.Z)
                end)

                if parsedOk and loc then
                    if opts.Origin and opts.MaxDist then
                        if Utils.WithinDistance(opts.Origin, loc, opts.MaxDist) then
                            foundPoints[#foundPoints + 1] = loc
                        end
                    else
                        foundPoints[#foundPoints + 1] = loc
                    end
                end
            end
            
            LogDebug(string.format("FindStalkerPoint - %d results, %d within range",
                #locations, #foundPoints), true)
            callback(foundPoints)
            return
        end

        if gotOk and finished == true then
            LogDebug("FindStalkerPoint - finished with no results", true)
            callback({})
            return
        end

        -- Without the flag an empty result reads the same as one still running, so this is almost
        -- always a query that finished with no out-of-LoS point (open ground) - an outcome every
        -- caller handles, not an error.
        if (os.clock() * 1000 - start) > timeoutMs then
            LogDebug("FindStalkerPoint - no results in " .. timeoutMs .. " ms", true)
            callback({})
            return
        end

        Utils.QueueWork(poll, 100)
    end

    Utils.QueueWork(poll, 100)
end

return PL
