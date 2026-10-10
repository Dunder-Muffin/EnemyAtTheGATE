-- =======================================================================
-- ModuleCheats/ConsoleCheats - the ModuleCheats cheats, typed into the game console (~ or F10).
--
-- SETTINGS.DEBUG_CONSOLE_CHEATS (SETTINGS_DEBUG, off in exports), and no other debug flag. SINGLE
-- PLAYER ONLY: a host alone in its world. A joined client, or a host with other players in, is
-- refused (the chat commands under DEBUG_CHEATS + DEBUG_CHAT_COMMANDS cover multiplayer).
--   noclip, god, invis, craft, topup, refill, instantfishing, trapleyak [krasue], trapkrasue
--   (or trapkrause), settime <h|day|night> (or time), resetportals, buffs. "cheats" lists them with
--   their arguments.
--   * Every name also answers to "au-<name>", the chat commands' spelling.
--   * Names match CheatConsoleCommands' where the cheat is the same, so its players need nothing
--     new. Don't run both: each mod toggles its own copy of noclip and god.
--
-- THREADING: a console handler runs inside UE4SS's Slate-tick intercept (CLAUDE.md section 2). It
-- only parses, answers in the console and queues the cheat; the player count is read in the work.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE   = require("AnteCore.State")
local Utils   = require("AnteUtils.Utils")
local AFUtils = require("AFUtils.AFUtils")
local CH      = require("ModuleCheats.Cheats")

local Log    = Utils.Log
local LogBad = Utils.LogBad

local CC = {}

-- "on" / "off" -> true / false; anything else = nil, which ToggleFishing reads as flip.
local function onOff(rest)
    local a = (rest or ""):lower()
    if a == "on" or a == "true" then return true end
    if a == "off" or a == "false" then return false end
    return nil
end

-- Aliases are CheatConsoleCommands' spellings of the same cheat.
local COMMANDS = {
    { Name = "noclip", Args = "[on|off]", Help = "fly through walls",
      Run = function(pawn, rest) CH.NoClip(pawn, rest) end },
    { Name = "god", Aliases = { "godmode", "health" }, Args = "[on|off]", Help = "invincible + full heal, kept on",
      Run = function(pawn, rest) CH.God(pawn, rest) end },
    { Name = "invis", Aliases = { "invisible" }, Args = "[on|off]", Help = "NPCs can't target you",
      Run = function(pawn, rest) CH.Invis(pawn, rest) end },
    { Name = "craft", Aliases = { "freecraft" }, Args = "[on|off]", Help = "free crafting, building and trades",
      Run = function(pawn, rest) CH.FreeCraft(pawn, rest) end },
    { Name = "topup", Help = "full food and water, rested, clean, curable debuffs gone",
      Run = function(pawn) CH.TopUp(pawn) end },
    { Name = "refill", Args = "[liquid]", Help = "charge carried energy items and fill the held one",
      Run = function(pawn, rest) CH.Refill(pawn, rest) end },
    { Name = "instantfishing", Args = "[on|off]", Help = "skip the fishing minigame",
      Run = function(_, rest) CH.ToggleFishing(onOff(rest)) end },
    { Name = "trapleyak", Args = "[krasue]", Help = "trap the Leyak (or Krasue) in the nearest containment",
      Run = function(pawn, rest) CH.TrapLeyak(pawn, rest) end },
    { Name = "trapkrasue", Aliases = { "trapkrause", "au-trapkrause" }, Help = "trap the Krasue in the nearest containment",
      Run = function(pawn) CH.TrapLeyak(pawn, "krasue") end },
    { Name = "settime", Aliases = { "time" }, Args = "<0-23|day|night>", Help = "jump the clock forward to that hour",
      Run = function(_, rest) CH.SetTime(rest) end },
    { Name = "resetportals", Aliases = { "resetvignettes" }, Help = "respawn portal and vignette enemies now",
      Run = function() CH.ResetVignettes() end },
    { Name = "buffs", Help = "list your buffs and debuffs in chat",
      Run = function(pawn) CH.ListBuffs(pawn) end },
}

-- A console command can reach a handler twice; the same line inside this window is one command.
local DEDUPE_MS = 300
local lastLine, lastAt = nil, 0

local function say(ar, msg)
    pcall(function() ar:Log("AnteUp2: " .. msg) end)
end

-- The arguments as one string. Parameters may or may not lead with the command name itself.
local function argsOf(name, params)
    local list = {}
    if type(params) == "table" then
        for _, p in ipairs(params) do list[#list + 1] = tostring(p) end
    end
    if list[1] and list[1]:lower() == name then table.remove(list, 1) end
    return table.concat(list, " ")
end

local function listCommands(ar)
    say(ar, "cheats - single player only. [on|off] or bare to toggle; each also works as au-<name>")
    for _, c in ipairs(COMMANDS) do
        local names = c.Name
        if c.Aliases then names = names .. " / " .. table.concat(c.Aliases, " / ") end
        if c.Args then names = names .. " " .. c.Args end
        pcall(function() ar:Log(string.format("  %-34s %s", names, c.Help)) end)
    end
end

-- True = handled. A refusal returns false so the engine (or another mod) may still answer.
local function run(cmd, name, params, ar)
    local rest = argsOf(name, params)
    local line = rest ~= "" and (name .. " " .. rest) or name
    local now = Utils.NowMs()
    if line == lastLine and now - lastAt < DEDUPE_MS then return true end
    lastLine, lastAt = line, now

    if not STATE.ModEnabled then
        say(ar, name .. " - load a world first")
        return false
    end
    if STATE.Role ~= "HOST" then
        say(ar, name .. " - single player only")
        return false
    end

    say(ar, line)
    Utils.QueueWork(function()
        if #Utils.LivePlayers() > 1 then
            Log("ConsoleCheats - refused '" .. line .. "': other players are in this world")
            pcall(function() AFUtils.DisplayTextChatMessage("Cheats are single player only") end)
            return
        end
        local pawn
        pcall(function() pawn = AFUtils.GetMyPlayerController():K2_GetPawn() end)
        if Utils.IsActorInvalid(pawn) then
            LogBad("ConsoleCheats - '" .. line .. "': no player pawn")
            return
        end
        Log("ConsoleCheats - " .. line)
        local ok, err = pcall(cmd.Run, pawn, rest)
        if not ok then LogBad("ConsoleCheats - '" .. line .. "' failed: " .. tostring(err)) end
    end, 0)
    return true
end

-- Once per session on a renderer (main.lua InitMod). Handlers are global, so each one checks the
-- world it lands in.
function CC.Register()
    local count = 0
    local function bind(name, handler)
        local ok, err = pcall(RegisterConsoleCommandGlobalHandler, name, handler)
        if ok then count = count + 1
        else LogBad("ConsoleCheats - '" .. name .. "' not registered: " .. tostring(err)) end
    end

    for _, c in ipairs(COMMANDS) do
        local names = { c.Name, "au-" .. c.Name }
        for _, a in ipairs(c.Aliases or {}) do names[#names + 1] = a end
        for _, n in ipairs(names) do
            bind(n, function(_, params, ar) return run(c, n, params, ar) end)
        end
    end
    for _, n in ipairs({ "cheats", "au-cheats" }) do
        bind(n, function(_, _, ar)
            listCommands(ar)
            return true
        end)
    end

    Log("ConsoleCheats - " .. count .. " console commands registered (single player only; type cheats)")
end

return CC
