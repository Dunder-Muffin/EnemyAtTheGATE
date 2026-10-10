-- =======================================================================
-- PlacedSpawnData - the SD.PlacedSpawns table (SpawnerData requires this and
-- hangs it off SD, so every consumer still reads SPAWNERDATA.PlacedSpawns).
--
-- Synthetic spawners: no game spawner owns these bodies. We pick a coord,
-- spawn the NPC, and own its respawn - which means every tick has to answer
-- "is my NPC already out there?" by SCANNING. That is where the dedupe radii
-- below come from, and where every duplicate ever seen came from.
--
--   * Driven by EventUtils.EnsurePlacedSpawns (StoryManager tick)
--   * AnNotes/AnteSystems/PlacedSpawns.md - how the anti-duplicate scan works, and every
--     way it bites
-- =======================================================================

-- =======================================================================
-- PROPS
--   * Variant        - the variant to spawn
--   * Base           - spawn a base NPC instead of a variant
--   * NoPatrol       - similar to above
--   * Yaw            - make it look a specific direction. good with nopatrol if guarding something
--   * ZLift          - capsule-centre Z modifier (default +97)
--   * CooldownDays   - respawn cooldown after a kill, in rolling in-game days (default 3;
--                      1 under HARDMODE.NoEnd). Fractions work: 1.5 = 36 hours
--   * StoryMin/Max   - spawn within Min <= StoryProgress < Max
--   * Level          - LABEL only - grouping and the /placed dump. NOT gated on; proximity is.
--   * FloorGate      - also accept floor collision under the coord as "loaded". Only for a coord
--                      outside every level volume (IsLocationLoaded never says yes there). Never
--                      as a default: at a sector border it passes on the neighbour's geometry.
--   * Hard           - Hard mode only (note: No phases). SD.HardVariants never reaches a
--                      placement, so name the upgrade: Variant="Exor Superior", not Base="Exor"

