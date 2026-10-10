
-- ============================================================
-- AssaultHooks.lua
-- Registers AIDirector hooks - AssaultManager handles the logic
-- ============================================================

---@diagnostic disable: undefined-field, undefined-global, unused-local, param-type-mismatch, inject-field

local UEHelpers = require("UEHelpers")
local AFUtils   = require("AFUtils.AFUtils")

require("AFUtils.AFBase")
require("AFUtils.BaseUtils.BaseUtils")
require("AFUtils.BaseUtils.FNames")
require("AFUtils.BaseUtils.DefaultObjects")
require("AFUtils.BaseUtils.StaticClasses")

local STATE  = require("Data.STATE")
local CONFIG = STATE.Config
local Utils  = require("Utils.Utils")
local AM     = require("Managers.AssaultManager")
local GATE   = require("Managers.GATEManager")
local AB     = require("Managers.AnteBridge")

local Log = Utils.Log
local LogDebug = Utils.LogDebug

local ASSAULT_DAYS = {
    -- Day 0 = Monday (March 15 1993)
    -- 0=Mon, 1=Tues, 2=Wed, 3=Thurs, 4=Fri, 5=Sat, 6=Sun,
    [1] = { [1]=true },
    [2] = { [1]=true, [5]=true },
    [3] = { [1]=true, [3]=true, [5]=true },
    [4] = { [6]=true, [1]=true, [3]=true, [5]=true },
    [5] = { [0]=true, [1]=true, [2]=true, [3]=true, [4]=true },
    [6] = { [0]=true, [1]=true, [2]=true, [3]=true, [4]=true, [5]=true },
    [7] = { [0]=true, [1]=true, [2]=true, [3]=true, [4]=true, [5]=true, [6]=true },

    -- 8+ = Endless assaults (see ChangeAssaultPhase)
    [8] = { [0]=true, [1]=true, [2]=true, [3]=true, [4]=true, [5]=true, [6]=true },
}

local DAY_STRING = { "Mon", "Tues", "Wed", "Thurs", "Fri", "Sat" }

local hook
local HOOKS = {}


-- ============================================================
-- Portal-storm suppression.
--
-- A portal-storm row (Assault_CurrentData.AssaultSpawnMethod == 1) makes the
-- director open AssaultPortal_BPs near players. Those portals BECOME the
-- assault's spawn locations, and the PortalSuppression bench upgrade destroys
-- them - which empties the locations and cancels the day's assault. Late-game
-- (StoryProgress >= 32) or Endless we rewrite the row to a ground spawn so GATE
-- assaults always proceed and no native portals open.
--
-- Runs after every assault-type selection, always before the director's
-- TryUpdateAssaultLocation opens portals. See memory: native-portal-storm-mechanism.
--
-- *** HANDLE WITH CARE. This rewrite is the single most dangerous line in the
-- mod. *** BeginAssault gives method 1 a free pass - it never checks the patrol
-- location. Every other method goes through the check that, when it fails,
-- kills the assault outright (power leeches + phase 6, no log). Rewriting the
-- method moves the row off the free pass and onto that check.
--   * v1.30/v1.40 stamped EVERY method to 0, and method 0 NEVER assigns a patrol
--     location - so from StoryProgress 32 onward, every single assault died that
--     way. That is the "only 1-2 leeches spawn and then it ends" bug.
--   * We now rewrite 1 -> 2 only, and BeginAssault's pre-hook below backstops
--     the patrol check so a miss can no longer cost an assault.
--   * CONFIG.SUPPRESS_PORTAL_STORMS = false turns the rewrite off entirely.
-- ============================================================
local PORTAL_METHOD_STORM  = 1   -- E_AssaultSpawnMethod: portal storm
local PORTAL_METHOD_GROUND = 2   -- EQS ground spawn. Evidence for 2 over 0:
                                 --   * assault_gkheavy / assault_shotgunsquad natively carry 2
                                 --     and were watched spawning cleanly (2026-08-04)
                                 --   * only the 2/3 branches of OnAssaultEQSResult assign
                                 --     Assault_PatrolTargetLocation

local function suppressPortalStorm(director)
    if CONFIG.SUPPRESS_PORTAL_STORMS == false then return end
    if STATE.StoryProgress < 32 and (CONFIG.ASSAULTS_PER_WEEK or 1) < 8 then return end
    if not director or IsNotValid(director) then return end

    local data = director.Assault_CurrentData
    if data and IsValid(data) then
        pcall(function()
            -- ONLY portal storms. Anything already on 2/3 is left alone.
            local was = data.AssaultSpawnMethod_40_45A45EFC4865CA0BEF4407AAB1065DCA
            if was ~= PORTAL_METHOD_STORM then return end

            data.AssaultSpawnMethod_40_45A45EFC4865CA0BEF4407AAB1065DCA = PORTAL_METHOD_GROUND
            Utils.Log(string.format(
                "[ASSAULT-TRACE] suppressPortalStorm: portal storm -> ground spawn (%d -> %d, SP=%s)",
                PORTAL_METHOD_STORM, PORTAL_METHOD_GROUND, tostring(STATE.StoryProgress)))
        end)
    end
