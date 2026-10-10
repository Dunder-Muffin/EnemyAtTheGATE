-- =======================================================================
-- NetChannel - the mod's ONE server->client push. Lua can't declare an RPC, so we ride the engine's
-- ClientPlaySoundAtLocation: a per-client RPC whose body is UGameplayStatics::PlaySoundAtLocation,
-- which returns immediately on a null sound. Nothing plays, nothing draws, nothing is written - the
-- chat RPC this replaces added a blank line to every player's chat box on every push.
--
-- ONE FRAME = one RPC call, four payload numbers:
--   Location   x / y / z, full double precision (measured un-quantized on the wire)
--   Volume     a, float32 - exact on integers to 2^24
--   Pitch      the header, always negative: -(BASE + opcode/msgId/part/count)
--
-- A message is 1-8 frames, so anything wider than four numbers sends numbered parts and the
-- receiver assembles them. Every frame goes out `copies` times and duplicates are dropped on
-- arrival: the transport is UNRELIABLE (measured lossless in a 100-frame burst, but a real
-- connection drops packets, and a lost frame means a message that never assembles).
--
-- ROLES: the authority sends; every renderer receives, including a host receiving its own send.
-- THREADING: the hook body is plain arithmetic and table work, safe in the RPC intercept.
-- Handlers run on the WorkQueue drain, so a handler may spawn, destroy and touch components - unless
-- registered inline (NET.On), for a high-rate handler that only fills Lua tables.
--
-- The pitch range is this mod's namespace on a shared RPC. AnDebug/NetProbe sits below it and
-- EnemyAtTheGATE still uses its own chat sentinel, so neither can decode as ours.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local Utils = require("AnteUtils.Utils")

local NET = {}

-- Opcodes, 1..31. One per message family; the payload layout inside it is the sender's business.
--   * VERSION and the frame header below are the one contract between DIFFERENT builds - it is how a
--     mismatched client finds out. Never renumber VERSION or change the header layout; add a field to
--     the version frame instead.
NET.OP = {
    FX = 1,        -- AnteUtils/ClientFX -> AnteVariants/ClientEffects
    VERSION = 2,   -- AnteCore/VersionCheck
    SCT = 3,       -- ModuleSCT (one frame per damage number)
    PROBE = 4,     -- AnDebug/NetProbe replicated-property probe (dev tool)
    ANTEST = 5,    -- AnTest/Runner: the server starts a joined client's half of a test (dev tool)
    CHAT = 6,      -- AnDebug/ChatCommands: a joined client's LOCAL command line, handed back to it (dev tool)
}

local RPC_PATH = "/Script/Engine.PlayerController:ClientPlaySoundAtLocation"

local BASE = 1000000        -- a real pitch multiplier is small and positive
local MAX_OPCODE = 31
local MSG_IDS = 1024        -- the msgId wraps; it only has to outlive a message's re-sends
local MAX_PARTS = 8
local MAX_HEADER = 2097151  -- 5 bits opcode, 10 msgId, 3 part, 3 count

local DEFAULT_COPIES = 2
local BOOK_MAX = 32
local BOOK_TTL_TICKS = 50   -- ~5s; long enough for re-sends, short enough to forget losses
-- A message's duplicates arrive in the same tick, so `done` only needs ~1s - and a short memory keeps
-- the 1024-id wrap from dropping fresh messages under combat-rate traffic.
local DONE_TTL_TICKS = 10

local lastSweep = 0
local handlers = {}   -- opcode -> fn(frames)
local inlineOps = {}  -- opcode -> true: the handler runs inside the RPC hook
local pending = {}    -- "op#msgId" -> { count, parts, filled, tick }
local done = {}       -- "op#msgId" -> tick, so a late duplicate can't re-dispatch a message


-- =======================================================================
-- Header
-- =======================================================================

local function packHeader(opcode, msgId, part, count)
    return ((opcode * MSG_IDS + msgId) * MAX_PARTS + part) * MAX_PARTS + (count - 1)
end

local function unpackHeader(h)
    local count = (h % MAX_PARTS) + 1
    h = h // MAX_PARTS
    local part = h % MAX_PARTS
    h = h // MAX_PARTS
    local msgId = h % MSG_IDS
    return h // MSG_IDS, msgId, part, count
end


