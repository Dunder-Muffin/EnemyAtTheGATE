-- =======================================================================
-- SpawnerHooks (AUTHORITY ONLY) - the mod's main entry into the game:
-- every NPC a spawner creates passes through TrySpawnNPC.
--   * SpawnAs: a SpawnerData entry can replace what a spawner spawns by rewriting its
--     spawn-list row names (SCHEMA.SpawnList; at ReceiveBeginPlay, plus once on MAIN for
--     existing spawners).
--     This is the most replication-friendly way to change an NPC.
--   * Spawner-config rules (applied here): SpawnAs, Disabled, Count, ForceSpawn,
--     CooldownDays, StoryMin/StoryMax, NoLossFlag.
--   * Per-NPC variant decision (Variant/MultiVariants/VariantLimit) lives in
--     NpcManager.HandleSpawnedActor.
--   * NoPatrol is the odd one out: a rule that configures the NPC rather than the spawner,
--     so it's applied per-body at TrySpawnNPC (and re-applied on the heal walk, since a
--     save-restored NPC comes back with a fresh controller at the stock PatrolFrequency).
-- Deep: AnNotes/AnteSystems/SpawnerHooks.md
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local SPAWNERDATA = require("AnteData.SpawnerData")
local NPCM = require("AnteVariants.NpcManager")
local Utils = require("AnteUtils.Utils")
local VARIANTS = require("AnteVariants.Variants")
local RESOLVER = require("AnteVariants.VariantResolver")
local ASSETS = require("AnteCore.AssetManager")
local ENUMS = require("AnteData.Enums")
local SCHEMA = require("AnteData.Schema")
local PROF = require("AnDebug.Profiler")

local LogBad = Utils.LogBad
local LogDebug = Utils.LogDebug

local SPAWNER_CLASS_NAME = "Abiotic_NPCSpawn_ParentBP_C"

-- NoPatrol - prevent spawned NPCs from idle wandering
--   * Path patrollers are not covered
local function applyNoPatrol(actor)
    if IsNotValid(actor) then return end
    -- this retries offhook until the controller possesses the pawn
    pcall(function() require("AnteUtils.AVUtils").SetNoPatrol(actor) end)
end

-- The reason a spawn is blocked. Tracked so we only log it once
local blockedReason = {}

