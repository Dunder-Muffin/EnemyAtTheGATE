-- =======================================================================
-- GK_DarkLensPatriarchHelpers - Dark Lens Chieftain boss fight setup
--   * Base DarkLens_Chieftain sets story flags - keep it. Also handles reset/respawn.
--   * Two phases: P1 is an invulnerable, immobile turret spawning 6/3 Weak/DarkLens Phyters
--     (shield drops once the 3 specials die); P2 shield breaks, boss moves and drips in Weak
--     Phyters one at a time (P2_DRIP knobs).
--   * Dodge roll is deleted on the boss + minions; a Z-floor catch recovers anyone knocked or
--     moved off the arena edge (FALL_MARGIN). Arena deployables are made inert (DL.ArmPropGuard)
--     so escorts can't fixate on them.
--   * Phase-1 immobiliser mode + scripted facing are knobs (PATR_HOLD_MODE/PATR_SCRIPT_AIM),
--     flippable live via /dlhold. Full writeup: AnNotes/AnteNPCs/DarkLensPatriarch.md
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local ASSETS = require("AnteCore.AssetManager")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local PROJ = require("AnteCore.Projectile")
local ProjectileRows = require("AnteCore.ProjectileRows")
local DL = require("AnteNPCs.GK_DarkLensHelpers")   -- watcher / flag backstop / respawn / arenas
local LogDebug = Utils.LogDebug

local H = {}

-- Layout: knobs, then per-actor state, then private machinery bottom-up (callee before caller,
-- no forward declarations), then H.* entry points at the bottom calling into it.

-- =======================================================================
-- Knobs - boss arena
-- =======================================================================

-- Boss P1 position - we move it slightly so its standing on top of the ledge
local PATR_USE_ORIGIN  = true
local PATR_ORIGIN      = FVector(-42500, 85100, 3200)
local PATR_ORIGIN_LIFT = 40
local PATR_ORIGIN_YAW  = 0

-- Everything the shared layer needs to run this fight's watcher / backstop / respawn.
-- Centroid of the minion spots; the whole fight lives within ~1.9km of it.
local ARENA_CENTER      = FVector(-40870, 85390, 2650)
local ARENA_SCAN_RADIUS = 2600    -- class overlap for the boss body
local ARENA             = DL.ARENAS.Patriarch   -- the floor plan: "is a body in this fight's room"
local CFG = {
    StateKey     = "DarkLensArmed",
    Label        = "DarkLens",
    Boss         = "Patriarch",
    Flag         = "Fracture_DL_Chieftain_Dead",
    ClassKey     = "DarkLens_Chieftain",
    Variant      = "Fallow Patriarch",
    Center       = ARENA_CENTER,
    Area         = ARENA,
    ScanRadius   = ARENA_SCAN_RADIUS,
    WakeSq       = 4500 * 4500,   -- a player this close to ARENA_CENTER wakes the watcher's real work
    AggroSq      = 2800 * 2800,   -- a player this close to the BOSS -> ForceAggro (covers the entrance)
    WatchMs      = 3000,          -- watcher cadence (out-of-combat "is a player close" check)
    SpawnerClass = "NPCSpawn_DARKLENS_Chieftain_C",
    Home         = PATR_ORIGIN,    -- a direct respawn lands on the perch, not in the spawner's floor
    -- Prop guard (DL.ArmPropGuard): the room's level-placed deployables are made invulnerable and
    -- un-dismantleable, and stop being something the escorts fixate on. Reaches the furthest ARENA
    -- corner from ARENA_CENTER (~3600); the polygon is what actually decides what gets touched.
    PropRadius   = 3700,
}

-- =======================================================================
-- Knobs - Fallow Patriarch
-- =======================================================================

-- Boss TDI. Moves faster in phase 2
local PATR_TDI = {
    Phase1 = 1.0,   Phase1Hard = 1.2,
    Phase2 = 1.2,   Phase2Hard = 1.4,
}

local function patrTdi(mobile)
    if STATE.HardModeNoMercy then
        return mobile and PATR_TDI.Phase2Hard or PATR_TDI.Phase1Hard
    end
    return mobile and PATR_TDI.Phase2 or PATR_TDI.Phase1
end

-- TWO CLOCKS, different units. Ours decides when discs fly; the BT's decides when it may ASK.
-- Measured period = BURST_PERIOD_TICKS + however long the BT takes to say yes.
local BURST_PERIOD_TICKS    = 25   -- OUR gate, in WQ ticks (~10/s). Phase 1
local BURST_DISCS           = 2
local BURST_PERIOD_TICKS_P2 = 21   -- Phase 2: faster, and one more disc
local BURST_DISCS_P2        = 3

-- The BT's own rate limit, in SECONDS (native RangedAttack_Cooldown): how often the tree may OFFER
-- an attack. Keep it WELL UNDER the burst period - dlHoldState suppresses the offers in between.
-- A rejected offer isn't free (the fire FX multicast already played, reading as a misfire), which
-- is what the hold + HOLD_LEAD_TICKS warm-up avoid.
local BT_OFFER_SECS   = 0.5
local HOLD_LEAD_TICKS = 1     -- open the BT gate 1 tick before the burst gate (warm-up)
local BURST_FIRST_MS = 300    -- windup time to fire (native aim apex)
local BURST_GAP_MS   = 300    -- gap between shots
local BURST_RESET_MS = 200    -- after the last bolt, before the BT release


local FIRE_SOCKET    = "r_weapon_ranged1"
local KEEPWARM_TICKS = 600

-- THE DISC IS SPAWNED BY US, not by the native gun. There is no per-actor speed knob on
-- FireRanged_Projectile - it builds the shot entirely off the DT_Projectiles row, and that row is
-- shared - so a slower disc means firing it ourselves. The class is the same one, its mesh and its
-- impact are class-baked, and PROJ.Queue's ~100ms serialize slot sits well inside BURST_GAP_MS.
local DISC = {
    Speed    = 1500,   -- 5000 Disc default
    LifeSpan = 6,      
}

-- Warm and pinned assets
local BURST_DEPS = {
    ENUMS.ProjectileClasses.DiscPlasma,
    ENUMS.Components.SM_GRINDER_DISC,        -- the disc body + its impact burst; a cold one is a
    ENUMS.Effects.EXPLOSION_PLASMA_DISC,     --   silent cosmetic miss on the first shot
    ENUMS.DamageType.Fire,
    ENUMS.BuffObjects.Ignited,
    ENUMS.BuffObjects.HPDamage,
}

-- Shield setup: Should be an unbreakable red shield (Phase 1) that's permanently visible
--   - Keeping both shield and Invincible flag. Some damage bypasses it
local BARRIER_SHIELD_HP = 99999
local BARRIER_COLOR     = FVector(2, 1, 0) -- Similar color to barrier mage
local BARRIER_GLOW_MIN  = 10000  -- Force shield glow in phase 1 with a shield min (10k)

local PATR_SHIELD_HP    = 450    -- Native chieftain shield/regen. Restored by /dlreset
local PATR_SHIELD_REGEN = 20

-- Phase-1 immobiliser. "/dlhold" flips both live. Full comparison: AnNotes/AnteNPCs/DarkLensPatriarch.md
--   * "pin"  - MovementMode None. Nothing moves it, not even a launch. Needs PIN_TICKS.
--   * "hold" - speeds to 0. No upkeep, but knockback and root-motion montages still move it.
local PATR_HOLD_MODE     = "pin"

