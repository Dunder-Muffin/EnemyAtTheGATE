-- =======================================================================
-- GK_DarkLensWitchHelpers - the Dark Lens Witch boss fight (Mother of the Fallow)
--   * The base DarkLens_Witch sets the story flag, so the REAL body must be what dies
--   * Her own Broadcast_CombatAbility3 (hover) + OnLanded overrides - hook THOSE, not the base
--   * Cycles Warrior/Storm/Plague aspects each hover; WARRIOR's ranged attack splits by altitude
--     (native shotgun on the ground, lobbed fireball in the air). Kick launch is hardcoded ->
--     GKW.KickDamp dampens it. Stagger/CC immune.
--   * Aspect-cycle mechanics (takeoff/landing/backstop timing): see AnNotes/AnteNPCs/GKDarkLensWitch.md
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local ASSETS = require("AnteCore.AssetManager")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local DL = require("AnteNPCs.GK_DarkLensHelpers")   -- watcher / flag backstop / respawn / arenas
local GKW = require("AnteNPCs.GK_WitchHelpers")     -- the sister witches' kits (Warrior/Storm/Plague)
local HIVE = require("AnteNPCs.PeccarySowHelpers")  -- the shared bee-cloud kit
local LogDebug = Utils.LogDebug

local H = {}

-- =======================================================================
-- Knobs - boss arena
-- =======================================================================

local WITCH_ARENA       = FVector(-28768, 90195, 3574)   -- her spawner
local ARENA_SCAN_RADIUS = 4000

-- Everything the shared layer needs to run this fight's watcher / backstop / respawn.
--   * WakeSq is deliberately WIDE (100m): her spawner sits well above and to one side of the
--     floor players cross, so a Chieftain-sized 45m gate never opens. The gate is a list walk +
--     one DistSq; the class overlap behind it still runs only once per WatchMs.
local CFG = {
    StateKey     = "DarkLensWitchArmed",
    Label        = "DL witch",
    Boss         = "Mother",
    Flag         = "Fracture_DL_Witch_Dead",
    ClassKey     = "DarkLens_Witch",
    Variant      = "Mother of the Fallow",
    Center       = WITCH_ARENA,
    Area         = DL.ARENAS.Mother,
    ScanRadius   = ARENA_SCAN_RADIUS,
    WakeSq       = 10000 * 10000,
    AggroSq      = 3000 * 3000,   -- a player this close to HER -> ForceAggro (the AISense fix)
    WatchMs      = 3000,
    SpawnerClass = "NPCSpawn_Gatekeeper_DARKLENS_Witch_C",
    Home         = WITCH_ARENA,
}

-- =======================================================================
-- Knobs - the aspect cycle
-- =======================================================================

-- The channel window: she pauses and dances while the new aspect lands
local ASPECT_IDLE_MS   = 3000
local IDLE_HOLD_MS     = 500    -- re-assert cadence - the native dive clears LockedInPlaceMontage
local IDLE_ANIM        = ENUMS.Anims.GKWITCH_DANCE_RITUAL
local IDLE_ANIM_RATE   = 1.5
local IDLE_ANIM_SKIP_S = 2.5    -- skip the montage's long wind-up
-- Re-warmed before every play: PlayMontageReplicated no-ops SILENTLY on a GC'd asset, so a cold
-- miss here is an invisible 3s of standing still.
local IDLE_DEPS = { IDLE_ANIM }

-- Landing detection - OnLanded drives the cycle, this is the watcher that can't miss it
local LANDING = {
    FirstMs = 1200,   -- after the hover's own clock, before the first touchdown poll
    PollMs  = 200,
    Tries   = 40,     -- 8s, then force the change anyway
}

-- Backstop: in combat but never hovering -> change anyway (must exceed a full cycle)
local ASPECT_MAX_GAP_TICKS = 750   -- 75s
-- WARRIOR is held on the ground, so its change can ONLY come from the backstop - a full-cycle
-- gap would park the whole fight in one aspect.
local WARRIOR_MAX_GAP_TICKS = 250   -- 25s

-- Hover pacing
local HOVER_SECONDS = 20   -- native 10
-- Inert on this line: Cooldown_CombatAbility* is only the duration an explicit SetAbilityOnCooldown
-- would use, and nothing on the Grunt->Gatekeeper->Witch chain ever calls it for slot 3. The real
-- hover gate is CanThrowGrenades (see applyAspectLoadout). Kept as the documented intent.
local HOVER_CD      = 40   -- cooldown between jetpacks (native 0)

-- HER cadences for the sisters' kits, in FAST_TICKs (~10/s), as { normal, hard }. She is a boss,
-- and - unlike a sister - a takeoff is the moment she stops being the aspect that owns it, so the
-- apex-only abilities need a ground clock of their own.
local MOTHER_CADENCE = {
    StormGrenade = { 30, 20 },   -- sister 70 / 30: shock grenades ARE her storm form
    PlagueQuill  = { 40, 20 },   -- sister 10: the quill becomes punctuation, not the attack...
    PlagueCloud  = { 80, 50 },   -- sister 100: ...clouds...
    PlagueSummon = { 90, 70 },   -- sister 100: ...and pestilences carry it instead
}

local function cadence(which)
    local pair = MOTHER_CADENCE[which]
    return STATE.HardModeNoMercy and pair[2] or pair[1]
