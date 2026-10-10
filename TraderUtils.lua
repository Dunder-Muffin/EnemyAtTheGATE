-- =======================================================================
-- TraderUtils (TU) - edit the game's trader DataTables at RUNTIME via the UE4SS UDataTable Lua
-- API, where `dt:FindRow(name)` returns a LIVE, mutable row.
--   * Injects each trade element BY INDEX into the live BuyableItems/TradeableItems TArrays -
--     assigning a WHOLE nested-struct array natively crashes, uncatchably.
--   * A trade = { item, count, stock, cost, costCount, worldflag? }, index-paired: pay
--     `cost` x `costCount` to get `item` x `count`. worldflag "None" = always shown.
--   * AUTHORITY/runtime; edits the GLOBAL DataTable assets process-wide - target unused rows.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local Utils = require("AnteUtils.Utils")
local ASSETS = require("AnteCore.AssetManager")
local SCHEMA = require("AnteData.Schema")
local Log = Utils.Log
local LogBad = Utils.LogBad

local TU = {}

local ITEMS_DT     = "/Game/Blueprints/DataTables/NarrativeNPCs/DT_NPC_TraderItems.DT_NPC_TraderItems"
local TRADERS_DT   = "/Game/Blueprints/DataTables/NarrativeNPCs/DT_NPC_Traders.DT_NPC_Traders"
local CONV_DT      = "/Game/Blueprints/DataTables/DT_NPC_Conversations.DT_NPC_Conversations"
local GLOBAL_ITEMS = "/Game/Blueprints/Items/ItemTable_Global.ItemTable_Global"
local WORLDFLAGS   = "/Game/Blueprints/DataTables/DT_WorldFlags.DT_WorldFlags"

local F_BUYABLE   = SCHEMA.TraderItems.BuyableItems
local F_TRADEABLE = SCHEMA.TraderItems.TradeableItems
local F_ITEM2     = SCHEMA.TraderItemWF.Output
local F_ITEM5     = SCHEMA.ItemCount.Item
local F_COUNT6    = SCHEMA.ItemCount.Count
local F_WORLDFLAG = SCHEMA.TraderItemWF.WorldFlagToMakeAvailable
local F_STOCK13   = SCHEMA.TraderItemWF.AvailableStock


-- Resolve a DataTable by path, LoadAsset'ing it if needed. Now just ASSETS.GetDataTable - this was
-- one of six byte-identical copies, each re-walking the whole UObject array per call.
local function getDataTable(path)
    return ASSETS.GetDataTable(path, true)
end

-- Find a live row. Returns the row (and the table), or nil.
local function findRow(dtPath, rowName)
    local dt = getDataTable(dtPath)
    if not dt then
        LogBad("TraderUtils - UDataTable:FindRow unavailable (old UE4SS?) for " .. dtPath)
        return nil
    end
    -- FindRow expects a STRING row name, NOT an FName - passing FName(...) is a native AV.
    -- FName is only for struct FIELD values (e.g. Item_5.RowName).
    local row = dt:FindRow(rowName)
    local ok = row and pcall(function() return row:IsValid() end) and row:IsValid()
    if not ok then
        LogBad("TraderUtils - row not found: " .. tostring(rowName))
        return nil
    end
    return row, dt
end

-- Build the buyable + tradeable struct tables for one trade.
local function makeArrays(trade, globalDT)
    -- DEBUG_TRADER_WINDOW lifts story gating: "None" is an invalid handle, so every offer shows
    -- regardless of its worldflag - for testing the full trade window.
    local worldflag = (SETTINGS.DEBUG_TRADER_WINDOW and "None") or trade.worldflag or "None"
    local buyable = {
        [F_ITEM2] = {
            [F_ITEM5]  = { DataTable = globalDT, RowName = FName(trade.item) },
            [F_COUNT6] = trade.count or 1,
        },
        -- Invalid handle (RowName "None") => W_TraderScreen always shows the offer.
        [F_WORLDFLAG] = SCHEMA.MakeHandle(worldflag, { DataTablePath = WORLDFLAGS }),
        [F_STOCK13]   = trade.stock or 1,
    }
    local tradeable = {
        [F_ITEM5]  = { DataTable = globalDT, RowName = FName(trade.cost) },
        [F_COUNT6] = trade.costCount or 1,
    }
    return buyable, tradeable
end


-- True if this UE4SS build exposes the DataTable row API.
function TU.Available()
    return getDataTable(ITEMS_DT) ~= nil
