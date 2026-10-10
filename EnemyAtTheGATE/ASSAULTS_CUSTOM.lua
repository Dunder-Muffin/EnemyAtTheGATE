-- ===========================================================================================
-- ASSAULTS_CUSTOM - добавка к ASSAULTS_HARD при DIFFICULTY = "HardCustom"
--
-- Записи дописываются в конец списков тех же строк ASSAULTS_HARD и выпадают
-- наравне с ними. Формат записи тот же, см. шапку ASSAULTS_HARD.lua.
--
-- Что здесь лежит:
--   1. Темы для отрезка Hydro - Reactors, StoryProgress 50-80
--   2. Строки, которые в Hard не давали штурмов: электрический шторм
--        после Labs и обе volatile-строки
--   3. ПУЛ БОССОВ - записи с Pool = "boss". В обычный выбор не попадают,
--        выпадают с шансом CONFIG.BOSS_ASSAULTS.Chance после финала игры
--
-- Имена с пробелом - варианты AnteUp. Без AnteUp такой слот станет
-- обычным базовым NPC, если GATE хоть раз видел карту вариантов
-- (AnteUp_VariantCache.txt), иначе не появится никто.
--
-- EM.VariantDrop - десант, где можно называть варианты, включая гигантов.
--   Требует обновлённый ModuleGATE/GateBridge.lua в AnteUp.
-- ===========================================================================================

local EM = require("Managers.EventManager")

