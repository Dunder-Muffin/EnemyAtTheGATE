-- =======================================================================
-- EVENT 13 - PRAETORIUM COMMAND  (Event_INQ_Command)  [AUTHORITY] - RESTARTABLE (once per vignette)
--   * Two night realm doors open and shades attack. Order reinforces
--   * Each Shade spawn gets a LockTarget (one-time) on a nearby enemy Order npc
--   * Each Order spawn gets a LockTarget (one-time) on a random Shade
--   * A couple weak 'Event Purifiers'
--   Gate: SM.GateINQCommand (three entryway bubbles, polled at 1s).
--
--   Dev: "/event INQ_Command" force-starts it (still needs a player in the wing). "/event
--        INQ_CommandStop" ends a test run and clears the once-per-vignette latch, so the test
--        loop is Stop -> re-trigger.
--   Decode detail (STING_SOUND, ENGAGE_MAX_Z, the rally beat): AnNotes/Modules/Events.md.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local EVU = require("ModuleStory.EventUtils")
local ENUMS = require("AnteData.Enums")
local ASSETS = require("AnteCore.AssetManager")

local Log = Utils.Log
local LogDebug = Utils.LogDebug

local EV = {}

-- The courtyard's middle: the start/abandon guard, the shades' push destination, and the anchor
-- the story gate reads (exported as EV.LOC at the foot of the file).
local IC_ANCHOR = FVector(107100, 48400, 1000)


