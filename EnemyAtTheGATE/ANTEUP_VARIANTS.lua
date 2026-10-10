-- ===================================================================================
-- ANTEUP_VARIANTS - таблица для примешивания вариантов AnteUp в штурмы
--
-- Читается Managers/Variety.lua, работает при CONFIG.VARIANT_INFUSION.Enabled
-- и запущенном AnteUp с MOD_COMPATIBILITY.ENEMY_AT_THE_GATE = true.
--
-- Infusion = { [базовая строка] = { { "Вариант", этап }, ... } }
--   * Обычный слот волны с этой базой может стать одним из перечисленных вариантов
--   * этап - минимальный StoryProgress. Взят из самой ранней зоны, где AnteUp
--       ставит этот вариант в мир (AnteData/SpawnerData + PlacedSpawnData)
--       Offices=10, Manufacturing=20, Labs=30, Security=40, Hydro=50,
--       PowerSrv=60, Reactors=70, Praetorium=80, Residence=90
--   * "Вариант@Строка" - вариант на чужом теле (вариант принимает эту строку
--       как AltBase), например Velites Guard на теле Grunt_Guard
--   * Вариант, которого нет в карте AnteUp, молча пропускается
--
-- Elite = { [базовая строка] = { "Вариант", этап } }
--   * Модификатор "элитная волна" ставит в волну одного такого врага
--   * Это те же подмены, что AnteUp делает в спавнерах при HARDMODE.NoMercy
--       (AnteData/SpawnerData.lua, SD.HardVariants)
--   * Для базы без строки здесь берётся самый поздний вариант из Infusion
--
-- Не включены специально: варианты событий ("Event ..."), тени ("... Shade"),
--   боссы (Fallow, Tarasque, Pestilence, Leyak Menace, Blizzard Yeti, Orchestrator),
--   питомцы и варианты без места в мире - их место в пуле боссов
--   или в отдельных записях ASSAULTS_CUSTOM.
-- ===================================================================================

