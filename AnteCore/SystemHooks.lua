-- =======================================================================
-- SystemHooks - game-system hooks that drive the StoryManager:
--   * ResetVignettes     - portals/vignettes reset: makes specific enemies respawn  [AUTHORITY]
--   * WorldFlagsChanged  - run an immediate event check                            [AUTHORITY]
--                          (so the periodic StoryManager tick can stay slow)
--   * SetGamePaused      - track STATE.IsPaused (SP/host - pause is an authority thing)
--
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local Utils = require("AnteUtils.Utils")
local StoryManager = require("ModuleStory.StoryManager")

local Log = Utils.Log
local LogDebug = Utils.LogDebug
local LogBad = Utils.LogBad

local SH = {}

local RESET_VIGNETTES    = "/Game/Blueprints/Meta/Abiotic_GameInstance.Abiotic_GameInstance_C:ResetVignettes"
local WORLDFLAGS_CHANGED = "/Script/AbioticFactor.GameActivitySubsystem:WorldFlagsChanged"
local SET_GAME_PAUSED    = "/Script/Engine.GameplayStatics:SetGamePaused"
local CLOSE_ESCAPE_MENU  = "/Game/Blueprints/Meta/Abiotic_PlayerController.Abiotic_PlayerController_C:CloseEscapeMenuAndResumeGame"

local registered = false

function SH.Register()
    if registered then return end
    registered = true

    -- =======================================================================
    -- Vignette/portal reset -> clear per-vignette story flags
    -- =======================================================================
    local ok1 = pcall(RegisterHook, RESET_VIGNETTES, function()
        if not Utils.IsAuthority() then return end
        local ok, err = pcall(StoryManager.OnVignetteReset)
        if not ok then LogBad("ResetVignettes hook error: " .. tostring(err)) end
    end)

    -- =======================================================================
    -- A world flag changed -> immediate event check
    -- =======================================================================
    local ok2 = pcall(RegisterHook, WORLDFLAGS_CHANGED, function()
        if not Utils.IsAuthority() then return end
        LogDebug("WorldFlagsChanged", SETTINGS.DEBUG_STORY)
        local ok, err = pcall(StoryManager.Tick)
        if not ok then LogBad("WorldFlagsChanged hook error: " .. tostring(err)) end
    end)

    -- =======================================================================
    -- PAUSE TRACKING (all roles - a listen host pausing stops the world for everyone).
    --   * Hook the SETTER, never IsGamePaused. That's a QUERY that engine and BP code
    --     call constantly regardless of state, so it would latch true on the first ask
    --     and put a Lua callback on one of the hottest engine statics (EnemyAtTheGATE
    --     tried this and backed it out). The setter fires only on a real state change
    --     and carries the value.
    --   * These callbacks fire from escape-menu WIDGET code - the Slate-tick hazard
    --     (CLAUDE.md 2). The body is a pure Lua table write only: no actor calls,
    --     no queueing.
    --   * Read by the freeze watchdog: world timers stop while paused, so FAST_TICK
    --     stops, and a paused player looks identical to a wedged game thread (see
    --     TickManager's watchdog for the stall signature this produces).
    -- =======================================================================
    local ok3 = pcall(RegisterHook, SET_GAME_PAUSED, function(_self, _worldContext, bPaused)
        -- 954+ wraps params (:get() them); older builds hand over the raw value.
        local ok, v = pcall(function() return bPaused:get() end)
        if not ok then v = bPaused end
        STATE.IsPaused = (v == true)
        if STATE.IsPaused then STATE.PauseEpoch = (STATE.PauseEpoch or 0) + 1 end   -- TestTap: a paused gap is no stall
    end)

    -- Belt-and-braces: the escape menu has its own resume path, and a missed
    --   unpause would leave the watchdog muted for the rest of the session.
    local ok4 = pcall(RegisterHook, CLOSE_ESCAPE_MENU, function()
        STATE.IsPaused = false
    end)

    Log("SystemHooks registered (vignette=" .. tostring(ok1) .. " worldflags=" .. tostring(ok2)
        .. " pause=" .. tostring(ok3) .. "/" .. tostring(ok4) .. ")")
end

return SH
