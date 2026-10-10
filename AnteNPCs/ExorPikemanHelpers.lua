-- =======================================================================
-- Exor Pikeman helpers - the machinery behind AnteNPCs/ExorPikeman.lua: the Sentinel/Wraith bond
-- (link, death propagation, transpose), the Wraith's summon-in and two-phase beam, and its
-- rift-away death FX.
--
-- MUST-KNOWS
--   * All bookkeeping is keyed by Utils.ActorKey - hooks here hand back fresh wrappers per call.
--   * byMode reads STATE.HardModeNoMercy at USE time - never cache what it returns.
--   * transposePair does NOT use Broadcast_TeleportFX (that bundles the blink sparkle we don't
--     want) - the tether and arrival bursts are sent on their own over the client-FX channel.
--   * transposePair moves both bodies OFF the drain, and every read of a bond goes through
--     livePartner - never index bondPartner and use the wrapper directly.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")

local LogDebug = Utils.LogDebug

local H = {}

local function byMode(t) return STATE.HardModeNoMercy and t.Hard or t.Normal end

local BEAM_EYE_Z = 80   -- trace/beam origin height above the actor root (~muzzle)

-- Bond / summon tuning.
local SUMMON_RADIUS   = 500    -- ~5m: where the Wraith materializes around the Sentinel
local SUMMON_AGGRO_MS = 1000   -- hand the Wraith the Sentinel's target this long after it lands

-- Transpose. Swap on a timer (10/20s); [HARD] also swap when damaged (7s cooldown).
local TRANSPOSE_TICKS = { Normal = 100, Hard = 200 }
local TRANSPOSE_HOP_MS = 50    -- the swap runs off the drain (see transposePair)
local REACT_DAMAGE = 20
local REACT_TICKS  = 70
local FX_SHOCKWAVE_SCALE = 2   -- the arrival burst is small at its authored size

-- Damage-over-time classes. A tick from one of these is not a hit to flinch from, and each
-- inherits its parent's DamageTypeDisplayName, so only the object path tells them apart.
local DOT_CLASSES = { "DamageType_Bleeding", "DamageType_Acid_Burn", "DamageType_Radiation" }

-- Wraith beam. The vanilla beam is undodgeable, so we need to lock its position slightly before it fires
local WRAITH_LOCK_MS  = 600
local WRAITH_BEAM_MS  = 2700
local WRAITH_BEAM_DMG = { Normal = 100, Hard = 130 }   -- the old weak(25) + strong(90) as one hit
local WRAITH_BEAM_RAD = 190
local WRAITH_DESPAWN_MS = 1200   -- corpse lingers this long, then rifts out

-- All keyed by Utils.ActorKey (wrappers differ across hooks).
local bondPartner  = {}   -- actor key -> the partner ACTOR wrapper
local bondSeen     = {}   -- actor key -> FAST_TICK its partner last read valid (see livePartner)
local BOND_STALE_TICKS = 250
local summonDone   = {}   -- actor key -> true, Sentinels that already called their Wraith
local lastSwapTick = {}   -- Sentinel key -> FAST_TICK of the last transpose (the scheduled gate)
local lastReactTick = {}  -- BOTH keys -> FAST_TICK of the last reactive transpose
local wraithCastOn = {}   -- actor key -> a beam channel is in flight


-- Link A<->B so either death kills the other.
local function linkPair(a, b)
    local ka, kb = Utils.ActorKey(a), Utils.ActorKey(b)
    if not ka or not kb then return end
    bondPartner[ka] = b
    bondPartner[kb] = a
    bondSeen[ka], bondSeen[kb] = STATE.FAST_TICK, STATE.FAST_TICK
    -- Start the transpose clock NOW, or the first OnTick reads an open gate and the pair swaps
    -- the instant the Wraith lands.
    lastSwapTick[ka] = STATE.FAST_TICK
    LogDebug("Exor bond - linked " .. ka .. " <-> " .. kb, SETTINGS.DEBUG_NPC_ACTIONS)
end

