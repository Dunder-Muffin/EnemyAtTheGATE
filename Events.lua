-- =======================================================================
-- Events [AUTHORITY] - the FRONT DOOR to the scripted story set-pieces.
-- StoryManager owns the WHEN (story flags, proximity, once-ever persistence); each set-piece owns
-- its own file and its own choreography. This file only holds the dispatch layer:
--     * the REGISTRY - the named handles, chronological, one per set-piece
--     * Run / RunManual - the story path and the debug path
--     * EVENTS.LOC - the anchor coords StoryManager's gates read, assembled from the modules
--     * the manual toggles for the set-pieces that own their own gate (see the ONGOING section)
--   Every module is mounted onto ONE table, so "/event Lab_ContBreach", the "(98) Events" keybind
--   group and StoryManager all see the same surface.
--   THREADING: all of this runs on the WorkQueue drain (= inside the ProcessTick hook), so
--   nothing may blocking-load. Spawns go via EVU.SpawnAt/SpawnOne -> NpcSpawner (off-hook),
--   audio via LoadAsync (EVU.PlayAnnouncement), heavy work staggered by Utils.QueueWork.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local Utils = require("AnteUtils.Utils")
local EVU = require("ModuleStory.EventUtils")

-- The set-pieces, in story order. Each returns its event functions plus an optional LOC table.
-- NAMES, required in the mount loop below: `require` also returns the loader path, and a bare
-- require in a table's last field splices that string in as an extra entry.
local MODULES = {
    "ModuleStory.OfficeGardens",      -- EVENT 1
    "ModuleStory.OrderAmbush",        -- EVENT 2
    "ModuleStory.LabEvents",          -- EVENT 3 + 4
    "ModuleStory.SecurityCutscene",   -- EVENT 5
    "ModuleStory.ReactorsDusk",       -- EVENT 7
    "ModuleStory.ReactorsCloud",      -- EVENT 8
    "ModuleStory.ReactorsGale",       -- EVENT 9
    "ModuleStory.ShadowgateCache",    -- EVENT 10
    "ModuleStory.InqNightRealm",      -- EVENT 11
    "ModuleStory.InqAssault",         -- EVENT 12 (+ the tank turret handle)
    "ModuleStory.InqCommand",         -- EVENT 13
    "ModuleStory.InqHolyFire",        -- EVENT 14
}

-- ...and the six that own their own gate as well as their own file, so this file only wraps a
-- manual override for each (the ONGOING section at the foot).
local HexedTreeStalker = require("AnteNPCs.HexedTreeStalker")
local RisePatrol = require("ModuleStory.RisePatrol")
local SleepShade = require("ModuleStory.SleepShade")
local HydroBridge = require("ModuleStory.HydroBridge")
local Winter = require("ModuleStory.Winter")
local PlantEscape = require("ModuleStory.PlantEscape")

local Log = Utils.Log

local EVENTS = {}