-- Scripted facing. ON, and it is not just presentation: sight is a CONE off the actor's forward
-- vector, so a turret left facing the wrong way drops CanSeeTarget and the attack branch with it.
-- The 360 cone is the belt to that braces - an immobile body should not be blindable by its own
-- yaw - and BTT_DoRangedAttack also delays up to 0.75s to turn before firing when badly faced.
local PATR_SCRIPT_AIM    = true
local PATR_SIGHT_DEGREES = 360   -- total cone; nil = leave the class default (170)

-- cadence checks
local AIM_TICKS          = 2    -- face boss towards target (PATR_SCRIPT_AIM only)
local PIN_TICKS          = 10   -- keep boss immobilized ("pin" only - "hold" self-maintains)
local BARRIER_POLL_TICKS = 20   -- Phase1: check for phase 2 (count alive DLPhyters)
local LEASH_TICKS        = 20   -- Phase1: check if this left its origin
local LEASH_DIST_SQ      = 600 * 600   -- leash distance
local UNSTICK_TICKS      = 15   -- Phase2: keep it off deployables


-- =======================================================================
-- Knobs - Minion Spawning
-- =======================================================================

-- Minions
local MINION_TIMESTAMP_TICKS = 2         -- cadence to timestamp nearby minions
local MINION_ALIVE_TICKS     = 30        -- if a minion's timestamp is this old consider it dead
local MINION_NEARBY_SQ       = 5000 * 5000   -- 50m: a special inside this sustains the barrier

local VAR_SPECIAL = "DarkLens Phyter"
local VAR_WEAK    = "Weak Phyter"

-- Specials spread across the field; spare kept below.
local SPECIAL_SPOTS = {
    FVector(-41830, 84580, 2850),
    FVector(-40400, 86470, 2510),
    FVector(-40880, 84330, 2690),
}
local WEAK_SPOTS = {
    FVector(-40690, 84290, 2730),
    FVector(-40890, 84830, 2690),
    FVector(-40930, 86530, 2500),
    FVector(-40560, 85730, 2550),
    FVector(-42170, 86020, 2760),
    FVector(-41590, 85190, 2640),
    -- FVector(-39720, 86010, 2560),
    -- FVector(-39910, 84260, 2710)
}

-- Teleport the boss back if it falls off the arena
local FALL_MARGIN    = 500
local FALL_POLL_TICKS = 15    -- ~1.5s; a fall is rare and the boss's own check rides LEASH_TICKS
local ARENA_FLOOR_Z = (function()
    local lo
    for _, list in ipairs({ SPECIAL_SPOTS, WEAK_SPOTS }) do
        for i = 1, #list do
            local z = list[i].Z
            if z and (not lo or z < lo) then lo = z end
        end
    end
    return (lo or 2500) - FALL_MARGIN
end)()


-- Phase-1 roster gate: min wave gap, and how long a claim may sit before it's released as failed.
local ROSTER_CD_TICKS      = 300   -- min gap between spawn waves (blocks re-aggro spam)
local PENDING_STALE_TICKS  = 150   -- a claim older than 15s = the spawn failed; release it
local SPAWN_STAGGER_MS     = 300   -- gap between minion spawns in a wave
local MINION_AGGRO_DELAY_MS = 1500 -- summon controller/BT needs a beat before ForceAggro

-- Phase 2 - spawn a Weak Phyter occasionally as a reinforcement
local P2_DRIP_TICKS = 150   -- 15s
local P2_DRIP_ALIVE = 2     -- max phyters

-- =======================================================================
-- Knobs - Minions
-- =======================================================================

local WEAK_SHIELD_HP = 50
local WEAK_NO_LOOT   = true
local WEAK_RANGED_CD      = 4    -- native 1
local WEAK_RANGED_CD_HARD = 3
local SHIELD_POLL_TICKS    = 5     -- shield-break poll + periodic-retreat roll cadence
local RETREAT_BREAK_GAP    = 30    -- min ticks between retreats (a regen re-break still triggers)
local RETREAT_PERIOD_TICKS = 120   -- periodic reposition cadence (12s)...
local RETREAT_CHANCE       = 0.35  -- ...taken this often when the roll comes up
local RETREAT_MIN          = 900   -- LoS band: back off but keep shooting (the Signifer kite)
local RETREAT_MAX          = 1800


-- =======================================================================
-- Knobs - visuals
-- =======================================================================

-- Boss eye point-lights (paired, one each side of the face)
local EYE = {
    On        = true,
    Bone      = "head",
    Forward   = 7,     -- +Z, out through the face
    Up        = 22,    -- -Y
    Side      = 8,     -- +-X, one light each way
    Intensity = 30,
    Atten     = 5,     -- a pinpoint: it IS the eye, it does not light the mask
    Source    = 3,
    R = 0.3, G = 4, B = 0.5,
}

-- NOTE: Tried Skeletal swapping the torso, but the size of the SK labcoat made the head float
local PATR_TORSO_MAT = ENUMS.Components.M_LABCOAT_TORII_OPEN

-- The merged mesh's torso slot. Try name first, then index (MergeAndClearSkeletals was called)
local PATR_TORSO_SLOTS = { "M_ChieftainTorso", 0 }

local PATR_BACKPACK_TINT = FVector(1.6, 0.45, 0.35)

-- Body tint
local LOOK_PATRIARCH_BODY = {
    Color = FVector(5, 2, 1),
    Emissive = 30,
    EmissiveColor = FVector(0, 5, 0),
    Components = { "Helmet", "SM_Rifle", "SM_NightVisionGoggles" },
}

