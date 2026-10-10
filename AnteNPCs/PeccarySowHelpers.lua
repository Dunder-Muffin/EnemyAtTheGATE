-- =======================================================================
-- Hive Sow bee-cloud kit - shared by the WILD Hive Sow (AnteNPCs/PeccarySow), the TAMED Hive Sow
-- pet (ModulePets/TamedPeccary) and the two witches that borrow the cloud. AUTHORITY.
--
-- WHAT IT IS
--   * The real attack is a spore CLOUD dropped where the target WAS at fire time, re-stinging
--     whoever LINGERS in it with Debuff_BeeSwarm until it expires. The thrown projectile is just
--     swapped to a tidy row in each def.
--   * OWNER-SAFE with no pet branch: hostility is judged from the SOW's own faction, so a tamed
--     follower stings only the owner's enemies.
--
-- MUST-KNOWS
--   * NO CLOUD ACTOR. The cloud is a location anchor plus the ClientFX visuals (which fire on the
--     host too), so there is no replicated actor and no native systems per cloud.
--   * A dead sow's cloud STOPS. Each sting applies a buff with its own timer linked to the caster,
--     so a loop that outlives the sow floods the timer manager with buffs on a freed instigator -
--     the level-exit access violation.
--   * The Debuff_BeeSwarm row is bNoExpiration + BlockedByExisting: it never times out on its own
--     (so OUR removal is what ends it) and a second apply onto a victim that still has it is
--     refused. So a re-sting's whole job is to push the removal deadline out - hence the per-victim
--     dedupe and the has-it-already skip. The buff object does self-remove once the LINKED ACTOR
--     dies or gets 2000uu away, which is the backstop when a cloud outlives its sow.
--   * A buff instance copies DamageToNPC_Modifier off the SHARED CDO when it is CREATED, so each sting
--     writes its owner's value in the same step as the apply (BEE DAMAGE TUNING). HS.TuneBeeDamage
--     from Stats just keeps the class resident so that write is cheap.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local ASSETS = require("AnteCore.AssetManager")
local Utils = require("AnteUtils.Utils")
local ENUMS = require("AnteData.Enums")
local Items = require("AnteData.Items")
local AVU = require("AnteUtils.AVUtils")
local AVM = require("AnteUtils.AVMath")
local AFUtils = require("AFUtils.AFUtils")
local LogDebug = Utils.LogDebug
local Log = Utils.Log

local HS = {}

-- Forced-throw knobs (HS.ForceThrow). A FLOOR on the throw rate, not an extra attack: the stamp is
-- written by every throw the sow makes, so one that is free to lob at range never trips it.
local HIVE_THROW = {
    FloorTicks = 60,   -- 6s without a cloud and we throw for it
    HopMs      = 50,   -- off the tick drain; a 0ms delay is not a thread hop
    GraceTicks = 30,   -- 3s to settle on a target before a fresh body may be thrown for
}

local hiveLastThrow = {}   -- fullname -> FAST_TICK of the last throw, native or forced

-- Standoff knobs (HS.KeepRange). Both sit above the tree's own 450uu throw floor, so a planted sow
-- still has its native throw branch open and only leans on HS.ForceThrow once something walks it
-- down. The gap between them is hysteresis - one threshold stutters in and out of the hold.
-- Keep the margin: a sow closing at sprint speed covers ~300uu between passes, so it actually
-- plants up to that far inside HOLD_IN.
local HIVE_STANDOFF = {
    HoldIn      = 900,    -- plant once the target is this close...
    HoldOut     = 1100,   -- ...and walk again once it is this far
    FaceDegrees = 30,     -- re-aim only past this much error
}

local hiveHeld = {}   -- fullname -> true while planted

