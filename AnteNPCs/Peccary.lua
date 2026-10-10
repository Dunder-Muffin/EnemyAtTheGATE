-- =======================================================================
-- Peccary (NPC_Monster_Peccary) variants, including Sows/Alphas
-- 
-- =======================================================================
-- ABILITY MAP - (Armored/Electro/Volatile/Sow) inherits these
-- 
--   0 PLANT_CARBUNCLE (Idle) - (150s) spawns Carbuncle, one per 10m radius
--   1 CHARGE - (12s) WalkSpeed 4500, StampedeDuration 4s, (EndChargeWithExplosion)
--       TurnWhileStampeding in apoc lets it steer
--   2-3 - EMPTY
--
-- Note: Peccary_Armored base does not charge
--
-- Machinery: AnteNPCs/PeccaryHelpers.lua (H.QuickCharge - the scripted charge start beat).
-- Deep: AnNotes/AnteNPCs/Peccary.md - the charge decode (why the WINDUP can't be shortened by a property,
-- and what we do about it), the Phase fade's server clock, and the Carbunccary vs Sneaking-8
-- finding.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local ENUMS = require("AnteData.Enums")
local G = require("AnteData.Items").Global
local STATE = require("AnteCore.State")
local ASSETS = require("AnteCore.AssetManager")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local AVM = require("AnteUtils.AVMath")
local StoryManager = require("ModuleStory.StoryManager")
local H = require("AnteNPCs.PeccaryHelpers")

-- NOTE: the Hive Sow variant lives in AnteNPCs/PeccarySow.lua.

local V = {}

local ABILITY_PLANT_CARBUNCLE = 0
local ABILITY_CHARGE          = 1


-- =======================================================================
-- CHARGE PECCARY [Tameable]
-- A head-heavy tank that trades reach and speed for a near-permanent charge.
--   * Tankier head, much slower; softer melee (35) and charge blast (100) than base
--   * Very short charge with almost no charge cooldown, and it CANNOT STEER it (see Stats)
--   * SCRIPTED CHARGE START (H.ChargePeccaryCharge): a ~1s telegraph instead of the native full
--     montage, and the run accelerates harder. Delete the OnCharge line to go back to stock
--   * HARD TO INTERRUPT - stagger-immune, weakness hits included, so only a Stopping Power crit
--     still cancels a charge mid-run (see Stats)
--   * Net/shock/FEAR immune; trails a lightning effect
--   * The Jager one spawns weaker (first Peccary)
--   * [HARD] - tankier, hits harder, a shorter telegraph, a faster run, a wider/heavier blast,
--     and the blast STUNS
-- =======================================================================

-- Charge plays a Timeline_Emissive that overwrites the body emissive, so OnTick re-applies it.
local CHARGE_BODY_COLOR   = FVector(0.3, 0.3, 3)
local CHARGE_EMISSIVE     = FVector(0, 1, 1)
local CHARGE_EMISSIVE_INT  = 200
local CHARGE_NAV_RADIUS = 42 -- Shrink collision a bit

-- Stun on charge
local CHARGE_STUN_SEC = 1

-- The body glow the charge overwrites: the windup rebuilds the material, the stampede's end resets
-- EmissiveIntensity. A renderer-side write; a no-op on a dedicated server's mesh.
local function chargeGlow(actor)
    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return end
    mesh:SetVectorParameterValueOnMaterials(FName("EmissiveColor"), CHARGE_EMISSIVE)
    mesh:SetScalarParameterValueOnMaterials(FName("EmissiveIntensity"), CHARGE_EMISSIVE_INT)
end

