-- =======================================================================
-- GK_DarkLensJotunHelpers - machinery for the DarkLens HEAVY boss set (defs in GK_DarkLens.lua):
-- "Jotun of the Fallow" + the "Fallow Steed" it rides. The parts every DarkLens boss shares -
-- adoption watcher, death-flag backstop, reset respawn, arena guard - live in
-- AnteNPCs/GK_DarkLensHelpers (required here as DL); this file is the fight itself.
-- Full decode/reasoning: AnNotes/AnteNPCs/GKDarkLensJotun.md
--
-- MUST-KNOWS (implementation):
--   * THE BOSS BODY IS SACRED - only the real DarkLens_Heavy dying sets WorldFlag
--     Fracture_DL_Heavy_Dead. The steed and every portalled Artillery Bot get DamageToNPCs = 0 so
--     neither can land the killing blow; JotunDeath backstops the flag anyway.
--   * THE MOUNT IS WELDED THE OTHER WAY ROUND from the Jotun Rider (mount mutated, spawns rider) -
--     here the BOSS spawns the mount and welds itself on via AVU.MountRider (doesn't tie the
--     passenger's lifetime to the carrier). Outliving the mount IS phase 2.
--   * PHASE 1 BARRIER = unbreakable body shield + Invincible belt, never Invincible alone (zeroed
--     hits still run flinch/stagger/break FX). Lit the whole fight so "kill the mount" reads before
--     the first magazine. Killing the steed permabreaks it.
--   * PHASE 2 PERSISTS ACROSS A RELOG via `STATE.StoryData.FallowJotunDismounted` (FileIO), read in
--     JotunStats - without it, leaving and re-entering the Fracture hands the boss a fresh mount.
--   * THE PIN COSTS THE BT ITS TurnToFaceTarget, and the LMG aims at a LOCATION regardless of body
--     yaw - facing and firing arc are scripted by hand (GK_HeavyHelpers, GKH.*: one copy of every
--     lesson the Jotun Rider paid for).
--   * OUR FIRE GATE MUST BE RELEASED BY US. GKH.GateRiderFire shuts the BT's branch; only a NATIVE
--     fire re-arms it, so dismount must explicitly re-open both or the phase-2 boss never shoots.
--   * THE MORTAR RIDES THE RELOAD CADENCE (two shells per native reload) - a smaller clip means
--     more reloads means more mortars, so JOTUN_AMMO is the real knob, not a mortar cooldown.
--   * THE LOOK IS PER MATERIAL SLOT, ALL ON THE MERGED BODY MESH (Grunt family merges Mesh/Head/
--     Legs/ClassGear at BeginPlay) - jotunWhiteKit paints named slots one at a time; AVU.TintMesh
--     would spray every slot and erase the two-tone look.
--   * THE FRONT HARDLIGHT SHIELD is native (Grunt_FireBurst/ShieldActive) and blocks 100% of hits
--     on it via a geometry check. Phase 1 neuters it (JOTUN_FRONT_SHIELD_P1) so shots meant for the
--     mount aren't eaten; it is NOT what slows the steed (Pawn -> Ignore, no nav).
--   * THE PHASE-2 TRANSITION IS A SCAN STORM ON TOP OF A TEARDOWN - took an AV to learn
--     ([[anteup2-ue4ss-findobject-scan-crash]]). Fix: pay scans early (JotunReady pins), don't spawn
--     into the teardown (ART_FIRST_DELAY_MS), pin anything that fires at the transition.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local FileIO = require("AnteCore.FileIO")
local ASSETS = require("AnteCore.AssetManager")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local DL = require("AnteNPCs.GK_DarkLensHelpers")     -- watcher / flag backstop / respawn / guard
local GKH = require("AnteNPCs.GK_HeavyHelpers")       -- the welded-turret upkeep, one copy
local LogDebug = Utils.LogDebug

local H = {}

-- =======================================================================
-- Knobs - arena
-- =======================================================================

-- Jotun spawn point. Slightly pushed forward of its natural spawner to make room for the Peccary
local JOTUN_HOME = FVector(-39390, 79490, 2500)

-- Centroid of the home + the two artillery posts. The arena is an S with jump pads at each end, so
-- it reads as quasi-circular around this: wide-ish radii, and the guard errs VULNERABLE.
local ARENA_CENTER      = FVector(-38903, 80125, 2380)
local ARENA_SCAN_RADIUS = 4000    -- class overlap for the boss body

local CFG = {
    StateKey     = "DarkLensJotunArmed",
    Label        = "DarkLens Jotun",
    Boss         = "Jotun",
    Flag         = "Fracture_DL_Heavy_Dead",
    ClassKey     = "DarkLens_Heavy",
    Variant      = "Jotun of the Fallow",
    Center       = ARENA_CENTER,
    Area         = DL.ARENAS.Jotun,   -- see the ARENA knob below (same table)
    ScanRadius   = ARENA_SCAN_RADIUS,
    WakeSq       = 8000 * 8000,   -- a player this close to ARENA_CENTER wakes the watcher's real work
    AggroSq      = 3000 * 3000,   -- a player this close to the BOSS -> ForceAggro (the AISense fix)
    WatchMs      = 3000,
    SpawnerClass = "NPCSpawn_Gatekeeper_DARKLENS_Heavy_C",
    Home         = JOTUN_HOME,
    GuardRange   = 6000,   -- 60m; the default 30m is sized for the Chieftain/Witch's tighter arenas
}

-- =======================================================================
-- Knobs - the Jotun (boss)
-- =======================================================================

-- Ammo and reload time. Shoots ~10 times per second fully spun up
local JOTUN_AMMO       = 30     -- 50
local JOTUN_RELOAD_CAP_TICKS = 90   -- failsafe if a stagger eats the refill signal (9s)
local JOTUN_MORTAR_DMG = 150

-- CustomTimeDilation per phase, plus the reload speed-up layered on top of the phase baseline.
local JOTUN_TDI = { Mounted = 1.0, OnFoot = 1.1, ReloadMult = 1.3 }

-- Phase 2 Jotun speed
local JOTUN_P2_SPEED = 450

-- Phase 1 -> 2 idle-stun (AVU.HoldStill, re-asserted on a beat - native paths set/clear
-- LockedInPlaceMontage themselves).
local JOTUN_IDLE = { Ms = 3000, HoldMs = 500 }

-- Weld geometry. Spine1 is the peccary's mid-back, in that rig's bone space (-X up, -Y forward).
-- The arc/yaw are wider than the Jotun Rider's 120/45 because this mount is a slow bruiser that
-- spends the fight facing its target anyway.
local SEAT_BONE   = "Spine1"
local SEAT_LOC    = FVector(-15, -36, 0)
local SEAT_ARC    = 150   -- fire only within this many degrees of the mount's facing
local SEAT_MAX_YAW = 60   -- Jotun: max turning radius (so it doesn't turn 180 while mounted)
local SEAT_SCALE  = FVector(0.87, 0.87, 0.87)

-- Phase 1 Jotun shield - tinted, invulnerable
local BARRIER_SHIELD_HP = 99999
local BARRIER_COLOR     = FVector(0.2, 0.2, 3)    -- blue; the GK shield material is dark, so >1
local BARRIER_CHANNELS  = { Red = 0.3, Green = 0.6, Blue = 2 }

local BARRIER_GLOW_MIN  = 10000  -- shield above this HP reads as the barrier (not a native shield)
-- Native shield/regen, restored by /dlreset jotun
local JOTUN_SHIELD = { Hp = 300, Regen = 10 }

-- Front hardlight shield: OFF in phase 1 (it blocks damage meant for the mount via a geometry
-- check, not a bool fight - see AnNotes/AnteNPCs/GKDarkLensJotun.md for why/how). Phase 2 gets it back.
local JOTUN_FRONT_SHIELD_P1 = false
-- The class default, from that same SCS. Only used if the live profile name can't be read back.
local JOTUN_SHIELD_PROFILE = "CharacterMesh"

-- Appearance
local LOOK_JOTUN = {
    Plate   = FVector(1, 1, 1.5),   -- armour, lifted just off the texture
    Trim    = FVector(0.2, 0.3, 1),   -- torso accessories + the leg fabric
    Visor   = FVector(0, 2, 4),   -- helmet emissive (the white MI ships PURPLE - overridden)
    VisorEm = 3,
}

local PIN_TICKS   = 10   -- pin + weld re-assert cadence
local AIM_TICKS   = 2    -- scripted facing + arc gate cadence (0.2s, the aimRider number)
local MOUNT_CHECK_TICKS = 30   -- "am I still on a steed" backstop (3s)
local REMOUNT_CD_TICKS  = 100  -- min gap between re-mount attempts

-- =======================================================================
-- Knobs - phase-2 artillery
-- =======================================================================

-- Two fixed posts. Re-checked on every phase-2 entry (including a re-mutation after a relog), so a
-- cleared post is refilled next visit - but never DURING a fight, which would be endless adds.
local ART_SPOTS = {
    FVector(-37740, 80640, 2380),
    FVector(-39580, 80140, 2380),
}
local ART_VARIANT      = "Artillery Bot"
local ART_CLEAR_RADIUS = 900    -- "one is already there" (the posts are ~19m apart)
local ART_STAGGER_MS   = 900
-- How long phase 2 waits before looks at the spawn posts. 
--   * Crash gap - gate in-by-name are UObject array walks that AV on half-destroyed objects
local ART_FIRST_DELAY_MS = 2500

-- Pinned in boss phase1 so phase2 doesn't scan
local PHASE2_PINS = {
    ENUMS.NpcClasses["Robot_Defense"],
    "/Game/Blueprints/Projectiles/Projectile_Grenade_ParentBP.Projectile_Grenade_ParentBP_C",
    "/Game/Blueprints/Projectiles/AbioticProjectile_ParentBP.AbioticProjectile_ParentBP_C",
    ENUMS.SOUNDS.GKHEAVY_GRENADE_03,
}
-- "Is this boss actually standing in the Fracture arena?"
local ARENA = DL.ARENAS.Jotun

-- =======================================================================
-- Knobs - the steed
-- =======================================================================

local VAR_STEED = "Fallow Steed"

-- Spawn the mount behind the boss:
--   * Avoid overlapping character capsules - this caused one to move forward 20m
--   * Weld happens right after
local MOUNT_SPAWN_BACK   = 250
local MOUNT_ADOPT_RADIUS = 3000   -- re-use a steed already standing here rather than stacking one

local STEED_MELEE_RATE   = 1.5    -- MeleeAttackPlayRate (replicates)
local STEED_MELEE_OFFSET = 0.2    -- NPC_Monster_Peccary's GetMeleeTimeOffset
local STEED_MELEE_LEN    = 1.2    -- fallback if montage can't be measured
local STEED_RELEASE_PAD  = 2      -- ticks of slack on the scripted release

-- Mount shield doesn't regen
local STEED_SHIELD = { Hp = 500, Regen = 0 }

local STEED_YAW_RATE     = 200    -- slow turner
local STEED_ACCELERATION = 600    -- 1024

local STEED_ABILITY_CARBUNCLE = 0   -- idle plant; the charge (1) is already EMPTY on Peccary_Armored

-- =======================================================================
-- Per-actor state (module-local; /reload clears with the defs)
-- =======================================================================

local jotunPhase2On    = {}   -- bossKey -> true once dismounted (runtime mirror of the StoryData flag)
local jotunMountState  = {}   -- bossKey -> { mount = wrapper, mountKey } (the ONE link record)
local jotunByMount     = {}   -- mountKey -> bossKey
local lastRemountTick  = {}   -- bossKey -> FAST_TICK of the last re-mount attempt (CooldownReady)
local lastSteedSwingTick = {} -- steedKey -> FAST_TICK of its last melee swing (hook -> ActorKey)
local steedSwingState  = {}   -- steedKey -> { releasedFor } (which swing we already released)
local jotunIdleGen     = {}   -- bossKey -> generation of the running dismount hold (stale = stop)
local jotunShieldProfile = {} -- bossKey -> the front shield's own collision profile while neutered
-- (the cached boss wrapper lives in CFG._ref, owned by the shared layer - DL.Boss/SetBoss/Forget)


-- =======================================================================
-- REGISTRATION - the shared arena watcher
-- =======================================================================

-- Armed from main.lua each world load. Adoption + the out-of-combat aggro check are shared with the
-- other two DarkLens fights; CFG is this one's half of it.
function H.Register()
    DL.ArmWatcher(CFG)
end


-- =======================================================================
-- PERSISTENCE - "the steed is already dead in this save"
-- =======================================================================

-- A boss that has already been dismounted must come back dismounted: its body persists (300km
-- DespawnDistance) but our module state does not, so a relog would otherwise re-mutate it into a
-- shielded, freshly-mounted phase 1.
local function phase2Persisted()
    return (STATE.StoryData or {}).FallowJotunDismounted == true
end


local function setPhase2Persisted(on)
    STATE.StoryData = STATE.StoryData or {}
    if STATE.StoryData.FallowJotunDismounted == on then return end
    STATE.StoryData.FallowJotunDismounted = on
    FileIO.SaveStoryData()
end


-- =======================================================================
-- JOTUN + STEED - private machinery
-- Shared helpers the H.* entry points below build on: dilation baseline, barrier pool, kit paint,
-- mounting/dismounting, phase-2 artillery. Defined here, ahead of every entry point that calls them.
-- =======================================================================

-- The phase's baseline CustomTimeDilation. Everything else that touches dilation (the reload
-- boost, and its restore) is expressed relative to THIS, so there is one place to change how fast
-- the boss runs in a phase.
local function baseTdi(key)
    if key and jotunPhase2On[key] then return JOTUN_TDI.OnFoot end
    return JOTUN_TDI.Mounted
end


-- Unbreakable pool + the Invincible belt. At 99999 nothing chews through it, so there is no top-up
-- loop; the belt catches shield-PIERCING types (Psychic_Holy bypasses body shields outright).
local function barrierUp(actor)
    AVU.SetBodyShield(actor, { Max = BARRIER_SHIELD_HP, Current = BARRIER_SHIELD_HP,
        Regen = 0, RegenTime = 1, RegenTimeZero = 1 })
    pcall(function() actor.Invincible = true end)
end


-- Permabreak: phase 2 is bare body for good. MAX 0 is what matters, not Current (the Gatekeeper
-- permabreak rule) - Regen/RegenTime here are just tidiness.
local function barrierPermabreak(actor)
    AVU.SetBodyShield(actor, { Max = 0, Current = 0, Regen = 0,
        RegenTime = 99999, RegenTimeZero = 99999 })
end


-- Paint ONE kit slot by NAME, on whichever component actually owns it. NOT `actor.Head` - the
-- Grunt family merges Head/Legs/ClassGear into `Mesh` at BeginPlay, so the modular components are
-- emptied and their old slots survive only as named slots on `Mesh` (see AnNotes). Mesh is tried
-- first, the standalone component second (covers a build that skips the merge); always by NAME,
-- never index - the merged slot order is whatever the merge produced.
local function kitSlot(actor, name, comp, opts)
    local mesh = Utils.GetValidMesh(actor)
    if mesh and AVU.MaterialSlot(mesh, name) ~= nil then
        AVU.TintSlot(mesh, name, opts)
        return
    end
    if IsValid(comp) and AVU.MaterialSlot(comp, name) ~= nil then
        AVU.TintSlot(comp, name, opts)
        return
    end
    Utils.LogBad("Jotun kit - no material slot '" .. tostring(name)
        .. "' on the merged body mesh or its own component (run /dumpmat on the boss)")
end


-- [RENDERER] The white kit + red trim (see LOOK_JOTUN). One AVU.TintSlot per material slot across
-- the three body components the Grunt family splits itself into - `Mesh` is only the TORSO here,
-- which is why a TintMesh on this base leaves the helmet and legs their stock colour.
--   * The materials must be RESIDENT (the def's Assets list); a cold one logs and skips the swap,
--     leaving the tint to land on the stock material - ugly, never a crash.
local function jotunWhiteKit(actor)
    -- The modular components, ONLY as the fallback owner of their slot - see kitSlot.
    local head, legs
    pcall(function() head = actor.Head end)
    pcall(function() legs = actor.Legs end)

    kitSlot(actor, "M_GKHeavyTorso", nil, {
        Material = ENUMS.Components.M_GKHEAVY_TORSO_WHITE,
        Texture = ENUMS.Components.T_GKHEAVY_TORSO_WHITE,
        Color = LOOK_JOTUN.Plate,
    })
    kitSlot(actor, "M_GKHeavyAccessories", nil, { Color = LOOK_JOTUN.Trim })
    kitSlot(actor, "M_GKHeavyHelmet", head, {
        Material = ENUMS.Components.M_GKHEAVY_HELMET_WHITE,
        Texture = ENUMS.Components.T_GKHEAVY_HELMET_WHITE,
        EmissiveTexture = ENUMS.Components.T_GKHEAVY_HELMET_EM_WHITE,
        Color = LOOK_JOTUN.Plate,
        Emissive = LOOK_JOTUN.VisorEm, EmissiveColor = LOOK_JOTUN.Visor,
    })
    kitSlot(actor, "M_GKHeavyLegs", legs, {
        Material = ENUMS.Components.M_GKHEAVY_LEGS_WHITE,
        Texture = ENUMS.Components.T_GKHEAVY_LEGS_WHITE,
        Color = LOOK_JOTUN.Plate,
    })
    kitSlot(actor, "M_GKHeavyFabric", legs, {
        Material = ENUMS.Components.M_GKHEAVY_FABRIC_WHITE,
        Texture = ENUMS.Components.T_GKHEAVY_FABRIC_WHITE,
        Color = LOOK_JOTUN.Trim,
    })

    -- ...and the health-stage flow would undo the TORSO half of all that on the first real hit:
    -- UpdateHealthTextureFromIndex writes HealthTextures[CurrentHealthTextureIndex] into the
    -- "Texture" param of Mesh slot 0, and the Heavy's array is two copies of the STOCK torso.
    -- Per-index writes only - a whole-array assign mangles the soft-ptrs into an AV.
    pcall(function()
        local tex = ASSETS.GetIfValid(ENUMS.Components.T_GKHEAVY_TORSO_WHITE)
        if IsNotValid(tex) then return end
        local ht = actor.HealthTextures
        if ht then for i = 1, #ht do ht[i] = tex end end
    end)
end


-- Make the hardlight FRONT shield stop blocking (`on` = false) or block again (`on` = true) - see
-- JOTUN_FRONT_SHIELD_P1 for the rationale. ONE write per phase: nothing native touches the collision
-- responses, so the neuter holds through every raise; the stashed profile name is both the "did we
-- do it" latch and the way back, cleared with the rest on world reset.
local function frontShield(boss, key, on)
    if JOTUN_FRONT_SHIELD_P1 or Utils.IsActorInvalid(boss) or not key then return end
    pcall(function()
        local sh = boss.Shield
        if IsNotValid(sh) then return end

        if on then
            local prof = jotunShieldProfile[key]
            if not prof then return end   -- never neutered (or already restored): leave it alone
            jotunShieldProfile[key] = nil
            sh:SetCollisionProfileName(FName(prof), true)
            LogDebug("Jotun - front shield restored (" .. prof .. ")", SETTINGS.DEBUG_NPC_ACTIONS)
            return
        end

        if jotunShieldProfile[key] then return end   -- already inert
        local prof
        pcall(function() prof = sh:GetCollisionProfileName():ToString() end)
        sh:SetCollisionResponseToAllChannels(0)   -- ECR_Ignore: blocks nothing, still renders
        -- Stashed AFTER the write, so a call that threw doesn't latch "inert" on a live shield.
        jotunShieldProfile[key] = prof or JOTUN_SHIELD_PROFILE
        LogDebug("Jotun - front shield neutered for phase 1", SETTINGS.DEBUG_NPC_ACTIONS)
    end)
end


-- Put the boss in the saddle: re-use a steed already standing in the arena, else spawn one.
--   * Adoption first, because a summoned NPC does NOT unload on a sublevel stream-out - after a
--     round trip the old body is still there, and spawning blind would stack a second one.
local function mountUp(boss)
    if Utils.IsActorInvalid(boss) or boss.IsDead then return end
    local key = Utils.ActorKey(boss)
    if not key or jotunPhase2On[key] then return end

    -- Already welded to a live steed? Nothing to do.
    local rec = jotunMountState[key]
    if rec and Utils.IsActorValid(rec.mount) and not Utils.IsDeadSafe(rec.mount) then return end
    if not AVU.CooldownReady(lastRemountTick, key, REMOUNT_CD_TICKS) then return end

    local bLoc
    pcall(function() bLoc = boss:K2_GetActorLocation() end)
    if not bLoc then return end

    local VT = require("AnteVariants.VariantTag")
    local V = require("AnteVariants.Variants")
    local steedId = V[VAR_STEED] and V[VAR_STEED].Id

    local hits = AVU.GetNearbyActorsOfClass(bLoc, MOUNT_ADOPT_RADIUS,
        ENUMS.NpcClasses["Peccary_Armored"])
    for i = 1, #hits do
        local m = hits[i]:get()
        if Utils.IsActorValid(m) and not Utils.IsDeadSafe(m) then
            local tag
            pcall(function() tag = VT.Decode(m) end)
            if tag == steedId then
                LogDebug("Jotun - adopting a steed already in the arena", SETTINGS.DEBUG_NPC_ACTIONS)
                H.WeldToSteed(boss, m)
                return
            end
        end
    end

    -- Spawn one BEHIND the boss (see MOUNT_SPAWN_BACK), then weld from its callback.
    local fwd
    pcall(function() fwd = boss:GetActorForwardVector() end)
    local at = FVector(bLoc.X - (fwd and fwd.X or 1) * MOUNT_SPAWN_BACK,
                       bLoc.Y - (fwd and fwd.Y or 0) * MOUNT_SPAWN_BACK, bLoc.Z)
    at = Utils.GetSpawnPoint(at, MOUNT_SPAWN_BACK) or at

    LogDebug("Jotun - summoning its steed", SETTINGS.DEBUG_NPC_ACTIONS)
    AVU.SummonVariant(VAR_STEED, at, { SkipSpawnFX = true }, function(m)
        H.WeldToSteed(boss, m)
    end)
end


-- Off the saddle and back to a walking NPC.
--   * THE FIRE GATE MUST BE RE-OPENED BY HAND. GateRiderFire may have left HasRangedAttack false
--     and RangedAttack_OnCooldown true, and the native clear is only ever re-armed by a native
--     fire - so a gate left shut here is a boss that never shoots again.
local function dismountBoss(boss, key)
    local rec = jotunMountState[key]
    AVU.DismountRider(boss, rec and rec.mount)
    GKH.ClearRiderGate(boss)

    -- PHASE 2 IS WHEN THIS BODY FINALLY WALKS, AND IT IS WEARING THE MOUNT'S SIZE. DismountRider
    -- detaches KeepWorld on purpose (a boss must not visibly shrink when it steps off), which bakes
    -- carrier * SEAT_SCALE into its own scale - so the capsule that was harmless while pinned in the
    -- saddle is now a 1.5x collision cylinder on a humanoid, and it has an arena to walk around.
    -- The def's NavRadius cannot cover this: that step runs at mutation, before it was ever welded.
    AVU.SetNavRadius(boss, AVU.NATIVE_NAV_RADIUS.Humanoid)

    pcall(function()
        local npcData = boss.NPCData
        if IsValid(npcData) then npcData[ENUMS.NpcData.HasRangedAttack] = true end
    end)
    pcall(function() boss.RangedAttack_OnCooldown = false end)

    if rec and rec.mountKey then jotunByMount[rec.mountKey] = nil end
    jotunMountState[key] = nil
end


-- Hold the boss still for JOTUN_IDLE.Ms. Re-asserted on a beat (native paths clear
-- LockedInPlaceMontage), generation-guarded so a second call supersedes the first, and released on
-- EVERY exit - a stuck hold is a boss that never moves again.
local function dismountIdle(boss, key)
    local gen = (jotunIdleGen[key] or 0) + 1
    jotunIdleGen[key] = gen

    local function hold(left)
        if jotunIdleGen[key] ~= gen then return end   -- superseded, or already released
        if Utils.IsActorInvalid(boss) or boss.IsDead then
            jotunIdleGen[key] = nil
            return
        end
        if left <= 0 then
            H.EndDismountIdle(boss)
            return
        end
        AVU.HoldStill(boss, true)
        Utils.QueueWork(function() hold(left - 1) end, JOTUN_IDLE.HoldMs)
    end

    AVU.HoldStill(boss, true)
    hold(math.max(1, math.ceil(JOTUN_IDLE.Ms / JOTUN_IDLE.HoldMs)))
end


-- Gate one in through the Gatekeeper rift. Both opts reach OnReady via the pipeline
-- (RobotDefenseHelpers.ArtilleryBunker), avoiding a near-duplicate def: NoBunker (this arena is
-- already full of hard cover) and ArtilleryProfile "Arena" (flat 6s cadence inside 30m, not the
-- placed bots' 10-25s battery curve - these are a boss-fight hazard, not a second artillery duel).
-- DamageToNPCs 0 for the same reason the steed carries it - no credited/aligned kill, no world flag.
local function portalArtillery(boss, spot)
    if Utils.IsActorInvalid(boss) or boss.IsDead then return end
    AVU.PortalSummon(spot, {
        { Variant = ART_VARIANT, Opts = { NoBunker = true, ArtilleryProfile = "Arena" } },
    }, {
        FactionFrom = boss,
        OnSpawned = function(npc)
            pcall(function() npc.DamageToNPCs = 0 end)
        end,
    })
    LogDebug(string.format("Jotun - artillery gated in at %.0f,%.0f", spot.X, spot.Y),
        SETTINGS.DEBUG_NPC_ACTIONS)
end


-- One Artillery Bot per spawn point. Checked on phase-2 entry and on every later re-entry.
local function artilleryCheck(boss)
    if Utils.IsActorInvalid(boss) or boss.IsDead then return end

    -- [Debug] Skip artillery bot spawn if we spawn the boss outside of its arena
    if not Utils.ActorInArea(boss, ARENA) then
        LogDebug("Jotun - phase 2 away from its arena, skipping the artillery posts",
            SETTINGS.DEBUG_NPC_ACTIONS)
        return
    end

    -- The PRESENCE SCAN is inside the delay too, not just the spawns: it resolves Robot_Defense by
    -- name and runs a sphere overlap, so leaving it here would keep the first walk in the teardown
    -- window that ART_FIRST_DELAY_MS exists to clear. Re-validate on the far side - 2.5s is long
    -- enough for the boss to die or its level to stream out.
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(boss) or boss.IsDead then return end

        local delay = 0
        for i = 1, #ART_SPOTS do
            local spot = ART_SPOTS[i]
            local present = #AVU.GetNearbyActorsOfClass(spot, ART_CLEAR_RADIUS,
                ENUMS.NpcClasses["Robot_Defense"])
            if present == 0 then
                Utils.QueueWork(function() portalArtillery(boss, spot) end, delay)
                delay = delay + ART_STAGGER_MS
            end
        end
    end, ART_FIRST_DELAY_MS)
end


-- =======================================================================
-- JOTUN - stats / visuals
-- =======================================================================

-- [AUTHORITY, Stats] Field writes + fail-safe resets. Runs on EVERY (re)mutation, so this is where
-- a save-restored boss picks its phase back up.
function H.JotunStats(actor, opts)
    local key = Utils.ActorKey(actor)
    local phase2 = phase2Persisted()
    if key then
        jotunPhase2On[key] = phase2 or nil
        lastRemountTick[key] = nil
    end

    -- Gun: native LMG kept (it IS the fight's suppression), just a short clip. The mortar rides the
    -- reload, so this is also the volley cadence - see MUST-KNOWS.
    pcall(function()
        actor.MaxAmmoCount = JOTUN_AMMO
        actor.CurrentAmmoCount = JOTUN_AMMO
    end)
    pcall(function() actor.MortarDamage = JOTUN_MORTAR_DMG end)

    -- Grenades OFF: the Heavy's is a CLUSTER grenade and it would carpet its own mount.
    AVU.DisableGrenades(actor)

    -- Can't be flinched, frozen, netted or knocked off its turn (debuff refusals + stagger).
    AVU.CCImmune(actor)

    -- A pinned body must not evade - the backstep montage on a frozen CMC reads as a teleporting
    -- statue - and the aggro montage's LENGTH is dead time before it will fight at all.
    pcall(function() actor.EvadesProjectiles = false end)
    AVU.SkipAggroAnim(actor)

    if phase2 then
        -- Bare body, on foot. Nothing here may assume the weld ever happened (this is also the
        -- path a /spawn'd test body takes once the flag is set).
        pcall(function() actor.Invincible = false end)
        barrierPermabreak(actor)
        AVU.SetMoveSpeed(actor, JOTUN_P2_SPEED, JOTUN_P2_SPEED)
    else
        barrierUp(actor)
    end
    -- Re-assert the phase's baseline speed-up on every (re)mutation - CustomTimeDilation is not
    -- saved, so a restored phase-2 body would otherwise come back at normal speed.
    AVU.SetTimeDilation(actor, baseTdi(key))
end


-- [RENDERER, Visuals] The barrier's colour, then the body. A barrier that is LIT AT ALL TIMES is
-- the "not while the steed lives" read (the Barrier Mage's), and the mount's own shell stays stock
-- so the pair can be told apart. All three colour slots + the per-channel intensities, or the
-- stock hue bleeds through.
function H.JotunVisuals(actor)
    -- Renderer half of stagger immunity (Stats' CCImmune covers authority): this base is
    -- acid+holy WEAK, and a weakness hit force-sends the stagger multicast to every client.
    AVU.SkipStaggerAnim(actor)

    AVU.SetShieldColor(actor, {
        Color = BARRIER_COLOR, Base = BARRIER_COLOR, Outline = BARRIER_COLOR, Glow = 3, --5
        Red = BARRIER_CHANNELS.Red, Green = BARRIER_CHANNELS.Green, Blue = BARRIER_CHANNELS.Blue,
    })
    -- ...and LIT THE WHOLE TIME, not just when it eats a hit: "kill the mount first" has to be
    -- readable, and a stock shield is invisible until damaged. Self-limiting - it tracks the pool's
    -- own replicated value, so it stops the moment the steed dies and the barrier permabreaks.
    -- (It also owns ForceFieldColor from here on; the component's per-frame loop overwrites the
    -- SetShieldColor one while lit. See AVU.ArmBarrierGlow.)
    AVU.ArmBarrierGlow(actor, { Color = BARRIER_COLOR, MinPoints = BARRIER_GLOW_MIN })
    jotunWhiteKit(actor)
    H.JotunClientWeld(actor)
end


-- [CLIENT ONLY] The MP anti-jitter for the welded boss, and its undo. None of the authority-side
-- weld replicates (component activity, collision responses, MoveIgnore lists are per-machine), so
-- a client proxy shakes unless calmed. Unlike the Jotun Rider's one-shot calm, THIS boss gets off
-- its mount, so the calm must be undone on dismount - a small per-tick check that follows the
-- (replicated) attachment and flips only on a transition.
local clientWeldOn = {}   -- clientActorKey -> true while WE have this proxy calmed

function H.JotunClientWeld(actor)
    if not Utils.IsClient() then return end
    if Utils.IsActorInvalid(actor) then return end

    AVU.RegisterOnTickActor(actor, function(a)
        if Utils.IsActorInvalid(a) then return "REMOVE" end
        if a.IsDead then return "REMOVE" end
        local key = AVU.CachedFullName(a)
        if not key then return end

        local parent
        pcall(function() parent = a:GetAttachParentActor() end)
        local welded = Utils.IsActorValid(parent)
        if welded == (clientWeldOn[key] == true) then return end

        clientWeldOn[key] = welded or nil
        if welded then
            GKH.CalmClientProxy(a)
        else
            AVU.RestoreRiderMovement(a)
            -- The authority's dismountBoss thins the capsule the boss inherited from its 1.75x
            -- mount; capsule size doesn't replicate, so this side has to do it too or the local
            -- player blocks against a 1.5x cylinder the server no longer has.
            AVU.SetNavRadius(a, AVU.NATIVE_NAV_RADIUS.Humanoid)
            pcall(function()
                local move = a.CharacterMovement
                if IsValid(move) then move.NetworkSmoothingMode = 1 end   -- Linear, the proxy default
            end)
        end
    end)
end


-- =======================================================================
-- JOTUN - ready / mounting
-- =======================================================================

-- [AUTHORITY, OnReady] Phase 1 puts it in the saddle; phase 2 only has to make sure the arena is
-- furnished (Silent: no shatter FX for a barrier that broke in an earlier session).
function H.JotunReady(actor, assets, opts)
    if Utils.IsActorInvalid(actor) then return end
    DL.SetBoss(CFG, actor)

    -- PAY THE SCANS NOW, WHILE IT IS QUIET. Both of these used to happen inside the phase-2
    -- transition, on top of the steed teardown - see ART_FIRST_DELAY_MS and CombatHooks'
    -- ArmDefenseBotSuppressor for why that combination is the scan-crash surface. Adoption is the
    -- calm moment: the boss has just been mutated and nothing is dying.
    pcall(function() require("AnteVariants.CombatHooks").ArmDefenseBotSuppressor() end)
    require("AnteCore.AssetKeeper").PinPaths(PHASE2_PINS)

    if phase2Persisted() then
        LogDebug("Jotun - restored into phase 2 (steed already dead in this save)",
            SETTINGS.DEBUG_NPC_ACTIONS)
        artilleryCheck(actor)
        return
    end
    mountUp(actor)
end


-- [AUTHORITY] Weld the boss onto a steed and link the pair.
--   * FACTION: the pair ship on different native teams and would fight. The steed's def already
--     declares Faction 6, so this copies the boss's LIVE Faction over as confirm (the actor byte
--     prop, not the NPCData.DefaultFaction struct read - that came back nil on the Jotun Rider).
--   * DamageToNPCs 0: the steed must never land the killing blow (no player credit = no world flag).
function H.WeldToSteed(boss, mount)
    if Utils.IsActorInvalid(boss) or Utils.IsActorInvalid(mount) then return end
    local bossKey, mountKey = Utils.ActorKey(boss), Utils.ActorKey(mount)
    if not bossKey or not mountKey then return end

    local fac
    pcall(function() fac = boss.Faction end)
    if fac ~= nil then AVU.SetFaction(mount, fac) end
    pcall(function() mount.DamageToNPCs = 0 end)

    if not AVU.MountRider(boss, mount, SEAT_BONE, { Location = SEAT_LOC, Scale = SEAT_SCALE }) then
        Utils.LogBad("Jotun - could not weld onto its steed; it fights on foot with the barrier up")
        return
    end

    jotunMountState[bossKey] = { mount = mount, mountKey = mountKey }
    jotunByMount[mountKey] = bossKey
    frontShield(boss, bossKey, false)   -- it must not eat shots aimed at the steed under it
    Utils.Log("Jotun of the Fallow mounted its steed")
end


-- =======================================================================
-- JOTUN - combat, tick, reload, damage gate
-- =======================================================================

-- [OnEnterCombat] Drag the steed in with it. MUST be deferred - anything that toggles CombatState
-- from inside the OnRep_CombatState dispatch re-enters the very hook that dispatched it (the
-- Jotun pair's own re-entrancy AV).
function H.JotunEnterCombat(actor)
    if Utils.IsActorInvalid(actor) then return end
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        local key = Utils.ActorKey(actor)
        local rec = key and jotunMountState[key]
        local mount = rec and rec.mount
        if not mount or Utils.IsActorInvalid(mount) or Utils.IsDeadSafe(mount) then return end
        local inCombat = false
        pcall(function() inCombat = mount.CombatState == true end)
        if inCombat then return end
        local target = GKH.BbTarget(actor)
        if target then AVU.ForceAggro(mount, target) end
    end, 0)
end


function H.JotunTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    if actor.IsDead then return "REMOVE" end
    local key = AVU.CachedFullName(actor)   -- stable OnTick wrapper -> the memo is safe
    if not key then return end

    -- Every tick (10Hz): the reload boost has to be dropped the instant the clip refills - back to
    -- the PHASE BASELINE, not to 1.0, or the first reload of phase 2 cancels its speed-up.
    GKH.HoldReloadDilation(actor, JOTUN_RELOAD_CAP_TICKS, baseTdi(key))

    if jotunPhase2On[key] then return end   -- on foot; the base BT owns everything else

    -- Live query, never a stored wrapper. A missing mount is NOT treated as "the steed died" - the
    -- steed's own OnDeath owns that transition, and reading a stream-out as a death would hand the
    -- player phase 2 for free. Missing simply means re-mount.
    local rec = jotunMountState[key]
    local mount = rec and rec.mount
    if mount and (Utils.IsActorInvalid(mount) or Utils.IsDeadSafe(mount)) then mount = nil end

    if not mount then
        if totalTicks % MOUNT_CHECK_TICKS == 0 then mountUp(actor) end
        return
    end

    if totalTicks % AIM_TICKS == 0 then
        local target = GKH.BbTarget(actor)
        GKH.AimRider(actor, mount, target, SEAT_MAX_YAW)
        GKH.GateRiderFire(actor, mount, target, SEAT_ARC)
    end
    if totalTicks % PIN_TICKS == 5 then
        GKH.ReassertPin(actor)
        GKH.ReweldRider(actor, SEAT_LOC)
    end
end


-- [OnReload] Speed the reload by running the whole actor fast (Montage_SetPlayRate is server-local)
-- - safe here because the reload sets LockedInPlaceMontage, so nothing else visibly speeds up.
-- MULTIPLIES the phase baseline rather than replacing it; the tick restores to that baseline, never
-- to 1.0.
function H.JotunReload(actor)
    if Utils.IsActorInvalid(actor) then return end
    local key = Utils.ActorKey(actor)
    if not key then return end
    GKH.ReloadStart[key] = STATE.FAST_TICK
    AVU.SetTimeDilation(actor, baseTdi(key) * JOTUN_TDI.ReloadMult)
end


-- [DamageGate] Ignore hits thrown in from outside the arena (shared - see DL.OutOfArena).
function H.JotunDamageGate(actor)
    return DL.OutOfArena(CFG, actor)
end


-- =======================================================================
-- PHASE 2 - dismount, permabreak, artillery (entry points)
-- =======================================================================

-- The one transition, and the only place the barrier ever comes down.
--   * IDEMPOTENT: a second call only re-runs the artillery check. That is also the RESTORED path -
--     JotunStats has already latched the phase off StoryData by the time OnReady lands here, so a
--     boss that lost its steed in an earlier session re-furnishes its arena and nothing else (no
--     second shatter multicast for a barrier that broke days ago).
function H.EnterPhase2(boss)
    if Utils.IsActorInvalid(boss) then return end
    local key = Utils.ActorKey(boss)
    if not key then return end

    if jotunPhase2On[key] then
        artilleryCheck(boss)
        return
    end
    jotunPhase2On[key] = true   -- set FIRST: baseTdi(key) reads it
    setPhase2Persisted(true)    -- and BEFORE anything that can fail - a relog must not undo the phase

    dismountBoss(boss, key)
    frontShield(boss, key, true)   -- on foot it can have its shield back (JOTUN_FRONT_SHIELD_P1)

    pcall(function() boss.Invincible = false end)
    barrierPermabreak(boss)
    pcall(function() boss:Broadcast_ForceShieldBrokenFX() end)

    AVU.SetMoveSpeed(boss, JOTUN_P2_SPEED, JOTUN_P2_SPEED)
    AVU.SetTimeDilation(boss, baseTdi(key))
    Utils.Log("Jotun of the Fallow - steed down, barrier shattered (phase 2)")

    -- The sting. 2D on the announcement channel so it lands as a moment for everyone, not a noise
    -- from over there. Inside the not-yet-phase-2 branch only - a relog (the early-out above) must
    -- not re-announce a barrier that broke days ago. Wave is pinned at adoption (PHASE2_PINS), so
    -- this costs no scan here despite PlaySound2DAll's own LoadAsync.
    AVU.PlaySound2DAll(ENUMS.SOUNDS.GKHEAVY_GRENADE_03)

    -- A beat on its feet before it starts shooting again - the shatter needs to land as a moment
    -- rather than a gear change. The rifts open at ART_FIRST_DELAY_MS (2.5s) and the hold releases
    -- at JOTUN_IDLE.Ms (3s), so the artillery arrives just as the boss gets back up.
    dismountIdle(boss, key)
    artilleryCheck(boss)
end


-- The paired release. Safe to call when no hold is running (HoldStill(false) on a free NPC is a
-- no-op), which is why death and /dlreset jotun can both call it unconditionally.
function H.EndDismountIdle(actor)
    local key = Utils.ActorKey(actor)
    if key then jotunIdleGen[key] = nil end   -- any pending re-assert sees a stale generation
    AVU.HoldStill(actor, false)
end


-- =======================================================================
-- JOTUN - death
-- =======================================================================

function H.JotunDeath(actor)
    -- FIRST: a hold left set would freeze the death animation in place.
    H.EndDismountIdle(actor)

    local key = Utils.ActorKey(actor)
    if key then
        -- The steed should already be gone (the barrier makes phase 1 unwinnable otherwise), but a
        -- riderless boss steed left wandering the Fracture would be a permanent oddity.
        local rec = jotunMountState[key]
        if rec and Utils.IsActorValid(rec.mount) then
            pcall(function() rec.mount:K2_DestroyActor() end)
        end
        if rec and rec.mountKey then jotunByMount[rec.mountKey] = nil end
        jotunMountState[key] = nil
        jotunPhase2On[key] = nil
        lastRemountTick[key] = nil
    end
    pcall(function() actor.Invincible = false end)
    GKH.ClearRiderGate(actor)
    DL.ForgetGuard(actor)
    DL.ForgetBoss(CFG)

    -- The class only sets Fracture_DL_Heavy_Dead on a player-credited or player-aligned kill; any
    -- other death would silently break the Fracture questline.
    DL.FlagBackstop(CFG)

    -- ...and start the respawn clock: late-game this boss comes back DL.RESPAWN_DAYS days from
    -- now (DL.NoteBossDeath / the arena watcher).
    DL.NoteBossDeath(CFG)
end


-- =======================================================================
-- FALLOW STEED (the mount)
-- =======================================================================

-- [AUTHORITY, Stats] A slow, wide-turning bruiser that hits hard and often. Peccary_Armored has no
-- charge at all (its Broadcast_CombatAbility1 is overridden EMPTY) and ships with a native
-- TargetPriority_Multiply of 400 - it is already an aggro magnet, which is exactly what a mount you
-- are meant to kill first should be.
function H.SteedStats(actor, opts)
    AVU.LockTaming(actor)
    AVU.DisableAbility(actor, STEED_ABILITY_CARBUNCLE)

    -- It carries the boss: a stagger stumble (or a Stopping Power forced one) rocks the whole
    -- welded platform. Stagger only - freeze/net counterplay stays available, unlike the boss's
    -- full CCImmune. SteedLook carries the renderer half.
    AVU.SetStaggerImmune(actor)

    -- It carries the boss. It may never damage an NPC (see the file header).
    pcall(function() actor.DamageToNPCs = 0 end)

    -- Faster SWING. On its own this only speeds the animation - the BT waits out the montage's RAW
    -- length - so SteedTick fires the release valve to match (AVU.MeleeReleaseTicks).
    pcall(function() actor.MeleeAttackPlayRate = STEED_MELEE_RATE end)

    local move = actor.CharacterMovement
    if IsValid(move) then
        pcall(function() move.RotationRate = FRotator(0, STEED_YAW_RATE, 0) end)
        pcall(function() move.MaxAcceleration = STEED_ACCELERATION end)
    end
end


-- [AUTHORITY, OnReady] The absorb pool, once the spawn has settled (Assets are loaded by now, so
-- the component class is resident and AddComponentByClass can't blocking-load in the hook).
function H.SteedReady(actor, assets, opts)
    if Utils.IsActorInvalid(actor) then return end
    Utils.QueueWork(function()
        AVU.AddBodyShield(actor, { Max = STEED_SHIELD.Hp, Current = STEED_SHIELD.Hp,
            Regen = STEED_SHIELD.Regen, ShowFX = true })

        -- No SetShieldFlareColor here on purpose - the mount wears the STOCK shield so it reads as
        -- the killable one. See the steed-shield knobs.
    end, 800)
end


-- [RENDERER] The native "energy shell flashes on an absorbed hit" look, built the ShieldPest way:
-- the NPC's OWN mesh, leader-posed, energy-shield material, hidden, and component-TAGGED
-- "bodyshield" (BodyShieldComponent.UpdateMaterials finds its FX meshes by that tag). Passing no
-- mesh uses the actor's own, so this is base-independent.
--   * NO COLOUR ARGS: the stock blue-to-red shell IS the read we want on the mount (see knobs).
function H.SteedLook(actor)
    -- Renderer half of SteedStats' SetStaggerImmune (forced staggers still multicast).
    AVU.SkipStaggerAnim(actor)

    AVU.AttachShieldShell(actor, nil, {})

    -- Calm the welded boss from the CARRIER's side too (client-only inside): the steed's tag
    -- usually decodes first, so this covers the window before the boss's own Visuals runs.
    AVU.CalmClientNpcPassengers(actor)
end


-- [OnMeleeSwing] Stamp the swing; SteedTick decides when to hand the BT its release.
function H.SteedSwing(actor)
    local key = Utils.ActorKey(actor)   -- a hook wrapper is FRESH every call - never a wrapper key
    if key then lastSteedSwingTick[key] = STATE.FAST_TICK end
end


-- [OnTick] Only the melee valve: let it swing again as soon as the sped-up montage has really
-- ended, instead of standing through the remainder of the raw one.
--   * Driven from HERE, not a QueueWork inside OnMeleeSwing: that hook hands out a fresh
--     ProcessEvent wrapper and holding one across a ~1s delay is the stale-wrapper case. This is
--     the tick's own stable wrapper, re-validated at the top of every pass.
function H.SteedTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    if actor.IsDead then return "REMOVE" end
    local key = AVU.CachedFullName(actor)
    if not key then return end

    local last = lastSteedSwingTick[key]
    if not last then return end
    local st = steedSwingState[key]
    if st and st.releasedFor == last then return end

    local wait = AVU.MeleeReleaseTicks(ENUMS.Anims.PECCARY_MELEE, STEED_MELEE_RATE, {
        Offset = STEED_MELEE_OFFSET, Fallback = STEED_MELEE_LEN, Pad = STEED_RELEASE_PAD,
    })
    if not wait then return end   -- not measured yet; the native delay still ends the swing
    if STATE.FAST_TICK - last < wait then return end

    st = st or {}
    st.releasedFor = last
    steedSwingState[key] = st
    AVU.ReleaseSoldierBT(actor)
end


-- [OnDeath] THE phase transition. The steed dying is the only legitimate way the boss loses its
-- barrier, so this is the authoritative trigger - the boss's tick deliberately treats a merely
-- MISSING mount as "re-mount", not "phase 2".
function H.SteedDeath(actor)
    local key = Utils.ActorKey(actor)
    if not key then return end

    local bossKey = jotunByMount[key]
    jotunByMount[key] = nil
    lastSteedSwingTick[key] = nil
    steedSwingState[key] = nil
    if not bossKey then return end

    -- Deferred: OnDeath runs inside the death dispatch, and EnterPhase2 detaches the boss, writes
    -- a save file and portals in adds - none of which belongs nested in that hook.
    Utils.QueueWork(function()
        local boss = DL.Boss(CFG)
        if not boss then return end
        H.EnterPhase2(boss)
    end, 250)
end


-- =======================================================================
-- DEBUG - encounter reset (/dlreset jotun, ChatCommands)
-- =======================================================================

-- Reset the fight for testing: destroy our steed + the portalled artillery, clear the persisted
-- phase, heal + re-shield the boss and put it back in a fresh saddle.
--   * With no living boss, a fresh one is put on the field - through its spawner where that still
--     works, else spawned directly (a world flag can never be un-set, so a save where it has died
--     can only ever get a direct spawn).
--   * Bodies are found by class scan + variant tag; the registry holds no wrappers.
function H.ResetEncounter()
    if not Utils.IsAuthority() then return end

    local VT = require("AnteVariants.VariantTag")
    local V = require("AnteVariants.Variants")
    local destroyed = 0

    local function wipe(classKey, variantName, radius)
        local id = V[variantName] and V[variantName].Id
        if not id then return end
        local hits = AVU.GetNearbyActorsOfClass(ARENA_CENTER, radius, ENUMS.NpcClasses[classKey])
        for i = 1, #hits do
            pcall(function()
                local a = hits[i]:get()
                if Utils.IsActorValid(a) and VT.Decode(a) == id then
                    a:K2_DestroyActor()
                    destroyed = destroyed + 1
                end
            end)
        end
    end
    wipe("Peccary_Armored", VAR_STEED, ARENA_SCAN_RADIUS + 2000)
    wipe("Robot_Defense", ART_VARIANT, ARENA_SCAN_RADIUS + 2000)

    for _, t in ipairs({ jotunPhase2On, jotunMountState, jotunByMount, lastRemountTick,
                         lastSteedSwingTick, steedSwingState, jotunIdleGen, jotunShieldProfile }) do
        for k in pairs(t) do t[k] = nil end
    end
    setPhase2Persisted(false)

    local boss = DL.Boss(CFG)
    if boss then
        pcall(function() boss.Invincible = false end)
        DL.ForgetGuard(boss)
        GKH.ClearRiderGate(boss)
        -- Release a dismount hold caught mid-run, and drop back to the mounted baseline speed
        -- (both are runtime-only state that the phase wipe above cannot reach).
        H.EndDismountIdle(boss)
        AVU.SetTimeDilation(boss, JOTUN_TDI.Mounted)
        -- Undo the permabreak first, then re-raise the barrier on top of native values, so a later
        -- break restores something sane.
        AVU.SetBodyShield(boss, { Max = JOTUN_SHIELD.Hp, Current = JOTUN_SHIELD.Hp,
            Regen = JOTUN_SHIELD.Regen, RegenTime = 8, RegenTimeZero = 15 })
        pcall(function() boss:InitalizeHealthValues(true) end)   -- heal limbs from NPCData
        -- A boss caught mid-phase-2 is still detached and walking; re-weld it.
        AVU.DismountRider(boss, nil)
        barrierUp(boss)
        mountUp(boss)
        Utils.Log(string.format("DL Jotun reset: boss re-shielded + re-mounting, %d bodies destroyed",
            destroyed))
    else
        DL.NoteFlagLocked(CFG)
        DL.RespawnBoss(CFG, string.format("%d bodies destroyed", destroyed))
    end
end


return H
