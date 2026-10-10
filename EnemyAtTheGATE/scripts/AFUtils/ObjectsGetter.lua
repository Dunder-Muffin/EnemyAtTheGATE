--[[
    Author: Igromanru
    Created Date: 19.08.2024
    Description: Utility functions for the game Abiotic Factor
]]

local UEHelpers = require("UEHelpers")
require("AFUtils.AFBase")
require("AFUtils.StaticClasses")
require("AFUtils.DefaultObjects")

---Returns current AAbiotic_PlayerController_C
---@return AAbiotic_PlayerController_C
function AFUtils.GetMyPlayerController()
    local myPlayerController = GetMyPlayerController() ---@cast myPlayerController AAbiotic_PlayerController_C
    if IsValid(myPlayerController) and myPlayerController:IsA(AFUtils.GetClassAbiotic_PlayerController_C()) then
        return myPlayerController
    end
    return CreateInvalidObject() ---@type AAbiotic_PlayerController_C
end

---Returns player's AAbiotic_PlayerController_C
---@param PlayerCharacter AAbiotic_PlayerCharacter_C
---@return AAbiotic_PlayerController_C
function AFUtils.GetPlayerController(PlayerCharacter)
    if IsValid(PlayerCharacter) and PlayerCharacter.MyPlayerController then
        return PlayerCharacter.MyPlayerController
    end
    return CreateInvalidObject() ---@type AAbiotic_PlayerController_C
end

---Returns current controlled player
---@return AAbiotic_PlayerCharacter_C
function AFUtils.GetMyPlayer()
    local playerController = AFUtils.GetMyPlayerController()
    if IsValid(playerController) then
        return playerController.MyPlayerCharacter
    end
    return CreateInvalidObject() ---@type AAbiotic_PlayerCharacter_C
end

local PlayerStateCache = CreateInvalidObject() ---@cast PlayerStateCache AAbiotic_PlayerState_C
---Returns player state of current player
---@return AAbiotic_PlayerState_C
function AFUtils.GetMyPlayerState()
    if IsValid(PlayerStateCache) then
        return PlayerStateCache
    end

    local myPlayer = AFUtils.GetMyPlayer()
    if IsValid(myPlayer) then
        PlayerStateCache = myPlayer.MyPlayerState
    end

    return PlayerStateCache
end

---Returns current player's inventory
---@return UAbiotic_InventoryComponent_C
function AFUtils.GetMyInventoryComponent()
    local myPlayer = AFUtils.GetMyPlayer()
    if IsValid(myPlayer) and myPlayer.CharacterInventory then
        return myPlayer.CharacterInventory
    end
    return CreateInvalidObject() ---@type UAbiotic_InventoryComponent_C
end

---Returns current player's equipment inventory
---@return UAbiotic_InventoryComponent_C
function AFUtils.GetMyEquipmentInventory()
    local myPlayer = AFUtils.GetMyPlayer()
    if IsValid(myPlayer) and myPlayer.CharacterEquipSlotInventory then
        return myPlayer.CharacterEquipSlotInventory
    end
    return CreateInvalidObject() ---@type UAbiotic_InventoryComponent_C
end

---Returns current player's hotbar inventory
---@return UAbiotic_InventoryComponent_C
function AFUtils.GetMyHotbarInventory()
    local myPlayer = AFUtils.GetMyPlayer()
    if IsValid(myPlayer) and myPlayer.CharacterHotbarInventory then
        return myPlayer.CharacterHotbarInventory
    end
    return CreateInvalidObject() ---@type UAbiotic_InventoryComponent_C
end

---Returns current player inventory widget
---@return UW_PlayerInventory_Main_C
function AFUtils.GetMyPlayerInventory()
    local myPlayer = AFUtils.GetMyPlayer()
    if IsValid(myPlayer) and myPlayer.InventoryReference then
        return myPlayer.InventoryReference
    end
    return CreateInvalidObject() ---@type UW_PlayerInventory_Main_C
end

---Returns current crafting area
---@return UW_Inventory_CraftingArea_C
function AFUtils.GetMyInventoryCraftingArea()
    local myPlayerInventory = AFUtils.GetMyPlayerInventory()
    if IsValid(myPlayerInventory) and myPlayerInventory.W_Inventory_CraftingArea then
        return myPlayerInventory.W_Inventory_CraftingArea
    end
    return CreateInvalidObject() ---@type UW_Inventory_CraftingArea_C
end


---Returns player's CharacterProgressionComponent
---@return UAbiotic_CharacterProgressionComponent_C
function AFUtils.GetMyCharacterProgressionComponent()
    local myPlayer = AFUtils.GetMyPlayer()
    if IsValid(myPlayer) and myPlayer.CharacterProgressionComponent then
        return myPlayer.CharacterProgressionComponent
    end

    return CreateInvalidObject() ---@type UAbiotic_CharacterProgressionComponent_C
end

