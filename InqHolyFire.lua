-- =======================================================================
-- EVENT 14 - PRAETORIUM HOLY FIRE  [AUTHORITY] - ONGOING
--   (Event_INQ_HolyFire / Event_INQ_HolyFireStop)
--   Two holy-fire patches on the Command Blockade approach that never burn out - permanent by
--   REFRESH (re-lit every HF.LIFE, under the actor's ~20s EffectDuration default so a remote
--   client's own visual never outlives the server's actor), not by duration. Presence-gated and
--   self-stopping via SM.GateINQHolyFire; nosave. See AnNotes/Modules/Events.md.
--   Dev: "/event INQ_HolyFire" arms it on the spot, "/event INQ_HolyFireStop" puts it out.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local ENUMS = require("AnteData.Enums")

local Log = Utils.Log
local LogDebug = Utils.LogDebug

local EV = {}


local HF = {
    FIRE_LOCS = {
        FVector(105000, 44800, 1230),
        FVector(104350, 44800, 1230),
        FVector(104450, 45180, 1490),
    },

    -- Coords paced out in-game read from the PLAYER's capsule CENTRE, roughly a stance above the
    -- floor, and a patch spawned at eye-of-the-capsule height hovers. Same -Z nudge the Fanatic's
    -- death patch uses. Set to 0 if these coords came off a floor trace instead.
    Z_DROP = -90,

    NEAR   = 12000,   -- a player within 120m of either patch = burn (and that sector is streamed)
    LIFE   = 12,      -- seconds: EffectDuration AND the refresh interval (see the banner)

    running = false,
    token   = 0,      -- orphans the in-flight beat on stop / re-arm / world teardown
}

-- Anyone close enough to be worth burning for? Pure Lua distance walk over the GameState player
-- array (Utils.IsPlayerNearby) - never a scan, so it is safe on the story cadence.
function HF.AnyoneNear()
    for _, spot in ipairs(HF.FIRE_LOCS) do
        if Utils.IsPlayerNearby(spot, HF.NEAR) then return true end
    end
    return false
end

-- The refresh beat: re-light every patch, then re-queue itself one LIFE later.
function HF.Beat(token)
    if token ~= HF.token or not STATE.ModEnabled then return end

    if not HF.AnyoneNear() then
        HF.running = false      -- lapse; the story gate re-arms on the next arrival
        LogDebug("INQ holy fire - Praetorium empty, patches lapse", SETTINGS.DEBUG_STORY)
        return
    end

    for _, spot in ipairs(HF.FIRE_LOCS) do
        -- Per-spot streaming check: proximity says a player is CLOSE, only the level manager says
        -- the ground under this coord is actually loaded.
        if Utils.IsLocationLoaded(spot) then
            AVU.SpawnCloud(FVector(spot.X, spot.Y, spot.Z + HF.Z_DROP),
                ENUMS.Components.AREA_HOLY_FIRE, { Duration = HF.LIFE })
        end
    end

    Utils.QueueWork(function() HF.Beat(token) end, HF.LIFE * 1000)
end

-- Arm (idempotent). Silent no-op when nobody is there, because the story gate calls this every
-- beat - the presence check lives HERE so an empty Praetorium doesn't log once per 10s.
function EV.INQHolyFire()
    if HF.running or not HF.AnyoneNear() then return end
    HF.running = true
    HF.token   = HF.token + 1
    Log("INQ holy fire - the approach is burning")
    HF.Beat(HF.token)
end

-- Dev handle: stop refreshing. Patches already on the ground burn down on their own clock.
function EV.INQHolyFireStop()
    HF.token   = HF.token + 1   -- orphan the queued beat
    HF.running = false
    Log("INQ holy fire - out (standing patches burn down on their own)")
end

-- Per-world reset (SM.Register). A teardown wipes the WorkQueue with the beat still queued, so a
-- stale `running` would leave the fire dead for the whole next world - the cmdWatching lesson.
function EV.INQHolyFireReset()
    HF.token   = HF.token + 1
    HF.running = false
end


return EV
