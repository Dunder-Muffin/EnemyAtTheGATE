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
            Wave2Time = 3,
            Wave3     = { "Pest", "Pest" },
            Wave3Time = 5,
            BossWave  = { "Pest", "Peccary" },
            BossWaveTime = 10,
        },
        {
            Name = "peststorm - CARBONATED STORM",
            StartMessage   = "A portal storm has started! With.. hiccups?",
            StoryMin = 20, StoryMax = 32,
            Wave1     = { "Pest_Carbonated", "Pest", "Pest", "Pest_Carbonated", "Pest", "Pest", "Pest_Carbonated" },
            Wave1Time = 1,
            Wave2     = { "Pest_Carbonated", "Pest_Carbonated", "Pest_Carbonated", "Pest_Carbonated", "Pest_Carbonated" },
            Wave2Time = 5,
            Wave3     = { "Pest_Carbonated", "Pest_Carbonated" },
            Wave3Time = 10,
            BossWave  = { "Exor_Monk", "Peccary", "Pest_Carbonated" },
            BossWaveTime = 1,
        },
    },

    -- [0-32] assault_peccaryboss: Pestx5 | boss: Peccary | "A portal storm has started!" | 2/2/2/10 | (none)
    assault_peccaryboss = {
        {
            Name = "peccaryboss - EARLY",
            StoryMin = 0, StoryMax = 20,
            Wave1     = { "Peccary", "Peccary" },
            Wave1Time = 1,
            Wave2     = { "Pest", "Pest", "Peccary", "Pest", "Pest", },
            Wave2Time = 5,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Peccary", "Peccary" },
            BossWaveTime = 5,
        },
        {
            Name = "peccaryboss - EXOR",
            StoryMin = 20, StoryMax = 32,
            Wave1     = { "Pest", "Pest", "Peccary", "Pest", "Pest", "Peccary", },
            Wave1Time = 1,
            Wave2     = { "Peccary", "Pest_Carbonated", "Peccary", "Pest_Carbonated", "Peccary", },
            Wave2Time = 5,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Exor_Monk", "Exor_Monk" },
            BossWaveTime = 5,
        },
    },

    -- [0-32] assault_peststorm_electro:   Pest_Electrox4 | boss: Sow | "A portal storm has started!" | 8/6/4/10 | LABS_ExploredLabs
    assault_peststorm_electro = {
        Name = "peststorm_electro - EARLY",
        StartMessage   = "A thunderous portal storm has started!",
        StoryMin = 30, StoryMax = 35,
        Wave1     = { "Pest_Electro", "Pest_Electro", "Pest_Electro", "Pest_Electro", "Pest_Electro" },
        Wave1Time = 1,
        Wave2     = { "Sow", "Pest_Electro", "Sow", "Pest_Electro" },
        Wave2Time = 3,
        Wave3     = { "Pest_Electro", "Sow" },
        Wave3Time = 15,
        BossWave  = { "Pest_Electro", "Peccary_Electro", "Peccary_Electro" },
        BossWaveTime = 1,
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
            Wave1     = { "Pest_Electro", "Pest_Electro", "Pest_Electro", "Peccary_Electro", 
                          "Pest_Electro", "Pest_Electro", "Pest_Electro", "Peccary_Electro", 
                          "Pest_Electro", "Pest_Electro", },
            Wave1Time = 2,
            Wave2     = { "Pest_Electro", "Peccary_Electro",  },
            Wave2Time = 15,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Exor_Monk", "Exor_Monk" },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.PestDrop(5000, { spawns = { electros=2 }, spawnRadius=2000, minSpawnRadius = 500 }),
                EM.PeccaryDrop(6000, { spawns = { electros=1 }, spawnRadius=2000, minSpawnRadius = 500 } ),
                EM.PestDrop(20000, { spawns = { electros=3 }, spawnRadius=2000, minSpawnRadius = 500 }),
                EM.PeccaryDrop(21000, { spawns = { electros=1 }, spawnRadius=2000, minSpawnRadius = 500 }),
                EM.ExorDrop(35000, { spawns = { monks=1 }, spawnRadius=3000, minSpawnRadius=1500 })
            )
        },
        {
            Name = "pestfrenzy_electro - LATE ELECTRO",
            StoryMin = 60, StoryMax = 80,
            StartMessage = "A pest Tempest!",
            Wave1     = { "Exor_Monk", "Pest_Electro", "Pest_Electro", "Pest_Electro", "Peccary_Electro", 
                          "Exor_Monk", "Pest_Electro", "Pest_Electro", "Pest_Electro", "Peccary_Electro", 
                          "Exor_Monk", "Pest_Electro", "Pest_Electro", "Pest_Electro", "Peccary_Electro",  },
            Wave1Time = 2,
            Wave2     = { "Peccary_Electro", "Peccary_Electro", "Peccary_Electro", },
            Wave2Time = 10,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Exor_Monk", "Exor_Monk", "Exor_Monk", "Exor_Monk" },
            BossWaveTime = 2,
            OnStart = EM.Sequence(
                EM.PestDrop(5000, { spawns = { electros=4 }, spawnRadius=2000, minSpawnRadius = 500 }),
                EM.PeccaryDrop(6000, { spawns = { electros=1 }, spawnRadius=2000, minSpawnRadius = 500 } ),

                EM.PestDrop(25000, { spawns = { electros=4 }, spawnRadius=1500, minSpawnRadius = 300}),
                EM.PeccaryDrop(26000, { spawns = { electros=1 }, spawnRadius=2000, minSpawnRadius = 500 } ),
                EM.ExorDrop(27000, { spawns = { monks=1 }, spawnRadius=3000, minSpawnRadius=1500 } ),
                
                EM.PestDrop(35000, { spawns = { electros=4 }, spawnRadius=1500, minSpawnRadius = 300}),
                EM.PeccaryDrop(40000, { spawns = { electros=2 }, spawnRadius=2000, minSpawnRadius = 500 } )
            )
        },
        {
            Name = "pestfrenzy_electro - LATE VOLATILE",
            StoryMin = 80, StoryMax = 100,
            StartMessage = "A Pestilence!",
            Wave1     = { "Exor_Volatile", "Exor_Volatile",  },
            Wave1Time = 15,
            Wave2     = { "Pest_Volatile", "Pest_Volatile", "Pest_Volatile", "Pest_Volatile", 
                          "Pest_Volatile", "Pest_Volatile", "Pest_Volatile", "Pest_Volatile", 
                          "Peccary_Volatile", "Peccary_Volatile", "Peccary_Volatile", },
            Wave2Time = 1,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Pest_Volatile", "Peccary_Volatile", "Peccary_Volatile", "Exor_Volatile", "Exor_Volatile"  },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.Sequence(EM.AssaultWeather("RadLeak", 240000, 15000)),
                EM.PestDrop(3000, { spawns = { volatiles=6 }, spawnRadius=2000, minSpawnRadius = 500}),
                EM.ExorDrop(12000, { spawns = { exors=2 }, spawnRadius=2000, minSpawnRadius=1000 } ),

                EM.PestDrop(30000, { spawns = { volatiles=4 }, spawnRadius=1500, minSpawnRadius = 300}),
                EM.ExorDrop(40000, { spawns = { volatiles=1 }, spawnRadius=3000, minSpawnRadius=1500 } ),
                EM.PestDrop(50000, { spawns = { volatiles=4 }, spawnRadius=1000, minSpawnRadius = 300}),
                EM.ExorDrop(65000, { spawns = { volatiles=2 }, spawnRadius=3000, minSpawnRadius=1500 } )
            )
        },
        {
            Name = "pestfrenzy_electro - LATE MAGMA",
            StoryMin = 80, StoryMax = 100,
            WarningMessage = "You feel a slight temperature change...",
            StartMessage   = "Thermal hypesthesia! Its hotter than you feel!",
            Wave1     = { "Pest_Magma", "Pest_Magma", "Peccary_Volatile", "Pest_Magma", "Pest_Magma", 
                          "Pest_Magma", "Pest_Magma", "Peccary_Volatile", "Pest_Magma", "Pest_Magma",  },
            Wave1Time = 1,
            Wave2     = { "Pest_Magma", "Pest_Magma", "Peccary_Volatile", "Pest_Magma", "Pest_Magma", },
            Wave2Time = 10,
            Wave3     = { "Exor_Volatile", "Pest_Magma", "Exor_Volatile", "Pest_Magma", "Exor_Volatile", },
            Wave3Time = 2,
            BossWave  = { "Exor_Volatile", "Pest_Magma", "Pest_Magma", "Pest_Volatile", "Pest_Volatile",  },
            BossWaveTime = 5,
            OnStart = EM.Sequence(
                -- Spawn some Magma Skinks with Exor faction
                EM.AssaultWeather("Spores", 180000, 20000),

                -- Spawn through the encounter
                EM.PestDrop(3000, { spawns = { magmas=12 }, spawnInterval=3000 }),
                EM.PestDrop(4000, { spawns = { volatiles=3 }, spawnInterval=12000 }),
                EM.SkinkDrop(5000, { spawns = { magmaskinks=4 }, faction=5, spawnRadius=10000 }),

                EM.PeccaryDrop(10000, { spawns = { volatiles=1 } }),
                EM.ExorDrop(20000, { spawns = { volatiles=1 }, spawnRadius=3000, minSpawnRadius=1500 } ),
                EM.PeccaryDrop(35000, { spawns = { volatiles=1 } }),
                EM.ExorDrop(36000, { spawns = { volatiles=1 }, spawnRadius=3000, minSpawnRadius=1500 } ),
                EM.SkinkDrop(40000, { spawns = { magmaskinks=4 }, faction=5, spawnRadius=7000 })
            )
        },
        {
            Name = "pestfrenzy_electro - END",
            StoryMin = 90, StoryMax = 100,
            WarnMessage    = "The portal suppressor is going haywire...",
            StartMessage   = "An inpestation!",
            Wave1     = { "Pest", "Pest", "Pest_Carbonated", "Pest_Rat", "Pest_Electro",
                          "Pest_Volatile", "Pest_Magma", "Pest", "Pest_Magma", "Pest_Electro",
                          "Pest_Electro", "Pest_Carbonated", "Pest_Magma", "Pest_Carbonated", "Pest_Rat",
                          "Sow", "Peccary_Mushroom", "Peccary", "Peccary", "Peccary_Electro", "Sow",
                          "Exor_Monk", "Exor" },
            Wave1Time = 1,
            Wave2     = { "Exor_Monk", "Exor", "Peccary_Volatile", "Peccary_Armored", "Exor_Armored", "Exor", "Exor_Pikeman" },
            Wave2Time = 5,
            Wave3     =  { "Pest_Enlightened", "Exor_Pikeman", "Pest_Enlightened",
                           "Pest_Enlightened", "Exor_Pikeman", "Pest_Enlightened", },
            Wave3Time = 3,
            BossWave  = { "Pest_Leyak", },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Spores", 240000, 25000),

                -- Spawn through the encounter
                EM.SkinkDrop(2000, { spawns = { skinks=6 }, spawnInterval=6000 }),
                EM.SkinkDrop(2000, { spawns = { magmaskinks=2 }, spawnInterval=8000 }),           

                EM.PestDrop(5000, { spawns = { pests=2, electros=2, carbonateds=2}, spawnInterval=100 }),
                EM.ExorDrop(7000, { spawns = { exors=1 }, spawnRadius=3000, minSpawnRadius=1500 }),

                EM.PestDrop(15000, { spawns = { pests=5, rats=3, volatiles=2}, spawnInterval=100, spawnRadius=1500 }),   
                EM.ExorDrop(17000, { spawns = { monks=1, exors=1 }, spawnRadius=3000, minSpawnRadius=1500 }),
                
                EM.PestDrop(25000, { spawns = { carbonateds=2, electros=1, magmas=3}, spawnInterval=100 }),
                EM.ExorDrop(27000, { spawns = { pikemen=1, exors=1, monks=1 }, spawnRadius=3000, minSpawnRadius=1500 }),

                EM.PestDrop(35000, { spawns = { volatiles=2, magmas=2}, spawnInterval=100 }),
                EM.PestDrop(45000, { spawns = { leyaks=3, enlighteneds=1 }, spawnInterval=100 })
            )
        },
        {
            Name = "pestfrenzy_electro - POSTEND",
            StoryMin = 102, StoryMax = 999,
            WarnMessage    = "The portal suppressor is going haywire...",
            StartMessage   = "An inpestation!",
            Wave1     = { "Pest", "Pest", "Pest_Carbonated", "Pest_Rat", "Pest_Electro",
                          "Pest_Volatile", "Pest_Magma", "Pest_Enlightened", "Pest_Magma", "Pest_Electro",
                          "Pest_Electro", "Pest_Carbonated", "Pest_Magma", "Pest_Carbonated", "Pest_Rat",
                          "Sow", "Peccary_Mushroom", "Peccary_Armored", "Peccary_Volatile", "Peccary_Electro", "Sow",
                          "Exor_Monk", "Exor_Armored" },
            Wave1Time = 1,
            Wave2     = { "Exor_Monk", "Exor", "Peccary_Volatile", "Peccary_Armored", "Exor_Armored", "Exor", "Exor_Pikeman" },
            Wave2Time = 5,
            Wave3     =  { "Pest_Enlightened", "Pest_Enlightened", "Exor_Pikeman", "Pest_Enlightened", "Pest_Enlightened",
                           "Pest_Enlightened", "Pest_Enlightened", "Exor_Pikeman", "Pest_Enlightened", "Pest_Enlightened", },
            Wave3Time = 2,
            BossWave  = { "Pest_Leyak", "Pest_Leyak", "Pest_Leyak", },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Spores", 240000, 25000),
                
                -- Spawn through the encounter
                EM.SkinkDrop(2000, { spawns = { skinks=10 }, spawnInterval=5000 }),
                EM.PestDrop(2000, { spawns = { enlighteneds=6 }, spawnInterval=9000 , spawnRadius=2000, minSpawnRadius = 1000 }),    
                EM.SkinkDrop(2000, { spawns = { magmaskinks=5 }, spawnInterval=7000 }),           

                EM.PestDrop(5000, { spawns = { pests=3, electros=3, carbonateds=3}, spawnInterval=100 }),
                EM.ExorDrop(7000, { spawns = { monks=2, exors=2 }, spawnRadius=3000, minSpawnRadius=1500 }),

                EM.PestDrop(15000, { spawns = { pests=5, rats=3, volatiles=5}, spawnInterval=100, spawnRadius=1500 }),   
                EM.ExorDrop(17000, { spawns = { armoreds=2, exors=2 }, spawnRadius=3000, minSpawnRadius=1500 }),
                
                EM.PestDrop(25000, { spawns = { carbonateds=3, electros=3, leyaks=3, magmas=5}, spawnInterval=100 }),
                EM.ExorDrop(27000, { spawns = { pikemen=2, monks=3 }, spawnRadius=3000, minSpawnRadius=1500 }),

                EM.PestDrop(35000, { spawns = { volatiles=4, magmas=4}, spawnInterval=100 }),
                EM.PestDrop(45000, { spawns = { leyaks=5, enlighteneds=3 }, spawnInterval=100 })
            )
        },
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
            StoryMin = 25, StoryMax = 35,
            StartMessage   = "Travelers from a Far Garden...",
            Wave1     = { "Pest", "Pest", "Pest_Carbonated", "Pest", "Pest", "Pest_Carbonated", },
            Wave1Time = 3,
            Wave2     = { "Peccary", "Peccary", },
            Wave2Time = 1,
            Wave3     = { "Exor_Monk", },
            Wave3Time = 15,
            BossWave  = { "Exor_Monk", "Exor_Monk", },
            BossWaveTime = 1,
            OnStart = EM.Sequence(
                EM.ExorDrop(3000, { spawns = { monks=1 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.PeccaryDrop(5000, { spawns = { peccaries=2 }})
            )
        },
        {
            Name = "monkdad - MID",
            StoryMin = 35, StoryMax = 50,
            StartMessage   = "Strange frequencies fill the air...",
            Wave1     = { "Pest", "Pest", "Pest_Carbonated", "Pest", "Pest", "Pest_Carbonated", },
            Wave1Time = 2,
            Wave2     = { "Peccary", "Peccary", },
            Wave2Time = 2,
            Wave3     = { "Exor", "Exor", "Exor", },
            Wave3Time = 2,
            BossWave  = { "Exor_Monk" },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.AssaultWeather("RadLeak", 30000, 25000),
                EM.ExorDrop(10000, { spawns = { monks=1 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.ExorDrop(20000, { spawns = { monks=1 }, spawnRadius=3000, minSpawnRadius=1500 })
            )
        },
        {
            Name = "monkdad - MID xORDER",
            StoryMin = 50, StoryMax = 70,
            StartMessage   = "The smell of smoke and ozone...",
            Wave1     = { "Pest_Electro", "Pest_Electro", "Pest_Electro", "Pest_Electro", "Pest_Electro", 
                          "Pest_Electro", "Peccary_Electro", "Peccary_Electro", "Pest_Electro" },
            Wave1Time = 1,
            Wave2     = { "Exor", "Peccary_Electro", "Exor", "Exor_Monk", "Peccary_Electro", 
                          "Exor", "Exor_Monk", "Exor", },
            Wave2Time = 2,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Grunt_Shotgun", "Grunt", "Grunt_Captain", "Grunt_Shotgun", "Grunt", },
            BossWaveTime = 2,
            OnStart = EM.Sequence(
                EM.AssaultWeather("RadLeak", 60000, 25000),
                
                -- Spawn through the encounter
                EM.OrderDrop(20000, { spawns = { guards=6 }, spawnInterval=4000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.PeccaryDrop(21000, { spawns = { peccaries=4 }, spawnInterval=6000 }),

                EM.PestDrop(15000, { spawns = { electros=6 }}),
                EM.OrderDrop(17000, { spawns = { guards=2, grunts=2, medics=1, captains=1  }, spawnRadius=3000, minSpawnRadius=1500 }),

                EM.OrderDrop(25000, { spawns = { breachers=3 }, spawnInterval=3000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.ExorDrop(27000, { spawns = { monks=2 }, spawnInterval=3000, spawnRadius=3000, minSpawnRadius=1500 })
            )
        },
        {
            Name = "monkdad - LATE xORDER",
            StoryMin = 72, StoryMax = 90,
            StartMessage   = "The smell of smoke and ozone...",
            Wave1     = { "Pest_Electro", "Pest_Electro", "Pest_Electro", "Pest_Electro", 
                          "Peccary_Electro", "Peccary_Electro",
                          "Exor_Monk", "Exor_Monk", "Exor_Monk", "Exor_Armored"   },
            Wave1Time = 1,
            Wave2     = { "Peccary_Electro", "Peccary_Electro", "Peccary_Electro", 
                          "Exor_Armored", "Exor_Monk", "Exor_Monk", "Exor_Monk", 
                          "Exor", "Exor_Monk", "Exor", },
            Wave2Time = 2,
            Wave3     = { "Exor" },
            Wave3Time = 10,
            BossWave  = { "Grunt_Sapper", "Grunt_Shotgun", "Grunt_Shotgun", "Grunt_Sapper", 
                          "Grunt_Sapper", "Grunt_Shotgun", "Grunt_Shotgun", "Grunt_Sapper", },
            BossWaveTime = 2,
            OnStart = EM.Sequence(
                EM.AssaultWeather("RadLeak", 60000, 25000),
                EM.OrderDrop(15000, { spawns = { grunts=6, medics=2, captains=1, breachers=3  }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.ExorDrop(17000, { spawns = { exors=2, armoreds=2 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(25000, { spawns = { grunts=12 }, spawnInterval=2000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(26000, { spawns = { breachers=8 }, spawnInterval=4000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.ExorDrop(30000, { spawns = { monks=2, armoreds=1 }, spawnRadius=3000, minSpawnRadius=1500 })
            )
        },
        {
            Name = "monkdad - END",
            StoryMin = 90, StoryMax = 100,
            StartMessage   = "The fog before the storm...",
            Wave1     = { "Exor_Pikeman", "Exor", "Exor_Pikeman", "Exor", "Exor_Pikeman", },
            Wave1Time = 2,
            Wave2     = { "Exor_Pikeman" },
            Wave2Time = 15,
            Wave3     = { "Exor_Monk", "Exor_Monk", "Exor_Monk", "Exor_Monk", "Exor_Monk",
                          "Exor_Monk", "Exor_Monk", "Exor_Monk", "Exor_Monk", "Exor_Monk", },
            Wave3Time = 2,
            BossWave  = { "Exor_Pikeman", "Exor_Pikeman", "Exor_Pikeman", "Exor_Pikeman", "Exor_Pikeman", },
            BossWaveTime = 3,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Fog", 240000, 18000),

                -- Spawn throughout the encounter
                EM.ExorDrop(15000, { spawns = { monks=4 }, spawnInterval=12000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.ExorDrop(16000, { spawns = { exors=3 }, spawnInterval=20000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.SymphonistDrop(10000, { spawns = { symphonists=4 }, spawnRadius=1000, minSpawnRadius=500, spawnInterval=15000 }),

                EM.ExorDrop(35000, { spawns = { exors=1, monks=2 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.ExorDrop(60000, { spawns = { monks=1, pikemen=2 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.ExorDrop(80000, { spawns = { monks=1, volatiles=1 }, spawnRadius=3000, minSpawnRadius=1500 })
            )
        },
        {
            Name = "monkdad - POSTEND",
            StoryMin = 102, StoryMax = 999,
            StartMessage   = "The fog before the storm...",
            Wave1     = { "Exor_Pikeman", "Exor", "Exor_Pikeman", "Exor", "Exor_Pikeman", },
            Wave1Time = 2,
            Wave2     = { "Symph", "Symph" },
            Wave2Time = 10,
            Wave3     = { "Exor_Monk", "Exor_Monk", "Exor_Monk", "Exor_Monk", "Exor_Monk",
                          "Exor_Monk", "Exor_Monk", "Exor", },
            Wave3Time = 2,
            BossWave  = { "Exor_Pikeman", "Exor_Pikeman", "Exor_Pikeman", "Exor_Pikeman", "Exor_Pikeman", },
            BossWaveTime = 3,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Fog", 50000, 18000),

                -- Spawn throughout the encounter
                EM.ExorDrop(15000, { spawns = { monks=5 }, spawnInterval=10000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.ExorDrop(16000, { spawns = { exors=4 }, spawnInterval=15000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.SymphonistDrop(20000, { spawns = { symphonists=4 }, spawnRadius=1000, minSpawnRadius=500, spawnInterval=5000 }),

                EM.ExorDrop(35000, { spawns = { exors=2, armoreds=2 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.AssaultWeather("Spores", 60000, 75000),
                EM.ExorDrop(60000, { spawns = { monks=4, pikemen=2 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.ExorDrop(80000, { spawns = { volatiles=3 }, spawnRadius=3000, minSpawnRadius=1500 })
            )
        },
    },

    -- assault_exorsquad: Exor_Monk, Exor_Armored, Exor_Monk | boss: none | "Something fowl lurks nearby…" | 5/4/3/10 | Dams_ReachedCentral
    assault_exorsquad = {
        {
            Name = "exorsquad - MID",
            StoryMin = 52, StoryMax = 70,
            StartMessage   = "An exor warband!",
            Wave1     = { "Exor", "Exor", "Sow", "Sow", "Sow",
                          "Exor_Monk", "Exor_Monk", "Peccary_Mushroom", "Peccary_Mushroom",  },
            Wave1Time = 2,
            Wave2     = { "Peccary_Mushroom", "Peccary_Mushroom", },
            Wave2Time = 10,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Exor", "Exor", "Exor", "Exor_Armored",  },
            BossWaveTime = 5,
            OnStart = EM.Sequence(
                EM.ExorDrop(5000, { spawns = { exors=1, monks=1 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.ExorDrop(40000, { spawns = { exors=1, monks=1 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.ExorDrop(55000, { spawns = { armoreds=1 }, spawnRadius=3000, minSpawnRadius=1500 })
            )
        },
        {
            Name = "exorsquad - LATE",
            StoryMin = 71, StoryMax = 90,
            StartMessage   = "An exor warband!",
             Wave1     = { "Exor_Armored", "Exor_Armored", "Peccary_Armored", "Peccary_Armored", "Peccary_Armored",
                          "Exor_Monk", "Exor_Monk", "Peccary_Volatile", "Peccary_Volatile", "Peccary_Volatile",  },
            Wave1Time = 2,
            Wave2     = { },
            Wave2Time = 1,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Exor_Pikeman", "Exor_Volatile", "Exor_Pikeman", "Exor_Volatile", "Exor_Pikeman",   },
            BossWaveTime = 5,
            OnStart = EM.Sequence(
                EM.ExorDrop(5000, { spawns = { armoreds=1, pikemen=1 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.ExorDrop(20000, { spawns = { exors=1, monks=1 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.ExorDrop(30000, { spawns = { armoreds=1, pikemen=1 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.ExorDrop(42000, { spawns = { armoreds=2, pikemen=1 }, spawnRadius=3000, minSpawnRadius=1500 })
            )
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
            Wave2Time = 5,
            Wave3     = { "Exor_Monk", "Exor_Pikeman", "Exor_Monk", "Exor_Pikeman", "Exor_Monk",
                          "Peccary_Electro", "Exor", "Peccary_Electro", "Exor",
                          "Pest_Enlightened", "Exor_Pikeman", "Pest_Enlightened", "Exor_Pikeman",
                          "Peccary_Electro", "Peccary_Electro",
                          "Exor_Armored", "Exor_Volatile", },
            Wave3Time = 2,
            BossWave  = { "Peccary_Volatile", "Peccary_Volatile", "Peccary_Volatile", },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.ExorDrop(15000, { spawns = { monks=1, exors=1 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.ExorDrop(25000, { spawns = { monks=2, exors=1, armoreds=1 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.ExorDrop(45000, { spawns = { monks=2, exors=2, armoreds=1 }, spawnRadius=3000, minSpawnRadius=1500 })
            )
        },
        {
            Name = "exorsquad - POSTEND",
            StoryMin = 102, StoryMax = 999,
            StartMessage   = "An Exordinary invasion!",
            Wave1     = { "Exor", "Exor", "Exor",
                          "Sow", "Sow", "Sow",
                          "Exor_Armored", "Exor_Armored", "Exor_Armored",
                          "Peccary_Armored", "Peccary_Electro", "Peccary_Armored", },
            Wave1Time = 2,
            Wave2     = { "Peccary_Volatile", "Exor_Volatile", "Peccary_Volatile", 
                          "Peccary_Volatile", "Exor_Volatile", "Peccary_Volatile",  },
            Wave2Time = 5,
            Wave3     = { "Pest_Enlightened", "Exor_Monk", "Exor_Pikeman", "Exor_Monk", "Exor_Pikeman", 
                          "Pest_Enlightened", "Peccary_Electro", "Peccary_Armored", "Peccary_Electro", "Peccary_Armored",
                          "Pest_Enlightened", "Exor", "Exor_Armored", "Exor", "Exor_Armored",
                          "Pest_Leyak", "Pest_Leyak", "Pest_Leyak", },
            Wave3Time = 2,
            BossWave  = { "Peccary_Volatile", "Peccary_Volatile", "Peccary_Volatile", },
            BossWaveTime = 5,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Blackout", 15000, 25000),
                EM.ExorDrop(5000, { spawns = { monks=2, exors=1, armoreds=1, pikemen=1, volatiles=1 }, spawnRadius=3000, minSpawnRadius=1500 }),

                EM.ExorDrop(10000, { spawns = { monks=15 }, spawnInterval=5000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.ExorDrop(30000, { spawns = { exors=10 }, spawnInterval=4000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.ExorDrop(50000, { spawns = { armoreds=5 }, spawnInterval=6000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.ExorDrop(55000, { spawns = { pikemen=5 }, spawnInterval=5000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.ExorDrop(70000, { spawns = { volatiles=3 }, spawnInterval=6000, spawnRadius=3000, minSpawnRadius=1500 })
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
            Wave1     = { "Grunt_Guard", "Grunt_Medic", },
            Wave1Time = 5,
            Wave2     = { "Grunt_Captain", },
            Wave2Time = 15,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Grunt_Guard", "Grunt_Medic", "Grunt_Captain" },
            BossWaveTime = 5,
            OnStart = EM.OrderDrop(10000, { spawns = { grunts=3 }, spawnRadius=3000, minSpawnRadius=1500 })
        },
        {
            Name       = "smggrunt - MID",
            StoryMin   = 40, StoryMax = 60,
            StartMessage = "A radio crackle is heard nearby...",
            Wave1     = { "Grunt_Guard", "Grunt", "Grunt_Medic", "Grunt_Shotgun" },
            Wave1Time = 2,
            Wave2     = { "Grunt_Captain", },
            Wave2Time = 15,
            Wave3     = { "Grunt_Shotgun", "Grunt_Shotgun", "Grunt_Medic", "Grunt",
                          "Grunt_Guard", "Grunt", "Grunt_Medic", "Grunt_Guard"  },
            Wave3Time = 2,
            BossWave  = { "Grunt_Captain" },
            BossWaveTime = 15,
            OnStart = EM.Sequence(
                EM.OrderDrop(3000, { spawns = { guards=2, medics=1, captains=1 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(25000, { spawns = { guards=2, captains=1, breachers=1 }, spawnRadius=3000, minSpawnRadius=1500 })
            )
        },
    },
   
    -- [40-100] assault_shotgunsquad: Grunt_Captain, Grunt_Medic, Grunt_Shotgun | boss: none | "A radio crackle is heard nearby…" | 5/5/5/10 | LABS_ReachedCommandCenter
    assault_shotgunsquad = {
        {
            Name       = "shotgunsquad - MID",
            StoryMin   = 40, StoryMax = 60,
            StartMessage = "A radio crackle is heard nearby...",
            Wave1     = { "Grunt_Shotgun", "Grunt_Shotgun", "Grunt_Medic", "Grunt_Medic", },
            Wave1Time = 3,
            Wave2     = { "Grunt_Captain" },
            Wave2Time = 15,
            Wave3     = { "Grunt_Shotgun", "Grunt_Shotgun", "Grunt_Shotgun", "Grunt_Shotgun",
                          "Grunt_Medic", "Grunt_Medic", },
            Wave3Time = 1,
            BossWave  = { "Grunt_Captain" },
            BossWaveTime = 15,
            OnStart = EM.Sequence(
                EM.OrderDrop(5000, { spawns = { breachers=1 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(25000, { spawns = { grunts=1, captains=1, breachers=2 }, spawnRadius=3000, minSpawnRadius=1500 })
            )
        },
        {
            Name       = "shotgunsquad - LATE",
            StoryMin   = 60, StoryMax = 80,
            StartMessage = "Close quarters Order!",
            Wave1      = { "Grunt_Shotgun", "Grunt_Shotgun", "Grunt_Shotgun", 
                          "Groupe_Grunt", "Grunt_Medic", "Grunt_Medic", },
            Wave1Time = 3,
            Wave2     = { "Grunt_Captain", },
            Wave2Time = 15,
            Wave3     = { "Groupe_Shotgun", "Grunt_Shotgun", "Grunt_Shotgun", "Grunt_Shotgun",
                          "Groupe_Grunt", "Groupe_Grunt", "Grunt_Medic", "Grunt_Medic", },
            Wave3Time = 1,
            BossWave  = { "Grunt_Captain", "Grunt_Captain", "Grunt_Captain",  },
            BossWaveTime = 5,
            OnStart = EM.Sequence(
                EM.OrderDrop(5000, { spawns = { breachers=2 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(25000, { spawns = { guards=2, breachers=2, captains=1 }, spawnInterval=1000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(50000, { spawns = { breachers=3 }, spawnRadius=3000, minSpawnRadius=1500 })
            )
        },
        {
            Name       = "shotgunsquad - END LEECH",
            StoryMin   = 80, StoryMax = 100,
            WarningMessage = "The lights flicker...",
            StartMessage = "Something materializes above!",
            Wave1     = { "Groupe_Rook", "Grunt_Shotgun", "Grunt_Shotgun", "Grunt_Shotgun", "Groupe_Rook", },
            Wave1Time = 5,
            Wave2     = { "Grunt_Captain", },
            Wave2Time = 20,
            Wave3     = { "Trooper_Shield", "Trooper_Shield", "Trooper_Shotgun", "Trooper_Shotgun", 
                          "Grunt_Shotgun", "Grunt_Shotgun", "Groupe_Shotgun", "Groupe_Shotgun", },
            Wave3Time = 3,
            BossWave  = { "Trooper_Shotgun", "Trooper_Shotgun", 
                          "Grunt_FlameRat", "Grunt_FlameRat" },
            BossWaveTime = 7,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Blackout", 60000, 15000),
                EM.PowerLeechBossDrop(1000, { spawns= { powerLeeches=1 } }),
                EM.OrderDrop(1000, { spawns = { captains=1, breachers=2 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(35000, { spawns = { captains=1, breachers=3 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(65000, { spawns = { captains=1, medics=1, breachers=4 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(90000, { spawns = { breachers=3 }, spawnRadius=3000, minSpawnRadius=1500 })
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
            BossWaveTime = 5,
            OnStart = EM.Sequence(
                EM.OrderDrop(5000, { spawns = { captains=1, grunts=3 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(25000, { spawns = { grunts=2, breachers=2 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(45000, { spawns = { captains=2, medics=2, breachers=4 }, spawnRadius=3000, minSpawnRadius=1500 })
            )
        },
        {
            Name       = "groupe - LATE",
            StoryMin   = 80, StoryMax = 100,
            StartMessage = "A groupe assault!",
            Wave1     = { "Groupe_Grunt", "Groupe_Grunt", "Groupe_Rook", "Groupe_Rook", 
                          "Groupe_Shotgun", "Groupe_Shotgun", "Grunt_Captain", },
            Wave1Time = 2,
            Wave2     = { "Grunt_Captain" },
            Wave2Time = 20,
            Wave3     = { "Groupe_Grunt", "Groupe_Grunt", "Groupe_Rook", "Groupe_Rook", 
                          "Groupe_Shotgun", "Groupe_Shotgun", "Grunt_Captain", },
            Wave3Time = 2,
            BossWave  = { "Grunt_Sapper", "Groupe_Shotgun", "Groupe_Rook", "Groupe_Grunt", 
                          "Grunt_Sapper", "Groupe_Shotgun", "Groupe_Rook", "Groupe_Grunt", },
            BossWaveTime = 7,
            OnStart = EM.Sequence(
                EM.RatDrop(3000, { spawns = { sappers=2 } }),
                EM.OrderDrop(20000, { spawns = { captains=2 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.RatDrop(30000, { spawns = { sappers=1 } }),
                EM.OrderDrop(45000, { spawns = { grunts=2, breachers=2 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(70000, { spawns = { captains=2, medics=2, breachers=4 }, spawnRadius=3000, minSpawnRadius=1500 })
            )
        },
        {
            Name       = "groupe - END Praetorium",
            StoryMin   = 90, StoryMax = 100,
            StartMessage = "A response from the Praetorium",
            Wave1     = { "Grunt_Medic", "Grunt_Medic", "Grunt_Captain",
                          "Grunt_Sapper", "Grunt_Sapper", "Interfector", "Interfector", },
            Wave1Time = 2,
            Wave2     = { "Grunt_LabRat_Mechanic", "Grunt_LabRat_Mechanic", "Grunt_LabRat_Mechanic", "Grunt_FlameRat" },
            Wave2Time = 5,
            Wave3     = { "Trooper_Shield", "Trooper_Shield", "Trooper_Shotgun", "Trooper_Shotgun", 
                          "Grunt_Medic", "Grunt_Medic", "Grunt_Captain",
                          "Grunt_Sapper", "Grunt_Sapper", "Interfector", "Interfector", },
            Wave3Time = 2,
            BossWave  = { "Grunt_FlameRat", "Grunt_FlameRat", "Grunt_FlameRat", },
            BossWaveTime = 15,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Blackout", 30000, 45000),

                -- Spawn through the encounter
                EM.OrderDrop(3000, { spawns = { interfectors=3 }, spawnInterval=25000, dilationStart = 1, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(5000, { spawns = { grunts=6 }, spawnInterval=8000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(6000, { spawns = { medics=3 }, spawnInterval=15000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(7000, { spawns = { captains=2 }, spawnInterval=20000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(8000, { spawns = { breachers=3 }, spawnInterval=18000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.RatDrop(10000, { spawns = { labRats=2, garageRats=2 }}),

                EM.OrderDrop(5000, { spawns = { guards=2, grunts=2, breachers=1 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.RatDrop(10000, { spawns = { labRats=2, garageRats=2 }}),

                EM.RatDrop(40000, { spawns = { labRats=1, garageRats=1, sappers=2 }}),
                EM.OrderDrop(45000, { spawns = { guards=2, medics=1, captains=1, breachers=1 }, spawnRadius=3000, minSpawnRadius=1500 })
            )
        },
        {
            Name = "groupe - END Prae xReaper",
            StoryMin = 90, StoryMax = 100,
            StartMessage = "An ancient nemesis...",
            Wave1     = { "Interfector", "Interfector", "Grunt_Sapper", "Grunt_FlameRat", },
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
                EM.AssaultWeather("BlackFog", 150000, 25000),

                -- Spawn through the encounter
                EM.ReaperDrop(10000, { spawns = { reapers=4 }, spawnInterval=20000 }),
                EM.ReaperDrop(20000, { spawns = { reapers=4 }, spawnInterval=20000, spawnRadius=2000, minSpawnRadius=1000 }),
                EM.OrderDrop(5000, { spawns = { guards=12 }, spawnInterval=4000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(6000, { spawns = { medics=7 }, spawnInterval=8000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(7000, { spawns = { captains=6 }, spawnInterval=10000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(8000, { spawns = { breachers=5 }, spawnInterval=12000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(3000, { spawns = { interfectors=5 }, dilationStart = 1, spawnInterval=15000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.RatDrop(20000, { spawns = { sappers=3 }, spawnInterval=20000 }),
                
                EM.RatDrop(12000, { spawns = { labRats=4 }, spawnInterval=15000 })
            )
        },
        {
            Name       = "groupe - POSTEND Praetorium",
            StoryMin   = 102, StoryMax = 999,
            StartMessage = "Order will be imposed.",
            Wave1     = { "Trooper", "Trooper", "Trooper", "Trooper", "Trooper", 
                          "Grunt_Medic", "Grunt_Medic", "Grunt_Captain",
                          "Grunt_Sapper", "Grunt_Sapper", "Interfector", },
            Wave1Time = 2,
            Wave2     = { "Grunt_LabRat_Mechanic", "Grunt_FlameRat", "Grunt_LabRat_Mechanic", "Grunt_FlameRat" },
            Wave2Time = 10,
            Wave3     = { "Trooper_Shield", "Trooper_Shield", "Trooper_Shotgun", "Trooper_Shotgun", 
                          "Trooper", "Trooper", "Trooper", 
                          "Grunt_Medic", "Grunt_Medic", "Grunt_Captain",
                          "Grunt_Sapper", "Grunt_Sapper", "Interfector", },
            Wave3Time = 2,
            BossWave  = { "Grunt_FlameRat", "Trooper", "Grunt_FlameRat", "Trooper", "Grunt_FlameRat", },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Blackout", 60000, 21000),
                EM.PowerLeechBossDrop(1000, { spawns = { powerLeeches=1 } }),
                
                -- Spawn through the encounter
                EM.OrderDrop(5000, { spawns = { guards=12 }, spawnInterval=4000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(6000, { spawns = { medics=7 }, spawnInterval=8000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(7000, { spawns = { captains=6 }, spawnInterval=10000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(8000, { spawns = { breachers=5 }, spawnInterval=12000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(3000, { spawns = { interfectors=5 }, dilationStart = 1, spawnInterval=15000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.RatDrop(20000, { spawns = { sappers=3 }, spawnInterval=20000 }),

                EM.OrderDrop(5000, { spawns = { guards=2, grunts=2, breachers=1 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.RatDrop(10000, { spawns = { labRats=2, garageRats=2 }}),

                EM.RatDrop(40000, { spawns = { garageRats=1, sappers=1 } }),

                EM.RatDrop(90000, { spawns = { flameRats=1 } }),
                EM.OrderDrop(90000, { spawns = { guards=3, grunts=3, medics=3, captains=2, breachers=2  }, spawnRadius=3000, minSpawnRadius=1500 }),

                EM.RatDrop(120000, { spawns = { sappers=1, flameRats=2 }, spawnInterval=3000 })
            )
           
        },
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
            BossWaveTime = 15,
            OnStart = EM.Sequence(
                EM.OrderDrop(15000, { spawns = { guards=2, captains=1 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(30000, { spawns = { guards=1, grunts=1, medics=1, captains=1, breachers=1 }, spawnRadius=3000, minSpawnRadius=1500 })
            )
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
            BossWaveTime = 15,
            OnStart = EM.Sequence(
                EM.OrderDrop(15000, { spawns = { guards=2, captains=1 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(45000, { spawns = { guards=4, captains=2 }, spawnRadius=3000, minSpawnRadius=1500 })
            )
        },
        {
            Name = "ratpatrol - END",
            StoryMin = 90, StoryMax = 100,
            StartMessage   = "No one expects the Ordo Inquisition!",
            Wave1     = { "Grunt_Sapper", "Grunt_LabRat", "Grunt_LabRat_Mechanic", 
                          "Grunt_Sapper", "Grunt_LabRat", "Grunt_LabRat_Mechanic", },
            Wave1Time = 2,
            Wave2     = { "Grunt_Sapper", "Grunt_Sapper", },
            Wave2Time = 15,
            Wave3     = { "Interfector", "Interfector", "Grunt_Captain", "Grunt_Captain", 
                          "Grunt_LabRat", "Grunt_LabRat", "Grunt_LabRat" },
            Wave3Time = 2,
            BossWave  = { "Grunt_FlameRat", "Grunt_FlameRat" },
            BossWaveTime = 5,
            OnStart = EM.Sequence(
                EM.RatDrop(1000, { spawns = { labRats=2, garageRats=2 }}),
                EM.RatDrop(40000, { spawns = { sappers=1 } }),
                EM.RatDrop(60000, { spawns = { labRats=2, garageRats=2 } })
            )
        },
        {
            Name = "ratpatrol - POSTEND",
            StoryMin = 102, StoryMax = 999,
            StartMessage   = "No one expects the Ordo Inquisition!",
            Wave1     = { "Grunt_Sapper", "Grunt_LabRat", "Grunt_LabRat_Mechanic", "Grunt_LabRat", "Grunt_LabRat_Mechanic", 
                          "Grunt_Sapper", "Grunt_LabRat", "Grunt_LabRat_Mechanic", "Grunt_LabRat", "Grunt_LabRat_Mechanic", },
            Wave1Time = 2,
            Wave2     = { "Grunt_FlameRat", "Grunt_FlameRat", },
            Wave2Time = 15,
            Wave3     = { "Interfector", "Interfector", "Grunt_Captain", "Grunt_Captain", 
                          "Grunt_LabRat", "Grunt_LabRat", "Grunt_LabRat" },
            Wave3Time = 2,
            BossWave  = { "Grunt_FlameRat", "Grunt_FlameRat" },
            BossWaveTime = 5,
            OnStart = EM.Sequence(
                EM.RatDrop(1000, { spawns = { labRats=4, garageRats=4, flameRats=1 }}),
                EM.RatDrop(40000, { spawns = { sappers=1, flameRats=1 }}),
                EM.RatDrop(70000, { spawns = { sappers=1, flameRats=1 } })
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
            BossWave  = { "Gatekeeper_Phyter", "Gatekeeper_Phyter", },
            BossWaveTime = 5,
            OnStart = EM.Sequence(
                EM.GatekeeperDrop(35000, { spawns = { phyters=1, mages=1 }, spawnInterval=3000 })
            )
        },
        {
            Name = "mages - LATE",
            StoryMin = 80, StoryMax = 90,
            StartMessage = "Something arcane assaults your senses...",
            Wave1     = { "Gatekeeper_Phyter", "Gatekeeper_Mage", },
            Wave1Time = 2,
            Wave2     = { "Gatekeeper_Phyter", "Gatekeeper_Mage" },
            Wave2Time = 12,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Gatekeeper_Witch", "Gatekeeper_Witch", },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.GatekeeperDrop(1000, { spawns = { phyters=1, mages=1 }, spawnInterval=4000 }),
                EM.GatekeeperDrop(35000, { spawns = { witches=1, mages=1 }, spawnInterval=4000 })
            )
        },
        {
            Name = "mages - END",
            StoryMin = 90, StoryMax = 100,
            StartMessage = "Something arcane overwhelms your senses...",
            Wave1     = { "Gatekeeper_Witch", "Gatekeeper_Mage", "Gatekeeper_Witch" },
            Wave1Time = 2,
            Wave2     = { "Gatekeeper_Witch",  },
            Wave2Time = 5,
            Wave3     = { "Gatekeeper_Witch", "Gatekeeper_Mage",},
            Wave3Time = 12,
            BossWave  = { "Gatekeeper_Chieftain", "Gatekeeper_Chieftain", },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.GatekeeperDrop(1000, { spawns = { mages=1 } }),
                EM.GatekeeperDrop(2000, { spawns = { witches=1 } }),
                EM.GatekeeperDrop(35000, { spawns = { mages=1 } }),
                EM.GatekeeperDrop(36000, { spawns = { witches=2 } })
            )
        },
        {
            Name = "mages - POSTEND xPRAE",
            StoryMin = 102, StoryMax = 999,
            StartMessage = "A cultish confrontation...",
            Wave1     = { "Gatekeeper_Mage", "Gatekeeper_Witch", "Gatekeeper_Witch", "Gatekeeper_Mage", "Gatekeeper_Witch", },
            Wave1Time = 2,
            Wave2     = { "DarkLens_Witch", },
            Wave2Time = 20,
            Wave3     = { "Grunt_Flamerat", "Grunt_Flamerat", "Grunt_Sapper", "Grunt_Sapper", 
                          "Interfector", "Interfector", "Interfector", "Interfector", },
            Wave3Time = 3,
            BossWave  = { "Gatekeeper_Witch", "Gatekeeper_Witch", "Gatekeeper_Mage", "Gatekeeper_Mage", 
                          "DarkLens_Chieftain", "DarkLens_Witch", "Grunt_FlameRat", "Grunt_FlameRat", },
            BossWaveTime = 7,
            OnStart = EM.Sequence(
                EM.RatDrop(7000, { spawns = { labRats=3, sappers=1, garageRats=3, flameRats=1 }, spawnInterval=500 }),
                EM.AssaultWeather("BlackFog", 10000, 25000),
                EM.GatekeeperDrop(6000, { spawns = { chieftains=1 } }),
                EM.GatekeeperDrop(7000, { spawns = { mages=1 } }),
                EM.GatekeeperDrop(8000, { spawns = { witches=2 } }),
                EM.RatDrop(30000, { spawns = { labRats=2, garageRats=3, flameRats=1 }, spawnInterval=500 }),
                EM.OrderDrop(31000, { spawns = { interfectors=3 }, dilationStart = 1, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.AssaultWeather("BlackFog", 15000, 60000),
                EM.GatekeeperDrop(41000, { spawns = { mages=1, witches=1 }, spawnInterval=1000 }),
                EM.GatekeeperDrop(42000, { spawns = { mages=1, witches=1 }, spawnInterval=1000 }),
                EM.GatekeeperDrop(43000, { spawns = { witches=2 }, spawnInterval=1000 }),
                EM.OrderDrop(44000, { spawns = { interfectors=3 }, dilationStart = 1, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.RatDrop(50000, { spawns = { labRats=3, sappers=1, garageRats=3, flameRats=1, interfectors=3 } }),
                EM.AssaultWeather("BlackFog", 30000, 80000),
                EM.GatekeeperDrop(61000, { spawns = { mages=4 }, spawnInterval=5000 }),
                EM.RatDrop(65000, { spawns = { sappers=2, flameRats=2 } })
            )
        },
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
            StoryMin = 90, StoryMax = 100,
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
            BossWaveTime = 7,
            OnStart = EM.Sequence(
                EM.OrderDrop(20000, { spawns= { grunts=3, guards=3, medics=1, captains=1 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.GatekeeperDrop(40000, { spawns= { heavies=1 }, spawnRadius=1500, minSpawnRadius=700 })
            )
        },
        {
            Name = "gkheavy - POSTEND xORDER",
            StoryMin = 102, StoryMax = 999,
            WarningMessage = "You hear gunfire in the distance...",
            StartMessage = "A confrontation!",
            Wave1     = { "Gatekeeper_Heavy", "Gatekeeper_Heavy", "Gatekeeper_Heavy",
                          "Gatekeeper_Chieftain", "Gatekeeper_Phyter", "Gatekeeper_Phyter", "Gatekeeper_Chieftain",  },
            Wave1Time = 2,
            Wave2     = { "Gatekeeper_Chieftain" },
            Wave2Time = 10,
            Wave3     = { "Trooper_Shotgun", "Trooper_Shotgun", "Interfector", "Interfector", "Grunt_Captain",
                          "Grunt_Sapper", "Grunt_Sapper", "Trooper_Shield", "Trooper_Shield", "Grunt_Captain",
                          "Trooper", "Trooper", "Interfector", "Interfector", "Interfector", },
            Wave3Time = 2,
            BossWave  = { "DarkLens_Heavy", "Gatekeeper_Heavy", "DarkLens_Heavy", "DarkLens_Chieftain" },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.OrderDrop(20000, { spawns= { grunts=3, guards=3, medics=1, captains=1 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.GatekeeperDrop(40000, { spawns= { heavies=2 }, spawnRadius=1500, minSpawnRadius=700 })
            )
        },
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
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.ExorDrop(22000, { spawns = { monks=1, exors=1, armoreds=1 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.GatekeeperDrop(25000, { spawns = { phyters=2, chieftains=1, witches=1, heavies=1 }, spawnRadius=1500, minSpawnRadius=500 })
                
            )
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
                EM.AssaultWeather("Blackfog", 12000, 21000),
                EM.GatekeeperDrop(5000, { spawns = { witches=2, mages=1 }, spawnRadius=1500, minSpawnRadius=500 }),
                EM.GatekeeperDrop(65000, { spawns = { mages=2 }, spawnRadius=1500, minSpawnRadius=500 })
                
            ) 
        },
        {
            Name = "gksquad - POSTEND SUPERBOSS",
            StoryMin = 102, StoryMax = 999,
            StartMessage = "The Gatekeepers hold nothing back...",
            Wave1     = { "Gatekeeper_Witch", "Gatekeeper_Witch", "Gatekeeper_Witch", 
                          "DarkLens_Phyter", "DarkLens_Phyter", "DarkLens_Phyter", "DarkLens_Chieftain", },
            Wave1Time = 5,
            Wave2     = { "Gatekeeper_Heavy", "Gatekeeper_Heavy", "Robot_Defense", "Robot_Defense", },
            Wave2Time = 12,
            Wave3     = { "Robot_Corrupt", "Robot_Defense", "Gatekeeper_Phyter", "Gatekeeper_Phyter", "DarkLens_Chieftain", 
                          "Gatekeeper_Witch", "Gatekeeper_Witch","Gatekeeper_Witch", "Gatekeeper_Witch", "DarkLens_Witch", 
                          "Robot_Corrupt", "Robot_Defense", "Gatekeeper_Phyter", "Gatekeeper_Phyter", "DarkLens_Chieftain",  },
            Wave3Time = 5,
            BossWave  = { "DarkLens_Witch", "DarkLens_Chieftain", "DarkLens_Witch", "DarkLens_Heavy", "DarkLens_Heavy", },
            BossWaveTime = 15,
            OnStart = EM.Sequence(
                -- 1-85, wave1/2
                EM.AssaultWeather("BlackFog", 15000, 22000), 
                EM.GatekeeperDrop(5000, { spawns = { phyters=1, witches=1, chieftains=1 }, spawnInterval=1500 }),
                EM.GatekeeperDrop(6000, { spawns = { phyters=2, mages=1 }, spawnInterval=1500 }),
                EM.AssaultWeather("RadLeak", 45000, 45000), 

                -- 85-160, wave3
                EM.AssaultWeather("BlackFog", 15000, 115000), 
                EM.GatekeeperDrop(65000, { spawns = { phyters=1, heavies=1, chieftains=1 }, spawnInterval=1000 }),
                EM.GatekeeperDrop(66000, { spawns = { phyters=1, mages=1, witches=1 }, spawnInterval=1000 }),
                EM.AssaultWeather("Spores", 60000, 140000), 

                -- 160+, wave4
                EM.AssaultWeather("BlackFog", 15000, 210000), 
                EM.GatekeeperDrop(160000, { spawns = { corruptBots=1 } }),
                EM.GatekeeperDrop(161000, { spawns = { mages=1 } }),

                EM.AssaultWeather("BlackFog", 30000, 240000),
                EM.GatekeeperDrop(211000, { spawns = { witches=1, mages=1 }, spawnInterval=3000 }),
                EM.GatekeeperDrop(212000, { spawns = { witches=1, mages=1 }, spawnInterval=3000 }),
                EM.SpawnDarkLensMage(213000, { spawns = { mages=1 } }),
                EM.ReaperDrop(210000, { spawns = { reapers=2 }, spawnRadius=1600, minSpawnRadius=800 })

            )
        },

        -- Jotun of the Fallow: Can we spawn this?
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
            Wave1     = { "Gatekeeper_Chieftain" },
            Wave1Time = 20,
            Wave2     = { },
            Wave2Time = 1,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Gatekeeper_Witch", "Gatekeeper_Chieftain", "Gatekeeper_Witch", 
                          "Gatekeeper_Chieftain", "Gatekeeper_Witch", "Gatekeeper_Chieftain", },
            BossWaveTime = 7,
            OnStart = EM.Sequence(
                EM.GatekeeperDrop(5000, { spawns = { witches=2 }, spawnInterval=5000 }),
                EM.GatekeeperDrop(6000, { spawns = { witches=2 }, spawnInterval=5000 })
            )
        },
        {
            Name = "witchhunt - LATE xA2",
            StoryMin = 90, StoryMax = 100,
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
            BossWaveTime = 5,
            OnStart = EM.Sequence(
                EM.GatekeeperDrop(2000, { spawns = { witches=3 }, spawnInterval=3000 }),
                EM.ExorDrop(3000, { spawns = { volatiles=2 }, spawnInterval=5000, spawnRadius=3000, minSpawnRadius=1500 })
            )
        },
        {
            Name = "witchhunt - POSTEND xA2",
            StoryMin = 102, StoryMax = 999,
            StartMessage = "A battle in the sky!",
            Wave1     = { "Exor_Volatile", "Exor_Volatile", "Exor_Volatile", "Exor_Volatile", "Exor_Volatile",
                          "Exor_Volatile", "Exor_Volatile",  },
            Wave1Time = 3,
            Wave2     = { "Exor_Volatile" },
            Wave2Time = 10,
            Wave3     = { "DarkLens_Witch", "Gatekeeper_Witch", "Gatekeeper_Witch", "Gatekeeper_Witch", "Gatekeeper_Witch", 
                          "DarkLens_Witch", "Gatekeeper_Witch", "Gatekeeper_Witch", },
            Wave3Time = 3,
            BossWave  = { "Exor_Volatile", "Exor_Volatile", "Exor_Volatile", "Exor_Volatile", 
                          "Exor_Volatile", "Exor_Volatile", "DarkLens_Witch", "DarkLens_Witch", 
                        },
            BossWaveTime = 7,
            OnStart = EM.Sequence(
                EM.GatekeeperDrop(2000, { spawns = { witches=3 }, spawnInterval=3000 }),
                EM.ExorDrop(3000, { spawns = { volatiles=2 }, spawnInterval=5000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.GatekeeperDrop(25000, { spawns = { witches=3 }, spawnInterval=3000 }),
                EM.ExorDrop(30000, { spawns = { volatiles=2 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.GatekeeperDrop(70000, { spawns = { witches=5 }, spawnInterval=1000 }),
                EM.ExorDrop(75000, { spawns = { volatiles=3 }, spawnRadius=3000, minSpawnRadius=1500 })
            )
        },
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
                          "Pest", "Pest", "Peccary", "Peccary", "Exor_Monk", "Exor_Monk" },
            Wave3Time = 2,
            BossWave  = { "Robot_Security" },
            BossWaveTime = 10,
        },
        {
            Name = "pistolbros - ROBOT MID xA2",
            StoryMin = 35, StoryMax = 60,
            StartMessage   = "A containment breach!",
            StartSound = "/Game/Audio/Music/ShortStings/anteverse_sting.anteverse_sting",
            Wave1     = { "Pest_Electro", "Pest_Electro", "Pest_Electro", "Pest_Electro", "Exor_Monk", "Exor", "Sow", "Sow" },
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
            Name = "pistolbros - ROBOT LATE xORDER",
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
            Name = "pistolbros - ROBOT END xORDER",
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
                EM.GatekeeperDrop(5000, { spawns = { corruptBots=1 } })
            )
        },
        {
            Name = "corruptbot - LATE xGIANT",
            StoryMin = 80, StoryMax = 100,
            StartMessage = "Massive entities are on the loose!",
            Wave1     = { "Robot_Containment", "Robot_Containment", "Robot_Containment", "Robot_Containment",  },
            Wave1Time = 5,
            Wave2     = { },
            Wave2Time = 1,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Robot_Corrupt", "Robot_Corrupt", },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.GiantDrop(12000, { spawns = { tarasques=2 } })
            )
        },
        {
            Name = "corruptbot - END SIEGE",
            StoryMin = 90, StoryMax = 100,
            StartMessage = "Corruption and fire!",
            Wave1     = { "Robot_Defense", "Robot_Defense", },
            Wave1Time = 10,
            Wave2     = { "Robot_Corrupt" },
            Wave2Time = 20,
            Wave3     = { "Robot_Defense", "Robot_Defense", },
            Wave3Time = 5,
            BossWave  = { "Robot_Corrupt" },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Spores", 120000, 18000),
                EM.GatekeeperDrop(1000, { spawns = { corruptBots=1 } }),
                EM.GatekeeperDrop(5000, { spawns = { witches=1 } })
            )
        },
        {
            Name = "corruptbot - POSTGAME SIEGE",
            StoryMin = 102, StoryMax = 999,
            StartMessage = "Corruption and fire!",
            Wave1     = { "Robot_Corrupt", "Robot_Defense", },
            Wave1Time = 5,
            Wave2     = { "Robot_Corrupt", "Robot_Defense" },
            Wave2Time = 15,
            Wave3     = { "Robot_Corrupt", "Robot_Defense", "Robot_Corrupt", "Robot_Defense",  },
            Wave3Time = 5,
            BossWave  = { "Robot_Corrupt", "Robot_Corrupt" },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Spores", 120000, 18000),
                EM.GatekeeperDrop(1000, { spawns = { corruptBots=1 } }),
                EM.GatekeeperDrop(5000, { spawns = { witches=2 }, spawnInterval=1000 }),
                EM.GatekeeperDrop(100000, { spawns = { corruptBots=1 } }),
                EM.GatekeeperDrop(101000, { spawns = { corruptBots=1 } })
            )
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
            StoryMin = 20, StoryMax = 40,
            StartMessage   = "An unnatural fog descends... ",
            Wave1     = { },
            Wave1Time = 1,
            Wave2     = { },
            Wave2Time = 1,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Symph", "Symph" },
            BossWaveTime = 30,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Fog", 240000, 10000)
            )
        },
        {
            Name = "soldierpatrol - SYMPH EARLYMID",
            StoryMin = 35, StoryMax = 50,
            StartMessage   = "An unnatural fog descends... ",
            Wave1     = { },
            Wave1Time = 1,
            Wave2     = { },
            Wave2Time = 1,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "Symph", "Symph", },
            BossWaveTime = 45,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Fog", 240000, 10000),
                EM.SymphonistDrop(3000, { spawns = { symphonists=2 } })
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
                EM.AssaultWeather("Fog", 240000, 10000),
                EM.SymphonistDrop(45000, { spawns = { symphonists = 2 } })
            )
        },
        {
            Name = "soldierpatrol - SYMPH xA2",
            StoryMin = 70, StoryMax = 90,
            StartMessage   = "A commotion in the fog... ",
            Wave1     = { "Pest_Volatile", "Pest_Carbonated", "Pest_Electro", "Peccary", "Peccary", 
                          "Exor", "Exor", "Exor_Monk", "Exor_Monk", "Sow", },
            Wave1Time = 2,
            Wave2     = { "Symph", "Symph", },
            Wave2Time = 10,
            Wave3     = { "Exor", "Exor", "Exor_Monk", "Exor_Armored", "Exor_Pikeman", "Exor_Pikeman", },
            Wave3Time = 2,
            BossWave  = { "Symph", "Symph", },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Fog", 240000, 10000),
                EM.SymphonistDrop(2000, { spawns = { symphonists=1 } }),
                EM.SymphonistDrop(40000, { spawns = { symphonists=1 } }),
                EM.SymphonistDrop(70000, { spawns = { symphonists=1 } }),
                EM.SymphonistDrop(100000, { spawns = { symphonists=1 } })
            )
        },
        {
            Name = "soldierpatrol - SYMPH END xORDER",
            StoryMin = 80, StoryMax = 100,
            StartMessage   = "A commotion in the fog... ",
            Wave1     = { "Grunt_Shotgun", "Grunt_Shotgun", "Grunt_Shotgun", "Grunt_Shotgun",
                          "Grunt", "Grunt_Guard", "Grunt", "Grunt_Guard",
                          "Grunt_Medic", "Grunt_Medic", "Grunt_Captain" },
            Wave1Time = 2,
            Wave2     = { },
            Wave2Time = 10,
            Wave3     = { "Symph", "Symph", "Symph", "Symph", },
            Wave3Time = 2,
            BossWave  = { "Interfector", "Interfector" },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Fog", 240000, 3000),
                EM.SymphonistDrop(1000, { spawns = { symphonists=1 } }),
                EM.OrderDrop(15000, { spawns = { grunts=6, medics=1, captains=1, breachers=2 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.SymphonistDrop(20000, { spawns = { symphonists=2 } }),
                EM.SymphonistDrop(40000, { spawns = { symphonists=1 } }),
                EM.SymphonistDrop(70000, { spawns = { symphonists=2 } }),
                EM.SymphonistDrop(100000, { spawns = { symphonists=2 } })
            )
        },
        {
            Name = "soldierpatrol - SYMPH END xGKs",
            StoryMin = 80, StoryMax = 100,
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
                EM.GatekeeperDrop(15000, { spawns = { phyters=2 } }),
                EM.SymphonistDrop(20000, { spawns = { symphonists=1 } }),

                EM.GatekeeperDrop(40000, { spawns = { heavies=1 } }),
                EM.SymphonistDrop(45000, { spawns = { symphonists=2 } }),

                EM.GatekeeperDrop(70000, { spawns = { mages=1, witches=1 } }),
                EM.SymphonistDrop(75000, { spawns = { symphonists=2 } }),

                EM.GatekeeperDrop(100000, { spawns = { mages=1, witches=2 } }),
                EM.SymphonistDrop(105000, { spawns = { symphonists=3 } })
            )
        },
        {
            Name = "soldierpatrol - SYMPH POSTEND xGKsORDER",
            StoryMin = 102, StoryMax = 999,
            StartMessage   = "A commotion in the fog... ",
            Wave1     = { "Grunt_Shotgun", "Grunt_Shotgun", "Grunt_Shotgun", "Grunt_Shotgun", "Grunt_Shotgun", 
                          "Trooper_Shield", "Trooper_Shield", "Trooper_Shield", "Trooper_Shield", "Trooper_Shield", 
                          "Grunt_Captain", "Grunt_Medic", "Grunt_Captain", "Grunt_Medic", "Grunt_Captain", 
                          "Trooper", "Groupe_Grunt", "Groupe_Grunt", "Groupe_Grunt", "Trooper", },
            Wave1Time = 1, 
            Wave2     = { "Interfector", },
            Wave2Time = 7,
            Wave3     = { "Gatekeeper_Heavy", "Gatekeeper_Phyter", "Gatekeeper_Phyter",
                          "Gatekeeper_Mage", "Gatekeeper_Mage", "Gatekeeper_Mage", 
                          "Gatekeeper_Witch", "Gatekeeper_Witch", "Gatekeeper_Witch", "Gatekeeper_Chieftain" },
            Wave3Time = 2,
            BossWave  = { "Symph", "Symph", "Symph", "Symph", "Symph", },
            BossWaveTime = 8,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Fog", 240000, 3000),
                
                -- Spawn through the encounter
                EM.SymphonistDrop(10000, { spawns = { symphonists=5 }, spawnInterval = 15000 }),

                EM.GatekeeperDrop(4000, { spawns = { phyters=3, chieftains=1} }),
                EM.OrderDrop(5000, { spawns = { guards=3, grunts=2, captains=1, breachers=1 }, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.SymphonistDrop(8000, { spawns = { symphonists=2 } }),

                EM.GatekeeperDrop(60000, { spawns = { witches=3, chieftains=1} }),
                EM.RatDrop(62000, { spawns = { labRats=2, garageRats=2, sappers=1, flameRats=2 }}),
                EM.SymphonistDrop(65000, { spawns = { symphonists=4 }, spawnRadius=2000, minSpawnRadius=700 })
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
            StoryMin = 70, StoryMax = 90,
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
            StoryMin = 90, StoryMax = 100,
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
        },
        {
            Name = "larva - POSTEND xGIANTS",
            StoryMin = 102, StoryMax = 999,
            StartMessage = "A clash of titans!",
            Wave1     = { "Gatekeeper_Heavy", "Gatekeeper_Heavy", },
            Wave1Time = 30,
            Wave2     = { "Gatekeeper_Heavy", "Gatekeeper_Heavy", },
            Wave2Time = 15,
            Wave3     = { },
            Wave3Time = 2,
            BossWave  = { "DarkLens_Heavy", "DarkLens_Heavy" },
            BossWaveTime = 20,
            OnStart = EM.Sequence(
                EM.GiantDrop(5000, { spawns = { tarasques=1 }, spawnRadius=2000, minSpawnRadius=1000 }),
                EM.GiantDrop(20000, { spawns = { yetis=1 }, spawnRadius=2500, minSpawnRadius=1500 }),
                EM.GiantDrop(35000, { spawns = { bigfoots=1 }, spawnRadius=2500, minSpawnRadius=1500 }),
                EM.GiantDrop(50000, { spawns = { yetis=2 }, spawnRadius=2500, minSpawnRadius=1500 }),
                EM.GiantDrop(80000, { spawns = { behemoths=1 }, spawnRadius=2500, minSpawnRadius=1500 })
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
            Wave2     = { "Reaper", },
            Wave2Time = 10,
            Wave3     = { "Zombie", "Zombie_Sci", "Zombie", "Zombie_Sci", "Zombie",
                          "Zombie", "Zombie", "Zombie_Sci", "Zombie", "Zombie",
                          "Zombie", "Zombie_Sci", "Zombie", "Zombie_Sci", "Zombie", },
            Wave3Time = 1,
            BossWave  = { "Zombie", "Zombie_Sci", "Zombie", "Zombie_Sci", "Zombie",
                          "Zombie", "Zombie", "Zombie_Sci", "Zombie", "Zombie",
                          "Zombie", "Zombie_Sci", "Zombie", "Zombie_Sci", "Zombie", },
            BossWaveTime = 1,
            OnStart = EM.AssaultWeather("BlackFog", 60000, 25000),
        },
        {
            Name = "zombiehorde - END REAPER",
            StoryMin = 90, StoryMax = 100,
            StartMessage = "Don't fear the reaper...",
            Wave1     = { "Reaper", "Reaper", },
            Wave1Time = 2,
            Wave2     = { "Reaper", },
            Wave2Time = 20,
            Wave3     = {  },
            Wave3Time = 1,
            BossWave  = { "Reaper", "Reaper", "Reaper", },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.AssaultWeather("BlackFog", 75000, 15000),
                EM.ReaperDrop(1000, { spawns = { reapers=1 } }),
                EM.ReaperDrop(60000, { spawns = { reapers=1 } })
            )
        },
        {
            Name = "zombiehorde - POSTEND REAPER xGKs",
            StoryMin = 102, StoryMax = 999,
            StartMessage     = "Fear the reaper...",
            Wave1     = { "DarkLens_Witch", "DarkLens_Witch" },
            Wave1Time = 45,
            Wave2     = { },
            Wave2Time = 2,
            Wave3     = { },
            Wave3Time = 2,
            BossWave  = { "DarkLens_Witch" },
            BossWaveTime = 60,
            OnStart = EM.Sequence(
                EM.AssaultWeather("BlackFog", 130000, 17000),
                EM.ReaperPortalDrop(5000, { spawns={ reapers=3 }, firstSpawnInterval=5000, spawnInterval=30000, spawnRadius=1500, minSpawnRadius=500 }),
                EM.ReaperPortalDrop(40000, { spawns={ reapers=2 }, firstSpawnInterval=5000, spawnInterval=30000, spawnRadius=1500, minSpawnRadius=500 }),
                EM.ReaperPortalDrop(75000, { spawns={ reapers=1 }, spawnInterval=5000, spawnRadius=1500, minSpawnRadius=500 })
            )
        },
        {
            Name = "zombiehorde - POSTEND REAPER xGKs",
            StoryMin = 102, StoryMax = 999,
            StartMessage = "Reap what you sow!",
            Wave1     = { "DarkLens_Chieftain", "Gatekeeper_Phyter", "Gatekeeper_Phyter", "Gatekeeper_Phyter",
                          "Gatekeeper_Phyter", "Gatekeeper_Phyter", "Gatekeeper_Phyter", "Gatekeeper_Phyter",
                          "Gatekeeper_Phyter", "Gatekeeper_Phyter","Gatekeeper_Phyter", "Gatekeeper_Chieftain", },
            Wave1Time = 1,
            Wave2     = { "DarkLens_Witch", "Gatekeeper_Witch", "Gatekeeper_Witch", "Gatekeeper_Witch", 
                          "Gatekeeper_Witch", "Gatekeeper_Witch", "Gatekeeper_Mage", "Gatekeeper_Mage", },
            Wave2Time = 2,
            Wave3     = { "DarkLens_Heavy", "Gatekeeper_Phyter", "Gatekeeper_Heavy", "Gatekeeper_Phyter", 
                          "Gatekeeper_Heavy", "Gatekeeper_Phyter", },
            Wave3Time = 7,
            BossWave  = { "Robot_Corrupt", "Robot_Corrupt", },
            BossWaveTime = 25,
            OnStart = EM.Sequence(
                EM.AssaultWeather("BlackFog", 90000, 35000),
                EM.ReaperDrop(15000, { spawns = { reapers=2 }, spawnRadius=2500, minSpawnRadius=1000 }),
                EM.ReaperDrop(35000, { spawns = { reapers=2 }, spawnRadius=2500, minSpawnRadius=1000 }),
                EM.ReaperDrop(50000, { spawns = { reapers=3 }, spawnRadius=2500, minSpawnRadius=1000 }),
                EM.ReaperDrop(65000, { spawns = { reapers=3 }, spawnRadius=2500, minSpawnRadius=1000 })
            )
        },
        {
            Name = "groupe - POSTEND Reaper xORDER",
            StoryMin = 102, StoryMax = 999,
            StartMessage = "An ancient nemesis...",
            Wave1     = { "Interfector", "Interfector", "Grunt_Sapper", "Grunt_FlameRat", },
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
                EM.AssaultWeather("BlackFog", 150000, 25000),

                -- Spawn through the encounter
                EM.ReaperDrop(10000, { spawns = { reapers=4 }, spawnInterval=20000 }),
                EM.ReaperDrop(20000, { spawns = { reapers=4 }, spawnInterval=20000, spawnRadius=2000, minSpawnRadius=1000 }),
                EM.OrderDrop(5000, { spawns = { guards=20 }, spawnInterval=3000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(6000, { spawns = { medics=9 }, spawnInterval=7000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(7000, { spawns = { captains=8 }, spawnInterval=8000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(8000, { spawns = { breachers=6 }, spawnInterval=10000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(3000, { spawns = { interfectors=7 }, dilationStart = 1, spawnInterval=10000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.RatDrop(20000, { spawns = { sappers=3 }, spawnInterval=20000 }),
                
                EM.ReaperDrop(10000, { spawns = { reapers=2 } }),
                EM.RatDrop(12000, { spawns = { flameRats=2 } })
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
            StoryMin = 80, StoryMax = 100,
            StartMessage = "A witch hunt!",
            Wave1     = { "Gatekeeper_Witch", "Gatekeeper_Witch", "Gatekeeper_Witch", },
            Wave1Time = 2,
            Wave2     = { "Gatekeeper_Witch", },
            Wave2Time = 10,
            Wave3     = { "Pillager_Farmer", "Pillager_Musketeer", "Pillager_Torchbearer", "Pillager_Woodsman", "Pillager_Preacher",
                          "Pillager_Farmer", "Pillager_Musketeer", "Pillager_Torchbearer", "Pillager_Woodsman", "Pillager_Preacher",
                          "Pillager_Farmer", "Pillager_Musketeer", "Pillager_Torchbearer", "Pillager_Woodsman", "Pillager_Preacher", },
            Wave3Time = 2,
            BossWave  = { "Pillager_Preacher", "Pillager_Preacher", "Gatekeeper_Witch", },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.AssaultWeather("BlackFog", 33000, 17000),
                EM.GatekeeperDrop(1000, { spawns = { witches=2 }, })
            )
        },
        {
            Name = "salemmob - POSTEND xGKs",
            StoryMin = 102, StoryMax = 999,
            StartMessage = "A witch hunt!",
            Wave1     = { "Pillager_Farmer", "Pillager_Musketeer", "Pillager_Torchbearer", "Pillager_Woodsman", "Pillager_Preacher",
                          "Pillager_Farmer", "Pillager_Musketeer", "Pillager_Torchbearer", "Pillager_Woodsman", "Pillager_Preacher",
                          "Pillager_Farmer", "Pillager_Musketeer", "Pillager_Torchbearer", "Pillager_Woodsman", "Pillager_Preacher", },
            Wave1Time = 1,
            Wave2     = { "Gatekeeper_Mage", },
            Wave2Time = 10,
            Wave3     = { "Pillager_Farmer", "Pillager_Musketeer", "Pillager_Torchbearer", "Pillager_Woodsman", "Pillager_Preacher",
                          "Pillager_Farmer", "Pillager_Musketeer", "Pillager_Torchbearer", "Pillager_Woodsman", "Pillager_Preacher",
                          "Pillager_Farmer", "Pillager_Musketeer", "Pillager_Torchbearer", "Pillager_Woodsman", "Pillager_Preacher", 
                          "Pillager_Preacher", "Pillager_Preacher", "Pillager_Preacher", "Pillager_Preacher", "Pillager_Preacher", },
            Wave3Time = 1,
            BossWave  = { "Gatekeeper_Mage", "DarkLens_Witch", "DarkLens_Witch", "DarkLens_Witch",  
                          "Pillager_Torchbearer", "Pillager_Torchbearer", "Pillager_Preacher", },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.AssaultWeather("BlackFog", 180000, 15000),
                EM.GatekeeperDrop(1000, { spawns = { witches=2 } }),
                EM.GatekeeperDrop(20000, { spawns = { witches=3 } }),
                EM.GatekeeperDrop(55000, { spawns = { witches=4 } }),
                EM.GatekeeperDrop(90000, { spawns = { witches=5 } })
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
            StoryMin = 90, StoryMax = 100,
            WarningMessage   = "A stillness fills the air...",
            StartMessage = "An unseen war rages!",
            Wave1     = { "Assassin", "Assassin", "Assassin", "Assassin", "Assassin",
                          "Assassin", "Assassin", "Assassin", "Assassin", "Assassin",
                          "Assassin", "Assassin", "Assassin", "Assassin", "Assassin",  },
            Wave1Time = 1,
            Wave2     = { "Assassin" },
            Wave2Time = 15,
            Wave3     = {  "Interfector", "Interfector", "Interfector", "Interfector", "Interfector",
                           "Interfector", "Interfector", "Interfector",  },
            Wave3Time = 2,
            BossWave  = { "Reaper", },
            BossWaveTime = 7,
            OnStart = EM.Sequence(
                EM.AssaultWeather("BlackFog", 20000, 21000),
                EM.PowerLeechBossDrop(5000, { powerLeeches=1 }),
                EM.OrderDrop(5000, { spawns = { interfectors=1 }, dilationStart = 1, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.CrystalliskDrop(5000, { spawns = { crystallisks=1 }}),
                EM.OrderDrop(10000, { spawns = { interfectors=2 }, dilationStart = 1, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.CrystalliskDrop(15000, { spawns = { crystallisks=4 }}),
                EM.OrderDrop(20000, { spawns = { interfectors=3 }, dilationStart = 1, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.CrystalliskDrop(25000, { spawns = { crystallisks=6 }}),
                EM.CrystalliskDrop(60000, { spawns = { crystallisks=10 }}),
                EM.OrderDrop(65000, { spawns = { interfectors=3 }, dilationStart = 1, spawnRadius=3000, minSpawnRadius=1500 })
            ),
        },
        {
            Name = "assassin - POSTEND",
            StoryMin = 102, StoryMax = 999,
            WarningMessage   = "A stillness fills the air...",
            StartMessage = "An unseen war rages!",
            Wave1     = { "Assassin", "Assassin", "Assassin", "Assassin", "Assassin",
                          "Assassin", "Assassin", "Assassin", "Assassin", "Assassin",
                          "Assassin", "Assassin", "Assassin", "Assassin", "Assassin",  },
            Wave1Time = 1,
            Wave2     = { "Assassin" },
            Wave2Time = 15,
            Wave3     = {  "Interfector", "Interfector", "Interfector", "Interfector", "Interfector",
                           "Interfector", "Interfector", "Interfector", "Interfector", "Interfector",  },
            Wave3Time = 2,
            BossWave  = { "Reaper", "Reaper", "Reaper",},
            BossWaveTime = 7,
            OnStart = EM.Sequence(
                EM.AssaultWeather("BlackFog", 60000, 21000),
                EM.PowerLeechBossDrop(5000, { powerLeeches=2 }),
                EM.OrderDrop(5000, { spawns = { interfectors=2 }, dilationStart = 1, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.CrystalliskDrop(5000, { spawns = { crystallisks=3 }}),
                EM.OrderDrop(10000, { spawns = { interfectors=2 }, dilationStart = 1, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.CrystalliskDrop(15000, { spawns = { crystallisks=4 }}),
                EM.OrderDrop(20000, { spawns = { interfectors=3 }, dilationStart = 1, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.CrystalliskDrop(25000, { spawns = { crystallisks=6 }}),
                EM.CrystalliskDrop(60000, { spawns = { crystallisks=10 }}),
                EM.OrderDrop(65000, { spawns = { interfectors=3 }, dilationStart = 1, spawnRadius=3000, minSpawnRadius=1500 })
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
            StoryMin = 50, StoryMax = 70,
            Wave1     = { "WinterSprite", "WinterSprite", "WinterSprite", "WinterSprite", "WinterSprite", "WinterSprite_Bomb", },
            Wave1Time = 1,
            Wave2     = { "WinterSprite", },
            Wave2Time = 15,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_BOSS", },
            BossWaveTime = 2,
        },
        {
            Name = "lamogifrenzy - LATE",
            StoryMin = 70, StoryMax = 90,
            Wave1     = { "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb",
                          "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb", },
            Wave1Time = 1,
            Wave2     = { "WinterSprite_Bomb", },
            Wave2Time = 15,
            Wave3     = { },
            Wave3Time = 1,
            BossWave  = { "WinterSprite", "WinterSprite", "WinterSprite", "WinterSprite", "WinterSprite",  },
            BossWaveTime = 2,
            OnStart = EM.GiantDrop(5000, { spawns = { snowmen=1 } }),
        },
        {
            Name = "lamogifrenzy - END",
            StoryMin = 90, StoryMax = 100,
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
                EM.GiantDrop(5000, { spawns = { yetis=1 } }),
                EM.GiantDrop(25000, { spawns = { yetis=1 } }),
                EM.GiantDrop(45000, { spawns = { snowmen=1 } })
            )
        },
        {
            Name = "lamogifrenzy - POSTEND SNOWMAN",
            StoryMin = 102, StoryMax = 999,
            WarningMessage = "A cold front from the north...",
            StartMessage = "The snowpocalypse!",
            Wave1     = { "Pest_Snow", "Pest_Snow", "Peccary_Snow", "Peccary_Snow", "Peccary_Snow",
                          "Pest_Snow", "Peccary_Snow", "Peccary_Snow", "Peccary_Snow", "Pest_Snow",
                          "Peccary_Snow", "Peccary_Snow", "Peccary_Snow", "Peccary_Snow", "Peccary_Snow",  },
            Wave1Time = 2,
            Wave2     = { "Peccary_Snow", },
            Wave2Time = 5,
            Wave3     = { "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb", "WinterSprite_Bomb",
                          "WinterSprite", "WinterSprite", "WinterSprite", "WinterSprite", "WinterSprite", },
            Wave3Time = 2,
            BossWave  = { "Groupe_Shotgun", "Groupe_Rook", "Groupe_Shotgun", "Groupe_Rook", "Groupe_Grunt",
                          "Groupe_Grunt", "Groupe_Shotgun", "Groupe_Shotgun", "Groupe_Grunt", "Groupe_Grunt",  },
            BossWaveTime = 3,
            OnStart = EM.Sequence(
                EM.AssaultWeather("ColdSnap", 75000, 1000),

                -- Spawn throughout the encounter
                EM.PestDrop(4000, { spawns={ winters=10 }, spawnInterval=3000 }),
                EM.PeccaryDrop(10000, { spawns={ winters=4 }, spawnInterval=10000 }),
                
                EM.GiantDrop(5000, { spawns = { snowmen=1 } }),
                EM.GiantDrop(25000, { spawns = { yetis=1 } }),
                EM.GiantDrop(50000, { spawns = { yetis=1, snowmen=1 } })
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

        -- **NOTE: This assault may overstress your PC or server**
        {
            Name = "zombiewave - MAX CHAOS",
            StoryMin = 102, StoryMax = 999,
            StartMessage     = "Full containment breach!",
            Wave1     = { "Robot_Containment", "Robot_Containment", "Robot_Containment", 
                          "Robot_Containment", "Robot_Containment", },
            Wave1Time = 5,
            Wave2     = { "Robot_Defense", "Robot_Defense", },
            Wave2Time = 30,
            Wave3     = { "Groupe_Shotgun", "Groupe_Shotgun", "Groupe_Shotgun", "Groupe_Rook", 
                          "Groupe_Rook", "Groupe_Grunt", "Groupe_Grunt", "Groupe_Grunt", 
                          "Trooper", "Trooper", "Trooper", "Trooper", 
                          "Trooper_Shotgun", "Trooper_Shotgun", "Trooper_Shotgun", "Trooper_Shotgun", 
                          "Trooper_Shotgun", "Trooper_Shield", "Trooper_Shield", 
                          "Trooper", "Trooper", "Trooper", "Trooper", 
                          "Grunt_Sapper", "Grunt_FlameRat",
                          "Interfector", "Interfector", "Interfector",},
            Wave3Time = 2,
            BossWave  = { "Grunt_Sapper", "Robot_Defense", "DarkLens_Chieftain", "Robot_Corrupt", "Robot_Corrupt", 
                          "DarkLens_Witch", "DarkLens_Heavy", "Grunt_FlameRat" },
            BossWaveTime = 15,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Blackout", 50000, 15000),
                EM.AssaultWeather("Fog", 70000, 70000),
                EM.AssaultWeather("Spores", 190000, 150000),

                -- Spawn throughout the encounter

                EM.PestDrop(8000, { spawns={ electros=2, volatiles=5 }, spawnInterval=15000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.PestDrop(9000, { spawns={ rats=2, magmas=3, winters=2 }, spawnInterval=15000, spawnRadius=3000, minSpawnRadius=1500 }),

                EM.PeccaryDrop(21000, { spawns={ sows=6 }, spawnInterval=8000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.PeccaryDrop(35000, { spawns={ mushrooms=2, alphas=2, winters=2 }, spawnInterval=10000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.PeccaryDrop(46000, { spawns={ electros=2, armored=2, volatiles=2 }, spawnInterval=10000, spawnRadius=3000, minSpawnRadius=1500 }),
                
                EM.ExorDrop(20000, { spawns={ monks=2, exors=4, armoreds=2 }, spawnInterval=15000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.ExorDrop(36000, { spawns={ monks=2, exors=5, armoreds=1 }, spawnInterval=15000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.ExorDrop(71000, { spawns={ pikemen=3, volatiles=2 }, spawnInterval=15000, spawnRadius=2000, minSpawnRadius=1000 }),

                EM.OrderDrop(12000, { spawns={ guards=6 }, spawnInterval=12000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(13000, { spawns={ grunts=8 }, spawnInterval=12000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(14000, { spawns={ medics=6 }, spawnInterval=15000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(15000, { spawns={ captains=6 }, spawnInterval=12000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(16000, { spawns={ breachers=6 }, spawnInterval=15000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.OrderDrop(35000, { spawns={ interfectors=4 }, spawnInterval=20000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.RatDrop(32000, { spawns={ garageRats=2, sappers=2, flameRats=2 }, spawnInterval=11000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.SkinkDrop(44000, { spawns= { skinks=3, magmaskinks=3 }, spawnInterval=7000, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.SymphonistDrop(51000, { spawns= { symphonists=5 }, spawnInterval=10000, spawnRadius=3000, minSpawnRadius=1500 }),

                -- Burst drops
                EM.PestDrop(5000, { spawns={ pests=4, carbonateds=2, electros=2 }, spawnInterval=1500, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.PeccaryDrop(10000, { spawns={ peccaries=2, sows=2 }, spawnInterval=1500, spawnRadius=3000, minSpawnRadius=1500 }),
                EM.ExorDrop(125000, { spawns={ armoreds=2, volatiles=2 }, spawnInterval=1500, spawnRadius=3000, minSpawnRadius=1500 }),
                
                EM.RatDrop(45000, { spawns={ labRats=3, garageRats=5 }, spawnInterval=2000, spawnRadius=3000, minSpawnRadius=1500 }),

                
                EM.GatekeeperDrop(30000, { spawns={ phyters=3, chieftains=1 }, spawnInterval=2000, spawnRadius=1000 }),
                EM.GatekeeperDrop(60000, { spawns={ witches=3, mages=1, }, spawnInterval=4000, spawnRadius=1000 }),
                EM.GatekeeperDrop(90000, { spawns={ heavies=2, }, spawnInterval=4000, spawnRadius=1000 }),
                EM.GatekeeperDrop(120000, { spawns={ phyters=2, chieftains=1, mages=1 }, spawnInterval=1500, spawnRadius=1000 }),
                EM.GatekeeperDrop(150000, { spawns={ witches=2, chieftains=1, heavies=1 }, spawnInterval=1500, spawnRadius=1000 }),


                EM.OrderDrop(160000, { spawns={ guards=2, grunts=2, captains=3, breachers=2 }, spawnInterval=1000, spawnRadius=3000, minSpawnRadius=1500 }),

                EM.GiantDrop(3000, { spawns={ yetis=1, }, spawnRadius=2000, minSpawnRadius=1000 }),
                EM.GiantDrop(38000, { spawns={ bigfoots=1 }, spawnRadius=2000, minSpawnRadius=1000 }),
                EM.GiantDrop(80000, { spawns={ snowmen=1 }, spawnRadius=2000, minSpawnRadius=1000 }),
                EM.GiantDrop(140000, { spawns={ tarasques=1 }, spawnRadius=2000, minSpawnRadius=1000 }),
                EM.GiantDrop(220000, { spawns={ behemoths=1 }, spawnRadius=2000, minSpawnRadius=1000 }),

                EM.PestDrop(125000, { spawns={ leyaks=4 }, spawnInterval=4000, spawnRadius=1500 }),
                EM.PestDrop(155000, { spawns={ rats=2, magmas=2, enlighteneds=3 }, spawnInterval=5000, spawnRadius=1500 }),
                
                EM.CrystalliskDrop(15000,  { spawns= { crystallisks=4 }, spawnInterval=1000} ),
                EM.CrystalliskDrop(170000, { spawns= { crystallisks=4 }, spawnInterval=1000} )
            )
        },
        -- Assaults used for testing
        {
            Name = "[TEST] ReaperPortal",
            StoryMin = 999, StoryMax = 999,
            StartMessage     = "Fear the reaper...",
            Wave1     = { "DarkLens_Witch", "DarkLens_Witch" },
            Wave1Time = 45,
            Wave2     = { },
            Wave2Time = 2,
            Wave3     = { },
            Wave3Time = 2,
            BossWave  = { "DarkLens_Witch" },
            BossWaveTime = 60,
            OnStart = EM.Sequence(
                EM.AssaultWeather("BlackFog", 130000, 17000),
                EM.ReaperPortalDrop(5000, { spawns={ reapers=3 }, firstSpawnInterval=5000, spawnInterval=30000, spawnRadius=1500, minSpawnRadius=500 }),
                EM.ReaperPortalDrop(40000, { spawns={ reapers=2 }, firstSpawnInterval=5000, spawnInterval=30000, spawnRadius=1500, minSpawnRadius=500 }),
                EM.ReaperPortalDrop(75000, { spawns={ reapers=1 }, spawnInterval=5000, spawnRadius=1500, minSpawnRadius=500 })
            )
        },
    },
   
    -- Maybe split chaotic assaults here for a higher chance
    -- assault_pestfrenzy_volatile: Pest_Volatilex7 | boss: Exor_Volatile | "A frenzy!" | 4/4/4/10 | Reactors_S3Overgrowth_Complete
    assault_pestfrenzy_volatile = { },
}

return ASSAULTS