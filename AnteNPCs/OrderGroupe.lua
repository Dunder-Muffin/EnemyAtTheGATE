-- =======================================================================
-- ORDER GROUPE - the Voussoir whiteout troops (Ids 76-78). They all exploit the Voussoir
-- 'blizzard' effect. Groupe Sniper (Id 75) is in OrderSniper.lua; the Order shield troopers
-- (Trooper_Shield) are in OrderRook.lua.
--
-- MUST-KNOWS
--   * LOOK = the shared white-spectre kit in AnteNPCs/OrderGroupeHelpers: GRP.Wash / GRP.FadeOut /
--     GRP.FadeIn / GRP.FADE_OUT_MS (OrderSniper and the Interfector use the same set).
--   * Damage-stage texture updates REBUILD the torso material and drop the wash, so every
--     variant here re-asserts GRP.Wash from OnDamageTaken.
--   * Bases (decompiled): Groupe_Grunt / Groupe_Shotgun are plain NPC_Soldier_Grunt family;
--     Groupe_Rook = NPC_Groupe_Shield (extends NPC_Soldier_Grunt), and Trooper_Shield extends
--     that. The Rook's Shield is a StaticMeshComponent that blocks hits landing on it
--     (BlockDamage_Event).
--   * "AI_TurtleMode" (Rook: below 60% HP + damaged, 20s) CANNOT be made immune, only removed -
--     it is self-applied via BuffDebuffComponent->Server_ApplyBuff and never consults
--     AbioticFunctionLibrary.IsCharacterImmuneToBuffDebuff.
--   * All three bases run the SOLDIER BT - its rules (450uu floor, MOVE_None hangs the tree,
--     Buff.Fear = flee, the mandatory AVU.ReleaseSoldierBT) are in CLAUDE.md.
--
-- =======================================================================
-- ABILITY MAP - all three bases descend from NPC_Soldier_Grunt, so they inherit the Order's
-- single ability and nothing else:
--
--   1 GRENADE (only Grunt uses one)
--   0 Idle - none
--
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local ENUMS = require("AnteData.Enums")
local ASSETS = require("AnteCore.AssetManager")
local G = require("AnteData.Items").Global
local STATE = require("AnteCore.State")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local GRP = require("AnteNPCs.OrderGroupeHelpers")   -- the shared white-spectre wash/fade kit

local LogDebug = Utils.LogDebug

local V = {}


