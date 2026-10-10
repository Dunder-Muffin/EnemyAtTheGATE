-- =======================================================================
-- Schema - the game-build switch. Every struct field name, row-handle shape and asset path that
-- differs between game builds lives here; the rest of the mod asks.
--   * LEGACY = the Blueprint-struct layout: Blueprint row structs, GUID-suffixed field names,
--     FDataTableRowHandle / bare-FName row references.
--   * NATIVE = the C++-struct layout of later builds: C++ row structs, clean names, typed F<X>RowHandle {RowName}.
--   * Plan, rules and the old->new name data: AnNotes/AnteSystems/NativeMigration.md.
-- =======================================================================

local SCHEMA = {}

-- -----------------------------------------------------------------------
-- Detection (script load)
--   * By FName-pool lookup: names only a native-layout build registers. The pool is thread-safe; script
--     load may not run on the game thread, where a StaticFindObject can meet a GC and abort.
--   * SCHEMA.Verify re-checks with StaticFindObject from InitMod, on the game thread.
-- -----------------------------------------------------------------------

local NATIVE_MARKERS = { "NPCHandleFunctionLibrary", "NPCRowHandle" }
local NATIVE_CLASS   = "/Script/AbioticFactor.AbioticDamageType"

local function nameRegistered(s)
    local ok, found = pcall(function() return FName(s, EFindName.FNAME_Find) ~= NAME_None end)
    return ok and found == true
end

SCHEMA.Native = false
for _, marker in ipairs(NATIVE_MARKERS) do
    if nameRegistered(marker) then
        SCHEMA.Native = true
        break
    end
end
SCHEMA.Label = SCHEMA.Native and "NATIVE" or "LEGACY"

-- -----------------------------------------------------------------------
-- Field names, one table per struct, KEYED BY THE NATIVE NAME.
--   * Only the legacy spelling is listed: native = the key itself.
--   * Only fields the mod uses. Add one here before using it anywhere else.
--   * Reading a key that isn't listed throws, so a typo fails at the first read.
-- -----------------------------------------------------------------------

