-- =======================================================================
-- FileIO - manages persistent values per game world in JSON.
--   * One-time Story event flags.
--   * Respawn times for multicount spawners (no native cooldown for these).
--   * Respawn times for fake/placed spawn points.
--   * A small generic file for session meta (e.g. last-selected dev keybind category).
-- =======================================================================
---@diagnostic disable: undefined-field, undefined-global

local json = require("AFUtils.json")
local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local Utils = require("AnteUtils.Utils")

local Log = Utils.Log
local LogDebug = Utils.LogDebug
local LogBad = Utils.LogBad

local IO = {}

local source = debug.getinfo(1, "S").source
if source:sub(1, 1) == "@" then source = source:sub(2) end
local scriptDir = source:match("(.+[\\/])") or "./"
local SAVE_DIR = scriptDir .. "../../saved/"


local function worldKey()
    local name = STATE.WorldName
    if not name or name == "" then return "default" end
    return name
end

function IO.WorldPath()
    return SAVE_DIR .. worldKey() .. ".json"
end

-- A NON-world-scoped file under saved/ (e.g. the dev keybind selection, which should persist
-- across worlds and mod restarts). Pair with IO.ReadJson / IO.WriteJson.
function IO.MiscPath(name)
    return SAVE_DIR .. name
end


-- Recursive default-merge to keep new schemas from destroying old schema data
local function mergeDefaults(defaults, data)
    if type(defaults) ~= "table" then return data end
    if type(data) ~= "table" then data = {} end
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            data[k] = mergeDefaults(v, data[k])
        elseif data[k] == nil then
            data[k] = v
        end
    end
    return data
end


function IO.ReadJson(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    if not content or content == "" then return nil end

    local ok, result = pcall(json.decode, content)
    if not ok or type(result) ~= "table" then
        LogBad("FileIO - JSON decode failed for " .. path)
        return nil
    end
    return result
end


-- mkdir is a shell spawn (os.execute) and is blocking on the game thread
--   * only do this once when a write fails
--   * can cause long freezes if called multiple times
local dirEnsured = false
local function ensureDir()
    if dirEnsured then return end
    dirEnsured = true
    pcall(function() os.execute('mkdir "' .. SAVE_DIR .. '" 2>nul') end)
end

local function writeFile(path, data)
    local f = io.open(path, "w+")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

function IO.WriteJson(path, tableData)
    local ok, encoded = pcall(json.encode, tableData)
    if not ok then return false, "encode failed" end

    -- Temp file / rename so no midwrite saves happen
    local tmp = path .. ".tmp"
    if not writeFile(tmp, encoded) then
        ensureDir() -- saved/ may be missing - create once, retry
        if not writeFile(tmp, encoded) then return false, "write failed (saved/ dir?)" end
    end

    os.remove(path)
    if os.rename(tmp, path) then return true end

    -- rename fell over (rare FS states); direct-write fallback.
    local okF = writeFile(path, encoded)
    os.remove(tmp)
    return okF, okF and nil or "rename+write failed"
end


-- Load STATE.StoryData for the current world, merging in any new defaults.
--   * Creates the file on first run.
function IO.LoadStoryData()
    local defaults = STATE.StoryDataDefaults or {}
    local saved = IO.ReadJson(IO.WorldPath())
    -- Deep-copy defaults so we never mutate the schema table itself.
    STATE.StoryData = mergeDefaults(defaults, saved or {})

    if not saved then
        LogDebug("FileIO - no save for '" .. worldKey() .. "', creating", SETTINGS.DEBUG_STORY)
        IO.SaveStoryData()
    else
        LogDebug("FileIO - loaded StoryData for '" .. worldKey() .. "'", SETTINGS.DEBUG_STORY)
    end
end


function IO.SaveStoryData()
    local ok, err = IO.WriteJson(IO.WorldPath(), STATE.StoryData or {})
    if not ok then LogBad("FileIO - SaveStoryData failed: " .. tostring(err)) end
    return ok
end

return IO
