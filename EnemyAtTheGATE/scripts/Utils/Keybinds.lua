-- ============================================================
-- Debug keybinds. Role-aware (see AnteUp for the pattern):
--   * HOST / single-player (authority): run the action directly, as before.
--   * CLIENT (joined a dedicated/remote server): the action runs server-side,
--     so the bind sends a "/gate <cmd>" chat line (client->server RPC) that
--     Hooks/ChatCommands.lua executes on the server. Query binds get a
--     server->client chat reply. Client feedback uses the console Log, NOT the
--     chat UMG (touching the chat widget from a keybind on a pure client risks
--     a Slate paint crash - same reason AnteUp avoids it).
--
-- GATED BY CONFIG.DEBUG_KEYBIND, separately from CONFIG.DEBUG_COMMAND. These
-- binds overlap AnteUp's, so running both mods usually means DEBUG_KEYBIND=false
-- and driving GATE through /gate chat commands instead.
--
-- NOTE: keybinds only fire on a machine with input, and they are registered in
-- InitMod, which on this mod is driven by the ProcessSpawns_Quick (server) tick.
-- For a CLIENT to get these binds, KB.Register() must be called from a
-- client-side bootstrap - see the wiring note in Hooks/ChatCommands.lua and the
-- summary. The cycling binds resolve the row locally (the client has the GATE
-- table) and send only "/gate setnext <row> <idx>".
--
-- [CTRL]  + [END]       - Redraw the next assault
-- [SHIFT] + [END]       - Force start the next assault
-- [NUMPAD 6]            - Move clock ahead 1 hour
-- [SHIFT] + [RIGHT]     - Cycle forward through custom assaults (sets next)
-- [SHIFT] + [LEFT]      - Cycle backward through custom assaults (sets next)
-- [CTRL]  + [RIGHT]     - Cycle forward, skipping to next assault type
-- [CTRL]  + [LEFT]      - Cycle backward, skipping to previous assault type
-- [SHIFT] + [O]         - Force save world + character
-- [SHIFT] + [UP]        - Show current assault
-- [SHIFT] + [DOWN]      - Last custom assault
-- [CTRL] + [SHIFT] + P  - Remove all nearby NPCs and loose items
-- [CTRL] + [SHIFT] + T  - Make Disc/LaserTurrets require no power
-- ============================================================

---@diagnostic disable: undefined-global, undefined-field, unused-local, param-type-mismatch

local AFUtils = require("AFUtils.AFUtils")
local STATE   = require("Data.STATE")
local Utils   = require("Utils.Utils")
local Debug   = (require "Utils.UtilsDebug")
local GATE    = require("Managers.GATEManager")

local KB = {}

-- Persistent index for cycling through assaults to test them
local custIdx = 0


-- ============================================================
-- Role-aware helpers
-- ============================================================

-- Send a "/gate ..." command to the server (client side). Called directly (not
-- queued): on a client the QueueManager isn't drained by the server tick, and a
-- single chat-send RPC is safe to fire from the bind.
local function sendCmd(cmd)
    local pc = AFUtils.GetMyPlayerController()
    if IsValid(pc) then
        pc:Request_SendTextChatMessage(cmd)
        Utils.Log("[GATE] sent: " .. cmd)
    else
        Utils.Log("[GATE] sendCmd: no player controller")
    end
end

-- Run host-side work on the next clean game tick instead of in the keybind frame.
--
-- RegisterKeyBind callbacks fire inside a UE4SS Slate-tick intercept. Touching
-- actors or the chat UMG there (FindFirstOf, any BP call, Utils.Chat) corrupts
-- the Slate tree -> access violation, and ExecuteInGameThread does NOT help
-- because it flushes into the same intercept. The only safe thing a bind may do
-- is pure Lua, so everything below is a table.insert into the QueueManager and
-- runs later on the game-tick drain.
local function hostQueue(fn)
    Utils.QueueSpawn(fn, 0)
end

-- Feedback: chat on host (renders), console log on client (chat UMG is unsafe
-- from a keybind on a pure client).
local function notify(msg)
    if Utils.IsAuthority() then
        hostQueue(function() Utils.Chat(msg) end)
    else
        Utils.Log("[GATE] " .. msg)
    end
end

-- Apply a chosen custom-assault entry as the next assault. Role-aware.
local function applyNext(entry, label)
    if Utils.IsAuthority() then
        STATE.DebugQueuedAssault = entry           -- pure Lua, safe in the bind
        hostQueue(function()
            Utils.SetNextAssaultType(entry.row)    -- FindFirstOf + BP call
            Utils.Chat(label)
        end)
    else
        notify(label)
        sendCmd(string.format("/gate setnext %s %d", entry.row, entry.idx or 1))
    end
end



-- ============================================================
-- Registration
-- ============================================================