end

local FIRE_SOCKET    = "r_weapon_ranged1"   -- NPC_Base defaults ProjectileFireSocket to "head"
local KEEPWARM_TICKS = 600
local ADD_POLL_TICKS = 20

-- Per-aspect loadout + tint. Mute = silence the native gun bark; Fire = the cue to put back (by
-- path, never a stashed wrapper); NativeGun = leave OverrideSoldierFireLogic OFF (real shotgun).
-- WARRIOR keeps the shotgun only on the ground - Broadcast_DoRangedAttackFX multicasts on every
-- BT attempt regardless of our cadence, so gating a fireball behind it reads as an empty gun bark.
local ASPECTS = {
    WARRIOR = { Label = "Warrior", Add = "Warrior Acolyte", NativeGun = true,
                Fire = ENUMS.SOUNDS.SHOTGUN_MILITARY_FIRE,
                Body = FVector(1.6, 0.35, 0.2),  Helm = FVector(1.2, 0.3, 0.2),
                Deps = GKW.WARRIOR_ASSETS },
    STORM   = { Label = "Storm",  Add = "Storm Acolyte", Mute = true,
                Body = FVector(0.25, 0.7, 1.6),  Helm = FVector(0.3, 0.6, 1.2),
                Deps = GKW.STORM_ASSETS },
    PLAGUE  = { Label = "Plague", Add = "Plague Acolyte", Mute = true,
                Body = FVector(0.9, 1.1, 0.25),  Helm = FVector(0.7, 0.8, 0.2),
                Deps = GKW.PLAGUE_ASSETS },
}
local ASPECT_ORDER = { "WARRIOR", "STORM", "PLAGUE" }

-- =======================================================================
-- Knobs - acolytes
-- =======================================================================

local ADD_CAP          = 3     -- live acolytes across ALL aspects
local ADD_SPAWN_RADIUS = 450   -- nav-projected ring around her for the rift
local ADD_AGGRO_MS     = 800
local ADD_PENDING_MS   = 12000 -- a claim older than this = the rift aborted; release the slot

local ACOLYTE_SHIELD        = 150   -- the witch class default, kept
local ACOLYTE_GRAVITY_STORM = 0.7   -- 0.5 base; lighter overshoots the jetpack arc-solve

local PLAGUE_CLOUD_S = 20   -- landing bee cloud lifetime (stings for all but the 2s fade tail)

-- =======================================================================
-- Knobs - visuals
-- =======================================================================

-- Buried torso point-light: a big soft source that lights HER, not the arena
local GLOW_LIGHT_BONE  = "spine2"
local GLOW_LIGHT_LOC   = FVector(0, 0, 0)
local GLOW_LIGHT_COLOR = FLinearColor(2, 1.5, 0.5, 1)
local GLOW_INTENSITY   = 1000
local GLOW_SOURCE_RAD  = 260
local GLOW_ATTEN_RAD   = 450

local LOOK_BODY = FVector(5, 5, 5)
local LOOK_HELM = FVector(0.5, 0.1, 0.3)

-- The witch hat
local HAT_LOC   = FVector(0, -7, 0)
local HAT_ROT   = FRotator(90, 90, 0)
local HAT_SCALE = FVector(1.3, 1.3, 1.4)
local HAT_COLOR = FVector(15, 3, 0.5)

-- Her shield bubble. The stock hue is a DEEP blue/purple and it takes a lot to pull off it, hence
-- the big multipliers + per-channel Intensity scalars - and ALL THREE colour slots, or the stock
-- hue bleeds through whichever is left unset.
local SHIELD_COLOR = FVector(3, 2, 0.1)   -- orange
local SHIELD_R, SHIELD_G, SHIELD_B = 2, 1, 0
local SHIELD_GLOW  = 1

-- Native shield values, restored by /dlreset witch
local MOTHER_SHIELD_HP    = 300
local MOTHER_SHIELD_REGEN = 0

-- =======================================================================
-- Per-actor state (module-local; /reload clears with the defs)
-- =======================================================================

-- (the cached boss wrapper lives in CFG._ref, owned by the shared layer - DL.Boss/SetBoss/Forget)
local dlwAspect     = {}   -- bossKey -> current aspect key ("WARRIOR"/"STORM"/"PLAGUE")
local dlwNext       = {}   -- bossKey -> the aspect chosen AT TAKEOFF, applied on touchdown
local dlwHoverGen   = {}   -- bossKey -> takeoff counter; a landing watcher with a stale gen bails
local dlwChangeDue  = {}   -- bossKey -> true from takeoff until that hover's change fires (one-shot)
local dlwChangeTick = {}   -- bossKey -> FAST_TICK of the last aspect change (the no-hover backstop)
local dlwAdds       = {}   -- bossKey -> array of live acolyte wrappers (pruned per poll)
local dlwPending    = {}   -- bossKey -> count of rifts opened but not yet arrived (slot claims)
local dlwIdleGen    = {}   -- bossKey -> channel generation; a stale hold chain bails on mismatch
local dlwStagger    = {}   -- bossKey -> her PRISTINE StaggerCooldown, stashed before we park it