local ASSAULTS = {

    -- ========================================================
    -- 1. HYDRO - REACTORS (50-80)
    -- ========================================================

    -- Groupe в стуже: Frostpack, Rookram, Breacher и подкрепление на точке волны
    assault_groupe = {
        {
            Name = "custom groupe - FROST SIEGE",
            StoryMin = 55, StoryMax = 80,
            WarningMessage = "A cold wind blows through...",
            StartMessage   = "The Groupe brings the winter with them!",
            Wave1     = { "Groupe Frostpack", "Groupe_Grunt", "Groupe_Grunt", "Groupe Frostpack" },
            Wave1Time = 3,
            Wave2     = { "Groupe Rookram", "Groupe_Rook", "Groupe_Shotgun" },
            Wave2Time = 5,
            Wave3     = { "Groupe Breacher", "Groupe_Grunt", "Groupe Frostpack", "Groupe_Rook" },
            Wave3Time = 3,
            BossWave  = { "Groupe Rookram", "Groupe Breacher", "Groupe Frostpack" },
            BossWaveTime = 12,
            OnStart = EM.Sequence(
                EM.AssaultWeather("ColdSnap", 150000, 10000),
                EM.GroupeDrop(40000, { spawns = { grunts = 2, rooks = 1 }, spawnAtWavePoint = true })
            ),
        },
    },

    -- Крысы-подрывники: ракеты и колбы, к Reactors - Mad Rat и Super Sapper
    assault_ratpatrol = {
        {
            Name = "custom ratpatrol - SAPPER SIEGE",
            StoryMin = 50, StoryMax = 69,
            StartMessage = "Something's ticking near the walls...",
            Wave1     = { "Flask Rat", "Grunt_LabRat", "Grunt_LabRat", "Flask Rat" },
            Wave1Time = 2,
            Wave2     = { "Rocket Rat", "Grunt_Sapper", "Grunt_LabRat_Mechanic" },
            Wave2Time = 6,
            Wave3     = { "Grunt_Sapper", "Rocket Rat", "Flask Rat", "Grunt_LabRat" },
            Wave3Time = 3,
            BossWave  = { "Rocket Rat", "Rocket Rat", "Grunt_Captain" },
            BossWaveTime = 12,
            OnStart = EM.RatDrop(30000, { spawns = { labRats = 2, sappers = 1 } }),
        },
        {
            Name = "custom ratpatrol - DEMOLITION CREW",
            StoryMin = 70, StoryMax = 101,
            StartMessage = "The lights die. Then the fuses start hissing.",
            Wave1     = { "Flask Rat", "Rocket Rat", "Grunt_LabRat", "Flask Rat" },
            Wave1Time = 2,
            Wave2     = { "Mad Rat", "Grunt_Sapper", "Rocket Rat" },
            Wave2Time = 6,
            Wave3     = { "Super Sapper", "Grunt_LabRat_Mechanic", "Mad Rat", "Grunt_Medic" },
            Wave3Time = 4,
            BossWave  = { "Super Sapper", "Mad Rat", "Signifer" },
            BossWaveTime = 12,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Blackout", 60000, 40000),
                EM.RatDrop(35000, { spawns = { sappers = 2, garageRats = 1 } })
            ),
        },
    },

    -- Канаан идёт на базу, Экзоры высаживаются им в спину
    assault_salemmob = {
        {
            Name = "custom salemmob - HOLY WAR",
            StoryMin = 50, StoryMax = 80,
            StartMessage = "Torches in the fog - and something answers them.",
            Wave1     = { "Canaan Farmer", "Pillager_Farmer", "Canaan Fanatic", "Pillager_Torchbearer" },
            Wave1Time = 3,
            Wave2     = { "Canaan Marksman", "Pillager_Musketeer", "Chosen Canaan Farmer" },
            Wave2Time = 5,
            Wave3     = { "Canaan Lumberjack", "Chosen Canaan Fanatic", "Pillager_Torchbearer", "Canaan Fanatic" },
            Wave3Time = 3,
            BossWave  = { "Chosen Canaan Miner", "Pillager_Preacher", "Pillager_Woodsman" },
            BossWaveTime = 12,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Fog", 150000, 10000),
                EM.ExorDrop(25000, {
                    spawns = { monks = 2, exors = 1, armoreds = 1 },
                    spawnAtWavePoint = true,
                    favoredEnemy     = "Canaan",
                })
            ),
        },
    },

    -- Экзоры, которые отталкивают и смещают: Repeller, Displacer, Shadow Monk
    assault_exorsquad = {
        {
            Name = "custom exorsquad - DISPLACEMENT",
            StoryMin = 52, StoryMax = 75,
            StartMessage = "The air bends around them.",
            Wave1     = { "Exor_Monk", "Exorrior", "Exor Magus", "Exor_Monk" },
            Wave1Time = 3,
            Wave2     = { "Exor Repeller", "Exor_Armored", "Exor Displacer" },
            Wave2Time = 6,
            Wave3     = { "Exor Shadow Monk", "Exorrior Magus", "Exor", "Antegrav Exor" },
            Wave3Time = 3,
            BossWave  = { "Exor Displacer", "Exor Shadow Monk", "Magma Exor" },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Spores", 120000, 15000),
                EM.PeccaryDrop(35000, { spawns = { peccaries = 2, armoreds = 1 } })
            ),
        },
    },

    -- Центурионы Ордена, Экзоры бьют по ним с точки волны
    assault_soldierpatrol = {
        {
            Name = "custom soldierpatrol - CENTURIONS",
            StoryMin = 50, StoryMax = 70,
            StartMessage = "Heavy boots on the stairs...",
            Wave1     = { "Centurion Grunt", "Velites Guard@Grunt_Guard", "Grenadier Guard", "Dioscoridian" },
            Wave1Time = 2,
            Wave2     = { "Suppressor Grunt", "Grunt", "Commander" },
            Wave2Time = 4,
            Wave3     = { "Skirmisher", "Grunt_Medic", "Sweeper", "Grunt_Guard" },
            Wave3Time = 3,
            BossWave  = { "Trident", "Centurion Grunt" },
            BossWaveTime = 10,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Fog", 120000, 15000),
                EM.ExorDrop(20000, {
                    spawns = { monks = 2, armoreds = 1 },
                    spawnAtWavePoint = true,
                    favoredEnemy     = "Order",
                })
            ),
        },
    },

    -- Электрическое безумие: Laser Pest, Telepest и Electro Peccary
    assault_pestfrenzy_electro = {
        {
            Name = "custom pestfrenzy_electro - STATIC",
            StoryMin = 50, StoryMax = 70,
            StartMessage = "The hair on your arms stands up.",
            Wave1     = { "Laser Pest", "Pest_Electro", "Telepest", "Pest_Electro", "Laser Pest" },
            Wave1Time = 2,
            Wave2     = { "Electro Peccary", "Pest_Electro", "Telepest" },
            Wave2Time = 4,
            Wave3     = { "Pest_Electro", "Laser Pest", "Peccary_Electro" },
            Wave3Time = 3,
            BossWave  = { "Hive Sow", "Electro Peccary", "Telepest" },
            BossWaveTime = 10,
            OnStart = EM.PestDrop(20000, { spawns = { electros = 4 }, spawnInterval = 1500 }),
        },
    },


    -- ========================================================
    -- 2. СТРОКИ, КОТОРЫЕ В HARD НЕ ДАВАЛИ ШТУРМОВ
    -- * Это строки портальных штормов. С StoryProgress 32 GATE переводит
    --     их в наземный спавн (CONFIG.SUPPRESS_PORTAL_STORMS)
    -- ========================================================

    -- В Hard есть только запись 30-35. Эта продолжает строку до Reactors
    assault_peststorm_electro = {
        {
            Name = "custom peststorm_electro - CONDUCTOR",
            StoryMin = 35, StoryMax = 70,
            StartMessage = "A thunderous portal storm has started!",
            Wave1     = { "Pest_Electro", "Laser Pest", "Pest_Electro", "Telepest", "Pest_Electro" },
            Wave1Time = 1,
            Wave2     = { "Sow", "Electro Peccary", "Pest_Electro" },
            Wave2Time = 4,
            Wave3     = { "Telepest", "Laser Pest", "Sow" },
            Wave3Time = 6,
            BossWave  = { "Hive Sow", "Electro Peccary", "Electro Peccary" },
            BossWaveTime = 8,
        },
    },

    -- Строки volatile открываются игрой после Reactors_S3Overgrowth_Complete (73)
    assault_peststorm_volatile = {
        {
            Name = "custom peststorm_volatile - PESTILENT STORM",
            StoryMin = 73, StoryMax = 999,
            StartMessage = "The storm smells of rot.",
            Wave1     = { "Pest_Volatile", "Signal Pest", "Pest_Volatile", "Antevolatile Pest", "Pest_Volatile" },
            Wave1Time = 1,
            Wave2     = { "Volatile Peccary", "Peccary_Volatile", "Volatile Pest" },
            Wave2Time = 4,
            Wave3     = { "Exor_Volatile", "Acidic Exor", "Pest_Volatile", "Pest_Volatile" },
            Wave3Time = 3,
            BossWave  = { "Pestilence", "Exor Hunter" },
            BossWaveTime = 10,
            OnStart = EM.AssaultWeather("RadLeak", 120000, 15000),
        },
    },

    assault_pestfrenzy_volatile = {
        {
            Name = "custom pestfrenzy_volatile - ACID RAIN",
            StoryMin = 73, StoryMax = 999,
            StartMessage = "A frenzy! Mind the puddles.",
            Wave1     = { "Antevolatile Pest", "Pest_Volatile", "Antevolatile Pest", "Pest_Volatile",
                          "Antevolatile Pest", "Pest_Volatile" },
            Wave1Time = 1,
            Wave2     = { "Volatile Peccary", "Pest_Volatile", "Volatile Pest" },
            Wave2Time = 3,
            Wave3     = { "Antesignal Pest", "Pest_Volatile", "Pest_Volatile", "Antevolatile Pest" },
            Wave3Time = 2,
            BossWave  = { "Exor_Volatile", "Acidic Exor", "Acidic Exor" },
            BossWaveTime = 8,
            OnStart = EM.AssaultWeather("Spores", 120000, 15000),
        },
    },


    -- ========================================================
    -- 3. ПУЛ БОССОВ (Pool = "boss", StoryMin = 102)
    --
    -- * Строка, под которой лежит запись, для пула роли не играет: штурм
    --     идёт в строке, выбранной игрой. Записи разложены по строкам
    --     для порядка в /gate list
    -- * Примешивание и модификаторы эти записи не трогают
    -- * Гиганты-варианты идут через EM.VariantDrop: в волне директора
    --     гигант плохо находит путь
    -- ========================================================

    assault_corruptbot = {
        -- Пиявка-босс при отключённом питании и отряд подрывников
        {
            Name = "BOSS - POWER LEECH",
            Pool = "boss",
            StoryMin = 102, StoryMax = 999,
            WarningMessage = "The generators groan...",
            StartMessage   = "Something is feeding on the grid!",
            Wave1     = { "Rocket Rat", "Grunt_Sapper", "Flask Rat", "Mad Rat" },
            Wave1Time = 3,
            Wave2     = { "Super Sapper", "Signifer", "Grunt_LabRat_Mechanic" },
            Wave2Time = 8,
            Wave3     = { "Mad Rat", "Rocket Rat", "Super Sapper", "Purifier" },
            Wave3Time = 4,
            BossWave  = { "Signifer", "Super Sapper" },
            BossWaveTime = 15,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Blackout", 150000, 15000),
                EM.PowerLeechBossDrop(5000, { spawns = { powerLeeches = 1 } }),
                EM.PowerLeechBossDrop(90000, { spawns = { powerLeeches = 1 } })
            ),
        },
        -- Два испорченных робота и боевые боты Привратников
        {
            Name = "BOSS - CORRUPTION",
            Pool = "boss",
            StoryMin = 102, StoryMax = 999,
            WarningMessage = "An abnormal presence...",
            StartMessage   = "The machines have been turned.",
            Wave1     = { "Deatomizer Bot", "Gatekeeper_Phyter", "Neophyte Trainer", "Artillery Bot" },
            Wave1Time = 4,
            Wave2     = { "Robot_Corrupt", "Gatekeeper Warchief" },
            Wave2Time = 15,
            Wave3     = { "Artillery Bot", "Deatomizer Bot", "Plague Witch", "Storm Witch" },
            Wave3Time = 4,
            BossWave  = { "Robot_Corrupt", "Esoteric Chieftain" },
            BossWaveTime = 20,
            OnStart = EM.Sequence(
                EM.AssaultWeather("RadLeak", 180000, 15000),
                EM.GatekeeperDrop(60000, { spawns = { phyters = 2, mages = 1 } })
            ),
        },
    },

    assault_gksquad = {
        -- Двор Fallow: Патриарх, Мать и Ётун. Magus of the Fallow в волнах
        -- неуязвим, поэтому его здесь нет
        {
            Name = "BOSS - FALLOW COURT",
            Pool = "boss",
            StoryMin = 102, StoryMax = 999,
            WarningMessage = "The bones are cast.",
            StartMessage   = "The Fallow court has come to collect.",
            Wave1     = { "DarkLens Phyter@DarkLens_Phyter", "DarkLens_Phyter", "Warrior Witch", "Storm Witch" },
            Wave1Time = 4,
            Wave2     = { "Jotun Rocketeer", "Gatekeeper Warchief", "Barrier Mage" },
            Wave2Time = 10,
            Wave3     = { "Plague Witch", "Neophyte Tamer", "DarkLens_Phyter", "Abjurer Mage" },
            Wave3Time = 4,
            BossWave  = { "Fallow Patriarch", "Mother of the Fallow", "Jotun of the Fallow" },
            BossWaveTime = 20,
            OnStart = EM.Sequence(
                EM.AssaultWeather("BlackFog", 20000, 20000),
                EM.AssaultWeather("BlackFog", 30000, 150000)
            ),
        },
    },

    assault_larva = {
        -- Стадо тарасков: Charger, через минуту Slammer, вокруг них volatile-Экзоры
        {
            Name = "BOSS - TARASQUE STAMPEDE",
            Pool = "boss",
            StoryMin = 102, StoryMax = 999,
            WarningMessage = "The ground shakes...",
            StartMessage   = "Stampede!",
            Wave1     = { "Exor_Volatile", "Acidic Exor", "Exor Hunter" },
            Wave1Time = 4,
            Wave2     = { "Exor Superior", "Exor_Armored", "Exor Dislocator" },
            Wave2Time = 8,
            Wave3     = { "Acidic Exor", "Exor Shadow Monk", "Exor Superior", "Volatile Peccary" },
            Wave3Time = 4,
            BossWave  = { "Exor Superior", "Exor Superior" },
            BossWaveTime = 15,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Spores", 180000, 15000),
                EM.VariantDrop(8000,  { spawns = { ["Tarasque Charger"] = 1 } }),
                EM.VariantDrop(70000, { spawns = { ["Tarasque Slammer"] = 1 } })
            ),
        },
    },

    assault_lamogifrenzy = {
        -- Буран: Бигоги, Blizzard Yeti и зимние варианты
        {
            Name = "BOSS - BLIZZARD",
            Pool = "boss",
            StoryMin = 102, StoryMax = 999,
            WarningMessage = "The temperature plummets...",
            StartMessage   = "Whiteout!",
            Wave1     = { "Flurry Pest", "Pest_Snow", "Flurry Pest", "Whiteout Peccary" },
            Wave1Time = 3,
            Wave2     = { "Winter Exor", "Winterfector", "WinterSprite", "WinterSprite" },
            Wave2Time = 6,
            Wave3     = { "Whiteout Peccary", "Groupe Frostpack", "Winterfector", "WinterSprite_Bomb" },
            Wave3Time = 4,
            BossWave  = { "Winter Exor", "Groupe Frostpack", "Groupe Frostpack" },
            BossWaveTime = 12,
            OnStart = EM.Sequence(
                EM.AssaultWeather("ColdSnap", 200000, 10000),
                EM.VariantDrop(15000, { spawns = { ["Blizzard Yeti"] = 1 } }),
                EM.GiantDrop(80000,   { spawns = { bigogi = 1 } })
            ),
        },
    },

    assault_soloassassin = {
        -- Ночная жатва: жнецы из портала и кристаллиски в чёрном тумане
        {
            Name = "BOSS - NIGHT HARVEST",
            Pool = "boss",
            StoryMin = 102, StoryMax = 999,
            WarningMessage = "The night grows teeth...",
            StartMessage   = "The harvest has begun.",
            Wave1     = { "Obsidilisk", "Gravilisk", "Assassin" },
            Wave1Time = 4,
            Wave2     = { "Reaper", "Gravilisk", "Obsidilisk" },
            Wave2Time = 8,
            Wave3     = { "Assassin", "Obsidilisk", "Reaper", "Gravilisk" },
            Wave3Time = 4,
            BossWave  = { "Harvester Reaper", "Reaping Reaper" },
            BossWaveTime = 15,
            OnStart = EM.Sequence(
                EM.AssaultWeather("BlackFog", 200000, 10000),
                EM.ReaperPortalDrop(20000, { spawns = { reapers = 2 } })
            ),
        },
    },

    assault_zombiehorde = {
        -- Мор: Pestilence и Leyak Menace
        {
            Name = "BOSS - PESTILENCE",
            Pool = "boss",
            StoryMin = 102, StoryMax = 999,
            WarningMessage = "A sickly sweet smell...",
            StartMessage   = "Plague walks among them.",
            Wave1     = { "Antevolatile Pest", "Leyak Pest", "Antevolatile Pest", "Pest_Leyak", "Volatile Pest" },
            Wave1Time = 2,
            Wave2     = { "Pestilence", "Volatile Peccary", "Leyak Pest" },
            Wave2Time = 6,
            Wave3     = { "Leyak Menace", "Antesignal Pest", "Acidic Exor", "Antevolatile Pest" },
            Wave3Time = 3,
            BossWave  = { "Pestilence", "Leyak Menace", "Acidic Exor" },
            BossWaveTime = 12,
            OnStart = EM.Sequence(
                EM.AssaultWeather("RadLeak", 180000, 15000),
                EM.PestDrop(40000, { spawns = { volatiles = 4, leyaks = 2 }, spawnInterval = 1500 })
            ),
        },
    },

    assault_monkdad = {
        -- Оркестр в тумане: Orchestrator всех цветов и Симфонисты
        {
            Name = "BOSS - THE ORCHESTRA",
            Pool = "boss",
            StoryMin = 102, StoryMax = 999,
            WarningMessage = "An unnatural fog rolls in...",
            StartMessage   = "The orchestra tunes up.",
            Wave1     = { "Orchestrator Red", "Orchestrator Yellow", "Orchestrator Green" },
            Wave1Time = 5,
            Wave2     = { "Orchestrator Blue", "Orchestrator Red", "Symph" },
            Wave2Time = 4,
            Wave3     = { "Orchestrator Green", "Orchestrator Yellow", "Orchestrator Blue", "Orchestrator Red" },
            Wave3Time = 3,
            BossWave  = { "Orchestrator", "Orchestrator", "Orchestrator Red" },
            BossWaveTime = 12,
            OnStart = EM.Sequence(
                EM.AssaultWeather("Fog", 240000, 5000),
                EM.SymphonistDrop(30000, { spawns = { symphonists = 3 } })
            ),
        },
    },
}

return ASSAULTS
