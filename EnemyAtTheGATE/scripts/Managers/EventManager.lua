---@diagnostic disable: undefined-field, undefined-global, param-type-mismatch, unused-local

-- ============================================================
-- EventManager.lua
-- Factory functions run at assault start via OnStart = EM.SomeFunc().
-- Each factory returns a closure called by AssaultManager.
-- Spawn loops use Utils.SpawnBenchNPCs for shared logic.
--
-- Example usage (ASSAULTS_NORMAL.lua):
-- {
--    OnStart = EM.OrderDrop(5000, { spawns = { guards = 3, grunts = 2 } })
-- },
-- {
--   OnStart = EM.Sequence(
--     EM.AssaultWeather("RadLeak", 30000, 25000),
--     EM.OrderDrop(20000, { spawns = { grunts = 3 } }),
--     EM.ExorDrop(20000, { spawns = { monks = 1 } })
--   )
-- }
-- ============================================================

local UEHelpers = require("UEHelpers")
local AFUtils   = require("AFUtils.AFUtils")
local Utils     = require("Utils.Utils")
local STATE     = require("Data.STATE")
local CONFIG    = STATE.Config
local Enums     = require("Data.Enums")

local EM = {}

local Log      = Utils.Log
local LogDebug = Utils.LogDebug

-- Returns delay + current assault's prep time so EM spawns fire N ms after fighting starts.
local function PrepDelay(ms)
    return ms + (STATE.AssaultPrepTime or 20000)
end


-- ============================================================
-- CROSSFIRE OPTIONS - available on every EM.*Drop
--
--   favoredEnemy      faction name ("Exor") or number. Each NPC in the drop
--                     one-shot locks onto a random NPC of that faction within
--                     favoredRadius of the bench.
--   favoredRadius     search radius for the above       [2500 = 25m]
--   spawnAtWavePoint  spawn at the DIRECTOR's own wave point instead of around
--                     the bench
--   wavePointScatter  spread around that point           [400 = 4m]
--
-- The lock is a ONE-SHOT: it lapses on the NPC's first completed attack, so the
-- rival gets first swing and then everyone goes back to the base. No candidate
-- nearby = no action.
--
-- Example - Order waves, then Exor land on top of them 10s later:
--   Wave1   = { "Grunt", "Grunt", "Grunt_Guard" },
--   OnStart = EM.ExorDrop(10000, {
--       spawns = { monks = 3 },
--       spawnAtWavePoint = true,
--       favoredEnemy = "Order",
--   })
-- ============================================================

-- Builds the pointFinder for spawnAtWavePoint, or nil when the option is off.
--
-- WHICH POINT? Assault_CurrentTargetLocation is the EQS result set the director
-- spawns its waves from - up to 3 points on spawn method 2, all of them on 3.
-- How the director uses it:
--   * per NPC, not per wave - every wave body does Array_Random over the set
--   * the SET is re-rolled on each wave advance (ChangeAssaultPhase is
--     immediately followed by TryUpdateAssaultPatrolLocation, which re-runs the
--     EQS and replaces the array wholesale)
--
-- So we resolve ONE point for the whole drop, on the first NPC, and reuse it:
--   * the squad lands together, on one cluster of wave NPCs - which is the
--     point of a crossfire. Copying the director's per-NPC randomness would
--     scatter a 3-man drop across 3 points and defeat it.
--   * "which wave" answers itself - the drop takes whatever set is live when it
--     fires, so a drop 10s into wave 1 lands on wave 1
--   * widen wavePointScatter if you want them spread out around it
--
-- The EQS is ASYNC, so for a moment after a wave advance the array still holds
-- the previous wave's points. They're all near the base; it doesn't matter.
--
-- Returns nil if the director has no points yet - SpawnBenchNPCs treats a nil
-- result as "use the normal bench pick", so a drop is never lost.
local function wavePointFinder(opts)
    if not (opts.spawnAtWavePoint or opts.SpawnAtWavePoint) then return nil end
    local scatter = opts.wavePointScatter or 400
    local anchor                          -- resolved once, on the first NPC

    return function(benchLoc, avoid)
        if not anchor then
            local pt = Utils.GetAssaultSpawnPoint()
            if not pt then return nil end  -- no points yet: fall back this time
            anchor = pt
        end
        return Utils.GetNavPointInBand(anchor, 0, scatter, { avoid = avoid, maxZDelta = 250 })
            or anchor
    end
end




-- portalDrop is a shared HELPER used by the *Drop functions below; its
-- implementation lives at the BOTTOM of this file so the EVENT functions stay
-- easy to find. Forward-declared here so those functions can reference it.
local portalDrop


-- ============================================================
-- DIRECT_UNITS - the friendly spawn names used by the faction drops, pooled
-- into one table for EM.DirectDrop (which is faction-agnostic).
--
-- Order and Exor keep the plain names they already use. Where a name would
-- collide across factions (armoreds, volatiles, grunts, breachers, electros,
-- winters) the OTHER faction gets a prefixed key, so nothing here is ambiguous.
-- ============================================================

local DIRECT_UNITS = {
    -- The Order
    guards       = "Grunt_Guard",     grunts    = "Grunt",          medics   = "Grunt_Medic",
    captains     = "Grunt_Captain",   breachers = "Grunt_Shotgun",  snipers  = "Grunt_Sniper",
    interfectors = "Interfector",
    -- Order rats
    labRats      = "Grunt_LabRat",    sappers   = "Grunt_Sapper",
    garageRats   = "Grunt_LabRat_Mechanic",     flameRats = "Grunt_FlameRat",

    -- Exor
    monks        = "Exor_Monk",       exors     = "Exor",           armoreds = "Exor_Armored",
    pikemen      = "Exor_Pikeman",    volatiles = "Exor_Volatile",

    -- Groupe
    groupeGrunts = "Groupe_Grunt",    groupeRooks = "Groupe_Rook",
    groupeBreachers = "Groupe_Shotgun",

    -- Gatekeepers
    phyters      = "Gatekeeper_Phyter",   mages   = "Gatekeeper_Mage",
    heavies      = "Gatekeeper_Heavy",    witches = "Gatekeeper_Witch",
    chieftains   = "Gatekeeper_Chieftain", corruptBots = "Robot_Corrupt",

    -- Pests
    pests            = "Pest",              pestElectros = "Pest_Electro",
    pestVolatiles    = "Pest_Volatile",     pestWinters  = "Pest_Snow",
    pestCarbonateds  = "Pest_Carbonated",   pestRats     = "Pest_Rat",
    pestLeyaks       = "Pest_Leyak",        pestMagmas   = "Pest_Magma",
    pestEnlighteneds = "Pest_Enlightened",

    -- Peccaries
    peccaries        = "Peccary",           sows             = "Sow",
    peccaryAlphas    = "Peccary_Alpha",     peccaryMushrooms = "Peccary_Mushroom",
    peccaryWinters   = "Peccary_Snow",      peccaryElectros  = "Peccary_Electro",
    peccaryArmoreds  = "Peccary_Armored",   peccaryVolatiles = "Peccary_Volatile",

    -- Odds and ends
    symphonists  = "Symph",           reapers   = "Reaper",         crystallisks = "Assassin",
    skinks       = "Skink",           magmaSkinks = "Skink_Magma",
    lamogis      = "WinterSprite",    lamogiBombs = "WinterSprite_Bomb",
    zombies      = "Zombie",          powerLeeches = "PowerLeech",
}


