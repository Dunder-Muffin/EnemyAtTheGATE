-- =======================================================================
-- Peccary helpers - shared machinery for ANY charging peccary (AnteNPCs/Peccary.lua and friends).
--
-- MUST-KNOWS
--   * H.QuickCharge is the charge-windup piece: a ONE-LINER from def.OnCharge that shortens the
--     telegraph, which no native property can do. Opt-in per variant - a peccary that never calls
--     it keeps the stock windup.
--   * The MAGMA PECCARY section (bottom of file) is Magma-specific machinery migrated out of
--     AnteNPCs/PeccaryAlpha.lua's old inline locals - bite ignite, "too hot to handle" retaliation,
--     and the charge FX/type re-theme, bare-referenced from that def.
--   * def.OnCharge only fires for base rows listed in CombatHooks' CLASS_HOOKS. Today that is
--     `Peccary`, `Peccary_Snow` and `Peccary_Alpha` (the hook path itself lives on
--     NPC_Monster_Peccary, so it covers every peccary - it is only the lazy REGISTRATION that is
--     per row). A variant on another peccary row needs its row added there or OnCharge never fires.
--   * The charge END stays native. We start the stampede early and hand the native delay a
--     COMPENSATED StampedeDuration so the run still lasts exactly what the caller asked for.
--   * NEVER read StampedeDuration back as "the base" - QuickCharge overwrites it every charge.
--     Its `Run` knob is the real duration and it is always absolute (CLAUDE.md 3: a read-multiply
--     on a field we also write compounds on every re-mutation).
-- Deep: AnNotes/AnteNPCs/Peccary.md 1, [[af-peccary-charge-decode]].
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local ENUMS = require("AnteData.Enums")
local STATE = require("AnteCore.State")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local ASSETS = require("AnteCore.AssetManager")

local LogDebug = Utils.LogDebug

local H = {}


-- =======================================================================
-- QUICK CHARGE - running the stampede's start beat ourselves
--
-- THE NATIVE SHAPE (NPC_Monster_Peccary ubergraph, full decode in AnNotes/AnteNPCs/Peccary.md):
--     Broadcast_CombatAbility1  ->  StopMovementImmediately + PlayAnimMontage(start, PlayRate)
--       -> RetriggerableDelay(montageLength - 0.1)
--         -> WalkSpeed = 4500 (+dirty +OnRep), IsStampeding = true (+dirty +OnRep),
--            LockedInPlaceMontage = true, SetAbilityOnCooldown(1),
--            RetriggerableDelay(StampedeDuration) -> EndChargeWithExplosion
--
-- StampedeStartPlayRate alone cannot shorten that windup. The delay is built from
-- PlayAnimMontage's return value, and ACharacter::PlayAnimMontage returns MontageLength - the raw
-- length, never divided by the rate. Raise the rate alone and the body plays a fast windup and
-- then stands frozen for the remainder: strictly worse.
--
-- SO WE DO BOTH HALVES:
--   1. Raise the play rate so the telegraph animation actually FINISHES at `Windup`. This is not
--      cosmetic - stampede movement is `ReceiveTick -> if IsStampeding and NOT Montage_IsPlaying`,
--      so a still-playing start montage pins the body in place however early we set the flag.
--   2. At `Windup`, write the start beat ourselves (the same five writes, in the same order).
--
-- THE COMPENSATION. The native delay still fires at `rawLen - 0.1` and re-runs those writes -
-- harmless, they are idempotent - EXCEPT that it restarts RetriggerableDelay(StampedeDuration),
-- so the charge would end at `rawLen - 0.1 + StampedeDuration` and run long by the whole amount we
-- saved. We cannot pre-empt that node, so we feed it the number that lands the end where we want:
--     StampedeDuration := Windup + Run - rawLen + 0.1
-- The native timer owns the end, EndChargeWithExplosion fires once, and the blast is untouched.
--
-- WHY THE LENGTH IS CACHED AS A NUMBER. Resolving the montage is a StaticFindObject, and on this
-- UE4SS build that is a full UObject-array walk (~20-30ms) even when the asset is resident - far
-- too expensive per charge. We resolve ONCE per session and keep the float. A number cannot
-- dangle, so this is not the captured-wrapper hazard (CLAUDE.md 3) it looks like.
-- =======================================================================

