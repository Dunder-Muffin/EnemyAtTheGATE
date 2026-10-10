-- ============================================================
-- ChatCommands.lua  (DEV / DEDICATED-SERVER debug)
--
-- Lets the debug actions run on a dedicated server, where keybinds can't
-- reach the host. A client sends a "/gate <cmd>" chat line; chat send is a
-- built-in client->server RPC (Abiotic_PlayerController:Request_SendTextChatMessage,
-- flagged NetServer), so hooking it on the AUTHORITY picks the command up
-- server-side. Replies go back to that one client via Local_DisplayTextChatMessage
-- (flagged NetClient), the game's normal server->client chat path.
--
-- WIRING: main.lua InitMod registers this on the authority when
--   CONFIG.DEBUG_COMMAND is set - independently of CONFIG.DEBUG_KEYBIND, so you
--   can run the commands with the keybinds turned off (they clash with AnteUp's).
--   (See Keybinds.lua for the client side that sends these commands.)
--
-- COMMANDS (all prefixed "/gate"):
--   /gate help                 - list commands
--   /gate force                - force-begin the next assault
--   /gate shuffle              - shuffle the next native assault
--   /gate setnext <row> [idx]  - queue a specific custom assault row
--   /gate time [n]             - advance time n hours (default 1)
--   /gate turrets              - free all turrets from power
--   /gate clear                - kill + clear corpses/items near the sender
--   /gate save                 - save the sender's character + world
--   /gate current              - report the current assault
--   /gate last                 - report the last custom assault
--   /gate list                 - list custom assault rows
-- ============================================================

---@diagnostic disable: undefined-field, undefined-global, param-type-mismatch

local AFUtils = require("AFUtils.AFUtils")

local STATE = require("Data.STATE")
local CONFIG = STATE.Config
local Utils = require("Utils.Utils")
local Debug = require("Utils.UtilsDebug")
local GATE  = require("Managers.GATEManager")

local Log    = Utils.Log
local LogBad = Utils.LogBad

local CHAT_HOOK = "/Game/Blueprints/Meta/Abiotic_PlayerController.Abiotic_PlayerController_C:Request_SendTextChatMessage"
local PREFIX    = "/gate"
local WHITE     = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }

local CC = {}


-- Reply to the player who sent the command. Local_DisplayTextChatMessage is a
-- NetClient RPC, so calling it on the sender's controller (from the server)
-- shows the line on that client. On a HOST the sender is the host, so it just
-- displays locally.
--
-- QUEUED, always: most handlers call this straight from the
-- Request_SendTextChatMessage hook, and displaying a line re-enters the chat
-- pipeline while the outbound send is still on the stack - on a host that is a
-- widget mutation from inside the chat frame. Hopping to the game-tick drain
-- costs ~100 ms of latency on a debug command and takes the whole family of
-- re-entrancy off the table. Handlers that already queue just get one more hop.
local function reply(controller, msg)
    if IsNotValid(controller) then return end
    Utils.QueueSpawn(function()
        if IsNotValid(controller) then return end
        local ps = controller.PlayerState
        local ok, err = pcall(function()
            controller:Local_DisplayTextChatMessage("[GATE] ", WHITE, tostring(msg), WHITE, ps, false)
        end)
        if not ok then Log("reply failed (" .. tostring(msg) .. "): " .. tostring(err)) end
    end, 0)
end


-- ============================================================
-- Command handlers. Each: function(controller, args, sendReply)
--   * controller : sender's Abiotic_PlayerController (server-side, has authority)
--   * args       : array of lowercased-where-relevant tokens after the command
--   * sendReply  : reply(controller, msg) bound for convenience
-- Director / world reads use FindFirstOf, which is server-side here.
-- ============================================================
local COMMANDS = {}

COMMANDS.help = function(_, _, sendReply)
    sendReply("cmds: force, shuffle, setnext <row> [idx], time [n], turrets, clear, save, current, last, list")
end

COMMANDS.force = function(_, _, sendReply)
    Utils.QueueSpawn(function()
        local director = FindFirstOf("Abiotic_AIDirector_C")
        if IsNotValid(director) then sendReply("no director found"); return end
        director:ServerForceBeginAssault()
        sendReply("assault triggered")
    end, 0)
end

COMMANDS.shuffle = function(_, _, sendReply)
    Utils.QueueSpawn(function()
        local row = Utils.ShuffleAssault()
        sendReply(row and ("next native assault: " .. row) or "shuffle failed (no director / no valid row)")
    end, 0)
end

-- /gate setnext <row> [idx]
COMMANDS.setnext = function(_, args, sendReply)
    local row = args[1]
    if not row then sendReply("usage: /gate setnext <row> [idx]"); return end
    local idx = tonumber(args[2])

    local entries = GATE.GetAllCustomAssaults()
    if not entries or #entries == 0 then sendReply("no custom assaults loaded"); return end

    -- Match by row (and idx if provided). Row names are case-sensitive FNames,
    -- but accept a case-insensitive match for convenience.
    local chosen
    for _, e in ipairs(entries) do
        if e.row == row or e.row:lower() == row:lower() then
            if not idx or e.idx == idx then chosen = e; break end
            chosen = chosen or e   -- fall back to first row match if idx not found
        end
    end
    if not chosen then sendReply("unknown row: " .. tostring(row) .. " (try /gate list)"); return end

    Utils.QueueSpawn(function()
        STATE.DebugQueuedAssault = chosen
        Utils.SetNextAssaultType(chosen.row)
        sendReply(string.format("queued %s  [%s]", chosen.data.Name or chosen.row, chosen.row))
    end, 0)
end

