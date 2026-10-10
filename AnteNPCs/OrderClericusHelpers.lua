-- =======================================================================
-- Clericus helpers - the parry + swing machinery behind AnteNPCs/OrderClericus.lua
--
-- MUST-KNOWS (full rationale + decode history: scripts/AnNotes/AnteNPCs/OrderClericus.md)
--   * THE REDIRECT MUST BE SYNCHRONOUS - the impact is already overridden, so a queued velocity
--     write just lets the shot sail on. The cue hops off-hook; the flourish plays INLINE when its
--     clip is pinned (H.PlaySwing), so the parry pose lands on the impact frame.
--   * Two ignore-list fixes are mandatory on a deflect - see the numbered comments in H.Deflect.
--   * The swing montage stands in for the base's EMPTY MeleeAttacks map, and closes the BT task
--     that montage was supposed to close.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local ENUMS = require("AnteData.Enums")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local AVM = require("AnteUtils.AVMath")
local ASSETS = require("AnteCore.AssetManager")

local LogDebug = Utils.LogDebug

-- Knobs
local PARRY_COOLDOWN_S    = 2      -- parry downtime after a deflect
local DEFLECT_SPREAD_DEG  = 10     -- aim jitter on the deflection
local DEFLECT_MIN_SPEED   = 1500   -- floor if the projectile reports no speed (e.g. grenades)
local PARRY_RATE          = 1.75      -- deflect flourish play rate
local ATTACK_RATE         = 1      -- melee swing play rate (the LabRat's own pacing)
local ATTACK_LEN_FALLBACK = 1.2    -- montage seconds assumed if GetPlayLength won't read
local ATTACK_RESET_PAD_MS = 120    -- pad past the montage so the swing finishes

-- One clip for both jobs - the parry flourish and the swing are the same motion at very
-- different rates. The LabRat's swing, not the grunt's:
--   * ONE-HANDED. A prop on a hand bone follows the wrist, and the grunt's two-handed clip rolls
--     the right wrist mid-arc, so a sword mounted upright on r_hand swings through inverted.
--   * Its contact frame is early (the LabRat's MeleeHitApex is 0.2s raw, the grunt's 0.5s), so
--     the parry pose reaches the screen sooner at a lower rate, and the swing's contact lines up
--     with this base's 0.25s hit instead of trailing it.
--   * DefaultSlot (in the asset's name table), so it plays on AnimBP_Clericus and replicates.
local SWING_ANIM = ENUMS.Anims.LABRAT_MELEE

local SWING_DEPS = {
    SWING_ANIM,
    ENUMS.SOUNDS.SABER_DEFLECT,
}

local lastParrySecs = {}   -- ActorKey -> os.clock() SECONDS of the last deflect (wall clock, not FAST_TICK)

local H = {}


-- =======================================================================
-- PARRY FLAG
-- =======================================================================

-- Push-model write: an unmarked replicated property never leaves the server (CLAUDE.md S4).
-- No hand-called OnRep - its body is an empty stub on the parent.
function H.SetParry(actor, on)
    pcall(function()
        actor.IsShieldBlocking = on
        Utils.MarkReplicatedDirty(actor, "IsShieldBlocking")
    end)
end


-- Bring the parry to where it should be right now. Idempotent, write-on-change only, so the
-- steady state of a 2 Hz re-assert is a bool read.
function H.ArmParry(actor)
    if Utils.IsActorInvalid(actor) then return end

    pcall(function()
        local want
        if actor.IsDead or actor.IsDBNO then
            want = false          -- the native check would still honour the flag on a corpse
        else
            local key = Utils.ActorKey(actor)
            -- No key = nothing to gate on, so the parry counts as ready.
            want = (not key) or AVU.CooldownReady(lastParrySecs, key, PARRY_COOLDOWN_S,
                                                  { Now = os.clock(), Peek = true })
        end

        if actor.IsShieldBlocking ~= want then H.SetParry(actor, want) end
    end)
end


-- =======================================================================
-- SWING
-- =======================================================================

-- Play the sword swing on every machine, resolving the clip at fire time (S3 - a swing can land
-- minutes after mutation).
--   * INLINE when the clip is pinned resident (ASSETS.GetIfPinned: a table read, nothing to load
--     or scan), so the parry pose starts on the impact frame instead of up to a full 100ms drain
--     later. PlayMontageReplicated is non-loading, and the hook this runs in already makes
--     non-loading calls on the projectile itself.
--   * Otherwise the load and the play hop off-hook (S2). A still-cold montage is a skipped
--     flourish, never a hitch.
--   * thenFn always runs on a drain, WHETHER OR NOT the montage played - the BT release rides it
--     and must never depend on a cosmetic landing, and the deflect cue it carries stays off-hook.
function H.PlaySwing(actor, rate, thenFn)
    if Utils.IsActorInvalid(actor) then return end

    if ASSETS.GetIfPinned(SWING_ANIM) then
        AVU.PlayMontageReplicated(actor, SWING_ANIM, rate, false)
        if thenFn then
            Utils.QueueWork(function()
                if Utils.IsActorInvalid(actor) then return end
                thenFn(actor)
            end, 0)
        end
        return
    end

    ASSETS.LoadAsync(SWING_DEPS, function()
        Utils.QueueWork(function()
            if Utils.IsActorInvalid(actor) then return end
            AVU.PlayMontageReplicated(actor, SWING_ANIM, rate, false)
            if thenFn then thenFn(actor) end
        end, 0)
    end)
end


-- Stand in for the melee montage the base doesn't have, then close the BT task. AUTHORITY only:
-- PlayThirdPersonMontage is itself a multicast, so a client running this would double-play it.
function H.MeleeSwing(actor)
    if not Utils.IsAuthority() then return end
    if Utils.IsActorInvalid(actor) then return end

    H.PlaySwing(actor, ATTACK_RATE, function(a)
        -- Release on the montage's own clock, as the native RetriggerableDelay would (this base's
        -- GetMeleeTimeOffset is a flat 0, so play length IS the window) - scaled by our rate.
        local len = ATTACK_LEN_FALLBACK
        local anim = ASSETS.GetIfValid(SWING_ANIM)
        if IsValid(anim) then
            pcall(function()
                local l = anim:GetPlayLength()
                if l and l > 0 then len = l end
            end)
        end

        -- ReleaseSoldierBT is EndAbility_DoCombatReset(true) - exactly what BTT_DoMeleeAttack has
        -- waited on since the swing fired. Its extra writes are inert on a melee-only NPC, and it
        -- hops off-hook itself (its DecisionTick can cold-load the next behaviour - S2).
        Utils.QueueWork(function() AVU.ReleaseSoldierBT(a) end,
            math.floor((len / ATTACK_RATE) * 1000) + ATTACK_RESET_PAD_MS)
    end)
end


-- =======================================================================
-- DEFLECT
-- =======================================================================

-- Turn a parried projectile around and send it back at whoever fired it.
function H.Deflect(actor, proj)
    -- Read the two components SEPARATELY: a subclass missing ProjectileCollision must not cost us
    -- the movement component, and with it the whole deflect, through one shared pcall.
    local pm, collision
    pcall(function() pm = proj.ProjectileMovement end)
    pcall(function() collision = proj.ProjectileCollision end)
    if IsNotValid(pm) then return end

    -- Speed is preserved - a returned bolt should read as the same shot coming back.
    local loc, speed
    pcall(function()
        loc = proj:K2_GetActorLocation()
        local v = pm.Velocity
        speed = math.sqrt((v.X or 0) ^ 2 + (v.Y or 0) ^ 2 + (v.Z or 0) ^ 2)
    end)
    if not loc then return end
    if not speed or speed < DEFLECT_MIN_SPEED then speed = DEFLECT_MIN_SPEED end

    -- Captured BEFORE we take ownership below (after that, both fields point at us). Instigator is
    -- the pawn we want to hit; Owner is what the native check used, and is the actor on the
    -- projectile's move-ignore list - so we need it either way.
    local shooter, owner
    pcall(function()
        local inst = proj.Instigator
        if IsValid(inst) then shooter = inst end
        local o = proj:GetOwner()
        if IsValid(o) then owner = o end
    end)
    shooter = shooter or owner

    -- A player's item-carrying shot (thrown weapon, crossbow bolt, disc, net) stays theirs. The
    -- native item drop - and the quantum pick's return to the hotbar - only happens while the
    -- Instigator is a player, so re-owning it deleted the item. It still comes back, but passes
    -- the thrower and drops where it lands.
    local keepsItem = false
    pcall(function() keepsItem = proj.SpawnImpactItemAfterHit == true end)
    keepsItem = keepsItem and shooter ~= nil and Utils.IsPlayer(shooter)

    -- Aim back at the shooter; straight ahead if it's gone (streamed out mid-flight).
    local dx, dy, dz
    if shooter then
        local tl
        pcall(function() tl = shooter:K2_GetActorLocation() end)
        if tl then dx, dy, dz = tl.X - loc.X, tl.Y - loc.Y, tl.Z - loc.Z end
    end
    if not dx then
        local fwd
        pcall(function() fwd = actor:GetActorForwardVector() end)
        if not fwd then return end
        dx, dy, dz = fwd.X, fwd.Y, fwd.Z
    end

    -- Normalize, with a little scatter so a duel doesn't become a mirrored volley.
    -- ScatterDir returns nil on a degenerate direction - bail rather than fire a garbage vector.
    dx, dy, dz = AVM.ScatterDir(dx, dy, dz, DEFLECT_SPREAD_DEG)
    if not dx then return end

    -- THE REDIRECT. Re-owning the projectile is what lets the return shot damage its original
    -- firer: ownership/instigation drive the friendly-fire and self-hit checks downstream.
    local redirected = pcall(function()
        pm.Velocity = FVector(dx * speed, dy * speed, dz * speed)
        proj:FlushNetDormancy()
        if keepsItem then return end
        proj.Instigator = actor
        Utils.MarkReplicatedDirty(proj, "Instigator")
        proj:SetOwner(actor)
    end)
    if not redirected then return end

    if IsValid(collision) then
        pcall(function()
            -- 1. Stop ignoring the shooter (IgnoreOwnerCollision listed them at spawn), or the shot
            --    we just aimed at them passes straight through. An item shot does the opposite:
            --    stopped on its own Instigator it skips the hit and never drops the item.
            if keepsItem then
                collision:IgnoreActorWhenMoving(shooter, true)
            elseif owner then
                collision:IgnoreActorWhenMoving(owner, false)
            end
            -- 2. Start ignoring US. The character block branch never does this - unlike the
            --    "reflective" geometry branch right below it - so the projectile is still inside our
            --    capsule and re-impacts instantly, with the parry now down.
            collision:IgnoreActorWhenMoving(actor, true)
        end)
    end

    -- Parry down immediately (a bool + a push, both non-loading) so a burst can't be parried
    -- shot-for-shot; the variant's OnTick brings it back.
    local key = Utils.ActorKey(actor)
    if key then lastParrySecs[key] = os.clock() end
    H.SetParry(actor, false)

    LogDebug("Salii - deflected a projectile", SETTINGS.DEBUG_NPC_ACTIONS)

    -- Flourish + cue, off-hook (PlaySwing owns the load/queue dance).
    H.PlaySwing(actor, PARRY_RATE, function(a)
        local cue = ASSETS.GetIfValid(ENUMS.SOUNDS.SABER_DEFLECT)
        if IsValid(cue) then
            -- (Sound, Attached, UnattachedLocation, PlayForLocalPlayer)
            pcall(function() a:Broadcast_Play3DSoundEffect(cue, true, FVector(0, 0, 0), true) end)
        end
    end)
end

return H
