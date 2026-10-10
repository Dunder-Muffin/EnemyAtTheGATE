-- =======================================================================
-- SpawnerData - rules for the game's OWN spawners, keyed by their coordinates ("4000,150,322").
-- Also the story-band resolver (Phases) and the hard-mode row fallback.
--
--   * Keys are abs() - that is what Utils.GetSpawnerName builds. A SIGNED key is accepted and
--     folded to abs at load, so you can paste real world coords the way PlacedSpawnData does.
--
--   * SD.PlacedSpawns - our own pseudo-spawners at arbitrary coords - lives in
--     AnteData/PlacedSpawnData and is hung off SD below. Same read site as before.
--
-- AnNotes/AnteSystems/PlacedSpawns.md - Rationale + gotchas for both tables
-- =======================================================================
--  SPAWNERS
-- 
--   * Variant          - what variant to turn the base NPC into
--   * MultiVariants    - { <row>=<variant> } - some spawners create a random npc from a set
--                      this lets us define variants for one or more of those results
--   * Count            - spawn multiple - almost every spawner in the game spawns 1 npc. 
--                      multiple npcs are buggy natively so we do extra stuff to track state
--      * FillSpacingSec   - multispawns spawn one at a time. seconds between each (default 10)
--      * WipeCooldownHours - refill cooldown once all its spawns are killed, in rolling in-game
--                         hours (default 72; 36 under HARDMODE.NoEnd)
--      * VariantLimit     - multispawn, but only make a subset of them variants
--
--   * CooldownDays     - respawn cooldown for non-Count spawners, in CALENDAR days (ready at
--                        midnight). Default is the spawner class's own (mostly 2)
-- 
--   * SpawnAs          - replace the base row this spawner emits, at spawner:BeginPlay()
--                        from=to - this only works if the row names are correct
--                        * for multivariants, this only changes the matching npc 
--   * ForceSpawn       - (Symphonist spawners). Some spawners have an X% chance to spawn nothing. Force it to
--   * Disabled         - turn the spawner off
--   * NoLossFlag       - ignore the spawner's DisablePermanentlyFlag (the Gale trench's
--                        "pushed back" world flags) so it keeps respawning on its cooldown
--
--   * NoPatrol         - turn idle wandering off so the spawns stay still
--   * StoryMin/Max     - enables/disables a spawn based on StoryProgress. Lets us spawn later game enemies when appropriate
--   * SpawnRange       - spawner does not spawn until a player is this close (native 7500).
--                        * SETTINGS.GAMEPLAY.SpawnRange can override the global floor
--                        * can only raise value
--
--   * Phases           - STORY-BANDED RULE SETS. The whole entry changes as the run progresses
--                        (see the block below) - this is the ONLY story-banding mechanism
--
--   * Hard             - HARD MODE (SETTINGS.MODULES.HARDMODE.NoMercy). On a top-level entry:
--                        the whole rule only exists in hard mode (off = as if unlisted, so the
--                        spawner runs vanilla). On a Phases band: that band is only eligible in
--                        hard mode. Read at world load (the flag can't change mid-session).
--
-- --------------------------------------------------------------------------
--   PHASES - "this spawner emits something different later in the run"
--
--   Top-level props are the SHARED base; each phase OVERRIDES them. The LAST phase whose
--   window is open wins (StoryMin <= StoryProgress < StoryMax), so list them weakest ->
--   strongest and leave the FIRST one ungated as the floor.
--
--     Ex: a Repeller, upgraded to a Dislocator later. One band = one line.
--       ["16947,11248,10"] = { Phases={ {Variant="Exor Repeller"}, {StoryMin=60, Variant="Exor Dislocator"} } },
--
--     Ex: the Order creeping out of their start zone - the BASE ROW changes, not just
--         the variant, so each band restates what it needs:
--       ["9131,18698,810"] = { NoPatrol=true, Phases={
--           {              MultiVariants={ Pest="Antegrav Pest", Peccary="Phase Peccary", Exor_Monk="Exorrior" },
--                          Count=2, VariantLimit=1 },      -- floor: ungated
--           { StoryMin=24, SpawnAs="Grunt_Guard_Offduty", Variant="Velites Guard", Count=2 },
--           { StoryMin=34, SpawnAs="Grunt_Captain",    Variant="Commander" },
--           { StoryMin=51, SpawnAs="Gatekeeper_Phyter" },   -- no Variant: vanilla body
--           { StoryMin=91, SpawnAs="Exor_Volatile",    Variant="Acidic Exor" },
--       }},
--
--   (!) A phase is the COMPLETE picture, not a patch: its MultiVariants REPLACES the base
--       map rather than merging into it. Band one row of a 4-row spawner and you restate
--       all four - deliberate, so you can read what a band spawns off its own line.
--   (!) No phase eligible -> the top-level props alone (an entry that is ONLY Phases then
--       behaves vanilla). Give it an ungated floor phase instead of relying on that.
--   (!) Top-level StoryMin/Max is the OUTER window (spawner on/off). Phases pick what it
--       emits while it is on. Don't reach for a phase to turn a spawner off - a phase CAN
--       carry Disabled=true, but the outer window is the readable way to say it.
--   (!) Phases are re-checked on the live heartbeat, so a band change takes hold under a
--       spawner the player is standing next to. Bodies already out are NOT retro-changed;
--       the group refills into the new band as they die.
--
-- =======================================================================

local STATE = require("AnteCore.State")   -- for the hard-mode flags only (State has no deps)

local SD = {}

SD.Spawners = {

-- Dev note to self: Hard mode entries
-- ["41183,2205,-3010"] = { Hard=true , Variant="Exor Shadow Monk"},
-- -- or hard-only Phases band:
-- ["..."] = { Phases = { { Variant = "Exor Monk-ish thing" },
--                        { Hard = true, Variant = "Exor Shadow Monk" } } },

-- =======================================================================
-- OFFICE SECTOR
-- =======================================================================

    -- Office 1F, Starting backroom
    ["-21012,12978,410"] = { StoryMax=11, Count=2 },
    ["-18751,11181,10"] = { StoryMax=11, Phases={{Hard=true, Variant="Antegrav Pest"}} },

    -- Office 1F, Inside Cafeteria / Lobby
    ["-10620,6281,255"] = { StoryMin=31, SpawnAs="Pest_Electro", Count=2 },
    ["-11682,6227,255"] = { Variant="Razor Pest", Phases={{Hard=true, Count=2 }} },
    ["-14177,12573,12"] = { Variant="Charge Peccary", Phases={{Hard=true, Count=2 }} },
    ["-16616,12158,10"] = { Phases={ {Variant="Antegrav Pest"}, {StoryMin=35, Variant="Anterazor Pest"} }, Count=2 },
    ["-16947,11248,10"] = { Variant="Razor Pest", StoryMax=35 },
    ["-19079,15912,10"] = { MultiVariants={ Peccary="Phase Peccary", Exor_Monk="Exorrior", Exor="Antegrav Exor" }, Count=2 },
    ["-17231,9965,10"] = { SpawnAs="Pest_Carbonated", Variant="Chonky Pest", StoryMax=35 },
    ["-14767,15698,18"] = { Phases={ {Variant="Razor Pest" }, 
                                     { StoryMin=20, Disabled=true } }},
    ["-16341,15466,10"] = { Phases={ {SpawnAs="Pest_Carbonated", Variant="Chonky Pest", StoryMax=30 },
                                     { StoryMin=20, Disabled=true } }},
    ["-15794,14793,10"] = { Disabled=true, },
    ["-16112,15728,10"] = { Disabled=true, },

    -- Office Robot Bays
    ["-10495,15269,12"] = { Variant="Cafeteria Bot", CooldownDays=1 },
    ["-14858,7858,990"] = { Variant="Office Bot", Count=2, CooldownDays=1 },
    ["-20037,20772,2510"] = { Variant="Hospitality Bot", CooldownDays=1 },
    --["-10905,20483,810"] = { Grayson Bot }

    -- Office 2F - Greyson area, Conference Room ccc
    ["-9131,18698,810"] = { Phases = {
        { MultiVariants = { Pest="Antegrav Pest", Peccary="Phase Peccary", Exor_Monk="Exorrior" }, Count=2, VariantLimit=1 },
        { StoryMin=25, SpawnAs="Grunt_Guard_Offduty", Variant="Velites Guard", Count=2 },
        { StoryMin=35, SpawnAs="Grunt", Variant="Suppressor Grunt", Count=2, VariantLimit=1 },
        { StoryMin=71, SpawnAs="Gatekeeper_Phyter", Variant="Neophyte Trainer" },
        { StoryMin=100, SpawnAs="Exor_Volatile", Variant="Exor Hunter" },
    } },
    ["-12246,20719,810"] = { Phases = {
        { MultiVariants = { Pest="Antegrav Pest", Peccary="Phase Peccary", }, Count=2 },
        { StoryMin=25, SpawnAs="Grunt" },
        { StoryMin=41, SpawnAs="Grunt_Shotgun", Variant="Sweeper" },
        { StoryMin=71, SpawnAs="Grunt_Sapper", Variant="Mad Rat", Count=2, VariantLimit=1 },
    } },
    ["-12409,15772,810"] = { Phases = {
        { Variant="Antegrav Pest", Count=2 },
        { StoryMin=21, SpawnAs="Peccary", Variant="Charge Peccary" },
        { StoryMin=31, SpawnAs="Sow" },
        { StoryMin=51, SpawnAs="Trooper", Variant="Centurion Grunt" },
        { StoryMin=91, SpawnAs="Exor_Armored", Variant="Exor Repeller" },
    } },
    ["-11323,15748,901"] = { StoryMax=21 },


    
    -- Office 2F corridors
    ["-18703,12586,1110"] =  { SpawnAs="Pest_Volatile", Variant="Signal Pest" },
    ["-16492,15501,1223"] = { MultiVariants = { Pest="Razor Pest", Exor_Monk="Exorrior" }, Count=2, VariantLimit=1, 
                             Phases = {{ Hard=true, Count=3 }}},
    ["-17862,15123,1110"] = { MultiVariants = { Peccary="Charge Peccary", Exor="Antegrav Exor" }, Count=2, VariantLimit=1, },
    ["-17514,13515,1110"] = { MultiVariants = { Pest="Antegrav Pest", Peccary="Phase Peccary" }, StoryMax=45 },
    ["-20831,14766,1110"] =  { MultiVariants = { Peccary="Charge Peccary" }, Count=2, VariantLimit=1,
                              Phases = {{ Hard=true, Count=3 }} },
    ["-19171,12812,1110"] =  { MultiVariants = { Pest="Razor Pest", Peccary="Carbunccary", Exor_Monk="Exor Magus" } },
    ["-16398,13334,1110"] =  { SpawnAs="Pest_Carbonated", Count=2, VariantLimit=1 },
    ["-16044,10180,1210"] =  { Phases = {
        { MultiVariants = { Pest="Antegrav Pest", Exor_Monk="Exorrior" } },
        { StoryMin=41, SpawnAs="Grunt", Variant="Suppressor Grunt" },
        { StoryMin=71, SpawnAs="Grunt_Sapper" },
        { StoryMin=91, SpawnAs="Exor_Pikeman", Variant="Exor Spiritwalker" },
    } },
    ["-21640,10610,1111"] =  { MultiVariants = { Pest="Razor Pest", Exor_Monk="Exor Magus" },
                              Phases = {{ Hard=true, Count=2, VariantLimit=1 }} },
    ["-17483,11300,1110"] =  { Variant="Exorrior", StoryMax=35 },
    ["-19418,11233,1109"] =  { Variant="Razor Pest", StoryMax=25,
                              Phases = {{ Hard=true, SpawnAs="Peccary", Variant="Phase Peccary" }}},
    ["-20160,10131,1110"] =  { SpawnAs="Pest_Volatile", Variant="Signal Pest" },
    ["-17977,11822,1110"] = { Phases = {{ Hard=true, Variant="Flask Rat", Count=2, VariantLimit=1 }} },
    ["-19302,12496,1110"]  = { StoryMax=21, 
                              Phases = {{ Hard=true, SpawnAs="Pest_Volatile", Variant="Signal Pest" }}, },
    ["-16248,12906,1130"] = { SpawnAs="Peccary", StoryMax=21},
    ["-20270,11750,1829"] = { StoryMax=21 },
    ["-17330,17726,2930"]  = { Disabled=true },
    ["-20270,9660,1610"]  = { Disabled=true },

    -- 2F Data Farm / Cubicles
    ["-18313,8553,990"] = { MultiVariants = { Pest="Razor Pest", Exor="Antegrav Exor" }, Count=2, VariantLimit=1, 
                              Phases = {{ Hard=true, Count=3, VariantLimit=2 }}, },
    ["-19655,8705,990"] = { SpawnAs="Pest_Carbonated", Variant="Chonky Pest", StoryMax=35 },
    ["-16982,7691,990"] = { MultiVariants = { Pest="Antegrav Pest", Peccary="Charge Peccary", Exor_Monk="Exor Magus", Exor="Antegrav Exor" }, Count=2, VariantLimit=1,
                            Phases= {{ Hard=true, Count=3 }}},
    ["-18769,6441,990"] = { Variant="Phase Peccary", Count=2, VariantLimit=1,
                            Phases = {{Hard=true, Count=3, VariantLimit=2 }}},
    ["-18362,5444,990"] = { Count=2, VariantLimit=1, 
                            Phases={ { Variant="Razor Pest" }, 
                                     { StoryMin=35, Variant="Anterazor Pest"},
                                     { StoryMin=90, SpawnAs="Exor_Armored", Variant="Exor Repeller" },
                                     { Hard=true, StoryMin=90, SpawnAs="Exor_Armored", Variant="Exor Dislocator" }, }},
    ["-20516,8574,990"] = { MultiVariants = { Pest="Antegrav Pest", Peccary="Charge Peccary", Exor_Monk="Exorrior", Exor="Magma Exor", }, Count=2 },
    ["-20385,4971,1590"] =  { Variant="Exor Magus",
                              Phases = {{ Hard=true, Count=2, VariantLimit=1 } }},
    ["-21362,6885,990"] = { MultiVariants = { Exor="Antefire Exor", Exor_Pikeman="Exor Spiritwalker" }},
    ["-20347,6845,990"] = { SpawnAs="Pest_Carbonated", StoryMax=25 },
    ["-16642,6661,990"] = { Disabled=true },
    ["-18474,6013,430"] = { Disabled=true },
    ["-22842,7348,1040"] = { Disabled=true },
    ["-15645,8177,990"] = { Disabled=true },
    ["-18576,7063,990"] = { Disabled=true },
    ["-17973,7336,990"] = { Phases = {{ Hard=true, Variant="Barrier Mage", Count=3, VariantLimit=1 }} },
    -- ["21640,10611,990"] = { },

    -- 3F Elevator halls
    ["-22830,16394,2510"] = { Disabled=true },
    ["-17660,16143,2510"] = { SpawnAs="Pest_Volatile", Variant="Signal Pest" },
    ["-18934,16388,2511"] = { MultiVariants = { Pest="Antegrav Pest", Peccary="Phase Peccary", Exor_Monk="Exorrior", Exor="Antegrav Exor" }, Count=2 },
    ["-18178,17057,2510"] = { Variant="Antegrav Pest", Count=2 },
    ["-15965,15769,2610"] = { Variant="Antegrav Pest", Count=2 },

    -- 3F Exor Walkway
    ["-21600,17559,2618"] = { Variant="Exorrior", },
    ["-22129,18739,2700"] = { SpawnAs="Pest_Carbonated" },

    -- 3F Halls
    ["-21940,21184,2510"] = { MultiVariants = { Pest="Chonky Pest", Peccary="Phase Peccary", Exor_Monk="Exor Magus", Exor="Magma Exor", Exor_Pikeman="Exor Spiritwalker" }, NoPatrol=true },
    ["-16100,18053,2510"] = { MultiVariants = { Pest="Antegrav Pest", Peccary="Charge Peccary" } },
    ["-16063,19244,2510"] = { MultiVariants = { Pest="Antegrav Pest", Peccary="Phase Peccary", Exor_Monk="Exorrior", Exor="Antegrav Exor" }, Count=2 },
    ["-17278,20898,2510"] = { SpawnAs="Pest_Volatile", Variant="Signal Pest",
                             Phases = {{ Hard=true, Count=2 }} }, 
    ["-20881,20669,2510"] = { MultiVariants = { Pest="Antegrav Pest", Peccary="Phase Peccary" }, Count=2 },   
    ["-17105,19823,2921"] = { SpawnAs="Peccary", StoryMax=20 },
    ["-11874,20869,2510"] = { Variant="Razor Pest", StoryMax=20 },
    ["-14820,18860,2510"] = { StoryMax=31, SpawnAs="Pest_Volatile", Variant="Signal Pest" },
    ["-22317,20337,2509"] = { StoryMax=31, SpawnAs="Pest_Volatile", Variant="Signal Pest" },
    ["-13441,20304,2510"] = { Disabled=true }, 
    ["-16014,18698,2510"] = { Disabled=true },
    ["-20277,20108,2922"] = { Disabled=true },
    ["-15446,19680,2921"] = { Disabled=true },
    ["-12798,20046,3010"] = { Disabled=true },
    

    -- 2F Symphs
    ["-21776,7259,1040"] = { Variant="Orchestrator", ForceSpawn=true },
    ["-14646,18116,1116"] = { Hard=true, ForceSpawn=true, Count=2 },
    -- [""] = {Symph} --2F

    -- 3F Symphs
    ["-20728,20950,2510"] = { Variant="Orchestrator", ForceSpawn=true },
    --["-18057,16674,2510"] = {Symph},

-- =======================================================================
-- OFFICE VIGNETTES
-- =======================================================================

    -- Far Garden
    --[""] = {ExorMonk}
    -- ["118317,334942,2066"] = { Variant="Exor Magus", },
    ["122728,333905,1802"] = { Variant="Exor Magus", },

    -- Flathill
    ["7558,341986,3409"] = { Variant="Orchestrator", ForceSpawn=true }, -- elevator
    ["12581,339807,1181"] = { ForceSpawn=true }, -- behind arcade


-- =======================================================================
-- MANUFACTURING
-- =======================================================================

    -- Behind Forge and Forge Halls
    ["-6470,32667,8"] = { Variant="Hospitality Bot", CooldownDays=1 },
    ["-9299,29638,-90"] = { SpawnAs="Grunt_Guard_Offduty", Variant="Velites Guard", Count=2, },
    ["-8106,32273,-90"] = { SpawnAs="Pest_Volatile", Variant="Signal Pest" },
    ["-10164,31996,-190"] = { MultiVariants = { Pest="Antegrav Pest", Peccary="Charge Peccary", Exor_Monk="Exorrior" } },
    ["-9088,34828,-90"] = { Phases = { {Variant="Grenadier Guard", Count=2, VariantLimit=1 },
                                       { Hard=true, VariantLimit=2 },
                                       { StoryMin=71, SpawnAs="Exor", Variant="Exor Superior" } }},
    ["-10913,36077,60"] = { SpawnAs="Pest_Carbonated", Variant="Chonky Pest" },
    ["-6348,34485,811"] = { Phases = { { Variant="Suppressor Grunt" },
                                      { Hard=true, SpawnAs="Grunt_Sniper", Variant="Tracker Sniper" } }},
    ["-5129,39298,810"] = { SpawnAs="Grunt_Guard_Offduty", Variant="Velites Guard", Count=2, 
                           Phases = {{ Hard=true, Count=3 }} },
    ["-344,34028,310"] = { Variant="Suppressor Grunt" },
    ["-9256,30721,-190"] = { SpawnAs="Pest_Volatile", Variant="Signal Pest", },
    ["-7327,32526,-90"] = { SpawnAs="Pest_Carbonated", Count=3 },
    ["-5842,37257,910"] = { StoryMin=71, SpawnAs="Exor", Variant="Antegrav Exor" },
    ["-8575,31741,-276"] = { Disabled=true },
    ["-8852,31547,110"] = { Disabled=true },
    ["-11503,36436,60"] = { Disabled=true },


    -- Maint Office
    ["-6045,32000,10"] = { Phases = {{ Hard=true, Variant="Exor Magus", Count=2, VariantLimit=1 }} },

    -- Lot Oversight / Radiation Pool
    ["-3203,33678,-90"] = { Phases = {{ Hard=true, Variant="Suppressor Grunt", Count=2 }} },
    ["5872,37257,910"] = { Variant="Grenadier Guard" },
    ["-4288,39207,810"] = { SpawnAs="Grunt_Guard_Offduty", Variant="Velites Guard" },
    ["-1561,36598,260"] = { Variant="Flask Rat" }, --Spawns once
    ["-1810,37258,910"] = { Variant="Suppressor Grunt", },
    ["-4523,33291,210"] = { Variant="Exor Magus", },
    ["-5286,36230,-90"] = { Phases = { { Disabled=true }, 
                          { Hard=true, SpawnAs="Peccary", Variant="Phase Peccary", StoryMax=30 }} },


    -- Storage
    ["-5337,38286,-390"] = { Variant="Exorrior" },
    ["-3666,37243,-387"] = { Variant="Phase Peccary" },
    ["-1385,36276,-690"] = { Variant="Exorrior", Count=2, VariantLimit=1 },
    ["-3814,35407,-690"] = { Phases = {{ Hard=true, Variant="Exor Magus", Count=2, VariantLimit=1 }} },

    -- Shipping Logistics / MG Nest
    ["-3035,31708,510"] = { Hard=true, Count=2 }, --Grunt
    ["-3330,31642,210"] = { SpawnAs="Grunt_Medic", Variant="Dioscoridian", 
                           Phases = {{ Hard=true, Count=2 }} },
    ["-4442,30192,210"] = { SpawnAs="Trooper", Variant="Centurion Grunt" },
    ["-4335,31351,510"] = { SpawnAs="Grunt_Captain", Variant="Trident" },
    ["-4698,30117,510"] = { Phases = { {Variant="Grenadier Guard" },
                                       { StoryMin=71, SpawnAs="Gatekeeper_Phyter" } }},
    ["-3418,31281,510"] = { Variant="Suppressor Grunt", },
    ["-291,35086,310"] = { Variant="Dioscoridian", },
    ["308,32585,459"] = { Phases={ {Variant="Exorrior"}, {StoryMin=35, Variant="Exorrior Magus"} } },
    ["668,33075,678"] = { Variant="Exor Magus" },
    ["-1873,30954,-90"] = { Phases = { { Variant="Trident" },
                                       { StoryMin=71, SpawnAs="Exor_Armored", Variant="Exor Repeller" }} },
    ["-109,35131,710"] = { Variant="Commander" },
    ["-2555,33017,509"] = { Variant="Twilight Sniper" },
    ["-3503,32087,510"] = { Phases = { { Hard=true, Variant="Grenadier Guard" },
                                       { StoryMin=71, SpawnAs="Gatekeeper_Phyter" } }},
    ["-3372,31855,-90"] = { Phases = { { Disabled=true }, 
                         { Hard=true, Variant="Suppressor Grunt", Count=2, VariantLimit=1 }} },
    ["-1906,31089,-90"] = { Phases = {{ Hard=true, Count=2 }} },
    ["-4902,30210,210"] = { Phases = { { SpawnAs="Trooper", Variant="Centurion Grunt"},
                                       { StoryMin=71, SpawnAs="Gatekeeper_Mage" } }},
    ["-2056,28877,-90"] = { Disabled=true },
    ["-5042,30590,210"] = { Disabled=true },
    -- ["-4322,30413,510"] = { Variant="", },

    -- Underground Portal
    ["-6822,38117,-1148"] = { Variant="Antegrav Pest", Count=3 },
    ["-6117,36261,-1290"] = { SpawnAs="Pest_Volatile", Variant="Signal Pest" },
    ["-4659,35784,-1290"] = { Variant="Razor Pest" },
    ["-6448,35069,-1380"] = { Variant="Charge Peccary" },
    ["-4351,34420,-1290"] = { Variant="Phase Peccary" },
    -- ["-7239,37826,-1148"] = { Variant="Carbunccary" },
    ["-3848,33971,-1340"] = { Disabled=true },
    ["-5525,37627,-1030"] = { Disabled=true },

    -- Mines
    ["2543,42147,519"] = { Variant="Exorrior" },
    ["6180,43753,755"] = { Variant="Razor Pest" },
    ["6713,43780,755"] = { SpawnAs="Exor_Monk", Variant="Exor Magus" },
    ["7642,43393,805"] = { Variant="Obsidilisk" },
    ["6291,38707,588"] = { Variant="Gravilisk", 
                           Phases = { { Hard=true, Count=2, VariantLimit=1 } }},
    ["10295,40133,1218"] = { Variant="Phase Peccary" },
    ["7297,39711,357"] = { Phases = { { Hard=true, Variant="Obsidilisk", Count=3, VariantLimit=1 } }},
    ["3370,43691,397"] = { Phases = { {Disabled=true},
                                     { Hard=true, Count=2 }} },
    ["5440,44196,490"] = { Disabled=true },
    ["9733,38346,1237"] = { Disabled=true },
    ["9067,42358,496"] = { Phases =  { { Variant="Orchestrator", ForceSpawn=true },
                                       { Variant="Orchestrator", Count=2, VariantLimit=1 } }},

    -- Mineshaft
    ["13925,33578,1382"] = { Variant="Obsidilisk" },
    ["14043,35066,1480"] = { Variant="Obsidilisk", Count=2, VariantLimit=1 },
    ["11397,35004,1100"] = { Phases = { { Variant="Obsidilisk", Count=2, VariantLimit=1 },
                                        { Hard=true, Variant="Obsidilisk", Count=4, VariantLimit=2 } }},

    -- Tram
    ["4765,31413,1677"] = { Variant="Grenadier Guard" },
    ["2006,32991,1307"] = { Variant="Dioscoridian" },
    ["900,31840,1308"] = { SpawnAs="Grunt_Captain", Variant="Trident" },
    ["1691,32076,1307"] = { Variant="Trident", 
                            Phases = {{ Hard=true, Count=2, VariantLimit=1 }} },

    -- Mapping Center - Smith entrance
    ["-15016,41662,-195"] = { Variant="Exorrior", Count=2 },
    ["-15506,40667,-195"] = { Phases = { { Disabled=true },
                                       { Hard=true, Variant="Razor Pest", Count=3, VariantLimit=1, StoryMax=30 } }},
    ["-10445,39571,505"] = { Variant="Exor Magus" },

    -- Mapping Center
    
    ["-14641,48754,705"] = { Phases = { { Hard=true, SpawnAs="Trooper", Variant="Centurion Grunt" } }},
    ["-14958,48108,305"] = { Variant="Trident" },
    ["-15306,48123,305"] = { Variant="Suppressor Grunt" },
    ["-14963,48463,305"] = { Variant="Suppressor Grunt" },
    ["-11612,45329,505"] = { Phases = { { Hard=true, SpawnAs="Grunt_Guard_Offduty", Variant="Velites Guard", Count=2 } } },
    ["-12984,45513,768"] = { Variant="Tracker Sniper" },
    ["-16451,44353,505"] = { Phases = { { Disabled=true },
                                       { Hard=true, Variant="Exorrior Magus" } }},

    -- Syncotron
    ["2936,22136,905"] = { Phases = { { Hard=true, Variant="Grenadier Guard" } }},
    ["1414,21025,1204"] = { Variant="Suppressor Grunt" },

-- =======================================================================
-- MANUFACTURING VIGNETTES
-- =======================================================================

    -- Train
    ["334048,9649,600"] = { Variant="Suppressor Grunt", Count=2 },
    ["335493,5106,600"] = { SpawnAs="Grunt_Captain" },
    -- ["336185,3294,600"] = { },
    ["336923,2390,940"] = { Variant="Trident" },
    ["339484,-809,600"] = { Variant="Suppressor Grunt" },
    -- ["336345,3301,601"] = { SpawnAs="Grunt_Sniper", Variant="Tracker Sniper" }, --Medic
    -- ["334669,7889,600"] = { },

    
-- =======================================================================
-- LABS
-- =======================================================================

    -- Office-Labs hall 

    -- Wildlife Pens square
    ["-867,10667,-1181"] = { Variant="Exor Magus" },
    ["-1120,8917,-1762"] = { Variant="Hive Sow" },
    ["3517,10641,-1749"] = { Variant="Hive Sow" },
    ["-1109,9181,-981"] = { Variant="Flask Rat" },

    -- Lobby/Aquarium
    ["4437,12755,-1181"] = { Variant="Constrictor Bot" },
    ["6733,13157,-1181"] = { SpawnAs="Pest_Volatile", Variant="Signal Pest" },
    ["6124,15179,-1243"] = { Phases= { { Variant="Flask Rat" },
                                       { StoryMin=71, SpawnAs="Pest_Electro", Variant="Laser Pest", Count=2 } }},
    ["5740,15132,-1243"] = { Variant="Suppressor Grunt" },
    ["7411,13760,-1181"] = { Variant="Laser Pest", Count=2, VariantLimit=1 },
    --["6756,14079,-422"] = { Variant="Laser Pest" },
    ["7638,12341,-522"] = { SpawnAs="Peccary_Electro", Variant="Electro Peccary",
                           Phases = { { Hard=true, Count=3 } }},
    ["553,15099,-881"] = { Variant="Trident", StoryMax=42 },
    ["3746,13917,-1181"] = { Variant="Flask Rat" },
    ["4969,15051,-422"] = { Disabled=true },
    
    -- Particle Labs
    ["-62,14009,-880"] = { Variant="Flask Rat" }, 
    ["-1342,14662,-1181"] = { Variant="Skirmisher" }, 
    ["-2599,11567,-1181"] = { Variant="Laser Pest", Count=2, VariantLimit=1 },
    ["1929,12997,681"] = { SpawnAs="Pest_Leyak", Variant="Leyak Pest" }, 
    ["-2098,12887,-682"] = { SpawnAs="Pest_Leyak", Variant="Leyak Pest" }, -- Particle Labs post-zombies
    ["-245,13930,-880"] = { SpawnAs="Pest_Leyak", Variant="Leyak Pest" },
    ["-2720,11393,-681"] = { Variant="Laser Pest", Count=2, VariantLimit=1 },

    
    -- CBlock
    --["3004,-6656,533"] = { Variant="Constrictor Bot" }, --Near the vault
    ["12187,3059,-965"] = { Variant="Antegrav Exor", Count=2, VariantLimit=1 },
    -- ["4763,2463,60"] = { SpawnAs="Exor" },
    -- ["-2146,-3725,590"] = { Variant="Obsidilisk" },
    ["4530,5590,-240"] = { SpawnAs="Pest_Electro", Count=2 },
    ["3629,1427,110"] = { Variant="Laser Pest" },
    ["12339,1918,-795"] = { SpawnAs="Robot_Containment", Variant="Constrictor Bot" },
    ["3004,-6656,533"] = { Variant="Constrictor Bot" },
    ["4665,7213,-240"] = { Disabled=true },
    ["5784,6835,240"] = { Disabled=true },
    ["4369,6205,-240"] = { Disabled=true },
    
    -- Adjustment 1F
    ["3642,2938,60"] = { StoryMin=50, Variant="Magma Exor" },
    ["1451,1703,360"] = { SpawnAs="Peccary_Electro", Variant="Electro Peccary", NoPatrol=true },
    ["1481,2544,400"] = { Phases={ {Variant="Antegrav Exor"}, 
                                   { Hard=true, Variant="Antegrav Exor", Count=2 },
                                   { Hard=true, StoryMin=34, StoryMax=50, Variant="Antefire Exor"}, 
                                   { StoryMin=50, Variant="Antefire Exor" },
                                   { Hard=true, StoryMin=50, Variant="Antefire Exor", Count=2 } }},
    ["-1162,2968,360"] = { Variant="Orchestrator" },
    ["191,4721,410"] = { Phases = { { SpawnAs="Exor" },
                            { StoryMin=35, SpawnAs="Exor", Variant="Magma Exor" },
                            { Hard=true, StoryMin=35, SpawnAs="Exor", Variant="Magma Exor", Count=2 } }},
    ["2384,1334,660"] = { Variant="Magma Exor" }, --Vanilla gated
    ["-984,4442,360"] = { Variant="Exorrior" },
    ["2252,36,660"] = { Variant="Charge Peccary" },
    ["-3800,3641,360"] = { StoryMin=50, SpawnAs="Pest_Electro", Variant="Laser Pest", Count=3, VariantLimit=1 },
    ["2302,7079,699"] = { Variant="Flask Rat" },
    ["3965,5051,360"] = { SpawnAs="Assassin", Variant="Obsidilisk" },
    -- ["-3800,3641,360"] = { SpawnAs="Grunt_Captain", Variant="Commander" },
    ["1980,4081,410"] = { SpawnAs="Trooper", Variant="Centurion Grunt" },
    ["1406,3904,410"] = { Variant="Suppressor Grunt" },
    ["591,5193,360"] = { SpawnAs="Symph", Variant="Orchestrator" }, --Zombie, Vanilla gated
    ["1681,12536,-1081"] = { Disabled=true },
    ["6007,3345,654"] = { Disabled=true },
    ["-4734,3233,360"] = { Disabled=true },
    ["1228,1228,660"] = { Disabled=true },
    ["-861,4405,360"] = { Disabled=true },
    ["82,366,360"] = { Disabled=true },
    -- ["2113,495,660"] = { SpawnAs="Exor", Variant="Magma Exor" },

    -- Adjustment 2F
    --["4639,3706,1070"] = { Variant="" }, --Robot_Containment
    ["315,354,1110"] = { Phases= { { SpawnAs="Grunt_Shotgun", Variant="Sweeper" },
                                     { StoryMin=71, SpawnAs="Pest_Electro", Count=3 } }},-- Grunt
    ["735,-2098,750"] = { Phases= { { Count=2 },
                                     { StoryMin=71, SpawnAs="Exor" } }}, --Grunt_Captain
    ["188,-2097,750"] = { Variant="Dioscoridian" },
    ["2558,4886,1310"] = { Variant="Charge Peccary" },
    ["1605,3995,1260"] = { Variant="Antegrav Exor" },
    ["467,1164,1010"] = { Phases= { { SpawnAs="Grunt_Medic", Variant="Dioscoridian"},
                                     { SpawnAs="Peccary_Electro", Variant="Electro Peccary"} }},
    ["1160,1735,1010"] = { SpawnAs="Grunt_Guard_Offduty", Variant="Velites Guard", Count=2 },
    ["1333,3170,1010"] = { Variant="Suppressor Grunt" },
    ["516,5299,1260"] = { SpawnAs="Pest_Electro", Count=3,
                          Phases= {{ Hard=true, Variant="Laser Pest", VariantLimit=2 }}}, --Sow
    ["2386,-425,1110"] = { Variant="Flask Rat" },
    ["1328,2888,990"] = { Variant="Sweeper" },
    ["1721,260,1110"] = { Variant="Skirmisher", Count=2, VariantLimit=1 },
    ["854,4311,1260"] = { SpawnAs="Pest_Leyak", Variant="Leyak Pest", 
                            Phases =  { { Hard=true, Count=2 } }},
    ["1687,251,1110"] = { Phases = { { Disabled=true },
                                     { StoryMin=71, SpawnAs="Exor_Armored", Variant="Exor Dislocator" } }},
    ["1933,136,1110"] = { Phases = { { Disabled=true },
                                     { StoryMin=71, SpawnAs="Peccary_Armored", Variant="Armored Peccary" } }},
    ["29,955,590"] = { Variant="Gravilisk" },
    ["2241,5035,1310"] = { Disabled=true },
    ["2448,5123,1310"] = { Disabled=true },
    ["2983,5045,1310"] = { Disabled=true },
    ["1416,297,1710"] = { Disabled=true },
    ["1424,1088,1110"] = { Disabled=true },
    ["965,4493,1260"] = { Disabled=true },
    ["1555,32,1110"] = { Disabled=true },

    -- Inner Wing
    ["18173,5009,669"] = { Variant="Constrictor Bot" },
    -- ["13432,-735,-669"] = { SpawnAs="Zombie Sci", Variant="Zombie Trio" },
    -- ["13521,-897,-669"] = {  Variant="Zombie Trio" },
    
    --["21844,-14425,-936"] = { Variant="Tarasque Summoner" },


    -- Control Center
    ["11304,50,2416"] = { Variant="Suppressor Grunt", Count=2 },
    ["8336,2060,2536"] = { Variant="Grenadier Guard", Count=2 },
    ["11730,-2214,2416"] = { SpawnAs="Grunt_Guard_Offduty", Variant="Velites Guard", Count=2,
                            Phases = { { Hard=true, Count=3 } }},
    ["9522,3614,2236"] = { Phases = { { Hard=true, Count=2 } }},
    ["13292,4285,2776"] = { Variant="Laser Pest" },
    ["12403,174,3216"] = { SpawnAs="Grunt_Captain", Variant="Commander" },
    ["11556,5590,2776"] = { SpawnAs="Peccary_Electro", Variant="Electro Peccary" },
    ["9099,-6341,2836"] = { Disabled=true },

    -- Orchestrators
    ["6002,13152,1181"] = { Variant="Orchestrator", ForceSpawn=true },
    ["-1703,10916,-681"] = { ForceSpawn=true }, 
    ["5783,3460,-240"] = { ForceSpawn=true }, 




-- =======================================================================
-- LABS VIGNETTES
-- =======================================================================

    -- Mycofields
    ["321820,329929,2219"] = { SpawnAs="Pest_Magma", Variant="Magma Pest", Count=2 },
    ["320985,329704,1945"] = { SpawnAs="Pest_Magma", Variant="Magma Pest",
                               Phases={ { Hard=true, SpawnAs="Peccary_Alpha", Variant="Magma Peccary" } }},
    ["322008,319949,2607"] = { SpawnAs="Pest_Magma", Variant="Magma Pest", Count=3 },
    ["324607,325845,1782"] = { Variant="Magma Exor", Count=2 },
    ["317976,324306,1284"] = { Variant="Exorrior" },
    ["317658,320454,2334"] = { SpawnAs="Peccary_Alpha", Variant="Magma Peccary",
                               Phases={ { Hard=true, Count=2 } }},
    ["317868,324014,1292"] = { SpawnAs="Exor", Variant="Magma Exor",
                               Phases = {{ Hard=true, Count=2 }} },
    ["317629,324054,2334"] = { SpawnAs="Exor", Variant="Magma Exor" },
    ["318852,317682,2701"] = { Phases={ { Hard=true, Variant="Exor Magus", Count=2 } }},
    ["324771,318916,3393"] = { SpawnAs="Pest_Magma", Variant="Magma Pest" },
    ["325828,318894,4070"] = { SpawnAs="Exor", Variant="Magma Exor" },
    ["325177,315332,5830"] = { SpawnAs="Pest_Volatile", Variant="Signal Pest", NoPatrol=true }, 
    ["329137,316629,8328"] = { SpawnAs="Pest_Magma", Variant="Magma Pest" },

    
    -- Rise
    ["-150389,-323377,320"] = { Variant="Dioscoridian" },
    ["-150224,-322401,320"] = { SpawnAs="Grunt_Guard_Offduty", Variant="Velites Guard" },
    ["-150025,-322299,320"] = { Variant="Suppressor Grunt", Count=3, VariantLimit=1 },
    ["-147155,-322761,320"] = { Variant="Skirmisher", Count=2 },
    ["-150763,-323722,900"] = { Variant="Suppressor Grunt", 
                              Phases = { { Hard=true, Count=2 } }},
    ["-148988,-322899,1140"] = { Variant="Commander" },
    ["-146413,-325496,900"] = { Variant="Dioscoridian", Count=2 },
    ["-148933,-326965,900"] = { Variant="Suppressor Grunt",
                              Phases = { { Hard=true, Count=2 } }},
    ["-148783,-323771,2190"] = { SpawnAs="Trooper", Variant="Centurion Grunt" },
    ["-148377,-322580,2300"] = { SpawnAs="Grunt_Guard", Variant="Grenadier Guard", Count=2 },
    ["-148034,-322557,2300"] = { Variant="Dioscoridian" },
    ["-148504,-321762,2300"] = { Variant="Flask Rat", Count=3, VariantLimit=2 },
    ["-147551,-322103,1485"] = { Variant="Twilight Sniper" },
    ["-149830,-322066,1485"] = { Variant="Tracker Sniper" },
    ["-151220,-323829,900"] = { Variant="Sweeper", 
                              Phases =  { { Hard=true, Count=2, VariantLimit=1 } }},
    
    
-- =======================================================================
-- SECURITY VIGNETTES
-- =======================================================================

    -- Canaan
    ["143003,25338,50196"]  = { Variant="Canaan Lumberjack"},
    ["142822,17625,49585"] = { Variant="Canaan Fanatic",
                               Phases={{ Hard=true, Count=2, VariantLimit=1 }} },
    ["152050,19141,50385"] = { Variant="Canaan Fanatic",
                               Phases={ { StoryMin=45, Variant="Chosen Canaan Fanatic" },
                                        { Hard=true, StoryMin=45, Variant="Chosen Canaan Fanatic", Count=2, VariantLimit=1 } }},
    ["150643,15143,50567"] = { Phases={ { Hard=true, Count=2 } }}, -- Pillager_Musketeer
    ["149625,25374,50385"] = { Phases={ {Variant="Canaan Fanatic"}, {StoryMin=45, Variant="Chosen Canaan Fanatic"} } },
    ["149083,27240,50812"] = { Variant="Canaan Marksman" },
    ["142987,41697,51942"] = { Variant="Canaan Marksman" },
    ["140705,40897,51897"] = { Variant="Canaan Marksman" },
    ["146452,35935,50983"] = { Variant="Canaan Marksman",
                               Phases={ { Hard=true, Count=2, VariantLimit=1 } }},
    ["150991,24231,50368"] = { Hard=true, SpawnAs="Pillager_Farmer", Variant="Chosen Canaan Farmer" },
    ["146359,14770,50490"] = { Variant="Canaan Farmer", 
                               Phases={ { StoryMin=45, Variant="Chosen Canaan Farmer" },
                                        { Hard=true, Variant="Chosen Canaan Farmer", Count=2, VariantLimit=1 } }},
    ["146724,17358,50556"] = { Variant="Canaan Farmer", 
                               Phases={ { StoryMin=45, Variant="Chosen Canaan Farmer" },
                                        { Hard=true, StoryMin=45, Variant="Chosen Canaan Farmer", Count=2, VariantLimit=1 } }},
    ["147730,18174,50563"] = { Variant="Canaan Farmer" },
    ["151867,16614,50430"] = { Variant="Canaan Farmer", Count=2 },
    ["151122,18749,50447"] = { Variant="Canaan Farmer",
                               Phases={ {StoryMin=45, Variant="Chosen Canaan Farmer"} }},
    ["146300,23507,50696"] = { Variant="Canaan Farmer",
                               Phases={ { Hard=true, Variant="Chosen Canaan Farmer"}, 
                                        {StoryMin=45, Variant="Chosen Canaan Farmer"} }},
    ["144042,30037,50952"] = { Hard=true, Variant="Canaan Marksman" }, 
    ["152624,27105,50368"] = { Hard=true, Count=2 },
    ["152248,35157,50943"] = { Variant="Canaan Lumberjack", 
                               Phases = { { Hard=true, Count=3 } }},
    ["149208,23821,50385"] = { Variant="Canaan Farmer" },
    ["148506,24864,50382"] = { Phases={ {Variant="Canaan Farmer"}, {StoryMin=45, Variant="Chosen Canaan Farmer"} } },
    ["147502,31398,50779"] = { Phases={ {Variant="Canaan Farmer"}, {StoryMin=45, Variant="Chosen Canaan Farmer"} } },
    ["146256,34578,50641"] = { Variant="Canaan Farmer" },
    ["140405,40417,50769"] = { Variant="Canaan Farmer",
                               Phases={ { Hard=true, Variant="Chosen Canaan Farmer" } }},
    ["140398,38405,51016"] = { Variant="Canaan Fanatic",
                               Phases={ { Hard=true, Variant="Chosen Canaan Fanatic" }, 
                                        { StoryMin=45, Variant="Chosen Canaan Fanatic" } }},
    ["157258,34384,52378"] = { Variant="Canaan Fanatic", Count=2, VariantLimit=1,
                                Phases = { { Hard=true, Count=3 } }},
    ["144733,42610,51902"] = { Variant="Canaan Lumberjack",
                               Phases={ { Hard=true, Variant="Chosen Canaan Miner" }, 
                                        { StoryMin=45, Variant="Chosen Canaan Miner" } }},
    ["144518,28403,50368"] = { Phases={ {Variant="Canaan Farmer"}, {StoryMin=45, Variant="Chosen Canaan Farmer"} } },
    ["138048,41485,51898"] = { SpawnAs="Pillager_Torchbearer", Variant="Canaan Fanatic" },
    ["153775,31586,52579"] = { SpawnAs="Pillager_Torchbearer", Variant="Canaan Fanatic" },
    ["154437,31633,52579"] = { Variant="Canaan Fanatic" },
    ["154054,31976,52579"] = { Variant="Chosen Canaan Miner" },
    ["154248,31132,52579"] = { SpawnAs="Pillager_Torchbearer", Variant="Canaan Fanatic" },
    ["154764,52242,54200"] = { Hard=true, Count=2 },
    ["158188,51225,54200"] = { Count=2, Phases={ { Hard=true, Count=3 } }},
    ["153499,30962,52669"] = { Variant="Niketas" },
    ["152623,27949,50368"] = { Disabled=true },
    --["148308,29374,50904"] = {}, -- Pillager_Preacher
    --["149478,14929,51156"] = {}, --Pillager_Musketeer
    

    -- NightRealm: See PlacedSpawns

-- =======================================================================
-- HYDROPLANT
-- =======================================================================

    -- Entrance
    ["-26167,2220,-192"] = { Variant="Hive Sow", StoryMin=50 },
    ["-25437,2551,-192"] = { Variant="Laser Pest", StoryMin=50 },
    ["-28648,1059,-792"] = { Variant="Laser Pest", Count=2, StoryMin=50 },
    -- ["36543,3732,200"] = { SpawnAs="Exor_Monk", Variant="Exorrior" }, --niche
    ["-38384,3155,500"] = { Variant="Sweeper", StoryMin=50 }, 
    ["-37027,3236,500"] = { Variant="Suppressor Grunt", StoryMin=50 }, 
    ["-37892,4627,500"] = { Hard=true, Variant="Skirmisher", Count=2, VariantLimit=1, StoryMin=50 },
    ["-38760,4044,-100"] = { Variant="Sweeper", Count=2, VariantLimit=1, StoryMin=50 }, 
    ["-38890,4458,-100"] = { Variant="Skirmisher", StoryMin=50 }, 
    ["-37090,3120,1200"] = { Variant="Tracer Sniper", StoryMin=50 },
    ["-33098,1724,1747"] = { Variant="Tracer Sniper", StoryMin=50 },
    ["-37448,-2743,737"] = { Variant="Sweeper", Count=2 },
    ["-29702,1003,200"] = { Disabled=true }, --Pest_Electro
    ["-38305,8771,1120"] = { Disabled=true }, 
    ["-37366,6540,1100"] = { Disabled=true }, 
    -- ["-27753,851,200"] = {}, --Pest_Electro    
    
    -- Electrical Station
    ["-39774,5202,500"] = { Variant="Suppressor Grunt", StoryMin=50,
                           Phases = { { Hard=true, Count=2 } }}, 
    ["-41302,4529,500"] = { Variant="Suppressor Grunt", Count=2, StoryMin=50 }, 
    ["-41764,5596,800"] = { Variant="Flask Rat", StoryMin=50 }, 
    ["-36995,3181,1198"] = { Variant="Rocket Rat", StoryMin=50 }, 
    ["-39027,4070,-100"] = { Variant="Trident", StoryMin=50 }, 
    ["-41380,4990,1200"] = { SpawnAs="Robot_Defense", Variant="Deatomizer Bot", StoryMin=50 }, 
    
    -- Waterfall Entrances
    ["-44126,7068,550"] = { Disabled=true },
    ["-47068,11160,939"] = { Disabled=true }, -- Grunt_Medic
    ["-46863,11044,939"] = { Disabled=true }, -- Grunt
    
    -- Waterfall 
    ["-48608,7613,337"] = { Variant="Hive Sow", StoryMin=50 },
    ["-46392,8321,337"] = { Variant="Exorrior", StoryMin=50,
                            Phases = { { Hard=true, Variant="Exorrior Magus" } }},
    ["-46376,8181,937"] = { Variant="Exor Displacer", StoryMin=50 },
    ["-46635,11156,2237"] = { Variant="Exor Displacer", StoryMin=50,
                            Phases = { { Hard=true, Count=2, VariantLimit=1 } }},
    ["-50185,6072,1237"] = { Variant="Exorrior Magus", StoryMin=50 },
    ["-49107,5814,640"] = { Variant="Telepest", StoryMin=50 },
    ["-51073,6589,637"] = { Variant="Laser Pest", StoryMin=50 },
    ["-41105,18745,2016"] = { SpawnAs="Robot_Defense", StoryMin=50,
                              Phases = { { Hard=true, Variant="Deatomizer Bot", Count=2 } }},
    ["-50055,8217,737"] = { SpawnAs="Pest_Electro", Variant="Telepest", StoryMin=53 },
    ["-50107,7834,737"] = { SpawnAs="Pest_Electro", Variant="Telepest", StoryMin=53 },
    ["-40195,13922,500"] = { StoryMin=54, StoryMax=59, Disabled=true }, --Robot_Defense, disabled during event    
    ["-50162,5151,1937"] = { SpawnAs="Pest_Electro" },
    ["-49793,5595,1937"] = { Disabled=true },

    -- Hydroplant underground
    ["-38314,16535,100"] = { Disabled=true }, -- Keep Artillery Bot from constantly aiming for this
    ["-40396,17171,100"] = { SpawnAs="Exor_Armored",
                             Phases= {{ Hard=true, Count=2 }} }, 

    -- Hydroplant End Entrance
    ["-37218,18636,1100"] = { Count=2, StoryMin=50 }, --Grunt
    ["-36955,20688,2000"] = { SpawnAs="Pest_Leyak", Variant="Leyak Menace", StoryMin=50 },
    ["-37410,20441,2700"] = { Variant="Sweeper", Count=2, VariantLimit=1, NoPatrol=true, StoryMin=50 }, 
    ["-34014,21690,2200"] = { SpawnAs="Exor_Armored", Variant="Exor Displacer", Count=2, VariantLimit=1, StoryMin=50, 
                              Phases = {{ Hard=true, VariantLimit=2 }} },
    ["-34254,21901,2200"] = { SpawnAs="Exor_Armored", Variant="Exor Repeller", StoryMin=50 },
    ["-38608,15349,800"] = { Disabled=true }, -- LabRat
    ["-37033,23903,2300"] = { Disabled=true }, --Sniper
    ["-38436,19863,2700"] = { NoPatrol=true },
    -- ["-41183,8762,500"] = { Variant="" }, --Defense Bot (indoor)
    -- ["-40195,13922,500"] = { Variant="" }, --Defense Bot
    -- ["-33238,23182,700"] = { Variant="Deatomizer Bot", StoryMin=50 }, --Robot_Defense (Tower)
    ["-41964,15046,1200"] = { Phases = {{ Disabled=true },
                                        { StoryMin=60, Variant="Deatomizer Bot", Count=1 },
                                        { Hard=true, StoryMin=60, Variant="Deatomizer Bot", Count=2 } }}, --Defense Bot
    ["-33445,21597,565"] = { Disabled=true }, --Electro Pest
    ["-35223,18825,506"] = { Disabled=true }, --Electro Pest
    ["-40220,17495,500"] = { Disabled=true }, --Sow
    ["-40107,16817,500"] = { Disabled=true }, --Exor_Armored

-- =======================================================================
-- HYDROPLANT VIGNETTES
-- =======================================================================

    -- Voussior Lower
    ["-275906,75701,-7890"] = { Hard=true, Variant="Groupe Frostpack", Count=2, VariantLimit=1 },
    ["-275751,76493,-7890"] = { Hard=true, Variant="Groupe Breacher" },

    -- Voussior Upper
    ["-277498,76569,-1090"] = { SpawnAs="Groupe_Shotgun", Variant="Groupe Breacher" },
    ["-276605,79712,-2090"] = { Variant="Groupe Rookram" },
    ["-277150,79393,-2090"] = { Variant="Groupe Frostpack", 
                                Phases = { { Hard=true, Count=2 } }},
    ["-279136,78850,-1140"] = { Variant="Groupe Frostpack" },
    ["-274581,78119,-1890"] = { Variant="Groupe Frostpack", Count=2 },

    -- Slopes
    ["-273371,93418,-7427"] = { SpawnAs="Grunt_Sniper", Variant="Groupe Sniper" },
    ["-272988,93952,-8118"] = { Variant="Groupe Breacher" },
    ["-272662,93662,-8143"] = { Variant="Groupe Frostpack", 
                               Phases = { { Hard=true, Count=3, VariantLimit=2 } }},
    ["272662,93446,8144"] = { Variant="Groupe Rookram" },
    ["-270572,86725,-9895"] = { Variant="Groupe Breacher" },
    ["-271680,86437,-9899"] = { Variant="Blizzard Yeti", 
                                Phases = { { Hard=true, Count=2 } }},

    -- Voussior Lower
    ["-267852,84623,-11671"] = { Variant="Groupe Rookram" },
    ["-267399,83873,-11671"] = { Variant="Groupe Frostpack", Count=2 },
    ["-267570,83940,-11671"] = { SpawnAs="Grunt_Sniper", Variant="Groupe Sniper" },
    ["278810,78538,13391"] = { Variant="Groupe Frostpack" },
    ["-266082,84912,-11760"] = { Variant="Groupe Rookram" },
    ["-266878,85187,-11760"] = { SpawnAs="Groupe_Grunt", Variant="Groupe Frostpack" },
    ["-267944,82244,-11110"] = { Variant="Groupe Breacher" },
    ["-267922,82649,-11110"] = { SpawnAs="Groupe_Shotgun", Variant="Groupe Breacher" },
    
    -- Yeti Cave
    ["-268810,78538,-13391"] = { Variant="Groupe Frostpack" },    
    ["-273258,76701,-13700"] = { Variant="Blizzard Yeti", 
                               Phases = { { Hard=true, Count=2 } }},


    
-- =======================================================================
-- POWER SERVICES
-- =======================================================================

    -- Power house
    ["-30418,1447,-9312"] = { Variant="Telepest", Count=2, VariantLimit=1 },

    -- Orange bloom
    ["-24543,3468,-10212"] = { Hard=true, Variant="Exorrior", Count=2, VariantLimit=1 },
    ["-25833,5254,-10200"] = { Variant="Razor Pest", Count=2, VariantLimit=1,
                             Phases = { { Hard=true, Count=4, VariantLimit=2 } }},


    -- Blue bloom
    ["-32744,12988,-10500"] = { SpawnAs="Peccary_Electro", Variant="Electro Peccary", Count=2 },
    ["-30892,14234,-10032"] = { Variant="Charge Peccary", Count=2 },
    ["-27061,13458,-10112"] = { Variant="Anterazor Pest" },
    ["-25509,14376,-9723"] = { Variant="Antegrav Pest", Count=2 },
    ["-25128,15875,-10172"] = { SpawnAs="Peccary", Variant="Phase Peccary",
                                Phases = { { Hard=true, Count=2 } }},
    ["-25673,16749,-9000"] = { SpawnAs="Peccary_Mushroom" },

    -- Purple bloom    
    ["-22229,12660,-9900"] = { SpawnAs="Exor_Armored", Variant="Exor Displacer",
                                Phases = { { Hard=true, Count=2 } }},

    ["-34648,17836,-11318"] = { SpawnAs="Exor", Variant="Antefire Exor" },
    ["-35865,22341,-10536"] = { SpawnAs="Pest_Enlightened", Variant="Enlightened Pest" },


-- =======================================================================
-- POWER SERVICES VIGNETTES - EXOR VILLAGE
-- =======================================================================

    -- Waterfall
    ["24830,-328993,448"] = { Variant="Hive Sow" },

    -- Pest pool    
    ["28539,-332310,761"] = { Variant="Exorrior", 
                             Phases= { { Hard=true, Count=3 } }},
    ["28025,-332166,692"] = { SpawnAs="Peccary_Armored", Variant="Armored Peccary" }, --Sow
    ["29629,-328541,656"] = { SpawnAs="Pest_Volatile", Variant="Signal Pest" },
    ["29815,-328473,656"] = { Variant="Razor Pest" },
    ["30208,-328581,670"] = { Variant="Chonky Pest" },
    ["30463,-328876,591"] = { SpawnAs="Pest_Carbonated" },
    ["30377,-328145,735"] = { Hard=true, Variant="Exor Dislocator", Count=2, VariantLimit=1 },
    ["29876,-330647,624"] = { Hard=true, Variant="Hive Sow" },
    ["32893,-332930,609"] = { Variant="Exor Magus", Count=2, VariantLimit=1,  
                             Phases= { { Hard=true, Count=3 } }},

    -- Intersection (Outpost-Bridge-Bonepile)
    ["31231,-331537,726"] = { Variant="Exor Spiritwalker", NoPatrol=true },
    ["24770,-335426,-447"] = { SpawnAs="Exor" },
    
    -- Outpost
    ["32288,-332739,639"] = { Variant="Hive Sow",
                             Phases= { { Hard=true, Count=3, VariantLimit=1 } }},

    -- Bone Pile
    ["33375,-338513,-93"] = { Variant="Exor Spiritwalker" },
    ["30294,-338077,1424"] = { Variant="Hive Sow", Count=2, VariantLimit=1,
                              Phases= {{ Hard=true, Count=4, VariantLimit=2 }} },
    ["29661,-337911,1450"] = { SpawnAs="Pest_Volatile", Variant="Chonky Signal Pest",
                              Phases= {{ Hard=true, Count=2 }} },
    ["29146,-338535,1436"] = { Hard=true, Variant="Exorrior Magus" },

    -- Chieftain Hut    
    ["29237,-334459,1860"] = { Variant="Exor Spiritwalker" },
    ["29833,-334459,1860"] = { Variant="Exor Spiritwalker" },

    -- South walkway
    ["17850,-334378,1017"] = { Hard=true, Variant="Hive Sow", Count=2 },

    -- South corner
    ["21498,-338334,878"] = { SpawnAs="Peccary", Variant="Carbunccary" },
    ["25580,-339022,1540"] = { Variant="Exor Repeller" },
    ["25962,-338668,1678"] = { Variant="Exorrior Magus",
                              Phases= {{ Hard=true, Count=2 }} },

    ["31886,-334881,613"] = { Disabled=true }, --Sow
    
-- =======================================================================
-- REACTORS
-- =======================================================================

    ------------------------------------------
    -- DUSK
    ------------------------------------------
    -- Entryway
    ["-14221,31755,-16200"] = { Variant="Suppressor Grunt" },
    ["-13589,27200,-16200"] = { Variant="Exor Spiritwalker" },
    ["-13608,27448,-16200"] = { Hard=true, SpawnAs="Exor_Pikeman", Variant="Exor Spiritwalker" },
    ["-17046,31229,-16200"] = { SpawnAs="Grunt_Captain", Variant="Commander" },    
    ["-17221,31755,-16200"] = { Disabled=true },
    -- ["-16582,32297,-16150"] = { }, -- Grunt_Sapper

    -- Lobby
    ["-15456,38933,-15800"] = { SpawnAs="Gatekeeper_MageEye", Variant="Warden Eye", StoryMin=71,
                              Phases= {{ Hard=true, Count=2 } }},
    ["-19626,40394,-15800"] = { Phases={ { StoryMin=71, Variant="Beholder Mage" },
                                         { Hard=true, Count=2 },
                                         { Hard=true, StoryMin=71, Variant="Beholder Mage", Count=2, VariantLimit=1 } }},
    ["-17118,42004,-15100"] = { Hard=true, Count=3 },
    ["-14783,39380,-15000"] = { Variant="Antevolatile Pest" },
    ["-21298,38310,-15799"] = { Hard=true, Variant="Rocket Rat", Count=2, VariantLimit=1 },
    ["-12229,41159,-15000"] = { SpawnAs="Gatekeeper_Mage", Variant="Barrier Mage", NoPatrol=true },
    ["-18731,37695,-15100"] = { Disabled=true }, --Pest

    -- Cafeteria Corner
    ["-23919,41617,-15300"] = { Variant="Antevolatile Pest", Count=2, VariantLimit=1,
                                Phases= {{ Hard=true, Count=3, VariantLimit=2}} },
    ["-25712,40828,-15300"] = { SpawnAs="Peccary_Mushroom" },
    ["-23689,43481,-15300"] = { Variant="Pestilence" },

    -- Medical Clinic    
    ["-23799,39890,-15300"] = { Variant="Antevolatile Pest",
                                Phases= {{ Hard=true, Count=3 }} },
    ["-22856,38829,-15300"] = { Variant="Neophyte Trainer",
                                Phases= {{ Hard=true, Count=2, VariantLimit=1 }} },

    -- Office Entrance    
    ["-13184,41842,-15000"] = { Variant="Signal Pest" },

    -- Offices
    ["-15484,41976,-15000"] = { Hard=true, Variant="Exor Hunter" },
    ["-14634,45849,-15000"] = { SpawnAs="Peccary_Volatile", Variant="Volatile Peccary",
                                Phases= {{ Hard=true, Count=2, VariantLimit=1 }} },
    ["-16389,42024,-15100"] = { Disabled=true },
    ["-16295,42782,-14800"] = { SpawnAs="Peccary_Volatile", Variant="Volatile Peccary" },

    -- Offices - Locked
    ["-12968,43495,-14307"] = { SpawnAs="Pest_Volatile" },
    ["-12970,42947,-15000"] = { Variant="Laser Pest" },
    ["-11494,44208,-14888"] = { Variant="Anterazor Pest" },

    -- Control Room
    ["-18108,46108,-14900"] = { Hard=true, Variant="Acidic Exor", Count=2, VariantLimit=1 },
    ["-11825,42571,-15000"] = { Variant="Hive Sow", Count=2, VariantLimit=1 },
    ["-11952,42880,-15000"] = { SpawnAs="Pest_Volatile", Variant="Volatile Pest" },
    ["-11806,45092,-15000"] = { Hard=true, Count=4 },

    -- Hallway to Reactor Core
    ["-19273,48772,-15300"] = { SpawnAs="Peccary_Volatile", Variant="Volatile Peccary",
                                Phases= {{ Hard=true, Count=2 }} },
    ["-18570,44019,-15800"] = { Variant="Exor Hunter",
                                Phases= {{ Hard=true, Count=2, VariantLimit=1 }} },

    -- Reactor Core
    ["-23126,50669,-15000"] = { Hard=true, Variant="Super Sapper" },
    ["-23370,50195,-15000"] = { Hard=true, Variant="Super Sapper" },

    
    ------------------------------------------
    -- CLOUD
    ------------------------------------------
    -- Outdoors
    ["631,10672,-17476"] = { Variant="Rocket Rat" },
    ["13088,23076,-17659"] = { Count=2 },

    -- Tram tower
    ["-656,6136,-15576"] = { Variant="Deatomizer Bot", NoPatrol=true, StoryMax=74 },
    ["564,16861,-16800"] = { Hard=true, SpawnAs="Grunt_Shotgun", Variant="Sweeper" },
    ["373,15574,-16300"] = { Variant="Grenadier Guard", 
                             Phases= {{ Hard=true, Count=2, VariantLimit=1 }} },
    ["9517,24156,-16877"] = { SpawnAs="Grunt_Sapper", Variant="Mad Rat" },
    ["8710,22488,-17639"] = { Variant="Rocket Rat",
                              Phases= {{ Hard=true, Count=2, VariantLimit=1 }} },

    -- Jotun Hill
    ["1550,3335,15076"] = { Hard=true, Count=3 },
    ["-1882,580,-14516"] = { Variant="Artillery Bot" },

    -- Plant Rooftop
    ["3968,6511,-13877"] = { Variant="Neophyte Trainer" },
    ["8135,10245,-14176"] = { Variant="Rocket Rat", Count=2, VariantLimit=1 },
    ["8284,11393,-14476"] = { Hard=true, Variant="Dioscoridian", Count=2 },
    ["7915,11209,-14776"] = { Variant="Skirmisher", Count=2, VariantLimit=1, 
                              Phases= {{ Hard=true, Count=3, VariantLimit=2 }} },
    ["9815,12102,-14175"] = { SpawnAs="Peccary", Variant="Jotun Steed", StoryMin=72 },

    -- Plant Staircase
    ["16891,12885,-14475"] = { Hard=true, SpawnAs="Trooper", Variant="Centurion Grunt" },
    ["16685,12661,-15975"] = { Phases = {{ SpawnAs="Grunt_Shotgun" },
                                        { StoryMin=72, SpawnAs="Gatekeeper_Heavy" } }},
    ["16434,13511,-15075"] = { Variant="Grenadier Guard",
                              Phases = {{ StoryMin=72, SpawnAs="Gatekeeper_Phyter", Variant="Neophyte Trainer" } }},
    ["16673,14066,-18375"] = { Hard=true, Variant="Skirmisher", Count=2 },
    ["15959,13077,-16275"] = { Variant="Suppressor Grunt",
                              Phases= {{ Hard=true, Count=2 }} },

    -- Plant Floor Outdoors
    ["19640,13809,-18597"] = { Hard=true, SpawnAs="Grunt_Captain", Variant="Signifer", Count=2 },
    ["20248,15627,-18208"] = { Count=3 },
    ["10830,18182,-17480"] = { Hard=true, Count=3 },
    ["8703,15642,-16276"] = { Disabled=true },
    ["8647,15435,-16276"] = { Disabled=true },

    -- Plant MG Nest
    ["17887,19483,-17336"] = { Variant="Signifer",
                              Phases= {{ Hard=true, Count=2 }} },
    ["17516,19912,-17336"] = { Variant="Skirmisher", Count=2, VariantLimit=1 },

    -- Plant Sewers
    ["10585,14970,-16876"] = { Hard=true, Variant="Barrier Mage", Count=2, VariantLimit=1 },
    ["11058,15334,-17492"] = { Variant="Neophyte Trainer" },
    ["9029,17047,-17476"] = { Hard=true, Count=2 },
    ["10050,16748,-16876"] = { Variant="Barrier Mage" },
    -- ["10068,12515,-16876"] = { Hard=true, Count=2 },

    -- Plant Reactor
    ["8540,8776,-17476"] = { Hard=true, Variant="Signifer" },
    ["8393,8688,-17476"] = { Variant="Mad Rat" },


    
    ------------------------------------------
    -- MIST
    ------------------------------------------
    -- Mist entrance
    ["-546,23896,-17400"] = { StoryMin=72, SpawnAs="Exor", Variant="Antegrav Exor",
                              Phases= {{ Hard=true, Count=3 }} },
    ["-76,26458,-15229"] = { Hard=true, Count=2 },
    ["1490,27383,-15882"] = { Variant="Antevolatile Pest" },
    ["4291,28192,-16058"] = { Hard=true, SpawnAs="Exor_Monk", Variant="Exor Shadow Monk", Count=2 },
    ["4947,31462,-15866"] = { SpawnAs="Peccary_Volatile", Variant="Volatile Peccary",
                              Phases= {{ Hard=true, Count=2 }} },
    ["5314,30254,-15558"] = { Hard=true, Variant="Exor Spiritwalker" },
    ["6170,32279,-16600"] = { SpawnAs="Exor_Monk", Variant="Exorrior",
                              Phases= {{ Hard=true, Variant="Exorrior Magus" }} },

    -- Turbine 01
    ["9187,37930,-16107"] = { Variant="Antevolatile Pest" },
    ["9539,37869,-16099"] = { SpawnAs="Peccary_Volatile", Variant="Volatile Peccary" },
    ["8195,34608,-16007"] = { Variant="Pestilence" },
    ["9923,36580,-15776"] = { Variant="Pestilence",
                              Phases= {{ Hard=true, Count=3, VariantLimit=2 }} },
    ["6779,37509,-14307"] = { SpawnAs="Exor", Variant="Antegrav Exor",
                              Phases= {{ Hard=true, Count=2, VariantLimit=1 }} },
    ["7723,36528,-15807"] = { StoryMin=73, SpawnAs="Robot_Corrupt", NoPatrol=true },

    -- Control Center
    ["12100,35839,-14307"] = { SpawnAs="Exor_Volatile", Variant="Exor Hunter" },
    ["11159,35218,-14607"] = { Variant="Pestilence" },
    ["10866,35686,-14607"] = { SpawnAs="Peccary_Volatile", Variant="Volatile Peccary" },
    ["11057,35962,-14307"] = { Hard=true, Count=4 },
    
    -- Roadway
    ["14414,36104,-15797"] = { Hard=true, Count=2 },
    ["16948,34626,-15907"] = { SpawnAs="Exor",
                              Phases= {{ Hard=true, Variant="Antegrav Exor", Count=3 }} },
    ["13188,32301,-15807"] = { SpawnAs="Exor_Volatile", Variant="Acidic Exor" },
    ["11709,34157,-15607"] = { SpawnAs="Grunt_Sapper", Variant="Mad Rat",
                              Phases= {{ Hard=true, Variant="Antegrav Exor", Count=2 }} },
    ["15956,34940,-15907"] = { Variant="Antevolatile Pest" },
    ["15069,31167,-15797"] = { Variant="Pestilence" },
    ["14798,31709,-15797"] = { SpawnAs="Robot_Corrupt" },

    -- Turbine02
    ["18977,34473,-15807"] = { SpawnAs="Exor_Volatile", Variant="Acidic Exor" },
    ["19020,36619,-14607"] = { Variant="Exor Hunter" },

    -- Reactor core
    ["14231,38798,-14607"] = { Hard=true, Count=2 },
    ["10290,38894,-15807"] = { Variant="Acidic Exor",
                              Phases= {{ Hard=true, Count=2 }} },
    ["13092,38459,-15807"] = { Variant="Exor Hunter" },

    -- Pool
    ["11930,32758,-15482"] = { SpawnAs="Exor_Armored", Variant="Exor Repeller" },
    ["10522,31951,-17007"] = { SpawnAs="Exor_Armored", Variant="Exor Dislocator" },
    ["11133,29915,-17007"] = { Hard=true, SpawnAs="Exor_Armored", Variant="Exor Displacer" },
    ["12332,30784,-17007"] = { Hard=true, SpawnAs="Exor_Monk", Variant="Exorrior Magus" },
    ["12893,32500,-16207"] = { SpawnAs="Skink_Mushroom", NoPatrol=true },

    -- Lower floor    
    ["11844,32887,-17107"] = { Variant="Antevolatile Pest",
                              Phases= {{ Hard=true, Count=2 }} },
    ["13459,32193,-17107"] = { Variant="Pestilence" },
    ["13745,32917,-17207"] = { Hard=true, SpawnAs="Peccary_Volatile", Variant="Volatile Peccary" },
    ["15375,32520,-17207"] = { Variant="Exor Spiritwalker" },
    ["15295,32050,-17207"] = { Variant="Exor Spiritwalker" },
    ["15628,32575,-17207"] = { Variant="Hive Sow",
                              Phases= {{ Hard=true, Count=2 }} },
    ["13588,34753,-17057"] = { SpawnAs="Exor_Armored",
                              Phases= {{ Hard=true, Variant="Exor Repeller", Count=2, VariantLimit=1 }} },
    ["15142,32036,-17207"] = { Disabled=true },
    ["12753,33524,-17307"] = { Disabled=true },
    ["11964,33089,-17107"] = { Disabled=true },
    

    ------------------------------------------
    -- GALE
    ------------------------------------------
    -- Pre-entrance
    ["174,28753,-17100"] = { Hard=true, Variant="Exor Dislocator", Count=2 },

    -- Entrance

    -- WAR Trench. Both factions' spawners are DisablePermanentlyFlag'd by the S2War "pushed
    -- back" triggers (Reactors_S2War_GKLoss / _OrderLoss) - NoLossFlag keeps them respawning.
    ["3775,44679,-16093"] = { Variant="Neophyte Trainer", Count=2, VariantLimit=1, NoLossFlag=true },
    ["3960,44662,-16095"] = { Count=2, NoLossFlag=true },
    ["3838,44525,-16095"] = { SpawnAs="Gatekeeper_Chieftain", NoLossFlag=true },
    ["4078,44500,-16095"] = { SpawnAs="Gatekeeper_Mage", Variant="Beholder Mage", NoLossFlag=true },
    ["3436,46769,-16045"] = { SpawnAs="Peccary", Variant="Jotun Steed", NoLossFlag=true },
    ["343,45480,-16025"] = { SpawnAs="Grunt_Shotgun", Variant="Sweeper", Count=2, NoLossFlag=true },
    ["562,47638,-15650"] = { Variant="Rocket Rat", Count=2, VariantLimit=1, NoLossFlag=true },
    ["-171,46633,-16095"] = { Variant="Centurion Grunt", NoLossFlag=true },
    ["-279,46784,-16095"] = { Variant="Centurion Grunt", NoLossFlag=true },
    ["-673,46898,-16095"] = { SpawnAs="Grunt_Medic", Variant="Dioscoridian", Count=2, NoLossFlag=true },
    ["-467,46873,-16095"] = { Hard=true, SpawnAs="Grunt_Captain", Variant="Signifer", NoLossFlag=true },
    ["1173,46804,-16095"] = { SpawnAs="Grunt_Shotgun", Variant="Skirmisher", NoLossFlag=true },
    ["1103,46682,-16093"] = { SpawnAs="Trooper", Variant="Centurion Grunt", NoLossFlag=true,
                              Phases={{ Hard=true, Count=2 }} },

    -- Order - Fuel Room
    -- ["-5649,47132,-15495"] = { Sniper },
    ["-4321,50349,-16495"] = { Variant="Trident",
                               Phases= {{ Hard=true, Variant="Signifer" }} },
    ["-4151,50392,-16495"] = { Variant="Skirmisher" },
    ["-793,50302,-16445"] = { SpawnAs="Gatekeeper_Chieftain" },
    ["-2190,51070,-16095"] = { SpawnAs="Exor_Armored", Variant="Exor Displacer" },
    
    -- Order - Sniper Nest
    ["-4847,48815,-15445"] = { Variant="Groupe Sniper" },
    ["-4806,48094,-15445"] = { Variant="Tracer Sniper" },

    -- Order - Lower Offices
    ["79,46476,-16615"] = { Variant="Pestilence" },
    ["-1118,45201,-16495"] = { Variant="Super Sapper"},
    ["1061,46255,-16795"] = { SpawnAs="Trooper", Variant="Centurion Grunt" },
    -- ["-2440,44161,-16795"] = {}, --Grunt_Shotgun
    ["1503,47856,-16895"] = { Disabled=true }, --Zombie

    -- Order - Reactor entrance
    ["1506,49091,-16020"] = { Hard=true, Variant="Neophyte Trainer", Count=2, VariantLimit=1 },
    -- ["1413,49325,-16020"] = {}, --Gatekeeper_Chieftain

    -- GK - pool room    
    ["2893,43216,-16395"] = { SpawnAs="Robot_Corrupt", NoPatrol=true },
    ["3992,39738,-16395"] = { SpawnAs="Pest_Volatile", Variant="Pestilence"},
    ["7325,42273,-15395"] = { Hard=true, Variant="Neophyte Trainer" },
    ["8195,44334,-15395"] = { Hard=true, Variant="Neophyte Trainer", Count=2, VariantLimit=1 },


    -- GK - pool room overlook
    ["4677,40371,-15395"] = { Variant="Neophyte Trainer"},
    ["3040,40709,-15395"] = { SpawnAs="Gatekeeper_MageEye", Variant="Warden Eye" },

    -- GK - Reactor Entrance    
    ["5428,46422,-15745"] = { SpawnAs="Peccary", Variant="Jotun Steed"},
    ["7287,46277,-15745"] = { Hard=true, Variant="Neophyte Trainer" },
    ["4957,45626,-15745"] = { Phases = { { Disabled=true },
                                         { Hard=true, Variant="Warden Eye" } }},
    
    -- Gale - Lower offices
    ["2846,45573,-16595"] = { Variant="Abjurer Mage", 
                              Phases = {{ Hard=true, Count=2, VariantLimit=1 }} },
    -- Gale - GK side
    ["1413,49325,6020"] = { Variant="Abjurer Mage"},
    ["6109,45058,-16095"] = { Variant="Beholder Mage"},
    ["4815,48324,-15815"] = { Variant="Esoteric Chieftain" },


    -- Gale - Central
    ["1894,48612,-15865"] = { Disabled=true }, --Phyter
    ["3497,51073,-15735"] = { Disabled=true }, --Phyter
    ["3016,48336,-16295"] = { Disabled=true }, --Chieftain
    
    -- Misc
    ["1175,40100,-15795"] = { Disabled=true }, --Pest
    ["-1048,46106,-16495"] = { Disabled=true }, --ElectroPest
    ["-2350,49325,-16445"] = { Disabled=true }, --Exor Cha
    ["-663,43189,-16895"] = { Disabled=true }, --Pest
    ["2338,42968,-17660"] = { Disabled=true }, --Zombie
    ["1042,47592,-17660"] = { Disabled=true }, --Zombie
    ["4799,40653,-16395"] = { Disabled=true }, --Pest
    ["5587,45770,-18957"] = { Disabled=true }, --Sow

    ------------------------------------------
    -- OTHER REACTOR HALLS
    ------------------------------------------

-- =======================================================================
-- REACTORS VIGNETTES - SHADOWGATE
-- =======================================================================

    -- Outside - Witch's Hut
    -- ["-311920,214397,1452"] = { Variant="" },
    ["-311386,218307,1307"] = { Variant="Plague Witch", NoPatrol=true,
                                Phases= {{ Hard=true, Count=2 }} },
    ["-311720,218127,1307"] = { Hard=true, Variant="Plague Witch", NoPatrol=true },
    ["-311338,218019,1312"] = { NoPatrol=true },
    ["-312679,220984,1044"] = { Hard=true, Variant="Warrior Witch", Count=3 },
    
    -- Swamp
    ["-324829,221284,1162"] = { Variant="Storm Witch", Count=2, VariantLimit=1 },
    
    -- Shadowgate Entrance
    ["-328720,209070,374"] = { Hard=true, Variant="Storm Witch", Count=2 },
    ["-337837,208727,696"] = { Variant="Warrior Witch", NoPatrol=true,
                               Phases = { { Hard=true, Count=2 } }},

    -- Compound
    ["-332714,212357,588"] = { Variant="Esoteric Chieftain" },
    ["-333967,208266,791"] = { NoPatrol=true },
    ["-330974,208909,606"] = { Phases = { { Disabled=true },
                                          { Hard=true, SpawnAs="Gatekeeper_Phyter", Count=3 } }}, -- Gatekeeper_Witch
    ["-329773,212084,710"] = { Phases = { { Disabled=true },
                                          { Hard=true } }}, -- Gatekeeper_Heavy, MG nest
    ["-331247,207414,710"] = { Phases = { { Disabled=true },
                                          { Hard=true, SpawnAs="Gatekeeper_Chieftain", Variant="Gatekeeper Warchief" } }}, -- Gatekeeper_Phyter, MG nest

    ["-328580,208655,482"] = { Disabled=true }, --Jotun MG nest
    
    -- Portal
    ["-340109,211191,1240"] = { SpawnAs="Gatekeeper_Witch", Variant="Warrior Witch" },
    ["-343417,212287,1617"] = { SpawnAs="Gatekeeper_Mage", Variant="Abjurer Mage" },
    ["-342099,210840,1640"] = { SpawnAs="Gatekeeper_Witch", Variant="Storm Witch" },
    ["-341033,212533,290"] = { Variant="Storm Witch" },
    ["-340661,212368,1290"] = { Variant="Jotun Rocketeer" },
    ["-339130,213382,300"] = { SpawnAs="Gatekeeper_Phyter", Variant="Neophyte Trainer" },
    ["-341632,214480,840"] = { SpawnAs="Gatekeeper_Mage", Variant="Abjurer Mage", NoPatrol=true }, -- Witch
    ["-342246,213752,840"] = { Variant="Storm Witch" },
    ["-339535,214141,823"] = { SpawnAs="Robot_Defense", Variant="Deatomizer Bot", NoPatrol=true },
    ["-339239,215703,1240"] = { SpawnAs="Gatekeeper_Chieftain", Variant="Esoteric Chieftain" },
    ["-341233,214195,290"] = { SpawnAs="Peccary", Variant="Jotun Steed" },

    
-- =======================================================================
-- PRAETORIUM
-- =======================================================================

    -- Entrance
    ["88607,27766,-2862"] = { Hard=true, Count=3 },

    -- Garage
    ["88864,21930,-3102"] = { Count=2 }, --LabRat_Mechanic
    ["88910,23522,-3102"] = { Hard=true, SpawnAs="Grunt_Sapper", Variant="Rocket Rat", Count=2, VariantLimit=1 }, --LabRat_Mechanic

    -- Lower level
    ["98700,25677,-3252"] = { Variant="Praetorium Sniper" },
    ["97038,21928,-3302"] = { SpawnAs="Grunt_Sapper", Variant="Rocket Rat", NoPatrol=true },
    ["95912,23324,-2532"] = { Variant="Grenadier Guard" },
    ["97713,22664,-3102"] = { SpawnAs="Grunt_Sapper", Variant="Rocket Rat" },
    ["95470,24940,-2582"] = { Variant="Tracer Sniper" },
    ["95626,25348,-2582"] = { Variant="Dioscoridian" },
    ["93531,21588,-3302"] = { Phases = { { Disabled=true },
                                         { Hard=true, SpawnAs="Trooper", Variant="Speculatores" } }},
    ["95013,20696,-2532"] = { Hard=true, SpawnAs="Grunt_Sapper", Variant="Rocket Rat" },
    ["93090,21953,-3302"] = { Disabled=true },
    -- ["95013,20696,-2532"] = { }, --Grunt
    
    -- Upper level - pre-library
    ["100666,29665,1048"] = { Hard=true, Variant="Salii", Count=2 },
    ["97248,25362,1188"] = { Hard=true, Variant="Signifer", Count=2, VariantLimit=1 },
    ["103662,31271,1148"] = { Hard=true, Variant="Salii" },
    ["103377,31386,1148"] = { Hard=true, SpawnAs="Grunt_Sapper", Variant="Mad Rat", Count=2 },
    ["92545,30375,1048"] = { Variant="Suppressor Grunt",
                             Phases= {{ Hard=true, Count=2 }} },
    ["92365,30375,1048"] = { Variant="Suppressor Grunt",
                             Phases= {{ Hard=true, Count=2 }} },
    ["98453,29539,1048"] = { Variant="Salii",
                             Phases= {{ Hard=true, Count=2 }} },

    -- Upper level - Control Spire
    ["98256,34416,2920"] = { Variant="Speculatores" },
    ["98511,33971,2920"] = { Variant="Signifer" },
    ["97947,35618,2970"] = { Variant="Salii" },
    
    --Library
    ["99606,32307,1148"] = { Variant="Salii" },
    ["102040,32434,1248"] = { Hard=true, SpawnAs="Interfector", Variant="Peremptor" },
    ["102563,32956,1148"] = { Variant="Salii" },
    ["99395,34237,736"] = { Variant="Salii" },
    ["102627,32381,188"] = { Variant="Salii" },
    ["105555,32359,528"] = { Variant="Salii" },
    ["100825,36271,1148"] = { Variant="Salii" },
    ["100602,36771,1148"] = { Variant="Salii" },
    ["103067,37995,1508"] = { Variant="Salii" },
    ["102147,37976,1508"] = { NoPatrol=true },
    ["105340,36985,1148"] = { Disabled=true },

    --Command Blockade

    -- Command Blockade, Upper
    -- The two posted Purifiers.
    --   * Event_INQ_PurifiedAssault's gate requires BOTH alive, and the event roots them
    --     in place for its duration (ModuleStory/Events).
    --   * NoPatrol keeps each one inside the event's 15m "is it still posted?" probe.
    ["105038,44632,1098"] = { SpawnAs="Grunt_FlameRat", Variant="Purifier", NoPatrol=true }, -- TrooperShield
    ["104022,44586,1098"] = { SpawnAs="Grunt_FlameRat", Variant="Purifier", NoPatrol=true }, -- Trooper
    ["102567,45296,1168"] = { Hard=true, SpawnAs="Grunt_Sniper", Variant="Praetorium Sniper", }, -- Captain
    -- ["105303,42698,1098"] = { Variant="Purifier", NoPatrol=true },
    -- ["103832,42698,1098"] = { Variant="Purifier", NoPatrol=true },
    ["105303,42698,1098"] = { Disabled=true },
    ["103832,42698,1098"] = { Disabled=true },
    ["103528,44889,1098"] = { Disabled=true }, -- Grunt
    ["104788,44743,1098"] = { Disabled=true }, -- Medic
    ["103673,44884,1196"] = { Disabled=true }, -- Sapper
    ["103355,44679,1098"] = { Disabled=true }, -- Grunt
    
    -- Command Blockade, Lower
    -- ["104597,41231,748"] = { Variant="" }, -- FlameRat
    ["104322,43559,748"] = { SpawnAs="Grunt_FlameRat", Variant="Purifier", NoPatrol=true }, -- TrooperShotgun
    ["104836,43567,748"] = { SpawnAs="Grunt_FlameRat", Variant="Purifier", NoPatrol=true }, -- TrooperShotgun
    ["104060,48226,1148"] = { Hard=true, Variant="Peremptor" },
    ["105125,48226,1148"] = { Hard=true, Variant="Peremptor" },

    -- Command Center
    ["107396,49930,998"] = { Hard=true, SpawnAs="Trooper", Variant="Speculatores"},
    ["105686,49176,998"] = { Hard=true, Variant="Speculatores", Count=2 },
    ["107271,48035,848"] = { Hard=true, Variant="Suppressor Grunt", Count=3, VariantLimit=1 },
    ["107703,48035,848"] = { Hard=true, SpawnAs="Grunt_Guard_Offduty", Variant="Velites Guard", Count=3, VariantLimit=1 },
    ["109136,49993,898"] = { Hard=true, Count=2 },
    
    ["107607,47031,848"] = { Variant="Dioscoridian"},
    ["107011,47761,1239"] = { Variant="Signifer"},
    ["106144,47042,998"] = { Variant="Shield Embolon"},
    ["106955,48447,848"] = { SpawnAs="Grunt_Captain", Variant="Signifer"},
    ["109536,48212,1628"] = { Variant="Praetorium Sniper"},
    ["108060,47784,1348"] = { SpawnAs="Trooper", Variant="Speculatores"},
    ["109166,47880,1348"] = { Variant="Salii"},

    -- Lockers
    ["101664,47468,1468"] = { Disabled=true }, -- Grunt offduty
    
-- =======================================================================
-- RESIDENCE
-- =======================================================================

    -- Lower levels

    -- Lower levels - Eatery
    ["-34875,32782,761"] = { Variant="Warrior Witch",
                             Phases= {{ Hard=true, Count=2, VariantLimit=1 }}},
    ["-33222,33724,811"] = { SpawnAs="Gatekeeper_Phyter", Variant="Neophyte Trainer" },
    ["-32729,34186,811"] = { Phases= { { Disabled=true }, 
                                       { Hard=true, SpawnAs="Gatekeeper_Mage" } }}, -- Pest_Snow
    --["-32586,36781,162"] = {}, --Gatekeeper_Heavy

    -- Lower levels - Maintainence
    ["-32989,33369,161"] = { Variant="Whiteout Peccary", 
                             Phases= {{ Hard=true, Count=3, VariantLimit=2 }}},
    ["-32063,33324,161"] = { Variant="Neophyte Tamer", Count=2, VariantLimit=1, 
                             Phases= {{ Hard=true, VariantLimit=2 }}},
    ["-35822,30670,161"] = { Variant="Neophyte Trainer", Count=2, VariantLimit=1, 
                             Phases= {{ Hard=true, VariantLimit=2 }}},
    ["-36171,32621,-139"] = { SpawnAs="Pest_Snow", Variant="Flurry Pest", Count=3, VariantLimit =2,
                              Phases= {{ Hard=true, Count=4, VariantLimit=2 }}}, -- Peccary_Snow
    ["-34997,32563,-139"] = { SpawnAs="Pest_Volatile", Variant="Signal Pest" },
    ["-33884,33833,108"] = { Variant="Whiteout Peccary", Count=2, VariantLimit=1 },
    ["-34497,34426,108"] = { SpawnAs="Exor_Armored", Variant="Winter Exor",
                             Phases= {{ Hard=true, Count=2, VariantLimit=1 }}},
    -- ["-33273,31741,161"] = {} --Robot_Defense

    -- Lower levels - Eatery <-> Athletics
    ["-40694,36169,-1115"] = { Variant="Winterfector", 
                               Phases = { { Hard=true, Count=2, VariantLimit=1 } }},


    -- Lower levels - Athletics - Soccer Field
    ["-37790,37774,-39"] = { Variant="Whiteout Peccary",
                             Phases = { { StoryMin=91, SpawnAs="Peccary", Variant="Jotun Steed" }, 
                                        { StoryMin=91, SpawnAs="Peccary", Variant="Jotun Steed", Count=2 } }},
    ["-36598,39203,-39"] = { Variant="Whiteout Peccary", 
                             Phases = { { Hard=true, StoryMin=91, SpawnAs="Peccary", Variant="Jotun Steed" } }},
    ["-38159,39022,-39"] = { SpawnAs="Exor_Armored", Variant="Winter Exor", 
                             Phases = { { Hard=true, Count=2, VariantLimit=1 } }},
    ["-34639,39978,-39"] = { SpawnAs="Exor_Armored", Variant="Exor Displacer", 
                             Phases = { { Hard=true, Count=2 } }},
    ["-37276,40458,-39"] = { Variant="Whiteout Peccary" },
    ["-37276,32577,-39"] = { Variant="Winterfector", NoPatrol=true,
                             Phases = {{ Hard=true, Count=2, VariantLimit=1 } }},

    -- Lower levels - Athletics - Gymnasium
    ["-36010,44690,661"] = { Variant="Jotun Rocketeer",
                             Phases = { { Hard=true, Count=2, VariantLimit=1 } }},
    ["-37121,46631,661"] = { Phases = { { Count=1 },
                                        { StoryMin=91, SpawnAs="Grunt_FlameRat", } }},
    
    -- Lower level - Athletics - Pool
    ["-40731,42817,1261"] = { Variant="Storm Witch", Count=2, VariantLimit=1,
                              Phases = { { Hard=true, Count=2 } }},
    ["-40200,42062,962"] = { SpawnAs="Gatekeeper_Witch", Variant="Storm Witch",
                              Phases = { { Hard=true, Count=2 } }},
    ["-42148,39934,-489"] = { Variant="Winterfector" },

    -- Dorms - 2F
    ["-34825,32872,1361"] = { SpawnAs="Gatekeeper_Mage", Variant="Beholder Mage" },
    ["-33800,39868,1361"] = { SpawnAs="Pest_Snow", Variant="Flurry Pest", Count=2, VariantLimit=1 },
    ["-34610,39455,1361"] = { SpawnAs="Exor_Volatile", Variant="Exor Hunter" },
    ["-35504,38167,1361"] = { SpawnAs="Pest_Volatile", Variant="Antesignal Pest" },

    -- Dorms - 3F
    ["-33946,30553,2261"] = { SpawnAs="Gatekeeper_Heavy", Variant="Jotun Rocketeer" },
    ["-37280,35623,2311"] = { SpawnAs="Yeti", Variant="Blizzard Yeti", 
                              Phases = { { Hard=true, Count=2, VariantLimit=1, } }},
    ["-33890,34187,2162"] = { Variant="Neophyte Trainer", Count=2, VariantLimit=1 },
    ["-35785,32473,2311"] = { SpawnAs="Exor_Armored", Variant="Winter Exor" },

    -- Dorms - 4F
    ["-30621,37998,2477"] = { Hard=true, Count=2 }, --Bigfoot
    ["-33636,38997,3261"] = { Hard=true, Count=2 }, --Bigfoot
   
    

-- =======================================================================
-- FRACTURE
-- =======================================================================

    -- Entrance
    ["-27363,59569,-1030"] = { Hard=true, Variant="Peremptor", Count=2, VariantLimit=1 },

    -- Food court
    ["25083,57507,550"] = { SpawnAs="Pest_Carbonated", Variant="Chonky Pest", Count=2 },
    ["-34284,53389,-88"] = { SpawnAs="Gatekeeper_Phyter", Variant="Neophyte Tamer",
                             Phases={{ Hard=true, Count=3, VariantLimit=1 }}},
    ["-34360,55327,-787"] = { Variant="Gravilisk", StoryMax=94 },
    ["-34241,55120,-787"] = { Variant="Gravilisk", StoryMax=94 },
    ["-34498,55566,-787"] = { Variant="Obsidilisk", StoryMax=94 },
    ["-35138,60891,288"] = { Variant="Purifier" },

    -- Blockbuster (Front-left)
    ["-20866,64453,658"] = { Variant="Exor Hunter", Count=2 },
    ["-21803,61242,-765"] = { SpawnAs="Pest_Snow", Variant="Flurry Pest", Count=3 },
    ["-21028,60029,137"] = { SpawnAs="Peccary", Variant="Phase Peccary", Count=2, StoryMax=94 },
    ["-21351,62567,105"] = { SpawnAs="Exor_Monk", Variant="Exor Magus", Count=2, VariantLimit=1, StoryMax=94 },
    ["-19605,61592,1268"] = { SpawnAs="Pest_Leyak", Variant="Leyak Menace", StoryMax=94 },

    -- Building Office (left-mid)
    ["-19293,73240,2938"] = { Variant="Esoteric Chieftain" },
    ["-19462,73143,2961"] = { Hard=true, SpawnAs="Peccary", Variant="Jotun Steed" },
    
    -- Ice Queen (mid)
    ["-24248,70408,1332"] = { Count=2, Phases= {{Hard=true, Count=4}} }, --WinterSprite

    -- Post-Forcefield
    ["-26092,81016,665"] = { Hard=true, SpawnAs="Gatekeeper_Chieftain" },
    ["-28479,83277,1104"] = { Variant="Neophyte Trainer" },
    ["-26857,82438,1002"] = { Variant="Jotun Rocketeer" },
    ["-25686,83893,720"] = { Variant="Plague Witch", Phases= {{Hard=true, Count=2}} },

-- =======================================================================
-- FRACTURE BOTANICALS
-- =======================================================================

    -- Facility
    -- * p1
    ["-39378,68276,1675"] = { SpawnAs="Pest_Magma", Variant="Magma Pest", Count=2,
                              Phases= {{ Hard=true, SpawnAs="Peccary_Alpha", Variant="Magma Peccary", Count=2 }} },
    ["-41535,63569,-150"] = { Phases= {{ Disabled=true },
                                       { Hard=true, SpawnAs="Grunt_Sniper", Variant="Twilight Sniper", Disabled=false }}},
    -- * p2
    ["-41313,63643,1300"] = { SpawnAs="Gatekeeper_Mage", Variant="Abjurer Mage", 
                              Phases= {{ Hard=true, Count=2, VariantLimit=1 }} },
    ["-41469,65419,1300"] = { Variant="Neophyte Trainer", 
                              Phases= {{ Hard=true, Count=2, VariantLimit=1 }} },
    ["-42396,62367,1375"] = { Hard=true, Variant="Plague Witch", Count=2, VariantLimit=1 },
    ["-43020,62548,200"] = { SpawnAs="Pest_Leyak" },
    ["-43471,65944,450"] = { SpawnAs="Gatekeeper_Heavy", Variant="Jotun Rocketeer",
                              Phases= {{ Hard=true, Count=2 }} },
    ["-43133,71806,-750"] = { SpawnAs="Grunt_Sniper", Variant="Tracer Sniper" },
    ["-43893,71620,-750"] = { SpawnAs="Grunt_Captain", Variant="Signifer" },
    -- * p3
    ["-45536,69235,-225"] = { Count=2, 
                              Phases= {{ Variant="Neophyte Tamer", VariantLimit=1 }} },
    ["-42999,65696,-122"] = { Variant="Neophyte Trainer", 
                              Phases= {{ Hard=true, SpawnAs="Gatekeeper_Chieftain", Variant="Esoteric Chieftain", Count=2 }} },
    ["-43042,66941,-425"] = { SpawnAs="Gatekeeper_Mage", Variant="Beholder Mage",
                              Phases= {{ Hard=true, Count=2 }} },
    ["-40796,70558,1950"] = { SpawnAs="Pest_Leyak" },
    ["-42200,72032,2450"] = { Variant="Winterfector" },
    -- * p4
    ["-50399,64541,3151"] = { SpawnAs="Grunt_FlameRat", Variant="Purifier", NoPatrol=true },

    -- BOTANICALS VIGNETTE
    -- * p1
    ["-37805,66571,51818"] = { SpawnAs="Exor", Variant="Magma Exor", Count=2 },
    ["-41539,64848,51300"] = { Variant="Antefire Exor", Count=2, VariantLimit=1,
                               Phases= {{ Hard=true, Count=3, VariantLimit=2 }} },
    ["-40828,63655,51300"] = { Variant="Exor Repeller",
                               Phases= {{ Hard=true, Variant="Exor Repeller", Count=2 }} },
    ["-43342,62666,51375"] = { SpawnAs="Exor_Monk", Variant="Exor Magus", Count=2, VariantLimit=1,
                               Phases= {{ Hard=true, Variant="Exorrior Magus" }} },
    ["-40049,61397,50575"] = { Variant="Antevolatile Pest", Count=2,
                               Phases= {{ Hard=true, Count=4 }} },
    ["-40090,62447,50575"] = { Variant="Pestilence", Count=2 },
    ["-42443,61870,50200"] = { SpawnAs="Exor_Volatile" },
    ["-41604,59521,50200"] = { Variant="Exor Hunter", Count=2 },
    -- * p2
    ["-42054,71366,52050"] = { Count=2, -- Bogman
                               Phases={{ Hard=true, Count=3 }} }, 
    ["-44460,70352,50150"] = { Variant="Acidic Exor",
                               Phases={{ Hard=true, Count=2, VariantLimit=1 }} }, 
    ["-41832,68812,51675"] = { SpawnAs="Exor_Pikeman", Variant="Exor Spiritwalker" },
    ["-41858,68098,51713"] = { SpawnAs="Peccary_Volatile", Variant="Volatile Peccary" },
    ["-46194,66115,49775"] = { Variant="Exor Displacer" },
    ["-44102,63063,49650"] = { Variant="Exor Repeller",
                               Phases={{ Hard=true, Variant="Exor Dislocator", Count=2, VariantLimit=1 }} }, 
    -- * p3
    ["-46403,60063,51975"] = { Variant="Pestilence", Count=3, VariantLimit=1 },
    ["-46437,60718,51996"] = { SpawnAs="Pest_Leyak", Variant="Leyak Pest" },
    ["-45340,60668,52900"] = { Variant="Obsidilisk", Count=2,
                               Phases={{ Hard=true, Count=4 }} }, 
    -- *p4
    -- ["?"] = { SpawnAs="Grunt_FlameRat", Variant="Purifier", Count=2, VariantLimit=1 },
    
    
-- =======================================================================
-- DARK LENS BOSSES
-- =======================================================================
    -- Mother of the Fallow (GK_DarkLensWitch)
    ["-28768,90195,3574"] = { Variant="Mother of the Fallow" },

    -- Jotun of the Fallow (GK_DarkLensJotunHelpers) - its spawner spot IS the arena home coord.
    ["-39389,79595,2370"] = { Variant="Jotun of the Fallow" },

    -- Partiarch of the Fallow (GK_DarkLensChieftain)
    ["42756,85059,3038"] = { Variant="Fallow Patriarch" },
    ["-42886,84851,3054"] = { Disabled=true }, -- disable default phyters
    ["-42967,85197,3022"] = { Disabled=true },

    -- Guardian of the Fallow (GK_DarkLensMage)
    ["-34748,87230,2588"] = { Variant="Magus of the Fallow" },


}


-- Keys are abs(coords) because Utils.GetSpawnerName builds the lookup that way. A SIGNED key is
-- accepted too - real world coords read better, and they are what PlacedSpawnData uses - so fold
-- it to the abs form here rather than making every author remember.
--   * A collision means two authored keys name the SAME spawner: the abs one wins and the signed
--     one is dropped, because silently overwriting a rule is the worse failure. Reported by
--     SpawnerHooks.ValidateSpawnerData at init (nothing in AnteData may require Utils).
SD.KeyCollisions = {}
do
    local signed = {}
    for key in pairs(SD.Spawners) do
        if key:find("-", 1, true) then signed[#signed + 1] = key end
    end
    for _, key in ipairs(signed) do
        local abs = key:gsub("-", "")
        if SD.Spawners[abs] then
            SD.KeyCollisions[#SD.KeyCollisions + 1] = key
        else
            SD.Spawners[abs] = SD.Spawners[key]
        end
        SD.Spawners[key] = nil
    end
end


-- =======================================================================
-- PLACED SPAWNS - our own pseudo-spawners, in their own file. Props and authoring rules
-- live there; this is just the hook-up, so SPAWNERDATA.PlacedSpawns reads the same as ever.
-- =======================================================================
SD.PlacedSpawns = require("AnteData.PlacedSpawnData")

-- =======================================================================
-- PHASES - story-banded rule sets. See the Phases block in this file's header for the
-- authoring rules; this is the resolver.
--
--   * The entry's TOP-LEVEL props are the shared base; each Phases entry OVERRIDES them
--     (shallow merge - a phase's MultiVariants REPLACES the base one, it does not merge
--     into it, so a phase always reads as the complete picture).
--   * LAST eligible phase wins (StoryMin <= story < StoryMax) - the same edges and the same
--     "list weakest -> strongest, ungated floor first" convention as the spawner story
--     window. No phase eligible -> the top-level props alone.
--   * Phased=true + PhaseIndex are stamped on the result: SpawnerHooks compares them per
--     heartbeat to notice a band change under a spawner that is already live. PhaseIndex is
--     nil when no band is open, which is why Phased exists as the separate "is banded" flag.
--
-- MEMOISED against a global story epoch - the merge happens once per entry per band change,
-- not per lookup (SpawnerHooks calls this on the IsOnCooldown heartbeat, per spawner, per
-- AI-Director evaluation). Keyed by the ENTRY TABLE, so PlacedSpawns can opt in for free.
-- =======================================================================
local StoryManager        -- lazy: SpawnerData is required at load time, StoryManager is not
local phaseCache  = {}    -- entry table -> merged rules (or false = no phase eligible)
local cachedStory = nil

function SD.Resolve(entry)
    if type(entry) ~= "table" or not entry.Phases then return entry end   -- the 99% path

    StoryManager = StoryManager or require("ModuleStory.StoryManager")
    local story = StoryManager.GetStoryProgress() or 0
    -- The cache epoch folds in the hard-mode flag: EARLY_SPAWNER_CONFIG can resolve
    -- entries BEFORE InitMod sets STATE.HardModeNoMercy, and a Hard band judged in that
    -- window would otherwise stay cached wrong for the session.
    local epoch = tostring(story) .. (STATE.HardModeNoMercy and "|H" or "")
    if epoch ~= cachedStory then
        cachedStory = epoch
        phaseCache = {}
    end

    local hit = phaseCache[entry]
    if hit ~= nil then return hit or nil end

    local won, wonIdx
    for i, ph in ipairs(entry.Phases) do
        if (not ph.StoryMin or story >= ph.StoryMin)
       and (not ph.StoryMax or story <  ph.StoryMax)
       and (not ph.Hard or STATE.HardModeNoMercy) then
            won, wonIdx = ph, i
        end
    end

    local merged = { Phased = true }   -- "this entry is banded", even when NO band is open
    for k, v in pairs(entry) do if k ~= "Phases" then merged[k] = v end end
    if won then
        for k, v in pairs(won) do merged[k] = v end
        merged.PhaseIndex = wonIdx
    end
    -- ^ Phased is what SpawnerHooks tests, NOT PhaseIndex: an entry whose LAST band has a
    --   StoryMax falls off the end to PhaseIndex=nil, and that transition still has to
    --   re-apply (it must put the vanilla SpawnAs rows back). Keying the heartbeat off
    --   PhaseIndex alone would silently leave the last band's rows rewritten forever.

    phaseCache[entry] = merged
    return merged
end

-- The one read for SPAWNER BEHAVIOUR: name -> the rules in force RIGHT NOW.
--   * Everything that acts on a spawner goes through this.
--   * Everything that inspects ALL bands (variant-name validation, the asset pre-warm)
--     reads SD.Spawners[name] RAW instead - a shut band's typo must still be caught.
function SD.Rules(spawnerName)
    local entry = spawnerName and SD.Spawners[spawnerName]
    -- HARD MODE: a top-level Hard entry only exists when NoMercy is on - off, the
    -- spawner reads as unlisted and runs vanilla. (Band-level Hard is in SD.Resolve.)
    if type(entry) == "table" and entry.Hard and not STATE.HardModeNoMercy then return nil end
    return SD.Resolve(entry)
end

-- =======================================================================
-- HARD MODE fallback (HARDMODE.NoMercy): row -> variant, for SPAWNER-BORN NPCs whose
-- spawner resolved no variant of its own. This is how "every native Exor Monk hardens"
-- works without tagging dozens of entries - a spawner that already maps the row
-- (Exorrior / Exor Magus) keeps its own mapping, because the fallback only fires when
-- the resolver came back empty (see NpcManager.HandleSpawnedActor).
--   * Spawner path ONLY: PlacedSpawns, EATG assault bodies, summons and story events
--     are untouched.
--   * Names are validated at init with the rest of SpawnerData.
-- =======================================================================
SD.HardVariants = {
    Exor_Monk   = "Exor Shadow Monk", -- Replaces monks with one with a decoy beam
    Grunt_Sapper = "Super Sapper",    -- Replaces sappers with a double rocket sapper
    Gatekeeper_Chieftain = "Gatekeeper Warchief",   -- Faster grabs, a triple grenade, shield always up
    Exor = "Exor Superior",   -- Tougher, six-quill bursts, a seeker quill on every reload
}

return SD
