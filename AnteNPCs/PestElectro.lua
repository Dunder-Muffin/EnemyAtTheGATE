-- =======================================================================
-- ElectroPest variants - base row "Pest_Electro" (NPC_Monster_Pest_Electro).
--
-- The base pest fires a shock ring at the start of (some) leaps and carries electric buffs.
-- Both variants keep that and hang their own behavior off the same beat.
--   * OnShockRing = the Pest_Electro:Server_ShockRingDamage class hook - the ONE reliable
--     "a leap just started" signal on this base. Laser Pest times its burst off it; Telepest
--     starts its blink combo off it.
--   * Test spawn - add to AnteData/SpawnerData.lua:
--       ["<x,y,z>"] = { SpawnAs="Pest_Electro", Variant="Laser Pest" },
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local G = require("AnteData.Items").Global
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local Lasers = require("AnteUtils.Lasers")
local ASSETS = require("AnteCore.AssetManager")
local TELE = require("AnteNPCs.PestElectroHelpers")   -- the blink teleport + multibounce combo

local LogDebug = Utils.LogDebug

local V = {}

-- =======================================================================
-- ABILITY MAP - NPC_Monster_Pest_Electro (row "Pest_Electro", extends NPC_Monster_Pest)
--   0 Idle - none      1 - EMPTY      2 - EMPTY      3 - EMPTY
-- No ability slots implemented (none in the Pest chain either) - all four are free.
-- NOT slots: the Electro Pest is purely REACTIVE - its zap fires off the damage channel
-- (ReceivePointDamage / ReceiveRadialDamage -> ZapAggressor), plus Server_ShockRingDamage
-- and the CurrentlyElectroCharged state. None of it is reachable via ability slots.
-- =======================================================================


-- =======================================================================
-- LASER PEST 
-- Fires lasers in random directions when it leaps. Immune to its own lasers
-- Depth: AnNotes/AnteNPCs/PestElectro.md
-- =======================================================================

-- The burst rides the shock ring, and the ring is the leap's own event, so the leap IS the
-- pacing - there is no separate burst cooldown. ElectroChargeCooldown (Stats) is the one dial.
local LASER_FLOOR_TICK = 30      -- ignore the save-load tick flood at startup
local LASER_DAMAGE = { Normal = 50, Hard = 70 }
local LASER_DELAY_MS = 300       -- fire the lasers this long after the leap
local LASER_DURATION_MS = 1000    -- how long the beams stay live
local LASER_COUNT = { Normal = 4, Hard = 5 }   -- how many beams sprout
local LASER_SPREAD = FVector(0, 0, 0)  -- origin jitter (half-extents); zeroed = one shared origin
local LASER_SIDE_SPREAD = 25        -- +/- deg jitter around each side (left/right)
local LASER_PLAYER_RANGE = 3000     -- ~30m: skip the whole laser show if no player is this near
local LEAP_GRAVITY_SCALE = 0.7
local GRENADE_GLOW = 3000           -- back-grenade rainbow: M_Antelight_RGB EmissiveIntensity (ships 1000)

