-- =======================================================================
-- JOTUN - NPC_Gatekeeper_Heavy
--   * The mounted pair is TWO defs: "Jotun Steed" (the mount we mutate) welds a raw
--     Gatekeeper_Heavy in OnReady and mutates THAT into "Jotun Rider"
--   * A rider spawned directly is a stationary turret - pin + arc gate no-op without a mount
--   * "Dismounted Jotun" replaces the rider when the steed dies under it, carrying its HP over
--   * The LMG hitscans and aims regardless of yaw, so facing won't suppress it - the arc gate is
--     in the helpers. Shield 300 HP, enrages at 30%
--   Machinery: AnteNPCs/GK_HeavyHelpers.lua
-- =======================================================================
-- ABILITY MAP - NPC_Gatekeeper_Heavy
--   0 Banner speech (BannerSpeech=true) - Cloud Reactor Jotun only
--   1 Grenade - the Order throw, re-armed by the Heavy as a CLUSTER grenade (20s cd). Disabled here
--   2, 3 - empty
--   * NOT a slot: the LMG is the ranged path (30-shot burst @0.15s, MaxAmmoCount 50)
--   * STEED (Peccary) map lives in AnteNPCs/Peccary.lua: 0 = plant carbuncle, 1 = charge
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local G = require("AnteData.Items").Global
local H = require("AnteNPCs.GK_HeavyHelpers")

local V = {}

-- Read at USE time, never cached: the flag is a world-load property and a def is shared.
local function byMode(t) return STATE.HardModeNoMercy and t.Hard or t.Normal end


-- =======================================================================
-- JOTUN STEED  (the mount)
-- * An armoured peccary carrying a Jotun, welded on at spawn
-- * Keeps its charge, but COMMITS to the line - no mid-charge steering, longer and faster runs
-- * ...and OVERRUNS it: every charge ends in a 2.5s stun that freezes its yaw, so the arc gate
--     shuts the rider's LMG for anyone standing behind it (H.SteedTick)
-- * Runtime body shield + a peccary-shaped energy shell
-- =======================================================================

V["Jotun Steed"] = {
    Id = 83,
    Base = "Peccary",
    AltBases = { "Peccary_Armored" },
    Assets = H.STEED_ASSETS,   -- the rider class, shield component + shell, mask, lightning

    -- Appearance
    BodyScale = FVector(1.3, 1.2, 1.3),
    -- Shrink the nav radius to prevent getting stuck on stuff
    NavRadius = AVU.NATIVE_NAV_RADIUS.Peccary,
    Tint = {
        Color = FVector(0.1, 0.1, 0.1),
        EmissiveColor = FVector(1.5, 0, 2),
        Emissive = 120,
    },
    Visuals = H.SteedLook,

    -- Stats
    BasicStats = {
        HpHead = 100,    -- 80
        HpTorso = 200,   -- 80
        -- WalkSpeed = 200,
        SprintSpeed = 300,   -- 900 
        MeleeDamage = 110, --50
        -- RangedDamage = 15,
        -- Shield = 400 (hard 500)
    },
    -- Shield, yaw rate and walking acceleration harden alongside these in the helpers.
    HardMode = {
        BasicStats = { SprintSpeed = 400, MeleeDamage = 150 },
    },
    -- Peccary ships on the A2-pest team; declared HERE so the pipeline's faction step lands BEFORE
    --   OnReady's weld - otherwise nearby Gatekeepers shot the mount for the ~1s weld window.
    Faction = 6,   -- Gatekeepers/Robots; the weld re-copies the live rider.Faction as the confirm
    Stats = H.SteedLoadout,

    -- Triggers
    OnReady = H.SteedReady,               -- weld the rider + the body shield
    OnEnterCombat = H.SteedEnterCombat,   -- share aggro with the rider
    OnTick = H.SteedTick,                 -- charge accel while it runs, the stun when it stops

    -- Closes the weakness-forced stagger SetStaggerImmune (SteedLoadout) can't block alone.
    OnDamageTaken = function(actor)
        AVU.ClearWeaknessStagger(actor)
    end,

    OnDeath = function(actor)
        H.SteedDeath(actor)   -- summons the Dismounted Jotun if the rider was still alive

        AVU.DropLoot(actor, {
            { Pool = {
                { G.CPU_REINFORCED },
                { G.CPU_CORRUPT, 1, MinStory = 73 },
            }, Count = 1, Radius = 100 },
            { Pool = {
                { G.RES_GROWTH, 1 },
                { G.MILITARY_ELEC, 4 },
                { G.MAGNETIC_ALLOY, 2 },
            }, Radius = 25 },
        })
    end,
}


