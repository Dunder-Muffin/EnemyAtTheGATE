-- =======================================================================
-- Exor Armored helpers - the machinery behind AnteNPCs/ExorArmored.lua: the Displacer/Dislocator
-- swap-bomb, and the Repeller/Dislocator mid-burst blink.
--
-- MUST-KNOWS
--   * byMode reads STATE.HardModeNoMercy at USE time - never cache what it returns (the flag
--     settles at world load, after this file is required, and /auhard flips it live).
--   * All four variants suppress their own grenade/teleport/melee every OnTick beat - the base
--     class never learned Ability slot 2, so nothing here touches it.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")

local LogDebug = Utils.LogDebug

local H = {}

-- ABILITY MAP - NPC_Monster_Exor_Armored: see AnteNPCs/ExorArmored.lua header for the full map.
local ABILITY_GRENADE  = 1
local ABILITY_TELEPORT = 3

local function byMode(t) return STATE.HardModeNoMercy and t.Hard or t.Normal end


-- =======================================================================
-- SWAP BOMB - drop a grenade, then teleswap with the target (player OR NPC). Displacer's only
-- teleport; Dislocator borrows it on reload.
-- =======================================================================

local DISPLACE_RANGE   = { MinSq = 500 * 500, MaxSq = 3500 * 3500 }   -- distance band to swap
local DISPLACE_CD_TICKS = { Normal = 100, Hard = 90 }                 -- cooldown in ticks (10/s)
local DISPLACE_WINDUP_MS = 1000   -- after the grenade drops, swap after this delay
local SWAP_EYE_Z = 60             -- chest height for the sight trace, both ends
local SWAP_PLAYER_DEBOUNCE = 50   -- ticks a PLAYER is off-limits after any scripted teleport (5s)

-- Blast is a FALLOFF: inner full damage, decaying to min damage at Radius.
local DISPLACE_GRENADE = {
    Damage = 150,   -- 70
    Fuse   = { Normal = 3.5, Hard = 3.2 },   -- 2
    Inner  = 450,   -- 350
    Radius = 950,   -- 750
    Scale  = 2.5,   -- visuals
}

local lastSwapBombTick = {}   -- actor key -> FAST_TICK of the last swap-bomb

-- The two rules a swap has to clear, checked at the DECISION - never mid-windup, or the Exor
-- plants a bomb and then visibly does nothing with it. The victim is always the Exor's CURRENT
-- combat target; nothing here picks one.
--   * LINE OF SIGHT. Without it the Exor yanks people through walls and floors, from somewhere
--     they never saw it. Fail-open like every other sight gate: a trace error lets the swap go.
--   * A PLAYER IS NOT JUGGLED. STATE.PlayerTeleportTicks is one ledger across every scripted yank
--     in the mod, so a pack of these can't pass one player between them every few seconds. NPC and
--     pet victims are ungated - nobody minds those being thrown around.
local function swapAllowed(actor, target)
    if Utils.IsPlayer(target) then
        local tkey = Utils.ActorKey(target)
        if tkey and not AVU.CooldownReady(STATE.PlayerTeleportTicks, tkey, SWAP_PLAYER_DEBOUNCE,
                { Peek = true }) then
            return false
        end
    end

    local a, t = actor:K2_GetActorLocation(), target:K2_GetActorLocation()
    if not a or not t then return false end
    return not AVU.IsPathBlocked(actor,
        FVector(a.X, a.Y, a.Z + SWAP_EYE_Z), FVector(t.X, t.Y, t.Z + SWAP_EYE_Z),
        { actor, target }, ENUMS.Trace.VISIBILITY)
end

