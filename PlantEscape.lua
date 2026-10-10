-- =======================================================================
-- PlantEscape [AUTHORITY] - the Power Services exit ambush (Event_Plant_Escape).
-- Opening the Plant exit calls the zone down on the players: six waves come up the two
-- approach halls and converge on the door they just unlocked, while they are still standing
-- at it.
--   * Two lanes (BLUE, ORANGE) on ONE wave clock. Every wave fields both, so the pressure
--     arrives from both sides at once rather than alternating.
--   * ONE self-rescheduling ticker, `token`-generation guarded - one thing to stop, and a
--     stop can't be undone by a beat already in flight.
--   * The halls are ~50m of open floor, so the whole job is making bodies actually WALK it:
--     see peGiveOrders, which is the HydroBridge recipe.
--   * ONE-TIME per world, latched by StoryManager (GATE 6). Leaving cancels it for good.
--   Dev: "/event Plant_Escape" force-starts it, "/event Plant_EscapeStop" ends and clears one.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local EVU = require("ModuleStory.EventUtils")

local Log = Utils.Log
local LogDebug = Utils.LogDebug

local PE = {}


-- =======================================================================
-- THE GROUND
-- =======================================================================

-- The objective: the Plant exit keypad the players just used. Both lanes converge here, and it
-- is the anchor every presence check is measured from.
local EXIT   = FVector(-22750, 13300, -11030)

-- The two approach halls, ~50m out either side of the exit.
local BLUE   = FVector(-24320, 8600, -10990)
local ORANGE = FVector(-27870, 13360, -11030)


-- =======================================================================
-- THE FIGHT
-- =======================================================================

local CFG = {
    -- 80m from the exit: comfortably past both spawn marks at ~50m, inside the game's own ~150m
    -- NPC despawn radius. Re-tested before every wave - an empty radius ends the event.
    Guard = 8000,

    FirstWaveMs = 1000,    -- first wave a beat after the door opens
    WaveMs      = 12000,
    WaveMsHard  = 9000,    -- NoMercy. Read at each reschedule, so /auhard retimes a live event

    SpawnFuzz    = 250,    -- spread within a lane's mark, and the navmesh search radius
    SpawnGapMs   = 400,    -- between bodies in one wave; both lanes share the stagger
    OrderDelayMs = 1500,   -- after a wave's last spawn, let the controllers come up, then march

    -- The march order only holds while the controller still REMEMBERS the goal: at the native 9s
    -- a body that loses sight of its target drops it, its potential-target count hits 0 and the
    -- target service early-outs forever, leaving it milling mid-hall. This is the "they stop on
    -- the way" fix. [[af-npc-targeting-levers]]
    TargetMemory = 60,

    DespawnGapMs = 150,    -- staggered teardown for the dev stop; a wiped field is a dozen actors
}

-- WAVES, in beat order: t=0, 10, 20, ... Each wave is a list of { Point, Npcs }; an Npcs entry is
-- a registered variant name or a raw DT_NPCList ROW name - EVU.SpawnAt takes either, but a
-- DisplayName spawns nothing at all, silently. Hence "Pest_Electro", not "Electro Pest".
local WAVES = {
    {   -- t=0
        { Point = BLUE,   Npcs = { "Chonky Pest" } },
        { Point = ORANGE, Npcs = { "Charge Peccary", "Antegrav Pest" } },
    },
    {
        { Point = BLUE,   Npcs = { "Exorrior" } },
        { Point = ORANGE, Npcs = { "Peccary" } },
    },
    {
        { Point = BLUE,   Npcs = { "Peccary" } },
        { Point = ORANGE, Npcs = { "Antegrav Pest", "Exor Magus" } },
    },
    {
        { Point = BLUE,   Npcs = { "Hive Sow" } },
        { Point = ORANGE, Npcs = { "Armored Peccary", "Anterazor Pest" } },
    },
    {
        { Point = BLUE,   Npcs = { "Chonky Pest" } },
        { Point = ORANGE, Npcs = { "Antegrav Exor", "Pest_Electro" } },
    },
    {   -- t=50
        { Point = BLUE,   Npcs = { "Exor Repeller" } },
        { Point = ORANGE, Npcs = { "Exor Displacer" } },
    },
}


-- =======================================================================
-- RUNTIME
-- =======================================================================

-- Everything this event has fielded, for the dev stop's teardown. Nothing else reads it: loot and
-- corpses are left to the native death path, which still runs (we never strip loot, so
-- Server_TryFadeOutCorpse is reachable).
local cast = {}

-- `token` is the generation counter: every queued item carries the token it was scheduled under
-- and bails once that no longer matches, so a stop can never be undone by a beat in flight.
local run = { active = false, token = 0, wave = 0 }

-- Forward-declared: a bare `local function` below would read nil at the call sites above it.
local peTick, peSpawnWave, peGiveOrders, peStop, peCadenceMs


-- =======================================================================
-- START / STOP
-- =======================================================================

-- `why` names the trigger in the log - the story gate, or "manual" from the dev handle.
-- Returns whether the ambush is now running. The story gate spends a once-ever latch on this, so
-- a start that finds an unstreamed hall has to say so rather than quietly consuming the event.
function PE.Start(why)
    if run.active then Log("Plant Escape - already running (ignoring re-trigger)"); return true end
    if not Utils.IsAuthority() then return false end
    if not Utils.AreaLoaded(EXIT, CFG.Guard, "PLANT ESCAPE") then return false end

    run.token  = run.token + 1
    run.active = true
    run.wave   = 0
    cast = {}

    Log("Story EVENT - PLANT ESCAPE: the halls answer the door (" .. tostring(why) .. ")")

    -- Which marks the level manager admits to, once per start. A mark reading UNLOADED with a
    -- player at the exit is one to nudge, and its wave would spawn un-mutated bodies.
    if SETTINGS.DEBUG_STORY then
        for _, m in ipairs({ { "BLUE", BLUE }, { "ORANGE", ORANGE } }) do
            LogDebug(("Plant Escape - %s mark %s: sector %s"):format(
                m[1], Utils.PrintRoundedLocation(m[2]),
                Utils.IsLocationLoaded(m[2]) and "LOADED" or "UNLOADED"), true)
        end
    end

    Utils.QueueWork(function() peTick(run.token) end, CFG.FirstWaveMs)
    return true
