
--[[
    Author: Igromanru
    Created Date: 19.08.2024
    Description: Utility functions for the game Abiotic Factor
]]

require("AFUtils.AFBase")

---@enum LiquidType
AFUtils.LiquidType = {
    None = 0,
    Water = 1,
    Unknown2 = 2,
    RadioactiveWaste = 3,
    Unknown4 = 4,
    Unknown5 = 5,
    Unknown6 = 6,
    Energy = 7,
    Unknown8 = 8,
    Antejuice = 9,
    TaintedWater = 10,
    Soup = 11,
    LaserEnergy = 12,
    Ink = 13
}

---@enum CriticalityLevels
AFUtils.CriticalityLevels = {
    Green = 0,
    Gray = 1,
    Yellow = 2,
    Red = 3,
    Purple = 4
}

-- Mapping for the CurrentInventory TArray in CharacterEquipSlotInventory (Lua based indexes aka. start with 1)
---@enum GearInventoryIndex
AFUtils.GearInventoryIndex = {
    ChestArmor = 1,
    HeadArmor = 2,
    LegArmor = 3,
    Backpack = 4,
    ArmArmor = 5,
    FullBodySuit = 6,
    Headlamp = 7,
    Trinket = 8,
    Wristwatch = 9, -- Wristwatch or Pager
    KeypadHacker = 10,
    OffHandShield = 11,
    Trinket2 = 12,
}

---@enum CharacterSkills
AFUtils.CharacterSkills = {
    None = 0,
    Sprinting = 1,
    Accuracy = 2,
    Reloading = 3,
    Sneaking = 4,
    SharpMeele = 5,
    BluntMelee = 6,
    Fishing = 7,
    Crafting = 8,
    Construction = 9,
    FirstAid = 10,
    Agriculture = 11,
    Cooking = 12,
    Unknown1 = 13,
    Fortitude = 14,
    Strength = 15,
    Throwing = 16,
    Unknown2 = 17
}

---Map of Sandbox Value FNames
---@enum SandboxValueName
AFUtils.SandboxValueName = {
    LootRespawnEnabled = "LootRespawnEnabled",
    PowerSocketsOffAtNight = "PowerSocketsOffAtNight",
    DayNightCycleState = "DayNightCycleState",
    DayNightCycleSpeedMultiplier = "DayNightCycleSpeedMultiplier",
    SinkRefillRate = "SinkRefillRate",
    FoodSpoilSpeedMultiplier = "FoodSpoilSpeedMultiplier",
    RefrigerationEffectivenessMultiplier = "RefrigerationEffectivenessMultiplier",
    EnemySpawnRate = "EnemySpawnRate",
    EnemyHealthMultiplier = "EnemyHealthMultiplier",
    EnemyPlayerDamageMultiplier = "EnemyPlayerDamageMultiplier",
    EnemyDeployableDamageMultiplier = "EnemyDeployableDamageMultiplier",
    DamageToAlliesMultiplier = "DamageToAlliesMultiplier",
    HungerSpeedMultiplier = "HungerSpeedMultiplier",
    ThirstSpeedMultiplier = "ThirstSpeedMultiplier",
    FatigueSpeedMultiplier = "FatigueSpeedMultiplier",
    ContinenceSpeedMultiplier = "ContinenceSpeedMultiplier",
    DetectionSpeedMultiplier = "DetectionSpeedMultiplier",
    PlayerXPGainMultiplier = "PlayerXPGainMultiplier",
    ItemStackSizeMultiplier = "ItemStackSizeMultiplier",
    ItemWeightMultiplier = "ItemWeightMultiplier",
    ItemDurabilityMultiplier = "ItemDurabilityMultiplier",
    DurabilityLossOnDeathMultiplier = "DurabilityLossOnDeathMultiplier",
    ShowDeathMessages = "ShowDeathMessages",
    AllowRecipeSharing = "AllowRecipeSharing",
    AllowPagers = "AllowPagers",
    AllowTransmog = "AllowTransmog",
    DisableResearchMinigame = "DisableResearchMinigame",
    DeathPenalties = "DeathPenalties",
    GlobalRecipeUnlocks = "GlobalRecipeUnlocks",
    FirstTimeStartingWeapon = "FirstTimeStartingWeapon",
    HostAccessPlayerCorpses = "HostAccessPlayerCorpses",
    StorageByTag = "StorageByTag"
}

---Map of weather events
---@enum WeatherEvents
AFUtils.WeatherEvents = {
    None = "None",
    Fog = "Fog",
    RadLeak = "RadLeak",
    Spores = "Spores",
	ColdSnap = "ColdSnap",
	Blackout = "Blackout",
	BlackFog = "BlackFog",
}

