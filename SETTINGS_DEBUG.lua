
-- ==============================================================================-
-- LOGGING AND DEV TOOLS
--
-- Crashing or freezing?
--
-- 1) Turn on everything in CRASH AND FREEZE REPORTS just below, and the DEBUG SETTINGS under it
--     + on a hosted server, also DEBUG_MIRROR_LOG
--
-- 2) If AbioticFactor crashes, copy ue4ss.log BEFORE restarting the game.
--     + starting the game again resets the logs
--     + Steam\steamapps\common\AbioticFactor\AbioticFactor\Binaries\Win64\ue4ss\
--     + a hosted server: Mods\AnteUp2\saved\logs\ (the mirror logs)
--
-- 3) Check the Crashes folder. If there's a crash log, copy that
--     + AppData\Local\AbioticFactor\Saved\Crashes
--     + a dedicated server: AbioticFactor\Saved\Logs\ (the crash stack is in the newest log)
--
--    IF there's a game freeze, provide ue4ss.log. There's typically a repeating line
--
-- 4) Providing both and what you were doing. This will help a lot!
--
-- You can use something like file.io to upload zip files (free)
-- ==============================================================================-

local SETTINGS_DEBUG = {

-- =======================================================================
-- CRASH AND FREEZE REPORTS - the ones to turn on when asked for logs
--   * They cost log size, not gameplay
-- =======================================================================

    DEBUG_FREEZE_TRACE = false,      -- Watchdog for game freezes. Will print out a stall line
    FREEZE_TRACE_LINE_GAP_SEC = 30,  -- at most one "FT wq/eigt" line per source per this many seconds
    DEBUG_FREEZE_TRACE_TICK = false, -- Use alongside FREEZE_TRACE when looking for an AV bug
    DEBUG_LOOKUP_TRACE = false,      -- An "FT sfo" line before every lookup by path - names the one a crash died in


    DEBUG_MIRROR_LOG = false,       -- If your server auto-restarts and wipes ue4ss.log, 
                                    -- this will write another log file in Anteup/saved/logs


-- =======================================================================
-- DEBUG SETTINGS
--   * Disabling these is a very minor performance difference
-- =======================================================================

    -- Spawners
    DEBUG_SPAWNERS = true,          -- spawner fires / variant decisions

    -- NPC creation and actions
    DEBUG_SPAWN_TRACE = true,       -- "spawn-> / spawn<-" around every actor spawn, to catch if a spawn broke
    DEBUG_NPC_ACTIONS = true,       -- mutations and variant behavior
    DEBUG_ATTACHMENTS = true,       -- component attach steps
    DEBUG_ATTACHMENTS_FULL = false, -- extra per-call attach detail

    -- Item related
    DEBUG_DROPS = false,            -- per-step item-spawn logging (pinpoints a drop crash)
    DEBUG_CUSTOM_ITEMS = false,     -- debug custom items
    DEBUG_BOBBLEHEADS = false,      -- debug bobbleheads
    DEBUG_PROJECTILE_HITS = false,   -- [VERBOSE]  debugging what projectiles exploded on

    -- Work queue
    DEBUG_QUEUES = true,           -- WorkQueue activity

    -- Story/Lore
    DEBUG_STORY = true,             -- StoryProgress transitions
    DEBUG_JOURNAL = true,           -- compendium/journal hook fires (per local player)

    -- Director (ModuleDirector)
    DEBUG_DIRECTOR = false,          -- eligibility + spawn decisions. On a HOST these ALSO echo to chat
                                    --   (log-only on a dedicated server). _Export-AnteUp2 forces this false

    -- Log damage
    DEBUG_CLIENT = true,           -- client-side scanning/visuals
    DEBUG_DAMAGE_NPC = true,       -- npc damage taken
    DEBUG_DAMAGE_PLAYER = true,    -- (any source of damage - proj/grenades)


    -- WHERE STUFF TENDS TO BREAK
    DEBUG_ASSET_LOADS = true,       -- Logs unloaded assets - "ASSETS cold-load: <path>"
                                    -- Used to check if/when these are cold-loaded


    DEBUG_HOOK_PROBE = false,       -- Test if a hook can be registered and does it fire


    -- Microlag/stutter profiler (AnDebug/Profiler)
    --   * Live lines: HITCH frames, and SLOW only for a label's first slow call or a regression
    --   * The periodic report lists only slow or hot labels, and a quiet period prints nothing
    --   * "/prof" in chat dumps a full report
    DEBUG_PROFILE = false, --devnote: pause the game before doing a full reload
    PROFILE_HITCH_MS = 50, --50
    PROFILE_REPORT_SEC = 300,
    PROFILE_SLOW_MS = 5,            -- one call this long is slow
    PROFILE_HOT_MS_PER_SEC = 1,     -- a label averaging this much work per second is hot




-- =======================================================================
-- DEV TOOLS - probably really leave these alone
-- =======================================================================

    -- ** WARNING: Lots of keybinds you may not want on, especially on a server ** --

    DEBUG_KEYBINDS = false,         -- summon/cleanup/dump keybinds
    DEBUG_CHAT_COMMANDS = false,    -- if on a server, allows clients to do keybind stuff
    DEBUG_SHOW_SPAWNERS = false,    -- floating debug text over every spawner
    DEBUG_TRADER_WINDOW = false,    -- trader item flow
    DEBUG_SENSES = false,           -- what the NPC sight/hearing/light setup did at startup

    -- ModuleCheats - a few things from cheatconsolecommands when that mod was freezing
    --   /instantfishing   /au-resetportals   /au-trapleyak  /au-trapkrasue   
    -- 
    -- Some other debug cheats
    --   /topup - removes most debuffs, refills needs meters
    --   /au-settime <0-23|day|night> - another way to set ingame time    --   
    --   /au-turret [find|break] 
    --   /placedviz - show added fake spawns
    --   /locvis - show current location
    -- 
    -- Enable submods
    --   /npch - NpcHighlighter mod, outlines nearby NPCs ([Shift+H] / [Ctrl+H])
    --
    -- Typed in CHAT, so these also need DEBUG_CHAT_COMMANDS = true (which turns on every dev chat
    -- command too, /spawn included, for anyone on a server). DEBUG_KEYBINDS adds no cheats.
    DEBUG_CHEATS = false,

    -- Console cheats: SINGLE PLAYER ONLY, and need no other flag. Open the console (~ or F10) and
    -- type a cheat: noclip, god, invis, craft, topup, refill, instantfishing, settime, ... -
    -- "cheats" lists them all. Don't also run the CheatConsoleCommands mod.
    DEBUG_CONSOLE_CHEATS = false,

}



return SETTINGS_DEBUG
