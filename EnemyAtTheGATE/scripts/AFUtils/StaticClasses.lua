--[[
    Author: Igromanru
    Created Date: 19.08.2024
    Description: Utility functions for the game Abiotic Factor
]]

require("AFUtils.AFBase")

local Actor_Class = CreateInvalidObject()
---@return UClass
function AFUtils.GetClassActor()
    if IsNotValid(Actor_Class) then
        Actor_Class = StaticFindObject("/Script/Engine.Actor")
        ---@cast Actor_Class UClass
    end
    return Actor_Class
end

local SkeletalMeshActor_Class = CreateInvalidObject()
---@return UClass
function AFUtils.GetClassSkeletalMeshActor()
    if IsNotValid(SkeletalMeshActor_Class) then
        SkeletalMeshActor_Class = StaticFindObject("/Script/Engine.SkeletalMeshActor")
        ---@cast SkeletalMeshActor_Class UClass
    end
    return SkeletalMeshActor_Class
end

local AbioticGameViewportClientClass = CreateInvalidObject()
---@return UClass
function AFUtils.GetClassAbioticGameViewportClient()
    if IsNotValid(AbioticGameViewportClientClass) then
        AbioticGameViewportClientClass = StaticFindObject("/Script/AbioticFactor.AbioticGameViewportClient")
        ---@cast AbioticGameViewportClientClass UClass
    end
    return AbioticGameViewportClientClass
end

local Abiotic_Survival_GameState_C_Class = CreateInvalidObject()
---@return UClass
function AFUtils.GetClassAbiotic_Survival_GameState_C()
    if IsNotValid(Abiotic_Survival_GameState_C_Class) then
        Abiotic_Survival_GameState_C_Class = StaticFindObject("/Game/Blueprints/Meta/Abiotic_Survival_GameState.Abiotic_Survival_GameState_C")
        ---@cast Abiotic_Survival_GameState_C_Class UClass
    end
    return Abiotic_Survival_GameState_C_Class
end

local Abiotic_Survival_GameMode_C_Class = CreateInvalidObject()
---@return UClass
function AFUtils.GetClassAbiotic_Survival_GameMode_C()
    if IsNotValid(Abiotic_Survival_GameMode_C_Class) then
        Abiotic_Survival_GameMode_C_Class = StaticFindObject("/Game/Blueprints/Meta/Abiotic_Survival_GameMode.Abiotic_Survival_GameMode_C")
        ---@cast Abiotic_Survival_GameMode_C_Class UClass
    end
    return Abiotic_Survival_GameMode_C_Class
end

local Abiotic_GameInstance_C_Class = CreateInvalidObject()
---@return UClass
function AFUtils.GetClassAbiotic_GameInstance_C()
    if IsNotValid(Abiotic_GameInstance_C_Class) then
        Abiotic_GameInstance_C_Class = StaticFindObject("/Game/Blueprints/Meta/Abiotic_GameInstance.Abiotic_GameInstance_C")
        ---@cast Abiotic_GameInstance_C_Class UClass
    end
    return Abiotic_GameInstance_C_Class
end

local Abiotic_PlayerController_C_Class = CreateInvalidObject()
---@return UClass
function AFUtils.GetClassAbiotic_PlayerController_C()
    if IsNotValid(Abiotic_PlayerController_C_Class) then
        Abiotic_PlayerController_C_Class = StaticFindObject("/Game/Blueprints/Meta/Abiotic_PlayerController.Abiotic_PlayerController_C")
        ---@cast Abiotic_PlayerController_C_Class UClass
    end
    return Abiotic_PlayerController_C_Class
end

local Abiotic_PlayerCharacter_C_Class = CreateInvalidObject()
---@return UClass
function AFUtils.GetClassAbiotic_PlayerCharacter_C()
    if IsNotValid(Abiotic_PlayerCharacter_C_Class) then
        Abiotic_PlayerCharacter_C_Class = StaticFindObject("/Game/Blueprints/Characters/Abiotic_PlayerCharacter.Abiotic_PlayerCharacter_C")
        ---@cast Abiotic_PlayerCharacter_C_Class UClass
    end
    return Abiotic_PlayerCharacter_C_Class
end

local Abiotic_Item_ParentBP_C_Class = CreateInvalidObject()
---@return UClass
function AFUtils.GetClassAbiotic_Item_ParentBP_C()
    if IsNotValid(Abiotic_Item_ParentBP_C_Class) then
        Abiotic_Item_ParentBP_C_Class = StaticFindObject("/Game/Blueprints/Items/Abiotic_Item_ParentBP.Abiotic_Item_ParentBP_C")
        ---@cast Abiotic_Item_ParentBP_C_Class UClass
    end
    return Abiotic_Item_ParentBP_C_Class
