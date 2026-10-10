-- =======================================================================
-- Order Grunt helpers - the machinery behind AnteNPCs/OrderGrunt.lua (SPLIT RULE: see the def file)
--
-- MUST-KNOWS
--   * NEVER call the native ranged attack from inside OnTick: Server_DoRangedAttack's hitscan fans
--     out into every NPC's combat hooks, re-enters UE4SS's ProcessEvent and AVs in dense combat
--     ([[anteup2-velites-reentrancy-crash]]). Hold still + face the target and let the BT shoot.
--   * PerformingRangedBurst is the cheap "is it in the aim/fire animation" read (host-side only -
--     AI runs on the authority, doesn't need to replicate).
--   * MODULAR PARTS ARE MERGED AWAY at spawn (MergeAndClearSkeletals folds Head/Legs/ClassGear into
--     `Mesh` and clears the sources) - address them as material SLOTS on `Mesh`, found BY NAME.
--   * Speeding the grenade throw MONTAGE drops its AnimNotify (grunt throws nothing) - use
--     CustomTimeDilation instead, which scales the whole timeline. Full notify-chain decode and the
--     borrowed-montage barrage: AnNotes/AnteNPCs/OrderGrunt.md.
--   * The Speculatores rappel is fully scripted: the native rope-down never moves the pawn (an
--     AnimBP root-bone offset off a one-shot timestamp), so nothing about it repeats or reverses.
--     Playing the fastrope loop BACKWARDS needs negative rate AND start position at the end
--     (Montage_Play always seeds position 0) - see specRopePose.
--   * Utils.QueueWork rounds its delay UP to whole 100ms fast ticks - see SPEC_STEP_MS.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local ENUMS = require("AnteData.Enums")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local AVM = require("AnteUtils.AVMath")
local PROJ = require("AnteCore.Projectile")
local ASSETS = require("AnteCore.AssetManager")

local LogDebug = Utils.LogDebug

local Anims = {
    StaggerLeft  = ENUMS.Anims.GRUNT_STAGGER_LEFT,
    StaggerRight = ENUMS.Anims.GRUNT_STAGGER_RIGHT,
}

local H = {}

local specRappel, specDrop, specRestoreMove, specRopePose, specZ


-- Force the helmet on (the native decide path, NPC_Soldier_Grunt.cpp Label_1369).
--   * Native Server_DecideIfWearingHelmet is a 50/50 roll at BeginPlay.
--   * Grunt_Guard's override of it is a no-op, so Guard AltBases never wear one on their own.
function H.ForceHelmet(actor)
    AVU.SetReplicatedProp(actor, "HasHelmet", true)
end


-- [AUTHORITY] The backpack is its own 20% roll (Server_DecideIfWearingBackpack,
-- NPC_Soldier_Grunt.cpp Label_1379); these settle it either way, as ForceHelmet does the 50/50.
-- Its OnRep is a bare SetVisibility, so both directions are safe from a drain.
function H.ForceBackpack(actor)
    AVU.SetReplicatedProp(actor, "HasBackpack", true)
end

function H.ForceNoBackpack(actor)
    AVU.SetReplicatedProp(actor, "HasBackpack", false)
end


-- =======================================================================
-- VELITES GUARD
-- The whole maneuver stack is DUTY-CYCLED (~10s backoff / ~5s regular grunt) so it doesn't kite
-- relentlessly. ON: backs off to a LoS'd point (Signifer recipe), throttled to one pathfind per
-- ~3s, with plant-to-fire hold windows. OFF: native BT drives it (minus the melee lunge); only the
-- reactive jukes (VelitesDodge) stay live. Per-actor phase offset so a squad doesn't move in lockstep.
-- =======================================================================

local VEL_ENGAGE_SQ = 2000 * 2000   -- only maneuver within this range (else let the BT close in)
local VEL_FIRE_SQ   = 1500 * 1500   -- hold to fire within this range
local VEL_FIRE_CD   = 25            -- 2.5s between fire windows
local VEL_FIRE_HOLD = 18            -- 1.8s hold-still per window, so the BT gets a standing burst
local VEL_STAGGER_CHANCE = 0.5     -- chance ON HIT to hard-stagger (side leap + stagger anim)
local VEL_STAGGER_CD     = 40       -- min ticks between hard staggers, so a barrage can't
                                    -- stagger-lock it (each hit still rolls the chance)
                                    
-- Whole-mesh wash over the off-duty kit. MULTIPLIES, so every channel <= 1 only darkens.
local VEL_TINT           = FVector(2.5, 2.5, 1)
local VEL_STAGGER_DIST   = 800 -- Stagger impulse velocity
local VEL_STAGGER_UP     = 200

-- Reload retime. MULTIPLIES the body's dilation, so it composes with the baseline below.
local VEL_RELOAD      = 2
local VEL_RELOAD_HARD = 4

-- The def's TimeDilation, owned here because the tick compares against it to tell "reload boost
-- is up" from "normal". def.TimeDilation reads it, so the two can't drift apart.
H.VELITES_TDI = 1.1
local VEL_TDI_EPS = 0.01

-- Duty cycle for the whole maneuver stack; side jukes stay phase-independent.
-- Hard mode holds the backoff window longer and gives less recovery between them.
local VEL_KITE_ON       = 100   -- (10s) maintain distance
local VEL_KITE_OFF      = 50    -- (5s) act like a normal grunt
local VEL_KITE_ON_HARD  = 120   -- (12s)
local VEL_KITE_OFF_HARD = 30    -- (3s)

-- Returns the ON length and the full cycle length for the current difficulty.
local function velKiteBands()
    if STATE.HardModeNoMercy then
        return VEL_KITE_ON_HARD, VEL_KITE_ON_HARD + VEL_KITE_OFF_HARD
    end
    return VEL_KITE_ON, VEL_KITE_ON + VEL_KITE_OFF
end
local VEL_KITE_TRIGGER = 700     -- ON window: backoff if target is near (7m; at 10m it backed off
                                 --    from targets that were already in its own fire band)
local VEL_KITE_MIN     = 1000   -- ...to a LoS'd navmesh point 10-16m away 
local VEL_KITE_MAX     = 1600   --    so it can still open a fire window from the new spot)
local VEL_KITE_CD      = 30     -- min ticks between walk orders; stamped even on a failed
                                --    FindLosPoint, so a cornered actor doesn't re-probe every tick