-- ============================================================
-- EVENT FUNCTIONS - you can call these in the ASSAULT files
-- ============================================================


-- ============================================================
-- Trigger a weather event with an automatic expiry.
-- * NOTE: Other delays are after Assault prep time is over.
--     This is not offset so weather can occur during prep.
-- * Fog, RadLeak, Spores, Blackout, BlackFog, ColdSnap
-- ============================================================

function EM.AssaultWeather(weather, duration, delay)
    duration = duration or 60000
    delay = delay or 0

    return function()
        -- Delays assume 20s prep time. If we shorten prep time we should also adjust this
        local prepShift = math.max(0, 20000 - (STATE.AssaultPrepTime or 20000))
        local effectiveDelay = math.max(0, delay - prepShift)

        Utils.DelayedGameThread(effectiveDelay, function()
            LogDebug("Triggering weather effect " .. weather, CONFIG.DEBUG_LOG)
            STATE.ActiveAssaultWeather = weather   -- set BEFORE trigger so hook allows it
            AFUtils.TriggerWeatherEvent(weather)
        end)
        Utils.DelayedGameThread(effectiveDelay + duration, function()
            if STATE.ActiveAssaultWeather == weather then
                STATE.ActiveAssaultWeather = nil   -- clear BEFORE trigger so hook allows the "None"
            end
            AFUtils.TriggerWeatherEvent("None")
        end)
    end
end

-- ============================================================
-- Spawn Pests near the assault bench.
-- opts.spawns: pests, electros, volatiles, winters, carbonateds, rats, leyaks, magmas, enlighteneds
-- ============================================================

function EM.PestDrop(delay, opts)
    delay = delay or 1000
    opts  = opts  or {}
    local spawns = opts.spawns or {}
    local pests        = spawns.pests        or 0
    local electros     = spawns.electros     or 0
    local volatiles    = spawns.volatiles    or 0
    local winters      = spawns.winters      or 0
    local carbonateds  = spawns.carbonateds  or 0
    local rats         = spawns.rats         or 0
    local leyaks       = spawns.leyaks       or 0
    local magmas       = spawns.magmas       or 0
    local enlighteneds = spawns.enlighteneds or 0

    return function()

        local spawnList = {}
        for _ = 1, pests        do table.insert(spawnList, Enums.NpcClasses["Pest"])             end
        for _ = 1, electros     do table.insert(spawnList, Enums.NpcClasses["Pest_Electro"])     end
        for _ = 1, volatiles    do table.insert(spawnList, Enums.NpcClasses["Pest_Volatile"])    end
        for _ = 1, winters      do table.insert(spawnList, Enums.NpcClasses["Pest_Snow"])        end
        for _ = 1, carbonateds  do table.insert(spawnList, Enums.NpcClasses["Pest_Carbonated"])  end
        for _ = 1, rats         do table.insert(spawnList, Enums.NpcClasses["Pest_Rat"])         end
        for _ = 1, leyaks       do table.insert(spawnList, Enums.NpcClasses["Pest_Leyak"])       end
        for _ = 1, magmas       do table.insert(spawnList, Enums.NpcClasses["Pest_Magma"])       end
        for _ = 1, enlighteneds do table.insert(spawnList, Enums.NpcClasses["Pest_Enlightened"]) end

        Utils.SpawnBenchNPCs(spawnList, PrepDelay(delay), {
            favoredEnemy  = opts.favoredEnemy  or opts.FavoredEnemy,
            favoredRadius = opts.favoredRadius or opts.FavoredRadius,
            pointFinder   = wavePointFinder(opts),
            radius        = opts.spawnRadius    or 3500,
            minRadius     = opts.minSpawnRadius or 2000,
            spawnInterval = opts.spawnInterval  or 500,
            isGiant       = true,
        })
        
        if CONFIG.DEBUG_LOG then
            Utils.Delay(PrepDelay(delay), function() 
                LogDebug("[ASSAULT] " .. STATE.SECONDS_TICK .. " - PestDrop starts", CONFIG.DEBUG_LOG)
            end)
        end
    end
end


-- ============================================================
-- Spawn Peccaries near the assault bench.
-- opts.spawns: pests, electros, volatiles, winters, carbonateds, rats, leyaks, magmas, enlighteneds
-- ============================================================

