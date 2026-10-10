-- =======================================================================
-- State - all mutable runtime mod/game state
--   * Everything except the "Persistent" block is wiped by Utils.ResetState()
--     when the player leaves a world.
-- =======================================================================

local STATE = {

    -- =======================================================================
    -- Persistent - survives world exit. Hooks/loops can only be
    -- registered once per UE4SS session.
    -- =======================================================================
    ServerHooksRegistered = false,
    ClientLoopStarted = false,
    DebugRegistered = false,
    RenderHooksRegistered = false,  -- UI hooks (journal); HOST-only
    KeybindsRegistered = false,     -- debug keybinds; HOST + CLIENT (not dedicated)
    ChatCommandsRegistered = false, -- chat hook; EVERY role (authority runs the server commands,
                                    -- a renderer runs the local ones - see AnDebug/ChatCommands)
    ConsoleCheatsRegistered = false, -- console cheat handlers; renderer, once/session (ModuleCheats/ConsoleCheats)
    ClientLaserHookArmed = false,   -- ULaserComponent OnRep_LaserActive recolor; pure CLIENT only
    ClientNpcNotifyArmed = false,   -- NotifyOnNewObject(NPC_Base_ParentBP_C) -> ClientVisuals pickup
    ClientProjNotifyArmed = false,  -- NotifyOnNewObject(AbioticProjectile_ParentBP_C) -> ClientProjectiles dressing
    TraderNotifyArmed = false,      -- NotifyOnNewObject(TravelingTrader) -> TraderMirror costume pickup
    SowMilkHookRegistered = false,  -- HarvestingComponent milk recolor; ALL roles (once/session)
    ProjHitTraceArmed = false,      -- AbioticProjectile ProjectileOverlap trace (SETTINGS.DEBUG_PROJECTILE_HITS)
    DeployDamageProbe = false,      -- "/deploydmg" live trace of every barricade/fan hit (AnDebug/DeployDamageProbe)
    GateBridgeArmed = false,        -- EnemyAtTheGATE assault-variant bridge; AUTHORITY only (ModuleGATE)
    -- (CustomItems rows are re-applied EVERY world in InitMod - idempotent - since runtime rows don't
    --  survive world/zone transitions; no once-per-session flag, see main.lua InitMod.)

    -- Does this UE4SS build expose the injected UDataTable row API - 553 does not
    --   * We do this to turn off parts of the mod that manipulate data tables (FindRow/AddRow/GetRowNames)
    --     - Trader shop / Custom items / Bobbleheads
    --     - Coworker rewards 
    --     - Non-equipped pet regen
    --   * If this fails, ASSETS.GetDataTable will permanently return nil (instead of self?)
    HasDataTableApi = nil,
    OldUE4SSWarned = false,         -- the one-time InitMod "update your UE4SS" warning has printed

    -- "HOST" (single player / listen host), "DEDICATED", or "CLIENT".
    -- Set by Utils.DetectRole() during InitMod. Can change between worlds
    -- (e.g. play single player, then join a friend's server).
    Role = nil,

    -- The role at the PREVIOUS InitMod (persists across ResetState).
    --   * A change vs the current role means the player switched session type WITHOUT
    --     relaunching - which the once-per-session hook/keybind registrations can't
    --     fully re-do; main.lua warns on it.
    LastInitRole = nil,

    -- =======================================================================
    -- Lifecycle
    -- =======================================================================
    ModInitCalled = false,
    ModEnabled = false,
    WorldName = "",
    IsPaused = false,   -- SetGamePaused hook (AnteCore/SystemHooks). Read by the freeze watchdog:
                        -- a paused game stops FAST_TICK and would otherwise read as a wedge.
    GameState = nil, -- The survival GameState for this world

    -- =======================================================================
    -- Ticking / deferred work
    -- =======================================================================
    FAST_TICK = 0,   -- increments ~10x/second (TickManager)

    -- Hive Sow (AnteNPCs/PeccarySow): a FAST_TICK deadline through which CombatHooks'
    --   carbunclebomb BeginPlay hook hides spawned bombs.
    --   * The bomb is AnimNotify-spawned (~1s into the throw montage, not row-driven),
    --     so the Sow "arms" this brief window on each ranged attack and the hook hides
    --     any carbunclebomb that spawns inside it.
    HideCarbuncleBombsUntil = 0,
    CarbunclePassengerSeen = false, -- a Carbuncle passenger was welded this world: arms the orphan net (AVAttach)

    -- Defense Robot (AnteNPCs/RobotDefense): a FAST_TICK deadline through which CombatHooks'
    --   native-projectile suppressor is armed.
    --   * The Defense bot's mortar/frag/molotov are pure BT tasks (HasRangedAttack=false ->
    --     no property lever), so a "Mortar Turret" variant arms this window each OnTick.
    --   * The hook then DESTROYS native frag/molotov and LOW-DAMAGES the native mortar
    --     for any DefenseBot projectile spawned inside the window.
    SuppressDefenseBotUntil = 0,

    -- SELECTIVE variant of the above: per-projectile-CLASS deadlines, so a variant can
    --   kill SOME native throws but keep others (e.g. Detonator keeps the frag, drops
    --   mortar+molotov; Artillery keeps the mortar).
    --   * Keys = projectile class names (see CombatHooks DEFBOT_DESTROY),
    --     values = FAST_TICK deadlines.
    --   * Composes across variants (each re-arms only its own classes).
    --   * The global timer above still means "all classes".
    SuppressDefBotClassUntil = {},

    -- Hard mode (ModuleHardMode) world-load flags, read by the engine layer so it never
    --   has to require a Module (the RobotDefense SuppressDefenseBotUntil precedent):
    --   * HardModeNoEnd   - SpawnerHooks (day-cooldown halving + wipe 600s) and
    --     EventUtils (PlacedSpawns 1-day default).
    --   * HardModeNoMercy - SpawnerData's `Hard` entry/band gate.
    HardModeNoEnd = nil,
    HardModeNoMercy = nil,

    -- Hard mode / NoAvail (ModuleHardMode): per-weapon damage nerf vs NPCs, read by
    --   CombatHooks' CheckForNPCDamageMultiplier hook.
    --   * Keys = DamageType CLASS names ("DamageType_Laser_Gib_Katana_C"), values =
    --     multipliers. CLASS, not DamageTypeDisplayName: display names collapse
    --     subclasses (every Explosive_* reads "Explosive"), the class is what
    --     separates a Megaton from a frag.
    --   * nil = hard mode off (the common case; one cheap read per damaging hit).
    --   * Pure Lua strings/numbers - no wrappers - so ResetState clears it only for
    --     settings hygiene; HardMode.Register() re-sets it each world.
    HardModeTypeScale = nil,
    -- fn(victim, attacker, damageType) -> true = drop this hit's weakness forced-stagger. Set per
    --   world by HardMode.Register; CombatHooks' ProcessDamage hook calls it on weak hits only.
    WeaknessStaggerGate = nil,

    -- Deferred work drained by TickManager.ProcessTick (always game thread).
    -- Items: { fn = function, fireAt = FAST_TICK value }
    WorkQueue = {},
    -- ActorKey -> true: pawns whose combat entry must skip the aggro clip (AVU.SkipAggroAnim
    -- marks, the CombatHooks BT_SetCombatState hook reads). String keys; wiped per world.
    NoAggroAnimActors = {},
    -- ActorKey -> true: pawns that must never dodge-roll (AVU.SkipBackstepAnim marks, the
    -- CombatHooks DetermineDodgeDirection hook reads). String keys; wiped per world.
    NoBackstepActors = {},
    -- ActorKey -> true: stagger-immune pawns (AVU.SetStaggerImmune marks). The CombatHooks damage
    -- hook drops a WEAKNESS hit's forced stagger for them. String keys; wiped per world.
    StaggerImmuneActors = {},

    -- Actors with a recurring per-tick callback: { Actor =, Fn = }
    -- Fn(actor, FAST_TICK) returning "REMOVE" unregisters it.
    OnTickActors = {},

    -- Pattern bots: actor -> FAST_TICK when its combat started, so a
    -- combat-aligned pattern (AVU.PatternTime) restarts from step 0 each
    -- fight. Cleared by PatternTime when the actor leaves combat.
    OnTickCombatStart = {},

    -- Barrier Mage heartbeat (AnteNPCs/GK_Mage + GK_MageEye):
    --   mageFullName -> { eyeFullName -> FAST_TICK of last ping }.
    --   * Each Barrier Eye stamps its OwningMage here every tick; the mage COUNTS fresh
    --     stamps instead of doing a 25m SphereOverlap (~40ms in a crowded arena).
    --   * Self-expiring: a dead / streamed / gone eye simply stops stamping and drops
    --     out - no stale-wrapper roster.
    BarrierPings = {},

    -- Live front shield-walls (AVU.AddShieldWall), actorKey -> { Until, Cos, Absorb, Comp }.
    --   * Lives in STATE because CombatHooks reads it on every NPC damage event and the mage that
    --     cast it must not own its lifetime - a caster that streams out would strand the ward.
    --   * `Until` is a FAST_TICK stamp, so a world reset has to clear this (see Utils.ResetState).
    ShieldWalls = {},

    -- DarkLens Chieftain heartbeat (AnteNPCs/GK_DarkLens), same push model as BarrierPings:
    --   bossFullName -> { minionFullName -> { t = FAST_TICK, s = special?, near = within 50m? } }.
    --   * Minions stamp; the boss counts fresh stamps - specials-near drive its Invincible
    --     barrier, any-fresh drive the roster refill. Self-expiring, no wrapper roster.
    FallowPings = {},

    -- Last time each PLAYER was moved by us: ActorKey -> FAST_TICK. Stamped by
    -- Utils.TeleportPlayer, so every scripted player hop (Exor swap-bomb, DarkLens yank, a
    -- teleport item) lands in one ledger. Abilities that YANK A PLAYER read it as a debounce, so a
    -- pack of teleporters can't juggle someone between them. A FAST_TICK stamp, so a world reset
    -- has to clear this (see Utils.ResetState).
    PlayerTeleportTicks = {},

    -- =======================================================================
    -- Spawners
    -- =======================================================================
    -- SpawnerState[name] = { isFull = bool } (multi-spawn tracking, phase 2)
    SpawnerState = {},

    -- =======================================================================
    -- Client
    -- =======================================================================
    -- NPCs the client scanner is done with (resolved or confirmed vanilla),
    -- keyed by actor:GetFullName(). Never re-examined.
    ClientSeenActors = {},

    -- Decode attempts per not-yet-resolved NPC, keyed by GetFullName().
    -- The variant tag can replicate a beat after the actor does, so we
    -- retry a few scans before concluding an NPC is vanilla.
    ClientTagAttempts = {},

    -- NPCs whose client VISUALS pipeline is in flight, keyed by GetFullName().
    --   * Guards the scan from starting a SECOND pipeline for the same actor while the
    --     first is still waiting on ACTOR_READY (we no longer mark it Seen up front).
    ClientVisualsPending = {},

    -- Failed visuals-pipeline attempts per NPC, keyed by GetFullName().
    --   * A pipeline can time out on ACTOR_READY (mesh not replicated yet, OR a starved
    --     WorkQueue); we retry on a later scan rather than leave the NPC permanently
    --     vanilla - but bounded, so a genuinely broken actor can't retry forever.
    ClientVisualsFails = {},

    -- True while a client scan loop re-arm is pending in the WorkQueue.
    -- Cleared by ResetState (the wipe of WorkQueue kills the pending loop).
    ClientScanArmed = false,

    -- Same, for the ClientEffects (renderer-side local FX) scan loop.
    ClientEffectsArmed = false,

    -- Same, for the PetManager poll (authority; re-applies variant identities to tamed pets).
    PetManagerArmed = false,

    -- Same, for the DarkLens arena watcher (authority; adopts + aggro-checks the Fracture
    -- Chieftain boss - AnteNPCs/GK_DarkLensPatriarchHelpers.Register).
    DarkLensArmed = false,

    -- Same, for that arena's PROP guard (DL.ArmPropGuard). EVERY ROLE, not just the authority -
    -- the dismantle prompt is decided on the machine that draws it. Key = <StateKey> .. "Props".
    DarkLensArmedProps = false,

    -- Same, for the DarkLens WITCH watcher (authority; adopts + aggro-checks the Fracture Witch
    -- boss - AnteNPCs/GK_DarkLensWitchHelpers.Register). Separate arena, separate loop.
    DarkLensWitchArmed = false,

    -- Same, for the final-boss module (authority; adopts the VignetteDirector_ShadowBoss + owns
    -- the portal storms - ModuleShadow/ShadowBoss.Register).
    ShadowBossArmed = false,

    -- Same, for the DarkLens HEAVY watcher (authority; adopts + aggro-checks the Fracture Jotun
    -- boss - AnteNPCs/GK_DarkLensJotunHelpers.Register). Separate arena, separate loop.
    DarkLensJotunArmed = false,

    -- Same, for the ambient-blizzard loop (ModuleStory/Events "Winter" ongoing event; authority).
    -- Armed story-gated by Winter.GateTick (StoryManager.Tick); reset per world in Utils.
    WinterArmed = false,

    -- =======================================================================
    -- Story
    -- =======================================================================
    
    -- Rough plot progression derived from the game's world flags (StoryManager)
    --   * Gates story events, some loot drops are gated by story
    StoryProgress = 0,

    -- Story event State that's world bound. Loaded and rearmed when loading a world
    StoryArmed = false,            -- the story event loop is running
    DirectorArmed = false,         -- the ModuleDirector loop is running
    BenchCacheArmed = false,       -- AnteCore/BenchCache holds this world's bench coords

    -- Big Bot (a PlacedSpawn; its live ref rides PlacedSpawnActors): the one-time
    --   welcome party around a fresh boss has fired this SESSION.
    --   * Deliberately NOT reset per world - like StoryData.BigBotKilledOnce, but
    --     game-side only. See RobotSecurity.bigBotEscortOnce.
    BigBotSpawnedEnemies = false,

    -- Hexed Tree stalker (AnteNPCs/HexedTreeStalker): a singleton creeping tree gated on
    -- the Canaan (V_Salem) vignette.
    HexedTreeArmed = false,        -- the stalker manager loop is running (gate OR manual)
    HexedTreeManual = false,       -- debug keybind override: ignore the Salem gate
    HexedTreeActor = nil,          -- the currently-live stalker tree (checked via IsValid)

    -- Rise patrol (ModuleStory/RisePatrol): the ongoing Order sweep gated on the V_RISE box.
    -- Both flags are cleared per world by RisePatrol.Reset (StoryManager.Register).
    RisePatrolArmed = false,       -- the sweep's beat is running (gate OR manual)
    RisePatrolManual = false,      -- debug toggle: ignore the V_RISE gate

    -- Artillery Bot firing profiles: ActorKey -> an ART_PROFILES entry, chosen per spawn from
    -- opts.ArtilleryProfile (AnteNPCs/RobotDefenseHelpers). It lives out here rather than in the
    -- helper because "/reload" re-requires every AnteNPCs file and resets its module-locals - and
    -- OnReady, the only place the profile is known, never runs again for a body already standing.
    -- A roof emplacement would silently revert to the default reach mid-session.
    ArtilleryProfiles = {},

    -- Tamed Hive Sow retreats in flight: ActorKey -> { dest, throwAt, releaseAt } (ModulePets/
    -- TamedPeccary). Out here for the same "/reload" reason: each run parks the BT, and a wiped
    -- helper-local would leave the pet parked with nothing left to release it.
    SowRetreats = {},

    -- Synthetic spawners (SpawnerData.PlacedSpawns): coord key -> the live NPC we placed
    -- there. Runtime only (reset per world); the respawn day-cooldown is in StoryData.
    PlacedSpawnActors = {},

    -- coord key -> {X,Y,Z}: where that NPC was last seen ALIVE.
    --   * A placed NPC wanders, and the game brings it back where it left off - not at
    --     the spawn coord - so this is the second anchor the dedupe scan has to check
    --     before it concludes "nothing here" and stacks another body.
    --   * Plain tables, never UE structs (they outlive the tick). Cleared on a defeat.
    PlacedSpawnLastPos = {},

    -- Story Event state that's permanently persisted per world. 
    --   These are saved/loaded from FileIO -> saved/<WorldName>.json
    StoryDataDefaults = {
        BigBotKilledOnce = false, -- BigBot drops Disc Turret once (also retires its welcome party)
        LabsAssaultDone = false, -- Labs Containment breach event - happens once
        ReaperCutsceneDone = false, -- Reaper mini-cutscene at Security entrance - plays once
        OfficeFargardensArmed = false, -- armed once a player enters V_Anteverse_A (starts the exit poll)
        OfficeFargardensDone = false, -- Office Fargardens brawl cutscene - plays once

        -- Order Ambush (EVENT 3): ARMED when the train is beaten, DONE when a player is caught
        --   back at a Crafting Bench (or immediately, on a save already past the beat).
        --   * Two flags because the trip home spans a logout, and because an armed-but-unfired
        --     world must stay armed across loads.
        OrderAmbushArmed = false,
        OrderAmbushDone = false,
        CafBotMicrowaveDropped = false, -- the PLACED-spawn Cafeteria Bot drops the VotV microwave once
        MystagogueWrapsDropped = false, -- (GK_Mage) the Barrier/Abjurer/Beholder Mage rare wraps drop - once ever
        ReactorsDuskDefenseDone = false, -- Reactors Dusk Gatekeeper raid on the Behemoth - fires once
        ReactorsCloudTakeoverDone = false, -- Reactors Cloud Order-vs-Jotun crossfire - fires once

        -- Reactors S2War "Gale" events: each war button's wave assault fires ONCE ever.
        --   * Marked done (and saved) the instant the event fires, BEFORE the waves run -
        --     so a logout mid-assault, or right after pressing a button, never
        --     re-triggers it on return.
        --   * The game's ButtonN_Pressed flag persists forever, so without these it
        --     WOULD refire every time a player re-entered.
        ReactorsGale1Done = false,
        ReactorsGale2Done = false,
        ReactorsGale3Done = false,

        -- Suomi rocket cache (EVENT 11): ARMED on Reactors_SG_Entered (which trips at the
        --   vignette ENTRANCE), DONE only once the cache's level actually streamed in and
        --   the items dropped.
        --   * Two flags because the fire point is 200m+ past the arm point, so the poll
        --     has to survive a logout between them.
        ShadowgateCacheArmed = false,
        ShadowgateCacheDone = false,

        -- Sleep Shade (ModuleStory/SleepShade): the once-ever jumpscare at a player's bed. Spent
        --   when the Shade is sent, not when the watcher first sees a sleeper.
        SleepShadeDone = false,

        -- (GK_DarkLensJotunHelpers) the DarkLens Heavy boss has lost its mount, so it is
        --   permanently in phase 2: no steed, no barrier, ever again in this world.
        --   * The boss BODY persists (300km DespawnDistance) but our module state does not, so
        --     without this a player who walked out of the Fracture and back would find it
        --     re-mounted and invulnerable again. Written the instant the steed dies.
        --   * Cleared by /dlreset jotun.
        FallowJotunDismounted = false,

        -- (PlacedSpawns) synthetic-spawner respawn gate: coord key -> in-game hour it may
        -- respawn (Utils.GetGameHours + the cooldown, stamped when its NPC is killed).
        PlacedSpawnReadyHour = {},

        -- (GK_DarkLensHelpers) DarkLens miniboss respawn gate: death-flag row name -> in-game
        --   day that boss may come back (GetCurrentDay + DL.RESPAWN_DAYS, stamped when it dies).
        --   * Persisted because the whole point is a cooldown measured in DAYS, which a player
        --     will sleep and log out through.
        --   * A world flag can never be UN-set. The flag can only ever say "this boss has died
        --     at least once" - this map is what makes a repeatable kill possible.
        DarkLensRespawnDay = {},

        -- (SpawnerHooks) Count-group wipe cooldowns: spawner name -> in-game hour it refills.
        SpawnerWipeReadyHour = {},

        -- (PetManager) ANTEPETS.StarterPack one-time grant: the pet-run starter
        --   pack (a deployed trap + bed + starting consumables) is created ONCE per world,
        --   then this latches true so it never re-grants. See PM.CreateStarterPack.
        PetStarterPackDone = false,

        -- (PetManager) guid -> tamed-variant name, for AnteUp2 variants tamed as NATIVE pets.
        --   * Keyed by the pet's persistent BuffActor_Tamed.Guid (stable across pickup/reload);
        --     the poll re-mutates the matching pet to the tamed variant on every (re)spawn.
        --   * Reversible: on uninstall the pet stays vanilla and this map is orphaned.
        --   * See [[af-pet-system]].
        Pets = {},

        -- (PetManager) item AssetID -> WILD variant name, for variant PESTS captured in a
        --   Deployed_PestTrap.
        --   * The trap DESTROYS the wild variant pest and respawns a plain one from a pet
        --     ITEM keyed only on the base row - so the variant identity is lost unless we
        --     record it.
        --   * Keyed by the caught pet item's AssetID (minted at capture, saved in the trap's
        --     inventory, and passed to SpawnPet as its Guid - so this shares Pets' key space).
        --   * Re-applied on every SpawnPetFromItem materialization.
        --     See [[anteup2-pest-trap-capture]].
        TrappedPests = {},

        -- (ModuleRevenge/RevengeDirector) the revenge-assault CALENDAR for this world.
        --   * Scheduled = { { Id = "Revenge_Train", Day = 12 }, ... } - booked, not yet run.
        --     An ARRAY of records on purpose: json.encode turns a sparse day-keyed map into an
        --     object and the round-trip stops being stable.
        --   * Fired = { Revenge_Train = 12 } - Id -> the in-game day it ran. A revenge is
        --     once-per-world; renaming a roster Id RE-ARMS it on every existing save.
        --   * Seen = { Revenge_Train = true } - this def's trigger has been OBSERVED satisfied.
        --     A revenge books on the false->true EDGE of its trigger. World flags restored from
        --     a save fire no change event (WorldFlagsChanged never fires at load), so "newly
        --     flipped" can only be answered against a persisted baseline - this is it.
        --   * Seeded - has the baseline been taken? The FIRST scan of a world absorbs everything
        --     already satisfied into Seen WITHOUT booking it; every scan after that books on the
        --     edge. Without this, installing onto a late save books the whole roster at once.
        RevengeCalendar = { Scheduled = {}, Fired = {}, Seen = {}, Seeded = false },
    },
    StoryData = {},
}

return STATE
