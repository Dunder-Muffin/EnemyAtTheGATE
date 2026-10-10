-- =======================================================================
-- StoryManager (AUTHORITY) - decides WHEN things happen.
--   1) STORY PROGRESS - a rough run-advancement score derived live from WorldFlagSubsystem
--      flags. Gates loot, variants, traders, events. No persistence of its own.
--   2) EVENT GATES - a 10s heartbeat (SM.Tick) fires each scripted set-piece (story flag +
--      proximity + "already happened"). Each set-piece owns its own file in ModuleStory;
--      ModuleStory/Events is the front door that names them (the EVENTS registry).
--      Once-ever gates persist via FileIO (STATE.StoryData); once-per-load gates use a STATE flag.
--   Events is required LAZILY inside gate functions - a top-level require would be a load cycle.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local Utils = require("AnteUtils.Utils")
local ItemSpawner = require("AnteCore.ItemSpawner")
local FileIO = require("AnteCore.FileIO")
local EVU = require("ModuleStory.EventUtils")
local ENUMS = require("AnteData.Enums")
local Items = require("AnteData.Items")
local HexedTreeStalker = require("AnteNPCs.HexedTreeStalker")
local RisePatrol = require("ModuleStory.RisePatrol")
local HydroBridge = require("ModuleStory.HydroBridge")
local Winter = require("ModuleStory.Winter")
local PlantEscape = require("ModuleStory.PlantEscape")
local SleepShade = require("ModuleStory.SleepShade")
local TraderDirector   -- lazy-required in SM.Tick (ModuleTraders loads after the engine in main)

local Log = Utils.Log
local LogDebug = Utils.LogDebug
local LogBad = Utils.LogBad

local SM = {}

-- Fire an event by its registry name (lazy require - see the header).
local function runEvent(name, ...)
    return require("ModuleStory.Events").Run(name, ...)
end

-- Read an event anchor coord from EVENTS.LOC, lazily at tick time.
--   * Coords live next to the event that spawns on them, so there's one copy of each.
local function eventLoc(key)
    return require("ModuleStory.Events").LOC[key]
end


-- =======================================================================
-- STORY PROGRESS - world-flag name -> the value reaching it implies. (Ported from AnteUp1.)
--   * StoryProgress = max(values of all currently-set flags).
--   * Sparse/monotonic by design - a rough guide, not an exact quest state.
-- =======================================================================
SM.STORY_FLAG_VALUES = {
    Office_ReachedLobby          = 10,
    Office_Silo3PortalOpened     = 11,
    Fog_Completed                = 12,
    WeatherFogTriggeredOnce       = 14,
    Office_ForkliftDoorOpened    = 15,
    Manufacturing_Arrived        = 20,
    MF_MetVarsha                 = 21,
    MF_OpenTrainStation          = 22,
    MF_MetBlacksmith2            = 23,
    TrainCompletedOnce           = 24,
    MF_PumpsFixed                = 27,
    MF_ExitOpened                = 28,
    LABS_EnteredLabs             = 30,
    LABS_Met_Thule               = 31,
    Labs_Helmholtz_Opened        = 32,
    LABS_TurretsDeactivated      = 33,
    LABS_AnteverseBFixed         = 34,
    LABS_CompletedAnteverseB     = 35,
    LABS_OpenVacuumDoor          = 36,
    Security_Entered             = 40,
    Security_Gate1Opened         = 41,
    NightRealm_ShadowA_Destroyed = 42,
    NightRealm_ShadowB_Destroyed = 43,
    Salem_Opened                 = 44,
    Salem_Complete               = 45,
    NightRealm_ShadowC_Destroyed = 46,
    NightRealm_ShadowD_Destroyed = 47,
    Security_ExitOpened          = 48,
    Dams_DarkWaterDrained        = 50,
    Dams_ReachedCentral          = 51,
    Dams_ActivatedPump1          = 52, --Central
    Dams_MetSwimInstructor       = 53,
    Dams_ActivatedPump3          = 54, --Voussoir
    Dams_ActivatedPump2          = 55, --Tower
    DAMS_CompletedVoussoir       = 56,
    Dams_ActivatedPump4          = 57, --Transmission?
    Dams_AllPumpsActivated       = 58,
    Dams_SpillwayOpen            = 59,
    Plant_EnteredPlant           = 60,
    Plant_AnteC_Entered          = 61,
    Plant_AnteC_FoundWarhead     = 62,
    Plant_FungusDestroyed        = 63,
    Plant_ExitOpened             = 64,
    Reactors_FirstContact        = 70,
    Reactors_S1Labs_Complete     = 71, -- Dusk
    -- Reactors_SecondContact       = 72, -- Cahn after Dusk
    -- Reactors_ThirdContact        = 73, -- Dr Hill intro
    Reactors_S4RadWaste_Complete = 72, -- Cloud
    Reactors_S3Overgrowth_Complete = 73,
    Reactors_S2War_Button1_Pressed = 74,
    Reactors_S2War_Button2_Pressed = 75,
    Reactors_S2War_Button3_Pressed = 76,
    Reactors_S2War_Complete       = 77,
    Reactors_AllStations_Complete = 78,
    Reactors_SG_Entered           = 79,
    Reactors_SG_ExitOpened        = 80,
    V_INQ_Entrance                = 81,
    V_INQ_HastaMet                = 82,
    V_INQ_SunDiskTouched          = 83,
    Res_HastaTria_EndCutscene     = 84,
    Residence_Entered             = 90,
    Res_Objective1_Complete       = 91,
    Residence_IceWallRemoved      = 92,
    Res_EnteredBotanicals         = 93,
    Residence_Wall                = 94,
    Fracture_Forcefield_Complete  = 95,
    Fracture_DL_AllEyes_Destroyed = 96,
    Residence_Fracture_Complete   = 97,
    End_Contact                   = 100,
    EndBossPhase1Complete         = 101,
    EndBossPhase2Complete         = 102,
    EndBossDefeated               = 103,
    End_MainStoryComplete         = 104,
}

