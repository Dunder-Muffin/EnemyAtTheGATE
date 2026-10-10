-- =======================================================================
-- Pest helpers - the machinery behind AnteNPCs/Pest.lua
--
-- MUST-KNOWS
--   * The SIGNAL record is keyed by Utils.ActorKey, not the wrapper - OnDealtDamage and OnDeath
--     hand us the same pest in DIFFERENT wrappers ([[anteup2-actor-wrapper-identity]]).
--   * A signal pest lures only if it actually CONNECTED - killed first, it records nothing. The
--     same hit also CALLS - see the SIGNAL_CALL rosters; that half is players-only and deferred.
--   * Gravity DIRECTION must stay a UNIT vector: it replicates as Vector_NetQuantizeNormal, and a
--     non-unit value spams "NetSerialize failed" every update. Strength goes in GravityScale.
--   * Buffs go out through Utils.AddBuff (off-hook); a direct Server_TryApplyBuff freezes (S2).
--   * THE LEAP IS A PEST'S ONLY MELEE (Server_DoMeleeAttack always hops), driven by ONE property:
--     LastPestLeapAtLocation - a direction + a speed BAND, never a destination. Full bytecode
--     decode: AnNotes/AnteNPCs/Pest.md.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local ENUMS = require("AnteData.Enums")
local STATE = require("AnteCore.State")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local AVM = require("AnteUtils.AVMath")
local TELE = require("AnteNPCs.PestElectroHelpers")   -- TELE.RearmLunge (shared lunge re-arm)

local LogDebug = Utils.LogDebug

-- Lure reach. Honoured only up to SETTINGS.GAMEPLAY.AI_SENSE.HearingRange - the hard
-- ceiling on every noise event - so keep the two in step.
local LURE_RADIUS   = 5000   -- ~50m; == AI_SENSE.HearingRange, the noise path's real cap
local QUILL_STAGGER = 200    -- ms between quill attachments (spreads the load)

-- Quill row down the back, shared by Razor + Anterazor.
local QUILL_POSITIONS = {
    { FVector(-10, -36, 0), FRotator(180, 40, 0) },
    { FVector(-10, -30, 0), FRotator(180, 15, 0) },
    { FVector(-10, -24, 0), FRotator(180, 350, 0) },
    { FVector(-12, -18, 0), FRotator(180, 335, 0) },
    { FVector(-12, -6, 0),  FRotator(180, 320, 0) },
}

local H = {}

-- ActorKey -> the victim it hit (= the lure target). H.SignalHit writes it, H.SignalNoise
-- reads + clears it.
H.SignalTargets = {}

-- The mark a signal pest leaves on a player. Stinky is the signature (its buff object fires a
-- 1200uu HEARING noise event every tick, so the lure outlives the pest that called it); [HARD]
-- adds the gag. Both are left on their own row durations - Stinky's row is bNoExpiration +
-- Buff.Save, i.e. WASH IT OFF, not wait it out.
local SIGNAL_STINK_SEC = 10   -- Debuff_Stinky's own DefaultDuration
local SIGNAL_SICK_SEC  = 90   -- Debuff_Sick's own DefaultDuration

-- Everything H.SignalHit can apply - put it in the def's Assets. Buff objects load by ROW NAME,
-- so nothing else pulls them in (CLAUDE.md 5).
H.SIGNAL_ASSETS = { ENUMS.BuffObjects.Stinky, ENUMS.BuffObjects.Sick }

-- THE STALKER CALL - who answers a signal, by tier x difficulty. Entries are rolled per body; a
-- raw DT_NPCList row ("Pest", "Peccary") brings the vanilla animal, a variant name an Antevariant,
-- and a duplicate entry is the weight (the normal pack is three-in-six plain Pests on purpose).
--   * Solo = the plain Signal Pest. Pack = the Chonky and Antesignal, which are harder to land.
--   * Not preloaded: these arrive seconds later through the spawner's own two-step load, so a
--     def.Assets entry would be pinning nothing by the time it mattered (CLAUDE.md 3).
local SIGNAL_CALL = {
    Solo = {
        Normal = { "Pest" },
        Hard   = { "Pest", "Pest_Carbonated", "Peccary", "Chonky Pest", "Razor Pest" },
    },
    Pack = {
        Normal = { "Pest", "Pest", "Pest", "Pest_Carbonated", "Chonky Pest", "Razor Pest" },
        Hard   = { "Razor Pest", "Chonky Pest", "Peccary", "Charge Peccary", "Carbunccary",
                   "Phase Peccary" },
    },
}
local SIGNAL_CALL_COUNT = { Solo = 1, Pack = 2 }

-- 15-30m and BEHIND something. The distance is a soft rule (the nav fallback can land closer);
-- the sight rule is the hard one - a stalker that pops into view is just a spawn.
local SIGNAL_CALL_MIN     = 1500
local SIGNAL_CALL_MAX     = 3000
local SIGNAL_CALL_RETRIES = 4     -- candidate spots, one per pass - best effort, may find none
local SIGNAL_CALL_DELAY_MS = 300  -- let the pest's own death sequence finish before the search


-- =======================================================================
-- LOCOMOTION
-- =======================================================================

-- Scale a pest's lunge, folding in the global leap multiplier every variant has to honour.
-- ABSOLUTE off the class default - NOT `field = field * mult`. Stats re-runs on every
-- save-restore/pet re-mutate, so a read-multiply form would compound each time (CLAUDE.md 3) and
-- the pest would get permanently faster.
H.LEAP_BASE = 1000

function H.ScaleLeap(actor, mult)
    actor.PestLeapVelocity = H.LEAP_BASE * mult * AVU.PestLeapMult()
end


-- =======================================================================
-- THE COIL LEAP  (Razor Pest, wild + tamed) - backward hop, then a forward dive.
-- Both legs ride the native launch label (LastPestLeapAtLocation = direction + speed band; full
-- bytecode decode in AnNotes/AnteNPCs/Pest.md). The dive triggers on DISTANCE opened, not a timer, because
-- PestLeapVelocity/GravityScale differ 2.5x between the wild and tamed forms - a fixed delay reads
-- as a 3m coil on one and a 7m flight on the other. OnLeapWindup is PRE, so the aim point is
-- re-asserted across the windup (COIL_AIM_MS); losing that reads as "the coil does nothing".
-- =======================================================================

