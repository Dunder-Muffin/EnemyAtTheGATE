-- =======================================================================
-- Breacher helpers - the machinery behind AnteNPCs/OrderBreacher.lua
--
-- MUST-KNOWS
--   * [AUTHORITY] Everything here runs server-side. The dodges reach clients because
--     PlayThirdPersonMontage is a multicast carrying the montage AND the play rate.
--   * The Skirmisher's dance is keyed to the SHELL COUNT, not a timer. `OnRangedAttack` is a PRE
--     hook on the shared soldier path, so `CurrentAmmoCount` read there is still the count BEFORE
--     the shell about to leave the barrel - that is what makes a per-shell script possible.
--   * A reload has no completion hook. The clip refilling IS the signal, so the post-reload dodge
--     is read off CurrentAmmoCount climbing back up in the tick.
--   * Never roll DURING a reload: the reload montage's completion delegate is what refills the
--     clip, so interrupting it hands out a free instant reload. AVU.DodgeRoll already refuses
--     while a locked montage is playing, which covers it - don't route around that.
--   * Projectile dodging is native (EvadesProjectiles + ProjectileEvasionCooldown). The roll it
--     plays is the base's own backstep montage, and that choice is re-resolved per machine, so
--     re-pointing it would mean writing the soft-refs on clients too.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")

local H = {}


-- =======================================================================
-- SKIRMISHER
-- =======================================================================

local SKIRM = {
    Clip        = 4,                                -- shells; the shell script below assumes it
    MeleeSq     = 300 * 300,                        -- shoved this close, roll out backwards
    BackpedalSq = 800 * 800,                        -- inside this, give ground
    Hop         = 600,                              -- how far back a backpedal aims
    SideRate    = { Normal = 0.75, Hard = 1.0 },    -- side-roll play rate
    LeftRateCut = 0.15,                             -- the left roll reads better slower than its mirror
    BackHopRate = 1.5,                              -- clip-out hop; a stagger clip, so hurry it
    LateDodge   = { Normal = 0.33, Hard = 1.0 },    -- chance of a roll off the third shell
    ReloadDil   = { Normal = 2.0,  Hard = 3.0 },
    RollCdMs    = { Normal = 12000, Hard = 6000 },  -- melee back-roll
    EvadeCd     = { Normal = 12,   Hard = 6 },      -- ProjectileEvasionCooldown, in SECONDS
}

-- actor -> { shells = last-seen CurrentAmmoCount, lastRollMs = last melee-roll stamp (AVU.CooldownReady) }
local skirmState = setmetatable({}, { __mode = "k" })

-- Read at USE time, never cached - the flag is a world-load property and a def is shared.
local function byMode(t) return STATE.HardModeNoMercy and t.Hard or t.Normal end

-- Chance/cooldown are handled by the callers' own stamps, so every roll here is unconditional.
local function sideDodge(actor)
    local left = math.random() < 0.5
    AVU.DodgeRoll(actor, {
        Chance = 1, CooldownTicks = 0,
        Rate = byMode(SKIRM.SideRate) - (left and SKIRM.LeftRateCut or 0),
        Anim = left and ENUMS.Anims.GK_DODGE_LEFT or ENUMS.Anims.GK_DODGE_RIGHT,
    })
end


-- [AUTHORITY, Stats] The Skirmisher's ranged identity: short clip, no frags, native projectile evade on a long leash.
function H.SkirmisherStats(actor)
    actor.CurrentAmmoCount = SKIRM.Clip
    actor.MaxAmmoCount     = SKIRM.Clip

    actor.EvadesProjectiles         = true
    actor.ProjectileEvasionCooldown = byMode(SKIRM.EvadeCd)

    AVU.DisableGrenades(actor)
end


-- [AUTHORITY, OnRangedAttack] One beat of the shell dance. `left` is what the clip holds once the
-- shell about to fire is gone, so with a 4-shell clip:
--     3  opening shell   -> roll aside
--     2                  -> hold the line
--     1                  -> roll aside, on a chance
--     0  clip out        -> hop back; the reload follows on its own
function H.SkirmisherShot(actor)
    -- Native body drops this call outright mid-burst - no shell fires, so nothing to dance to.
    local bursting = false
    pcall(function() bursting = actor.PerformingRangedBurst == true end)
    if bursting then return end

    local left = (tonumber(actor.CurrentAmmoCount) or 0) - 1

    if left == 3 or (left == 1 and math.random() < byMode(SKIRM.LateDodge)) then
        sideDodge(actor)
    elseif left <= 0 then
        AVU.DodgeRoll(actor, {
            Chance = 1, CooldownTicks = 0,
            Rate = SKIRM.BackHopRate,
            Anim = ENUMS.Anims.GRUNT_STAGGER_BACK,
        })
    end
end


-- [AUTHORITY, OnTick] Footwork: gives ground while close, rolls clear in swinging range, and catches the reload finishing.
function H.SkirmisherTick(actor, totalTicks)
    if not Utils.IsActorReadyToAttack(actor) then return end

    local st = skirmState[actor]
    if not st then st = {}; skirmState[actor] = st end

    -- Reload leaves it standing still and exposed, so it moves the instant the clip refills.
    local ammo = tonumber(actor.CurrentAmmoCount) or 0
    if st.shells == 0 and ammo > 0 then sideDodge(actor) end
    st.shells = ammo

    if totalTicks % 5 ~= 0 then return end   -- footwork at ~2/s

    -- Reload/roll footwork must sit out (see AVU.ReloadDilation) - a move order on top just SLIDES it.
    local locked = false
    pcall(function() locked = actor.LockedInPlaceMontage == true end)
    if locked or ammo <= 0 then return end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end
    local aLoc, tLoc = actor:K2_GetActorLocation(), target:K2_GetActorLocation()
    local distSq = Utils.DistSq(aLoc, tLoc)
    if distSq > SKIRM.BackpedalSq then return end

    if distSq < SKIRM.MeleeSq and AVU.CooldownReady(st, "lastRollMs", byMode(SKIRM.RollCdMs), { Now = Utils.NowMs() }) then
        AVU.DodgeRoll(actor, { Chance = 1, CooldownTicks = 0, Anim = ENUMS.Anims.GK_DODGE_BACK })
        return   -- the roll IS the retreat this beat; a move order on top of it slides
    end

    -- Re-asserted every check because the BT keeps pulling it back in; Z kept flat, not traced.
    local away = Utils.PointAheadOfVector(tLoc, aLoc, SKIRM.Hop)
    AVU.MoveOrder(actor, FVector(away.X, away.Y, aLoc.Z), 40)
end


-- [AUTHORITY, OnReload] Short 4-shell clip reloads often, so cut the stationary window (needs MirrorTimeDilation in the def).
function H.SkirmisherReload(actor)
    AVU.ReloadDilation(actor, byMode(SKIRM.ReloadDil))
end


return H