-- Recompute at most this often (FAST_TICK units, ~10/s).
--   * NPCs die in bunches in a melee; reading every world flag per death would be wasteful.
local STORY_TTL_TICKS = 50   -- ~5s
local lastComputeTick = -100000

-- Set of currently-active world-flag names { name = true }; nil if the subsystem isn't ready
-- (flags not loaded). AUTHORITY (world flags are server data).
function SM.GetWorldFlags()
    local subsystem = Utils.GetWorldFlagSubsystem()
    if IsNotValid(subsystem) then return nil end

    local ok, loaded = pcall(function() return subsystem:HasWorldFlagsLoaded() end)
    if not ok or not loaded then return nil end

    local out = {}
    local flags = {}
    pcall(function() subsystem:GetWorldFlags(flags) end)
    for _, f in ipairs(flags) do
        local ok2, name = pcall(function() return f:get():ToString() end)
        if ok2 and name and name ~= "" then out[name] = true end
    end
    return out
end

-- Current StoryProgress, recomputed from the live flags and cached for STORY_TTL_TICKS.
-- Each compute starts at 0, so it always reflects this world, never a stale save value.
-- `knownFlags` (optional) lets a caller that already marshalled flags this beat pass them in.
-- Reading world flags is a full TArray walk, so SM.Tick avoids doing it twice.
function SM.GetStoryProgress(knownFlags)
    local now = STATE.FAST_TICK or 0
    if not knownFlags and now - lastComputeTick < STORY_TTL_TICKS then
        return STATE.StoryProgress or 0
    end
    lastComputeTick = now

    local flags = knownFlags or SM.GetWorldFlags()
    if not flags then return STATE.StoryProgress or 0 end

    local story = 0
    for name, value in pairs(SM.STORY_FLAG_VALUES) do
        if flags[name] and value > story then story = value end
    end

    if story ~= (STATE.StoryProgress or 0) then
        LogDebug("StoryProgress -> " .. story, SETTINGS.DEBUG_STORY)
    end
    STATE.StoryProgress = story
    return story
end



-- =======================================================================
-- GATE 1 - OFFICE GARDENS. ONE-TIME event, two-phase (no precise "left Fargarden" flag exists).
-- ARM: player enters V_Anteverse_A early enough to matter; persisted so a reload keeps it live.
-- FIRE: once armed, a 3s poll (kept off the 10s SM.Tick for snappier timing) trips the moment
-- a player reaches the office exit.
-- =======================================================================
local OG_ARM_MAX_PROGRESS = 11      -- Don't run this event after Flathill
local OG_ARM_LOC          = FVector(125650, 334480, 2030)   -- Detect if player in Fargardens
local OG_FIRE_LOC         = FVector(-14430, 19830, 3035)    -- the office-side exit
local OG_POLL_MS          = 2000 -- start polling when a player leaves Flathill exit
local OG_FIRE_NEAR        = 2000 -- player near the portal exit (Office level 3 ceiling)
local ogPolling           = false

function SM.GateOfficeGardens(story)
    local data = STATE.StoryData or {}
    if data.OfficeFargardensDone then return end

    -- ARM. Gate the ARM only: once armed, the poll may still fire even if finishing V_Anteverse_A
    -- nudges StoryProgress past the cap.
    if not data.OfficeFargardensArmed then
        if (story or 0) > OG_ARM_MAX_PROGRESS then return end
        if not Utils.IsPlayerNearby(OG_ARM_LOC, 15000) then return end
        data.OfficeFargardensArmed = true
        FileIO.SaveStoryData()
        Log("Story EVENT - Office Gardens ARMED (player entered V_Anteverse_A)")
    end

    -- Armed (now, or on a prior load): make sure the fast poll is running.
    --   * Self-reschedules until a player reaches the exit, then fires once, marks done, stops.
    if ogPolling then return end
    ogPolling = true

    local function poll()
        local d = STATE.StoryData or {}
        if not STATE.ModEnabled or d.OfficeFargardensDone then ogPolling = false; return end

        if Utils.IsPlayerNearby(OG_FIRE_LOC, OG_FIRE_NEAR) then
            -- Mark done BEFORE running so a second poll can't double-fire it.
            d.OfficeFargardensDone = true
            FileIO.SaveStoryData()
            ogPolling = false
            Log("Story EVENT - Office Gardens triggered (player reached the office exit)")
            runEvent("Event_Office_Gardens")
            return
        end
        Utils.QueueWork(poll, OG_POLL_MS)
    end
    Utils.QueueWork(poll, OG_POLL_MS)
end


-- =======================================================================
-- BIG BOT: obsolete as a gate
-- =======================================================================


-- =======================================================================
-- GATE 2 - ORDER AMBUSH. ONE-TIME ever (persisted), two-phase like GATE 1.
-- The beat is "the Order comes for you once you are back at base": beating the train sends
-- players home for a task several minutes long, so the window is deliberately loose.
-- ARM: the train is complete. Persisted, so logging out between the train and the trip home
-- keeps it live.
-- FIRE: a slow poll trips on the first player standing at a Crafting Bench - and only that
-- player gets ringed.
-- A world already well past the beat when we first look is sealed armed+done instead, so an
-- existing save never gets ambushed retroactively.
-- =======================================================================
local OA_STALE_PROGRESS = 30      -- past this the beat has been and gone
local OA_POLL_MS        = 180000
local OA_BENCH_NEAR     = 2500    -- 25m of a Crafting Bench = they are home
local oaPolling         = false

-- The first live player standing at a Crafting Bench, or nil.
local function oaBenchPlayer()
    local AVU = require("AnteUtils.AVUtils")
    for _, p in ipairs(Utils.LivePlayers()) do
        local ok, loc = pcall(function() return p:K2_GetActorLocation() end)
        if ok and loc then
            local hits = AVU.GetNearbyActorsOfClass(loc, OA_BENCH_NEAR,
                ENUMS.DeployedObjs.CRAFTING_BENCH) or {}
            if #hits > 0 then return p end
        end
    end
    return nil
end