-- =======================================================================
-- GROUPE FROSTPACK  (Groupe_Grunt, Id 76)
-- A slightly slower grunt with a stretched burst pattern, plus a whiteout BLINK.
--   * [AUTHORITY] While a blizzard is active near it, roughly every 6s it fades to invisible,
--     lingers hidden, hops to a nearby spot with line of sight, then fades back in facing its
--     target.
--   * The Yeti-slam ice-cloud FX was TRIED here and dropped - too expensive at scale (3
--     Frostpacks out microlagged; it's a big niagara). The cheap material fade stays.
-- =======================================================================

local FROST_REPO_CD_TICKS = 60    -- ~6s between storm blinks
local FROST_REPO_MIN      = 500
local FROST_REPO_MAX      = 1500
local FROST_BURST_HARD    = 4     -- GruntBurstCount in hard mode (3 normally)

-- actor wrapper -> FAST_TICK of the last blink (the OnTick wrapper is stable per registration).
local lastFrostRepoTick = setmetatable({}, { __mode = "k" })

V["Groupe Frostpack"] = {
    Id = 76,
    Base = "Groupe_Grunt",
    Assets = {},

    -- Appearance
    -- [RENDERER] The bright ~70% whiteout wash + a whisper of cold shimmer, faded in on appear.
    Visuals = function(actor, assets)
        GRP.Wash(actor)
        local mesh = Utils.GetValidMesh(actor)
        if mesh then mesh:SetVectorParameterValueOnMaterials(FName("EmissiveColor"), FVector(0.4, 0.7, 1)) end
        GRP.FadeIn(actor)
    end,

    -- Stats
    BasicStats = {
        HpHead = 150, --100
        HpTorso = 200, --150
        -- WalkSpeed = 200,
        SprintSpeed = 500, --600
        MeleeDamage = 100, -- 50
        RangedDamage = 35, -- 25
        MeleeAttackRange = 1,
        RangedAttackCooldown = 1,   -- 0.5
    },
    HardMode = { NoAggroAnim = true, BasicStats = { HpHead = 200, HpTorso = 250, RangedDamage = 40 } },

    Stats = function(actor, opts)
        actor.GruntBurstCount = STATE.HardModeNoMercy and FROST_BURST_HARD or 3
        actor.CurrentAmmoCount = 20 -- 20
        actor.MaxAmmoCount = 20 -- 20
        actor.GruntBurstTimeBetweenShots = 0.15 -- 0.1

        AVU.DisableGrenades(actor)
    end,

    -- Triggers
    OnTick = function(actor, totalTicks)
        if Utils.IsActorInvalid(actor) then return "REMOVE" end
        if totalTicks % 10 ~= 0 then return end
        if actor.IsDead then return end

        local target = actor:GetCurrentCombatTarget()
        if Utils.IsActorInvalid(target) then return end

        local loc = actor:K2_GetActorLocation()
        if not loc or not AVU.BlizzardActiveNear(loc) then return end

        if not AVU.CooldownReady(lastFrostRepoTick, actor, FROST_REPO_CD_TICKS) then return end

        GRP.StormBlink(actor, target, {
            MinDist = FROST_REPO_MIN, MaxDist = FROST_REPO_MAX, Label = "Frostpack",
        })
    end,

    -- Re-assert the wash (damage stages rebuild the materials and drop it - see header).
    OnDamageTaken = function(actor)
        GRP.Wash(actor)
    end,

    OnDeath = function(actor)
        AVU.DropLoot(actor, { Pool = {
            { G.AMMO_556, 4 },
            { G.AMMO_556, 4 },
        } })
    end,
}


-- =======================================================================
-- GROUPE BREACHER  (Groupe_Shotgun, Id 78)
-- A close-range shotgunner on a 3-shell clip (blast x3, then reload) that skirmishes on
-- scripted footwork and vanishes in a whiteout.
--   * [AUTHORITY] Storm blink: the Frostpack's ability (GRP.StormBlink), but it reopens the
--     distance it wants - the new perch is at least BREACHER_BLINK_MIN from its target.
--     The old snow-fury (TimeDilation + backpedal + siderolls) was replaced by this.
--   * Keeps the NATIVE shotgun BT (fires with no windup) and scripts movement on top.
--   * A borrowed BT was tried and dropped: the GK Gatekeeper/Heavy trees bake their windup into
--     the TREE itself, not a pawn property, so it can't be stripped at runtime.
-- =======================================================================

local BREACHER_CLIP             = 3       -- MaxAmmoCount (native shotgun clip = 8); reloads at 0
local BREACHER_ENGAGE_SQ        = 2000 * 2000   -- only maneuver within this range of the target
local BREACHER_MELEE_SQ         = 600 * 600     -- inside this -> backpedal hard
local BREACHER_HOP              = 600     -- how far ahead we aim the held move each re-issue
local BREACHER_STRAFE_TICKS     = 25      -- ~2.5s committed to one strafe side
local BREACHER_BACKPEDAL_TICKS  = 14      -- ~1.4s committed to a backpedal at range
local BREACHER_BACKPEDAL_CHANCE = 0.3
local BREACHER_BLINK_CD_TICKS   = 60      -- ~6s between storm blinks (the Frostpack's cadence)
local BREACHER_BLINK_MIN        = 800     -- 8m: it blinks to reopen the gap, not to close it
local BREACHER_BLINK_MAX        = 1500

local breacherMove = setmetatable({}, { __mode = "k" })   -- actor -> committed maneuver
-- actor wrapper -> FAST_TICK of the last blink (the OnTick wrapper is stable per registration).
local lastBreacherBlinkTick = setmetatable({}, { __mode = "k" })

V["Groupe Breacher"] = {
    Id = 78,
    Base = "Groupe_Shotgun",
    Assets = {},

    -- Appearance
    -- [RENDERER] The standard Groupe look: whiteout wash + cold shimmer, faded in on appear.
    Visuals = function(actor, assets)
        GRP.Wash(actor)
        local mesh = Utils.GetValidMesh(actor)
        if mesh then mesh:SetVectorParameterValueOnMaterials(FName("EmissiveColor"), FVector(0.4, 0.7, 1)) end
        GRP.FadeIn(actor)
    end,

    -- Stats
    BasicStats = {
        HpHead = 250, --100
        HpTorso = 150, -- 150
        -- WalkSpeed = 130,
        SprintSpeed = 200, -- SprintSpeed = 160,
        -- MeleeDamage = 50,
        -- RangedDamage = 25,
    },
    HardMode = { NoAggroAnim = true, BasicStats = { HpHead = 350, HpTorso = 200, RangedDamage = 33 } },

    Stats = function(actor, opts)
        pcall(function()
            actor.MaxAmmoCount = BREACHER_CLIP
            
            -- Clamp the loaded clip too
            if actor.CurrentAmmoCount and actor.CurrentAmmoCount > BREACHER_CLIP then
                actor.CurrentAmmoCount = BREACHER_CLIP
            end
            
            local npcData = actor.NPCData
            if IsNotValid(npcData) then return end

            npcData[ENUMS.NpcData.WalkSpeed] = 325
            npcData[ENUMS.NpcData.SprintSpeed] = 325
        end)
    end,

    -- Triggers
    OnTick = function(actor, totalTicks)
        if Utils.IsActorInvalid(actor) or actor.IsDead then return "REMOVE" end
        if totalTicks % 5 ~= 0 then return end                  -- ~2/s

        if not Utils.IsActorReadyToAttack(actor) then return end
        local target = actor:GetCurrentCombatTarget()
        if Utils.IsActorInvalid(target) then return end
        local aLoc = actor:K2_GetActorLocation()
        local tLoc = target:K2_GetActorLocation()
        if not aLoc or not tLoc then return end

        -- STORM BLINK: in a whiteout it vanishes and reappears out past its shotgun range instead
        -- of skirmishing. The reposition owns the tick.
        if AVU.BlizzardActiveNear(aLoc)
            and AVU.CooldownReady(lastBreacherBlinkTick, actor, BREACHER_BLINK_CD_TICKS) then
            GRP.StormBlink(actor, target, {
                MinDist = BREACHER_BLINK_MIN, MaxDist = BREACHER_BLINK_MAX,
                Label = "Groupe Breacher",
            })
            return
        end

        -- REGULAR skirmish: strafe/backpedal (reloading -> hold still, vulnerable downtime).
        if (actor.CurrentAmmoCount or 1) <= 0 then return end
        local dir = Utils.Direction(aLoc, tLoc)
        local distSq = Utils.DistSq(aLoc, tLoc)
        if distSq > BREACHER_ENGAGE_SQ then breacherMove[actor] = nil; return end   -- far -> let the BT advance

        local m = breacherMove[actor]
        if distSq < BREACHER_MELEE_SQ then
            m = { dx = -dir.X, dy = -dir.Y, expires = totalTicks + 6 }   -- too close: break off
        elseif (not m) or m.expires <= totalTicks then
            if math.random() < BREACHER_BACKPEDAL_CHANCE then
                m = { dx = -dir.X, dy = -dir.Y, expires = totalTicks + BREACHER_BACKPEDAL_TICKS }
            else
                m = { side = (math.random() < 0.5) and 1 or -1, expires = totalTicks + BREACHER_STRAFE_TICKS }
            end
        end
        if m.side then m.dx, m.dy = -dir.Y * m.side, dir.X * m.side end   -- arc around the target
        breacherMove[actor] = m

        local controller = actor:GetController()
        if IsNotValid(controller) then return end
        local dest = FVector(aLoc.X + m.dx * BREACHER_HOP, aLoc.Y + m.dy * BREACHER_HOP, aLoc.Z)
        pcall(function() controller:MoveToLocation(dest, 40, true, true, true, true, nil, true) end)
    end,

    -- Re-assert the wash (damage stages rebuild the materials and drop it - see header).
    OnDamageTaken = function(actor)
        GRP.Wash(actor)
    end,

    OnDeath = function(actor)
        AVU.DropLoot(actor, { Pool = {
            { G.SCRAP_KEVLAR, 2 },
            { G.CARBON_PLATING, 1 },
        } })
    end,
}



-- =======================================================================
-- GROUPE Rookram - A more aggressive rook that replaces its knife attack with a blunt knockback
--   * [AUTHORITY] Native turtle mode is removed 
--   * [AUTHORITY] It bashes twice as often while it stands in a whiteout.
-- =======================================================================

local RAM_BASH_RATE      = 1.5    -- MeleeAttackPlayRate (replicates)
local RAM_HIT_APEX       = 0.2   -- seconds to hit. Native apex (0.52s) isn't scaled by play-rate,
                                 -- so pulling it early keeps the hit inside the sped-up swing.
local RAM_MELEE_RANGE    = 120   -- 300
local RAM_MELEE_DMG      = 100   -- 75
local RAM_MELEE_DMG_HARD = 125
local RAM_WASH_MUL       = 25    -- the Ram's brighter fixed wash (Visuals + damage re-assert)

local RAM_SHIELD_SLOTS   = { 0, 2 }   -- shield mat slots swapped to the snow material (see Visuals)
local RAM_KNOCK_HORIZ    = 700
local RAM_KNOCK_UP       = 200
local RAM_KNOCK_CD_TICKS = 10    -- 1s per victim (bash can multi-hit)

-- CADENCE: three gates hold the swing rate. The real one is a BT tag cooldown, not a pawn field -
-- see AnNotes/AnteNPCs/OrderRook.md ("Melee cadence: the 15s IS real") for the full decode.
--   * BT_Attack_Soldier_Shield's mobile melee branch sets a 15s cooldown on tag
--     "AI.Cooldown.Ability1" - unrelated to the pawn's Cooldown_CombatAbility1. Cleared per actor
--     via AVU.SetBtCooldownTag.
--   * MeleeAttack_OnCooldown is ours to own (no native writer on a Rook), but it only binds the
--     CONTROLLER's melee path - a BT task swings straight through it, so it is a backstop.
--   * AVU.ReleaseSoldierBT ends the montage's raw-length wait early (world time, not scaled by rate).
-- RAM_SWING_CD_TICKS is the one dial - at 6s it clears past both smaller gates, so it sets the rate,
-- halving to RAM_SWING_CD_SNOW in a whiteout. The TURTLE branch answers to none of this: see the
-- Rookram section of AnNotes/AnteNPCs/OrderRook.md before chasing a burst of fast bashes.
local RAM_TIME_DILATION  = 1.7   -- also def.TimeDilation below; the release math needs the number
local RAM_SWING_CD_TICKS = 60    -- THE DIAL: min ticks between swings (6s; the tree's own gate was 15)
local RAM_SWING_CD_SNOW  = 30    -- the dial while it stands in a whiteout (3s)
local RAM_BT_MELEE_TAG   = "AI.Cooldown.Ability1"   -- the BT tag above, NOT the pawn's Ability1
-- Early release OFF: at a 6s dial the montage recovers with margin, and it costs an EIGT flush per
-- swing. Flip on only if the dial ever drops close to the montage length.
local RAM_EARLY_RELEASE  = false
-- Effective animation rate = montage rate x actor TimeDilation. If a swing reads visually clipped,
-- this is too high, not the pad.
local RAM_RELEASE_RATE   = RAM_BASH_RATE * RAM_TIME_DILATION
local RAM_RELEASE_PAD    = 2     -- ticks of slack, so the release lands after the blend-out
local RAM_LUNGE_FALLBACK = 1.4   -- only if the montage refuses to report its length

local lastRamKnockTick = {}   -- victim ActorKey -> FAST_TICK (ProcessDamage wrappers are fresh)
local lastRamSwingTick = {}   -- ActorKey -> FAST_TICK of its last swing (hook wrappers are fresh)
local ramReleasedFor   = {}   -- ActorKey -> the swing stamp we already released the BT for
local ramTagClearedFor = {}   -- ActorKey -> the swing stamp we already cleared the BT gate for
local ramInSnow        = {}   -- ActorKey -> standing in a whiteout, sampled on the 1s beat

V["Groupe Rookram"] = {
    Id = 77,
    Base = "Groupe_Rook",
    Assets = { ENUMS.DamageType.Blunt },
    
    -- Appearance
    Visuals = function(actor, assets)
        GRP.Wash(actor, RAM_WASH_MUL)
        local mesh = Utils.GetValidMesh(actor)
        if mesh then mesh:SetVectorParameterValueOnMaterials(FName("EmissiveColor"), FVector(0.3, 0.6, 1)) end
        GRP.FadeIn(actor)
        pcall(function()
            local shield = actor.Shield
            local mat = ASSETS.GetIfValid(ENUMS.Components.M_MILITARY_BACKPACK_SNOW)   -- resident with the class
            if IsValid(shield) and IsValid(mat) then
                for _, slot in ipairs(RAM_SHIELD_SLOTS) do
                    shield:SetMaterial(slot, mat)
                end
                shield:SetRelativeScale3D(FVector(1.15, 1.15, 1.15))   -- Larger shield
            end
        end)
        pcall(function()
            local knife = actor.Knife
            if IsValid(knife) then knife:SetVisibility(false, true) end
        end)
    end,

    -- Stats
    BasicStats = {
        HpHead = 150, -- 100
        HpTorso = 175, -- 150
        WalkSpeed = 150,   -- 200
        SprintSpeed = 230,   -- 350
        MeleeDamage = RAM_MELEE_DMG,   -- 75
        -- RangedDamage = 25,
        MeleeAttackRange = RAM_MELEE_RANGE,
    },
    HardMode = { NoAggroAnim = true, BasicStats = { HpHead = 175, HpTorso = 250, MeleeDamage = RAM_MELEE_DMG_HARD } },
    TimeDilation = RAM_TIME_DILATION,
    MirrorTimeDilation = true,
    Stats = function(actor, opts)

        AVU.ChangeDamageType(actor, ENUMS.DamageType.Blunt, true)   -- bash, not stab: no bleed
        pcall(function() actor.MeleeAttackPlayRate = RAM_BASH_RATE end)
        pcall(function() actor.MeleeHitApex = RAM_HIT_APEX end)
        pcall(function() actor.PowerMeleeHitApex = RAM_HIT_APEX end)
    end,

    -- Triggers
    -- [AUTHORITY] Per swing: shut the attack window. OnTick reopens it RAM_SWING_CD_TICKS later.
    -- Keyed by ActorKey, since this hook hands back a fresh wrapper every call.
    OnMeleeSwing = function(actor)
        if not Utils.IsAuthority() or Utils.IsActorInvalid(actor) then return end
        pcall(function() actor.MeleeAttack_OnCooldown = true end)
        local key = Utils.ActorKey(actor)
        if key then lastRamSwingTick[key] = STATE.FAST_TICK end
    end,

    -- [AUTHORITY] Remove turtle buff every 1s (can't be made immune to it)
    OnTick = function(actor, totalTicks)
        if Utils.IsActorInvalid(actor) then return "REMOVE" end
        if actor.IsDead then return end
        -- CachedFullName, not ActorKey
        local key = AVU.CachedFullName(actor)
        if not key then return end
        local now, last = STATE.FAST_TICK, lastRamSwingTick[key]
        local swingCd = ramInSnow[key] and RAM_SWING_CD_SNOW or RAM_SWING_CD_TICKS

        -- Reopen the swing window. A never-swung body (last == nil) clears it too: a /reload wipes
        -- this table but not a mid-cooldown body's state, so it needs the same idle re-assert.
        -- Read-then-write keeps this to one property write per Ram per swing, not per tick.
        if last == nil or now - last >= swingCd then
            pcall(function()
                if actor.MeleeAttack_OnCooldown then actor.MeleeAttack_OnCooldown = false end
            end)
            -- Also clear the tree's OWN gate (the real 15s cooldown, see CADENCE above). Latched
            -- per swing so this is one native call per attack, not per tick. `last or 0` covers a
            -- never-swung body the same way as above.
            if ramTagClearedFor[key] ~= (last or 0) then
                ramTagClearedFor[key] = last or 0
                AVU.SetBtCooldownTag(actor, RAM_BT_MELEE_TAG, 0)
            end
        end

        -- Hand the tree its release once the sped-up bash has really finished (see CADENCE above).
        -- Driven from HERE, not a QueueWork inside OnMeleeSwing: that hook's wrapper is fresh, and
        -- holding one across a ~1s delay is the stale-wrapper case. `wait == nil` just means not
        -- measured yet, which reads as vanilla cadence for a tick or two.
        if RAM_EARLY_RELEASE and last and ramReleasedFor[key] ~= last then
            local wait = AVU.MeleeReleaseTicks(ENUMS.Anims.ROOK_LUNGE, RAM_RELEASE_RATE,
                { Fallback = RAM_LUNGE_FALLBACK, Pad = RAM_RELEASE_PAD })
            if wait and now - last >= wait then
                ramReleasedFor[key] = last
                AVU.ReleaseSoldierBT(actor)
            end
        end

        if totalTicks % 10 ~= 0 then return end
        if Utils.ActorHasBuff(actor, "AI_TurtleMode") then
            Utils.RemoveBuff(actor, "AI_TurtleMode")
        end

        -- Storm state picks the swing dial above. Sampled on this 1s beat rather than per tick,
        -- and held as state so the dial can never hand out a free swing on a flicker.
        local loc = actor:K2_GetActorLocation()
        ramInSnow[key] = (loc ~= nil) and AVU.BlizzardActiveNear(loc) or false
    end,

    -- [AUTHORITY] Every bash launches the victim away from the shield. Per-victim cooldown -
    -- the sped-up bash can register several hits in one swing.
    OnDealtDamage = function(attacker, victim)
        if Utils.IsActorInvalid(attacker) or Utils.IsActorInvalid(victim) then return end
        local key = Utils.ActorKey(victim)
        if not key then return end
        if not AVU.CooldownReady(lastRamKnockTick, key, RAM_KNOCK_CD_TICKS) then return end

        local al = attacker:K2_GetActorLocation()
        if not al then return end
        AVU.KnockbackFrom(victim, al, RAM_KNOCK_HORIZ, RAM_KNOCK_UP, false)
        LogDebug("Ram - shield-bash knockback", SETTINGS.DEBUG_NPC_ACTIONS)
    end,

    -- Re-assert the Ram's brighter wash (damage stages rebuild the materials and drop it).
    -- The shield is a one-time MATERIAL swap in Visuals, which the damage-stage system leaves alone.
    OnDamageTaken = function(actor)
        GRP.Wash(actor, RAM_WASH_MUL)
    end,

    OnDeath = function(actor)
        -- These cadence tables are keyed by a STRING, which never garbage-collects, so the dying
        -- body has to drop its own keys. (lastRamKnockTick is keyed by VICTIM, not the Ram, so it
        -- deliberately stays.)
        local key = Utils.ActorKey(actor)
        if key then
            lastRamSwingTick[key], ramReleasedFor[key], ramTagClearedFor[key] = nil, nil, nil
            ramInSnow[key] = nil
        end

        AVU.DropLoot(actor, { Pool = {
            { G.SCRAP_KEVLAR, 2 },
            { G.CARBON_PLATING, 1 },
        } })
    end,
}

-- NOTE: the Order shield-trooper variants (Shield Grunt + Shield Embolon, base "Trooper_Shield")
-- moved to AnteNPCs/OrderRook.lua - the Order Rook chassis family lives together there now.

return V