-- Charge tuning that is NOT per variant. Everything a variant would want to differ lives in the
-- QuickCharge opts instead.
local QC = {
    Speed      = 4500,   -- the native WalkSpeed cap for a stampede; only MaxAcceleration reaches it
    MinRate    = 1,      -- never SLOW the telegraph down: a Windup longer than the montage no-ops
    MinNative  = 0.25,   -- floor on the compensated StampedeDuration (see THE COMPENSATION)
    LateMs     = 60,     -- fire the start beat a hair AFTER the montage ends, never before it
    RestoreMs  = 500,    -- slack past the run before MaxAcceleration is put back
}

-- The raw montage length in seconds, resolved once per session. nil = not resolved yet.
local chargeMontageLen

-- actor key -> generation counter for this peccary's active charge. A new charge bumps it;
-- deferred charge callbacks compare against it and bail out if a newer charge has since started,
-- so a stale one never acts on a body mid-new-charge. Cleared in H.ChargeForget (OnDeath).
local chargeToken = {}

-- actor key -> the MaxAcceleration this body walks at, captured ONCE before its first charge boost.
-- Not re-read per charge on purpose: the re-charge gap is short enough that a new charge can start
-- on the same beat the previous restore was due, and a re-capture there would bank the BOOSTED
-- value as the walking one and never give it back.
local chargeAccelBase = {}

local function windupLength()
    if chargeMontageLen then return chargeMontageLen end

    local m = ASSETS.GetIfValid(ENUMS.Anims.PECCARY_CHARGE_START)
    if not m then return nil end

    local len
    pcall(function() len = tonumber(m.SequenceLength) end)
    if not len or len <= 0 then
        pcall(function() len = tonumber(m:GetPlayLength()) end)
    end
    if not len or len <= 0 then return nil end

    chargeMontageLen = len
    -- ONCE per session, and deliberately not debug-gated: this number is the ceiling on every
    -- Windup knob in the file, and it is the first thing to check if a QuickCharge no-ops.
    Utils.Log("QuickCharge - peccary charge montage is "
              .. string.format("%.2f", len) .. "s raw")
    return len
end


