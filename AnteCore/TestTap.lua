-- =======================================================================
-- TestTap - counters the AnTest suites read while a test runs (AnTest/Metrics).
--   * Every site is `if TAP.on then ... end`, so with no test running it costs one field read.
--   * Sites: Utils.LogBad ("bad"), Utils.TraceLookup ("lookup", by caller), Utils.IsDeparted
--     ("departed", by caller), the AssetManager loader ("reload" / "coldload", by path), and
--     TickManager.ProcessTick (heartbeat gaps + WorkQueue depth).
--   * No requires: Utils loads this, and everything loads Utils.
-- =======================================================================

local TAP = { on = false }

local tallies = {}
local beat = {}

local function freshBeat()
    return { n = 0, sum = 0, last = nil, maxGap = 0, over250 = 0, over1000 = 0, maxDepth = 0, maxLagTicks = 0,
             pauses = 0 }
end
beat = freshBeat()

function TAP.Start()
    tallies = {}
    beat = freshBeat()
    TAP.on = true
end

function TAP.Stop()
    TAP.on = false
end

-- kind groups a family of events; key groups within it (a caller, a path, an error shape).
-- `sample` keeps the first concrete value seen for that key.
function TAP.Count(kind, key, sample)
    local t = tallies[kind]
    if not t then
        t = { total = 0, by = {}, sample = {} }
        tallies[kind] = t
    end
    t.total = t.total + 1
    key = key or "?"
    t.by[key] = (t.by[key] or 0) + 1
    if sample ~= nil and t.sample[key] == nil then t.sample[key] = tostring(sample) end
end

-- Once per heartbeat (~10/s). A stalled game thread shows as a long gap; the queue numbers say
-- whether deferred work was piling up behind it. A gap that spans a pause (pauseEpoch moved,
-- STATE.PauseEpoch) is the player at the menu, not a stall, and is left out.
function TAP.Beat(queue, fastTick, pauseEpoch)
    local now = os.clock() * 1000
    local b = beat
    if b.last and pauseEpoch ~= b.epoch then
        b.pauses = b.pauses + 1
    elseif b.last then
        local gap = now - b.last
        b.n = b.n + 1
        b.sum = b.sum + gap
        if gap > b.maxGap then b.maxGap = gap end
        if gap >= 250 then b.over250 = b.over250 + 1 end
        if gap >= 1000 then b.over1000 = b.over1000 + 1 end
    end
    b.last, b.epoch = now, pauseEpoch

    local depth = #queue
    if depth > b.maxDepth then b.maxDepth = depth end
    for i = 1, depth do
        local item = queue[i]
        local lag = item and (fastTick - item.fireAt) or 0
        if lag > b.maxLagTicks then b.maxLagTicks = lag end
    end
end

function TAP.Read()
    return tallies, beat
end

return TAP
