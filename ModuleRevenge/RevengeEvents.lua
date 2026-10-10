-- =======================================================================
-- RevengeEvents (RE) - the OnStart primitives a revenge assault composes in ModuleRevenge/
-- RevengeAssaults.lua. AUTHORITY.
--
--     OnStart = RE.Sequence(
--         RE.Weather("Fog", 240000, 5000),
--         RE.OrderDrop(5000, { spawns = { guards = 2, captains = 1 } })
--     )
--
-- Every RE.* is a FACTORY: returns a closure, called once by RevengeDirector at assault start.
-- Nothing here runs at file-load time. Full reasoning: AnNotes/Modules/RevengeDirector.md.
--
-- MUST-KNOWS
--   * A drop is not a wave: waves walk the director's spawn path, a drop rings the bench NOW.
--   * Delays measure from END OF PREP, not the call (prepDelay() adds STATE.RevengePrepMs) -
--     the two weather primitives (RE.Weather / RE.SpecialWeather) are the exception, so fog can
--     roll in during the warning.
--   * THREADING: spawns go via Utils.QueueWork -> EVU.SpawnAt. Never spawn directly from a
--     closure - it runs inside RevengeDirector's SortAssaultSpawnLists hook.
--   * AVU.ForceWeather is EIGT-wrapped (TriggerWeatherEvent blocking-loads FX) - don't move it
--     back onto QueueWork.
--   * Unit keys match EnemyAtTheGATE's DIRECT_UNITS so drop lists port between mods; RE.Drop
--     also accepts Antevariant names directly.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local ASSETS = require("AnteCore.AssetManager")
local EVU = require("ModuleStory.EventUtils")

local LogBad = Utils.LogBad
local LogDebug = Utils.LogDebug

local RE = {}

-- Drop placement defaults. A ring, never a disc: minRadius keeps bodies off the crafting bench
-- itself, radius keeps them inside the base's fight rather than out in the dark.
local DROP_RADIUS     = 3500
local DROP_MIN_RADIUS = 2000
local DROP_INTERVAL   = 500    -- ms between bodies in one drop
local DROP_Z_DELTA    = 250    -- how far off the bench's floor a spawn point may sit
local AGGRO_DELAY_MS  = 1500   -- a fresh body's controller/BT isn't up instantly (AVU.ForceAggro)

-- The native prep window, used when the director hasn't told us otherwise yet.
local DEFAULT_PREP_MS = 20000


-- =======================================================================
-- Shared plumbing
-- =======================================================================

-- Delay measured from the end of prep. See the MUST-KNOWS.
local function prepDelay(ms)
    return (ms or 0) + (STATE.RevengePrepMs or DEFAULT_PREP_MS)
end

-- The bench this assault is targeting, plus its location. nil once the assault is over, which is
-- exactly the "don't land a late drop" test every queued spawn needs.
--   * Deliberately re-resolved per body rather than captured: a drop can outlive the bench (a
--     player dismantles it mid-fight), and a captured wrapper would be a freed pointer (CLAUDE.md 3).
--   * `anyPhase` also answers during PREP (phase 1), which IsAssaultHappening() reports as false.
--     Drops want the waves-only reading; weather timed off the warning wants this one.
local function assaultBench(anyPhase)
    local dir = Utils.GetAIDirectorActor()   -- cached: this runs once PER SPAWNED BODY
    if not dir or IsNotValid(dir) then return nil end

    local happening = false
    if anyPhase then
        local phase
        pcall(function() phase = tonumber(dir.Assault_CurrentPhase) end)
        happening = phase ~= nil and phase ~= 0 and phase ~= 6
    else
        pcall(function() happening = dir:IsAssaultHappening() end)
    end
    if not happening then return nil end

    local bench = dir.TargetAssaultBench
    if not bench or IsNotValid(bench) then return nil end

    local ok, loc = pcall(function() return bench:K2_GetActorLocation() end)
    if not ok or not loc then return nil end

    -- COPY the vector: the returned struct rides UE4SS's params buffer and this one is held
    -- across the spawn hop (the TraderDirector nearestBench lesson).
    return bench, FVector(loc.X, loc.Y, loc.Z)
end

-- Place ONE body in the ring and point it at the base.
local function dropOne(name, opts)
    local _, benchLoc = assaultBench()
    if not benchLoc then return end        -- assault ended, or the bench is gone: drop nothing

    -- zClearance 0 = the FEET. EVU.SpawnAt applies the capsule lift itself, and doing it in both
    -- places puts the body a metre in the air (the TraderDirector FloorZ note).
    local spot = Utils.GetSpawnPoint(benchLoc,
        opts.radius or opts.spawnRadius or DROP_RADIUS,
        opts.minRadius or opts.minSpawnRadius or DROP_MIN_RADIUS,
        nil, DROP_Z_DELTA, 0)
    if not spot then return end

    EVU.SpawnAt(name, spot, {
        Exact = true,                      -- GetSpawnPoint already chose the point; don't re-roll it
        callback = function(npc)
            if Utils.IsActorInvalid(npc) then return end
            -- Onto the BENCH, not a player: an assault body that beelines the base is what makes a
            -- drop read as a raid. It re-targets to whoever shoots it as normal. Re-read from the
            -- director, not the bench held across the spawn: a deployable carries no departed stamp.
            local bench = assaultBench()
            if bench then AVU.ForceAggro(npc, bench, AGGRO_DELAY_MS) end
        end,
    })
