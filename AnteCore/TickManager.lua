-- =======================================================================
-- TickManager - the mod heartbeat, driven by a Blueprint tick (~10/sec).
--
-- One ProcessTick() handles the ongoing logic:
--   * Drains our WorkQueue (deferred work) on a safe game thread.
--   * Runs ongoing work from some NPCs (STATE.OnTickActors)
--     - e.g. 'Antegrav Pest flips gravity every 5s. Check every 50 ticks'.
--
-- Driven differently per role (most ticks aren't available on a client):
--   * HOST/SERVER (authority): hooked to the AI Director's ProcessSpawns_Quick,
--     a 10/sec tick that only runs server-side. Hook callbacks run on the
--     game thread.
--   * CLIENT: the AI Director doesn't tick, so a self-rescheduling
--     ExecuteWithDelay loop hops onto the game thread instead.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local SETTINGS = require("Settings")
local PROF = require("AnDebug.Profiler")
local TAP = require("AnteCore.TestTap")
local LogBad = Utils.LogBad

local HOOK_FAST_TICK = "/Game/Blueprints/Environment/Systems/Abiotic_AIDirector.Abiotic_AIDirector_C:ProcessSpawns_Quick"
local CLIENT_TICK_MS = 100

-- Freeze forensics (SETTINGS.DEBUG_FREEZE_TRACE).
--   * A hang leaves no stack. Pre-log each WQ item so the hang's LAST log line names
--     the wedged job - at most one line per source per FREEZE_TRACE_LINE_GAP_SEC
--     (Utils.FreezeTraceLine).
--   * OnTick handlers are too hot to log per-invocation. They get a no-log breadcrumb
--     instead (STATE.LastWork/LastWorkDone), which covers a FREEZE but not a CRASH.
--     DEBUG_FREEZE_TRACE_TICK opts into the noisy per-handler line for that case.
--   * The watchdog below reports the breadcrumb from a worker thread when the tick stalls.
local FT = SETTINGS.DEBUG_FREEZE_TRACE
-- Opt-in extension of FT to the OnTick channel (crash forensics only - see Settings).
local FT_TICK = FT and SETTINGS.DEBUG_FREEZE_TRACE_TICK

local TM = {}


-- =======================================================================
-- FORCE_SAVE_MINUTES (Settings, player-facing) - an EXTRA forced save every N
-- minutes on top of the game's own 5-minute autosave.
--   * Accepted ONLY when the value is exactly 1, 2, 3 or 4 (5+ adds nothing over
--     the native autosave; anything else = feature off).
--   * Same save the CTRL+M dev bind fires: Request_ForceWorldSave via a player
--     controller. Called BY the server on its own copy of the controller, so it
--     works on DEDICATED (which has no local controller). A renderer host also
--     runs its own SaveCharacter.
-- =======================================================================
local FSM = SETTINGS.GAMEPLAY.FORCE_SAVE_MINUTES
local FORCE_SAVE_TICKS = (FSM == 1 or FSM == 2 or FSM == 3 or FSM == 4) and (FSM * 600) or nil

local function forceRegularSave()
    if not STATE.ModEnabled or not Utils.IsAuthority() then return end
    local player = Utils.AnyPlayer()
    if not player then return end   -- empty server / character select: nothing worth saving

    local saved = false
    pcall(function()
        local pc = player:GetController()
        if IsValid(pc) and pc.Request_ForceWorldSave then
            pc:Request_ForceWorldSave()
            saved = true
        end
    end)
    -- A renderer host also saves its own character (remote players' characters ride the
    -- world save; a pure client never runs this - the block below is authority-gated).
    if Utils.HasRenderer() then
        pcall(function()
            local pc = require("AFUtils.AFUtils").GetMyPlayerController()
            if IsValid(pc) then pc:SaveCharacter() end
        end)
    end
    if saved then
        Utils.Log("TickManager - forced save (FORCE_SAVE_MINUTES=" .. tostring(FSM) .. ")")
    end
end


-- =======================================================================
-- Freeze watchdog - runs on a WORKER thread (ExecuteWithDelay), so it can
-- still speak when the game thread is wedged.
--   * PURE LUA ONLY in here (no actor/BP calls - CLAUDE.md 2), and no ExecuteInGameThread:
--     from this thread UE4SS pushes the callback onto the game thread's own Lua stack.
--   * Armed lazily from the first ProcessTick; reschedules forever (there is
--     no cancel), staying silent while STATE.ModEnabled is off (world
--     transitions) or ticks advance.
--   * LIMIT: if the game thread died INSIDE Lua it holds the Lua lock and this
--     callback can't enter - then the WQ pre-log lines are the evidence instead.
-- =======================================================================
local watchdogArmed = false
local wdLastTick, wdStalls = -1, 0

function TM.StartFreezeWatchdog()
    if watchdogArmed or not FT then return end
    watchdogArmed = true
    local function check()
        -- A PAUSED game is not a wedged one.
        --   * World timers stop while paused, so FAST_TICK stops too. A paused game can
        --     produce the same escalating 5s/10s/15s stall series as a real freeze.
        --   * STATE.IsPaused comes off the SetGamePaused hook in AnteCore/SystemHooks;
        --     reading a Lua boolean keeps this callback pure Lua, which is mandatory
        --     on a worker thread.
        if STATE.IsPaused then
            wdStalls = 0
            wdLastTick = STATE.FAST_TICK
            ExecuteWithDelay(5000, check)
            return
        end

        if STATE.ModEnabled and STATE.FAST_TICK == wdLastTick then
            wdStalls = wdStalls + 1
            Utils.LogBad(string.format(
                "FREEZE-WATCHDOG: game tick stalled ~%ds at tick %d | last work: %s [%s] | queued: %d",
                wdStalls * 5, STATE.FAST_TICK,
                tostring(STATE.LastWork or "(none recorded)"),
                STATE.LastWorkDone and "completed; wedge is NOT in traced mod work"
                    or "IN FLIGHT - this is the wedge",
                #STATE.WorkQueue))
        else
            -- A stall that ENDS is a HITCH, not a freeze - say so, or a lone stalled-~5s
            --   line reads like a wedge that killed the session. The escalating
            --   5s/10s/15s series is the real-wedge signature.
            if wdStalls > 0 then
                Utils.LogBad(string.format(
                    "FREEZE-WATCHDOG: recovered - tick advancing again after a ~%ds stall (hitch, not a wedge)",
                    wdStalls * 5))
            end
            wdStalls = 0
        end
        wdLastTick = STATE.FAST_TICK
        ExecuteWithDelay(5000, check)
    end
    ExecuteWithDelay(5000, check)
    Utils.Log("TickManager - freeze watchdog armed (5s)")
end


-- =======================================================================
-- ProcessTick - always runs on the game thread
-- =======================================================================
function TM.ProcessTick()
    if not STATE.ModEnabled then return end
    if FT and not watchdogArmed then TM.StartFreezeWatchdog() end
    if TAP.on then TAP.Beat(STATE.WorkQueue, STATE.FAST_TICK, STATE.PauseEpoch) end

    -- Drain due WorkQueue items (iterate backwards: we remove during loop).
    --   * Throttled per tick, because a burst of spawns whose BeginPlay does blocking LoadAssets
    --     would otherwise slam one frame and deadlock a dedicated server. The rest stay queued.
    if #STATE.WorkQueue > 0 then
        -- CATCH-UP + BUDGET (see the SETTINGS block). The count alone was the wrong dial: it
        -- throttled cheap items just as hard as spawns, so a backlog never cleared, while still
        -- allowing two 100ms items into one frame. Depth opens the cap; the clock closes it.
        local cap = SETTINGS.CORE.WORKQUEUE_MAX_PER_TICK or 0
        local deep = SETTINGS.CORE.WORKQUEUE_CATCHUP_DEPTH or 0
        if deep > 0 and #STATE.WorkQueue >= deep then
            cap = math.max(cap, SETTINGS.CORE.WORKQUEUE_CATCHUP_MAX or cap)
        end
        local budgetMs = SETTINGS.CORE.WORKQUEUE_BUDGET_MS or 0
        local started = (budgetMs > 0 and os and os.clock) and os.clock() or nil

        local ran = 0
        for i = #STATE.WorkQueue, 1, -1 do
            local item = STATE.WorkQueue[i]
            if item and STATE.FAST_TICK >= item.fireAt then
                if cap > 0 and ran >= cap then break end
                -- Checked from the SECOND item on, so one due item always runs however long it
                -- took - a single over-budget item must not be able to wedge the queue.
                if started and ran > 0
                    and (os.clock() - started) * 1000 >= budgetMs then break end
                table.remove(STATE.WorkQueue, i)
                ran = ran + 1
                if FT then
                    -- Pre-log so a hang mid-item leaves its source line as the log's last word.
                    --   * item.quiet skips only the LINE, never the breadcrumb: a benign 4/s poll
                    --     would otherwise bury the wedged item it exists to reveal.
                    if not item.quiet then Utils.FreezeTraceLine("wq", item.src) end
                    STATE.LastWork = "WQ " .. (item.src or "?")
                    STATE.LastWorkDone = false
                end
                local t0 = PROF.Begin()
                local ok, err = pcall(item.fn)
                if FT then STATE.LastWorkDone = true end
                if t0 then PROF.EndAs(t0, "WQ " .. (item.src or "?")) end
                if not ok then LogBad("WorkQueue error: " .. tostring(err)) end
            end
        end
    end

    TM.ProcessOnTickActors()

    -- Periodic backup (~every 5s): destroy our attached subactors whose carrier is
    --   gone/dead, in case a per-subactor self-cleanup tick entry was lost (the
    --   floating orphan Carbuncles).
    --   * Authority-only in effect - the carrier map is empty on clients.
    if STATE.FAST_TICK % 50 == 0 then
        local t0 = PROF.Begin()
        local ok, err = pcall(AVU.SweepOrphanSubactors)
        PROF.EndAs(t0, "SweepOrphanSubactors")
        if not ok then LogBad("SweepOrphanSubactors error: " .. tostring(err)) end
    end

    -- Player-set EXTRA AUTOSAVE (see the FORCE_SAVE block above; nil unless the
    --   setting is exactly 1-4).
    --   * Queued, not inline: the save runs from the WQ drain exactly like the
    --     CTRL+M dev bind always has.
    if FORCE_SAVE_TICKS and STATE.FAST_TICK > 0 and STATE.FAST_TICK % FORCE_SAVE_TICKS == 0
        and Utils.IsAuthority() then
        Utils.QueueWork(forceRegularSave, 0)
    end

    PROF.OnTick()

    STATE.FAST_TICK = STATE.FAST_TICK + 1
end


-- =======================================================================
-- OnTickActors - actors with a recurring callback (e.g. Antegrav Pest
-- gravity flips). Fn(actor, FAST_TICK) returning "REMOVE" unregisters.
--   * Perf: only cheap liveness checks here (no BP calls) - this runs 10x/s
--     per registered actor.
--   * Tick fns must do their own deep checks before touching meshes/components
--     (and most gate real work on FAST_TICK % N).
-- =======================================================================
-- Module-level so the liveness check is `pcall(fn, actor)` - no per-actor-per-tick
--   closure allocation, unlike pcall(function() ... end) which captures `actor`
--   fresh each call.
--   IsDeparted first: address-only, so a freed entry is dropped without a deref.
local function tickActorDead(a)
    return Utils.IsDeparted(a) or IsNotValid(a) or a.IsDead == true
end

local PARK_TICKS = 20   -- how often a parked tick looks again (2s)

function TM.ProcessOnTickActors()
    if STATE.IsPaused then return end

    for i = #STATE.OnTickActors, 1, -1 do
        local entry = STATE.OnTickActors[i]
        local actor = entry.Actor

        local ok, dead = pcall(tickActorDead, actor)

        if not ok or dead then
            table.remove(STATE.OnTickActors, i)
        elseif entry.ParkedUntil and STATE.FAST_TICK < entry.ParkedUntil then
            -- Parked (the REMOVE branch below): nothing until its next look.
        else
            -- PHASE-OFFSET: spread each actor's `% N` gates across all N ticks.
            --   * Handlers gate on `totalTicks % N`. totalTicks was the GLOBAL tick, so every
            --     NPC's `% 10` work bunched onto the same frame (a ~1/s hitch with a roomful
            --     of variants). Per-actor Phase spreads them.
            --   * Safe: it only shifts WHEN a handler fires. Cooldown logic reads
            --     STATE.FAST_TICK directly and is unaffected (see AVU.RegisterOnTickActor).
            -- Freeze breadcrumb only (NO log line: this path runs 10x/s per actor).
            --   * entry.Src is a precomputed string, so this is two field writes per call.
            if FT then
                STATE.LastWork = entry.Src or "OnTick ?"
                STATE.LastWorkDone = false
                -- A breadcrumb only survives a FREEZE (the watchdog reads it). A CRASH takes the
                -- process with it, so OnTick is the one work channel that can die ANONYMOUS - no
                -- trace, since the log's last line would be an unrelated completed WQ item.
                -- FT_TICK pays the ~200 lines/s to make it name itself; off by default. TM.TraceTicks
                -- is the same for one /at run (its `trace` word).
                if FT_TICK or TM.TraceTicks then Utils.LogDebug("FT tick " .. (entry.Src or "?"), true) end
            end
            local t0 = PROF.Begin()
            local ok2, result = pcall(entry.Fn, actor, STATE.FAST_TICK + (entry.Phase or 0))
            if FT then STATE.LastWorkDone = true end
            if t0 then PROF.EndAs(t0, "OnTick " .. (entry.Src or "?")) end
            if not ok2 then
                LogBad("OnTickActors error: " .. tostring(result))
                table.remove(STATE.OnTickActors, i)
            elseif result == "REMOVE" then
                -- PARK a body whose level is merely away (Utils.IsLevelAway) instead of dropping
                -- it. Nearly every tick opens with `if IsActorInvalid then return "REMOVE"`, and
                -- for a script-spawned body on a dedicated server that read is TRANSIENT: the
                -- players leave, the level unloads, the body stays. Dropping its clock there
                -- left a statue for whoever came back - riders, Beholder eyes, summons.
                if Utils.IsLevelAway(actor) then
                    if not entry.ParkedUntil then
                        Utils.LogDebug("OnTick - parked, its level is away: "
                            .. tostring(entry.Src or Utils.GetActorName(actor)), SETTINGS.DEBUG_NPC_ACTIONS)
                    end
                    entry.ParkedUntil = STATE.FAST_TICK + PARK_TICKS
                else
                    table.remove(STATE.OnTickActors, i)
                end
            elseif entry.ParkedUntil then
                entry.ParkedUntil = nil
                Utils.LogDebug("OnTick - resumed, its level is back: "
                    .. tostring(entry.Src or Utils.GetActorName(actor)), SETTINGS.DEBUG_NPC_ACTIONS)
            end
        end
    end
end


-- =======================================================================
-- Drivers
-- =======================================================================

-- Authority: piggyback on the AI Director's 10x/second function
function TM.RegisterServer()
    if STATE.ServerHooksRegistered then return end

    RegisterHook(HOOK_FAST_TICK, function()
        TM.ProcessTick()
    end)

    Utils.Log("TickManager - server fast tick registered")
end

-- Client: driven by the player character's ReceiveTick hook (one we CAN access),
--   throttled here so it kicks off ~10x/sec.
--   * A naive ExecuteWithDelay + ExecuteInGameThread loop crashed the client
--     (ExecuteInGameThread can flush mid-component-tick or mid-widget-update).
--   * ReceiveTick runs on the real game thread in a clean gameplay context,
--     safe for BP/component work.

local clientAccum = 0
function TM.ClientTick(deltaSeconds)
    if not STATE.ModEnabled or STATE.Role ~= "CLIENT" then return end

    clientAccum = clientAccum + (deltaSeconds or 0)
    if clientAccum < (CLIENT_TICK_MS / 1000) then return end
    clientAccum = clientAccum - (CLIENT_TICK_MS / 1000)
    if clientAccum > 0.5 then clientAccum = 0 end  -- don't spiral after a hitch

    local ok, err = pcall(TM.ProcessTick)
    if not ok then LogBad("Client tick error: " .. tostring(err)) end
end

return TM
