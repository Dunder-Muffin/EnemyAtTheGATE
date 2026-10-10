-- =======================================================================
-- CombatHooks (AUTHORITY ONLY) - variant combat behavior.
--
-- Dispatch is generic: the actor's VariantTag (serverDef below) picks its def in the Variants
-- registry. The ATTACKER side still goes by its address-cached display name (DamageCauserName):
--   def.OnDealtDamage(attacker, victim)  - variant dealt damage
--   def.OnDamageTaken(victim, damage)    - variant took damage
--   def.OnDeath(actor)                   - variant died
--   def.OnGibbed(actor)                  - variant's corpse was gibbed
--   def.OnDBNO(actor)                    - variant entered DBNO (down-but-not-out)
--   def.OnEnterCombat(actor)             - variant aggroed (entered combat)
--   def.OnExitCombat(actor)              - variant disengaged (left combat; NOT on DBNO)
--   def.OnWindupAttack(actor)            - Exor channels its beam attack
--   def.OnGrab(actor)                    - a Reaper's grab LANDED (read actor.HoldingCharacter)
--   def.OnScoutContact(actor, SwingAt)   - a ReaperScout's melee contact, PRE its summon call
--                                          (SwingAt is a param WRAPPER - :get() it)
--   def.OnLeapWindup(actor)              - a pest began its leap windup (aim is still writable;
--                                          0.2s for variants - the apoc-leap hook forces it)
--   def.OnCharge(actor)                  - a peccary began its charge windup, or a Tarasque began
--                                          its stampede
--   def.OnChargeEnd(actor)               - a peccary's charge ENDED, detonation or not (PRE of the
--                                          Broadcast_StampedeEnd multicast)
--   def.OnSlam(actor)                    - a Tarasque began its fist-slam montage (PRE: the smash
--                                          notify has not fired yet)
--   def.OnHealthStage(actor)             - the NPC's health-texture stage dropped (POST). On a
--                                          Symphonist that IS the mirage arm point - see the
--                                          CLASS_HOOKS entry
--
-- Declarative, not a dispatch, but applied by a hook here:
--   def.DeployableDamage = { <family> = mult } - scale what this variant does to BARRICADES /
--                                          TURRETS / the Chopinator (AVU.DeployableDamageMult)
--   def.LeapSpeed = 0..1                 - Exor_Volatile only: fraction of the native leap's
--                                          launch speed, for a pounce the player can step out of
--                                          (see registerExorLeapHook)
--   def.OnChargeImpact(actor)            - a peccary's charge DETONATED (POST - the blast damage
--                                          has already landed; see the CLASS_HOOKS entry)
--
-- CLASS_HOOKS pass a single callback to RegisterHook, so they are **PRE** hooks - the handler runs
-- BEFORE the native body. A handler that wants to overwrite something the body itself writes must
-- QueueWork the write a beat later (see OnLeapWindup).
--
-- Two hook tiers:
--   * Base-class hooks (ProcessDamage / OnRep_IsDead / OnRep_IsGibbed on the always-loaded
--     Abiotic_Character_ParentBP / NPC_Base_ParentBP) - registered eagerly in Register().
--   * Class-specific hooks (e.g. NPC_Exor_Monk_C:Broadcast_WindupAttack) - the UFunction doesn't
--     resolve until an instance is in memory, so RegisterClassHooks(rowName) registers them on
--     first mutation of that NPC, deduped so two variants of one base can't double-register.
--
-- ProcessDamage on the character parent is the reliable damage hook; the native
-- ReceivePointDamage / ReceiveRadialDamage hooks never fire.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local Utils = require("AnteUtils.Utils")
local VARIANTS = require("AnteVariants.Variants")
local RESISTS = require("AnteData.NpcResistances")
local ENUMS = require("AnteData.Enums")
local PROF = require("AnDebug.Profiler")

local LogBad = Utils.LogBad

local HOOKS = {}

-- Every callback in this file is the authority's. It is registered only there, but RegisterHook can't
-- be undone: a process that leaves single player and joins a server keeps every one of them, and the
-- engine dispatches them on that client too ([[anteup2-server-hooks-outlive-role]]). Hence a per-call check.
local function live() return STATE.ModEnabled and Utils.IsAuthority() end

-- Feature modules that watch every hit (ModuleSCT) register here, so this file never names them.
-- Observers run after the ProcessDamage bails: never for a freed or dead victim, and with a dead
-- causer already squashed to nil.
local damageObservers = {}

function HOOKS.SetDamageObserver(key, fn)
    damageObservers[key] = fn
end

local function notifyDamageObservers(victim, attacker, instigatedBy, damageType)
    if not next(damageObservers) then return end
    local instigator, dt = instigatedBy:get(), damageType:get()
    for key, fn in pairs(damageObservers) do
        local ok, err = pcall(fn, victim, attacker, instigator, dt)
        if not ok then LogBad("damage observer [" .. key .. "]: " .. tostring(err)) end
    end
end

-- Class-specific hooks, keyed by base NPC row name
--   * path     - the UFunction to hook
--   * dispatch - the variant's defintion field to call (e.g. fn(actor))

-- Shared by all three Lamogi rows below - they all resolve this UFunction at the parent only.
local LAMOGI_BUMP_HOOK =
    "/Game/Blueprints/Characters/NPCs/NPC_Monster_WinterSprite.NPC_Monster_WinterSprite_C:Broadcast_MeleeAttackImpact"