-- Per-actor state (weak keys -> GC'd actors drop out; OnTick hands back a STABLE wrapper).
local velFire = setmetatable({}, { __mode = "k" })   -- actor -> totalTicks of last fire window
local velHold = setmetatable({}, { __mode = "k" })   -- actor -> tick until which we hold still
local velKitePhase = setmetatable({}, { __mode = "k" })    -- actor -> random duty-cycle offset
local velLastKiteTick = setmetatable({}, { __mode = "k" }) -- actor -> tick of last walk order

-- The body's own kit needs no preloading - it is class-default on the off-duty guard.
H.VELITES_ASSETS = {
    ENUMS.Components.SM_HELM_MAKESHIFT_NVGS,
    -- Reactive hard-stagger anims: kept warm so the OnDamageTaken play doesn't sync-load inside
    -- the ProcessDamage hook (S2). The LeapBack is a montage-free impulse.
    ENUMS.Anims.GRUNT_STAGGER_LEFT, ENUMS.Anims.GRUNT_STAGGER_RIGHT,
}


-- [RENDERER] NVGs over the off-duty guard's own kit, washed. Only Color is written, so def.Tint's
-- lens glow survives; the wash reaches the torso because nothing replaces slot 0 any more.
function H.VelitesLook(actor)
    if Utils.IsActorInvalid(actor) then return end

    AVU.AttachStaticMesh(actor, ENUMS.Components.SM_HELM_MAKESHIFT_NVGS, "head", {
        Location = FVector(0, 0, 0),
        Rotation = FRotator(90, 90, 0),
        Scale = FVector(0.5, 1.2, 1.2),
        Color = FVector(0, 0, 0),
    })

    pcall(function() actor.HasShoulderLight = false end)   -- honoured on the next LocalToggleLightFX

    AVU.TintMesh(actor, { Color = VEL_TINT })
end


-- Suppress melee always; everything else only runs during the backoff (ON) window - during OFF
-- the native BT drives it like a regular grunt.
function H.VelitesTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) then return end

    -- Release the reload pin the moment the boost is actually back at baseline - checked ahead of
    -- the combat guards below, because a fight that ends mid-reload would otherwise leave the body
    -- pinned at zero speed. ReloadDilation's own hard stop bounds the wait; ReleaseGround no-ops
    -- when nothing is held, so this costs a table lookup on a normal tick.
    local tdi = H.VELITES_TDI
    pcall(function() tdi = tonumber(actor.CustomTimeDilation) or H.VELITES_TDI end)
    if tdi > H.VELITES_TDI + VEL_TDI_EPS then return end
    AVU.ReleaseGround(actor)

    -- Still roping in: footwork now would slide the body out from under the rope animation.
    if actor.IsPerformingSpawnFX then return end

    -- While flinching / DBNO / dead / mid-montage, just wait.
    --   * The jukes are fire-and-forget montages, so there's nothing to cancel.
    if not Utils.IsActorReadyToAttack(actor) then return end
    if totalTicks % 4 ~= 0 then return end   -- ~2.5/s

    AVU.SuppressMelee(actor)   -- never lunge; it's a ranged skirmisher

    -- Any locked montage (reload, aggro, door enter) means no footwork: a move order on top of one
    -- slides the body with no locomotion anim to play.
    if actor.LockedInPlaceMontage then return end

    -- Duty cycle: OFF window -> hands off entirely (a regular grunt, minus the lunge).
    local kiteOn, kiteCycle = velKiteBands()
    if velKitePhase[actor] == nil then velKitePhase[actor] = math.random(0, kiteCycle - 1) end
    if (totalTicks + velKitePhase[actor]) % kiteCycle >= kiteOn then return end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end

    local aLoc = actor:K2_GetActorLocation()
    local tLoc = target:K2_GetActorLocation()
    local distSq = Utils.DistSq(aLoc, tLoc)

    -- PLANT WHILE FIRING: while the burst is live just face the target so it shoots planted.
    --   * The fire window below INVITES the shot; this sustains the facing through the whole
    --     burst, so it takes priority over the range checks.
    if actor.PerformingRangedBurst then
        pcall(function() actor:K2_SetActorRotation(Utils.RotatorToTarget(aLoc, tLoc), false) end)
        return
    end

    -- Far: let the BT close the gap (don't fight it out of range).
    if distSq > VEL_ENGAGE_SQ then return end

    -- FIRE WINDOW: we do NOT script the burst (see the header).
    --   * Seed velFire on first engage so the first window waits a full cooldown.
    if velFire[actor] == nil then velFire[actor] = totalTicks end

    -- Mid hold window: keep facing the target, no juke, let the BT fire.
    if velHold[actor] and totalTicks < velHold[actor] then
        pcall(function() actor:K2_SetActorRotation(Utils.RotatorToTarget(aLoc, tLoc), false) end)
        return
    end

    -- Open a new hold window: PLANT (cancel any in-flight backoff walk - footwork below can leave
    -- a move order running), face the target, hand off to the BT.
    if distSq <= VEL_FIRE_SQ
       and (actor.CurrentAmmoCount or 0) > 0
       and (totalTicks - velFire[actor]) >= VEL_FIRE_CD then
        velFire[actor] = totalTicks
        velHold[actor] = totalTicks + VEL_FIRE_HOLD
        pcall(function()
            local c = actor:GetController()
            if IsValid(c) then c:StopMovement() end
        end)
        pcall(function() actor:K2_SetActorRotation(Utils.RotatorToTarget(aLoc, tLoc), false) end)
        return
    end

    -- BACKOFF: target inside the comfort band -> walk back out to a LoS'd point 10-16m away (the
    -- Signifer recipe), throttled to one pathfind per VEL_KITE_CD.
    if distSq > VEL_KITE_TRIGGER * VEL_KITE_TRIGGER then return end
    if not AVU.CooldownReady(velLastKiteTick, actor, VEL_KITE_CD, { Now = totalTicks }) then return end
    -- No Fallback: cornered means stand and shoot, not a blind back-away.
    AVU.KiteFrom(actor, target, { MinDist = VEL_KITE_MIN, MaxDist = VEL_KITE_MAX })
end


-- Compress the reload so it spends less of the fight standing still (def.MirrorTimeDilation is
-- what carries the retime to clients).
--
-- PIN THE BODY FOR IT. CustomTimeDilation scales MOVEMENT as well as animation, so any frame the
-- body is both boosted and free to move is covered at the boosted speed. HoldGround zeroes the
-- speeds, and zero times any dilation is still zero - which is what makes this hold regardless of
-- when the boost actually lands back at baseline. VelitesTick releases it.
-- (NOT AVU.HoldStill: that writes LockedInPlaceMontage, the very flag ReloadDilation polls to
-- decide the reload is over.)
function H.VelitesReload(actor)
    if Utils.IsActorInvalid(actor) then return end
    AVU.HoldGround(actor)
    AVU.ReloadDilation(actor, STATE.HardModeNoMercy and VEL_RELOAD_HARD or VEL_RELOAD)
end


-- REACTIVE STAGGER: chance to side stagger with an added push when hit
--   * AVU.Jump's own cooldown rate-limits it
--   * Montage play deferred one WQ tick off the ProcessDamage hook; anims preloaded (S2).
function H.VelitesDodge(victim, damage, dmgType)
    if Utils.IsActorInvalid(victim) then return end
    if victim.IsPerformingSpawnFX then return end   -- no juke off the rope
    -- Don't hard-stagger on a basic BLEED DoT (a lurching dodge per bleed tick reads silly);
    -- other DoTs are fine. dmgType is the DamageType object; its full name carries the row.
    local dtn = Utils.DamageTypeName(dmgType)
    if dtn and string.find(dtn, "Bleeding", 1, true) then return end
    if math.random() >= VEL_STAGGER_CHANCE then return end

    local left = math.random() < 0.5
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(victim) or victim.IsDead then return end
        AVU.Jump(victim, {
            Dir = left and "left" or "right",
            Distance = VEL_STAGGER_DIST, Up = VEL_STAGGER_UP,
            Cooldown = VEL_STAGGER_CD, CooldownKey = "stagger",
            Montage = left and Anims.StaggerLeft or Anims.StaggerRight,
        })
    end, 0)
end


-- =======================================================================
-- GRENADIER GUARD
-- =======================================================================

-- Throw beats over its cycle (5 grenades, 17 seconds)
local GREN_CYCLE = 170
local GRENADIER_TIMES = { [20] = true, [70] = true, [110] = true, [140] = true, [160] = true }

-- Cook-off cooldown, SHARED by the electrified-net path and the hard-hit path.
--   * Stops a hard hit, or the cook-off grenade's OWN blast, from chain-dropping more grenades.
local lastCookoffTick = {}   -- ActorKey -> tick of the last cook-off (cross-hook wrappers differ)
local DROP_GRENADE_CD = 50          -- 5s between cook-off drops (FAST_TICK = 10/s)
local DROP_GRENADE_MINDAMAGE = 30   -- only hard hits

-- Throw-hold: keep facing the target past the sped-up throw.
--   * The throw is sped 2.5x, so the montage + its GrenadeRelease notify complete in ~0.3-0.4s
--     real; hold a few ticks past that so the body still faces the target at grenade release.
local grenHold = setmetatable({}, { __mode = "k" })
local GREN_THROW_HOLD = 6   -- ticks (~0.6s)
local GREN_MAX_DZ = 500     -- no throw beat at a target more than a storey above or below

H.GRENADIER_ASSETS = {
    ENUMS.Components.SM_GRENADE_FRAG,
    ENUMS.Components.T_TORSO_BREACHER,
    ENUMS.Components.T_TORSO_BREACHER_INJURED1,
    ENUMS.Components.T_TORSO_BREACHER_INJURED2,
    ENUMS.Components.T_TORSO_BREACHER_INJURED3,
    -- The native single throw's own montage (Broadcast_ThrowGrenade soft-loads it), so the first
    -- throw after a quiet stretch is a cache hit.
    ENUMS.Anims.GRUNT_GRENADE_THROW,
    -- [HARD] the barrage (see BARRAGE below). Warmed here AND re-warmed at fire time - a
    -- def.Assets preload beats GC by timing, not pinning (S3), and the barrage first fires
    -- tens of seconds after mutation.
    ENUMS.Anims.INTERFECTOR_THROW_KNIVES,
    ENUMS.ProjectileClasses.GrenadeFrag,
}

-- Baseline CustomTimeDilation, matching the def's TimeDilation. Named constant because every throw
-- path punches it and has to put it back - restoring the wrong value (e.g. a copy-pasted 1.1 from
-- another variant) permanently speeds the Grenadier up after its first throw.
local GREN_BASE_TDI = 0.9

