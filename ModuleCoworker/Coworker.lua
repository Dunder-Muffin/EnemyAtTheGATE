-- =======================================================================
-- ModuleCoworker/Coworker - gives an item each feed; better items for higher food+thirst value.
-- Native (NPC_Coworker.cpp): eats held food, no sickness/poison, no repeats. Feed 1-2: 10/15%
-- stapler chance. Feed 3: always drops pens, aggro-pings nearest player, runs off, despawns in 1min.
-- The native feed hook never fires, so CW.Register polls each watched coworker every second
-- (via NotifyOnNewObject) to detect FedCount changes instead.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local SCHEMA = require("AnteData.Schema")
local G = require("AnteData.Items").Global
local Utils = require("AnteUtils.Utils")
local ASSETS = require("AnteCore.AssetManager")
local ItemSpawner = require("AnteCore.ItemSpawner")
local StoryManager = require("ModuleStory.StoryManager")

local Log = Utils.Log
local LogDebug = Utils.LogDebug

local CW = {}
local COWORKER_CLASS = "/Game/Blueprints/Characters/NPCs/NPC_Coworker.NPC_Coworker_C"

local EAT_DROP_DELAY_MS = 3000   -- time our drop after it eats
local DROP_FUZZ = 60             -- drop an item within 60cm of the coworker's location
local DROP_Z_OFFSET = -10

local F_CONSUMABLE = SCHEMA.Item.ConsumableData
local F_HUNGER     = SCHEMA.Consumable.HungerFill
local F_THIRST     = SCHEMA.Consumable.ThirstFill

--------------------------------------------------------
-- Coworker feeding rewards / tiers
--   * Drops more relevant items as game progresses
--   * Drops better items with better food (food+thirst)
--------------------------------------------------------
local DROP_TIERS = {
    [0] = {
        { FoodValue = 30, Drops = { { G.PENS, 2 }, { G.RUBBERBANDS, 2 }, { G.STAPLER, 1 } } },
        { FoodValue = 0,  Drops = { { G.PENS, 1 }, { G.RUBBERBANDS, 1 }, { G.STAPLER, 1 } } },
    },
    -- Early Manufacturing
    [23] = {
        { FoodValue = 60, Drops = { { G.MILITARY_ELEC, 2 }, { G.STEELCABLE, 2 }, { G.SCREWS, 3 } } },
        { FoodValue = 30, Drops = { { G.MILITARY_ELEC, 1 }, { G.STEELCABLE, 1 }, { G.SCREWS, 2 } } },
        { FoodValue = 0, Drops = { { G.PENS, 2 }, { G.RUBBERBANDS, 2 }, { G.STAPLER, 2 } } },
    },
    -- MidLabs
    [33] = {
        { FoodValue = 110, Drops = { { G.CPU_JAILBROKEN, 1 }, { G.GEM, 2 }, { G.SCRAP_SILVER, 2 }, { G.CAPACITOR, 2 } } },
        { FoodValue = 80, Drops = { { G.CAPACITOR, 2 }, { G.GEM, 1 }, { G.SCRAP_SILVER, 2 } } },
        { FoodValue = 40, Drops = { { G.MILITARY_ELEC, 2 }, { G.STEELCABLE, 2 }, { G.SCREWS, 3 } } },
        { FoodValue = 0, Drops = { { G.PENS, 3 }, { G.RUBBERBANDS, 3 }, { G.STAPLER, 2 } } },
    },
    -- Early Hydro
    [51] = {
        { FoodValue = 150, Drops = { { G.CPU_REINFORCED, 1 }, { G.RES_GROWTH, 3 }, { G.SCRAP_KEVLAR, 3 } } },
        { FoodValue = 120, Drops = { { G.CPU_REINFORCED, 1 }, { G.RES_GROWTH, 3 }, { G.RES_GROWTH, 2 }, { G.SCRAP_KEVLAR, 2 } } },
        { FoodValue = 90, Drops = { { G.CPU_REINFORCED, 1 }, { G.RES_GROWTH, 2 }, { G.TRANSFORMER_BUSHING, 1 }, { G.COIL_WINDING, 1 }, { G.SCRAP_KEVLAR, 1 } } },
        { FoodValue = 60, Drops = { { G.CPU_JAILBROKEN, 1 }, { G.GEM, 2 }, { G.CARBON, 2 }, { G.CAPACITOR, 2 } } },
        { FoodValue = 30, Drops = { { G.MILITARY_ELEC, 2 }, { G.STEELCABLE, 2 }, { G.SCREWS, 3 } } },
        { FoodValue = 0, Drops = { { G.PENS, 3 }, { G.RUBBERBANDS, 3 }, { G.STAPLER, 2 } } },
    },
    -- TODO:
}

-- Return a loot table from DROP_TIERS
local function pickItemDropTier(value, story)

    -- key
    local bracketKey
    for k in pairs(DROP_TIERS) do
        if story >= k and (not bracketKey or k > bracketKey) then bracketKey = k end
    end

    -- value.Drops
    local best
    for _, tier in ipairs(DROP_TIERS[bracketKey] or {}) do
        if value >= tier.FoodValue and (not best or tier.FoodValue > best.FoodValue) then best = tier end
    end
    return best and best.Drops, bracketKey, best and best.FoodValue
