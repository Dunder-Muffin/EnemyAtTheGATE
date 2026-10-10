-- =======================================================================
-- Exor helpers - the machinery behind AnteNPCs/Exor.lua: the Antegrav/Antefire gravity-flip
-- cycle, the Antefire scripted plasma bolt, the reload seeker quill (Antegrav + Exor Superior),
-- and the Magma/Antefire mortar lob.
--
-- MUST-KNOWS
--   * gravTick/gravOnHit are shared by BOTH gravity variants - one function, two OnTick refs.
--   * reloadArmOrigin is the shared muzzle for anything thrown "out of the reload arm" (seeker
--     quill, both mortars).
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local AVM = require("AnteUtils.AVMath")
local PROJ = require("AnteCore.Projectile")
local ProjectileRows = require("AnteCore.ProjectileRows")

local LogDebug = Utils.LogDebug

local H = {}


-- =======================================================================
-- GRAVITY CYCLE - Antegrav + Antefire Exor share this: ceiling in combat while the target is
-- close and in sight, ground otherwise, plus a hit-triggered coin-flip.
-- =======================================================================

local GRAV_CHECK_TICKS = 15         -- reassess gravity every N ticks
local FLIP_CYCLE_TICKS = 50         -- periodic flip cadence while in combat
local FLIP_COOLDOWN_TICKS = 25      -- hit-triggered flip cooldown
local FLIP_MIN_DAMAGE = 30          -- a hit below this never flips (DoT ticks, chip damage)
local FAR_TARGET_SQ = 3000 * 3000   -- drop to the ground once the target is farther than this

local lastGravFlipTick = {}   -- actor key -> FAST_TICK of the last hit-triggered gravity flip
-- actor key -> { Tick, Up }: the hit flip that last re-anchored the combat cycle, so the cycle
-- continues that flip's direction for a full half-cycle instead of reversing it mid-transit.
local cycleAnchor = {}

-- Between surfaces: a body that has not landed yet is left alone by every flip path, so a flip
-- is always a full transit and never a reversal in mid-air.
local function inTransit(move)
    local falling = false
    pcall(function() falling = move:IsFalling() end)
    return falling
end


-- Out of combat: stick to the floor. In combat: flip on a cycle, but only while the target is
-- close and in sight - never strand it ceiling-bound on a target it can no longer reach.
local function gravTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end

    local move = actor.CharacterMovement
    if IsNotValid(move) then return end

    -- Runs above the modulo gate - a ceiling probe in flight owns the body until it resolves.
    if AVU.CeilingVerifyTick(actor, totalTicks) then return end
    if totalTicks % GRAV_CHECK_TICKS ~= 0 then return end

    local onCeiling = move.GravityDirection.Z > 0

    if not actor.CombatState then
        if onCeiling then AVU.SetCeilingGravity(actor, false) end
        return
    end

    local target = actor:GetCurrentCombatTarget()
    local canCeiling = false
    if Utils.IsActorValid(target) then
        local loc = actor:K2_GetActorLocation()
        local targetClose = Utils.DistSq(loc, target:K2_GetActorLocation()) <= FAR_TARGET_SQ
        -- From the body's centre: on the ceiling the pawn's eye point is on the wrong side of it.
        canCeiling = targetClose and AVU.CanSeeActor(actor, target, loc)
    end

    if not canCeiling then
        if onCeiling then AVU.SetCeilingGravity(actor, false) end   -- drop to engage
        return
    end

    if inTransit(move) then return end

    local anchor = cycleAnchor[Utils.ActorKey(actor) or ""]
    local since = anchor and (STATE.FAST_TICK - anchor.Tick) or totalTicks
    local evenPhase = (math.floor(since / FLIP_CYCLE_TICKS) % 2) == 0
    local wantCeiling
    if anchor then wantCeiling = (evenPhase == anchor.Up) else wantCeiling = evenPhase end
    if wantCeiling and not onCeiling then
        if AVU.CeilingKnownBad(actor:K2_GetActorLocation()) then return end   -- a probe already ruled this spot out
        AVU.SetCeilingGravity(actor, true)
    elseif (not wantCeiling) and onCeiling then
        AVU.SetCeilingGravity(actor, false)
    end
end