-- =======================================================================
-- GATEKEEPER PECCARY  (summoned from Beholder Mage)
-- * Normal Peccary with a hardlight shield
-- =======================================================================

V["Gatekeeper Peccary"] = {
    Id = 23,
    Base = "Peccary",
    AltBases = { "Peccary_Armored" },
    Assets = H.STEED_ASSETS,   -- shares the steed's dressing; the rider class rides along unused

    -- Appearance
    BodyScale = 1.15,
    NavRadius = AVU.NATIVE_NAV_RADIUS.Peccary,
    Tint = {
        Color = FVector(0.1, 0.1, 0.1),
        EmissiveColor = FVector(1.5, 0, 2),
        Emissive = 120,
    },
    Visuals = H.GkPeccaryLook,

    -- Stats
    BasicStats = {
        HpHead = 100,   -- 80
        HpTorso = 100,   -- 80
        -- WalkSpeed = 200,
        SprintSpeed = 600,   -- 900
        MeleeDamage = 60,   -- 50
        -- RangedDamage = 15,
        -- Shield = 100
    },
    Faction = 6,
    Stats = H.GkPeccaryLoadout,

    -- A constant summon, so it pays out nothing (the loadout strips the native drop).
    --   * Stripping loot also skips the native corpse fade, and a script-spawned body has no
    --     spawner to despawn it - so the corpse is ours to remove. It dies and lies there like
    --     any peccary first (still harvestable), and is cleared after the linger.
    OnDeath = function(actor)
        AVU.HideOnDeath(actor, 15000)
    end,
}


-- =======================================================================
-- JOTUN RIDER  (welded to the steed - not meant to be spawner-picked)
-- * A saddle turret: it can't move, so its aim, firing arc and weld are all driven from the tick
-- * Only fires within 120 deg of the mount's facing
-- * Dying in the saddle detaches the corpse and blocks the dismount
-- =======================================================================

local RIDER_GRENADES = false

-- MAGAZINE, both riders. 30 matches the LMG burst (GruntBurstCount 30 @ 0.15s), so one clip is one
-- burst (~4.5s suppression), then a 5.4s reload - a window to close, flank or heal each cycle.
-- Shared with the Dismounted Jotun so phase 2 keeps the same rhythm.
local RIDER_AMMO = 30   -- 50

V["Jotun Rider"] = {
    Id = 84,
    Base = "Gatekeeper_Heavy",

    -- Appearance
    BodyScale = 0.95,
    -- [RENDERER] Shield color, MP client-proxy calm, and the stagger-blank half (forced staggers
    -- still multicast on this acid/holy-weak base).
    Visuals = function(actor)
        AVU.SetShieldColor(actor, { Color = H.RIDER_SHIELD_COLOR })
        H.CalmClientProxy(actor)
        AVU.SkipStaggerAnim(actor)
    end,

    -- Stats
    BasicStats = {
        HpHead = H.RIDER_HP,    -- 550
        HpTorso = H.RIDER_HP,   -- 550
        -- WalkSpeed = 200,
        -- SprintSpeed = 330,
        -- MeleeDamage = 50,
        -- RangedDamage = 35,
        -- Shield = 800
    },
    HardMode = {
        BasicStats = { HpHead = H.RIDER_HP_HARD, HpTorso = H.RIDER_HP_HARD, RangedDamage = 40 },
    },
    -- The hard reload retime rides CustomTimeDilation, which is server-local without this.
    MirrorTimeDilation = true,
    Stats = function(actor)
        pcall(function() actor.MaxAmmoCount = RIDER_AMMO; actor.CurrentAmmoCount = RIDER_AMMO end)
        if not RIDER_GRENADES then AVU.DisableGrenades(actor) end
        -- A saddle turret that stumbles is a broken weld (same acid/holy stagger fix as SteedLoadout).
        AVU.SetStaggerImmune(actor)
    end,

    -- Triggers
    OnEnterCombat = H.RiderEnterCombat,   -- drags the mount into the fight too

    -- [HARD] The window to close on a saddle turret is its reload; shorten it. Authority only -
    -- Broadcast_ReloadWeapon is a multicast, and a client that retimed for itself would then fight
    -- the MirrorTimeDilation tick reading the server's value back.
    OnReload = function(actor)
        if not STATE.HardModeNoMercy or not Utils.IsAuthority() then return end
        AVU.ReloadDilation(actor, H.RIDER_HARD_RELOAD)
    end,

    OnTick = H.RiderTick,                 -- aim + arc gate + pin/weld self-heal + HP snapshot

    OnDeath = function(actor)
        H.RiderDeath(actor)

        AVU.DropLoot(actor, {
            { Pool = {
                { G.TRANSCENDIUM, 2 },
                { G.MILITARY_ELEC, 6 },
            } },
        })
    end,
}


