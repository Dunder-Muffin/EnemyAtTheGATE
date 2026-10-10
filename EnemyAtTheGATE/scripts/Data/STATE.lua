-- ============================================================
-- STATE
-- Tracks some information across various parts of the mod
-- ============================================================

local State = {

    -- Loaded from CONFIG.json in main.lua before any other modules
    Config = {},

    -- General
    ModInitCalled  = false,
    ModEnabled     = false,
    IsPaused       = false,

    -- Net role: "HOST" (SP / listen-server host), "DEDICATED", or "CLIENT"
    -- (joined a remote game). Set by Utils.DetectRole(); can change between
    -- worlds, so it is re-detected each InitMod. nil until first detected.
    Role = nil,

    -- Debug wiring guards (register once per session)
    IsChatCommandsRegistered = false,
    IsClientFXRegistered     = false,
    -- Client-only bootstrap (joined a remote/dedicated server): set once the
    -- local player's ReceiveTick has registered client-side debug keybinds.
    ClientBootstrapDone = false,

    -- Only registers once
    IsHookAlreadyRegistered    = false,
    IsKeybindsAlreadyRegistered = false,
    -- ProcessSpawns_Quick (fast tick) is registered inside InitMod after the AIDirector
    -- is confirmed loaded. Guard prevents double-registration across world reloads.
    IsFastTickRegistered = false,

    -- Raw tick counter; incremented every ProcessSpawns_Quick call (~10/sec).
    -- Used by QueueManager for 100 ms resolution scheduling.
    TICKS = 0,
    SECONDS_TICK = 0, -- ticks just expressed in seconds

    -- =====================================================================

    -- Relative scale of how far are we in the game (each sector is ~10 points)
    StoryProgress = 0,

    -- Last custom assault used (full entry table)
    LastCustomAssault = nil,


    -- Last 5 applied assaults and customIndex ("monkdad_1" for monkdad assault, 1st custom assault)
    RecentAssaults = {},

    -- When the director queues an assault, we apply assaultData. The director may end up shuffling again, 
    --   so we only want to add this assault to STATE.RecentAssaults when wave 1 starts.
    RecentAssaults_Pending = nil,   -- { row, idx } or nil


    -- Game day when the most recent assault was initiated (SortAssaultSpawnLists)
    -- * Used by CheckDaysSinceLastAssault instead of dayNight.LastAssaultDay
    LastAssaultDay = -1,


    -- Prep time of the current assault - game default is 20s
    -- * We have EventManager functions that add prepTime to their delay
    AssaultPrepTime = 20000,

    -- Weather effect currently requested by AssaultWeather. 
    -- * Tracking this so we can force set weather if cleared
    ActiveAssaultWeather = nil,

    -- Tracks whether the Snowman hooks are registered.
    -- * Registering will fail if done at startup if there's no Snowman
    IsSnowmanHookRegistered = false,

    ENDLESS_EXCLUDE_ROWS = { "assault_peststorm", "assault_peccaryboss", "assault_peststorm_electro", "assault_peststorm_volatile" }, 



    -- =====================================================================



    -- Set by debug cycle keybinds (SHIFT+LEFT/RIGHT) to force a specific entry
    -- regardless of SP range; cleared by SortAssaultSpawnLists after use
    DebugQueuedAssault = nil,   -- { row, idx, data } or nil

    -- Set when the endless loop calls ServerForceBeginAssault, cleared when
    -- wave 1 fires (phase 2) or the assault ends. Prevents the loop from
    -- double-starting during the 20s prep phase where IsAssaultHappening() = false.
    EndlessAssaultPending = false,


    -- DOES NOT WORK :(
    -- Disable scarecrows during Symphonist encounters
    DisableScarecrows = false,

    -- Tracks Scarecrow hook. We can't register if there's no scarecrows around
    IsScarecrowHookRegistered = false,


}

return State