-- Cloud knobs. The cloud is a PURE VISUAL; the "damage zone" is the sting loop, split out so the
-- visual telegraphs slightly sooner and LINGERS past the last sting.
local HIVE_CLOUD_SECONDS  = 16      -- cloud VISUAL lifetime (also the pushed client FX lifetime)
local HIVE_STING_SECONDS  = 14      -- the DAMAGE window
local HIVE_BEE_SECONDS    = 2       -- BeeSwarm duration per sting
local HIVE_RADIUS         = 300     -- cloud sting radius
local HIVE_BOMB_DELAY     = 200     -- ms after the throw before the cloud spawns
local HIVE_APPLY_DELAY    = 2000    -- ms escape window before the first sting (from cloud spawn)
local HIVE_SPORE_PULSE_MS = 6000    -- re-send cadence for the FINITE spore-shake FX. Each renderer
                                    -- FX spawn costs 5-45ms, so 3 pulses with brief lulls beats a
                                    -- seamless 4s cadence.
local HIVE_PULSE_NEAR     = 4000    -- only pulse while a player is within ~40m
local HIVE_STING_INTERVAL = 2000    -- ms between stings while the window is open
local HIVE_EXPIRE_MS      = HIVE_STING_INTERVAL + 300   -- cap removal after the last sting
local HIVE_BEE_NPC_DMG_MULT = 0.27   -- BeeSwarm NPC damage modifier (stock 0.2) Reduced from 0.3s

local HIVE_BEE_CLASS    = "/Game/Blueprints/BuffsDebuffs/BuffObject_BeeSwarm.BuffObject_BeeSwarm_C"
local HIVE_BEE_CDO_PATH = "/Game/Blueprints/BuffsDebuffs/BuffObject_BeeSwarm.Default__BuffObject_BeeSwarm_C"

local hiveBeeToken   = {}    -- victim GetFullName -> latest sting token
local hiveMeleeStung = {}    -- victim GetFullName -> true while a melee bee window is active
local hiveAreaStung  = {}    -- victim GetFullName -> FAST_TICK of its last CLOUD sting
local hiveBeeTuned   = false

local HIVE_AREA_DEDUPE_TICKS = math.floor(HIVE_STING_INTERVAL / 100) - 2   -- ticks are 10/sec
local HIVE_AREA_STALE_TICKS  = HIVE_AREA_DEDUPE_TICKS * 10   -- when a victim is forgotten

local function hiveName(a) return Utils.GetActorName(a) or "Bee Sow" end

-- [AUTHORITY] Is there a WALL between this sow and what it is about to bomb? Both throw paths ask,
-- because neither the tree's own branch nor TryRangedAttackCheck tests it, and a cloud anchors on
-- the target's position - so a blocked target means a cloud dropped through the wall.
--   * A geometry trace, deliberately NOT the AI's sight: facing, vision cone and the CanSeeTarget
--     blackboard bool all say "no" for something the sow has simply not turned towards yet, and a
--     sow that only bombs what it is already looking at stops using its attack. Cover is the only
--     thing being tested here.
--   * IsPathBlocked is fail-open, so a trace error keeps the sow throwing.
local function hiveCanSee(actor, target)
    local from, to
    pcall(function()
        from = actor:K2_GetActorLocation()
        to   = target:K2_GetActorLocation()
    end)
    if not (from and to) then return true end
    return not AVU.IsPathBlocked(actor, from, to, { actor, target })
end


-- =======================================================================
-- BEE DAMAGE TUNING (the shared BuffObject CDO)
-- =======================================================================
-- DamageToNPC_Modifier sits on the BuffObject CDO, which every owner shares, and a new buff instance
-- copies it when it is created. So each sting writes its OWNER's value in the same game-thread step
-- as the apply (hiveStingTarget). Written any earlier, another owner's sting can land in between -
-- which is how a pet's per-level value used to stay on every wild sow and witch for the session.

