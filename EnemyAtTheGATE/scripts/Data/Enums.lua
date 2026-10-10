-- Enums / constants for EnemyAtTheGATE

local Enums = {}

-- ============================================================
-- NPC class paths (UE asset references)
-- Keys match the in-game DT_NPCList row names exactly.
-- ============================================================

Enums.BASE_PARENT_NPC = "/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C"
Enums.ItemDropClass   = "/Game/Blueprints/Items/Abiotic_Item_Dropped.Abiotic_Item_Dropped_C"

Enums.NpcClasses = {

    ------------------------------------------
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
    ["Exor_Volatile"]      = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Exor_Volatile.NPC_Monster_Exor_Volatile_C",

    ["Carbuncle"]          = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Carbuncle.NPC_Monster_Carbuncle_C",
    ["Carbuncle_Tainted"]  = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Carbuncle_Tainted.NPC_Monster_Carbuncle_Tainted_C",
    ["Carbuncle_Mushroom"] = "/Game/Blueprints/Characters/NPCs/NPC_Carbuncle_Mushroom.NPC_Carbuncle_Mushroom_C",
    ["Carbuncle_Volatile"] = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Carbuncle_Volatile.NPC_Monster_Carbuncle_Volatile_C",

    ------------------------------------------
    -- Anteverse 1 - Composers / Symphonists
    ["Composer"]           = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Composer.NPC_Monster_Composer_C",
    ["Symph"]              = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Symphonist.NPC_Monster_Symphonist_C",
    ["Mirage"]             = "/Game/Blueprints/Environment/Mirage/BP_Mirage_Symphonist.BP_Mirage_Symphonist_C",

    ------------------------------------------
    -- The Order 
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

    ------------------------------------------
    -- Gate Robots
    ["Robot_Security"]     = "/Game/Blueprints/Characters/NPCs/NPC_Robot_Security.NPC_Robot_Security_C",
    ["Robot_Containment"]  = "/Game/Blueprints/Characters/NPCs/NPC_Robot_Containment.NPC_Robot_Containment_C",
    ["Robot_Defense"]      = "/Game/Blueprints/Characters/NPCs/NPC_Robot_Defense.NPC_Robot_Defense_C",
    ["Robot_Corrupt"]      = "/Game/Blueprints/Characters/NPCs/NPC_Robot_Corrupt.NPC_Robot_Corrupt_C",

    ------------------------------------------
    -- GateKeepers
    ["Gatekeeper_Phyter"]  = "/Game/Blueprints/Characters/NPCs/NPC_Gatekeeper_Grunt.NPC_Gatekeeper_Grunt_C",
    ["Gatekeeper_Mage"]    = "/Game/Blueprints/Characters/NPCs/NPC_Mage.NPC_Mage_C",
    ["Gatekeeper_Heavy"]   = "/Game/Blueprints/Characters/NPCs/NPC_Gatekeeper_Heavy.NPC_Gatekeeper_Heavy_C",
    ["Gatekeeper_Chieftain"]= "/Game/Blueprints/Characters/NPCs/NPC_Gatekeeper_Chieftain.NPC_Gatekeeper_Chieftain_C",
    ["Gatekeeper_Witch"]   = "/Game/Blueprints/Characters/NPCs/NPC_Gatekeeper_Witch.NPC_Gatekeeper_Witch_C",
    --["Gatekeeper_Heavy_BANNER"] = ".../NPC_Gatekeeper_Heavy_BannerSpeech...",

    ["DarkLens_Chieftain"] = "/Game/Blueprints/Characters/NPCs/NPC_Gatekeeper_Chieftain_DarkLens.NPC_Gatekeeper_Chieftain_DarkLens_C",
    ["DarkLens_Heavy"]     = "/Game/Blueprints/Characters/NPCs/NPC_Gatekeeper_Heavy_DarkLens.NPC_Gatekeeper_Heavy_DarkLens_C",
    ["DarkLens_Witch"]     = "/Game/Blueprints/Characters/NPCs/NPC_Gatekeeper_Witch_DarkLens.NPC_Gatekeeper_Witch_DarkLens_C",
    ["DarkLens_Mage"]      = "/Game/Blueprints/Characters/NPCs/NPC_Mage_DarkLens.NPC_Mage_DarkLens_C",

    ------------------------------------------
    -- Anteverse 168 - Canaan (Pillagers)
    ["Pillager_Farmer"]    = "/Game/Blueprints/Characters/NPCs/NPC_Pillager_Farmer.NPC_Pillager_Farmer_C",
    ["Pillager_Woodsman"]  = "/Game/Blueprints/Characters/NPCs/NPC_Pillager_Woodsman.NPC_Pillager_Woodsman_C",
    ["Pillager_Musketeer_GUARD"]= "/Game/Blueprints/Characters/NPCs/NPC_Pillager_Musketeer_Guard.NPC_Pillager_Musketeer_Guard_C",
    ["Pillager_Torchbearer"]= "/Game/Blueprints/Characters/NPCs/NPC_Pillager_Torchbearer.NPC_Pillager_Torchbearer_C",
    ["Pillager_Preacher"]  = "/Game/Blueprints/Characters/NPCs/NPC_Pillager_Preacher.NPC_Pillager_Preacher_C",
    ["Pillager_Musketeer"] = "/Game/Blueprints/Characters/NPCs/NPC_Pillager_Musketeer.NPC_Pillager_Musketeer_C",
    ["Pillager_Preacher_Niketas"]= "/Game/Blueprints/Characters/NPCs/NPC_Pillager_Preacher_NiketasBOSS.NPC_Pillager_Preacher_NiketasBOSS_C",

    ------------------------------------------
    -- Anteverse 21 - Skinks
    ["Skink"]              = "/Game/Blueprints/Characters/NPCs/NPC_Skink_Basic.NPC_Skink_Basic_C",
    ["Skink_Crafted"]      = "/Game/Blueprints/Characters/NPCs/NPC_Skink_Crafted.NPC_Skink_Crafted_C",
    ["Skink_Magma"]        = "/Game/Blueprints/Characters/NPCs/NPC_Skink_Magma.NPC_Skink_Magma_C",
    ["Skink_Magma_Crafted"]= "/Game/Blueprints/Characters/NPCs/NPC_Skink_Magma_Crafted.NPC_Skink_Crafted_Magma_C",

    ------------------------------------------
    -- Anteverse 23 - Zombies / Power Leeches / Assassin
    ["Zombie"]             = "/Game/Blueprints/Characters/NPCs/NPC_Zombie.NPC_Zombie_C",
    ["Zombie_Dam"]         = "/Game/Blueprints/Characters/NPCs/NPC_Zombie_DamWorker.NPC_Zombie_DamWorker_C",
    ["Zombie_Sci"]         = "/Game/Blueprints/Characters/NPCs/NPC_Zombie_Scientist.NPC_Zombie_Scientist_C",
    ["PowerLeech"]         = "/Game/Blueprints/Characters/NPCs/NPC_PowerLeech.NPC_PowerLeech_C",
    ["PowerLeech_BOSS"]    = "/Game/Blueprints/Characters/NPCs/NPC_PowerLeechBoss.NPC_PowerLeechBoss_C",
    ["Assassin"]           = "/Game/Blueprints/Characters/NPCs/NPC_Assassin.NPC_Assassin_C",

    ------------------------------------------
    -- Anteverse 33 - Flesh Dimension
    ["BogMan"]             = "/Game/Blueprints/Characters/NPCs/NPC_Monster_BogMan.NPC_Monster_BogMan_C",
    ["Leyak"]              = "/Game/Blueprints/Characters/NPCs/NPC_Leyak.NPC_Leyak_C",
    ["Krasue"]             = "/Game/Blueprints/Characters/NPCs/NPC_Krasue.NPC_Krasue_C",

    ------------------------------------------
    -- Anteverse 39 - Night Realm
    ["Reaper"]             = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Reaper.NPC_Monster_Reaper_C",
    ["ReaperScout"]        = "/Game/Blueprints/Characters/NPCs/NPC_Monster_ReaperScout.NPC_Monster_ReaperScout_C",

    ------------------------------------------
    -- Anteverse 42 - Macroscopic Dimension (Giants)
    ["Tarasque"]           = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Tarasque.NPC_Monster_Tarasque_C",
    ["Behemoth"]           = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Behemoth.NPC_Monster_Behemoth_C",

    ------------------------------------------
    -- Anteverse 188 - North Pole
    ["Snowman"]            = "/Game/Blueprints/Characters/NPCs/NPC_Snowman.NPC_Snowman_C",
    ["Yeti"]               = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Yeti.NPC_Monster_Yeti_C",
    ["Bigfoot"]            = "/Game/Blueprints/Characters/NPCs/NPC_Bigfoot.NPC_Bigfoot_C",

    ------------------------------------------
    -- Space Queen - Winter Sprites
    ["WinterSprite"]       = "/Game/Blueprints/Characters/NPCs/NPC_Monster_WinterSprite.NPC_Monster_WinterSprite_C",
    ["WinterSprite_Bomb"]  = "/Game/Blueprints/Characters/NPCs/NPC_Monster_WinterSprite_Bomb.NPC_Monster_WinterSprite_Bomb_C",
    ["WinterSprite_BOSS"]  = "/Game/Blueprints/Characters/NPCs/NPC_Monster_WinterSprite_BOSS.NPC_Monster_WinterSprite_BOSS_C",
}