--   * ActiveRadius   - similar to SpawnRange, but not a guarantee to spawn (default 12000)
--                        > Still has to pass the streaming gate, but should spawn faster
--                        > unstreamed levels will eat the spawns and hides bodies
--   * NearRadius     - niche case - make the streaming gate check this spawn rapidly (3s)
--                        instead of the standard 10-60s check (10s backing off to 60s). 
--                        This is to make npcs near level entrances spawn faster
--      * NearFastCheck  how many of those 3s re-checks before it falls back to the standard logic
--
--   (!) Dedupe radii - how we recognise a body as already ours
--   * BaseRadius     - adopt and remutate an NPC near this PlacedSpawn loc (default 4000)
--                        * Measures distance to the NPC's last known position
--                        * Looking for a base_npc row - ex: Looking for a Pest in 40m to turn into a Razor Pest
--                        * We're assuming players moved out of the level, came back,
--                          and we need to find the existing NPC and mutate it
--   * VariantRadius  - base radius, but we're looking for an existing variant to 'adopt' for our spawner (default 4000)
--                        
--
--   (!) BaseRadius must be below the gap to any other placement sharing that row.
--   (!) BaseRadius=0 will make the spawner respawn and stack endlessly. Don't set it to 0
--   (!) Cut VariantRadius below the distance to a real spawner of the same variant on a NoPatrol
--       placement - otherwise that spawner's wanderer is adopted and the PlacedSpawner stays empty.
--       Don't cut it on a placement that roams
-- =======================================================================
local PLACED = {

-- =======================================================================
-- OFFICE SECTOR
-- =======================================================================

    -- 1F Starting area
    ["-18430,10250,310"] = { Hard=true, StoryMax=10, Variant="Razor Pest", NoPatrol=true, BaseRadius=1000, VariantRadius=1000 },

    -- 2F Reception
    ["-14720,14010,1330"] = { StoryMax=23, Base="Peccary", NoPatrol=true, Yaw=120, BaseRadius=1500 },
    ["-15180,13900,1340"] = { StoryMin=23, StoryMax=40, Base="Grunt_Guard", NoPatrol=true, Yaw=120 },
    ["-15920,14450,1210"] = { StoryMin=23, StoryMax=40, Variant="Flask Rat", BaseRadius=2500 },

    -- 2F Security Office
    ["-13970,16780,1230"] = { StoryMax=23, Variant="Razor Pest", NoPatrol=true, Yaw=-40, BaseRadius=100, VariantRadius=100, FloorGate=true },
    ["-13830,16890,1230"] = { StoryMax=23, Variant="Chonky Pest", NoPatrol=true, Yaw=-60, BaseRadius=100, VariantRadius=100, FloorGate=true },
    ["-15370,16200,1180"] = { Hard=true, StoryMax=30, Base="Peccary" },

    -- 2F Silo
    ["-13430,17570,1170"] = { Hard=true, StoryMax=30, Variant="Antegrav Pest", BaseRadius=400 },
    ["-14250,18330,1170"] = { Hard=true, StoryMax=30, Base="Peccary" },
    ["-11440,20260,870"] = { StoryMin=70, Base="Gatekeeper_Phyter", BaseRadius=2500 },

    -- 2F
    ["-13800,9140,870"] = { Hard=true, StoryMax=30, Variant="Chonky Pest", BaseRadius=2500 },
    ["-22910,7020,1140"] = { Hard=true, StoryMax=60, Variant="Carbunccary", BaseRadius=2500 },

    -- 3F
    ["-20500,22650,2610"] = { Variant="Cafeteria Bot", NoPatrol=true, BaseRadius=1500 }, -- Microwave Bot
    ["-18720,20150,2640"] = { Variant="Chonky Pest", BaseRadius=2500 },
    ["-20200,16030,2570"] = { Hard=true, Variant="Carbunccary", NoPatrol=true, Yaw=-45, BaseRadius=1000, VariantRadius=1500 },
    ["-14070,23570,2430"] = { Variant="Phase Peccary", NoPatrol=true, Yaw=0, BaseRadius=2500, VariantRadius=1500 },

    -- 2F Elevator    
    ["-19170,15060,1190"] = { Hard=true, StoryMin=35, StoryMax=60, Base="Pest_Electro" },
    ["-19170,15060,1180"] = { StoryMin=60, Variant="Exor Displacer", BaseRadius=100 },
    ["-18985,15383,1180"] = { StoryMin=60, Variant="Exor Repeller", BaseRadius=100 },

    -- 4F Big Bot boss
    ["-8850,20965,900"] = { StoryMin=15, Variant="Big Bot", BaseRadius=500 },

    -- Story progression
    ["-13430,17570,1180"] = { Hard=true, StoryMin=23, StoryMax=60, Variant="Suppressor Grunt", BaseRadius=1500 },
    ["-10720,20170,900"] = { StoryMin=23, StoryMax=60, Variant="Velites Guard", BaseRadius=500, VariantRadius=1500 },
    ["-8800,18340,900"] = { StoryMin=23, StoryMax=60, Base="Grunt_Medic" },
    ["-12710,20740,900"] = { StoryMin=23, StoryMax=80, Variant="Suppressor Grunt", BaseRadius=500 },
    ["-8470,17247,70"] = { StoryMin=23, StoryMax=90, Variant="Velites Guard", BaseRadius=250, VariantRadius=1500 },
    ["-8570,17980,110"] = { StoryMin=23, StoryMax=90, Base="Grunt_Captain" },
    ["-12060,15070,900"] = { StoryMin=35, StoryMax=90, Variant="Antegrav Exor" },
    ["-18005,12268,1180"] = { StoryMin=35, StoryMax=90, Variant="Skirmisher" },
    ["-17505,12719,1180"] = { StoryMin=35, StoryMax=90, Variant="Trident" },
    
    -- TODO: Use an ingame spawner for Flask Rats when possible, particularly around level edges
    -- ["-4960,12420,280"] = { StoryMin=30, StoryMax=60, Variant="Flask Rat" },
    -- ["-6760,7930,-210"] = { StoryMin=30, Variant="Flask Rat" },
    ["-5040,13280,560"] = { StoryMin=30, StoryMax=60, Variant="Suppressor Grunt", NoPatrol=true, Yaw=180, BaseRadius=1000 },    
    ["-21540,15970,1170"] = { StoryMin=83, Variant="Flurry Pest", NoPatrol=true, Yaw=130 },


    
-- =======================================================================
-- OFFICE VIGNETTES
-- =======================================================================

    -- Far Garden
    ["121790,333330,2020"] = { Base="Pest" },
    ["124830,334370,1860"] = { Base="Pest" },
    ["117850,333480,2370"] = { Hard=true, Variant="Chonky Pest", NoPatrol=true, Yaw=-45 },
    ["128260,334510,1900"] = { Hard=true, Base="Peccary" },
    ["126410,336110,2070"] = { Hard=true, Variant="Exorrior", NoPatrol=true, Yaw=-90, BaseRadius=500, NearRadius=500 },


    -- Flathill
    ["5830,339370,3360"] = { StoryMax=14, Variant="Orchestrator", Level="V_FOG" },


-- =======================================================================
-- MANUFACTURING SECTOR
-- =======================================================================

    -- Lower access (Office <-> Labs)
    ["-8350,17510,70"] = { StoryMin=23, StoryMax=60, Base="Grunt_Guard", Yaw=-90 },
    ["-8350,17510,80"] = { StoryMin=60, StoryMax=80, Variant="Antegrav Exor", NoPatrol=true, Yaw=-90 },
    ["-8350,17510,90"] = { StoryMin=80, Variant="Exor Spiritwalker", NoPatrol=true, Yaw=-90 },
    ["-8050,17600,70"] = { Hard=true, StoryMin=23, StoryMax=60, Base="Grunt_Captain", NoPatrol=true, Yaw=0 },
    ["-8050,17600,80"] = { Hard=true, StoryMin=60, StoryMax=80, Base="Sow", NoPatrol=true, Yaw=0 },
    ["-8050,17600,90"] = { Hard=true, StoryMin=80, Variant="Exor Spiritwalker", NoPatrol=true, Yaw=0 },
    ["-5010,27550,0"] = { Hard=true, StoryMin=23, StoryMax=80, Variant="Velites Guard", NoPatrol=true, Yaw=-130, BaseRadius=1500, VariantRadius=500 },
    ["-4510,25740,910"] = { Hard=true, StoryMin=23, StoryMax=80, Base="Grunt_Medic", NoPatrol=true, Yaw=120, BaseRadius=500 },
    ["-6620,34260,870"] = { Hard=true, StoryMax=30, Variant="Velites Guard", NoPatrol=true, Yaw=-130, BaseRadius=250, VariantRadius=500 },

    -- Entrance
    ["-1750,23470,510"] = { StoryMax=30, Variant="Chonky Pest" },
    ["-1330,23670,510"] = { Hard=true, StoryMax=30, Base="Peccary" },
    ["-1100,22430,870"] = { Hard=true, StoryMax=30, Variant="Exorrior Magus" },
    ["-6380,29470,10"] = { StoryMax=30, Variant="Phase Peccary", NoPatrol=true, Yaw=-45, BaseRadius=500, VariantRadius=500, NearRadius=500 },
    ["-4170,24450,900"] = { StoryMax=30, Variant="Razor Pest", NoPatrol=true, BaseRadius=1500 },

    -- Forge area / Lot Oversight
    ["-920,34240,760"] = { Hard=true, StoryMax=40, Variant="Tracker Sniper", Yaw=180, BaseRadius=500 },
    ["-4075,40340,875"] = { StoryMin=71, Variant="Rocket Rat", Level="Facility_MFMines" },
    ["1130,38400,1660"] = { Variant="Suppressor Grunt", NoPatrol=true, Yaw=180, BaseRadius=500, VariantRadius=500, Level="Facility_MFWest" },
    ["1080,37980,1660"] = { Variant="Suppressor Grunt", NoPatrol=true, Yaw=180, BaseRadius=500, VariantRadius=500, Level="Facility_MFWest" },

    -- Storage
    ["-3360,38970,-330"] = { StoryMax=30, Base="Peccary", NoPatrol=true, Yaw=-130, BaseRadius=500 },
    ["-4110,38020,-310"] = { StoryMax=30, Variant="Razor Pest", NoPatrol=true, Yaw=-130, BaseRadius=1500, VariantRadius=500 },
    ["-2700,36580,-310"] = { Hard=true, StoryMax=30, Variant="Signal Pest", NoPatrol=true, Yaw=-130, BaseRadius=2500, VariantRadius=500 },
    ["-6140,37405,-310"] = { Hard=true, StoryMax=30, Variant="Charge Peccary", NoPatrol=true, Yaw=-10, BaseRadius=1000, VariantRadius=500 },

    -- MG Nest / Shipping
    ["-4080,31550,570"] = { Hard=true, StoryMax=30, Variant="Dioscoridian", NoPatrol=true, Yaw=-45, BaseRadius=500, VariantRadius=500 },
    ["-820,26570,-30"] = { Hard=true, StoryMax=30, Variant="Tracker Sniper", NoPatrol=true, Yaw=140, BaseRadius=500 },

    -- Mines hallway
    ["-2910,39720,880"] = { Hard=true, StoryMax=40, Variant="Suppressor Grunt", NoPatrol=true, Yaw=180, BaseRadius=250, VariantRadius=250 },
    ["-3280,39210,880"] = { Hard=true, StoryMax=40, Variant="Suppressor Grunt", NoPatrol=true, Yaw=120, BaseRadius=250, VariantRadius=250 },
    ["-5720,41750,850"] = { StoryMax=60, Variant="Commander", Yaw=-45, BaseRadius=1000 },

    -- Mines
    ["7870,43560,420"] = { Variant="Chonky Pest", NoPatrol=true },
    ["-1170,41090,1560"] = { Variant="Gravilisk", NoPatrol=true, Yaw=-45, BaseRadius=500 },
    ["1900,42860,600"] = { Variant="Carbunccary", NoPatrol=true, BaseRadius=500 },
    ["8090,38040,520"] = { Variant="Signal Pest", NoPatrol=true, Yaw=-150, BaseRadius=500 },
    ["8200,34990,1100"] = { Variant="Obsidilisk", NoPatrol=true, BaseRadius=500, VariantRadius=500 },
    ["7480,35730,1270"] = { Hard=true, Variant="Obsidilisk", NoPatrol=true, BaseRadius=500, VariantRadius=500 },
    ["-2000,40480,1530"] = { Hard=true, Variant="Gravilisk", NoPatrol=true, Yaw=140, BaseRadius=400 },
    ["-1600,40540,1540"] = { Hard=true, Variant="Obsidilisk", NoPatrol=true, Yaw=140, BaseRadius=400 },
    ["2560,26110,-650"] = { Hard=true, Variant="Twilight Sniper", Yaw=20, BaseRadius=500 },

    -- Frake Entrance
    ["9900,32050,1830"] = { Base="Peccary" },
    ["9940,30220,1970"] = { Variant="Exorrior", BaseRadius=1000 },
    ["10180,32120,1930"] = { Variant="Exor Magus", NoPatrol=true, Yaw=180, BaseRadius=1000 },

    -- Train entrance
    ["6102,33066,1650"] = { Variant="Commander", Yaw=150, BaseRadius=250 },
    ["4270,34720,1650"] = { Hard=true, Variant="Commander", Yaw=-40, BaseRadius=250, VariantRadius=250 },
    ["3850,34170,1710"] = { Variant="Flask Rat", NoPatrol=true, Yaw=30, BaseRadius=500 },

    -- Mapping Center
    ["-11580,46530,570"] = { Hard=true, Variant="Twilight Sniper", Yaw=45, BaseRadius=500 },
    ["-13990,48190,770"] = { Variant="Flask Rat", NoPatrol=true, Yaw=-80 },
    ["-12490,46490,600"] = { Variant="Commander", Yaw=140, BaseRadius=500 },

    -- Syncotron
    ["1670,21030,70"] = { Variant="Velites Guard", NoPatrol=true, Yaw=90, BaseRadius=500 },
    ["1150,21020,70"] = { Hard=true, Variant="Velites Guard", NoPatrol=true, Yaw=90, BaseRadius=500 },
    ["1420,22760,70"] = { Variant="Centurion Grunt", NoPatrol=true, Yaw=90 },
    ["-620,23010,-30"] = { Hard=true, Variant="Dioscoridian", NoPatrol=true, Yaw=0 },
    ["1070,21010,630"] = { Hard=true, Variant="Trident", Yaw=90 },

    -- Syncotron - black hole targets
    ["4430,22270,-910"] = { StoryMax=30, Variant="Flask Rat", NoPatrol=true, Yaw=75 },
    ["5260,22480,-910"] = { StoryMax=30, Base="Grunt", NoPatrol=true, Yaw=120, BaseRadius=1000 },
    ["3980,22470,-910"] = { StoryMax=30, Base="Grunt", NoPatrol=true, Yaw=45, BaseRadius=1000 },

-- =======================================================================
-- MANUFACTURING VIGNETTES
-- =======================================================================

    --  Train
    -- 1st cart    
    ["333440,11540,660"] = { Variant="Velites Guard", NoPatrol=true, Yaw=180, BaseRadius=500 },
    
    -- Roof
    ["335020,5760,1300"] = { Variant="Velites Guard", NoPatrol=true, Yaw=-120, BaseRadius=100 },
    ["335200,5740,1300"] = { Variant="Grenadier Guard", NoPatrol=true, Yaw=-20, BaseRadius=100 },
    ["335800,4200,1300"] = { Variant="Suppressor Grunt", NoPatrol=true, Yaw=120, BaseRadius=250, VariantRadius=250 },
    ["336980,2170,1380"] = { Variant="Tracker Sniper", Yaw=-55, BaseRadius=250 },

    -- 3rd cart
    ["335565,4490,670"] = { Variant="Twilight Sniper", Yaw=150, BaseRadius=250 },
    
    -- 6th cart
    ["337950,1410,670"] = { Variant="Flask Rat", NoPatrol=true, Yaw=180 },
    ["338560,280,670"] = { Variant="Suppressor Grunt", NoPatrol=true, Yaw=130, BaseRadius=250, VariantRadius=250 },

    -- 7th cart
    ["339320,-350,670"] = { Hard=true, Variant="Dioscoridian", NoPatrol=true, Yaw=-75, BaseRadius=500 },
    ["340030,-1210,670"] = { Hard=true, Variant="Grenadier Guard", NoPatrol=true, Yaw=130, BaseRadius=500 },
    ["339920,-720,670"] = { Hard=true, Variant="Twilight Sniper", Yaw=-45, BaseRadius=500 },

-- =======================================================================
-- LABS SECTOR
-- =======================================================================

    -- Entrance
    ["10200,11310,-1370"] = { Variant="Signal Pest", BaseRadius=2000, VariantRadius=2000 },
    ["10710,9125,-1330"] = { StoryMax=35, Variant="Phase Peccary", BaseRadius=2500 },
    ["8380,9180,-1110"] = { Variant="Exorrior", NoPatrol=true, Yaw=60, BaseRadius=500 },
    ["10960,9610,-1040"] = { Base="Exor_Monk", NoPatrol=true, BaseRadius=1500 },
    ["8320,10290,-1030"] = { Variant="Antegrav Pest", NoPatrol=true, Yaw=-20, BaseRadius=1000 },
    ["8970,9260,-610"] = { Variant="Signal Pest", NoPatrol=true, Yaw=130, BaseRadius=500, VariantRadius=500 },
    ["10110,11250,-1370"] = { Hard=true, Variant="Anterazor Pest", BaseRadius=1500 },
    ["9050,12730,-1330"] = { Hard=true, StoryMax=35, Variant="Carbunccary", NoPatrol=true, Yaw=-90, BaseRadius=500 },
    ["8390,9140,-510"] = { Hard=true, Variant="Anterazor Pest", NoPatrol=true, Yaw=70, BaseRadius=1000 },
    ["8100,8820,-1120"] = { Hard=true, Variant="Laser Pest", NoPatrol=true, Yaw=150, BaseRadius=500, VariantRadius=500 },
    
    -- Elevator
    ["9880,6440,-1670"] = { Hard=true, Variant="Exor Superior", NoPatrol=true, Yaw=150, BaseRadius=500, VariantRadius=500 },
    ["8530,7300,-1670"] = { Hard=true, Variant="Exor Superior", NoPatrol=true, Yaw=-30, BaseRadius=500, VariantRadius=500 },
    ["10660,4350,-180"] = { Hard=true, Variant="Advanced Big Bot", NoPatrol=true, Yaw=150, BaseRadius=500 },
    ["8890,2815,550"] = { Variant="Advanced Hospitality Bot", BaseRadius=500 },
    ["5540,4940,1270"] = { Base="Robot_Containment" },
    ["11400,3920,2000"] = { StoryMax=34, Variant="Sweeper", NoPatrol=true, Yaw=150, BaseRadius=500 },

    -- Lobby
    ["-1850,7610,-410"] = { Hard=true, StoryMax=33, Variant="Anterazor Pest", NoPatrol=true, Yaw=-120, BaseRadius=500 },

    -- Aquarium    
    ["6030,10350,-980"] = { Variant="Telepest", NoPatrol=true, Yaw=150, BaseRadius=1000 },
    ["6690,12160,-1320"] = { Variant="Laser Pest", NoPatrol=true, Yaw=-150, BaseRadius=500, VariantRadius=500 },
    ["4860,10730,-780"] = { Hard=true, Variant="Telepest", NoPatrol=true, Yaw=-30, BaseRadius=1000 },
    ["5590,11350,-830"] = { Variant="Anterazor Pest", NoPatrol=true, Yaw=-30, BaseRadius=1500 },


    -- Particle Labs
    ["-2310,15590,-810"] = { Variant="Leyak Pest", NoPatrol=true, Yaw=-90, BaseRadius=250, VariantRadius=250 },
    ["3690,12670,-810"] = { Hard=true, Base="Grunt_Shotgun", NoPatrol=true, Yaw=90, BaseRadius=2000 },
    ["3940,13270,-1080"] = { Hard=true, Variant="Leyak Pest", NoPatrol=true, Yaw=0, BaseRadius=250, VariantRadius=250 },
    ["720,13170,-480"] = { Hard=true, StoryMax=32, Variant="Tracker Sniper", Yaw=0 },

    ["520,14280,-1080"] = { StoryMin=43, StoryMax=50, Base="Grunt_Shotgun", NoPatrol=true, Yaw=-30, BaseRadius=500, NearRadius=5000, NearFastCheck=15 },
    ["580,13500,-1080"] = { StoryMin=43, StoryMax=50, Base="Grunt_Guard", NoPatrol=true, Yaw=60, BaseRadius=500, NearRadius=5000, NearFastCheck=15 },
    ["460,13890,-1080"] = { StoryMin=43, StoryMax=50, Base="Grunt_Captain", NoPatrol=true, Yaw=0, BaseRadius=500, NearRadius=5000, NearFastCheck=15 },
    ["200,13570,-1080"] = { StoryMin=43, StoryMax=50, Base="Grunt", NoPatrol=true, Yaw=15, BaseRadius=500, NearRadius=5000, NearFastCheck=15 },
    ["-40,12750,-1080"] = { StoryMin=43, Variant="Leyak Menace", NoPatrol=true, Yaw=60, BaseRadius=1000, NearRadius=5000, NearFastCheck=15 },
    ["1100,15160,-1080"] = { StoryMin=43, Variant="Leyak Pest", NoPatrol=true, Yaw=-120, BaseRadius=1000, VariantRadius=1000, NearRadius=5000, NearFastCheck=15 },

    -- Holding Pens area
    ["-3400,-7610,420"] = { Variant="Centurion Grunt", NoPatrol=true, Yaw=130, BaseRadius=2500, VariantRadius=2500 },
    ["-3510,1540,1170"] = { Variant="Skirmisher", NoPatrol=true, Yaw=30, BaseRadius=1000, VariantRadius=1000 },
    ["14330,3010,-870"] = { Variant="Chonky Pest" },
    ["1440,11160,-820"] = { Variant="Anterazor Pest" },
    ["5190,8000,-840"] = { Variant="Anterazor Pest", NoPatrol=true, BaseRadius=1000 },
    ["-1360,11690,-600"] = { StoryMin=33, Variant="Advanced Big Bot" },
    ["5030,10660,-820"] = { Variant="Laser Pest", NoPatrol=true, Yaw=165, BaseRadius=1000, VariantRadius=1500 },
    ["-960,8070,-880"] = { StoryMin=71, Variant="Exor Spiritwalker" },
    ["640,7050,-880"] = { StoryMin=71, Variant="Signal Pest" },

    
    -- Adjustment-Office
    ["-3090,9680,-190"] = { Hard=true, StoryMax=51, Variant="Trident", NoPatrol=true, Yaw=-120, BaseRadius=250 },
    ["-3410,8860,-340"] = { StoryMin=51, Variant="Exor Repeller" },
    ["-2760,9480,-190"] = { Hard=true, Variant="Trident", NoPatrol=true, Yaw=-120, BaseRadius=250 },


    -- Adjustment Wing 1F
    ["-2630,2530,470"] = { StoryMax=50, Variant="Chonky Signal Pest", NoPatrol=true, Yaw=-50, BaseRadius=500 },
    ["4980,4810,-170"] = { Hard=true, StoryMax=50, Variant="Razor Pest", NoPatrol=true, Yaw=-120, BaseRadius=250 },
    ["3350,2610,480"] = { Hard=true, Variant="Signal Pest", BaseRadius=500 },
    ["1224,5532,420"] = { Hard=true, StoryMax=50, Variant="Suppressor Grunt", NoPatrol=true, Yaw=-50, BaseRadius=500, VariantRadius=500 },
    ["-1650,1090,720"] = { Hard=true, Variant="Hive Sow", NoPatrol=true, Yaw=120, BaseRadius=500 },
    ["-2370,6350,420"] = { Hard=true, StoryMax=50, Variant="Grenadier Guard", NoPatrol=true, Yaw=10, BaseRadius=500 },

    -- ["200,930,460"] = { Variant="Chonky Signal Pest", NoPatrol=true, Yaw=-50, BaseRadius=500, VariantRadius=500, StoryMax=50 },

    -- Adjustment Wing 2F
    ["-230,3850,1360"] = { StoryMax=50, Variant="Exorrior Magus", NoPatrol=true, Yaw=40, BaseRadius=500 },
    ["-2640,-890,1180"] = { StoryMax=50, Variant="Commander", Yaw=0, BaseRadius=500 },
    ["-660,-570,1250"] = { Variant="Leyak Pest", Yaw=60, BaseRadius=500, VariantRadius=500 },
    ["30,230,1170"] = { Hard=true, Variant="Twilight Sniper", Yaw=40, BaseRadius=500 },
    ["-920,-1800,1060"] = { Hard=true, StoryMax=70, Variant="Trident", NoPatrol=true, Yaw=-75, BaseRadius=400 },
    ["-710,-350,1770"] = { Hard=true, Variant="Leyak Pest", Yaw=-150, BaseRadius=500, VariantRadius=500 },

    -- Inner Wing
    ["14350,3100,-900"] = { Variant="Telepest", NoPatrol=true, Yaw=-150, BaseRadius=500 },
    ["18130,740,-340"] = { Variant="Chonky Signal Pest", NoPatrol=true, Yaw=-150, BaseRadius=500 },
    ["18470,-2260,-900"] = { Variant="Chonky Pest", NoPatrol=true, Yaw=-150, BaseRadius=500 },
    ["18620,-900,-900"] = { Variant="Phase Peccary" },
    ["16420,-830,-900"] = { Variant="Antegrav Pest", NoPatrol=true, Yaw=-150, BaseRadius=100 },
    ["17110,-1140,-900"] = { Variant="Antegrav Pest", NoPatrol=true, Yaw=-150, BaseRadius=250 },
    ["16350,840,-240"] = { Base="Exor_Monk", NoPatrol=true, Yaw=-150, BaseRadius=500 },
    ["16520,-740,-900"] = { Hard=true, Variant="Anterazor Pest", NoPatrol=true, Yaw=-150, BaseRadius=100 },
    ["13840,1770,-900"] = { Hard=true, Variant="Laser Pest", NoPatrol=true, Yaw=120, BaseRadius=500, VariantRadius=500 },
    ["17150,-800,-240"] = { Hard=true, Variant="Antegrav Exor", NoPatrol=true, Yaw=-150, BaseRadius=500 },
    
    -- Inner Wing Turrets
    ["18250,-6440,-40"] = { StoryMin=33, Variant="Containment Bot", BaseRadius=1000 },
    ["21420,-3370,-10"] = { StoryMin=33, Variant="Advanced Hospitality Bot", NoPatrol=true, Yaw=-150, BaseRadius=2000 },
    ["17410,-11950,-950"] = { StoryMin=33, Variant="Armored Peccary" },
    ["21440,-5140,-600"] = { StoryMin=33, Variant="Orchestrator" },
    ["19350,-4900,-120"] = { StoryMin=33, Variant="Orchestrator" },
    -- ["19620,-1920,-850"] = { Variant="Advanced Hospitality Bot", StoryMin=33 },
    ["16020,-8100,-570"] = { StoryMin=33, Variant="Constrictor Bot", NoPatrol=true, Yaw=30, BaseRadius=1500, VariantRadius=1500 },
    ["19620,-1920,-850"] = { Hard=true, StoryMin=33, Variant="Advanced Big Bot", BaseRadius=2000 },
    ["18460,-5900,-900"] = { Hard=true, StoryMin=33, Variant="Leyak Pest", Yaw=30, BaseRadius=500 },
    ["19210,-6380,-900"] = { Hard=true, StoryMin=33, Variant="Leyak Pest", Yaw=110, BaseRadius=500 },

    -- Control Center 1F
    ["9320,-1690,1960"] = { StoryMin=31, StoryMax=33, Variant="Twilight Sniper", NoPatrol=true, Yaw=30, BaseRadius=500 },    
    ["11580,-1640,1920"] = { StoryMin=31, StoryMax=33, Variant="Skirmisher", NoPatrol=true, Yaw=120, BaseRadius=500 },
    ["9840,1400,2100"] = { StoryMin=31, StoryMax=33, Variant="Grenadier Guard", BaseRadius=1000, VariantRadius=1000 },
    ["10810,-40,1830"] = { Hard=true, StoryMin=31, StoryMax=33, Variant="Skirmisher", NoPatrol=true, Yaw=-60, BaseRadius=500 },
    ["8540,2110,2010"] = { Hard=true, StoryMin=31, StoryMax=33, Variant="Twilight Sniper", NoPatrol=true, Yaw=30, BaseRadius=500 },

    -- Control Center 2F
    ["11750,-4020,2840"] = { Hard=true, StoryMin=31, StoryMax=33, Variant="Twilight Sniper", NoPatrol=true, Yaw=120, BaseRadius=500 },
    ["11880,290,3160"] = { Hard=true, StoryMin=31, StoryMax=33, Variant="Grenadier Guard", NoPatrol=true, Yaw=120, BaseRadius=500, VariantRadius=500 },
    ["11440,-430,3110"] = { StoryMin=31, StoryMax=33, Variant="Grenadier Guard", NoPatrol=true, Yaw=120, BaseRadius=500, VariantRadius=500 },
    ["12620,-3460,2960"] = { StoryMin=31, StoryMax=33, Variant="Sweeper", NoPatrol=true, Yaw=120, BaseRadius=500 },

    -- Control Center 2F MG nest corridor
    ["14390,-3210,3080"] = { Hard=true, StoryMin=31, StoryMax=33, Variant="Velites Guard", NoPatrol=true, Yaw=-150, BaseRadius=500, VariantRadius=500 },
    ["14140,-1170,3080"] = { Hard=true, StoryMin=31, StoryMax=33, Variant="Velites Guard", NoPatrol=true, Yaw=-150, BaseRadius=500, VariantRadius=500 },
    
    -- Control Center core
    ["10000,-1350,3420"] = { StoryMin=31, StoryMax=33, Variant="Commander", Yaw=25, BaseRadius=250, VariantRadius=250 },
    ["10180,-1690,3420"] = { StoryMin=31, StoryMax=33, Variant="Sweeper", NoPatrol=true, Yaw=-10, BaseRadius=250 },
    ["10540,-1550,3420"] = { StoryMin=31, StoryMax=33, Variant="Dioscoridian", Yaw=75, BaseRadius=500 },
    ["9890,-1050,3420"] = { Hard=true, StoryMin=31, StoryMax=33, Variant="Sweeper", NoPatrol=true, Yaw=-10, BaseRadius=250 },
    ["10260,-880,3420"] = { Hard=true, StoryMin=31, StoryMax=33, Variant="Dioscoridian", Yaw=-25, BaseRadius=500 },
    

    -- Tarasque vault bosses
    ["1080,-6180,550"] = { StoryMin=36, Variant="Tarasque Charger", Yaw=60, BaseRadius=400 },
    ["1500,-6420,550"] = { StoryMin=36, Variant="Tarasque Slammer", Yaw=60, BaseRadius=400 },


-- =======================================================================
-- LABS VIGNETTES
-- =======================================================================
    -- MYCOFIELDS
    -- First island
    ["325420,333260,80"] = { Variant="Magma Pest", NoPatrol=true, Yaw=-30, BaseRadius=1000, VariantRadius=1000 },
    ["325420,329500,2050"] = { Hard=true, Variant="Magma Pest", NoPatrol=true, Yaw=130, BaseRadius=1000, VariantRadius=1000 },
    ["323700,329470,2390"] = { Hard=true, Variant="Magma Pest", NoPatrol=true, Yaw=10, BaseRadius=1000, VariantRadius=1000 },
    ["317450,330900,2130"] = { Hard=true, Variant="Exorrior Magus", NoPatrol=true, Yaw=10 },
    ["317820,330090,2170"] = { Hard=true, Base="Pest", NoPatrol=true, Yaw=10 },
    ["317320,327740,1960"] = { Hard=true, Variant="Magma Peccary", NoPatrol=true, Yaw=30, BaseRadius=1000, VariantRadius=1000 },
    ["316500,327170,1820"] = { Base="Peccary_Mushroom", NoPatrol=true, Yaw=-45, BaseRadius=1000 },
    ["319230,329970,1720"] = { Variant="Magma Pest", NoPatrol=true, Yaw=120, BaseRadius=1000, VariantRadius=1000 },
    ["320730,331500,2280"] = { Variant="Hive Sow", NoPatrol=true, Yaw=-20 },

    -- Middle island
    ["320080,322140,2220"] = { Hard=true, Variant="Magma Exor", NoPatrol=true, Yaw=-20, BaseRadius=1000, VariantRadius=1000 },
    ["320520,323200,2470"] = { Hard=true, Variant="Magma Peccary", NoPatrol=true, Yaw=-60, BaseRadius=1000, VariantRadius=1000 },
    ["320040,322300,2200"] = { Variant="Razor Pest", NoPatrol=true, Yaw=-90, BaseRadius=1000 },
    ["324520,321380,2640"] = { Variant="Charge Peccary", NoPatrol=true, Yaw=180, BaseRadius=1000 },
    ["324290,324840,2900"] = { Hard=true, Variant="Exor Superior", NoPatrol=true, Yaw=180, BaseRadius=1000, VariantRadius=1000 },
    ["323060,321890,3160"] = { Hard=true, Variant="Signal Pest", NoPatrol=true, Yaw=60 },
    ["318800,321550,3100"] = { Variant="Magma Exor", NoPatrol=true, Yaw=40, BaseRadius=1000, VariantRadius=1000 },
    ["318930,321200,2520"] = { Variant="Chonky Pest", NoPatrol=true, Yaw=45 },
    ["316540,317190,1910"] = { Variant="Magma Peccary", NoPatrol=true, Yaw=110, BaseRadius=1000, VariantRadius=1000 },
    ["324330,321660,2670"] = { Variant="Magma Peccary", NoPatrol=true, Yaw=45 },

    -- Top island
    ["323630,319120,3690"] = { Variant="Magma Exor", NoPatrol=true, Yaw=180, BaseRadius=1000, VariantRadius=1000 },
    ["325760,319930,4030"] = { Hard=true, Variant="Carbunccary", NoPatrol=true, Yaw=180, BaseRadius=1000 },
    ["326320,315050,6550"] = { Hard=true, Variant="Exor Superior", NoPatrol=true, Yaw=0, BaseRadius=1000, VariantRadius=1000 },
    ["329100,315470,8030"] = { Variant="Chonky Pest", NoPatrol=true, Yaw=140 },
    ["330160,318570,9010"] = { Variant="Magma Peccary" },
    ["329250,318290,8880"] = { Hard=true, Variant="Charge Peccary" },
    ["330330,318380,9020"] = { Variant="Razor Pest", NoPatrol=true, Yaw=-150 },

    -- RISE 
    -- Underfloor
    ["-149540,-323130,-190"] = { Hard=true, Variant="Flask Rat", NoPatrol=true, Yaw=-45, BaseRadius=500, VariantRadius=500, NearRadius=25000 },
    ["-147110,-324380,-190"] = { Hard=true, Base="Grunt_Captain", NoPatrol=true, Yaw=180, BaseRadius=500, NearRadius=25000 },

    -- First floor
    ["-148910,-326040,360"] = { Base="Grunt_Guard", NoPatrol=true, Yaw=-70, BaseRadius=500, NearRadius=25000, NearFastCheck=15 },
    ["-148380,-325990,360"] = { Base="Grunt_Guard", NoPatrol=true, Yaw=-100, BaseRadius=500, NearRadius=25000, NearFastCheck=15 },
    ["-146400,-326670,120"] = { Hard=true, Base="Grunt_Captain", NoPatrol=true, Yaw=140, BaseRadius=500 },
    ["-151020,-326220,480"] = { Base="Grunt", NoPatrol=true, Yaw=-90, BaseRadius=500 },
    ["-150520,-325580,480"] = { Variant="Velites Guard", NoPatrol=true, Yaw=90, BaseRadius=500, VariantRadius=500 },
    ["-146350,-324110,380"] = { Hard=true, Variant="Grenadier Guard", NoPatrol=true, Yaw=90, BaseRadius=500, VariantRadius=500 },

    -- First floor, labs
    ["-150810,-322680,380"] = { Hard=true, Base="Grunt_Captain", NoPatrol=true, Yaw=-30, BaseRadius=500 },
    ["-148070,-321880,380"] = { Hard=true, Variant="Commander", NoPatrol=true, Yaw=-30, BaseRadius=500, VariantRadius=500 },
    ["-146730,-323500,380"] = { Hard=true, Variant="Dioscoridian", NoPatrol=true, Yaw=120, BaseRadius=500, VariantRadius=500 },

    -- Second floor, labs
    ["-150700,-322820,910"] = { Hard=true, Base="Grunt_Guard", NoPatrol=true, Yaw=0, BaseRadius=500 },

    -- Second floor
    ["-150730,-325490,100"] = { Variant="Centurion Grunt", NoPatrol=true, Yaw=-130, BaseRadius=500, VariantRadius=500 },
    ["-150420,-326090,960"] = { Hard=true, Variant="Twilight Sniper", Yaw=90, BaseRadius=500, VariantRadius=500 },
    ["-146410,-324700,960"] = { Hard=true, Variant="Shield Grunt", NoPatrol=true, Yaw=-90 },
    ["-147080,-323260,960"] = { Hard=true, Variant="Velites Guard", NoPatrol=true, Yaw=130, BaseRadius=500, VariantRadius=500 },
    ["-148210,-322840,1200"] = { Hard=true, Variant="Shield Grunt", NoPatrol=true, Yaw=0 },

    -- Roof
    ["-149930,-326520,1940"] = { Base="Grunt_Shotgun", Yaw=90, BaseRadius=500 },
    ["-149130,-324860,1940"] = { Variant="Shield Grunt", Yaw=90 },
    ["-150830,-324670,1940"] = { Hard=true, Variant="Twilight Sniper", Yaw=-90, BaseRadius=500, VariantRadius=500 },
    ["-149130,-322610,2400"] = { Hard=true, Base="Grunt_Captain", NoPatrol=true, Yaw=-90, BaseRadius=500 },
    ["-146370,-325910,1940"] = { Hard=true, Variant="Shield Grunt", NoPatrol=true, Yaw=180 },
    ["-146290,-325120,1940"] = { Hard=true, Variant="Velites Guard", NoPatrol=true, Yaw=180, BaseRadius=500, VariantRadius=500 },
    ["-150040,-322180,1940"] = { Hard=true, Variant="Centurion Grunt", NoPatrol=true, Yaw=180, BaseRadius=1500, VariantRadius=1500 },

-- =======================================================================
-- SECURITY 
-- =======================================================================
    -- Halls
    ["-11500,-4500,820"] = { Hard=true, StoryMin=44, Variant="Roaming Shade", NoPatrol=true, Yaw=150 },
    ["-16040,-5740,690"] = { Hard=true, StoryMin=44, Variant="Roaming Shade", NoPatrol=true, Yaw=150 },

    ["-11350,-1740,700"] = { StoryMin=50, Variant="Grunt Shade", Yaw=90 }, -- post security
    ["-11030,-1740,700"] = { StoryMin=50, Variant="Breacher Shade", Yaw=90 },
    ["-11160,-2100,700"] = { StoryMin=50, Variant="Grunt Shade", Yaw=90 },
    ["-12450,-5140,700"] = { StoryMin=71, Variant="Neophyte Shade", Yaw=90 },
    ["-12710,-5420,820"] = { StoryMin=50, Variant="Breacher Shade", Yaw=90 },
    ["-13280,-5550,700"] = { StoryMin=50, Variant="Grunt Shade", Yaw=90 },
    ["-12530,-5040,700"] = { StoryMin=71, Variant="Neophyte Shade", Yaw=90 },
    ["-20380,-2960,730"] = { StoryMin=46, Variant="Roaming Shade" },
    ["-19720,-3460,730"] = { StoryMin=46, Variant="Roaming Shade" },

    -- 1st sector
    ["-11140,-1570,690"] = { Hard=true, StoryMin=46, StoryMax=50, Variant="Roaming Shade", NoPatrol=true, Yaw=75 },
    ["-12720,-5170,730"] = { StoryMin=47, Variant="LabRat Shade" },

    -- 2nd sector
    ["-13290,-5890,830"] = { Hard=true, StoryMin=46, StoryMax=50, Variant="Roaming Shade", NoPatrol=true, Yaw=30 },
    ["-19120,-350,390"] = { Hard=true, StoryMin=44, Variant="Roaming Shade", NoPatrol=true, Yaw=0, BaseRadius=1000 },
    ["-18240,-3440,1040"] = { Hard=true, StoryMin=44, Variant="Roaming Shade", NoPatrol=true, Yaw=0 },

    -- 3rd sector
    ["-17670,-4030,1900"] = { Variant="Roaming Shade" },
    ["-19770,-3540,2030"] = { Hard=true, StoryMin=44, Variant="Roaming Shade", NoPatrol=true, Yaw=0 },
    ["-18330,-4630,1390"] = { Hard=true, StoryMin=46, Variant="Grunt Shade", NoPatrol=true, Yaw=0 },

    -- 4th sector exit door
    ["-21830,170,730"] = { StoryMin=47, StoryMax=50, Variant="Roaming Shade", NoPatrol=true, Yaw=0, BaseRadius=250 },
    ["-21810,-250,730"] = { StoryMin=47, StoryMax=50, Variant="Roaming Shade", NoPatrol=true, Yaw=0, BaseRadius=250 },

-- =======================================================================
-- SECURITY VIGNETTES
-- =======================================================================
    
    
    -- NIGHT REALM
    -- 3rd section
    ["25470,-234520,5390"] = { Hard=true, StoryMin=45, StoryMax=50, Variant="LabRat Shade", NoPatrol=true, Yaw=15 },
    ["25950,-234380,6090"] = { StoryMin=45, StoryMax=50, Variant="Roaming Shade", NoPatrol=true, Yaw=0 }, 
    ["26610,-232560,6090"] = { Hard=true, StoryMin=45, StoryMax=50, Variant="Breacher Shade", NoPatrol=true, Yaw=-90 },
    ["27540,-236670,6090"] = { StoryMin=45, StoryMax=50, Variant="Roaming Shade", NoPatrol=true, Yaw=-60 },
    ["28250,-236570,6090"] = { StoryMin=45, StoryMax=50, Variant="Roaming Shade", NoPatrol=true, Yaw=-110 },
    ["27500,-237950,6350"] = { Hard=true, StoryMin=45, StoryMax=50, Variant="Grunt Shade", BaseRadius=1500, VariantRadius=1500 },
    ["28160,-236680,6090"] = { StoryMin=46, StoryMax=50, Variant="Roaming Shade" },

    -- 4th section
    ["36350,-233790,5490"] = { StoryMin=46, StoryMax=50, Variant="Roaming Shade", BaseRadius=1000, VariantRadius=1000 },
    ["36040,-233020,5870"] = { Hard=true, StoryMin=46, StoryMax=50, Variant="LabRat Shade", NoPatrol=true, Yaw=0 },
    ["36030,-234400,5840"] = { Hard=true, StoryMin=46, StoryMax=50, Variant="Grunt Shade", NoPatrol=true, Yaw=90 },
    ["36040,-234870,5870"] = { Hard=true, StoryMin=46, StoryMax=50, Variant="Roaming Shade", BaseRadius=1000, VariantRadius=1000 },
    ["34740,-236010,5840"] = { Hard=true, StoryMin=46, StoryMax=50, Variant="Grunt Shade", NoPatrol=true, Yaw=-45 },
    ["33810,-235130,5420"] = { StoryMin=46, StoryMax=50, Variant="Roaming Shade", BaseRadius=1000, VariantRadius=1000 },
    ["35030,-234960,5390"] = { StoryMin=46, StoryMax=50, Variant="Roaming Shade", NoPatrol=true, Yaw=-170 },

    -- Throne room
    ["34210,-231480,5690"] = { Hard=true, StoryMin=46, StoryMax=50, Variant="Grunt Shade", NoPatrol=true, Yaw=-90, BaseRadius=250, VariantRadius=250 },
    ["34600,-231520,5690"] = { Hard=true, StoryMin=46, StoryMax=50, Variant="Grunt Shade", NoPatrol=true, Yaw=-90, BaseRadius=250, VariantRadius=250 },
    ["33690,-232980,5590"] = { StoryMin=46, StoryMax=50, Variant="Roaming Shade", NoPatrol=true, Yaw=70, BaseRadius=500, VariantRadius=500 },
    ["35300,-232010,5590"] = { StoryMin=46, StoryMax=50, Variant="Roaming Shade", NoPatrol=true, Yaw=180, BaseRadius=500, VariantRadius=500 },
    ["34320,-232770,5590"] = { StoryMin=46, StoryMax=50, Variant="LabRat Shade", BaseRadius=1500, VariantRadius=1500 },
    ["34340,-230945,5590"] = { StoryMin=46, StoryMax=50, Variant="Roaming Shade" },

    -- CANAAN

    -- Behind the gate (in case players scale it)
    ["139340,30050,50430"] = { Variant="Canaan Marksman", NoPatrol=true, Yaw=-150, BaseRadius=500, VariantRadius=500 },
    ["138970,30750,50430"] = { Variant="Canaan Marksman", NoPatrol=true, Yaw=-150, BaseRadius=500, VariantRadius=500 },

    -- Outer camp
    ["139980,26770,49560"] = { Hard=true, Variant="Canaan Farmer", NoPatrol=true, Yaw=-90, BaseRadius=250, VariantRadius=250 },
    ["140500,23150,49600"] = { Hard=true, Variant="Canaan Marksman", NoPatrol=true, Yaw=100, BaseRadius=500 },

    -- Windmill / Farm
    ["138940,19540,49850"] = { Variant="Outcast", NoPatrol=true, Yaw=150, BaseRadius=500 },
    ["139530,19200,49850"] = { Hard=true, Variant="Outcast", NoPatrol=true, Yaw=-30, BaseRadius=1000 },
    ["142980,16260,50080"] = { Hard=true, Variant="Canaan Lumberjack", NoPatrol=true, Yaw=-90, BaseRadius=500 },
    ["144050,18230,49740"] = { Hard=true, Variant="Canaan Lumberjack", NoPatrol=true, Yaw=20, BaseRadius=500 },
    ["150510,16090,51250"] = { Hard=true, Variant="Canaan Fanatic", NoPatrol=true, Yaw=-120, BaseRadius=1000, VariantRadius=1000 },
    ["149690,16610,51220"] = { Hard=true, Variant="Canaan Marksman", NoPatrol=true, Yaw=100, BaseRadius=1000 },

    -- Village entrance
    ["148940,21090,51000"] = { Hard=true, Variant="Chosen Canaan Farmer", NoPatrol=true, Yaw=-70, BaseRadius=500, VariantRadius=500 },
    ["147710,20640,50620"] = { Hard=true, Variant="Chosen Canaan Fanatic", NoPatrol=true, Yaw=-70, BaseRadius=500, VariantRadius=500 },
    ["148550,20550,50620"] = { Hard=true, Base="Pillager_Torchbearer", NoPatrol=true, Yaw=-130, BaseRadius=500 },

    -- Village square
    ["152390,28020,50770"] = { Hard=true, Variant="Chosen Canaan Fanatic", NoPatrol=true, Yaw=180, BaseRadius=500, VariantRadius=500 },
    ["148340,28010,50870"] = { Variant="Canaan Farmer", NoPatrol=true, Yaw=90, BaseRadius=250, VariantRadius=250 },

    -- Main Village area
    ["144560,31410,50460"] = { Hard=true, Variant="Canaan Marksman", NoPatrol=true, Yaw=0, BaseRadius=500, VariantRadius=500 },
    ["148380,31230,51310"] = { Hard=true, Variant="Canaan Marksman", NoPatrol=true, Yaw=90, BaseRadius=500, VariantRadius=500 },
    ["145400,30310,50830"] = { Hard=true, Variant="Canaan Marksman", NoPatrol=true, Yaw=90, BaseRadius=500, VariantRadius=500 },
    ["144520,35920,50520"] = { Variant="Canaan Farmer", NoPatrol=true, Yaw=45, BaseRadius=250, VariantRadius=250 },

    -- Blacksmith Hut
    ["150940,33880,51030"] = { Variant="Chosen Canaan Fanatic", NoPatrol=true, Yaw=30, BaseRadius=500 },
    ["150630,34390,51030"] = { Hard=true, Variant="Chosen Canaan Fanatic", NoPatrol=true, Yaw=30, BaseRadius=500 },
    ["150690,33760,51030"] = { Hard=true, Variant="Chosen Canaan Farmer", NoPatrol=true, Yaw=-150, BaseRadius=500, VariantRadius=500 },

    -- Mines
    ["145960,38830,51140"] = { Hard=true, Variant="Chosen Canaan Miner", NoPatrol=true, Yaw=-130, BaseRadius=500, VariantRadius=500 },
    ["144030,41320,51100"] = { Hard=true, Variant="Chosen Canaan Miner", NoPatrol=true, Yaw=50, BaseRadius=500, VariantRadius=500 },
    ["148940,38400,51610"] = { Variant="Canaan Marksman", NoPatrol=true, Yaw=-90, BaseRadius=250, VariantRadius=250 },
    ["144920,40250,51100"] = { Variant="Canaan Fanatic", NoPatrol=true, Yaw=-40, BaseRadius=500, VariantRadius=500 },
    ["143910,40780,51100"] = { Base="Pillager_Musketeer", NoPatrol=true, Yaw=-40, BaseRadius=500 },
    ["141080,44000,52000"] = { Variant="Canaan Fanatic", NoPatrol=true, Yaw=-100, BaseRadius=500, VariantRadius=500 },
    
    ["140360,43130,51960"] = { Variant="Chosen Canaan Miner", NoPatrol=true, Yaw=0, BaseRadius=500, VariantRadius=500 },

    -- Hill to Niketas
    ["153880,35530,51570"] = { Variant="Canaan Farmer", NoPatrol=true, Yaw=0, BaseRadius=250 },
    ["154100,33180,52800"] = { Variant="Canaan Marksman", NoPatrol=true, Yaw=120, BaseRadius=250 },

    -- Niketas 
    ["153540,30760,52730"] = { Variant="Chosen Canaan Farmer", NoPatrol=true, Yaw=50, BaseRadius=250 },
    ["153230,31000,52730"] = { Variant="Chosen Canaan Farmer", NoPatrol=true, Yaw=50, VariantRadius=250 },
    -- ["153510,30450,52730"] = { Variant="Chosen Canaan Farmer", NoPatrol=true, Yaw=50, BaseRadius=500 },
    -- ["153020,30960,52730"] = { Variant="Chosen Canaan Farmer", NoPatrol=true, Yaw=50, VariantRadius=250 },
    ["153040,30970,52730"] = { Hard=true, Base="Pillager_Preacher", NoPatrol=true, Yaw=30, BaseRadius=500 },
    ["153610,30480,52730"] = { Hard=true, Base="Pillager_Preacher", NoPatrol=true, Yaw=75, BaseRadius=500 },

    -- Swamp
    ["149660,53640,54300"] = { Variant="Outcast", NoPatrol=true, Yaw=-140 },
    ["149880,52330,54300"] = { Variant="Outcast", NoPatrol=true, Yaw=160 },
    
    -- Unsorted
    ["150200,30790,50430"] = { Variant="Canaan Marksman", NoPatrol=true, Yaw=-90, BaseRadius=250, VariantRadius=250 },
    ["149010,28180,50870"] = { Variant="Canaan Farmer", NoPatrol=true, Yaw=120, BaseRadius=250, VariantRadius=250 },


-- =======================================================================
-- HYDROPLANT
-- =======================================================================
    -- Entrance
    ["-25360,-280,-680"] = { StoryMin=50, Variant="Electro Peccary" },
    ["-31150,810,-130"] = { StoryMin=50, Variant="Exor Repeller", NoPatrol=true, Yaw=180 },
    ["-34040,2150,-100"] = { StoryMin=50, Variant="Hive Sow" },
    ["-35910,4380,-100"] = { Hard=true, StoryMin=50, Variant="Exor Magus" },
    ["-26570,1320,-340"] = { Hard=true, StoryMin=50, Variant="Exorrior Magus", NoPatrol=true, Yaw=-30, BaseRadius=500 },
    ["-26120,490,-730"] = { Hard=true, StoryMin=50, Variant="Exorrior Magus", NoPatrol=true, Yaw=90, BaseRadius=500 },
    ["-28840,730,-730"] = { Hard=true, StoryMin=50, Variant="Carbunccary", NoPatrol=true, Yaw=90, BaseRadius=1000 },
    ["-37130,5110,600"] = { Hard=true, StoryMin=50, Variant="Twilight Sniper", Yaw=-30, BaseRadius=1000 },
    ["-38130,4120,1260"] = { Hard=true, StoryMin=50, Variant="Centurion Grunt", NoPatrol=true, Yaw=-45 },
    
    -- Tower 2-4
    ["-41170,-4430,10"] = { StoryMin=50, Base="Exor_Armored" },
    ["-40140,-3480,10"] = { Hard=true, StoryMin=50, Variant="Antefire Exor" },
    ["-40200,-3880,610"] = { StoryMin=50, Variant="Magma Peccary" },
    ["-36550,-2350,50"] = { StoryMin=50, Variant="Suppressor Grunt", BaseRadius=1000, VariantRadius=1000 },
    ["-35650,-1900,50"] = { Hard=true, StoryMin=50, Variant="Skirmisher", BaseRadius=1000 },
    ["-35870,-2890,610"] = { StoryMin=50, Variant="Grenadier Guard", BaseRadius=1000 },
    ["-41630,-3800,610"] = { Hard=true, StoryMin=50, Variant="Twilight Sniper", Yaw=-160 },

    -- Electrical Station
    ["-36710,3830,190"] = { Hard=true, StoryMin=50, Variant="Exor Repeller", BaseRadius=1500 },
    ["-36620,5140,-100"] = { Hard=true, StoryMin=50, Variant="Shield Grunt" },
    ["-37880,4980,-130"] = { Hard=true, StoryMin=50, Base="Grunt", NoPatrol=true, Yaw=-90, BaseRadius=1000 },
    ["-39160,4430,0"] = { Hard=true, StoryMin=50, Base="Grunt", NoPatrol=true, Yaw=-90, BaseRadius=1000 },
    ["-39260,2370,-100"] = { Hard=true, StoryMin=50, Variant="Twilight Sniper", Yaw=-140, BaseRadius=1000 },
    ["-39430,2780,860"] = { StoryMin=50, Variant="Electro Peccary" },
    ["-39570,4380,1200"] = { StoryMin=50, Variant="Charge Peccary" },
    ["-42170,5040,1160"] = { StoryMin=50, Variant="Sweeper", BaseRadius=1000, VariantRadius=1000 },
    ["-41230,4010,1160"] = { StoryMin=50, Base="Grunt", BaseRadius=750 },
    ["-38700,5430,-130"] = { Hard=true, StoryMin=50, Variant="Exor Shadow Monk", NoPatrol=true, BaseRadius=1500, VariantRadius=1500, Yaw=-150 },
    ["-39170,5840,1510"] = { StoryMin=50, Variant="Exor Repeller", NoPatrol=true, BaseRadius=1000 },
    ["-40310,6380,1370"] = { StoryMin=50, Variant="Exor Displacer", NoPatrol=true, BaseRadius=1000 },

    -- Storage
    ["-37050,5950,1200"] = { StoryMin=50, Base="Grunt_Captain", NoPatrol=true, Yaw=-150, BaseRadius=1000 },
    ["-38640,4850,560"] = { Hard=true, StoryMin=50, Variant="Exor Displacer", NoPatrol=true, Yaw=35, BaseRadius=1000 },
    
    -- Storage-Waterfall outdoor
    ["-41000,7190,-130"] = { StoryMin=50, Variant="Exor Repeller", NoPatrol=true, Yaw=30, BaseRadius=1000 },
    ["-36960,9930,560"] = { Hard=true, StoryMin=50, Variant="Tracer Sniper", Yaw=-50, BaseRadius=1000 },
    ["-40990,8860,1250"] = { Hard=true, StoryMin=50, Variant="Twilight Sniper", Yaw=-150, BaseRadius=1000 },

    -- Tower 1-3
    ["-43750,6740,610"] = { StoryMin=50, Variant="Constrictor Bot" },
    ["-46310,3280,50"] = { StoryMin=50, Base="Robot_Defense", BaseRadius=1000 },  
    ["-47850,5570,770"] = { StoryMin=50, Variant="Artillery Bot", Yaw=-45, BaseRadius=500 },  
    --["-47750,5490,800"] =  { Variant="Artillery Bot", BaseRadius=500, VariantRadius=500, StoryMin=50 },  

    -- Submarine
    ["-41230,9540,-100"] = { StoryMin=50, Variant="Antefire Exor", NoPatrol=true, Yaw=-90 },
    ["-39660,9450,-100"] = { Hard=true, StoryMin=50, Base="Exor_Armored", NoPatrol=true, Yaw=-150, BaseRadius=1000 },
    ["-41030,8680,-100"] = { StoryMin=50, Base="Peccary", BaseRadius=2500 },
    ["-39640,8960,-1290"] = { StoryMin=50, Base="Exor_Armored", NoPatrol=true, Yaw=-120, BaseRadius=1000 },
    ["-40390,9380,-1400"] = { StoryMin=50, Variant="Hive Sow", NoPatrol=true, Yaw=-30 },
    ["-40660,8020,-800"] = { StoryMin=50, Variant="Anterazor Pest" },
    ["-40540,7830,-1440"] = { Hard=true, StoryMin=50, Variant="Chonky Signal Pest", NoPatrol=true, Yaw=100 },
    ["-41550,9140,-40"] = { StoryMin=50, Base="Pest_Electro", NoPatrol=true, Yaw=-45, BaseRadius=500 },
    ["-40030,9270,-100"] = { StoryMin=50, Variant="Exor Magus", NoPatrol=true, Yaw=30, BaseRadius=1000, VariantRadius=1000 },

    -- Waterfall Apts shore
    ["-50270,4700,-770"] = { StoryMin=50, Variant="Orchestrator" },

    -- Waterfall Apts
    ["-46400,10230,2530"] = { StoryMin=50, Variant="Antesignal Pest", BaseRadius=1000 },
    ["-46890,10890,2530"] = { StoryMin=50, Variant="Phase Peccary", BaseRadius=3000 },
    ["-49270,5220,1300"] = { StoryMin=50, Variant="Exor Repeller", NoPatrol=true, Yaw=50, BaseRadius=1000 },
    ["-49050,6750,400"] = { StoryMin=50, Variant="Anterazor Pest", BaseRadius=1000 },
    ["-50110,7020,-200"] = { StoryMin=50, Variant="Exor Repeller", NoPatrol=true, Yaw=-130, BaseRadius=500 },
    ["-50140,7330,1400"] = { Hard=true, StoryMin=50, Variant="Exor Displacer", NoPatrol=true, Yaw=15, BaseRadius=1000, VariantRadius=1000 },
    ["-49310,8030,1300"] = { Hard=true, StoryMin=50, Variant="Signal Pest", NoPatrol=true, Yaw=130, BaseRadius=1000 },
    ["-51000,8330,1370"] = { StoryMin=50, Variant="Exor Shadow Monk", NoPatrol=true, Yaw=-140, BaseRadius=1000 },
    ["-50560,6680,1370"] = { StoryMin=50, Variant="Hive Sow", NoPatrol=true, Yaw=20, BaseRadius=1000 },
    ["-46950,8200,430"] = { StoryMin=50, Base="Pest", NoPatrol=true, Yaw=20, BaseRadius=2000 },
    ["-48170,7420,1300"] = { Hard=true, StoryMin=50, Variant="Exor Superior", BaseRadius=3000 },
    -- ["-47260,9600,2500"] = { Hard=true, StoryMin=50, Variant="Antesignal Pest", BaseRadius=3000 },

    -- Bridge
    ["-46080,10240,1030"] = { StoryMin=50, Variant="Commander", Yaw=45 },
    ["-44560,11960,630"] = { StoryMin=50, Variant="Twilight Sniper", Yaw=-130, BaseRadius=250 },
    ["-44050,12200,630"] = { Hard=true, StoryMin=50, Variant="Twilight Sniper", Yaw=50, BaseRadius=250 },

    -- Hydroplant End Entrance
    ["-38680,15350,1490"] = { StoryMin=54, Variant="Artillery Bot", Yaw=-160, BaseRadius=500, Opts={ ArtilleryProfile="SiegeEvent" } },
    ["-37740,21480,600"] = { StoryMin=50, Variant="Deatomizer Bot", NoPatrol=true, Yaw=-130, BaseRadius=1000, VariantRadius=1000 },
    ["-32350,21940,580"] = { StoryMin=50, Variant="Artillery Bot", BaseRadius=500 },
    ["-34190,20880,590"] = { Hard=true, StoryMin=50, Base="Robot_Defense", NoPatrol=true, Yaw=-50, BaseRadius=1000 },

    -- Hydroplant
    ["-36140,23310,2360"] = { StoryMin=50, Variant="Signal Pest", NoPatrol=true, Yaw=130 },
    ["-34320,21390,2300"] = { Hard=true, StoryMin=50, Variant="Antegrav Pest" },
    ["-34930,22040,2280"] = { Hard=true, StoryMin=50, Variant="Phase Peccary", NoPatrol=true, Yaw=-70 },
    ["-33960,22160,2260"] = { Hard=true, StoryMin=50, Base="Sow", NoPatrol=true, Yaw=-120 },

    -- Void entrance
    ["-40300,10850,-700"] = { StoryMin=50, Variant="Laser Pest", BaseRadius=1000 },
    ["-40490,11610,-170"] = { Hard=true, StoryMin=50, Base="Exor_Armored", BaseRadius=1000 },

    -- unsorted


    -- ["-37630,3130,-1430"] = { Variant="Advanced Big Bot", StoryMin=50 },

-- =======================================================================
-- HYDROPLANT VIGNETTES
-- =======================================================================

    -- VOUSSOIR
    -- Lower
    ["-278450,75690,-8090"] = { Hard=true, Variant="Groupe Rookram" },
    ["-276190,76700,-7830"] = { Hard=true, Variant="Groupe Rookram" },

    -- Upper
    ["-277620,78260,-2590"] = { Hard=true, Variant="Groupe Frostpack", NoPatrol=true, Yaw=-45, BaseRadius=1500, VariantRadius=1500 },
    ["-278080,78340,-2590"] = { Hard=true, Variant="Groupe Rookram", NoPatrol=true, Yaw=-45, BaseRadius=1500, VariantRadius=1500 },
    ["-277600,76830,-1430"] = { Hard=true, Variant="Groupe Sniper", Yaw=45 },
    ["-276320,76300,-1020"] = { Hard=true, Variant="Groupe Frostpack", BaseRadius=500, VariantRadius=500 },
    ["-278950,79160,-1070"] = { Hard=true, Variant="Groupe Breacher", NoPatrol=true, Yaw=-45, BaseRadius=500, VariantRadius=500 },
    ["-276710,76890,-610"] = { Hard=true, Variant="Groupe Sniper", Yaw=130 },
    ["-279390,83030,-1930"] = { Hard=true, Variant="Groupe Sniper", Yaw=-75 },

    -- Slopes
    ["-271910,86560,-7730"] = { Hard=true, Variant="Groupe Sniper", Yaw=-30, BaseRadius=1500 },
    
    --Yetis: New spawn is a later flag just in case
    -- ["-272630,86070,-9580"] = { Hard=true, StoryMin=58, Variant="Blizzard Yeti", NoPatrol=true, Yaw=0, BaseRadius=750, VariantRadius=750 },

-- =======================================================================
-- POWER SERVICES
-- =======================================================================

    -- Entrance
    ["-28830,7910,-10450"] = { Base="Peccary_Mushroom" },
    ["-27470,10055,-10450"] = { Variant="Antegrav Exor", BaseRadius=3000 },
    ["-30970,11350,-10410"] = { Hard=true, Base="Peccary_Mushroom" },
    ["-27320,10100,-10450"] = { Hard=true, Variant="Exor Dislocator", NoPatrol=true, Yaw=-140, BaseRadius=1500 },
    ["-26150,4420,-10120"] = { Hard=true, Variant="Exor Dislocator", BaseRadius=2500 },

    -- Power House
    ["-30320,4020,-9850"] = { Variant="Exorrior Magus", NoPatrol=true, Yaw=0, BaseRadius=1500 },
    ["-30250,1340,-9750"] = { Variant="Antesignal Pest", NoPatrol=true, Yaw=120, BaseRadius=1500 },
    ["-31600,3740,-9250"] = { Variant="Chonky Pest" },
    ["-30990,1690,-9750"] = { Hard=true, Variant="Exor Superior", BaseRadius=2000 },
    ["-30990,2930,-9250"] = { Hard=true, Variant="Hive Sow" },
    ["-30620,3600,-9250"] = { Hard=true, Variant="Armored Peccary", NoPatrol=true, Yaw=120 },
    ["-30300,3100,-9250"] = { Hard=true, Base="Exor_Armored", BaseRadius=1000 },

    -- Check-In room
    ["-29030,-570,-9700"] = { Base="Exor_Armored", NoPatrol=true, Yaw=150, BaseRadius=1000 },
    ["-29330,-920,-9700"] = { Variant="Phase Peccary", NoPatrol=true, Yaw=120 },
    ["-28880,510,-9700"] = { Hard=true, Variant="Chonky Signal Pest", NoPatrol=true, Yaw=-80, BaseRadius=1000 },
    ["-28760,-410,-9700"] = { Hard=true, Variant="Exor Superior", NoPatrol=true, Yaw=90, BaseRadius=500 },

    -- Tram
    ["-27700,1470,-10050"] = { Variant="Magma Exor", NoPatrol=true, Yaw=30, BaseRadius=1000 },
    ["-25870,1300,-9930"] = { Variant="Antefire Exor", NoPatrol=true, Yaw=120, BaseRadius=1000 },
    ["-27110,2680,-10050"] = { Variant="Magma Peccary" },
    ["-25640,3090,-10050"] = { Variant="Magma Pest" },
    ["-26420,1040,-9930"] = { Variant="Magma Pest" },
    ["-26590,1550,-9100"] = { Hard=true, Variant="Magma Exor", NoPatrol=true, Yaw=30, BaseRadius=1000 },
    ["-25280,2680,-10050"] = { Hard=true, Variant="Magma Exor", NoPatrol=true, Yaw=150, BaseRadius=500 },

    -- Orange bloom
    ["-23430,7520,-8970"] = { Variant="Phase Peccary", BaseRadius=2000 },
    ["-24980,5610,-9970"] = { Variant="Hive Sow" },
    ["-25160,4330,-9860"] = { Variant="Chonky Pest" },

    -- Blue bloom
    ["-28570,13050,-10150"] = { Variant="Antegrav Exor", NoPatrol=true, Yaw=-120, BaseRadius=1500 },
    ["-26940,14300,-9110"] = { Variant="Antefire Exor", BaseRadius=1500 },
    ["-27320,15620,-8730"] = { Variant="Exorrior Magus", NoPatrol=true, Yaw=-45, BaseRadius=1000 },
    ["-25330,14100,-9630"] = { Variant="Exor Magus", NoPatrol=true, Yaw=-90, BaseRadius=1000 },
    ["-29720,11930,-10150"] = { Variant="Armored Peccary" },
    ["-26910,13590,-10050"] = { Hard=true, Variant="Exor Magus", NoPatrol=true, Yaw=-30, BaseRadius=1000 },

    -- Purple bloom    
    ["-21865,14235,-9975"] = { Variant="Exor Displacer", NoPatrol=true, BaseRadius=1000, VariantRadius=1000 },
    ["-21400,10580,-10200"] = { Variant="Signal Pest", BaseRadius=750 },
    ["-21210,11170,-9360"] = { Variant="Antesignal Pest", NoPatrol=true, Yaw=-90, BaseRadius=750 },

    -- Fungal bloom
    ["-27720,10280,-10410"] = { StoryMin=62, Variant="Exor Spiritwalker", NoPatrol=true, Yaw=-120, BaseRadius=500 },
    ["-27240,9620,-10450"] = { Hard=true, StoryMin=62, Variant="Exor Spiritwalker", NoPatrol=true, Yaw=-140, BaseRadius=500 },


    -- Pool 
    ["-32930,17475,-10655"] = { Variant="Chonky Signal Pest", BaseRadius=750, NearFastCheck=15, ActiveRadius=15000 },
    ["-33610,16840,-10655"] = { Variant="Signal Pest", BaseRadius=750, NearFastCheck=15, ActiveRadius=15000 },
    ["-31585,19685,-10655"] = { Variant="Anterazor Pest", BaseRadius=2500, NearFastCheck=15, ActiveRadius=15000 },
    ["-32545,19380,-11255"] = { Variant="Antegrav Exor", BaseRadius=1500, NearFastCheck=15, ActiveRadius=15000 },
    ["-35245,19285,-11080"] = { Variant="Antegrav Pest", BaseRadius=500, NearFastCheck=15, ActiveRadius=15000 },
    ["-35920,20260,-11080"] = { Variant="Antegrav Exor", BaseRadius=1500, NearFastCheck=15, ActiveRadius=15000 },
    ["-33850,21915,-11115"] = { Variant="Phase Peccary", NearFastCheck=15, ActiveRadius=15000 },
    ["-35575,22200,-10475"] = { Variant="Phase Peccary", NearFastCheck=15, ActiveRadius=15000 },
    ["-35570,19000,-10550"] = { Variant="Anterazor Pest", BaseRadius=500, NearFastCheck=15, ActiveRadius=15000 },
    ["-22264,9236,-8770"] = { Variant="Antefire Exor", NearFastCheck=15, ActiveRadius=15000 },
    
-- =======================================================================
-- POWER SERVICES VIGNETTES
-- =======================================================================

    -- EXOR VILLAGE
    -- Entrance
    ["22400,-324590,2740"] = { Base="Pest" },
    ["25380,-323540,3010"] = { Base="Pest" },
    ["22050,-324550,3200"] = { Variant="Exor Magus", NoPatrol=true, Yaw=30, BaseRadius=1500, NearFastCheck=15, ActiveRadius=5000 },    
    ["23770,-321320,2820"] = { Hard=true, Variant="Exor Shadow Monk", NoPatrol=true, Yaw=120, BaseRadius=1500, VariantRadius=1500, NearFastCheck=15, ActiveRadius=5000 },
    ["24360,-324670,3690"] = { Hard=true, Variant="Exorrior", NoPatrol=true, Yaw=120, BaseRadius=1500, NearFastCheck=15, ActiveRadius=5000 },
    ["23010,-323740,2960"] = { StoryMin=62, Variant="Exor Spiritwalker", NoPatrol=true, Yaw=30, NearFastCheck=15, ActiveRadius=5000 },
    ["24390,-322670,3040"] = { Hard=true, StoryMin=62, Variant="Exor Spiritwalker", NoPatrol=true, Yaw=180, NearFastCheck=15, ActiveRadius=5000 },

    -- Waterfall
    ["25650,-326490,100"] = { Hard=true, Variant="Signal Pest", NoPatrol=true, Yaw=-90, BaseRadius=1500, VariantRadius=1500 },
    ["26030,-327180,170"] = { Variant="Phase Peccary" },

    -- Warhead
    ["28930,-335260,290"] = { Variant="Exor Dislocator", NoPatrol=true, Yaw=0, BaseRadius=1000 },
    ["29060,-335760,400"] = { Base="Peccary", NoPatrol=true, Yaw=20, BaseRadius=1000 },
    ["24150,-335780,-340"] = { Variant="Phase Peccary", NoPatrol=true, Yaw=20, BaseRadius=1000 },
    ["23970,-335460,-380"] = { Hard=true, Variant="Exor Repeller", NoPatrol=true, Yaw=30, BaseRadius=1000 },
    ["25180,-334985,-335"] = { Hard=true, Variant="Exor Spiritwalker", NoPatrol=true, Yaw=180, BaseRadius=1000, VariantRadius=1000 },

    -- Outpost
    ["37620,-334950,220"] = { Variant="Exor Displacer" },
    ["36890,-335090,250"] = { Variant="Exor Displacer" },
    ["37530,-334320,50"] = { Hard=true, Base="Exor_Pikeman", NoPatrol=true, Yaw=-45, BaseRadius=1500 },
    
    -- Bonepile
    ["29240,-338790,1560"] = { Hard=true, Variant="Carbunccary", NoPatrol=true, Yaw=0, BaseRadius=1000 },

    -- Chieftain Hut
    ["29420,-333330,1940"] = { Variant="Exor Repeller", NoPatrol=true, Yaw=-90, BaseRadius=500 },
    ["30470,-333560,2000"] = { Variant="Chonky Pest", BaseRadius=2500, VariantRadius=2500 },
    ["28850,-333190,1940"] = { Hard=true, Variant="Exor Spiritwalker", NoPatrol=true, Yaw=-90, BaseRadius=500, VariantRadius=500 },
    

    -- Bridge overlook    
    ["27000,-336350,2090"] = { Variant="Antefire Exor", NoPatrol=true, Yaw=-90, BaseRadius=2500 },

    -- Waterfall walkway
    ["19730,-336650,1170"] = { Variant="Signal Pest", NoPatrol=true, Yaw=0 },
    ["21500,-331260,210"] = { Hard=true, Variant="Exor Superior", NoPatrol=true, Yaw=-100, BaseRadius=1500 }, 

    -- South corner
    ["22420,-339600,1000"] = { Variant="Exor Spiritwalker", NoPatrol=true, Yaw=-90, BaseRadius=1500 },
    ["24140,-339470,1000"] = { Variant="Razor Pest", NoPatrol=true, Yaw=-90 },
    ["25840,-337820,2460"] = { Variant="Signal Pest", NoPatrol=true, Yaw=-140, BaseRadius=1500 },

    ["24110,-330680,880"] = { Hard=true, Variant="Exor Superior", NoPatrol=true, Yaw=120, BaseRadius=1500, VariantRadius=1500 }, 
    
    -- Could place a hidden enemy above the roof
    -- ["21060,-334070,8280"]  = { Variant="Swole Exor" },

-- =======================================================================
-- REACTORS
-- =======================================================================


    ------------------------------------------
    -- DUSK
    ------------------------------------------
    -- HALLS Central-Dusk
    ["-12990,21645,-16385"] = { Variant="Sweeper", NoPatrol=true },
    ["-12615,21350,-16350"] = { Variant="Suppressor Grunt", NoPatrol=true },
    ["-13165,21980,-16350"] = { Variant="Suppressor Grunt", NoPatrol=true },
    ["-15400,35520,-16760"] = { Hard=true, Variant="Tracer Sniper", Yaw=-150 },
    ["-15380,37730,-15590"] = { StoryMax=72, Variant="Trident", NoPatrol=true, Yaw=-150 },
    ["-15420,38140,-15590"] = { StoryMax=72, Variant="Sweeper", NoPatrol=true, Yaw=-150 },
    ["-15100,38000,-15590"] = { Hard=true, StoryMax=72, Variant="Suppressor Grunt", NoPatrol=true, Yaw=-150 },
    ["-13130,20000,-15730"] = { Hard=true, StoryMin=71, Variant="Mad Rat", Yaw=90 },
    ["-7970,18130,-16700"] = { StoryMin=72, Variant="Jotun Rocketeer", Yaw=40 },
    
    -- Lobby
    ["-17090,37880,-15700"] = { Hard=true, StoryMin=71, Variant="Barrier Mage", NoPatrol=true, Yaw=130, BaseRadius=1500 },
    ["-17840,35570,-15700"] = { Hard=true, StoryMax=72, Variant="Leyak Menace", NoPatrol=true, Yaw=130 },
    ["-18050,36300,-15700"] = { Hard=true, StoryMax=72, Variant="Leyak Menace", NoPatrol=true, Yaw=130 },
    ["-19450,36820,-15240"] = { Variant="Exor Repeller", BaseRadius=2000 },
    ["-18770,44460,-15230"] = { Hard=true, Variant="Warden Eye", BaseRadius=2500 },
    ["-18550,38890,-15000"] = { Hard=true, StoryMin=71, Variant="Exor Displacer", BaseRadius=2000 },
    ["-19330,41900,-15800"] = { Hard=true, StoryMin=71, Variant="Neophyte Trainer", NoPatrol=true, Yaw=-150, BaseRadius=1500, VariantRadius=1500 },
    ["-20950,41250,-15800"] = { StoryMin=71, Variant="Neophyte Trainer", NoPatrol=true, Yaw=0, BaseRadius=2500, VariantRadius=2500 },

    -- Cafeteria
    ["-26960,42350,-15230"] = { Variant="Antesignal Pest", NoPatrol=true, Yaw=45, BaseRadius=1000 },

    -- Offices
    ["-14720,41120,-14930"] = { Variant="Volatile Peccary", NoPatrol=true, Yaw=130, BaseRadius=1000, VariantRadius=1000 },
    ["-14680,42010,-14350"] = { Variant="Signal Pest", NoPatrol=true, Yaw=30, BaseRadius=1000, VariantRadius=1000 },
    ["-14940,43990,-14900"] = { Variant="Pestilence", NoPatrol=true, Yaw=-45, BaseRadius=1000 },
    ["-16140,43120,-14640"] = { Variant="Antevolatile Pest", NoPatrol=true, Yaw=-90, BaseRadius=1000, VariantRadius=1000 },
    ["-16680,44580,-14510"] = { Hard=true, Variant="Exor Magus", BaseRadius=1500 },
    
    -- Offices - Locked
    ["-13100,43560,-14930"] = { Hard=true, Variant="Laser Pest", NoPatrol=true, Yaw=-45, BaseRadius=500, VariantRadius=500 },
    ["-11860,44590,-15000"] = { Variant="Chonky Signal Pest", NoPatrol=true, Yaw=-130, BaseRadius=1000 },
    ["-11850,46360,-14900"] = { Variant="Exorrior" },
    ["-13730,44290,-15000"] = { Variant="Exor Superior", NoPatrol=true, Yaw=30, BaseRadius=2000, VariantRadius=2000 },

    -- Hallway Reactor Core
    ["-21250,48230,-15230"] = { Variant="Exor Repeller" },
    ["-19970,45700,-15200"] = { Variant="Antegrav Exor" },

    -- Reactor Core
    ["-23180,49580,-14900"] = { Hard=true, Variant="Rocket Rat", BaseRadius=500 },

    -- Reactor Core corridor
    ["-23630,45740,-15800"] = { StoryMin=71, Variant="Warden Eye" },


    ------------------------------------------
    -- CLOUD
    ------------------------------------------
    -- HALLS Central-Cloud
    ["-7780,15280,-16290"] = { StoryMin=71, Variant="Rocket Rat", NoPatrol=true, Yaw=130, BaseRadius=250, VariantRadius=3000 },
    ["-8110,15000,-16290"] = { Hard=true, StoryMin=71, Variant="Mad Rat", NoPatrol=true, Yaw=130, BaseRadius=250, VariantRadius=3000 },
    ["-7760,14880,-16290"] = { StoryMin=71, Base="Grunt_Medic", NoPatrol=true, Yaw=130, BaseRadius=3000 },
    ["-8250,15510,-16250"] = { Hard=true, StoryMin=71, Base="Grunt", NoPatrol=true, Yaw=130, BaseRadius=3000 },
    ["-14930,36250,-16790"] = { Hard=true, StoryMin=73, Variant="Jotun Rocketeer", Yaw=-130 },
    ["-16470,30890,-16140"] = { Hard=true, StoryMin=73, Variant="Jotun Steed" },

    -- Outside
    ["-8470,8630,-17590"] = { Hard=true, StoryMax=74, Variant="Twilight Sniper", Yaw=100 },
    ["-5360,14280,-17590"] = { Hard=true, StoryMax=74, Base="Grunt_Sniper", Yaw=-120 },
    ["2400,14820,-17450"] = { StoryMin=72, Base="Gatekeeper_Phyter" },
    ["-1430,15100,-17480"] = { Hard=true, StoryMin=72, StoryMax=79, Variant="Skirmisher", BaseRadius=2000 },
    ["-30,16490,-17570"] = { Hard=true, StoryMin=72, StoryMax=79, Variant="Skirmisher", BaseRadius=750 },
    ["7670,21380,-17540"] = { Hard=true, StoryMin=72, StoryMax=79, Base="Gatekeeper_Phyter", BaseRadius=2000 },
    ["5160,18220,-17570"] = { Hard=true, StoryMin=72, Variant="Beholder Mage" },
    ["1270,15160,-17570"] = { Hard=true, StoryMin=72, Variant="Jotun Steed" },
    ["-3820,12000,-17540"] = { StoryMin=72, Variant="Jotun Rocketeer", NoPatrol=true, Yaw=30 },

    -- Tram Tower
    ["100,16310,-16240"] = { Hard=true, Variant="Commander", Yaw=-50 },
    ["850,18830,-15800"] = { Hard=true, Variant="Centurion Grunt", Yaw=-45 },
    ["540,18430,-15800"] = { Hard=true, Variant="Shield Grunt", Yaw=-45 },

    -- Jotun Hill
    ["-3850,4630,-15200"] = { Hard=true, Variant="Artillery Bot", Yaw=50, BaseRadius=1000, VariantRadius=1000 },
    ["-1770,6630,-16050"] = { Hard=true, StoryMax=72, Variant="Advanced Big Bot", NoPatrol=true, Yaw=50 },
    ["910,7110,-16480"] = { Hard=true, StoryMax=72, Variant="Constrictor Bot", NoPatrol=true, Yaw=120 },

    -- Plant Rooftop
    ["12880,12190,-14110"] = { StoryMax=72, Variant="Warden Eye", Yaw=-160, BaseRadius=1000 },
    ["4690,7910,-14370"] = { Variant="Warden Eye", NoPatrol=true, Yaw=-65, BaseRadius=1000 },
    ["4790,9310,-14370"] = { Base="Gatekeeper_Mage", NoPatrol=true, Yaw=-90, BaseRadius=2000 },
    ["7070,10350,-14610"] = { Hard=true, Variant="Tracer Sniper", Yaw=-150, BaseRadius=1000 },
    ["10860,12710,-14110"] = { Hard=true, StoryMax=72, Variant="Mad Rat", NoPatrol=true, Yaw=-150, BaseRadius=1000, VariantRadius=1000 },
    ["8400,9550,-12930"] = { Hard=true, Variant="Artillery Bot", Yaw=120, BaseRadius=1000 },
    ["12560,12590,-12910"] = { Hard=true, StoryMax=72, Variant="Artillery Bot", Yaw=120, BaseRadius=1000 },
    ["16330,13120,-13210"] = { Hard=true, StoryMax=72, Variant="Tracker Sniper", Yaw=90, BaseRadius=1000 },

    -- Plant Staircase
    ["15910,13040,-15010"] = { Hard=true, Variant="Mad Rat", Yaw=45, BaseRadius=1000 },
    ["15980,14700,-18260"] = { Variant="Commander", Yaw=-50, BaseRadius=2500 },

    -- Plant Floor Outside
    ["18610,15620,-17670"] = { Hard=true, Variant="Twilight Sniper", Yaw=180, BaseRadius=1000 },
    ["18130,16390,-18730"] = { Variant="Signal Pest", NoPatrol=true, BaseRadius=1000 },
    ["19520,18540,-18010"] = { Hard=true, StoryMax=72, Variant="Sweeper", NoPatrol=true, Yaw=-130, BaseRadius=1000 },
    ["13520,20340,-18060"] = { Hard=true, StoryMax=72, Base="Grunt_Sniper", Yaw=-30, BaseRadius=1000 },
    
    -- Plant MG Nest
    ["19710,18320,-17270"] = { Hard=true, StoryMax=72, Variant="Suppressor Grunt" },

    -- Plant Sewers
    ["7880,16340,-16510"] = { Variant="Warden Eye", BaseRadius=3000 },
    ["8650,17220,-17410"] = { Variant="Exorrior Magus", BaseRadius=3000 },
    ["9530,14710,-17535"] = { StoryMax=72, Variant="Pestilence", BaseRadius=1000 },
    ["10150,16160,-17380"] = { Hard=true, Variant="Abjurer Mage", NoPatrol=true, Yaw=-45, BaseRadius=500 },
    ["9760,14260,-16810"] = { Hard=true, Base="Gatekeeper_Heavy", NoPatrol=true, Yaw=-150, BaseRadius=1000 },
    ["9780,13410,-17410"] = { Hard=true, Variant="Warden Eye", NoPatrol=true, Yaw=-150, BaseRadius=1000 },

    -- Plant Reactor
    ["5610,12010,-17380"] = { Hard=true, StoryMax=72, Variant="Grenadier Guard", NoPatrol=true, Yaw=90, BaseRadius=1000 },
    ["6270,11690,-17380"] = { Hard=true, StoryMax=72, Variant="Centurion Grunt", NoPatrol=true, Yaw=120, BaseRadius=1000 },
    ["7770,9920,-17410"] = { Hard=true, StoryMax=72, Variant="Mad Rat", NoPatrol=true, Yaw=130, BaseRadius=500, VariantRadius=500 },
    ["8640,9580,-17410"] = { StoryMin=74, Variant="Jotun Steed", NoPatrol=true, Yaw=-130, BaseRadius=2500, VariantRadius=2500 },
    ["6790,6970,-17970"] = { Hard=true, StoryMax=72, Variant="Twilight Sniper", Yaw=30, BaseRadius=1000 },
    ["10650,9780,-17940"] = { Hard=true, StoryMax=72, Variant="Tracker Sniper", Yaw=-130, BaseRadius=1000 },
    ["7950,14750,-17410"] = { Hard=true, StoryMin=72, Variant="Beholder Mage", NoPatrol=true, Yaw=-140, BaseRadius=1500 },

    ------------------------------------------
    -- MIST
    ------------------------------------------
    -- HALLS Cloud-Mist
    ["2550,27210,-14940"] = { Hard=true, Variant="Signal Pest", NoPatrol=true, Yaw=-130, BaseRadius=1000 },
    ["6880,32090,-15730"] = { Variant="Chonky Signal Pest", NoPatrol=true, Yaw=130, BaseRadius=1000 },
    ["4080,26340,-16510"] = { Hard=true, Variant="Signal Pest", NoPatrol=true, Yaw=180, BaseRadius=1000 },
    
    -- Entrance
    ["6870,32730,-15700"] = { Variant="Exor Superior", NoPatrol=true, Yaw=130, BaseRadius=2000, VariantRadius=2000 },
    ["10800,34030,-15700"] = { Hard=true, Variant="Magma Peccary", NoPatrol=true, Yaw=180, BaseRadius=2000 },
    ["8210,33370,-15700"] = { StoryMin=73, Base="Robot_Corrupt", NoPatrol=true, BaseRadius=2000 },
    
    -- Turbine01
    ["9250,35520,-15950"] = { Hard=true, Variant="Magma Exor", NoPatrol=true, Yaw=-90, BaseRadius=1000 },
    ["9330,34800,-15950"] = { Hard=true, Variant="Magma Pest", NoPatrol=true, Yaw=70, BaseRadius=1000 },
    ["8790,35870,-14850"] = { Hard=true, Variant="Exor Displacer", NoPatrol=true, Yaw=130, BaseRadius=1000 },
    ["8610,35640,-14850"] = { Variant="Antefire Exor", NoPatrol=true, Yaw=130, BaseRadius=1000 },

    
    -- Control Center    
    ["10300,36210,-14800"] = { Variant="Antesignal Pest", NoPatrol=true, Yaw=-150, BaseRadius=1000 },
    ["9480,34350,-14800"] = { Variant="Carbunccary", BaseRadius=1000 },
    ["11290,35500,-14500"] = { Variant="Leyak Menace", BaseRadius=1000 },
    ["9210,34980,-14810"] = { Variant="Leyak Pest", Yaw=-50, BaseRadius=1000 },
    ["9630,36380,-14740"] = { Hard=true, Variant="Razor Pest", BaseRadius=2000 },
    ["10250,35070,-14800"] = { Hard=true, Variant="Exorrior Magus", BaseRadius=2000, VariantRadius=2000 },
    ["11940,34580,-14240"] = { Hard=true, Variant="Exor Repeller", NoPatrol=true, Yaw=120, BaseRadius=1000, VariantRadius=1000 },
    ["10790,34840,-14510"] = { Hard=true, Variant="Charge Peccary", BaseRadius=1000 },
    ["11850,37000,-14210"] = { Hard=true, Variant="Phase Peccary", BaseRadius=2000 },

    -- Roadway
    ["15950,33310,-15740"] = { Hard=true, Variant="Antesignal Pest", NoPatrol=true, Yaw=-150, BaseRadius=250 },
    ["12210,34080,-15550"] = { StoryMin=73, Base="Robot_Corrupt", BaseRadius=2000 },

    -- Turbine02
    ["18790,33870,-15740"] = { Hard=true, Variant="Exorrior", NoPatrol=true, Yaw=150 },
    ["18090,35870,-15740"] = { Hard=true, Variant="Exor Displacer", NoPatrol=true, Yaw=-30, BaseRadius=2500 },
    ["16340,36570,-15740"] = { Hard=true, Variant="Chonky Signal Pest", NoPatrol=true, Yaw=0, BaseRadius=750 },
    ["16320,34130,-15700"] = { StoryMin=73, Base="Robot_Corrupt", NoPatrol=true, BaseRadius=1500 },

    -- Reactor Core
    ["10160,38590,-15740"] = { Variant="Signal Pest", NoPatrol=true, Yaw=45, BaseRadius=1000 },
    ["13500,42400,-15760"] = { Hard=true, Variant="Signal Pest", NoPatrol=true, Yaw=-120, BaseRadius=1000 },
    ["12990,43270,-14570"] = { Hard=true, Variant="Exor Magus", NoPatrol=true, Yaw=-60, BaseRadius=2500 },
    ["15360,42640,-15770"] = { Hard=true, Variant="Exorrior", NoPatrol=true, Yaw=-120, BaseRadius=2500 },
    ["15170,40430,-15210"] = { Hard=true, Variant="Exor Repeller", NoPatrol=true, Yaw=150 },

    -- Unsorted
    -- ["12200,34170,-15500"] = { Variant="Mad Rat" },
    

    ------------------------------------------
    -- GALE
    ------------------------------------------
    -- HALLS Mist-Gale
    ["-3400,3810,-17490"] = { StoryMin=72, Variant="Jotun Rocketeer", NoPatrol=true, Yaw=-140 },
    ["-1650,32780,-17000"] = { Hard=true, StoryMin=73, Base="Grunt_Sniper", Yaw=90 },
    ["-360,33390,-17030"] = { Hard=true, StoryMin=73, Variant="Commander", Yaw=90 },
    ["60,32970,-17000"] = { Hard=true, StoryMin=73, Variant="Super Sapper", NoPatrol=true, Yaw=-140, BaseRadius=2500, VariantRadius=2500 },
    ["-4730,38470,-17500"] = { Hard=true, StoryMin=73, Variant="Jotun Rocketeer", NoPatrol=true, Yaw=0 },

    -- Lobby
    ["-1110,38560,-15690"] = { Variant="Mad Rat", BaseRadius=2500 },
    ["-1980,40500,-15690"] = { Variant="Neophyte Trainer" },
    ["-1480,41460,-15690"] = { Variant="Skirmisher", Yaw=-110, BaseRadius=1000, VariantRadius=1000 },
    ["-1630,41530,-15690"] = { Variant="Rocket Rat", Yaw=-110, BaseRadius=1000 },
    ["-870,42490,-15330"] = { Hard=true, Variant="Jotun Steed", NoPatrol=true, Yaw=150, BaseRadius=2000 },
    ["670,40360,-15690"] = { Hard=true, Variant="Sweeper", NoPatrol=true, Yaw=60, BaseRadius=1000, VariantRadius=1000 }, 
    ["1420,41570,-15460"] = { Variant="Sweeper", NoPatrol=true, Yaw=-120, BaseRadius=1000, VariantRadius=1000 }, 
    
    -- War Trench
    ["1440,46060,-15990"] = { Variant="Rocket Rat", NoPatrol=true, Yaw=-25, BaseRadius=1500, VariantRadius=1500 }, 
    ["670,46460,-16000"] = { Variant="Shield Grunt", Yaw=-25, BaseRadius=2000 }, 
    ["-400,45630,-15590"] = { Variant="Groupe Sniper", Yaw=-20, BaseRadius=1000, VariantRadius=1000 },
    ["1110,47510,-15950"] = { Variant="Commander", Yaw=-30, BaseRadius=1000, VariantRadius=1000 },


    --------------------------------
    -- Order - Lobby Entrance
    ["-2740,44570,-15730"] = { Variant="Tracker Sniper", Yaw=150, BaseRadius=1000 },
    ["-4140,43700,-15730"] = { Variant="Mad Rat", NoPatrol=true, Yaw=150, BaseRadius=1500 },
    ["-4630,43810,-15730"] = { Hard=true, Variant="Sweeper", NoPatrol=true, Yaw=60, BaseRadius=1000, VariantRadius=1000 },
    ["-3560,43470,-15730"] = { Hard=true, Variant="Centurion Grunt", NoPatrol=true, Yaw=150, BaseRadius=1000, VariantRadius=1000 },
    ["-5990,45250,-15790"] = { Hard=true, Variant="Super Sapper", NoPatrol=true, Yaw=70, BaseRadius=2000, VariantRadius=2000 },

    -- Order - Fuel Room
    ["-3040,47650,-15990"] = { Variant="Commander", BaseRadius=500, VariantRadius=500 },
    ["-810,48710,-16030"] = { Hard=true, Variant="Signifer", NoPatrol=true, Yaw=45, BaseRadius=500, VariantRadius=500 },
    ["-100,49220,-15430"] = { Variant="Sweeper", BaseRadius=1500, VariantRadius=1500 },
    ["-200,49220,-15430"] = { Hard=true, Variant="Sweeper", BaseRadius=1500, VariantRadius=1500 }, 
    ["-2920,46310,-15970"] = { Variant="Centurion Grunt", BaseRadius=1500, VariantRadius=1500 },
    ["-50,48320,-15430"] = { Hard=true, Variant="Shield Grunt", BaseRadius=1500 }, 
    ["-2370,49720,-15350"] = { Hard=true, Variant="Groupe Sniper", Yaw=-110, BaseRadius=1000, VariantRadius=2500 },
    ["-1780,46480,-16030"] = { Variant="Suppressor Grunt", NoPatrol=true, Yaw=60, BaseRadius=1000 },
    ["-640,48640,-16030"] = { Hard=true, Variant="Suppressor Grunt", NoPatrol=true, Yaw=-120, BaseRadius=750 },
    ["-4310,49440,-16270"] = { Hard=true, Variant="Centurion Grunt", NoPatrol=true, Yaw=-30, BaseRadius=2500, VariantRadius=2500 },
    ["-3510,50840,-15530"] = { Hard=true, Variant="Tracker Sniper", Yaw=-30, BaseRadius=500 },
    ["-4550,47440,-16430"] = { Base="Grunt_Shotgun", BaseRadius=2500 },
    ["-2500,46540,-16380"] = { Base="Grunt_Medic", BaseRadius=1500 },

    -- Order - Sniper Nest
    ["-5740,47210,-16030"] = { Variant="Centurion Grunt", Yaw=-120, BaseRadius=2500, VariantRadius=2500 },
    ["-6030,47290,-15400"] = { Hard=true, Variant="Shield Grunt", NoPatrol=true, Yaw=60 },

    -- Order - Lower Offices
    ["-1520,43910,-16680"] = { Variant="Rocket Rat", NoPatrol=true, Yaw=150, BaseRadius=1000, VariantRadius=1000 },
    ["310,45060,-16660"] = { Hard=true, Variant="Chonky Signal Pest", NoPatrol=true, Yaw=150, BaseRadius=1000 },
    ["-120,47980,-16400"] = { Variant="Velites Guard", NoPatrol=true, Yaw=-150, BaseRadius=1000 },


    ------------------------------
    -- GK - Lobby Entrance
    ["2640,41430,-15710"] = { Variant="Jotun Rocketeer", NoPatrol=true, Yaw=110, BaseRadius=1000 }, 
    ["4250,39740,-15710"] = { Hard=true, Base="Robot_Corrupt", NoPatrol=true, Yaw=150, BaseRadius=2000 }, 

    -- GK - Pool room
    ["6450,45100,-15330"] = { Variant="Warden Eye", NoPatrol=true, BaseRadius=1000, VariantRadius=1000 },
    ["5700,42220,-16330"] = { Hard=true, Base="Gatekeeper_Mage", BaseRadius=2000 }, 
    ["5800,39520,-15080"] = { Hard=true, Variant="Barrier Mage", BaseRadius=2000 },
    ["6800,41730,-15330"] = { Hard=true, Variant="Gatekeeper Warchief", BaseRadius=1000, VariantRadius=2000 }, 
    ["6120,42120,-15830"] = { Hard=true, Base="Gatekeeper_Phyter", NoPatrol=true, BaseRadius=1000 }, 
    ["6170,45340,-16030"] = { Variant="Neophyte Trainer", NoPatrol=true, Yaw=-40, BaseRadius=1000, VariantRadius=1000 }, 

    -- GK - Reactor Entrance
    ["4030,48120,-15710"] = { Hard=true, Base="Robot_Corrupt", NoPatrol=true, Yaw=45, BaseRadius=3000 },
    ["5410,48620,-15710"] = { Hard=true, Variant="Constrictor Bot", NoPatrol=true, Yaw=-120, BaseRadius=3000 },
    ["2700,47860,-15760"] = { Hard=true, Variant="Barrier Mage", NoPatrol=true, Yaw=-60, BaseRadius=2000 },

    -- GK - Lower offices
    ["2030,42390,-16490"] = { Variant="Beholder Mage", NoPatrol=true, Yaw=-110, BaseRadius=2000, VariantRadius=2000 }, 
    ["4510,46320,-16730"] = { Variant="Esoteric Chieftain", NoPatrol=true, Yaw=160, BaseRadius=1000, VariantRadius=2000 },


    -- Reactor Central
    ["5160,50030,-16230"] = { Hard=true, Base="Gatekeeper_Heavy", NoPatrol=true, Yaw=150, BaseRadius=2000 },

    -- ??
    ["-17595,36977,-15315"] = { Variant="Antefire Exor" },

    

    ------------------------------------------
    -- FUSION CORE
    ------------------------------------------
    -- Entrance
    ["-10070,23210,-15800"] = { StoryMin=78, Variant="Jotun Rocketeer", NoPatrol=true, Yaw=-150, VariantRadius=1000 },
    ["-10690,24040,-15800"] = { StoryMin=78, Variant="Jotun Rocketeer", NoPatrol=true, Yaw=-120, VariantRadius=1000 },

    ["-5150,28970,-16360"] = { StoryMin=78, Variant="Orchestrator" },
    ["-4200,28000,-16360"] = { StoryMin=78, Variant="Orchestrator" },
    ["-11180,29380,-15540"] = { StoryMin=78, StoryMax=90, Base="Robot_Corrupt" },
    ["-11010,29130,-15500"] = { Hard=true, StoryMin=78, StoryMax=90, Variant="Constrictor Bot" },
    ["-3630,30960,-14900"] = { StoryMin=78, StoryMax=90, Variant="Mad Rat", Yaw=-140, BaseRadius=1500 },
    ["-3170,30500,-16500"] = { StoryMin=78, StoryMax=90, Variant="Rocket Rat", Yaw=-140, BaseRadius=1500 },
    ["-6200,30960,-14600"] = { StoryMin=78, StoryMax=90, Variant="Sweeper", Yaw=-140 },
    ["-6420,31320,-14600"] = { StoryMin=78, StoryMax=90, Variant="Trident", Yaw=-140 },
    ["-11220,33320,-16700"] = { StoryMin=78, StoryMax=90, Variant="Neophyte Trainer", Yaw=-20 },
    ["-12270,32970,-16700"] = { StoryMin=78, StoryMax=90, Variant="Esoteric Chieftain", Yaw=-40 },
    ["-12070,33660,-16740"] = { Hard=true, StoryMin=78, StoryMax=90, Variant="Jotun Rocketeer" },

-- =======================================================================
-- REACTORS VIGNETTES - SHADOWGATE
-- =======================================================================
    -- Outdoors
    ["-318180,210000,1530"] = { Base="Gatekeeper_Witch", Yaw=-10 },
    ["-317670,209220,1530"] = { Base="Gatekeeper_Witch", Yaw=76 },
    ["-320420,216120,1400"] = { Variant="Storm Witch", BaseRadius=1500 },

    -- First hill
    ["-318420,214860,1850"] = { Hard=true, Variant="Artillery Bot" },
    ["-318980,214530,1850"] = { Hard=true, Variant="Gatekeeper Warchief", NoPatrol=true, Yaw=-45 },
    ["-317840,212090,1810"] = { Variant="Warden Eye", Yaw=50 }, 

    -- Witch's hut    
    ["-311510,217180,1380"] = { StoryMin=80, Variant="Jotun Steed" },
    ["-311260,218720,1660"] = { StoryMin=80, Variant="Storm Witch", NoPatrol=true, Yaw=-130, BaseRadius=500 },

    -- Ruined building
    ["-316230,215300,1300"] = { Hard=true, Base="Gatekeeper_Witch", NoPatrol=true, Yaw=0, BaseRadius=3000 },

    -- Tunnel Entrance
    ["-321130,219060,2450"] = { Base="Gatekeeper_Mage", NoPatrol=true, BaseRadius=2500 },
    ["-323370,215920,1150"] = { Variant="Warden Eye" },
    ["-321470,217650,1260"] = { Hard=true, Variant="Jotun Rocketeer", NoPatrol=true, Yaw=180 },
    ["-322260,216100,1260"] = { Hard=true, Variant="Jotun Rocketeer", NoPatrol=true, Yaw=110 },

    -- Swamp
    ["-320120,215720,1400"] = { Base="Robot_Corrupt", NoPatrol=true },
    ["-318240,217040,980"] = { Variant="Abjurer Mage", NoPatrol=true, Yaw=-10, BaseRadius=1500 },
    ["-318770,217250,950"] = { Variant="Plague Witch", NoPatrol=true, Yaw=-10, BaseRadius=1000 },
    ["-320530,222400,1030"] = { Variant="Plague Witch" },

    -- Second hill near tunnel
    ["-318100,219680,2470"] = { Variant="Warden Eye", NoPatrol=true, BaseRadius=2500 },

    -- Entrance to Shadowgate
    -- Left gate
    ["-332270,214070,650"] = { Variant="Neophyte Trainer", NoPatrol=true, Yaw=0 },
    ["-331340,213700,650"] = { Variant="Neophyte Trainer", NoPatrol=true, Yaw=60 },
    ["-332160,214580,650"] = { Hard=true, Base="Robot_Corrupt", NoPatrol=true, Yaw=0 },
    ["-332390,216070,2140"] = { Hard=true, Variant="Warrior Witch", NoPatrol=true, Yaw=-45, BaseRadius=2000 },

    -- Front gate
    ["-326910,210900,710"] = { Variant="Artillery Bot", BaseRadius=1500 },
    ["-329620,210160,670"] = { Hard=true, Variant="Deatomizer Bot", NoPatrol=true, Yaw=-10, BaseRadius=2500 },
    ["-326840,209440,570"] = { Base="Robot_Corrupt", NoPatrol=true },
    ["-325620,205650,1140"] = { Variant="Jotun Rocketeer", NoPatrol=true, Yaw=110 },

    -- Right gate
    ["-332570,205060,1040"] = { Variant="Jotun Rocketeer", NoPatrol=true, Yaw=0 },

    ["-312590,211300,2050"] = { Base="Robot_Corrupt", NoPatrol=true },

    
    -- Compound
    ["-333820,209890,920"] = { Variant="Jotun Rocketeer", NoPatrol=true, Yaw=35, BaseRadius=1500 },
    ["-336590,211600,790"] = { Variant="Warrior Witch", NoPatrol=true, Yaw=-20, BaseRadius=1000, VariantRadius=2000 },
    ["-334940,211980,560"] = { Variant="Beholder Mage", NoPatrol=true, Yaw=-20 },
    ["-341330,211480,1700"] = { Variant="Storm Witch", NoPatrol=true, Yaw=-80, BaseRadius=1000, VariantRadius=500 },

    -- Inside Shadowgate
    ["-336500,210530,750"] = { Hard=true, Variant="Jotun Steed", NoPatrol=true, Yaw=70 },
    ["-337360,210720,750"] = { Hard=true, Variant="Esoteric Chieftain", NoPatrol=true, Yaw=-110, BaseRadius=2500, VariantRadius=2500 },

    -- Inside Shadowgate Portal Room
    ["-339600,210200,1340"] = { Variant="Beholder Mage", NoPatrol=true, Yaw=17, BaseRadius=1500 },
    ["-341545,211960,1302"] = { Variant="Warden Eye", NoPatrol=true, BaseRadius=1500 },
    ["-343480,211660,1340"] = { Base="Gatekeeper_Witch", NoPatrol=true, Yaw=-10, BaseRadius=1000 },
    ["-337960,211190,910"] = { Base="Gatekeeper_Witch", NoPatrol=true, Yaw=70, BaseRadius=1000 },
    ["-337420,212730,910"] = { Base="Gatekeeper_Phyter", NoPatrol=true, Yaw=-110, BaseRadius=1000 },
    ["-338040,215080,360"] = { Variant="Warden Eye", NoPatrol=true, Yaw=-110, BaseRadius=2500 },
    ["-340640,212600,390"] = { Variant="Warrior Witch", NoPatrol=true, Yaw=160, BaseRadius=400, VariantRadius=500 },
    ["-341260,212840,350"] = { Variant="Plague Witch", NoPatrol=true, Yaw=-10, BaseRadius=250, VariantRadius=250 },
    ["-339260,215350,1300"] = { Hard=true, Variant="Advanced Big Bot" },
    ["-342100,212790,350"] = { Hard=true, Variant="Warden Eye", NoPatrol=true, BaseRadius=1000 },
    ["-338500,211680,350"] = { Hard=true, Base="Robot_Corrupt" },
    ["-341900,215250,900"] = { Hard=true, Base="Gatekeeper_Mage", NoPatrol=true, Yaw=-110, BaseRadius=500 },
    ["-342340,214340,1080"] = { Hard=true, Variant="Beholder Mage", NoPatrol=true, Yaw=160, BaseRadius=500 },
    ["-341090,215880,1300"] = { Hard=true, Variant="Constrictor Bot" },
    -- ["-318770,217250,950"] = { Variant="Plague Witch", Yaw=-10, NoPatrol=true },


-- =======================================================================
-- PRAETORIUM
-- =======================================================================

    -- Cafeteria
    ["87250,27400,-1900"] = { Variant="Velites Guard", NoPatrol=true, Yaw=-90, BaseRadius=400 },
    ["87750,27400,-1900"] = { Base="Grunt_Guard", NoPatrol=true, Yaw=-90, BaseRadius=500 },
    ["87050,27360,-1900"] = { Base="Grunt_Captain", NoPatrol=true, Yaw=-90, BaseRadius=500 },
    ["87550,27410,-1900"] = { Hard=true, Variant="Shield Grunt", NoPatrol=true, Yaw=-90 },
    ["87150,26880,-1900"] = { Variant="Skirmisher", NoPatrol=true, Yaw=-90, BaseRadius=1000 },
    ["87650,26330,-1900"] = { Variant="Grenadier Guard", NoPatrol=true, Yaw=-90, BaseRadius=400 },
    ["87110,26410,-1900"] = { Variant="Trident", NoPatrol=true, Yaw=-90, BaseRadius=750 },
    ["87640,25850,-1900"] = { Hard=true, Variant="Shield Grunt", NoPatrol=true, Yaw=-90, BaseRadius=1000 },
    ["87210,25850,-1900"] = { Base="Grunt_Shotgun", NoPatrol=true, Yaw=90, BaseRadius=500 },
    ["86760,25610,-1900"] = { Variant="Suppressor Grunt", NoPatrol=true, Yaw=90, BaseRadius=250 },
    ["87730,25310,-1900"] = { Hard=true, Variant="Sweeper", NoPatrol=true, Yaw=-90, BaseRadius=500 },
    ["87400,25300,-1900"] = { Variant="Centurion Grunt", NoPatrol=true, Yaw=-90, BaseRadius=500 },
    ["87480,24410,-1900"] = { Hard=true, Variant="Suppressor Grunt", NoPatrol=true, Yaw=180, BaseRadius=400 },
    ["86860,24830,-1900"] = { Hard=true, Variant="Speculatores", NoPatrol=true, Yaw=180, BaseRadius=500 },
    ["87980,25580,-1900"] = { Hard=true, Variant="Speculatores", NoPatrol=true, Yaw=180, BaseRadius=500 },
    ["84780,26120,-2230"] = { Hard=true, Variant="Tracer Sniper", Yaw=0 },

    -- Entrance
    ["86680,23250,-2640"] = { Variant="Tracer Sniper", NoPatrol=true, Yaw=90 },
    ["87170,23460,-2640"] = { Variant="Shield Embolon", NoPatrol=true, Yaw=-90, BaseRadius=1500 },
    ["88550,28450,-3160"] = { Variant="Mad Rat", NoPatrol=true, Yaw=-90 },
    ["86700,24840,-3240"] = { Variant="Sweeper", NoPatrol=true, Yaw=0, BaseRadius=1500 },
    ["89480,24810,-3240"] = { Variant="Skirmisher", NoPatrol=true, Yaw=180, BaseRadius=1500 },
    ["87970,23060,-3500"] = { Base="Grunt_Sapper", NoPatrol=true, Yaw=-20, BaseRadius=750 },

    -- Lower level - left hall
    ["92140,21930,-3220"] = { Variant="Shield Embolon", NoPatrol=true, Yaw=180 },
    ["92150,22300,-3220"] = { Variant="Shield Embolon", NoPatrol=true, Yaw=180 },
    ["92130,21590,-3220"] = { Variant="Shield Embolon", NoPatrol=true, Yaw=180 },
    ["92540,22070,-3220"] = { Variant="Centurion Grunt", NoPatrol=true, Yaw=180, BaseRadius=1000 },
    ["92530,21770,-3220"] = { Variant="Centurion Grunt", NoPatrol=true, Yaw=180, BaseRadius=750 },
    ["94070,21210,-3140"] = { Hard=true, Variant="Twilight Sniper", NoPatrol=true, Yaw=90, BaseRadius=1000 },
    ["96760,21750,-3220"] = { Variant="Shield Embolon", NoPatrol=true, Yaw=-140 },
    ["97130,21730,-3220"] = { Variant="Signifer", NoPatrol=true, Yaw=-140 },
    ["95600,22000,-2810"] = { Hard=true, Variant="Praetorium Sniper", Yaw=0, BaseRadius=1500 },

    -- Lower level - middle hall
    ["94960,23100,-2520"] = { Hard=true, Variant="Mad Rat", NoPatrol=true, Yaw=180, BaseRadius=1000 },
    ["94930,23160,-3040"] = { Hard=true, Variant="Signifer", NoPatrol=true, Yaw=180, BaseRadius=1000, VariantRadius=1000 },

    -- Lower level - right hall
    ["93430,24800,-3220"] = { Hard=true, Variant="Rocket Rat", NoPatrol=true, Yaw=-150, BaseRadius=1500 },
    ["96400,27890,-2730"] = { Variant="Speculatores", NoPatrol=true, Yaw=-140 },
    ["97000,27430,-2730"] = { Variant="Speculatores", NoPatrol=true, Yaw=180 },
    ["96820,27920,-2730"] = { Variant="Dioscoridian", NoPatrol=true, Yaw=180, BaseRadius=2500, VariantRadius=2500 },
    ["97380,26500,-2770"] = { Variant="Signifer", NoPatrol=true, Yaw=140, BaseRadius=2500 },
    ["96050,23180,-1540"] = { Hard=true, Variant="Praetorium Sniper", Yaw=90, BaseRadius=1500 },
    ["94720,26760,-1760"] = { Hard=true, Variant="Suppressor Grunt", NoPatrol=true, Yaw=0, BaseRadius=1000, VariantRadius=1000 },

    -- Upper level - elevator
    ["97480,27050,1200"] = { Variant="Skirmisher", NoPatrol=true, Yaw=-140 },
    ["97570,25960,1200"] = { Hard=true, Variant="Skirmisher", NoPatrol=true, Yaw=180 },
    ["99020,26500,1200"] = { Variant="Suppressor Grunt", NoPatrol=true, Yaw=-140, BaseRadius=2000 },
    ["98760,26390,1200"] = { Variant="Shield Embolon", NoPatrol=true, Yaw=-140 },
    ["95390,29420,11400"] = { Hard=true, Variant="Twilight Sniper", Yaw=-90, BaseRadius=1000, VariantRadius=1000 },

    -- Upper level - pre-library
    ["101440,29150,1150"] = { Hard=true, Base="Grunt_FlameRat", NoPatrol=true, Yaw=-130 },
    ["99190,31570,1200"] = { Base="Grunt_FlameRat", NoPatrol=true, Yaw=0 },
    ["99150,31400,1200"] = { Hard=true, Variant="Sweeper", NoPatrol=true, Yaw=0 },
    ["98350,32050,1180"] = { Hard=true, Variant="Commander", Yaw=0, BaseRadius=2000 },
    ["98070,34080,1250"] = { Hard=true, Base="Interfector", Yaw=-90, BaseRadius=1000 },
    ["92020,29730,1150"] = { Hard=true, Variant="Commander", Yaw=0 },
    ["102740,31130,1250"] = { Variant="Praetorium Sniper", Yaw=-90, BaseRadius=1000 },
    ["102570,31140,1250"] = { Hard=true, Base="Interfector", NoPatrol=true, Yaw=-90, BaseRadius=1000 },
    ["101370,28950,1110"] = { Variant="Centurion Grunt", NoPatrol=true, Yaw=-140, BaseRadius=100 },
    ["101240,29100,1110"] = { Variant="Speculatores", NoPatrol=true, Yaw=-140, BaseRadius=100 },

    -- Upper level - Control Spire
    ["93440,33280,1830"] = { Variant="Event FlameRat", NoPatrol=true, Yaw=180, BaseRadius=1000 }, 
    ["97710,34200,3030"] = { Hard=true, Base="Interfector", NoPatrol=true, Yaw=-90, BaseRadius=1000 }, 
    -- Night Realm portal - 91900,33030,1710, Yaw=0   (siege ends at 98240,33960,2980)

    -- Portal Shortcut
    ["100330,37980,1600"] = { Hard=true, Variant="Peremptor", NoPatrol=true, Yaw=0, BaseRadius=1500, VariantRadius=1500 }, 

    -- Library
    ["100130,34050,1780"] = { Variant="Praetorium Library Sniper", Yaw=-45, BaseRadius=1000 },
    ["102520,34470,1130"] = { Variant="Praetorium Library Sniper", Yaw=180, BaseRadius=1000 },
    ["103420,36350,1810"] = { Hard=true, Variant="Praetorium Library Sniper", Yaw=-90, BaseRadius=1000 },
    ["103400,32430,930"] = { Hard=true, Variant="Praetorium Library Sniper", Yaw=180, BaseRadius=1000 },
    ["105110,34620,100"] = { Variant="Shield Embolon", Yaw=40 },
    ["104660,34670,100"] = { Variant="Shield Embolon", Yaw=100 },
    ["104000,36840,730"] = { Variant="Salii", Yaw=0, BaseRadius=750, VariantRadius=1000 },
    ["101080,36300,730"] = { Variant="Praetorium Sniper", Yaw=0, BaseRadius=1500 },

    -- Post-Library
    ["102430,36600,760"] = { Hard=true, Variant="Peremptor", NoPatrol=true, Yaw=90, BaseRadius=1000, VariantRadius=1000 },
    ["103370,36330,1250"] = { Hard=true, Variant="Purifier", NoPatrol=true, Yaw=180, BaseRadius=2000 },
    ["102900,38360,1610"] = { Hard=true, Variant="Mad Rat", BaseRadius=2500 },
    ["99970,39340,1210"] = { Hard=true, Variant="Twilight Sniper", Yaw=0, BaseRadius=1000 },
    ["107610,36860,1250"] = { Hard=true, Base="Interfector", Yaw=140 },

    -- Blockade
    ["105070,44320,810"] = { Hard=true, Variant="Twilight Sniper", Yaw=-90, BaseRadius=1000 },
    ["104060,44550,810"] = { Hard=true, Variant="Tracer Sniper", Yaw=-90, BaseRadius=1000 },
    ["104570,42730,1310"] = { Hard=true, Variant="Rocket Rat", Yaw=-90, BaseRadius=1500 },
    ["103860,41140,1200"] = { Hard=true, Variant="Super Sapper", Yaw=-90, BaseRadius=1500 },
    ["105540,41320,1200"] = { Hard=true, Variant="Rocket Rat", Yaw=-90, BaseRadius=1500 },

    -- Command entrance
    ["102080,49890,1110"] = { Hard=true, Variant="Praetorium Sniper", Yaw=0, BaseRadius=2500, VariantRadius=2500 },
    ["107690,45550,1250"] = { Hard=true, Variant="Praetorium Sniper", Yaw=180, BaseRadius=500, VariantRadius=500 },

    -- Command
    ["106960,46370,1450"] = { Variant="Praetorium Sniper", Yaw=90, BaseRadius=100, VariantRadius=2500 },
    ["105550,48420,960"] = { Base="Trooper", NoPatrol=true, Yaw=0, BaseRadius=100 },
    ["105600,48100,960"] = { Variant="Centurion Grunt", NoPatrol=true, Yaw=0, BaseRadius=100 },
    ["108430,49180,1410"] = { Base="Trooper", Yaw=90, BaseRadius=1000 },
    ["108370,49360,1410"] = { Base="Clericus", NoPatrol=true, Yaw=0, BaseRadius=1000 },
    ["108500,49070,1410"] = { Variant="Salii", NoPatrol=true, Yaw=-120, BaseRadius=250, VariantRadius=1000 },
    ["109190,49800,1000"] = { Hard=true, Variant="Twilight Sniper", NoPatrol=true, Yaw=-120, BaseRadius=500 },
    -- ["106840,46100,1250"] = { Hard=true, Variant="Peremptor", NoPatrol=true, Yaw=0, BaseRadius=500, VariantRadius=500 },
    
    -- Sun Disk 
    ["105200,51000,2450"] = { Variant="Shield Embolon", NoPatrol=true, Yaw=-30, BaseRadius=100, VariantRadius=100 },
    ["105150,50270,2450"] = { Variant="Shield Embolon", NoPatrol=true, Yaw=30, BaseRadius=100, VariantRadius=100 },
    ["105050,50640,2450"] = { Variant="Signifer", NoPatrol=true, Yaw=0, BaseRadius=250, VariantRadius=250 },
    ["105050,50460,2450"] = { Variant="Salii", NoPatrol=true, Yaw=0, BaseRadius=250, VariantRadius=250 },
    ["105060,50820,2450"] = { Variant="Salii", NoPatrol=true, Yaw=0, BaseRadius=250, VariantRadius=250 },
    ["105520,50370,2450"] = { Base="Trooper", NoPatrol=true, Yaw=0, BaseRadius=250 },
    ["105520,50620,2450"] = { Base="Trooper", NoPatrol=true, Yaw=0, BaseRadius=250 }, 
    ["105520,50870,2450"] = { Base="Trooper", NoPatrol=true, Yaw=0, BaseRadius=250 }, 
    ["104640,50780,2450"] = { Hard=true, Variant="Sweeper", NoPatrol=true, Yaw=0, BaseRadius=100 },
    ["104630,50580,2450"] = { Hard=true, Variant="Skirmisher", NoPatrol=true, Yaw=0, BaseRadius=100 },
    ["101350,50580,2450"] = { Hard=true, Variant="Praetorium Sniper", Yaw=0, BaseRadius=3000, VariantRadius=3000 },

    ["105200,47500,2450"] = { Variant="Rocket Rat", NoPatrol=true, Yaw=110, BaseRadius=400 },
    ["104000,47500,2450"] = { Variant="Rocket Rat", NoPatrol=true, Yaw=70, BaseRadius=400 },    
    ["105200,47000,2450"] = { Hard=true, Variant="Super Sapper", NoPatrol=true, Yaw=110, BaseRadius=400 },
    ["104000,47000,2450"] = { Hard=true, Variant="Super Sapper", NoPatrol=true, Yaw=70, BaseRadius=400 },
    ["104800,46750,2450"] = { Variant="Mad Rat", NoPatrol=true, Yaw=90, BaseRadius=400 },
    ["104400,46750,2450"] = { Variant="Purifier", NoPatrol=true, Yaw=90, BaseRadius=500, VariantRadius=500 },

    -- Lockers
    ["103400,47900,1500"] = { Variant="Praetorium Sniper", Yaw=180, BaseRadius=1500, VariantRadius=1500 },
    ["101030,48300,1500"] = { Variant="Sweeper", NoPatrol=true, Yaw=0 },
    ["100910,47250,1500"] = { Hard=true, Variant="Peremptor", NoPatrol=true, Yaw=-30, BaseRadius=500, VariantRadius=500 },
    ["102670,49380,1500"] = { Hard=true, Variant="Peremptor", NoPatrol=true, Yaw=-70, BaseRadius=500, VariantRadius=500 },
    ["103330,46720,1480"] = { Hard=true, Variant="Commander", Yaw=140, BaseRadius=500 },
    -- ["103330,49330,1500"] = { Variant="Praetorium Sniper", Yaw=-90 },

-- =======================================================================
-- RESIDENCE
-- =======================================================================

    -- Check in terminal
    ["-22750,24660,230"] = { StoryMin=90, Variant="Flurry Pest" },


    -- Entrance
    ["-25850,32370,920"] = { StoryMin=90, Variant="Flurry Pest" },
    ["-25700,32230,920"] = { StoryMin=91, Variant="Winter Exor", NoPatrol=true, Yaw=120 },
    ["-27430,34930,920"] = { StoryMin=90, Variant="Whiteout Peccary", NoPatrol=true, Yaw=-75, VariantRadius=3500 },
    ["-28200,33370,820"] = { StoryMin=90, Variant="Exor Superior", NoPatrol=true, Yaw=120, VariantRadius=3000 },
    ["-30300,35140,920"] = { StoryMin=90, Variant="Neophyte Trainer", NoPatrol=true, Yaw=-50, BaseRadius=2000, VariantRadius=2000 },
    ["-29960,35010,920"] = { Hard=true, StoryMin=90, Variant="Storm Witch", NoPatrol=true, Yaw=-150, BaseRadius=2000 },

    -- Side entrance <=> Manufacturing
    ["-25290,35450,1320"] = { StoryMin=90, Variant="Neophyte Tamer", Yaw=120 },
    ["-24930,35640,1320"] = { StoryMin=90, Variant="Neophyte Tamer", Yaw=120 },
    ["-24895,35203,1320"] = { Hard=true, StoryMin=90, Variant="Esoteric Chieftain", Yaw=120 },
    ["-20140,36380,620"] = { Hard=true, StoryMin=90, Variant="Purifier", Yaw=120 },
    ["-20350,36420,620"] = { Hard=true, StoryMin=90, Variant="Purified Grunt" },
    ["-19370,37200,620"] = { Hard=true, StoryMin=90, Variant="Purified Rat" },
    ["-17070,38740,-30"] = { StoryMin=90, Variant="Groupe Sniper", Yaw=-100, BaseRadius=1000 },
    ["-14830,37150,-30"] = { Hard=true, StoryMin=90, Variant="Groupe Sniper", Yaw=-100, BaseRadius=1000 },



    -- Lower level - Maintainence
    ["-32310,33920,260"] = { StoryMin=90, Variant="Winter Exor", NoPatrol=true, Yaw=30, BaseRadius=500, VariantRadius=500 },
    ["-35780,31820,260"] = { StoryMin=90, Variant="Winter Exor", NoPatrol=true, BaseRadius=1000, VariantRadius=1000 },
    ["-30910,33860,260"] = { StoryMin=90, Variant="Jotun Steed", NoPatrol=true, Yaw=120 },

    -- Lower level - Eatery
    ["-33720,36060,620"] = { Hard=true, StoryMin=90, Variant="Plague Witch", NoPatrol=true, BaseRadius=1000 },
    ["-32320,35570,360"] = { Hard=true, StoryMin=90, Variant="Warden Eye", NoPatrol=true, Yaw=-150, BaseRadius=1000 },
    ["-34860,32280,820"] = { StoryMin=90, Variant="Esoteric Chieftain" },
    ["-31820,35630,820"] = { Hard=true, StoryMin=90, Base="Robot_Corrupt", NoPatrol=true, BaseRadius=1500 },
    ["-31670,35740,920"] = { StoryMin=90, Variant="Warden Eye", NoPatrol=true, Yaw=-150, BaseRadius=1500 },
    ["-36450,34230,410"] = { StoryMin=90, Variant="Whiteout Peccary", NoPatrol=true, Yaw=150, BaseRadius=1500, VariantRadius=1500 },
    ["-37420,34800,110"] = { StoryMin=90, Variant="Chonky Signal Pest", BaseRadius=2500 },
    ["-37430,35270,110"] = { StoryMin=90, Variant="Telepest" },
    ["-34560,36500,410"] = { StoryMin=90, Variant="Exor Spiritwalker", NoPatrol=true, Yaw=180 },
    ["-35210,37190,410"] = { StoryMin=90, Variant="Winter Exor", NoPatrol=true, Yaw=-100, BaseRadius=1500, VariantRadius=1500 },
    ["-32800,36650,220"] = { Hard=true, StoryMin=90, Variant="Warrior Witch", NoPatrol=true, Yaw=180, BaseRadius=1000, VariantRadius=1500 },
    ["-34320,36870,320"] = { Hard=true, StoryMin=90, Variant="Anterazor Pest", NoPatrol=true, Yaw=-140, BaseRadius=1000 },
    
    -- Lower level - Eatery basement
    ["-33900,36810,620"] = { Hard=true, StoryMin=90, Variant="Gatekeeper Warchief", NoPatrol=true, Yaw=-45, BaseRadius=1000 },
    ["-33490,36090,320"] = { StoryMin=90, Variant="Abjurer Mage", NoPatrol=true, BaseRadius=2000, VariantRadius=2000 },

    -- Lower level - Eatery <-> Athletics
    ["-37890,34540,320"] = { StoryMin=90, Base="Interfector", NoPatrol=true, Yaw=-90, BaseRadius=500 },
    ["-37580,34130,380"] = { Hard=true, StoryMin=90, Variant="Groupe Sniper", NoPatrol=true, Yaw=90, BaseRadius=1500 },
    ["-41280,37210,-1030"] = { Hard=true, StoryMin=90, Variant="Shield Embolon" },
    ["-42650,39840,-580"] = { Hard=true, StoryMin=90, Variant="Twilight Sniper", Yaw=-60 },
    ["-42110,40310,-430"] = { Hard=true, StoryMin=90, Base="Grunt_FlameRat", NoPatrol=true, Yaw=-150 },
    ["-39900,34310,170"] = { Hard=true, StoryMin=90, Base="Grunt_Sniper", Yaw=120, BaseRadius=1000 },

    -- Lower level - Athletics - Soccer field
    ["-38460,35800,60"] = { Variant="Winter Exor", NoPatrol=true, Yaw=-90, BaseRadius=500, VariantRadius=500 },
    ["-36550,39630,20"] = { Hard=true, StoryMin=91, Variant="Beholder Mage", NoPatrol=true, Yaw=-150 },
    ["-33670,43220,760"] = { StoryMin=91, Variant="Winterfector", NoPatrol=true, Yaw=-50 },

    -- Lower level - Athletics - Gymnasium
    ["-37120,42950,20"] = { StoryMin=90, Variant="Neophyte Tamer" },
    ["-36620,43790,20"] = { StoryMin=90, Variant="Gatekeeper Warchief" },
    ["-35520,45620,720"] = { StoryMin=90, StoryMax=91, Variant="Advanced Big Bot" },
    ["-34290,43940,760"] = { StoryMin=90, StoryMax=91, Base="Robot_Defense" },
    
    -- Lower level - Athletics - Pool    
    ["-38560,42110,720"] = { StoryMin=90, StoryMax=91, Variant="Warrior Witch", NoPatrol=true, Yaw=90, BaseRadius=1000 },
    ["-39410,44790,870"] = { StoryMin=90, StoryMax=91, Variant="Warrior Witch", NoPatrol=true, Yaw=90, BaseRadius=500 },
    ["-40910,43650,720"] = { StoryMin=90, StoryMax=91, Variant="Plague Witch", NoPatrol=true, Yaw=20, BaseRadius=500 },
    ["-39930,43000,240"] = { StoryMin=90, StoryMax=91, Variant="Plague Witch", NoPatrol=true, Yaw=90, BaseRadius=500 },
    ["-38850,43700,420"] = { Hard=true, StoryMin=90, StoryMax=91, Variant="Peremptor", BaseRadius=1500 },
    ["-40490,42520,280"] = { StoryMin=91, Variant="Peremptor", NoPatrol=true, Yaw=30, BaseRadius=1500 },
    ["-41180,44040,720"] = { StoryMin=91, Base="Interfector", NoPatrol=true, Yaw=0, BaseRadius=1500 },
    ["-37280,46530,720"] = { Hard=true, StoryMin=91, Variant="Peremptor", NoPatrol=true, BaseRadius=1500 },
    ["-37320,43640,420"] = { Hard=true, StoryMin=91, Variant="Winterfector", NoPatrol=true, Yaw=130, BaseRadius=1500 },
    ["-46700,51340,760"] = { Hard=true, StoryMin=91, Variant="Twilight Sniper", Yaw=-45 },
     

    -- Lower level <=> Hydroplant
    ["-35110,30740,1420"] = { StoryMin=91, Variant="Groupe Sniper", NoPatrol=true, Yaw=120 },
    ["-43970,24370,140"] = { StoryMin=91, Variant="Deatomizer Bot", NoPatrol=true, Yaw=30 },
    ["-43980,23810,180"] = { StoryMin=91, Variant="Constrictor Bot", NoPatrol=true, Yaw=40 },
    ["-44850,24320,200"] = { StoryMin=91, Variant="Hospitality Bot", NoPatrol=true, Yaw=20 },

    -- Dorms 2F    
    ["-34230,39830,1420"] = { StoryMin=90, Variant="Exorrior Magus" },
    ["-33330,39220,1420"] = { StoryMin=90, Variant="Leyak Menace" },
    ["-32250,35260,1420"] = { StoryMin=90, Variant="Hive Sow" },
    ["-33060,35710,1420"] = { StoryMin=90, Variant="Exorrior Magus", NoPatrol=true, Yaw=30 },
    ["-34870,35080,1650"] = { Hard=true, StoryMin=90, Variant="Signal Pest", NoPatrol=true, Yaw=-60, BaseRadius=1500, VariantRadius=1500 },
    ["-34380,34880,1420"] = { Hard=true, StoryMin=90, Variant="Exor Dislocator", NoPatrol=true, Yaw=60, BaseRadius=1000 },
    ["-33450,35680,1420"] = { StoryMin=90, Variant="Exor Superior", BaseRadius=3000, VariantRadius=3000 },
    ["-38300,34890,1420"] = { StoryMin=90, Variant="Leyak Menace" },
    ["-36160,38370,1420"] = { StoryMin=90, Variant="Armored Peccary" },
    ["-37680,37460,1420"] = { StoryMin=90, Variant="Winter Exor", NoPatrol=true, BaseRadius=1500, VariantRadius=1500 },
    ["-35900,33100,1420"] = { StoryMin=90, Variant="Esoteric Chieftain", NoPatrol=true, Yaw=-45 },
    ["-35570,32720,1420"] = { StoryMin=90, Base="Gatekeeper_Phyter", NoPatrol=true, Yaw=130, BaseRadius=1500 },
    ["-35890,32770,1420"] = { StoryMin=90, Base="Gatekeeper_Heavy", NoPatrol=true, Yaw=130, BaseRadius=2500 },
    
    -- Dorms 2F-3F
    ["-35700,31580,1810"] = { Hard=true, StoryMin=90, Variant="Exor Hunter", NoPatrol=true, Yaw=130 },

    -- Dorms 3F
    ["-34760,39210,2370"] = { Hard=true, StoryMin=91, Variant="Winter Exor", NoPatrol=true, Yaw=150, BaseRadius=1500, VariantRadius=1500 },
    ["-37610,37150,2370"] = { StoryMin=91, Base="Robot_Corrupt", NoPatrol=true, BaseRadius=500 },
    ["-33190,30390,2370"] = { Hard=true, StoryMin=91, Variant="Storm Witch", NoPatrol=true, Yaw=150, BaseRadius=500 },
    ["-35960,31270,2420"] = { StoryMin=91, Variant="Groupe Sniper", Yaw=120 },
    -- ["-33060,33030,2320"] = { Variant="Barrier Mage", StoryMin=91 },
    -- ["-37280,35623,2311"] = {} --BigFoot
    
    -- Dorms Barracks    
    ["-31730,30670,1720"] = { StoryMin=90, Variant="Winterfector", NoPatrol=true, Yaw=-140, BaseRadius=250 },
    ["-31440,30890,1720"] = { StoryMin=90, Base="Interfector", NoPatrol=true, Yaw=40, BaseRadius=250 },
    ["-33180,31230,1620"] = { StoryMin=90, Variant="Deatomizer Bot", NoPatrol=true, Yaw=40, BaseRadius=1000 },
    ["-31870,31290,1620"] = { StoryMin=90, Variant="Esoteric Chieftain", NoPatrol=true, Yaw=-65 },
    ["-34460,31490,1720"] = { Hard=true, StoryMin=90, Variant="Abjurer Mage", NoPatrol=true, Yaw=45, BaseRadius=1500, VariantRadius=1500 },
    ["-34160,30790,1720"] = { Hard=true, StoryMin=90, Base="Gatekeeper_Witch", NoPatrol=true, Yaw=45, BaseRadius=400 },

    -- Dorms 4F
    ["-36130,32950,3300"] = { Hard=true, StoryMin=91, Variant="Beholder Mage", NoPatrol=true, BaseRadius=1500, VariantRadius=1500 },
    ["-37080,37930,3260"] = { StoryMin=91, Variant="Winterfector", NoPatrol=true, Yaw=0 },
    
    -- Dorms Roof
    ["-37440,36940,3810"] = { Hard=true, StoryMin=91, Variant="Winter Exor" },
    ["-37870,36970,3810"] = { StoryMin=91, Variant="Flurry Pest", BaseRadius=1500, VariantRadius=1500 },
    ["-33570,39600,2820"] = { StoryMin=91, Variant="Neophyte Trainer", NoPatrol=true, Yaw=-150, BaseRadius=1000, VariantRadius=1000 },
    ["-33850,39530,2820"] = { StoryMin=91, Variant="Warrior Witch" },

    -- Upper Dorms
    ["-35970,38570,2370"] = { Variant="Winterfector", NoPatrol=true, Yaw=-30 },
    ["-31800,37430,2730"] = { Hard=true, Variant="Peremptor", NoPatrol=true, Yaw=130 },

    -- Exec Dorms
    ["-44470,31090,3320"] = { StoryMin=91, Variant="Barrier Mage", NoPatrol=true, Yaw=-40, BaseRadius=400 },
    ["-44090,31420,3320"] = { StoryMin=91, Variant="Abjurer Mage", NoPatrol=true, Yaw=-60, BaseRadius=400 },
    ["-44850,32480,3320"] = { StoryMin=91, Variant="Beholder Mage", NoPatrol=true, Yaw=-60, BaseRadius=400 },
    ["-45330,32180,3320"] = { StoryMin=91, Base="Gatekeeper_Mage", NoPatrol=true, Yaw=-40, BaseRadius=2500 },
    ["-45400,32760,3320"] = { StoryMin=91, Variant="Esoteric Chieftain", NoPatrol=true, Yaw=-55 },
    ["-45360,32680,3320"] = { StoryMin=91, Variant="Warden Eye", NoPatrol=true, BaseRadius=400 },
    ["-42560,28920,3320"] = { StoryMin=91, Variant="Warden Eye" },
    
-- =======================================================================
-- FRAGMENTS
-- =======================================================================

    -- Entrance
    ["-27440,54550,-280"] = { StoryMin=92, StoryMax=100, Variant="Exor Displacer", NoPatrol=true, Yaw=-160, BaseRadius=1500, NearRadius=12000, NearFastCheck=15 },
    ["-29670,54260,-380"] = { StoryMin=92, StoryMax=100, Variant="Exor Repeller", NoPatrol=true, Yaw=-30, BaseRadius=1500, NearRadius=12000, NearFastCheck=15 },
    ["-28920,54800,-380"] = { Hard=true, StoryMin=92, StoryMax=100, Variant="Exor Hunter", NoPatrol=true, Yaw=-30, NearRadius=12000, NearFastCheck=15 },

    -- Food court - left side 
    ["-26670,58740,-480"] = { StoryMin=92, StoryMax=94, Variant="Anterazor Pest", BaseRadius=1000 },
    ["-28290,60290,-480"] = { StoryMin=92, StoryMax=94, Variant="Exor Superior" },
    ["-27950,59210,-480"] = { StoryMin=92, Variant="Exor Shadow Monk", BaseRadius=1000, VariantRadius=1000 },
    ["-26750,59720,-480"] = { Hard=true, StoryMin=92, Variant="Exor Spiritwalker", BaseRadius=3000, VariantRadius=3000 },

    -- Food Court - right side
    ["-35700,55040,-20"] = { StoryMin=92, StoryMax=100, Variant="Advanced Cafeteria Bot", NoPatrol=true },
    ["-34270,53930,-720"] = { StoryMin=92, StoryMax=94, Variant="Advanced Cafeteria Bot", NoPatrol=true },
    ["-33440,53620,-720"] = { StoryMin=92, StoryMax=94, Variant="Advanced Cafeteria Bot", NoPatrol=true },
    ["-35120,53900,10"] = { StoryMin=92, StoryMax=94, Variant="Advanced Cafeteria Bot" },
    ["-34620,53700,-720"] = { Hard=true, StoryMin=92, StoryMax=100, Variant="Abjurer Mage" },


    -- Food Court - Broken Hall
    ["-33630,61670,910"] = { Hard=true, StoryMin=92, StoryMax=100, Base="Grunt_Sapper", NoPatrol=true, Yaw=-90, BaseRadius=1000 },
    ["-34280,60470,-310"] = { StoryMin=92, Variant="Mad Rat" },
    ["-33900,60250,-310"] = { StoryMin=92, StoryMax=94, Base="Grunt_LabRat_Mechanic" },
    ["-33810,60830,500"] = { StoryMin=92, StoryMax=94, Variant="Purified Grunt" },
    ["-34580,60840,320"] = { StoryMin=92, StoryMax=94, Variant="Purified Grunt" },

    -- Food Court - front
    ["-30620,64060,1300"] = { StoryMin=92, Variant="Advanced Big Bot", NoPatrol=true, Yaw=90, BaseRadius=1500 },
    ["-30720,64800,1300"] = { Hard=true, StoryMin=92, Variant="Advanced Big Bot", NoPatrol=true, Yaw=90, BaseRadius=1500 },


    -- Blockbuster (front-left)   
    ["-20150,60800,-740"] = { StoryMin=92, Variant="Winter Exor" },
    ["-22377,60230,-620"] = { StoryMin=92, StoryMax=94, Variant="Antefire Exor", BaseRadius=3000, VariantRadius=3000 },
    ["-22320,53930,-640"] = { StoryMin=92, Variant="Whiteout Peccary" },
    ["-20980,62290,130"] = { StoryMin=92, StoryMax=94, Variant="Electro Peccary" },
    ["-21190,64140,130"] = { StoryMin=92, StoryMax=94, Base="Peccary_Mushroom" },
    ["-21300,63900,130"] = { Hard=true, StoryMin=92, StoryMax=94, Variant="Leyak Menace" },
    ["-21270,60650,370"] =  { Hard=true, StoryMin=92, StoryMax=94, Variant="Signal Pest", NoPatrol=true, Yaw=-90, BaseRadius=500, VariantRadius=500 },
    ["-25030,65690,330"] = { StoryMin=92, StoryMax=94, Variant="Exorrior" },
    ["-21180,60620,1400"] = { StoryMin=92, Variant="Hive Sow" },
    ["-20530,60560,1370"] = { StoryMin=92, StoryMax=94, Variant="Anterazor Pest" },
    ["-20490,60990,1370"] = { StoryMin=92, StoryMax=94, Variant="Pestilence" },
    ["-23120,60320,2450"] = { StoryMin=92, StoryMax=94, Base="Exor_Armored" },

    ["-25720,65350,120"] = { StoryMin=92, StoryMax=94, Variant="Acidic Exor" },
    ["-26340,64740,-140"] = { StoryMin=92, StoryMax=94, Variant="Chonky Pest" },
    ["-24200,65860,630"] = { Hard=true, StoryMin=92, StoryMax=94, Variant="Volatile Peccary" },
    

    -- Shadowgate (left-left)
    ["-17040,62570,230"] = { Hard=true, StoryMin=92, Variant="Jotun Rocketeer", NoPatrol=true, Yaw=60 },
    ["-17770,63670,110"] = { StoryMin=94, Variant="Storm Witch" },
    ["-15930,65690,120"] = { StoryMin=92, Variant="Gatekeeper Warchief" },
    ["-18300,66010,80"] = { StoryMin=94, Variant="Barrier Mage", BaseRadius=1500, VariantRadius=1500 },
    ["-16490,69060,1370"] = { StoryMin=92, Variant="Neophyte Trainer", NoPatrol=true, Yaw=-150, BaseRadius=100 },
    ["-16590,69290,1370"] = { StoryMin=94, Variant="Neophyte Tamer", NoPatrol=true, Yaw=-150, BaseRadius=100 },
    ["-16270,67780,1340"] = { StoryMin=94, Variant="Artillery Bot" },
    ["-16740,67540,1340"] = { StoryMin=92, Variant="Beholder Mage", NoPatrol=true, Yaw=-90, BaseRadius=500, VariantRadius=500 },
    ["-17270,67160,1340"] = { Hard=true, StoryMin=92, Variant="Beholder Mage", NoPatrol=true, Yaw=-90, BaseRadius=500, VariantRadius=500 },
    ["-16905,68349,1840"] = { Hard=true, StoryMin=94, Variant="Warrior Witch", NoPatrol=true, Yaw=-90, BaseRadius=2000, VariantRadius=2000 },

    -- Office Building (left-mid)
    ["-15920,72850,2450"] = { StoryMin=94, Variant="Office Bot" },
    ["-17720,71820,2730"] = { StoryMin=94, Variant="Office Bot" },
    ["-18900,72000,2960"] = { StoryMin=94, Base="Robot_Containment" },
    ["-17450,73640,2090"] = { StoryMin=94, Base="Gatekeeper_Mage" },
    ["-16900,72340,2000"] = { StoryMin=94, Base="Gatekeeper_Phyter", NoPatrol=true, BaseRadius=2500 },
    ["-17410,71890,2080"] = { StoryMin=94, Variant="Storm Witch" },
    ["-16170,72850,1280"] = { StoryMin=94, Base="Robot_Corrupt" },
    ["-15550,72920,1180"] = { StoryMin=94, Variant="Office Bot" },
    ["-17390,73430,2080"] = { Hard=true, StoryMin=94, Base="Robot_Defense" },
    ["-19150,71610,2270"] = { Hard=true, StoryMin=94, Base="Gatekeeper_Heavy", NoPatrol=true, Yaw=20, BaseRadius=1500 },

    -- Ice Queen (mid)
    ["-25040,71250,-160"] = { Hard=true, StoryMin=94, Base="WinterSprite_BOSS" },


    -- Hydroplant (right-mid)
    ["-28910,68880,780"] = { Hard=true, StoryMin=94, Base="Robot_Defense", NoPatrol=true, Yaw=90, BaseRadius=2500 },
    ["-30400,71150,900"] = { StoryMin=94, Variant="Deatomizer Bot", NoPatrol=true, Yaw=-130 },
    ["-31510,71980,1520"] = { StoryMin=94, Base="Robot_Corrupt", NoPatrol=true, Yaw=90 },
    ["-30930,72120,1560"] = { StoryMin=94, Base="Gatekeeper_Phyter", NoPatrol=true, Yaw=-130, BaseRadius=2000 },
    ["-30460,70670,-1260"] = { Hard=true, StoryMin=94, Variant="Storm Witch", NoPatrol=true, Yaw=-130, BaseRadius=2000, VariantRadius=2000 },
    ["-31280,72210,1520"] = { Hard=true, StoryMin=94, Variant="Barrier Mage", NoPatrol=true, Yaw=100, BaseRadius=2000, VariantRadius=2000 },

    -- NightRealm (right-back)
    ["-34200,73100,850"] = { Hard=true, StoryMin=92, Variant="Roaming Shade", NoPatrol=true, Yaw=-140 },
    ["-34760,73830,950"] = { Hard=true, StoryMin=92, Variant="Roaming Shade", NoPatrol=true, Yaw=-70 },
    ["-35870,74750,910"] = { StoryMin=92, Variant="Grunt Shade", NoPatrol=true, Yaw=-90 },
    ["-35270,74660,910"] = { StoryMin=92, Variant="Grunt Shade", NoPatrol=true, Yaw=-90 },
    ["-35480,75800,1510"] = { StoryMin=94, Variant="Breacher Shade", NoPatrol=true, Yaw=-90 },
    ["-35773,74648,1510"] = { StoryMin=92, Variant="Roaming Shade" },
    ["-36260,74020,1710"] = { StoryMin=92, Variant="Roaming Shade" },
    ["-35150,72517,1710"] = { StoryMin=94, Variant="Roaming Shade" },
    ["-35330,72970,1680"] = { Hard=true, StoryMin=92, Variant="Breacher Shade", NoPatrol=true, Yaw=130 },
    ["-35550,72970,1680"] = { Hard=true, StoryMin=92, Variant="Breacher Shade", NoPatrol=true, Yaw=130 },
    ["-35760,73300,1650"] = { Hard=true, StoryMin=94, Variant="Neophyte Shade", NoPatrol=true, Yaw=130 },
    ["-34250,72950,1710"] = { StoryMin=94, Variant="Neophyte Shade", NoPatrol=true, Yaw=-130, BaseRadius=2000 },
    ["-35390,72180,2610"] = { StoryMin=92, Variant="Roaming Shade", NoPatrol=true, Yaw=45 },
    ["-35120,73030,4410"] = { StoryMin=92, Variant="Neophyte Shade", NoPatrol=true, Yaw=150 },
    ["-35600,72600,4410"] = { StoryMin=94, Variant="Roaming Shade", NoPatrol=true, Yaw=120 },

    -- * Post-Forcefield
    ["-24620,78600,650"] = { Hard=true, StoryMin=95, Base="Robot_Defense", NoPatrol=true, Yaw=120 },
    ["-24700,81390,2930"] = { StoryMin=95, Variant="Abjurer Mage", NoPatrol=true, Yaw=120 },
    ["-27770,85260,1200"] = { StoryMin=95, Variant="Advanced Big Bot" },
    ["-28430,84490,1110"] = { Hard=true, StoryMin=95, Variant="Jotun Steed", BaseRadius=2000 },

-- =======================================================================
-- FRAGMENTS BOTANICALS
-- =======================================================================
    -- Facility
    -- * p1
    ["-37560,66760,1860"] = { StoryMin=93, Variant="Acidic Exor", VariantRadius=2500 },
    ["-36980,66950,1860"] = { Hard=true, StoryMin=93, Variant="Exor Hunter", VariantRadius=2500 },
    -- * p2
    ["-41730,59820,300"] = { StoryMin=93, Variant="Exor Superior", BaseRadius=2500, VariantRadius=2500 },
    ["-42760,59750,300"] = { Hard=true, StoryMin=93, Base="Exor_Volatile", BaseRadius=2500 },
    ["-40830,62310,1050"] = { Hard=true, StoryMin=93, Base="Gatekeeper_Heavy", NoPatrol=true, Yaw=40, BaseRadius=2500 },
    ["-41550,71120,2010"] = { Hard=true, StoryMin=93, Base="Exor_Pikeman", NoPatrol=true, Yaw=-90, BaseRadius=2500 },
    ["-42140,71180,2150"] = { StoryMin=93, Variant="Antegrav Exor", NoPatrol=true, Yaw=-50, VariantRadius=2500 },
    ["-47140,66520,-160"] = { StoryMin=93, Variant="Warrior Witch", BaseRadius=1500 },
    ["-41250,65900,-80"] = { StoryMin=93, Base="Interfector" },
    ["-42050,72100,-680"] = { StoryMin=93, Variant="Praetorium Sniper", Yaw=-130, BaseRadius=250 },
    -- * p3
    ["-44310,70950,250"] = { StoryMin=93, Variant="Exor Superior", NoPatrol=true, Yaw=-100, BaseRadius=1500, VariantRadius=1500 },
    ["-45970,68070,-160"] = { StoryMin=93, Variant="Plague Witch", BaseRadius=1500 },
    ["-46850,66710,-120"] = { Hard=true, StoryMin=93, Variant="Deatomizer Bot", BaseRadius=2500, VariantRadius=2500 },
    ["-44200,61250,1440"] = { StoryMin=93, Variant="Jotun Rocketeer", BaseRadius=2500, VariantRadius=2500 },
    ["-43910,61410,1440"] = { StoryMin=93, Variant="Jotun Steed", BaseRadius=2500, VariantRadius=2500 },
    ["-46190,64080,1940"] = { StoryMin=93, Variant="Barrier Mage", NoPatrol=true, Yaw=-100, BaseRadius=2500, VariantRadius=2500 },
    ["-41640,65160,-80"] = { Hard=true, StoryMin=93, Variant="Winterfector", NoPatrol=true, Yaw=-100, BaseRadius=2500, VariantRadius=2500 },
    -- * p4
    ["-45660,62037,3010"] = { Hard=true, StoryMin=93, Base="Gatekeeper_Heavy", NoPatrol=true, Yaw=-90, BaseRadius=2000 },
    ["-50070,60350,3570"] = { Hard=true, StoryMin=93, Variant="Twilight Sniper", NoPatrol=true, Yaw=-10, BaseRadius=500, VariantRadius=500 },
    ["-50190,59820,3010"] = { StoryMin=93, Variant="Tracer Sniper", Yaw=0, BaseRadius=500, VariantRadius=500 },
    ["-48490,59090,3010"] = { StoryMin=93, Variant="Praetorium Sniper", Yaw=80, BaseRadius=500 },
    ["-49320,60460,3010"] = { StoryMin=93, Variant="Winterfector", NoPatrol=true, Yaw=-20, BaseRadius=500 },
    ["-49800,60500,3320"] = { StoryMin=93, Base="Interfector", NoPatrol=true, Yaw=0, BaseRadius=250 },
    ["-49830,59690,3010"] = { Hard=true, StoryMin=93, Variant="Signifer", NoPatrol=true, Yaw=0 },
    ["-49420,59450,3050"] = { Hard=true, StoryMin=93, Variant="Peremptor", NoPatrol=true, Yaw=60, BaseRadius=500, VariantRadius=500 },
    ["-50610,64300,3250"] = { StoryMin=93, StoryMax=100, Variant="Purified Grunt", NoPatrol=true, Yaw=-90, BaseRadius=1000 },
    ["-50180,64340,3250"] = { StoryMin=93, StoryMax=100, Variant="Purified Breacher", NoPatrol=true, Yaw=-90, BaseRadius=1000 },    
    ["-50180,64840,3250"] = { Hard=true, StoryMin=93, Variant="Shield Embolon", NoPatrol=true, Yaw=-90, BaseRadius=1000, VariantRadius=1000 },
    ["-50750,64840,3250"] = { Hard=true, StoryMin=93, Variant="Rocket Rat", NoPatrol=true, Yaw=-90, BaseRadius=1000, VariantRadius=1000 },
    -- * p5 (exiting)
    ["-45440,65250,1900"] = { Hard=true, StoryMin=94, Variant="Abjurer Mage", BaseRadius=1500, VariantRadius=1500 },
    ["-44510,67300,2270"] = { StoryMin=94, Variant="Storm Witch", NoPatrol=true, BaseRadius=1500, VariantRadius=1500 },
    ["-45200,62100,1870"] = { Hard=true, StoryMin=94, Variant="Warrior Witch", NoPatrol=true, Yaw=160, BaseRadius=1500, VariantRadius=1500 },
    ["-46630,61990,2040"] = { StoryMin=94, Variant="Neophyte Trainer", NoPatrol=true, Yaw=-10, BaseRadius=1500, VariantRadius=1500 },
    ["-37540,63350,1480"] = { Hard=true, StoryMin=94, Variant="Storm Witch", NoPatrol=true, Yaw=90, BaseRadius=2500, VariantRadius=2500 },
    ["-36620,65150,1300"] = { Hard=true, StoryMin=94, Base="Gatekeeper_Phyter", NoPatrol=true, Yaw=-110, BaseRadius=2500 },

    ---------------------------------
    -- FRAGMENTS VIGNETTE
    ---------------------------------
    -- * p1
    ["-39200,67530,51860"] = { Hard=true, Base="Exor_Volatile", BaseRadius=2500 },
    ["-39530,68980,51770"] = { Base="Peccary_Mushroom", BaseRadius=2500 },
    ["-40770,68240,51740"] = { Variant="Exor Shadow Monk", BaseRadius=2500, VariantRadius=2500 },
    ["-41830,63800,51360"] = { Base="Pest_Volatile", BaseRadius=2500 },
    ["-40510,69040,51740"] = { Variant="Hive Sow", BaseRadius=3000, VariantRadius=3000 },
    ["-42490,61970,51470"] = { Variant="Magma Peccary" },
    ["-41080,60290,50640"] = { Variant="Phase Peccary" },
    ["-42700,62400,50260"] = { Hard=true, Variant="Exor Shadow Monk", BaseRadius=2500, VariantRadius=2500 },
    -- * p2
    ["-42260,68360,51710"] = { Hard=true, Base="Peccary_Alpha", BaseRadius=2500 },
    ["-44640,69850,50250"] = { Hard=true, Variant="Antesignal Pest", NoPatrol=true, Yaw=20, BaseRadius=3000 },
    ["-44780,64300,49670"] = { Variant="Hive Sow", BaseRadius=3000, VariantRadius=3000 },
    -- * p3
    ["-45460,58580,52040"] = { Variant="Exor Displacer", BaseRadius=2000, VariantRadius=2000 },
    ["-45220,60260,52040"] = { Hard=true, Base="Exor_Volatile", BaseRadius=2000 },

}

return PLACED