-- The ONE writer. `hiveBeeMult` is what we last put on the CDO, and a repeat of that value costs
-- nothing - each resolve of the CDO is a full object-array walk.
--   * THE CLASS CAN UNLOAD BETWEEN FIGHTS (nothing else holds a buff object; a dedicated server
--     drops it within minutes), and a reload hands back a fresh CDO at the stock 0.2. So the
--     remembered value is only trusted while the class is PINNED, and a sting that finds the CDO
--     gone loads it on the spot: its write has to land BEFORE the apply behind it creates the
--     buff instance, and that instance then lives for the whole re-sting window.
--   * `offHook` = the caller is a sting's beforeApply (an ExecuteInGameThread step), the one place
--     a blocking load is allowed - the apply would blocking-load the same class a line later.
local hiveBeeMult = nil

local function hiveWriteBeeMult(mult, offHook)
    if hiveBeeMult == mult and ASSETS.GetIfPinned(HIVE_BEE_CLASS) then return end
    local function apply(cdo)
        if IsNotValid(cdo) then return end
        hiveBeeMult = mult
        pcall(function() cdo.DamageToNPC_Modifier = mult end)
    end
    local cdo = ASSETS.GetIfValid(HIVE_BEE_CDO_PATH)
    if IsNotValid(cdo) and offHook then
        pcall(function() LoadAsset(HIVE_BEE_CLASS) end)
        cdo = ASSETS.GetIfValid(HIVE_BEE_CDO_PATH)
    end
    if IsValid(cdo) then apply(cdo) return end
    ASSETS.LoadAsync({ HIVE_BEE_CLASS }, function() apply(ASSETS.GetIfValid(HIVE_BEE_CDO_PATH)) end)
end

-- Warm AND PIN the class and seed the baseline, so a first sting's write is a resolve rather than
-- a load - minutes later as well as seconds later.
local function hiveTuneDamage()
    ASSETS.WarmPinned({ HIVE_BEE_CLASS })   -- free from the second call on
    if hiveBeeTuned then return end
    hiveWriteBeeMult(HIVE_BEE_NPC_DMG_MULT)
    if hiveBeeMult == nil then return end   -- CDO was cold; the async write lands, latch then
    hiveBeeTuned = true
    Log("HiveSow - BeeSwarm DamageToNPC_Modifier set to " .. HIVE_BEE_NPC_DMG_MULT)
end


-- Public entry - call from a Stats, so the class is resident before the first sting.

function HS.TuneBeeDamage() hiveTuneDamage() end


-- =======================================================================
-- STINGING
-- =======================================================================

-- Give one victim a ~2s swarm. The token is what makes re-stinging extend rather than double up:
-- only the newest removal fires, so the swarm ends HIVE_EXPIRE_MS after the LAST sting.
-- linkedActor must stay valid or the native tick removes the buff instantly.
--   * `mult` is the owner's NPC damage modifier (nil = HIVE_BEE_NPC_DMG_MULT), written just before the
--     apply (see BEE DAMAGE TUNING). NPC victims only: on a player the buff resets the modifier to 1
--     itself, and skipping the write keeps a sow stinging a player from flipping the CDO back and
--     forth against a pet stinging NPCs.
local function hiveStingTarget(victim, linkedActor, mult, isNpc)
    if Utils.IsActorInvalid(victim) then return end

    -- RE-STINGING A VICTIM THAT STILL HAS THE SWARM ONLY MOVES ITS DEADLINE - the row is
    -- BlockedByExisting, so the apply is refused anyway. Skipping it matters because an apply hops
    -- off-hook and resolves two paths (component + linked actor), and a cloud re-stings everything
    -- inside it every interval for the whole window. HasBuff resolves nothing.
    if not Utils.ActorHasBuff(victim, ENUMS.Debuffs.BeeSwarm) then
        local tune = isNpc and function() hiveWriteBeeMult(mult or HIVE_BEE_NPC_DMG_MULT, true) end or nil
        Utils.ApplyBuffLinked(victim, ENUMS.Debuffs.BeeSwarm, HIVE_BEE_SECONDS, linkedActor, 0, tune)
    end

    local ok, key = pcall(function() return victim:GetFullName() end)
    if not ok or not key then return end
    local tok = (hiveBeeToken[key] or 0) + 1
    hiveBeeToken[key] = tok
    Utils.QueueWork(function()
        if hiveBeeToken[key] ~= tok then return end   -- re-stung since -> keep (refreshed)
        hiveBeeToken[key] = nil
        -- Only if still there (it self-removes past 20m): a RemoveBuff is a by-path walk.
        if Utils.IsActorValid(victim) and Utils.ActorHasBuff(victim, ENUMS.Debuffs.BeeSwarm) then
            Utils.RemoveBuff(victim, ENUMS.Debuffs.BeeSwarm)
        end
    end, HIVE_EXPIRE_MS)
