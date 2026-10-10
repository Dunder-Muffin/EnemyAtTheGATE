
-- ==============================================================================-
-- ANTEUP2 SETTINGS
--
-- * See SETTINGS_CORE for additional gameplay knobs and internals
-- * See SETTINGS_DEBUG for configuring logging and crash support
--
-- ==============================================================================-
local SETTINGS = {

    -- [SINGLE PLAYER / SERVER]
    MODULES = {

        ------------------------------------------
        -- PET VARIANTS: Allows some Antevariant pets
        ANTEPETS = {
            Enabled = true,
            
            StarterPack = false,    -- ** Pet playthrough ** Starting items to catch a pest at the start of the game
            BreakfastInBed = true,  -- Easy feed a pet in bed. Mouseover the bed and press [F]
            
            RevivePets = true,      -- Pets teleport to an empty bed if killed
            AllPetsRegen = true,    -- Pets in hotbar also regen health
            FixPestHealing = true,  -- Pests normally heal slower then other pets
            HealMultiplier = 3,     -- Scale passive pet regen rate. (Vanilla regen is very slow)

            PetsAttackDBNO = true,  -- Pets attack DBNO enemies
            PetDeployAggroRange = 1500,  -- Pets aggro faster when placed (not through walls)

            FeedXpBonus = true,     -- Feeding XP counts thirst too: (hunger + thirst) / 4, up to 40. Never less than vanilla
                                    -- (Vanilla: hunger / 3, up to 20)
            SowMilk = 4,            -- Milk per milking of a tamed Sow (vanilla 1)
            MushroomPeccaryYield = 10, -- Mushrooms per harvest of a tamed Mushroom Peccary (vanilla 1, once every 7 in-game days)
        },


        ------------------------------------------
        -- NEW TRADERS AND ITEMS: Requires ue4ss 954+
        --   ** OFF on the newer game build regardless of what you set here (main.lua forces it):
        --      the DT_NPC_TraderItems rows don't survive its native layout, so a trader would
        --      arrive with an empty shop. Still works on the older build.
        TRADERS = {
            Enabled = true,
            CustomItems = true,   -- One trader has new items
            BetterCoworker = true, -- Gives better items for better food (hunger+thirst total)
        },


        ------------------------------------------
        -- BOBBLEHEADS: New collectible bobbleheads, dropped by a few Antevariants. Requires ue4ss 954+
        --   Turn OFF if a newer ue4ss build breaks them
        BOBBLEHEADS = true, -- Enables new bobbleheads


        ------------------------------------------
        -- DIRECTOR: Adds a more dynamic experience by spawning randomized enemies in some sectors        
        --   These npcs may idle, investigate a location, target a player, or get into crossfires with another faction
        DIRECTOR = {
            Enabled = true,
        },

        
        ------------------------------------------
        -- ELEMENTAL BALANCE: Makes a few weapons deal more elemental damage and less physical damage
        --   (ex: Welding Spear, Tech Scepter)
        ElementalBalance = false,


        ------------------------------------------
        -- SCROLLING COMBAT TEXT: Experimental addon to show player damage numbers
        -- * For a dedicated server this will enable it for all clients
        ScrollingCombatText = false,

        ------------------------------------------
        -- FARMING: Adds new plantables. Requires ue4ss 954+
        FARMING = {
            Enabled = true,
            GrowthRate = 1, -- Growth multiplier (garden plots and the mushroom farm)
            -- Apple -> Apple tree
            -- Royal Coin -> Money tree
            -- Mushroom farm: double yield
        },



        ------------------------------------------
        -- /!\ ANTEPATHY /!\ 
        -- HARD MODE: enable all of these for a challenge, or toggle ones you like. 
        ------------------------------------------
        HARDMODE = {
            NoMercy = false,      -- Harder Antevariants, some gaining new abilities
            NoEnd = false,        -- Enemies are more numerous and respawn twice as fast
            NoAvail = false,      -- Weakened some ways to 'cheese' hard encounters - explosives, rapid healing items, charge attacks, stunlocks
            NoRetreat = false,   -- Personal teleporters no longer work
            NoReprieve = false,  -- (NYI) Requires the mod "Enemy at the GATE". Hard variant assaults
        },
    },


    -- [SINGLE PLAYER / SERVER]
    -- EXISTING ITEM TWEAKS: small changes to native items and weapons
    ITEM_TWEAKS = {

        ----------------------------------------
        -- Gear
        GravityCube_Backpack = true,      -- A Gravity Cube (raw or trinket) works while in your hotbar or backpack
                                          -- (Vanilla: only while held in hand, or worn in a trinket slot)

        HaulingWatch_GravityCube = true,  -- Gain the gravity cube effect while looking at the Hauling Watch [T]
                                          -- (Vanilla: the watch only halves carry weight while you look at it)

        ----------------------------------------
        -- Deployables
        Chemistry = {                     -- QoL: faster Distillation and Chemistry bench speed and capacity
            DistillationMultiplier = 2,   -- Vanilla = 12s
            ChemistryMultiplier = 2,      -- Vanilla = 15s
            ChemistryMax = 8,             -- Vanilla = 8
        },


        -- Weapon Elemental Balance (neutral)


        -- Weapon Buffs
        VerdantSkink_HealAll = true, -- Makes Verdant Skink heal pets more reliably
                                     -- (Vanilla: If the healing splash hits a player and pet, it will pick the player)

        ElectroThrower_LongThrow = true,  -- Electro-Thrower fires lower damage bolts twice as fast, reaches further (7m -> 10m) and is more accurate. Stun rate is the same.
                                          -- Net damage and range increase, with greatly increased battery use
                                          -- (Vanilla: most bolts miss past a few meters. Multiplayer: every player needs the same value)

        NullGrenade_Instant = true,  -- Null grenades detonate on contact, or 1.6s after they land
                                     -- (Vanilla: ~4.6s from the throw. Hard to hit most Gatekeepers with it)


        -- Weapon Nerfs (hard mode NoAvail turns these on whatever the value here)
        Deatomizer_BiggerTankWeakerLaser = false,  -- Reduce Deatomizer damage and stagger to prevent instant stunlock. Triple Deatomizer's laser capacity
                                                   -- (Vanilla: overdrive plus a Laser Collector stunlocks and melts nearly anything)

                                                   
        ----------------------------------------
        -- Gear
        InventoryTrinkets = false,        -- Most Trinkets work in the Backpack. On the edge of QoL and overpowered


    },


    -- [SINGLE PLAYER / SERVER]
    MOD_COMPATIBILITY = {

        -- Mod: ENEMY AT THE GATE - lets its assaults contain AnteUp variants
        ENEMY_AT_THE_GATE = true,

        -- Mod: HARDER GRUNTS or similar. Let those mods handle specific factions
        DISABLE_ORDER_ANTEVARIANTS = false,
        DISABLE_GK_ANTEVARIANTS = false,
    },

}
























