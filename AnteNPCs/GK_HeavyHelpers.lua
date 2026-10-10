-- =======================================================================
-- Jotun helpers - the mount/rider + Rocketeer machinery behind AnteNPCs/GK_Heavy.lua
--   Full decode: AnNotes/AnteNPCs/GK_Heavy.md
--
-- MUST-KNOWS
--   * The LINK RECORD is the ONLY channel between the two defs, keyed by GetFullName. The
--     mount's OnDeath reads NUMBERS/flags out of it, never a stale wrapper.
--   * The rider's movement component is DEAD (the weld pin), so the controller can't rotate
--     it and the BT's opening TurnToFaceTarget never completes - aimRider turns it by hand.
--   * The LMG aims to a LOCATION regardless of yaw, so the arc is enforced by hand. Our own
--     RangedAttack_OnCooldown must be RELEASED by us - the native clear only re-arms after a
--     native fire, so a stuck hold reads as "fired once in ten opportunities".
--   * NPCData.RangeToRangedAttack is DEAD DATA in this build. Don't tune with it.
--   * Reload speed rides CustomTimeDilation, NOT the montage rate: Montage_SetPlayRate is
--     SERVER-LOCAL (clients would see a full-length reload). Safe hot - the reload locks in place.
--   * NEVER force-gib the dead rider to clear the saddle: its gib-salvage GenerateLootDrop
--     cold-loads inside our WorkQueue drain (S2 freeze). Detach the corpse instead.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local AVM = require("AnteUtils.AVMath")
local PROJ = require("AnteCore.Projectile")
local ASSETS = require("AnteCore.AssetManager")

local Log = Utils.Log
local LogDebug = Utils.LogDebug

local H = {}

-- Read at USE time, never cached: the flag is a world-load property and a def is shared.
local function byMode(t) return STATE.HardModeNoMercy and t.Hard or t.Normal end


-- =======================================================================
-- THE JOTUN PAIR  (mount + welded rider)
-- =======================================================================

local JOTUN_CLASS = ENUMS.NpcClasses["Gatekeeper_Heavy"]

-- Saddle weld (Spine1 is mid-back). Peccary bone space: -X up, -Y forward, Z lateral (its own
-- skeleton's sockets read the same way). The mount's 1.3 BodyScale multiplies the offset, so one
-- unit of seat is ~1.3 on screen.
local RIDER_SEAT = { Bone = "Spine1", Loc = FVector(-7, -35, 0), Rot = FRotator(0, 0, 0),
                     Scale = FVector(0.95, 0.95, 0.95) }

-- Firing arc: the Jotun only fires within 120 deg of the mount's facing.
local RIDER_ARC_DEG     = 120
local RIDER_MAX_YAW_DEG = 45

local RIDER_CORPSE_LINGER_MS = 4000   -- a rider that dies first detaches, then self-cleans

-- Mount body shield: runtime BodyShieldComponent (absorb) + the native shell visual, built the
-- ShieldPest way - the NPC's OWN mesh, leader-posed, energy-shield material, hidden, and
-- component-TAGGED "bodyshield" (the component finds its FX meshes by that tag). Peccary-shaped.
local MOUNT_BODYSHIELD   = true
local MOUNT_SHIELD_HP    = { Normal = 400, Hard = 500 }
local MOUNT_SHIELD_REGEN = 5
local BODYSHIELD_CLASS   = AVU.BODYSHIELD_CLASS
local SHIELD_SHELL_MESH  = ENUMS.Components.SK_PECCARY
local MASK_MESH          = ENUMS.Components.SK_SNIPER_HEAD   -- the ShieldPest mask (sniper helm)

local STEED_ABILITY_CARBUNCLE = 0
local STEED_ABILITY_CHARGE    = 1
local STEED_CHARGE = true   -- the Peccary charge stays on (the Jotun is Psychic immune)

-- CHARGE tuning - a laden peccary COMMITS to its line. TurnWhileStampeding is written exactly ONCE
-- (BeginPlay), so one false here holds for life. Full decode: AnNotes/AnteNPCs/GK_Heavy.md "Charge tuning".
local STEED_CHARGE_STEER  = false
local STEED_STAMPEDE_SECS = 4     -- 4
local STEED_CHARGE_CD     = 10    -- 12
local STEED_ACCELERATION  = { Normal = 500, Hard = 700 }   -- 1024
local STEED_YAW_RATE      = { Normal = 140, Hard = 180 }   -- 360

-- Speed is the ACCELERATION, not the stampede's WalkSpeed=4500 write (that's only a cap that never
-- binds below ~900). Boosted for the RUN ONLY - the walking value is what makes the mount turn wide.
local STEED_CHARGE_ACCEL  = 650   -- ~3250 top speed over a 5s run (500 gave ~2500)

-- RECOVERY stun: the frozen yaw is deliberate, not a side effect - combat facing here IS the
-- movement, so a rooted steed keeps its charge yaw, and the rider's arc gate then holds the LMG
-- shut for anything standing behind it. That's the window to shoot the Jotun in the back.
local STEED_STUN_MS = 2500

-- Head + torso, both riders. The Dismounted Jotun shares it so phase 2 is the same body: its
-- CarryHpFrac scales THIS number, so the two must stay matched per mode.
H.RIDER_HP = 400                                    -- 550
H.RIDER_HP_HARD = 525
-- Reload speed-up on the mounted rider, [HARD] only (CustomTimeDilation, mirrored to clients).
H.RIDER_HARD_RELOAD = 1.5
H.RIDER_SHIELD_COLOR = FVector(0.6, 0.2, 1)         -- purple theming

