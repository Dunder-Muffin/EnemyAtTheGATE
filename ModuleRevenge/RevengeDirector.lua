-- =======================================================================
-- RevengeDirector [AUTHORITY] - the CALENDAR and the director plumbing behind ModuleRevenge.
-- Roster in ModuleRevenge/RevengeAssaults.lua, OnStart primitives in ModuleRevenge/RevengeEvents.lua.
--
-- WHAT IT DOES, in one line each:
--   SCAN      every 10s beat, any revenge whose Trigger has just gone false->true books a night.
--   SCHEDULE  max( today (+1 past NIGHT_CUTOFF_HOUR) + def.Delay , lastBookedDay + def.Delay ).
--   PERSIST   STATE.StoryData.RevengeCalendar, so the calendar survives a logout.
--   FIRE      on the scheduled night, force the native assault and fill in its waves.
--
-- MUST-KNOWS (full reasoning: AnNotes/Modules/RevengeDirector.md)
--   * Scan is EDGE-triggered against a persisted `Seen`/`Seeded` baseline, not "is it true now" -
--     WorldFlagsChanged never fires on save-load, so a condition scan would book the whole roster
--     the instant a late-game save loads.
--   * `StoryMax` is a second line of defence only; some triggers have no story mapping to cap.
--   * We FORCE the assault start (ServerForceBeginAssault) rather than hook the day gate, to avoid
--     two mods' pre-hooks fighting over one value-returning UFunction.
--   * SortAssaultSpawnLists is shared with EATG (order unpredictable) - GateBridge's published
--     calendar is what tells EATG to stand down on a claimed night.
--   * Commit = "waves applied to the director", not "assault survived" - an engine-side abort after
--     that still spends the night rather than retrying forever.
--   * Two things keep a backlog from draining all at once: a night is spent as soon as one revenge
--     commits, and nothing starts while the director's phase is non-zero. `IsAssaultHappening()`
--     is not that second test - see assaultInFlight().
--   * We only overwrite the director's own warning/start text; never send our own broadcast on top
--     (tried once, produced duplicate messages).
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local Utils = require("AnteUtils.Utils")
local SCHEMA = require("AnteData.Schema")
local FileIO = require("AnteCore.FileIO")
local VARIANTS = require("AnteVariants.Variants")
local ASSAULTS = require("ModuleRevenge.RevengeAssaults")

local Log = Utils.Log
local LogBad = Utils.LogBad
local LogDebug = Utils.LogDebug

local RD = {}


-- =======================================================================
-- KNOBS
-- =======================================================================

-- Schedule for tomorrow night once the clock passes this hour. Prevents a sudden event
local NIGHT_CUTOFF_HOUR = 18

-- The window a revenge may start in. Outside it we simply wait; the entry stays on the calendar.
--   * We bypass the director's own CheckForAssaultRestrictedHours by forcing the start, so this
--     is the ONLY thing keeping a revenge from kicking off at nine in the morning.
local FIRE_HOUR_START = 22    -- 10pm
local FIRE_HOUR_END   = 2     -- 2am

-- (Spacing between stacked revenges is each def's own `Delay` - see schedule(). There is no
-- global gap knob: a revenge that wants different spacing than its trigger delay sets `Gap`.)

-- Cap on how many revenges may sit on the calendar at once. The backlog is re-scanned every beat,
-- so a capped entry is not lost - it just waits for a slot.
--   * This is what stops a mod installed on a FINISHED save from booking two solid weeks of
--     nightly assaults the moment it loads.
local CATCHUP_MAX = 5

-- A player must be within this of a Crafting Bench for a revenge to fire. No base = nothing to
-- assault; the director would pick no bench and abort anyway.
local BENCH_RADIUS = 5000

-- How long a forced start has to reach SortAssaultSpawnLists before we assume it did not take and
-- allow a retry. Generously past the director's own 15s poll.
local PENDING_TIMEOUT_MS = 60000

-- Attempts per night before giving up until tomorrow.
local MAX_ATTEMPTS_PER_NIGHT = 3


-- =======================================================================
-- STATE
-- =======================================================================

local armed = false
local pending = nil          -- { def = <def>, day = n } handed from Tick to the hook
local pendingAt = 0          -- FAST_TICK when `pending` was set
local attemptsToday = 0
local attemptsDay = -1

-- Id -> def, built AT LOAD, not in Register. RD.Tick is driven by StoryManager and there is no
-- ordering guarantee that Register ran first; an empty byId would send every due entry down the
-- "not in the roster" branch, which PERMANENTLY marks it fired. Register only re-checks and logs.
local byId = {}
for _, def in ipairs(ASSAULTS) do
    if def.Id and not byId[def.Id] then byId[def.Id] = def end
