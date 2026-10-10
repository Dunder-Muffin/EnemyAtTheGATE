-- ===========================================================================================
-- INSTRUCTIONS FOR CREATING OR MODIFYING ASSAULTS
-- ===========================================================================================
-- 
-- * EnemyAtTheGATE updates may replace ASSAULTS_NORMAL or ASSAULTS_HARD
--     + IF you made changes to these files, back them up!
--     + Mod updates can overwrite those files - or put your entire file in ASSAULTS_CUSTOM 
--       and set difficulty to CUSTOM
-- 
-- * The table is grouped by ingame assault names. Don't change those.
--     + ex: The game may pick assault_monkdad for its next assault. 
--             This mod sees that string, and then picks one of our assaults under that group
-- 
-- * This mod tries not to repeat the last 5 custom assaults
-- 
-- * If the chosen assault doesn't have a custom assault that's valid, we should redraw it
-- 
-- 
-- ===========================================================================================
-- ASSAULT PARAMETERS - if you look at some of the assaults you'll get the picture
-- ===========================================================================================
-- 
-- > [StoryMin, StoryMax] - acts as a gating system - easier assaults early and harder ones later
--      * Offices=10, Manufacturing=20, Labs=30, Security=40, Hydro=50,
--        PowerSrv=60, Reactors=70, Praetorium=80, Residence=90+, BeatTheGame=102+
-- 
-- > [Warning/StartMessage] - (optional) replaces the Assault warning/start message
-- 
-- > [Wave1, Wave1Time, etc]. - Assaults happen in 4 waves. Empty waves are skipped
-- 
-- > [OnStart] - (optional) calls a function during the assault to do something
--      * SEE Managers/EventManager.lua and the assaults for examples
--      * Some actions
--          - EM.AssaultWeather() - adds a weather event to the assault
--          - EM.OrderDrop() - spawns Order units near the bench during the assault. You can modify the range
--          - EM.GatekeeperDrop() - unlike other drops, GK drops all emerge from one portal
--          - EM.Sequence(...) - call multiple functions
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
            Name = "peststorm - EARLY",
            StoryMin = 0, StoryMax = 20,
            Wave1     = { "Pest", "Pest", "Pest", "Pest", "Pest" },
            Wave1Time = 1,
            Wave2     = { "Pest", "Pest", "Pest", },
            Wave2Time = 6,
            Wave3     = { "Pest", "Pest" },
            Wave3Time = 3,
            BossWave  = { "Peccary" },
            BossWaveTime = 5,
        },
        {
            Name = "peststorm - CARBONATED STORM",
            StartMessage   = "A portal storm has started! With.. hiccups?",
            StoryMin = 20, StoryMax = 32,
            Wave1     = { "Pest_Carbonated", "Pest", "Pest", "Pest_Carbonated", "Pest", "Pest", "Pest_Carbonated" },
            Wave1Time = 1,
            Wave2     = { "Pest_Carbonated", "Pest_Carbonated", "Pest", "Pest_Carbonated", "Pest_Carbonated" },
            Wave2Time = 5,
            Wave3     = { "Peccary", "Peccary" },
            Wave3Time = 5,
            BossWave  = { "Peccary", "Exor_Monk" },
            BossWaveTime = 10,
        },
    },

    -- [0-32] assault_peccaryboss: Pestx5 | boss: Peccary | "A portal storm has started!" | 2/2/2/10 | (none)
    assault_peccaryboss = {
        {
            Name = "peccaryboss - EARLY",
            StoryMin = 0, StoryMax = 20,
            Wave1     = { "Pest", "Pest", "Peccary", },
            Wave1Time = 1,
            Wave2     = { "Pest", "Peccary", },
            Wave2Time = 6,
            Wave3     = { "Pest", "Pest" },
            Wave3Time = 3,
            BossWave  = { "Peccary" },
            BossWaveTime = 5,
        },
        {
            Name = "peccaryboss - EXOR",
            StoryMin = 20, StoryMax = 32,
            Wave1     = { "Pest", "Pest", "Peccary", "Pest", "Pest", "Peccary", },
            Wave1Time = 2,
            Wave2     = { "Peccary", "Pest_Carbonated", "Peccary", "Pest_Carbonated", "Peccary", },
            Wave2Time = 5,
            BossWave  = { "Exor_Monk", "Exor_Monk" },
            BossWaveTime = 5,
        },
    },

    -- [0-32] assault_peststorm_electro:   Pest_Electrox4 | boss: Sow | "A portal storm has started!" | 8/6/4/10 | LABS_ExploredLabs
    assault_peststorm_electro = {
        Name = "peststorm_electro - EARLY",
        StartMessage   = "A thunderous portal storm has started!",
        StoryMin = 30, StoryMax = 35,
        Wave1     = { "Pest", "Pest", "Pest_Electro", "Pest_Electro", "Pest_Electro" },
        Wave1Time = 1,
        Wave2     = { "Sow", "Pest_Electro", "Sow", "Pest_Electro" },
        Wave2Time = 5,
        Wave3     = { "Pest_Electro", "Sow" },
        Wave3Time = 5,
        BossWave  = { "Peccary_Electro" },
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
            StoryMin = 35, StoryMax = 60,
            StartMessage = "A pest Tempest!",
            Wave1     = { "Pest_Electro", "Pest_Electro", "Pest_Electro", },
            Wave1Time = 1,
            Wave2     = { "Peccary_Electro", "Exor_Monk", },
            Wave2Time = 10,
            Wave3     = { "Pest_Electro", "Pest_Electro", "Pest_Electro", "Peccary_Electro", 
                          "Pest_Electro", "Pest_Electro", "Pest_Electro", },
            Wave3Time = 1,
            BossWave  = { "Peccary_Electro", "Exor_Monk", "Exor_Monk" },
            BossWaveTime = 15
        },
        {
            Name = "pestfrenzy_electro - LATE ELECTRO",
            StoryMin = 60, StoryMax = 80,
            StartMessage = "A pest Tempest!",
            Wave1     = { "Pest_Electro", "Pest_Electro", "Pest_Electro", "Pest_Electro", "Pest_Electro", 
                          "Pest_Electro", "Pest_Electro", "Peccary_Electro", "Peccary_Electro", },
            Wave1Time = 1,
            Wave2     = { "Peccary_Electro", "Exor_Monk", "Exor_Monk", },
            Wave2Time = 7,
            Wave3     = { "Pest_Electro", "Pest_Electro", "Pest_Electro", "Pest_Electro", "Peccary_Electro",
                          "Pest_Electro", "Pest_Electro", "Pest_Electro", "Exor_Monk", "Peccary_Electro", 
                          "Pest_Electro", "Pest_Electro", "Pest_Electro", "Exor_Monk", },
            Wave3Time = 1,
            BossWave  = { "Peccary_Electro", "Exor_Monk", "Exor_Monk" },
            BossWaveTime = 20
        },
        {
            Name = "pestfrenzy_electro - LATE VOLATILE",
            StoryMin = 80, StoryMax = 100,
            StartMessage = "A Pestilence!",
            Wave1     = { "Pest_Volatile", "Pest_Volatile", "Pest_Volatile", "Pest_Volatile", 
                          "Pest_Volatile", "Pest_Volatile", "Pest_Volatile", "Pest_Volatile", 
                          "Exor", "Exor",  },
            Wave1Time = 2,
            Wave2     = { "Peccary_Volatile", "Exor_Volatile", "Peccary_Volatile" },
            Wave2Time = 20,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Pest_Volatile", "Pest_Volatile", "Pest_Volatile", 
                          "Peccary_Volatile", "Exor_Volatile", "Exor_Volatile"  },
            BossWaveTime = 3,
            OnStart = EM.Sequence(
                EM.AssaultWeather("RadLeak", 180000, 15000)
            )
        },
        {
            Name = "pestfrenzy_electro - LATE MAGMA",
            StoryMin = 80, StoryMax = 100,
            WarningMessage = "You feel a slight temperature change...",
            StartMessage   = "Thermal hypesthesia! Its hotter than you feel!",
            Wave1     = { "Pest_Magma", "Pest_Magma", "Pest_Magma", "Pest_Magma", "Pest_Magma", 
                          "Pest_Magma", "Pest_Magma", "Pest_Magma", "Peccary_Volatile",  },
            Wave1Time = 1,
            Wave2     = { "Peccary_Volatile", "Exor_Volatile", },
            Wave2Time = 20,
            Wave3     = { "Pest_Magma", "Exor_Volatile", "Pest_Magma", "Exor_Volatile", },
            Wave3Time = 2,
            BossWave  = { "Exor_Volatile", "Pest_Magma", "Pest_Magma", "Pest_Volatile", "Pest_Volatile",  },
            BossWaveTime = 3,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Spores", 180000, 20000),
                EM.SkinkDrop(15000, { spawns = { magmaskinks=2 }, faction=5, spawnRadius=2500, minSpawnRadius=1500 })
            )
        },
        {
            Name = "pestfrenzy_electro - END",
            StoryMin = 90, StoryMax = 999,
            WarnMessage    = "The portal suppressor is going haywire...",
            StartMessage   = "An inpestation!",
            Wave1     = { "Pest", "Pest", "Pest_Carbonated", "Pest_Rat", "Pest_Electro", "Pest_Electro",
                          "Pest_Volatile", "Pest_Magma", "Pest", "Pest_Magma", "Pest_Electro", "Peccary_Electro",
                          "Exor_Monk", "Exor", 
                          "Pest_Electro", "Pest_Carbonated", "Pest_Magma", "Pest_Carbonated", "Pest_Rat", "Peccary_Armored",
                          "Sow", "Peccary_Mushroom", "Peccary", "Peccary", "Peccary_Electro", "Sow",
                          "Exor_Monk", "Exor", 
                        },
            Wave1Time = 1,
            Wave2     = { "Exor_Monk", "Exor", "Peccary_Volatile", "Peccary_Armored", 
                          "Exor_Armored", "Exor", "Exor_Pikeman", "Exor", "Exor_Pikeman" },
            Wave2Time = 7,
            Wave3     =  { "Pest_Enlightened", "Exor_Pikeman", "Pest_Enlightened", "Pest_Enlightened",
                           "Pest_Enlightened", "Exor_Pikeman", "Pest_Enlightened", "Pest_Enlightened", },
            Wave3Time = 7,
            BossWave  = { "Pest_Leyak", "Pest_Leyak", },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Spores", 240000, 25000)
            )
        }
    },

    -- [11-999] assault_monkdad: Exor_Monk, Peccary, Peccary | boss: none | "Something fowl lurks nearby…" | 2/2/2/10 | Office_Silo3Opened
    assault_monkdad = {
        {
            Name = "monkdad - EARLY",
            StoryMin = 10, StoryMax = 25,
            StartMessage   = "Travelers from a Far Garden...",
            Wave1     = { "Pest", "Pest", "Peccary", "Peccary", },
            Wave1Time = 3,
            Wave2     = { "Exor_Monk", },
            Wave2Time = 10,
            Wave3     = {},
            Wave3Time = 1,
            BossWave  = { "Exor_Monk", },
            BossWaveTime = 15,
        },
        {
            Name = "monkdad - EARLY2",
            StoryMin = 10, StoryMax = 25,
            StartMessage   = "Travelers from a Far Garden...",
            Wave1     = { "Pest", "Pest", "Pest", "Pest", "Pest", },
            Wave1Time = 3,
            Wave2     = { "Peccary", },
            Wave2Time = 10,
            Wave3     = {},
            Wave3Time = 1,
            BossWave  = { "Peccary", "Peccary", "Exor_Monk", },
            BossWaveTime = 1,
        },
        {
            Name = "monkdad - EARLY3",
            StoryMin = 10, StoryMax = 25,
            StartMessage   = "Travelers from a Far Garden...",
            Wave1     = { },
            Wave1Time = 1,
            Wave2     = { },
            Wave2Time = 1,
            Wave3     = {},
            Wave3Time = 1,
            BossWave  = { "Exor_Monk", "Exor_Monk", "Exor_Monk", },
            BossWaveTime = 12,
        },
        {
            Name = "monkdad - EARLY4",
            StoryMin = 10, StoryMax = 25,
            StartMessage = "Something fowl lurks nearby...",
            Wave1     = { "Pest", "Pest", "Pest", "Pest", "Pest", "Pest", "Pest", "Pest", },
            Wave1Time = 1,
            Wave2     = { "Pest" },
            Wave2Time = 10,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Exor_Monk", "Exor_Monk"  },
            BossWaveTime = 1,
        },
        {
            Name = "monkdad - EARLY5",
            StoryMin = 10, StoryMax = 25,
            StartMessage   = "Travelers from a Far Garden...",
            Wave1     = { "Exor_Monk", "Peccary", },
            Wave1Time = 3,
            Wave2     = { },
            Wave2Time = 1,
            Wave3     = { "Exor_Monk", },
            Wave3Time = 15,
            BossWave  = { "Peccary", "Peccary", },
            BossWaveTime = 1
        },
        {
            Name = "monkdad - EARLY6",
            StoryMin = 10, StoryMax = 25,
            StartMessage   = "Travelers from a Far Garden...",
            Wave1     = { "Pest", "Pest_Carbonated", "Pest", "Pest_Carbonated", "Pest_Carbonated", },
            Wave1Time = 3,
            Wave2     = { "Peccary", "Peccary", },
            Wave2Time = 1,
            Wave3     = { "Exor_Monk", },
            Wave3Time = 15,
            BossWave  = { "Exor_Monk", "Exor_Monk", },
            BossWaveTime = 15
        },
        {
            Name = "monkdad - EARLYMID",
            StoryMin = 25, StoryMax = 32,
            StartMessage   = "Travelers from a Far Garden...",
            Wave1     = { "Exor_Monk", "Pest", "Pest", "Pest_Carbonated", "Pest", "Pest", "Pest_Carbonated", },
            Wave1Time = 3,
            Wave2     = { "Peccary", "Peccary", },
            Wave2Time = 1,
            Wave3     = { "Exor_Monk", },
            Wave3Time = 15,
            BossWave  = { "Exor_Monk", "Exor_Monk", },
            BossWaveTime = 1
        },
        {
            Name = "monkdad - EARLYMID2",
            StoryMin = 25, StoryMax = 32,
            StartMessage   = "Travelers from a Far Garden...",
            Wave1     = { "Exor_Monk", "Pest", "Pest", "Pest_Carbonated", "Pest", "Pest", "Pest_Carbonated", },
            Wave1Time = 3,
            Wave2     = { "Peccary", "Peccary", },
            Wave2Time = 1,
            Wave3     = { "Exor_Monk", },
            Wave3Time = 15,
            BossWave  = { "Exor_Monk", "Exor_Monk", },
            BossWaveTime = 1
        },
        {
            Name = "monkdad - MID",
            StoryMin = 35, StoryMax = 50,
            StartMessage   = "Strange frequencies fill the air...",
            Wave1     = { "Exor", "Pest", "Pest", "Pest_Carbonated", "Pest", "Pest", "Pest_Carbonated", },
            Wave1Time = 2,
            Wave2     = { "Peccary", "Peccary", },
            Wave2Time = 2,
            Wave3     = { "Exor", "Exor", "Exor", },
            Wave3Time = 2,
            BossWave  = { "Exor_Monk" },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.AssaultWeather("RadLeak", 30000, 25000)
            )
        },
        {
            Name = "monkdad - MID xORDER",
            StoryMin = 50, StoryMax = 70,
            StartMessage   = "The smell of smoke and ozone...",
            Wave1     = { "Pest_Electro", "Pest_Electro", "Pest_Electro", "Pest_Electro", "Pest_Electro", 
                          "Pest_Electro", "Peccary_Electro", "Peccary_Electro", "Pest_Electro",
                          "Exor", "Peccary_Electro", "Exor", "Exor_Monk", "Peccary_Electro", "Exor", },
            Wave1Time = 1,
            Wave2     = { "Exor_Monk" },
            Wave2Time = 10,
            Wave3     = { "Grunt", "Grunt_Guard", "Grunt", "Grunt_Guard", "Grunt", "Grunt_Guard", "Grunt_Medic" },
            Wave3Time = 1,
            BossWave  = { "Grunt_Shotgun", "Grunt", "Grunt_Captain", "Grunt_Shotgun", "Grunt", },
            BossWaveTime = 2,
            OnStart = EM.Sequence(
                EM.AssaultWeather("RadLeak", 60000, 25000)
            )
        },
        {
            Name = "monkdad - LATE xORDER",
            StoryMin = 72, StoryMax = 90,
            StartMessage   = "The smell of smoke and ozone...",
            Wave1     = { "Pest_Electro", "Pest_Electro", "Pest_Electro", "Pest_Electro", 
                          "Peccary_Electro", "Peccary_Electro",
                          "Exor_Monk", "Exor_Monk", "Exor_Monk", "Exor_Armored",
                          "Peccary_Electro", "Peccary_Electro", "Peccary_Electro", 
                          "Exor_Armored", "Exor_Monk", "Exor_Monk", "Exor_Monk", "Exor_Monk", "Exor", 
                           },
            Wave1Time = 1,
            Wave2     = { "Exor", },
            Wave2Time = 10,
            Wave3     = { "Grunt", "Grunt", "Grunt", "Grunt", "Grunt_Medic", "Grunt_Medic", 
                          "Grunt", "Grunt", "Grunt", "Grunt", "Grunt_Captain", "Grunt_Captain",
                          "Grunt_Sapper", "Grunt_Shotgun", "Grunt_Shotgun", "Grunt_Sapper",
                          "Grunt_Shotgun", "Grunt_Shotgun", },
            Wave3Time = 2,
            BossWave  = { "Exor_Monk", "Exor_Monk", "Exor_Armored", },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.AssaultWeather("RadLeak", 60000, 25000)
            )
        },
        {
            Name = "monkdad - END",
            StoryMin = 90, StoryMax = 999,
            StartMessage   = "The fog before the storm...",
            Wave1     = { "Exor_Pikeman", "Exor", "Exor_Pikeman", "Exor", "Exor_Pikeman", 
                          "Exor_Monk", "Exor_Monk", "Exor_Monk", "Exor_Monk", "Exor",
                          "Exor_Monk", "Exor_Monk", "Exor_Monk", "Exor_Monk", "Exor", },
            Wave1Time = 2,
            Wave2     = { "Exor_Pikeman", },
            Wave2Time = 10,
            Wave3     =  { "Symph", "Symph", "Symph", "Symph", "Symph", "Symph",  },
            Wave3Time = 2,
            BossWave  = { "Exor_Pikeman", "Exor_Pikeman", "Exor_Pikeman", "Exor_Pikeman" },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Fog", 240000, 18000)
            )
        }
    },

    -- assault_exorsquad: Exor_Monk, Exor_Armored, Exor_Monk | boss: none | "Something fowl lurks nearby…" | 5/4/3/10 | Dams_ReachedCentral
    assault_exorsquad = {
        {
            Name = "exorsquad - MID",
            StoryMin = 52, StoryMax = 70,
            StartMessage   = "An exor warband!",
            Wave1     = { "Exor", "Exor", "Peccary", "Peccary", "Sow",
                          "Exor_Monk", "Exor_Monk", "Peccary_Mushroom", "Peccary_Mushroom", "Peccary_Mushroom",  },
            Wave1Time = 2,
            Wave2     = { "Exor_Armored" },
            Wave2Time = 20,
            Wave3     = { "Exor", "Exor", },
            Wave3Time = 1,
            BossWave  = { "Exor", "Exor_Armored",  },
            BossWaveTime = 10
        },
        {
            Name = "exorsquad - LATE",
            StoryMin = 71, StoryMax = 90,
            StartMessage   = "An exor warband!",
             Wave1     = { "Exor_Armored", "Exor_Armored", "Peccary_Armored", "Peccary_Armored", "Peccary_Armored",
                          "Exor_Monk", "Exor_Monk", "Peccary_Volatile", "Peccary_Volatile", "Peccary_Volatile",  },
            Wave1Time = 2,
            Wave2     = { "Exor_Armored", "Exor_Pikeman" },
            Wave2Time = 15,
            Wave3     = { "Exor_Volatile", "Exor_Volatile", },
            Wave3Time = 1,
            BossWave  = { "Exor_Pikeman", "Exor_Pikeman", "Exor_Pikeman",   },
            BossWaveTime = 20
        },
        {
            Name = "exorsquad - END",
            StoryMin = 90, StoryMax = 100,
            StartMessage = "An exor legion!",
            Wave1     = { "Exor", "Exor_Volatile", "Exor",
                          "Sow", "Sow", "Sow",
                          "Exor_Armored", "Exor_Pikeman", "Exor_Armored", 
                          "Peccary", "Peccary", "Peccary_Armored", },
            Wave1Time = 2,
            Wave2     = { "Peccary_Volatile", "Peccary_Volatile", "Peccary_Volatile", },
            Wave2Time = 10,
            Wave3     = { "Exor_Monk", "Exor_Pikeman", "Exor_Monk", "Exor_Pikeman", "Exor_Monk",
                          "Peccary_Electro", "Exor", "Peccary_Electro", "Exor",
                          "Pest_Enlightened", "Exor_Pikeman", "Pest_Enlightened", "Exor_Pikeman",
                          "Peccary_Electro", "Peccary_Electro",
                          "Exor_Armored", "Exor_Volatile", },
            Wave3Time = 2,
            BossWave  = { "Peccary_Volatile", "Peccary_Volatile", "Exor_Volatile", },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Spores", 90000, 21000)
            )
        
        },
    },
   

    -- ========================================================
    -- ORDER centric
    -- ========================================================

    -- [20-60] assault_smggrunt: Grunt | boss: none | "A radio crackle is heard nearby…" | 2/2/2/10 | MF_MetBlacksmith
    assault_smggrunt = {
        {
            Name       = "smggrunt - EARLY",
            StoryMin   = 20, StoryMax = 40,
            StartMessage = "A radio crackle is heard nearby...",
            Wave1     = { "Grunt_Guard", "Grunt_Guard", "Grunt_Guard", },
            Wave1Time = 2,
            Wave2     = { "Grunt_Medic", "Grunt_Captain" },
            Wave2Time = 15,
            Wave3     = { "Grunt_Guard", "Grunt_Guard", "Grunt_Medic" },
            Wave3Time = 2,
            BossWave  = { "Grunt_Medic", "Grunt_Captain" },
            BossWaveTime = 10
        },
        {
            Name       = "smggrunt - MID",
            StoryMin   = 40, StoryMax = 60,
            StartMessage = "A radio crackle is heard nearby...",
            Wave1     = { "Grunt_Guard", "Grunt", "Grunt_Medic", "Grunt_Shotgun" },
            Wave1Time = 2,
            Wave2     = { "Grunt_Captain", },
            Wave2Time = 20,
            Wave3     = { "Grunt_Shotgun", "Grunt_Guard", "Grunt_Medic", "Grunt",
                          "Grunt_Guard", "Grunt", "Grunt_Medic", "Grunt_Shotgun"  },
            Wave3Time = 2,
            BossWave  = { "Grunt_Captain" },
            BossWaveTime = 15
        },
    },
   
    -- [40-100] assault_shotgunsquad: Grunt_Captain, Grunt_Medic, Grunt_Shotgun | boss: none | "A radio crackle is heard nearby…" | 5/5/5/10 | LABS_ReachedCommandCenter
    assault_shotgunsquad = {
        {
            Name       = "shotgunsquad - MID",
            StoryMin   = 40, StoryMax = 60,
            StartMessage = "A radio crackle is heard nearby...",
            Wave1     = { "Grunt_Shotgun", "Grunt_Shotgun", "Grunt_Shotgun", "Grunt_Medic", "Grunt_Medic", },
            Wave1Time = 2,
            Wave2     = { "Grunt_Captain" },
            Wave2Time = 20,
            Wave3     = { "Grunt_Shotgun", "Grunt_Shotgun", "Grunt_Shotgun", "Grunt_Shotgun",
                          "Grunt_Medic", "Grunt_Medic", },
            Wave3Time = 1,
            BossWave  = { "Grunt_Captain" },
            BossWaveTime = 30
        },
        {
            Name       = "shotgunsquad - LATE",
            StoryMin   = 60, StoryMax = 80,
            WarningMessage = "The lights flicker...",
            StartMessage = "Close quarters Order!",
            Wave1      = { "Grunt_Shotgun", "Grunt_Shotgun", "Grunt_Shotgun", 
                          "Groupe_Grunt", "Grunt_Medic", "Grunt_Medic", },
            Wave1Time = 3,
            Wave2     = { "Grunt_Captain", },
            Wave2Time = 20,
            Wave3     = { "Groupe_Shotgun", "Grunt_Shotgun", "Grunt_Shotgun", "Grunt_Shotgun",
                          "Groupe_Grunt", "Groupe_Grunt", "Grunt_Medic", "Grunt_Medic", },
            Wave3Time = 1,
            BossWave  = { "Grunt_Captain", "Grunt_Captain", "Grunt_Captain",  },
            BossWaveTime = 5,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Blackout", 60000, 15000)
            ) 
        },
        {
            Name       = "shotgunsquad - END LEECH",
            StoryMin   = 80, StoryMax = 999,
            WarningMessage = "The lights flicker...",
            StartMessage = "Something materializes above!",
            Wave1     = { "Groupe_Rook", "Groupe_Shotgun", "Grunt_Shotgun", "Grunt_Shotgun", 
                          "Groupe_Rook", "Groupe_Shotgun", "Grunt_Shotgun", "Grunt_Shotgun", },
            Wave1Time = 2,
            Wave2     = { "Grunt_Captain", },
            Wave2Time = 25,
            Wave3     = { "Trooper_Shotgun", "Trooper_Shotgun", "Trooper_Shotgun", "Trooper_Shotgun",
                          "Trooper", "Trooper", "Grunt_Captain", "Grunt_Captain" },
            Wave3Time = 5,
            BossWave  = { "Grunt_FlameRat", "Grunt_FlameRat", },
            BossWaveTime = 3,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Blackout", 75000, 15000),
                EM.PowerLeechBossDrop(1000, { spawns = { powerLeeches=1 }})
            ) 
        },
    },

    -- [60-999] assault_groupe: Groupe_Grunt, Groupe_Rook, Groupe_Shotgun | boss: none | "A cold wind blows through…" | 2/2/2/10 | DAMS_CompletedVoussoir
    -- * Becomes Praetorium based
    assault_groupe = {
        {
            Name       = "groupe - MID",
            StoryMin   = 60, StoryMax = 80,
            StartMessage = "A groupe assault!",
            Wave1     = { "Groupe_Shotgun", "Groupe_Rook", "Groupe_Grunt", "Grunt_Captain" },
            Wave1Time = 2,
            Wave2     = { "Grunt_Captain" },
            Wave2Time = 15,
            Wave3     = { "Groupe_Shotgun", "Groupe_Rook", "Groupe_Grunt", "Groupe_Shotgun", "Groupe_Rook", "Groupe_Grunt",  },
            Wave3Time = 2,
            BossWave  = { "Grunt_Captain", "Groupe_Rook", "Grunt_Captain", 
                          "Groupe_Shotgun", "Grunt_Captain", "Groupe_Grunt", },
            BossWaveTime = 5
        },
        {
            Name       = "groupe - LATE",
            StoryMin   = 80, StoryMax = 100,
            StartMessage = "A groupe assault!",
            Wave1     = { "Grunt_Sapper", "Groupe_Grunt", "Groupe_Grunt", "Groupe_Rook", "Groupe_Rook", 
                          "Groupe_Shotgun", "Groupe_Shotgun", "Grunt_Captain", },
            Wave1Time = 2,
            Wave2     = { "Grunt_Captain" },
            Wave2Time = 20,
            Wave3     = { "Groupe_Grunt", "Groupe_Grunt", "Groupe_Rook", "Groupe_Rook", 
                          "Groupe_Shotgun", "Groupe_Shotgun", "Grunt_Captain", },
            Wave3Time = 2,
            BossWave  = { "Grunt_Sapper", "Groupe_Shotgun", "Groupe_Rook", "Groupe_Grunt", 
                          "Grunt_Sapper", "Groupe_Shotgun", "Groupe_Rook", "Groupe_Grunt", },
            BossWaveTime = 7
        },
        {
            Name       = "groupe - END Praetorium",
            StoryMin   = 90, StoryMax = 999,
            StartMessage = "A response from the Praetorium",
            Wave1     = { "Trooper", "Trooper", "Trooper", "Trooper", "Trooper", 
                          "Grunt_Medic", "Grunt_Medic", "Grunt_Captain",
                          "Grunt_Sapper", "Grunt_Sapper", "Interfector", },
            Wave1Time = 2,
            Wave2     = { "Grunt_LabRat_Mechanic", "Grunt_LabRat_Mechanic", "Grunt_LabRat_Mechanic", "Grunt_FlameRat" },
            Wave2Time = 5,
            Wave3     = { "Trooper_Shield", "Trooper_Shield", "Trooper_Shotgun", "Trooper_Shotgun", 
                          "Trooper", "Trooper", "Trooper", 
                          "Grunt_Medic", "Grunt_Medic", "Grunt_Captain",
                          "Grunt_Sapper", "Grunt_Sapper", "Interfector", },
            Wave3Time = 2,
            BossWave  = { "Grunt_FlameRat", "Grunt_FlameRat", "Grunt_FlameRat", },
            BossWaveTime = 15,
            OnStart = EM.Sequence(
                EM.OrderDrop(5000, { spawns = { interfectors=1 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(35000, { spawns = { interfectors=1 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(65000, { spawns = { interfectors=1 }, spawnRadius=3000, minSpawnRadius=1500 })
            )
        },
        {
            Name = "groupe - END Prae xReaper",
            StoryMin = 100, StoryMax = 999,
            StartMessage = "An ancient nemesis...",
            Wave1     = { "Interfector", "Interfector", "Interfector", },
            Wave1Time = 5,
            Wave2     = { "Grunt_LabRat", "Grunt_LabRat", "Grunt_Guard", "Grunt_Guard", 
                          "Grunt", "Grunt", "Grunt_Medic", "Grunt_Medic", 
                          "Grunt_Captain", "Grunt_Captain", "Grunt_Breacher", "Grunt_Breacher", 
                          "Groupe_Grunt", "Groupe_Grunt", "Groupe_Rook", "Groupe_Rook", 
                          "Groupe_Shotgun", "Groupe_Shotgun", "Grunt_Sapper", "Grunt_Sapper", 
                          "Trooper", "Trooper", "Trooper_Shield", "Trooper_Shield", 
                          "Trooper_Shotgun", "Trooper_Shotgun", "Interfector", "Interfector", 
                          "Grunt_LabRat_Mechanic", "Grunt_LabRat_Mechanic", "Grunt_FlameRat", "Grunt_FlameRat" },
            Wave2Time = 1,
            Wave3     = { "Grunt_Captain", "Grunt_Captain", "Reaper", },
            Wave3Time = 7,
            BossWave  = { "Reaper", "Reaper", },
            BossWaveTime = 2,
            OnStart = EM.Sequence(
                EM.AssaultWeather("BlackFog", 120000, 60000),
                EM.ReaperDrop(20000, { spawns = { reapers=4 }, spawnInterval=20000, spawnRadius=2500, minSpawnRadius=1200 })
            )
        }
    },
   
    -- [20-999] assault_ratpatrol: Grunt_LabRat | boss: none | (no message) | 5/5/5/10 | MF_MetSoldier
    assault_ratpatrol = {
        {
            Name = "ratpatrol - EARLY",
            StoryMin = 20, StoryMax = 40,
            StartMessage   = "An inquisition patrol!",
            Wave1     = { "Grunt_LabRat", "Grunt_LabRat", "Grunt_LabRat", "Grunt_LabRat",  },
            Wave1Time = 2,
            Wave2     = { "Grunt_Guard", "Grunt_Guard", },
            Wave2Time = 10,
            Wave3     = { "Grunt_Guard", "Grunt_LabRat", "Grunt_Captain", "Grunt_LabRat", },
            Wave3Time = 2,
            BossWave  = { "Grunt_LabRat", "Pest_Rat" },
            BossWaveTime = 15,
        },
        {
            Name = "ratpatrol - MID",
            StoryMin = 40, StoryMax = 60,
            StartMessage   = "An inquisition patrol!",
            Wave1     = { "Grunt_LabRat", "Grunt_LabRat", "Grunt_LabRat",  
                          "Grunt_Shotgun", "Grunt_Shotgun", "Grunt", "Grunt",
                          "Grunt_LabRat", "Grunt_LabRat", "Grunt_LabRat", },
            Wave1Time = 2,
            Wave2     = { "Grunt_Captain", "Grunt_LabRat", "Grunt_Captain", },
            Wave2Time = 7,
            Wave3     = { "Grunt_LabRat", "Grunt_LabRat", "Grunt_LabRat", "Grunt_LabRat",
                          "Grunt_Guard", "Grunt", "Grunt_Medic", "Grunt_Captain", },
            Wave3Time = 2,
            BossWave  = { "Grunt_LabRat", "Pest_Rat" },
            BossWaveTime = 15
        },
        {
            Name = "ratpatrol - LATE",
            StoryMin = 71, StoryMax = 90,
            StartMessage   = "A swarm of rats!",
            Wave1     = { "Grunt_Sapper", "Grunt_LabRat", "Grunt_LabRat", "Grunt_LabRat",
                          "Grunt_Sapper", "Grunt_LabRat", "Grunt_LabRat", "Grunt_LabRat", },
            Wave1Time = 2,
            Wave2     = { "Grunt_Sapper", "Grunt_LabRat", },
            Wave2Time = 15,
            Wave3     = { "Grunt_Sapper", "Grunt_LabRat", "Grunt_LabRat", "Grunt_Captain", 
                          "Grunt_Sapper", "Grunt_LabRat", "Grunt_LabRat", "Grunt_Captain", },
            Wave3Time = 3,
            BossWave  = { "Grunt_Sapper", "Grunt_Sapper", "Pest_Rat" },
            BossWaveTime = 15
        },
        {
            Name = "ratpatrol - END",
            StoryMin = 90, StoryMax = 999,
            StartMessage   = "No one expects the Ordo Inquisition!",
            Wave1     = { "Grunt_Sapper", "Grunt_LabRat", "Grunt_LabRat_Mechanic", 
                          "Grunt_Sapper", "Grunt_LabRat", "Grunt_LabRat_Mechanic", },
            Wave1Time = 3,
            Wave2     = { "Grunt_Sapper", "Grunt_Sapper", },
            Wave2Time = 15,
            Wave3     = { "Interfector", "Interfector", "Grunt_Captain", "Grunt_Captain", 
                          "Grunt_LabRat", "Grunt_LabRat", "Grunt_LabRat" },
            Wave3Time = 2,
            BossWave  = { "Grunt_FlameRat", "Grunt_FlameRat" },
            BossWaveTime = 5,
            OnStart = EM.Sequence(
                EM.RatDrop(1000, { spawns = { labRats=2, garageRats=2 }})
            )
        },
    },


   
    -- ========================================================
    -- GK Centric
    -- ========================================================

    -- [70-999] assault_mages: Gatekeeper_Phyterx2 | boss: Gatekeeper_Mage | "Something arcane tingles your senses…" | 5/5/4/10 | Reactors_S1Labs_Complete
    assault_mages={
        {
            Name = "mages - MIDLATE",
            StoryMin = 70, StoryMax = 80,
            Wave1     = { "Gatekeeper_Phyter", "Gatekeeper_Mage", },
            Wave1Time = 2,
            Wave2     = { "Gatekeeper_Mage", },
            Wave2Time = 20,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Gatekeeper_Phyter", "Gatekeeper_Phyter", "Gatekeeper_Phyter", },
            BossWaveTime = 5
        },
        {
            Name = "mages - LATE",
            StoryMin = 80, StoryMax = 90,
            StartMessage = "Something arcane assaults your senses...",
            Wave1     = { "Gatekeeper_Phyter", "Gatekeeper_Mage", },
            Wave1Time = 2,
            Wave2     = { "Gatekeeper_Mage", "Gatekeeper_Chieftain" },
            Wave2Time = 12,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Gatekeeper_Mage", "Gatekeeper_Phyter", "Gatekeeper_Phyter", },
            BossWaveTime = 5
        },
        {
            Name = "mages - END",
            StoryMin = 90, StoryMax = 999,
            StartMessage = "Something arcane overwhelms your senses...",
            Wave1     = { "Gatekeeper_Witch", "Gatekeeper_Witch", "Gatekeeper_Mage", "Gatekeeper_Chieftain" },
            Wave1Time = 2,
            Wave2     = { "Gatekeeper_Witch", "Gatekeeper_Witch", "Gatekeeper_Mage", },
            Wave2Time = 12,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Gatekeeper_Mage", "Gatekeeper_Mage", },
            BossWaveTime = 5
        }
    },
   
    
    -- [72-999] assault_gkheavy: Gatekeeper_Chieftain, Gatekeeper_Heavy, Gatekeeper_Mage | boss: none | "The bones are cast." | 5/5/4/10 | Reactors_S2War_Complete
    assault_gkheavy = {
        {
            Name = "gkheavy - LATE",
            StoryMin = 70, StoryMax = 90,
            Wave1     = { "Gatekeeper_Phyter", "Gatekeeper_Phyter", "Gatekeeper_Phyter", "Gatekeeper_Heavy", },
            Wave1Time = 2,
            Wave2     = { "Gatekeeper_Phyter" },
            Wave2Time = 20,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = {  "Gatekeeper_Heavy", "Gatekeeper_Chieftain",},
            BossWaveTime = 10,
        },
        {
            Name = "gkheavy - END",
            StoryMin = 90, StoryMax = 100,
            Wave1     = { "Gatekeeper_Heavy", "Gatekeeper_Phyter", "Gatekeeper_Chieftain", },
            Wave1Time = 2,
            Wave2     = { "Gatekeeper_Heavy" },
            Wave2Time = 20,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Gatekeeper_Chieftain", "Gatekeeper_Heavy", "Gatekeeper_Heavy" },
            BossWaveTime = 10,
        },
        {
            Name = "gkheavy - END xORDER",
            StoryMin = 90, StoryMax = 999,
            WarningMessage = "You hear gunfire in the distance...",
            StartMessage = "A confrontation!",
            Wave1     = { "Gatekeeper_Heavy", "Gatekeeper_Heavy", "Gatekeeper_Chieftain",
                          "Gatekeeper_Phyter", "Gatekeeper_Phyter", "Gatekeeper_Phyter", "Gatekeeper_Phyter",  },
            Wave1Time = 2,
            Wave2     = { "Gatekeeper_Chieftain" },
            Wave2Time = 10,
            Wave3     = { "Grunt_Sapper", "Grunt_Captain", "Interfector", "Interfector", 
                          "Grunt_Guard", "Grunt_Guard", "Grunt_Guard", "Trooper", "Trooper", 
                          "Trooper_Shotgun", "Groupe_Shotgun", "Grunt_Shotgun", },
            Wave3Time = 2,
            BossWave  = { "Gatekeeper_Heavy", "Gatekeeper_Phyter", "Gatekeeper_Heavy", "Gatekeeper_Chieftain" },
            BossWaveTime = 7
        }
    },

    -- [75-999] assault_gksquad: Gatekeeper_Chieftain, Gatekeeper_Phyter, Gatekeeper_Witch | boss: none | "The bones are cast." | 5/5/4/10 | Reactors_SG_InteriorContact
    assault_gksquad = {
        {
            Name = "gksquad - LATE",
            StoryMin = 70, StoryMax = 90,
            Wave1     = { "Gatekeeper_Phyter", "Gatekeeper_Witch", "Gatekeeper_Mage" },
            Wave1Time = 5,
            Wave2     = { "Gatekeeper_Chieftain", "Gatekeeper_Heavy", },
            Wave2Time = 15,
            Wave3     = { },
            Wave3Time = 2,
            BossWave  = { "Gatekeeper_Phyter", "Gatekeeper_Witch", "Gatekeeper_Mage" },
            BossWaveTime = 2,
        },
        {
            Name = "gksquad - END xA2",
            StoryMin = 90, StoryMax = 100,
            StartMessage = "Containment breach!",
            Wave1     = { "Exor_Monk", "Pest", "Pest", "Pest_Snow", "Pest_Volatile", 
                          "Exor", "Peccary_Mushroom", "Peccary_Snow", "Peccary_Snow", "Peccary_Volatile", 
                          "Exor_Armored", "Exor", "Exor_Monk", "Exor_Monk",
                          "Exor_Pikeman", "Exor_Pikeman", },
            Wave1Time = 2,
            Wave2     = { "Exor_Volatile", },
            Wave2Time = 10,
            Wave3     = { "Gatekeeper_Heavy", "Gatekeeper_Heavy", "Gatekeeper_Phyter", "Gatekeeper_Phyter", 
                          "Gatekeeper_Chieftain", "Gatekeeper_Mage", "Gatekeeper_Mage" },
            Wave3Time = 2,
            BossWave  = { "Exor_Volatile", "Exor_Volatile", "Peccary_Volatile", "Peccary_Volatile",  },
            BossWaveTime = 10
        },
        {
            Name = "gksquad - END BOSS",
            StoryMin = 90, StoryMax = 100,
            StartMessage = "Defenders of the Dark Lens!",
            Wave1     = { "Gatekeeper_Phyter", "Gatekeeper_Phyter", "Gatekeeper_Phyter", "Gatekeeper_Chieftain", },
            Wave1Time = 2,
            Wave2     = { "Gatekeeper_Heavy", "Gatekeeper_Heavy",  },
            Wave2Time = 15,
            Wave3     = { "Gatekeeper_Witch", "Gatekeeper_Witch", "Gatekeeper_Witch", "Gatekeeper_Witch", "Gatekeeper_Chieftain", },
            Wave3Time = 2,
            BossWave  = { "Gatekeeper_Heavy", },
            BossWaveTime = 20,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Blackfog", 25000, 21000)
            ) 
        },
    },

    -- [75-999] assault_witchhunt: Gatekeeper_Witch×3 | boss: none | "A hex upon your house." | 2/2/2/10 | Reactors_SG_InteriorContact
    assault_witchhunt = {
        {
            Name = "witchhunt - LATE",
            StoryMin = 70, StoryMax = 90,
            StartMessage = "A horrifying hex!",
            Wave1     = { "Gatekeeper_Witch", "Gatekeeper_Witch", },
            Wave1Time = 1,
            Wave2     = { "Gatekeeper_Witch", },
            Wave2Time = 20,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Gatekeeper_Witch", "Gatekeeper_Witch",
                          "Gatekeeper_Witch", },
            BossWaveTime = 5,
        },
        {
            Name = "witchhunt - END",
            StoryMin = 90, StoryMax = 100,
            StartMessage = "Witches and warlocks!",
            Wave1     = { "Gatekeeper_Chieftain", "Gatekeeper_Witch",  },
            Wave1Time = 15,
            Wave2     = { },
            Wave2Time = 1,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Gatekeeper_Witch", "Gatekeeper_Chieftain", "Gatekeeper_Witch", "Gatekeeper_Witch",  
                          "Gatekeeper_Chieftain", "Gatekeeper_Witch", "Gatekeeper_Chieftain", },
            BossWaveTime = 7
        },
        {
            Name = "witchhunt - LATE xA2",
            StoryMin = 90, StoryMax = 999,
            StartMessage = "A battle in the sky!",
            Wave1     = { "Exor_Volatile", "Exor_Volatile", "Exor_Volatile", "Exor_Volatile", "Exor_Volatile"},
            Wave1Time = 2,
            Wave2     = { "Exor_Volatile" },
            Wave2Time = 5,
            Wave3     = { "Gatekeeper_Witch", "Gatekeeper_Witch", "Gatekeeper_Witch", "Gatekeeper_Witch", "Gatekeeper_Witch" },
            Wave3Time = 2,
            BossWave  = { "Exor_Volatile", "Exor_Volatile", "Exor_Volatile", "Exor_Volatile",
                          "Gatekeeper_Witch", "Gatekeeper_Witch", "Gatekeeper_Witch", "Gatekeeper_Witch",
                          "Gatekeeper_Witch", "Exor_Volatile", "Gatekeeper_Witch", "Exor_Volatile", },
            BossWaveTime = 5
        }
    },



    -- ========================================================
    -- Robots
    -- ========================================================

    -- [20-999] assault_pistolbros: Grunt_Guardx2 | boss: none | "A radio crackle is heard nearby…" | 2/2/2/10 | MF_MetBlacksmith
    --   * Hijacking for Robot
    assault_pistolbros = {
        {
            Name = "pistolbros - ROBOT EARLY xA2",
            StoryMin = 20, StoryMax = 30,
            StartMessage   = "Security closes in...",
            StartSound = "/Game/Audio/Music/ShortStings/anteverse_sting.anteverse_sting",
            Wave1     = { "Robot_Security", },
            Wave1Time = 2,
            Wave2     = { "Robot_Security",  },
            Wave2Time = 15,
            Wave3     = { "Pest", "Pest", "Pest", "Pest", "Pest_Carbonated", "Pest_Carbonated",
                          "Pest", "Pest", "Peccary", "Peccary", "Peccary", "Peccary" },
            Wave3Time = 2,
            BossWave  = { "Robot_Security" },
            BossWaveTime = 10,
        },
        {
            Name = "pistolbros - ROBOT MID xA2",
            StoryMin = 35, StoryMax = 60,
            StartMessage   = "A containment breach!",
            StartSound = "/Game/Audio/Music/ShortStings/anteverse_sting.anteverse_sting",
            Wave1     = { "Pest", "Pest", "Pest_Electro", "Pest_Electro", "Sow", "Sow", "Sow" },
            Wave1Time = 2,
            Wave2     = { "Robot_Containment", "Robot_Containment", },
            Wave2Time = 10,
            Wave3     =  { "Exor", "Exor", "Exor_Monk", "Peccary", "Sow", "Sow" },
            Wave3Time = 2,
            BossWave  = { "Robot_Containment" },
            BossWaveTime = 10,
        },
        {
            Name = "pistolbros - ROBOT MID xORDER",
            StoryMin = 40, StoryMax = 70,
            StartMessage   = "Order will be contained.",
            StartSound = "/Game/Audio/Music/ShortStings/anteverse_sting.anteverse_sting",
            Wave1     = { "Grunt_Shotgun", "Grunt_Shotgun", "Grunt_Shotgun", 
                          "Grunt_Guard", "Grunt_Guard", "Grunt", "Grunt_Medic", "Grunt_Captain", 
                          "Grunt_Shotgun", "Grunt_Shotgun" },
            Wave1Time = 2,
            Wave2 = { "Robot_Containment", "Robot_Containment" },
            Wave2Time = 10,
            Wave3 = { "Grunt_LabRat", "Grunt_LabRat" },
            Wave3Time = 3,
            BossWave  = { "Robot_Containment", "Robot_Containment" },
            BossWaveTime = 5,
        },
        {
            Name = "pistolbros - ROBOT LATE XFIRE",
            StoryMin = 70, StoryMax = 90,
            WarningMessage = "Explosions echo in the distance...",
            StartMessage   = "The sounds get closer!",
            StartSound = "/Game/Audio/Music/ShortStings/anteverse_sting.anteverse_sting",
            Wave1     = { "Grunt", "Grunt", "Grunt_Guard", "Grunt_Captain" },
            Wave1Time = 2,
            Wave2 =  { "Robot_Defense", "Robot_Containment", },
            Wave2Time = 10,
            Wave3 =  { "Peccary", "Peccary_Electro", "Exor", "Exor_Armored", "Exor_Monk" },
            Wave3Time = 5,
            BossWave  = { "Robot_Defense", "Robot_Defense" },
            BossWaveTime = 10,
        },
        {
            Name = "pistolbros - ROBOT END XFIRE",
            StoryMin = 90, StoryMax = 100,
            WarningMessage = "Explosions echo in the distance...",
            StartMessage   = "The sounds get closer!",
            StartSound = "/Game/Audio/Music/ShortStings/anteverse_sting.anteverse_sting",
            Wave1     = { "Groupe_Shotgun", "Groupe_Shotgun", "Grunt_Sapper", 
                          "Grunt", "Grunt", "Grunt_Guard", "Grunt_Captain", "Grunt_Sapper",  },
            Wave1Time = 2,
            Wave2 =  { "Robot_Defense", "Robot_Defense", "Robot_Containment" },
            Wave2Time = 8,
            Wave3 =  { "Peccary_Armored", "Peccary_Volatile", "Exor", "Exor", "Exor_Armored", "Exor_Monk", "Exor_Volatile" },
            Wave3Time = 5,
            BossWave  = { "Robot_Defense", "Robot_Defense", "Robot_Containment", "Grunt_Sapper" },
            BossWaveTime = 10,
        },
        {
            Name = "pistolbros - ROBOT END",
            StoryMin = 90, StoryMax = 100,
            WarningMessage = "Explosions echo in the distance...",
            StartMessage   = "A robotic uprising!",
            StartSound = "/Game/Audio/Music/ShortStings/anteverse_sting.anteverse_sting",
            Wave1     = { "Robot_Security", "Robot_Security", "Robot_Security", "Robot_Security", 
                          "Robot_Containment", },
            Wave1Time = 3,
            Wave2     =  { "Robot_Defense", },
            Wave2Time = 30,
            Wave3     =  { "Robot_Security", "Robot_Security", "Robot_Security", 
                          "Robot_Containment", "Robot_Containment", },
            Wave3Time = 3,
            BossWave  = { "Robot_Defense", "Robot_Corrupt" },
            BossWaveTime = 10,
        },
        {
            Name = "pistolbros - ROBOT END",
            StoryMin = 102, StoryMax = 999,
            WarningMessage = "Explosions echo in the distance...",
            StartMessage   = "A robotic uprising!",
            StartSound = "/Game/Audio/Music/ShortStings/anteverse_sting.anteverse_sting",
            Wave1     = { "Robot_Security", "Robot_Security", "Robot_Security", "Robot_Security", 
                          "Robot_Security", "Robot_Security", "Robot_Security", "Robot_Security", 
                          "Robot_Containment", "Robot_Containment", },
            Wave1Time = 3,
            Wave2     =  { "Robot_Defense", "Robot_Defense", },
            Wave2Time = 10,
            Wave3     =  { "Robot_Containment", "Robot_Containment", "Robot_Containment", 
                          "Robot_Corrupt", "Robot_Defense", "Robot_Defense", },
            Wave3Time = 3,
            BossWave  = { "Robot_Defense", "Robot_Corrupt" },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Blackout", 90000, 1000),
                EM.PowerLeechBossDrop(1000, { spawns= { powerLeeches=1 }}),
                EM.GatekeeperDrop(1000, { spawns = { corruptBots=1 } }),
                EM.GatekeeperDrop(60000, { spawns = { corruptBots=1 } }),
                EM.GatekeeperDrop(120000, { spawns = { corruptBots=1 } }),
                EM.GatekeeperDrop(121000, { spawns = { corruptBots=1 } })
            )
        },
    },

    -- [73-999] assault_corruptbot: (no wave npcs) | boss: Robot_Corrupt | "An abnormal presence…" | 5/5/5/10 | Reactors_S3Overgrowth_Complete
    assault_corruptbot = {
        {
            Name = "corruptbot - LATE",
            StoryMin = 70, StoryMax = 90,
            Wave1     = { "Gatekeeper_Phyter", "Gatekeeper_Phyter",  },
            Wave1Time = 10,
            Wave2     = { },
            Wave2Time = 1,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Robot_Corrupt" },
            BossWaveTime = 2,
            OnStart = EM.Sequence(
                EM.GatekeeperDrop(5000, { spawns = { corruptBots=1 }, spawnRadius=1500, minSpawnRadius=700 })
            )
        },
        {
            Name = "corruptbot - LATE xGIANT",
            StoryMin = 80, StoryMax = 100,
            StartMessage = "Massive entities are on the loose!",
            Wave1     = { "Robot_Containment", "Robot_Containment", "Robot_Containment", "Robot_Containment",  },
            Wave1Time = 3,
            Wave2     = { },
            Wave2Time = 1,
            Wave3     = { "Robot_Corrupt", },
            Wave3Time = 10,
            BossWave  = { "Robot_Corrupt", },
            BossWaveTime = 15,
            OnStart = EM.Sequence(
                EM.GiantDrop(12000, { spawns = { tarasques=2 }, spawnRadius=1500, minSpawnRadius=700 })
            )
        },
        {
            Name = "corruptbot - END SIEGE",
            StoryMin = 100, StoryMax = 999,
            StartMessage = "Corruption and fire!",
            Wave1     = { "Gatekeeper_Witch", "Gatekeeper_Witch", "Robot_Defense", "Robot_Defense", },
            Wave1Time = 5,
            Wave2     = { "Gatekeeper_Witch", "Robot_Corrupt" },
            Wave2Time = 15,
            Wave3     = { "Robot_Defense" },
            Wave3Time = 20,
            BossWave  = { "Robot_Corrupt", "Robot_Corrupt" },
            BossWaveTime = 10
        }
    },


    
    -- ========================================================
    -- SYMPHONIST centric
    -- ========================================================

    -- [20-999] assault_soldierpatrol: Grunt_Captain, Grunt_Medic, Grunt_Guard | boss: none | "A radio crackle is heard nearby…" | 2/2/2/10 | MF_MetBlacksmith
    --   * Hijacking for Symphonist
    assault_soldierpatrol = {
        {
            Name = "soldierpatrol - SYMPH EARLY",
            StoryMin = 20, StoryMax = 40,
            StartMessage   = "An unnatural fog descends... ",
            Wave1     = { "Symph", },
            Wave1Time = 20,
            Wave2     = { },
            Wave2Time = 1,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Symph" },
            BossWaveTime = 40,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Fog", 240000, 10000)
            )
        },
        {
            Name = "soldierpatrol - SYMPH EARLYMID",
            StoryMin = 35, StoryMax = 50,
            StartMessage   = "An unnatural fog descends... ",
            Wave1     = { "Symph", },
            Wave1Time = 45,
            Wave2     = { },
            Wave2Time = 1,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Symph" },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Fog", 240000, 10000),
                EM.SymphonistDrop(3000, { spawns = { symphonists=1 } })
            )
        },
        {
            Name = "soldierpatrol - SYMPH MID",
            StoryMin = 40, StoryMax = 70,
            StartMessage   = "An unnatural fog descends... ",
            Wave1     = { "Symph", "Symph", },
            Wave1Time = 10,
            Wave2     = { },
            Wave2Time = 1,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Symph" },
            BossWaveTime = 60,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Fog", 240000, 10000)
            )
        },
        {
            Name = "soldierpatrol - SYMPH LATE XFIRE",
            StoryMin = 70, StoryMax = 90,
            StartMessage   = "A commotion in the fog... ",
            Wave1     = { "Pest_Volatile", "Pest_Carbonated", "Pest_Electro", "Peccary", "Peccary", 
                          "Exor", "Exor", "Exor_Monk", "Exor_Monk", "Sow", },
            Wave1Time = 2,
            Wave2     = { "Symph", "Symph", "Symph", },
            Wave2Time = 10,
            Wave3     = { "Exor", "Exor", "Exor_Monk", "Exor_Armored", "Exor_Pikeman", "Exor_Pikeman", },
            Wave3Time = 2,
            BossWave  = { "Symph", "Symph", "Symph", },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Fog", 240000, 10000),
                EM.SymphonistDrop(90000, { spawns = { symphonists=1 } })
            )
        },
        {
            Name = "soldierpatrol - SYMPH END xORDER",
            StoryMin = 80, StoryMax = 999,
            StartMessage   = "A commotion in the fog... ",
            Wave1     = { "Grunt_Shotgun", "Grunt_Shotgun", "Grunt_Shotgun", "Grunt_Shotgun",
                          "Grunt", "Grunt", "Grunt_Guard", "Grunt_Guard", "Grunt_Guard",
                          "Grunt_Medic", "Grunt_Medic", "Grunt_Captain" },
            Wave1Time = 2,
            Wave2     = { },
            Wave2Time = 10,
            Wave3     = { "Symph", "Symph", "Symph", "Symph", "Symph", },
            Wave3Time = 2,
            BossWave  = { "Interfector", "Interfector" },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Fog", 240000, 3000),
                EM.SymphonistDrop(20000, { spawns = { symphonists=2 }, spawnRadius=2000, minSpawnRadius=1000 })
            )
        },
        {
            Name = "soldierpatrol - SYMPH END xGKs",
            StoryMin = 80, StoryMax = 999,
            StartMessage   = "A commotion in the fog... ",
            Wave1     = { "Gatekeeper_Phyter", "Gatekeeper_Phyter", "Gatekeeper_Phyter",                          
                          "Gatekeeper_Phyter", "Gatekeeper_Phyter", "Gatekeeper_Phyter", },
            Wave1Time = 2,
            Wave2     = { "Gatekeeper_Chieftain", },
            Wave2Time = 10,
            Wave3     = { "Symph", "Symph", "Symph", "Symph", "Symph", },
            Wave3Time = 2,
            BossWave  = { "Gatekeeper_Heavy", "Gatekeeper_Heavy" },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Fog", 240000, 3000),
                EM.SymphonistDrop(20000, { spawns = { symphonists=3 }, spawnRadius=2000, minSpawnRadius=1000 })
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
            StoryMin = 20, StoryMax = 40,
            Wave1     = { "Larva", "Larva_Hive", "Larva_Hive", "Larva",  },
            Wave1Time = 2,
            Wave2     = { "Larva_Big", },
            Wave2Time = 10,
            Wave3     = { "Larva", "Larva_Hive", "Larva", },
            Wave3Time = 3,
            BossWave  = { "Larva_Big", "Larva", "Larva_Big_Hive", "Larva", "Larva_Big" },
            BossWaveTime = 3,
        },
        {
            Name = "larva - MID",
            StoryMin = 50, StoryMax = 70,
            StartMessage   = "Horrors from beyond!",
            Wave1     = { "Larva", "Larva", "Larva_Hive", "Larva_Big", "Larva_Big_Hive", 
                          "Larva", "Larva", "Larva_Hive", "Larva_Big", "Larva_Big_Hive", },
            Wave1Time = 1,
            Wave2     = { "BogMan", "BogMan", "BogMan", },
            Wave2Time = 5,
            Wave3     = { "Peccary_Mushroom", "Peccary_Mushroom", "Peccary_Armored", },
            Wave3Time = 3,
            BossWave  = { "Larva_Big", "Larva", "Larva_Big_Hive", "Larva", "Larva_Big", "Pest_Leyak", "Pest_Leyak" },
            BossWaveTime = 3,
        },
        {
            Name = "larva - LATE GIANTS",
            StoryMin = 70, StoryMax = 100,
            StartMessage   = "Horrors from beyond!",
            Wave1     = { "Larva", "Larva_Hive", "Larva_Big_Hive", "Larva_Big", "Larva_Big_Hive", 
                          "Larva", "Larva_Hive", "Larva_Big_Hive", "Larva_Big", "Larva_Big_Hive", },
            Wave1Time = 1,
            Wave2     = { "BogMan", "BogMan", "BogMan", "BogMan", "BogMan",},
            Wave2Time = 3,
            Wave3     = { "Peccary_Mushroom", "Peccary_Mushroom", "Peccary_Armored", "Peccary_Armored", },
            Wave3Time = 3,
            BossWave  = { "Larva_Big", "Larva", "Larva_Big_Hive", "Larva", "Larva_Big", "Pest_Leyak", "Pest_Leyak" },
            BossWaveTime = 3,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Spores", 90000, 15000),
                EM.GiantDrop(5000, { spawns = { tarasques=1 }, spawnRadius=2500, minSpawnRadius=1500 })
            )
        },
        {
            Name = "larva - LATE GIANTS",
            StoryMin = 100, StoryMax = 999,
            StartMessage   = "Horrors from beyond!",
            Wave1     = { "Larva", "Larva_Hive", "Larva_Big_Hive", "Larva_Big", "Larva_Big_Hive", 
                          "Larva", "Larva_Hive", "Larva_Big_Hive", "Larva_Big", "Larva_Big_Hive", },
            Wave1Time = 1,
            Wave2     = { "BogMan", "BogMan", "BogMan", "BogMan", "BogMan",},
            Wave2Time = 3,
            Wave3     = { "Peccary_Mushroom", "Peccary_Mushroom", "Peccary_Armored", "Peccary_Armored", },
            Wave3Time = 3,
            BossWave  = { "Larva_Big", "Larva", "Larva_Big_Hive", "Larva", "Larva_Big", "Pest_Leyak", "Pest_Leyak" },
            BossWaveTime = 3,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Spores", 90000, 15000),
                EM.GiantDrop(15000, { spawns = { yetis=1 }, spawnRadius=2500, minSpawnRadius=1500 }),
                EM.GiantDrop(40000, { spawns = { bigfoots=1 }, spawnRadius=2500, minSpawnRadius=1500 })
            )
        }
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
            Wave1Time = 2,
            Wave2     = { },
            Wave2Time = 10,
            Wave3     = { "Zombie", "Zombie", "Zombie", "Zombie", "Zombie_Sci", "Zombie", "Zombie", "Zombie", "Zombie", "Zombie_Sci", "Zombie_Dam", "Zombie_Dam", "Zombie_Dam", "Zombie_Dam", "Zombie_Dam", },
            Wave3Time = 2,
            BossWave  = { },
            BossWaveTime = 2,
        },
        {
            Name = "zombiehorde - LATE",
            StoryMin = 70, StoryMax = 90,
            Wave1     = { "Zombie_Sci", "Zombie_Sci", "Zombie", "Zombie_Sci", "Zombie_Sci", "Zombie", "Zombie_Sci", "Zombie_Sci", "Zombie", "Zombie_Sci",  },
            Wave1Time = 2,
            Wave2     = { },
            Wave2Time = 10,
            Wave3     = { "Zombie", "Zombie", "Zombie", "Zombie", "Zombie_Sci", "Zombie", "Zombie", "Zombie", "Zombie", "Zombie_Sci", "Zombie", "Zombie", "Zombie", "Zombie", "Zombie_Sci", },
            Wave3Time = 2,
            BossWave  = { },
            BossWaveTime = 2,
            --OnStart = EM.PowerFailure()
        },
        {
            Name = "zombiehorde - MID REAPER",
            StoryMin = 60, StoryMax = 90,
            StartMessage = "Don't fear the reaper...",
            Wave1     = { "Reaper", },
            Wave1Time = 15,
            Wave2     = { },
            Wave2Time = 1,
            Wave3     = { "Reaper", },
            Wave3Time = 10,
            BossWave  = { "Zombie", "Zombie_Sci", "Zombie", "Zombie_Sci", "Zombie",
                          "Zombie", "Zombie", "Zombie_Sci", "Zombie", "Zombie",
                          "Zombie", "Zombie_Sci", "Zombie", "Zombie_Sci", "Zombie", },
            BossWaveTime = 2,
            OnStart = EM.AssaultWeather("BlackFog", 60000, 15000),
        },
        {
            Name = "zombiehorde - END REAPER",
            StoryMin = 90, StoryMax = 999,
            StartMessage = "Don't fear the reaper...",
            Wave1     = { "Gatekeeper_Witch", "Gatekeeper_Witch", },
            Wave1Time = 5,
            Wave2     = { "Gatekeeper_Witch", },
            Wave2Time = 20,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Reaper", "Reaper", },
            BossWaveTime = 20,
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
            StoryMin = 40, StoryMax = 60,
            Wave1     = { "Pillager_Farmer", "Pillager_Musketeer", "Pillager_Torchbearer", "Pillager_Woodsman", },
            Wave1Time = 2,
            Wave2     = { "Pillager_Musketeer_GUARD", "Pillager_Musketeer_GUARD", },
            Wave2Time = 5,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Pillager_Farmer", "Pillager_Musketeer", "Pillager_Preacher", "Pillager_Woodsman",
                          "Pillager_Farmer", "Pillager_Musketeer", "Pillager_Preacher", "Pillager_Woodsman", },
            BossWaveTime = 2,
        },
        {
            Name = "salemmob - MIDLATE",
            StoryMin = 60, StoryMax = 80,
            StartMessage = "A lode of trouble...",
            Wave1     = { "Pillager_Farmer", "Pillager_Musketeer", "Pillager_Preacher", "Pillager_Woodsman",
                          "Pillager_Farmer", "Pillager_Musketeer", "Pillager_Preacher", "Pillager_Woodsman", },
            Wave1Time = 2,
            Wave2     = { "Pillager_Musketeer_GUARD", "Pillager_Musketeer_GUARD", },
            Wave2Time = 5,
            Wave3     = { "Pillager_Torchbearer", "Pillager_Torchbearer", "Pillager_Torchbearer", "Pillager_Torchbearer", "Pillager_Torchbearer", },
            Wave3Time = 1,
            BossWave  = { "Pillager_Preacher", "Pillager_Preacher", "Pillager_Preacher", "Pillager_Musketeer",
                          "Pillager_Preacher", "Pillager_Preacher", "Pillager_Preacher", "Pillager_Musketeer", },
            BossWaveTime = 2,
        },
        {
            Name = "salemmob - END xGKs",
            StoryMin = 80, StoryMax = 999,
            StartMessage = "A witch hunt!",
            Wave1     = { "Gatekeeper_Witch", "Gatekeeper_Witch", "Gatekeeper_Witch", },
            Wave1Time = 2,
            Wave2     = { "Gatekeeper_Witch", },
            Wave2Time = 20,
            Wave3     = { "Pillager_Farmer", "Pillager_Musketeer", "Pillager_Torchbearer", "Pillager_Woodsman", "Pillager_Preacher",
                          "Pillager_Farmer", "Pillager_Musketeer", "Pillager_Torchbearer", "Pillager_Woodsman", "Pillager_Preacher",
                          "Pillager_Farmer", "Pillager_Musketeer", "Pillager_Torchbearer", "Pillager_Woodsman", "Pillager_Preacher", },
            Wave3Time = 2,
            BossWave  = { "Pillager_Preacher", "Pillager_Preacher", "Gatekeeper_Witch", },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.AssaultWeather("BlackFog", 63000, 17000)
            )
        }
    },


    -- ========================================================
    -- Crystallisks
    -- ========================================================
    
    -- [20-999] assault_soloassassin: Assassin | boss: none | (no message) | 8/6/4/10 | MF_MetSoldier
    assault_soloassassin = {
        {
            Name = "assassin - EARLY",
            StoryMin = 20, StoryMax = 40,
            WarningMessage   = "A stillness fills the air.",
            StartMessage = "A crystalline assault!",
            Wave1     = { "Assassin", "Assassin", },
            Wave1Time = 2,
            Wave2     = { "Assassin", },
            Wave2Time = 15,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Assassin", "Assassin", "Assassin",},
            BossWaveTime = 5,
        },
        {
            Name = "assassin - MID",
            StoryMin = 40, StoryMax = 60,
            WarningMessage = "A stillness fills the air.",
            StartMessage = "A crystalline assault!",
            Wave1     = { "Assassin", "Assassin", "Assassin",},
            Wave1Time = 2,
            Wave2     = { "Assassin", "Assassin", "Assassin",},
            Wave2Time = 5,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Assassin", "Assassin", "Assassin", "Assassin", "Assassin",},
            BossWaveTime = 5
        },
        {
            Name = "assassin - MIDLATE",
            StoryMin = 60, StoryMax = 80,
            WarningMessage = "A stillness fills the air.",
            StartMessage = "A crystalline assault!",
            Wave1     = { "Assassin", "Assassin", "Assassin", "Assassin", "Assassin", "Assassin",},
            Wave1Time = 2,
            Wave2     = { "Assassin", "Assassin", "Assassin",},
            Wave2Time = 5,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Assassin", "Assassin", "Assassin", "Assassin", "Assassin",
                          "Assassin", "Assassin", "Assassin", "Assassin", "Assassin",},
            BossWaveTime = 2
        },
        {
            Name = "assassin - MIDLATE",
            StoryMin = 80, StoryMax = 90,
            WarningMessage = "A stillness fills the air.",
            StartMessage = "The lights flicker ominously...",
            Wave1     = { "Assassin", "Assassin", "Assassin", "Assassin", },
            Wave1Time = 2,
            Wave2     = { "Assassin", },
            Wave2Time = 20,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Assassin", "Assassin", "Assassin", "Assassin",
                          "Assassin", "Assassin", "Assassin", "Assassin",},
            BossWaveTime = 2,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Blackout", 60000, 15000),
                EM.PowerLeechBossDrop(1000, { powerLeeches=1 })
            )
        },
        {
            Name = "assassin - END",
            StoryMin = 90, StoryMax = 999,
            WarningMessage   = "A stillness fills the air...",
            StartMessage = "An unseen war rages!",
            Wave1     = { "Assassin", "Assassin", "Assassin", "Assassin", "Assassin",
                          "Assassin", "Assassin", "Assassin", "Assassin", "Assassin",
                          "Assassin", "Assassin", "Assassin", "Assassin", "Assassin",  },
            Wave1Time = 1,
            Wave2     = { "Assassin" },
            Wave2Time = 7,
            Wave3     = {  "Interfector", "Interfector", "Interfector", "Interfector", "Interfector",
                           "Interfector", "Interfector", "Interfector",  },
            Wave3Time = 2,
            BossWave  = { "Reaper", },
            BossWaveTime = 15,
            OnStart = EM.Sequence(
                EM.AssaultWeather("BlackFog", 20000, 21000),
                EM.PowerLeechBossDrop(5000, { powerLeeches=1 })
            ),
        }
    },

   
    -- ========================================================
    -- Lamogi
    -- ========================================================
    
    -- [50-999] assault_lamogifrenzy: WinterSpritex3 | boss: WinterSprite_Bomb | "The bytes are all wrong." | 8/6/4/10 | VWinter_Complete
    --   * Also does Snowman and some winter enemies
    assault_lamogifrenzy = {
        {
            Name = "lamogifrenzy - MID",
            StoryMin = 50, StoryMax = 70,
            Wave1     = { "WinterSprite", "WinterSprite", "WinterSprite", "WinterSprite", "WinterSprite", "WinterSprite_Bomb", },
            Wave1Time = 1,
            Wave2     = { "WinterSprite", },
            Wave2Time = 15,
            Wave3     = { "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb",  },
            Wave3Time = 1,
            BossWave  = { "WinterSprite", "WinterSprite_BOSS", },
            BossWaveTime = 5,
        },
        {
            Name = "lamogifrenzy - LATE",
            StoryMin = 70, StoryMax = 90,
            Wave1     = { "WinterSprite_BOSS", "WinterSprite_BOSS", "WinterSprite_BOSS", 
                          "WinterSprite", "WinterSprite", "WinterSprite", "WinterSprite", "WinterSprite", },
            Wave1Time = 2,
            Wave2     = { },
            Wave2Time = 1,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb", 
                          "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb", 
                          "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb",   },
            BossWaveTime = 4
        },
        {
            Name = "lamogifrenzy - END",
            StoryMin = 90, StoryMax = 999,
            WarningMessage = "A cold front from the north...",
            StartMessage = "Snowmageddon!",
            Wave1     = { "Pest_Snow", "Pest_Snow", "Pest_Snow", "Pest_Snow", "Peccary_Snow",
                          "Pest_Snow", "Pest_Snow", "Pest_Snow", "Peccary_Snow", "Pest_Snow",
                          "Pest_Snow", "Peccary_Snow", "Peccary_Snow", "Peccary_Snow", },
            Wave1Time = 2,
            Wave2     = { "Peccary_Snow", },
            Wave2Time = 10,
            Wave3     = { "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb",
                          "WinterSprite", "WinterSprite", "WinterSprite", },
            Wave3Time = 2,
            BossWave  = { "Groupe_Shotgun", "Groupe_Shotgun", "Groupe_Grunt", "Groupe_Grunt", },
            BossWaveTime = 5,
            OnStart =  EM.Sequence(
                EM.AssaultWeather("ColdSnap", 75000, 10000),
                EM.GiantDrop(5000, { spawns = { snowmen=1 } }),
                EM.GiantDrop(45000, { spawns = { yetis=1 } })
            )
        }
    },
   

    -- ========================================================
    -- Chaos assault.
    -- !TODO: Put some wild assaults in here
    -- ========================================================

    -- [70-999] assault_zombiewave: Zombiex10 | boss: none | (no message) | 2/2/2/10 | LABS_ActivateWarehouseLift
    -- * Multifaction messes of an assault
    assault_zombiewave = {

        
        {
            Name = "zombiewave - SUPER CHAOS",
            StoryMin = 102, StoryMax = 999,
            StartMessage     = "Full containment breach!",
            Wave1     = { "Robot_Security", "Robot_Security", "Robot_Containment", 
                          "Robot_Containment", "Robot_Containment", "Robot_Containment", 
                          "Robot_Containment", },
            Wave1Time = 5,
            Wave2     = { "Gatekeeper_Phyter", "Gatekeeper_Phyter", "Gatekeeper_Witch", "Gatekeeper_Heavy" },
            Wave2Time = 25,
            Wave3     = { "Grunt_Guard", "Grunt_Guard", "Grunt", 
                          "Grunt_Shotgun", "Grunt_Shotgun", "Groupe_Rook", 
                          "Grunt_Medic", "Groupe_Grunt", "Groupe_Grunt", 
                          "Grunt_Captain", "Trooper_Shotgun", "Trooper_Shotgun", 
                          "Trooper_Shotgun", "Trooper_Shield", "Trooper", 
                          "Trooper", "Trooper", "Trooper", "Trooper", },
            Wave3Time = 1,
            BossWave  = { "Robot_Defense", "Robot_Corrupt" },
            BossWaveTime = 30,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Blackout", 50000, 15000),
                EM.AssaultWeather("Fog", 60000, 70000),
                EM.AssaultWeather("Spores", 180000, 120000),

                -- Spawn throughout the encounter

                EM.PestDrop(5000, { spawns={ pests=4, electros=5 }, spawnInterval=10000, spawnRadius=2000, minSpawnRadius=1000 }),
                EM.PestDrop(6000, { spawns={ winters=5 }, spawnInterval=12000, spawnRadius=2000, minSpawnRadius=1000 }),
                EM.PestDrop(7000, { spawns={ electros=2, volatiles=4 }, spawnInterval=9000, spawnRadius=2000, minSpawnRadius=1000 }),
                EM.PestDrop(8000, { spawns={ carbonateds=2, rats=2, magmas=2, leyaks=1, enlighteneds=1 }, spawnInterval=14000, spawnRadius=2000, minSpawnRadius=1000 }),
                
                EM.PeccaryDrop(10000, { spawns={ peccaries=3, sows=3 }, spawnInterval=12000, spawnRadius=2000, minSpawnRadius=1000 }),
                EM.PeccaryDrop(11000, { spawns={ mushrooms=2, alphas=1, winters=2 }, spawnInterval=15000, spawnRadius=2000, minSpawnRadius=1000 }),
                EM.PeccaryDrop(12000, { spawns={ electros=3, armored=2, volatiles=1 }, spawnInterval=16000, spawnRadius=2000, minSpawnRadius=1000 }),
                
                EM.ExorDrop(20000, { spawns={ monks=4, exors=1, armoreds=1 }, spawnInterval=20000, spawnRadius=2000, minSpawnRadius=1000 }),
                EM.ExorDrop(33000, { spawns={ monks=2, pikemen=2 }, spawnInterval=22000, spawnRadius=2000, minSpawnRadius=1000 }),
                EM.ExorDrop(34000, { spawns={ exors=2, volatiles=2 }, spawnInterval=30000, spawnRadius=2000, minSpawnRadius=1000 }),

                EM.OrderDrop(13000, { spawns={ guards=8, grunts=4 }, spawnInterval=8000, spawnRadius=2000, minSpawnRadius=1000 }),
                EM.OrderDrop(14000, { spawns={ medics=6 }, spawnInterval=14000, spawnRadius=2000, minSpawnRadius=1000 }),
                EM.OrderDrop(15000, { spawns={ captains=5 }, spawnInterval=20000, spawnRadius=2000, minSpawnRadius=1000 }),
                EM.OrderDrop(16000, { spawns={ breachers=5 }, spawnInterval=20000, spawnRadius=2000, minSpawnRadius=1000 }),
                EM.OrderDrop(17000, { spawns={ interfectors=3 }, spawnInterval=30000, spawnRadius=2000, minSpawnRadius=1000 }),
                EM.CrystalliskDrop(18000, { spawns= { crystallisks=6 }, spawnInterval=16000, spawnRadius=2000, minSpawnRadius=1000 }),
                EM.RatDrop(23000, { spawns={ labRats=4, garageRats=2 }, spawnInterval=22000, spawnRadius=2000, minSpawnRadius=1000 }),
                EM.RatDrop(31000, { spawns={ garageRats=3, sappers=2, flameRats=1 }, spawnInterval=20000, spawnRadius=2000, minSpawnRadius=1000 }),
                EM.SkinkDrop(24000, { spawns= { skinks=3, magmaskinks=3 }, spawnInterval=5000, spawnRadius=2000, minSpawnRadius=1000 }),
                EM.SymphonistDrop(51000, { spawns= { symphonists=2 }, spawnInterval=9000, spawnRadius=2000, minSpawnRadius=1000 }),

                -- Burst drops
                EM.GatekeeperDrop(30000, { spawns={ phyters=2 }, spawnInterval=6000, spawnRadius=3000, minSpawnRadius=1000 }),
                EM.GatekeeperDrop(50000, { spawns={ phyters=1, heavies=1, }, spawnInterval=6000, spawnRadius=2000, minSpawnRadius=1000 }),
                EM.GatekeeperDrop(70000, { spawns={ witches=1, mages=1, }, spawnInterval=6000, spawnRadius=2000, minSpawnRadius=1000 }),
                EM.GatekeeperDrop(95000, { spawns={ chieftains=1, witches=1 }, spawnInterval=2000, spawnRadius=1000 }),
                EM.GatekeeperDrop(110000, { spawns={ phyters=1, heavies=1, mages=1 }, spawnInterval=2000, spawnRadius=1000 }),

                EM.GiantDrop(13000, { spawns={ tarasques=1, }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.GiantDrop(43000, { spawns={ yetis=1 }, spawnInterval=10000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.GiantDrop(70000, { spawns={ bigfoots=1 }, spawnInterval=5000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.GiantDrop(150000, { spawns={ snowmen=1 }, spawnInterval=5000, spawnRadius=3000, minSpawnRadius=1500 })

            )
        },
        
        -- This assault is just for testing
        {
            Name = "zombiewave - CHAOS END",
            StoryMin = 999, StoryMax = 999,
            StartMessage     = "Hello, world!",
            Wave1     = { },
            Wave1Time = 2,
            Wave2     = { },
            Wave2Time = 10,
            Wave3     = { },
            Wave3Time = 2,
            BossWave  = { "DarkLens_Heavy" },
            BossWaveTime = 60,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Blackout", 5000, 50000)
            )
        },
    },
   
    -- Maybe split chaotic assaults here for a higher chance
    -- assault_pestfrenzy_volatile: Pest_Volatilex7 | boss: Exor_Volatile | "A frenzy!" | 4/4/4/10 | Reactors_S3Overgrowth_Complete
    assault_pestfrenzy_volatile = { },
}

return ASSAULTS