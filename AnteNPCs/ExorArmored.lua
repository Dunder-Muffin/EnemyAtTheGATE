-- =======================================================================
-- Armored Exor (row "Exor_Armored") - extends Exor (quill rifle, radiation zone). Adds Grenade
-- (Ability1) / projectile_exorgrenade, Teleport (Ability3), and a Roar (concussion cone).
--
-- Inherits the RadiationZone child component from Exor - every variant's Stats calls
-- AVU.ClearRadiationZone to avoid the damage-timer-in-a-crowd crash (see Exor.lua).
--
-- Variants (all suppress the native grenade, teleport and concussion roar):
--   * Exor Displacer  - EASY. Short bursts of fast, lightly-homing quills. No mid-burst blink;
--                       its only teleport is the swap-bomb (grenade at its feet, then trade places).
--   * Exor Repeller   - whole clip in one burst of SLOW carbuncle spikes, blinks twice mid-burst.
--   * Exor Dislocator - HYBRID: Repeller's clip-long blinking burst + Displacer's swap-bomb on reload.
--   * Winter Exor     - artillery. Short quill bursts; each reload walks a creeping barrage of
--                       frost shells out along the lane to its target.
--
-- ABILITY MAP - NPC_Monster_Exor_Armored (row "Exor_Armored")
--   0 Idle - none
--   1 GRENADE  - throws projectile_exorgrenade (250 dmg). Native CD 15s, self-cooldowns on use.
--               LoS-gated: only throws when the lane to the target is clear, or blocker is within 300uu.
--   2         - EMPTY. Nothing in the Exor chain overrides slot 2.
--   3 TELEPORT - hard blink to the target's location +100 Z (Broadcast_TeleportFX both ends).
--               NEVER calls SetAbilityOnCooldown - only the BT paces it.
-- NOT slots: the aggro ROAR (PerformAggroAnimation -> Debuff_Concussed, gated by MaxRoarDistance)
--   and the quill rifle (the ranged-attack path).
--
-- Machinery: AnteNPCs/ExorArmoredHelpers.lua
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local G = require("AnteData.Items").Global
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local H = require("AnteNPCs.ExorArmoredHelpers")
local PR = require("AnteCore.ProjectileRows")

-- Read at USE time, never cached - the flag is a world-load property and a def is shared.
local function byMode(t) return STATE.HardModeNoMercy and t.Hard or t.Normal end

local V = {}


-- =======================================================================
-- EXOR DISPLACER - drops a grenade at its feet and teleswaps with the target
--   * Fires faster quills (purple quillspear), but a short weaker burst
--   * Does not use its Concussion
-- =======================================================================

-- Burstfire mechanics. Gap BETWEEN shots in a burst is a hardcoded 0.25.
local DISPLACE_FIRE = {
    Burst = { Normal = 3,   Hard = 4 },     -- 5
    Ammo  = { Normal = 15,  Hard = 16 },    -- 20 - 5 bursts to a clip
    Gap   = { Normal = 1.0, Hard = 0.8 },   -- 2 (RangedAttack_Cooldown) - downtime between bursts
}

-- PURPLE quillspear round (projectile_exorspike_quillspear) in place of the native green quillrifle
local DISPLACE_PROJECTILE = ENUMS.ProjectileRows.QuillSpear