end


function HOOKS.Register()

    -- ============================================================
    -- Endless mode helpers - defined here so both SortAssaultSpawnLists
    -- and the endless loop section below can share the same logic.
    -- ============================================================
    local excludeSet = {}
    for _, r in ipairs(STATE.ENDLESS_EXCLUDE_ROWS) do excludeSet[r] = true end

    local function pickEndlessAssault()
        local all = GATE.GetAllCustomAssaults()
        local sp  = STATE.StoryProgress
        local pool = {}
        -- Пул боссов бросается отдельно, как в обычном режиме
        local boss = AM.TryBossAssault()
        if boss then return boss end

        for _, entry in ipairs(all) do
            -- записи с Pool в обычный выбор не попадают
            if not excludeSet[entry.row] and not entry.data.Pool then
                local min = entry.data.StoryMin or 0
                local max = entry.data.StoryMax or 999
                if sp >= min and sp <= max then
                    table.insert(pool, entry)
                end
            end
        end
        if #pool == 0 then return nil end

        local fresh = {}
        for _, entry in ipairs(pool) do
            if not AM.IsRecentAssault(entry.row, entry.idx) then
                table.insert(fresh, entry)
            end
        end

        local src = (#fresh > 0) and fresh or pool
        return src[math.random(1, #src)]
    end


    -- ============================================================
    -- SortAssaultSpawnLists - Called when director is setting up assault data.
    -- * Clears last assault, this should reflect the NEW assault
    -- ============================================================
    -- This is the ONE hook that rewrites the director's wave lists, so an error
    -- part-way through could once leave the assault with nothing to spawn.
    --   * AssaultManager now resolves before it writes
    --   * this pcall wrapper makes sure a throw anywhere else in here is LOGGED
    --     rather than silently ending the hook
    hook = "/Game/Blueprints/Environment/Systems/Abiotic_AIDirector.Abiotic_AIDirector_C:SortAssaultSpawnLists"
    RegisterHook(hook, function(self)
        local ok, err = pcall(function()
        Log("DEBUG - SortAssaultSpawnLists()")

        local director = self:get()
        if IsNotValid(director) then return end

        -- ANTEUP REVENGE CLAIM - AnteUp's ModuleRevenge hooks THIS SAME FUNCTION and writes the
        -- wave lists itself on a claimed night. Two pre-hooks both run and the ORDER IS NOT
        -- DEFINED, so without this bail whoever happens to run second wins and the revenge is a
        -- coin flip. Bail before touching anything - including the STATE resets below, which
        -- would clobber the prep time the revenge just published.
        local dnmR = AFUtils.GetDayNightManager()
        local todayR = (dnmR and IsValid(dnmR)) and dnmR.CurrentDay or nil
        if todayR and AB.IsDayClaimed(todayR) then
            Log("[GATE-HOOK] SortAssaultSpawnLists - day " .. tostring(todayR) ..
                " is an AnteUp revenge night; leaving the wave lists to it")
            return
        end

        -- If forcing assaults, Assault_CurrentData may initially be nil
        -- * Do NOT return early, set wave lists on the director
        local assaultData = director.Assault_CurrentData
        local hasAssaultData = assaultData and IsValid(assaultData)

        LogDebug("[GATE-HOOK] SortAssaultSpawnLists (assaultData=" .. tostring(hasAssaultData) .. ")", CONFIG.DEBUG_LOG)
        STATE.LastCustomAssault    = nil
        STATE.AssaultPrepTime      = 20000
        STATE.ActiveAssaultWeather = nil

        -- For endless mode: mark that an assault is being set up so the
        -- endless loop doesn't double-fire before Wave 1 confirms it started.
        if (CONFIG.ASSAULTS_PER_WEEK or 1) >= 8 then
            STATE.EndlessAssaultPending = true
        end

        -- Will autoclear assault X seconds after the final spawn. Default 300s
        director.AssaultMaxTimeLimitSeconds = CONFIG.ASSAULT_TIMEOUT or 300

        local debugAssault = STATE.DebugQueuedAssault

        -- In endless mode, if the director's 15s tick triggered this before the
        -- loop set DebugQueuedAssault, pick from the filtered pool ourselves.
        -- This prevents SetCustomAssault from seeing excluded rows (portal storms,
        -- peccaryboss) that exist in the GATE table but are banned in endless mode.
        if not debugAssault and (CONFIG.ASSAULTS_PER_WEEK or 1) >= 8 then
            local chosen = pickEndlessAssault()
            if chosen then
                debugAssault = { row=chosen.row, idx=chosen.idx, data=chosen.data, endless=true }
                LogDebug(string.format("[GATE] SortAssaultSpawnLists: endless pick %s [%s]",
                    chosen.data.Name or chosen.row, chosen.row), CONFIG.DEBUG_LOG)
            end
        end


        -- Draw one of our custom assaults and set it
        if not debugAssault then
            AM.SetCustomAssault(director, assaultData)


        -- WHEN DEBUGGING / ENDLESS: We setup a specific assault
        else
            STATE.DebugQueuedAssault = nil

            -- director calls SelectRandomAssaultType before this, force the assaultname
            local out = {}
            director:SelectNewAssaultType(FName(debugAssault.row), true, out)

            -- 3s prep only for keyboard-triggered debug (not endless loop)
            if hasAssaultData and not debugAssault.endless then
                assaultData.AssaultPrepTime_58_3CA2B5904E9FE2EB428ABEAFF52C6B4E = 3
                STATE.AssaultPrepTime = 3000
            end

            AM.SCM_ApplyAssaultData(director, assaultData, debugAssault.data, debugAssault.row, debugAssault.idx)

        end

        -- NOTE: no suppressPortalStorm here anymore.
        --   * SortAssaultSpawnLists runs INSIDE BeginAssault, after the
        --     location/patrol machinery already ran under the row's real method
        --   * a rewrite here is too late to save a portal-storm row, and could
        --     only disturb one that legitimately opened its portals
        --   * the conversion happens once, queued right after row selection
        --     (see the SelectRandomAssaultType hook)

        end)
        if not ok then
            Utils.LogBad("[GATE] SortAssaultSpawnLists - error: " .. tostring(err) ..
                         " (the assault keeps whatever wave lists it already had)")
        end
    end)


    -- ============================================================
    -- SelectRandomAssaultType - Fires when the director picks a new assault
    --   * If we setup a debug assault do nothing
    -- ============================================================
    hook = "/Game/Blueprints/Environment/Systems/Abiotic_AIDirector.Abiotic_AIDirector_C:SelectRandomAssaultType"
    RegisterHook(hook, function(self)
        Log("DEBUG - SelectRandomAssaultType()")

        local director = self:get()
        if IsNotValid(director) then return end

        -- THE PORTAL-STORM SUPPRESSION, from the only vantage point that works.
        --
        -- Why not inline here:
        --   * a synchronous PRE call edits the PREVIOUS assault's struct - the
        --     native body overwrites Assault_CurrentData the moment it picks a row
        --   * that timing mistake is why suppression never applied to a naturally
        --     scheduled assault, and portal rows at a suppressed base died with
        --     just the end message
        -- Why not a POST-hook:
        --   * POST hooks are not guaranteed on this UE4SS build. Confirmed
        --     2026-08-04: every post-probe on this director stayed silent across
        --     two full assaults while every pre-hook fired.
        --
        -- So we queue it one WorkQueue drain out (~0.1s):
        --   * the native body completes synchronously inside this call, so by the
        --     next drain the struct holds the freshly-picked row
        --   * the location/patrol EQS that reads the method doesn't run until
        --     warning/prep time, seconds later
        --   * the write is a single byte property set - loads nothing
        --   * one task per burst, because SetCustomAssault's redraw loop can call
        --     this 15x back-to-back and 15 identical reports help nobody
        if STATE.SelectReportPending then return end
        STATE.SelectReportPending = true
        Utils.QueueSpawn(function()
            STATE.SelectReportPending = false
            if IsNotValid(director) then return end
            local row, method = "?", "?"
            pcall(function()
                row    = tostring(Utils.FNameToString(director.Assault_CurrentRow))
                method = tostring(director.Assault_CurrentData.AssaultSpawnMethod_40_45A45EFC4865CA0BEF4407AAB1065DCA)
            end)
            Log(string.format("[ASSAULT-TRACE] selected row=%s method=%s", row, method))
            suppressPortalStorm(director)
        end, 0)

        if not STATE.DebugQueuedAssault then return end

        LogDebug("[GATE-HOOK] SelectRandomAssaultType - overriding row to " .. STATE.DebugQueuedAssault.row, CONFIG.DEBUG_LOG)
        local out = {}
        director:SelectNewAssaultType(FName(STATE.DebugQueuedAssault.row), true, out)
        suppressPortalStorm(director)   -- SelectNewAssaultType reset the method; re-apply
                                        -- (Lua-called, so the data really is fresh here)
    end)
    -- No POST-hook here on purpose - they're not guaranteed on this UE4SS build.
    -- The selection report + method force ride the queued task in the PRE-hook.
    -- Cost: we lose the FoundValidRow=false probe ("no DT_Assaults row satisfies
    -- its WorldFlagsRequired"). If the queued report ever prints a STALE row name
    -- at 4pm and no assault follows, that bail is what happened.


    -- ============================================================
    -- CheckDaysSinceLastAssault - decides whether today is an assault day
    --
    -- * Answered from the ASSAULT_DAYS schedule + CONFIG.ASSAULTS_PER_WEEK, and
    --     our own STATE.LastAssaultDay
    -- * We track the day ourselves because dayNight.LastAssaultDay misreports
    --     when an assault runs past midnight, which loses us the next assault
    -- ============================================================
    hook = "/Game/Blueprints/Environment/Systems/Abiotic_AIDirector.Abiotic_AIDirector_C:CheckDaysSinceLastAssault"
    RegisterHook(hook, function(self)

        local schedule = CONFIG.ASSAULTS_PER_WEEK or 1

        -- ANTEUP REVENGE CLAIM - tonight belongs to AnteUp's ModuleRevenge, which forces its own
        -- assault and writes its own wave lists. Stand down completely.
        --   * Checked BEFORE the endless branch on purpose: endless answers true while idle, which
        --     would race the revenge for the same start.
        --   * We do NOT stamp STATE.LastAssaultDay here. Stamping it would make our own scheduler
        --     believe it already used today's slot and silently eat TOMORROW's assault too.
        local dnm = AFUtils.GetDayNightManager()
        local today = (dnm and IsValid(dnm)) and dnm.CurrentDay or nil
        if today and AB.IsDayClaimed(today) then
            LogDebug("[GATE-HOOK] CheckDaysSinceLastAssault() - day " .. tostring(today) ..
                     " is claimed by an AnteUp revenge assault; standing down", CONFIG.DEBUG_LOG)
            return false
        end

        -- Endless mode: only allow when nothing is running or starting up.
        --   * True while idle is what lets the director's own 15s poll start the
        --       next assault - that poll is endless mode's engine.
        --   * Returning true UNCONDITIONALLY made SortAssaultSpawnLists fire
        --       every 15s and overwrite the assault in progress, which is what
        --       the IsAssaultHappening / EndlessAssaultPending guards prevent.
        if schedule >= 8 then
            if Utils.IsAssaultHappening()  then return false end
            if STATE.EndlessAssaultPending then return false end
            return true
        end

        local dayNight = AFUtils.GetDayNightManager()
        if not dayNight or IsNotValid(dayNight) then return end

        local currentDay  = dayNight.CurrentDay or 0
        local dayOfWeek   = currentDay % 7
        local dayName     = DAY_STRING[dayOfWeek + 1] or tostring(dayOfWeek)
        local isScheduled = ASSAULT_DAYS[schedule] and ASSAULT_DAYS[schedule][dayOfWeek]

        LogDebug(string.format("[GATE-HOOK] CheckDaysSinceLastAssault() - Day %d (%s) ourLastAssault=%d scheduled=%s",
            currentDay, dayName, STATE.LastAssaultDay, tostring(isScheduled)), CONFIG.DEBUG_LOG)


        -- No assault today according to our scheduler
        if not isScheduled then
            return false

        -- An assault already happened today
        elseif currentDay <= STATE.LastAssaultDay then
            LogDebug("[GATE-HOOK] CheckDaysSinceLastAssault() - already had assault on day " .. STATE.LastAssaultDay, CONFIG.DEBUG_LOG)
            return false

        -- Let's do an assault today
        else 
            STATE.LastAssaultDay = currentDay
            LogDebug("[GATE-HOOK] CheckDaysSinceLastAssault() - " .. dayName .. " is a scheduled assault day", CONFIG.DEBUG_LOG)
            return true
        end
    end)


    -- ============================================================
    -- IsTodayAssaultDay - Polled by the director every 15s.
    --   * Endless mode: this poll IS the engine. Answering true while idle is
    --       what restarts assaults ~15s after the last one ends (paired with
    --       the CheckForAssaultRestrictedHours override below, which opens the
    --       hours window). Answering false while one is running or pending is
    --       what stops the poll stacking a second start on top.
    -- ============================================================
    hook = "/Game/Blueprints/Environment/Systems/Abiotic_AIDirector.Abiotic_AIDirector_C:IsTodayAssaultDay"
    RegisterHook(hook, function(self)
        if (CONFIG.ASSAULTS_PER_WEEK or 1) >= 8 then
            -- ANTEUP REVENGE CLAIM: endless mode's whole engine is answering true while idle, so
            -- without this it restarts an assault ~15s after the revenge's own ends - and would
            -- also race its start. See the CheckDaysSinceLastAssault guard above.
            local dnm = AFUtils.GetDayNightManager()
            local today = (dnm and IsValid(dnm)) and dnm.CurrentDay or nil
            if today and AB.IsDayClaimed(today) then return false end

            -- Must return true for the director's poll to proceed into
            -- SortAssaultSpawnLists. Returns false while running or pending to
            -- prevent the 15s poll from stacking additional assault starts.
            if Utils.IsAssaultHappening()  then return false end
            if STATE.EndlessAssaultPending then return false end
            return true
        end
    end)


    -- ============================================================
    -- Assault_WarnPlayers - silence the announcer's assault voice line.
    --   (CONFIG.SUPPRESS_ASSAULT_VOICE)
    --
    -- * It's a VOID function, so a pre-hook returning false does NOT cancel it -
    --     that only works on functions with a return value (see IsTodayAssaultDay)
    -- * So we let it run and stop the audio it started: DayNightManager holds the
    --     live component in LastAnnouncementSound
    -- * Parking CurrentAnnouncementIndex past the end stops the follow-up lines
    -- * Deliberately leaves the warning TEXT and the assault sting alone
    -- ============================================================
    if CONFIG.SUPPRESS_ASSAULT_VOICE then
        hook = "/Game/Blueprints/Environment/Systems/Abiotic_AIDirector.Abiotic_AIDirector_C:Assault_WarnPlayers"
        RegisterHook(hook, function(self)
            -- Runs on the director's own frame; stopping an audio component
            -- loads nothing, so this is safe in-hook.
            local ok, err = pcall(function()
                local dayNight = AFUtils.GetDayNightManager()
                if not dayNight or IsNotValid(dayNight) then return end

                local sound = dayNight.LastAnnouncementSound
                if sound and IsValid(sound) then sound:Stop() end

                -- Park the index past the end so PlayNextAnnouncementLine has
                -- nothing left to queue for this announcement.
                local lines = dayNight["Announcement Sounds in Order"]
                if lines then dayNight.CurrentAnnouncementIndex = #lines + 1 end
            end)
            if not ok then
                LogDebug("[GATE] SUPPRESS_ASSAULT_VOICE: " .. tostring(err), CONFIG.DEBUG_LOG)
            end
        end)
        Log("[GATE] Assault announcer voice suppressed (SUPPRESS_ASSAULT_VOICE)")
    end


    -- ============================================================
    -- CheckForAssaultRestrictedHours(bool& Allowed) - the night-window gate.
    -- ENDLESS MODE: force Allowed = true so assaults can start at any hour.
    --
    -- This is what makes endless mode work without us starting assaults:
    --   * the director already polls IsTodayAssaultDay every ~15s
    --   * our hooks above answer true whenever nothing is running or pending
    --   * so the native start path fires on its own ~15s after an assault ends
    --     and picks up our assault in SortAssaultSpawnLists
    --   * this hours check was the only thing blocking that during the day
    --
    -- It REPLACED a 90s ServerForceBeginAssault() loop, which was bad twice over:
    --   * it ran inside a Utils.QueueSpawn, which drains inside the director's
    --     own ProcessSpawns_Quick hook - re-entering ProcessEvent on the very
    --     object, mid-frame, unattended, every 90 seconds
    --   * it raced the native poll for the same start (what EndlessAssaultPending
    --     was refereeing)
    --
    -- NOTE: `Allowed` is an OUT-PARAM, not a return value, so this MUST be a
    -- POST-hook that writes it. A pre-hook returning true does nothing.
    -- ============================================================
    if (CONFIG.ASSAULTS_PER_WEEK or 1) >= 8 then
        hook = "/Game/Blueprints/Environment/Systems/Abiotic_AIDirector.Abiotic_AIDirector_C:CheckForAssaultRestrictedHours"
        RegisterHook(hook, function() end, function(self, allowed)
            local ok, err = pcall(function() allowed:set(true) end)
            if not ok then
                Utils.LogBad("[GATE] CheckForAssaultRestrictedHours: could not set Allowed: " .. tostring(err))
            end
        end)
    end


    -- ============================================================
    -- ASSAULT-ABORT TRACE (the "warning message, then it's over, zero NPCs" case)
    --
    -- BeginAssault has a silent bail-out that produces exactly that:
    --
    --     HasValidAssaultPatrolLocation()   -- Assault_PatrolTargetLocation != (0,0,0)
    --       false -> SpawnPowerLeechCheck() -> Assault_CurrentPhase = 6
    --
    -- Why it leaves no trace:
    --   * phase 6 is written DIRECTLY, not via ChangeAssaultPhase, so our phase
    --     hook never fires
    --   * SortAssaultSpawnLists is only reached on the SUCCESS branch, so the
    --     wave lists are never even consulted
    -- From the outside it is indistinguishable from an assault whose lists came
    -- out empty. The tell is the couple of power leeches on the base's batteries.
    --
    -- Four ways the patrol location ends up (0,0,0):
    --   1. spawn method 0 - OnAssaultEQSResult only broadcasts for it and NEVER
    --      assigns the location, so a method-0 row aborts 100% of the time
    --   2. PatrolTargetRequiresUpdate false -> returns without querying
    --   3. the bench target's level isn't streamed -> "Bench Target isn't loaded"
    --   4. EQ_FindAssaultSpawn came back empty or missed the native 1s window
    --
    -- The BeginAssault hook below now backstops all four. These probes stay so
    -- the log still says when the backstop had to step in.
    --
    -- Read-only property reads, no asset loads, fires only at assault setup.
    -- ============================================================
    local function vecStr(v)
        if not v then return "nil" end
        local ok, s = pcall(function()
            return string.format("%.0f,%.0f,%.0f", v.X or 0, v.Y or 0, v.Z or 0)
        end)
        return ok and s or "?"
    end

    local function patrolIsSet(director)
        local set = false
        pcall(function()
            local p = director.Assault_PatrolTargetLocation
            set = p and not (p.X == 0 and p.Y == 0 and p.Z == 0)
        end)
        return set
    end

    -- Register a probe without letting a bad function name take the rest of
    -- HOOKS.Register() down with it, and say out loud whether it took - a silent
    -- probe is indistinguishable from a probe that never fires.
    --
    -- PRE-hooks only:
    --   * these started as POST-hooks and every one stayed silent through two
    --     complete assaults (2026-08-04) while every pre-hook fired
    --   * a pre probe reads state as of CALL time, not completion; the 15s
    --     AssaultTick watch picks up whatever the body then changed
    local DIRECTOR = "/Game/Blueprints/Environment/Systems/Abiotic_AIDirector.Abiotic_AIDirector_C:"

    local function traceHook(fnName, probeFn)
        local ok, err = pcall(RegisterHook, DIRECTOR .. fnName, probeFn)
        if ok then
            LogDebug("[ASSAULT-TRACE] probe armed: " .. fnName, CONFIG.DEBUG_LOG)
        else
            Utils.LogBad("[ASSAULT-TRACE] could NOT hook " .. fnName .. ": " .. tostring(err))
        end
    end

    -- ============================================================
    -- THE PATROL-LOCATION BACKSTOP - what stops an assault dying for free.
    --
    -- BeginAssault, for any spawn method except 1, runs:
    --     TryUpdateAssaultPatrolLocation()  (async EQS)
    --     Delay(1s)
    --     HasValidAssaultPatrolLocation() -> false = kill the assault
    --
    -- That 1s is the whole window, and the EQS can miss it, come back empty, or
    -- (method 0) never assign anything at all. So we take two shots inside the
    -- window: if the patrol point is still (0,0,0), write a real navmesh point
    -- beside the target bench and the assault proceeds normally.
    --
    -- Two attempts because the EQS callback can land BETWEEN them and re-zero
    -- the location when it returns no results. Both are pure property work on
    -- the game thread - nothing loads, nothing spawns.
    -- ============================================================
    hook = DIRECTOR .. "BeginAssault"
    local okBegin, errBegin = pcall(RegisterHook, hook, function(self)
        -- Re-resolve the director inside each delayed pass rather than capturing
        -- this hook's wrapper: a UE4SS wrapper is per-hook and shouldn't be held
        -- across frames.
        for _, at in ipairs({ 600, 850 }) do
            Utils.DelayedGameThread(at, function()
                local d = FindFirstOf("Abiotic_AIDirector_C")
                if not d or IsNotValid(d) then return end
                Utils.EnsureAssaultPatrolLocation(d)
            end)
        end
    end)
    if okBegin then
        LogDebug("[ASSAULT-TRACE] patrol backstop armed (BeginAssault)", CONFIG.DEBUG_LOG)
    else
        Utils.LogBad("[GATE] could NOT hook BeginAssault - assaults can still abort " ..
                     "on a missing patrol location: " .. tostring(errBegin))
    end

    -- THE ABORT SENTINEL. SpawnPowerLeechCheck has exactly one call site in the
    -- entire director: the failure branch of BeginAssault, one instruction before
    -- Assault_CurrentPhase = 6. If this fires the assault just died - no waves,
    -- no NPCs, and no other trace anywhere.
    traceHook("SpawnPowerLeechCheck", function(self)
        local ok, err = pcall(function()
            local director = self:get()
            if IsNotValid(director) then return end

            local method = "?"
            pcall(function()
                method = tostring(director.Assault_CurrentData.AssaultSpawnMethod_40_45A45EFC4865CA0BEF4407AAB1065DCA)
            end)

            local bench = director.TargetAssaultBench
            Utils.LogBad(string.format(
                "[ASSAULT-TRACE] *** ASSAULT ABORTED *** BeginAssault found no patrol location, " ..
                "so it spawned power leeches and jumped to phase 6. " ..
                "patrol=%s method=%s bench=%s benchLoc=%s requiresUpdate=%s eqsLocations=%d row=%s",
                vecStr(director.Assault_PatrolTargetLocation),
                method,
                tostring(IsValid(bench)),
                vecStr(director.Assault_BenchTargetLocation),
                tostring(director.PatrolTargetRequiresUpdate),
                (director.Assault_CurrentTargetLocation and director.Assault_CurrentTargetLocation:GetArrayNum()) or -1,
                tostring(Utils.FNameToString(director.Assault_CurrentRow))))
            Utils.LogBad("[ASSAULT-TRACE] the backstop should have prevented this - if benchLoc is " ..
                         "(0,0,0) the director never found a base; otherwise try " ..
                         "SUPPRESS_PORTAL_STORMS = false in CONFIG.lua")
        end)
        if not ok then Utils.LogBad("[ASSAULT-TRACE] abort probe: " .. tostring(err)) end
    end)

    -- WHICH MESSAGE DID THE PLAYER ACTUALLY SEE? Assault_WarnPlayers has three
    -- call sites, each passing a distinct flag combination, so the args name the
    -- branch that fired:
    --   (Active=F, Morning=T, End=F) - daytime "assault tonight" warning
    --   (Active=F, Morning=F, End=F) - BeginAssault succeeded, assault is ON
    --   (Active=F, Morning=F, End=T) - HasValidAssaultLocation() was FALSE, the
    --       director gave up. THIS is the "warning... then it's already over" pair.
    traceHook("Assault_WarnPlayers", function(self, active, morning, ending)
        local ok, err = pcall(function()
            local a = active  and active:get()
            local m = morning and morning:get()
            local e = ending  and ending:get()

            local what = e and "ASSAULT-END message (no valid assault location)"
                       or m and "morning warning (assault scheduled tonight)"
                       or "assault STARTING"
            Log(string.format("[ASSAULT-TRACE] Assault_WarnPlayers: %s  [active=%s morning=%s end=%s]",
                what, tostring(a), tostring(m), tostring(e)))
        end)
        if not ok then Utils.LogBad("[ASSAULT-TRACE] warn probe: " .. tostring(err)) end
    end)

    traceHook("TryUpdateAssaultLocation", function(self)
        local ok, err = pcall(function()
            local director = self:get()
            if IsNotValid(director) then return end
            Log(string.format(
                "[ASSAULT-TRACE] TryUpdateAssaultLocation: benchLoc=%s bench=%s locations=%d",
                vecStr(director.Assault_BenchTargetLocation),
                tostring(IsValid(director.TargetAssaultBench)),
                (director.Assault_CurrentTargetLocation and director.Assault_CurrentTargetLocation:GetArrayNum()) or -1))
        end)
        if not ok then Utils.LogBad("[ASSAULT-TRACE] location probe: " .. tostring(err)) end
    end)

    -- AssaultTick calls TryUpdateAssaultPatrolLocation once a second while an
    -- assault is live, so only speak when the answer CHANGES.
    local lastPatrolTrace = nil

    traceHook("TryUpdateAssaultPatrolLocation", function(self)
        local ok, err = pcall(function()
            local director = self:get()
            if IsNotValid(director) then return end

            local bench = director.TargetAssaultBench
            local msg = string.format(
                "[ASSAULT-TRACE] TryUpdateAssaultPatrolLocation: requiresUpdate=%s bench=%s benchLoc=%s patrolSet=%s",
                tostring(director.PatrolTargetRequiresUpdate),
                tostring(IsValid(bench)),
                vecStr(director.Assault_BenchTargetLocation),
                tostring(patrolIsSet(director)))

            if msg ~= lastPatrolTrace then
                lastPatrolTrace = msg
                Log(msg)
            end
        end)
        if not ok then LogDebug("[ASSAULT-TRACE] patrol probe: " .. tostring(err), CONFIG.DEBUG_LOG) end
    end)

    -- ============================================================
    -- ASSAULT WATCH - ground truth that needs no faith in per-function probes.
    --
    -- AIDirector_AssaultTick is the director's 15s looping timer delegate: it
    -- runs rain or shine and demonstrably fires as a PRE-hook on this build, so
    -- whatever the individual probes miss, this snapshot catches 15s later.
    -- Snapshots the whole assault state machine; logs only on change.
    --
    -- Reading a dead assault in these lines:
    --   * phase 0->1 with patrol=(0,0,0) that never becomes non-zero, then
    --     phase 1->6 with toSpawn=0  =  BeginAssault's patrol-location abort
    --   * compare `method` on a failing vs a working run - it says whether the
    --     row's spawn method is one that actually assigns a patrol point
    -- ============================================================
    local lastWatch = nil
    traceHook("AIDirector_AssaultTick", function(self)
        local ok, err = pcall(function()
            local d = self:get()
            if IsNotValid(d) then return end

            local method = "?"
            pcall(function()
                method = tostring(d.Assault_CurrentData.AssaultSpawnMethod_40_45A45EFC4865CA0BEF4407AAB1065DCA)
            end)
            local locs, alive = -1, -1
            pcall(function() locs  = d.Assault_CurrentTargetLocation:GetArrayNum() end)
            pcall(function() alive = d.AssaultNPCs:GetArrayNum() end)

            local snap = string.format(
                "[ASSAULT-WATCH] phase=%s row=%s method=%s portals=%s bench=%s benchLoc=%s patrol=%s eqsLocs=%d toSpawn=%s alive=%d",
                tostring(d.Assault_CurrentPhase),
                tostring(Utils.FNameToString(d.Assault_CurrentRow)),
                method,
                tostring(d.CurrentAssaultPortals),
                tostring(IsValid(d.TargetAssaultBench)),
                vecStr(d.Assault_BenchTargetLocation),
                vecStr(d.Assault_PatrolTargetLocation),
                locs,
                tostring(d.TotalNPCsToSpawn),
                alive)

            if snap ~= lastWatch then
                lastWatch = snap
                Log(snap)
            end
        end)
        if not ok then Utils.LogBad("[ASSAULT-WATCH] " .. tostring(err)) end
    end)

    traceHook("OnAssaultEQSResult", function(self)
        local ok, err = pcall(function()
            local director = self:get()
            if IsNotValid(director) then return end

            local method, locs = "?", -1
            pcall(function()
                method = tostring(director.Assault_CurrentData.AssaultSpawnMethod_40_45A45EFC4865CA0BEF4407AAB1065DCA)
                locs   = director.Assault_CurrentTargetLocation:GetArrayNum() or -1
            end)

            -- PRE-hook: patrolSet reflects the state BEFORE this callback runs -
            -- the body is what assigns the patrol point (methods 2/3 only). So
            -- this line firing at all says the EQS query returned; whether the
            -- patrol point actually got set shows up in the next [ASSAULT-WATCH].
            Log(string.format(
                "[ASSAULT-TRACE] OnAssaultEQSResult: spawnMethod=%s eqsLocations=%d patrolSetBefore=%s (%s)",
                method, locs, tostring(patrolIsSet(director)),
                vecStr(director.Assault_PatrolTargetLocation)))
        end)
        if not ok then LogDebug("[ASSAULT-TRACE] EQS probe: " .. tostring(err), CONFIG.DEBUG_LOG) end
    end)


    -- ============================================================
    -- ActiveAssaultTick
    -- Fires every tick during an active assault; throttled to ~3 s.
    -- ============================================================
    hook = "/Game/Blueprints/Environment/Systems/Abiotic_AIDirector.Abiotic_AIDirector_C:ActiveAssaultTick"
    RegisterHook(hook, function(self)
        if STATE.SECONDS_TICK % 3 ~= 0 then return end

        local ok, err = pcall(function()
            local director = self:get()
            if IsNotValid(director) then return end
            if not director:IsAssaultHappening() then return end
            AM.OnAssaultTick(director)
        end)
        if not ok then
            Utils.LogBad("[GATE] ActiveAssaultTick - error: " .. tostring(err))
        end
    end)

    -- ============================================================
    -- OnRep_LastKnownHour - fires every in-game hour.
    -- * Reapply weather at 6am if there's an assault with an active weather event
    -- ============================================================
    hook = "/Game/Blueprints/Environment/Systems/DayNightManager.DayNightManager_C:OnRep_LastKnownHour"
    RegisterHook(hook, function(self)
        if not STATE.ActiveAssaultWeather then return end
        if not Utils.IsAssaultHappening() then return end

        local ok, err = pcall(function()
            
            local dayNight = AFUtils.GetDayNightManager()
            if not dayNight or IsNotValid(dayNight) then return end

            local t = dayNight.CurrentTimeInSeconds

            -- 6am: 21600 seconds. Some buffer
            if t > 20000 and t < 23000 then
                Utils.DelayedGameThread(1000, function()
                    if not STATE.ActiveAssaultWeather then return end
                    AFUtils.TriggerWeatherEvent(STATE.ActiveAssaultWeather)
                end)
            end
            
        end)
        if not ok then
            Utils.LogBad("[GATE-HOOK] OnRep_LastKnownHour weather reapply error: " .. tostring(err))
        end
    end)


    -- ============================================================
    -- ChangeAssaultPhase
    -- * Triggers each time during an assault the director advances to the next wave.
    -- * There's a vague period before assaults start where the director may 
    --     try shuffling assault name, and Endless was firing off assaults during assaults 
    -- ============================================================
    local PHASE_NAMES = { [0]="None", [2]="Wave 1", [3]="Wave 2", [4]="Wave 3", [5]="Boss Wave", [6]="End" }

    hook = "/Game/Blueprints/Environment/Systems/Abiotic_AIDirector.Abiotic_AIDirector_C:ChangeAssaultPhase"
    RegisterHook(hook, function(self, newPhase)
        local ok, err = pcall(function()
            
            local phase = newPhase:get()
            local name = PHASE_NAMES[phase] or ("Phase " .. tostring(phase))
            
            LogDebug("[ASSAULT] " .. STATE.SECONDS_TICK .. " - Assault " .. name, CONFIG.DEBUG_LOG)

            -- Commit the pending assault when Wave 1 fires.
            -- * Sometimes the assault gets shuffled so we want the actual assault happening
            -- * Endless Assaults - setting this to false at the beginning of the assault leads to some looping
            if phase == 2 then
                if STATE.RecentAssaults_Pending then
                    AM.TrackAssault(STATE.RecentAssaults_Pending.row, STATE.RecentAssaults_Pending.idx)
                    STATE.RecentAssaults_Pending = nil
                end
                
                STATE.EndlessAssaultPending = false
            end

            -- Redundancy: Reenable scarecrows on assault end
            if phase == 6 then
                -- STATE.DisableScarecrows = false
                STATE.ActiveAssaultWeather = nil
                STATE.EndlessAssaultPending = false  -- just in case

                -- Drop the AnteUp variant plan so a stale one can't claim
                -- slots for whatever spawns next (Managers/AnteBridge.lua)
                AB.ClearPlan()
            end
        end)
        if not ok then Utils.LogBad("[ASSAULT] ChangeAssaultPhase() - err " .. tostring(err)) end
    end)


    -- ============================================================
    -- NPC_Base_ParentBP:ReceiveBeginPlay()
    -- * Called whenever any NPC is created.
    -- ============================================================
    hook = "/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C:ReceiveBeginPlay"
    RegisterHook(hook, function(self)
        local npc = self:get()
        if Utils.IsActorInvalid(npc) then return end

        local name = Utils.GetActorName(npc)
        if name == "Containment Robot" then
            npc.GrabCooldown             = 999999
            npc.TimeOfLastGrabAttempt    = 999999
            npc.TimeOfLastSuccessfulGrab = 999999
            LogDebug("[GATE] Containment Robot grab disabled at spawn", CONFIG.DEBUG_LOG)
        end

    end)


end

return HOOKS
