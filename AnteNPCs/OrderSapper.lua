-- =======================================================================
-- Order Sapper variants  (base "Grunt_Sapper" = NPC_Sapper -> NPC_Soldier_Grunt subclass)
--
-- MUST-KNOWS
--   * It wears the LabRat mesh but is a GRUNT underneath, so it inherits the Order grenade
--     ability and the burst plumbing.
--   * On top of that it overrides ranged with a ROCKET (gated by HasRocket + CurrentAmmoCount,
--     which counts 2 ROCKETS, not bullets), spams the grenade (Cooldown_CombatAbility1 = 0.1),
--     and adds a KAMIKAZE charge on slot 2.
--   * [AUTHORITY] The throw can't be STOPPED, only REDIRECTED: GrenadeData.RowName IS the
--     projectile, so repointing that row makes the native throw hurl whatever you point it at.
--     See the helpers file.
--
-- ABILITY MAP - NPC_Sapper (row "Grunt_Sapper")
--   0 Idle    - none
--   1 GRENADE - inherited grunt throw via Broadcast_ThrowGrenade -> GrenadeData. NOT stoppable by
--       cooldown (BTT_DoCombatAbility ignores it); redirect it instead.
--   2 KAMIKAZE- Broadcast_CombatAbility2: path-check -> equip montage (primes two grenades in-hand)
--       -> KamikazeActive=true -> charges the target -> Detonate (KamikazeDamage=1200 radial).
--       Fire it by hand with actor:Broadcast_CombatAbility2(); tune via actor.KamikazeDamage.
--   3 ROCKET  - Broadcast_CombatAbility3 -> Equip_Launcher -> HasRocket=true -> the overridden
--       Server_DoRangedAttack fires the rocket. H.StripRocket pins it off.
--   NOT a slot: melee knocks the target back (ScaledLaunchCharacter dir*400 / Z250).
--
--   * The Sapper is the ONE Order soldier that overrides Server_DoRangedAttack, so its
--     def.OnRangedAttack hook is on NPC_Sapper's own copy, not the shared soldier path - a real
--     PRE hook, firing as the rocket leaves. def.OnThrow and def.OnMeleeSwing are the eager
--     NPC_Base multicasts.
--   * [AUTHORITY] The KAMIKAZE can refuse to start: Broadcast_CombatAbility2 opens with a
--     synchronous path solve and silently ends the ability on a partial or invalid path. Anything
--     that halts the BT to make room for the charge must be able to hand it back - see the
--     KAMIKAZE LOCKDOWN note in the helpers.
--
-- Machinery: AnteNPCs/OrderSapperHelpers.lua
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local G = require("AnteData.Items").Global
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local H = require("AnteNPCs.OrderSapperHelpers")

local V = {}


-- =======================================================================
-- SUPER SAPPER
-- The plain Grunt_Sapper, escalated - it keeps every native move and gets more out of each
-- * Its rocket comes in pairs: a second one a second later, fired from the same kneel
-- * Sometimes throws a three-grenade barrage instead of a single frag
-- * Melee is a double punch that detonates a grenade in each fist, the second blowing the target
--     away and the sapper back the other way
-- =======================================================================