V["Exor Displacer"] = {
    Id = 71,
    Base = "Exor_Armored",
    -- Round + the blink FX Broadcast_TeleportFX spawns. The game FindObject's those, so a variant
    -- calling the multicast from the tick-hook drain must keep them resident.
    Assets = {
        ENUMS.ProjectileClasses.QuillSpear,
        ENUMS.Effects.EXOR_BLINK, ENUMS.Effects.EXOR_BEAM, ENUMS.Effects.EXOR_BLINK_SFX,
    },

    -- Appearance
    BodyScale = 0.9,
    Tint = { Color = FVector(0.4, 0.15, 0.7), EmissiveColor = FVector(0.6, 0, 1), Emissive = 60 },

    -- Stats
    BasicStats = {
        HpHead = 550, --650
        HpTorso = 500, --600
        WalkSpeed = 300, --200
        SprintSpeed = 500, --600
        MeleeDamage = 75, --50
        RangedDamage = 50, --25
    },
    HardMode = {
        BasicStats = { HpHead = 600, HpTorso = 600, MeleeDamage = 100, RangedDamage = 70 },
        TimeDilation = 1.1,
    },
    Stats = function(actor, opts)
        pcall(function() actor.MaxBurstFire = byMode(DISPLACE_FIRE.Burst) end)
        pcall(function() actor.MaxAmmoCount = byMode(DISPLACE_FIRE.Ammo) end)
        pcall(function() actor.CurrentAmmoCount = actor.MaxAmmoCount end)
        pcall(function() actor.RangedAttack_Cooldown = byMode(DISPLACE_FIRE.Gap) end)
        pcall(function() actor.MaxRoarDistance = 0 end)   -- disable the concussion

        -- Fast, lightly-homing quill (native FireRanged_Projectile reads this row).
        AVU.SetProjectileRow(actor, "ExorProjectile", DISPLACE_PROJECTILE)
        AVU.ClearRadiationZone(actor)
    end,

    -- Triggers
    OnTick = H.DisplacerTick,

    OnGibbed = function(actor)
        AVU.DropLoot(actor, {
            { Row = G.POWDERED_CRYSTAL, Amount = 2, Radius = 90 },
            { Row = G.CARAPACE, Amount = 2, Radius = 90 },
            { Row = G.DISTILLATION_UNNERVING, Amount = 4, Radius = 90 },
        })
    end,
}


-- =======================================================================
-- EXOR REPELLER
--   * Fires a large burst of shots, blinking while attacking
--   * Slower, higher damage shots
--   * Disable melee, grenade, and concussion so it focuses on firing
--   * 'projectile_carbunclespike'
-- =======================================================================

local REPEL_BURST = 18   -- 5
local REPEL_AMMO  = 18   -- 15
local REPEL_PROJECTILE = ENUMS.ProjectileRows.CarbuncleSpike   -- 800 velocity, non-homing

V["Exor Repeller"] = {
    Id = 74,
    Base = "Exor_Armored",
    Assets = {
        ENUMS.ProjectileClasses.CarbuncleSpike,
        ENUMS.Effects.EXOR_BLINK, ENUMS.Effects.EXOR_BEAM, ENUMS.Effects.EXOR_BLINK_SFX,
    },

    -- Appearance
    BodyScale = 1.1,
    Tint = { Color = FVector(0.3, 0.5, 1), EmissiveColor = FVector(0.4, 0.1, 0.7), Emissive = 200 },

    -- Stats
    BasicStats = {
        HpHead = 500, --650
        HpTorso = 500, --600
        -- WalkSpeed = 200,
        -- SprintSpeed = 600,
        MeleeDamage = 75,
        RangedDamage = 60, --25
        MeleeAttackRange = 1,   -- never melee: it's a blink-and-shoot skirmisher (+ AVU.SuppressMelee)
    },
    HardMode = { TimeDilation = 1.4, BasicStats = { HpHead = 550, HpTorso = 550, RangedDamage = 80 } },
    TimeDilation = 1.3,
    Stats = function(actor, opts)
        pcall(function() actor.MaxBurstFire = REPEL_BURST end)
        pcall(function() actor.MaxAmmoCount = REPEL_AMMO end)
        pcall(function() actor.CurrentAmmoCount = actor.MaxAmmoCount end)
        pcall(function() actor.MaxRoarDistance = 0 end)

        -- Every shot becomes the slow carbuncle spike.
        AVU.SetProjectileRow(actor, "ExorProjectile", REPEL_PROJECTILE)
        AVU.ClearRadiationZone(actor)
    end,

    -- Triggers
    OnTick = H.RepellerTick,

    OnGibbed = function(actor)
        AVU.DropLoot(actor, { Pool = {
            { G.QUILL, 4 },
            { G.CARAPACE, 2 },
        } })
    end,
}


