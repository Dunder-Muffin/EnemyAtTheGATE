
-- ============================================================
-- AssaultManager.lua
-- Core logic for selecting and applying custom assault data.
--
-- ============================================================

---@diagnostic disable: undefined-field, undefined-global, unused-local

local STATE  = require("Data.STATE")
local CONFIG = STATE.Config
local Utils  = require("Utils.Utils")
local GATE   = require("Managers.GATEManager")
local AB     = require("Managers.AnteBridge")

local Log      = Utils.Log
local LogDebug = Utils.LogDebug

local RECENT_HISTORY_SIZE = 5

local AM = {}


-- ============================================================
-- Set our CustomAssault
-- * Gets the Director's current assault row name
-- * Picks a random eligible entry from the assault table
-- * Redraws up to MAX_REDRAWS times if:
--     - The row of custom assaults exists, but none are eligible (SP limits)
--     - The entry was recently used
-- * Applies the chosen entry to the Director
-- ============================================================

function AM.SetCustomAssault(director, directorAssaultData)
    
    local initAssaultName = Utils.FNameToString(director.Assault_CurrentRow)
    if not initAssaultName or initAssaultName == "None" then return end

    local MAX_REDRAWS = 15
    local chosenRow, chosenAssaultData, chosenIdx

    for attempt = 1, MAX_REDRAWS do

        -- Use Current Assault handle or redraw Assault on retry
        local assaultName
        if attempt == 1 then
            assaultName = initAssaultName
        else
            local out = {}
            director:SelectRandomAssaultType(out)
            if not out.FoundValidRow then break end
            local rowFName = director.Assault_CurrentRow
            assaultName = (rowFName and rowFName:ToString()) or ""
            if assaultName == "" or assaultName == "None" then break end
        end


        -- Get an entry in our custom assaults for that Assault name
        local customAssaultData, idx = GATE.PickRandomAssault(assaultName)


        -- [DONT DO CUSTOM ASSAULT] 
        -- We don't reference this at all - break and let the game do the assault
        if not customAssaultData and not GATE.RowExists(assaultName) then           
            break


        -- [REDRAW THE ASSAULT]
        -- We reference this, but no entries are elgible (StoryProgress creates restrictions)
        elseif not customAssaultData then
            LogDebug("[GATE] SetCustomAssault() - Redrawing for " .. assaultName .. " because we have no legal entries [SP=" .. STATE.StoryProgress .. "]", CONFIG.DEBUG_LOG)
        

        -- [REDRAW THE ASSAULT]
        -- This exact assault was used recently (assault_peccaryboss_2 - the 2nd entry in assault_peccaryboss)
        elseif AM.IsRecentAssault(assaultName, idx) then
            LogDebug("[GATE] SetCustomAssault() - Redrawing for " .. AM.MakeAssaultKey(assaultName, idx) .. " because we used it recently", CONFIG.DEBUG_LOG)
        

        -- [THIS IS OUR CUSTOM ASSAULT DATA]
        else
            chosenRow  = assaultName
            chosenAssaultData = customAssaultData
            chosenIdx  = idx
            break
        end

    end

    if not chosenAssaultData then
        LogDebug("[GATE] SetCustomAssault() - no custom assault for " .. initAssaultName .. " (SP=" .. STATE.StoryProgress .. ")", CONFIG.DEBUG_LOG)
        return
    end

    LogDebug("[GATE] SetCustomAssault() - applying " ..
        AM.MakeAssaultKey(chosenRow, chosenIdx) ..
        " (SP=" .. STATE.StoryProgress .. ")", CONFIG.DEBUG_LOG)

    AM.SCM_ApplyAssaultData(director, directorAssaultData, chosenAssaultData, chosenRow, chosenIdx)
end

-- ============================================================
-- Helper to SetCustomAssault
-- * Writes assault entry data onto the AIDirector and tracks history.
-- ============================================================