V["Super Sapper"] = {
    Id = 185,
    Base = "Grunt_Sapper",
    Assets = H.SUPER_ASSETS,   -- rocket + frag classes, the barrage montage, blast FX and type

    -- Appearance
    Tint = { Color = FVector(1.4, 0.9, 0.5) },
    Visuals = H.SuperLook,

    -- Stats
    BasicStats = {
        HpHead  = 350,   -- 240
        HpTorso = 550,   -- 400
        -- WalkSpeed = 130,
        SprintSpeed = 650,   -- 600
        MeleeDamage = 40,   -- 95; the two detonations are the real payload
        -- RangedDamage = 35,  (the rockets carry their own damage)
    },
    HardMode = { NoAggroAnim = true, BasicStats = { HpHead = 450, HpTorso = 700 } },
    Stats = function(actor, opts)
        H.SuperLoadout(actor)
    end,

    -- Triggers
    OnRangedAttack = H.SuperRocket,   -- PRE: books the follow-up rocket and holds the kneel
    OnThrow = H.SuperThrow,           -- rolls for the three-grenade barrage
    OnMeleeSwing = H.SuperPunch,
    OnTick = H.SuperTick,             -- owns the kneel hold and the melee release valve

    OnDeath = function(actor)
        if Utils.IsActorInvalid(actor) then return end
        H.SuperDeath(actor)

        AVU.DropLoot(actor, { Pool = {
            { G.FRAG_GRENADE, 2 },
            { G.DETONATION_CORD, 2 },
            { G.PETN, 3 },
            { G.PLASTIC_SCRAP, 8 },
            { G.MAGNETIC_ALLOY, 2 },
            { G.TRANSURANIC, 1 },
            { G.MONEY, 4 },
        }, Count = 3, Radius = 90 })
    end,
}


-- =======================================================================
-- MAD RAT
-- A crazed Sapper that throws flasks instead of grenades or rockets
-- * Periodically throws a slow moving spread of megaton flasks
-- * Melee is a two-beat punch: a flask smashed in each fist, the second one blowing both bodies apart
-- * Kamikaze charge blast is replaced by dropping several flasks - in a ring around the corpse
-- * [HARD] tougher, and every flask it owns hits harder: bigger megatons on a shorter fuse and a
--     twitchier throw rhythm. It is also carrying twice the load, so it fights twice as long before
--     spending itself and leaves twice the flasks when it does
-- =======================================================================

V["Mad Rat"] = {
    Id = 116,
    Base = "Grunt_Sapper",
    Assets = H.MADRAT_ASSETS,   -- worn vials, throw + backstep montages, the megaton projectile

    -- Appearance
    Tint = { Color = FVector(2, 0.35, 13) },
    Visuals = function(actor, assets)
        H.MadDress(actor)
    end,

    -- Stats
    BasicStats = {
        HpHead  = 240,   -- 240
        HpTorso = 400,   -- 400
        -- WalkSpeed = 130,
        SprintSpeed = 500,   -- 600
        -- MeleeDamage = 95,
        -- RangedDamage = 35,  (flasks carry their own damage)
    },
    -- Hard mode's behaviour tuning (megatons, throw rhythm, kamikaze scatter) lives in MAD_HARD, Helpers.
    HardMode = { NoAggroAnim = true, BasicStats = { HpHead = 350, HpTorso = 450 } },
    TimeDilation = 1.3,
    MirrorTimeDilation = true,   -- so the heavy's slow-mo + the throw-rhythm TDI show on clients
    Stats = function(actor, opts)
        H.MadLoadout(actor)
        AVU.HideForArrival(actor)   -- OnReady's portal reveals it; here so it never stands visible first
    end,

    -- Triggers
    OnReady = function(actor) AVU.PortalArrival(actor) end,   -- yellow rift + the step-out montage
    OnTick = H.MadTick,
    OnThrow = H.MadThrow,          -- the twitchy throw-rhythm rides each native throw
    OnMeleeSwing = H.MadPunch,     -- two flasks smashed into the target, then the shove

    OnDeath = function(actor)
        if Utils.IsActorInvalid(actor) then return end

        -- Alchemist loot pile (3 of the pool); its location is where the flask payload lands.
        local loc = AVU.DropLoot(actor, {
            { Pool = {
                { G.FLASK_CHARGING, 2 },
                { G.FLASK_PORTAL, 1 },
                { G.FLASK_RESTORATIVE, 1 },
                { G.FLASK_RESTORATIVE, 2 },
                { G.FLASK_UNSTABLE, 3 },

                { G.TINCTURE_ANTIHEAT, 1 },
                { G.TINCTURE_BRAINPOWER, 2 },
                { G.TINCTURE_CURATIVE, 1 },
                { G.TINCTURE_ELECTRIFYING, 1 },
                { G.TINCTURE_GIGANTO, 1 },
                { G.TINCTURE_PHASING, 1 },
                { G.TINCTURE_RESTORATIVE, 1 },
                { G.TINCTURE_RESTORATIVE, 2 },
                { G.TINCTURE_SPEEDY, 1 },

                { G.COATING_ACID, 1 },
                { G.COATING_BOUNCE, 1 },
                { G.COATING_FOGGY, 1 },
                { G.COATING_HOLY, 1 },
                { G.COATING_REFORGING, 1 },
                { G.COATING_SOMNIVOROUS, 1 },
            }, Count = 2, Radius = 90 },
            { Pool = {
                { G.DIGITAL_ORE, 2 },
                { G.BLACK_GUNK, 2 },
                { G.MAGNETIC_ALLOY, 1 },
                { G.LODESTONE_FRAGMENT, 1 },
                { G.NEUTRINO_MAPPER, 1 },
            }, Count = 2, Radius = 90 },
        })

        H.MadDeathPayload(actor, loc)
    end,
}


