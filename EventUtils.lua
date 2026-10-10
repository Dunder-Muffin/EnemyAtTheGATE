-- =======================================================================
-- EventUtils (EVU, AUTHORITY) - the support stack under ModuleStory.
-- Two things live here: SPAWN/AUDIO helpers used by ModuleStory/Events set-pieces, and
-- PLACED SPAWNS - the synthetic-spawner system (SpawnerData.PlacedSpawns), ticked from
-- StoryManager.Tick. Player/buff/generic-NPC-op helpers live in Utils/AVU instead.
-- Deep: AnNotes/Modules/EventUtils.md (PlacedSpawns engine internals), AnNotes/AnteSystems/PlacedSpawns.md
-- (the data author's view).
--
-- THREADING: callers run on the WorkQueue drain (inside the ProcessTick hook), so nothing
-- here may blocking-load. Spawns go through NpcSpawner (off-hook); audio is LoadAsync'd.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local UEHelpers = require("UEHelpers")
local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local ASSETS = require("AnteCore.AssetManager")
local NpcSpawner = require("AnteCore.NpcSpawner")
local FileIO = require("AnteCore.FileIO")
local SPAWNERDATA = require("AnteData.SpawnerData")
local ENUMS = require("AnteData.Enums")
local SCHEMA = require("AnteData.Schema")
local PROF = require("AnDebug.Profiler")
-- VARIANTS / NpcManager are LAZY (required inside SpawnOne): they pull in the variant defs, which
-- reach back into ModuleStory, so a top-level require here risks a load-time cycle.

local LogDebug = Utils.LogDebug
local LogBad = Utils.LogBad

local EVU = {}


-- =======================================================================
-- MANUAL-TRIGGER LATCH WAIVER
-- A manual trigger (the "/event" command, the keybind group) is a DEBUG trigger, so it waives the
-- "already happened" latches the story gates rely on - otherwise re-testing a set-piece means
-- clearing a flag and restarting the game. Lives here rather than in Events because the set-piece
-- files ask the question and only Events.RunManual answers it.
--   * Latches only. The area/streaming guards and the "already running" guards are NOT waived:
--     those exist to stop a crash or a stacked run, not a repeat.
-- =======================================================================

-- True only for the SYNCHRONOUS body of a manual run (Events.RunManual brackets it).
local forced = false

function EVU.SetForced(on)
    forced = on == true
end

-- Should a once-ever latch stop this run? Waived for a manual trigger, and the log says which
-- happened either way - a set-piece that silently declines to run is the thing being fixed here.
function EVU.LatchStops(done, what, why)
    if not done then return false end
    if forced then
        Utils.Log(what .. " - " .. why .. ", re-running anyway (manual trigger)")
        return false
    end
    Utils.Log(what .. " - " .. why)
    return true
end


-- =======================================================================
-- SPAWN + AUDIO building blocks (used by the ModuleStory set-pieces)
-- =======================================================================

-- Play a 2D announcement on the local renderer.
--   * Host/SP hears it. A pure MP client would need a ClientEffects-style trigger (TODO).
--   * `cutoffMs` ~= nil builds a stoppable component and stops it after that long, for clipping
--     a long cue. Otherwise fire-and-forget the whole thing.
--   * LoadAsync first: we're on the hook drain, and a blocking load here would deadlock.
function EVU.PlayAnnouncement(path, cutoffMs)
    ASSETS.LoadAsync({ path }, function()
        local gs = ASSETS.GetIfValid("/Script/Engine.Default__GameplayStatics")
        local world = Utils.GetWorld()
        local sound = ASSETS.GetIfValid(path)
        if not gs or IsNotValid(world) or IsNotValid(sound) then return end

        if cutoffMs then
            local comp
            -- (World, Sound, Vol, Pitch, StartTime, Concurrency, bPersistAcrossLevel, bAutoDestroy)
            pcall(function() comp = gs:CreateSound2D(world, sound, 1.0, 1.0, 0.0, nil, false, false) end)
            if IsValid(comp) then
                pcall(function() comp:Play(0.0) end)
                Utils.QueueWork(function()
                    pcall(function() if IsValid(comp) then comp:Stop() end end)
                end, cutoffMs)
            end
        else
            -- (World, Sound, Vol, Pitch, StartTime, Concurrency, OwningController, bIsUISound)
            pcall(function() gs:PlaySound2D(world, sound, 1.0, 1.0, 0.0, nil, nil, true) end)
        end
    end)
end


-- Spawn ONE NPC by name at an exact `spot`.
--   * A registered variant spawns its Base and mutates it. Anything else spawns as a raw DT
--     row. Callers can mix both freely. onSpawned(npc) fires on the authority once it's up.
--   * extraOpts.Variant forwards to MutateActor's Stats(actor, opts) for per-instance tuning
--     (e.g. { NoSummon = true }). Stripped before reaching NpcSpawner.
--   * Always routes through AVU.SummonVariant so def.RopeSpawn's gate+delay pairing applies.
--     Skipping it silently drops rope-in on Trooper-based variants (Centurion, Speculatores).
function EVU.SpawnOne(name, spot, onSpawned, extraOpts)
    local VARIANTS = require("AnteVariants.Variants")

    local def = VARIANTS[name]
    extraOpts = extraOpts or {}

    if def then
        -- ONE opts table for SummonVariant. It forwards the whole thing to MutateActor so the
        -- per-instance Variant opts reach Stats, and it reads Rotation/SkipSpawnFX and the two
        -- spawn-in forcers (def.RopeSpawn / def.ForceSpawnFX) itself.
        -- Copied, never the caller's table - SummonVariant writes SpawnDelay into it.
        local opts = {}
        for k, v in pairs(extraOpts.Variant or {}) do opts[k] = v end
        opts.Rotation = extraOpts.Rotation
        opts.SkipSpawnFX = extraOpts.SkipSpawnFX
        AVU.SummonVariant(name, spot, opts, function(npc)
            if Utils.IsActorInvalid(npc) then return end   -- callers' rosters hold the ref; never a dead one
            if onSpawned then pcall(onSpawned, npc) end
        end)
        return
    end

    -- A raw DT row: spawn it as-is, nothing to mutate.
    local opts = {
        callback = function(npc)
            if Utils.IsActorInvalid(npc) then return end
            if onSpawned then pcall(onSpawned, npc) end
        end,
    }
    for k, v in pairs(extraOpts) do
        if k ~= "Variant" then opts[k] = v end
    end

    NpcSpawner.SpawnNpc(name, spot, opts)
end


-- Spawn one NPC NEAR `loc`: fuzz the point, snap it to the navmesh, lift it clear of the floor, then
-- SpawnOne. This is the normal way a set-piece places a body - SpawnOne only takes an exact spot.
-- opts:
--   Fuzz        (default 150)  - random spread around loc, and the navmesh search radius
--   ZLift       (default 90)   - extra lift so the capsule centre clears the floor
--   Yaw         (optional)     - facing, in degrees; grab one in-game with the [CTRL][L] keybind
--   FuzzYaw     (optional)     - random +/- degrees on top of Yaw; ignored without a Yaw.
--                                Scatters a squad so it doesn't read as a parade formation.
--   SkipSpawnFX (optional)     - just appear, no entrance montage
--   callback    (optional)     - onSpawned(npc), authority
--   Variant     (optional)     - opts table handed to the variant's Stats(actor, opts); see SpawnOne
--   Exact       (optional)     - spawn AT `loc` exactly, only dropping it onto the floor beneath
--                                it (Utils.ProjectToNav). Use for hand-authored coords: a muster
--                                point, a formation slot. The default GetSpawnPoint path re-rolls
--                                within Fuzz and can snap to a different storey, which is
--                                ruinous for a placed body.
--   ZExtent     (optional)     - Exact only: how far down/up to look for the floor (default 150,
--                                less than a storey - a miss falls back to the authored point).
function EVU.SpawnAt(name, loc, opts)
    opts = opts or {}
    local fuzz  = opts.Fuzz  or 150
    local zlift = opts.ZLift or 90

    local yaw = opts.Yaw
    if yaw and opts.FuzzYaw then yaw = yaw + (math.random() * 2 - 1) * opts.FuzzYaw end

    local spot, rot
    if opts.Exact then
        -- No fuzz, no re-roll, no cross-storey snap: this point was chosen on purpose.
        --   * No navmesh under it? Still spawn AT it (the body falls to the floor) rather
        --     than teleport it somewhere the author didn't ask for.
        spot = Utils.ProjectToNav(loc, opts.ZExtent) or loc
        rot  = yaw and FRotator(0, yaw, 0) or nil
    else
        spot, rot = Utils.GetSpawnPoint(Utils.FuzzLocation(loc, fuzz), fuzz, nil, nil, nil, nil, yaw)
        spot = spot or loc
    end
    spot = FVector(spot.X, spot.Y, spot.Z + zlift)

    EVU.SpawnOne(name, spot, opts.callback, {
        Rotation = rot, SkipSpawnFX = opts.SkipSpawnFX, Variant = opts.Variant,
    })
end


-- =======================================================================
-- PLACED SPAWNS - synthetic spawners (SpawnerData.PlacedSpawns): an NPC at an arbitrary
-- coord with no game spawner. Ticked by StoryManager.Tick. AUTHORITY.
--   * Keeps one alive while a player is in the gated level. A kill starts a persisted day-based
--     respawn cooldown; an un-killed one just respawns freely on re-entry.
--   * cfg.Variant spawns and mutates a variant. cfg.Base spawns a plain DT row, never mutated -
--     for a body that has to read as ordinary alongside variant squadmates. See findPlacedCopy.
--   * cfg.Opts is handed to the variant's Stats/OnReady, for a placement that wants one shape of
--     it. Ignored on a plain cfg.Base placement, which is never mutated.
--   * No game spawner owns the body, so "is my NPC already out there?" is answered by
--     SCANNING - see AnNotes/Modules/EventUtils.md for why a naive scan stacks duplicates.
-- =======================================================================
-- Kill cooldowns are ROLLING in-game hours (Utils.GetGameHours), not calendar days.
local PLACED_DEFAULT_COOLDOWN_HOURS = 72
local PLACED_HARD_COOLDOWN_HOURS    = 24  -- under HARDMODE.NoEnd; per-entry cfg.CooldownDays still wins
local PLACED_DEFAULT_ZLIFT = 97
EVU.PlacedDefaultZLift = PLACED_DEFAULT_ZLIFT   -- PlacedViz marks the same point
local PLACED_SAFE_RADIUS = 3000           -- Crafting benches block PlacedSpawns within this
-- BASE-row match (~40m): how close a plain-base body still counts as "ours, reverted". Kept
-- tight - a native NPC of the same row looks identical.
local PLACED_DEFAULT_BASE_RADIUS = 4000
-- VARIANT-NAME match (~40m, overridable via cfg.VariantRadius). No wider than the base match: a
-- same-named body further out is as likely a spawner's or an event's as ours, and the
-- last-known-position anchor is what finds our own wanderer. Also the SCAN radius.
local PLACED_DEFAULT_VARIANT_RADIUS = 4000
EVU.PlacedDefaultBaseRadius = PLACED_DEFAULT_BASE_RADIUS         -- /placed and PlacedViz print them
EVU.PlacedDefaultVariantRadius = PLACED_DEFAULT_VARIANT_RADIUS
-- A player must be within this of an anchor before we scan or spawn (~120m, inside the game's
-- own ~150m NPC despawn radius so we don't act on a dead sector).
local PLACED_ACTIVE_RADIUS = 12000
-- Safety release for a spawn that never lands. Must outlast the worst-case NpcSpawner delay
-- (200ms stagger per queued spawn, then an async class load), or a still-in-flight spawn reads
-- as "gone" and gets duplicated.
local PLACED_PENDING_MS = 20000
-- Retry delay after a spawn lands in an unloaded sublevel, so a stubborn sector doesn't churn
-- every tick.
local PLACED_BACKOFF_SEC = 60
-- Retry delay once a player's Crafting Bench suppresses a placement. Long, because a base stays put;
-- the cost is that a bench picked up and moved frees its old spot this late.
local PLACED_BENCH_BACKOFF_SEC = 600
-- Retry delay for a streaming-gate miss (sector not loaded yet). Matches the old cadence of
-- waiting for the next 10s story beat.
local PLACED_STREAM_RETRY_SEC = 10
-- A growing backoff fits a coord that never streams in, but not one a player is walking toward
-- - see AnNotes/AnteSystems/PlacedSpawns.md "ActiveRadius is the spawn earlier knob". Fix: a placement near
-- an anchor gets free fast re-checks before joining the growing backoff. Both radii are
-- overridable per-placement (cfg.NearRadius / cfg.NearFastCheck).
local PLACED_NEAR_RADIUS = 6000           -- ~60m: inside this sector, it streams any second
local PLACED_NEAR_FAST_CHECKS = 10        -- free re-checks per approach, at PLACED_NEAR_CHECK_MS
-- Cadence of those fast checks, not the 1s budget re-sweep. The poll is TTL-cached
-- (STREAM_CACHE_TTL, 4s), so a faster cadence would just re-read a stale answer.
local PLACED_NEAR_CHECK_MS = 3000
-- Past the free re-checks, the cadence while someone stays inside NearRadius. Never the growing
-- backoff there: a sector that streams a minute after you arrive used to sit out a 60s penalty on
-- top of that, and the body appeared when you were standing on the coord, if at all.
local PLACED_NEAR_SLOW_CHECK_SEC = 10
local placedPending = {}                  -- coord key -> true while a spawn is in flight
local placedBackoff = {}                  -- coord key -> os.time() before which we won't retry (unloaded sublevel)
local placedActive = {}                   -- coord key -> true once a player is inside ActiveRadius AND the sector is live (arrival edge)
local placedWarmed = {}                   -- coord key -> true once def.Assets were warmed for this approach
local placedFailN = {}                    -- coord key -> consecutive stream-gate failures (grows the retry backoff)
local placedNearN = {}                    -- coord key -> stream-gate failures spent inside PLACED_NEAR_RADIUS (the grace counter)
local placedNear = {}                     -- coord key -> true while a player is inside NearRadius (the walk-up edge)
local streamCache = {}                    -- IsLocationLoaded TTL cache (see isLocLoadedCached below)
local streamCacheN = 0

-- Helper functions
local spawnPlaced, startPlacedCooldown, ensureOnePlacedSpawn
local placedLoc, placedAnchors, notePlacedPos, findPlacedCopy, adoptPlacedCopy, healPlacedVariant
local anyPlayerNear, rawRowName, rawNpcName, vec, isLocLoadedCached, placedLabel, streamGateMissed
local forgetLocLoaded, geometryUnder

-- Player positions, snapshotted ONCE per tick (plain tables). The presence gate runs for every
-- placement now, so it can't cost a BP call each time - this makes it a pure-Lua distSq walk.
local playerLocs = {}

-- WORK BUDGET. A sphere-overlap scan and an actor spawn both happen on ARRIVAL, and every
-- placement in a sector arrives at once. Unbudgeted, that fired ~6 overlaps/spawns in one tick
-- (a burst hitch). Spend PLACED_MAX_WORK_PER_PASS per PLACED_RESWEEP_MS pass instead - one unit
-- alone can cost ~110ms (IsLocationLoaded + overlap scan).
local PLACED_MAX_WORK_PER_PASS = 1
local PLACED_RESWEEP_MS = 1000
local placedWorkLeft = 0        -- budget for the CURRENT pass (read by ensureOnePlacedSpawn)
local placedSweepQueued = false -- a re-sweep is already in the WorkQueue; don't stack them

-- Come back sooner than the next 10s story tick. nil = nothing deferred. The budget path wants
-- PLACED_RESWEEP_MS (1s); a streaming-gate miss wants PLACED_NEAR_CHECK_MS (3s, its TTL).
-- Shortest request wins.
local placedDeferredMs = nil

local function deferSweep(ms)
    if not placedDeferredMs or ms < placedDeferredMs then placedDeferredMs = ms end
end

function EVU.EnsurePlacedSpawns(story)
    local placed = SPAWNERDATA.PlacedSpawns
    if not placed then return end
    STATE.PlacedSpawnActors = STATE.PlacedSpawnActors or {}
    STATE.PlacedSpawnLastPos = STATE.PlacedSpawnLastPos or {}

    playerLocs = {}
    for _, p in ipairs(Utils.LivePlayers()) do
        local ok, l = pcall(function() return p:K2_GetActorLocation() end)
        if ok and l then playerLocs[#playerLocs + 1] = { X = l.X, Y = l.Y, Z = l.Z } end
    end

    placedWorkLeft, placedDeferredMs = PLACED_MAX_WORK_PER_PASS, nil
    for key, cfg in pairs(placed) do
        ensureOnePlacedSpawn(key, cfg, story)
    end

    -- Deferred work is picked up on a short re-sweep rather than waiting out the 10s story tick, so
    -- a room still fills promptly - just a few placements per pass.
    if placedDeferredMs and not placedSweepQueued then
        placedSweepQueued = true
        local delay = placedDeferredMs
        Utils.QueueWork(function()
            placedSweepQueued = false
            EVU.EnsurePlacedSpawns(story)
        end, delay)
    end
end

-- [StoryManager.Register] Per-world reset of the PlacedSpawns RUNTIME state: module-locals
-- that reference old-world facts (arrival edges, backoffs, stream-cache, in-flight flags).
--   * Without it, a stale placedActive[key] from the previous visit would rob a placement of
--     its arrival burst, and stale backoffs would delay spawns.
--   * Persisted state (cooldown days) lives in STATE.StoryData and is NOT touched here.
function EVU.ResetPlacedRuntime()
    placedActive = {}
    placedWarmed = {}
    placedFailN = {}
    placedNearN = {}
    placedNear = {}
    placedBackoff = {}
    placedPending = {}
    streamCache = {}
    streamCacheN = 0
    placedSweepQueued = false   -- the queued re-sweep died in the teardown WorkQueue wipe
end

-- The placement respawn gate: coord key -> in-game hour it may respawn (persisted).
--   * Folds in an older save's PlacedSpawnReadyDay: day N meant that day's midnight, hour N*24.
function EVU.PlacedReadyHours()
    local sd = STATE.StoryData
    sd.PlacedSpawnReadyHour = sd.PlacedSpawnReadyHour or {}
    local book, old = sd.PlacedSpawnReadyHour, sd.PlacedSpawnReadyDay
    if old then
        for key, day in pairs(old) do
            if book[key] == nil and type(day) == "number" then book[key] = day * 24 end
        end
        sd.PlacedSpawnReadyDay = nil
    end
    return book
end

-- Clear all PlacedSpawn kill-cooldowns (the debug "reset spawner cooldowns" path).
--   * Does NOT force a spawn or clear live refs - the next StoryManager tick re-runs
--     EnsurePlacedSpawns, which only (re)spawns where the level/story gates pass AND no
--     live/dupe copy already exists.
--   * So a killed placement just becomes re-eligible immediately; it won't duplicate a living one.
function EVU.ResetPlacedSpawnCooldowns()
    local book = EVU.PlacedReadyHours()
    for key in pairs(book) do book[key] = nil end
    FileIO.SaveStoryData()
end

-- [DEBUG] Read-only snapshot of one placement's RUNTIME gate state - the module-locals that
-- decide whether a coord is scanning, waiting on streaming, in flight or backed off. This is
-- the "why is that spot empty" half of the answer; the config half is in PlacedSpawnData.
--   * Plain table, no wrappers. Read by AnDebug/PlacedViz and safe to call from anywhere.
function EVU.PlacedRuntime(key)
    return {
        Active  = placedActive[key] and true or false,
        Warmed  = placedWarmed[key] and true or false,
        Pending = placedPending[key] and true or false,
        FailN   = placedFailN[key] or 0,
        NearN   = placedNearN[key] or 0,
        Near    = placedNear[key] and true or false,
        Backoff = placedBackoff[key],
    }
end

-- [DEBUG] The streaming gate's raw answers for one placement, uncached: the level manager's (what
-- the gate asks), and floor collision under the coord (what FloorGate adds). Read by AnTest/Placed.
function EVU.PlacedProbe(key)
    local cfg = SPAWNERDATA.PlacedSpawns and SPAWNERDATA.PlacedSpawns[key]
    local loc = cfg and placedLoc(key, cfg)
    if not loc then return nil end
    return {
        Loc = loc,
        Label = placedLabel(cfg),
        Loaded = Utils.IsLocationLoaded(vec(loc)) and true or false,
        Floor = geometryUnder(loc) and true or false,
        Live = STATE.PlacedSpawnActors and IsValid(STATE.PlacedSpawnActors[key]) or false,
    }
end

-- Record a PlacedSpawn NPC as DEFEATED right now - a kill, or a banish (an Invincible
-- "despawn" NPC like the Roaming Shade, removed via controller Despawn and never IsDead).
--   * Must be called AT defeat-time, while the actor is still valid, so the cooldown is set
--     immediately. Otherwise the next EnsurePlacedSpawns tick can't tell the despawn from a
--     level stream-out and re-places it on return.
--   * Matched by GetFullName (stable across UE4SS wrappers).
--   * No-op if the actor isn't one of our placements. AUTHORITY.
function EVU.MarkPlacedDefeated(actor)
    if not Utils.IsAuthority() then return end
    if Utils.IsActorInvalid(actor) then return end
    local placed = SPAWNERDATA.PlacedSpawns
    if not placed then return end

    local fn
    if not pcall(function() fn = actor:GetFullName() end) or not fn then return end

    for key, npc in pairs(STATE.PlacedSpawnActors or {}) do
        if Utils.IsActorValid(npc) then
            local nfn
            pcall(function() nfn = npc:GetFullName() end)
            if nfn == fn then
                startPlacedCooldown(key, placed[key])
                STATE.PlacedSpawnActors[key] = nil
                if STATE.PlacedSpawnLastPos then STATE.PlacedSpawnLastPos[key] = nil end
                return
            end
        end
    end
end

-- Record every tracked placement whose body is dead right now. For the debug wipe commands: their
-- destroy lands within ~2s, beating the reap in ensureOnePlacedSpawn, and the invalid ref it leaves
-- reads as a stream-out. Returns how many were recorded. AUTHORITY.
function EVU.ReapDeadPlacedSpawns()
    if not Utils.IsAuthority() then return 0 end
    local placed = SPAWNERDATA.PlacedSpawns
    if not placed or not STATE.PlacedSpawnActors then return 0 end

    local n = 0
    for key, npc in pairs(STATE.PlacedSpawnActors) do
        local dead = false
        if IsValid(npc) then pcall(function() dead = npc.IsDead == true end) end
        if dead then
            startPlacedCooldown(key, placed[key])
            STATE.PlacedSpawnActors[key] = nil
            n = n + 1
        end
    end
    return n
end


-- --- PlacedSpawns helpers -----------------------------------------------------

-- What this placement puts in the world, for logs and the /placed dump.
function placedLabel(cfg)
    return tostring(cfg.Variant or cfg.Base)
end

-- One placement: reap the dead ref, then adopt-or-respawn if every gate passes.
function ensureOnePlacedSpawn(key, cfg, story)
    if not (cfg.Variant or cfg.Base) then return end

    -- HARD MODE (HARDMODE.NoMercy): a Hard placement only exists in hard mode. Gated before the
    -- live-ref maintenance on purpose - with the flag off we neither spawn nor maintain it, so
    -- a save-restored body from a hard world just lives out its life as an ordinary NPC.
    -- World-load static, like every hard-mode flag.
    if cfg.Hard and not STATE.HardModeNoMercy then return end

    local live = STATE.PlacedSpawnActors[key]
    if live ~= nil then
        -- Raw IsValid, not Utils.IsActorValid, which also fails on an unloaded level (not a
        -- kill). Valid + IsDead is a real kill and starts the cooldown. Invalid is AMBIGUOUS: a
        -- kill and a despawn look identical to a stream-out. A genuine defeat is recorded
        -- separately at defeat-time by EVU.MarkPlacedDefeated. Streamed-out means re-place on
        -- return.
        if IsValid(live) then
            local dead = false
            pcall(function() dead = live.IsDead end)
            if not dead then
                -- Still alive: remember WHERE (cheap - one GetActorLocation per tick).
                --   * A reloaded NPC comes back wherever it patrolled to, not at the spawn
                --     coord. This is the anchor the next scan has to check.
                local t0 = PROF.Begin()
                notePlacedPos(key, live)
                healPlacedVariant(key, cfg, live)   -- adopted/unmutated body -> restore the variant
                -- NoPatrol re-assert (two property writes on the once-per-tick beat - free).
                --   * Closes the one hole SetNoPatrol can't: ClearStuckState() rewinds the
                --     patrol stamp whenever the NPC unsticks off geometry, buying it one wander
                --     each time otherwise.
                if cfg.NoPatrol then AVU.SetNoPatrol(live) end
                PROF.EndAs(t0, "Placed.liveMaint")
                return
            end
            startPlacedCooldown(key, cfg)
        end
        STATE.PlacedSpawnActors[key] = nil   -- killed, or the level unloaded (ref gone)
    end

    -- No live NPC: adopt/respawn if the story gates pass and we're past any kill-cooldown.
    story = story or 0
    if cfg.StoryMin and story < cfg.StoryMin then return end   -- not unlocked yet
    if cfg.StoryMax and story >= cfg.StoryMax then return end  -- this phase is over
    local readyAt = EVU.PlacedReadyHours()[key]
    local now = readyAt and Utils.GetGameHours()
    if now and now < readyAt then return end                   -- still cooling down from a kill

    -- Cheap early-outs BEFORE any budget is spent. Every path that does expensive work but
    -- produces no NPC must land in one of these, or it consumes the pass budget forever and
    -- keeps the re-sweep alive as a permanent scan loop.
    if placedPending[key] then return end                       -- a spawn is already in flight

    local loc = placedLoc(key, cfg)
    if not loc then return end

    -- PRESENCE GATE - cheap pure-Lua distSq pre-filter in front of the real STREAMING gate
    -- below, so ~90 placements don't each make a subsystem call + overlap query every pass.
    -- cfg.Level is a LABEL only, not gated on - it can disagree with the coord's real streaming
    -- sector (see AnNotes/AnteSystems/PlacedSpawns.md "Level is a label, not a gate"). Proximity is ground
    -- truth for whether the sector is live.
    local anchors = placedAnchors(key, loc)
    local activeRadius = cfg.ActiveRadius or PLACED_ACTIVE_RADIUS
    if not anyPlayerNear(anchors, activeRadius) then
        -- Left the radius: the next approach is an ARRIVAL again, and gets a fresh warm and a
        -- fresh streaming grace.
        placedActive[key] = nil
        placedWarmed[key] = nil
        placedNearN[key] = nil
        placedNear[key] = nil
        return
    end

    -- WALK-UP RESET. The stream-gate penalties below describe how the sector looked from where
    -- the player WAS - and ActiveRadius is twice NearRadius, so someone crossing the room can
    -- burn the whole grace at 100m and then stand on an empty coord waiting out a 60s backoff.
    -- Arriving inside NearRadius is new evidence, so it hands the grace back; the counters still
    -- run out once you are standing there, which is what keeps a dead coord quiet. Gated on
    -- placedFailN so it only lifts a backoff the STREAM GATE armed - a bench suppression or an
    -- unloaded landing is not something walking closer disproves.
    local near = anyPlayerNear(anchors, cfg.NearRadius or PLACED_NEAR_RADIUS)
    if near and not placedNear[key] and placedFailN[key] then
        placedNearN[key], placedFailN[key], placedBackoff[key] = nil, nil, nil
    end
    placedNear[key] = near or nil

    local backoff = placedBackoff[key]
    if backoff and os.time() < backoff then return end          -- suppressed (bench / unloaded landing)

    -- ARRIVAL BURST vs steady-state budget (see AnNotes/AnteSystems/PlacedSpawns.md for the why). A
    -- placement's FIRST pass after a player enters its radius runs UNBUDGETED, so a whole
    -- arriving cluster lands in one hitch alongside the game's own level-entry load spike.
    -- Steady-state re-checks (wanderer scans, cooldown expiries, stream retries) ride the
    -- 1-per-pass budget instead. Spawns are already staggered by NpcSpawner, so the burst is
    -- gates and scans, not construction. It's spent when the sector actually goes LIVE
    -- (placedActive below), not the moment ActiveRadius is crossed - spending it earlier
    -- trickled a room in over several seconds instead of filling it at once.
    local arrival = not placedActive[key]
    if arrival then
        -- Front-load this variant's def.Assets once per approach, not per stream-gate retry.
        -- A LoadAsync fan-out, not a poll. Lazy require: SpawnerHooks pulls NpcManager, a
        -- load-time cycle risk from the top of this file.
        if not placedWarmed[key] then
            placedWarmed[key] = true
            pcall(function() require("AnteVariants.SpawnerHooks").WarmVariantAssets(cfg) end)
        end
    else
        if placedWorkLeft <= 0 then deferSweep(PLACED_RESWEEP_MS) return end
        placedWorkLeft = placedWorkLeft - 1
    end

    -- STREAMING GATE - ask the game (ULevelManagerSubsystem::IsLocationLoaded), not a distance
    -- guess. Near a level border, ActiveRadius can include an unstreamed sector, and spawning
    -- there yields an unmutatable body we then destroy. Only scan anchors that are live - an
    -- overlap query on a dead sector reports "empty" and would duplicate.
    local t0 = PROF.Begin()
    local liveAnchors, locLoaded = {}, false
    for i = 1, #anchors do
        if isLocLoadedCached(anchors[i], cfg.FloorGate) then
            liveAnchors[#liveAnchors + 1] = anchors[i]
            if i == 1 then locLoaded = true end        -- anchors[1] is always the spawn coord
        end
    end
    PROF.EndAs(t0, "Placed.streamGate")
    if #liveAnchors == 0 then
        -- Nothing live to scan or spawn into. Keep watching on the re-sweep while you're
        -- walking in, back off once it's clear the sector isn't coming - see streamGateMissed.
        streamGateMissed(key, anchors, cfg)
        return
    end
    -- Past the gate: the sector is live, so this is the real arrival.
    placedActive[key] = true

    -- Already out there? Adopt it (and heal it back into the variant if it reverted) - never stack.
    t0 = PROF.Begin()
    local copy, exact = findPlacedCopy(key, cfg, liveAnchors)
    PROF.EndAs(t0, "Placed.copyScan")
    if copy then
        placedFailN[key], placedNearN[key] = nil, nil
        adoptPlacedCopy(key, cfg, copy, exact)
        return
    end

    -- Only place where the sector is live: the coord can be dead while the last-known-position
    -- anchor we just scanned is live, so there's nothing to do this tick. Same backoff as above
    -- (against the COORD only) so an unstreamed spot doesn't rescan every sweep forever.
    if not locLoaded then
        streamGateMissed(key, { loc }, cfg)
        return
    end
    placedFailN[key], placedNearN[key] = nil, nil
    spawnPlaced(key, cfg, loc)
end

-- A placement missed the streaming gate: decide when to retry. Two regimes, opposite answers
-- (see AnNotes/Modules/EventUtils.md). WALKING IN (a player inside PLACED_NEAR_RADIUS of an anchor) gets
-- free re-checks for PLACED_NEAR_FAST_CHECKS passes at the PLACED_NEAR_CHECK_MS cadence, no
-- backoff. NEVER STREAMS grows the retry (10s -> 20s -> ... capped at PLACED_BACKOFF_SEC). The
-- near path self-ARMs the re-sweep (deferSweep) since the arrival pass is unbudgeted. Its check
-- counter is bounded and per-approach, so a near coord that genuinely never streams still goes
-- quiet.
function streamGateMissed(key, anchors, cfg)
    if anyPlayerNear(anchors, (cfg and cfg.NearRadius) or PLACED_NEAR_RADIUS) then
        -- Someone is standing in the sector, so every re-check must be a REAL query: drop the
        -- TTL-cached answers for these anchors, or a 3s cadence against a 4s cache spends half
        -- the grace re-reading the same stale "unloaded".
        for i = 1, #anchors do forgetLocLoaded(anchors[i]) end

        local limit = (cfg and cfg.NearFastCheck) or PLACED_NEAR_FAST_CHECKS
        local g = (placedNearN[key] or 0) + 1
        placedNearN[key] = g
        if g <= limit then
            deferSweep(PLACED_NEAR_CHECK_MS)
            return
        end
        -- Once per approach. Only an error when floor collision IS under the coord: then its
        -- geometry is in and the gate disagrees (a coord outside every level volume: FloorGate).
        -- No floor means its sector really is out - the near radius reaches another storey or the
        -- room next door, which a dedicated server streams only when someone stands in it.
        if g == limit + 1 then
            local floor = geometryUnder(anchors[1])
            local msg = string.format("PlacedSpawn %s (%s) - sector still UNLOADED after %d near checks%s; "
                .. "watching every %ds while someone is near", key, placedLabel(cfg), limit,
                floor and " though its floor is in" or " (no floor under it: not streamed)",
                PLACED_NEAR_SLOW_CHECK_SEC)
            if floor then
                LogBad(msg .. ". Standing on it? Then nudge it, add a ZLift, or FloorGate=true if the "
                    .. "coord sits outside every level volume")
            else
                LogDebug(msg, SETTINGS.DEBUG_SPAWNERS)
            end
        end
        placedBackoff[key] = os.time() + PLACED_NEAR_SLOW_CHECK_SEC
        deferSweep(PLACED_NEAR_SLOW_CHECK_SEC * 1000)
        return
    end
    local n = (placedFailN[key] or 0) + 1
    placedFailN[key] = n
    placedBackoff[key] = os.time() + math.min(PLACED_STREAM_RETRY_SEC * n, PLACED_BACKOFF_SEC)
end

-- The SpawnerData key IS the coord ("x,y,z"), lifted clear of the floor. nil on a malformed key.
--   * Returns a PLAIN table, memoised. Every placement is walked every pass now, so re-parsing
--     ~90 strings and allocating ~90 FVector userdata per pass would be pure waste.
--   * FVectors are built only where a UE call actually needs one (`vec` below) - a handful
--     per pass, not one per placement.
local placedCoords = {}   -- key -> {X,Y,Z}, or false for a known-bad key

function placedLoc(key, cfg)
    local c = placedCoords[key]
    if c ~= nil then return c or nil end

    local x, y, z = tostring(key):match("^(-?%d+),(-?%d+),(-?%d+)$")
    if not x then
        LogBad("PlacedSpawn - bad coord key: " .. tostring(key))
        placedCoords[key] = false
        return nil
    end

    c = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) + (cfg.ZLift or PLACED_DEFAULT_ZLIFT) }
    placedCoords[key] = c
    return c
end

-- Plain {X,Y,Z} -> FVector, at the point of use.
function vec(t) return FVector(t.X, t.Y, t.Z) end

-- Cached ULevelManagerSubsystem::IsLocationLoaded. The raw query has a real per-call cost, and a
-- room fill re-asks the same anchors every 1s re-sweep. TTL-cached (STREAM_CACHE_TTL), keyed by
-- 10m bucket. A stale TRUE (streamed out mid-TTL) is caught by the normal destroy-on-unloaded
-- path. A stale FALSE just delays a placement by at most one TTL.
-- streamCache/-N are declared with the other placed-spawn locals up top; ResetPlacedRuntime writes them.
local STREAM_CACHE_TTL = 4        -- seconds

local function streamKey(pt)
    return math.floor(pt.X / 1000) .. ":" .. math.floor(pt.Y / 1000) .. ":" .. math.floor(pt.Z / 1000)
end

-- Drop the cached answer for `pt`, so the next isLocLoadedCached is a real query.
function forgetLocLoaded(pt)
    streamCache[streamKey(pt)] = nil
end

-- Is there level collision under `pt`? A downward Visibility trace from just above the coord
-- (authored ~1m over its floor) to well below it. An unstreamed sector has no collision at all,
-- so a hit is direct evidence the geometry is in. Needs an actor as the trace's world context;
-- any live player serves, and with none in the world there is nobody to spawn for anyway.
function geometryUnder(pt)
    local players = Utils.LivePlayers()
    local ctx = players and players[1]
    if not ctx or IsNotValid(ctx) then return false end
    return AVU.IsPathBlocked(ctx, FVector(pt.X, pt.Y, pt.Z + 100), FVector(pt.X, pt.Y, pt.Z - 700), { ctx })
end

function isLocLoadedCached(pt, floorGate)
    local k = streamKey(pt) .. (floorGate and ":f" or "")
    local now = os.clock()
    local e = streamCache[k]
    if e and (now - e.t) < STREAM_CACHE_TTL then return e.loaded end

    local loaded = Utils.IsLocationLoaded(vec(pt)) and true or false
    -- The subsystem answers by level VOLUME, and a coord outside every volume reads unloaded for
    -- good even though its sector is in and a spawn there works (the 2F Security Office pair).
    -- Floor collision is the tiebreak, but only where the placement opts in (cfg.FloorGate). As a
    -- default it is a false positive at every sector border: the trace hits the loaded
    -- neighbour's geometry under a coord whose own sector is still out, each pass is a spawn
    -- that lands unloaded and is destroyed, and a cold class spawned that way is the S2 wedge.
    if not loaded and floorGate then loaded = geometryUnder(pt) end
    if not e then
        streamCacheN = streamCacheN + 1
        if streamCacheN > 256 then streamCache = {}; streamCacheN = 1 end   -- bound the table
    end
    streamCache[k] = { t = now, loaded = loaded }
    return loaded
end

-- Where this placement's NPC could be: the spawn coord, plus its last known live position if it
-- had wandered meaningfully clear of it. Both are scan anchors AND presence-gate anchors.
function placedAnchors(key, loc)
    local anchors = { loc }
    local last = STATE.PlacedSpawnLastPos and STATE.PlacedSpawnLastPos[key]
    if last and not Utils.WithinDistance(last, loc, 1000) then
        anchors[#anchors + 1] = last
    end
    return anchors
end

-- Is any player within `radius` of ANY anchor? Pure Lua against the per-tick player snapshot.
function anyPlayerNear(anchors, radius)
    local r2 = radius * radius
    for i = 1, #playerLocs do
        for j = 1, #anchors do
            if Utils.DistSq(playerLocs[i], anchors[j]) <= r2 then return true end
        end
    end
    return false
end

-- Snapshot the NPC's position as a PLAIN table.
--   * Never hold a UE struct/wrapper across ticks - the GC family; see CLAUDE.md 3.
--   * Cleared on a defeat: a dead NPC isn't coming back to it.
function notePlacedPos(key, npc)
    local ok, l = pcall(function() return npc:K2_GetActorLocation() end)
    if not ok or not l then return end

    -- Reject ORIGIN reads (seen in the /placed dump: "lastPos=0,0,0 (479m from coord)").
    --   * An actor mid-teardown / in an unloaded sector reads 0,0,0; storing that poisons the
    --     anchor list - we would then presence-gate and scan around WORLD ORIGIN forever.
    if math.abs(l.X) < 1 and math.abs(l.Y) < 1 and math.abs(l.Z) < 1 then return end

    STATE.PlacedSpawnLastPos = STATE.PlacedSpawnLastPos or {}
    STATE.PlacedSpawnLastPos[key] = { X = l.X, Y = l.Y, Z = l.Z }
end

-- RAW identity reads. A property read is safe even on an actor Utils.IsActorValid rejects (an
-- unstreamed sublevel); acting on one isn't. The scanned dupes ARE those orphaned bodies, so
-- Utils.GetActorRowName/GetActorNPCName, which bail through IsActorValid, would miss them.
-- Canonicalised like Utils.CanonicalRowName: raw FName casing isn't trustworthy.
function rawRowName(npc)
    local ok, r = pcall(SCHEMA.NpcRowName, npc)
    if ok and r then return Utils.CanonicalRowName(r) end
    return nil
end

function rawNpcName(npc)
    local ok, n = pcall(function()
        local nd = npc.NPCData
        local t = nd and nd[ENUMS.NpcData.DisplayName]
        return t and t:ToString() or nil
    end)
    if ok and n and n ~= "" then return n end
    return nil
end

-- A tracked body that isn't (or is no longer) the variant: re-mutate it. Turns an adopted
-- stray, or one that spawned while its sublevel was unloaded (MutateActor bailed), back into
-- the placement's NPC instead of sitting as a plain base forever. Only attempts while the actor
-- is genuinely valid. Otherwise the next tick retries.
function healPlacedVariant(key, cfg, npc)
    if not cfg.Variant then return end                    -- a PLAIN (cfg.Base) placement: nothing to restore
    if Utils.IsActorInvalid(npc) then return end          -- sublevel not streamed: MutateActor would bail

    -- "Is this still OUR variant?" = the VariantTag's Id, never the DisplayName (CLAUDE.md Law 2).
    -- Matching the Id keeps the identity half the name test had: a body wearing some OTHER
    -- variant's tag is still not this placement's.
    --   * This runs EVERY TICK on a live placement, so a false "missing" is a re-mutation per
    --     tick - and the STATS step rebuilds the limb maps, which is a heal on a body mid-fight.
    local VARIANTS = require("AnteVariants.Variants")     -- lazy: load-cycle risk at file scope
    local VariantTag = require("AnteVariants.VariantTag")
    local def = VARIANTS[cfg.Variant]
    local wantId = def and def.Id
    if wantId then
        if VariantTag.Decode(npc) == wantId then return end
    elseif rawNpcName(npc) == cfg.Variant then
        return                                            -- Id-less def: the name is all there is
    end

    LogDebug("PlacedSpawn - " .. key .. " body is not '" .. tostring(cfg.Variant)
        .. "' (variant missing); re-mutating", SETTINGS.DEBUG_STORY)
    local ok, err = pcall(function()
        -- cfg.Opts travels here too: a re-mutation without it would quietly hand a placement its
        -- DEFAULT shape, and nothing in the world would look wrong.
        require("AnteVariants.NpcManager").MutateActor(cfg.Variant, npc, cfg.Opts or {})
    end)
    if not ok then LogBad("PlacedSpawn - re-mutate failed: " .. tostring(err)) end
end

-- Is a copy of this placement's NPC already at one of the anchors? Two match modes. VARIANT:
-- DisplayName == the variant name, out to cfg.VariantRadius. BASE: row name == ours and
-- no variant at all, out to the tighter cfg.BaseRadius (a reverted body and a plain native are
-- indistinguishable). Full write-up: AnNotes/AnteSystems/PlacedSpawns.md.
-- Returns npc, isExact (or nil). Closest match wins, VARIANT beating BASE at any range.
-- cfg.BaseRadius = 0 disables both branches, so the placement always spawns and stacks.
function findPlacedCopy(key, cfg, anchors)
    local baseRadius = cfg.BaseRadius or PLACED_DEFAULT_BASE_RADIUS
    if baseRadius <= 0 then return nil end

    -- Lazy (see the header): the variant registry reaches back into ModuleStory.
    local VARIANTS = require("AnteVariants.Variants")
    local VariantTag = require("AnteVariants.VariantTag")
    local def = cfg.Variant and VARIANTS[cfg.Variant]

    -- Is this row the one this placement owns? A variant accepts its Base + AltBases; a plain
    -- placement accepts exactly the row it was told to spawn.
    local function ownsRow(row)
        if not row then return false end
        if def then return VariantTag.AcceptsBase(def, row) end
        return row == cfg.Base
    end

    -- Bodies another placement already owns are OFF-LIMITS. Two placements of the same variant
    -- can sit inside one exact-match radius. Without this, whoever scans first steals the
    -- other's NPC and that spot stays empty forever.
    local taken = {}
    for k, npc in pairs(STATE.PlacedSpawnActors) do
        if k ~= key and IsValid(npc) then
            local fn
            pcall(function() fn = npc:GetFullName() end)
            if fn then taken[fn] = true end
        end
    end

    -- Scan the LARGER of the two match radii, then let each branch apply its own. That way a
    -- plain placement (no name match) and a tightened VariantRadius both shrink the sphere
    -- overlap instead of just filtering its results - overlaps are not free.
    local variantRadius = cfg.Variant and (cfg.VariantRadius or PLACED_DEFAULT_VARIANT_RADIUS) or 0
    local wide = math.max(baseRadius, variantRadius)
    local baseSq, variantSq = baseRadius * baseRadius, variantRadius * variantRadius
    local bestExact, bestExactD, bestBase, bestBaseD

    for i = 1, #anchors do
        local anchor = anchors[i]
        for _, npc in ipairs(AVU.GetNearbyNpcs(vec(anchor), wide)) do
            local fn, nl
            pcall(function() fn = npc:GetFullName() end)
            pcall(function() nl = npc:K2_GetActorLocation() end)

            if nl and not (fn and taken[fn]) then
                local d = Utils.DistSq(nl, anchor)
                local name = rawNpcName(npc)

                if cfg.Variant and name == cfg.Variant and d <= variantSq then
                    if not bestExactD or d < bestExactD then bestExact, bestExactD = npc, d end

                elseif d <= baseSq and ownsRow(rawRowName(npc)) then
                    -- Skip anything that IS a variant already - its own placement or spawner
                    -- owns it, and re-mutating one variant into another because they share a
                    -- Base would be a hijack. Either marker is enough: the DisplayName catches a
                    -- body whose tag write failed, the tag catches one whose name didn't take.
                    local isVariant = (name and VARIANTS[name] ~= nil) or (VariantTag.Decode(npc) ~= nil)
                    if not isVariant and (not bestBaseD or d < bestBaseD) then bestBase, bestBaseD = npc, d end
                end
            end
        end
    end

    if bestExact then return bestExact, true end
    return bestBase, false
end

-- Take ownership of an existing body instead of spawning a second one.
--   * A BASE copy - a placement NPC whose NPCData was rebuilt from the DT row, so it lost the
--     variant - is re-mutated in place. That is what stops the stack from growing: the stray
--     becomes the placement's NPC again.
function adoptPlacedCopy(key, cfg, npc, exact)
    STATE.PlacedSpawnActors[key] = npc
    notePlacedPos(key, npc)

    if exact then
        LogDebug("PlacedSpawn - " .. key .. " already present; re-acquired (no dupe)", SETTINGS.DEBUG_STORY)
        return
    end

    -- A base body: a stray from the old stacking bug, or a native of the same row.
    --   * Owning it is what stops the stack growing. healPlacedVariant turns it back into the
    --     variant, now or on a later tick if its sublevel is still streaming in.
    --   * For a PLAIN placement the adopted body IS already what we wanted, so the heal
    --     no-ops and only NoPatrol has anything to do.
    LogDebug("PlacedSpawn - " .. key .. " adopted a base body instead of spawning a dupe", SETTINGS.DEBUG_STORY)
    healPlacedVariant(key, cfg, npc)
    if cfg.NoPatrol then AVU.SetNoPatrol(npc) end
end

-- Is a PLAYER'S Crafting Bench within the safe radius of `loc`? Ownership, not class: the map
-- ships its own benches as scenery (the Canaan blacksmith hut's Repair Bench sits on top of three
-- placements), and only a bench someone deployed means "this is a home".
--   * DeployedByPlayer is a class default of false, set true at deploy and carried in the
--     deployable's save data, so it reads right on a restored base too.
--   * A bench we can't read blocks, as the class-only test did.
--   * Returns the blocking bench too, so the suppression log can say where it is.
local function playerBenchNearby(loc)
    local hits = AVU.GetNearbyActorsOfClass(loc, PLACED_SAFE_RADIUS,
        ENUMS.DeployedObjs.CRAFTING_BENCH) or {}
    for i = 1, #hits do
        -- Overlap out-param elements can arrive as RemoteUnrealParam; unwrap when they do.
        local a = hits[i]
        local okg, inner = pcall(function() return hits[i]:get() end)
        if okg and inner then a = inner end

        if IsValid(a) then
            local mine = true
            pcall(function() mine = a.DeployedByPlayer == true end)
            if mine then return true, a end
        end
    end
    return false
end

-- Place the NPC: honour the Crafting-Bench safe zone, then spawn. Callers have already gated on
-- presence and confirmed no copy exists.
function spawnPlaced(key, cfg, plainLoc)
    if placedPending[key] then return end
    local backoff = placedBackoff[key]
    if backoff and os.time() < backoff then return end

    local loc = vec(plainLoc)

    -- A powered Crafting Bench projects a safe zone that suppresses spawners. This mirrors that
    -- on presence only, not power. Backed off rather than re-checked every pass, since a bench
    -- doesn't come and go and an un-backed-off miss would keep the re-sweep running forever.
    local blocked, bench = playerBenchNearby(loc)
    if blocked then
        local where = "?"
        pcall(function()
            local b = bench:K2_GetActorLocation()
            where = string.format("%s at %.0f,%.0f,%.0f", bench:GetFName():ToString(), b.X, b.Y, b.Z)
        end)
        LogDebug("PlacedSpawn - " .. key .. " suppressed by a nearby player Crafting Bench (" .. where .. ")",
            SETTINGS.DEBUG_STORY)
        placedBackoff[key] = os.time() + PLACED_BENCH_BACKOFF_SEC
        return
    end

    -- Optional facing (Yaw degrees) - e.g. snipers idle-look along their spawn rotation.
    local opts = {}
    if cfg.Yaw then opts.Rotation = FRotator(0, cfg.Yaw, 0) end

    -- cfg.Opts: per-instance tuning for the variant, forwarded to its Stats/OnReady opts the same
    -- way an event spawn's `Variant` table is. For a placement that wants one shape of a variant -
    -- an Artillery Bot on a roof reading its firing profile off its post.
    for k, v in pairs(cfg.Opts or {}) do opts[k] = v end

    placedPending[key] = true
    Utils.QueueWork(function()
        if placedPending[key] then
            LogBad("PlacedSpawn - " .. key .. " spawn never landed (pending released)")
        end
        placedPending[key] = false
    end, PLACED_PENDING_MS)

    local function onSpawned(npc)
        placedPending[key] = false
        if IsNotValid(npc) then return end   -- raw: nothing was created at all

        -- Landed in an unloaded sublevel: IsLevelLoaded is false, so Utils.IsActorValid is
        -- false, so MutateActor bails - leaving an untracked plain base NPC that the next tick
        -- would spawn a duplicate on top of. Destroy it and back off instead.
        if Utils.IsActorInvalid(npc) then
            LogBad("PlacedSpawn - " .. key .. " ('" .. placedLabel(cfg)
                .. "') landed in an UNLOADED sublevel - destroying it")
            placedBackoff[key] = os.time() + PLACED_BACKOFF_SEC
            Utils.QueueWork(function()                      -- off the spawn path, never nested in it
                pcall(function() if IsValid(npc) then npc:K2_DestroyActor() end end)
            end, 0)
            return
        end

        STATE.PlacedSpawnActors[key] = npc
        notePlacedPos(key, npc)
        if cfg.NoPatrol then AVU.SetNoPatrol(npc) end   -- retries internally until the controller possesses
        LogDebug("PlacedSpawn - spawned '" .. placedLabel(cfg) .. "' at " .. key, SETTINGS.DEBUG_STORY)
    end

    -- cfg.Base = a PLAIN placement: spawn the DT row and stop there.
    --   * SummonVariant is just "SpawnNpc(def.Base) then MutateActor". Dropping to SpawnNpc is
    --     exactly that minus the mutation - same deferred, role-split, off-hook spawn path
    --     underneath either way.
    if cfg.Variant then
        AVU.SummonVariant(cfg.Variant, loc, opts, onSpawned)
    else
        NpcSpawner.SpawnNpc(cfg.Base, loc, { Rotation = opts.Rotation, callback = onSpawned })
    end
end

-- Start (or restart) a placement's respawn cooldown. Persisted (per-world save value).
--   * Mutates the SAME table STATE holds so a same-tick respawn-gate read sees it.
function startPlacedCooldown(key, cfg)
    local now = Utils.GetGameHours() or 0
    -- Stamped ABSOLUTE at defeat time (persisted), so a NoEnd toggle only shapes NEW
    -- stamps - a wait already on disk keeps its hour.
    local hours = (cfg and cfg.CooldownDays and cfg.CooldownDays * 24)
        or (STATE.HardModeNoEnd and PLACED_HARD_COOLDOWN_HOURS or PLACED_DEFAULT_COOLDOWN_HOURS)
    local readyAt = now + hours
    EVU.PlacedReadyHours()[key] = readyAt
    if STATE.PlacedSpawnLastPos then STATE.PlacedSpawnLastPos[key] = nil end
    FileIO.SaveStoryData()
    LogDebug(string.format("PlacedSpawn - %s defeated; respawns in %gh (day %d %02d:00)", key, hours,
        math.floor(readyAt / 24), math.floor(readyAt % 24)), SETTINGS.DEBUG_STORY)
end


return EVU