function SM.GateOrderAmbush(flags, story)
    local data = STATE.StoryData or {}
    if data.OrderAmbushDone then return end

    -- ARM. Gate the ARM only: once armed the poll stays live however far the story runs on.
    if not data.OrderAmbushArmed then
        if (story or 0) > OA_STALE_PROGRESS then
            data.OrderAmbushArmed, data.OrderAmbushDone = true, true
            FileIO.SaveStoryData()
            Log("Story EVENT - Order Ambush sealed unfired (world is already past the beat)")
            return
        end
        if not (flags and flags.TrainCompletedOnce) then return end
        data.OrderAmbushArmed = true
        FileIO.SaveStoryData()
        Log("Story EVENT - Order Ambush ARMED (train complete)")
    end

    -- Armed (now, or on a prior load): make sure the poll is running.
    if oaPolling then return end
    oaPolling = true

    local function poll()
        local d = STATE.StoryData or {}
        if not STATE.ModEnabled or d.OrderAmbushDone then oaPolling = false; return end

        local target = oaBenchPlayer()
        if target then
            -- Mark done BEFORE running so a second poll can't double-fire it.
            d.OrderAmbushDone = true
            FileIO.SaveStoryData()
            oaPolling = false
            Log("Story EVENT - Order Ambush triggered (player is back at a Crafting Bench)")
            runEvent("Event_Manu_OrderAmbush", target)
            return
        end
        Utils.QueueWork(poll, OA_POLL_MS)
    end
    Utils.QueueWork(poll, OA_POLL_MS)
end


-- =======================================================================
-- GATE 3 - LAB CONTAINMENT BREACH. ONE-TIME ever (persisted).
--   * Fires once the turrets are cut (StoryProgress >= 33) and a player reaches any entrance.
-- =======================================================================
local CB_PROGRESS  = 33     -- LABS_TurretsDeactivated
local CB_NEAR      = 2000   -- ~20m: any one entrance trips it
local CB_ENTRANCES = {
    FVector(11600, 3825, 2050),
    FVector(7770, 6125, 2050),
    FVector(6650, 7020, -900),
}

function SM.GateLabContBreach(story)
    local data = STATE.StoryData or {}
    if data.LabsAssaultDone then return end
    if story < CB_PROGRESS then return end

    local atEntrance = false
    for _, loc in ipairs(CB_ENTRANCES) do
        if Utils.IsPlayerNearby(loc, CB_NEAR) then atEntrance = true; break end
    end
    if not atEntrance then return end

    data.LabsAssaultDone = true
    FileIO.SaveStoryData()
    runEvent("Event_Lab_ContBreach")
end


-- =======================================================================
-- GATE 4 - LAB PORTAL PESTS. Once per world, not persisted.
--   * Fires on the EDGE of LABS_CompletedAnteverseB (story 34 -> 35): the flag persists, so
--     "is it set" would misfire on every later load - only "it was unset a tick ago, now it is"
--     counts. The WorldFlagsChanged hook ticks us the instant it lands, so t0 is the exit.
--   * The event checks portal proximity itself at fire time.
-- =======================================================================
local LPP_FLAG     = "LABS_CompletedAnteverseB"
local LPP_DELAY_MS = 5000   -- let the players clear the portal first
local lppPrevSet   = nil    -- nil = not observed yet this world

function SM.GateLabPortalPests(flags)
    if not flags then return end
    local nowSet = flags[LPP_FLAG] == true
    local fire = (lppPrevSet == false) and nowSet
    lppPrevSet = nowSet
    if not fire then return end

    Utils.QueueWork(function() runEvent("Event_Lab_PortalPests") end, LPP_DELAY_MS)
end


-- =======================================================================
-- GATE 5 - SECURITY CUTSCENE. ONE-TIME ever (persisted).
--   * The trigger is the SECURITY KEYPAD's own Activated bool, not Security_Gate1Opened: that
--     flag lands well before the gate actually opens, so the squad used to arrive while the
--     players were still standing at the lock.
--   * Two-stage, the GATE 13 (Command) shape: the 10s beat only tests proximity, then arms a 1s watcher
--     that polls the keypad. The keypad is found ONCE per arm - a FindAllOf on a cadence is the
--     banned microlag pattern - and a scan that finds nothing backs off for SC_RESCAN_TICKS.
--   * A keypad ALREADY activated the first time we see it means the gate was opened before this
--     gate ever watched it (a save from before the mod, or before this change). Latch done and
--     stay quiet rather than ambushing a hall the players cleared hours ago.
-- =======================================================================
-- Button_Generic is the parent of every button in the game, and FindAllOf matches SUBCLASSES
-- too, so this one query covers the keypad without caring which button the lock turns out to be
-- - Activated lives on the parent either way.
local SC_LOCK_CLASS   = "Button_Generic_C"
local SC_REGION_NEAR  = 6000   -- 60m: close enough that the walkway is streamed in
local SC_LOCK_NEAR    = 500    -- 5m around the authored coord; the next button along is 15m away
local SC_WATCH_MS     = 1000
local SC_RESCAN_TICKS = 300    -- 30s before another scan, for arriving ahead of the stream-in
local SC_DELAY_MS     = 5000   -- the unlock itself can still fail if the player walks off mid-use

local scWatching = false
local scNextTick = 0

-- The one lock this gate cares about. A placed prop has no identity but its LOCATION, so the
-- NEAREST button to the anchor wins rather than the first one inside the radius.
local function findSecurityLock()
    local anchor = eventLoc("SecurityLock")
    if not anchor then return nil end

    local best, bestDistSq
    for _, b in ipairs(FindAllOf(SC_LOCK_CLASS) or {}) do
        if Utils.IsActorValid(b) then
            local loc = b:K2_GetActorLocation()
            -- The distance test also rejects the class-default object (it reads as origin).
            if loc and Utils.WithinDistance(anchor, loc, SC_LOCK_NEAR) then
                local d = Utils.DistSq(anchor, loc)
                if d and (not bestDistSq or d < bestDistSq) then best, bestDistSq = b, d end
            end
        end
    end
    return best
end