-- Phyter head point-light (the "glow")
local GLOW = {
    On      = true,
    Bone    = "head",
    Forward = 0,     -- +Z; 0 = the middle of the skull, which is the point
    Up      = 4,     -- -Y, a shade above the jaw line
    Side    = 0,     -- +-X; centred (unlike the boss's paired eyes)
    Atten   = 320,
    Source  = 22,    -- ~skull-sized: soft falloff, still localised to the head
}

-- Dim the Phyters' NVG lens
local NVG = {
    LensDim        = 0.9,
    LensColor1     = FVector(0.01, 0.0, 0.01), -- (0.03, 0, 0.26)
    LensColor2     = FVector(0.1, 0.0, 0.5),   -- (0.22, 0, 1.0)
    LightIntensity = nil,
}

local LOOK_SPECIAL = { Color = FVector(20, 10, 7), EmissiveColor = FVector(1, 1, 0), Emissive = 90,
                       Shield = FVector(8, 1, 1),
                       Glow = { R = 3.0, G = 0.12, B = 0.08, Intensity = 1800 } }
local LOOK_WEAK    = { Color = FVector(3, 3, 3), EmissiveColor = FVector(0.1, 0, 1), Emissive = 40,
                       Shield = FVector(1, 1, 1),
                       Glow = { R = 0.5, G = 0, B = 1.5, Intensity = 1400 } }


-- =======================================================================
-- Per-actor state (module-local; /reload clears with the defs)
-- =======================================================================

-- (the cached boss wrapper lives in CFG._ref, owned by the shared layer - DL.Boss/SetBoss/Forget)
local dlBurstTick   = {}   -- bossKey -> FAST_TICK of last accepted burst (CooldownReady)
local dlHoldState   = {}   -- bossKey -> FAST_TICK to hold RangedAttack_OnCooldown until
local dlBarrierOn   = {}   -- bossKey -> current barrier latch (toggle; false on every mutation)
local dlRosterTick  = {}   -- bossKey -> FAST_TICK of last spawn wave (CooldownReady)
local dlPendingState = {}  -- bossKey -> { s, w, tick } - claimed-but-not-yet-spawned minions
local dlMobileOn    = {}   -- bossKey -> true once the barrier broke (phase 2: unpinned, fights on foot)
local dlDripTick    = {}   -- bossKey -> FAST_TICK of last phase-2 drip spawn (CooldownReady)
local dlOwnerState  = {}   -- minionKey -> { ownerKey, owner (wrapper), special, drip } (summon link)
local dlShieldPrev  = {}   -- minionKey -> last polled CurrentShieldHitPoints (AVU.ShieldBreakPoll)
local dlRetreatTick = {}   -- minionKey -> FAST_TICK of last retreat (CooldownReady)

-- Make sure we don't add attachments twice
--   * Visuals like tints are idempotent, but attachments are not
local dlEyeState    = {}   -- bossKey -> { pointLightComp, pointLightComp }
local dlGlowState   = {}   -- minionKey -> pointLightComp (the Phyter head glow)
local dlGlowWatch   = {}   -- minionKey -> true while its death watcher is registered


-- =======================================================================
-- PATRIARCH - placement machinery (perch / pin / leash)
-- =======================================================================

-- Hold it in place with whichever immobiliser PATR_HOLD_MODE names.
local function immobilise(actor)
    if PATR_HOLD_MODE == "pin" then AVU.PinInPlace(actor) else AVU.HoldGround(actor) end
end


-- Let it move again. BOTH releases, always: each is a no-op on a body the other holds, and that
-- is what lets /dlhold switch modes without leaving the old one latched.
local function mobilise(actor)
    AVU.ReleaseGround(actor)
    AVU.Unpin(actor)
end


-- Teleport to the perch (NPC teleport is in-drain-safe).
local function snapPerch(actor)
    if not PATR_USE_ORIGIN then return end
    pcall(function()
        actor:K2_SetActorLocationAndRotation(
            FVector(PATR_ORIGIN.X, PATR_ORIGIN.Y, PATR_ORIGIN.Z + PATR_ORIGIN_LIFT),
            FRotator(0, PATR_ORIGIN_YAW, 0), false, {}, true)
    end)
end


-- Keep this leashed - teleport it back to origin if it strays.
--   * `turret` = phase 1, which leashes IN COMBAT TOO: a knockback or a root-motion roll can
--     still shove a held body off its overlook. Phase 2 is meant to chase, so it keeps the bail.
--   * A FALL is the exception to all of that: below ARENA_FLOOR_Z is wrong in either phase, in or
--     out of combat, at any XY - so it skips both bails. Same catch the escorts get.
local function leashBoss(actor, turret)
    if not PATR_USE_ORIGIN then return end
    local loc
    pcall(function() loc = actor:K2_GetActorLocation() end)
    if not loc then return end

    if (loc.Z or 0) >= ARENA_FLOOR_Z then
        local inCombat
        pcall(function() inCombat = actor.CombatState == true end)
        if inCombat and not turret then return end
        if Utils.DistSqXY(loc, PATR_ORIGIN) <= LEASH_DIST_SQ then return end
    end
    LogDebug("Patriarch - off its perch, re-leashing", SETTINGS.DEBUG_NPC_ACTIONS)
    pcall(function()
        actor:K2_SetActorLocationAndRotation(
            FVector(PATR_ORIGIN.X, PATR_ORIGIN.Y, PATR_ORIGIN.Z + PATR_ORIGIN_LIFT),
            FRotator(0, PATR_ORIGIN_YAW, 0), false, {}, true)
    end)
end


-- =======================================================================
-- PATRIARCH - tick / barrier machinery
-- =======================================================================

-- Count this boss's fresh heartbeats, pruning stale entries. HEARTBEATS not a stored roster: a
-- freed slot still passes IsValid (S3), so liveness is inverted - each minion re-stamps its own
-- entry from its OnTick (H.MinionTick), and a stamp not refreshed in MINION_ALIVE_TICKS reads gone.
-- Returns specialNear/specialAny/weakAny/dripAny: near = BARRIER count (specials within 50m); Any
-- = ROSTER counts (escorts exist at all); dripAny = weaks the phase-2 drip sent, kept apart so the
-- drip isn't starved by a surviving roster and doesn't feed the roster's "everyone dead" re-field.
local function countFresh(bossKey)
    local pings = STATE.FallowPings[bossKey]
    if not pings then return 0, 0, 0, 0 end
    local now = STATE.FAST_TICK
    local specialNear, specialAny, weakAny, dripAny = 0, 0, 0, 0
    for mKey, rec in pairs(pings) do
        -- rec.t > now = a stamp from before a clock reset; ResetState clears the table,
        -- this is the belt-and-braces (Barrier Mage LastScan lesson).
        if (now - rec.t) > MINION_ALIVE_TICKS or rec.t > now then
            pings[mKey] = nil
        elseif rec.s then
            specialAny = specialAny + 1
            if rec.near then specialNear = specialNear + 1 end
        else
            weakAny = weakAny + 1
            if rec.d then dripAny = dripAny + 1 end
        end
    end
    return specialNear, specialAny, weakAny, dripAny
end


-- Poll if we need to bring down its Phase 1 barrier - if no DarkLens Phyters exist nearby
local function barrierPoll(actor, key)
    local nearCount = countFresh(key)
    local want = nearCount > 0
    local prev = dlBarrierOn[key]

    if prev == want then return end

    dlBarrierOn[key] = want
    if want then
        pcall(function() actor.Invincible = true end)
        AVU.SetBodyShield(actor, { Max = BARRIER_SHIELD_HP })
        -- Fresh specials -> back to turret mode (re-aggro after a phase-2 disengage)
        if dlMobileOn[key] then
            dlMobileOn[key] = nil
            AVU.SetTimeDilation(actor, patrTdi(false))   -- reset to phase 1
            snapPerch(actor)
            immobilise(actor)
        end
    else
        pcall(function() actor.Invincible = false end)
        -- Permabreak - phase 2. Need Max=0 to keep this from resetting shield if de-aggroed
        AVU.SetBodyShield(actor, { Max = 0, Current = 0, Regen = 0,
            RegenTime = 99999, RegenTimeZero = 99999 })
        if prev == true then
            pcall(function() actor:Broadcast_ForceShieldBrokenFX() end)
            -- Phase 2: off the perch and into the fight, and the whole body winds up - faster
            -- animation, chase and grab. The burst cadence is separate (BURST_PERIOD_TICKS_P2).
            --   * SERVER-LOCAL by choice: mirrored CTD rubber-bands a simulated proxy's POSITION
            --     while the actor MOVES, and this is the moving phase. Joined clients already see
            --     the faster chase through position replication.
            dlMobileOn[key] = true
            AVU.SetTimeDilation(actor, patrTdi(true))
            mobilise(actor)
            -- Start the drip's clock HERE rather than letting CooldownReady's free first call
            -- fire one immediately: reinforcements arriving on the same beat as the shield
            -- shattering just reads as the old two-at-once wave (see the P2_DRIP knobs).
            dlDripTick[key] = STATE.FAST_TICK
            -- The phase-2 call, flat and non-positional on every player's UI channel (the
            -- assault-sting route). Gated on `prev == true` with the rest of this block, so a
            -- boot/re-mutation that starts with the barrier already down never speaks it.
            AVU.PlaySound2DAll(ENUMS.SOUNDS.GKCHIEF_DL_PHASE2)
        end
    end
    LogDebug("Patriarch barrier " .. (want and "UP" or "DOWN"), SETTINGS.DEBUG_NPC_ACTIONS)
end


-- =======================================================================
-- PATRIARCH - plasma attack machinery
-- =======================================================================