Enums.FX = {    
    PORTAL_PURPLE = "/Game/Particles/Niagara_Portal_Friendly_Purple.Niagara_Portal_Friendly_Purple",
    PORTAL_DOOR = "/Game/Particles/Niagara_Portal_Door.Niagara_Portal_Door", --cool AF
    PORTAL_BURST_ENTER = "/Game/Particles/Niagara_Portal_Burst_Enter.Niagara_Portal_Burst_Enter",
    PORTAL_FRIENDLY = "/Game/Particles/Niagara_Portal_Friendly.Niagara_Portal_Friendly",
    PORTAL_YELLOW = "/Game/Particles/Niagara_Portal_Friendly_Yellow.Niagara_Portal_Friendly_Yellow",
    PORTAL_NIGHTREALM_DOOR = "/Game/Particles/Niagara_Portal_NightRDoor_2.Niagara_Portal_NightRDoor_2",
}

-- ============================================================
-- Sound assets
-- ============================================================

Enums.SOUNDS = {
    ASSAULT_WARN_START = "/Game/Audio/Music/ShortStings/anteverse_sting.anteverse_sting",
    RADIO_GK_START     = "/Game/Audio/Monsters/Grunt/GateKeeper_RadioChirp_Cue.GateKeeper_RadioChirp_Cue",
    PORTAL_NIGHTREALM  = "/Game/Audio/Environment/Portals/s_portal_nightrealm_open.s_portal_nightrealm_open",
    -- The GK rift's hold-open loop. Same asset AnteUp uses for its GK_PORTAL, so a
    -- machine running both mods hears one consistent portal.
    PORTAL_SALEM       = "/Game/Audio/Environment/Portals/S_Salem_PortalLoop.S_Salem_PortalLoop",
    PORTAL_SHADOWGATE  = "/Game/Audio/Environment/Portals/S_Portal_Shadowgate_Loop.S_Portal_Shadowgate_Loop",
    PORTAL_EXIT2       = "/Game/Audio/Environment/Portals/S_Portal_Exit_3rdPerson_2.S_Portal_Exit_3rdPerson_2",
    TELEPORT_GEN       = "/Game/Audio/Actions/teleport_generic.teleport_generic",
}


-- ============================================================
-- Factions (E_Factions). Ported from AnteUp2's AnteData/Enums.
--
-- * The raw enum NAMES are out of order vs their values - key off the value.
-- * Hostility (AbioticFunctionLibrary.GetHostilityTowardsTarget):
--     0 = hostile to everything outside its own NPC class
--     1 = hostile to all
--     2 = hostile to different factions   <- what makes crossfire work
-- * Player factions are { 2, 4, 7, 8 }. A custom team should avoid those and {0,1}.
-- ============================================================

Enums.Faction = {
    Crystallisk = 0,   -- class-keyed: hostile to everything outside its own NPC class
    Scientists  = 2,   -- players
    Order       = 3,
    Exor        = 5,   -- Anteverse 2 - Pests and Exor share this team
    Gatekeepers = 6,   -- Gatekeepers / Robots
    Zombie      = 9,
    Canaan      = 11,  -- Pillagers (Anteverse 168)
}


-- ============================================================
-- DT_Assaults
-- ============================================================

Enums.STORM_ASSAULTS = {
    assault_peststorm          = true,
    assault_peststorm_electro  = true,
    assault_peststorm_volatile = true,
}

return Enums
