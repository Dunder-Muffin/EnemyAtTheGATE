-- =======================================================================
-- EVENT 12 - PRAETORIUM PURIFIED ASSAULT  [AUTHORITY] - RESTARTABLE (latches per vignette)
--   Two handles, one set-piece - the blockade approach:
--     Event_INQ_PurifiedAssault  the assault itself. Starts if players are near the south
--                                entrance and at least 2/4 Purifiers are alive; ends when they
--                                reach the north spawn point. Gate: SM.GateINQPurifiedAssault.
--     Event_INQ_TankTurret       the Order tank at the mouth of the approach. Its own handle
--                                because the story gate silences the automated LMG on arrival,
--                                well before the assault; the assault then BREAKS the whole tank
--                                as its opening bang (PA.BlowTank). Gate: SM.GateINQTankTurret.
--   Dev: "/event INQ_PurifiedAssault" force-starts; "/event INQ_PurifiedAssaultStop" ends a test.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local EVU = require("ModuleStory.EventUtils")
local ASSETS = require("AnteCore.AssetManager")

local Log = Utils.Log
local LogDebug = Utils.LogDebug

local EV = {}

-- The two anchors the story gates also read (exported as EV.LOC at the foot of the file).
local PA_TRIGGER = FVector(104530, 39550, 1100)   -- the assault's south trigger
local TANK_AT    = FVector(104560, 45200, 1430)   -- the Order tank in the Command Blockade

-- =======================================================================
-- THE ASSAULT - every 30s the blockade fields whichever of Purified Grunt/Breacher/Rat are
-- missing (max 3), all walking south onto the trigger. The posted Purifier Rats stay ANCHORED,
-- never rooted - rooted, they can't fire.
-- =======================================================================

-- Event table
local PA = {
    TRIGGER   = PA_TRIGGER,                     -- the south trigger (see the anchors above)
    ABANDON   = 10000,                          -- >100m from the trigger = nobody is playing
    SPAWN     = FVector(104620, 45890, 1100),   -- the spawn ground behind the blockade
    END_NEAR  = 1500,                           -- within 15m of it = broken through (latch)

    -- Where the four Purifiers are posted
    PURIFIERS = {
        { at = FVector(105038, 44632, 1098) },
        { at = FVector(103528, 44889, 1098) },
        { at = FVector(104322, 43559, 748), Guard = true },
        { at = FVector(104836, 43567, 748), Guard = true },
    },
    PURIFIERS_RADIUS = 1500,
    PURIFIERS_MIN   = 2,       -- live (unique) Purifiers must EXCEED this; at or below = cell broken

    POLL_MS    = 2000,
    WAVE_MS    = 30000,   -- the refill beat: respawn whichever TYPES are missing
    WAVE_STAGGER_MS = 2500, -- gap between same-beat spawns (never a one-frame burst)
    MAX_MS     = 600000,  -- hard stop (10 min) - a place-trigger can be missed forever
    LOST_POLLS = 3,       -- consecutive cell-broken polls before it counts (wrappers can blink)

    -- The first order waits out the grunt rappel/mutation window (LONG_SPAWN_DELAY 2700): a
    -- destination written while the entrance montage still owns the body just gets eaten.
    MOVE_DELAY_MS  = 4000,

    POOL = { "Purified Grunt", "Purified Breacher", "Purified Rat" },

    -- The tank the assault detonates on the way in (PA.BlowTank)
    TANK        = TANK_AT,
    TANK_RADIUS = 2000,   -- see OT_RADIUS in StoryManager: this tank only, never a neighbour

    -- Every attacker this run has fielded: { npc, name, readyAt, done? }, pruned in place by
    -- PA.MissingTypes - so it never grows past what is actually standing in the approach.
    roster = {},

    -- Runtime state. `token` orphans every queued item on stop/restart; `done` is the
    -- until-next-vignette-reset latch (cleared only by PurifiedAssaultOnVignetteReset).
    run = { active = false, token = 0, done = false, rats = nil },
}