local CLASS_HOOKS = {
    Exor_Monk = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Exor_Monk.NPC_Exor_Monk_C:Broadcast_WindupAttack",
          dispatch = "OnWindupAttack"
        },
        -- The Monk's slot-3 blink announces itself through this NetMulticast, with BOTH
        -- endpoints as params -> def.OnTeleport(actor, PreviousLocation, NewLocation)
        -- (param WRAPPERS via passParams - copy the scalars inside the handler). The
        -- Shadow Monk re-fires the same multicast for its decoy trail, so its handler
        -- MUST guard against its own echo (a server-side call dispatches locally through
        -- this hook too).
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Exor_Monk.NPC_Exor_Monk_C:Broadcast_TeleportFX",
          dispatch = "OnTeleport", passParams = true
        },
    },
    -- The Exor Wraith drives its double-tap off the windup channel. The Ally doesn't override
    -- Broadcast_WindupAttack, so the UFunction only resolves at the PARENT (Pikeman) path - hook
    -- that; it fires for real Pikemen too, but dispatchVariant's name lookup filters to the Wraith.
    Exor_Pikeman_Ally = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Exor_Pikeman.NPC_Exor_Pikeman_C:Broadcast_WindupAttack",
          dispatch = "OnWindupAttack"
        },
    },
    -- The Volatile Exor's low-HP self-destruct. The DECISION is upstream and unreachable
    -- (OnHealthChanged rolls SelfDetonateChance ONCE behind a DoOnce latch), so we hook the COMMIT
    -- point: PerformSelfDetonation plays its montage, waits 1.2s, THEN gibs + fires the radial
    -- blast. That 1.2s telegraph is a scheduling beat - the Acidic Exor lands its bigger acid
    -- burst on the same frame as the native one.
    Exor_Volatile = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Exor_Volatile.NPC_Monster_Exor_Volatile_C:PerformSelfDetonation",
          dispatch = "OnSelfDetonate"
        },
        -- Swing START, for the Hunter's post-swing pause. Same always-loaded NPC_Base path as the
        -- Witch/Rook/Clericus rows, so the path+dispatch dedup keeps it to one hook.
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C:Broadcast_DoMeleeAttackFX",
          dispatch = "OnMeleeSwing"
        },
    },
    -- THE PEST LEAP WINDUP. Server_DoMeleeAttack sets LastPestLeapAtLocation (= the target's EYES),
    -- yaw-faces it, latches MeleeAttack_OnCooldown, then waits a Delay before the launch label
    -- re-reads that aim point - so the leap's destination stays writable through the windup. The
    -- Delay is 0.2s vs 0.5s by difficulty, and the apoc-leap hook (registerPestApocLeapHook) forces
    -- the 0.2s branch for every mutated pest variant - so plan on a 200ms window. This is a PRE
    -- hook (see the header), i.e. it fires BEFORE the native aim write, so a handler must defer its
    -- own write by a beat or the native one lands on top of it.
    -- Lives on NPC_Monster_Pest (no pest subclass overrides it), so it fires for every pest and the
    -- name lookup filters to defs declaring OnLeapWindup.
    -- BOTH ROWS REGISTER IT, and that is not redundant: CLASS_HOOKS is installed lazily on the
    -- first mutation of THAT ROW, so with only Razor Pests in the world a Pest_Snow-only entry
    -- never fires. The dedup key is path|dispatch, so the two still install ONE hook.
    Pest_Snow = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Pest.NPC_Monster_Pest_C:Server_DoMeleeAttack",
          dispatch = "OnLeapWindup"
        },
    },
    Pest = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Pest.NPC_Monster_Pest_C:Server_DoMeleeAttack",
          dispatch = "OnLeapWindup"
        },
    },
    -- ElectroPest fires its shock ring at the start of (some) leaps; Laser Pest
    -- uses it to time its laser burst to AFTER a leap. The tamed Laser Pest and Telepest keep
    -- their body discharged (no ring), so they time off the leap windup instead.
    Pest_Electro = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Pest_Electro.NPC_Monster_Pest_Electro_C:Server_ShockRingDamage",
          dispatch = "OnShockRing"
        },
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Pest.NPC_Monster_Pest_C:Server_DoMeleeAttack",
          dispatch = "OnLeapWindup"
        },
    },
    -- NO Grunt_FlameRat entry - the Cinderlord's burst cycle was scrapped, leaving no consumer. If
    -- a FlameRat variant needs a per-shot beat again, this is the ONE reliably hookable point on
    -- that class (everything else goes through EX_LocalVirtualFunction - the Tarasque trap):
    --   "/Game/Blueprints/Characters/NPCs/NPC_FlameRat.NPC_FlameRat_C:Server_DoRangedAttack"

    -- Symphonist's mirage ability; the Orchestrator re-spawns minions in its place.
    Symph = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Symphonist.NPC_Monster_Symphonist_C:ActivateMirage",
          dispatch = "OnMirage"
        },
        -- THE MIRAGE ARM POINT - the only place a Symphonist ever wants one.
        -- `UpdateHealthTextureIndex` is the parent's health-texture-stage updater, which the
        -- Symphonist overrides to ALSO set `WantsToActivateMirage = true` + `Invincible = true` on
        -- the server. `BTD_WantsToMirage` reads that flag; nothing else ever sets it. So this is
        -- the seam for a variant that wants no mirage at all - see H.MinionNoMirage, and note it
        -- MUST clear Invincible too (BTT_DoCombatMirage is what normally clears it, and a
        -- suppressed mirage means that task never runs).
        -- *** POST, not PRE ***: it is reached by EX_LocalVirtualFunction from
        -- OnRep_CurrentHealthTextureIndex, so our callback runs after the body
        -- ([[ue4ss-local-script-call-hook-is-post]]) - which is what a suppressor needs. If that
        -- ever inverted, the failure mode is benign: the flags get re-set and the mirage behaves
        -- exactly as it does today.
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Symphonist.NPC_Monster_Symphonist_C:UpdateHealthTextureIndex",
          dispatch = "OnHealthStage"
        },
    },
    -- NO Exor ammo hook: OnCurrentAmmoUpdated is the CLIENT-side quill-mesh OnRep updater (fires
    -- where rendered, not on the authority). Magma Exor polls CurrentAmmoCount in OnTick instead.

    -- THE PECCARY CHARGE WINDUP (ability slot 1). Broadcast_CombatAbility1 is the multicast that
    -- StopMovementImmediately's, kills avoidance and starts Anim_Peccary_Charge_Start_Montage, then
    -- RetriggerableDelay(montageLen - 0.1) before the stampede itself - so this fires at the very
    -- top of the telegraph, which is exactly where a variant wants to lay down cover FX. It lives on
    -- NPC_Monster_Peccary (Snow/Sow/Armored all inherit it un-overridden), so it fires for every
    -- peccary and the name lookup filters to defs declaring OnCharge.
    Peccary_Snow = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Peccary.NPC_Monster_Peccary_C:Broadcast_CombatAbility1",
          dispatch = "OnCharge"
        },
        -- Snow Peccary tail-throw -> the Whiteout Peccary lobs a frost shell instead of the native ice
        -- ball (whose 1500 speed + gravity 1.0 falls short of where this thing actually engages).
        -- Server_DoRangedAttack IS a Peccary_Snow override, so it resolves at that class.
        -- NOTE the native sequence is turn -> 0.5s -> AboutToThrow -> 0.5s -> fire, so a handler
        -- that wants to land on the tail-throw animation has to wait ~1s, not fire on the hook.
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Peccary_Snow.NPC_Monster_Peccary_Snow_C:Server_DoRangedAttack",
          dispatch = "OnRangedAttack"
        },
    },
    -- THE PECCARY CHARGE IMPACT (the other end of the same ability).
    -- Server_EndChargeImpact is the ONLY thing that fires the charge blast
    -- (ApplyRadialDamageWithFalloff at ChargeDamageAmount over AOE_RadialForce.Radius, plus the
    -- impulse), and the ubergraph reaches it only on a DETONATING charge - a stampede cancelled by
    -- a stagger takes the other branch. So this dispatch means "the charge actually connected",
    -- which a damage hook cannot tell you: OnDealtDamage is handed (attacker, victim) and no
    -- damage type, so a blast hit is indistinguishable from a bite.
    -- *** IT IS A POST HOOK, NOT A PRE ONE. *** The ubergraph calls it via
    -- EX_LocalVirtualFunction, and a BP-to-BP local call runs the body BEFORE our callback
    -- ([[ue4ss-local-script-call-hook-is-post]]) - which is what we want here: the victims are
    -- already resolved, so a handler reads the aftermath instead of racing it.
    -- Lives on NPC_Monster_Peccary, so it covers Snow/Sow/Armored too; the name lookup filters to
    -- defs declaring OnChargeImpact.
    Peccary = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Peccary.NPC_Monster_Peccary_C:Server_EndChargeImpact",
          dispatch = "OnChargeImpact"
        },
        -- The WINDUP half, same UFunction the Peccary_Snow row asks for. It is listed twice on
        -- purpose: the hook PATH is on NPC_Monster_Peccary and covers every peccary, but
        -- RegisterClassHooks is LAZY PER ROW - so a base-"Peccary" variant declaring OnCharge would
        -- never see it until some Peccary_Snow happened to mutate first. The path|dispatch dedup
        -- installs exactly one hook whichever row gets there first.
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Peccary.NPC_Monster_Peccary_C:Broadcast_CombatAbility1",
          dispatch = "OnCharge"
        },
        -- THE CHARGE END, detonation or not: Broadcast_StampedeEnd is the multicast the ubergraph
        -- fires as IsStampeding drops (EX_VirtualFunction, so PRE). The stampede's own cleanup -
        -- walk speed, the emissive reset - runs on the NEXT UpdateStampede pass after it.
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Peccary.NPC_Monster_Peccary_C:Broadcast_StampedeEnd",
          dispatch = "OnChargeEnd"
        },
    },
    -- The Alpha is a pure data reskin of NPC_Monster_Peccary (it overrides no UFunction at all), so
    -- the same parent path serves it. Listed on its own row because RegisterClassHooks is lazy PER
    -- ROW - a world with only Alphas in it would otherwise never install the windup hook.
    Peccary_Alpha = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Peccary.NPC_Monster_Peccary_C:Broadcast_CombatAbility1",
          dispatch = "OnCharge"
        },
    },
    -- THE EXOR'S RANGED SHOT. Exor_Armored does NOT override Server_DoRangedAttack - it only
    -- resolves on NPC_Monster_Exor (its parent), so hook THAT path (the Chieftain/Yeti pattern)
    -- and let the name lookup filter to defs declaring OnRangedAttack.
    -- *** IT FIRES ONCE PER SHOT, NOT ONCE PER BURST. *** The body is
    -- super -> FireRanged_Projectile -> CurrentBurst++ -> CombatReset, and the burst is paced by a
    -- RetriggerableDelay(CurrentBurst >= MaxBurstFire ? RangedAttack_Cooldown : 0.25) that lets the
    -- BT fire again. So a handler that fires something expensive must set MaxBurstFire = 1, or it
    -- runs once per round of the volley.
    Exor_Armored = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Exor.NPC_Monster_Exor_C:Server_DoRangedAttack",
          dispatch = "OnRangedAttack"
        },
    },
    -- Same UFunction, listed twice on purpose (the Peccary pattern): the PATH lives on
    -- NPC_Monster_Exor and covers every Exor, but RegisterClassHooks is LAZY PER ROW, so a
    -- base-"Exor" variant declaring OnRangedAttack would never see it until some Exor_Armored
    -- happened to mutate first. path|dispatch dedup installs exactly one hook either way.
    -- *** PRE, so LastRangedAttackLocation is still the PREVIOUS shot's aim inside the handler. ***
    -- The Antefire's scripted bolt defers a beat to read this shot's.
    Exor = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Exor.NPC_Monster_Exor_C:Server_DoRangedAttack",
          dispatch = "OnRangedAttack"
        },
    },
    -- Sow tail-throw; the Hive Sow uses it to apply the bee swarm. The carbunclebomb's damage
    -- doesn't attribute to the Sow, so a damage hook can't see it - this fires when it throws.
    Sow = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Peccary_Sow.NPC_Peccary_Sow_C:Server_DoRangedAttack",
          dispatch = "OnRangedAttack"
        },
    },
    -- Tarasque revives from DBNO (Phase 2 -> Phase 1). The spawner Tarasque summons an Armored
    -- Peccary at the start of every Phase 1 (the first one comes from OnReady).
    -- The two ability multicasts are the family's only PRE seams: everything downstream of them
    -- (PerformSmash, Server_EndChargeImpact, ConcussNearbyPlayers) is EX_LocalVirtualFunction.
    --   * CombatAbility1 = the STAMPEDE opening - StopMovementImmediately, then WalkSpeed 900 and
    --     a forward AddMovementInput on tick. Nothing precedes it but the aggro roar, so this is
    --     where a variant lays down its own wind-up.
    --   * CombatAbility2 = the fist-slam montage. Its SmashLight/SmashHeavy notifies are what
    --     deal the damage, at the body's position when they fire - so a variant that wants the
    --     slam to commit to a SPOT has to mark it here.
    Tarasque = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Tarasque.NPC_Monster_Tarasque_C:TarasqueRevive",
          dispatch = "OnRevive"
        },
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Tarasque.NPC_Monster_Tarasque_C:Broadcast_CombatAbility1",
          dispatch = "OnCharge"
        },
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Tarasque.NPC_Monster_Tarasque_C:Broadcast_CombatAbility2",
          dispatch = "OnSlam"
        },
    },
    -- Musketeer fires its crossbow; the Marksman launches its own flat holy shot instead (the
    -- native projectile is suppressed). The GUARD subclass inherits the same un-overridden
    -- UFunction, so both rows point at the parent path and the dispatch's throttle de-dupes.
    Pillager_Musketeer = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Pillager_Musketeer.NPC_Pillager_Musketeer_C:Server_DoRangedAttack",
          dispatch = "OnRangedAttack"
        },
    },
    Pillager_Musketeer_GUARD = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Pillager_Musketeer.NPC_Pillager_Musketeer_C:Server_DoRangedAttack",
          dispatch = "OnRangedAttack"
        },
    },
    -- THE REAPER'S GRAB LANDING - the one moment a Reaper variant can act on, and the only
    -- hookable point in the whole grab chain. Everything around it is closed:
    -- Server_PerformGrabHoldSequence / CanGrabValidTarget / OnTargetDamaged are all
    -- EX_LocalVirtualFunction (the Tarasque trap), and this multicast is what the parent fires once
    -- HoldingCharacter is already set - so the handler can just read it. See AnteNPCs/ShadesHelpers.
    Reaper = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Reaper.NPC_Monster_Reaper_C:Broadcast_DoSuccessfulGrabAnimation",
          dispatch = "OnGrab"
        },
        -- Swing START - the only seam early enough to beat the Reaper's own kill-despawn: the
        -- ProcessDamage dispatch is effectively POST and the killing blow trips the
        -- hazard-corpse bail, so OnDealtDamage never fires on exactly the lethal hit
        -- (H.ReaperSwing hides the controller across the whole swing instead). Same
        -- path|dispatch as the Rook/Clericus rows -> one shared hook.
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C:Broadcast_DoMeleeAttackFX",
          dispatch = "OnMeleeSwing"
        },
    },
    -- The Yeti extends NPC_Monster_Tarasque (it only re-points montages), so both its light and
    -- heavy smashes land through the Tarasque's PerformSmash. Hook the PARENT path - the only
    -- place the UFunction resolves - and let the name lookup filter to the Yeti def. Blizzard
    -- Yeti kicks up a storm on each jump attack. See [[af-decompiled-bp-source]].
    Yeti = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Monster_Tarasque.NPC_Monster_Tarasque_C:PerformSmash",
          dispatch = "OnSmash"
        },
    },
    -- The Trident picks its weapon PER SHOT (net on a full magazine, else the native magnum
    -- burst), which works because this is a PRE hook: OverrideSoldierFireLogic written in the
    -- handler decides the shot that is about to fire ([[anteup2-per-shot-gun-override]]).
    -- NPC_Soldier_Captain does not override Server_DoRangedAttack, so it rides the shared soldier
    -- path like the Chieftain and the path+dispatch dedup keeps that hook single.
    Grunt_Captain = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Soldier_Grunt.NPC_Soldier_Grunt_C:Server_DoRangedAttack",
          dispatch = "OnRangedAttack"
        },
    },
    -- The Chieftain does NOT override Server_DoRangedAttack - it only resolves on NPC_Soldier_Grunt
    -- (its grandparent), so hook the SOLDIER path (the Wraith/Yeti pattern). It fires for EVERY
    -- Order-soldier ranged attack and dispatchVariant filters to defs declaring OnRangedAttack.
    -- With OverrideSoldierFireLogic the native flow still runs (montage + sound multicast) but
    -- returns before the hitscan burst - this hook is where the variant lobs its own projectile.
    Gatekeeper_Chieftain = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Soldier_Grunt.NPC_Soldier_Grunt_C:Server_DoRangedAttack",
          dispatch = "OnRangedAttack"
        },
        -- Melee SWING - per attempt, hit or miss, and it carries LastMeleeAttackType, which is how
        -- the Warchief tells a grab from an ordinary swing. Same always-loaded NPC_Base path as
        -- the Witch/Rook/Clericus rows, so the path+dispatch dedup keeps it to one hook.
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C:Broadcast_DoMeleeAttackFX",
          dispatch = "OnMeleeSwing"
        },
    },
    -- The DarkLens Chieftain (Fallow Patriarch) is a thin skin over the Chieftain and, like
    -- it, never overrides Server_DoRangedAttack - same shared soldier path, deduped.
    DarkLens_Chieftain = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Soldier_Grunt.NPC_Soldier_Grunt_C:Server_DoRangedAttack",
          dispatch = "OnRangedAttack"
        },
    },
    -- The Neophyte Trainer (Gatekeeper_Phyter) spits a BURST of goo lobs in place of the native
    -- hitscan rifle burst. Like the Chieftain it doesn't override Server_DoRangedAttack, so it
    -- rides the SAME soldier path - the path+dispatch dedup keeps that hook single when both exist.
    Gatekeeper_Phyter = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Soldier_Grunt.NPC_Soldier_Grunt_C:Server_DoRangedAttack",
          dispatch = "OnRangedAttack"
        },
    },
    -- The Mystagogue's fireball beat. Its body is Delay(FireballDelay) -> FireRanged_Projectile off
    -- the FireballProjectile handle, so blanking that handle leaves this dispatch as the whole
    -- attack (the Abjurer's spore ball). The cast montage and muzzle cue live in FireWeaponFX, a
    -- separate call, so suppressing the spawn costs no animation. NPC_Mage_DarkLens inherits the
    -- same UFunction and the name lookup filters it out - no DarkLens def declares OnRangedAttack.
    Gatekeeper_Mage = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Mage.NPC_Mage_C:Server_DoRangedAttack",
          dispatch = "OnRangedAttack"
        },
    },
    -- The breacher's shotgun blast rides the same shared soldier path (Grunt_Shotgun overrides
    -- Grunt_FireBurst, never Server_DoRangedAttack). PRE, so CurrentAmmoCount is still the
    -- PRE-shot count here - which is what lets the Skirmisher script a per-shell dance.
    Grunt_Shotgun = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Soldier_Grunt.NPC_Soldier_Grunt_C:Server_DoRangedAttack",
          dispatch = "OnRangedAttack"
        },
    },
    -- The Sapper is the one Order soldier that DOES override Server_DoRangedAttack - its copy
    -- calls super for the montage and then spawns the AT rocket - so hook ITS path, not the shared
    -- soldier one. Engine-dispatched, so this is a real PRE hook: the handler sees the shot that is
    -- about to leave, which is what the Super Sapper times its follow-up rocket from.
    --   * The melee multicast is the always-loaded NPC_Base path shared with the Witch/Rook rows;
    --     the dedup keeps it single. Fires per ATTEMPT, hit or miss, which is what a swing whose
    --     payload is two detonations wants.
    Grunt_Sapper = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Sapper.NPC_Sapper_C:Server_DoRangedAttack",
          dispatch = "OnRangedAttack"
        },
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C:Broadcast_DoMeleeAttackFX",
          dispatch = "OnMeleeSwing"
        },
    },
    -- The Jotun Rocketeer suppresses its LMG (OverrideSoldierFireLogic) and fires a plasma bolt -
    -- same shared soldier path as the Chieftain/Phyter, kept single by the path+dispatch dedup.
    Gatekeeper_Heavy = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Soldier_Grunt.NPC_Soldier_Grunt_C:Server_DoRangedAttack",
          dispatch = "OnRangedAttack"
        },
    },
    -- The DarkLens Heavy (Jotun of the Fallow) OVERRIDES Broadcast_ReloadWeapon - that override is
    -- where its mortar volley lives - so the eager NPC_Base OnReload hook may never resolve on it
    -- (the Witch's Broadcast_CombatAbility3 lesson). Hook ITS copy. Harmless if the parent's hook
    -- does also fire: def.OnReload only stamps a tick and re-asserts a time dilation, so a double
    -- dispatch in one frame is a no-op.
    DarkLens_Heavy = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Gatekeeper_Heavy_DarkLens.NPC_Gatekeeper_Heavy_DarkLens_C:Broadcast_ReloadWeapon",
          dispatch = "OnReload"
        },
    },
    -- The Fallow Steed swings on a scripted release valve, so it needs the per-attempt melee
    -- multicast. Same always-loaded NPC_Base path as the Witch/Rook/Clericus entries - the
    -- path+dispatch dedup installs ONE hook however many rows ask for it, and the name lookup
    -- filters it to defs that actually declare OnMeleeSwing.
    Peccary_Armored = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C:Broadcast_DoMeleeAttackFX",
          dispatch = "OnMeleeSwing"
        },
    },
    -- Three channels on the Witch group:
    --   * Broadcast_MeleeAttackImpact IS a Witch override (the kick-knockback multicast), so it
    --     resolves at the Witch class -> OnMeleeImpact (Warrior kick fireball + updraft flask).
    --   * Server_DoRangedAttack is NOT overridden, so the Storm Witch's suppressed-shotgun bolts
    --     ride the shared SOLDIER path alongside Chieftain/Phyter/Heavy.
    --   * Broadcast_CombatAbility3 is the DELIBERATE jetpack takeoff (BT slot 3) -> OnJetpack
    --     (Storm pulse / Pestilence bees). The evade roll calls JetpackToLocation directly and
    --     skips this multicast, so OnJetpack only fires on real leaps.
    Gatekeeper_Witch = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Gatekeeper_Witch.NPC_Gatekeeper_Witch_C:Broadcast_MeleeAttackImpact",
          dispatch = "OnMeleeImpact"
        },
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Soldier_Grunt.NPC_Soldier_Grunt_C:Server_DoRangedAttack",
          dispatch = "OnRangedAttack"
        },
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Gatekeeper_Witch.NPC_Gatekeeper_Witch_C:Broadcast_CombatAbility3",
          dispatch = "OnJetpack"
        },
        -- Melee SWING - fires per attempt, hit or miss (both Server_DoMeleeAttack paths broadcast
        -- it BEFORE the hit test). It lives on the always-loaded NPC_Base parent, so once
        -- registered it fires for EVERY NPC melee game-wide and the name lookup filters to defs
        -- declaring OnMeleeSwing. (Storm's kick nova is on IMPACT, not here.)
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C:Broadcast_DoMeleeAttackFX",
          dispatch = "OnMeleeSwing"
        },
    },
    -- The DarkLens Witch (Mother of the Fallow) is the one boss that OVERRIDES its ability
    -- multicast: Broadcast_CombatAbility3 and OnLanded resolve on ITS OWN class (the hover is a
    -- full replacement, no super), so a hook on the base Witch's copy never fires for her - both
    -- paths below are the DarkLens ones. Melee/ranged are NOT overridden, so those two ride the
    -- base Witch / shared soldier paths and the path+dispatch dedup keeps every hook single.
    --   * OnLanded fires on EVERY landing; the handler gates on FlameOnLanding (true only for the
    --     divebomb) and the hook being a PRE hook is what lets it suppress the native fire pool.
    DarkLens_Witch = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Gatekeeper_Witch_DarkLens.NPC_Gatekeeper_Witch_DarkLens_C:Broadcast_CombatAbility3",
          dispatch = "OnJetpack"
        },
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Gatekeeper_Witch_DarkLens.NPC_Gatekeeper_Witch_DarkLens_C:OnLanded",
          dispatch = "OnLanded"
        },
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Gatekeeper_Witch.NPC_Gatekeeper_Witch_C:Broadcast_MeleeAttackImpact",
          dispatch = "OnMeleeImpact"
        },
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Soldier_Grunt.NPC_Soldier_Grunt_C:Server_DoRangedAttack",
          dispatch = "OnRangedAttack"
        },
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C:Broadcast_DoMeleeAttackFX",
          dispatch = "OnMeleeSwing"
        },
    },
    -- The Shield Embolon paces its turtle shield-bash by latching MeleeAttack_OnCooldown per SWING
    -- - the turtle melee branch has no native cooldown (AnteNPCs/OrderRook.lua). Same NPC_Base
    -- multicast as the Witch entry; the dedup keeps the hook single when both exist.
    Trooper_Shield = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C:Broadcast_DoMeleeAttackFX",
          dispatch = "OnMeleeSwing"
        },
    },
    -- The Centurion Grunt swings 1.5x and fires its own release valve, so it needs the per-attempt
    -- melee multicast to time that from. Same always-loaded NPC_Base path as the entries above -
    -- the path+dispatch dedup installs ONE hook however many rows ask for it.
    Trooper = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C:Broadcast_DoMeleeAttackFX",
          dispatch = "OnMeleeSwing"
        },
    },
    -- The SAME chassis one class up (NPC_OrderGrunt_Shield extends NPC_Groupe_Shield), for the
    -- Groupe Rookram's swing cadence. NOT redundant with the row above: CLASS_HOOKS installs on the
    -- first mutation of THAT ROW, so a snow fight with no Order troopers in it would never register
    -- the Embolon's copy (the Pest/Pest_Snow pair, same reasoning). The dedup key is path|dispatch,
    -- so the two still install ONE hook.
    Groupe_Rook = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C:Broadcast_DoMeleeAttackFX",
          dispatch = "OnMeleeSwing"
        },
    },
    -- The Clericus ships an EMPTY MeleeAttacks map (a non-combat coward that never swings), so a
    -- melee Clericus variant must supply its own montage AND its own BT release: the native
    -- Broadcast_DoMeleeAttackFX bails on the failed montage cast before scheduling
    -- EndAbility_DoCombatReset, and BTT_DoMeleeAttack then waits forever ("attacks exactly once").
    -- Same NPC_Base multicast as the Witch/Rook entries, kept single by the dedup.
    Clericus = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C:Broadcast_DoMeleeAttackFX",
          dispatch = "OnMeleeSwing"
        },
    },
    -- The Deatomizer Bot's melee shove needs a SWING START to time from: its own laser sweep
    -- deals damage as the bot AND leaves a plasma burn that re-credits it every tick, so
    -- OnDealtDamage alone cannot tell a connecting swing from a DoT. Same always-loaded NPC_Base
    -- multicast as the rows above, kept single by the dedup.
    Robot_Defense = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C:Broadcast_DoMeleeAttackFX",
          dispatch = "OnMeleeSwing"
        },
    },
    -- ReaperScout's OnMegalightHit is EMPTY natively (it ignores the x-ray). A scout variant
    -- hooks it to react (freeze) - the dispatch is variant-keyed, so vanilla scouts stay inert.
    ReaperScout = {
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Monster_ReaperScout.NPC_Monster_ReaperScout_C:OnMegalightHit",
          dispatch = "OnMegalight"
        },
        -- The scout's SUMMON moment: its Server_DoMeleeAttack override is what calls
        -- AIDirector.TriggerDynamicReaperAttack on a player hit. bothSlots because the PRE slot
        -- alone did not fire live (2026-09-03); a POST-slot veto still works - the summon's EQS
        -- callback (OnReaperQuery) re-checks ActiveDynamicReaper before spawning, so the write
        -- lands in time from either slot. The redirect latches per scout, so a double fire is
        -- harmless. SwingAtActor arrives as a param WRAPPER.
        {
          path = "/Game/Blueprints/Characters/NPCs/NPC_Monster_ReaperScout.NPC_Monster_ReaperScout_C:Server_DoMeleeAttack",
          dispatch = "OnScoutContact", passParams = true, bothSlots = true
        },
    },
    -- THE LAMOGI BUMP LANDING. The whole family attacks by running into things, and
    -- Broadcast_MeleeAttackImpact is where that contact resolves (it is also where the native
    -- knockback lives - the TAMED branch bounces the pet itself 250/250 and the wild one launches
    -- the victim). It is a multicast, so it dispatches through ProcessEvent and hooks cleanly.
    --   * Only NPC_Monster_WinterSprite_C defines it - LamogiSpeedy/LamogiPlated are 15-line reskin
    --     subclasses that do not override it - so all three rows hook the PARENT path, exactly like
    --     Exor_Pikeman_Ally and Yeti above. The dedup key is path|field, so registering it under
    --     three row names still installs ONE hook.
    --   * PRE-hook: the native body runs after us, so anything meant to BEAT a native write has to
    --     be queued a beat later (see the header). The uppercut in TamedLamogiHelpers does exactly that.
    WinterSprite  = { { path = LAMOGI_BUMP_HOOK, dispatch = "OnMeleeImpact" } },
    Lamogi_Speedy = { { path = LAMOGI_BUMP_HOOK, dispatch = "OnMeleeImpact" } },
    Lamogi_Plated = { { path = LAMOGI_BUMP_HOOK, dispatch = "OnMeleeImpact" } },
}

