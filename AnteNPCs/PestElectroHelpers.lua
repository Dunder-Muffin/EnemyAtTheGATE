-- =======================================================================
-- Telepest blink kit - shared by the WILD Telepest (AnteNPCs/PestElectro) and the TAMED Telepest
-- pet (ModulePets/TamedPests). AUTHORITY, except the client blink mirror at the bottom.
-- Depth: AnNotes/AnteNPCs/PestElectro.md. Shared leap / IsLungingInAir contract: AnNotes/AnteNPCs/Pest.md.
--
-- Blinks to a flank of GetCurrentCombatTarget and redirects the lunge onto it; optionally repeats
-- as an impact-or-timeout multi-dart combo. Always targets the current enemy, so it's owner-safe.
--   * ONE warp per drain tick, mod-wide (lastWarpTick) - two in one frame re-enters our hooks -> AV.
--   * Every move runs OFF the drain (offHook): a move runs the landing spot's BeginOverlap handlers
--     synchronously, and in-drain that froze the game mid-combo (CLAUDE.md S2, the NPC teleport row).
--   * Blink FX is renderer-local: host draws it live, clients mirror it off the replicated jump.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local UEHelpers = require("UEHelpers")
local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local ASSETS = require("AnteCore.AssetManager")
local Utils = require("AnteUtils.Utils")
local ENUMS = require("AnteData.Enums")
local AVU = require("AnteUtils.AVUtils")
local AVM = require("AnteUtils.AVMath")
local LogDebug = Utils.LogDebug

local TE = {}

-- Blink FX paths, EXPOSED so a def's Assets can preload them (a cold first blink would race).
-- The teleporter PROP mesh is a per-def cosmetic and stays in each def's Visuals.
TE.BLINK_FX  = ENUMS.Effects.EXOR_BLINK
TE.BLINK_SFX = "/Game/Audio/Monsters/Exor/NPC_Monk_Blink_Cue.NPC_Monk_Blink_Cue"

-- Warp geometry knobs.
local TELE_MIN_DIST     = 600    -- min distance from the target it can warp to
local TELE_MAX_DIST     = 700    -- max
local TELE_SIDE_MIN_DEG = 30     -- flank arc (front + back 90deg both excluded)
local TELE_SIDE_MAX_DEG = 150
local TELE_RETRIES      = 5      -- LoS position retries (each failure costs a full trace)
local TELE_TRACE_CHAN   = ENUMS.Trace.VISIBILITY
local TELE_EYE_Z        = 60     -- eye height for the LoS trace + lunge aim
local TELE_AIR_Z        = 60     -- warp this far above the target's Z so the leap stays airborne
local TELE_Z_MAX        = 100    -- SAFETY: clamp warp/arc height to [target.Z, target.Z + this]
local TELE_AIM_Z        = 40     -- redirect the lunge at the target's BODY
local TELE_LAUNCH_Z     = 240    -- up-arc of the redirect; apex = AIR_Z + Z^2/2g must stay <= Z_MAX
local TELE_GRAVITY      = 980    -- approx gravity (GravityScale ~1) for the ballistic redirect
local TELE_HOP_MS       = 50     -- worker hop before a move (a 0 delay is not a thread hop)

local lastWarpTick = -1   -- one warp per drain tick, mod-wide (see MUST-KNOWS)
local COMBO_END_STALE = 120   -- seconds before a GroundMs stamp is pruned (a string key never collects)


-- Re-arm the pest's native in-air contact damage: the replicated bool + dirty + OnRep, the same
-- trio the native launch writes. Cheap enough for a watchdog cadence while the dart flies.
--   * `skipOnRep` for a caller in the WorkQueue drain. OnRep_IsLungingInAir calls Montage_Stop with
--     no montage, which stops EVERY playing montage and fires their end callbacks synchronously -
--     a suspect in a mid-combo freeze. ReceiveHit needs only the bool; the OnRep restarts the loop audio.

function TE.RearmLunge(actor, skipOnRep)
    AVU.SetReplicatedProp(actor, "IsLungingInAir", true, { SkipOnRep = skipOnRep })
end


