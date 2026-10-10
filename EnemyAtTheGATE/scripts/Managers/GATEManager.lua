
-- ============================================================
-- GATE.lua
--
-- Manages the Assault table - this determines what new assaults do
-- * Assault tables for an assault are keyed off native DT_Assaults row name
--      (e.g. "assault_pistolbros")
-- 
-- * If the assault table exists, it can have multiple entries
--     - An elegible one is chosen randomly
--     - Each entry has a storyMin/Max - which is a relative game progression in which
--        this assault can happen
--     - <!> Note this doesn't override the game limiting DT_Assault rows. 
--            "assault_peststorm_electro" won't get triggered until Labs

-- * Multiple assault files - pick one based on difficulty
--      - NORMAL, HARD, CUSTOM, AND (TODO: STALINGATE)
--      - Any assaults in CUSTOM is mixed into the selected difficulty
--      - <!> NormalCustom uses ASSAULTS_NORMAL and ASSAULTS_CUSTOM
--
-- ============================================================

---@diagnostic disable: undefined-field, undefined-global


local STATE  = require("Data.STATE")
local CONFIG = STATE.Config
local Utils  = require("Utils.Utils")

-- reference to the MOD_ROOT folder with the assault files
local _src = debug.getinfo(1, "S").source
if _src:sub(1,1) == "@" then _src = _src:sub(2) end
local MOD_ROOT = _src:match("(.+[\\/])") .. "../../"

local Log = Utils.Log
local LogBad = Utils.LogBad

local GATE = {}


local ASSAULT_TABLE = nil



-- ============================================================
-- Sets up the Assault table for the rest of the mod 
--   by reading from the assault files
-- 
-- * Based on CONFIG.DIFFICULTY
-- * Caches the table in ASSAULT_TABLE so we only need to do this once
-- ============================================================

function GATE.GetAssaultTable()
    if ASSAULT_TABLE then return ASSAULT_TABLE end

    local difficulty = CONFIG.DIFFICULTY
    local resultTable = {}

    local useCustomTable = false

    if difficulty == "Normal" or difficulty == "NormalCustom" then
        resultTable    = GATE.LoadAssaultFile("ASSAULTS_NORMAL.lua")
        useCustomTable = (difficulty == "NormalCustom")

    elseif difficulty == "Hard" or difficulty == "HardCustom" then
        resultTable    = GATE.LoadAssaultFile("ASSAULTS_HARD.lua")
        useCustomTable = (difficulty == "HardCustom")

    elseif difficulty == "Custom" then
        resultTable    = GATE.LoadAssaultFile("ASSAULTS_CUSTOM.lua")

    -- ANTEUP: a standalone assault file whose wave lists may name AnteUp
    -- VARIANTS ("Razor Pest") alongside plain DT_NPCList rows. Any assault row
    -- it doesn't define falls through to the game's own assault, same as any
    -- other standalone file. See Managers/AnteBridge.lua.
    elseif difficulty == "AnteUpNormal" or difficulty == "AnteUpNormalCustom" then
        resultTable    = GATE.LoadAssaultFile("ASSAULTS_ANTEUP_NORMAL.lua")
        useCustomTable = (difficulty == "AnteUpNormalCustom")

    else
        Utils.LogBad("[GATE] GetAssaultTable() - CONFIG.DIFFICULTY invalid: " .. tostring(difficulty))
        Utils.Chat("[GATE] invalid DIFFICULTY in CONFIG - use Normal / Hard / NormalCustom / HardCustom / Custom / AnteUpNormal")
    end

    -- Нормализуем ДО слияния: MergeTables идёт по ipairs и не видит запись,
    -- которую забыли обернуть в список
    GATE.NormalizeTable(resultTable)

    if useCustomTable then
        local custom = GATE.LoadAssaultFile("ASSAULTS_CUSTOM.lua")
        GATE.NormalizeTable(custom)
        Utils.MergeTables(resultTable, custom)
    end

    ASSAULT_TABLE = resultTable
    return ASSAULT_TABLE
end


-- ============================================================
-- Given an assault row from DT_Assaults, pick a random entry.
-- 
-- Returns (entry, index) where index is the nth assault option
--   or nil if no entries
-- ============================================================

