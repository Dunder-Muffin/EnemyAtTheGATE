-- =======================================================================
-- OrderRook helpers - the machinery behind AnteNPCs/OrderRook.lua
--
-- MUST-KNOWS
--   * embShieldShove ignores OnDealtDamage from Fire_Holy's DoT ticks (not just the real swing) -
--     gated on the swing stamp (H.EmbSwing), not PerformingMeleeAttack (latches true after a power
--     attack). AnNotes/AnteNPCs/OrderRook.md, "The three-knockbacks bug".
--   * AGGRO clears the tree's OWN 15s tag cooldown (AI.Cooldown.Ability1) on a cadence, same fix as
--     the Rookram (OrderGroupe.lua) - without it AGGRO only ever lands its first lunge.
--     MeleeAttack_OnCooldown does NOT gate a BT-driven swing (AnNotes), so it can't substitute.
--   * A Rook can never clear FailedHits or MeleeCounter by itself - the native resets both live at
--     the end of a gun burst, and it has no gun. Left alone it fights from cover. AnNotes/AnteNPCs/OrderRook.md,
--     "Why a shield trooper retreats".
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")

local LogDebug = Utils.LogDebug

local H = {}


-- =======================================================================
-- SHIELD EMBOLON
--   * 3-phase cycle: GUARD (3s) -> PRESS (5s) -> AGGRO (7s)
--   * MeleeAttackPlayRate alone doesn't raise the attack rate - AVU.ReleaseSoldierBT is the valve
--   * Every AI_TurtleMode add/remove is a game-thread flush - don't churn it
-- =======================================================================

local EMB_SHIELD_SCALE = { X=1.0, Y=1.0, Z=0.85 }
local EMB_SPEAR  = { Scale = { X=0.6, Y=0.6, Z=0.6 }, Loc = nil, Rot = nil }   -- Loc/Rot nil = keep the native grip
local EMB_BANNER = { Scale = FVector(1.2, 1.25, 0.82), Loc = FVector(-11, 10, 48), Rot = FRotator(0, 180, 0) }

-- local EMB_SHIELD_SCALE = { X=0.85, Y=0.85, Z=0.9 }
-- local EMB_SPEAR  = { Scale = { X=0.6, Y=0.6, Z=0.6 }, Loc = nil, Rot = nil }   -- Loc/Rot nil = keep the native grip
-- local EMB_BANNER = { Scale = FVector(1, 1.1, 0.82), Loc = FVector(-9, 10, 50), Rot = FRotator(0, 180, 0) }

local EMB_REACH_SQ = 180 * 180   -- uu, just inside MeleeAttackRange (200)
local EMB_BT_MELEE_TAG = "AI.Cooldown.Ability1"   -- the tree's OWN gate, not the pawn's Ability1

