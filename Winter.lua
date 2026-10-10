-- =======================================================================
-- Winter [AUTHORITY] - ambient WHITEOUTS in the winter vignettes. ONGOING.
--   (Event_Dams_Ongoing_Winter)
--   Every WINTER_CHECK_MIN..MAX ms (randomized), each live player gets: area check
--   (V_Alps/Voussoir box) -> already-storming skip -> roof check (upward line trace) ->
--   AVU.TriggerBlizzard, a cosmetic whiteout.
--   WINTER.GateTick arms the loop once story passes WINTER_MIN_PROGRESS; story never regresses,
--   so there's no disarm. WINTER.Toggle is the manual override behind Event_Dams_Ongoing_Winter.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")

local Log = Utils.Log
local LogDebug = Utils.LogDebug

local WINTER = {}


local WINTER_MIN_PROGRESS = 51      -- Dams_ReachedCentral: Voussoir is unreachable before this

-- V_Alps (Voussoir) bounding box - user-measured corners, generously padded. The only ambient-storm
-- area for now; add a second box and check both to add another (e.g. V_Winter).
-- Measured extremes: X -280311..-256418, Y 72186..100867, Z -12500..-133.
local WINTER_ALPS_BOX = {
    MinX = -285000, MaxX = -251000,
    MinY =   67000, MaxY = 106000,
    MinZ =  -15000, MaxZ =    2500,   -- headroom above the highest peak (-133)
}

local WINTER_CHECK_MIN_MS = 10000   -- roof-check cadence per cycle (randomized in range)
local WINTER_CHECK_MAX_MS = 20000
local WINTER_ROOF_TRACE_Z = 2500    -- "a roof within 25m above" suppresses the storm
local WINTER_DUR_MIN_S    = 3       -- whiteout length
local WINTER_DUR_MAX_S    = 8
local WINTER_BLIZ_SIZE    = 1800    -- zone half-extents (~18m box). Modest on purpose: an indoor
                                    -- player rarely shares an outdoor player's volume.

local function winterInAlps(loc)
    return loc.X >= WINTER_ALPS_BOX.MinX and loc.X <= WINTER_ALPS_BOX.MaxX
       and loc.Y >= WINTER_ALPS_BOX.MinY and loc.Y <= WINTER_ALPS_BOX.MaxY
       and loc.Z >= WINTER_ALPS_BOX.MinZ and loc.Z <= WINTER_ALPS_BOX.MaxZ
end

-- One player's cycle: area box first (pure Lua), then storm-dedup, then the roof trace.
local function winterCheckPlayer(p)
    local ok, loc = pcall(function() return p:K2_GetActorLocation() end)
    if not ok or not loc then return end

    if not winterInAlps(loc) then return end         -- not in Voussoir: free early-out
    if AVU.BlizzardActiveNear(loc) then return end   -- already storming here

    local from = FVector(loc.X, loc.Y, loc.Z + 100)
    local to   = FVector(loc.X, loc.Y, loc.Z + 100 + WINTER_ROOF_TRACE_Z)

    -- likely indoors
    if AVU.IsPathBlocked(p, from, to, { p }) then
        LogDebug("Winter - no storm - target is indoors", SETTINGS.DEBUG_STORY)
        return
    end

    AVU.TriggerBlizzard(loc, { Duration = math.random(WINTER_DUR_MIN_S, WINTER_DUR_MAX_S),
                               Size = WINTER_BLIZ_SIZE })
    LogDebug("Winter - ambient whiteout on a player in Voussoir", SETTINGS.DEBUG_STORY)
end

local function winterLoop()
    if not STATE.ModEnabled or not STATE.WinterArmed then
        STATE.WinterArmed = false
        return
    end
    for _, p in ipairs(Utils.LivePlayers()) do
        pcall(winterCheckPlayer, p)
    end
    Utils.QueueWork(winterLoop, math.random(WINTER_CHECK_MIN_MS, WINTER_CHECK_MAX_MS))
end

local function winterStart()
    if STATE.WinterArmed then return end
    STATE.WinterArmed = true
    Utils.QueueWork(winterLoop, math.random(WINTER_CHECK_MIN_MS, WINTER_CHECK_MAX_MS))
    Log("Winter armed (ambient whiteouts: Voussoir/V_Alps box)")
end

-- Story gate, called from StoryManager.Tick each beat: two compares until it arms, then a no-op.
-- Skips ALL winter work (loop + per-player checks) while story <= WINTER_MIN_PROGRESS.
function WINTER.GateTick(story)
    if not Utils.IsAuthority() or STATE.WinterArmed then return end
    if (story or 0) <= WINTER_MIN_PROGRESS then return end
    winterStart()
end

-- Manual toggle (keybind/chat), like the Hexed Tree's: force the loop on/off anywhere for testing.
function WINTER.Toggle()
    if STATE.WinterArmed then
        STATE.WinterArmed = false   -- the loop sees this and stops rescheduling
        Log("Winter disarmed (manual)")
    else
        winterStart()
    end
end


return WINTER