V["Charge Peccary"] = {
    Id = 5,
    Base = "Peccary",
    -- PECCARY_CHARGE_START is MEASURED, not played, by H.QuickCharge - it only has to be resident
    -- for the length read, and a cold read there just falls back to the native windup.
    Assets = { ENUMS.Effects.LIGHTNING_STUN, ENUMS.Effects.TINCTURE_ELECTRIC_BURST,
               ENUMS.BuffObjects.Stunned, ENUMS.Anims.PECCARY_CHARGE_START },
    TamedVariant = "Tamed Charge Peccary",

    -- Appearance
    BodyScale = { X = 0.95, Y = 1.1, Z = 1.1 },
    NavRadius = CHARGE_NAV_RADIUS,   -- authority + every client mirror it (see the knob)
    Tint = { Color = CHARGE_BODY_COLOR, EmissiveColor = CHARGE_EMISSIVE, Emissive = CHARGE_EMISSIVE_INT },
    Visuals = function(actor, assets)

        -- The RENDERER half of the stagger lid (Stats owns the mechanics). A forced stagger still
        -- multicasts, so without this a remote client plays a stumble the server never took.
        AVU.SkipStaggerAnim(actor)

        -- Charge blast -> the electric tincture burst, matching the body tint. Every renderer sets
        -- it: the blast FX is spawned locally at impact off this member, so an authority-only set
        -- would leave remote clients on the native purple.
        local burst = ASSETS.GetIfValid(ENUMS.Effects.TINCTURE_ELECTRIC_BURST)
        if IsValid(burst) then
            pcall(function() actor.ChargeBlastImpactParticle = burst end)
        end

        if not SETTINGS.GAMEPLAY.REDUCE_VISUALS then
            AVU.AttachNiagara(actor, ENUMS.Effects.LIGHTNING_STUN, "hips", { Scale = FVector(0.7, 0.7, 0.7) })
        end
    end,

    -- Stats
    BasicStats = {
        HpHead = 180,   -- 80
        HpTorso = 40,   -- 80
        -- WalkSpeed = 200,
        SprintSpeed = 250,   -- 900
        MeleeDamage = 40,   -- 50
        -- RangedDamage = 15,
    },
    -- Fear immune: a routed peccary still charges, it just charges AWAY.
    DebuffsImmune = { ENUMS.Debuffs.Netted, ENUMS.Debuffs.ShockTrap, ENUMS.Debuffs.Zapped,
                      ENUMS.Debuffs.ZappedPurple, ENUMS.Debuffs.Fear },
    TimeDilation = 1.2,
    
    -- Hard stats
    HardMode = {
        BasicStats = { HpHead = 220, HpTorso = 60, MeleeDamage = 50 },   -- 180 / 40 / 40
    },
    Stats = function(actor, opts)
        local hard = STATE.HardModeNoMercy

        local move = actor.CharacterMovement
        if IsNotValid(move) then return end

        local npcData = actor.NPCData
        if IsNotValid(npcData) then return end

        -- WALKING turn rate only, not the charge's: H.QuickCharge sets its own MaxAcceleration for
        -- the run and restores this value after. [HARD] a sharper (not instant) turn.
        move.MaxAcceleration = move.MaxAcceleration * (hard and 1.25 or 0.8)

        actor.Cooldown_CombatAbility1 = 3.5   -- 12
        -- Native-timing fallback only; H.QuickCharge overwrites this per charge (see its header -
        -- never read it back as "how long the charge is").
        actor.StampedeDuration = 3            -- 4

        -- HARD TO INTERRUPT: closes both the pooled AND forced-weakness stagger paths (both needed,
        -- or a weak-type hit still gets one free stagger). See AnNotes/AnteNPCs/Peccary.md S1 "Interrupting
        -- a charge" for why. A Stopping Power crit still gets through. [[af-weakness-forced-stagger]]
        AVU.SetStaggerImmune(actor)
        
        if IsValid(actor.AOE_RadialForce) then
            actor.AOE_RadialForce.Radius = hard and 150 or 100
        end
        actor.ChargeDamageAmount = hard and 130 or 100

        actor.TurnWhileStampeding = false

        AVU.DisableAbility(actor, ABILITY_PLANT_CARBUNCLE)

        -- (Jager) The first Peccary is weaker
        if StoryManager.GetStoryProgress() < 10 then
            local headHP = 120
            npcData[ENUMS.NpcData.MeleeDamage] = 30
            actor.ChargeDamageAmount = 75
            AVU.SetLimbHealth(actor, { Head = headHP })
        end

    end,

    -- Scripted charge START: cut the telegraph and run harder (H.CHARGE_PROFILE holds both, per
    -- difficulty). ONE LINE - drop it and the charge is stock again.
    OnCharge = H.ChargePeccaryCharge,

    -- Forced-stagger half of the uninterruptible charge (see Stats above).
    OnDamageTaken = function(actor)
        AVU.ClearWeaknessStagger(actor)
    end,

    -- [HARD] Charge will do a 1s stun on caught players
    --   * Npc ApplyRadialDamage re-enters OnDamageTaken and can cause an AV crash
    OnChargeImpact = function(actor)
        if not STATE.HardModeNoMercy or Utils.IsActorInvalid(actor) then return end

        local radius = 0
        pcall(function() radius = tonumber(actor.AOE_RadialForce.Radius) or 0 end)
        if radius <= 0 then return end

        local origin = actor:K2_GetActorLocation()
        local r2 = radius * radius
        for _, player in ipairs(Utils.LivePlayers()) do
            local ok, loc = pcall(function() return player:K2_GetActorLocation() end)
            if ok and loc and Utils.DistSq(origin, loc) <= r2 then
                -- ApplyBuffLinked, not AddBuff: Server_TryApplyBuff no-ops server->player.
                Utils.ApplyBuffLinked(player, ENUMS.Debuffs.Zapped, CHARGE_STUN_SEC)
            end
        end
    end,

    -- Re-glow after a charge. The stampede's own cleanup (UpdateStampede's last pass, a beat after
    -- Broadcast_StampedeEnd) drops EmissiveIntensity to the native 0.25; two passes so the second
    -- lands after that cleanup whatever its timer phase.
    OnChargeEnd = function(actor)
        for _, ms in ipairs({ 300, 1200 }) do
            Utils.QueueWork(function() chargeGlow(actor) end, ms)
        end
    end,

    -- The slow net under OnChargeEnd (a charge that ends without the multicast). Runs on clients
    -- too (ClientTick): the material rebuild happens on every machine, and without it a client
    -- keeps the vanilla glow after the first charge.
    ClientTick = true,
    OnTick = function(actor, totalTicks)
        if Utils.IsActorInvalid(actor) then return "REMOVE" end
        if totalTicks % 20 ~= 0 then return end
        if not actor.CombatState then return end
        chargeGlow(actor)
    end,

    OnDeath = H.ChargeForget,

    OnGibbed = function(actor)
        AVU.DropLoot(actor, { Pool = { { G.DISTILLATION_CHARGED, 4 } } })
    end,
}


