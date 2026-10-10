-- =======================================================================
-- Pipeline - runs something as a chain of steps that can wait on
-- conditions, delays, or async asset loads before continuing.
--   * Common usecase: a plain NPC mutating into an Antevariant -
--     set some stats, load assets, wait on that and do other things.
--   * Every step transition is scheduled through Utils.QueueWork, so steps
--     always execute on the game thread at fasttick cadence.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local ASSETS = require("AnteCore.AssetManager")
local Utils = require("AnteUtils.Utils")
local PROF = require("AnDebug.Profiler")
local LogBad = Utils.LogBad

local PLM = {}

-- The PinPaths backstop after a load (see PLM.LoadAssets): picks up what the immediate pin missed.
local PIN_DELAY_MS = 4000

-- =======================================================================
-- Run a chain of steps, passing a shared context table between them.
--   * onFail(stepName, reason) - OPTIONAL. Called when a step fails or crashes, so the
--     caller can undo its own bookkeeping (e.g. ClientVisuals un-marking an actor so a
--     later scan retries it). A pipeline that dies is otherwise SILENT to its caller.
-- =======================================================================
function PLM.Run(steps, context, onFail)
    local i = 1

    local function nextStep()
        if i > #steps then return end

        local step = steps[i]
        i = i + 1

        -- Profiling: label the step's SYNCHRONOUS cost by name (which mutation step
        --   is the fat one - Stats? Visuals attaches?).
        --   * Caveat: PLM.Do calls next() INLINE, so consecutive Do steps nest and the
        --     FIRST one's label absorbs its successors; async steps (WaitFor/Delay/
        --     LoadAssets) re-enter via the WorkQueue and time separately.
        -- A Do step runs INLINE (below), so a wedge inside one logs nothing of its own - this
        -- crumb is what puts the step name on the watchdog line.
        Utils.Crumb("pipe:" .. (step.name or "?"))

        local t0 = PROF.Begin()
        local ok, err = pcall(function()
            step.run(context, nextStep, function(reason)
                LogBad("Pipeline failed: " .. (step.name or "?") .. " | " .. (reason or "unknown")
                    .. (context.name and (" | " .. tostring(context.name)) or ""))
                if onFail then pcall(onFail, step.name, reason) end
            end)
        end)
        if t0 then PROF.EndAs(t0, "Pipe." .. (step.name or "?")) end

        if not ok then
            LogBad("Pipeline crash in step: " .. (step.name or "?") .. " | " .. tostring(err)
                .. (context.name and (" | " .. tostring(context.name)) or ""))
            if onFail then pcall(onFail, step.name, tostring(err)) end
        end
    end

    nextStep()
end

-- =======================================================================
-- Step: run a function, continue immediately
-- =======================================================================
function PLM.Do(name, fn)
    return {
        name = name,
        run = function(ctx, next, fail)
            local ok, result = pcall(fn, ctx)
            if not ok then
                fail(result)
                return
            end
            next()
        end
    }
end

-- =======================================================================
-- Step: continue after a delay (game-thread safe via WorkQueue)
-- =======================================================================
function PLM.Delay(name, delayMs)
    return {
        name = name,
        run = function(ctx, next, fail)
            Utils.QueueWork(next, delayMs or 100)
        end
    }
end

-- =======================================================================
-- Step: poll a condition each tick until true (or timeout)
-- =======================================================================
-- A timeout here is a step FAILURE.
--   * It used to just log and silently stop the chain, which left callers
--     believing the pipeline had run.
--   * abandon - OPTIONAL, polled ahead of the condition. True ends the chain quietly: neither next
--     nor fail. For a wait whose subject can leave play mid-wait - nothing is left to do, and
--     polling it out to the timeout only produced a false failure.
function PLM.WaitFor(name, condition, timeoutMs, abandon)
    return {
        name = name,
        run = function(ctx, next, fail)
            local dropped = false
            PLM.WaitUntil(function()
                if abandon and abandon(ctx) then
                    dropped = true
                    return true
                end
                return condition(ctx)
            end, name, function()
                if not dropped then next() end
            end, timeoutMs, function()
                fail("timed out after " .. tostring(timeoutMs or 2000) .. "ms")
            end)
        end
    }
end