local function lockOpened(button)
    local on = false
    pcall(function() on = button.Activated == true end)
    return on
end

function SM.GateSecurityCutscene()
    local data = STATE.StoryData or {}
    if data.ReaperCutsceneDone or scWatching then return end

    -- FAST_TICK resets to 0 on a world change; without this a cooldown armed in the previous
    -- world sits in the future forever (the GateINQNightRealm lesson).
    local tick = STATE.FAST_TICK or 0
    if tick < scNextTick - SC_RESCAN_TICKS then scNextTick = 0 end
    if tick < scNextTick then return end
    if not Utils.IsPlayerNearby(eventLoc("SecurityLock"), SC_REGION_NEAR) then return end

    scNextTick = tick + SC_RESCAN_TICKS   -- armed on the ATTEMPT, so a miss can't rescan next beat
    local lock = findSecurityLock()
    if not lock then
        LogDebug("SECURITY CUTSCENE - no button at the authored lock coord (/au-keypads reads it)",
                 SETTINGS.DEBUG_STORY)
        return
    end

    if lockOpened(lock) then
        data.ReaperCutsceneDone = true
        FileIO.SaveStoryData()
        Log("Story GATE - SECURITY CUTSCENE skipped: the gate was already unlocked")
        return
    end

    Log("Story GATE - SECURITY CUTSCENE: watching the Security lock ("
        .. (Utils.GetActorClassName(lock) or "?") .. ")")
    scWatching = true
    local function watch()
        -- A stream-out invalidates the lock; the beat re-arms once someone comes back.
        if not STATE.ModEnabled or Utils.IsActorInvalid(lock) then scWatching = false; return end
        if not lockOpened(lock) then
            Utils.QueueWork(watch, SC_WATCH_MS)
            return
        end

        -- Latch NOW, before the delay, so nothing in the window can double-fire it.
        scWatching = false
        local d = STATE.StoryData or {}
        d.ReaperCutsceneDone = true
        FileIO.SaveStoryData()
        Log("Story GATE - SECURITY CUTSCENE: the lock opened")
        Utils.QueueWork(function() runEvent("Event_Security_Cutscene") end, SC_DELAY_MS)
    end
    Utils.QueueWork(watch, 0)
end


-- =======================================================================
-- GATE 6 - PLANT ESCAPE. ONE-TIME ever (persisted).
-- Plant_ExitOpened is the door the ambush answers, so the flag IS the trigger - gated on the
-- flag rather than story == 64 because StoryProgress is max(all set flags) and a later one would
-- silently move it off 64 before this beat ran.
-- The flag persists, so a fresh load far from the Plant would spend the ambush on an unstreamed
-- hall. PlantEscape.Start owns that check (it is the same radius its waves are gated on) and
-- reports whether it armed - so the once-ever latch is only spent on an event that really began.
-- Not retroactive: it belongs to the moment the exit opens. A save already into Reactors walked
-- out of the Plant without it, so the latch is spent unfired and the gate stops looking.
-- =======================================================================
local PLE_FLAG = "Plant_ExitOpened"
local PLE_EXPIRED = 70   -- Reactors_FirstContact: past the Plant, the beat can no longer happen

function SM.GatePlantEscape(flags, story)
    local data = STATE.StoryData or {}
    if data.PlantEscapeDone or not (flags and flags[PLE_FLAG]) then return end

    if (story or 0) >= PLE_EXPIRED then
        data.PlantEscapeDone = true
        FileIO.SaveStoryData()
        Log("Story GATE - PLANT ESCAPE: story past the Plant, marked done without firing")
        return
    end

    if not PlantEscape.Start("the Plant exit opened") then return end

    data.PlantEscapeDone = true
    FileIO.SaveStoryData()
end


-- =======================================================================
-- GATE 7 - REACTORS DUSK DEFENSE. ONE-TIME ever (persisted).
-- Fires the instant Reactors_S1Labs_Complete is set (WorldFlagsChanged ticks us immediately).
-- Gated on the FLAG, not story == 71: StoryProgress is max(all set flags), so a later flag
-- would silently move it off 71 and the window would be missed.
-- =======================================================================
local RD_FLAG = "Reactors_S1Labs_Complete"
local RD_NEAR = 12000   -- a player must be this close (= the hall is streamed in)

function SM.GateReactorsDusk(flags)
    local data = STATE.StoryData or {}
    if data.ReactorsDuskDefenseDone then return end
    if not (flags and flags[RD_FLAG]) then return end

    -- Require a player at the hall first: the flag PERSISTS, so loading a save that already
    -- cleared Dusk would otherwise fire into an unloaded hall. Guard before marking done.
    if not Utils.IsPlayerNearby(eventLoc("ReactorsDusk"), RD_NEAR) then return end

    data.ReactorsDuskDefenseDone = true
    FileIO.SaveStoryData()
    runEvent("Event_ReactorsDusk_Defense")
end


-- =======================================================================
-- GATE 8 - REACTORS CLOUD TAKEOVER. ONE-TIME ever (persisted).
-- Fires the instant Reactors_S4RadWaste_Complete is set, same two rules as GATE 7 Dusk:
-- gate on the FLAG (not story==74, which a later flag could move past), and guard player
-- proximity BEFORE the done-marker (the flag persists, so a fresh load must not misfire).
-- =======================================================================
local RC_FLAG = "Reactors_S4RadWaste_Complete"
local RC_NEAR = 10000   -- ~100m from the approach: a player must be this close (= the area is streamed in)

function SM.GateReactorsCloud(flags)
    local data = STATE.StoryData or {}
    if data.ReactorsCloudTakeoverDone then return end
    if not (flags and flags[RC_FLAG]) then return end
    if not Utils.IsPlayerNearby(eventLoc("ReactorsCloud"), RC_NEAR) then return end

    data.ReactorsCloudTakeoverDone = true
    FileIO.SaveStoryData()
    runEvent("Event_ReactorsCloud_GKTakeover")
end


