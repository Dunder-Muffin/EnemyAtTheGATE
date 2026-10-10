
-- ============================================================
-- QueueManager.lua
-- Deferred work queue with ~100 ms tick resolution.
--
-- * Handles NPC spawning and other tasks. AF has some instability
--    in when and how NPCs are spawned, so we are using this queue to
--    process tasks with STATE.TICKS
-- 
-- * QM.Drain() will run a task
-- ============================================================

local STATE = require("Data.STATE")

local QM = {}

local _queue = {}   -- { fn=function, fireAt=TICKS }

-- Max items to run per tick (~10 ticks/sec). Spreads heavy bursts (e.g. many
-- assault drops landing on the same tick) across frames so a single game-thread
-- frame isn't slammed with dozens of spawns at once. 0 = unlimited.
-- 2 -> ~20 spawns/sec. Lower = gentler on the game thread, slower to drain.
QM.MaxPerTick = 2


-- ============================================================
-- Queue fn to run after delay ms
-- ============================================================
function QM.Queue(fn, delay)

    -- ms <-> ticks
    local tickDelay = math.max(1, math.ceil((delay or 0) / 100))

    table.insert(_queue, {
        fn     = fn,
        fireAt = STATE.TICKS + tickDelay,
    })
end


-- ============================================================
-- Called every tick. Runs any functions where now > fireAt
-- 
-- ============================================================
function QM.Drain()
    
    if #_queue == 0 then return end
    
    local now = STATE.TICKS
    local cap = QM.MaxPerTick or 0
    local ran = 0


    -- * Iterates backwards. (If the _queue gets new items)
    -- * Stops after `cap` items this tick; the rest stay queued for next tick.
    for i = #_queue, 1, -1 do
        local item = _queue[i]
        if item and now >= item.fireAt then
            if cap > 0 and ran >= cap then break end
            table.remove(_queue, i)
            ran = ran + 1
            local ok, err = pcall(item.fn)
            if not ok then
                print("[GATE][ERR] QueueManager.Drain: " .. tostring(err) .. "\n")
            end
        end
    end
end


-- ============================================================
-- Reset: called on session end (StopMod).
-- ============================================================
function QM.Reset()
    _queue = {}
end


return QM
