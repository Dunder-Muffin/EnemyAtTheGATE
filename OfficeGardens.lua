-- =======================================================================
-- EVENT 1 - OFFICE GARDENS  (Event_Office_Gardens)  [AUTHORITY] - ONE-TIME
--   A brawl the players catch leaving Fargarden: a Charge Peccary pair and a Hospitality Bot
--   come tearing past them into an A2 mob. Three points converge at B:
--     A (OG.SPAWN_PECCARY/PECCARY2/BOT) - the chasers, RUN to B from the office exit.
--     B (OG.BRAWL_AT)                   - the brawl, mid-hall so the world's own spawners at
--                                         the far end can't drag the fight into them.
--     C (OG.SPAWN_MOB)                  - the A2 mob, WALKS to B.
--   Chasers are held on the mob with AVU.AssertLock, re-asserted every OG.HOLD_EVERY_MS - a
--   lapsed lock lets a free chaser take the nearest hostile, often a player.
--   Gate: SM.GateOfficeGardens. Decode detail: AnNotes/Modules/Events.md.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local EVU = require("ModuleStory.EventUtils")
local ENUMS = require("AnteData.Enums")

local Log = Utils.Log
local LogDebug = Utils.LogDebug

local EV = {}

-- ONE table for the whole set-piece rather than 30 file-scope locals: Lua's 200-local ceiling is
-- per FILE, and an overflow fails the WHOLE file while reporting at an unrelated line (CLAUDE.md).
local OG = {}


-- Exact marks (EVU.SpawnAt's `Exact`) - each chaser needs its own point, no fuzz to separate two
-- standing on one coord.
OG.SPAWN_PECCARY  = FVector(-12500,20270,2570)   -- A: Charge Peccary 1
OG.SPAWN_PECCARY2 = FVector(-12500,20550,2570)   -- A: Charge Peccary 2
OG.SPAWN_BOT      = FVector(-12725,20890,2590)   -- A: Bot
OG.BRAWL_AT       = FVector(-16400,19990,2570)   -- B: both sides converge here
OG.SPAWN_MOB      = FVector(-19920,20045,2570)   -- C: A2 aliens at the end of the hall
OG.GUARD_RADIUS   = 20000

-- The A2 mob (spawns at C, walks to B). Raw DT_NPCList row names, not DisplayNames - a
-- DisplayName spawns nothing.
OG.MOB = { "Pest", "Pest", "Razor Pest", "Antegrav Pest", "Antegrav Pest",
           "Pest_Carbonated", "Pest_Carbonated", "Phase Peccary", "Peccary" }

-- Clear the hall before either side arrives: two ~30m sweeps over the entrance and midpoint.
OG.CLEAR = {
    { OG.SPAWN_PECCARY, 3000 },
    { FVector(-17298, 20000, 2572), 3000 },
}

-- Readiness. Nothing spawns until every sector the set-piece touches is actually streamed in: the
-- trigger fires as the player steps out of the Fargarden portal, and a body spawned into an
-- arriving level reads IsActorValid=false, so MutateActor bails and it's left un-mutated (0.4-0.6s
-- failed testing, 1.4s was fine). Utils.IsLocationLoaded is the game's own answer for that
-- (ULevelManagerSubsystem), so ogWaitReady ASKS instead of padding a constant.
-- Don't retry inside MutateActor instead - it can't tell arriving from tearing down.
OG.SETTLE_MS       = 1500 -- floor before the first probe. Streaming is the KNOWN cause, not
                          -- a proven complete one, so this still covers the measured
                          -- margin; the probe only ever extends it.
OG.SETTLE_EVERY_MS = 250  -- re-probe this often
OG.SETTLE_MAX_MS   = 20000 -- then start anyway - a sector that never streams must not
                           -- swallow a one-time story event
-- The sectors it spawns into, labelled for the give-up log.
OG.READY_AT = { { "A", OG.SPAWN_PECCARY }, { "B", OG.BRAWL_AT }, { "C", OG.SPAWN_MOB } }

-- Beats (ms), all measured from the START below, not the trigger.
OG.MOB_MS        = 500    -- mob is 70m off, spawns after the chasers so they claim the
                          -- earlier NpcSpawner slots
