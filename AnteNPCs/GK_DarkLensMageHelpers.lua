-- =======================================================================
-- GK_DARKLENSMAGE HELPERS - the Magus of the Fallow (base row "DarkLens_Mage")
-- Full decode/mechanics: AnNotes/AnteNPCs/GKDarkLensMage.md. MUST-KNOWS:
--   * THE SEAL IS NOT `Invincible`. NPC_Mage_DarkLens gates on a replicated
--     `DarkLensCombatReady` bool: while false, ProcessDamage refuses, IsNPCBusy() is forced
--     true, and the shield wall stays up. The eyes-destroyed flag flips it via its own OnRep,
--     which unhides/unpins/aggros on every machine. NEVER write Invincible directly - unseal
--     is ONE AVU.SetReplicatedProp on DarkLensCombatReady.
--   * TEST COPIES ONLY: unsealTestCopy() flips that bool for a body OUTSIDE DL.ARENAS.Mage;
--     the real arena body keeps the native gate (its polygon overlaps two other DarkLens
--     arenas, so a test spawn inside the Fracture stays sealed). WHILE SEALED NOTHING HERE
--     MAY ACT - every ability keys off CombatState, and CFG.CanForceAggro refuses it too.
--   * THE SHARED DARKLENS LAYER (GK_DarkLensHelpers, as DL) runs the watcher/arena guard/
--     respawn like the other three DarkLens fights. RespawnStory = 0: its death IS the
--     Fracture-complete milestone, so no story check gates the respawn.
--   * STOCK KIT MOSTLY OFF: native fireball, the native TurtleMode front shield and the
--     native eye spawn are all disabled - the ghost-bolt replaces the fireball as the regular
--     attack (Wraith recipe), and only the gravity wave + choke chain survive from stock
--     NPC_Mage.
--   * Immobility is the Patriarch treatment: PinInPlace at OnReady + Stats, re-asserted on a
--     cadence, plus a scripted FaceTarget - a pinned body never turns on its own.
--   * THE GHOST-BOLT is the filler attack (shared with the Astral add): fires from tick
--     unless a scripted move owns the body (quietBolt/boltQuiet) or a victim is held.
--   * THE VOLLEY IS A NON-ATTACK: OnTick-fired lobbed fireballs, aim captured BY VALUE at
--     cast so montage + flight time are the dodge window.
--   * FIRE-PATCH BOOST: the patch's lifetime delay is armed in its own BeginPlay, so
--     stretching it needs write-then-ResetDuration, off NotifyOnNewObject via QueueWork (not
--     in the notify itself - the Coworker rule).
--   * THE EYE BEAM sweeps a steered laser off the Deatomizer recipe, geometry-only damage
--     (PointDamageOffHook), a measured re-play cadence for its channel pose, and a scripted
--     HoldStill since our CCImmune refuses the native self-stun.
--   * THE PHASE MACHINE (1..5, two astral holds) tracks progress by DAMAGE DEALT, not HP -
--     two guards (a per-hit cap + a post-hit floor clamp) keep a burst from overshooting a
--     transition.
--   * THE ASTRAL ADD is a scripted spirit copy that fires the same ghost-bolt, dodges by a
--     scripted glide-hop (its pose is single-node, so montage dodges can't play), and its
--     death (or a timeout) ends the hold.
--   * THE FORCE CHOKE rides the native grab chain: a scripted two-impulse pull (lift then a
--     solved lob) delivers the victim into the grab window, with a rescue/watchdog belt
--     against a whiff or a softlock.
--   * FILE LAYOUT: SEAL HANDLING -> ARENA REGISTRATION -> CORE DISPATCH -> ASSET SETS ->
--     PER-ACTOR TRACKING, then one banner per Magus mechanic (PHASE MACHINE, FIRE-PATCH
--     BOOST, FIREBALL VOLLEY, EYE BEAM, FORCE CHOKE, GHOST-BOLT) with that mechanic's own
--     knobs directly above it, then ASTRAL MAGUS (its own knobs + private machinery), then
--     the two VARIANT HOOKS banners (Magus, then Astral) that GK_DarkLens.lua actually calls.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local ENUMS = require("AnteData.Enums")
local ASSETS = require("AnteCore.AssetManager")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local AVM = require("AnteUtils.AVMath")
local PROJ = require("AnteCore.Projectile")
local Lasers = require("AnteUtils.Lasers")
local UEHelpers = require("UEHelpers")
local DL = require("AnteNPCs.GK_DarkLensHelpers")   -- the shared layer: arenas, watcher, guard, respawn
local GKM = require("AnteNPCs.GK_MageHelpers")      -- StripMageShield (Magus) / StripMageKit (Astral)
local VS = require("AnteVariants.VariantSignal")    -- astral-hold bit -> clients (the shell mirror)

local M = {}


-- =======================================================================
-- SEAL HANDLING
-- =======================================================================

-- The native gate: false = bubble up, ProcessDamage refuses, BT parked. Read live, never cached
-- (the OnRep flips it on every machine the moment the last eye dies).
local function isSealed(actor)
    local ready = false
    pcall(function() ready = actor.DarkLensCombatReady == true end)
    return not ready
end

--- [AUTHORITY] Unseal a TEST copy (anything outside the Fracture Mage arena). The real boss
--- keeps its native Fracture_DL_AllEyes_Destroyed gate. One replicated-prop trio: the OnRep
--- hides the bubble, clears Invincible and aggros on every machine.
local function unsealTestCopy(actor, opts)
    if Utils.IsActorInvalid(actor) then return end
    local ready = false
    pcall(function() ready = actor.DarkLensCombatReady end)
    if ready then return end
    if not (opts and opts.Unseal) and Utils.ActorInArea(actor, DL.ARENAS.Mage) then return end
    AVU.SetReplicatedProp(actor, "DarkLensCombatReady", true)
end


-- =======================================================================
-- ARENA REGISTRATION
-- =======================================================================

-- Everything GK_DarkLensHelpers needs to run this fight's watcher / arena guard / backstop /
-- respawn (see that file's header for the fields). Center/Home = the game's own
-- NPCSpawn_DARKLENS_Mage mark - the same coordinate as the SpawnerData row.
local ARENA_CENTER = FVector(-34748, 87230, 2588)
local CFG = {
    StateKey      = "DarkLensMageArmed",
    Label         = "DarkLens Mage",
    Boss          = "Magus",
    Flag          = "Residence_Fracture_Complete",   -- its death flag IS the Fracture-complete flag
    ClassKey      = "DarkLens_Mage",
    Variant       = "Magus of the Fallow",
    Center        = ARENA_CENTER,
    Area          = DL.ARENAS.Mage,
    ScanRadius    = 3000,
    WakeSq        = 8000 * 8000,   -- the arena is the biggest of the four and open on every side
    AggroSq       = 3000 * 3000,   -- a player this close to the (UNSEALED) boss -> ForceAggro
    CanForceAggro = function(boss) return not isSealed(boss) end,
    WatchMs       = 3000,
    SpawnerClass  = "NPCSpawn_DARKLENS_Mage_C",
    Home          = ARENA_CENTER,
    GuardRange    = 5000,          -- 50m boss-anchor radius; the plan polygon is the other anchor
    -- ALWAYS eligible to come back DL.RESPAWN_DAYS after a kill: its death IS the Fracture-complete
    -- milestone the other three wait on, so there is no story check left to make (the default gate
    -- would still pass, but only after StoryManager recomputes progress from the flag it just set).
    RespawnStory  = 0,
}

--- Armed from main.lua each world load (the Patriarch/Witch/Jotun pattern). Authority-only
--- inside; a client call is a no-op (no prop guard for this arena - it overlaps two others).
function M.Register()
    DL.ArmWatcher(CFG)
end


-- =======================================================================
-- CORE DISPATCH
--   Cadence knobs read by MagusTick to pace facing/pin/unseal-retry and the gap enforced
--   between any two scripted abilities. Not owned by one mechanic below.
-- =======================================================================
local PIN_TICKS    = 10   -- pin re-assert cadence (Patriarch precedent)
local FACE_TICKS   = 5    -- scripted facing cadence while in combat
local UNSEAL_TICKS = 30   -- test-copy unseal retry (world flags may not be loaded at mutation)
local GAP_TICKS    = 30   -- breathing room AFTER any ability ends before the next may start


-- =======================================================================
-- ASSET SETS
-- =======================================================================

-- Everything a volley IMPACT touches, minutes after mutation - re-warmed per cast (S3: a
-- def.Assets preload does not stick; a resident re-load is a free cache hit). The projectile
-- CLASS is deliberately ABSENT here - PROJ.Queue loads it itself per shot, and listing it too
-- buys a second UObject scan (the FrostShells lesson).
M.VOLLEY_DEPS = {
    ENUMS.Components.AREA_PLASMA_FIRE,    -- the fire patch the fireball spawns on impact
    ENUMS.DamageType.FirePlasma,          -- passed per shot; its DebuffsCanApply is the trap:
    ENUMS.BuffObjects.IgnitedPlasma,      --   named by ROW, so the buff OBJECT must be warm
    ENUMS.BuffObjects.HPDamage,           --   and so must its parent DoT
    ENUMS.Anims.MAGE_FIREBALL,            -- the tell: with the native fireball OFF nothing else
                                          --   ever loads it, and PlayMontageReplicated is non-loading
}

-- Everything a beam channel touches: the component class + the three Niagara systems a laser
-- builds LAZILY per renderer (the Lasers-header cold-load rule), the damage type, the loop SFX.
M.BEAM_DEPS = {
    ENUMS.LaserComponent,
    Lasers.FX_BEAM, Lasers.FX_END, Lasers.FX_RECV,
    ENUMS.DamageType.Laser,
    ENUMS.SOUNDS.HEAVY_LASER_FIRE,
    ENUMS.Anims.MAGE_BLOCK,            -- the channel pose (head-stabilising block)
}

-- Everything the force choke touches: BOTH grab montages (SUCCESS is FindObject'd cold by the
-- native success broadcast - nil = silent whiff) + the stun object ParryStun applies by ROW.
M.CHOKE_DEPS = {
    ENUMS.Anims.MAGE_GRAB_START,
    ENUMS.Anims.MAGE_GRAB_SUCCESS,
    ENUMS.BuffObjects.Stunned,
}

-- ONE beam style, declared once: the server end paints from it here, and def.LaserStyle hands
-- the SAME table to ClientVisuals' OnRep hook (laser colour does not replicate).
M.BEAM_STYLE = { Color = Lasers.COLOR.BLUE }

-- The ghost-bolt's pieces (shadow-orb carrier with hidden mesh, the ChargeUp trail, Electric -
-- no debuff tail, S6-clean). Listed in BOTH def.Assets below; the class is listed on purpose -
-- pinned, PROJ.Queue's per-shot resolve is a table hit instead of a UObject-array walk.
local BOLT_ASSETS = {
    ENUMS.ProjectileClasses.ShadowOrbVacuum,
    ENUMS.DamageType.Electric,
    ENUMS.Effects.EXOR_CHARGEUP_CHA,      -- welded onto the bolt as its visible body
}

-- The Astral add's def.Assets: the bolt, the ping FX, the meditate pose.
M.ASTRAL_ASSETS = {
    ENUMS.Effects.SHIELD_REGEN,           -- the immune-hit ping (BroadcastFX; upward cylinder)
    ENUMS.Anims.MAGE_MEDITATE,
}
for _, p in ipairs(BOLT_ASSETS) do M.ASTRAL_ASSETS[#M.ASTRAL_ASSETS + 1] = p end

-- def.Assets for the Magus: the Pipeline LoadAsyncs AND GC-pins this whole set at mutation
-- (renderer, ASSET_KEEPER) - the "permanent pin" for a boss that fires a lot of
-- fireballs. The projectile classes ARE listed here: a pinned class makes PROJ.Queue's per-shot
-- resolve a trusted table hit instead of a UObject-array walk.
M.MAGUS_ASSETS = {
    ENUMS.SOUNDS.GKMAGE_DL_AGGRO,         -- the unseal OnRep speaks it (test unseal is in-drain)
    ENUMS.SOUNDS.GKMAGE_DL_ASTRAL,        -- the flat 2D call fired at each astral hold (enterAstral)
    -- the volley (+ the fireball montage, which doubles as the bolt's tell)
    ENUMS.ProjectileClasses.MageFireball,
    ENUMS.Components.AREA_PLASMA_FIRE,
    ENUMS.DamageType.FirePlasma,
    ENUMS.BuffObjects.IgnitedPlasma,
    ENUMS.BuffObjects.HPDamage,
    ENUMS.Anims.MAGE_FIREBALL,
    -- the eye beam
    ENUMS.LaserComponent,
    Lasers.FX_BEAM, Lasers.FX_END, Lasers.FX_RECV,
    ENUMS.DamageType.Laser,
    ENUMS.SOUNDS.HEAVY_LASER_FIRE,
    ENUMS.Anims.MAGE_BLOCK,
    -- the force choke
    ENUMS.Anims.MAGE_GRAB_START,
    ENUMS.Anims.MAGE_GRAB_SUCCESS,
    ENUMS.BuffObjects.Stunned,
    -- the astral-hold shell
    ENUMS.Components.M_ENERGY_SHIELD,
}
for _, p in ipairs(BOLT_ASSETS) do M.MAGUS_ASSETS[#M.MAGUS_ASSETS + 1] = p end


-- =======================================================================
-- PER-ACTOR TRACKING
-- =======================================================================
local volleyTick = {}       -- key -> last volley FAST_TICK stamp (AVU.CooldownReady)
local beamTick   = {}       -- key -> last beam-channel FAST_TICK stamp
local chokeTick  = {}       -- key -> last force-choke FAST_TICK stamp
local busyUntil  = {}       -- key -> FAST_TICK before which no NEW ability may start
local boltQuietUntil = {}   -- key -> FAST_TICK before which the ghost-bolt filler stays quiet
                            --   (a scripted move owns the body: volley cast / beam / choke)
local beamOn     = {}       -- key -> true while a channel owns the mage's facing
local beamPoseMs = nil      -- measured block-montage re-play cadence (ms) - the NUMBER only,
                            --   never the asset (S3); nil until the first channel measures it
local phaseState = {}       -- key -> { Phase = 1..5, Actor = <magus>, AstralSlot = {actor=,born=,cancel=} }
local astralToMagus = {}    -- astral key -> its magus' key (death routing + ball slow-down)
local magusShell = {}       -- key -> attached shell component (the astral-hold sheen)

local astralPingTick  = {}  -- astral key -> last immune-ping FAST_TICK stamp
local astralDodgeTick = {}  -- astral key -> last side-hop FAST_TICK stamp

local patchNotifyArmed  = false   -- NotifyOnNewObject can't be undone; arm once per session

local function isBusy(key) return STATE.FAST_TICK < (busyUntil[key] or 0) end
local function setBusy(key, ticks) busyUntil[key] = STATE.FAST_TICK + ticks end

-- The ghost-bolt filler yields to whichever scripted move owns the body. Extend-only, so an
-- early finisher (a beam bailing) can't shorten a hold someone else set; a hold that outlives
-- its move by a beat is harmless (the next tick fires the bolt).
local function boltQuiet(key) return STATE.FAST_TICK < (boltQuietUntil[key] or 0) end
local function quietBolt(key, ms)
    local until_ = STATE.FAST_TICK + math.ceil(ms / 100)
    if until_ > (boltQuietUntil[key] or 0) then boltQuietUntil[key] = until_ end
end


-- =======================================================================
-- PHASE MACHINE
--   1: 100-66%  volley + beam            -> floor at 66% -> phase 2
--   2: astral hold 1 - INVULN (DamageGate), no abilities, ghost-bolt filler only
--   3: 66-33%   volley + beam + choke    -> floor at 33% -> phase 4
--   4: astral hold 2 - INVULN, volley only
--   5: 33-0%    everything, cooldowns x PHASE5_CD_MUL
-- An astral hold ends when its add dies OR at ASTRAL_SPAWN.MaxMs (we kill the add ourselves).
-- =======================================================================

-- Two guards prevent overshoot: DMG_CAP_RAW caps each hit pre-scaling (a single burst can't
-- zero a pool outright), and a post-hit clamp holds each pool at its phase floor. Progress is
-- DAMAGE DEALT, not remaining HP - limb damage doesn't reach the kill pools until overflow, so
-- an aim-based meter would stall for a torso/head-focused fight. See AnNotes/AnteNPCs/GKDarkLensMage.md.
M.HP_HEAD  = 2500                  -- def.BasicStats reads these: phase math and statline agree
M.HP_TORSO = 2500
M.HP_HEAD_HARD  = 3000             -- def.HardMode.BasicStats reads these
M.HP_TORSO_HARD = 4500
M.HP_LIMB  = 1000                  -- x4; a shield tax on limb-shooters, NOT a phase meter
local HEAD_LIMB, TORSO_LIMB = 3, 4 -- GetLimbHealth indices (the Tarasque decode)
-- The two transitions are FRACTIONS OF THE COMBINED POOL, not absolutes, so the hard pools move
-- the fight's shape with them instead of front-loading both holds into the first third.
local PHASE2_AT_FRAC = 0.5         -- damage taken -> astral hold 1
local PHASE4_AT_FRAC = 1.0         -- damage taken -> astral hold 2 (clamp-voided hits COUNT,
                                   --   so a pool-camper still progresses the fight)
local PHASE2_FRAC   = 0.66         -- pool floor while phases 1-2, and the write-down mark
local PHASE4_FRAC   = 0.33         -- pool floor while phases 3-4, ditto
local PHASE5_CD_MUL = 0.6          -- endgame: ability cooldowns scaled by this
local DMG_CAP_RAW   = 400          -- per-hit ceiling, pre-scaling (headshot x2 can still double it)

-- The live pools. Everything downstream (floors, transitions) derives from these, so hard mode
-- only has to change the pair.
local function hpPools()
    if STATE.HardModeNoMercy then return M.HP_HEAD_HARD, M.HP_TORSO_HARD end
    return M.HP_HEAD, M.HP_TORSO
end

-- The astral-hold shell (the "I am invulnerable" read, on every machine).
local SHELL_TICKS = 10                        -- mirror cadence (renderer)
local SHELL_COLOR = FVector(2, 0.55, 0.08)    -- red-orange; ALL THREE slots or stock hue bleeds
local SHELL_GLOW  = 6
local SIG_ASTRAL  = VS.TDI                    -- free: this def never mirrors time dilation

-- The phase OPENER: the moment a hold ends, the boss force-chokes immediately and holds its
-- other abilities while the whole sequence (tell + pull + choke + toss, ~7s) plays out. Named
-- FC_ (tryForceChoke reads the resulting st.OpenerUntil), but only endAstral below reads these -
-- kept with the phase machine's own knobs rather than the Force Choke section.
local FC_OPENER_BUSY_TICKS   = 70  -- volley/beam blackout after a hold ends
local FC_OPENER_WINDOW_TICKS = 80  -- give up on the opener if no valid pull target appears

-- The Astral add's spawn/lifetime, as read by spawnAstral/astralTimeout below (its own
-- look/combat knobs live with the rest of ASTRAL MAGUS, further down).
local ASTRAL_SPAWN = {
    Name     = "Astral Magus",
    MaxMs    = 40000,   -- hold ceiling: past this we kill the add and end the phase
    SpawnOut = 350,     -- navmesh ring around the boss for the add's arrival
}

-- Which scripted ability may fire in which phase (the ghost-bolt filler is never gated here).
local PHASE_ALLOW = {
    [1] = { volley = true, beam = true },
    [2] = {},
    [3] = { volley = true, beam = true, choke = true },
    [4] = { volley = true },
    [5] = { volley = true, beam = true, choke = true, CdMul = PHASE5_CD_MUL },
}

local function phaseOf(key)
    local st = phaseState[key]
    return st and st.Phase or 1
end

-- Hard mode only ADDS abilities to a phase, never removes them: the choke is live from the
-- opening instead of being the first hold's reward.
local HARD_ALLOW = { [1] = { choke = true } }

local function allows(key, what)
    local phase = phaseOf(key)
    if PHASE_ALLOW[phase][what] == true then return true end
    return STATE.HardModeNoMercy and (HARD_ALLOW[phase] or {})[what] == true
end

local function cdTicks(key, base)
    return math.floor(base * (PHASE_ALLOW[phaseOf(key)].CdMul or 1))
end

-- The DEATH-guard pool floors for the CURRENT phase (nil = endgame, pools free). Death is
-- Head==0 OR Torso==0, so each pool holds its own floor until the fight has earned the phase.
local function floorsFor(phase)
    local head, torso = hpPools()
    if phase <= 2 then return head * PHASE2_FRAC, torso * PHASE2_FRAC end
    if phase <= 4 then return head * PHASE4_FRAC, torso * PHASE4_FRAC end
    return nil
end

local function currentHp(actor)
    local h, t = 0, 0
    pcall(function() h = tonumber(actor:GetLimbHealth(HEAD_LIMB)) or 0 end)
    pcall(function() t = tonumber(actor:GetLimbHealth(TORSO_LIMB)) or 0 end)
    return h, t
end

-- Write CURRENT head/torso: the native per-limb setter (real health) + the BP mirror map +
-- the GetOnly total push that refreshes the nameplate (the ScalePetHealth recipe).
local function writeHp(actor, head, torso)
    pcall(function()
        actor:SetLimbHealth(HEAD_LIMB, head)
        actor:SetLimbHealth(TORSO_LIMB, torso)
        local cur = actor.Current_LimbHealthMap
        if cur ~= nil then cur:Add(HEAD_LIMB, head); cur:Add(TORSO_LIMB, torso) end
        actor:GetAndSetTotalHealth(true, {}, {}, {})
    end)
end

--- End an astral hold (idempotent - the add's death AND the timeout both funnel here).
local function endAstral(key, st)
    if st.Phase ~= 2 and st.Phase ~= 4 then return end
    if st.AstralSlot then st.AstralSlot.cancel = true; st.AstralSlot = nil end
    st.Phase = (st.Phase == 2) and 3 or 5
    if st.Actor ~= nil and Utils.IsActorValid(st.Actor) then VS.Set(st.Actor, SIG_ASTRAL, 0) end
    -- PHASE OPENER: the unseal moment IS a force choke. The busy blackout keeps volley/beam
    -- out of the way for the whole sequence; tryForceChoke sees OpenerUntil and fires past
    -- its own busy/cooldown gates (with an expiry, in case nobody is in the pull band).
    st.OpenerUntil = STATE.FAST_TICK + FC_OPENER_WINDOW_TICKS
    setBusy(key, FC_OPENER_BUSY_TICKS)
end

--- The 30s ceiling. Slot-matched so a stale timer from an already-ended hold no-ops.
local function astralTimeout(key, slot)
    local st = phaseState[key]
    if not st or st.AstralSlot ~= slot then return end
    local a = slot.actor
    if a ~= nil and Utils.IsActorValid(a) and not a.IsDead then
        AVU.KillNpc(a)   -- its OnDeath routes back through endAstral; the call below is the belt
    end
    endAstral(key, st)
end

--- Claim the slot BEFORE the spawn request (the orchestrator-registry rule: the spawn callback
--- lands ticks later, and a cancelled slot destroys its late arrival).
local function spawnAstral(actor, key, st)
    local origin = actor:K2_GetActorLocation()
    if not origin then endAstral(key, st); return end
    local spot = Utils.GetSpawnPoint(origin, ASTRAL_SPAWN.SpawnOut) or origin

    local slot = { born = STATE.FAST_TICK }
    st.AstralSlot = slot

    AVU.SummonVariant(ASTRAL_SPAWN.Name, spot, nil, function(npc)
        slot.actor = npc
        if Utils.IsActorInvalid(npc) then return end
        if slot.cancel then AVU.KillNpc(npc); return end
        local ak = Utils.ActorKey(npc)
        if ak then astralToMagus[ak] = key end
        Utils.QueueWork(function()
            if Utils.IsActorInvalid(npc) then return end
            local tgt = AVU.GetCurrentTarget(actor)
            if tgt then AVU.LockAggro(npc, tgt, { DelayMs = 500, HoldMs = 6000 }) end
        end, 400)
    end)

    Utils.QueueWork(function() astralTimeout(key, slot) end, ASTRAL_SPAWN.MaxMs)
end

local function enterAstral(actor, key, st)
    st.Phase = (st.Phase == 1) and 2 or 4
    st.Actor = actor
    VS.Set(actor, SIG_ASTRAL, 1)   -- clients mirror the shell off this
    setBusy(key, GAP_TICKS)
    spawnAstral(actor, key, st)
    -- The summon call, flat and non-positional on every player's UI channel (the assault-sting
    -- route) - the hold is an arena-wide beat, not a thing you locate by ear. Fires on BOTH holds.
    AVU.PlaySound2DAll(ENUMS.SOUNDS.GKMAGE_DL_ASTRAL)
end

--- One WQ beat after every hit: bank the damage, hold the death-guard floors, and transition
--- when the phase's damage budget is spent.
local function checkPhase(actor, damage)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end
    local key = Utils.ActorKey(actor)
    if not key then return end
    local st = phaseState[key]
    if not st then st = { Phase = 1, Dealt = 0 }; phaseState[key] = st end

    -- The meter: aim-independent, and clamp-voided damage still counts (a pool-camper whose
    -- hits are being floored is still fighting the boss).
    st.Dealt = (st.Dealt or 0) + (tonumber(damage) or 0)

    -- Death guard: each pool held at the CURRENT phase's floor (raise-only).
    local fh, ft = floorsFor(st.Phase)
    if fh then
        local h, t = currentHp(actor)
        if h < fh or t < ft then writeHp(actor, math.max(h, fh), math.max(t, ft)) end
    end

    -- Budget triggers. The transition WRITES both pools down to the phase mark, so however
    -- the damage was aimed, every phase starts from the same statline and the nameplate
    -- coherently drops to "66%" / "33%".
    local head, torso = hpPools()
    local budget = head + torso
    if st.Phase == 1 and st.Dealt >= budget * PHASE2_AT_FRAC then
        writeHp(actor, head * PHASE2_FRAC, torso * PHASE2_FRAC)
        enterAstral(actor, key, st)
    elseif st.Phase == 3 and st.Dealt >= budget * PHASE4_AT_FRAC then
        writeHp(actor, head * PHASE4_FRAC, torso * PHASE4_FRAC)
        enterAstral(actor, key, st)
    end
end

--- [RENDERER-LOCAL] The astral-hold sheen: a red-orange AttachShieldShell, built lazily
--- (nil = mesh not streamed, retry next cadence - never latch), toggled with the hold.
local function setShell(actor, key, on)
    local shell = magusShell[key]
    if on and not (shell ~= nil and Utils.IsComponentValid(shell)) then
        shell = AVU.AttachShieldShell(actor, nil,
            { Color = SHELL_COLOR, Base = SHELL_COLOR, Outline = SHELL_COLOR, Glow = SHELL_GLOW })
        if shell then magusShell[key] = shell end
    end
    if shell ~= nil and Utils.IsComponentValid(shell) then
        pcall(function() shell:SetVisibility(on, false) end)
    end
end

--- [RENDERER-LOCAL] Host reads the phase directly; a pure client reads the replicated signal.
local function mirrorShell(actor, key)
    local astral
    if Utils.IsAuthority() then
        local p = phaseOf(key)
        astral = (p == 2 or p == 4)
    else
        astral = (VS.Read(actor, SIG_ASTRAL) or 0) >= 1
    end
    setShell(actor, key, astral)
end


-- =======================================================================
-- FIRE-PATCH BOOST (the lockdown half of the volley)
-- =======================================================================
local PATCH_SECS         = 20      -- boosted fire-patch lifetime (native EffectDuration 5)
local PATCH_BOOST_MS     = 100     -- let FinishSpawning/BeginPlay arm the stock delay first

--- [AUTHORITY, WQ drain] Stretch a freshly-spawned plasma patch if a DarkLens Mage made it.
local function boostPatch(patch)
    if not STATE.ModEnabled then return end
    if Utils.IsActorInvalid(patch) then return end
    local inst
    pcall(function() inst = patch.Instigator end)
    if inst == nil or Utils.GetActorRowName(inst) ~= "DarkLens_Mage" then return end
    pcall(function()
        patch.EffectDuration = PATCH_SECS
        patch:ResetDuration()   -- the lifetime delay was armed with the stock 5 in BeginPlay;
                                -- ResetDuration re-triggers it with the value we just wrote
    end)
end

--- [AUTHORITY] Arm the patch watcher once per session (patches only spawn server-side).
local function armPatchBoost()
    if patchNotifyArmed then return end
    patchNotifyArmed = true
    NotifyOnNewObject(ENUMS.Components.AREA_PLASMA_FIRE, function(patch)
        -- NOTHING in the notify itself (the Coworker rule) - just book the boost.
        Utils.QueueWork(function() boostPatch(patch) end, PATCH_BOOST_MS)
    end)
end


-- =======================================================================
-- FIREBALL VOLLEY
-- =======================================================================

-- The fireball volley (area denial - the patches are the point, not the direct hits).
local VOLLEY_CHECK_TICKS = 10      -- OnTick check (every 1s)
local VOLLEY_CD_TICKS    = 100     -- volley cooldown
local VOLLEY_RANGE_SQ    = 4500 ^ 2 -- volley area
local VOLLEY_SHOTS       = 7       -- number of projectiles
local VOLLEY_FIRST_MS    = 600     -- montage windup before shot 0 (native FireballDelay is 0.5)
local VOLLEY_GAP_MS      = 200
local VOLLEY_SPREAD      = 650     -- scatter half-extent (uu) -> ~13m footprint
local VOLLEY_HORIZ_SPEED = 1000    -- "a bit slower than the base fireball" (row speed 1500)
local VOLLEY_FLIGHT_MIN  = 0.8     -- LobFlightTime clamp - the real speed/readability knob
local VOLLEY_FLIGHT_MAX  = 2.2
local VOLLEY_DMG         = 60      -- direct-hit only
local VOLLEY_DMG_HARD    = 120     -- the area-denial pattern becomes a real threat to stand in

--- One lobbed shell. Re-validates per shot (the caster can die mid-volley).
local function launchVolleyShot(actor, cx, cy, cz, index, ignore)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end

    local muzzle
    pcall(function() muzzle = actor.Mesh:GetSocketLocation(FName("l_hand")) end)
    if not muzzle or (muzzle.X == 0 and muzzle.Y == 0 and muzzle.Z == 0) then
        muzzle = actor:K2_GetActorLocation()
        muzzle.Z = muzzle.Z + 80
    end

    -- Shot 0 on the mark; the rest scattered over the lockdown footprint. Impacts aim at the
    -- TARGET's ground height - the patch traces its own floor from wherever the shell lands.
    local at = FVector(cx, cy, cz)
    if index > 0 then at = AVM.ScatterPoint(at, VOLLEY_SPREAD, 0) end

    local t = AVM.LobFlightTime(muzzle, at, VOLLEY_HORIZ_SPEED, VOLLEY_FLIGHT_MIN, VOLLEY_FLIGHT_MAX)
    local vel = AVM.LobVelocity(muzzle, at, t)
    local speed = math.sqrt(vel.X * vel.X + vel.Y * vel.Y + vel.Z * vel.Z)
    if speed < 1 then return end
    local dir = FVector(vel.X / speed, vel.Y / speed, vel.Z / speed)

    PROJ.Queue(muzzle, dir, ENUMS.ProjectileClasses.MageFireball, nil, {
        Owner = actor,                             -- Instigator defaults to Owner - the patch's
                                                   --   IgnoreInstigatorAndAllies NEEDS it set
        Damage = STATE.HardModeNoMercy and VOLLEY_DMG_HARD or VOLLEY_DMG,
        Velocity = speed,
        MaxSpeed = 999999,                         -- the row caps at 1500; a lob must survive
        GravityScale = 1,                          -- the arc solve assumes full gravity (row 0.1)
        FlightRow = ENUMS.ProjectileRows.FireballLob,   -- ...and so must a client's copy
        DamageTypeClass = ENUMS.DamageType.FirePlasma,
        IgnoreGroup = ignore,                      -- shells launched over the same shoulder
        _traceName = "magusVolley",
    })
end

--- Cast: telegraph montage, quiet the bolt filler, stagger the shells out.
local function fireVolley(actor, key, tl)
    local cx, cy, cz = tl.X, tl.Y, tl.Z   -- aim frozen BY VALUE - this is the dodge window

    ASSETS.WarmPinned(M.VOLLEY_DEPS)   -- S3 re-warm; free when resident/pinned
    AVU.PlayMontageReplicated(actor, ENUMS.Anims.MAGE_FIREBALL, 1, true)
    quietBolt(key, VOLLEY_FIRST_MS + VOLLEY_SHOTS * VOLLEY_GAP_MS + 400)

    local ignore = {}
    for i = 0, VOLLEY_SHOTS - 1 do
        Utils.QueueWork(function() launchVolleyShot(actor, cx, cy, cz, i, ignore) end,
            VOLLEY_FIRST_MS + i * VOLLEY_GAP_MS)
    end
end

--- [AUTHORITY, cadenced from OnTick] All the gates, then the cast.
local function tryVolley(actor)
    local key = Utils.ActorKey(actor)
    if not key or isBusy(key) or not allows(key, "volley") then return end
    -- Peek: the stamp lands only after every later gate passes (the CooldownReady rule).
    if not AVU.CooldownReady(volleyTick, key, cdTicks(key, VOLLEY_CD_TICKS), { Peek = true }) then return end

    local inCombat = false
    pcall(function() inCombat = actor.CombatState end)
    if not inCombat then return end

    -- Mid-choke the grab montage owns the body - stomping it strands the victim attached.
    local holding
    pcall(function() holding = actor.HoldingCharacter end)
    if holding ~= nil and Utils.IsActorValid(holding) then return end

    local target = AVU.GetCurrentTarget(actor)
    if not target then return end
    local tl
    pcall(function() tl = target:K2_GetActorLocation() end)
    if not tl then return end
    if Utils.DistSq(actor:K2_GetActorLocation(), tl) > VOLLEY_RANGE_SQ then return end

    AVU.CooldownReady(volleyTick, key, cdTicks(key, VOLLEY_CD_TICKS))   -- stamp
    setBusy(key, math.floor((VOLLEY_FIRST_MS + VOLLEY_SHOTS * VOLLEY_GAP_MS) / 100) + GAP_TICKS)
    fireVolley(actor, key, tl)
end


-- =======================================================================
-- EYE BEAM (focus -> fire at the shadow -> chase)
-- =======================================================================

-- The eye beam (focus a random player, fire at their shadow 1s later, then slowly chase them).
local BEAM_CD_TICKS    = 250       -- ~24s between channels
local BEAM_FIRST_TICKS = 80        -- first channel ~8s into the fight (never the opener)
local BEAM_RANGE_SQ    = 2600 ^ 2  -- focus-pick radius (random player inside this)
local BEAM_HOLD_MS     = 1000      -- lit at the focus spot, held - THE dodge cue
local BEAM_CHASE_MS    = 6000      -- how long the beam follows before it dies
local BEAM_SPEED       = 450       -- beam chase speed
local BEAM_SPEED_HARD  = 550       -- still under a sprint, so running away still works
local BEAM_STEP_MS     = 100
local BEAM_TRACE_SEC   = 0.05      -- component re-trace: steered beams need it (native dmg is 0)
local BEAM_RADIUS      = 240       -- GAMEPLAY thickness (SweptBeamHits) - the "bigger beam" knob
local BEAM_DMG         = 100       -- per crossing
local BEAM_DMG_HARD    = 125
local BEAM_REHIT_TICKS = 10        -- same victim hittable again after this (standing in it BURNS)
local BEAM_IGNITE_S    = 4         -- blue-fire rider on a crossing
-- The block pose is re-played all channel long, on the montage's OWN measured length minus this
-- lead (so the restart lands before the blend-out shows the idle underneath). BEAM_POSE_MS is
-- only the fallback if the measurement ever fails.
local BEAM_POSE_LEAD_S = 0.35
local BEAM_POSE_MIN_MS = 400
local BEAM_POSE_MS     = 1500
-- Emitter origin relative to the HEAD bone, whose local frame is FVector(side, -up, forward)
-- ([[af-head-bone-local-axes]]: +Z out the face, -Y up, X lateral). This targets the glowing
-- LEFT eye - if it renders out the RIGHT eye, flip the X sign; tune magnitudes in-game.
local BEAM_EYE_OFFSET  = FVector(6, -6, 9)

--- One RANDOM living player inside the focus radius (the GameState array, never FindAllOf).
local function pickBeamTarget(al)
    local gs = STATE.GameState
    local players = IsValid(gs) and gs.PlayerCharacterInGame
    if not players then return nil end
    local pool = {}
    for i = 1, #players do
        local p = players[i]
        if Utils.IsActorValid(p) and not Utils.IsDeadSafe(p) then
            local pl
            pcall(function() pl = p:K2_GetActorLocation() end)
            if pl and Utils.DistSq(al, pl) <= BEAM_RANGE_SQ then pool[#pool + 1] = p end
        end
    end
    if #pool == 0 then return nil end
    return pool[math.random(1, #pool)]
end

--- The channel: light the beam on the victim's shadow, hold 1s, then chase the LIVE victim.
--- All exits funnel through OnFinish exactly once.
local function startBeam(actor, key, victim)
    local vl
    pcall(function() vl = victim:K2_GetActorLocation() end)
    if not vl then return end
    local p0 = FVector(vl.X, vl.Y, vl.Z - 88)   -- their feet at the moment of focus

    -- Channel stance NOW (not in the load callback): the tell must not lag the decision.
    -- The channel OWNS the body: the ghost-bolt filler is quiet for its whole span (the old
    -- native fireball kept firing mid-beam, which also flickered the beam invisible - any
    -- other montage mid-channel breaks the pose) and melee is suppressed.
    AVU.HoldStill(actor, true)
    quietBolt(key, BEAM_HOLD_MS + BEAM_CHASE_MS + 500)
    AVU.SuppressMelee(actor, BEAM_HOLD_MS + BEAM_CHASE_MS + 500)

    ASSETS.LoadAsync(M.BEAM_DEPS, function(results)
        if Utils.IsActorInvalid(actor) or actor.IsDead then
            if Utils.IsActorValid(actor) then AVU.HoldStill(actor, false) end
            return
        end

        -- Measure the block pose ONCE (the asset is right here in the load results): its own
        -- play length minus the lead is the re-play cadence that never shows the idle under it.
        if beamPoseMs == nil then
            local len
            local blk = results and results[ENUMS.Anims.MAGE_BLOCK]
            if IsValid(blk) then pcall(function() len = tonumber(blk:GetPlayLength()) end) end
            if len and len > 0 then
                beamPoseMs = math.max(BEAM_POSE_MIN_MS, math.floor((len - BEAM_POSE_LEAD_S) * 1000))
            else
                beamPoseMs = BEAM_POSE_MS
            end
            Utils.LogDebug(string.format("Magus beam - block pose %.2fs -> re-play every %dms",
                len or -1, beamPoseMs), SETTINGS.DEBUG_NPC_ACTIONS)
        end

        -- The block/brace pose: stabilises the HEAD, which is where the beam originates.
        -- Played HERE (post-load) so a first cast can't skip it non-resident.
        -- (The Chieftain combat-fire montage was tried and does NOT retarget to this rig.)
        AVU.PlayMontageReplicated(actor, ENUMS.Anims.MAGE_BLOCK, 1, true)

        -- Out of the glowing LEFT eye: head bone + the eye offset (bone frame - see the knob).
        local made = Lasers.FireBurst(actor, "head", {
            Count = 1, AimAt = p0,
            Location = BEAM_EYE_OFFSET,
            Damage = 0,                                   -- hits are scripted (S6 hop) below
            Duration = BEAM_HOLD_MS + BEAM_CHASE_MS + 500,
            MaxDistance = 20000,
            TraceInterval = BEAM_TRACE_SEC,
            Style = M.BEAM_STYLE,
        })
        local comp = made and made[1]
        if not Utils.IsComponentValid(comp) then
            Utils.LogBad("Magus beam - FireBurst yielded no component (deps cold?)")
            AVU.HoldStill(actor, false)
            return
        end
        local chan = {}          -- this channel's token: a stale pose loop from an ended
        beamOn[key] = chan       --   channel sees a different (or no) token and stops

        -- The pose loop: its OWN clock on the measured cadence, from the first play - not the
        -- sweep's steps, which only start BEAM_HOLD_MS in (longer than the pose may be).
        local function holdPose()
            if beamOn[key] ~= chan then return end
            if Utils.IsActorInvalid(actor) or actor.IsDead then return end
            AVU.PlayMontageReplicated(actor, ENUMS.Anims.MAGE_BLOCK, 1, true)
            Utils.QueueWork(holdPose, beamPoseMs or BEAM_POSE_MS)
        end
        Utils.QueueWork(holdPose, beamPoseMs or BEAM_POSE_MS)

        -- Fire-loop SFX (HOST/SP-local, like the beam colour); OnStep moves it, OnFinish stops it.
        local snd
        pcall(function()
            local wave = ASSETS.GetIfValid(ENUMS.SOUNDS.HEAVY_LASER_FIRE)
            local gs = UEHelpers.GetGameplayStatics()
            local world = Utils.GetWorld()
            if IsValid(wave) and gs and IsValid(world) then
                -- bAutoDestroy=FALSE: OnStep rides this wrapper for the whole chase, and the fire
                -- cue is shorter than the sweep - with the engine owning it, it frees mid-chase
                -- and every later move is a use-after-free. OnFinish is the sole owner instead.
                snd = gs:SpawnSoundAtLocation(world, wave, FVector(p0.X, p0.Y, p0.Z + 90),
                    FRotator(0, 0, 0), 2.0, 1.0, 0.0, nil, nil, false)
            end
        end)

        local hit = {}   -- victim key -> last-hit FAST_TICK (re-hittable: BEAM_REHIT_TICKS)

        Lasers.SteeredSweep(actor, comp, {
            From = p0,
            -- Slower than a sprint at both rungs: running away works
            Speed = STATE.HardModeNoMercy and BEAM_SPEED_HARD or BEAM_SPEED,
            Radius = BEAM_RADIUS, StepMs = BEAM_STEP_MS, MaxMs = BEAM_CHASE_MS,
            FirstDelayMs = BEAM_HOLD_MS,   -- lit on the shadow, held - the dodge cue
            Arrive = false,                -- chase: snap-follow until the clock ends it

            -- Follow the LIVE victim's feet - riding their actual Z is what keeps the beam on
            -- the ground (a frozen Z sweeps midair on any slope). Victim gone/dead = finish.
            Heading = function()
                if Utils.IsActorInvalid(victim) or Utils.IsDeadSafe(victim) then return nil end
                local tl
                pcall(function() tl = victim:K2_GetActorLocation() end)
                if not tl then return nil end
                return FVector(tl.X, tl.Y, tl.Z - 88)
            end,

            -- The mage turns WITH the beam - the whole read of the ability. The pose itself is
            -- holdPose's job (above); this re-asserts HoldStill EVERY step, because
            -- PlayThirdPersonMontage's lockInPlace clears when its montage ENDS, which was
            -- un-parking the BT mid-channel (the boss kept attacking through the beam).
            OnStep = function(_, pt)
                AVU.FaceSpot(actor, pt)
                AVU.HoldStill(actor, true)
                pcall(function()
                    if snd then snd:K2_SetWorldLocation(FVector(pt.X, pt.Y, pt.Z + 80), false, {}, false) end
                end)
            end,

            Hits = {
                -- Players only (default); escorts and pets are spared. ANY player crossed mid-
                -- chase counts, not just the focus - and standing IN the beam re-hits every
                -- BEAM_REHIT_TICKS.
                Skip = function(v)
                    local k = Utils.ActorKey(v)
                    if k == nil then return true end
                    local last = hit[k]
                    return last ~= nil and (STATE.FAST_TICK - last) < BEAM_REHIT_TICKS
                end,
            },

            OnHit = function(caught)
                local k = Utils.ActorKey(caught)
                if k then hit[k] = STATE.FAST_TICK end
                AVU.PointDamageOffHook(actor, caught,
                    STATE.HardModeNoMercy and BEAM_DMG_HARD or BEAM_DMG, ENUMS.DamageType.Laser)
                Utils.ApplyBuffLinked(caught, ENUMS.Debuffs.IgnitedPlasma, BEAM_IGNITE_S)
            end,

            OnFinish = function()
                beamOn[key] = nil            -- also stops holdPose (token mismatch)
                -- Sole owner of the cue (bAutoDestroy=false at spawn), so free it here too.
                pcall(function()
                    if Utils.IsComponentValid(snd) then
                        snd:Stop()
                        snd:K2_DestroyComponent(snd)
                    end
                end)
                if Utils.IsActorValid(actor) then AVU.HoldStill(actor, false) end
                if Utils.IsComponentValid(comp) then
                    pcall(function()
                        comp.LaserActive = false
                        Utils.MarkReplicatedDirty(comp, "LaserActive")
                        comp:OnRep_LaserActive()
                    end)
                end
            end,
        })
    end)
end

--- [AUTHORITY, cadenced from OnTick] Gates, then the channel on a RANDOM in-range player.
local function tryBeam(actor)
    local key = Utils.ActorKey(actor)
    if not key or isBusy(key) or not allows(key, "beam") then return end
    if beamTick[key] == nil then
        beamTick[key] = STATE.FAST_TICK - BEAM_CD_TICKS + BEAM_FIRST_TICKS
    end
    if not AVU.CooldownReady(beamTick, key, cdTicks(key, BEAM_CD_TICKS), { Peek = true }) then return end

    local inCombat = false
    pcall(function() inCombat = actor.CombatState end)
    if not inCombat then return end

    local holding
    pcall(function() holding = actor.HoldingCharacter end)
    if holding ~= nil and Utils.IsActorValid(holding) then return end   -- never mid-choke

    local victim = pickBeamTarget(actor:K2_GetActorLocation())
    if not victim then return end

    AVU.CooldownReady(beamTick, key, cdTicks(key, BEAM_CD_TICKS))   -- stamp
    setBusy(key, math.floor((BEAM_HOLD_MS + BEAM_CHASE_MS) / 100) + GAP_TICKS)
    startBeam(actor, key, victim)
end


-- =======================================================================
-- FORCE CHOKE (stun + reel-in -> native grab chain -> sky toss)
-- =======================================================================

local FC_CD_TICKS      = 300       -- ~30s between chokes (it ALSO opens each post-astral phase)
local FC_FIRST_TICKS   = 140       -- first choke ~14s in
local FC_MIN_SQ        = 650 ^ 2   -- range it tries to do this
local FC_MAX_SQ        = 2300 ^ 2
local FC_MAX_DZ        = 500       -- trajectory sanity: no cross-floor pulls (the arena's tiers
                                   --   put a target up to ~5m above/below the boss)
local FC_PULL_AT_MS    = 500       -- grab-start montage opens the tell; the yank lands mid-reach
local FC_STUN_S        = 2.2       -- covers lift + reel + the seize (was 1.5 for the one-shove pull)
-- The yank is TWO impulses (a single toward-shove sent a HIGHER target sailing over the head):
--   1. the LIFT - straight up, XY zeroed (it also halts a sprinter dead)
--   2. the REEL, FC_REEL_AT_MS later - a SOLVED lob (AVM.LobVelocity, both axes overridden) from
--      wherever they are to FC_LAND_AHEAD in front of the boss AT ITS HEIGHT, in a flight time
--      clamped from range - so the second leg always angles DOWN onto the boss, whatever the tier.
local FC_LIFT_UP       = 1800       -- ~2m of lift; still rising a little when the reel takes over
local FC_REEL_AT_MS    = 500
local FC_REEL_SPEED    = 2600      -- flight time = range / this, clamped:
local FC_REEL_T_MIN    = 0.45      --   (a close target isn't an instant snap)
local FC_REEL_T_MAX    = 0.80      --   (a far one still arrives before the stun lapses)
local FC_LAND_AHEAD    = 130       -- landing spot: this far in front of the boss, on the pull line
local FC_SEIZE_SLACK_MS = 150      -- after the solved arrival: in reach? seize
local FC_GRAB_NEAR_SQ  = 450 ^ 2   -- arrived close enough to count as caught (whiff otherwise)
-- The redundancy: a second after the expected arrival, a victim STILL far away was carried off
-- (over an edge, off a ledge, into the void) - put them in front of the boss and seize.
local FC_RESCUE_AFTER_MS = 1000
local FC_RESCUE_FAR_SQ   = 1000 ^ 2   -- ">10m away" = the pull went wrong
local FC_RESCUE_AHEAD    = 200        -- teleport spot: this far in front of the boss
local FC_WATCH_MS      = 300       -- release poll cadence
local FC_MAX_HOLD_MS   = 5000      -- softlock guard: force-drop past this
local FC_TOSS_DELAY_MS = 150       -- let the release restore the victim's movement first
local FC_TOSS_HORIZ    = 320       -- impulse push after its done doing its choke attack
local FC_TOSS_UP       = 800       --
local FC_SUPPRESS_MS   = 4000      -- no native melee mid-sequence
local FC_BUSY_TICKS    = 60

--- Is the mage currently holding THIS victim?
local function isHolding(actor, target)
    local held = false
    pcall(function()
        local h = actor.HoldingCharacter
        held = h ~= nil and Utils.IsActorValid(h) and Utils.ActorKey(h) == Utils.ActorKey(target)
    end)
    return held
end

--- The pushback: gentle out, more up than out - the air time is the ledge safety.
local function tossVictim(actor, target)
    if Utils.IsActorInvalid(target) or target.IsDead then return end
    local pivot
    pcall(function() pivot = actor:K2_GetActorLocation() end)
    if not pivot then pcall(function() pivot = target:K2_GetActorLocation() end) end
    if not pivot then return end
    AVU.KnockbackFrom(target, pivot, FC_TOSS_HORIZ, FC_TOSS_UP, false, { OverrideXY = true })
end

--- Release watch: the native choke drops the victim IN PLACE (no native throw) - we add the
--- toss on that transition, and force the drop past the softlock ceiling.
local function watchChoke(actor, target, elapsed)
    if Utils.IsActorInvalid(actor) then
        Utils.QueueWork(function() tossVictim(actor, target) end, FC_TOSS_DELAY_MS)
        return
    end
    if not isHolding(actor, target) then
        Utils.QueueWork(function() tossVictim(actor, target) end, FC_TOSS_DELAY_MS)
        return
    end
    if elapsed >= FC_MAX_HOLD_MS then
        -- An unreleased grab SOFTLOCKS the player (the GK_MageHelpers lesson).
        pcall(function() actor:DropHoldingCharacter() end)
        Utils.QueueWork(function() tossVictim(actor, target) end, FC_TOSS_DELAY_MS)
        return
    end
    Utils.QueueWork(function() watchChoke(actor, target, elapsed + FC_WATCH_MS) end, FC_WATCH_MS)
end

--- Both live locations, or nil if either body is gone/dead.
local function pairLocations(actor, target)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return nil end
    if Utils.IsActorInvalid(target) or target.IsDead then return nil end
    local al, tl
    pcall(function() al = actor:K2_GetActorLocation() end)
    pcall(function() tl = target:K2_GetActorLocation() end)
    if not al or not tl then return nil end
    return al, tl
end

--- A spot `ahead` uu in front of the boss on the boss->victim line (XY), at the boss's height.
local function spotBefore(al, tl, ahead)
    local nx, ny = AVM.Normalize2D(tl.X - al.X, tl.Y - al.Y)
    return FVector(al.X + nx * ahead, al.Y + ny * ahead, al.Z)
end

--- After the reel's solved arrival: did the native grab window take them? If not and they're
--- in reach, seize directly. Only a CONFIRMED hold gets the release watch - a whiff must never
--- toss.
local function seizeVictim(actor, target)
    local al, tl = pairLocations(actor, target)
    if not al then return end

    if not isHolding(actor, target) then
        if Utils.DistSq(al, tl) > FC_GRAB_NEAR_SQ then return end   -- pull dodged/blocked: whiff
        pcall(function() actor:Server_PerformGrabHoldSequence(target) end)
    end

    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) then return end
        if isHolding(actor, target) then watchChoke(actor, target, 0) end
    end, 200)
end

--- The redundancy, a second after the expected arrival: a victim neither held nor anywhere near
--- was CARRIED OFF (over the boss's head, off a tier, into the void). Teleport them in front of
--- the boss (Utils.TeleportPlayer, the EIGT player-teleport; a player hop cold-loads) and let the
--- seize have its normal go - the held check here is belt. Never fires for a pull that whiffed
--- cleanly; the caller only schedules it once the reel has actually launched them.
local function rescueVictim(actor, target)
    local al, tl = pairLocations(actor, target)
    if not al then return end
    if isHolding(actor, target) then return end
    if Utils.DistSq(al, tl) <= FC_RESCUE_FAR_SQ then return end

    local spot = spotBefore(al, tl, FC_RESCUE_AHEAD)
    local face = Utils.RotatorToTarget(FVector(spot.X, spot.Y, 0), FVector(al.X, al.Y, 0))
    Utils.LogDebug("Magus choke - victim carried off, rescuing in front of the boss",
        SETTINGS.DEBUG_NPC_ACTIONS)
    Utils.TeleportPlayer(target, spot, face)
    Utils.QueueWork(function() seizeVictim(actor, target) end, 200)   -- after the EIGT hop lands
end

--- Impulse 2, the REEL: from wherever the lift left them, the exact lob that lands them in
--- front of the boss at its own height, in a range-clamped flight time. Both axes overridden -
--- the solved arc REPLACES whatever the lift/gravity had them doing. Then the seize on the
--- solved arrival, and the rescue check a second after that.
local function reelVictim(actor, target)
    local al, tl = pairLocations(actor, target)
    if not al then return end

    local land = spotBefore(al, tl, FC_LAND_AHEAD)
    local t = AVM.LobFlightTime(tl, land, FC_REEL_SPEED, FC_REEL_T_MIN, FC_REEL_T_MAX)
    AVU.KnockbackVelocity(target, AVM.LobVelocity(tl, land, t, 1))

    local arriveMs = math.floor(t * 1000)
    Utils.QueueWork(function() seizeVictim(actor, target) end, arriveMs + FC_SEIZE_SLACK_MS)
    Utils.QueueWork(function() rescueVictim(actor, target) end, arriveMs + FC_RESCUE_AFTER_MS)
end

--- Impulse 1, the LIFT, at the montage's mid-reach: stun + straight up with XY zeroed (a
--- sprinter is halted dead), then the reel FC_REEL_AT_MS later. Re-checks the corridor at the
--- moment of the pull - cover reached since the tell = a clean whiff (nothing launched, so no
--- reel, no seize, no rescue).
local function pullVictim(actor, target)
    local al, tl = pairLocations(actor, target)
    if not al then return end
    if AVU.IsPathBlocked(actor, FVector(al.X, al.Y, al.Z + 55),
            FVector(tl.X, tl.Y, tl.Z + 55), { actor, target }) then return end

    Utils.ApplyBuffLinked(target, ENUMS.Debuffs.ParryStun, FC_STUN_S, actor)
    AVU.KnockbackFrom(target, al, 0, FC_LIFT_UP, true, { OverrideXY = true })

    Utils.QueueWork(function() reelVictim(actor, target) end, FC_REEL_AT_MS)
end

--- The cast: montage tell + tether FX, then the timed chain.
local function forceChoke(actor, key, target, al, tl)
    ASSETS.LoadAsync(M.CHOKE_DEPS, function()
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        if Utils.IsActorInvalid(target) or target.IsDead then return end

        -- The grab-start montage IS the windup tell - and its AnimNotify arms the native
        -- grab-overlap window the victim is about to be reeled into.
        AVU.PlayMontageReplicated(actor, ENUMS.Anims.MAGE_GRAB_START, 1, true)
        AVU.SendClientBeam(FVector(al.X, al.Y, al.Z + 55), FVector(tl.X, tl.Y, tl.Z + 55),
            "EXOR_BEAM_CHA", 1)
        quietBolt(key, FC_SUPPRESS_MS)   -- (a held victim keeps it quiet past this - tryBolt)
        AVU.SuppressMelee(actor, FC_SUPPRESS_MS)

        Utils.QueueWork(function() pullVictim(actor, target) end, FC_PULL_AT_MS)
    end)
end

--- [AUTHORITY, cadenced from OnTick] Gates: a PLAYER target in the pull band, level with us,
--- clear corridor. Then the cast.
local function tryForceChoke(actor)
    local key = Utils.ActorKey(actor)
    if not key then return end

    -- The phase opener bypasses busy + cooldown (endAstral's blackout is what the bypass
    -- rides through); it expires if no valid pull target shows up in the window.
    local st = phaseState[key]
    local opener = st ~= nil and st.OpenerUntil ~= nil
    if opener and STATE.FAST_TICK > st.OpenerUntil then
        st.OpenerUntil = nil
        opener = false
    end

    if not opener then
        if isBusy(key) or not allows(key, "choke") then return end
        if chokeTick[key] == nil then
            chokeTick[key] = STATE.FAST_TICK - FC_CD_TICKS + FC_FIRST_TICKS
        end
        if not AVU.CooldownReady(chokeTick, key, cdTicks(key, FC_CD_TICKS), { Peek = true }) then return end
    end

    local inCombat = false
    pcall(function() inCombat = actor.CombatState end)
    if not inCombat then return end

    local holding
    pcall(function() holding = actor.HoldingCharacter end)
    if holding ~= nil and Utils.IsActorValid(holding) then return end

    local target = AVU.GetCurrentTarget(actor)
    if not target then return end
    if Utils.GetActorRowName(target) ~= nil then return end   -- row name = an NPC; players only

    local tl
    pcall(function() tl = target:K2_GetActorLocation() end)
    if not tl then return end
    local al = actor:K2_GetActorLocation()
    local d2 = Utils.DistSq(al, tl)
    if d2 < FC_MIN_SQ or d2 > FC_MAX_SQ then return end
    if math.abs(tl.Z - al.Z) > FC_MAX_DZ then return end
    if AVU.IsPathBlocked(actor, FVector(al.X, al.Y, al.Z + 55),
            FVector(tl.X, tl.Y, tl.Z + 55), { actor, target }) then return end

    if opener then st.OpenerUntil = nil end
    AVU.CooldownReady(chokeTick, key, cdTicks(key, FC_CD_TICKS))   -- stamp (opener starts the CD too)
    setBusy(key, FC_BUSY_TICKS + GAP_TICKS)
    forceChoke(actor, key, target, al, tl)
end


-- =======================================================================
-- GHOST-BOLT (the regular attack of BOTH bodies - the Magus and its Astral add)
-- =======================================================================

-- The ghost-bolt: the REGULAR attack of both the Magus and its Astral add (native ranged is
-- suppressed on both). Ours end to end: a straight, gravity-free shadow-orb carrier.
local BOLT_TICKS    = 20        -- one bolt every ~2s
local BOLT_SPEED    = 700       -- straight line, gravity 0
local BOLT_DMG      = 75        -- Electricity
local BOLT_RANGE_SQ = 4500 ^ 2
local BOLT_TELL_MS  = 500       -- Magus only: fireball montage as the tell, bolt this far in
                                --   (the native FireballDelay); the add's meditate pose is
                                --   single-node, so it fires bare

--- [AUTHORITY] One bolt at the current target: straight, gravity-free, our damage - the
--- shadow-orb class as the carrier with its mesh hidden and the ChargeUp niagara welded on as
--- the visible body. Re-validates everything (the caller may have queued it a tell ago).
--- Its look (hidden orb, charge-up trail, 0.7) rides the GhostOrb row, so a remote client dresses
--- its own copy too.
local function ghostBolt(actor)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end
    local target = AVU.GetCurrentTarget(actor)
    if not target then return end
    local tl
    pcall(function() tl = target:K2_GetActorLocation() end)
    if not tl then return end
    local al = actor:K2_GetActorLocation()
    if not al or Utils.DistSq(al, tl) > BOLT_RANGE_SQ then return end

    local muzzle
    pcall(function() muzzle = actor.Mesh:GetSocketLocation(FName("l_hand")) end)
    if not muzzle or (muzzle.X == 0 and muzzle.Y == 0 and muzzle.Z == 0) then
        muzzle = FVector(al.X, al.Y, al.Z + 60)
    end
    local dir = Utils.Direction(muzzle, FVector(tl.X, tl.Y, tl.Z + 30))
    if not dir then return end

    PROJ.Queue(muzzle, dir, ENUMS.ProjectileClasses.ShadowOrbVacuum, nil, {
        Owner = actor,
        Damage = BOLT_DMG,
        Velocity = BOLT_SPEED,
        GravityScale = 0,
        DamageTypeClass = ENUMS.DamageType.Electric,
        FlightRow = ENUMS.ProjectileRows.GhostOrb,
        _traceName = "ghostBolt",
    })
end

--- [AUTHORITY, cadenced from MagusTick] The Magus's filler: in combat, with a target in range,
--- and nothing else owning the body (a scripted move's quiet window, a beam channel, a held
--- victim). Fireball montage as the tell, the bolt BOLT_TELL_MS in - the native cadence's read.
local function tryBolt(actor, key)
    if boltQuiet(key) or beamOn[key] then return end
    local inCombat = false
    pcall(function() inCombat = actor.CombatState end)
    if not inCombat then return end
    local holding
    pcall(function() holding = actor.HoldingCharacter end)
    if holding ~= nil and Utils.IsActorValid(holding) then return end

    local target = AVU.GetCurrentTarget(actor)
    if not target then return end
    local tl
    pcall(function() tl = target:K2_GetActorLocation() end)
    if not tl or Utils.DistSq(actor:K2_GetActorLocation(), tl) > BOLT_RANGE_SQ then return end

    -- UNLOCKED (lockInPlace=false): the body is pinned anyway, and a locked montage every 2s
    -- would hold IsNPCBusy() (LockedInPlaceMontage) nearly all fight, parking the BT's own
    -- combat-state tasks. The gates above keep this out of every window a lock matters in.
    AVU.PlayMontageReplicated(actor, ENUMS.Anims.MAGE_FIREBALL, 1, false)
    Utils.QueueWork(function()
        -- A move that started during the tell owns the body now - the bolt yields to it.
        if boltQuiet(key) or beamOn[key] then return end
        ghostBolt(actor)
    end, BOLT_TELL_MS)
end


-- =======================================================================
-- ASTRAL MAGUS (the phase add - a spirit copy on the base Mystagogue)
-- =======================================================================

-- Spirit look: washed cyan overdrive + half opacity, re-asserted on a cadence (damage-stage
-- texture rebuilds drop material params).
local ASTRAL_LOOK = {
    Ticks    = 30,                  -- renderer re-assert cadence (opacity/tint/pose)
    Opacity  = 0.5,                 -- honoured only if the master material reads Opacity - test
    Tint     = FVector(0, 20, 30),  -- washed cyan overdrive (Groupe-style)
    Emissive = 1,
}
local ASTRAL_TETHER_TICKS  = 50    -- soul-tether pulse to the sealed Magus (~5s)
local ASTRAL_PING_CD_TICKS = 10    -- shield-break ping on immune hits (1s throttle)
-- Scripted side-strafe on damage: the meditate pose is single-node, so MONTAGE dodges can never
-- play - the strafe IS its dodge. Fast and low: barely any lift, a sideways slide.
local ASTRAL_DODGE = {
    Chance  = 0.75,
    CdTicks = 30,
    Speed   = 1300,
    Up      = 60,
}

--- [RENDERER-LOCAL] The spirit look: washed cyan overdrive + half opacity. Re-asserted on a
--- cadence (damage-stage texture rebuilds drop material params).
local function applyAstralLook(actor)
    AVU.SetMeshOpacity(actor, ASTRAL_LOOK.Opacity)
    AVU.TintMesh(actor, { Color = ASTRAL_LOOK.Tint, Emissive = ASTRAL_LOOK.Emissive })
end

--- [AUTHORITY] The soul-tether pulse: a burst at the midpoint between the add and its sealed
--- Magus. A test-spawned astral has no owner and simply never pulses.
local function astralTether(actor)
    local ak = Utils.ActorKey(actor)
    local mk = ak and astralToMagus[ak] or nil
    local st = mk and phaseState[mk] or nil
    local magus = st and st.Actor or nil
    if magus == nil or not Utils.IsActorValid(magus) or magus.IsDead then return end
    local a, m
    pcall(function() a = actor:K2_GetActorLocation() end)
    pcall(function() m = magus:K2_GetActorLocation() end)
    if not a or not m then return end
    AVU.SendClientFX(FVector((a.X + m.X) / 2, (a.Y + m.Y) / 2, (a.Z + m.Z) / 2 + 40),
        "EXOR_SHOCKWAVE_CHA", 1)
end


-- =======================================================================
-- VARIANT HOOKS - MAGUS (referenced from GK_DarkLens.lua's "Magus of the Fallow")
-- =======================================================================

--- [RENDERER] Renderer half of the no-dodge + no-stagger-stumble rules (both Broadcast_Perform*
--- are multicasts; each machine has its own copy of the anim fields, and this base is acid-weak
--- so a bioball force-sends the stagger one past Stats' CCImmune).
function M.MagusVisuals(actor)
    AVU.SkipBackstepAnim(actor)
    AVU.SkipStaggerAnim(actor)

    AVU.TintMesh(actor, {
        Color = FVector(10, 0.2, 22),
        Emissive = 30,
        EmissiveColor = FVector(0, 5, 5),
    })
end

--- [AUTHORITY] Runs on every (re)mutation.
function M.MagusStats(actor, opts)
    -- Can't be flinched, frozen, netted or staggered (debuff refusals + the stagger recipe).
    AVU.CCImmune(actor)

    -- No dodge/backstep: the montage IS the movement, and this body never moves. Aggro block
    -- montage skipped too - its length would otherwise be the combat-entry delay.
    pcall(function() actor.EvadesProjectiles = false end)
    AVU.SkipBackstepAnim(actor)
    AVU.SkipAggroAnim(actor)

    -- Only uses its grab as a 'force grab ability'
    pcall(function() actor.GrabCooldown = 99999 end)
    pcall(function() actor.ChokeDamage = 20 end)

    -- The native fireball is OFF (the ghost-bolt is the regular attack, from MagusTick): the
    -- def's HasRangedAttack=false gates the BT branch, this latch covers a ranged loop already
    -- in flight and is re-asserted on tick (the Wraith recipe - a manual true needs it).
    pcall(function() actor.RangedAttack_OnCooldown = true end)

    -- No projectile deflector: the def's DebuffsImmune refuses AI_TurtleMode (the buff that
    -- raises the front shield); this zeroes the Shield mesh so a raised one covers nothing.
    GKM.StripMageShield(actor)

    -- NO GRAVITY WAVE. It is a pure RadialForce impulse (zero damage) that repeats every 0.75s for
    -- 10s once anything walks into its sphere, and it shoves indiscriminately - this arena is
    -- ledges, so it threw players into the pit and its own Astral add off the edge.
    GKM.StripGravityWave(actor)

    -- Belt for a re-mutation (stream-back / save-restore): OnReady only runs once per spawn.
    AVU.PinInPlace(actor)

    -- PHASE FAIL-SAFE (the Barrier Mage lesson - Stats runs on EVERY mutation): re-derive the
    -- phase from live HP and never resume INTO an astral hold (its add is gone after a
    -- stream-back). BasicStats' re-init already healed the pools, so a re-mutated boss
    -- restarts at phase 1 with zero banked damage - a reset, not a resume.
    local key = Utils.ActorKey(actor)
    if key then
        local st = phaseState[key]
        if st and st.AstralSlot then st.AstralSlot.cancel = true; st.AstralSlot = nil end
        phaseState[key] = { Phase = 1, Dealt = 0, Actor = actor }
        VS.Set(actor, SIG_ASTRAL, 0)   -- never boot into a hold; the shell mirror follows
    end

    armPatchBoost()
    unsealTestCopy(actor, opts)
end

--- [AUTHORITY] Post-spawn/adopt: the Magus never moves.
function M.MagusReady(actor)
    if Utils.IsActorInvalid(actor) then return end
    AVU.PinInPlace(actor)
end

--- [BOTH via ClientTick] Renderer half mirrors the astral-hold shell; everything else is
--- authority-only (a pure client MUST fall out before the ability/pin work).
function M.MagusTick(actor, ticks)
    local key = Utils.ActorKey(actor)
    if not key then return end

    if Utils.HasRenderer() and ticks % SHELL_TICKS == 7 then mirrorShell(actor, key) end
    if not Utils.IsAuthority() then return end

    -- Upkeep that runs sealed or not: the pin belt and the test-copy unseal retry.
    if ticks % PIN_TICKS == 5 then AVU.PinInPlace(actor) end
    if ticks % UNSEAL_TICKS == 3 then unsealTestCopy(actor) end

    -- SEALED = the native bubble is up and nothing here may act. CombatState is not proof of a
    -- fight (the watcher's ForceAggro writes it - CFG.CanForceAggro refuses that for a sealed
    -- body, this is the belt), so every ability waits on the flag itself.
    if isSealed(actor) then return end

    if ticks % FACE_TICKS == 0 and not beamOn[key] then   -- a channel owns the facing
        local inCombat = false
        pcall(function() inCombat = actor.CombatState end)
        if inCombat then
            local target = AVU.GetCurrentTarget(actor)
            if target then AVU.FaceTarget(actor, target) end
        end
    end
    if ticks % VOLLEY_CHECK_TICKS == 2 then tryVolley(actor) end
    if ticks % VOLLEY_CHECK_TICKS == 4 then tryBeam(actor) end
    if ticks % VOLLEY_CHECK_TICKS == 6 then tryForceChoke(actor) end
    if ticks % BOLT_TICKS == 8 then tryBolt(actor, key) end   -- the filler, after the moves
    -- Two native latches this body holds DOWN for good, re-asserted because the class keeps trying
    -- to clear them: the fireball (any fire attempt clears it) and the gravity wave (a ~10Hz
    -- self-tick re-checks it, and Server_OnShieldRemoval resets it outright).
    if ticks % 10 == 1 then
        pcall(function() actor.RangedAttack_OnCooldown = true end)
        pcall(function() actor.GravityWaveOnCooldown = true end)
    end
    if ticks % UNSEAL_TICKS == 3 then
        -- Signal belt: endAstral can lose its actor wrapper on a bad day; the phase is the
        -- truth, so re-assert the replicated bit on a slow cadence.
        local p = phaseOf(key)
        VS.Set(actor, SIG_ASTRAL, (p == 2 or p == 4) and 1 or 0)
    end
end

--- [AUTHORITY, OnDamageTaken] The hit's damage is captured NOW; the reads/writes are deferred
--- one beat so the native pipeline has finished with the limb maps. Fires per DoT tick too -
--- that is fine, DoT damage is fight progress like any other.
function M.MagusDamaged(actor, damage)
    local dmg = tonumber(damage) or 0
    Utils.QueueWork(function() checkPhase(actor, dmg) end, 0)
end

--- [AUTHORITY] Forget per-actor tracking (string keys never collect on their own), and undo
--- every latch a mid-ability death could leave behind.
function M.MagusDeath(actor)
    local key = Utils.ActorKey(actor)
    if key then
        volleyTick[key], beamTick[key], chokeTick[key] = nil, nil, nil
        busyUntil[key], boltQuietUntil[key], beamOn[key] = nil, nil, nil
        -- A live astral add dies with its owner (and a mid-flight spawn is cancelled).
        local st = phaseState[key]
        if st and st.AstralSlot then
            st.AstralSlot.cancel = true
            local a = st.AstralSlot.actor
            if a ~= nil and Utils.IsActorValid(a) and not a.IsDead then AVU.KillNpc(a) end
        end
        phaseState[key] = nil
        -- The shell must not glow on a corpse.
        local shell = magusShell[key]
        magusShell[key] = nil
        if shell ~= nil and Utils.IsComponentValid(shell) then
            pcall(function() shell:K2_DestroyComponent(shell) end)
        end
    end
    if Utils.IsActorValid(actor) then
        -- Belts: the beam's OnFinish("dead") normally does this, but a latched
        -- LockedInPlaceMontage / held victim must never survive a missed exit path.
        AVU.HoldStill(actor, false)
        pcall(function()
            local h = actor.HoldingCharacter
            if h ~= nil and Utils.IsActorValid(h) then actor:DropHoldingCharacter() end
        end)
    end

    -- The trophy (the Patriarch's Chieftain bobblehead precedent). CustomRow makes it self-gating:
    -- nothing drops while ModuleBobbleheads' rows are not in the table.
    AVU.DropLoot(actor, { Row = "Mystagogue Bobblehead", Amount = 1, Radius = 90, CustomRow = true })

    -- The shared layer's bookkeeping. Guard cache + boss ref always; the FLAG BACKSTOP and the
    -- RESPAWN CLOCK only for the arena body - its flag is Residence_Fracture_Complete, and a test
    -- copy dying in the Office must neither complete the Fracture nor start a 3-day timer.
    DL.ForgetGuard(actor)
    DL.ForgetBoss(CFG)
    if Utils.IsActorValid(actor) and Utils.ActorInArea(actor, DL.ARENAS.Mage) then
        DL.FlagBackstop(CFG)    -- native sets it on player-credited kills only
        DL.NoteBossDeath(CFG)   -- 3 days -> DL.RespawnBoss (direct spawn: the spawner is flag-locked)
    else
        Utils.LogDebug("DarkLens Mage - death outside the arena (test copy): no flag/respawn stamp",
            SETTINGS.DEBUG_NPC_ACTIONS)
    end
end

--- [AUTHORITY, per hit] A hit thrown in from outside the arena does nothing (the shared
--- DL.OutOfArena - the same anti-snipe rule as the other three); untouchable during an astral
--- hold; every other phase caps single-hit damage (a NUMBER return = pre-scaling cap in
--- CombatHooks) so no burst can zero a pool before the deferred floor clamp runs. Per-hit, never
--- latched - it cannot go stale, and it never fights the native DarkLensCombatReady seal (which
--- refuses hits outright while sealed, before this ever runs).
function M.MagusDamageGate(actor)
    if DL.OutOfArena(CFG, actor) then return true end
    local key = Utils.ActorKey(actor)
    local p = key and phaseOf(key) or 1
    if p == 2 or p == 4 then return true end
    return DMG_CAP_RAW
end


-- =======================================================================
-- VARIANT HOOKS - ASTRAL (referenced from GK_DarkLens.lua's "Astral Magus")
-- =======================================================================

--- [RENDERER] Spirit look + the meditate pose (single-node mode - no montage will ever play
--- on this body again, which is fine: its whole kit is the native projectile spawn).
function M.AstralVisuals(actor)
    AVU.SkipBackstepAnim(actor)
    AVU.PlayIdleSequence(actor, ENUMS.Anims.MAGE_MEDITATE, true)
    applyAstralLook(actor)
end

--- [AUTHORITY] Runs on every (re)mutation of the add.
function M.AstralStats(actor)
    GKM.StripMageKit(actor)   -- front shield + gravity wave + grab + native eye, all off
    AVU.CCImmune(actor)       -- a timed spirit must not spend its window stunned/frozen
    -- The bolt is scripted (AstralTick); the native fireball channel stays DOWN - the def's
    -- HasRangedAttack=false gates the BT branch, this latch covers an in-flight loop and is
    -- re-asserted on tick (the Wraith recipe: a manual true needs re-assertion).
    pcall(function() actor.RangedAttack_OnCooldown = true end)
    AVU.ClearLoot(actor)      -- a phase add drops nothing
    AVU.SkipBackstepAnim(actor)   -- montage dodges are dead under the meditate pose anyway;
    AVU.SkipAggroAnim(actor)      --   the scripted glide-hop in AstralDamaged is the dodge
end

--- [BOTH via ClientTick] Renderer keeps the look + pose honest; authority runs the kit.
function M.AstralTick(actor, ticks)
    if Utils.HasRenderer() and ticks % ASTRAL_LOOK.Ticks == 3 then
        applyAstralLook(actor)
        AVU.PlayIdleSequence(actor, ENUMS.Anims.MAGE_MEDITATE, true)
    end
    if not Utils.IsAuthority() then return end

    -- The native fireball stays down (a fire attempt clears the latch; re-assert).
    if ticks % 10 == 1 then pcall(function() actor.RangedAttack_OnCooldown = true end) end
    if ticks % BOLT_TICKS == 5 then ghostBolt(actor) end   -- bare: no tell under the meditate pose
    if ticks % ASTRAL_TETHER_TICKS == 8 then astralTether(actor) end
end

--- [AUTHORITY, OnDamageTaken] Two per-hit reactions: a shield-break ping when the hit is a
--- type it is IMMUNE to (reads as "wrong damage type" without a tooltip, 1s throttle), and
--- the scripted glide-hop dodge (montage-free - the meditate pose is single-node).
local IMMUNE_PING_TYPES = {   -- mirror of the "Astral Magus" NpcResistances immunity row
    Sharp = true, Blunt = true, Bullet = true, Bleeding = true, Acid = true, Explosive = true,
}
function M.AstralDamaged(actor, damage, dmgType)
    local key = Utils.ActorKey(actor)
    if not key then return end

    local typeName
    pcall(function() typeName = dmgType.DamageTypeDisplayName:ToString() end)
    if typeName then typeName = typeName:gsub("'", "") end
    if typeName and IMMUNE_PING_TYPES[typeName] then
        if AVU.CooldownReady(astralPingTick, key, ASTRAL_PING_CD_TICKS) then
            Utils.QueueWork(function()
                if Utils.IsActorInvalid(actor) or actor.IsDead then return end
                local loc
                pcall(function() loc = actor:K2_GetActorLocation() end)
                if loc then
                    -- Shield_Regen is an upward-projecting cylinder: seat it at the BASE
                    -- (capsule centre -88 = feet, +30 back up for the meditate float).
                    AVU.BroadcastFX(FVector(loc.X, loc.Y, loc.Z - 88 + 30),
                        ENUMS.Effects.SHIELD_REGEN, nil, FVector(1, 1, 1))
                end
            end, 0)
        end
        return   -- an immune hit is nothing to dodge away from
    end

    -- The dodge: chance + cooldown gated (Peek - a failed roll must not eat the cooldown).
    if not AVU.CooldownReady(astralDodgeTick, key, ASTRAL_DODGE.CdTicks, { Peek = true }) then return end
    if math.random() >= ASTRAL_DODGE.Chance then return end
    AVU.CooldownReady(astralDodgeTick, key, ASTRAL_DODGE.CdTicks)   -- stamp
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        local al, right
        pcall(function() al = actor:K2_GetActorLocation() end)
        pcall(function() right = actor:GetActorRightVector() end)
        if not al or not right then return end
        local side = (math.random(0, 1) == 0) and 1 or -1
        local pivot = FVector(al.X + right.X * side * 300, al.Y + right.Y * side * 300, al.Z)
        -- Unglue from the ground first (the lasso lesson: friction + AI re-pathing scrub a
        -- walking NPC's launch to a feeble hop) - Falling for one beat, then the shove.
        pcall(function() actor.CharacterMovement:SetMovementMode(3, 0) end)   -- 3 = Falling
        AVU.LaunchCharacterFrom(actor, pivot, ASTRAL_DODGE.Speed, ASTRAL_DODGE.Up, true)
    end, 0)
end

--- [AUTHORITY, OnDeath] Vanish dressing + route the hold's end back to the owning Magus.
function M.AstralDied(actor)
    local ak = Utils.ActorKey(actor)
    local magusKey = ak and astralToMagus[ak] or nil
    if ak then
        astralToMagus[ak] = nil
        astralPingTick[ak], astralDodgeTick[ak] = nil, nil
    end

    pcall(function()
        local loc = actor:K2_GetActorLocation()
        if loc then AVU.SendClientFX(loc, "PORTAL_RIFT", 2) end
    end)
    AVU.HideOnDeath(actor)   -- a spirit leaves no corpse

    if magusKey then
        local st = phaseState[magusKey]
        if st then endAstral(magusKey, st) end
    end
end


-- =======================================================================
-- DEBUG - encounter reset (/dlreset magus, ChatCommands)
-- =======================================================================

--- Reset the fight for testing: kill any astral add, wipe the phase machine + every latch, heal
--- the boss back to its statline. With no living boss a fresh one is put on the field (direct
--- spawn once Residence_Fracture_Complete is set - the spawner is flag-locked forever). The
--- native SEAL is left exactly as it is: a body inside the arena is unsealed by the eyes, not
--- by us.
function M.ResetEncounter()
    if not Utils.IsAuthority() then return end

    local VT = require("AnteVariants.VariantTag")
    local V = require("AnteVariants.Variants")
    local destroyed = 0
    local astralId = V[ASTRAL_SPAWN.Name] and V[ASTRAL_SPAWN.Name].Id
    if astralId then
        local hits = AVU.GetNearbyActorsOfClass(ARENA_CENTER, CFG.ScanRadius + 2000,
            ENUMS.NpcClasses["Gatekeeper_Mage"])
        for i = 1, #hits do
            pcall(function()
                local a = hits[i]:get()
                if Utils.IsActorValid(a) and VT.Decode(a) == astralId then
                    a:K2_DestroyActor()
                    destroyed = destroyed + 1
                end
            end)
        end
    end

    for _, t in ipairs({ volleyTick, beamTick, chokeTick, busyUntil, boltQuietUntil, beamOn,
                         phaseState, astralToMagus, astralPingTick, astralDodgeTick }) do
        for k in pairs(t) do t[k] = nil end
    end

    local boss = DL.Boss(CFG)
    if boss then
        DL.ForgetGuard(boss)
        AVU.HoldStill(boss, false)
        pcall(function()
            local h = boss.HoldingCharacter
            if h ~= nil and Utils.IsActorValid(h) then boss:DropHoldingCharacter() end
        end)
        local key = Utils.ActorKey(boss)
        if key then phaseState[key] = { Phase = 1, Dealt = 0, Actor = boss } end
        VS.Set(boss, SIG_ASTRAL, 0)
        pcall(function() boss:InitalizeHealthValues(true) end)   -- heal limbs from NPCData (our statline)
        Utils.Log(string.format("DL Magus reset: boss healed, phase 1, %d astral body(ies) destroyed",
            destroyed))
    else
        DL.NoteFlagLocked(CFG)
        DL.RespawnBoss(CFG, string.format("%d astral body(ies) destroyed", destroyed))
    end
end


return M
