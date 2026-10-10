
---@diagnostic disable: undefined-field, undefined-global, param-type-mismatch


local UEHelpers = require("UEHelpers")
local AFUtils   = require("AFUtils.AFUtils")

local STATE = require("Data.STATE")
local Enums = require("Data.Enums")
local GATE  = require("Managers.GATEManager")
local Utils = require("Utils.Utils")

local LogDebug = Utils.LogDebug

local Debug = {}


-- **********************************************************
-- Logging
-- **********************************************************

-- Move time ahead x hours
function Debug.AdvanceTime(hoursToAdvance)
    hoursToAdvance = hoursToAdvance or 4

    AFUtils.AddGameTime(hoursToAdvance)

    local dayNight = AFUtils.GetDayNightManager()
    if IsNotValid(dayNight) then return end

    local t = dayNight.CurrentTimeInSeconds
    local hour = math.floor(t / 3600)
    local minute = 0 --math.floor((t % 3600) / 60) -- set it the hour
    local day = dayNight.CurrentDay or 0

    local assaultSuffix = ""
    local director = FindFirstOf("Abiotic_AIDirector_C")
    if director and IsValid(director) then
        local rowFName = director.Assault_CurrentRow
        if rowFName then
            local rowStr = rowFName:ToString()
            if rowStr ~= "" and rowStr ~= "None" then
                assaultSuffix = " [" .. rowStr .. "]"
            end
        end
    end

    Utils.Chat(string.format("[GATE] Day %d  %02d:%02d - %s", day, hour, minute, assaultSuffix))
end