end

local coworkerFedCount = {}   -- GetFullName -> last-seen FedCount

-- Polling: When coworkers exist, we poll every second to know when it gets fed
local notifyArmed  = false  -- NotifyOnNewObject guard (just in case)
local POLL_MS = 1000
local watched = {}        -- GetFullName -> npc wrapper (added on sighting, pruned when invalid)
local pollActive = false


-- (5a) Get the food+thirst of the food item given to the coworker (ItemTable_Global row)
local function mealValueOf(rowName)
    local hunger, thirst = 0, 0
    pcall(function()
        local dt = ASSETS.GetDataTable(G.BASE)
        if not dt then return end
        local row = dt:FindRow(rowName)
        if not row then return end
        local cd = row[F_CONSUMABLE]
        hunger = tonumber(cd[F_HUNGER]) or 0
        thirst = tonumber(cd[F_THIRST]) or 0
    end)
    return math.max(hunger, thirst)
end



-- (5) We fed it - lets see what it gives us
--   * StoryProgress - relative
local function dropItem(foodRow, x, y, z, fedCount)
    local value = foodRow and mealValueOf(foodRow) or 0
    local story = StoryManager.GetStoryProgress()
    local drops, bracket, tierValue = pickItemDropTier(value, story)
    if not drops then return end
    ItemSpawner.DropPool(drops, 1, FVector(x, y, z + DROP_Z_OFFSET), DROP_FUZZ)
    LogDebug(string.format("Coworker - feed %d ('%s' value %.0f) -> story[%d] tier %d",
        fedCount, tostring(foodRow), value, bracket, tierValue), SETTINGS.DEBUG_NPC_ACTIONS)
end

-- (4) Periodic check - did we feed the coworker something new?
--   * Look at coworker's FedCount (# of feeds) and FoodEaten (food name)
local function processCoworker(npc)
    local fed = 0
    pcall(function() fed = npc.FedCount or 0 end)
    if fed <= 0 then return end

    -- New food item given to coworker - FedCount > coworkerFedCount[fn]
    local fn; pcall(function() fn = npc:GetFullName() end)
    if not fn or (coworkerFedCount[fn] or 0) >= fed then return end
    coworkerFedCount[fn] = fed

    -- Also track what it was fed
    local foodRowName
    pcall(function()
        local foodEaten = npc.FoodEaten
        local n = #foodEaten
        if n > 0 then foodRowName = foodEaten[n]:ToString() end
    end)

    -- Queue the drop for when the coworker finishes eating
    local loc = npc:K2_GetActorLocation()
    local x, y, z = loc.X, loc.Y, loc.Z
    Utils.QueueWork(function() dropItem(foodRowName, x, y, z, fed) end, EAT_DROP_DELAY_MS)
end


--------------- TRACK COWORKER AND POLL TO UPDATE ---------------


-- (3) Poll all coworkers until none exist (only one normally, but can spawn more)
--   * For each coworker, check its FedCount and FoodEaten for the last thing it ate

local function pollExistingCoworkers()
    if not STATE.ModEnabled then pollActive = false; return end
    local isCwAround = false

    for fn, npc in pairs(watched) do
        if Utils.IsActorValid(npc) then
            isCwAround = true
            pcall(processCoworker, npc)
        else
            watched[fn] = nil
        end
    end
    if not isCwAround then
        pollActive = false
        LogDebug("Coworker - stopped (no coworker alive)", SETTINGS.DEBUG_NPC_ACTIONS)
        return
    end
    Utils.QueueWork(pollExistingCoworkers, POLL_MS)
end

-- (2) Add a new coworker to the watchList and start to poll
--   * Skips CDOs (NotifyOnNewObject fires for those too, not just live instances)

local function watchCoworker(npc)
    if Utils.IsActorInvalid(npc) then return end
    
    local fn; pcall(function() fn = npc:GetFullName() end)
    if not fn or fn:find("Default__") then return end
    
    if watched[fn] then return end
    watched[fn] = npc

    -- Log("Coworker - watching '" .. fn .. "' for feeds")
    if not pollActive then
        pollActive = true
        Utils.QueueWork(pollExistingCoworkers, POLL_MS)
    end
end



-- (1) If using this module, this is the start point
--     Server/host arms NotifyOnNewObject and waits for the coworker

function CW.Register()
    if not SETTINGS.MODULES.TRADERS.BetterCoworker then return end
    if not Utils.IsAuthority() then return end
    coworkerFedCount, watched = {}, {}

    -- First check if a coworker already exists (also covers a /reload mid-session)
    for _, npc in ipairs(FindAllOf("NPC_Coworker_C") or {}) do
        pcall(watchCoworker, npc)
    end

    if not notifyArmed then
        notifyArmed = true
        NotifyOnNewObject(COWORKER_CLASS, function(npc)
            -- QueueWork, not inline: actor work directly in the Notify callback freezes the game.
            Utils.QueueWork(function() watchCoworker(npc) end, 0)
        end)
    end
    Log("Coworker module registered")
end

return CW
