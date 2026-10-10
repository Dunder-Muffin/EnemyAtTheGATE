-- =======================================================================
-- ORDER INTERFECTOR - variants of the Order's dual-dagger assassin (row "Interfector").
-- Machinery: AnteNPCs/OrderInterfectorHelpers.lua.  Decode notes: AnNotes/AnteNPCs/OrderInterfector.md
--
-- MUST-KNOWS
--   * RANGED (3-knife burst) and MELEE (dual daggers) are both native ubergraph behavior; the
--     knife projectile row is bytecode and can't be re-rowed, only re-tinted via ChangeDamageType.
--   * It's the dodge NPC: EvadesProjectiles=true, staggers read as dodges.
--   * ToggleCombatStateFX swaps FOUR dagger meshes - any recolor/fade must hit all four.
--   * No ability slots are used - the base pawn overrides none of them (dead CombatAbility stubs).
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local ENUMS = require("AnteData.Enums")
local G = require("AnteData.Items").Global
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local H = require("AnteNPCs.OrderInterfectorHelpers")

local V = {}


-- =======================================================================
-- WINTERFECTOR  (Interfector, Id 158)
-- Bright white/cyan frost assassin that blinks around the fight, freezing on every landed hit.
-- Full blink-cycle + freeze decode: AnNotes/AnteNPCs/OrderInterfector.md
--   * [AUTHORITY] blink cycle: 2 regular blinks (fade out, reposition, fade in) then 1 shard-throw
--     blink, on a ~9s cadence. Every landed hit (swipe/knife/shard) freezes the target 2s.
--   * Weak to fire, but immune to its own blue plasma burn.
--   * [RENDERER] whiteout/cyan wash, icicle daggers, warp-mirror puff on a big position jump.
-- =======================================================================

local WINTER_MIRROR_JUMP = 400   -- regular blinks start at 500uu; sprint moves ~105uu/tick

V["Winterfector"] = {
    Id = 158,
    Base = "Interfector",
    Assets = {
        ENUMS.Components.M_ICICLE,                 -- dagger swap (Visuals)
        ENUMS.Anims.INTERFECTOR_THROW_KNIVES,      -- shard-blink throw visual
        ENUMS.Effects.NIAGARA_FLASK_BLIZZARD,      -- exit puff + warp mirror
        -- The freeze now rides the FIRST dagger swipe, which can land before the first blink
        -- warms BLINK_DEPS. The apply is EIGT so a cold load can't deadlock - this is purely
        -- so the opening freeze doesn't hitch.
        ENUMS.BuffObjects.StunnedFrozen,
        ENUMS.Effects.NIAGARA_DEBUFF_FROZEN,
    },
    -- Shard/knife hits must reach OnDealtDamage (projectile damage only dispatches via the
    -- instigator fallback, and hands the PROJECTILE as attacker - H.FreezeOnHit ignores it).
    ProjectileDealtDamage = true,
    ClientTick = true,   -- the warp mirror + wash re-assert

    -- Appearance
    Tint = H.WINTER_TINT,   -- declarative first coat; re-asserted from OnDamageTaken + client tick
    Visuals = function(actor, assets)
        H.IceDaggers(actor)
    end,

    -- Stats
    BasicStats = {
        HpHead = 400,        -- 450
        HpTorso = 500,       -- 450
        -- HpLeftArm/RightArm/LeftLeg/RightLeg = 300,
        -- WalkSpeed = 130,
        SprintSpeed = 900,   -- 1050
        MeleeDamage = 85,    -- 75
        -- MeleeAttackRange = 150,
        RangedDamage = 35, -- 30 (x3),
    },
    HardMode = {
        BasicStats = { HpHead=450, HpTorso=550, MeleeDamage=90, RangedDamage=40 },
        NoAggroAnim = true
    },
    TimeDilation = 0.9,
    -- Frost rows: it is the frost assassin. IgnitedPlasma: blue plasma burn only - plain
    -- Debuff_Ignited is deliberately absent, so real fire still burns it (and still hits x1.5).
    DebuffsImmune = { ENUMS.Debuffs.Frost, ENUMS.Debuffs.Frost2, ENUMS.Debuffs.Frost3,
                      ENUMS.Debuffs.Frost4, ENUMS.Debuffs.Frost5, ENUMS.Debuffs.FlaskBlizzard,
                      ENUMS.Debuffs.SniperRifleIce, ENUMS.Debuffs.IgnitedPlasma },

    -- Triggers
    -- [AUTHORITY] the blink cycle; [RENDERER] the warp mirror + periodic wash re-assert.
    OnTick = function(actor, totalTicks)
        if Utils.IsActorInvalid(actor) then return "REMOVE" end
        if not Utils.IsAuthority() then
            AVU.WarpMirrorTick(actor, ENUMS.Effects.NIAGARA_FLASK_BLIZZARD, WINTER_MIRROR_JUMP,
                ENUMS.SOUNDS.STALACTITE_BREAK, 0.6)
            if totalTicks % 20 == 0 then H.WinterWash(actor) end
            return
        end
        H.BlinkTick(actor, totalTicks)
    end,

    -- [AUTHORITY] Freeze on ANY landed hit (per-victim cooldown; players only).
    OnDealtDamage = H.FreezeOnHit,

    -- [RENDERER] Damage-stage texture updates rebuild the body material and drop the wash.
    OnDamageTaken = function(actor)
        H.WinterWash(actor)
    end,

    OnDeath = function(actor)
        AVU.DropLoot(actor, { Pool = {
            { G.THROWING_SHARD, 10 },
            { G.TACTICAL_SCRAP, 1 },
            { G.DISTILLATION_ENDOTHERMIC, 3 }
        } })
    end,
}