-- =======================================================================
-- PHASE PECCARY
-- Fades in and out on a loop. Fast while invisible, very strong when visible
--   * Runs off server clock for visibility
--   * When fully invisible, sheds debuffs and blinks 5m
-- =======================================================================

-- Fading in and out uses the server clock, not tick, so its synced across clients
local PHASE_PERIOD_S = 10    -- one 0 -> 1 -> 0 cycle
local PHASE_TROUGH_S = 1     -- width of the "fully faded" beat (>= the ~1s sample gap)

-- Appearance: Emissive glow becomes red as its fully visible
local PHASE_GLOW = {
    { At = 0.95, Color = FVector(7, 0, 0), Power = 150 },
    { At = 0.85, Color = FVector(5, 0, 0.1), Power = 125 },
    { At = 0.75, Color = FVector(3, 0, 0.2), Power = 100 },
    { At = 0.65, Color = FVector(1, 0, 0.2), Power = 75 },
    { At = 0.55, Color = FVector(1, 0, 0.2), Power = 50 },
}
local PHASE_TINT     = FVector(1, 0, 1)   -- == the def's Tint.EmissiveColor
local PHASE_TINT_INT = 25

-- Sprint band by opacity: fastest while faded, slowest while solid.
local PHASE_SPEED      = { Low = 200, High = 600 }
local PHASE_SPEED_HARD = { Low = 300, High = 700 }

