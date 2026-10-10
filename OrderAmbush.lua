-- =======================================================================
-- EVENT 2 - ORDER AMBUSH  (Event_Manu_OrderAmbush)  [AUTHORITY] - ONE-TIME
--   A ring of Order soldiers drops around the player it was called on - or, with no target
--   named (the debug keybind), around every player.
--     * Warn first, then spawn a beat later (the AnteUp1 feel).
--     * Base rows, not variants - the spawn pipeline mutates them like any other spawn.
--   Gate: SM.GateOrderAmbush (armed on the train, fired at a crafting bench).
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local AFUtils = require("AFUtils.AFUtils")
local Utils = require("AnteUtils.Utils")
local EVU = require("ModuleStory.EventUtils")

local Log = Utils.Log

local EV = {}


local AMBUSH_DELAY_MS = 30000   -- warning -> spawn
local AMBUSH_WARN_COLOR = AFUtils.CriticalityLevels and AFUtils.CriticalityLevels.Purple or nil

-- { row, X offset, Y offset } around the player.
local AMBUSH_RING = {
    { "Grunt_Guard",   500,    0 },
    { "Grunt",        -250,  433 },
    { "Grunt_Captain",-250, -433 },
    { "Grunt_Guard",     0,  500 },
}

function EV.OrderAmbush(target)
    if not Utils.IsAuthority() then return end

    -- A PATH, not the wrapper: the ring lands AMBUSH_DELAY_MS later and a wrapper held that
    -- long can be freed underneath us.
    local targetPath = target and Utils.ObjectPath(target) or nil
    if target and not targetPath then return end

    -- Who this ambush is for, re-resolved at each use.
    local function victims()
        if not targetPath then return Utils.LivePlayers() end
        local p = Utils.ResolveByPath(targetPath)
        return p and { p } or {}
    end

    local function warn(players, msg)
        for _, p in ipairs(players) do
            pcall(function() p:Client_DisplayWarningMessage(FText(msg), AMBUSH_WARN_COLOR, false) end)
        end
    end

    warn(victims(), "Something doesn't feel right...")
    Log("Story EVENT - ORDER AMBUSH incoming (" .. (AMBUSH_DELAY_MS / 1000) .. "s)")

    Utils.QueueWork(function()
        local marked = victims()
        local count = 0
        for _, p in ipairs(marked) do
            local ok, pLoc = pcall(function() return p:K2_GetActorLocation() end)
            if ok and pLoc then
                count = count + 1
                for _, e in ipairs(AMBUSH_RING) do
                    local at = FVector(pLoc.X + e[2], pLoc.Y + e[3], pLoc.Z + 50)
                    local spot = Utils.GetSpawnPoint(at, 250) or at
                    EVU.SpawnOne(e[1], spot, nil, { Rotation = Utils.RotatorToTarget(spot, pLoc) })
                end
            end
        end
        if count > 0 then warn(marked, "An Orderly ambush!") end
        Log("Story EVENT - ORDER AMBUSH spawned (" .. count .. " player(s))")
    end, AMBUSH_DELAY_MS)
end


return EV