-- =======================================================================
-- GATE 9 - REACTORS GALE POWERED. THREE ONE-TIME events (persisted), one per S2War button.
-- Flag-gated (not story==N, the Dusk/Cloud rule) so WorldFlagsChanged fires each wave on the spot.
-- Proximity guarded BEFORE the done-marker: the flags persist, so a fresh load must not fire
-- into an unloaded arena.
-- =======================================================================
local RG_NEAR = 10000   -- a player must be this close to Center (= the arena is streamed in)
local RG_BUTTONS = {
    { Flag = "Reactors_S2War_Button1_Pressed", Done = "ReactorsGale1Done", Event = "Event_ReactorsGale_Powered1" },
    { Flag = "Reactors_S2War_Button2_Pressed", Done = "ReactorsGale2Done", Event = "Event_ReactorsGale_Powered2" },
    { Flag = "Reactors_S2War_Button3_Pressed", Done = "ReactorsGale3Done", Event = "Event_ReactorsGale_Powered3" },
}

function SM.GateReactorsGale(flags)
    if not flags then return end
    local data = STATE.StoryData or {}
    local arena = eventLoc("ReactorsGale")

    for _, b in ipairs(RG_BUTTONS) do
        if not data[b.Done] and flags[b.Flag] then
            -- Guard BEFORE the done-marker, so a far-away load just defers it until they're back.
            if Utils.IsPlayerNearby(arena, RG_NEAR) then
                data[b.Done] = true
                FileIO.SaveStoryData()
                runEvent(b.Event)
            end
        end
    end
end



-- =======================================================================
-- GATE 10 - SHADOWGATE CACHE. ONE-TIME ever (persisted), two-phase like GATE 1 (flag and
-- drop site are ~200m apart).
-- ARM: Reactors_SG_Entered trips at the vignette entrance, before the cache's part of V_SUOMI
-- streams in; persisted so a logout keeps the poll alive.
-- FIRE: polls Utils.IsLocationLoaded, not proximity - dropping into an unstreamed level is
-- the PlacedSpawns failure mode, and vignettes are single levels so this is cheap and exact.
-- =======================================================================
local SUOMI_FLAG    = "Reactors_SG_Entered"
local SUOMI_POLL_MS = 3000
local suomiPolling  = false

function SM.GateShadowgateCache(flags)
    local data = STATE.StoryData or {}
    if data.ShadowgateCacheDone then return end

    -- ARM. Latch it so a later flag (StoryProgress moving past 79) can't close the window.
    if not data.ShadowgateCacheArmed then
        if not (flags and flags[SUOMI_FLAG]) then return end
        data.ShadowgateCacheArmed = true
        FileIO.SaveStoryData()
        Log("Story EVENT - Shadowgate cache ARMED (player entered the SG vignette)")
    end

    -- Armed (now, or on a prior load): make sure the poll is running.
    if suomiPolling then return end
    suomiPolling = true

    local function poll()
        local d = STATE.StoryData or {}
        if not STATE.ModEnabled or d.ShadowgateCacheDone then suomiPolling = false; return end

        -- Guard BEFORE the done-marker, so a not-yet-streamed level just re-polls.
        if Utils.IsLocationLoaded(eventLoc("ShadowgateCache")) then
            d.ShadowgateCacheDone = true
            FileIO.SaveStoryData()
            suomiPolling = false
            Log("Story EVENT - Shadowgate cache triggered (V_SUOMI streamed in)")
            runEvent("Event_Reactors_ShadowgateCache")
            return
        end
        Utils.QueueWork(poll, SUOMI_POLL_MS)
    end
    Utils.QueueWork(poll, SUOMI_POLL_MS)
end



-- =======================================================================
-- KILL REWARDS + VIGNETTE RESET - the persisted consequences of an event's boss dying.
-- Called from the variant defs' OnDeath (AnteNPCs/RobotSecurity) and the vignette hook
-- (AnteCore/SystemHooks). AUTHORITY.
-- =======================================================================

-- Big Bot died: record it, and drop the Disc Turret the first time it's ever killed in this world.
--   * Respawn is owned by its PlacedSpawn's day-cooldown now; the old per-vignette re-arm is gone.
--   * BigBotKilledOnce also permanently retires the welcome party - see RobotSecurity.bigBotEscortOnce.
function SM.OnBigBotKilled(actor, loc)
    local data = STATE.StoryData or {}

    if not data.BigBotKilledOnce then
        data.BigBotKilledOnce = true
        if loc and loc.X ~= 0 then
            Utils.QueueWork(function()
                ItemSpawner.DropPool({ { Items.Global.BASE, Items.Global.DISC_TURRET } }, nil, loc, 100)
            end, 1000)
        end
        Log("Story EVENT - BigBot killed (FIRST time) - Disc Turret dropped")
    else
        LogDebug("BigBot killed again - no Disc Turret (already dropped once)", SETTINGS.DEBUG_STORY)
    end

    FileIO.SaveStoryData()
end


-- ONE-TIME unique drop for the placed-spawn Cafeteria Bot (mirrors the BigBot Disc Turret).
--   * Called for every cafeteria bot's death, but only a death in the placed spawn's streaming
--     level counts. It can wander well past any radius, so the level gate beats a coord leash.
--     Needs no per-actor state, so it survives mod reloads.
--   * Death-only, so the ~tens-of-ms GetLevelName spatial query is a non-issue.
local CAFBOT_DROP_LEVEL = "Facility_Office3"   -- the placed spawn at (-20500, 22650, 2610)

function SM.OnCafeteriaBotKilled(loc)
    local data = STATE.StoryData or {}
    if data.CafBotMicrowaveDropped then return end
    if not loc or loc.X == 0 then return end
    if Utils.GetLevelName(loc) ~= CAFBOT_DROP_LEVEL then return end

    data.CafBotMicrowaveDropped = true
    Utils.QueueWork(function()
        ItemSpawner.DropPool({ { Items.Global.BASE, Items.Global.MICROWAVE } }, nil, loc, 75)
    end, 1000)
    Log("Story EVENT - placed Cafeteria Bot killed (FIRST time) - microwave dropped")
    FileIO.SaveStoryData()
end