-- Returns a summary string for debug display.
function Debug.GetAssaultRowSummary(assaultName)
    local pool = {}
    local t    = GATE.GetAssaultTable()
    local entries = t[assaultName]
    local sp   = STATE.StoryProgress

    if not entries then
        return assaultName .. " has no custom assaults"
    end

    for _, entry in ipairs(entries) do
        local min = entry.StoryMin or 0
        local max = entry.StoryMax or 999
        if sp >= min and sp <= max then
            table.insert(pool, entry)
        end
    end

    return string.format("%s: [%d / %d] eligible / total custom assaults",
        assaultName, #pool, #entries)
end





-- ================================================================
-- Friendly-NPC protection for the debug wipes.
--
-- The wipe used to take everything with a pulse, which on a base with pets
-- meant killing them too. Two independent guards, because either one alone has
-- a hole:
--
--   1. FACTION - anything on the players' team (E_Factions player = 2). Catches
--      tamed pets AND the ally NPCs: Exor_Pikeman_Ally, MageEye_Ally, Coworker,
--      Boxy. `Faction` is a real property on Abiotic_Character_ParentBP_C, which
--      every NPC inherits.
--   2. TAMED BUFF - a tamed pet carries a BuffActor_Tamed_C that back-points at
--      its NPC. Covers a pet whose Faction read fails or hasn't resolved yet.
--
-- BuffActor_Tamed_C is a BASE-GAME class, so this matches what AnteUp does
-- without GATE depending on AnteUp being loaded.
-- ================================================================

local PLAYER_FACTION   = 2            -- E_Factions: the players' team
local TAMED_BUFF_CLASS = "BuffActor_Tamed_C"

-- Build the tamed-pet skip set ONCE per wipe (one buff scan, not one per NPC).
local function buildPetSet()
    local set = {}
    for _, buff in ipairs(FindAllOf(TAMED_BUFF_CLASS) or {}) do
        if IsValid(buff) then
            local npc
            pcall(function() npc = buff.CharacterNPC end)
            if npc and Utils.IsActorValid(npc) then
                local fullName
                pcall(function() fullName = npc:GetFullName() end)
                if fullName then set[fullName] = true end
            end
        end
    end
    return set
end

-- True if this NPC belongs to the players and must survive a debug wipe.
local function isFriendly(npc, petSet)
    local faction
    local ok = pcall(function() faction = npc.Faction end)
    if ok and faction ~= nil then
        -- TEnumAsByte usually marshals as a number; :get() it if it arrived wrapped.
        local n = tonumber(faction)
        if n == nil then pcall(function() n = tonumber(faction:get()) end) end
        if n == PLAYER_FACTION then return true end
    end

    if petSet then
        local fullName
        pcall(function() fullName = npc:GetFullName() end)
        if fullName and petSet[fullName] then return true end
    end

    return false
end


-- ----------------------------------------------------------------
-- Kill all living NPCs within 250m of player 1.
-- * Skips the players' own NPCs - see isFriendly above.
-- ----------------------------------------------------------------
-- originActor: optional. Defaults to the local player (host/SP). On a dedicated
-- server pass the command sender's pawn so "nearby" is relative to them.
function Debug.P1KillNearby(originActor)
    -- Queue all work; the callback runs on the game-tick hook, safely outside
    -- any UE4SS intercept context.
    Utils.QueueSpawn(function()
        local player = originActor or AFUtils.GetMyPlayer()
        if IsNotValid(player) then return end
        local loc = player:K2_GetActorLocation()

        local actorClass = StaticFindObject(Enums.BASE_PARENT_NPC)
        if not actorClass or IsNotValid(actorClass) then return end

        local nearby  = Utils.GetNearbyActorClass(loc, 25000, actorClass)
        local petSet  = buildPetSet()
        local count   = 0
        local spared  = 0
        for i = 1, #nearby do
            local npc = nearby[i]:get()
            if Utils.IsActorValid(npc) and not npc.IsDead then
                if isFriendly(npc, petSet) then
                    spared = spared + 1
                else
                    -- Mark dead and stop its tick
                    -- Defer K2_DestroyActor to a second QueueSpawn so it runs between
                    -- frames, not during any Blueprint event chain.
                    npc.IsDead = true
                    npc:SetActorTickEnabled(false)
                    local capturedNpc = npc
                    Utils.QueueSpawn(function()
                        if capturedNpc and IsValid(capturedNpc) then
                            capturedNpc:K2_DestroyActor()
                        end
                    end, 2000)
                    count = count + 1
                end
            end
        end
        Utils.Log(string.format("[GATE] KillNearby: %d NPCs killed, %d friendly spared", count, spared))
    end, 0)
end


-- ----------------------------------------------------------------
-- Destroy dead NPC corpses and dropped items within 250m.
-- ----------------------------------------------------------------
-- originActor: optional. Defaults to the local player (host/SP). On a dedicated
-- server pass the command sender's pawn so "nearby" is relative to them.
function Debug.P1ClearCorpsesItems(delay_ms, originActor)
    Utils.QueueSpawn(function()
        local player = originActor or AFUtils.GetMyPlayer()
        if IsNotValid(player) then return end
        local loc = player:K2_GetActorLocation()

        local destroyQueue = {}

        -- Dead NPC corpses.
        -- Friendly bodies are left alone too: a downed pet still has its tamed
        -- buff actor, and sweeping the corpse would take the pet with it.
        local npcClass = StaticFindObject(Enums.BASE_PARENT_NPC)
        if npcClass and IsValid(npcClass) then
            local nearby = Utils.GetNearbyActorClass(loc, 25000, npcClass)
            local petSet = buildPetSet()
            for i = 1, #nearby do
                local actor = nearby[i]:get()
                if actor and IsValid(actor) and actor.IsDead and not actor:IsActorBeingDestroyed()
                   and not isFriendly(actor, petSet) then
                    table.insert(destroyQueue, actor)
                end
            end
            Utils.Log("[GATE] ClearCorpses: " .. #destroyQueue .. " corpses")
            for _, actor in ipairs(destroyQueue) do
                if IsValid(actor) then actor:K2_DestroyActor() end
            end
        end

        -- Dropped items
        destroyQueue = {}
        local itemClass = StaticFindObject(Enums.ItemDropClass)
        if itemClass and IsValid(itemClass) then
            local nearby = Utils.GetNearbyActorClass(loc, 5000, itemClass)
            for i = 1, #nearby do
                local actor = nearby[i]:get()
                if actor and IsValid(actor) and not actor:IsActorBeingDestroyed() then
                    table.insert(destroyQueue, actor)
                end
            end
            Utils.Log("[GATE] ClearItems: " .. #destroyQueue .. " items")
            for _, actor in ipairs(destroyQueue) do
                if IsValid(actor) then
                    actor.HasBeenPickedUp = true
                    actor:SaveItem(true)
                    actor:InitDespawn()
                    actor:K2_DestroyActor()
                end
            end
        end
    end, delay_ms or 0)
end



-- ----------------------------------------------------------------
-- Remove concussion debuff every second
-- ----------------------------------------------------------------
function Debug.P1RemoveConcussion()

    local function hasBuff(actor, buff)
        if Utils.IsActorInvalid(actor) then return false end
        
        local buffComp = actor.BuffDebuffComponent
        if IsNotValid(buffComp) then return false end

        local foundBuff = {} -- Returns the limb enum if buff is found
        local onLimb = {} 
        if not buffComp["HasBuff?"] then return false end
    
        buffComp["HasBuff?"](buffComp, FName(buff), nil, true, 0, 1, foundBuff, onLimb)

        if foundBuff and #foundBuff > 0 then
            return true
        else
            return false
        end
    end


    local player = AFUtils.GetMyPlayer()
    if IsNotValid(player) then return end

    Utils.Log("Checking player")
    if hasBuff(player, "Debuff_Concussion") then
    Utils.Log("Has concussion")
        
        local buffComp = player.BuffDebuffComponent
        if not buffComp then return false end

        local buffRows = {}
        local rowHandle = {}

        rowHandle.RowName = FName("Debuff_Concussion")
        rowHandle.DataTablePath = "/Game/Blueprints/DataTables/BuffsDebuffs/DT_BuffsDebuffs.DT_BuffsDebuffs"
        table.insert(buffRows, rowHandle)

        Utils.Log("Removing buff ")
        buffComp:Server_RemoveSpecificBuffs(buffRows, false, {})
    end
    -- if not ok then return false end
    -- return ok
end

return Debug
