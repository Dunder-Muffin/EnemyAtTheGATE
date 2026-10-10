-- ===========================================================================================
-- ANTEUP ASSAULT TEST - assaults with variants
-- ===========================================================================================
--
-- HOW IT WORKS - DT_NPCList has no "Razor Pest", so we spawn the BASE ("Pest")
--                and tell AnteUp which slots/waves to mutate
--
-- REQUIREMENTS
--   * The AnteUp mod must be installed and enabled (its MOD_COMPATIBILITY.ENEMY_AT_THE_GATE setting)
--
-- VARIANT NAMES
--   * The full list AnteUp published this session is in
--         Mods/EnemyAtTheGATE/AnteUp_VariantCache.txt
--
-- 
-- ===========================================================================================
-- TESTING ASSAULTS
-- ===========================================================================================
-- 
-- SINGLE PLAYER
-- * In CONFIG.lua, Set DEBUG=true
--    [SHIFT] + [<-] or [->]     - cycle through assaults
--    [CONTROL] + [<-] or [->]   - cycle through groups of assaults
--    [SHIFT] + [END]            - force start an assault. Ignores restrictions
--    [CONTROL] + [SHIFT] + [P]  - remove enemies, corpses, and all dropped items nearby (250m)
-- 
-- * Recommendation - Add NpcHighlighter to highlight nearby enemies
-- 
-- ===========================================================================================
-- 
-- * Note the game's assault has a worldflag threshold, like corruptbot has [Reactors_S3Overgrowth_Complete]
--     Those assaults won't happen despite storyMin/Max until that happens
-- 
-- * [ENDLESS NOTE] - have 6 'monkdad' assaults within the ~10-25 storyMin and storyMax
--      > There's an earlygame window (Flathill - Blacksmith) where monkdad is the only valid assault. 
--          We're trying to exclude portal storms from ENDLESS. 
--          AbioticFactor is very aggressive about portal storms early so that might happen
-- 
-- ===========================================================================================


local EM = require("Managers.EventManager")
local Enums = require("Data.Enums")