end

-- End the event. The cast is LEFT STANDING: this fires when the players walk away, and pulling
-- bodies out of a hall they may re-enter reads worse than the fight they abandoned.
function peStop(reason)
    if not run.active then return end
    run.active = false
    run.token = run.token + 1   -- orphans every queued beat and spawn slot in one write
    Log("Story EVENT - PLANT ESCAPE over (" .. tostring(reason) .. ")")
end

-- Dev stop ("/event Plant_EscapeStop"): also clears the field, so a test can be re-run on a
-- hall that isn't already full.
function PE.Stop(reason)
    local pulled = 0
    for _, npc in ipairs(cast) do
        if Utils.IsActorValid(npc) then
            pulled = pulled + 1
            Utils.QueueWork(function()
                pcall(function() if IsValid(npc) then npc:K2_DestroyActor() end end)
            end, pulled * CFG.DespawnGapMs)
        end
    end
    cast = {}
    peStop(reason or "stopped by hand")
    if pulled > 0 then Log("Plant Escape - " .. pulled .. " pulled") end
end

function PE.Active() return run.active == true end

-- Per-world reset. A teardown wipes the WorkQueue with beats still queued, so an `active` left
-- true here would refuse to arm for the whole next world.
function PE.Reset()
    run.active = false
    run.token = run.token + 1
    run.wave = 0
    cast = {}
end


-- =======================================================================
-- THE TICKER - one beat per wave. It only schedules; the actor work happens on what it queues.
-- =======================================================================

function peTick(token)
    if not run.active or token ~= run.token or not STATE.ModEnabled then return end

    local wave = WAVES[run.wave + 1]
    if not wave then return peStop("the last wave is fielded") end

    -- Asked once per wave, before anything spawns. An empty radius means the sector is streaming
    -- out, which is the transition-crash window as well as an empty fight - so this ENDS the
    -- event rather than skipping a beat. There is no catch-up and no re-arm.
    if not Utils.IsPlayerNearby(EXIT, CFG.Guard) then
        return peStop("nobody left at the exit")
    end

    run.wave = run.wave + 1
    peSpawnWave(token, run.wave, wave)

    Utils.QueueWork(function() peTick(token) end, peCadenceMs())
end

-- NoMercy tightens the wave clock. Read at each reschedule, never cached - the flag is settled at
-- world load, but /auhard flips it live for A/B testing.
function peCadenceMs()
    return STATE.HardModeNoMercy and CFG.WaveMsHard or CFG.WaveMs
end


-- Field one wave: flatten both lanes into one ordered stagger (so the two halls trickle in
-- together rather than lane-by-lane), then march the survivors once they are all out.
function peSpawnWave(token, wi, wave)
    local flat = {}
    for _, lane in ipairs(wave) do
        for _, name in ipairs(lane.Npcs) do
            flat[#flat + 1] = { point = lane.Point, name = name }
        end
    end
    if #flat == 0 then return end

    local landed = {}
    for i, s in ipairs(flat) do
        Utils.QueueWork(function()
            if token ~= run.token or not STATE.ModEnabled then return end
            EVU.SpawnAt(s.name, s.point, {
                Fuzz = CFG.SpawnFuzz,
                callback = function(npc)
                    if Utils.IsActorInvalid(npc) then return end
                    landed[#landed + 1] = npc
                    cast[#cast + 1] = npc
                end,
            })
        end, (i - 1) * CFG.SpawnGapMs)
    end

    Utils.QueueWork(function()
        if token ~= run.token then return end
        peGiveOrders(wi, landed)
    end, (#flat - 1) * CFG.SpawnGapMs + CFG.OrderDelayMs)
end


-- A wave's marching orders. Three writes per body, each covering a different way a body stops 50m
-- short of the door:
--   * TargetMemory is what keeps the order alive at all - see CFG.TargetMemory.
--   * LocationOfInterest is the STANDING order. The BT re-arms it on every investigate reset and
--     nothing clears it on arrival, so a body that finishes or loses a fight resumes the walk by
--     itself and then loiters at the exit. No aggro push can produce that.
--   * AttackMove is the OPENING order: the bait makes them cross the hall at combat speed. Its
--     goal is captured as the order lands, so the bait parking afterwards can't disturb them -
--     but the target itself lapses, which is why the standing order underneath is not optional.
-- The standing destination is written first, so there is never a window where a body is in combat
-- with nowhere to be. NoPatrol keeps one between fights from drifting off on the idle patrol.
function peGiveOrders(wi, landed)
    local live = Utils.LivingActors(landed)
    if #live == 0 then return end

    for _, npc in ipairs(live) do
        AVU.SetTargetMemory(npc, CFG.TargetMemory)
        AVU.SetNoPatrol(npc)
        AVU.SetPointOfInterest(npc, EXIT)
    end

    -- Bait is pooled and self-managed (AVU.SpawnAggroBait); never destroy it.
    AVU.AttackMove(live, EXIT)

    LogDebug(("Plant Escape - wave %d: %d sent at the exit"):format(wi, #live), SETTINGS.DEBUG_STORY)
end


return PE