-- /gate time [n]
COMMANDS.time = function(_, args, sendReply)
    local n = tonumber(args[1]) or 1
    Utils.QueueSpawn(function()
        Debug.AdvanceTime(n)
        local dayNight = AFUtils.GetDayNightManager()
        if dayNight and IsValid(dayNight) then
            local t = dayNight.CurrentTimeInSeconds or 0
            sendReply(string.format("advanced %dh -> Day %d %02d:00", n, dayNight.CurrentDay or 0, math.floor(t / 3600)))
        else
            sendReply("advanced " .. n .. "h")
        end
    end, 0)
end

COMMANDS.turrets = function(_, _, sendReply)
    Utils.QueueSpawn(function()
        local laser, disc = Utils.FreeAllTurrets()
        sendReply(string.format("turrets freed: %d laser, %d disc", laser, disc))
    end, 0)
end

-- /gate clear  - kill + clean up near the SENDER (not the host)
COMMANDS.clear = function(controller, _, sendReply)
    -- Resolve the pawn on the drain tick, not in the chat hook frame.
    Utils.QueueSpawn(function()
        local pawn = controller:K2_GetPawn()
        if Utils.IsActorInvalid(pawn) then sendReply("no pawn to center on"); return end
        Debug.P1KillNearby(pawn)             -- +0s
        Debug.P1ClearCorpsesItems(3000, pawn) -- +3s, after kills settle
        sendReply("killing + clearing nearby")
    end, 0)
end

-- /gate save  - save the SENDER's character + the world
COMMANDS.save = function(controller, _, sendReply)
    Utils.QueueSpawn(function()
        local pawn = controller.MyPlayerCharacter
        if pawn and IsValid(pawn) then
            local ps = pawn.MyPlayerState
            if ps and IsValid(ps) then
                local loc = pawn:K2_GetActorLocation()
                pcall(function()
                    ps.CurrentPlayerSaveData.LastSafeWorldLocation_30_486FB66C419E431BD6B754B0C04C9F5B = loc
                end)
            end
        end
        controller:SaveCharacter()
        controller:Request_ForceWorldSave()
        sendReply("saved game")
    end, 0)
end

COMMANDS.current = function(_, _, sendReply)
    -- FindFirstOf + IsAssaultHappening are BP calls: off the chat hook frame.
    Utils.QueueSpawn(function()
        local director, nativeName = Utils.GetNativeAssaultName()
        if not director then sendReply("no director found"); return end

        local isActive   = director:IsAssaultHappening()
        local lastCustom = STATE.LastCustomAssault
        local queued     = STATE.DebugQueuedAssault

        if not isActive then
            if queued then
                sendReply(string.format("inactive. queued: %s [%s]", queued.data.Name or queued.row, queued.row))
            elseif lastCustom then
                sendReply(string.format("inactive. last: %s [SP %s-%s]",
                    lastCustom.Name or nativeName, lastCustom.StoryMin or 0, lastCustom.StoryMax or 999))
            else
                sendReply("inactive. no previous assault data")
            end
            return
        end

        if lastCustom then
            sendReply(string.format("%s [SP %d-%d] (%s)",
                lastCustom.Name or nativeName, lastCustom.StoryMin or 0, lastCustom.StoryMax or 999, nativeName))
        else
            sendReply(nativeName)
        end
    end, 0)
end

COMMANDS.last = function(_, _, sendReply)
    local a = STATE.LastCustomAssault
    if not a then sendReply("no custom assault applied this session"); return end
    sendReply(string.format("last: %s [%d-%d]", a.Name or "?", a.StoryMin or 0, a.StoryMax or 999))
end

COMMANDS.list = function(_, _, sendReply)
    local entries = GATE.GetAllCustomAssaults()
    if not entries or #entries == 0 then sendReply("no custom assaults loaded"); return end
    -- Unique row names, in order
    local seen, rows = {}, {}
    for _, e in ipairs(entries) do
        if not seen[e.row] then seen[e.row] = true; rows[#rows + 1] = e.row end
    end
    sendReply("rows: " .. table.concat(rows, ", "))
end


-- ============================================================
-- Parse one chat line. Returns silently if it isn't a "/gate" command.
-- ============================================================
local function handleChat(controller, text)
    if not text then return end

    -- Split on whitespace
    local tokens = {}
    for tok in text:gmatch("%S+") do tokens[#tokens + 1] = tok end
    if #tokens == 0 then return end
    if tokens[1]:lower() ~= PREFIX then return end

    local cmdName = (tokens[2] or "help"):lower()
    local handler = COMMANDS[cmdName]
    if not handler then
        reply(controller, "unknown command: " .. cmdName .. " (try /gate help)")
        return
    end

    -- args = tokens after the command name
    local args = {}
    for i = 3, #tokens do args[#args + 1] = tokens[i] end

    local function sendReply(msg) reply(controller, msg) end
    handler(controller, args, sendReply)
end


function CC.Register()
    RegisterHook(CHAT_HOOK, function(self, MessageToSend)
        if not STATE.ModEnabled then return end
        -- Only the authority executes commands. (The hook is normally registered
        -- on the server only, but guard anyway in case it's wired elsewhere.)
        if not Utils.IsAuthority() then return end

        local controller = self:get()
        if IsNotValid(controller) then return end

        -- FString param -> Lua string
        local ok, text = pcall(function()
            local v = MessageToSend:get()
            return v and v:ToString() or nil
        end)
        if not ok or not text then return end

        local ok2, err = pcall(handleChat, controller, text)
        if not ok2 then LogBad("ChatCommand error: " .. tostring(err)) end
    end)

    Log("ChatCommands registered (/gate ...)")
end

return CC