function AM.SCM_ApplyAssaultData(director, assDirector, data, assaultRow, entryIdx)
    
    -- Pending assault. We'll save it to RecentAssaults when it happens
    STATE.RecentAssaults_Pending = { row = assaultRow, idx = entryIdx }
    STATE.LastCustomAssault = data

    -- Optionally override the Assault's PrepTime (default 20s)
    -- * Shortening it for debugging starting assaults mostly
    if data.PrepTime then
        STATE.AssaultPrepTime = data.PrepTime * 1000
    end

    if data.OnStart then
        if type(data.OnStart) ~= "function" then
            Utils.LogBad("ApplyAssaultData() - OnStart function not recognized - %s. " ..
                          tostring(data.OnStart))
        else
            local ok, err = pcall(data.OnStart)
            if not ok then Utils.LogBad("[GATE] ApplyAssaultData() - OnStart error: " .. tostring(err)) end
        end
    end

    -- A wave entry may name an ANTEUP VARIANT ("Razor Pest") instead of a
    -- DT_NPCList row. ResolveWave hands back the base rows to actually spawn plus
    -- an index-aligned variant list; PublishPlan then tells AnteUp which slots to
    -- mutate as the director spawns them. With AnteUp absent it's a pass-through
    -- (variants resolve to their plain base). See Managers/AnteBridge.lua.
    --
    -- RESOLVE FIRST, THEN WRITE - this order is load-bearing.
    --   * The old code Empty()'d all four director arrays up front and refilled
    --     them one at a time.
    --   * Anything that threw in between (a bad wave table, an AnteBridge
    --     hiccup) left FOUR EMPTY wave lists.
    --   * That fails SILENTLY: AssaultTick sees CurrentSpawnIndex > LastIndex on
    --     every wave and walks phase 2->3->4->5->6 on consecutive ticks. Warning
    --     message, end message, zero NPCs, nothing in the log.
    --   * Resolving into locals first means a failure leaves the NATIVE lists
    --     intact - you get a vanilla assault instead of no assault.
    AB.ResetWarnings()

    local waveVariants = {}
    local resolved = {}   -- { {arrayName, bases}, ... } in wave order

    local WAVES = {
        { key = "Wave1",    label = "Wave1",    slot = 1, array = "Assault_NPCList_Wave1"    },
        { key = "Wave2",    label = "Wave2",    slot = 2, array = "Assault_NPCList_Wave2"    },
        { key = "Wave3",    label = "Wave3",    slot = 3, array = "Assault_NPCList_Wave3"    },
        { key = "BossWave", label = "BossWave", slot = 4, array = "Assault_NPCList_BossWave" },
    }

    for _, w in ipairs(WAVES) do
        if data[w.key] then
            local ok, bases, variants = pcall(AB.ResolveWave, data[w.key], w.label)
            if not ok then
                Utils.LogBad(string.format(
                    "[GATE] SCM_ApplyAssaultData() - %s failed to resolve, keeping the NATIVE assault: %s",
                    w.label, tostring(bases)))
                return
            end
            waveVariants[w.slot] = variants
            resolved[#resolved + 1] = { array = w.array, bases = bases }
        end
    end

    -- Every wave that this entry names must have produced rows. An entry that
    -- resolves to nothing would empty the director's list and spawn nobody.
    if #resolved == 0 then
        Utils.LogBad("[GATE] SCM_ApplyAssaultData() - " .. tostring(assaultRow) ..
                     " resolved to NO waves; keeping the native assault")
        return
    end

    -- Past this point nothing can throw, so the empty-then-fill is safe.
    director.Assault_NPCList_Wave1:Empty()
    director.Assault_NPCList_Wave2:Empty()
    director.Assault_NPCList_Wave3:Empty()
    director.Assault_NPCList_BossWave:Empty()

    local written = 0
    for _, r in ipairs(resolved) do
        Utils.SetFNameArray(director[r.array], r.bases)
        written = written + #r.bases
    end

    -- Verify, don't assume: SetFNameArray grows the TArray by index-append and
    -- then ForEach-sets each element. If a UE4SS build stops honouring that,
    -- every array comes back empty and the assault silently evaporates.
    local landed = 0
    pcall(function()
        landed = (director.Assault_NPCList_Wave1:GetArrayNum() or 0)
               + (director.Assault_NPCList_Wave2:GetArrayNum() or 0)
               + (director.Assault_NPCList_Wave3:GetArrayNum() or 0)
               + (director.Assault_NPCList_BossWave:GetArrayNum() or 0)
    end)
    if landed < written then
        Utils.LogBad(string.format(
            "[GATE] SCM_ApplyAssaultData() - wrote %d NPC rows but the director only has %d. " ..
            "This assault will spawn short or not at all.", written, landed))
    end

    LogDebug(string.format("[GATE] SCM_ApplyAssaultData() - %s: %d NPC rows across %d waves",
        tostring(assaultRow), landed, #resolved), CONFIG.DEBUG_LOG)

    AB.PublishPlan(waveVariants)

    -- Everything below lives on Assault_CurrentData (assDirector), which can be
    -- nil on the first forced assault of a session - the director lazy-loads it.
    -- Skip gracefully; the NPC lists above are the part that matters.
    local hasAssDir = assDirector and IsValid(assDirector)
    if not hasAssDir then
        if data.Wave1Time or data.PrepTime or data.WarningMessage or data.StartMessage then
            LogDebug("[GATE] SCM_ApplyAssaultData() - director assault not ready. " ..
                     "Skipping CustomAssault for assault " .. tostring(assaultRow), CONFIG.DEBUG_LOG)
        end
        return
    end

    -- Spawn rates
    if data.Wave1Time    then assDirector.SpawnRate_Wave1_51_A581A0FF4929204673F831B606F107BB    = data.Wave1Time    end
    if data.Wave2Time    then assDirector.SpawnRate_Wave2_52_C22A1E2D460359824DC44C976D16912F    = data.Wave2Time    end
    if data.Wave3Time    then assDirector.SpawnRate_Wave3_53_103CE75749AD731024F5C1BDA2F877DC    = data.Wave3Time    end
    if data.BossWaveTime then assDirector.SpawnRate_BossWave_54_256D1A7141EFD7796B16D998642B14C9 = data.BossWaveTime end

    -- Messages
    if data.WarningMessage then assDirector.AssaultWarningText_18_284D22564719BD07A425ACA3639B5BBC  = FText(data.WarningMessage) end
    if data.StartMessage   then assDirector.AssaultStartedText_19_1C0D1F3247831C1BF02A73882F8399D5 = FText(data.StartMessage)   end

    -- PrepTime
    if data.PrepTime then assDirector.AssaultPrepTime_58_3CA2B5904E9FE2EB428ABEAFF52C6B4E = data.PrepTime end

    -- Sounds
    if data.StartSound then
        local sound = StaticFindObject(data.StartSound)
        if sound and IsValid(sound) then
            assDirector.AssaultStartSound_35_4C12A2EC4C2B953ED7CD86922FABDAAF = sound
        end
    end
end



-- ============================================================
-- When an assault is happening, AssaultTick is called periodically.
-- Throttled to ~3 s in AssaultHooks.
--
-- (1) CONFIG.ASSAULT_NPCS_RUN
--     Push non-combat assault NPCs into combat so they actually attack.
--
-- (2) Specific NPC assault triggers
--      * Containment Bot: We need to stop these from grabbing or they hold their target 
--          for several minutes         
-- ============================================================
function AM.OnAssaultTick(director)
    local assaultNPCs = director.AssaultNPCs
    if not assaultNPCs then return end

    local assaultSize = assaultNPCs:GetArrayNum()
    if not assaultSize or assaultSize == 0 then return end

    local targetBench = director.TargetAssaultBench

    local directorData = director.Assault_CurrentData
    if IsNotValid(directorData) then return end
    

    for i = 1, assaultSize do
        local npc = assaultNPCs[i]
        if Utils.IsActorInvalid(npc) or npc.IsDead then goto next end

        -- (1) Force Assault NPCs in combat if configured
        if CONFIG.ASSAULT_NPCS_RUN and IsValid(targetBench) and not npc.CombatState then
            Utils.ForceAttackTarget(npc, targetBench)
        end

        -- (2) Prevent assault Containment Bots from grabbing
        local name = Utils.GetActorName(npc)

        if name == "Containment Robot" then
            
            -- Put grab on cooldown
            npc.GrabCooldown             = 99999
            npc.TimeOfLastGrabAttempt    = 99999
            npc.TimeOfLastSuccessfulGrab = 99999

            -- Just in case it does grab, force it to drop
            local held = npc.HoldingCharacter
            if IsValid(held) then
                local ok, err = pcall(function()
                    npc:DropHoldingCharacter()
                end)
            end
        end 

        ::next::
    end 
end




-- ----------------------------------------------------------------
-- Helpers, could be local but keeping these below
-- ----------------------------------------------------------------

function AM.MakeAssaultKey(row, i)
    return row .. "_" .. (i or 1)
end

-- Ignore recency until Manufacturing
function AM.IsRecentAssault(row, i)
    if STATE.StoryProgress < 20 then return end

    local key = AM.MakeAssaultKey(row, i)
    for _, k in ipairs(STATE.RecentAssaults) do
        if k == key then return true end
    end
    return false
end

function AM.TrackAssault(row, i)
    table.insert(STATE.RecentAssaults, 1, AM.MakeAssaultKey(row, i))
    while #STATE.RecentAssaults > RECENT_HISTORY_SIZE do
        table.remove(STATE.RecentAssaults)
    end
end


return AM