V["Laser Pest"] = {
    Id = 16,
    Base = "Pest_Electro",
    Assets = { ENUMS.Components.SM_LASER_GRENADE, ENUMS.LaserComponent,
               ENUMS.Components.M_ANTELIGHT_RGB },
    TamedVariant = "Tamed Laser Pest",   -- its PET form (ModulePets/TamedPests; laser is dropped when tamed)
    LaserStyle = Lasers.RANDOM,          -- opt OUT of SETTINGS.GAMEPLAY.CLIENT_LASER_COLOR: the disco is the point

    -- Appearance
    Tint = { Color = FVector(2, 0.7, 2), EmissiveColor = FVector(0, 0.2, 1), Emissive = 45 },
    --BodyScale = 0.9,
    Visuals = function(actor, assets)
        AVU.AttachStaticMesh(actor, ENUMS.Components.SM_LASER_GRENADE, "hips", {
            -- Location = FVector(-15, -15, 0), -- up(-)/down(+), back(+)/forward(-)
            -- Rotation = FVector(0, 0, 0),
            -- Scale = FVector(1.4, 1.4, 1.7),
            Location = FVector(-10, -8, 0), -- up(-)/down(+), back(+)/forward(-)
            Rotation = FVector(0, 0, 0),
            Scale = FVector(3, 3, 3),
            Emissive = GRENADE_GLOW,
            Material = ENUMS.Components.M_ANTELIGHT_RGB,
        })
    end,

    -- Stats
    BasicStats = {
        HpHead = 80,   -- 60
        -- WalkSpeed = 150,
        SprintSpeed = 250,   -- 150
        -- MeleeDamage = 70,
        -- RangedDamage = 15,
    },
    HardMode = { BasicStats = { HpHead = 140 }, TimeDilation = 1.25 },
    DebuffsImmune = { ENUMS.Debuffs.Ignited, ENUMS.Debuffs.ShockTrap, ENUMS.Debuffs.Zapped },
    TimeDilation = 1.15,
    Stats = function(actor, opts)
        -- Floatier, slower leap arc, so the beams get a long airborne sweep.
        local move = actor.CharacterMovement
        if IsValid(move) then
            pcall(function() move.GravityScale = LEAP_GRAVITY_SCALE end)
        end

        actor.PestLeapVelocity = 725 --1000

        -- Ring deals nothing; the short charge cooldown only exists to pace our laser beat.
        pcall(function() actor.ShockRingDamage = 0 end)
        pcall(function() actor.ElectroChargeCooldown = 0.25 end)
        pcall(function() actor.ShockResponseDamage = 0 end)


    end,

    -- Triggers
    -- [AUTHORITY] Fire the beam burst LASER_DELAY_MS after the shock ring, i.e. mid-leap.
    OnShockRing = function(actor)
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end

        -- No player within ~30m -> skip the whole show. Brawling other NPCs off-screen, the laser
        -- components + their 0.2s traces + replicated beams are pure wasted CPU.
        --   * IsPlayerNearby reads the GameState player array - cheap, no FindAllOf scan.
        if not Utils.IsPlayerNearby(actor:K2_GetActorLocation(), LASER_PLAYER_RANGE) then return end

        if STATE.FAST_TICK < LASER_FLOOR_TICK then return end

        Utils.QueueWork(function()
            if Utils.IsActorInvalid(actor) or actor.IsDead then return end

            -- Re-warm the WHOLE beam dependency set right before Lasers.FireBurst: any of it
            -- cold-loads inside the WorkQueue drain hook (S2 deadlock), and a def.Assets preload
            -- does not pin it (S3). The CLASS ALONE IS NOT ENOUGH - see Lasers.BURST_ASSETS.
            ASSETS.LoadAsync(Lasers.BURST_ASSETS, function()
                if Utils.IsActorInvalid(actor) then return end
                local hard = STATE.HardModeNoMercy
                Lasers.FireBurst(actor, "Spine2", {
                    Count = hard and LASER_COUNT.Hard or LASER_COUNT.Normal,
                    Damage = hard and LASER_DAMAGE.Hard or LASER_DAMAGE.Normal,
                    Duration = LASER_DURATION_MS,
                    Location = FVector(-10, 0, 10),
                    Spread = LASER_SPREAD, 
                    -- Bias the beams to its sides
                    SideBias = true, SideSpread = LASER_SIDE_SPREAD,
                    PitchMin = -15, PitchMax = 20,
                })
                LogDebug("Laser Pest - dome laser burst (post-shock)", SETTINGS.DEBUG_NPC_ACTIONS)
            end)
        end, LASER_DELAY_MS)
    end,

    OnGibbed = function(actor)
        -- Early story: 1 of the basic pool; later (>32): 2 of the richer pool.
        AVU.DropLoot(actor, {
            { Pool = {
                { G.LIQUID_CRYSTAL, 2 },
                { G.LENS, 1 },
                { G.GEM, 2 },
                { G.CAPACITOR, 1 },
                { G.DIODE, 1 },
            }, Count = 1, MaxStory = 32 },
            { Pool = {
                { G.LIQUID_CRYSTAL, 2 },
                { G.LENS, 1 },
                { G.GEM, 2 },
                { G.CAPACITOR, 1 },
                { G.DIODE, 1 },
                { G.QUANTUM_GLASS, 2 },
                { G.PROJECTION_MATRIX, 1 },
            }, Count = 2, MinStory = 33 },
        })
    end,
}