-- Row names whose class hooks are already registered (dedup)
local registeredClassHooks = {}

-- Shared UFunction hooks, deduped by "path|dispatch". Two DIFFERENT rows can name one parent
-- UFunction (Chieftain and Neophyte Gunner both ride NPC_Soldier_Grunt:Server_DoRangedAttack).
-- Without this the second row to mutate re-hooks the same path: a double dispatch (two bursts per
-- trigger) plus a second trampoline on one function.
local registeredHookPaths = {}


-- The def a hook's actor was mutated into, or nil - by its VariantTag, never its DisplayName.
--   * Law 2, and a number read: the DisplayName read copies an FText, the read that crashed a
--     server mid stream-in ([[anteup2-ftext-read-av-npc-beginplay]]).
--   * Authority only, checked per call. These hooks register on the first authority world and
--     can't be unregistered, so after leaving single player for a server they still fire on the
--     client - where the tag replicates and would dispatch every variant handler.
local function serverDef(actor)
    if not Utils.IsAuthority() then return nil end
    return require("AnteVariants.VariantTag").DefOf(actor)
end

-- Generic dispatch: look up the acting NPC's variant  and call fn.
--   * Extra args are the hook's own PARAM WRAPPERS, forwarded verbatim (added for
--     OnTeleport's endpoint vectors). A handler that wants one must :get() and COPY the
--     scalars inside the call - a wrapper held past the hook is a freed-slot deref.
local function dispatchVariant(actor, field, ...)
    if Utils.IsActorInvalid(actor) then return end
    local variant = serverDef(actor)
    local fn = variant and variant[field]
    if fn then
        local ok, err = pcall(fn, actor, ...)
        if not ok then LogBad(field .. " error: " .. tostring(err)) end
    end
end


-- def.OnDeath is reachable from TWO hooks - the shared OnRep_IsDead below, and a class hook for
-- NPCs whose own death sequence tears them down first (the Mage Eye force-gibs itself and puts a
-- 5s lifespan on the corpse). Both funnel through here so OnDeath runs EXACTLY ONCE; otherwise the
-- first NPC to trip both drops its loot twice.
-- Keyed by fullname STRING, never the wrapper ([[anteup2-actor-wrapper-identity]]), and it holds
-- only booleans so it can't pin a dead UObject across a teardown. Cleared per world in Register().
local deathDone = {}

local function dispatchDeathOnce(actor)
    if Utils.IsActorInvalid(actor) then return end

    local key = Utils.ActorKey(actor)
    if key then
        if deathDone[key] then return end
        deathDone[key] = true
        -- Shared per-actor books keyed by this STRING don't collect on their own; drop them here
        -- rather than making every variant remember to.
        pcall(function() require("AnteUtils.AVUtils").ClearReloadDilation(key) end)
    end

    -- A PlacedSpawn kill is recorded HERE, while the body is still valid. The placement's own
    -- reap only sees a corpse that survives to its next beat; a gib (explosive kill) or a fast
    -- corpse cleanup destroys it first, the ref reads as a stream-out, and the body re-places
    -- with no cooldown (the 2026-09-14 Anterazor at 8390,9140,-510). No-op for untracked actors.
    if next(STATE.PlacedSpawnActors or {}) ~= nil then
        pcall(function() require("ModuleStory.EventUtils").MarkPlacedDefeated(actor) end)
    end

    dispatchVariant(actor, "OnDeath")
end


-- =======================================================================
-- POSTHUMOUS-ATTACKER GUARD. A DoT from a killed NPC keeps crediting it as the DamageCauser for
-- ~10s after death (CrashDOT: the kamikaze'd Mad Rat dispatched "melee flask burst" every tick).
--   * DamageCauserName makes the NAME lookup GC-safe, but the direct dispatch then hands the RAW
--     wrapper to def.OnDealtDamage, and on a freed+reused slot the handler's first property read
--     is the packed-int AV. (The projectile path already guarded with fresh-or-nil.)
--   * So track recently dead/departed actors by WRAPPER ADDRESS - the only handle needing no
--     deref - and skip them. A corpse shouldn't fire its on-hit abilities anyway.
--   * A new actor allocated at a dead one's address merely skips on-hit procs for the TTL window.
--     Benign, and the TTL outlasts the longest DoT.
--   * The same stamp evicts the address from the causer-name caches. Without that, the new actor
--     was served the dead one's name for the rest of the session - a pet read as a long-dead Order
--     Grunt, and its own OnDealtDamage stopped firing.
-- =======================================================================
local deadAddrs = {}            -- wrapper address -> FAST_TICK when it died/left
local deadAddrCount = 0
local DEAD_ADDR_TTL = 300       -- ticks (~30s): outlives every DoT a dead actor can leave behind

local function noteDeadAddr(actor)
    local addr
    pcall(function() if actor.GetAddress then addr = actor:GetAddress() end end)
    if not addr then return end
    Utils.ForgetCauserAddr(addr)
    if deadAddrs[addr] == nil then
        deadAddrCount = deadAddrCount + 1
        if deadAddrCount > 256 then   -- bound: drop expired entries
            local now = STATE.FAST_TICK
            for a, t in pairs(deadAddrs) do
                if (now - t) >= DEAD_ADDR_TTL then deadAddrs[a] = nil end
            end
            deadAddrCount = 0
            for _ in pairs(deadAddrs) do deadAddrCount = deadAddrCount + 1 end
        end
    end
    deadAddrs[addr] = STATE.FAST_TICK
end

local function isRecentlyDead(wrapper)
    local addr
    pcall(function() if wrapper.GetAddress then addr = wrapper:GetAddress() end end)
    local t = addr and deadAddrs[addr]
    return t ~= nil and (STATE.FAST_TICK - t) < DEAD_ADDR_TTL
end

-- True only on the hit that killed it: the parent ProcessDamage body sets IsDead and calls
-- OnRep_IsDead itself, whose hook stamps the address with the CURRENT tick. A corpse's later DoT
-- ticks carry an older stamp.
local function diedThisTick(wrapper)
    local addr
    pcall(function() if wrapper.GetAddress then addr = wrapper:GetAddress() end end)
    return addr ~= nil and deadAddrs[addr] == STATE.FAST_TICK
end


-- =======================================================================
-- ONE SCALE PASS PER HIT. AoE damage runs CheckForNPCDamageMultiplier TWICE on an NPC:
-- ReceiveRadialDamage scales, then final-calls ProcessDamage, whose NPC_Base override scales the
-- number the first pass produced. Left alone, every multiplier in that hook lands SQUARED on an
-- explosion - an Explosive=0.25 row reads as 0.0625. Point damage gets a single pass.
--   * The repeat identifies itself exactly: it arrives carrying our own previous output as its
--     INPUT, on the same body, on the same frame. So it passes through, and a blast is scaled
--     once, the way a bullet is.
--   * The frame stamp is what makes that test safe. Our output is a plausible raw number for some
--     later hit, and an unstamped latch would strip a DoT's resistance for a whole fight the first
--     time the two agreed.
--   * The NATIVE resist/weakness step doubles too. That is vanilla behaviour, and stays.
-- =======================================================================
local scaledOut = {}     -- wrapper address -> the damage our pass wrote
local scaledTick = {}    -- wrapper address -> FAST_TICK of that pass
local scaledCount = 0

local function scaleAddr(actor)
    local addr
    pcall(function() if actor.GetAddress then addr = actor:GetAddress() end end)
    return addr
end

-- Write the out param AND record it, so the second pass can recognise itself.
local function setScaled(outParam, addr, damage)
    outParam:set(damage)
    if not addr then return end
    if scaledOut[addr] == nil then
        scaledCount = scaledCount + 1
        if scaledCount > 256 then   -- bound: an entry is only ever read on its own frame
            local now = STATE.FAST_TICK
            for a, t in pairs(scaledTick) do
                if t ~= now then scaledOut[a], scaledTick[a] = nil, nil end
            end
            scaledCount = 0
            for _ in pairs(scaledOut) do scaledCount = scaledCount + 1 end
        end
    end
    scaledOut[addr] = damage
    scaledTick[addr] = STATE.FAST_TICK
end

local function isSecondScalePass(addr, inDamage)
    if not addr or type(inDamage) ~= "number" then return false end
    return scaledTick[addr] == STATE.FAST_TICK and scaledOut[addr] == inDamage
end

-- A downed tamed pet, while RevivePets is on. Such a pet takes no damage: a hit on a downed pet that
-- isn't in a companion slot is added straight to its bleedout, and the native ApplyDBNODamage runs
-- the bleedout check in the same call - so a stray hit (mostly the player's own AoE) kills it before
-- PetManager's bleedout rescue can act. The rescue still handles the bleedout itself.
local function isDownedPet(actor)
    local pets = SETTINGS.MODULES and SETTINGS.MODULES.ANTEPETS
    if not (pets and pets.Enabled and pets.RevivePets) then return false end
    local down
    pcall(function() down = actor.IsDBNO end)
    if down ~= true then return false end
    local buff
    pcall(function() buff = actor.CachedFollowerBuffActor end)
    return buff ~= nil and IsValid(buff)
end

-- FAST_TICK restarts at 0 every world, so a survivor reads as stamped on this very frame.
function HOOKS.ResetScalePass()
    scaledOut, scaledTick, scaledCount = {}, {}, 0
end


-- =======================================================================
-- CORPSE DEBUFF STRIP. The native death sequence only strips buffs when GIBBED, so a normal NPC
-- corpse keeps its DoTs and ticks ProcessDamage for up to ~21s post-death (the hazard-corpse
-- family). Our IsDeadSafe bail skips the Lua dispatch, but each tick still marshals the hook on a
-- dying actor whose slot GC may reclaim mid-window, and the buff's own BP graph derefs natively.
--   * Fix at the ROOT: Server_RemoveAllBuffs(2), the game's own player-death cleanse, removes only
--     Severity != Positive rows - so Buff_Tamed and other positive markers survive.
--   * NPCs only; players keep native handling.
--   * Deferred one WQ drain: buff removal fires RemovedBuff events (resident teardown, no cold
--     loads) which must not run nested in the OnRep hook.
--   * Visible change: a burning corpse stops burning at death, same as the native gib path.
-- =======================================================================
local BUFFTYPE_REMOVE_NEGATIVE = 2   -- E_BuffTypes value the game uses for "cleanse debuffs"

local function stripCorpseDebuffs(actor)
    if not Utils.IsAuthority() then return end
    if not IsValid(actor.NPCData) then return end   -- NPC corpses only - never touch players

    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) then return end
        local dead = false
        pcall(function() dead = actor.IsDead == true end)
        if not dead then return end
        pcall(function()
            local comp = actor.BuffDebuffComponent
            if IsValid(comp) then comp:Server_RemoveAllBuffs(BUFFTYPE_REMOVE_NEGATIVE) end
        end)
    end, 250)
end


