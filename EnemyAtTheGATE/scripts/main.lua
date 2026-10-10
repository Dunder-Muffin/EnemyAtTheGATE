---@diagnostic disable: undefined-global, undefined-field, unused-local, param-type-mismatch

-- ============================================================
-- main.lua
-- * Waits for a game world to start
-- * Registers hooks once
-- * Occasionally sets a 'StoryProgress' score based on WorldFlags
-- ============================================================


    -- ============================================================
    -- [DEBUG] ExecuteInGameThread tracer  (DELETE this whole block to revert)
    -- Shadows the global, so every EIGT call anywhere logs a trace.
    --
    -- Reading the log:
    --   * "queue", no "returned"     - the EIGT call is BLOCKING its caller
    --                                  (a deadlock if that caller is the game thread)
    --   * "queue" + "returned", no ENTER - the game-thread queue isn't draining
    --   * all four lines             - EIGT is fine, the hang is elsewhere
    -- ============================================================
    do
        local _STATE = require("Data.STATE")   -- for the DEBUG flag (loaded at runtime)
        local _rawEIGT = ExecuteInGameThread
        local _seq = 0
        local function dbg(m)
            if _STATE.Config and _STATE.Config.DEBUG_LOG then print("[GATE] " .. m .. "\n") end
        end
        ExecuteInGameThread = function(fn)
            _seq = _seq + 1
            local id = _seq
            local info = debug.getinfo(2, "Sl")
            local where = info and (info.short_src .. ":" .. tostring(info.currentline)) or "?"
            dbg(string.format("[EIGT #%d] queue    <- %s", id, where))
            _rawEIGT(function()
                dbg(string.format("[EIGT #%d] ENTER (game thread)", id))
                local ok, err = pcall(fn)
                if not ok then dbg(string.format("[EIGT #%d] ERROR  %s", id, tostring(err))) end
                dbg(string.format("[EIGT #%d] EXIT", id))
            end)
            dbg(string.format("[EIGT #%d] returned", id))
        end
    end


local UEHelpers = require("UEHelpers")
local AFUtils   = require("AFUtils.AFUtils")

require("AFUtils.AFBase")
require("AFUtils.BaseUtils.BaseUtils")
require("AFUtils.BaseUtils.LinearColors")
require("AFUtils.BaseUtils.DefaultObjects")
require("AFUtils.BaseUtils.StaticClasses")

local STATE  = require("Data.STATE")
local GATE   = require("Managers.GATEManager")
local CONFIG = STATE.Config

local Utils           = require("Utils.Utils")
local Debug           = require("Utils.UtilsDebug")
local QM              = require("Managers.QueueManager")
local AssaultHooks    = require("Hooks.AssaultHooks")
local SystemHooks     = require("Hooks.SystemHooks")
local StoryManager    = require("Managers.StoryManager")
local Keybinds        = require("Utils.Keybinds")
local ChatCommands    = require("Hooks.ChatCommands")
local ClientFX        = require("Hooks.ClientFX")
local AssetKeeper     = require("Utils.AssetKeeper")

local Log = Utils.Log
local LogBad = Utils.LogBad
local LogDebug = Utils.LogDebug

-- Starts when a game world is loaded, so this is our entry hook
local HOOK_SLOW_TICK = "/Game/Blueprints/Meta/Abiotic_Survival_GameState.Abiotic_Survival_GameState_C:UpdateNPCDebugInfo"

-- Registered after InitMod(), this is our work hook. It ticks every 100ms and
--   we use it and a WorkQueue to drive some functions
local HOOK_FAST_TICK = "/Game/Blueprints/Environment/Systems/Abiotic_AIDirector.Abiotic_AIDirector_C:ProcessSpawns_Quick"
local HOOK_QUIT = "/Game/Blueprints/Widgets/MenuSystem/W_EscapeMenu_Main.W_EscapeMenu_Main_C:Quit_Quit"

-- These hooks are for clients. Clients don't need this mod but 
--   * They won't see visual effects (such as portals) without it
--   * Allows clients to run Debug keybind commands (using chat as the medium)
--   * Clients don't have access to many of the hooks, but they do to their Character
local HOOK_CLIENT_BEGINPLAY = "/Game/Blueprints/Characters/Abiotic_PlayerCharacter.Abiotic_PlayerCharacter_C:ReceiveBeginPlay"
local HOOK_CLIENT_TICK      = "/Game/Blueprints/Characters/Abiotic_PlayerCharacter.Abiotic_PlayerCharacter_C:ReceiveTick"

