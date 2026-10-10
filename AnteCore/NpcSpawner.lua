-- =======================================================================
-- NPCSPAWNER - spawns NPCs actors. Does not mutate.
-- 
--   NOTES
--     * Assets/classes are async loaded every spawn (can't rely on cache)
--     * Spawns run off WorkQueue - so they're 200ms apart
--     * create spawns using deferredSpawn so we can set actor props (faction)
--     * For mutations or other work, use the callback function
--
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local UEHelpers = require("UEHelpers")
local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local ASSETS = require("AnteCore.AssetManager")
local SETTINGS = require("Settings")
local Utils = require("AnteUtils.Utils")
local SCHEMA = require("AnteData.Schema")

local LogBad = Utils.LogBad
local LogDebug = Utils.LogDebug

local NS = {}

local nextSlotTick = 0

-- [Utils.ResetState] The cursor is a FAST_TICK and FAST_TICK restarts at 0 each world, so a
-- cursor left over from the last one queues every spawn against a tick this world never reaches.
function NS.ResetSlotCursor() nextSlotTick = 0 end

-- Slack before a spawned NPC's class is GC-pinned (see loadAndSpawn). Matches Pipeline's.
local PIN_DELAY_MS = 4000

-- =======================================================================
-- BIG BODIES SPAWN WITH THEIR FEET IN THE FLOOR
-- A spawn point is a navmesh point plus a fixed clearance (Utils.GetSpawnPoint adds 100, one
-- ordinary humanoid capsule). A LARGE/HUGE body's capsule is taller, so it lands shin-deep and
-- stays there - the engine only depenetrates on a MOVE. Shows up on robots and Jotun-tier bosses.
--   * ENPCCharacterSize: 0 Small, 1 Medium, 2 Large, 3 Huge.
--   * 15uu is deliberately small - the gap between two capsule heights, not a hover. More than
--     that and a body spawned under a low ceiling starts INSIDE it instead.
local BIG_BODY_SIZE = 2
local BIG_BODY_LIFT = 15

-- =======================================================================
-- HEAVY-BEGINPLAY ROWS - these classes' own BeginPlay blocking-loads, which is a hard freeze
-- if the spawn runs on the WorkQueue drain (inside the ProcessTick hook - CLAUDE.md S2's
-- re-entrant ProcessEvent deadlock). The wedge is inside FinishSpawningActor itself, not our
-- callback or the class load.
--
-- Fix: hop to a worker thread first (ExecuteWithDelay), THEN ExecuteInGameThread. An EIGT
-- called directly from the game thread has no hook frame to escape; going out to a worker
-- thread first means the EIGT lands on a clean game-thread pump with no hook underneath it.
-- The spawn itself still happens on the game thread, so the BP calls are legal.
--   * Cost: one extra hop (~a frame); doSpawn re-checks STATE.ModEnabled and the world to
--     cover the extra exposure window.
--   * Four ways in: a row listed here (wedges even with a WARM class), opts.OffHook, a COLD
--     class load (automatic, see loadAndSpawn - the first spawn of a class per world), or the
--     native layout, where every spawn hops.
--   * Native layout: an NPC's construction resolves its row handles (NPCRow, voice rows...), and
--     that build loads some DataTables and what they reference lazily - so a WARM class still
--     wedges in-drain (a chat-spawned Grunt_Sapper, 10s into a world).
--   * Everything else stays on QueueWork: a queued EIGT landing mid-paint on a renderer is a
--     hazard of its own, so the hop is for spawns that would otherwise risk the deadlock.
-- Deep: AnNotes/AnteSystems/NpcSpawner.md (crash evidence, Zombie/Exor status).
-- =======================================================================
local OFFHOOK_ROWS = {
    Reaper = true,
    -- ReaperScout: the same wedge as its Reaper sibling, and it wedges WARM - Roaming Shade
    -- placements spawn scouts all through a Security run, so only the session's first one ever
    -- took the cold hop. A wedge here leaves no watchdog line either: the stall is inside a Lua
    -- call, so it holds the Lua lock the worker-thread watchdog needs to report.
    ReaperScout = true,
    -- Assassin: same in-flight FinishSpawningActor wedge, seen on a Shardling spawn mid-assault.
    Assassin = true,
    -- Grunt_FlameRat: same wedge, on a Purifier placement. The class is not boot-pinned, so the
    -- first spawn each session is cold and FinishSpawningActor loads what the class load did not.
    Grunt_FlameRat = true,
    -- DarkLens bosses: same wedge, on the Mage's timed respawn. We only ever spawn one once the
    -- native body is dead, so its one-off class is cold every time by construction.
    DarkLens_Mage = true,
    DarkLens_Chieftain = true,
    DarkLens_Heavy = true,
    DarkLens_Witch = true,
    -- Zombies: BeginPlay rolls a random head/torso/legs and blocking-loads each pick, so a WARM
    -- class still wedges whenever a pick is cold (the Zombie Trio's flankers). Off-hook that is
    -- a hitch, not a freeze.
    Zombie = true,
    Zombie_Dam = true,
    Zombie_Sci = true,
    -- Traders (SpawnClass, trace name "Trader_<row>") opt in through opts.OffHook instead.
}
-- Long enough that ExecuteWithDelay genuinely defers onto its worker thread rather than running
-- inline on the caller (a 0 delay is not a thread hop), short enough to stay inside the spawn's
-- own beat.
local OFFHOOK_HOP_MS = 50


-- =======================================================================
-- Game thread. Deferred spawn so opts can be applied pre-finish.
-- =======================================================================
local function spawnNpcActor(npcClass, location, rotation, opts, callback)

    -- (Niche) A spawn request can be async loaded after leaving a world and requeued
    if not STATE.ModEnabled then return end

    local world = Utils.GetWorld()
    if IsNotValid(world) then return end

    local gameplayStatics = UEHelpers.GetGameplayStatics()
    local kismetMath = UEHelpers.GetKismetMathLibrary()
    if not gameplayStatics or not kismetMath then return end

    local transform = kismetMath:MakeTransform(location, rotation or FRotator(), FVector(1, 1, 1))

    -- 1=AlwaysSpawn 2=AlawysSpawnAdjustPosition 3=DontSpawnIfCollision
    local collisionHandling = opts.CollisionHandling or 2

    -- Debug: spawn-> / spawn<- bracket - enclosing a spawn so we know if it was involved in a crash
    --   * Some NPCs do their own blocking LoadAssets - Exor is one. 
    --   * NPCs with random assets like Zombie can freeze the game if spawned this way
    Utils.LogDebug("spawn-> " .. tostring(opts._traceName or "npc"), SETTINGS.DEBUG_SPAWN_TRACE)

    local npc = gameplayStatics:BeginDeferredActorSpawnFromClass(world, npcClass, transform, collisionHandling, nil, 0)
    if IsNotValid(npc) then
        LogBad("NpcSpawner - deferred spawn failed")
        return
    end

    if opts.Faction then npc.Faction = opts.Faction end

    -- Skip the spawn-in FX and animation montage
    if opts.SkipSpawnFX then pcall(function() npc.SkipSpawnFX = true end) end

    -- FORCE the native spawn-in on a class that ships it disabled (class default
    --   IsPerformingSpawnFX=false, sometimes + SkipSpawnFX=true). Both opts write the same
    --   pair; WHAT the spawn-in looks like is entirely the class's own OnSpawnFXStarted:
    --     RopeSpawn    - the fast-rope rappel (NPC_Soldier_Grunt, OrderGrunt Troopers).
    --     ForceSpawnFX - anything else. On NPC_Gatekeeper_Parent it's a portal burst
    --                    (broadcast from the GameState), inherited by Witch/Heavy and turned
    --                    off only by Gatekeeper_Grunt/Chieftain.
    --   * Both gates are read exactly ONCE, in ReceiveBeginPlay - so this only works here in
    --     the deferred window; a post-BeginPlay write does nothing.
    --   * The true value differs from the class default, so it rides the initial replication
    --     bunch and each client runs its half from its own BeginPlay - no further plumbing.
    --   * Don't set either blindly: a class whose SpawnFXDuration is 0 never clears the flag,
    --     so IsNPCBusy() stays true and its AI is parked forever. Check the class chain first.
    if opts.RopeSpawn or opts.ForceSpawnFX then pcall(function()
        npc.SkipSpawnFX = false
        npc.IsPerformingSpawnFX = true
    end) end

    -- PreFinish: Any actor props we want to set before actor:BeginPlay()
    --   ex: A trader NPC
    if opts.PreFinish then pcall(opts.PreFinish, npc) end

    -- Lift a LARGE/HUGE body out of the floor (see the BIG_BODY knobs). Done HERE because
    -- CharacterSize is a class default - already readable in the deferred window - and because
    -- FinishSpawningActor's transform is what actually places the body: no post-spawn teleport, and
    -- the collision handling above still resolves from the lifted point.
    --   * opts.NoLift opts out for a caller that placed the body deliberately (a welded rider, a
    --     seat, an exact set-piece mark).
    --   * Read defensively: a class with no such property, or an enum that comes back as something
    --     other than a number, just gets no lift.
    local finishTransform = transform
    if not opts.NoLift then
        local size
        pcall(function() size = npc.CharacterSize end)
        if type(size) ~= "number" then
            local n
            pcall(function() n = size:GetIntValue() end)
            size = n
        end
        if type(size) == "number" and size >= BIG_BODY_SIZE then
            finishTransform = kismetMath:MakeTransform(
                FVector(location.X, location.Y, location.Z + BIG_BODY_LIFT),
                rotation or FRotator(), FVector(1, 1, 1))
        end
    end

    npc = gameplayStatics:FinishSpawningActor(npc, finishTransform, 0)
    if IsNotValid(npc) then
        LogBad("NpcSpawner - finish spawn failed")
        return
    end

    -- Push-model insurance for the forced flag: the pre-finish write should already ride
    --   the initial bunch (differs from the CDO); this covers a channel that opened
    --   before the write.
    if opts.RopeSpawn or opts.ForceSpawnFX then Utils.MarkReplicatedDirty(npc, "IsPerformingSpawnFX") end

    Utils.LogDebug("spawn<- " .. tostring(opts._traceName or "npc"), SETTINGS.DEBUG_SPAWN_TRACE)

    LogDebug("NpcSpawner - spawned " .. Utils.GetActorName(npc), SETTINGS.DEBUG_QUEUES)

    if callback then
        local ok, err = pcall(callback, npc)
        if not ok then LogBad("NpcSpawner callback error: " .. tostring(err)) end
    end
end


-- =======================================================================
-- Shared: stagger a slot, async-load the class PATH, then deferred-spawn it off-hook.
--   * Spawns must happen IGT, but not inside a ue4ss hook callback's IGT - any LoadAsset
--     there is a re-entrant deadlock.
--   * NPCs sometimes have their own blocking assets.
-- =======================================================================
local function loadAndSpawn(classPath, location, opts)
    local delayMs
    nextSlotTick, delayMs = Utils.ClaimSlotTick(nextSlotTick, 2)

    Utils.QueueWork(function()
        ASSETS.LoadAsync({ classPath }, function(results, cold)
            local npcClass = results[classPath]
            if IsNotValid(npcClass) then
                LogBad("NpcSpawner - class failed to load: " .. tostring(opts._traceName))
                return
            end

            -- The delayed PinPaths is the backstop for the PinLoaded pin below (see there); it is free
            -- once that one has landed.
            local KEEPER = require("AnteCore.AssetKeeper")
            Utils.QueueWork(function()
                pcall(function() KEEPER.PinPaths({ classPath }) end)
            end, PIN_DELAY_MS)

            -- Heavy-BeginPlay rows go the long way round (see OFFHOOK_ROWS).
            local offHook = opts.OffHook
            if offHook == nil then offHook = OFFHOOK_ROWS[opts._traceName or ""] end

            -- COLD CLASS: the load could not show the class was already resident, so whatever its
            -- spawn pulls beyond the class package is likely cold too - the shared signature of the
            -- FlameRat, DarkLens and trader wedges. A class never resolved before counts (LoadAsset
            -- may not probe it), which errs toward the hop. Hop it once; NpcSpawner's pin makes
            -- every later spawn a warm WQ one.
            --   * An explicit opts.OffHook = false still refuses.
            local coldHop = false
            if offHook == nil and cold and cold[classPath] then
                offHook, coldHop = true, true
                LogDebug("NpcSpawner - cold class, spawning off-hook: " ..
                    tostring(opts._traceName or classPath), SETTINGS.DEBUG_SPAWN_TRACE)
            end
            if offHook == nil and SCHEMA.Native then offHook = true end

            -- Dispatch mode, decided below - named HERE so the freeze label tells the truth.
            --   * On a renderer host, doSpawn runs via QueueWork = INSIDE the ProcessSpawns_Quick
            --     hook drain - the label must say "WQ", not "EIGT", or a real §2 wedge misreads
            --     as an EIGT-pump stall.
            local mode = offHook and (coldHop and "OFFHOOK-cold" or "OFFHOOK")
                or (STATE.Role == "DEDICATED" and "EIGT" or "WQ")

            local function doSpawn()
                -- *** S3 - RE-RESOLVE THE CLASS BY PATH. NEVER SPAWN THE CAPTURED WRAPPER. ***
                -- doSpawn runs later than the load callback that produced `npcClass` (a frame
                -- for WQ/EIGT, OFFHOOK_HOP_MS for the worker hop), and a freshly loaded UClass
                -- with no live instances can be collected in that window. IsValid lies on the
                -- reused slot, so spawning it gives the actor a garbage skeletal mesh component:
                -- an access violation in FBoneContainer::Initialize, before BeginPlay ever runs.
                --   * The CLASS is the whole check - a live UClass keeps its CDO, and the CDO's
                --     hard ref keeps the SkeletalMesh alive, so the mesh can't be collected while
                --     the class isn't.
                --   * GetIfValid is StaticFindObject-authoritative for a /Game/ path - the only
                --     read that can tell a live class from a reused slot. Costs a UObject walk
                --     (~25ms), paid once per spawn on a path already staggered 200ms apart.
                --   * Collected => one retry through the full load path (bounded by _reloaded),
                --     so the loser of a GC race arrives a beat late instead of crashing.
                -- Deep: AnNotes/AnteSystems/NpcSpawner.md (crash trace).
                local cls = ASSETS.GetIfValid(classPath)
                if IsNotValid(cls) then
                    LogBad("NpcSpawner - class collected between load and spawn: " ..
                        tostring(opts._traceName or classPath) ..
                        (opts._reloaded and " (already retried, giving up)" or " - retrying"))
                    if not opts._reloaded then
                        opts._reloaded = true
                        loadAndSpawn(classPath, location, opts)
                    end
                    return
                end

                -- Freeze breadcrumb for the DEBUG_FREEZE_TRACE watchdog: FinishSpawningActor
                -- runs BeginPlay, which for some NPCs blocking-loads, so a hang here names the
                -- class. The label also names the mode: an "OFFHOOK" wedge means the
                -- worker-thread hop didn't escape the hook frame - a different bug from the
                -- in-drain ("WQ") one the hop exists to fix.
                STATE.LastWork = mode .. " npcspawn " .. tostring(opts._traceName or classPath)
                STATE.LastWorkDone = false
                local ok, err = pcall(spawnNpcActor, cls, location,
                    opts.Rotation, opts, opts.callback)
                STATE.LastWorkDone = true
                if not ok then LogBad("NpcSpawner - spawn error: " .. tostring(err)) end
            end

            if offHook then
                -- Worker thread, then back to the game thread - the ONLY way an EIGT is queued
                -- rather than run under whatever hook frame we are standing in.
                Utils.DelayedGameThread(OFFHOOK_HOP_MS, doSpawn)
            elseif STATE.Role == "DEDICATED" then
                ExecuteInGameThread(doSpawn)
            else
                Utils.QueueWork(doSpawn, 0)
            end

            -- GC-PIN the class on the next drain item. Two jobs: a fresh class with no instance yet
            -- is held through the load-to-spawn window, where a GC mark condemned one (the KEEP list
            -- covers the common spawner staples), and doSpawn's re-resolve becomes a trusted cache hit
            -- instead of a lookup. Queued AFTER the in-drain spawn on purpose: the drain runs newest
            -- first, so the pin lands ahead of it.
            pcall(KEEPER.PinLoaded, classPath, npcClass)
        end)
    end, delayMs)
end


-- =======================================================================
-- Spawn an NPC by its NpcClasses key (e.g. "Peccary") at location.
--   opts: Rotation, Faction, CollisionHandling, callback(npc)
--         OffHook - force (or refuse) the worker-thread hop; defaults per row, see OFFHOOK_ROWS
-- =======================================================================
function NS.SpawnNpc(npcName, location, opts)
    if not Utils.IsAuthority() then return end
    if not npcName or not location then return end
    opts = opts or {}

    local className = ENUMS.NpcClasses[npcName]
    if not className then
        LogBad("NpcSpawner - unknown NPC: " .. tostring(npcName))
        return
    end
    opts._traceName = npcName

    loadAndSpawn(className, location, opts)
end


-- =======================================================================
-- Spawn an actor by full class path (for actors not in ENUMS.NpcClasses,
--   e.g. narrative trader or deployable class
-- opts: Rotation, Faction, CollisionHandling, SkipSpawnFX, RopeSpawn, ForceSpawnFX,
--       PreFinish(npc), callback(npc), _traceName
-- =======================================================================
function NS.SpawnClass(classPath, location, opts)
    if not Utils.IsAuthority() then return end
    if not classPath or not location then return end
    opts = opts or {}
    opts._traceName = opts._traceName or "actor"

    loadAndSpawn(classPath, location, opts)
end

return NS
