-- =======================================================================
-- EVENT 8 - REACTORS CLOUD TAKEOVER  (Event_ReactorsCloud_GKTakeover)  [AUTHORITY] - ONE-TIME
--   An Order platoon musters behind the players as they power up Cloud Reactor. ONE rift tears
--   open further back - the Gatekeepers' - and a Jotun Steed rolls out; the Order throws itself
--   at it. Only the Gatekeepers rift in; the Order is already down here.
--   Every spawn rechecks player proximity first: spawning into a streaming-out sector is the
--   transition-crash window (the LAB BREACH guard).
--   Gate: SM.GateReactorsCloud.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local EVU = require("ModuleStory.EventUtils")

local Log = Utils.Log
local LogDebug = Utils.LogDebug

local EV = {}


-- The approach the players walk in on: the area guard, and the anchor the story gate reads.
local RC_ANCHOR       = FVector(7610, 9800, -17370)

-- Order/GK spawn points.
local RC_ORDER_SP     = FVector(7050, 10480, -17480)
local RC_ORDER_SP2    = FVector(7850, 9210, -17480)
local RC_GK_SP        = FVector(7600, 9870, -17480)

local RC_PORTAL_YAW   = -50    -- rift door facing the players
local RC_YAW_FUZZ     = 20     -- +/- make each NPC's facing a range (a parade rank reads as scenery)
local RC_GUARD_RADIUS = 10000  -- ~100m: a player must be this close for the area to count as loaded

-- FORMATION (rcFormationSlot). Ranks, not a random cloud: a deterministic per-index slot is the only
-- thing that GUARANTEES two NPCs never land on the same navmesh point.
local RC_RANK_WIDTH   = 4      -- NPCs per rank
local RC_RANK_SPACING = 200    -- side-to-side gap within a rank
local RC_RANK_DEPTH   = 200    -- gap between ranks
local RC_GK_SPACING   = 200    -- the raid's own slot gap
local RC_SLOT_JITTER  = 70     -- +/- wobble within a slot, so a rank doesn't read as a parade ground.
                               -- MUST stay well under half the spacing or it undoes the separation.
