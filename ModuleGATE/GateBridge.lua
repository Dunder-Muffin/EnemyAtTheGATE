-- =======================================================================
-- GateBridge (AUTHORITY ONLY) - lets EnemyAtTheGATE put ANTEVARIANTS in its
-- assault wave lists, and gives ModuleRevenge the same slot-mutation service.
-- Full decode (channels, cursor matching, pin/warm, threading): AnNotes/Modules/GateBridge.md
-- + DROP TAG: NPC из десанта GATE (EM.VariantDrop) несёт тег "AnteVariant=<имя>" и
--   превращается в вариант по нему, без плана волн. См. readDropTag и шаг (A) в Register.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local Utils = require("AnteUtils.Utils")
local VARIANTS = require("AnteVariants.Variants")
local VariantTag = require("AnteVariants.VariantTag")
local NPCM = require("AnteVariants.NpcManager")
local SpawnerHooks = require("AnteVariants.SpawnerHooks")

local Log = Utils.Log
local LogBad = Utils.LogBad
local LogDebug = Utils.LogDebug

local GB = {}

-- ---------------------------------------------------------------- channels
local CH_VARIANTS = "AnteUp_VariantBases"
local CH_PLAN     = "AnteUp_AssaultPlan"
local CH_PROBE    = "AnteUp_ChannelProbe"
local CH_CALENDAR = "AnteUp_AssaultCalendar"

-- Mods/shared/ - the one folder both mods can name from their own root
-- (this file is <mod>/scripts/ModuleGATE/, so ../../../shared/).
local source = debug.getinfo(1, "S").source
if source:sub(1, 1) == "@" then source = source:sub(2) end
local scriptDir = source:match("(.+[\\/])") or "./"
local SHARED_DIR    = scriptDir .. "../../../shared/"
local FILE_VARIANTS = SHARED_DIR .. "AnteUp_VariantBases.txt"
local FILE_PLAN     = SHARED_DIR .. "AnteUp_AssaultPlan.txt"
local FILE_CALENDAR = SHARED_DIR .. "AnteUp_AssaultCalendar.txt"

local useSharedVars = false     -- decided by probeChannel()

-- Director phase -> wave slot in the plan. 0=None 1=Warning 2..5=Wave1..Boss 6=End.
local PHASE_WAVE = { [2] = 1, [3] = 2, [4] = 3, [5] = 4 }

-- Re-read cadence for the FILE fallback only (the shared-var read is free).
local FILE_POLL_TICKS = 10      -- FAST_TICK is ~10/s, so ~1s

-- DROP TAG - NPC из десанта GATE (EM.VariantDrop) приходит с тегом "AnteVariant=<имя>"
-- в AActor.Tags. GATE вешает его до FinishSpawningActor, поэтому к BeginPlay он уже стоит.
-- Волны директора идут по плану (канал 2), десанты - по тегу: у десанта нет слота в волне.
local DROP_TAG_PREFIX = "AnteVariant="

-- ---------------------------------------------------------------- state
local planRaw = nil             -- last raw plan string we parsed
local plan = nil                -- { waves = { [1..4] = {names} }, taken = { [wave] = {idx=true} } }
local localPlan = nil           -- a plan set IN-PROCESS by ModuleRevenge (see GB.SetLocalPlan)
local lastFileRead = -999
local lastPhaseSeen = nil


-- =======================================================================
-- Transport
-- =======================================================================

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
    if not f then
        LogBad("[GATE-BRIDGE] could not write " .. path)
        return false
    end
    f:write(text)
    f:close()
    return true
end

-- One-time decision: can a shared variable carry a STRING on this UE4SS build?
local function probeChannel()
    local wrote = pcall(function() ModRef:SetSharedVariable(CH_PROBE, "ok") end)
    local back
    if wrote then pcall(function() back = ModRef:GetSharedVariable(CH_PROBE) end) end
    useSharedVars = (back == "ok")
    Log("AnteUp2 - GATE bridge channel: " ..
        (useSharedVars and "shared variables" or "shared/ file fallback"))
end

local function publish(channel, filePath, payload)
    if useSharedVars then
        local ok = pcall(function() ModRef:SetSharedVariable(channel, payload) end)
        if ok then return true end
        LogBad("[GATE-BRIDGE] shared-variable write failed on " .. channel .. "; using file")
        useSharedVars = false
    end
    return writeFile(filePath, payload)
end


