-- =======================================================================
-- RevengeAssaults - the ROSTER. Definitions only; the calendar/director live in RevengeDirector.lua,
-- the OnStart primitives (RE.*) in RevengeEvents.lua.
--
-- A revenge assault is a NATIVE assault the world owes the player - it rides the AI Director's own
-- warning/prep/bench-targeting/music like an EATG assault; we only decide WHEN and WHAT spawns.
--
-- MUST-KNOWS (full reasoning: AnNotes/Modules/RevengeDirector.md)
--   * `Id` is the save key - renaming re-arms an existing world. Add/remove entries freely.
--   * `Trigger.Flag` is a raw world flag, not StoryProgress (see AnNotes for why). `MinStory`
--     covers triggers with no single flag.
--   * Booking is edge-triggered against a persisted baseline, so installing on a finished save
--     does not queue the whole roster.
--   * `Row` must be a real DT_Assaults row - the shell we overwrite waves/messages/timings on.
--     `assault_monkdad` is the safe default (least story-restricted row in the table).
--   * Wave entries take an Antevariant name or a plain DT_NPCList row, mixed freely. An empty wave
--     skips that phase; an unmatched name spawns nothing (logged at load).
--   * `StoryMax` retires an outgrown trigger; `Delay` schedules relative to the trigger AND the
--     last booked night - see AnNotes.
--
-- WaveNTime = seconds the director waits BEFORE EACH spawn of that wave, measured from the previous
-- spawn (any wave) - not the wave's duration. The very first body of the assault is immediate;
-- a one-body wave's Time is therefore its gap after the previous wave's last body, and the phase
-- advances a tick after the wave's last body. An EMPTY wave is skipped on the next tick with no
-- wait, so dead time goes on the rate of the wave whose first body should arrive late, never on
-- an empty one. Worked out in AnNotes/Modules/RevengeDirector.md.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local RE = require("ModuleRevenge.RevengeEvents")