end

-- Should `sow` sting `candidate`?
--   * PLAYER target: decided by IsFollower - a pet spares players, a wild sow stings them.
--     GetHostilityTowardsTarget is UNRELIABLE from Lua for player targets (it kept returning
--     not-hostile even for wild sows, so the cloud never stung the player while melee did).
--   * NPC target: the game's own hostility check, which works fine and lets a pet's cloud sting
--     the player's enemies.
local function hiveShouldSting(sow, candidate, isPlayer)
    if Utils.IsActorInvalid(candidate) then return false end
    if Utils.IsActorInvalid(sow) then return not isPlayer end   -- orphaned cloud: spare players

    local sowIsPet = false
    pcall(function() sowIsPet = sow:IsFollower() end)
    if isPlayer then return not sowIsPet end

    -- A pet's cloud spares the other pets: the hostility check below reads one follower as hostile
    -- to another, so they took a 0-damage swarm (and a buff op each) from every cloud.
    if sowIsPet then
        local candIsPet = false
        pcall(function() candIsPet = candidate:IsFollower() end)
        if candIsPet then return false end
    end

    local afl = AFUtils.GetAbioticFunctionLibrary()
    if IsNotValid(afl) then return true end                     -- can't check -> default-sting
    local ok, hostile = pcall(function() return afl:GetHostilityTowardsTarget(sow, candidate, sow) end)
    if not ok then return true end
    return hostile ~= false
end

-- ONE cloud sting per victim per interval, however many clouds they stand in - a stationary fight
-- stacks 5-7 overlapping clouds and BeeSwarm only refreshes, so the rest is pure churn. Melee
-- stings deliberately bypass this (they have their own guard): a bite should always land.
local function hiveAreaCanSting(victim)
    local ok, key = pcall(function() return victim:GetFullName() end)
    if not ok or not key then return true end   -- unreadable -> fail open, sting it

    local now = STATE.FAST_TICK or 0
    local last = hiveAreaStung[key]
    if last and (now - last) < HIVE_AREA_DEDUPE_TICKS then return false end

    -- Bound the table: victims that walked away would otherwise sit in it forever. Pruning on a
    -- sting is enough - it is the only thing that grows it.
    for k, t in pairs(hiveAreaStung) do
        if (now - t) > HIVE_AREA_STALE_TICKS then hiveAreaStung[k] = nil end
    end

    hiveAreaStung[key] = now
    return true
end