H.STEED_ASSETS = { JOTUN_CLASS, BODYSHIELD_CLASS, ENUMS.Effects.LIGHTNING_PURPLE, MASK_MESH,
                   SHIELD_SHELL_MESH, ENUMS.Components.M_ENERGY_SHIELD }

-- Link records - one per live pair, pruned on either death. A DESPAWNED mount just strands a
-- record; every wrapper read off it is guarded.
local links = {}        -- mount fullname -> { rider, mount, riderKey, alive, total, maxTotal }
local linkByRider = {}  -- rider fullname -> the same record

local gateSuppressed = {}   -- riders whose fire WE hold shut (the release matters - see header)

-- Tick-only, so the wrapper is the stable one the tick registration stored (Conventions 3) - and
-- self-collecting, which is why nothing clears it on death (the OnDeath wrapper is a DIFFERENT one
-- and the write would only add a key, the RocketeerCleanup lesson).
local steedCharging = setmetatable({}, { __mode = "k" })   -- steed -> was IsStampeding last sample


-- =======================================================================
-- STEED (the mount)
-- =======================================================================

-- [RENDERER] The shield's VISUAL shell. The component TAG is the whole wiring:
-- BodyShieldComponent.UpdateMaterials scans GetComponentsByTag(..., "bodyshield") and re-scans
-- while its cache is empty, so the shell registers whichever of the two lands first.
local function attachShieldShell(actor)
    if not MOUNT_BODYSHIELD then return end
    AVU.AttachShieldShell(actor, SHIELD_SHELL_MESH, { Color = H.RIDER_SHIELD_COLOR })
end


-- [RENDERER] Purple lightning over the back, the ShieldPest mask, the shield shell.
function H.SteedLook(actor)
    -- Renderer half of SteedLoadout's SetStaggerImmune (forced staggers still multicast).
    AVU.SkipStaggerAnim(actor)

    if not SETTINGS.GAMEPLAY.REDUCE_VISUALS then
        AVU.AttachNiagara(actor, ENUMS.Effects.LIGHTNING_PURPLE, "Spine2",
            { Scale = FVector(0.8, 0.8, 0.8) })
    end

    -- Static-pose attach (different skeleton, so no LeaderPose).
    AVU.AttachSkeletalMesh(actor, MASK_MESH, "Head",
        { Location = FVector(183, -22, 0), Rotation = FRotator(0, 270, 270), Scale = FVector(1.2, 1.2, 1.2) })

    attachShieldShell(actor)

    -- Calm the welded rider from the CARRIER's side too: the steed's tag usually decodes first, so
    -- this covers the window before the rider's own Visuals runs.
    AVU.CalmClientNpcPassengers(actor)
end


-- =======================================================================
-- GATEKEEPER PECCARY - the steed's look with nothing on its back (the Beholder's Rose Eye
-- summons these). Shares SteedLook's dressing minus everything that only exists for a passenger:
-- no shield shell, no rider calm, no stagger immunity.
-- =======================================================================

-- [RENDERER]
function H.GkPeccaryLook(actor)
    if not SETTINGS.GAMEPLAY.REDUCE_VISUALS then
        AVU.AttachNiagara(actor, ENUMS.Effects.LIGHTNING_PURPLE, "Spine2",
            { Scale = FVector(0.7, 0.7, 0.7) })
    end

    -- Static-pose attach (different skeleton, so no LeaderPose).
    AVU.AttachSkeletalMesh(actor, MASK_MESH, "Head",
        { Location = FVector(183, -22, 0), Rotation = FRotator(0, 270, 270), Scale = FVector(1.2, 1.2, 1.2) })
end


-- [AUTHORITY] Otherwise a plain peccary, but its charge is a committed line - no mid-run steering.
function H.GkPeccaryLoadout(actor)
    AVU.LockTaming(actor)   -- bespoke summon, no pet form -> not pheromone-tameable
    AVU.DisableAbility(actor, STEED_ABILITY_CARBUNCLE)
    AVU.ClearLoot(actor, true)   -- no drop; preserveGib, so a gib kill still leaves peccary parts

    -- COMMITS to its charge line, like the Steed. Written exactly once (BeginPlay reads it), so
    -- one false here holds for life.
    pcall(function() actor.TurnWhileStampeding = false end)

    AVU.AddBodyShield(actor, { Max = 100, Regen = 0, ShowFX = true })
end


function H.SteedLoadout(actor)
    AVU.LockTaming(actor)
    AVU.DisableAbility(actor, STEED_ABILITY_CARBUNCLE)
    if not STEED_CHARGE then AVU.DisableAbility(actor, STEED_ABILITY_CHARGE) end

    -- It carries the rider: a stagger stumble (incl. the weakness/Stopping-Power FORCED ones -
    -- see AVU.SkipStaggerAnim). SteedLook has the renderer half.
    AVU.SetStaggerImmune(actor)

    local move = actor.CharacterMovement
    if IsValid(move) then
        move.RotationRate = FRotator(0, byMode(STEED_YAW_RATE), 0)
        move.MaxAcceleration = byMode(STEED_ACCELERATION)
    end

    actor.TurnWhileStampeding = STEED_CHARGE_STEER
    actor.StampedeDuration = STEED_STAMPEDE_SECS
    actor.Cooldown_CombatAbility1 = STEED_CHARGE_CD
end