function EV.INQPurifiedAssault()
    local run = PA.run
    if run.active then Log("Purified Assault - already running (ignoring re-trigger)"); return end
    if EVU.LatchStops(run.done, "Purified Assault", "broken through this vignette (latched)") then
        return
    end

    -- Only runs start/stop check when enough Purifiers 
    local rats = {}
    for i, post in ipairs(PA.PURIFIERS) do rats[i] = PA.FindPurifier(post.at) end
    if PA.CountLive(rats) <= PA.PURIFIERS_MIN then
        Log("Purified Assault - not starting: the cell is already broken (need >"
            .. PA.PURIFIERS_MIN .. " posted Purifiers alive)")
        return
    end

    run.token    = run.token + 1
    run.active   = true
    run.elapsed  = 0
    run.nextWave = 0        -- the whole trio walks out on the first poll
    run.ratMiss  = 0
    run.rats     = rats
    PA.roster = {}

    PA.AnchorRats()   -- posted emplacements: anchored (never rooted - see the banner)
    PA.BlowTank()     -- the opening bang: the Order tank + its automated LMG (see PA.TANK)

    Log("Purified Assault - the blockade answers")
    PA.Tick(run.token)
end

-- Dev handle ("/event INQ_PurifiedAssaultStop"): quiet ending, leftover attackers despawned, and
-- the breakthrough latch CLEARED - the test loop is Stop -> re-trigger, no vignette reset needed.
-- (The latch is memory-only anyway, so a game restart clears it too.)
function EV.INQPurifiedAssaultStop()
    PA.Stop("stopped by hand", { Despawn = true })
    PA.run.done = false
end

-- Read by StoryManager's gate (never re-arm on top of a live run / a latched vignette).
function EV.PurifiedAssaultActive() return PA.run.active == true end
function EV.PurifiedAssaultDone()   return PA.run.done == true end

-- Vignette reset: clear the breakthrough latch, and orphan a run the teardown interrupted
-- (its queued ticks died with the WorkQueue; the stale `active` would block every restart).
function EV.PurifiedAssaultOnVignetteReset()
    PA.run.done = false
    PA.run.rats = nil
    if PA.run.active then
        PA.run.active = false
        PA.run.token = PA.run.token + 1
    end
end


-- =======================================================================
-- HELPERS
-- =======================================================================