OG.MOB_STAGGER   = 150
OG.PECCARY_MS    = 0      -- peccaries in at once (hall clear above is synchronous)
OG.BOT_MS        = 500    -- bot a beat behind, already chasing
OG.GO_MS         = 1000   -- whole cast released together - a floor, ogHoldCast still waits
                          -- for the last chaser to land
OG.HOLD_EVERY_MS = 500    -- re-assert every lock this often - must beat the game's 1s
                          -- re-target service or a player steals a chaser in the gap
OG.ARM_WAIT_MS   = 15000  -- how long to wait for the full cast before starting without a
                          -- missing chaser (sized for a starved WorkQueue)

-- Target choice. Every chaser is LOCKED onto a mob member (AVU.AssertLock) from the moment it has
-- one - never pushed at a bare location. The lock is what skips the aggro animation, what stops a
-- player being taken mid-run, and what stops combat being re-entered over and over.
OG.PECCARY_LOCK  = 5000   -- how long a peccary keeps its lock. After this it fights on its own
                          -- judgement - by then it is in the mob and the nearest hostile is a
                          -- pest, not a player. nil (the bot) = locked for as long as it chases
OG.PECCARY_DROP  = 12000  -- peccary reverts to its own faction this far into the fight,
                          -- before it turns on too many allies
OG.HOLD_MAX_MS   = 90000  -- safety cap for a chaser with no dropAt (the bot); only matters
                          -- if it can never reach its target
OG.HANDOFF_MS    = 6000   -- a dropped peccary is handed to the bot for this long, so a laggy
                          -- or player-chased peccary doesn't pick the player instead

OG.CHASER_SPEED   = 1000
OG.BOT_SPEED_FOR  = 12000 -- the bot keeps OG.CHASER_SPEED this long into the chase, then its
                          -- own row speed
OG.CHASER_STAGGER = 250

-- The one team every chaser runs under - must differ from the A2 mob's faction (else the lock is
-- refused) and be the same across chasers (else they turn on each other). Also hostile to
-- players, which the lock suppresses.
OG.CHASER_FACTION = ENUMS.Faction.Gatekeepers

OG.BOT_NAME = "Event Hospitality Bot"   -- hand-off target, matched against OG.CHASERS.name

-- loc/inMs: exact mark and spawn beat (inMs from event start).
-- Flip: hand it OG.CHASER_FACTION (bot is on Gatekeepers already).
-- NoFX: suppress the spawn-in burst - peccaries arrive already running.
-- dropAt: ms after ENGAGING to drop out (nil = hold until the mob is dead).
-- LockFor: ms after ENGAGING to stop re-asserting the lock (nil = for as long as it chases).
-- HandOff: send a dropped chaser at the bot.
-- speedFor: sprint this far into the chase, then back to its row speed.
OG.CHASERS = {
    { name = "Charge Peccary", loc = OG.SPAWN_PECCARY,  inMs = OG.PECCARY_MS, NoFX = true,
      Flip = true, dropAt = OG.PECCARY_DROP, LockFor = OG.PECCARY_LOCK, HandOff = true },
    { name = "Charge Peccary", loc = OG.SPAWN_PECCARY2, inMs = OG.PECCARY_MS, NoFX = true,
      Flip = true, dropAt = OG.PECCARY_DROP, LockFor = OG.PECCARY_LOCK, HandOff = true },
    { name = OG.BOT_NAME,      loc = OG.SPAWN_BOT,      inMs = OG.BOT_MS,
      speedFor = OG.BOT_SPEED_FOR },
}

local ogWaitReady, ogRunCast, ogHoldCast, ogHoldOne, ogArmChaser, ogReleaseChaser, ogPickTarget,
      ogFindBot, ogRestoreSpeed, ogPassThroughPlayers

function EV.OfficeGardens()
    if not Utils.IsAuthority() then return end
    if not Utils.AreaLoaded(OG.BRAWL_AT, OG.GUARD_RADIUS, "OFFICE GARDENS") then return end
    Log("Story EVENT - OFFICE GARDENS")

    -- Wait for the sectors before anything spawns, hall clear included. cast.t0 starts in
    -- ogRunCast, not here, so the chase budgets measure the chase and never the wait.
    local t0 = Utils.NowMs()
    Utils.QueueWork(function() ogWaitReady(t0) end, OG.SETTLE_MS)
end