-- [AttachSubactor.OnConfigured, off-hook] Mutate the raw welded Heavy into its variant, sync teams.
local function riderConfigured(rider, mount)
    if Utils.IsActorInvalid(rider) or Utils.IsActorInvalid(mount) then return end

    -- The tag replicates, so clients decorate the rider like any variant.
    -- Lazy require - a top-level one cycles.
    require("AnteVariants.NpcManager").MutateActor("Jotun Rider", rider, {})

    -- FACTION SYNC. The pair ship on DIFFERENT native teams (they'd fight). ConfigureSubActor leaves
    -- a Rider's faction untouched, so rider.Faction IS the live row value - copy it onto the MOUNT.
    -- (NPCData.DefaultFaction reads nil here - don't use it.)
    local fac
    pcall(function() fac = rider.Faction end)
    if fac ~= nil then
        AVU.SetFaction(mount, fac)
    else
        Utils.LogBad("Jotun Rider - couldn't read rider Faction; mount keeps the Peccary team")
    end

    -- Face the mount's forward: AttachSubactor's Rotation opt is WORLD-space (the baked relative
    -- offset depends on the mount's spawn yaw). The saddle clamp keeps it there.
    pcall(function()
        local mrot = mount:K2_GetActorRotation()
        rider:K2_SetActorRotation(FRotator(0, mrot.Yaw, 0), false)
    end)

    -- rec.mount is read ONLY by the weld self-heal (live path, guarded); OnDeath reads numbers only.
    local rec = { rider = rider, mount = mount, riderKey = rider:GetFullName(), alive = true }
    links[mount:GetFullName()] = rec
    linkByRider[rec.riderKey] = rec
end


-- [AUTHORITY] Weld the rider on (riderConfigured then mutates it + syncs factions), then the shield.
function H.SteedReady(actor)
    AVU.AttachSubactor(actor, JOTUN_CLASS, RIDER_SEAT.Bone, {
        Location = RIDER_SEAT.Loc,
        Rotation = RIDER_SEAT.Rot,
        Scale = RIDER_SEAT.Scale,
        Rider = true,
        DeathLingerMs = RIDER_CORPSE_LINGER_MS,
        OnConfigured = function(child, parent) riderConfigured(child, parent) end,
    })

    if MOUNT_BODYSHIELD then
        -- Delayed so the shield lands after the spawn settles.
        Utils.QueueWork(function()
            AVU.AddBodyShield(actor, { Max = byMode(MOUNT_SHIELD_HP), Regen = MOUNT_SHIELD_REGEN, ShowFX = true })
        end, 800)
    end
end


-- [OnEnterCombat] Point the rider at the mount's target. MUST run off-hook - setting BT_CombatState
-- from inside OnRep_CombatState re-fires it and AVs.
function H.SteedEnterCombat(actor)
    if Utils.IsActorInvalid(actor) then return end
    local rec = links[actor:GetFullName()]
    if not rec or not rec.alive then return end
    local rider = rec.rider
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) or Utils.IsActorInvalid(rider) then return end
        if rider.IsDead then return end
        local inCombat = false
        pcall(function() inCombat = rider.CombatState == true end)
        if inCombat then return end
        local target = H.BbTarget(actor)
        if target then AVU.ForceAggro(rider, target) end
    end, 0)
end


-- [OnTick] THE CHARGE LOOP. IsStampeding's edges ARE the charge: rising swaps in the charge
-- acceleration, falling restores the walking value and starts the recovery stun. Watches the FLAG
-- rather than def.OnChargeImpact because a weakness-forced stagger cancels a charge without
-- detonating it (see AnNotes/AnteNPCs/GK_Heavy.md "Why H.SteedTick watches IsStampeding"). Airborne = no
-- root (MOVE_None mid-air would hover it) - it lands under its own gravity instead.
function H.SteedTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    if actor.IsDead then return "REMOVE" end

    local charging = false
    pcall(function() charging = actor.IsStampeding == true end)
    if charging == (steedCharging[actor] == true) then return end   -- nil reads as false: no stun at spawn
    steedCharging[actor] = charging

    local move = actor.CharacterMovement
    if IsValid(move) then
        pcall(function()
            move.MaxAcceleration = charging and STEED_CHARGE_ACCEL or STEED_ACCELERATION
        end)
    end
    if charging then return end

    -- The recovery. RootInPlace is the timed one of the four immobilisers: it token-guards its own
    -- restore, so no pairing to leak, and it leaves the BT ticking (a parked tree on a mount that
    -- is carrying a live turret is a bigger risk than a stun that ends 100ms late).
    local grounded = false
    if IsValid(move) then pcall(function() grounded = move:IsMovingOnGround() == true end) end
    if grounded then AVU.RootInPlace(actor, STEED_STUN_MS) end
    AVU.SuppressMelee(actor, STEED_STUN_MS)
    LogDebug("Jotun Steed - charge over, " .. STEED_STUN_MS .. "ms recovery", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- [OnDeath] The subactor self-cleanup destroys the welded rider; if it was still alive, summon the
-- walking replacement carrying its remaining HP.
function H.SteedDeath(actor)
    if Utils.IsActorInvalid(actor) then return end
    local key = actor:GetFullName()
    local rec = links[key]
    links[key] = nil
    if not rec then return end
    linkByRider[rec.riderKey] = nil
    if not rec.alive then return end

    local loc = actor:K2_GetActorLocation()
    if not loc or loc.X == 0 then return end

    local frac = 1
    if rec.total and rec.maxTotal and rec.maxTotal > 0 then
        frac = AVM.Clamp(rec.total / rec.maxTotal, 0.1, 1)
    end

    -- Log-level (rare): only fires on an actual death, not a despawn/stream-out. math.floor matters
    -- - %d on a float is a hard Lua 5.4 error, which would throw before the summon runs.
    Log(string.format("Jotun Steed died - summoning Dismounted Jotun (hp %d%%)",
        math.floor(frac * 100 + 0.5)))

    AVU.SummonVariant("Dismounted Jotun", loc, { CarryHpFrac = frac, SkipSpawnFX = true })
end


-- =======================================================================
-- RIDER (the saddle turret)
-- =======================================================================

-- Is `target` inside the mount's frontal arc (2D)? Point blank (<50uu) is always engageable.
local function targetInArc(mount, target, arcDeg)
    local ok, inArc = pcall(function()
        return AVM.InArc(mount:K2_GetActorLocation(), mount:GetActorForwardVector(),
                         target:K2_GetActorLocation(), (arcDeg or RIDER_ARC_DEG) / 2, 50)
    end)
    return ok and inArc == true
end


-- Suppress/allow the ranged attack by target bearing: HasRangedAttack gates the BT's attack branch,
-- RangedAttack_OnCooldown holds the current loop.
--   * TRANSITION-AWARE: when the arc re-opens we RELEASE the hold we set (header). The mount turning
--     toward its target is what re-opens the arc.
local function gateRiderFire(actor, mount, target, arcDeg)
    local allow = true
    if mount and target then allow = targetInArc(mount, target, arcDeg) end
    local key = actor:GetFullName()
    pcall(function()
        local npcData = actor.NPCData
        if IsNotValid(npcData) then return end
        if allow then
            if npcData[ENUMS.NpcData.HasRangedAttack] ~= true then
                npcData[ENUMS.NpcData.HasRangedAttack] = true
            end
            if gateSuppressed[key] then
                gateSuppressed[key] = nil
                actor.RangedAttack_OnCooldown = false   -- release OUR hold only
                LogDebug("Jotun Rider fire gate OPEN", SETTINGS.DEBUG_NPC_ACTIONS)
            end
        else
            npcData[ENUMS.NpcData.HasRangedAttack] = false
            actor.RangedAttack_OnCooldown = true
            if not gateSuppressed[key] then
                gateSuppressed[key] = true
                LogDebug("Jotun Rider fire gate CLOSED (target outside arc)", SETTINGS.DEBUG_NPC_ACTIONS)
            end
        end
    end)
end


-- Drive the rider's AIM by hand (header: the controller can't), clamped to +/-maxYawDeg of the
-- mount's facing; idle settles forward. Server-side; clients see the replicated pose.
local function aimRider(rider, mount, target, maxYawDeg)
    local clamp = maxYawDeg or RIDER_MAX_YAW_DEG
    pcall(function()
        local my = mount:K2_GetActorRotation().Yaw
        local desired = my
        if target and Utils.IsActorValid(target) then
            desired = AVM.YawTo(rider:K2_GetActorLocation(), target:K2_GetActorLocation())
        end
        local diff = AVM.Clamp(AVM.AngleDiff(desired, my), -clamp, clamp)
        rider:K2_SetActorRotation(FRotator(0, my + diff, 0), false)
    end)
end


-- Re-assert the weld pin: the Heavy's fire path (and the AI freeze/unfreeze) sets MOVE_None and
-- RESTORES walking after - with zero gravity that drift read as "teleports around / stuck in air".
--   * Defense in depth: DefaultLandMovementMode=None makes the native restores land back on the
--     pin, and the component stays DEACTIVATED so nothing drives the root between re-asserts.
local function reassertPin(actor)
    pcall(function()
        local move = actor.CharacterMovement
        if IsNotValid(move) then return end
        if move.MovementMode ~= 0 then
            move:StopMovementImmediately()
            move:SetMovementMode(0, 0)   -- MOVE_None
        end
        if move.GravityScale ~= 0 then move.GravityScale = 0 end
        if move.DefaultLandMovementMode ~= 0 then move.DefaultLandMovementMode = 0 end
        if move:IsActive() then move:Deactivate() end
    end)
end


-- Snap the rider back onto the saddle past a drift threshold (warps/CMC moves shift the root and
-- attachment then keeps the NEW offset).
local function reweldRider(rider, seat)
    seat = seat or RIDER_SEAT.Loc
    pcall(function()
        local root = rider.RootComponent
        if IsNotValid(root) then return end
        local distSq = Utils.DistSq(root.RelativeLocation, seat)
        if distSq > 50 * 50 then
            rider:K2_SetActorRelativeLocation(seat, false, {}, true)
            LogDebug(string.format("Welded rider re-seated (drift %d)", math.floor(math.sqrt(distSq))),
                SETTINGS.DEBUG_NPC_ACTIONS)
        end
    end)
end


-- Detach the dead rider so the corpse can't float in the saddle (the pin holds it at zero gravity
-- on a MOVING bone). The ragdoll then falls on its own; subactor cleanup destroys it after
-- DeathLingerMs. Gravity/CMC restored as a non-ragdoll fallback. No loot path touched (NEVER
-- force-gib - header). Deferred a beat so the native death sequence has begun.
local function detachRiderCorpse(actor)
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) then return end
        -- KeepWorld on all three rules, so the corpse stays where it died as it detaches.
        pcall(function() actor:K2_DetachFromActor(1, 1, 1) end)
        pcall(function()
            local move = actor.CharacterMovement
            if IsValid(move) then
                move:Activate(true)
                move.GravityScale = 1
                move.DefaultLandMovementMode = 1   -- MOVE_Walking
                move:SetMovementMode(3, 0)         -- MOVE_Falling -> it drops to the ground
            end
        end)
    end, 150)
