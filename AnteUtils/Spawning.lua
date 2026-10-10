-- =======================================================================
-- Spawning (SP) - putting a NEW actor into the world from a variant.
-- Split out of AVUtils, re-exported onto AVU: callers write AVU.SummonVariant / SpawnCloud / etc.
--
-- All of these are deferred spawns sharing one hazard (CLAUDE.md S2): a fresh actor's BeginPlay
-- BLOCKING-LOADS what it needs (mesh, Niagara, a projectile's DamageType). Nested in a UE4SS hook -
-- where QueueWork drains - that re-enters ProcessEvent and DEADLOCKS the game thread, HOST/SP too.
--
-- Every spawn here is two-step, and a NEW one must be as well:
--   1. ASSETS.LoadAsync(everything the actor touches), so BeginPlay is a pure cache hit.
--   2. Spawn on the role-split escape hatch:
--        if STATE.Role == "DEDICATED" then ExecuteInGameThread(doSpawn) else Utils.QueueWork(doSpawn, 0) end
--      EIGT is the only TRUE off-hook escape, but on a renderer host it flushes mid-paint and
--      crashes - so a host uses the queue and leans on step 1 instead.
--   3. `nosave = true` goes on the DEFERRED actor, BEFORE FinishSpawningActor - setting it after
--      is too late and the thing reloads orphaned. (Deployables/clouds set it twice, pre- and
--      post-finish, for that reason.)
--
-- The PORTAL pair at the bottom is the "reinforcements arrive through a rift" set-piece:
-- PortalDrop opens the doorway, PortalSummon spawns + mutates + faction/targets what walks out.
-- ARRIVALS names PortalSummon presets, so a summon can swap its spawn-in by name ("rift").
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local UEHelpers = require("UEHelpers")
local STATE = require("AnteCore.State")
local ASSETS = require("AnteCore.AssetManager")
local Utils = require("AnteUtils.Utils")
local ENUMS = require("AnteData.Enums")
local AF2 = require("AnteUtils.AFUtils2")
local FX = require("AnteUtils.ClientFX")
local ItemSpawner = require("AnteCore.ItemSpawner")
local PROJ = require("AnteCore.Projectile")
local AVM = require("AnteUtils.AVMath")
local SETTINGS = require("Settings")
local LogBad = Utils.LogBad
local LogDebug = Utils.LogDebug

---@class AVU.Spawning        -- merged onto AVU below; the name is what makes goto-def work
local SP = {}


-- =======================================================================
-- SPAWN-IN FX / TIMING - the cosmetics of arriving.
-- =======================================================================

-- [AUTHORITY] Cut an NPC's spawn-in FX/montage short, from Stats/OnReady. BeginPlay checks
-- SkipSpawnFX before our mutation runs, so we can't pre-empt it - we END the FX by clearing the
-- replicated IsPerformingSpawnFX, whose OnRep fires OnSpawnFXEnded everywhere.
-- This can only CUT IT SHORT (a frame or two still shows). To suppress it ENTIRELY, pass
-- SkipSpawnFX through the SPAWNER (NpcSpawner writes it pre-FinishSpawningActor, so the FX never
-- starts) - which is what SP.SummonVariant's opts.SkipSpawnFX does.
function SP.SkipSpawnFX(actor)
    if Utils.IsActorInvalid(actor) then return end
    pcall(function()
        actor.SkipSpawnFX = true
        actor.IsPerformingSpawnFX = false
        Utils.MarkReplicatedDirty(actor, "IsPerformingSpawnFX")
        actor:OnRep_IsPerformingSpawnFX()
    end)
end


-- Default SPAWN_DELAY (ms) per base row, when a variant doesn't set its own. This is the
-- BEHAVIOUR half of NpcManager's split gate - how long def.OnReady waits, and the reason the
-- number is large: OnReady can read where the body IS, and the Order rappel set spends its first
-- 3.5s hanging off a rope. See SP.VisualDelay for the appearance half.
--   * Most NPCs pop straight in, so a near-instant mutate keeps summons from standing inert.
local LONG_SPAWN_DELAY = 2700
local LONG_SPAWN_ROWS = {
    Grunt = true, Grunt_Guard = true, Grunt_Medic = true,
    Grunt_Captain = true, Grunt_Shotgun = true,
}
-- Pest family mutates a touch faster (they pop straight in, no spawn anim to wait out).
local FAST_SPAWN_ROWS = {
    Pest = true, Pest_Carbonated = true, Pest_Electro = true,
}
function SP.SpawnAnimDelay(baseRow)
    if baseRow and LONG_SPAWN_ROWS[baseRow] then return LONG_SPAWN_DELAY end
    if baseRow and FAST_SPAWN_ROWS[baseRow] then return 50 end
    return 150
end


-- How long the APPEARANCE half waits, derived from the entrance wait above.
--   * A body's own mesh is up and on screen from the first frame of its entrance, so dressing it
--     needs only the mesh (ACTOR_READY) plus a short settle for the capsule init. Held to the
--     entrance wait, a rappelling grunt roped down looking vanilla and reskinned after it landed.
--   * A CAP, not a fixed value: a variant that asked to mutate faster than this still does.
local VISUAL_DELAY_CAP = 1200
function SP.VisualDelay(spawnDelay)
    spawnDelay = tonumber(spawnDelay) or 0
    if spawnDelay < VISUAL_DELAY_CAP then return spawnDelay end
    return VISUAL_DELAY_CAP
end


-- [AUTHORITY] Hide a freshly-spawned actor, REVEAL it after `revealMs` (default 350). Call from
-- the summoner's onSpawned. Masks the brief full-size frame (and any pre-mutation montage) of a
-- variant that shrinks or reskins - the tiny Shardlings would otherwise flash in at assassin size.
--   * No offscreen relocate: NPCs at 0,0,0 fall through the void, distance-despawn, lose navmesh.
--   * bHidden REPLICATES (marked dirty) and covers the whole actor, so every machine sees the
--     same phase-in. The reveal is guarded - the actor can die first.
function SP.SpawnHidden(actor, revealMs)
    if Utils.IsActorInvalid(actor) then return end
    pcall(function()
        actor:SetActorHiddenInGame(true)
        Utils.MarkReplicatedDirty(actor, "bHidden")
    end)
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) then return end
        pcall(function()
            actor:SetActorHiddenInGame(false)
            Utils.MarkReplicatedDirty(actor, "bHidden")
        end)
    end, revealMs or 350)
end


-- =======================================================================
-- SPAWNERS - NPCs, clouds, deployables, bait. All two-step (see the header).
-- =======================================================================