end

local AbioticDeployed_ParentBP_C_Class = CreateInvalidObject()
---@return UClass
function AFUtils.GetClassAbioticDeployed_ParentBP_C()
    if IsNotValid(AbioticDeployed_ParentBP_C_Class) then
        AbioticDeployed_ParentBP_C_Class = StaticFindObject("/Game/Blueprints/DeployedObjects/AbioticDeployed_ParentBP.AbioticDeployed_ParentBP_C")
        ---@cast AbioticDeployed_ParentBP_C_Class UClass
    end
    return AbioticDeployed_ParentBP_C_Class
end

local RechargeableComponent_C_Class = CreateInvalidObject()
---@return UClass
function AFUtils.GetClassRechargeableComponent_C()
    if IsNotValid(RechargeableComponent_C_Class) then
        RechargeableComponent_C_Class = StaticFindObject("/Game/Blueprints/Items/RechargeableComponent.RechargeableComponent_C")
        ---@cast RechargeableComponent_C_Class UClass
    end
    return RechargeableComponent_C_Class
end

local Deployed_Battery_ParentBP_C_Class = CreateInvalidObject()
---@return UClass
function AFUtils.GetClassDeployed_Battery_ParentBP_C()
    if IsNotValid(Deployed_Battery_ParentBP_C_Class) then
        Deployed_Battery_ParentBP_C_Class = StaticFindObject("/Game/Blueprints/DeployedObjects/Misc/Deployed_Battery_ParentBP.Deployed_Battery_ParentBP_C")
        ---@cast Deployed_Battery_ParentBP_C_Class UClass
    end
    return Deployed_Battery_ParentBP_C_Class
end

local Abiotic_Item_Dropped_C_Class = CreateInvalidObject()
---@return UClass
function AFUtils.GetClassAbiotic_Item_Dropped_C()
    if IsNotValid(Abiotic_Item_Dropped_C_Class) then
        Abiotic_Item_Dropped_C_Class = StaticFindObject("/Game/Blueprints/Items/Abiotic_Item_Dropped.Abiotic_Item_Dropped_C")
        ---@cast Abiotic_Item_Dropped_C_Class UClass
    end
    return Abiotic_Item_Dropped_C_Class
end

local Abiotic_Weapon_ParentBP_C_Class = CreateInvalidObject()
---@return UClass
function AFUtils.GetClassAbiotic_Weapon_ParentBP_C()
    if IsNotValid(Abiotic_Weapon_ParentBP_C_Class) then
        Abiotic_Weapon_ParentBP_C_Class = StaticFindObject("/Game/Blueprints/Items/Weapons/Abiotic_Weapon_ParentBP.Abiotic_Weapon_ParentBP_C")
        ---@cast Abiotic_Weapon_ParentBP_C_Class UClass
    end
    return Abiotic_Weapon_ParentBP_C_Class
end

local Abiotic_Character_ParentBP_C_Class = CreateInvalidObject()
---@return UClass
function AFUtils.GetClassAbiotic_Character_ParentBP_C()
    if IsNotValid(Abiotic_Character_ParentBP_C_Class) then
        Abiotic_Character_ParentBP_C_Class = StaticFindObject("/Game/Blueprints/Characters/Abiotic_Character_ParentBP.Abiotic_Character_ParentBP_C")
        ---@cast Abiotic_Character_ParentBP_C_Class UClass
    end
    return Abiotic_Character_ParentBP_C_Class
end

local NPC_Base_ParentBP_C_Class = CreateInvalidObject()
---@return UClass
function AFUtils.GetClassNPC_Base_ParentBP_C()
    if IsNotValid(NPC_Base_ParentBP_C_Class) then
        NPC_Base_ParentBP_C_Class = StaticFindObject("/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C")
        ---@cast NPC_Base_ParentBP_C_Class UClass
    end
    return NPC_Base_ParentBP_C_Class
end

local NarrativeNPC_ParentBP_C_Class = CreateInvalidObject()
---@return UClass
function AFUtils.GetClassNarrativeNPC_ParentBP_C()
    if IsNotValid(NarrativeNPC_ParentBP_C_Class) then
        NarrativeNPC_ParentBP_C_Class = StaticFindObject("/Game/Blueprints/Characters/NarrativeNPCs/NarrativeNPC_ParentBP.NarrativeNPC_ParentBP_C")
        ---@cast NarrativeNPC_ParentBP_C_Class UClass
    end
    return NarrativeNPC_ParentBP_C_Class
end

