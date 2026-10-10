-- ============================================================
-- Variety.lua
-- Разнообразие штурмов поверх файлов ASSAULTS_*:
--
-- (1) ПРИМЕШИВАНИЕ ВАРИАНТОВ (CONFIG.VARIANT_INFUSION)
--     Каждый обычный слот волны с шансом становится вариантом AnteUp
--     той же базы, разрешённым на текущем этапе (ANTEUP_VARIANTS.lua).
--
-- (2) МОДИФИКАТОРЫ (CONFIG.MUTATORS)
--     С шансом к штурму добавляется одно из:
--       Weather   - погода на время штурма (только записям без своего OnStart)
--       Crossfire - отряд враждебной фракции высаживается на точку волны
--                   и сначала бьёт по штурмующим
--       Elite     - в каждую волну встаёт один усиленный враг
--
-- Всё это работает на КОПИИ записи: запись в кэше ASSAULT_TABLE не меняется,
-- следующий штурм с той же записью бросает кубики заново.
--
-- Записи пула боссов (Pool = "boss") и записи с NoVariety = true
-- не трогаются: они собраны вручную.
-- ============================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE  = require("Data.STATE")
local CONFIG = STATE.Config
local Utils  = require("Utils.Utils")
local AB     = require("Managers.AnteBridge")
local EM     = require("Managers.EventManager")

local Log      = Utils.Log
local LogBad   = Utils.LogBad
local LogDebug = Utils.LogDebug

local V = {}

local WAVE_KEYS = { "Wave1", "Wave2", "Wave3", "BossWave" }

-- Корень мода: этот файл лежит в <mod>/scripts/Managers/
local _src = debug.getinfo(1, "S").source
if _src:sub(1, 1) == "@" then _src = _src:sub(2) end
local MOD_ROOT = _src:match("(.+[\\/])") .. "../../"


-- ============================================================
-- Данные ANTEUP_VARIANTS.lua - грузим один раз за сессию.
-- Ошибка в файле не ломает штурмы: примешивание просто выключается.
-- ============================================================
local DATA = nil

local function getData()
    if DATA then return DATA end
    DATA = { Infusion = {}, Elite = {} }

    local fn, err = loadfile(MOD_ROOT .. "ANTEUP_VARIANTS.lua")
    if not fn then
        LogBad("[GATE] Variety - ANTEUP_VARIANTS.lua not loaded: " .. tostring(err))
        return DATA
    end
    local ok, result = pcall(fn)
    if ok and type(result) == "table" then
        DATA.Infusion = result.Infusion or {}
        DATA.Elite    = result.Elite    or {}
    else
        LogBad("[GATE] Variety - ANTEUP_VARIANTS.lua error: " .. tostring(result))
    end
    return DATA
end


-- ============================================================
-- Вспомогательное
-- ============================================================

-- "Velites Guard@Grunt_Guard" -> "Velites Guard"
local function variantPart(name)
    return string.match(name, "^(.-)@") or name
end

-- Слот волны - обычная строка DT_NPCList, а не вариант?
-- Варианты пишутся с пробелом, "@" задаёт тело варианта.
local function isPlainRow(entry)
    return not string.find(entry, " ", 1, true) and not string.find(entry, "@", 1, true)
end