-- [AUTHORITY, def.OnCharge] Shorten this peccary's charge telegraph and (optionally) make the run
-- itself faster. Call it as the whole handler:
--     OnCharge = H.ChargePeccaryCharge          -- a thin per-variant wrapper holding its opts
--
-- opts (all optional):
--   Windup   seconds of telegraph before the body starts moving (default 1.0). Ignored if it is
--            already >= the raw montage length - there is nothing to save.
--   Run      seconds the stampede then runs (default 3). ABSOLUTE, never read off the actor.
--   Accel    MaxAcceleration FOR THE RUN ONLY, restored afterwards. This - not `Speed` - is the
--            charge's actual velocity: the run is a flat AddMovementInput per tick, so the body
--            ramps LINEARLY at MaxAcceleration and peaks near `Accel x Run`, with 4500 only a cap.
--            Leave nil to charge at whatever the walking value is.
--   Speed    the WalkSpeed cap (default 4500).
--
-- Returns true if it took over this charge, false if it left the native timing alone.
function H.QuickCharge(actor, opts)
    if not Utils.IsAuthority() then return false end
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return false end
    opts = opts or {}

    local rawLen = windupLength()
    if not rawLen then return false end   -- unmeasurable: leave the native windup alone

    local windup = opts.Windup or 1.0
    local run    = opts.Run or 3
    local rate   = rawLen / windup
    if rate <= QC.MinRate then return false end   -- asked for a windup we already have (or longer)

    -- The number the NATIVE delay must be handed so the run ends where we want it to.
    local native = windup + run - rawLen + 0.1
    if native < QC.MinNative then
        -- A Run shorter than the saving. The native beat would land after our end and restart the
        -- whole stampede, so refuse rather than ship a double charge.
        LogDebug("QuickCharge - Run too short for a " .. windup .. "s windup, staying native",
                 SETTINGS.DEBUG_NPC_ACTIONS)
        return false
    end

    local key = Utils.ActorKey(actor)
    if not key then return false end
    local token = (chargeToken[key] or 0) + 1
    chargeToken[key] = token

    -- PRE hook, so both writes land before the body reads them: Broadcast_CombatAbility1 is a
    -- NetMulticast the ENGINE dispatches, which is what makes our callback a genuine PRE
    -- ([[ue4ss-local-script-call-hook-is-post]] is about BP-to-BP local calls, not this).
    pcall(function() actor.StampedeStartPlayRate = rate end)
    pcall(function() actor.StampedeDuration = native end)

    local speed = opts.Speed or QC.Speed
    local accel = opts.Accel

    Utils.QueueWork(function()
        if chargeToken[key] ~= token then return end          -- a newer charge owns the body
        if not Utils.IsActorReadyToAttack(actor) then return end   -- died / DBNO / stunned / staggered out

        -- The five native writes, in the native order. WalkSpeed goes through AVU.TagSpeed
        -- because that property CARRIES THE VARIANTTAG FRACTION and a bare 4500 clears it -
        -- exactly what the native beat does, on every peccary, on every charge. Ours keeps it;
        -- the native beat at rawLen-0.1 still clears it afterwards, so this narrows the untagged
        -- window rather than closing it. Harmless either way (a client that samples inside it just
        -- re-derives on the next ClientVisuals sweep), and worth not making worse.
        pcall(function() actor:FlushNetDormancy() end)
        AVU.SetReplicatedProp(actor, "WalkSpeed", AVU.TagSpeed(actor, speed))
        AVU.SetReplicatedProp(actor, "IsStampeding", true)
        pcall(function() actor.LockedInPlaceMontage = true end)
        pcall(function() actor:SetAbilityOnCooldown(1, false, 0) end)

        if accel then
            local move = actor.CharacterMovement
            if IsValid(move) then
                -- The walking value is captured LIVE the FIRST time only, so the restore lands on
                -- whatever Stats left rather than a hardcoded native constant to keep in sync.
                if chargeAccelBase[key] == nil then
                    local live
                    pcall(function() live = tonumber(move.MaxAcceleration) end)
                    if live and math.abs(live - accel) > 0.5 then chargeAccelBase[key] = live end
                end
                pcall(function() move.MaxAcceleration = accel end)

                Utils.QueueWork(function()
                    -- A newer charge owns the body: it has already re-applied the boost and booked
                    -- its own restore, so leaving it alone is correct.
                    if chargeToken[key] ~= token then return end
                    if Utils.IsActorInvalid(actor) then return end
                    local base = chargeAccelBase[key]
                    local m = actor.CharacterMovement
                    if IsValid(m) and base then
                        pcall(function() m.MaxAcceleration = base end)
                    end
                end, run * 1000 + QC.RestoreMs)
            end
        end
    end, windup * 1000 + QC.LateMs)

    return true
end


-- [OnDeath] Drop this body's charge bookkeeping. Both tables are string-keyed, so nothing here
-- collects on its own - a variant using QuickCharge MUST call this from def.OnDeath.
function H.ChargeForget(actor)
    local key = Utils.ActorKey(actor)
    if not key then return end
    chargeToken[key] = nil
    chargeAccelBase[key] = nil
end