-- =======================================================================
-- Send [AUTHORITY]
-- =======================================================================

local function nextMsgId()
    local id = ((STATE.NetMsgId or 0) + 1) % MSG_IDS
    STATE.NetMsgId = id
    return id
end

local function validate(opcode, frames)
    if not Utils.IsAuthority() then return false end
    if type(opcode) ~= "number" or opcode < 1 or opcode > MAX_OPCODE then
        Utils.LogBad("NetChannel - bad opcode: " .. tostring(opcode))
        return false
    end
    local n = frames and #frames or 0
    if n < 1 or n > MAX_PARTS then
        Utils.LogBad("NetChannel - a message is 1-" .. MAX_PARTS .. " frames, got " .. n)
        return false
    end
    return true
end

-- Every frame of one message to one controller. A nil sound is what makes the call inert.
local function pushMessage(pc, opcode, msgId, frames, copies)
    local n = #frames
    for _ = 1, math.max(1, copies or DEFAULT_COPIES) do
        for part = 1, n do
            local f = frames[part]
            pc:ClientPlaySoundAtLocation(nil, { X = f.x or 0, Y = f.y or 0, Z = f.z or 0 },
                f.a or 0, -(BASE + packHeader(opcode, msgId, part - 1, n)))
        end
    end
end

-- [AUTHORITY] Push one message to every player's renderer. Returns the renderers reached.
-- `frames` is 1-8 tables of { x, y, z, a }, all optional numbers.
function NET.Broadcast(opcode, frames, copies)
    if not validate(opcode, frames) then return 0 end

    -- The GameState's player array, NOT FindAllOf (which walks every UObject in the world - see
    -- [[anteup2-microlag-and-profiler]]).
    local gs = STATE.GameState
    if IsNotValid(gs) then return 0 end
    local players = gs.PlayerCharacterInGame
    if not players then return 0 end

    local msgId = nextMsgId()
    local reached = 0
    for i = 1, #players do
        local p = players[i]
        if IsValid(p) then
            pcall(function()
                local pc = p:GetController()
                if IsNotValid(pc) or not pc.ClientPlaySoundAtLocation then return end
                pushMessage(pc, opcode, msgId, frames, copies)
                reached = reached + 1
            end)
        end
    end
    return reached
end

-- [AUTHORITY] The same message to ONE client - for anything only that player should see.
function NET.SendTo(pc, opcode, frames, copies)
    if not validate(opcode, frames) or IsNotValid(pc) then return false end
    local ok = pcall(pushMessage, pc, opcode, nextMsgId(), frames, copies)
    return ok
end


-- =======================================================================
-- Text in frames: 6 bytes in each double, 3 in the float, so 21 bytes a frame and 168 a message.
-- Zero bytes are padding, so the text itself must have none (a chat line never does).
-- =======================================================================

NET.TEXT_MAX = MAX_PARTS * 21

