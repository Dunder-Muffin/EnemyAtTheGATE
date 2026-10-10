-- =======================================================================
-- ModuleTraders/TraderDirector [AUTHORITY] - schedules the CUSTOM costume traders like the native
-- narrative ones: one arrives every couple of in-game days, stays about a day, then leaves.
-- Roster alternates and is story-gated. Placement anchors on the picked player's nearest Crafting
-- Bench, never the player directly. See AnNotes/Modules/Traders.md -> TraderDirector for the full decode.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local Placement = require("AnteCore.Placement")
local FileIO = require("AnteCore.FileIO")

local Log = Utils.Log
local LogBad = Utils.LogBad
local LogDebug = Utils.LogDebug

local TD = {}

-- Roster, visited in order. An entry is skipped while story < MinStory, or while its ItemsFlag
-- module toggle is off (the soda machine sells CUSTOM items).
local ROSTER = {
    { Costume = "Fisherman",   MinStory = 15 },
    { Costume = "Hank",        MinStory = 15 },
    { Costume = "SodaMachine", MinStory = 35, ItemsFlag = "CustomItems" },
}
local SPAWN_EVERY_DAYS = 2      -- a trader arrives every ~2 in-game days
local STAY_DAYS        = 1      -- and stays ~1 day
local BENCH_RADIUS     = 5000   -- only visit a player within ~50m of a Crafting Bench (at a base)