-- 50% chance to reverse current gravity on a REAL hit: FLIP_MIN_DAMAGE or more, on a body that
-- has landed. Bleed and burn ticks arrive every ~2.5s, the same as the cooldown, so without the
-- floor a bleeding Exor flipped on nearly every tick and never reached either surface.
-- Peek + stamp-on-success: a failed coin flip must not consume the cooldown, or a rapid-fire
-- weapon flips it many times a second.
local function gravOnHit(victim, label, damage)
    if Utils.IsActorInvalid(victim) then return end
    if (tonumber(damage) or 0) < FLIP_MIN_DAMAGE then return end

    local vkey = Utils.ActorKey(victim)
    if not vkey then return end
    local now = STATE.FAST_TICK
    if not AVU.CooldownReady(lastGravFlipTick, vkey, FLIP_COOLDOWN_TICKS, { Peek = true }) then return end

    local move = victim.CharacterMovement
    if IsNotValid(move) then return end
    if inTransit(move) then return end

    if math.random(0, 100) < 50 then
        local goUp = not (move.GravityDirection.Z > 0)
        if goUp and AVU.CeilingKnownBad(victim:K2_GetActorLocation()) then return end
        lastGravFlipTick[vkey] = now
        cycleAnchor[vkey] = { Tick = now, Up = goUp }
        AVU.SetCeilingGravity(victim, goUp)
        LogDebug(label .. " - gravity reversed on hit", SETTINGS.DEBUG_NPC_ACTIONS)
    end
end


-- The raised reload-arm socket, so anything thrown here reads as leaving the arm mid-reload.
-- Falls back to above the body when the socket can't be resolved.
local function reloadArmOrigin(actor)
    local mesh = Utils.GetValidMesh(actor)
    if mesh then
        local ok, loc = pcall(function() return mesh:GetSocketLocation(FName("r_arm2_end")) end)
        if ok and loc then return loc end
    end
    local l = actor:K2_GetActorLocation()
    return FVector(l.X, l.Y, l.Z + 120)
end


-- =======================================================================
-- ANTEFIRE PRIMARY FIRE - the native gun, pointed at a custom row.
--   * FireRanged_Projectile builds the shot entirely off its DT_Projectiles row, and the stock
--     plasma row flies at 5500. The slower bolt used to mean skipping the native spawn (an
--     invalid row bails at its row lookup) and firing our own - which also skipped ConsumeAmmo,
--     so the clip never emptied and the BT never reloaded. A cloned row at 1800
--     (AnteCore/ProjectileRows) keeps the whole beat native: spawn, ammo, replication.
--   * The scripted bolt below is the FALLBACK, taken only when the row is not ready (old UE4SS):
--     H.AntefireProjectile blanks the native row and H.AntefireRangedAttack fires this instead.
-- =======================================================================

local ANTEFIRE_BOLT = {
    Class    = ENUMS.ProjectileClasses.PlasmaBall,
    Speed    = 1800,   -- native row speed 5500
    LifeSpan = 6,      -- Exor's ranged range is 500m; don't let a miss fly forever
    -- Set explicitly rather than racing the row's own latent load - a cold type lands untyped.
    DamageType = ENUMS.DamageType.FirePlasma,
    Deps = {
        ENUMS.DamageType.FirePlasma,
        ENUMS.BuffObjects.IgnitedPlasma,
        ENUMS.BuffObjects.HPDamage,
    },
}

-- Muzzle and aim read off the same fields the native path uses (ProjectileFireSocket,
-- LastRangedAttackLocation + RangedTarget_VerticalOffset), so the shot leaves the same place and
-- keeps the native lead - only the travel speed changes. Damage is the NPC's own RangedDamage.
local function firePlasmaBolt(actor)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end

    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return end

    local muzzle
    pcall(function() muzzle = mesh:GetSocketLocation(actor.ProjectileFireSocket) end)
    if not muzzle then return end

    local aim
    pcall(function()
        local l = actor.LastRangedAttackLocation
        aim = FVector(l.X, l.Y, l.Z + (tonumber(actor.RangedTarget_VerticalOffset) or 0))
    end)
    if not aim or Utils.DistSq(muzzle, aim) < 1 then return end

    local damage = 0
    pcall(function() damage = tonumber(actor.NPCData[ENUMS.NpcData.RangedDamage]) or 0 end)

    PROJ.Queue(muzzle, Utils.Direction(muzzle, aim), ANTEFIRE_BOLT.Class, nil, {
        Owner = actor,
        Instigator = actor,
        Velocity = ANTEFIRE_BOLT.Speed,
        MaxSpeed = ANTEFIRE_BOLT.Speed,   -- the row's own cap is 5500; ours has to win
        GravityScale = 0,
        LifeSpan = ANTEFIRE_BOLT.LifeSpan,
        Damage = damage,
        DamageTypeClass = ANTEFIRE_BOLT.DamageType,
        Preload = ANTEFIRE_BOLT.Deps,
    })

    -- The half of the native beat the blanked row skipped: decrement, dormancy flush, dirty mark,
    -- OnRep_CurrentAmmoCount (redraws the quill rack). Only on a shot we actually fired.
    pcall(function() actor:ConsumeAmmo() end)
