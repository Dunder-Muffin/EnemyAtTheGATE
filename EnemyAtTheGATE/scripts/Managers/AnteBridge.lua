
-- ============================================================
-- AnteBridge.lua
-- Lets an assault file name an ANTEUP VARIANT anywhere a DT_NPCList row name
-- is expected:
--
--     Wave1 = { "Pest", "Razor Pest", "Charge Peccary" },
--
-- DT_NPCList has no "Razor Pest" row, so we spawn the variant's BASE ("Pest")
-- and tell AnteUp which SLOTS of which wave it should mutate. AnteUp hooks
-- NPC BeginPlay, reads the director's spawn cursor, and mutates the body.
--
-- TWO STRING CHANNELS (UE4SS mods have separate Lua states - nothing but
-- primitives crosses):
--   1. AnteUp_VariantBases   AnteUp publishes  "1|Razor Pest=Pest|..."
--   2. AnteUp_AssaultPlan    WE publish  "<serial>|<wave1>|<wave2>|<wave3>|<boss>"
--        one comma-separated entry per index of the array we wrote, either a
--        variant name or "-" for "leave it vanilla".
--
-- Transport is ModRef:SetSharedVariable/GetSharedVariable, with a one-line file
-- in Mods/shared/ as the fallback for UE4SS builds that only take UObjects
-- there. Both mods run the same round-trip probe, so they always pick the same
-- channel.
--
-- IF ANTEUP IS NOT RUNNING: we fall back to the last variant map we saw
-- (cached next to this mod), so "Razor Pest" still spawns a plain Pest and the
-- wave keeps its size. Unknown names are warned about once per assault.
-- ============================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE  = require("Data.STATE")
local CONFIG = STATE.Config
local Utils  = require("Utils.Utils")

local Log      = Utils.Log
local LogBad   = Utils.LogBad
local LogDebug = Utils.LogDebug

local AB = {}

local CH_VARIANTS = "AnteUp_VariantBases"
local CH_PLAN     = "AnteUp_AssaultPlan"
local CH_PROBE    = "AnteUp_ChannelProbe"
local CH_CALENDAR = "AnteUp_AssaultCalendar"

-- This file is <mod>/scripts/Managers/, so ../../ is the mod root and
-- ../../../shared/ is Mods/shared/ (the folder both mods can name).
local _src = debug.getinfo(1, "S").source
if _src:sub(1, 1) == "@" then _src = _src:sub(2) end
local SCRIPT_DIR    = _src:match("(.+[\\/])") or "./"
local MOD_ROOT      = SCRIPT_DIR .. "../../"
local SHARED_DIR    = SCRIPT_DIR .. "../../../shared/"
local FILE_VARIANTS = SHARED_DIR .. "AnteUp_VariantBases.txt"
local FILE_PLAN     = SHARED_DIR .. "AnteUp_AssaultPlan.txt"
local FILE_CALENDAR = SHARED_DIR .. "AnteUp_AssaultCalendar.txt"
local FILE_CACHE    = MOD_ROOT   .. "AnteUp_VariantCache.txt"

local probed        = false
local useSharedVars = false

local variantBases  = nil     -- name -> base row, or nil until first successful read
local fromCache     = false   -- true when variantBases came off disk (AnteUp silent)
local warnedThisAssault = {}
local planSerial    = 0


-- ============================================================
-- Transport
-- ============================================================

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    if not s or s == "" then return nil end
    return (s:gsub("%s+$", ""))
end

local function writeFile(path, text)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(text)
    f:close()
    return true
end

-- Can a shared variable carry a STRING on this UE4SS build? Run once.
local function probeChannel()
    if probed then return end
    probed = true
    local wrote = pcall(function() ModRef:SetSharedVariable(CH_PROBE, "ok") end)
    local back
    if wrote then pcall(function() back = ModRef:GetSharedVariable(CH_PROBE) end) end
    useSharedVars = (back == "ok")
    LogDebug("[ANTE] bridge channel: " ..
        (useSharedVars and "shared variables" or "shared/ file fallback"), CONFIG.DEBUG_LOG)
end

local function readChannel(channel, filePath)
    probeChannel()
    if useSharedVars then
        local s
        pcall(function() s = ModRef:GetSharedVariable(channel) end)
        if type(s) == "string" and s ~= "" then return s end
        return nil
    end
    return readFile(filePath)
end