-- =======================================================================
-- CHARGE PECCARY - its own QuickCharge profile
-- Bare-reference handlers (Conventions 1), one per difficulty knob set. The windup is the whole
-- point of the variant: it charges near-constantly, so the telegraph is what you actually play
-- against, and [HARD] cuts it to well under a second.
-- =======================================================================

--   Windup - telegraph before it moves (native is the full ~raw montage)
--   Run    - how long the 4500-capped sprint lasts
--   Accel  - run-only MaxAcceleration; peak speed ~= Accel x Run, capped at 4500.
--            (Native walking accel is ~1024, and the stock charge peaks near the cap over 4s.)
--   A Windup already >= the raw montage length is a silent no-op (there is nothing to save).
--     The one-time "charge montage is Xs raw" log line is the ceiling these have to sit under.
H.CHARGE_PROFILE = {
    Normal = { Windup = 0.5, Run = 4, Accel = 900 },
    Hard   = { Windup = 0.2, Run = 4, Accel = 700 },
}

function H.ChargePeccaryCharge(actor)
    H.QuickCharge(actor, STATE.HardModeNoMercy and H.CHARGE_PROFILE.Hard
                                                or H.CHARGE_PROFILE.Normal)
end

-- [pet] the tamed form: the wild Normal profile at every difficulty (a pet with the full
-- wind-up loses its target before it gets moving - same reason as the Magma pet).
function H.ChargePetCharge(actor)
    H.QuickCharge(actor, H.CHARGE_PROFILE.Normal)
end


-- =======================================================================
-- MAGMA PECCARY - a shorter telegraph on the Alpha's native charge
-- No Accel: the run keeps whatever MaxAcceleration the body walks at, which is what the native
-- charge uses. Run matches the native StampedeDuration, so only the windup changes.
-- The two forms differ in WHEN, not by how much: the wild mini-boss only gets it in hard mode,
-- the pet always does.
-- =======================================================================

H.MAGMA_CHARGE = { Windup = 0.4, Run = 4 }

-- [wild] hard mode only
function H.MagmaPeccaryCharge(actor)
    if not STATE.HardModeNoMercy then return end
    H.QuickCharge(actor, H.MAGMA_CHARGE)
end

-- [pet] every difficulty
function H.MagmaPetCharge(actor)
    H.QuickCharge(actor, H.MAGMA_CHARGE)
end


-- =======================================================================
-- MAGMA PECCARY (wild) - bite ignite, "too hot to handle" retaliation, charge FX/type re-theme.
-- Entry points are bare-referenced from AnteNPCs/PeccaryAlpha.lua's def. The tamed pet form
-- (ModulePets/TamedPeccary) has its own separate re-theme/nova - not this section.
-- =======================================================================

-- Direct hits only, gated on the damage type's DISPLAY NAME (CLAUDE.md S5) - so Sharp_*/Blunt_*/
-- Bullet_* subclasses all match, and every DoT is excluded for free (a DoT carries its own name).
local MAGMA_RETALIATE_TYPES      = { Sharp = true, Blunt = true, Bullet = true }
local MAGMA_RETAL_RADIUS         = 300    -- ~3m, roughly the native RoyalCounter's 290
local MAGMA_RETAL_IGNITE_SECS    = 4
local MAGMA_RETAL_THROTTLE_TICKS = 20     -- ~2s between bursts (FAST_TICK = 100ms), matching RoyalCounter's 2s CD

-- Re-loaded right before firing - a preload doesn't stick (CLAUDE.md S3).
local MAGMA_RETAL_DEPS = {
    ENUMS.Effects.MAGMAPEST_EXPLOSION,
    ENUMS.BuffObjects.Ignited,
    ENUMS.BuffObjects.HPDamage,
    ENUMS.DamageType.Fire,
}

local magmaRetaliateTick = {}   -- actor key -> FAST_TICK of the last retaliation burst