-- LEG 1, the coil - aim-point OFFSETS from the pest (not a distance; how far it goes is COIL_GAP).
-- BACK picks the speed band and the band is a CLIFF (150/300 are walls, not a curve). LIFT sets
-- the arc angle; never 0, or a flat aim point erases the arc and the pest just slides backward.
-- Tuning detail: AnNotes/AnteNPCs/Pest.md.
local COIL_BACK = 150
local COIL_LIFT = 60

-- HOW FAR BACK BEFORE IT DIVES (uu, 2D, from where the windup started)
local COIL_GAP = 150

-- MIN sits past the native launch delay so the dive can't fire before liftoff; MAX is the hard
-- stop for a pest wedged against a wall that will never open the gap.
local COIL_MIN_MS  = 200
local COIL_MAX_MS  = 1000
local COIL_POLL_MS = 100

-- THE DIVE's only real lever: PestLeapVelocity, scaled across the single coilPounce call (the
-- distance band is already maxed by the time leg 2 fires). Reach saturates on speed - if a dive
-- still lands short, drop COIL_LIFT rather than raising this again. See AnNotes/AnteNPCs/Pest.md.
local COIL_DIVE_MULT = 1.3

-- Where the dive aims above the target's feet. Chest height - aiming higher also shallows the
-- descent angle, the other reach lever.
local COIL_DIVE_AIM_Z = 60

-- Aim-write beats inside the 0.2s Apocalyptic windup - the drains land at ~100ms and ~200ms.
local COIL_AIM_MS = { 50, 150 }

-- One extra IsLungingInAir re-arm after the dive, for a leg that clips terrain on the way down.
-- FALLING-gated: re-arming a GROUNDED pest would let it damage you by walking into you.
local COIL_REARM_MS = 200

-- ActorKey -> { id, from = {X,Y}, ms }. One coil per pest; a windup arriving while one is live is
-- ignored rather than stacked. The id (not a bool) is what stops a stale poll from firing into a
-- NEWER coil.
local coilState = {}
local coilSeq = 0

-- Server_InstantlyLunge with PestLeapVelocity scaled across that ONE call, then put straight back.
--   * The launch label is reached by a plain goto (no Delay), so the scaled value is read
--     synchronously and the window is that one statement.
--   * The restore sits outside the lunge's pcall: a leaked boost would stick for the body's life.
--     Failing the other way is harmless - the boost just misses.
local function boostedLunge(actor, aim, mult)
    local baseLeap
    if mult and mult ~= 1 then pcall(function() baseLeap = actor.PestLeapVelocity end) end
    local boosted = type(baseLeap) == "number"
    if boosted then pcall(function() actor.PestLeapVelocity = baseLeap * mult end) end

    pcall(function() actor:Server_InstantlyLunge(aim) end)

    if boosted then pcall(function() actor.PestLeapVelocity = baseLeap end) end
end

-- [AUTHORITY] The forward leg. The band is recomputed from wherever the coil actually left the
-- pest, which is the entire point of the manoeuvre.
local function coilPounce(actor, key, id, gap)
    local st = coilState[key]
    if not st or st.id ~= id then return end
    coilState[key] = nil

    if Utils.IsActorInvalid(actor) or actor.IsDead then return end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end

    local tl
    pcall(function() tl = target:K2_GetActorLocation() end)
    if not tl then return end

    boostedLunge(actor, FVector(tl.X, tl.Y, tl.Z + COIL_DIVE_AIM_Z), COIL_DIVE_MULT)
    TELE.RearmLunge(actor)   -- re-open contact damage for the dive

    -- The gap the coil actually opened - the number to tune COIL_GAP / COIL_LIFT against.
    LogDebug(string.format("Pest - coil pounce after %.0fuu back", gap or 0),
        SETTINGS.DEBUG_NPC_ACTIONS)

    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        local mode
        pcall(function() mode = actor.CharacterMovement.MovementMode end)
        if mode == ENUMS.MovementMode.FALLING and not actor.IsLungingInAir then
            TELE.RearmLunge(actor)
        end
    end, COIL_REARM_MS)
end

-- [AUTHORITY] Watch the gap open, then dive. Three exits, and each is a real case: the gap is
-- reached (the normal one), the pest LANDED early (a low ceiling or a wall behind it - the attack
-- still has to finish, so dive from wherever it is), or the timeout fires.
local function coilWatch(actor, key, id)
    local st = coilState[key]
    if not st or st.id ~= id then return end

    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.LungeInterrupted then
        coilState[key] = nil
        return
    end

    st.ms = st.ms + COIL_POLL_MS

    local al
    pcall(function() al = actor:K2_GetActorLocation() end)
    local gap = al and math.sqrt(Utils.DistSqXY(al, st.from)) or 0

    local mode
    pcall(function() mode = actor.CharacterMovement.MovementMode end)
    local landed = (mode ~= ENUMS.MovementMode.FALLING)

    if gap >= COIL_GAP or landed or st.ms >= COIL_MAX_MS then
        coilPounce(actor, key, id, gap)
        return
    end

    Utils.QueueWork(function() coilWatch(actor, key, id) end, COIL_POLL_MS)
end