-- =======================================================================
-- EXOR DISLOCATOR - Hybrid
--   * Attacks like the Exor Repeller: ONE burst = the WHOLE clip, blinking twice mid-burst
--   * Teleswap grenades like the Exor Displacer when reloading
-- =======================================================================

local DISLOC_BURST = 16   -- shots per burst (default 5) 
local DISLOC_AMMO  = 16
local DISLOC_COOLDOWN = 0.4 -- low downtime between bursts in case it doesn't empty its clip

-- The purple spear on our own row: slower (1000), a gentler homing and a touch bigger (numbers in
-- AnteCore/ProjectileRows). The stock spear is the fallback if the row didn't build this world.
local DISLOC_PROJECTILE = ENUMS.ProjectileRows.DislocatorSpear
local DISLOC_PROJECTILE_FALLBACK = ENUMS.ProjectileRows.QuillSpear

V["Exor Dislocator"] = {
    Id = 94,
    Base = "Exor_Armored",
    Assets = {
        ENUMS.ProjectileClasses.QuillSpear,
        ENUMS.Effects.EXOR_BLINK, ENUMS.Effects.EXOR_BEAM, ENUMS.Effects.EXOR_BLINK_SFX,
    },

    -- Appearance
    BodyScale = 1.0,
    Tint = { Color = FVector(0.6, 0.3, 0.3), EmissiveColor = FVector(0.8, 0.1, 0.3), Emissive = 100 },

    -- Stats
    BasicStats = {
        HpHead = 500, --650
        -- HpTorso = 600,
        -- WalkSpeed = 200,
        -- SprintSpeed = 600,
        MeleeDamage = 100,
        RangedDamage = 55,
        MeleeAttackRange = 1,
    },
    HardMode = {
        BasicStats = { HpHead = 600, HpTorso = 700, MeleeDamage = 125, RangedDamage=65 },
        TimeDilation = 1.4,
    },
    TimeDilation = 1.3,
    Stats = function(actor, opts)
        pcall(function() actor.MaxBurstFire = DISLOC_BURST end)
        pcall(function() actor.MaxAmmoCount = DISLOC_AMMO end)
        pcall(function() actor.CurrentAmmoCount = actor.MaxAmmoCount end)
        pcall(function() actor.RangedAttack_Cooldown = DISLOC_COOLDOWN end)
        pcall(function() actor.MaxRoarDistance = 0 end)   -- no concussion roar

        -- Purple quillspear (native FireRanged_Projectile reads this row at fire time).
        AVU.SetProjectileRow(actor, "ExorProjectile",
            PR.Ready(DISLOC_PROJECTILE) and DISLOC_PROJECTILE or DISLOC_PROJECTILE_FALLBACK)
        AVU.ClearRadiationZone(actor)
    end,

    -- Triggers
    OnTick = H.DislocatorTick,
    OnReload = H.DislocatorReload,

    OnGibbed = function(actor)
        AVU.DropLoot(actor, { Pool = {
            { G.QUILL, 4 },
            { G.CARAPACE, 3 },
            { G.POWDERED_CRYSTAL, 2 },
        } })
    end,
}


-- =======================================================================
-- WINTER EXOR
--   * Its RANGED ATTACK is the Snowman's creeping barrage: a wave of lobbed frost shells that
--     walks out along the lane to its target, sweeping THROUGH wherever you stand
--   * The native quill is suppressed entirely - the barrage IS the primary attack
--   * Each shell is a cold AoE that freezes; the sweep is dodged sideways, never backwards
--   * Cold-proof: no cold damage, no frost debuffs
-- =======================================================================

-- FIRE RATE - ammo/reload do not work when suppressing a native attack: invalidating a projectile
-- row also suppresses everything downstream of the spawn (ammo, whatever the OnLoaded chain drives).
local WINTER_FIRE = { Burst = 1, Ammo = 1, Cooldown = 3 }   -- Cooldown MUST stay above Freeze + windup