function EM.PeccaryDrop(delay, opts)
    delay = delay or 1000
    opts  = opts  or {}
    local spawns = opts.spawns or {}
    local peccaries    = spawns.peccaries    or 0
    local sows  	   = spawns.sows         or 0
    local mushrooms    = spawns.mushrooms    or 0
	local alphas  	   = spawns.alphas       or 0
    local winters      = spawns.winters      or 0
    local electros     = spawns.electros     or 0
    -- "armored" / "peccarys" appear in the ASSAULTS files; accept them.
    local armoreds     = spawns.armoreds     or spawns.armored or 0
    local volatiles    = spawns.volatiles    or 0
    peccaries          = peccaries + (spawns.peccarys or 0)

    return function()

        local spawnList = {}
        for _ = 1, peccaries    do table.insert(spawnList, Enums.NpcClasses["Peccary"]) end
        for _ = 1, sows         do table.insert(spawnList, Enums.NpcClasses["Sow"]) end
        for _ = 1, mushrooms    do table.insert(spawnList, Enums.NpcClasses["Peccary_Mushroom"]) end
        for _ = 1, alphas       do table.insert(spawnList, Enums.NpcClasses["Peccary_Alpha"]) end
        for _ = 1, winters      do table.insert(spawnList, Enums.NpcClasses["Peccary_Snow"]) end
        for _ = 1, electros     do table.insert(spawnList, Enums.NpcClasses["Peccary_Electro"]) end
        for _ = 1, armoreds     do table.insert(spawnList, Enums.NpcClasses["Peccary_Armored"]) end
        for _ = 1, volatiles    do table.insert(spawnList, Enums.NpcClasses["Peccary_Volatile"]) end

        Utils.SpawnBenchNPCs(spawnList, PrepDelay(delay), {
            favoredEnemy  = opts.favoredEnemy  or opts.FavoredEnemy,
            favoredRadius = opts.favoredRadius or opts.FavoredRadius,
            pointFinder   = wavePointFinder(opts),
            radius        = opts.spawnRadius    or 3500,
            minRadius     = opts.minSpawnRadius or 2000,
            spawnInterval = opts.spawnInterval  or 500,
            isGiant       = true,
        })
        
        if CONFIG.DEBUG_LOG then
            Utils.Delay(PrepDelay(delay), function() 
                LogDebug("[ASSAULT] " .. STATE.SECONDS_TICK .. " - PeccaryDrop starts", CONFIG.DEBUG_LOG)
            end)
        end
    end
end


-- ============================================================
-- Spawn Exors near the assault bench.
-- opts.spawns: monks, exors, armoreds, pikemen, volatiles
-- They portal in as part of their spawn animation.
-- ============================================================

function EM.ExorDrop(delay, opts)
    delay = delay or 1000
    opts  = opts  or {}
    local spawns = opts.spawns or {}
    local monks    = spawns.monks    or 0
    local exors    = spawns.exors    or 0
    local armoreds  = spawns.armoreds  or 0
    local pikemen  = spawns.pikemen  or 0
    local volatile = spawns.volatiles or 0

    return function()

        local spawnList = {}
        for _ = 1, monks    do table.insert(spawnList, Enums.NpcClasses["Exor_Monk"])     end
        for _ = 1, exors    do table.insert(spawnList, Enums.NpcClasses["Exor"])          end
        for _ = 1, armoreds  do table.insert(spawnList, Enums.NpcClasses["Exor_Armored"])  end
        for _ = 1, pikemen  do table.insert(spawnList, Enums.NpcClasses["Exor_Pikeman"])  end
        for _ = 1, volatile do table.insert(spawnList, Enums.NpcClasses["Exor_Volatile"]) end

        Utils.SpawnBenchNPCs(spawnList, PrepDelay(delay), {
            favoredEnemy  = opts.favoredEnemy  or opts.FavoredEnemy,
            favoredRadius = opts.favoredRadius or opts.FavoredRadius,
            pointFinder   = wavePointFinder(opts),
            radius        = opts.spawnRadius or 2000,
            minRadius     = opts.minSpawnRadius or 1200,
            spawnInterval = opts.spawnInterval,
            dilationStart = 0.5,
            dilationDelay = 3000,
        })
        
        if CONFIG.DEBUG_LOG then
            Utils.Delay(PrepDelay(delay), function() 
                LogDebug("[ASSAULT] " .. STATE.SECONDS_TICK .. " - ExorDrop starts", CONFIG.DEBUG_LOG)
            end)
        end
    end
end

-- ============================================================
-- Drop Order units near the assault bench.
-- opts.spawns: guards, grunts, medics, captains, breachers, snipers, interfectors
-- ============================================================

function EM.OrderDrop(delay, opts)
    delay = delay or 1000
    opts  = opts  or {}
    local spawns = opts.spawns or {}
    local guards       = spawns.guards       or 0
    local grunts       = spawns.grunts       or 0
    local medics       = spawns.medics       or 0
    local captains     = spawns.captains     or 0
    local breachers    = spawns.breachers    or 0
    local snipers      = spawns.snipers      or 0
    local interfectors = spawns.interfectors or 0

    return function()

        local spawnList = {}
        for _ = 1, guards       do table.insert(spawnList, Enums.NpcClasses["Grunt_Guard"])   end
        for _ = 1, grunts       do table.insert(spawnList, Enums.NpcClasses["Grunt"])         end
        for _ = 1, medics       do table.insert(spawnList, Enums.NpcClasses["Grunt_Medic"])   end
        for _ = 1, captains     do table.insert(spawnList, Enums.NpcClasses["Grunt_Captain"]) end
        for _ = 1, breachers    do table.insert(spawnList, Enums.NpcClasses["Grunt_Shotgun"]) end
        for _ = 1, snipers      do table.insert(spawnList, Enums.NpcClasses["Grunt_Sniper"])  end
        for _ = 1, interfectors do table.insert(spawnList, Enums.NpcClasses["Interfector"])   end

        Utils.SpawnBenchNPCs(spawnList, PrepDelay(delay), {
            favoredEnemy  = opts.favoredEnemy  or opts.FavoredEnemy,
            favoredRadius = opts.favoredRadius or opts.FavoredRadius,
            pointFinder   = wavePointFinder(opts),
            radius        = opts.spawnRadius or 2500,
            minRadius     = opts.minSpawnRadius or 1000,
            spawnInterval = opts.spawnInterval or 300,
            dilationStart = opts.dilationStart or 0.2,
            dilationDelay = opts.dilationDelay or 3000,
        })

        if CONFIG.DEBUG_LOG then
            Utils.Delay(PrepDelay(delay), function() 
                LogDebug("[ASSAULT] " .. STATE.SECONDS_TICK .. " - OrderDrop starts", CONFIG.DEBUG_LOG)
            end)
        end
    end
end