-- =======================================================================
-- GATE 11 - V_INQ NIGHT REALM  (Event_INQ_NightRealm)
--   * ONE TIME EVENT
--   * "/event INQ_NightRealm" still runs a siege on demand regardless of the latch.
-- =======================================================================
-- The AUTOMATIC trigger only.
local NR_ENABLED       = true
local NR_NEAR          = 2500   -- player proximity to start
local NR_COOLDOWN_TICKS = 2400  -- 4 min at the 100ms FAST_TICK

-- The siege's own end trigger: a player here has just cleared the hall, so the door must not
-- reopen in their face.
local NR_END      = FVector(98240, 33960, 2980)
local NR_END_NEAR = 1500        -- a bit wider than the event's own 10m stop, as a standoff

local nrNextTick = 0
local nrWasActive = false

function SM.GateINQNightRealm()
    if not NR_ENABLED then return end

    -- ONE-TIME: a siege already ran to an ending in this world - the door stays sealed.
    local data = STATE.StoryData or {}
    if data.NightRealmDone then return end

    local tick = STATE.FAST_TICK or 0
    -- FAST_TICK resets to 0 on a world change; without this a stale cooldown from the
    -- previous world would sit in the future forever and the gate would never fire again.
    if tick < nrNextTick - NR_COOLDOWN_TICKS then nrNextTick = 0 end

    -- The latch rides the ACTIVE->INACTIVE edge: the first observed ending, whatever the
    -- reason (far end reached, time cap, abandoned, dev stop), marks the event done.
    local active = require("ModuleStory.Events").INQNightRealmActive()
    if active then nrWasActive = true; return end
    if nrWasActive then
        nrWasActive = false
        data.NightRealmDone = true
        FileIO.SaveStoryData()
        Log("Story EVENT - Night Realm siege ended; sealed for this world (NightRealmDone)")
        return
    end

    if tick < nrNextTick then return end
    if not Utils.IsPlayerNearby(eventLoc("INQNightRealm"), NR_NEAR) then return end
    if Utils.IsPlayerNearby(NR_END, NR_END_NEAR) then return end

    nrNextTick = tick + NR_COOLDOWN_TICKS   -- also armed here, so a crash mid-siege still backs off
    runEvent("Event_INQ_NightRealm")
end


-- =======================================================================
-- GATE 12 - PRAETORIUM PURIFIED ASSAULT (Event_INQ_PurifiedAssault)
-- Restartable; latches (Events.PurifiedAssaultDone) until the next vignette reset once players
-- break through to the spawn ground. Trigger deliberately tight (10m).
-- The "both Purifiers alive" check lives in the event starter, which needs the probe scans
-- anyway. The cooldown spaces start-attempt scans so a camped player costs one probe a minute.
-- =======================================================================
local PA_ENABLED        = true
local PA_TRIGGER_NEAR   = 1000   -- 10m, in UE units
local PA_COOLDOWN_TICKS = 600    -- 1 min at the 100ms FAST_TICK, between start attempts

local paNextTick = 0

function SM.GateINQPurifiedAssault()
    if not PA_ENABLED then return end

    local E = require("ModuleStory.Events")
    if E.PurifiedAssaultActive() or E.PurifiedAssaultDone() then return end

    -- FAST_TICK resets to 0 on a world change; without this a cooldown armed in the previous
    -- world sits in the future forever (the GateINQNightRealm lesson).
    local tick = STATE.FAST_TICK or 0
    if tick < paNextTick - PA_COOLDOWN_TICKS then paNextTick = 0 end
    if tick < paNextTick then return end

    if not Utils.IsPlayerNearby(eventLoc("PurifiedAssault"), PA_TRIGGER_NEAR) then return end

    -- Armed on every ATTEMPT, not just a successful start: a start refused for missing
    -- Purifiers must not re-scan on every 10s heartbeat.
    paNextTick = tick + PA_COOLDOWN_TICKS
    runEvent("Event_INQ_PurifiedAssault")
end


-- =======================================================================
-- GATE 13 - PRAETORIUM COMMAND ASSAULT (Event_INQ_Command)
-- Once per vignette. Must fire as the player steps in, faster than the 10s heartbeat allows.
-- Two-stage: the 10s beat checks cheaply for anyone in the Command wing. If so, it arms a 1s
-- watcher (Events.INQCommandEntryTripped, a pure-Lua distance walk) that fires on first hit.
-- It disarms once the wing empties, the event starts, or the vignette latch (INQCommandDone) sets.
-- cmdWatching is reset in SM.Register: a world teardown wipes the WorkQueue mid-poll, and a
-- stale true would kill the gate for the whole next world.
-- =======================================================================
local CMD_ENABLED     = true
local CMD_REGION_NEAR = 20000   -- 200m: close enough that the wing is streamed and worth polling
local CMD_WATCH_MS    = 3000    -- the fast entry poll, only while a player is in the region

local cmdWatching = false

function SM.GateINQCommand()
    if not CMD_ENABLED or cmdWatching then return end

    local E = require("ModuleStory.Events")
    if E.INQCommandActive() or E.INQCommandDone() then return end
    if not Utils.IsPlayerNearby(eventLoc("INQCommand"), CMD_REGION_NEAR) then return end

    cmdWatching = true
    local function watch()
        -- Re-required every pass, not captured: a "/reload" swaps the module table underneath us.
        local Ev = require("ModuleStory.Events")
        if not STATE.ModEnabled
            or Ev.INQCommandActive() or Ev.INQCommandDone()
            or not Utils.IsPlayerNearby(eventLoc("INQCommand"), CMD_REGION_NEAR) then
            cmdWatching = false
            return
        end

        if Ev.INQCommandEntryTripped() then
            cmdWatching = false
            runEvent("Event_INQ_Command")
            return
        end
        Utils.QueueWork(watch, CMD_WATCH_MS)
    end
    Utils.QueueWork(watch, 0)
end