-- [HARD] THE BARRAGE - three grenades thrown on the Interfector's (notify-free) knife-throw
-- animation instead of the grunt's own grenade throw, so nothing native fires and we own all
-- three releases. Release-beat timing is pre-compensated for QueueWork's 100ms rounding and
-- PROJ.SpawnGrenade's own one-tick defer. Full decode: AnNotes/AnteNPCs/OrderGrunt.md.
--   * Don't change BARRAGE.Rate without re-deriving BARRAGE.Rel (see the note file).
-- Everything in ONE table (the 200-local rule).
local BARRAGE = {
    Beat     = 140,    -- which GRENADIER_TIMES slot of the GREN_CYCLE loop becomes the barrage:
                       --    1 barrage + 4 single throws per cycle. MUST be a key of
                       --    GRENADIER_TIMES or the branch is unreachable and hard mode is silent.
    Rate     = 0.75,   -- montage play rate (see above - do not change without re-deriving Rel)
    Rel      = { 100, 300, 600 },   -- ms from barrage start to each QUEUED spawn (pre-compensated)
    HoldMs   = 1400,   -- face-the-target hold; must outlast the montage (0.8 / 0.75 = 1.07s)
    RestMs   = 1200,   -- when the baseline TimeDilation goes back on
    Damage   = 90,     -- per grenade. The class default is 400 (175 under HardMode NoAvail) and
                       --    three of those is not a fight, it is a cutscene.
    ArcDeg   = 32,     -- lob angle; ArcSpeed solves the speed for the actual range
    Gravity  = 1,      -- MUST match the row's ProjectileGravityScale (projectile_fraggrenade = 1)
                       --    or the arc solve lies
    MaxSpeed = 2500,   -- the row caps at 1500 and clamps SILENTLY - past ~17m the solve needs more
    Spread   = 220,    -- lateral fan (uu) so three grenades cover ground instead of stacking
    Fuzz     = 90,     -- per-grenade jitter on top of the fan
    Fan      = { -1, 0.35, 1 },   -- fan multipliers, in throw order
    -- FIRE LOCKOUT: without it the BT opens up mid-barrage and the rifle montage cuts the throw
    -- animation short (releases still land, they're WorkQueue beats not anim notifies, but it
    -- looks wrong). Lever is RangedAttack_OnCooldown - "on cooldown" is child 1 of the root
    -- Selector in BT_Attack_Soldier, above both firing branches, so true there blocks a burst.
    -- Re-pinned on a heartbeat because each native attack attempt clears it. Must be explicitly
    -- released at the end, or a body pinned outside the AI's own reset path never shoots again.
    LockFireMs   = 1500,   -- covers the montage (1.07s) plus the last release
    LockPulseMs  = 300,    -- re-pin cadence; coarse on purpose, see grenLockFire
}
BARRAGE.Deps = { ENUMS.Anims.INTERFECTOR_THROW_KNIVES, ENUMS.ProjectileClasses.GrenadeFrag }


-- [RENDERER] Breacher-look torso + a grenade bandolier.
function H.GrenadierLook(actor)
    -- HealthTextures: per-index in-place writes ONLY (a whole-array assign mangles the soft-ptrs
    -- into an AV). Injured1-3 keep the damage-state feedback.
    pcall(function()
        local texes = {
            ASSETS.GetIfValid(ENUMS.Components.T_TORSO_BREACHER),
            ASSETS.GetIfValid(ENUMS.Components.T_TORSO_BREACHER_INJURED1),
            ASSETS.GetIfValid(ENUMS.Components.T_TORSO_BREACHER_INJURED2),
            ASSETS.GetIfValid(ENUMS.Components.T_TORSO_BREACHER_INJURED3),
        }
        local ht = actor.HealthTextures
        if not ht then return end
        for i = 1, #ht do
            local t = texes[i] or texes[1]
            if IsValid(t) then ht[i] = t end
        end
    end)

    -- A row of frag meshes across the back. Pass the PATH - AttachStaticMesh re-resolves per
    -- attach, so the shared mesh can't be a stale wrapper.
    local positions = {
        FVector(-12, 32, 7), FVector(-5, 37, 0), FVector(2, 37, -7),   -- R+/F+/U+
        FVector(9, 37, -14),
    }
    for _, loc in ipairs(positions) do
        AVU.AttachStaticMesh(actor, ENUMS.Components.SM_GRENADE_FRAG, "backpack", {
            Location = loc,
            Scale = FVector(1.1, 1.1, 1.1),
        })
    end

    AVU.SetHelmet(actor, { Color = FVector(9, 7, 1) })
end