-- [AUTHORITY] Run `fn(actor)` on the game thread, off the WorkQueue drain, with the actor
-- re-resolved by path (the NpcSpawner OFFHOOK recipe). `step` names the hop for the freeze
-- watchdog, and fn re-stamps STATE.LastWork before each later engine call so a wedge names it.
local function offHook(actor, step, fn)
    local path = Utils.ObjectPath(actor)
    if not path then return false end
    Utils.DelayedGameThread(TELE_HOP_MS, function()
        if not STATE.ModEnabled then return end
        local a = Utils.ResolveByPath(path)
        if Utils.IsActorInvalid(a) or a.IsDead then return end
        STATE.LastWork = "OFFHOOK telepest " .. step .. " " .. path
        STATE.LastWorkDone = false
        fn(a)
        STATE.LastWorkDone = true
    end)
    return true
end


-- Renderer-local blink graphic (+ optionally the Monk cue). Cosmetic - it never blocks the
-- teleport. Assets are def-preloaded, so the non-loading resolve inside is a cache hit.
local function telepestBlinkFX(loc, withSound)
    if not Utils.HasRenderer() then return end
    AVU.SpawnLocalNiagara(loc, TE.BLINK_FX, { Lifetime = 1500 })
    if not withSound then return end
    pcall(function()
        local snd = ASSETS.GetIfValid(TE.BLINK_SFX)
        local gs = UEHelpers.GetGameplayStatics()
        local world = Utils.GetWorld()
        if IsValid(snd) and gs and IsValid(world) then
            gs:PlaySoundAtLocation(world, snd, loc, FRotator(0, 0, 0), 1.0, 1.0, 0.0, nil, nil, nil, nil)
        end
    end)
end

