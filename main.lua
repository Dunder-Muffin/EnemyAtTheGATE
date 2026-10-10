-- =======================================================================
-- AnteUp2 - NPC Antevariants for Abiotic Factor
--
-- BASICS
--   * Creates 'Antevariants' of existing NPCs by mutating NPCs from the
--     game's NPCSpawners as well as PsuedoSpawners that spawn additional enemies
-- 
--   * Antevariants are visually different and have a variety of changes -
--     stats, behaviors, abilities, etc. 
-- 
--   * Around this core game flow are modules - some optional, some not. 
--     Required modules update Journal entries, create Story Events/Assaults
--     Optional modules add pets, traders, custom items, and debug cheats
-- 
--   * Multiplayer: Required for server and clients.
--
-- ROLES (detected once per world in InitMod)
--     HOST      - single player / listen server: decides variants AND
--                 renders them (stats + visuals + UI hooks).
--     DEDICATED - dedicated server: decides variants, applies stats.
--                 No renderer -> no Visuals, no UI/widget hooks.
--     CLIENT    - joined player: visuals only. Never decides anything;
--                 it re-derives what the server already decided.
--
-- =======================================================================
-- 
-- HIGH LEVEL MOD FLOW
--
--  1. BOOT. Script load requires every module explicitly (no glob loader).
--     MAIN.Start (3s after load) registers two idempotent init triggers:
--       * authority: GameState UpdateNPCDebugInfo - a server-side 1s timer that
--         fires even with zero players, so dedicated servers init too.
--       * client: the local player's ReceiveTick - the only reliable
--         "world running" tick a pure client has.
--     Whichever fires calls TryInit -> InitMod once per world: detect role,
--       register the role's hook set, arm the modules.
--     On world teardown (GameMode ReceiveEndPlay) StopMod releases old-world
--       refs so the engine can GC; the next world re-inits fresh.
--
--  2. HEARTBEAT. AnteCore/TickManager, ~10/s per role.
--       * Authority rides the AI Director's ProcessSpawns_Quick hook;
--         a client throttles its ReceiveTick down to the same cadence.
--       * Each beat drains STATE.WorkQueue - ALL deferred actor work funnels
--         through it so it runs on the game thread (never ExecuteWithDelay
--         for actor work: worker thread).
--       * The drain is capped per tick (WORKQUEUE_MAX_PER_TICK) so spawn bursts
--         can't slam one frame; per-actor OnTick handlers are phase-offset so
--         their "% N" gates don't all land on the same frame.
--
--  3. THE MAIN PATH (authority). Nearly all variant work starts at the
--     spawner hooks.
--       * Every NPC a placed spawner creates passes through TrySpawnNPC
--         (AnteVariants/SpawnerHooks - the mod's main entry into the game).
--       * SpawnerHooks first applies per-spawner config from AnteData/SpawnerData
--         (SpawnAs row rewrites, Count groups, cooldowns, story gating),
--         then hands the spawned actor to NpcManager.
--       * HandleSpawnedActor -> VariantResolver picks a variant for this
--         spawner+base row -> mutation is QUEUED with a random stagger
--         (area load fires many spawners in one frame).
--       * MutateActor runs the declarative def (AnteNPCs/*) through
--         AnteCore/Pipeline: wait-until-ready -> async LoadAssets (never
--         blocking in-hook) -> stats/faction/tag -> OnReady (gameplay
--         subactors) -> Visuals (renderer only).
--       * Every step boundary re-checks the actor still exists (sublevels can
--         stream out mid-pipeline with no teardown).
--       * Ongoing behavior then runs from CombatHooks (damage/death/combat-state
--         dispatch to the def's On* handlers; class-specific hooks are
--         registered lazily on first mutation) and from the def's OnTick via
--         the heartbeat.
--
--  4. SERVER -> CLIENT.
--       * NPCData/DisplayName/meshes don't replicate, and this build is
--         push-model (a replicated prop isn't sent unless MarkReplicatedDirty).
--       * So the server encodes the variant Id as a fraction in the replicated
--         WalkSpeed (VariantTag); live scalars ride a side-effect-free
--         replicated double (VariantSignal).
--
--  5. CLIENT PATH. Clients mirror; they never decide.
--       * ClientVisuals picks up new NPCs event-driven (NotifyOnNewObject + a
--         slow 15s safety sweep), decodes the WalkSpeed tag, and re-runs the
--         variant's Visuals locally.
--       * ClientEffects and TraderMirror re-apply the cosmetics that can never
--         replicate; ClientProjectiles dresses our scripted shots (trail, hidden
--         mesh, size) off the shot's replicated row (PR.LOOKS).
--
--  THREADING / GC. The two crash families that shaped all of the above
--    (blocking-load-in-hook deadlocks, freed-wrapper setters) are documented in
--    CLAUDE.md sections 2-3 - read those before touching spawn / attach / tick code.
-- =======================================================================
-- 
-- MODULES  (folders under scripts/; armed in InitMod, gated by SETTINGS)
--
--   ALWAYS ON - no gate, part of the shipped experience
--     ModuleStory/       Tracks 'StoryProgress'through what WorldFlags are set
--                        * StoryManager gates the triggered Events; each set-piece owns a file
--                          beside it, named by the Events registry (ModuleStory/Events)
--                        * EventUtils owns PlacedSpawns
--     ModuleJournal/     Updates ingame Journal entries with some Antevariant data
--
--   OPTIONAL - SETTINGS.MODULES.* / SETTINGS.GAMEPLAY.* / SETTINGS.MOD_COMPATIBILITY.*
--     ModulePets/        Allows players to tame specific Antevariants, and maintain the variant form.
--                        They'll revert to their base NPC without the mod.
--                        Other options like better regen, respawning dead pets, and a starter pack.
--                        Feeding XP that counts thirst (PetFeeding), bigger sow / mushroom
--                        peccary harvests (PetHarvest)
--
--     ModuleGATE/        Bridges EnemyAtTheGATE if you're letting it handle assaults.
-- 
--     ModuleRevenge/     Tied to ModuleStory. Triggered assaults that act as an 'event'
--
--     ModuleShadow/      Whether to modify the Albatross boss
--
--     ModuleHardMode/    Opt-in difficulty toggles (SETTINGS.MODULES.HARDMODE).
--                        Currently wired: NoAvail (enemies resist stuns/explosives/base defenses)
--
--     ModuleElemental/   Battery melee weapons trade physical damage for their element
--                        (SETTINGS.MODULES.ElementalBalance), so elemental weaknesses matter
--                        without inflating every source of that damage type.
--
--     ModuleDirector/    A light director: spawns small packs out of players' sight when they are
--                        away from base (SETTINGS.MODULES.DIRECTOR; rules in DirectorRules.lua)
--
--     ModuleFarming/     Plantable apple trees (SETTINGS.MODULES.FARMING). Four runtime rows make
--                        food_apple farmable; growth and harvest are native. GrowthRate also drives
--                        the mushroom farm, whose yield doubles. AnNotes/Modules/Farming.md

--     ModuleAudioFix/    Repairs shipped voice waves authored with no SoundClass, which no volume
--                        slider can reach (SETTINGS.CORE.VOICE_SOUNDCLASS_FIX). Renderer-only.
--
--   **Incompatible with ue4ss 3.0.1.553
-- 
--     ModuleTraders/     Rotates a few custom traders that visit on a rotating basis.
--
--     ModuleItems/       Adds custom items, which are mostly contained to one trader. Also holds
--                        the native item/projectile tweaks: ItemMods (authority, weapon rows
--                        on every role) and ProjectileVisuals (renderer).
--
--     ModuleBobbleheads/ Adds a few bobbleheads
-- 
--     ModuleCoworker/    Gives the Coworker a tiered reward system based on food quality
-- 
--     (GAMEPLAY[])       Other adjustables
--
-- =======================================================================
-- 
--   DEV TOOLS - stripped by _Export-AnteUp2
--     AnDebug/              Adds debug keybinds, chat commands, and other debug tools
--
--     AnTest/               The /at test suites (roster, waves, soak, churn, ...). Required only
--                           from the /at chat command, so stripping it leaves nothing dangling
--
--     ModuleCheats/         Adds some additional cheat commands for testing or convenience.
--                           Ships, off: chat cheats need DEBUG_CHEATS + DEBUG_CHAT_COMMANDS;
--                           the console ones (single player) need only DEBUG_CONSOLE_CHEATS
--
--     ModuleNpcHighlighter/ Absorbed the NpcHighlighter mod. /npch to enable
--
--     ModuleCinematic/      Staging tools for recording video: hold NPCs still, revert a
--                           variant to its vanilla body and mutate it again on camera.
--                           Keybind groups (90)/(91), or /au-cine
-- =======================================================================




---@diagnostic disable: undefined-global, undefined-field, lowercase-global

require("UEHelpers")
local AFUtils = require("AFUtils.AFUtils")

require("AFUtils.AFBase")
require("AFUtils.BaseUtils.BaseUtils")
require("AFUtils.BaseUtils.MathUtils")
require("AFUtils.BaseUtils.FNames")
require("AFUtils.BaseUtils.LinearColors")
require("AFUtils.BaseUtils.DefaultObjects")
require("AFUtils.BaseUtils.StaticClasses")

-- Game-build switch, before any module that captures a struct field name at file scope.
local SCHEMA = require("AnteData.Schema")

local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")

-- SETTINGS BACK-COMPAT. Player settings have been reorganised more than once, and a user who
-- kept an older SETTINGS.lua must not silently lose the knob they actually edited (a dropped
-- HearingRange just makes HoistHearing(nil) return). Surviving old keys fold forward and the
-- OLD value wins. This has to run before the module requires below - several read their gate
-- at file scope.
do
    local M   = SETTINGS.MODULES or {}
    local OLD = M.GAMEPLAY or {}                       -- GAMEPLAY's previous home
    local G, C = SETTINGS.GAMEPLAY, SETTINGS.CORE
    SETTINGS.MODULES = M
    SETTINGS.MOD_COMPATIBILITY = SETTINGS.MOD_COMPATIBILITY or {}
    M.HARDMODE = M.HARDMODE or {}                      -- an older file must read "all off", not throw
    M.FARMING  = M.FARMING or {}

    local function keep(dst, key, old) if old ~= nil then dst[key] = old end end

    -- Loose keys that joined GAMEPLAY / MOD_COMPATIBILITY / CORE
    keep(G, "REDUCE_VISUALS",          SETTINGS.REDUCE_VISUALS)
    keep(G, "CLIENT_LASER_COLOR",      SETTINGS.FORCE_LASER_COLOR)
    keep(G, "FORCE_SAVE_MINUTES",      SETTINGS.FORCE_SAVE_MINUTES)
    keep(G, "MODULE_REVENGE_ASSAULTS", M.REVENGE_ASSAULTS)
    keep(G, "MODULE_SHADOWBOSS",       M.ENABLE_SHADOWBOSS)
    keep(G, "SpawnRange",              OLD.SpawnRange)
    keep(SETTINGS.MOD_COMPATIBILITY, "ENEMY_AT_THE_GATE", M.ENABLE_GATE_BRIDGE)
    -- ItemModifications became the top-level ITEM_TWEAKS. It has had two earlier homes.
    keep(SETTINGS, "ITEM_TWEAKS",      G.ItemModifications or OLD.ItemModifications)
    keep(G, "FragGrenade_Brighter",    SETTINGS.ITEM_TWEAKS and SETTINGS.ITEM_TWEAKS.FragGrenade_Brighter)
    for _, k in ipairs({ "EARLY_SPAWNER_CONFIG", "WORKQUEUE_MAX_PER_TICK", "BLIZZARD_HOST_ZONE",
                         "ASSET_KEEPER", "CLASS_PINS" }) do
        keep(C, k, SETTINGS[k])
    end

    -- The perception knobs used to be loose in MODULES.GAMEPLAY / MODULES.ANTEPETS (and briefly
    -- in a top-level MODULES.AI_SENSE) before becoming one AI_SENSE table.
    local dst = G.AI_SENSE
    local moved = {
        [OLD.AI_SENSE or {}] = { "HearingRange", "StinkyRange", "Eyesight", "MinLightLevel",
                                 "EngineSightChecksPerFrame", "PetEyesight", "PetVisionDegrees",
                                 "PetSightRadius" },
        [M.AI_SENSE or {}]   = { "HearingRange", "StinkyRange", "Eyesight", "MinLightLevel",
                                 "EngineSightChecksPerFrame", "PetEyesight", "PetVisionDegrees",
                                 "PetSightRadius" },
        [OLD]                = { "HearingRange", "StinkyRange", "Eyesight" },
        [M.ANTEPETS or {}]   = { "PetEyesight", "PetVisionDegrees", "PetSightRadius" },
    }
    for src, keys in pairs(moved) do
        if src ~= dst then
            for _, k in ipairs(keys) do
                if src[k] ~= nil then dst[k] = src[k] end
            end
        end
    end
end

-- TRADERS ARE LEGACY-LAYOUT ONLY. The trader shop is driven by DT_NPC_TraderItems, and those rows
-- do not survive the native-layout migration - a trader arrives with nothing to sell.
-- Forced off here rather than at each gate, so every SETTINGS.MODULES.TRADERS.* reader (the
-- director, the mirror, the shop UI, the soda-machine items, the coworker bonus) folds at once
-- and a player's own SETTINGS.lua still works unchanged on the older layout.
-- Reinstating them needs the rows rebuilt in the Unreal editor, not more Lua.
if SCHEMA.Native then
    local T = SETTINGS.MODULES.TRADERS
    for k, v in pairs(T or {}) do
        if type(v) == "boolean" then T[k] = false end   -- every flag, including ones added later
    end
end

local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local ASSETS = require("AnteCore.AssetManager")
local TickManager = require("AnteCore.TickManager")
local SpawnerHooks = require("AnteVariants.SpawnerHooks")
local CombatHooks = require("AnteVariants.CombatHooks")
local StoryManager = require("ModuleStory.StoryManager")
local PetManager = require("ModulePets.PetManager")
local PetHarvest = require("ModulePets.PetHarvest")
local PetFeeding = require("ModulePets.PetFeeding")
local SystemHooks = require("AnteCore.SystemHooks")
local AssetKeeper = require("AnteCore.AssetKeeper")
local AudioFix = require("ModuleAudioFix.AudioFix")
local ClientVisuals = require("AnteVariants.ClientVisuals")
local ClientEffects = require("AnteVariants.ClientEffects")
local ClientProjectiles = require("AnteVariants.ClientProjectiles")
local VersionCheck = require("AnteCore.VersionCheck")
local SCT = require("ModuleSCT.SCT")
local JournalHooks = require("ModuleJournal.JournalHooks")
local Profiler = require("AnDebug.Profiler")
local Keybinds = require("AnDebug.Keybinds")
local ChatCommands = require("AnDebug.ChatCommands")
local Cheats = require("ModuleCheats.Cheats")
local ConsoleCheats = require("ModuleCheats.ConsoleCheats")
local NpcHighlighter = require("ModuleNpcHighlighter.NpcHighlighter")
local Cinematic = require("ModuleCinematic.Cinematic")
local DebugUtils = require("AnDebug.DebugUtils")
local CustomItems = require("ModuleItems.CustomItems")
local ProjectileRows = require("AnteCore.ProjectileRows")
local Farming = require("ModuleFarming.Farming")
local CustomItemEffects = require("ModuleItems.CustomItemEffects")
local ItemMods = require("ModuleItems.ItemMods")
local ProjectileVisuals = require("ModuleItems.ProjectileVisuals")
local TraderShop = require("ModuleTraders.TraderShop")
local TraderMirror = require("ModuleTraders.TraderMirror")
local Coworker = require("ModuleCoworker.Coworker")
local GateBridge = require("ModuleGATE.GateBridge")
local Bobbleheads = require("ModuleBobbleheads.Bobbleheads")
local ShadowBoss = require("ModuleShadow.ShadowBoss")
local RevengeDirector = require("ModuleRevenge.RevengeDirector")
local HardMode = require("ModuleHardMode.HardMode")
local ElementalBalance = require("ModuleElemental.ElementalBalance")
local Director = require("ModuleDirector.Director")
-- (Winter lives in ModuleStory/Winter - Event_Dams_Ongoing_Winter, armed by StoryManager.Tick.)

local Log = Utils.Log

local MAIN = {}

-- The client ReceiveTick hook's UE4SS ids (set in MAIN.Start), so the AUTHORITY
-- can self-remove that hook once role is known (see MAIN.DropClientTickHook).
local clientTickHookIds = nil
local clientTickDropScheduled = false
-- True while a client-tick-hook retry loop is in flight (see registerHookWithRetry).
--   * Guards against stacking a second loop if registerClientTickHook is called
--     again before the first resolves.
local clientTickHookPending = false

-- Init-trigger hooks - fire once the world is stable; clients can't see most
-- hooks, so each role gets its own trigger.
--   * Authority: GameState's UpdateNPCDebugInfo - a server-side 1s timer
--     that runs even with no players, so dedicated servers init too.
--   * Client: the local player character's ReceiveTick - the GameState
--     debug timer and the AI Director (ProcessSpawns_Quick) are both
--     server-only, so a client has no other reliable "world running" tick.
local HOOK_SERVER_TICK = "/Game/Blueprints/Meta/Abiotic_Survival_GameState.Abiotic_Survival_GameState_C:UpdateNPCDebugInfo"
local HOOK_CLIENT_TICK = "/Game/Blueprints/Characters/Abiotic_PlayerCharacter.Abiotic_PlayerCharacter_C:ReceiveTick"
-- Authority world-teardown signal.
--   * The GameState has no EndPlay UFunction; the (server-only) GameMode does.
--   * It fires while the old world is tearing down, BEFORE the engine GC-checks
--     it, so StopMod can release our references in time.
--   * Clients fall back to the cached-GameState check in TryInit.
local HOOK_WORLD_END = "/Game/Blueprints/Meta/Abiotic_Survival_GameMode.Abiotic_Survival_GameMode_C:ReceiveEndPlay"

-- Hook registration is RACE-PRONE: RegisterHook THROWS ("no UFunction with the
-- specified name was found") until the target /Game/ Blueprint class is loaded.
--   * On a slow machine the survival GameState (our authority init trigger) isn't
--     resident at the T+3s Start, so a single un-guarded RegisterHook that threw
--     used to abort the whole MAIN.Start and take the client fallback down with it
--     - leaving the mod totally inert ("works ~1/15 of launches").
--   * Fix: RETRY each hook independently until its UFunction resolves.
--     See registerHookWithRetry / MAIN.Start.
local HOOK_RETRY_DELAY_MS = 2000
local HOOK_RETRY_MAX = 60   -- ~2 min of attempts before giving up with a very loud log


-- The client ReceiveTick callback: bootstraps client init AND drives the client
-- WorkQueue drain (TickManager.ClientTick). Extracted so MAIN.Start and
-- MAIN.StopMod share one body.
--   * On the AUTHORITY (host/SP) this hook is REDUNDANT (the server tick drives
--     init + drain) and DANGEROUS to keep: another mod (NPCHighlighter) hooks this
--     exact UFunction, and a hot-reload teardown while a pawn ticks rewrites the
--     shared trampoline -> access violation. So the authority self-drops it once
--     role is known (MAIN.DropClientTickHook).
--   * A real CLIENT KEEPS it - it's the client's ONLY "world running" tick (the
--     server debug timer + AI Director are server-only).
--   * See [[anteup2-shared-hook-teardown]].
--   * ReceiveTick fires once per PLAYER PAWN, not once per frame: a client with N players in view
--     ran the mod tick at N x 10/s. One pawn leads; another takes over only once the lead has
--     stopped ticking (its player left, died, or fell out of relevance).
local TICK_LEAD_HANDOFF_SEC = 1.0
local tickLeadAddr, tickLeadSeen = nil, 0

local function isTickLead(self)
    local pawn = self and self:get()
    local addr = pawn and pawn:GetAddress()
    if not addr then return false end
    local now = os.clock()
    if addr ~= tickLeadAddr then
        if tickLeadAddr and (now - tickLeadSeen) < TICK_LEAD_HANDOFF_SEC then return false end
        tickLeadAddr = addr
    end
    tickLeadSeen = now
    return true
end

local function clientTickBody(self, DeltaSeconds)
    if not isTickLead(self) then return end
    local dt = DeltaSeconds and DeltaSeconds:get() or 0
    -- Frame-time sampling for the microlag profiler (no-op unless DEBUG_PROFILE).
    --   * The engine's own DeltaSeconds captures a stalled frame retroactively
    --     (the tick AFTER a 300ms hitch arrives with dt=0.3), so this sees stalls
    --     our Lua slept through (blocking loads included).
    Profiler.FrameSample(dt)
    MAIN.TryInit()
    if STATE.ModInitCalled and Utils.IsAuthority() then
        -- While profiling, the authority KEEPS this hook - it's the only per-frame
        --   callback we have; without it there is no hitch detection on host/SP.
        -- Tradeoff: re-opens the shared-hook hot-reload hazard (see below), so
        --   DEBUG_PROFILE is a diagnostic lever, not a shipping default.
        if not Profiler.Enabled then MAIN.DropClientTickHook() end
        return
    end
    TickManager.ClientTick(dt)
end

-- Try to register a hook by name, retrying until its UFunction resolves.
--   * RegisterHook RAISES a Lua error when the target /Game/ Blueprint class isn't
--     loaded yet, so the call is pcall-wrapped and NEVER allowed to escape
--     (a throw here must not abort the caller).
--   * EVERY ATTEMPT HOPS TO THE GAME THREAD. RegisterHook resolves its target with a
--     StaticFindObject, and the engine makes that call FATAL when it lands while the game
--     thread is collecting garbage ("Illegal call to StaticFindObject() while serializing
--     object data or garbage collecting"). On a UE4SS without ExecuteInGameThreadWithDelay,
--     MAIN.Start and the retry timer run on a worker thread - the one thread that can race a
--     map-load GC - so the lookup itself always runs in ExecuteInGameThread.
--   * PURE Lua only in the retry body (no actor/BP calls - CLAUDE.md 2).
--   * onSuccess(preId, postId) - OPTIONAL, called once when the hook takes.
--   * onGiveUp()               - OPTIONAL, called if we exhaust HOOK_RETRY_MAX attempts.
local function registerHookWithRetry(label, hookName, callback, onSuccess, onGiveUp, attempt)
    attempt = attempt or 1
    ExecuteInGameThread(function()
        local ok, preId, postId = pcall(RegisterHook, hookName, callback)
        if ok and preId ~= nil then
            Log(string.format("AnteUp2 - %s hook registered (attempt %d)", label, attempt))
            if onSuccess then pcall(onSuccess, preId, postId) end
            return
        end

        -- ok=false -> RegisterHook threw (UFunction not found); ok=true,preId=nil -> odd no-id return.
        local reason = ok and "RegisterHook returned no id" or tostring(preId)

        if attempt >= HOOK_RETRY_MAX then
            -- Very loud, greppable give-up banner: this is the "the mod will not run" signal.
            Utils.LogBad("################################################################")
            Utils.LogBad(string.format(
                "#### AnteUp2 FATAL: '%s' hook FAILED after %d attempts (~%ds).",
                label, attempt, math.floor(attempt * HOOK_RETRY_DELAY_MS / 1000)))
            Utils.LogBad("#### Function : " .. hookName)
            Utils.LogBad("#### LastError: " .. reason)
            Utils.LogBad("#### => The mod could NOT arm this init trigger and will not run.")
            Utils.LogBad("####    The Blueprint class never loaded - likely an OLD/INCOMPATIBLE")
            Utils.LogBad("####    or non-Steam game build. Check your game version + install path.")
            Utils.LogBad("################################################################")
            if onGiveUp then pcall(onGiveUp) end
            return
        end

        Log(string.format("AnteUp2 - %s hook not ready (attempt %d/%d: %s); retrying in %dms",
            label, attempt, HOOK_RETRY_MAX, reason, HOOK_RETRY_DELAY_MS))
        Utils.DelayedGameThread(HOOK_RETRY_DELAY_MS, function()
            registerHookWithRetry(label, hookName, callback, onSuccess, onGiveUp, attempt + 1)
        end)
    end)
end

-- [Start + StopMod] Register the client tick hook if absent (idempotent);
-- also clears clientTickDropScheduled so a future authority drop can re-arm.
--   * The StopMod call RESTORES the hook after an authority world so a subsequent
--     CLIENT join can init + drain (see MAIN.StopMod).
--   * Retries via registerHookWithRetry (Abiotic_PlayerCharacter_C may not be
--     loaded yet at the menu); clientTickHookPending stops a second concurrent loop.
local function registerClientTickHook()
    clientTickDropScheduled = false
    if clientTickHookIds or clientTickHookPending then return end
    clientTickHookPending = true
    registerHookWithRetry("client ReceiveTick", HOOK_CLIENT_TICK, clientTickBody,
        function(preId, postId)
            clientTickHookIds = { pre = preId, post = postId }
            clientTickHookPending = false
        end,
        function() clientTickHookPending = false end)   -- gave up: allow a later StopMod to re-try
end


-- ==========================================================
-- Start - register both init triggers (once per UE4SS session).
--   * Each calls the idempotent MAIN.TryInit; whichever fires for the current role wins.
--   * A hook that never fires for this role is simply inert.
-- ==========================================================
function MAIN.Start()

    -- Client bootstrap trigger + WorkQueue drain FIRST (the resilient fallback).
    --   * See clientTickBody / registerClientTickHook above for the full why
    --     (redundant + hot-reload-dangerous on the authority, so self-dropped there;
    --     essential and kept on a real CLIENT).
    --   * On a HOST this hook ALSO bootstraps init via the host's own player tick,
    --     so even a permanently-failing authority hook can't stop single-player/listen
    --     from running.
    registerClientTickHook()

    -- Authority init trigger.
    --   * registerHookWithRetry pcall-guards it and retries until the survival GameState
    --     Blueprint is loaded, so a slow machine that isn't in-world at this T+3s Start
    --     no longer throws-and-aborts (which used to kill the client fallback above too,
    --     leaving the mod inert on ~14/15 launches).
    --   * A DEDICATED server has no client fallback, so this retry is its only path in -
    --     hence the generous window + loud give-up log.
    registerHookWithRetry("authority GameState init", HOOK_SERVER_TICK,
        function() MAIN.TryInit() end)

    -- Farming plant rows BEFORE any world exists. A garden plot's restore reads its saved
    -- PlantItem row ONCE and returns silently if it is missing, so rows added at InitMod are too
    -- late on a cold process start and every custom plant is dropped. InitMod rebuilds them per
    -- world. Through ExecuteInGameThread for the same reason the hook retry above is: Start runs
    -- on a UE4SS worker thread on an older UE4SS, and the row lookups are StaticFindObject.
    ExecuteInGameThread(function()
        local okFarm, errFarm = pcall(Farming.BuildRows)
        if not okFarm then Utils.LogBad("Start - farming-row pre-build failed: " .. tostring(errFarm)) end
    end)

    Log("AnteUp2 - init triggers arming (retry-until-resolved)")
end

-- Drop our redundant client ReceiveTick hook on the authority (host/SP). One-shot.
--   * DEFERRED to a clean WorkQueue tick (ProcessSpawns_Quick) - we must never
--     unregister the hook chain from inside its own callback.
--   * Runs on the game thread, so it can't race a concurrent ReceiveTick invoke.
--   * See MAIN.Start for the why (shared-UFunction hot-reload teardown crash).
function MAIN.DropClientTickHook()
    if clientTickDropScheduled or not clientTickHookIds then return end
    clientTickDropScheduled = true
    local ids = clientTickHookIds
    Utils.QueueWork(function()
        local ok, err = pcall(function()
            UnregisterHook(HOOK_CLIENT_TICK, ids.pre, ids.post)
        end)
        clientTickHookIds = nil
        if ok then Log("AnteUp2 - client ReceiveTick hook dropped (authority)")
        else Utils.LogBad("AnteUp2 - client tick unregister failed: " .. tostring(err)) end
    end, 0)
end

-- Cheap guard runs every tick until the world is ready, then no-ops.
function MAIN.TryInit()
    -- Fallback teardown detection (esp. clients, which have no GameMode):
    --   * Our cached GameState going invalid means the old world tore down;
    --     clean up so the next world re-inits fresh.
    if STATE.ModInitCalled and IsNotValid(STATE.GameState) then
        MAIN.StopMod()
    end

    if STATE.ModInitCalled then return end

    local gameState = AFUtils.GetSurvivalGameState()
    if IsNotValid(gameState) then return end

    STATE.GameState = gameState
    MAIN.InitMod(gameState)
end


-- ==========================================================
-- InitMod - runs once per world, on the game thread
-- ==========================================================

function MAIN.InitMod(gameState)
    STATE.ModInitCalled = true

    local role = Utils.DetectRole()
    Log("InitMod - role: " .. role)
    pcall(Utils.SoftRefsSafe)   -- decides once, and puts the UE4SS build into every log
    pcall(Utils.RowApiSafe)     -- the hard DataTable-row gate, by build number (the probe below defers to it)
    pcall(SCHEMA.Verify)        -- once: confirms the game-build layout on the game thread, logs it

    -- Session-type switch WITHOUT a relaunch (e.g. SP/host -> exit to menu -> join a server).
    --   * UE4SS registers hooks/keybinds once per launch; we re-link what we can (StopMod
    --     restores the client tick hook), but warn the player to relaunch if anything's
    --     still missing.
    --   * A mere in-session zone transition keeps the same role, so this stays quiet then.
    local roleSwitched = STATE.LastInitRole ~= nil and STATE.LastInitRole ~= role
    STATE.LastInitRole = role

    if gameState.WorldSaveName then
        STATE.WorldName = gameState.WorldSaveName:ToString()
    end

    -- Custom items (ALL roles, EVERY world init): clone the custom item rows.
    --   * AddRow from a donor row + scalar tuning - the only safe recipe.
    --   * Every role needs the rows resident so replicated items/trades resolve.
    --   * MUST re-run every world, NOT once/session: runtime-added rows do not reliably
    --     survive a world/zone transition (the item-table asset can reload), and a saved
    --     inventory item stores only its ROW NAME + re-resolves its data LIVE from the table.
    --   * If the row is missing in a world, that item becomes an invisible dud slot that
    --     blocks placement; re-adding the row (idempotent - per item: FindRow-exists -> skip)
    --     lets the game re-resolve it on next draw.
    --   * ModuleBobbleheads injects its own rows into CustomItems.CUSTOM_ITEMS first, so Apply
    --     builds them in the same pass. They have their OWN switch (MODULES.BOBBLEHEADS), so
    --     either half can be turned off alone if a UE4SS build breaks it.
    -- UE4SS DataTable gate (decided once/session). The in-place row API every row feature needs
    -- (FindRow returning a live row, AddRow cloning one) arrived at UE4SS v3.0.1-593; before it
    -- FindRow hands back a Lua COPY. Utils.RowApiSafe decides by build number and ASSETS'
    -- capability probe covers unlisted builds. Off = ASSETS.GetDataTable reads nil everywhere and
    -- every DataTable feature detects itself OFF - warn ONCE so a degraded install reads as "old
    -- UE4SS", not as mysteriously bald traders and missing sodas. ItemTable_Global is Immortal
    -- (game-hard-refd), so it is resident by InitMod - no `load` needed.
    ASSETS.GetDataTable("/Game/Blueprints/Items/ItemTable_Global.ItemTable_Global")
    if STATE.HasDataTableApi == false and not STATE.OldUE4SSWarned then
        STATE.OldUE4SSWarned = true
        local n = Utils.UE4SSBuildNumber()
        Utils.LogBad("AnteUp2 - this UE4SS build" .. (n and (" (v3.0.1-" .. n .. ")") or "")
            .. " lacks the DataTable row API (v3.0.1-593 or newer). Trader shop, custom items, "
            .. "bobblehead items, custom projectile rows and weapon retunes are DISABLED; "
            .. "NPC variants still run. On someone else's server, some variant projectiles will "
            .. "be INVISIBLE to you unless that server sets CORE.CUSTOM_PROJECTILE_ROWS = false. "
            .. "Update UE4SS to v3.0.1-1012.")
    end

    -- pcall'd: STATE.ModInitCalled is already latched, so an error escaping here would
    -- kill InitMod mid-run and leave the WHOLE mod (variants included) silently dead for
    -- the session. An old UE4SS's member-access semantics are unpredictable (nil / throw /
    -- return-self); the row work must degrade to a logged failure, never an abort.
    local okItems, errItems = pcall(function()
        Bobbleheads.RegisterItems()   -- self-gated on MODULES.BOBBLEHEADS
        local traderItems = SETTINGS.MODULES.TRADERS.CustomItems and true or false
        if traderItems or SETTINGS.MODULES.BOBBLEHEADS ~= false then
            CustomItems.Apply({ TraderItems = traderItems })
        end
    end)
    if not okItems then Utils.LogBad("InitMod - custom-item setup failed: " .. tostring(errItems)) end

    -- Custom DT_Projectiles rows (ALL roles, every world - a client builds its copy of a shot
    -- from the same row handle). Same capability gate and the same reason for the pcall as the
    -- item rows above; a row that fails just leaves its variant on the scripted shot.
    local okRows, errRows = pcall(ProjectileRows.Apply)
    if not okRows then Utils.LogBad("InitMod - projectile-row setup failed: " .. tostring(errRows)) end
    -- ...and the authority half: rows whose shots must never hit their own shooter.
    local okIgn, errIgn = pcall(ProjectileRows.ArmShooterIgnore)
    if not okIgn then Utils.LogBad("InitMod - shooter-ignore setup failed: " .. tostring(errIgn)) end

    -- Weapon retune rows (SETTINGS.ITEM_TWEAKS, ALL roles, every world): a hitscan gun's cadence,
    -- spread and range are read on the SHOOTER's machine, so a client needs the edit as much as
    -- the server. ItemMods.Register arms the authority half further down.
    local okWeap, errWeap = pcall(ItemMods.ApplyWeaponRows)
    if not okWeap then Utils.LogBad("InitMod - weapon-row setup failed: " .. tostring(errWeap)) end
    -- Gear rows, same roles and cadence: the watch tooltip reads the row on a client too.
    local okGear, errGear = pcall(ItemMods.ApplyGearRows)
    if not okGear then Utils.LogBad("InitMod - gear-row setup failed: " .. tostring(errGear)) end
    -- Chemistry bench speed + input size: the server runs the benches, a client draws their
    -- progress % and "add" prompt from the same two fields.
    local okChem, errChem = pcall(ItemMods.ArmChemistry)
    if not okChem then Utils.LogBad("InitMod - chemistry setup failed: " .. tostring(errChem)) end

    -- Apple-tree farming rows (SETTINGS.MODULES.FARMING, ALL roles, every world): a client rebuilds
    -- the plant proxy's mesh from the same plant row, so it needs the rows as much as the server.
    -- Self-gated on the setting and on the row API; same pcall reasoning as the rows above.
    local okFarm, errFarm = pcall(Farming.Apply)
    if not okFarm then Utils.LogBad("InitMod - farming-row setup failed: " .. tostring(errFarm)) end

    -- Tamed Hive Sow milk recolor (ALL roles, once/session).
    --   * The native udder harvest re-inits the mesh and wipes our tint; this hook
    --     re-applies it (any renderer) + drops honey/wax (authority).
    --   * Multicast_PlayHarvestSound fires on every machine, so register regardless of role.
    require("AnteNPCs.PeccarySowHelpers").RegisterMilkHook()

    -- Server/Host
    if Utils.IsAuthority() then
        -- Custom-soda DRINK effects (authority). Arm the consume hook EVERY world.
        --   * It used to arm only when a soda machine spawned (TraderShop.SetupTrades),
        --     so on a fresh load / mod restart, drinking a soda you already owned
        --     silently did nothing until a machine appeared.
        --   * Arm() force-loads the consumable class first (the UFunction won't resolve
        --     otherwise) and is idempotent.
        if SETTINGS.MODULES.TRADERS.CustomItems then CustomItemEffects.Arm() end

        if not STATE.ServerHooksRegistered then
            SpawnerHooks.Register()
            CombatHooks.Register()
            SystemHooks.Register()
            TickManager.RegisterServer()

            -- Perception: hoist every NPC's hearing off its pitiful native 750uu, and widen
            -- the smell the Stinky debuff already emits. Both are once-per-session and
            -- self-guarded; both no-op when their SETTINGS knob is 0/nil.
            --   * Hearing is the ONE event-driven sense (sight is a 0.5s poll), so this is
            --     also the groundwork for AVU.ReportNoise. See AnNotes/AnteSystems/NPCPerception.md.
            --   * The NotifyOnNewObject inside HoistHearing can never be unregistered, hence
            --     once per SESSION. Its companion sweep is re-armed per WORLD below.
            AVU.HoistHearing(SETTINGS.GAMEPLAY.AI_SENSE.HearingRange)
            AVU.RegisterStinkyNoise()


            -- World teardown (authority, pre-GC): release our retained refs so the
            --   old world can be collected.
            --   * Registered here (not Start) so the GameMode class is loaded;
            --     pcall'd so a missing UFunction is inert.
            local okEnd = pcall(RegisterHook, HOOK_WORLD_END, function()
                if STATE.ModEnabled then MAIN.StopMod() end
            end)
            Log("AnteUp2 - world-end hook " .. (okEnd and "registered" or "UNAVAILABLE"))

            STATE.ServerHooksRegistered = true
        end

        -- Hearing top-up: re-armed EVERY world, unlike the hoist above.
        --   * StopMod drops the WorkQueue, which kills the in-flight timer, so a once-per-session
        --     arm would leave the loop permanently dead after the first zone transition.
        --   * Generation-guarded, so re-arming supersedes rather than stacking a second loop.
        AVU.StartHearingSweep(SETTINGS.GAMEPLAY.AI_SENSE.HearingRange)

        -- Both PER WORLD, for the same reason as the sweep above (StopMod drops the WorkQueue, and
        -- the sight sense object belongs to the world's perception system).
        --   * The light floor is what lets an NPC see a player at all outside a lit room - it
        --     floors CurrentLightValue, the value the spot meter multiplies by. POLLED, not hooked:
        --     the Timer_ComputeLightValue hook registered fine and never fired (see AVSenses).
        --   * The trace budget is stage 1 - the engine only runs MaxTracesPerTick sight checks per
        --     FRAME for the whole level, stock 6, which is the 5-20s "staring through you" delay.
        AVU.StartLightFloor(SETTINGS.GAMEPLAY.AI_SENSE.MinLightLevel)
        AVU.SetSightBudget(SETTINGS.GAMEPLAY.AI_SENSE.EngineSightChecksPerFrame)

        if not STATE.DebugRegistered then
            if SETTINGS.DEBUG_SHOW_SPAWNERS then DebugUtils.RegisterSpawnerDebug() end
            -- Hook probe (DEV): "does this UFunction hook, and does it ever FIRE?"
            --   * Sits with the other server hooks because its candidates are BP classes
            --     that only resolve once a world is up.
            --   * Self-guards on SETTINGS.DEBUG_HOOK_PROBE + its own armed flag.
            pcall(function() require("AnDebug.HookProbe").Register() end)
            STATE.DebugRegistered = true
        end
        
        -- Story-event heartbeat (Order Ambush + BigBot bridge spawner).
        --   * Idempotent (self-guards via STATE.StoryArmed; re-arms each world load
        --     after ResetState).
        --   * Runs FIRST so FileIO.LoadStoryData has populated STATE.StoryData (incl. the
        --     persisted Count-spawner wipe cooldowns) before ApplySpawnOverrides configures
        --     the already-live spawners and seeds their cooldown state from it.
        StoryManager.Register()

        -- Pet manager: re-applies AnteUp2 variant identities to NATIVE tamed pets (poll).
        --   * Idempotent (self-guards via STATE.PetManagerArmed; re-arms each world
        --     after ResetState).
        --   * After StoryManager so FileIO.LoadStoryData has populated STATE.StoryData.Pets first.
        PetManager.Register()

        -- Bigger tamed-animal harvests (ANTEPETS.SowMilk / MushroomPeccaryYield) and the feed-XP
        -- top-up's food snapshots (ANTEPETS.FeedXpBonus). Both self-gate (setting + authority); hooks
        -- arm once per session, per-world tables reset here.
        PetHarvest.Register()
        PetFeeding.Register()

        -- DarkLens arena watcher (Fracture Chieftain boss set, AnteNPCs/GK_DarkLens):
        -- adopts the game-spawned DarkLens_Chieftain (its spawner's coords aren't in
        -- SpawnerData) + forces aggro when a player is close (the AISense-bugginess fix).
        --   * Idempotent (STATE.DarkLensArmed; re-arms each world load after ResetState).
        pcall(function() require("AnteNPCs.GK_DarkLensPatriarchHelpers").Register() end)

        -- Same for the DarkLens WITCH arena (Mother of the Fallow). Her SpawnerData row is the
        -- primary path; this is the fallback that adopts a body already standing in the world.
        --   * Idempotent (STATE.DarkLensWitchArmed; re-arms each world load after ResetState).
        pcall(function() require("AnteNPCs.GK_DarkLensWitchHelpers").Register() end)

        -- Same for the DarkLens HEAVY arena (Jotun of the Fallow + its Fallow Steed).
        --   * Idempotent (STATE.DarkLensJotunArmed; re-arms each world load after ResetState).
        --   * Must be AFTER StoryManager: JotunStats reads STATE.StoryData.FallowJotunDismounted
        --     to decide which phase a re-adopted boss comes back in, and FileIO populates that.
        pcall(function() require("AnteNPCs.GK_DarkLensJotunHelpers").Register() end)

        -- Same for the DarkLens MAGE arena (Magus of the Fallow). Its watcher refuses to force
        -- aggro while the native seal is up (CFG.CanForceAggro), and its "death flag" is
        -- Residence_Fracture_Complete - the Mage has none of its own.
        --   * Idempotent (STATE.DarkLensMageArmed; re-arms each world load after ResetState).
        pcall(function() require("AnteNPCs.GK_DarkLensMageHelpers").Register() end)

        -- One-time pet-run starter pack (SETTINGS.MODULES.ANTEPETS.StarterPack):
        --   a deployed trap + bed + starting consumables, once per world (latched in StoryData).
        --   * Fully self-gating (authority + setting + flag); harmless to call every world load.
        PetManager.CreateStarterPack()

        -- Coworker feed rewards (hunger+story tiered drops; hook arms on first night sighting).
        Coworker.Register()

        -- EnemyAtTheGATE bridge: publishes our variant->base map and mutates the
        --   assault NPCs EATG's wave lists asked for.
        --   * Self-gates (setting + authority + once/session); inert when EATG isn't
        --     installed. See ModuleGATE/GateBridge.
        GateBridge.Register()

        -- Final boss (The Shadow): adopts the island's VignetteDirector, tunes the per-phase boss,
        --   owns the portal-storm clock + extra spawns. Inert off the island (director never seen).
        --   * Idempotent (STATE.ShadowBossArmed; re-arms each world load after ResetState).
        ShadowBoss.Register()

        -- Revenge assaults: books a real assault a night or two after a story beat, and fills its
        --   waves with Antevariants. Self-gates (setting + authority); the CALENDAR itself is
        --   ticked from StoryManager.Tick. See ModuleRevenge/RevengeDirector.
        RevengeDirector.Register()

        -- Native item/weapon tweaks (SETTINGS.ITEM_TWEAKS). Self-gates per-mod +
        -- once-per-session; harmless to call every world (arms the BioCannon heal hook, etc.).
        ItemMods.Register()

        -- A pot of soup that wasn't cooked (Hank's soup_pepper) places as itself instead of the
        -- game's Pest Goulash fallback. Always on: it only touches pots with no ingredient list.
        pcall(function() require("ModuleItems.SoupPots").Register() end)

        -- Hard-mode toggles (SETTINGS.MODULES.HARDMODE). Self-gates per-flag + authority;
        -- hooks arm once/session, per-world state (STATE.HardModeTypeScale, deployable
        -- re-tune) re-applies here. Flags are read at WORLD LOAD - no mid-session toggle.
        HardMode.Register()

        -- Elemental weapon rebalance (SETTINGS.MODULES.ElementalBalance). Self-gates on the
        -- setting; idempotent absolute writes, re-applied here because the item DataTable can
        -- reload across worlds and every equip spawns a fresh weapon actor. Not authority-only:
        -- the item row it edits also feeds the client's tooltip.
        ElementalBalance.Register()

        -- Director (SETTINGS.MODULES.DIRECTOR): small packs spawned out of sight of players who are
        -- out in the world. Self-gates (setting + authority); idempotent (STATE.DirectorArmed,
        -- re-arms each world load after ResetState). Rules: ModuleDirector/DirectorRules.
        Director.Register()

        -- (Ambient winter whiteouts: armed story-gated by StoryManager.Tick -> Winter.GateTick.)

        -- Spawner config normally applies on Spawner:ReceiveBeginPlay (e.g. SpawnAs);
        --   this covers spawners that began before our mod started.
        SpawnerHooks.ApplySpawnOverrides()

        -- A host's native-gun shots on one of our rows (PR.LOOKS `Native`) - nothing else dresses
        -- them there. Self-gates on a renderer, so a dedicated server skips it.
        ClientProjectiles.Register()

    -- Client (the WorkQueue is drained by the ReceiveTick hook in MAIN.Start,
    -- NOT an ExecuteInGameThread loop - see TickManager.ClientTick)
    else
        ClientVisuals.Register()
        -- Our scripted shots' trails, hidden meshes and sizes are runtime component work the
        -- server cannot replicate; a client dresses its own copy off the shot's row.
        ClientProjectiles.Register()
        -- Costumed traders look like bare humans on clients (attaches don't replicate) -
        -- re-apply the skin + arrival sounds locally. ModuleTraders/TraderMirror.
        TraderMirror.Register()
        -- def.PetScaleMult on CLIENTS: mesh scale doesn't replicate, so a joined player
        --   must re-scale their own copy of a pet on the pet system's UpdateMeshScale
        --   (else it renders native size).
        --   * Self-gates on ANTEPETS.Enabled; the handler identifies the pet via the
        --     replicated VariantTag.
        PetManager.RegisterMeshScaleHook()

        -- DarkLens arena PROP guard, client half. The authority arms this inside each fight's
        --   Register() above, but `CanBePackaged` does not replicate and the dismantle prompt is
        --   decided on the machine that DRAWS it - so a joined player needs their own pass or the
        --   Chieftain's arena is still packable from their side. See GK_DarkLensHelpers' ARENA
        --   PROPS section; the hook half stays server-only (BT_CheckObstruction is AI).
        --   * The SAME Register() the authority branch calls: its watcher half self-gates on
        --     Utils.IsAuthority(), so on a client this arms the prop sweep and nothing else.
        --   * Idempotent (STATE.DarkLensArmedProps; re-arms each world load after ResetState).
        pcall(function() require("AnteNPCs.GK_DarkLensPatriarchHelpers").Register() end)
    end

    -- UI hooks (journal/compendium) - ANY RENDERER (host / single-player / pure
    -- CLIENT); a dedicated server has no journal UI so it's skipped.
    --   * HISTORY: this was HOST/SP-only because it crashed pure clients (2026-06-14)
    --     in the Slate paint path (FSlateApplication::Tick -> UUserWidget::NativeTick
    --     -> UE4SS.dll, access violation).
    --   * The cause was NOT the journal hook (it only SetText's a compendium textblock)
    --     - it was the CLIENT draining its WorkQueue via ExecuteInGameThread, which
    --     flushed queued component work (AddComponentByClass) mid widget-paint.
    --   * That drain loop is GONE: the client now drains via the player ReceiveTick
    --     hook (a clean gameplay tick - TickManager.ClientTick) and its component work
    --     no longer uses EIGT, so the widget hook is safe on clients.
    --   * The only client EIGT left is asset LoadAsync - not component work, and
    --     already running during normal play.
    if Utils.HasRenderer() and not STATE.RenderHooksRegistered then
        JournalHooks.Register()
        -- Custom-trader trade-window text overrides (renderer-side 500ms poll,
        --   ModuleTraders/TraderShop): soda entry text + the per-trader window title
        --   (Hank, soda machine).
        --   * Armed for TRADERS.Enabled - Hank's title needs it even when CustomItems
        --     is off (it's not a soda-only feature anymore).
        if SETTINGS.MODULES.TRADERS.Enabled then TraderShop.RegisterUI() end
        -- Feed a pet without evicting it from its bed (ANTEPETS.BreakfastInBed).
        --   * RENDERER, not authority: the bed's CanInteractWith_B override is a purely LOCAL
        --     prompt gate - the server runs InteractWith_B with no re-validation - so the hook
        --     goes on every machine that draws a prompt, and a dedicated server skips it.
        --   * Self-gates on the setting + once-per-session. See ModulePets/PetManager.
        PetManager.RegisterBreakfastInBed()
        -- Brighter frag-grenade ground light (GAMEPLAY.FragGrenade_Brighter).
        --   * RENDERER, not authority: a PointLightComponent property doesn't replicate, so every
        --     machine has to write its own copy. Self-gates on the setting + once-per-session.
        --     See ModuleItems/ProjectileVisuals.
        ProjectileVisuals.Register()
        STATE.RenderHooksRegistered = true
    end

    -- Debug keybinds - any machine with input (HOST + CLIENT, not dedicated).
    --   * On a client the summon binds send a "/spawn" chat command instead of
    --     spawning directly (see AnDebug/Keybinds).
    --   * RegisterKeyBind is input, not a widget UFunction hook, so it doesn't add
    --     the UMG-tick interception that crashed JournalHooks on clients.
    if Utils.HasRenderer() and SETTINGS.DEBUG_KEYBINDS and not STATE.KeybindsRegistered then
        Keybinds.Register()
        STATE.KeybindsRegistered = true
    end

    -- Cinematic staging (keybind groups (90)/(91), /au-cine). Called EVERY world, unlike the
    -- keybinds above: all Register does is drop last world's staging records, whose ActorKey
    -- strings a new world can re-issue onto bodies we never touched.
    if SETTINGS.DEBUG_KEYBINDS or SETTINGS.DEBUG_CHEATS then
        Cinematic.Register()
    end

    -- Chat commands - EVERY role, unlike everything else here.
    --   * handleChat splits: the authority runs the server commands (/spawn, /clear...), a
    --     renderer runs the LOCAL ones (/instantfishing, which can only be armed where the
    --     player actually is).
    --   * A joined client never sees its own line (the send is a server RPC), so the server
    --     hands a LOCAL line back to it over the NetChannel (ChatCommands.ArmClientForward).
    --   * The hook is on a PlayerController UFunction (an actor, not a widget),
    --     so it's client-safe.
    if SETTINGS.DEBUG_CHAT_COMMANDS and not STATE.ChatCommandsRegistered then
        ChatCommands.Register()
        STATE.ChatCommandsRegistered = true
    end
    -- A joined client never sees its own chat line (the send is a server RPC), so the test suites'
    -- client halves arrive from the server over the NetChannel. Per world; dev-only (AnTest is stripped
    -- at export, hence the pcall).
    if SETTINGS.DEBUG_CHAT_COMMANDS and not Utils.IsAuthority() then
        pcall(ChatCommands.ArmClientForward)
        pcall(function() require("AnTest.Runner").ArmClientReceiver() end)
    end

    -- ModuleCheats (SETTINGS.DEBUG_CHEATS) - our versions of cheats that are broken elsewhere.
    --   * Register() only arms the FISHING rod hook: RENDERER-only (the minigame is
    --     entirely client-side, so a dedicated server never runs it) and OFF until
    --     each player toggles it for themselves.
    --   * The other cheats (/au-trapleyak, /topup) are authority chat commands and
    --     need no arming - ChatCommands calls straight into them.
    if SETTINGS.DEBUG_CHEATS then
        Cheats.Register()

        -- NPC highlighter (/npch): renderer-local outlines on nearby NPCs/allies/players.
        --   * Called EVERY world (not once/session): its scan poll rides the WorkQueue and
        --     self-terminates on teardown, so this is what re-arms it in the next world.
        --   * Inert until the player runs /npch - a disarmed highlighter costs nothing.
        NpcHighlighter.Register()
    elseif SETTINGS.DEBUG_CONSOLE_CHEATS then
        Cheats.ResetWorld()   -- the console arms the fishing hook on first use instead
    end

    -- Containments the trap cheat filled never drain - but the drain rate isn't saved, so it is
    -- re-applied every world. Whatever the cheat flags are now: the mark lives in this save's
    -- StoryData. Authority-only, and a no-op for a save without one.
    pcall(Cheats.ArmEndlessContainments)

    -- Console cheats (SETTINGS.DEBUG_CONSOLE_CHEATS): the same cheats typed into the game console,
    -- single player only, needing no other debug flag. The handlers are session-wide; each refuses
    -- a world that isn't single player.
    if SETTINGS.DEBUG_CONSOLE_CHEATS and Utils.HasRenderer() and not STATE.ConsoleCheatsRegistered then
        ConsoleCheats.Register()
        STATE.ConsoleCheatsRegistered = true
    end


    STATE.ModEnabled = true
    Log("InitMod - ** mod ready ** (world: " .. STATE.WorldName .. ", AnteUp2 " .. VersionCheck.Label() .. ")")
    Log("AnteUP: My role is " .. STATE.Role)

    -- Build check, every role: the authority announces its version, and a client whose build
    -- differs gets a chat warning. Warn only - nothing is disabled.
    VersionCheck.Start()

    -- Floating damage numbers (SETTINGS.MODULES.ScrollingCombatText). Every role: an enabled host or
    -- server sends each player their numbers, and every renderer draws what it receives.
    SCT.Register()

    if Utils.HasRenderer() then
        Log("Owner has Renderer")
        -- Renderer-side local FX off replicated anchors (host/SP + pure clients).
        -- Fixes dedicated-client cosmetics the server can't replicate (Sow bees).
        ClientEffects.Register()

        -- Receivers for the /au-netprobe channel test; passive until the server sends a probe.
        if SETTINGS.DEBUG_CHAT_COMMANDS then require("AnDebug.NetProbe").RegisterReceivers() end

        -- Custom bobbleheads (SETTINGS.MODULES.BOBBLEHEADS) - PROTOTYPE. Renderer-side, on HOST
        --   as well as clients: a bobblehead's look is runtime component work and so doesn't
        --   replicate, and a save-restored one never passes through BB.Place on either machine.
        --   * A DEDICATED server arms it too, below this block - it owns the authority half.
        --   * Self-gates on the setting, and per role inside. Called EVERY world: its sweep rides the
        --     WorkQueue and dies on teardown, so this is what re-arms it. See
        --     ModuleBobbleheads/Bobbleheads.
        Bobbleheads.Register()
        AFUtils.DisplayTextChatMessage("AnteUp2 " .. VersionCheck.Label() .. " loaded (" .. role .. ")")

        -- EXPERIMENT (SETTINGS.CORE.ASSET_KEEPER): pin a curated hot-set of
        --   assets resident for this zone (hidden components on the local GameState).
        --   * Self-gates on the flag; loads async then pins on a clean drain. A dedicated server
        --     establishes its own set below.
        --   * Released in StopMod. See AnteCore/AssetKeeper.
        AssetKeeper.Establish()

        -- SETTINGS.CORE.VOICE_SOUNDCLASS_FIX: hand the game's unclassed voice waves the SoundClass
        --   they shipped without, so the volume sliders reach them. See ModuleAudioFix/AudioFix.
        AudioFix.Establish()

        -- Switched session type without relaunching (see roleSwitched above). Warn prominently,
        -- deferred so it isn't buried under the load spam. Drains via the (now-restored) tick.
        if roleSwitched then
            local warn = "** AnteUp2: session type changed without a restart. Features were re-linked, "
                .. "but if keybinds / client visuals / trader appearances are missing, FULLY CLOSE AND "
                .. "REOPEN the game - UE4SS mods only fully initialize once per launch. **"
            Log(warn)
            Utils.QueueWork(function() AFUtils.DisplayTextChatMessage(warn) end, 3000)
        end
    end

    -- A dedicated server has no renderer, but it owns the AUTHORITY half of the custom bobbleheads:
    -- the marker stamped onto a dropped item (the only thing that tells a client WHICH figure a
    -- placed one is) and the packaging retag. Without it every placed custom bobblehead is the
    -- donor class's Gate Scientist, on every machine. (A host arms it in the renderer block above.)
    if Utils.IsAuthority() and not Utils.HasRenderer() then Bobbleheads.Register() end

    -- ...and the KEEP set minus what only a renderer draws: the classes and debuff objects its own
    -- spawns and damage load, which a dedicated server otherwise cold-loads in its drain.
    if not Utils.HasRenderer() then AssetKeeper.Establish() end
end


-- ==========================================================
-- StopMod - the world is tearing down (zone transition / world travel / exit).
-- Triggered by the GameState ReceiveEndPlay hook.
--   * ResetState drops our strong references to old-world actors (OnTickActors /
--     WorkQueue closures) so the old World can be GC'd, and clears ModInitCalled
--     so the next world re-runs InitMod.
--   * Persistent flags (hooks/loops registered once per session) survive, so we
--     don't re-register hooks.
--   * No GC heroics - just release what we hold and let the engine collect.
-- ==========================================================
function MAIN.StopMod()
    Log("StopMod - world teardown, releasing state")
    STATE.ModEnabled = false
    pcall(Utils.ResetState)

    -- Drop the experimental asset-keeper's pins so the old world's assets can be collected on the
    -- transition (no-op unless ASSET_KEEPER established any). See AnteCore/AssetKeeper.
    pcall(AssetKeeper.Release)

    -- Debug markers hold actor wrappers from the world that is going away.
    pcall(function() require("AnDebug.PlacedViz").ResetWorld() end)
    pcall(function() require("AnDebug.LocationViz").ResetWorld() end)

    -- Restore the client ReceiveTick hook for the NEXT join.
    --   * On an authority session we self-dropped it (hot-reload safety), but a CLIENT's
    --     ONLY init trigger + WorkQueue drain IS this hook - without restoring it, a later
    --     "SP/host -> exit to menu -> join a server" leaves the client unable to init at
    --     all (dead keybinds / client visuals / trader skins).
    --   * Safe here: we're heading to the menu / next load, not mid in-world tick; it just
    --     re-arms the same ~1s startup window the drop already tolerates.
    --   * See [[anteup2-shared-hook-teardown]].
    pcall(registerClientTickHook)
end


-- ==========================================================
-- Entry point
-- ==========================================================

-- Optional (opt-in): watch spawner CONSTRUCTION from the EARLIEST point (script load),
--   so near spawners in single player get their SpawnAs/Count config before they can
--   fire a first spawn ahead of InitMod's ApplySpawnOverrides.
--   * NotifyOnNewObject needs no LoadAsset (resolved by class path) and only
--     configures spawners that have a rule.
if SETTINGS.CORE.EARLY_SPAWNER_CONFIG then
    SpawnerHooks.RegisterEarlyConfig()
end

-- On the game thread where UE4SS can (Utils.DelayedGameThread); a worker thread on an older one.
Utils.DelayedGameThread(5000, function() MAIN.Start() end)