end

-- Clone a live DT_NPC_TraderItems row into a NEW row via AddRow(name, <live row>) - an ENGINE
-- struct->struct copy, so nested arrays and FText/soft-ptr fields arrive intact (a Lua-table AddRow
-- AVs in UE4SS's converter instead). Lets us edit a dedicated row instead of hijacking a live game
-- row (trader_corn, trader_thule), so real stock is never clobbered. Idempotent (no-op if
-- newRowName exists); the clone also seeds SetTrades' required >=1 grow-seed.
function TU.CloneItemRow(donorRowName, newRowName)
    local dt = getDataTable(ITEMS_DT)
    if not dt then
        LogBad("TraderUtils - DT_NPC_TraderItems not resolvable (clone)")
        return false
    end
    if not dt.AddRow then
        LogBad("TraderUtils - AddRow unavailable in this UE4SS build; cannot clone '" .. tostring(newRowName) .. "'")
        return false
    end

    local existing
    pcall(function() existing = dt:FindRow(newRowName) end)
    if existing and pcall(function() return existing:IsValid() end) and existing:IsValid() then
        return true   -- already cloned this session
    end

    local src = dt:FindRow(donorRowName)
    if not (src and pcall(function() return src:IsValid() end) and src:IsValid()) then
        LogBad("TraderUtils - clone donor row '" .. tostring(donorRowName) .. "' not found")
        return false
    end

    local ok, err = pcall(function() dt:AddRow(newRowName, src) end)
    if not ok then
        LogBad("TraderUtils - CloneItemRow AddRow errored: " .. tostring(err))
        return false
    end

    local check
    pcall(function() check = dt:FindRow(newRowName) end)
    local found = (check and pcall(function() return check:IsValid() end) and check:IsValid()) or false
    if found then
        Log(("TraderUtils - cloned item row '%s' -> '%s'"):format(donorRowName, newRowName))
    else
        LogBad("TraderUtils - CloneItemRow verify failed for '" .. tostring(newRowName) .. "'")
    end
    return found
end

-- WorldFlag row used to HIDE leftover trade slots. W_TraderScreen skips a trade whose
-- WorldFlagToMakeAvailable is a VALID handle naming a flag the world lacks, and IsRowHandleValid
-- verifies existence - a made-up name fell through to "shown". So use the game's own
-- "DemoNeverSet": a real row that is never set outside the demo build.
local HIDDEN_FLAG = "DemoNeverSet"

-- Set a DT_NPC_TraderItems row's trades to exactly `trades` (slots 1..N), GROW-THEN-OVERWRITE.
-- Can't grow a UE4SS TArray by assigning to a new index (issue #435 corrupts the slot); appending
-- a COPY of an existing element is safe, so this grows both arrays to N by copying element 1, then
-- overwrites slots 1..N in-bounds (requires >=1 element to seed from). Can't shrink either -
-- opts.hideExtras retargets leftover slots at a never-set worldflag so the trade screen hides them.
local nativeTradesNoted = {}

function TU.SetTrades(itemRowName, trades, opts)
    opts = opts or {}
    -- Native layout: a trade's output is an FInstancedStruct, which this UE4SS can neither read into
    -- nor build, and the game exposes no setter for one. The row keeps its donor's trades.
    if SCHEMA.Native then
        if not nativeTradesNoted[itemRowName] then
            nativeTradesNoted[itemRowName] = true
            LogBad("TraderUtils - custom trades can't be written on this game build (trade outputs are "
                .. "FInstancedStruct); '" .. tostring(itemRowName) .. "' keeps its donor's trades")
        end
        return false
    end
    local globalDT = getDataTable(GLOBAL_ITEMS)
    if not globalDT or not pcall(function() return globalDT:IsValid() end) or not globalDT:IsValid() then
        LogBad("TraderUtils - global item table not resolvable")
        return false
    end

    local row = findRow(ITEMS_DT, itemRowName)
    if not row then return false end

    local want = #trades
    if want == 0 then return true end

    local hidden = 0
    local ok, err = pcall(function()
        if row[F_BUYABLE]:GetArrayNum() < 1 or row[F_TRADEABLE]:GetArrayNum() < 1 then
            error("row '" .. itemRowName .. "' has no seed element to grow from")
        end
        -- 1) GROW to `want` by appending COPIES of element 1. Re-fetch the array each iteration:
        --    an append reallocates, dangling the old wrapper.
        while row[F_BUYABLE]:GetArrayNum() < want do
            local a = row[F_BUYABLE]; a[a:GetArrayNum() + 1] = a[1]
        end
        while row[F_TRADEABLE]:GetArrayNum() < want do
            local a = row[F_TRADEABLE]; a[a:GetArrayNum() + 1] = a[1]
        end
        -- 2) OVERWRITE slots 1..want (now all in-bounds) with our trade structs.
        for i = 1, want do
            local b, t = makeArrays(trades[i], globalDT)
            row[F_BUYABLE][i]   = b
            row[F_TRADEABLE][i] = t
        end
        -- 3) HIDE leftover vanilla slots (want+1..end) by retargeting just their worldflag field
        --    at the never-set flag - an in-place nested C++-struct write, so safe.
        if opts.hideExtras then
            for i = want + 1, row[F_BUYABLE]:GetArrayNum() do
                row[F_BUYABLE][i][F_WORLDFLAG] = SCHEMA.MakeHandle(HIDDEN_FLAG, { DataTablePath = WORLDFLAGS })
                hidden = hidden + 1
            end
        end
    end)
    if not ok then LogBad("TraderUtils - SetTrades failed: " .. tostring(err)); return false end
    Log(("TraderUtils - set %d trade(s) in '%s'%s"):format(want, itemRowName,
        hidden > 0 and (" (+%d leftover slot(s) hidden)"):format(hidden) or ""))
    return true