-- =======================================================================
-- GATE 12 - THE ASSAULT'S TANK TURRET (Event_INQ_TankTurret)
-- Silences the automated LMG on the Order tank. Not persisted: the turret is a placed actor
-- that comes back on every sublevel stream-in, so the mute re-applies per arrival.
-- ARRIVAL-EDGE, NOT A POLL: only fires on a false->true IsLocationLoaded transition, never on
-- the 10s cadence - a FindAllOf under 15s is the banned microlag pattern
-- ([[anteup2-microlag-and-profiler]]). OT_BREAK opts into permanently destroying the tank instead.
-- =======================================================================
local OT_ENABLED  = true
local OT_BREAK    = false   -- true = blow the tank up (permanent) instead of muting the gun
-- Tight on purpose: the anchor is an exact reading, while DisableTankTurretsAt's own 100m
-- default (the /au-turret "nearest tank" case) would also catch other Order tanks nearby.
local OT_RADIUS   = 2000
-- The turret arms in its own BeginPlay, a beat after the level reports loaded, so the first
-- pass can miss it. Retry a couple of times, then stop.
local OT_RETRY_MS = 2500
local OT_TRIES    = 3

local otWasLoaded = false
local otTriesLeft = 0
local otPolling   = false

function SM.GateINQTankTurret()
    if not OT_ENABLED then return end

    local loc = eventLoc("OrdTank")
    if not loc then return end        -- coords not filled in yet; /au-turret still works

    local loaded = Utils.IsLocationLoaded(loc)

    -- Streamed out: re-arm so the next arrival re-applies.
    --   * The turret that comes back is a NEW actor with the class defaults, so a stale
    --     "done" would leave it live.
    if not loaded then
        otWasLoaded, otTriesLeft = false, 0
        return
    end

    if otWasLoaded then return end    -- already handled this arrival
    otWasLoaded = true
    otTriesLeft = OT_TRIES

    if otPolling then return end
    otPolling = true

    local function attempt()
        if not STATE.ModEnabled or otTriesLeft <= 0 then otPolling = false; return end
        otTriesLeft = otTriesLeft - 1

        -- Bail if the level went away underneath us mid-retry.
        if not Utils.IsLocationLoaded(loc) then otPolling = false; return end

        local hits = require("ModuleStory.Events")
            .DisableTankTurretsAt(loc, OT_RADIUS, { Break = OT_BREAK, Label = "INQ TANK TURRET" })
        if hits > 0 then otPolling = false; return end

        Utils.QueueWork(attempt, OT_RETRY_MS)
    end
    Utils.QueueWork(attempt, 0)
end


-- =======================================================================
-- GATE 14 - PRAETORIUM HOLY FIRE (Event_INQ_HolyFire)
-- Keeps the two staked fire patches near the Command Blockade lit whenever anyone is there.
-- No story flag, no latch, no persistence - ambient scenery. Events.INQHolyFire is idempotent
-- and owns the presence check, so an empty Praetorium costs two cheap distance walks.
-- =======================================================================
local HFIRE_ENABLED = true

function SM.GateINQHolyFire()
    if not HFIRE_ENABLED then return end
    runEvent("Event_INQ_HolyFire")
end