-- =======================================================================
-- DISMOUNTED JOTUN  (the replacement when the steed dies first)
-- * A plain walking Jotun, spawned with whatever HP the rider had left
-- =======================================================================

V["Dismounted Jotun"] = {
    Id = 85,
    Base = "Gatekeeper_Heavy",

    -- Appearance
    BodyScale = 0.95,
    Visuals = function(actor, assets)
        AVU.SetShieldColor(actor, { Color = H.RIDER_SHIELD_COLOR })
        AVU.SkipStaggerAnim(actor)   -- renderer half; Stats has the authority half
    end,

    -- Stats
    BasicStats = {
        HpHead = H.RIDER_HP,    -- 550
        HpTorso = H.RIDER_HP,   -- 550
        -- WalkSpeed = 200,
        -- SprintSpeed = 330,
        -- MeleeDamage = 50,
        -- RangedDamage = 35,
        -- Shield = 800
    },
    -- Matched to the Jotun Rider: this IS that body, so a hard rider must not shrink on dismount.
    HardMode = {
        BasicStats = { HpHead = H.RIDER_HP_HARD, HpTorso = H.RIDER_HP_HARD, RangedDamage = 40 },
    },
    -- opts.CarryHpFrac (from the steed's death) scales the pools down to what the rider had left.
    -- Runs AFTER BasicStats, so this is the final word.
    Stats = function(actor, opts)
        pcall(function() actor.MaxAmmoCount = RIDER_AMMO; actor.CurrentAmmoCount = RIDER_AMMO end)

        -- Same no-knockaround rule as the rest of the Jotun family (see SteedLoadout).
        AVU.SetStaggerImmune(actor)

        local frac = opts and opts.CarryHpFrac
        if frac and frac < 1 then
            local pool = byMode({ Normal = H.RIDER_HP, Hard = H.RIDER_HP_HARD })
            AVU.SetLimbHealth(actor, {
                Head = math.max(60, math.floor(pool * frac)),
                Torso = math.max(60, math.floor(pool * frac)),
            })
        end
    end,

    -- Triggers
    -- No cleanup here - it keeps no per-actor state. (A copy-pasted Rocketeer cleanup once resolved
    --   to nil globals and threw, killing the whole OnDeath, so loot never dropped.)
    OnDeath = function(actor)
        AVU.DropLoot(actor, {
            { Pool = {
                { G.TRANSCENDIUM, 2 },
                { G.MILITARY_ELEC, 6 },
            } },
        })
    end,
}


-- =======================================================================
-- JOTUN ROCKETEER
-- * Artillery, not a bruiser: squishier, with a mortar volley every ~10s at range ([HARD] ~7s,
--     and the shells hit half again as hard)
-- * LMG replaced by SMG fireballs on a flat cadence - the magazine IS the burst, the sped-up
--     reload (2x, [HARD] 2.5x) is the real pacing
-- * Rocket pack on its back; the LMG's fire cue is reskinned to match the new gun
-- =======================================================================

-- ProjectileFireSocket defaults to "head" on NPC_Base - repoint it at the weapon socket.
local BOMBARD_FIRE_SOCKET = "r_weapon_ranged1"

-- MAGAZINE. FireRanged_Projectile ends in ConsumeAmmo, so our bolts DO burn the clip: the whole clip
-- goes out in ~2s, then the BT reloads (a skipped reload would just keep firing on empty - no stall).
--   * TUNING: the magazine is the whole damage budget (clip x RangedDamage in ~2s, plus each
--     fireball's AoE and ignite). Cut the damage, not the cadence, if it reads as too lethal.
local BOMBARD_AMMO = { Normal = 10, Hard = 15 }   -- 50

-- LMG fallback (inert under OverrideSoldierFireLogic). CurrentReloadDuration is deliberately NOT set
-- - a player field the NPC reload path never reads, so it would look like a knob that does nothing.
local BOMBARD_BURST_COUNT, BOMBARD_BURST_GAP = 12, 0.25

local BOMBARD_BODYSHIELD = { Normal = 300, Hard = 450 }   -- 800
local BOMBARD_DISABLE_NATIVE_GRENADE = true
local BOMBARD_RELOAD_TDI = { Normal = 2.0, Hard = 2.5 }   -- 1.0; dropped again the moment the clip refills

V["Jotun Rocketeer"] = {
    Id = 129,
    Base = "Gatekeeper_Heavy",
    Assets = H.ROCKETEER_ASSETS,   -- mortar deps, rocket pack + material, fireball class + cue

    -- Appearance
    BodyScale = 0.95,
    Tint = { Color = FVector(4, 0.4, 0.6), EmissiveColor = FVector(0, 1, 2), Emissive = 25 },
    Visuals = function(actor)
        H.AttachRocketPack(actor)
        H.ReskinLmgFx(actor)
        AVU.SkipStaggerAnim(actor)   -- renderer half; Stats has the authority half
    end,

    -- Stats
    BasicStats = {
        HpHead = 400,    -- 550
        HpTorso = 400,   -- 550
        RangedDamage = 60,   -- per bolt (FireRanged_Projectile's DamageFromWeapon)
        -- Shield = 250 (hard 400)   -- 800
    },
    -- Magazine, shield and the mortar (damage + cadence) harden alongside these.
    HardMode = {
        BasicStats = { HpHead = 500, HpTorso = 500, RangedDamage = 80 },
    },
    MirrorTimeDilation = true,   -- reload speed-up rides CustomTimeDilation (server-local) - mirror it
    Stats = function(actor)
        -- Suppress the LMG; fire H.BOMBARD_GUN_ROW via OnRangedAttack instead.
        pcall(function() actor.OverrideSoldierFireLogic = true end)
        local ammo = byMode(BOMBARD_AMMO)
        pcall(function() actor.MaxAmmoCount = ammo; actor.CurrentAmmoCount = ammo end)
        pcall(function() actor.ProjectileFireSocket = FName(BOMBARD_FIRE_SOCKET) end)   -- not "head"
        AVU.SetProjectileRow(actor, "GrenadeData", H.BOMBARD_GUN_ROW, true)   -- borrowed row handle

        pcall(function() actor.GruntBurstCount = BOMBARD_BURST_COUNT end)   -- LMG fallback, inert
        pcall(function() actor.GruntBurstTimeBetweenShots = BOMBARD_BURST_GAP end)

        AVU.SetBodyShield(actor, { Max = byMode(BOMBARD_BODYSHIELD) })
        if BOMBARD_DISABLE_NATIVE_GRENADE then AVU.DisableGrenades(actor) end

        -- Same no-knockaround rule as the rest of the Jotun family (see SteedLoadout).
        AVU.SetStaggerImmune(actor)
    end,

    -- Triggers
    OnRangedAttack = H.RocketeerRangedAttack,   -- the bolt, in place of the suppressed LMG

    -- Speed the reload by running the whole actor fast (mirrored to clients); the tick's
    -- holdReloadDilation puts it back the moment the clip refills.
    OnReload = function(actor)
        if Utils.IsActorInvalid(actor) then return end
        local key = Utils.ActorKey(actor)
        if not key then return end
        H.ReloadStart[key] = STATE.FAST_TICK
        AVU.SetTimeDilation(actor, byMode(BOMBARD_RELOAD_TDI))
    end,

    OnTick = H.RocketeerTick,                   -- mortar loop + the fire/reload gates

    OnDeath = function(actor)
        H.RocketeerCleanup(actor)

        AVU.DropLoot(actor, {
            { Pool = { { G.AMMO_ROCKET, 1 } }, Chance = 0.25 },
            { Pool = { { G.FRAG_GRENADE, 1 } }, Chance = 0.25 },
            { Pool = {
                { G.DETONATION_CORD, 1 },
                { G.GUNPOWDER, 3 },
                { G.METAL_SCRAP, 6 },
            }, Count = 2 },
        })
    end,
}

return V