-- [AUTHORITY, def.OnLeapWindup] Bend the leap into the coil.
function H.CoilLeap(actor)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end
    if not Utils.IsAuthority() then return end

    local key = Utils.ActorKey(actor)
    if not key then return end
    if coilState[key] then return end   -- already coiling; let it finish

    if Utils.IsActorInvalid(actor:GetCurrentCombatTarget()) then
        LogDebug("Pest - coil windup, no target", SETTINGS.DEBUG_NPC_ACTIONS)
        return
    end

    local from
    pcall(function() from = actor:K2_GetActorLocation() end)
    if not from then return end

    coilSeq = coilSeq + 1
    local id = coilSeq
    coilState[key] = { id = id, from = { X = from.X, Y = from.Y }, ms = 0 }
    LogDebug("Pest - coil leap armed", SETTINGS.DEBUG_NPC_ACTIONS)

    -- LEG 1 rides the NATIVE launch; we only move its aim point, repeatedly, across the windup.
    -- The point goes behind the pest ON THE TARGET LINE, not on its facing - the native yaw-face
    -- runs after this hook, so the pest's own forward vector isn't pointing where you'd assume yet.
    for _, atMs in ipairs(COIL_AIM_MS) do
        Utils.QueueWork(function()
            local st = coilState[key]
            if not st or st.id ~= id then return end
            if Utils.IsActorInvalid(actor) or actor.IsDead then return end

            local t = actor:GetCurrentCombatTarget()
            if Utils.IsActorInvalid(t) then return end

            local al, tl = actor:K2_GetActorLocation(), t:K2_GetActorLocation()
            if not al or not tl then return end
            local dx, dy = al.X - tl.X, al.Y - tl.Y          -- AWAY from the target
            local d = math.sqrt(dx * dx + dy * dy)
            if d < 1 then return end

            pcall(function()
                actor.LastPestLeapAtLocation =
                    FVector(al.X + dx / d * COIL_BACK, al.Y + dy / d * COIL_BACK, al.Z + COIL_LIFT)
            end)
        end, atMs)
    end

    Utils.QueueWork(function() coilWatch(actor, key, id) end, COIL_MIN_MS)
end


-- =======================================================================
-- ZIGZAG LEAP - generic pest machinery: the Flurry Pest's weave AND the hard-mode Razor/Anterazor
-- evade both ride it. Same native launch label as the coil (direction + speed band; full decode
-- AnNotes/AnteNPCs/Pest.md). Under 150uu the band is already an 0.8x shuffle-hop, so ZIG_MIN_DIST sits
-- above the band's 300 breakpoint - a zigzag only fires on an approach it's already rewarding.
-- Same PRE-hook re-assert pattern as the coil leap above (ZIG_AIM_WRITE_MS).
-- State keyed by Utils.ActorKey, never the wrapper ([[anteup2-actor-wrapper-identity]]).
-- =======================================================================

-- Aim-bend timing, same reasoning as the coil's COIL_AIM_MS. Losing a beat leaves the leap dead
-- straight with no other symptom.
local ZIG_AIM_WRITE_MS = { 50, 150 }   -- drain at ~100ms / ~200ms, inside the 0.2s windup

-- Distance bands (uu, 2D). How many times to zigzag - less if closer. A MIN at/above the commit
-- distance means the gate never opens (the Flurry also widens MeleeAttackRange to commit further out).
local ZIG_MIN_DIST = 500
local ZIG_FAR_DIST = 1300

-- Waypoint shape: the dogleg sits at ZIG_WAYPOINT_FRAC of the way to the target, swung
-- ZIG_YAW_DEG off the straight line. Bigger yaw = wider weave; too big and the pest visibly leaps
-- away from you before committing.
local ZIG_YAW_DEG       = 55
local ZIG_WAYPOINT_FRAC = 0.55

-- Per-leg timing. ZIG_LEG_MS = timeout fallback between legs (a connecting hit advances early via
-- H.ZigOnHit). ZIG_REARM_MS re-arms IsLungingInAir mid-flight (a ground graze else eats the flag).
-- ZIG_CAP_SLACK_MS pads the worst-case leg chain so a wedged combo still cleans itself up.
local ZIG_LEG_MS       = 700
local ZIG_IMPACT_MS    = 250
local ZIG_REARM_MS     = 200
local ZIG_CAP_SLACK_MS = 800

-- The [HARD] Razor evade shape - pass it to H.ZigLeap as `opts`. Shared by the wild Razor and
-- Anterazor (Pest.lua) and the tamed Razor (TamedPests.lua) so all three weave the same.
-- MaxLegs 2 = one side hop, then the dive. Without it a commit past ZIG_FAR_DIST becomes a
-- 3-leg flurry whose last leg fires straight off the landing.
-- DiveLiftDeg / DiveMult shape that dive (a bare lunge with no windup hop - flat unless lifted);
-- 10 degrees turns the Razor's shin-high glide into a waist-high one. See AnNotes/AnteNPCs/Pest.md 3.
H.HARD_EVADE = { MinDist = 200, MaxLegs = 2, DiveLiftDeg = 10 }   -- 2m; under it the normal/coil leap stands


-- =======================================================================
-- RAZOR BLEED - the on-hit bleed roll shared by the Razor family.
-- Our proc goes through Utils.AddBuff, which skips the native bleed roll, so the Thick Skinned
-- trait (a buff row on the player) is honoured here instead: it halves the chance.
-- =======================================================================

local THICK_SKINNED_ROW = "Buff_Trait_ThickSkinned"

-- [AUTHORITY, def.OnDealtDamage] One roll per hit against `odds` = { Bleed = %, Severe = % }
-- (0-100, summing to at most 100), applied to the torso. Thick Skinned halves both.
function H.RazorBleed(victim, odds)
    if Utils.IsActorInvalid(victim) then return end
    local mult = 1
    if Utils.IsPlayer(victim) and Utils.ActorHasBuff(victim, THICK_SKINNED_ROW) then mult = 0.5 end

    local severe = (odds.Severe or 0) * mult
    local bleed  = (odds.Bleed or 0) * mult
    local r = math.random() * 100
    local row
    if r < severe then
        row = ENUMS.Debuffs.SevereBleeding
    elseif r < severe + bleed then
        row = ENUMS.Debuffs.Bleeding
    else
        return
    end
    Utils.AddBuff(victim, row, false, 0, 4)
end

-- key -> { id, leg, legs, actor, endsAt, points }
local zigState = {}
local zigSeq = 0

-- Rotate the (pest -> target) vector by `yawDeg` and walk `frac` of the way along it. Returns a
-- point at the TARGET's height (the pest leaps at eye level; a ground-height waypoint makes leg 1
-- dive into the floor and eat its own IsLungingInAir).
local function doglegPoint(from, to, yawDeg, frac)
    local dx, dy = (to.X or 0) - (from.X or 0), (to.Y or 0) - (from.Y or 0)
    if dx * dx + dy * dy < 1 then return nil end

    local r = AVM.RotateYaw(FVector(dx, dy, 0), yawDeg)
    return FVector((from.X or 0) + r.X * frac, (from.Y or 0) + r.Y * frac, to.Z or 0)