-- Fire a plasma disc, ours rather than the native gun's - see the DISC knobs for why.
-- Re-validates per bolt, so a mid-burst death/DBNO just stops firing.
local function patrFireShot(actor)
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return end

    local target = AVU.GetCurrentTarget(actor)
    local aim
    if Utils.IsActorValid(target) then
        pcall(function() aim = target:K2_GetActorLocation() end)
    end
    if not aim then return end   -- no target = no bolt (the release is already queued)

    -- Same muzzle the native path used, so the disc still leaves the launcher.
    local from
    local mesh = Utils.GetValidMesh(actor)
    if mesh then
        pcall(function()
            local m = mesh:GetSocketLocation(FName(FIRE_SOCKET))
            from = FVector(m.X, m.Y, m.Z)
        end)
    end
    if not from then return end
    if Utils.DistSq(from, aim) < 1 then return end

    local dmg = 35
    pcall(function() dmg = actor.NPCData[ENUMS.NpcData.RangedDamage] or dmg end)

    -- The native gun off the slow row (FIRE_SOCKET is already its muzzle, set at burst start).
    --   Falls through to the scripted disc when it will not fire: row not ready, or stunned.
    if ProjectileRows.Fire(actor, ENUMS.ProjectileRows.PatriarchDisc, dmg, aim) then
        LogDebug("Patriarch - plasma disc (native row)", SETTINGS.DEBUG_NPC_ACTIONS)
        return
    end

    PROJ.Queue(from, Utils.Direction(from, aim), ENUMS.ProjectileClasses.DiscPlasma, nil, {
        Owner = actor, Instigator = actor,
        Damage = dmg,
        Velocity = DISC.Speed,
        MaxSpeed = DISC.Speed,    -- or the movement component ramps back toward the row's 5000
        GravityScale = 0,
        LifeSpan = DISC.LifeSpan,
        DamageTypeClass = ENUMS.DamageType.Fire,
        Preload = BURST_DEPS,
    })
    LogDebug("Patriarch - plasma disc", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- =======================================================================
-- ROSTER machinery (minion spawning)
-- =======================================================================

-- opts.Special/NoClaim/Drip/Lock are documented on spawnMinion below.
local function onMinionSpawned(m, boss, opts)
    local special = opts.Special
    local bossKey = Utils.ActorKey(boss)
    local pend = (not opts.NoClaim) and bossKey and dlPendingState[bossKey] or nil
    if pend then
        if special then pend.s = math.max(0, pend.s - 1) else pend.w = math.max(0, pend.w - 1) end
    end
    if Utils.IsActorInvalid(m) or not bossKey then return end
    local mKey = Utils.ActorKey(m)
    if not mKey then return end

    dlOwnerState[mKey] = { ownerKey = bossKey, owner = boss, special = special, drip = opts.Drip }
    AVU.WatchSummonLifetime(m, boss, { ReleaseOnParentDeath = true, Label = "Fallow minion" })

    -- Stamp NOW: the roster/barrier must see this body before its first OnTick, or a
    -- second combat flip inside the grace window double-spawns.
    local pings = STATE.FallowPings[bossKey]
    if not pings then pings = {} STATE.FallowPings[bossKey] = pings end
    pings[mKey] = { t = STATE.FAST_TICK, s = special, near = true, d = opts.Drip }

    local mLoc
    pcall(function() mLoc = m:K2_GetActorLocation() end)

    -- A DRIP arrival commits to a player who is actually in the room (bare lock = one-shot, see
    -- the P2_DRIP knobs). Everything else takes the boss's target, or the nearest player.
    if opts.Lock then
        local player = Utils.PlayerInArea(ARENA) or (mLoc and Utils.NearestPlayer(mLoc))
        if player then
            AVU.LockAggro(m, player, { DelayMs = MINION_AGGRO_DELAY_MS })
            return
        end
    end
    local target = AVU.GetCurrentTarget(boss) or (mLoc and Utils.NearestPlayer(mLoc))
    if target then AVU.ForceAggro(m, target, MINION_AGGRO_DELAY_MS) end
end


-- Spawn minion. opts:
--   Special - a DarkLens Phyter rather than a Weak one (barrier + claim bookkeeping)
--   NoClaim - this spawn was never counted into the pending-claim table, so it must not decrement
--             it either. Letting it would make rosterCheck fire a second wave.
--   Drip    - a phase-2 drip arrival: counted against P2_DRIP_ALIVE, not against the roster
--   Lock    - take a one-shot AVU.LockAggro on an arena player instead of the plain ForceAggro
local function spawnMinion(boss, variantName, spot, opts)
    if Utils.IsActorInvalid(boss) or boss.IsDead then return end
    opts = opts or {}
    AVU.SummonVariant(variantName, spot, {}, function(m)
        onMinionSpawned(m, boss, opts)
    end)
end


-- On aggro: respawn DarkLens Phyters if none are alive. Do the same with Weak Phyters
--   * Using heartbeats (never a stored-wrapper roster - GC lies) to check,
--     and a claim table so a wave can't double-spawn.
local function rosterCheck(actor)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end
    local key = Utils.ActorKey(actor)
    if not key then return end

    -- ONLY AT HOME: the spots below are hardcoded coords, so a boss fought elsewhere would spawn
    -- ten NPCs into unloaded space - a streaming BeginPlay inside the drain, the S2 freeze.
    -- Away from the arena it fights alone, and unshielded (the barrier rides those heartbeats).
    if not Utils.ActorInArea(actor, ARENA) then
        LogDebug("Patriarch - away from its arena, skipping the roster", SETTINGS.DEBUG_NPC_ACTIONS)
        return
    end
    -- Peek + stamp-on-spawn: a combat re-entry that finds everyone dead must ALWAYS
    -- re-field the roster (a blanket stamp gates the re-engage wave). The pending-claim
    -- table is what actually prevents double-spawns.
    if not AVU.CooldownReady(dlRosterTick, key, ROSTER_CD_TICKS, { Peek = true }) then return end

    local pend = dlPendingState[key]
    if pend and (STATE.FAST_TICK - pend.tick) > PENDING_STALE_TICKS then
        pend = nil
        dlPendingState[key] = nil
    end

    local _, specialAny, weakAny = countFresh(key)
    local wantS = (specialAny == 0 and not (pend and pend.s > 0)) and #SPECIAL_SPOTS or 0
    local wantW = (weakAny == 0 and not (pend and pend.w > 0)) and #WEAK_SPOTS or 0
    if wantS == 0 and wantW == 0 then return end

    dlRosterTick[key] = STATE.FAST_TICK   -- stamp only when a wave actually goes out
    pend = pend or { s = 0, w = 0 }
    pend.tick = STATE.FAST_TICK
    dlPendingState[key] = pend

    local delay = 0
    if wantS > 0 then
        pend.s = wantS
        for i = 1, #SPECIAL_SPOTS do
            local spot = SPECIAL_SPOTS[i]
            Utils.QueueWork(function() spawnMinion(actor, VAR_SPECIAL, spot, { Special = true }) end, delay)
            delay = delay + SPAWN_STAGGER_MS
        end
    end
    if wantW > 0 then
        pend.w = wantW
        for i = 1, #WEAK_SPOTS do
            local spot = WEAK_SPOTS[i]
            Utils.QueueWork(function() spawnMinion(actor, VAR_WEAK, spot, {}) end, delay)
            delay = delay + SPAWN_STAGGER_MS
        end
    end
    LogDebug(string.format("Patriarch roster - spawning %d specials / %d weaks", wantS, wantW),
        SETTINGS.DEBUG_NPC_ACTIONS)
end


-- [PHASE 2, from the tick] One weak gates in at a random phase-1 weak spot, capped on the drip's
-- OWN live count - the P2_DRIP knob block has the shape and the reasoning.
--   * Called on a cadence, so it must be cheap when it does nothing: the two counts are a walk of
--     an already-pruned heartbeat table, and everything else is behind the cooldown Peek.
--   * NoClaim: these are not a roster wave, so they must not decrement the pending-claim table -
--     that would let rosterCheck fire a second full wave.
local function phase2Drip(boss, key)
    if not AVU.CooldownReady(dlDripTick, key, P2_DRIP_TICKS, { Peek = true }) then return end
    if select(4, countFresh(key)) >= P2_DRIP_ALIVE then return end
    if not Utils.ActorInArea(boss, ARENA) then return end   -- fixed coordinates; see rosterCheck

    -- Stamp at REQUEST, not on the spawn callback: the spawn is async (preload -> queue), and a
    -- second tick inside that window would ask again with the same count and send a duplicate.
    dlDripTick[key] = STATE.FAST_TICK

    local spot = WEAK_SPOTS[math.random(1, #WEAK_SPOTS)]
    spawnMinion(boss, VAR_WEAK, spot, { NoClaim = true, Drip = true, Lock = true })
    LogDebug("Patriarch - phase 2 drip reinforcement", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- =======================================================================
-- MINIONS - retreat / rescue machinery
-- =======================================================================

-- Put a minion that has dropped out of the room back on a spawn spot - see the FALL_MARGIN block
-- for why this is a Z test and not a "did it dodge" test. Lifted like a fresh spawn so it lands on
-- the floor rather than in it.
local function minionRescue(actor)
    local loc
    pcall(function() loc = actor:K2_GetActorLocation() end)
    if not loc or (loc.Z or 0) >= ARENA_FLOOR_Z then return end

    local spot = WEAK_SPOTS[math.random(1, #WEAK_SPOTS)]
    pcall(function()
        actor:K2_SetActorLocationAndRotation(
            FVector(spot.X, spot.Y, spot.Z + PATR_ORIGIN_LIFT), FRotator(), false, {}, true)
    end)
    LogDebug("DL Phyter - fell out of the arena, put back on a spawn spot",
        SETTINGS.DEBUG_NPC_ACTIONS)
end


-- The Signifer kite, NAVMESH-ONLY (no AVU.KiteFrom Fallback): this arena has cliff edges, and a
-- blind back-away is what walks a Phyter off one. No LoS point = cornered = stand and fight.
local function minionRetreat(actor)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end
    local target = AVU.GetCurrentTarget(actor)
    if not target then return end
    AVU.KiteFrom(actor, target, { MinDist = RETREAT_MIN, MaxDist = RETREAT_MAX })
end


-- =======================================================================
-- VISUALS machinery (renderer helpers)
-- =======================================================================

-- Drop this body's eye glow
local function eyesOff(key)
    local rec = dlEyeState[key]
    if not rec then return end
    dlEyeState[key] = nil
    for i = 1, #rec do
        -- The stored wrappers are re-validated rather than trusted (S3 teardown)
        pcall(function()
            local c = rec[i]
            if IsValid(c) then c:K2_DestroyComponent(c) end
        end)
    end
end


-- [RENDERER] Upsert point-lights for eyes
local function eyeGlow(actor)
    if Utils.IsActorInvalid(actor) then return end
    local key = Utils.ActorKey(actor)
    if not key then return end

    eyesOff(key)
    if not EYE.On or SETTINGS.GAMEPLAY.REDUCE_VISUALS then return end

    local rec = {}
    for _, side in ipairs({ -EYE.Side, EYE.Side }) do
        local comp = AVU.AttachPointLight(actor, EYE.Bone, {
            Location          = FVector(side, -EYE.Up, EYE.Forward),
            Color             = FLinearColor(EYE.R, EYE.G, EYE.B, 1),
            Intensity         = EYE.Intensity,
            AttenuationRadius = EYE.Atten,
            SourceRadius      = EYE.Source,
            Immediate         = true,
        })
        if comp then rec[#rec + 1] = comp end
    end
    dlEyeState[key] = (#rec > 0) and rec or nil
    LogDebug(string.format("Patriarch - %d eye light(s) at fwd %s / up %s / side %s",
        #rec, EYE.Forward, EYE.Up, EYE.Side), SETTINGS.DEBUG_ATTACHMENTS)
end


-- Drop this body's head glow (and its book entry).
local function glowOff(key)
    local comp = dlGlowState[key]
    if not comp then return end
    dlGlowState[key] = nil
    -- The stored wrapper is re-validated rather than trusted (S3 teardown)
    pcall(function() if IsValid(comp) then comp:K2_DestroyComponent(comp) end end)
end


-- [RENDERER] Upsert the Phyter's in-skull point light. `tone` is the per-variant colour/intensity
-- slice (LOOK_SPECIAL.Glow / LOOK_WEAK.Glow); see the GLOW knob block for the shape.
--   * Re-entrant like eyeGlow: an attachment isn't idempotent, so the old component drops first.
--   * Pruned by the death watcher below - a string key never GCs, and this fight cycles many bodies.
local function headGlow(actor, tone)
    if Utils.IsActorInvalid(actor) or not tone then return end
    local dead = false
    pcall(function() dead = actor.IsDead == true end)
    if dead then return end   -- never decorate a corpse (AVAttach's own stagger rule)

    local key = Utils.ActorKey(actor)
    if not key then return end

    glowOff(key)
    if not GLOW.On or SETTINGS.GAMEPLAY.REDUCE_VISUALS then return end

    local comp = AVU.AttachPointLight(actor, GLOW.Bone, {
        Location          = FVector(GLOW.Side, -GLOW.Up, GLOW.Forward),
        Color             = FLinearColor(tone.R, tone.G, tone.B, 1),
        Intensity         = tone.Intensity,
        AttenuationRadius = GLOW.Atten,
        SourceRadius      = GLOW.Source,
        -- Immediate, because we need the COMPONENT BACK to book it for teardown - the staggered
        -- path returns nil by design (AVAttach's staggerDefer). No real cost here: the roster is
        -- already spawned on a SPAWN_STAGGER_MS ladder, so these attaches arrive spread out anyway.
        Immediate         = true,
    })
    if not comp then return end
    dlGlowState[key] = comp

    -- Put it out when the body dies. RENDERER half; H.MinionDeath is authority, so a joined client
    -- needs the OnRep'd IsDead signal - without it a wiped roster leaves lights burning on corpses.
    --   * ONE watcher per body, latched (re-entrant caller, non-re-entrant RegisterOnTickActor) -
    --     without it each pass stacks another tick entry. Watcher clears its own latch on exit.
    if not dlGlowWatch[key] then
        dlGlowWatch[key] = true
        AVU.RegisterOnTickActor(actor, function(a)
            if Utils.IsActorInvalid(a) or a.IsDead then
                glowOff(key)
                dlGlowWatch[key] = nil
                return "REMOVE"
            end
        end)
    end

    LogDebug(string.format("DL Phyter - head glow at int %s / rad %s / src %s",
        tone.Intensity, GLOW.Atten, GLOW.Source), SETTINGS.DEBUG_ATTACHMENTS)
end


-- [RENDERER] Take the glare out of the night-vision visor. The lens master has NO emissive
-- parameters, so tint's Emissive cannot reach it - Color1/Color2 via AVU.SetGlass is the only
-- lever (auto-detects slot 1, M_Glass_Lens_Purple). Idempotent - a second Visuals pass just
-- re-writes the same values. NVG knob block; detail: AnNotes/AnteNPCs/DarkLensPatriarch.md
local function nvgVisor(actor)
    if Utils.IsActorInvalid(actor) then return end
    local nvg
    pcall(function() nvg = actor.SM_NightVisionGoggles end)
    if IsNotValid(nvg) then return end

    if NVG.LensDim then
        local function dim(c) return FVector(c.X * NVG.LensDim, c.Y * NVG.LensDim, c.Z * NVG.LensDim) end
        AVU.SetGlass(nvg, { Lens = dim(NVG.LensColor1), LensInner = dim(NVG.LensColor2) })
    end
    if NVG.LightIntensity then
        pcall(function()
            local pl = actor.PointLight
            if IsValid(pl) then pl:SetIntensity(NVG.LightIntensity) end
        end)
    end
end


-- [RENDERER]
local function tintPack(actor)
    if not PATR_BACKPACK_TINT then return end
    if Utils.IsActorInvalid(actor) then return end
    pcall(function()
        local pack = actor.backpack
        if IsNotValid(pack) then return end
        AVU.TintSlot(pack, 0, { DiffuseColor = PATR_BACKPACK_TINT })
    end)
end


-- [RENDERER] Reskin the merged body's TORSO slot - see the PATR_TORSO_MAT knob block
--   * Slot by name with index 0 as the backstop
local function reskinTorso(actor)
    if not PATR_TORSO_MAT then return end
    if Utils.IsActorInvalid(actor) then return end
    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return end

    for _, slot in ipairs(PATR_TORSO_SLOTS) do
        if AVU.MaterialSlot(mesh, slot) then
            AVU.TintSlot(mesh, slot, { Material = PATR_TORSO_MAT })
            LogDebug("Patriarch - torso reskinned on slot " .. tostring(slot),
                SETTINGS.DEBUG_ATTACHMENTS)
            return
        end
    end
    LogDebug("Patriarch - no torso slot matched " .. table.concat({ tostring(PATR_TORSO_SLOTS[1]),
        tostring(PATR_TORSO_SLOTS[2]) }, "/") .. " (run /dumpmat)", SETTINGS.DEBUG_ATTACHMENTS)
end


-- =======================================================================
-- PATRIARCH - entry points
-- =======================================================================

-- [RENDERER, Visuals]
function H.PatriarchVisuals(actor)
    -- Supppress dodge + stagger stumble: Stats (CCImmune) does the authority half, this does the
    -- renderer half
    --   * Both Broadcast_Perform(Backstep|Stagger) are multicasts and each machine has its own
    --     copy of the anim fields; a weakness hit (it's acid-weak) force-sends the stagger one
    AVU.SkipBackstepAnim(actor)
    AVU.SkipStaggerAnim(actor)

    pcall(function()
        if IsValid(actor.Gun) then
            AVU.SwapSkeletalMesh(actor.Gun, ENUMS.Components.SK_GRINDER)
            actor.Gun:SetRelativeScale3D(FVector(1, 1, 1.5))
        end
    end)

    pcall(function()
        local cue = ASSETS.GetIfValid(ENUMS.SOUNDS.DISC_LAUNCHER_FIRE)
        if IsValid(cue) then actor.WeaponFireSound = cue end
    end)

    AVU.TintMesh(actor, LOOK_PATRIARCH_BODY)

    -- Tints
    reskinTorso(actor)
    tintPack(actor)

    -- Force constant shield glow. Safe to set the barrier shade permanently: the phase-2 shield is
    -- permabroken, so it never flashes in the fight's other colour.
    AVU.SetShieldColor(actor, { Color = BARRIER_COLOR, Base = BARRIER_COLOR,
        Outline = BARRIER_COLOR, Glow = 5 })

    AVU.ArmBarrierGlow(actor, { Color = BARRIER_COLOR, MinPoints = BARRIER_GLOW_MIN })

    eyeGlow(actor)
end


-- [AUTHORITY, Stats] Field writes + fail-safe resets. Runs on every (re)mutation, so a
-- save-restored boss always starts VULNERABLE (the Barrier Mage lesson).
function H.PatriarchStats(actor, opts)
    local key = Utils.ActorKey(actor)
    if key then
        dlBarrierOn[key] = false
        dlMobileOn[key] = nil    -- every (re)mutation starts as the pinned turret
        dlHoldState[key] = nil
        dlDripTick[key] = nil    -- ...so the phase-2 drip's clock starts fresh at the next flip
    end

    -- Can't be flinched, frozen, netted or knocked off its turn (debuff refusals + stagger).
    AVU.CCImmune(actor)
    pcall(function() actor.Invincible = false end)   -- pre-rework builds latched this; always clear
    AVU.SetTimeDilation(actor, patrTdi(false))   -- phase 2 winds the body up; a re-mutation is phase 1 again

    AVU.ShieldAlwaysOn(actor)   -- the barrier is the fight; never let it start stowed

    -- Replace hitscan pistol. OnRangedAttack owns attacking
    pcall(function() actor.OverrideSoldierFireLogic = true end)
    pcall(function() actor.RangedAttack_Cooldown = BT_OFFER_SECS end)
    pcall(function()
        actor.MaxAmmoCount = 5000
        actor.CurrentAmmoCount = 5000
    end)

    -- Disable grenades
    AVU.DisableGrenades(actor)
    -- Left pointing at the disc, but NOT the fire path any more - patrFireShot spawns its own.
    AVU.SetProjectileRow(actor, "GrenadeData", ENUMS.ProjectileRows.DiscPlasma, true)
    pcall(function() actor.ProjectileFireSocket = FName(FIRE_SOCKET) end)

    -- Prevent dodge/roll animations
    pcall(function() actor.EvadesProjectiles = false end)
    AVU.SkipBackstepAnim(actor)
    AVU.SkipAggroAnim(actor)

    -- See all round: a turret cannot walk its target back into a cone (see PATR_SIGHT_DEGREES).
    if PATR_SIGHT_DEGREES then AVU.SetSightConfig(actor, { Degrees = PATR_SIGHT_DEGREES }) end
end


-- [AUTHORITY, OnReady] Park it on the overlook, then hold it (adoption may catch it mid-patrol).
function H.PatriarchReady(actor)
    if Utils.IsActorInvalid(actor) then return end
    snapPerch(actor)
    immobilise(actor)
end


function H.PatriarchTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    if actor.IsDead then return "REMOVE" end
    local key = AVU.CachedFullName(actor)
    if not key then return end

    -- Cadence hold: RangedAttack_OnCooldown self-clears ~0.1s after any write (native
    -- RetriggerableDelay), so the gate is re-asserted per tick and EXPLICITLY cleared at
    -- window end - a set-and-forget true sticks forever (Rocketeer lesson).
    local holdUntil = dlHoldState[key]
    if holdUntil then
        if STATE.FAST_TICK < holdUntil then
            pcall(function() actor.RangedAttack_OnCooldown = true end)
        else
            dlHoldState[key] = nil
            pcall(function() actor.RangedAttack_OnCooldown = false end)
        end
    end

    -- Turret-phase upkeep; the leash runs in BOTH phases (out of combat, everyone goes home).
    if not dlMobileOn[key] then
        -- Scripted facing. The fire path turns it too, but only as it fires - between bursts an
        -- immobile body has no orient-to-movement to keep it pointed, and a boss facing the wrong
        -- way loses sight of its target entirely (PATR_SCRIPT_AIM).
        if PATR_SCRIPT_AIM and totalTicks % AIM_TICKS == 0 then
            local inCombat
            pcall(function() inCombat = actor.CombatState == true end)
            local target = inCombat and AVU.GetCurrentTarget(actor) or nil
            if target then AVU.FaceTarget(actor, target) end
        end
        -- "pin" ONLY - every native fire / stagger / AI-freeze restore puts walking back.
        -- "hold" self-maintains: those same restores recopy the speed from NPCData, and it is 0.
        if PATR_HOLD_MODE == "pin" and totalTicks % PIN_TICKS == 5 then AVU.PinInPlace(actor) end
    else
        -- Phase 2 only: it has to be MOVING to get stuck on the arena's deployables.
        if totalTicks % UNSTICK_TICKS == 4 then AVU.UnstickFromProp(actor, { Label = "Patriarch" }) end
        -- ...and it calls in its own reinforcements now, one at a time (P2_DRIP knobs). Polled on
        -- the unstick's cadence rather than the drip period, so the 15s clock is the DRIP's and
        -- this only has to notice it has come round.
        if totalTicks % UNSTICK_TICKS == 9 then phase2Drip(actor, key) end
    end
    if totalTicks % LEASH_TICKS == 7 then leashBoss(actor, not dlMobileOn[key]) end
    if totalTicks % BARRIER_POLL_TICKS == 3 then barrierPoll(actor, key) end
    if totalTicks % KEEPWARM_TICKS == 11 then ASSETS.WarmPinned(BURST_DEPS) end
end


-- [OnEnterCombat] Deferred a beat: the combat flip's target/CombatState reads lag the
-- dispatch (Neophyte lesson), and nothing here may run inline in the OnRep hook.
--   * Snap-to-perch covers the pre-mutation window where the boss may have wandered.
function H.PatriarchEnterCombat(actor)
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        local key = Utils.ActorKey(actor)
        if key and not dlMobileOn[key] then snapPerch(actor) end
    end, 100)
    Utils.QueueWork(function() rosterCheck(actor) end, 400)
end


-- [OnRangedAttack] BT accepted an attack (native FX multicast already played the fire montage)
--   * Gate the cadence, then schedule the burst fire
--   * Each bolt is its own WorkQueue and re-aiming between
function H.PatriarchRangedAttack(actor)
    if Utils.IsActorInvalid(actor) then return end
    local key = Utils.ActorKey(actor)
    if not key then return end

    -- Fire rate based on phase
    local phase2 = dlMobileOn[key] == true
    local burstCd    = phase2 and BURST_PERIOD_TICKS_P2 or BURST_PERIOD_TICKS
    local burstCount = phase2 and BURST_DISCS_P2 or BURST_DISCS

    if not AVU.CooldownReady(dlBurstTick, key, burstCd) then
        -- Race-window reject (the hold usually suppresses the BT before it gets here - see the
        -- BT_OFFER_SECS knob): release the task or it stalls 5-8s in the aim pose.
        Utils.QueueWork(function() AVU.ReleaseSoldierBT(actor) end, 300)
        return
    end
    dlHoldState[key] = STATE.FAST_TICK + burstCd - HOLD_LEAD_TICKS
    ASSETS.WarmPinned(BURST_DEPS)   -- first-bolt latency insurance

    for i = 0, burstCount - 1 do
        Utils.QueueWork(function() patrFireShot(actor) end, BURST_FIRST_MS + i * BURST_GAP_MS)
    end
    Utils.QueueWork(function() AVU.ReleaseSoldierBT(actor) end,
        BURST_FIRST_MS + (burstCount - 1) * BURST_GAP_MS + BURST_RESET_MS)
end


-- [OnDamageTaken] The no-tick backstop (Barrier Mage lesson: an OnTick can stop on a
-- stream-out; this hook rides the replicated tag and always fires on a hit).
function H.PatriarchDamaged(actor)
    if Utils.IsActorInvalid(actor) then return end
    local key = Utils.ActorKey(actor)
    if not key then return end
    if dlBarrierOn[key] then
        local nearCount = countFresh(key)
        if nearCount == 0 then barrierPoll(actor, key) end
    end
end


function H.PatriarchDeath(actor)
    local key = Utils.ActorKey(actor)
    if key then
        dlBarrierOn[key] = nil
        dlMobileOn[key] = nil
        dlBurstTick[key] = nil
        dlHoldState[key] = nil
        dlPendingState[key] = nil
        dlRosterTick[key] = nil
        dlDripTick[key] = nil
        STATE.FallowPings[key] = nil
        -- The mask goes dark, and that string key stops leaking (it is not weak-collectable -
        -- CLAUDE.md's naming/keying note). The torso reskin needs no teardown: it is a material
        -- on a mesh that dies with the body.
        eyesOff(key)
    end
    pcall(function() actor.Invincible = false end)
    mobilise(actor)   -- also drops the HoldGround stash (string key - it never collects itself)
    DL.ForgetGuard(actor)
    DL.ForgetBoss(CFG)

    -- Drop a bobblehead. CustomRow: skipped when the row is not in the table - the module is off,
    -- or this UE4SS cannot build rows.
    AVU.DropLoot(actor, { Row = "Chieftain Bobblehead", Amount = 1, Radius = 90, CustomRow = true })

    -- Make sure the WorldFlag for this is set (if the native failed)
    DL.FlagBackstop(CFG)

    -- This can respawn after Fractures is complete
    DL.NoteBossDeath(CFG)
end


-- [DamageGate] Ignore hits thrown in from outside the arena (shared - see DL.OutOfArena).
function H.PatriarchDamageGate(actor)
    return DL.OutOfArena(CFG, actor)
end


-- =======================================================================
-- MINIONS - entry points
-- =======================================================================

-- Shared [AUTHORITY, Stats]. The special keeps native stats + shield; the weak halves.
--   * Grenades off on both - per-slot disable, NEVER CanThrowGrenades=false.
--   * A save-RESTORED minion re-runs this but has no dlOwnerState link (module state is
--     per-session): it fights as a stray and the boss fields a fresh roster next combat
--     entry. Deliberate - no stored-roster resurrection.
function H.MinionStats(actor, opts, special)
    AVU.DisableGrenades(actor)
    -- Disable dodge
    pcall(function() actor.EvadesProjectiles = false end)
    AVU.SkipBackstepAnim(actor)
    if not special then
        AVU.SetBodyShield(actor, { Max = WEAK_SHIELD_HP })
        if WEAK_NO_LOOT then AVU.ClearLoot(actor) end
    end
end


-- [RENDERER] Same tint set as the Neophytes (the GK texture is very dark - big multipliers).
function H.MinionVisuals(actor, look)
    -- Renderer half of the no-dodge rule - see H.PatriarchVisuals (multicast, per-machine field).
    AVU.SkipBackstepAnim(actor)

    AVU.TintMesh(actor, {
        Color = look.Color,
        Emissive = look.Emissive,
        EmissiveColor = look.EmissiveColor,
        Components = { "Helmet", "SM_Rifle", "SM_NightVisionGoggles" },
    })
    AVU.SetShieldColor(actor, { Color = look.Shield, Outline = look.Shield, Glow = 5 })

    nvgVisor(actor)
    headGlow(actor, look.Glow)
end


H.SpecialVisuals = function(actor) H.MinionVisuals(actor, LOOK_SPECIAL) end
H.SpecialStats = function(actor, opts) H.MinionStats(actor, opts, true) end

H.WeakVisuals = function(actor) H.MinionVisuals(actor, LOOK_WEAK) end
H.WeakStats    = function(actor, opts)
    H.MinionStats(actor, opts, false)
    local cd = STATE.HardModeNoMercy and WEAK_RANGED_CD_HARD or WEAK_RANGED_CD
    pcall(function() actor.RangedAttack_Cooldown = cd end)   -- slow rate of fire
end


-- Shared by both the special and the weak Phyter.
function H.MinionTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    if actor.IsDead then return "REMOVE" end
    local key = AVU.CachedFullName(actor)   -- stable OnTick wrapper -> memo is safe
    if not key then return end

    -- Heartbeat: liveness for the roster, nearness for the barrier - see countFresh for both.
    local rec = dlOwnerState[key]
    if rec and totalTicks % MINION_TIMESTAMP_TICKS == 0 then
        local owner = rec.owner
        if Utils.IsActorValid(owner) and not owner.IsDead then
            local near = false
            pcall(function()
                near = Utils.DistSq(actor:K2_GetActorLocation(), owner:K2_GetActorLocation()) <= MINION_NEARBY_SQ
            end)
            local pings = STATE.FallowPings[rec.ownerKey]
            if not pings then pings = {} STATE.FallowPings[rec.ownerKey] = pings end
            pings[key] = { t = STATE.FAST_TICK, s = rec.special, near = near, d = rec.drip }
        end
    end

    -- Went over an edge - put it back on a spawn spot (see the FALL_MARGIN block). Its own slow
    -- cadence: a fall is rare and the check is a location read per body per pass, on a fight that
    -- fields a dozen of them. Not gated on the owner book either - a save-restored stray Phyter in
    -- this arena is still ours, and still should not be lying at the bottom of the map.
    if totalTicks % FALL_POLL_TICKS == 3 then minionRescue(actor) end

    if totalTicks % SHIELD_POLL_TICKS == 0 then
        -- Shield broke -> reposition. The break is a one-shot (AVU.ShieldBreakPoll), but a
        -- regenerated shield breaking AGAIN should retreat again, so it shares the retreat
        -- cooldown rather than latching.
        if AVU.ShieldBreakPoll(actor, dlShieldPrev, key)
            and AVU.CooldownReady(dlRetreatTick, key, RETREAT_BREAK_GAP, { Peek = true }) then
            dlRetreatTick[key] = STATE.FAST_TICK
            LogDebug("DL Phyter - shield broke, retreating", SETTINGS.DEBUG_NPC_ACTIONS)
            Utils.QueueWork(function() minionRetreat(actor) end, 0)   -- off the poll, off-hook
        end

        -- Periodic reposition. Peek + hand-stamp: the chance roll must not burn the
        -- cooldown on failed rolls (CLAUDE.md CooldownReady note).
        local inCombat
        pcall(function() inCombat = actor.CombatState == true end)
        if inCombat and AVU.CooldownReady(dlRetreatTick, key, RETREAT_PERIOD_TICKS, { Peek = true })
            and math.random() < RETREAT_CHANCE then
            dlRetreatTick[key] = STATE.FAST_TICK
            minionRetreat(actor)
        end
    end
end


-- Shared by both the special and the weak Phyter.
function H.MinionDeath(actor)
    if Utils.IsActorInvalid(actor) then return end
    local key = Utils.ActorKey(actor)
    if not key then return end
    local rec = dlOwnerState[key]
    if rec then
        local pings = STATE.FallowPings[rec.ownerKey]
        if pings then pings[key] = nil end
    end
    dlOwnerState[key] = nil
    dlShieldPrev[key] = nil
    dlRetreatTick[key] = nil
end


-- =======================================================================
-- REGISTRATION & DEBUG (main.lua / ChatCommands)
-- =======================================================================

-- Armed from main.lua each world load - from BOTH role branches, because the two halves below want
-- different machines and each self-gates rather than making the caller pick.
function H.Register()
    DL.ArmWatcher(CFG)      -- AUTHORITY (bails on a client itself)
    DL.ArmPropGuard(CFG)    -- EVERY ROLE - see the ARENA PROPS section in GK_DarkLensHelpers
end


-- /dlreset - encounter reset: destroy minions, wipe state, then either re-perch the live boss or
-- respawn one.
function H.ResetEncounter()
    if not Utils.IsAuthority() then return end

    local VT = require("AnteVariants.VariantTag")
    local destroyed = 0
    local hits = AVU.GetNearbyActorsOfClass(ARENA_CENTER, ARENA_SCAN_RADIUS + 2000,
        ENUMS.NpcClasses["Gatekeeper_Phyter"])
    for i = 1, #hits do
        pcall(function()
            local m = hits[i]:get()
            if Utils.IsActorValid(m) and VT.Decode(m) ~= nil then
                m:K2_DestroyActor()
                destroyed = destroyed + 1
            end
        end)
    end

    -- Full state wipe (single-arena tables)
    STATE.FallowPings = {}
    for _, t in ipairs({ dlBarrierOn, dlMobileOn, dlBurstTick, dlHoldState, dlDripTick,
                         dlPendingState, dlRosterTick, dlOwnerState, dlShieldPrev, dlRetreatTick }) do
        for k in pairs(t) do t[k] = nil end
    end

    -- Boss back to phase-1 turret: healed, native shield, pinned on the perch
    local boss = DL.Boss(CFG)
    if boss then
        pcall(function() boss.Invincible = false end)
        DL.ForgetGuard(boss)
        pcall(function() boss.RangedAttack_OnCooldown = false end)
        AVU.SetTimeDilation(boss, patrTdi(false))   -- undo the phase-2 wind-up

        -- Undo a permabreak: native shield values incl. regen
        AVU.SetBodyShield(boss, { Max = PATR_SHIELD_HP, Current = PATR_SHIELD_HP,
            Regen = PATR_SHIELD_REGEN, RegenTime = 8, RegenTimeZero = 15 })
        pcall(function() boss:InitalizeHealthValues(true) end)   -- heal limbs from NPCData
        snapPerch(boss)
        immobilise(boss)
        Utils.Log(string.format("DL reset: boss re-perched, %d minions destroyed", destroyed))
    else
        DL.NoteFlagLocked(CFG)
        DL.RespawnBoss(CFG, string.format("%d minions destroyed", destroyed))
    end
end


-- /dlhold [hold|pin|aim|noaim] - flip PATR_HOLD_MODE / PATR_SCRIPT_AIM live and print the boss's
-- real movement state. The knobs are the persistence; this is the A/B tool.
--   * A mode change re-holds the live boss, unless it is in phase 2 - re-immobilising it there
--     would freeze the chase.
--   * The readout is the point: it answers "is it ACTUALLY at 0" and "did the roll blank stick"
--     without a second test run. MaxWalkSpeed is the live value; nd= is what restores copy from.
function H.SetHoldMode(word)
    local boss = DL.Boss(CFG)
    if word == "aim" or word == "noaim" then
        PATR_SCRIPT_AIM = (word == "aim")
    elseif word == "hold" or word == "pin" then
        local key = boss and Utils.ActorKey(boss) or nil
        if boss then mobilise(boss) end   -- drop the old immobiliser before the mode changes
        PATR_HOLD_MODE = word
        if boss and not (key and dlMobileOn[key]) then immobilise(boss) end
    end

    local s = string.format("/dlhold %s aim=%s", PATR_HOLD_MODE, tostring(PATR_SCRIPT_AIM))
    if not boss then return s .. "   (no live boss)" end

    local walk, sprint, live, maxw, mode, roll = "?", "?", "?", "?", "?", "?"
    pcall(function()
        local nd = boss.NPCData
        walk = string.format("%.2f", nd[ENUMS.NpcData.WalkSpeed] or -1)
        sprint = string.format("%.2f", nd[ENUMS.NpcData.SprintSpeed] or -1)
    end)
    pcall(function() live = string.format("%.2f", boss.WalkSpeed or -1) end)
    pcall(function()
        local mv = boss.CharacterMovement
        maxw = string.format("%.2f", mv.MaxWalkSpeed or -1)
        mode = tostring(mv.MovementMode) .. (mv:IsActive() and "" or " INACTIVE")
    end)
    -- The three backstep refs (AVU.SkipBackstepAnim): no soft-ref read has ever come back on this
    -- UE4SS, so this column only says the blank was written at STATS.
    roll = "written-blind"
    return string.format("%s   phase=%s nd=%s/%s live=%s max=%s mode=%s roll=%s",
        s, dlMobileOn[Utils.ActorKey(boss) or ""] and "2" or "1",
        walk, sprint, live, maxw, mode, roll)
end


return H
