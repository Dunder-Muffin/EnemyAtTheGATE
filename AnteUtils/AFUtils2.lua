-- =======================================================================
-- AnteUtils/AFUtils2 - our replacements for the vendored AFUtils helpers that read item-struct field
-- names. Those spell the old build's GUID names, so they read nothing on the native layout; these take
-- every name from AnteData/Schema and run on both builds. Only what the mod needs lives here.
--   * Liquids / energy: fill an item's ChangeableData to its capacity.
--   * Weather: trigger an event by row name.
-- AFUtils calls that touch no struct field (player / controller getters, the hotbar-slot getter,
-- chat output, enums) stay on AFUtils.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local Utils = require("AnteUtils.Utils")
local ASSETS = require("AnteCore.AssetManager")
local ENUMS = require("AnteData.Enums")
local SCHEMA = require("AnteData.Schema")
local AFUtils = require("AFUtils.AFUtils")

local AF2 = {}

local I, LQ, CD, SL = SCHEMA.Item, SCHEMA.Liquid, SCHEMA.Changeable, SCHEMA.Slot
local L = ENUMS.LiquidType
local ENERGY = { [L.Energy] = true, [L.LaserEnergy] = true }

local WEATHER_LIB = "/Script/AbioticFactor.Default__WeatherEventHandleFunctionLibrary"


-- =======================================================================
-- Liquids
-- =======================================================================

function AF2.IsEnergyLiquid(liquidType) return ENERGY[tonumber(liquidType)] == true end

-- A LiquidType number from a name ("ink", "RadioactiveWaste") or a number string; nil if unknown.
function AF2.LiquidByName(name)
    if name == nil or name == "" then return nil end
    local n = tonumber(name)
    if n then return n end
    local want = tostring(name):lower()
    for key, value in pairs(L) do
        if key:lower() == want then return value end
    end
    return nil
end

-- The name of a LiquidType number, for messages.
function AF2.LiquidName(liquidType)
    for key, value in pairs(L) do
        if value == liquidType then return key end
    end
    return tostring(liquidType)
end