local ASSAULTS = {

    -- ===================================================================
    -- FLATHILL - Symphonist blitz. A wave of Orchestrator and its spawns
    -- ===================================================================
    {
        Id      = "Revenge_Flathill",
        Name    = "monkdad - FLATHILL",
        Row     = "assault_monkdad",
        Trigger  = { Flag = "Fog_Completed" },        -- StoryProgress 12
        Delay    = 2,
        StoryMax = 22,   -- retires once the train station is open (Orchestrators are Office-tier)

        WarningMessage = "An unnatural fog rolls in...",
        StartMessage   = "A chorus in the mist.",

        Wave1     = { "Orchestrator Red", "Orchestrator Yellow", "Orchestrator Green" },
        Wave1Time = 5,
        Wave2     = { "Orchestrator Yellow", "Orchestrator Green", "Orchestrator Red" },
        Wave2Time = 3,
        Wave3     = { "Orchestrator Green", "Orchestrator Yellow", "Orchestrator Green", "Orchestrator Blue", },
        Wave3Time = 2,
        BossWave  = { "Orchestrator Red", "Orchestrator" },
        BossWaveTime = 10,

        OnStart = RE.Sequence(
            RE.Weather("Fog", 240000, 5000)
        ),
    },


    -- ===================================================================
    -- TRAIN - the Order wants revenge
    -- ===================================================================
    {
        Id      = "Revenge_Train",
        Name    = "monkdad - TRAIN",
        Row     = "assault_monkdad",
        Trigger  = { Flag = "TrainCompletedOnce" },   -- StoryProgress 24
        Delay    = 1,
        StoryMax = 32,   -- retires inside Labs

        WarningMessage = "An ordered stillness...",
        StartMessage   = "Radio crackles fill the air",

        Wave1     = { "Velites Guard", "Velites Guard" },
        Wave1Time = 5,
        Wave2     = { "Grenadier Guard", "Centurion Grunt" },
        Wave2Time = 15,
        Wave3     = {},
        Wave3Time = 3,
        BossWave  = { "Suppressor Grunt", "Suppressor Grunt", "Grunt_Captain" },
        BossWaveTime = 3,

        OnStart = RE.Sequence(
            RE.OrderDrop(5000, { spawns = { guards = 2, captains = 1 },
                                 spawnInterval = 1000, spawnRadius = 2000, minSpawnRadius = 1000 })
        ),
    },


    -- ===================================================================
    -- CONTROL - Chaos with Bots and rogue IS entities
    -- ===================================================================
    {
        Id      = "Revenge_Control",
        Name    = "monkdad - CONTROL",
        Row     = "assault_monkdad",
        Trigger  = { Flag = "LABS_TurretsDeactivated" },   -- StoryProgress 33
        Delay    = 1,
        StoryMax = 41,   -- retires as Security opens

        WarningMessage = "The lights flicker...",
        StartMessage   = "Containment has been compromised!",

        Wave1     = { "Robot_Security", "Hospitality Bot" },
        Wave1Time = 3,
        Wave2     = { "Obsidilisk", "Assassin", "Assassin" },
        Wave2Time = 3,
        Wave3     = { "Charge Peccary", "Phase Peccary" },
        Wave3Time = 3,
        BossWave  = { "Constrictor Bot", "Hive Sow", "Razor Pest", "Chonky Pest", "Exor Magus" },
        BossWaveTime = 5,

        OnStart = RE.Sequence(
            RE.Weather("Blackout", 120000, 5000),
            RE.PestDrop(10000, { spawns = { pests = 3, electros = 3 },
                                 spawnInterval = 4000, spawnRadius = 3000, minSpawnRadius = 2000 }),
            RE.PeccaryDrop(20000, { spawns = { peccaries = 1, sows = 1, mushrooms = 1, electros = 1 },
                                    spawnInterval = 4000, spawnRadius = 3500, minSpawnRadius = 2000 }),
            RE.ExorDrop(25000, { spawns = { exors = 1 },
                                 spawnInterval = 3000, spawnRadius = 3500, minSpawnRadius = 2000 })
        ),
    },


    -- ===================================================================
    -- MYCOFIELDS - Firey Exor assault
    -- ===================================================================
    {
        Id      = "Revenge_Mycofields",
        Name    = "monkdad - MYCOFIELDS",
        Row     = "assault_monkdad",
        Trigger  = { Flag = "LABS_CompletedAnteverseB" },       -- StoryProgress 35
        Delay    = 1,
        StoryMax = 45,   -- retires partway through Security

        WarningMessage = "The air feels different...",
        StartMessage   = "A blast of heat",

        Wave1     = { "Magma Pest", "Pest", "Magma Pest", "Peccary_Mushroom" },
        Wave1Time = 3,
        Wave2     = { "Peccary_Mushroom", "Magma Pest", "Magma Peccary" },
        Wave2Time = 5,
        Wave3     = { "Magma Exor" },
        Wave3Time = 15,
        BossWave  = { "Peccary", "Peccary_Mushroom", "Hive Sow", "Magma Peccary", "Magma Exor" },
        BossWaveTime = 3,

        OnStart = RE.Sequence(
            RE.Weather("Spores", 240000, 15000),
            RE.PestDrop(5000, { spawns = { magmas = 5 },
                                spawnInterval = 5000, spawnRadius = 3000, minSpawnRadius = 2000 })
        ),
    },


    -- ===================================================================
    -- SHADES - shade variants attack
    -- ===================================================================
    {
        Id      = "Revenge_Shades",
        Name    = "monkdad - SHADES",
        Row     = "assault_monkdad",
        Trigger  = { Flag = "Security_ExitOpened" },
        Delay    = 2,
        StoryMax = 59,

        WarningMessage = "Night falls upon the facility...",
        StartMessage   = "Shadows descend!",

        Wave1     = { "LabRat Shade", "Peccary Shade" },
        Wave1Time = 3,
        Wave2     = { "Grunt Shade" },
        Wave2Time = 10,
        Wave3     = { "Roaming Shade", "Roaming Shade" },
        Wave3Time = 5,
        BossWave  = { "Grunt Shade", "Grunt Shade", "Breacher Shade" },
        BossWaveTime = 3,

        OnStart = RE.Sequence(
            RE.Weather("BlackFog", 240000, 5000),
            RE.PestDrop(5000, { spawns = { magmas = 5 },
                                spawnInterval = 5000, spawnRadius = 3000, minSpawnRadius = 2000 })
        ),
    },


    -- ===================================================================
    -- RISE - another Order revenge assault
    -- ===================================================================
    {
        Id      = "Revenge_Rise",
        Name    = "monkdad - RISE",
        Row     = "assault_monkdad",
        Trigger  = { Flag = "Rise_Opened" },               -- no StoryProgress mapping
        Delay    = 2,
        WarningMessage = "Rise above...",
        StartMessage   = "And every path leads down",

        Wave1     = { "Suppressor Grunt", "Suppressor Grunt" },
        Wave1Time = 3,
        Wave2     = { "Dioscoridian" },
        Wave2Time = 10,
        Wave3     = { "Grunt_Guard", "Skirmisher", "Sweeper", "Grunt_Guard" },
        Wave3Time = 3,
        BossWave  = { "Centurion Grunt", "Centurion Grunt" },
        BossWaveTime = 7,

        OnStart = RE.Sequence(
            RE.OrderDrop(5000,  { spawns = { guards = 2, breachers = 1, captains = 1 },
                                  spawnInterval = 1000, spawnRadius = 2000, minSpawnRadius = 1000 }),
            RE.OrderDrop(45000, { spawns = { guards = 2, medics = 1, captains = 1 },
                                  spawnInterval = 1000, spawnRadius = 2000, minSpawnRadius = 1000 })
        ),
    },


    -- ===================================================================
    -- VOUSSOIR - the Groupe follows the cold down from the Alps: whiteouts on the bench
    -- ===================================================================
    {
        Id      = "Revenge_Voussoir",
        Name    = "monkdad - VOUSSOIR",
        Row     = "assault_monkdad",
        Trigger  = { Flag = "DAMS_CompletedVoussoir" },   -- StoryProgress 56
        Delay    = 1,
        StoryMax = 64,   -- retires once the Plant exit opens

        WarningMessage = "You feel a cold wind blow through...",
        StartMessage   = "A frozen force flies in!",

        Wave1     = { "Groupe Frostpack", "Groupe Frostpack" },
        Wave1Time = 3,
        Wave2     = { "Groupe Frostpack" },
        Wave2Time = 20,
        Wave3     = { "Groupe Breacher", "Groupe Breacher" },
        Wave3Time = 5,
        BossWave  = { "Groupe Rookram", "Groupe Frostpack" },
        BossWaveTime = 15,

        -- Whiteouts on the bench at +5 / +25 / +45 / +65s after the start banner (the delay
        -- counts from OnStart, so the 20s prep is in each number); the last one a 30s squall.
        OnStart = RE.Sequence(
            RE.SpecialWeather("Whiteout", 10000, 25000),
            RE.SpecialWeather("Whiteout", 10000, 45000),
            RE.SpecialWeather("Whiteout", 10000, 65000),
            RE.SpecialWeather("Whiteout", 30000, 85000)
        ),
    },


    -- ===================================================================
    -- HYDRO CROSSFIRE - Defense Bots attack and Exor jump the bots
    -- ===================================================================
    {
        Id      = "Revenge_HydroCrossfire",
        Name    = "monkdad - HYDRO xFire",
        Row     = "assault_monkdad",
        Trigger  = { Flag = "Dams_SpillwayOpen" },        -- StoryProgress 59
        Delay    = 2,    -- also the stacking gap behind Voussoir, so the two never land back to back
        StoryMax = 71,   -- retires once Reactors is under way

        WarningMessage = "Metallic footsteps crash closer...",
        StartMessage   = "Robots that despise!",
        Wave1     = { "Advanced Big Bot" },
        Wave1Time = 5,
        Wave2     = { "Event Defense Bot" },
        Wave2Time = 40,
        Wave3     = { "Event Defense Bot" },
        Wave3Time = 40,
        BossWave  = { "Advanced Big Bot" },
        BossWaveTime = 40,
    },
}

return ASSAULTS