-- Hold the whole set-piece until every sector it spawns into is streamed in. `sinceMs` is
-- real ms at the TRIGGER, so the give-up covers the floor too.
function ogWaitReady(sinceMs)
    local waited, missing = Utils.NowMs() - sinceMs, {}
    for _, z in ipairs(OG.READY_AT) do
        if not Utils.IsLocationLoaded(z[2]) then missing[#missing + 1] = z[1] end
    end

    if #missing == 0 then
        LogDebug("OFFICE GARDENS - sectors ready after " .. math.floor(waited) .. "ms",
            SETTINGS.DEBUG_STORY)
    elseif waited < OG.SETTLE_MAX_MS then
        Utils.QueueWork(function() ogWaitReady(sinceMs) end, OG.SETTLE_EVERY_MS)
        return
    else
        -- Start anyway rather than lose a one-time event. Bodies in the named sectors may spawn
        -- un-mutated; if this line ever shows up, that's the cause.
        Log("Story EVENT - OFFICE GARDENS starting with sector(s) "
            .. table.concat(missing, "/") .. " still unstreamed")
    end

    ogRunCast()
end


-- Split from EV.OfficeGardens so the settle above is a plain QueueWork, not a nested closure.
function ogRunCast()
    -- Keyed by OG.CHASERS index, never by name - two entries can be the same NPC (two peccaries)
    -- and a shared name key would let the second spawn overwrite the first's tracking.
    --   target[i]/speed[i] = its committed mob member / its own speed, captured before sprinting.
    --   done[i]            = released or died; the hold chain ends when every index is done.
    --   t0                 = real ms at the settle; OG.ARM_WAIT_MS measures off it.
    --   engagedAt[i]       = real ms it first got a target; dropAt and LockFor measure off this.
    local cast = { mob = {}, chasers = {}, orig = {}, armed = {}, target = {}, speed = {},
                   done = {}, engagedAt = {}, t0 = Utils.NowMs() }

    for _, c in ipairs(OG.CLEAR) do
        AVU.DestroyNpcsInRadius(c[1], c[2], "OfficeGardens")
    end

    -- 1) The A2 mob walks in from C. SetPointOfInterest is the native standing-destination
    -- channel: one write, the BT re-arms it on every investigate reset, real perception overrides
    -- it when the chasers arrive.
    for i, name in ipairs(OG.MOB) do
        Utils.QueueWork(function()
            EVU.SpawnAt(name, OG.SPAWN_MOB, {
                Yaw = 180,
                callback = function(n)
                    cast.mob[#cast.mob + 1] = n
                    AVU.SetPointOfInterest(n, OG.BRAWL_AT)
                end,
            })
        end, OG.MOB_MS + (i - 1) * OG.MOB_STAGGER)
    end

    -- 2) The chasers enter, each on its own exact coord
    for i, c in ipairs(OG.CHASERS) do
        Utils.QueueWork(function()
            EVU.SpawnAt(c.name, c.loc, {
                Yaw = 180, Exact = true, SkipSpawnFX = c.NoFX,
                callback = function(n) cast.chasers[i] = n end,
            })
        end, c.inMs + (i - 1) * OG.CHASER_STAGGER)
    end

    -- 3) Held on the mob until their beat ends - ogHoldCast re-locks on a cadence and releases
    -- each as its time runs out, no separate revert pass.
    -- ONE hold item drives the whole cast, never one chain per chaser: sibling QueueWork chains
    -- queued together don't stay in step (drain is newest-first), so the last-queued one starves
    -- the rest. See AnNotes/Modules/Events.md.
    Utils.QueueWork(function() ogHoldCast(cast) end, OG.GO_MS)
end


-- =======================================================================
-- HELPERS
-- =======================================================================

