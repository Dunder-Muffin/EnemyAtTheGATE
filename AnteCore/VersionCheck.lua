-- =======================================================================
-- VersionCheck - warn a player whose AnteUp2 build differs from the server's.
--   * The authority announces its version to every player over NetChannel on a heartbeat. A pure
--     client compares it with its own and prints one chat warning per world on a mismatch, or when
--     no announcement arrives at all - which is what a server on an older build looks like.
--   * Warn only. A mismatched client keeps running; parts of it just won't line up with the server.
--   * The server can't learn a client's version (the only client->server channel is visible chat),
--     so the warning appears on the mismatched player's screen.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local VERSION = require("VERSION")
local STATE = require("AnteCore.State")
local NET = require("AnteCore.NetChannel")
local Utils = require("AnteUtils.Utils")

local VC = {}

local CFG = {
    FirstAnnounceMs = 5000,
    AnnounceMs = 15000,
    -- Four announcements' worth, so a dropped frame can't raise a false alarm.
    SilenceWarnMs = 60000,
    Color = { R = 1.0, G = 0.75, B = 0.25, A = 1.0 },
}

-- Per-world client state, reset by VC.Start.
local heard = false
local warned = false

local function label(major, minor, dev)
    return string.format("%d.%d%s", major, minor, dev and "-dev" or "")
end

local MAJOR, MINOR, DEV = math.floor(VERSION.Major or 0), math.floor(VERSION.Minor or 0), VERSION.Dev == true

-- This build's version, e.g. "1.19" or "1.18-dev".
function VC.Label()
    return label(MAJOR, MINOR, DEV)
end

local function warn(msg)
    if warned then return end
    warned = true
    Utils.LogBad("VersionCheck - " .. msg)
    pcall(function()
        require("AFUtils.AFUtils").DisplayTextChatMessage(msg, "[AnteUp2] ", CFG.Color)
    end)
end

-- [CLIENT] The server's announcement, dispatched on the drain.
local function onVersion(frames)
    local f = frames[1]
    heard = true
    local major, minor, dev = math.floor(f.x or 0), math.floor(f.y or 0), (f.z or 0) == 1
    if major == MAJOR and minor == MINOR and dev == DEV then return end
    warn(string.format("Version mismatch: you have AnteUp2 %s, the server has %s. Effects and some "
        .. "features may not work until both match.", VC.Label(), label(major, minor, dev)))
end

-- [AUTHORITY] Re-announce on a heartbeat so a player who joins later hears it within one period.
-- `gen` retires a loop left over from an earlier Start in the same world.
local function announceLoop(gen)
    if STATE.VersionLoopGen ~= gen then return end
    NET.Broadcast(NET.OP.VERSION, { { x = MAJOR, y = MINOR, z = DEV and 1 or 0 } })
    Utils.QueueWork(function() announceLoop(gen) end, CFG.AnnounceMs, true)
end

-- Every role, every world (InitMod).
function VC.Start()
    if Utils.IsAuthority() then
        STATE.VersionLoopGen = (STATE.VersionLoopGen or 0) + 1
        local gen = STATE.VersionLoopGen
        Utils.QueueWork(function() announceLoop(gen) end, CFG.FirstAnnounceMs, true)
        return
    end

    heard, warned = false, false
    NET.RegisterReceiver()
    NET.On(NET.OP.VERSION, onVersion)
    Utils.QueueWork(function()
        if heard then return end
        warn("The server hasn't reported an AnteUp2 version, so it is running an older build or "
            .. "doesn't have AnteUp2. Effects and some features may not work.")
    end, CFG.SilenceWarnMs)
end

return VC