local LEGACY = {
    NPC = {   -- FAbiotic_NPCStruct -> FAbioticNPC
        AchievementStat          = "AchievementStat_136_246B5AD74BC67B9850CA0CA33E4755AC",
        CanBashOpenDoors         = "CanBashOpenDoors_110_0C2F50854675CCB520EEFC8B762677C4",
        CanOpenDoors             = "CanOpenDoors_77_CAD75EB947C7C78F76846FA22BBF8DAE",
        CompendiumKill           = "CompendiumKill_142_C1A9B2AB45F0A33DE67D23BF710B930D",
        DamageType_Melee         = "DamageType_Melee_84_C959B7F94F2B504041ADBAAA9C5AF7DE",
        DamageType_Ranged        = "DamageType_Ranged_85_E98D2E5C42F02821A9EC4CA77F454AF0",
        DefaultFaction           = "DefaultFaction_12_4111F03F450FC48D854F62B533ADF4A7",
        DefaultSprintSpeed       = "DefaultSprintSpeed_18_F44E4C8A4F87079E4A5710984C1DF4EC",
        DefaultWalkSpeed         = "DefaultWalkSpeed_17_311EDFE249A63474E18512B1E0BA66D4",
        DisplayName              = "DisplayName_9_5C4263DF4E1C7D38B677D7A3755C44E8",
        GibInfo                  = "GibInfo_93_85C59FF64049C8D27AA681B7FAE7780D",
        HasDBNOState             = "HasDBNOState_53_969EEA6044826C92D7C791A275736E87",
        HasRangedAttack          = "HasRangedAttack_25_A22819164FDBB42E27EA22A68EF90767",
        HP_Head                  = "HP_Head_42_B6C672214D769CFF8ADD09BC740F0855",
        HP_LeftArm               = "HP_LeftArm_43_3759F0B24516CB52D327D19BC0D7B199",
        HP_LeftLeg               = "HP_LeftLeg_45_DC2A3E8642BBF43316D529937D64ADB6",
        HP_RightArm              = "HP_RightArm_44_91DEABCD44E1CAECCD5AC5997D2763FE",
        HP_RightLeg              = "HP_RightLeg_47_BDF050784072C9B3BA05C5813B7B599A",
        HP_Torso                 = "HP_Torso_41_F869473149C739C907DE8FADA897657E",
        MeleeAttackDamagePerHit  = "MeleeAttackDamagePerHit_67_EDB3FAC04077970C606CD38276E2CCAD",
        NPC_Hit_XP_Multiplier    = "NPC_Hit_XP_Multiplier_108_D2C5D29B412F4D63256DB3B968495DEA",
        RangedAttackCooldown     = "RangedAttackCooldown_115_323C598445E2D5A3C66A97ABAC4F0BC1",
        RangedAttackDamagePerHit = "RangedAttackDamagePerHit_66_D033996345E36DA6D1E422A35BE68466",
        RangeToMeleeAttack       = "RangeToMeleeAttack_19_BD3B04004681AA59651B098842F63F06",
        RangeToRangedAttack      = "RangeToRangedAttack_20_6B3CAF6F44DB3656355981A94BB6B080",
        VoiceLines               = "VoiceLines_29_DD52970C470363E69342FC96F39AE4EC",
    },
    NPCDialog = {   -- FAbiotic_NPCDialogStruct -> FAbioticNPCDialog
        NormalDeathSounds    = "NormalDeathSounds_54_9B419A8F47F4F5497E6135A0880A581F",
        ScreamingDeathSounds = "ScreamingDeathSounds_56_D8100BA446DBCDF0146C7390965415B8",
    },
    Gib = {   -- FAbiotic_Gib_Struct -> FAbioticGib
        CanBeGibbed = "CanBeGibbed_6_D955B9AF47D23E73B370B497B8576D26",
        GibSalvage  = "GibSalvage_17_F342266B4DA5F48F1F2CF5A1776A9783",
    },
    SpawnEntry = {   -- FAbiotic_NPCSpawnsStruct -> FNPCSpawnEntry (renamed fields)
        NPCToSpawn        = "NPC_25_8522BD234E4A757C66AC12A637E91499",
        SpawnChanceWeight = "SpawnWeight_28_8EDDAE8949E891F09288CFBC5ECA1B6D",
        WorldFlagRequired = "WorldFlag_26_C7464581434F6CEB0BEA498F9C918EB4",
    },
    Item = {   -- FAbiotic_InventoryItemStruct -> FAbioticInventoryItem
        AttachSocketFP               = "FPAttachSocket_116_9BBC31B44A0C8DC200B003806CB6F10A",
        AttachSocketTP               = "TPAttachSocket_135_5DABD45F4B7CC7412C24F2A96BE45603",
        CanLoseDurability            = "CanLoseDurability_29_42EA515F4AC1EC69D8480DB36C01D5E1",
        ChanceToLoseDurability       = "ChanceToLoseDurability_97_DF967C464092E2E6AEEBFE84C536ACAB",
        ConsumableData               = "ConsumableData_84_757B6B114FF23016981BEF888A31C670",
        CookableData                 = "CookableData_94_7EFD1F0A4A7EFB44D3D8B9B14581BF36",
        DeployedItemClass            = "DeployedItemClass_33_2CB440284F44C59CE124E4A806544272",
        DeployHologramMesh           = "DeployHologramMesh_55_E52DCCC54303C0963597E2A66F16A038",
        EquipmentData                = "EquipmentData_100_576D05464F36104AFE501B878255E318",
        FPAnimationData              = "FPAnimationData_103_FFAE11A04A2E52F39BDCF5BA02948877",
        GameplayTags                 = "GameplayTags_138_C253BD3B4A4A21569AFC138CF0DDB59A",
        InventoryIcon                = "InventoryIcon_50_57AF4D5548B1985502D209AB8854A797",
        IsWeapon                     = "IsWeapon_63_57F6A703413EA260B1455CA81F2D4911",
        ItemClass                    = "ItemClass_7_A94CF32A438C7DF014B8E2AF8D01B0AB",
        ItemDescription              = "ItemDescription_38_E5F7B38A4F3C41EB9DA52CA14654D303",
        ItemName                     = "ItemName_51_B88648C048EE5BC2885E4E95F3E13F0A",
        LiquidData                   = "LiquidData_110_4D07F09C483C1E65B39024ABC7032FA0",
        MaxItemDurability            = "MaxItemDurability_31_6EBCEFC943F9E85DE9350BBC0E249447",
        PlacementOrientationsAllowed = "PlacementOrientationsAllowed_122_75894D7C4B93F103C06AB18421167757",
        Scale_Cooking                = "Scale_Cooking_152_328507B94E0FE12E2E2A938B5D4E8429",
        Scale_FirstPersonMesh        = "Scale_FirstPersonMesh_146_6AFCDB94484AE7625E73C6AFB835D21F",
        Scale_Hologram               = "Scale_Hologram_155_D2482E9E445F3E18BD348CB4D4FD231D",
        Scale_TPHeldMesh             = "Scale_TPHeldMesh_145_6826D00A4F30AEDBF62E02892E4261E6",
        Scale_WorldMesh              = "Scale_WorldMesh_143_AF66D856410026FCC19E70AC421B3667",
        StackSize                    = "StackSize_47_D124F11B4B6D9766B2B33699795845A9",
        TextureVariant               = "TextureVariant_132_ADE79DC6445FF43625192BAF413DD666",
        TryPlaceInHotbar             = "TryPlaceInHotbar_128_F78F6AA34A238AEAB278F48066C080BF",
        WeaponData                   = "WeaponData_61_3C29CF6C4A7F9DD435F9318FEE4B033D",
        Weight                       = "Weight_119_CE7DB430417207921D739CAF458D4D7C",
        WorldStaticMesh              = "WorldStaticMesh_19_71632A4B4A368D299BD41EA07881A95D",
    },
    Consumable = {   -- FAbiotic_Consumable_Struct -> FAbioticConsumable
        ArmorChange       = "ArmorChange_19_16C741BA4535E6F6100D07B69FC1A0EA",
        BuffsToAdd        = "BuffsToAdd_23_0A2DBBC447537E9C754279951429DB87",
        ContinenceFill    = "ContinenceFill_13_2B1EC44C41E46984971A9F95E6CFB3E7",
        FatigueFill       = "FatigueFill_12_E90E1C3846E743D359DFC29B6B932BBC",
        HealthChange      = "HealthChange_17_42D5968640F9B02C6414BDBDA2196B6B",
        HungerFill        = "HungerFill_5_0F5B3F3B46E595BD90371AA8D9C70A99",
        RadiationChange   = "RadiationChange_28_A69AB0FF4F262573EB722E82ACC010CE",
        SanityFill        = "SanityFill_15_EA5C94304AEC5881C4A2C5A262CE916A",
        TemperatureChange = "TemperatureChange_14_9C12C233407D10A07EE1828308D28927",
        ThirstFill        = "ThirstFill_11_5F6F7BB94AF9FA42F990CF96FBE5B478",
        TimeToConsume     = "TimeToConsume_32_8034526445B400D3948365AF202D7D0E",
    },
    Weapon = {   -- FAbiotic_WeaponStruct -> FAbioticWeapon
        BulletSpread_Max    = "BulletSpread_Max_39_4AE2E5744A934A3FFCEC2A9D7A1A6963",
        BulletSpread_Min    = "BulletSpread_Min_38_08ADC0BA4BEA02135BE0438A60AE5725",
        DamagePerHit        = "DamagePerHit_16_F95199D1425C37191C55CDA0DC07BDDC",
        MagazineSize        = "MagazineSize_57_E890A3944240BB8D07EF0B9251F1FBD4",
        MaximumHitscanRange = "MaximumHitscanRange_26_F36D29CA48831A6C3AD49EB94F5D2BE2",
        RequireAmmo         = "RequireAmmo_85_8BB1C1954D2A83BB1994549DDEEBA306",
        TimeBetweenShots    = "TimeBetweenShots_8_71ACC9414B36314DEF34B3A54649941C",
    },
    Equipment = {   -- FAbiotic_Equipment_Struct -> FAbioticEquipment
        CanAutoEquip = "CanAutoEquip_7_8C31C7864D1203170E1ED4B7CD8D86B7",
        EquipSlot    = "EquipSlot_5_7DAF59D54ADD37B8594D91A65C47292E",
    },
    Liquid = {   -- FAbiotic_LiquidStruct -> FAbioticLiquid
        AllowedLiquids = "AllowedLiquids_7_1DF3EB8C43F49DA3A1E4A2AF908148D3",
        MaxLiquid      = "MaxLiquid_16_80D4968B4CACEDD3D4018E87DA67E8B4",
    },
    Cookable = {   -- FAbiotic_CookableStruct -> FAbioticCookable
        FarmableDataRow = "FarmableDataRow_48_7F52477E453E35CB6673A6914103179E",
    },
    ItemDrop = {   -- FAbiotic_ItemDropStruct -> FAbioticItemDrop
        ItemDataTable = "ItemDataTable_16_C430AEEE4D16DC471206DBBAA9F6796F",
        QuantityMax   = "QuantityMax_14_6E8D8DF64637C2DD2E9DA59CBF7FAADF",
        QuantityMin   = "QuantityMin_13_08A3850648D7ADA008D57FB0855F1474",
    },
    ItemDropTable = {   -- FAbiotic_ItemDropTableStruct -> FAbioticItemDropTable
        SalvageDropItems = "SalvageDropItems_4_6F67F05F401125FAC788E4B1800CBC93",
    },
    Changeable = {   -- FAbiotic_InventoryChangeableDataStruct -> FAbioticInventoryChangeableData
        AssetID               = "AssetID_25_06DB7A12469849D19D5FC3BA6BEDEEAB",
        CurrentAmmoInMagazine = "CurrentAmmoInMagazine_12_D68C190F4B2FA78A4B1D57835B95C53D",
        CurrentItemDurability = "CurrentItemDurability_4_24B4D0E64E496B43FB8D3CA2B9D161C8",
        CurrentLiquid         = "CurrentLiquid_19_3E1652F448223AAE5F405FB510838109",
        CurrentStack          = "CurrentStack_9_D443B69044D640B0989FD8A629801A49",
        DynamicProperties     = "DynamicProperties_50_5C138DB145048726E8C0FEAC7C9600F7",
        LiquidLevel           = "LiquidLevel_46_D6414A6E49082BC020AADC89CC29E35A",
        MaxItemDurability     = "MaxItemDurability_6_F5D5F0D64D4D6050CCCDE4869785012B",
        PlayerMadeString      = "PlayerMadeString_42_CC0B72B24DBEAB2CC04454AAFFD4BBE9",
    },
    Slot = {   -- FAbiotic_InventoryItemSlotStruct -> FAbioticInventoryItemSlot
        ChangeableData = "ChangeableData_12_2B90E1F74F648135579D39A49F5A2313",
        ItemDataTable  = "ItemDataTable_18_BF1052F141F66A976F4844AB2B13062B",
    },
    ItemCount = {   -- FAbioticItemCount_Struct -> FAbioticItemCount
        Count = "Count_6_4C6C5BFB4956F9C29A5C2BB6F28B7690",
        Item  = "Item_5_5AD3D6B1470ED45BCB2D15BC84BB0F1A",
    },
    Projectile = {   -- FAbiotic_ProjectileStruct -> FAbioticProjectile
        AoE_InnerRadius                       = "AoE_InnerRadius_77_CAE50D6B46894572B2592083DE5ECD39",
        AoE_OuterRadius                       = "AoE_OuterRadius_78_9794512B4B4EE92BBB113195C7EEA50E",
        AoEMinimumDamage                      = "AoEMinimumDamage_79_A2BFD9FA4566429A21D1BBAF3BFFEAE4",
        AreaOfEffectDamage                    = "AreaOfEffectDamage_66_9D10072C4BCE8210B5D02F8890ABB3B9",
        BounceVelocityStopSimulatingThreshold = "BounceVelocityStopSimulatingThreshold_44_AF2B3ECB4F96127A287DF88A0D7E6516",
        Bounciness                            = "Bounciness_40_95964CCB495BB31BA9C459BFF46D4A8F",
        BuffDebuffToApply                     = "BuffDebuffToApply_101_C6C9E6F34E073829A7976682FC1D2FF1",
        CanDealDamage                         = "CanDealDamage_103_E75522E840C7207AC2F800937F3F5A69",
        CanHarmDeployables                    = "CanHarmDeployables_84_BD20F506477079DA789C548416DE8246",
        CollisionRadius                       = "CollisionRadius_59_13099EB848995C0ED7612B88823E6AEC",
        DamageFalloff                         = "DamageFalloff_69_2F433F7E4AD27E5079FBC8933E0FB92A",
        Friction                              = "Friction_42_0BCACACF4E4D41C853F7E4B64131FD16",
        GlintProjectile                       = "GlintProjectile_62_E1034F4246A7721AFADA54A1AE9674CE",
        HomingAccelerationMagnitude           = "HomingAccelerationMagnitude_55_06EA46E54F277BC4670EFF8862BD94D9",
        InitialSpeed                          = "InitialSpeed_21_5DC7DBA94DAE609C3AF75E89A68691A7",
        IsHomingProjectile                    = "IsHomingProjectile_54_04981F5D478DFA1F676D2E85C75EA577",
        MaxSpeed                              = "MaxSpeed_23_D2E63E7D4D56F4151FE6CBB2FE307B2E",
        NumberOfBounce                        = "NumberOfBounce_106_A132B8824AF0027427A1088511B469AB",
        ProjectileGravityScale                = "ProjectileGravityScale_31_D7158C5148CB3F07BF79CB9B61C35410",
        RotationRemainsVertical               = "RotationRemainsVertical_56_4832EC27461A4446AF35978CA0F19819",
        ShouldBounce                          = "ShouldBounce_36_61C339324EA78E560CF2FE954EB1D548",
    },
    Assault = {   -- FAssault_Struct -> FAssault
        AssaultPrepTime    = "AssaultPrepTime_58_3CA2B5904E9FE2EB428ABEAFF52C6B4E",
        AssaultStartedText = "AssaultStartedText_19_1C0D1F3247831C1BF02A73882F8399D5",
        AssaultWarningText = "AssaultWarningText_18_284D22564719BD07A425ACA3639B5BBC",
        SpawnRate_BossWave = "SpawnRate_BossWave_54_256D1A7141EFD7796B16D998642B14C9",
        SpawnRate_Wave1    = "SpawnRate_Wave1_51_A581A0FF4929204673F831B606F107BB",
        SpawnRate_Wave2    = "SpawnRate_Wave2_52_C22A1E2D460359824DC44C976D16912F",
        SpawnRate_Wave3    = "SpawnRate_Wave3_53_103CE75749AD731024F5C1BDA2F877DC",
    },
    TraderItems = {   -- FTraderItems_Struct -> FTraderItems
        BuyableItems   = "BuyableItems_7_55E09D9641EA3DC84377659B943A07D8",
        TradeableItems = "TradeableItems_9_21D1FC6140A24A248B5C828DAF0B8FD2",
    },
    TraderItemWF = {   -- FTraderItemWF_Struct -> FTraderItemWF
        AvailableStock           = "AvailableStock_13_B2DCBC5A42891AA9E4072CACD92EE4E2",
        -- What the trade hands over. Legacy: an FAbioticItemCount_Struct. Native: an FInstancedStruct
        -- (FAbioticItemCount / FTraderOutputRecipe / FTraderOutputCustomization), which UE4SS can't
        -- read into or build.
        Output                   = "Item_2_539C34D64F27057AE3A8D4B7136D2A49",
        WorldFlagToMakeAvailable = "WorldFlagToMakeAvailable_9_F1D3CCE54CCECD7869FB31B28507827E",
    },
    Customization = {   -- FAbiotic_CustomizationStruct -> FAbioticCustomization
        Material     = "Material_47_2BCAA56043478B8F8AF097B87369896A",
        SkeletalMesh = "SkeletalMesh_21_6AE38B6846F6DB34DA17F38E52D58FB3",
        StaticMesh   = "StaticMesh_20_A4A408164457F857B4E91487F73D7AC1",
    },
}