-- One hold pass over the whole cast, re-locking every OG.HOLD_EVERY_MS, until each
-- chaser's dropAt (the peccaries) or the mob is dead (the bot; OG.HOLD_MAX_MS is only a backstop).
-- Self-rescheduling, one item for all three - never one per chaser. See AnNotes/Modules/Events.md for why.
-- Re-asserts rather than firing once: a lock lapses on the chaser's first completed swing, and a
-- free chaser takes the nearest hostile by pure distance - early in the run, that's a player.
function ogHoldCast(cast)
    -- Nobody moves until the whole cast is standing. The set-piece is three bodies tearing down the
    -- hall together. Arming one while the others are still queued sends it 70m ahead alone, leaving
    -- the unarmed ones loose next to the players on their own faction. OG.ARM_WAIT_MS is the
    -- give-up: a chaser whose spawn never lands must not hold the event hostage.
    if not cast.started then
        local waitedMs = Utils.NowMs() - cast.t0
        local ready = 0
        for i = 1, #OG.CHASERS do
            if Utils.IsActorValid(cast.chasers[i]) then ready = ready + 1 end
        end
        if ready < #OG.CHASERS and waitedMs < OG.ARM_WAIT_MS then
            Utils.QueueWork(function() ogHoldCast(cast) end, OG.HOLD_EVERY_MS)
            return
        end
        cast.started = true
        cast.tGo = Utils.NowMs()
        LogDebug("OFFICE GARDENS - chase starts with " .. ready .. "/" .. #OG.CHASERS
            .. " chaser(s) after " .. math.floor(waitedMs) .. "ms", SETTINGS.DEBUG_STORY)
    end

    -- Every chaser budget runs from the chase start, not the event start. The wait above can be
    -- longer than a peccary's whole dropAt on a starved queue, and an event-start anchor would then
    -- release it on its first pass - a chaser that never chases.
    local elapsedMs = Utils.NowMs() - cast.tGo

    -- One roster read per pass, shared by every chaser. Dead bodies drop out here, not just invalid
    -- ones: a corpse is not a lock target (AssertLock refuses one) and "the mob is wiped" should
    -- mean dead, not despawned.
    local living = {}
    for _, m in ipairs(cast.mob) do
        if Utils.IsActorValid(m) and not Utils.IsDeadSafe(m) then living[#living + 1] = m end
    end

    local pending = false
    for i, c in ipairs(OG.CHASERS) do
        if not cast.done[i] then
            ogHoldOne(cast, i, c, elapsedMs, living)
            if not cast.done[i] then pending = true end
        end
    end

    if pending then Utils.QueueWork(function() ogHoldCast(cast) end, OG.HOLD_EVERY_MS) end
end


-- One chaser's slice of a hold pass. `elapsedMs` is real ms since the chase started.
-- Sets cast.done[i] once this chaser needs no further passes (released, or dead).
function ogHoldOne(cast, i, c, elapsedMs, living)
    local npc = cast.chasers[i]

    -- The sprint is time-boxed independently of the chase: the bot stays in the fight but stops
    -- being a sprinting one. (ogReleaseChaser also restores, so a chaser with no speedFor - the
    -- peccaries - gets its speed back when it drops out instead.)
    if c.speedFor and elapsedMs >= c.speedFor then ogRestoreSpeed(cast, i) end

    -- Its own drop time, measured from ENGAGEMENT - a chaser still running at its victim has not
    -- started mauling anything yet, so its clock has not started either. No dropAt = in until the
    -- mob is dead. OG.HOLD_MAX_MS backstops both, including one that never reaches the fight.
    local fightMs = c.dropAt and cast.engagedAt[i] and (Utils.NowMs() - cast.engagedAt[i])
    if (fightMs and fightMs >= c.dropAt) or elapsedMs >= OG.HOLD_MAX_MS then
        LogDebug("OFFICE GARDENS - chaser " .. i .. " dropping out of the chase", SETTINGS.DEBUG_STORY)
        cast.done[i] = true
        ogReleaseChaser(cast, i)
        return
    end

    if Utils.IsActorValid(npc) and not Utils.IsDeadSafe(npc) then
        if not cast.armed[i] then ogArmChaser(cast, i, npc) end

        -- Every pest we spawned is dead: the brawl is over, so there is nothing left to hold this
        -- chaser on. Release it and let it behave like any other NPC.
        -- (#cast.mob == 0 = the mob's spawn callbacks haven't landed yet; just wait.)
        if #living == 0 and #cast.mob > 0 then
            LogDebug("OFFICE GARDENS - A2 mob wiped; releasing chaser " .. i, SETTINGS.DEBUG_STORY)
            cast.done[i] = true
            ogReleaseChaser(cast, i)
            return
        end

        -- Keep the committed victim; only re-pick once it's dead. Re-picking every pass would
        -- thrash (the candidate list compacts as the mob dies, so a positional pick slides onto a
        -- different actor each time) and would converge the whole cast on one victim.
        local target = cast.target[i]
        if Utils.IsActorInvalid(target) or Utils.IsDeadSafe(target) then
            target = ogPickTarget(cast, i, living)
            cast.target[i] = target
        end

        if target then
            cast.engagedAt[i] = cast.engagedAt[i] or Utils.NowMs()   -- starts dropAt/LockFor
            -- LockFor lapses and we simply stop re-asserting: it keeps its faction and stays in
            -- the fight, just on its own judgement. The lock is a launcher, not a leash.
            if not (c.LockFor and Utils.NowMs() - cast.engagedAt[i] >= c.LockFor) then
                AVU.AssertLock(npc, target)
            end
        end   -- (no target = the mob's spawn callbacks haven't landed yet; just wait)

    elseif cast.armed[i] then
        cast.done[i] = true   -- it was here and is gone now: it died. Nothing to hold or release.
    end                       -- (not armed = its spawn callback never landed; keep polling to dropAt)
end


-- Pick chaser i a victim, preferring one no other chaser has committed to so the cast
-- spreads across the mob. Otherwise they dog-pile the first pest, kill it together, and all come
-- free on the same tick - i.e. all turn on the players at once (see ogHoldOne). Doubles up only
-- when there are more chasers left than pests. nil = the mob hasn't spawned yet, so just wait.
function ogPickTarget(cast, i, living)
    if #living == 0 then return nil end

    -- NEAREST TO B FIRST. The mob walks C -> B, so its front-runners are both the closest to B and
    -- the closest to the chasers coming from A: aiming at those makes the two sides meet near B
    -- instead of the chasers diving down the hall to whoever is still back at C.
    local order = {}
    for _, m in ipairs(living) do
        local d = math.huge
        local ok, loc = pcall(function() return m:K2_GetActorLocation() end)
        if ok and loc then d = Utils.DistSq(loc, OG.BRAWL_AT) end
        order[#order + 1] = { npc = m, d = d }
    end
    table.sort(order, function(a, b) return a.d < b.d end)

    -- Key by GetFullName, not the wrapper: UE4SS hands out a different wrapper for one UObject on
    -- each call, so comparing wrappers is unreliable (see CLAUDE.md).
    local taken = {}
    for j, t in pairs(cast.target) do
        if j ~= i and Utils.IsActorValid(t) then
            pcall(function() taken[t:GetFullName()] = true end)
        end
    end

    for _, e in ipairs(order) do
        local name
        pcall(function() name = e.npc:GetFullName() end)
        if not (name and taken[name]) then return e.npc end
    end
    return order[1].npc
end


-- One-time setup for a chaser, the first tick it exists - team, speed, and no charging.
function ogArmChaser(cast, i, npc)
    local c = OG.CHASERS[i]
    cast.armed[i] = true

    -- Let it run THROUGH the players instead of into them. The hall is narrow, and a chaser whose
    -- capsule sweeps into a player capsule wedges on it - with three of them that is a roadblock,
    -- and it fights the whole point of the beat, which is that they tear straight PAST the players.
    -- Lives on MoveIgnoreActors (AddUnique), so nothing else can clear it; ogReleaseChaser puts it
    -- back, because a released chaser may well end up fighting them.
    ogPassThroughPlayers(npc, true)

    -- Delete the aggro/startle reaction. It is NOT cosmetic: BTT_SetCombatState delays by the
    -- montage's own play length while LockedInPlaceMontage parks the BT, so every combat entry is a
    -- ~1s "stand still" window - and a chaser that re-enters combat replays it, which reads as a
    -- body stuck twitching in the hall. One write, native fallback path, nothing to re-assert.
    AVU.SkipAggroAnim(npc)

    -- Capture the REAL faction so ogReleaseChaser can hand it back (false = unreadable, so skip it).
    if c.Flip then
        local orig
        pcall(function() orig = npc.Faction end)
        cast.orig[i] = orig or false
        AVU.SetFaction(npc, OG.CHASER_FACTION)
    end

    -- Pin ability slot 1 off for 10 min: the chaser must run at the mob, not lunge at it. Slot 1 is
    -- the charge/stampede on the Charge Peccary (ABILITY MAP in AnteNPCs/Peccary.lua) and empty on
    -- the Hospitality Bot (Robot_Security), so it's a harmless no-op there.
    pcall(function() npc:SetAbilityOnCooldown(1, true, 600) end)

    -- The chase sprint. Capture the row's OWN speeds first so ogRestoreSpeed can put them back, and
    -- guard the read: a 0/nil read later "restored" would leave the NPC unable to move at all (the
    -- CLAUDE.md guarded-read rule).
    local npcData = npc.NPCData
    if IsValid(npcData) then
        local walk, sprint
        pcall(function()
            walk   = npcData[ENUMS.NpcData.WalkSpeed]
            sprint = npcData[ENUMS.NpcData.SprintSpeed]
        end)
        if walk and walk > 0 and sprint and sprint > 0 then
            cast.speed[i] = { walk = walk, sprint = sprint }
        end

        -- TagSpeed: these fields carry the VariantTag in their fraction, so a raw integer write
        -- un-tags the chaser for the whole chase (clients stop mirroring its visuals mid-event).
        -- The restore above is safe already - it puts back what we read, fraction included.
        local chase = AVU.TagSpeed(npc, OG.CHASER_SPEED)
        npcData[ENUMS.NpcData.WalkSpeed]   = chase
        npcData[ENUMS.NpcData.SprintSpeed] = chase
    end

    LogDebug("OFFICE GARDENS - chaser " .. i .. " (" .. c.name .. ") armed", SETTINGS.DEBUG_STORY)
end


-- Put a chaser back on its row's own speed. Idempotent (latched), and a no-op if we never
-- got a clean read of the originals - better a permanently fast bot than an immobile one.
function ogRestoreSpeed(cast, i)
    local sp = cast.speed[i]
    if not sp then return end
    cast.speed[i] = nil            -- latch: only restore once

    local npc = cast.chasers[i]
    if Utils.IsActorInvalid(npc) then return end

    pcall(function()
        local npcData = npc.NPCData
        if IsNotValid(npcData) then return end
        npcData[ENUMS.NpcData.WalkSpeed]   = sp.walk
        npcData[ENUMS.NpcData.SprintSpeed] = sp.sprint
    end)
    LogDebug("OFFICE GARDENS - chaser " .. i .. " back to its row speed", SETTINGS.DEBUG_STORY)
end


-- Make a chaser's capsule ignore (or stop ignoring) every player while it moves.
function ogPassThroughPlayers(npc, on)
    if Utils.IsActorInvalid(npc) then return end
    pcall(function()
        local cap = npc.CapsuleComponent
        if IsNotValid(cap) then return end
        for _, p in ipairs(Utils.LivePlayers()) do
            cap:IgnoreActorWhenMoving(p, on == true)
        end
    end)
end


-- This chaser is done chasing. Drop the lock and give a flipped one its real faction back
-- (so it stops grinding its own kind). Then hand it off (c.HandOff): a bare unlock sends it at
-- whatever is nearest, usually the bot by now, but a lagged peccary could otherwise take a player
-- instead - the hand-off makes that certain rather than incidental, until it lapses (OG.HANDOFF_MS).
function ogReleaseChaser(cast, i)
    local c   = OG.CHASERS[i]
    local npc = cast.chasers[i]
    if Utils.IsActorInvalid(npc) then return end

    ogRestoreSpeed(cast, i)   -- no-op if speedFor already did it (it latches)
    ogPassThroughPlayers(npc, false)   -- it collides with players again from here
    AVU.UnlockAggro(npc)
    local orig = cast.orig[i]
    if orig then AVU.SetFaction(npc, orig) end   -- FIRST: the hand-off below needs it hostile to the bot

    if c.HandOff then
        local bot = ogFindBot(cast)
        if bot then
            AVU.LockAggro(npc, bot, { HoldMs = OG.HANDOFF_MS })
            LogDebug("OFFICE GARDENS - chaser " .. i .. " handed off to the bot", SETTINGS.DEBUG_STORY)
        else
            LogDebug("OFFICE GARDENS - chaser " .. i .. " dropped out; no bot left to hand it to",
                SETTINGS.DEBUG_STORY)
        end
    end

    LogDebug("OFFICE GARDENS - chaser " .. i .. " released", SETTINGS.DEBUG_STORY)
end


-- The living Hospitality Bot in the cast, or nil (it can die in the brawl). Matched on the
-- OG.CHASERS name, so the hand-off doesn't hardcode a cast index.
function ogFindBot(cast)
    for j, c in ipairs(OG.CHASERS) do
        if c.name == OG.BOT_NAME then
            local bot = cast.chasers[j]
            if Utils.IsActorValid(bot) and not Utils.IsDeadSafe(bot) then return bot end
        end
    end
    return nil
end


return EV
