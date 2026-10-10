-- =======================================================================
-- Chieftain helpers - the skink gun + tincture machinery behind AnteNPCs/GK_Chieftain.lua
--
-- MUST-KNOWS
--   * We can override its attack (hit-scan firing) with OverrideSoldierFireLogic 
--       - BT plays the fire montage/sounds
--       - OnRangedAttack dispatch fires the replacement shot and roll our own projectiles
--          > FireRanged_Projectile needs an FDataTableRowHandle - uses GrenadeData and 
--             passes that (AVU.FireProjectileRow)
--          > End with ReleaseSoldierBT or this never re-fires
--   * OnRep_ShieldBroken bypasses ue4ss hooks, so we need to poll for it
--       - Runs via EX_LocalVirtualFunction on host
--   * When it drinks a tincture (BuffObject_Stunned) we use BuffObject_Stunned which will freeze its BT
--       - Will test if a tincture was applied by catching for a buff. A phase latches when the boon actually applies, 
--         an interrupted drink stays unspent for the retry driver.
--
-- Decode notes: memory [[anteup2-chieftain-decode]]
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local ENUMS = require("AnteData.Enums")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local AVM = require("AnteUtils.AVMath")
local ASSETS = require("AnteCore.AssetManager")
local PROJ = require("AnteCore.Projectile")

local LogDebug = Utils.LogDebug

-- Weapon. Cycle = DELAY (windup) + RESET (BT release) + the BT / RangedAttack_Cooldown.
local GUN = {
    FireDelayMs = 100,   -- ms after Server_DoRangedAttack
    FireResetMs = 100,   -- ms after the lob before the BT release
    Cd          = 0.3,   -- RangedAttack_Cooldown - next-attack gate after the reset
    Ammo        = 500,   -- "no reload" in practice
    Row         = ENUMS.ProjectileRows.MagmaSkinkBall,    -- red magma goo lob (ignites + drops a fire AreaEffect)
    GrenadeRow  = ENUMS.ProjectileRows.ElectronGrenade,   -- bouncy, scatters crystal shards
}