-- Sting everything hostile within the cloud radius once. `anchor` is a PLAIN {X,Y,Z} table.
--   * AUDIENCE GATE first - skip the whole scan without a player in earshot; a sting nobody can
--     perceive still costs real time in a sow-heavy fight.
--   * The GameState player array, NOT FindAllOf - that walks the entire UObject array, and this
--     runs per cloud every 2s.
local function hiveStingArea(anchor, attacker, mult)
    if not Utils.IsPlayerNearby(anchor, 6000) then return end

    local cloudLoc = FVector(anchor.X, anchor.Y, anchor.Z)

    local gs = STATE.GameState
    local players = IsValid(gs) and gs.PlayerCharacterInGame or nil
    for i = 1, (players and #players or 0) do
        local p = players[i]
        if Utils.IsActorValid(p) then
            local ok, pl = pcall(function() return p:K2_GetActorLocation() end)
            if ok and pl and Utils.DistSq(cloudLoc, pl) <= HIVE_RADIUS * HIVE_RADIUS
               and hiveShouldSting(attacker, p, true) and hiveAreaCanSting(p) then
                hiveStingTarget(p, attacker, mult, false)
            end
        end
    end

    local ignore = Utils.IsActorValid(attacker) and attacker or nil
    for _, npc in ipairs(AVU.GetNearbyNpcs(cloudLoc, HIVE_RADIUS, { ignoreActor = ignore })) do
        if hiveShouldSting(attacker, npc) and hiveAreaCanSting(npc) then
            hiveStingTarget(npc, attacker, mult, true)
        end
    end

    LogDebug(hiveName(attacker) .. " - cloud sting tick", SETTINGS.DEBUG_NPC_ACTIONS)
end

-- Repeating sting: first after the escape window, then every HIVE_STING_INTERVAL until the window
-- runs out (the deadline IS the cloud's lifetime). Stops the moment the caster is dead or gone -
-- see the header.
local function hiveStingLoop(anchor, attacker, elapsedMs, stingSecs, mult)
    if Utils.IsActorInvalid(attacker) then return end
    local attackerDead = false
    pcall(function() attackerDead = attacker.IsDead end)
    if attackerDead then return end

    hiveStingArea(anchor, attacker, mult)
    local nextElapsed = elapsedMs + HIVE_STING_INTERVAL
    if nextElapsed <= (stingSecs or HIVE_STING_SECONDS) * 1000 then
        Utils.QueueWork(function() hiveStingLoop(anchor, attacker, nextElapsed, stingSecs, mult) end,
            HIVE_STING_INTERVAL)
    end
end


-- =======================================================================
-- THE ATTACKS
-- =======================================================================

-- [AUTHORITY] Drop a bee cloud NOW, anchored at `loc`, credited to `owner` (any NPC - the Sow's
-- tail-throw and the Plague Witch's takeoff both land here).
--   opts.ApplyDelay  ms escape window before the first sting (explicit 0 = sting immediately)
--   opts.Seconds     cloud VISUAL lifetime; the sting window keeps the native 2s fade tail
--   opts.BeeMult     NPC damage modifier for this cloud's stings (nil = HIVE_BEE_NPC_DMG_MULT)

function HS.DropCloud(loc, owner, opts)
    if Utils.IsActorInvalid(owner) or not loc then return end
    local applyDelay = (opts and opts.ApplyDelay) or HIVE_APPLY_DELAY
    local cloudSecs  = (opts and opts.Seconds) or HIVE_CLOUD_SECONDS
    local stingSecs  = cloudSecs - (HIVE_CLOUD_SECONDS - HIVE_STING_SECONDS)
    local mult       = opts and opts.BeeMult
    local anchor = { X = loc.X, Y = loc.Y, Z = loc.Z }

    AVU.SendClientFX(anchor, "HIVE_BEES", cloudSecs)
    Utils.QueueWork(function() hiveStingLoop(anchor, owner, applyDelay, stingSecs, mult) end, applyDelay)

    -- SPORE PULSES: the shake burst is FINITE (and bAutoDestroy frees its component, so it can't
    -- be kept alive), so one send never covered the cloud window. Each pulse is one tiny RPC per
    -- renderer, gated on somebody being close enough to see it.
    for t = 0, (cloudSecs - 2) * 1000, HIVE_SPORE_PULSE_MS do
        Utils.QueueWork(function()
            if Utils.IsActorInvalid(owner) then return end
            if not Utils.IsPlayerNearby(anchor, HIVE_PULSE_NEAR) then return end
            AVU.SendClientFX(anchor, "HIVE_SPORES", cloudSecs)
        end, t)
    end
end


-- The tail-throw: drop a cloud where the target WAS at fire time. Dispatched from the Sow class
-- hook (CombatHooks "Sow" -> OnRangedAttack).
--   * opts.ApplyDelay shortens the escape window for a PET (it fights FOR the owner); the wild
--     sow keeps the full window so players can step out.
--   * opts.BeeMult goes to DropCloud (the pet's per-level damage).

function HS.RangedAttack(actor, opts)
    if Utils.IsActorInvalid(actor) then return end
    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end

    -- Every throw passes through here, which is what makes HS.ForceThrow a floor rather than an
    -- addition. ActorKey, not the memo: the hook hands a fresh wrapper each time.
    local key = Utils.ActorKey(actor)
    if key then hiveLastThrow[key] = STATE.FAST_TICK end

    -- A MOVE ORDER IS NOT AN ENEMY: the bait stays the combat target after AttackMove, so
    -- anchoring on it drops the cloud on the ordered-to spot and then on the world origin.
    -- Stamped above first, so the sow goes quiet for the throw floor instead of retrying.
    if AVU.IsAggroBait(target) then return end

    -- The last gate before a cloud exists. The throw montage has already played by now, so a
    -- walled-off target costs the sow the attack rather than getting bombed through the wall.
    if not hiveCanSee(actor, target) then
        LogDebug(hiveName(actor) .. " - throw held (cover between it and its target)", SETTINGS.DEBUG_NPC_ACTIONS)
        return
    end

    local applyDelay = (opts and opts.ApplyDelay) or HIVE_APPLY_DELAY   -- 0 is truthy in Lua

    local targetLoc = target:K2_GetActorLocation()
    LogDebug(hiveName(actor) .. " - ranged attack (bee cloud incoming)", SETTINGS.DEBUG_NPC_ACTIONS)

    -- Plain-table anchor (never hold a UE struct across ticks - CLAUDE.md 3).
    local anchor = { X = targetLoc.X, Y = targetLoc.Y, Z = targetLoc.Z }

    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) then return end
        HS.DropCloud(anchor, actor, { ApplyDelay = applyDelay, BeeMult = opts and opts.BeeMult })
    end, HIVE_BOMB_DELAY)
end


-- [AUTHORITY, OnTick] GUARANTEE THE CLOUD - throw for the sow when its tree won't.
--   * The tree is a plain selector of distance tests and the throw branch wants the target past
--     450uu, so a sow that gets walked down stops using its signature attack entirely. Nothing on
--     the pawn re-opens it: the pounce has no cooldown to raise, a smaller MeleeAttackRange only
--     walks it in closer, and a kite loses - the move-to branch re-issues the instant our order
--     cancels it (the retreat-and-return twitch this replaced).
--   * TryRangedAttackCheck gates on nothing but its own cooldown - no range, no line of sight - so
--     raising the event ourselves works point-blank, and it re-enters our own OnRangedAttack hook,
--     which keeps the cloud, the turn, the montage and the client FX native. Cover is the one
--     thing we DO have to supply (hiveCanSee), or the sow bombs through walls.
--   * It also ends the running attack task (both tasks finish on the CombatReset the throw
--     broadcasts), so a sow locked in a bite loop gets a break out of it.
-- Peek, then stamp by hand: the stamp belongs to a throw we actually asked for.
--   opts.FloorTicks  a different floor (the pet throws on a shorter one)
--   opts.Force       skip the floor and the spawn grace, for a throw the caller already decided on

function HS.ForceThrow(actor, opts)
    if Utils.IsActorInvalid(actor) or not actor.CombatState then return end
    if actor.IsDead or actor.AboutToThrow or actor.IsStampeding then return end

    local key = AVU.CachedFullName(actor)
    if not key then return end

    local floor = (opts and opts.FloorTicks) or HIVE_THROW.FloorTicks
    if not (opts and opts.Force) then
        -- SPAWN GRACE. A fresh body has no stamp, so the floor reads ready on its very first tick
        -- and the sow throws before it has settled on a target. Seeding here rather than from the
        -- def covers the wild sow, the pet and the witches at once.
        if not hiveLastThrow[key] then
            hiveLastThrow[key] = STATE.FAST_TICK - (floor - HIVE_THROW.GraceTicks)
            return
        end
        if not AVU.CooldownReady(hiveLastThrow, key, floor, { Peek = true }) then return end
    end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) or AVU.IsAggroBait(target) then return end

    -- Refused rather than stamped: cover is a reason to wait, not to spend the floor. The sow
    -- throws the moment it has a clear line again.
    if not hiveCanSee(actor, target) then return end

    -- Broadcast_DoRangedAttackFX can cold-load the throw montage, so never from the drain.
    Utils.DelayedGameThread(HIVE_THROW.HopMs, function()
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        if Utils.IsActorInvalid(target) then return end
        pcall(function() actor:Server_DoRangedAttack(target, FVector(0, 0, 0), 1) end)
    end)

    hiveLastThrow[key] = STATE.FAST_TICK
    LogDebug(hiveName(actor) .. " - forced throw", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- [AUTHORITY, OnTick] KEEP THE RANGE - by refusing to move, not by walking away.
--   * The move-to branch cannot be out-ORDERED: it re-issues the instant our MoveTo cancels it. It
--     has no answer to a SPEED of zero, though - the orders keep coming and the sow simply doesn't
--     travel, so it settles wherever we plant it and stops running players down.
--   * HoldGround leaves the movement component live, so knockback and the pounce still work. What
--     it costs is combat FACING, which on this family IS the movement - hence the re-aim, off a
--     facing error rather than the clock so the turn timeline isn't restarted mid-turn.
-- Releasing is not optional: a sow that drops combat while planted stays planted.

local function hiveKeepFacing(actor, aLoc, tLoc)
    local rot
    pcall(function() rot = actor:K2_GetActorRotation() end)
    if not rot then return end
    if math.abs(AVM.AngleDiff(AVM.YawTo(aLoc, tLoc), rot.Yaw or 0)) < HIVE_STANDOFF.FaceDegrees then return end
    AVU.TurnToTarget(actor)
end

local function hiveRelease(actor, key)
    if not hiveHeld[key] then return end
    hiveHeld[key] = nil
    AVU.ReleaseGround(actor)
end

function HS.KeepRange(actor)
    local key = AVU.CachedFullName(actor)
    if not key then return end

    local target
    if actor.CombatState then target = actor:GetCurrentCombatTarget() end
    -- Bait = a move order, not something to stand off from; planting on one strands the sow.
    if Utils.IsActorInvalid(target) or AVU.IsAggroBait(target) then return hiveRelease(actor, key) end

    local aLoc, tLoc = actor:K2_GetActorLocation(), target:K2_GetActorLocation()
    if not (aLoc and tLoc) then return end
    local dsq = Utils.DistSq(aLoc, tLoc)

    if hiveHeld[key] then
        if dsq >= HIVE_STANDOFF.HoldOut * HIVE_STANDOFF.HoldOut then return hiveRelease(actor, key) end
        hiveKeepFacing(actor, aLoc, tLoc)
    elseif dsq <= HIVE_STANDOFF.HoldIn * HIVE_STANDOFF.HoldIn and AVU.HoldGround(actor) then
        hiveHeld[key] = true
        LogDebug(hiveName(actor) .. " - holding range", SETTINGS.DEBUG_NPC_ACTIONS)
    end
end

-- [AUTHORITY] Drop the plant now, for a caller about to move the sow itself (a planted sow has no
-- speed to move with). KeepRange re-plants on its next pass if the caller doesn't hold it off.
function HS.ReleaseRange(actor)
    local key = AVU.CachedFullName(actor)
    if key then hiveRelease(actor, key) end
end


-- [OnDeath] both tables are string-keyed, so nothing collects on its own - and ReleaseGround has a
-- stash of its own to drop.
function HS.Forget(actor)
    local key = Utils.ActorKey(actor)
    if not key then return end
    hiveLastThrow[key] = nil
    hiveRelease(actor, key)
end


-- Melee sting with the 2s cap. The lunge re-hits rapidly at point-blank, so gate per victim: apply
-- once, ignore re-hits for HIVE_EXPIRE_MS so the swarm runs its ~2s and re-arms. The sow only
-- melees its combat enemy (a pet won't melee its owner), so no hostility check is needed.
-- `mult` as in hiveStingTarget (the pet passes its per-level value).

function HS.MeleeSting(victim, attacker, mult)
    if Utils.IsActorInvalid(victim) or Utils.IsActorInvalid(attacker) then return end
    local ok, key = pcall(function() return victim:GetFullName() end)
    if not ok or not key then return end
    if hiveMeleeStung[key] then return end

    hiveMeleeStung[key] = true
    local isNpc = false
    pcall(function() isNpc = IsValid(victim.NPCData) end)
    hiveStingTarget(victim, attacker, mult, isNpc)
    Utils.QueueWork(function() hiveMeleeStung[key] = nil end, HIVE_EXPIRE_MS)
end


-- =======================================================================
-- TAMED SOW MILK - re-apply our tint after the native udder harvest
-- =======================================================================
-- The harvest re-inits the sow's mesh, wiping the tamed tint back to the base purple. Its
-- Multicast_PlayHarvestSound fires on EVERY machine, so ONE hook (registered on all roles) covers
-- both halves: re-run the variant's Visuals on any renderer, and drop the byproduct on authority.
-- Registered once per UE4SS session; the flag only latches on SUCCESS, so a failed registration
-- (class not loaded yet) retries on the next world load.

function HS.RegisterMilkHook()
    if STATE.SowMilkHookRegistered then return end

    local HOOK = "/Game/Blueprints/Characters/Components/HarvestingComponent.HarvestingComponent_C:Multicast_PlayHarvestSound"
    local ok = pcall(RegisterHook, HOOK, function(self)
        local comp = self:get()
        if IsNotValid(comp) then return end
        local owner; pcall(function() owner = comp:GetOwner() end)
        if Utils.IsActorInvalid(owner) then return end
        -- Identify our tamed sow by the replicated VariantTag, NOT DisplayName (which doesn't
        -- replicate, so it would fail on a joined client). Cheap sow-row early-out first.
        if Utils.GetActorRowName(owner) ~= "Sow" then return end
        local VariantTag = require("AnteVariants.VariantTag")
        local VARIANTS = require("AnteVariants.Variants")
        local def = VARIANTS["Tamed Hive Sow"]
        if not (def and VariantTag.Decode(owner) == def.Id) then return end

        -- Re-apply the tint. Small delay so it runs AFTER the native mesh reset settles. (The
        -- beehive attach is guard-skipped, so only the colour re-applies.)
        if Utils.HasRenderer() and def.Visuals then
            Utils.QueueWork(function()
                if Utils.IsActorInvalid(owner) then return end
                pcall(def.Visuals, owner, {})
            end, 300)
        end

        -- Milk byproduct, authority only (the multicast fires everywhere).
        if Utils.IsAuthority() then
            Utils.QueueWork(function()
                if Utils.IsActorInvalid(owner) then return end
                local loc = owner:K2_GetActorLocation()
                if not loc then return end
                local IS = require("AnteCore.ItemSpawner")
                IS.DropPool({ { Items.Global.HONEY, 2 }, { Items.Global.WAX, 1 } }, nil, loc, 60)
            end, 200)
        end
    end)
    if ok then STATE.SowMilkHookRegistered = true end
    Log("HiveSow - milk recolor hook " .. (ok and "registered" or "not yet (class unloaded) - retry next world"))
end


return HS
