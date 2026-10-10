-- =======================================================================
-- HydroBridge [AUTHORITY] - the ongoing Hydroplant bridge assault (Event_Hydro_Ongoing_Bridge).
-- Between Voussoir and the spillway the Order keeps throwing squads across the bridge at the
-- Gatekeeper robots dug in behind the end gate, and the players walk into someone else's war.
--   * Order muster on the bridge in pairs and march on the gate; the robots are a fixed garrison
--     behind it. Both sides fight whatever they meet on the way and hold at the gate.
--   * Two AI facts do all the work here, and without either one both sides wander off: every
--     body gets a LONG TargetMemory, and the gate is a STANDING order, not an aggro push.
--     See hbGiveOrders.
--   * Two beats on ONE self-rescheduling ticker - one thing to stop, one place a beat can drift.
--     The Order beat is a rolling wave under an alive cap; the robot beat re-forms a whole post
--     that has fallen (see hbRobotWave).
--   * Nothing either side leaves is lootable, and nothing it leaves is permanent: no game
--     spawner owns these bodies, so this event owns their corpses too (see the reaper).
--   * The gate is unlocked once at the start, through the keypad's own native trigger.
--   Dev: "/event Hydro_Ongoing_Bridge" force-starts, "/event Hydro_Ongoing_BridgeStop" ends one.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local ENUMS = require("AnteData.Enums")
local EVU = require("ModuleStory.EventUtils")

local Log = Utils.Log
local LogBad = Utils.LogBad
local LogDebug = Utils.LogDebug

local HB = {}


-- =======================================================================
-- THE GROUND
-- =======================================================================

-- The objective, and the anchor everything else is measured from: the ground behind the end gate.
local GATE = FVector(-38920, 16970, 560)

-- Where the robots come out of. Close to the gate on purpose - they are the garrison, not a
-- second attacking side, so their march order is barely a march.
local ROBOT_SP = FVector(-39422, 17242, 600)

-- The Order's muster marks, west across the bridge (~90m out). One is picked per body.
local BRIDGE_SP = {
    FVector(-45520, 10510, 1000),
    FVector(-45220, 11390, 1000),
    FVector(-44520, 11450, 1000),
}

-- The gate's keypad. A level-placed prop has no identity but its LOCATION, so the nearest button
-- to this coord wins - the Security cutscene gate shape. "/au-keypads" prints what is standing there.
local KEYPAD = FVector(-38690, 15610, 890)
local KEYPAD_NEAR = 500

-- =======================================================================
-- THE FIGHT
-- =======================================================================

local CFG = {
    -- Story window. Dams_ActivatedPump3 (Voussoir) opens it; Dams_SpillwayOpen closes it, and
    -- the close is EXCLUSIVE - reaching the spillway is the beat the siege is over.
    StoryMin = 54,
    StoryMax = 59,

    Active  = 12000,   -- 120m from the gate: reaches the far bridge mark with room to spare
    PollMs  = 2000,

    -- Both sides field on their own beat, capped by what is STANDING rather than by what has been
    -- spawned - a wave that arrives into a full field simply doesn't. At this cadence the cap is
    -- the real throttle: it holds a steady pressure instead of letting a cleared bridge stay
    -- cleared for a minute.
    OrderEveryMs = 20000,
    OrderMax     = 7,

    -- The robots are a GARRISON, not a wave: the whole post comes back at once or not at all,
    -- so killing one does not summon its replacement into the fight you are still having.
    RobotEveryMs = 20000,   -- how often the post is re-checked, not how often it fields
    RobotClear   = 1500,    -- 15m: nobody may be standing on the spawn point when it refills

    -- A pair every beat: a plain Grunt leads and one body off the pool follows it. The lead is
    -- fixed so the column always reads as Order line infantry with something attached, rather
    -- than a run of whatever the roll happened to give.
    OrderLead   = "Grunt",
    SpawnGapMs  = 1500,

    -- A player this close to a muster mark is better evidence than the level manager's own
    -- answer - see hbMarkReady. Deliberately tight: it is a claim about THIS point, not about
    -- the sector or the level.
    MarkNear = 6000,

    -- First orders wait out the rappel/mutation window (LONG_SPAWN_DELAY 2700): a destination
    -- written while the entrance montage still owns the body is just eaten.
    OrderDelayMs = 4000,

    -- Seconds a body remembers an enemy it can no longer see (native 9). At the native value the
    -- controller drops the target, DELETES it from perception and stops re-targeting - which is
    -- both halves of what went wrong on the first test. See hbGiveOrders.
    TargetMemory = 60,

    -- Release for a spawn that never lands, so an in-flight body can't hold its slot against the
    -- cap forever. Must outlast the worst case: NpcSpawner's 200ms-per-queued-spawn stagger, then
    -- an async class load.
    PendingMs = 20000,

    -- Corpse reaping. Nothing here has an owning spawner, so the game's own despawn never comes
    -- for these bodies - see the reaper.
    CorpseMs      = 25000,
    ReapPerBeat   = 2,
    DespawnGapMs  = 200,
}