-- Public alias - any variant that MOVES a Telepest outside the combo (the tamed pet's pit rescue)
-- should show the same arrival graphic, or the body just appears somewhere else with no cue.
TE.BlinkFX = telepestBlinkFX

-- Trace candidate(eye) -> target(eye). True if CLEAR. Ignores BOTH the pest AND the target: the
-- trace ENDS at the target's body, so not ignoring it means every spot reads blocked.
local function telepestHasLOS(actor, target, cand, tl)
    local from = FVector(cand.X, cand.Y, cand.Z + TELE_EYE_Z)
    local to   = FVector(tl.X, tl.Y, tl.Z + TELE_EYE_Z)
    return not AVU.IsPathBlocked(actor, from, to, { actor, target }, TELE_TRACE_CHAN)
end

-- A point on one of the target's SIDE flanks, at the actor's current (clamped) distance, same
-- height. LoS-PREFERRED but always returns a spot (the last candidate) so the warp never fizzles -
-- reliability beats a perfect line of sight.
local function telepestPickLoc(actor, target, retries)
    local al = actor:K2_GetActorLocation()
    local tl = target:K2_GetActorLocation()

    local dist = AVM.Clamp(AVM.DistXY(al, tl), TELE_MIN_DIST, TELE_MAX_DIST)

    local fwdYaw = 0
    pcall(function() fwdYaw = target:K2_GetActorRotation().Yaw end)

    local lastCand
    for _ = 1, (retries or TELE_RETRIES) do
        local base = TELE_SIDE_MIN_DEG + math.random() * (TELE_SIDE_MAX_DEG - TELE_SIDE_MIN_DEG)
        local off = base + ((math.random() < 0.5) and 0 or 180)
        local ang = math.rad(fwdYaw + off)
        local cand = FVector(tl.X + math.cos(ang) * dist, tl.Y + math.sin(ang) * dist, tl.Z)
        lastCand = cand
        if telepestHasLOS(actor, target, cand, tl) then return cand end
    end
    return lastCand
end


-- Teleport onto a flank of the combat target, then redirect the in-flight lunge onto it.
-- The spot pick and the ballistics run here; the move and the launch run off the drain (offHook).
-- opts (all optional; nil = the classic single warp):
--   Gravity     effective gravity for the redirect (pass 980*GravityScale for a slow float-dart)
--   Speed       fixed redirect speed, with the up-arc solved so the dart falls onto the body.
--               Overrides MinSpeed and LaunchZ
--   MinSpeed    hspeed floor for the arc-solved redirect (default 800; lower alongside Gravity)
--   LaunchZ     arc-solved redirect up-arc (default 240); apex = AIR_Z + LaunchZ^2/2g
--   ForceLunge  re-arm the native in-air contact damage (TE.RearmLunge)
--   Retries     LoS retry cap (rapid re-blinks pass a small number; each retry costs a full trace)
--   Escape      disengage hop: same flank pick + FX, no redirect, velocity killed at the flank

function TE.Teleport(actor, opts)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end
    if STATE.FAST_TICK == lastWarpTick then
        Utils.QueueWork(function() TE.Teleport(actor, opts) end, 200)
        return
    end
    lastWarpTick = STATE.FAST_TICK
    opts = opts or {}

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end

    local dest = telepestPickLoc(actor, target, opts.Retries)
    if not dest then return end

    local tl = target:K2_GetActorLocation()

    -- Teleport AIRBORNE so the redirected leap continues mid-air, clamped so it never lands below
    -- the target's floor or starts above its head.
    local airZ = tl.Z + TELE_AIR_Z
    if airZ < tl.Z then airZ = tl.Z
    elseif airZ > tl.Z + TELE_Z_MAX then airZ = tl.Z + TELE_Z_MAX end
    local ax, ay = dest.X, dest.Y

    local dx, dy = tl.X - ax, tl.Y - ay
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1 then len = 1 end
    local yaw = math.deg(math.atan(dy, dx))

    local vx, vy, vz   -- nil = the escape hop, which launches nothing
    if not opts.Escape then
        local g = opts.Gravity or TELE_GRAVITY
        local dz = (tl.Z + TELE_AIM_Z) - airZ                -- target body vs launch height
        local hspeed
        if opts.Speed then
            local t = len / opts.Speed                       -- flight time at that speed...
            if t < 0.05 then t = 0.05 end
            hspeed, vz = opts.Speed, (dz + 0.5 * g * t * t) / t   -- ...and the arc that lands then
        else
            local launchZ = opts.LaunchZ or TELE_LAUNCH_Z
            local disc = launchZ * launchZ - 2 * g * dz
            if disc < 0 then disc = 0 end
            local t = (launchZ + math.sqrt(disc)) / g        -- time to fall to the target's height
            if t < 0.15 then t = 0.15 end
            hspeed, vz = AVM.Clamp(len / t, opts.MinSpeed or 800, 3000), launchZ
        end
        vx, vy = dx / len * hspeed, dy / len * hspeed
    end

    offHook(actor, opts.Escape and "escape" or "warp", function(a)
        pcall(function()
            a:K2_SetActorLocationAndRotation(FVector(ax, ay, airZ), FRotator(0, yaw, 0), false, {}, true)
        end)
        if not vx then
            STATE.LastWork = "OFFHOOK telepest escape-stop"
            pcall(function() a.CharacterMovement:StopMovementImmediately() end)
            return
        end
        STATE.LastWork = "OFFHOOK telepest launch"
        pcall(function() a:LaunchCharacter(FVector(vx, vy, vz), true, true) end)
        if opts.ForceLunge then
            STATE.LastWork = "OFFHOOK telepest rearm"
            TE.RearmLunge(a)
        end
    end)

    -- The arrival graphic stays on the drain: a component spawn inside a game-thread flush is the
    -- renderer-host paint hazard (S2).
    Utils.QueueWork(function() telepestBlinkFX(FVector(ax, ay, airZ), true) end, TELE_HOP_MS)
    LogDebug(opts.Escape and "Telepest - escape blink (disengage)" or "Telepest - warp + redirect lunge",
        SETTINGS.DEBUG_NPC_ACTIONS)
end


-- [AUTHORITY] Blink to a chosen spot facing `faceActor`: velocity killed, arrival graphic, no
-- redirect (a stuck recovery, a pit rescue). True if the blink went out.

function TE.BlinkTo(actor, dest, faceActor)
    if Utils.IsActorInvalid(actor) or actor.IsDead or not dest then return false end
    local x, y, z = dest.X, dest.Y, dest.Z
    if STATE.FAST_TICK == lastWarpTick then
        Utils.QueueWork(function() TE.BlinkTo(actor, { X = x, Y = y, Z = z }, faceActor) end, 200)
        return true
    end

    local yaw = 0
    pcall(function()
        yaw = actor:K2_GetActorRotation().Yaw
        local fl = faceActor and faceActor:K2_GetActorLocation()
        if fl then yaw = math.deg(math.atan(fl.Y - y, fl.X - x)) end
    end)

    local sent = offHook(actor, "blink", function(a)
        pcall(function()
            a:K2_SetActorLocationAndRotation(FVector(x, y, z), FRotator(0, yaw, 0), false, {}, true)
        end)
        STATE.LastWork = "OFFHOOK telepest blink-stop"
        pcall(function() a.CharacterMovement:StopMovementImmediately() end)
    end)
    if not sent then return false end
    lastWarpTick = STATE.FAST_TICK
    Utils.QueueWork(function() telepestBlinkFX(FVector(x, y, z), true) end, TELE_HOP_MS)
    return true
end


-- =======================================================================
-- THE BLINK COMBO - an impact-or-timeout multi-dart state machine
-- =======================================================================
-- Dart 1 is the classic flank warp (and lightens gravity for the whole window); darts 2..N re-blink
-- onto a fresh flank with the lunge re-armed. A CONNECTED dart advances the next step after
-- ImpactMs, a whiff waits out StepMs - the two paths race safely on the step guard, and a hard-cap
-- cleanup ALWAYS restores gravity.

local comboState = {}   -- fullname -> { id, step, actor, endsAt, grav, o, darts, total }
local comboEnd   = {}   -- fullname -> os.clock() the last combo ended (the GroundMs floor)
local comboSeq = 0

-- End the combo: clear state (which stops the watchdog and further steps) and restore gravity.
-- Idempotent, and `id` keeps a stale hard-cap timer from clobbering a NEWER combo's state.
local function comboFinish(key, id)
    local st = comboState[key]
    if not st or st.id ~= id then return end
    comboState[key] = nil
    comboEnd[key] = os.clock()
    if Utils.IsActorInvalid(st.actor) then return end
    pcall(function() st.actor.CharacterMovement.GravityScale = st.grav or 1.0 end)
end

-- Watchdog: re-arm IsLungingInAir whenever the pest is airborne without it. Two reads, no traces.
-- Self-terminates when comboFinish drops the state. Skipped during the escape blink - a disengage
-- hop must NOT deal contact damage.
local function comboWatch(key)
    local st = comboState[key]
    if not st then return end
    local actor = st.actor
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end
    if st.step <= st.darts then
        pcall(function()
            if not actor.IsLungingInAir and actor.CharacterMovement:IsFalling() then
                TE.RearmLunge(actor, true)   -- in-drain: no OnRep (see TE.RearmLunge)
            end
        end)
    end
    Utils.QueueWork(function() comboWatch(key) end, st.o.RearmMs or 250)
end

-- Fire step `step` (1 = classic warp, 2..darts = re-blinks, darts+1 = the escape blink). The step
-- guard is what lets the impact path and the timeout path race: both schedule the same call and
-- only the first through does anything.
local function comboFire(key, step)
    local st = comboState[key]
    if not st or st.step ~= step - 1 then return end
    st.step = step

    local o = st.o
    local actor = st.actor
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.LungeInterrupted then
        comboFinish(key, st.id)   -- netted/stunned/dead: end it, restore gravity now
        return
    end

    local gs = o.GravityScale or 0.65
    if step == 1 then
        -- Lighten gravity for the whole combo window (guarded read per the 0-read rule; the pest is
        -- WarpDelayMs into its native full-gravity leap here).
        pcall(function()
            local cm = actor.CharacterMovement
            local g = cm.GravityScale
            st.grav = (g and g > 0) and g or 1.0
            cm.GravityScale = gs
        end)
        TE.Teleport(actor, {
            Gravity = 980 * gs, MinSpeed = o.MinSpeed or 900, LaunchZ = o.LaunchZ, Speed = o.Speed,
        })
    elseif step <= st.darts then
        TE.Teleport(actor, {
            Gravity = 980 * gs, MinSpeed = o.MinSpeed or 900, LaunchZ = o.LaunchZ, Speed = o.Speed,
            ForceLunge = true, Retries = o.Retries or 2,
        })
    else
        TE.Teleport(actor, { Escape = true, Retries = o.Retries or 2 })
    end

    if step >= st.total then
        Utils.QueueWork(function() comboFinish(key, st.id) end, o.TailMs or 500)
    else
        Utils.QueueWork(function() comboFire(key, step + 1) end, o.StepMs or 1200)   -- timeout path
    end
end


-- [AUTHORITY] Start the combo - call from the leap trigger (OnShockRing, or OnLeapWindup on a
-- discharged pet). opts:
--   ExtraHits    re-blinks after the classic warp (default 2; total darts = 1 + ExtraHits)
--   WarpDelayMs  dart 1 delay after the shock ring, so the leap is airborne (default 250)
--   StepMs       TIMEOUT fallback between darts (default 1200)
--   ImpactMs     a connected dart re-blinks this soon instead (default 350)
--   TailMs       wait after the final step before restoring gravity (default 500)
--   RearmMs      watchdog cadence (default 250)
--   Retries      LoS retries for re-blinks (default 2; dart 1 uses the full set)
--   GravityScale combo-window GravityScale (default 0.65; the cleanup restores it)
--   MinSpeed     redirect hspeed floor (default 900)
--   LaunchZ      redirect up-arc (default 240) - lower it to flatten the darts (see TE.Teleport)
--   Speed        fixed dart speed, arc solved onto the target (see TE.Teleport)
--   EscapeBlink  extra Escape-mode blink after the last dart, to clear melee range on cooldown
--   GroundMs     time on the ground between combos, measured from the LAST one ENDING. The trigger's
--                own cooldown runs from the combo's START, so a long combo can eat all of it and
--                leave no window to punish the pest in
-- Returns true if a combo started, false if one is already running (or still grounded).

function TE.StartCombo(actor, opts)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return false end

    local key = actor:GetFullName()
    local now = os.clock()
    for k, st in pairs(comboState) do if st.endsAt < now then comboState[k] = nil end end   -- prune
    for k, t in pairs(comboEnd) do if now - t > COMBO_END_STALE then comboEnd[k] = nil end end
    if comboState[key] then return false end   -- re-entry guard: a mid-combo trigger stays native-only

    local ground = opts and opts.GroundMs
    if ground and comboEnd[key] and (now - comboEnd[key]) < ground / 1000 then return false end

    local o = opts or {}
    local warpDelay = o.WarpDelayMs or 250
    local stepMs = o.StepMs or 1200
    local darts = 1 + (o.ExtraHits or 2)
    local total = darts + (o.EscapeBlink and 1 or 0)

    -- Hard cap = every step waiting out its full timeout, plus slack.
    local capMs = warpDelay + total * stepMs + (o.TailMs or 500) + 500
    comboSeq = comboSeq + 1
    local id = comboSeq
    comboState[key] = { id = id, step = 0, actor = actor, endsAt = now + capMs / 1000,
                        o = o, darts = darts, total = total }

    Utils.QueueWork(function() comboFire(key, 1) end, warpDelay)
    Utils.QueueWork(function() comboWatch(key) end, warpDelay + (o.RearmMs or 250))
    Utils.QueueWork(function() comboFinish(key, id) end, capMs)   -- unconditional cleanup
    return true
end

-- True while a combo is running on this actor.
function TE.InCombo(actor)
    local key; pcall(function() key = actor:GetFullName() end)
    local st = key and comboState[key]
    return st ~= nil and st.endsAt >= os.clock()
end


-- The IMPACT half of impact-or-timeout: call from the def's OnDealtDamage. That dispatch is inside
-- the ProcessDamage hook, so ONLY table reads + a QueueWork here (CLAUDE.md 6). Any damage the pest
-- deals advances it, which is benign - it was attacking that instant anyway.

function TE.ComboOnHit(actor)
    if Utils.IsActorInvalid(actor) then return end
    local key = actor:GetFullName()
    local st = comboState[key]
    if not st or st.step < 1 or st.step >= st.total then return end
    local step = st.step
    Utils.QueueWork(function() comboFire(key, step + 1) end, st.o.ImpactMs or 350)
end


-- CLIENT-side blink mirror (defs opt in via ClientTick). The server can't push the FX, but
-- position REPLICATES. A warp arrives as a one-tick DISCONTINUITY: legit movement caps at
-- ~300u/tick, while a warp lands 700-1300u away, so a 600u jump reads as a blink.
-- Weak-keyed by the OnTick wrapper (stable for the life of one registration; freed with it).
local clientBlinkLast = setmetatable({}, { __mode = "k" })   -- OnTick wrapper -> last {X,Y,Z}
local CLIENT_BLINK_JUMP_SQ = 600 * 600

function TE.ClientBlinkTick(actor)
    local loc
    pcall(function() loc = actor:K2_GetActorLocation() end)
    if not loc then return end
    local last = clientBlinkLast[actor]
    clientBlinkLast[actor] = { X = loc.X, Y = loc.Y, Z = loc.Z }
    if not last then return end
    local dx, dy = loc.X - last.X, loc.Y - last.Y
    if dx * dx + dy * dy < CLIENT_BLINK_JUMP_SQ then return end
    telepestBlinkFX(loc, true)   -- arrival-only, matching the host (no origin burst anywhere)
    LogDebug("Telepest - client blink mirror (jump " .. math.floor(math.sqrt(dx * dx + dy * dy)) .. "u)",
        SETTINGS.DEBUG_CLIENT)
end


return TE