end

-- Point a DT_NPC_Traders row's inventory at a DT_NPC_TraderItems row (mutates the live handle's
-- fields in place). Returns true on success.
function TU.SetTraderInventory(traderRowName, itemRowName)
    local row = findRow(TRADERS_DT, traderRowName)
    if not row then return false end
    local itemsDT = getDataTable(ITEMS_DT)
    if not itemsDT then return false end
    local ok, err = pcall(function() SCHEMA.SetRow(row.NPCTradeInventory, itemRowName, itemsDT) end)
    if not ok then LogBad("TraderUtils - SetTraderInventory failed: " .. tostring(err)); return false end
    return true
end

-- Point a DT_NPC_Traders row's NPCConversation at a DT_NPC_Conversations row. Drives the trader's
-- NAME (the conv row's NPCName FText) in the trade-screen title. Returns true on success.
function TU.SetTraderConversation(traderRowName, convRowName)
    local row = findRow(TRADERS_DT, traderRowName)
    if not row then return false end
    local convDT = getDataTable(CONV_DT)
    if not convDT then return false end
    local ok, err = pcall(function() SCHEMA.SetRow(row.NPCConversation, convRowName, convDT) end)
    if not ok then LogBad("TraderUtils - SetTraderConversation failed: " .. tostring(err)); return false end
    return true
end


-- Replace a conversation's INTERACTION lines with BECKON lines. Interaction lines carry posed
-- montages (the fisherman's sit/mock); beckon lines are plain. Every InitalContactMessages/
-- ReturnMessages slot gets a COPY of a BeckoningLine, cycling and growing to fit so the random
-- per-speak pick still varies. Safe: NPCConversation is a native struct, not the UserDefinedStruct
-- that crashes on whole-array assignment.
function TU.SpeakBeckonOnInteract(convRowName)
    local row = findRow(CONV_DT, convRowName)
    if not row then return false end
    local ok, err = pcall(function()
        local beckon = row.BeckoningLines
        local bn = beckon:GetArrayNum()
        if bn < 1 then error("'" .. convRowName .. "' has no BeckoningLines") end
        for _, cat in ipairs({ "InitalContactMessages", "ReturnMessages" }) do
            local arr = row[cat]
            -- grow to at least bn slots (by copying element 1) so every beckon line is represented
            local want = math.max(arr:GetArrayNum(), bn)
            while arr:GetArrayNum() < want do local a = arr; a[a:GetArrayNum() + 1] = a[1] end
            -- overwrite every slot; the cycle + random pick at speak time gives variety
            for i = 1, arr:GetArrayNum() do arr[i] = beckon[((i - 1) % bn) + 1] end
        end
    end)
    if not ok then LogBad("TraderUtils - SpeakBeckonOnInteract failed: " .. tostring(err)); return false end
    Log("TraderUtils - '" .. convRowName .. "' interact lines set to beckon lines")
    return true
end


return TU