-- The anchor points StoryManager's gates ALSO need. Each coord is declared next to the event that
-- spawns on it and exported as that module's LOC, so there is exactly one copy of each; the gates
-- read this table lazily at tick time (SM's eventLoc).
EVENTS.LOC = {}

-- Mount one set-piece module onto EVENTS: its LOC entries into EVENTS.LOC, everything else
-- straight on. A name collision would silently replace a handle, so it is loud instead.
local function mount(module)
    for key, value in pairs(module) do
        if key == "LOC" then
            for name, coord in pairs(value) do EVENTS.LOC[name] = coord end
        else
            if EVENTS[key] then
                Utils.LogBad("Events - two set-piece modules both export '" .. key .. "'")
            end
            EVENTS[key] = value
        end
    end
end

for _, name in ipairs(MODULES) do mount((require(name))) end


-- =======================================================================
-- REGISTRY - the named handles (keybind + /event chat command).
-- Values are function names on EVENTS, resolved at Run time.
-- CHRONOLOGICAL, and a number matches the StoryManager gate that fires it (SM.Gate*).
--   ONE-TIME     a latch, once ever (persisted in STATE.StoryData unless noted).
--   RESTARTABLE  latches too, but a vignette reset re-arms it.
--   ONGOING      a loop, story- or presence-gated; the handle here force-toggles it.
-- Every "...Stop" handle is a DEV handle: it ends a test run without walking to the end trigger.
-- =======================================================================
local REGISTRY = {
    Event_Office_Gardens           = "OfficeGardens",          --  1  ONE-TIME     Office
    Event_Manu_OrderAmbush         = "OrderAmbush",            --  2  ONE-TIME     Manufacturing
    Event_Lab_ContBreach           = "LabContBreach",          --  3  ONE-TIME     Labs
    Event_Lab_PortalPests          = "LabPortalPests",         --  4  ONE-TIME     Labs (per world)
    Event_Rise_Ongoing_Patrol      = "RisePatrol",             --     ONGOING      V_RISE
    Event_Security_Cutscene        = "SecurityCutscene",       --  5  ONE-TIME     Security
    Event_Canaan_Ongoing_HexTree   = "HexTree",                --     ONGOING      Canaan
    Event_Base_SleepShade          = "SleepShade",             --     ONE-TIME     any base (its own sleep watcher)
    Event_Hydro_Ongoing_Bridge     = "HydroBridge",            --     ONGOING      Hydroplant
    Event_Hydro_Ongoing_BridgeStop = "HydroBridgeStop",
    Event_Dams_Ongoing_Winter      = "Winter",                 --     ONGOING      Voussoir/V_Alps
    Event_Plant_Escape             = "PlantEscape",            --  6  ONE-TIME     Plant
    Event_Plant_EscapeStop         = "PlantEscapeStop",
    Event_ReactorsDusk_Defense     = "ReactorsDuskDefense",    --  7  ONE-TIME     Reactors S1
    Event_ReactorsCloud_GKTakeover = "ReactorsCloudTakeover",  --  8  ONE-TIME     Reactors S4
    Event_ReactorsGale_Powered1    = "ReactorsGalePowered1",   --  9  ONE-TIME     Reactors S2War 1
    Event_ReactorsGale_Powered2    = "ReactorsGalePowered2",   --  9  ONE-TIME     Reactors S2War 2
    Event_ReactorsGale_Powered3    = "ReactorsGalePowered3",   --  9  ONE-TIME     Reactors S2War 3
    Event_Reactors_ShadowgateCache = "ReactorsShadowgateCache",-- 10  ONE-TIME     Shadowgate
    Event_INQ_NightRealm           = "INQNightRealm",          -- 11  ONE-TIME     V_Inq (per world)
    Event_INQ_NightRealmStop       = "INQNightRealmStop",
    Event_INQ_TankTurret           = "INQTankTurret",          -- 12  ONE-TIME     Praetorium
    Event_INQ_PurifiedAssault      = "INQPurifiedAssault",     -- 12  RESTARTABLE  Praetorium
    Event_INQ_PurifiedAssaultStop  = "INQPurifiedAssaultStop",
    Event_INQ_Command              = "INQCommand",             -- 13  RESTARTABLE  Praetorium
    Event_INQ_CommandStop          = "INQCommandStop",
    Event_INQ_HolyFire             = "INQHolyFire",            -- 14  ONGOING      Praetorium
    Event_INQ_HolyFireStop         = "INQHolyFireStop",
}

-- REGISTRY indexed by a NORMALISED name - lowercased, underscores dropped - built once on first
-- use. Every manual trigger is hand-typed, so "/event plantescape", "/event plant_escape" and the
-- exact "Event_Plant_Escape" all have to land on the same handle.
local registryIndex

local function normalizeName(name)
    return (tostring(name or ""):lower():gsub("_", ""))
end

local function resolveEvent(name)
    if not registryIndex then
        registryIndex = {}
        for key, fnName in pairs(REGISTRY) do
            local n = normalizeName(key)
            if registryIndex[n] then
                Utils.LogBad("Events - two REGISTRY handles normalise to '" .. n
                    .. "'; one of them is unreachable by name")
            end
            registryIndex[n] = fnName
        end
    end
    return registryIndex[normalizeName(name)]
end

-- Run a named event (e.g. "Event_Lab_ContBreach"). Extra args pass through. AUTHORITY only.
-- This is the STORY path: every once-ever latch is honoured. Manual triggers use RunManual.
function EVENTS.Run(name, ...)
    if not Utils.IsAuthority() then return false end
    local fn = EVENTS[resolveEvent(name) or ""]
    if not fn then Log("Events.Run - unknown event '" .. tostring(name) .. "'"); return false end
    local ok, err = pcall(fn, ...)
    if not ok then Utils.LogBad("Event '" .. tostring(name) .. "' error: " .. tostring(err)) end
    return true
end

-- The DEBUG path ("/event", the keybind group): Run with the once-ever latches waived
-- (EVU.LatchStops). Wrapped so a throw anywhere inside can't leave the waiver stuck on, which
-- would silently disarm every latch for the rest of the session.
function EVENTS.RunManual(name, ...)
    EVU.SetForced(true)
    local ok, ran = pcall(EVENTS.Run, name, ...)
    EVU.SetForced(false)
    if not ok then Utils.LogBad("Event '" .. tostring(name) .. "' error: " .. tostring(ran)) end
    return ok and ran == true
end

-- True if a name is an event handle (so the keybind can branch off summonVariant).
function EVENTS.IsEvent(name)
    return type(name) == "string" and name:sub(1, 6) == "Event_"
end


-- =======================================================================
-- ONGOING - the manual overrides for the set-pieces that own their own gate as well as their own
-- file (module.GateTick, called from StoryManager.Tick). Each handle here DROPS the story and
-- presence gates and toggles the loop on the spot, for testing before the story reaches it - so
-- run it standing in the place, the spawn marks still have to be streamed in.
--     Event_Rise_Ongoing_Patrol     ModuleStory/RisePatrol    the V_RISE Order sweep
--     Event_Canaan_Ongoing_HexTree  AnteNPCs/HexedTreeStalker the singleton stalking Hexed Tree
--     Event_Base_SleepShade         ModuleStory/SleepShade    the jumpscare at a sleeper's bed (runs once, now)
--     Event_Hydro_Ongoing_Bridge    ModuleStory/HydroBridge   Order waves across the bridge
--     Event_Dams_Ongoing_Winter     ModuleStory/Winter        ambient whiteouts in Voussoir
--     Event_Plant_Escape            ModuleStory/PlantEscape   EVENT 6, six waves onto the exit
-- =======================================================================

function EVENTS.RisePatrol()
    if not Utils.IsAuthority() then return end
    RisePatrol.Toggle()
end

function EVENTS.HexTree()
    if not Utils.IsAuthority() then return end
    HexedTreeStalker.Toggle()
end

function EVENTS.SleepShade()
    if not Utils.IsAuthority() then return end
    SleepShade.RunNow()
end

function EVENTS.HydroBridge()
    if not Utils.IsAuthority() then return end
    HydroBridge.Toggle()
end

function EVENTS.HydroBridgeStop()
    if not Utils.IsAuthority() then return end
    HydroBridge.Stop("stopped by hand")
end

function EVENTS.Winter()
    if not Utils.IsAuthority() then return end
    Winter.Toggle()
end

function EVENTS.PlantEscape()
    if not Utils.IsAuthority() then return end
    PlantEscape.Start("manual")
end

function EVENTS.PlantEscapeStop()
    if not Utils.IsAuthority() then return end
    PlantEscape.Stop("stopped by hand")
end


return EVENTS