-- The second Order spawn
local ORDER_POOL = {
    "Grunt", "Grunt", "Grunt_Guard", "Grunt_Medic", 
    "Grunt_Captain", "Grunt_Shotgun", "Sweeper", "Assault Sniper",
}

-- The post, in full. "Event Big Bot", not the Big Bot: the boss version summons its own A2
-- reinforcements and stuns itself on an overheat, neither of which belongs on a body that respawns.
local ROBOT_GARRISON = { "Event Big Bot", "Robot_Security" }


-- =======================================================================
-- RUNTIME
-- =======================================================================

-- Every body this siege has fielded: { npc, side, deadAt? }. Pruned in place by hbCensus; a
-- deadAt stamp is the reaper's clock. Plain array - entries are dropped as soon as they read
-- invalid, so it never outgrows what is actually standing.
local roster = {}

-- `token` is the generation counter: every queued item carries the token it was scheduled under
-- and bails once that no longer matches, so a stop or restart can never be undone by an item
-- already in flight. `manual` is the dev override that skips the story/presence gate.
local run = { active = false, token = 0, manual = false, pend = { order = 0, robot = 0 } }

local validated = false
local gateOpened = false   -- the keypad has been triggered (or was already open) this world

-- Forward-declared: a bare `local function` below would be nil at the call sites above it.
local hbTick, hbCensus, hbOrderWave, hbRobotWave, hbSpawn, hbGiveOrders, hbReap
local hbEscort, hbUnlockGate, hbStop, hbValidate, hbPickMark, hbMarkReady


-- =======================================================================
-- START / STOP
-- =======================================================================

function HB.Start(why)
    if run.active then return end
    hbValidate()

    run.token     = run.token + 1
    run.active    = true
    run.elapsed   = 0
    run.nextOrder = 0    -- the first squad steps off immediately
    run.nextRobot = 0
    run.wave      = 0
    run.pend      = { order = 0, robot = 0 }
    roster = {}          -- last siege's dead are not this siege's headcount

    hbUnlockGate()
    Log("Hydro Bridge - the Order comes across (" .. tostring(why) .. ")")

    -- Which marks the level manager admits to, once per start. A mark that reads UNLOADED with a
    -- player standing on it is one to nudge - hbMarkReady covers for it, but the coord is wrong.
    if SETTINGS.DEBUG_STORY then
        for i, spot in ipairs(BRIDGE_SP) do
            LogDebug(("Hydro Bridge - muster mark %d %s: sector %s"):format(
                i, Utils.PrintRoundedLocation(spot),
                Utils.IsLocationLoaded(spot) and "LOADED" or "UNLOADED"), true)
        end
    end

    hbTick(run.token)
end

function hbStop(reason, despawn)
    if not run.active then return end
    run.active = false
    run.token = run.token + 1   -- orphans every queued beat, wave slot and order in one write

    local pulled = 0
    if despawn then
        for i = #roster, 1, -1 do
            local npc = roster[i].npc
            if Utils.IsActorValid(npc) then
                pulled = pulled + 1
                -- Staggered destroys: each teardown is real work, and a wiped field is a dozen.
                Utils.QueueWork(function()
                    pcall(function() if IsValid(npc) then npc:K2_DestroyActor() end end)
                end, pulled * CFG.DespawnGapMs)
            end
        end
    end
    roster = {}

    Log(("Hydro Bridge - over (%s), %d pulled"):format(tostring(reason), pulled))