-- =======================================================================
-- PURIFIED INTERFECTOR  (Interfector, Id 159)
-- The cell's holy conversion: HOLY DAMAGE HEALS IT (Holy=0 + a shield refilled by holy hits).
-- Full decode: AnNotes/AnteNPCs/OrderInterfector.md
--   * Melee retyped to Fire_Holy (ignites, ignores armor); native acid knife burst replaced with
--     a bouncing holy disc (bypasses body shields) lobbed every ~4.5s.
--   * [RENDERER] white/gold Purified look, holy shield shell over the body mesh, native daggers.
--   * HasRangedAttack=false does NOT stop the knife burst - BT_Attack_Interfector's ranged
--     branch reads only RangedAttack_OnCooldown. It still throws between discs; pin that bool
--     (see the Peremptor) if that is ever unwanted.
-- =======================================================================

V["Purified Interfector"] = {
    Id = 159,
    Base = "Interfector",
    HardMode = { NoAggroAnim = true },
    Assets = H.PURIFIED_INTERFECTOR_ASSETS,   -- shield kit + FireHoly + IgnitedHoly/HPDamage

    -- Appearance
    Tint = H.PURIFIED_TINT,
    Visuals = function(actor, assets)
        H.AttachHolyShell(actor)
    end,

    -- Stats
    BasicStats = {
        -- HpHead = 450,
        -- HpTorso = 450,
        -- HpLeftArm/RightArm/LeftLeg/RightLeg = 300,
        -- WalkSpeed = 130,
        -- SprintSpeed = 1050,
        MeleeDamage = 85,        -- 75 (and it ignites-holy now)
        -- MeleeAttackRange = 150,
        HasRangedAttack = false, -- the acid knife burst is bytecode - replaced by the disc
        -- Shield = 250, no regen - only holy damage refills it
    },
    -- Its own bounced disc can come home: Holy=0 nulls the damage but a nulled hit still lands
    -- its DEBUFF (snow lesson), so the holy ignites are blocked outright.
    DebuffsImmune = { ENUMS.Debuffs.IgnitedHoly, ENUMS.Debuffs.Ignited },

    Stats = function(actor, opts)
        H.PurifiedStats(actor)
    end,

    -- Triggers
    -- [AUTHORITY] the disc cadence (renderers have no per-tick work for this variant).
    OnTick = function(actor, totalTicks)
        if Utils.IsActorInvalid(actor) then return "REMOVE" end
        if not Utils.IsAuthority() then return "REMOVE" end
        H.DiscTick(actor, totalTicks)
    end,

    -- [AUTHORITY] the holy feed loop (+ wash re-assert through damage-stage rebuilds).
    OnDamageTaken = H.PurifiedHit,

    OnDeath = function(actor)
        AVU.DropLoot(actor, { Pool = {
            { G.TACTICAL_SCRAP, 3 },
            { G.LODESTONE_FRAGMENT, 3 },
        } })
    end,
}