local MAIN = {}


-- ============================================================
-- Wait a bit before starting ModLoop. 
--    * Prevents some race conditions with mod loading
-- ============================================================
ExecuteWithDelay(3000, function()
    MAIN.LoadConfig()
end)

-- ModLoop is all RegisterHook calls, and each one is a StaticFindObject - FATAL if it lands on
-- this worker thread while the game thread is collecting garbage. The timer stays here; the
-- registrations hop to the game thread.
ExecuteWithDelay(3000, function()
    Utils.RunOnGameThread(function()
        STATE.ModInitCalled = false
        MAIN.ModLoop()
    end)
end)


-- ============================================================
-- Game loop - two ticks, registered at different times
--
-- * HOOK_SLOW_TICK (~1/sec, GameState) - init trigger + periodic work.
--     Registered at startup: GameState always loads before the AIDirector,
--     so this hook is findable even on slow game loads.
-- * HOOK_FAST_TICK (~10/sec, AIDirector) - registered inside InitMod once the
--     world is stable. Increments TICKS and drains QM at 100 ms resolution.
-- ============================================================
function MAIN.ModLoop()
    Log("ModLoop started")

    RegisterHook(HOOK_SLOW_TICK, function(self)
        if not STATE then return end

        if not STATE.ModInitCalled then
            MAIN.InitMod()
        end

        if not STATE.ModEnabled then return end

        STATE.SECONDS_TICK = STATE.SECONDS_TICK + 1

        -- Grab WorldFlags and update score every minute
        if STATE.SECONDS_TICK % 60 == 0 then
            StoryManager.GetStoryProgress()
        end

        -- ASSAULTS_PER_WEEK = 8 - nonstop assaults
        if CONFIG.ASSAULTS_PER_WEEK and CONFIG.ASSAULTS_PER_WEEK >= 8 and
           STATE.SECONDS_TICK % 30 == 0 then
            local _dir = FindFirstOf("Abiotic_AIDirector_C")
            if _dir and IsValid(_dir) and not _dir:IsAssaultHappening() then
                _dir:ServerForceBeginAssault()
            end
        end

        -- -- DEBUG: Remove Concussion
        -- Debug.P1RemoveConcussion()
    end)

    -- User exits to main menu. StopMod destroys AssetKeeper's components, so it runs on the
    -- game thread; the 2s worker-thread delay only lets the world finish tearing down first.
    RegisterHook(HOOK_QUIT, function(self)
        STATE.ModEnabled = false
        Utils.DelayedGameThread(2000, MAIN.StopMod)
    end)

    -- Client bootstrap triggers. Both call the idempotent ClientBootstrap - the
    -- first to fire wins, the rest no-op via ClientBootstrapDone.
    --   * ReceiveBeginPlay - the reliable one
    --   * ReceiveTick      - fallback
    RegisterHook(HOOK_CLIENT_BEGINPLAY, function()
        if STATE.ClientBootstrapDone then return end
        MAIN.ClientBootstrap()
    end)
    RegisterHook(HOOK_CLIENT_TICK, function()
        if STATE.ClientBootstrapDone then return end
        MAIN.ClientBootstrap()
    end)
end


