-- =======================================================================
-- NEOPHYTE HELPERS - the machinery behind AnteNPCs/GK_Neophyte.lua: the skink-gun burst both
-- trainers fire, and the pet-Pest throw (one minion normally, a three-pest volley in hard mode).
--
-- MUST-KNOWS
--   * H.ByMode reads STATE.HardModeNoMercy at USE time. Never cache what it returns - the flag
--     settles at world load, after this file is required, and /auhard flips it live.
--   * The throw is ONE volley per fight. The latch is claimed only on commit, so a failed
--     attempt (no target yet, combat flag not up) can't burn it - which is why the tick keeps
--     re-polling instead of trusting OnEnterCombat's one-shot.
--   * The minion roster is rolled ONCE, in H.Stats, and kept on the per-actor record. That is
--     what makes the keep-warm affordable: two extra classes to hold resident instead of a
--     seven-entry pool re-walked every minute.
--   * neoState is keyed by Utils.ActorKey - the throw, the tick and Stats each see a different
--     wrapper for the same body.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local AVM = require("AnteUtils.AVMath")
local ASSETS = require("AnteCore.AssetManager")
local PROJ = require("AnteCore.Projectile")
local G = require("AnteData.Items").Global

local LogDebug = Utils.LogDebug

local H = {}

-- Pick the hard-mode value out of a { Normal =, Hard = } pair.
function H.ByMode(t) return STATE.HardModeNoMercy and t.Hard or t.Normal end

-- The def file writes its Trainer plan here. It is what a body whose STATS step bailed throws -
-- rebuilding the record costs a plan lookup, skipping costs the variant its signature move.
H.FallbackPlan = nil

-- Per-trainer record (fullName -> record):
--   * plan   = which minion this one throws; written by Stats, read by the throw
--   * gun    = plan.Gun (H.GUN_GOO / H.GUN_FROST) - which round the burst fires
--   * extras = the two hard-mode pool picks, rolled with the plan
--   * warm   = plan.Warm plus those picks, so the keep-warm holds exactly what will be thrown
--   * thrown = the volley is spent, and the minion classes can leave the warm batch
local neoState = {}

local SHIELD_HP = 150 --225


-- =======================================================================
-- THE SKINK GUN - the burst weapon that replaced the GK rifle
-- =======================================================================