-- ============================================================
-- Drop ANY units right on top of the base - "they're already inside".
--
-- Where the faction drops spawn at 15-30m and walk in, DirectDrop lands units
-- in a 5-10m ring around the bench. If nothing navigable is in that ring
-- (small room, bench in a corner, base packed with deployables) it retries out
-- to 15m before falling back to a normal bench spawn - so the drop always
-- lands, it just may be a bit further out than asked.
--
-- opts.spawns takes the SAME friendly names the faction drops use, pooled
-- across factions (see DIRECT_UNITS at the top of this file):
--   Order  : guards, grunts, medics, captains, breachers, snipers, interfectors
--   Exor   : monks, exors, armoreds, pikemen, volatiles
--   GK     : phyters, mages, heavies, chieftains, witches, corruptBots
--   others : groupe*, pest*, peccary*, labRats, symphonists, reapers, skinks...
--
-- opts:
--   spawnRadius     outer edge of the primary ring        [1000 = 10m]
--   minSpawnRadius  inner edge of the primary ring         [500 =  5m]
--   fallbackRadius  outer edge of the retry ring          [1500 = 15m]
--   spawnInterval, dilationStart, dilationDelay - as the other drops
--
-- Example:
--   EM.DirectDrop(15000, { spawns = { captains = 2, monks = 1 } })
--
-- NOTE: don't use this for giants (Tarasque/Snowman/etc) - they need
-- EM.GiantDrop's nav-agent shrink and the room to path.
-- ============================================================