-- The partner for `key` if it is alive, else nil. The held wrapper is only safe to test while a
-- departure would still be stamped (Utils.IsDeparted, 300 ticks), so a bond nobody has confirmed
-- for longer - a parked Sentinel, a Wraith nobody hits - is dropped without touching it, and a
-- partner that left play without dying (despawned, cleared, streamed out) is dropped on sight.
local function livePartner(key)
    local partner = bondPartner[key]
    if partner == nil then return nil end
    if STATE.FAST_TICK - (bondSeen[key] or 0) > BOND_STALE_TICKS then
        bondPartner[key], bondSeen[key] = nil, nil
        return nil
    end
    if not Utils.IsActorValid(partner) then
        if Utils.IsDeparted(partner) then bondPartner[key], bondSeen[key] = nil, nil end
        return nil
    end
    bondSeen[key] = STATE.FAST_TICK
    return partner
end


-- Death propagation. Clear both bond entries BEFORE killing the partner, so its own OnDeath finds
-- no bond and doesn't re-kill us.
local function killPartner(actor)
    local key = Utils.ActorKey(actor)
    if not key then return end
    local partner = livePartner(key)
    bondPartner[key], bondSeen[key] = nil, nil
    lastSwapTick[key] = nil
    lastReactTick[key] = nil
    summonDone[key] = nil
    if not partner then return end
    local pkey = Utils.ActorKey(partner)
    if pkey then
        bondPartner[pkey] = nil; bondSeen[pkey] = nil; lastSwapTick[pkey] = nil
        lastReactTick[pkey] = nil; summonDone[pkey] = nil
    end
    LogDebug("Exor bond - partner died, killing the other", SETTINGS.DEBUG_NPC_ACTIONS)
    AVU.KillNpc(partner)
end


-- Arrival FX: a beam from the Sentinel to the newly-materialized Wraith (Broadcast_BeamAttack, a
-- NetMulticast - clients redraw it), plus a lightning burst at each end (client-FX channel).
local function connectFX(sentinel, wraith)
    if Utils.IsActorInvalid(sentinel) or Utils.IsActorInvalid(wraith) then return end

    local a = sentinel:K2_GetActorLocation()
    local b = wraith:K2_GetActorLocation()

    pcall(function() sentinel:Broadcast_BeamAttack(b) end)   -- the connecting beam, Sentinel -> Wraith
    AVU.SendClientFX(FVector(a.X, a.Y, a.Z + BEAM_EYE_Z), "LIGHTNING_BURST", 1)
    AVU.SendClientFX(FVector(b.X, b.Y, b.Z + BEAM_EYE_Z), "LIGHTNING_BURST", 1)
end


-- Summon the bonded Wraith ~5m from the Sentinel, deferred off OnRep_CombatState.
-- NpcSpawner does the async class load + off-hook spawn, so nothing blocking-loads here. That
-- async gap means the Sentinel can be one-shot mid-spawn, so re-check it in the callback and kill
-- the orphan Wraith if it's gone.
local function summonWraith(sentinel)
    if Utils.IsActorInvalid(sentinel) or sentinel.IsDead then return end

    local origin = sentinel:K2_GetActorLocation()
    local loc = Utils.GetSpawnPoint(origin, SUMMON_RADIUS) or origin
    LogDebug("Exor Spiritwalker - calling in its Wraith", SETTINGS.DEBUG_NPC_ACTIONS)

    AVU.SummonVariant("Exor Wraith", loc, { SpawnDelay = 250 }, function(wraith)
        if Utils.IsActorInvalid(wraith) then return end

        if Utils.IsActorInvalid(sentinel) or sentinel.IsDead then
            AVU.KillNpc(wraith)   -- don't leave an unbonded Wraith behind
            return
        end

        linkPair(sentinel, wraith)
        connectFX(sentinel, wraith)

        -- Hand it the Sentinel's target a beat later, in case it doesn't aggro on its own.
        Utils.QueueWork(function()
            if Utils.IsActorInvalid(sentinel) or Utils.IsActorInvalid(wraith) or wraith.IsDead then return end
            local target = sentinel:GetCurrentCombatTarget()
            if Utils.IsActorValid(target) then AVU.ForceAggro(wraith, target) end
        end, SUMMON_AGGRO_MS)
    end)
end