local ASSAULTS = {

   
    -- ========================================================
    -- Portal Storms
    -- Gets phased out around the start of Labs (StoryProgress 32)
    -- ========================================================

    -- [0-32] assault_peststorm: Pestx7 | boss: none | "A portal storm has started!" | 6/4/3/10 | (none)
    assault_peststorm = {
        {
            Name = "peststorm - [ANTEUP]",
            StoryMin = 0, StoryMax = 32,
            Wave1     = { "Pest", "Razor Pest", "Pest", "Chonky Pest" },
            Wave1Time = 3,
            Wave2     = { "Antegrav Pest", "Antegrav Pest", "Antegrav Pest", },
            Wave2Time = 1,
            Wave3     = { "Pest", "Pest" },
            Wave3Time = 5,
            BossWave  = { "Charge Peccary" },
            BossWaveTime = 15,
        },
    },

    -- [0-32] assault_peccaryboss: Pestx5 | boss: Peccary | "A portal storm has started!" | 2/2/2/10 | (none)
    assault_peccaryboss = {
        {
            Name = "peccaryboss - [ANTEUP]",
            StoryMin = 0, StoryMax = 32,
            Wave1     = { "Antegrav Pest", "Antegrav Pest", "Peccary", },
            Wave1Time = 1,
            Wave2     = { "Charge Peccary", "Peccary", },
            Wave2Time = 10,
            Wave3     = { "Phase Peccary", "Phase Peccary" },
            Wave3Time = 1,
            BossWave  = { "Anterazor Pest" },
            BossWaveTime = 15,
        },
    },

    -- [0-32] assault_peststorm_electro:   Pest_Electrox4 | boss: Sow | "A portal storm has started!" | 8/6/4/10 | LABS_ExploredLabs
    assault_peststorm_electro = {
        Name = "peststorm_electro - EARLY",
        StartMessage   = "A thunderous portal storm has started!",
        StoryMin = 30, StoryMax = 35,
        Wave1     = { "Pest_Electro", "Pest_Electro", "Pest_Electro", "Pest_Electro" },
        Wave1Time = 3,
        Wave2     = { "Pest", "Laser Pest", "Pest", "Laser Pest" },
        Wave2Time = 5,
        Wave3     = { "Peccary_Electro", "Peccary_Electro" },
        Wave3Time = 5,
        BossWave  = { "Telepest" },
        BossWaveTime = 10,
    },
    
    -- [REDRAW] assault_peststorm_volatile:  Pest_Volatilex4 | boss: Exor_Volatile | "A portal storm has started!" | 8/6/4/10 | Reactors_S3Overgrowth_Complete
    assault_peststorm_volatile = {},


    -- ========================================================
    -- Exor centric
    -- ========================================================

   
    -- [35-999] assault_pestfrenzy_electro: Pest_Electrox6 | boss: Sow | "A frenzy!" | 4/4/4/10 | LABS_ExploredLabs
    -- * Letting this handle all Pest centric assaults
    assault_pestfrenzy_electro = {
        {
            Name = "pestfrenzy_electro - MID",
            StoryMin = 35, StoryMax = 70,
            StartMessage = "A pest Tempest!",
            Wave1     = { "Pest_Electro", "Pest_Electro", "Pest_Electro", },
            Wave1Time = 1,
            Wave2     = { "Peccary_Electro", "Telepest", },
            Wave2Time = 10,
            Wave3     = { "Laser Pest", "Laser Pest", "Laser Pest", "Peccary_Electro", },
            Wave3Time = 2,
            BossWave  = { "Telepest", "Telepest", "Exor_Monk" },
            BossWaveTime = 5
        },
        {
            Name = "pestfrenzy_electro - LATE",
            StoryMin = 70, StoryMax = 999,
            StartMessage = "An elemental Tempest!",
            Wave1     = { "Pest_Electro", "Magma Pest", "Pest_Volatile", "Laser Pest", "Magma Pest", "Electro Peccary" },
            Wave1Time = 2,
            Wave2     = { "Telepest", "Pest_Magma", "Pestilence", "Pest_Electro", "Magma Pest", "Volatile Peccary" },
            Wave2Time = 2,
            Wave3     = { "Magma Peccary", "Volatile Peccary", "Electro Peccary", "Pest_Enlightened" },
            Wave3Time = 5,
            BossWave  = { "Magma Exor", "Exorrior Magus", "Acidic Exor" },
            BossWaveTime = 3,
            OnStart = EM.Sequence(
                EM.AssaultWeather("RadLeak", 180000, 15000),
                EM.SkinkDrop(5000, { spawns = { skinks=2 } }),
                EM.SkinkDrop(20000, { spawns = { magmaskinks=2 } })
            )
        },
    },

    -- [52-999] assault_exorsquad: Exor_Monk, Exor_Armored, Exor_Monk | boss: none | "Something fowl lurks nearby…" | 5/4/3/10 | Dams_ReachedCentral
    assault_exorsquad = {
        {
            Name = "exorsquad - MID",
            StoryMin = 52, StoryMax = 80,
            StartMessage   = "An exor warband!",
            Wave1     = { "Magma Exor", "Peccary_Mushroom", "Armored Peccary", "Magma Peccary", "Exor", },
            Wave1Time = 2,
            Wave2     = { "Exor_Armored", },
            Wave2Time = 20,
            Wave3     = { "Exorrior", "Exorrior Magus", "Hive Sow" },
            Wave3Time = 3,
            BossWave  = { "Exor Repeller", "Exor Displacer",  },
            BossWaveTime = 10
        },
        {
            Name = "exorsquad - LATE",
            StoryMin = 81, StoryMax = 999,
            StartMessage   = "An exordinary invasion!",
            Wave1     = { "Pest", "Peccary", "Pest_Carbonated", "Charge Peccary", "Exor_Monk",
                          "Razor Pest", "Phase Peccary", "Chonky Pest", "Sow", "Exorrior Magus",
                         },
            Wave1Time = 1,
            Wave2     = { "Telepest", "Hive Sow", "Laser Pest", "Exor", "Electro Peccary",
                          "Pest_Electro", "Magma Exor", "Pest_Volatile", "Exor", "Peccary_Armored"
                         },
            Wave2Time = 1,
            Wave3     = { "Exor_Spiritwalker", },
            Wave3Time = 40,
            BossWave  = { "Exor_Armored", "Peccary_Volatile", "Exor Dislocator", "Exor Displacer", "Volatile Peccary", "Pest_Leyak" },
            BossWaveTime = 5,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Spores", 90000, 21000)
            )
        },
    },
   

    -- ========================================================
    -- ORDER centric
    -- ========================================================

    -- [20-70] assault_smggrunt: Grunt | boss: none | "A radio crackle is heard nearby…" | 2/2/2/10 | MF_MetBlacksmith
    assault_smggrunt = {
        {
            Name       = "smggrunt - EARLY",
            StoryMin   = 20, StoryMax = 40,
            StartMessage = "A radio crackle is heard nearby...",
            Wave1     = { "Grunt_Guard", "Velites Guard@Grunt_Guard", "Grunt_Guard", },
            Wave1Time = 2,
            Wave2     = { "Grenadier Guard",  },
            Wave2Time = 15,
            Wave3     = { "Suppressor Grunt", "Suppressor Grunt" },
            Wave3Time = 2,
            BossWave  = { "Dioscoridian", "Commander" },
            BossWaveTime = 10
        },
        {
            Name       = "smggrunt - MID",
            StoryMin   = 40, StoryMax = 70,
            StartMessage = "A radio crackle is heard nearby...",
            Wave1     = { "Centurion Grunt", "Suppressor Grunt", "Suppressor Grunt" },
            Wave1Time = 2,
            Wave2     = { "Centurion Grunt", },
            Wave2Time = 15,
            Wave3     = { "Grenadier Guard", "Skirmisher", },
            Wave3Time = 5,
            BossWave  = { "Trident", "Grunt_Captain", "Trident" },
            BossWaveTime = 2
        },
        {
            Name       = "smggrunt - MID xFIRE",
            StoryMin   = 40, StoryMax = 70,
            StartMessage = "A radio crackle is heard nearby, among other things...",
            Wave1     = { "Centurion Grunt", "Velites Guard", "Dioscoridian" },
            Wave1Time = 2,
            Wave2     = { "Grunt_Shotgun", "Grunt_Captain", "Skirmisher" },
            Wave2Time = 2,
            Wave3     = { "Sweeper", "Grenadier Guard", "Skirmisher", },
            Wave3Time = 2,
            BossWave  = { "Centurion Grunt", "Grunt" },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                -- Timed to show up around Waves 1/2
                EM.PestDrop(15000, { spawns = { pests=2, electros=2 }, }),
                EM.PeccaryDrop(15000, { spawns = { peccarys=2, electros=1 } }),
                -- Waves 3/4
                EM.PeccaryDrop(30000, { spawns = { peccarys=2, electros=1 } }),
                EM.ExorDrop(30000, { spawns = { monks=1, exors=1 }, } )
            )
        },
    },
   
    -- [40-100] assault_shotgunsquad: Grunt_Captain, Grunt_Medic, Grunt_Shotgun | boss: none | "A radio crackle is heard nearby…" | 5/5/5/10 | LABS_ReachedCommandCenter
    assault_shotgunsquad = {
        {
            Name       = "shotgunsquad - MID",
            StoryMin   = 40, StoryMax = 70,
            StartMessage = "A radio crackle is heard nearby...",
            Wave1     = { "Suppressor Grunt", "Sweeper", "Skirmisher", },
            Wave1Time = 2,
            Wave2     = { "Dioscoridian" },
            Wave2Time = 15,
            Wave3     = { "Velites Guard", "Grunt", "Grenadier Guard", },
            Wave3Time = 1,
            BossWave  = { "Trident" },
            BossWaveTime = 30,
            OnStart = EM.Sequence(
                EM.DirectDrop(5000, { spawns = { breachers = 1 } })
            )
        },
        -- {
        --     Name       = "shotgunsquad - LATE",
        --     StoryMin   = 70, StoryMax = 100,
        --     WarningMessage = "The lights flicker...",
        --     StartMessage = "Close quarters Order!",
        --     Wave1     = { "Suppressor Grunt", "Sweeper", "Skirmisher", },
        --     Wave1Time = 2,
        --     Wave2     = { "Dioscoridian" },
        --     Wave2Time = 15,
        --     Wave3     = { "Velites Guard", "Grunt", "Grenadier Grunt", },
        --     Wave3Time = 1,
        --     BossWave  = { "Trident" },
        --     BossWaveTime = 30,
        --     OnStart = EM.Sequence(
        --         EM.AssaultWeather("Blackout", 60000, 15000)
        --     ) 
        -- },
        -- {
        --     Name       = "shotgunsquad - LATE",
        --     StoryMin   = 70, StoryMax = 100,
        --     WarningMessage = "The lights flicker...",
        --     StartMessage = "Close quarters Order!",
        --     Wave1     = { "Suppressor Grunt", "Sweeper", "Skirmisher", },
        --     Wave1Time = 2,
        --     Wave2     = { "Dioscoridian" },
        --     Wave2Time = 15,
        --     Wave3     = { "Velites Guard", "Grunt", "Grenadier Grunt", },
        --     Wave3Time = 1,
        --     BossWave  = { "Trident" },
        --     BossWaveTime = 30,
        --     OnStart = EM.Sequence(
        --         EM.AssaultWeather("Blackout", 60000, 15000)
        --     ) 
        -- },
    },

    -- [70-999] assault_groupe: Groupe_Grunt, Groupe_Rook, Groupe_Shotgun | boss: none | "A cold wind blows through…" | 2/2/2/10 | DAMS_CompletedVoussoir
    -- * Becomes Praetorium based
    assault_groupe = {
        {
            Name       = "assault_groupe - MIDLATE",
            StoryMin   = 70, StoryMax = 90,
            StartMessage = "A radio crackle is heard nearby...",
            Wave1     = { "Groupe_Grunt", "Groupe Frostpack", "Groupe Frostpack", "Groupe_Shotgun" },
            Wave1Time = 2,
            Wave2     = { "Groupe Frostpack" },
            Wave2Time = 15,
            Wave3     = { "Groupe Rookram", "Groupe_Rook", "Groupe Rookram", "Groupe_Rook" },
            Wave3Time = 5,
            BossWave  = { "Groupe Breacher", "Groupe Breacher" },
            BossWaveTime = 30,
        },
    },
   
    -- [20-999] assault_ratpatrol: Grunt_LabRat | boss: none | (no message) | 5/5/5/10 | MF_MetSoldier
    assault_ratpatrol = {
        {
            Name = "ratpatrol - EARLY",
            StoryMin = 20, StoryMax = 40,
            StartMessage   = "An inquisition patrol!",
            Wave1     = { "Grunt_LabRat", "Grunt_LabRat", },
            Wave1Time = 2,
            Wave2     = { "Grunt_Captain", },
            Wave2Time = 15,
            Wave3     = { "Flask Rat", "Grunt_LabRat", "Grunt_LabRat", },
            Wave3Time = 2,
            BossWave  = { "Flask Rat", "Pest_Rat" },
            BossWaveTime = 30,
        },
        {
            Name = "ratpatrol - MID",
            StoryMin = 40, StoryMax = 70,
            StartMessage   = "An inquisition patrol!",
            Wave1     = { "Velites Guard", "Grunt_LabRat", "Grunt_LabRat", "Grunt_Guard", },
            Wave1Time = 2,
            Wave2     = { "Skirmisher", },
            Wave2Time = 15,
            Wave3     = { "Flask Rat", "Flask Rat", "Flask Rat", "Flask Rat", "Flask Rat",  },
            Wave3Time = 2,
            BossWave  = { "Pest_Rat", "Pest_Rat" },
            BossWaveTime = 20,
        },
        {
            Name = "ratpatrol - LATE",
            StoryMin = 71, StoryMax = 999,
            StartMessage   = "A swarm of rats!",
            Wave1     = { "Mad Rat", "Grunt_LabRat", "Mad Rat", },
            Wave1Time = 2,
            Wave2     = { "Flask Rat", },
            Wave2Time = 20,
            Wave3     = { "Grunt_Sapper", "Rocket Rat", "Flask Rat",  },
            Wave3Time = 5,
            BossWave  = { "Pest_Rat",  "Mad Rat",  },
            BossWaveTime = 30,
        },
        -- {
        --     Name = "ratpatrol - END",
        --     StoryMin = 90, StoryMax = 999,
        --     StartMessage   = "No one expects the Ordo Inquisition!",
        -- },
    },


   
    -- ========================================================
    -- GK Centric
    -- ========================================================

    -- [70-999] assault_mages: Gatekeeper_Phyterx2 | boss: Gatekeeper_Mage | "Something arcane tingles your senses…" | 5/5/4/10 | Reactors_S1Labs_Complete
    assault_mages={
        {
            Name = "mages - LATE",
            StoryMin = 70, StoryMax = 90,
            Wave1     = { "Gatekeeper_Mage", },
            Wave1Time = 30,
            Wave2     = { "Barrier Mage", },
            Wave2Time = 30,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Abjurer Mage", },
            BossWaveTime = 5,
        },
        {
            Name = "mages - END",
            StoryMin = 90, StoryMax = 999,
            StartMessage   = "A conclave of Magi",
            Wave1     = { "Gatekeeper_Phyter", "Gatekeeper_Phyter", },
            Wave1Time = 20,
            Wave2     = { },
            Wave2Time = 1,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Abjurer Mage", "Gatekeeper_Mage", "Barrier Mage" },
            BossWaveTime = 1,
            OnStart = EM.Sequence(
                EM.GatekeeperDrop(5000, { spawns = { mages=1 }, spawnRadius=2000, minSpawnRadius=1000 })
            )
        },
    },
   
    
    -- [72-999] assault_gkheavy: Gatekeeper_Chieftain, Gatekeeper_Heavy, Gatekeeper_Mage | boss: none | "The bones are cast." | 5/5/4/10 | Reactors_S2War_Complete
    assault_gkheavy = {
        {
            Name = "gkheavy - LATE",
            StoryMin = 70, StoryMax = 90,
            Wave1     = { "Gatekeeper_Heavy", },
            Wave1Time = 1,
            Wave2     = { },
            Wave2Time = 1,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Gatekeeper_Phyter", "Gatekeeper_Heavy", "Gatekeeper_Chieftain",},
            BossWaveTime = 15,
        },
        {
            Name = "gkheavy - END",
            StoryMin = 90, StoryMax = 999,
            StartMessage   = "The heralds of war.",
            Wave1     = { },
            Wave1Time = 1,
            Wave2     = { },
            Wave2Time = 1,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Jotun Steed", "Jotun Steed" },
            BossWaveTime = 15,
        },
    },

    -- [75-999] assault_gksquad: Gatekeeper_Chieftain, Gatekeeper_Phyter, Gatekeeper_Witch | boss: none | "The bones are cast." | 5/5/4/10 | Reactors_SG_InteriorContact
    assault_gksquad = {
        {
            Name = "gksquad - END xA2",
            StoryMin = 75, StoryMax = 999,
            StartMessage   = "Gotta contain them all!",
            Wave1     = { "Neophyte Trainer", },
            Wave1Time = 5,
            Wave2     = { "Neophyte Trainer", },
            Wave2Time = 5,
            Wave3     = { "Gatekeeper_Chieftain", },
            Wave3Time = 30,
            BossWave  = { "Neophyte Trainer", "Esoteric Chieftain" },
            BossWaveTime = 2,
            OnStart = EM.Sequence(
                EM.PestDrop(5000, { spawns={ pests=5, carbonateds=2, electros=1, magmas=1, volatiles=1 }, spawnInterval=3000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.PestDrop(6000, { spawns={ pests=1, carbonateds=1, electros=1, magmas=1, volatiles=1 }, spawnInterval=3000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.PeccaryDrop(10000, { spawns={ peccaries=2, mushrooms=1, armoreds=1, alphas=1, volatiles=1 }, spawnInterval=5000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.ExorDrop(20000, { spawns={ monks=1, exors=2, armoreds=1 }, spawnInterval=10000, spawnRadius=3000, minSpawnRadius=1500 })
            )
        },
        {
            Name = "gksquad - END xOrder",
            StoryMin = 75, StoryMax = 999,
            StartMessage   = "Following Order",
            Wave1     = { "Gatekeeper_Phyter", "Gatekeeper_Chieftain" },
            Wave1Time = 5,
            Wave2     = { "Gatekeeper_Heavy", },
            Wave2Time = 30,
            Wave3     = { },
            Wave3Time = 5,
            BossWave  = { "Gatekeeper_Mage", "Esoteric Chieftain", },
            BossWaveTime = 2,
            OnStart = EM.Sequence(
                EM.OrderDrop(3000, { spawns={ grunts=3, captains=1 }, spawnInterval=1000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(5000, { spawns={ guards=3, grunts=2, captains=2, breachers=2 }, spawnInterval=5000, spawnRadius=3000, minSpawnRadius=1500 })
            )
        },
    },

    -- [80-999] assault_witchhunt: Gatekeeper_Witch×3 | boss: none | "A hex upon your house." | 2/2/2/10 | Reactors_SG_InteriorContact
    assault_witchhunt = {
        {
            Name = "witchhunt - END",
            StoryMin = 80, StoryMax = 999,
            StartMessage = "A horrifying hex!",
            Wave1     = { },
            Wave1Time = 1,
            Wave2     = { },
            Wave2Time = 1,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Gatekeeper_Witch", "Gatekeeper_Witch", "Gatekeeper_Witch", 
                          "Gatekeeper_Witch", "Gatekeeper_Witch", "Gatekeeper_Witch", },
            BossWaveTime = 5,
        },
        {
            Name = "witchhunt - END xA2",
            StoryMin = 80, StoryMax = 999,
            StartMessage = "A battle in the sky!",
            Wave1     = { "Exor_Volatile", "Acidic Exor", "Exor_Volatile",  },
            Wave1Time = 10,
            Wave2     = { "Exor Hunter", "Exor_Volatile" },
            Wave2Time = 5,
            Wave3     = { "Storm Witch", "Warrior Witch", "Warrior Witch", "Storm Witch" },
            Wave3Time = 7,
            BossWave  = {  },
            BossWaveTime = 5,
            OnStart = EM.Sequence(
                EM.GatekeeperDrop(2000, { spawns={ witches=3, }, firstSpawnInterval=2000, spawnInterval=3000, spawnRadius=2500, minSpawnRadius=1500, spawnAtWavePoint = true, favoredEnemy="Exor" }),
                EM.GatekeeperDrop(25000, { spawns={ witches=2, }, firstSpawnInterval=3000, spawnInterval=7000, spawnRadius=3000, minSpawnRadius=1500, spawnAtWavePoint = true, favoredEnemy="Exor" }),
                EM.ExorDrop(40000, { spawns={ volatiles=3 }, spawnInterval=10000, spawnRadius=3000, minSpawnRadius=1500, favoredEnemy="Gatekeepers", })
            )
        }
    },



    -- ========================================================
    -- Robots
    -- ========================================================

    -- [20-999] assault_pistolbros: Grunt_Guardx2 | boss: none | "A radio crackle is heard nearby…" | 2/2/2/10 | MF_MetBlacksmith
    --   * Hijacking for Robot
    assault_pistolbros = {
        {
            Name = "pistolbros - ROBOT EARLY",
            StoryMin = 20, StoryMax = 50,
            StartMessage   = "Screeching metal echos through the hall...",
            StartSound = "/Game/Audio/Music/ShortStings/anteverse_sting.anteverse_sting",
            Wave1     = { "Robot_Security" },
            Wave1Time = 15,
            Wave2     = { "Cafeteria Bot", },
            Wave2Time = 15,
            Wave3     = { "Pest", },
            Wave3Time = 15,
            BossWave  = { "Charge Peccary", "Pest", "Chonky Pest", "Office Bot", "Office Bot" },
            BossWaveTime = 2,
        },
        {
            Name = "pistolbros - ROBOT MID",
            StoryMin = 50, StoryMax = 80,
            StartMessage   = "A showdown of flesh and steel...",
            StartSound = "/Game/Audio/Music/ShortStings/anteverse_sting.anteverse_sting",
            Wave1     = { "Office Bot", "Office Bot" },
            Wave1Time = 2,
            Wave2     = { },
            Wave2Time = 2,
            Wave3     = { "Pest_Rat" },
            Wave3Time = 15,
            BossWave  = { "Constrictor Bot", "Constrictor Bot" },
            BossWaveTime = 2,
        },
        {
            Name = "pistolbros - ROBOT LATE",
            StoryMin = 80, StoryMax = 999,
            StartMessage   = "Lasers hum in the distance...",
            StartSound = "/Game/Audio/Music/ShortStings/anteverse_sting.anteverse_sting",
            Wave1     = { "Laser Pest", "Laser Pest", "Laser Pest", "Laser Pest" },
            Wave1Time = 2,
            Wave2     = { "Deatomizer Bot" },
            Wave2Time = 20,
            Wave3     = {},
            Wave3Time = 2,
            BossWave  = { "Deatomizer Bot" },
            BossWaveTime = 20,
        },
    },

    -- [73-999] assault_corruptbot: (no wave npcs) | boss: Robot_Corrupt | "An abnormal presence…" | 5/5/5/10 | Reactors_S3Overgrowth_Complete
    assault_corruptbot = {
        {
            Name = "assault_corruptbot - ROBOT LATE",
            StoryMin = 80, StoryMax = 999,
            StartSound = "/Game/Audio/Music/ShortStings/anteverse_sting.anteverse_sting",
            Wave1     = { },
            Wave1Time = 2,
            Wave2     = { },
            Wave2Time = 2,
            Wave3     = { "Deatomizer Bot", "Robot_Corrupt" },
            Wave3Time = 20,
            BossWave  = { "Office Bot", "Robot_Corrupt", },
            BossWaveTime = 20,
        },
    },


    
    -- ========================================================
    -- SYMPHONIST centric
    -- ========================================================

    -- [20-999] assault_soldierpatrol: Grunt_Captain, Grunt_Medic, Grunt_Guard | boss: none | "A radio crackle is heard nearby…" | 2/2/2/10 | MF_MetBlacksmith
    --   * Hijacking for Symphonist
    assault_soldierpatrol = {
        {
            Name = "soldierpatrol - SYMPH EARLY",
            StoryMin = 20, StoryMax = 50,
            StartMessage   = "An unnatural fog descends... ",
            Wave1     = { "Symph", },
            Wave1Time = 20,
            Wave2     = { },
            Wave2Time = 1,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Orchestrator" },
            BossWaveTime = 20,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Fog", 180000, 10000)
            )
        },
        {
            Name = "soldierpatrol - SYMPH MID",
            StoryMin = 50, StoryMax = 999,
            StartMessage   = "An orchestra of porcelain... ",
            Wave1     = { },
            Wave1Time = 1,
            Wave2     = { },
            Wave2Time = 1,
            Wave3     = { "Symph", "Orchestrator", },
            Wave3Time = 10,
            BossWave  = { "Orchestrator", "Orchestrator" },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Fog", 240000, 10000),
                EM.SymphonistDrop(5000, { spawns = { symphonists=1 } })
            )
        },
    },
   


    -- ========================================================
    -- Larva, Flesh Dimension, and Big stuff
    -- ========================================================

    -- [20-999] assault_larva: Larvax3, Larva_Hivex4, Larva_Bigx2 | boss: Larva_Big_Hive | "The hive is angry!" | 6/4/2/6 | MFMines_Mgt_Explored
    assault_larva = {
        {
            Name = "larva - EARLY",
            StoryMin = 20, StoryMax = 50,
            Wave1     = { "Larva", "Larva_Hive", "Larva_Hive", "Larva",  },
            Wave1Time = 2,
            Wave2     = { "Larva_Big", },
            Wave2Time = 2,
            Wave3     = { "Larva", "Larva_Hive", "Larva", },
            Wave3Time = 2,
            BossWave  = { "Larva_Big", "Larva", "Larva_Big_Hive", "Larva", "Larva_Big" },
            BossWaveTime = 2,
        },
        {
            Name = "larva - MID",
            StoryMin = 50, StoryMax = 80,
            StartMessage   = "A invasion of flesh.",
            Wave1     = { "Larva", "Larva", "Larva_Hive", "Larva_Big", "Larva_Big_Hive", },
            Wave1Time = 3,
            Wave2     = { "BogMan", "BogMan", },
            Wave2Time = 3,
            Wave3     = { "Pest_Leyak", "Pest_Leyak", "Pest_Leyak", },
            Wave3Time = 3,
            BossWave  = { "Tarasque Charger", "Tarasque Slammer" },
            BossWaveTime = 3,
        },
        {
            Name = "larva - LATE",
            StoryMin = 80, StoryMax = 999,
            StartMessage   = "A invasion of flesh.",
            Wave1     = { "Larva", "Larva", "Larva_Hive", "Larva_Big", "Larva_Big_Hive", },
            Wave1Time = 3,
            Wave2     = { "BogMan", "BogMan", },
            Wave2Time = 3,
            Wave3     = { "Pest_Leyak", "Pest_Leyak", "Pest_Leyak", },
            Wave3Time = 3,
            BossWave  = { "Tarasque Charger", "Tarasque Slammer" },
            BossWaveTime = 3,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Spores", 90000, 15000),
                EM.GiantDrop(25000, { spawns = { yetis=1 }, spawnRadius=3000, minSpawnRadius=1500 })
            )
        },
    },
   


   
    -- ========================================================
    -- Zombies and Reaper
    -- ========================================================

    -- [35-999] assault_zombiehorde: Zombiex10 | boss: none | (no message) | 2/2/2/10 | LABS_ActivateWarehouseLift
    assault_zombiehorde = {
        {
            Name = "zombiehorde - MID",
            StoryMin = 35, StoryMax = 70,
            Wave1     = { "Zombie_Sci", "Zombie_Sci", "Zombie", "Zombie_Sci", "Zombie_Sci", "Zombie", "Zombie_Sci", "Zombie_Sci", "Zombie", "Zombie_Sci",  },
            Wave1Time = 1,
            Wave2     = { "Zombie_Sci", },
            Wave2Time = 10,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Zombie", "Zombie", "Zombie", "Zombie", "Zombie_Sci", "Zombie", "Zombie", "Zombie", "Zombie", "Zombie_Sci", "Zombie_Dam", "Zombie_Dam", "Zombie_Dam", "Zombie_Dam", "Zombie_Dam", },
            BossWaveTime = 1,
        },
        {
            Name = "zombiehorde - LATE REAPER",
            StoryMin = 71, StoryMax = 90,
            StartMessage = "Don't fear the reaper...",
            Wave1     = { "Breacher Shade", "Grunt Shade", "Grunt Shade", "Grunt Shade", },
            Wave1Time = 2,
            Wave2     = { "Roaming Shade" },
            Wave2Time = 10,
            Wave3     = { "Breacher Shade", "Monk Shade", "Monk Shade", },
            Wave3Time = 2,
            BossWave  = { "Roaming Shade", "Roaming Shade", "Neophyte Shade" },
            BossWaveTime = 2,
            OnStart = EM.AssaultWeather("BlackFog", 60000, 15000),
        },
        {
            Name = "zombiehorde - END REAPER",
            StoryMin = 91, StoryMax = 999,
            StartMessage = "Don't fear the reaper...",
            Wave1     = { "Neophyte Shade", "Neophyte Shade", "Roaming Shade", },
            Wave1Time = 5,
            Wave2     = { "Roaming Shade", "Reaper" },
            Wave2Time = 10,
            Wave3     = { "Breacher Shade", "Breacher Shade", "Grunt Shade", "Breacher Shade", "Monk Shade", "Neophyte Shade", },
            Wave3Time = 2,
            BossWave  = { "Reaper", },
            BossWaveTime = 2,
            OnStart = EM.Sequence(
                EM.AssaultWeather("BlackFog", 120000, 15000),
                EM.ReaperPortalDrop(5000, { spawns={ reapers=1 }, spawnInterval=5000, spawnRadius=1500, minSpawnRadius=500 })
            )
        },
    },

   
    -- ========================================================
    -- Canaan
    -- ========================================================
    
    -- [40-999] assault_salemmob: Pillager_Farmerx2, Pillager_Musketeerx2, Pillager_Torchbearerx2 | boss: Pillager_Woodsman | "Torches and pitchforks!" | 3/3/3/10 | Salem_Complete
    assault_salemmob = {
        {
            Name = "salemmob - MID",
            StoryMin = 40, StoryMax = 80,
            Wave1     = { "Pillager_Farmer", "Canaan Farmer", "Pillager_Torchbearer", "Canaan Farmer", "Pillager_Preacher", "Pillager_Woodsman", },
            Wave1Time = 2,
            Wave2     = { "Pillager_Preacher", },
            Wave2Time = 15,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Pillager_Preacher", "Fanatic", "Fanatic", "Pillager_Preacher",  },
            BossWaveTime = 2,
        },
        {
            Name = "salemmob - LATE",
            StoryMin = 81, StoryMax = 999,
            StartMessage = "A witch hunt!",
            Wave1     = { "Pillager_Preacher", "Pillager_Musketeer", "Pillager_Torchbearer", "Pillager_Farmer",  },
            Wave1Time = 2,
            Wave2     = { "Pillager_Preacher", "Pillager_Musketeer", "Pillager_Torchbearer", "Pillager_Farmer",  },
            Wave2Time = 2,
            Wave3     = { "Pillager_Preacher", "Fanatic", "Fanatic", "Pillager_Preacher", "Pillager_Farmer", },
            Wave3Time = 2,
            BossWave  = { "Gatekeeper_Witch", "Gatekeeper_Witch", },
            BossWaveTime = 2,
            OnStart = EM.Sequence(
                EM.AssaultWeather("BlackFog", 65000, 15000),
                EM.GatekeeperDrop(5000, { spawns = { witches=2 }, spawnInterval=1000, spawnRadius=2000, minSpawnRadius=1000 }),
                EM.GatekeeperDrop(15000, { spawns = { witches=1 }, spawnInterval=1000, spawnRadius=2000, minSpawnRadius=1000 }),
                EM.GatekeeperDrop(25000, { spawns = { witches=1 }, spawnInterval=1000, spawnRadius=2000, minSpawnRadius=1000 })
            )
        },
    },


    -- ========================================================
    -- Crystallisks
    -- ========================================================
    
    -- [20-999] assault_soloassassin: Assassin | boss: none | (no message) | 8/6/4/10 | MF_MetSoldier
    assault_soloassassin = {
        {
            Name = "assassin - EARLY",
            StoryMin = 20, StoryMax = 50,
            WarningMessage   = "A stillness fills the air.",
            StartMessage = "A crystalline assault!",
            Wave1     = { "Assassin", "Assassin", "Assassin" },
            Wave1Time = 2,
            Wave2     = { "Assassin", },
            Wave2Time = 15,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Obsidilisk", "Obsidilisk", "Obsidilisk",},
            BossWaveTime = 5,
        },
        {
            Name = "assassin - MID",
            StoryMin = 51, StoryMax = 999,
            WarningMessage   = "A stillness fills the air.",
            StartMessage = "A crystalline assault!",
            Wave1     = { "Assassin", "Obsidilisk", "Assassin", },
            Wave1Time = 2,
            Wave2     = { "Assassin", "Obsidilisk", "Assassin", "Obsidilisk", },
            Wave2Time = 2,
            Wave3     = { "Assassin", "Obsidilisk", "Assassin", "Obsidilisk", "Assassin", },
            Wave3Time = 5,
            BossWave  = { "Obsidilisk", "Obsidilisk", "Obsidilisk" },
            BossWaveTime = 5,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Blackout", 60000, 15000),
                EM.PowerLeechBossDrop(3000, { spawns = { powerLeeches=1 } })
            ),
        },
    },

   
    -- ========================================================
    -- Lamogi
    -- ========================================================
    
    -- [50-999] assault_lamogifrenzy: WinterSpritex3 | boss: WinterSprite_Bomb | "The bytes are all wrong." | 8/6/4/10 | VWinter_Complete
    --   * Also does Snowman and some winter enemies
    assault_lamogifrenzy = {
        {
            Name = "lamogifrenzy - MID",
            StoryMin = 50, StoryMax = 80,
            Wave1     = { "WinterSprite", "WinterSprite", "WinterSprite", },
            Wave1Time = 1,
            Wave2     = { "WinterSprite", },
            Wave2Time = 15,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_BOSS", },
            BossWaveTime = 3,
        },
        {
            Name = "lamogifrenzy - LATE",
            StoryMin = 81, StoryMax = 999,
            StartMessage = "A crystalline assault!",
            Wave1     = { "WinterSprite", "WinterSprite", "WinterSprite", },
            Wave1Time = 1,
            Wave2     = { "WinterSprite", },
            Wave2Time = 15,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb", },
            BossWaveTime = 3,
            OnStart = EM.Sequence(
                EM.AssaultWeather("ColdSnap", 75000, 10000),
                EM.GiantDrop(5000, { spawns = { yetis=1 }, spawnRadius=4000, minSpawnRadius=2000 }),
                EM.GiantDrop(25000, { spawns = { snowmen=1 }, spawnRadius=4000, minSpawnRadius=2000 })
            ) 
        },
    },
   

    -- ========================================================
    -- Chaos assault.
    -- !TODO: Put some wild assaults in here
    -- ========================================================

    -- [70-999] assault_zombiewave: Zombiex10 | boss: none | (no message) | 2/2/2/10 | LABS_ActivateWarehouseLift
    -- * Multifaction messes of an assault
    assault_zombiewave = {
        {
            Name = "monkdad - HYDRO xFire",
            StoryMin = 999, StoryMax = 999,
			WarningMessage = "The smell of smoke fills the air...",
            StartMessage   = "A robotic counterattack!",
            Wave1     = { "Robot_Defense", "Exor Repeller", "Exor_Armored", "Exor" },
            Wave1Time = 10,
            Wave2     = { "Robot_Containment" },
            Wave2Time = 25,
            Wave3     = { },
            Wave3Time = 3,
            BossWave  = { "Deatomizer Bot", "Exor Displacer", "Antegrav Exor", "Exorrior Magus", "Antegrav Exor", },
            BossWaveTime = 10
        },
    },
   
    -- Maybe split chaotic assaults here for a higher chance
    -- assault_pestfrenzy_volatile: Pest_Volatilex7 | boss: Exor_Volatile | "A frenzy!" | 4/4/4/10 | Reactors_S3Overgrowth_Complete
    assault_pestfrenzy_volatile = { },

    
    -- ========================================================
    -- Endless assault support.
    -- ========================================================
    -- [11-30] assault_monkdad: Exor_Monk, Peccary, Peccary | boss: none | "Something fowl lurks nearby…" | 2/2/2/10 | Office_Silo3Opened
    -- Need 6 filler rows for Endless to sustain itself (if we kill portal storms right)
    assault_monkdad = {
        {
            Name = "monkdad - FILLER",
            StoryMin = 10, StoryMax = 30,
            StartMessage   = "Travelers from a Far Garden...",
            Wave1 = {}, Wave1Time = 1, Wave2 = {}, Wave2Time = 1, Wave3 = {}, Wave3Time = 1,
            BossWave  = { "Exor Magus", "Exor_Monk", "Exorrior", }, BossWaveTime = 5,
        },
        {
            Name = "monkdad - FILLER2",
            StoryMin = 10, StoryMax = 30,
            StartMessage   = "Travelers from a Far Garden...",
            Wave1 = {}, Wave1Time = 1, Wave2 = {}, Wave2Time = 1, Wave3 = {}, Wave3Time = 1,
            BossWave  = { "Exor Magus", "Exor_Monk", "Exorrior", }, BossWaveTime = 5,
        },
        {
            Name = "monkdad - FILLER3",
            StoryMin = 10, StoryMax = 30,
            StartMessage   = "Travelers from a Far Garden...",
            Wave1 = {}, Wave1Time = 1, Wave2 = {}, Wave2Time = 1, Wave3 = {}, Wave3Time = 1,
            BossWave  = { "Exor Magus", "Exor_Monk", "Exorrior", }, BossWaveTime = 5,
        },
        {
            Name = "monkdad - FILLER4",
            StoryMin = 10, StoryMax = 30,
            StartMessage   = "Travelers from a Far Garden...",
            Wave1 = {}, Wave1Time = 1, Wave2 = {}, Wave2Time = 1, Wave3 = {}, Wave3Time = 1,
            BossWave  = { "Exor Magus", "Exor_Monk", "Exorrior", }, BossWaveTime = 5,
        },
        {
            Name = "monkdad - FILLER5",
            StoryMin = 10, StoryMax = 30,
            StartMessage   = "Travelers from a Far Garden...",
            Wave1 = {}, Wave1Time = 1, Wave2 = {}, Wave2Time = 1, Wave3 = {}, Wave3Time = 1,
            BossWave  = { "Exor Magus", "Exor_Monk", "Exorrior", }, BossWaveTime = 5,
        },
        {
            Name = "monkdad - FILLER6",
            StoryMin = 10, StoryMax = 30,
            StartMessage   = "Travelers from a Far Garden...",
            Wave1 = {}, Wave1Time = 1, Wave2 = {}, Wave2Time = 1, Wave3 = {}, Wave3Time = 1,
            BossWave  = { "Exor Magus", "Exor_Monk", "Exorrior", }, BossWaveTime = 5,
        },
        {
            -- Just until exorsquad
            Name = "monkdad - MID",
            StoryMin = 35, StoryMax = 50,
            StartMessage   = "Travelers from a Far Garden...",
            Wave1 = {}, Wave1Time = 1, Wave2 = {}, Wave2Time = 1, Wave3 = {}, Wave3Time = 1,
            BossWave  = { "Exor", "Exor Magus", "Exor_Monk",  "Magma Exor", "Exorrior", "Magma Exor", }, BossWaveTime = 5,
        },
    },

}

return ASSAULTS