-- AVU.TeleportCharacter picks the right half: a player victim hops off-hook, an NPC (and the Exor
-- itself) is a plain set. Deployables and other non-characters are refused by AVU.IsSwappable -
-- they have their own position channels and would fight a plain move.
local function exorSwapBomb(actor, target, opts)
    if Utils.IsActorInvalid(actor) or not AVU.IsSwappable(target) then return end
    opts = opts or {}

    local windup = opts.Windup or DISPLACE_WINDUP_MS

    -- CLAIM the victim now, a whole windup before Utils.TeleportPlayer stamps it for real: two
    -- Exors deciding inside that second would otherwise both pass swapAllowed and both fire.
    if Utils.IsPlayer(target) then
        local tkey = Utils.ActorKey(target)
        if tkey then STATE.PlayerTeleportTicks[tkey] = STATE.FAST_TICK end
    end

    -- Snapshot the drop spot as plain NUMBERS: a held FVector is re-read live, so the destination
    -- would otherwise follow the Exor's later blinks instead of staying on the bomb.
    local a0 = actor:K2_GetActorLocation()
    if not a0 then return end
    local ax, ay, az = a0.X, a0.Y, a0.Z

    -- An actor's origin is its capsule CENTRE, so a swap between two differently-sized characters
    -- has to go via the FLOOR or the shorter one ends up buried / the taller one hovering.
    local exorHalf = AVU.CapsuleHalfHeight(actor)
    local groundZ  = az - exorHalf   -- the grenade lands at the Exor's feet

    AVU.DropGrenades(actor, 1, 0, {
        Fuzz = 0,
        Damage = opts.Damage or DISPLACE_GRENADE.Damage,
        Fuse   = opts.Fuse   or byMode(DISPLACE_GRENADE.Fuse),
        Radius = opts.Radius or DISPLACE_GRENADE.Radius,
        InnerRadius = opts.InnerRadius or DISPLACE_GRENADE.Inner,
        Scale  = opts.Scale  or DISPLACE_GRENADE.Scale,
        Class  = ENUMS.ProjectileClasses.GrenadeExor,
        NoBounce = true,   -- plant it: a bomb that rolls away made the swap survivable
    })

    -- Client-FX channel, not CreateEffect (ParticleEffect doesn't replicate). 3s covers
    -- swap -> detonation.
    AVU.SendClientFX(FVector(ax, ay, az), "EXOR_CHARGE", 3)
    LogDebug("Exor Displacer swap", SETTINGS.DEBUG_NPC_ACTIONS)

    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        if not AVU.IsSwappable(target) then return end

        -- Victim goes to the DROP POINT (where the blast lands), not the grenade actor -
        -- NoBounce keeps the two in the same place anyway.
        local b = target:K2_GetActorLocation()
        if not b then return end

        -- Both ends via the FLOOR, so a height mismatch doesn't bury one and float the other.
        local targetHalf  = AVU.CapsuleHalfHeight(target)
        local victimDest  = FVector(ax, ay, groundZ + targetHalf + ENUMS.Tuning.PLAYER_ZLIFT)
        local exorDest    = FVector(b.X, b.Y, (b.Z - targetHalf) + exorHalf)

        local face = Utils.RotatorToTarget(FVector(ax, ay, 0), FVector(b.X, b.Y, 0))
        AVU.TeleportCharacter(target, victimDest, face)
        -- Onto the victim's spot: player space, so off the drain like the victim's own leg.
        AVU.MoveNpcOffHook(actor, exorDest, Utils.RotatorToTarget(exorDest, victimDest),
            { Label = "exor displacer swap" })

        -- Teleport trail for BOTH legs: native FX draws a blink at each end + a beam between.
        local from = FVector(ax, ay, az)
        pcall(function() actor:Broadcast_TeleportFX(from, b) end)
        pcall(function() actor:Broadcast_TeleportFX(b, from) end)
        LogDebug("Exor swap-bomb - swapped with " .. tostring(Utils.GetActorName(target)),
            SETTINGS.DEBUG_NPC_ACTIONS)
    end, windup)
end


-- =======================================================================
-- BLINK + BURST TRACKING - shared by the Repeller and the Dislocator (both fire one long burst
-- and reposition mid-way). One band, two jobs: the ENGAGE window and the DESTINATION ring - same
-- numbers on purpose. The hard band is tighter at both ends: it closes to knife range and stays.
-- =======================================================================

local EXOR_BLINK_ZLIFT = 90

local REPEL_RANGE = {
    Normal = { Min = 800, Max = 2000 },
    Hard   = { Min = 600, Max = 1700 },
}
for _, b in pairs(REPEL_RANGE) do b.MinSq, b.MaxSq = b.Min * b.Min, b.Max * b.Max end

local REPEL_MOVE_SQ = 1000 * 1000   -- prefer a location not close to the blink point

-- Blink the shooter to a fresh spot on a ring around its target: in LOS, on solid ground, and not
-- basically where it already stood. Falls through to "stay put and keep firing" if no spot passes.
-- Navmesh projection, not a downward ground-probe - a probe accepts roofs/rocks/ledges it can't
-- path off (that bug is why AVU.FindLosPoint exists; see its header).
local function repeller_Blink(actor, target)
    if Utils.IsActorInvalid(actor) or Utils.IsActorInvalid(target) then return end

    local a = actor:K2_GetActorLocation()
    local t = target:K2_GetActorLocation()

    local band = byMode(REPEL_RANGE)
    local ground = AVU.FindLosPoint(target, {
        Actor = actor,
        MinDist = band.Min,
        MaxDist = band.Max,
        Tries = 10,
    })
    if not ground then return end   -- nowhere navigable with LoS: stay put, keep barraging

    -- FindLosPoint returns a FLOOR navmesh point - lift to capsule centre or the Exor buries to
    -- the waist.
    local dest = FVector(ground.X, ground.Y, ground.Z + AVU.CapsuleHalfHeight(actor, EXOR_BLINK_ZLIFT))
    if Utils.DistSq(a, dest) < REPEL_MOVE_SQ then return end   -- don't burn the blink on a step sideways

    pcall(function()
        actor:K2_SetActorLocationAndRotation(dest, Utils.RotatorToTarget(dest, t), false, {}, true)
    end)
    pcall(function() actor:Broadcast_TeleportFX(a, dest) end)
    LogDebug("Exor Repeller - blink", SETTINGS.DEBUG_NPC_ACTIONS)