end


-- Current target from the controller's blackboard ("TargetActor" = the key the AI stack uses).
-- AVU.GetBlackboardTarget IS this read (raw, past GetCurrentTarget's deployable/door hiding).
H.BbTarget = AVU.GetBlackboardTarget


-- [OnEnterCombat] Drag the mount into the fight too. MUST be deferred - setting BT_CombatState from
-- inside OnRep_CombatState re-fires it and AVs.
function H.RiderEnterCombat(actor)
    if Utils.IsActorInvalid(actor) then return end
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        local mount
        pcall(function() mount = actor:GetAttachParentActor() end)
        if not mount or Utils.IsActorInvalid(mount) or Utils.IsDeadSafe(mount) then return end
        local inCombat = false
        pcall(function() inCombat = mount.CombatState == true end)
        if inCombat then return end
        local target = H.BbTarget(actor)
        if target then AVU.ForceAggro(mount, target) end
    end, 0)
end


-- [OnTick] The turret loop. 0.2s: aim + arc gate. 1s: re-assert the pin, self-heal the weld.
-- 2s: snapshot HP numbers for the dismount carry-over.
function H.RiderTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    if actor.IsDead then return "REMOVE" end
    if totalTicks % 2 ~= 0 then return end

    -- Live query, never a stored wrapper. Nil (bad bone / ragdoll-detach / directly-spawned turret)
    -- fails OPEN: fire freely, no clamp.
    local mount
    pcall(function() mount = actor:GetAttachParentActor() end)
    if mount and (Utils.IsActorInvalid(mount) or Utils.IsDeadSafe(mount)) then mount = nil end

    -- SELF-HEALING WELD. Unstuck-warps shift the root and the attachment never restores the offset.
    -- Detached entirely -> re-attach to the linked mount; drifted -> reweldRider snaps it back.
    if not mount then
        local rec = linkByRider[actor:GetFullName()]
        local m = rec and rec.mount
        if m and Utils.IsActorValid(m) and not Utils.IsDeadSafe(m) then
            local mesh = Utils.GetValidMesh(m)
            if mesh then
                pcall(function()
                    actor:K2_AttachToComponent(mesh, FName(RIDER_SEAT.Bone), 0, 0, 0, true)
                    actor:K2_SetActorRelativeLocation(RIDER_SEAT.Loc, false, {}, true)
                end)
                mount = m
                LogDebug("Jotun Rider re-attached to its steed", SETTINGS.DEBUG_NPC_ACTIONS)
            end
        end
    end

    local target = H.BbTarget(actor)
    if mount then aimRider(actor, mount, target) end
    gateRiderFire(actor, mount, target)

    if totalTicks % 10 == 0 then
        reassertPin(actor)
        if mount then reweldRider(actor) end
    end

    if totalTicks % 20 == 0 then
        local rec = linkByRider[actor:GetFullName()]
        if rec then
            pcall(function()
                local total = actor:GetTotalHealth()
                if total and total > 0 then
                    rec.total = total
                    if not rec.maxTotal or total > rec.maxTotal then rec.maxTotal = total end
                end
            end)
        end
    end
