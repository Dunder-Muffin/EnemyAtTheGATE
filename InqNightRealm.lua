-- =======================================================================
-- EVENT 11 - V_INQ NIGHT REALM  (Event_INQ_NightRealm)  [AUTHORITY] - ONE-TIME per world
--   * A Night Realm door opens in the hall and periodically spawns Shades
--   * A nearby spawner contains an Event FlameRat (immune to Npc damage)
--       > Leashed, not rooted or it doesn't rotate
--   * Shade spawns lockTarget the FlameRat once
--       > If not found, they move up the ramp
--   Gate: SM.GateINQNightRealm, latched on the first ending (NightRealmDone).
--   Dev: "/fx NIGHTREALM_DOOR" previews the door; "/event INQ_NightRealmStop" ends a test siege
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local EVU = require("ModuleStory.EventUtils")

local Log = Utils.Log
local LogDebug = Utils.LogDebug

local EV = {}


local NR_TEAR = FVector(91900, 33030, 1710) -- the Night Realm door (also the gate's anchor)
local NR_END  = FVector(98240, 33960, 2980) -- reach this and the siege is over
local NR_END_RADIUS = 1000                  -- 10m, in UE units

-- Darken the hall for the siege (AVU.SetScreenTint). OFF: the Praetorium's darkness is saved for a
-- specific set-piece, not spent on every Night Realm door. Flip to true and both halves are wired
-- (raised at the door, dropped in nrStop). The gate is on BOTH halves ON PURPOSE - an unconditional
-- ClearScreenTint in nrStop would wipe a tint some OTHER event had raised.
local NR_DARKEN = false

-- Event FlameRat and radius
local NR_LEADER = "Event FlameRat"
local NR_LEADER_RADIUS = 2000

-- How long to wait before locking target on the Event FlameRat - it needs time to change faction
local NR_AGGRO_DELAY_MS = 1500

-- The leader's post = its PlacedSpawns coord ("93440,33280,1830" + the default 90 ZLift). READ-ONLY
-- to this event: the placement spawns and owns the body, we only find and leash it. See the banner.
local NR_CINDER        = FVector(93440, 33280, 1860)

-- Try and leash actors involved
--   * SLACK stops the pulse being a jitter generator: a leader already on its post gets no order.
local NR_LEASH_MS    = 10000
local NR_LEASH_SLACK = 600     -- 6m; inside this it counts as "at its post"

-- ONE wave, as (offset from the wave's start, variant). Re-fired every NR_WAVE_MS. The stagger is
-- what makes it read as a column marching out rather than a burst.
local NR_WAVE = {
    -- { At = 0,    Variant = "Breacher Shade" },
    { At = 0, Variant = "Grunt Shade" },
    { At = 2000, Variant = "Grunt Shade" },
}
local NR_WAVE_MS = 20000
local NR_SPREAD  = 250      -- arrival scatter, each nav-projected by PortalSummon

-- The door heartbeat: refreshes the door FX until the event ends
local NR_DOOR_BEAT_MS = 6000
local NR_DOOR_LIFE_S  = 8

local NR_POLL_MS = 2000     -- the ticker: end-check + door beat + wave beat all ride this
local NR_MAX_MS  = 600000   -- hard stop (10 min) - just in case
local NR_ABANDON = 15000    -- ...same for walking away: no player within this of the door = stop.

-- Max alive shades
local NR_MAX_SHADES = 4

-- Order spawns after the event ends (cleanup crew)
local NR_CLEANUP = {
    { Loc = FVector(92150, 31950, 1750), Yaw = 90, Variant = "Sweeper" },
    { Loc = FVector(92580, 31940, 1750), Yaw = 90, Variant = "Sweeper" },
}
local NR_CLEANUP_MS = 3000   -- a beat after the door shuts, so they arrive to the aftermath

-- Forward-declared (defined below the event): a bare `local function` down there would be nil at
-- the call site - the file convention's capture trap.
local nrFindLeader, nrTick, nrSpawnWave, nrStop, nrLiveShades, nrCleanup
local nrLeashLeader, nrSendToRamp

-- Every shade this siege has put in the hall, pruned by nrLiveShades. Not a strong reference
-- problem: entries are dropped as soon as they read invalid or dead.
local nrRoster = {}

-- Shades that spawned with no Event FlameRat to charge walk up the ramp instead (NR_END). This is
-- ONE successful SetPointOfInterest write each - a standing order the BT re-arms after every fight,
-- so it's a destination, not a leash. Shades stay free to brawl on the way and still count against
-- NR_MAX_SHADES via the roster. An entry clears once its write lands; the leash beat retries the
-- rest (the controller may not be possessed yet at spawn, and a mid-fight write would be eaten).
-- Weak keys: the roster holds the wrapper while the shade lives.
local nrRampPending = setmetatable({}, { __mode = "k" })   -- shade wrapper -> true (order not landed)

-- The siege's whole runtime state. `token` is the generation counter: every queued item carries the
-- token it was scheduled under and bails if it no longer matches, so a stop or restart can never be
-- undone by an item already in flight.
local nrRun = { active = false, token = 0 }

function EV.INQNightRealm()
    if nrRun.active then Log("Night Realm - already running (ignoring re-trigger)"); return end

    nrRun.token   = nrRun.token + 1
    nrRun.active  = true
    nrRun.elapsed = 0
    nrRun.nextDoor = NR_DOOR_BEAT_MS   -- t0's door is the OPEN send below, so the beat starts later
    nrRun.nextWave = 0
    nrRun.nextLeash = NR_LEASH_MS      -- ...and the leash starts a beat in: the placement may only
                                       -- just have posted this one, mid-mutation
    nrRoster = {}                      -- last siege's dead are not this siege's headcount
    nrRampPending = setmetatable({}, { __mode = "k" })   -- ...nor its stragglers this siege's orders

    -- The leader is NOT ours to create - the PlacedSpawn owns it (see the banner). This is a LOG
    -- LINE, not a gate: the siege runs either way, and every consumer (nrSpawnWave, nrLeashLeader)
    -- re-resolves the leader on its own beat, so one that arrives late still gets picked up.
    if nrFindLeader(NR_CINDER, NR_LEADER_RADIUS) then
        LogDebug("Night Realm - " .. NR_LEADER .. " posted", SETTINGS.DEBUG_STORY)
    else
        Log("Night Realm - no " .. NR_LEADER .. " at its post; the shades will run free")
    end

    -- The open sting + the first door instance, in one send. Every later send is the SILENT entry.
    AVU.SendClientFX(NR_TEAR, "NIGHTREALM_OPEN", NR_DOOR_LIFE_S)

    -- The realm bleeds through: darken the frame while the door is open. OFF by default.
    if NR_DARKEN then AVU.SetScreenTint() end

    Log("Night Realm - the door opens in V_Inq")

    nrTick(nrRun.token)
end

-- Dev handle: stop a running siege without walking to the end trigger ("/event INQ_NightRealmStop").
function EV.INQNightRealmStop()
    nrStop("stopped by hand")
end

-- Is a siege running? Read by StoryManager's gate, which must never re-arm on top of one and starts
-- its cooldown when this goes false (NOT when the siege began).
function EV.INQNightRealmActive()
    return nrRun.active == true
end


-- =======================================================================
-- HELPERS
-- =======================================================================

-- The ticker. ONE self-rescheduling WorkQueue item drives end-check, door heartbeat
-- and wave cadence, so there is exactly one thing to stop and one place a beat can drift. It only
-- schedules - no actor work happens on this item itself.
function nrTick(token)
    if not nrRun.active or token ~= nrRun.token or not STATE.ModEnabled then return end

    -- End conditions, cheapest first. The real one is reaching the place; the other two are the
    -- net for a siege nobody is coming back to finish.
    if Utils.IsPlayerNearby(NR_END, NR_END_RADIUS) then return nrStop("players reached the far end") end
    if nrRun.elapsed >= NR_MAX_MS then return nrStop("hard time cap") end
    if not Utils.IsPlayerNearby(NR_TEAR, NR_ABANDON) then return nrStop("nobody left in the hall") end

    -- Door heartbeat. Silent entry - NIGHTREALM_OPEN's sting is a one-shot and must never repeat.
    if nrRun.elapsed >= nrRun.nextDoor then
        nrRun.nextDoor = nrRun.elapsed + NR_DOOR_BEAT_MS
        AVU.SendClientFX(NR_TEAR, "NIGHTREALM_DOOR", NR_DOOR_LIFE_S)
    end

    if nrRun.elapsed >= nrRun.nextWave then
        nrRun.nextWave = nrRun.elapsed + NR_WAVE_MS
        nrSpawnWave(token)
    end

    -- Pull the leader back to its post if it has wandered (see NR_LEASH_MS), and retry any
    -- leaderless shade whose ramp order hasn't landed yet.
    if nrRun.elapsed >= nrRun.nextLeash then
        nrRun.nextLeash = nrRun.elapsed + NR_LEASH_MS
        nrLeashLeader()
        for npc in pairs(nrRampPending) do nrSendToRamp(npc) end
    end

    nrRun.elapsed = nrRun.elapsed + NR_POLL_MS
    Utils.QueueWork(function() nrTick(token) end, NR_POLL_MS)
end


-- One wave out of the door, on its own internal stagger. The leader is each arrival's
-- aggro target AND its LifetimeOwner, re-resolved per wave rather than captured at open: the Event
-- FlameRat can die mid-siege or arrive late, and a leash bound to a corpse takes the wave with it.
function nrSpawnWave(token)
    local leader = nrFindLeader(NR_TEAR, NR_LEADER_RADIUS)
    LogDebug(string.format("Night Realm - wave out (%s)",
        leader and ("leashed to " .. NR_LEADER) or "no " .. NR_LEADER .. " - shades run free"),
        SETTINGS.DEBUG_STORY)

    for _, slot in ipairs(NR_WAVE) do
        Utils.QueueWork(function()
            if not nrRun.active or token ~= nrRun.token then return end   -- siege ended mid-wave

            -- HEADCOUNT, per SLOT not per wave: the cap is about what is alive in the hall right
            -- now, and a wave takes 5s to finish walking out.
            if nrLiveShades() >= NR_MAX_SHADES then
                LogDebug("Night Realm - at the shade cap, holding this slot", SETTINGS.DEBUG_STORY)
                return
            end

            -- Rift = false: PortalSummon's full arrival recipe (nav-project, suppress the native
            -- spawn-in, portal burst, lifetime leash) WITHOUT re-opening a doorway - the heartbeat
            -- already owns one.
            AVU.PortalSummon(NR_TEAR, { { Variant = slot.Variant, Count = 1 } }, {
                Rift     = false,
                EmergeMs = 0,
                Spread   = NR_SPREAD,
                -- Faction is UNSET on purpose: the shade defs set their own (SHADE_FACTION) in
                -- Stats, and passing one here would overwrite it after the fact.
                --
                -- LifetimeOwner ties each shade to the Event FlameRat: a script-spawned NPC belongs
                -- to no spawner group, so nothing ever unloads it ([[anteup2-neophyte-trainer]]).
                -- KNOWN GAP: no leader = no owner, and those shades persist until the level
                -- unloads. Acceptable while leaderless is the degenerate case.
                LifetimeOwner = leader,
                -- The shades step OUT of a door and should not also pop in. SkipSpawnFX (default)
                -- kills the native entrance; EmergeFX = false kills PortalSummon's own arrival
                -- burst, which was the one still firing. The shadow-meld they play on DEATH suits
                -- them anyway, so the flourish moves to the end rather than being lost.
                EmergeFX = false,
                -- Attack is deliberately UNSET - aggro is the explicit lock in OnSpawned, so the
                -- no-leader case gets NO fallback target (a fallback = the players).
                OnSpawned = function(npc)
                    nrRoster[#nrRoster + 1] = npc   -- for the headcount above

                    -- TWO loot systems, and event shades must feed NEITHER: StripLoot covers the
                    -- native death drop, SuppressScriptedLoot the variant's own (shadeDeath's
                    -- AVU.DropLoot - the Night Essence).
                    AVU.StripLoot(npc)
                    AVU.SuppressScriptedLoot(npc)

                    -- Charge the Event FlameRat. A BARE lock (no HoldMs) is deliberate: it lapses
                    -- on the shade's first completed swing, so it commits to the run down the hall
                    -- and is then free to fight whatever it reached. LockAggro re-validates both
                    -- actors after the delay, so a leader that died meanwhile is a no-op.
                    if leader then
                        AVU.LockAggro(npc, leader, { DelayMs = NR_AGGRO_DELAY_MS })
                    else
                        -- No leader to charge: up the ramp instead (see nrRampPending). First try
                        -- rides the same post-mutation delay as the lock; misses retry on the
                        -- leash beat.
                        nrRampPending[npc] = true
                        Utils.QueueWork(function()
                            if nrRun.active and token == nrRun.token then nrSendToRamp(npc) end
                        end, NR_AGGRO_DELAY_MS)
                    end
                end,
            })
        end, slot.At)
    end
end


-- The siege must never spawn its own leader (an ensure-or-spawn probe once left duplicate,
-- untracked Event FlameRats behind on re-entry). Leaderless is a supported state; an empty post
-- is a placement fix, not one made here. See AnNotes/Modules/Events.md.


-- Keep the leader in the arena - one LocationOfInterest write per pulse, and only when
-- it has actually drifted (NR_LEASH_SLACK). See the NR_LEASH_MS block for why this is an anchor and
-- not a root. Re-resolved every pulse like the wave leash: the Event FlameRat can die and be
-- replaced mid-siege, and a leash bound to a corpse is a no-op forever.
function nrLeashLeader()
    local leader = nrFindLeader(NR_CINDER, NR_LEADER_RADIUS)
    if Utils.IsActorInvalid(leader) or Utils.IsDeadSafe(leader) then return end

    local ok, at = pcall(function() return leader:K2_GetActorLocation() end)
    if not ok or not at then return end
    if Utils.WithinDistance(NR_CINDER, at, NR_LEASH_SLACK) then return end

    AVU.SetPointOfInterest(leader, NR_CINDER)
    LogDebug("Night Realm - pulling the " .. NR_LEADER .. " back to its post", SETTINGS.DEBUG_STORY)
end


-- One standing walk order up the ramp for a leaderless shade (the Purified Assault escort pattern:
-- one SUCCESSFUL write, never re-issued - POI is standing, the BT re-arms it after every fight).
-- Skipped mid-fight (never fight the combat AI for the body); cleared from nrRampPending only when
-- the write lands, so the leash beat keeps retrying the misses.
function nrSendToRamp(npc)
    if not nrRampPending[npc] then return end
    if Utils.IsActorInvalid(npc) or Utils.IsDeadSafe(npc) then nrRampPending[npc] = nil return end

    local fighting = false
    pcall(function() fighting = npc.CombatState == true end)
    if not fighting and AVU.SetPointOfInterest(npc, NR_END) then
        nrRampPending[npc] = nil
        LogDebug("Night Realm - leaderless shade sent up the ramp", SETTINGS.DEBUG_STORY)
    end
end


-- How many of our shades are still alive. Prunes the roster in place, so it never
-- grows past the number actually standing in the hall.
function nrLiveShades()
    local live = 0
    for i = #nrRoster, 1, -1 do
        local npc = nrRoster[i]
        if Utils.IsActorInvalid(npc) or Utils.IsDeadSafe(npc) then
            table.remove(nrRoster, i)
        else
            live = live + 1
        end
    end
    return live
end


-- End the siege. Bumping the token orphans every queued tick and half-spawned wave
-- slot in one write. The door is then CLOSED EXPLICITLY - a lapsed heartbeat is not a close, since
-- the last send still has most of NR_DOOR_LIFE_S to run and would otherwise hang open (or, on a
-- missed teardown, loop for the rest of the session with nothing left able to reach it).
function nrStop(reason)
    if not nrRun.active then return end
    nrRun.active = false
    nrRun.token  = nrRun.token + 1
    AVU.StopClientFX("NIGHTREALM_DOOR")
    if NR_DARKEN then AVU.ClearScreenTint() end   -- lights back up on EVERY ending, like the door shutting
    Log("Night Realm - the door closes (" .. tostring(reason) .. ")")
    nrCleanup()
end


-- The Order's mop-up detail, walking in from the back once the door is shut. Fired
-- from nrStop, so it lands on EVERY ending (far end reached, time cap, hall emptied) - the Order
-- tidies up regardless of how the players left it.
function nrCleanup()
    for _, e in ipairs(NR_CLEANUP) do
        Utils.QueueWork(function()
            -- Exact: hand-authored coords. The default SpawnAt path fuzzes the point and snaps
            -- with a +/-600 Z extent, which is how a placed body ends up on another storey.
            EVU.SpawnAt(e.Variant, e.Loc, { Exact = true, Yaw = e.Yaw })
        end, NR_CLEANUP_MS)
    end
end


-- The nearest LIVE Event FlameRat, or nil. Name-matched (the DisplayName MutateActor
-- sets) rather than by VariantTag, so it still resolves for a body whose STATS step bailed - a
-- half-mutated Event FlameRat is still what shades should charge.
function nrFindLeader(loc, radius)
    local best, bestDist
    for _, npc in ipairs(AVU.GetNearbyNpcs(loc, radius) or {}) do
        if Utils.GetActorName(npc) == NR_LEADER and not Utils.IsDeadSafe(npc) then
            local ok, at = pcall(function() return npc:K2_GetActorLocation() end)
            local d = (ok and at) and Utils.DistSq(loc, at) or math.huge
            if not bestDist or d < bestDist then best, bestDist = npc, d end
        end
    end
    return best
end


-- The anchor StoryManager's gate reads, merged into EVENTS.LOC by ModuleStory/Events
-- (the coord lives next to the event that spawns on it, so there is one copy of each).
EV.LOC = { INQNightRealm = NR_TEAR }


return EV