end

-- End the weave. Idempotent, and `id` keeps a stale hard-cap timer from clobbering a NEWER combo.
local function zigFinish(key, id)
    local st = zigState[key]
    if not st or st.id ~= id then return end
    zigState[key] = nil
end

-- Fire leg `leg` (2..legs). The step guard is what lets the impact path and the timeout path race
-- safely: both schedule the same zigFire and only the first one through does anything.
local function zigFire(key, leg)
    local st = zigState[key]
    if not st or st.leg ~= leg - 1 then return end

    local actor = st.actor
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.LungeInterrupted then
        zigFinish(key, st.id)   -- netted / stunned / dead: the launch label would bail anyway
        return
    end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then
        zigFinish(key, st.id)
        return
    end

    st.leg = leg

    local from = actor:K2_GetActorLocation()
    local to   = target:K2_GetActorLocation()

    -- The LAST leg goes for the body, lifted by DiveLiftDeg; the middle ones swing to the next dogleg.
    local aim
    local final = leg >= st.legs
    if final then
        local z = to.Z
        if st.liftDeg then z = z + AVM.DistXY(from, to) * math.tan(math.rad(st.liftDeg)) end
        aim = FVector(to.X, to.Y, z)
    else
        aim = doglegPoint(from, to, (st.points[leg] or 1) * ZIG_YAW_DEG, ZIG_WAYPOINT_FRAC)
    end
    if not aim then
        zigFinish(key, st.id)
        return
    end

    -- Zero the velocity BEFORE re-lunging. The forced-apocalyptic launch OVERRIDES velocity so
    -- this is normally redundant - kept as belt-and-braces against the additive non-apoc launch
    -- ever coming back (see the LEAP CONTRACT above).
    pcall(function() actor.CharacterMovement:StopMovementImmediately() end)
    boostedLunge(actor, aim, final and st.diveMult or nil)
    TELE.RearmLunge(actor)   -- re-open contact damage for this leg

    LogDebug("Pest - zigzag leg " .. leg .. "/" .. st.legs, SETTINGS.DEBUG_NPC_ACTIONS)

    if leg >= st.legs then
        Utils.QueueWork(function() zigFinish(key, st.id) end, ZIG_LEG_MS)
    else
        Utils.QueueWork(function() zigFire(key, leg + 1) end, ZIG_LEG_MS)   -- timeout fallback
    end
end

-- Re-arm IsLungingInAir while a leg is in the air. Cheap (three property calls, no traces), and
-- it is the only thing standing between a mid-flight ground graze and a leg that lands with no
-- contact damage at all.
local function zigWatch(key, id)
    local st = zigState[key]
    if not st or st.id ~= id then return end

    local actor = st.actor
    if Utils.IsActorInvalid(actor) or actor.IsDead then
        zigFinish(key, id)
        return
    end

    -- Only while genuinely airborne - re-arming a GROUNDED pest would let it damage on contact
    -- while it merely walks into you.
    --   * Read MovementMode, don't call IsFalling(): the property read is used elsewhere in the
    --     mod and is known good, whereas a missing UFunction would just be eaten by the pcall and
    --     silently disable the whole watchdog.
    local mode
    pcall(function() mode = actor.CharacterMovement.MovementMode end)
    if mode == ENUMS.MovementMode.FALLING and not actor.IsLungingInAir then
        TELE.RearmLunge(actor)
    end

    Utils.QueueWork(function() zigWatch(key, id) end, ZIG_REARM_MS)
end