-- Item-row fields that moved to another struct, as dotted paths from the item row.
--   * Radioactivity: ConsumableData on legacy, the item row itself on native.
--   * EquipBuffs: what worn gear applies while equipped. Legacy gear read the consumable's
--     BuffsToAdd (TArray<FName>); native reads EquipmentData.BuffsWhileEquipped (row handles).
SCHEMA.ItemPath = {
    Radioactivity = SCHEMA.Native and "Radioactivity"
        or (LEGACY.Item.ConsumableData .. ".Radioactivity_43_0EF079AA43B77C98214300AD0CFB2F74"),
    EquipBuffs = SCHEMA.Native and "EquipmentData.BuffsWhileEquipped"
        or (LEGACY.Item.ConsumableData .. "." .. LEGACY.Consumable.BuffsToAdd),
}

-- The struct object each table names fields of: { legacy UserDefinedStruct, native script struct }.
-- Only /au-schema reads these.
local STRUCTS = {
    NPC           = { "/Game/Blueprints/Data/Abiotic_NPCStruct.Abiotic_NPCStruct",                                   "/Script/AbioticFactor.AbioticNPC" },
    NPCDialog     = { "/Game/Blueprints/Data/Abiotic_NPCDialogStruct.Abiotic_NPCDialogStruct",                       "/Script/AbioticFactor.AbioticNPCDialog" },
    Gib           = { "/Game/Blueprints/Data/Abiotic_Gib_Struct.Abiotic_Gib_Struct",                                 "/Script/AbioticFactor.AbioticGib" },
    SpawnEntry    = { "/Game/Blueprints/Data/Abiotic_NPCSpawnsStruct.Abiotic_NPCSpawnsStruct",                       "/Script/AbioticFactor.NPCSpawnEntry" },
    Item          = { "/Game/Blueprints/Data/Abiotic_InventoryItemStruct.Abiotic_InventoryItemStruct",               "/Script/AbioticFactor.AbioticInventoryItem" },
    Consumable    = { "/Game/Blueprints/Data/Abiotic_Consumable_Struct.Abiotic_Consumable_Struct",                   "/Script/AbioticFactor.AbioticConsumable" },
    Weapon        = { "/Game/Blueprints/Data/Abiotic_WeaponStruct.Abiotic_WeaponStruct",                             "/Script/AbioticFactor.AbioticWeapon" },
    Equipment     = { "/Game/Blueprints/Data/Abiotic_Equipment_Struct.Abiotic_Equipment_Struct",                     "/Script/AbioticFactor.AbioticEquipment" },
    Liquid        = { "/Game/Blueprints/Data/Abiotic_LiquidStruct.Abiotic_LiquidStruct",                             "/Script/AbioticFactor.AbioticLiquid" },
    Cookable      = { "/Game/Blueprints/Data/Abiotic_CookableStruct.Abiotic_CookableStruct",                         "/Script/AbioticFactor.AbioticCookable" },
    ItemDrop      = { "/Game/Blueprints/Data/Abiotic_ItemDropStruct.Abiotic_ItemDropStruct",                         "/Script/AbioticFactor.AbioticItemDrop" },
    ItemDropTable = { "/Game/Blueprints/Data/Abiotic_ItemDropTableStruct.Abiotic_ItemDropTableStruct",               "/Script/AbioticFactor.AbioticItemDropTable" },
    Changeable    = { "/Game/Blueprints/Data/Abiotic_InventoryChangeableDataStruct.Abiotic_InventoryChangeableDataStruct", "/Script/AbioticFactor.AbioticInventoryChangeableData" },
    Slot          = { "/Game/Blueprints/Data/Abiotic_InventoryItemSlotStruct.Abiotic_InventoryItemSlotStruct",       "/Script/AbioticFactor.AbioticInventoryItemSlot" },
    ItemCount     = { "/Game/Blueprints/Data/AbioticItemCount_Struct.AbioticItemCount_Struct",                       "/Script/AbioticFactor.AbioticItemCount" },
    Projectile    = { "/Game/Blueprints/Data/Abiotic_ProjectileStruct.Abiotic_ProjectileStruct",                     "/Script/AbioticFactor.AbioticProjectile" },
    Assault       = { "/Game/Blueprints/Data/Assault_Struct.Assault_Struct",                                         "/Script/AbioticFactor.Assault" },
    TraderItems   = { "/Game/Blueprints/Data/TraderItems_Struct.TraderItems_Struct",                                 "/Script/AbioticFactor.TraderItems" },
    TraderItemWF  = { "/Game/Blueprints/Data/TraderItemWF_Struct.TraderItemWF_Struct",                               "/Script/AbioticFactor.TraderItemWF" },
    Customization = { "/Game/Blueprints/Data/Abiotic_CustomizationStruct.Abiotic_CustomizationStruct",               "/Script/AbioticFactor.AbioticCustomization" },
}