-- PLACEMENT. Every distance below is measured from the BENCH, not the player - a player-anchored
-- arrival can land far from base since the player is the one thing that moves. See
-- AnNotes/Modules/Traders.md -> TraderDirector for why this changed.
local NEAR_DIST        = 1500   -- the good spot: standing within 15m of the bench
local NEAR_MIN         = 300    -- but not in its lap (and clear of the bench's own box)
local NEAR_Z_TOL       = 500    -- +/-5m of the bench's floor, so never the storey above or below
local IMMOBILE_DIST    = 2500   -- a machine can't walk in, so it gets a wider near-bench pass
local FAR_DIST         = 3000   -- nothing near the bench? arrive out at ~30m...
local WALK_DIST        = 400    -- ...and walk in to a spot 2-4m from the bench. Traders' arrival
local WALK_MIN         = 200    -- tolerance adds up to 2m on top, so it settles within ~5m.
local WALK_SKIP        = 600    -- a near arrival already this close just faces the bench
local NEAR_TRIES       = 6      -- candidate spots per near-bench pass (each is its own nav query
                                -- batch, so keep it modest - this is a one-off hitch budget)
local NEAR_RETRIES     = 5      -- reachable-point retries inside one candidate
local UNSEEN_RANGE     = 6000   -- players this close count when a spot must be out of their sight
local EYE_Z            = 60     -- capsule centre -> eyes
local CHEST_Z          = 100    -- a spot's floor -> the trader's chest

-- SETTLE. A visit waits until a bench has been the anchor for a while, never the tick a player
-- lands at base. Arriving by teleport means the base's sectors are still streaming, and a trader
-- spawn (a cold class plus, for Hank, a customization load) on top of that is the freeze the
-- native director avoids by waiting out IsAnyLevelLoading. The same bench seen again after a gap
-- longer than StaleTicks starts over (the player left and came back). FAST_TICK restarts every
-- world, so an entry stamped AHEAD of now is treated as stale too.
local SETTLE = { Ticks = 200, StaleTicks = 600 }   -- 20s at the bench; a 60s gap restarts it
local benchSettle = {}   -- bench full name -> { first = FAST_TICK, last = FAST_TICK }

local Traders                   -- lazy (avoids any require-order surprises)
local spawnPending = false
local forced                    -- costume key for a /au-tradervisit run; see TD.ForceVisit
local lastBail                  -- why the last Tick declined to place, so ForceVisit can SAY so
                                -- (a scheduled tick declining is normal and silent; a forced one
                                -- declining silently just looks broken)

local function sched()
    STATE.StoryData.TraderDirector = STATE.StoryData.TraderDirector or {}
    return STATE.StoryData.TraderDirector
end

-- Any of OUR spawned traders still around? Raw IsValid on purpose - a streamed-out wrapper must
-- not count as "gone home" (the StoryManager placed-spawn rule).
local function anyLiveTrader()
    for _, npc in ipairs(STATE.SpawnedTraders or {}) do
        if IsValid(npc) then return true end
    end
    return false
end

-- =======================================================================
-- Placement
-- =======================================================================

-- The base's anchor: the Crafting Bench NEAREST the picked player, within BENCH_RADIUS. Returns the
-- bench actor (so a spot check can ignore its own box) + its location, or nil when the player is
-- out spelunking.
local function nearestBench(origin)
    local hits = AVU.GetNearbyActorsOfClass(origin, BENCH_RADIUS, ENUMS.DeployedObjs.CRAFTING_BENCH) or {}
    local best, bestLoc, bestD
    for i = 1, #hits do
        -- Overlap out-param elements can arrive as RemoteUnrealParam; unwrap when they do.
        local a = hits[i]
        local okg, inner = pcall(function() return hits[i]:get() end)
        if okg and inner then a = inner end
        if IsValid(a) then
            local ok, loc = pcall(function() return a:K2_GetActorLocation() end)
            if ok and loc then
                local dist = Utils.DistSq(origin, loc)
                -- COPY it: the returned struct rides UE4SS's params buffer, and this vector is held
                -- across the async EQS poll and (as a WalkTo target) a minute of walking.
                if not bestD or dist < bestD then
                    best, bestLoc, bestD = a, FVector(loc.X, loc.Y, loc.Z), dist
                end
            end
        end
    end
    return best, bestLoc
end

-- Has this bench been the anchor long enough to host a visit? See SETTLE.
local function benchSettled(bench)
    local k
    pcall(function() k = bench:GetFullName() end)
    if not k then return false end
    local now = STATE.FAST_TICK or 0
    local s = benchSettle[k]
    if not s or s.last > now or now - s.last > SETTLE.StaleTicks then
        s = { first = now }
        benchSettle[k] = s
    end
    s.last = now
    return now - s.first >= SETTLE.Ticks
end

-- Eye points of the players close enough to matter for UNSEEN_RANGE, as plain {X,Y,Z} + the actor
-- (the trace's world context and its own ignore).
local function playerEyes(benchLoc)
    local eyes = {}
    for _, p in ipairs(Utils.LivePlayers()) do
        local ok, l = pcall(function() return p:K2_GetActorLocation() end)
        if ok and l and Utils.DistSq(l, benchLoc) <= UNSEEN_RANGE * UNSEEN_RANGE then
            eyes[#eyes + 1] = { Actor = p, X = l.X, Y = l.Y, Z = l.Z + EYE_Z }
        end
    end
    return eyes
end

-- True if no eye in `eyes` has a clear line to a body standing at `cand`. The bench is ignored so
-- it can't count as cover for a trader standing right against it.
local function unseen(cand, eyes, bench)
    local chest = FVector(cand.X, cand.Y, cand.Z + CHEST_Z)
    for _, e in ipairs(eyes) do
        if not AVU.IsPathBlocked(e.Actor, FVector(e.X, e.Y, e.Z), chest, { e.Actor, bench }) then
            return false
        end
    end
    return true
end

-- A spot within `radius` of the bench that a player will actually walk into: reachable, on the
-- bench's own floor, not inside something they built, and IN SIGHT of the bench - a trader that
-- landed in the next room over is one nobody finds. nil when this pass found nothing.
--   * GetSpawnPoint uses K2_GetRandomReachablePointInRadius, so the point has a nav PATH from the
--     bench, not just navmesh presence (which can land behind a locked door).
--   * zClearance 0 = the feet; TR.Spawn does the capsule lift itself.
--   * IsSpawnSpotClear adds the headroom trace and the bench -> spot sight line (bench ignored).
--   * opts: MinDist (NEAR_MIN), NoSight (drop the bench sight line - the Immobile last chance),
--     HideFrom (playerEyes() - also out of every one of those players' sight, so it doesn't pop in
--     in front of them).
--   * Synchronous and drain-safe (no asset loads); only runs when a visit is due.
local function spotNearBench(benchLoc, bench, radius, opts)
    opts = opts or {}
    local minDist = opts.MinDist or NEAR_MIN
    for _ = 1, NEAR_TRIES do
        local cand = Utils.GetSpawnPoint(benchLoc, radius, minDist, NEAR_RETRIES, NEAR_Z_TOL, 0)
        if cand
            and Utils.WithinDistanceXY(cand, benchLoc, radius)
            and math.abs(cand.Z - benchLoc.Z) <= NEAR_Z_TOL
            -- GetSpawnPoint NEVER returns nil - it falls back to an UNCHECKED FuzzLocation - so
            -- re-project to prove the point really is on the navmesh and not inside a wall.
            and Utils.ProjectToNav(cand, 60, 0)
            and AVU.SpotClearOfDeployables(cand, { Ignore = bench })
            and (not bench or AVU.IsSpawnSpotClear(bench, cand, {
                ZClearance = 0, Ignore = { bench }, From = (not opts.NoSight) and benchLoc or nil }))
            and (not opts.HideFrom or unseen(cand, opts.HideFrom, bench))
        then
            return cand
        end
    end
    return nil
end

-- Where a mobile trader arriving at `loc` walks to: a standable spot 2-4m from the bench, or the
-- bench itself (MoveToLocation projects it to the floor beside the bench). nil when it already
-- landed close enough to just stand there.
local function walkTarget(loc, benchLoc, bench)
    if Utils.WithinDistanceXY(loc, benchLoc, WALK_SKIP) then return nil end
    return spotNearBench(benchLoc, bench, WALK_DIST, { MinDist = WALK_MIN }) or benchLoc
end

-- Commit a visit: spawn the costume facing the bench and write the schedule. `walkTo` = nil to
-- stand where it lands (Traders ignores it on an Immobile costume anyway).
local function place(pick, loc, walkTo, d, day, how, benchLoc)
    Traders = Traders or require("ModuleTraders.Traders")
    -- FloorZ: every point we hand over is a navmesh sample, i.e. FLOOR level. Say so, or TR.Spawn
    -- treats it as a capsule centre and the trader spawns waist-deep in the ground.
    Traders.SpawnCostume(pick.Costume, loc, { WalkTo = walkTo, FaceTo = benchLoc, FloorZ = loc.Z })
    d.ActiveUntil  = day + STAY_DAYS
    d.NextSpawnDay = day + SPAWN_EVERY_DAYS
    if pick.NextIdx then d.NextIdx = pick.NextIdx end   -- the rotation moves on a real visit only
    FileIO.SaveStoryData()
    local dist = benchLoc and ("%.0fm from the bench"):format(math.sqrt(Utils.DistSq(loc, benchLoc)) / 100) or "?"
    Log(("TraderDirector - %s arrives %s, %s%s (day %d, leaves day %d)")
        :format(pick.Costume, how, dist, walkTo and ", walking in" or "", day, d.ActiveUntil))
end

-- One scheduler step. Called from StoryManager.Tick with the current StoryProgress.
function TD.Tick(story)
    if not SETTINGS.MODULES.TRADERS.Enabled then return end
    if not Utils.IsAuthority() then return end
    if spawnPending then return end
    if not STATE.StoryData then return end           -- per-world save not loaded yet
    local day = Utils.GetCurrentDay()
    if not day then return end
    local d = sched()
    lastBail = nil

    -- A trader is out: pack it up once its stay is over.
    if anyLiveTrader() then
        if d.ActiveUntil and day >= d.ActiveUntil then
            Traders = Traders or require("ModuleTraders.Traders")
            Traders.DespawnAll()
            d.ActiveUntil = nil
            d.NextSpawnDay = day + SPAWN_EVERY_DAYS
            FileIO.SaveStoryData()
            Log("TraderDirector - trader left; next visit day " .. d.NextSpawnDay)
        end
        return
    end

    -- Next visit due? (First ever visit: no NextSpawnDay recorded -> due now.)
    -- Cleared AFTER this gate on purpose: the spawn below is deferred, so a tick landing between
    -- SpawnCostume and the body appearing sees no live trader - clearing first would drop the
    -- ActiveUntil we just wrote and the trader would never pack up.
    if d.NextSpawnDay and day < d.NextSpawnDay then return end
    d.ActiveUntil = nil

    -- Pick the next story-eligible costume, alternating through the roster. A forced visit
    -- (/au-tradervisit) skips the STORY gate either way - named costume or not. It never skips the
    -- ItemsFlag gate: SpawnCostume genuinely cannot build a soda machine with CustomItems off.
    story = story or 0
    local pick
    local forcedKey = (type(forced) == "string") and forced or nil
    if forcedKey then
        -- A costume that isn't on the roster is still spawnable; it just has no schedule entry.
        for _, cand in ipairs(ROSTER) do
            if cand.Costume == forcedKey then pick = cand; break end
        end
        pick = pick or { Costume = forcedKey }
        if pick.ItemsFlag and not SETTINGS.MODULES.TRADERS[pick.ItemsFlag] then
            lastBail = pick.Costume .. " needs MODULES.TRADERS." .. pick.ItemsFlag
            LogBad("TraderDirector - forced visit: " .. lastBail)
            return
        end
    else
        -- The rotation index is written by place(), not here: a tick that picks and then bails (no
        -- bench, not settled) must not move it, or a stretch of bailed ticks spins the roster and
        -- the visit that finally lands is a coin flip instead of the next costume in line.
        local idx = d.NextIdx or 1
        for i = 0, #ROSTER - 1 do
            local c = ((idx - 1 + i) % #ROSTER) + 1
            local cand = ROSTER[c]
            if (forced or story >= (cand.MinStory or 0))
                and (not cand.ItemsFlag or SETTINGS.MODULES.TRADERS[cand.ItemsFlag]) then
                pick = { Costume = cand.Costume, NextIdx = (c % #ROSTER) + 1 }
                break
            end
        end
    end
    if not pick then lastBail = "story too early for any roster trader"; return end

    -- Never spawn into a world that is still streaming (see SETTLE). A forced visit waits too.
    if Utils.IsAnyLevelLoading() then lastBail = "a level is still loading"; return end

    local player = Utils.RandomPlayer()
    if not player then lastBail = "no live player"; return end
    local lok, origin = pcall(function() return player:K2_GetActorLocation() end)
    if not lok or not origin then lastBail = "could not read the player's location"; return end

    -- Traders only visit a BASE, so the picked player must be near a Crafting Bench - and THAT
    -- bench, not the player, is what the arrival is placed around. Out spelunking = skip this tick;
    -- the ~10s story cadence retries with a fresh pick, so there's no extra polling. One
    -- SphereOverlap per attempt, only while a visit is due.
    local bench, benchLoc = nearestBench(origin)
    if not bench or not benchLoc then
        lastBail = "the picked player has no Crafting Bench within " .. (BENCH_RADIUS / 100) .. "m"
        LogDebug("TraderDirector - visit due, but picked player isn't near a Crafting Bench; retrying", SETTINGS.DEBUG_STORY)
        return
    end

    -- Settled at this base? A forced (/au-tradervisit) run skips it - that's a dev at their bench.
    if not forced and not benchSettled(bench) then
        lastBail = "the bench hasn't been the anchor for " .. (SETTLE.Ticks / 10) .. "s yet"
        LogDebug("TraderDirector - visit due, waiting for the base to settle", SETTINGS.DEBUG_STORY)
        return
    end

    Traders = Traders or require("ModuleTraders.Traders")
    local immobile = Traders.CostumeIsImmobile(pick.Costume)

    -- 1. The spot we actually want: right by the bench, same floor, in sight of it, not inside
    --    their build - and out of the players' own sight, so it walks round the corner rather than
    --    popping in in front of them.
    -- 2. The same spot, in view or not.
    local eyes = playerEyes(benchLoc)
    local loc = (#eyes > 0 and spotNearBench(benchLoc, bench, NEAR_DIST, { HideFrom = eyes }))
        or spotNearBench(benchLoc, bench, NEAR_DIST)

    -- 3. An Immobile costume (the soda machine) can never walk in, so give it a wider near-bench
    --    sweep, then one without the bench sight line. It NEVER takes the ring below: that ring is
    --    chosen to be out of sight, and a machine that can't walk in would stay hidden all visit.
    --    Still nothing = a cramped base; try again next tick rather than hide it.
    if not loc and immobile then
        loc = spotNearBench(benchLoc, bench, IMMOBILE_DIST)
            or spotNearBench(benchLoc, bench, IMMOBILE_DIST, { NoSight = true })
        if not loc then
            lastBail = "no spot near the bench for an immobile costume"
            LogDebug("TraderDirector - no spot near the bench for " .. pick.Costume .. "; retrying",
                SETTINGS.DEBUG_STORY)
            return
        end
    end

    if loc then
        place(pick, loc, (not immobile) and walkTarget(loc, benchLoc, bench) or nil, d, day, "at the bench", benchLoc)
        return
    end

    -- 4. Nothing usable near the bench (a cramped or heavily-built base): arrive out in the ring on
    --    an out-of-sight EQS point, then walk in. The query is still run from the PLAYER (its
    --    contexts are built around a pawn), but the RESULTS are filtered and scored against the
    --    BENCH, so "closest hidden point" means closest to the base.
    spawnPending = true
    Utils.QueueWork(function() spawnPending = false end, 10000)   -- safety release
    Placement.FindStalkerPoint(player, { Origin = benchLoc, MaxDist = FAR_DIST }, function(points)
        -- The EQS poll ran for up to 1.5s, so the bench wrapper is re-checked before it is used
        -- again (a dismantle in that window would leave a freed pointer). benchLoc is a plain
        -- FVector and stays valid either way.
        if IsNotValid(bench) then bench = nil end

        local far
        if points and #points > 0 then
            local bestD
            for _, p in ipairs(points) do
                local dist = Utils.DistSqXY(p, benchLoc)
                if not bestD or dist < bestD then far, bestD = p, dist end
            end
        end
        -- No hidden point in the ring either: a plain reachable navmesh spot around the bench beats
        -- skipping the visit. It arrives in view, which is fine - it is about to walk over anyway.
        far = far or Utils.GetSpawnPoint(benchLoc, FAR_DIST, NEAR_DIST, 25, NEAR_Z_TOL, 0)
        if not far then
            spawnPending = false
            LogDebug("TraderDirector - no spawn point this tick; retrying later", SETTINGS.DEBUG_STORY)
            return
        end

        -- Only mobile costumes get here (see step 3).
        place(pick, far, walkTarget(far, benchLoc, bench), d, day, "in the ring", benchLoc)
        spawnPending = false
    end)
end

-- [AUTHORITY, DEV] Run a visit RIGHT NOW through the real placement path (/au-tradervisit), not the
-- keybind spawn (which drops a trader at your feet and can't test placement). `costumeKey` optional;
-- nil takes the roster's next pick. Packs up whatever is out and clears the day gate so it can be
-- run back to back. Story gate skipped, ItemsFlag gate not. Consumes a schedule slot. Anchors on a
-- random online player, same as a real visit (in MP may pick someone else's bench).
-- Returns ok, reason.
function TD.ForceVisit(costumeKey)
    if not Utils.IsAuthority() then return false, "authority only" end
    if not SETTINGS.MODULES.TRADERS.Enabled then return false, "MODULES.TRADERS.Enabled is off" end
    if not STATE.StoryData then return false, "per-world save not loaded yet" end
    if not Utils.GetCurrentDay() then return false, "no day clock yet" end

    Traders = Traders or require("ModuleTraders.Traders")
    Traders.DespawnAll()                     -- make room; also empties STATE.SpawnedTraders

    local d = sched()
    d.NextSpawnDay = nil                     -- due now
    d.ActiveUntil  = nil
    spawnPending   = false                   -- clear a stuck async guard from an earlier attempt

    -- `forced` only has to survive the SYNCHRONOUS half of Tick (the pick), since the far-spawn
    -- path captures `pick` into its EQS closure before returning.
    forced = costumeKey or true              -- `true` = "roster's next, story gate off"
    lastBail = nil
    local ok, err = pcall(TD.Tick, STATE.StoryProgress or 0)
    forced = nil
    if not ok then return false, tostring(err) end
    if lastBail then return false, lastBail end
    -- No bail: placement is underway. The far-spawn tier finishes asynchronously (the EQS poll), so
    -- "underway" is as strong a guarantee as this can honestly give - the Log line is the receipt.
    return true
end

return TD