-- THE CYCLE - 15s total. One table IS the schedule (embPhaseAt walks it in order).
--   Ticks     how long this phase lasts (FAST_TICKs, 10/s)
--   Turtle    pin AI_TurtleMode or strip it
--   Advance   walk the goal onto the target
--   Cd        ticks between swings. Nothing the pawn owns can enforce it, so a turtled phase holds
--             the body still between bashes (embPaceBash) and a mobile one leans on its tag clear
--   Rate      MeleeAttackPlayRate (montages replicate)
--   Apex      MeleeHitApex, scaled with Rate so it lands inside the sped-up swing
--   Speed     walk and sprint speed (one number - see H.EmbTick, in-combat always resolves sprint)
--   Shove     shield bashes knock back (Guard/Press only - AGGRO's spear swings are plain damage)
--   Release   fire AVU.ReleaseSoldierBT ourselves (see EMB_EARLY_RELEASE)
local EMB_EARLY_RELEASE = false   -- off by default: one EIGT flush per swing (AnNotes)

local EMB_PHASES = {
    { Name = "GUARD", Ticks = 30, Turtle = true,  Advance = false,
      Cd = 25, Rate = 1,   Apex = 0.52, PowerApex = 0.22, Speed = 350, Shove = true },
    { Name = "PRESS", Ticks = 50, Turtle = true,  Advance = true,
      Cd = 20, Rate = 1,   Apex = 0.52, PowerApex = 0.22, Speed = 400, Shove = true },
    { Name = "AGGRO", Ticks = 70, Turtle = false, Advance = true,
      Cd = 10, Rate = 1.5, Apex = 0.30, PowerApex = 0.30, Speed = 550, Release = EMB_EARLY_RELEASE },
}

local EMB_CYCLE_TICKS = 0
for _, p in ipairs(EMB_PHASES) do EMB_CYCLE_TICKS = EMB_CYCLE_TICKS + p.Ticks end

local EMB_TURTLE = { Secs = 40, CheckTicks = 20 }   -- buff duration; mid-fight stance-corrective cadence
local EMB_RELEASE = { PadTicks = 2, LungeFallback = 1.4 }   -- slack after the measured montage length
local EMB_KNOCKBACK = { Distance = 800, Up = 250, CdTicks = 40 }   -- shield-bash shove
local EMB_HEAD_TINT = FVector(0.06, 0.05, 0.05)   -- near-black face under the gold helmet
local EMB_TRACE_EXTRA = 80   -- 20 native: margin so a bash still lands on someone backpedalling
local EMB_BRAVERY_TICKS = 10       -- 1s: the FailedHits / MeleeCounter pin
local EMB_TAG_CLEAR_TICKS = 5      -- 0.5s: the mobile branch's own melee tag
local EMB_SWING_WINDOW = 8   -- ticks: how close to our own swing stamp counts as "this swing", not a DoT tick
local EMB_REPATH = { Sq = 150 * 150, Ticks = 15 }   -- re-path only if the goal moved or is stale (1.5s)

local lastEmbSwingTick = {}   -- ActorKey -> FAST_TICK of last swing (wrappers are fresh per hook)
local lastEmbKnockTick = {}   -- victim ActorKey -> FAST_TICK of last shove
local embState         = {}   -- ActorKey -> { t0, phase, goal, goalAt, releasedFor, held } (H.EmbTick)


-- [ALL] Shrink the native riot shield mesh (server: the block geometry; renderer: cosmetic).
local function embModifyShield(actor)
    pcall(function()
        local shield = actor.Shield
        if IsValid(shield) then
            shield:SetRelativeScale3D(FVector(EMB_SHIELD_SCALE.X, EMB_SHIELD_SCALE.Y, EMB_SHIELD_SCALE.Z))
        end
    end)
end


-- [RENDERER] Re-arm the Knife socket with the Lodespear mesh (SwapStaticMesh, native attachment).
local function embReplaceWeapon(actor)
    local knife
    pcall(function() knife = actor.Knife end)
    if not IsValid(knife) then return end

    AVU.SwapStaticMesh(knife, ENUMS.Components.SM_SPEAR_LODE)
    pcall(function()
        knife:SetRelativeScale3D(FVector(EMB_SPEAR.Scale.X, EMB_SPEAR.Scale.Y, EMB_SPEAR.Scale.Z))
        if EMB_SPEAR.Loc then knife:K2_SetRelativeLocation(EMB_SPEAR.Loc, false, {}, false) end
        if EMB_SPEAR.Rot then knife:K2_SetRelativeRotation(EMB_SPEAR.Rot, false, {}, false) end
        knife:SetVisibility(true, true)
    end)
end


-- [RENDERER] Hang the Order banner off the shield face (rides "l_hand", the same bone as Shield).
local function embAddShieldBanner(actor)
    local comp = AVU.AttachStaticMesh(actor, ENUMS.Components.SM_BANNER_HANGING, "l_hand", {
        Immediate = true,
        Material = ENUMS.Components.M_BANNER_ORDER,
        Location = EMB_BANNER.Loc,
        Rotation = EMB_BANNER.Rot,
        Scale = EMB_BANNER.Scale,
    })
    LogDebug(comp and "Embolon - banner drape OK" or "Embolon - banner drape FAILED",
        SETTINGS.DEBUG_NPC_ACTIONS)
end


-- Which phase does `elapsed` ticks into the cycle land in?
local function embPhaseAt(elapsed)
    local t = elapsed % EMB_CYCLE_TICKS
    for _, p in ipairs(EMB_PHASES) do
        if t < p.Ticks then return p end
        t = t - p.Ticks
    end
    return EMB_PHASES[1]   -- unreachable; keeps the return type honest
end


-- [AUTHORITY] Apply a phase (EMB_PHASES row): turtle tag, melee timing, move speed.
local function embEnterPhase(actor, st, phase)
    local prev = st.phase
    st.phase, st.goal, st.goalAt = phase, nil, nil

    -- Only touch the buff when Turtle actually changes - every add/remove is a flush.
    if not prev or prev.Turtle ~= phase.Turtle then
        if phase.Turtle then
            Utils.AddBuff(actor, "AI_TurtleMode", true, EMB_TURTLE.Secs)
        else
            Utils.RemoveBuff(actor, "AI_TurtleMode")
        end
    end

    pcall(function()
        actor.MeleeAttackPlayRate = phase.Rate
        actor.MeleeHitApex        = phase.Apex
        actor.PowerMeleeHitApex   = phase.PowerApex
    end)
    AVU.SetMoveSpeed(actor, phase.Speed, phase.Speed)   -- preserves the VariantTag

    pcall(function() actor.MeleeAttack_OnCooldown = false end)
    LogDebug("Embolon - " .. phase.Name, SETTINGS.DEBUG_NPC_ACTIONS)
end


-- [AUTHORITY] MeleeAttackPlayRate alone only buys dead air (AnNotes) - measure the lunge once and
-- fire AVU.ReleaseSoldierBT ourselves. nil = not measured yet, don't release early.
local function embReleaseTicks(phase)
    return AVU.MeleeReleaseTicks(ENUMS.Anims.ROOK_LUNGE, phase.Rate, {
        Fallback = EMB_RELEASE.LungeFallback,
        Pad = EMB_RELEASE.PadTicks,
    })
end


-- [AUTHORITY] Push the move goal onto the target. Re-paths only if it moved or the order is stale -
-- re-issuing MoveToLocation every pass restarts path following and makes the body jitter.
local function embAdvance(actor, st, tl, now)
    local stale = (st.goalAt == nil) or (now - st.goalAt >= EMB_REPATH.Ticks)
    if not stale and st.goal and Utils.DistSq(st.goal, tl) < EMB_REPATH.Sq then return end
    st.goal, st.goalAt = { X = tl.X, Y = tl.Y, Z = tl.Z }, now

    pcall(function()
        local controller = actor:GetController()
        if IsValid(controller) then
            controller:MoveToLocation(tl, 40, true, true, true, true, nil, true)
        end
    end)
end


-- [AUTHORITY] The tree decides both when to swing and how close to stand from a BLACKBOARD COPY of
-- RangeToMeleeAttack, taken once when the controller possesses the body - which is before the
-- pipeline re-stats it. Leaving that copy vanilla parks the Embolon a hundred uu outside its own
-- sweep, bashing at nothing. Mirror whatever BasicStats landed on, and again late in case the
-- controller had no board yet.
local function embMirrorMeleeRange(actor)
    local range
    pcall(function() range = actor.NPCData[ENUMS.NpcData.MeleeAttackRange] end)
    if range and range > 0 then AVU.SetBlackboardFloat(actor, "RangeToMeleeAttack", range) end
end


-- [AUTHORITY] Let go of the bash hold. Never optional: a body that leaves combat or dies while held
-- would stay parked, and the stash outlives the phase machine.
local function embReleaseHold(actor, st)
    if not st or not st.held then return end
    st.held = false
    AVU.SetBtStunned(actor, false)
end


-- [AUTHORITY] Space the turtled bashes out. That branch answers to no cooldown at all - the tree
-- has no tag on it and BTT_DoMeleeAttack never reads MeleeAttack_OnCooldown - so `Cd` is enforced
-- from outside, by parking the body with the tree's own Stunned hold until the interval is up.
--   * Armed on the first tick after the swing. The bash re-swings every ~0.5s, so any later start
--     is overtaken by the next swing resetting the clock.
--   * The swing in progress still lands: the damage step's stun check reads the pawn's Stunned,
--     and this hold only writes the blackboard's.
--   * Written on transition only; a cadenced write would restart the hold forever.
local function embPaceBash(actor, st, phase, last, now)
    local hold = phase.Turtle and last ~= nil and (now - last) < phase.Cd
    if hold == (st.held == true) then return end
    -- A real stun writes the same bool - let its own removal do the clearing.
    if not hold and AVU.HasGameplayTag(actor, "Modifier.Stunned") then return end
    st.held = hold
    AVU.SetBtStunned(actor, hold)
end


-- [AUTHORITY] Shield-bash knockback, flat along attacker -> victim. Turtled phases only (Shove).
local function embShieldShove(attacker, victim)
    if not Utils.IsAuthority() then return end
    if Utils.IsActorInvalid(attacker) or Utils.IsActorInvalid(victim) then return end

    local aKey = Utils.ActorKey(attacker)
    if not aKey then return end
    local swung = lastEmbSwingTick[aKey]
    if not swung or STATE.FAST_TICK - swung > EMB_SWING_WINDOW then return end   -- a DoT tick, not a swing

    local st = embState[aKey]
    if not st or not st.phase or not st.phase.Shove then return end

    local key = Utils.ActorKey(victim)
    if not key then return end
    if not AVU.CooldownReady(lastEmbKnockTick, key, EMB_KNOCKBACK.CdTicks) then return end

    local al
    pcall(function() al = attacker:K2_GetActorLocation() end)
    if not al then return end

    AVU.KnockbackFrom(victim, al, EMB_KNOCKBACK.Distance, EMB_KNOCKBACK.Up, false)
    LogDebug("Embolon - shield shove", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- [RENDERER] Sink the face back into shadow. The body is one MERGED modular mesh, so the head is a
-- material SLOT on it and def.Tint's gold sprays it along with the armour - this runs after and
-- takes that slot back. Matched by material name because the merge decides the slot ORDER; a slot
-- def.Tint already touched holds a MID, so the name lives on its Parent.
local function embDarkenHead(actor)
    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return end

    local hit = 0
    pcall(function()
        for i = 0, mesh:GetNumMaterials() - 1 do
            local cur = mesh:GetMaterial(i)
            if IsValid(cur) then
                local name = cur:GetFName():ToString()
                if not string.find(name, "Head", 1, true) then
                    local parent = cur.Parent
                    if IsValid(parent) then name = parent:GetFName():ToString() end
                end
                if string.find(name, "Head", 1, true) then
                    AVU.TintSlot(mesh, i, { Color = EMB_HEAD_TINT })
                    hit = hit + 1
                end
            end
        end
    end)
    LogDebug("Embolon - head darkened (" .. hit .. " slot)", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- [RENDERER] Full dress: shield, Lodespear, banner, gold-lens helmet over a blacked-out face.
function H.EmbVisuals(actor)
    embModifyShield(actor)
    embReplaceWeapon(actor)
    embAddShieldBanner(actor)
    AVU.SetHelmet(actor, { Color = FVector(8, 4, 0.3), LensMaterial = ENUMS.Components.M_GLASS_LENS_GOLD })
    embDarkenHead(actor)
end


-- [AUTHORITY] Dress the server's shield geometry too (dedicated has no Visuals); no crouch. Then
-- reconcile the two halves of its reach - the sweep it was re-statted with, and the copy the tree
-- decides on.
function H.EmbReady(actor)
    embModifyShield(actor)
    AVU.SetCanCrouch(actor, false)
    pcall(function() actor.MeleeRangeTraceExtra = EMB_TRACE_EXTRA end)
    embMirrorMeleeRange(actor)
    Utils.QueueWork(function()
        if Utils.IsActorValid(actor) then embMirrorMeleeRange(actor) end
    end, 1500)
end


-- Fires per swing, hit or miss, before the hit test. The stamp it leaves is the clock everything
-- downstream runs on - the shove's swing/burn-tick test and the bash pacing both read it. Keyed by
-- ActorKey: this hook hands back a fresh wrapper.
function H.EmbSwing(actor)
    if not Utils.IsAuthority() then return end
    if Utils.IsActorInvalid(actor) then return end
    pcall(function() actor.MeleeAttack_OnCooldown = true end)
    local key = Utils.ActorKey(actor)
    if key then lastEmbSwingTick[key] = STATE.FAST_TICK end
end


function H.EmbTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    local key = AVU.CachedFullName(actor)   -- stable wrapper (OnTick): memo hits, skip GetFullName
    if not key then return end
    if actor.IsDead then
        embReleaseHold(actor, embState[key])
        lastEmbSwingTick[key], embState[key] = nil, nil
        return
    end
    local now = STATE.FAST_TICK

    local st = embState[key]
    if not st then
        st = { t0 = now, phase = nil }   -- t0 per-actor, so a shield line doesn't swap in lockstep
        embState[key] = st
    end

    -- Out of combat: park in GUARD and stop processing the cycle.
    if actor.CombatState ~= true then
        embReleaseHold(actor, st)
        if st.phase ~= EMB_PHASES[1] then embEnterPhase(actor, st, EMB_PHASES[1]) end
        st.parked = true
        return
    end
    if st.parked then st.parked, st.t0 = nil, now end   -- first tick of a fight: reopen on GUARD

    local phase = embPhaseAt(now - st.t0)
    if phase ~= st.phase then embEnterPhase(actor, st, phase) end

    -- KEEP IT WILLING TO FIGHT. Entering combat slams FailedHits to 99 and every swing bumps
    -- MeleeCounter; each sends the tree to cover from above the melee branch, and neither ever comes
    -- back down on a body with no gun to end a burst with. This is what made it read as retreating.
    if totalTicks % EMB_BRAVERY_TICKS == 0 then
        AVU.SetBlackboardInt(actor, "FailedHits", 0)
        AVU.SetBlackboardInt(actor, "MeleeCounter", 0)
    end

    local last = lastEmbSwingTick[key]

    -- The mobile branch self-applies a 15s tag cooldown at the end of every swing, so the clear has
    -- to run on a cadence rather than once per swing: the selector re-evaluates the moment the
    -- montage ends, and a tag still standing at that instant costs the rest of the phase.
    if not phase.Turtle and totalTicks % EMB_TAG_CLEAR_TICKS == 0 then
        AVU.SetBtCooldownTag(actor, EMB_BT_MELEE_TAG, 0)
    end
    if last == nil or now - last >= phase.Cd then
        pcall(function()
            if actor.MeleeAttack_OnCooldown then actor.MeleeAttack_OnCooldown = false end
        end)
    end

    embPaceBash(actor, st, phase, last, now)

    -- AGGRO: hand the BT its release once the sped-up montage has really finished.
    if phase.Release and last and st.releasedFor ~= last then
        local wait = embReleaseTicks(phase)
        if wait and now - last >= wait then
            st.releasedFor = last
            AVU.ReleaseSoldierBT(actor)
        end
    end

    -- Stance corrective: embEnterPhase sets the turtle tag on a phase change; this only fixes it
    -- going wrong in between (CheckForTurtleMode re-applies it on hits taken under 60% HP).
    if (now - st.t0) % EMB_TURTLE.CheckTicks == 0 then
        local turtled = Utils.ActorHasBuff(actor, "AI_TurtleMode")
        if phase.Turtle and not turtled then
            Utils.AddBuff(actor, "AI_TurtleMode", true, EMB_TURTLE.Secs)
        elseif not phase.Turtle and turtled then
            Utils.RemoveBuff(actor, "AI_TurtleMode")
        end
    end

    if totalTicks % 5 ~= 0 then return end   -- the scripted advance runs at ~2Hz
    if not phase.Advance then return end

    local target = AVU.GetCurrentTarget(actor)
    if Utils.IsActorInvalid(target) then return end
    if not Utils.IsActorReadyToAttack(actor) then return end

    local al = actor:K2_GetActorLocation()
    local tl = target:K2_GetActorLocation()
    if not al or not tl then return end
    if Utils.DistSq(al, tl) <= EMB_REACH_SQ then return end   -- already in reach: let it swing

    embAdvance(actor, st, tl, now)
end


-- A landed hit shoves the victim - real swings only (embShieldShove sorts a burn tick from a bash).
function H.EmbShove(attacker, victim)
    embShieldShove(attacker, victim)
end

return H