-- Spawn a variant's base NPC near `loc`, then mutate it - the "summon" path (e.g. the Big Bot
-- calling reinforcements). opts is forwarded to MutateActor; onSpawned (opt) gets the mutated npc.
--   * A name that is not a registered variant but IS an ENUMS.NpcClasses row spawns that row
--     VANILLA (Rotation / SkipSpawnFX / onSpawned still honoured). Summon rosters mix the two
--     freely, and a caller that forgot to branch used to get a silent nothing.
-- NpcSpawner/NpcManager/Variants are required LAZILY to dodge a load-time cycle
-- (Variants -> <variant file> -> AVUtils -> NpcManager -> Variants); all loaded by call time.
function SP.SummonVariant(variantName, loc, opts, onSpawned)
    opts = opts or {}
    local def = require("AnteVariants.Variants")[variantName]
    if not def then
        if ENUMS.NpcClasses[variantName] then
            require("AnteCore.NpcSpawner").SpawnNpc(variantName, loc, {
                Rotation = opts.Rotation,
                SkipSpawnFX = opts.SkipSpawnFX,
                callback = function(npc) if onSpawned then pcall(onSpawned, npc) end end,
            })
        else
            LogBad("SummonVariant - '" .. tostring(variantName) .. "' is neither a variant nor an NPC row")
        end
        return
    end

    -- def.SkipSpawnFX: a variant whose arrival should never be an arrival - it is simply THERE
    -- when you turn around (the Leyaks). Per-spawn opts still win either way.
    local skipFX = opts.SkipSpawnFX
    if skipFX == nil then skipFX = def.SkipSpawnFX end

    -- def.RopeSpawn / opts.RopeSpawn: force the rope-rappel spawn-in on a class that ships it
    -- disabled (the OrderGrunt Troopers). NpcSpawner sets the two gates pre-FinishSpawningActor
    -- (BeginPlay reads them once). SkipSpawnFX wins if a caller asked for both, and a rope spawn
    -- inherits the long OnReady delay - a body 5m up a rope is the wrong place to read a position
    -- from. Its appearance still mutates on the short gate (SP.VisualDelay).
    local ropeSpawn = opts.RopeSpawn
    if ropeSpawn == nil then ropeSpawn = def.RopeSpawn end
    if skipFX then ropeSpawn = nil end
    if ropeSpawn and opts.SpawnDelay == nil then opts.SpawnDelay = LONG_SPAWN_DELAY end

    -- def.ForceSpawnFX / opts.ForceSpawnFX: the SAME lever for a class whose spawn-in is NOT the
    -- rope - the Gatekeeper portal burst (Gatekeeper_Grunt/Chieftain ship it off; their Witch and
    -- Heavy siblings don't). Short (SpawnFXDuration 1) and montage-less, so it keeps the default
    -- mutate delay rather than the rope's 2.7s. SkipSpawnFX still wins over both.
    local forceFX = opts.ForceSpawnFX
    if forceFX == nil then forceFX = def.ForceSpawnFX end
    if skipFX then forceFX = nil end

    require("AnteCore.NpcSpawner").SpawnNpc(def.Base or variantName, loc, {
        Rotation = opts.Rotation,   -- optional FRotator; controls the spawn facing
        RopeSpawn = ropeSpawn,
        ForceSpawnFX = forceFX,

        -- Suppress the native spawn-in (FX + montage). Forwarded to the SPAWNER, not set in the
        -- callback: NpcSpawner writes it pre-FinishSpawningActor so the FX never starts, whereas
        -- setting it after can only cut it short. For a summon that should read as a continuation
        -- rather than an arrival - the Jotun's rider stepping off its dying steed.
        SkipSpawnFX = skipFX,

        -- Opt OUT of the spawner's Large/Huge-body floor lift (NpcSpawner BIG_BODY_LIFT) for a
        -- summon placed on an exact mark rather than on the ground - a seat, a socket, a set piece.
        NoLift = opts.NoLift,

        callback = function(npc)
            require("AnteVariants.NpcManager").MutateActor(variantName, npc, opts)
            if onSpawned then pcall(onSpawned, npc) end
        end,
    })
end


-- Summon one body at `loc` (variant name or raw DT_NPCList row - SummonVariant dispatches) and
-- lock it onto `target`: the "reinforcement with a purpose" beat (the Big Bots' Summon). The lock
-- is the one-shot kind unless opts.HoldMs opts into a held one; DelayMs (500) covers the fresh
-- body's controller not being up yet, and a gone target just skips the lock.
-- opts: DelayMs, HoldMs, Opts (forwarded to MutateActor), OnSpawned(npc).
function SP.SummonAndLock(name, loc, target, opts)
    opts = opts or {}
    local AVU = require("AnteUtils.AVUtils")   -- LAZY: AVUtils requires this file at load
    SP.SummonVariant(name, loc, opts.Opts or {}, function(npc)
        if Utils.IsActorValid(target) then
            AVU.LockAggro(npc, target, { DelayMs = opts.DelayMs or 500, HoldMs = opts.HoldMs })
        end
        if opts.OnSpawned then pcall(opts.OnSpawned, npc) end
    end)
end


-- =======================================================================
-- SpawnReinforcements - "something calls for help": pick a spot near a point, subject to a
-- line-of-sight rule, and put N NPCs on it locked onto a target.
--
-- Every summoner in the mod was rebuilding this by hand (Commander, Signifer, Big Bot, the signal
-- pests) and each hand-rolled copy differed in the parts that matter: whether the spot was
-- validated, whether the lock survived the controller not being up yet, and how much of the search
-- landed in ONE frame.
--
-- THREE THINGS IT DOES THAT A HAND-ROLLED LOOP GETS WRONG:
--   1. THE SEARCH IS SPREAD, ONE CANDIDATE PER PASS. A candidate costs a nav query plus (when a
--      sight rule is set) a ~10ms line trace. Four candidates in one drain item is a ~50ms hitch;
--      four candidates 120ms apart is invisible. "Best effort" means it may simply find nothing -
--      that is a normal outcome here, not a failure to log loudly.
--   2. ONE ANCHOR, N BODIES. Count > 1 fuzzes around a single validated point rather than running
--      N independent searches - a pack that arrives together reads better AND costs 1/N the
--      queries. Scatter is that fuzz radius.
--   3. THE LOCK IS A ONE-SHOT BY DESIGN. A bare AVU.LockAggro lapses the moment the NPC lands a
--      hit (every attack task clears TargetLocked), which is exactly right for "it came for YOU,
--      then it fights normally". Pass HoldMs only for a lock that must survive the whole fight.
--
-- opts:
--   Npcs        (required) name or ARRAY of names, rolled per body. A VARIANT name spawns +
--               mutates; anything else is used as a raw ENUMS.NpcClasses row.
--   Origin      (required) FVector the ring is measured from - usually the TARGET, not the caller.
--   Count       how many bodies (1) - Scatter (250) apart around one anchor.
--   MinDist / MaxDist   the ring (1500 / 3000). A loose rule: the nav fallback can land closer,
--               and a body that arrives slightly near beats no body at all.
--   OutOfSight  an actor that must NOT be able to see the anchor (the stalker rule).
--   InLoS       an actor that MUST see it. Set at most one of the two; neither = no sight rule
--               and NO trace cost at all.
--   Retries     candidate points to try, one per SpreadMs (4 / 120ms).
--   Reject(pt)  a predicate that vetoes a candidate point (true = skip it). Runs before the sight
--               trace, so a cheap veto costs nothing (a "not inside a base footprint" test).
--   OnFail()    called once every candidate was rejected - the "best effort found nothing" outcome,
--               for a caller that must release a slot it claimed.
--   SkipSpawnFX suppress the native spawn-in on every body of the wave (raw rows included), for
--               reinforcements that are meant to already be there rather than to arrive. Left
--               unset, each variant's own def decides.
--   Target      lock every spawned body onto this actor - HoldMs / LockDelayMs (500) tune it.
--   Opts        forwarded to MutateActor (SpawnDelay, Faction, ...).
--   Track       a table this writes `Track[Utils.ActorKey(npc)] = npc` into. STRING-keyed, so it
--               is a PLAIN table and the caller prunes it (a summon registry, a cap check).
--   Orphan      DEFAULT TRUE - every body self-cleans once no player is within OrphanRange
--               (15000). Don't switch it off casually: a script-spawned NPC is in no spawner
--               group, so the game never unloads it, and a repeatable caller leaks a body per
--               firing. Pass `Orphan = false` only when the caller owns the lifetime itself
--               (an AVU.WatchSummonLifetime tie, or a registry it prunes and destroys).
--   OnSpawned(npc), Label (log prefix).
-- =======================================================================

local REINF_POINT_RETRIES = 6     -- nav attempts INSIDE one candidate (GetSpawnPoint's own loop)
local REINF_EYE_Z         = 70    -- watcher eye height above its root, for the sight trace
local REINF_BODY_Z        = 60    -- the height on the candidate a watcher would actually see
-- MinDist is a SOFT rule (the banner says so): GetSpawnPoint's ring query can fall back to a
-- projection or a plain fuzz, and a body that arrives a bit close beats no body at all. This is
-- the floor under that slack, as a fraction of MinDist SQUARED - 0.5 is ~0.71x the asked distance.
local REINF_NEAR_SLACK    = 0.5

function SP.SpawnReinforcements(opts)
    if not Utils.IsAuthority() then return end
    opts = opts or {}
    local roster = opts.Npcs
    if not opts.Origin or not roster then return end
    -- COPIED, not held: the search runs across several WorkQueue passes and the caller's vector is
    -- usually something it read off a live actor a moment ago.
    local origin = FVector(opts.Origin.X, opts.Origin.Y, opts.Origin.Z)
    if type(roster) ~= "table" then roster = { roster } end
    if #roster == 0 then return end

    local AVU     = require("AnteUtils.AVUtils")   -- LAZY: AVUtils requires this file at load
    local VARIANTS = require("AnteVariants.Variants")

    local label   = opts.Label or "SpawnReinforcements"
    local count   = opts.Count or 1
    local minD    = opts.MinDist or 1500
    local maxD    = opts.MaxDist or 3000
    -- At most one sight rule; InLoS wins if a caller sets both. nil watcher = no rule and, more to
    -- the point, NO TRACE COST - the expensive half of a candidate is entirely opt-in.
    local wantSeen = opts.InLoS ~= nil
    -- The watcher and the lock target are read passes and an async spawn later, so they cross through
    -- Utils.CarryActor (a target can be an unstamped prop the AI is breaking through).
    local getWatcher = Utils.CarryActor(wantSeen and opts.InLoS or opts.OutOfSight)
    local getTarget  = Utils.CarryActor(opts.Target)

    -- One body: spawn the variant (or the raw row) and wire up the lock / tracking / callback.
    local function place(at)
        local function onSpawned(npc)
            if Utils.IsActorInvalid(npc) then return end
            if opts.Track then
                local key = Utils.ActorKey(npc)
                if key then opts.Track[key] = npc end
            end
            -- DelayMs, always: a body this fresh has no controller yet, so an immediate lock is a
            -- silent no-op. HoldMs absent = the one-shot lock (see the banner).
            local target = getTarget()
            if target then
                AVU.LockAggro(npc, target,
                    { DelayMs = opts.LockDelayMs or 500, HoldMs = opts.HoldMs })
            end
            -- The game will never unload this body on its own (see the Orphan note).
            if opts.Orphan ~= false then
                AVU.SelfCleanWhenAlone(npc, { OrphanRange = opts.OrphanRange, Label = label })
            end
            if opts.OnSpawned then pcall(opts.OnSpawned, npc) end
        end

        if VARIANTS[at.Name] then
            -- A FRESH copy per body: SummonVariant writes back into the table it is handed
            -- (SpawnDelay, for a rope spawn), and the caller's Opts is shared across the wave.
            local o = {}
            for k, v in pairs(opts.Opts or {}) do o[k] = v end
            if o.SkipSpawnFX == nil then o.SkipSpawnFX = opts.SkipSpawnFX end
            SP.SummonVariant(at.Name, at.Loc, o, onSpawned)
        else
            -- Not a variant: a raw ENUMS.NpcClasses row, spawned vanilla.
            require("AnteCore.NpcSpawner").SpawnNpc(at.Name, at.Loc,
                { SkipSpawnFX = opts.SkipSpawnFX, callback = onSpawned })
        end
    end

    -- The anchor found: fan the bodies out around it, one per SpawnGapMs so a wave never lands as
    -- one frame of spawns.
    local function spawnWave(anchor)
        for i = 1, count do
            local loc = (i == 1) and anchor or Utils.FuzzLocation(anchor, opts.Scatter or 250)
            local name = roster[math.random(1, #roster)]
            Utils.QueueWork(function()
                place({ Name = name, Loc = loc })
            end, (i - 1) * (opts.SpawnGapMs or 150))
        end
        LogDebug(label .. " - " .. count .. " inbound", SETTINGS.DEBUG_NPC_ACTIONS)
    end

    -- ONE candidate. Returns true when it took the spot; the caller re-queues otherwise.
    local function tryPoint()
        local pt = Utils.GetSpawnPoint(origin, maxD, minD, REINF_POINT_RETRIES)
        if not pt then return false end
        -- The nav fallback can land on top of us; that is the one distance failure worth rejecting.
        if Utils.DistSq(pt, origin) < (minD * minD) * REINF_NEAR_SLACK then return false end
        if opts.Reject and opts.Reject(pt) then return false end

        local watcher = getWatcher()
        if watcher then
            local w = watcher:K2_GetActorLocation()
            if not w then return false end
            local blocked = AVU.IsPathBlocked(watcher,
                FVector(w.X, w.Y, w.Z + REINF_EYE_Z),
                FVector(pt.X, pt.Y, pt.Z + REINF_BODY_Z),
                { watcher }) and true or false
            -- IsPathBlocked fails OPEN (false on a trace error). For InLoS that reads as "visible",
            -- which is the harmless direction; for OutOfSight it would place the body in plain view,
            -- so that branch spends its retries rather than accepting an unproven spot.
            if wantSeen == blocked then return false end
        end

        spawnWave(pt)
        return true
    end

    local left = opts.Retries or 4
    local function attempt()
        if not STATE.ModEnabled then return end
        if tryPoint() then return end
        left = left - 1
        if left <= 0 then
            LogDebug(label .. " - no usable spot, giving up", SETTINGS.DEBUG_NPC_ACTIONS)
            if opts.OnFail then pcall(opts.OnFail) end
            return
        end
        Utils.QueueWork(attempt, opts.SpreadMs or 120)
    end
    Utils.QueueWork(attempt, 0)
end


-- [AUTHORITY] Spawn a lingering AreaEffect "cloud" (a real replicated actor) at `location`.
-- opts: Duration (EffectDuration s), NoDamage (zero DamagePerTick), Preload (extra paths - e.g.
-- its Niagara - so BeginPlay can't blocking-load), DelayMs, Owner, OnSpawned.
function SP.SpawnCloud(location, classPath, opts)
    opts = opts or {}
    if not location or not classPath then return end

    local toLoad = { classPath }
    for _, p in ipairs(opts.Preload or {}) do toLoad[#toLoad + 1] = p end

    ASSETS.LoadAsync(toLoad, function(results)
        local cls = results[classPath]
        if IsNotValid(cls) then LogBad("SpawnCloud - class not loaded: " .. tostring(classPath)); return end

        local function doSpawn()
            -- S3 - re-resolve, never spawn the captured wrapper (deliberately shadows `cls`
            -- above). A UClass with no live instances is collectible; a Lua wrapper doesn't root
            -- it, so a later cold-load can GC it and IsValid lies on the reused slot
            -- ([[anteup2-stale-class-spawn-av]]: AV @0x28 in FBoneContainer::Initialize). Worst
            -- site for this: opts.DelayMs here is caller-chosen and unbounded, unlike other
            -- spawners which only risk a frame.
            local cls = ASSETS.GetIfValid(classPath)
            if IsNotValid(cls) then
                LogBad("SpawnCloud - class collected before spawn: " .. tostring(classPath))
                return
            end

            local gs = UEHelpers.GetGameplayStatics()
            local km = UEHelpers.GetKismetMathLibrary()
            local world = Utils.GetWorld()
            if not gs or not km or IsNotValid(world) then return end

            local xform = km:MakeTransform(location, FRotator(), FVector(1, 1, 1))
            local ok, err = pcall(function()
                local ae = gs:BeginDeferredActorSpawnFromClass(world, cls, xform, 0, nil, 0)
                if IsNotValid(ae) then return end
                ae.nosave = true
                if opts.Duration then pcall(function() ae.EffectDuration = opts.Duration end) end
                if opts.NoDamage then pcall(function() ae.DamagePerTick = 0 end) end
                ae = gs:FinishSpawningActor(ae, xform, 0)
                if Utils.IsActorValid(ae) and opts.OnSpawned then pcall(opts.OnSpawned, ae) end
                -- opts.Owner: destroy the cloud the moment its owner DIES. AreaEffect damage runs
                -- on an FTimerManager tick, and with a freed instigator that tick ProcessDamages a
                -- stale pointer -> AV (the LabBreach mass-combat crash, same family as the
                -- level-exit AreaEffect teardown). Orphan-subactor-style watcher.
                if Utils.IsActorValid(ae) and opts.Owner then
                    local cloud, owner = ae, opts.Owner
                    local function watch()
                        if Utils.IsActorInvalid(cloud) then return end   -- expired naturally
                        local dead = true
                        pcall(function() dead = Utils.IsActorInvalid(owner) or owner.IsDead end)
                        if dead then
                            pcall(function() cloud:K2_DestroyActor() end)
                            return
                        end
                        Utils.QueueWork(watch, 500)
                    end
                    Utils.QueueWork(watch, 500)
                end
            end)
            if not ok then LogBad("SpawnCloud failed: " .. tostring(err)) end
        end

        Utils.QueueWork(function()
            if STATE.Role == "DEDICATED" then ExecuteInGameThread(doSpawn) else doSpawn() end
        end, opts.DelayMs or 0)
    end)
end


-- [AUTHORITY] Spawn a free-standing deployable (e.g. a barricade) at `location`.
-- opts: Faction, Durability, Scale, CollisionHandling (0=AlwaysSpawn,1=AdjustIfPossible),
-- Preload, DelayMs, OnSpawned, PaintColor (EPaintColor int), PaintPreload.
--
-- PAINT HAZARD: SetPaintColor -> SetupPaintAndTexture -> LoadAsset_BLOCKING on that color's
-- FPaintedDeployable.Materials_<Color>. Nested in this in-hook spawn drain, a non-resident color
-- FREEZES or re-enters ProcessEvent and AV-crashes the host (the Commander/Artillery bunkers, which
-- only survived by luck when the color happened to be warm). So we paint ONLY when the caller
-- guarantees warmth via opts.PaintPreload (their /Game material paths, batched into the async
-- preload here); without it we SKIP the paint. Materials live in DT_PaintedDeployables.
function SP.SpawnDeployable(classPath, location, rotation, opts)
    opts = opts or {}
    if not classPath or not location then return end

    local toLoad = { classPath }
    for _, p in ipairs(opts.Preload or {}) do toLoad[#toLoad + 1] = p end
    for _, p in ipairs(opts.PaintPreload or {}) do toLoad[#toLoad + 1] = p end

    ASSETS.LoadAsync(toLoad, function(results)
        local cls = results[classPath]
        if IsNotValid(cls) then LogBad("SpawnDeployable - class not loaded: " .. tostring(classPath)); return end

        local function doSpawn()
            -- S3 - re-resolve, shadowing the captured `cls`. Same reasoning and same crash as
            -- SpawnCloud above / NpcSpawner ([[anteup2-stale-class-spawn-av]]).
            local cls = ASSETS.GetIfValid(classPath)
            if IsNotValid(cls) then
                LogBad("SpawnDeployable - class collected before spawn: " .. tostring(classPath))
                return
            end

            local gs = UEHelpers.GetGameplayStatics()
            local km = UEHelpers.GetKismetMathLibrary()
            local world = Utils.GetWorld()
            if not gs or not km or IsNotValid(world) then return end

            local ch = opts.CollisionHandling or 0
            local xform = km:MakeTransform(location, rotation or FRotator(), opts.Scale or FVector(1, 1, 1))
            local ok, err = pcall(function()
                local d = gs:BeginDeferredActorSpawnFromClass(world, cls, xform, ch, nil, 0)
                if IsNotValid(d) then return end
                d.nosave = true
                if opts.Faction then pcall(function() d.Faction = opts.Faction end) end
                if opts.Durability then
                    pcall(function() d.MaxDurability = opts.Durability end)
                    pcall(function() d.CurrentDurability = opts.Durability end)
                end
                -- PaintColor = EPaintColor enum (property `PaintedColor`); set pre-finish so
                -- construction picks the painted materials. GATED on PaintPreload (see header) -
                -- an unpreloaded color blocking-loads in-hook -> freeze/AV crash.
                local canPaint = opts.PaintColor and opts.PaintPreload and #opts.PaintPreload > 0
                if canPaint then pcall(function() d.PaintedColor = opts.PaintColor end) end
                d = gs:FinishSpawningActor(d, xform, ch)
                if Utils.IsActorValid(d) then
                    pcall(function() d.nosave = true end)
                    -- Re-apply via the setter too (marks dirty + OnRep_PaintedColor ->
                    -- swaps to the painted materials on host & clients). Cache hit (preloaded).
                    if canPaint then pcall(function() d:SetPaintColor(opts.PaintColor, true) end) end
                    if opts.OnSpawned then pcall(opts.OnSpawned, d) end
                end
                if opts.PaintColor and not canPaint then
                    Utils.LogDebug("SpawnDeployable - PaintColor " .. tostring(opts.PaintColor)
                        .. " SKIPPED (no PaintPreload; would blocking-load in-hook)", true)
                end
            end)
            if not ok then LogBad("SpawnDeployable failed: " .. tostring(err)) end
        end

        Utils.QueueWork(function()
            if STATE.Role == "DEDICATED" then ExecuteInGameThread(doSpawn) else doSpawn() end
        end, opts.DelayMs or 0)
    end)
end


-- An invisible actor NPCs can be aggroed / move-ordered onto when we only have a LOCATION
-- (AttackMove) - NPCs need an ACTOR to path to.
--   * POOLED and NEVER destroyed. The bait class (an Item Stand) async-loads its display mesh via
--     UE's LATENT LoadAsset, and destroying it mid-load is a use-after-free: the load can land
--     SECONDS later and FLoadAssetAction::OnLoaded derefs the freed actor -> AV. Our odd spawn
--     (SetReplicates pre-init) can also skip UE's cancel-latent-actions-on-EndPlay. One bait per
--     world, RELOCATED, always completes live.
--   * Behaviour is unchanged: ForceAggro captures the move goal BY VALUE
--     (BT_SetLastKnownLocation), so moving the bait never disturbs a committed group.
--   * STATE.AggroBait drops on world teardown (Utils.ResetState) and every use re-validates, so a
--     GC / world change just re-spawns one.
local AGGRO_BAIT_CLASS = ENUMS.DeployedObjs.ITEM_STAND
local aggroBaitPending = false   -- a spawn is in flight
local aggroBaitWaiters = {}      -- callers that arrived mid-spawn; all share the one bait

function SP.SpawnAggroBait(loc, onReady)
    if not Utils.IsAuthority() or not loc then return end

    -- Live pooled bait: relocate + hand back. No spawn, no load, no destroy.
    if Utils.IsActorValid(STATE.AggroBait) then
        pcall(function() STATE.AggroBait:K2_SetActorLocation(loc, false, {}, true) end)
        if onReady then pcall(onReady, STATE.AggroBait) end
        return
    end
    STATE.AggroBait = nil

    -- A spawn is already in flight: park this caller until it lands (they all share the one bait).
    if aggroBaitPending then
        aggroBaitWaiters[#aggroBaitWaiters + 1] = { loc = loc, onReady = onReady }
        return
    end
    aggroBaitPending = true

    ASSETS.LoadAsync({ AGGRO_BAIT_CLASS }, function(results)
        local cls = results[AGGRO_BAIT_CLASS]
        if IsNotValid(cls) then
            aggroBaitPending = false
            LogBad("SpawnAggroBait - class failed to load")
            return
        end

        local function doSpawn()
            -- S3 - re-resolve, shadowing the captured `cls` ([[anteup2-stale-class-spawn-av]]).
            -- This bail must clear aggroBaitPending like the world bail below: the flag is what
            -- makes every other caller park in aggroBaitWaiters, so returning without it wedges the
            -- shared bait for the rest of the session.
            local cls = ASSETS.GetIfValid(AGGRO_BAIT_CLASS)
            if IsNotValid(cls) then
                aggroBaitPending = false
                LogBad("SpawnAggroBait - class collected before spawn")
                return
            end

            local world = Utils.GetWorld()
            local gs = UEHelpers.GetGameplayStatics()
            local km = UEHelpers.GetKismetMathLibrary()
            if IsNotValid(world) or not gs or not km then aggroBaitPending = false; return end
            local xform = km:MakeTransform(loc, FRotator(), FVector(1, 1, 1))

            local ok, bait = pcall(function()
                local d = gs:BeginDeferredActorSpawnFromClass(world, cls, xform, 1, nil, 0)
                if IsNotValid(d) then return nil end
                pcall(function() d.nosave = true end)
                pcall(function() d.DeployedByPlayer = false end)
                d:SetReplicates(false)
                d = gs:FinishSpawningActor(d, xform, 0)
                if IsNotValid(d) then return nil end
                d:SetActorHiddenInGame(true)
                d:SetActorEnableCollision(false)
                return d
            end)
            aggroBaitPending = false
            if not ok then LogBad("SpawnAggroBait - spawn error: " .. tostring(bait)); return end
            if Utils.IsActorInvalid(bait) then return end

            STATE.AggroBait = bait
            if onReady then pcall(onReady, bait) end

            -- Release anyone who queued while the spawn was in flight: same bait, moved to each spot.
            local waiters = aggroBaitWaiters
            aggroBaitWaiters = {}
            for _, w in ipairs(waiters) do
                if Utils.IsActorValid(STATE.AggroBait) then   -- == bait; field form avoids a nil-narrow lint
                    pcall(function() STATE.AggroBait:K2_SetActorLocation(w.loc, false, {}, true) end)
                end
                if w.onReady then pcall(w.onReady, STATE.AggroBait) end
            end
        end

        -- Same role split as the spawners: EIGT on a dedicated server (off the spawn hook),
        -- QueueWork on a renderer host (EIGT mid-paint crashes there).
        if STATE.Role == "DEDICATED" then ExecuteInGameThread(doSpawn) else Utils.QueueWork(doSpawn, 0) end
    end)
end


-- Is `actor` the pooled move-order bait? The bait is a legitimate `GetCurrentCombatTarget()`, so
-- anything that aims at the TARGET'S LOCATION will happily fire at it - briefly at the player's
-- move-order anchor, then at (0,0,0) once it parks. Ask this before using a combat target as an
-- aim point; a plain move goal is fine.
-- Full names, not `==`: wrappers compare by address and a fresh one arrives per call.
function SP.IsAggroBait(actor)
    if Utils.IsActorInvalid(actor) or Utils.IsActorInvalid(STATE.AggroBait) then return false end
    local a, b
    pcall(function() a = actor:GetFullName() end)
    pcall(function() b = STATE.AggroBait:GetFullName() end)
    return a ~= nil and a == b
end


-- [AUTHORITY] Make `actors` RUN (combat speed) to a world location: spawn the invisible bait there,
-- force-target the list onto it, then ~150ms later PARK the bait at (0,0,0).
--   * The move goal is the target's location captured into the blackboard AT THE MOMENT ForceAggro
--     writes it, so the bait must physically be at `location` then. Moving it afterwards does not
--     change the goal - they walk to the spot and stop.
--   * We PARK rather than destroy so the target stays VALID (an invalid one resets the BT to idle),
--     and park it FAR so they stop treating it as a nearby live target (ranged NPCs were stopping
--     short / lobbing grenades). Re-aggro is deliberately not done - it would rewrite the goal.
--   * The bait is POOLED and never destroyed; onReady(bait) is for the rare caller needing the ref.
--     Do NOT K2_DestroyActor it - that reintroduces the async-load use-after-free.
local AGGRO_PARK_MS = 150
function SP.AttackMove(actors, location, onReady)
    if not Utils.IsAuthority() then return end
    local AVU = require("AnteUtils.AVUtils")   -- lazy: AVUtils requires US (merge loop)
    SP.SpawnAggroBait(location, function(bait)
        for _, npc in ipairs(actors or {}) do AVU.ForceAggro(npc, bait) end
        -- park it far away once the goal is written (keep it valid, just not nearby)
        Utils.QueueWork(function()
            if Utils.IsActorValid(bait) then
                pcall(function() bait:K2_SetActorLocation(FVector(0, 0, 0), false, {}, true) end)
            end
        end, AGGRO_PARK_MS)
        if onReady then pcall(onReady, bait) end
    end)
end


-- Force the global weather event (e.g. "Fog", or "None" to end it) through AFUtils2, which builds
-- the build's row handle and calls DayNightManager:TriggerWeatherEvent. Changes the WHOLE level's
-- weather.
--   * TriggerWeatherEvent BLOCKING-LOADS the weather FX, so nested in a hook it deadlocks (froze
--     SP on Orchestrator spawn). ExecuteInGameThread is the only true escape - QueueWork still
--     drains inside ProcessTick. A hand-rolled `CurrentWeatherEvent = FName + OnRep` hung the same
--     way (OnRep loads the FX) and didn't build a valid event either.
--   * Caller: RevengeEvents (a revenge's weather).
function SP.ForceWeather(eventName)
    ExecuteInGameThread(function()
        pcall(function() AF2.TriggerWeatherEvent(eventName) end)
    end)
end


-- =======================================================================
-- FROST SHELLS - the Snowman's frost artillery, given a visible body + impact FX and a debuff the
-- projectile itself can't carry (see FreezeSecs below for why).
-- Full decode / cost investigation: AnNotes/AnteSystems/Spawning.md.
--
-- SP.FrostShells(actor, opts) - AUTHORITY. opts:
--   Count       - shells (default 1). ONE shell aims AT the target; MORE march outward.
--   StartDist   - uu to the first impact of a marching barrage (default 500). Well outside the
--                 shell's own 350uu outer AoE so the opening impact can't catch the firer.
--   Step        - uu between impacts (default 300, the native DistanceBetweenProjectiles)
--   Damage      - per shell
--   ArcDeg      - lob angle (default 45)
--   Ticks       - FAST_TICKs between shells (default 2 = 0.2s; the native rate is 0.1s)
--   Socket      - muzzle socket name on the mesh; falls back to the body + ZLift
--   ZLift       - fallback muzzle height (default 120)
--   MaxRange    - clamp for the single-shell aim, so a long-range thrower doesn't lob into orbit
--   FreezeSecs  - Debuff_Frost on PLAYERS caught at each impact point (0/nil = none).
--   FreezeRadius- radius of that burst (default 350, the row's own AoE outer)
--
-- FreezeSecs is not a nicety - the shell can't freeze on its own. The row's own async load
-- always clobbers our arm-time DamageTypeClass, so we apply the freeze debuff ourselves at the
-- impact point, timed to the shell's flight (see AnNotes/AnteSystems/Spawning.md).
-- =======================================================================

local FROST_SHELL_CLASS  = ENUMS.ProjectileClasses.SnowmanFrostSpray
local FROST_SHELL_MESH   = ENUMS.Components.SM_SNOWBALL
local FROST_SHELL_IMPACT = ENUMS.Effects.NIAGARA_SNOWBALL_EXPLODE
local FROST_SHELL_TYPE   = ENUMS.DamageType.ColdFreeze
local FROST_SHELL_SPEED_CAP = 3000

-- Everything the shell touches. PUBLIC so a variant can put the same list in def.Assets.
-- The projectile CLASS is deliberately ABSENT - PROJ.Queue loads it itself; listing it here too
-- would scan it twice per shell.
SP.FROST_SHELL_DEPS = {
    FROST_SHELL_MESH,
    FROST_SHELL_TYPE,
    FROST_SHELL_IMPACT,
}

-- Pinned separately from FROST_SHELL_DEPS because the class entries pin via ChildActorClass
-- (CLASS pin kind), not a component UPROPERTY - PinPaths runs once at mutation, so this is not
-- the double-load the Preload note above bans; it just turns PROJ.Queue's own per-shell class
-- resolve into a trusted table hit instead of a UObject-array scan.
local FROST_SHELL_PINNABLE = { FROST_SHELL_MESH, FROST_SHELL_IMPACT,
    FROST_SHELL_TYPE, FROST_SHELL_CLASS }

-- [AUTHORITY] Call once at mutation (def.Stats) so the wave's assets are resident and pinned
-- before the first shot instead of cold-loading on it. Safe to call per actor - PinPaths dedupes.
function SP.WarmFrostShells()
    ASSETS.WarmPinned(SP.FROST_SHELL_DEPS)
    require("AnteCore.AssetKeeper").PinPaths(FROST_SHELL_PINNABLE)
end

-- =======================================================================
-- FROST CONE - the Snowman's frost breath, and the CHEAP way to do a cold sweep: replaces a
-- multi-shell FrostShells wave (~270ms/wave floor, mostly unpinnable per-shell class scans) with
-- one client-FX push + one AVU.BlastDamage per beat (~5x fewer lookups, no actor spawns), and
-- sidesteps the same projectile-DamageType-clobber problem since BlastDamage applies the freeze
-- debuff directly. The visual is a real cone (Snowman's own Niagara, yaw-aimed); the damage is a
-- staggered line of overlapping spheres marching along it. Full cost breakdown and the two failed
-- attempts to reuse Niagara_Snowman_FrostSpray directly: AnNotes/AnteSystems/Spawning.md.
--
-- SP.FrostCone(actor, opts) - AUTHORITY. opts:
--   Reach       - uu the cone covers (default 1600)
--   Beats       - damage steps along it (default 3). THE COST KNOB - one DamageType lookup each.
--   Radius      - damage sphere per beat (default 350; overlap them or the sweep has gaps)
--   Damage      - per beat. A target standing in the lane can eat more than one.
--   StepMs      - gap between beats (default 180)
--   Seconds     - how long the visual lives (default 2)
--   FreezeSecs  - Debuff_Frost duration on caught PLAYERS (default 4; 0 = no freeze)
--   Socket      - muzzle socket for the origin; falls back to the body + ZLift
--   ZLift       - fallback muzzle height (default 120)
--   WindupMs    - telegraph before the first beat (default 900). See TELEGRAPH.
--   HitNpcs     - also damage NPCs (default false; see CLAUDE.md S6 before turning this on)
-- =======================================================================

local CONE_BEAT_FX   = ENUMS.Effects.NIAGARA_SNOWBALL_EXPLODE
local CONE_WINDUP_FX = ENUMS.Effects.NIAGARA_SLUSHIE

SP.FROST_CONE_DEPS = { CONE_BEAT_FX, CONE_WINDUP_FX, ENUMS.DamageType.Cold }

-- [AUTHORITY] Warm + pin the cone's full set, DamageType_Cold included. The pin turns BlastDamage's
-- per-beat GetIfValid and PointDamageOffHook's in-EIGT re-resolve into trusted table hits instead
-- of a UObject-array scan - those scans were most of a recurring ~70ms hitch on every player hit.
function SP.WarmFrostCone()
    ASSETS.WarmPinned(SP.FROST_CONE_DEPS)
    require("AnteCore.AssetKeeper").PinPaths(SP.FROST_CONE_DEPS)
end

function SP.FrostCone(actor, opts)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end
    opts = opts or {}

    -- Lazy require: AVUtils merges this file onto AVU, so a top-level require here deadlocks the
    -- loader (the AnteUtils rule in CLAUDE.md S1).
    local AVU = require("AnteUtils.AVUtils")

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end

    local reach  = opts.Reach or 1600
    local beats  = opts.Beats or 3
    local radius = opts.Radius or 350
    local stepMs = opts.StepMs or 180

    -- Named socket if the caller has one, else above the body.
    local origin
    if opts.Socket then
        local mesh = Utils.GetValidMesh(actor)
        if mesh then
            local ok, loc = pcall(function() return mesh:GetSocketLocation(FName(opts.Socket)) end)
            if ok and loc then origin = loc end
        end
    end
    if not origin then
        local l = actor:K2_GetActorLocation()
        origin = FVector(l.X, l.Y, l.Z + (opts.ZLift or 120))
    end

    local to = target:K2_GetActorLocation()
    local dx, dy = (to.X or 0) - (origin.X or 0), (to.Y or 0) - (origin.Y or 0)
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1 then return end
    local ux, uy = dx / len, dy / len

    -- TELEGRAPH.
    local windup = opts.WindupMs or 900
    FX.BroadcastFX(origin, CONE_WINDUP_FX, nil, FVector(1.4, 1.4, 1.4))

    -- Beats march outward. Each is deferred, so a beat that KILLS runs its death cascade on its
    -- own drain rather than all of them landing in one frame.
    --   * The aim is SNAPSHOTTED HERE, at windup start, and never re-read. That is what makes the
    --     telegraph mean anything: the cone lands where you WERE when it began, so moving off the
    --     line beats it. Re-aiming at fire time would make the windup pure decoration.
    for i = 1, beats do
        local reachAt = reach * (i / beats)
        -- Beats sit at the TARGET's height, not the muzzle's - a cone fired downhill otherwise
        -- sprays damage through the air above the victim.
        local point = FVector(origin.X + ux * reachAt, origin.Y + uy * reachAt, to.Z or origin.Z)

        Utils.QueueWork(function()
            if Utils.IsActorInvalid(actor) or actor.IsDead then return end

            -- The cone's visible body: one burst per beat, so the sweep is drawn by the same
            -- march that deals the damage and you can see exactly where it has reached.
            FX.BroadcastFX(point, CONE_BEAT_FX, nil, FVector(0.8, 0.8, 0.8))

            AVU.BlastDamage(actor, point, {
                Radius = radius,
                Damage = opts.Damage or 30,
                DamageType = ENUMS.DamageType.Cold,
                HitNpcs = opts.HitNpcs or false,
                -- The freeze the projectile version could never land (see the header). PLAYERS
                -- only - an NPC->player debuff needs the direct Server_ApplyBuff path, which is
                -- what BlastDamage's Debuff option uses.
                Debuff = (opts.FreezeSecs ~= 0) and ENUMS.Debuffs.Frost or nil,
                DebuffSeconds = opts.FreezeSecs or 1,
            })
        end, windup + stepMs * (i - 1))
    end

    LogDebug("FrostCone - " .. beats .. " beats over " .. reach .. "uu", SETTINGS.DEBUG_NPC_ACTIONS)
end


function SP.FrostShells(actor, opts)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end
    opts = opts or {}

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end

    local count   = opts.Count or 1
    local step    = opts.Step or 300
    local arcDeg  = opts.ArcDeg or 45
    local start   = opts.StartDist or 500

    -- Muzzle: the named socket if the caller has one, else above the body.
    local origin
    if opts.Socket then
        local mesh = Utils.GetValidMesh(actor)
        if mesh then
            local ok, loc = pcall(function() return mesh:GetSocketLocation(FName(opts.Socket)) end)
            if ok and loc then origin = loc end
        end
    end
    if not origin then
        local l = actor:K2_GetActorLocation()
        origin = FVector(l.X, l.Y, l.Z + (opts.ZLift or 120))
    end

    local from = actor:K2_GetActorLocation()
    local to   = target:K2_GetActorLocation()
    local dx, dy = (to.X or 0) - (from.X or 0), (to.Y or 0) - (from.Y or 0)
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1 then return end
    local ux, uy = dx / len, dy / len

    -- ONE warm for the whole wave, so the per-shell batch is only the class + the mesh (header,
    -- fix 1). Fire-and-forget: the shells are 0.2s apart, so even a cold set is resident long
    -- before the first one spawns, and a warm set makes this three cache-checks.
    ASSETS.WarmPinned(SP.FROST_SHELL_DEPS)

    for i = 0, count - 1 do
        -- ONE shell goes at the target; a barrage walks outward from StartDist.
        local reach
        if count == 1 then
            reach = opts.MaxRange and math.min(len, opts.MaxRange) or len
        else
            reach = start + step * i
        end

        -- Impacts sit at the TARGET's height, not ours - a wave walked up a slope otherwise arcs
        -- into the hillside on shell 2.
        local aim = FVector(from.X + ux * reach, from.Y + uy * reach, to.Z or from.Z)
        local speed = AVM.ArcSpeed(origin, aim, arcDeg, 1)

        -- The freeze the shell itself can never carry (see the header). Timed to the shell's own
        -- flight: for a fixed-angle lob, t = 2 * v * sin(theta) / g.
        if (opts.FreezeSecs or 0) > 0 then
            local flightMs = math.floor(
                (2 * speed * math.sin(math.rad(arcDeg)) / -ENUMS.Tuning.WORLD_GRAVITY_Z) * 1000 + 0.5)
            local burstAt = aim
            Utils.QueueWork(function()
                if Utils.IsActorInvalid(actor) then return end
                require("AnteUtils.AVUtils").BuffPlayersInRadius(
                    burstAt, opts.FreezeRadius or 350,
                    { { Buff = ENUMS.Debuffs.Frost, Secs = opts.FreezeSecs } })
            end, math.max(100, math.min(4000, flightMs)))
        end

        PROJ.Queue(origin, AVM.ArcDir(origin, aim, arcDeg), FROST_SHELL_CLASS, FROST_SHELL_MESH, {
            Owner = actor,
            Instigator = actor,        -- AoE row: damage credit + the gate that stops self-detonation
            Damage = opts.Damage or 35,
            Velocity = speed,
            MaxSpeed = FROST_SHELL_SPEED_CAP,   -- the row's own cap is 1500; see the header
            GravityScale = 1,          -- applied to the LIVE movement -> a real arc
            LifeSpan = 6,              -- long enough for the farthest shell's arc
            IgnoreOwnerDuration = 2,
            SerializeTicks = opts.Ticks or 2,
            -- PROJ.Queue's serialize slots are GLOBAL across every NPC's shots and it DROPS any
            -- shot that can't fire in time, so the cap has to clear this whole wave.
            MaxBacklogMs = 1000 + count * (opts.Ticks or 2) * 100,
            DamageTypeClass = FROST_SHELL_TYPE,
            OnSpawned = function(proj)
                local fx = ASSETS.GetIfValid(FROST_SHELL_IMPACT)
                if IsValid(fx) then pcall(function() proj.ExplosionParticleFX = fx end) end
            end,
        })
    end

    LogDebug("FrostShells - " .. count .. " shell(s)", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- =======================================================================
-- PortalDrop - the staged Gatekeeper arrival: open a portal, hang a beat, THEN have whatever is
-- coming step out. The telegraph is the mechanic - the delay is the window to be elsewhere.
-- The doorway (Niagara_Portal_Door) HARD-LOOPS, so it rides the client-FX channel (BroadcastFX
-- can't close a looping system) and shuts itself OpenMs later.
--
-- location: where the portal opens. Nav-project it in the CALLER - we never move it.
-- opts:
--   EmergeMs   ms from open -> OnEmerge (default 2000, the "step through" beat)
--   OpenMs     how long the doorway stays up (default EmergeMs + 3000)
--   Yaw        the doorway's facing in degrees (default 0). The FX is a flat plane and is
--              invisible edge-on, so set it whenever the player has a fixed vantage. It is also
--              the direction the doorway DRIFTS, so it is worth setting even for a head-on view.
--   Drift      uu the doorway travels along Yaw over its whole life, starting half that distance
--              AHEAD of `location` and ending half behind it - the "warp gate advancing on you"
--              read. The travel is spread over the SAME lifetime, so a bigger number is a faster
--              slide. Omit to take the registry entry's own Drift (GK_PORTAL = 100); 0 pins it.
--   Key        ClientFX registry key (default "GK_PORTAL")
--   OnEmerge(location)  AUTHORITY callback - spawn your NPCs here. Fired ONCE, off-hook.
--              NOTE the arrivals are placed at `location`, NOT at where the doorway has drifted to -
--              the drift is theatre, the spawn point is the anchor.
-- =======================================================================
function SP.PortalDrop(location, opts)
    if not Utils.IsAuthority() or not location then return end
    opts = opts or {}

    local emergeMs = opts.EmergeMs or 2000
    local openMs = opts.OpenMs or (emergeMs + 3000)

    -- Rift = false: skip the DOORWAY, keep the staging (the emerge delay + whatever the caller does
    -- per arrival, usually AVU.SpawnPortalFX). For summons that should read as "popping in" - the
    -- big flat GK doorway is a lot of theatre for two small drones.
    if opts.Rift ~= false then
        FX.SendClientFX(location, opts.Key or "GK_PORTAL", math.ceil(openMs / 1000),
            opts.Yaw, opts.Drift)
    end

    if not opts.OnEmerge then return end

    Utils.QueueWork(function()
        pcall(opts.OnEmerge, location)
    end, emergeMs)
end


-- =======================================================================
-- PortalSummon - the whole "reinforcements arrive through a rift" set-piece in one call.
-- PortalDrop opens the portal; this spawns + mutates what walks out, sets faction/target, and -
-- unlike a hand-rolled version - ties each arrival's LIFETIME to the summoner. That last part is
-- not optional: a script-spawned NPC belongs to no spawner group, so nothing ever unloads it, and
-- an unowned one strands in an empty level forever.
--
-- location: where the portal opens. Nav-project it in the CALLER if the summoner may be hovering or
--           on a ledge - we scatter the arrivals from here but never move the portal.
-- spawns: an array; each entry is one of
--     "Gatekeeper_Phyter"                      - a base NPC (an ENUMS.NpcClasses key)
--     { Npc = "Gatekeeper_Phyter", Count = 2 } - N of a base NPC
--     { Variant = "Barrier Eye", Count = 1,    - N of a VARIANT, via SP.SummonVariant, so it is
--       Opts = { CarryHpFrac = 0.4 } }           mutated + tagged. Opts reaches Stats as `opts`.
-- opts:
--   EmergeMs / OpenMs / Key / Yaw / Rift / Drift  forwarded to SP.PortalDrop. Yaw is ALSO the
--                 facing every arrival spawns with, so a body steps out of the doorway pointing
--                 the way the doorway points (and the way it drifts) instead of at world 0. An
--                 entry's own Opts.Rotation still wins; with no Yaw this is the FRotator() default
--                 the spawners already used, so nothing changes for callers that don't set one.
--   Spread        (default 200) scatter radius from the portal, each spot nav-projected
--   Attack        an actor -> every arrival is forced onto it (AVU.ForceAggro)
--   AggroDelayMs  (default 600) ForceAggro re-validates at fire time, so a late target is fine
--   Faction       explicit faction number for the arrivals...
--   FactionFrom   ...or an actor to copy it from (e.g. the summoner)
--   LifetimeOwner an actor -> each arrival destroys itself when that actor goes INVALID. Gated on
--                 invalid, NOT death, so summons keep fighting after the summoner dies and only
--                 vanish when the corpse unloads (IsActorValid checks IsLevelLoaded).
--   EmergeFX      (default TRUE) the portal burst per arrival. Preload AVU.PORTAL_FX in Assets.
--   SkipSpawnFX   (default TRUE) suppress the native spawn-in. FALSE only if you want both.
--   Guard         fn() -> bool at emerge; false aborts (the summoner died mid-cast).
--   OnSpawned(npc) per-arrival hook, after all of the above - the genuinely special stuff (the
--                 Barrier Mage linking an eye back to itself).
-- =======================================================================
local PORTAL_SPREAD_ANGLE = 137   -- golden-ish, so N arrivals never stack on each other

function SP.PortalSummon(location, spawns, opts)
    if not Utils.IsAuthority() or not location or not spawns then return end
    opts = opts or {}

    local AVU = require("AnteUtils.AVUtils")   -- lazy: AVUtils requires US (merge loop)
    local spread = opts.Spread or 200
    local skipFX = (opts.SkipSpawnFX ~= false)
    -- Read at emerge and per arrival, a portal and an async spawn later: carried from here
    -- (Utils.CarryActor). Attack is a combat target and can be an unstamped prop.
    local getAttack = Utils.CarryActor(opts.Attack)
    local getFactionFrom = Utils.CarryActor(opts.FactionFrom)
    local getOwner = Utils.CarryActor(opts.LifetimeOwner)

    -- Flatten Count into a plain list, so index -> arrival spot is 1:1.
    local list = {}
    for _, e in ipairs(spawns) do
        local entry = (type(e) == "string") and { Npc = e } or e
        for _ = 1, (entry.Count or 1) do list[#list + 1] = entry end
    end
    if #list == 0 then return end

    SP.PortalDrop(location, {
        EmergeMs = opts.EmergeMs,
        OpenMs = opts.OpenMs,
        Key = opts.Key,
        Yaw = opts.Yaw,
        Drift = opts.Drift,
        Rift = opts.Rift,

        OnEmerge = function(where)
            if opts.Guard and not opts.Guard() then return end

            -- Resolve the faction ONCE, as a number: the summoner can die before the async spawn
            -- callback, and a dead wrapper can't be read.
            local faction = opts.Faction
            local from = (faction == nil) and getFactionFrom() or nil
            if from then pcall(function() faction = from.Faction end) end

            for i, entry in ipairs(list) do
                -- Nav-project each arrival - a raw XY offset can land inside a wall or off a ledge.
                -- No point -> fall back to the portal itself, which is already standable.
                local at = where
                if #list > 1 then
                    local rad = math.rad(i * PORTAL_SPREAD_ANGLE)
                    at = Utils.GetSpawnPoint(
                        FVector(where.X + math.cos(rad) * spread,
                                where.Y + math.sin(rad) * spread,
                                where.Z), spread) or where
                end

                local function arrive(npc)
                    if Utils.IsActorInvalid(npc) then return end

                    if opts.EmergeFX ~= false then FX.SpawnPortalFX(npc) end
                    if faction ~= nil then AVU.SetFaction(npc, faction) end

                    -- The owner is checked every tick from here on, so its own departure is seen
                    -- within a tick - well inside the stamp's life.
                    if getOwner() then
                        AVU.RegisterOnTickActor(npc, function(sub)
                            if Utils.IsActorInvalid(sub) then return "REMOVE" end
                            if not getOwner() then
                                pcall(function() sub:K2_DestroyActor() end)
                                return "REMOVE"
                            end
                        end)
                    end

                    local attack = getAttack()
                    if attack then AVU.ForceAggro(npc, attack, opts.AggroDelayMs or 600) end
                    if opts.OnSpawned then pcall(opts.OnSpawned, npc) end
                end

                -- Face the arrival the way the DOORWAY faces: it walked out of that plane, so a
                -- body standing at a right angle to it reads as spawned-in. Fresh per arrival -
                -- never one struct wrapper shared across async spawns (S3).
                local facing = FRotator(0, opts.Yaw or 0, 0)

                if entry.Variant then
                    -- Copy so we never mutate the caller's table across repeats.
                    local vopts = {}
                    for k, v in pairs(entry.Opts or {}) do vopts[k] = v end
                    if vopts.SkipSpawnFX == nil then vopts.SkipSpawnFX = skipFX end
                    if vopts.Rotation == nil then vopts.Rotation = facing end
                    SP.SummonVariant(entry.Variant, at, vopts, arrive)
                else
                    require("AnteCore.NpcSpawner").SpawnNpc(entry.Npc, at, {
                        SkipSpawnFX = skipFX,
                        Rotation = facing,
                        callback = arrive,
                    })
                end
            end
        end,
    })
end


-- =======================================================================
-- ARRIVALS - named spawn-in profiles: how a script-summoned body enters, in place of its class's
-- native spawn-in. Each profile is a PortalSummon opts table, so a new one is data, not a code path.
--   * Script spawns only. A body a GAME spawner made has already run BeginPlay, and with it the
--     native spawn-in, before we ever see it.
--   * "/spawn <name> <arrival>" (AnDebug/ChatCommands) is the debug door.
-- =======================================================================
SP.ARRIVALS = {
    rift = { Rift = true, EmergeFX = false },                -- the drifting GK doorway; steps out 2s later
    none = { Rift = false, EmergeMs = 0, EmergeFX = false }, -- just there: no doorway, no spawn-in
}

-- Summon `name` (variant or raw NpcClasses row) at `loc` through an SP.ARRIVALS profile. `yaw` faces
-- the doorway and the arrival alike. False for an unknown profile.
function SP.SummonArrival(name, loc, arrival, yaw)
    local profile = SP.ARRIVALS[arrival]
    if not profile or not loc then return false end

    local opts = { Yaw = yaw }
    for k, v in pairs(profile) do opts[k] = v end

    local entry = require("AnteVariants.Variants")[name] and { Variant = name } or { Npc = name }
    SP.PortalSummon(loc, { entry }, opts)
    return true
end


-- =======================================================================
-- DropLoot - the OnDeath/OnGibbed loot drop with its guards, replacing the 5-line boilerplate
-- every variant hand-rolled (validity -> location -> reject the degenerate X==0 origin -> spawn).
--   AVU.DropLoot(actor, drops, opts?)  -- returns loc if the guards passed, else nil
--     drops = ONE entry or a LIST. Entry keys:
--       Row = <rowname>, Amount = n?   - single-item drop (ItemSpawner.Drop)
--       Pool = {...}, Count = n?       - pool drop (DropPool; Count nil = every entry)
--                                        a pool ROW is { G.ROWNAME, amount? }, resolved in Global
--       Radius = r?                    - fuzz radius (default 75)
--       MinStory / MaxStory = s?       - only when StoryProgress >= / <= s, checked at drop time
--       Chance = c?                    - only with probability c (0..1)
--       CustomRow = true               - a Row one of OUR modules builds: dropped only while it
--                                        is in the item table (ItemSpawner.RowExists)
--     MinStory/MaxStory/Chance ALSO work on an individual ROW inside a Pool
--     ({ G.TACTICAL_SCRAP, 1, MinStory = 81 }) - gated-out rows are removed BEFORE the
--     Count draw, so they can't win the roll either. A pool row is read positionally by
--     ItemSpawner.resolveEntry, so a named key on an ungated pool reaches nobody silently - gate a
--     whole pool with a sibling entry instead ({ Pool = {...}, MinStory = 81 }).
--     A LIST of entries needs its own outer braces - DropLoot(actor, {...}, {...}) puts the second
--     entry in the `opts` slot, where it drops nothing and reports nothing.
--     opts.SkipTamed - bail on a tamed pet's corpse (PlayerPets: wild variants of petable NPCs).
-- =======================================================================
-- [AUTHORITY] Mark ONE actor's SCRIPTED loot suppressed - the drops a variant's own OnDeath makes
-- through SP.DropLoot. AVU.ClearLoot / StripLoot only suppress NATIVE death loot and can't touch
-- these. OPT-IN deliberately: "ClearLoot the vanilla drops, then DropLoot our own" is a common
-- pattern across variants, and having DropLoot honour HasDroppedLoot would silently break all of
-- them. Keyed by ActorKey and CONSUMED on the drop, so the table stays bounded to "spawned but not
-- yet dead" - for event/summoned bodies that must not become a farm.
local lootSuppressed = {}

function SP.SuppressScriptedLoot(actor)
    local key = Utils.ActorKey(actor)
    if key then lootSuppressed[key] = true end
end

function SP.DropLoot(actor, drops, opts)
    if Utils.IsActorInvalid(actor) then return nil end
    local name = Utils.GetActorName(actor)

    -- Consume the flag either way - this actor is dying, the entry has no later use.
    local skey = Utils.ActorKey(actor)
    if skey and lootSuppressed[skey] then
        lootSuppressed[skey] = nil
        Utils.LogDebug("DropLoot - suppressed for " .. tostring(name), SETTINGS.DEBUG_NPC_ACTIONS)
        return nil
    end

    if opts and opts.SkipTamed then
        -- Native out-param check (bool GetFollowerBuff(buff&)) - the authoritative "is a tamed pet"
        -- test. Followers REVIVE, so dropping loot off one is farmable.
        local pet = false
        pcall(function()
            local has, buff = actor:GetFollowerBuff()
            if has == true then pet = true end
            if buff ~= nil and IsValid(buff) then pet = true end
        end)
        if pet then return nil end
    end

    local loc = actor:K2_GetActorLocation()
    if not loc or loc.X == 0 then
        Utils.LogDebug("DropLoot - " .. tostring(name) .. " bailed (degenerate location)", SETTINGS.DEBUG_NPC_ACTIONS)
        return nil
    end

    if drops.Row or drops.Pool then
        -- A table that is BOTH a drop entry and a list of them is a brace typo: the wrap below
        -- keeps only the entry, and the list elements silently never drop (the Jotun Steed lost a
        -- whole 4-item pool this way). Say so rather than eating it.
        if #drops > 0 then
            Utils.Log("DropLoot - " .. tostring(name) .. " passed a Row/Pool entry that ALSO holds "
                      .. #drops .. " list entries; those are ignored (brace typo?)")
        end
        drops = { drops }
    end

    local story   -- resolved once, only if something gates on it
    local function passesGate(d)
        if d.MinStory or d.MaxStory then
            if story == nil then
                -- Lazy require: StoryManager pulls variant defs (load-time cycle back to AVU).
                story = require("ModuleStory.StoryManager").GetStoryProgress() or 0
            end
            if d.MinStory and story < d.MinStory then return false end
            if d.MaxStory and story > d.MaxStory then return false end
        end
        if d.Chance and math.random() >= d.Chance then return false end
        if d.CustomRow and d.Row and not ItemSpawner.RowExists(d.Row) then return false end
        return true
    end

    local queued = 0
    for _, d in ipairs(drops) do
        if passesGate(d) then
            if d.Row then
                ItemSpawner.Drop(d.Row, d.Amount or 1, loc, d.Radius or 75)
                queued = queued + 1
            elseif d.Pool then
                -- Per-ROW gates (see the header). Filtered up front so a gated-out row is out of
                -- the Count draw entirely; an untouched pool is passed through by reference.
                local pool, gated = d.Pool, false
                for _, row in ipairs(pool) do
                    if row.MinStory or row.MaxStory or row.Chance then gated = true; break end
                end
                if gated then
                    local keep = {}
                    for _, row in ipairs(pool) do
                        if passesGate(row) then keep[#keep + 1] = row end
                    end
                    pool = keep
                end
                if #pool > 0 then
                    ItemSpawner.DropPool(pool, d.Count, loc, d.Radius or 75)
                    queued = queued + 1
                end
            end
        end
    end
    -- Dispatch proof: distinguishes "loot queued, then the spawn pipeline wedged" from "OnDeath
    -- never dispatched" when diagnosing a freeze.
    Utils.LogDebug("DropLoot - " .. tostring(name) .. " queued " .. queued .. "/" .. #drops .. " entries",
        SETTINGS.DEBUG_NPC_ACTIONS)
    return loc
end


return SP