end

function HB.Stop(reason) hbStop(reason or "stopped by hand", true) end

-- Read by StoryManager's gate: never arm on top of a live siege.
function HB.Active() return run.active == true end

-- Dev handle ("/event Hydro_Ongoing_Bridge"): a MANUAL override that ignores the story window and
-- the presence gate, for testing before the story reaches it. The spawn marks still have to be
-- streamed in, so run it from the bridge - anywhere else it just holds every slot.
function HB.Toggle()
    run.manual = not run.manual
    if run.manual then HB.Start("manual") else HB.Stop("manual override off") end
end

-- Per-world reset. A teardown wipes the WorkQueue with beats still queued, so a flag left set
-- here would kill the siege for the whole next world - and the keypad latch belongs to the world
-- whose keypad it read.
function HB.Reset()
    run.active, run.manual = false, false
    run.token = run.token + 1
    run.pend = { order = 0, robot = 0 }
    roster = {}
    gateOpened = false
end


-- =======================================================================
-- THE TICKER - end checks, then the two field beats, then the reaper. It only schedules; the
-- actor work all happens on the items it queues.
-- =======================================================================

function hbTick(token)
    if not run.active or token ~= run.token or not STATE.ModEnabled then return end

    if not run.manual then
        local story = STATE.StoryProgress or 0
        if story >= CFG.StoryMax then return hbStop("the spillway is open", true) end
        if not Utils.IsPlayerNearby(GATE, CFG.Active) then
            return hbStop("nobody left at the bridge", true)
        end
    end

    local order, robot = hbCensus()

    if run.elapsed >= run.nextOrder then
        run.nextOrder = run.elapsed + CFG.OrderEveryMs
        hbOrderWave(token, order)
    end

    if run.elapsed >= run.nextRobot then
        run.nextRobot = run.elapsed + CFG.RobotEveryMs
        hbRobotWave(token, robot)
    end

    hbEscort()
    hbReap()

    run.elapsed = run.elapsed + CFG.PollMs
    Utils.QueueWork(function() hbTick(token) end, CFG.PollMs)
end


-- Live headcount per side, pruning the roster in place. A spawn still in flight counts against
-- its side: a wave's slots are seconds apart but a spawn is not instant, and an uncounted one
-- lets the next slot overshoot the cap. A body that has died since the last pass is STAMPED here
-- rather than dropped - the reaper needs its corpse, and its clock starts now.
function hbCensus()
    local order, robot = 0, 0
    for i = #roster, 1, -1 do
        local e = roster[i]
        if Utils.IsActorInvalid(e.npc) then
            table.remove(roster, i)
        elseif Utils.IsDeadSafe(e.npc) then
            e.deadAt = e.deadAt or Utils.NowMs()
        elseif e.side == "order" then
            order = order + 1
        else
            robot = robot + 1
        end
    end
    return order + run.pend.order, robot + run.pend.robot
end


-- =======================================================================
-- FIELDING
-- =======================================================================