-- ONE top-level local for the whole set-piece: knobs, runtime state and helpers all hang off this
-- table, which also keeps the file clear of Lua's 200-local/upvalue chunk cap.
local IC = {
    ANCHOR    = IC_ANCHOR,   -- the courtyard's middle (defined once, up top)
    GUARD     = 15000,   -- a player must be this close for the wing to count as loaded (start guard)
    ABANDON   = 15000,   -- ...and still be, or nobody is watching and the run is torn down

    -- THE ENTRY TRIGGERS - the three ways into the wing, each a 5m bubble, polled every second by
    -- SM.GateINQCommand. Any one of them starts the assault.
    ENTRIES    = {
        FVector(106830, 46016, 1210),   -- E1
        FVector(108430, 46120, 1210),   -- E2
        FVector(106160, 50500, 1110),   -- E3
    },
    ENTRY_NEAR = 500,    -- 5m, in UE units

    -- THE SPAWN POINTS. Door points are Night Realm tears the shades step out of, with FX and a
    -- portal arrival. The rest are Order muster points, where reinforcements walk on with their
    -- native spawn-in, including the Centurion's rope-down (see EVU.SpawnOne's RopeSpawn note).
    POINTS = {
        N1 = { Loc = FVector(105280, 48210, 950),  Yaw = 0,   Door = true }, -- Left Entrance
        N2 = { Loc = FVector(108820, 50340, 1410), Yaw = 180, Door = true }, -- Right Entrance
        O1 = { Loc = FVector(106330, 49940, 1100) }, --Prime Entrance
        O2 = { Loc = FVector(108090, 48180, 1440) }, --Globe
        O3 = { Loc = FVector(106060, 48220, 950), Yaw=180 }, -- Left Ent
    },
    -- Fixed iteration order, since pairs() is unordered. It decides the per-point stagger offset,
    -- so without it the same beat would spawn in a different order every run.
    ORDER = { "N1", "N2", "O1", "O2", "O3" },

    -- THE SCRIPT, in seconds from the trigger. One entry per beat. Each key is a spawn point, and
    -- its list is what walks out of it. Names are mixed variant/base row - both are accepted.
    WAVES = {
        { At = 5, N1 = { "Grunt Shade" },
                   N2 = { "Grunt Shade", "LabRat Shade" } ,
        },

        { At = 15, N1 = { "Breacher Shade", "Grunt Shade" },
                   N2 = { "Grunt Shade", "Harvester Reaper" },
                   O1 = { "Suppressor Grunt" },
        },

        { At = 20, N1 = { "LabRat Shade", },
                   N2 = { "LabRat Shade", } ,
        },

        { At = 25, N1 = { "Grunt Shade" },
                   N2 = { "Grunt Shade", "Breacher Shade" },
                   O1 = { "Grunt_Guard", "Speculatores" },
                   O2 = { "Grunt" },
                   O3 = { "Sweeper" } },

        { At = 35, N1 = { "Reaping Reaper", "Grunt Shade", "Grunt Shade" },
                   N2 = { "Grunt Shade", "LabRat Shade", "Breacher Shade" },
                   O1 = { "Speculatores", "Grunt_Guard" },
                   O2 = { "Skirmisher", "Skirmisher" },
                   O3 = { "Speculatores", "Event Purifier" } },

        { At = 45, N1 = { "Grunt Shade", "Grunt Shade" },
                   N2 = { "Neophyte Shade" },
                   O1 = { "Speculatores" },
                   O2 = { "Speculatores" },
                   O3 = { "Speculatores" } },

        { At = 55, N1 = { "Grunt Shade" },
                   N2 = { "Breacher Shade" },
                   O1 = { "Sweeper" },
                   O2 = { "Sweeper" },
                   O3 = { "Sweeper" },
        },

        { At = 65, N1 = { "Grunt Shade", "Breacher Shade", "Neophyte Shade", },
                   N2 = { "Grunt Shade", "Breacher Shade" },
                   O1 = { "Purified Grunt", "Purified Grunt", "Event Purifier" },
                   O2 = { "Praetorium Sniper" },
                   O3 = { "Centurion Grunt" },
        },
        { At = 75, N1 = { "Grunt Shade", "Grunt Shade", },
                   N2 = { "Neophyte Shade", "Neophyte Shade", "Reaping Reaper"  },
                   O1 = { "Suppressor Grunt" },
                   O2 = { "Event Purifier", "Grunt_Captain" },
                   O3 = { "Suppressor Grunt" },                   
        },
    },

    -- Cosmetic beats (seconds). CLOSE also ends the run.
    TINT_AT   = 0,
    STING_AT  = 1,
    DOORS_AT  = 2,
    CLOSE_AT  = 80,
    CLOSE_GRACE_MS = 2500,

    -- Cold-load insurance for the Reaper class both Reapers ride. It is not what makes them safe:
    -- their BeginPlay froze the game outright in the drain, and the actual fix is NpcSpawner's
    -- OFFHOOK_ROWS hop. A warm class is just one less thing happening on the frame they land.
    -- Warmed late rather than at t=0 because a preload never pins (see S3). It beats GC by timing.
    WARM_AT = 15,
    WARM    = { ENUMS.NpcClasses.Reaper },

    -- The blackout. Timed AT THE SOURCE (see the banner) - this number is the only thing keeping
    -- it on screen, so it is safe by construction rather than by everyone remembering to clear it.
    TINT_SECONDS = 3,
    TINT_COLOR   = nil,   -- nil = AVU.SCREENTINT_DEFAULT; a plain number 0..1 is a brightness shorthand

    -- The two tears, held open from DOORS_AT to CLOSE_AT. LIFE > BEAT so consecutive sends overlap
    -- instead of gapping, and BEAT is a multiple of POLL (see the banner).
    DOOR_KEY      = "NIGHTREALM_DOOR",    -- the SILENT entry: the sting is its own beat (STING_AT)

    -- THE OPENING CUE plays via AVU.PlaySound2DAll (flat, non-positional), not as a world sound -
    -- a positional play was inaudible across the hall. Deliberately not an assault sting: this is
    -- a tear opening, not the Anteverse siege warning. See AnNotes/Modules/Events.md.
    STING_SOUND   = ENUMS.SOUNDS.PORTAL_NIGHTREALM_OPEN,
    DOOR_BEAT_MS  = 6000,
    DOOR_LIFE_S   = 8,

    POLL_MS   = 2000,     -- the ticker: abandon check + door heartbeat + the hard cap ride this
    STAGGER_MS = 700,     -- between bodies out of the SAME point on one beat
    POINT_MS   = 250,     -- ...and between the points themselves, so a beat is never one frame
    SPREAD     = 250,     -- arrival scatter at a door, each nav-projected by PortalSummon

    -- Where the shades are told to go (a standing order, not an aggro lock - see the banner).
    PUSH          = IC_ANCHOR,
    PUSH_DELAY_MS = 4000,   -- past the spawn/mutation window: an order written into it is eaten

    -- ...and if the fight has already reached the doorway, engage that instead of walking past it.
    -- A bare lock (no hold) lapses on the arrival's first completed swing, so it commits to the
    -- body in front of it and then becomes a normal combatant again - the Night Realm recipe.
    -- Shared by both sides: a shade takes the nearest foe at its door, an Order reinforcement a
    -- random shade in the same radius (IC.OnOrderArrival).
    ENGAGE_RADIUS = 2000,   -- 20m

    -- THE STOREY BAND THAT KEEPS THE WAR ON ONE FLOOR. Every aggro sweep here is a 3D sphere, and
    -- the mezzanine's Sun Disk garrison sits close enough in plan view to get swept into an engage
    -- radius through the ceiling. ENGAGE_MAX_Z caps the sweep to this floor's own Z band, applied
    -- to all three behaviour sweeps. ENGAGE_RADIUS is left alone - the problem was the vertical
    -- axis, not the distance. See AnNotes/Modules/Events.md.
    ENGAGE_MAX_Z  = 600,

    -- THE RALLY BEATS - twice mid-run, wake the wing's idlers up to the war (IC.Rally). NPC-vs-NPC
    -- has no hearing path and the sight cone hangs off capsule yaw (AnNotes/AnteSystems/NPCPerception.md), so
    -- a garrison body facing away from the pour stands idle until something hits it.
    RALLY_AT     = { 30, 60 },   -- seconds from the trigger
    RALLY_POINT  = "O2",
    RALLY_RADIUS = 1300,

    -- Event shades drop nothing (both loot systems - the native death drop AND the variant's own
    -- Night Essence). This is a repeatable-per-vignette set-piece that fields a dozen-plus bodies;
    -- flip to true if it should be farmable after all.
    SHADE_LOOT = false,

    -- Every shade this run put in the wing, so the abandoned ending can take them back out.
    roster = {},

    -- Runtime state. `token` orphans every queued beat on stop/restart; `done` is the
    -- until-next-vignette-reset latch (cleared by INQCommandOnVignetteReset / the dev stop).
    run = { active = false, token = 0, done = false, tinted = false },
}