-- =======================================================================
-- Step: wait for a condition, but continue anyway once timeoutMs is up.
-- =======================================================================
-- The difference from WaitFor is what a timeout MEANS. WaitFor's timeout is a failure - the
-- condition was supposed to hold. This one's is a normal outcome: the step is waiting on something
-- the actor may simply never do (a spawn-in animation a base doesn't have), so "it never happened"
-- and "it happened already" both just mean carry on.
--   * onTimeout - OPTIONAL, runs before continuing. It is the only trace that the wait ran out, so
--     a caller that cares whether it waited the full budget logs it there.
--   * The already-true case costs NOTHING: it is tested inline and continues in the same drain
--     item. WaitUntil always defers its first poll by a tick, and a step most actors sail through
--     would otherwise put one more item on a queue that only drains a couple per tick.
function PLM.WaitAtMost(name, condition, timeoutMs, onTimeout)
    return {
        name = name,
        run = function(ctx, next, fail)
            local ok, done = pcall(condition, ctx)
            if ok and done then
                next()
                return
            end

            PLM.WaitUntil(function()
                return condition(ctx)
            end, name, next, timeoutMs, function()
                if onTimeout then pcall(onTimeout, ctx) end
                next()
            end)
        end
    }
end


-- WaitFor's engine; usable on its own.
--   * onTimeout - OPTIONAL. Given, it OWNS the timeout (and the logging): WaitFor turns it into a
--     pipeline failure, WaitAtMost continues the chain anyway. Standalone callers omit it and just
--     get the log.
--   * NOTE: the deadline is WALL CLOCK (os.clock) while `check` re-queues through
--     the WorkQueue, which is capped at SETTINGS.CORE.WORKQUEUE_MAX_PER_TICK - if enough
--     polls are in flight they starve each other, and this can time out even though
--     the condition would have passed.
function PLM.WaitUntil(condition, name, callback, timeoutMs, onTimeout)
    local start = os.clock() * 1000
    timeoutMs = timeoutMs or 2000

    local function check()
        if condition() then
            callback()
            return
        end

        if (os.clock() * 1000 - start) > timeoutMs then
            if onTimeout then
                onTimeout()
            else
                LogBad("Pipeline WaitUntil timeout on: " .. name)
            end
            return
        end

        Utils.QueueWork(check, 100)
    end

    Utils.QueueWork(check, 100)
end

-- =======================================================================
-- Step: async-load every path in ctx.paths into ctx.assets
--   * ctx.paths IS def.Assets (NpcManager is the only caller of Pipeline.Run).
-- =======================================================================
function PLM.LoadAssets()
    return {
        name = "LoadAssets",
        run = function(ctx, next, fail)
            local paths = ctx.paths or {}

            ASSETS.LoadAsync(paths, function(results)
                ctx.assets = results

                if not results then
                    fail("Asset load failed")
                    return
                end

                -- GC-PIN what we just loaded. def.Assets is a PRELOAD, not a hold: nothing keeps
                -- a variant's assets resident once no live actor references them, so a set only
                -- BeginPlay touched can get collected and cold-load again on the next mutation.
                -- Pinning fixes both halves:
                --   * no re-cold-load, and
                --   * every later GetIfValid on these paths is a trusted cache hit instead of a
                --     full UObject-array WALK - the operation that crashes
                --     ([[anteup2-ue4ss-findobject-scan-crash]]).
                -- Self-scoping: only variants actually spawned in this world pin. Flag-gated
                -- (ASSET_KEEPER), every role, deduped against pinned + known-unpinnable paths, so
                -- free from the 2nd mutation of a variant onward.
                --   * Pinned on the very next drain item, BEFORE the next step: a GC can land in
                --     the load -> use gap (one took the Embolon's spear 0.2 s after its cold load,
                --     before its Visuals asked for it). About 1 ms per new path.
                --   * The delayed PinPaths is the backstop for anything that couldn't pin then.
                Utils.QueueWork(function()
                    pcall(function()
                        local KEEPER = require("AnteCore.AssetKeeper")
                        for path, asset in pairs(results) do KEEPER.PinNow(path, asset) end
                    end)
                    next()
                end, 0)
                if #paths > 0 then
                    Utils.QueueWork(function()
                        pcall(function() require("AnteCore.AssetKeeper").PinPaths(paths) end)
                    end, PIN_DELAY_MS)
                end
            end)
        end
    }
end

return PLM
