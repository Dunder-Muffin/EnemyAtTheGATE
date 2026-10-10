-- =======================================================================
-- GK_DARKLENS - the DarkLens boss sets (Fracture): the CHIEFTAIN, the WITCH and the HEAVY
-- MUST-KNOWS:
--   * Four fights, five helper files: Chieftain (Fallow Patriarch + Phyter escorts) ->
--     GK_DarkLensPatriarchHelpers; Witch (Mother of the Fallow + acolytes) ->
--     GK_DarkLensWitchHelpers; Heavy (Jotun of the Fallow + Fallow Steed) ->
--     GK_DarkLensJotunHelpers; Mage (Magus of the Fallow + Astral add) ->
--     GK_DarkLensMageHelpers. Shared machinery (adoption watcher, death-flag backstop,
--     reset respawn, arena guard) lives in GK_DarkLensHelpers.
--   * DarkLens_Chieftain is a thin skin over Gatekeeper_Chieftain; its only real content is
--     the death flag Fracture_DL_Chieftain_Dead. THE REAL BOSS BODY MUST DIE - never replace
--     it, never let an NPC land the killing blow (helpers carry a set-flag backstop).
--   * NOT spawner-wired: the arena watcher (GK_DarkLensHelpers.Register) adopts each boss by
--     proximity and force-aggros it; a SpawnerData row supersedes once coords are known.
--   * "Gatekeeper Neophyte" IS the Phyter (row Gatekeeper_Phyter). Row "DarkLens_Phyter" is a
--     byte-identical alias no BP class declares - AltBases covers a level-placed spawner using it.
--   * Full per-boss decode: AnNotes/AnteNPCs/DarkLensPatriarch.md, GKDarkLensWitch.md,
--     GKDarkLensJotun.md, GKDarkLensMage.md, GKDarkLensShared.md.
-- =======================================================================
-- ABILITY MAP - NPC_Gatekeeper_Witch_DarkLens (row "DarkLens_Witch") + NPC_Gatekeeper_Witch
--   3 HOVER - the DarkLens class REPLACES the base leap outright (no super): crouch 0.6s ->
--       launch -> Flying -> BT released -> Delay(JetpackDuration) -> divebomb + FlameOnLanding.
--       The dive itself is UNARMED; the landing fire pool is the damage.
--   * CanThrowGrenades=false / DisableGrenades kills EVERY slot on a witch - she has no grenade
--     code, and that flag is what UN-BLOCKS them. Which is what makes it the Mother's WARRIOR
--     ground lever: the only thing that stops the hover, at the cost of the revive. Restored on
--     every other aspect change - see AnNotes/AnteNPCs/GKDarkLensWitch.md ("WARRIOR is grounded").
--   * NOT slots: 10-pellet hitscan shotgun (suppressed via OverrideSoldierFireLogic), kick +
--     its native 1200/200 launch, medic revive, EvadesProjectiles.
-- ABILITY MAP - NPC_Gatekeeper_Heavy_DarkLens (row "DarkLens_Heavy")
--   * NOT slots, and all three are the fight: the hitscan LMG (30-shot burst, spins 0.4s -> 0.1s);
--     the ROCKET-PACK MORTAR, fired by the class's Broadcast_ReloadWeapon override (2 shells 2s
--     apart, so CLIP SIZE is its cadence); the front hardlight Shield, popped on fire and dropped
--     0.75s after it stops, blocking 100% of anything whose HitComponent IS that mesh (geometry,
--     so AoE goes round). Decode: AnNotes/AnteNPCs/GKDarkLensJotun.md.
-- ABILITY MAP - NPC_Mage_DarkLens (row "DarkLens_Mage", DisplayName "Guardian of the Fallow")
--   0-3 ALL EMPTY - inherits NPC_Mage exactly (all four Cooldown_* set, no bodies).
--   * NOT slots, all OFF on the Magus: fireball (HasRangedAttack=false), TurtleMode shield
--     (DebuffsImmune), gravity wave (a pure shove, and this arena is ledges). Only the choke grab
--     (melee type 6, no native throw) survives.
--   * SpawnMageEye() is a no-op here - the seal is DarkLensCombatReady, never Invincible.
--     Full kit decode: AnNotes/AnteNPCs/GKDarkLensMage.md ("The seal" / "Stock kit strip").
-- Case files: memory/anteup2-darklens-decode.md, memory/anteup2-witch-decode.md,
-- memory/anteup2-darklens-heavy-bombardier.md.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local ENUMS = require("AnteData.Enums")
local AVU = require("AnteUtils.AVUtils")
local G = require("AnteData.Items").Global
local H = require("AnteNPCs.GK_DarkLensPatriarchHelpers")
local W = require("AnteNPCs.GK_DarkLensWitchHelpers")
local J = require("AnteNPCs.GK_DarkLensJotunHelpers")
local M = require("AnteNPCs.GK_DarkLensMageHelpers")
local GKW = require("AnteNPCs.GK_WitchHelpers")   -- the acolytes wear their sisters' kits