end

-- Watch the native CurrentBurst counter and blink after shot `at1`, then again after `at2`.
-- `tracker` is the caller's own key -> { prev, blinks } table, so the two variants can't stomp
-- each other's counts. CurrentBurst counts UP and resets to 0 on a fresh burst - that reset is
-- how we know to re-arm the blinks.
local function burstBlink(actor, target, tracker, at1, at2)
    local key = Utils.ActorKey(actor)
    if not key then return end

    local st = tracker[key]
    if not st then st = { prev = 0, blinks = 0 }; tracker[key] = st end

    local burst = 0
    pcall(function() burst = actor.CurrentBurst or 0 end)
    if burst < st.prev then st.blinks = 0 end   -- CurrentBurst dropped -> a new burst began
    st.prev = burst

    if st.blinks == 0 and at1 and at1 > 0 and burst >= at1 then
        st.blinks = 1
        repeller_Blink(actor, target)
    elseif st.blinks == 1 and at2 and at2 > 0 and burst >= at2 then
        st.blinks = 2
        repeller_Blink(actor, target)
    end
end


-- =======================================================================
-- Entry points - bare references from ExorArmored.lua
-- =======================================================================

-- EXOR DISPLACER - suppress the native grenade/teleport, then swap-bomb once in range.
function H.DisplacerTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    if totalTicks % 10 ~= 0 then return end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end   -- out of combat: let the AI be

    pcall(function() actor:SetAbilityOnCooldown(ABILITY_GRENADE, true, 4) end)
    pcall(function() actor:SetAbilityOnCooldown(ABILITY_TELEPORT, true, 4) end)
    AVU.SuppressMelee(actor)

    if not Utils.IsActorReadyToAttack(actor) then return end

    local dsq = Utils.DistSq(actor:K2_GetActorLocation(), target:K2_GetActorLocation())
    if dsq < DISPLACE_RANGE.MinSq or dsq > DISPLACE_RANGE.MaxSq then return end
    if not AVU.IsSwappable(target) then return end

    -- Peek, then stamp by hand below: a swap the sight gate refuses must not eat the cooldown, or
    -- an Exor stuck behind cover spends its whole fight on spent charges.
    local key = Utils.ActorKey(actor)
    if not AVU.CooldownReady(lastSwapBombTick, key, byMode(DISPLACE_CD_TICKS), { Peek = true }) then
        return
    end
    if not swapAllowed(actor, target) then return end

    lastSwapBombTick[key] = STATE.FAST_TICK
    exorSwapBomb(actor, target)
end


-- EXOR REPELLER - suppress grenade/teleport/melee, then blink through the burst.
local repelBlinkState = {}   -- actor key -> { prev, blinks } (see burstBlink)
local REPEL_BLINK = { Fire1 = 6, Fire2 = 12 }   -- blink after this many shots of the burst

function H.RepellerTick(actor, totalTicks)
    if totalTicks % 5 ~= 0 then return end
    if Utils.IsActorInvalid(actor) then return "REMOVE" end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end

    if totalTicks % 10 == 0 then
        pcall(function() actor:SetAbilityOnCooldown(ABILITY_GRENADE, true, 600) end)
        pcall(function() actor:SetAbilityOnCooldown(ABILITY_TELEPORT, true, 600) end)
        AVU.SuppressMelee(actor)
    end

    -- ANY target: the Repeller only repositions ITSELF, so this path doesn't care what it is.
    if not Utils.IsActorReadyToAttack(actor) then return end

    local dsq = Utils.DistSq(actor:K2_GetActorLocation(), target:K2_GetActorLocation())
    local band = byMode(REPEL_RANGE)
    if dsq < band.MinSq or dsq > band.MaxSq then return end

    burstBlink(actor, target, repelBlinkState, REPEL_BLINK.Fire1, REPEL_BLINK.Fire2)
end