function EV.INQCommand()
    local run = IC.run
    if run.active then Log("Command Assault - already running (ignoring re-trigger)"); return end
    if EVU.LatchStops(run.done, "Command Assault", "already run this vignette (latched)") then
        return
    end
    if not Utils.AreaLoaded(IC.ANCHOR, IC.GUARD, "INQ COMMAND ASSAULT") then return end

    run.token   = run.token + 1
    run.active  = true
    run.done    = true    -- latched AT THE START: a second entry trigger must not stack a run
    run.elapsed = 0
    run.tinted  = false
    -- The doors open at DOORS_AT as a one-shot below; the heartbeat takes over a full beat later.
    run.nextDoor = IC.DOORS_AT * 1000 + IC.DOOR_BEAT_MS
    IC.roster = {}

    local token = run.token
    Log("Command Assault - the Night Realm opens on the Command Center")

    -- t=0  the realm bleeds through. Self-expiring - the stop clears it early if it is still ours.
    -- The sting is warmed on the same beat so its own item a second later is a cache hit, not a
    -- cold load landing after the doors. A preload never pins (see S3), so it is warmed here, per
    -- run, rather than trusted from startup.
    Utils.QueueWork(function()
        if not IC.Live(token) then return end
        run.tinted = AVU.SetScreenTint(IC.TINT_COLOR, IC.TINT_SECONDS) and true or false
        ASSETS.WarmPinned({ IC.STING_SOUND })
    end, IC.TINT_AT * 1000)

    -- t=1  the tear is heard before it is seen. ONE call, not one per door: this plays AT each
    -- player at a fixed volume with no location involved, so a second call is just the same cue at
    -- double volume.
    Utils.QueueWork(function()
        if not IC.Live(token) then return end
        AVU.PlaySound2DAll(IC.STING_SOUND)
    end, IC.STING_AT * 1000)

    -- t=DOORS_AT  both doors open (silent entry - the sting already played).
    Utils.QueueWork(function()
        if not IC.Live(token) then return end
        IC.BeatDoors()
    end, IC.DOORS_AT * 1000)

    -- t=WARM  pull the heavy arrival's class in ahead of its beat (see IC.WARM).
    Utils.QueueWork(function()
        if not IC.Live(token) then return end
        ASSETS.WarmPinned(IC.WARM)
    end, IC.WARM_AT * 1000)

    -- t=RALLY_AT[...]  wake the wing's idlers up to the war (see IC.Rally).
    for _, at in ipairs(IC.RALLY_AT) do
        Utils.QueueWork(function()
            if not IC.Live(token) then return end
            IC.Rally()
        end, at * 1000)
    end

    -- t=0  GC-PIN the whole run's variant asset union (every role; a no-op with ASSET_KEEPER off).
    -- Pinned assets can't be collected between waves. A pinned path is also trusted
    -- straight from the AssetManager cache instead of a full UObject-array walk (~20-30ms flat per
    -- lookup even when warm), so each wave body's mutation isn't re-paying that per asset per step.
    -- IC.WARM covers the Reaper's class separately (it pins as a CLASS under CLASS_PINS).
    Utils.QueueWork(function()
        if not IC.Live(token) then return end
        local V = require("AnteVariants.Variants")
        local seen, list = {}, {}
        for _, wave in ipairs(IC.WAVES) do
            for _, key in ipairs(IC.ORDER) do
                for _, name in ipairs(wave[key] or {}) do
                    local def = V[name]
                    for _, p in ipairs((def and def.Assets) or {}) do
                        if not seen[p] then seen[p] = true; list[#list + 1] = p end
                    end
                end
            end
        end
        require("AnteCore.AssetKeeper").PinPaths(list)
    end, 0)

    -- t=CLOSE(+grace)  the doors shut and the run ends. Its own item, at an exact time, AFTER the
    -- last wave's stagger has drained - see IC.CLOSE_GRACE_MS and the IC.Tick header.
    --   * Queued BEFORE the waves on purpose: the drain walks the queue BACKWARDS (TickManager
    --     removes as it goes), so on a same-tick tie the LATER-queued item runs FIRST - and the
    --     spawns must win that tie, not the stop that would orphan them.
    Utils.QueueWork(function()
        if not IC.Live(token) then return end
        IC.Stop("the doors close")
    end, IC.CLOSE_MS())

    -- The waves, each body on its own queued item, all orphaned by one token bump.
    for _, wave in ipairs(IC.WAVES) do
        local base = wave.At * 1000
        for pi, key in ipairs(IC.ORDER) do
            for i, name in ipairs(wave[key] or {}) do
                local at = base + (pi - 1) * IC.POINT_MS + (i - 1) * IC.STAGGER_MS
                Utils.QueueWork(function() IC.Spawn(token, key, name) end, at)
            end
        end
    end

    IC.Tick(token)
end

-- Dev handle ("/event INQ_CommandStop"): quiet ending, our shades removed, and the
-- once-per-vignette latch CLEARED so the next trigger (or another "/event INQ_Command") runs.
function EV.INQCommandStop()
    IC.Stop("stopped by hand", { Despawn = true })
    IC.run.done = false
end

-- Read by StoryManager's gate: never arm on top of a live run or a spent vignette.
function EV.INQCommandActive() return IC.run.active == true end
function EV.INQCommandDone()   return IC.run.done == true end

-- Has a player stepped into one of the three entryways? The gate's fast poll (1s) calls this, so
-- it is a PURE-LUA distance walk over the GameState player array - no scans, no subsystem calls.
function EV.INQCommandEntryTripped()
    local r2 = IC.ENTRY_NEAR * IC.ENTRY_NEAR
    for _, p in ipairs(Utils.LivePlayers()) do
        local ok, at = pcall(function() return p:K2_GetActorLocation() end)
        if ok and at then
            for _, e in ipairs(IC.ENTRIES) do
                if Utils.DistSq(e, at) <= r2 then return true end
            end
        end
    end
    return false
end

-- Vignette reset: clear the once-per-vignette latch, and orphan a run the teardown interrupted
-- (its queued beats died with the WorkQueue; a stale `active` would block every restart).
function EV.INQCommandOnVignetteReset()
    IC.run.done = false
    if IC.run.active then
        IC.run.active = false
        IC.run.token = IC.run.token + 1
    end
    IC.roster = {}
end


-- =======================================================================
-- HELPERS
-- =======================================================================

-- Is this queued item still the run it was scheduled under? Every deferred beat
-- asks first - a stop (or a restart) can never be undone by an item already in flight.
function IC.Live(token)
    return IC.run.active and token == IC.run.token and STATE.ModEnabled
end

-- When the run ends, in ms from the trigger (the authored close beat + the grace
-- that lets the last wave finish walking out - see IC.CLOSE_GRACE_MS).
function IC.CLOSE_MS()
    return IC.CLOSE_AT * 1000 + IC.CLOSE_GRACE_MS
end

-- The ticker. Only the abandon check and door heartbeat - the script is
-- fixed-length, so every other beat (including the ending) is scheduled up front.
-- The ending is deliberately not checked here. A poll-based check could land on the same drain
-- as the last wave's spawns and orphan them, and could only ever fire late. It's its own queued
-- item at an exact time - the hard cap below only guards a close that got lost entirely.
function IC.Tick(token)
    if not IC.Live(token) then return end
    local run = IC.run

    -- Nobody in the wing: tear it down and take the shades with us (see the banner).
    if not Utils.IsPlayerNearby(IC.ANCHOR, IC.ABANDON) then
        return IC.Stop("nobody left in the wing", { Despawn = true })
    end

    if run.elapsed >= IC.CLOSE_MS() + IC.POLL_MS * 3 then
        return IC.Stop("hard cap (the close never fired)")
    end

    if run.elapsed >= run.nextDoor then
        run.nextDoor = run.elapsed + IC.DOOR_BEAT_MS
        IC.BeatDoors()
    end

    run.elapsed = run.elapsed + IC.POLL_MS
    Utils.QueueWork(function() IC.Tick(token) end, IC.POLL_MS)
end

-- One heartbeat send per tear. The SILENT registry entry - this fires every
-- DOOR_BEAT_MS, and any entry carrying a sound would re-sting on each one. The opening cue is its
-- own one-shot at STING_AT, off this channel entirely (IC.STING_SOUND).
function IC.BeatDoors()
    for _, key in ipairs(IC.ORDER) do
        local pt = IC.POINTS[key]
        if pt.Door then AVU.SendClientFX(pt.Loc, IC.DOOR_KEY, IC.DOOR_LIFE_S, pt.Yaw) end
    end
end

-- Put one body out of one spawn point.
--   * A DOOR uses PortalSummon with Rift = false: the full arrival recipe (nav-project, suppress
--     the native spawn-in, lifetime plumbing) WITHOUT opening a second doorway - the tear is
--     already open and owned by the heartbeat. EmergeFX is off too: they step OUT of a door, they
--     should not also pop in.
--   * An ORDER post is a plain EVU.SpawnAt on the authored coord (Exact - the default path fuzzes
--     and can snap a body onto the storey above), keeping its native spawn-in.
function IC.Spawn(token, key, name)
    if not IC.Live(token) then return end
    local pt = IC.POINTS[key]
    if not pt then return end

    if not pt.Door then
        EVU.SpawnAt(name, pt.Loc, { Exact = true, Yaw = pt.Yaw, FuzzYaw = 20,
            callback = function(npc) IC.OnOrderArrival(token, npc) end })
        LogDebug("Command Assault - " .. key .. " fields " .. name, SETTINGS.DEBUG_STORY)
        return
    end

    -- Variant or raw DT row - PortalSummon takes either, under different keys.
    local isVariant = require("AnteVariants.Variants")[name] ~= nil
    local entry = isVariant and { Variant = name, Count = 1 } or { Npc = name, Count = 1 }

    AVU.PortalSummon(pt.Loc, { entry }, {
        Rift      = false,
        EmergeMs  = 0,
        EmergeFX  = false,
        Spread    = IC.SPREAD,
        Yaw       = pt.Yaw,
        -- Faction is deliberately UNSET: the shade defs write SHADE_FACTION themselves in Stats,
        -- and one passed here would land on top of it.
        -- Attack is deliberately UNSET: IC.OnArrival hands out the orders instead (a bare lock on
        -- whatever is at the door, plus the IC.PUSH destination), and it can pick per arrival.
        OnSpawned = function(npc) IC.OnArrival(token, npc, pt.Loc) end,
    })
    LogDebug("Command Assault - " .. key .. " door: " .. name, SETTINGS.DEBUG_STORY)
end

-- A body has stepped out of a tear. Book it (so the abandoned ending can take it
-- back), suppress its drops, and give it somewhere to be.
function IC.OnArrival(token, npc, door)
    if not IC.Live(token) or Utils.IsActorInvalid(npc) then return end
    IC.roster[#IC.roster + 1] = npc

    -- A Reaper that ends up somewhere it can't walk down from gets sent back to this door.
    if door and Utils.GetActorRowName(npc) == "Reaper" then
        require("AnteNPCs.ShadesHelpers").SetStrandHome(npc, door)
    end

    -- TWO loot systems, and neither should feed off an ambience set-piece: StripLoot covers the
    -- NATIVE death drop, SuppressScriptedLoot the variant's own (shadeDeath's Night Essence).
    if not IC.SHADE_LOOT then
        AVU.StripLoot(npc)
        AVU.SuppressScriptedLoot(npc)
    end

    -- Both orders land on ONE beat, held until past the spawn/mutation window (a destination or a
    -- target written while the entrance montage still owns the body is just eaten).
    Utils.QueueWork(function()
        if not IC.Live(token) then return end
        if Utils.IsActorInvalid(npc) or Utils.IsDeadSafe(npc) then return end

        -- 1) Something hostile already at the doorway? Take it - a bare lock, so it commits to
        --    that body and is a free combatant again after its first swing.
        local foe = IC.NearestFoe(npc, IC.ENGAGE_RADIUS)
        if foe then AVU.AssertLock(npc, foe) end

        -- 2) And either way, march on the Order's ground: a standing order that yields to combat
        --    and re-arms itself after every fight (AVU.SetPointOfInterest). With no foe nearby it
        --    is the only order; with one it is where the shade drifts once that fight is over.
        AVU.SetPointOfInterest(npc, IC.PUSH)
    end, IC.PUSH_DELAY_MS)