function GATE.PickRandomAssault(assaultName)
    local assaultTable = GATE.GetAssaultTable()
    local entries = assaultTable[assaultName]
    if not entries or #entries == 0 then return nil, nil end

    local pool = {}
    local sp   = STATE.StoryProgress

    for i, entry in ipairs(entries) do
        local min = entry.StoryMin or 0
        local max = entry.StoryMax or 999
        -- Записи с Pool (пул боссов) идут только через GATE.GetPoolEntries
        if sp >= min and sp <= max and not entry.Pool then
            table.insert(pool, { data = entry, idx = i })
        end
    end

    if #pool == 0 then
        Utils.LogDebug("[GATE] PickRandomAssault() - " .. assaultName .. ": no eligible entry for StoryProgress=" .. sp, CONFIG.DEBUG_LOG)
        return nil, nil
    end

    local chosen = pool[math.random(1, #pool)]
    Utils.LogDebug(string.format("[GATE] PickRandomAssault() - %s: picked '%s' (pool=%d, SP=%d)",
        assaultName, chosen.data.Name or "?", #pool, sp), CONFIG.DEBUG_LOG)

    return chosen.data, chosen.idx
end


-- ============================================================
-- Helper that loads and an ASSAULT file and returns it
-- ============================================================
function GATE.LoadAssaultFile(filename)
    local path = MOD_ROOT .. filename
    local fn, err = loadfile(path)
    local msg = ""
    if not fn then
        msg = "ERROR - " .. filename .. ": " .. tostring(err)
        LogBad(msg)
        Utils.Chat(msg)
        return {}
    end
    local ok, result = pcall(fn)
    if not ok or type(result) ~= "table" then
        msg = "ERROR - " .. filename .. ": " .. tostring(result)
        LogBad(msg)
        Utils.Chat(msg)
        return {}
    end
    return result
end

-- -- ============================================================
-- -- Returns how many entries exist for the given row across all story ranges.
-- -- ============================================================

-- function GATE.GetRowEntryCount(assaultName)
--     local t = GATE.GetAssaultTable()
--     local entries = t[assaultName]
--     return entries and #entries or 0
-- end


-- ============================================================
-- NormalizeTable - чинит запись, записанную без внешнего списка
--
--   assault_x = { Name = "...", Wave1 = {...} }      -- так было
--   assault_x = { { Name = "...", Wave1 = {...} } }  -- так нужно
--
-- * Без обёртки #entries == 0, строка считается "нашей", но без записей,
--     и её штурм всегда перетягивается. Так было с assault_peststorm_electro
-- ============================================================

function GATE.NormalizeTable(t)
    for row, entries in pairs(t or {}) do
        if type(entries) == "table" and entries.Name ~= nil and entries[1] == nil then
            local copy = {}
            for k, v in pairs(entries) do copy[k] = v end
            for k in pairs(copy) do entries[k] = nil end
            entries[1] = copy
            Log("[GATE] NormalizeTable - " .. tostring(row) .. ": single entry wrapped into a list")
        end
    end
end


-- ============================================================
-- GetPoolEntries - все записи пула (Pool = "boss"), подходящие по этапу
--
-- * Строка, под которой лежит запись, для пула роли не играет: штурм
--     идёт в строке, которую выбрала игра. Строка нужна только для
--     истории повторов и отладочных команд
-- * Возвращает { { row, idx, data }, ... }
-- ============================================================

function GATE.GetPoolEntries(poolName)
    local t  = GATE.GetAssaultTable()
    local sp = STATE.StoryProgress
    local out = {}
    for row, entries in pairs(t) do
        for i, entry in ipairs(entries) do
            local min = entry.StoryMin or 0
            local max = entry.StoryMax or 999
            if entry.Pool == poolName and sp >= min and sp <= max then
                out[#out + 1] = { row = row, idx = i, data = entry }
            end
        end
    end
    -- pairs() не задаёт порядок; сортируем, чтобы выбор зависел только от random
    table.sort(out, function(a, b)
        if a.row ~= b.row then return a.row < b.row end
        return a.idx < b.idx
    end)
    return out
end


-- ============================================================
-- Returns true if assaultName is a key in the assault table,
-- regardless of whether any entries are eligible for the current SP.
-- Used to distinguish "GATE owns this row" from "vanilla row".
-- ============================================================

function GATE.RowExists(assaultName)
    local t = GATE.GetAssaultTable()
    return t[assaultName] ~= nil
end


-- ============================================================
-- Returns a list of all row keys in the combined table.
-- ============================================================

function GATE.GetAllAssaultRows()
    local t = GATE.GetAssaultTable()
    local rows = {}
    for k in pairs(t) do
        table.insert(rows, k)
    end
    table.sort(rows)
    return rows
end


-- ============================================================
-- TODO: Move to DebugUtils, test when combining files
-- Returns a flattened table of all the custom assaults currently
-- 
-- Returns [{ row, idx, data }]
-- * row is native assault, 
-- * data is each custom assault
-- ============================================================

function GATE.GetAllCustomAssaults()
    local t = GATE.GetAssaultTable()
    local flat = {}
    for name, entries in pairs(t) do
        for i, entry in ipairs(entries) do
            table.insert(flat, { row = name, idx = i, data = entry })
        end
    end

    table.sort(flat, function(a, b)
        if a.row ~= b.row then return a.row < b.row end
        return a.idx < b.idx
    end)
    return flat
end


return GATE