-- [AUTHORITY, def.OnLeapWindup] Bend an in-progress leap into a zigzag.
--   * Decides leg count from the current distance, builds the waypoints, then re-asserts leg 1's
--     aim on every ZIG_AIM_WRITE_MS beat (see the knob above).
--   * Returns silently for a short leap - that is the whole "don't do 2 bounces at 5m" rule.
--   * The entry log is UNCONDITIONAL on purpose: "leaps in a straight line" has three possible
--     causes (hook never fired / gate rejected / aim write lost) that look identical in game, and
--     this line separates the first two from the third in one test.
--   * opts (optional; the hard-mode Razor evade in Pest.lua): MinDist overrides the ZIG_MIN_DIST
--     floor, MaxLegs caps the distance-derived leg count (2 = one side hop then the dive).
--   * RETURNS true when this leap is weave-owned (committed here, or already mid-weave) so a
--     caller can skip its own aim writes - CoilLeap and the weave fight over the same beats.
function H.ZigLeap(actor, opts)
    if type(opts) ~= "table" then opts = nil end   -- belt: a dispatch-forwarded arg is never ours
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end

    local key = Utils.ActorKey(actor)
    if not key then return end

    local now = os.clock()
    for k, st in pairs(zigState) do if st.endsAt < now then zigState[k] = nil end end   -- prune stale
    if zigState[key] then return true end   -- already weaving: let it finish, don't stack combos

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then
        LogDebug("Pest - leap windup, no target", SETTINGS.DEBUG_NPC_ACTIONS)
        return
    end

    local from = actor:K2_GetActorLocation()
    local to   = target:K2_GetActorLocation()
    local dist = AVM.DistXY(from, to)

    local minDist = (opts and opts.MinDist) or ZIG_MIN_DIST
    if dist < minDist then
        LogDebug(string.format("Pest - leap windup at %.0fuu, under the %duu zigzag floor",
            dist, minDist), SETTINGS.DEBUG_NPC_ACTIONS)
        return   -- too close to be worth splitting; the native single leap stands
    end
    local legs = (dist >= ZIG_FAR_DIST) and 3 or 2
    if opts and opts.MaxLegs and legs > opts.MaxLegs then legs = opts.MaxLegs end

    -- Alternate the opening side per pest so a pack doesn't weave in lockstep.
    local side = (math.random(0, 1) == 0) and 1 or -1

    -- One dogleg per leg except the last, which aims at the target itself. Recomputed against the
    -- LIVE target position at fire time for the later legs (a player runs), so this list only
    -- carries the side each leg swings to.
    local points = {}
    for i = 1, legs - 1 do
        points[i] = side * ((i % 2 == 1) and 1 or -1)
    end

    zigSeq = zigSeq + 1
    local id = zigSeq
    local lastWrite = ZIG_AIM_WRITE_MS[#ZIG_AIM_WRITE_MS]
    local capMs = lastWrite + legs * ZIG_LEG_MS + ZIG_CAP_SLACK_MS
    zigState[key] = { id = id, leg = 0, legs = legs, actor = actor, points = points,
                      endsAt = now + capMs / 1000,
                      liftDeg = opts and opts.DiveLiftDeg, diveMult = opts and opts.DiveMult }

    LogDebug(string.format("Pest - leap windup at %.0fuu -> %d-leg zigzag", dist, legs),
        SETTINGS.DEBUG_NPC_ACTIONS)

    -- LEG 1 rides the NATIVE launch - we only bend its aim point, repeatedly, across the windup.
    local firstSide = points[1]
    for _, atMs in ipairs(ZIG_AIM_WRITE_MS) do
        Utils.QueueWork(function()
            local st = zigState[key]
            if not st or st.id ~= id or st.leg > 1 then return end   -- leg 2 has taken over
            if Utils.IsActorInvalid(actor) or actor.IsDead then return end

            local t = actor:GetCurrentCombatTarget()
            if Utils.IsActorInvalid(t) then return end

            local p = doglegPoint(actor:K2_GetActorLocation(), t:K2_GetActorLocation(),
                                  firstSide * ZIG_YAW_DEG, ZIG_WAYPOINT_FRAC)
            if not p then return end

            st.leg = 1
            pcall(function() actor.LastPestLeapAtLocation = p end)
        end, atMs)
    end

    -- Leg 2 timeout fallback; the impact path (H.ZigOnHit) can bring it forward. Timed off the
    -- LAST aim write, which is the point the native launch has definitely taken our value.
    Utils.QueueWork(function() zigFire(key, 2) end, lastWrite + ZIG_LEG_MS)
    Utils.QueueWork(function() zigWatch(key, id) end, lastWrite + ZIG_REARM_MS)
    Utils.QueueWork(function() zigFinish(key, id) end, capMs)   -- unconditional cleanup

    return true   -- committed: this leap is weave-owned
end

-- IMPACT half of impact-or-timeout: route the def's OnDealtDamage here. This runs inside the
-- ProcessDamage dispatch, so it does table reads + a QueueWork and NOTHING else (CLAUDE.md 6).
function H.ZigOnHit(actor)
    if Utils.IsActorInvalid(actor) then return end
    local key = Utils.ActorKey(actor)
    local st = key and zigState[key]
    if not st or st.leg < 1 or st.leg >= st.legs then return end

    local leg = st.leg
    Utils.QueueWork(function() zigFire(key, leg + 1) end, ZIG_IMPACT_MS)
end

-- Weave-state accessors for machinery OUTSIDE this file (PestSnowHelpers' SnowRetreat is the
-- consumer: mid-combo hits must not retreat, and a finished weave is ended eagerly so zigWatch
-- stops re-arming a body about to be teleported).
function H.ZigMidCombo(key)
    local st = key and zigState[key]
    return (st and st.leg < st.legs) == true
end

function H.ZigEnd(key)
    local st = key and zigState[key]
    if st then zigFinish(key, st.id) end
end


-- =======================================================================
-- POST-LEAP RECOVERY - a no-FX pause between leaps ([HARD] Razor Pest).
-- LEVER = the BT `Stunned` bool (AVU.SetBtStunned) - a pest has no cooldown property.
-- MeleeAttack_OnCooldown, BTDecorator_TagCooldown, and a real stun buff were all tried and are
-- dead ends here (why: AnNotes/AnteNPCs/Pest.md, [[af-bt-tag-cooldown-gate]]). BT_Main_Pest's root selector
-- parks on Stunned at HIGH priority, so Hold REPLACES the tree's own post-attack wait rather than
-- stacking with it - budget it as the whole gap. It parks the CHASE too, not just the attack.
-- =======================================================================

-- All in ticks (FAST_TICK is 10/s), measured from the leap WINDUP stamp. One table (CLAUDE.md 6).
local RECOVER = {
    Min   = 4,     -- never look for a landing before this (0.2s windup + liftoff)
    Cap   = 25,    -- ...and never wait past it: a pest wedged mid-air still has to recover
    Hold  = 17,    -- THE DIAL: how long the pause lasts. See the REPLACES note above.
    Stale = 120,   -- drop an entry this old - a pest that died mid-hold never clears its own
}

local recoverState = {}   -- ActorKey -> { at = windup tick, held = tick the pause began, hold }

-- [AUTHORITY, def.OnLeapWindup] Arm the pause. One stamp per leap: a re-stamp while a pause is
-- already pending is ignored, so a stray second windup can't extend an in-flight hold.
--   * `hold` (ticks, optional) replaces RECOVER.Hold for this pest - the tamed Razor pauses shorter.
function H.RecoverArm(actor, hold)
    local key = Utils.ActorKey(actor)
    if not key then return end

    local now = STATE.FAST_TICK
    for k, st in pairs(recoverState) do   -- prune first: a dead pest's OnTick is unregistered
        if now - st.at > RECOVER.Stale then recoverState[k] = nil end
    end

    if recoverState[key] then return end
    recoverState[key] = { at = now, hold = hold }
end

-- [AUTHORITY, def.OnTick] Drive the pause. Free when nothing is pending (one table lookup).
function H.RecoverTick(actor)
    local key = Utils.ActorKey(actor)
    local st = key and recoverState[key]
    if not st then return end

    local now = STATE.FAST_TICK

    if not st.held then
        local waited = now - st.at
        if waited < RECOVER.Min then return end
        -- Wait out the leap itself. Parking a pest mid-weave would not break the combo (the legs
        -- fire off our own QueueWork chain, not the tree) but it would spend the pause on airtime
        -- the player never reads as a pause. The cap is the escape hatch.
        if waited < RECOVER.Cap and (H.ZigMidCombo(key) or actor.IsLungingInAir) then return end
        st.held = now
        AVU.SetBtStunned(actor, true)
        return
    end

    if now - st.held < (st.hold or RECOVER.Hold) then return end
    recoverState[key] = nil
    -- Don't yank a REAL stun that landed on top of ours - it writes the same shared bool and its
    -- own Server_OnBuffRemove is what should clear it. Ours just expires and hands the flag over.
    if not AVU.HasGameplayTag(actor, "Modifier.Stunned") then AVU.SetBtStunned(actor, false) end
end


-- =======================================================================
-- APPEARANCE
-- =======================================================================

-- One quill per tick-step so five attachments don't land on one frame.
function H.AttachQuillRow(actor, emissiveColor)
    for i, p in ipairs(QUILL_POSITIONS) do
        Utils.QueueWork(function()
            if Utils.IsActorInvalid(actor) then return end

            AVU.AttachStaticMesh(actor, ENUMS.Components.SM_QUILL, "hips", {
                Location = p[1],
                Rotation = p[2],
                EmissiveColor = emissiveColor,
                EmissiveStrength = 150,
                Scale = FVector(1, 1.25, 1.25)
            })
        end, QUILL_STAGGER * (i - 1))
    end
end


-- =======================================================================
-- ON-HIT DEBUFFS
-- =======================================================================

-- Fracture ONE random leg (limbs 7/8), never stacking a second on the same one.
function H.MaybeFractureLeg(victim, chancePct)
    if Utils.IsActorInvalid(victim) then return end

    local buffComp = victim.BuffDebuffComponent
    if not buffComp then return end
    if math.random(0, 100) >= chancePct then return end

    local leg = math.random(7, 8)
    if Utils.ActorHasBuff(victim, "Debuff_LegFracture", leg) then return end

    Utils.AddBuff(victim, "Debuff_LegFracture", false, 0, leg)
end


function H.FractureBothLegs(victim)
    if Utils.IsActorInvalid(victim) then return end
    if not IsValid(victim.BuffDebuffComponent) then return end

    Utils.AddBuff(victim, "Debuff_LegFracture", false, 0, 7)   -- left leg
    Utils.AddBuff(victim, "Debuff_LegFracture", false, 0, 8)   -- right leg
end


-- =======================================================================
-- SIGNAL MECHANIC
-- =======================================================================

-- [AUTHORITY] Shared setup for the signal pests' Pest_Volatile base: keep the body and the native
-- contact detonation (capped by MeleeDamage), strip the rest of the volatile kit.
--   * Gib salvage - TryGibbingNPC pays GibInfo.GibSalvage ("gibbed_pest_volatile") UNCONDITIONALLY
--     incl. its explosion self-gib, so blank it and let OnGibbed be the only payout (still
--     gibbable). Regular loot needs nothing - PotentialLootWhenKilled is a single "None".
--   * Kill credit - blanked, so a kill never unlocks the Pest_Volatile compendium entry or bumps
--     STAT_KILLS_PEST. Real volatiles elsewhere are untouched.
--   * Radiation aura - stripped; ClearRadiationZone explains why its damage timer is a crash risk.
function H.VolatileBaseSetup(actor)
    if Utils.IsActorInvalid(actor) then return end

    AVU.ClearGibLoot(actor)
    AVU.BlankKillCredit(actor)
    AVU.ClearRadiationZone(actor)
end


-- [AUTHORITY] The stalker call: something answers the signal from out of sight and comes for the
-- player who tripped it. Players only, same reason the mark is (an NPC victim would have the pack
-- hunting one of its own). Deferred timing / late origin read / best-effort search: AnNotes/AnteNPCs/Pest.md
-- section 5.
--   * `victim` is a fresh ProcessDamage wrapper crossing a delay, so it is re-validated at use
--     (the AVU.LockAggro DelayMs pattern).
local function signalCall(victim, tier)
    local roster = SIGNAL_CALL[tier][STATE.HardModeNoMercy and "Hard" or "Normal"]

    Utils.QueueWork(function()
        if Utils.IsActorInvalid(victim) or Utils.IsDeadSafe(victim) then return end
        local at = victim:K2_GetActorLocation()
        if not at then return end

        AVU.SpawnReinforcements({
            Npcs       = roster,
            Count      = SIGNAL_CALL_COUNT[tier],
            Origin     = at,
            MinDist    = SIGNAL_CALL_MIN,
            MaxDist    = SIGNAL_CALL_MAX,
            OutOfSight = victim,      -- the whole point: it must arrive unseen
            Retries    = SIGNAL_CALL_RETRIES,
            Target     = victim,      -- bare lock = one-shot; it comes for YOU, then fights normally
            Opts       = { SpawnDelay = 250 },   -- no spawn anim to wait out; render the variant fast
            Label      = "Signal pest",
        })
    end, SIGNAL_CALL_DELAY_MS)
end

-- [AUTHORITY, def.OnDealtDamage] The whole signal-pest contract: MARK the victim, record it as the
-- lure target, then die. Shared by every signal variant.
--   * ApplyBuffLinked, not AddBuff - Server_TryApplyBuff routes on Is_Locally_Controlled and
--     silently no-ops server->player. Both applies are EIGT-deferred and re-resolve the victim by
--     path, so the pest killing itself on the next line can't strand them.
--   * PLAYERS ONLY: Stinky's noise event would have the pack it just summoned fighting one of
--     its own.
--   * The record lands BEFORE IsDead so the OnDeath lure can read it.
local function signalMark(attacker, victim, tier)
    if Utils.IsActorInvalid(attacker) or Utils.IsActorInvalid(victim) then return end

    if Utils.IsPlayer(victim) then
        Utils.ApplyBuffLinked(victim, ENUMS.Debuffs.Stinky, SIGNAL_STINK_SEC)
        if STATE.HardModeNoMercy then
            Utils.ApplyBuffLinked(victim, ENUMS.Debuffs.Sick, SIGNAL_SICK_SEC)
        end
        signalCall(victim, tier)
    end

    local key = Utils.ActorKey(attacker)
    if key then H.SignalTargets[key] = victim end

    attacker.IsDead = true
    attacker:OnRep_IsDead()
end


-- [AUTHORITY, def.OnDealtDamage] The plain signal contract - mark, call ONE stalker, die.
function H.SignalHit(attacker, victim)
    signalMark(attacker, victim, "Solo")
end


-- [AUTHORITY, def.OnDealtDamage] The heavier signal bodies (Chonky, Antesignal): same contract,
-- but two answer instead of one, off a nastier roster.
function H.SignalHitPack(attacker, victim)
    signalMark(attacker, victim, "Pack")
end



-- [AUTHORITY] The SAME lure as one engine noise event instead of a sweep + per-NPC controller
-- pokes - instigator = the victim (who every hearer aggros), position = the pest (so the radius is
-- centred where it died). Every signal variant uses this; the old SphereOverlapActors sweep is gone.
--   * Cheaper AND better-behaved: one native call, flat cost as the room fills, and it goes
--     through real perception - so allies/pets are skipped (the sweep force-targeted a pet onto
--     its own owner) and hearers PATH to the target instead of wallhacking to it.
--   * Everyone hearing it also flinches (Server_AttemptStartle). On a *signal* pest that reads as
--     the whole room jolting, which is the point.
--   * Range is capped by the listener: the smaller of (Range, the hearer's HearingRange) wins, so
--     LURE_RADIUS can never exceed AI_SENSE.HearingRange. Details: AnNotes/AnteSystems/NPCPerception.md.
function H.SignalNoise(actor)
    if Utils.IsActorInvalid(actor) then return end

    local key = Utils.ActorKey(actor)
    local target = key and H.SignalTargets[key]
    if key then H.SignalTargets[key] = nil end
    if Utils.IsActorInvalid(target) then return end   -- never hit anything -> don't lure

    AVU.ReportNoise(target, {
        Tag   = AVU.NOISE_TAGS.Aggro,
        Range = LURE_RADIUS,
        Pos   = actor:K2_GetActorLocation(),
    })
end


-- =======================================================================
-- SHIELD PEST - energy shell + mask + absorb layer (wild variant AND tamed pet)
-- =======================================================================
-- The game HAS a shield pest class but never finished wiring it: no DT_NPCList row of its own, so
-- no spawner and no pet item can ever produce one, and taming it hands back a plain Pest. So we
-- don't use that class at all - we BUILD the shield pest onto an ORDINARY Pest from the recipe in
-- its own SCS, which makes it a normal variant everywhere (spawners, taming, pet re-mutation).
-- The recipe, read off that Blueprint - do not "tidy" these numbers:
--   * BodyShieldComponent  the absorb pool (added at runtime; AUTHORITY)
--   * ShieldMesh           the pest's OWN body mesh, leader-posed, energy-shield material, hidden,
--                          component-tagged "bodyshield" (RENDERER)
--   * CharacterMesh1       the sniper-helm mask on bone "Head". The +155 X compensates the
--                          human-rig offset baked into the grunt head meshes.

local SHIELDPEST_SHELL_MESH = ENUMS.Components.SK_HOPPER
local SHIELDPEST_MASK_MESH  = ENUMS.Components.SK_SNIPER_HEAD
local SHIELDPEST_MASK_LOC   = FVector(155.2, -1.46, -0.47)
local SHIELDPEST_MASK_ROT   = FRotator(0, 270, 270)
local SHIELDPEST_MASK_SCALE = FVector(1.02, 1.02, 1.02)

-- Everything the build needs RESIDENT - put this in the def's Assets. AddComponentByClass on a
-- cold class would blocking-load inside the tick hook (CLAUDE.md 2).
H.SHIELD_PEST_ASSETS = {
    AVU.BODYSHIELD_CLASS, AVU.SHIELD_SHELL_MAT, SHIELDPEST_SHELL_MESH, SHIELDPEST_MASK_MESH,
}


-- [AUTHORITY] The absorb pool. Call from OnReady (Assets are loaded by then); opts are
-- AVU.SetBodyShield's. Idempotent, so it is safe on the re-runnable pipeline and on pet re-mutation.

function H.ShieldPestShield(actor, opts)
    return AVU.AddBodyShield(actor, opts or {})
end


-- [RENDERER] The look: energy shell + mask. Call from Visuals. opts.Color = FVector shell tint.
-- GUARDED ONCE per actor internally - the attach is not idempotent and a pet is re-mutated on
-- every respawn, so without this a re-mutate stacks a second helmet on its head.
local shieldPestGeared = {}   -- ActorKey -> true (a redeploy is a new actor/name -> it rebuilds)

function H.ShieldPestGear(actor, opts)
    opts = opts or {}
    if Utils.IsActorInvalid(actor) then return end

    local key = Utils.ActorKey(actor)
    if not key or shieldPestGeared[key] then return end
    shieldPestGeared[key] = true

    local color = FVector(1, 1, 1)
    if opts.IsPet then color = FVector(12, 12, 12) end

    AVU.AttachShieldShell(actor, SHIELDPEST_SHELL_MESH, { Color = opts.Color })
    AVU.AttachSkeletalMesh(actor, SHIELDPEST_MASK_MESH, "Head", {
        Location = SHIELDPEST_MASK_LOC,
        Rotation = SHIELDPEST_MASK_ROT,
        Scale = SHIELDPEST_MASK_SCALE,
        Color = color,
    })
end


-- =======================================================================
-- PLAGUE INFECT  (Pestilence / Mini Pestilence, Pest_Volatile family - AnteNPCs/PestVolatile.lua)
-- =======================================================================

local PLAGUE_REINFECT_TICKS = 10   -- min ticks between doses on one victim (melee hit + explosion
                                    -- both route through OnDealtDamage on the same swing)

-- The buff objects a plague dose can pull in by row name. Corrosive and Filthy carry none.
H.PLAGUE_ASSETS = { ENUMS.BuffObjects.Sick, ENUMS.BuffObjects.Spores, ENUMS.BuffObjects.Bleeding }

local lastInfectedTick = {}   -- victim key -> FAST_TICK of its last plague dose

-- [AUTHORITY, def.OnDealtDamage] The shared plague proc; cfg picks the dose (see each variant's
-- PLAGUE_* knobs). ApplyBuffLinked (not AddBuff) is the direct Server_ApplyBuff path NPC->player
-- debuffs need, and casts safely on NPC victims too.
--
-- Filthy and the torso bleed have no knob: they ride every dose at the row's own timing, which is
-- what makes them the plague's signature rather than another number to tune.
--   * Filthy (Debuff_Bloodsoaked) never expires - it is washed off, not waited out.
--   * The bleed is pinned to the TORSO so repeat hits land on the limb that already has one and
--     the row's BlockedByExisting refuses them. A free limb each time would stack five bleeds.
--     BuffObject_Bleeding retimes itself to 10s on an NPC and leaves a player on the row's own
--     300s, so the same call reads as a scratch on a pest and a real wound on a player.
function H.PlagueInfect(victim, cfg)
    if Utils.IsActorInvalid(victim) then return end
    if not IsValid(victim.BuffDebuffComponent) then return end

    local key = Utils.ActorKey(victim)
    if not AVU.CooldownReady(lastInfectedTick, key, PLAGUE_REINFECT_TICKS) then return end

    if cfg.Corrosive then Utils.ApplyBuffLinked(victim, ENUMS.Debuffs.FlaskCorrosive, cfg.Corrosive) end
    if cfg.Sick      then Utils.ApplyBuffLinked(victim, ENUMS.Debuffs.Sick, cfg.Sick) end
    if cfg.Spores    then Utils.ApplyBuffLinked(victim, ENUMS.Debuffs.Spores, cfg.Spores) end

    Utils.ApplyBuffLinked(victim, ENUMS.Debuffs.Filthy, nil)
    Utils.ApplyBuffLinked(victim, ENUMS.Debuffs.Bleeding, nil, nil, ENUMS.EBodyLimbs.Torso)

    if cfg.Rad and Utils.IsPlayer(victim) then
        AVU.AddRadiation(victim, cfg.Rad, false)
    end
end


-- =======================================================================
-- CEILING AMBUSH  (Antevolatile / Antesignal Pest, Pest_Volatile family - AnteNPCs/PestVolatile.lua)
-- Cling upside down, drop on a target in range, fight it out on the floor, climb back.
-- =======================================================================

-- actor WRAPPER -> { phase = "ceiling"|"floor", nextCheck, returnAt } (absolute fast-ticks).
-- Weak-keyed: OnTick hands back a STABLE wrapper ([[anteup2-actor-wrapper-identity]]).
local ambushState = setmetatable({}, { __mode = "k" })

-- Flip between the ceiling (goUp) and the floor: gravity direction + strength, mesh pose, a
-- movement-recompute nudge.
local function setAmbushGravity(actor, mesh, goUp, cfg)
    AVU.SetCeilingGravity(actor, goUp, { UpScale = cfg.GravUp, DownScale = cfg.GravDown, Mesh = mesh })
end

-- [AUTHORITY, def.OnTick] Cling until a target comes within cfg.NearSq, drop, fight for
-- cfg.FloorTicks, climb back, re-arm.
--   * cfg.Verify adds the ceiling probe. It matters more here than on the periodic flippers: this
--     machine holds the ceiling INDEFINITELY, so a ceiling-less room is permanent, not a 5s blip.
function H.CeilingAmbushTick(actor, totalTicks, cfg)
    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return "REMOVE" end

    -- True = the probe owns the body (recovery fall / cooldown): freeze the ambush state, no gravity.
    if cfg.Verify and AVU.CeilingVerifyTick(actor, totalTicks, { DownScale = cfg.GravDown }) then
        return
    end

    local now = totalTicks
    local st = ambushState[actor]
    -- FAST_TICK restarts at 0 on a world reload, so a stale entry's absolute ticks would sit in
    -- the "future" forever and the pest would never re-arm. Rebuild on impossible values.
    if st and (st.nextCheck > now + cfg.CheckTicks or st.returnAt > now + cfg.FloorTicks) then
        st = nil
    end
    if not st then
        st = { phase = "ceiling", nextCheck = now + cfg.CheckTicks, returnAt = 0 }
        ambushState[actor] = st
    end

    -- DROPPED: ride out the floor window, then climb back up and re-arm the check.
    --   * The climb is GATED on the verdict map exactly like the re-cling below and like
    --     PeriodicGravFlip's floor branch. Without it a body that already proved (at spawn or by
    --     trying) that there is no ceiling here would launch again after every single drop, and
    --     the tick verify would only catch it 2.5s and ~67m later.
    if st.phase == "floor" then
        if now < st.returnAt then return end
        if not (cfg.Verify and AVU.CeilingKnownBad(actor:K2_GetActorLocation())) then
            setAmbushGravity(actor, mesh, true, cfg)
        end
        st.phase = "ceiling"
        st.nextCheck = now + cfg.CheckTicks   -- next drop can come CheckTicks from now
        return
    end

    -- ON THE CEILING (armed): every CheckTicks, drop if the target has come within range.
    if now < st.nextCheck then return end
    st.nextCheck = now + cfg.CheckTicks

    -- Re-cling if anything grounded us: this is how a body recovers once its 15s probe cooldown
    -- lapses. A known-bad spot keeps it hunting on foot.
    if cfg.Verify then
        local down = false
        pcall(function() down = actor.CharacterMovement.GravityDirection.Z < 0 end)
        if down and not AVU.CeilingKnownBad(actor:K2_GetActorLocation()) then
            setAmbushGravity(actor, mesh, true, cfg)
        end
    end

    local target = AVU.GetCurrentTarget(actor)
    if not target or Utils.IsActorInvalid(target) then return end

    -- HORIZONTAL distance only (Utils.DistSqXY). It's clinging to a ceiling of ARBITRARY height,
    -- so a 3D distance would fold that height into the number - in a tall room a player standing
    -- directly underneath would read as "far" and it would never drop.
    local dsq = Utils.DistSqXY(actor:K2_GetActorLocation(), target:K2_GetActorLocation())
    if dsq > cfg.NearSq then return end

    setAmbushGravity(actor, mesh, false, cfg)
    st.phase = "floor"
    st.returnAt = now + cfg.FloorTicks
end

-- [AUTHORITY, def.OnDeath] It gibs itself on detonation but can still be plain-killed on the
-- ceiling, so the state entry and the inverted gravity both need cleaning up here.
function H.AmbushCleanup(actor)
    if Utils.IsActorInvalid(actor) then return end
    ambushState[actor] = nil
    AVU.RestoreGravity(actor)
end


return H