end

-- The nearest live NPC `npc` is hostile to, within `radius`, or nil. "Hostile" is
-- a plain faction inequality. Reapers are excluded (Invincible, faction 0 - a lock onto one
-- flails forever) and the sweep is capped to ENGAGE_MAX_Z (the Sun Disk garrison sits overhead).
function IC.NearestFoe(npc, radius)
    local loc, myFaction
    pcall(function() loc = npc:K2_GetActorLocation() end)
    pcall(function() myFaction = npc.Faction end)
    if not loc or myFaction == nil then return nil end

    local best, bestD
    for _, other in ipairs(AVU.GetNearbyNpcs(loc, radius, { ignoreActor = npc, maxZ = IC.ENGAGE_MAX_Z }) or {}) do
        local row = Utils.GetActorRowName(other)
        if row ~= "Reaper" and row ~= "ReaperScout" and not Utils.IsDeadSafe(other) then
            local fac
            pcall(function() fac = other.Faction end)
            if fac ~= nil and fac ~= myFaction then
                local ok, at = pcall(function() return other:K2_GetActorLocation() end)
                local d = (ok and at) and Utils.DistSq(loc, at) or math.huge
                if not bestD or d < bestD then best, bestD = other, d end
            end
        end
    end
    return best
end

-- An Order reinforcement has mustered. ONE bare lock (AVU.AssertLock, never a
-- held AVU.LockAggro) onto a random live shade within ENGAGE_RADIUS, so newcomers spread across
-- the pour instead of dog-piling the nearest body. Held past the spawn window like the shades'
-- own orders - a destination written while the spawn-in still owns the body is just eaten.
function IC.OnOrderArrival(token, npc)
    if not IC.Live(token) or Utils.IsActorInvalid(npc) then return end
    Utils.QueueWork(function()
        if not IC.Live(token) then return end
        if Utils.IsActorInvalid(npc) or Utils.IsDeadSafe(npc) then return end
        local shade = IC.RandomShade(npc, IC.ENGAGE_RADIUS)
        if shade then AVU.AssertLock(npc, shade) end
    end, IC.PUSH_DELAY_MS)