---Map of Traits. Key is trait's FName<br>
---Game v0.10.0
---@type { [string]: { Description: string, Buff: boolean } }
AFUtils.Traits = {
	Trait_Decathlon = {
		Description = "Decathlon Competitor",
		Buff = true,
	},
	Trait_FormerGuard = {
		Description = "Tough as Nails",
		Buff = true,
	},
	Trait_WrinklyBrainmeat = {
		Description = "Wrinkly Brainmeat",
		Buff = true,
	},
	Trait_NightOwl = {
		Description = "Night Owl",
		Buff = true,
	},
	Trait_Chef = {
		Description = "Hobbyist Chef",
		Buff = true,
	},
	Trait_Inconspicuous = {
		Description = "Inconspicuous",
		Buff = true,
	},
	Trait_Outdoorsman = {
		Description = "Weathered",
		Buff = true,
	},
	Trait_FannyPack = {
		Description = "Fanny Pack",
		Buff = true,
	},
	Trait_ThickSkinned = {
		Description = "Thick Skinned",
		Buff = true,
	},
	Trait_FirstAidCert = {
		Description = "First Aid Certification",
		Buff = true,
	},
	Trait_Gardener = {
		Description = "Gardener",
		Buff = true,
	},
	Trait_LightEater = {
		Description = "Light Eater",
		Buff = true,
	},
	Trait_Moist = {
		Description = "Naturally Moist",
		Buff = true,
	},
	Trait_SelfDefense = {
		Description = "Self Defense",
		Buff = true,
	},
	Trait_SteelBladder = {
		Description = "Bladder of Steel",
		Buff = true,
	},
	Trait_Strong = {
		Description = "Buff Brainiac",
		Buff = true,
	},
	Trait_LeadBelly = {
		Description = "Lead Belly",
		Buff = true,
	},
	Trait_FearOfViolence = {
		Description = "Fear of Violence",
		Buff = false,
	},
	Trait_EasilyStartled = {
		Description = "Easily Startled",
		Buff = false,
	},
	Trait_Feeble = {
		Description = "Feeble",
		Buff = false,
	},
	Trait_Narcoleptic = {
		Description = "Narcoleptic",
		Buff = false,
	},
	Trait_Agoraphobic = {
		Description = "Agoraphobic",
		Buff = false,
	},
	Trait_Fumbler = {
		Description = "Fumbler",
		Buff = false,
	},
	Trait_Asthmatic = {
		Description = "Asthmatic",
		Buff = false,
	},
	Trait_Claustrophobic = {
		Description = "Claustrophobic",
		Buff = false,
	},
	Trait_Clumsy = {
		Description = "Clumsy",
		Buff = false,
	},
	Trait_Conspicuous = {
		Description = "Painfully Obvious",
		Buff = false,
	},
	Trait_HeartyAppetite = {
		Description = "Hearty Appetite",
		Buff = false,
	},
	Trait_Dry = {
		Description = "Dry Skin",
		Buff = false,
	},
	Trait_Hemophobic = {
		Description = "Hemophobic",
		Buff = false,
	},
	Trait_Dyslexia = {
		Description = "Dyslexia",
		Buff = false,
	},
	Trait_RestlessSleeper = {
		Description = "Restless Sleeper",
		Buff = false,
	},
	Trait_Smoker = {
		Description = "Smoker",
		Buff = false,
	},
	Trait_SlowHealer = {
		Description = "Slow Healer",
		Buff = false,
	},
	Trait_SlowLearner = {
		Description = "Slow Learner",
		Buff = false,
	},
	Trait_Hemophilia = {
		Description = "Hemophilia",
		Buff = false,
	},
	Trait_Unlucky = {
		Description = "Unlucky",
		Buff = false,
	},
	Trait_WeakBladder = {
		Description = "Weak Bladder",
		Buff = false,
	},
	Trait_Cannibal = {
		Description = "Forbidden Diet",
		Buff = false,
	},
}

---Valid OutlineMask values for UOutlineComponent_C
---@enum OutlineMask
AFUtils.OutlineMask = {
	None = 0,
	Object = 1, -- Cyan
	White = 2, -- White / Grey
	-- Cyan2 = 3, -- Cyan
	-- White2 = 4,
	-- Cyan3 = 5,
	-- White3 = 6,
	-- Cyan4 = 7,
	Enemy = 8 -- Red
}

---@enum Factions
AFUtils.Factions = {
	None = 0,
	NewEnumerator5 = 1,
	Player = 2,
	Soldier = 3,
	NewEnumerator4 = 4,
	Creature = 5,
	NewEnumerator7 = 6,
	NewEnumerator8 = 7,
	NewEnumerator9 = 8,
	NewEnumerator10 = 9,
	NewEnumerator11 = 10,
	NewEnumerator12 = 11,
	NewEnumerator13 = 12,
	NewEnumerator14 = 13,
	NewEnumerator16 = 14
};

---@enum FoodCookStates
AFUtils.FoodCookStates = {
    Cooking = 0,
    Cooked = 1,
    CarefullyCooked = 2,
    WellCooked = 3,
    BeautifullyCooked = 4,
    NewEnumerator7 = 5,
    Burnt = 6,
    Ignited = 7
}


-- K2_AttachToComponent(.., locationRule, rotationRule, scaleRule)
-- enum class EAttachmentRule {
--     KeepRelative = 0,
--     KeepWorld = 1,
--     SnapToTarget = 2,
--     EAttachmentRule_MAX = 3,
-- };




return AFUtils