-- Every class hooked lazily is pinned: a class that unloads takes its hooks with it, and the
-- registration latches never re-register them ([[anteup2-hook-dies-with-unloaded-class]]). Each is
-- hooked because an instance is being mutated, so the class is resident and the pin is a cache read.
local function pinHookClasses(hookPaths)
    local list, seen = {}, {}
    for _, p in ipairs(hookPaths) do
        local cls = p:match("^(.-):")
        if cls and not seen[cls] then seen[cls] = true; list[#list + 1] = cls end
    end
    if #list > 0 then require("AnteCore.AssetManager").WarmPinned(list) end
end


-- Special: the Mage Eye never reliably reached def.OnDeath off the shared OnRep_IsDead - its own
-- Server_PerformDeathSequence override runs the parent sequence then DestroyEye(), which force-gibs
-- it and puts a 5s lifespan on the remains. So hook the eye's OWN death function, PRE: it runs
-- before the teardown while the actor is whole and its location readable, authority-only, once.
-- It does NOT catch a K2_DestroyActor (our wardenBreach despawn, the native orphan cleanup) -
-- those are destroys, not deaths, and drop nothing.
local MAGEEYE_DEATH_HOOK = "/Game/Blueprints/Characters/NPCs/NPC_MageEye.NPC_MageEye_C:Server_PerformDeathSequence"

local function registerMageEyeDeathHook()
    local ok, err = pcall(RegisterHook, MAGEEYE_DEATH_HOOK, function(self)
        if not live() then return end
        dispatchDeathOnce(self:get())
    end)
    if ok then
        Utils.Log("CombatHooks - MageEye death hook registered")
    else
        LogBad("CombatHooks - MageEye death hook FAILED: " .. tostring(err))
    end
end


-- Special: make a "shade" scout VULNERABLE to holy. The scout's GetResponseToDamageType override
-- reports Immune for anything its parent didn't return as a WEAKNESS hit - and the parent gates
-- weakness behind a flat 14% chance roll, so holy otherwise lands about one hit in seven. For
-- scouts opting in via def.HolyVulnerable, flip Immune->false so every holy hit runs the pipeline:
-- Invincible still blocks the HP, and OnDamageTaken despawns the variant.
local SCOUT_RESPONSE_HOOK =
    "/Game/Blueprints/Characters/NPCs/NPC_Monster_ReaperScout.NPC_Monster_ReaperScout_C:GetResponseToDamageType"

-- `slot` only names the delivering slot in the log - which slot fired is the whole diagnostic when
-- one of them silently ships dead.
local function scoutHolyResponse(slot)
    return function(self, DamageType, _causer, _hitComp, _hitBone, Immune, Weakness)
        if not live() then return end
        local actor = self:get()
        if Utils.IsActorInvalid(actor) then return end
        local def = serverDef(actor)
        if not (def and def.HolyVulnerable) then return end
        local dt = DamageType and DamageType:get()
        local ok, n = pcall(function() return dt and dt:GetFullName() end)
        if not (ok and n and tostring(n):find("Holy")) then return end
        pcall(function() Immune:set(false) end)
        pcall(function() Weakness:set(true) end)
        Utils.LogDebug("CombatHooks - scout holy un-immuned [" .. slot .. "]", SETTINGS.DEBUG_DAMAGE_NPC)
    end
end

local function registerScoutHolyHook()
    -- BOTH slots. The call site is EX_LocalVirtualFunction, so either slot runs AFTER the body -
    -- which is what makes the out-param writes stick, and what makes a PRE registration real
    -- insurance here instead of a write the body would overwrite. Both writes are absolute, so a
    -- double fire is a no-op.
    local ok, err = pcall(RegisterHook, SCOUT_RESPONSE_HOOK,
                          scoutHolyResponse("pre"), scoutHolyResponse("post"))
    if not ok then LogBad("CombatHooks - scout holy hook FAILED: " .. tostring(err)) end
end


-- Rook melee-pick override. FindBestMeleeAttack picks the KNIFE LUNGE (type 1) unless turtled,
-- when it picks the SHIELD BASH (type 2). def.ForceShieldBash makes it type 2 ALWAYS - the real
-- Turtle_ShieldBash montage with its early PowerMeleeHitApex timing, while staying in the mobile
-- branch. POST-hook: the body writes LastMeleeAttackType, we overwrite before the caller reads it.
local ROOK_MELEE_PICK_HOOK =
    "/Game/Blueprints/Characters/NPCs/NPC_Groupe_Shield.NPC_Groupe_Shield_C:FindBestMeleeAttack"

local function registerRookBashHook()
    RegisterHook(ROOK_MELEE_PICK_HOOK,
        function() end,   -- (no pre)
        function(self)
            if not live() then return end
            local actor = self:get()
            if Utils.IsActorInvalid(actor) then return end
            local def = serverDef(actor)
            if not (def and def.ForceShieldBash) then return end
            pcall(function() actor.LastMeleeAttackType = 2 end)
        end)
end


-- =======================================================================
-- def.DeployableDamage - a variant that hits BARRICADES / TURRETS / the Chopinator harder than a
-- normal NPC does. Declarative map of family -> multiplier; see AVU.DeployableDamageMult for the
-- shape and ENUMS.DeployedGroups for the families.
--
-- WHY THIS SHAPE. A deployable is not a character, so NOTHING in the normal damage path sees it:
-- OnDealtDamage rides Abiotic_Character_ParentBP:ProcessDamage and a barricade never reaches it,
-- and CheckForNPCDamageMultiplier is an NPC_Base function about damage TAKEN. Two seams that look
-- like the answer are dead, so this one HITS THE DEPLOYABLE AGAIN instead of editing the hit:
-- (scale - 1) more of the same raw damage, from the same attacker with the same damage type,
-- dealt off-hook. The deployable then runs its own math on it - sandbox multiplier, the type's
-- DeployableDamageMultiplier, the flat x0.5 for an AI instigator - so the total lands at exactly
-- `scale` x the native loss with nothing re-derived on our side.
--
--   * NOT `Can Harm Deployable?`, the multiplier the deployable's own math asks for. RegisterHook
--     accepts it and the callback NEVER runs, on either slot (it is only reached by
--     EX_LocalVirtualFunction). `[[anteup2-can-harm-deployable-hook-dead]]`
--   * NOT `Damage:set()` in this hook either. The write takes - reading the param back gives the
--     scaled number - but the body has already copied Damage into the ubergraph frame that
--     `Process Damage` reads, so the durability math still uses the original. This callback runs
--     AFTER the body even though the engine dispatches the event.
--   * The top-up re-enters this hook, so a per-deployable stamp consumes it; without that the
--     boost compounds without bound.
--   * SHARED with every deployable hit in the world, so the bail order is (1) is there damage at
--     all, (2) name -> def, (3) does the def declare the field, (4) VariantTag - only then is it
--     ours. Not a hot path (deployables are damaged rarely), and the first two bails are a float
--     read and a table lookup.
--   * ARMED PER VARIANT from RegisterClassHooks, not per row: a def that never declares the field
--     never pays for the hook. A new variant that wants it just declares it.
-- =======================================================================
-- "/deploydmg" prints one line per deployable hit, the BAILS included - which bail fires names the
-- broken link. Args are joined rather than concatenated by the caller, so a disabled probe costs
-- nothing on the (common) hit that isn't ours. AnDebug/DeployDamageProbe.
local function deployBail(a, b, c)
    if not STATE.DeployDamageProbe then return end
    Utils.LogBad("[DEPLOYDMG]   skipped: " .. tostring(a)
        .. (b ~= nil and tostring(b) or "") .. (c ~= nil and tostring(c) or ""))
end

local DEPLOY_BP =
    "/Game/Blueprints/DeployedObjects/AbioticDeployed_ParentBP.AbioticDeployed_ParentBP_C"

-- Per hook, because a retry must not re-register the one that already took (that would scale the
-- hit twice). deployHookArmed is the caller's cheap "nothing left to do".
local deployPointArmed, deployRadialArmed, deployHookArmed = false, false, false

local function registerDeployableDamageHook()
    if deployHookArmed then return end

    -- Lazy, like the pest hook's VariantTag: CombatHooks is required from the variant layer, so a
    -- top-level require of AVU here would risk the load cycle. By call time both are loaded.
    local AVU = require("AnteUtils.AVUtils")
    local VariantTag = require("AnteVariants.VariantTag")

    -- The multiplier this causer earns against this deployable, or nil for "leave the hit alone".
    local function deployScale(deployable, causer)
        if Utils.IsActorInvalid(causer) then return deployBail("no causer") end

        -- By tag: ours, and the mutation actually finished (CLAUDE.md 2). pcall'd because the
        -- causer is anything at all here - a player, a projectile, another deployable.
        local okDef, def = pcall(VariantTag.DefOf, causer)
        if not okDef or not def then
            return deployBail("causer is not a mutated variant: ", Utils.GetActorClassName(causer))
        end
        local name = def.Name
        if not (def.DeployableDamage or (def.HardMode and def.HardMode.DeployableDamage)) then
            return deployBail("declares no DeployableDamage: ", name)
        end

        local cname = deployable and Utils.GetActorClassName(deployable)
        local scale = cname and AVU.DeployableDamageMult(def, cname)
        if not scale or scale == 1 then
            return deployBail("no family match for ", cname, " in " .. tostring(name) .. "'s map")
        end
        return scale, name
    end

    -- Deployables with a top-up hit in flight: ActorKey -> { amount, at }. Matched on the exact
    -- damage we sent rather than "the next hit", so a second swing landing while the top-up is
    -- still in the air can't be mistaken for it - that mix-up would boost a boost.
    local topUpSent = {}
    local TOPUP_WINDOW_MS = 1000

    local function topUpHit(self, Damage, DamageType, DamageCauser)
        if not live() then return end

        local okD, dmg = pcall(function() return Damage:get() end)
        if not okD or type(dmg) ~= "number" or dmg <= 0 then return end

        local deployable = self and self:get()
        if Utils.IsActorInvalid(deployable) then return end

        local key = Utils.ActorKey(deployable)
        local sent = key and topUpSent[key]
        if sent then
            if Utils.NowMs() - sent.at >= TOPUP_WINDOW_MS then
                topUpSent[key] = nil          -- it never landed; stop shadowing this deployable
            elseif math.abs(dmg - sent.amount) < 0.01 then
                topUpSent[key] = nil
                return                        -- this hit IS our top-up
            end
        end

        local causer = DamageCauser and DamageCauser:get()
        local scale, name = deployScale(deployable, causer)
        if not scale then return end

        -- The SAME type, so the top-up takes the same resistances and debuffs the native hit did.
        local dtPath
        local dtObj = DamageType and DamageType:get()
        if IsValid(dtObj) then
            pcall(function() dtPath = Utils.ObjectPath(dtObj:GetClass()) end)
        end
        if not dtPath then return deployBail("hit has no readable damage type class") end

        local extra = dmg * (scale - 1)
        if key then topUpSent[key] = { amount = extra, at = Utils.NowMs() } end
        AVU.PointDamageOffHook(causer, deployable, extra, dtPath, true)

        if STATE.DeployDamageProbe then
            Utils.LogBad(string.format("[DEPLOYDMG]   %s x%.2f -> +%.1f raw on top of %.1f",
                name, scale, extra, dmg))
        end
    end

    -- Latched on SUCCESS, not on the attempt: RegisterHook throws until the deployable BP is loaded,
    -- and a world can be well underway before the first one exists. A retry costs one lookup, and
    -- only runs until it takes.
    local failure
    if not deployPointArmed then
        local ok, err = pcall(RegisterHook, DEPLOY_BP .. ":ReceivePointDamage",
            function(self, Damage, DamageType, _HL, _HN, _HC, _Bone, _Dir, _Inst, DamageCauser)
                pcall(topUpHit, self, Damage, DamageType, DamageCauser)
            end)
        deployPointArmed = ok or false
        failure = not ok and err or failure
    end

    if not deployRadialArmed then
        local ok, err = pcall(RegisterHook, DEPLOY_BP .. ":ReceiveRadialDamage",
            function(self, Damage, DamageType, _Origin, _Hit, _Inst, DamageCauser)
                pcall(topUpHit, self, Damage, DamageType, DamageCauser)
            end)
        deployRadialArmed = ok or false
        failure = not ok and err or failure
    end

    deployHookArmed = deployPointArmed and deployRadialArmed
    if deployHookArmed then
        Utils.Log("CombatHooks - deployable-damage hooks registered")
    else
        LogBad("CombatHooks - deployable-damage hooks not yet registered: " .. tostring(failure))
    end
end


-- Force the pest leap onto its APOCALYPTIC branch for every mutated pest variant, whatever the
-- world's difficulty. NPC_Monster_Pest reads AbioticFunctionLibrary:ApocalypticAbilitiesEnabled at
-- three points in the leap - the windup hop (700 vs 500), the windup Delay (0.2s vs 0.5s) and the
-- launch itself (LaunchCharacter OVERRIDE vs velocity-ADD; the label is shared, so
-- Server_InstantlyLunge re-lunges get it too) - and the check is GLOBAL (difficulty >= 3 OR the
-- ApocalypticAbilities sandbox bool), no per-actor lever. So hook the library function and RETURN
-- true when the caller is one of ours - its result is a return value, never a callback param
-- ([[ue4ss-hook-return-value-override]]); a ReturnValue param left this hook dead until 2026-10-01:
--   * pest probe = PestLeapVelocity exists (only the NPC_Monster_Pest family has it). The hook
--     fires for EVERY apoc check in the game (Mage, BogMan, robots, soldiers, ...), so non-pests
--     must bail this cheaply; no pest subclass adds its own check, so only the leap changes.
--   * ours = VariantTag.Decode (the mutation-atomic marker) - NEVER the DisplayName, which
--     false-positives on unmutated Pest_Volatile bodies (CLAUDE.md, [[anteup2-volatile-base-signal-pests]]).
-- AVU.PestLeapMult returns 1 BECAUSE of this hook (no sub-Apocalyptic shortfall left to
-- compensate) - retune it if this is ever removed. Wild pests keep native difficulty behavior.
local APOC_CHECK_HOOK =
    "/Game/Blueprints/Libraries/AbioticFunctionLibrary.AbioticFunctionLibrary_C:ApocalypticAbilitiesEnabled"

local apocForcedLogged = false

local function registerPestApocLeapHook()
    local VariantTag = require("AnteVariants.VariantTag")   -- lazy: avoids any require-order surprise
    -- nil = leave the native answer alone (a real Apocalyptic world already reads true).
    local function forceForOurPests(_self, WorldContext)
        if not live() then return nil end

        local ctx = WorldContext and WorldContext:get()
        if IsNotValid(ctx) then return nil end

        local okPest, leapVel = pcall(function() return ctx.PestLeapVelocity end)
        if not okPest or type(leapVel) ~= "number" then return nil end   -- not a pest

        if VariantTag.Decode(ctx) == nil then return nil end   -- wild pest: keep native difficulty

        if not apocForcedLogged then
            apocForcedLogged = true
            Utils.Log("CombatHooks - pest apocalyptic leap forced for a mutated pest")
        end
        return true
    end
    -- Both slots: the forced answer is absolute, and the one that runs after the body is what sticks.
    local ok, err = pcall(RegisterHook, APOC_CHECK_HOOK, forceForOurPests, forceForOurPests)
    if ok then
        Utils.Log("CombatHooks - pest apocalyptic-leap hook registered")
    else
        LogBad("CombatHooks - pest apocalyptic-leap hook FAILED: " .. tostring(err))
    end
end


-- =======================================================================
-- def.PetSpecialAttack - the ONLY lever on a PET's "special attack" damage.
--
-- *** A TAMED BODY IGNORES ITS OWN SpecialAttackDamage / ShockRingDamage FIELD. *** Every special
-- routes its number through NPC_Base_ParentBP:GetPetSpecialAttack first, which - once the body
-- carries Buff.Follower.Tamed - throws the passed-in value away and returns the DT_Pets curve
-- instead (BuffActor_Follower:GetSpecialAttack -> BaseSpecial + SpecialBonusPerLevel * level).
-- So `actor.ShockRingDamage = 0` on a pet is cosmetic: a L20 tamed Electro Pest still rings for
-- 130 (156 through the companion buff's OverallDamage_Multiply). Same trap on the carbonated AoE
-- (SpecialAttackDamage) and the peccary charge.
--
-- The DT_Pets row is shared with every vanilla pet of that base, so editing it is not an option.
-- The one seam left is the RESULT, and this is it:
--   * A POST hook, deliberately - GetPetSpecialAttack is reached by EX_LocalVirtualFunction from
--     each special's own body, so a single-callback RegisterHook would fire after the body anyway
--     ([[ue4ss-local-script-call-hook-is-post]]). The override is the callback's RETURN value - see
--     applyPetSpecial.
--   * `def.PetSpecialAttack = <number>` or `= function(actor, untamedValue) -> number`. The number
--     is RAW: the caller still multiplies it by OverallDamage_Multiply, so an active companion
--     shows 1.2x what is written here (50 reads as 60).
--   * The hook is SHARED with every pet in the game: only a body whose tagged def declares the field
--     is overridden. A wild body never reaches the tamed branch, so declaring this on a wild def is
--     inert.
-- =======================================================================
local PET_SPECIAL_HOOK =
    "/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C:GetPetSpecialAttack"

-- SELF-REPORTING, once. This override is invisible when it fails - the pet just keeps dealing its
-- DT_Pets number and nothing complains - so the first one applied says so. Silence plus a
-- "registered" line means the callback never fired, or no pet it reached carried a tagged def
-- with PetSpecialAttack.
local petSpecialLoggedOk = false

-- The body, shared by both callback slots (see registerPetSpecialAttackHook).
--   * GetPetSpecialAttack's result is a RETURN value, which UE4SS never passes in as a param: the
--     callback's own return value overwrites it. It used to wait for a ReturnValue param that never
--     came, so this override never applied once.
--   * A local call (the pest subclasses), so the callback runs after the body and the return sticks.
local function applyPetSpecial(self, UntamedValue)
    if not live() then return nil end

    local actor = self and self:get()
    if Utils.IsActorInvalid(actor) then return nil end

    local def = serverDef(actor)
    local want = def and def.PetSpecialAttack
    if want == nil then return nil end

    local untamed = UntamedValue and UntamedValue:get()
    if type(want) == "function" then
        local okCall, v = pcall(want, actor, untamed)
        if not okCall or type(v) ~= "number" then return nil end
        want = v
    end
    if type(want) ~= "number" then return nil end

    if not petSpecialLoggedOk then
        petSpecialLoggedOk = true
        Utils.Log("CombatHooks - PetSpecialAttack [" .. tostring(def.Name) .. "] untamed "
            .. tostring(untamed) .. " -> " .. tostring(want))
    end
    return want
end

-- BOTH callback slots get the same body, deliberately.
--   * For a local script call (which this is) UE4SS fires both AFTER the body, so either works and
--     whichever runs first wins - the second no-ops on the `was == want` check.
--   * If a future build ever dispatches it as a true PRE, that slot's write is simply overwritten
--     by the body and the POST slot still lands it. There is no ordering left to be wrong about.
local function registerPetSpecialAttackHook()
    local ok, err = pcall(RegisterHook, PET_SPECIAL_HOOK, applyPetSpecial, applyPetSpecial)
    if ok then
        Utils.Log("CombatHooks - pet special-attack hook registered")
    else
        LogBad("CombatHooks - pet special-attack hook FAILED: " .. tostring(err))
    end
end


-- ================================================================
-- BT_SetCombatState (the controller) - the combat-entry funnel. Every gameplay entry goes through
-- it (the BT task, the follower/command buffs), and its SkipAggroAnimation param is the only thing
-- between "combat state set" and PerformCombatEngage: the aggro montage, plus the AggroDuration
-- wait that parks the tree for the clip's length. Forcing the param true for a marked pawn skips
-- both, and the task finishes on the spot (Success=false -> FinishExecute).
--   * PRE: the task calls this cross-object, so the engine dispatches it and the param write lands
--     before the body reads it. Both slots are armed; after a landed PRE write the POST slot reads
--     the param as already true and stays silent, so a "[post]" line means PRE never fired.
--   * Marked = AVU.SkipAggroAnim ran on the pawn (def.NoAggroAnim / HardMode.NoAggroAnim via
--     NpcManager STATS, or a direct call): STATE.NoAggroAnimActors, keyed by ActorKey.
--   * The out-of-combat startle has its own native gate; SkipAggroAnim sets that too.
--   * Skipping the engage also skips its aggro bark (TryDialogQuip) - intended.
--   * pcall'd registration, ahead of the bare ones: RegisterHook throws while the class is unloaded.
-- ================================================================
local COMBAT_STATE_HOOK =
    "/Game/Blueprints/Characters/NPCs/Abiotic_AI_Controller_ParentBP.Abiotic_AI_Controller_ParentBP_C:BT_SetCombatState"

local function skipAggroOnEntry(slot)
    return function(self, State, SkipAggroAnimation)
        if not live() then return end
        local entering, skip = false, true
        pcall(function() entering = State:get() == true; skip = SkipAggroAnimation:get() == true end)
        if not entering or skip then return end

        local ctrl = self:get()
        if IsNotValid(ctrl) then return end
        local pawn
        pcall(function() pawn = ctrl.MyPawn end)
        if Utils.IsActorInvalid(pawn) then return end
        local key = Utils.ActorKey(pawn)
        if not (key and STATE.NoAggroAnimActors[key]) then return end

        local ok = pcall(function() SkipAggroAnimation:set(true) end)
        if SETTINGS.DEBUG_NPC_ACTIONS then   -- the name is an FText copy; only pay it to log
            Utils.LogDebug(string.format("SkipAggroAnim - combat entry without the aggro clip [%s%s] %s",
                slot, ok and "" or " write failed", tostring(Utils.GetActorName(pawn))), true)
        end
    end
end

local function registerSkipAggroHook()
    local ok, err = pcall(RegisterHook, COMBAT_STATE_HOOK, skipAggroOnEntry("pre"), skipAggroOnEntry("post"))
    if ok then
        Utils.Log("CombatHooks - combat-entry aggro-skip hook registered")
    else
        LogBad("CombatHooks - combat-entry aggro-skip hook FAILED: " .. tostring(err))
    end
end


-- ================================================================
-- DetermineDodgeDirection (the pawn) - the dodge-roll funnel. Every roll driver reaches
-- AI_PerformBackstep, which asks this for a direction and multicasts it. For a pawn AVU.SkipBackstepAnim
-- marked, this is the BACKSTOP behind AVU.BlockDodgeDrivers, which is what actually stops the rolls:
--   * It re-runs BlockDodgeDrivers. The attack tree's node instances do not exist before combat
--     and are rebuilt on every re-entry, so a roll that got through is the one beat guaranteed to
--     find them. Expect one roll per combat entry at most, then silence from that pawn.
--   * It turns the roll that DID get through into a BACK roll: direction 3 has no clip of its own
--     and GetBackstepAnim falls back to the back clip. It cannot cancel one.
--   * The direction is an OUT param of a local script call, so the write lands after the body -
--     both slots are armed and the second no-ops on `was == 3`.
--   * The Exor multicasts its own direction and never comes through here.
--   * "hook is live" is said on the first entry of ANY pawn: without it, a hook that never fires
--     reads the same as one whose pawns were never marked.
-- ================================================================
local DODGE_DIR_HOOK =
    "/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C:DetermineDodgeDirection"
local DODGE_DIR_BACK_ONLY = 3
local dodgeHookSeen = false

local function forceBackRoll(slot)
    return function(self, _origin, _random, _forceBackwards, Direction)
        if not live() then return end
        if not dodgeHookSeen then
            dodgeHookSeen = true
            Utils.Log("SkipBackstep - dodge-direction hook is live [" .. slot .. "]")
        end

        local pawn = self:get()
        if Utils.IsActorInvalid(pawn) then return end
        local key = Utils.ActorKey(pawn)
        if not (key and STATE.NoBackstepActors and STATE.NoBackstepActors[key]) then return end

        local was
        pcall(function() was = Direction:get() end)
        if was == DODGE_DIR_BACK_ONLY then return end

        local gated = require("AnteUtils.AVUtils").BlockDodgeDrivers(pawn)

        -- Already a BACK roll: a sequence dodge (a Peccary's hop back before it charges, the
        -- Interfector's post-melee flip). Nothing to redirect and no gate that could stop it.
        if was == 0 then return end
        local ok = pcall(function() Direction:set(DODGE_DIR_BACK_ONLY) end)

        if SETTINGS.DEBUG_NPC_ACTIONS then
            Utils.LogDebug(string.format("SkipBackstep - %s rolled anyway%s; forced backwards [%s%s] (direction %s)",
                tostring(Utils.GetActorName(pawn)),
                gated and " (tree gate closed)" or " (its tree has no gate - a sequence dodge)",
                slot, ok and "" or " write failed", tostring(was)), true)
        end
    end
end

local function registerNoDodgeHook()
    local ok, err = pcall(RegisterHook, DODGE_DIR_HOOK, forceBackRoll("pre"), forceBackRoll("post"))
    if ok then
        Utils.Log("CombatHooks - dodge-direction hook registered")
    else
        LogBad("CombatHooks - dodge-direction hook FAILED: " .. tostring(err))
    end
end


-- NOTE: def.DBNOPhases (collapse the Tarasque's 4 DBNO windows into N) used to be gated here by a
-- POST-hook on UpdateHealthTextureIndex. That NEVER FIRED on the host - the BP event is only ever
-- invoked via EX_LocalVirtualFunction, which bypasses UE4SS's ProcessEvent-based RegisterHook. The
-- cap now lives in AnteNPCs/TarasqueHelpers.lua on hooks that DO fire (OnDamageTaken + OnRevive).
-- See [[anteup2-tarasque]].


-- Shared projectile-parent BeginPlay hook path, KEPT because the Defense Robot molotov suppressor
-- below also hooks it. The Hive Sow carbunclebomb suppression that used to live here was removed -
-- hiding lost to async FX re-show, and speed clamps did nothing because the bomb LOBS (gravity ~31),
-- so its launch speed is under any MaxSpeed cap. The real lever is a row swap:
-- `actor.ProjectileRow.RowName` in the Hive Sow def (PeccarySow.lua). No hook needed.
local BOMB_BEGINPLAY_HOOK =
    "/Game/Blueprints/Projectiles/AbioticProjectile_ParentBP.AbioticProjectile_ParentBP_C:ReceiveBeginPlay"


-- Defense Robot native-attack suppressor. Its mortar / 6-shot frag / fire grenade are BT tasks
-- spawning via Launch_Grenade (HasRangedAttack=false, so no ammo/cooldown/row lever, and a BP event
-- can't be cancelled from Lua). So we act on the spawned PROJECTILE at BeginPlay: while a Mortar
-- Turret keeps STATE.SuppressDefenseBotUntil armed, DESTROY every native DefenseBot throw and let
-- RobotDefense's OnTick rain its own scattered mortars instead.
--   * TWO hook targets are required (the v1 bug): frag + mortar extend Projectile_Grenade_ParentBP,
--     which OVERRIDES ReceiveBeginPlay, so they never reach the AbioticProjectile parent the
--     molotov uses. The shared handler registers on both.
--   * OURS vs native: PROJ.Queue sets `WasThrown = true` and Launch_Grenade never does, so the
--     handler skips those - which is how we nuke all three native classes and still keep the
--     turret's own rained mortars (same mortar class).
--   * Lazy on the first ARTILLERY BOT mutation (the only variant that arms suppression) - NOT on the
--     row, which made every Deatomizer Bot pay for it too; see RegisterClassHooks. The FAST_TICK
--     early-out keeps it near-free with no turret alive. While armed it also affects vanilla Defense
--     bots (rare) - accepted.
local GRENADE_BEGINPLAY_HOOK =
    "/Game/Blueprints/Projectiles/Projectile_Grenade_ParentBP.Projectile_Grenade_ParentBP_C:ReceiveBeginPlay"
local DEFBOT_DESTROY = {   -- all native throws: removed on spawn (the variant supplies its own attack)
    ["Projectile_Grenade_Frag_DefenseBot_C"] = true,
    ["Projectile_Molotov_DefenseBot_C"] = true,
    ["Projectile_Grenade_Mortar_DefenseBot_C"] = true,
}

-- Does the body that threw this own a def asking for its native throws to be destroyed?
--   * Per-THROWER and permanent, unlike the two time windows: a body whose grenade slot has been
--     replaced by a scripted attack should never land a native one, and a window can only ever
--     guess at when its BT will throw.
--   * def.SuppressNativeThrows: true = every native throw, or a { [className] = true } set to keep
--     some. Looked up by the VariantTag, since a DisplayName alone can name someone else's def
--     (CLAUDE.md law 2).
local function throwerSuppresses(proj, cname)
    local thrower
    pcall(function() thrower = proj.Instigator end)
    if Utils.IsActorInvalid(thrower) then return false end

    local def = serverDef(thrower)
    local want = def and def.SuppressNativeThrows
    if not want then return false end

    return want == true or (type(want) == "table" and want[cname] == true)
end

-- Both hook slots fire for one throw; the first to see a projectile handles it.
local defBotSeen, defBotSeenN = {}, 0

local function suppressDefBotProjectile(self, slot)
    if not live() then return end

    local proj = self:get()
    if Utils.IsActorInvalid(proj) then return end
    local ok, cname = pcall(function() return proj:GetClass():GetFName():ToString() end)
    if not ok or not DEFBOT_DESTROY[cname] then return end
    local key = Utils.ActorKey(proj)
    if not key or defBotSeen[key] then return end
    if defBotSeenN >= 64 then defBotSeen, defBotSeenN = {}, 0 end
    defBotSeen[key], defBotSeenN = true, defBotSeenN + 1

    -- Our variant's own projectiles carry WasThrown=true (PROJ.Queue) - never touch those.
    -- Tested FIRST so a scripted lob can't be caught by a body's own SuppressNativeThrows.
    local mine = false
    pcall(function() mine = proj.WasThrown == true end)
    if mine then return end

    -- Three arming channels: the GLOBAL deadline (all classes - the Mortar Turret's kill-all), the
    -- PER-CLASS map (selective - the Detonator drops mortar+molotov, keeps frag), and the THROWER's
    -- own def (permanent - see throwerSuppresses).
    local now = STATE.FAST_TICK
    local globalArmed = now <= (STATE.SuppressDefenseBotUntil or 0)
    local deadline = (STATE.SuppressDefBotClassUntil or {})[cname]
    local classArmed = (deadline ~= nil) and now <= deadline
    local ownerArmed = throwerSuppresses(proj, cname)

    -- SIGHTING diagnostic: every native defbot throw logs its armed state, so a dead suppressor
    -- names which channel failed. No lines at all means the hook isn't firing; all-false lines
    -- mid-fight mean arming is broken.
    Utils.LogDebug(("CombatHooks - defbot %s spawned [%s] (global=%s class=%s owner=%s)")
        :format(cname, tostring(slot), tostring(globalArmed), tostring(classArmed), tostring(ownerArmed)),
        SETTINGS.DEBUG_NPC_ACTIONS)

    if not globalArmed and not classArmed and not ownerArmed then return end

    -- Hide now, destroy just after the throw notify launches it. Destroying at BeginPlay kills it
    -- before the launch -> BP error.
    pcall(function() proj:SetActorHiddenInGame(true) end)
    Utils.QueueWork(function()
        if Utils.IsActorValid(proj) then
            pcall(function() proj:SetActorHiddenInGame(true) end)
            pcall(function() proj:K2_DestroyActor() end)
        end
    end, 50)
    Utils.LogDebug("CombatHooks - defbot " .. cname .. " suppressed", SETTINGS.DEBUG_NPC_ACTIONS)
end

local function registerDefenseBotSuppressor()
    -- These hook PROJECTILE classes, which needn't be in memory when the first Robot_Defense
    -- mutates (nothing thrown yet). A raw RegisterHook on an unloaded class THROWS, the error is
    -- swallowed upstream, and registeredClassHooks is already latched so it never retries - the
    -- "suppression silently does nothing" first-test bug. So load both parents, then pcall-register.
    local ASSETS = require("AnteCore.AssetManager")   -- lazy: avoids any require-order surprise
    local grenadeParent = "/Game/Blueprints/Projectiles/Projectile_Grenade_ParentBP.Projectile_Grenade_ParentBP_C"
    local bombParent    = "/Game/Blueprints/Projectiles/AbioticProjectile_ParentBP.AbioticProjectile_ParentBP_C"
    ASSETS.LoadAsync({ grenadeParent, bombParent }, function()
        ASSETS.WarmPinned({ grenadeParent, bombParent })   -- a class that unloads takes its hook with it
        -- Both slots: POST alone sat dead on this hook, PRE delivers ([[anteup2-hook-post-slot-unreliable]]).
        local ok1, err1 = pcall(RegisterHook, GRENADE_BEGINPLAY_HOOK,             -- frag + mortar
            function(self) suppressDefBotProjectile(self, "pre") end,
            function(self) suppressDefBotProjectile(self, "post") end)
        local ok2, err2 = pcall(RegisterHook, BOMB_BEGINPLAY_HOOK,                -- molotov
            function(self) suppressDefBotProjectile(self, "pre") end,
            function(self) suppressDefBotProjectile(self, "post") end)
        if ok1 and ok2 then
            Utils.Log("CombatHooks - DefenseBot projectile suppressor registered")
        else
            LogBad("CombatHooks - DefenseBot suppressor FAILED: "
                .. tostring(err1 or "") .. " / " .. tostring(err2 or ""))
        end
    end)
end


-- =======================================================================
-- ArmDefenseBotSuppressor - the same registration, callable AHEAD OF TIME.
--   * WHY IT IS PUBLIC: arming costs 2 LoadAsync probes + 2 by-NAME RegisterHooks, and on this
--     UE4SS build every one of those is a full UObject-array walk. RegisterClassHooks fires it on
--     the FIRST Artillery Bot mutation - which for the DarkLens Jotun is the exact frame batch that
--     just tore its steed and the steed's welded passengers down. A walk over a half-destroyed
--     object IS [[anteup2-ue4ss-findobject-scan-crash]] - see AnNotes/AnteSystems/CombatHooks.md for the AV
--     this actually caused.
--   * So a summoner that KNOWS it will portal Artillery Bots in later arms it at a quiet moment
--     instead (GK_DarkLensJotunHelpers.JotunReady = boss adoption). Same one-time cost, paid early.
--   * Idempotent, and it shares registeredHookPaths with RegisterClassHooks - whichever runs first
--     wins and the other becomes a table read. Placed OUTSIDE the per-row latch for the same reason
--     that call site is: registeredClassHooks is keyed by row, and a Deatomizer Bot mutating first
--     would claim "Robot_Defense" and lock the Artillery Bot out.
-- =======================================================================
function HOOKS.ArmDefenseBotSuppressor()
    if registeredHookPaths[GRENADE_BEGINPLAY_HOOK] then return end
    registeredHookPaths[GRENADE_BEGINPLAY_HOOK] = true
    registerDefenseBotSuppressor()
end


-- Both ends of the Volatile Exor's leap, off the one movement-mode event the chassis fires:
-- LaunchCharacter flips it to Falling, and the landing flips it back.
--   * def.NoLeapConcussion - the native landing concusses every PLAYER within 3.5m
--     (Debuff_Concussed, 10s), applied inline with nothing gating the radius or duration. Strip it
--     from nearby players on the next drain: a buff touch nested in a movement hook is the S2
--     hazard, and a REMOVE loads nothing so the drain is safe.
--   * def.LeapSpeed - a pounce slow enough to read and step out of. There is no speed property:
--     the arc is solved at world gravity and flown at GravityScale, so scaling the launch velocity
--     by k and gravity by k*k holds the landing point and stretches the airtime to 1/k.
-- Both fire for every Exor_Volatile and are gated on the opt-in field, so vanilla / Acidic Exors
-- are untouched.
local EXOR_MOVEMODE_HOOK =
    "/Game/Blueprints/Characters/NPCs/NPC_Monster_Exor_Volatile.NPC_Monster_Exor_Volatile_C:K2_OnMovementModeChanged"
local CONCUSSION_STRIP_RADIUS = 700   -- native apply is 350; padded for player drift over the QueueWork tick
local MOVE_FALLING = 3
local EXOR_LEAP_STALE = 600   -- ticks: drop the entry of a body that streamed out mid-leap

-- ActorKey -> { mode = the transition we last acted on, grav = GravityScale before the leap }.
-- `mode` is what makes the pair of callback slots below idempotent.
local exorLeap = {}

local function exorMoveMode(self, _prevMode, newMode)
    if not live() then return end
    local actor = self and self:get()
    if Utils.IsActorInvalid(actor) then return end
    local def = serverDef(actor)
    if not def or not (def.NoLeapConcussion or def.LeapSpeed) then return end

    local mode
    pcall(function() mode = tonumber(newMode:get()) end)
    if not mode then return end

    local key = Utils.ActorKey(actor)
    if not key then return end

    local now = STATE.FAST_TICK
    local st = exorLeap[key]
    if st and st.mode == mode then return end   -- the other slot already ran this transition
    if not st then
        for k, e in pairs(exorLeap) do
            if now - e.at > EXOR_LEAP_STALE then exorLeap[k] = nil end
        end
        st = {}
        exorLeap[key] = st
    end
    st.mode, st.at = mode, now

    if mode == MOVE_FALLING then
        if not def.LeapSpeed then return end
        local lunging = false
        pcall(function() lunging = actor.IsLunging == true end)
        if not lunging then return end   -- walked off a ledge, not the ability

        -- Written INLINE, deliberately: deferring by even one drain spends the opening of the
        -- flight at full speed. Nothing here can load.
        local k = def.LeapSpeed
        pcall(function()
            local move = actor.CharacterMovement
            if not IsValid(move) then return end
            local v = move.Velocity
            if not v then return end
            st.grav = move.GravityScale or 1
            move.Velocity = FVector(v.X * k, v.Y * k, v.Z * k)
            move.GravityScale = st.grav * k * k
        end)
        return
    end

    -- LANDED.
    if st.grav then
        local grav = st.grav
        st.grav = nil
        pcall(function()
            local move = actor.CharacterMovement
            if IsValid(move) then move.GravityScale = grav end
        end)
    end

    if not def.NoLeapConcussion then return end
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) then return end
        local loc = actor:K2_GetActorLocation()
        if not loc then return end
        local gs = STATE.GameState
        local players = gs and gs.PlayerCharacterInGame
        if not players then return end
        local r2 = CONCUSSION_STRIP_RADIUS * CONCUSSION_STRIP_RADIUS
        for i = 1, #players do
            local p = players[i]
            if Utils.IsActorValid(p) then
                local ok, pl = pcall(function() return p:K2_GetActorLocation() end)
                if ok and pl and Utils.DistSq(loc, pl) <= r2 then
                    Utils.RemoveBuff(p, ENUMS.Debuffs.Concussed)
                end
            end
        end
    end, 0)
end

local function registerExorLeapHook()
    RegisterHook(EXOR_MOVEMODE_HOOK, exorMoveMode, exorMoveMode)
end


-- Register class-specific hooks for an NPC row, once. Called from NpcManager.MutateActor, i.e.
-- only when an instance of that class exists.
function HOOKS.RegisterClassHooks(rowName, variantName)
    -- DefenseBot suppressor: per-VARIANT, not per-row, and latched OUTSIDE the row latch below.
    --   * Only two variants want it: the Artillery Bot (RobotDefenseHelpers.ArtilleryTick sets
    --     STATE.SuppressDefenseBotUntil) and anything declaring def.SuppressNativeThrows. Registering
    --     for the whole row made every Robot_Defense mutation pay a 4-scan burst (2 LoadAsync probes
    --     + 2 by-NAME RegisterHooks - a hook path IS a UObject-array scan) and left two GLOBAL
    --     projectile ReceiveBeginPlay hooks live, so every projectile in the world (base turret bolts
    --     included) entered Lua for the rest of the session - the same scan-crash family as
    --     [[anteup2-ue4ss-findobject-scan-crash]] (see AnNotes/AnteSystems/CombatHooks.md).
    --   * Own latch because registeredClassHooks is keyed by ROW: a Deatomizer mutating first would
    --     claim "Robot_Defense" and lock a later Artillery Bot out of its hook entirely.
    --   * A summoner that can see an Artillery Bot coming should call ArmDefenseBotSuppressor at a
    --     quiet moment instead; this stays as the catch-all for every other spawn path.
    local sdef = variantName and VARIANTS[variantName]
    if variantName == "Artillery Bot" or (sdef and sdef.SuppressNativeThrows) then
        HOOKS.ArmDefenseBotSuppressor()
    end

    -- def.DeployableDamage: also per-VARIANT and also outside the row latch, for the same reason -
    -- the hook is about the DEPLOYABLE class, not this NPC's, so it is armed by whether a def asks
    -- for it rather than by which row spawned. Self-latching, so this is one table lookup after the
    -- first arming. Both the base and the hard-mode map count as asking.
    if variantName and not deployHookArmed then
        local d = VARIANTS[variantName]
        if d and (d.DeployableDamage or (d.HardMode and d.HardMode.DeployableDamage)) then
            registerDeployableDamageHook()
        end
    end

    if not rowName or registeredClassHooks[rowName] then return end
    registeredClassHooks[rowName] = true

    if rowName == "ReaperScout" then registerScoutHolyHook(); pinHookClasses({ SCOUT_RESPONSE_HOOK }) end
    if rowName == "Groupe_Rook" then registerRookBashHook(); pinHookClasses({ ROOK_MELEE_PICK_HOOK }) end
    if rowName == "Gatekeeper_MageEye" then registerMageEyeDeathHook(); pinHookClasses({ MAGEEYE_DEATH_HOOK }) end
    if rowName == "Exor_Volatile" then registerExorLeapHook(); pinHookClasses({ EXOR_MOVEMODE_HOOK }) end

    -- Any pest-family row (Pest, Pest_Snow, Pest_Electro, Pest_Volatile, Pest_Laser, ... - incl.
    -- the tamed re-mutations): ONE library hook covers the whole family, so it latches on the hook
    -- path rather than the per-row dedup above.
    if rowName:sub(1, 4) == "Pest" and not registeredHookPaths[APOC_CHECK_HOOK] then
        registeredHookPaths[APOC_CHECK_HOOK] = true
        registerPestApocLeapHook()
        pinHookClasses({ APOC_CHECK_HOOK })
    end

    local specs = CLASS_HOOKS[rowName]
    if not specs then return end

    local hooked = {}
    for _, spec in ipairs(specs) do hooked[#hooked + 1] = spec.path end
    pinHookClasses(hooked)

    for _, spec in ipairs(specs) do
        local field = spec.dispatch
        local dedupKey = spec.path .. "|" .. field
        if not registeredHookPaths[dedupKey] then
            registeredHookPaths[dedupKey] = true
            -- PCALL'd, and that is not paranoia: RegisterHook THROWS on a path it cannot resolve
            -- (CLAUDE.md 2), this runs INSIDE MutateActor, and an un-guarded throw would abort the
            -- MUTATION - every spec after it, and the body itself, left half-made. One typo'd path
            -- in the table above is worth one dead dispatch and a log line, not a broken NPC.
            local ok, err
            if spec.passParams then
                -- OPT-IN param forwarding (OnTeleport's endpoint vectors). Per spec, not
                -- global: a bare-ref handler with its own optional second arg (H.ZigLeap's
                -- `opts`) must never suddenly receive a hook param wrapper in it.
                local cb = function(self, ...)
                    if not live() then return end
                    dispatchVariant(self:get(), field, ...)
                end
                if spec.bothSlots then
                    -- Some BP events never fire the single-callback (PRE) slot on this build
                    -- while the POST slot works (the NoAvail stun hook shipped silently dead
                    -- PRE-only). Both slots may ALSO both fire - the handler must tolerate
                    -- running twice per call.
                    ok, err = pcall(RegisterHook, spec.path, cb, cb)
                else
                    ok, err = pcall(RegisterHook, spec.path, cb)
                end
            else
                ok, err = pcall(RegisterHook, spec.path, function(self)
                    if not live() then return end
                    dispatchVariant(self:get(), field)
                end)
            end
            -- The dedup key is stamped ABOVE, on the attempt - a path that failed to resolve once
            -- will fail on every later mutation of that row too, and this sits on the spawn path.
            if not ok then
                LogBad("CombatHooks - class hook FAILED (" .. dedupKey .. "): " .. tostring(err))
            end
        end
    end
    Utils.Log("CombatHooks - class hooks registered for " .. rowName)
end

function HOOKS.Register()

    -- ================================================================
    -- def.PetSpecialAttack - override a PET special's DT_Pets damage (see the banner above
    -- registerPetSpecialAttackHook). Eager: it lives on the always-loaded NPC_Base_ParentBP.
    --
    -- FIRST, before any of the bare RegisterHook calls below. Those are un-pcall'd, and
    -- `RegisterHook` THROWS while its target class is unloaded (CLAUDE.md 2) - one throw aborts
    -- the rest of Register(). Registered last, this silently never ran; it is pcall'd internally,
    -- so nothing after it can be affected by putting it first.
    -- ================================================================
    registerPetSpecialAttackHook()
    registerSkipAggroHook()
    registerNoDodgeHook()

    deathDone = {}   -- fresh world -> fresh once-per-actor death latch
    deadAddrs, deadAddrCount = {}, 0   -- FAST_TICK resets per world, so stale stamps would read
                                       -- as "recently dead" forever - drop them with the world

    -- ================================================================
    -- ProcessDamage - fires whenever a character takes damage
    -- ================================================================
    local hook = "/Game/Blueprints/Characters/Abiotic_Character_ParentBP.Abiotic_Character_ParentBP_C:ProcessDamage"
    RegisterHook(hook,
        function(self, Damage, DamageType, HitLocation, HitNormal, HitComponent, BoneName,
                 ShotFromDirection, InstigatedBy, DamageCauser, HitInfo)

            if not live() then return end

            local victim = self:get()

            -- THE KILLING BLOW. Victim classes Super into this function, so by the time we run the
            -- body - death included - is done. Damage observers still get that hit; variant
            -- dispatch keeps skipping it.
            local killingBlow = diedThisTick(victim)

            -- ADDRESS-ONLY corpse bail FIRST. A DoT tick can reach ProcessDamage via FTimerManager
            -- on a freed+reused victim slot, which reads back as a packed-int rather than nil - the
            -- same freed-slot family the ATTACKER path below is guarded against, now on the victim,
            -- which still deref'd first via IsDeadSafe / .NPCData / LastPointDamage. Skipping on the
            -- wrapper ADDRESS needs no deref; a reused address just loses dispatch for the TTL
            -- window. See AnNotes/AnteSystems/CombatHooks.md for the AV this fixed.
            if not killingBlow and isRecentlyDead(victim) then return end
            if Utils.IsActorInvalid(victim) then return end

            -- HAZARD-CORPSE BAIL: skip already-dead victims. A corpse in an environmental DoT
            -- (fire volume, electrified Office water, acid proc) keeps firing ProcessDamage every
            -- tick for SECONDS after death, a window that overlaps GC reusing its slot - and every
            -- fire derefs the dying actor (LogDamage HP reads, LastPointDamage, the victim block).
            -- The killing blow is NOT exempt from this: the body has already set IsDead by the time
            -- we run (see killingBlow above), so only observers get past it.
            if not killingBlow and Utils.IsDeadSafe(victim) then return end

            -- Profiling: time the live-dispatch path per hit, per victim - the aggregate in a
            -- dense fight is the interesting number. The bails above are too cheap to matter.
            local profT0 = PROF.Begin()

            -- DamageCauser is nil for some effects (the bleeding debuff): IsValid is safe on a
            -- null wrapper, direct property access is not. The name resolve is GC-hardened too -
            -- a timer-driven DoT tick can pass a FREED causer that still passes IsValid, and a
            -- fresh DisplayName deref on it is the FTimerManager -> ProcessDamage AV.
            -- DamageCauserName caches by address and only derefs on FIRST sight, while alive.
            local attacker = DamageCauser:get()

            -- ADDRESS-ONLY corpse bail for the ATTACKER too: a DoT / attribution tick can carry a
            -- causer that died or was vacuumed mid-flight. The causer is already stamped by
            -- OnRep_IsDead + ReceiveEndPlay, but the name resolve below - and
            -- LogDamage, whenever DEBUG_DAMAGE_* is on - would deref it FIRST-SIGHT before any
            -- guard, and DamageCauserName's cache only covers causers seen WHILE ALIVE. So consult
            -- the stamp with no deref and squash a dead causer to nil, which is already the handled
            -- "no causer" shape downstream. The only cost is a cosmetic name loss for a causer
            -- first seen post-mortem - exactly the sight that AVs.
            if attacker and isRecentlyDead(attacker) then attacker = nil end

            if killingBlow then
                notifyDamageObservers(victim, attacker, InstigatedBy, DamageType)
                PROF.EndAs(profT0, "CombatHooks.ProcessDamage dispatch")
                return
            end

            local attackerName = Utils.DamageCauserName(attacker) or ""

            -- Rich damage trace, split by victim kind. NPC lines are CHATTY (every stress-test
            -- hit); PLAYER lines are the tuning-relevant ones and log for ANY source - the old
            -- variant-attacker gate missed projectiles, whose causer is never a variant name.
            local victimIsNpc = IsValid(victim.NPCData)
            if (victimIsNpc and SETTINGS.DEBUG_DAMAGE_NPC)
                or (not victimIsNpc and SETTINGS.DEBUG_DAMAGE_PLAYER) then
                Utils.LogDamage(victim, attacker, DamageType)
            end

            -- A variant dealt damage
            local attackerDef = VARIANTS[attackerName]
            local dispatchAttacker = attacker

            -- PROJECTILE damage: the causer is the projectile actor, so the lookup above misses
            -- and grenades/mortars/fireballs never dispatched OnDealtDamage. Fall back to the
            -- causer's INSTIGATOR name (GC-safe, first-sight-cached), OPT-IN via
            -- def.ProjectileDealtDamage - handlers written for attacker == the NPC must not
            -- suddenly get a projectile (the Groupe Sniper relocates its attacker). When fresh the
            -- PROJECTILE is passed as attacker = the blast origin, a better knockback direction
            -- than the bot; on stale DoT ticks it is nil, so guard.
            if not attackerDef then
                local instName, fresh = Utils.DamageCauserInstigatorName(attacker)
                local instDef = instName and VARIANTS[instName]
                if instDef and instDef.ProjectileDealtDamage then
                    attackerDef = instDef
                    attackerName = instName
                    dispatchAttacker = fresh and attacker or nil
                end
            end

            if attackerDef and attackerDef.OnDealtDamage then
                -- POSTHUMOUS GUARD: a dead attacker's lingering DoTs still credit it every tick,
                -- its wrapper may be a freed slot, and a corpse firing on-hit abilities is wrong
                -- anyway. Address check only, no deref of the possibly-stale wrapper.
                if dispatchAttacker and isRecentlyDead(dispatchAttacker) then
                    Utils.LogDebug("OnDealtDamage [" .. attackerName .. "] skipped: attacker is dead/departed",
                        SETTINGS.DEBUG_NPC_ACTIONS)
                else
                    local ok, err = pcall(attackerDef.OnDealtDamage, dispatchAttacker, victim)
                    if not ok then LogBad("OnDealtDamage [" .. attackerName .. "]: " .. tostring(err)) end
                end
            end

            -- A variant took damage
            if not victim.IsDead then
                -- Stagger-immune pawns (AVU.SetStaggerImmune) shrug off the forced stagger a WEAKNESS
                -- hit brings: this hook sits between the engine raising the flag and CheckForStagger
                -- reading it. Flag first - it is false on every non-weak hit, so the key is only
                -- built when there is something to clear. The damage bonus has already landed.
                local weakHit = false
                pcall(function() weakHit = victim.RecentlyWeaknessStaggered == true end)
                if weakHit and STATE.StaggerImmuneActors then
                    local victimKey = Utils.ActorKey(victim)
                    if victimKey and STATE.StaggerImmuneActors[victimKey] then
                        pcall(function() victim.RecentlyWeaknessStaggered = false end)
                        weakHit = false
                        if SETTINGS.DEBUG_NPC_ACTIONS then
                            Utils.LogDebug("StaggerImmune - weakness stagger dropped on "
                                .. tostring(Utils.GetActorName(victim)), true)
                        end
                    end
                end
                -- Same seam, rate-limited instead of refused: HardMode's weakness window (NoMercy,
                -- and ItemMods' LongThrow for its own hits) lets one forced stagger per victim through.
                if weakHit and STATE.WeaknessStaggerGate then
                    local okGate, drop = pcall(STATE.WeaknessStaggerGate, victim, attacker, DamageType)
                    if okGate and drop then
                        pcall(function() victim.RecentlyWeaknessStaggered = false end)
                    end
                end

                local victimDef = serverDef(victim)
                local victimName = victimDef and victimDef.Name or "?"

                -- A FLOOR TRAP applies its TrapDebuffs straight onto the buff component, past the
                -- DebuffsImmune list every other applier asks first - so a body "immune" to
                -- Debuff_ShockTrap was stunned by the Shock Trap itself. Shed what it should refuse;
                -- the debuff can land either side of this hit, hence the repeats.
                if victimDef and victimDef.DebuffsImmune and attacker and attackerName:find("Trap", 1, true) then
                    pcall(function()
                        local AVU = require("AnteUtils.AVUtils")
                        local rows = attacker.TrapDebuffs
                        for i = 1, #rows do
                            local row = rows[i]:ToString()
                            if AVU.IsDebuffImmune(victim, row) then
                                AVU.StripBuffSoon(victim, row, { 100, 300, 600 })
                                Utils.LogDebug("TrapImmune - " .. tostring(victimName) .. " sheds " .. row,
                                    SETTINGS.DEBUG_NPC_ACTIONS)
                            end
                        end
                    end)
                end

                if victimDef and victimDef.OnDamageTaken then
                    -- pcall'd: LastPointDamage is nil for some damage types. The DamageType object
                    -- is passed through - some variants react to the type.
                    local ok, err = pcall(function()
                        local damage = victim.LastPointDamage.IncomingDamage_13_40FC659E429FC966D1A7919E7D20512A
                        victimDef.OnDamageTaken(victim, damage, DamageType:get())
                    end)
                    if not ok then LogBad("OnDamageTaken [" .. victimName .. "]: " .. tostring(err)) end
                end
            end

            notifyDamageObservers(victim, attacker, InstigatedBy, DamageType)

            PROF.EndAs(profT0, "CombatHooks.ProcessDamage dispatch")
        end)

    -- ================================================================
    -- OnRep_IsDead - actor died. The first ~10s of a world is skipped for the variant dispatch:
    -- NPCs reloading from the save fire a flood of OnReps for already-dead actors.
    -- ================================================================
    hook = "/Game/Blueprints/Characters/Abiotic_Character_ParentBP.Abiotic_Character_ParentBP_C:OnRep_IsDead"
    RegisterHook(hook,
        function(self)
            if not live() then return end

            local actor = self:get()
            if Utils.IsActorInvalid(actor) then return end

            -- ANY death may orphan native AreaEffects the actor cast (molotov / spore-cloud timers
            -- ticking a freed instigator = the FTimerManager AV), so queue the coalesced sweep
            -- (authority-gated inside). Deliberately BEFORE the early-world gate: the save-load
            -- OnRep flood is exactly when restored effects need their casters checked, and the
            -- sweep is coalesced, so the whole flood costs one scan.
            pcall(function() require("AnteUtils.AVUtils").NoteDeathForAreaSweep(actor) end)

            -- Its lingering DoTs must not fire on-hit abilities posthumously, and the corpse must
            -- not keep ticking DoT damage into this hook (guard/strip headers above).
            noteDeadAddr(actor)
            stripCorpseDebuffs(actor)

            -- Skip the first ~10s for the VARIANT dispatch only: NPCs reloading from the save fire
            -- a flood of OnRep calls for already-dead actors.
            if STATE.FAST_TICK < 100 then return end

            -- Latched: an NPC whose own death sequence ALSO dispatches OnDeath (the Mage Eye class
            -- hook) must not run the variant's OnDeath - and drop its loot - twice.
            dispatchDeathOnce(actor)
        end)

    -- ================================================================
    -- ReceiveEndPlay - an actor leaving the world without necessarily dying: death-cleanup
    -- destroy, sublevel STREAM-OUT, level transition. The death sweep above never sees a
    -- streamed-out caster (no OnRep_IsDead fires), so its AreaEffect timers keep ticking a
    -- soon-freed instigator - the FTimerManager -> hooked-ProcessDamage AV (the CrashDOT family).
    -- The actor is still valid during EndPlay, so note it for the same coalesced sweep; a
    -- zone-exit burst folds into one throttled scan.
    -- ================================================================
    --   * No IsActorInvalid bail here. An NPC despawned because its level unloaded already reads
    --     IsLevelLoaded = false, so that bail skipped the stamp AND the sweep note for exactly
    --     the stream-out case. self is live for the whole of EndPlay, so a nil check is enough.
    local function onCharacterEndPlay(self)
        if not live() then return end

        local actor = self:get()
        if IsNotValid(actor) then return end

        -- Every deferred wrapper's first touch reads this (Utils.IsActorValid). False = already
        -- stamped this tick: one body reaches here up to three times (both slots of the NPC hook,
        -- plus the parent's), and the sweep note below costs a GetFullName.
        if not Utils.NoteDeparted(actor) then return end

        noteDeadAddr(actor)        -- block posthumous OnDealtDamage dispatch
        pcall(function() require("AnteUtils.AVUtils").NoteDeathForAreaSweep(actor) end)
    end

    hook = "/Game/Blueprints/Characters/Abiotic_Character_ParentBP.Abiotic_Character_ParentBP_C:ReceiveEndPlay"
    RegisterHook(hook, onCharacterEndPlay)

    -- NPC_Base OVERRIDES ReceiveEndPlay and reaches the parent only through a local script call,
    -- so the engine never dispatches the function hooked above for an NPC. Hook the one it does
    -- dispatch. Both slots: the body is an absolute stamp, and the sweep note is coalesced.
    hook = "/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C:ReceiveEndPlay"
    local okEnd, errEnd = pcall(RegisterHook, hook, onCharacterEndPlay, onCharacterEndPlay)
    if not okEnd then LogBad("CombatHooks - NPC EndPlay hook FAILED: " .. tostring(errEnd)) end

    -- The birth half: a new NPC allocated at a departed address must not read as gone.
    local function onNpcBeginPlay(self)
        Utils.ForgetDeparted(self:get())
    end
    hook = "/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C:ReceiveBeginPlay"
    local okBegin, errBegin = pcall(RegisterHook, hook, onNpcBeginPlay, onNpcBeginPlay)
    if not okBegin then LogBad("CombatHooks - NPC BeginPlay hook FAILED: " .. tostring(errBegin)) end

    -- Players override both events too, so the character-parent hook above reaches them only by a
    -- local script call. Just the registry here (the buff lookup trusts it for players).
    local function stampPlayerGone(self)
        if not live() then return end
        local p = self:get()
        if IsNotValid(p) then return end
        Utils.NoteDeparted(p)
    end
    local function forgetPlayerGone(self) Utils.ForgetDeparted(self:get()) end
    local PLAYER_BP = "/Game/Blueprints/Characters/Abiotic_PlayerCharacter.Abiotic_PlayerCharacter_C"
    local okPE, errPE = pcall(RegisterHook, PLAYER_BP .. ":ReceiveEndPlay", stampPlayerGone, stampPlayerGone)
    local okPB, errPB = pcall(RegisterHook, PLAYER_BP .. ":ReceiveBeginPlay", forgetPlayerGone, forgetPlayerGone)
    if okPE and okPB then
        Utils.ArmPlayerStamps()
        Utils.Log("CombatHooks - player EndPlay/BeginPlay registry hooks registered")
    else
        LogBad("CombatHooks - player registry hooks FAILED (player buffs stay on the path lookup): "
            .. tostring(errPE or errPB))
    end

    -- ================================================================
    -- OnRep_IsDBNO - actor went down-but-not-out (Order soldiers et al) -> def.OnDBNO(actor),
    -- e.g. the Grenadier cooking off its grenades. Fires on BOTH entering and leaving DBNO, so
    -- gate on actor.IsDBNO == true.
    -- ================================================================
    hook = "/Game/Blueprints/Characters/Abiotic_Character_ParentBP.Abiotic_Character_ParentBP_C:OnRep_IsDBNO"
    RegisterHook(hook,
        function(self)
            if not live() then return end
            if STATE.FAST_TICK < 100 then return end

            local actor = self:get()
            if Utils.IsActorInvalid(actor) then return end
            if not actor.IsDBNO then return end   -- only on ENTERING DBNO

            local variant = serverDef(actor)
            local actorName = variant and variant.Name
            if variant and variant.OnDBNO then
                local ok, err = pcall(variant.OnDBNO, actor)
                if not ok then LogBad("OnDBNO [" .. actorName .. "]: " .. tostring(err)) end
            end
        end)

    -- ================================================================
    -- OnRep_CombatState - actor.CombatState toggled -> def.OnEnterCombat / OnExitCombat.
    -- DBNO does NOT toggle CombatState, so an exit is a true disengage.
    -- ================================================================
    hook = "/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C:OnRep_CombatState"
    RegisterHook(hook,
        function(self)
            if not live() then return end
            if STATE.FAST_TICK < 100 then return end   -- skip the save-load combat-state flood

            local actor = self:get()
            if Utils.IsActorInvalid(actor) then return end

            local variant = serverDef(actor)
            local actorName = variant and variant.Name
            if not variant then return end

            local field = actor.CombatState and "OnEnterCombat" or "OnExitCombat"
            local fn = variant[field]
            if fn then
                local ok, err = pcall(fn, actor)
                if not ok then LogBad(field .. " [" .. actorName .. "]: " .. tostring(err)) end
            end
        end)

    -- ================================================================
    -- OnRep_IsGibbed - dead actor's corpse was destroyed.
    -- Longer startup skip (save-load gib replays).
    -- ================================================================
    hook = "/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C:OnRep_IsGibbed"
    RegisterHook(hook,
        function(self)
            if not live() then return end
            if STATE.FAST_TICK < 300 then return end

            local actor = self:get()
            if Utils.IsActorInvalid(actor) then return end

            local variant = serverDef(actor)
            local actorName = variant and variant.Name
            if variant and variant.OnGibbed then
                local ok, err = pcall(variant.OnGibbed, actor)
                if not ok then LogBad("OnGibbed [" .. actorName .. "]: " .. tostring(err)) end
            end
        end)

    -- ================================================================
    -- CheckForNPCDamageMultiplier - scales damage before it is applied, off
    -- AnteData/NpcResistances. This is how variants get weaknesses / resistances.
    -- ================================================================
    hook = "/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C:CheckForNPCDamageMultiplier"
    RegisterHook(hook,
        function(self, instigator, totalInDamage, damageType, hit, totalOutDamage)
            if not live() then return end

            -- Cheap early-out: the game fires this CONSTANTLY with 0 damage (overlap/contact/aggro
            -- checks - the Chopinator brushing the bot). Scaling 0 is pointless, so bail before any
            -- GetActorName/table work. Also kills the "dmg -> 0.0" log flood.
            local damage = totalOutDamage:get() or 0
            if damage <= 0 then return end

            local actor = self:get()
            -- Address-only bail first (no deref; same 2026-07-21 hardening as ProcessDamage).
            if isRecentlyDead(actor) then return end
            if Utils.IsActorInvalid(actor) then return end

            -- Same hazard-corpse bail as ProcessDamage: no resist/weakness scaling for a corpse in
            -- an environmental DoT, since the derefs below would touch a dying actor every tick.
            -- The lethal hit still scales - IsDead isn't set until the native body runs.
            if Utils.IsDeadSafe(actor) then return end

            -- Scale a hit ONCE. An AoE hit reaches here twice; the repeat carries what the first
            -- pass wrote, and everything below must not compound on itself (see setScaled).
            local sAddr = scaleAddr(actor)
            if isSecondScalePass(sAddr, totalInDamage and totalInDamage:get()) then return end

            if isDownedPet(actor) then
                setScaled(totalOutDamage, sAddr, 0)
                return
            end

            -- FRONT SHIELD-WALL (AVU.AddShieldWall) - absorbs a hit thrown from inside the
            -- wearer's frontal cone. Above everything else: a wall eats the hit whole, the way the
            -- native Mystagogue plate does, so nothing downstream should scale what it already ate.
            --   * Checked for EVERY NPC, not just registered variants - the mage lends these to
            --     plain allies, which have no def to hang a DamageGate on.
            --   * The `next` guard is the point: with no wall up anywhere (the overwhelmingly
            --     common case) this costs one table probe, not a GetFullName per hit.
            if next(STATE.ShieldWalls) then
                local shooter
                pcall(function()
                    local inst = instigator and instigator:get()
                    if IsNotValid(inst) then return end
                    local pawn = inst.K2_GetPawn and inst:K2_GetPawn() or inst
                    if IsValid(pawn) then shooter = pawn:K2_GetActorLocation() end
                end)
                -- Lazy require: cached, and only reached while a wall is actually up.
                local survives = require("AnteUtils.AVUtils").ShieldWallSurvival(actor, shooter)
                if survives < 1 then
                    damage = math.floor(damage * survives)
                    setScaled(totalOutDamage, sAddr, damage)
                    if damage <= 0 then return end
                end
            end

            local vdef = serverDef(actor)
            local actorName = vdef and vdef.Name

            -- def.DamageGate(victim) -> true = IGNORE this hit entirely; a NUMBER = per-hit
            -- damage CAP. A per-hit veto/limit, for rules no stat can express - the DarkLens
            -- bosses use `true` to shrug off fire thrown in from outside their arena, and the
            -- Magus returns a cap so no single hit can burst through a phase floor (its clamp
            -- only snaps AFTER a hit lands - a lethal hit must be bounded BEFORE the pipeline).
            --   * Answered PER HIT rather than latched onto `Invincible`, because that flag is
            --     usually already owned by something (a barrier, or the Mage's own default
            --     invulnerability) and a latch fights whoever else writes it.
            --   * Runs before the resist/weakness scaling: a 0 here is final; a cap is then
            --     still scaled below (and by the native limb/headshot steps after us).
            --   * ARGS: (victim, damageTypeObject, rawDamage). The extra two are additive - every
            --     gate written before them ignores them - and they are what lets a gate answer
            --     "this SOURCE, not this attacker" (the Tamed Telepest vetoes DeathPit damage so a
            --     fall into a pit becomes a warp home instead of a dead pet).
            local gate = vdef and vdef.DamageGate
            if gate then
                local ok, block = pcall(gate, actor, damageType and damageType:get() or nil, damage)
                if ok and block then
                    if block == true then setScaled(totalOutDamage, sAddr, 0) return end
                    if type(block) == "number" and damage > block then
                        damage = block
                        setScaled(totalOutDamage, sAddr, damage)
                    end
                end
            end

            -- def.NoSelfDamage: a body its own blast can't hurt. A grenade/flask runs
            -- ApplyRadialDamageWithFalloff with an EMPTY ignore list, so a thrower standing inside
            -- its own outer radius eats the hit - a projectile's collision ignore only stops the
            -- CONTACT, never the blast. For a thrower whose whole kit is lobbing AoE at its feet.
            --   * Zeroed and returned like a DamageGate: final, and nothing below compounds it.
            --   * ADDRESS compare, never `==` - each hook hands back a fresh wrapper.
            --   * Self only. Another body of the same variant is a different pawn and still hits.
            local nsd = vdef and vdef.NoSelfDamage
            if nsd and sAddr then
                local pawnAddr
                pcall(function()
                    local inst = instigator and instigator:get()
                    if IsNotValid(inst) then return end
                    local pawn = inst.K2_GetPawn and inst:K2_GetPawn() or inst
                    if IsValid(pawn) and pawn.GetAddress then pawnAddr = pawn:GetAddress() end
                end)
                if pawnAddr == sAddr then setScaled(totalOutDamage, sAddr, 0) return end
            end

            -- def.NpcDamageScale: an extra multiplier on damage dealt by ANOTHER NPC, so a body
            -- can be opened up to the AI (AVU.SetInvincibleToNPCs) without melting in a crossfire
            -- it was never balanced against. Player hits are untouched.
            --   * STACKS on the native step, which already multiplies an NPC's damage by the
            --     ATTACKER'S own DamageToNPCs (0.5 by default) - so 0.5 here is a quarter of a
            --     player's hit, not half.
            --   * The attacker test is only paid by a variant that declares the field.
            local nds = vdef and vdef.NpcDamageScale
            if nds then
                local inst
                pcall(function() inst = instigator and instigator:get() end)
                if Utils.IsAIInstigator(inst) then
                    damage = math.floor(damage * nds)
                    if damage < 1 then damage = 1 end   -- a floored 0 reads as immunity, CLAUDE.md 5
                    setScaled(totalOutDamage, sAddr, damage)
                end
            end

            -- HARD MODE (NoAvail): per-WEAPON nerf, keyed by DamageType CLASS name - the class is
            -- what separates a Megaton from a frag when both display as "Explosive". Set by
            -- ModuleHardMode/HardMode.lua per world; nil when hard mode is off.
            --   * Above the RESISTS gate below ON PURPOSE: this applies to EVERY NPC (vanilla
            --     included), not just registered variants.
            --   * Clamped to >=1, never 0: a floored 0 reads as immunity AND skips the rest of
            --     ProcessDamage (debuffs, stagger, aggro-on-damage) - see CLAUDE.md 5.
            --   * Stacks multiplicatively with a variant's own RESISTS row below - audit any
            --     variant that already resists a nerfed type.
            local hmScale = STATE.HardModeTypeScale
            if hmScale then
                local dtObj = damageType:get()
                if dtObj and IsValid(dtObj) then
                    local okC, cname = pcall(function() return dtObj:GetClass():GetFName():ToString() end)
                    local m = okC and cname and hmScale[cname]
                    if m then
                        damage = math.floor(damage * m)
                        if damage < 1 then damage = 1 end
                        setScaled(totalOutDamage, sAddr, damage)
                    end
                end
            end

            -- Per damage-type weakness/resistance, keyed by DISPLAY NAME rather than class:
            -- subclasses inherit DamageTypeDisplayName, so one "Sharp" key covers all ~25
            -- DamageType_Sharp_*, one "Bullet" covers sniper/shotgun/small/large. That is the whole
            -- value of this axis. (The GAME categorises by GameplayTags - see [[af-damage-types]].)
            --   * APOSTROPHE TRAP: Holy's display name is literally  'Holy'  - quote marks baked
            --     into the string-table source - so typeMods["Holy"] silently missed and every
            --     Holy= entry in NpcResistances was dead. Strip the quotes.
            --   * UNMATCHABLE, don't add keys: "Plasma" (Fire_Plasma doesn't override the display
            --     name, so it reads as "Fire" - already covered) and hardlight saber / sledge
            --     (Laser subclasses, so they read as "Laser").
            --   * This hook can never UN-immune an NPC: the native body already multiplied by
            --     ImmuneDamageMultiplier (0), and 0 * m == 0.
            local typeMods = actorName and RESISTS[actorName]
            -- HARD MODE (NoMercy): per-variant overrides layered over the base row - a
            -- type named in RESISTS.HardMode[name] WINS, unnamed types fall through to
            -- the base row. Tamed forms are separate display names, so they never harden.
            local hardMods = actorName and STATE.HardModeNoMercy and RESISTS.HardMode[actorName] or nil
            if not typeMods and not hardMods then return end   -- nothing to scale (the gate above already set)

            local dt = damageType:get()
            if dt and IsValid(dt) then
                local typeName = dt.DamageTypeDisplayName:ToString()
                if typeName then typeName = typeName:gsub("'", "") end
                local m = typeName and ((hardMods and hardMods[typeName])
                    or (typeMods and typeMods[typeName]))
                if m then damage = math.floor(damage * m) end
            end

            if damage and damage >= 0 then
                setScaled(totalOutDamage, sAddr, damage)
                -- (No log here - the rich "DMG:" line in the ProcessDamage hook
                -- covers damage visibility; this hook only does the scaling.)
            end
        end)

    -- ================================================================
    -- Server_DoMeleeAttackCustom - a special melee attack -> def.OnCustomMelee(actor, attackType).
    -- e.g. Security Robot: 1 = normal melee, 2 = lunge, 3 = spin.
    -- ================================================================
    hook = "/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C:Server_DoMeleeAttackCustom"
    RegisterHook(hook,
        function(self, attackType)
            if not live() then return end

            local actor = self:get()
            if Utils.IsActorInvalid(actor) then return end

            local def = serverDef(actor)
            if not (def and def.OnCustomMelee) then return end

            local atkType = attackType and attackType:get() or 0
            local ok, err = pcall(def.OnCustomMelee, actor, atkType)
            if not ok then LogBad("OnCustomMelee error: " .. tostring(err)) end
        end)

    -- ================================================================
    -- Broadcast_ReloadWeapon - a ranged NPC reloaded -> def.OnReload(actor). A NetMulticast on the
    -- always-loaded NPC_Base parent (hence eager), so it runs on the authority too. More reliable
    -- than polling CurrentAmmoCount, which refills to odd values. Magma Exor drops a fire patch.
    -- ================================================================
    hook = "/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C:Broadcast_ReloadWeapon"
    RegisterHook(hook,
        function(self)
            if not live() then return end
            dispatchVariant(self:get(), "OnReload")
        end)

    -- ================================================================
    -- Broadcast_ThrowGrenade - a throw STARTED (the windup, before the GrenadeRelease notify
    -- spawns the projectile) -> def.OnThrow(actor). Eager NPC_Base multicast, so it runs on the
    -- authority too. The reliable "throwing NOW" signal; the Mad Rat rides it to modulate throw
    -- speed via CustomTimeDilation.
    -- ================================================================
    hook = "/Game/Blueprints/Characters/NPCs/NPC_Base_ParentBP.NPC_Base_ParentBP_C:Broadcast_ThrowGrenade"
    RegisterHook(hook,
        function(self)
            if not live() then return end
            dispatchVariant(self:get(), "OnThrow")
        end)

    -- ================================================================
    -- OverrideProjectileBlock - THE NPC PROJECTILE-DEFLECT CHANNEL (AUTHORITY) ->
    -- def.OnProjectileBlocked(actor, projectile). The whole chain is native and lives on the
    -- CHARACTER PARENT, so NPCs inherit it even though only players ever light it up:
    --   AbioticProjectile BeginPlay binds TryOverrideBlock as the ProjectileMovement IMPACT
    --   OVERRIDE -> CheckOverriddenByBlock casts the hit actor to Abiotic_Character_ParentBP_C (an
    --   NPC passes) -> CheckProjectileBlockOverridden -> CanCurrentlyShieldBlock, whose parent body
    --   returns IsShieldBlocking when the causer is inside the +/-60 deg front yaw arc. True =>
    --   impact overridden (no damage, no FX, projectile NOT consumed) and OverrideProjectileBlock
    --   fires - an EMPTY parent stub, so a free hook point with no native behavior to fight.
    -- `IsShieldBlocking = true` (+ MarkReplicatedDirty) is the entire arming lever.
    --   * PROJECTILES ONLY: the other half of blocking (CanCurrentlyShieldBlock from ProcessDamage)
    --     is unreachable, because NPC_Base fully overrides ProcessDamage and never calls it. So
    --     hitscan, lasers and melee walk through the flag - handle those with a front-arc test in
    --     OnDamageTaken.
    --   * The handler runs INSIDE the projectile's impact ProcessEvent (S2): non-loading property
    --     writes only, and SYNCHRONOUS - deferring the velocity write by one tick lets the shot
    --     sail on. Push FX, damage and anything cold-loadable off-hook.
    -- ================================================================
    hook = "/Game/Blueprints/Characters/Abiotic_Character_ParentBP.Abiotic_Character_ParentBP_C:OverrideProjectileBlock"
    RegisterHook(hook,
        function(self, Projectile)
            if not live() then return end
            if not Utils.IsAuthority() then return end   -- clients override the impact locally
                                                         -- (they read the replicated flag); only
                                                         -- the server gets to re-aim the thing
            local actor = self:get()
            if Utils.IsActorInvalid(actor) then return end

            local def = serverDef(actor)
            local actorName = def and def.Name
            if not (def and def.OnProjectileBlocked) then return end

            local proj = Projectile and Projectile:get()
            if not proj or Utils.IsActorInvalid(proj) then return end

            local ok, err = pcall(def.OnProjectileBlocked, actor, proj)
            if not ok then LogBad("OnProjectileBlocked [" .. actorName .. "]: " .. tostring(err)) end
        end)

    -- ================================================================
    -- Class/NPC-specific hooks are registered lazily - their UFunctions don't resolve until an
    -- instance exists. See HOOKS.RegisterClassHooks(rowName), called on first mutation.
    -- ================================================================

    Utils.Log("CombatHooks registered")
end

return HOOKS