-- [AUTHORITY] blast type -> Explosive, not Fire (avoids the crowd-ignite crash; Explosive carries
-- no debuff). Async-loads: Assets aren't resident yet at Stats time.
function H.MagmaChargeType(actor)
    if Utils.IsActorInvalid(actor) then return end
    ASSETS.LoadAsync({ ENUMS.DamageType.Explosive }, function()
        if Utils.IsActorInvalid(actor) then return end
        local dt = ASSETS.GetIfValid(ENUMS.DamageType.Explosive)
        if IsValid(dt) then pcall(function() actor.ChargeDamageType = dt end) end
    end)
end

-- [RENDERER] charge FX -> fire. The multicast reads these members locally on each machine, so this
-- must run from Visuals on every renderer; each set is pcall'd so a missing member no-ops.
function H.MagmaChargeFX(actor)
    if Utils.IsActorInvalid(actor) then return end
    local burst  = ASSETS.GetIfValid(ENUMS.Effects.MAGMAPEST_EXPLOSION)
    local windup = ASSETS.GetIfValid(ENUMS.Effects.CAMPFIRE_BASIC)
    if IsValid(burst) then
        pcall(function() actor.ChargeImpactParticle = burst end)
        pcall(function() actor.ChargeBlastImpactParticle = burst end)
    end
    if IsValid(windup) then
        pcall(function() actor.ChargeLoopParticle = windup end)   -- the windup, at the Forehead socket
    end
end

-- Ignite a PLAYER via the direct Server_ApplyBuff path (Server_TryApplyBuff no-ops server->player).
-- Requires BuffObject_Ignited preloaded (see the def's Assets) so this can't cold-load in-hook.
function H.MagmaIgnite(player, secs)
    if Utils.IsActorInvalid(player) then return end
    Utils.ApplyBuffLinked(player, ENUMS.Debuffs.Ignited, secs)
end

-- "Too hot to handle" burst: magma FX at the peccary + ignite every PLAYER within radius. Players
-- only (an NPC victim would re-enter our damage hook from a timer tick - CLAUDE.md S5). Re-loads
-- its deps first, since a preload doesn't stick (CLAUDE.md S3).
local function magmaFireRetaliation(actor)
    local loc
    if Utils.IsActorValid(actor) then
        local ok, l = pcall(function() return actor:K2_GetActorLocation() end)
        if ok and l then loc = l end
    end
    if not loc then return end

    ASSETS.LoadAsync(MAGMA_RETAL_DEPS, function()
        Utils.QueueWork(function()
            AVU.BroadcastFX(loc, ENUMS.Effects.MAGMAPEST_EXPLOSION, nil, FVector(1.2, 1.2, 1.2))
            AVU.BuffPlayersInRadius(loc, MAGMA_RETAL_RADIUS, {
                { Buff = ENUMS.Debuffs.Ignited, Secs = MAGMA_RETAL_IGNITE_SECS },
            })
        end, 0)
    end)
end

-- [def.OnDamageTaken, bare reference] melee it and it bursts, igniting nearby players.
function H.MagmaRetaliate(victim, damage, dmgType)
    local hitType = AVU.RetaliateGate(victim, damage, dmgType, MAGMA_RETALIATE_TYPES,
        magmaRetaliateTick, MAGMA_RETAL_THROTTLE_TICKS)
    if not hitType then return end

    -- DEFER off the ProcessDamage hook (we're inside it now).
    Utils.QueueWork(function() magmaFireRetaliation(victim) end, 0)
    LogDebug("Magma Peccary - too hot to handle (" .. hitType .. ")", SETTINGS.DEBUG_NPC_ACTIONS)
end

-- [def.OnDeath, bare reference] both books are string-keyed; nothing else prunes them.
function H.MagmaForget(actor)
    H.ChargeForget(actor)
    if Utils.IsActorInvalid(actor) then return end
    magmaRetaliateTick[Utils.ActorKey(actor) or ""] = nil
end


return H