---Returns PlayerHUD
---@return UW_PlayerHUD_Main_C
function AFUtils.GetMyPlayerHUD()
    local playerController = AFUtils.GetMyPlayerController()
    if IsValid(playerController) and playerController.PlayerHUDRef then
        return playerController.PlayerHUDRef
    end
    return CreateInvalidObject() ---@type UW_PlayerHUD_Main_C
end

 ---@return UAbiotic_GameInstance_C
 function AFUtils.GetGameInstance()
    local gameInstance = UEHelpers.GetGameInstance() ---@cast gameInstance UAbiotic_GameInstance_C
    if IsValid(gameInstance) and gameInstance:IsA(AFUtils.GetClassAbiotic_GameInstance_C()) then
        return gameInstance
    end
    return CreateInvalidObject() ---@type UAbiotic_GameInstance_C
 end

---Returns current AAbiotic_Survival_GameMode_C
---@return AAbiotic_Survival_GameMode_C
function AFUtils.GetSurvivalGameMode()
    local gameMode = GetGameModeBase() ---@cast gameMode AAbiotic_Survival_GameMode_C
    if IsValid(gameMode) and gameMode:IsA(AFUtils.GetClassAbiotic_Survival_GameMode_C()) then
        return gameMode
    end
    return CreateInvalidObject() ---@type AAbiotic_Survival_GameMode_C
end

---Returns current AAbiotic_Survival_GameMode_C
---@return AAbiotic_Survival_GameState_C
function AFUtils.GetSurvivalGameState()
    local gameState = GetGameStateBase() ---@cast gameState AAbiotic_Survival_GameState_C
    if IsValid(gameState) and gameState:IsA(AFUtils.GetClassAbiotic_Survival_GameState_C()) then
        return gameState
    end
    return CreateInvalidObject() ---@type AAbiotic_Survival_GameState_C
end

---@return UAbiotic_CharacterSave_C
function AFUtils.GetMyCharacterSave()
    local gameInstance = AFUtils.GetGameInstance()
    local playerState = AFUtils.GetMyPlayerState()
    if IsValid(gameInstance) and IsValid(playerState) then
        local playerSave = gameInstance:GetPlayerSave(playerState.UniquePlayerID, false)
        if IsValid(playerSave) and playerSave:IsA(AFUtils.GetClassAbiotic_CharacterSave_C())  then
            ---@cast playerSave UAbiotic_CharacterSave_C
            return playerSave
        end
    end
    return CreateInvalidObject() ---@type UAbiotic_CharacterSave_C
end

---@return UAbiotic_CharacterSave_C
function AFUtils.GetMyPendingCharacterSave()
    local gameInstance = AFUtils.GetGameInstance()
    local playerState = AFUtils.GetMyPlayerState()
    if IsValid(gameInstance) and IsValid(playerState) and gameInstance.PendingPlayerSaves and #gameInstance.PendingPlayerSaves > 0 then
        local myUniqueId = playerState.UniquePlayerID:ToString()
        for i = 1, #gameInstance.PendingPlayerSaves do
            local playerSave = gameInstance.PendingPlayerSaves[i]
            if IsValid(playerSave) and playerSave:IsA(AFUtils.GetClassAbiotic_CharacterSave_C()) and playerSave.SaveIdentifier:ToString() == myUniqueId then
                ---@cast playerSave UAbiotic_CharacterSave_C
                return playerSave
            end
        end
    end
    return CreateInvalidObject() ---@type UAbiotic_CharacterSave_C
end

local AIDirectorCache = CreateInvalidObject() ---@cast AIDirectorCache AAbiotic_AIDirector_C
---Returns current AAbiotic_AIDirector_C
---@return AAbiotic_AIDirector_C
function AFUtils.GetAIDirector()
    if IsValid(AIDirectorCache) then
        return AIDirectorCache
    end

    local gameMode = AFUtils.GetSurvivalGameMode()
    if IsValid(gameMode) and gameMode.AI_Director then
        AIDirectorCache = gameMode.AI_Director
    end
    
    return AIDirectorCache
end

---Returns current ULeyakDirectorComponent_C
---@return ULeyakDirectorComponent_C
function AFUtils.GetLeyakDirectorComponent()
    local aiDirector = AFUtils.GetAIDirector()
    if IsValid(aiDirector) then
        return aiDirector.LeyakDirectorComponent
    end
    
    return CreateInvalidObject() ---@type ULeyakDirectorComponent_C
end

---Returns current UKrasueDirectorComponent_C
---@return UKrasueDirectorComponent_C
function AFUtils.GetKrasueDirectorComponent()
    local aiDirector = AFUtils.GetAIDirector()
    if IsValid(aiDirector) then
        return aiDirector.KrasueDirectorComponent
    end
    
    return CreateInvalidObject() ---@type UKrasueDirectorComponent_C
end

local DayNightManagerCache = CreateInvalidObject() ---@cast DayNightManagerCache ADayNightManager_C
---Retruns current ADayNightManager_C
---@return ADayNightManager_C
function AFUtils.GetDayNightManager()
    local aiDirector = AFUtils.GetAIDirector()
    if IsValid(aiDirector) and aiDirector.DayNightManager then
        DayNightManagerCache = aiDirector.DayNightManager
    end
    return DayNightManagerCache