-- =======================================================================
-- TELEPEST  -  [AUTHORITY] blink combo, [RENDERER] blink FX
-- Warps mid-leap to strike from a new angle: a 3-hit combo (classic flank warp + 2 re-blinks),
-- each landing back on the target before it lands. Combo mechanics + geometry: AnNotes/AnteNPCs/PestElectro.md.
--   * Combo leaps FLOAT: GravityScale drops for the window (restored after) so darts land on the
--     target instead of dropping flat.
--   * The warp is gated by the shock-ring CHARGE cooldown (WARP_CHARGE_CD); only the ring's
--     damage is zeroed, its visual is baked into the leap and can't be removed.
--   * Blink FX is renderer-local: host draws it inside TELE.Teleport, clients mirror it off the
--     replicated position jump (ClientTick -> TELE.ClientBlinkTick).
-- =======================================================================

-- The blink teleport AND the multibounce combo live in AnteNPCs/PestElectroHelpers (TELE.Teleport,
-- TELE.StartCombo/ComboOnHit, TELE.BLINK_* asset paths), shared with the TAMED
-- Telepest pet (ModulePets/TamedPests: faster darts, level-scaled hits, escape blink).
-- Only this variant's own timing/stat knobs stay here.
local WARP_DELAY_MS     = 500     -- teleport once the forward leap is ENGAGED (airborne), not at liftoff
local WARP_CHARGE_CD    = { Normal = 9, Hard = 7 }   -- Warp cooldown. Its airborne time counts - its cooldown is shorter than it appears
-- Time on the ground between combos. The charge cooldown above runs from a combo's START, and a
-- whiffing combo runs nearly to its own hard cap - which on hard left no window to punish it in.
local WARP_GROUND_MS    = { Normal = 2000, Hard = 1500 }

-- Knobs for the SHARED combo state machine. Total darts = 1 (classic warp) + ExtraHits re-blinks.
local COMBO_KNOBS = {
    ExtraHits    = 2,      -- re-blinks after the first warp (3 strikes total)
    StepMs       = 1200,   -- TIMEOUT fallback between darts (a whiff waits this long)
    ImpactMs     = 350,    -- a CONNECTED dart re-blinks this soon instead (impact-or-timeout)
    GravityScale = 0.70,   -- combo-window GravityScale (restored by the cleanup)
    MinSpeed     = 900,    -- redirect hspeed floor (base 800 would cancel the slowdown up close)
    TailMs       = 500,    -- after the last re-blink, wait this long before restoring gravity
                           -- (the final dart is still airborne at the last blink)
    RearmMs      = 250,    -- watchdog cadence: while a dart flies with IsLungingInAir cleared
                           -- (ground graze ate the flag), re-arm it so target contact still hurts
    Retries      = 2,      -- LoS retries for re-blink spot-picks (each failed retry = a ~10ms
                           -- trace; a wall-flank on one dart of a burst is invisible)
    WarpDelayMs  = WARP_DELAY_MS,
}

