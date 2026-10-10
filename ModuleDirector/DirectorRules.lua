-- =======================================================================
-- DirectorRules - the ROSTER for ModuleDirector. Definitions only; the engine is Director.lua.
--
-- A rule is ONE ROW: when it may fire (Story / Sector / Night / Hard) and what it does
-- (Behaviour + Spawns). Night and hard mode are CONDITIONS on a row, never overrides inside one -
-- where a count differs between normal and hard you write two rows. The engine merges nothing,
-- so a row is the whole truth about itself.
--
--   Id             unique; the log / chat-echo label
--   Story          { min, max } - fires while min <= StoryProgress < max (StoryManager's scale)
--   Sector         a SECTORS key. nil = anywhere the other conditions allow
--   Night          true = night only, false = day only, nil = either
--   Hard           true = HARDMODE.NoEnd only, false = normal only, nil = either
--   Behaviour      Wander       - spawned and left to native behaviour
--                  Investigate  - WALKS to where the player was at the check, then loiters
--                  Hunt         - locked onto the player until it lands a hit, then fights normally
--                  Stalk        - Hunt that is recalled if it never engages, and re-armed (Retries)
--                  Crossfire    - Packs groups on opposing bearings, all RUNNING to the player's spot
--                  A LIST rotates per firing: { "Hunt", "Investigate" } on a 3-minute cooldown is
--                  each of them every 6 minutes, landing 3 minutes apart - which is how you spread
--                  two behaviours instead of letting two rows race. Crossfire can't share a cycle
--   Spawns         a PACKS entry: { {name, weight}, ... }, rolled per body. A name is an Antevariant
--                  or a raw ENUMS.NpcClasses row; an unknown name is logged at load
--   Count          bodies per firing (1)
--   MaxActive      firings from this rule alive at once, per player (1)
--   SpawnFX        true = keep the native spawn-in burst. Off by default: packs land out of sight
--   CooldownSecs   { min, max } real seconds before this rule may fire again on that player. The
--                  DEFAULT is per-clock (DEFAULTS.CooldownSecs by day, CooldownSecsNight at night);
--                  a row that names its own number means that number whatever the clock says
--   OncePerNight   true   = one firing per night PER PLAYER
--                  "world" = one firing per night for the whole session, whoever earns it first
--                  Pair it with Night=true; the night counter only advances on a day -> night flip
--   Chance         0-1, rolled when the row would fire. A miss SPENDS the cooldown and the night
--                  latch, so OncePerNight + Chance=0.5 is "about half of nights get the event".
--                  A cooldown can't express this: by nightfall it has always expired
--   Retries        Stalk only: re-arms after a recall, this many times per cycle (5)
--   Packs          Crossfire only: groups on opposing bearings (2)
--   Groups         Crossfire only: ONE ENTRY PER BEARING, { Spawns=..., Count=n }. Use it when
--                  the bearings are meant to differ - two factions converging on the player rather
--                  than one pack split in half. Replaces Packs / Spawns / Count on that row
--
-- Anything a row leaves out falls back to DEFAULTS.
--
-- * Days last ~30 minutes
-- * Nights last ~4.5 minutes
--
-- =======================================================================

---@diagnostic disable: undefined-global

local DEFAULTS = {
    CheckEverySecs    = 60,          -- per-player cadence
    PlayerQuietSecs   = 90,          -- floor between ANY two director firings on one player
    BenchClearMetres  = 40,          -- don't spawn enemies near benchs
    BenchClearZMetres = 10,          -- 
    SpawnRingMetres   = { 15, 30 },  -- how far away enemies can spawn
    CooldownSecs      = { 300, 900 }, -- default cooldown by DAY
    CooldownSecsNight = { 150, 300 }, -- ...and at night (only ~270 seconds long)
    SectorGraceSecs   = 120,         -- Initial grace period in an area before starting cooldowns
    EngageSecs        = 60,          -- Stalk: if an npc stalks and doesn't enter combat after this long, recall it
    SpawnFX           = false,       -- Suppress spawn FX by default
    Retries           = 5,
}

-- Floor plans
--   * Facility levels +-55000 on X/Y
--      > Sectors may have light overlaps. StoryBands can contain some of this
--   * Most vignettes are well clear typically +-300000
--   * Director doesn't start in a new area for GraceSecs (DEFAULTS.SectorGraceSecs) 
--
local SECTORS = {
    -- Y reaches 24000 for the north stairwell and 4900 for the south door, both just off the
    -- placement hull. Residence starts at Y 24660 here, so 24000 is the whole of the slack.
    Office = {
        Points = { { X=-26000, Y=4900 }, { X=-3000, Y=4900 }, { X=-3000, Y=24000 }, { X=-26000, Y=24000 } },
        MinZ = -1500, MaxZ = 4000,
    },

    -- L-shaped: the Office stack reaches up to Y 23500 on the west side, so below Y 26000 
    -- this is only some of the corridor east of it
    Manufacturing = {
        Points = { { X=-8600, Y=17000 }, { X=18000, Y=17000 }, { X=18000, Y=50000 },
                   { X=-18000, Y=50000 }, { X=-18000, Y=26000 }, { X=-8600, Y=26000 } },
        MinZ = -1500, MaxZ = 2500,
    },

    -- West edge is tight and splits with Office (Office reaches X=-4960, the westernmost Labs
    -- spawner is -4734, so -4800 is the gap between them)
    Labs = {
        Points = { { X=-4800, Y=-15000 }, { X=24000, Y=-15000 }, { X=24000, Y=16500 }, { X=-4800, Y=16500 } },
        MinZ = -2500, MaxZ = 4200,
    },

    -- Hydroplant
    -- Power services is under this level (Z -5000+)
    Hydroplant = {
        Points = { { X=-52500, Y=-5500 }, { X=-24500, Y=-5500 }, { X=-24500, Y=4000 },
                   { X=-26000, Y=4000 },  { X=-26000, Y=24500 }, { X=-42500, Y=24500 },
                   { X=-42500, Y=14000 }, { X=-52500, Y=14000 } },
        MinZ = -3000, MaxZ = 4000,
    },

    -- Exor Village (V_Anteverse_C)
    ExorVillage = {
        Points = { { X=12000, Y=-345000 }, { X=43000, Y=-345000 },
                   { X=43000, Y=-316000 }, { X=12000, Y=-316000 } },
        GraceSecs = 120,
    },
}

-- Hard-tier pools are "the normal pool PLUS these", so the shared half can't drift.
local function plus(base, extra)
    local out = {}
    for _, e in ipairs(base) do out[#out + 1] = e end
    for _, e in ipairs(extra) do out[#out + 1] = e end
    return out
end

-- What spawns and the chance to spawn
local PACKS = {}

PACKS.OfficeEarlyCritters = { { "Pest", 70 }, { "Razor Pest", 10 }, { "Chonky Pest", 10 }, { "Antegrav Pest", 5 }, { "Signal Pest", 5 } }

PACKS.OfficeCritters = { { "Pest", 60 }, { "Peccary", 20 }, { "Razor Pest", 10 }, { "Chonky Pest", 5 }, { "Signal Pest", 5 } }

-- Midgame Office: both factions have moved in behind the player, so the two pools stay separate
-- and meet as a crossfire. "Grunt_Medic" is the plain medic row (the variant is Dioscoridian).
PACKS.OfficeMidgameOrder = {
    { "Grunt_Guard", 40 }, { "Grunt", 20 }, { "Velites Guard", 10 }, { "Suppressor Grunt", 10 },
    { "Grunt_Captain", 10 }, { "Grunt_Medic", 10 },
}
PACKS.OfficeMidgameExor = {
    { "Pest", 40 }, { "Signal Pest", 10 }, { "Charge Peccary", 10 }, { "Phase Peccary", 10 },
    { "Sow", 10 }, { "Exor_Monk", 10 }, { "Exor", 10 },
}

-- Manufacturing is Order-held, so both tiers are Order patrols; hard trades Grunt_Guard filler
-- for the two heavies.
PACKS.MfOrder = {
    { "Grunt_Guard", 40 }, { "Grunt", 20 }, { "Velites Guard", 20 },
    { "Suppressor Grunt", 10 }, { "Grunt_Captain", 10 },
}
PACKS.MfOrderHard={
    { "Grunt_Guard", 20 }, { "Grunt", 20 }, { "Velites Guard", 20 }, { "Suppressor Grunt", 10 },
    { "Grunt_Captain", 10 }, { "Trident", 10 }, { "Grenadier Guard", 10 },
}

-- The Labs wildlife: Anteverse creatures, flat-weighted. "Pest_Electro" and "Assassin" are base
-- ENUMS.NpcClasses rows - the electro pest and the crystallisk have no variant of their own.
PACKS.LabsWild = {
    { "Razor Pest", 1 }, { "Chonky Pest", 1 }, { "Pest_Electro", 1 }, { "Laser Pest", 1 },
    { "Telepest", 1 }, { "Leyak Pest", 1 }, { "Charge Peccary", 1 }, { "Phase Peccary", 1 },
    { "Electro Peccary", 1 }, { "Carbunccary", 1 }, { "Sow", 1 }, { "Hive Sow", 1 },
    { "Exor_Monk", 1 }, { "Exor", 1 }, { "Assassin", 1 }, { "Obsidilisk", 1 },
}
PACKS.LabsWildHard=plus(PACKS.LabsWild, {
    { "Leyak Menace", 2 }, { "Antegrav Exor", 1 }, { "Exor Magus", 1 }, { "Exorrior", 1 },
})

-- The Order side of a Labs crossfire - a patrol that walked in, not a garrison.
PACKS.LabsOrder = {
    { "Grunt", 50 }, { "Grunt_Guard", 20 }, { "Grunt_Shotgun", 20 }, { "Grunt_Captain", 10 },
}
PACKS.LabsOrderHard={
    { "Grunt", 10 }, { "Grunt_Shotgun", 10 }, { "Grunt_Captain", 10 }, { "Velites Guard", 10 },
    { "Suppressor Grunt", 10 }, { "Grenadier Guard", 10 }, { "Grunt_Guard", 10 },
    { "Sweeper", 10 }, { "Skirmisher", 10 }, { "Trident", 10 },
}

-- The dam is contested ground: an Order patrol off the tower side, and whatever came up out of the
-- water or walked out of the plant on the other.
PACKS.HydroOrder = {
    { "Grunt", 40 }, { "Grunt_Guard", 10 }, { "Grenadier Guard", 10 }, { "Suppressor Grunt", 10 },
    { "Dioscoridian", 10 }, { "Grunt_Captain", 10 }, { "Grunt_Shotgun", 10 },
}
PACKS.HydroWild = {
    { "Hive Sow", 20 }, { "Exor", 20 }, { "Exor_Armored", 20 }, { "Robot_Containment", 20 },
    { "Advanced Hospitality Bot", 20 },
}

-- The Exor village's own population. The hard tier is a DIFFERENT pool, not the normal one plus
-- extras: the plain Pest / Peccary / Exor Magus filler drops out for the heavier cousins.
PACKS.VillageWild = {
    { "Pest", 20 }, { "Razor Pest", 10 }, { "Chonky Pest", 10 }, { "Peccary", 10 },
    { "Charge Peccary", 10 }, { "Phase Peccary", 10 }, { "Exor Magus", 10 }, { "Exorrior", 10 },
    { "Exor", 10 },
}
PACKS.VillageWildHard={
    { "Razor Pest", 10 }, { "Chonky Pest", 10 }, { "Charge Peccary", 10 }, { "Phase Peccary", 10 },
    { "Carbunccary", 10 }, { "Hive Sow", 10 }, { "Exor_Monk", 10 }, { "Exorrior Magus", 10 },
    { "Exor", 10 }, { "Magma Exor", 10 },
}

local RULES = {

    -- ===================================================================
    -- OFFICE EARLY (StoryProgress 10-12) Office-Flathill
    -- * Very light harassment
    -- ===================================================================
    { Id="Office_Early_Day_Wander",           Story={ 10, 12 }, Sector="Office", Night=false, Hard=false,
      CooldownSecs = { 600, 900 },
      Behaviour="Wander",      Spawns=PACKS.OfficeEarlyCritters, Count=1, MaxActive=1 },

    { Id="Office_Early_Night_Investigate",    Story={ 10, 12 }, Sector="Office", Night=true,  Hard=false,
      OncePerNight="world",
      Behaviour="Investigate", Spawns=PACKS.OfficeEarlyCritters, Count=1, MaxActive=1 },

    { Id="Office_Early_Day_Wander_Hard",      Story={ 10, 12 }, Sector="Office", Night=false, Hard=true,
      Behaviour="Wander",      Spawns=PACKS.OfficeEarlyCritters, Count=1, MaxActive=1 },

    { Id="Office_Early_Day_Investigate_Hard", Story={ 10, 12 }, Sector="Office", Night=false, Hard=true,
      Behaviour="Investigate", Spawns=PACKS.OfficeEarlyCritters, Count=1, MaxActive=2 },

    -- ===================================================================
    -- OFFICE  (StoryProgress 12-30) Office-Manufacturing
    -- ===================================================================
    { Id="Office_Day_Wander",           Story={ 12, 30 }, Sector="Office", Night=false, Hard=false,
      Behaviour="Wander",      Spawns=PACKS.OfficeCritters, Count=1, MaxActive=1 },

    { Id="Office_Night_Investigate",    Story={ 12, 30 }, Sector="Office", Night=true,  Hard=false,
      Behaviour="Investigate", Spawns=PACKS.OfficeCritters, Count=1, MaxActive=1 },

    { Id="Office_Day_Wander_Hard",      Story={ 12, 30 }, Sector="Office", Night=false, Hard=true,
      Behaviour="Wander",      Spawns=PACKS.OfficeCritters, Count=1, MaxActive=2 },

    { Id="Office_Day_Investigate_Hard", Story={ 12, 30 }, Sector="Office", Night=false, Hard=true,
      Behaviour="Investigate", Spawns=PACKS.OfficeCritters, Count=1, MaxActive=2 },

    { Id="Office_Night_Hunt_Hard",      Story={ 12, 30 }, Sector="Office", Night=true,  Hard=true,
      Behaviour="Hunt",        Spawns=PACKS.OfficeCritters, Count=1, MaxActive=2 },

    -- ===================================================================
    -- OFFICE MIDGAME  (StoryProgress 31-60) - Order and Exor infest the Office,
    -- leading to crossfires 
    -- ===================================================================
    { Id="Office_Mid_Day_Order",        Story={ 31, 60 }, Sector="Office", Night=false, Hard=false,
      Behaviour="Investigate", Spawns=PACKS.OfficeMidgameOrder, Count=1, MaxActive=1 },

    { Id="Office_Mid_Day_Exor",         Story={ 31, 60 }, Sector="Office", Night=false, Hard=false,
      Behaviour="Investigate", Spawns=PACKS.OfficeMidgameExor,  Count=1, MaxActive=1 },

    { Id="Office_Mid_Night_Crossfire",  Story={ 31, 60 }, Sector="Office", Night=true,  Hard=false,
      Behaviour="Crossfire",   MaxActive=1, OncePerNight="world",
      Groups = { { Spawns=PACKS.OfficeMidgameOrder, Count=2 },
                 { Spawns=PACKS.OfficeMidgameExor,  Count=2 } } },

    { Id="Office_Mid_Day_Crossfire_Hard",   Story={ 31, 60 }, Sector="Office", Night=false, Hard=true,
      Behaviour="Crossfire",   MaxActive=1, CooldownSecs={ 780, 960 },
      Groups = { { Spawns=PACKS.OfficeMidgameExor,  Count=1 },
                 { Spawns=PACKS.OfficeMidgameOrder, Count=1 } } },

    { Id="Office_Mid_Night_Crossfire_Hard", Story={ 31, 60 }, Sector="Office", Night=true,  Hard=true,
      Behaviour="Crossfire",   MaxActive=1, OncePerNight="world",
      Groups = { { Spawns=PACKS.OfficeMidgameExor,  Count=3 },
                 { Spawns=PACKS.OfficeMidgameOrder, Count=2 } } },

    -- ===================================================================
    -- MANUFACTURING  (After Frake/second Blacksmith)
    -- ===================================================================
    { Id="Mf_Day_Wander",               Story={ 23, 70 }, Sector="Manufacturing", Night=false, Hard=false,
      Behaviour="Wander",      Spawns=PACKS.MfOrder, Count=1, MaxActive=1, CooldownSecs={ 1000, 1400 } },

    { Id="Mf_Night_Investigate",        Story={ 23, 70 }, Sector="Manufacturing", Night=true,  Hard=false,
      Behaviour="Investigate", Spawns=PACKS.MfOrder, Count=1, MaxActive=1, CooldownSecs={ 210, 270 } },

    -- Hard day: three events up at once - one wandering pair and two search parties.
    { Id="Mf_Day_Wander_Hard",          Story={ 23, 70 }, Sector="Manufacturing", Night=false, Hard=true,
      Behaviour="Wander",      Spawns=PACKS.MfOrderHard, Count=2, MaxActive=1, CooldownSecs={ 600, 800 } },

    { Id="Mf_Day_Investigate_Hard",     Story={ 23, 70 }, Sector="Manufacturing", Night=false, Hard=true,
      Behaviour="Investigate", Spawns=PACKS.MfOrderHard, Count=2, MaxActive=2, CooldownSecs={ 900, 1200 } },

    { Id="Mf_Night_Hunt_Hard",          Story={ 23, 70 }, Sector="Manufacturing", Night=true,  Hard=true,
      Behaviour="Hunt",        Spawns=PACKS.MfOrderHard, Count=2, MaxActive=1, CooldownSecs={ 210, 270 } },

    -- ===================================================================
    -- LABS  (After resetting Security).
    -- ===================================================================
    { Id="Labs_Day_Wander",             Story={ 33, 36 }, Sector="Labs", Night=false, Hard=false,
      Behaviour="Wander",      Spawns=PACKS.LabsWild, Count=1, MaxActive=2, CooldownSecs={ 800, 1000 } },

    { Id="Labs_Night_Crossfire",        Story={ 33, 36 }, Sector="Labs", Night=true,  Hard=false,
      Behaviour="Crossfire",   MaxActive=1, CooldownSecs={ 150, 300 },
      Groups = { { Spawns=PACKS.LabsWild,  Count=2 },
                 { Spawns=PACKS.LabsOrder, Count=1 } } },

    { Id="Labs_Day_Investigate_Hard",   Story={ 33, 36 }, Sector="Labs", Night=false, Hard=true,
      Behaviour="Investigate", Spawns=PACKS.LabsWildHard, Count=1, MaxActive=2, CooldownSecs={ 800, 1000 } },

    { Id="Labs_Day_Crossfire_Hard",     Story={ 33, 36 }, Sector="Labs", Night=false, Hard=true,
      Behaviour="Crossfire",   MaxActive=1, CooldownSecs={ 900, 1200 },
      Groups = { { Spawns=PACKS.LabsOrderHard, Count=1 },
                 { Spawns=PACKS.LabsWildHard,  Count=2 } } },

    { Id="Labs_Night_Crossfire_Hard",   Story={ 33, 36 }, Sector="Labs", Night=true,  Hard=true,
      Behaviour="Crossfire",   MaxActive=1, CooldownSecs={ 150, 300 },
      Groups = { { Spawns=PACKS.LabsOrderHard, Count=2 },
                 { Spawns=PACKS.LabsWildHard,  Count=2 } } },
                 
    -- ===================================================================
    -- LABS  (Duplicate of above. Brief pause when opening the vault and fighting the Tarasques)
    -- ===================================================================
    { Id="Labs_Day_Wander",             Story={ 40, 999 }, Sector="Labs", Night=false, Hard=false,
      Behaviour="Wander",      Spawns=PACKS.LabsWild, Count=1, MaxActive=2, CooldownSecs={ 800, 1000 } },

    { Id="Labs_Night_Crossfire",        Story={ 40, 999 }, Sector="Labs", Night=true,  Hard=false,
      Behaviour="Crossfire",   MaxActive=1, CooldownSecs={ 150, 300 },
      Groups = { { Spawns=PACKS.LabsWild,  Count=2 },
                 { Spawns=PACKS.LabsOrder, Count=1 } } },

    { Id="Labs_Day_Investigate_Hard",   Story={ 40, 999 }, Sector="Labs", Night=false, Hard=true,
      Behaviour="Investigate", Spawns=PACKS.LabsWildHard, Count=1, MaxActive=2, CooldownSecs={ 800, 1000 } },

    { Id="Labs_Day_Crossfire_Hard",     Story={ 40, 999 }, Sector="Labs", Night=false, Hard=true,
      Behaviour="Crossfire",   MaxActive=1, CooldownSecs={ 900, 1200 },
      Groups = { { Spawns=PACKS.LabsOrderHard, Count=1 },
                 { Spawns=PACKS.LabsWildHard,  Count=2 } } },

    { Id="Labs_Night_Crossfire_Hard",   Story={ 40, 999 }, Sector="Labs", Night=true,  Hard=true,
      Behaviour="Crossfire",   MaxActive=1, CooldownSecs={ 150, 300 },
      Groups = { { Spawns=PACKS.LabsOrderHard, Count=2 },
                 { Spawns=PACKS.LabsWildHard,  Count=2 } } },

    -- ===================================================================
    -- HYDROPLANT  (Dams_DarkWaterDrained 50 .. Reactors_FirstContact 70).
    -- One crossfire, the same two groups on both tiers - hard only changes how often it comes.
    -- ===================================================================
    { Id="Hydro_Night_Crossfire",       Story={ 50, 70 }, Sector="Hydroplant", Night=true, Hard=false,
      Behaviour="Crossfire",   MaxActive=1, OncePerNight="world",
      Groups = { { Spawns=PACKS.HydroOrder, Count=2 },
                 { Spawns=PACKS.HydroWild,  Count=1 } } },

    { Id="Hydro_Crossfire_Hard",        Story={ 50, 70 }, Sector="Hydroplant", Hard=true,
      Behaviour="Crossfire",   MaxActive=1, CooldownSecs={ 900, 900 },
      Groups = { { Spawns=PACKS.HydroOrder, Count=2 },
                 { Spawns=PACKS.HydroWild,  Count=1 } } },

    -- ===================================================================
    -- EXOR VILLAGE  (V_Anteverse_C, from Plant_EnteredPlant 60 on - it stays live for the rest of
    -- the run, since the portal keeps letting the player back in).
    -- Day and night alike - one body at a time, the behaviour alternating each firing.
    -- ===================================================================
    { Id="Village_Prowl",               Story={ 60, 999 }, Sector="ExorVillage", Hard=false,
      Behaviour={ "Wander", "Investigate" }, Spawns=PACKS.VillageWild,
      Count=1, MaxActive=2, CooldownSecs={ 300, 300 } },

    { Id="Village_Prowl_Hard",          Story={ 60, 999 }, Sector="ExorVillage", Hard=true,
      Behaviour={ "Hunt", "Investigate" }, Spawns=PACKS.VillageWildHard,
      Count=1, MaxActive=2, CooldownSecs={ 180, 180 } },
}

return { DEFAULTS = DEFAULTS, SECTORS = SECTORS, PACKS = PACKS, RULES = RULES }