end

local AIControllerLeyakCache = CreateInvalidObject() ---@cast AIControllerLeyakCache AAI_Controller_Leyak_C
---Returns current AAI_Controller_Leyak_C
---@return AAI_Controller_Leyak_C
function AFUtils.GetAIControllerLeyak()
    if IsValid(AIControllerLeyakCache) then
        return AIControllerLeyakCache
    end
    
    AIControllerLeyakCache = FindFirstOf("AI_Controller_Leyak_C") ---@cast AIControllerLeyakCache AAI_Controller_Leyak_C
    return AIControllerLeyakCache
end

---Search for player state by UniquePlayerId
---@param PlayerId FString|string
---@return AAbiotic_PlayerState_C
function AFUtils.GetPlayerStateById(PlayerId)
    if type(PlayerId) == "userdata" and PlayerId:type() == "FString" then
        PlayerId = PlayerId:ToString()
    end
    if type(PlayerId) == "string" and PlayerId ~= "" then
        local gameState = AFUtils.GetSurvivalGameState()
        if IsValid(gameState) and gameState.PlayerArray then
            for i = 1, #gameState.PlayerArray do
                local playerState = gameState.PlayerArray[i] ---@cast playerState AAbiotic_PlayerState_C
                if playerState.UniquePlayerID and playerState.UniquePlayerID:ToString() == PlayerId then
                    return playerState
                end
            end
        end
    end
    return CreateInvalidObject() ---@type AAbiotic_PlayerState_C
end

---Search for player by UniquePlayerId
---@param PlayerId FString|string
---@return AAbiotic_PlayerCharacter_C
function AFUtils.GetPlayerById(PlayerId)
    local playerState = AFUtils.GetPlayerStateById(PlayerId)
    if IsValid(playerState) and playerState.PawnPrivate then
        return playerState.PawnPrivate ---@type AAbiotic_PlayerCharacter_C
    end
    return CreateInvalidObject() ---@type AAbiotic_PlayerCharacter_C
end

---Returns struct that represents current selected slot in the hotbat aka. held item
---@param PlayerCharacter AAbiotic_PlayerCharacter_C
---@return FInventorySlotSelected_Struct?
function AFUtils.GetCurrentHotbarSlotSelected(PlayerCharacter)
    if IsValid(PlayerCharacter) and PlayerCharacter.CurrentHotbarSlotSelected:IsValid() then
        return PlayerCharacter.CurrentHotbarSlotSelected
    end
    return nil
end

---Retruns struct that represents the current selected Hotbar item slot, it's inventory component and SlotIndex. The item can be modified through ChangeableData.
---@param PlayerCharacter AAbiotic_PlayerCharacter_C
---@return FAbiotic_InventoryItemSlotStruct? # Can be used to modify item's data though ChangeableData
---@return UAbiotic_InventoryComponent_C? # Parent InventoryComponent
---@return integer? # Slot index
function AFUtils.GetSelectedHotbarInventoryItemSlot(PlayerCharacter)
    local slotData = AFUtils.GetCurrentHotbarSlotSelected(PlayerCharacter)
    if slotData and slotData.Inventory_2_B69CD60741EFD551F09ED5AFF44B1E46:IsValid() then
        local inventory = slotData.Inventory_2_B69CD60741EFD551F09ED5AFF44B1E46
        local luaIndex = slotData.Index_5_6BDC7B3944A5DE0B319F9FA20720872F + 1
        if inventory.CurrentInventory and #inventory.CurrentInventory >= luaIndex then
            return inventory.CurrentInventory[luaIndex], inventory, slotData.Index_5_6BDC7B3944A5DE0B319F9FA20720872F
        end
    end
    return nil, nil, nil
end

---Get current held weapon for a player
---@param PlayerCharacter AAbiotic_PlayerCharacter_C #If nil, will use the local player
---@return AAbiotic_Weapon_ParentBP_C?
function AFUtils.GetCurrentWeapon(PlayerCharacter)
    PlayerCharacter = PlayerCharacter or AFUtils.GetMyPlayer()
    if IsNotValid(PlayerCharacter) then return nil end

    local weapon = PlayerCharacter.ItemInHand_BP ---@cast weapon AAbiotic_Weapon_ParentBP_C
    if IsValid(weapon) and weapon:IsA(AFUtils.GetClassAbiotic_Weapon_ParentBP_C()) and not weapon:IsA(AFUtils.GetClassWeapon_FishingRod_C()) then
        return weapon
    end
    return nil
end

---@param Inventory UAbiotic_InventoryComponent_C
---@param SlotIndex integer
---@return FAbiotic_InventoryItemSlotStruct?
function AFUtils.GetInventoryItemSlot(Inventory, SlotIndex)
    if IsNotValid(Inventory) or not SlotIndex or SlotIndex < 0 then return nil end

    -- Lua array starts with 1, while TArray with 0
    local index = SlotIndex + 1
    if Inventory.CurrentInventory and #Inventory.CurrentInventory >= index then
        return Inventory.CurrentInventory[index]
    end

    return nil
end