-- Gun attachment (the backpack can't be recolored - its material has no Color param).
local SQUID_XF = {
    Scale = FVector(1.3, 1.3, 1.3),
    Loc   = FVector(0, -5, -20),
    Rot   = FRotator(0, 0, 0),
}

-- Tincture drink
local DRINK = {
    Rate = 2,      -- montage play rate (PlayThirdPersonMontage replicates it)
    Ms   = 1600,   -- DBNO_Heal is 3.8s at rate 1.0
}
local FLASK = {
    Bone  = "l_hand",
    Loc   = FVector(0, 0, 0),
    Scale = FVector(1.2, 1.2, 1.2),
}

-- The combat drink is unreliable (the BT isn't always overridden), so it retries.
-- (COMBAT_DRINK_DELAY_MS, the delay on the first attempt, lives in the def file.)
local COMBAT_RETRY = {
    Ms       = 2000,   -- gap between attempts while it keeps getting interrupted
    MaxTries = 5,
}

local FX_SPEEDY_AURA = ENUMS.Effects.TINCTURE_ELECTRIC_PASSIVE   -- looping body lightning (speedy)
local FX_BONE        = "R_Leg2"   -- body-centre bone for the attached aura

-- Storm tincture: a one time AoE stun, similar to the Storm Witch's takeoff nova
local STORM = {
    Radius = 700,   -- 7m
    Dmg    = 55,    -- per player caught (matches the Storm Witch's nova)
    StunS  = 1.5,   -- brief Debuff_Zapped
}
-- Fire-time deps - ride pick.Deps so the drink LoadAsyncs them ~DRINK.Ms ahead.
--   * Zapped applies BuffObject_Stunned (+ its BLUE LIGHTNING_STUN body FX - purple is
--     ZappedPurple, the drink hold); both cold-load on first use.
--   * TINCTURE_ELECTRIC_BURST is the nova's client FX, and SpawnLocalNiagara skips a cold asset
local STORM_DEPS = { ENUMS.DamageType.Electric, ENUMS.BuffObjects.Stunned,
                     ENUMS.Effects.LIGHTNING_STUN, ENUMS.Effects.TINCTURE_ELECTRIC_BURST }

-- After it dies, the gun it was holding scurries off as this.
local DEATH_SKINK = {
    DelayMs = 1800,
    Row     = "Skink_Magma",   -- DT_NPCList row (red skink)
}

-- DEBUG: force which tincture rolls (nil = random). "speedy" | "giganto" | "phasing" | "storm".
local DEBUG_FORCE_TINCTURE = nil

-- Per-actor state, keyed by Utils.ActorKey
local shieldPrev  = {}   -- key -> last polled CurrentShieldHitPoints
local drank       = {}   -- key -> { combat=true, shield=true } as each phase is spent
local drinking    = {}   -- key -> true while a drink is running (overlap guard)
local chestComps  = {}   -- key -> attached chest-plate component (kept so the drink tint can recolor it)
local squidComps  = {}   -- key -> attached squid-gun component (hidden on death)
local combatTries = {}   -- key -> combat-tincture attempts (retry cap)

local H = {}

-- key -> true while the phasing look is on. Exported: the def's OnDamageTaken re-drops the fade.
H.Phased = {}
local phased = H.Phased


-- =======================================================================
-- TINCTURES
-- Two roll per life (on aggro + on shield break).
--   * apply() runs on the AUTHORITY at drink-end, already off-hook (the drink-end WorkQueue
--     step) - which is where a damage call has to be.
-- =======================================================================

local TINCTURES = {
    {   -- SPEEDY - time dilation +20% (stride, attacks, the works), wearing the game's own electrifying-tincture aura; clients get it via the def's MirrorTimeDilation.
        Name = "speedy", Color = FVector(1, 0.3, 0.7),
        apply = function(actor)
            AVU.SetTimeDilation(actor, 1.2)
            H.MeleeTempo(actor)   -- the dilation moved the animation clock; the contact times follow it
            AVU.AttachNiagara(actor, FX_SPEEDY_AURA, FX_BONE, {})
        end,
    },
    {   -- GIGANTO - bigger body + hitbox (BodyScale mirrors to clients) and a heavier headbutt/kick; guarded multiply (§3).
        Name = "giganto", Color = FVector(1, 0.3, 0.7),
        apply = function(actor)
            AVU.SetBodyScale(actor, 1.2)
            pcall(function()
                local d = actor.NPCData
                local m = d[ENUMS.NpcData.MeleeDamage] or 0
                if m > 0 then d[ENUMS.NpcData.MeleeDamage] = m * 1.5 end
            end)
        end,
    },
    {   -- PHASING - near-invisible (DitherOpacity) + takes more damage; no FX (the impact burst read poorly, so the fade IS the look).
        Name = "phasing", Color = FVector(1, 0.3, 0.7),
        apply = function(actor)
            AVU.SetArmor(actor, { Head = -5, Chest = -5 })
            local key = Utils.ActorKey(actor)
            if key then phased[key] = true end
            H.ApplyPhaseLook(actor)
        end,
    },
    {   -- STORM - a 7m electric burst that stuns and deals BlastDamage (players-only AoE, §5).
        Name = "storm", Color = FVector(1, 0.3, 0.7), Deps = STORM_DEPS,
        apply = function(actor)
            local loc
            pcall(function()
                local l = actor:K2_GetActorLocation()
                loc = FVector(l.X, l.Y, l.Z)
            end)
            if not loc then return end
            AVU.SendClientFX(loc, "ELECTRIC_NOVA", 3)
            AVU.BlastDamage(actor, loc, {
                Radius = STORM.Radius, Damage = STORM.Dmg,
                DamageType = ENUMS.DamageType.Electric, RequireLoS = true,
                Debuff = ENUMS.Debuffs.Zapped, DebuffSeconds = STORM.StunS,
            })
        end,
    },
}


-- =======================================================================
-- THE DRINK
-- =======================================================================

-- Drink tincture - uses its DBNO heal montage with a flask in hand
--   * Does this up to two times - entering combat and when its shield breaks
--   * `drinking` = set this so it skips trying to drink while its drinking
--   * We can't reliably preload and pin tincture dependencies, so we have to cold load those
local function drinkTincture(actor, phase)
    if Utils.IsActorInvalid(actor) then return end
    local key = Utils.ActorKey(actor)
    if not key then return end
    if drank[key] and drank[key][phase] then return end   -- phase already spent
    if drinking[key] then
        LogDebug("Esoteric Chieftain - drink (" .. phase .. ") skipped: already drinking",
            SETTINGS.DEBUG_NPC_ACTIONS)
        return
    end

    local pick = TINCTURES[math.random(#TINCTURES)]
    if DEBUG_FORCE_TINCTURE then
        for _, t in ipairs(TINCTURES) do
            if t.Name == DEBUG_FORCE_TINCTURE then pick = t; break end
        end
    end

    -- Core drink set + ONLY the rolled tincture's extra dep.
    --   * Never cold-load the boon FX that didn't roll; usually all warm anyway via the keep-warm tick.
    local deps = {
        ENUMS.Anims.GK_DBNO_HEAL,
        ENUMS.Components.SM_FLASK_CONSUMABLE,
        ENUMS.Effects.TINCTURE_ELECTRIC_PASSIVE,   -- speedy body aura, spawned at drink-end
        ENUMS.BuffObjects.Stunned,                 -- the hold-stun applied at drink-start
        ENUMS.Effects.LIGHTNING_PURPLE,            -- + its BodyParticleEffect
        ENUMS.Effects.TINCTURE_GIGANTO_POOF,       -- shared drink-end smoke poof (every tincture)
    }
    for _, d in ipairs(pick.Deps or {}) do deps[#deps + 1] = d end

    -- Pinned as well: the poof and the boon FX fire at drink END, seconds after this load, and an
    -- unpinned one was collected in between on a dedicated server ("BroadcastFX - Niagara not resident").
    ASSETS.PinSoon(deps)
    ASSETS.LoadAsync(deps, function()
        Utils.QueueWork(function()
            if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return end
            -- Re-check the guards HERE: the async load + queue hop means another trigger
            -- could have started a sequence in the meantime.
            if drinking[key] then return end
            if drank[key] and drank[key][phase] then return end
            drinking[key] = true   -- overlap guard only; the PHASE latches on SUCCESS (drink-end)

            -- Plant it so the drink isn't broken:
            --   * StaggerCooldown parked so incoming fire can't flinch it out of the anim.
            --   * HoldStill locks the montage + stops the AI facing fight.
            --   * The native stun freezes the BT (see the header for why not WalkSpeed).
            local prevStagger = actor.StaggerCooldown
            AVU.HoldStill(actor, true)
            Utils.AddBuff(actor, ENUMS.Debuffs.ZappedPurple, true, 0.5)
            pcall(function() actor.StaggerCooldown = 99999 end)

            -- Keep its OWN attacks from stomping the drink anim (fire montage and melee/grab both override ours).
            --   * RangedAttack_OnCooldown is the proven ranged pin (Crystallisk lever:
            --     a manual `true` sticks until cleared below).
            --   * SuppressMelee covers the rest.
            pcall(function() actor.RangedAttack_OnCooldown = true end)
            AVU.SuppressMelee(actor, DRINK.Ms + 500)

            -- Sped via montage PlayRate, not CTD (the rate replicates - §4).
            --   * DRINK.Ms is derived from the rate, so the release/boon still lands at the anim's end.
            AVU.PlayMontageReplicated(actor, ENUMS.Anims.GK_DBNO_HEAL, DRINK.Rate, true)

            -- Flask in hand. Immediate=true because we destroy it at drink-end -
            -- a stagger-deferred attach returns nil and leaks the flask.
            local flask = AVU.AttachStaticMesh(actor, ENUMS.Components.SM_FLASK_CONSUMABLE, FLASK.Bone, {
                Location = FLASK.Loc,
                Scale = FLASK.Scale,
                Color = pick.Color,
                Immediate = true,
            })
            LogDebug("Esoteric Chieftain - drinking tincture_" .. pick.Name .. " (" .. phase .. ")",
                SETTINGS.DEBUG_NPC_ACTIONS)

            -- Drink done: release, drop the flask, tint + apply the boon.
            --   * The overlap guard clears FIRST, on every exit incl. a dead/invalid actor -
            --     a stuck guard would silently eat the other flask phase.
            Utils.QueueWork(function()
                drinking[key] = nil
                if Utils.IsActorInvalid(actor) then return end
                AVU.HoldStill(actor, false)
                Utils.RemoveBuff(actor, ENUMS.Debuffs.ZappedPurple)   -- native self-restore (BT_SetStunned false)
                pcall(function() actor.StaggerCooldown = prevStagger or 0 end)
                pcall(function() actor.RangedAttack_OnCooldown = false end)   -- re-arm the gun
                if flask then pcall(function() flask:K2_DestroyComponent(flask) end) end
                if actor.IsDead then return end

                -- Shared drink-end poof (every tincture).
                --   * The native Giganto smoke+glitter burst = the universal "drink done" tell.
                --   * BroadcastFX = one-shot GameState multicast.
                --   * Re-warmed here (load, then broadcast on the next drain item): the drink-start load is
                --     seconds old, and the pin above may not have landed yet.
                local ploc
                pcall(function() ploc = actor:K2_GetActorLocation() end)
                if ploc then
                    local x, y, z = ploc.X, ploc.Y, ploc.Z
                    ASSETS.LoadAsync({ ENUMS.Effects.TINCTURE_GIGANTO_POOF, ENUMS.SOUNDS.AIR_POOF }, function()
                        Utils.QueueWork(function()
                            AVU.BroadcastFX(FVector(x, y, z), ENUMS.Effects.TINCTURE_GIGANTO_POOF, ENUMS.SOUNDS.AIR_POOF,
                                FVector(1.5, 1.5, 1.5))
                        end, 0)
                    end)
                end

                -- Sell the flavour: recolor the body + chest plate. Renderer-local.
                --   * The flask's own material ignored the Color param, so the actor-wide tint
                --     is the readable tell.
                pcall(function()
                    local mesh = Utils.GetValidMesh(actor)
                    if mesh then mesh:SetVectorParameterValueOnMaterials(FName("Color"), pick.Color) end
                end)
                local chest = chestComps[key]
                if chest then AVU.TintComponent(chest, { Color = pick.Color }) end

                -- Guarded so a per-tincture error surfaces in the log instead of silently swallowing
                -- the visual, and never aborts the surrounding drain step.
                local okApply, applyErr = pcall(pick.apply, actor)
                if okApply then
                    drank[key] = drank[key] or {}
                    drank[key][phase] = true
                    LogDebug("Esoteric Chieftain - tincture_" .. pick.Name .. " applied (" .. phase .. ")",
                        SETTINGS.DEBUG_NPC_ACTIONS)
                else
                    Utils.LogBad("Esoteric Chieftain - tincture_" .. pick.Name .. " apply FAILED: " ..
                        tostring(applyErr))
                end
            end, DRINK.Ms)
        end, 0)
    end)
end


-- =======================================================================
-- LOADOUT
-- =======================================================================

-- Kill the native hitscan burst and hand it the skink gun + electron grenade.
function H.ArmSkinkGun(actor)
    pcall(function() actor.OverrideSoldierFireLogic = true end)
    pcall(function() actor.RangedAttack_Cooldown = GUN.Cd end)
    pcall(function()
        actor.MaxAmmoCount = GUN.Ammo
        actor.CurrentAmmoCount = GUN.Ammo
    end)

    AVU.SetProjectileRow(actor, "GrenadeData", GUN.GrenadeRow, true)
end


-- [RENDERER] Swap the magnum for the Magma Skink, plus the chest plate + helm tint.
function H.Gear(actor)
    pcall(function()
        local gun = actor.Gun
        if IsNotValid(gun) then return end
        gun:SetVisibility(false, false)
        local sock = gun:GetAttachSocketName()
        -- Immediate: the handle is kept so death can hide it (the squid "scurries off"
        -- as the death skink) - a stagger-deferred attach returns nil.
        local squid = AVU.AttachStaticMesh(actor, ENUMS.Components.SM_SQUID,
            sock and sock:ToString() or "None", {
                Location = SQUID_XF.Loc,
                Rotation = SQUID_XF.Rot,
                Scale = SQUID_XF.Scale,
                Material = ENUMS.Components.M_SQUID_MAGMA,   -- red magma skin (slot-0 override)
                Immediate = true,
            })
        local key = Utils.ActorKey(actor)
        if key and squid then squidComps[key] = squid end
    end)

    -- Skink squeal instead of the magnum bang.
    --   * WeaponFireSound is per-instance and does NOT replicate, so it belongs in Visuals.
    pcall(function()
        local cue = ASSETS.GetIfValid(ENUMS.SOUNDS.BIOCANNON_FIRE)
        if IsValid(cue) then actor.WeaponFireSound = cue end
    end)

    -- Cascade chest plate (Immediate so the post-drink tint can recolor it).
    local chest = AVU.AttachStaticMesh(actor, ENUMS.Components.SM_ARMOR_CHEST_CRYSTAL, "spine2", {
        Location = FVector(5, -23, 4),
        Rotation = FRotator(0, 90, 0),
        Color = FVector(0.2, 0.1, 0.2),
        Scale = FVector(1.2, 1.2, 1.2),
        Immediate = true,
    })
    local ckey = Utils.ActorKey(actor)
    if ckey and chest then chestComps[ckey] = chest end

    -- The Chieftain always wears a helm, and it parents the character master, so "Color" tints it.
    pcall(function() AVU.TintComponent(actor.Helmet, { Color = FVector(4, 2, 0.4) }) end)
end


-- =======================================================================
-- SHOOTING
-- =======================================================================

-- [RangedAttack] Fire its projectile off-hook.
--   * Borrows and repoints the GrenadeData handle (AVU.FireProjectileRow).
--   * A grenade-throw anim notify can't land in the same drain step - the drain is synchronous.
local function fireBioShot(actor)
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return end

    -- Re-pin the aim point: the parent Server_DoRangedAttack should have set it, but stale aim is
    -- invisible until a lob sails at a wall ([[af-npc-grenade-throw-chain]]).
    local target = actor:GetCurrentCombatTarget()
    local aim
    if Utils.IsActorValid(target) then
        pcall(function() aim = target:K2_GetActorLocation() end)
    end
    local dmg = 25
    pcall(function() dmg = actor.NPCData[ENUMS.NpcData.RangedDamage] or dmg end)

    AVU.FireProjectileRow(actor, GUN.Row, dmg, aim, GUN.GrenadeRow)
    LogDebug("Esoteric Chieftain - bio shot", SETTINGS.DEBUG_NPC_ACTIONS)

    -- Release the BT ranged task, delayed a beat so the pose stays planted through the attack
    Utils.QueueWork(function() AVU.ReleaseSoldierBT(actor) end, GUN.FireResetMs)
end


function H.RangedAttack(actor)
    if Utils.IsActorInvalid(actor) then return end
    Utils.QueueWork(function() fireBioShot(actor) end, GUN.FireDelayMs)
end


-- =======================================================================
-- DRINK TRIGGERS
-- =======================================================================

-- Shield-break poll (AVU.ShieldBreakPoll handles the disengage/disabled edge).
function H.ShieldBreakPoll(actor)
    local key = Utils.ActorKey(actor)
    if not key or (drank[key] and drank[key].shield) then return end
    if actor.IsDead or actor.IsDBNO then return end

    if AVU.ShieldBreakPoll(actor, shieldPrev, key) then
        drinkTincture(actor, "shield")   -- FLASK PHASE 2 (latched inside on success)
    end
end


-- Combat (first) tincture retry driver
--   * Re-attempts failed drink attempts - multiple things can cause this to fail
--   * Only tries up to MaxTries times so this doesn't get stuck trying forever
function H.TryCombatDrink(actor)
    if Utils.IsActorInvalid(actor) then return end
    local key = Utils.ActorKey(actor)
    if not key then return end
    if drank[key] and drank[key].combat then return end   -- already landed - done
    if actor.IsDead then return end

    local tries = combatTries[key] or 0
    if tries >= COMBAT_RETRY.MaxTries then
        drank[key] = drank[key] or {}
        drank[key].combat = true   -- give up: spend it so we stop retrying
        LogDebug("Esoteric Chieftain - combat tincture gave up after " .. tries .. " tries",
            SETTINGS.DEBUG_NPC_ACTIONS)
        return
    end

    local inCombat, dbno = false, false
    pcall(function() inCombat = actor.CombatState == true end)
    pcall(function() dbno = actor.IsDBNO == true end)
    if not inCombat then return end   -- disengaged; a fresh aggro re-arms via OnEnterCombat

    -- Busy or knocked down: wait and retry WITHOUT spending a try.
    if drinking[key] or dbno then
        Utils.QueueWork(function() H.TryCombatDrink(actor) end, COMBAT_RETRY.Ms)
        return
    end

    combatTries[key] = tries + 1
    drinkTincture(actor, "combat")
    -- Re-check after the drink would have finished; if it didn't spend, come back around.
    Utils.QueueWork(function() H.TryCombatDrink(actor) end, DRINK.Ms + COMBAT_RETRY.Ms)
end


-- =======================================================================
-- PHASING LOOK
-- =======================================================================

-- Fade the body via DitherOpacity, then hard-hide the gear. Renderer-local.
--   * Helm/backpack/squid/chest can't partial-fade.
function H.ApplyPhaseLook(actor)
    if Utils.IsActorInvalid(actor) then return end
    local mesh = Utils.GetValidMesh(actor)
    -- The body material uses DitherOpacity and ignores Opacity (0 = solid, 0.5 = invisible).
    if mesh then pcall(function() mesh:SetScalarParameterValueOnMaterials(FName("DitherOpacity"), 0.3) end) end
    pcall(function()
        if IsValid(actor.Helmet)   then actor.Helmet:SetVisibility(false, false) end
        if IsValid(actor.backpack) then actor.backpack:SetVisibility(false, false) end
    end)
    local key = Utils.ActorKey(actor)
    local squid = key and squidComps[key]
    if IsValid(squid) then pcall(function() squid:SetVisibility(false, false) end) end
    local chest = key and chestComps[key]
    if IsValid(chest) then pcall(function() chest:SetVisibility(false, false) end) end
end


-- =======================================================================
-- DEATH
-- =======================================================================

-- [OnDeath] Spawn a Magma Skink and hide its held weapon
--   * Location captured in case the body flies off
--     (the AggroBait lesson: never let deferred work re-deref the dying actor).
function H.ChieftainDeath(actor)
    local key = Utils.ActorKey(actor)

    local squid = key and squidComps[key]
    if squid then
        pcall(function() squid:SetVisibility(false, false) end)
        pcall(function() squid:K2_DestroyComponent(squid) end)
    end

    local deathLoc
    pcall(function()
        local l = actor:K2_GetActorLocation()
        deathLoc = FVector(l.X, l.Y, l.Z)
    end)
    if deathLoc then
        Utils.QueueWork(function()
            require("AnteCore.NpcSpawner").SpawnNpc(DEATH_SKINK.Row, deathLoc, { SkipSpawnFX = true })
            LogDebug("Esoteric Chieftain - death skink released", SETTINGS.DEBUG_NPC_ACTIONS)
        end, DEATH_SKINK.DelayMs)
    end

    if key then
        shieldPrev[key] = nil; drank[key] = nil
        drinking[key] = nil; chestComps[key] = nil; squidComps[key] = nil
        phased[key] = nil; combatTries[key] = nil
    end

    -- Undo the phasing look on the corpse: body back to solid, drop any attached tincture
    -- niagara, restore the helm/backpack.
    --   * Harmless no-ops if it never phased.
    --   * destroy=true pops the niagara components before the ragdoll despawns.
    pcall(function()
        local mesh = Utils.GetValidMesh(actor)
        if mesh then mesh:SetScalarParameterValueOnMaterials(FName("DitherOpacity"), 0) end
    end)
    AVU.EndAttachedNiagara(actor, true)
    pcall(function()
        if IsValid(actor.Helmet)   and actor.HasHelmet   == true then actor.Helmet:SetVisibility(true, false) end
        if IsValid(actor.backpack) and actor.HasBackpack == true then actor.backpack:SetVisibility(true, false) end
    end)
end

-- =======================================================================
-- PROVISIONER (the yellow supply Chieftain - def in GK_Chieftain.lua)
-- =======================================================================

-- Backpack: size it larger and give it a yellow tint 
--   * M_AbioticItems_Master underneath - DiffuseColor is the param that works on this 
--    ([[af-abioticitems-master-diffusecolor]]
local PROV_PACK = {
    Tint  = FVector(2.4, 2.0, 0.35),
    Scale = FVector(1.2, 1.2, 1.2),
}

-- [RENDERER] The look on top of the def.Tint body wash: bigger, brighter pack.
function H.ProvisionerGear(actor)
    if Utils.IsActorInvalid(actor) then return end
    pcall(function()
        local pack = actor.backpack
        if IsNotValid(pack) then return end
        AVU.TintSlot(pack, 0, { DiffuseColor = PROV_PACK.Tint })
        pack:SetRelativeScale3D(PROV_PACK.Scale)
    end)
end


-- =======================================================================
-- MELEE TEMPO + THE ALWAYS-ON SHIELD (shared by the Esoteric Chieftain and the Warchief)
--
-- A faster melee clip alone buys nothing but dead air: Broadcast_DoMeleeAttackFX sizes the BT's
-- release from the montage's RAW length, so the body stands there for whatever the speed-up saved.
-- That is what leaves a vanilla Chieftain parked for seconds after a grab it missed, and the
-- release valve below is the half that actually shortens the attack.
--
-- The rate stays modest because a LANDED grab keeps its own beats - 1.25s to the headbutt, then
-- 0.2s to the drop - and those are real-time delays that don't scale with the clip. Outrun them
-- and the animation is over while the victim is still held, which reads as dropping them early.
-- =======================================================================

local MELEE = {
    Rate = 1.5,
    -- Native contact times. The damage moment is a real-time delay the play rate does NOT scale,
    -- so each one is divided by the effective animation speed at write time.
    ApexNative      = 0.35,   -- MeleeHitApex - the grab and the ordinary swing
    PowerApexNative = 0.4,    -- PowerMeleeHitApex - the out-of-range lunge
    PadTicks        = 2,
    GrabFallback    = 2.5,    -- assumed clip length until AVU.MeleeReleaseTicks measures it
    SwingFallback   = 1.6,
}

-- Which clip the release valve has to measure, per melee type. The Chieftain's own picker only
-- ever lands on 6 (grab) and 1 (swing), plus 2 past melee range - and 2 has no montage on this
-- base, so it keeps the native timing.
local MELEE_CLIP = {
    [1] = ENUMS.Anims.GKCHIEF_MELEE,
    [6] = ENUMS.Anims.GKCHIEF_GRAB,
}

local meleeSwing    = {}   -- key -> { tick, kind } of the last melee attempt
local meleeReleased = {}   -- key -> the swing tick whose BT release has already been spent


-- CustomTimeDilation scales the whole animation timeline on top of the play rate, so the two
-- multiply into one effective speed - which is what both the apex and the release window divide by.
local function animSpeed(actor)
    local tdi
    pcall(function() tdi = tonumber(actor.CustomTimeDilation) end)
    if not tdi or tdi <= 0 then tdi = 1 end
    return MELEE.Rate * tdi
end


-- [AUTHORITY] Speed the melee up and move the contact times to match. Re-assert it after anything
-- that changes the body's time dilation.
function H.MeleeTempo(actor)
    if Utils.IsActorInvalid(actor) then return end
    local speed = animSpeed(actor)
    pcall(function()
        actor.MeleeAttackPlayRate = MELEE.Rate
        actor.MeleeHitApex        = MELEE.ApexNative / speed
        actor.PowerMeleeHitApex   = MELEE.PowerApexNative / speed
    end)
end


-- [HARD] The hardlight shell stays up out of combat, so a Chieftain that has not aggroed yet is
-- not a free hit. Used by the variants that don't hold it up at every difficulty.
function H.HardShieldStance(actor)
    if STATE.HardModeNoMercy then AVU.ShieldAlwaysOn(actor) end
end


-- [AUTHORITY, OnMeleeSwing] Stamp the attempt for the release valve. Keyed by ActorKey - this
-- hook hands back a fresh wrapper.
function H.MeleeSwing(actor)
    if not Utils.IsAuthority() or Utils.IsActorInvalid(actor) then return end
    local key = Utils.ActorKey(actor)
    if not key then return end

    -- An enum can come back as a wrapper instead of a number. One we can't read gets no early
    -- release - the native wait still ends the swing, it just ends it late.
    local kind
    pcall(function() kind = actor.LastMeleeAttackType end)
    if type(kind) ~= "number" then pcall(function() kind = kind:GetIntValue() end) end
    meleeSwing[key] = { tick = STATE.FAST_TICK, kind = (type(kind) == "number") and kind or nil }
end


-- [AUTHORITY, OnTick] Hand the BT its release once the sped-up clip has really finished.
-- Never while it is holding someone: the valve refuses to end a live grab, but it runs a
-- controller decision tick on the way in and the headbutt loop owns those beats.
function H.MeleeReleaseTick(actor)
    local key = AVU.CachedFullName(actor)   -- stable wrapper (OnTick): memo hit, skip GetFullName
    if not key then return end
    if actor.IsDead then
        meleeSwing[key], meleeReleased[key] = nil, nil
        return
    end

    local swung = meleeSwing[key]
    if not swung or meleeReleased[key] == swung.tick then return end

    local clip = MELEE_CLIP[swung.kind]
    if not clip then return end
    local wait = AVU.MeleeReleaseTicks(clip, animSpeed(actor), {
        Fallback = (swung.kind == 6) and MELEE.GrabFallback or MELEE.SwingFallback,
        Pad = MELEE.PadTicks,
    })
    if not wait or STATE.FAST_TICK - swung.tick < wait then return end

    local holding = false
    pcall(function() holding = IsValid(actor.HoldingCharacter) end)
    if holding then return end

    meleeReleased[key] = swung.tick
    AVU.ReleaseSoldierBT(actor)
end


-- =======================================================================
-- WARCHIEF (the hard-mode Chieftain - def in GK_Chieftain.lua)
-- Nothing here replaces a native move; each one rides the beat the native one already produces.
--   * MELEE   - the shared tempo above, plus its release valve.
--   * GRENADE - the single throw becomes three, on the Interfector's notify-free knife-throw clip.
--       Owning the montage is what suppresses the native frag: that one is spawned by the
--       GrenadeRelease notify on the Chieftain's own throw clip. Same trick, and the same beat
--       derivation, as the Grenadier Guard - AnNotes/AnteNPCs/OrderGrunt.md.
--   * SHIELD  - a heavier shell, up from the moment it spawns.
-- =======================================================================

local WAR = {
    Shield = 500,   -- native 350

    -- THE VOLLEY. Rel is pre-compensated for QueueWork's 100ms rounding and PROJ.SpawnGrenade's
    -- own one-tick defer, exactly like the Super Sapper's - don't change ThrowRate without
    -- re-deriving it. Raw beats at rate 1 are 0.15 / 0.275 / 0.5s.
    ThrowRate = 1,
    Rel       = { 100, 200, 400 },
    Damage    = 110,    -- the native throw bakes 250, and three of those is not a fight
    ArcDeg    = 32,
    Gravity   = 1,      -- MUST match the row's ProjectileGravityScale or the arc solve lies
    MaxSpeed  = 2500,   -- the row caps at 1500 and clamps SILENTLY
    Spread    = 220,    -- lateral fan (uu), so three frags cover ground instead of stacking
    Fuzz      = 90,
    Fan       = { -1, 0.35, 1 },
    GunTint   = FVector(9, 9, 0.3),   -- the one visible tell: a gold pistol
}
WAR.ThrowDeps = { ENUMS.Anims.INTERFECTOR_THROW_KNIVES, ENUMS.ProjectileClasses.GrenadeFrag }

H.WAR_ASSETS = {
    ENUMS.Anims.GKCHIEF_GRAB, ENUMS.Anims.GKCHIEF_MELEE,   -- measured for the release valve
    ENUMS.Anims.INTERFECTOR_THROW_KNIVES,
    ENUMS.ProjectileClasses.GrenadeFrag,
}


-- [AUTHORITY] Melee tempo, a heavier shell, and a shield that is up before the fight starts.
function H.WarLoadout(actor)
    H.MeleeTempo(actor)
    AVU.SetBodyShield(actor, { Max = WAR.Shield })
    AVU.ShieldAlwaysOn(actor)
end


function H.WarTick(actor)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    H.MeleeReleaseTick(actor)
end


-- Throwing hand, with an eye-height fallback for a body whose mesh isn't up yet.
local function warHandLoc(actor)
    local mesh = Utils.GetValidMesh(actor)
    if mesh then
        local ok, loc = pcall(function() return mesh:GetSocketLocation(FName("r_hand")) end)
        if ok and loc then return loc end
    end
    local l = actor:K2_GetActorLocation()
    return l and FVector(l.X, l.Y, l.Z + 150) or nil
end


-- ONE arc-solved frag of the volley. `index` picks its lane in the fan.
local function warLob(actor, index)
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return end
    local target = AVU.GetCurrentTarget(actor)
    if not target then return end

    local from = warHandLoc(actor)
    local tLoc = target:K2_GetActorLocation()
    if not from or not tLoc then return end

    -- Hand the held grenade off as the throw leaves, then re-arm it for the next lane. There is
    -- ONE hand slot, so show/hide must interleave exactly one per throw; the last lane leaves the
    -- hand empty, which is correct. Renderer-only, and local - a pure client sees empty hands.
    if Utils.HasRenderer() then
        pcall(function() actor:Local_SpawnGrenadeInHand(true) end)
        if index < #WAR.Rel then
            Utils.QueueWork(function()
                if Utils.IsActorValid(actor) then pcall(function() actor:Local_SpawnGrenadeInHand(false) end) end
            end, 0)
        end
    end

    -- Fan the landing points ACROSS the line of fire so the volley covers ground.
    local nx, ny = AVM.Normalize2D(tLoc.X - from.X, tLoc.Y - from.Y)
    local off = WAR.Spread * (WAR.Fan[index] or 0)
    local aim = Utils.FuzzLocation(FVector(tLoc.X - ny * off, tLoc.Y + nx * off, tLoc.Z), WAR.Fuzz)

    local speed = AVM.ArcSpeed(from, aim, WAR.ArcDeg, WAR.Gravity)
    local dir = AVM.ArcDir(from, aim, WAR.ArcDeg)
    PROJ.SpawnGrenade(actor, ENUMS.ProjectileClasses.GrenadeFrag, {
        Label = "Warchief volley",
        Location = from,
        AlignToVelocity = true,
        Velocity = FVector(dir.X * speed, dir.Y * speed, dir.Z * speed),
        Damage = WAR.Damage,
        Gravity = WAR.Gravity,
        MaxSpeed = WAR.MaxSpeed,
    })
end


-- [AUTHORITY, OnThrow] PRE: the native throw is starting. Take the montage slot off it and own
-- all three releases - see the header for why owning the clip is what suppresses the native frag.
--   * PlayMontageReplicated, not a local play: the point of borrowing an animation is that
--     clients see it too.
--   * The release beats are in real milliseconds, so this body has to stay at dilation 1 - give
--     the def a TimeDilation and the montage stretches out from under the schedule.
function H.WarThrow(actor)
    if not Utils.IsAuthority() or Utils.IsActorInvalid(actor) then return end
    -- No target, no takeover: the native single throw is the right fallback, not three misses.
    if not AVU.GetCurrentTarget(actor) then return end

    ASSETS.WarmPinned(WAR.ThrowDeps)
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        AVU.PlayMontageReplicated(actor, ENUMS.Anims.INTERFECTOR_THROW_KNIVES, WAR.ThrowRate, false)
        for i = 1, #WAR.Rel do
            Utils.QueueWork(function() warLob(actor, i) end, WAR.Rel[i])
        end
        LogDebug("Gatekeeper Warchief - triple grenade volley", SETTINGS.DEBUG_NPC_ACTIONS)
    end, 0)
end


-- [RENDERER] A gold pistol. The body wash stays faint, so the gun is what marks it out.
function H.WarchiefGear(actor)
    if Utils.IsActorInvalid(actor) then return end
    pcall(function()
        local gun = actor.Gun
        if IsNotValid(gun) then return end
        AVU.TintComponent(gun, { DiffuseColor = WAR.GunTint })
    end)
end

return H