-- Fold in SETTINGS_CORE (GAMEPLAY + CORE) to SETTINGS
local okCore, CORE_SETTINGS = pcall(require, "SETTINGS_CORE")
if okCore and type(CORE_SETTINGS) == "table" then
    for k, v in pairs(CORE_SETTINGS) do SETTINGS[k] = v end
else
    print("[AnteUp2] SETTINGS_CORE.lua failed to load - running on built-in defaults (" .. tostring(CORE_SETTINGS) .. ")")
end

-- Anything below reads these unconditionally, so they exist even if the file above didn't load
SETTINGS.GAMEPLAY = SETTINGS.GAMEPLAY or {}
SETTINGS.GAMEPLAY.AI_SENSE = SETTINGS.GAMEPLAY.AI_SENSE or {}
SETTINGS.ITEM_TWEAKS = SETTINGS.ITEM_TWEAKS or {}
SETTINGS.CORE = SETTINGS.CORE or {}


-- Fold in SETTINGS_DEBUG to SETTINGS
local ok, DEBUG_SETTINGS = pcall(require, "SETTINGS_DEBUG")
if ok and type(DEBUG_SETTINGS) == "table" then
    for k, v in pairs(DEBUG_SETTINGS) do SETTINGS[k] = v end
else
    print("[AnteUp2] SETTINGS_DEBUG.lua failed to load - all debug logging is OFF (" .. tostring(DEBUG_SETTINGS) .. ")")
end


return SETTINGS