-- =======================================================================
-- PEREMPTOR  (Interfector, Id 180)
-- The Interfector stripped down to one committed attack: a delayed cut.
--   * [AUTHORITY] Inside 10m, on a ~11s cooldown, it backflips clear, settles into a held stance
--     for a 3s windup (1.5s in hard mode), dashes ~15m through its target - and only a beat LATER
--     does everything on that line take the hit. The gap between the pass and the damage is the
--     whole point; the windup is the counterplay.
--   * Knives off and dodges off: the dash is its repositioning move, and a blind backstep in the
--     middle of a committed windup would throw the cut off its line.
--   * Stun/freeze/stagger/fear immune (AVU.CCImmune, bleed left on), so the windup can't be taken
--     away. Slows and knockbacks still land.
--   * Its ordinary swings SLOW: players to 70% speed, other NPCs to a standstill (two different
--     mechanisms - see the handler). So walking away from the wind-up is not free either.
--   * The player hit CANNOT kill - it asks for exactly the gap down to a floor, and every step
--     after that only reduces it. NPCs on the line eat a flat 400, and any hostile body whose
--     head is at or under that is cut in half outright - through a body shield, which the cut
--     breaks on its way in. Players' pets are spared that half of it.
-- Combo decode + why the stance is a slow montage rather than a paused one: the PEREMPTOR banner
-- in AnteNPCs/OrderInterfectorHelpers.lua and AnNotes/AnteNPCs/OrderInterfector.md.
-- =======================================================================

V["Peremptor"] = {
    Id = 180,
    Base = "Interfector",
    Assets = {
        ENUMS.Anims.INTERFECTOR_DODGE_BACK,   -- the backflip
        ENUMS.Anims.INTERFECTOR_MELEE_01,     -- the held stance
        ENUMS.DamageType.Sharp,              -- bleed rows are warmed at windup (H.PEREMPTOR)
        ENUMS.Components.T_WHITE_GENERIC,     -- the daggers' emissive mask (Visuals)
        ENUMS.Components.SM_HELM_MAKESHIFT_NVGS,
    },

    -- Appearance
    -- Not a def.Tint: the four material slots take four different colours, and a Tint block paints
    -- them all the same. The values live at PEREMPTOR_LOOK in the helpers, where the daggers are
    -- self-lit so their gold holds up once they leave the body's glow.
    Visuals = function(actor)
        H.PeremptorLook(actor)
    end,

    -- Stats
    BasicStats = {
        HpHead = 400, --450
        -- HpTorso = 450,
        -- HpLeftArm/RightArm/LeftLeg/RightLeg = 300,
        -- WalkSpeed = 130,
        -- SprintSpeed = 1050,
        MeleeDamage = 75,        -- 75
        -- MeleeAttackRange = 150,
        -- Belt only: this gates the controller's RETALIATION paths, not the knife burst. The BT's
        -- ranged branch never reads it - H.PeremptorStats pins RangedAttack_OnCooldown, which is
        -- the gate that actually holds it shut. See the PEREMPTOR banner in the helpers.
        HasRangedAttack = false,
    },
    HardMode = {
        BasicStats = { MeleeDamage = 90, HpHead=450, HpTorso=500 },
        NoAggroAnim = true
    },
    -- The held stance rides CustomTimeDilation, which is server-local without this.
    MirrorTimeDilation = true,

    Stats = function(actor, opts)
        H.PeremptorStats(actor)
    end,

    -- Triggers
    -- [AUTHORITY] the combo state machine (renderers have no per-tick work for this variant).
    OnTick = function(actor, totalTicks)
        if Utils.IsActorInvalid(actor) then return "REMOVE" end
        if not Utils.IsAuthority() then return "REMOVE" end
        H.PeremptorTick(actor, totalTicks)
    end,

    -- [AUTHORITY] Its swings drag: players to 70% speed, other NPCs to a standstill. Per-victim
    -- gated - see the handler.
    OnDealtDamage = H.PeremptorSlowOnHit,

    OnDeath = function(actor)
        H.PeremptorForget(actor)
        AVU.DropLoot(actor, { Pool = {
            { G.TACTICAL_SCRAP, 2 },
            { G.LODESTONE_FRAGMENT, 2 },
        } })
    end,
}

return V