end


local function cal()
    STATE.StoryData.RevengeCalendar = STATE.StoryData.RevengeCalendar or {}
    local c = STATE.StoryData.RevengeCalendar
    c.Scheduled = c.Scheduled or {}
    c.Fired = c.Fired or {}
    return c
end


-- =======================================================================
-- Wave resolution - a wave list may name an Antevariant, a raw DT_NPCList row, or "Variant@Row".
-- Returns  bases    (what the director actually spawns)
--          variants (index-aligned; a variant name, or "-" for "leave it vanilla")
-- Mirrors EATG's AnteBridge.ResolveWave so a wave list ports between the mods unchanged.
-- =======================================================================
local function resolveWave(list, label)
    local bases, variants = {}, {}
    for i = 1, #(list or {}) do
        local entry = tostring(list[i])
        local name, bodyOverride = string.match(entry, "^(.-)@(.+)$")
        if not name then name = entry end

        local def = VARIANTS[name]
        if def and def.Base then
            bases[i]    = bodyOverride or def.Base
            variants[i] = name
        else
            bases[i]    = bodyOverride or entry
            variants[i] = "-"
            -- Every DT_NPCList row is one word ("Pest_Carbonated"), so a SPACE means this was
            -- meant to be a variant name. Unresolved it spawns NOTHING, which reads as "the wave
            -- was small" rather than "the name is wrong".
            if string.find(name, " ", 1, true) then
                LogBad(string.format("Revenge - %s: \"%s\" is not a registered variant; " ..
                    "that slot will spawn NOTHING", label or "wave", name))
            end
        end
    end
    return bases, variants
end

-- Write a Lua list of names into a director TArray<FName>. Grow by index-append, then ForEach-set.
local function setFNameArray(tarray, names)
    -- Native: the elements are FNPCRowHandle structs. An FName written over one is an AV inside
    -- UE4SS's struct converter, so append whole handles instead.
    if SCHEMA.Native then
        for _, n in ipairs(names) do SCHEMA.AppendNameProp(tarray, n) end
        return
    end
    for _ = 1, #names do tarray[#tarray + 1] = FName("None") end
    local i = 1
    tarray:ForEach(function(_, elem)
        if i > #names then return end
        elem:set(FName(names[i]))
        i = i + 1
    end)
end


-- =======================================================================
-- Applying a revenge onto the director (called from the SortAssaultSpawnLists hook).
-- =======================================================================

local A = SCHEMA.Assault
local WAVES = {
    { key = "Wave1",    slot = 1, array = "Assault_NPCList_Wave1",
      time = "Wave1Time",    rate = A.SpawnRate_Wave1 },
    { key = "Wave2",    slot = 2, array = "Assault_NPCList_Wave2",
      time = "Wave2Time",    rate = A.SpawnRate_Wave2 },
    { key = "Wave3",    slot = 3, array = "Assault_NPCList_Wave3",
      time = "Wave3Time",    rate = A.SpawnRate_Wave3 },
    { key = "BossWave", slot = 4, array = "Assault_NPCList_BossWave",
      time = "BossWaveTime", rate = A.SpawnRate_BossWave },
}

local F_WARN_TEXT = A.AssaultWarningText
local F_START_TEXT = A.AssaultStartedText
local F_PREP_TIME = A.AssaultPrepTime