end

-- Queue a whole drop: `names` is a flat list, one body per entry, staggered by `interval`.
local function benchDrop(names, delayMs, opts, label)
    opts = opts or {}
    if #names == 0 then return end

    local interval = opts.spawnInterval or DROP_INTERVAL
    local base = prepDelay(delayMs)

    for i, name in ipairs(names) do
        Utils.QueueWork(function()
            if not STATE.ModEnabled then return end
            dropOne(name, opts)
        end, base + (i - 1) * interval)
    end

    LogDebug(string.format("Revenge - %s queued: %d bodies from +%dms", label or "drop", #names, base),
        SETTINGS.DEBUG_STORY)
end

-- Expand an { key = count } table into a flat list of row names via `units`.
--   * An unknown key is a typo and would silently shrink the drop, so it is logged loudly.
local function expand(spawns, units, label)
    local out = {}
    for key, count in pairs(spawns or {}) do
        local row = units[key]
        if not row then
            LogBad(string.format("Revenge - %s: unknown unit key '%s' (drop will be short)",
                label or "drop", tostring(key)))
        else
            for _ = 1, (tonumber(count) or 0) do out[#out + 1] = row end
        end
    end
    return out
end


-- =======================================================================
-- UNIT TABLES - the { key = count } vocabulary of the faction drops.
-- Keys match EnemyAtTheGATE's DIRECT_UNITS so drop lists port between the mods verbatim.
-- =======================================================================

local PEST_UNITS = {
    pests = "Pest",                   electros     = "Pest_Electro",
    volatiles = "Pest_Volatile",      winters      = "Pest_Snow",
    carbonateds = "Pest_Carbonated",  rats         = "Pest_Rat",
    leyaks = "Pest_Leyak",            magmas       = "Pest_Magma",
    enlighteneds = "Pest_Enlightened",
}

local PECCARY_UNITS = {
    peccaries = "Peccary",            sows      = "Sow",
    mushrooms = "Peccary_Mushroom",   alphas    = "Peccary_Alpha",
    winters   = "Peccary_Snow",       electros  = "Peccary_Electro",
    armoreds  = "Peccary_Armored",    volatiles = "Peccary_Volatile",
}

local EXOR_UNITS = {
    monks = "Exor_Monk",   exors     = "Exor",           armoreds = "Exor_Armored",
    pikemen = "Exor_Pikeman",         volatiles = "Exor_Volatile",
}

local ORDER_UNITS = {
    guards = "Grunt_Guard",       grunts    = "Grunt",          medics  = "Grunt_Medic",
    captains = "Grunt_Captain",   breachers = "Grunt_Shotgun",  snipers = "Grunt_Sniper",
    interfectors = "Interfector", labRats   = "Grunt_LabRat",   sappers = "Grunt_Sapper",
    flameRats = "Grunt_FlameRat", troopers  = "Trooper",        rooks   = "Trooper_Shield",
}


-- =======================================================================
-- THE PRIMITIVES
-- =======================================================================

-- Run several OnStart closures in order, in ONE closure. Each is pcall'd, so a thrower can't take
-- the rest of the assault's opening down with it.
function RE.Sequence(...)
    local steps = { ... }
    return function()
        for i, step in ipairs(steps) do
            if type(step) ~= "function" then
                LogBad("Revenge - Sequence step " .. i .. " is not a function")
            else
                local ok, err = pcall(step)
                if not ok then LogBad("Revenge - Sequence step " .. i .. ": " .. tostring(err)) end
            end
        end
    end
end


-- Global weather for the assault, with an automatic expiry back to "None".
--   * Valid names: Fog, RadLeak, Spores, ColdSnap, Blackout, BlackFog (AFUtils.WeatherEvents).
--     Anything else silently does nothing, so it is validated here instead.
--   * `delay` is NOT prep-offset - weather during the warning is the point, and it is what makes a
--     revenge announce itself before the first body arrives.
--   * DelayedGameThread (not QueueWork): AVU.ForceWeather must reach a clean game-thread flush.
function RE.Weather(weather, duration, delay)
    duration = duration or 60000
    delay    = delay    or 0

    return function()
        local AFUtils = require("AFUtils.AFUtils")
        if not AFUtils.WeatherEvents[weather] then
            LogBad("Revenge - unknown weather '" .. tostring(weather) ..
                   "' (expected Fog/RadLeak/Spores/ColdSnap/Blackout/BlackFog)")
            return
        end

        STATE.RevengeWeather = weather
        Utils.DelayedGameThread(delay, function()
            LogDebug("Revenge - weather -> " .. weather, SETTINGS.DEBUG_STORY)
            AVU.ForceWeather(weather)
        end)

        -- Clear only if nothing else took the weather over in the meantime, so a later
        -- RE.Weather in the same Sequence isn't cancelled by an earlier one expiring.
        Utils.DelayedGameThread(delay + duration, function()
            if STATE.RevengeWeather ~= weather then return end
            STATE.RevengeWeather = nil
            AVU.ForceWeather("None")
        end)
    end
end


-- LOCALIZED weather centred on the ASSAULT BENCH, with a hard expiry.
--   * Kinds: "Whiteout" - the V_Alps blizzard (AVU.TriggerBlizzard). Cosmetic for players inside
--     the box (snow, 2D audio, shake); behaviours read AVU.BlizzardActiveNear instead.
--   * `delay` counts from the OnStart call like RE.Weather, NOT from the end of prep - so
--     "N seconds after the start banner" is written as prep + N.
--   * Self-expiring by construction: the zone, the niagara and the audio each carry `duration`
--     and the registry entry expires by tick. There is no clear call to miss, so a storm can
--     outlive the assault by at most its own duration.
--   * The blizzard set is warmed at OnStart and re-loaded (a cache hit) right before each storm;
--     the local render spawns the niagara in-drain and needs it resident.
--   * opts.Size - half-extents in uu (default per kind). Centred on the bench regardless of roof;
--     the ambient Winter loop's roof check is deliberately not applied to a base under attack.
local SPECIAL_WEATHER = {
    Whiteout = { Size = 2500, Assets = AVU.BLIZZARD_ASSETS },
}

function RE.SpecialWeather(kind, duration, delay, opts)
    duration = duration or 10000
    delay    = delay    or 0
    opts     = opts     or {}

    return function()
        local spec = SPECIAL_WEATHER[kind]
        if not spec then
            LogBad("Revenge - unknown special weather '" .. tostring(kind) .. "' (expected Whiteout)")
            return
        end
        ASSETS.WarmPinned(spec.Assets)

        Utils.QueueWork(function()
            if not STATE.ModEnabled then return end
            ASSETS.LoadAsync(spec.Assets, function()
                if not STATE.ModEnabled then return end
                local _, benchLoc = assaultBench(true)
                if not benchLoc then return end        -- assault over, or the bench is gone
                AVU.TriggerBlizzard(benchLoc, { Duration = duration / 1000, Size = opts.Size or spec.Size })
                LogDebug(string.format("Revenge - %s on the bench for %ds", kind, duration / 1000),
                    SETTINGS.DEBUG_STORY)
            end)
        end, delay)
    end
end


-- Drop a list of Antevariants and/or raw DT rows in the ring around the bench.
--   * The general form. `opts.units = { "Velites Guard", "Grunt_Captain", "Pest" }` - one body per
--     entry, so repeat a name to get several.
--   * Reach for this over the faction drops when the drop wants VARIANTS; the faction drops speak
--     in plain base rows by design (they mirror EATG's vocabulary).
function RE.Drop(delay, opts)
    opts = opts or {}
    local names = opts.units or {}
    return function() benchDrop(names, delay or 1000, opts, "Drop") end
end

-- opts.spawns: pests, electros, volatiles, winters, carbonateds, rats, leyaks, magmas, enlighteneds
function RE.PestDrop(delay, opts)
    opts = opts or {}
    return function()
        benchDrop(expand(opts.spawns, PEST_UNITS, "PestDrop"), delay or 1000, opts, "PestDrop")
    end
end

-- opts.spawns: peccaries, sows, mushrooms, alphas, winters, electros, armoreds, volatiles
function RE.PeccaryDrop(delay, opts)
    opts = opts or {}
    return function()
        benchDrop(expand(opts.spawns, PECCARY_UNITS, "PeccaryDrop"), delay or 1000, opts, "PeccaryDrop")
    end
end

-- opts.spawns: monks, exors, armoreds, pikemen, volatiles
--   * Exors portal in as part of their own spawn animation, so a tighter ring reads better.
function RE.ExorDrop(delay, opts)
    opts = opts or {}
    opts.radius    = opts.radius    or opts.spawnRadius    or 2000
    opts.minRadius = opts.minRadius or opts.minSpawnRadius or 1200
    return function()
        benchDrop(expand(opts.spawns, EXOR_UNITS, "ExorDrop"), delay or 1000, opts, "ExorDrop")
    end
end

-- opts.spawns: guards, grunts, medics, captains, breachers, snipers, interfectors,
--              labRats, sappers, flameRats, troopers, rooks
function RE.OrderDrop(delay, opts)
    opts = opts or {}
    return function()
        benchDrop(expand(opts.spawns, ORDER_UNITS, "OrderDrop"), delay or 1000, opts, "OrderDrop")
    end
end


return RE