local PHASE_BLINK = {
    Radius = 800,   -- 8m
    Min    = 300,   -- never a 0.5m shuffle that reads as a rubber-band
    Lift   = 60,    -- Z-lift when moving it
}

-- One vanish per fade cycle (OnTick's wrapper is the stable one, so a weak key is safe).
local phaseCycle = setmetatable({}, { __mode = "k" })

-- Debuffs this sheds when its fully invisible
local PHASE_SHED = {
    ENUMS.Debuffs.Bleeding, ENUMS.Debuffs.SevereBleeding,
    ENUMS.Debuffs.Ignited, ENUMS.Debuffs.IgnitedHoly, ENUMS.Debuffs.IgnitedPlasma,
    ENUMS.Debuffs.AcidBurn, ENUMS.Debuffs.FlaskCorrosive,
    ENUMS.Debuffs.Frost, ENUMS.Debuffs.Frost2, ENUMS.Debuffs.Frost3, ENUMS.Debuffs.Frost4,
    ENUMS.Debuffs.Frost5, ENUMS.Debuffs.SniperRifleIce, ENUMS.Debuffs.FlaskBlizzard,
    ENUMS.Debuffs.Netted, ENUMS.Debuffs.NettedCannon, ENUMS.Debuffs.Rooted,
    ENUMS.Debuffs.ShockTrap, ENUMS.Debuffs.Zapped, ENUMS.Debuffs.ZappedPurple,
    ENUMS.Debuffs.ParryStun, ENUMS.Debuffs.Concussed, ENUMS.Debuffs.Fear,
    ENUMS.Debuffs.BeeSwarm, 
}

-- [AUTHORITY] Fully invisible: shed debuffs and blink to a new spot.
local function phaseVanish(actor)
    for i = 1, #PHASE_SHED do
        local row = PHASE_SHED[i]
        if Utils.ActorHasBuff(actor, row) then Utils.RemoveBuff(actor, row) end
    end

    local origin = actor:K2_GetActorLocation()
    local dest = Utils.GetSpawnPoint(origin, PHASE_BLINK.Radius, PHASE_BLINK.Min, 6, nil, PHASE_BLINK.Lift)
    if dest then AVU.TeleportTo(actor, dest, { NoFX = true }) end
end


-- [RENDERER] Solidifying glow: first PHASE_GLOW step the opacity clears, else the def's own tint.
local function phaseGlow(mesh, opacity)
    local color, power = PHASE_TINT, PHASE_TINT_INT
    for i = 1, #PHASE_GLOW do
        if opacity >= PHASE_GLOW[i].At then
            color, power = PHASE_GLOW[i].Color, PHASE_GLOW[i].Power
            break
        end
    end
    mesh:SetVectorParameterValueOnMaterials(FName("EmissiveColor"), color)
    mesh:SetScalarParameterValueOnMaterials(FName("EmissiveIntensity"), power)
end

V["Phase Peccary"] = {
    Id = 7,
    Base = "Peccary",
    Assets = { ENUMS.Effects.DUST_RAINBOW },

    -- Appearance
    Tint = { Color = FVector(0.1, 0.8, 0.8), EmissiveColor = FVector(1, 0, 3), Emissive = 25 },
    Visuals = function(actor, assets)
        if not SETTINGS.GAMEPLAY.REDUCE_VISUALS then
            AVU.AttachNiagara(actor, ENUMS.Effects.DUST_RAINBOW, "hips", { Scale = FVector(0.25, 0.25, 0.25) })
        end
    end,
    ClientTick = true,

    -- Stats
    BasicStats = {
        -- HpHead = 80,
        -- HpTorso = 80,
        -- WalkSpeed = 200,
        SprintSpeed = 300,   -- 900 (300-600, 350-700 hard)
        MeleeDamage = 25,   -- 50 (25-125)
        -- RangedDamage = 15,
    },
    
    -- [HARD]
    HardMode = {
        BasicStats = { HpHead = 110, HpTorso = 110, SprintSpeed = 350 },   -- 80 / 80 / 300
    },
    Stats = function(actor, opts)
        AVU.LockTaming(actor)   -- bespoke variant, no pet form -> not pheromone-tameable

        local move = actor.CharacterMovement
        if IsNotValid(move) then return end

        move.MaxAcceleration = move.MaxAcceleration * 0.7

        -- No charge, and no idle Carbuncle plant - the plant is an actor-count sink
        -- (wild peccaries still scatter them).
        AVU.DisableAbility(actor, ABILITY_CHARGE)
        AVU.DisableAbility(actor, ABILITY_PLANT_CARBUNCLE)
    end,

    -- Triggers
    -- [AUTHORITY + RENDERER] Fade cycle, in combat only. Authority drives gameplay + the host
    -- visual; pure clients run it via ClientTick for the visual alone.
    OnTick = function(actor, totalTicks)
        if Utils.IsActorInvalid(actor) then return "REMOVE" end
        if actor.IsDead or actor.IsDBNO or not actor.CombatState then return end
        if totalTicks % 10 ~= 0 then return end

        local now = Utils.ServerTimeSeconds()
        if not now then return end   -- no GameState yet; skip rather than fade out of phase

        local mesh = Utils.GetValidMesh(actor)
        if not mesh then return "REMOVE" end

        local npcData = actor.NPCData
        if IsNotValid(npcData) then return end

        local opacity = AVM.TriangleWave(now, PHASE_PERIOD_S)

        mesh:SetScalarParameterValueOnMaterials(FName("Opacity"), opacity)
        phaseGlow(mesh, opacity)

        -- [Authority] Clear debuffs + a short teleport once fully invisible. The cycle latch below
        -- caps it to ONE hop per fade even though the trough window is wider than the sample gap.
        if opacity <= 0.02 and Utils.IsAuthority() then
            local cycle = math.floor(now / PHASE_PERIOD_S)
            if (now % PHASE_PERIOD_S) < PHASE_TROUGH_S and phaseCycle[actor] ~= cycle then
                phaseCycle[actor] = cycle
                phaseVanish(actor)
            end
        end

        -- Gameplay scaling (authority; harmless no-op on clients): faster + softer-hitting while
        -- faded, slower + harder while solid
        local band = STATE.HardModeNoMercy and PHASE_SPEED_HARD or PHASE_SPEED
        npcData[ENUMS.NpcData.SprintSpeed] =
            AVU.TagSpeed(actor, band.High - (band.High - band.Low) * opacity)
        npcData[ENUMS.NpcData.MeleeDamage] = opacity * 100 + 25
    end,

    OnDeath = function(actor)
        if Utils.IsActorInvalid(actor) then return end

        phaseCycle[actor] = nil
        AVU.EndAttachedNiagara(actor)   -- stop the rainbow dust
    end,
    
    OnGibbed = function(actor)
        AVU.DropLoot(actor, { Pool = { { G.ANOMALY, 1 } } })        
        AVU.DropLoot(actor, { Pool = { { G.PECCARY_CHOP, 1 } } })
    end,
}


-- =======================================================================
-- CARBUNCCARY
-- Slow support tank carrying 3 welded Carbuncles that briefly slow players.
--   * Passengers are the mod's heaviest user of AVAttach's subactor lifetime machinery (THE
--     SUBACTOR BOOK / ORPHAN NET) - read that before touching this.
--   * Sneaking 8 (Buff.SkillPerks.Nimble) makes a player untetherable by these; why we can't
--     override it for these three: AnNotes/AnteNPCs/Peccary.md
--   * [HARD] - tankier, hits harder, faster, ~20% faster passenger re-grab
-- =======================================================================

local CARBUNCLE = ENUMS.NpcClasses["Carbuncle"]

-- Seconds before a passenger can grab again, per mount point.
local CARB_TETHER_CD      = { Shoulder = 10, Flank = 14, Head = 8 }
local CARB_TETHER_CD_HARD = { Shoulder = 8,  Flank = 12, Head = 6 }

V["Carbunccary"] = {
    Id = 32,
    Base = "Peccary",
    Assets = { CARBUNCLE },   -- preload so AttachSubactor finds it resident in OnReady

    -- Appearance
    BodyScale = 1.4,
    Tint = { Color = FVector(0.3, 0.25, 0.2), EmissiveColor = FVector(0.7, 0.4, 0.2), Emissive = 100 },
    Visuals = function(actor, assets)
        -- [RENDERER] Calm the local Carbuncle copies (movement/smoothing/collision) - none of
        -- the authority pin replicates. Same as the Jotun rider; no-op on the host.
        AVU.CalmClientNpcPassengers(actor)
    end,
    TimeDilation = 0.85,

    -- Stats
    BasicStats = {
        HpHead = 120,   -- 80
        HpTorso = 120,   -- 80
        WalkSpeed = 230,   -- 200
        SprintSpeed = 350,   -- 900
        MeleeDamage = 70,   -- 50
        -- RangedDamage = 15,
    },
    HardMode = {
        BasicStats = { HpHead = 150, HpTorso = 150, SprintSpeed = 400, MeleeDamage = 80 },
    },
    Stats = function(actor, opts)
        AVU.LockTaming(actor)   -- bespoke variant, no pet form -> not pheromone-tameable
        -- No charge, and no native idle plant: it welds its own 3 in OnReady, so planted
        -- extras are pure actor-count load.
        AVU.DisableAbility(actor, ABILITY_CHARGE)
        AVU.DisableAbility(actor, ABILITY_PLANT_CARBUNCLE)
    end,

    -- Triggers
    -- AUTHORITY: weld 3 Carbuncles
    OnReady = function(actor, assets)
        local cd = STATE.HardModeNoMercy and CARB_TETHER_CD_HARD or CARB_TETHER_CD

        -- Front left shoulder
        AVU.AttachSubactor(actor, CARBUNCLE, "L_FShoulder", {
            Location = FVector(0, -5, 0),
            Rotation = FRotator(0, 30, 310),
            Scale = FVector(0.5, 0.5, 1.4),
            Carbuncle = { MaxTetherDistance = 750, MaxTetherTime = 1, TetherCooldownTime = cd.Shoulder },
        })
        -- Right flank
        AVU.AttachSubactor(actor, CARBUNCLE, "R_FLeg1", {
            Location = FVector(-10, 0, -20), -- R+/U+/F+
            Rotation = FRotator(270, 0, 0),
            Scale = FVector(0.5, 0.5, 1),
            Carbuncle = { MaxTetherDistance = 1500, MaxTetherTime = 1, TetherCooldownTime = cd.Flank },
        })
        -- Head rider
        AVU.AttachSubactor(actor, CARBUNCLE, "Head", {
            Location = FVector(-2, -22, 0),
            Rotation = FRotator(180, 0, 270),
            Scale = FVector(0.6, 0.6, 1.2),
            Carbuncle = { MaxTetherDistance = 1000, MaxTetherTime = 1, TetherCooldownTime = cd.Head },
        })
    end,

    -- [AUTHORITY] Kill + destroy the welded Carbuncles so they don't outlive the carrier,
    -- then drop its 3 passengers as meat (AnteUp1 loot).
    OnDeath = function(actor)
        if Utils.IsActorInvalid(actor) then return end
        Utils.KillAttachedActors(actor)
        Utils.QueueWork(function() Utils.DestroyAttachedActors(actor) end, 100)

        AVU.DropLoot(actor, { Pool = { { G.CARBUNCLE_CARCASS, 1 } }, Count = 3, Radius = 50 })
        AVU.DropLoot(actor, { Pool = { { G.PECCARY_CHOP, 1 } }, Count = 2, Radius = 50 })
    end,
}


-- The Shadow Peccary (Id 56) is now "Peccary Shade" in AnteNPCs/Shades.lua, on the shared shade
-- kit (M_NightShadow cloud, SHADE_FACTION, shade immunities) rather than its own coat here. Same
-- Id, same base, same LockTaming + no-carbuncle stats.

return V