end


-- [OnDeath] Died in the saddle: flag the link (blocks the dismount summon) and detach the corpse.
-- Native loot already dropped at the death location; the mount fights on.
function H.RiderDeath(actor)
    if Utils.IsActorInvalid(actor) then return end
    local key = actor:GetFullName()
    gateSuppressed[key] = nil
    local rec = linkByRider[key]
    if rec then
        rec.alive = false
        linkByRider[key] = nil
    end
    detachRiderCorpse(actor)
end


-- =======================================================================
-- SHARED WELDED-TURRET UPKEEP - exported for the DarkLens "Jotun of the Fallow" mount
-- (AnteNPCs/GK_DarkLensJotunHelpers), which hits the same weld/aim/fire-arc hazards (pin drift,
-- an un-turnable rider stalling at TurnToFaceTarget, a *_OnCooldown hold only WE clear).
-- Each takes the caller's own geometry; omitted args keep the Jotun Rider's numbers.
-- =======================================================================
H.ReassertPin = function(actor) reassertPin(actor) end
H.AimRider    = function(rider, mount, target, maxYawDeg) aimRider(rider, mount, target, maxYawDeg) end
H.GateRiderFire = function(rider, mount, target, arcDeg) gateRiderFire(rider, mount, target, arcDeg) end
H.ReweldRider = function(rider, seat) reweldRider(rider, seat) end

-- Drop the fire-gate bookkeeping for an actor (death / dismount). The gate keys by FULLNAME, and a
-- string key can't be weak-collected.
function H.ClearRiderGate(actor)
    pcall(function() gateSuppressed[actor:GetFullName()] = nil end)
end


-- [RENDERER] Proxy calm for the welded rider - the MP anti-stutter: the local copy's own movement
-- tick, mesh smoothing and capsule collision all fight the replicated attachment, and the authority
-- pin is per-machine state that doesn't replicate. (AnNotes/AnteNPCs/GK_Heavy.md)
function H.CalmClientProxy(actor)
    pcall(function()
        local move = actor.CharacterMovement
        if IsValid(move) then
            move.NetworkSmoothingMode = 0   -- Disabled - no interpolation fighting the weld
            move:StopMovementImmediately()
            move:SetMovementMode(0, 0)      -- MOVE_None
            move.GravityScale = 0
            move:Deactivate()
        end
        local cap = actor.CapsuleComponent
        if IsValid(cap) then
            cap:SetCollisionEnabled(1)                -- QueryOnly
            cap:SetCollisionResponseToChannel(2, 1)   -- Pawn -> Overlap (local sweeps)
        end
        -- The mount's LOCAL proxy must also ignore the rider when it moves (the server MoveIgnore
        -- list does not replicate - the Flask Rat lesson).
        local mount = actor:GetAttachParentActor()
        if IsValid(mount) and IsValid(mount.CapsuleComponent) then
            mount.CapsuleComponent:IgnoreActorWhenMoving(actor, true)
        end
    end)
end


-- =======================================================================
-- JOTUN ROCKETEER
-- =======================================================================