end

-- A random live shade from this run's roster within `radius` of `npc`, or nil.
-- The roster is the authoritative arrival list, so no scan - but Reapers are excluded (same
-- reason as IC.NearestFoe) and a nil/unwritten faction is SKIPPED rather than taken: a fresh
-- arrival's Stats may not have landed yet, and "faction unknown" must read as "not a target".
function IC.RandomShade(npc, radius)
    local loc, myFaction
    pcall(function() loc = npc:K2_GetActorLocation() end)
    pcall(function() myFaction = npc.Faction end)
    if not loc or myFaction == nil then return nil end

    local r2 = radius * radius
    local picks = {}
    for _, shade in ipairs(IC.roster) do
        if Utils.IsActorValid(shade) and not Utils.IsDeadSafe(shade) then
            local row = Utils.GetActorRowName(shade)
            if row ~= "Reaper" and row ~= "ReaperScout" then
                local fac
                pcall(function() fac = shade.Faction end)
                if fac ~= nil and fac ~= myFaction then
                    local ok, at = pcall(function() return shade:K2_GetActorLocation() end)
                    if ok and at and Utils.DistSq(loc, at) <= r2
                       and math.abs(at.Z - loc.Z) <= IC.ENGAGE_MAX_Z then
                        picks[#picks + 1] = shade
                    end
                end
            end
        end
    end
    if #picks == 0 then return nil end
    return picks[math.random(#picks)]
end

-- The rally beat. ONE sphere at RALLY_POINT, bucketed by faction in pure Lua,
-- then every idle body gets AVU.JoinCombat against a random opposite-faction body from the same
-- sweep. JoinCombat's native guard (already in combat or holding a target -> no-op) makes this
-- idempotent - it only sweeps up bodies staring at a wall. NPC-only by construction (GetNearbyNpcs).
-- Reapers are skipped (Invincible, faction 0 - see IC.NearestFoe). A nil faction is skipped too,
-- the fresh-arrival rule from IC.RandomShade. Capped to ENGAGE_MAX_Z - see AnNotes/Modules/Events.md.
function IC.Rally()
    local pt = IC.POINTS[IC.RALLY_POINT]
    if not pt then return end

    local byFaction = {}   -- faction -> { npc, ... }, every live rally-able body in the sweep
    for _, npc in ipairs(AVU.GetNearbyNpcs(pt.Loc, IC.RALLY_RADIUS, { maxZ = IC.ENGAGE_MAX_Z }) or {}) do
        local row = Utils.GetActorRowName(npc)
        if row ~= "Reaper" and row ~= "ReaperScout" and not Utils.IsDeadSafe(npc) then
            local fac
            pcall(function() fac = npc.Faction end)
            if fac ~= nil then
                byFaction[fac] = byFaction[fac] or {}
                table.insert(byFaction[fac], npc)
            end
        end
    end

    -- Everyone NOT of faction f, flattened once per faction, so the random pick is one index.
    local foesOf = {}
    for f in pairs(byFaction) do
        local foes = {}
        for g, list in pairs(byFaction) do
            if g ~= f then
                for _, npc in ipairs(list) do foes[#foes + 1] = npc end
            end
        end
        foesOf[f] = foes
    end

    local woke = 0
    for f, list in pairs(byFaction) do
        local foes = foesOf[f]
        if #foes > 0 then
            for _, npc in ipairs(list) do
                if AVU.JoinCombat(npc, foes[math.random(#foes)]) then woke = woke + 1 end
            end
        end
    end
    LogDebug("Command Assault - rally: " .. woke .. " idler(s) joined the war", SETTINGS.DEBUG_STORY)
end

-- End the run. The token bump orphans every queued beat in one write, so there
-- is nothing else to cancel. The doors are then closed EXPLICITLY (letting the heartbeat lapse
-- leaves the last send up for its full lifetime, and up forever on a machine that missed a
-- teardown - AVU.StopClientFX destroys what each renderer has live for that Niagara).
--   * opts.Despawn - quietly remove the shades we placed (only on endings nobody is watching).
function IC.Stop(reason, opts)
    local run = IC.run
    if not run.active then return end
    run.active = false
    run.token = run.token + 1

    AVU.StopClientFX(IC.DOOR_KEY)

    -- Lights back up - but ONLY inside our own window. Past it the tint has already expired on its
    -- own beat, and clearing unconditionally would wipe a tint some OTHER event had raised since.
    if run.tinted and run.elapsed < IC.TINT_SECONDS * 1000 then AVU.ClearScreenTint() end
    run.tinted = false

    if opts and opts.Despawn then
        for i = #IC.roster, 1, -1 do
            local npc = IC.roster[i]
            if Utils.IsActorValid(npc) and not Utils.IsDeadSafe(npc) then
                -- A Reaper leaves by its controller, never by K2_DestroyActor. It owns a child
                -- actor plus a possessed controller, and its own Despawn is the path that unwinds
                -- them - the same class whose BeginPlay wedges the drain (see NpcSpawner's
                -- OFFHOOK_ROWS). Its teardown is not somewhere to improvise.
                local reaper = Utils.GetActorRowName(npc) == "Reaper"
                -- Staggered (the KillNpcsInRadius lesson: each teardown is real work).
                Utils.QueueWork(function()
                    if Utils.IsActorInvalid(npc) then return end
                    if reaper then
                        pcall(function()
                            local c = npc.NPC_Controller
                            if IsNotValid(c) then c = npc:GetController() end
                            if IsValid(c) then c:Despawn() end
                        end)
                        return
                    end
                    pcall(function() if IsValid(npc) then npc:K2_DestroyActor() end end)
                end, i * 200)
            end
        end
    end
    IC.roster = {}

    Log("Command Assault - over (" .. tostring(reason) .. ")")
end


-- The anchor StoryManager's gate reads, merged into EVENTS.LOC by ModuleStory/Events
-- (the coord lives next to the event that spawns on it, so there is one copy of each).
EV.LOC = { INQCommand = IC_ANCHOR }


return EV