local GROUPS = {}
for group in pairs(LEGACY) do GROUPS[#GROUPS + 1] = group end
table.sort(GROUPS)

for _, group in ipairs(GROUPS) do
    local names = {}
    for native, legacy in pairs(LEGACY[group]) do
        names[native] = SCHEMA.Native and native or legacy
    end
    SCHEMA[group] = setmetatable(names, { __index = function(_, key)
        error(string.format("SCHEMA.%s has no field '%s' - add it to AnteData/Schema.lua", group, tostring(key)), 2)
    end })
end

-- -----------------------------------------------------------------------
-- Asset paths that moved
-- -----------------------------------------------------------------------

SCHEMA.Path = {
    -- The abstract DamageType parent: a Blueprint on legacy, a C++ class on native.
    DamageTypeParent = SCHEMA.Native and NATIVE_CLASS
        or "/Game/Blueprints/DamageTypes/Abiotic_DamageType_ParentBP.Abiotic_DamageType_ParentBP_C",
}

-- -----------------------------------------------------------------------
-- Row handles
--   * Every handle on both builds carries RowName, so reads and in-place writes go through it.
--   * Legacy extras: FDataTableRowHandle.DataTable, FRowHandle.DataTablePath. Native has neither.
--   * Some props were a bare FName on legacy and are a handle on native: the *NameProp helpers.
-- -----------------------------------------------------------------------

local function rowString(fname)
    local s = fname and fname:ToString() or nil
    if s == nil or s == "" or s == "None" then return nil end
    return s
end

-- Row name (string) of a row handle, or nil when empty.
function SCHEMA.RowOf(handle)
    if handle == nil then return nil end
    return rowString(handle.RowName)
end

-- Row name of a prop that is an FName on legacy and a row handle on native.
function SCHEMA.RowOfNameProp(value)
    if value == nil then return nil end
    return rowString(SCHEMA.Native and value.RowName or value)
end

-- Point an existing handle at `row`, in place. `legacyTable` also sets FDataTableRowHandle.DataTable
-- on legacy (skip it when the handle already points at the right table).
function SCHEMA.SetRow(handle, row, legacyTable)
    handle.RowName = FName(row)
    if legacyTable ~= nil and not SCHEMA.Native then handle.DataTable = legacyTable end
end

-- Set `holder[key]` (a prop, or an array index) that is an FName on legacy and a handle on native.
function SCHEMA.SetNameProp(holder, key, row)
    if SCHEMA.Native then
        holder[key].RowName = FName(row)
    else
        holder[key] = FName(row)
    end
end

-- Append `row` to an array whose elements are FNames on legacy and row handles on native.
function SCHEMA.AppendNameProp(arr, row)
    local n = arr:GetArrayNum()
    if SCHEMA.Native then
        arr[n + 1] = { RowName = FName(row) }
    else
        arr[n + 1] = FName(row)
    end
end

-- Dotted path to the FName inside a field that is an FName on legacy and a row handle on native,
-- for per-member copies (a whole-struct copy is never safe, CLAUDE.md 3).
function SCHEMA.NameLeaf(path)
    if SCHEMA.Native then return path .. ".RowName" end
    return path
end

-- Set a hook's out-param that is an FName on legacy and a row handle on native, in place.
function SCHEMA.SetNameParam(param, row)
    if SCHEMA.Native then
        param:get().RowName = FName(row)
    else
        param:set(FName(row))
    end
end

-- A handle for a BY-VALUE function parameter. `legacy` holds the legacy-only fields:
-- { DataTable = <UDataTable> } or { DataTablePath = "<path>" }. Never pass the result to a
-- const-ref struct parameter (CLAUDE.md §3).
function SCHEMA.MakeHandle(row, legacy)
    local handle = { RowName = FName(row) }
    if not SCHEMA.Native and legacy then
        if legacy.DataTable ~= nil then handle.DataTable = legacy.DataTable end
        if legacy.DataTablePath ~= nil then handle.DataTablePath = FString(legacy.DataTablePath) end
    end
    return handle
end

-- A BY-VALUE parameter that is an FName on legacy and a row handle on native.
function SCHEMA.NameArg(row)
    if SCHEMA.Native then return SCHEMA.MakeHandle(row) end
    return FName(row)
end

-- -----------------------------------------------------------------------
-- Actor members that moved
-- -----------------------------------------------------------------------

-- An NPC's DT_NPCList row name as the engine spells it (not canonicalised), or nil. Legacy keeps it in
-- the FName NPCDataTableRow; native in the FNPCRowHandle NPCRow. Throws on a non-NPC: callers pcall.
function SCHEMA.NpcRowName(actor)
    if SCHEMA.Native then return rowString(actor.NPCRow.RowName) end
    return rowString(actor.NPCDataTableRow)
end

-- A spawner's live spawn entries (field names: SCHEMA.SpawnEntry). Edit them in place.
--   * Legacy: NPCsToSpawn, a per-instance array filled at construction.
--   * Native: CachedNPCSpawns, filled from the spawner's NPCSpawnTags (DT_NPCSpawns) by its own
--     BeginPlay - EMPTY until then, including inside a BeginPlay hook. Not forced here: filling it
--     reads DT_NPCSpawns, which may be cold, and a load in a hook frame deadlocks.
function SCHEMA.SpawnList(spawner)
    if SCHEMA.Native then return spawner.CachedNPCSpawns end
    return spawner.NPCsToSpawn
end

-- -----------------------------------------------------------------------
-- Checks (game thread)
-- -----------------------------------------------------------------------

local verified = false

-- Once per session, from InitMod: confirm the script-load guess with StaticFindObject and put the
-- decision in the log. A mismatch means every name this session is wrong.
function SCHEMA.Verify()
    if verified then return end
    verified = true
    local Utils = require("AnteUtils.Utils")

    local ok, cls = pcall(StaticFindObject, NATIVE_CLASS)
    local native = ok and cls ~= nil and cls:IsValid() or false
    if native == SCHEMA.Native then
        Utils.Log("Schema: " .. SCHEMA.Label .. " (game build layout; see AnNotes/AnteSystems/NativeMigration.md)")
    else
        Utils.LogBad(string.format("Schema: detection DISAGREES - script load said %s, %s says %s. "
            .. "Every struct field name this session is wrong; report this with UE4SS.log.",
            SCHEMA.Label, NATIVE_CLASS, native and "NATIVE" or "LEGACY"))
    end
end

-- /au-schema: every mapped field name against the live struct's properties. Heavy (a StaticFindObject
-- per struct), so queue it; a legacy struct is only resident once something that uses it has loaded.
function SCHEMA.Check()
    local Utils = require("AnteUtils.Utils")
    local total, missingTotal, unresolved = 0, 0, 0
    Utils.Log(string.format("Schema check - %s build layout, %d structs", SCHEMA.Label, #GROUPS))

    for _, group in ipairs(GROUPS) do
        local path = STRUCTS[group][SCHEMA.Native and 2 or 1]
        local ok, struct = pcall(StaticFindObject, path)
        if not ok or struct == nil or not struct:IsValid() then
            unresolved = unresolved + 1
            Utils.Log(string.format("  %-13s ?? %s not resident", group, path))
        else
            local have = {}
            local s = struct
            while s ~= nil and s:IsValid() do
                s:ForEachProperty(function(prop) have[prop:GetFName():ToString()] = true end)
                s = s:GetSuperStruct()
            end

            local missing, count = {}, 0
            for _, name in pairs(rawget(SCHEMA, group)) do
                count = count + 1
                if not have[name] then missing[#missing + 1] = name end
            end
            table.sort(missing)
            total, missingTotal = total + count, missingTotal + #missing
            if #missing == 0 then
                Utils.Log(string.format("  %-13s ok  %d/%d", group, count, count))
            else
                Utils.LogBad(string.format("  %-13s %d/%d MISSING: %s",
                    group, #missing, count, table.concat(missing, ", ")))
            end
        end
    end

    local okPath, parent = pcall(StaticFindObject, SCHEMA.Path.DamageTypeParent)
    local pathOk = okPath and parent ~= nil and parent:IsValid()
    Utils.Log(string.format("  %-13s %s  %s", "Path", pathOk and "ok" or "??", SCHEMA.Path.DamageTypeParent))

    local summary = string.format("Schema check - %d/%d names resolve, %d missing, %d structs not resident",
        total - missingTotal, total, missingTotal, unresolved)
    if missingTotal > 0 then Utils.LogBad(summary) else Utils.Log(summary) end

    -- Native: which DataTables the engine row registry holds for the process. A table listed here
    -- can't GC, which is the evidence ASSETS.Immortal needs to trust it again on this build.
    if SCHEMA.Native then
        pcall(function()
            local reg = FindFirstOf("ABFRowRegistrySubsystem")
            if reg == nil or not reg:IsValid() then
                Utils.Log("  Row registry: ABFRowRegistrySubsystem not found")
                return
            end
            -- IsValid before any name read: the array holds null slots, and GetFName on a null
            -- wrapper is an uncatchable AV (reads NamePrivate at 0x18).
            local names, nulls, list = {}, 0, reg.BaseTables
            for i = 1, #list do
                local t = list[i]
                if t ~= nil and t:IsValid() then
                    local ok, n = pcall(function() return t:GetFName():ToString() end)
                    names[#names + 1] = ok and n or "?"
                else
                    nulls = nulls + 1
                end
            end
            table.sort(names)
            Utils.Log(string.format("  Row registry holds %d tables (+%d null): %s",
                #names, nulls, table.concat(names, ", ")))
        end)
    end
    return total, missingTotal, unresolved
end

return SCHEMA