-- The ticker - end-checks cheapest first, then the refill beat, then the escort
-- walk. Actor work is property reads plus at most one standing-order write per attacker per
-- waypoint; the only scans this event ever does are at start/stop.
function PA.Tick(token)
    local run = PA.run
    if not run.active or token ~= run.token or not STATE.ModEnabled then return end

    -- Broken through: latch for the rest of the vignette and free the Purifiers.
    if Utils.IsPlayerNearby(PA.SPAWN, PA.END_NEAR) then
        return PA.Stop("players reached the spawn ground", { Done = true })
    end
    if run.elapsed >= PA.MAX_MS then return PA.Stop("hard time cap", { Despawn = true }) end
    if not Utils.IsPlayerNearby(PA.TRIGGER, PA.ABANDON) then
        return PA.Stop("players left the blockade", { Despawn = true })
    end

    -- Count remaining purifiers, stop if 3 are killed
    local live = PA.CountLive(run.rats)
    if live <= PA.PURIFIERS_MIN then
        for i, rat in ipairs(run.rats or {}) do
            if Utils.IsActorInvalid(rat) then run.rats[i] = PA.FindPurifier(PA.PURIFIERS[i].at) end
        end
        live = PA.CountLive(run.rats)
    end
    if live > PA.PURIFIERS_MIN then
        run.ratMiss = 0
    else
        run.ratMiss = run.ratMiss + 1
        if run.ratMiss >= PA.LOST_POLLS then
            -- Players are right there: no despawn.
            return PA.Stop("the cell is broken (" .. live .. "/" .. #PA.PURIFIERS .. " Purifiers left)")
        end
    end

    -- REFILL BEAT: the first beat (elapsed 0) fields the whole trio; every later beat respawns
    -- whichever types have died since. Staggered so a wipe-refill never lands three spawns in
    -- one drain frame.
    if run.elapsed >= run.nextWave then
        run.nextWave = run.elapsed + PA.WAVE_MS
        local stagger = 0
        for _, name in ipairs(PA.MissingTypes()) do
            local nm = name
            Utils.QueueWork(function()
                if run.active and token == run.token then PA.SpawnOne(token, nm) end
            end, stagger)
            stagger = stagger + PA.WAVE_STAGGER_MS
        end
    end

    PA.Escort(run.elapsed)

    run.elapsed = run.elapsed + PA.POLL_MS
    Utils.QueueWork(function() PA.Tick(token) end, PA.POLL_MS)
end


-- The escort walk - everyone walks topside to the trigger and loiters there.
--   * LocationOfInterest is a STANDING order (the BT re-arms it after every fight -
--     AVU.SetPointOfInterest), so each attacker needs ONE successful write, not the old 6s
--     AttackMove re-issue loop.
--   * Orders are deferred while the body is fighting (never fight the combat AI for it), and a
--     failed write (controller not possessed yet) just retries next poll.
function PA.Escort(elapsed)
    for _, e in ipairs(PA.roster) do
        local npc = e.npc
        if not e.done and elapsed >= e.readyAt
            and Utils.IsActorValid(npc) and not Utils.IsDeadSafe(npc) then

            local fighting = false
            pcall(function() fighting = npc.CombatState == true end)
            if not fighting and AVU.SetPointOfInterest(npc, PA.TRIGGER) then
                e.done = true
            end
        end
    end
end


-- Field one attacker of the given TYPE out of the spawn ground. Routing is the
-- escort's job - readyAt holds its first write past the rappel/mutation window, so there are no
-- nested move QueueWorks to orphan.
function PA.SpawnOne(token, name)
    local run = PA.run
    EVU.SpawnAt(name, PA.SPAWN, {
        Fuzz = 250,
        callback = function(npc)
            if not run.active or token ~= run.token then return end
            PA.roster[#PA.roster + 1] = {
                npc     = npc,
                name    = name,
                readyAt = run.elapsed + PA.MOVE_DELAY_MS,
            }
        end,
    })
end


-- End the run. The token bump orphans every queued tick/move order in one write.
--   * opts.Done    = set the breakthrough latch.
--   * opts.Despawn = quietly remove leftover attackers. Only on endings where nobody is watching -
--                    never mid-fight.
function PA.Stop(reason, opts)
    local run = PA.run
    if not run.active then return end
    run.active = false
    run.token = run.token + 1
    if opts and opts.Done then run.done = true end

    -- Post anchors are left standing on purpose: a guard walking back to its post is the steady
    -- state, and a restart just re-asserts them.
    run.rats = nil

    if opts and opts.Despawn then
        for i = #PA.roster, 1, -1 do
            local npc = PA.roster[i].npc
            if Utils.IsActorValid(npc) and not Utils.IsDeadSafe(npc) then
                -- Staggered destroys (the KillNpcsInRadius lesson: each teardown is real work).
                Utils.QueueWork(function()
                    pcall(function() if IsValid(npc) then npc:K2_DestroyActor() end end)
                end, i * 200)
            end
        end
    end
    PA.roster = {}

    Log("Purified Assault - over (" .. tostring(reason) .. ")")
end


-- Anchor the posted Purifiers (LocationOfInterest - they step out to fight/bless
-- and walk back on their own), re-probing when a stored wrapper has gone stale from stream churn.
--   * REPLACES the old RootInPlace emplacement: a MOVE_None root wedges BT_Main_FlameRat's fire
--     path (the rooted-BT-stall family), so rooted Purifiers never fired their blessing gout.
--   * Guard posts (the basement pair) also register with H.SetGuardAnchor - their anchor never
--     releases on damage.
function PA.AnchorRats()
    local OFR = require("AnteNPCs.OrderFlameRatHelpers")   -- lazy: keeps Events require-cycle-free
    for i, post in ipairs(PA.PURIFIERS) do
        local rat = PA.run.rats and PA.run.rats[i]
        if Utils.IsActorInvalid(rat) then rat = PA.FindPurifier(post.at) end
        if rat and not Utils.IsDeadSafe(rat) then
            AVU.SetPointOfInterest(rat, post.at)
            OFR.SetGuardAnchor(rat, post.Guard)
        end
    end
end


-- The opening bang - detonate the Order tank at the mouth of the approach.
--   * All the work is the tank half's (EV.DisableTankTurretsAt with Break), which owns the FX preload +
--     path re-resolve the break needs; this is just the assault's trigger for it.
--   * No proximity guard of its own: the assault only starts with a player at the trigger, and a
--     tank that isn't streamed in simply isn't found.
function PA.BlowTank()
    if not PA.TANK then return end
    EV.DisableTankTurretsAt(PA.TANK, PA.TANK_RADIUS,
        { Break = true, Label = "PURIFIED ASSAULT" })
end


-- Which of the Purified NPCs are missing
function PA.MissingTypes()
    local alive = {}
    for i = #PA.roster, 1, -1 do
        local e = PA.roster[i]
        if Utils.IsActorInvalid(e.npc) or Utils.IsDeadSafe(e.npc) then
            table.remove(PA.roster, i)
        else
            alive[e.name] = true
        end
    end

    local missing = {}
    for _, name in ipairs(PA.POOL) do
        if not alive[name] then missing[#missing + 1] = name end
    end
    return missing
end


-- Live UNIQUE Purifiers among the post wrappers, deduped by ActorKey -
-- neighbouring posts can probe the same body, and a double-counted survivor would keep a broken
-- cell alive.
function PA.CountLive(rats)
    local seen, live = {}, 0
    for _, rat in ipairs(rats or {}) do
        if Utils.IsActorValid(rat) and not Utils.IsDeadSafe(rat) then
            local key = Utils.ActorKey(rat)
            if key and not seen[key] then
                seen[key] = true
                live = live + 1
            end
        end
    end
    return live
end


-- The live posted Purifier nearest `loc`, or nil. Name-matched on the variant DisplayName, which
-- only our mutation writes - the same probe the Night Realm uses to find its leader.
function PA.FindPurifier(loc, radius)
    local best, bestDist
    for _, npc in ipairs(AVU.GetNearbyNpcs(loc, radius or PA.PURIFIERS_RADIUS) or {}) do
        if Utils.GetActorName(npc) == "Purifier" and not Utils.IsDeadSafe(npc) then
            local ok, at = pcall(function() return npc:K2_GetActorLocation() end)
            local d = (ok and at) and Utils.DistSq(loc, at) or math.huge
            if not bestDist or d < bestDist then best, bestDist = npc, d end
        end
    end
    return best
end


-- =======================================================================
-- THE ORDER TANK  (Event_INQ_TankTurret)
--   Silence the tank-mounted automated LMG. Two modes: DISABLE (default) is two plain property
--   writes, nothing replicated or loaded, safe from any drain. BREAK (opts.Break) is the game's
--   own destroy path and cold-loads FX, so it goes LoadAsync -> QueueWork -> a by-path
--   re-resolve. Full mechanics in AnNotes/Modules/Events.md.
-- =======================================================================

local TANK_CLASS  = "DestructibleTank_C"
-- How far from the anchor a tank still counts as "the" tank. Generous - the anchor is a hand-noted
-- approximation. Also what rejects the class-default object (it reads as origin).
local TANK_RADIUS = 10000

-- Everything SetStateBroken can cold-load. Only needed for opts.Break.
local TANK_BREAK_PRELOAD = {
    "/Game/Particles/Niagara_NanoNuke.Niagara_NanoNuke",
    "/Game/Audio/Explosion/Explosion_01_Cue.Explosion_01_Cue",
}

-- The BREAK half, off-hook. Split out because it needs the preload + path hop; the disable path
-- deliberately needs neither.
local function breakTank(tank, label)
    local path = Utils.ObjectPath(tank)
    if not path then return end

    ASSETS.LoadAsync(TANK_BREAK_PRELOAD, function()
        Utils.QueueWork(function()
            -- Re-resolve across the hop: a wrapper captured into a deferred callback can be freed,
            -- and IsValid lies about it (S3).
            local t = Utils.ResolveByPath(path)
            if not t or Utils.IsActorInvalid(t) then return end

            local broken = false
            pcall(function() broken = t.Broken end)
            if broken then return end   -- a player beat us to it between the load and the drain

            -- The tank's own override: parent break (mesh swap, world-save entry) + LMG destroy.
            local ok = pcall(function() t:Server_InitialBreakEvent() end)
            if ok then
                Log("Story EVENT - " .. label .. ": tank DESTROYED (turret went with it)")
            else
                Utils.LogBad("Story EVENT - " .. label .. ": Server_InitialBreakEvent failed")
            end
        end, 0)
    end)
end

-- Disable (or break) every Order tank turret within `radius` of `loc`. Shared by the story gate
-- (fixed anchor) and the /au-turret cheat (at your feet), so the behaviour is defined once.
-- opts: Break (destroy the tank instead of muting the gun), Label (log prefix).
-- Returns the number of tanks acted on - the gate uses it to decide whether it's done.
function EV.DisableTankTurretsAt(loc, radius, opts)
    if not Utils.IsAuthority() or not loc then return 0 end
    opts = opts or {}
    local label = opts.Label or "INQ TANK TURRET"
    local hits = 0

    -- FindAllOf, not SphereOverlap: this is a placed static prop, so the class filter should be
    -- the ONLY thing that matters - not which collision channel its mesh sits on. Affordable
    -- because callers are edge-triggered (arrival / a typed command), never a cadence - see the
    -- 15s FindAllOf rule in CLAUDE.md.
    for _, tank in ipairs(FindAllOf(TANK_CLASS) or {}) do
        if Utils.IsActorValid(tank) then
            local tloc = tank:K2_GetActorLocation()
            if tloc and Utils.WithinDistance(loc, tloc, radius or TANK_RADIUS) then
                local broken = false
                pcall(function() broken = tank.Broken end)

                if broken then
                    -- Already destroyed (a player got it, or we did on a previous pass). The LMG
                    -- went with it; nothing to do.
                    LogDebug("Story EVENT - " .. label .. ": tank already broken", SETTINGS.DEBUG_STORY)
                elseif opts.Break then
                    hits = hits + 1
                    breakTank(tank, label)
                else
                    local lmg = tank.LMG
                    if Utils.IsActorValid(lmg) then
                        hits = hits + 1
                        -- Plain property writes, server-side only: neither replicates (clients see
                        -- CurrentTarget / TargetTurretRotation, which just stop changing), so no
                        -- MarkReplicatedDirty and no load.
                        pcall(function()
                            lmg.AutomatedTurret = false
                            lmg.TurretMaxRange  = 0
                        end)
                        Log(string.format("Story EVENT - %s: turret muted at (%.0f, %.0f, %.0f)",
                            label, tloc.X, tloc.Y, tloc.Z))
                    end
                end
            end
        end
    end

    if hits == 0 then
        LogDebug("Story EVENT - " .. label .. ": no Order tank within " .. (radius or TANK_RADIUS) ..
            "uu (not streamed in?)", SETTINGS.DEBUG_STORY)
    end
    return hits
end

function EV.INQTankTurret(opts)
    if not Utils.IsAuthority() then return end

    local loc = TANK_AT

    -- IsLocationLoaded, not the Utils.AreaLoaded player-radius guard: the turret is live the moment
    -- its sublevel streams in, well outside any proximity radius (0.5s target scan from BeginPlay
    -- regardless of distance). Also the right guard for a manual /event from another zone.
    if not Utils.IsLocationLoaded(loc) then
        Log("Story EVENT - INQ TANK TURRET skipped (that level is not streamed in)")
        return
    end

    EV.DisableTankTurretsAt(loc, TANK_RADIUS, opts)
end


-- The anchors StoryManager's gate reads, merged into EVENTS.LOC by ModuleStory/Events
-- (the coord lives next to the event that spawns on it, so there is one copy of each).
EV.LOC = { PurifiedAssault = PA_TRIGGER, OrdTank = TANK_AT }


return EV