-- One Order pair: the fixed lead, then one off the pool. The cap is re-tested per SLOT rather
-- than per wave, because the pair takes seconds to finish arriving and the fight moves. Testing it
-- in slot order also means the lead gets the last free place, never the follower.
function hbOrderWave(token, alive)
    run.wave = run.wave + 1
    local wave = { CFG.OrderLead, ORDER_POOL[math.random(#ORDER_POOL)] }

    local batch = {}

    for i, name in ipairs(wave) do
        Utils.QueueWork(function()
            if not run.active or token ~= run.token then return end
            local live = hbCensus()
            if live >= CFG.OrderMax then
                LogDebug("Hydro Bridge - at the Order cap, holding this slot", SETTINGS.DEBUG_STORY)
                return
            end
            hbSpawn(token, "order", name, hbPickMark(), batch)
        end, (i - 1) * CFG.SpawnGapMs)
    end

    -- ONE order item for the whole pair, queued past the last body's mutation window. Sibling
    -- per-body chains queued together do NOT stay in step on the newest-first drain.
    Utils.QueueWork(function()
        if run.active and token == run.token then hbGiveOrders(batch, true) end
    end, (#wave - 1) * CFG.SpawnGapMs + CFG.OrderDelayMs)

    LogDebug(("Hydro Bridge - wave %d: %s + %s (%d alive)")
        :format(run.wave, wave[1], wave[2], alive), SETTINGS.DEBUG_STORY)
end


-- Refill the garrison, all of it at once, and only when the post is genuinely empty and nobody is
-- watching it. Three gates, cheapest first:
--   * ONE SURVIVOR HOLDS THE POST. Replacing casualties one at a time would trickle a fresh bot
--     into a fight already in progress; this way the post falls, and then comes back.
--   * NOT UNDER SOMEONE'S NOSE. A body appearing at a spawn point a player is standing on reads
--     as a cheat, so the refill waits for them to move off (RobotClear).
--   * The mark still has to be live, like any other spawn.
function hbRobotWave(token, alive)
    if alive > 0 then return end   -- `alive` counts in-flight spawns too, so this can't double-fire

    if Utils.IsPlayerNearby(ROBOT_SP, CFG.RobotClear) then
        LogDebug("Hydro Bridge - the robot post is empty but someone is standing on it, holding",
            SETTINGS.DEBUG_STORY)
        return
    end
    if not hbMarkReady(ROBOT_SP) then
        LogDebug("Hydro Bridge - robot post not live, holding", SETTINGS.DEBUG_STORY)
        return
    end

    local batch = {}
    for i, name in ipairs(ROBOT_GARRISON) do
        Utils.QueueWork(function()
            if run.active and token == run.token then
                hbSpawn(token, "robot", name, ROBOT_SP, batch)
            end
        end, (i - 1) * CFG.SpawnGapMs)
    end

    Utils.QueueWork(function()
        if run.active and token == run.token then hbGiveOrders(batch) end
    end, (#ROBOT_GARRISON - 1) * CFG.SpawnGapMs + CFG.OrderDelayMs)

    LogDebug("Hydro Bridge - the garrison re-forms", SETTINGS.DEBUG_STORY)
end


-- Is this mark safe to spawn on? The hazard is real - a body spawned into an ARRIVING sector comes
-- back IsActorValid = false, MutateActor bails, EVU.SpawnOne drops it, and an un-mutated base NPC
-- is left standing - so the game's own answer is asked first.
--   * But a player standing AT the mark outranks that answer. IsLocationLoaded is a point-in-volume
--     test, and a bridge deck spanning two sectors can sit outside every volume: it then reads
--     UNLOADED however close anyone is standing, and half the muster marks silently stop working.
--     That case is provably safe to spawn into - IsLevelLoaded returns TRUE outright when a body
--     overlaps NO level volume, so IsActorValid passes and the bail never happens.
--   * This is not the "any player in the level" proxy that PlacedSpawns rejects. That one went
--     true as soon as a player entered the level, long before the sector around the coord was up.
--     MarkNear is a claim about this point only.
function hbMarkReady(spot)
    if not spot then return false end
    return Utils.IsLocationLoaded(spot) or Utils.IsPlayerNearby(spot, CFG.MarkNear)
end


-- A muster mark that is actually live, starting from a random one. Rotating rather than rolling
-- once matters: with one of three marks sitting in a streaming gap, a single random pick quietly
-- loses a third of every wave.
function hbPickMark()
    local n = #BRIDGE_SP
    local start = math.random(n)
    for i = 0, n - 1 do
        local spot = BRIDGE_SP[(start + i - 1) % n + 1]
        if hbMarkReady(spot) then return spot end
    end
    return nil
end


-- Field one body and enrol it. `batch` is the wave's order list, filled by the callback.
--   * Exact: these are hand-authored marks. The default SpawnAt path re-rolls within Fuzz and
--     snaps with a +/-600 Z extent, which is how a placed body ends up on another storey.
--   * A nil spot means every mark failed hbMarkReady - the sector really is not up.
function hbSpawn(token, side, name, spot, batch)
    if not spot then
        LogDebug("Hydro Bridge - no live spawn mark for the " .. side .. ", skipping",
            SETTINGS.DEBUG_STORY)
        return
    end

    -- The slot is claimed HERE, not when the body lands (see hbCensus). Released either way, and
    -- by a watchdog if the spawn never calls back at all.
    run.pend[side] = run.pend[side] + 1
    local released = false
    local function release()
        if released then return end
        released = true
        run.pend[side] = math.max(0, run.pend[side] - 1)
    end
    Utils.QueueWork(release, CFG.PendingMs)

    EVU.SpawnAt(name, spot, {
        Exact = true,
        callback = function(npc)
            release()
            if not run.active or token ~= run.token then return end

            local entry = { npc = npc, side = side }
            roster[#roster + 1] = entry
            batch[#batch + 1] = entry   -- the ENTRY, so hbGiveOrders can record the order landing

            -- Before any order: at the native 9s memory a body that loses sight of its enemy has
            -- it deleted from perception outright, and then re-targets nothing. See CFG.TargetMemory.
            AVU.SetTargetMemory(npc, CFG.TargetMemory)

            -- These have somewhere to be. Without this, a body between fights drifts on the idle
            -- patrol instead of holding the ground it took. (Retries until the controller possesses.)
            AVU.SetNoPatrol(npc)

            -- TWO loot systems and, for the robots, a third: StripLoot covers the native death
            -- drop, SuppressScriptedLoot the variant's own OnDeath drop, ClearGibLoot the salvage
            -- a gib pays out unconditionally. `true` keeps both sides GIBBABLE - the Order's
            -- salvage is deliberately left alone.
            AVU.StripLoot(npc, true)
            AVU.SuppressScriptedLoot(npc)
            if side == "robot" then
                AVU.ClearGibLoot(npc)
            else
                -- The helmet's DEATH drop only. The pop-off a head hit earns is left in.
                pcall(function() npc.Apoc_ForceHelmetOffOnDeath = false end)
            end

            LogDebug("Hydro Bridge - " .. tostring(name) .. " joins the " .. side,
                SETTINGS.DEBUG_STORY)
        end,
    })
end


-- A wave's marching orders. Everything goes to the gate and fights whatever is in the way.
-- TWO orders, and each covers the other's failure:
--   * LocationOfInterest is the STANDING one. The BT re-arms it on every investigate reset and
--     nothing clears it on arrival, so a body that loses a fight's target resumes the march by
--     itself and then loiters at the gate. This is what a bait aggro cannot do.
--   * AttackMove is the OPENING one: the bait makes them cross at combat speed rather than walk
--     the 90m. Its goal is captured by value as the order lands, so the bait parking afterwards
--     can't disturb them - but the target itself lapses, which is exactly why the standing order
--     underneath it is not optional.
-- Written in that order on purpose: the standing destination exists before anything puts the body
-- into combat, so there is never a window where it has neither.
--
-- `rush` is the ORDER only. The bait leaves itself as the body's COMBAT TARGET and then parks at
-- the origin - harmless to a body that only needs the captured move goal, but the garrison spawns
-- 6m from the gate and has no distance to cover, so the rush buys it nothing and costs it a target
-- pointing off the map. The Event Big Bot aims its lunges and its discs at whatever
-- GetCurrentCombatTarget() returns, which is how it walked out of its own post.
function hbGiveOrders(batch, rush)
    local toGate = {}

    for _, e in ipairs(batch) do
        if Utils.IsActorValid(e.npc) and not Utils.IsDeadSafe(e.npc) then
            e.poi = AVU.SetPointOfInterest(e.npc, GATE)   -- a miss is retried by hbEscort
            toGate[#toGate + 1] = e.npc
        end
    end

    -- Bait is pooled and self-managed (AVU.SpawnAggroBait); never destroy it.
    if rush and #toGate > 0 then AVU.AttackMove(toGate, GATE) end
end


-- Retry the standing order for anything whose write missed - a body spawned into a controller that
-- was not possessed yet. Deferred while it is fighting: never fight the combat AI for the body.
function hbEscort()
    for _, e in ipairs(roster) do
        if not e.poi and not e.deadAt and Utils.IsActorValid(e.npc) then
            local fighting = false
            pcall(function() fighting = e.npc.CombatState == true end)
            if not fighting then e.poi = AVU.SetPointOfInterest(e.npc, GATE) end
        end
    end
end


-- =======================================================================
-- CORPSES
-- =======================================================================

-- Clear the dead. A script-spawned NPC belongs to no spawner group, so the game never unloads it
-- - and stripping its loot takes it off the native fade-out path as well (that only runs on the
-- branch that actually dropped something). Left alone, an hour of this siege is a bridge paved
-- with bodies. Budgeted per beat: a destroy is real work and a wipe kills six at once.
function hbReap()
    local now = Utils.NowMs()
    local left = CFG.ReapPerBeat

    for i = #roster, 1, -1 do
        if left <= 0 then return end
        local e = roster[i]
        if e.deadAt and now - e.deadAt >= CFG.CorpseMs then
            table.remove(roster, i)
            left = left - 1
            local npc = e.npc
            -- Off the ticker's own item: a teardown runs EndPlay and everything hanging off it.
            Utils.QueueWork(function()
                pcall(function() if IsValid(npc) then npc:K2_DestroyActor() end end)
            end, left * CFG.DespawnGapMs)
        end
    end
end


-- =======================================================================
-- THE GATE
-- =======================================================================

-- Open the end gate through the keypad's own native trigger, once per world.
--   * TriggerButtonWithoutUser is Button_Generic's own no-player entry point: it runs the same
--     arm a successful code entry does - Activated, replicated, OnRep, save data, and the
--     ButtonPressed broadcast the door is listening on - while skipping the security-level and
--     world-flag checks a player would have to pass. So the gate opens for good.
--   * ONLY on a button reading locked. A non-OneTimeUse button TOGGLES on that entry point, so
--     firing it at an open gate would shut it.
--   * Scanned once per start: FindAllOf on a cadence is the banned microlag pattern.
function hbUnlockGate()
    if gateOpened then return end

    local best, bestD
    for _, b in ipairs(FindAllOf("Button_Generic_C") or {}) do
        if Utils.IsActorValid(b) then
            local loc = b:K2_GetActorLocation()
            -- The distance test also rejects the class-default object (it reads as origin).
            if loc and Utils.WithinDistance(KEYPAD, loc, KEYPAD_NEAR) then
                local d = Utils.DistSq(KEYPAD, loc)
                if d and (not bestD or d < bestD) then best, bestD = b, d end
            end
        end
    end

    if not best then
        LogDebug("Hydro Bridge - no button at the authored keypad coord (/au-keypads reads it)",
            SETTINGS.DEBUG_STORY)
        return
    end

    gateOpened = true
    local on = false
    pcall(function() on = best.Activated == true end)
    if on then
        LogDebug("Hydro Bridge - the gate was already unlocked", SETTINGS.DEBUG_STORY)
        return
    end

    pcall(function() best:TriggerButtonWithoutUser() end)
    Log("Hydro Bridge - the end gate unlocks")
end


-- =======================================================================
-- GATE TICK - called from StoryManager.Tick. Story window plus presence; the manual override
-- owns the siege outright while it is set.
-- =======================================================================

function HB.GateTick(story)
    if not STATE.ModEnabled or run.manual then return end

    if story >= CFG.StoryMin and story < CFG.StoryMax
        and Utils.IsPlayerNearby(GATE, CFG.Active) then
        if not run.active then HB.Start("story " .. story) end
    elseif run.active then
        hbStop(story >= CFG.StoryMax and "the spillway is open" or "nobody left at the bridge", true)
    end
end


-- Pool typos are silent otherwise - an unknown name spawns nothing and logs one line deep inside
-- NpcSpawner, one body short per wave forever.
function hbValidate()
    if validated then return end
    validated = true
    local VARIANTS = require("AnteVariants.Variants")   -- lazy: the defs reach back into ModuleStory
    for _, pool in ipairs({ ORDER_POOL, ROBOT_GARRISON, { CFG.OrderLead } }) do
        for _, name in ipairs(pool) do
            if not VARIANTS[name] and not ENUMS.NpcClasses[name] then
                LogBad("Hydro Bridge - unknown spawn '" .. tostring(name)
                    .. "' (not a variant or an NpcClasses row)")
            end
        end
    end
end


return HB