-- VANISH DETECTOR. A body a spawner loses without a kill - fell out of the level, leapt away and
-- despawned - leaves no log at all, and the spawner just refills on its seconds cooldown ("Razor
-- Pests respawning rapidly"). A kill puts the spawner on its DAY cooldown, so a rule spawner
-- re-spawning within minutes at a live count that did not grow means the previous body left some
-- other way. Count groups are skipped (their fill and refill are logged on their own).
--   * A spawner whose level streamed out and back since its last spawn (its BeginPlay fired again)
--     refills natively: its body left with the level, and a stream-out is never a kill
--     ([[anteup2-spawner-count-streaming]]). That is a debug line and a `refill` count, not an error.
local VANISH_WINDOW_SEC = 600
local lastSpawnAt, lastSpawnCount = {}, {}   -- spawner name -> os.time() / live count after that spawn
local lastSpawnMs, streamInMs = {}, {}       -- spawner name -> Utils.NowMs() of its last spawn / BeginPlay

-- Track spawners that spawn 2+ NPCs
--   * The game will constantly respawn from multispawners so we need manage its cooldown
--   * phases fill -> full -> wipe -> "fill"
local countConfig   = {} -- { count, fill, wipe }
local countState = {}    -- { phase, cap, wipeAt, spawned }
local DEFAULT_FILL_SPACING_SEC    = 10   -- native 10
local DEFAULT_WIPE_COOLDOWN_HOURS = 72   -- killed cooldown, in-game hours (rolling)
local HARD_WIPE_COOLDOWN_HOURS    = 36   -- ... under HARDMODE.NoEnd (per-rule WipeCooldownHours still wins)
local HARD_MIN_COOLDOWN_DAYS      = 2    -- NoEnd halves native day cooldowns, never below this

-- A multispawn group only counts as killed if a player is nearby
-- AIDirector will stream out NPCs and we need to ignore that
local WIPE_REQUIRE_PLAYER_WITHIN = 6000

-- UE property names on a spawn-list entry (SCHEMA.SpawnList)
local FIELD_NPC    = SCHEMA.SpawnEntry.NPCToSpawn
local FIELD_WEIGHT = SCHEMA.SpawnEntry.SpawnChanceWeight

local SPAWNER_CLASS_PATH  = "/Game/Blueprints/Environment/Spawns/Abiotic_NPCSpawn_ParentBP.Abiotic_NPCSpawn_ParentBP_C"
local IS_ON_COOLDOWN_HOOK = SPAWNER_CLASS_PATH .. ":IsOnCooldown"

local HOOKS = {}


-- =======================================================================
-- SpawnAs - rewrite the NPC rows this spawner can spawn.
--   * STRING form: every row becomes SpawnAs (the original behavior).
--   * MAP form { <fromRow>=<toRow> }: only matching rows are rewritten - for MultiVariants
--     spawners where one species must change base and the others must stay
--     (e.g. SpawnAs={ Pest="Pest_Volatile" } on a Pest+Peccary mix;
--     key the MultiVariants entry by the NEW row).
--   * Re-apply is a no-op (the rewritten row no longer matches a map key).
-- =======================================================================
--   * PHASED SpawnAs is DESTRUCTIVE. The rewrite is in place: band 1 writing "Grunt_Guard"
--     over a Pest/Peccary/Exor_Monk mix erases the rows band 0 (and any map-form SpawnAs)
--     needs. vanillaRows snapshots the row names the FIRST time we touch a spawner.
--     restoreSpawnRows puts them back before each band applies, so a band change rewrites
--     the ORIGINAL list, never a rewrite of a rewrite.
--   * The snapshot only needs to survive IN-SESSION. The spawn list is per spawner instance
--     and is NOT world-saved (WorldSaveHasModified is the
--     "reconciled with the world save" gate feeding PendingSpawns_Quick, not a dirty flag;
--     persisted cooldowns live in the AIDirector subsystem). Every session and re-stream
--     starts vanilla, so restoring a snapshot over a freshly streamed spawner is a no-op.
--   * Row NAMES only - never weights, or we would undo ForceSpawn (which runs after us).
local vanillaRows = {}   -- spawnerName -> { rowName, ... } as first seen this session

local function snapshotSpawnRows(spawner, spawnerName)
    if vanillaRows[spawnerName] then return end
    pcall(function()
        local npcList = SCHEMA.SpawnList(spawner)
        if not npcList or #npcList == 0 then return end   -- not filled yet: snapshot on a later pass
        local rows = {}
        for i = 1, #npcList do
            local entry = npcList[i]
            rows[i] = entry and entry[FIELD_NPC].RowName:ToString() or nil
        end
        vanillaRows[spawnerName] = rows
    end)
end

local function restoreSpawnRows(spawner, spawnerName)
    local rows = vanillaRows[spawnerName]
    if not rows then return end
    pcall(function()
        local npcList = SCHEMA.SpawnList(spawner)
        if not npcList then return end
        for i = 1, #npcList do
            local entry, row = npcList[i], rows[i]
            if entry and row then entry[FIELD_NPC].RowName = FName(row) end
        end
    end)
end

local function applySpawnAs(spawner, spawnerName, rules)
    local map = type(rules.SpawnAs) == "table" and rules.SpawnAs or nil

    snapshotSpawnRows(spawner, spawnerName)

    local ok, err = pcall(function()
        local npcList = SCHEMA.SpawnList(spawner)
        if not npcList then return end

        for i = 1, #npcList do
            local entry = npcList[i]
            if entry then
                if map then
                    local repl = map[entry[FIELD_NPC].RowName:ToString()]
                    if repl then entry[FIELD_NPC].RowName = FName(repl) end
                else
                    entry[FIELD_NPC].RowName = FName(rules.SpawnAs)
                end
            end
        end

        -- Mark modified so the spawner registers its changed state
        spawner.WorldSaveHasModified = true
    end)

    local desc = rules.SpawnAs
    if map then
        local parts = {}
        for from, to in pairs(map) do parts[#parts + 1] = from .. "->" .. to end
        desc = table.concat(parts, ", ")
    end

    if ok then
        LogDebug(string.format("[%s] SpawnAs -> %s", spawnerName, desc),
            SETTINGS.DEBUG_SPAWNERS)
    else
        LogBad(string.format("[%s] SpawnAs (%s) failed: %s", spawnerName, tostring(desc), tostring(err)))
    end
end


-- =======================================================================
-- Wipe-cooldown PERSISTENCE - a Count group you killed stays on cooldown across a full
-- relaunch (not just a re-stream).
--   * Stored in the world JSON under STATE.StoryData.SpawnerWipeReadyHour =
--     { [spawnerName] = wipeAt } (Utils.GetGameHours - in-game hours, rolling).
--   * Written via FileIO (lazy-required so this module has no load-time dependency on it).
--   * Overhead is tiny: only WIPED spawners have an entry, and we only write the file on a
--     wipe START / END (a full group kill / its cooldown elapsing), not per tick.
-- =======================================================================
local function saveCooldowns()
    local ok, FileIO = pcall(require, "AnteCore.FileIO")
    if ok and FileIO then pcall(FileIO.SaveStoryData) end
end

-- The persisted book, or nil before StoryData loads. Drops the pre-rolling SpawnerCooldowns
-- store, whose wall-clock stamps would read as a cooldown that never ends.
local function wipeBook()
    local sd = STATE.StoryData
    if not sd then return nil end
    sd.SpawnerCooldowns = nil
    sd.SpawnerWipeReadyHour = sd.SpawnerWipeReadyHour or {}
    return sd.SpawnerWipeReadyHour
end

local function persistWipe(name, wipeAt)
    local book = wipeBook()
    if not book then return end
    book[name] = wipeAt
    saveCooldowns()
end

local function clearWipe(name)
    local book = wipeBook()
    if not (book and book[name]) then return end
    book[name] = nil
    saveCooldowns()
end

-- A persisted (cross-session) wipe cooldown for this spawner that hasn't elapsed yet, else nil.
local function persistedWipeAt(name)
    local book = wipeBook()
    local at = book and book[name]
    local now = Utils.GetGameHours()
    if at and (not now or at > now) then return at end
    return nil
end


-- =======================================================================
-- Count - keep a GROUP of `Count` NPCs at this spawner: fill it, let players empty it,
-- then a LONG cooldown before it refills.
--
-- The native spawner does all the spawning (NPCsAllowedFromSpawn = the live cap); each
-- spawn still flows through our TrySpawnNPC hook -> HandleSpawnedActor. We set:
--   * UseDaysCooldown = false - switches the native throttle from a multi-DAY cooldown to
--     SECONDS (the flag is otherwise unused by the game). This SECONDS cooldown is the gap
--     between each NPC while the group fills (`fill`, default 10s); it also throttles our
--     per-NPC mutations.
--   * The wipe-cooldown + "don't refill partial deaths" behavior is driven by the
--     IsOnCooldown hook (a pure SIDE-EFFECT driver, no return-override needed). It watches
--     GetCurrentSpawnedCount and toggles the cap:
--         fill: cap=Count. Native fills one per `fill` sec until the group reaches Count.
--               "Reached Count" latches on the CUMULATIVE number spawned (st.spawned, bumped
--               in the TrySpawnNPC hook), NOT just cur>=Count seen live. Otherwise a group a
--               player empties as fast as it fills never latches full and refills every
--               `fill` sec forever. cur>=Count is kept as a fast path.
--         full: cap=0 -> partial deaths do NOT refill, so the group can be emptied.
--         wipe: group reached 0 -> hold cap=0 for `wipe` in-game hours (default 72, 36 under
--               NoEnd), then refill. Rolling, so it runs the same length whatever the hour.
--   * State is per spawner-INSTANCE (reset in applyCount), so a re-stream repopulates
--     instead of inheriting a stale wipe cooldown.
--
-- Bench/base proximity is still respected (independent of the cap).
-- Reset for testing via DebugUtils.ResetSpawnerCooldowns (Ctrl+Shift+M).
-- =======================================================================
local function applyCount(spawner, spawnerName, rules)
    local fill = rules.FillSpacingSec  or DEFAULT_FILL_SPACING_SEC
    local wipe = rules.WipeCooldownHours
        or (STATE.HardModeNoEnd and HARD_WIPE_COOLDOWN_HOURS or DEFAULT_WIPE_COOLDOWN_HOURS)
    countConfig[spawnerName] = { count = rules.Count, fill = fill, wipe = wipe }

    -- Resolve this (possibly RE-STREAMED) instance's phase + starting cap BEFORE touching
    -- the spawner.
    --   * Blindly opening the cap to Count and resetting every non-wipe phase to "fill" here
    --     reopens a FILLED or cooling group's cap on return and refills the whole group
    --     before the IsOnCooldown heartbeat can re-assert 0 (the respawn-on-return bug).
    --   * So we PRESERVE "full" and "wipe" across a re-stream (native NPCs persist / re-stream
    --     on their own; we must not refill on top of them) and set the cap to match:
    --       fill -> cap = Count (a genuinely fresh group)
    --       full/wipe -> cap = 0 (already built, or killed + cooling)
    --   * st.cap = nil forces the IsOnCooldown hook to re-assert the cap on the new instance.
    local st = countState[spawnerName]
    local startCap
    if st and (st.phase == "full" or st.phase == "wipe") then
        st.cap = nil
        startCap = 0
    else
        local at = persistedWipeAt(spawnerName)
        if at then
            countState[spawnerName] = { phase = "wipe", wipeAt = at }   -- relaunch: resume cooldown
            startCap = 0
        else
            countState[spawnerName] = { phase = "fill", spawned = 0 }   -- fresh: fill the group
            startCap = rules.Count
        end
    end

    local ok, err = pcall(function()
        spawner.NPCsAllowedFromSpawn = startCap       -- phase-correct cap (NOT blindly Count)
        spawner.UseDaysCooldown = false               -- DAYS -> SECONDS throttle (the fill spacing)
        spawner.SpawnCooldown_Default = fill
        spawner.WorldSaveHasModified = true
    end)

    if ok then
        LogDebug(string.format("[%s] Count -> %d (fill %ds, wipe-cooldown %gh, phase %s)",
            spawnerName, rules.Count, fill, wipe, countState[spawnerName].phase),
            SETTINGS.DEBUG_SPAWNERS)
    else
        LogBad(string.format("[%s] Count failed: %s", spawnerName, tostring(err)))
    end
end


-- =======================================================================
-- CooldownDays - override the native DAY-based respawn cooldown for a NON-Count spawner
-- (most vanilla spawners default to SpawnCooldownDays_Default = 2).
--   * The game persists the cooldown as "the in-game DAY the spawner last spawned" in the
--     AIDirectorSubsystem (saved with the world) and lets it respawn once
--     NormalizedSpawnCooldownDays in-game days pass.
--   * That normalized value is DERIVED (UpdateCooldownDays) from SpawnCooldownDays_Default
--     divided by the EnemySpawnRate sandbox option (min 1) - so we set the field and re-derive.
-- =======================================================================
local function applyCooldownDays(spawner, spawnerName, rules)
    local ok, err = pcall(function()
        spawner.UseDaysCooldown = true
        spawner.SpawnCooldownDays_Default = rules.CooldownDays
        spawner:UpdateCooldownDays()             -- recompute NormalizedSpawnCooldownDays
        spawner.WorldSaveHasModified = true
    end)

    if ok then
        LogDebug(string.format("[%s] CooldownDays -> %d", spawnerName, rules.CooldownDays),
            SETTINGS.DEBUG_SPAWNERS)
    else
        LogBad(string.format("[%s] CooldownDays failed: %s", spawnerName, tostring(err)))
    end
end


-- =======================================================================
-- ForceSpawn - zero the SpawnWeight of any "None" rows so the spawner can
-- never roll an empty pick and always spawns a real NPC.
-- =======================================================================
local function applyForceSpawn(spawner, spawnerName)
    local ok, err = pcall(function()
        local npcList = SCHEMA.SpawnList(spawner)
        if not npcList then return end

        for i = 1, #npcList do
            local entry = npcList[i]
            if entry and entry[FIELD_NPC].RowName:ToString() == "None" then
                entry[FIELD_WEIGHT] = 0
            end
        end

        spawner.WorldSaveHasModified = true
    end)

    if ok then
        LogDebug(string.format("[%s] ForceSpawn applied", spawnerName), SETTINGS.DEBUG_SPAWNERS)
    else
        LogBad(string.format("[%s] ForceSpawn failed: %s", spawnerName, tostring(err)))
    end
end


-- =======================================================================
-- Disabled - stop a spawner from ever creating an NPC.
--   * Useful for spawners in areas players almost never visit, to skip the NPC's
--     mesh/AI/anim load.
--   * NPCsAllowedFromSpawn is the spawn cap; 0 = streams in but spawns nothing.
--     Cheaper than letting it spawn and destroying the actor afterward.
-- =======================================================================
local function disableSpawner(spawner, spawnerName)
    local ok, err = pcall(function()
        spawner.NPCsAllowedFromSpawn = 0
        spawner.WorldSaveHasModified = true
    end)

    if ok then
        LogDebug(string.format("[%s] Disabled (NPCsAllowedFromSpawn=0)", spawnerName),
            SETTINGS.DEBUG_SPAWNERS)
    else
        LogBad(string.format("[%s] Disable failed: %s", spawnerName, tostring(err)))
    end
end


-- NoLossFlag - ignore the spawner's DisablePermanentlyFlag.
--   * Some placed spawners (the Gale trench's two factions) carry a world flag that, once a
--     player trips the matching "pushed back" trigger, shuts the spawner off for the rest
--     of the save - the day cooldown never gets a look in. Blanking the row handle makes
--     it respawn like any other spawner while the flag (and whatever it opened) stands.
--   * Re-applied on every stream-in, so the blank survives sublevel reloads.
-- =======================================================================
local function clearLossFlag(spawner, spawnerName)
    local had
    local ok, err = pcall(function()
        local handle = spawner.DisablePermanentlyFlag
        if not handle then return end
        local row = handle.RowName and handle.RowName:ToString() or "None"
        if row == "None" or row == "" then return end
        had = row
        handle.RowName = FName("None")
    end)

    if not ok then
        LogBad(string.format("[%s] NoLossFlag failed: %s", spawnerName, tostring(err)))
    elseif had then
        LogDebug(string.format("[%s] NoLossFlag - cleared DisablePermanentlyFlag %s", spawnerName, had),
            SETTINGS.DEBUG_SPAWNERS)
    end
end


-- =======================================================================
-- OverrideSpawnRange - how close a player must be before the spawner may spawn.
--
-- *** CURRENTLY UNWIRED - kept as a documented lever, deliberately not called. ***
-- applySpawnerRules has the commented call site. Arm it only if you actually want the game's
-- own spawners reaching further; PlacedSpawns are a separate system with their own radii
-- (ActiveRadius / NearRadius / NearFastCheck - see AnteData/SpawnerData's header).
--
--   * PlayerWithinDistanceToSpawn (def 75m)
--      > "spawn blocked: Player Too Far" log message when out of range
--      > 10m - player too close
--      > 45m - LoS check (blocks only when the player CAN see the spot)
--      > 50m - recent death check
--   * Applied as a FLOOR, never a set: some level instances ship wider and shrinking those would
--     be a silent regression. That also makes it idempotent on the IsOnCooldown heartbeat.
--   * Widening cannot pop an NPC in someone's face - the three checks above are separate
--     constants in the same native function and are untouched by this.
-- =======================================================================
function HOOKS.OverrideSpawnRange(spawner, spawnerName, rules)
    local spawnRange = (rules and rules.SpawnRange)
        or SETTINGS.GAMEPLAY.SpawnRange
    if not spawnRange then return end

    local applied
    local ok, err = pcall(function()
        local cur = spawner.PlayerWithinDistanceToSpawn or 0
        if cur >= spawnRange then return end
        spawner.PlayerWithinDistanceToSpawn = spawnRange
        applied = cur
    end)

    if not ok then
        LogBad(string.format("[%s] SpawnRange failed: %s", spawnerName, tostring(err)))
    elseif applied then
        LogDebug(string.format("[%s] SpawnRange %d -> %d", spawnerName, applied, spawnRange),
            SETTINGS.DEBUG_SPAWNERS)
    end
end


-- =======================================================================
-- StoryMin / StoryMax - only let a spawner run inside a StoryProgress window.
--   * StoryMin - spawns nothing until StoryProgress >= this (gate behind a milestone)
--   * StoryMax - spawns nothing once  StoryProgress >= this (shut the phase down)
--   * Same keys, same inclusive/exclusive edges as SpawnerData.PlacedSpawns.
--   * Enforced as a cap of 0 (like Disabled), NOT by blocking the spawn afterwards -
--     a spawner outside its window never loads its NPC's mesh/AI at all.
--   * Re-checked on the IsOnCooldown heartbeat, not just at ReceiveBeginPlay: a level can
--     stay streamed in while StoryProgress moves past an edge, and we want the spawner to
--     switch on/off there and then rather than on the next re-stream.
--   * storyCap[name] holds the NATIVE cap we zeroed, so opening the window can hand it back
--     (we must not guess a default - most spawners aren't Count spawners, so nothing else
--     would ever restore it).
-- =======================================================================
local StoryManager   -- lazy: Variants -> variant defs -> StoryManager is a load-time cycle
local storyCap = {}  -- spawnerName -> the cap we're holding at 0, while gated OFF

-- Phases: spawnerName -> the PhaseIndex currently applied to that spawner. The heartbeat
-- compares it to the band in force now, so a story crossing takes hold under a spawner the
-- player is standing next to instead of waiting for a re-stream.
local appliedPhase = {}

local function storyAllows(rules)
    if not (rules.StoryMin or rules.StoryMax) then return true end
    StoryManager = StoryManager or require("ModuleStory.StoryManager")
    local story = StoryManager.GetStoryProgress() or 0   -- cached ~5s; cheap per heartbeat
    if rules.StoryMin and story < rules.StoryMin then return false end
    if rules.StoryMax and story >= rules.StoryMax then return false end
    return true
end

local function storyGateOff(spawner, spawnerName)
    if storyCap[spawnerName] == nil then
        local ok, cap = pcall(function() return spawner.NPCsAllowedFromSpawn end)
        storyCap[spawnerName] = (ok and cap) or 1
        LogDebug(string.format("[%s] outside its story window - held at 0 (cap %s)",
            spawnerName, tostring(storyCap[spawnerName])), SETTINGS.DEBUG_SPAWNERS)
    end
    pcall(function()
        spawner.NPCsAllowedFromSpawn = 0
        spawner.WorldSaveHasModified = true
    end)
end


-- =======================================================================
-- Apply all spawner-config rules to one spawner. Shared by ReceiveBeginPlay
-- (streamed-in spawners) and ApplySpawnOverrides (already-live at init).
--   * NOTE: this only configures the SPAWNER. The per-NPC variant decision
--     (Variant / MultiVariants / VariantLimit) happens later, in
--     NpcManager.HandleSpawnedActor when each NPC actually spawns.
-- =======================================================================

-- HARD MODE (NoEnd) - halve every native DAY cooldown, never below HARD_MIN_COOLDOWN_DAYS.
-- Gated on STATE.HardModeNoEnd (ModuleHardMode sets it per world).
--   * The native cooldown counts CALENDAR days (ready at midnight), so 1 day meant anything
--     killed in the evening was back within a minute or two of real time. 2 days is 1-2 days.
--   * IDEMPOTENCE is the whole design: this runs from BeginPlay, the init scan AND the
--     heartbeat re-apply, so a read-then-halve would compound (2 -> 1 -> 0). The native
--     value is cached per CLASS from the FIRST pristine sighting - a fresh (re)streamed
--     instance carries the class default by definition, and this module is not
--     /reload-able, so the cache can only be lost with the whole Lua state.
--   * The cache is NOT seeded from a spawner carrying a CooldownDays rule - a re-apply
--     pass could have already written the rule's value there, and one poisoned reading
--     becomes the "native" for the entire class.
--   * Count spawners are skipped (their day path is off; applyCount halves the wipe),
--     and an authored rules.CooldownDays wins - applyCooldownDays runs after us.
--   * Retroactive by design: the days path is evaluated LIVE against the persisted
--     LastDayOnCooldown stamp, so an in-flight 4-day wait becomes 2 days immediately.
local nativeDaysByClass = {}   -- spawner class name -> pristine SpawnCooldownDays_Default

local function hardenDayCooldown(spawner, spawnerName, rules)
    if not STATE.HardModeNoEnd then return end
    if rules and ((rules.Count and rules.Count > 1) or rules.CooldownDays) then return end

    local clsName, native
    pcall(function()
        clsName = spawner:GetClass():GetFName():ToString()
        native = nativeDaysByClass[clsName]
        if native == nil then
            native = spawner.SpawnCooldownDays_Default
            if type(native) == "number" and native >= 1 then nativeDaysByClass[clsName] = native end
        end
    end)
    if type(native) ~= "number" or native <= HARD_MIN_COOLDOWN_DAYS then return end

    local target = math.max(HARD_MIN_COOLDOWN_DAYS, math.floor(native / 2))
    local ok = pcall(function()
        if spawner.SpawnCooldownDays_Default ~= target then
            spawner.SpawnCooldownDays_Default = target
            spawner:UpdateCooldownDays()             -- recompute NormalizedSpawnCooldownDays
            spawner.WorldSaveHasModified = true
            LogDebug(string.format("[%s] NoEnd: CooldownDays %d -> %d",
                tostring(spawnerName), native, target), SETTINGS.DEBUG_SPAWNERS)
        end
    end)
    if not ok then LogDebug("[" .. tostring(spawnerName) .. "] NoEnd harden failed", SETTINGS.DEBUG_SPAWNERS) end
end

-- abs key -> true, so the coord dump below writes one line per spawner, not one per evaluation.
local seenSpawnerCoords = {}

-- The rules that edit the spawn list (SpawnAs, ForceSpawn) need it filled. A native spawner fills
-- it in its own BeginPlay, after our PRE BeginPlay hook, so those two re-run a beat later.
--   * One pending retry per spawner; bounded, since a spawner can legitimately have no entries.
--   * Gated on the spawner's coords, not its wrapper: a player hopping out frees it (see the
--     BeginPlay heal below). Rules are re-read at run time in case a story band moved.
local LIST_RETRY_MS, LIST_RETRY_MAX = 250, 8
local listPending = {}   -- spawnerName -> retries used

local function spawnListReady(spawner)
    local ok, n = pcall(function() return #SCHEMA.SpawnList(spawner) end)
    return ok and (tonumber(n) or 0) > 0
end

local function deferListRules(spawner, spawnerName)
    if listPending[spawnerName] then return end
    listPending[spawnerName] = 0

    local sloc   -- plain numbers: nothing engine-owned is held across the wait
    pcall(function()
        local l = spawner:K2_GetActorLocation()
        sloc = { X = l.X, Y = l.Y, Z = l.Z }
    end)

    local function attempt()
        if not STATE.ModEnabled or not Utils.IsLocationLoaded(sloc) then
            listPending[spawnerName] = nil
            return
        end
        if not spawnListReady(spawner) then
            local used = listPending[spawnerName] + 1
            listPending[spawnerName] = used
            if used >= LIST_RETRY_MAX then
                listPending[spawnerName] = nil
                LogDebug(string.format("[%s] spawn list still empty after %d tries - SpawnAs/ForceSpawn skipped",
                    spawnerName, used), SETTINGS.DEBUG_SPAWNERS)
                return
            end
            Utils.QueueWork(attempt, LIST_RETRY_MS)
            return
        end
        listPending[spawnerName] = nil
        local rules = SPAWNERDATA.Rules(spawnerName)
        if not rules or rules.Disabled or not storyAllows(rules) then return end
        if rules.SpawnAs then applySpawnAs(spawner, spawnerName, rules) end
        if rules.ForceSpawn then applyForceSpawn(spawner, spawnerName) end
    end
    Utils.QueueWork(attempt, LIST_RETRY_MS)
end

local function applySpawnerRules(spawner, spawnerName, rules)
    -- SpawnerData keys are abs(), and GetSpawnerName strips the signs before anything downstream
    -- can see them - so no other log line in the mod can tell you a spawner's real world position.
    -- This runs for EVERY spawner (above the `rules` guard), which is the point: the unconfigured
    -- ones are exactly the coords still missing from SpawnerData.
    if spawnerName and not seenSpawnerCoords[spawnerName] then
        seenSpawnerCoords[spawnerName] = true
        local loc = Utils.RoundedLocation(spawner:K2_GetActorLocation())
        -- A spawner caught before it is positioned reads 0,0,0 and would poison the key.
        if loc.X ~= 0 or loc.Y ~= 0 or loc.Z ~= 0 then
            LogDebug(string.format("SpawnerCoord [%s] = %d,%d,%d",
                spawnerName, loc.X, loc.Y, loc.Z), SETTINGS.DEBUG_SPAWNERS)
        else
            seenSpawnerCoords[spawnerName] = nil   -- let a later, positioned pass log it properly
        end
    end

    -- HOOKS.OverrideSpawnRange(spawner, spawnerName, rules)
    -- ^ deliberately NOT called - see its header. This is the place to arm it: above the `rules`
    --   guard, so the global floor reaches the unconfigured majority of spawners too.

    -- Above the rules guard for the same reason: NoEnd must reach the unconfigured
    -- majority of spawners, not just the ones with a SpawnerData entry.
    hardenDayCooldown(spawner, spawnerName, rules)

    if not rules then return end

    -- Phased entry: put the vanilla rows back before this band writes its own SpawnAs, so
    -- each band rewrites the ORIGINAL list rather than the previous band's output. Harmless
    -- (and cheap) on a spawner we have never rewritten - vanillaRows is empty and this no-ops.
    if rules.Phased then
        appliedPhase[spawnerName] = rules.PhaseIndex or 0   -- 0 = banded, but no band open
        restoreSpawnRows(spawner, spawnerName)
    end

    -- Disabled wins outright - if it spawns nothing, nothing else matters.
    if rules.Disabled then
        disableSpawner(spawner, spawnerName)
        return
    end

    -- Above the story gate: a blanked flag is harmless in any window, and a spawner held
    -- at 0 by StoryMin still needs it gone by the time the window opens.
    if rules.NoLossFlag then clearLossFlag(spawner, spawnerName) end

    -- Outside its StoryProgress window: hold at 0 and skip the rest (the IsOnCooldown
    -- heartbeat re-checks, and re-runs this function once the window opens).
    if not storyAllows(rules) then
        storyGateOff(spawner, spawnerName)
        return
    end

    -- Inside the window: hand back the native cap if we were holding it at 0.
    -- Do this BEFORE applyCount, which sets its own phase-correct cap on top.
    local held = storyCap[spawnerName]
    if held ~= nil then
        storyCap[spawnerName] = nil
        pcall(function() spawner.NPCsAllowedFromSpawn = held end)
        LogDebug(string.format("[%s] story window open - cap restored to %s", spawnerName, tostring(held)),
            SETTINGS.DEBUG_SPAWNERS)
    end

    local listLater = SCHEMA.Native and (rules.SpawnAs or rules.ForceSpawn) and not spawnListReady(spawner)
    if listLater then deferListRules(spawner, spawnerName) end

    if rules.SpawnAs and not listLater then applySpawnAs(spawner, spawnerName, rules) end

    local isCount = rules.Count and rules.Count > 1
    if isCount then applyCount(spawner, spawnerName, rules) end
    -- CooldownDays is for NON-Count spawners (Count uses a seconds cooldown + its own
    -- fill/wipe state machine; CooldownDays would re-enable the day cooldown and fight it).
    if rules.CooldownDays and not isCount then applyCooldownDays(spawner, spawnerName, rules) end

    if rules.ForceSpawn and not listLater then applyForceSpawn(spawner, spawnerName) end
end


-- =======================================================================
-- SPAWNER ASSET PRE-WARM.
--   * Pipe.LoadAssets is the fattest mutation step: cold def.Assets loading when each NPC
--     spawns (measured up to 135ms), paced by the game's spawners, so a spawner-dense area
--     (Exor Village) reads choppy for its whole fill.
--   * A spawner streaming in is the EARLY signal for which variants are about to spawn, so
--     warm every candidate's def.Assets in the level-entry window and the per-NPC
--     LoadAssets step becomes a cache hit.
--   * Story-unresolved on purpose (RESOLVER.AllNames): a shut window's candidate costs only
--     a few extra paths.
-- =======================================================================
local warmedAt = {}             -- variant name -> FAST_TICK of the last warm queue
local WARM_DEDUP_TICKS = 600    -- 60s: ten Pest spawners in one level = one warm, not ten

-- Takes a plain LIST of variant names. Rules-shaped callers go through
-- queueVariantAssetWarm, which flattens every band via RESOLVER.AllNames first.
local function queueNameAssetWarm(names)
    if not names or #names == 0 then return end
    local now = STATE.FAST_TICK
    local paths = {}
    for _, name in ipairs(names) do
        local last = warmedAt[name]
        if not last or now < last or (now - last) >= WARM_DEDUP_TICKS then
            warmedAt[name] = now
            local def = VARIANTS[name]
            for _, p in ipairs((def and def.Assets) or {}) do
                if type(p) == "string" then paths[#paths + 1] = p end
            end
        end
    end
    if #paths == 0 then return end

    -- OFF the BeginPlay hook (blocking-load-in-hook = the S2 deadlock family); the WQ drain
    -- is the blessed load context.
    --   * One item per spawner: any cold loads land inside the arrival burst window instead
    --     of on the first spawn, and spawners stream in staggered anyway.
    --   * PIN, don't just load. A warmed-but-unpinned candidate GC-cycles FOREVER -
    --     Pipeline's own pin only fires on actual MUTATION, so a variant that sits near
    --     spawners without ever spawning cold-loads again on every dedup lapse, each round a
    --     fresh LoadAsync scan per path (see AnNotes/AnteSystems/SpawnerHooks.md and
    --     [[anteup2-ue4ss-findobject-scan-crash]]). Pinned, a re-warm finds every path in
    --     KEEPER.IsPinned and does NOTHING - the 60s dedup lapse becomes free, and the
    --     level-entry churn window stops being a scan burst.
    --   * The plain LoadAsync stays for flag-off (old behavior) - the warm's original job is
    --     still wanted there.
    Utils.QueueWork(function()
        if not STATE.ModEnabled then return end
        local t0 = PROF.Begin()
        if SETTINGS.CORE.ASSET_KEEPER then
            require("AnteCore.AssetKeeper").PinPaths(paths)
        else
            ASSETS.WarmPinned(paths)
        end
        PROF.EndAs(t0, "SpawnerAssetWarm")
    end, 100)
end

local function queueVariantAssetWarm(rules)
    if not rules then return end
    queueNameAssetWarm(RESOLVER.AllNames(rules))
end

-- Public wrapper: EventUtils warms a PLACED spawn's variant at its arrival burst.
--   * Placed/late spawns aren't covered by the spawner-hook warms (Power Services is ALL
--     placed spawns), so Pipe.LoadAssets stayed fat there without this.
--   * `rules` = a SpawnerData-shaped entry (a placed cfg's { Variant = "..." } qualifies).
--     Every band of a phased entry is warmed, not just the open one.
function HOOKS.WarmVariantAssets(rules)
    queueVariantAssetWarm(rules)
end

-- Same warm, for a caller that already HAS the names (GATE warms a wave's roster).
--   * Don't route a name list through WarmVariantAssets as { Variant = names }: a Variant
--     value is a STRING (Phases replaced the old banded-list form), and ValidateSpawnerData
--     flags a table there as a missed conversion.
function HOOKS.WarmVariantNames(names)
    queueNameAssetWarm(names)
end


-- =======================================================================
-- SAVE-RESTORE HEAL. The TrySpawnNPC hook is the ONLY place a spawner NPC gets its
-- variant, and it only fires on a live spawn EVENT.
--   * An NPC restored from the world save skips it. The AIDirectorSubsystem re-links the
--     body to its spawner (so it counts against the cap - "Spawn's NPC Cap Reached" - and
--     the spawner never respawns a mutable one), and NPCData was rebuilt from the DT row on
--     load, so the variant is gone.
--   * Net: a plain base NPC can stand at a variant spawner until killed.
--   * PlacedSpawns already heals this case (healPlacedVariant); this is the game-spawner
--     mirror. Walk the spawner's live NPCs (director list, proximity fallback - see
--     GetSpawnerNpcs) and re-run the normal spawn decision on any live body carrying no
--     VARIANTTAG (see the test below - the tag, not the DisplayName, is what proves a
--     mutation finished).
--   * HandleSpawnedActor is re-run-safe by design (row-name identity): it respects
--     MultiVariants / story bands / VariantLimit (the list index stands in for the fill
--     count) and skips non-accepted bases (a pre-SpawnAs body).
--   * Triggers: deferred after ReceiveBeginPlay (the relink lands around stream-in), and
--     the IsOnCooldown heartbeat as the rate-limited catch-all for late relinks.
-- =======================================================================
local healCheckedAt = {}          -- spawnerName -> os.time() of the last heal walk
local healQueued = {}             -- npc fullname -> os.time() a mutation was queued (spawn OR heal)
local HEAL_RECHECK_SEC = 30       -- per-spawner walk cadence on the heartbeat
-- Leave a just-queued mutation alone: MutateActor staggers 300-1000ms and STATS (the
-- DisplayName write) lands a few ticks later - re-queueing inside that window would run
-- the pipeline twice on one actor.
local HEAL_MUTATE_GRACE_SEC = 30

-- Called from the TrySpawnNPC hook too, so a freshly-spawned NPC's in-flight
-- mutation is never doubled by a heal walk landing inside the stagger window.
local function healMarkQueued(npc)
    local fn
    pcall(function() fn = npc:GetFullName() end)
    if fn then healQueued[fn] = os.time() end
end

-- The spawner's live NPCs, as a plain Lua array.
--   * `spawner.CurrentNPCs` is a DEAD legacy property - the BP declares it but never writes
--     it. Decompiled GetCurrentSpawnedCount asks the AIDirectorSubsystem instead; CurrentNPCs
--     reads EMPTY on every spawner even while it has live NPCs.
--   * GetSpawnedAIFromSpawner fills an out-param TArray - pass a Lua table per the out-param
--     convention (CLAUDE.md 3; a pcall that omits the out is a SILENT NO-OP).
function HOOKS.GetSpawnerNpcs(spawner)
    local out = {}
    local sub = Utils.GetAIDirector()   -- cached; FindFirstOf here was ~10ms per walk
    if IsValid(sub) then
        pcall(function() sub:GetSpawnedAIFromSpawner(spawner, out) end)
    end
    -- The out-param TArray marshals each element as a RemoteUnrealParam - :get() unwraps it
    -- to the actor wrapper (the same convention as GetNearbyNpcs' SphereOverlapActors array).
    --   * Without it the first IsValid/property touch on an element throws "attempt to call a
    --     RemoteUnrealParam value", aborting the walk mid-loop - so the heal never actually
    --     mutated anything from the director list.
    local npcs = {}
    for i = 1, #out do
        local npc
        pcall(function() npc = out[i]:get() end)
        if npc then npcs[#npcs + 1] = npc end
    end
    return npcs
end

-- Fallback candidate list when the director yields nothing but the native count says bodies
-- exist (out-param marshalling quirk, or a director re-link edge).
--   * A TIGHT proximity scan around the spawner for bodies of the rules' base rows -
--     the PlacedSpawns base-radius pattern.
--   * Lazy requires: AVUtils/VariantTag from here is a load-cycle risk.
local HEAL_SCAN_RADIUS = 4000   -- ~40m, same as PLACED_DEFAULT_BASE_RADIUS

local function healFallbackScan(spawner, rules)
    local cur = 0
    pcall(function() cur = spawner:GetCurrentSpawnedCount(true) or 0 end)
    if cur <= 0 then return {} end
    local loc
    pcall(function() loc = spawner:K2_GetActorLocation() end)
    if not loc then return {} end

    local AVU = require("AnteUtils.AVUtils")
    local VariantTag = require("AnteVariants.VariantTag")
    local vname = type(rules.Variant) == "string" and rules.Variant or nil
    local def = vname and VARIANTS[vname]

    local out = {}
    for _, npc in ipairs(AVU.GetNearbyNpcs(loc, HEAL_SCAN_RADIUS)) do
        local row = Utils.GetActorRowName(npc)
        if row and ((def and VariantTag.AcceptsBase(def, row))
                or (rules.SpawnAs and row == rules.SpawnAs)
                or (rules.MultiVariants and rules.MultiVariants[row] ~= nil)) then
            out[#out + 1] = npc
        end
    end
    return out
end

local function healSpawnerNpcs(spawner, spawnerName, rules, force)
    -- NoPatrol rides this walk too: it is a CONTROLLER property, so it does not survive a
    -- save (the restored NPC is possessed fresh at the stock PatrolFrequency) and TrySpawnNPC
    -- never fires for that body. Reusing the walk costs nothing - no extra scan, same rate limit.
    if not (rules and (rules.Variant or rules.MultiVariants or rules.NoPatrol)) then return end
    if IsNotValid(spawner) then return end

    local VariantTag = require("AnteVariants.VariantTag")   -- lazy: load-cycle risk at file scope

    local now = os.time()
    local last = healCheckedAt[spawnerName]
    if not force and last and (now - last) < HEAL_RECHECK_SEC then return end
    healCheckedAt[spawnerName] = now

    local npcs = HOOKS.GetSpawnerNpcs(spawner)
    if #npcs == 0 then npcs = healFallbackScan(spawner, rules) end

    for i = 1, #npcs do
        local npc = npcs[i]
        -- IsActorValid = streamed-in too: MutateActor just bails on an unstreamed body;
        -- a later pass retries once its sublevel is live.
        if npc and Utils.IsActorValid(npc) then
            local dead = false
            pcall(function() dead = npc.IsDead end)

            -- Cheap and unconditional (see the header note): re-pin every live body,
            -- mutated or not.
            --   * Writing the same two values again is a no-op, so there is no "already done"
            --     set to keep - and re-asserting beats ClearStuckState's patrol-timer rewind.
            if (not dead) and rules.NoPatrol then applyNoPatrol(npc) end

            -- "Did WE already mutate this?" = does it carry our VariantTag (the WalkSpeed
            -- fraction the STATS step stamps LAST)?
            --   * That is the authoritative marker - the same one clients decode - and it is
            --     ATOMIC with the mutation: a body that finished STATS is both re-statted AND
            --     tagged; one that bailed is neither.
            --   * NEVER substitute a `not VARIANTS[Utils.GetActorName(npc)]` DisplayName test -
            --     a BASE whose own DisplayName collides with a registered variant name reads as
            --     "already mutated" and is silently never healed. See
            --     [[anteup2-volatile-base-signal-pests]].
            --   * (The Variant/MultiVariants test short-circuits a NoPatrol-ONLY spawner out of
            --     the mutation half - HandleSpawnedActor would resolve to "" and do nothing anyway.)
            if (not dead) and (rules.Variant or rules.MultiVariants) and VariantTag.Decode(npc) == nil then
                local fn
                pcall(function() fn = npc:GetFullName() end)
                local queuedAt = fn and healQueued[fn]
                if not (queuedAt and (now - queuedAt) < HEAL_MUTATE_GRACE_SEC) then
                    local rowName = Utils.GetActorRowName(npc)
                    local variantName = rowName and NPCM.HandleSpawnedActor(spawner, npc, rowName, i)
                    if variantName then
                        if fn then healQueued[fn] = now end
                        LogDebug(string.format("[%s] healed save-restored %s => %s",
                            spawnerName, rowName, variantName), SETTINGS.DEBUG_SPAWNERS)
                    end
                end
            end
        end
    end

    -- Bound healQueued: entries only matter inside the grace window.
    local n = 0
    for _ in pairs(healQueued) do n = n + 1 end
    if n > 256 then
        for fn, t in pairs(healQueued) do
            if (now - t) >= HEAL_MUTATE_GRACE_SEC then healQueued[fn] = nil end
        end
    end
end


-- [InitMod, authority] Apply spawner rules to spawners that already exist
-- (their ReceiveBeginPlay fired before our hook registered).
--   * A spawner's first spawn cycle may have fired before this runs; those NPCs keep
--     the original type (NpcManager skips mutating them via the def.Base check).
--   * restoreRowsFirst is for /reloadspawns (SpawnerReload): put each rewritten spawner's
--     ORIGINAL rows back before re-applying, so the new rules map from vanilla instead of
--     from the last edit's output. Phased entries already do this per band change.
function HOOKS.ApplySpawnOverrides(restoreRowsFirst)
    local spawners = FindAllOf(SPAWNER_CLASS_NAME)
    if not spawners then return end

    for _, spawner in ipairs(spawners) do
        if IsValid(spawner) then
            local spawnerName = Utils.GetSpawnerName(spawner)
            if restoreRowsFirst and spawnerName then restoreSpawnRows(spawner, spawnerName) end
            local rules = spawnerName and SPAWNERDATA.Rules(spawnerName)
            applySpawnerRules(spawner, spawnerName, rules)
            -- (No asset warm - see the ReceiveBeginPlay hook note; it also put cold loads into
            -- the world-INIT window, a prime suspect window for AVs.)
        end
    end
end


-- Validate that every Variant / MultiVariants name in SpawnerData resolves to a
-- registered variant. Run once on authority at init.
--   * A typo (e.g. "ChonkyPest" vs "Chonky Pest") otherwise fails SILENTLY - the name
--     resolves to nil and the NPC just spawns vanilla.
function HOOKS.ValidateSpawnerData()
    local bad = 0

    local function checkName(vname, where)
        if vname and vname ~= "" and not VARIANTS[vname] then
            bad = bad + 1
            LogBad(string.format("SpawnerData: unknown variant '%s' at [%s] - will spawn vanilla", vname, where))
        end
    end

    -- Variant / MultiVariants values are plain STRINGS (story banding moved to Phases). A
    -- table here is a missed conversion of the old banded-list form, so say that instead of
    -- silently walking past it.
    local function checkSpec(spec, where)
        if type(spec) == "table" then
            bad = bad + 1
            LogBad(string.format(
                "SpawnerData: [%s] Variant is a TABLE - the old banded-list form is gone, use Phases", where))
            return
        end
        checkName(spec, where)   -- string or nil
    end

    -- Every prop SD.Spawners understands. A key outside this set is a TYPO, and a typo'd
    -- gate is the worst kind: `MinStory=41` parses, reads as nil, and the band is silently
    -- UNGATED - so the last band wins from StoryProgress 0 and the spawner is wrong for the
    -- whole run. (MinStory is a real name, just a different system: the AVU.DropLoot gate.
    -- SpawnerData's gate is StoryMin.)
    local KNOWN_PROPS = {
        Variant = true, MultiVariants = true, Count = true, FillSpacingSec = true,
        WipeCooldownHours = true, VariantLimit = true, CooldownDays = true, SpawnAs = true,
        ForceSpawn = true, Disabled = true, NoPatrol = true, StoryMin = true, StoryMax = true,
        SpawnRange = true, Phases = true, Hard = true, NoLossFlag = true,
    }

    -- SpawnAs must name a real DT_NPCList row AND, when the band also names a Variant, a row
    -- that variant will actually accept - otherwise the body spawns and never mutates
    -- (NpcManager's AcceptsBase check drops it) and the band looks half-applied in game.
    local function checkSpawnAs(rules, where)
        local rows = {}
        if type(rules.SpawnAs) == "string" then
            rows[#rows + 1] = rules.SpawnAs
        elseif type(rules.SpawnAs) == "table" then
            for _, to in pairs(rules.SpawnAs) do rows[#rows + 1] = to end
        end

        -- WARN, not an error: ENUMS.NpcClasses is a CURATED subset of DT_NPCList (roughly
        -- 100 of 120 rows), so a legitimate row we never needed a class path for lands here
        -- too. Still worth saying - the misses it does catch are the expensive kind: a
        -- VARIANT name typed into the SpawnAs slot (SpawnAs="Telepest") writes a row that
        -- DT_NPCList has never heard of, and that spawner then emits NOTHING, silently.
        for _, row in ipairs(rows) do
            if not ENUMS.NpcClasses[row] then
                LogBad(string.format(
                    "SpawnerData: [%s] SpawnAs '%s' is not in ENUMS.NpcClasses - verify it is a real "
                    .. "DT_NPCList row (a variant name here = the spawner emits nothing)", where, row))
            end
        end

        -- Pair check: only meaningful for the single-string form (a map form deliberately
        -- rewrites several rows, and MultiVariants keys each to its own variant).
        local def = type(rules.SpawnAs) == "string" and type(rules.Variant) == "string"
                    and VARIANTS[rules.Variant]
        if not def then return end

        local accepts = (def.Base == rules.SpawnAs)
        for _, alt in ipairs(def.AltBases or {}) do
            if alt == rules.SpawnAs then accepts = true; break end
        end
        if not accepts then
            bad = bad + 1
            LogBad(string.format(
                "SpawnerData: [%s] SpawnAs '%s' but '%s' wants base '%s' - it will spawn UNMUTATED",
                where, rules.SpawnAs, rules.Variant, tostring(def.Base)))
        end
    end

    -- One band's worth of props (also used for the un-phased top level).
    local function checkRules(rules, where)
        if type(rules) ~= "table" then return end
        checkSpec(rules.Variant, where)
        if type(rules.MultiVariants) == "table" then
            for rowName, spec in pairs(rules.MultiVariants) do
                checkSpec(spec, where .. " " .. tostring(rowName))
            end
        end
        checkSpawnAs(rules, where)
        for k in pairs(rules) do
            if type(k) == "string" and not KNOWN_PROPS[k] and k ~= "PhaseIndex" and k ~= "Phased" then
                bad = bad + 1
                LogBad(string.format("SpawnerData: [%s] unknown prop '%s' - typo? (gates are StoryMin/StoryMax)",
                    where, k))
            end
        end
        -- Positional elements = a missing brace pair. `Phases = { {...}, {...} }` written as
        -- `Phases = {...}, {...}` is LEGAL Lua: Phases gets only the first band and the rest
        -- become array items on the entry, so NO band ever wins and the spawner runs vanilla
        -- forever. Silent without this check.
        if #rules > 0 then
            bad = bad + 1
            LogBad(string.format(
                "SpawnerData: [%s] has %d stray positional table(s) - 'Phases =' is missing its outer { }",
                where, #rules))
        end
    end

    -- The hard-mode fallback map is names too - a typo here spawns vanilla just as silently.
    for rowName, vname in pairs(SPAWNERDATA.HardVariants or {}) do
        checkName(vname, "HardVariants." .. tostring(rowName))
        if not ENUMS.NpcClasses[rowName] then
            bad = bad + 1
            LogBad(string.format(
                "SpawnerData: HardVariants key '%s' is not in ENUMS.NpcClasses - not a real row?", tostring(rowName)))
        end
    end

    -- RAW entries on purpose: a typo in a band that is not open yet must still be caught now,
    -- not whenever the run happens to reach that StoryProgress.
    for spawnerName, rules in pairs(SPAWNERDATA.Spawners) do
        if type(rules) == "table" then
            checkRules(rules, spawnerName)
            if rules.Phases and #rules.Phases == 0 then
                bad = bad + 1
                LogBad(string.format(
                    "SpawnerData: [%s] Phases holds ONE band, not a list - missing the outer { }", spawnerName))
            end
            for i, phase in ipairs(rules.Phases or {}) do
                checkRules(phase, string.format("%s phase %d", spawnerName, i))
            end
            -- An entry that is ONLY Phases and has no ungated band spawns vanilla until the
            -- first StoryMin - almost always a missing floor rather than an intent.
            if rules.Phases and #rules.Phases > 0 then
                local floor = false
                for _, phase in ipairs(rules.Phases) do
                    if not phase.StoryMin then floor = true; break end
                end
                if not floor and not rules.Variant and not rules.MultiVariants then
                    LogBad(string.format(
                        "SpawnerData: [%s] no ungated phase - spawns vanilla below StoryMin %s",
                        spawnerName, tostring(rules.Phases[1].StoryMin)))
                end
            end
        end
    end

    -- PlacedSpawns. Same silent-failure argument, one extra key: a plain placement's Base
    -- must be a NpcClasses row or NpcSpawner can't resolve a class for it - and unlike a
    -- spawner rule that mistake only surfaces when someone walks within 120m of the coord.
    for key, cfg in pairs(SPAWNERDATA.PlacedSpawns or {}) do
        if type(cfg) == "table" then
            checkSpec(cfg.Variant, "placed " .. tostring(key))
            if cfg.Base and not ENUMS.NpcClasses[cfg.Base] then
                bad = bad + 1
                LogBad(string.format("SpawnerData: unknown Base row '%s' at placed [%s] - nothing will spawn",
                    tostring(cfg.Base), tostring(key)))
            end
            if not (cfg.Variant or cfg.Base) then
                bad = bad + 1
                LogBad(string.format("SpawnerData: placed [%s] has neither Variant nor Base - inert", tostring(key)))
            end
            -- Phases is a SD.Spawners feature. PlacedSpawns reads cfg.Variant straight into
            -- AVU.SummonVariant (VARIANTS[name]), so a banded placement would resolve to nil
            -- and spawn nothing, silently. SD.Resolve is entry-keyed and would work here - the
            -- opt-in is the READ SITES in ModuleStory/EventUtils, which is the actual work.
            if cfg.Phases then
                bad = bad + 1
                LogBad(string.format(
                    "SpawnerData: placed [%s] has Phases - NOT supported on PlacedSpawns, it will spawn nothing",
                    tostring(key)))
            end
        end
    end

    -- Signed keys are folded to abs at load (SpawnerData); a collision means the abs twin already
    -- carried a rule, so the signed one was DROPPED rather than silently overwriting it.
    for _, key in ipairs(SPAWNERDATA.KeyCollisions or {}) do
        LogBad(string.format(
            "SpawnerData: signed key [%s] collides with its abs twin [%s] - the signed rule is IGNORED",
            key, (key:gsub("-", ""))))
    end

    if bad > 0 then
        LogBad(string.format("SpawnerData: %d unknown variant name(s) above - check spelling/registration", bad))
    elseif #(SPAWNERDATA.KeyCollisions or {}) == 0 then
        Utils.Log("SpawnerData variant names OK")
    end
end


-- [reset-cooldowns debug command] Clear the runtime phase/wipe state on every Count spawner
-- so they drop back to "fill" and refill NOW.
--   * The next IsOnCooldown heartbeat re-inits the spawner to phase=fill and restores its
--     cap to Count.
--   * Cleared IN PLACE (keep the hook's upvalue valid).
function HOOKS.ResetCountCooldowns()
    for k in pairs(countState) do countState[k] = nil end
    -- Also drop persisted (cross-session) wipe cooldowns so the reset is total.
    local book = wipeBook()
    if book then
        for k in pairs(book) do book[k] = nil end
        saveCooldowns()
    end
end


-- Apply spawner-config rules to ONE spawner (name lookup + rules).
--   * Public so the optional early-config watcher (RegisterEarlyConfig) can configure
--     a spawner the moment it's constructed.
function HOOKS.ConfigureSpawner(spawner)
    if IsNotValid(spawner) then return end
    local spawnerName = Utils.GetSpawnerName(spawner)
    if not spawnerName then return end

    applySpawnerRules(spawner, spawnerName, SPAWNERDATA.Rules(spawnerName))
end

-- [OPTIONAL] SETTINGS.CORE.EARLY_SPAWNER_CONFIG: configure a spawner the moment it is constructed,
-- ahead of its first TrySpawnNPC - the ReceiveBeginPlay hook misses the near spawners of a level
-- that was already streaming when the hook armed.
--   * The notify fires INSIDE StaticConstructObject, on whichever thread builds the actor (the
--     async loader for a streamed sublevel) and before the actor has a transform. Configuring it
--     right there read every spawner as "0,0,0" - no rule ever matched, only the NoEnd clamp fired
--     - and made Blueprint calls from the loader thread. So the body is queued to the game thread:
--     ExecuteInGameThread from the construct hook is a plain C++ push, and the callback runs a
--     frame later on the game thread with the transform in place.
--   * Authority only. A client's spawners are the server's copies; role is unknown until InitMod,
--     so a client's earliest spawners still get one harmless game-thread pass.
local earlyConfigArmed = false
function HOOKS.RegisterEarlyConfig()
    if earlyConfigArmed then return end
    earlyConfigArmed = true

    NotifyOnNewObject(SPAWNER_CLASS_PATH, function(obj)
        ExecuteInGameThread(function()
            if STATE.Role == "CLIENT" then return end
            local ok, err = pcall(function() HOOKS.ConfigureSpawner(obj) end)
            if not ok then LogBad("EarlyConfig error: " .. tostring(err)) end
        end)
    end)
    Utils.Log("SpawnerHooks - early spawner config armed (NotifyOnNewObject -> game thread)")
end


-- ================================================================
-- SECURITY REAPER interception - the director's NPCSpawn_Reaper spawners.
-- SpawnerData can't carry this rule: it is keyed by COORDINATES and Security places 29
-- reaper points sharing one intent. A dedicated hook on the subclass's own TrySpawnNPC
-- also side-steps the open question of whether the parent hook below ever fires for the
-- subclass's super-call - and since no coordinate entries exist for these spawners, the
-- parent path resolves to no variant, so the two can never double-mutate.
--   * Armed lazily from ReceiveBeginPlay: the class only exists once a reaper spawner
--     streams in, and BeginPlay precedes any spawn by construction.
--   * Both slots (single-callback registrations on this family have shipped silently
--     dead); the per-spawn stamp absorbs a double fire.
--   * The scripted first-encounter spawner (SpawnedViaTrigger) stays vanilla.
-- ================================================================
local REAPER_SPAWN_HOOK =
    "/Game/Blueprints/Environment/Spawns/NPCSpawn_Reaper.NPCSpawn_Reaper_C:TrySpawnNPC"
local reaperHookArmed = false
local lastReaperSpawnKey   -- the PRE and POST slots fire for the same spawn

local function onReaperSpawn(self, _IsNight, _Force, _CheckOnly, Success, SpawnedNPC)
    if not (STATE.ModEnabled and Utils.IsAuthority()) then return end
    local okSpawn
    pcall(function() okSpawn = Success:Get() end)
    if not okSpawn then return end
    local actor
    pcall(function() actor = SpawnedNPC:Get() end)
    if Utils.IsActorInvalid(actor) then return end

    local key = Utils.ActorKey(actor)
    if not key or key == lastReaperSpawnKey then return end
    lastReaperSpawnKey = key

    local viaTrigger = false
    pcall(function() viaTrigger = self:Get().SpawnedViaTrigger == true end)
    if viaTrigger then return end
    if Utils.GetActorRowName(actor) ~= "Reaper" then return end

    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) then return end
        NPCM.MutateActor("Security Reaper", actor, { FromSpawner = true })
    end, 500)
end

local function armReaperSpawnerHook(spawner)
    if reaperHookArmed then return end
    local cls
    pcall(function() cls = spawner:GetClass():GetFName():ToString() end)
    if not cls or cls:lower() ~= "npcspawn_reaper_c" then return end
    reaperHookArmed = true
    local ok, err = pcall(RegisterHook, REAPER_SPAWN_HOOK, onReaperSpawn, onReaperSpawn)
    if ok then
        Utils.Log("SpawnerHooks - Security Reaper spawner hook armed")
    else
        Utils.LogBad("SpawnerHooks - Security Reaper spawner hook FAILED: " .. tostring(err))
    end

    -- A reaper RESTORED from the world save never goes through TrySpawnNPC, so the first one
    -- after a load can be vanilla until its next despawn cycle (observed as "sometimes not
    -- mutating" after a full restart). The director's own pointer names it - heal it once here.
    Utils.QueueWork(function()
        if not STATE.ModEnabled then return end
        local VariantTag = require("AnteVariants.VariantTag")   -- lazy: load-cycle risk at file scope
        local r
        pcall(function() r = Utils.GetReaperDirector().SpawnedReaper end)
        if Utils.IsActorInvalid(r) then return end
        if Utils.GetActorRowName(r) ~= "Reaper" or VariantTag.Decode(r) ~= nil then return end
        Utils.Log("SpawnerHooks - healing a save-restored vanilla Security Reaper")
        NPCM.MutateActor("Security Reaper", r, { FromSpawner = true })
    end, 4000)
end


function HOOKS.Register()

    -- ================================================================
    -- TrySpawnNPC - fires when a spawner creates (or fails to create)
    -- an NPC. Hook callbacks run on the game thread.
    -- ================================================================
    local hook = "/Game/Blueprints/Environment/Spawns/Abiotic_NPCSpawn_ParentBP.Abiotic_NPCSpawn_ParentBP_C:TrySpawnNPC"
    RegisterHook(hook,
        function(self, IsNight, Force, CheckOnly, Success, SpawnedNPC, DebugMsg, Response)

            if not (STATE.ModEnabled and Utils.IsAuthority()) then return end

            local spawner = self:Get()
            if IsNotValid(spawner) then return end

            -- DIAGNOSTIC: show the reason why a configured spawner failed to spawn
            --   e.g. On Cooldown (N days left), Global NPC Cap Reached, Blocked by X,
            --        Cap Reached, Could not find valid spawn location, World Flag, etc
            -- 
            if not Success:Get() then
                if SETTINGS.DEBUG_SPAWNERS then
                    local sName = Utils.GetSpawnerName(spawner)
                    if sName and SPAWNERDATA.Spawners[sName] then
                        local ok, reason = pcall(function()
                            local d = DebugMsg and DebugMsg:Get()
                            if d == nil then return "?" end
                            if type(d) == "userdata" and d.ToString then return d:ToString() end
                            return tostring(d)
                        end)
                        reason = (ok and reason) or "?"
                        if blockedReason[sName] ~= reason then
                            blockedReason[sName] = reason
                            LogDebug(string.format("[%s] spawn blocked: %s", sName, reason), true)
                        end
                    end
                end
                return
            end

            local actor = SpawnedNPC:Get()
            if Utils.IsActorInvalid(actor) then return end

            local spawnerName = Utils.GetSpawnerName(spawner)

            -- It spawned, so clear any "blocked" reason we'd logged for it.
            if spawnerName then blockedReason[spawnerName] = nil end

            -- Cumulative fill tracking (Count spawners): count each real spawn toward this
            -- group's quota, so the group latches "full" after Count spawns even if the
            -- player is killing members DURING the fill.
            --   * Only the "fill" phase spawns (full/wipe hold cap=0), so this only ever
            --     bumps there. See the applyCount / IsOnCooldown headers.
            if spawnerName then
                local st = countState[spawnerName]
                if st and st.phase == "fill" then st.spawned = (st.spawned or 0) + 1 end
            end

            -- NoPatrol: independent of the variant decision, so it runs BEFORE the
            -- early-outs below (a VariantLimit-capped or unmutated body still holds its spot).
            if spawnerName then
                local rules = SPAWNERDATA.Rules(spawnerName)
                if rules and rules.NoPatrol then applyNoPatrol(actor) end
            end

            -- Base identity = game row name (stable, not our DisplayName)
            local rowName = Utils.GetActorRowName(actor)
            if not rowName then return end

            -- VariantLimit uses the spawner's own running count (1,2,..,Count as the
            -- native fills the group), so "first X are variants" works natively.
            local spawnedCount = spawner:GetCurrentSpawnedCount(true) or 1
            if spawnerName and not countConfig[spawnerName] and SPAWNERDATA.Rules(spawnerName) then
                local now = os.time()
                local prevAt, prevCount = lastSpawnAt[spawnerName], lastSpawnCount[spawnerName]
                local refill = streamInMs[spawnerName] and lastSpawnMs[spawnerName]
                    and streamInMs[spawnerName] > lastSpawnMs[spawnerName]
                if prevAt and (now - prevAt) < VANISH_WINDOW_SEC and spawnedCount <= (prevCount or 0) then
                    if refill then
                        local TAP = require("AnteCore.TestTap")
                        if TAP.on then TAP.Count("refill", spawnerName, rowName) end
                        LogDebug(string.format("[%s] refilled %s %ds after its last spawn: its level streamed out "
                            .. "and back", spawnerName, rowName, now - prevAt), SETTINGS.DEBUG_SPAWNERS)
                    else
                        local dist = "?"
                        pcall(function()
                            local _, dSq = Utils.NearestPlayer(spawner:K2_GetActorLocation())
                            if dSq then dist = string.format("%.0fm", math.sqrt(dSq) / 100) end
                        end)
                        LogBad(string.format("[%s] re-spawned %s %ds after its last spawn at the same live count (%d) "
                            .. "with no kill cooldown and no stream-out between - the previous body VANISHED (out "
                            .. "of the level, despawned...). Nearest player %s",
                            spawnerName, rowName, now - prevAt, spawnedCount, dist))
                    end
                end
                lastSpawnAt[spawnerName], lastSpawnCount[spawnerName] = now, spawnedCount
                lastSpawnMs[spawnerName] = Utils.NowMs()
            end
            local t0 = PROF.Begin()
            local variantName = NPCM.HandleSpawnedActor(spawner, actor, rowName, spawnedCount)
            if variantName then healMarkQueued(actor) end   -- heal walks skip the stagger window
            PROF.EndAs(t0, "SpawnerHooks.HandleSpawnedActor")

            if SETTINGS.DEBUG_SPAWNERS then
                LogDebug(string.format("[%s] spawned %s => %s (%d)",
                    spawnerName or "?", rowName, variantName or rowName, spawnedCount), true)
            end
        end)

    -- ================================================================
    -- ReceiveBeginPlay - spawner comes alive (level streamed in).
    -- Apply SpawnAs row swaps + Count cap before its first spawn cycle.
    -- ================================================================
    hook = "/Game/Blueprints/Environment/Spawns/Abiotic_NPCSpawn_ParentBP.Abiotic_NPCSpawn_ParentBP_C:ReceiveBeginPlay"
    RegisterHook(hook,
        function(self)
            -- Authority checked per call: these hooks outlive a single-player world, and a spawner's
            -- BeginPlay still fires here after the same process joins a server as a client.
            if not (STATE.ModEnabled and Utils.IsAuthority()) then return end

            local spawner = self:Get()
            if IsNotValid(spawner) then return end

            armReaperSpawnerHook(spawner)   -- Security Reaper: see the block above Register()

            local spawnerName = Utils.GetSpawnerName(spawner)
            if not spawnerName then return end
            streamInMs[spawnerName] = Utils.NowMs()   -- the vanish detector's stream-out test

            local rules = SPAWNERDATA.Rules(spawnerName)
            local t0 = PROF.Begin()
            applySpawnerRules(spawner, spawnerName, rules)
            PROF.EndAs(t0, "SpawnerHooks.applySpawnerRules(BeginPlay)")

            -- Save-restored NPCs re-link into CurrentNPCs around stream-in; give the save
            -- system a beat, then heal any plain body.
            --   * Forced past the heartbeat rate limit so a fresh stream-in always gets one
            --     prompt walk.
            --   * healSpawnerNpcs no-ops for unconfigured spawners.
            --   * The walk holds this spawner's wrapper for 5s, and a player who hops out again
            --     inside that window frees it (IsValid passes a freed slot, and a spawner has no
            --     EndPlay to stamp). So gate on its COORDS, read now while it is live: a sector
            --     that is no longer loaded means the wrapper is not safe to touch. The heartbeat
            --     heal runs on a live spawner and picks up anything skipped here.
            --   * (NoPatrol is in this list for the same reason it's in healSpawnerNpcs'
            --     guard: a save-restored body needs re-pinning and never sees TrySpawnNPC.)
            if rules and (rules.Variant or rules.MultiVariants or rules.NoPatrol) then
                local sloc   -- plain numbers: nothing engine-owned is held across the wait
                pcall(function()
                    local l = spawner:K2_GetActorLocation()
                    sloc = { X = l.X, Y = l.Y, Z = l.Z }
                end)
                Utils.QueueWork(function()
                    if not STATE.ModEnabled then return end
                    if not Utils.IsLocationLoaded(sloc) then return end
                    healSpawnerNpcs(spawner, spawnerName, rules, true)
                end, 5000)
            end
            -- (NO asset warm here anymore - run-6 profiling proved it net-negative.
            --   * A warm at stream-in doesn't PIN, and native spawners fire seconds-to-minutes
            --     later, so the assets were GC'd again before the spawn - we paid the warm AND
            --     the pipeline load.
            --   * Placed spawns keep their warm: their arrival->spawn gap is seconds.
            --   * See [[anteup2-projectile-preload-gc]] "preload beats GC by timing, not pinning".)
        end)

    -- ================================================================
    -- IsOnCooldown - state-machine DRIVER for our Count spawners.
    --   * Does NOT override the return value (no reliance on UE4SS return-override); it runs
    --     on every spawn evaluation (the AIDirector calls IsOnCooldown even when the cap is
    --     reached) and uses that as a heartbeat to drive the group's lifecycle by toggling
    --     the cap (NPCsAllowedFromSpawn) between Count and 0:
    --     fill -> full -> wipe -> fill. See the applyCount header for the model.
    --   * The native SECONDS cooldown (SpawnCooldown_Default, set in applyCount) handles the
    --     gap between NPCs while filling; this hook handles "stop refilling once full" and
    --     the long post-wipe cooldown.
    --   * NonCount spawners (no countConfig entry) are untouched.
    -- ================================================================
    -- Extracted to a named local so the profiler can time the WHOLE heartbeat: it fires
    -- per spawner per AI-Director evaluation, so its AGGREGATE cost in a spawner-dense
    -- level (Labs Pens+Lobby, Adjustment 1F+2F) is what matters, not any single call.
    local function cooldownBeat(spawner)
            if IsNotValid(spawner) then return end

            local name = Utils.GetSpawnerName(spawner)
            if not name then return end

            -- Story window (StoryMin/StoryMax) - re-checked live, because StoryProgress
            -- moves while a level stays streamed in.
            --   * Closed -> hold the cap at 0 and stop here (a gated Count spawner keeps its
            --     phase; it resumes where it left off).
            --   * Just re-opened -> re-apply the whole rule set, which restores the cap and
            --     re-inits Count.
            local rules = SPAWNERDATA.Rules(name)
            if rules and (rules.StoryMin or rules.StoryMax) then
                if not storyAllows(rules) then
                    storyGateOff(spawner, name)
                    return
                elseif storyCap[name] ~= nil then
                    applySpawnerRules(spawner, name, rules)
                end
            end

            -- Phases - the band in force changed under a spawner that is already live, so the
            -- whole rule set (SpawnAs rows, Count, Disabled, ...) has to be re-applied.
            --   * Cheap to test: PhaseIndex is nil on every un-phased entry, and SD.Rules
            --     memoises the merge against a global story epoch.
            --   * The Count group is reset with it so the new band FILLS rather than inheriting
            --     the old band's quota. Bodies already out are left alone - they belong to the
            --     previous band and are unloaded the next time players leave the area.
            if rules and rules.Phased and appliedPhase[name] ~= (rules.PhaseIndex or 0) then
                LogDebug(string.format("[%s] story band -> phase %s (was %s) - re-applying rules",
                    name, tostring(rules.PhaseIndex or "none"), tostring(appliedPhase[name])),
                    SETTINGS.DEBUG_SPAWNERS)
                countConfig[name], countState[name] = nil, nil
                applySpawnerRules(spawner, name, rules)   -- stamps appliedPhase + restores rows

                -- The floating debug label was written from the OLD band, so refresh it.
                if SETTINGS.DEBUG_SHOW_SPAWNERS then
                    pcall(require("AnDebug.DebugUtils").ShowSpawners, spawner)
                end
            end

            -- Save-restore heal catch-all: a body re-linked into CurrentNPCs AFTER the
            -- stream-in walk (late save relink) still gets re-mutated.
            --   * Rate-limited to one walk per spawner per HEAL_RECHECK_SEC; unconfigured
            --     spawners early-out on two table reads.
            healSpawnerNpcs(spawner, name, rules)

            local cfg = countConfig[name]
            if not cfg then return end   -- not one of our Count spawners

            -- CheckDead=true -> LIVING count only (false returns the raw tracked array incl.
            -- not-yet-cleaned corpses, which would hide a wipe while bodies linger).
            local ok, cur = pcall(function() return spawner:GetCurrentSpawnedCount(true) end)
            if not ok or not cur then return end

            local st = countState[name]
            if not st then st = { phase = "fill", spawned = 0 }; countState[name] = st end

            local function setCap(v)
                if st.cap ~= v then
                    st.cap = v
                    pcall(function() spawner.NPCsAllowedFromSpawn = v end)
                end
            end

            if st.phase == "wipe" then
                local now = Utils.GetGameHours()
                if st.wipeAt and now and now >= st.wipeAt then
                    st.phase, st.wipeAt, st.spawned = "fill", nil, 0   -- reset the fill quota for the new cycle
                    setCap(cfg.count)              -- long cooldown elapsed -> refill the group
                    clearWipe(name)                -- drop the persisted entry
                    LogDebug(string.format("[%s] wipe cooldown done -> refilling", name), SETTINGS.DEBUG_SPAWNERS)
                else
                    setCap(0)                      -- still on cooldown (re-stream may have reset the cap to Count)
                end

            elseif st.phase == "full" then
                setCap(0)                          -- group built -> partial deaths do NOT refill
                if cur <= 0 then
                    -- cur==0 means KILLED *or* just STREAMED-OUT (the AIDirector drops
                    -- streamed-out NPCs from the spawner's list as the player leaves the zone).
                    --   * Only treat it as a real wipe if a player is in combat range;
                    --     otherwise HOLD "full" - the NPCs persist/re-stream, and starting a
                    --     cooldown here would refill ON TOP of them when the player returns
                    --     (the respawn-on-return bug).
                    local near = false
                    local okp, sloc = pcall(function() return spawner:K2_GetActorLocation() end)
                    if okp and sloc then near = Utils.IsPlayerNearby(sloc, WIPE_REQUIRE_PLAYER_WITHIN) end
                    local now = near and Utils.GetGameHours()
                    if now then
                        st.phase  = "wipe"
                        st.wipeAt = now + cfg.wipe
                        persistWipe(name, st.wipeAt)   -- survive a relaunch
                        LogDebug(string.format("[%s] group wiped -> %gh cooldown (ready at day %d %02d:00)",
                            name, cfg.wipe, math.floor(st.wipeAt / 24), math.floor(st.wipeAt % 24)),
                            SETTINGS.DEBUG_SPAWNERS)
                    end
                end

            else  -- "fill"
                setCap(cfg.count)                  -- native fills one per `fill` sec up to Count
                -- Latch full on the CUMULATIVE spawn count (st.spawned, bumped per spawn in
                -- the TrySpawnNPC hook) so a group emptied as fast as it fills still latches.
                --   * cur>=Count is the fast path when the whole group is alive at once
                --     (e.g. an already-full group re-observed after a re-stream, where
                --     st.spawned reset to 0).
                if cur >= cfg.count or (st.spawned or 0) >= cfg.count then
                    st.phase = "full"
                    setCap(0)
                    LogDebug(string.format("[%s] filled to %d (live %d) -> holding until wiped",
                        name, cfg.count, cur), SETTINGS.DEBUG_SPAWNERS)
                end
            end
    end

    RegisterHook(IS_ON_COOLDOWN_HOOK,
        function(self)
            if not (STATE.ModEnabled and Utils.IsAuthority()) then return end
            local t0 = PROF.Begin()
            cooldownBeat(self:Get())
            PROF.EndAs(t0, "SpawnerHooks.cooldownBeat")
        end)

    HOOKS.ValidateSpawnerData()   -- warn about misspelled variant names (silent otherwise)

    Utils.Log("SpawnerHooks registered")
end

return HOOKS