-- BEATS = shots in the cone. WindupMs/Step telegraph the sweep so it reads as dodgeable.
local WINTER_CONE = {
    Reach = 1800,
    Beats = 4,
    Radius = 300,       -- overlaps at this reach/beat count, so the sweep has no gaps
    Damage = 70,         -- per beat; standing in the lane eats more than one
    DamageHard = 90,
    Step = 300,
    Windup = 700,        -- telegraph: how long you have to move
    FreezeSecs = 1.5,
    Muzzle = "r_arm2_end",   -- origin for the telegraph puff + the cone's line
}

V["Winter Exor"] = {
    Id = 152,
    Base = "Exor_Armored",
    Assets = AVU.FROST_CONE_DEPS,   -- must be warm BEFORE the first shot, not loaded on it

    -- Appearance
    BodyScale = 1.1,
    Tint = { Color = FVector(5, 5, 10), EmissiveColor = FVector(0.3, 0, 3), Emissive = 70 },

    -- Stats
    BasicStats = {
        HpHead = 650,   -- 650
        HpTorso = 600,   -- 600
        -- WalkSpeed = 200,
        SprintSpeed = 450,   -- 600
        MeleeDamage = 150, -- 50
        -- RangedDamage = 50,   -- 25
    },
    HardMode = {        
        BasicStats = { HpHead=750, HpTorso=700, MeleeDamage=175 },
    },
    DebuffsImmune = { ENUMS.Debuffs.Frost, ENUMS.Debuffs.Frost2, ENUMS.Debuffs.Frost3,
                      ENUMS.Debuffs.Frost4, ENUMS.Debuffs.Frost5, ENUMS.Debuffs.FlaskBlizzard },
    Stats = function(actor, opts)
        pcall(function() actor.MaxBurstFire = WINTER_FIRE.Burst end)
        pcall(function() actor.MaxAmmoCount = WINTER_FIRE.Ammo end)
        pcall(function() actor.CurrentAmmoCount = actor.MaxAmmoCount end)
        pcall(function() actor.RangedAttack_Cooldown = WINTER_FIRE.Cooldown end)
        pcall(function() actor.MaxRoarDistance = 0 end)   -- no concussion roar

        AVU.SetProjectileRow(actor, "ExorProjectile", "None")   -- suppress the native quill; the cone is the attack

        -- def.Assets alone does not hold these against GC - re-pin right before the first cone,
        -- since the cone Niagara is referenced nowhere else.
        AVU.WarmFrostCone()
        AVU.ClearRadiationZone(actor)
    end,

    -- Triggers
    -- THE PRIMARY ATTACK. Dispatched from the Exor's own Server_DoRangedAttack, so the cone lands
    -- on the fire montage instead of riding some side channel. QueueWork, not inline: the handler
    -- runs inside that hook. 
    OnRangedAttack = function(actor)
        Utils.QueueWork(function()
            if Utils.IsActorInvalid(actor) or actor.IsDead then return end
            AVU.FrostCone(actor, {
                Reach      = WINTER_CONE.Reach,
                Beats      = WINTER_CONE.Beats,
                Radius     = WINTER_CONE.Radius,
                Damage     = STATE.HardModeNoMercy and WINTER_CONE.DamageHard or WINTER_CONE.Damage,
                StepMs     = WINTER_CONE.Step,
                FreezeSecs = WINTER_CONE.FreezeSecs,
                WindupMs   = WINTER_CONE.Windup,
                Socket     = WINTER_CONE.Muzzle,
                -- Also hits NPC enemies (Order skirmishes) via BlastDamage's safe path: followers
                -- excluded, lethal-range NPCs skipped, PointDamageOffHook used. Freeze stays
                -- players-only (a frozen NPC is blind).
                HitNpcs    = true,
            })
        end, 150)
    end,

    OnTick = H.WinterTick,

    OnGibbed = function(actor)
        AVU.DropLoot(actor, { Row = G.FROZEN_ESSENCE, Amount = 1, MinStory = 91 })
    end,
}

return V