end


-- =======================================================================
-- SEEKER QUILL - one oversized, slow, tracking quill thrown on each reload. The Antegrav Exor's
-- [HARD] reload, and every Exor Superior reload.
-- =======================================================================

local ANTEGRAV_HARD_RELOAD = 2   -- [HARD] reload play-speed multiplier
local SUPERIOR_RELOAD = 1.5      -- reload play-speed multiplier, on top of its 1.1 dilation

local SEEKER_QUILL = {
    Class    = ENUMS.ProjectileClasses.QuillSpear,
    Speed    = 600,
    Homing   = 800,
    LifeSpan = 6,
}

local function lobSeeker(actor, label)
    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end

    local origin = reloadArmOrigin(actor)
    local to = target:K2_GetActorLocation()
    local aim = FVector(to.X, to.Y, to.Z + 40)   -- chest height
    if Utils.DistSq(origin, aim) < 100 * 100 then return end   -- point-blank: no room to steer
    local dir = Utils.Direction(origin, aim)

    local damage = 0
    pcall(function() damage = (tonumber(actor.NPCData[ENUMS.NpcData.RangedDamage]) or 0) * 1.5 end)

    PROJ.Queue(origin, dir, SEEKER_QUILL.Class, nil, {
        Owner = actor,
        Instigator = actor,
        Velocity = SEEKER_QUILL.Speed,
        MaxSpeed = SEEKER_QUILL.Speed,
        GravityScale = 0,
        FlightRow = ENUMS.ProjectileRows.SeekerQuill,   -- the pace and the homing, for a remote client
        LifeSpan = SEEKER_QUILL.LifeSpan,
        Damage = damage,
        -- PROJ.Queue loads the class itself; this is the row's own latent-loaded type, and a cold
        -- one lands untyped. Both are pinned, so the per-shot resolve is a table hit.
        Preload = { ENUMS.DamageType.SharpExorQuill },

        -- BEFORE FinishSpawningActor: BeginPlay's ApplyHomingSettings only runs once.
        PreFinish = function(proj)
            if Utils.IsActorInvalid(target) then return end
            pcall(function() proj.HomingTarget = target end)
        end,

        -- AFTER: BeginPlay rebuilds the movement component from the row.
        PostFinish = function(proj)
            local pm = proj.ProjectileMovement
            if IsNotValid(pm) then return end
            pcall(function() pm.bIsHomingProjectile = true end)
            pcall(function() pm.HomingAccelerationMagnitude = SEEKER_QUILL.Homing end)
            pcall(function() pm.MaxSpeed = SEEKER_QUILL.Speed end)

            -- Home at the chest, not the feet: with this flag set, ApplyHomingSettings picks the
            -- target's mesh, whose origin is on the floor. Re-run it natively - a UE4SS write to the
            -- weak HomingTargetComponent fails silently. [[af-projectile-homing]]
            pcall(function() pm.UseHomingTargetBoundsCenter = false end)
            pcall(function() proj:ApplyHomingSettings() end)
        end,
    })

    LogDebug(label .. " - reload seeker quill", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- =======================================================================
-- MORTAR LOB - Magma (molotov) and Antefire (mage fireball) reload shells, same arc engine.
-- =======================================================================

local ANTEFIRE_HARD_RELOAD = 1.5   -- [HARD] reload play-speed multiplier

local FIRE_MORTAR = {
    Gravity  = 1,
    AngleDeg = 40,
    SpeedMul = 0.9,
    ProjectileClass = ENUMS.ProjectileClasses.Molotov,
    FlightRow = ENUMS.ProjectileRows.FireMortar,   -- its look (hidden bottle, fireball trail) rides the row
    Deps = {
        ENUMS.ProjectileClasses.Molotov,
        ENUMS.DamageType.Fire,
        ENUMS.Components.AREA_MOLOTOV_FIRE,
    },
}

local MAGMA_SPLIT_OFFSET = 300   -- [HARD] second shell's offset from the first, random bearing

local PLASMA_MORTAR = {
    Gravity  = 1,
    AngleDeg = 40,
    AngleDegHard = 25,   -- [HARD] flatter = faster to the same landing spot
    SpeedMul = 0.8,
    ProjectileClass = ENUMS.ProjectileClasses.MageFireball,
    FlightRow = ENUMS.ProjectileRows.PlasmaMortar,   -- full gravity (the row ships 0.1); hidden ball + plasma trail
    NeedsInstigator = true,   -- ignores instigator and its allies
    DamageTypeClass = ENUMS.DamageType.FirePlasma,
    Deps = {
        ENUMS.ProjectileClasses.MageFireball,
        ENUMS.DamageType.FirePlasma,
        ENUMS.Components.AREA_PLASMA_FIRE,
    },
}

-- Lobs an arc at the target, landing slightly short (cfg.SpeedMul) so the patch walls off ground
-- in front of them. ArcSpeed solves for the speed that lands at the given angle, so a lower angle
-- is a faster shell to the same spot. aimOffset shifts the aim point (Magma's hard second shell).
local function lobMortar(actor, cfg, aimOffset)
    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end

    local angle = (STATE.HardModeNoMercy and cfg.AngleDegHard) or cfg.AngleDeg
    local origin = reloadArmOrigin(actor)

    local to = target:K2_GetActorLocation()
    if aimOffset then to = FVector(to.X + aimOffset.X, to.Y + aimOffset.Y, to.Z + aimOffset.Z) end
    local launchDir = AVM.ArcDir(origin, to, angle)
    local v = AVM.ArcSpeed(origin, to, angle, cfg.Gravity) * cfg.SpeedMul

    PROJ.Queue(origin, launchDir, cfg.ProjectileClass, nil, {
        Owner = actor,
        Instigator = cfg.NeedsInstigator and actor or nil,
        Velocity = v,
        GravityScale = cfg.Gravity,
        FlightRow = cfg.FlightRow,
        LifeSpan = 5,
        IgnoreOwnerDuration = 2,
        DamageTypeClass = cfg.DamageTypeClass,
        Preload = cfg.Deps,
    })
end


-- =======================================================================
-- Entry points - bare references from Exor.lua
-- =======================================================================

H.GravTick = gravTick

function H.AntegravDamageTaken(victim, damage) gravOnHit(victim, "Antegrav Exor", damage) end
function H.AntefireDamageTaken(victim, damage) gravOnHit(victim, "Antefire Exor", damage) end

function H.AntegravReload(actor)
    if not STATE.HardModeNoMercy or Utils.IsActorInvalid(actor) then return end
    AVU.ReloadDilation(actor, ANTEGRAV_HARD_RELOAD)
    lobSeeker(actor, "Antegrav Exor")
end

function H.SuperiorReload(actor)
    if Utils.IsActorInvalid(actor) then return end
    AVU.ReloadDilation(actor, SUPERIOR_RELOAD)
    lobSeeker(actor, "Exor Superior")
end

function H.MagmaReload(actor)
    if Utils.IsActorInvalid(actor) then return end
    lobMortar(actor, FIRE_MORTAR)
    if STATE.HardModeNoMercy then
        local bearing = math.random() * 2 * math.pi
        lobMortar(actor, FIRE_MORTAR, FVector(math.cos(bearing) * MAGMA_SPLIT_OFFSET,
                                              math.sin(bearing) * MAGMA_SPLIT_OFFSET, 0))
    end
    LogDebug("Magma Exor - reload fire mortar", SETTINGS.DEBUG_NPC_ACTIONS)
end

-- [Stats] Point the native gun at the slow plasma row; blank it (and fall back to the scripted
--   bolt) only when the row failed to build this world.
function H.AntefireProjectile(actor)
    if ProjectileRows.Ready(ENUMS.ProjectileRows.AntefirePlasma) then
        AVU.SetProjectileRow(actor, "ExorProjectile", ENUMS.ProjectileRows.AntefirePlasma)
    else
        AVU.SetProjectileRow(actor, "ExorProjectile", "None")   -- invalid on purpose: no native spawn
    end
end

-- One plasma bolt per shot of the burst - the fallback path only; with the row ready the native
-- gun has already fired. Deferred a beat: this dispatch is PRE, so at call time
-- LastRangedAttackLocation still holds the previous shot's aim - the native body writes this one
-- just after us.
function H.AntefireRangedAttack(actor)
    if ProjectileRows.Ready(ENUMS.ProjectileRows.AntefirePlasma) then return end
    Utils.QueueWork(function() firePlasmaBolt(actor) end, 0)
end

function H.AntefireReload(actor)
    if Utils.IsActorInvalid(actor) then return end
    if STATE.HardModeNoMercy then AVU.ReloadDilation(actor, ANTEFIRE_HARD_RELOAD) end
    lobMortar(actor, PLASMA_MORTAR)
    LogDebug("Antefire Exor - reload plasma mortar", SETTINGS.DEBUG_NPC_ACTIONS)
end

return H