local function applyToDirector(director, def)
    -- Resolve everything into locals before writing anything to the director. A throw mid-write
    -- would otherwise leave the four wave arrays empty with no error (see AnNotes/Modules/RevengeDirector.md).
    local resolved, waveVariants = {}, {}
    for _, w in ipairs(WAVES) do
        if def[w.key] then
            local ok, bases, variants = pcall(resolveWave, def[w.key], w.key)
            if not ok then
                LogBad(string.format("Revenge - %s: %s failed to resolve, keeping the NATIVE " ..
                    "assault: %s", def.Id, w.key, tostring(bases)))
                return false
            end
            waveVariants[w.slot] = variants
            resolved[#resolved + 1] = { array = w.array, bases = bases }
        end
    end
    if #resolved == 0 then
        LogBad("Revenge - " .. def.Id .. " defines no waves; keeping the native assault")
        return false
    end

    -- Past here nothing can throw, so empty-then-fill is safe.
    director.Assault_NPCList_Wave1:Empty()
    director.Assault_NPCList_Wave2:Empty()
    director.Assault_NPCList_Wave3:Empty()
    director.Assault_NPCList_BossWave:Empty()

    local written = 0
    for _, r in ipairs(resolved) do
        setFNameArray(director[r.array], r.bases)
        written = written + #r.bases
    end

    -- Verify rather than assume: setFNameArray depends on UE4SS honouring index-append growth. If
    -- a build stops honouring it every array comes back empty and the assault silently evaporates.
    local landed = 0
    pcall(function()
        landed = (director.Assault_NPCList_Wave1:GetArrayNum() or 0)
               + (director.Assault_NPCList_Wave2:GetArrayNum() or 0)
               + (director.Assault_NPCList_Wave3:GetArrayNum() or 0)
               + (director.Assault_NPCList_BossWave:GetArrayNum() or 0)
    end)
    if landed < written then
        LogBad(string.format("Revenge - %s wrote %d NPC rows but the director only has %d; " ..
            "this assault will spawn short or not at all", def.Id, written, landed))
    end

    -- Hand the variant plan to GateBridge IN-PROCESS, so its existing BeginPlay slot-matcher
    -- mutates our bodies exactly as it does EATG's. No round-trip through the shared channel.
    require("ModuleGATE.GateBridge").SetLocalPlan(waveVariants)

    -- Assault_CurrentData can be nil on a forced start (the director lazy-loads it). The wave
    -- lists above are the part that matters, so a miss here is a downgrade, not a failure.
    local data = director.Assault_CurrentData
    if data and IsValid(data) then
        for _, w in ipairs(WAVES) do
            if def[w.time] then pcall(function() data[w.rate] = def[w.time] end) end
        end
        if def.PrepTime then pcall(function() data[F_PREP_TIME] = def.PrepTime end) end

        -- Only place a revenge's messages are set. The director shows them itself on its own
        -- cadence; only written when the def supplies one, else the row's native text stands.
        if def.WarningMessage then pcall(function() data[F_WARN_TEXT] = FText(def.WarningMessage) end) end
        if def.StartMessage then pcall(function() data[F_START_TEXT] = FText(def.StartMessage) end) end
    end

    STATE.RevengePrepMs = (def.PrepTime or 20) * 1000

    Log(string.format("Revenge - %s applied: %d NPC rows across %d waves", def.Id, landed, #resolved))
    return true
end


-- =======================================================================
-- Scheduling
-- =======================================================================

local function isScheduled(c, id)
    for _, e in ipairs(c.Scheduled) do
        if e.Id == id then return true end
    end
    return false
end

local function latestScheduledDay(c)
    local latest
    for _, e in ipairs(c.Scheduled) do
        if not latest or e.Day > latest then latest = e.Day end
    end
    return latest
end

-- Is this def's trigger satisfied right now?
local function triggerMet(def, flags, story)
    local t = def.Trigger or {}
    if t.Flag then return (flags and flags[t.Flag]) == true end
    if t.MinStory then return (story or 0) >= t.MinStory end
    return false
end

-- Book `def` onto the calendar. Returns the day it landed on.
-- Lands on the LATER of "today + Delay" and "last booked night + Delay", so a burst of triggers
-- spreads out instead of stacking on one night (see AnNotes/Modules/RevengeDirector.md for a worked example).
-- `def.Gap` overrides only the stacking half; unset it defaults to `Delay`.
local function schedule(c, def, day, hour)
    local delay = def.Delay or 1
    local when = day + ((hour >= NIGHT_CUTOFF_HOUR) and 1 or 0) + delay

    local latest = latestScheduledDay(c)
    if latest then
        local stacked = latest + (def.Gap or delay)
        if stacked > when then when = stacked end
    end

    table.insert(c.Scheduled, { Id = def.Id, Day = when })
    Log(string.format("Revenge SCHEDULED - %s on day %d (today %d, %02d:00)",
        def.Id, when, day, hour))
    return when
end

-- One scan pass. Edge-triggered: a revenge books on its trigger's false->true transition, judged
-- against the persisted `Seen` baseline (see AnNotes/Modules/RevengeDirector.md for why).
-- The first scan of a world takes the baseline and books nothing (`Seeded`); only later flips book.
-- `flags == nil` means the WorldFlagSubsystem isn't readable yet - bail without seeding, or the
-- baseline would be taken empty and everything would read as newly flipped next tick.
local function scan(c, flags, story, day, hour)
    if not flags then return false end
    if not Utils.AnyPlayer() then return false end

    c.Seen = c.Seen or {}
    local changed = false
    local seeding = not c.Seeded

    for _, def in ipairs(ASSAULTS) do
        if triggerMet(def, flags, story) and not c.Seen[def.Id] then
            c.Seen[def.Id] = true
            changed = true

            -- On the baseline pass this is all we do: record it and move on.
            if not seeding
                and not c.Fired[def.Id]
                and not isScheduled(c, def.Id)
                and not (def.StoryMax and story > def.StoryMax)
                and #c.Scheduled < CATCHUP_MAX
            then
                schedule(c, def, day, hour)
            end
        end
    end

    if seeding then
        c.Seeded = true
        changed = true
        local n = 0
        for _ in pairs(c.Seen) do n = n + 1 end
        Log(string.format("Revenge - baseline taken for this world: %d trigger(s) already " ..
            "satisfied and absorbed (story %d). Only NEW flips book from here.", n, story))
    end

    return changed
end


-- =======================================================================
-- Firing
-- =======================================================================

local function inFireWindow(hour)
    if FIRE_HOUR_START <= FIRE_HOUR_END then
        return hour >= FIRE_HOUR_START and hour < FIRE_HOUR_END
    end
    return hour >= FIRE_HOUR_START or hour < FIRE_HOUR_END   -- wraps midnight
end

-- Is any player near a Crafting Bench? Without one the director has nothing to target.
local function anyBase()
    local ENUMS = require("AnteData.Enums")
    local AVU = require("AnteUtils.AVUtils")
    for _, p in ipairs(Utils.LivePlayers()) do
        local ok, loc = pcall(function() return p:K2_GetActorLocation() end)
        if ok and loc then
            local hits = AVU.GetNearbyActorsOfClass(loc, BENCH_RADIUS, ENUMS.DeployedObjs.CRAFTING_BENCH) or {}
            if #hits > 0 then return true end
        end
    end
    return false
end

-- Is an assault already in flight - ours, EATG's, or the game's own?
-- `Assault_CurrentPhase` is the only honest answer: 0 is idle, 1 is the prep/warning window and
-- 2-6 are the waves through the end. `IsAssaultHappening()` looks like this test but is NOT -
-- it answers FALSE for phase 1, and prep is minutes long, so it leaves the whole run-up open for
-- a second start to land on top and overwrite the wave lists.
local function assaultInFlight(director)
    local phase
    pcall(function() phase = director.Assault_CurrentPhase end)
    phase = tonumber(phase)
    if phase then return phase ~= 0 end

    local happening = false                 -- phase unreadable: fall back to the coarse test
    pcall(function() happening = director:IsAssaultHappening() end)
    return happening
end

-- Hand `def` to the hook and force the director to start. The hook does the real work.
local function fire(def, day)
    local director = Utils.GetAIDirectorActor()
    if not director or IsNotValid(director) then return false end
    if assaultInFlight(director) then return false end

    pending   = { def = def, day = day }
    pendingAt = STATE.FAST_TICK or 0

    -- No message sent here - the director shows its own warning/start banners off
    -- Assault_CurrentData, which applyToDirector already wrote.

    -- One call on a clean game-thread flush point, NOT from the WorkQueue drain: that runs inside
    -- ProcessTick / ProcessSpawns_Quick, and starting an assault from there re-enters ProcessEvent
    -- on the director mid-frame.
    Utils.DelayedGameThread(0, function()
        local d = Utils.GetAIDirectorActor()
        if not d or IsNotValid(d) then return end
        Log("Revenge - forcing assault start for " .. def.Id)
        -- Load the revenge's shell row first, on BOTH builds (forced, so its world flags don't gate
        -- it). A forced start never picks a row, and BeginAssault branches on the row's spawn method
        -- and shows its warning text BEFORE SortAssaultSpawnLists, where the hook applies ours. An
        -- idle director holds the class default (method 0, no text): a chime with no message, no
        -- patrol location, then phase 6.
        local out = {}
        local okSel, errSel = pcall(function() d:SelectNewAssaultType(FName(def.Row), true, out) end)
        if not okSel then LogBad("Revenge - SelectNewAssaultType threw: " .. tostring(errSel)) end
        Log("Revenge - shell row " .. tostring(def.Row) .. " selected (FoundValidRow="
            .. tostring(out.FoundValidRow) .. ")")
        local ok, err = pcall(function() d:ServerForceBeginAssault() end)
        if not ok then LogBad("Revenge - ServerForceBeginAssault threw: " .. tostring(err)) end
    end)

    -- Say where a forced start stalls on its way to SortAssaultSpawnLists, the hook that applies ours:
    --   * FoundPlayerBases - the async base search finished (true even when it found none).
    --   * bench  - a base was picked to assault; false = no bench the director counts (the start ends).
    --   * patrol - the EQS found a spawn point; false with a bench = nowhere to spawn from (phase 6).
    -- `row` is Assault_CurrentRow, which only the native build fills; legacy reads nil regardless.
    for _, ms in ipairs({ 1000, 4000, 10000 }) do
        Utils.QueueWork(function()
            if not pending or pending.def ~= def then return end
            local d = Utils.GetAIDirectorActor()
            if not d or IsNotValid(d) then return end
            local bases, phase, row, bench, patrol
            pcall(function() bases = d.FoundPlayerBases end)
            pcall(function() phase = d.Assault_CurrentPhase end)
            pcall(function() row = SCHEMA.RowOfNameProp(d.Assault_CurrentRow) end)
            pcall(function() bench = IsValid(d.TargetAssaultBench) end)
            pcall(function()
                local p = d.Assault_PatrolTargetLocation
                patrol = (p.X ~= 0 or p.Y ~= 0 or p.Z ~= 0)
            end)
            Log(string.format("Revenge - %s not applied after %.0fs: FoundPlayerBases=%s bench=%s patrol=%s phase=%s row=%s",
                def.Id, ms / 1000, tostring(bases), tostring(bench), tostring(patrol), tostring(phase), tostring(row)))
        end, ms)
    end

    return true
end


-- =======================================================================
-- TICK - called from StoryManager.Tick (the 10s beat), AUTHORITY.
-- =======================================================================
function RD.Tick(story, flags)
    if not SETTINGS.GAMEPLAY.MODULE_REVENGE_ASSAULTS then return end
    if not Utils.IsAuthority() then return end
    if not STATE.StoryData then return end          -- per-world save not loaded yet

    local day = Utils.GetCurrentDay()
    local hour = Utils.GetCurrentHour()
    if not day or not hour then return end

    local c = cal()

    -- SCAN. Cheap: a table walk plus a flag lookup per def.
    if scan(c, flags, story, day, hour) then
        FileIO.SaveStoryData()
        RD.PublishCalendar()
    end

    -- Expire a forced start that never reached the hook, so the night can be retried.
    if pending and (STATE.FAST_TICK or 0) - pendingAt > (PENDING_TIMEOUT_MS / 100) then
        LogDebug("Revenge - forced start for " .. pending.def.Id .. " never landed; releasing",
            SETTINGS.DEBUG_STORY)
        pending = nil
    end
    if pending then return end

    -- FIRE. `>=` not `==`: a night slept through, spent offline, or spent away from base defers
    -- the revenge rather than losing it.
    if not inFireWindow(hour) then return end

    if attemptsDay ~= day then attemptsDay, attemptsToday = day, 0 end
    if attemptsToday >= MAX_ATTEMPTS_PER_NIGHT then return end

    -- ONE REVENGE PER NIGHT. A backlog is normal - entries pile up while the player is away from
    -- a bench - and without this the whole backlog drains at one beat apiece the moment a bench
    -- comes into range. `Fired` is stamped at COMMIT and persisted, so a night stays spent across
    -- a reload, while a forced start that never committed still gets its MAX_ATTEMPTS retries.
    for _, d in pairs(c.Fired) do
        if d == day then return end
    end

    for _, e in ipairs(c.Scheduled) do
        if day >= e.Day then
            local def = byId[e.Id]
            if not def then
                -- The roster no longer has this Id (renamed or removed). Drop it rather than
                -- retrying a ghost every beat.
                LogBad("Revenge - scheduled '" .. tostring(e.Id) .. "' is not in the roster; dropping")
                c.Fired[e.Id] = day
                for i, s in ipairs(c.Scheduled) do
                    if s.Id == e.Id then table.remove(c.Scheduled, i); break end
                end
                FileIO.SaveStoryData()
                RD.PublishCalendar()
                return
            end

            if not anyBase() then
                LogDebug("Revenge - " .. e.Id .. " is due but nobody is near a Crafting Bench",
                    SETTINGS.DEBUG_STORY)
                return
            end

            attemptsToday = attemptsToday + 1
            fire(def, day)
            return                                   -- one revenge per night, always
        end
    end
end


-- =======================================================================
-- The days we have claimed, for EnemyAtTheGATE. Published through GateBridge's transport.
-- =======================================================================
function RD.PublishCalendar()
    if not STATE.StoryData then return end
    local c = cal()

    local set = {}
    for _, e in ipairs(c.Scheduled) do set[e.Day] = true end

    -- Tonight stays claimed after commit: the commit removes the entry from Scheduled, so
    -- publishing Scheduled alone would un-claim the night mid-assault and let EATG start a second
    -- one on top (see AnNotes/Modules/RevengeDirector.md). Only days >= today are republished from Fired.
    local today = Utils.GetCurrentDay()
    if today then
        for _, d in pairs(c.Fired) do
            if type(d) == "number" and d >= today then set[d] = true end
        end
    end

    local days = {}
    for d in pairs(set) do days[#days + 1] = d end
    table.sort(days)
    pcall(function() require("ModuleGATE.GateBridge").PublishCalendar(days) end)
end

-- Is `day` claimed by a revenge? Same answer PublishCalendar gives EATG - booked, or already run
-- today (see the note there). Ours to call locally; EATG asks over the channel.
function RD.IsDayClaimed(day)
    if not day or not STATE.StoryData then return false end
    local c = cal()
    for _, e in ipairs(c.Scheduled) do
        if e.Day == day then return true end
    end
    local today = Utils.GetCurrentDay()
    if today and day >= today then
        for _, d in pairs(c.Fired) do
            if d == day then return true end
        end
    end
    return false
end


-- =======================================================================
-- DEV surface (/au-revenge, ModuleCheats/Cheats.Revenge). AUTHORITY.
-- =======================================================================

-- Roster lookup for a chat argument: exact Id first, then a case-insensitive substring, because
-- these Ids are long to type ("train" finds Revenge_Train).
local function resolveId(id)
    if not id or id == "" then return nil end
    if byId[id] then return byId[id] end
    local want = id:lower()
    for _, d in ipairs(ASSAULTS) do
        if d.Id and d.Id:lower():find(want, 1, true) then return d end
    end
    return nil
end

-- Book a revenge onto the calendar through the real scheduler, ignoring its trigger.
-- Returns ok, <day or reason>. `tonight` books TODAY instead, bypassing Delay and stacking, to
-- exercise the real fire path without rolling the clock over a day boundary. Clears any `Fired`
-- record so a revenge can be re-queued during a test session. Does NOT bypass CATCHUP_MAX.
-- (Stacking-test walkthrough: AnNotes/Modules/RevengeDirector.md.)
function RD.QueueLater(id, tonight)
    if not Utils.IsAuthority() then return false, "authority only" end
    if not SETTINGS.GAMEPLAY.MODULE_REVENGE_ASSAULTS then return false, "GAMEPLAY.MODULE_REVENGE_ASSAULTS is off" end
    if not STATE.StoryData then return false, "per-world save not loaded yet" end

    local day, hour = Utils.GetCurrentDay(), Utils.GetCurrentHour()
    if not day or not hour then return false, "no day clock yet" end

    local def = resolveId(id)
    if not def then return false, "no revenge matching '" .. tostring(id) .. "'" end

    local c = cal()
    if isScheduled(c, def.Id) then return false, def.Id .. " is already booked" end
    if #c.Scheduled >= CATCHUP_MAX then
        return false, string.format("calendar is full (%d booked, CATCHUP_MAX=%d)", #c.Scheduled, CATCHUP_MAX)
    end

    c.Fired[def.Id] = nil
    -- Mark the trigger seen either way: a hand-booked revenge must not ALSO book itself the
    -- moment its flag is noticed for the first time.
    c.Seen = c.Seen or {}
    c.Seen[def.Id] = true

    local when
    if tonight then
        when = day
        table.insert(c.Scheduled, { Id = def.Id, Day = when })
        Log(string.format("Revenge SCHEDULED - %s TONIGHT (day %d, %02d:00) [forced]", def.Id, day, hour))
    else
        when = schedule(c, def, day, hour)
    end

    FileIO.SaveStoryData()
    RD.PublishCalendar()
    return true, when
end

-- The calendar as human-readable lines.
function RD.Describe()
    if not Utils.IsAuthority() then return { "Revenge: authority only" } end
    if not SETTINGS.GAMEPLAY.MODULE_REVENGE_ASSAULTS then return { "Revenge: GAMEPLAY.MODULE_REVENGE_ASSAULTS is off" } end
    if not STATE.StoryData then return { "Revenge: per-world save not loaded yet" } end

    local c = cal()
    local day, hour = Utils.GetCurrentDay(), Utils.GetCurrentHour()

    -- Line 1 answers the two questions the calendar can't: what day is it, and is the firing
    -- window even open right now. A booked-and-DUE revenge that simply isn't 10pm yet looks
    -- identical to a broken one without this.
    local windowState = "?"
    if hour then
        windowState = inFireWindow(hour) and "OPEN" or
            string.format("shut until %02d:00", FIRE_HOUR_START)
    end
    local out = {
        string.format("Revenge - day %s, %s:00 | fire window %02d:00-%02d:00 [%s] | %s",
            tostring(day), tostring(hour), FIRE_HOUR_START, FIRE_HOUR_END, windowState,
            c.Seeded and "baseline taken" or "BASELINE NOT TAKEN YET"),
    }

    if #c.Scheduled == 0 then
        out[#out + 1] = "  booked: (nothing)"
    else
        for _, e in ipairs(c.Scheduled) do
            local when = "?"
            if day then
                local nights = e.Day - day
                when = (nights <= 0) and "DUE TONIGHT"
                    or (nights == 1) and "tomorrow night"
                    or string.format("in %d nights", nights)
            end
            out[#out + 1] = string.format("  booked: %s -> night %d (%s)", e.Id, e.Day, when)
        end
    end

    local fired = {}
    for id, d in pairs(c.Fired) do fired[#fired + 1] = string.format("%s (day %s)", id, tostring(d)) end
    table.sort(fired)
    out[#out + 1] = "  fired: " .. (#fired > 0 and table.concat(fired, ", ") or "(none)")

    -- Everything not booked and not fired, split by WHY - "nothing is booked" should never be a
    -- mystery, and a revenge the run has outgrown must not read as one that is still coming.
    local story = STATE.StoryProgress or 0
    local waiting, retired, absorbed = {}, {}, {}
    for _, def in ipairs(ASSAULTS) do
        if not c.Fired[def.Id] and not isScheduled(c, def.Id) then
            local t = def.Trigger or {}
            if def.StoryMax and story > def.StoryMax then
                retired[#retired + 1] = string.format("%s (max %d)", def.Id, def.StoryMax)
            elseif (c.Seen or {})[def.Id] then
                -- Trigger already satisfied when the baseline was taken, so its edge is gone.
                -- Distinct from "waiting": this one is never coming on its own.
                absorbed[#absorbed + 1] = def.Id
            else
                waiting[#waiting + 1] = def.Id .. " <- " .. (t.Flag or ("story " .. tostring(t.MinStory)))
            end
        end
    end
    out[#out + 1] = "  waiting on trigger: " .. (#waiting > 0 and table.concat(waiting, ", ") or "(none)")
    if #absorbed > 0 then
        out[#out + 1] = "  already tripped before the baseline (use \"later\" to force): " ..
            table.concat(absorbed, ", ")
    end
    if #retired > 0 then
        out[#out + 1] = string.format("  retired (story %d past their StoryMax): %s",
            story, table.concat(retired, ", "))
    end
    return out
end

-- Start one NOW: no hour window, no bench requirement, no calendar entry needed.
-- Returns ok, <Id or reason>.
function RD.ForceNow(id)
    if not Utils.IsAuthority() then return false, "authority only" end
    if not SETTINGS.GAMEPLAY.MODULE_REVENGE_ASSAULTS then return false, "GAMEPLAY.MODULE_REVENGE_ASSAULTS is off" end
    if not STATE.StoryData then return false, "per-world save not loaded yet" end

    local day = Utils.GetCurrentDay()
    if not day then return false, "no day clock yet" end

    local def
    if id and id ~= "" then
        def = resolveId(id)
        if not def then return false, "no revenge matching '" .. id .. "'" end
    else
        local c = cal()
        local pick = c.Scheduled[1]
        if not pick then return false, "nothing booked (try: /au-revenge now <Id>)" end
        def = byId[pick.Id]
        if not def then return false, "booked '" .. tostring(pick.Id) .. "' is not in the roster" end
    end

    -- Clear a stuck handoff from a previous attempt, then go through the REAL path so this
    -- exercises the same hook a scheduled night does.
    pending = nil
    if not fire(def, day) then
        return false, "could not start (an assault may already be running)"
    end
    return true, def.Id
end

-- Wipe the calendar and RE-BASELINE to now.
--   * Clearing Seen/Seeded too is what makes this "forget everything and start from today": the
--     next scan retakes the baseline, absorbing whatever is already satisfied instead of booking
--     it. On a late-game save that means nothing books - which is the point.
--   * It does NOT re-book past triggers. To get one back, use "/au-revenge later <Id>".
function RD.ResetCalendar()
    if not STATE.StoryData then return 0 end
    local c = cal()
    local n = #c.Scheduled
    for id in pairs(c.Fired) do c.Fired[id] = nil; n = n + 1 end
    c.Scheduled = {}
    c.Seen = {}
    c.Seeded = false
    pending, attemptsToday, attemptsDay = nil, 0, -1
    FileIO.SaveStoryData()
    RD.PublishCalendar()
    return n
end


-- =======================================================================
-- REGISTER - validate the roster, arm the director hook. AUTHORITY, once per world.
-- =======================================================================
function RD.Register()
    if not SETTINGS.GAMEPLAY.MODULE_REVENGE_ASSAULTS then return end
    if not Utils.IsAuthority() then return end

    -- Per-world runtime reset (a teardown can leave these mid-flight; the StoryManager lesson).
    pending, pendingAt, attemptsToday, attemptsDay = nil, 0, 0, -1

    -- Republish on world load. The channel (or its shared/ file) survives a world change, so
    -- without this the PREVIOUS world's claimed nights would still be telling EATG to stand down.
    --   * Deferred: StoryData is loaded by StoryManager.Register, which may not have run yet.
    Utils.QueueWork(function()
        if STATE.ModEnabled then RD.PublishCalendar() end
    end, 5000)

    -- Roster validation. byId is already built (see its declaration); this only reports problems,
    -- and it runs every Register so a "/reload" re-checks an edited roster.
    local seen = {}
    for _, def in ipairs(ASSAULTS) do
        if not def.Id then
            LogBad("Revenge - a roster entry has no Id; it can never be scheduled")
        elseif seen[def.Id] then
            LogBad("Revenge - DUPLICATE Id '" .. def.Id .. "'; the second entry is unreachable")
        else
            seen[def.Id] = true
            if not def.Row then LogBad("Revenge - " .. def.Id .. " has no Row (DT_Assaults shell)") end
            if not (def.Trigger and (def.Trigger.Flag or def.Trigger.MinStory)) then
                LogBad("Revenge - " .. def.Id .. " has no Trigger.Flag/MinStory; it can never fire")
            end
        end
    end

    if armed then return end
    armed = true

    -- The ONE director hook. Pre-hook, no return value, so coexisting with EATG's hook on the same
    -- function is safe - but see the MUST-KNOWS about write order and the EATG stand-down.
    local hook = "/Game/Blueprints/Environment/Systems/Abiotic_AIDirector.Abiotic_AIDirector_C:SortAssaultSpawnLists"
    local ok, err = pcall(RegisterHook, hook, function(self)
        if not pending then return end
        Log("Revenge - SortAssaultSpawnLists reached for " .. pending.def.Id)
        local ok2, err2 = pcall(function()
            local director = self:get()
            if IsNotValid(director) then return end

            local def = pending.def
            local day = pending.day
            pending = nil

            -- Re-assert the shell row fire() loaded, in case another assault check swapped it
            -- in the meantime. The same call EATG's queued-assault path makes.
            local out = {}
            pcall(function() director:SelectNewAssaultType(FName(def.Row), true, out) end)

            if not applyToDirector(director, def) then return end

            -- COMMIT. Waves are on the director; this night is spent either way (MUST-KNOWS).
            local c = cal()
            c.Fired[def.Id] = day
            for i, s in ipairs(c.Scheduled) do
                if s.Id == def.Id then table.remove(c.Scheduled, i); break end
            end
            FileIO.SaveStoryData()
            RD.PublishCalendar()

            -- OnStart LAST, so a throwing set-piece cannot cost the waves. Its own drops are all
            -- queued off-hook (RevengeEvents), so nothing here loads.
            if def.OnStart then
                local okS, errS = pcall(def.OnStart)
                if not okS then LogBad("Revenge - " .. def.Id .. " OnStart: " .. tostring(errS)) end
            end
        end)
        if not ok2 then
            LogBad("Revenge - SortAssaultSpawnLists: " .. tostring(err2) ..
                   " (the assault keeps whatever wave lists it already had)")
        end
    end)

    if not ok then
        armed = false
        LogBad("Revenge - could NOT hook SortAssaultSpawnLists; revenge assaults are inert: " .. tostring(err))
        return
    end

    -- End of assault - drop the in-process variant plan and the prep-time reading (phase 6 = End,
    -- 0 = None/setup). A stale plan would otherwise be preferred over EATG's on the next assault.
    -- Pre-hook, no return value: safe to share with EATG's own phase hook.
    -- (One abort path skips this; see AnNotes/Modules/RevengeDirector.md.)
    local phaseHook = "/Game/Blueprints/Environment/Systems/Abiotic_AIDirector.Abiotic_AIDirector_C:ChangeAssaultPhase"
    local okP, errP = pcall(RegisterHook, phaseHook, function(_, newPhase)
        local okI, errI = pcall(function()
            local phase = newPhase and newPhase:get()
            if phase ~= 6 and phase ~= 0 then return end
            require("ModuleGATE.GateBridge").ClearLocalPlan()
            STATE.RevengePrepMs = nil
        end)
        if not okI then LogBad("Revenge - ChangeAssaultPhase: " .. tostring(errI)) end
    end)
    if not okP then
        LogBad("Revenge - could NOT hook ChangeAssaultPhase; the variant plan will not self-clear " ..
               "and a later EATG assault could inherit it: " .. tostring(errP))
    end

    Log(string.format("RevengeDirector armed (%d revenge assaults registered)", #ASSAULTS))
end

return RD