-- Swap the pair's positions; each ends up facing where the other stood. Skipped if either is
-- down. Position replicates; the FX is drawn over the client channel. NOT Broadcast_TeleportFX:
-- it bundles the blink sparkle, the blink sound and the connecting beam into one multicast, and
-- the sparkle is the one piece we don't want - so the tether is re-sent on its own and each body
-- gets an arrival burst in its PARTNER's colour, aimed along the swap axis. Stamps the scheduled
-- gate, so a reactive swap also restarts the metronome.
--   * OFF THE DRAIN: a move runs every overlap at the destination synchronously, and the pair's
--     first in-drain swap wedged the game (2026-09-28, [[anteup2-npc-teleport-overlap-freeze]]).
--     Both bodies cross the hop through Utils.CarryActor, and each move stamps its own freeze crumb.
local function transposePair(sentinel, wraith)
    if Utils.IsActorInvalid(sentinel) or Utils.IsActorInvalid(wraith) then return end
    if sentinel.IsDead or wraith.IsDead then return end
    local sPath, wPath = Utils.ObjectPath(sentinel), Utils.ObjectPath(wraith)
    if not sPath or not wPath then return end
    local getS, getW = Utils.CarryActor(sentinel), Utils.CarryActor(wraith)

    -- Stamped at the decision, so the tick can't queue a second swap while this one is in the hop.
    local sk = Utils.ActorKey(sentinel)
    if sk then lastSwapTick[sk] = STATE.FAST_TICK end

    Utils.DelayedGameThread(TRANSPOSE_HOP_MS, function()
        if not STATE.ModEnabled then return end
        local s, w = getS(), getW()
        if not s or not w or s.IsDead or w.IsDead then return end
        local a, b = s:K2_GetActorLocation(), w:K2_GetActorLocation()
        if not a or not b then return end

        STATE.LastWork = "OFFHOOK exor transpose sentinel " .. sPath
        STATE.LastWorkDone = false
        pcall(function() s:K2_SetActorLocationAndRotation(b, Utils.RotatorToTarget(b, a), false, {}, true) end)
        STATE.LastWork = "OFFHOOK exor transpose wraith " .. wPath
        pcall(function() w:K2_SetActorLocationAndRotation(a, Utils.RotatorToTarget(a, b), false, {}, true) end)
        STATE.LastWorkDone = true

        -- a/b are capsule centres, i.e. torso height, and each body ARRIVES at the other's spot.
        local yaw = math.deg(math.atan((b.Y or 0) - (a.Y or 0), (b.X or 0) - (a.X or 0)))
        AVU.SendClientBeam(a, b, "EXOR_BEAM_CHA", 1)
        AVU.SendClientFX(b, "EXOR_SHOCKWAVE_CHA", 1, yaw, nil, FX_SHOCKWAVE_SCALE)   -- blue, on the red Sentinel
        AVU.SendClientFX(a, "EXOR_SHOCKWAVE", 1, yaw, nil, FX_SHOCKWAVE_SCALE)       -- red, on the blue Wraith
        LogDebug("Exor pair - transposed", SETTINGS.DEBUG_NPC_ACTIONS)
    end)
end


-- [HARD] A real hit on either half swaps the pair on the spot, so committing to the body you can
-- hurt rotates it out from under you. `victimIsSentinel` is how each def hands over its own role -
-- nothing else records which half is which. DoT ticks are excluded outright rather than left to
-- REACT_DAMAGE: a big burn should not be able to drive the swap on its own. The cooldown is the
-- PAIR's (both keys stamped), or focusing one body doubles the rate. Deferred - the caller is
-- inside the ProcessDamage hook.
local function reactiveTranspose(victim, damage, dmgType, victimIsSentinel)
    if not STATE.HardModeNoMercy then return end
    if not damage or damage < REACT_DAMAGE then return end
    if Utils.IsActorInvalid(victim) or victim.IsDead then return end

    local typeName = Utils.DamageTypeName(dmgType)
    if typeName then
        for _, cls in ipairs(DOT_CLASSES) do
            if typeName:find(cls, 1, true) then return end
        end
    end

    local key = Utils.ActorKey(victim)
    if not key then return end
    local partner = livePartner(key)
    if not partner or partner.IsDead then return end
    local pkey = Utils.ActorKey(partner)

    if not AVU.CooldownReady(lastReactTick, key, REACT_TICKS) then return end
    if pkey then lastReactTick[pkey] = STATE.FAST_TICK end

    local sentinel = victimIsSentinel and victim or partner
    local wraith   = victimIsSentinel and partner or victim
    Utils.QueueWork(function() transposePair(sentinel, wraith) end, 0)
    LogDebug("Exor pair - reactive transpose (" .. math.floor(damage) .. " dmg)", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- Dissolve a dead Wraith - no gib path on its BP, so the corpse would otherwise lie there
-- forever. Let the death anim read for a beat, then rift it out (client-FX channel, so every
-- renderer gets the same system) and hide the body.
local function wraithVanish(actor)
    if Utils.IsActorInvalid(actor) then return end
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) then return end
        local loc = actor:K2_GetActorLocation()
        if loc then AVU.SendClientFX(loc, "PORTAL_RIFT", 2) end
        AVU.HideOnDeath(actor)   -- hides on all machines, destroys on the de-clumped corpse timer
        LogDebug("Exor Wraith - rifted out", SETTINGS.DEBUG_NPC_ACTIONS)
    end, WRAITH_DESPAWN_MS)
