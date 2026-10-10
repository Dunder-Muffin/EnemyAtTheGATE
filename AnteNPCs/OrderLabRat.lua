-- =======================================================================
-- Order LabRat (base row "Grunt_LabRat" = NPC_LabRat). Ported from AnteUp1 AUOrderLabRat.
--
-- MUST-KNOWS
--   * A flask used to detonate on spawn by hitting the rat itself. PROJ.SpawnGrenade now adds the
--     rat to the flask's ProjectileCollision:IgnoreActorWhenMoving, so it can only pop on something
--     else. That ignore covers the CONTACT only - the BLAST catches everything in radius, thrower
--     included, which is what def.NoSelfDamage is for.
--   * A flask row that ships CanDealDamage = false (Updraft, Portal) makes the damage number inert.
--     Give those FLASK_OVERRIDE.Arm or they land doing nothing but their effect.
--   * No fuse flags on spawn - FuseStartsImmediately can detonate a flask mid-setup (crash).
--   * Flask projectile classes are warmed by PINNING (warmFlasks), never def.Assets - pinned, a
--     drop's class resolve is a cache hit instead of a UObject-array walk.
--   * A THROWN flask needs VelocityOverride PRE-Finish (dropFlask's `Throw`). The post-Finish
--     pm.Velocity write is the gentle-drop path and its speed is capped by the row's MaxSpeed.
--
-- FIGHT OR FLIGHT - the rat's "chases you half the time" is BT_Attack_LabRat, not chance: a target
-- inside 600uu with MeleeCounter < 3 gets charged and punched, and only once the counter reaches 3
-- does the branch fail into BT_Escape (which resets the counter on its way out). Holding the
-- counter at the ceiling is the whole knob - see NO_MELEE.
--
-- ABILITY MAP - NPC_LabRat (row "Grunt_LabRat"). Despite the "Grunt_" row name it is NOT a Grunt
-- subclass (derives from NPC_Base_ParentBP) - inherits none of the Order's grenade ability.
--   0 IDLE - Broadcast_ScanEnvironment: lamp + beam + scan anim, cosmetic only. BT-paced (no
--       self-cooldown). Pin off with AVU.DisableAbility(actor, 0).
--   1 - EMPTY, but carries dead GrenadeData/GrenadeThrowAnimation - a variant can light it up for
--       free via actor:Broadcast_ThrowGrenade().
--   2/3 - EMPTY. Loot drip is a BT service (BTS_DropLabRatLoot), not a slot.
--
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local G = require("AnteData.Items").Global
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local AVM = require("AnteUtils.AVMath")
local PROJ = require("AnteCore.Projectile")

local LogDebug = Utils.LogDebug

local PC = ENUMS.ProjectileClasses

-- Flask projectile classes used by the drop, weighted by repetition.
--   * warmFlasks GC-pins the DISTINCT classes at mutation, so each loads once per world and every
--     drop resolves from cache - adding a flask back costs one pinned class, not a per-throw load.
local FLASKS = {
    PC.FlaskCorrosive, PC.FlaskCorrosive, PC.FlaskCorrosive,
    PC.FlaskCorrosive, PC.FlaskCorrosive, PC.FlaskCorrosive,
    PC.FlaskHoly, PC.FlaskHoly, PC.FlaskHoly,
    PC.FlaskUpdraft, PC.FlaskUpdraft, PC.FlaskUpdraft,
    -- rare
    PC.FlaskPortal,
}
local FLASKS_LAST_SAFE = 12   -- 1..this excludes Portal (the aimed throw + the death scatter)

-- Payload written onto the SPAWNED projectile's ProjectileData, over the row defaults.
--   * Inner is the FULL-damage radius and Outer only where the falloff bottoms out - at HALF the
--     damage, which the parent hardcodes and the row's AoEMinimumDamage never gets a say in. So
--     Inner is the dial that decides whether a flask feels lethal.
--   * Only the two flasks whose shipped blasts are big enough to clip the rat get their radii
--     rewritten (TIGHTEN); the rest keep their row values.
local FLASK = {
    Normal = { Damage = 70,  Inner = 60, Outer = 260 },
    Hard   = { Damage = 100, Inner = 90, Outer = 320 },
}
local TIGHTEN = { [PC.FlaskCorrosive] = true, [PC.FlaskHoly] = true }

-- Per-flask departures from that payload; unlisted flasks take the table above as-is, thrown or
-- scattered on death. Both rows here ship CanDealDamage = false, which makes a damage number inert
-- on its own - Arm flips the flag on THIS INSTANCE (the row is shared with the player's own
-- throwables, so it can never be written on the row).
local FLASK_OVERRIDE = {
    [PC.FlaskUpdraft] = { Arm = true },    -- vanilla only launches; it hits for the shared number
    [PC.FlaskPortal]  = { Damage = 0 },    -- the rare one stays pure relocation
}

-- Launch flasks behind it 
local TOSS = {
    Normal = { Horiz = 150, Up = 30 },   -- ~5m behind
    Hard   = { Horiz = 400, Up = 30 },   -- ~10m behind
}

-- The overhand throw at whatever the rat is running from. MinRange keeps the blast off the
-- thrower; the flight-time clamp is what makes a close throw still arc instead of snapping flat.
local LOB = { MinRange = 500, MaxRange = 2200, HorizSpeed = 900, MinTime = 0.6, MaxTime = 1.4 }

local FLASK_GRAVITY = 1.2
local SPAWN_LIFT    = 90    -- above the capsule centre, so a flask leaves at chest height
local NO_MELEE      = 3     -- MeleeCounter ceiling: at this the BT stops charging and flees

local function byMode(t) return STATE.HardModeNoMercy and t.Hard or t.Normal end

-- The DISTINCT classes in FLASKS (that list is weighted by repetition). DERIVED, never hand-listed,
-- so editing FLASKS above automatically changes what gets pinned.
local FLASK_PINNABLE = {}
do
    local seen = {}
    for _, p in ipairs(FLASKS) do
        if not seen[p] then
            seen[p] = true
            FLASK_PINNABLE[#FLASK_PINNABLE + 1] = p
        end
    end
end

-- [ANY ROLE] GC-pin the flask classes, called once at mutation from def.Stats.
--   * NOT def.Assets: LoadAssets WAITS on that list, and blocking a mutation on heavy BP classes is
--     the ~0.5s mutation microspike. PinPaths is fire-and-forget.
--   * Matters because a rat throws 5x/15s and an unpinned class probe is a full
--     UObject-array walk (~25-30ms) [[anteup2-ue4ss-findobject-scan-crash]]. Pinned = cache hit.
--   * Safe to call per actor: PinPaths skips already-pinned paths; pins clear on world teardown.
local function warmFlasks()
    require("AnteCore.AssetKeeper").PinPaths(FLASK_PINNABLE)
end

local BACKPACK_TINT = FVector(7, 7, 9)

-- A flask in the right hand, in place of the weapon it never had - the LabRat skeleton has no
-- weapon socket, so this hangs off the r_hand BONE and the offsets are eyeballed.
local HAND_FLASK = {
    Location = FVector(6, 3, 0), Rotation = FRotator(0, 0, 0), Scale = FVector(1.3, 1.3, 1.3),
}

-- Helper functions
local dropFlask, dropFlaskBehind, lobFlaskAtTarget, payload

local V = {}

-- =======================================================================
-- FLASK RAT
-- * A fleeing alchemist: it never closes to punch, it throws
-- * Tosses live flasks over its shoulder as it runs, and lobs one at whoever is chasing it
-- * Dies into a small flask spread plus a pile of craftable alchemy loot
-- =======================================================================

V["Flask Rat"] = {
    Id = 33,
    Base = "Grunt_LabRat",
    HardMode = { NoAggroAnim = true },
    -- Its own blast can't touch it. The flask ignores the rat on CONTACT already, but the AoE
    -- catches everything in radius, thrower included - and it throws at its own feet.
    NoSelfDamage = true,
    -- Worn backpack props only (the whole worn stack shares SM_FLASK). Flask PROJECTILE classes stay
    -- OUT of this list - LoadAssets WAITS on it, and preloading heavy BP classes stalls every spawn
    -- ~0.5s. They're warmed instead by warmFlasks (pins from Stats, no wait, no GC-out).
    Assets = {
        ENUMS.Components.SM_FLASK,
    },

    -- Appearance
    Tint = { Color = FVector(3, 3, 6), },
    Visuals = function(actor, assets)
        pcall(function() AVU.TintSlot(actor.Backpack, 0, { DiffuseColor = BACKPACK_TINT }) end)

        -- The flask it throws with, on the hand bone.
        AVU.AttachStaticMesh(actor, ENUMS.Components.SM_FLASK, "r_hand", {
            Location = HAND_FLASK.Location, Rotation = HAND_FLASK.Rotation, Scale = HAND_FLASK.Scale,
            EmissiveColor = FVector(0.3, 1, 0.5), EmissiveStrength = 6,
        })

        -- Vials: the flask glass material has no Color param (baked swirl), so differentiate with
        -- Emissive instead.
        -- Top vial
        AVU.AttachStaticMesh(actor, ENUMS.Components.SM_FLASK, "Backpack", {
            Location = FVector(0, -10, 17), Rotation = FRotator(25, 0, 0),
            Scale = FVector(1.5, 1.5, 1.5),
        })
        -- Left vial
        AVU.AttachStaticMesh(actor, ENUMS.Components.SM_FLASK, "Backpack", {
            Location = FVector(20, -37, -12), Rotation = FRotator(0, 45, 45),   -- L+/F+/U+,  -- /yaw/forward
            Scale = FVector(1.75, 1.75, 1.75),
            EmissiveColor = FVector(0.2, 1, 0.4), EmissiveStrength = 8,
        })
        -- Right vial
        AVU.AttachStaticMesh(actor, ENUMS.Components.SM_FLASK, "Backpack", {
            Location = FVector(-10, -23, -5), Rotation = FRotator(45, 0, 270),
            Scale = FVector(1.5, 1.5, 1.5),
            EmissiveColor = FVector(1, 0.5, 0.1), EmissiveStrength = 8,
        })
    end,

    -- Stats
    BasicStats = {
        HpHead = 240,   -- 120
        HpTorso = 300,   -- 200
        -- WalkSpeed = 130,
        SprintSpeed = 400,   -- 600
        -- MeleeDamage = 65,
        -- RangedDamage = 35,
    },
    TimeDilation = 0.8,
    Stats = function(actor, opts)
        actor.VoicePitch = 1 -- does this do anything?
        warmFlasks()   -- GC-pin the flask classes: every drop re-resolves them (see warmFlasks)
    end,

    -- Triggers
    -- Keep the rat running, and throw on scripted beats: three over the shoulder, two at the target.
    OnTick = function(actor, totalTicks)
        if not Utils.IsActorReadyToAttack(actor) then return end

        -- Pinning the counter at its ceiling every tick deletes the charge-and-punch branch, so the
        -- rat stays in BT_Escape and never lands its knockback swing (see FIGHT OR FLIGHT above).
        -- Drop this line and the vanilla half-and-half comes back.
        -- (SuppressMelee / MeleeAttack_OnCooldown are no-ops here: this tree calls
        -- Server_DoMeleeAttack directly and never reaches TryMeleeAttackCheck.)
        AVU.SetBlackboardInt(actor, "MeleeCounter", NO_MELEE)

        if totalTicks % 10 ~= 0 then return end
        local t = (totalTicks % 150) / 10
        if t == 1 or t == 7 or t == 13 then
            dropFlaskBehind(actor)
            LogDebug("Flask Rat - tossed a flask behind itself", SETTINGS.DEBUG_NPC_ACTIONS)
        elseif t == 4 or t == 10 then
            lobFlaskAtTarget(actor)
        end
    end,

    -- A small spread of flasks + a pile of craftable loot on death.
    OnDeath = function(actor)
        local loc = AVU.DropLoot(actor, {
            { Pool = {
                { G.DISTILLATION_ALIEN, 10 },
                { G.DISTILLATION_BRAINY, 8 },
                { G.DISTILLATION_FIZZY, 8 },
                { G.DISTILLATION_VOID, 6 },
                { G.DISTILLATION_FLESHY, 6 },
                { G.DISTILLATION_FOGGY, 4 },
            }, Count = 2 },
            { Pool = {
                { G.TINCTURE_BRAINPOWER, 1 },
                { G.TINCTURE_CURATIVE, 1 },
                { G.TINCTURE_SPEEDY, 1 },
                { G.COATING_REFORGING, 1 },
                { G.FLASK_CHARGING, 1 },
                { G.FLASK_CORROSIVE, 1 },
                { G.FLASK_HOLY, 1 },
                { G.FLASK_RESTORATIVE, 1 },
            }, Count = 2 },
            { Pool = {
                { G.HEXWOOD, 2 },
            }, MinStory = 45 },
            { Pool = {
                { G.RES_GROWTH, 1 },
            }, MinStory = 60 },
        })
        if not loc then return end

        -- 3 flasks scattered a touch up + outward (they ignore the now-dead rat too).
        Utils.QueueWork(function()
            if Utils.IsActorInvalid(actor) then return end
            for _ = 1, 3 do
                local flask = FLASKS[math.random(1, FLASKS_LAST_SAFE)] -- no Portal on death
                local p = payload(flask)   -- the corpse scatter hits as hard as a thrown one
                dropFlask(actor, flask, {
                    Location = FVector(loc.X + math.random(-40, 40), loc.Y + math.random(-40, 40), loc.Z + 80),
                    Velocity = FVector(math.random(-80, 80), math.random(-80, 80), 40),
                    Gravity = 1.0,
                    Damage = p.Damage, AoEInner = p.Inner, AoEOuter = p.Outer, ArmDamage = p.Arm,
                })
            end
        end, 400)
    end,
}


-- =======================================================================
-- HELPERS (below the variant)
-- =======================================================================

-- Spawns one flask through the shared PROJ.SpawnGrenade funnel (this file's hand-rolled version
-- was its blueprint - see the funnel's header for Instigator/arming/AoE ordering rules).
--   * opts.Throw picks the arc path: VelocityOverride PRE-Finish, which the class copies to
--     pm.Velocity verbatim and no speed multiplier touches. Without it the flask takes the
--     post-Finish pm.Velocity write, which is the gentle drop the death scatter still wants.
--   * NoiseOnImpact=true is safe: additive (doesn't replace impact damage), soft-tagged (can't
--     chain-aggro a room), hardcoded 1000uu range. Decode: AnNotes/AnteNPCs/OrderLabRat.md.
function dropFlask(actor, flaskClass, opts)
    opts = opts or {}
    if not opts.Location then return end   -- actor may be a dead/destroyed corpse (death drop)
    local thrown = opts.Throw == true
    PROJ.SpawnGrenade(actor, flaskClass, {
        NoiseOnImpact = true,
        Label = "Flask Rat dropFlask",
        Location = opts.Location,
        Scale = opts.Scale or 1.6,
        AlignToVelocity = thrown,
        VelocityViaPM = not thrown,
        Velocity = opts.Velocity,
        MaxSpeed = thrown and 4000 or nil,        -- the row default (~1000) clips a real throw
        SpeedMult = (not thrown) and 0.15 or nil,
        Damage = opts.Damage,
        ArmDamage = opts.ArmDamage,
        ArmContactMs = 100,
        AoEInner = opts.AoEInner,
        AoEOuter = opts.AoEOuter,
        Gravity = opts.Gravity or FLASK_GRAVITY,
    })
end


-- The blast payload for one flask at the current difficulty (see FLASK / FLASK_OVERRIDE).
function payload(flask)
    local cfg  = byMode(FLASK)
    local over = FLASK_OVERRIDE[flask]
    return {
        Damage = (over and over.Damage) or cfg.Damage,
        Inner  = TIGHTEN[flask] and cfg.Inner or nil,
        Outer  = TIGHTEN[flask] and cfg.Outer or nil,
        Arm    = over and over.Arm or nil,
    }
end


-- Toss a random flask over the rat's shoulder. The Instigator-ignore (server AND client both skip
-- the rat until the flask bounces) lets us spawn it close in; the arc then carries it clear so a
-- flask that rolls to a stop can't pop under the rat's own feet.
function dropFlaskBehind(actor)
    local fwd = actor:GetActorForwardVector()
    local back = FVector(-(fwd.X or 0), -(fwd.Y or 0), 0)   -- straight behind, flattened
    local loc = actor:K2_GetActorLocation()
    local spawnLoc = FVector(loc.X + back.X * 150, loc.Y + back.Y * 150, loc.Z + SPAWN_LIFT)

    local toss = byMode(TOSS)
    local flask = FLASKS[math.random(1, #FLASKS)]
    local p = payload(flask)
    dropFlask(actor, flask, {
        Location = spawnLoc,
        Scale = 1.3,
        Throw = true,
        Velocity = AVM.ArcVelocity(back, toss.Horiz, toss.Up),
        Damage = p.Damage, AoEInner = p.Inner, AoEOuter = p.Outer, ArmDamage = p.Arm,
    })
end


-- Lob a flask AT whoever the rat is running from - the threat it kept when it stopped punching.
-- Held outside LOB.MinRange so the blast can't reach back down the throw, and solved for a clamped
-- flight time so a close throw still arcs instead of going flat.
function lobFlaskAtTarget(actor)
    local target = AVU.GetCurrentTarget(actor)
    if not target then return end

    local from, to = actor:K2_GetActorLocation(), target:K2_GetActorLocation()
    local d2 = Utils.DistSq(from, to)
    if d2 < LOB.MinRange * LOB.MinRange or d2 > LOB.MaxRange * LOB.MaxRange then return end

    local dir = Utils.Direction(from, to)
    local origin = FVector(from.X + dir.X * 60, from.Y + dir.Y * 60, from.Z + SPAWN_LIFT)
    local land = FVector(to.X, to.Y, to.Z)
    local flight = AVM.LobFlightTime(origin, land, LOB.HorizSpeed, LOB.MinTime, LOB.MaxTime)

    local flask = FLASKS[math.random(1, FLASKS_LAST_SAFE)]   -- no Portal thrown at a player
    local p = payload(flask)
    dropFlask(actor, flask, {
        Location = origin,
        Scale = 1.3,
        Throw = true,
        Velocity = AVM.LobVelocity(origin, land, flight, FLASK_GRAVITY),
        Damage = p.Damage, AoEInner = p.Inner, AoEOuter = p.Outer, ArmDamage = p.Arm,
    })
    LogDebug("Flask Rat - lobbed a flask at its target", SETTINGS.DEBUG_NPC_ACTIONS)
end

return V