local function writeChannel(channel, filePath, payload)
    probeChannel()
    if useSharedVars then
        local ok = pcall(function() ModRef:SetSharedVariable(channel, payload) end)
        if ok then return true end
        LogBad("[ANTE] shared-variable write failed; switching to the file channel")
        useSharedVars = false
    end
    return writeFile(filePath, payload)
end

-- Keeps empty fields (slot positions must line up with the array we write).
local function split(s, sep)
    local out, pos = {}, 1
    while true do
        local a, b = string.find(s, sep, pos, true)
        if not a then
            out[#out + 1] = string.sub(s, pos)
            return out
        end
        out[#out + 1] = string.sub(s, pos, a - 1)
        pos = b + 1
    end
end


-- ============================================================
-- The variant -> base map.
-- Re-read every time it's still missing (AnteUp publishes at its InitMod,
-- which can land after ours), then cached for the session. A successful live
-- read is mirrored to disk so a later session without AnteUp can still map a
-- variant name back to something DT_NPCList can spawn.
-- ============================================================
local function parseVariantPayload(raw)
    local map, n = {}, 0
    local fields = split(raw, "|")
    for i = 2, #fields do            -- fields[1] is the format version
        local name, base = string.match(fields[i], "^(.-)=(.+)$")
        if name and name ~= "" and base and base ~= "" then
            map[name] = base
            n = n + 1
        end
    end
    if n == 0 then return nil end
    return map, n
end

function AB.GetVariantMap()
    if variantBases and not fromCache then return variantBases end

    local raw = readChannel(CH_VARIANTS, FILE_VARIANTS)
    if raw then
        local map, n = parseVariantPayload(raw)
        if map then
            variantBases, fromCache = map, false
            writeFile(FILE_CACHE, raw)
            LogDebug(string.format("[ANTE] AnteUp variant map: %d variants", n), CONFIG.DEBUG_LOG)
            return variantBases
        end
    end

    if variantBases then return variantBases end   -- already on the cached copy

    local cached = readFile(FILE_CACHE)
    if cached then
        local map, n = parseVariantPayload(cached)
        if map then
            variantBases, fromCache = map, true
            Log(string.format("[ANTE] AnteUp not responding - using the cached variant map (%d entries). " ..
                "Variants will spawn as their plain base NPC.", n))
            return variantBases
        end
    end

    return nil
end

-- Is AnteUp live right now? (Used only for messaging.)
function AB.IsAnteUpLive()
    AB.GetVariantMap()
    return (variantBases ~= nil) and not fromCache
end


-- ============================================================
-- Wave resolution.
--
-- Takes an assault-file wave list and returns
--     bases    - the row names to write onto the director (what actually spawns)
--     variants - index-aligned: a variant name, or "-" for "leave it vanilla"
--
-- An unrecognised name is written through UNCHANGED - it's either a plain
-- DT_NPCList row (the normal case) or a typo, and the director's own
-- "INVALID SPAWN CLASS on NPCList row" log is the clearest message for a typo.
--
-- "Variant@Row" picks the BODY:
--   * a variant declares one Base plus any AltBases it also accepts (the Order
--     grunt variants are Base "Grunt" but take Guard / Trooper too)
--   * on its own we spawn the Base; "Velites Guard@Grunt_Guard" puts it on a Guard
--   * if AnteUp rejects the pairing it leaves the NPC vanilla, so the wave still
--     spawns the body you asked for
-- ============================================================
function AB.ResolveWave(list, label)
    local bases, variants = {}, {}
    if not list then return bases, variants end

    local map = AB.GetVariantMap()

    -- NO map at all (AnteUp silent AND no cache on disk). Every variant name is
    -- about to go onto the director unchanged, and the director can't spawn a row
    -- DT_NPCList doesn't have - so those slots spawn NOTHING, not even a base
    -- NPC. Say so loudly; otherwise it looks like "the assault is just small".
    if not map and not warnedThisAssault["#nomap"] then
        warnedThisAssault["#nomap"] = true
        LogBad("[ANTE] ###############################################################")
        LogBad("[ANTE] #### No AnteUp variant map. Any VARIANT named in this assault")
        LogBad("[ANTE] #### will be written to the director as-is and will SPAWN NOTHING.")
        LogBad("[ANTE] #### Is AnteUp installed, enabled, and is its MOD_COMPATIBILITY.ENEMY_AT_THE_GATE on?")
        LogBad("[ANTE] ###############################################################")
        Utils.Chat("[GATE] AnteUp variant map missing - variant slots will not spawn")
    end
    map = map or {}

    for i = 1, #list do
        local entry = tostring(list[i])
        local name, bodyOverride = string.match(entry, "^(.-)@(.+)$")
        if not name then name = entry end

        local base = map[name] and (bodyOverride or map[name])

        if base then
            bases[i] = base
            -- On the cached map AnteUp isn't there to mutate anything, so don't
            -- claim the slot - the base NPC spawns and that's the whole story.
            variants[i] = fromCache and "-" or name
            if fromCache and not warnedThisAssault[name] then
                warnedThisAssault[name] = true
                Log(string.format("[ANTE] %s: \"%s\" -> plain \"%s\" (AnteUp not running)",
                    label or "wave", name, base))
            end
        else
            -- Unknown name. With a "@Row" suffix that row is still a real NPC to
            -- spawn, so use it; otherwise pass the name straight through.
            bases[i] = bodyOverride or entry
            variants[i] = "-"

            -- Typo detector: every DT_NPCList row is one word ("Pest_Carbonated",
            -- "Gatekeeper_Witch"), so a SPACE means it was meant to be a variant
            -- name. Unresolved, it spawns nothing - worth a line each time.
            if string.find(name, " ", 1, true) and not warnedThisAssault[name] then
                warnedThisAssault[name] = true
                LogBad(string.format("[ANTE] %s: \"%s\" is not a known AnteUp variant - " ..
                    "this slot will spawn NOTHING. Check the spelling against %s",
                    label or "wave", name, "AnteUp_VariantCache.txt"))
            end
        end
    end

    return bases, variants
end


-- ============================================================
-- REVENGE CALENDAR - the in-game days AnteUp has CLAIMED for one of its own "revenge assault"
-- set-pieces (AnteUp's ModuleRevenge). Payload "1|12,14,17"; "1|" means nothing is claimed.
--
-- WHY WE HAVE TO CARE: only one assault can run at a time, and both mods write the SAME director
-- wave lists from the SAME SortAssaultSpawnLists hook. Hook order between two mods is not defined,
-- so on a claimed night whoever writes last wins and the revenge is a coin flip. Standing down is
-- what makes it deterministic.
--
-- Advisory and one-way: with AnteUp absent the channel is never written and this always says false.
-- ============================================================
local claimedDays, claimedAt = nil, -9999
local CLAIM_TTL_TICKS = 50      -- ~5s. IsTodayAssaultDay is polled every 15s; the file fallback
                                -- read is the only cost worth throttling.

function AB.IsDayClaimed(day)
    if not day then return false end

    local now = STATE.TICKS or 0
    if not claimedDays or (now - claimedAt) >= CLAIM_TTL_TICKS then
        claimedAt = now
        claimedDays = {}
        local raw = readChannel(CH_CALENDAR, FILE_CALENDAR)
        if raw then
            local fields = split(raw, "|")
            for _, d in ipairs(split(fields[2] or "", ",")) do
                local n = tonumber(d)
                if n then claimedDays[n] = true end
            end
        end
    end

    return claimedDays[day] == true
end


-- ============================================================
-- Publish the plan for the assault that was just applied.
-- waveVariants = { [1]=wave1 variants, [2]=wave2, [3]=wave3, [4]=boss } -
-- each the second return of ResolveWave (or nil for an empty wave).
-- ============================================================
function AB.PublishPlan(waveVariants)
    local anyVariant = false
    local parts = {}

    for w = 1, 4 do
        local v = waveVariants[w] or {}
        for i = 1, #v do
            if v[i] ~= "-" then anyVariant = true end
        end
        parts[w] = table.concat(v, ",")
    end

    -- Nothing to mutate: clear the channel instead of leaving a stale plan up.
    if not anyVariant then
        AB.ClearPlan()
        return
    end

    planSerial = planSerial + 1
    local payload = tostring(planSerial) .. "|" .. table.concat(parts, "|")
    writeChannel(CH_PLAN, FILE_PLAN, payload)
    LogDebug("[ANTE] published assault plan: " .. payload, CONFIG.DEBUG_LOG)
end

function AB.ClearPlan()
    writeChannel(CH_PLAN, FILE_PLAN, "")
end

-- Called when a new assault is being set up, so the "AnteUp isn't running"
-- warnings appear once per assault rather than once per session.
function AB.ResetWarnings()
    warnedThisAssault = {}
end


return AB