-- EXOR DISLOCATOR - Repeller's blink-through-burst, plus the Displacer's swap-bomb on reload.
-- burst == clip here, so the reload (and swap-bomb) lands at the end of every clip.
local dislocBlinkState = {}   -- own table: the two variants can't stomp each other's counts
local DISLOC_BLINK = { Fire1 = 5, Fire2 = 11 }   -- thirds of the 16-shot clip; move both with it
local DISLOC_GRENADE = {
    Damage = 130,
    Fuse   = { Normal = 3.5, Hard = 3.2 },
    Radius = 800,
    WindupMs = 800,
}
local DISLOC_RELOAD_MS = 1000   -- how far into the reload the grenade+swap fires

-- WHICH RELOADS CARRY A SWAP. Both modes open on one - the first reload of a fight is always
-- dangerous - then normal takes every other reload and hard takes two of every three
-- (swap, nothing, swap, swap, nothing, ...). The counter wraps at 6, which both periods divide,
-- so each pattern repeats exactly rather than jumping at the wrap.
local DISLOC_SWAP_PERIOD = { Normal = 2, Hard = 3 }   -- skip the reload when count % period == 1
local DISLOC_SWAP_WRAP   = 6

local dislocReloadCount = {}   -- actor key -> reload counter, 0-5

function H.DislocatorTick(actor, totalTicks)
    if totalTicks % 5 ~= 0 then return end
    if Utils.IsActorInvalid(actor) then return "REMOVE" end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end

    if totalTicks % 10 == 0 then
        pcall(function() actor:SetAbilityOnCooldown(ABILITY_GRENADE, true, 4) end)
        pcall(function() actor:SetAbilityOnCooldown(ABILITY_TELEPORT, true, 4) end)
        AVU.SuppressMelee(actor)
    end

    -- Poll the burst counter often (shots are ~0.25s = ~2.5 fast-ticks apart). ANY target: the
    -- blink only moves US.
    if not Utils.IsActorReadyToAttack(actor) then return end

    local dsq = Utils.DistSq(actor:K2_GetActorLocation(), target:K2_GetActorLocation())
    local band = byMode(REPEL_RANGE)
    if dsq < band.MinSq or dsq > band.MaxSq then return end

    burstBlink(actor, target, dislocBlinkState, DISLOC_BLINK.Fire1, DISLOC_BLINK.Fire2)
end

-- 1s into the reload: drop a live grenade at our feet, then trade places with the target so they
-- land on it (exorSwapBomb does the drop + windup + swap). Driven by the eager
-- Broadcast_ReloadWeapon hook (NPC_Base multicast, fires on authority).
function H.DislocatorReload(actor)
    if Utils.IsActorInvalid(actor) then return end

    -- Cadence first: a reload that isn't a swap reload should not queue work at all.
    local key = Utils.ActorKey(actor)
    if key then
        local n = dislocReloadCount[key] or 0
        dislocReloadCount[key] = (n + 1) % DISLOC_SWAP_WRAP
        if n % byMode(DISLOC_SWAP_PERIOD) == 1 then
            LogDebug("Exor Dislocator - reload swap skipped (cadence)", SETTINGS.DEBUG_NPC_ACTIONS)
            return
        end
    end

    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end

        local target = actor:GetCurrentCombatTarget()
        if not AVU.IsSwappable(target) then return end   -- player or NPC; not a deployable

        local dsq = Utils.DistSq(actor:K2_GetActorLocation(), target:K2_GetActorLocation())
        if dsq < DISPLACE_RANGE.MinSq or dsq > DISPLACE_RANGE.MaxSq then return end
        if not swapAllowed(actor, target) then return end

        LogDebug("Exor Dislocator - reload swap-bomb", SETTINGS.DEBUG_NPC_ACTIONS)
        exorSwapBomb(actor, target, {
            Damage = DISLOC_GRENADE.Damage,
            Fuse   = byMode(DISLOC_GRENADE.Fuse),
            Radius = DISLOC_GRENADE.Radius,
            Windup = DISLOC_GRENADE.WindupMs,
        })
    end, DISLOC_RELOAD_MS)
end


-- WINTER EXOR - no grenade, no blink, no melee: the frost cone is the whole kit.
function H.WinterTick(actor, totalTicks)
    if totalTicks % 10 ~= 0 then return end
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    if Utils.IsActorInvalid(actor:GetCurrentCombatTarget()) then return end

    pcall(function() actor:SetAbilityOnCooldown(ABILITY_GRENADE, true, 4) end)
    pcall(function() actor:SetAbilityOnCooldown(ABILITY_TELEPORT, true, 4) end)
    AVU.SuppressMelee(actor)
end

return H
