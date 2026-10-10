-- =======================================================================
-- GATEKEEPER MYSTAGOGUE ("Gatekeeper_Mage")
--   * The Mage Eyes related to this are in AnteNPCs/GK_MageEye.lua which has eye rules
--       (can't switch its beam off, force-gibs itself)
--   * The BEHOLDER's eyes are welded to its shoulders and fired from ITS tick, so that whole set -
--       mage and eyes both - lives in AnteNPCs/GK_MageBeholderHelpers.lua. Decode: AnNotes/AnteNPCs/Beholder.md
--
-- =======================================================================
-- ABILITY MAP - NPC_Gatekeeper_Mage
--   0-3 ALL EMPTY - sets Cooldown_Idle/CombatAbility1-3 but overrides none
--   NOT slots, each on its own path:
--     fireball = Server_DoRangedAttack -> FireballDelay -> l_hand
--     gravity wave = its own overlap + timer
--     MageEye = SpawnMageEye()
--     shield = ShieldCooldown/UpdateShieldState
--     choke grab = melee type 6 (15s cd, DamageType_Drowning)
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local FileIO = require("AnteCore.FileIO")
local Utils = require("AnteUtils.Utils")
local ENUMS = require("AnteData.Enums")
local G = require("AnteData.Items").Global
local AVU = require("AnteUtils.AVUtils")
local H = require("AnteNPCs.GK_MageHelpers")
local BH = require("AnteNPCs.GK_MageBeholderHelpers")

local V = {}

-- Mystagogue Wraps: a rare drop shared by all three mages, once per world (StoryData latch).
local WRAPS = { Chance = 0.03, MinStory = 72 }

-- DropLoot `drops`, with the wraps appended when this kill wins the roll. The latch is set only
-- once DropLoot actually queued the drop (a suppressed or degenerate death returns nil).
local function dropWithWraps(actor, drops)
    local data = STATE.StoryData
    local won = data ~= nil and not data.MystagogueWrapsDropped
        and math.random() < WRAPS.Chance
        -- Lazy require: StoryManager pulls variant defs (load-time cycle).
        and (require("ModuleStory.StoryManager").GetStoryProgress() or 0) >= WRAPS.MinStory
    if won then drops[#drops + 1] = { Row = G.MYSTAGOUGE_WRAPS } end

    if AVU.DropLoot(actor, drops) and won then
        data.MystagogueWrapsDropped = true
        FileIO.SaveStoryData()
        Utils.Log("Mystagogue Wraps dropped by " .. tostring(Utils.GetActorName(actor)) .. " (once per world)")
    end
end


-- =======================================================================
-- BARRIER MAGE
-- A mage that uses Mage Eyes to create an invulnerability shield, instead of a projected shield
--   * Controls up to 2 eyes that channel a beam on it, which drops if all are destroyed
--   * Replaces eyes periodically
--   * Different colored shield (red-ish)
-- =======================================================================

-- Applied AFTER the material swap (can't be def.Tint - that runs before Visuals and gets wiped).
local MYST_TINT_ORANGE = { Color = FVector(3, 2, 0.5), EmissiveColor = FVector(0, 0, 15), Emissive = 25 }   -- cyan-blue eyes (warm is impossible)

V["Barrier Mage"] = {
    Id = 98,
    Base = "Gatekeeper_Mage",
    Assets = H.BARRIER_ASSETS,   -- eye class, beam FX, shell material, portal burst, cast montage

    -- Appearance
    -- Orange robes + no forward shield (the mesh IS the block volume; zeroed on every machine).
    Visuals = function(actor, assets)
        H.StripMageShield(actor)
        H.MystagogueRecolor(actor, "Orange", MYST_TINT_ORANGE)
    end,
    ClientTick = true,   -- clients run OnTick too: its renderer branch drives the sheen

    -- Stats
    BasicStats = {
        HpHead = 350,   -- 550
        HpTorso = 400,   -- 550
        -- WalkSpeed = 90,
        SprintSpeed = 300,   -- 450
        -- MeleeDamage = 50,
        -- RangedDamage = 50,   (the fireball reads this)
    },
    HardMode = {
        BasicStats = { HpHead=450, HpTorso=500, RangedDamage = 75 },
    },

    -- No forward shield: prevent the buff that raises it (Stats zeroes the shield mesh = the block volume)
    DebuffsImmune = { "AI_TurtleMode" },
    Stats = H.BarrierStats,

    -- Triggers
    OnTick = H.BarrierTick,
    OnDamageTaken = H.BarrierHit,   -- tick-independent self-correct (see the helpers)

    OnDeath = function(actor)
        H.BarrierDeath(actor)

        dropWithWraps(actor, { { Pool = {
                { G.MAGE_EYE, 2 },
                { G.DIGITAL_GOLD, 2 },
            } } })
    end,
}


-- =======================================================================
-- ABJURER MAGE
-- A support caster that buffs its squad instead of duelling
-- * Loses most Mage abilities (eye/shield/grab) and shoots a hardlight spear instead of its fireball
-- * THREE buffs on a fixed ABAC rotation, one cast per cadence, combat only. Any of them can pick
--   the mage itself - it is the squad's last patient, not an exception to it:
--     A  shield beam   - tether that refills body shields; goes to the biggest deficit
--     B  shield wall   - lends the Mystagogue's forward plate for a few seconds
--     C  displacement  - warps one of the squad in behind whatever the mage is fighting
-- * [HARD] casts faster and holds the wall longer
-- =======================================================================

-- Applied AFTER the material swap (see MYST_TINT_ORANGE above).
local MYST_TINT_GREEN = { EmissiveColor = FVector(0.2, 4, 0.4), Emissive = 25 }

V["Abjurer Mage"] = {
    Id = 103,
    Base = "Gatekeeper_Mage",
    Assets = H.ABJURER_ASSETS,   -- meditate pose, tether + regen FX, shield class, the lent plate

    -- Appearance
    Tint = { Color = FVector(0.5, 1, 3) },
    -- Green robes + the meditate idle pose.
    Visuals = function(actor, assets)
        H.MystagogueRecolor(actor, "Green", MYST_TINT_GREEN)
        AVU.PlayIdleSequence(actor, ENUMS.Anims.MAGE_MEDITATE, true)
        H.AbjurerShieldShell(actor)   -- its body shield has no mesh of its own to flare
    end,

    -- Stats
    BasicStats = {
        HpHead = 300,       -- 550
        HpTorso = 350,      -- 550
        -- WalkSpeed = 90,
        SprintSpeed = 120,  -- 450
        -- MeleeDamage = 50,
        RangedDamage = 70,
        RangedAttackRange = 2500,   -- 3500
        RangedAttackCooldown = 0,   -- 3 (but the BT has its own hardcoded delay - see the helpers)
        -- Shield = 100
    },
    HardMode = {
        BasicStats = { HpHead=350, HpTorso=400, RangedDamage = 100 },
    },
    DebuffsImmune = { "AI_TurtleMode" },
    Stats = H.AbjurerStats,

    -- Triggers
    OnEnterCombat = H.AbjurerCombat,        -- one ally scan builds this fight's patient roster
    OnExitCombat = H.AbjurerExitCombat,
    OnRangedAttack = H.AbjurerRangedAttack, -- the spear, in place of the blanked fireball
    -- Drives the rotation. A cast that can't fire (displacement with no target) does not consume
    -- its slot, so the ABAC pattern never drifts.
    OnTick = H.AbjurerTick,

    OnDeath = function(actor)
        H.AbjurerDeath(actor)

        dropWithWraps(actor, { { Pool = {
                { G.TRANSCENDIUM, 2 },
                { G.MAGE_EYE, 1 },
                { G.PLUTONIC_BLOOD, 1 },
            } } })
    end,
}


-- =======================================================================
-- BEHOLDER MAGE
-- A mage that spawns with 3 Eyes from a pool of eyes attached above it
--   * Does not attack or use a projected hardlight shield. It instead has a massive personal shield
--   * Picks 3 eyes from a pool. They are invulnerable. It always picks at least one 'Fast eye'
--   * Every 2 seconds an eye attacks. The eye lights up before attacking
--   * Some eyes have different cooldowns, so 'faster' eyes will act more often
--   * HARD MODE - the Mage picks a missing fast eye and makes that its primary attack
-- 
-- Eye colors
--   * Verdant - lobs a corrosive ball that deals (100/150) damage and applies Corrosive. Fast
--   * Amber - fires a fireball that deals (50/75) damage and causes a molotov effect. Fast
--   * Violet - fires a fast violet ball that deals (75/100) psychic damage. Fast
--   * Crimson - fires a laser that deals (120/170) damage. Slow
--   * Azure - fires a slow moving plasma disc that deals 100 damage and stuns on hit. Slow
--   * Rose - spawns a Gatekeeper Peccary. It has stats similar to a Peccary with added health. Very slow.
--            Rose appears half as often
-- Machinery + all six eye kits: AnteNPCs/GK_MageBeholderHelpers.lua
-- =======================================================================

V["Beholder Mage"] = {
    Id = 104,
    Base = "Gatekeeper_Mage",
    Assets = BH.BEHOLDER_ASSETS,   -- eye class, body shield + its shell, the laser component
    SpawnDelay = 200,

    -- Appearance
    BodyScale = 1.15,
    Visuals = BH.BeholderLook,

    -- Stats
    BasicStats = {
        HpHead = 150,   -- 550
        HpTorso = 200,   -- 550
        WalkSpeed = 140,   -- 300
        SprintSpeed = 235,   -- 450
        -- MeleeDamage = 50,
        RangedDamage = 0, 
        HasRangedAttack = false,
        RangedAttackRange = 1,   -- 3500
        -- Shield = 700
    },
    -- [HARD] Ranged attack becomes a random fast eye
    HardMode = {
        BasicStats = {
            HasRangedAttack = true,
            RangedAttackRange = 3500,
            -- Shield 1000
        },
    },
    -- No forward shield: immunise the buff that RAISES it (the helpers zero the mesh).
    DebuffsImmune = { "AI_TurtleMode" },
    TimeDilation = 0.85,   -- slow and deliberate; it is a platform, not a duellist
    Stats = BH.BeholderStats,

    -- Triggers
    OnReady = BH.BeholderReady,           -- pick this Beholder's colours and weld them on
    OnTick = BH.BeholderTick,             -- ONE clock for the whole roster
    OnRangedAttack = BH.BeholderCast,     -- [HARD] the fourth attack, out of the casting hand
    OnExitCombat = BH.BeholderExitCombat, -- the Rose eye's pets go home with the fight

    OnDeath = function(actor)
        BH.BeholderDeath(actor)

        dropWithWraps(actor, { { Pool = {
                { G.MAGE_EYE, 3 },
                { G.TRANSURANIC, 1, Chance = 0.5 },
                { G.LODESTONE_FRAGMENT, 1 },
            } } })
    end,
}


return V
