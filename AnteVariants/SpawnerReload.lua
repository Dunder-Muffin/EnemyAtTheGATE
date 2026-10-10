-- =======================================================================
-- SpawnerReload - re-require AnteData/SpawnerData and adopt its tables IN
-- PLACE via the /reloadspawns chat command. No UE4SS mod restart needed.
--
-- WHY: same reason as VariantReload (SHIFT+M leaks hooks = use-after-free),
-- but for the spawner/placement tables instead of the variant defs. Editing
-- one coord used to cost a full restart.
--
-- WHY IT'S SAFE: every consumer reads SPAWNERDATA.Spawners / .PlacedSpawns /
-- .Rules(...) at USE time - nobody caches a sub-table - so refilling the
-- module table is enough for the next tick to see the new data.
--
-- SCOPE:
--   * Picked up: any edit to SpawnerData (and the data files it requires) -
--     entries, Phases, props, HardVariants, and the resolver functions.
--   * NOT picked up: SpawnerHooks / EventUtils logic, Enums, hook
--     registrations. Those still need a real restart, from the MAIN MENU.
--   * NPCs already spawned keep what they are. Spawner CONFIG (SpawnAs,
--     Count, Disabled) is re-applied to live spawners; the bodies already
--     out are not retro-changed.
--
-- ONE-WAY on a spawner already streamed in: applySpawnerRules returns early
-- on a nil entry and nothing records the pre-Disabled cap, so DELETING an
-- entry, or dropping Disabled from one, leaves the old config standing until
-- that sector streams out and back. Changing or adding rules works.
--
-- ATOMIC: the re-require is pcall'd against a saved package.loaded, so a
-- syntax error leaves the running data untouched - fix and run it again.
--
-- Pairs with /resetspawns (DebugUtils.ResetSpawnerCooldowns): this command
-- swaps the DATA, that one clears the day/Count/wipe cooldowns holding a
-- group back. Editing a Count usually wants both.
-- =======================================================================
---@diagnostic disable: undefined-field, undefined-global

local Utils = require("AnteUtils.Utils")
local STATE = require("AnteCore.State")

local SR = {}

local SPAWNER_MODULE = "AnteData.SpawnerData"

-- The whole data island, cleared together. Requiring SpawnerData against a CACHED
-- sibling would re-run the top file and silently keep the old tables underneath -
-- the same trap VariantReload has with AnteNPCs/*Helpers.
--   * A name that isn't loaded is skipped, so a future data file can be listed early.
local DATA_MODULES = {
    "AnteData.PlacedSpawnData",
}

local function countKeys(t)
    local n = 0
    if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end
    return n
end

-- Tracking for a coord that no longer exists is a body nothing owns: drop the entry so
-- another placement can adopt it, and say so, because the body itself stays standing.
local function prunePlacedTracking(placed)
    local orphans = {}
    for key in pairs(STATE.PlacedSpawnActors or {}) do
        if not placed[key] then
            orphans[#orphans + 1] = key
            STATE.PlacedSpawnActors[key] = nil
        end
    end
    for key in pairs(STATE.PlacedSpawnLastPos or {}) do
        if not placed[key] then STATE.PlacedSpawnLastPos[key] = nil end
    end
    for _, key in ipairs(orphans) do
        Utils.LogBad("SpawnerReload - [" .. key .. "] is gone from PlacedSpawns; its NPC is still"
            .. " in the world and now untracked (/clear it, or it may be re-adopted nearby)")
    end
    return #orphans
end

-- Returns (true, "<n> spawners / <n> placements") or (false, error).
function SR.Reload()
    local LIVE = package.loaded[SPAWNER_MODULE]
    if type(LIVE) ~= "table" then return false, "SpawnerData is not loaded" end

    local saved = { [SPAWNER_MODULE] = LIVE }
    package.loaded[SPAWNER_MODULE] = nil
    for _, name in ipairs(DATA_MODULES) do
        if package.loaded[name] then
            saved[name] = package.loaded[name]
            package.loaded[name] = nil
        end
    end

    local ok, fresh = pcall(require, SPAWNER_MODULE)
    if not ok or type(fresh) ~= "table" then
        for name, mod in pairs(saved) do package.loaded[name] = mod end
        local err = ok and "module did not return a table" or tostring(fresh)
        Utils.LogBad("SpawnerReload - FAILED: " .. err)
        Utils.LogBad("SpawnerReload - old spawner data still active")
        return false, err
    end

    -- Adopt the fresh contents onto the LIVE table rather than replacing it: four files hold
    -- this exact table as a module-local, so a swap would be invisible to all of them.
    -- Functions come across too (SD.Resolve's phaseCache is an upvalue, so this resets it).
    for k in pairs(LIVE) do if fresh[k] == nil then LIVE[k] = nil end end
    for k, v in pairs(fresh) do LIVE[k] = v end
    package.loaded[SPAWNER_MODULE] = LIVE   -- keep one identity for any later lazy require

    local nSpawners, nPlaced = countKeys(LIVE.Spawners), countKeys(LIVE.PlacedSpawns)

    if Utils.IsAuthority() then
        pcall(function() require("AnteVariants.SpawnerHooks").ValidateSpawnerData() end)

        -- Clear the arrival edges and stream-gate backoffs, or a placement added this second
        -- sits out the previous entry's penalty before it is even tried.
        pcall(function() require("ModuleStory.EventUtils").ResetPlacedRuntime() end)
        prunePlacedTracking(LIVE.PlacedSpawns or {})

        -- Off the chat hook: this walks every spawner in the world and writes its config.
        -- Rows are restored to vanilla first so an EDITED SpawnAs maps from the original list
        -- rather than from what the previous rules already wrote.
        Utils.QueueWork(function()
            require("AnteVariants.SpawnerHooks").ApplySpawnOverrides(true)
            Utils.Log("SpawnerReload - re-applied config to live spawners")
        end, 0)
    end

    Utils.Log(string.format("SpawnerReload - reloaded %d spawners / %d placements", nSpawners, nPlaced))
    return true, string.format("%d spawners / %d placements", nSpawners, nPlaced)
end

return SR