local GUN = {
    FireDelayMs = 150,   -- windup after Server_DoRangedAttack before the first lob (aim apex)
    BurstCount  = { Normal = 5, Hard = 6 },   -- lobs per burst
    BurstGapMs  = 140,   -- gap between lobs within a burst
    ResetMs     = 120,   -- after the last lob, before the BT release
    Cooldown    = 1.5,   -- RangedAttack_Cooldown - the pause between bursts
    Ammo        = 500,   -- "no reload" in practice
    Damage      = 30,    -- per lob (a 5-lob burst ~= the native rifle burst); base 40

    -- Aim jitter, re-rolled per shot, so a burst peppers an area instead of drilling one point.
    -- FuzzLocation is XY-only, which is what we want - the arc solve owns Z.
    Fuzz        = { Normal = 7, Hard = 10 },

    -- WHERE THE LOB LEAVES FROM. ProjectileFireSocket defaults to "head", not a real socket on
    -- SK_Human_Skeleton - it falls back to the head bone, so the goo left the Trainer's neck
    -- instead of the skink in its hand. Repointing at the weapon socket fixes it (same move as
    -- the GK Witch and Jotun Rocketeer).
    --   * Position only, no sub-socket nudge - tune SKINK_LOC for alignment, not this.
    Socket      = "r_weapon_ranged1",

    -- FIRED-ROUND ARC. FireRanged_Projectile aims FLAT (straight down the muzzle ->
    -- LastRangedAttackLocation line), so a ballistic round only connects inside ~15m unlifted.
    -- The aim point is the one thing that path lets us own, so lifting it by the drop IS the arc.
    -- (A thrown round doesn't need any of this - it gets a real solved arc.)
    --   * The indoor guard: past ~35m the honest solve aims into the ceiling, so lift caps out
    --     here instead. (Native also adds RangedTarget_VerticalOffset - 0 here.)
    ArcMaxLift  = 900,
}

-- THE TWO ROUNDS. The def picks one per variant as `plan.Gun`, and Stats records it on the body.
-- They take DIFFERENT FIRING PATHS, and which one is decided by whether the round carries a Class:
--   * `Row` only  -> the native gun (AVU.FireProjectileRow). Cheap, replicates free, but the shot
--     is aimed FLAT, so `Speed`/`Gravity` must MIRROR the row - they feed the arc solve that fakes
--     a lob, and a number that disagrees with the row only makes the solve lie.
--   * `Class`     -> hand-thrown (PROJ.SpawnGrenade), a real solved arc at `ArcDeg`.
--   * Chill (optional) is what one hit takes off a player's body temperature - see H.FrostHit.
H.GUN_GOO = {
    Row = ENUMS.ProjectileRows.BioBall,
    Speed = 2700, Gravity = 1,
}

-- THE FROST SKINK. Thrown rather than fired, because projectile_snowball ships
-- `CanDealDamage = false` - it is the game's harmless toy, and the native gun path has no seam to
-- arm it. PROJ.SpawnGrenade's ArmDamage flips that on the SPAWNED SNOWBALL (never the shared row,
-- which the player's own snowballs read), and the throw is what gives us the handle to do it.
--   * Damage is ours, so "same damage as the goo" holds; the row's DamageType is the bare parent,
--     i.e. untagged, so nothing resists it and the chill is the only cold in the round.
H.GUN_FROST = {
    Class = ENUMS.ProjectileClasses.Snowball,
    Gravity = 1,
    MaxSpeed = 3000,   -- the row's own cap; the arc solve stays well under it
    ArcDeg = 20,       -- flat enough to read as a shot rather than a mortar
    Chill = 0.25,
}

-- Skink-gun cosmetic (attached over the hidden SM_Rifle). Offsets are SOCKET-relative.
local SKINK_SCALE = FVector(1, 1, 1)
local SKINK_LOC   = FVector(5, -15, -12) -- F+/L+/U+
local SKINK_ROT   = FRotator(180, 90, 180)

-- Fallback keep-warm for a body with no record (its Stats step bailed). A body WITH one warms
-- its own round's class instead - see newRecord.
local KEEPWARM_TICKS = 600
local KEEPWARM = { ENUMS.ProjectileClasses.BioBall, ENUMS.SOUNDS.BIOCANNON_FIRE }

local AGGRESSION_TICKS = 10   -- ~1s; how often the cover counter is cleared (see H.Tick)


-- =======================================================================
-- THE MINION THROW
-- =======================================================================

local THROW = {
    AnimSpeed   = 2,     -- the single-throw mime; the volley has its own rate
    OriginUp    = 120,   -- spawn height above the trainer's feet
    LaunchUp    = 500,
    SpeedMin    = 600,
    SpeedMax    = 1800,
    AggroMs     = 2000,  -- force the minion to aggro after this delay
    PollTicks   = 15,    -- re-check that the minion actually got thrown
}

-- [HARD] THE VOLLEY - three pests thrown on the Interfector's (notify-free) knife-throw animation,
-- the same borrowed clip the Grenadier Guard barrages with. Release beats are pre-compensated for
-- QueueWork's 100ms rounding and the spawner's own defer; full derivation: AnNotes/AnteNPCs/OrderGrunt.md.
--   * Don't change Rate without re-deriving Rel (see that note).
local VOLLEY = {
    Rate     = 0.75,   -- montage play rate
    Rel      = { 100, 300, 600 },   -- ms from volley start to each QUEUED spawn
    RestMs   = 1200,   -- when the baseline TimeDilation goes back on
    Spread   = 260,    -- lateral fan (uu) on the landing spots, so the pests arrive abreast
    Fuzz     = 60,     -- per-pest jitter on top of the fan
    Fan      = { 0, -1, 1 },   -- fan multipliers in throw order: the plan's pest lands centre
    -- FIRE LOCKOUT: without it the BT opens up mid-volley and the rifle montage cuts the throw
    -- animation short. Lever is RangedAttack_OnCooldown - "on cooldown" is child 1 of the root
    -- Selector in BT_Attack_Soldier, above both firing branches. Re-pinned on a heartbeat because
    -- each native attack attempt clears it, and released explicitly, or a body pinned outside the
    -- AI's own reset path never shoots again.
    LockMs      = 1500,   -- covers the montage (0.8 / 0.75 = 1.07s) plus the last release
    LockPulseMs = 300,    -- re-pin cadence; coarse on purpose (the drain is 2 items/tick)
}
VOLLEY.Deps = { ENUMS.Anims.INTERFECTOR_THROW_KNIVES }

-- Baseline CustomTimeDilation, matching the defs' TimeDilation. Named constant because the volley
-- punches it to 1 and has to put it back - CustomTimeDilation scales the whole animation timeline,
-- so 0.9 would stretch the montage out from under a release schedule written in real milliseconds.
local BASE_TDI = 0.9


-- =======================================================================
-- APPEARANCE
-- =======================================================================

-- [RENDERER] Tint + the rifle->skink swap. `look` is one of the def's LOOK_* tables.
function H.Visuals(actor, look)
    -- Dark texture, so needs a large color multiplier
    AVU.TintMesh(actor, {
        Color = look.Color,
        Emissive = look.Emissive,
        EmissiveColor = look.EmissiveColor,
        Components = { "Helmet", "SM_Rifle", "SM_NightVisionGoggles" },
    })

    AVU.SetShieldColor(actor, {
        Color   = look.Shield,
        Outline = look.Shield,
        Glow    = 5,
    })

    -- Swap the rifle for the skink: hide SM_Rifle + the inherited Gun, hang the squid at the
    -- rifle's socket. FireRanged_Projectile fires from the BODY mesh's ProjectileFireSocket, not
    -- the weapon component, so hiding the gun doesn't affect firing. Stats points that socket at
    -- GUN.Socket too, so shot and skink line up; SKINK_LOC then shifts the skink relative to it.
    pcall(function()
        local rifle = actor.SM_Rifle
        local sock
        if IsValid(rifle) then
            rifle:SetVisibility(false, false)
            local s = rifle:GetAttachSocketName()
            sock = s and s:ToString() or nil
        end
        pcall(function() if IsValid(actor.Gun) then actor.Gun:SetVisibility(false, false) end end)
        -- look.Skink recolours the animal itself (the frost skink is a whiteout with a cyan cast).
        -- Both colour params are passed because they are independent branches in the attach
        -- helper and the squid's material family is not shared with the body's.
        local skin = look.Skink
        AVU.AttachStaticMesh(actor, ENUMS.Components.SM_SQUID, sock or "None", {
            Location = SKINK_LOC,
            Rotation = SKINK_ROT,
            Scale = SKINK_SCALE,
            Color = skin and skin.Color,
            DiffuseColor = skin and skin.Color,
        })
    end)

    -- Skink noise instead of gunfire noise. WeaponFireSound is read locally per machine by
    -- Broadcast_DoRangedAttackFX and doesn't replicate, so the swap belongs in Visuals.
    -- Assigning the cue to the UPROPERTY roots it (no GC re-resolve needed after)
    pcall(function()
        local cue = ASSETS.GetIfValid(ENUMS.SOUNDS.BIOCANNON_FIRE)
        if IsValid(cue) then actor.WeaponFireSound = cue end
    end)
end


-- =======================================================================
-- STATS + LIFECYCLE
-- =======================================================================

-- The NPC class a pool entry will actually spawn - the row itself, or a registered variant's Base.
-- Warming the variant's own name would resolve to nothing and the summon would cold-load.
--   * Variants is required LAZILY: it pulls in GK_Neophyte, which pulls in this file, so a
--     load-time require cycles. Everything is loaded well before a mutation runs.
local function poolClass(name)
    local path = ENUMS.NpcClasses[name]
    if path then return path end
    local def = require("AnteVariants.Variants")[name]
    return def and def.Base and ENUMS.NpcClasses[def.Base] or nil
end


-- Roll the two hard-mode pool picks. Distinct where the pool allows it, so a volley reads as
-- three different pests rather than the same one twice.
local function rollExtras(plan)
    local pool = plan.Pool
    if not pool or #pool == 0 then return nil end

    local first = pool[math.random(#pool)]
    local second = first
    if #pool > 1 then
        repeat second = pool[math.random(#pool)] until second ~= first
    end
    return { first, second }
end


-- Build a trainer's record: the plan, its hard-mode roster, and the exact asset set that roster
-- needs held resident. Deduped - the pool overlaps the plan's own minion often enough that a
-- repeat would pay a second UObject-array walk for a path already in the batch.
local function newRecord(plan)
    local st = { plan = plan, gun = plan.Gun or H.GUN_GOO, warm = plan.Warm }
    if not STATE.HardModeNoMercy then return st end

    st.extras = rollExtras(plan)
    if not st.extras then return st end

    st.warm = {}
    local seen = {}
    local function add(path)
        if path and not seen[path] then
            seen[path] = true
            st.warm[#st.warm + 1] = path
        end
    end
    for _, path in ipairs(plan.Warm) do add(path) end
    add(ENUMS.Anims.INTERFECTOR_THROW_KNIVES)
    for _, name in ipairs(st.extras) do add(poolClass(name)) end
    return st
end


-- [AUTHORITY] Field writes + the per-actor minion plan. This is the ONLY place the plan and its
-- hard-mode roster are recorded, and it runs before any hook that reads them (STATS is the first
-- pipeline step).
function H.Stats(actor, plan)
    local gun = plan.Gun or H.GUN_GOO
    pcall(function() neoState[Utils.ActorKey(actor)] = newRecord(plan) end)

    AVU.DisableGrenades(actor)   -- native throw off; we drive the minion toss ourselves
    AVU.SetBodyShield(actor, { Max = SHIELD_HP })
    -- [HARD] The shell stays up out of combat - no free opening volley on a trainer that has not
    -- seen you yet, and its minion gets thrown either way.
    if STATE.HardModeNoMercy then AVU.ShieldAlwaysOn(actor) end

    -- Skink-gun: kill the native hitscan burst. Server_DoRangedAttack still runs (BT still
    -- multicasts the fire montage/sound) but returns before Grunt_FireBurst, so OnRangedAttack
    -- drives the lobs. RangedAttack_Cooldown = the pause BETWEEN bursts.
    pcall(function() actor.OverrideSoldierFireLogic = true end)
    pcall(function() actor.RangedAttack_Cooldown = GUN.Cooldown end)
    pcall(function()
        actor.MaxAmmoCount = GUN.Ammo
        actor.CurrentAmmoCount = GUN.Ammo
    end)
    -- Grenades are off, so use it to repoint FireRanged_Projectile's row handle permanently.
    -- A thrown round has no row to point at - it never takes the native path.
    if gun.Row then AVU.SetProjectileRow(actor, "GrenadeData", gun.Row, true) end

    -- Fire from the gun, not the neck (see GUN.Socket).
    pcall(function() actor.ProjectileFireSocket = FName(GUN.Socket) end)
end


-- [OnTick] Poll the throw + keep the goo-lob class/squeal warm so no burst cold-loads.
--   * No REMOVE once thrown: the keep-warm has to outlive the throw.
--   * The minion classes are only in the warm batch UNTIL they are thrown - each /Game/ path in a
--     LoadAsync batch is a UObject-array walk (~25ms), so a class nothing will spawn again is
--     pure cost.
function H.Tick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    if actor.IsDead then return "REMOVE" end

    if totalTicks % KEEPWARM_TICKS == 11 then
        local st = neoState[Utils.ActorKey(actor)]
        local warm = (st and not st.thrown and st.warm) or KEEPWARM
        ASSETS.WarmPinned(warm)
    end
    if totalTicks % THROW.PollTicks == 0 then H.TryThrow(actor) end

    -- KEEP IT WILLING TO SHOOT. Combat entry slams FailedHits to 99 (ToggleCombatStateFX), which
    -- parks the body in BT_Attack_Soldier's cover branch above every firing branch. The burst-end
    -- clear in AVU.ReleaseSoldierBT can't undo that on its own - it only runs AFTER a burst, and a
    -- burst is exactly what the counter is blocking - so the fight has to be opened here.
    --   * One BP call, non-loading. Gated on being in a fight so an idle body pays nothing.
    if totalTicks % AGGRESSION_TICKS == 3 and Utils.IsActorReadyToAttack(actor) then
        AVU.SetBlackboardInt(actor, "FailedHits", 0)
    end
end


-- [OnEnterCombat] Throw at the first chance it gets. The tick keeps polling either way - this
-- one-shot often lands before CombatState/target are readable.
function H.EnterCombat(actor)
    Utils.QueueWork(function() H.TryThrow(actor) end, 150)
end


-- [OnDeath] Prune the record + the shared loot table.
function H.Death(actor)
    if Utils.IsActorInvalid(actor) then return end
    neoState[Utils.ActorKey(actor)] = nil

    AVU.DropLoot(actor, {
        { Pool = {
            { G.MAGNETIC_ALLOY, 1 },
        } },
        { Pool = {
            { G.NACHOS, 3 },
            { G.RAD_RICE_BOWL, 1 },
            { G.PECCARY_ROAST_STUFFED, 1 },
            { G.SILK_TEMAKI, 1 },
            { G.FLASK_RESTORATIVE, 1 },
            { G.FLASK_RESTORATIVE, 1 },
        }, Count = 1 },
    })
end


-- =======================================================================
-- THE MINION THROW
-- =======================================================================

-- [PostSpawn] Ally setup (AUTHORITY, after variant mutation): join the trainer's faction, tie
-- lifetime to the trainer, fling at the locked landing spot, force aggro onto the target.
local function onMinionSpawned(pest, trainer, target, landing, fac)
    if Utils.IsActorInvalid(pest) then return end

    if fac ~= nil then AVU.SetFaction(pest, fac) end

    -- Dies with its trainer - a script-spawned NPC never unloads on its own.
    AVU.WatchSummonLifetime(pest, trainer, { Label = "Neophyte minion" })

    -- THE TOSS: horizontal speed scales with distance (clamped), so it flies AT the landing spot
    -- rather than a fixed-length lob.
    local pl = pest:K2_GetActorLocation()
    if not pl then return end
    AVU.LaunchCharacterFrom(pest, landing,
        AVM.TossSpeed(pl, landing, THROW.SpeedMin, THROW.SpeedMax), THROW.LaunchUp, true)

    -- Attack once it's down and settled (ForceAggro re-validates both actors at fire time).
    AVU.ForceAggro(pest, target, THROW.AggroMs)
end


-- [Spawn] ONE pest, thrown at `landing`. Every option here is either a registered variant or a
-- raw DT_NPCList row, and SummonVariant dispatches between them - so the hard pool can name
-- plain Pest classes alongside "Razor Pest" without a branch.
local function spawnMinion(trainer, target, variant, origin, landing, fac, yaw)
    local function postSpawn(pest) onMinionSpawned(pest, trainer, target, landing, fac) end

    -- SkipSpawnFX + Rotation go through the SPAWNER, not post-spawn: NpcSpawner writes them before
    -- FinishSpawningActor, so BeginPlay never starts the FX and the pest never faces wrong.
    -- Post-spawn versions land a frame or two late - the burst flickers and the wrong facing has
    -- already replicated to clients.
    AVU.SummonVariant(variant, origin, { SkipSpawnFX = true, Rotation = yaw }, postSpawn)
end


-- Fan a landing spot ACROSS the line of throw, so the volley arrives abreast instead of stacked:
-- AVM.PerpendicularPoint by the lane multiplier, then jittered. Lane 0 (centre) skips both.
local function laneSpot(from, to, lane)
    if lane == 0 then return FVector(to.X, to.Y, to.Z) end
    return Utils.FuzzLocation(AVM.PerpendicularPoint(from, to, VOLLEY.Spread, lane), VOLLEY.Fuzz)
end


-- Hold the rifle off for the length of a volley, then hand control straight back.
--   * First pin written inline (already on the drain, so QueueWork(_, 0) would only cost exposure).
local function lockFire(actor)
    pcall(function() actor.RangedAttack_OnCooldown = true end)
    for ms = VOLLEY.LockPulseMs, VOLLEY.LockMs, VOLLEY.LockPulseMs do
        Utils.QueueWork(function()
            if Utils.IsActorValid(actor) then pcall(function() actor.RangedAttack_OnCooldown = true end) end
        end, ms)
    end
    Utils.QueueWork(function()
        if Utils.IsActorValid(actor) then pcall(function() actor.RangedAttack_OnCooldown = false end) end
    end, VOLLEY.LockMs + VOLLEY.LockPulseMs)
end


-- [HARD] THE VOLLEY: the Interfector's three-gesture throw, one pest per gesture. The plan's own
-- minion lands centre; the two pool picks land left and right of it. See VOLLEY.
--   * The montage is played REPLICATED (PlayThirdPersonMontage carries the play rate to clients;
--     a local Montage_SetPlayRate would be server-only) and LOCKED IN PLACE, like the single
--     throw - a full second of gesture is long enough for the AI to walk out of it otherwise.
--   * Falls back to the single throw when the montage isn't resident, so a cold asset costs the
--     extra pests, never the volley beat.
local function throwVolley(trainer, target, st, origin, landing, fac, yaw)
    -- S3: re-warm at fire time - a def.Assets preload does not pin, and the first volley is tens
    -- of seconds after mutation. Doubles as the residency test: a RESIDENT asset calls back
    -- SYNCHRONOUSLY; a COLD one calls back later via EIGT and leaves this nil.
    local montage
    ASSETS.LoadAsync(VOLLEY.Deps, function(results)
        montage = results[ENUMS.Anims.INTERFECTOR_THROW_KNIVES]
    end)
    if IsNotValid(montage) then
        LogDebug("Neophyte - volley montage cold, fell back to one throw", SETTINGS.DEBUG_NPC_ACTIONS)
        return false
    end

    local roster = { st.plan.Primary, st.extras[1], st.extras[2] }
    if st.plan.Alt and math.random() >= (st.plan.PrimaryChance or 0.5) then roster[1] = st.plan.Alt end

    lockFire(trainer)   -- BEFORE the montage: the burst we are racing starts on the AI's tick
    AVU.SetTimeDilation(trainer, 1)
    AVU.PlayMontageReplicated(trainer, ENUMS.Anims.INTERFECTOR_THROW_KNIVES, VOLLEY.Rate, true)
    LogDebug("Neophyte - HARD three-pest volley", SETTINGS.DEBUG_NPC_ACTIONS)

    for i = 1, #VOLLEY.Rel do
        local variant = roster[i]
        local spot = laneSpot(origin, landing, VOLLEY.Fan[i])
        Utils.QueueWork(function()
            if Utils.IsActorInvalid(trainer) then return end
            spawnMinion(trainer, target, variant, origin, spot, fac, yaw)
        end, VOLLEY.Rel[i])
    end

    Utils.QueueWork(function()
        if Utils.IsActorValid(trainer) then AVU.SetTimeDilation(trainer, BASE_TDI) end
    end, VOLLEY.RestMs)
    return true
end


-- [Toss] Face the target, play the throw windup, then spawn + launch. One volley per trainer.
local function summonMinion(trainer, target, st)
    local aLoc = trainer:K2_GetActorLocation()
    local tLoc = target:K2_GetActorLocation()
    if not aLoc or not tLoc then return end

    -- The async spawn callback gets PLAIN VALUES only: the faction NUMBER (minions join the GK
    -- team) and a LOCKED landing spot (the target moves before the pest exists).
    local fac
    pcall(function() fac = trainer.Faction end)
    local landing = FVector(tLoc.X, tLoc.Y, tLoc.Z + 30)
    local origin  = FVector(aLoc.X, aLoc.Y, aLoc.Z + THROW.OriginUp)
    local rot     = Utils.RotatorToTarget(aLoc, tLoc)

    -- ONE yaw, used twice: the trainer turns with it AND each pest is spawned with it, so they
    -- leave the throw pointing downrange instead of sideways (the spawner's default).
    local yaw = FRotator(0, rot.Yaw, 0)
    pcall(function() trainer:K2_SetActorRotation(yaw, false) end)

    if STATE.HardModeNoMercy and st.extras
       and throwVolley(trainer, target, st, origin, landing, fac, yaw) then
        return
    end

    -- The ordinary throw: one minion, mimed on the GK's own grenade windup played fast enough to
    -- outrun its GrenadeRelease notify (which would otherwise spawn a real grenade).
    AVU.PlayMontageReplicated(trainer, ENUMS.Anims.GK_GRENADE_THROW, THROW.AnimSpeed, true)
    LogDebug("Neophyte - throwing a minion", SETTINGS.DEBUG_NPC_ACTIONS)

    local variant = st.plan.Primary
    if st.plan.Alt and math.random() >= (st.plan.PrimaryChance or 0.5) then variant = st.plan.Alt end
    spawnMinion(trainer, target, variant, origin, landing, fac, yaw)
end


-- [Throw gate] true = thrown (or already had); false = not yet, keep polling.
--   * The once-flag is claimed only on commit, so a failed attempt can't burn it.
function H.TryThrow(actor)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return false end

    local key = Utils.ActorKey(actor)
    local st = neoState[key]
    if st and st.thrown then return true end

    local inCombat = false
    pcall(function() inCombat = actor.CombatState == true end)
    if not inCombat then return false end

    -- AVU.GetCurrentTarget, NOT raw GetCurrentCombatTarget: that reads nil for a beat after the
    -- combat flip, which used to make the throw silently no-op.
    local target = AVU.GetCurrentTarget(actor)
    if not target then return false end

    if not st then
        if not H.FallbackPlan then return false end
        st = newRecord(H.FallbackPlan)
        neoState[key] = st
    end
    st.thrown = true
    summonMinion(actor, target, st)
    return true
end


-- =======================================================================
-- THE SKINK GUN
-- =======================================================================

-- [Muzzle] Where the next lob will actually spawn: the body mesh's GUN.Socket, read live so it
-- tracks the firing pose. Copied into a fresh FVector - the native return is a scratch struct.
local function neoMuzzle(actor)
    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return nil end

    local ok, loc = pcall(function() return mesh:GetSocketLocation(FName(GUN.Socket)) end)
    if not ok or not loc then return nil end
    return FVector(loc.X, loc.Y, loc.Z)
end


-- [Shot] One goo lob, off-hook (WorkQueue drain).
--   * Re-pins the aim EVERY shot - the target moves mid-burst and stale aim sails into a wall.
--   * The jitter is re-rolled per shot, so a burst walks across the target rather than stacking.
--   * FireRanged_Projectile async-loads the class (non-blocking) and spawns from the body's
--     ProjectileFireSocket.
local function neoFireShot(actor)
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return end

    local st = neoState[Utils.ActorKey(actor)]
    local gun = (st and st.gun) or H.GUN_GOO

    local target = actor:GetCurrentCombatTarget()
    local aim
    if Utils.IsActorValid(target) then
        pcall(function() aim = target:K2_GetActorLocation() end)
    end
    if aim then aim = Utils.FuzzLocation(aim, H.ByMode(GUN.Fuzz)) end

    local dmg = GUN.Damage
    pcall(function() dmg = actor.NPCData[ENUMS.NpcData.RangedDamage] or dmg end)

    -- THROWN round: a real solved arc from the muzzle, and the one path that can arm a harmless
    -- row. No muzzle or no aim means no shot - unlike the fired round there is no flat fallback.
    if gun.Class then
        local from = neoMuzzle(actor)
        if not from or not aim then return end

        local speed = AVM.ArcSpeed(from, aim, gun.ArcDeg, gun.Gravity)
        local dir = AVM.ArcDir(from, aim, gun.ArcDeg)
        PROJ.SpawnGrenade(actor, gun.Class, {
            Label = "Frost skink lob",
            Location = from,
            AlignToVelocity = true,
            Velocity = FVector(dir.X * speed, dir.Y * speed, dir.Z * speed),
            Damage = dmg,
            Gravity = gun.Gravity,
            MaxSpeed = gun.MaxSpeed,
            ArmDamage = true,   -- projectile_snowball is inert without it
        })
        LogDebug("Neophyte - frost lob", SETTINGS.DEBUG_NPC_ACTIONS)
        return
    end

    -- FIRED round: lift the aim by the drop the lob will take getting there. The native path
    -- shoots straight down the muzzle -> aim line, so this lift is the ONLY arc it ever gets.
    -- No muzzle = no lift rather than no shot: a flat lob still lands at close range.
    if aim then
        local muzzle = neoMuzzle(actor)
        if muzzle then
            aim = AVM.BallisticAimPoint(muzzle, aim, gun.Speed, gun.Gravity, GUN.ArcMaxLift)
        end
    end
    AVU.FireProjectileRow(actor, gun.Row, dmg, aim)   -- no restore: Stats set the row for good
    LogDebug("Neophyte - goo lob", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- [Burst] GUN.BurstCount lobs, then ONE BT release - each its own WorkQueue drain (S2).
--   * neoFireShot re-checks validity, so a mid-burst death just stops firing.
local function neoFireBurst(actor)
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return end

    local shots = H.ByMode(GUN.BurstCount)
    for i = 0, shots - 1 do
        Utils.QueueWork(function() neoFireShot(actor) end, i * GUN.BurstGapMs)
    end
    -- Release the BT ranged task after the burst (shared valve - see AVU.ReleaseSoldierBT).
    Utils.QueueWork(function() AVU.ReleaseSoldierBT(actor) end,
        (shots - 1) * GUN.BurstGapMs + GUN.ResetMs)
end


-- [OnRangedAttack] Skink-gun burst (authority; fires off Server_DoRangedAttack).
--   * Deferred to the aim apex - never call a native attack inline in a hook (S2).
function H.RangedAttack(actor)
    if Utils.IsActorInvalid(actor) then return end
    Utils.QueueWork(function() neoFireBurst(actor) end, GUN.FireDelayMs)
end


-- =======================================================================
-- THE FROST ROUND - a hit chills the player instead of applying a debuff outright
--
-- The temperature meter is `CurrentBodyTemperature` on the player: a replicated double that the
-- native 1.05s Timer_ComputeBodyTemperature drifts back toward whatever the room is, and that
-- CheckForTemperatureDebuffs then reads as Round(value) to pick the Chilly / Cold / Hypothermia
-- ladder. So a hit only has to nudge the number - the ladder, the frost vignette, the HUD arrow,
-- the cold-resist tiers and the slow thaw are all native consequences of it.
--   * FLOOR, not a target: pushing past -4 is the ONE thing to avoid. The native ladder has cases
--     for 1/2/3 only, and bracket 4 returns no row - which sends the caller down the same branch
--     as bracket 0 and STRIPS every temperature debuff the player had.
--   * Cold gear already answers this: the ladder is chosen with CurrentColdResist, so an equipped
--     player gets the _Resisted / _Reduced rows for free.
--   * Recovery is ~0.075/s in a neutral room, so a full chill takes ~40s to shed. Breaking off is
--     the counterplay; nothing here needs a timer of its own.
-- =======================================================================

local FROST_FLOOR = -3.2   -- see the bracket-4 note above

-- [OnDealtDamage] Reached for PROJECTILE hits via def.ProjectileDealtDamage, so `attacker` is the
-- snowball (or nil on a stale hit) and only the victim matters.
--   * Off-hook (QueueWork, the player through Utils.CarryActor): this rides ProcessDamage, and
--     OnRep_CurrentBodyTemperature does a FindObject for the cold-breath Niagara on the way through
--     (a scan, not a load - so QueueWork is enough and EIGT would be the wrong tool).
function H.FrostHit(attacker, victim)
    if not Utils.IsAuthority() then return end
    if Utils.IsActorInvalid(victim) or not Utils.IsPlayer(victim) then return end

    local chill = H.GUN_FROST.Chill or 0
    if chill <= 0 then return end
    local getV = Utils.CarryActor(victim)

    Utils.QueueWork(function()
        local v = getV()
        if not v then return end

        local temp
        pcall(function() temp = v.CurrentBodyTemperature end)
        if type(temp) ~= "number" or temp <= FROST_FLOOR then return end

        AVU.SetReplicatedProp(v, "CurrentBodyTemperature", math.max(temp - chill, FROST_FLOOR))
        LogDebug("Neophyte - frost round chilled a player", SETTINGS.DEBUG_NPC_ACTIONS)
    end, 0)
end


return H