end


-- =======================================================================
-- Entry points - bare references from ExorPikeman.lua
-- =======================================================================

H.KillPartner = killPartner
H.WraithVanish = wraithVanish

-- Hold the ranged loop suppressed + transpose with the bonded Wraith on the scheduled cadence.
function H.SpiritwalkerTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    if totalTicks % 10 ~= 0 then return end
    if actor.IsDead then return end

    -- Re-assert BEFORE the partner early-out below: this must keep running even when the Wraith
    -- is gone, or the beam creeps back in.
    pcall(function() actor.RangedAttack_OnCooldown = true end)

    local key = Utils.ActorKey(actor)
    if not key then return end
    local partner = livePartner(key)
    if not partner then return end
    -- This Sentinel is plainly alive, so the Wraith's side of the bond is fresh too.
    local pkey = Utils.ActorKey(partner)
    if pkey and bondPartner[pkey] then bondSeen[pkey] = STATE.FAST_TICK end

    if not AVU.CooldownReady(lastSwapTick, key, byMode(TRANSPOSE_TICKS)) then return end
    transposePair(actor, partner)
end

-- Call the Wraith in on first aggro. OnEnterCombat is authority-only and fires once per real
-- aggro (DBNO doesn't toggle CombatState). Deferred off the OnRep_CombatState hook.
function H.SpiritwalkerEnterCombat(actor)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end
    local key = Utils.ActorKey(actor)
    if not key or summonDone[key] then return end
    summonDone[key] = true
    Utils.QueueWork(function() summonWraith(actor) end, 0)
end

function H.SpiritwalkerDamageTaken(victim, damage, dmgType)
    reactiveTranspose(victim, damage, dmgType, true)
end

function H.WraithDamageTaken(victim, damage, dmgType)
    reactiveTranspose(victim, damage, dmgType, false)
end

-- Two-phase beam: lock the aim point + telegraph it, then WRAITH_LOCK_MS later fire on that
-- frozen point, not wherever the target has since moved.
function H.WraithWindup(actor)
    if not Utils.IsAuthority() then return end   -- damage is server-side; the beam multicasts the visual
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end
    local key = Utils.ActorKey(actor)
    if key and wraithCastOn[key] then return end
    if key then wraithCastOn[key] = true end

    Utils.QueueWork(function()
        if key then wraithCastOn[key] = nil end
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        local target = actor:GetCurrentCombatTarget()
        if Utils.IsActorInvalid(target) then return end

        -- LOCK: the aim point is frozen HERE and never re-read.
        local t = target:K2_GetActorLocation()
        local p = FVector(t.X, t.Y, t.Z)

        -- Telegraph on the mark so the dodge is readable, not a coin flip.
        AVU.SendClientFX(p, "EXOR_CHARGE_CHA", 1)

        Utils.QueueWork(function()
            -- Safe NPC beam path: native "_Cha" beam multicast + radial damage, never
            -- FireRanged_HitscanBullet. Visual always shows; damage respects the eye->point wall trace.
            AVU.CastPsychicBeam(actor, target, p, {
                Dmg = byMode(WRAITH_BEAM_DMG), Radius = WRAITH_BEAM_RAD,
                EyeZ = BEAM_EYE_Z, AlwaysShow = true, Crumb = "wraithBeam",
            })
        end, WRAITH_LOCK_MS)
    end, WRAITH_BEAM_MS - WRAITH_LOCK_MS)
end

return H
