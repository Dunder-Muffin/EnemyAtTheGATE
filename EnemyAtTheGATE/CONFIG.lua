return {


    -- ===================================================================
    -- Which ASSAULTS files get used
    --   "Normal"       = ASSAULTS_NORMAL
    --   "NormalCustom" = ASSAULTS_NORMAL + ASSAULTS_CUSTOM.lua
    --   "Hard"         = ASSAULTS_HARD
    --   "HardCustom"   = ASSAULTS_HARD + ASSAULTS_CUSTOM.lua
    --   "Custom"       = ASSAULTS_CUSTOM.lua
    --
    -- AnteUp Integration (needs the AnteUp mod)
    --   "AnteUpNormal"       = ASSAULTS_ANTEUP_NORMAL  
    --   "AnteUpNormalCustom" = ASSAULTS_ANTEUP_NORMAL + ASSAULTS_CUSTOM.lua
    --     * These files can name AnteUp variants
    --         Wave1 = { "Pest", "Razor Pest", "Charge Peccary" },
    --       We spawn the base NPC and AnteUp turns it into the variant
    --     * The NPC will remain a base NPC if it fails for some reason
    --
    -- ===================================================================
    DIFFICULTY        = "Hard",

    -- ===================================================================
    -- Number of Assaults per week
    -- (2): Runs assaults on both portal reset days
    -- (3-4): Every other day cadence
    -- (5): Weekdays
    -- (6): Skip Sunday
    -- (7): Every day
    -- (8): ENDLESS - Assaults start soon after one ends
    --          * This will start once the Flathill portal is open
    -- ===================================================================
    ASSAULTS_PER_WEEK = 7,
    

    -- ===================================================================
    -- Silence the Facility Announcer's vocal assault alerts.
    -- * If doing constant assaults it may be worth muting
    -- ===================================================================
    SUPPRESS_ASSAULT_VOICE = false,


    -- ===================================================================
    -- Stop native "portal storm" assaults opening their own portals
    -- (Labs onwards, or any time ASSAULTS_PER_WEEK = 8)
    --
    -- * Those portals ARE the assault's spawn points, so the PortalSuppression
    --     bench upgrade can delete them and cancel the whole assault
    -- * GATE rewrites the row to a normal ground spawn instead
    --
    -- SET THIS TO false if assaults start but no enemies arrive
    -- ===================================================================
    SUPPRESS_PORTAL_STORMS = true,


    -- ===================================================================
    -- If set to true, use the settings below
    -- 
    -- * Assault NPCs run instead of walk
	-- * Deployable damage multipliers (currently set to 1x, so no change)
    -- ===================================================================
    ENABLE_ASSAULT_REBALANCING = true,

        -- Assaults normally auto-end 300 seconds after the last NPC spawns. 
        -- * Short expiration in case an NPC gets stuck
        ASSAULT_TIMEOUT   = 150, 

        -- NPCs normally approach the base out of combat
        -- * Make NPCs enter combat earlier to move faster (Credit: @Falselight)
        ASSAULT_NPCS_RUN  = true,

        

        -- NPC damage can be weak on deployables. 
        -- * A Grunt will take minutes destroying a water cooler
        -- * Tweak damage dealt to objects
        -- * Note: A couple late game enemies actually do damage. Mostly the Corrupt Bot
        DEPLOYABLE_DAMAGE_MULTIPLIER = {
            Barricade   = 1,    -- Defensive walls
            Turrets     = 1,    -- Turrets (+ Tesla Coils)
            Bench       = 1,    -- Benches, Beds
            Other       = 1,    -- Other stuff
        },

        -- If true, furniture gets destroyed at 0 hp
        FURNITURE_DESTRUCTION = true,


    -- ===================================================================

    -- ===================================================================
    -- Debugging - three independent switches
    --
    -- Running alongside AnteUp? Our keybinds share a lot of real estate with
    -- its debug binds. Set DEBUG_KEYBIND = false and leave DEBUG_COMMAND on:
    -- the keys stay free for AnteUp, and you drive GATE with /gate commands.
    -- ===================================================================

    -- Write GATE's debug chatter to ue4ss.log
    DEBUG_LOG      = false,

    -- Enable the [CTRL]/[SHIFT] keybinds listed below
    DEBUG_KEYBIND  = false,

    -- Enable the "/gate ..." chat commands listed below
    -- * These work on a dedicated server too (keybinds can't reach the host)
    -- * ANY player on the server can run them, so be careful with that
    DEBUG_COMMAND  = false,


    -- KEYBINDS (DEBUG_KEYBIND)
    -- [CTRL]  + [END]       - Redraw the next assault
    -- [SHIFT] + [END]       - Force start the next assault (Regardless of StoryProgress restrictions)
    -- [NUMPAD 6]            - Move clock ahead 1 hour
    -- [SHIFT] + [RIGHT]     - Cycle forward through custom assaults (sets next assault)
    -- [SHIFT] + [LEFT]      - Cycle backward through custom assaults (sets last assault)
    -- [CTRL]  + [RIGHT]     - Cycle forward, skipping to the next assault type
    -- [CTRL]  + [LEFT]      - Cycle backward, skipping to the previous assault type
    -- [SHIFT] + [O]         - Force save world + character (including position)
    -- [SHIFT] + [UP]        - Show current assault row
    -- [SHIFT] + [DOWN]      - Last custom assault
    -- [CTRL]  + [SHIFT] + P - Remove all nearby NPCs and loose items
    -- [CTRL]  + [SHIFT] + T - Make Disc/Laser turrets require no power
    --
    -- CHAT COMMANDS (DEBUG_COMMAND)
    -- /gate help                 - list commands
    -- /gate force                - force start the next assault
    -- /gate shuffle              - redraw the next native assault
    -- /gate setnext <row> [idx]  - queue a specific custom assault row
    -- /gate time [n]             - move clock ahead n hours (default 1)
    -- /gate turrets              - free all turrets from power
    -- /gate clear                - remove nearby NPCs and loose items
    -- /gate save                 - force save world + character
    -- /gate current              - show current assault row
    -- /gate last                 - last custom assault
    -- /gate list                 - list the custom assault rows
    -- ============================================================
}