function NET.PackText(text)
    text = tostring(text or ""):sub(1, NET.TEXT_MAX)
    local frames, pos = {}, 1
    local function take(n)
        local v = 0
        for _ = 1, n do
            v = v * 256 + (text:byte(pos) or 0)
            pos = pos + 1
        end
        return v
    end
    while pos <= #text do
        frames[#frames + 1] = { x = take(6), y = take(6), z = take(6), a = take(3) }
    end
    return frames
end

function NET.UnpackText(frames)
    local out = {}
    local function put(v, n)
        v = math.floor((tonumber(v) or 0) + 0.5)
        local bytes = {}
        for i = n, 1, -1 do
            bytes[i] = v % 256
            v = v // 256
        end
        for i = 1, n do
            if bytes[i] > 0 then out[#out + 1] = string.char(bytes[i]) end
        end
    end
    for _, f in ipairs(frames or {}) do
        put(f.x, 6); put(f.y, 6); put(f.z, 6); put(f.a, 3)
    end
    return table.concat(out)
end


-- =======================================================================
-- Receive [RENDERER]
-- =======================================================================

-- Forget books that never completed and ids old enough that no re-send can still be in flight.
-- FAST_TICK restarts at 0 every world, so a negative age means the entry is from the last one.
local function sweep()
    local now = STATE.FAST_TICK or 0
    local live = 0
    for key, book in pairs(pending) do
        local age = now - (book.tick or 0)
        if age > BOOK_TTL_TICKS or age < 0 then pending[key] = nil else live = live + 1 end
    end
    for key, tick in pairs(done) do
        local age = now - tick
        if age > DONE_TTL_TICKS or age < 0 then done[key] = nil end
    end
    -- A flood of half-arrived messages would grow this forever; drop the lot and let re-sends
    -- rebuild whatever is still coming.
    if live > BOOK_MAX then pending = {} end
end

-- Sweeping is O(books), so it runs on a timer rather than per frame - a burst of frames does its
-- housekeeping once.
local function maybeSweep()
    local now = STATE.FAST_TICK or 0
    if now - lastSweep < 10 or now < lastSweep then
        lastSweep = math.min(lastSweep, now)
        return
    end
    lastSweep = now
    sweep()
end

local function dispatch(opcode, frames)
    local fn = handlers[opcode]
    if not fn then
        Utils.LogDebug("NetChannel - opcode " .. opcode .. " arrived with no handler on this machine",
            SETTINGS.DEBUG_CLIENT)
        return
    end
    if inlineOps[opcode] then
        local ok, err = pcall(fn, frames)
        if not ok then Utils.LogBad("NetChannel - opcode " .. opcode .. " handler: " .. tostring(err)) end
        return
    end
    Utils.LogDebug("NetChannel - opcode " .. opcode .. " (" .. #frames .. " frame(s))",
        SETTINGS.DEBUG_CLIENT)
    Utils.QueueWork(function() fn(frames) end, 0)
end

local function onFrame(_self, sound, location, volume, pitch)
    local p = pitch and pitch:get()
    if type(p) ~= "number" or p > -BASE then return end

    local h = -p - BASE
    local header = math.floor(h + 0.5)
    if header < 0 or header > MAX_HEADER or math.abs(h - header) > 0.001 then return end

    -- A genuine call carries a sound; ours never does.
    local ok, live = pcall(function() return sound:get():IsValid() end)
    if ok and live then return end

    local opcode, msgId, part, count = unpackHeader(header)
    if not handlers[opcode] then return end

    local key = opcode .. "#" .. msgId
    if done[key] then return end
    maybeSweep()

    local loc = location and location:get()
    local frame = {
        x = loc and loc.X or 0, y = loc and loc.Y or 0, z = loc and loc.Z or 0,
        a = (volume and volume:get()) or 0,
    }

    if count == 1 then
        done[key] = STATE.FAST_TICK
        dispatch(opcode, { frame })
        return
    end

    local book = pending[key]
    if not book then
        book = { count = count, parts = {}, filled = 0, tick = STATE.FAST_TICK }
        pending[key] = book
    end
    if book.parts[part + 1] then return end   -- another copy of a part we already hold
    book.parts[part + 1] = frame
    book.filled = book.filled + 1
    if book.filled < book.count then return end

    pending[key] = nil
    done[key] = STATE.FAST_TICK
    dispatch(opcode, book.parts)
end


-- =======================================================================
-- Public
-- =======================================================================

-- [RENDERER] Arm the receiving hook. Idempotent - every consumer calls it before NET.On.
-- Both slots are armed: this RPC fires both, duplicates cost a table lookup, and either slot alone
-- still delivers every message if the other ever stops firing ([[anteup2-hook-post-slot-unreliable]]).
function NET.RegisterReceiver()
    if STATE.NetChannelArmed then return end

    local ok, preId = pcall(RegisterHook, RPC_PATH,
        function(...) pcall(onFrame, ...) end,
        function(...) pcall(onFrame, ...) end)

    if ok and preId ~= nil then
        STATE.NetChannelArmed = true
        Utils.Log("NetChannel - receiver armed")
    else
        Utils.LogBad("NetChannel - receiver NOT armed, nothing pushed will arrive: "
            .. (ok and "RegisterHook returned no id" or tostring(preId)))
    end
end

-- [RENDERER] Route one opcode to fn(frames). Frames are plain number tables { x, y, z, a }.
--   * inline = true runs fn inside the RPC hook instead of on the drain. Only for a handler that
--     touches nothing but Lua tables, where a high-rate stream would otherwise crowd the WorkQueue.
function NET.On(opcode, fn, inline)
    handlers[opcode] = fn
    inlineOps[opcode] = inline == true or nil
end

return NET