function KB.Register()

    -- ------------------------------------------------
    -- Shuffle next native assault and display it
    -- ------------------------------------------------
    RegisterKeyBind(Key.END, { ModifierKey.CONTROL }, function()
        if Utils.IsAuthority() then
            -- ShuffleAssault does FindFirstOf + up to 1000 SelectRandomAssaultType
            -- calls + a chat write - never in the bind frame.
            hostQueue(Utils.ShuffleAssault)
        else
            sendCmd("/gate shuffle")
        end
    end)


    -- ------------------------------------------------
    -- Force an assault to begin
    -- * DevNote: We queue functions from keybinds, not call directly - keybind
    --     hooks fire inside a ProcessEvent intercept, which can cause writes to
    --     AIDirector to be discarded, or crash when spawning actors.
    -- ------------------------------------------------
    RegisterKeyBind(Key.END, { ModifierKey.SHIFT }, function()
        if not Utils.IsAuthority() then sendCmd("/gate force"); return end
        Utils.QueueSpawn(function()
            local director = FindFirstOf("Abiotic_AIDirector_C")
            if not director or IsNotValid(director) then
                Utils.Chat("[GATE] No director found")
                return
            end
            director:ServerForceBeginAssault()
            Utils.Chat("[GATE] Assault triggered")
        end, 0)
    end)

    -- ------------------------------------------------
    -- Advance time 1 hour
    -- ------------------------------------------------
    RegisterKeyBind(Key.NUM_SIX, {}, function()
        if Utils.IsAuthority() then
            -- AdvanceTime does NOT queue internally (unlike the other Debug.*):
            -- it drives the day/night manager + a chat write directly.
            hostQueue(function() Debug.AdvanceTime(1) end)
        else
            sendCmd("/gate time 1")
        end
    end)

    -- ------------------------------------------------
    -- Cycle through assaults and set current as the next assault (+1)
    -- ------------------------------------------------
    RegisterKeyBind(Key.RIGHT_ARROW, { ModifierKey.SHIFT }, function()
        local entries = GATE.GetAllCustomAssaults()
        if not entries or #entries == 0 then
            notify("No custom assaults loaded")
            return
        end

        custIdx = (custIdx % #entries) + 1
        local entry = entries[custIdx]

        applyNext(entry, string.format("[%d/%d] %s  %s",
            custIdx, #entries, entry.data.Name or entry.row, entry.row))
    end)


    -- ------------------------------------------------
    -- Cycle through assaults and set current as the next assault (-1)
    -- ------------------------------------------------
    RegisterKeyBind(Key.LEFT_ARROW, { ModifierKey.SHIFT }, function()
        local entries = GATE.GetAllCustomAssaults()
        if not entries or #entries == 0 then
            notify("No custom assaults loaded")
            return
        end

        custIdx = custIdx - 1
        if custIdx < 1 then custIdx = #entries end
        local entry = entries[custIdx]

        applyNext(entry, string.format("[%d/%d] %s  %s ",
            custIdx, #entries, entry.data.Name or entry.row, entry.row))
    end)


    -- ------------------------------------------------
    -- Cycle through assaults but jump to the next category
    -- ------------------------------------------------
    RegisterKeyBind(Key.RIGHT_ARROW, { ModifierKey.CONTROL }, function()
        local entries = GATE.GetAllCustomAssaults()
        if not entries or #entries == 0 then
            notify("No custom assaults loaded")
            return
        end
        local n = #entries
        local baseRow = (custIdx >= 1 and custIdx <= n) and entries[custIdx].row or nil

        -- scan forward until the row changes
        local idx = custIdx >= 1 and custIdx or 0
        for i = 1, n do
            idx = (idx % n) + 1
            if entries[idx].row ~= baseRow then break end
        end
        custIdx = idx

        local entry = entries[custIdx]
        applyNext(entry, string.format("[%d/%d] %s  %s",
            custIdx, n, entry.data.Name or entry.row, entry.row))
    end)

    -- ------------------------------------------------
    -- Cycle through assaults but jump to the previous category
    -- ------------------------------------------------
    RegisterKeyBind(Key.LEFT_ARROW, { ModifierKey.CONTROL }, function()
        local entries = GATE.GetAllCustomAssaults()
        if not entries or #entries == 0 then
            notify("No custom assaults loaded")
            return
        end
        local n = #entries
        local baseRow = (custIdx >= 1 and custIdx <= n) and entries[custIdx].row or nil
        local startIdx = custIdx >= 1 and custIdx or 1

        -- Step 1: scan backward past the current type to find a different row
        local searchIdx = startIdx
        local prevRow
        for i = 1, n do
            searchIdx = (searchIdx - 2 + n) % n + 1
            if entries[searchIdx].row ~= baseRow then
                prevRow = entries[searchIdx].row
                break
            end
        end
        if not prevRow then return end  -- all entries share the same row

        -- Step 2: walk backward from searchIdx while the row still matches,
        -- to land on the FIRST entry of that type group
        local firstIdx = searchIdx
        for i = 1, n do
            local testIdx = (firstIdx - 2 + n) % n + 1
            if entries[testIdx].row == prevRow then
                firstIdx = testIdx
            else
                break
            end
        end
        custIdx = firstIdx

        local entry = entries[custIdx]
        applyNext(entry, string.format("[%d/%d] %s  %s",
            custIdx, n, entry.data.Name or entry.row, entry.row))
    end)

    -- ------------------------------------------------
    -- Show current assault
    -- ------------------------------------------------
    RegisterKeyBind(Key.UP_ARROW, { ModifierKey.SHIFT }, function()
        if not Utils.IsAuthority() then sendCmd("/gate current"); return end

        hostQueue(function()
            local director, nativeAssaultName = Utils.GetNativeAssaultName()
            if not director then
                Utils.Chat("[GATE] No director found")
                return
            end

            local isActive   = director:IsAssaultHappening()
            local lastCustom = STATE.LastCustomAssault
            local queued     = STATE.DebugQueuedAssault

            if not isActive then
                -- If we put an assault in DebugQueued, display it
                if queued then
                    Utils.Chat(string.format("[GATE] Active. Debug queued: %s  Name=%s",
                        queued.data.Name or queued.row,
                        queued.row))
                elseif lastCustom then
                    Utils.Chat(string.format("[GATE] Inactive. Last: %s [SP %s-%s])",
                        lastCustom.Name or nativeAssaultName,
                        lastCustom.StoryMin or 0,
                        lastCustom.StoryMax or 999))
                else
                    Utils.Chat("[GATE] Inactive. No previous assault data")
                end
                return
            end

            -- Assault is running - show what was actually applied
            if lastCustom then
                Utils.Chat(string.format("[GATE] %s  [SP %d-%d]  (%s)",
                    lastCustom.Name or nativeAssaultName,
                    lastCustom.StoryMin or 0,
                    lastCustom.StoryMax or 999,
                    nativeAssaultName))
            else
                Utils.Chat("[GATE] " .. nativeAssaultName)
            end
        end)
    end)


    -- ------------------------------------------------
    -- Show last assault
    -- ------------------------------------------------
    RegisterKeyBind(Key.DOWN_ARROW, { ModifierKey.SHIFT }, function()
        if not Utils.IsAuthority() then sendCmd("/gate last"); return end

        local assault = STATE.LastCustomAssault
        if not assault then
            notify("No custom assault applied this session")
            return
        end
        notify(string.format("[GATE] Last Assault - %s [%d - %d]",
            assault.Name or "?",
            assault.StoryMin or 0,
            assault.StoryMax or 999))
    end)




    -- ------------------------------------------------
    -- Kill nearby NPCs, then clear corpses + dropped items after 3s
    --
    -- * NOTE: Don't directly call BP functions from keybinds. KB calls end up
    --    calling another ProcessEvent which can crash; Debug.* queue their own
    --    work via Utils.QueueSpawn.
    -- ------------------------------------------------
    RegisterKeyBind(Key.P, { ModifierKey.SHIFT, ModifierKey.CONTROL }, function()
        -- ** SINGLE PLAYER / HOSTED ONLY **
        --if not Utils.IsAuthority() then sendCmd("/gate clear"); return end

        Debug.P1KillNearby()            -- queues at +0s (runs next game tick)
        Debug.P1ClearCorpsesItems(3000) -- queues at +3s (after kill+destroy settle)
    end)


    -- ------------------------------------------------
    -- Force-save world and player
    -- * Player can get rolled back if there's a GC crash when exiting the game
    -- ------------------------------------------------
    RegisterKeyBind(Key.O, { ModifierKey.SHIFT }, function()
        -- ** SINGLE PLAYER / HOSTED ONLY **
        --if not Utils.IsAuthority() then sendCmd("/gate save"); return end

        -- Request_ForceWorldSave is the heaviest re-entrant ProcessEvent in the
        -- mod - running the save pipeline from the bind's Slate frame is the
        -- classic access violation. Queue the whole body.
        hostQueue(function()
            local controller = FindFirstOf("Abiotic_PlayerController_C")
            if not controller or IsNotValid(controller) then
                Utils.Chat("[GATE] ForceSave: no player controller")
                return
            end

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

            Utils.Chat("[GATE] Saved game")
        end)
    end)


    -- ------------------------------------------------
    -- Make active DiscTurrets and LaserTurrets not require power/laser
    -- ------------------------------------------------
    RegisterKeyBind(Key.T, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
        if not Utils.IsAuthority() then sendCmd("/gate turrets"); return end
        Utils.QueueSpawn(function()
            local laserCount, discCount = Utils.FreeAllTurrets()
            Utils.Chat(string.format("[GATE] Turrets freed: %d laser, %d disc", laserCount, discCount))
        end, 0)
    end)



    -- ------------------------------------------------
    -- Play a sound for testing. Change DEBUG_SOUND_PATH to the asset you want to hear.
    -- ------------------------------------------------
    -- local Enums = require("Data.Enums")
    -- local DEBUG_SOUND_PATH = Enums.SOUNDS.PORTAL_NIGHTREALM
    -- RegisterKeyBind(Key.S, { ModifierKey.CONTROL }, function()
    --     Utils.Broadcast2DSound(DEBUG_SOUND_PATH)
    --     Utils.Chat("[GATE] Playing: " .. DEBUG_SOUND_PATH)
    -- end)


end

return KB