local V = {}


-- =======================================================================
-- FALLOW PATRIARCH  (the DarkLens Chieftain, remade as an overlook plasma cannon)
--   * Phase 1: pinned at its perch, scripted facing, 2 plasma discs every ~2.5s (dodgeable,
--     ignites - we spawn them ourselves at half the row's speed). Shielded UNBREAKABLE while any
--     of the 3 specials lives within 50m.
--   * Phase 2 (specials dead -> shield shatters): unpins, fights on foot (chase +
--     grab-headbutt), shield permabroken, winds up to 3 discs/~2.1s + 1.2x time dilation,
--     drips one weak every 15s (max 2 alive), stops fixating on props.
--   * Full decode incl. immobiliser choice, facing/sight-cone chain, drip mechanics:
--     AnNotes/AnteNPCs/DarkLensPatriarch.md.
-- =======================================================================

V["Fallow Patriarch"] = {
    Id = 160,
    ImmuneToBackstabs = true,   -- a fight, not a stealth opener
    Base = "DarkLens_Chieftain",
    Assets = {
        ENUMS.Components.SK_GRINDER,
        -- The disc is spawned by us, not the native gun, so its type and that type's debuff have
        -- to be resident here - see the DISC knobs in GK_DarkLensPatriarchHelpers.
        ENUMS.ProjectileClasses.DiscPlasma,
        ENUMS.Components.SM_GRINDER_DISC,
        ENUMS.Effects.EXPLOSION_PLASMA_DISC,
        ENUMS.DamageType.Fire,
        ENUMS.BuffObjects.Ignited,
        ENUMS.BuffObjects.HPDamage,
        ENUMS.SOUNDS.DISC_LAUNCHER_FIRE,
        ENUMS.SOUNDS.GKCHIEF_DL_PHASE2,     -- the flat 2D call at the barrier break (barrierPoll)
        ENUMS.Components.M_LABCOAT_TORII_OPEN,
    },

    -- Appearance
    BodyScale = 1.1,
    Visuals = H.PatriarchVisuals,

    -- Stats (native DT row kept; the fight is the barrier, not a stat wall)
    BasicStats = {
        HpHead = 700, --350
        HpTorso = 900, --450
        -- WalkSpeed = 150,
        -- SprintSpeed = 650,
        MeleeDamage = 130,      -- 85; grab-headbutt ticks 2x this - punishes closing in
        -- MeleeAttackRange = 300,
        RangedDamage = 50,      -- 65 (per plasma disc)
        -- Shield = 350; the barrier phases drive it (99999 raised, 0 permabroken)
    },
    -- The hard TimeDilation is NOT here: PatriarchStats writes dilation itself on every
    -- (re)mutation, so it owns both phases' values (PATR_TDI in the helpers).
    HardMode = {
        BasicStats = {
            HpHead = 1000,
            HpTorso = 1200,
            MeleeDamage = 175,
            RangedDamage = 90,
        },
    },
    Stats = H.PatriarchStats,
    OnReady = H.PatriarchReady,

    -- Triggers
    OnTick = H.PatriarchTick,
    OnEnterCombat = H.PatriarchEnterCombat,
    OnRangedAttack = H.PatriarchRangedAttack,
    OnDamageTaken = H.PatriarchDamaged,
    OnDeath = H.PatriarchDeath,
    -- Same anti-snipe rule as the Mother: a hit from outside the arena is ignored.
    DamageGate = H.PatriarchDamageGate,
}


-- =======================================================================
-- DARKLENS PHYTER  (the 3 "special" escorts - they ARE the boss's barrier)
--   * 3 spawn with the DarkLens Chieftain to sustain its invuln shield; red pointlight marks it.
--   * ForceSpawnFX restores the portal spawn-in that Gatekeeper_Grunt (its base) turns off by
--     default - see AnNotes/AnteNPCs/DarkLensPatriarch.md ("The Gatekeeper spawn-in is a portal burst").
-- =======================================================================

V["DarkLens Phyter"] = {
    Id = 161,
    ImmuneToBackstabs = true,   -- a fight, not a stealth opener
    Base = "Gatekeeper_Phyter",
    AltBases = { "DarkLens_Phyter" },
    Assets = {},

    -- Appearance
    ForceSpawnFX = true,
    Visuals = H.SpecialVisuals,

    -- Stats
    BasicStats = {
        HpHead = 200, --250,
        HpTorso = 200, --300,
        HpLeftArm = 100,     -- 300
        HpRightArm = 100,    -- 300
        HpLeftLeg = 100,     -- 300
        HpRightLeg = 100,    -- 300
        -- WalkSpeed = 130,
        SprintSpeed = 400,
        -- MeleeDamage = 100,
        RangedDamage = 30, --50
        -- Shield = 225
    },
    HardMode = {
        BasicStats = {
            HpHead = 300,
            HpTorso = 300,
            SprintSpeed = 600,   -- 600 native
            RangedDamage = 40,
        },
    },
    Stats = H.SpecialStats,

    -- Triggers
    OnTick = H.MinionTick,
    OnDeath = H.MinionDeath,
}


-- =======================================================================
-- WEAK PHYTER  (the 7 chaff - "a neophyte at half health/shields")
--   * Reduced hp, shield and damage, slow attack. Deliberately NO ForceSpawnFX - unlike the
--     specials, these arrive in numbers (7 on the roster wave, then one every 15s), so a portal
--     burst per body is just noise. Also the Patriarch's phase-2 drip body (GK_DarkLensPatriarchHelpers).
-- =======================================================================

V["Weak Phyter"] = {
    Id = 162,
    ImmuneToBackstabs = true,   -- a fight, not a stealth opener
    Base = "Gatekeeper_Phyter",
    AltBases = { "DarkLens_Phyter" },
    Assets = {},

    -- Appearance
    Visuals = H.WeakVisuals,
    TimeDilation = 0.8,

    -- Stats
    BasicStats = {
        HpHead = 100,        -- 250
        HpTorso = 125,       -- 300
        HpLeftArm = 25,     -- 300
        HpRightArm = 25,    -- 300
        HpLeftLeg = 25,     -- 300
        HpRightLeg = 25,    -- 300
        -- WalkSpeed = 130,
        SprintSpeed = 300, --600
        MeleeDamage = 80,    -- 100
        RangedDamage = 30,   -- 50
        RangedAttackCooldown = 5,   -- 1; belt for the WeakStats live-field write
        -- Shield = 75   -- 225
    },
    -- RangedAttackCooldown is the same belt as above - the live number is WEAK_RANGED_CD in
    -- GK_DarkLensPatriarchHelpers, which hardens itself.
    HardMode = {
        BasicStats = {
            HpHead = 150,
            HpTorso = 200,
            SprintSpeed = 400,
            RangedAttackCooldown = 3,
        },
    },
    Stats = H.WeakStats,

    -- Triggers
    OnTick = H.MinionTick,
    OnDeath = H.MinionDeath,
}


-- =======================================================================
-- MOTHER OF THE FALLOW  (the DarkLens Witch, remade as an aspect-channeller)
--   * Channels one of three aspects (Warrior/Storm/Plague), swapping on aggro and on every
--     hover landing; each change holds her idle 3s (the open window). The aspect drives her
--     gun, kick rider, landing eruption, and which acolyte gates in (one per change, up to 3).
--   * Native kit kept: hover, kick (1200/200 launch, trimmed by counter-impulse), medic revive -
--     except as WARRIOR, which is held on the ground and so gives up both. Storm throws shock
--     grenades on a ground clock; Plague fires slowly and leans on clouds + summons instead.
--     Full decode: AnNotes/AnteNPCs/GKDarkLensWitch.md.
-- =======================================================================

V["Mother of the Fallow"] = {
    Id = 164,
    ImmuneToBackstabs = true,   -- a fight, not a stealth opener
    Base = "DarkLens_Witch",
    -- PRELOAD: what the FIRST aspect change needs whichever one it is (the ritual-dance montage),
    -- plus the fireball class and her hat. The three kits are warmed per change and at every
    -- takeoff - a def.Assets preload does not pin, and the hover is the lead time.
    Assets = {
        ENUMS.Anims.GKWITCH_DANCE_RITUAL,
        ENUMS.ProjectileClasses.MageFireball,
        ENUMS.Components.SM_WITCH_HAT,
    },

    -- Appearance
    BodyScale = 1.15, 
    Visuals = W.MotherVisuals,
    TimeDilation = 0.9,

    -- Stats
    BasicStats = {
        HpHead = 700,  -- 500
        HpTorso = 900, -- 500
        -- WalkSpeed = 200,
        SprintSpeed = 360,   -- 600;
        MeleeDamage = 125,   -- 50;
        RangedDamage = 40,   -- 25
        -- Shield = 150
    },
    HardMode = {
        BasicStats = {
            HpHead = 900, HpTorso = 1200, MeleeDamage = 175, SprintSpeed = 440
        },
    },
    Stats = W.MotherStats,

    -- Triggers
    OnTick = W.MotherTick,
    OnEnterCombat = W.MotherEnterCombat,     -- first aspect + first acolyte
    OnJetpack = W.MotherJetpack,             -- deliberate takeoff: PICKS the next aspect + drives
                                             --   the landing watcher (the cycle lives here)
    OnLanded = W.MotherLanded,               -- fast path only - the watcher covers a missed hook
    OnRangedAttack = W.MotherRangedAttack,   -- Warrior: shotgun grounded, fireballs airborne
    OnMeleeSwing = W.MotherMeleeSwing,       -- Warrior's kick fireball
    OnMeleeImpact = W.MotherMeleeImpact,     -- Storm's kick nova
    OnDeath = W.MotherDeath,
    -- Hits thrown in from outside her arena do nothing (it is open to fire from well outside).
    -- Per-hit, so it never fights whatever else owns Invincible.
    DamageGate = W.MotherDamageGate,
}


-- =======================================================================
-- ACOLYTES  (weakened Witch variants - reduced HP, half shield, slower, no loot; one per aspect)
--   * Plague doesn't throw pestilences or bee clouds
--   * Kicks are also dampened to make platform deaths less common
-- =======================================================================

-- Speeds are cut against the TDI rise, which already buys back some pace.
local ACOLYTE = {
    TDI         = 1,
    Sprint      = 450,   -- 600 base
    SprintMelee = 550,   -- the Warrior brawler still has to reach you
}

local ACOLYTE_HP = {
    HpHead   = 200,   -- 250
    HpTorso  = 200,   -- 250
    HpLeftArm  = 200, -- 250
    HpRightArm = 200, -- 250
    HpLeftLeg  = 200, -- 250
    HpRightLeg = 200, -- 250
}

V["Warrior Acolyte"] = {
    Id = 165,
    ImmuneToBackstabs = true,   -- a fight, not a stealth opener
    Base = "Gatekeeper_Witch",
    Assets = GKW.WARRIOR_ASSETS,

    -- Appearance
    Visuals = W.WarriorAcolyteLook,

    -- Stats (keeps the native shotgun - the kick fireball is its tell)
    BasicStats = {
        HpHead = ACOLYTE_HP.HpHead,         HpTorso = ACOLYTE_HP.HpTorso,
        HpLeftArm = ACOLYTE_HP.HpLeftArm,   HpRightArm = ACOLYTE_HP.HpRightArm,
        HpLeftLeg = ACOLYTE_HP.HpLeftLeg,   HpRightLeg = ACOLYTE_HP.HpRightLeg,
        SprintSpeed = ACOLYTE.SprintMelee,   -- 600
        MeleeDamage = 30,   -- 50
        -- Shield = 150
    },
    TimeDilation = ACOLYTE.TDI,
    MirrorTimeDilation = true,
    Stats = W.WarriorAcolyteStats,

    -- Triggers
    OnMeleeSwing = W.WarriorAcolyteSwing,
    OnMeleeImpact = W.WarriorAcolyteImpact,   -- the family kick profile (short back + up)
    OnDeath = W.WarriorAcolyteDeath,
}

V["Storm Acolyte"] = {
    Id = 166,
    ImmuneToBackstabs = true,   -- a fight, not a stealth opener
    Base = "Gatekeeper_Witch",
    Assets = GKW.STORM_ASSETS,

    -- Appearance
    Visuals = W.StormAcolyteLook,

    -- Stats
    BasicStats = {
        HpHead = ACOLYTE_HP.HpHead,         HpTorso = ACOLYTE_HP.HpTorso,
        HpLeftArm = ACOLYTE_HP.HpLeftArm,   HpRightArm = ACOLYTE_HP.HpRightArm,
        HpLeftLeg = ACOLYTE_HP.HpLeftLeg,   HpRightLeg = ACOLYTE_HP.HpRightLeg,
        SprintSpeed = ACOLYTE.Sprint,   -- 600
        MeleeDamage = 30,    -- 50
        RangedDamage = 25,   -- 20/pellet base (one bolt per attack)
        -- Shield = 150
    },
    TimeDilation = ACOLYTE.TDI,
    MirrorTimeDilation = true,
    Stats = W.StormAcolyteStats,

    -- Triggers
    OnRangedAttack = GKW.StormRangedAttack,   -- the suppressed shotgun's replacement bolt
    OnMeleeImpact = W.StormAcolyteImpact,     -- kick profile + the nova on a connecting kick...
    OnJetpack = GKW.StormJetpack,             -- ...and the nova again on a deliberate takeoff
    OnDeath = W.StormAcolyteDeath,
}

V["Plague Acolyte"] = {
    Id = 167,
    ImmuneToBackstabs = true,   -- a fight, not a stealth opener
    Base = "Gatekeeper_Witch",
    Assets = GKW.PLAGUE_ASSETS,

    -- Appearance
    Visuals = W.PlagueAcolyteLook,

    -- Stats
    BasicStats = {
        HpHead = ACOLYTE_HP.HpHead,         HpTorso = ACOLYTE_HP.HpTorso,
        HpLeftArm = ACOLYTE_HP.HpLeftArm,   HpRightArm = ACOLYTE_HP.HpRightArm,
        HpLeftLeg = ACOLYTE_HP.HpLeftLeg,   HpRightLeg = ACOLYTE_HP.HpRightLeg,
        SprintSpeed = ACOLYTE.Sprint,   -- 600
        MeleeDamage = 30,    -- 50
        RangedDamage = 20,   -- 20/pellet base (one hard-homing quill per attack)
        -- Shield = 150
    },
    TimeDilation = ACOLYTE.TDI,
    MirrorTimeDilation = true,
    -- The Mother's landing cloud must never sting her own acolyte (faction already covers it).
    DebuffsImmune = { ENUMS.Debuffs.BeeSwarm },
    Stats = W.PlagueAcolyteStats,

    -- Triggers
    OnRangedAttack = GKW.PlagueRangedAttack,   -- the suppressed shotgun's replacement quill
    OnMeleeImpact = W.PlagueAcolyteImpact,     -- the family kick profile (short back + up)
    OnDeath = W.PlagueAcolyteDeath,
}

-- =======================================================================
-- JOTUN OF THE FALLOW  (the DarkLens Heavy, remade as a mounted siege platform)
--   * Phase 1: the Jotun is invulnerable (red shield); its mount must be killed. Kite and take
--     cover. Jotun has a short clip giving windows to attack.
--   * Phase 2: once the steed dies, the Jotun spawns 2 Artillery Bots and continues on foot.
--     Full decode: AnNotes/AnteNPCs/GKDarkLensJotun.md.
-- =======================================================================

V["Jotun of the Fallow"] = {
    Id = 169,
    ImmuneToBackstabs = true,   -- a fight, not a stealth opener
    Base = "DarkLens_Heavy",
    Assets = {
        ENUMS.NpcClasses["Peccary_Armored"],
        AVU.BODYSHIELD_CLASS,
        ENUMS.Components.M_GKHEAVY_TORSO_WHITE,
        ENUMS.Components.M_GKHEAVY_HELMET_WHITE,
        ENUMS.Components.M_GKHEAVY_LEGS_WHITE,
        ENUMS.Components.M_GKHEAVY_FABRIC_WHITE,
        ENUMS.Components.T_GKHEAVY_TORSO_WHITE,
        ENUMS.Components.T_GKHEAVY_HELMET_WHITE,
        ENUMS.Components.T_GKHEAVY_HELMET_EM_WHITE,
        ENUMS.Components.T_GKHEAVY_LEGS_WHITE,
        ENUMS.Components.T_GKHEAVY_FABRIC_WHITE,
    },

    -- Appearance
    Visuals = J.JotunVisuals,


    -- Stats (native DT row kept: 550 a limb, weak Holy+Acid, resist Blunt/Fire/Sharp/Bullet/Laser
    -- and IMMUNE to its own Explosive.GKHeavy. The head/torso/limb split below is the ask; if it
    -- does not move the live limbs, NpcResistances is the fallback lever on GK bases.)
    BasicStats = {
        HpHead = 1500,       -- 550
        HpTorso = 3000,      -- 550
        HpLeftArm = 200,     -- 550
        HpRightArm = 200,    -- 550
        HpLeftLeg = 200,     -- 550
        HpRightLeg = 200,    -- 550
        -- WalkSpeed = 200,
        -- SprintSpeed = 330,
        -- MeleeDamage = 50,
        RangedDamage = 55, -- 35
        -- Shield = 800; the barrier phases drive it (99999 raised, 0 permabroken)
    },
    MirrorTimeDilation = true,   -- the reload speed-up rides CustomTimeDilation (server-local)
    Stats = J.JotunStats,
    OnReady = J.JotunReady,

    -- Triggers
    OnTick = J.JotunTick,
    OnEnterCombat = J.JotunEnterCombat,   -- drag the steed in too
    OnReload = J.JotunReload,             -- speed the reload; the mortar rides the native reload
    OnDeath = J.JotunDeath,
    -- Same anti-snipe rule as the other two: a hit from outside the arena is ignored.
    DamageGate = J.JotunDamageGate,
}


-- =======================================================================
-- FALLOW STEED  (the Jotun's mount - killing it IS phase 1)
--   * A slow, wide-turning armoured peccary. Peccary_Armored has no charge (natively empty) but
--     a 400x aggro-magnet priority, so it commits to walking you down.
--   * 500-point shield over its head/torso pools, doubly weak to acid+electricity,
--     near-immune to explosives.
--   * Can never damage an NPC (DamageToNPCs 0): the boss must only ever die to a player, or its
--     world flag never fires.
-- =======================================================================

V["Fallow Steed"] = {
    Id = 170,
    ImmuneToBackstabs = true,   -- a fight, not a stealth opener
    Base = "Peccary_Armored",
    Assets = {
        AVU.BODYSHIELD_CLASS,
        ENUMS.Components.M_ENERGY_SHIELD,
        ENUMS.Anims.PECCARY_MELEE, 
    },

    -- Appearance
    BodyScale = 1.75,
    NavRadius = AVU.NATIVE_NAV_RADIUS.Peccary, -- Shrink the NavRadius for pathing
    Tint = {
        Color = FVector(5, 5, 15),
        EmissiveColor = FVector(0.5, 2, 6),
        Emissive = 50,
    },
    Visuals = J.SteedLook,

    -- Stats
    BasicStats = {
        HpHead = 2400,    -- 160
        HpTorso = 1600,    -- 160
        WalkSpeed = 250,     -- 200
        SprintSpeed = 450,   -- 900
        MeleeDamage = 250,    -- 50
        -- MeleeAttackRange = 300,
        -- Shield = 500
    },
    -- Declared HERE so the pipeline's faction step lands BEFORE OnReady's weld - otherwise nearby
    -- Gatekeepers shoot the mount during the ~1s weld window. The weld re-copies the live
    -- boss.Faction as the confirm.
    Faction = 6,   -- Gatekeepers/Robots
    Stats = J.SteedStats,
    OnReady = J.SteedReady,

    -- Triggers
    OnMeleeSwing = J.SteedSwing,   -- stamp; the tick fires the release valve
    OnTick = J.SteedTick,

    OnDeath = function(actor)
        J.SteedDeath(actor)   -- THE phase transition: dismount + shatter the barrier

        AVU.DropLoot(actor, {
            { Pool = {
                { G.MAGNETIC_ALLOY, 2 },
                { G.MILITARY_ELEC, 4 },
            }, Radius = 125 },
        })
    end,
}


-- =======================================================================
-- MAGUS OF THE FALLOW  (the DarkLens Mage - the miniboss in progress)
--   * CC-immune, permanently immobile (Patriarch pin treatment, scripted facing). Native kit:
--     only the gravity wave survives. Ghost-bolt (~2s cadence, 75 Electric) is the filler attack;
--     fireball volley (~15s, area denial) and force choke (~30s, grab+reel) are scripted.
--   * Eye beam (~24s): chases a random player with a slow laser; crossed = 90 + plasma ignite.
--   * PHASES key off DAMAGE DEALT (the one aim-independent meter): volley+beam -> astral hold 1
--     at half the combined pool (invuln) -> +choke -> astral hold 2 at a full pool (volley only)
--     -> endgame at x0.6 cooldowns. Head/torso hold hard floors (66%/33%) until endgame as the
--     death guard. HARD: bigger pools, the choke from phase 1, a harder volley and a faster beam.
--   * Invuln-until-flag is NATIVE (DarkLensCombatReady, never write Invincible on this base).
--     Replaces the game's Guardian; respawns 3 days after every kill, no story gate. /dlreset magus.
--   * This row ships HasDBNOState=true (Gatekeeper_Mage's is false), so a "kill" in testing may
--     be a knockdown first. Full decode: AnNotes/AnteNPCs/GKDarkLensMage.md.
-- =======================================================================

V["Magus of the Fallow"] = {
    Id = 171,
    ImmuneToBackstabs = true,   -- a fight, not a stealth opener
    Base = "DarkLens_Mage",
    Assets = M.MAGUS_ASSETS,

    -- Appearance 
    Visuals = M.MagusVisuals,
    LaserStyle = M.BEAM_STYLE,

    DebuffsImmune = { "AI_TurtleMode" },
    BasicStats = {
        HpHead = M.HP_HEAD,
        HpTorso = M.HP_TORSO,
        HpLeftArm = M.HP_LIMB,    -- 450 base;
        HpRightArm = M.HP_LIMB,
        HpLeftLeg = M.HP_LIMB, 
        HpRightLeg = M.HP_LIMB,
        -- WalkSpeed = 150, 
        -- SprintSpeed = 4000,
        -- MeleeDamage = 85,
        -- RangedDamage = 65,
        HasRangedAttack = false,   -- attack is scripted (MagusTick)
    },
    -- The pools MUST match M.HP_*_HARD: the phase machine derives its floors and its
    -- damage-dealt transitions from those, so a mismatch here desyncs the fight from its statline.
    -- Hard mode also opens the choke in phase 1 and sharpens the volley/beam - all in the helpers.
    HardMode = {
        BasicStats = {
            HpHead = M.HP_HEAD_HARD,
            HpTorso = M.HP_TORSO_HARD,
        },
    },
    ClientTick = true,   -- clients mirror the astral-hold shell themselves
    Stats = M.MagusStats,
    OnReady = M.MagusReady,

    -- Triggers
    OnTick = M.MagusTick,
    OnDamageTaken = M.MagusDamaged,    -- the phase-floor clamp (deferred one beat per hit)
    OnDeath = M.MagusDeath,
    -- Untouchable during an astral hold. Per-hit, so it never fights the native seal.
    DamageGate = M.MagusDamageGate,
}


-- =======================================================================
-- ASTRAL MAGUS  (the phase add - the boss's spirit, and the hold's health bar)
--   * A washed-cyan, half-translucent Mystagogue in the meditate pose, gliding slowly. Immune
--     to everything physical (NpcResistances, Exor Wraith recipe), weak to Holy. Kill it to end
--     the hold early; collapses on its own after 30s.
--   * Only attack: the scripted ghost-bolt every ~2s (same bolt its Magus fires), bare, no tell.
--     CC-immune; dodges via a scripted glide-hop (montage dodges are dead in this pose).
--   * Front shield / gravity wave / choke / native eye all stripped. No loot, no corpse.
--     Full decode: AnNotes/AnteNPCs/GKDarkLensMage.md ("Astral add").
-- =======================================================================

V["Astral Magus"] = {
    Id = 172,
    ImmuneToBackstabs = true,   -- a fight, not a stealth opener
    Base = "Gatekeeper_Mage",
    Assets = M.ASTRAL_ASSETS,
    BodyScale = 1.05,

    -- Appearance
    Visuals = M.AstralVisuals,
    ClientTick = true,   -- clients re-assert the spirit look + meditate pose themselves

    -- Stats
    -- The buff that RAISES the front shield; StripMageKit zeroes the mesh, this blocks re-arm.
    DebuffsImmune = { "AI_TurtleMode" },
    BasicStats = {
        HpHead = 350,        -- 550
        HpTorso = 450,       -- 550
        HpLeftArm = 25,     -- 300
        HpRightArm = 25,    -- 300
        HpLeftLeg = 25,     -- 300
        HpRightLeg = 25,    -- 300
        WalkSpeed = 150,     -- 90
        SprintSpeed = 200,   -- 450
        -- MeleeDamage = 50,
        HasRangedAttack = false,   -- the ghost-bolt is scripted (AstralTick); BT ranged off
    },
    HardMode = { BasicStats = { HpHead = 400, HpTorso = 600 } },
    Stats = M.AstralStats,

    -- Triggers
    OnTick = M.AstralTick,
    OnDamageTaken = M.AstralDamaged,   -- immune-hit shield-break ping + the glide-hop dodge
    OnDeath = M.AstralDied,
}


return V