local RC_Z_EXTENT     = 150    -- how far a slot looks up/down for its floor. DELIBERATELY under a
                               -- storey: better to spawn at the authored Z and drop than to land a
                               -- floor away (see EVU.SpawnAt's Exact / Utils.ProjectToNav).

-- The Order platoon, minus the Captain (he gets his own fixed post). Mixed variant/base row.
local RC_ORDER = {
    "Grunt_Guard", "Grunt_Guard", "Grunt_Guard", "Velites Guard"
}
local RC_CAPTAIN = "Grunt_Captain"

-- GKs
local RC_RAID = { "Jotun Steed" }
-- local RC_LAST = "Abjurer Mage"

-- Beats (ms)
local RC_ORDER_MS        = 1000   -- the platoon musters (no rift - the ONE portal is the GK's)
local RC_ORDER_STAGGER   = 400
local RC_PORTAL_MS       = 3000   -- THE portal: the GK rift tears open behind them
local RC_PORTAL_OPEN_MS  = 4000
local RC_RAID_MS         = 5000   -- the Jotun rolls out
local RC_RAID_STAGGER    = 250
local RC_ENGAGE_MS       = 6000   -- and the Order turns on it
-- local RC_LAST_MS         = 7000
-- local RC_LAST_ENGAGE_MS  = 8000
local RC_REINFORCE_MS    = 8000  -- extra Order, into the meat grinder
local RC_REINFORCE_GAP   = 2000
local RC_REINFORCE       = { "Grunt_Guard", "Suppressor Grunt", "Grunt_Captain" }

-- Holding the Order on the Jotun (see rcHoldOrder). The cadence must beat the game's 1s re-target
-- service, and the lock must be RE-ASSERTED because it lapses on each NPC's first completed shot
-- (AVU.LockAggro). The cap is a backstop for a Jotun nothing can reach.
local RC_HOLD_EVERY_MS = 500
local RC_HOLD_MAX_MS   = 180000

-- Every NPC in this set-piece remembers its enemy for this long (native default: 9s). This is the
-- fix for the two sides falling out of combat: at 9s the controller drops a target it can't see,
-- deletes it from perception, and the re-targeting service stops (PotentialCombatTargetCount hits
-- 0). A pair that drifts 15-20m apart mid-retreat could never re-engage without a player walking
-- between them. A minute outlives any retreat. See AVU.SetTargetMemory.
local RC_TARGET_MEMORY  = 60

local rcSpawnWave, rcEngage, rcHoldOrder, rcYawToward, rcFormationSlot   -- below

function EV.ReactorsCloudTakeover()
    if not Utils.IsAuthority() then return end
    if not Utils.AreaLoaded(RC_ANCHOR, RC_GUARD_RADIUS, "REACTORS CLOUD TAKEOVER") then return end
    Log("Story EVENT - REACTORS CLOUD TAKEOVER")

    local cast = { order = {}, raid = {} }

    -- Each side faces the other. Derived, not hand-tuned, so moving a muster point can't leave a
    -- squad staring at a wall.
    local orderYaw = rcYawToward(RC_ORDER_SP, RC_GK_SP)
    local gkYaw    = rcYawToward(RC_GK_SP, RC_ORDER_SP)

    -- t+1: the platoon musters in the hall, in ranks. No rift for them (see the banner).
    rcSpawnWave(RC_ORDER, RC_ORDER_SP, orderYaw, RC_ORDER_MS, RC_ORDER_STAGGER,
        { Into = cast.order })

    -- ...and the officer who was already down here, at his post, forward of them.
    rcSpawnWave({ RC_CAPTAIN }, RC_ORDER_SP2, rcYawToward(RC_ORDER_SP2, RC_GK_SP), RC_ORDER_MS, 0,
        { Into = cast.order })

    -- t+3: THE portal. The Gatekeeper doorway tears open further back and hangs there.
    Utils.QueueWork(function()
        AVU.PortalDrop(RC_GK_SP, { Yaw = RC_PORTAL_YAW, OpenMs = RC_PORTAL_OPEN_MS })
    end, RC_PORTAL_MS)

    -- t+5: the Jotun rolls out of it - slot 1 of the raid's formation, with the wide GK spacing.
    rcSpawnWave(RC_RAID, RC_GK_SP, gkYaw, RC_RAID_MS, RC_RAID_STAGGER,
        { Into = cast.raid, SkipFX = true, Spacing = RC_GK_SPACING,
          OnSpawned = function(npc) cast.jotun = npc end })

    -- t+6: the whole Order turns on it, and KEEPS turning on it for as long as it lives. This hold
    -- IS the set-piece (see the banner): without it they shoot the players instead.
    Utils.QueueWork(function() rcHoldOrder(cast) end, RC_ENGAGE_MS)

    -- ...while the raid is thrown at the Order, so both sides are committed to each other.
    Utils.QueueWork(function() rcEngage(cast, cast.raid) end, RC_ENGAGE_MS)

    -- -- t+7: the Mage follows it through - reinforcement suppressed (see the header) - and goes in a beat
    -- -- later (a just-spawned NPC's controller won't take an aggro order yet). SlotFrom continues the
    -- -- raid's formation past the Jotun, so it can't be spawned INTO the Jotun standing in the doorway.
    -- rcSpawnWave({ RC_LAST }, RC_GK_SP, gkYaw, RC_LAST_MS, 0,
    --     { Into = cast.raid, SkipFX = true, Variant = { NoSummon = true },
    --       Spacing = RC_GK_SPACING, SlotFrom = #RC_RAID,
    --       OnSpawned = function(npc) cast.last = npc end })
    -- Utils.QueueWork(function() rcEngage(cast, { cast.last }) end, RC_LAST_ENGAGE_MS)

    -- t+10..16: Order reinforcements from the same muster point. SlotFrom puts them in the ranks
    -- BEHIND the platoon, which is likely still standing there. rcHoldOrder re-reads cast.order
    -- each pass, so they join the assault automatically.
    rcSpawnWave(RC_REINFORCE, RC_ORDER_SP, orderYaw, RC_REINFORCE_MS, RC_REINFORCE_GAP,
        { Into = cast.order, SlotFrom = #RC_ORDER })
end


-- =======================================================================
-- HELPERS
-- =======================================================================

-- Spawn a list at `loc`, facing `yaw`, on a stagger starting at baseMs. Each NPC gets its
-- OWN formation slot (rcFormationSlot) - they never share a point. Re-checks player proximity per
-- slot: the wave runs ~16s, the entry AreaLoaded only guarded the start, and spawning into a
-- streaming-out sector is the transition-crash window. A dropped slot leaves the wave partial
-- (as in the Lab breach) - no catch-up.
-- opts: Into (collect bodies into this list), SkipFX (no entrance montage), OnSpawned(npc),
--       Spacing (slot gap; default RC_RANK_SPACING), SlotFrom (start numbering here, so a later
--       wave at the same muster point falls in BEHIND an earlier one instead of on top of it),
--       Variant (per-spawn opts for the variant's Stats - EVU.SpawnOne; the Abjurer's NoSummon).
function rcSpawnWave(names, loc, yaw, baseMs, staggerMs, opts)
    opts = opts or {}
    local slotFrom = opts.SlotFrom or 0

    for i, name in ipairs(names) do
        -- Resolved HERE, not in the closure: the slot is a pure function of the index either way,
        -- but computing it up front makes it obvious two slots can never collide.
        local spot = rcFormationSlot(loc, yaw, slotFrom + i, opts.Spacing)

        Utils.QueueWork(function()
            if not Utils.IsPlayerNearby(RC_ANCHOR, RC_GUARD_RADIUS) then
                LogDebug("REACTORS CLOUD - spawn slot skipped (area no longer loaded)", SETTINGS.DEBUG_STORY)
                return
            end
            -- Exact: the slot IS the answer. Without it EVU.SpawnAt hands the point to
            -- Utils.GetSpawnPoint, which snaps +/-600 in Z (another storey) then picks a random
            -- reachable point anyway - throwing away both the formation AND the floor.
            EVU.SpawnAt(name, spot, {
                Exact = true, ZExtent = RC_Z_EXTENT, Yaw = yaw, FuzzYaw = RC_YAW_FUZZ,
                SkipSpawnFX = opts.SkipFX, Variant = opts.Variant,
                callback = function(npc)
                    -- Both sides get the long memory: either one losing sight of the other is what
                    -- ends the fight (see RC_TARGET_MEMORY).
                    AVU.SetTargetMemory(npc, RC_TARGET_MEMORY)
                    if opts.Into then opts.Into[#opts.Into + 1] = npc end
                    if opts.OnSpawned then opts.OnSpawned(npc) end
                end,
            })
        end, baseMs + (i - 1) * staggerMs)
    end
end


-- Yaw (degrees) from `from` toward `to` - the flat facing, ignoring height.
function rcYawToward(from, to)
    return math.deg(math.atan((to.Y or 0) - (from.Y or 0), (to.X or 0) - (from.X or 0)))
end


-- Slot `n` (1-based) of a formation centred on `loc` and facing `yaw` - ranks of
-- RC_RANK_WIDTH, laid out sideways first then BACKWARDS away from the facing, so rank 1 is the
-- front line and later arrivals fall in behind it.
--   * A random cloud around one point does NOT reliably separate bodies: two rolls can land a few
--     cm apart and the navmesh projection can snap them to the SAME point. Spawn collision handling
--     is "adjust position, always spawn", so the loser gets shoved somewhere unhelpful - and a body
--     as big as the Jotun can end up with nowhere to go. A deterministic slot per index is the only
--     thing that guarantees clearance.
--   * UE convention for a yaw of t: forward = (cos t, sin t), right = (-sin t, cos t).
function rcFormationSlot(loc, yaw, n, spacing)
    spacing = spacing or RC_RANK_SPACING

    local col = (n - 1) % RC_RANK_WIDTH
    local row = math.floor((n - 1) / RC_RANK_WIDTH)

    local side = (col - (RC_RANK_WIDTH - 1) / 2) * spacing   -- centre the rank on loc
    local back = row * RC_RANK_DEPTH

    local t = math.rad(yaw or 0)
    local fx, fy = math.cos(t), math.sin(t)
    local rx, ry = -fy, fx

    -- Wobble within the slot, so a squad doesn't stand in a perfect grid. Bounded well under half
    -- the spacing, so it can never close the gap the slot exists to guarantee.
    local jx = math.random(-RC_SLOT_JITTER, RC_SLOT_JITTER)
    local jy = math.random(-RC_SLOT_JITTER, RC_SLOT_JITTER)

    return FVector(loc.X + rx * side - fx * back + jx,
                   loc.Y + ry * side - fy * back + jy,
                   loc.Z)
end


-- Hold the whole Order on the Jotun Steed, re-locking every RC_HOLD_EVERY_MS for as long
-- as it lives (self-rescheduling - exactly one runs for the set-piece). Load-bearing, not garnish:
-- an unlocked NPC takes the nearest hostile by pure distance, and the Order musters close enough
-- that any drifter turns on a player. It must re-lock, not fire once, since a lock lapses on each
-- NPC's first completed shot. It re-reads cast.order each pass to pick up late reinforcements.
function rcHoldOrder(cast)
    -- REAL ms, not a count of passes: the cadence is a QueueWork delay and the drain is
    -- newest-first at 2 items/tick, so under load a "500ms" pass takes seconds and this cap means
    -- whatever the queue felt like (Office Gardens' 90s ran 467s that way).
    cast.t0 = cast.t0 or Utils.NowMs()
    if Utils.NowMs() - cast.t0 >= RC_HOLD_MAX_MS then
        Log("REACTORS CLOUD - Order hold hit its cap; releasing")
        return
    end

    local jotun = cast.jotun
    if Utils.IsActorValid(jotun) and not Utils.IsDeadSafe(jotun) then
        cast.jotunSeen = true   -- it exists; from here, "gone" means DEAD

        local order = Utils.LivingActors(cast.order)
        for _, npc in ipairs(order) do
            AVU.AssertLock(npc, jotun)
        end

    elseif cast.jotunSeen then
        -- It was here and is gone: dead. The war is decided and the Order is free.
        LogDebug("REACTORS CLOUD - the Jotun is down; the Order is free", SETTINGS.DEBUG_STORY)
        return
    end
    -- (never seen = its spawn callback hasn't landed yet; the spawn is async and this hold starts a
    -- beat later, so keep ticking rather than conclude it died. Bailing here would leave the Order
    -- permanently unlocked, i.e. shooting the players - the exact failure this hold prevents.)

    Utils.QueueWork(function() rcHoldOrder(cast) end, RC_HOLD_EVERY_MS)
end


-- Throw `movers` (the raid, or just the Mage) at the Order. The target is re-picked each
-- call from whatever is still standing, so a re-kick recovers a raid whose first target died -
-- Order and Gatekeepers are natively hostile, this only skips the milling-about.
-- If the Order is wiped there is nothing to aggro onto, so bait-move the raid onto the Order's
-- muster point instead: fighting over the ground the set-piece is about, rather than idling at the
-- rift - from where, unlocked with nothing nearer, they would come find the players.
function rcEngage(cast, movers)
    movers = Utils.LivingActors(movers)
    if #movers == 0 then return end

    local target = Utils.LivingActors(cast.order)[1]
    if target then
        for _, npc in ipairs(movers) do AVU.ForceAggro(npc, target) end
        LogDebug("REACTORS CLOUD - " .. #movers .. " Gatekeeper(s) sent at the Order", SETTINGS.DEBUG_STORY)
        return
    end

    Log("REACTORS CLOUD - no Order left; marching the raid onto their muster point")
    AVU.AttackMove(movers, RC_ORDER_SP)   -- bait is pooled/self-managed (AVU.SpawnAggroBait); don't destroy it
end


-- The anchor StoryManager's gate reads, merged into EVENTS.LOC by ModuleStory/Events
-- (the coord lives next to the event that spawns on it, so there is one copy of each).
EV.LOC = { ReactorsCloud = RC_ANCHOR }


return EV