-- RANGED WEAPON (replaces the LMG). Row is a knob: SmgFireball = red igniting bolt, PlasmaBall =
-- the same in blue, QuillSpear = Exor spear. Exported - the def's Stats sets the same row.
--   * The two MS delays must SUM to less than the fire gap, or each bolt's tail lands after the
--     next was due and the chain fights itself.
H.BOMBARD_GUN_ROW = ENUMS.ProjectileRows.SmgFireball
local BOMBARD_GUN_ROW       = H.BOMBARD_GUN_ROW
local BOMBARD_RANGED_DMG    = 60    -- fallback only; fireBolt prefers the live NPCData value
local BOMBARD_FIRE_DELAY_MS = 100   -- windup before the bolt
local BOMBARD_FIRE_RESET_MS = 80    -- before the BT ranged task is released

-- CADENCE = FLAT AND FAST on purpose (the LMG loop always SOUNDS like rapid fire, so the gun
-- matches the noise): one bolt per gap tick, magazine = the burst, RELOAD = the real pacing.
-- Why, plus the removed spin-up ramp: AnNotes/AnteNPCs/GK_Heavy.md.
local BOMBARD_FIRE_GAP_TICKS = 2   -- 0.2s per bolt = 5/sec

-- The reload's time-dilation boost is dropped the moment the clip refills (or at this cap).
local BOMBARD_RELOAD_CAP_TICKS = 80    -- 8s failsafe if the refill signal is missed

-- LMG FX (applied per-machine in Visuals; see H.ReskinLmgFx + AnNotes/AnteNPCs/GK_Heavy.md).
local BOMBARD_LMG_FIRE_CUE = ENUMS.SOUNDS.SMG_U1_FIRE   -- nil = leave the native LMG bark alone
local BOMBARD_MUTE_MUZZLE  = true   -- it fires at 10Hz off one projectile; the tracer already reads

-- MORTAR. Ballistic lob on a distance-scaled flight time (near = flatter).
--   * THE CLAMP IS THE TUNING KNOB, not MORTAR_HORIZ_SPEED: past ~horiz 2400 every shell is pinned
--     at FLIGHT_MAX. Raise the clamps to slow the shells - but apex scales with t^2, so a long
--     indoor lob then clips ceilings. Full note: AnNotes/AnteNPCs/GK_Heavy.md.
local MORTAR_CLASS       = ENUMS.ProjectileClasses.MortarDefenseBot
local MORTAR_DMG         = { Normal = 60, Hard = 90 }   -- per shell (it also carries a baked AoE min)
local MORTAR_SHOTS       = 2     -- per volley, staggered, each re-aiming (a walking barrage)
local MORTAR_SHOT_GAP_MS = 700
local MORTAR_LAUNCH_SIDE = 28    -- left/right launch offset per shell (twin nozzles)
local MORTAR_CD_TICKS    = { Normal = 100, Hard = 70 }   -- ~10s / 7s between volleys
local MORTAR_MIN_RANGE   = 1000
local MORTAR_MAX_RANGE   = 9000
local MORTAR_FIRST_DELAY_TICKS = 30
local MORTAR_HORIZ_SPEED = 650   -- 950 (only shapes the near end of the band; see above)
local MORTAR_FLIGHT_MIN, MORTAR_FLIGHT_MAX = 1.6, 3.2
local MORTAR_LAUNCH_UP   = 190   -- launch above the body (clears it)
local MORTAR_LAND_DROP   = 80    -- aim at the target's feet
local MORTAR_ARM_MS      = 150   -- grace before ExplodesOnContact re-arms (clears the launcher)

