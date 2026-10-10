-- =======================================================================
-- ModuleShadow/ShadowBoss - the final boss (The Shadow, south island). AUTHORITY.
--   Gate: SETTINGS.GAMEPLAY.MODULE_SHADOWBOSS. Tuning lives in the KNOBS table below (kept out of
--   SETTINGS so the settings file doesn't spoil the fight). Full decode: AnNotes/Modules/ShadowBoss.md.
--
-- The native fight (VignetteDirector_ShadowBoss on V_ISLAND owns it): BossPhase 1 -> Storm 1 ->
-- BossPhase 2 -> Storm 2 -> BossPhase 3 -> victory. Each phase spawns a fresh NPC_Boss_Shadow.
--
-- WHAT THIS MODULE DOES: adopts the director; post-hooks its phase seams (ApplyPhaseStatsToBoss,
-- StartPortalStorm/EndPortalStorm, OnBossDeath); owns the storm clock (disarms the native ends,
-- ends storms itself on a live-enemy poll); coaxes far-away storm enemies toward players; tunes
-- boss knobs per phase (torso HP, teleport cadence, ability cooldowns); trims/transforms the
-- SpawnTentacles shield event; forces the boss back into combat when it drops target; echoes
-- native hand slams with extra calls (optionally turret-seeking) and adds bonus hand-slam impact
-- damage; hosts the ShadowStorms content seams; and exposes /au-boss dev commands.
--
-- THREADING (CLAUDE.md S2): every hook handler defers through Utils.QueueWork. Ending the storm
--   ourselves calls the director's EndPortalStorm(), which chains STRAIGHT into StartNextPhase ->
--   SpawnBoss (a real spawn, cold-loads on the first boss of a session) - so that hop goes through
--   Utils.DelayedGameThread, not plain EIGT (need a real escape from the drain's hook frame; see
--   endStorm).
-- STATE: module-local, reset by SB.Reset() from Utils.ResetState (world teardown).
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local ASSETS = require("AnteCore.AssetManager")
local ENUMS = require("AnteData.Enums")

local Log, LogBad, LogDebug = Utils.Log, Utils.LogBad, Utils.LogDebug

local SB = {}

local ENABLED = SETTINGS.GAMEPLAY.MODULE_SHADOWBOSS == true
local DBG = SETTINGS.DEBUG_NPC_ACTIONS

-- =======================================================================
-- KNOBS - the fight tuning. Per-BossPhase arrays are indexed 1/2/3.
-- =======================================================================
local CFG = {
    -- Boss burrow/relocate IDLE timer per BossPhase (native 30/30/20). This timer, not damage,
    -- ends most damage windows - the 2026-08-15b log had 15/10/5 here and every window closed
    -- on the clock long before the stagger pool was touched. nil = leave native
    TeleportSeconds = { 30, 30, 30 },

    -- Boss stagger pool per BossPhase (native 1000 all phases)
    StaggerStamina = { 1000, 1000, 1000 },

    -- Boss torso HP per BossPhase (native 3000; the game ADDS +600 / +1000 in phases 2/3 on top
    -- of whatever the base is, so these read 6000 / 6600 / 7000). Head (the DBNO kill pool) is
    -- left at 500. nil = native
    TorsoHp = { 3000, 4000, 5000 },

    -- Native: a boss that is NOT in combat burrows on EVERY hit (no stamina check) - so an
    -- attacker it can't perceive (invisibility) locks it into a burrow per hit. The 2026-08-16
    -- log proved the ReceivePointDamage hook alone was NOT closing this (36s attack lulls, then
    -- one-hit "quick retreats" on every emerge, zero force logs) - so the boss WATCH POLL now
    -- enforces it too: any live boss found out of combat is ForceAggro'd at the nearest player.
    ForceCombatOnHit = true,

    -- Max seconds of stagger grace after an emerge, for ONE case only: a boss that emerges OUT of
    -- combat (it dropped its target while burrowed - the invisible-attacker fight) gets instantly
    -- re-burrowed by CheckForStagger's !CombatState branch on the first hit. So RecentlyStaggered
    -- is latched only then, released the moment combat resumes or this timeout expires. A boss
    -- that emerges IN combat gets no grace - the latch is a zero-drain clean return, and an
    -- unconditional grace let hitscan ROF out-damage the whole stagger pool. Crit-forced staggers
    -- still go through. 0 = native behavior.
    -- Do not swap the latch to IsPerformingDoorEnter: NPC_Base.ReceiveTick latches
    -- LockedInPlaceMontage every tick while that flag is set, with no door montage to ever clear
    -- it, so IsNPCBusy() parks the BT forever (no orbs/shield/beam; tried and reverted).
    EmergeGraceSeconds = 2.5,

    -- Shield tentacles per event, TOTAL (native = min(6+players,10), 15 on Apocalyptic) - the
    -- small ones are a visual nuisance more than a threat ...
    TentacleTotal = { 5, 4, 3 },
    -- ... of which this many are transformed into Giant Tentacles per BossPhase. They stay in
    -- the boss's array = they hold the shield. Phase 3 = 3 of 3: giants only.
    GiantTentacles = { 1, 2, 3 },

    -- AFTERSHOCK: this many seconds after each shield event, one EXTRA Giant Tentacle rises next
    -- to the boss. It is a spawn of ours, NOT in the boss's array - so it fights (and tethers its
    -- beam; the class self-finds the boss at BeginPlay) but killing it does NOT help drop the
    -- shield, and it OUTLIVES the shield. Dies with the boss (lifetime-linked). nil/0 = off.
    AftershockTentacleSeconds = 20,

    -- ECHO hand slams: each NATIVE slam (fixed 20s timer) is followed by this many extra slams,
    -- EchoDelayMs apart - a 1-2-3 punch instead of a separate cadence. The echo call self-gates
    -- exactly like the native one (no shield up, not teleporting, has a target).
    HandSlamEcho = { 0, 1, 2 },
    HandSlamEchoDelayMs = 2500,

    -- Echo hands hunt turrets (per BossPhase): an echo slam retargets onto a random standing
    -- player laser turret in LoS of the boss (within TurretSeekRange), punishing turret nests.
    -- Falls back to the normal combat target when no turret qualifies.
    EchoSlamSeeksTurrets = { false, true, true },
    TurretSeekRange = 12000,

    -- HAND SLAM IMPACT (every slam, native and echo alike): the native radial's linear falloff and
    -- the deployable x0.5 NPC-damage cut mean it never scratches a turret nest - see
    -- AnNotes/Modules/ShadowBoss.md "HAND SLAM IMPACT" for the full decode. These add on top of the native
    -- hit: flat turret damage within radius (500 here = 250 durability = dead in 2 slams), and a
    -- player bonus (flat damage + KnockbackFrom shove). Zero/nil a field to leave the native slam
    -- alone.
    HandSlamTurretDamage = 500,
    HandSlamTurretRadius = 450,
    HandSlamPlayerBonus = { Damage = 100, Radius = 400, Knockback = 900, KnockbackUp = 350 },

    -- Ability 3 (eye beam) cooldown {min,max} per BossPhase (native: disabled / 15-20 / 10-15).
    -- nil = native.
    BeamCooldown = { nil, { 20, 30 }, { 15, 25 } },

    -- Ability 2 (shield + tentacles) cooldown {min,max} per BossPhase (native 20-40 / 18-30 /
    -- 18-30; the roll happens only after ALL tentacles of the previous event die). nil = native.
    ShieldCooldown = { { 20, 40 }, { 18, 30 }, { 45, 60 } },

    -- Storm control. Native: ends at <=3 alive (once all 10 spawned) or 300s. Ours: never before
    -- Min, then when every tracked enemy is dead, hard stop at Max. Arrays indexed by storm 1/2.
    StormMinSeconds = { 90, 150 },
    StormMaxSeconds = { 240, 300 },
    -- "All dead" tolerates this many survivors once Min has passed: one or two bodies always end
    -- up in the ocean / wedged, and they should not hold the storm to Max. (The all-dead end still
    -- waits for the script's own content to finish - SS.Pending.)
    StormEndLeftover = 2,

    -- Every N seconds, nudge far-away storm enemies toward a random player (0 = off)
    CoaxSeconds = 15,

    -- STRAGGLER OUTLINE: once a storm has run HuntAfterSeconds with at most HuntMaxAlive enemies
    -- left, the survivors are outlined through walls (yellow) so the wedged/lost ones can be
    -- hunted down instead of the storm sitting on its max clock. Renderer-side, all machines,
    -- via the OUTLINE ClientFX opcode. nil/0 = off.
    HuntAfterSeconds = { 150, 210 },
    HuntMaxAlive = 5,
}

-- Game classes / hook paths (director + boss + level BP)
local DIRECTOR_CLASS = "/Game/Blueprints/Environment/Systems/ShadowBoss/VignetteDirector_ShadowBoss.VignetteDirector_ShadowBoss_C"
local DIRECTOR_SHORT = "VignetteDirector_ShadowBoss_C"
local BOSS_CLASS     = "/Game/Blueprints/Characters/NPCs/NPC_Boss_Shadow.NPC_Boss_Shadow_C"
local ISLAND_LEVEL   = "V_ISLAND_C"

local HOOK_PHASE_STATS = DIRECTOR_CLASS .. ":ApplyPhaseStatsToBoss"
local HOOK_STORM_START = DIRECTOR_CLASS .. ":StartPortalStorm"
local HOOK_STORM_END   = DIRECTOR_CLASS .. ":EndPortalStorm"
local HOOK_BOSS_DEATH  = DIRECTOR_CLASS .. ":OnBossDeath"
local HOOK_TENTACLES   = BOSS_CLASS .. ":SpawnTentacles"        -- fires AFTER the body (see the tentacle section)
local HOOK_BOSS_HIT    = BOSS_CLASS .. ":ReceivePointDamage"    -- PRE: force combat on first hit
local HAND_CLASS       = "/Game/Blueprints/Characters/NPCs/ShadowBossHand.ShadowBossHand_C"
local HOOK_HAND_SLAM   = HAND_CLASS .. ":Broadcast_Slam"        -- PRE, server: the hand just LANDED (see the slam section)

local POLL_MS         = 1000     -- storm poll cadence
local NEVER_SECONDS   = 999999   -- disable the native portal phase (MaxPortalStormTime)
local COAX_FAR_SQ     = 4000 * 4000   -- an enemy farther than this from every player gets directed towards a player
local COAX_NEAR       = 1500     -- ...to a nav point within this of a random player
local OFFHOOK_HOP_MS  = 50       -- NpcSpawner's hop: long enough to really land on the worker thread


-- =======================================================================
-- Per-world state (SB.Reset clears)
-- =======================================================================
local hooksArmed   = false   -- RegisterHook is per-process; only the WRAPPERS below are per-world
local notifyArmed  = false
local director     = nil     -- the live VignetteDirector wrapper (nil until adopted)
local stormState   = nil     -- { startTick, phase, nativeDisarmed, coaxTick, ended } while a storm is ours
local trackedNpcs  = {}      -- ActorKey -> npc wrapper: OUR extra spawns (native adds read off the director)
local pollActive   = false


function SB.Reset()
    director, stormState, trackedNpcs, pollActive = nil, nil, {}, false
    if SB._resetSlams then SB._resetSlams() end
    if SB._resetWatch then SB._resetWatch() end
    if SB.OnBossContentEnd then pcall(SB.OnBossContentEnd, "reset") end
    if SB.OnStormReset then pcall(SB.OnStormReset) end
end


-- =======================================================================
-- Director access
-- =======================================================================
local function findDirector()
    if Utils.IsActorValid(director) then return director end
    director = nil
    for _, d in ipairs(FindAllOf(DIRECTOR_SHORT) or {}) do
        local fn; pcall(function() fn = d:GetFullName() end)
        if fn and not fn:find("Default__") and Utils.IsActorValid(d) then
            director = d
            break
        end
    end
    return director
end

function SB.Director() return findDirector() end

-- The live boss, via the director (nil between phases / before the fight)
function SB.Boss()
    local d = findDirector()
    if not d then return nil end
    local boss
    pcall(function() boss = d.ActiveBoss end)
    if Utils.IsActorInvalid(boss) then return nil end
    return boss
end

-- 1/2/3 = the boss phase; during a storm this is the phase whose boss just died (= Storm N)
function SB.Phase()
    local d = findDirector()
    local p = 0
    if d then pcall(function() p = tonumber(d.CurrentBossPhase) or 0 end) end
    return p
end

function SB.StormActive()
    local d = findDirector()
    local on = false
    if d then pcall(function() on = d.PortalStormActive == true end) end
    return on
end


-- =======================================================================
-- ECHO hand slams. The native slam timer (20s, StartHandSlamAttacks) isn't a property, so instead
-- we ride HandSlamAttack() - it's callable and self-gates (server, no shield up, not teleporting,
-- has a target). A NotifyOnNewObject on the hand actor tells us a native slam just fired, and we
-- answer with CFG.HandSlamEcho[phase] extra calls ~1s apart (S2: preload the class, hop off drain).
-- `echoCalling` tags our own hands: the notify fires synchronously inside our HandSlamAttack()
-- call, so a plain flag around the call is race-free. TURRET SEEK: an echo hand can be retargeted
-- onto a standing player laser turret in LoS by writing HomingTarget and calling
-- OnRep_HomingTarget() (that's what wires the projectile's homing component - HomingTarget itself
-- is read only once, at the hand's BeginPlay). Deployed_Turret_Laser_AUTO is skipped
-- (bCanBeDamaged=false).
-- =======================================================================
local echoCalling = false    -- true only INSIDE our own HandSlamAttack() call (read by the notify)
local RETARGET_DELAY_MS = 150    -- after the echo hand spawns; its BeginPlay target-grab is done
local TURRET_CLASS_SHORT = "Deployed_Turret_Laser_C"

function SB._resetSlams() echoCalling = false end

-- Random standing player laser turret in LoS of the boss, or nil. One-shot FindAllOf per echo
-- slam (<= a few per 20s volley) - never a tick.
local function seekTurret(boss)
    local bl
    pcall(function() bl = boss:K2_GetActorLocation() end)
    if not bl then return nil end
    local eye = FVector(bl.X, bl.Y, bl.Z + 500)   -- trace from mid-body, not the waterline
    local rangeSq = (CFG.TurretSeekRange or 12000) ^ 2
    local candidates = {}
    for _, t in ipairs(FindAllOf(TURRET_CLASS_SHORT) or {}) do
        if Utils.IsActorValid(t) then
            local tl
            pcall(function() tl = t:K2_GetActorLocation() end)
            if tl and Utils.DistSq(bl, tl) <= rangeSq
                and not AVU.IsPathBlocked(boss, eye, FVector(tl.X, tl.Y, tl.Z + 50), { boss, t }) then
                candidates[#candidates + 1] = t
            end
        end
    end
    if #candidates == 0 then return nil end
    return candidates[math.random(1, #candidates)]
end

local function retargetHandAtTurret(hand)
    local phase = SB.Phase()
    if not (CFG.EchoSlamSeeksTurrets and CFG.EchoSlamSeeksTurrets[phase]) then return end
    if Utils.IsActorInvalid(hand) then return end
    local boss = SB.Boss()
    if not boss then return end
    local turret = seekTurret(boss)
    if not turret then return end
    pcall(function()
        hand.HomingTarget = turret
        Utils.MarkReplicatedDirty(hand, "HomingTarget")
        hand:OnRep_HomingTarget()
    end)
    LogDebug("ShadowBoss - echo hand retargeted onto a laser turret", DBG)
end

-- A NATIVE hand just spawned: answer with the phase's echo volley.
local function scheduleEchoes()
    local phase = SB.Phase()
    local n = (CFG.HandSlamEcho and CFG.HandSlamEcho[phase]) or 0
    if n <= 0 then return end
    local gap = CFG.HandSlamEchoDelayMs or 1000
    for i = 1, n do
        Utils.QueueWork(function()
            if not STATE.ModEnabled then return end
            local b = SB.Boss()
            if not b or Utils.IsDeadSafe(b) then return end
            ASSETS.LoadAsync({ HAND_CLASS }, function()
                Utils.DelayedGameThread(OFFHOOK_HOP_MS, function()
                    local b2 = SB.Boss()
                    if not b2 or Utils.IsDeadSafe(b2) then return end
                    echoCalling = true
                    pcall(function() b2:HandSlamAttack() end)
                    echoCalling = false
                end)
            end)
        end, gap * i)
    end
    LogDebug("ShadowBoss - native slam echoed x" .. n .. " (phase " .. phase .. ")", DBG)
end

-- =======================================================================
-- HAND SLAM IMPACT - what happens where the hand lands (native and echo alike). Broadcast_Slam is
-- a true PRE hook (engine-dispatched multicast, DoOnce'd per hand) firing right as the hand lands,
-- so self:get() is at the impact point - see AnNotes/Modules/ShadowBoss.md for the full decode.
-- Turrets take flat damage off-hook through their own ReceivePointDamage (a killing blow runs the
-- deployable's destroy/drop chain, so this must not run in-drain - the S6 kill-path hazard); not
-- AVU.PointDamageOffHook, since its IsDeadSafe read errors (and reads "dead") on a deployable.
-- Players take AVU.BlastDamage (the same off-hook-safe pattern) with a knockback bonus.
-- The hand class only resolves once a hand exists, so this hook arms from the first hand notify.
-- =======================================================================
local handHooksArmed = false
local gsDefault = nil   -- /Script/ default object: never GCs, cache once (the PointDamageOffHook precedent)

local function slamTurret(bossPath, turretPath, dmg)
    ExecuteInGameThread(function()
        STATE.LastWork = "EIGT slamTurret"
        STATE.LastWorkDone = false
        pcall(function()
            local t = Utils.ResolveByPath(turretPath)
            if not t then return end
            local gone = false
            pcall(function() gone = t.DeployableDestroyed == true end)
            if gone then return end
            if IsNotValid(gsDefault) then gsDefault = ASSETS.GetIfValid("/Script/Engine.Default__GameplayStatics") end
            local dt = ASSETS.GetIfValid(ENUMS.DamageType.Explosive)
            if IsNotValid(gsDefault) or IsNotValid(dt) then return end   -- never fire untyped
            local boss = bossPath and Utils.ResolveByPath(bossPath)
            local ctrl
            if boss then pcall(function() ctrl = boss.NPC_Controller end) end
            gsDefault:ApplyPointDamage(t, dmg, FVector(0, 0, -1), {}, ctrl, boss, dt)
        end)
        STATE.LastWorkDone = true
    end)
end

local function onHandSlam(loc)
    local boss = SB.Boss()
    if not boss then return end
    local bossPath = Utils.ObjectPath(boss)

    -- Turrets in radius -> flat damage each (off-hook, DamageType warmed first).
    local tdmg = CFG.HandSlamTurretDamage or 0
    if tdmg > 0 then
        local r2 = (CFG.HandSlamTurretRadius or 450) ^ 2
        local paths = {}
        for _, t in ipairs(FindAllOf(TURRET_CLASS_SHORT) or {}) do
            if Utils.IsActorValid(t) then
                local tl
                pcall(function() tl = t:K2_GetActorLocation() end)
                if tl and Utils.DistSq(loc, tl) <= r2 then
                    local p = Utils.ObjectPath(t)
                    if p then paths[#paths + 1] = p end
                end
            end
        end
        if #paths > 0 then
            ASSETS.LoadAsync({ ENUMS.DamageType.Explosive }, function()
                for _, p in ipairs(paths) do slamTurret(bossPath, p, tdmg) end
            end)
            LogDebug("ShadowBoss - hand slam hit " .. #paths .. " turret(s)", DBG)
        end
    end

    -- Players: bonus damage + shove.
    local pb = CFG.HandSlamPlayerBonus
    if pb and ((pb.Damage or 0) > 0 or (pb.Knockback or 0) > 0) then
        ASSETS.LoadAsync({ ENUMS.DamageType.Explosive }, function()
            local b = SB.Boss()
            if not b then return end
            AVU.BlastDamage(b, loc, {
                Damage = pb.Damage or 0, Radius = pb.Radius or 400,
                DamageType = ENUMS.DamageType.Explosive,
                Knockback = pb.Knockback or 0, KnockbackUp = pb.KnockbackUp or 300,
            })
        end)
    end
end

local function armHandHooks()
    if handHooksArmed then return end
    local ok, err = pcall(function()
        RegisterHook(HOOK_HAND_SLAM, function(self)
            if not STATE.ModEnabled then return end
            local hand = self:get()
            local loc
            pcall(function() loc = hand:K2_GetActorLocation() end)
            if not loc then return end
            Utils.QueueWork(function() onHandSlam(loc) end, 0)
        end)
    end)
    if ok then
        handHooksArmed = true
        Log("ShadowBoss - hand slam hook armed")
    else
        LogBad("ShadowBoss - hand slam hook FAILED: " .. tostring(err))
    end
end

-- The notify callback body (armed in SB.Register): NEVER touch actors in the notify - the flag
-- read is pure Lua, everything else queues.
function SB._onHandSpawned(hand)
    if not STATE.ModEnabled then return end
    if not handHooksArmed then Utils.QueueWork(armHandHooks, 0) end
    if echoCalling then
        Utils.QueueWork(function() retargetHandAtTurret(hand) end, RETARGET_DELAY_MS)
        return
    end
    Utils.QueueWork(scheduleEchoes, 0)
end


-- =======================================================================
-- Boss watch poll - per living boss, every BOSS_WATCH_MS (BOSS_WATCH_GRACE_MS while a grace is
-- armed, so release lands within a tenth-second of combat resuming). See the EmergeGraceSeconds
-- CFG comment for why the emerge grace is conditional. Combat enforcement: a live boss out of
-- CombatState mid-fight is the instant-stagger failure state, so it gets ForceAggro'd at the
-- nearest player (the ReceivePointDamage hook alone wasn't reliable enough by itself).
-- Two property reads per tick on one actor - noise. Token'd per boss; dies with it.
-- =======================================================================
local BOSS_WATCH_MS       = 500
local BOSS_WATCH_GRACE_MS = 100
local FORCE_COMBAT_EVERY  = 30    -- FAST_TICK ticks (~3s) between ForceAggro attempts

local watchToken = {}   -- ActorKey -> latest watch token (a new boss / re-apply supersedes)
function SB._resetWatch() watchToken = {} end

local function nearestPlayer(loc)
    local best, bestSq
    for _, p in ipairs(Utils.LivePlayers()) do
        local pl
        pcall(function() pl = p:K2_GetActorLocation() end)
        local d = pl and Utils.DistSq(loc, pl)
        if d and (not bestSq or d < bestSq) then best, bestSq = p, d end
    end
    return best
end

local function startBossWatch(boss)
    local key = Utils.ActorKey(boss)
    if not key then return end
    local token = (watchToken[key] or 0) + 1
    watchToken[key] = token
    local wasInvincible = false
    local lastForce = 0
    local graceUntilMs = nil   -- os.clock()-based deadline while OUR RecentlyStaggered latch is armed; nil = not armed

    local function releaseGrace(b, why)
        graceUntilMs = nil
        -- Our latch only (the native clear is a RetriggerableDelay only a NATIVE stagger arms).
        -- A native burrow meanwhile already cleared it via ResetStagger; writing false again is
        -- harmless - nothing else consults the flag on this boss.
        pcall(function() b.RecentlyStaggered = false end)
        LogDebug("ShadowBoss - stagger grace released (" .. why .. ")", DBG)
    end

    local function watch()
        if not STATE.ModEnabled or watchToken[key] ~= token then return end
        local b = SB.Boss()
        if not b or Utils.ActorKey(b) ~= key or Utils.IsDeadSafe(b) then
            watchToken[key] = nil
            return
        end

        local invincible, inCombat = false, true
        pcall(function()
            invincible = b.Invincible == true
            inCombat = b.CombatState == true
        end)

        if wasInvincible and not invincible then
            -- Emerged. LockedInPlaceMontage=false repairs a boss the 08-16e build already broke
            -- (harmless otherwise). The stagger latch is CONDITIONAL: only a boss that came up
            -- OUT of combat gets it (that is the one-hit !CombatState re-burrow case); a boss
            -- in combat starts counting its pool on the first hit - see the CFG comment.
            pcall(function() b.LockedInPlaceMontage = false end)
            if not inCombat and (CFG.EmergeGraceSeconds or 0) > 0 then
                -- RecentlyStaggered = CheckForStagger's cooldown branch (a clean return; NOTHING
                -- else consults it). See the CFG comment for why NOT IsPerformingDoorEnter -
                -- that "stronger" latch tick-latches LockedInPlaceMontage and parks the BT forever.
                pcall(function() b.RecentlyStaggered = true end)
                graceUntilMs = os.clock() * 1000 + CFG.EmergeGraceSeconds * 1000
                lastForce = 0   -- force combat NOW, not on the throttle
                LogDebug("ShadowBoss - emerged out of combat: stagger grace latched", DBG)
            elseif DBG then
                LogDebug("ShadowBoss - emerged in combat: no grace, pool live", DBG)
            end
        end
        wasInvincible = invincible

        -- Release the latch the moment combat is back (the poll runs at the fast cadence while
        -- armed, so this lands within ~100ms), or at the timeout, or if the boss burrowed again
        -- (a native ResetStagger will refill and clear at the next emerge; drop our bookkeeping).
        if graceUntilMs then
            if inCombat then
                releaseGrace(b, "combat resumed")
            elseif invincible then
                releaseGrace(b, "burrowed")
            elseif os.clock() * 1000 >= graceUntilMs then
                releaseGrace(b, "timeout")
            end
        end

        if CFG.ForceCombatOnHit ~= false and not inCombat and not invincible
            and STATE.FAST_TICK - lastForce >= FORCE_COMBAT_EVERY then
            local bl
            pcall(function() bl = b:K2_GetActorLocation() end)
            local p = bl and nearestPlayer(bl)
            if p then
                lastForce = STATE.FAST_TICK
                AVU.ForceAggro(b, p)
                LogDebug("ShadowBoss - boss out of combat; forced onto nearest player", DBG)
            end
        end

        Utils.QueueWork(watch, graceUntilMs and BOSS_WATCH_GRACE_MS or BOSS_WATCH_MS)
    end
    Utils.QueueWork(watch, BOSS_WATCH_MS)
end


-- =======================================================================
-- Boss knobs - applied after the game's own ApplyPhaseStatsToBoss. TimeToTeleport is the idle
-- burrow cadence, read once when the timer (re)arms at the end of each teleport, so a write any
-- time before that lands. Stamina is the real stagger/burrow pool (AI_PerformStagger IS a burrow;
-- CheckForStagger drains it per hit and staggers at 0) - a bigger pool means longer damage
-- windows. The same function also staggers on any hit while !CombatState with no stamina check;
-- forceCombat below closes that hole.
-- =======================================================================
local function applyBossKnobs(boss, phase)
    if Utils.IsActorInvalid(boss) then return end
    local tp = CFG.TeleportSeconds and CFG.TeleportSeconds[phase]
    if tp then
        pcall(function() boss.TimeToTeleport = tp end)
    end
    local stam = CFG.StaggerStamina and CFG.StaggerStamina[phase]
    if stam then
        pcall(function()
            boss:SetMaxStamina(stam)
            boss:SetCurrentStamina(stam)
        end)
    end
    -- Torso via the row + InitalizeHealthValues (faction-safe). The director's own
    -- MaxTorsoHealth_Add cheat-stat (+600/+1000) is a modifier on top of the row, so it survives.
    local torso = CFG.TorsoHp and CFG.TorsoHp[phase]
    if torso then AVU.SetLimbHealth(boss, { Torso = torso }) end

    -- Ability cooldowns: {min,max} FVector2D fields, mutated IN PLACE (never a struct assign -
    -- S3). The BT re-rolls from these on every use, so a post-phase-stats write holds all phase.
    local bc = CFG.BeamCooldown and CFG.BeamCooldown[phase]
    if bc then
        pcall(function()
            boss.Ability3Cooldown.X = bc[1]
            boss.Ability3Cooldown.Y = bc[2]
        end)
    end
    local sc = CFG.ShieldCooldown and CFG.ShieldCooldown[phase]
    if sc then
        pcall(function()
            boss.Ability2Cooldown.X = sc[1]
            boss.Ability2Cooldown.Y = sc[2]
        end)
    end

    LogDebug(string.format(
        "ShadowBoss - phase %d boss knobs applied (TimeToTeleport=%s, stamina=%s, torso=%s, beamCD=%s, shieldCD=%s)",
        phase, tostring(tp or "native"), tostring(stam or "native"), tostring(torso or "native"),
        bc and (bc[1] .. "-" .. bc[2]) or "native", sc and (sc[1] .. "-" .. sc[2]) or "native"), DBG)

    startBossWatch(boss)

    -- Boss-phase CONTENT (per-phase pressure spawns - ShadowStorms wires this seam).
    if SB.OnBossContent then pcall(SB.OnBossContent, phase) end
end


-- =======================================================================
-- Tentacles - the shield event (boss Ability 2). We're removing some of the boss's tentacles and
-- replacing them with our own.
--   * SpawnTentacles fills the boss's tentacle array; the shield drops when that array empties.
--   * This is a posthook, so we read the array after the fact: transform the first
--     CFG.GiantTentacles into Giant Tentacles, keep CFG.TentacleTotal, destroy the rest.
-- =======================================================================
local function onSpawnTentacles(boss)
    if Utils.IsActorInvalid(boss) then return end
    local phase = SB.Phase()
    local total = CFG.TentacleTotal and CFG.TentacleTotal[phase]
    local giants = (CFG.GiantTentacles and CFG.GiantTentacles[phase]) or 0

    local list = {}
    pcall(function()
        local arr = boss.SpawnedTentacles
        for i = 1, #arr do
            local t = arr[i]
            if Utils.IsActorValid(t) and not Utils.IsDeadSafe(t) then list[#list + 1] = t end
        end
    end)
    local native = #list
    if native == 0 then return end
    if not total then total = native end
    giants = math.min(giants, total)

    local kept, culled = 0, 0
    for i, t in ipairs(list) do
        if i <= giants then
            Utils.QueueWork(function()
                if not STATE.ModEnabled or Utils.IsActorInvalid(t) then return end
                pcall(function() require("AnteVariants.NpcManager").MutateActor("Giant Tentacle", t, {}) end)
            end, 200 + i * 150)
            kept = kept + 1
        elseif i <= total then
            kept = kept + 1
        else
            culled = culled + 1
            Utils.QueueWork(function()   -- off-hook; SkipSpawnFX + a 1.5s emerge hides the beat it lived
                if Utils.IsActorInvalid(t) then return end
                pcall(function() t:K2_DestroyActor() end)
            end, 0)
        end
    end
    Log(string.format("ShadowBoss - shield event (phase %d): %d spawned -> %d kept (%d giant), %d culled",
        phase, native, kept, giants, culled))

    -- The AFTERSHOCK giant (see the CFG comment). Placed 6-10m from the boss's CURRENT position
    -- at fire time (it burrows; a spot captured now can be empty water by then), lifetime-linked
    -- to the boss so it can't outlive the phase.
    local after = CFG.AftershockTentacleSeconds
    if after and after > 0 then
        local bossKey = Utils.ActorKey(boss)
        Utils.QueueWork(function()
            if not STATE.ModEnabled then return end
            local b = SB.Boss()
            if not b or Utils.ActorKey(b) ~= bossKey or Utils.IsDeadSafe(b) then return end
            local bl; pcall(function() bl = b:K2_GetActorLocation() end)
            if not bl then return end
            local spot = Utils.GetSpawnPoint(bl, 1000, 600)
            if not spot then return end
            require("AnteUtils.Spawning").PortalSummon(spot, { { Variant = "Giant Tentacle" } }, {
                Rift = false, EmergeMs = 0, EmergeFX = false,
                LifetimeOwner = b,
                OnSpawned = function(t)
                    -- Aftershock giants count as storm-gating enemies too, should the boss die
                    -- while one stands (a leftover would otherwise stall nothing - it self-destroys
                    -- with the boss - but the sweep/victory books should know it).
                    if Utils.IsActorValid(t) then SB.Track(t) end
                end,
            })
            Log("ShadowBoss - aftershock giant tentacle rises (phase " .. phase .. ")")
        end, after * 1000)
    end
end


-- =======================================================================
-- Force combat on the first hit. CheckForStagger staggers on any hit while !CombatState with no
-- stamina check, so an unperceived attacker (invisibility) burrows the boss on every landing hit.
-- ForceAggro flips CombatState + target so hits from then on follow the stamina rule. Deferred:
-- the hit's own stagger has already happened by the time this lands, and ForceAggro should never
-- run from inside the damage frame.
-- This hook alone proved unreliable in practice (fires unconfirmed); the boss WATCH POLL is the
-- enforcement that actually counts. This stays as the fast path, with proof-of-fire logging.
-- =======================================================================
local lastForceTick = 0
local hitHookProof = 0   -- first few fires logged per session (diagnosis, cheap)

local function onBossHit(boss, instigator)
    if hitHookProof < 3 then
        hitHookProof = hitHookProof + 1
        LogDebug("ShadowBoss - ReceivePointDamage hook fired (" .. hitHookProof .. "/3 proof)", DBG)
    end
    if CFG.ForceCombatOnHit == false then return end
    if STATE.FAST_TICK - lastForceTick < 10 then return end   -- one attempt per second is plenty
    local inCombat = true
    pcall(function() inCombat = boss.CombatState == true end)
    if inCombat then return end
    local pawn
    pcall(function() pawn = instigator:K2_GetPawn() end)
    if Utils.IsActorInvalid(pawn) then return end
    lastForceTick = STATE.FAST_TICK
    Utils.QueueWork(function()
        if not STATE.ModEnabled then return end
        local b = SB.Boss()
        if not b or Utils.IsActorInvalid(pawn) then return end
        AVU.ForceAggro(b, pawn)
        LogDebug("ShadowBoss - forced into combat on hit (attacker unseen)", DBG)
    end, 0)
end


-- Boss-CLASS hooks: the class only resolves once a boss has spawned, so these arm from the first
-- ApplyPhaseStatsToBoss (which runs right after SpawnBoss). Per-process, like the director hooks.
local bossHooksArmed = false

local function armBossHooks()
    if bossHooksArmed then return end
    local ok, err = pcall(function()
        RegisterHook(HOOK_TENTACLES, function(self)
            if not STATE.ModEnabled then return end
            local boss = self:get()
            Utils.QueueWork(function() onSpawnTentacles(boss) end, 0)   -- runs after the body anyway
        end)
        RegisterHook(HOOK_BOSS_HIT, function(self, Damage, DamageType, HitLocation, HitNormal,
                                             HitComponent, BoneName, ShotFromDirection, InstigatedBy)
            if not STATE.ModEnabled then return end
            local boss = self:get()
            local inst = InstigatedBy and InstigatedBy:get()
            if inst == nil or Utils.IsActorInvalid(boss) then return end   -- first-sight null (memory)
            onBossHit(boss, inst)
        end)
    end)
    if ok then
        bossHooksArmed = true
        Log("ShadowBoss - boss class hooks armed")
    else
        LogBad("ShadowBoss - boss class hooks FAILED: " .. tostring(err))
    end
end


-- =======================================================================
-- Storm ownership
-- =======================================================================

-- Our extras register here so the end-of-storm check waits on them too. During a storm the spawn
-- also joins the director's own SpawnedAssaultNPCs, the array the native <=3-alive end counts -
-- without that, the native end can race ahead of our disarm poll and close the storm mid-script
-- while our own content is still alive. pcall'd: an append failure just falls back to the disarm.
function SB.Track(npc)
    if Utils.IsActorInvalid(npc) then return end
    local key = Utils.ActorKey(npc)
    if key then trackedNpcs[key] = npc end
    if stormState and not stormState.ended then
        local d = findDirector()
        if d then
            local ok = pcall(function()
                local arr = d.SpawnedAssaultNPCs
                arr[#arr + 1] = npc
            end)
            if not ok then LogDebug("SB.Track - assault-array append failed", DBG) end
        end
    end
end

-- Every enemy the storm is waiting on: the director's own adds + ours. Prunes dead/invalid.
local function liveStormEnemies()
    local out = {}
    local d = findDirector()
    if d then
        pcall(function()
            local arr = d.SpawnedAssaultNPCs
            for i = 1, #arr do
                local n = arr[i]
                if Utils.IsActorValid(n) and not Utils.IsDeadSafe(n) then out[#out + 1] = n end
            end
        end)
    end
    for key, n in pairs(trackedNpcs) do
        if Utils.IsActorInvalid(n) or Utils.IsDeadSafe(n) then
            trackedNpcs[key] = nil
        else
            out[#out + 1] = n
        end
    end
    return out
end

-- Disarm the native "<=3 alive" end once the game has finished spawning its adds. The check is
--   TotalSpawnedCount >= MaxNPCSpawnCount AND alive <= 3 - so zeroing the counter after the
--   spawn timer has self-cleared (it clears itself at the cap) makes the first half never true
--   again, without touching the wave timer or the roster.
local function disarmNativeEnd(d)
    if not stormState or stormState.nativeDisarmed then return end
    local total, cap = 0, 10
    pcall(function()
        total = tonumber(d.TotalSpawnedCount) or 0
        cap = tonumber(d.MaxNPCSpawnCount) or 10
    end)
    if total < cap then return end
    pcall(function() d.TotalSpawnedCount = 0 end)
    stormState.nativeDisarmed = true
    LogDebug("ShadowBoss - storm: native adds all out; native end disarmed", DBG)
end

-- Per-storm scalar-or-array knob read (StormMin/MaxSeconds accept both shapes).
local function stormKnob(v, phase, fallback)
    if type(v) == "table" then return v[phase] or fallback end
    return v or fallback
end

-- Nudge far-away enemies toward a random player. Wander-toward, not aggro. An enemy still far
-- after COAX_TP_AFTER nudges is presumed STUCK (bad nav, a hole, a ledge) and gets teleported to
-- a nav point near a random player instead - safe in-drain for an NPC (S2); lift to capsule
-- height or it sinks in. Counts live in stormState; enemies can appear twice in the source list
-- (director array + our tracked book), so a per-pulse `seen` dedupes both order and count.
local COAX_TP_AFTER = 3
local COAX_TP_LIFT = 90

local function coaxPulse(enemies)
    if (CFG.CoaxSeconds or 0) <= 0 then return end
    local players = Utils.LivePlayers()
    if #players == 0 then return end
    local counts = stormState and stormState.coaxCounts
    local nudged, seen, names = 0, {}, {}
    for _, npc in ipairs(enemies) do
        local key = Utils.ActorKey(npc)
        local loc; pcall(function() loc = npc:K2_GetActorLocation() end)
        if loc and key and not seen[key] then
            seen[key] = true
            local farFromAll = true
            for _, p in ipairs(players) do
                local pl; pcall(function() pl = p:K2_GetActorLocation() end)
                if pl and Utils.DistSq(loc, pl) < COAX_FAR_SQ then farFromAll = false break end
            end
            if farFromAll then
                local target = players[math.random(1, #players)]
                local tl; pcall(function() tl = target:K2_GetActorLocation() end)
                local dest = tl and Utils.GetSpawnPoint(tl, COAX_NEAR)
                if dest then
                    local n = (counts and (counts[key] or 0) or 0) + 1
                    if counts then counts[key] = n end
                    if n > COAX_TP_AFTER then
                        -- Enough walking orders - port the straggler into the fight.
                        if counts then counts[key] = 0 end
                        pcall(function()
                            local rot = npc:K2_GetActorRotation()
                            npc:K2_SetActorLocationAndRotation(
                                FVector(dest.X, dest.Y, dest.Z + COAX_TP_LIFT), rot, false, {}, true)
                        end)
                        LogDebug("ShadowBoss - coax: teleported stuck "
                            .. tostring(Utils.GetActorName(npc)) .. " to the fight", DBG)
                    elseif AVU.MoveOrder(npc, dest) then
                        nudged = nudged + 1
                        if nudged <= 3 then names[#names + 1] = tostring(Utils.GetActorName(npc)) end
                    end
                end
            elseif counts and counts[key] then
                counts[key] = nil   -- it made it near someone; a later stall starts fresh
            end
        end
    end
    if nudged > 0 then
        LogDebug("ShadowBoss - coax: nudged " .. nudged .. " far enemies ("
            .. table.concat(names, ", ") .. (nudged > #names and ", ..." or "") .. ")", DBG)
    end
end

-- End the storm through the game's own path. EndPortalStorm -> StartNextPhase -> SpawnBoss is a
-- REAL SPAWN (§2): preload the boss class first, then hop it fully off-hook.
local function endStorm(reason)
    if not stormState or stormState.ended then return end
    stormState.ended = true
    Log("ShadowBoss - ending storm " .. tostring(stormState.phase) .. " (" .. reason .. ")")

    ASSETS.LoadAsync({ BOSS_CLASS }, function()
        local d = findDirector()
        if not d then return end
        pcall(function() d.PortalStormActive = false end)   -- what the native check writes first
        Utils.DelayedGameThread(OFFHOOK_HOP_MS, function()
            local d2 = findDirector()
            if d2 then pcall(function() d2:EndPortalStorm() end) end
        end)
    end)
end

local function stormPoll()
    pollActive = false
    if not STATE.ModEnabled or not stormState or stormState.ended then return end
    local d = findDirector()
    if not d then return end

    -- The game ended it underneath us (shouldn't - we disarm both native ends - but be safe)
    if not SB.StormActive() then
        LogDebug("ShadowBoss - storm ended natively", DBG)
        stormState = nil
        return
    end

    local elapsed = (STATE.FAST_TICK - stormState.startTick) / 10   -- FAST_TICK = 0.1s
    disarmNativeEnd(d)
    local enemies = liveStormEnemies()

    local minS = stormKnob(CFG.StormMinSeconds, stormState.phase, 90)
    local maxS = stormKnob(CFG.StormMaxSeconds, stormState.phase, 180)
    if elapsed >= maxS then
        endStorm(string.format("max %ds, %d still alive", maxS, #enemies))
        return
    end
    if elapsed >= minS and #enemies <= (CFG.StormEndLeftover or 0) and stormState.nativeDisarmed then
        -- Never cut a storm whose SCRIPT is still mid-flight (drip spawns remaining, a rift
        -- still on the schedule) - the all-dead end only counts bodies, not intent.
        local pending = false
        if SB.OnStormContentPending then
            local ok, p = pcall(SB.OnStormContentPending, elapsed)
            pending = ok and p == true
        end
        if not pending then
            endStorm(#enemies == 0 and string.format("all enemies dead at %.0fs", elapsed)
                or string.format("%d leftover(s) at %.0fs", #enemies, elapsed))
            return
        end
    end

    if (CFG.CoaxSeconds or 0) > 0
        and STATE.FAST_TICK - (stormState.coaxTick or 0) >= CFG.CoaxSeconds * 10 then
        stormState.coaxTick = STATE.FAST_TICK
        coaxPulse(enemies)
    end

    -- STRAGGLER HUNT: late in the storm with only a handful left, outline the survivors through
    -- walls on every machine so the wedged/lost ones can be found. Re-sent every poll beat
    -- (1s) with a life just past it, so it reads as a steady outline, not a strobe. Each send is
    -- one chat-RPC per player; at <=5 bodies that is nothing.
    local huntAfter = stormKnob(CFG.HuntAfterSeconds, stormState.phase, 0)
    if huntAfter > 0 and elapsed >= huntAfter and #enemies > 0
        and #enemies <= (CFG.HuntMaxAlive or 5) then
        if not stormState.hunting then
            stormState.hunting = true
            Log(string.format("ShadowBoss - storm %d: %d straggler(s) at %.0fs - outlining",
                stormState.phase, #enemies, elapsed))
        end
        for _, npc in ipairs(enemies) do AVU.OutlineNpcAll(npc, 2) end
    end

    pollActive = true
    Utils.QueueWork(stormPoll, POLL_MS)
end

local function onStormStarted()
    local d = findDirector()
    if not d then return end
    -- The boss is dead; stop any boss-phase content (idempotent - OnBossDeath got it too).
    if SB.OnBossContentEnd then pcall(SB.OnBossContentEnd, "storm") end
    local phase = SB.Phase()
    stormState = { startTick = STATE.FAST_TICK, phase = phase, nativeDisarmed = false,
                   coaxTick = STATE.FAST_TICK, ended = false,
                   coaxCounts = {} }   -- ActorKey -> failed-nudge count (the straggler-teleport escalation)
    pcall(function() d.MaxPortalStormTime = NEVER_SECONDS end)
    Log(string.format("ShadowBoss - Storm %d started (min %ds / max %ds)", phase,
        stormKnob(CFG.StormMinSeconds, phase, 90), stormKnob(CFG.StormMaxSeconds, phase, 180)))
    if not pollActive then
        pollActive = true
        Utils.QueueWork(stormPoll, POLL_MS)
    end
    -- Storm content (extra spawns, rifts) plugs in here per phase - see AnNotes/Modules/ShadowBoss.md.
    if SB.OnStormContent then pcall(SB.OnStormContent, phase) end
end

local function onStormEnded()
    LogDebug("ShadowBoss - EndPortalStorm fired (phase now " .. SB.Phase() .. ")", DBG)
    stormState = nil
    trackedNpcs = {}
    if SB.OnStormEnd then pcall(SB.OnStormEnd) end
end


-- =======================================================================
-- Hooks (per-process; the director class resolves once V_ISLAND is loaded)
-- =======================================================================
local function armHooks()
    if hooksArmed then return true end
    local ok = pcall(function()
        RegisterHook(HOOK_PHASE_STATS, function(self)
            if not STATE.ModEnabled then return end
            local d = self:get()
            Utils.QueueWork(function()
                if Utils.IsActorInvalid(d) then return end
                director = d
                local phase = SB.Phase()
                Log("ShadowBoss - BossPhase " .. phase .. " boss spawned")
                armBossHooks()   -- the boss class is resident now (SpawnBoss just ran)
                applyBossKnobs(SB.Boss(), phase)
            end, 0)
        end)
        RegisterHook(HOOK_STORM_START, function(self)
            if not STATE.ModEnabled then return end
            local d = self:get()
            Utils.QueueWork(function()
                if Utils.IsActorInvalid(d) then return end
                director = d
                onStormStarted()
            end, 0)
        end)
        RegisterHook(HOOK_STORM_END, function(self)
            if not STATE.ModEnabled then return end
            Utils.QueueWork(onStormEnded, 0)
        end)
        RegisterHook(HOOK_BOSS_DEATH, function(self)
            if not STATE.ModEnabled then return end
            Utils.QueueWork(function()
                local phase = SB.Phase()
                Log("ShadowBoss - boss died (phase " .. phase .. ")")
                -- "bossdeath" + phase: a phase-3 death is the VICTORY - storm content runs its
                -- gate teardown + leftover-enemy dismissal off this.
                if SB.OnBossContentEnd then pcall(SB.OnBossContentEnd, "bossdeath", phase) end
            end, 0)
        end)
    end)
    if ok then
        hooksArmed = true
        Log("ShadowBoss - director hooks armed")
    else
        LogDebug("ShadowBoss - director class not loaded yet; hooks deferred", DBG)
    end
    return ok
end

local function adoptDirector(d)
    if Utils.IsActorInvalid(d) then return end
    local fn; pcall(function() fn = d:GetFullName() end)
    if not fn or fn:find("Default__") then return end
    director = d
    armHooks()
    Log("ShadowBoss - director adopted (phase " .. SB.Phase() .. ", fight "
        .. tostring(select(2, pcall(function() return d.BossFightActive end))) .. ")")
end


-- =======================================================================
-- Dev commands (/au-boss ...) - all AUTHORITY, all off-hook. The level BP's own debug events:
--   DebugStartBossFight - lights the rune (= player activation) -> BossPhase 1
--   DebugNextBossPhase  - ends the current storm if one is running, else advances the phase
--     (kills nothing: with a boss alive it spawns the NEXT phase boss on top - use "end" first)
-- =======================================================================
local function levelBP()
    for _, lvl in ipairs(FindAllOf(ISLAND_LEVEL) or {}) do
        local fn; pcall(function() fn = lvl:GetFullName() end)
        if fn and not fn:find("Default__") then return lvl end
    end
    return nil
end

function SB.Command(rest)
    if not Utils.IsAuthority() then return end
    local sub = (rest or ""):match("^%s*(%S*)")
    if sub == "" then sub = "status" end
    Utils.QueueWork(function()
        local d = findDirector()
        if sub == "status" then
            if not d then Log("ShadowBoss - no director (not on the island?)") return end
            local boss = SB.Boss()
            local hp = "-"
            if boss then
                pcall(function() hp = string.format("%.0f/%.0f torso, %.0f head",
                    boss:GetLimbHealth(4), boss:GetMaxLimbHealth(4), boss:GetLimbHealth(3)) end)
            end
            Log(string.format("ShadowBoss - phase %d, storm %s, boss %s, tracked extras %d%s",
                SB.Phase(), tostring(SB.StormActive()), hp,
                (function() local c = 0 for _ in pairs(trackedNpcs) do c = c + 1 end return c end)(),
                stormState and string.format(", storm t=%.0fs", (STATE.FAST_TICK - stormState.startTick) / 10) or ""))
        elseif sub == "start" then
            local lvl = levelBP()
            if not lvl then Log("ShadowBoss - level BP not found") return end
            ASSETS.LoadAsync({ BOSS_CLASS }, function()
                Utils.DelayedGameThread(OFFHOOK_HOP_MS, function()
                    local l = levelBP()
                    if l then pcall(function() l:DebugStartBossFight() end) end
                end)
            end)
        elseif sub == "next" then
            local lvl = levelBP()
            if not lvl then Log("ShadowBoss - level BP not found") return end
            if stormState then stormState.ended = true end   -- our poll steps aside
            ASSETS.LoadAsync({ BOSS_CLASS }, function()
                Utils.DelayedGameThread(OFFHOOK_HOP_MS, function()
                    local l = levelBP()
                    if l then pcall(function() l:DebugNextBossPhase() end) end
                end)
            end)
        elseif sub == "end" then
            -- Kill the live boss the way the level BP's cinematic-skip does (IsDead + OnRep):
            -- fires DeadAlive_Changed -> director OnBossDeath -> storm / victory.
            if not SB.Boss() then Log("ShadowBoss - no live boss") return end
            Utils.DelayedGameThread(OFFHOOK_HOP_MS, function()
                local boss = SB.Boss()   -- re-resolve across the hop; never a captured wrapper
                if not boss then return end
                pcall(function()
                    boss:FlushNetDormancy()
                    boss.IsDead = true
                    Utils.MarkReplicatedDirty(boss, "IsDead")
                    boss:OnRep_IsDead()
                end)
            end)
        else
            Log("ShadowBoss - usage: /au-boss [status|start|next|end]")
        end
    end, 0)
end


-- =======================================================================
-- Register - authority only, once per world (main.lua calls it every world load)
-- =======================================================================
function SB.Register()
    if not ENABLED then return end
    if not Utils.IsAuthority() then return end
    if STATE.ShadowBossArmed then return end
    STATE.ShadowBossArmed = true

    -- Storm content wires its seams onto SB when required. Required HERE, not at the top of this
    -- file: ShadowStorms requires ShadowBoss back, and a top-level pair is a require cycle.
    pcall(require, "ModuleShadow.ShadowStorms")

    -- Already on the island (a /reload, or the level was up before the mod)?
    for _, d in ipairs(FindAllOf(DIRECTOR_SHORT) or {}) do pcall(adoptDirector, d) end

    if not notifyArmed then
        notifyArmed = true
        NotifyOnNewObject(DIRECTOR_CLASS, function(d)
            Utils.QueueWork(function() adoptDirector(d) end, 0)   -- never touch actors IN the notify
        end)
        -- Every hand slam spawns one of these; the callback separates native from echo hands
        -- (see the echo section) and never touches actors in the notify.
        NotifyOnNewObject(HAND_CLASS, SB._onHandSpawned)
    end
    Log("ShadowBoss module registered")
end

return SB