-- Vignette/portal reset: re-arm anything that respawns per-vignette. (The Big Bot, the only
-- per-vignette boss, moved to a PlacedSpawn whose day-cooldown owns its own respawn.)
function SM.OnVignetteReset()
    -- GATE 12 (tank): reset rebuilds the level, so the tank/turret are fresh actors again.
    otWasLoaded, otTriesLeft = false, 0

    -- GATE 11: drop the crash-backoff cooldown. nrWasActive too - a reset can tear the world
    -- down MID-siege, and a stale true would wrongly latch NightRealmDone as "ended".
    nrNextTick = 0
    nrWasActive = false

    -- GATE 12: the breakthrough latch is per-vignette by design; also clears the start-attempt
    -- cooldown and orphans a run the teardown interrupted.
    paNextTick = 0
    pcall(function() require("ModuleStory.Events").PurifiedAssaultOnVignetteReset() end)

    -- GATE 13: once-per-vignette, so this re-arms it; the watcher flag goes with it (its
    -- queued poll died in the teardown's WorkQueue wipe).
    cmdWatching = false
    pcall(function() require("ModuleStory.Events").INQCommandOnVignetteReset() end)
end



-- =======================================================================
-- TICK - the story heartbeat (AUTHORITY).
--   * Self-reschedules via the WorkQueue (like ClientEffects), armed once by SM.Register from InitMod.
--   * Also driven immediately by the WorldFlagsChanged hook (AnteCore/SystemHooks),
--     so flag-gated events react on the spot.
-- =======================================================================
local STORY_TICK_MS = 10000

-- In-flight guards for the heavy sub-steps SM.Tick spreads across later drains (see below).
--   * Cleared when each sub-item runs - and RESET in SM.Register: a world teardown wipes the
--     WorkQueue with sub-items still queued, which would otherwise leave a flag stuck true
--     and silently kill that sub-step for the whole next world.
local subQueued = { placed = false, tree = false, trader = false, revenge = false }

function SM.Tick()
    -- ONE flag marshal per beat: read the flags once, derive StoryProgress from that same set
    -- (each GetWorldFlags is a full TArray walk; this beat used to do two).
    local flags = SM.GetWorldFlags()
    local story = SM.GetStoryProgress(flags)

    -- Debug: the highest story flag currently set (the one driving StoryProgress).
    if SETTINGS.DEBUG_STORY then
        local hiName, hiVal = "(none)", 0
        if flags then
            for name, value in pairs(SM.STORY_FLAG_VALUES) do
                if flags[name] and value > hiVal then hiVal, hiName = value, name end
            end
        end
        LogDebug(string.format("StoryProgress - %d [%s]", story, hiName), SETTINGS.DEBUG_STORY)
    end

    -- Scripted set-pieces, in STORY ORDER - same numbering as the EVENTS registry, so a gate and
    -- its set-piece are always found under the same number.
    --   * Retired gates, kept as pointers: the Big Bot and the Tarasque door pair are
    --     SD.PlacedSpawns entries now (StoryMin 15 / 36 - see AnteNPCs/RobotSecurity.lua and
    --     AnteNPCs/Tarasque.lua); the Lab Control Center event is gone.
    --   * The presence-only ONGOING loops (Rise Patrol, Hexed Tree, Winter) are batched onto their
    --     own drain further down; HydroBridge has a story window, so it rides this list.
    SM.GateOfficeGardens(story)           --  1
    SM.GateOrderAmbush(flags, story)      --  2
    SM.GateLabContBreach(story)           --  3
    SM.GateLabPortalPests(flags)          --  4  (once per world; flag-edge, not persisted)
    SM.GateSecurityCutscene()             --  5  (keypad-watched, not flag-gated)
    SleepShade.GateTick(story)            --     ONE-TIME (any base; its own 1s sleep watcher)
    HydroBridge.GateTick(story)           --     ONGOING (its own story window + gate proximity)
    SM.GatePlantEscape(flags, story)      --  6  (the Plant exit ambush)
    SM.GateReactorsDusk(flags)            --  7
    SM.GateReactorsCloud(flags)           --  8
    SM.GateReactorsGale(flags)            --  9  (S2War buttons 1/2/3)
    SM.GateShadowgateCache(flags)         -- 10
    SM.GateINQNightRealm()                -- 11  (one-time per world)
    SM.GateINQTankTurret()                -- 12  (per-arrival; the assault's tank)
    SM.GateINQPurifiedAssault()           -- 12  (restartable, per vignette; PA_ENABLED-gated)
    SM.GateINQCommand()                   -- 13  (once per vignette; arms a 1s entry watcher)
    SM.GateINQHolyFire()                  -- 14  (ongoing ambient hazard; HFIRE_ENABLED-gated)

    -- The heavy steps run as their own WorkQueue items, offset onto different 100ms drains.
    -- Inline here they used to stack all sub-steps into one frame and cause a visible hitch.
    -- The in-flight guards stop a WorldFlagsChanged-driven SM.Tick (which can fire between
    -- heartbeats) from double-queuing.

    -- Synthetic spawners (SpawnerData.PlacedSpawns): keep placed NPCs alive in their levels.
    if not subQueued.placed then
        subQueued.placed = true
        Utils.QueueWork(function()
            subQueued.placed = false
            if not STATE.ModEnabled then return end
            EVU.EnsurePlacedSpawns(story)
        end, 300)
    end

    -- The cheap presence gates, batched onto one drain: the Hexed Tree stalker (Canaan vignette;
    -- arm delay shortens once Salem's done), the Winter arm (two compares until story passes
    -- Voussoir, then a no-op) and the V_RISE Order sweep.
    if not subQueued.tree then
        subQueued.tree = true
        Utils.QueueWork(function()
            subQueued.tree = false
            if not STATE.ModEnabled then return end
            HexedTreeStalker.GateTick(story)
            Winter.GateTick(story)
            RisePatrol.GateTick()
        end, 600)
    end

    -- Custom trader visits (ModuleTraders/TraderDirector): story-gated, rotating, day-scheduled.
    if not subQueued.trader then
        subQueued.trader = true
        Utils.QueueWork(function()
            subQueued.trader = false
            if not STATE.ModEnabled then return end
            TraderDirector = TraderDirector or require("ModuleTraders.TraderDirector")
            TraderDirector.Tick(story)
        end, 900)
    end

    -- Revenge assaults (ModuleRevenge/RevengeDirector): scan triggers, book nights, fire the one
    -- that's due. Takes this beat's flag set, since the trigger model is flag-first. Re-marshalling
    -- them in the sub-item would cost a second full TArray walk.
    if not subQueued.revenge then
        subQueued.revenge = true
        Utils.QueueWork(function()
            subQueued.revenge = false
            if not STATE.ModEnabled then return end
            require("ModuleRevenge.RevengeDirector").Tick(story, flags)
        end, 1200)
    end
end


function SM.Register()
    if STATE.StoryArmed then return end
    STATE.StoryArmed = true
    subQueued = { placed = false, tree = false, trader = false, revenge = false }   -- see note above

    -- Same hazard as subQueued: a world teardown wipes the WorkQueue with a poll item still
    -- queued, so an in-flight flag left true would silently kill that gate for the whole
    -- next world. Clear all self-rescheduling in-flight flags here.
    ogPolling, oaPolling, suomiPolling, otPolling = false, false, false, false
    otWasLoaded, otTriesLeft = false, 0   -- GATE 12: arrival edge is per-world
    cmdWatching = false                   -- GATE 13: the entry watcher's in-flight flag
    scWatching, scNextTick = false, 0      -- GATE 5: same, plus the keypad-scan backoff
    lppPrevSet = nil                      -- GATE 4: the flag edge is per-world

    -- GATE 14: same hazard one layer down - clear the fire's refresh-beat flag or the
    -- patches never light again this world.
    pcall(function() require("ModuleStory.Events").INQHolyFireReset() end)

    -- Same, for the V_RISE sweep: its grace delay / beat died with the WorkQueue, and it owns
    -- file-local in-flight flags that ResetState can't reach.
    RisePatrol.Reset()

    -- ...and for the Hydroplant bridge siege, which also owns the once-per-world keypad latch.
    HydroBridge.Reset()

    -- ...and the Plant exit ambush, whose wave ticker died with the WorkQueue.
    PlantEscape.Reset()

    -- ...and the Sleep Shade, whose sleep watcher and spot search died the same way.
    SleepShade.Reset()

    EVU.ResetPlacedRuntime()   -- per-world: arrival edges / backoffs / stream cache

    -- Load this world's persisted story data (boss kill flags, placed-spawn cooldowns) first.
    FileIO.LoadStoryData()

    local function loop()
        if not STATE.ModEnabled then STATE.StoryArmed = false; return end
        local ok, err = pcall(SM.Tick)
        if not ok then LogBad("StoryManager tick error: " .. tostring(err)) end
        Utils.QueueWork(loop, STORY_TICK_MS)
    end
    Utils.QueueWork(loop, STORY_TICK_MS)
    Log("StoryManager events registered")
end

return SM