-- Варианты базы, разрешённые на этапе sp и известные AnteUp
local function candidates(base, sp, map)
    local out = {}
    for _, e in ipairs(getData().Infusion[base] or {}) do
        local name, minSp = e[1], e[2] or 0
        if sp >= minSp and map[variantPart(name)] then
            out[#out + 1] = { name = name, min = minSp }
        end
    end
    return out
end

-- Копия списка волны
local function copyList(list)
    local out = {}
    for i, v in ipairs(list or {}) do out[i] = tostring(v) end
    return out
end

-- Шанс примешивания на текущем этапе
local function infusionChance(sp)
    local cfg = CONFIG.VARIANT_INFUSION
    if not cfg or not cfg.Enabled then return 0 end
    if cfg.LateStory and sp >= cfg.LateStory and cfg.LateChance then
        return cfg.LateChance
    end
    return cfg.Chance or 0
end

-- Сообщение в чат с задержкой: хук директора - не место для записи в виджет чата
local function announce(msg)
    Utils.DelayedGameThread(2000, function() Utils.Chat(msg) end)
end


-- ============================================================
-- (1) Примешивание: каждый обычный слот с шансом chance
--     становится случайным подходящим вариантом.
-- Возвращает новый список и число замен.
-- ============================================================
function V.InfuseList(list, chance, sp, map)
    local out, changed = {}, 0
    for i, raw in ipairs(list or {}) do
        local entry = tostring(raw)
        if chance > 0 and isPlainRow(entry) and math.random() < chance then
            local c = candidates(entry, sp, map)
            if #c > 0 then
                entry = c[math.random(1, #c)].name
                changed = changed + 1
            end
        end
        out[i] = entry
    end
    return out, changed
end


-- ============================================================
-- (2a) Elite - по одному усиленному врагу на волну.
-- В каждой волне выбираем случайный обычный слот, у базы которого есть
-- элитная замена (Elite) или хотя бы один вариант (берём самый поздний).
-- ============================================================
local function eliteFor(base, sp, map)
    local e = getData().Elite[base]
    if e and sp >= (e[2] or 0) and map[variantPart(e[1])] then
        return e[1]
    end
    local best
    for _, c in ipairs(candidates(base, sp, map)) do
        if not best or c.min >= best.min then best = c end
    end
    return best and best.name or nil
end

local function applyElite(data, sp, map)
    local total = 0
    for _, key in ipairs(WAVE_KEYS) do
        local list = data[key]
        if list and #list > 0 then
            -- слоты, которые можно усилить
            local slots = {}
            for i, entry in ipairs(list) do
                if isPlainRow(entry) and eliteFor(entry, sp, map) then slots[#slots + 1] = i end
            end
            if #slots > 0 then
                local i = slots[math.random(1, #slots)]
                list[i] = eliteFor(list[i], sp, map)
                total = total + 1
            end
        end
    end
    return total > 0
end


-- ============================================================
-- (2b) Weather - случайная погода на 2-3 минуты.
-- Только для записей без своего OnStart: у записи с OnStart может быть
-- своя погода, и две погоды перебили бы друг друга.
-- ============================================================
local WEATHER_EARLY = { "Fog", "Spores", "RadLeak", "ColdSnap" }
local WEATHER_LATE  = { "Fog", "Spores", "RadLeak", "ColdSnap", "BlackFog", "Blackout" }

local function makeWeather(sp)
    local pool = (sp >= 50) and WEATHER_LATE or WEATHER_EARLY
    local weather = pool[math.random(1, #pool)]
    -- задержка 15с от начала подготовки (20с) - погода накрывает базу до первой волны
    return EM.AssaultWeather(weather, math.random(120, 180) * 1000, 15000), weather
end


-- ============================================================
-- (2c) Crossfire - отряд другой фракции на точке волны.
-- Фракция штурма определяется большинством слотов. Отряд проходит через
-- то же примешивание, поэтому в нём тоже бывают варианты.
-- ============================================================
local function factionOf(row)
    if not row then return nil end
    if row:match("^Grunt") or row:match("^Trooper") or row:match("^Groupe") or row == "Interfector" then
        return "Order"
    end
    if row:match("^Exor") or row:match("^Pest") or row:match("^Peccary") or row == "Sow" then
        return "Exor"
    end
    if row:match("^Gatekeeper") or row:match("^DarkLens") or row:match("^Robot") then
        return "Gatekeepers"
    end
    if row:match("^Pillager") then return "Canaan" end
    if row:match("^Zombie") then return "Zombie" end
    return nil
end

local function mainFaction(data, map)
    local votes, best, bestN = {}, nil, 0
    for _, key in ipairs(WAVE_KEYS) do
        for _, raw in ipairs(data[key] or {}) do
            local entry = tostring(raw)
            local name, body = string.match(entry, "^(.-)@(.+)$")
            local base = body or map[name or entry] or entry
            local f = factionOf(base)
            if f then
                votes[f] = (votes[f] or 0) + 1
                if votes[f] > bestN then best, bestN = f, votes[f] end
            end
        end
    end
    return best
end

-- Отряды-соперники: { кого бьём = { { этап, { строки } }, ... } }
-- Берётся самый поздний отряд, чей этап уже наступил.
local RIVAL_SQUADS = {
    Order = {
        { 0,  { "Exor_Monk", "Exor_Monk", "Exor" } },
        { 52, { "Exor_Monk", "Exor", "Exor_Armored" } },
        { 70, { "Exor", "Exor_Armored", "Exor_Volatile", "Exor_Monk" } },
    },
    Exor = {
        { 0,  { "Grunt", "Grunt_Guard", "Grunt_Captain" } },
        { 40, { "Grunt", "Grunt_Shotgun", "Grunt_Captain", "Grunt_Medic" } },
        { 80, { "Trooper", "Trooper_Shield", "Grunt_Shotgun", "Grunt_Captain" } },
    },
    Gatekeepers = {
        { 0,  { "Grunt", "Grunt_Shotgun", "Grunt_Captain", "Grunt_Medic" } },
        { 80, { "Trooper", "Trooper_Shield", "Trooper_Shotgun", "Grunt_Captain" } },
    },
    Canaan = {
        { 0,  { "Exor_Monk", "Exor_Monk", "Exor" } },
        { 52, { "Exor_Monk", "Exor", "Exor_Armored" } },
    },
    Zombie = {
        { 0,  { "Grunt", "Grunt_Guard", "Grunt_Captain" } },
        { 40, { "Grunt", "Grunt_Shotgun", "Grunt_Captain" } },
    },
}

local function makeCrossfire(data, sp, map, chance)
    local target = mainFaction(data, map)
    local squads = target and RIVAL_SQUADS[target]
    if not squads then return nil end

    local squad
    for _, s in ipairs(squads) do
        if sp >= s[1] then squad = s[2] end
    end
    if not squad then return nil end

    local units = V.InfuseList(copyList(squad), chance, sp, map)
    return EM.VariantDrop(math.random(15, 35) * 1000, {
        units            = units,
        spawnAtWavePoint = true,
        favoredEnemy     = target,
        spawnInterval    = 800,
    }), target
end


-- ============================================================
-- Выбор модификатора по весам из списка available.
-- Вес 0 отсеивается ещё при сборке списка в V.Prepare.
-- ============================================================
local function rollMutator(available)
    local weights = (CONFIG.MUTATORS and CONFIG.MUTATORS.Weights) or {}
    local total = 0
    for _, name in ipairs(available) do total = total + (weights[name] or 1) end
    if total <= 0 then return nil end
    local r = math.random() * total
    for _, name in ipairs(available) do
        r = r - (weights[name] or 1)
        if r <= 0 then return name end
    end
    return available[#available]
end

-- Подшить дополнительную функцию к OnStart записи.
-- Каждая часть в своём pcall, чтобы ошибка одной не отменила другую.
local function chainOnStart(data, extra)
    local orig = data.OnStart
    data.OnStart = function()
        if type(orig) == "function" then
            local ok, err = pcall(orig)
            if not ok then LogBad("[GATE] Variety - entry OnStart error: " .. tostring(err)) end
        end
        local ok2, err2 = pcall(extra)
        if not ok2 then LogBad("[GATE] Variety - mutator OnStart error: " .. tostring(err2)) end
    end
end


-- ============================================================
-- Главная точка входа: вернуть копию записи для этого штурма.
-- Вызывается из AssaultManager.SCM_ApplyAssaultData.
-- ============================================================
function V.Prepare(data)
    -- (0) Поверхностная копия записи и копии списков волн
    local out = {}
    for k, v in pairs(data) do out[k] = v end
    for _, key in ipairs(WAVE_KEYS) do
        if data[key] then out[key] = copyList(data[key]) end
    end

    -- Записи боссов и помеченные NoVariety - без изменений
    if data.Pool or data.NoVariety then return out end

    -- Без живого AnteUp вариантов нет: превращать некому
    local map = AB.IsAnteUpLive() and AB.GetVariantMap() or nil
    local sp  = STATE.StoryProgress or 0
    local notes = {}

    -- (1) Примешивание
    local chance = map and infusionChance(sp) or 0
    if chance > 0 then
        local changed = 0
        for _, key in ipairs(WAVE_KEYS) do
            if out[key] then
                local n
                out[key], n = V.InfuseList(out[key], chance, sp, map)
                changed = changed + n
            end
        end
        if changed > 0 then notes[#notes + 1] = changed .. " variant slot(s)" end
    end

    -- (2) Модификатор
    local mcfg = CONFIG.MUTATORS
    if mcfg and mcfg.Enabled and math.random() < (mcfg.Chance or 0) then
        -- Кандидаты: вес 0 в CONFIG выключает модификатор совсем
        local weights = mcfg.Weights or {}
        local available = {}
        local function offer(name)
            if (weights[name] or 1) > 0 then available[#available + 1] = name end
        end
        if not data.OnStart then offer("Weather") end
        if map then
            offer("Crossfire")
            offer("Elite")
        end

        -- Бросаем по весам; если выпавший модификатор к записи не подходит
        -- (некого усилить, непонятна фракция), убираем его и бросаем снова
        local label
        while not label and #available > 0 do
            local picked = rollMutator(available)
            if not picked then break end
            for i, name in ipairs(available) do
                if name == picked then table.remove(available, i) break end
            end

            if picked == "Weather" then
                local fn, weather = makeWeather(sp)
                chainOnStart(out, fn)
                label = "weather: " .. weather

            elseif picked == "Crossfire" then
                local fn, target = makeCrossfire(out, sp, map, chance)
                if fn then
                    chainOnStart(out, fn)
                    label = "crossfire vs " .. target
                end

            elseif picked == "Elite" then
                if applyElite(out, sp, map) then label = "elite wave" end
            end
        end

        if label then
            notes[#notes + 1] = "mutator " .. label
            if mcfg.Announce then announce("[GATE] Assault modifier - " .. label) end
        end
    end

    if #notes > 0 then
        Log(string.format("[GATE] Variety - %s: %s", tostring(data.Name or "?"), table.concat(notes, ", ")))
    end
    return out
end


return V