-- Warmed right before each lob (a def.Assets preload doesn't stick - S3).
local MORTAR_DEPS = { MORTAR_CLASS, ENUMS.DamageType.ExplosiveDefenseBot, ENUMS.Components.SM_MORTAR_SHELL,
                      ENUMS.Effects.EXPLOSION_BIG_2, ENUMS.SOUNDS.MORTAR_FIRE, ENUMS.Effects.MUZZLE_FLASH }

-- ROCKET PACK - the jetpack mesh, so it can be recoloured. FRotator is (Pitch, Yaw, Roll): Pitch 180
-- = upside-down (tubes up); YAW 90 seats it flat ON the back (yaw composes last, swinging the
-- already-flipped pack about the socket's vertical) - without it the pack bisects the torso.
local PACK_MESH     = ENUMS.Components.SM_JETPACK
local PACK_MATERIAL = ENUMS.Components.M_BACKPACK_SMALL_RED
local PACK_LOC, PACK_ROT, PACK_SCALE = FVector(0, 0, -15), FRotator(0, 90, 180), FVector(1.2, 1.2, 1.2)
local PACK_BONE_FALLBACK = "spine2"

H.ROCKETEER_ASSETS = { table.unpack(MORTAR_DEPS) }
H.ROCKETEER_ASSETS[#H.ROCKETEER_ASSETS + 1] = PACK_MESH
H.ROCKETEER_ASSETS[#H.ROCKETEER_ASSETS + 1] = PACK_MATERIAL
H.ROCKETEER_ASSETS[#H.ROCKETEER_ASSETS + 1] = ENUMS.ProjectileClasses.SmgFireball
H.ROCKETEER_ASSETS[#H.ROCKETEER_ASSETS + 1] = ENUMS.SOUNDS.SMG_U1_FIRE   -- H.ReskinLmgFx needs it RESIDENT

local lastMortarTick = setmetatable({}, { __mode = "k" })   -- tick-only: same stored wrapper each tick

-- Gun cadence state keyed by FULLNAME string, not the wrapper: a wrapper key never hit across hooks,
-- so the throttle no-op'd and the gun had no gate at all ([[anteup2-actor-wrapper-identity]]).
-- String keys can't be weak-collected -> all cleared on death.
local lastBoltTick = {}   -- tick of the last bolt
local fireHeld     = {}   -- actors whose ranged branch WE are holding shut
local backpackDone = {}   -- attach-once guard

-- Tick the current reload's time-dilation boost began. Exported: the def's OnReload arms it,
-- holdReloadDilation below disarms it.
H.ReloadStart = {}
local reloadStart = H.ReloadStart


-- =======================================================================
-- ROCKETEER GUN + FX
-- =======================================================================

-- [RENDERER] Jetpack on the native backpack slot: read that comp's socket so the mesh sits where the
-- game puts a pack, hide it, attach the jetpack (recoloured via material).
function H.AttachRocketPack(actor)
    if Utils.IsActorInvalid(actor) then return end
    local fn; pcall(function() fn = actor:GetFullName() end)
    if not fn or backpackDone[fn] then return end
    backpackDone[fn] = true

    local bone = PACK_BONE_FALLBACK
    pcall(function()
        local bp = actor.backpack
        if IsValid(bp) then
            local s = bp:GetAttachSocketName()
            local n = s and s:ToString()
            if n and n ~= "" and n ~= "None" then bone = n end
            bp:SetVisibility(false, false)
        end
    end)

    AVU.AttachStaticMesh(actor, PACK_MESH, bone,
        { Location = PACK_LOC, Rotation = PACK_ROT, Scale = PACK_SCALE, Material = PACK_MATERIAL })
    LogDebug("Jotun Rocketeer - jetpack attached (" .. bone .. ")", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- Keep the BT's ranged branch shut for the rest of this bolt's gap.
--   * MUST be re-asserted per tick: SetRangedAttackOnCooldown arms a RetriggerableDelay on
--     RangedAttack_Cooldown, which the Heavy's LMG loop pins at 0.1s - a one-shot write self-clears.
--   * And WE must clear it: once held true the BT stops calling SetRangedAttackOnCooldown, so
--     nothing re-arms the native clear and it sticks forever (the Rider's gateSuppressed bug).
local function holdRangedGate(actor)
    local key = Utils.ActorKey(actor)
    if not key then return end
    local last = lastBoltTick[key]

    if last and (STATE.FAST_TICK - last) < BOMBARD_FIRE_GAP_TICKS then
        fireHeld[key] = true
        pcall(function() actor.RangedAttack_OnCooldown = true end)
    elseif fireHeld[key] then
        fireHeld[key] = nil
        pcall(function() actor.RangedAttack_OnCooldown = false end)
    end
end


-- Drop the reload's time-dilation boost the moment it lands. No "reload ended" hook exists, so we
-- watch Broadcast_ReloadWeapon's ammo refill (armed only from OnReload, so a full clip can't
-- false-positive); the cap is a failsafe for an interrupted montage. `restoreTo` is the CALLER'S
-- BASELINE (not necessarily 1.0), so a permanently-fast late-phase boss isn't snapped back to normal.
local function holdReloadDilation(actor, capTicks, restoreTo)
    local key = Utils.ActorKey(actor)
    if not key then return end
    local started = reloadStart[key]
    if not started then return end

    local full = false
    pcall(function() full = actor.CurrentAmmoCount >= actor.MaxAmmoCount end)
    if not full and (STATE.FAST_TICK - started) < (capTicks or BOMBARD_RELOAD_CAP_TICKS) then return end

    reloadStart[key] = nil
    AVU.SetTimeDilation(actor, restoreTo or 1.0)
end

-- Exported for the DarkLens Jotun, which speeds its reload the same way (the montage rate is
-- SERVER-LOCAL, so CustomTimeDilation + MirrorTimeDilation is the only lever a client also sees).
-- Arm it from def.OnReload by stamping H.ReloadStart[key]; this drops the boost when the clip
-- refills. Both fights share H.ReloadStart, which is keyed by ActorKey - no collision.
H.HoldReloadDilation = function(actor, capTicks, restoreTo)
    holdReloadDilation(actor, capTicks, restoreTo)
end


-- [RENDERER] Reskin the LMG's fire FX (self-sustaining fire loop: AnNotes/AnteNPCs/GK_Heavy.md).
--   * MuzzleFlashFX is the one member BOTH spawn sites read (Grunt Gun, Heavy LMG) - nilling covers
--     both; SpawnSystemAttached with a null system is a no-op.
--   * The cue is CHANGED on the persistent LMG_Fire_Cue component, never muted - a cold/GC'd cue
--     leaves the native bark alone, so clearing the sound on a miss would silence the gun entirely.
function H.ReskinLmgFx(actor)
    if Utils.IsActorInvalid(actor) then return end
    if BOMBARD_MUTE_MUZZLE then pcall(function() actor.MuzzleFlashFX = nil end) end
    if not BOMBARD_LMG_FIRE_CUE then return end
    pcall(function()
        local comp = actor.LMG_Fire_Cue
        if IsNotValid(comp) then return end
        local cue = ASSETS.GetIfValid(BOMBARD_LMG_FIRE_CUE)
        if IsNotValid(cue) then return end
        comp:SetSound(cue)
        comp:SetVolumeMultiplier(1)
    end)
end


-- One ranged bolt from the weapon socket: pin aim (FireRanged_Projectile aims muzzle ->
-- LastRangedAttackLocation), fire via the GrenadeData handle, release the BT task.
--   * No cooldown bookkeeping here - the hold belongs to holdRangedGate (writing
--     RangedAttack_Cooldown wouldn't stick; the Heavy's LMG loop overwrites it every iteration).
local function fireBolt(actor)
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return end

    local target = actor:GetCurrentCombatTarget()
    local aim
    if Utils.IsActorValid(target) then
        pcall(function() aim = target:K2_GetActorLocation() end)
    end
    local dmg = BOMBARD_RANGED_DMG
    pcall(function() dmg = actor.NPCData[ENUMS.NpcData.RangedDamage] or dmg end)

    AVU.FireProjectileRow(actor, BOMBARD_GUN_ROW, dmg, aim)   -- no restore: the row swap is permanent
    Utils.QueueWork(function() AVU.ReleaseSoldierBT(actor) end, BOMBARD_FIRE_RESET_MS)
end


-- =======================================================================
-- ROCKETEER MORTAR
-- =======================================================================

-- One mortar shell (AUTHORITY). Launches above the body, offset left/right; ExplodesOnContact is
-- disarmed pre-Finish and re-armed after MORTAR_ARM_MS so the shell clears the launcher first.
local function launchShell(actor, target, side)
    if Utils.IsActorInvalid(actor) or actor.IsDead or Utils.IsActorInvalid(target) then return end
    local al, tl = actor:K2_GetActorLocation(), target:K2_GetActorLocation()
    if not al or not tl then return end

    local right; pcall(function() right = actor:GetActorRightVector() end)
    local L = FVector(al.X + (right and right.X or 0) * side * MORTAR_LAUNCH_SIDE,
                      al.Y + (right and right.Y or 0) * side * MORTAR_LAUNCH_SIDE, al.Z + MORTAR_LAUNCH_UP)
    local T = FVector(tl.X, tl.Y, tl.Z - MORTAR_LAND_DROP)

    local t = AVM.LobFlightTime(L, T, MORTAR_HORIZ_SPEED, MORTAR_FLIGHT_MIN, MORTAR_FLIGHT_MAX)
    local vel = AVM.LobVelocity(L, T, t)   -- ProjectileGravityScale 1 (the Gravity opt below)

    ASSETS.LoadAsync(MORTAR_DEPS, function()
        if Utils.IsActorInvalid(actor) or actor.IsDead or not Utils.IsActorReadyToAttack(actor) then return end

        -- Launch tell (all machines): the defense-bot fire cue + a muzzle puff. scale = FVector (S6).
        AVU.BroadcastFX(L, ENUMS.Effects.MUZZLE_FLASH, ENUMS.SOUNDS.MORTAR_FIRE, FVector(1.5, 1.5, 1.5))

        PROJ.SpawnGrenade(actor, MORTAR_CLASS, {
            Label = "Jotun Rocketeer mortar", Location = L, AlignToVelocity = true,
            Velocity = vel, MaxSpeed = 999999, Gravity = 1, Damage = byMode(MORTAR_DMG),
            ArmContactMs = MORTAR_ARM_MS,
            PreFinish = function(proj)
                pcall(function() proj.ExplodesOnContact = false end)
                pcall(function() proj.ExplodesOnContactWithCharacter = false end)
            end,
        })
    end)
end


-- A volley of shells, staggered, alternating the left/right launch offset.
local function fireMortar(actor, target)
    for i = 0, MORTAR_SHOTS - 1 do
        local side = (i % 2 == 0) and 1 or -1
        Utils.QueueWork(function() launchShell(actor, target, side) end, i * MORTAR_SHOT_GAP_MS)
    end
end


-- [OnRangedAttack] Fire the bolt in place of the suppressed LMG. Manual gate: under the override the
-- BT re-triggers faster than RangedAttack_Cooldown holds, so the gap tick is the real rate of fire.
function H.RocketeerRangedAttack(actor)
    if Utils.IsActorInvalid(actor) then return end
    local key = Utils.ActorKey(actor)
    if not key then return end
    if not AVU.CooldownReady(lastBoltTick, key, BOMBARD_FIRE_GAP_TICKS) then return end

    -- Shut the BT's ranged branch for the gap (holdRangedGate re-asserts it from the tick). Without
    -- the hold the BT free-runs and Broadcast_DoRangedAttackFX outpaces the bolts behind it.
    fireHeld[key] = true
    pcall(function() actor.RangedAttack_OnCooldown = true end)

    Utils.QueueWork(function() fireBolt(actor) end, BOMBARD_FIRE_DELAY_MS)
end


-- [OnTick] Mortar loop (an ADD-ON to the native BT): every MORTAR_CD_TICKS a target inside the
-- artillery band gets a volley. Also owns the fire/reload gates.
function H.RocketeerTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    if actor.IsDead then return end

    holdRangedGate(actor)        -- EVERY tick (10Hz) - the native clear runs at 0.1s
    holdReloadDilation(actor)

    if totalTicks % 5 ~= 0 then return end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) or not Utils.IsActorReadyToAttack(actor) then return end

    local al, tl = actor:K2_GetActorLocation(), target:K2_GetActorLocation()
    if not al or not tl then return end
    local dsq = Utils.DistSq(al, tl)
    if dsq < MORTAR_MIN_RANGE ^ 2 or dsq > MORTAR_MAX_RANGE ^ 2 then return end

    -- FirstDelay = the opening grace before the first volley (CooldownReady persists that seed).
    if not AVU.CooldownReady(lastMortarTick, actor, byMode(MORTAR_CD_TICKS),
                             { FirstDelay = MORTAR_FIRST_DELAY_TICKS }) then return end
    fireMortar(actor, target)
end


-- [OnDeath] State cleanup. Must NOT be able to skip the caller's loot drop - an unreadable key used
-- to `return` right past it (the bug that left the Dismounted Jotun dropping nothing).
function H.RocketeerCleanup(actor)
    -- No lastMortarTick clear: it is WEAK-keyed by the wrapper, and the wrapper we get HERE is a
    -- different one than the tick stored - so the write only ever added a fresh key. It self-collects.
    local key = Utils.ActorKey(actor)
    if key then
        lastBoltTick[key] = nil
        fireHeld[key]     = nil
        reloadStart[key]  = nil
    end
end

return H