-- The liquid types `itemStruct` (an item row or an item actor's ItemData) accepts, and its capacity.
function AF2.LiquidSpec(itemStruct)
    local allowed, max = {}, 0
    pcall(function()
        local liquid = itemStruct[I.LiquidData]
        max = tonumber(liquid[LQ.MaxLiquid]) or 0
        local arr = liquid[LQ.AllowedLiquids]
        for i = 1, #arr do allowed[#allowed + 1] = tonumber(arr[i]) end
    end)
    return allowed, max
end

-- Fill `cd` (a ChangeableData) to its item's capacity. Returns the LiquidType used, or nil.
--   * `want` wins when the item accepts it; else the current liquid if accepted; else the item's
--     first accepted type - the LAST one for an energy-only item, the same best-battery pick the
--     game's charger makes.
function AF2.FillLiquid(cd, itemStruct, want)
    if not cd then return nil end
    local allowed, max = AF2.LiquidSpec(itemStruct)
    if max <= 0 or #allowed == 0 then return nil end

    local accepts, energyOnly = {}, true
    for _, t in ipairs(allowed) do
        accepts[t] = true
        if not ENERGY[t] then energyOnly = false end
    end
    local cur
    pcall(function() cur = tonumber(cd[CD.CurrentLiquid]) end)

    local pick = (want and accepts[want] and want)
        or (cur and cur ~= L.None and accepts[cur] and cur)
        or (energyOnly and allowed[#allowed])
        or allowed[1]
    local ok = pcall(function()
        cd[CD.CurrentLiquid] = pick
        cd[CD.LiquidLevel] = max
    end)
    return ok and pick or nil
end

-- Energy only: fills an item that takes nothing but battery or laser charge.
function AF2.FillEnergy(cd, itemStruct)
    local allowed = AF2.LiquidSpec(itemStruct)
    if #allowed == 0 then return false end
    for _, t in ipairs(allowed) do
        if not ENERGY[t] then return false end
    end
    return AF2.FillLiquid(cd, itemStruct) ~= nil
end

-- An inventory slot, given the item row it holds.
function AF2.FillSlotEnergy(slot, itemStruct)
    if not slot or not itemStruct then return false end
    return AF2.FillEnergy(slot[SL.ChangeableData], itemStruct)
end

-- A slot AND the live item actor spawned from it: a held or worn item keeps its own ChangeableData
-- copy, synced from the slot only when it is equipped.
function AF2.FillSlotEnergyFromItem(slot, item)
    if not slot or Utils.IsActorInvalid(item) then return false end
    local data = item.ItemData
    local a = AF2.FillSlotEnergy(slot, data)
    local b = AF2.FillEnergy(item.ChangeableData, data)
    return a and b
end

-- The live gear actors a player can wear (each keeps its own ChangeableData and ItemData copy).
local GEAR_PROPS = {
    "Gear_TorsoBP", "Gear_HelmetBP", "Gear_LegsBP", "Gear_BackpackBP", "Gear_ArmsBP", "Gear_SuitBP",
    "Gear_HeadlampBP", "Gear_TrinketBP", "Gear_WristwatchBP", "Gear_HackingDeviceBP", "Gear_ShieldBP",
    "Gear_Trinket2_BP",
}
AF2.GEAR_PROPS = GEAR_PROPS

-- Every slot of `inv` that holds an energy item, filled from the item's own row. Returns the count
-- and, in `seen`, one "row=result" entry per occupied slot.
local function fillInventoryEnergy(inv, dt, seen)
    local filled = 0
    pcall(function()
        local arr = inv.CurrentInventory
        for i = 1, #arr do
            pcall(function()
                local slot = arr[i]
                local rn = SCHEMA.RowOf(slot[SL.ItemDataTable])
                if not rn then return end
                local row = dt:FindRow(rn)
                local ok = row and AF2.FillSlotEnergy(slot, row)
                if ok then filled = filled + 1 end
                if seen then seen[#seen + 1] = rn .. (ok and "=filled" or "=skip") end
            end)
        end
    end)
    return filled
end

-- Every worn item: the equip-slot entries (from their item rows) and the live gear actors (each from
-- its own ItemData), done separately so no slot order has to be assumed. Returns the slot count and a
-- per-slot summary for logging.
function AF2.FillAllEquippedWithEnergy(pc)
    if Utils.IsActorInvalid(pc) then return 0, "" end
    local seen = {}
    local filled = 0
    local dt = ASSETS.GetDataTable("/Game/Blueprints/Items/ItemTable_Global.ItemTable_Global")
    if dt then
        local inv
        pcall(function() inv = pc.CharacterEquipSlotInventory end)
        if not Utils.IsComponentInvalid(inv) then
            filled = fillInventoryEnergy(inv, dt, seen)
            Utils.MarkReplicatedDirty(inv, "CurrentInventory")
        end
    end
    for _, prop in ipairs(GEAR_PROPS) do
        local gear
        pcall(function() gear = pc[prop] end)
        if gear and not Utils.IsActorInvalid(gear) then
            pcall(function() AF2.FillEnergy(gear.ChangeableData, gear.ItemData) end)
        end
    end
    return filled, table.concat(seen, ", ")
end

-- Every energy item a player carries: the held item (slot + live actor), worn gear, and every hotbar
-- and backpack slot. Returns how many slots were filled. The caller refreshes the hotbar
-- (AVU.RefreshHotbar - never in a hook).
function AF2.FillAllCarriedWithEnergy(pc)
    if Utils.IsActorInvalid(pc) then return 0 end
    pcall(function()
        local slot = AF2.HeldSlot(pc)
        if slot then AF2.FillSlotEnergyFromItem(slot, pc.ItemInHand_BP) end
    end)
    local filled = (AF2.FillAllEquippedWithEnergy(pc))
    local dt = ASSETS.GetDataTable("/Game/Blueprints/Items/ItemTable_Global.ItemTable_Global")
    if not dt then return filled end
    for _, prop in ipairs({ "CharacterHotbarInventory", "CharacterInventory" }) do
        local inv
        pcall(function() inv = pc[prop] end)
        if not Utils.IsComponentInvalid(inv) then
            filled = filled + fillInventoryEnergy(inv, dt)
            Utils.MarkReplicatedDirty(inv, "CurrentInventory")
        end
    end
    return filled
end

-- The selected hotbar slot, its inventory and 0-based index (InventorySlotSelected_Struct is still a
-- Blueprint struct on both builds, so AFUtils' getter holds).
function AF2.HeldSlot(pc)
    return AFUtils.GetSelectedHotbarInventoryItemSlot(pc)
end


-- =======================================================================
-- Weather
-- =======================================================================

-- Trigger a weather event by row name ("Fog", "RadLeak", ... or "None" to end one). Returns true when
-- the call was made. The row is checked against the game's own list first, and on the old build its
-- DataTablePath is carried over from there.
function AF2.TriggerWeatherEvent(name)
    if type(name) ~= "string" then return false end
    local lib = ASSETS.GetIfValid(WEATHER_LIB)
    local dnm = FindFirstOf("DayNightManager_C")
    if IsNotValid(lib) or IsNotValid(dnm) then return false end

    local path
    if name ~= "None" then
        local found = false
        pcall(function()
            local out = {}
            lib:GetAllWeatherEventRowHandles(out)
            for i = 1, #out do
                local h = out[i]:get()
                if h.RowName:ToString() == name then
                    found = true
                    if not SCHEMA.Native then path = h.DataTablePath:ToString() end
                    break
                end
            end
        end)
        if not found then return false end
    end

    return (pcall(function()
        dnm:TriggerWeatherEvent(SCHEMA.MakeHandle(name, path and { DataTablePath = path } or nil))
    end))
end


return AF2