-- Every per-boss table, so a wipe/death/reset can't miss one.
local ALL_STATE = { dlwAspect, dlwNext, dlwHoverGen, dlwChangeDue, dlwChangeTick,
                    dlwAdds, dlwPending, dlwIdleGen, dlwStagger }

-- Attachments are NOT idempotent (a second call bolts on a second hat and a second light), so the
-- attach half of Visuals is latched. Per-machine (Visuals runs on clients too) and deliberately
-- OUTSIDE ALL_STATE, so /dlreset witch can re-tint without duplicating hardware.
local dlwLookDone = {}   -- actorKey -> true once her attachments exist


-- =======================================================================
-- MOTHER - aspect-cycle machinery (private; callee-before-caller, see file header)
-- =======================================================================

-- Never the one she is already wearing, so every change reads as a change.
local function pickAspect(current)
    local pool = {}
    for _, k in ipairs(ASPECT_ORDER) do
        if k ~= current then pool[#pool + 1] = k end
    end
    return pool[math.random(#pool)]
end


-- Per-aspect field writes + the renderer-local re-tint. Deps are warmed here: the payload and the
-- gun both fire within seconds of this.
local function applyAspectLoadout(actor, aspect)
    local def = ASPECTS[aspect]
    if not def then return end

    ASSETS.WarmPinned(def.Deps or {})

    -- NO TAKEOFF FIRE on any aspect (LeaveFireWithJetpack drops molotov patches along the flight
    -- path). The LANDING pool is a separate flag - FlameOnLanding - and that one stays.
    pcall(function() actor.LeaveFireWithJetpack = false end)

    -- WARRIOR FIGHTS ON THE GROUND. CanThrowGrenades is the one thing the controller's
    -- AdditionalAbilityCheck consults, so clearing it shuts the hover (slot 3) - and, as the same
    -- switch, her medic revive for the length of the aspect. Every other aspect turns it back on,
    -- which is the whole reason this is set on EVERY change rather than once.
    --   * Grounded, her ranged split (MotherRangedAttack) always resolves to the shotgun and the
    --     kick fireball becomes her reach. WARRIOR_MAX_GAP_TICKS is what ends the aspect.
    pcall(function() actor.CanThrowGrenades = (aspect ~= "WARRIOR") end)

    -- The gun: Warrior fires the real shotgun (on the ground), the others suppress it for their
    -- bolt/quill. Open the native gate on the way - a sister's hold chain may still have it
    -- latched shut, and the incoming aspect owns its own cadence from here.
    pcall(function() actor.OverrideSoldierFireLogic = (def.NativeGun ~= true) end)
    pcall(function() actor.RangedAttack_OnCooldown = false end)

    if not Utils.HasRenderer() then return end

    -- The gun bark: cleared for the bolt/quill aspects, put back BY PATH for Warrior.
    -- Per-instance and renderer-local, exactly like the sisters' Visuals-set cue.
    if def.Mute then
        pcall(function() actor.WeaponFireSound = nil end)
    elseif def.Fire then
        pcall(function()
            local cue = ASSETS.GetIfValid(def.Fire)
            if IsValid(cue) then actor.WeaponFireSound = cue end
        end)
    end

    pcall(function()
        local mesh = Utils.GetValidMesh(actor)
        if mesh then mesh:SetVectorParameterValueOnMaterials(FName("Color"), def.Body) end
    end)
    pcall(function() AVU.TintComponent(actor.Helmet, { Color = def.Helm }) end)
end


-- The channel: pseudo-stun + the ritual dance, released as a PAIR (death and /dlreset witch both
-- call H.EndChannel) so a LockedInPlaceMontage can never outlive the fight.
local function idleChannel(actor, key)
    local gen = (dlwIdleGen[key] or 0) + 1
    dlwIdleGen[key] = gen

    AVU.HoldStill(actor, true)
    -- Stash the pre-channel value once, so a second channel can't stash our own 99999. Since
    -- AVU.CCImmune this is EXPECTED to read 99999 already; the stash costs nothing and stays
    -- correct if that changes.
    if dlwStagger[key] == nil then
        pcall(function() dlwStagger[key] = actor.StaggerCooldown end)
    end
    pcall(function() actor.StaggerCooldown = 99999 end)

    ASSETS.LoadAsync(IDLE_DEPS, function()
        if Utils.IsActorInvalid(actor) or actor.IsDead or dlwIdleGen[key] ~= gen then return end
        AVU.PlayMontageReplicated(actor, IDLE_ANIM, IDLE_ANIM_RATE, false)
        -- Start PAST the long wind-up so the window shows the dance, not the approach to it.
        if IDLE_ANIM_SKIP_S > 0 then
            AVU.SkipIntoAnimation(actor, IDLE_ANIM, IDLE_ANIM_SKIP_S)
        end
    end)

    local function hold(left)
        if dlwIdleGen[key] ~= gen then return end
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        if left <= 0 then
            H.EndChannel(actor)
            return
        end
        AVU.HoldStill(actor, true)
        Utils.QueueWork(function() hold(left - 1) end, IDLE_HOLD_MS)
    end
    hold(math.ceil(ASPECT_IDLE_MS / IDLE_HOLD_MS))
end


-- What erupts where she touches down.
--   * WARRIOR has no branch on purpose: FlameOnLanding is left TRUE and the NATIVE
--     AreaEffect_MolotovBurn_Mage pool (Fire_Plasma, 20/0.5s, 5s) is the payload - a real
--     replicated actor, free of our hooks.
--   * The other two suppressed that pool on the way down and bring their own.
local function aspectPayload(actor, aspect)
    if aspect == "STORM" then
        GKW.StormImpact(actor)   -- the sister's shock nova, at her feet (players only, S6-safe)
    elseif aspect == "PLAGUE" then
        local loc
        pcall(function() local l = actor:K2_GetActorLocation(); loc = FVector(l.X, l.Y, l.Z) end)
        if loc then HIVE.DropCloud(loc, actor, { Seconds = PLAGUE_CLOUD_S }) end
    end
end


-- Drop dead/unloaded bodies from the roster. Wrappers, not keys: we own these spawns and need the
-- actor to re-check validity (IsActorValid also catches an unloaded level).
local function pruneAdds(key)
    local roster = dlwAdds[key]
    if not roster then roster = {} dlwAdds[key] = roster end
    local keep = {}
    for i = 1, #roster do
        local a = roster[i]
        if Utils.IsActorValid(a) and not Utils.IsDeadSafe(a) then keep[#keep + 1] = a end
    end
    dlwAdds[key] = keep
    return keep
end


-- ONE acolyte of the current aspect, through a rift. A fresh summon is invisible to a world scan
-- TWICE (mid-spawn, then pre-mutation), so the slot is CLAIMED at request time and released by
-- arrival or by a stale timer. Doorway faces whoever she's fighting (the FX is a flat plane,
-- invisible edge-on). Faction copied from her (never def.Faction - the E_Factions name/value
-- trap); lifetime tied to her so a script-spawned NPC can't strand in an empty level.
local function summonAcolyte(actor, aspect)
    local key = Utils.ActorKey(actor)
    if not key then return end
    local def = ASPECTS[aspect]
    if not def then return end

    local live = #pruneAdds(key) + (dlwPending[key] or 0)
    if live >= ADD_CAP then
        LogDebug("Mother of the Fallow - acolyte cap reached", SETTINGS.DEBUG_NPC_ACTIONS)
        return
    end

    local loc
    pcall(function() local l = actor:K2_GetActorLocation(); loc = FVector(l.X, l.Y, l.Z) end)
    if not loc then return end
    -- Nav-project: she has just landed from a dive and may be on a ledge or a stair.
    local at = Utils.GetSpawnPoint(loc, ADD_SPAWN_RADIUS) or loc

    -- Portal facing: her target, else the nearest player, else world yaw 0.
    local target = AVU.GetCurrentTarget(actor)
    local face = Utils.IsActorValid(target) and target or Utils.NearestPlayer(at)
    local yaw = 0
    if Utils.IsActorValid(face) then
        pcall(function() yaw = Utils.RotatorToTarget(at, face:K2_GetActorLocation()).Yaw end)
    end

    dlwPending[key] = (dlwPending[key] or 0) + 1
    local claim = { open = true }
    local function release()
        if not claim.open then return end
        claim.open = false
        dlwPending[key] = math.max(0, (dlwPending[key] or 1) - 1)
    end

    AVU.PortalSummon(at, { { Variant = def.Add, Count = 1 } }, {
        Spread = 100,
        EmergeMs = 500,
        OpenMs = 2000,
        Rift = true,
        Yaw = yaw,
        EmergeFX = false,
        Attack = target,
        AggroDelayMs = ADD_AGGRO_MS,
        FactionFrom = actor,
        LifetimeOwner = actor,
        Guard = function()   -- died mid-cast -> no reinforcement
            return Utils.IsActorValid(actor) and not Utils.IsDeadSafe(actor)
        end,
        OnSpawned = function(npc)
            release()
            if Utils.IsActorInvalid(npc) then return end
            local roster = dlwAdds[key] or {}
            roster[#roster + 1] = npc
            dlwAdds[key] = roster
        end,
    })

    -- The rift can abort (Guard false, spawn failure): never leak the slot.
    Utils.QueueWork(release, ADD_PENDING_MS)
end


-- The whole set-piece: new aspect -> loadout + tint -> 3s channel -> payload -> one acolyte.
-- The CALLER picks the aspect: a hover picks it at TAKEOFF (so the dive can decide the native
-- fire pool's fate mid-flight); aggro and the backstop pick it here and now. `why` names the
-- trigger - only a landing has a dive under it, so only a landing erupts a payload.
local function changeAspect(actor, key, aspect, why)
    dlwAspect[key] = aspect
    dlwChangeTick[key] = STATE.FAST_TICK
    applyAspectLoadout(actor, aspect)

    Utils.Log("Mother of the Fallow - channelling " .. ASPECTS[aspect].Label
        .. " [" .. tostring(why) .. "]")

    idleChannel(actor, key)
    if why == "landing" then aspectPayload(actor, aspect) end
    summonAcolyte(actor, aspect)
end


-- Hovering, diving, or simply off a ledge. JetpackActive covers the hover, IsFalling the rest.
local function isAirborne(actor)
    local air = false
    pcall(function()
        local cmc = actor.CharacterMovement
        air = (actor.JetpackActive == true) or (IsValid(cmc) and cmc:IsFalling())
    end)
    return air
end


-- The one-shot both landing paths funnel through, so OnLanded and the watcher can never
-- double-change.
local function landingChange(actor, key, why)
    if not dlwChangeDue[key] then return end
    dlwChangeDue[key] = nil
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end
    changeAspect(actor, key, dlwNext[key] or pickAspect(dlwAspect[key]), why)
end


-- Poll for touchdown, and suppress the native fire pool on the way down.
--   * A stale generation (she took off again) or a spent one-shot (OnLanded beat us to it) bails.
--   * FlameOnLanding is written false on EVERY airborne poll for a non-Warrior landing: the native
--     ability sets it true at the start of the dive and OnLanded consumes it, so clearing it any
--     time during the fall is enough - no hook required.
local function landingWatch(actor, key, gen, tries)
    if dlwHoverGen[key] ~= gen or not dlwChangeDue[key] then return end
    if Utils.IsActorInvalid(actor) or actor.IsDead then
        dlwChangeDue[key] = nil
        return
    end

    if dlwNext[key] ~= "WARRIOR" then
        pcall(function() actor.FlameOnLanding = false end)
    end

    if not isAirborne(actor) then landingChange(actor, key, "landing") return end
    if tries <= 0 then
        -- Never leave the cycle stalled because a touchdown was never observed.
        landingChange(actor, key, "landing-timeout")
        return
    end
    Utils.QueueWork(function() landingWatch(actor, key, gen, tries - 1) end, LANDING.PollMs)
end


-- The no-hover backstop: hovering is the BT's decision, and if it never picks the ability the
-- whole fight would sit in one aspect. After a long enough in-combat gap, change anyway (no dive
-- under it, so no payload). For WARRIOR this is not a backstop at all but the ONLY way out - it is
-- deliberately grounded, so its gap is the aspect's actual length.
local function forceChangeCheck(actor, key)
    if dlwChangeDue[key] then return end   -- a hover is mid-flight; its landing owns the change
    local last = dlwChangeTick[key]
    if not last then return end
    local now = STATE.FAST_TICK
    if now < last then dlwChangeTick[key] = now return end   -- clock reset (world change)
    local gap = (dlwAspect[key] == "WARRIOR") and WARRIOR_MAX_GAP_TICKS or ASPECT_MAX_GAP_TICKS
    if (now - last) < gap then return end

    local inCombat
    pcall(function() inCombat = actor.CombatState == true end)
    if not inCombat then return end

    changeAspect(actor, key, pickAspect(dlwAspect[key]), "no-hover backstop")
end


-- =======================================================================
-- ARENA WATCHER (authority) - adoption + the out-of-combat aggro check
-- =======================================================================

-- Armed from main.lua each world load. Loop, adoption and aggro check are shared with the
-- Chieftain fight (same watcher, different arena) - CFG is her half of it.
function H.Register()
    DL.ArmWatcher(CFG)
end


-- =======================================================================
-- MOTHER - entry points (authority + renderer), def-file order
-- =======================================================================

-- [RENDERER, Visuals] Base look + the silhouette glow. Tints are idempotent; the attachments
-- below run once per body (dlwLookDone).
function H.MotherVisuals(actor)
    -- Renderer half of stagger immunity (Stats' CCImmune covers authority): the forced-stagger
    -- multicast still reaches clients, and each machine reads its OWN copy of the anim fields.
    AVU.SkipStaggerAnim(actor)

    pcall(function()
        local mesh = Utils.GetValidMesh(actor)
        if mesh then mesh:SetVectorParameterValueOnMaterials(FName("Color"), LOOK_BODY) end
    end)
    pcall(function() AVU.TintComponent(actor.Helmet, { Color = LOOK_HELM }) end)

    AVU.SetShieldColor(actor, {
        Color = SHIELD_COLOR, Base = SHIELD_COLOR, Outline = SHIELD_COLOR,
        Red = SHIELD_R, Green = SHIELD_G, Blue = SHIELD_B,
        Glow = SHIELD_GLOW,
    })

    local key = Utils.ActorKey(actor)
    if not key or dlwLookDone[key] then return end
    dlwLookDone[key] = true

    AVU.AttachStaticMesh(actor, ENUMS.Components.SM_WITCH_HAT, "head", {
        Location = HAT_LOC, Rotation = HAT_ROT, Scale = HAT_SCALE, Color = HAT_COLOR,
    })

    if not SETTINGS.GAMEPLAY.REDUCE_VISUALS and GLOW_INTENSITY > 0 then
        AVU.AttachPointLight(actor, GLOW_LIGHT_BONE, {
            Location = GLOW_LIGHT_LOC,
            Color = GLOW_LIGHT_COLOR,
            Intensity = GLOW_INTENSITY,
            SourceRadius = GLOW_SOURCE_RAD,
            AttenuationRadius = GLOW_ATTEN_RAD,
        })
    end
end


-- [AUTHORITY, Stats] Field writes + fail-safe resets. Runs on every (re)mutation, so a
-- save-restored Mother always starts with no aspect (the first aggro picks one).
function H.MotherStats(actor)
    local key = Utils.ActorKey(actor)
    if key then
        for _, t in ipairs(ALL_STATE) do t[key] = nil end
    end

    AVU.CCImmune(actor)
    pcall(function() actor.Invincible = false end)
    DL.ForgetGuard(actor)

    -- Suppress the native shotgun; OnRangedAttack fires whatever the current aspect uses.
    -- The suppressed path STILL multicasts Broadcast_DoRangedAttackFX (montage + cue) - only
    -- Grunt_FireBurst is skipped - so every aspect keeps an animated attack.
    pcall(function() actor.OverrideSoldierFireLogic = true end)
    pcall(function() actor.ProjectileFireSocket = FName(FIRE_SOCKET) end)
    pcall(function() actor.RangedAttack_OnCooldown = false end)

    -- Hover pacing (JetpackDuration latches per hover)
    pcall(function() actor.JetpackDuration = HOVER_SECONDS end)
    pcall(function() actor.Cooldown_CombatAbility3 = HOVER_CD end)

    -- The native projectile DODGE jetpacks her to a RANDOM navigable point - it fights every
    -- scripted beat and this arena has drops.
    pcall(function() actor.EvadesProjectiles = false end)

    -- NEVER DisableGrenades on a witch: that flag is what UN-BLOCKS the hover + the revive.
    -- Written true HERE because the Warrior aspect borrows it as its ground lever - a body
    -- re-mutated mid-Warrior would otherwise come back permanently unable to hover.
    pcall(function() actor.CanThrowGrenades = true end)

    -- The fire trail is WARRIOR-only; applyAspectLoadout owns it from here.
    pcall(function() actor.LeaveFireWithJetpack = false end)
end


-- [OnTick] Roster prune + the aspect backstop + keep-warm.
function H.MotherTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    if actor.IsDead then return "REMOVE" end
    local key = AVU.CachedFullName(actor)   -- stable OnTick wrapper -> the memo is safe here
    if not key then return end

    -- The two range aspects run their signature ability off HER clock rather than off a takeoff:
    -- she changes aspect on every landing, so anything gated on the hover would fire once at most.
    -- Each helper owns its own cooldown + cap; this is just the 2/s knock on the door.
    local aspect = dlwAspect[key]
    if totalTicks % 5 == 0 then
        if aspect == "STORM" then
            GKW.StormGroundGrenade(actor, cadence("StormGrenade"))
        elseif aspect == "PLAGUE" then
            GKW.PlagueCloudPoll(actor, cadence("PlagueCloud"))
            GKW.PlagueGroundThrow(actor, cadence("PlagueSummon"))
        end
    end

    if totalTicks % ADD_POLL_TICKS == 9 then pruneAdds(key) end
    if totalTicks % ADD_POLL_TICKS == 13 then forceChangeCheck(actor, key) end
    if totalTicks % KEEPWARM_TICKS == 17 then
        ASSETS.WarmPinned(aspect and ASPECTS[aspect].Deps or IDLE_DEPS)
    end
end


-- [OnEnterCombat] Deferred a beat: the combat flip's target/CombatState reads lag the dispatch,
-- and nothing may run inline in the OnRep hook.
function H.MotherEnterCombat(actor)
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        local key = Utils.ActorKey(actor)
        if not key then return end
        changeAspect(actor, key, pickAspect(dlwAspect[key]), "aggro")
    end, 300)
end


-- [OnJetpack] The deliberate takeoff multicast (the evade roll calls JetpackToLocation directly,
-- so this is only ever a real hover). CHOOSES THE NEXT ASPECT NOW, not on touchdown - deciding
-- early is what lets the landing watcher clear FlameOnLanding mid-dive without depending on the
-- OnLanded hook firing at all. Arms the one-shot + a generation, then schedules the touchdown
-- watcher. The CURRENT aspect still gets its takeoff signature - she lands as something else.
function H.MotherJetpack(actor)
    if Utils.IsActorInvalid(actor) then return end
    local key = Utils.ActorKey(actor)
    if not key then return end

    -- She must not come down still gated by a fire-cadence hold.
    pcall(function() actor.RangedAttack_OnCooldown = false end)

    local current = dlwAspect[key]
    if current == "STORM" then
        GKW.StormJetpack(actor)    -- the sister's takeoff nova (own 4s gate)
    elseif current == "PLAGUE" then
        GKW.PlagueJetpack(actor)   -- the sister's apex Mini Pestilence toss (own cd + cap)
    end

    local aspect = pickAspect(current)
    dlwNext[key] = aspect
    dlwChangeDue[key] = true
    local gen = (dlwHoverGen[key] or 0) + 1
    dlwHoverGen[key] = gen

    ASSETS.WarmPinned(ASPECTS[aspect].Deps or {})
    ASSETS.WarmPinned(IDLE_DEPS)
    LogDebug("Mother of the Fallow - hover up, will land as " .. ASPECTS[aspect].Label,
        SETTINGS.DEBUG_NPC_ACTIONS)

    Utils.QueueWork(function() landingWatch(actor, key, gen, LANDING.Tries) end,
        HOVER_SECONDS * 1000 + LANDING.FirstMs)
end


-- [OnLanded, PRE] The FAST PATH into that one-shot - the cycle does not depend on it (see the
-- watcher). Every landing routes here; the takeoff one-shot, not FlameOnLanding, is the gate.
function H.MotherLanded(actor)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end
    local key = Utils.ActorKey(actor)
    if not key or not dlwChangeDue[key] then return end
    landingChange(actor, key, "landing")
end


-- [OnRangedAttack, PRE] The suppressed shotgun's replacement, by aspect. Storm and Plague reuse
-- the sisters' fire paths (each owns its cadence gate + BT release). WARRIOR splits by ALTITUDE:
-- native shotgun on the ground, suppressed + sister's fireball in the air. PRE hook, so writing
-- OverrideSoldierFireLogic here still decides THIS shot - the split self-heals on any airborne path.
function H.MotherRangedAttack(actor)
    if Utils.IsActorInvalid(actor) or not Utils.IsAuthority() then return end
    local key = Utils.ActorKey(actor)
    if not key then return end
    local aspect = dlwAspect[key]

    if aspect == "WARRIOR" then
        local air = isAirborne(actor)
        pcall(function() actor.OverrideSoldierFireLogic = air end)
        if air then GKW.WarriorRangedAttack(actor) end
    elseif aspect == "STORM" then
        GKW.StormRangedAttack(actor)
    elseif aspect == "PLAGUE" then
        -- Much slower than the sister's: her plague form pressures with clouds and pestilences,
        -- and a quill every 4s reads as the punctuation between them.
        GKW.PlagueRangedAttack(actor, cadence("PlagueQuill"))
    else
        -- No aspect yet (aggroed before the entry hook landed): release the task or the BT sits in
        -- the aim pose waiting on a CombatReset that never comes.
        Utils.QueueWork(function() AVU.ReleaseSoldierBT(actor) end, 300)
    end
end


-- [OnMeleeSwing] Warrior's kick throws a fireball on the SWING (hit or miss) - the sister's own
-- gated payload. Storm rides the IMPACT instead, Plague keeps a plain kick.
function H.MotherMeleeSwing(actor)
    if Utils.IsActorInvalid(actor) then return end
    local key = Utils.ActorKey(actor)
    if not key or dlwAspect[key] ~= "WARRIOR" then return end
    Utils.QueueWork(function() GKW.WarriorKickSwing(actor) end, GKW.KICK_SWING_FIRE_MS)
end


-- [OnMeleeImpact] Every connecting kick gets the family kick profile (short back + up, so a hit on
-- a ledge is not a death sentence); Storm's also discharges the nova (shared gate, in the helper).
function H.MotherMeleeImpact(actor)
    if Utils.IsActorInvalid(actor) then return end
    GKW.KickDamp(actor)
    local key = Utils.ActorKey(actor)
    if not key or dlwAspect[key] ~= "STORM" then return end
    GKW.StormImpact(actor)
end


function H.MotherDeath(actor)
    H.EndChannel(actor)   -- a stuck LockedInPlaceMontage must never outlive the fight
    DL.ForgetGuard(actor)
    local key = Utils.ActorKey(actor)
    if key then
        for _, t in ipairs(ALL_STATE) do t[key] = nil end
    end
    DL.ForgetBoss(CFG)

    -- The class only sets Fracture_DL_Witch_Dead on a player-credited or player-aligned kill; any
    -- other death would silently stall the Fracture questline.
    DL.FlagBackstop(CFG)

    -- ...and start the respawn clock (DL.RESPAWN_DAYS from now).
    DL.NoteBossDeath(CFG)
end


-- [DamageGate] Ignore hits thrown in from outside the arena (shared - see DL.OutOfArena).
function H.MotherDamageGate(actor)
    return DL.OutOfArena(CFG, actor)
end


-- Release the channel hold. Idempotent, and every exit path calls it.
function H.EndChannel(actor)
    if Utils.IsActorInvalid(actor) then return end
    local key = Utils.ActorKey(actor)
    if key then dlwIdleGen[key] = (dlwIdleGen[key] or 0) + 1 end   -- orphan any in-flight chain
    AVU.HoldStill(actor, false)

    -- End the dance WITH the hold - the montage outlasts the channel, so left alone it plays on
    -- while she is fighting again. Stopped BY ASSET, never "the active montage": this also runs on
    -- death, and a blanket stop there would cut her death animation.
    pcall(function()
        local dance = ASSETS.GetIfValid(IDLE_ANIM)
        if IsValid(dance) then AVU.CancelAnim(actor, dance) end
    end)
    local base = key and dlwStagger[key]
    if base then pcall(function() actor.StaggerCooldown = base end) end
end


-- =======================================================================
-- ACOLYTES - a sister witch at half HP / half shield, with her kit
-- =======================================================================

-- Shared [AUTHORITY, Stats]: half shield, no loot (three chaff witches at native loot is a
-- pinata), no evade roll (unaimed, and this arena has drops).
--   * Grenades deliberately untouched (see MotherStats - the flag gates the witch's slots).
local function acolyteBase(actor)
    AVU.SetBodyShield(actor, { Max = ACOLYTE_SHIELD, Current = ACOLYTE_SHIELD })
    AVU.ClearLoot(actor)
    pcall(function() actor.EvadesProjectiles = false end)
    pcall(function() actor.LeaveFireWithJetpack = false end)
end

function H.WarriorAcolyteStats(actor)
    acolyteBase(actor)   -- keeps the native shotgun: the kick fireball is its aspect tell
end

function H.StormAcolyteStats(actor)
    acolyteBase(actor)
    pcall(function() actor.OverrideSoldierFireLogic = true end)   -- the bolt replaces the pellets
    pcall(function() actor.DefaultGravityScale = ACOLYTE_GRAVITY_STORM end)
    pcall(function() actor.CharacterMovement.GravityScale = ACOLYTE_GRAVITY_STORM end)
end

function H.PlagueAcolyteStats(actor)
    acolyteBase(actor)
    pcall(function() actor.OverrideSoldierFireLogic = true end)   -- the quill replaces the pellets
    pcall(function() actor.ProjectileFireSocket = FName(FIRE_SOCKET) end)
end

-- Looks are the sisters' own, unchanged: an acolyte should read as that aspect at a glance.
H.WarriorAcolyteLook = function(actor)
    pcall(function()
        local mesh = Utils.GetValidMesh(actor)
        if mesh then mesh:SetVectorParameterValueOnMaterials(FName("Color"), ASPECTS.WARRIOR.Body) end
    end)
    pcall(function() AVU.TintComponent(actor.Helmet, { Color = ASPECTS.WARRIOR.Helm }) end)
end
H.StormAcolyteLook  = GKW.StormLook
H.PlagueAcolyteLook = GKW.PlagueLook

-- The kick fireball, on the SWING (hit or miss) - same shape as the sister's def.
function H.WarriorAcolyteSwing(actor)
    if Utils.IsActorInvalid(actor) then return end
    Utils.QueueWork(function() GKW.WarriorKickSwing(actor) end, GKW.KICK_SWING_FIRE_MS)
end

-- Every acolyte kick gets the family profile too - three of them punting people off the platform
-- was the whole problem. Storm's also discharges its nova.
H.WarriorAcolyteImpact = GKW.KickDamp
H.PlagueAcolyteImpact  = GKW.KickDamp
function H.StormAcolyteImpact(actor)
    GKW.KickDamp(actor)
    GKW.StormImpact(actor)
end

function H.WarriorAcolyteDeath(actor) GKW.WarriorCleanup(actor) end
function H.StormAcolyteDeath(actor)   GKW.StormCleanup(actor) end
function H.PlagueAcolyteDeath(actor)  GKW.PlagueCleanup(actor) end


-- =======================================================================
-- DEBUG - encounter reset (/dlreset witch, ChatCommands)
-- =======================================================================

-- Destroy our acolytes (no loot/FX), wipe fight state, heal + clear the Mother. With no living
-- Mother, a fresh one is put on the field - through her spawner where that still works, else
-- spawned directly (a world flag can never be un-set, so a save where she has died can only ever
-- get a direct spawn).
function H.ResetWitch()
    if not Utils.IsAuthority() then return end

    -- Sweep around HER when she is alive (she roams; the acolytes are wherever she landed), else
    -- around the arena.
    local boss = DL.Boss(CFG)
    local center = WITCH_ARENA
    if boss then
        pcall(function() local l = boss:K2_GetActorLocation(); center = FVector(l.X, l.Y, l.Z) end)
    end

    -- Acolytes are base-witch bodies carrying a variant tag; the boss is a DIFFERENT class, so
    -- this scan can never catch her.
    local VT = require("AnteVariants.VariantTag")
    local destroyed = 0
    local hits = AVU.GetNearbyActorsOfClass(center, ARENA_SCAN_RADIUS,
        ENUMS.NpcClasses["Gatekeeper_Witch"])
    for i = 1, #hits do
        pcall(function()
            local m = hits[i]:get()
            if Utils.IsActorValid(m) and VT.Decode(m) ~= nil then
                m:K2_DestroyActor()
                destroyed = destroyed + 1
            end
        end)
    end

    -- Release the channel FIRST: EndChannel restores her stashed StaggerCooldown out of
    -- dlwStagger, and the wipe below is what would take that stash away.
    if boss then H.EndChannel(boss) end

    for _, t in ipairs(ALL_STATE) do
        for k in pairs(t) do t[k] = nil end
    end

    if boss then
        pcall(function() boss.Invincible = false end)
        DL.ForgetGuard(boss)
        pcall(function() boss.RangedAttack_OnCooldown = false end)
        pcall(function() boss.FlameOnLanding = false end)
        pcall(function() boss.CanThrowGrenades = true end)   -- undo a Warrior ground hold
        pcall(function() boss:InitalizeHealthValues(true) end)   -- heal limbs from NPCData
        AVU.SetBodyShield(boss, { Max = MOTHER_SHIELD_HP, Current = MOTHER_SHIELD_HP,
            Regen = MOTHER_SHIELD_REGEN, RegenTime = 8, RegenTimeZero = 15 })
        H.MotherVisuals(boss)
        -- The aspect is wiped, so put her stock bark back (a muting aspect had cleared it).
        pcall(function()
            local cue = ASSETS.GetIfValid(ENUMS.SOUNDS.SHOTGUN_MILITARY_FIRE)
            if IsValid(cue) then boss.WeaponFireSound = cue end
        end)
        Utils.Log(string.format("DL witch reset: Mother cleared, %d acolytes destroyed", destroyed))
    else
        DL.NoteFlagLocked(CFG)
        DL.RespawnBoss(CFG, string.format("%d acolytes destroyed", destroyed))
    end
end


return H