return {

    Infusion = {

        -- -----------------------------------------------------------------
        -- Pests
        -- -----------------------------------------------------------------
        Pest             = { { "Razor Pest", 10 }, { "Antegrav Pest", 10 }, { "Anterazor Pest", 30 } },
        Pest_Carbonated  = { { "Chonky Pest", 10 } },
        Pest_Electro     = { { "Laser Pest", 30 }, { "Telepest", 30 } },
        Pest_Volatile    = { { "Signal Pest", 10 }, { "Chonky Signal Pest", 30 }, { "Antesignal Pest", 50 },
                             { "Antevolatile Pest", 70 }, { "Volatile Pest", 70 } },
        Pest_Magma       = { { "Magma Pest", 30 } },
        Pest_Leyak       = { { "Leyak Pest", 30 } },
        Pest_Enlightened = { { "Enlightened Pest", 60 } },
        Pest_Snow        = { { "Flurry Pest", 83 } },

        -- -----------------------------------------------------------------
        -- Peccaries
        -- -----------------------------------------------------------------
        Peccary          = { { "Charge Peccary", 10 }, { "Phase Peccary", 10 }, { "Carbunccary", 10 } },
        Peccary_Armored  = { { "Armored Peccary", 33 } },
        Peccary_Electro  = { { "Electro Peccary", 30 } },
        Peccary_Volatile = { { "Volatile Peccary", 70 } },
        Peccary_Snow     = { { "Whiteout Peccary", 90 } },
        Peccary_Alpha    = { { "Magma Peccary", 30 } },
        Sow              = { { "Hive Sow", 30 } },

        -- -----------------------------------------------------------------
        -- Exor
        -- -----------------------------------------------------------------
        Exor_Monk        = { { "Exorrior", 10 }, { "Exor Magus", 10 }, { "Exorrior Magus", 30 },
                             { "Exor Shadow Monk", 50 } },
        Exor             = { { "Antegrav Exor", 10 }, { "Antefire Exor", 10 }, { "Magma Exor", 10 },
                             { "Exor Superior", 70 } },
        Exor_Armored     = { { "Exor Repeller", 50 }, { "Exor Displacer", 50 }, { "Exor Dislocator", 60 },
                             { "Winter Exor", 90 } },
        Exor_Pikeman     = { { "Exor Spiritwalker", 10 } },
        Exor_Volatile    = { { "Acidic Exor", 70 }, { "Exor Hunter", 70 } },

        -- -----------------------------------------------------------------
        -- The Order
        -- -----------------------------------------------------------------
        Grunt            = { { "Suppressor Grunt", 20 }, { "Grenadier Guard", 20 } },
        Grunt_Guard      = { { "Velites Guard@Grunt_Guard", 20 }, { "Grenadier Guard@Grunt_Guard", 20 },
                             { "Suppressor Grunt@Grunt_Guard", 20 } },
        Grunt_Captain    = { { "Commander", 20 }, { "Trident", 20 }, { "Signifer", 70 } },
        Grunt_Medic      = { { "Dioscoridian", 20 } },
        Grunt_Shotgun    = { { "Skirmisher", 30 }, { "Sweeper", 30 } },
        Grunt_Sniper     = { { "Tracker Sniper", 20 }, { "Twilight Sniper", 20 }, { "Tracer Sniper", 50 },
                             { "Groupe Sniper", 50 } },
        Grunt_LabRat     = { { "Flask Rat", 20 } },
        Grunt_Sapper     = { { "Rocket Rat", 50 }, { "Mad Rat", 70 }, { "Super Sapper", 70 } },
        Grunt_FlameRat   = { { "Purifier", 80 } },
        Trooper          = { { "Centurion Grunt", 20 }, { "Speculatores", 80 } },
        Trooper_Shield   = { { "Shield Grunt", 30 }, { "Shield Embolon", 80 } },
        Interfector      = { { "Winterfector", 90 }, { "Peremptor", 91 } },

        -- Groupe
        Groupe_Grunt     = { { "Groupe Frostpack", 50 } },
        Groupe_Rook      = { { "Groupe Rookram", 50 } },
        Groupe_Shotgun   = { { "Groupe Breacher", 50 } },

        -- -----------------------------------------------------------------
        -- Crystallisks, robots
        -- -----------------------------------------------------------------
        Assassin          = { { "Gravilisk", 20 }, { "Obsidilisk", 20 } },
        Robot_Security    = { { "Office Bot", 10 }, { "Cafeteria Bot", 10 }, { "Hospitality Bot", 10 },
                              { "Advanced Hospitality Bot", 30 } },
        Robot_Containment = { { "Constrictor Bot", 30 } },
        Robot_Defense     = { { "Deatomizer Bot", 50 }, { "Artillery Bot", 50 } },

        -- -----------------------------------------------------------------
        -- Gatekeepers
        -- -----------------------------------------------------------------
        Gatekeeper_Phyter    = { { "Neophyte Trainer", 70 }, { "Neophyte Tamer", 90 } },
        Gatekeeper_Witch     = { { "Storm Witch", 70 }, { "Plague Witch", 70 }, { "Warrior Witch", 70 } },
        Gatekeeper_Mage      = { { "Barrier Mage", 70 }, { "Abjurer Mage", 70 } },
        Gatekeeper_Heavy     = { { "Jotun Rocketeer", 70 } },
        Gatekeeper_Chieftain = { { "Esoteric Chieftain", 70 }, { "Gatekeeper Warchief", 90 } },

        -- -----------------------------------------------------------------
        -- Canaan
        -- -----------------------------------------------------------------
        Pillager_Farmer      = { { "Canaan Farmer", 40 }, { "Chosen Canaan Farmer", 40 } },
        Pillager_Musketeer   = { { "Canaan Marksman", 40 } },
        Pillager_Torchbearer = { { "Canaan Fanatic", 40 }, { "Chosen Canaan Fanatic", 40 } },
        Pillager_Woodsman    = { { "Canaan Lumberjack", 40 }, { "Chosen Canaan Miner", 40 }, { "Outcast", 40 } },
    },

    Elite = {
        Exor                 = { "Exor Superior", 70 },
        Exor_Monk            = { "Exor Shadow Monk", 50 },
        Grunt_Sapper         = { "Super Sapper", 70 },
        Gatekeeper_Chieftain = { "Gatekeeper Warchief", 90 },
    },
}