-- =======================================================================
-- ROCKET RAT
-- * Doesn't shoot rockets, instead rocket jumps and rains grenades while midair
-- * Only jumps at a target it can see
-- * Rocket jump does a knockback
-- * Spawn is jumping through a portal (like Hasta Tria)
-- * [HARD] tougher, jumps more often, rains five grenades instead of three, and the takeoff
--     shockwave becomes the real threat - wider, twice the damage, half again the shove
-- =======================================================================

V["Rocket Rat"] = {
    Id = 118,
    Base = "Grunt_Sapper",
    Assets = H.ROCKETRAT_ASSETS,   -- explosion FX, frag class, launcher montage, blunt damage type

    -- Appearance
    Tint = { Color = FVector(2, 0.25, 0.1) },
    Visuals = function(actor, assets)
        AVU.SetReplicatedProp(actor, "VoicePitch", 0.7)
    end,

    -- Stats
    BasicStats = {
        HpHead  = 250,   -- 240
        HpTorso = 350,   -- 400
        -- WalkSpeed = 130,
        -- SprintSpeed = 600,
        MeleeDamage = 70,   -- 95
        -- RangedDamage = 35,
        -- Grenades: 4x70, 7x70
    },
    -- Hard mode's behaviour tuning (jump cadence, frag count, shockwave) lives in RJ_HARD, Helpers.
    HardMode = { NoAggroAnim = true, BasicStats = { HpHead = 350, HpTorso = 400 } },
    TimeDilation = 1.2,
    MirrorTimeDilation = true,   -- so the pre-jump TDI flourish shows on clients
    -- Ammo stays full so it never hits the out-of-rockets kamikaze - the jump IS its ranged attack,
    -- so H.RocketLoadout suppresses the shot itself instead of starving it of ammo.
    Stats = function(actor, opts)
        H.RocketLoadout(actor)
        AVU.HideForArrival(actor)   -- OnReady's portal reveals it; here so it never stands visible first
    end,

    -- Triggers
    OnReady = function(actor) AVU.PortalArrival(actor) end,   -- yellow rift + the step-out montage
    OnTick = H.RocketTick,

    OnDeath = function(actor)
        if Utils.IsActorInvalid(actor) then return end
        H.RocketDeathCleanup(actor)

        AVU.DropLoot(actor, { Pool = {
            { G.FRAG_GRENADE, 1 },
            { G.FRAG_GRENADE, 1 },
            { G.MAGNETIC_ALLOY, 2 },
            { G.DETONATION_CORD, 1 },
            { G.PLASTIC_SCRAP, 8 },
            { G.PETN, 1 },
            { G.PETN, 1 },
            { G.TRANSURANIC, 1 },
            { G.MONEY, 3 },
        }, Count = 3, Radius = 90 })
    end,
}

return V
