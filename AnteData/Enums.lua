local AnteEnums = {}
local SCHEMA = require("AnteData.Schema")

-- =======================================================================
-- TUNING - cross-variant magic numbers. A value belongs here once more than one variant needs it
-- and it means the same thing everywhere.
--   * static, never-changes-at-runtime data -> AnteData (this file)
--   * MUTABLE runtime state -> AnteCore/State
--   * a knob only ONE variant uses stays a local in that variant's file (AnteNPCs convention);
--     promote it here only when a second caller wants it
-- =======================================================================

AnteEnums.Tuning = {
    -- When moving players, offset to keep them from clipping in the ground
    PLAYER_ZLIFT = 20,

    -- Quasi-disable an ability with a cooldown
    CD_DISABLED = 3600,

    -- World gravity Z (cm/s^2), UE default. AVMath's ballistics read this
    WORLD_GRAVITY_Z = -980,
}


-- =======================================================================
-- NPCs
-- =======================================================================

AnteEnums.BASE_PARENT_NPC = "/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C"
-- Its class default: the donor for every soft-ref blank (Utils.BlankSoftRef).
AnteEnums.BASE_PARENT_NPC_CDO = "/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.Default__NPC_Base_ParentBP_C"

-- DT_NPCList - short names for actor.NPCData fields, spelled for the running game build (SCHEMA.NPC)
--   * ex: npcData[ENUMS.NpcData.WalkSpeed] = 400
--   * HP_* limb fields only take effect AFTER actor:InitalizeHealthValues (see AVU.SetLimbHealth)
local NPC = SCHEMA.NPC
AnteEnums.NpcData = {
    WalkSpeed        = NPC.DefaultWalkSpeed,
    SprintSpeed      = NPC.DefaultSprintSpeed,

    -- Out-of-combat / in-combat door handling (BT_CheckObstruction's door branch).
    CanOpenDoors     = NPC.CanOpenDoors,
    CanBashOpenDoors = NPC.CanBashOpenDoors,

    MeleeDamage      = NPC.MeleeAttackDamagePerHit,
    MeleeDamageType  = NPC.DamageType_Melee,
    MeleeAttackRange = NPC.RangeToMeleeAttack,

    RangedDamage     = NPC.RangedAttackDamagePerHit,
    RangedDamageType = NPC.DamageType_Ranged,
    RangedAttackRange = NPC.RangeToRangedAttack,
    RangedAttackCooldown = NPC.RangedAttackCooldown,
    HasRangedAttack  = NPC.HasRangedAttack,

    HpHead           = NPC.HP_Head,
    HpTorso          = NPC.HP_Torso,
    HpLeftArm        = NPC.HP_LeftArm,
    HpRightArm       = NPC.HP_RightArm,
    HpLeftLeg        = NPC.HP_LeftLeg,
    HpRightLeg       = NPC.HP_RightLeg,

    DisplayName      = NPC.DisplayName,
    HitXpMultiplier  = NPC.NPC_Hit_XP_Multiplier,

    DefaultFaction   = NPC.DefaultFaction,

    VoiceLines       = NPC.VoiceLines,

    -- Row handles on the NPC's row: blanked to strip kill credit (AVU.BlankKillCredit).
    CompendiumKill   = NPC.CompendiumKill,
    AchievementStat  = NPC.AchievementStat,

    -- FAbioticGib: NPCData[GibInfo][ENUMS.NpcGib.X]
    GibInfo          = NPC.GibInfo,
}

-- Fields of NPCData[ENUMS.NpcData.VoiceLines] - one soft-object array per line type
AnteEnums.NpcVoiceLines = {
    NormalDeath      = SCHEMA.NPCDialog.NormalDeathSounds,
    ScreamingDeath   = SCHEMA.NPCDialog.ScreamingDeathSounds,
}

-- Fields of NPCData[ENUMS.NpcData.GibInfo]
AnteEnums.NpcGib = {
    CanBeGibbed      = SCHEMA.Gib.CanBeGibbed,
    GibSalvage       = SCHEMA.Gib.GibSalvage,
}

-- Keys for NPC actor classes. Using the same row names as DT_NPCList 
--   * DisplayName differs, so "Pest_Carbonated", not "Carbonated Pest"
AnteEnums.NpcClasses = {

    -- ==============================================================================
    -- Anteverse 2 - Pests
    ["Pest"]               = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Pest.NPC_Monster_Pest_C",
    ["Pest_Electro"]       = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Pest_Electro.NPC_Monster_Pest_Electro_C",
    ["Pest_Volatile"]      = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Pest_Volatile.NPC_Monster_Pest_Volatile_C",
    ["Pest_Snow"]          = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Pest_Snow.NPC_Monster_Pest_Snow_C",
    ["Pest_Electro_Shield"]= "/Game/Blueprints/Characters/NPCs/NPC_Monster_ShieldPest.NPC_Monster_ShieldPest_C",
    ["Pest_Carbonated"]    = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Pest_Carbonated.NPC_Monster_Pest_Carbonated_C",
    ["Pest_Enlightened"]   = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Pest_Enlightened.NPC_Monster_Pest_Enlightened_C",
    ["Pest_Leyak"]         = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Pest_Leyak.NPC_Monster_Pest_Leyak_C",
    ["Pest_Magma"]         = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Pest_Magma.NPC_Monster_Pest_Magma_C",
    ["Pest_Rat"]           = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Pest_Rat.NPC_Monster_Pest_Rat_C",

    ["Peccary"]            = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Peccary.NPC_Monster_Peccary_C",
    ["Sow"]                = "/Game/Blueprints/Characters/NPCs/NPC_Peccary_Sow.NPC_Peccary_Sow_C",
    ["Peccary_Alpha"]      = "/Game/Blueprints/Characters/NPCs/NPC_Peccary_Alpha.NPC_Peccary_Alpha_C",
    ["Peccary_Mushroom"]   = "/Game/Blueprints/Characters/NPCs/NPC_Peccary_Mushroom.NPC_Peccary_Mushroom_C",
    ["Peccary_Snow"]       = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Peccary_Snow.NPC_Monster_Peccary_Snow_C",
    ["Peccary_Armored"]    = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Peccary_Armored.NPC_Monster_Peccary_Armored_C",
    ["Peccary_Electro"]    = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Peccary_Electro.NPC_Monster_Peccary_Electro_C",
    ["Peccary_Volatile"]   = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Peccary_Volatile.NPC_Monster_Peccary_Volatile_C",

    ["Exor_Monk"]          = "/Game/Blueprints/Characters/NPCs/NPC_Exor_Monk.NPC_Exor_Monk_C",
    ["Exor"]               = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Exor.NPC_Monster_Exor_C",
    ["Exor_Armored"]       = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Exor_Armored.NPC_Monster_Exor_Armored_C",
    ["Exor_Pikeman"]       = "/Game/Blueprints/Characters/NPCs/NPC_Exor_Pikeman.NPC_Exor_Pikeman_C",
    ["Exor_Pikeman_Ally"]  = "/Game/Blueprints/Characters/NPCs/NPC_Exor_Ally.NPC_Exor_Ally_C",
    ["Exor_Volatile"]      = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Exor_Volatile.NPC_Monster_Exor_Volatile_C",

    ["Carbuncle"]          = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Carbuncle.NPC_Monster_Carbuncle_C",
    ["Carbuncle_Tainted"]  = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Carbuncle_Tainted.NPC_Monster_Carbuncle_Tainted_C",
    ["Carbuncle_Mushroom"] = "/Game/Blueprints/Characters/NPCs/NPC_Carbuncle_Mushroom.NPC_Carbuncle_Mushroom_C",
    ["Carbuncle_Volatile"] = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Carbuncle_Volatile.NPC_Monster_Carbuncle_Volatile_C",

    -- ==============================================================================
    -- Anteverse 1 - Composers / Symphonists
    ["Composer"]           = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Composer.NPC_Monster_Composer_C",
    ["Symph"]              = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Symphonist.NPC_Monster_Symphonist_C",
    ["Mirage"]             = "/Game/Blueprints/Environment/Mirage/BP_Mirage_Symphonist.BP_Mirage_Symphonist_C",

    -- ==============================================================================
    -- The Order
    -- Night visitor (AI-director gated normally; direct spawn works - self-contained actor)
    ["Coworker"]           = "/Game/Blueprints/Characters/NPCs/NPC_Coworker.NPC_Coworker_C",

    ["Grunt_Guard"]        = "/Game/Blueprints/Characters/NPCs/NPC_Grunt_Guard.NPC_Grunt_Guard_C",
    ["Grunt"]              = "/Game/Blueprints/Characters/NPCs/NPC_Soldier_Grunt.NPC_Soldier_Grunt_C",
    ["Grunt_Captain"]      = "/Game/Blueprints/Characters/NPCs/NPC_Soldier_Captain.NPC_Soldier_Captain_C",
    ["Grunt_Medic"]        = "/Game/Blueprints/Characters/NPCs/NPC_Soldier_Grunt_Medic.NPC_Soldier_Grunt_Medic_C",
    ["Grunt_Shotgun"]      = "/Game/Blueprints/Characters/NPCs/NPC_Soldier_Grunt_Shotgun.NPC_Soldier_Grunt_Shotgun_C",
    ["Grunt_Sniper"]       = "/Game/Blueprints/Characters/NPCs/NPC_Soldier_Grunt_Sniper.NPC_Soldier_Grunt_Sniper_C",
    ["Grunt_Guard_Offduty"]= "/Game/Blueprints/Characters/NPCs/NPC_Grunt_Guard_OffDuty.NPC_Grunt_Guard_OffDuty_C",
    ["Grunt_LabRat"]       = "/Game/Blueprints/Characters/NPCs/NPC_LabRat.NPC_LabRat_C",
    ["Grunt_LabRat_Mechanic"]= "/Game/Blueprints/Characters/NPCs/NPC_LabRat_Garage.NPC_LabRat_Garage_C",
    ["Grunt_Sapper"]       = "/Game/Blueprints/Characters/NPCs/NPC_Sapper.NPC_Sapper_C",
    ["Grunt_FlameRat"]     = "/Game/Blueprints/Characters/NPCs/NPC_FlameRat.NPC_FlameRat_C",

    ["Groupe_Grunt"]       = "/Game/Blueprints/Characters/NPCs/NPCGroupe_Mountaineer.NPCGroupe_Mountaineer_C",
    ["Groupe_Rook"]        = "/Game/Blueprints/Characters/NPCs/NPC_Groupe_Shield.NPC_Groupe_Shield_C",
    ["Groupe_Shotgun"]     = "/Game/Blueprints/Characters/NPCs/NPC_Groupe_Shotgunner.NPC_Groupe_Shotgunner_C",

    ["Trooper"]            = "/Game/Blueprints/Characters/NPCs/NPC_OrderGrunt_Trooper.NPC_OrderGrunt_Trooper_C",
    ["Trooper_Shield"]     = "/Game/Blueprints/Characters/NPCs/NPC_OrderGrunt_Shield.NPC_OrderGrunt_Shield_C",
    ["Trooper_Shotgun"]    = "/Game/Blueprints/Characters/NPCs/NPC_OrderGrunt_ShotTrooper.NPC_OrderGrunt_ShotTrooper_C",
    ["Interfector"]        = "/Game/Blueprints/Characters/NPCs/NPC_Interfector.NPC_Interfector_C",
    ["Clericus"]           = "/Game/Blueprints/Characters/NPCs/NPC_Clericus.NPC_Clericus_C",

    -- ==============================================================================
    -- Gate Robots
    ["Robot_Security"]     = "/Game/Blueprints/Characters/NPCs/NPC_Robot_Security.NPC_Robot_Security_C",
    ["Robot_Containment"]  = "/Game/Blueprints/Characters/NPCs/NPC_Robot_Containment.NPC_Robot_Containment_C",
    ["Robot_Defense"]      = "/Game/Blueprints/Characters/NPCs/NPC_Robot_Defense.NPC_Robot_Defense_C",
    ["Robot_Corrupt"]      = "/Game/Blueprints/Characters/NPCs/NPC_Robot_Corrupt.NPC_Robot_Corrupt_C",

    -- ==============================================================================
    -- GateKeepers
    ["Gatekeeper_Phyter"]  = "/Game/Blueprints/Characters/NPCs/NPC_Gatekeeper_Grunt.NPC_Gatekeeper_Grunt_C",
    ["Gatekeeper_Mage"]    = "/Game/Blueprints/Characters/NPCs/NPC_Mage.NPC_Mage_C",
    -- The Mage's eye drone. Natively spawned BY the Mage (NPC_Mage.SpawnMageEye), but it is a
    -- normal NPC and stands alone: its laser gate (CanFireLaser) reads "OwningMage invalid OR
    -- dead", so a mage-less eye is simply always-enraged. See AnteNPCs/GK_Mage.lua.
    ["Gatekeeper_MageEye"] = "/Game/Blueprints/Characters/NPCs/NPC_MageEye.NPC_MageEye_C",
    ["Gatekeeper_Heavy"]   = "/Game/Blueprints/Characters/NPCs/NPC_Gatekeeper_Heavy.NPC_Gatekeeper_Heavy_C",
    ["Gatekeeper_Chieftain"]= "/Game/Blueprints/Characters/NPCs/NPC_Gatekeeper_Chieftain.NPC_Gatekeeper_Chieftain_C",
    ["Gatekeeper_Witch"]   = "/Game/Blueprints/Characters/NPCs/NPC_Gatekeeper_Witch.NPC_Gatekeeper_Witch_C",

    ["DarkLens_Chieftain"] = "/Game/Blueprints/Characters/NPCs/NPC_Gatekeeper_Chieftain_DarkLens.NPC_Gatekeeper_Chieftain_DarkLens_C",
    ["DarkLens_Heavy"]     = "/Game/Blueprints/Characters/NPCs/NPC_Gatekeeper_Heavy_DarkLens.NPC_Gatekeeper_Heavy_DarkLens_C",
    ["DarkLens_Witch"]     = "/Game/Blueprints/Characters/NPCs/NPC_Gatekeeper_Witch_DarkLens.NPC_Gatekeeper_Witch_DarkLens_C",
    ["DarkLens_Mage"]      = "/Game/Blueprints/Characters/NPCs/NPC_Mage_DarkLens.NPC_Mage_DarkLens_C",

    -- ==============================================================================
    -- Anteverse 168 - Canaan (Pillagers)
    ["Pillager_Farmer"]    = "/Game/Blueprints/Characters/NPCs/NPC_Pillager_Farmer.NPC_Pillager_Farmer_C",
    ["Pillager_Woodsman"]  = "/Game/Blueprints/Characters/NPCs/NPC_Pillager_Woodsman.NPC_Pillager_Woodsman_C",
    ["Pillager_Musketeer_GUARD"]= "/Game/Blueprints/Characters/NPCs/NPC_Pillager_Musketeer_Guard.NPC_Pillager_Musketeer_Guard_C",
    ["Pillager_Torchbearer"]= "/Game/Blueprints/Characters/NPCs/NPC_Pillager_Torchbearer.NPC_Pillager_Torchbearer_C",
    ["Pillager_Preacher"]  = "/Game/Blueprints/Characters/NPCs/NPC_Pillager_Preacher.NPC_Pillager_Preacher_C",
    ["Pillager_Musketeer"] = "/Game/Blueprints/Characters/NPCs/NPC_Pillager_Musketeer.NPC_Pillager_Musketeer_C",
    ["Pillager_Preacher_Niketas"]= "/Game/Blueprints/Characters/NPCs/NPC_Pillager_Preacher_NiketasBOSS.NPC_Pillager_Preacher_NiketasBOSS_C",

    -- ==============================================================================
    -- Anteverse 21 - Skinks
    ["Skink"]              = "/Game/Blueprints/Characters/NPCs/NPC_Skink_Basic.NPC_Skink_Basic_C",
    ["Skink_Crafted"]      = "/Game/Blueprints/Characters/NPCs/NPC_Skink_Crafted.NPC_Skink_Crafted_C",
    ["Skink_Magma"]        = "/Game/Blueprints/Characters/NPCs/NPC_Skink_Magma.NPC_Skink_Magma_C",
    ["Skink_Magma_Crafted"]= "/Game/Blueprints/Characters/NPCs/NPC_Skink_Magma_Crafted.NPC_Skink_Crafted_Magma_C",
    ["Skink_Mushroom"]        = "/Game/Blueprints/Characters/NPCs/NPC_Skink_Mushroom.NPC_Skink_Mushroom_C",
    ["Skink_Mushroom_Crafted"]= "/Game/Blueprints/Characters/NPCs/NPC_Skink_Mushroom_Crafted.NPC_Skink_Mushroom_Crafted_C",

    -- ==============================================================================
    -- Anteverse 23 - Zombies / Power Leeches / Assassin
    ["Zombie"]             = "/Game/Blueprints/Characters/NPCs/NPC_Zombie.NPC_Zombie_C",
    ["Zombie_Dam"]         = "/Game/Blueprints/Characters/NPCs/NPC_Zombie_DamWorker.NPC_Zombie_DamWorker_C",
    ["Zombie_Sci"]         = "/Game/Blueprints/Characters/NPCs/NPC_Zombie_Scientist.NPC_Zombie_Scientist_C",
    ["PowerLeech"]         = "/Game/Blueprints/Characters/NPCs/NPC_PowerLeech.NPC_PowerLeech_C",
    ["PowerLeech_BOSS"]    = "/Game/Blueprints/Characters/NPCs/NPC_PowerLeechBoss.NPC_PowerLeechBoss_C",
    ["Assassin"]           = "/Game/Blueprints/Characters/NPCs/NPC_Assassin.NPC_Assassin_C",

    -- ==============================================================================
    -- Anteverse 33 - Flesh Dimension
    ["BogMan"]             = "/Game/Blueprints/Characters/NPCs/NPC_Monster_BogMan.NPC_Monster_BogMan_C",
    ["Leyak"]              = "/Game/Blueprints/Characters/NPCs/NPC_Leyak.NPC_Leyak_C",
    ["Krasue"]             = "/Game/Blueprints/Characters/NPCs/NPC_Krasue.NPC_Krasue_C",

    -- ==============================================================================
    -- Anteverse 39 - Night Realm
    ["Reaper"]             = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Reaper.NPC_Monster_Reaper_C",
    ["ReaperScout"]        = "/Game/Blueprints/Characters/NPCs/NPC_Monster_ReaperScout.NPC_Monster_ReaperScout_C",

    -- ==============================================================================
    -- Anteverse 42 - Macroscopic Dimension (Giants)
    ["Tarasque"]           = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Tarasque.NPC_Monster_Tarasque_C",
    ["Behemoth"]           = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Behemoth.NPC_Monster_Behemoth_C",

    -- ==============================================================================
    -- South Island - the final boss (ModuleShadow; AnNotes/Modules/ShadowBoss.md)
    ["Boss_Shadow"]        = "/Game/Blueprints/Characters/NPCs/NPC_Boss_Shadow.NPC_Boss_Shadow_C",
    ["Boss_Tentacle"]      = "/Game/Blueprints/Characters/NPCs/NPC_Boss_Tentacle.NPC_Boss_Tentacle_C",

    -- ==============================================================================
    -- Anteverse 188 - North Pole
    ["Snowman"]            = "/Game/Blueprints/Characters/NPCs/NPC_Snowman.NPC_Snowman_C",
    ["Yeti"]               = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Yeti.NPC_Monster_Yeti_C",
    ["Bigfoot"]            = "/Game/Blueprints/Characters/NPCs/NPC_Bigfoot.NPC_Bigfoot_C",

    -- ==============================================================================
    -- Space Queen - Winter Sprites
    ["WinterSprite"]       = "/Game/Blueprints/Characters/NPCs/NPC_Monster_WinterSprite.NPC_Monster_WinterSprite_C",
    ["WinterSprite_Bomb"]  = "/Game/Blueprints/Characters/NPCs/NPC_Monster_WinterSprite_Bomb.NPC_Monster_WinterSprite_Bomb_C",
    ["WinterSprite_BOSS"]  = "/Game/Blueprints/Characters/NPCs/NPC_Monster_WinterSprite_BOSS.NPC_Monster_WinterSprite_BOSS_C",
    -- The two pet only evolutions (Sir Ogi / Speedogi)
    ["Lamogi_Plated"]      = "/Game/Blueprints/Characters/NPCs/NPC_Monster_LamogiPlated.NPC_Monster_LamogiPlated_C",
    ["Lamogi_Speedy"]      = "/Game/Blueprints/Characters/NPCs/NPC_Monster_LamogiSpeedy.NPC_Monster_LamogiSpeedy_C",
    
}

-- NPC groupings for mod compatibility - if another mod modifies humanoids, we can turn ORDER and GK variants off
AnteEnums.NpcGroupings = {
    ORDER = {
        ["Grunt_Guard"] = true,
        ["Grunt"] = true,
        ["Grunt_Captain"] = true,
        ["Grunt_Medic"] = true,
        ["Grunt_Shotgun"] = true,
        ["Grunt_Sniper"] = true,
        ["Grunt_Sapper"] = true,
        ["Grunt_LabRat"] = true,
        ["Grunt_LabRat_Mechanic"] = true,
        ["Grunt_FlameRat"] = true,

        ["Groupe_Grunt"] = true,
        ["Groupe_Rook"] = true,
        ["Groupe_Shotgun"] = true,

        ["Grunt_Guard_Offduty"] = true,
        ["Trooper"] = true,
        ["Trooper_Shield"] = true,
        ["Trooper_Shotgun"] = true,
        ["Interfector"] = true,
    },
    GATEKEEPERS = {
        ["Robot_Corrupt"] = true,
        ["Gatekeeper_Phyter"] = true,
        ["Gatekeeper_Mage"] = true,
        ["Gatekeeper_MageEye"] = true,
        ["Gatekeeper_Heavy"] = true,
        ["Gatekeeper_Chieftain"] = true,
        ["Gatekeeper_Witch"] = true,
        ["DarkLens_Chieftain"] = true,
        ["DarkLens_Heavy"] = true,
        ["DarkLens_Witch"] = true,
        ["DarkLens_Mage"] = true,
    },
}


-- =======================================================================
-- COMPONENTS
-- =======================================================================


-- Meshes, materials, textures, and spawnable BP actor classes (AreaEffects).
-- *** NO NIAGARA SYSTEMS HERE - those all live in AnteEnums.Effects. *** The two tables used to
-- both carry Niagara, and the cost of that was silent: the ClientFX registry read
-- `AnteEnums.Effects.SNIPER_TRACER` while the path sat in THIS table, so it resolved to nil and
-- the Fallow Patriarch's sniper telegraph drew nothing at all (fixed 2026-08-12).
AnteEnums.Components = {


    -- ARMOR / ATTACHMENTS to Antevariant NPCs
    SM_CHEFSHAT = "/Game/Models/Characters/Armor/SM_ChefHat_02.SM_ChefHat_02",
    SM_COWBOYHAT = "/Game/Models/Characters/Armor/SM_Hat_CowboyHat.SM_Hat_CowboyHat",
    SM_SECURITYCAP = "/Game/Models/Characters/Armor/SM_Armor_Security_Hat.SM_Armor_Security_Hat",
    SM_APRON = "/Game/Models/Characters/Armor/SM_CookingApron_01.SM_CookingApron_01",

    SM_ARMOR_CHEST_HEX = "/Game/Models/Characters/Armor/SM_Armor_Chest_Hex.SM_Armor_Chest_Hex",
    SM_PECCARY_HELM_MUSH = "/Game/Models/Characters/Armor/SM_Peccary_Helmet_mush.SM_Peccary_Helmet_mush",
    SM_ARMOR_HELMET_CRYSTAL = "/Game/Models/Characters/Armor/SM_Armor_Helmet_Crystal.SM_Armor_Helmet_Crystal",
    -- The wearable witch hat (armor item mesh). Worn OVER the GK Witch's own hat to bulk out the
    -- boss silhouette - the Mother of the Fallow.
    SM_WITCH_HAT = "/Game/Models/Characters/Armor/SM_WitchHat.SM_WitchHat",
    SM_QUILL = "/Game/Models/Characters/NPCs/Exor/SM_Projectile_Exor_Quill.SM_Projectile_Exor_Quill",
    -- The Exor's own back-quill cluster, as worn by the body at 100% quill state. A fan of spikes
    -- around an INVISIBLE column, so on an arm bone it reads as a spiked armband rather than a prop.
    SM_EXOR_QUILLSTATE = "/Game/Models/Characters/NPCs/Exor/SM_ExorQuillState_100.SM_ExorQuillState_100",
    -- Exor_Armored's plating: its own SkeletalMesh the game merges onto the body, not a texture.
    -- Shares SK_Monster_Exor_Skeleton, so it leader-poses onto any Exor-family body (Monk too).
    -- One slot, ArmorPurp = M_Exor_Armor_02 (character master: tint with Color).
    SK_EXOR_ARMOR = "/Game/Models/Characters/NPCs/Exor/SK_Monster_Exor_Armor.SK_Monster_Exor_Armor",
    -- The throwable snowball. Used as a PROJECTILE body (PROJ.Queue's meshClass -> SM_Appearance)
    -- to give the Snowman's meshless frost shell something visible to arc through the air.
    SM_SNOWBALL = "/Game/Models/Weapons/Ranged/Snowball/SM_Throwable_Snowball.SM_Throwable_Snowball",
    -- The Throwing Shard ITEM's world mesh (ItemTable_Global "throwing_shard" -> WorldStaticMesh;
    -- shared with the tech dart). PROJ.Queue meshClass for the Winterfector's shard throw - the
    -- ice-shard PROJECTILE class has NO mesh of its own (glint Niagara only; snow rule: check
    -- a borrowed projectile HAS a mesh). The Item opt carries the replicated body for clients.
    SM_THROWING_DART_TECH = "/Game/Models/Weapons/Ranged/ThrowingDartTech/SM_ThrowingDart_Tech.SM_ThrowingDart_Tech",
    -- Translucent icy material (Particles/Materials; known-resident from the winter work).
    -- Winterfector dagger swap: M_Dagger_Interfector parents M_AbioticItems_Master. That master
    -- declares NO "Color"/"Tint"/"AccentColor" param - which is what the "it ignores every tint
    -- param" lesson actually was - but it DOES have DiffuseColor (base-colour multiply, >1 legal)
    -- and EmissiveColor/EmissiveIntensity. Wash one of these meshes with opts.DiffuseColor; swap
    -- the material only when you need a different SHADING model (translucency, like the icicle).
    M_ICICLE = "/Game/Particles/Materials/M_Icicle.M_Icicle",
    -- Flat white. The items master's glow is EmissiveColor x EmissiveIntensity x EmissiveMultiplier
    -- MASKED BY EmissiveTexture, and a material that never meant to glow leaves that texture unset -
    -- so the three scalars alone light nothing. Drop this in the EmissiveTexture param to make the
    -- whole mesh emit evenly, then colour it with EmissiveColor.
    T_WHITE_GENERIC = "/Game/Models/Environment/Walls/T_ABF_WhiteGeneric.T_ABF_WhiteGeneric",
    -- Parents M_AbioticItems_Master -> tint it with opts.DiffuseColor, not opts.Color.
    SM_EXOR_SKULL = "/Game/Models/Characters/NPCs/ExorPikeman/SM_Exor_Pikeman_Skull.SM_Exor_Pikeman_Skull",
    -- The Pikeman's ALTERNATE body albedo, usable as a reskin on the Exor MONK body: both meshes
    -- carry one M_AbioticCharacter_Master instance on a slot named M_Exor_Monk01, so the Pikeman
    -- was unwrapped against the Monk's UVs and its atlas lands square. Goes in the "Texture" param
    -- of body slot 0; the Monk's slot 1 (Monkstuff) is separate cloth and keeps T_Monk_Vanity.
    T_EXOR_PIKEMAN_02 = "/Game/Models/Characters/NPCs/ExorPikeman/T_Exor_Pikeman_02.T_Exor_Pikeman_02",
    -- SM_SPROUTS_COMPLEX = "/Game/Models/Environment/AnteverseB/SM_Sprouts_COMPLEX.SM_Sprouts_COMPLEX",  -- [unused]
    -- SM_HELM_MAESTRO = "/Game/Models/Characters/Armor/SM_Armor_Helmet_Maestro.SM_Armor_Helmet_Maestro",  -- [unused]
    SM_HELM_MAKESHIFT_NVGS = "/Game/Models/Characters/Armor/SM_Armor_Makeshift_NVGs.SM_Armor_Makeshift_NVGs",
    SM_HELM_PREACHER = "/Game/Models/Characters/Armor/SM_Armor_Helmet_Preacher.SM_Armor_Helmet_Preacher",
    
    -- The Order banner pole (base pivot, ~5.4m tall, slot 0 = cloth, slot 1 = pole). Default GK banner
    SM_BANNER_POLE = "/Game/Models/Items/Misc/SM_Banner_Pole.SM_Banner_Pole",
    -- The pole-FREE hanging banner cloth (~60cm x 1.75m, TOP pivot - it drapes DOWNWARD). ONE slot
    -- (M_BannerFabric), and like the pole its default cloth is the GATEKEEPER banner - always
    -- override slot 0 with M_BANNER_ORDER. The Embolon's shield drape.
    SM_BANNER_HANGING = "/Game/Models/Items/Misc/SM_Banner_Hanging.SM_Banner_Hanging",
    M_BANNER_ORDER = "/Game/Models/Items/Misc/M_Banner_Order.M_Banner_Order",
    -- Shipped goggle/visor MIs of M_Glass_Lens_Master (more siblings: _Dark/_Dark_Green/_TintBlack/
    -- _HighInq/_Mountaineer). Feed one to AVU.SetHelmet's LensMaterial to swap a helmet's glass slot
    -- outright - guaranteed-correct art vs guessing Color1/Color2. Preload it in def.Assets.
    M_GLASS_LENS_RED    = "/Game/Textures/Glass/M_Glass_Lens_Red.M_Glass_Lens_Red",
    M_GLASS_LENS_GOLD   = "/Game/Textures/Glass/M_Glass_Lens_Gold.M_Glass_Lens_Gold",
    M_GLASS_LENS_PURPLE = "/Game/Textures/Glass/M_Glass_Lens_Purple.M_Glass_Lens_Purple",
    M_GLASS_LENS_BLACKTINT = "/Game/Textures/Glass/M_Glass_Lens_TintBlack.M_Glass_Lens_M_Glass_Lens_TintBlack",
    -- The sniper rifle's U1 upgrade skin, SKELETAL - so it drops straight onto the soldier `Gun`
    -- component via AVU.SwapSkeletalMesh. A weapon body can't be TINTED (M_AbioticItems_Master
    -- albedo isn't a param), so a mesh swap is the lever; base is SK_SniperRifle.
    SK_SNIPER_RIFLE_U1 = "/Game/Models/Weapons/Ranged/SniperRifle/SK_Sniper_Rifle_U1.SK_Sniper_Rifle_U1",
    SM_GLOWSTICK = "/Game/Models/Items/Tools/SM_GlowStick_01.SM_GlowStick_01",
    -- The one-handed sword's WORLD mesh (its item row's WorldStaticMesh, per ItemTable_Global).
    -- Hung on an NPC's hand bone - NPC_Base_ParentBP names those itself: `Left Hand` = "l_hand",
    -- `Right Hand` = "r_hand" (the Interfector's knife-swish SFX attaches to "r_hand" too).
    SM_SWORD = "/Game/Models/Weapons/Melee/Sword/SM_Sword_01.SM_Sword_01",
    -- The player net launcher's world mesh. Its material (M_NetLauncher) parents
    -- M_AbioticItems_Master, so it tints with DiffuseColor - NOT Color ([[af-abioticitems-master-diffusecolor]]).
    -- An SK_NetLauncher exists too; the static mesh is the one to hang on a hand/weapon socket.
    SM_NETGUN = "/Game/Models/Weapons/Ranged/NetLauncher/SM_NetGun.SM_NetGun",
    -- The two lodestone melee upgrades' WORLD meshes (item rows spear_fire_U1 "Lodespear" /
    -- club_fire_U1 "Lodehammer"). STATIC, so they drop onto a Pillager's `Weapon_Right` component
    -- via AVU.SwapStaticMesh - see the Chosen Canaan variants in AnteNPCs/Pillager.lua.
    SM_SPEAR_LODE  = "/Game/Models/Weapons/Melee/IndustrialSpear/SM_Spear_Lode.SM_Spear_Lode",
    SM_HAMMER_LODE = "/Game/Models/Weapons/Melee/IndustrialClub/SM_Hammer_Lode.SM_Hammer_Lode",
    -- The Woodsman's felling axe (item row `woodaxe`). Its own hand prop, and what the Canaan
    -- Lumberjack throws - a thrown weapon also wants the item ROW, which carries the mesh to clients.
    SM_WOODAXE     = "/Game/Models/Weapons/Melee/WoodAxe/SM_WoodAxe.SM_WoodAxe",
    -- Item row `pickaxe`. Static, so it swaps onto `Weapon_Right` the same way (Chosen Canaan Miner).
    SM_PICKAXE     = "/Game/Models/Weapons/Melee/PickAxe/SM_Pickaxe_01.SM_Pickaxe_01",
    -- The scientist lab rat's scanner tool, STATIC world mesh - drops onto the garage rat's
    -- `R_Weapon` StaticMeshComponent (base SM_PipeWrench) via AVU.SwapStaticMesh (LabRat Shade).
    SM_RATSCANNER = "/Game/Models/Weapons/Melee/RatScanner/SM_RatScanner.SM_RatScanner",
    SM_HEAVY_LASER = "/Game/Models/Weapons/Ranged/HeavyLaser/SM_HeavyLaser.SM_HeavyLaser",
    SK_GRINDER = "/Game/Models/Weapons/Ranged/DiskLauncher/SK_DiskLauncher.SK_DiskLauncher",
    -- SM_BEAKER = "/Game/Models/Items/Tools/SM_Beaker_02.SM_Beaker_02",  -- [unused]
    -- SM_FLASK_COATING = "/Game/Models/Items/Misc/SM_Flask_Coating.SM_Flask_Coating",  -- [unused]
    -- SM_FLASK_DISTILLATION = "/Game/Models/Items/Misc/SM_Flask_Coating.SM_Flask_Distillation",  -- [unused]
    -- SM_FISH_OIL = "/Game/Models/Items/Misc/SM_FishOil.SM_FishOil",
    -- SM_PLUTONIC_BLOOD = "/Game/Models/Items/Misc/SM_PlutonicBlood.SM_PlutonicBlood",  -- [unused]
    SM_LASER_GRENADE = "/Game/Models/Weapons/Ranged/LaserGrenade/SM_LaserGrenade.SM_LaserGrenade",
    SM_RESOURCE238 = "/Game/Models/Items/Misc/SM_Resource238.SM_Resource238",   -- U-238 canister (Heavy Laser Bot backpack)
    SM_JETPACK = "/Game/Models/Items/BackPacks/SM_Jetpack.SM_Jetpack",   -- jetpack (Jotun Rocketeer rocket pack)
    -- The Grunt Captain's radio pack - the grunt family's `backpack` component takes it as a
    -- straight AVU.SwapStaticMesh (same socket, same 1x scale). Its M_RadioPack parents
    -- M_AbioticCharacter_Master, so slot 0 tints with Color.
    SM_RADIO_PACK = "/Game/Models/Characters/NPCs/Grunt/Torso/SM_RadioPack.SM_RadioPack",
    -- Back/belt kit for a grunt body. An ATTACHED prop carries its own mesh AND material, so it
    -- is the one reskin route that never asks whether a texture matches the body's UV family
    -- (T_TORSO_GROUPE has that story). Both are StaticMeshes, so AssetKeeper can pin them.
    -- Both parent M_AbioticItems_Master, so they tint with DiffuseColor - a plain Color writes
    -- nothing ([[af-abioticitems-master-diffusecolor]]).
    SM_MILITARY_PACK = "/Game/Models/Items/BackPacks/SM_MilitaryBackPack_01.SM_MilitaryBackPack_01",
    SM_HIKING_PACK = "/Game/Models/Items/BackPacks/SM_HikingPack.SM_HikingPack",
    -- GK Heavy's goggles, strapless so they sit on a bare head. TWO slots: the body on the item
    -- master (DiffuseColor) and a glass lens on the lens master, which has no DiffuseColor - so a
    -- DiffuseColor spray tints the shell and leaves the lens lit, which is what you want.
    SM_NVG_NOSTRAPS = "/Game/Models/Characters/NPCs/GateKeeperHeavy/SM_NightVisionGoggles_NoStraps.SM_NightVisionGoggles_NoStraps",
    -- The OPEN box: two real material slots (box + the rounds inside). Its closed sibling
    -- SM_AmmoBox_308_01 ships WorldGridMaterial - attach that and you get the checker placeholder.
    -- Worth checking StaticMaterials before attaching any item mesh for the first time.
    SM_AMMOBOX_308 = "/Game/Models/Items/Ammo/SM_AmmoBoxOpen_308_01.SM_AmmoBoxOpen_308_01",
    -- Hardlight spear tip. The visible body of ProjectileRows.HardlightSpear - the ROW loads it at
    -- BeginPlay, so preload it with any spawn of that row or the load lands in-hook.
    SM_SPEAR_HARDLIGHT_TIP = "/Game/Models/Weapons/Melee/HardlightSpear/SM_Spear_Hardlight_Tip.SM_Spear_Hardlight_Tip",
    SM_MORTAR_SHELL = "/Game/Models/Characters/NPCs/LabRat/SM_SapperATLauncher_Ammo.SM_SapperATLauncher_Ammo",   -- AT-launcher shell (defense-bot mortar mesh)
    M_BACKPACK_SMALL_PURPLE = "/Game/Models/Items/BackPacks/M_Backpack_Small_Purple.M_Backpack_Small_Purple",   -- slot-0 override to recolor the U-238 canister / jetpack purple (no tint param on their baked mats)
    M_BACKPACK_SMALL_RED = "/Game/Models/Items/BackPacks/M_Backpack_Small_Red.M_Backpack_Small_Red",
    M_MILITARY_BACKPACK_SNOW = "/Game/Models/Items/BackPacks/M_MilitaryBackPack_Snow.M_MilitaryBackPack_Snow",   -- Groupe Rook shield tint

    -- The rope-rappel props that grunts use to spawn. Hard reffed by grunts
    -- Used by the Speculatores's rappel relocate.
    SM_ROPE_CYLINDER = "/Engine/BasicShapes/Cylinder.Cylinder",
    M_ROPE_GRAY = "/Game/Models/Environment/Walls/M_ABF_GrayGeneric_1sided.M_ABF_GrayGeneric_1sided",

    -- Scientist-zombie dress-up (tie material + reactor-crew ID card mesh/material).
    M_SCIENTIST_TIE_GREEN = "/Game/Models/Characters/Scientist/Materials/M_Scientist_Tie_Green.M_Scientist_Tie_Green",
    SM_IDCARD_DEFAULT = "/Game/Models/Characters/Scientist/IDCards/SM_IDCard_Default.SM_IDCard_Default",
    M_SCIENTIST_IDCARD_REACTORCREW = "/Game/Models/Characters/Scientist/Materials/M_Scientist_IDCard_ReactorCrew.M_Scientist_IDCard_ReactorCrew",

    -- SCIENTIST CLOTHING. Every one of these is a plain M_AbioticCharacter_Master instance whose
    -- only content is a `Texture` param, which is what makes them usable as a RESKIN on some other
    -- character's torso slot (AVU.TintSlot's opts.Material) instead of only on their own mesh.
    --   * The Fallow Patriarch wears the open lab coat over the gatekeeper chest.
    --   * A reskin is UV-dependent: the texture is unwrapped for its own mesh, so it reads
    --     correctly only where the target's unwrap is close enough. Check it in-game.
    M_LABCOAT_TORII_OPEN = "/Game/Models/Characters/Scientist/Male/Materials/M_Labcoat_Torii_Closed.M_Labcoat_Torii_Closed",

    -- MODULAR HUMAN BODY PARTS - for a real MESH swap rather than a reskin. Every torso/head/legs
    -- asset in the game's human families is built on the SAME SK_Human_Skeleton (the gatekeeper
    -- parts in AnteEnums.GateKeeperParts included), so one drops onto an NPC's own `Mesh` via
    -- AVU.SwapSkeletalMesh with the AnimBP, the sockets and any leader-posed follower intact.
    -- Full recipe + the reasons it is the harder road: [[af-skeletal-mesh-swap-recipe]].
    --   * On a MERGED family (grunt/Gatekeeper/Order/Exor/Pillager/Zombie - see
    --     [[af-modular-mesh-merge]]) `Mesh` is the whole BAKED body, so swapping it drops the head
    --     and legs too; they have to go back on as leader-posed followers.
    --   * The SCIENTIST torsos ship PhysicsAsset = None, so a swapped body cannot ragdoll until it
    --     is handed one back - PHYS_HUMAN_ENEMY is what the enemy human meshes carry natively
    --     (SkeletalMeshComponent:SetPhysicsAsset(asset, true)).
    --   * [unused] - kept as the worked example. The Patriarch used these, then went to a reskin
    --     because a scientist torso and a gatekeeper head do not share a neckline.
    SK_TORSO_TORII_OPEN_M = "/Game/Models/Characters/Scientist/Male/SK_Torso_Torii_Open_M.SK_Torso_Torii_Open_M",
    PHYS_HUMAN_ENEMY      = "/Game/Models/Characters/Scientist/Male/PhysAsset_Human_Enemy.PhysAsset_Human_Enemy",

    M_ANTELIGHT_RGB   = "/Game/Models/Items/Farming/M_Antelight_RGB.M_Antelight_RGB",

    -- The Lamogi's PURPLE body texture (what Bigogi wears). The body material's texture param is
    -- literally named "Texture" - NPC_Monster_WinterSprite.All_PerformDeathSequence MIDs slot 0 and
    -- sets it to swap in the surprise face, so this is the same authoritative channel.
    T_GAMESPRITE_PURPLE = "/Game/Models/Characters/NPCs/GameSprite/T_TheGameSprite_Purple.T_TheGameSprite_Purple",

    -- The PLAIN Lamogi's material + its texture atlas (the whiteish-cyan one). SK_TheGameSprite has
    -- exactly ONE material slot named after this material, so the atlas carries face, body, wick and
    -- glasses together - which is why the plain Lamogi can't be recoloured piecewise, and why these
    -- are useful on a mesh (like the Speedy's) that DOES split those into slots.
    M_GAMESPRITE       = "/Game/Models/Characters/NPCs/GameSprite/M_TheGameSprite.M_TheGameSprite",
    T_GAMESPRITE       = "/Game/Models/Characters/NPCs/GameSprite/T_TheGameSprite.T_TheGameSprite",

    -- Alien beehive resource-node mesh (cosmetic prop for the Hive Sow's tail).
    SM_BEEHIVE = "/Game/Models/Items/Nodes/SM_Beehive_ResourceNode.SM_Beehive_ResourceNode",

    -- The Reaper's black-shimmer material. Apply as an OVERLAY (AVU.SetOverlayMaterial) over
    -- another mesh for a "shade" look - keeps the base textures, adds a dark sheen.
    --   * PLAIN translucent, no panner - as an overlay it is a STATIC dark coat, not animated.
    M_REAPER_DARKNESS = "/Game/Models/Characters/NPCs/Reaper/M_Reaper_Darkness.M_Reaper_Darkness",
    -- Sibling reaper BODY materials - the ReaperScout's own skeletal mesh wears one of these (the
    -- "translucent slowly-moving black cloud"). See AnteNPCs/Shades.lua SHADE_BODY_OVERLAY.
    --   * UNVERIFIED paths, guessed from the Reaper folder.
    --   * A bad path just no-ops in ASSETS.GetIfValid, so trying them as a body overlay is safe -
    --     that's how to find which one actually drifts.
    M_REAPER        = "/Game/Models/Characters/NPCs/Reaper/M_Reaper.M_Reaper",
    M_REAPER_FIGURE = "/Game/Models/Characters/NPCs/Reaper/M_Reaper_Figure.M_Reaper_Figure",

    -- The Reaper's helmet static mesh. The Grunt-family Shades swap their Helmet component's mesh
    -- for this (AnteNPCs/Shades.lua swapShadeHelm) to wear the reaper's crown. Falls back silently
    -- to the base helmet if the path doesn't resolve.
    SM_REAPER_HELM = "/Game/Models/Characters/Armor/SM_ReaperHelm.SM_ReaperHelm",

    -- SELF-PANNING overlay candidates (the "translucent clouds drifting across the model" look):
    --   * M_AURA_PAN_GHOSTS - a panning ghost-aura (translucent/unlit); animates on its own as an overlay.
    --   * M_BOSS_SHADOW     - the Shadow Boss's dark moving material (darker; prototype asset - may not
    --                         render on a skeletal mesh if it lacks that usage flag).
    M_AURA_PAN_GHOSTS = "/Game/Particles/Materials/M_Aura_Pan_Ghosts.M_Aura_Pan_Ghosts",
    -- M_BOSS_SHADOW     = "/Game/Prototypes/Boss/M_Boss_Shadow.M_Boss_Shadow",  -- [unused]

    -- Weapon-coating gradient overlays
    -- * Just an OverlayMaterial promoted to a MID with params that drive the look
    --   (GradientDirection colour, GradientBias/Contrast, PulseIntensity/PulseSpeed)
    -- * AVU.ApplyGradientMaterial can paint it on any character mesh (renderer-local)
    -- * GOTCHA: M_WeaponCoating_Melee (the WeaponCoating BP's CDO default) is not cooked/loadable
    --     > every real coating row is in DT_WeaponCoatings - pointing at its own M_WeaponCoating_<Type>
    M_WEAPON_COATING              = "/Game/Prototypes/WeaponCoating/M_WeaponCoating_Thermal.M_WeaponCoating_Thermal",  -- default gradient (warm/red)
    M_WEAPON_COATING_HOLY         = "/Game/Prototypes/WeaponCoating/M_WeaponCoating_Holy.M_WeaponCoating_Holy",
    M_WEAPON_COATING_SOMNIVOROUS  = "/Game/Prototypes/WeaponCoating/M_WeaponCoating_Somnivorous.M_WeaponCoating_Somnivorous",
    M_WEAPON_COATING_DISRUPTOR    = "/Game/Prototypes/WeaponCoating/M_WeaponCoating_Disruptor.M_WeaponCoating_Disruptor",
    M_WEAPON_COATING_ACID         = "/Game/Prototypes/WeaponCoating/M_WeaponCoating_Acid.M_WeaponCoating_Acid",
    M_WEAPON_COATING_ELECTRO      = "/Game/Prototypes/WeaponCoating/M_WeaponCoating_Electromagnetic.M_WeaponCoating_Electromagnetic",

    -- AREA-EFFECT ACTOR CLASSES (AVU.SpawnCloud). Real replicated BP ACTORS, not Niagara - each
    -- carries its own cloud + damage and shows on every machine. They live here, not in Effects,
    -- because Effects is Niagara-only (see its header).
    --   * Peccary spore cloud (its Niagara is Niagara_Spores_PeccaryShake; DamagePerTick can be
    --     zeroed so a layered debuff does the work).
    -- SPORE_CLOUD_PECCARY = "/Game/Blueprints/AreaEffects/AreaEffect_MushroomSporeCloud_Peccary.AreaEffect_MushroomSporeCloud_Peccary_C",  -- [unused]
    -- The thermite molotov's own burn patch (the Magma Exor's reload mortar drops this).
    AREA_MOLOTOV_FIRE = "/Game/Blueprints/AreaEffects/AreaEffect_MolotovBurn.AreaEffect_MolotovBurn_C",
    -- Holy-fire ground patch (the holy molotov's lingering burn). EffectDuration/DamagePerTick tunable.
    AREA_HOLY_FIRE = "/Game/Blueprints/AreaEffects/AreaEffect_MolotovBurn_Holy.AreaEffect_MolotovBurn_Holy_C",
    -- BLUE PLASMA fire patch (the Mage's burn): DamageType_Fire_Plasma + Debuff_Ignited_Plasma.
    -- Projectile_MageFireball spawns it on impact - preload it before lobbing that fireball so its
    -- spawn can't blocking-load in-hook. DamagePerTick 20 / EffectDuration 5s natively.
    AREA_PLASMA_FIRE = "/Game/Blueprints/AreaEffects/AreaEffect_MolotovBurn_Mage.AreaEffect_MolotovBurn_Mage_C",

    -- SKELETAL MESH
    -- Player Hex armor SET (skeletal, shares the human skeleton). Attach with
    -- AVU.AttachSkeletalMesh + opts.LeaderPose=true so each piece follows the body's
    -- animation and the arm/leg plates line up. M_HEX_ARMOR is the shared material.
    SK_ARMOR_CHEST_HEX  = "/Game/Models/Characters/Armor/SKMeshes/SK_Armor_Chest_Hex.SK_Armor_Chest_Hex",
    SK_ARMOR_ARMS_HEX   = "/Game/Models/Characters/Armor/SKMeshes/SK_Armor_Arms_Hex.SK_Armor_Arms_Hex",
    SK_ARMOR_LEGS_HEX   = "/Game/Models/Characters/Armor/SKMeshes/SK_Armor_Legs_Hex.SK_Armor_Legs_Hex",
    SK_ARMOR_HELMET_HEX = "/Game/Models/Characters/Armor/SKMeshes/SK_Armor_Helmet_Hex.SK_Armor_Helmet_Hex",
    M_HEX_ARMOR         = "/Game/Models/Characters/Armor/M_HexArmor.M_HexArmor",

    -- SK_GREEK_ARMOR = "/Game/Models/Characters/Armor/SKMeshes/SK_Armor_Torso_Greek.SK_Armor_Torso_Greek",  -- [unused]
    -- SK_PREACHER_HELM = "/Game/Models/Characters/Armor/SKMeshes/SK_Helmet_Preacher.SK_Helmet_Preacher",  -- [unused]
    -- SK_CHEST_BREACHER = "/Game/Models/Characters/Armor/SKMeshes/SK_Armor_Torso_Breacher.SK_Armor_Torso_Breacher",  -- [unused]
    -- SK_GKHEAVY_NVGS = "/Game/Models/Characters/NPCs/GateKeeperHeavy/SK_NightVisionGoggles.SK_NightVisionGoggles",  -- [unused]
    -- SK_HEAD_SCARF = "/Game/Models/Characters/Armor/SKMeshes/SK_Scarf_Snowman.SK_Scarf_Snowman",  -- [unused]
    -- Static armor pieces (perf: an SM on a socket costs a transform + draw call; the SK_*
    -- attaches above pay skinning every frame - prefer these where a rigid piece reads fine).
    -- SM_FISHING_HAT = "/Game/Models/Characters/Armor/SM_FishingHat.SM_FishingHat",  -- [unused]
    -- SM_HELM_PREACHER = "/Game/Models/Characters/Armor/SM_Armor_Helmet_Preacher.SM_Armor_Helmet_Preacher",  -- [unused]
    -- SM_CHEST_LABS_U2 = "/Game/Models/Characters/Armor/SM_Armor_Labs_Chest_U2.SM_Armor_Labs_Chest_U2",  -- [unused]

    -- PROJECTILES
    SM_STAPLER = "/Game/Models/Items/Nodes/SM_Stapler.SM_Stapler",
    -- SM_POWER_SUPPLY  = "/Game/Models/Items/Electronics/SM_PowerSupply.SM_PowerSupply",  -- [unused]
    SM_TELEPHONE  = "/Game/Models/Items/Electronics/SM_Telephone.SM_Telephone",
    SM_PERSONAL_TELEPORTER = "/Game/Models/Items/Electronics/SM_PersonalTeleporter.SM_PersonalTeleporter",
    SM_PENHOLDER = "/Game/Models/Items/Nodes/SM_PenHolder.SM_PenHolder",
    -- SM_BINDER =  "/Game/Models/Items/Nodes/SM_Binder_01.SM_Binder_01",  -- [unused]
    SM_RUBBERBALL = "/Game/Models/Items/Misc/SM_RubberBandBall.SM_RubberBandBall",
    SM_GRENADE_FRAG = "/Game/Models/Weapons/Ranged/MilitaryGrenade/SM_Grenade_Military_Projectile.SM_Grenade_Military_Projectile",
    SM_GRENADE_LASER = "/Game/Models/Weapons/Ranged/LaserGrenade/SM_LaserGrenade.SM_LaserGrenade",
    -- The null grenade's shell. Its material is M_AbioticItems_Master WITH an emissive mask, so it
    -- takes a DiffuseColor tint and an EmissiveColor glow (Storm Witch shock pulse grenade).
    SM_GRENADE_NULL = "/Game/Models/Weapons/Ranged/NullGrenade/SM_Grenade_Null.SM_Grenade_Null",
    -- SM_HEALING_SYRINGE = "/Game/Models/Items/Healing/SM_Syringe.SM_Syringe",  -- [unused]

    SM_FLASK = "/Game/Models/Items/Throwables/SM_Flask_Throwable.SM_Flask_Throwable",
    -- SK_FLASK_CONSUMABLE = "/Game/Models/Items/Drinks/SK_Flask_Consumable.SK_Flask_Consumable",  -- [unused]
    -- The tincture/drink bottle (every tincture_* item row shares this one SM; the "flavor" is
    -- our tint). The Esoteric Chieftain drinks one on shield break.
    SM_FLASK_CONSUMABLE = "/Game/Models/Items/Misc/SM_Flask_Consumable.SM_Flask_Consumable",
    -- The "food_corn_infected" item's world mesh - the cob a Canaan Farmer eats to corrupt itself.
    -- Held in the left hand (the pitchfork owns Weapon_Right); the item's own TP scale is 0.8.
    SM_CORN_INFECTED = "/Game/Models/Items/Farming/SM_InfectedCorn.SM_InfectedCorn",
    -- The BioCannon's equipped weapon mesh IS the squid creature model (ItemTable_Global row
    -- "biocannon" points straight at it). Attached over the Chieftain's hidden magnum.
    SK_SQUID_BIOCANNON = "/Game/Models/Characters/NPCs/Squid/SK_Squid.SK_Squid",
    -- The squid as a STATIC mesh - the SK_Squid is not animated at all, so this is the cheaper
    -- stand-in for the skink-gun cosmetic (Neophyte Trainer + Esoteric Chieftain). One material slot
    -- ("M_Squid", the default blue); override slot 0 with M_SQUID_MAGMA for the red/magma look.
    SM_SQUID = "/Game/Models/Characters/NPCs/Squid/SM_SquidTest.SM_SquidTest",
    -- Weapon meshes for NPC hand-swaps (hide actor.Gun, attach these at its socket - the Chieftain
    -- squid pattern). SM versions on purpose: the SK weapon meshes are unanimated, same lesson.
    SM_ELECTROTHROWER = "/Game/Models/Weapons/Ranged/Electrothrower/SM_ElectroThrower.SM_ElectroThrower",   -- Storm Witch
    SM_QUILLRIFLE     = "/Game/Models/Weapons/Ranged/QuillRifle/SM_Weapon_QuillRifle.SM_Weapon_QuillRifle", -- Plague Witch
    -- Red "magma" squid material (MaterialInstanceConstant off M_AbioticCharacter_Master) - the
    -- Chieftain's skink-gun material override so it reads as the magma/red skink.
    M_SQUID_MAGMA = "/Game/Models/Characters/NPCs/Squid/M_Squid_Magma.M_Squid_Magma",
    SM_ARMOR_CHEST_CASCADE = "/Game/Models/Characters/Armor/SM_Armor_Chest_Cascade.SM_Armor_Chest_Cascade",
    SM_ARMOR_CHEST_CRYSTAL = "/Game/Models/Characters/Armor/SM_Armor_Chest_Crystal.SM_Armor_Chest_Crystal",
    -- Distillation/chemistry-bench flasks (bulbous alchemist glassware) - the Mad Rat wears these.
    SM_FLASK_DISTILL_INPUT = "/Game/Models/Items/Deployable/SM_Bench_Distillation_Flask_Input.SM_Bench_Distillation_Flask_Input",
    -- SM_FLASK_CHEM_OUTPUT   = "/Game/Models/Items/Deployable/SM_Bench_Chemistry_Flask_Output.SM_Bench_Chemistry_Flask_Output",  -- [unused]
    -- SM_FLASK_CHEM_INPUT2   = "/Game/Models/Items/Deployable/SM_Bench_Chemistry_Flask_Input_02.SM_Bench_Chemistry_Flask_Input_02",  -- [unused]

    -- DECALS
    DECAL_SMILEY = "/Game/Textures/BloodDecals/M_Decal_SmileyFace.M_Decal_SmileyFace",

    -- Testing 
    -- SM_CARAPACE = "/Game/Models/Characters/NPCs/AnteverseBug/SM_BugCarapace.SM_BugCarapace",
    -- SM_LILYCAP = "/Game/Models/Environment/AnteverseC/SM_Mushroom_LilyCap.SM_Mushroom_LilyCap",
    -- SM_MAGE_CHEST = "/Game/Models/Characters/Armor/SM_Armor_Chest_Mage.SM_Armor_Chest_Mage"

    -- SKELETAL MESH SWAPS (whole-body reskin via AVU.SwapBodyMesh - the new mesh MUST share the
    -- actor's skeleton; all SK_NPC_Hopper_* use SK_NPC_Hopper_Skeleton so any swaps onto a Pest).
    -- SK_CARBONATED_PEST = "/Game/Models/Characters/NPCs/Hopper/SK_Hopper_Carbonated.SK_Hopper_Carbonated",  -- [unused]
    -- SK_PEST_VOLATILE   = "/Game/Models/Characters/NPCs/Hopper/SK_NPC_Hopper_volatile.SK_NPC_Hopper_volatile",   -- Volatile Pest body (green volatile look)  -- [unused]



    
    -- MATERIAL MESH SWAPS (works but need to verify its not causing crashes)
    M_TORSO_SNIPER = "/Game/Models/Characters/NPCs/Grunt/Torso/M_Sniper_Torso.M_Sniper_Torso",
    T_TORSO_SNIPER = "/Game/Models/Characters/NPCs/Grunt/Torso/T_Sniper_Torso.T_Sniper_Torso",
    -- Breacher-look GRUNT-BODY torso textures (Grenadier reskin; per-index HealthTextures
    -- writes like the Velites' sniper set - the Injured1-3 set keeps damage feedback).
    T_TORSO_BREACHER          = "/Game/Models/Characters/NPCs/Grunt/Torso/T_BreacherTorso_Rework.T_BreacherTorso_Rework",
    T_TORSO_BREACHER_INJURED1 = "/Game/Models/Characters/NPCs/Grunt/Torso/T_BreacherTorso_Injured1.T_BreacherTorso_Injured1",
    T_TORSO_BREACHER_INJURED2 = "/Game/Models/Characters/NPCs/Grunt/Torso/T_BreacherTorso_Injured2.T_BreacherTorso_Injured2",
    T_TORSO_BREACHER_INJURED3 = "/Game/Models/Characters/NPCs/Grunt/Torso/T_BreacherTorso_Injured3.T_BreacherTorso_Injured3",
    -- The Breacher's GEAR sheet, used cross-slot as a torso skin on the Assault Sniper. It is not
    -- authored for that geometry and stretches, which is the point - it reads as blotchy camo.
    -- Cross-family skins are worth TRYING rather than ruling out: a loose map on a busy mesh can
    -- land somewhere useful, where the same swap on a clean surface reads as noise.
    T_GEAR_BREACHER = "/Game/Models/Characters/NPCs/Grunt/Torso/T_BreacherGear_Rework.T_BreacherGear_Rework",
    -- Groupe torso, the Order Troopers' skin. It is the whole content of M_Groupe_Torso_01, so
    -- writing this texture and swapping that material are the same operation.
    --   * TORSO TEXTURES ARE PER-UV-FAMILY. The four *_Rework torso meshes (Grunt / Breacher /
    --     Captain / Medic) share one layout - the game puts this same skin on SK_Breacher_Torso_Rework
    --     (Trooper) and SK_Medic_Torso_Rework (ShotTrooper). SK_Sniper_Torso is NOT in that set and
    --     is the only one without the suffix: a Rework skin on a sniper body maps to noise that
    --     reads as "nothing changed". Only T_Sniper_Torso + T_SniperTorso_Injured1-3 fit that mesh.
    --   * The mesh half is closed after mutation anyway - MergeAndClearSkeletals has baked head and
    --     legs into Mesh, so there is no torso left to swap on its own.
    --   * No Injured variants in the Groupe set, so a reskin using it also flattens the damage stages.
    T_TORSO_GROUPE = "/Game/Models/Characters/NPCs/Groupe/T_GroupeTorso.T_GroupeTorso",
    -- Shotgunner legs material for the grunt's separate leader-posed Legs component, PLUS the
    -- breacher legs texture forced into its "Texture" param (the material's default alone did
    -- not read in-game - same belt-and-suspenders as the sniper-torso reskin).
    M_LEGS_SHOTGUNNER = "/Game/Models/Characters/NPCs/Grunt/Legs/M_Shotgunner_Legs.M_Shotgunner_Legs",
    T_LEGS_BREACHER   = "/Game/Models/Characters/NPCs/Grunt/Legs/T_BreacherLegs_Rework.T_BreacherLegs_Rework",
    -- REMOVED: T_Breacher_Rework, the Grunt_Shotgun torso diffuse the Skirmisher reskinned with.
    -- Skirmisher is a Color-param reskin now.
    --   * It failed to resolve too often - the reskin became a coin flip, and every miss logged.
    --   * Applying it meant writing HealthTextures, a TArray of asset pointers and the sharpest
    --     edge we have (CLAUDE.md S3).

    -- GK HEAVY "WHITE" KIT - the material set the white/purple narrative Jotun wears, one MI per
    -- material SLOT of the Heavy's three body components (Mesh = torso, Head = helmet, Legs).
    -- Swap them per slot with AVU.TintSlot and tint on top; the Jotun of the Fallow is white/red.
    --   * M_GKHeavy_Fabric_Purple is the SECONDARY (belt/tassets) MI and its name lies - it wears
    --     T_GKHeavyFabric_WHITE, so it takes a tint cleanly.
    --   * The helmet MI ships a PURPLE EmissiveColor (0.05, 0, 1) - override it or the visor stays
    --     the narrative NPC's colour.
    --   * THE TEXTURES ARE LISTED TOO, and they are not redundant: a `SetMaterial` swap is the thing
    --     most likely to be silently undone (the health-stage flow rewrites the torso's "Texture"
    --     param; an MID already on a slot keeps its own params), so each slot gets the matching
    --     texture written onto its MID as well - belt and braces for one draw call's worth of work.
    --     The helmet's GLOW is a second atlas (EmissiveTexture) - swapping only the albedo leaves
    --     the old pattern lit through the new skin.
    M_GKHEAVY_TORSO_WHITE  = "/Game/Models/Characters/NPCs/GateKeeperHeavy/M_GKHeavy_Torso_White.M_GKHeavy_Torso_White",
    M_GKHEAVY_HELMET_WHITE = "/Game/Models/Characters/NPCs/GateKeeperHeavy/M_GKHeavy_Helmet_White.M_GKHeavy_Helmet_White",
    M_GKHEAVY_LEGS_WHITE   = "/Game/Models/Characters/NPCs/GateKeeperHeavy/M_GKHeavy_Legs_White.M_GKHeavy_Legs_White",
    M_GKHEAVY_FABRIC_WHITE = "/Game/Models/Characters/NPCs/GateKeeperHeavy/M_GKHeavy_Fabric_Purple.M_GKHeavy_Fabric_Purple",
    T_GKHEAVY_TORSO_WHITE  = "/Game/Models/Characters/NPCs/GateKeeperHeavy/T_GKHeavyTorso_White.T_GKHeavyTorso_White",
    T_GKHEAVY_HELMET_WHITE = "/Game/Models/Characters/NPCs/GateKeeperHeavy/T_GKHeavyHelmet_White.T_GKHeavyHelmet_White",
    T_GKHEAVY_HELMET_EM_WHITE = "/Game/Models/Characters/NPCs/GateKeeperHeavy/T_GKHeavyHelmet_Emissive_White.T_GKHeavyHelmet_Emissive_White",
    T_GKHEAVY_LEGS_WHITE   = "/Game/Models/Characters/NPCs/GateKeeperHeavy/T_GKHeavyLegs_White.T_GKHeavyLegs_White",
    T_GKHEAVY_FABRIC_WHITE = "/Game/Models/Characters/NPCs/GateKeeperHeavy/T_GKHeavyFabric_White.T_GKHeavyFabric_White",

    -- Zombie head = scientist head MESH + the zombie ("z") skin MATERIAL (the rot is the
    -- material). Swap onto a grunt's separate Head component for a zombie-soldier look.
    -- SK_HEAD_ZOMBIE = "/Game/Models/Characters/Scientist/Male/SK_Head_M_01.SK_Head_M_01",  -- [unused]
    -- M_HEAD_ZOMBIE  = "/Game/Models/Characters/Scientist/Male/Materials/M_Male_Head_01z.M_Male_Head_01z",  -- [unused]

    -- SKELETAL MESH LIMB SWAPS (couldn't get this to work)
    -- SK_TORSO_SNIPER = "/Game/Models/Characters/NPCs/Grunt/Torso/SK_Sniper_Torso.SK_Sniper_Torso",
    -- SK_LEGS_BREACHER = "/Game/Models/Characters/NPCs/Grunt/Legs/SK_Breacher_Legs_Rework.SK_Breacher_Legs_Rework",
    --SkeletalMesh /Game/Models/Characters/NPCs/Grunt/Legs/SK_Captain_Legs_Rework.SK_Captain_Legs_Rework
    
    -- MYSTAGOGUE (Gatekeeper_Mage) recolour set: a red hood/robes base plus GREEN and ORANGE
    -- material variants per body region (Head / Torso / Legs).
    --   * Swapped whole-material in GK_MageHelpers.lua (H.MystagogueRecolor): Barrier Mage = orange,
    --     Abjurer Mage = green.
    --   * The base red materials are un-suffixed on the mesh, so the swap matches on the
    --     "Head"/"Torso"/"Legs" region word - it works whatever the base suffix is.
    M_MYST_HEAD_GREEN   = "/Game/Models/Characters/NPCs/GateKeeperMystagogue/M_GateKeeper_Mystagogue_Head_Green.M_GateKeeper_Mystagogue_Head_Green",
    M_MYST_HEAD_ORANGE  = "/Game/Models/Characters/NPCs/GateKeeperMystagogue/M_GateKeeper_Mystagogue_Head_Orange.M_GateKeeper_Mystagogue_Head_Orange",
    M_MYST_TORSO_GREEN  = "/Game/Models/Characters/NPCs/GateKeeperMystagogue/M_GateKeeper_Mystagogue_Torso_Green.M_GateKeeper_Mystagogue_Torso_Green",
    M_MYST_TORSO_ORANGE = "/Game/Models/Characters/NPCs/GateKeeperMystagogue/M_GateKeeper_Mystagogue_Torso_Orange.M_GateKeeper_Mystagogue_Torso_Orange",
    M_MYST_LEGS_GREEN   = "/Game/Models/Characters/NPCs/GateKeeperMystagogue/M_GateKeeper_Mystagogue_Legs_Green.M_GateKeeper_Mystagogue_Legs_Green",
    M_MYST_LEGS_ORANGE  = "/Game/Models/Characters/NPCs/GateKeeperMystagogue/M_GateKeeper_Mystagogue_Legs_Orange.M_GateKeeper_Mystagogue_Legs_Orange",
    -- The Mystagogue BODY - the friendly/narrative mesh (the `_Enemy` sibling is the combat one).
    -- ONE whole-body skeletal on SK_Human_Skeleton, NOT the modular Head/Torso/Legs set the
    -- Chieftain uses, so it carries its own materials and can be attached standalone with no
    -- MergeAndClearSkeletals caveat ([[af-modular-mesh-merge]]). Used as the ModuleBobbleheads
    -- `mystagogue` figure.
    --   *** IT HAS CHAOS CLOTH *** (3 ClothingAssetCommon entries on the robe). A cloth sim does
    --   not scale with the component, so on a 0.165 figurine it hangs wrong - the bobblehead
    --   overlay sets bDisableClothSimulation.
    SK_MYSTAGOGUE       = "/Game/Models/Characters/NPCs/GateKeeperMystagogue/SK_Gatekeeper_Mystagogue.SK_Gatekeeper_Mystagogue",

    -- The Symphonist body, ONE whole-body skeletal on its own skeleton (bone list in
    -- AnteEnums.Bones.Symphonist - the finger bones l_/r_index2 + l_/r_pinky2 are what the
    -- Orchestrator hangs its four coloured lights off). No cloth, no modular parts. Used as the
    -- ModuleBobbleheads `symph` figure; never resident otherwise, so it lives or dies by the
    -- module's preload+pin batch.
    SK_SYMPHONIST       = "/Game/Models/Characters/NPCs/Symphonist/SK_Monster_Symphonist.SK_Monster_Symphonist",

    -- =======================================================================
    -- CONSOLIDATED asset paths (migrated from per-file locals 2026-07-19). One source of truth;
    -- the origin file keeps a thin local/AVU alias pointing here (no use-site churn).
    -- =======================================================================

    -- Gatekeeper energy-shield SHELL overlay material (native body-shield look). Shared by the
    -- Jotun mount shell, AVU.AttachShieldShell (AVU.SHIELD_SHELL_MAT), and the Shield Pest.
    M_ENERGY_SHIELD = "/Game/Particles/OverlayMaterials/M_GateKeeper_EnergyShield.M_GateKeeper_EnergyShield",
    -- The Pillager Preacher's HOLY body-shield skin - the SAME UBodyShieldComponent_C, reskinned.
    --   * ShieldMesh wears this MI (a pre-tinted gold/white M_EnergyShield_Master child), not GK teal.
    --   * The COMPONENT swaps all four Particle_Shield* to the Niagara_Shield_*_Holy set
    --     (ENUMS.Effects) + Color_FullShield (5, 4.09, 0.80).
    --   * Param-tinting the GK MI cannot get there: it exposes NO parameters (see M_Ignited below).
    M_PREACHER_ENERGY_SHIELD = "/Game/Particles/OverlayMaterials/M_Preacher_EnergyShield.M_Preacher_EnergyShield",
    -- The Preacher's PURPOSE-BUILT holy shell mesh - the original holy-shield NPC's own
    -- `ShieldMesh` SCS component (hidden, tagged "bodyshield", wearing M_Preacher_EnergyShield).
    -- Pass it to AVU.AttachShieldShell instead of letting it copy the body mesh: it's authored to
    -- read as a force field, and it leader-poses onto any Pillager (same parent skeleton).
    SK_BODYSHIELD_PREACHER = "/Game/Models/Characters/Accessories/SK_BodyShield_Preacher.SK_BodyShield_Preacher",
    -- THE reaper/shade "cloud": the ReaperScout's OverlayMaterial (confirmed via /dumpmat - its body
    -- slots are just a dark scientist mannequin, this overlay is the whole translucent-black-cloud
    -- look). Apply as a body OVERLAY (AVU.SetOverlayMaterial) for an authentic shade.
    M_NIGHTSHADOW = "/Game/Particles/OverlayMaterials/M_NightShadow.M_NightShadow",
    -- THE ONE TINTABLE BODY OVERLAY - the burning-body overlay the Ignited debuff rows hang off
    -- (MaterialEffect on DT_BuffsDebuffs), so it is proven on SKELETAL characters. Seat it with
    -- AVU.SetOverlayMaterialDynamic and set its two params on the MID (its two shipped children
    -- differ ONLY by these):
    --   * Color - FVector, HDR (values >1 = emissive). Holy = (20, 19.6, 0), Plasma = (1.7, 0, 20).
    --   * "Boost Emssive" - scalar glow multiplier (the typo IS the param name). Both children use 5.
    --   * It's a translucent unlit shimmer, NOT a solid coat - the base textures read through it.
    --   * Why this one: M_NightShadow / M_Reaper_Darkness / M_GateKeeper_EnergyShield expose NO
    --     parameters at all (zero parameter nodes in the FModel exports), so a "best-effort tint"
    --     on them silently no-ops and every wearer looks identical.
    M_IGNITED = "/Game/Particles/OverlayMaterials/M_Ignited.M_Ignited",

    -- Sniper-head mesh reused as a face MASK (Jotun rider + Shield Pest, leader-posed to "Head").
    SK_SNIPER_HEAD = "/Game/Models/Characters/NPCs/Grunt/Heads/SK_Sniper_Head.SK_Sniper_Head",

    -- Spinning grinder-disc mesh (Warden MageEye melee + Security Robot disc projectile).
    SM_GRINDER_DISC = "/Game/Models/Items/Tools/SM_GrinderDisk_Spinning.SM_GrinderDisk_Spinning",
    -- The deployable disc turret's launcher head on its own (the big bots' shoulder guns).
    SM_DISC_LAUNCHER_TURRET = "/Game/Models/Items/Electronics/SM_DiskLauncher_Turret.SM_DiskLauncher_Turret",

    -- Peccary body SK - the Jotun mount's shield-shell mesh.
    SK_PECCARY = "/Game/Models/Characters/NPCs/Peccary/SK_NPC_Peccary.SK_NPC_Peccary",
    -- Hopper (Pest) body SK - the Shield Pest's shield-shell mesh.
    SK_HOPPER = "/Game/Models/Characters/NPCs/Hopper/SK_NPC_Hopper.SK_NPC_Hopper",
    -- MageEye drone SK - the one mesh the Vacuum U2 hard-codes (AVU.VACUUMABLE_MESH).
    SK_MAGE_EYE_DRONE = "/Game/Models/Characters/NPCs/GateKeeperMystagogue/SK_MageEyeDrone.SK_MageEyeDrone",
    -- The shield-recharge burst that plays ON a body being topped up (the Abjurer's beam).
    SHIELD_REGEN_HOLY = "/Game/Particles/Niagara_Shield_Regen_Holy.Niagara_Shield_Regen_Holy",

    -- The Mystagogue's forward hardlight plate (AVU.AddShieldWall). ~402 wide x 253 tall at scale 1,
    -- and the mesh is NOT centred - it spans local Z -140..+112, which is what the wall's Z offset
    -- is measured against. SM_Shield_Mage_2Sided is the SAME geometry with an added inside-face
    -- material slot, for the player's dropshield; only use it if a wall needs a visible back face.
    SM_SHIELD_MAGE = "/Game/Models/Characters/NPCs/GateKeeperMystagogue/SM_Shield_Mage.SM_Shield_Mage",
    -- Warden MageEye emissive eye texture (desaturated, recolored per alert state).
    T_MAGEEYE_EMISSIVE_DESAT = "/Game/Models/Characters/NPCs/GateKeeperMystagogue/T_MageEyeDrone_Emissive_Desat.T_MageEyeDrone_Emissive_Desat",

    -- Deployable barricade paint materials (SetPaintColor targets; preloaded before the swap).
    M_SANDBAG       = "/Game/Models/Items/Deployable/M_Sandbag.M_Sandbag",                         -- Order Captain sandbag wall (Brown)
    M_CEMENTBAG_RED = "/Game/Models/Items/Deployable/Painted/M_CementBag_Red.M_CementBag_Red",     -- Defense Bot bunker (Red)

    -- TRADER COSTUMES (ModuleTraders/Traders): vending-machine body + the Hank scientist customization set.
    SM_VENDING_MACHINE    = "/Game/Models/Environment/Power/SM_VendingMachine_01.SM_VendingMachine_01",
    M_VENDING_MACHINE     = "/Game/Models/Environment/Power/M_VendingMachine_03.M_VendingMachine_03",   -- KizzCola body mat (slot 0)
    SK_FISHING_ROD        = "/Game/Models/Items/Tools/SK_FishingRod_T1.SK_FishingRod_T1",
    SK_HAIR_HUDSON        = "/Game/Models/Characters/Scientist/HeadAccessories/Hair/SK_Hair_Hudson.SK_Hair_Hudson",
    SK_GLASSES_BUBBLES    = "/Game/Models/Characters/Scientist/HeadAccessories/SK_Glasses_Bubbles.SK_Glasses_Bubbles",
    SK_TORSO_DRESSSHIRT_M = "/Game/Models/Characters/Scientist/Male/SK_Torso_DressShirt_M.SK_Torso_DressShirt_M",
    SK_LEGS_LABPANTS      = "/Game/Models/Characters/Scientist/Male/SK_Legs_LabPants.SK_Legs_LabPants",
    M_SCIENTIST_PANTS_02  = "/Game/Models/Characters/Scientist/Male/Materials/M_Scientist_Pants_02.M_Scientist_Pants_02",
    M_SCIENTIST_TIE_GRAY  = "/Game/Models/Characters/Scientist/Materials/M_Scientist_Tie_Gray.M_Scientist_Tie_Gray",

}

-- Other components

-- Self-driving component (server side ticks, traces every 0.2s, DamageType_Laser, replicates a Niagara_LaserEmitterBeam)
-- See AnteUtils/Lasers.lua -> Lasers.FireBurst
AnteEnums.LaserComponent = "/Game/Blueprints/Lasers/LaserComponent.LaserComponent_C"


-- NIAGARA SYSTEMS ONLY - every path a spawn/attach/ClientFX call feeds to a Niagara component.
-- Meshes, materials and AreaEffect ACTOR classes go in AnteEnums.Components (see its header for
-- why the boundary is worth keeping).
AnteEnums.Effects = {

    ----------------------
    -- Test
    FIRE_DRIPPING = "/Game/Realistic_Starter_VFX_Pack_Niagara/Niagara/Fire/NS_Fire_Dripping.NS_Fire_Dripping",
    --
    ----------------------

    -- Hitscan tracer beams. Preload (variant Assets) so a SUMMONED shooter's FIRST shot doesn't
    -- blocking-load = a ~250ms hitch.
    --   * ASSASSIN - Crystallisk family, SpawnSystemAtLocation on fire.
    --   * SNIPER - drives "User.BeamEnd" (Order Sniper, island BossAlly sniper); the Fallow
    --     Patriarch's DL_SNIPE_AIM/SHOT ClientFX entries draw with it.
    NIAGARA_ASSASSIN_TRACER = "/Game/Particles/Niagara_Assassin_Tracer.Niagara_Assassin_Tracer",
    SNIPER_TRACER = "/Game/Particles/Niagara_Sniper_Tracer.Niagara_Sniper_Tracer",
    -- A holy bolt's trail: a HORIZONTAL LINE, ~2m at scale 1, and near enough one-dimensional -
    -- a uniform scale lengthens it and barely changes its thickness. That is what makes it usable
    -- as a drawn ray between two points off the plain point channel: aim with yaw, set the length
    -- with the send's uniform scale. (The BoltTrail family also has _Acid/_Fire/_Shock/_Rebar.)
    NIAGARA_BOLTTRAIL_HOLY = "/Game/Particles/Niagara_BoltTrail_Holy.Niagara_BoltTrail_Holy",

    -- Used by the Groupe Sniper vanish and Groupe Frostpack blink.
    NIAGARA_YETI_SLAM = "/Game/Particles/Niagara_Yeti_Slam.Niagara_Yeti_Slam",

    -- Debuff_Frost / Debuff_SniperRifleIce body FX (their DT_BuffsDebuffs BodyParticleEffect).
    -- * Won't deadlock, but preload this or the first apply may hitch
    NIAGARA_DEBUFF_FROZEN = "/Game/Particles/Niagara_Debuff_Frozen.Niagara_Debuff_Frozen",

    -- Used as the Gatekeeper's portal (Furniture Store rectangle rift)
    -- * Loops, and client-fx only (AnteEnums.ClientFX / AVU.SendClientFX)
    -- * Avoid AVU.BroadcastFX: the GameState multicast spawns with bAutoDestroy, which never fires
    --     for a loop and the server can't close it on a client
    PORTAL_DOOR = "/Game/Particles/Niagara_Portal_Door.Niagara_Portal_Door",

    -- The red Anteverse portal (the ShadowBoss phase-3 arena gates)
    -- * Client-fx only, like PORTAL_DOOR
    PORTAL_REDVERSE = "/Game/Particles/Niagara_Portal_Redverse.Niagara_Portal_Redverse",

    -- Night Realm portal - a one dimensional fx
    -- * Client-Fx only
    PORTAL_NIGHTREALM = "/Game/Particles/Niagara_Portal_NightRDoor_2.Niagara_Portal_NightRDoor_2",

    -- One-shot portal burst (ClientFX FX.PORTAL_FX arrival pop).
    PORTAL_BURST_ONCE = "/Game/Particles/Trailer/Niagara_Portal_BurstOnce.Niagara_Portal_BurstOnce",

    -- Yellow portal - used by Inquisitors
    PORTAL_FRIENDLY_YELLOW = "/Game/Particles/Niagara_Portal_Friendly.Niagara_Portal_Friendly",

    -- Drifting will-o'-wisp orbs, one per colour (the Beholder eyes' projectile trails).
    --   * PROJ.Queue TrailFX only - a runtime-added NiagaraComponent is host/SP-local, so the
    --     projectile underneath still has to read right on its own for a dedicated client.
    --   * The BLUE one is deliberately unused: it parks a large cyan orb at the muzzle that
    --     outlives the shot and drowns it out. That slot fires a plasma DISC instead - a class-baked
    --     mesh, which replicates and can actually be scaled.
    WISP_BLUE  = "/Game/Particles/Niagara_VOTV_Wisp_Blue.Niagara_VOTV_Wisp_Blue",
    WISP_GREEN = "/Game/Particles/Niagara_VOTV_Wisp_Green.Niagara_VOTV_Wisp_Green",
    WISP_RED   = "/Game/Particles/Niagara_VOTV_Wisp_Red.Niagara_VOTV_Wisp_Red",

    -- Small arc of solid blue lightning (Exor Spiritwalker)
    LIGHTNING_ELECTRICDAM = "/Game/Particles/Niagara_ElectricArc_Dam.Niagara_ElectricArc_Dam",
    
    -- Lightning dancing across a surface. Blue or purple. Used by several variants
    LIGHTNING_STUN = "/Game/Particles/Niagara_Electricity_Stun.Niagara_Electricity_Stun",
    LIGHTNING_PURPLE = "/Game/Particles/Niagara_Electricity_Stun_Purple.Niagara_Electricity_Stun_Purple",
    -- Debuff_ZappedPurple's MaterialEffect - the body overlay that rides with LIGHTNING_PURPLE.
    -- The buff row names it, so preload it WITH the niagara or the pair half cold-loads.
    M_ELECTRICITY_SHOCK_PURPLE = "/Game/Particles/Materials/M_Electricity_Shock_Purple.M_Electricity_Shock_Purple",

    -- Charging flask impact - yellow electric sphere
    FLASK_CHARGING = "/Game/Particles/Niagara_Flask_Charging_Impact.Niagara_Flask_Charging_Impact",

    -- Blizzard flask impact - snow impact
    NIAGARA_FLASK_BLIZZARD = "/Game/Particles/Niagara_Flask_Blizzard.Niagara_Flask_Blizzard",

    -- Snowball burst. Assigned to a projectile's ExplosionParticleFX. Winterfector uses this
    NIAGARA_SNOWBALL_EXPLODE = "/Game/Particles/Niagara_BigSnowballExplode.Niagara_BigSnowballExplode",

    -- Slushie fx, Whiteout Peccary uses this
    NIAGARA_SLUSHIE = "/Game/Particles/Niagara_Slushie.Niagara_Slushie",

    -- Snowman ground slam - a dense ~1s snow explosion. Groupe Sniper's vanish cover
    NIAGARA_SNOWMAN_GROUNDPOUND = "/Game/Particles/Niagara_Snowman_GroundPound.Niagara_Snowman_GroundPound",

    -- Snowman frostcone - does not appear to render. The Snowman uses this with Niagara_Snowman_FrostSlide_01
    -- The sibling can't be ported
    NIAGARA_SNOWMAN_SPRAY = "/Game/Particles/Niagara_Snowman_FrostSpray.Niagara_Snowman_FrostSpray",

    -- Crystallisk purple smoke burst. Used by Praetorium Sniper. Can't be recolored
    NIAGARA_SMOKESCREEN = "/Game/Particles/Niagara_Assassin_Smokescreen.Niagara_Assassin_Smokescreen",

    -- Upward wind column off the updraft flask. Reads as a ground marker without whiting out the
    -- screen of whoever is standing in it.
    FLASK_UPDRAFT = "/Game/Particles/Niagara_Flask_Updraft_Impact.Niagara_Flask_Updraft_Impact",

    -- Rose petals blow in a medium area
    TORII_PETALS = "/Game/Particles/Niagara_Environment_Petals_TORII.Niagara_Environment_Petals_TORII",

    -- Dust particles float without movement
    DUST_RAINBOW = "/Game/Particles/Niagara_Dust_Rainbow.Niagara_Dust_Rainbow",

    -- Black smoke cloud on the ground. Used by Shades - REAPER_SHADOWMELD was prone to freezes
    FLASK_PHEROMONE_IMPACT = "/Game/Particles/Niagara_Flask_Pheromone_Impact.Niagara_Flask_Pheromone_Impact",

    -- Shield break
    SHIELD_BREAK  = "/Game/Particles/Niagara_Shield_Break.Niagara_Shield_Break",
    SHIELD_REGEN  = "/Game/Particles/Niagara_Shield_Regen.Niagara_Shield_Regen",

    -- Holy Bodyshield set. Used by PillagerPreacher and Purifier/Purified Order NPCs
    SHIELD_BROKEN_HOLY = "/Game/Particles/Niagara_Shield_Broken_Holy.Niagara_Shield_Broken_Holy",
    SHIELD_BREAK_HOLY  = "/Game/Particles/Niagara_Shield_Break_Holy.Niagara_Shield_Break_Holy",
    SHIELD_REGEN_HOLY  = "/Game/Particles/Niagara_Shield_Regen_Holy.Niagara_Shield_Regen_Holy",
    SHIELD_IMPACT_HOLY = "/Game/Particles/Niagara_Shield_Impact_Holy.Niagara_Shield_Impact_Holy",

    -- Light blue ball
    PLASMA_PROJECTILE = "/Game/Particles/Niagara_Projectile_Plasma.Niagara_Projectile_Plasma",

    -- Crackly lightning. Used by Esoteric Chieftain
    TINCTURE_ELECTRIC_PASSIVE = "/Game/Particles/Niagara_Tincture_Electrifying_Passive.Niagara_Tincture_Electrifying_Passive",

    -- Nova similar to ElectroPest. Used by Esoteric Chieftain / Storm Witch
    TINCTURE_ELECTRIC_BURST = "/Game/Particles/Niagara_Tincture_Electrifying_Burst.Niagara_Tincture_Electrifying_Burst",

    -- The Electro Pest's leap ring - a lightning sphere that expands and dies in about a second.
    -- Exposes no user params, so its only size handle is the component scale.
    ELECTROPEST_SHOCKRING = "/Game/Particles/Niagara_ElectroPest_ShockRing_Attack.Niagara_ElectroPest_ShockRing_Attack",

    -- White (purple) air smoke poof
    TINCTURE_GIGANTO_POOF = "/Game/Particles/Niagara_White_Smokescreen.Niagara_White_Smokescreen",

    -- Water droplets being absorbed
    BUFF_FARGARDEN = "/Game/Particles/Niagara_Buff_Fargarden.Niagara_Buff_Fargarden",

    -- Large green healing bubble
    HEALING_FORCEFIELD_MAGE = "/Game/Particles/Niagara_Healing_ForceField_AllyMage.Niagara_Healing_ForceField_AllyMage",
    -- The restorative flask's impact burst (its ExplosionParticleFX), finite: fine over BroadcastFX.
    FLASK_RESTORATIVE_BURST = "/Game/Particles/Niagara_Flask_Restorative.Niagara_Flask_Restorative",

    -- Cloud of bees FX used by Hive Sow and Plague Witch
    BEES = "/Game/Particles/Niagara_Bees.Niagara_Bees",
    BEE_SWARM = "/Game/Particles/Niagara_BeeAttackSwarm.Niagara_BeeAttackSwarm",
    SPORES_PECCARY_SHAKE = "/Game/Particles/Niagara_Spores_PeccaryShake.Niagara_Spores_PeccaryShake",
    SPORES_MUSHROOM = "/Game/Particles/Niagara_Spores_MagicMushroom.Niagara_Spores_MagicMushroom",
    -- A directional spore burst. No size param - only HSV/alpha ranges - so it rides the client-FX
    -- channel (CORN_SPORES), where the transform scale is the only lever and it can be tuned live.
    SPORES_BURST = "/Game/Particles/Niagara_Mushroom_Spores.Niagara_Mushroom_Spores",
    
    -- Fireball trail. Used by Magma Exor to add a trail
    NIAGARA_FIREBALL = "/Game/Particles/Niagara_MagmaSkink_Fireball.Niagara_MagmaSkink_Fireball",

    FIRE_HOLY = "/Game/Particles/Niagara_Fire_Torch_Holy.Niagara_Fire_Torch_Holy",

    -- Used by Magma Peccary
    CAMPFIRE_BASIC = "/Game/Realistic_Starter_VFX_Pack_Niagara/Niagara/Fire/NS_Campfire_Basic.NS_Campfire_Basic",
    MAGMAPEST_EXPLOSION = "/Game/Particles/Niagara_MagmaPest_Explosion.Niagara_MagmaPest_Explosion",

    -- Used by Jotun Rocketeer to mimic rocket backpack and Rocket Rat
    EXPLOSION_BIG_2 = "/Game/Realistic_Starter_VFX_Pack_Niagara/Niagara/Explosion/NS_Explosion_Big_2.NS_Explosion_Big_2",  
    MUZZLE_FLASH = "/Game/Particles/Niagara_MuzzleFlash_Default.Niagara_MuzzleFlash_Default",
    EXPLOSION_BIG = "/Game/Realistic_Starter_VFX_Pack_Niagara/Niagara/Explosion/NS_Explosion_Big_4.NS_Explosion_Big_4", 


    -- The Mage Eye's tether beam, in its friendly (ally-drone) colourway. Same shape as the Exor
    -- tethers below - drawn from its spawn point to a beam-end param - but the param is spelled
    -- "User.Beam End", with a space (the LaserEmitterBeam family's spelling).
    MAGEEYE_BEAM_ALLY = "/Game/Particles/Niagara_LaserBeam_MageEye_Ally.Niagara_LaserBeam_MageEye_Ally",

    -- Exor FX. Mostly used by Exor variants
    EXOR_BEAM = "/Game/Particles/Niagara_Exor_Beam.Niagara_Exor_Beam",
    EXOR_CHARGEUP = "/Game/Particles/Niagara_Exor_ChargeUp.Niagara_Exor_ChargeUp",
    EXOR_SHOCKWAVE = "/Game/Particles/Niagara_Exor_Shockwave.Niagara_Exor_Shockwave",
    EXOR_BEAM_CHA = "/Game/Particles/Niagara_Exor_Beam_Cha.Niagara_Exor_Beam_Cha",
    EXOR_CHARGEUP_CHA = "/Game/Particles/Niagara_Exor_ChargeUp_Cha.Niagara_Exor_ChargeUp_Cha",
    EXOR_SHOCKWAVE_CHA = "/Game/Particles/Niagara_Exor_Shockwave_Cha.Niagara_Exor_Shockwave_Cha",
    EXOR_BLINK_CHA = "/Game/Particles/Trailer/Niagara_ExorMonk_Blink_Cha.Niagara_ExorMonk_Blink_Cha",
    PORTAL_RIFT_BLUEFADE = "/Game/Particles/Niagara_Portal_Rift_BlueFade.Niagara_Portal_Rift_BlueFade",
    EXOR_BLINK = "/Game/Particles/Trailer/Niagara_ExorMonk_Blink.Niagara_ExorMonk_Blink",
    EXOR_BLINK_SFX = "/Game/Audio/Monsters/Exor/NPC_Monk_Blink_Cue.NPC_Monk_Blink_Cue",
    -- Dark one-shot impact burst (Projectile_ShadowBeam's explosion, the Witch boss ally's slam).
    -- The Exorrior Magus' pushback nova, over the client-FX channel so it can be slowed.
    SHADOW_IMPACT_LITE = "/Game/Particles/Niagara_Boss_Shadow_Impact_Lite.Niagara_Boss_Shadow_Impact_Lite",
    -- Debuff_ParryStun's body overlay - its ONLY visual, and the reason that row is the quiet stun.
    M_PARRY_INDICATOR = "/Game/Particles/Materials/M_ParryIndicator.M_ParryIndicator",


    -- Drawn from its spawn point to a "User.BeamEnd" Vec3 param, like the Exor tethers. Storm Witch uses this
    TECHSPEAR_BEAM = "/Game/Particles/Niagara_TechSpear_LightningBeam.Niagara_TechSpear_LightningBeam",
    TECHSPEAR_IMPACT = "/Game/Particles/Niagara_TechSpear_Impact.Niagara_TechSpear_Impact",

    -- Used by Acidic Exor
    ACID_MACE_IMPACT = "/Game/Particles/Niagara_Mace_Acid_Impact.Niagara_Mace_Acid_Impact",
    ACID_COATING_IMPACT = "/Game/Particles/Niagara_Coating_Acid_Impact.Niagara_Coating_Acid_Impact",
    BUFF_FLASK_CORROSIVE = "/Game/Particles/Niagara_Buff_Flask_Corrosive.Niagara_Buff_Flask_Corrosive",

    -- Looping black leaves shedding off the Reaper's helm - attach to a shade for animated motion.
    REAPER_BLACK_LEAVES = "/Game/Particles/Niagara_ReaperHelm_BlackLeaves.Niagara_ReaperHelm_BlackLeaves",

    
    -- Player vomit
    VOMIT_PLAYER = "/Game/Realistic_Starter_VFX_Pack_Niagara/Niagara/Fire/NS_PlayerVomit.NS_PlayerVomit",
    
    -- Plasma-disc detonation burst (Security Robot disc projectile).
    EXPLOSION_PLASMA_DISC = "/Game/Realistic_Starter_VFX_Pack_Niagara/Niagara/Explosion/NS_Explosion_PlasmaDisc.NS_Explosion_PlasmaDisc",
    
    -- Weather blizzard system (SubFXZone_Blizzard - AVU.BLIZZARD_NIAGARA).
    BLIZZARD_WEATHER = "/Game/Particles/Niagara_Weather_Blizzard.Niagara_Weather_Blizzard",
    
    -- ULaserComponent FX set (beam / end-impact / receiving particle). AnteUtils/Lasers.
    -- Everything OnRep_LaserActive can reach on its way to a visible beam is listed in
    -- Lasers.BURST_ASSETS - keep the two in step.
    LASER_EMITTER_BEAM = "/Game/Particles/Niagara_LaserEmitterBeam.Niagara_LaserEmitterBeam",
    LASER_END_IMPACT   = "/Game/Particles/Niagara_LaserEndImpact.Niagara_LaserEndImpact",
    LASER_RECEIVING    = "/Game/Particles/Niagara_Laser_ReceivingParticle.Niagara_Laser_ReceivingParticle",
    -- The three beam MATERIALS Local_ChangeLaserColor picks between (plain / black / glitched).
    M_LASERBEAM          = "/Game/Particles/Materials/M_LaserBeam.M_LaserBeam",
    M_LASERBEAM_BLACK    = "/Game/Particles/Materials/M_LaserBeam_Black.M_LaserBeam_Black",
    M_LASERBEAM_GLITCHED = "/Game/Particles/Materials/M_LaserBeam_Glitched.M_LaserBeam_Glitched",
    
    

    -- ** The mushroom skink's spore ball in flight (the visible body of Projectile_BioBall_Healing).
    -- Tried as a PROJ TrailFX on the Abjurer's bolt and it drew NOTHING, on the host included -
    -- the system is authored for that projectile's own component and does not stand up as a
    -- welded-on trail. Use a row whose mesh IS the projectile instead.
    -- SKINK_SPORE_PROJECTILE = "/Game/Particles/Niagara_MushroomSkink_Spores_Projectile.Niagara_MushroomSkink_Spores_Projectile",

    -- ** Mushroom Skink projectile - had stability issues with these when testing Acidic Exor
    -- SKINK_SPORE_IMPACT    = "/Game/Particles/Niagara_MushroomSkink_Healing_Impact.Niagara_MushroomSkink_Healing_Impact",
    -- SKINK_SPORE_EXPLOSION = "/Game/Particles/Niagara_MushroomSkink_Spores_Explosion.Niagara_MushroomSkink_Spores_Explosion",
    -- SKINK_SPORE_MUTED     = "/Game/Particles/Niagara_MushroomSkink_Healing_Impact_Muted.Niagara_MushroomSkink_Healing_Impact_Muted",
    
    -- ** Don't spawn detached, it carries a SkeletalMesh interface and can cause a freeze
    -- REAPER_SHADOWMELD = "/Game/Particles/Niagara_Reaper_ShadowMeld.Niagara_Reaper_ShadowMeld",

    -- SPARKS2 = "/Game/Particles/Niagara_Sparks_02.Niagara_Sparks_02",
    -- SPARKS3 = "/Game/Particles/Niagara_Sparks_03.Niagara_Sparks_03",
    -- LIGHT_MATERIAL_GREEN = "/Game/Models/FX/M_EV_Lightbeam_Green.M_EV_Lightbeam_Green",
    -- ROTTEN_FOOD = "/Game/Particles/Niagara_Stench_RottenFood.Niagara_Stench_RottenFood",
    -- ROBOT_SHATTER_SPARKS = "/Game/Particles/Niagara_Security_Robot_Shatter.Niagara_Security_Robot_Shatter",
    -- DIOX_HEALING = "/Game/Particles/Niagara_Dioxohealer_Player.Niagara_Dioxohealer_Player",
    -- DIOX_ACTIVE = "/Game/Particles/Niagara_Dioxohealer_Active.Niagara_Dioxohealer_Active",
    -- FIRE_SMALL_2 = "/Game/Realistic_Starter_VFX_Pack_Niagara/Niagara/Fire/NS_Fire_Small_2.NS_Fire_Small_2",
    -- FIRE_SMALL_3 = "/Game/Realistic_Starter_VFX_Pack_Niagara/Niagara/Fire/NS_Fire_Small_3.NS_Fire_Small_3",
    -- EXOR_GOO_SPLASH = "/Game/Particles/Niagara_ExorGoo_Splash.Niagara_ExorGoo_Splash",
    -- BLOOD_GIB_ALIEN = "/Game/Particles/Niagara_Blood_Gib_Alien.Niagara_Blood_Gib_Alien",
    -- LAVA_SPLASH = "/Game/Particles/Niagara_Splash_AnteverseLava.Niagara_Splash_AnteverseLava",
    -- FIREFLIES = "/Game/Particles/Niagara_Environment_Fireflies.Niagara_Environment_Fireflies",
    -- CAULDRON_BUBBLES = "/Game/Particles/Niagara_Cauldron_Bubbles.Niagara_Cauldron_Bubbles",
    -- CHARGING_STATION_LINES = "/Game/Particles/Niagara_ChargingStation_Lines.Niagara_ChargingStation_Lines",
    -- BLACKFOG_WEATHER = "/Game/Particles/Niagara_Weather_BlackFog.Niagara_Weather_BlackFog",
    -- STUNBATON_IMPACT = "/Game/Particles/Niagara_StunBaton_Impact.Niagara_StunBaton_Impact",
    -- FIRE_BIG_1 = "/Game/Realistic_Starter_VFX_Pack_Niagara/Niagara/Fire/NS_Fire_Big_1.NS_Fire_Big_1",
    -- FOG_TEST     = "/Game/Particles/Niagara_Weather_DarkFusionDust.Niagara_Weather_DarkFusionDust",
    -- LIGHTNING_TESLA = "/Game/Particles/Niagara_Electricity_TeslaCoil.Niagara_Electricity_TeslaCoil",
    -- BLUE_PARTICLE_RISER = "/Game/Particles/Niagara_BlueParticleRiser.Niagara_BlueParticleRiser",
    -- LIGHTNING_ELECTROPEST = "/Game/Particles/Niagara_ElectroHopper_Electricity.Niagara_ElectroHopper_Electricity",

}

-- Utils.CreateEffect - accepts SoundWaves
-- SpawnSoundAtLocation / Broadcast_Play3DSoundEffect - can accept cues
AnteEnums.SOUNDS = {
    -- Both LOOPING SoundWaves; the ClientFX receiver stops + frees the component itself.
    -- SALEM is the GK portal's hum now. Shadowgate is kept as the louder alternative -
    -- its row carries Volume 10, Salem's carries none (= 1.0), so this is a big drop in level.
    PORTAL_SALEM = "/Game/Audio/Environment/Portals/S_Salem_PortalLoop.S_Salem_PortalLoop",
    PORTAL_SHADOWGATE = "/Game/Audio/Environment/Portals/S_Portal_Shadowgate_Loop.S_Portal_Shadowgate_Loop",
    PORTAL_EXIT = "/Game/Audio/Environment/Portals/S_Portal_Exit_3rdPerson_2.S_Portal_Exit_3rdPerson_2",
    PORTAL_NIGHTREALM_OPEN = "/Game/Audio/Environment/Portals/s_portal_nightrealm_open.s_portal_nightrealm_open",

    -- ULaserComponent's two LOOPING beam sounds - ToggleSounds SpawnSoundAttached-es both the
    -- moment a beam activates. Part of Lasers.BURST_ASSETS; see its banner.
    LASER_EMIT_LOOP     = "/Game/Audio/Equipment/Lasers/s_laser_emit_loop.s_laser_emit_loop",
    LASER_HIT_HISS_LOOP = "/Game/Audio/Equipment/Lasers/s_laser_hit_hiss_loop.s_laser_hit_hiss_loop",

    -- The DarkLens Mage's unseal line: OnRep_DarkLensCombatReady soft-loads + speaks it, and a
    -- scripted unseal (GK_DarkLensMageHelpers) fires that OnRep from the WorkQueue drain - warm it.
    GKMAGE_DL_AGGRO = "/Game/Audio/Monsters/GatekeeperMage/s_GKMage_DarkLens_Aggro_01_Dialogue.s_GKMage_DarkLens_Aggro_01_Dialogue",

    -- The DarkLens Magus' astral-hold call: played FLAT (AVU.PlaySound2DAll) for every player as
    -- each Astral Magus is summoned, the same UI channel the assault stings use.
    --   *** THE BARE SoundWave, NOT the `_Dialogue` sibling *** (see MAGE_NARRATIVE below):
    --   `_Dialogue` is a UDialogueWave, not a USoundBase, and Client_Play2DSoundEffect takes a
    --   USoundBase. 4.97s, SoundClass Abiotic_Dialog_NPC.
    GKMAGE_DL_ASTRAL = "/Game/Audio/Monsters/GatekeeperMage/BossFight/s_GK_Mage_BossFight_05.s_GK_Mage_BossFight_05",

    -- The Fallow Patriarch's phase-2 call: the barrier permabreaks, it comes off the perch, and
    -- this plays FLAT for every player (AVU.PlaySound2DAll). Same BARE-SoundWave rule as above.
    -- 2.13s, SoundClass Abiotic_Dialog_NPC.
    GKCHIEF_DL_PHASE2 = "/Game/Audio/Monsters/GatekeeperChieftain/s_GKChief_AllyDeath_03.s_GKChief_AllyDeath_03",

    -- The Jotun of the Fallow's PHASE-2 STING, played 2D on the announcement channel
    -- (AVU.PlaySound2DAll) the moment its steed drops and the barrier shatters - the same channel
    -- the AI Director uses for assault stings and the Night Realm portal.
    --   * The BARE SoundWave (verified USoundWave, so Client_Play2DSoundEffect binds it) - the
    --     `_Dialogue` siblings in this folder are UDialogueWaves and are NOT USoundBase.
    GKHEAVY_GRENADE_03 = "/Game/Audio/Monsters/GatekeeperHeavy/GKHeavy/s_GKHeavy_Grenade_03.s_GKHeavy_Grenade_03",

    -- Gatekeeper Chieftain idle barks (ModuleBobbleheads picks one per bobble).
    -- Listed, not generated: a loop hides the real asset names from grep and from the /pins dump.
    GKCHIEF_IDLE = {
        "/Game/Audio/Monsters/GatekeeperChieftain/s_GKChief_Idle_01.s_GKChief_Idle_01",
        "/Game/Audio/Monsters/GatekeeperChieftain/s_GKChief_Idle_02.s_GKChief_Idle_02",
        "/Game/Audio/Monsters/GatekeeperChieftain/s_GKChief_Idle_03.s_GKChief_Idle_03",
        "/Game/Audio/Monsters/GatekeeperChieftain/s_GKChief_Idle_04.s_GKChief_Idle_04",
        "/Game/Audio/Monsters/GatekeeperChieftain/s_GKChief_Idle_05.s_GKChief_Idle_05",
        "/Game/Audio/Monsters/GatekeeperChieftain/s_GKChief_Idle_06.s_GKChief_Idle_06",
        "/Game/Audio/Monsters/GatekeeperChieftain/s_GKChief_Idle_07.s_GKChief_Idle_07",
    },

    -- Mystagogue lines, for the `mystagogue` bobblehead's poke bark. These are NARRATIVE dialogue
    -- (the friendly Mage's "you came back" greetings from three story chapters), picked because the
    -- Mystagogue has no idle-bark set of its own - the combat Mage only ever shouts.
    --   *** THE BARE SoundWave, NOT THE `_Dialogue` SIBLING. *** Every one of these ships twice:
    --   `<name>` is the USoundWave and `<name>_Dialogue` is a UDialogueWave, which is NOT a
    --   USoundBase and cannot be handed to PlaySoundAtLocation. (GKMAGE_DL_AGGRO above legitimately
    --   names a `_Dialogue` asset - that one is the game's own soft-ref, played by native code.)
    --   Directory case is the export's: END and PREWALL are upper, the MAGE folder too.
    MAGE_NARRATIVE = {
        "/Game/Audio/NarrativeNPCs/MAGE/END/Res_End__Mage_Return_01.Res_End__Mage_Return_01",
        "/Game/Audio/NarrativeNPCs/MAGE/END/Res_Boss_Mage_Return_03.Res_Boss_Mage_Return_03",
        "/Game/Audio/NarrativeNPCs/MAGE/END/Res_Boss_Mage_Return_01.Res_Boss_Mage_Return_01",
        "/Game/Audio/NarrativeNPCs/MAGE/PREWALL/Res_PreWall__Mage_Return_02.Res_PreWall__Mage_Return_02",
    },

    TELEPORT_GENERIC = "/Game/Audio/Actions/teleport_generic_Cue.teleport_generic_Cue",
    SABER_DEFLECT = "/Game/Audio/Melee/Hardlight_Saber/Hardlight_Saber_Deflect_Cue.Hardlight_Saber_Deflect_Cue",
    MORTAR_FIRE = "/Game/Audio/Monsters/SecurityBot/DefenseBot_Mortar_Fire_Cue.DefenseBot_Mortar_Fire_Cue", 
    HELMET_POPOFF = "/Game/Audio/Impact/helmet_popoff_Cue.helmet_popoff_Cue",
    RADIO_GK_START = "/Game/Audio/Monsters/Grunt/GKRadio/GateKeeper_RadioChirp_Cue.GateKeeper_RadioChirp_Cue",
    -- The plain loop, NOT the _overdrive variant (swapped 2026-08-13: the overdrive reads harsh
    -- on the Deatomizer sweep and the Magus eye beam, the two users of this key).
    HEAVY_LASER_FIRE = "/Game/Audio/Guns/HeavyLaser/s_heavylaser_fire_loop.s_heavylaser_fire_loop",
    GROUPE_RIFLE_FIRE = "/Game/Audio/Guns/GroupeRifle/grouperifle_U1_fire_Cue.grouperifle_U1_fire_Cue",
    -- The laser grenade's three cues: the worble it hums while armed, its bounce, and the
    -- turret-fire cue each of its eight beams opens with.
    LASER_NADE_LOOP = "/Game/Audio/Grenades/Holy/s_lode_grenade_worble_loop.s_lode_grenade_worble_loop",
    LASER_NADE_BOUNCE = "/Game/Audio/Grenades/NullGrenade/S_NullGrenade_Bounce_Cue.S_NullGrenade_Bounce_Cue",
    LASER_TURRET_FIRE = "/Game/Audio/Guns/LaserTurret/s_laserturret_fire.s_laserturret_fire",
    BIOCANNON_FIRE = "/Game/Audio/Guns/BioCannon/S_Skink_WeaponSound.S_Skink_WeaponSound",
    STALACTITE_BREAK = "/Game/Audio/Environment/Glass/Stalactite_Break_Cue.Stalactite_Break_Cue",
    AIR_POOF = "/Game/Audio/Impact/Flasks/S_Air_Poof_1.S_Air_Poof_1",
    ELECTROTHROWER_FIRE = "/Game/Audio/Guns/ElectroThrower/ElectroThrowerFire_Cue.ElectroThrowerFire_Cue",
    EXOR_FIRE = "/Game/Audio/Monsters/Exor/Exor_Fire_Cue.Exor_Fire_Cue",
    EXOR_VOLATILE_LEAP = "/Game/Audio/Monsters/Exor_Volatile/S_Exor_Volatile_Leap.S_Exor_Volatile_Leap",
    SHOTGUN_MILITARY_FIRE = "/Game/Audio/Guns/Shotgun_Military/Shotgun_Military_Fire_Cue.Shotgun_Military_Fire_Cue",
    SNIPER_FIRE = "/Game/Audio/Guns/SniperRifle_Military/Sniper_Military_Fire_Cue.Sniper_Military_Fire_Cue",
    DISC_LAUNCHER_FIRE = "/Game/Audio/Guns/DiscLauncher/s_disclauncher_fire.s_disclauncher_fire",
    SNIPER_BOLTRACK = "/Game/Audio/Guns/SniperRifle_Military/SniperNPC_Boltrack_Cue.SniperNPC_Boltrack_Cue",
    SMG_U1_FIRE = "/Game/Audio/Guns/SMG_Military/SMG_U1_Fire_Cue.SMG_U1_Fire_Cue",
    BOT_SPARK = "/Game/Audio/Monsters/SecurityBot/Bot_Spark_Cue.Bot_Spark_Cue",
    BOT_POWERDOWN = "/Game/Audio/Monsters/SecurityBot/Bot_Voice_PowerDown.Bot_Voice_PowerDown",   -- 4.8s wave

    -- Assault sound effects
    ASSAULT_WARN_START = "/Game/Audio/Music/ShortStings/anteverse_sting.anteverse_sting",
    ASSAULT_STING_HORROR     = "/Game/Audio/Music/ShortStings/s_assault_horror1_sting.s_assault_horror1_sting",
    ASSAULT_STING_MYSTERIOUS = "/Game/Audio/Music/ShortStings/s_assault_mysterious_sting.s_assault_mysterious_sting",
    ASSAULT_STING_ELECTRO    = "/Game/Audio/Music/ShortStings/s_assault_electro_sting.s_assault_electro_sting",
    ASSAULT_STING_END        = "/Game/Audio/Music/ShortStings/s_assault_end_sting.s_assault_end_sting",
}

-- =======================================================================
-- VOICE-CLASS REPAIR (ModuleAudioFix) - shipped waves whose SoundClassObject is empty.
--
-- Every volume slider in the game is a SoundVolumeChange on a class under Abiotic_Master, so a
-- wave with no class sits outside the tree and NO slider reaches it: it plays at a flat 1.0 while
-- the rest of the mix is scaled. The NPC voice path makes that audible - Local_Play_DialogSpeak
-- does a bare SetSound + Play on CharacterVoiceAudio, which overrides attenuation but not the
-- class, so the wave's own field is the only thing deciding.
--
-- These ten are the Grunt / Groupe_Generic NeedCover + SeekingCover barks, and they are the ONLY
-- unclassed voice lines in DT_NPCVoices. Their 196 folder-mates all carry Abiotic_Dialog, which is
-- what the repair assigns.
-- =======================================================================
AnteEnums.VoiceFix = {
    SoundClass = "/Game/Audio/Abiotic_Dialog.Abiotic_Dialog",

    Unclassed = {
        "/Game/Audio/Monsters/Grunt/Grunt_Mad_New/s_grunt_mad_cover-01.s_grunt_mad_cover-01",
        "/Game/Audio/Monsters/Grunt/Grunt_Mad_New/s_grunt_mad_cover-02.s_grunt_mad_cover-02",
        "/Game/Audio/Monsters/Grunt/Grunt_Mad_New/s_grunt_mad_cover-03.s_grunt_mad_cover-03",
        "/Game/Audio/Monsters/Grunt/Grunt_Mad_New/s_grunt_mad_cover-04.s_grunt_mad_cover-04",
        "/Game/Audio/Monsters/Grunt/Grunt_Mad_New/s_grunt_mad_cover-05.s_grunt_mad_cover-05",
        "/Game/Audio/Monsters/Grunt/Grunt_Mad_New/s_grunt_mad_cover-06.s_grunt_mad_cover-06",
        "/Game/Audio/Monsters/Grunt/Grunt_Mad_New/s_grunt_mad_cover-07.s_grunt_mad_cover-07",
        "/Game/Audio/Monsters/Grunt/Grunt_Mad_New/s_grunt_mad_cover-08.s_grunt_mad_cover-08",
        "/Game/Audio/Monsters/Grunt/Grunt_Mad_New/s_grunt_mad_cover-09.s_grunt_mad_cover-09",
        "/Game/Audio/Monsters/Grunt/Grunt_Mad_New/s_grunt_mad_cover-10.s_grunt_mad_cover-10",
    },
}

-- =======================================================================
-- CLIENT-FX REGISTRY - effects the server asks every renderer to play LOCALLY, over the chat
-- side-channel (AVU.SendClientFX -> AnteVariants/ClientEffects). Ported from EnemyAtTheGATE.
--
-- *** APPEND ONLY. THE ARRAY INDEX IS THE WIRE FORMAT. ***
-- Inserting or deleting renumbers every later entry, which silently repoints live effects on any
-- client running a different build.
--
-- Why this channel: it is the only one that can run a LOOPING effect on clients. A replicated FX
-- actor can't carry a custom Niagara; BroadcastFX can, but spawns bAutoDestroy, which never fires
-- for a loop. Here each machine owns and frees its own component, so loops get a real lifetime.
--
-- ENTRY KEYS
--   FX / Sound / Scale  the system, an optional sound, and the spawn scale
--   Beam = true         drawn location -> a second point (rides MessageColor.G/B/A as XYZ);
--                       BeamParam names the Vector3 USER param. A beam carries no yaw.
--                       Otherwise the entry is a POINT and MessageColor.G carries a YAW.
--   OneShot = true      fire-and-forget: never STOP'd, never heartbeat re-armed, so ClientEffects
--                       skips the liveFX book. REQUIRED on anything combat-spammed - every book
--                       touch is a full UObject-array scan (25-30ms, and the crash surface in
--                       [[anteup2-ue4ss-findobject-scan-crash]]). Omit only for a key an event
--                       holds open or closes explicitly (the portals/doors below).
--   ZOffset             vertical shift; senders send capsule CENTRE, ground FX want feet
--   Drift               uu of forward travel over the effect's lifetime (see GK_PORTAL)
--   NoCull = <uu>|true  override the engine's distance cull: a NUMBER renders the effect out to
--                       that many uu (10000 = 100m), `true` is uncapped. Without it a portal blinks
--                       out around 50m - the engine deactivates a Niagara past its effect type's
--                       MaxDistance, and the two the game ships are Portal_Far (8000/4000/1000 uu
--                       by quality level) and Standard (4000/2000/1000), the latter also being the
--                       fallback for a system with NO effect type (Portal_BurstOnce, Rift_BlueFade).
--                       PREFER A NUMBER. Uncapped also drops the visibility cull, so the system
--                       ticks and draws for its whole Lifetime with nobody looking; a number keeps
--                       a real cutoff, just one we chose. Either way the cost scales with LIFETIME
--                       x COUNT, not with OneShot-ness - so this belongs on held-open set pieces,
--                       not on arrival pops or combat effects. (ClientFX.lua)
--   Float/Vec2/Vec3/ColorParams   USER params, set before the resetting Activate
--   Dilation            playback speed (0.5 = half). The only channel that can pace an effect -
--                       BroadcastFX hands back no component. Give a slowed entry a longer lifetime.
-- =======================================================================
AnteEnums.ClientFX = {
    -- The GK rift. DRIFTS: it starts Drift/2 AHEAD of the sent point and slides Drift/2 BEHIND it
    -- over its lifetime, so it reads as a warp gate advancing on whatever it faces rather than a
    -- decal on the air. "Forward" is the entry's yaw, i.e. straight through the plane's own face,
    -- so a doorway aimed at a player travels TOWARDS them.
    --   * Per-send override: AVU.SendClientFX(loc, key, secs, yaw, drift). 0 pins it still.
    { Key = "GK_PORTAL",
      FX = AnteEnums.Effects.PORTAL_DOOR,      -- hard-looping: only usable on THIS channel
      Sound = AnteEnums.SOUNDS.PORTAL_SALEM,   -- looping too; the client stops + frees it
      NoCull = 10000,                          -- 100m; a warp gate you can only see from 50m is no tell
      Drift = 100,                             -- 50uu ahead -> 50uu behind (same lifetime, so a
                                               --   bigger number is simply a FASTER slide)
      Scale = FVector(1.2, 1.2, 1.2) },

    -- The Exor tether
    { Key = "EXOR_BEAM",
      FX = AnteEnums.Effects.EXOR_BEAM,
      Beam = true, OneShot = true,
      BeamParam = "User.BeamEnd",   -- FULL name: SetNiagaraVariableVec3 misses on a bare "BeamEnd"
      Scale = FVector(1, 1, 1) },

    -- The Exor tether
    { Key = "EXOR_BEAM_CHA",
      FX = AnteEnums.Effects.EXOR_BEAM_CHA,
      Beam = true, OneShot = true,
      BeamParam = "User.BeamEnd",   -- FULL name: SetNiagaraVariableVec3 misses on a bare "BeamEnd"
      Scale = FVector(1, 1, 1) },

    -- The Abjurer's support tether. Beam width and glow are the system's own authored defaults;
    -- "User.Beam Width" / "User.Radius" are the knobs if it ever reads wrong.
    { Key = "MAGEEYE_BEAM_ALLY",
      FX = AnteEnums.Effects.MAGEEYE_BEAM_ALLY,
      Beam = true, OneShot = true,
      BeamParam = "User.Beam End",   -- the SPACE is real; this family does not spell it "BeamEnd"
      Scale = FVector(1, 1, 1) },

    -- The pop on the body the Abjurer's beam lands on - sent at the RECIPIENT, not the caster.
    { Key = "SHIELD_REGEN",
      FX = AnteEnums.Effects.SHIELD_REGEN_HOLY,
      OneShot = true,
      Scale = FVector(1, 1, 1) },

    -- MESH OPCODE (def.Mesh + def.Wall): no Niagara. Builds the Abjurer's lent front plate on the
    -- live NPC nearest the sent point, for `secs`. Same addressing as OUTLINE below - the sender
    -- sends the wearer's own location, so the radius only has to beat replication lag.
    --   * A runtime-added component does NOT replicate, which is the whole reason this is a
    --     channel entry: every renderer has to build its own copy. The BLOCK is decided
    --     server-side from two transforms, so a client that mis-picks in a crowd draws the plate
    --     on the wrong body for a few seconds and nothing else diverges.
    --   * `Mesh` (rather than FX) is also what puts the path in ClientEffects' keep-warm sweep.
    { Key = "SHIELD_WALL",
      Mesh = AnteEnums.Components.SM_SHIELD_MAGE,
      Wall = true, WallRadius = 200 },

    -- THE HIVE SOW'S BEE CLOUD, pushed by the SOW itself when it spawns a cloud, so only the Hive
    -- Sow's clouds get bees. The params below recolour the spore puff toward neon.
    --   * Why pushed, not scanned: the old ClientEffects scan decorated ANY
    --     AreaEffect_MushroomSporeCloud_Peccary, so a plain Peccary's shake grew a swarm too - and
    --     it cost a whole-UObject-array FindAllOf every 800ms per renderer
    --     ([[anteup2-microlag-and-profiler]]).
    --   * The stock puff is a dark translucent ORANGE that blends into the floor, and
    --     SPORES_PECCARY_SHAKE has no Color param - only HSV-shift USER params (Vector2f ranges).
    --   * HueShiftRange is the rotation (units ~= degrees; base orange ~30, so +50 -> yellow-green)
    --   * AlphaScaleRange is the anti-blend fix; Value/Saturation give it the neon pop.
    { Key = "HIVE_SPORES",
      FX = AnteEnums.Effects.SPORES_PECCARY_SHAKE,
      OneShot = true,
      Scale = FVector(2.5, 2.5, 2.5),
      Vec2Params = {
          HueShiftRange   = { X = 50,  Y = 50 },   -- orange -> neon yellow-green
          SaturationRange = { X = 1.5, Y = 1.5 },
          ValueRange      = { X = 1.4, Y = 1.4 },
          AlphaScaleRange = { X = 1.6, Y = 1.6 },
      } },

    -- The bees themselves. Stock Niagara_BeeAttackSwarm is small dark specks that vanish against a
    -- dim floor, so the cloud reads as "nothing is happening" until the stings land.
    --   * SIZE is deliberately NOT the lever (still Scale 2): a bigger translucent swarm is just
    --     overdraw. Colour is what makes it legible.
    --   * The params below are a PROBE, not a verified recipe - there is no FModel export of this
    --     system on disk, so its exposed USER params are unknown. Every setter is pcall'd and
    --     resolves by name, so a name this system does not have costs nothing and changes nothing.
    --     Vec2 HSV first because that is the shared-module spelling HIVE_SPORES above is already
    --     driven by. ColorParams is OFF-LIMITS (const-ref crash - see the note under this entry).
    --   * IF NOTHING CHANGES IN GAME, that is the "wrong param name" answer, not "colour cannot be
    --     done" - probe one name at a time (see the ColorParams note in ClientFX.SpawnLocalNiagara).
    { Key = "HIVE_BEES",
      FX = AnteEnums.Effects.BEE_SWARM,
      OneShot = true,
      Scale = FVector(2, 2, 2),
      Vec2Params = {
          HueShiftRange   = { X = 45,  Y = 45 },    -- toward acid yellow-green
          SaturationRange = { X = 1.6, Y = 1.6 },
          ValueRange      = { X = 1.8, Y = 1.8 },   -- the main "pops off the floor" term
          AlphaScaleRange = { X = 1.5, Y = 1.5 },
      } },
      -- ColorParams REMOVED 2026-08-10: it fed a plain FLinearColor TABLE to
      -- SetVariableLinearColor, whose value param is `const FLinearColor&` - a CONST-REF struct
      -- param, and on this UE4SS build the ref-param push-back derefs a table as a null userdata
      -- = uncatchable AV @0x70. The FIRST bee cloud of every session crashed the game
      -- (AVCrash-WinterfectorWitch1-4). The laser precedent (SetColorParameter) is BY-VALUE,
      -- which is why it works. If a direct colour is ever wanted here, route it through the
      -- by-value UFXSystemComponent:SetColorParameter instead. See [[ue4ss-const-ref-struct-param-av]].


    -- These FX may be crash prone
    -- { Key = "ACID_SPORE",
    --   FX = AnteEnums.Effects.SKINK_SPORE_EXPLOSION,
    --   Scale = FVector(2.5, 2.5, 2.5),
    --   FloatParams = { Charge = 1.0 } },

    -- { Key = "ACID_SPORE_BIG",   -- the self-destruct
    --   FX = AnteEnums.Effects.SKINK_SPORE_EXPLOSION,
    --   Scale = FVector(5, 5, 5),
    --   FloatParams = { Charge = 1.0 } },

    -- CHAIN LIGHTNING. The game has NO chain-lightning projectile; these are the two systems the
    -- native users draw it with - a beam per victim, plus a burst at each end.
    --   * Both native users (the TechSpear, NPC_Monster_Peccary_Electro) hand-roll it as a
    --     SphereOverlap fan from ONE origin with a separate beam per victim - not a chain at all.
    { Key = "TECH_LIGHTNING",
      FX = AnteEnums.Effects.TECHSPEAR_BEAM,
      Beam = true, OneShot = true,
      BeamParam = "User.BeamEnd",   -- FULL name: SetNiagaraVariableVec3 misses on a bare "BeamEnd"
      Scale = FVector(1, 1, 1) },

    { Key = "TECH_ZAP",
      FX = AnteEnums.Effects.TECHSPEAR_IMPACT,
      OneShot = true,
      Scale = FVector(1.4, 1.4, 1.4) },

    -- The Displacer/Dislocator swap-bomb windup marker. This channel spawns the real system on
    -- every renderer, host included.
    --   * Was Utils.CreateEffect(EXOR_CHARGEUP), but ReplicatedParticleFX's ParticleEffect does NOT
    --     replicate - every remote client played the BP's DEFAULT portal open/close (2026-07-22).
    { Key = "EXOR_CHARGE",
      FX = AnteEnums.Effects.EXOR_CHARGEUP,
      OneShot = true,
      Scale = FVector(2, 2, 2) },

    -- 2026-07-22 CreateEffect migration, continued (same non-replicating ParticleEffect bug as
    -- EXOR_CHARGE above): the Wraith aim telegraph, the Sentinel<->Wraith connect zap, the Wraith
    -- vanish rift, and the Reaper-flavored shadow meld (Phase Peccary + Shades).
    { Key = "EXOR_CHARGE_CHA",
      FX = AnteEnums.Effects.EXOR_CHARGEUP_CHA,
      OneShot = true,
      Scale = FVector(1, 1, 1) },

    { Key = "LIGHTNING_BURST",
      FX = AnteEnums.Effects.LIGHTNING_ELECTRICDAM,
      OneShot = true,
      Scale = FVector(1, 1, 1) },

    { Key = "PORTAL_RIFT",
      FX = AnteEnums.Effects.PORTAL_RIFT_BLUEFADE,
      OneShot = true,
      NoCull = 10000,  -- 100m. EffectType-less system -> the 4000/2000 Standard fallback; a storm rift
                       -- across the arena has to be visible from across the arena
      Scale = FVector(1, 1, 1) },

    -- OneShot is what killed the 256-309ms book walks this key paid per Shade meld during
    -- Event_INQ_Command (the 2026-08-05 AVCrash log). FX swapped 08-05 from REAPER_SHADOWMELD
    -- (detached = invalid-mesh DI, see its Effects entry) to the panic flask's ground smoke;
    -- ZOffset drops the burst from the sent capsule-center to FEET, where a ground effect reads.
    { Key = "REAPER_MELD",
      FX = AnteEnums.Effects.FLASK_PHEROMONE_IMPACT,
      OneShot = true,
      ZOffset = -85,
      Scale = FVector(1, 1, 1) },

    -- The Storm Witch's takeoff pulse: the Electrifying tincture's retaliation nova, scaled up to
    -- read as an AoE tell (the native burst plays at 1.0 attached to a body; ours is a point burst).
    { Key = "ELECTRIC_NOVA",
      FX = AnteEnums.Effects.TINCTURE_ELECTRIC_BURST,
      OneShot = true,
      Scale = FVector(2.5, 2.5, 2.5) },

    -- THE NIGHT REALM DOOR (Event_INQ_NightRealm), as a PAIR over one Niagara - and the pair is the
    -- whole point.
    --   * Every send on this channel has a FINITE lifetime (the client spawns a component and frees
    --     it `seconds` later), so a door that hangs open is held by a HEARTBEAT, re-sent before the
    --     last one expires.
    --   * The beat's entry must therefore be SILENT, or every beat would re-fire the open sting.
    --   * Closing is a real STOP (AVU.StopClientFX), keyed on the NIAGARA - either key closes both.
    --   * Neither passes a Yaw: it's a vertical tear, not the GK plane.
    { Key = "NIGHTREALM_OPEN",           -- sent ONCE, at open: door + the sting
      FX = AnteEnums.Effects.PORTAL_NIGHTREALM,
      Sound = AnteEnums.SOUNDS.PORTAL_NIGHTREALM_OPEN,
      NoCull = 10000,                    -- 100m, BOTH halves - or the heartbeat re-spawns a culled door
      Scale = FVector(1, 1, 1) },

    { Key = "NIGHTREALM_DOOR",           -- the silent heartbeat that holds it open
      FX = AnteEnums.Effects.PORTAL_NIGHTREALM,
      NoCull = 10000,
      Scale = FVector(1, 1, 1) },

    -- [UNUSED - kept for INDEX STABILITY; this registry is append-only, see the header]
    -- Was the Cinderlord's muzzle pilot light, telegraphing the next burst. Scrapped with the whole
    -- scripted charge cycle (AnNotes/AnteNPCs/OrderFlameRat.md).
    { Key = "CINDER_CHARGE",
      FX = AnteEnums.Effects.CAMPFIRE_BASIC,
      Scale = FVector(2.5, 2.5, 3.5) },

    -- [UNUSED - kept for INDEX STABILITY; this registry is append-only, see the header]
    -- Was the Cinderlord's far fire lane, replaced by real AreaEffect_MolotovBurn_Holy patches
    -- (AVU.SpawnCloud in AnteNPCs/OrderFlameRat.lua clFlameLane).
    --   * A magma-explosion burst read wrong next to the projectile's own patches and outlived each
    --     burst by 5+ seconds.
    --   * A real replicated actor costs no client-FX pushes at all.
    { Key = "CINDER_LANE",
      FX = AnteEnums.Effects.MAGMAPEST_EXPLOSION,
      Scale = FVector(2, 2, 2) },

    -- SOUND-ONLY (no FX): the Night Realm door's open sting on its own, so a set-piece can
    -- TELEGRAPH the tear a beat before the doorway is drawn.
    --   * NIGHTREALM_OPEN carries the same sting, but it also draws a door - it can't warn without
    --     opening one, and sending it twice re-stings.
    --   * A sound-only entry is legal on this channel: ClientEffects skips the Niagara half when
    --     an entry has no FX. It also has no STOP (the stop opcode keys off the entry's NIAGARA).
    --     *** That was only true in principle until 2026-08-05: the decoder ALSO required a def.FX
    --     and dropped every sound-only push before playback, so this entry had never once played,
    --     anywhere, silently. Fixed in the decoder. ***
    --   * Sound2D = played AT each listener, not at the sent location. The portal cues are authored
    --     with close attenuation, so positionally this was INAUDIBLE from across the hall (field,
    --     2026-08-04) - and a "the realm is tearing open" telegraph has to land whether or not you
    --     are standing at the door. Still per-renderer, so clients hear it too (unlike
    --     EVU.PlayAnnouncement, which is host/SP-local).
    --   * [CURRENTLY UNUSED - kept for INDEX STABILITY, and as the worked example of a sound-only
    --     entry.] Its one caller (Event_INQ_Command's opening cue) moved to AVU.PlaySound2DAll:
    --     for a pure announcement the game's own Client_Play2DSoundEffect RPC beats this channel
    --     outright - the sound reference travels ON THE WIRE, so a client that doesn't happen to
    --     have the asset resident still plays it, where this path renders silence.
    { Key = "NIGHTREALM_STING",
      Sound = AnteEnums.SOUNDS.PORTAL_NIGHTREALM_OPEN,
      Sound2D = true },

    -- [CURRENTLY UNUSED - kept for INDEX STABILITY.] AVU.FrostCone drew its cone through this
    -- entry until Niagara_Snowman_FrostSpray turned out to render NOTHING for us - world-spawned
    -- here, and attached to a muzzle socket with the Snowman's own relative rotation. See the
    -- FrostCone header for both negative results; the cone is a line of snow bursts now.
    { Key = "FROST_CONE",
      FX = AnteEnums.Effects.NIAGARA_SNOWMAN_SPRAY,
      Scale = FVector(1.6, 1.6, 1.6) },

    -- THE RAT PORTAL (AVU.PortalArrival) - the yellow teleporter-pad ring one NPC steps out of.
    -- Assumed LOOPING, so it can only live on this channel; its `seconds` lifetime is what closes
    -- it (no STOP, no heartbeat - see OneShot).
    --   * OneShot: this fires off a SPAWNER, i.e. potentially several a minute in a busy zone, and
    --     it is never STOP'd or re-armed. Skipping the liveFX book skips a full UObject-array scan
    --     per push ([[anteup2-ue4ss-findobject-scan-crash]]). The Lifetime teardown still owns and
    --     frees the component, which is what a looping system actually needs.
    --   * ZOffset: +25, DIALLED IN IN-GAME (`/clientfx PORTAL_YELLOW 6 0 25`, 2026-08-08) - do not
    --     "correct" it by reasoning about the asset. This doorway is LIFTED, not dropped to the
    --     feet: senders send capsule CENTRE (~88 above the floor) and the system emits below its
    --     own origin, so REAPER_MELD's ground-effect -85 buried it. Re-trial with
    --     `/clientfx PORTAL_YELLOW 6 0 <z>` (which overrides this without a restart); the value
    --     here is registry data, so changing it needs a real restart.
    --   * Sound = the game's own 3rd-person portal-exit sting (a one-shot; the component is freed
    --     with the visual either way).
    -- NO NoCull, deliberately: this is the per-ARRIVAL ring (Rocket Rat / Mad Rat step-outs), not a
    -- set piece, and it is spawn-and-forget. It is also the entry that exposed what exempting a
    -- LOOPING system costs - see the teardown's hard-free branch. Range visibility is worth nothing
    -- on a ring that exists to announce a body appearing next to you. The GATE version of this same
    -- Niagara (PORTAL_YELLOW_HOLD, below) is the one that gets it.
    { Key = "PORTAL_YELLOW",
      FX = AnteEnums.Effects.PORTAL_FRIENDLY_YELLOW,
      Sound = AnteEnums.SOUNDS.PORTAL_EXIT,
      OneShot = true,
      ZOffset = 25,
      Scale = FVector(1, 1, 1) },

    -- The STEP-OUT cue, fired ~0.4s after the doorway opens, when the arriving body actually
    -- appears (AVU.PortalArrival's emerge beat). A separate entry purely because it is a separate
    -- MOMENT - the entry above sings when the door tears, this one when something comes through.
    --   * SOUND-ONLY and POSITIONAL: no FX (ClientEffects skips the Niagara half) and no Sound2D,
    --     so it goes out through SpawnSoundAtLocation and carries the cue's own attenuation. That
    --     is right here - unlike an event telegraph, a body stepping out is a thing you should
    --     have to be near to hear.
    --   * If the two cues muddy each other, drop `Sound` from PORTAL_YELLOW rather than this one.
    { Key = "PORTAL_YELLOW_EMERGE",
      Sound = AnteEnums.SOUNDS.TELEPORT_GENERIC },

    -- Fallow Patriarch sniper (GK_DarkLens): AIM = the silent telegraph streak drawn to the
    -- target 1s before the shot; SHOT = the same tracer + the rifle report at fire time.
    -- Both beams (SendClientBeam), both OneShot (combat-spammed; skip the liveFX book).
    { Key = "DL_SNIPE_AIM",
      FX = AnteEnums.Effects.SNIPER_TRACER,
      Beam = true,
      OneShot = true,
      Scale = FVector(1, 1, 1) },
    { Key = "DL_SNIPE_SHOT",
      FX = AnteEnums.Effects.SNIPER_TRACER,
      Sound = AnteEnums.SOUNDS.SNIPER_FIRE,
      Beam = true,
      OneShot = true,
      Scale = FVector(1, 1, 1) },

    -- The Astral Magus <-> Fallow Magus soul-tether pulse (midpoint burst every ~5s), and the BLUE
    -- half of the Spiritwalker/Wraith transpose. Senders pass their own scale.
    { Key = "EXOR_SHOCKWAVE_CHA",
      FX = AnteEnums.Effects.EXOR_SHOCKWAVE_CHA,
      OneShot = true,
      Scale = FVector(1, 1, 1) },

    -- The RED half of that transpose. It carries the blink cue because the pair no longer rides
    -- Broadcast_TeleportFX, which bundled that sound with the sparkle we dropped - without it a
    -- swap has no audio tell at all.
    { Key = "EXOR_SHOCKWAVE",
      FX = AnteEnums.Effects.EXOR_SHOCKWAVE,
      Sound = AnteEnums.Effects.EXOR_BLINK_SFX,
      OneShot = true,
      Scale = FVector(1, 1, 1) },

    -- The ShadowBoss phase-3 arena gates (ShadowStorms BOSS_PHASES[3]) - HELD-OPEN portals sent
    -- once with a fight-length lifetime and closed early by FX.StopClientFX at victory. Both are
    -- deliberately NOT OneShot: the stop opcode only reaches components in the liveFX book, and
    -- these are one-send-per-fight, so the book cost is nothing.
    --   * REDVERSE_HOLD: the red Anteverse gate. No sound - it stands for many minutes.
    --   * YELLOW_HOLD: the Inquisitor ring again, but book'd/stoppable (PORTAL_YELLOW itself is
    --     OneShot and CANNOT be stopped early). Same dialled-in ZOffset. NOTE the stop opcode
    --     keys off the NIAGARA, so stopping this also pops any in-flight Mad Rat arrival ring -
    --     cosmetic, momentary, accepted.
    { Key = "PORTAL_REDVERSE_HOLD",
      FX = AnteEnums.Effects.PORTAL_REDVERSE,
      NoCull = 10000,                    -- 100m; an ARENA gate has to read from the far wall
      Scale = FVector(1, 1, 1) },
    { Key = "PORTAL_YELLOW_HOLD",
      FX = AnteEnums.Effects.PORTAL_FRIENDLY_YELLOW,
      Sound = AnteEnums.SOUNDS.PORTAL_EXIT,
      NoCull = 10000,
      ZOffset = 25,
      Scale = FVector(1, 1, 1) },

    -- OUTLINE opcode - not a Niagara: each renderer outlines the live NPC nearest the sent point
    -- (within OutlineRadius) through walls for `seconds`, via its OutlineComponent's
    -- ToggleOutlineOverlay. Mode = an E_OutlineMode VALUE (5 = PinnedRecipe = yellow; see
    -- ModuleNpcHighlighter's COLOR table). Sender: AVU.OutlineNpcAll(npc, seconds). Used by the
    -- Shadow-boss storm "hunt the stragglers" telegraph. OneShot: never stopped, no book.
    { Key = "OUTLINE_YELLOW",
      Outline = true, OutlineMode = 5, OutlineRadius = 300,
      OneShot = true },

    -- The Exorrior Magus' pushback nova, on its chest. Half speed so the dark burst blooms rather
    -- than snapping - which is why it rides this channel instead of BroadcastFX (that multicast
    -- hands back no component, so it can pace and size neither).
    -- Scale here is only the fallback: the sender passes its own (ExorMonkHelpers NOVA.FxScale),
    -- which is where to tune it - that one reloads, this one needs a restart.
    { Key = "EXOR_NOVA_BURST",
      FX = AnteEnums.Effects.SHADOW_IMPACT_LITE,
      OneShot = true,
      Dilation = 0.35,
      Scale = FVector(3, 3, 3) },

    -- The Order radio call-in chirp (Centurion mark, Commander/Signifer reinforcement calls). The
    -- native Broadcast_RadioChirp already fires alongside these; this rides the channel purely for
    -- the VOLUME lever the multicast doesn't expose, so the call carries across a firefight.
    -- SOUND-ONLY and POSITIONAL - a radio call is a thing you locate, not an announcement.
    -- FAR is the Signifer's: it radios from the back of the fight, so it needs the extra reach.
    { Key = "RADIO_CALL",     Sound = AnteEnums.SOUNDS.RADIO_GK_START, Volume = 1.5 },
    { Key = "RADIO_CALL_FAR", Sound = AnteEnums.SOUNDS.RADIO_GK_START, Volume = 2.0 },

    -- The Tarasque Slammer's marked ground - the spot its slam has committed to, drawn while the
    -- player still has time to leave it. An upward wind column, played slow so it stands for the
    -- whole window.
    --   * It was NIAGARA_YETI_SLAM at scale 3 first: a bright white 15m cloud that whited out the
    --     screen of the player it was warning. A telegraph has to be readable from INSIDE it.
    { Key = "TARASQUE_SLAM_MARK",
      FX = AnteEnums.Effects.FLASK_UPDRAFT,
      OneShot = true,
      Dilation = 0.5,
      ZOffset = -80,                     -- senders pass the target's capsule centre; this is ground
      Scale = FVector(1.5, 1.5, 1.5) },

    -- The Peremptor's cut: an updraft at its feet while it holds the stance, and again where it
    -- arrives. Same Niagara as the slam mark, read as wind off a body rather than marked ground -
    -- so no Dilation (it should snap, not linger) and a tighter scale.
    { Key = "PEREMPTOR_UPDRAFT",
      FX = AnteEnums.Effects.FLASK_UPDRAFT,
      OneShot = true,
      -- Tipped on its side so the column blows ALONG the sender's yaw - a wind tunnel down the
      -- line of the cut rather than a plume at its feet. Flip the sign if it points backwards;
      -- this is registry data, so a change needs a restart, not /reload.
      Pitch = -90,
      ZOffset = -40,                     -- senders pass capsule centre; a horizontal column wants
                                         -- to sit above the floor, not on it
      -- Scale is the ONLY asymmetric dial in the channel: the wire carries one uniform percent, so
      -- a per-axis shape has to live here. Local Z is the column's length, which the pitch has
      -- already turned into the tunnel's reach, so 2x Z is a tunnel twice as long and no wider.
      Scale = FVector(1.2, 1.2, 2.4) },

    -- The Peremptor's cut itself: one of these per hand, spanning the whole blink. The sender owns
    -- placement, facing and LENGTH (the uniform scale), so the entry holds no Scale of its own -
    -- a registry Scale would be overridden by every send anyway.
    { Key = "PEREMPTOR_CUT_TRAIL",
      FX = AnteEnums.Effects.NIAGARA_BOLTTRAIL_HOLY,
      OneShot = true },

    -- The same wind standing up, drawn on the TARGET: it marks who the cut is for rather than
    -- which way it travels, so it reads better as a column than as a tunnel pointing at them.
    { Key = "PEREMPTOR_UPDRAFT_UP",
      FX = AnteEnums.Effects.FLASK_UPDRAFT,
      OneShot = true,
      ZOffset = -80,                     -- upright, so this one does sit on the floor
      Scale = FVector(1.2, 1.2, 2.4) },

    -- The Canaan Farmer's corruption burst, on its head the instant the corn takes.
    -- BroadcastFX cannot pass Niagara params and this system sizes off nothing else, so the
    -- channel is what makes it readable: the HSV shift pushes the stock orange to a sick green.
    { Key = "CORN_SPORES",
      FX = AnteEnums.Effects.SPORES_BURST,
      OneShot = true,
      Scale = FVector(2, 2, 2),
      Vec2Params = {
          HueShiftRange   = { X = 70,  Y = 70 },    -- orange -> yellow-green
          SaturationRange = { X = 1.4, Y = 1.4 },
          ValueRange      = { X = 1.2, Y = 1.2 },
          AlphaScaleRange = { X = 1.5, Y = 1.5 },
      } },

    -- The Storm Witch's shock pulse grenade ring, re-fired every 2s while the shell sits there.
    -- Scale is only the fallback - the sender passes its own (GK_WitchHelpers SW_GRENADE.RingScale),
    -- which is the /reload-able dial; this one needs a restart.
    { Key = "SHOCK_RING",
      FX = AnteEnums.Effects.ELECTROPEST_SHOCKRING,
      OneShot = true,
      Scale = FVector(2, 2, 2) },

    -- Both Magi roar as the nova wind-up starts. Sound-only and positional.
    { Key = "EXOR_NOVA_ROAR", Sound = AnteEnums.SOUNDS.EXOR_VOLATILE_LEAP, Volume = 1.5 },
}

-- Key -> index, built once. Both ends require this file, so they cannot drift.
AnteEnums.ClientFXIndex = {}
for i, def in ipairs(AnteEnums.ClientFX) do AnteEnums.ClientFXIndex[def.Key] = i end


local GRUNTREW = "/Game/Animations/Characters/GruntRework/"
local GKCHIEF  = "/Game/Animations/Characters/GKChieftain/"
local REAPER   = "/Game/Animations/Characters/Reaper/"
-- A montage only plays on an NPC if it is authored on the DefaultSlot: that is the slot NPC anim
-- graphs have a node for, and every entry below is on it. The player's own COMBAT montages (melee
-- swings, weapon fires, shove) are all on UpperAimSpace, the player rig's upper-body aim layer -
-- PlayThirdPersonMontage starts one of those happily, replicates it, and nothing moves. The
-- skeleton is NOT the tell: most of these say Grunt/Rook/LabRat and are all SK_Human_Skeleton.
AnteEnums.Anims = {
    -- MOVING POSE, not a montage. NPC_Soldier_Grunt exposes CombatBlendspace /
    -- AltCombatBlendspace / IdleBlendspace as pawn fields, so the whole soldier family can borrow
    -- another one's walk: write both Combat fields, then `mesh:SetAnimationMode(0, true)` to
    -- re-init (BOTH args - the one-arg call is a silent no-op). Renderer-side; anim fields do not
    -- replicate. The Breacher levels its weapon while walking where BS_Sniper_CombatRun carries it
    -- up across the chest, which is what makes a sniper's laser cross its own body.
    BS_BREACHER_RUN = "/Game/Animations/Characters/GruntRework/BS_Breacher_CombatRun.BS_Breacher_CombatRun",

    -- The Volatile Exor's self-destruct wind-up. Also the Magi's pushback-nova telegraph.
    EXOR_VOLATILE_DETONATE = "/Game/Animations/Characters/ExorVolatile/Anim_Exor_Volatile_Death_Detonate_Montage.Anim_Exor_Volatile_Death_Detonate_Montage",
    -- The Volatile Exor's only melee attack (its whole MeleeAttacks map points here): a 1.2s
    -- double swing, right hand round at 0.1s and left at 0.5s. Nothing in the melee path clears
    -- LockedInPlaceMontage on this base, so play it UNLOCKED and root the body separately.
    EXOR_VOLATILE_MELEE = "/Game/Animations/Characters/ExorVolatile/Anim_Exor_Volatile_Melee_Montage.Anim_Exor_Volatile_Melee_Montage",
    -- NPC_Monster_Exor's AggroAnimation, shared by the whole Exor line (the Monk included). Short
    -- and active, so it doubles as a recovery clip after a held pose.
    EXOR_AGGRO = "/Game/Animations/Characters/Exor/Anim_Exor_Aggro_01_Montage.Anim_Exor_Aggro_01_Montage",
    -- The grunt rope-rappel pair. An AnimSequence, not a Montage. 
    -- * Played with AnimInstance:PlaySlotAnimationAsDynamicMontage (renderer-local). Used by Speculatores
    GRUNT_FASTROPE_LOOP = GRUNTREW .. "Anim_Grunt_FastRope_Loop.Anim_Grunt_FastRope_Loop",
    GRUNT_FASTROPE_LAND = GRUNTREW .. "Anim_Grunt_FastRope_Land.Anim_Grunt_FastRope_Land",
    GRUNT_AGGRO         = GRUNTREW .. "Anim_Grunt_Aggro_Montage.Anim_Grunt_Aggro_Montage",
    -- The whole Order line's melee swing, 1.6s - NPC_Soldier_Grunt points EVERY MeleeAttacks
    -- enumerator at it and no subclass (Trooper included) overrides. Read for its raw length by
    -- variants timing their own release valve (the ROOK_LUNGE note below). TWO-HANDED, and it
    -- rolls the right wrist mid-arc, so a prop mounted on r_hand swings through inverted - the
    -- Salii moved off it to LABRAT_MELEE for that. Contact frame 0.5s raw (the grunt's MeleeHitApex).
    GRUNT_MELEE         = GRUNTREW .. "Anim_Grunt_Melee_Montage.Anim_Grunt_Melee_Montage",
    -- The peccary charge TELEGRAPH. Its RAW length is the native windup (the ubergraph builds the
    -- pre-stampede delay from PlayAnimMontage's return, which is the un-rate-divided length), so
    -- anything that wants a shorter windup has to measure this and drive the start beat itself -
    -- AnteNPCs/PeccaryHelpers' H.QuickCharge. [[af-peccary-charge-decode]]
    PECCARY_CHARGE_START = "/Game/Animations/Characters/Peccary/Anim_Peccary_Charge_Start_Montage.Anim_Peccary_Charge_Start_Montage",
    -- Signifer's call-in reinforcement animation
    STAND_AND_RADIO = "/Game/Animations/Characters/Scientist/ThirdPerson/Retargeted/Anim_Standing_MessWithRadio_Montagert.Anim_Standing_MessWithRadio_Montagert",
    -- The player's generic eat/drink clip, ~1.6s
    PLAYER_EAT_GENERIC = "/Game/Animations/Characters/Scientist/ThirdPerson/Retargeted/Anim_Player_Eat_Generic_Montagert.Anim_Player_Eat_Generic_Montagert",
    PLAYER_DRINK_GENERIC = "/Game/Animations/Characters/Scientist/ThirdPerson/Retargeted/Anim_Player_Drink_Container_Montagert.Anim_Player_Drink_Container_Montagert",
    GRUNT_RELOAD_SMG    = GRUNTREW .. "Anim_Grunt_Reload_SMG_Montage.Anim_Grunt_Reload_SMG_Montage",
    -- NPC_Soldier_Captain overrides ReloadMontage with its OWN clip - the magnum reload, NOT the
    -- SMG one. ModAnimationSpeed matches by PATH, so a Captain variant speeding GRUNT_RELOAD_SMG
    -- is a silent no-op (the montage it names never plays on that base).
    CAPTAIN_RELOAD      = GRUNTREW .. "Anim_Captain_Reload_Montage.Anim_Captain_Reload_Montage",
    GRUNT_GRENADE_THROW = GRUNTREW .. "Anim_Grunt_Grenade_Throw_Montage.Anim_Grunt_Grenade_Throw_Montage",
    -- Neophyte Trainer - mimic a throw
    GK_GRENADE_THROW    = GRUNTREW .. "Anim_GKChieftain_Throw_Montage.Anim_GKChieftain_Throw_Montage",
    GRUNT_STAGGER_LEFT  = GRUNTREW .. "Anim_Grunt_Stagger_Left_Montage.Anim_Grunt_Stagger_Left_Montage",
    GRUNT_STAGGER_RIGHT = GRUNTREW .. "Anim_Grunt_Stagger_Right_Montage.Anim_Grunt_Stagger_Right_Montage",
    -- A short backward stumble. Sped up it reads as a hop back rather than a stagger, which is
    -- what the Skirmisher's clip-out retreat uses.
    GRUNT_STAGGER_BACK  = GRUNTREW .. "Anim_Grunt_Stagger_Backward_Montage.Anim_Grunt_Stagger_Backward_Montage",
    -- THE REAPER's soft-ref animation set
    REAPER_ATTACK_LEFT  = REAPER   .. "Anim_Reaper_Attack_Left_Montage.Anim_Reaper_Attack_Left_Montage",
    REAPER_ATTACK_LEAP  = REAPER   .. "Anim_Reaper_Attack_Leap_Montage.Anim_Reaper_Attack_Leap_Montage",
    REAPER_GRAB         = REAPER   .. "Reaper_Attack_GrabNew_Montage.Reaper_Attack_GrabNew_Montage",
    REAPER_AGGRO        = REAPER   .. "Anim_Reaper_Aggro_Montage.Anim_Reaper_Aggro_Montage",
    REAPER_BLOCK        = REAPER   .. "Anim_Reaper_Combat_Block_Montage.Anim_Reaper_Combat_Block_Montage",
    -- The Grunt's backward knockback = its BackstepAnimation (AI_PerformBackstep, ForceBackwards).
    -- Used as the Velites' "LeapBack". Preload it (a cold montage sync-loads in our tick hook = §2).
    GRUNT_KNOCKBACK     = GRUNTREW .. "Anim_Grunt_Knockback_Montage.Anim_Grunt_Knockback_Montage",
    BREACHER_RELOAD     = GRUNTREW .. "Anim_Breacher_Reload_Montage.Anim_Breacher_Reload_Montage",
    -- The Witch's shotgun reload (its ReloadMontage soft ref). Warrior Witch speeds it up via OnReload.
    GKWITCH_RELOAD      = "/Game/Animations/Characters/GKWitch/Anim_GKWitch_Reload_Montage.Anim_GKWitch_Reload_Montage",
    -- The witch's ritual dance - an ambient/flavour montage the shipped game never plays in
    -- combat. The Mother of the Fallow channels her aspects with it.
    --   * It opens with a couple of seconds of wind-up before the dance proper, so a short window
    --     wants AVU.SkipIntoAnimation (or one of the offset cuts below).
    --   * _OffSetB / _OffSetC are the game's own alternate cuts, almost certainly the same dance
    --     entered at different points so a group of dancers isn't in lockstep. UNVERIFIED which
    --     beat each opens on - if one lands right it beats the local skip, because a different
    --     ASSET replicates through the montage multicast and a position write does not.
    GKWITCH_DANCE_RITUAL = "/Game/Animations/Characters/GKWitch/Anim_GKWitch_Dance_Ritual_Montage.Anim_GKWitch_Dance_Ritual_Montage",
    GKWITCH_DANCE_RITUAL_B = "/Game/Animations/Characters/GKWitch/Anim_GKWitch_Dance_Ritual_Montage_OffSetB.Anim_GKWitch_Dance_Ritual_Montage_OffSetB",
    GKWITCH_DANCE_RITUAL_C = "/Game/Animations/Characters/GKWitch/Anim_GKWitch_Dance_Ritual_Montage_OffSetC.Anim_GKWitch_Dance_Ritual_Montage_OffSetC",
    -- The Heavy's LMG reload (its ReloadMontage soft ref).
    -- *** For an NPC the MONTAGE is the reload clock, not CurrentReloadDuration *** - NPC_Base's
    -- Broadcast_ReloadWeapon plays it at rate 1 and refills CurrentAmmoCount on its
    -- Completed/BlendOut/notify. So there are only two ways to speed an NPC reload up:
    --   * the montage rate (OnReload + AVU.ModAnimationSpeed) - but Montage_SetPlayRate is
    --     SERVER-LOCAL, so clients still watch a full-length reload
    --   * CustomTimeDilation for the duration, mirrored to clients via def.MirrorTimeDilation
    --     (what the Jotun Rocketeer does)
    -- CurrentReloadDuration is an Abiotic_Character (player) field the NPC path never reads.
    GKHEAVY_RELOAD      = "/Game/Animations/Characters/GKHeavy/Anim_GKHeavy_Combat_Reload_Montage.Anim_GKHeavy_Combat_Reload_Montage",
    GK_DODGE_LEFT       = GKCHIEF  .. "Anim_Gatekeeper_Chieftain_Dodge_Left_Montage.Anim_Gatekeeper_Chieftain_Dodge_Left_Montage",
    -- The Mystagogue's own left dodge. It PLAYS on the grunt rig - so the montage retargets, unlike
    -- GKCHIEF_COMBAT_FIRE below going the other way - but it reads wrong on that body, and the
    -- Skirmisher went back to GK_DODGE_LEFT above. Left decoded; don't re-try it on a soldier.
    MAGE_DODGE_LEFT     = "/Game/Animations/Characters/GKMystagogue/Anim_Mage_Dodge_Left_Montage.Anim_Mage_Dodge_Left_Montage",
    GK_DODGE_RIGHT      = GKCHIEF  .. "Anim_Gatekeeper_Chieftain_Dodge_Right_Montage.Anim_Gatekeeper_Chieftain_Dodge_Right_Montage",
    -- The GK soldier family's native BackstepAnimation (Chieftain + GK Grunt both soft-ref it).
    GK_DODGE_BACK       = GKCHIEF  .. "Anim_Gatekeeper_Chieftain_Dodge_Back_Montage.Anim_Gatekeeper_Chieftain_Dodge_Back_Montage",
    -- The Interfector's back dodge - the Warrior Witch's backflip look (played unlocked during
    -- her back+up kick hop, replicated via PlayMontageReplicated).
    INTERFECTOR_DODGE_BACK = "/Game/Animations/Characters/Interfector/Anim_Interfector_Dodge_Back_Montage.Anim_Interfector_Dodge_Back_Montage",
    -- The Interfector's native 3-knife throw montage. Its knives are fired by the UBERGRAPH
    -- (Server_DoRangedAttack: montage, then 3x FireRanged_Projectile on Delay(TimeBetweenKnives)),
    -- NOT by an AnimNotify - so replaying this as the visual for a scripted throw does not
    -- double-fire anything (unlike GRUNT_GRENADE_THROW, whose notify spawns the grenade).
    INTERFECTOR_THROW_KNIVES = "/Game/Animations/Characters/Interfector/Anim_Interfector_ThrowKnives_Montage.Anim_Interfector_ThrowKnives_Montage",
    -- The Interfector's dagger swipe. Its damage is dealt by the native melee path, not by a
    -- notify on this montage, so playing it standalone is a pure pose - which is what the
    -- Peremptor's held stance uses it as (slowed to a crawl, so it settles mid-swing).
    INTERFECTOR_MELEE_01 = "/Game/Animations/Characters/Interfector/Anim_Interfector_Melee_01_Montage.Anim_Interfector_Melee_01_Montage",
    -- The Chieftain's DBNO self-revive heal anim (Server_PerformDBNORevive plays it for 3.8s).
    -- It's the ONLY "self-medicate" montage on the GKChieftain skeleton - player drink montages
    -- won't retarget - so the Esoteric Chieftain reuses it standing as its tincture-drink anim.
    GK_DBNO_HEAL        = GKCHIEF  .. "Anim_Gatekeeper_Chieftain_DBNO_Heal_Montage.Anim_Gatekeeper_Chieftain_DBNO_Heal_Montage",
    -- The Chieftain's disc-launcher fire pose. CROSS-SKELETON RESULT (2026-08-13): does NOT
    -- play on the Mystagogue (tried as the Magus channel pose - silent nothing), so the GK_DODGE
    -- "any humanoid soldier" rule does not extend to the Mystagogue rig. Kept for Chieftain use.
    GKCHIEF_COMBAT_FIRE = GKCHIEF  .. "Anim_Gatekeeper_Chieftain_Combat_Fire_Montage.Anim_Gatekeeper_Chieftain_Combat_Fire_Montage",
    -- The Chieftain's grab-headbutt (MeleeAttacks type 6) and its ordinary swing (type 1). Both
    -- are here to be MEASURED: the BT's melee wait is sized from the clip's raw length, so a body
    -- that speeds its swings up has to fire the release valve itself (AVU.MeleeReleaseTicks).
    -- The grab clip carries no notify - the grab moment is the native MeleeHitApex delay, which a
    -- play rate does not scale.
    GKCHIEF_GRAB        = GKCHIEF  .. "Anim_Gatekeeper_Chieftain_Combat_Grab_Headbutt_Montage.Anim_Gatekeeper_Chieftain_Combat_Grab_Headbutt_Montage",
    GKCHIEF_MELEE       = GRUNTREW .. "Anim_GKChieftain_Melee_Montage.Anim_GKChieftain_Melee_Montage",

    -- The Mage's cast: its FireballMontage, which is also its GrenadeThrowAnimation. Reused as the
    -- "I am summoning an eye" tell (AnteNPCs/GK_Mage.lua). Playing it does NOT throw a fireball -
    -- the projectile is spawned by Server_DoRangedAttack, not by the montage.
    MAGE_FIREBALL       = "/Game/Animations/Characters/GKMystagogue/Anim_Mage_Fireball_Montage.Anim_Mage_Fireball_Montage",

    -- Mage flaoating meditation pose
    MAGE_MEDITATE       = "/Game/Animations/Characters/GKMystagogue/Anim_Mage_Meditate.Anim_Mage_Meditate",
    -- The Mage Eye drone's two poses. Its AnimBP is a two-state machine picking between exactly
    -- these off `CanSeeTarget = IsValid(StationaryTarget)`; playing one directly (single-node mode)
    -- takes the pose away from that machine - and from the random hover bob in the same graph.
    MAGEEYE_CLOSE       = "/Game/Animations/Characters/MageEyeDrone/Anim_MageEyeDrone_Close.Anim_MageEyeDrone_Close",
    MAGEEYE_OPEN        = "/Game/Animations/Characters/MageEyeDrone/Anim_MageEyeDrone_OpenFix.Anim_MageEyeDrone_OpenFix",

    -- The Mystagogue side-steps, as raw SEQUENCES rather than their _Montage siblings - the only
    -- form that plays on a mesh held in single-node mode by an idle pose. Currently UNUSED: the
    -- Abjurer's scripted sidestep was dropped because the mage's own native dodge already works
    -- and does not disturb the meditate pose. Kept for the next pose-locked idle that needs one.
    MAGE_DODGE_LEFT_SEQ  = "/Game/Animations/Characters/GKMystagogue/Anim_Mage_Dodge_Left.Anim_Mage_Dodge_Left",
    MAGE_DODGE_RIGHT_SEQ = "/Game/Animations/Characters/GKMystagogue/Anim_Mage_Dodge_Right.Anim_Mage_Dodge_Right",

    -- Symphonist idle. An AnimSequence (not a _Montage), which is what single-node evaluation
    -- wants - it is used as a FROZEN FRAME for the `symph` collectible, not played.
    SYMPH_IDLE          = "/Game/Animations/Characters/Symphonist/Anim_Symphonist_Idle.Anim_Symphonist_Idle",

    -- The Mage's choke grab pair (MeleeAttacks type 6). START's AnimNotify is what arms the native
    -- grab-overlap window (Tick_CheckForGrabOverlap), so playing it via PlayMontageReplicated IS a
    -- scripted grab attempt; SUCCESS is FindObject'd cold by Broadcast_DoSuccessfulGrabAnimation -
    -- non-resident = the whole choke silently whiffs. Preload BOTH (the Magus force choke).
    MAGE_GRAB_START     = "/Game/Animations/Characters/GKMystagogue/Anim_Mage_Grab_Start_Montage.Anim_Mage_Grab_Start_Montage",
    MAGE_GRAB_SUCCESS   = "/Game/Animations/Characters/GKMystagogue/Anim_Mage_Grab_Success_Montage.Anim_Mage_Grab_Success_Montage",

    -- The Mage's block/brace (its native AggroAnimation). The Magus eye-beam channel pose:
    -- holds the head steady, which is what a beam ORIGINATING at the eye needs.
    MAGE_BLOCK          = "/Game/Animations/Characters/GKMystagogue/Anim_Mage_Block_Montage.Anim_Mage_Block_Montage",

    -- CONSOLIDATED (migrated from per-file locals 2026-07-19)
    -- Fishing catch montages (ModuleCheats /instantfishing preload; the tool + FP-arms variant).
    ROD_CATCH_SUCCESS    = "/Game/Animations/Tools/Anim_Rod_Catch_Success_Montage.Anim_Rod_Catch_Success_Montage",
    FP_ROD_CATCH_SUCCESS = "/Game/Animations/Characters/Scientist/FPArms/FishingRod/Anim_FP_Rod_Catch_Success_Montage.Anim_FP_Rod_Catch_Success_Montage",
    ROD_CATCH_FAIL       = "/Game/Animations/Tools/Anim_Rod_Catch_Fail_Montage.Anim_Rod_Catch_Fail_Montage",
    FP_ROD_CATCH_FAIL    = "/Game/Animations/Characters/Scientist/FPArms/FishingRod/Anim_FP_Rod_Catch_Fail_Montage.Anim_FP_Rod_Catch_Fail_Montage",
    -- Sapper family montages (Sapper throw / rocket-launcher equip; LabRat backstep).
    SAPPER_THROW          = "/Game/Animations/Characters/Sapper/Anim_Sapper_Combat_ThrowGrenade_Montage.Anim_Sapper_Combat_ThrowGrenade_Montage",
    SAPPER_EQUIP_LAUNCHER = "/Game/Animations/Characters/Sapper/Anim_Sapper_Combat_Equip_Launcher_Montage.Anim_Sapper_Combat_Equip_Launcher_Montage",
    -- The Sapper's swing - the montage its MeleeAttacks map points all three melee types at.
    -- Its hit beat is MeleeHitApex 0.2s; sped up, that apex has to be divided by the play rate
    -- or the native contact lands before the animation gets there.
    SAPPER_MELEE          = "/Game/Animations/Characters/Sapper/Anim_Sapper_Combat_Melee_Montage.Anim_Sapper_Combat_Melee_Montage",
    LABRAT_BACKSTEP       = "/Game/Animations/Characters/LabRat/Anim_LabRat_Stagger_Backwards_Montage.Anim_LabRat_Stagger_Backwards_Montage",
    -- The LabRat's swing - the montage its MeleeAttacks map points ALL THREE melee types at.
    --   * PREFER THIS over a Scientist/Retargeted player montage when hand-playing an NPC swing:
    --     DefaultSlot (read from the asset's name table), and NPC graphs are minimal
    --     (AnimBP_Clericus has only DefaultSlot + DeathSlot)
    --   * ONE-HANDED right-hand swing (the Garage rat's pipe wrench), contact frame 0.2s raw (the
    --     LabRat's MeleeHitApex) - the Salii's swing AND its parry flourish
    LABRAT_MELEE          = "/Game/Animations/Characters/LabRat/Anim_LabRat_Melee_Montage.Anim_LabRat_Melee_Montage",
    -- "I just walked out of a rift" - the ONLY step-out-of-a-portal montage in the game, and it is
    -- on the right rig for the rat family: NarrativeNPC_HastaTria plays it from its ubergraph the
    -- moment it stops being disabled, and its IdleAnimation is Anim_Sapper_Idle - i.e. HastaTria IS
    -- a Sapper-skinned body, so Sapper/LabRat variants share its skeleton.
    --   * The path has a `_Montage` SUFFIX (the asset in the BP bytecode); without it nothing
    --     resolves and PlayMontageReplicated no-ops SILENTLY.
    --   * UNVERIFIED: which SLOT it declares. A montage whose slot has no node in the target
    --     AnimBP plays into nothing - succeeds, right length, mesh never moves (the Salii
    --     dead-montage case, AnNotes/AnteNPCs/OrderClericus.md). If an arrival looks static, that's why.
    HASTATRIA_EXIT_PORTAL = "/Game/Animations/Characters/HastaTria/Anim_HastaTria_ExitPortal_Montage.Anim_HastaTria_ExitPortal_Montage",
    -- The Rook family's two melee montages, straight off NPC_Groupe_Shield's MeleeAttacks map:
    -- enumerators 0/3 -> LUNGE (the MOBILE swing), enumerator 1 -> SHIELD BASH (the TURTLED one).
    -- Which one plays follows the AI_TurtleMode tag, not a write (AnNotes/AnteNPCs/OrderRook.md).
    -- We mostly don't PLAY these - the base does. They are here to read GetPlayLength off: the
    -- BT's melee release is RetriggerableDelay(GetPlayLength - GetMeleeTimeOffset) using the RAW
    -- length: MeleeAttackPlayRate speeds the visible swing but NOT the wait, so a variant that
    -- wants a faster cadence has to time its own AVU.ReleaseSoldierBT off these.
    -- The exception to that: the Canaan Fanatic plays the LUNGE outright as its ignite beat. 1.4s,
    -- and it carries the body ~1m forward on ROOT MOTION - so whatever plays it must not be in
    -- MOVE_None, or the travel is silently dropped.
    ROOK_LUNGE       = "/Game/Animations/Characters/Rook/Anim_Rook_Melee_Lunge_Montage.Anim_Rook_Melee_Lunge_Montage",
    ROOK_SHIELD_BASH = "/Game/Animations/Characters/Rook/Anim_Rook_Turtle_ShieldBash_Montage.Anim_Rook_Turtle_ShieldBash_Montage",
    -- The Peccary family's melee montage (MeleeAttacks enumerator 0; enumerator 1 is the LUNGE
    -- that rides the charge). Same job as the Rook pair above - measured, never played, so a
    -- variant can time its own release valve. NOTE the Peccary is the ONE base that overrides
    -- GetMeleeTimeOffset (0.2), and that offset is already subtracted from the native wait, so a
    -- scripted release has to subtract it too or it lands LATER than vanilla.
    PECCARY_MELEE    = "/Game/Animations/Characters/Peccary/Anim_Peccary_Combat_Melee_Montage.Anim_Peccary_Combat_Melee_Montage",
    -- The security robot's right-handed windup punch (its MeleeAttacks enumerator 0). 1.1s, with
    -- the arm fully extended at ~0.4s - so it doubles as a throw telegraph. The swing's damage
    -- comes from the native melee path (MeleeHitApex), not a notify, so replaying it on its own
    -- is a pure visual.
    ROBOT_T1_PUNCH   = "/Game/Animations/Characters/RobotT1/Anim_Robot_T1_Attack_Stun_Montage.Anim_Robot_T1_Attack_Stun_Montage",
    ROBOT_T1_LUNGE   = "/Game/Animations/Characters/RobotT1/Anim_Robot_T1_Attack_Lunge_Montage.Anim_Robot_T1_Attack_Lunge_Montage",
    -- What AI_PerformStagger plays on the whole robot line (NPC_Robot_ParentBP.StaggerAnimation).
    ROBOT_T1_STAGGER = "/Game/Animations/Characters/RobotT1/Anim_Robot_T1_Stagger_Montage.Anim_Robot_T1_Stagger_Montage",
    -- The T1 rear swipe (MeleeAttacks enumerator 5). 1.2s: the right arm holds forward through
    -- ~0.1s, sweeps round to ~0.6s, then resets - the shape the Constrictor's lasso is timed to.
    -- Named here so that variant can PRELOAD it: the native melee path loads its montage
    -- asynchronously, so an unwarmed one starts well after the script that asked for it.
    ROBOT_T1_REAR    = "/Game/Animations/Characters/RobotT1/Anim_Robot_T1_Attack_Rear_Montage.Anim_Robot_T1_Attack_Rear_Montage",
    -- The Crystallisk's power melee (MeleeAttacks enumerator 1) - a forward roll rather than a
    -- swing, which is why the Obsidilisk's Shardlings use it as their scatter. Damage comes from
    -- the native melee path (PowerMeleeHitApex), not a notify, so replaying it is a pure visual.
    ASSASSIN_POWER_MELEE = "/Game/Animations/Characters/Assassin/Anim_Assassin_Power_Melee_Montage.Anim_Assassin_Power_Melee_Montage",
}

AnteEnums.DeployedObjs = {
    BASE = "/Game/Blueprints/DeployedObjects/AbioticDeployed_ParentBP.AbioticDeployed_ParentBP_C",

    CRAFTING_BENCH = "/Game/Blueprints/DeployedObjects/Furniture/AbioticDeployed_CraftingBench_ParentBP.AbioticDeployed_CraftingBench_ParentBP_C",
    -- The concrete bench kinds (all children of CRAFTING_BENCH). ModuleDirector registers
    -- NotifyOnNewObject per concrete class; any of them marks a player base.
    CRAFTING_BENCH_DEFAULT = "/Game/Blueprints/DeployedObjects/Furniture/Deployed_CraftingBench_Default.Deployed_CraftingBench_Default_C",
    CRAFTING_BENCH_REPAIR  = "/Game/Blueprints/DeployedObjects/Furniture/Deployed_CraftingBench_Repair.Deployed_CraftingBench_Repair_C",
    CRAFTING_BENCH_UPGRADE = "/Game/Blueprints/DeployedObjects/Furniture/Deployed_CraftingBench_Upgrade.Deployed_CraftingBench_Upgrade_C",
    CRAFTING_BENCH_SIGNAL  = "/Game/Blueprints/DeployedObjects/Furniture/Deployed_CraftingBench_SIGNAL.Deployed_CraftingBench_SIGNAL_C",
    BENCH_AMMO             = "/Game/Blueprints/DeployedObjects/Furniture/Deployed_Bench_AmmoStation.Deployed_Bench_AmmoStation_C",
    BENCH_COOKING          = "/Game/Blueprints/DeployedObjects/Furniture/Deployed_Bench_CookingStation.Deployed_Bench_CookingStation_C",
    CHOPINATOR = "/Game/Blueprints/DeployedObjects/Misc/Deployed_ElectricFan.Deployed_ElectricFan_C",
    DISCTURRET = "/Game/Blueprints/DeployedObjects/Misc/Deployed_Turret_Disc.Deployed_Turret_Disc_C",
    BAGWALLCURVE = "/Game/Blueprints/DeployedObjects/Barricades/Deployed_CementBagWall_Curve.Deployed_CementBagWall_Curve_C",
    BAGWALL = "/Game/Blueprints/DeployedObjects/Barricades/Deployed_CementBagWall_Straight.Deployed_CementBagWall_Straight_C",
    ITEM_STAND = "/Game/Blueprints/DeployedObjects/Furniture/Deployed_ItemStand_ParentBP.Deployed_ItemStand_ParentBP_C",
    -- Rings when a NARRATIVE trader spawns within its Range (5000). Our traders spawn directly, so
    -- ModuleTraders/Traders rings it by hand - see ringArrivalBells there.
    ARRIVAL_BELL = "/Game/Blueprints/DeployedObjects/Furniture/Deployed_ArrivalBell.Deployed_ArrivalBell_C",
    -- Parent of all furniture. No bobblehead class overrides its ReceiveBeginPlay, so a bobblehead's
    -- BeginPlay dispatches to this class's UFunction (ModuleBobbleheads hooks it there).
    FURNITURE = "/Game/Blueprints/DeployedObjects/Furniture/AbioticDeployed_Furniture_ParentBP.AbioticDeployed_Furniture_ParentBP_C",

    -- The bobblehead PARENT, and the one deployed class NO item row points at (all 13 vanilla
    -- bobblehead rows target a subclass). That makes it a free host: every instance in the world
    -- is OURS, so ModuleBobbleheads needs no class-identity test beyond "is it exactly this".
    -- It is also a complete working bobblehead already (Science meshes) and SILENT - the talking
    -- subclasses override Broadcast_BobbleMyHead, so hosting on one of those would stack their
    -- vanilla line under ours.
    BOBBLEHEAD = "/Game/Blueprints/DeployedObjects/Furniture/Deployed_Bobblehead_ParentBP.Deployed_Bobblehead_ParentBP_C",
}

-- =======================================================================
-- Deployable FAMILIES - the vocabulary `def.DeployableDamage` speaks (see AVU.DeployableDamageMult
-- and VariantDef.md). Group name -> the deployed CLASS-name prefixes that belong to it.
--   * Prefixes are LOWERCASE and matched against a lowercased class name, because an FName's
--     ToString casing is set by whoever registered the name first, not by us
--     ([[af-fname-casing-not-stable]]).
--   * A prefix, not an exact name, so every subclass comes along for free: "deployed_barricade_"
--     is Carbon / Makeshift / Plank_Full / Plank_Half / Plank_Window and anything added later.
--   * Add a group here rather than spelling classes out in a variant def - the point is that two
--     NPCs that both "chew through barricades" agree on what a barricade IS.
-- =======================================================================
AnteEnums.DeployedGroups = {
    -- Every player-built WALL. Cement bag walls were their own family and are folded in here: an
    -- NPC that tears through a plank wall has no reason to respect a sandbag one, and two families
    -- that can both match a wall would make "first match wins" a coin flip.
    Barricade = { "deployed_barricade_", "deployed_cementbagwall_" },
    Turret    = { "deployed_turret_" },                          -- Disc, Laser, Laser_AUTO (player-built)
    Fan       = { "deployed_electricfan" },                      -- the Chopinator
}

-- =======================================================================
-- Collectibles/Bobbleheads - /Game/Models/Items/Collectible/
--   * Bobbleheads have a Body, Head, and _Full (deploy hologram)
--   * StaticMeshes - if we provide a Skeletal mesh its an added component
--
-- HEAD_Z = included with bobble head as a neck height baked into into BobbleHead.RelativeLocation
-- =======================================================================
local COLLECT = "/Game/Models/Items/Collectible/"
AnteEnums.Collectibles = {
    -- key = { Body, Head, HeadZ }.  HeadX/Y are ~0.2/0 on every row; not worth carrying.
    SCIENCE = { Body = COLLECT .. "SM_Collectible_Science.SM_Collectible_Science",
                Head = COLLECT .. "SM_Collectible_Science_Head.SM_Collectible_Science_Head",     HeadZ = 25.52 },
    SNIPER  = { Body = COLLECT .. "SM_Collectible_Sniper.SM_Collectible_Sniper",
                Head = COLLECT .. "SM_Collectible_Sniper_Head.SM_Collectible_Sniper_Head",       HeadZ = 24.70 },
    GKHEAVY = { Body = COLLECT .. "SM_Collectible_GKHeavy.SM_Collectible_GKHeavy",
                Head = COLLECT .. "SM_Collectible_GKHeavy_Head.SM_Collectible_GKHeavy_Head",     HeadZ = 31.34 },
    GRUNT   = { Body = COLLECT .. "SM_Collectible_Grunt.SM_Collectible_Grunt",
                Head = COLLECT .. "SM_Collectible_Grunt_Head.SM_Collectible_Grunt_Head",         HeadZ = 26.70 },
    SECURITY = { Body = COLLECT .. "SM_Collectible_Security.SM_Collectible_Security",
                Head = COLLECT .. "SM_Collectible_Security_Head.SM_Collectible_Security_Head",   HeadZ = 25.52 },
    BLACKSMITH = { Body = COLLECT .. "SM_Collectible_Blacksmith.SM_Collectible_Blacksmith",
                Head = COLLECT .. "SM_Collectible_Blacksmith_Head.SM_Collectible_Blacksmith_Head", HeadZ = 25.52 },

    -- *** NOT A BOBBLEHEAD ROW. *** SM_Collectible_Composer is one of the orphan collectible
    -- sculpts (referenced by ZERO blueprint - see [[anteup2-bobblehead-decode]]): a composer
    -- figure standing on a round standee, with NO _Head split and no item row pointing at it.
    -- That means two things:
    --   * Head is nil, so any def using this MUST set HideHead - applyLook only swaps the head
    --     mesh on the non-hidden branch, and a nil path into swapMesh would just log.
    --   * It is never resident. It only works because allAssetPaths pulls Look.Body into the
    --     module's preload+pin batch (CLAUDE.md S3).
    -- HeadZ is the PARENT DEFAULT, not a measurement - nothing ever hung a head on this sculpt.
    -- For a HideHead def it is purely the wobble PIVOT height, which is what `symph` uses it for.
    COMPOSER = { Body = COLLECT .. "SM_Collectible_Composer.SM_Collectible_Composer",
                Head = nil,                                                                       HeadZ = 25.52 },
}

-- Gatekeeper Chieftain / Phyter parts - the FULL-SIZE NPC skeletals, for the overlay tier.
--   * A SkeletalMeshComponent with no anim instance renders its REFERENCE pose. Fine for a head
--     (nothing to animate); an arms-out A-pose torso is the reason we borrow a collectible BODY
--     instead of building the whole figure from these.
--   * Chieftain vs Phyter is the head + mask: skull mask vs NV goggles.
AnteEnums.GateKeeperParts = {
    HEAD        = "/Game/Models/Characters/NPCs/GateKeeperChieftain/SK_GateKeeper_Head.SK_GateKeeper_Head",
    HEAD_PHYTER = "/Game/Models/Characters/NPCs/GateKeeperChieftain/SK_GateKeeper_Head_Phyter.SK_GateKeeper_Head_Phyter",
    TORSO       = "/Game/Models/Characters/NPCs/GateKeeperChieftain/SK_GateKeeper_Torso.SK_GateKeeper_Torso",
    LEGS        = "/Game/Models/Characters/NPCs/GateKeeperChieftain/SK_GateKeeper_Legs.SK_GateKeeper_Legs",
    -- The part MATERIALS. Normally you never need these - a part component set up by the game
    -- takes its material from the asset. They matter when a part is re-attached STANDALONE after
    -- MergeAndClearSkeletals has already eaten it ([[af-modular-mesh-merge]]): the merged mesh
    -- carries the combined material list, so a lone part can come back PRESENT, VISIBLE, holding
    -- its asset and still drawing NOTHING (`mats=0` in /dumpmesh). That is a real bug that cost a
    -- round trip - the chieftain's head does it, its legs do not.
    -- Pass one as AVU.AttachSkeletalMesh's opts.Material (slot 0). M_ChieftainHead is shared by
    -- the head AND the skull mask - one T_ChieftainMask atlas covers both.
    M_HEAD      = "/Game/Models/Characters/NPCs/GateKeeperChieftain/M_ChieftainHead.M_ChieftainHead",
    M_LEGS      = "/Game/Models/Characters/NPCs/GateKeeperChieftain/M_ChieftainLegs.M_ChieftainLegs",
    M_TORSO     = "/Game/Models/Characters/NPCs/GateKeeperChieftain/M_ChieftainTorso.M_ChieftainTorso",

    -- Phyter and Chieftain share head, just with a skull or goggles
    HELMET      = "/Game/Models/Characters/NPCs/GateKeeperChieftain/SM_ChieftainHelmet.SM_ChieftainHelmet",
    SKULL       = "/Game/Models/Characters/NPCs/GateKeeperChieftain/SM_GateKeeper_Chieftain_Skull.SM_GateKeeper_Chieftain_Skull",
    NV_GOGGLES  = "/Game/Models/Characters/NPCs/GateKeeperHeavy/SM_NightVisionGoggles.SM_NightVisionGoggles",

    -- The pistol, for posing a figure holding one. Hand bones on this family are named by
    -- NPC_Base_ParentBP: "r_hand" / "l_hand".
    PISTOL      = "/Game/Models/Weapons/Ranged/GateKeeperPistol/SM_GKPistol.SM_GKPistol",

    -- Two-handed aiming pose, used as a FROZEN FRAME (not played) to get a posed figurine out of
    -- a skeletal that would otherwise render its arms-out reference pose.
    --   *** THE SEQUENCE, NOT THE _Montage. *** Single-node mode (SetAnimation + SetPosition +
    --   Stop) is built around AnimSequence; a montage is a wrapper with its own slot/section
    --   machinery and does not reliably evaluate that way. Both assets exist side by side.
    ANIM_FIRE   = "/Game/Animations/Characters/GKChieftain/Anim_Gatekeeper_Chieftain_Combat_Fire.Anim_Gatekeeper_Chieftain_Combat_Fire",
}

-- =======================================================================
-- Destructible resource nodes - Computers, military radios, etc.
-- =======================================================================
AnteEnums.ResourceNodes = {
    BASE = "/Game/Blueprints/Environment/Nodes/ResourceNode_ParentBP.ResourceNode_ParentBP",
    RADIO = "/Game/Blueprints/Environment/Nodes/ResourceNode_MilitaryRadio.ResourceNode_MilitaryRadio_C",
    HEXED_TREE = "/Game/Blueprints/Environment/Nodes/ResourceNode_HexedTree.ResourceNode_HexedTree_C",
}

-- =======================================================================
-- Projectile classes
-- * Note: When modifying thrown weapons with trajectories, raise MaxSpeed
--   to prevent clamping
-- =======================================================================
AnteEnums.ProjectileClasses = {
    BASE = "/Game/Blueprints/Projectiles/AbioticProjectile_ParentBP.AbioticProjectile_ParentBP_C",

    ThrownWeapon = "/Game/Blueprints/Projectiles/Projectile_ThrownWeapon.Projectile_ThrownWeapon_C", --can assign a static mesh
    ThrowingIceShard = "/Game/Blueprints/Projectiles/Projectile_ThrowingKnife_IceShard.Projectile_ThrowingKnife_IceShard_C",

    GrenadeParent = "/Game/Blueprints/Projectiles/Projectile_Grenade_ParentBP.Projectile_Grenade_ParentBP_C",
    GrenadeFrag = "/Game/Blueprints/Projectiles/Projectile_Grenade_Frag.Projectile_Grenade_Frag_C",
    -- The Sapper's AT rocket. A Projectile_Grenade_Frag subclass, so PROJ.SpawnGrenade drives it.
    -- Row projectile_rocketsapper: 2000 speed, gravity 0.01 (flat), AoE 350/500,
    -- DamageType_Explosive_DefenseBot and NO debuff, so firing one carries no buff preload.
    -- It airbursts when its owner's combat target enters the AirburstOverlap sphere, which means
    -- the spawner must be SetOwner'd to the NPC (PROJ does that post-Finish).
    RocketSapper = "/Game/Blueprints/Projectiles/Projectile_Rocket_Sapper.Projectile_Rocket_Sapper_C",
    GrenadeExor = "/Game/Blueprints/Projectiles/Projectile_ExorGrenade.Projectile_ExorGrenade_C", -- meshless (red orb) + biotic explosion

    DiscPlasma = "/Game/Blueprints/Projectiles/Projectile_Disc_Plasma.Projectile_Disc_Plasma_C",
    DiscTurret = "/Game/Blueprints/Projectiles/Projectile_Disc_Turret.Projectile_Disc_Turret_C", -- preload this if using Disc Turrets
    DiscLodestone = "/Game/Blueprints/Projectiles/Projectile_Disc_Lodestone.Projectile_Disc_Lodestone_C",
    
    SnowmanFrostSpray = "/Game/Blueprints/Projectiles/Projectile_Snowman_FrostSpray.Projectile_Snowman_FrostSpray_C",
    -- The throwable snowball (row projectile_snowball). Visible SM_Throwable_Snowball, and its
    -- DamageType is the bare Abiotic_DamageType_ParentBP - NO tags, so it matches no weakness,
    -- resistance or immunity query and lands flat on everything.
    Snowball = "/Game/Blueprints/Projectiles/Projectile_Snowball.Projectile_Snowball_C",
    PeccaryIceBall = "/Game/Blueprints/Projectiles/Projectile_Peccary_IceBall.Projectile_Peccary_IceBall_C",
    PlasmaBall = "/Game/Blueprints/Projectiles/Projectile_SMG_PlasmaBall.Projectile_SMG_PlasmaBall_C", -- Adv SMG, Plasmosis Rifle
    SmgFireball = "/Game/Blueprints/Projectiles/Projectile_SMG_Fireball.Projectile_SMG_Fireball_C", -- Toaster SMG
    CarbuncleSpike = "/Game/Blueprints/Projectiles/Projectile_CarbuncleSpike.Projectile_CarbuncleSpike_C", -- non-homing quill? 
    
    ExorSpike = "/Game/Blueprints/Projectiles/Projectile_ExorSpike.Projectile_ExorSpike_C", -- homing
    QuillSpear = "/Game/Blueprints/Projectiles/Projectile_ExorSpike_QuillSpear.Projectile_ExorSpike_QuillSpear_C", -- faster quill
    QuillRifle = "/Game/Blueprints/Projectiles/Projectile_ExorSpike_QuillRifle.Projectile_ExorSpike_QuillRifle_C",
    
    -- TWO NET CLASSES, and the difference is the DEBUFF, not the mesh (both SM_Net_Projectile).
    --   Net         row projectile_net_ammo -> Debuff_NettedCannon: the 4s stun PLUS a 5-dmg/0.5s
    --               electric DoT. That DoT re-enters ProcessDamage per tick, so on an NPC victim in
    --               a crowd it is the S6 teardown family - prefer NetThrowable for NPC-facing nets.
    --   NetThrowable row projectile_net -> Debuff_Netted: the same 4s stun, NO DoT, no damage at all.
    -- BOTH ship BuffsIgnoreAllies = true, so their buff step SKIPS any player-faction victim (they
    -- are player tools). An NPC that wants to net a PLAYER must clear that bool on the spawned
    -- actor - Projectile.Queue's opts.PreFinish. See the Trident (AnteNPCs/OrderCaptainHelpers).
    -- Both also carry ImpactItem "net" + SpawnImpactItemAfterHit, i.e. every shot drops a lootable
    -- net unless PreFinish turns that off too.
    Net = "/Game/Blueprints/Projectiles/Projectile_Ammo_Net.Projectile_Ammo_Net_C",
    NetThrowable = "/Game/Blueprints/Projectiles/Projectile_Throwable_Net.Projectile_Throwable_Net_C",
    HolyFireball = "/Game/Blueprints/Projectiles/Projectile_HolyFireball.Projectile_HolyFireball_C",
    Molotov = "/Game/Blueprints/Projectiles/Projectile_ThermiteMolotov.Projectile_ThermiteMolotov_C",
    MolotovDefenseBot = "/Game/Blueprints/Projectiles/Projectile_Molotov_DefenseBot.Projectile_Molotov_DefenseBot_C",
    MortarDefenseBot = "/Game/Blueprints/Projectiles/Projectile_Grenade_Mortar_DefenseBot.Projectile_Grenade_Mortar_DefenseBot_C",
    FragDefenseBot = "/Game/Blueprints/Projectiles/Projectile_Grenade_Frag_DefenseBot.Projectile_Grenade_Frag_DefenseBot_C",
    ScrapshotRound = "/Game/Blueprints/Projectiles/Projectile_ScrapshotShotgunRound.Projectile_ScrapshotShotgunRound_C",
    -- The Thumper Shotgun's acid round (row projectile_shotgun_bounceShot, 9 per player shot).
    -- 5500 speed, gravity 0, ONE bounce at full bounciness, no AoE and no row debuff;
    -- DamageType_Acid_Accuracy, so preload that (DamageType.AcidAccuracy) with it. Meshless -
    -- the visible round is the class's own Niagara, so pass no mesh.
    ShotgunBounceShot = "/Game/Blueprints/Projectiles/Projectile_Shotgun_BounceShot.Projectile_Shotgun_BounceShot_C",

    MagmaFireball = "/Game/Blueprints/Projectiles/Projectile_MagmaSkinkFireball.Projectile_MagmaSkinkFireball_C",
    -- DamageType_Fire, on impact it drops a blue AreaEffect_MolotovBurn_Mage (applies Debuff_Ignited_Plasma)
    --   * Lob it like the Molotov (GravityScale) for a plasma mortar.
    --   * HideMesh + a plasma TrailFX reskins the comet blue.
    --   * Preload the patch (Preload) so its impact spawn can't blocking-load in-hook.
    MageFireball = "/Game/Blueprints/Projectiles/Projectile_MageFireball.Projectile_MageFireball_C",
    -- The Vacuum's alt-fire lightning orb (SM_Sphere_Lightning): 150/150 Explosive AoE, NO
    -- debuffs (no S6 preload tail). The Astral Magus' shot - slowed per spawn by the helpers.
    ShadowOrbVacuum = "/Game/Blueprints/Projectiles/Projectile_ShadowOrb_Vacuum.Projectile_ShadowOrb_Vacuum_C",

    
    BioBall = "/Game/Blueprints/Projectiles/Projectile_BioBall.Projectile_BioBall_C",
    -- Electron-grenade shard. 2000 speed, gravity 0, bounces x3, DamageType_Sharp off its row.
    -- No mesh and no trail of its own - the visible round is the parent's glint, which is why it
    -- reads as almost nothing without a trail welded on (the Abjurer's spore bolt).
    ElectronCrystal = "/Game/Blueprints/Projectiles/Projectile_ElectronCrystal.Projectile_ElectronCrystal_C",
    GrenadeElectron = "/Game/Blueprints/Projectiles/Projectile_Electron_Grenade.Projectile_Electron_Grenade_C",

    -- Unshipped in native, unknown effect
    RocketEMP = "/Game/Blueprints/Projectiles/Projectile_Rocket_EMP.Projectile_Rocket_EMP_C",

    FlaskBlizzard = "/Game/Blueprints/Projectiles/Projectile_Flask_Blizzard.Projectile_Flask_Blizzard_C",
    FlaskCharging = "/Game/Blueprints/Projectiles/Projectile_Flask_Charging.Projectile_Flask_Charging_C",
    FlaskConcussive = "/Game/Blueprints/Projectiles/Projectile_Flask_Concussive.Projectile_Flask_Concussive_C",
    FlaskCorrosive = "/Game/Blueprints/Projectiles/Projectile_Flask_Corrosive.Projectile_Flask_Corrosive_C",
    FlaskHoly = "/Game/Blueprints/Projectiles/Projectile_Flask_Holy.Projectile_Flask_Holy_C",
    FlaskMegaton = "/Game/Blueprints/Projectiles/Projectile_Flask_Megaton.Projectile_Flask_Megaton_C",
    FlaskPanic = "/Game/Blueprints/Projectiles/Projectile_Flask_Panic.Projectile_Flask_Panic_C",
    FlaskPortal = "/Game/Blueprints/Projectiles/Projectile_Flask_Portal.Projectile_Flask_Portal_C",
    FlaskRestorative = "/Game/Blueprints/Projectiles/Projectile_Flask_Restorative.Projectile_Flask_Restorative_C",
    FlaskUnstable = "/Game/Blueprints/Projectiles/Projectile_Flask_Unstable.Projectile_Flask_Unstable_C",
    FlaskUpdraft = "/Game/Blueprints/Projectiles/Projectile_Flask_Updraft.Projectile_Flask_Updraft_C",
    -- Harpoon = "/Game/Blueprints/Projectiles/Projectile_Harpoon.Projectile_Harpoon_C",
    -- Laser grenade. It does NOT explode - it bounces, fuses, then Detonate() walks eight
    -- auto-aiming LaserComponents out of it one at a time (LaserStartOffset 0.4s apart), each
    -- re-aimed every 0.1s at a random character within 600uu. Two per-instance knobs:
    --   * DamageFromWeapon -> every beam's LaserDamage.
    --   * ChangeableData.LiquidLevel + LaserStartOffset -> how long the beams last. The eight
    --     beams come up ONE AT A TIME, LaserStartOffset (0.4) apart, hold for GetLaserDuration
    --     (LiquidLevel/10 * 6s), then go down one at a time on the same spacing - so the total is
    --     16*LaserStartOffset + 0.6*LiquidLevel, and at the default offset the ramps are 6.4s of
    --     it. Liquid alone is only the middle hold; Liquid 0 = it does nothing at all.
    -- Ships SpawnImpactItemAfterHit, so an NPC's throw drops a lootable grenade unless cleared.
    GrenadeLaser = "/Game/Blueprints/Projectiles/Projectile_Grenade_Laser.Projectile_Grenade_Laser_C",

}


-- =======================================================================
-- Projectile row names - we use these to replace a projectile path
-- ex: Replacing a grenade or a weapon
--   * Native should handle replication and loading
-- =======================================================================
AnteEnums.ProjectileRows = {
    -- BioCannon goo lob (Esoteric Chieftain sci-gun). 2700 speed, gravity 1, AoE 50/200.
    BioBall          = "projectile_bioball",
    -- Scientist electron grenade. 1500 speed, gravity 1, bouncy (0.5); scatters ElectronCrystal shards.
    ElectronGrenade  = "projectile_electron_grenade",
    -- Magma-skink glob (Antegrav Exor quill-burst reskin). Ignites + drops an AreaEffect_MagmaSkink
    -- fire patch on impact. (New-update row, absent from the stale DT_Projectiles export.)
    MagmaSkinkBall   = "projectile_magmaskinkball",
    -- Blue plasma bolt (plasma Exor). 5500 speed, gravity 0; DamageType_Fire_Plasma, ignites (Debuff_Ignited_Plasma).
    PlasmaBall       = "projectile_smg_plasmaball",
    -- RED fireball - what the Toaster SMG (item row smg_military_U1) fires. 5000 speed, gravity 0,
    -- AoE 50/200, DamageType_Fire_Accuracy (ignites via Debuff_Ignited - applied on the NATIVE
    -- impact, so FireRanged_Projectile needs no debuff preload). Jotun Rocketeer's gun.
    SmgFireball      = "projectile_smg_fireball",

    -- The throwable snowball. 2000 speed (max 3000), gravity 1, no AoE, untagged damage type.
    -- It ships CanDealDamage = FALSE - the game's harmless toy, and the only visible-mesh row that
    -- does. Fired down the native gun path it flies, lands, plays its FX and deals NOTHING,
    -- silently. Throw it with PROJ.SpawnGrenade + opts.ArmDamage instead; never edit the row, the
    -- player's own snowballs read it. See AnNotes/AnteSystems/Projectile.md.
    Snowball         = "projectile_snowball",
    -- No visible projectile but does freeze. AoE row (100/350, falloff 0.5) -> PROJ.Queue MUST pass
    -- DamageTypeClass = ENUMS.DamageType.Cold (the arm races the native latent type load).
    SnowmanFrost     = "projectile_snowmanfrost",
    -- The Snow Peccary's ice ball (see ProjectileClasses.PeccaryIceBall). Its native ProjectileRow.
    SnowPeccaryBomb  = "projectile_snowpeccarybomb",
    -- Blue plasma DISC (Warrior Witch gun; disc-launcher ammo). 5000 speed, gravity 0, NO bounce, small
    -- Fire AoE (25/120) that ignites via Debuff_Ignited. Fired NATIVELY via FireRanged_Projectile
    -- (no per-shot LoadAsync chop, replicates free) - not PROJ.Queue. Deals Fire on native impact.
    DiscPlasma       = "projectile_disc_plasma",
    -- OURS, not the game's: DiscPlasma cloned at runtime with a slower flight (AnteCore/ProjectileRows).
    -- Exists only once ProjectileRows.Apply has run in this world - fire via ProjectileRows.Fire,
    -- which refuses a row that is not ready.
    BotDisc          = "anteup_disc_plasma_bot",        -- 2000 speed
    BotDiscSlow      = "anteup_disc_plasma_bot_slow",   -- 1000 speed
    AntefirePlasma   = "anteup_plasmaball_antefire",    -- PlasmaBall at 1800 (ships 5500)
    PatriarchDisc    = "anteup_disc_plasma_patriarch",  -- DiscPlasma at 1500
    WitchJetFireball = "anteup_magefireball_witchjet",  -- MageFireball at 1300, gravity 0 (ships 1500 / 0.1)
    -- OURS too: FLIGHT rows for scripted shots (PROJ.Queue opts.FlightRow). They carry the gravity,
    -- homing and bounce a remote client would otherwise take from the class's own row; speed stays
    -- per shot. Numbers live in AnteCore/ProjectileRows.
    FireballLob      = "anteup_magefireball_lob",       -- MageFireball under full gravity (ships 0.1)
    EyeDisc          = "anteup_disc_plasma_eye",        -- DiscPlasma, slow and homing (ships 5000, no homing)
    MolotovFlat      = "anteup_molotov_flat",           -- Molotov, gravity 0 (ships 1)
    SeekerQuill      = "anteup_quillspear_seeker",      -- QuillSpear at 600 / homing 800 (ships 2000 / 20000)
    DislocatorSpear  = "anteup_quillspear_dislocator",  -- QuillSpear at 1000 / homing 800, bigger (a NATIVE-gun row)
    HardlightBolt    = "anteup_spear_hardlight_flat",   -- hardlight spear, gravity 0 (ships 1)
    NetFlat          = "anteup_net_flat",               -- net, gravity 0 (ships 0.8)
    HolyBoltFlat     = "anteup_holyfireball_flat",      -- holy fireball, gravity 0 (ships 0.3)
    ThrownAxe        = "anteup_thrownweapon_axe",       -- thrown weapon, gravity 0.25 (ships 0.6)
    OfficeThrow      = "anteup_thrownitem_office",      -- generic thrown item, gravity 0.45, no bounce
    OfficeDirect     = "anteup_thrownitem_flat",        -- ...and gravity 0
    -- IDENTITY rows: a copy of the row the class already flies, so a remote client can tell OUR
    -- shot from a player's or a native NPC's and dress it (PR.LOOKS / AnteVariants/ClientProjectiles).
    EyeFlask         = "anteup_flask_corrosive_eye",    -- Beholder Verdant
    EyeSeeker        = "anteup_exorspike_eye",          -- Beholder Violet
    GhostOrb         = "anteup_shadoworb_ghost",        -- DarkLens Magus filler bolt (homing off)
    FireMortar       = "anteup_molotov_mortar",         -- Magma Exor reload shell
    PlasmaMortar     = "anteup_magefireball_mortar",    -- Antefire Exor reload shell (full gravity)
    LamogiBolt       = "anteup_plasmaball_lamogi",      -- Tamed Lamogi
    -- Donors for the above that had no key of their own.
    Molotov          = "projectile_thermitemolotov",
    ThrownWeapon     = "projectile_thrownweapon",
    ShadowOrb        = "projectile_shadoworb",          -- what a directly spawned ShadowOrb_Vacuum flies (its CDO handle)
    -- HOLY disc (lodestone disc-launcher ammo). 5000 speed, BOUNCES x6, spinning grinder-disc
    -- mesh. DamageType_Psychic_Holy_Bolt (the body-shield-BYPASSING holy family) + row buff
    -- Debuff_Ignited_Holy on the NATIVE impact (no debuff preload needed for the fire itself -
    -- the SmgFireball rule). Purified Interfector's thrown disc, via FireProjectileRow.
    DiscLodestone    = "projectile_disc_lodestone",
    -- Plain Exor quill. 1200 -> 7000 speed, gravity 0, GENTLE homing (accel 800). DamageType_Sharp_ExorQuill.
    ExorSpike        = "projectile_exorspike",
    -- Carbuncle spike. 800 speed, gravity 0, no homing - a slow, easily-dodged quill.
    CarbuncleSpike   = "projectile_carbunclespike",
    -- Electron crystal shard. 2000 speed, gravity 0, bounces x3.
    ElectronCrystal  = "projectile_electroncrystal",
    -- Science bolt. 5000 speed, gravity 0.17, no AreaEffect patch - a clean fast bolt.
    ScienceBolt      = "projectile_sciencebolt",
    -- Thrown net. 2250 speed, gravity 0.8 (arcs), radius 20; deals no damage (native snare is NPC-only).
    NetAmmo          = "projectile_net_ammo",
    -- Preacher holy fireball. 1500 speed, gravity 0.3, AoE 100/250; drops an AreaEffect_MolotovBurn_Holy patch.
    HolyFireball     = "projectile_holyfireball",
    -- Defense-bot mortar shell. High lob (InitialSpeed 0, gravity 1); big AoE 350/600 on contact.
    DefenseBotMortar = "projectile_defensebotmortar",
    -- EMP rocket. TEST - see ProjectileClasses.RocketEMP: possibly unimplemented; a missing row
    -- makes FireRanged_Projectile skip the spawn silently (logs "bad projectile"), nothing worse.
    RocketEMP        = "projectile_rocket_emp",

    -- Green homing quills
    QuillRifle = "projectile_exorspike_quillrifle",
    QuillSpear = "projectile_exorspike_quillspear",
    -- Thrown FLASK rows (Sapper native-throw redirect). Confirmed from the flask BPs'
    -- ProjectileDataRowHandle; absent from the stale DT_Projectiles export. Megaton is deliberately
    -- omitted here - it one-shots players.
    FlaskCorrosive   = "projectile_flask_corrosive",   -- acid pool on impact
    FlaskHoly        = "projectile_flask_holy",         -- holy fire patch
    FlaskUpdraft     = "projectile_flask_updraft",       -- launches targets upward (LaunchVelocity 1100, 0 dmg)
    -- The Mage's fireball. DamageType_Fire_Plasma (ignites via Debuff_Ignited_Plasma - loads off-hook
    -- on the native impact, so FireRanged_Projectile needs no preload). Speed 1500.
    MageFireball     = "projectile_magefireball",
    -- Blue lightning orb: 4500 speed / gravity 0 / Explosive 150-150 AoE / no debuffs.
    ShadowOrbVacuum  = "projectile_shadoworb_vacuum",
    FlaskConcussive  = "projectile_flask_concussive",   -- stun / knockback
    FlaskUnstable    = "projectile_flask_unstable",     -- volatile blast
    FlaskPortal      = "projectile_flask_portal",       -- teleport
    -- What the game itself uses when a player throws a non-weapon item
    --   * Uses Projectile_ThrownWeapon. It does blunt instead of sharp
    --   * Can overwrite a thrown projectile with this to make that do blunt damage *or bounce
    --       - ProjectileDataRowHandle pre-finish, otherwise DamageType is overwritten as part of its load
    ThrownGenericItem = "projectile_throwngenericitem",

    -- Thrown hardlight spear
    HardlightSpear = "projectile_spear_hardlight",
}



-- DamageType blueprint CLASSES (subclasses of the damage-type parent, ENUMS.DamageType.Parent, in
-- /Game/Blueprints/DamageTypes). Pass to AVU.ChangeDamageType to re-theme an NPC's attack, hand to
-- ApplyRadialDamage/ApplyPointDamage, or list in def.Assets to preload. 126 exist; this is the
-- curated set we reach for - add more as needed. Path: DamageType_<Name>.DamageType_<Name>_C.
--   * There is NO E_DamageTypes enum. The game categorises by GAMEPLAY TAGS (DamageType.Sharp,
--     DamageType.Holy, ...) listed in DT_DamageDefinitions, and NPC weakness/resist/immunity are
--     FGameplayTagQuery columns on DT_NPCList. See [[af-damage-types]].
--   * ALWAYS PRELOAD a DamageType you pass to a damage call: StaticFindObject returns nil if the BP
--     isn't resident, and a damage event whose type is NOT a subclass of that parent
--     deals ZERO damage (DistributeDamageThroughLimbs bails with a red log line).
local function dtClass(name)
    return "/Game/Blueprints/DamageTypes/DamageType_" .. name .. ".DamageType_" .. name .. "_C"
end
AnteEnums.DamageType = {
    -- elemental / category bases
    Acid       = dtClass("Acid"),
    Bleeding   = dtClass("Bleeding"),
    Blunt      = dtClass("Blunt"),
    ChokingGas = dtClass("ChokingGas"),
    Cold       = dtClass("Cold"),
    ColdFreeze = dtClass("Cold_FreezeTarget"), -- any hit freezes, so preload Debuff_Frost. This extends Blunt and may read as such
    Drowning   = dtClass("Drowning"),   -- suffocation type (Mage choke)
    Electric   = dtClass("Electric"),
    Explosive  = dtClass("Explosive"),
    ExplosiveDefenseBot = dtClass("Explosive_DefenseBot"),   -- defense-bot mortar/frag (no debuff)
    Fire       = dtClass("Fire"),
    Laser      = dtClass("Laser"),
    LaserGib   = dtClass("Laser_Gib"),   -- what laser guns deal in overdrive
    Psychic    = dtClass("Psychic"),
    Radiation  = dtClass("Radiation"),
    Sharp      = dtClass("Sharp"),
    -- specific subclasses
    BulletGeneric = dtClass("BulletGeneric"),
    -- What every Exor quill (projectile_exorspike and the two rifle rows) deals. Plain Sharp tags
    -- inherited from its parent, so it bleeds and NpcResistances reads it as "Sharp".
    SharpExorQuill = dtClass("Sharp_ExorQuill"),
    BulletSniper  = dtClass("Bullet_Sniper"),
    PsychicMonk   = dtClass("Psychic_Monk"),
    BluntStompSquish = dtClass("Blunt_StompSquish"),   -- Tamed Chonky Pest landing slam
    -- What ProjectileRows.ThrownGenericItem carries - plain Blunt tags, no debuff, plus a
    -- Throwing-skill XP award. Preload it alongside that row: a thrown projectile latent-loads
    -- its own type at BeginPlay, and a cold one lands before the load does (untyped, no resists).
    BluntThrownXP = dtClass("Blunt_ThrownXP"),
    -- The DEFAULT type of ProjectileRows.ThrownWeapon, i.e. what any thrown weapon deals unless the
    -- row is swapped. Plain Sharp tags, so it BLEEDS - preload BuffObjects.Bleeding with it.
    SharpThrownXP = dtClass("Sharp_ThrownXP"),
    FirePlasma    = dtClass("Fire_Plasma"),   -- Re-applies Debuff_Ignited_Plasma
    AcidVolatile  = dtClass("Acid_VolPestExplode"), -- Preload Debuff_AcidBurn
    AcidBurn      = dtClass("Acid_Burn"),   -- what Debuff_AcidBurn's own DoT ticks deal
    -- What ProjectileClasses.ShotgunBounceShot deals. Plain Acid tags inherited from
    -- DamageType_Acid (it only adds an Accuracy XP award) and NO debuff, so it needs no buff preload.
    AcidAccuracy  = dtClass("Acid_Accuracy"),

    FireHoly      = dtClass("Fire_Holy"), -- ignores armor but not bodyshields, plus Debuff_Ignited_Holy
    PsychicHoly   = dtClass("Psychic_Holy"), -- ignores armor and bodyshields
    PsychicHolyBolt = dtClass("Psychic_Holy_Bolt"), 
    HolyBullet    = dtClass("HolyBullet"), -- ignores nothing, can bleed

    -- despite it being plasma it counts as laser for BodyShield damage
    LaserHardlight = dtClass("Laser_Gib_Hardlight"), -- Hardlight weapons

    ShieldNeutralizer = dtClass("ShieldNeutralizer"), -- null grenade

    -- abstract parent class (not a DamageType_* row. Doesn't fit dtClass): a Blueprint on the old
    -- game build, C++ UAbioticDamageType on the new (SCHEMA.Path)
    Parent = SCHEMA.Path.DamageTypeParent,
}



-- =======================================================================
-- AF Enums/Structs
-- =======================================================================

-- ETraceTypeQuery values for line traces (AVU.IsPathBlocked and every caller that names a channel).
-- The enum is 0-BASED: TraceTypeQuery1 = 0 is Visibility, TraceTypeQuery2 = 1 is Camera, and the
-- game's own channels follow. 3 is TraceTypeQuery4 - the default of the game's MELEE sweep
-- (Abiotic_Character_ParentBP CurrentMeleeingData.TraceChannel), which some cave and wall meshes
-- ignore; the game's own eye-to-target sight trace passes 0. Never write a channel literal at a
-- call site.
AnteEnums.Trace = {
    VISIBILITY = 0,
    CAMERA     = 1,
    MELEE      = 3,   -- the melee sweep channel; not a wall test
}

-- Engine_enums.EMovementMode
AnteEnums.MovementMode = {
    NONE = 0,
    WALKING = 1,
    NAVWALKING = 2,
    FALLING = 3,
    SWIMMING = 4,
    FLYING = 5,
    -- CUSTOM = 6,
    -- MAX = 7
}

-- Engine_Enums_EbodyLimbs
AnteEnums.EBodyLimbs = {
    AllBones = 0,
    RandomBone = 1,
    RandomBoneExceptHead = 2,
    Head = 3,
    Torso = 4,
    LeftArm = 5,
    RightArm = 6,
    LeftLeg = 7,
    RightLeg = 8,
    EBodyLimbs_MAX = 9,
}

-- Not referenced directly in most cases 
--   * These need to be preloaded to prevent ue4ss deadlock freezes (S2) 
--   * Why?
--     - DamageType
--       > Loading the DamageType class does not pull in buffs
--       > When damage lands, ProcessDamage applies that debuff (Server_ApplyBuff), 
--       > This blocking loads the object if not in memory
--     - Hooks
--       > Utils.QueueWork can drain inside a hook - a cold load causing a deadlock
--       > Harder to catch because the damage type/debuff may be warm
--   * So preload both. Similar to soft-ref DamageType preloads in PROJ.Queue opts.Preload 
--       ([[anteup2-projectile-preload-gc]]).
AnteEnums.BuffObjects = {

    -- What DamageType_Acid_Burn / DamageType_Acid_VolPestExplode apply 
    --   * Extends BuffObject_HPDamage (10 dmg per 0.5s tick, dealt as DamageType_Acid)
    --   * Preload DamageType_Acid too
    AcidBurn = "/Game/Blueprints/BuffsDebuffs/BuffObject_AcidBurn.BuffObject_AcidBurn_C",
    HPDamage = "/Game/Blueprints/BuffsDebuffs/BuffObject_HPDamage.BuffObject_HPDamage_C",

    -- What Debuff_Ignited (and DamageType_Fire - DebuffsCanApply) can apply
    --   * Extends BuffObject_HPDamage (5 dmg per 0.5s tick, dealt as DamageType_Fire)
    --   * Preload HPDamage + DamageType.Fire as well
    --   * DamageType_Fire does not autopull this in - S2 if pulled from a hook drained path
    Ignited = "/Game/Blueprints/BuffsDebuffs/BuffObject_Ignited.BuffObject_Ignited_C",

    -- What Debuff_Ignited_Holy applies 
    --   * DamageType_Fire_Holy's DebuffsCanApply_LowDmg entry
    --   * Preload HPDamage + DamageType.FireHoly alongside it
    --   * Fire_Holy does not autopull this in - S2 if pulled from a hook drained path
    IgnitedHoly = "/Game/Blueprints/BuffsDebuffs/BuffObject_Ignited_Holy.BuffObject_Ignited_Holy_C",

    -- What Debuff_Ignited_Plasma applies 
    --   * DamageType_Fire_Plasma's DebuffsCanApply entry
    --   * Rides every plasma projectile or source
    --   * Fire_Plasma does not autopull this in - S2 if pulled from a hook drained path
    IgnitedPlasma = "/Game/Blueprints/BuffsDebuffs/BuffObject_Ignited_Plasma.BuffObject_Ignited_Plasma_C",

    -- What Debuff_Frost / Debuff_Flask_Blizzard / Debuff_SniperRifleIce apply 
    --   * Frost applies run through ApplyBuffLinked / BuffPlayersInRadius (EIGT, genuinely off-hook)
    --   * won't deadlock, but need to warm this to prevent loading hitches
    StunnedFrozen = "/Game/Blueprints/BuffsDebuffs/BuffObject_Stunned_Frozen.BuffObject_Stunned_Frozen_C",

    -- What Debuff_Zapped / Debuff_ZappedPurple / Debuff_ParryStun apply
    --   * Preload alongside the row's OWN BodyParticleEffect wherever the stun is self-applied and
    --     off a hook, or the first one can deadlock.
    --   * THE TWO ZAPPED ROWS USE DIFFERENT FX, and picking the wrong one silently loses the
    --     preload (the render colour still comes from the row, so nothing LOOKS wrong - the blue
    --     one just cold-loads on first use, which is the exact hitch the preload exists to stop):
    --       Debuff_Zapped       -> Effects.LIGHTNING_STUN    (blue)   + M_Electricity_Shock
    --       Debuff_ZappedPurple -> Effects.LIGHTNING_PURPLE  (purple) + M_Electricity_Shock_Purple
    --     Debuff_NettedCannon has NO BodyParticleEffect at all, only the blue shock material.
    Stunned = "/Game/Blueprints/BuffsDebuffs/BuffObject_Stunned.BuffObject_Stunned_C",

    -- What Debuff_Netted / Debuff_NettedCannon apply. EXTENDS BuffObject_Stunned, so a net is a
    -- REAL stun on players too (Modifier.Stunned gates ~25 input paths in Abiotic_PlayerCharacter);
    -- the NPC_Base cast inside it is only the NetDurationReductionPercentage shortener.
    --   * A net projectile names its debuff by ROW, so loading the projectile does NOT pull this in
    --     - preload it with any net fired from a drained path (the S6 debuff-preload trap).
    Netted = "/Game/Blueprints/BuffsDebuffs/BuffObject_Netted.BuffObject_Netted_C",
    -- What Debuff_NettedCannon applies - the NET GUN's round, and the one the game itself fires at
    -- NPCs. Extends BuffObject_Netted, adds Modifier.Netted.Strong (NPC_Base's Netted state 2, the
    -- one the net MESH and the controller's IsNetted read) plus a 5-dmg/0.5s electric tick, so
    -- preload DamageType.Electric with it.
    NettedCannon = "/Game/Blueprints/BuffsDebuffs/BuffObject_Netted_Cannon.BuffObject_Netted_Cannon_C",

    -- Stat floor trap. ModifyStat_Hunger/Thirst - if modifying a debuff could be applied.
    --   * Debuff_Starving / Debuff_Parched
    --   * Mild hunger/thirst rows don't have buff logic and are fine
    SuddenDeathThirst = "/Game/Blueprints/BuffsDebuffs/BuffObject_SuddenDeath_Thirst.BuffObject_SuddenDeath_Thirst_C",
    SuddenDeathHunger = "/Game/Blueprints/BuffsDebuffs/BuffObject_SuddenDeath_Hunger.BuffObject_SuddenDeath_Hunger_C",

    -- The stat CEILING sibling of the two above, and the only one on the fatigue ladder.
    -- ModifyStat_Fatigue -> CheckForFatigueDebuffs applies by ROW NAME at three thresholds:
    --   Fatigue/MaxFatigue >= 0.75 -> Debuff_Sleepy  (no BuffLogic_Object - nothing to load)
    --   >= FatigueRequiredToSleep  -> Debuff_Tired   (same)
    --   >= 0.90                    -> Debuff_Exhausted -> THIS, which no normal session has resident
    -- So only a POSITIVE fatigue modify big enough to cross 0.90 can cold-load, and the Twilight
    -- Sniper is the one thing in the mod that does it on purpose. Preload at fire time.
    FatigueExhausted = "/Game/Blueprints/BuffsDebuffs/BuffObject_Fatigue_Exhausted.BuffObject_Fatigue_Exhausted_C",

    -- What Debuff_BeeSwarm (AnteEnums.Debuffs.BeeSwarm) applies - 
    --   (!) This needs a LinkedActor - by default it fades if victim is > 20m from source
    --       Without it, it will sting forever
    -- the target gets 20m from the source). Measured GC-cycling 6x in one session (2026-08-08
    -- long-play log) - kept resident via the AssetKeeper CLASS keep-set.
    BeeSwarm = "/Game/Blueprints/BuffsDebuffs/BuffObject_BeeSwarm.BuffObject_BeeSwarm_C",

    -- What DamageType_Sharp's DebuffsCanApply rows apply. Which of the two you get is picked by
    -- the DamageType parent's SeverityLevels against the damage of THAT hit (descending 350/250/
    -- 150/50): under 50 no bleed at all, 50-149 Bleeding, 150+ SevereBleeding.
    --   * Loading DamageType.Sharp does NOT pull either in - the row names them (the S6 trap), so
    --     preload alongside any scripted Sharp hit big enough to reach them.
    Bleeding = "/Game/Blueprints/BuffsDebuffs/BuffObject_Bleeding.BuffObject_Bleeding_C",
    SevereBleeding = "/Game/Blueprints/BuffsDebuffs/BuffObject_SevereBleeding.BuffObject_SevereBleeding_C",

    -- What Debuff_Sick applies - the 90s vomit gag (DoVomitingSequence). Nothing in a normal
    -- session holds it resident, so preload it with any scripted Sick apply (the Signal Pest).
    Sick = "/Game/Blueprints/BuffsDebuffs/BuffObject_Sick.BuffObject_Sick_C",

    -- What Debuff_Spores applies - the 120s sneeze that draws aggro and infects nearby players.
    -- Same preload rule as Sick; only the mushroom families ever apply it.
    Spores = "/Game/Blueprints/BuffsDebuffs/BuffObject_Spores.BuffObject_Spores_C",

    -- What Debuff_Concussed applies. An ACTOR, not an object (BuffLogic_Actor), but the same
    -- preload rule: the row names it, so nothing else pulls it in and a scripted concussion
    -- cold-loads on first use.
    ConcussedActor = "/Game/Blueprints/BuffsDebuffs/Actors/BuffActor_Concussed.BuffActor_Concussed_C",

    -- What Debuff_Stinky applies - a per-tick UAISense_Hearing::ReportNoiseEvent at 1200uu
    -- ("stinky"), i.e. the target keeps announcing itself to every NPC that can hear. Same
    -- preload rule as Sick; the game only ever applies it from poop/liquid deployables, so it
    -- is cold in a normal fight.
    Stinky = "/Game/Blueprints/BuffsDebuffs/BuffObject_Stinky.BuffObject_Stinky_C",

    -- What Buff_GravityCube applies - the trinket, a held cube, and ItemMods' carried-cube poll.
    -- Only sets FallDamageResistance 0.25; the gravity itself is the row's Gravity_Mulitply -50.
    GravityCube = "/Game/Blueprints/BuffsDebuffs/BuffObject_GravityCube.BuffObject_GravityCube_C",

    -- What the trinket rows ItemMods' InventoryTrinkets grants apply: seven buff objects, three buff actors.
    CoreCompanion     = "/Game/Blueprints/BuffsDebuffs/Buff_CoreCompanion.Buff_CoreCompanion_C",
    LootBoot          = "/Game/Blueprints/BuffsDebuffs/Buff_LootBoot.Buff_LootBoot_C",
    CrystalLens       = "/Game/Blueprints/BuffsDebuffs/Traits/BuffObject_CrystalLens.BuffObject_CrystalLens_C",
    CrystalCurrent    = "/Game/Blueprints/BuffsDebuffs/Traits/BuffObject_CrystalCurrent.BuffObject_CrystalCurrent_C",
    FriendFinderActor = "/Game/Blueprints/BuffsDebuffs/Actors/BuffActor_FriendFinder.BuffActor_FriendFinder_C",
    KylieActor        = "/Game/Blueprints/BuffsDebuffs/Actors/BuffActor_Kylie.BuffActor_Kylie_C",
    ShieldGenerator      = "/Game/Blueprints/BuffsDebuffs/Buff_ShieldGenerator.Buff_ShieldGenerator_C",
    ShieldGeneratorU1b   = "/Game/Blueprints/BuffsDebuffs/Buff_ShieldGenerator_U1b.Buff_ShieldGenerator_U1b_C",
    ShieldGeneratorKylie = "/Game/Blueprints/BuffsDebuffs/Buff_ShieldGenerator_Kylie.Buff_ShieldGenerator_Kylie_C",
    KylieGeneratorActor  = "/Game/Blueprints/BuffsDebuffs/Actors/BuffActor_Kylie_Generator.BuffActor_Kylie_Generator_C",
}

-- Debuffs that can be set so an NPC is immune to it
AnteEnums.Debuffs = {
    Netted = "Debuff_Netted",
    NettedCannon = "Debuff_NettedCannon",
    Bleeding = "Debuff_Bleeding",
    SevereBleeding = "Debuff_SevereBleeding",
    ShockTrap = "Debuff_ShockTrap",
    Zapped = "Debuff_Zapped",
    ZappedPurple = "Debuff_ZappedPurple",
    Ignited = "Debuff_Ignited",
    IgnitedHoly = "Debuff_Ignited_Holy",
    IgnitedPlasma = "Debuff_Ignited_Plasma",   -- BLUE plasma fire (Debuff_Ignited_Plasma)
    -- The movement slows. All three are PURE STAT rows - no BuffLogic object or actor, no FX - so
    -- none can cold-load, which is rare for a debuff worth applying.
    --   * Speed_Multiply is a PERCENT delta, but SpeedMultiplyMinimum_Add floors it at 60% by
    --     default, so no ordinary slow can take anything below 60: TurtleMode is written -50 and
    --     lands ON the floor at exactly 60%. Only Rooted (-2000, i.e. floor gone) and
    --     Debuff_MGT_FloorGoo (-45, a 15% floor) reach past it.
    --   * OBSERVED: Rooted does NOT take on an NPC (2026-09-05, tested on the Peremptor's melee).
    --     The game only ever applies it from BogmanRoots_BP behind a faction gate, so the NPC path
    --     may simply be unsupported. To stop an NPC use AVU.HoldGround, which zeroes the NPCData
    --     speeds that LocalUpdateWalkSpeed actually reads and skips this stat layer entirely.
    --   * Vine is HIDDEN; TurtleMode is FullVisibility, so it leaves a blank "[No icon]" row in the
    --     player's debuff list. Prefer Vine on players for that reason alone.
    Rooted = "Debuff_Rooted",         -- ~0%, 2s, BlockedByExisting. PLAYERS ONLY - see above
    TurtleMode = "AI_TurtleMode",     -- 60%, 10s, ReplaceExisting, but shows an empty UI row
    VineSlow = "debuff_vine_slow",    -- 70%, 10s, BlockedByExisting, hidden. The tidy player slow
    Fear = "Debuff_Fear",
    Frost = "Debuff_Frost",-- this may be slushies
    Frost2 = "Debuff_Frost_Shield",
    Frost3 = "Debuff_Frost_PeccIceBall",
    -- The Snow Pest's on-hit proc. NOTE the native roll is TAMED-ONLY: NPC_Monster_Pest_Snow's
    -- ApplyPestHitDamageToTarget returns immediately unless the pest carries Buff.Follower.Tamed,
    -- so a WILD Snow Pest never freezes anything. Variants apply it themselves (see PestSnow.lua).
    Frost4 = "Debuff_Frost_SnowPest",
    Frost5 = "Debuff_Frost_Snowman",  -- carried by projectile_snowmanfrost's impact
    -- The Throwing Shard's row buff (projectile_throwing_iceshard.BuffDebuffToApply): a 0.75s
    -- micro-freeze riding every shard hit natively. The Winterfector layers real Frost on top.
    SniperRifleIce = "Debuff_SniperRifleIce",
    -- RESOLVED (2026-08-08, DT_BuffsDebuffs export finally on disk): Debuff_Frost DOES carry a
    -- logic object - BuffObjects.StunnedFrozen (+ NIAGARA_DEBUFF_FROZEN body FX, M_Debuff_Frozen
    -- overlay), and so do FlaskBlizzard and SniperRifleIce. Still safe to apply from hooks via
    -- ApplyBuffLinked / BuffPlayersInRadius (EIGT, off-hook); warm StunnedFrozen +
    -- Effects.NIAGARA_DEBUFF_FROZEN first to dodge the first-apply hitch. Frost row: 5s default,
    -- Speed_Multiply -50, Modifier.Stunned.Frozen.
    FlaskBlizzard = "Debuff_Flask_Blizzard", -- hard 8s freeze (Stunned.Frozen, ReplaceExisting); we re-apply shorter
    Stunned = "Stunned", -- does this work?
    -- BuffObject_Stunned -> grants the "Modifier.Stunned" tag, which makes the PLAYER apply
    -- its PP_Debuff_Stunned post-process (the electricity-edge screen FX of the robot punch).
    ParryStun = "Debuff_ParryStun",
    -- 3.5s screen-shake/disorient + Speed_Multiply -35 (Volatile Exor leap-land, Concussive flask).
    -- Its logic lives in a BuffLogic_ACTOR - preload BuffObjects.ConcussedActor with any scripted apply.
    Concussed = "Debuff_Concussed",
    BeeSwarm = "Debuff_BeeSwarm",   -- the alien-beehive bee swarm (Hive Sow)

    -- Plague set (Pestilence). All four are SAFE on NPCs (their buff objects cast to the shared
    -- character parent, or have no logic object at all), but they differ in what they actually DO:
    AcidBurn = "Debuff_AcidBurn",   -- the volatile pest's own explosion proc (DamageType_Acid_VolPestExplode)
    FlaskCorrosive = "Debuff_Flask_Corrosive",  -- 30s, pure stat mod: DamageReduction_Multiply -30
                                                --   = target takes +30% damage. No BP logic -> zero risk,
                                                --   and it WORKS on NPCs. The best "amplify damage" debuff.
    Sick = "Debuff_Sick",           -- 90s vomit gag. DoVomitingSequence lives on the shared character
                                    --   parent, so an NPC really does vomit (FX + hunger/thirst drain).
    Stinky = "Debuff_Stinky",       -- Its buff object reports a HEARING noise event (1200uu,
                                    --   "stinky") on EVERY tick, so a stinky target is a walking
                                    --   noise beacon - the one debuff that is itself an aggro
                                    --   tool. Safe on NPCs (the logic casts to the shared
                                    --   character parent).
                                    -- NOT A TIMER: the row is bNoExpiration + Buff.Save, so it
                                    --   is WASHED OFF (shower / mop / stain removal), not waited
                                    --   out, and it survives a reload. DefaultDuration reads 10.
    Spores = "Debuff_Spores",       -- 120s "Spore Infection": sneezes, which ReportPlayerSoundToNPCs
                                    --   (draws aggro) and infects other PLAYERS within 550. Its logic
                                    --   casts to Abiotic_PlayerCharacter, so on an NPC it's a safe NO-OP.
    -- "Filthy" - the upper bloodstain threshold, and pure state: no buff object, no FX, no stat mod.
    --   * NOT A TIMER (bNoExpiration, like Stinky): it is washed off in a shower, not waited out.
    --   * Normally driven by BloodStainsData.BloodyLevel, so the game's own CheckForBloodstainDebuffs
    --     can strip a scripted one the next time that level moves. Applying it is a nudge, not a lock.
    Filthy = "Debuff_Bloodsoaked",

    -- Broken-bone set (NPC_Robot_Defense's melee roll picks one of the three at random).
    -- All three are pure StatModifier + a Buff.Treatable.BrokenBone tag - no buff object, no FX,
    -- so nothing to preload - and they are TREATED (splint / cast), not waited out: the row
    -- durations are 300s and LegBroken is bNoExpiration. Sprain and Fracture are -10 speed,
    -- Broken -20; applying a heavier one removes the lighter.
    LegSprain   = "Debuff_LegSprain",
    LegFracture = "Debuff_LegFracture",
    LegBroken   = "Debuff_LegBroken",

    NoCloak = "Debuff_NoCloak",     -- grants the Buff.NoCloak tag -> assassin never re-cloaks
    ReaperTrack = "Debuff_ReaperTeleport",   -- empty marker buff (BuffObject_ReaperTeleport does
                                             -- nothing on its own) - reuse as a 60s "tracked" tag

    -- Taming (pheromone flask). The flask applies Buff_Pheromone, whose logic (Pest/Peccary classes
    -- only) then grants Buff_Passive (the Buff.Follower.Passive pacify state that lets you tame it).
    -- Both go through Server_ApplyBuff, which respects DebuffsImmune - so listing either in an NPC's
    -- DebuffsImmune blocks that step. See AVU.LockTaming (immunize a variant with no pet form).
    Pheromone = "Buff_Pheromone",
    Passive   = "Buff_Passive",
}

-- =======================================================================



AnteEnums.Bones = {
    Pest = {        
    -- "pest_root","Jaw_L","Jaw_R","Jaw2_L","Jaw2_R","Spine1","Spine2",
    -- "Head","hips"
    },
    Peccary = {
    -- Root, hips, Spine1, Spine2, neck, Head, tongue1, tongue2, Tongue3, 
    -- l_jaw1, l_jaw2, r_jaw1, r_jaw2, L_FShoulder, L_FLeg1, L_FLeg2, L_FFoot, 
    -- R_FShoulder, R_FLeg1, R_FLeg2, R_FFoot, 
    -- Belly1, Belly2, quill2, quill1, quill3, quill4, quill5, quill6, quill7, 
    -- quill8, Quill9, Quill10, Tail1, Tail2, Tail3, Tail4, 
    -- L_BShoulder, L_BLeg1, L_BLeg2, L_BLeg3, L_BFoot, 
    -- R_BShoulder, R_BLeg1, R_BLeg2, R_BLeg3, R_BFoot
    },
    SecurityBot = {
    --hips, Torso, eye, 
    -- l_clav, l_arm1, l_arm2, l_hand, 
    -- l_claw1, l_claw2, l_claw3, L_Claw4, L_Claw5, L_Claw6, 
    -- r_clav, r_arm1, r_arm2, r_hand, 
    -- l_leg1, l_leg2, L_Leg3, L_Foot1, L_Foot2, l_toe1, l_toe2, L_Heel, 
    -- r_leg1, r_leg2, R_Leg3, R_Foot1, R_Foot2, r_toe1, r_toe2, R_Heel, L_FootIK, R_FootIK
    },
    ExorMonk = {
        --Root, hips, Spine1, Spine2, spine3, neck, Head, 
        -- tongue1, tongue2, r_jaw2, l_jaw2, r_jaw1, l_jaw1, 
        -- quill3, quill1, quill2, r_quill4, l_quill4, 
        -- r_clav, r_arm1, r_arm2, l_clav, l_arm1, l_arm2, l_hand, l_claw1, l_claw2, l_claw3, 
        -- quill4, quill5, quill6, r_quill5, l_quill3, l_quill5, r_quill3, quill7, quill8, r_quill2, l_quill2, 
        -- l_leg1, l_leg2, L_Leg3, L_Foot, r_leg1, r_leg2, R_Leg3, R_Foot
    },
    Symphonist = {
        -- Root, hips, spine, Head, 
        -- l_clav, l_arm1, l_arm2, l_hand, l_index1, l_index2, 
        -- l_middle1, l_middle2, l_middle3, 
        -- l_pinky1, l_pinky2, l_pinky3, l_thumb1, l_thumb2, 
        -- l_horn2, l_horn1, l_horn3, 
        -- r_clav, r_arm1, r_arm2, r_hand, r_index1, r_index2, 
        -- r_middle1, r_middle2, r_middle3, r
        -- _pinky1, r_pinky2, r_pinky3, r_thumb1, r_thumb2, 
        -- r_horn2, r_horn1, r_horn3, 
        -- l_leg1, l_leg2, L_Foot, l_toe1, l_toe2, l_toe3, 
        -- r_leg1, r_leg2, R_Foot, r_toe1, r_toe2, r_toe3
    },
    Grunt = {
        -- Root, hips, Spine1, Spine2, spine3, neck, Head, jaw, 
        -- r_clav, r_arm1, r_arm2, r_hand, backpack, 
        -- l_clav, l_arm1, l_arm2, l_hand, 
        -- r_leg1, r_leg2, R_Foot, r_toe, l_leg1, l_leg2, L_Foot, l_toe
    },
    LabRat = {
        -- <humanoid bones>, Backpack
        -- VB VB_IDCard, VB VB_IDCardAlt
    },
    Crystallisk = {
        -- root_assassin, hips, spine, l_clav, l_arm1, l_arm2, l_hand, 
        -- L_Finger1, L_Finger2, L_Finger3, L_Finger4, L_Finger5, L_Finger6, l_thumb1, l_thumb2, 
        -- neck, Head, HeadTop, L_Head02, L_Head01, R_Head02, R_Head01, 
        -- L_BackLeg4, L_BackLeg5, L_BackLeg6, L_BackLeg6_IK, L_BackLeg1, L_BackLeg2, L_BackLeg3, L_BackLeg3_IK, 
        -- r_clav, r_arm1, r_arm2, r_hand, R_Finger1, R_Finger2, R_Finger3, R_Finger4, R_Finger5, R_Finger6, r_thumb1, r_thumb2, 
        -- R_BackLeg4, R_BackLeg5, R_BackLeg6, R_BackLeg6_IK, R_BackLeg1, R_BackLeg2, R_BackLeg3, R_BackLeg3_IK, WeakPoint, 
        -- l_leg1, l_leg2, L_BackLeg7, L_BackLeg8, L_BackLeg9, L_BackLeg9_IK, 
        -- r_leg1, r_leg2, R_BackLeg7, R_BackLeg8, R_BackLeg9, R_BackLeg9_IK, L_HandIK, R_HandIK
    }
}

AnteEnums.Levels = {
    Facility_Botanical = true,
    Facility_Containment = true,
    Facility_DF_Central = true,
    Facility_DF_Labs = true,
    Facility_DF_Overgrowth = true,
    Facility_DF_RadWaste = true,
    Facility_DF_War = true,
    Facility_Dam = true,
    Facility_Dam_Central = true,
    Facility_Dam_Hydroplant = true,
    Facility_Dam_Lower = true,
    Facility_Dam_Waterfall = true,
    Facility_DarkFusion = true,
    Facility_Fracture = true,
    Facility_Labs = true,
    Facility_Labs_Adjustment = true,
    Facility_Labs_Control = true,
    Facility_MFFoundry = true,
    Facility_MFHQ = true,
    Facility_MFMaggot = true,
    Facility_MFMines = true,
    Facility_MFWest = true,
    Facility_Office1 = true,
    Facility_Office2 = true,
    Facility_Office3 = true,
    Facility_Office4 = true,
    Facility_Parking = true,
    Facility_Pens = true,
    Facility_Plant = true,
    Facility_Pool = true,
    Facility_Reservoir = true,
    Facility_Residence = true,
    Facility_Security = true,
    H_Cabin = true,
    H_Garden = true,
    H_Japan = true,
    V_Alps = true,
    V_Anteverse_A = true,
    V_Anteverse_B = true,
    V_Anteverse_C = true,
    V_BOTANICAL = true,
    V_DistantShore = true,
    V_Dummy = true,
    V_FOG = true,
    V_ISLAND = true,
    V_Inq = true,
    V_NIGHT = true,
    V_RISE = true,
    V_SUOMI = true,
    V_Salem = true,
    V_Signal = true, --VOTV Level?
    V_SnowGlobe = true,
    V_TheWall = true,
    V_Tile = true,
    V_Train = true,
    V_Winter = true,
    Vignette_FurnitureWarehouse = true,
    Vignette_MirrorWorld = true,
    Vignette_Theatre = true,
}

AnteEnums.AssaultTypes = {
    assault_peststorm = true,
    assault_peccaryboss = true,
    assault_monkdad = true,
    assault_soldierpatrol = true,
    assault_pistolbros = true,
    assault_smggrunt = true,
    assault_soloassassin = true,
    assault_peststorm_electro = true,
    assault_peststorm_volatile = true,
    assault_exorsquad = true,
    assault_shotgunsquad = true,
    assault_zombiehorde = true,
    assault_zombiewave = true,
    assault_corruptbot = true,
    assault_gksquad = true,
    assault_gkheavy = true,
    assault_mages = true,
    assault_witchhunt = true,
    assault_groupe = true,
    assault_ratpatrol = true,
    assault_salemmob = true,
    assault_pestfrenzy_volatile = true,
    assault_pestfrenzy_electro = true,
    assault_lamogifrenzy = true,
    assault_larva = true,
}

-- K2_AttachToComponent(.., locationRule, rotationRule, scaleRule)
-- enum class EAttachmentRule {
--     KeepRelative = 0,
--     KeepWorld = 1,
--     SnapToTarget = 2,
--     EAttachmentRule_MAX = 3,
-- };


-- Collision enums for something like making a Chopinator attachment
-- namespace ECollisionEnabled {
--     enum Type {
--         NoCollision = 0,
--         QueryOnly = 1,
--         PhysicsOnly = 2,
--         QueryAndPhysics = 3,
--         ProbeOnly = 4,
--         QueryAndProbe = 5,
--         ECollisionEnabled_MAX = 6,
--     };
-- }

-- namespace EParticleCollisionResponse {
--     enum Type {
--         Bounce = 0,
--         Stop = 1,
--         Kill = 2,
--         EParticleCollisionResponse_MAX = 3,
--     };
-- }

-- enum ECollisionResponse {
--     ECR_Ignore = 0,
--     ECR_Overlap = 1,
--     ECR_Block = 2,
--     ECR_MAX = 3,
-- };

--    void Server_DoMeleeAttackCustom(TEnumAsByte<E_NPC_MeleeTypes::Type> MeleeAttackType, FVector Location);
-- namespace E_NPC_MeleeTypes {
--     enum Type {
--         NewEnumerator5 = 0,
--         NewEnumerator0 = 1,
--         NewEnumerator1 = 2,
--         NewEnumerator2 = 3,
--         NewEnumerator3 = 4,
--         NewEnumerator4 = 5,
--         NewEnumerator6 = 6,
--         NewEnumerator7 = 7,
--         NewEnumerator8 = 8,
--         NewEnumerator9 = 9,
--         E_NPC_MAX = 10,
--     };
-- }
-- namespace E_NPC_AbilityTypes {
--     enum Type {
--         NewEnumerator3 = 0,
--         NewEnumerator0 = 1,
--         NewEnumerator1 = 2,
--         NewEnumerator2 = 3,
--         E_NPC_MAX = 4,
--     };
-- }

-- enum EMovementMode {
--     MOVE_None = 0,
--     MOVE_Walking = 1,
--     MOVE_NavWalking = 2,
--     MOVE_Falling = 3,
--     MOVE_Swimming = 4,
--     MOVE_Flying = 5,
--     MOVE_Custom = 6,
--     MOVE_MAX = 7,
-- };

-- Spawner enum to control when some spawns spawn
-- namespace ETimesOfDay {
--     enum Type {
--         NewEnumerator0 = 0, --Anytime?
--         NewEnumerator1 = 1,
--         NewEnumerator2 = 2, --Night only? 
--         ETimesOfDay_MAX = 3,
--     };
-- }

-- E_LiquidType - what an item/container's liquid slot holds ("Modify Item Liquid In Slot",
-- CurrentLiquid/AllowedLiquids, RechargeableComponent.CompatibleLiquidType, ...).
--   * Names from the native ELiquidType (same numbers on a Blueprint-struct build, whose
--     Blueprint enum only had NewEnumeratorN names). Keys kept from before: None (native Empty),
--     Energy (Battery), LaserEnergy (Laser).
AnteEnums.LiquidType = {
    None             = 0,
    Water            = 1,
    Feces            = 2,
    RadioactiveWaste = 3,
    MoltenMaterial   = 4,
    Fuel             = 5,
    Vomit            = 6,
    Energy           = 7,    -- battery charge (the charging crate's ChargeType)
    Blood            = 8,
    Antejuice        = 9,
    TaintedWater     = 10,
    Soup             = 11,
    LaserEnergy      = 12,   -- laser-weapon ammo (the laser collector's fill type)
    Ink              = 13,
}

-- Known Faction values
--   * Some values are out of order
--   * DT/JSON exports store the name, so a Zombie's DefaultFaction=9, 
--     where its commented value is 10
--   * Hostility (AbioticFunctionLibrary.GetHostilityTowardsTarget)
--       - 0 = hostile to everything not its own Npc class
--       - 1 = hostile to all
--       - 2 = hostile to different factions
--   * Player factions are { 2, 4, 7, 8 }, so BelongsToAnyPlayerFaction can return true for 
--     multiple factions
--   * Some native checks key on this like InvincibleToNPCs will ignore non-player-faction AI controllers
--   * Custom teams should use a value outside {0,1} and outside {2,4,7,8}.
AnteEnums.Faction = {
    Crystallisk = 0,   -- class-keyed: hostile to everything outside its own NPC class
    Scientists  = 2,   -- players
    Order       = 3,
    Exor        = 5,   -- Anteverse 2 (Pests / Exor share this team)
    Gatekeepers = 6,   -- GateKeepers / Robots
    Zombie      = 9,
    Canaan      = 11,  -- Pillagers (Anteverse 168)
    Shade       = 12,  -- OURS (Shades.lua SHADE_FACTION): unused by the game, not player-flagged
}

-- Raw enum for reference (names are out of order vs values; do not key off the names):
-- namespace E_Factions {
--     enum Type {
--         NewEnumerator0 = 0, -- Crystallisk
--         NewEnumerator5 = 1,
--         NewEnumerator1 = 2, -- Scientist / Player
--         NewEnumerator2 = 3, -- Order
--         NewEnumerator4 = 4,
--         NewEnumerator6 = 5, -- Anteverse2 - Pests
--         NewEnumerator7 = 6, -- GateKeepers, Robots
--         NewEnumerator8 = 7, 
--         NewEnumerator9 = 8,
--         NewEnumerator10 = 9,
--         NewEnumerator11 = 10, -- Zombie
--         NewEnumerator12 = 11,
--         NewEnumerator13 = 12,
--         NewEnumerator14 = 13,
--         NewEnumerator16 = 14,
--         E_MAX = 15,
--     };
-- }

-- enum class EPaintColor {
--     White = 0,
--     Blue = 1,
--     Red = 2,
--     Green = 3,
--     Orange = 4,
--     Purple = 5,
--     Yellow = 6,
--     Black = 7,
--     Cyan = 8,
--     Lime = 9,
--     Pink = 10,
--     Brown = 11,
--     None = 12,
--     Glitch = 13,
--     EPaintColor_MAX = 14,
-- };

-- When spawning
-- enum class ESpawnActorCollisionHandlingMethod {
--     Undefined = 0,
--     AlwaysSpawn = 1,
--     AdjustIfPossibleButAlwaysSpawn = 2,
--     AdjustIfPossibleButDontSpawnIfColliding = 3,
--     DontSpawnIfColliding = 4,
--     ESpawnActorCollisionHandlingMethod_MAX = 5,
-- }


return AnteEnums