V["Telepest"] = {
    Id = 42,
    Base = "Pest_Electro",
    Assets = { TELE.BLINK_FX, TELE.BLINK_SFX,
               ENUMS.Components.SM_PERSONAL_TELEPORTER },   -- preload so the blink niagara/cue + prop are a cache hit
    TamedVariant = "Tamed Telepest",   -- its PET form (ModulePets/TamedPests; keeps the blink)

    -- Appearance
    BodyScale = { X = 1.2, Y = 1.2, Z = 1.2 },
    Tint = { Color = FVector(0.6, 1, 0.4), EmissiveColor = FVector(0, 1, 1), Emissive = 25 },
    Visuals = function(actor, assets)
        AVU.AttachStaticMesh(actor, ENUMS.Components.SM_PERSONAL_TELEPORTER, "Spine1", {
            Location = FVector(-15, 14, -7), --Down(+), Backwards(+), Left(+)
            Rotation = FRotator(160, 90, 270),
            Scale = FVector(1.15, 1.15, 1.07),
        })

        -- The teleporter material has no usable emissive param, so a small unshadowed point
        -- light co-located inside the prop (same Spine1 + offset) is what makes it READ as
        -- glowing. Cheap: shadows off by default, tight radius.
        --   * REDUCE_VISUALS drops it (a dynamic point light is render-thread cost); the prop
        --     mesh above still shows, just unlit.
        if not SETTINGS.GAMEPLAY.REDUCE_VISUALS then
            AVU.AttachPointLight(actor, "Spine1", {
                Location = FVector(-17, 14, -7),
                Color = FLinearColor(0, 0.85, 1, 1),   -- teleporter cyan
                Intensity = 1200,
                AttenuationRadius = 160,
                SourceRadius = 8,
            })
        end
    end,

    -- [RENDERER] Blink mirror (see header): pure clients redraw the FX off the replicated position
    -- jump. Authority has no per-tick work (the blink is OnShockRing-driven), so OnTick below
    -- unregisters itself immediately on the server.
    ClientTick = true,

    -- Stats
    BasicStats = {
        HpHead = 100,   -- 60
        -- WalkSpeed = 150,
        -- SprintSpeed = 150,
        -- MeleeDamage = 70,
        -- RangedDamage = 15,
        MeleeAttackRange = 1500,   -- 150; this is the leap range
    },
    HardMode = { BasicStats = { HpHead = 120, MeleeDamage = 80 }, TimeDilation = 0.9 },
    DebuffsImmune = { ENUMS.Debuffs.ShockTrap, ENUMS.Debuffs.Zapped },
    TimeDilation = 0.75,
    Stats = function(actor, opts)
        -- Ring damage off (the graphic is hardcoded into the leap); the charge cooldown is the
        -- knob that actually paces the warp.
        pcall(function() actor.ShockRingDamage = 0 end)
        pcall(function() actor.ShockResponseDamage = 0 end)
        pcall(function()
            actor.ElectroChargeCooldown = STATE.HardModeNoMercy and WARP_CHARGE_CD.Hard
                                                                 or WARP_CHARGE_CD.Normal
        end)
    end,

    -- Triggers
    -- [AUTHORITY] A charged shock-ring leap starts the shared blink-combo state machine (dart 1
    -- after WarpDelayMs, then impact-or-timeout advances, a watchdog, a hard-cap cleanup). Can't
    -- re-trigger mid-combo: the ring FX rides OnPestJumpLiftoff, which only the native windup leap
    -- broadcasts - the combo's LaunchCharacter redirects never touch it.
    OnShockRing = function(actor)
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        COMBO_KNOBS.GroundMs = STATE.HardModeNoMercy and WARP_GROUND_MS.Hard or WARP_GROUND_MS.Normal
        TELE.StartCombo(actor, COMBO_KNOBS)
    end,

    -- IMPACT half of impact-or-timeout: a connected dart brings the next re-blink forward.
    -- Fires inside ProcessDamage, so ComboOnHit does only table reads + a QueueWork (S6).
    OnDealtDamage = function(attacker, victim)
        TELE.ComboOnHit(attacker)
    end,

    OnTick = function(actor, totalTicks)
        if Utils.IsAuthority() then return "REMOVE" end
        if Utils.IsActorInvalid(actor) then return "REMOVE" end
        TELE.ClientBlinkTick(actor)
    end,

    -- Gibbed (over-killed): drops an exor heart + a pair of staplers.
    OnGibbed = function(actor)
        AVU.DropLoot(actor, { Pool = {
            { G.GIB_EXORHEART, 1 },
            { G.STAPLER, 2 },
            { G.SOLDER, 1 },
        } })
    end,
}

-- FEAR IMMUNITY: these pest variants are immune to Debuff_Fear (appended to each def's
-- DebuffsImmune so existing immunities are kept; NpcManager applies it on mutate). The base
-- pests in AnteNPCs/Pest stay fearable.
for _, def in pairs(V) do
    def.DebuffsImmune = def.DebuffsImmune or {}
    table.insert(def.DebuffsImmune, ENUMS.Debuffs.Fear)
end


return V
