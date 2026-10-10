
-- ==============================================================================-
-- ANTEUP2 GAMEPLAY + CORE SETTINGS
--
-- * GAMEPLAY - player settings that are rarely changed once they suit you
-- * CORE     - mod internals. Probably leave these alone
--
-- * See SETTINGS for hard mode, pets, traders, item tweaks and mod compatibility
-- ==============================================================================-
local SETTINGS_CORE = {

-- =======================================================================
-- GAMEPLAY SETTINGS
-- =======================================================================
GAMEPLAY = {

    -- [SINGLE PLAYER / SERVER] Enable one late-game boss variant
    MODULE_SHADOWBOSS = true,

    -- [SINGLE PLAYER / SERVER] After some plot events, enemies seek revenge soon after in scripted assaults
    MODULE_REVENGE_ASSAULTS = true,


    -- [SINGLE PLAYER / CLIENT] Skip some Antevariant visuals - small performance boost
    REDUCE_VISUALS = false,

    -- [SINGLE PLAYER / CLIENT] Frag Grenades on the ground glow brighter, so a landed one is easy to spot
    FragGrenade_Brighter = true,

    -- [MULTIPLAYER / CLIENT] Laser colors aren't replicated well, so some lasers are forced to one color
    CLIENT_LASER_COLOR = 5,   -- Purple

    -- [SINGLE PLAYER / SERVER] AUTOSAVES the game more often (default 5 mins). Good if crashes set you back too much
    FORCE_SAVE_MINUTES = 3, --[1, 2, 3, 4]

    -- How close to a spawner players have to be for it to spawn (game default 75m)
    SpawnRange = 7500,


    -- AI Senses: native enemies are half-blind/deaf
    --   * See 20m, hear 7.5m, and need a light fixture within 25m
    --   * Spotting takes a very long time even at 7.5m, and its worse the more NPCs are nearby
    AI_SENSE = {
        HearingRange = 5000,            -- npc hearing (native 7.5m)
        StinkyRange = 2500,             -- stink debuff radius (native 12m)
        EngineSightChecksPerFrame = 15, -- enemies do more checks/frame (native 6)
        MinLightLevel = 1,              -- enemies ignore light
        Eyesight = 2,                   -- antevariants spot faster
        PetEyesight = 4,                -- pets spot faster, see further
        PetVisionDegrees = 250,         -- pet field of view (native 170)
        PetSightRadius = 2000,          -- native (8m pest, 16m peccary)
    },

},




-- =======================================================================
-- CORE SETTINGS - probably leave these alone
-- =======================================================================
CORE = {

    -- [SINGLE PLAYER] 
    -- This will hook NpcSpawner earlier, otherwise in single player, your initial location may not have antevariants
    EARLY_SPAWNER_CONFIG = true,


    -- Max work items processed per tick (0.1s) in STEADY STATE.
    --   * 2 (prev 4)
    --   * The cap exists for EXPENSIVE items: a burst of spawns whose BeginPlay blocking-loads
    --     would slam one frame. It is far too slow for the cheap majority - 2/tick is 20 items/s,
    --     so portaling between areas builds a backlog the queue never works off, and items miss
    --     their deadlines (placed spawns reported "never landed").
    WORKQUEUE_MAX_PER_TICK = 2,

    -- CATCH-UP: once the queue is this deep, raise the cap to WORKQUEUE_CATCHUP_MAX.
    --   * 0 disables catch-up entirely (back to a flat cap).
    WORKQUEUE_CATCHUP_DEPTH = 30,
    WORKQUEUE_CATCHUP_MAX = 12,

    -- The real safety rail, and why raising the cap is safe: a WALL-CLOCK budget per tick. The
    -- drain stops once a tick has spent this long, so the cap only ever pays out for items that
    -- turn out to be cheap. A tick full of spawns still drains ~1 - the first one blows the
    -- budget - while a tick of table writes drains the full catch-up cap.
    --   * This BOUNDS a hitch that a count never did: two 100ms items were always allowed.
    --   * The first due item each tick always runs, budget or not, so the queue cannot stall.
    --   * 0 disables the budget.
    WORKQUEUE_BUDGET_MS = 10,

    -- Voussoir: Spawns the whole storm rather then a local effect (Single player/host only)
    BLIZZARD_HOST_ZONE = true,


    -- [SINGLE PLAYER / SERVER / CLIENT] asset-residency KEEPER (AnteCore/AssetKeeper)
    --  Keep enabled - its a massive perf boost with a minor impact on memory and helps prevent AV crashes
    --  ON  = variant assets, spawned classes, projectiles and ClientEffects' keep-warm list are pinned:
    --        hidden components hold refs to them so they never GC
    --  OFF = pins never establish and the sweep probes every path again = the config that crashed
    -- 
    --  (!) SIDENOTE: Any asset lookup on ue4ss 1012 walks the entire UObject array (StaticFindObject/LoadAsset) 
    --      If any object's Outer is mid-teardown it AV-crashes. Extremely rare but not uncatachable
    --      
    ASSET_KEEPER = true,

    -- [SINGLE PLAYER / SERVER] Custom projectile rows (AnteCore/ProjectileRows)
    --  ON  = variant shots fly custom DT_Projectiles rows, so every player sees them fly the way
    --        the server does (speed, arc, homing)
    --  OFF = every one of those shots uses its older scripted form instead. It still works for
    --        everyone, but a joined player may see some shots drop early or fly straight
    --  Turn OFF on a server if:
    --    * any player runs a UE4SS older than v3.0.1-593 (e.g. -553 / -556) - their game cannot
    --      build the rows, and a shot whose row is missing is INVISIBLE to them (it still hurts)
    --    * the server dies during mod startup right after a "ProjectileRows - building" line
    --  A joining player's own copy of this setting is ignored: the server decides.
    CUSTOM_PROJECTILE_ROWS = true,

    -- [SINGLE PLAYER / SERVER / CLIENT] Soft-reference writes (removing an NPC's dodge-roll, stagger and aggro clips)
    --  "auto" = only on a UE4SS build they are proven on (v3.0.1-1012). Any other build skips them
    --  false  = never. true = always (a wrong guess is a crash during startup, with no error)
    --  The log says which way it went: look for "SoftRefs -"
    SOFT_REF_WRITES = "auto",

    -- [SINGLE PLAYER / SERVER / CLIENT] DataTable rows (custom items, bobbleheads, custom projectile rows, weapon retunes)
    --  "auto" = on for UE4SS v3.0.1-593 and newer, off for older builds (-553 / -556), where editing
    --           a row silently does nothing. A build the mod doesn't recognise runs a quick check instead
    --  false  = never. true = always
    --  The log says which way it went: look for "RowApi -"
    DATATABLE_ROWS = "auto",

    -- [SINGLE PLAYER / SERVER / CLIENT] addition to ASSET_KEEPER
    --   * Extends to Blueprint CLASSES (DamageTypes, buff objects, NPC classes) 
    --       > Uses a ChildActorComponent's ChildActorClass ref
    --   * Every pin is read-back verified and logs  "CLASS pin HELD/REJECTED <path>" once at world start
    --       > Rejected pins fallback to today's behavior
    --   * Turn OFF first if bisecting a crash.
    CLASS_PINS = true,

    -- [SINGLE PLAYER / SERVER] How a buff apply/remove finds its target after the off-hook hop
    --   Mode "path"  = re-find the buff component by path every time (a full object walk per op,
    --                  one more for a linked actor). The old behavior, and the kill switch
    --   Mode "rows"  = the buffs listed in Rows skip the walk and carry the actor itself across
    --   Mode "all"   = every buff op skips the walk
    --   Verify = true: the skipped ops walk anyway and check the answer they would have given.
    --     A miss logs "BuffLookup -" and puts every op back on "path" until restart. Test builds only
    --   /au-bufftest shows the counters and runs the test set (AnDebug/BuffProbe)
    BUFF_LOOKUP = {
        Mode = "all",
        Rows = { "Debuff_BeeSwarm" },   -- Mode "rows" only: the Hive Sow's (and the Plague Witch's) stings
        Verify = false,
    },

    -- [SINGLE PLAYER / SERVER / CLIENT] How an asset request checks whether the asset is already loaded
    --   "never"  = ask the game's asset registry, which needs no object walk. The asset arrives a
    --              moment later instead of on the spot
    --   "seen"   = look it up by path (a full object walk when it is gone) only for assets loaded before
    --   "always" = look it up by path every time. The old behavior, and the kill switch
    --   Pinned assets skip this either way. /pins prints the counters: "missed (walks)" is what to watch
    ASSET_PROBE = "never",

    -- [RENDERER] repairs shipped voice waves that were authored with no SoundClass (ModuleAudioFix)
    --   * Ten Grunt / Groupe "need cover" barks sit outside the class tree every volume slider
    --     adjusts, so they play at full volume however low the sliders are.
    --   * Assigns the Abiotic_Dialog class their 196 folder-mates carry. Local and cosmetic; a wave
    --     that already has a class is skipped, so an official fix supersedes this on its own.
    --   * Rides ASSET_KEEPER's pins - with the keeper off the repair lapses at the next GC.
    VOICE_SOUNDCLASS_FIX = true,
},

}



return SETTINGS_CORE