-- =======================================================================
-- CHANNEL 1 - publish "variant name -> base row" so EATG can turn a name in an
-- assault file into something DT_NPCList can actually spawn.
-- PET forms are excluded (identified structurally via TamedVariant, not by name):
-- they only exist as the tamed re-mutation of a wild variant, so spawning one into
-- an assault would be nonsense.
-- =======================================================================
function GB.PublishVariants()
    local petForms = {}
    for _, def in pairs(VARIANTS) do
        if def.TamedVariant then petForms[def.TamedVariant] = true end
    end

    local parts = {}
    for name, def in pairs(VARIANTS) do
        if def.Base and not petForms[name] then
            parts[#parts + 1] = name .. "=" .. def.Base
        end
    end
    table.sort(parts)

    local payload = "1|" .. table.concat(parts, "|")
    publish(CH_VARIANTS, FILE_VARIANTS, payload)
    Log(string.format("AnteUp2 - GATE bridge published %d variants", #parts))
end


-- =======================================================================
-- CHANNEL 3 - publish the in-game days ModuleRevenge has CLAIMED, so EATG stands down on them
-- instead of starting a second assault on top of a revenge (both mods write the same director
-- wave lists). Payload "1|12,14,17"; an empty calendar still publishes "1|" so a cleared claim
-- is explicit. One-way and advisory - harmless if EATG is absent.
-- =======================================================================
function GB.PublishCalendar(days)
    local payload = "1|" .. table.concat(days or {}, ",")
    publish(CH_CALENDAR, FILE_CALENDAR, payload)
    LogDebug("[GATE-BRIDGE] published revenge calendar: " .. payload, SETTINGS.DEBUG_STORY)
end


-- =======================================================================
-- CHANNEL 2 - read the plan EATG published for the assault it just applied.
-- =======================================================================

local function readPlanRaw()
    if useSharedVars then
        local s
        pcall(function() s = ModRef:GetSharedVariable(CH_PLAN) end)
        if type(s) == "string" and s ~= "" then return s end
        return nil
    end

    -- File fallback: throttle the actual disk read, keep serving the parsed plan.
    local now = STATE.FAST_TICK or 0
    if planRaw and (now - lastFileRead) < FILE_POLL_TICKS then return planRaw end
    lastFileRead = now
    return readFile(FILE_PLAN)
end

-- Plain-text split that KEEPS empty fields.
--   * Slot positions must line up with the FName array EATG wrote,
--     so "Pest,,Peccary" is three slots, not two.
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

local function parsePlan(raw)
    -- fields[1] = serial, 2..5 = the four waves
    local fields = split(raw, "|")
    local p = { waves = {}, taken = {} }
    for w = 1, 4 do
        local waveStr = fields[w + 1]
        p.waves[w] = (waveStr and waveStr ~= "") and split(waveStr, ",") or {}
        p.taken[w] = {}
    end
    return p
end

-- GC-pin the whole plan's variant-asset union, once per assault ([[anteup2-pinned-cache-trust]]).
-- Mutating a wave body then finds its assets warm and trusted instead of cold-loading mid-fight.
-- Every role (PinPaths); with ASSET_KEEPER off, warmWave's per-wave LoadAsync is the fallback.
-- Pins release with the world (StopMod). See AnNotes/Modules/GateBridge.md.
local function pinPlanAssets(p)
    local seen, list = {}, {}
    for w = 1, 4 do
        for _, n in ipairs(p.waves[w] or {}) do
            local def = (n and n ~= "-" and n ~= "") and VARIANTS[n] or nil
            for _, path in ipairs(def and def.Assets or {}) do
                if type(path) == "string" and not seen[path] then
                    seen[path] = true; list[#list + 1] = path
                end
            end
        end
    end
    if #list > 0 then require("AnteCore.AssetKeeper").PinPaths(list) end
end

-- =======================================================================
-- THE IN-PROCESS PLAN - ModuleRevenge's own assaults get the same slot-mutation service, handed
-- over directly (same Lua state) instead of via the shared channel. Wins over the channel while
-- set (a revenge night means EATG stood down). MUST be cleared at assault end (RevengeDirector's
-- ChangeAssaultPhase hook, phase 6) or it silently steals the next EATG assault's wave bodies.
-- =======================================================================

-- waveVariants = { [1..4] = index-aligned variant names, "-" for vanilla } (nil waves are fine).
function GB.SetLocalPlan(waveVariants)
    local p = { waves = {}, taken = {} }
    for w = 1, 4 do
        p.waves[w] = waveVariants and waveVariants[w] or {}
        p.taken[w] = {}
    end
    localPlan = p
    lastPhaseSeen = nil
    pinPlanAssets(p)

    local parts = {}
    for w = 1, 4 do parts[w] = table.concat(p.waves[w], ",") end
    Log("[GATE-BRIDGE] local (revenge) plan: " .. table.concat(parts, "|"))
end

function GB.ClearLocalPlan()
    if not localPlan then return end
    localPlan = nil
    lastPhaseSeen = nil
    LogDebug("[GATE-BRIDGE] local plan cleared", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- Current plan, re-parsed only when the raw string actually changes.
--   * A new assault carries a new serial, so an identical-looking assault still resets.
local function currentPlan()
    if localPlan then return localPlan end

    local raw = readPlanRaw()
    if not raw or raw == "" then
        planRaw, plan = nil, nil
        return nil
    end
    if raw ~= planRaw then
        planRaw = raw
        plan = parsePlan(raw)
        lastPhaseSeen = nil
        -- Once per assault; the first thing to check when a wave comes out vanilla - NOT debug-gated.
        Log("[GATE-BRIDGE] new assault plan: " .. raw)
        pinPlanAssets(plan)
    end
    return plan
end


-- =======================================================================
-- Director access
-- =======================================================================

local function getDirector()
    -- Utils owns the cache: re-finds on an invalid wrapper, drops it on world teardown.
    local d = Utils.GetAIDirectorActor()
    if not d or IsNotValid(d) then return nil end
    return d
end

-- phase + the slot the in-flight spawn came from (0-based on the BP side).
local function readSpawnCursor(dir)
    local phase, idx
    local ok = pcall(function()
        phase = dir.Assault_CurrentPhase
        idx   = dir.Assault_PreviousSpawnIndex
    end)
    if not ok or phase == nil or idx == nil then return nil end
    return tonumber(phase), tonumber(idx)
end

-- Is this body one of the assault's?
--   * FinishSpawningActor adds every assault NPC to AssaultNPCs immediately, so by the time
--     our staggered WorkQueue item runs this is an exact answer.
--   * Keeps a spawner NPC that happened to pop during the assault from eating a slot.
local function isAssaultNpc(dir, actor)
    local found = false
    pcall(function()
        local list = dir.AssaultNPCs
        if not list then return end
        local n = list:GetArrayNum() or 0
        local myName = actor:GetFullName()
        for i = 1, n do
            local a = list[i]
            if a and not Utils.IsActorInvalid(a) and a:GetFullName() == myName then
                found = true
                return
            end
        end
    end)
    return found
end


-- =======================================================================
-- Slot matching
-- =======================================================================

local function slotUsable(name, rowName)
    if not name or name == "" or name == "-" then return false end
    local def = VARIANTS[name]
    if not def then return false end
    return VariantTag.AcceptsBase(def, rowName)
end

-- Returns variantName, waveIdx, slotIdx  (or nil when this body isn't ours)
local function claimSlot(p, wave, cursorIdx, rowName)
    local list = p.waves[wave]
    if not list or #list == 0 then return nil end
    local taken = p.taken[wave]

    -- 1. The cursor slot - the normal, exact case (BP index is 0-based).
    local at = cursorIdx + 1
    if not taken[at] and slotUsable(list[at], rowName) then
        taken[at] = true
        return list[at], wave, at
    end

    -- 2. Cursor points at a FREE slot this body doesn't match (path 1 failed). Two cases:
    --      a) Slot is VANILLA ("-"): consume it so the FIFO scan can't later steal it for a
    --         real variant slot in the same wave. Costs nothing - no variant to lose.
    --      b) Slot holds a REAL VARIANT this body's base doesn't match: an interloper, most
    --         often a non-assault NPC that spawned mid-assault (e.g. OnStart PestDrop/PeccaryDrop
    --         hitting the same parent-class hook). Leave the slot untouched - burning it here is
    --         the wave-skip bug (the real variant body spawns moments later and finds it taken).
    if list[at] ~= nil and not taken[at] then
        if list[at] == "-" then
            taken[at] = true
        end
        return nil
    end

    -- 3. Cursor was stale (a slow class load outran the spawn rate): first
    --    unclaimed slot in this wave that accepts this base.
    for i = 1, #list do
        if not taken[i] and slotUsable(list[i], rowName) then
            taken[i] = true
            LogDebug(string.format("[GATE-BRIDGE] cursor %d stale for %s, took slot %d (%s)",
                at, rowName, i, list[i]), SETTINGS.DEBUG_NPC_ACTIONS)
            return list[i], wave, i
        end
    end

    return nil
end


-- =======================================================================
-- Drop tag - имя варианта из тега "AnteVariant=<имя>", или nil.
--   * Обычный NPC тегов не несёт, так что для него это один пустой ForEach
--   * pcall: Tags читается на каждом BeginPlay, и сбой здесь не должен
--     задеть путь волн ниже
-- =======================================================================
local function readDropTag(actor)
    local found = nil
    pcall(function()
        local tags = actor.Tags
        if not tags or (tags:GetArrayNum() or 0) == 0 then return end
        tags:ForEach(function(_, elem)
            if found then return end
            local s = elem:get():ToString()
            if s:sub(1, #DROP_TAG_PREFIX) == DROP_TAG_PREFIX then
                found = s:sub(#DROP_TAG_PREFIX + 1)
            end
        end)
    end)
    return found
end


-- =======================================================================
-- Asset warm - a wave's variants, once, as the wave starts. Cheap once the plan's assets are
-- pinned; stays for ASSET_KEEPER off and for non-path def entries the pin skipped.
-- =======================================================================
local function warmWave(p, wave)
    local list = p.waves[wave]
    if not list then return end
    local names = {}
    for _, n in ipairs(list) do
        if n and n ~= "-" and n ~= "" and VARIANTS[n] then names[#names + 1] = n end
    end
    if #names == 0 then return end
    SpawnerHooks.WarmVariantNames(names)
end


-- =======================================================================
-- Register - authority only.
-- =======================================================================
function GB.Register()
    if STATE.GateBridgeArmed then return end
    -- MODULE_REVENGE_ASSAULTS rides the same BeginPlay slot-matcher (via GB.SetLocalPlan), so the hook
    -- arms for either feature. Only the EATG-facing variant map is gated on the bridge setting.
    local forGate = SETTINGS.MOD_COMPATIBILITY.ENEMY_AT_THE_GATE
    local forRevenge = SETTINGS.GAMEPLAY.MODULE_REVENGE_ASSAULTS
    if not (forGate or forRevenge) then return end
    if not Utils.IsAuthority() then return end

    probeChannel()
    if forGate then GB.PublishVariants() end

    local hook = "/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C:ReceiveBeginPlay"
    local ok, err = pcall(RegisterHook, hook, function(self)
        if not STATE.ModEnabled then return end

        -- (A) Десант GATE с тегом варианта. Плана и фазы не нужно: тег сам
        --     говорит, кем стать. Слоты волн не трогаем - у десанта их нет.
        if forGate then
            local dropActor = self:get()
            if not Utils.IsActorInvalid(dropActor) then
                local dropVariant = readDropTag(dropActor)
                if dropVariant then
                    local rowName = Utils.GetActorRowName(dropActor)
                    if rowName and slotUsable(dropVariant, rowName) then
                        LogDebug(string.format("[GATE-BRIDGE] drop tag: %s -> %s", rowName, dropVariant),
                            SETTINGS.DEBUG_NPC_ACTIONS)
                        SpawnerHooks.WarmVariantNames({ dropVariant })
                        -- Та же отложенная мутация, что у волн: десант тоже приходит пачкой
                        Utils.QueueWork(function()
                            if not STATE.ModEnabled then return end
                            if Utils.IsActorInvalid(dropActor) then return end
                            NPCM.MutateActor(dropVariant, dropActor, { Stagger = true })
                        end, math.random(300, 900))
                    else
                        LogBad(string.format("[GATE-BRIDGE] drop tag '%s' does not fit %s - left vanilla",
                            tostring(dropVariant), tostring(rowName)))
                    end
                    return
                end
            end
        end

        local p = currentPlan()
        if not p then return end

        local dir = getDirector()
        if not dir then return end

        local phase, cursorIdx = readSpawnCursor(dir)
        local wave = phase and PHASE_WAVE[phase]
        if not wave then return end

        if lastPhaseSeen ~= phase then
            lastPhaseSeen = phase
            warmWave(p, wave)
        end

        local actor = self:get()
        if Utils.IsActorInvalid(actor) then return end

        local rowName = Utils.GetActorRowName(actor)
        if not rowName then return end

        local variantName, w, slot = claimSlot(p, wave, cursorIdx, rowName)
        if not variantName then return end

        LogDebug(string.format("[GATE-BRIDGE] wave %d slot %d: %s -> %s",
            w, slot, rowName, variantName), SETTINGS.DEBUG_NPC_ACTIONS)

        -- Off-hook, same stagger as the spawner path (a wave lands in a burst).
        Utils.QueueWork(function()
            if not STATE.ModEnabled then return end
            if Utils.IsActorInvalid(actor) then return end

            -- Not an assault body after all - hand the slot back
            -- so the real assault NPC for it still gets its variant.
            if not isAssaultNpc(dir, actor) then
                if w and slot and p.taken[w] then p.taken[w][slot] = nil end
                LogDebug("[GATE-BRIDGE] " .. rowName .. " was not an assault NPC; slot released",
                    SETTINGS.DEBUG_NPC_ACTIONS)
                return
            end

            NPCM.MutateActor(variantName, actor, { Stagger = true })
        end, math.random(300, 900))
    end)

    if not ok then
        LogBad("[GATE-BRIDGE] NPC BeginPlay hook failed: " .. tostring(err))
        return
    end

    STATE.GateBridgeArmed = true
    Log("AnteUp2 - GATE bridge armed")
end

return GB