function EM.DirectDrop(delay, opts)
    delay = delay or 1000
    opts  = opts  or {}
    local spawns = opts.spawns or {}

    local outer    = opts.spawnRadius    or 1000
    local inner    = opts.minSpawnRadius or 500
    local fallback = opts.fallbackRadius or 1500

    return function()

        -- Sorted so a given spawns table always drops in the same order
        -- (pairs() order is undefined and would shuffle the wave run to run).
        local names = {}
        for name in pairs(spawns) do names[#names + 1] = name end
        table.sort(names)

        local spawnList = {}
        for _, name in ipairs(names) do
            local rowName = DIRECT_UNITS[name]
            local class   = rowName and Enums.NpcClasses[rowName]
            if not class then
                Utils.LogBad("[GATE] EM.DirectDrop() - unknown unit name: " .. tostring(name))
            else
                for _ = 1, (spawns[name] or 0) do table.insert(spawnList, class) end
            end
        end
        if #spawnList == 0 then return end

        -- spawnAtWavePoint wins over the tight ring: "land on the wave" and
        -- "land on the bench" are different set pieces, and the caller asked
        -- for the first one.
        local wavePoint = wavePointFinder(opts)

        Utils.SpawnBenchNPCs(spawnList, PrepDelay(delay), {
            favoredEnemy  = opts.favoredEnemy  or opts.FavoredEnemy,
            favoredRadius = opts.favoredRadius or opts.FavoredRadius,
            radius        = fallback,       -- only reached if pointFinder returns nil
            minRadius     = inner,
            spawnInterval = opts.spawnInterval or 500,
            dilationStart = opts.dilationStart or 0.5,
            dilationDelay = opts.dilationDelay or 2000,

            -- Tight band first, then the 15m ring. Returning nil hands the pick
            -- back to SpawnBenchNPCs' default (never-fails) GetSpawnPoint.
            pointFinder = wavePoint or function(benchLoc, avoid)
                return Utils.GetNavPointInBand(benchLoc, inner, outer, { avoid = avoid })
                    or Utils.GetNavPointInBand(benchLoc, inner, fallback, { avoid = avoid })
            end,
        })

        if CONFIG.DEBUG_LOG then
            Utils.Delay(PrepDelay(delay), function()
                LogDebug("[ASSAULT] " .. STATE.SECONDS_TICK .. " - DirectDrop starts", CONFIG.DEBUG_LOG)
            end)
        end
    end
end


-- ============================================================
-- Spawn Groupe units near the assault bench.
-- opts.spawns: grunts, breachers, rooks
-- ============================================================

function EM.GroupeDrop(delay, opts)
    delay = delay or 1000
    opts  = opts  or {}
    local spawns = opts.spawns or {}
    local grunts    = spawns.grunts    or 0
    local breachers = spawns.breachers or 0
    local rooks     = spawns.rooks     or 0

    return function()

        local spawnList = {}
        for _ = 1, grunts    do table.insert(spawnList, Enums.NpcClasses["Groupe_Grunt"])   end
        for _ = 1, rooks     do table.insert(spawnList, Enums.NpcClasses["Groupe_Rook"])    end
        for _ = 1, breachers do table.insert(spawnList, Enums.NpcClasses["Groupe_Shotgun"]) end

        Utils.SpawnBenchNPCs(spawnList, PrepDelay(delay), {
            favoredEnemy  = opts.favoredEnemy  or opts.FavoredEnemy,
            favoredRadius = opts.favoredRadius or opts.FavoredRadius,
            pointFinder   = wavePointFinder(opts),
            radius        = opts.spawnRadius or 3000,
            minRadius     = opts.minSpawnRadius or 1500,
            spawnInterval = opts.spawnInterval or 500,
            dilationStart = 0.5,
            dilationDelay = 3000,
        })
        
        if CONFIG.DEBUG_LOG then
            Utils.Delay(PrepDelay(delay), function() 
                LogDebug("[ASSAULT] " .. STATE.SECONDS_TICK .. " - GroupeDrop starts", CONFIG.DEBUG_LOG)
            end)
        end
    end
end


-- ============================================================
-- Spawn rats near the assault bench.
-- opts.spawns: labRats, sappers, garageRats, flameRats
function EM.RatDrop(delay, opts)
    delay = delay or 1000
    opts  = opts  or {}
    local spawns = opts.spawns or {}
    local labRats    = spawns.labRats   or 0
    local sappers    = spawns.sappers   or 0
    -- The docs and every ASSAULTS caller say garageRats/flameRats (plural), but
    -- these two only ever read the SINGULAR - so every garage/flame rat in the
    -- files spawned zero. Plural is canonical; singular still accepted.
    local garageRats = spawns.garageRats or spawns.garageRat or 0
    local flameRat   = spawns.flameRats  or spawns.flameRat  or 0

    return function()
        local spawnList = {}
        for _ = 1, labRats    do table.insert(spawnList, Enums.NpcClasses["Grunt_LabRat"])          end
        for _ = 1, sappers    do table.insert(spawnList, Enums.NpcClasses["Grunt_Sapper"])          end
        for _ = 1, garageRats do table.insert(spawnList, Enums.NpcClasses["Grunt_LabRat_Mechanic"]) end
        for _ = 1, flameRat   do table.insert(spawnList, Enums.NpcClasses["Grunt_FlameRat"])        end

        portalDrop(spawnList, "RAT_PORTAL", {
            delay              = delay,
            fxDelay            = opts.fxDelay        or 2000,
            spawnInterval      = opts.spawnInterval  or 500,
            firstSpawnInterval = opts.firstSpawnInterval,
            spawnRadius        = opts.spawnRadius    or 1500,
            minSpawnRadius     = opts.minSpawnRadius or 3000,
            emergeSound    = Enums.SOUNDS.TELEPORT_GEN,
            dilation       = 0.1,
            dilationDelay  = 2000,
            drift          = opts.drift,
            favoredEnemy     = opts.favoredEnemy or opts.FavoredEnemy,
            favoredRadius    = opts.favoredRadius or opts.FavoredRadius,
            spawnAtWavePoint = opts.spawnAtWavePoint or opts.SpawnAtWavePoint,
            label          = "RatDrop",
        })
    end
end


-- ============================================================
-- Gatekeeper portal drop.
-- opts.spawns: phyters, mages, heavies, chieftains, witches, corruptBots
-- * These drops all spawn from one portal point
-- ============================================================

function EM.GatekeeperDrop(delay, opts)
    delay = delay or 1000
    opts  = opts  or {}
    local spawns = opts.spawns or {}
    local phyters    = spawns.phyters    or 0
    local mages      = spawns.mages      or 0
    local heavies    = spawns.heavies    or 0
    local chieftains = spawns.chieftains or 0
    local witches    = spawns.witches    or 0
    local corruptBots= spawns.corruptBots or 0

    return function()
        local spawnList = {}
        for _ = 1, phyters     do table.insert(spawnList, Enums.NpcClasses["Gatekeeper_Phyter"])    end
        for _ = 1, mages       do table.insert(spawnList, Enums.NpcClasses["Gatekeeper_Mage"])      end
        for _ = 1, heavies     do table.insert(spawnList, Enums.NpcClasses["Gatekeeper_Heavy"])     end
        for _ = 1, chieftains  do table.insert(spawnList, Enums.NpcClasses["Gatekeeper_Chieftain"]) end
        for _ = 1, witches     do table.insert(spawnList, Enums.NpcClasses["Gatekeeper_Witch"])     end
        for _ = 1, corruptBots do table.insert(spawnList, Enums.NpcClasses["Robot_Corrupt"])        end

        portalDrop(spawnList, "GK_PORTAL", {
            delay              = delay,
            fxDelay            = opts.fxDelay        or 4000,
            spawnInterval      = opts.spawnInterval  or 1000,
            firstSpawnInterval = opts.firstSpawnInterval,
            spawnRadius        = opts.spawnRadius    or 2500,
            minSpawnRadius     = opts.minSpawnRadius or 1000,
            emergeSound    = Enums.SOUNDS.PORTAL_EXIT2,
            dilation       = 0.5,
            drift          = opts.drift,
            favoredEnemy     = opts.favoredEnemy or opts.FavoredEnemy,
            favoredRadius    = opts.favoredRadius or opts.FavoredRadius,
            spawnAtWavePoint = opts.spawnAtWavePoint or opts.SpawnAtWavePoint,
            label          = "GatekeeperDrop",
        })
    end
end



-- ============================================================
-- Spawn giant creatures near the assault bench.
-- opts.spawns: tarasques, behemoths, yetis, bigfoots, bigogi, snowmen
-- 
-- Nav-agent is shrunk so they navigate the facility corridors.
-- Snowman requires special BT patching (see Utils.HandleSnowman).
-- ============================================================

function EM.GiantDrop(delay, opts)
    delay = delay or 1000
    opts  = opts  or {}
    local spawns = opts.spawns or {}
    local tarasques = spawns.tarasques or 0
    local behemoths = spawns.behemoths or 0
    local yetis     = spawns.yetis     or 0
    local bigfoots  = spawns.bigfoots  or 0
    local bigogi    = spawns.bigogi    or 0
    local snowmen   = spawns.snowmen   or 0

    return function()

        local spawnList = {}
        for _ = 1, tarasques do table.insert(spawnList, Enums.NpcClasses["Tarasque"])          end
        for _ = 1, behemoths do table.insert(spawnList, Enums.NpcClasses["Behemoth"])          end
        for _ = 1, yetis     do table.insert(spawnList, Enums.NpcClasses["Yeti"])              end
        for _ = 1, bigfoots  do table.insert(spawnList, Enums.NpcClasses["Bigfoot"])           end
        for _ = 1, bigogi    do table.insert(spawnList, Enums.NpcClasses["WinterSprite_BOSS"]) end
        for _ = 1, snowmen   do table.insert(spawnList, Enums.NpcClasses["Snowman"])           end

        Utils.SpawnBenchNPCs(spawnList, PrepDelay(delay), {
            favoredEnemy  = opts.favoredEnemy  or opts.FavoredEnemy,
            favoredRadius = opts.favoredRadius or opts.FavoredRadius,
            pointFinder   = wavePointFinder(opts),
            radius        = opts.spawnRadius    or 4000,
            minRadius     = opts.minSpawnRadius or 2000,
            maxZDelta     = 200,
            zClearance    = 200,
            spawnInterval = opts.spawnInterval  or 2500,
            isGiant       = true,
            onSpawned = function(npc, bench, loc)

                if Utils.IsActorInvalid(npc) then return end
                local npcName = Utils.GetActorName(npc)

                if npcName == "Snowman" then
                    Utils.HandleSnowman(npc)
                else
                    npc.CustomTimeDilation = 0.5
                    Utils.DelayedGameThread(3000, function()
                        if Utils.IsActorValid(npc) then npc.CustomTimeDilation = 1.0 end
                    end)
                    if Utils.IsActorAlive(npc) then
                        Utils.ForceAttackTarget(npc, bench)
                    end
                end
            end,
        })
        
        if CONFIG.DEBUG_LOG then
            Utils.Delay(PrepDelay(delay), function() 
                LogDebug("[ASSAULT] " .. STATE.SECONDS_TICK .. " - GiantDrop starts", CONFIG.DEBUG_LOG)
            end)
        end
    end
end


-- ============================================================
-- Spawn Symphonists near the assault bench.
-- opts.spawns: symphonists
-- * Assumes fog event is active
-- ============================================================

function EM.SymphonistDrop(delay, opts)
    delay = delay or 1000
    opts  = opts  or {}
    local spawns = opts.spawns or {}
    local symphonists = spawns.symphonists or 0

    return function()

        local spawnList = {}
        for _ = 1, symphonists do table.insert(spawnList, Enums.NpcClasses["Symph"]) end

        Utils.SpawnBenchNPCs(spawnList, PrepDelay(delay), {
            favoredEnemy  = opts.favoredEnemy  or opts.FavoredEnemy,
            favoredRadius = opts.favoredRadius or opts.FavoredRadius,
            pointFinder   = wavePointFinder(opts),
            radius        = opts.spawnRadius    or 3000,
            minRadius     = opts.minSpawnRadius or 1500,
            spawnInterval = opts.spawnInterval,
            dilationStart = 0.25,
            dilationDelay = 3000,
            forceAttack   = true,
        })
        
        if CONFIG.DEBUG_LOG then
            Utils.Delay(PrepDelay(delay), function() 
                LogDebug("[ASSAULT] " .. STATE.SECONDS_TICK .. " - SymphDrop starts", CONFIG.DEBUG_LOG)
            end)
        end
    end
end


-- ============================================================
-- Spawn Power Leech boss near the assault bench.
-- opts.spawns: symphonists
-- * Assumes fog event is active
-- ============================================================

function EM.PowerLeechBossDrop(delay, opts)
    delay = delay or 1000
    opts  = opts  or {}
    local spawns = opts.spawns or {}
    local powerLeeches = spawns.powerLeeches or 0

    return function()

        local spawnList = {}
        for _ = 1, powerLeeches do table.insert(spawnList, Enums.NpcClasses["PowerLeech_BOSS"]) end

        Utils.SpawnBenchNPCs(spawnList, PrepDelay(delay), {
            favoredEnemy  = opts.favoredEnemy  or opts.FavoredEnemy,
            favoredRadius = opts.favoredRadius or opts.FavoredRadius,
            pointFinder   = wavePointFinder(opts),
            radius        = opts.spawnRadius    or 500,
            minRadius     = opts.minSpawnRadius or 0,
            spawnInterval = opts.spawnInterval,
            dilationStart = nil,
            zClearance    = 500,
            forceAttack   = true,
        })
        
        if CONFIG.DEBUG_LOG then
            Utils.Delay(PrepDelay(delay), function() 
                LogDebug("[ASSAULT] " .. STATE.SECONDS_TICK .. " - SymphDrop starts", CONFIG.DEBUG_LOG)
            end)
        end
    end
end


-- ============================================================
-- Spawn Reapers near the assault bench.
-- opts.spawns: reapers
-- ============================================================

function EM.ReaperDrop(delay, opts)
    delay = delay or 1000
    opts  = opts  or {}
    local spawns = opts.spawns or {}
    local reapers = spawns.reapers or 0

    return function()

        local spawnList = {}
        for _ = 1, reapers do table.insert(spawnList, Enums.NpcClasses["Reaper"]) end

        Utils.SpawnBenchNPCs(spawnList, PrepDelay(delay), {
            favoredEnemy  = opts.favoredEnemy  or opts.FavoredEnemy,
            favoredRadius = opts.favoredRadius or opts.FavoredRadius,
            pointFinder   = wavePointFinder(opts),
            radius        = opts.spawnRadius    or 3000,
            minRadius     = opts.minSpawnRadius or 1500,
            spawnInterval = opts.spawnInterval,
            dilationStart = 1,
            dilationDelay = 1000,
            forceAttack   = true,
        })
        
        if CONFIG.DEBUG_LOG then
            Utils.Delay(PrepDelay(delay), function() 
                LogDebug("[ASSAULT] " .. STATE.SECONDS_TICK .. " - ReaperDrop starts", CONFIG.DEBUG_LOG)
            end)
        end
    end
end


-- ============================================================
-- Reaper PORTAL drop - reapers but they come out of a Nightrealm portal
-- opts.spawns: reapers
-- ============================================================

function EM.ReaperPortalDrop(delay, opts)
    delay = delay or 1000
    opts  = opts  or {}
    local spawns = opts.spawns or {}
    local reapers = spawns.reapers or 0

    return function()
        local spawnList = {}
        for _ = 1, reapers do table.insert(spawnList, Enums.NpcClasses["Reaper"]) end
        -- TODO: Create shaded enemies like a 'Shadow witch'. Would take some client fanagling

        portalDrop(spawnList, "NIGHTREALM", {
            delay              = delay,
            fxDelay            = opts.fxDelay        or 4000,
            spawnInterval      = opts.spawnInterval  or 1500,
            firstSpawnInterval = opts.firstSpawnInterval,
            spawnRadius        = opts.spawnRadius    or 3000,
            minSpawnRadius     = opts.minSpawnRadius or 1500,
            emergeSound    = Enums.SOUNDS.PORTAL_EXIT2,
            drift          = opts.drift,
            favoredEnemy     = opts.favoredEnemy or opts.FavoredEnemy,
            favoredRadius    = opts.favoredRadius or opts.FavoredRadius,
            spawnAtWavePoint = opts.spawnAtWavePoint or opts.SpawnAtWavePoint,
            label          = "ReaperPortalDrop",
        })
    end
end


-- ============================================================
-- Spawn Crystalisks near the assault bench.
-- opts.spawns: crystallisks
-- * Assumes fog event is active
-- ============================================================

function EM.CrystalliskDrop(delay, opts)
    delay = delay or 1000
    opts  = opts  or {}
    local spawns = opts.spawns or {}
    local crystallisks = spawns.crystallisks or 0

    return function()

        local spawnList = {}
        for _ = 1, crystallisks do table.insert(spawnList, Enums.NpcClasses["Assassin"]) end

        Utils.SpawnBenchNPCs(spawnList, PrepDelay(delay), {
            favoredEnemy  = opts.favoredEnemy  or opts.FavoredEnemy,
            favoredRadius = opts.favoredRadius or opts.FavoredRadius,
            pointFinder   = wavePointFinder(opts),
            radius        = opts.spawnRadius    or 3000,
            minRadius     = opts.minSpawnRadius or 1500,
            spawnInterval = opts.spawnInterval,
            dilationStart = 1,
            dilationDelay = 1000,
            forceAttack   = true,
        })
        
        if CONFIG.DEBUG_LOG then
            Utils.Delay(PrepDelay(delay), function() 
                LogDebug("[ASSAULT] " .. STATE.SECONDS_TICK .. " - CrystalliskDrop starts", CONFIG.DEBUG_LOG)
            end)
        end
    end
end


-- ============================================================
-- Spawn Winter Sprites (formerly Lamogi) near the base.
-- opts.spawns: lamogis, bombs, bosses
-- ============================================================

function EM.LamogiDrop(delay, opts)
    delay = delay or 1000
    opts  = opts  or {}
    local spawns = opts.spawns or {}
    local lamogis = spawns.lamogis or 0
    local bombs   = spawns.bombs   or 0
    local bosses  = spawns.bosses  or 0

    return function()

        local spawnList = {}
        for _ = 1, lamogis do table.insert(spawnList, Enums.NpcClasses["WinterSprite"])      end
        for _ = 1, bombs   do table.insert(spawnList, Enums.NpcClasses["WinterSprite_Bomb"]) end
        for _ = 1, bosses  do table.insert(spawnList, Enums.NpcClasses["WinterSprite_BOSS"]) end

        Utils.SpawnBenchNPCs(spawnList, PrepDelay(delay), {
            favoredEnemy  = opts.favoredEnemy  or opts.FavoredEnemy,
            favoredRadius = opts.favoredRadius or opts.FavoredRadius,
            pointFinder   = wavePointFinder(opts),
            radius        = opts.spawnRadius    or 3000,
            minRadius     = opts.minSpawnRadius or 1500,
            spawnInterval = opts.spawnInterval,
            dilationStart = 0.8,
            dilationDelay = 1,
            forceAttack   = true,
        })
        
        if CONFIG.DEBUG_LOG then
            Utils.Delay(PrepDelay(delay), function() 
                LogDebug("[ASSAULT] " .. STATE.SECONDS_TICK .. " - LamogiDrop starts", CONFIG.DEBUG_LOG)
            end)
        end
    end
end


-- ============================================================
-- Spawn a Dark Lens Mage near the assault bench.
-- opts.spawns: mages [1]
-- opts: spawnRadius [5000], minSpawnRadius [1500]
-- DarkLensCombatReady must be set or the NPC stands idle.
-- ============================================================

function EM.SpawnDarkLensMage(delay, opts)
    delay = delay or 1000
    opts  = opts  or {}
    local spawns = opts.spawns or {}
    local mages = spawns.mages or 1

    return function()

        local spawnList = {}
        for _ = 1, mages do table.insert(spawnList, Enums.NpcClasses["DarkLens_Mage"]) end

        Utils.SpawnBenchNPCs(spawnList, PrepDelay(delay), {
            favoredEnemy  = opts.favoredEnemy  or opts.FavoredEnemy,
            favoredRadius = opts.favoredRadius or opts.FavoredRadius,
            pointFinder   = wavePointFinder(opts),
            radius    = opts.spawnRadius    or 3000,
            minRadius = opts.minSpawnRadius or 1500,
            onSpawned = function(npc, bench, loc)
                npc.DarkLensCombatReady = true
                npc:OnRep_DarkLensCombatReady()
                npc.CustomTimeDilation = 0.1
                Utils.DelayedGameThread(3000, function()
                    if Utils.IsActorValid(npc) then npc.CustomTimeDilation = 1.0 end
                end)
            end,
        })
        
        if CONFIG.DEBUG_LOG then
            Utils.Delay(PrepDelay(delay), function() 
                LogDebug("[ASSAULT] " .. STATE.SECONDS_TICK .. " - DarkLensMage starts", CONFIG.DEBUG_LOG)
            end)
        end
    end
end



-- ============================================================
-- Spawn Skinks near the base.
-- opts.spawns: skinks, magmaSkinks
-- opts: faction, spawnRadius [3000], minSpawnRadius [1500]
-- Faction 6=Exor lets them coexist with Exor assault waves.
-- ============================================================

function EM.SkinkDrop(delay, opts)
    delay = delay or 1000
    opts  = opts  or {}
    local spawns = opts.spawns or {}
    local skinks     = spawns.skinks     or 0
    -- Accept both spellings: every ASSAULTS caller writes "magmaskinks", this
    -- read only ever matched "magmaSkinks", and Lua keys are case-sensitive - so
    -- every magma-skink drop in the files was silently spawning zero.
    local magmaSkinks= spawns.magmaSkinks or spawns.magmaskinks or 0
    local faction    = opts.faction       or 5 --lets default to a2

    return function()

        local spawnList = {}
        for _ = 1, skinks      do table.insert(spawnList, Enums.NpcClasses["Skink"])       end
        for _ = 1, magmaSkinks do table.insert(spawnList, Enums.NpcClasses["Skink_Magma"]) end

        Utils.SpawnBenchNPCs(spawnList, PrepDelay(delay), {
            favoredEnemy  = opts.favoredEnemy  or opts.FavoredEnemy,
            favoredRadius = opts.favoredRadius or opts.FavoredRadius,
            pointFinder   = wavePointFinder(opts),
            radius        = opts.spawnRadius    or 3000,
            minRadius     = opts.minSpawnRadius or 1500,
            spawnInterval = opts.spawnInterval  or 200,

            forceAttack   = true,
            onSpawned = function(npc, bench, loc)
                if opts.faction and opts.faction > 0 then
                    npc.Faction = opts.faction
                else
                    npc.Faction = 0
                end
            end,
        })
        
        if CONFIG.DEBUG_LOG then
            Utils.Delay(PrepDelay(delay), function() 
                LogDebug("[ASSAULT] " .. STATE.SECONDS_TICK .. " - SkinkDrop starts", CONFIG.DEBUG_LOG)
            end)
        end
    end
end



-- ============================================================
-- Run multiple OnStart functions in sequence.
--
-- Example:
--   OnStart = EM.Sequence(
--       EM.OrderDrop(5000, { spawns = { guards = 2, grunts = 1 } }),
--       EM.GiantDrop(60000, { spawns = { tarasques = 1 } })
--   )
-- ============================================================

function EM.Sequence(...)
    local fns = {...}
    return function()
        for _, fn in ipairs(fns) do
            if type(fn) == "function" then
                local ok, err = pcall(fn)
                if not ok then
                    Utils.LogBad("[GATE] EM.Sequence() - error: " .. tostring(err))
                end
            end
        end
    end
end


-- ============================================================
-- HELPER FUNCTION(S) - do NOT call these from the ASSAULT files.
-- ============================================================

-- ============================================================
-- portalDrop - opens ONE portal that NPCs spill out of.
--
-- The portal FX is sent BEFORE the spawn loop so the doorway opens first, and
-- it (plus its looping sound) auto-closes ~3s after the last NPC emerges. It
-- shows on every renderer via Utils.SendClientFX -> Hooks/ClientFX.
--
-- AIMED, NOT AXIS-ALIGNED. The doorway faces the target bench, and:
--   * the Niagara is a flat plane, so an unaimed portal can be invisible
--     edge-on from where the players are standing
--   * every NPC steps out pointing the same way, instead of at world 0
--   * the doorway DRIFTS along that facing, so it advances on the base and
--     bodies appear to be pushed out of it
--
--   spawnList : { classPath, ... }
--   fxKey     : "GK_PORTAL" / "NIGHTREALM" / "RAT_PORTAL"  (-> ClientFX EFFECTS)
--   opts:
--     delay              ms before the drop starts (after assault prep)   [1000]
--     fxDelay            ms after open before NPCs emerge                 [4000]
--     spawnInterval      ms between NPCs                                  [1000]
--     firstSpawnInterval ms (from portal open) to the FIRST NPC. Lets the
--                        first NPC come sooner than the inter-spawn gap.
--                        [defaults to fxDelay + spawnInterval]
--     spawnRadius        max distance of the portal from the bench        [1100]
--     minSpawnRadius     min distance of the portal from the bench         [300]
--     emergeSound        sound key played as each NPC emerges             [none]
--     dilation           CustomTimeDilation while emerging (slow walk-in) [none]
--     dilationDelay      ms before dilation restores to 1.0              [1000]
--     drift              uu the doorway travels over its life. nil = the
--                        ClientFX registry default, 0 = pinned         [nil]
--     favoredEnemy       faction to open on instead of the players       [nil]
--     favoredRadius      search radius for that                         [2500]
--     spawnAtWavePoint   tear the portal open at the director's own wave
--                        spawn point rather than near the bench        [false]
--     label              debug log label                                  [none]
-- ============================================================
function portalDrop(spawnList, fxKey, opts)
    opts = opts or {}
    if #spawnList == 0 then return end

    local favoredEnemy = Utils.ResolveFaction(opts.favoredEnemy)
    local favoredRadius = opts.favoredRadius or 2500
    local wavePoint = opts.spawnAtWavePoint and Utils.GetAssaultSpawnPoint or nil

    local delay          = opts.delay         or 1000
    local effectDelay    = opts.fxDelay       or 4000
    local interval       = opts.spawnInterval or 1000
    local portalRadius   = opts.spawnRadius   or 1100
    local portalMinRad   = opts.minSpawnRadius or 300
    local emergeSound    = opts.emergeSound
    local dilation       = opts.dilation
    local dilationDelay  = opts.dilationDelay or 1000
    -- Time (from portal open) to the FIRST spawn. Default = fxDelay + interval,
    -- which keeps the original timing; override for a quicker first arrival.
    local firstAt        = opts.firstSpawnInterval or (effectDelay + interval)

    Utils.QueueSpawn(function()
        if not Utils.IsAssaultHappening() then return end

        local bench, benchLoc = Utils.GetAssaultBench()
        if not benchLoc then return end

        -- Keep the portal away from other crafting benches in the base.
        local otherBenches = Utils.GetOtherBenchLocations(benchLoc)

        -- spawnAtWavePoint: open the doorway where the director's waves land.
        -- Falls through to the normal bench pick if it has no points yet.
        local portalLoc
        if wavePoint then
            local pt = wavePoint()
            if pt then
                portalLoc = Utils.GetNavPointInBand(pt, 0, 400, { avoid = otherBenches }) or pt
            end
        end
        portalLoc = portalLoc
            or Utils.GetSpawnPoint(benchLoc, portalRadius, portalMinRad, nil, 50, 100, otherBenches)
        if not portalLoc then return end

        -- Point the doorway (and everything that walks out of it) at the bench.
        local portalYaw = Utils.YawTo(portalLoc, benchLoc)

        -- Open the portal NOW (before the spawn loop) on every renderer machine.
        -- Portal stays open until ~3s after the last NPC emerges.
        local npcCount = #spawnList
        local lastAt   = firstAt + (npcCount - 1) * interval
        local portalSeconds = math.ceil(lastAt / 1000) + 3
        Utils.SendClientFX(portalLoc, fxKey, portalSeconds, portalYaw, opts.drift)

        for i, classPath in ipairs(spawnList) do
            Utils.QueueSpawn(function()
                if not Utils.IsAssaultHappening() then return end

                local spawnLoc = Utils.GetSpawnPoint(portalLoc, 200, 0, 100, 150, 100) or portalLoc
                -- Fresh FRotator per spawn - never share one struct wrapper
                -- across async spawn callbacks.
                Utils.SpawnNpc(classPath, spawnLoc, FRotator(0, portalYaw, 0), function(npc)
                    if Utils.IsActorInvalid(npc) then return end

                    if emergeSound then Utils.Broadcast2DSound(emergeSound) end

                    if dilation then
                        npc.CustomTimeDilation = dilation
                        Utils.DelayedGameThread(dilationDelay, function()
                            if Utils.IsActorValid(npc) then npc.CustomTimeDilation = 1 end
                        end)
                    end

                    if bench and Utils.IsActorAlive(npc) then
                        Utils.ForceAttackTarget(npc, bench)
                    end

                    -- Crossfire, applied last so its lock beats the bench aggro.
                    if favoredEnemy then
                        Utils.AggroFavoredEnemy(npc, benchLoc, favoredEnemy, favoredRadius)
                    end
                end)
            end, firstAt + (i - 1) * interval)
        end
    end, PrepDelay(delay))

    if CONFIG.DEBUG_LOG and opts.label then
        Utils.Delay(PrepDelay(delay), function()
            LogDebug("[ASSAULT] " .. STATE.SECONDS_TICK .. " - " .. opts.label .. " starts", CONFIG.DEBUG_LOG)
        end)
    end
end


return EM
