-- =======================================================================
-- VariantReload - re-require the variant DEFINITION files and rebuild the
-- registry IN PLACE (same table object) via the /reload chat command.
-- No UE4SS mod restart needed.
--
-- WHY: SHIFT+M (RestartCurrentMod) leaks one hook - WorldFlagsChanged keeps
-- firing into the destroyed Lua state, which is a use-after-free. Periodic
-- hooks (UpdateNPCDebugInfo @1s, ProcessSpawns_Quick @10Hz) fire even on an
-- empty world, so a bare restart can crash too. /reload sidesteps all of
-- it: hooks and infra stay put, only the def tables get rebuilt.
--
-- SCOPE:
--   * Picked up: edits inside an already-loaded AnteNPCs/*.lua or the two
--     ModulePets tamed-def files (knobs, BasicStats, Stats/Visuals/OnTick,
--     helpers, local tables).
--   * NOT picked up: brand-new variant files, Enums/Utils/engine edits, hook
--     registrations. Those need a real restart, from the MAIN MENU (quiet
--     world) given the hook leak above.
--   * Live NPCs keep the def they mutated with (their OnTick/handler
--     closures were captured then) - /clear + /spawn to see new values.
--     Module-local per-actor state (e.g. sciDrank) resets to fresh tables.
--
-- ATOMIC: every file is re-required FIRST (pcall each). Any failure
-- restores package.loaded and leaves the registry untouched - a broken
-- edit never bricks the running session. Fix the file and /reload again.
--
-- The merge below mirrors AnteVariants/Variants.lua (Name stamp, duplicate
-- name/Id checks) - keep the two in sync.
-- =======================================================================
---@diagnostic disable: undefined-field, undefined-global

local Utils = require("AnteUtils.Utils")
local VARIANTS = require("AnteVariants.Variants")   -- the live registry TABLE (kept by reference everywhere)

local VR = {}

-- A def SOURCE is a table of name -> def-table, nothing else.
--   * AnteNPCs also holds non-def INFRA: AnteNPCs.HexedTreeStalker is a RESOURCE NODE we
--     drive like an NPC (it animates and attacks nearby players on its own; we just move it),
--     so it lives there but returns FUNCTIONS and is required by ModuleStory, not Variants.lua.
--   * Shape-check the CURRENTLY-loaded module so those are excluded before we ever
--     clear/re-require them - reloading infra would orphan the copies StoryManager/Events hold.
local function isDefSource(mod)
    if type(mod) ~= "table" then return false end
    for _, v in pairs(mod) do
        if type(v) ~= "table" then return false end
    end
    return true
end

-- The def modules = everything under AnteNPCs.* that is currently loaded AND def-shaped,
-- plus the ModulePets files that register variants (only if loaded this session).
--   * Derived from package.loaded, so a future AnteNPCs file is covered automatically
--     once a restart has loaded it - no second require-list to maintain.
--   * AnteNPCs.<Base>Helpers files (the machinery a def file requires) are reloaded too,
--     but never merged - classified BY NAME, not shape, so a helper is never mistaken
--     for a def source. Without this, /reload would re-require a def against a STALE
--     cached helper, and since helpers hold the logic, most edits would silently no-op.
local function collectModuleNames()
    local names, helpers = {}, {}
    for name, mod in pairs(package.loaded) do
        if type(name) == "string" and name:find("^AnteNPCs%.") then
            if name:find("Helpers$") then
                helpers[#helpers + 1] = name
            elseif isDefSource(mod) then
                names[#names + 1] = name
            else
                Utils.Log("VariantReload - skipping non-def module: " .. name)
            end
        end
    end
    for _, n in ipairs({ "ModulePets.TamedPests", "ModulePets.TamedPeccary", "ModulePets.TamedLamogi" }) do
        if package.loaded[n] then names[#names + 1] = n end
    end
    -- ModulePets helpers are NOT under AnteNPCs.*, so they need the same explicit listing or an
    -- edit to one would reload the def against a stale cached helper (= silently no-op).
    for _, n in ipairs({ "ModulePets.TamedLamogiHelpers" }) do
        if package.loaded[n] then helpers[#helpers + 1] = n end
    end
    table.sort(names)     -- deterministic merge order (stable duplicate-check logs)
    table.sort(helpers)
    return names, helpers
end

-- Wipe + refill the registry IN PLACE.
--   * Assigning nil to existing keys during pairs() is legal Lua; only ADDING
--     mid-iteration is undefined - the refill is a separate pass.
local function mergeInto(registry, freshMods, names)
    for k in pairs(registry) do registry[k] = nil end

    local seenIds = {}
    local count = 0
    for _, moduleName in ipairs(names) do
        for name, variant in pairs(freshMods[moduleName]) do
            -- Belt over the isDefSource filter: a def file that grows a stray helper export
            -- later must degrade to a loud skip, not an in-merge error after the wipe.
            if type(variant) ~= "table" then
                Utils.LogBad("VariantReload - " .. moduleName .. "." .. tostring(name)
                    .. " is not a def table; skipped")
            else
                if registry[name] then
                    Utils.LogBad("VariantReload - duplicate variant definition: " .. name)
                end
                variant.Name = name
                if variant.Id then
                    if seenIds[variant.Id] then
                        Utils.LogBad(string.format("VariantReload - duplicate variant ID %d (%s and %s)",
                            variant.Id, name, seenIds[variant.Id]))
                    end
                    seenIds[variant.Id] = name
                end
                registry[name] = variant
                count = count + 1
            end
        end
    end
    return count
end

-- Returns (true, defCount) or (false, "file: error").
--   * Pure Lua + disk reads only - no UE asset loads, no BP calls - so it is safe
--     to run directly from the chat hook.
function VR.Reload()
    local names, helpers = collectModuleNames()

    -- Helpers FIRST so a syntax error in one is attributed to it, not to the def that pulls it in.
    local all = {}
    for _, n in ipairs(helpers) do all[#all + 1] = n end
    for _, n in ipairs(names) do all[#all + 1] = n end

    -- Phase 1: re-require everything, all-or-nothing.
    --   * ALL entries are cleared up front so any def-file-to-def-file require during the
    --     re-require pass resolves to a FRESH copy, never a half-stale mix
    --     (with per-file clearing, whoever sorted later kept the old one).
    local old, fresh = {}, {}
    for _, n in ipairs(all) do
        old[n] = package.loaded[n]
        package.loaded[n] = nil
    end
    for _, n in ipairs(all) do
        local ok, mod = pcall(require, n)
        if not ok or type(mod) ~= "table" then
            for _, m in ipairs(all) do package.loaded[m] = old[m] end
            local err = ok and "module did not return a table" or tostring(mod)
            Utils.LogBad("VariantReload - FAILED on " .. n .. ": " .. err)
            Utils.LogBad("VariantReload - registry untouched; fix the file and /reload again")
            return false, n .. ": " .. err
        end
        fresh[n] = mod
    end

    -- Phase 2: only now touch the registry - snapshotted + pcall'd so even an unforeseen
    -- merge error can't leave it half-filled.
    local backup = {}
    for k, v in pairs(VARIANTS) do backup[k] = v end
    local okMerge, countOrErr = pcall(mergeInto, VARIANTS, fresh, names)   -- defs only
    if not okMerge then
        for k in pairs(VARIANTS) do VARIANTS[k] = nil end
        for k, v in pairs(backup) do VARIANTS[k] = v end
        for _, m in ipairs(all) do package.loaded[m] = old[m] end
        Utils.LogBad("VariantReload - merge FAILED: " .. tostring(countOrErr) .. "; registry restored")
        return false, tostring(countOrErr)
    end
    local count = countOrErr

    -- The renderer's load-time Id->def snapshot must follow the new tables, or client/host
    -- visuals keep dispatching the OLD defs (ClientVisuals builds it once at require).
    pcall(function() require("AnteVariants.ClientVisuals").RebuildIdMap() end)
    pcall(function() require("AnteVariants.VariantTag").RebuildIdMap() end)

    Utils.Log(string.format("VariantReload - rebuilt %d defs from %d files (%d helper)",
        count, #all, #helpers))
    return true, count
end

return VR