-- ============================================================
-- Runs once after the world loads
-- ============================================================
function MAIN.InitMod()
    Log("InitMod starting")

    STATE.ModInitCalled = true

    -- Net role for this world. InitMod only ever runs on authority (HOST/SP or a
    -- dedicated server) because HOOK_FAST_TICK is a server-only AIDirector function.
    Utils.DetectRole()

    -- Register hooks
    if not STATE.IsHookAlreadyRegistered then
        AssaultHooks.Register()
        SystemHooks.Register()
        STATE.IsHookAlreadyRegistered = true
    end
    LogDebug("InitMod: hooks registered", CONFIG.DEBUG_LOG)


    -- Get WorldFlags, set StoryProgress score
    StoryManager.GetStoryProgress()
    LogDebug("InitMod: GetStoryProgress done", CONFIG.DEBUG_LOG)

    -- No preloading. 954 GCs preloaded assets before they're needed, so assets
    -- now load on demand (and reload if GC'd) via Utils.AssetManager - SpawnNpc,
    -- SpawnEffect and the sound helpers all go through it. See [GATE-DEBUG] notes.

    -- Config stuff
    if not CONFIG.ENABLE_ASSAULT_REBALANCING then
        Utils.DisableAssaultRebalancing()
    else
        Utils.ToggleFurnitureDestruction()
    end

    -- Client FX receiver - plays server-sent portal FX locally. Registered on any
    -- machine with a renderer; here that's host/SP, clients do it in
    -- ClientBootstrap. A dedicated server has no renderer, so it skips this.
    if Utils.HasRenderer() and not STATE.IsClientFXRegistered then
        ClientFX.Register()
        STATE.IsClientFXRegistered = true
    end

    -- Pin the portal FX + loop sounds for this world. Warming alone doesn't stick -
    -- UE GCs an asset nothing hard-refs, and a GC'd one is silently SKIPPED by the
    -- non-loading GetIfValid. Pinning also makes their lookups a table hit instead
    -- of a UObject-array walk. Renderer-only; see Utils/AssetKeeper.
    AssetKeeper.Establish()

    -- Debug wiring (authority side). The two halves are gated SEPARATELY so you
    -- can run one without the other - GATE's keybinds overlap AnteUp's, so the
    -- common setup is DEBUG_KEYBIND = false with DEBUG_COMMAND = true.
    --   * /gate chat commands - on the server/host, so clients can drive debug
    --     actions over chat (works on a dedicated server too)
    --   * keybinds - only where there's a renderer (HOST/SP). A dedicated server
    --     has no input; its clients get keybinds via ClientBootstrap
    if CONFIG.DEBUG_COMMAND and Utils.IsAuthority() and not STATE.IsChatCommandsRegistered then
        ChatCommands.Register()
        STATE.IsChatCommandsRegistered = true
    end
    if CONFIG.DEBUG_KEYBIND and Utils.HasRenderer() and not STATE.IsKeybindsAlreadyRegistered then
        Keybinds.Register()
        STATE.IsKeybindsAlreadyRegistered = true
    end


    -- Fast tick (ProcessSpawns_Quick) - drives QM.Drain at ~100 ms resolution.
    -- Registered here rather than at startup because the AIDirector and its
    -- UFunction must exist first, and on slow loads they aren't ready yet.
    if not STATE.IsFastTickRegistered then
        local ok, err = pcall(function()
            RegisterHook(HOOK_FAST_TICK, function()
                STATE.TICKS = STATE.TICKS + 1
                if STATE.ModEnabled then
                    QM.Drain()
                end
            end)
        end)
        if ok then
            STATE.IsFastTickRegistered = true
            Log("InitMod: fast tick registered")
        else
            LogBad("InitMod: fast tick registration failed: " .. tostring(err))
        end
    end

    -- Everything's good
    STATE.ModEnabled = true
    LogDebug("InitMod: body complete, returning to hook", CONFIG.DEBUG_LOG)

    -- AFUtils.DisplayWarningMessage("[GATE] Enemy at the GATE loaded.")
    
    -- Chat writes the chat widget, so this runs on the game thread, not the delay's worker thread.
    Utils.DelayedGameThread(1500, function()
        
        -- Check if the assaults were loaded correctly
        local entries = GATE.GetAllAssaultRows()
        
        if entries and #entries > 0 then
            Utils.Chat("[GATE] EnemyAtTheGATE loaded")
            Utils.Chat("- ASSAULT FILE: " .. CONFIG.DIFFICULTY)
            Utils.Chat("- ASSAULTS/WEEK: " .. (CONFIG.ASSAULTS_PER_WEEK or 1))
            Utils.Chat("<Open mod/CONFIG.lua for options>")
        --     Utils.Chat("**ERROR: CUSTOM ASSAULTS FILE **")
        --     Utils.Chat("- File has an error or not found")
        --     Utils.Chat("- See steamapps\\common\\AbF\\AbF\\Binaries\\Win64\\ue4ss\\ue4ss.log")
        --     Utils.Chat("   and restart the game")
        end

        -- Utils.Chat("- REBALANCING MODE ENABLED: " .. tostring(CONFIG.ENABLE_ASSAULT_REBALANCING))

        
    end)
    
end


-- ============================================================
-- Client bootstrap (joined a remote / dedicated server)
-- * A CLIENT never runs InitMod, so the character's ReceiveTick 
--     registers the debug keybinds here. Uses chat commands
--     for the server to execute
-- ============================================================
function MAIN.ClientBootstrap()
    -- Wait for AFUtils.GetSurvivalGameState()
    --   * At the pawn's ReceiveBeginPlay / earliest ticks 
    --       the net connection isn't established, and DetectRole()
    --       may mistakenly come back as HOST
    if IsNotValid(AFUtils.GetSurvivalGameState()) then return end
    if not next(CONFIG) then return end          -- config not loaded yet; retry

    local role = Utils.DetectRole()
    LogDebug(string.format("ClientBootstrap: role=%s keybinds=%s", tostring(role), tostring(CONFIG.DEBUG_KEYBIND)), CONFIG.DEBUG_LOG)

    -- Authority handles its own debug setup in InitMod.
    if not Utils.IsClient() then
        STATE.ClientBootstrapDone = true
        return
    end

    -- Client-local cosmetic FX (all clients, not just debug): the server's FX
    -- actor doesn't replicate, so the client plays portal FX off replicated NPC
    -- bursts. See Hooks/ClientFX.
    if not STATE.IsClientFXRegistered then
        ClientFX.Register()
        STATE.IsClientFXRegistered = true
    end

    -- Same pins as the host gets in InitMod - a client renders the portals, so it
    -- needs the FX and loop sounds held in memory just as much.
    AssetKeeper.Establish()

    -- Client keybinds only. A client can always TYPE /gate commands - the server
    -- decides whether to act on them (CONFIG.DEBUG_COMMAND, server-side).
    if CONFIG.DEBUG_KEYBIND and not STATE.IsKeybindsAlreadyRegistered then
        Keybinds.Register()
        STATE.IsKeybindsAlreadyRegistered = true
        Log("client debug keybinds registered (/gate commands -> server)")
    end
    STATE.ClientBootstrapDone = true
end


-- ============================================================
-- Reset variables
-- ============================================================
function MAIN.StopMod()
    Log("StopMod called")

    STATE.TICKS               = 0
    STATE.SECONDS_TICK        = 0
    STATE.ModEnabled          = false
    STATE.ModInitCalled       = false
    STATE.LastCustomAssault   = nil
    STATE.RecentAssaults      = {}
    STATE.StoryProgress       = 0
    STATE.DisableScarecrows   = false
    STATE.LastAssaultDay      = -1
    STATE.BossRoll            = nil
    QM.Reset()

    -- Drop the asset pins with the world. The hard refs belonged to a GameState that
    -- is going away, and the cache-trust they justified has to go with them.
    AssetKeeper.Release()

end



-- ============================================================
-- This blob is just loading the Config.lua into CONFIG
-- ============================================================
function MAIN.LoadConfig()
    local _src = debug.getinfo(1, "S").source
    if _src:sub(1,1) == "@" then _src = _src:sub(2) end
    local MOD_ROOT = _src:match("(.+[\\/])") .. "../"

    local configFn = loadfile(MOD_ROOT .. "CONFIG.lua")
    local loaded = {}
    if configFn then
        local ok, result = pcall(configFn)
        if ok and type(result) == "table" then loaded = result end
    else
        print("[GATE][ERR] Config.lua not found!\n")
    end
    for k, v in pairs(loaded)   do STATE.Config[k] = v end

    -- Legacy CONFIG.DEBUG support.
    --   * DEBUG used to cover logging + keybinds + chat commands in one flag
    --   * it's now three, so the keybinds (which collide with AnteUp's) can be
    --     turned off on their own
    --   * an old CONFIG.lua keeps the all-or-nothing behaviour instead of
    --     silently losing every debug feature
    local legacy = STATE.Config.DEBUG
    if legacy ~= nil then
        if STATE.Config.DEBUG_LOG     == nil then STATE.Config.DEBUG_LOG     = legacy end
        if STATE.Config.DEBUG_KEYBIND == nil then STATE.Config.DEBUG_KEYBIND = legacy end
        if STATE.Config.DEBUG_COMMAND == nil then STATE.Config.DEBUG_COMMAND = legacy end
    end
end