local CharacterCorpse_Human_BP_C_Class = CreateInvalidObject()
---@return UClass
function AFUtils.GetClassCharacterCorpse_Human_BP_C()
    if IsNotValid(CharacterCorpse_Human_BP_C_Class) then
        CharacterCorpse_Human_BP_C_Class = StaticFindObject("/Game/Blueprints/Environment/Special/CharacterCorpse_Human_BP.CharacterCorpse_Human_BP_C")
        ---@cast CharacterCorpse_Human_BP_C_Class UClass
    end
    return CharacterCorpse_Human_BP_C_Class
end

local NarrativeNPC_Human_ParentBP_C_Class = CreateInvalidObject()
---@return UClass
function AFUtils.GetClassNarrativeNPC_Human_ParentBP_C()
    if IsNotValid(NarrativeNPC_Human_ParentBP_C_Class) then
        NarrativeNPC_Human_ParentBP_C_Class = StaticFindObject("/Game/Blueprints/Characters/NarrativeNPCs/NarrativeNPC_Human_ParentBP.NarrativeNPC_Human_ParentBP_C")
        ---@cast NarrativeNPC_Human_ParentBP_C_Class UClass
    end
    return NarrativeNPC_Human_ParentBP_C_Class
end

local CharacterCorpse_ParentBP_Class = CreateInvalidObject()
---@return UClass
function AFUtils.GetClassCharacterCorpse_ParentBP()
    if IsNotValid(CharacterCorpse_ParentBP_Class) then
        CharacterCorpse_ParentBP_Class = StaticFindObject("/Game/Blueprints/Environment/Special/CharacterCorpse_ParentBP.CharacterCorpse_ParentBP_C")
        ---@cast CharacterCorpse_ParentBP_Class UClass
    end
    return CharacterCorpse_ParentBP_Class
end

local Deployed_Toilet_Portal_C_Class = CreateInvalidObject()
---@return UClass
function AFUtils.GetClassDeployed_Toilet_Portal_C()
    if IsNotValid(Deployed_Toilet_Portal_C_Class) then
        Deployed_Toilet_Portal_C_Class = StaticFindObject("/Game/Blueprints/DeployedObjects/Furniture/Deployed_Toilet_Portal.Deployed_Toilet_Portal_C")
        ---@cast Deployed_Toilet_Portal_C_Class UClass
    end
    return Deployed_Toilet_Portal_C_Class
end

local Item_Gear_KeypadHacker_C_Class = CreateInvalidObject()
---@return UClass
function AFUtils.GetClassItem_Gear_KeypadHacker_C()
    if IsNotValid(Item_Gear_KeypadHacker_C_Class) then
        Item_Gear_KeypadHacker_C_Class = StaticFindObject("/Game/Blueprints/Items/Gear/Item_Gear_KeypadHacker.Item_Gear_KeypadHacker_C")
        ---@cast Item_Gear_KeypadHacker_C_Class UClass
    end
    return Item_Gear_KeypadHacker_C_Class
end

local Abiotic_CharacterSave_C_Class = CreateInvalidObject()
---@return UClass
function AFUtils.GetClassAbiotic_CharacterSave_C()
    if IsNotValid(Abiotic_CharacterSave_C_Class) then
        Abiotic_CharacterSave_C_Class = StaticFindObject("/Game/Blueprints/Saves/Abiotic_CharacterSave.Abiotic_CharacterSave_C")
        ---@cast Abiotic_CharacterSave_C_Class UClass
    end
    return Abiotic_CharacterSave_C_Class
end

local GardenPlot_ParentBP_C_Class = CreateInvalidObject()
---@return UClass
function AFUtils.GetClassGardenPlot_ParentBP_C()
    if IsNotValid(GardenPlot_ParentBP_C_Class) then
        GardenPlot_ParentBP_C_Class = StaticFindObject("/Game/Blueprints/DeployedObjects/Farming/GardenPlot_ParentBP.GardenPlot_ParentBP_C")
        ---@cast GardenPlot_ParentBP_C_Class UClass
    end
    return GardenPlot_ParentBP_C_Class
end

local Weapon_FishingRod_C_Class = CreateInvalidObject()
---@return UClass
function AFUtils.GetClassWeapon_FishingRod_C()
    if IsNotValid(Weapon_FishingRod_C_Class) then
        Weapon_FishingRod_C_Class = StaticFindObject("/Game/Blueprints/Items/Weapons/Guns/Weapon_FishingRod.Weapon_FishingRod_C")
        ---@cast Weapon_FishingRod_C_Class UClass
    end
    return Weapon_FishingRod_C_Class
end

return AFUtils