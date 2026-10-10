-- =======================================================================
-- AVInventory (IV) - writes into a PLAYER's carried inventory, and the one safe hotbar refresh.
-- Split out of AVUtils, merged back onto AVU: callers still write AVU.RefreshHotbar /
-- ChargeNearbyItems.
--
-- MUST-KNOWS
--   * `RefreshHotbarState` has an innocent name and FIVE blocking loads behind it (deploy
--     hologram, world mesh, weapon mesh, ItemAnimBP, DeployedItemClass) with NO dedicated-server
--     guard - it is the KIZZ Hypervolt freeze. Never call it directly from drained mod code; go
--     through IV.RefreshHotbar, and only when the SELECTED item really changed.
--   * The native "Modify Item Liquid In Slot" is BANNED from the drain for the same reason (it
--     reaches that refresh through OnInventoryUpdated) - hence the inlined slot writes below.
--   * Slot structs are UserDefinedStructs, so every field needs its GUID suffix; the clean name
--     reads nil without complaining (CLAUDE.md 3).
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local ASSETS = require("AnteCore.AssetManager")
local Utils = require("AnteUtils.Utils")
local Items = require("AnteData.Items")
local SCHEMA = require("AnteData.Schema")

---@class AVU.Inventory      -- merged onto AVU in AVUtils; the name is what makes goto-def work
local IV = {}


-- Fire RefreshHotbarState safely from drained mod code. Role split:
--   * RENDERER (host/SP): direct call - the held item is being rendered, so the loads are cache
--     hits. EIGT is NOT safe here (it can flush mid component/widget paint).
--   * DEDICATED: nothing is resident -> EIGT + re-resolve BY PATH (CLAUDE.md 2 escape, 3 GC rule).

function IV.RefreshHotbar(pc)
    if Utils.IsActorInvalid(pc) then return end
    if Utils.HasRenderer() then
        pcall(function() pc:RefreshHotbarState() end)
        return
    end
    local path = Utils.ObjectPath(pc)
    if not path then return end
    ExecuteInGameThread(function()
        local p = Utils.ResolveByPath(path)
        if IsNotValid(p) then return end
        pcall(function() p:RefreshHotbarState() end)
    end)
end


-- =======================================================================
-- CHARGING CARRIED ITEMS - the pet "charging crate" passives
-- =======================================================================

local F_SLOT_ROW       = SCHEMA.Slot.ItemDataTable
local F_CHANGEABLE     = SCHEMA.Slot.ChangeableData
local F_LIQUID_LEVEL   = SCHEMA.Changeable.LiquidLevel
local F_CURRENT_LIQUID = SCHEMA.Changeable.CurrentLiquid
local F_ROW_LIQUID     = SCHEMA.Item.LiquidData
local F_ROW_MAXLIQUID  = SCHEMA.Liquid.MaxLiquid
local F_ROW_ALLOWED    = SCHEMA.Liquid.AllowedLiquids

local function liquidAllowed(liquid, liquidType)
    local allowed = liquid[F_ROW_ALLOWED]
    if not allowed then return false end
    for i = 1, #allowed do
        if allowed[i] == liquidType then return true end
    end
    return false
end

-- Add up to `amount` of `liquidType` into one ChangeableData, honouring AllowedLiquids + MaxLiquid.
-- Returns true only when the level actually changed - which matters, because the native version's
-- "did it change" test reports a CHANGE on every rejected item, and each of those would run the
-- hotbar refresh. Deliberate deviation from native: an item part-filled with a DIFFERENT liquid is
-- skipped rather than silently converted.
local function addLiquid(changeable, itemStruct, liquidType, amount)
    if not changeable or not itemStruct then return false end
    local liquid = itemStruct[F_ROW_LIQUID]
    if not liquid or not liquidAllowed(liquid, liquidType) then return false end
    local cur = changeable[F_LIQUID_LEVEL] or 0
    local curType = changeable[F_CURRENT_LIQUID] or 0
    if cur > 0 and curType ~= liquidType then return false end   -- never convert a foreign liquid
    local max = liquid[F_ROW_MAXLIQUID] or 0
    if cur >= max then return false end
    changeable[F_LIQUID_LEVEL] = math.min(cur + amount, max)
    changeable[F_CURRENT_LIQUID] = liquidType
    return true
end

-- Charge one inventory component's slot array. Marks CurrentInventory dirty when anything changed
-- (push-model: a Lua field write doesn't replicate on its own).
local function chargeSlotArray(inv, dt, liquidType, amount)
    local changed = 0
    if IsNotValid(inv) then return changed end
    local arr = inv.CurrentInventory
    if not arr then return changed end
    for i = 1, #arr do
        pcall(function()
            local slot = arr[i]
            local rn = slot[F_SLOT_ROW].RowName:ToString()
            if rn and rn ~= "None" and rn ~= "" then
                local row = dt:FindRow(rn)
                if row and addLiquid(slot[F_CHANGEABLE], row, liquidType, amount) then
                    changed = changed + 1
                end
            end
        end)
    end
    if changed > 0 then pcall(function() Utils.MarkReplicatedDirty(inv, "CurrentInventory") end) end
    return changed
end

-- Charge all of one player's carried inventories. Returns true when the HELD item charged - it
-- keeps its OWN ChangeableData copy (synced from the slot only on equip), so it gets the same
-- gated add its slot did, and that result IS the "does the hotbar need a refresh" answer.
local function chargePlayerInventories(player, dt, liquidType, amount)
    pcall(function() chargeSlotArray(player.CharacterHotbarInventory, dt, liquidType, amount) end)
    pcall(function() chargeSlotArray(player.CharacterEquipSlotInventory, dt, liquidType, amount) end)
    pcall(function()
        local add = player["Additional Inventories"]
        if add then for i = 1, #add do chargeSlotArray(add[i], dt, liquidType, amount) end end
    end)

    local heldChanged = false
    pcall(function()
        local held = player.ItemInHand_BP
        if IsValid(held) then
            heldChanged = addLiquid(held.ChangeableData, held.ItemData, liquidType, amount)
        end
    end)
    return heldChanged
end


-- [AUTHORITY] Add `amount` of `liquidType` (an ENUMS.LiquidType) to every chargeable slot of every
-- LIVE player within `radius` of `actor`. AoE by radius, so it naturally covers the owner a pet
-- follows. Stored/worn charges are pure slot data, read on the next equip or UI open.

function IV.ChargeNearbyItems(actor, liquidType, amount, radius)
    if Utils.IsActorInvalid(actor) then return end
    local loc = actor:K2_GetActorLocation()
    if not loc then return end
    -- ASSETS (immortal-listed), not a bare StaticFindObject: this runs on a ~15s pet passive, so
    -- the raw version was a recurring ~25ms UObject walk forever.
    local dt = ASSETS.GetDataTable(Items.Global.BASE)
    if not dt then return end

    local radSq = radius * radius
    for _, player in ipairs(Utils.LivePlayers()) do
        local ok, pl = pcall(function() return player:K2_GetActorLocation() end)
        if ok and pl and Utils.DistSq(loc, pl) <= radSq then
            if chargePlayerInventories(player, dt, liquidType, amount) then
                IV.RefreshHotbar(player)
            end
        end
    end
end


return IV