-- The ORDINARY throw: one native grenade, snapped out fast.
--   * AIM: the thrown projectile's direction is FindLookAtRotation(fireSocket ->
--     LastRangedAttackLocation + arc offset), NOT body facing. We drive the throw via
--     Broadcast_ThrowGrenade directly, so that location is whatever the rifle last set - stale,
--     or (0,0,0) if it hasn't fired - and grenades flew at an old spot. The rifle re-sets it on
--     its next burst, so pinning it here is a harmless one-off write.
--   * Snapped out via CustomTimeDilation, NOT the montage rate: speeding the MONTAGE drops the
--     GrenadeRelease AnimNotify and the grunt throws nothing (see the header).
--   * DEDICATED hops the native call off-hook (EIGT + path re-resolve, the PointDamageOffHook
--     shape). The throw soft-loads its montage and its release notify spawns the grenade; if
--     either is cold, loading inside the tick hook is the CLAUDE.md 2 wedge (the 2026-09-14
--     freeze sat in this tick's throw beat). A renderer host keeps it inline: EIGT from a tick on
--     a host is the paint hazard.
local function grenadierNativeThrow(actor, targetLoc)
    if Utils.IsActorInvalid(actor) then return end
    pcall(function() actor.LastRangedAttackLocation = targetLoc end)

    AVU.SetTimeDilation(actor, 2.5)
    if Utils.HasRenderer() then
        Utils.Crumb("grenThrow:native")
        pcall(function() actor:Broadcast_ThrowGrenade() end)
    else
        local path = Utils.ObjectPath(actor)
        if not path then return end
        ExecuteInGameThread(function()
            STATE.LastWork = "EIGT grenThrow " .. path
            STATE.LastWorkDone = false
            local a = Utils.ResolveByPath(path)
            if a and Utils.IsActorReadyToAttack(a) then
                pcall(function() a:Broadcast_ThrowGrenade() end)
            end
            STATE.LastWorkDone = true
        end)
    end
    LogDebug("Grenadier Guard - grenade", SETTINGS.DEBUG_NPC_ACTIONS)

    Utils.QueueWork(function()
        if Utils.IsActorValid(actor) then AVU.SetTimeDilation(actor, GREN_BASE_TDI) end
    end, 800)
end


-- Throwing-hand location, with an eye-height fallback (the Winterfector's handLoc).
local function grenHandLoc(actor)
    local mesh = Utils.GetValidMesh(actor)
    if mesh then
        local ok, loc = pcall(function() return mesh:GetSocketLocation(FName("r_hand")) end)
        if ok and loc then return loc end
    end
    local l = actor:K2_GetActorLocation()
    if not l then return nil end
    return FVector(l.X, l.Y, l.Z + 120)
end


-- Hold the rifle off for the length of a barrage, then hand control straight back (BARRAGE.LockFireMs).
--   * First pin written inline (already on the drain, so QueueWork(_, 0) would only cost exposure).
--   * Heartbeat is deliberately COARSE: the WorkQueue drains newest-first, 2 items/tick, GLOBALLY
--     ([[anteup2-workqueue-drain-starvation]]), and a barrage already queues 5+ other items.
local function grenLockFire(actor)
    pcall(function() actor.RangedAttack_OnCooldown = true end)
    for ms = BARRAGE.LockPulseMs, BARRAGE.LockFireMs, BARRAGE.LockPulseMs do
        Utils.QueueWork(function()
            if Utils.IsActorValid(actor) then pcall(function() actor.RangedAttack_OnCooldown = true end) end
        end, ms)
    end
    Utils.QueueWork(function()
        if Utils.IsActorValid(actor) then pcall(function() actor.RangedAttack_OnCooldown = false end) end
    end, BARRAGE.LockFireMs + BARRAGE.LockPulseMs)
end


-- The GRENADE IN THE HAND. Skipping GrenadeAppear/GrenadeRelease also skips their held-mesh
-- bookkeeping, so without this the barrage is three empty-handed mimes.
--   * Local_SpawnGrenadeInHand(false) spawns a fresh mesh at socket "npcgrenade", (true) only
--     destroys it - ONE slot, so show/hide must interleave exactly one per throw.
--   * LOCAL (builds a component, doesn't replicate) and runs on the authority, so a pure client
--     sees empty hands during the barrage - accepted, same cosmetic bound as the rest of this
--     variant; skipped outright on dedicated (no renderer to spend it on).
local function grenHandMesh(actor, show)
    if not Utils.HasRenderer() then return end
    if Utils.IsActorInvalid(actor) then return end
    pcall(function() actor:Local_SpawnGrenadeInHand(not show) end)
end


-- ONE arc-solved frag, lobbed at the target. `index` picks its lane in the fan.
local function grenLob(actor, target, index)
    if Utils.IsActorInvalid(actor) or Utils.IsActorInvalid(target) then return end
    if actor.IsDead or actor.IsDBNO then return end

    local from = grenHandLoc(actor)
    local tLoc = target:K2_GetActorLocation()
    if not from or not tLoc then return end

    -- Hand off the held mesh as the throw leaves, then re-arm it for the next lane (the last
    -- one leaves the hand empty, which is correct).
    grenHandMesh(actor, false)
    if index < #BARRAGE.Rel then
        Utils.QueueWork(function() grenHandMesh(actor, true) end, 0)
    end

    -- Fan the three landing points ACROSS the line of fire, so the volley covers ground instead
    -- of stacking one crater: perpendicular of the flat aim direction, x the lane multiplier.
    local nx, ny = AVM.Normalize2D(tLoc.X - from.X, tLoc.Y - from.Y)
    local off = BARRAGE.Spread * (BARRAGE.Fan[index] or 0)
    local aim = Utils.FuzzLocation(FVector(tLoc.X - ny * off, tLoc.Y + nx * off, tLoc.Z), BARRAGE.Fuzz)

    local speed = AVM.ArcSpeed(from, aim, BARRAGE.ArcDeg, BARRAGE.Gravity)
    local dir = AVM.ArcDir(from, aim, BARRAGE.ArcDeg)

    -- WasThrown stays TRUE (PROJ's default): it is what tells HardMode's NoAvail damage rewrite
    -- and CombatHooks' DefBot suppressor that this grenade is a variant's own attack, so our
    -- Damage is the number that survives.
    PROJ.SpawnGrenade(actor, ENUMS.ProjectileClasses.GrenadeFrag, {
        Label = "Grenadier barrage",
        Location = from,
        AlignToVelocity = true,
        Velocity = FVector(dir.X * speed, dir.Y * speed, dir.Z * speed),
        Damage = BARRAGE.Damage,
        Gravity = BARRAGE.Gravity,
        MaxSpeed = BARRAGE.MaxSpeed,
    })
end


-- [HARD] THE BARRAGE: the Interfector's knife-throw animation, throwing frags. See BARRAGE.
--   * The montage is played REPLICATED (PlayThirdPersonMontage carries the play rate to clients;
--     a local Montage_SetPlayRate would be server-only).
--   * UNLOCKED (lockInPlace=false): LockedInPlaceMontage is a latch nothing here clears, and the
--     grenHold facing loop in GrenadierTick already plants the body.
--   * Baseline TimeDilation is pinned to 1 for the throw. CustomTimeDilation scales the whole
--     animation timeline, so the def's 0.9 would stretch the montage out from under a release
--     schedule that is in REAL milliseconds.
local function grenadierBarrage(actor, target)
    if Utils.IsActorInvalid(actor) or Utils.IsActorInvalid(target) then return end

    -- S3: re-warm at fire time - a def.Assets preload does not pin, and the first barrage is tens
    -- of seconds after mutation. Doubles as the residency test: a RESIDENT asset calls back
    -- SYNCHRONOUSLY (montage is set before the next statement); a COLD one calls back later via
    -- EIGT, leaves it nil, and the fallback below eats that one barrage. If this ever profiles hot,
    -- pin BARRAGE.Deps via KEEPER.PinPaths at mutation instead ([[anteup2-pinned-cache-trust]]).
    local montage
    Utils.Crumb("grenBarrage:warm")
    ASSETS.LoadAsync(BARRAGE.Deps, function(results)
        montage = results[ENUMS.Anims.INTERFECTOR_THROW_KNIVES]
    end)

    -- Don't mime an empty throw. One native grenade is the honest fallback.
    if IsNotValid(montage) then
        grenadierNativeThrow(actor, target:K2_GetActorLocation())
        LogDebug("Grenadier Guard - barrage montage cold, fell back to one throw", SETTINGS.DEBUG_NPC_ACTIONS)
        return
    end

    Utils.Crumb("grenBarrage:lock")
    grenLockFire(actor)         -- BEFORE the montage: the burst we are racing starts on the AI's tick
    AVU.SetTimeDilation(actor, 1)
    Utils.Crumb("grenBarrage:montage")
    AVU.PlayMontageReplicated(actor, ENUMS.Anims.INTERFECTOR_THROW_KNIVES, BARRAGE.Rate, false)
    Utils.Crumb("grenBarrage:hand")
    grenHandMesh(actor, true)   -- the first grenade appears in hand; grenLob passes it along
    LogDebug("Grenadier Guard - HARD barrage", SETTINGS.DEBUG_NPC_ACTIONS)

    for i = 1, #BARRAGE.Rel do
        Utils.QueueWork(function() grenLob(actor, target, i) end, BARRAGE.Rel[i])
    end

    Utils.QueueWork(function()
        if Utils.IsActorValid(actor) then AVU.SetTimeDilation(actor, GREN_BASE_TDI) end
    end, BARRAGE.RestMs)
end


-- Throws a grenade at scripted beats while the target is at mid range.
function H.GrenadierTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end

    -- Electrified Net - immediately drops or detonates a grenade (50/50 chance)
    if totalTicks % 5 == 0 then
        Utils.Crumb("grenTick:netbuff")
        if Utils.ActorHasBuff(actor, ENUMS.Debuffs.NettedCannon) then
            local ckey = Utils.ActorKey(actor)
            if ckey and AVU.CooldownReady(lastCookoffTick, ckey, DROP_GRENADE_CD, { Now = totalTicks }) then
                Utils.Crumb("grenTick:cookoff")
                AVU.DropGrenades(actor, 1, (math.random() < 0.5) and 1 or 0)
                LogDebug("Grenadier Guard - electrified-net cook-off", SETTINGS.DEBUG_NPC_ACTIONS)
            end
        end
    end

    if not Utils.IsActorReadyToAttack(actor) then return end

    -- PLANT + FACE while firing the rifle or mid-throw. Runs before the throw-beat gate (which
    -- returns early most ticks), so the body is actually pointed at the target during both.
    --   * Use AVU.FaceTarget, not a bare K2_SetActorRotation - actor yaw alone is overwritten by
    --     the controller next frame, so repeated writes against it oscillate (reads as spinning or
    --     facing away). FaceTarget also writes the control rotation, which is the one that sticks.
    if totalTicks % 2 == 0 then
        local tgt = actor:GetCurrentCombatTarget()
        if Utils.IsActorValid(tgt)
           and (actor.PerformingRangedBurst or (grenHold[actor] and totalTicks < grenHold[actor])) then
            Utils.Crumb("grenTick:plant")
            local c = actor:GetController()
            if IsValid(c) then pcall(function() c:StopMovement() end) end
            AVU.FaceTarget(actor, tgt)
        end
    end

    if totalTicks % 10 ~= 0 then return end
    if not GRENADIER_TIMES[totalTicks % GREN_CYCLE] then return end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end
    local actorLoc = actor:K2_GetActorLocation()
    local targetLoc = target:K2_GetActorLocation()

    -- Mid range only: too close and it grenades itself, too far and it misses.
    local distSq = Utils.DistSq(actorLoc, targetLoc)
    if distSq < 200 * 200 or distSq > 2500 * 2500 then return end

    -- Reachable only: a target a storey away or behind cover can't be lobbed at, and a beat that
    -- fires anyway is what pins the body in one spot chucking grenades at a ceiling. No throw =
    -- no hold, so the BT is free to move it. One Visibility trace per beat (~3s).
    if math.abs(targetLoc.Z - actorLoc.Z) > GREN_MAX_DZ then return end
    Utils.Crumb("grenBeat:los")
    local eye = FVector(actorLoc.X, actorLoc.Y, actorLoc.Z + 120)
    if AVU.IsPathBlocked(actor, eye, targetLoc, { actor, target }) then return end

    Utils.Crumb("grenBeat:cancel")
    AVU.CancelAnim(actor)
    Utils.Crumb("grenBeat:aggro")
    AVU.ForceAggro(actor, target)
    Utils.Crumb("grenBeat:face")
    AVU.FaceTarget(actor, target)

    -- [HARD] the LAST beat of each cycle is a three-grenade barrage instead of one lob.
    --   * The other four beats stay single throws, so the barrage reads as a distinct move
    --     rather than the Grenadier's normal output.
    --   * grenadierBarrage falls back to the native single throw if its montage isn't resident,
    --     so this branch never costs a beat.
    if STATE.HardModeNoMercy and (totalTicks % GREN_CYCLE) == BARRAGE.Beat then
        grenHold[actor] = totalTicks + math.ceil(BARRAGE.HoldMs / 100)
        grenadierBarrage(actor, target)
        return
    end

    grenHold[actor] = totalTicks + GREN_THROW_HOLD
    grenadierNativeThrow(actor, targetLoc)
end


-- Hard hit while still up -> a chance to stagger and cook off 2-3 live grenades.
--   * Cooldown-gated so a hit (or the cook-off blast, which re-enters this hook) can't chain.
--   * Skipped once down or dead, where the DBNO cook-off takes over.
function H.GrenadierHit(victim, damage)
    if Utils.IsActorInvalid(victim) then return end
    if damage < DROP_GRENADE_MINDAMAGE then return end

    local dropGrenades = math.random() < 0.5
    if dropGrenades then
        pcall(function() victim:AI_PerformStagger(FVector(), false) end)
    end

    if victim.IsDead or victim.IsDBNO then return end
    local vkey = Utils.ActorKey(victim)
    if not vkey then return end
    local now = STATE.FAST_TICK
    -- Peek: the coin flip above can still veto, and a vetoed hit must not eat the cooldown.
    if not AVU.CooldownReady(lastCookoffTick, vkey, DROP_GRENADE_CD, { Now = now, Peek = true }) then return end
    if dropGrenades then
        lastCookoffTick[vkey] = now
        AVU.DropGrenades(victim, math.random(2, 3), 0)
        LogDebug("Grenadier Guard - hard-hit cook-off", SETTINGS.DEBUG_NPC_ACTIONS)
    end
end


-- =======================================================================
-- SUPPRESSOR GRUNT
-- =======================================================================

local SUPP_WALK       = 130   -- normal walk (base Grunt)
local SUPP_SPRINT     = 350   -- normal advance speed
local SUPP_SLOW_SPEED = 100   -- crawl while firing (walk == sprint, so it can't outrun the crawl)
local SUPP_SLOW_TICKS = 100   -- ~10s of crawl per burst

local suppSlowUntil = setmetatable({}, { __mode = "k" })   -- actor -> tick the slow lapses

H.SUPP_WALK = SUPP_WALK
H.SUPP_SPRINT = SUPP_SPRINT


-- SLOW-MARCH-WHILE-FIRING: on opening up, drop move speed to a crawl for ~10s, then restore.
--   * Each fresh burst refreshes the window, so it keeps grinding forward under fire.
--   * Movement itself is the Breacher BT's job - we only re-tune the speed.
function H.SuppressorTick(actor, totalTicks)
    -- Restore the moment the window lapses.
    --   * BEFORE the ready gate, so a stagger/DBNO mid-window can't strand it at the crawl.
    if suppSlowUntil[actor] and totalTicks >= suppSlowUntil[actor] then
        suppSlowUntil[actor] = nil
        AVU.SetMoveSpeed(actor, SUPP_WALK, SUPP_SPRINT)
    end

    if not Utils.IsActorReadyToAttack(actor) then return end

    if actor.PerformingRangedBurst then
        -- Rising edge: apply the crawl once (walk == sprint, so it can't sprint out of it).
        if not suppSlowUntil[actor] then
            AVU.SetMoveSpeed(actor, SUPP_SLOW_SPEED, SUPP_SLOW_SPEED)
        end
        suppSlowUntil[actor] = totalTicks + SUPP_SLOW_TICKS
    end
end


-- =======================================================================
-- CENTURION GRUNT  (the brave one + the squad mark)
-- Bravery is two blackboard counters (FailedHits, MeleeCounter) pinned to 0, not a new behaviour
-- tree - the only lever available against BT_Attack_Soldier's cover logic. The mark is a
-- `playersound_gunfire` noise event (force-spot, hostility-checked, no scan) fired ONCE per fight,
-- a few seconds in - it reads as "it just called us in" rather than as an ambient siren. Full
-- BT_Attack_Soldier branch decode: AnNotes/AnteNPCs/OrderGrunt.md.
--   SETTINGS.GAMEPLAY.AI_SENSE.HearingRange is a hard ceiling on CENT_MARK_RANGE.
-- =======================================================================

local CENT_TICKS          = 10     -- ~1s: bravery re-assert
local CENT_MARK_DELAY     = 30     -- ~3s after entering combat, the one call-out
local CENT_MARK_RETRY     = 5      -- mid-burst at the due beat: slide it, don't drop it
local CENT_MARK_RANGE     = 2500   -- who gets called in (capped by the listeners' HearingRange)
local CENT_MARK_ANIM      = ENUMS.Anims.STAND_AND_RADIO   -- the one radio gesture in the game
-- The clip is a ~7s ambient "fiddle with a radio", far too long to stand in mid-firefight, so only
-- a slice of it is used: START skips the reach-for-the-handset wind-up, MS ends both the gesture
-- and the busy window. The call-out lands on the same beat.
local CENT_MARK_START     = 2      -- seconds into the clip: the handset is already at the ear
local CENT_MARK_MS        = 1000   -- how long the gesture parks it
local CENT_MARK_SFX       = "RADIO_CALL"   -- the chirp again, loud enough to carry over the fight

-- Melee tempo. The tree waits out the swing montage's RAW length, so the play rate on its own is
-- pure dead air - CenturionTick fires the release valve once the sped-up swing has really ended.
-- The two apexes are world-time beats inside the montage, so they scale with the rate or the swing
-- connects after the arm has come back down.
local CENT_MELEE = {
    Rate      = 1.5,
    Apex      = 0.5 / 1.5,    -- MeleeHitApex, base 0.5
    PowerApex = 0.72 / 1.5,   -- PowerMeleeHitApex, base 0.72
    Fallback  = 1.2,          -- assumed montage length until the measurement lands
    Pad       = 2,            -- ticks of slack on the release
}

-- centurion key -> the FAST_TICK its opening call-out is due at, left by OnEnterCombat and spent
-- by the tick. ActorKey, not the wrapper: the combat hook and the tick see different registrations
-- of the same body.
local centMarkDue = {}
-- The swing record and the release bookkeeping, keyed by ActorKey: OnMeleeSwing is a hook and
-- hands out a fresh wrapper each fire.
local centSwingTick = {}   -- key -> FAST_TICK of the last swing
local centReleased  = {}   -- key -> the swing stamp already released for

H.CENTURION_ASSETS = {
    ENUMS.Components.M_GLASS_LENS_RED,
    CENT_MARK_ANIM,   -- also re-loaded at each fire (a preload does not PIN - S3)
}


-- [AUTHORITY] Radio the target's position to every Order body that can hear it.
--   * LOCKED-IN-PLACE montage: that also parks the BT (BTD_IsNPCBusy) so it stands still for the
--     call instead of walking through it, and the chirp is native + replicated on its own.
--   * The anim fires minutes after mutation, so it is re-LoadAsync'd at fire time (S3).
--   * Left to run its own length the clip holds the body for ~8s and the tree fires straight
--     through it with the gun stuck in the radio pose, so the stop is explicit.
--   * The noise ORIGINATES AT THE CENTURION, not at the target. Hearers gate on their distance to
--     the noise LOCATION, so the default (the instigator's own spot) would draw the circle around
--     the player and leave the Centurion's own squad out of a call it is making.
local function centurionMark(actor, target)
    ASSETS.LoadAsync({ CENT_MARK_ANIM }, function()
        if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return end
        if Utils.IsActorInvalid(target) then return end

        pcall(function()
            local move = actor.CharacterMovement
            if IsValid(move) then move:StopMovementImmediately() end
        end)
        AVU.PlayMontageReplicated(actor, CENT_MARK_ANIM, 1, true)
        pcall(function() actor:Broadcast_RadioChirp() end)
        local loc = actor:K2_GetActorLocation()
        if loc then AVU.SendClientFX(loc, CENT_MARK_SFX, 2) end
        -- Server-local, so a remote client watches the wind-up instead - the stop below is the half
        -- that has to reach everyone.
        AVU.SkipIntoAnimation(actor, CENT_MARK_ANIM, CENT_MARK_START)

        -- Land the call-out at the END of the gesture, so the squad reacts to something they saw.
        Utils.QueueWork(function()
            if Utils.IsActorInvalid(actor) or actor.IsDead then return end
            AVU.StopMontageReplicated(actor, CENT_MARK_ANIM)
            if Utils.IsActorInvalid(target) then return end

            local from = actor:K2_GetActorLocation()
            if not from then return end
            local sent = AVU.ReportNoise(target, {
                Tag   = AVU.NOISE_TAGS.Aggro,
                Range = CENT_MARK_RANGE,
                Pos   = from,
            })

            -- Whether the call reached anyone splits two failures that look identical from the
            -- outside: the noise not being reported at all, and it being reported into an empty
            -- circle. The sweep is a sphere overlap, once per fight, and only when debugging.
            if SETTINGS.DEBUG_NPC_ACTIONS then
                local heard = #AVU.GetNearbyNpcs(from, CENT_MARK_RANGE)
                LogDebug("Centurion Grunt - marked target: reported=" .. tostring(sent)
                    .. ", " .. heard .. " NPC(s) within " .. CENT_MARK_RANGE .. "uu",
                    SETTINGS.DEBUG_NPC_ACTIONS)
            end
        end, CENT_MARK_MS)
    end)
end


-- [AUTHORITY] The 1.5x swing: montage rate (replicates) plus the two hit beats it moves.
function H.CenturionMeleeTempo(actor)
    pcall(function()
        actor.MeleeAttackPlayRate = CENT_MELEE.Rate
        actor.MeleeHitApex        = CENT_MELEE.Apex
        actor.PowerMeleeHitApex   = CENT_MELEE.PowerApex
    end)
end


-- [AUTHORITY, OnMeleeSwing] Stamp the swing. Fires per attempt, hit or miss, before the hit test -
-- CenturionTick times the release off it.
function H.CenturionSwing(actor)
    if not Utils.IsAuthority() then return end
    if Utils.IsActorInvalid(actor) then return end
    local key = Utils.ActorKey(actor)
    if key then centSwingTick[key] = STATE.FAST_TICK end
end


-- [AUTHORITY, OnEnterCombat] Arm the one call-out of this fight. Only marks the body: the tick
-- owns the stable wrapper, the target check and the mid-burst slide.
function H.CenturionAggro(actor)
    if Utils.IsActorInvalid(actor) then return end
    local key = Utils.ActorKey(actor)
    if key then centMarkDue[key] = STATE.FAST_TICK + CENT_MARK_DELAY end
end


-- [AUTHORITY, OnDeath] Drop the swing record. Plain tables, STRING keys - they never collect.
function H.CenturionDeath(actor)
    local key = Utils.ActorKey(actor)
    if key then centSwingTick[key], centReleased[key], centMarkDue[key] = nil, nil, nil end
end


-- [AUTHORITY] Let the tree swing again as soon as the sped-up montage has really finished. Driven
-- from the tick, not a QueueWork inside OnMeleeSwing, so no fresh wrapper is held across a delay.
-- A nil measurement just means "not yet" - the native delay still ends the swing.
--   * FAST_TICK is real time and the swing is NOT: the Centurion's CustomTimeDilation scales the
--     montage too, so the effective rate is the product. Releasing early would cut the swing off
--     mid-arc; late merely hands the tree what it was going to take anyway.
local function centurionRelease(actor, key)
    local last = centSwingTick[key]
    if not last or centReleased[key] == last then return end

    local rate = CENT_MELEE.Rate * (tonumber(actor.CustomTimeDilation) or 1)
    local wait = AVU.MeleeReleaseTicks(ENUMS.Anims.GRUNT_MELEE, rate, {
        Fallback = CENT_MELEE.Fallback, Pad = CENT_MELEE.Pad,
    })
    if not wait or STATE.FAST_TICK - last < wait then return end

    centReleased[key] = last
    AVU.ReleaseSoldierBT(actor)
end


-- [AUTHORITY] Spend the armed call-out once its beat lands. A fight it drops out of before then
-- takes the mark with it: the current target is nil out of combat, and there is nothing to radio.
local function centurionMarkDue(actor, key)
    local due = centMarkDue[key]
    if not due or STATE.FAST_TICK < due then return end

    -- The gesture takes the arms, so opening it mid-burst puts the muzzle somewhere the shots
    -- aren't going. Slide the beat rather than losing the fight's one call.
    if actor.PerformingRangedBurst == true then
        centMarkDue[key] = STATE.FAST_TICK + CENT_MARK_RETRY
        return
    end

    centMarkDue[key] = nil
    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorValid(target) then centurionMark(actor, target) end
end


-- [AUTHORITY] Hold the two cover counters down, fire the armed call-out, and pace the melee.
function H.CenturionTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end

    local key = AVU.CachedFullName(actor)
    if key then
        if actor.IsDead then
            centSwingTick[key], centReleased[key], centMarkDue[key] = nil, nil, nil
        else
            centurionRelease(actor, key)
            centurionMarkDue(actor, key)
        end
    end

    if totalTicks % CENT_TICKS ~= 0 then return end
    if not Utils.IsActorReadyToAttack(actor) then return end

    -- The bravery. Both writes are one BP call each and non-loading, so a 1s cadence is cheap.
    AVU.SetBlackboardInt(actor, "FailedHits", 0)
    AVU.SetBlackboardInt(actor, "MeleeCounter", 0)
end



-- =======================================================================
-- SPECULATORES  (the rappel flanker)
-- IsPerformingSpawnFX is the whole control channel: setting it parks the BT (IsNPCBusy), mutes
-- perception on the authority, REPLICATES (push-model), and every renderer's tick mirror shows/
-- hides the rope off that same flag - no extra client plumbing. On a live grunt it otherwise does
-- nothing (only the AnimBP RopeAlpha mirror, inert with a stale timestamp).
-- =======================================================================

local SPEC_RELOC_CD    = 200           -- repositioning rappel cooldown
local SPEC_FAR         = { Normal = 1500, Hard = 1000 }   -- only rappel once the target is this far (uu)
-- Teleport-step cadence. 100ms is a FLOOR, not a preference.
--   * Utils.QueueWork quantizes its delay to whole 100ms fast ticks (ceil), so scheduling at
--     50ms just fires two steps in the same drain.
--   * To make a phase FASTER, cut its STEP COUNT - the per-step hop grows, the wall-clock shrinks.
local SPEC_STEP_MS     = 100
local SPEC_UP_STEPS    = 9             -- ~0.9s winch up - 2x the old 17-step/1.7s climb
local SPEC_DOWN_STEPS  = 22            -- ~2.2s descent - the drop-in reads deliberate, not snapped
local SPEC_RISE_Z      = 500           -- winch height (the native RopeOffset.Z)
local SPEC_HOLD_MS     = 2000          -- "gone" beat at the apex before the drop-in
local SPEC_DROP_MIN    = 500           -- LoS ring around the target - never drops within 5m
local SPEC_DROP_MAX    = 1400
local SPEC_LAND_ZLIFT  = 90            -- navmesh point -> capsule centre (or it sinks into the floor)
local SPEC_ABORT_MS    = 12000         -- watchdog: the sequence is ~5.3s; restore by here regardless
local SPEC_ROPE_SCALE  = FVector(0.025, 0.025, 9)   -- the native RopeMesh recipe (900uu of rope)
local SPEC_ROPE_OFFSET = FVector(0, 0, 450)         -- cylinder pivot is centred: span feet -> +900
-- Rope-loop play rates (the fastrope loop at native 1.0 reads as frantic hand-over-hand against
-- the slower scripted winch).
--   * Renderer-LOCAL (each machine plays its own copy off the replicated flag), so the rate
--     "replicates" by construction.
--   * UP runs REVERSED (see specRopePose) and faster, to match the 2x winch; DOWN is the native
--     direction at the old deliberate rate.
local SPEC_ROPE_RATE_UP   = 1.2
local SPEC_ROPE_RATE_DOWN = 0.6
local SPEC_ROPE_LOOPS     = 99
-- The AnimBP's OWN rappel pose, driven instead of the slot montage above. On = the native
-- RopeDownFX state machine, Off = the hand-rolled reversed montage.
--   * RootSlide 0 blanks the AnimBP's own rope descent. Its RopeOffset.Z of 500 is the same 500 our
--     winch teleports, applied to the MESH on top of it - the body climbs twice as far, twice as
--     fast. We own the position here, so the AnimBP contributes pose only.
--   * TotalTime is the alpha's decay window, re-stamped every re-assert so it never runs out
--     mid-rappel (see specNativeRopePose).
local SPEC_NATIVE_POSE = {
    On = true,
    TotalTime = ((9 * 100 + 100) + 2000 + (22 * 100 + 100)) / 1000,   -- SPEC_UP/HOLD/DOWN, in seconds
    RootSlide = 0,
}
-- Loop direction is inferred from the actor's own Z drift over the re-assert window (~0.3s).
--   * The ONLY signal both ends share: IsPerformingSpawnFX is a single bool and position
--     replicates natively.
--   * Rise/fall per window is ~170uu / ~70uu, so the deadband is generous.
local SPEC_DIR_EPS_Z      = 20

-- Keyed by ActorKey, NOT the wrapper: the client mirror and the authority driver may run
-- on different registrations of the same body.
local specState     = {}   -- authority: key -> { cd = tick, busy = bool }
local specRopeState = {}   -- renderer:  key -> { armed = bool, comp = ropeComp, dir, lastZ }

H.SPECULATORES_ASSETS = { ENUMS.Components.SM_ROPE_CYLINDER, ENUMS.Components.M_ROPE_GRAY,
                          ENUMS.Anims.GRUNT_FASTROPE_LOOP, ENUMS.Components.M_GLASS_LENS_GOLD }


-- The two halves of the Speculatores tick; the dispatcher that picks between them lives INLINE
-- in the def's OnTick (AnteNPCs/OrderGrunt.lua).

-- [RENDERER, every tick] Rope mirror; arms only after the flag has been LOW once.
--   * The native RopeSpawn spawn-in owns the first high window (its own rope + anim);
--     arming late keeps us from double-roping it.
function H.SpecRopeMirror(actor, totalTicks)
    local key = Utils.ActorKey(actor)
    if not key then return end
    local st = specRopeState[key]
    if not st then st = { armed = false }; specRopeState[key] = st end

    local flag = false
    pcall(function() flag = actor.IsPerformingSpawnFX == true end)

    if not st.armed then
        if not flag then st.armed = true end
        return
    end

    if flag and not st.comp then
        st.comp = AVU.AttachStaticMesh(actor, ENUMS.Components.SM_ROPE_CYLINDER, "root", {
            Location = SPEC_ROPE_OFFSET, Scale = SPEC_ROPE_SCALE,
            Material = ENUMS.Components.M_ROPE_GRAY, Immediate = true,
        })
        -- Winch-up owns the rising edge: start REVERSED (climbing) without waiting for a
        -- Z sample; the drift read below takes over from the next window on.
        st.dir  = -1
        st.lastZ = specZ(actor)
        if SPEC_NATIVE_POSE.On then specNativeRopePose(actor) else specRopePose(actor, st.dir) end
    elseif flag and st.comp and SPEC_NATIVE_POSE.On then
        -- Slide the alpha window along so RopeLoop can't time out mid-rappel (specNativeRopePose).
        if totalTicks % 3 == 0 then specNativeRopePose(actor, true) end
    elseif flag and st.comp then
        -- RE-ASSERT the pose while roped (~every 0.3s): the dynamic montage can be interrupted
        -- mid-sequence, and played only once on the rising edge that left the NPC idle-standing
        -- in mid-air. Replay only when no montage is active, or the vertical direction flipped.
        if totalTicks % 3 == 0 then
            local z, want = specZ(actor), st.dir or -1
            if z and st.lastZ then
                local dz = z - st.lastZ
                if dz > SPEC_DIR_EPS_Z then want = -1        -- rising  -> climb (reversed)
                elseif dz < -SPEC_DIR_EPS_Z then want = 1 end -- falling -> native descend
            end
            st.lastZ = z or st.lastZ

            local active
            pcall(function()
                local mesh = Utils.GetValidMesh(actor)
                local inst = mesh and mesh:GetAnimInstance()
                if IsValid(inst) then active = inst:GetCurrentActiveMontage() end
            end)
            if want ~= st.dir or not (active and IsValid(active)) then
                st.dir = want
                specRopePose(actor, want)
            end
        end
    elseif (not flag) and st.comp then
        pcall(function() st.comp:K2_DestroyComponent(st.comp) end)
        st.comp = nil
        st.dir, st.lastZ = nil, nil
        pcall(function()
            local mesh = Utils.GetValidMesh(actor)
            local inst = mesh and mesh:GetAnimInstance()
            if IsValid(inst) then inst:StopSlotAnimation(0.2, FName("DefaultSlot")) end
        end)
    end
end


-- Current capsule Z, or nil. Own number (never the transient wrapper FVector).
function specZ(actor)
    local z
    pcall(function()
        local l = actor:K2_GetActorLocation()
        if l then z = l.Z end
    end)
    return z
end


-- [AUTHORITY] End the rappel's AI park. BT_SetStunned is a SHARED bool, so a real stun that landed
-- mid-rappel owns it now and its own buff removal will clear it - clearing here would hand the
-- Speculatores a free escape from it.
function specReleaseStun(actor)
    if Utils.IsActorInvalid(actor) then return end
    if AVU.HasGameplayTag(actor, "Modifier.Stunned") then return end
    AVU.SetBtStunned(actor, false)
end


-- [RENDERER] Re-arm the AnimBP's OWN rappel pose - the RopeDownFX state machine, whose RopeLoop
-- state holds Anim_Grunt_FastRope_Loop.
--   * The machine re-enters RopeLoop by itself whenever IsPerformingSpawnFX turns its branch back
--     on (bReinitializeOnBecomingRelevant), so all it needs from us is a live timer.
--   * That timer is why a repositioning rappel shows nothing. RopeAlpha is
--     MapRangeClamped(now, InitTimestamp, InitTimestamp + RopeTotalTime, 1, 0) and InitTimestamp is
--     stamped ONCE, when the anim instance initialises. Minutes later it is long expired, RopeAlpha
--     reads 0, and RopeLoop's only transition (RopeAlpha == 0) fires on the first frame - into
--     RopeEnd, which is terminal. The body plays the LANDING clip and then stands there.
--   * Stamped from the AnimBP's own CachedGameTime, so both sides read one clock and no world
--     lookup is needed. A zero there means the instance has not ticked yet - leave it alone rather
--     than stamping a timer that expires instantly.
--   * RE-STAMPED on a cadence, not once. RopeAlpha hitting 0 is RopeLoop's ONLY exit and RopeEnd is
--     terminal, so a single expiry drops the pose for the rest of the rappel with no way back -
--     which is why sliding the window along costs less than sizing it correctly.
function specNativeRopePose(actor, quiet)
    local why
    pcall(function()
        local mesh = Utils.GetValidMesh(actor)
        local inst = mesh and mesh:GetAnimInstance()
        if IsNotValid(inst) then why = "no anim instance"; return end

        local now = inst.CachedGameTime
        if not now or now <= 0 then why = "CachedGameTime " .. tostring(now); return end
        inst.RopeOffset    = FVector(0, 0, SPEC_NATIVE_POSE.RootSlide)
        inst.RopeTotalTime = SPEC_NATIVE_POSE.TotalTime
        inst.InitTimestamp = now
        why = string.format("native RopeLoop re-armed for %.1fs", SPEC_NATIVE_POSE.TotalTime)
    end)
    if not quiet or not why then
        LogDebug("Speculatores - rope pose: " .. tostring(why), SETTINGS.DEBUG_NPC_ACTIONS)
    end
end


-- Play the fastrope-loop pose on THIS renderer, in `dir` (-1 = reversed/climbing, 1 = native
-- descend). An AnimSEQUENCE, played via the slot player, local to this machine; cosmetic-grade,
-- so a miss just means the idle pose rides up.
--   * REVERSING: Montage_Play always seeds position 0 regardless of rate sign, so a bare -rate
--     ends on frame one. Instead: let PlaySlotAnimationAsDynamicMontage build the montage (the
--     only way to wrap a raw sequence), then re-issue Montage_Play on it at -rate starting one
--     tick shy of the end - looped SPEC_ROPE_LOOPS times, so it plays far past the ~1s the winch needs.
function specRopePose(actor, dir)
    local reverse = (dir or -1) < 0
    ASSETS.LoadAsync({ ENUMS.Anims.GRUNT_FASTROPE_LOOP }, function(results)
        local seq = results[ENUMS.Anims.GRUNT_FASTROPE_LOOP]
        if IsNotValid(seq) or Utils.IsActorInvalid(actor) then return end
        -- Every reverse bail below leaves the clip running FORWARD - a descent pose on a rising
        -- body, which reads as "the animation is just clunky". Name the bail so it can't hide.
        local why
        local ok, err = pcall(function()
            if not actor.IsPerformingSpawnFX then return end
            local mesh = Utils.GetValidMesh(actor)
            local inst = mesh and mesh:GetAnimInstance()
            if IsNotValid(inst) then why = "no anim instance"; return end

            local rate = reverse and SPEC_ROPE_RATE_UP or SPEC_ROPE_RATE_DOWN
            local m = inst:PlaySlotAnimationAsDynamicMontage(seq, FName("DefaultSlot"), 0.2, 0.2,
                rate, SPEC_ROPE_LOOPS, -1.0, 0.0)
            if not reverse then why = "descend, forward"; return end
            if IsNotValid(m) then why = "FORWARD - no montage returned"; return end

            local len = m:GetPlayLength()
            if not len or len <= 0 then why = "FORWARD - GetPlayLength " .. tostring(len); return end
            inst:Montage_Play(m, -rate, 0, len - 0.001, true)
            why = string.format("climb, reversed from %.2fs", len)
        end)
        if not ok then why = "FORWARD - threw: " .. tostring(err) end
        if why then LogDebug("Speculatores - rope pose: " .. why, SETTINGS.DEBUG_NPC_ACTIONS) end
    end)
end


-- [AUTHORITY, every ~5s] Rappel when off cooldown, in combat, and the target is past SPEC_FAR.
function H.SpecDrive(actor, totalTicks)
    local key = Utils.ActorKey(actor)
    if not key then return end
    local st = specState[key]
    if not st then st = { cd = -SPEC_RELOC_CD }; specState[key] = st end
    if st.busy then return end
    if totalTicks - st.cd < SPEC_RELOC_CD then return end
    if actor.IsDead then return end

    local target = AVU.GetCurrentTarget(actor)
    if Utils.IsActorInvalid(target) then return end
    local al = actor:K2_GetActorLocation()
    local tl = target:K2_GetActorLocation()
    if not al or not tl then return end
    local far = STATE.HardModeNoMercy and SPEC_FAR.Hard or SPEC_FAR.Normal
    if Utils.DistSq(al, tl) <= far * far then return end

    st.cd = totalTicks
    st.busy = true
    specRappel(actor, st)
    LogDebug("Speculatores - rappel up (target " .. math.floor(math.sqrt(Utils.DistSq(al, tl)) / 100) .. "m out)",
        SETTINGS.DEBUG_NPC_ACTIONS)
end


-- The UP half: open the flag channel, winch the actor up the rope, vanish at the apex, then hand
-- off to specDrop.
--   * Every deferred step re-validates and bails through abort() - idempotent and also armed as
--     a watchdog, so a death/stream-out mid-sequence can't strand an invisible, collisionless,
--     AI-parked body.
function specRappel(actor, st)
    local function abort()
        st.busy = false
        if Utils.IsActorInvalid(actor) then return end
        pcall(function()
            actor.IsPerformingSpawnFX = false
            Utils.MarkReplicatedDirty(actor, "IsPerformingSpawnFX")
            actor:OnRep_IsPerformingSpawnFX()
            actor:SetActorHiddenInGame(false)
            Utils.MarkReplicatedDirty(actor, "bHidden")
            actor:SetActorEnableCollision(true)
        end)
        specReleaseStun(actor)
        specRestoreMove(actor)
    end
    Utils.QueueWork(function() if st.busy then abort() end end, SPEC_ABORT_MS)

    if Utils.IsActorInvalid(actor) or actor.IsDead then st.busy = false; return end
    local start = actor:K2_GetActorLocation()
    if not start or start.X == 0 then st.busy = false; return end
    start = FVector(start.X, start.Y, start.Z)   -- own copy (the wrapper's FVector is transient)

    pcall(function()
        actor.IsPerformingSpawnFX = true
        Utils.MarkReplicatedDirty(actor, "IsPerformingSpawnFX")
    end)

    -- Park the AI for the whole sequence. IsPerformingSpawnFX alone only makes IsNPCBusy() true,
    -- which gates the tree's next evaluation but does not abort a ranged attack already running -
    -- hence a body winching up the rope still firing, without even turning to face. The Stunned
    -- branch aborts, and carries no FX of its own.
    AVU.SetBtStunned(actor, true)

    -- FLY for the whole sequence; restored to Falling at the end / on abort.
    --   * In Falling mode gravity re-accelerates the pawn between teleport steps and the
    --     tug-of-war reads as rapid vertical jitter.
    --   * Flying = no gravity, so each absolute set stands.
    pcall(function()
        local move = actor.CharacterMovement
        if IsValid(move) then
            move:StopMovementImmediately()   -- zero velocity FIRST (the RootInPlace ordering rule)
            move:SetMovementMode(5, 0)       -- 5 = MOVE_Flying
        end
    end)

    -- Winch up: absolute per-step sets. NPC teleports are drain-safe (S2) and position replicates
    -- natively.
    for i = 1, SPEC_UP_STEPS do
        Utils.QueueWork(function()
            if Utils.IsActorInvalid(actor) or actor.IsDead then return abort() end
            local z = start.Z + SPEC_RISE_Z * (i / SPEC_UP_STEPS)
            pcall(function()
                actor:K2_SetActorLocationAndRotation(FVector(start.X, start.Y, z),
                    actor:K2_GetActorRotation(), false, {}, true)
            end)
        end, i * SPEC_STEP_MS)
    end

    -- Apex: gone. bHidden replicates; collision off = no free hits on an "ascended" body.
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) or actor.IsDead then return abort() end
        pcall(function()
            actor:SetActorHiddenInGame(true)
            Utils.MarkReplicatedDirty(actor, "bHidden")
            actor:SetActorEnableCollision(false)
        end)
    end, SPEC_UP_STEPS * SPEC_STEP_MS + 100)

    Utils.QueueWork(function()
        specDrop(actor, st, start, abort)
    end, SPEC_UP_STEPS * SPEC_STEP_MS + 100 + SPEC_HOLD_MS)
end


-- The DOWN half: pick a fresh LoS point near the target, teleport in at height, descend, close
-- the channel.
--   * Target re-read at drop time - it had 2s to move; no target left -> drop back where it
--     went up.
function specDrop(actor, st, fallback, abort)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return abort() end

    local target = AVU.GetCurrentTarget(actor)
    local dest, landZ = fallback, fallback.Z   -- fallback is already capsule-centre
    if Utils.IsActorValid(target) then
        local p = AVU.FindLosPoint(target, { Actor = actor, MinDist = SPEC_DROP_MIN,
            MaxDist = SPEC_DROP_MAX, Tries = 14, MaxZDelta = 800 })
        if p then dest, landZ = p, p.Z + SPEC_LAND_ZLIFT end
    end

    pcall(function()
        actor:K2_SetActorLocationAndRotation(FVector(dest.X, dest.Y, landZ + SPEC_RISE_Z),
            actor:K2_GetActorRotation(), false, {}, true)
        actor:SetActorHiddenInGame(false)
        Utils.MarkReplicatedDirty(actor, "bHidden")
        actor:SetActorEnableCollision(true)
    end)

    for i = 1, SPEC_DOWN_STEPS do
        Utils.QueueWork(function()
            if Utils.IsActorInvalid(actor) or actor.IsDead then return abort() end
            local z = landZ + SPEC_RISE_Z * (1 - i / SPEC_DOWN_STEPS)
            pcall(function()
                actor:K2_SetActorLocationAndRotation(FVector(dest.X, dest.Y, z),
                    actor:K2_GetActorRotation(), false, {}, true)
            end)
        end, i * SPEC_STEP_MS)
    end

    Utils.QueueWork(function()
        st.busy = false
        if Utils.IsActorInvalid(actor) then return end
        pcall(function()
            actor.IsPerformingSpawnFX = false
            Utils.MarkReplicatedDirty(actor, "IsPerformingSpawnFX")
            actor:OnRep_IsPerformingSpawnFX()   -- HOST rule: run the local end handler ourselves
        end)
        specReleaseStun(actor)   -- before the re-aggro, so the tree drops straight back into combat
        specRestoreMove(actor)
        local t = AVU.GetCurrentTarget(actor)
        if Utils.IsActorValid(t) then
            AVU.FaceTarget(actor, t)
            AVU.ForceAggro(actor, t)
        end
        LogDebug("Speculatores - dropped back in", SETTINGS.DEBUG_NPC_ACTIONS)
    end, SPEC_DOWN_STEPS * SPEC_STEP_MS + 100)
end


-- End the Flying pin: back to Falling so the pawn settles the last few uu and the movement
-- component lands it into Walking on its own (the GK_Heavy un-weld recipe).
function specRestoreMove(actor)
    if Utils.IsActorInvalid(actor) then return end
    pcall(function()
        local move = actor.CharacterMovement
        if IsValid(move) then
            move:StopMovementImmediately()
            move:SetMovementMode(3, 0)   -- 3 = MOVE_Falling
        end
    end)
end

return H
