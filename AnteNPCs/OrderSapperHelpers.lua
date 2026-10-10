-- =======================================================================
-- Order Sapper helpers - flask + rocket-jump machinery behind AnteNPCs/OrderSapper.lua
--
-- MUST-KNOWS
--   * The native throw reads GrenadeData at fire time, so repointing that row turns it into a
--     flask throw with correct anim/aim/arc/hand origin, replicated for free.
--   * We can't STOP the throw, only redirect it - BTT_DoCombatAbility calls Broadcast_CombatAbility1
--     directly and never reads Cooldown_CombatAbility1, so AVU.DisableGrenades is a no-op here.
--   * The HEAVY is a manual lob, not the native throw - the native path bakes damage at 250 and
--     can't slow a spawned projectile.
--   * Rocket-jump consistency comes from zeroing velocity first and letting each LaunchCharacter
--     override it - residual momentum would skew the arc. Re-assert it every tick in flight
--     (see H.RocketTick).
--
-- Base Grunt_Sapper stats (DT_NPCList, authoritative): Walk 130 / Sprint 600 / Melee 95 /
-- Ranged 35 / meshScale 1.05 / HpHead 240 / HpTorso 400. /npcstats can misreport these.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local ENUMS = require("AnteData.Enums")
local ASSETS = require("AnteCore.AssetManager")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local AVM = require("AnteUtils.AVMath")
local PROJ = require("AnteCore.Projectile")

local LogDebug = Utils.LogDebug

local PC = ENUMS.ProjectileClasses

-- DT_Projectiles rows for the flasks (from the flask BPs' ProjectileDataRowHandle). These are what
-- GrenadeData is repointed to. Megaton is deliberately EXCLUDED - it one-shots players.
local FLASK_ROW = {
    Corrosive  = ENUMS.ProjectileRows.FlaskCorrosive,
    Holy       = ENUMS.ProjectileRows.FlaskHoly,
    Updraft    = ENUMS.ProjectileRows.FlaskUpdraft,
    Concussive = ENUMS.ProjectileRows.FlaskConcussive,
    Unstable   = ENUMS.ProjectileRows.FlaskUnstable,
    Portal     = ENUMS.ProjectileRows.FlaskPortal,
}

local SAPPER_THROW_MONTAGE = ENUMS.Anims.SAPPER_THROW            -- played manually for the heavy's telegraph
local BACKSTEP_MONTAGE     = ENUMS.Anims.LABRAT_BACKSTEP         -- the Sapper already uses the LabRat stagger set
local LAUNCHER_MONTAGE     = ENUMS.Anims.SAPPER_EQUIP_LAUNCHER   -- upper-body, so it won't fight the launch
-- The step-out-of-a-portal montage both rats play on arrival (AVU.PortalArrival). Authored on
-- HastaTria, which is a Sapper-skinned narrative NPC - same rig as these two.
local ARRIVAL_MONTAGE      = ENUMS.Anims.HASTATRIA_EXIT_PORTAL

-- Flask PROJECTILE classes for the manual fan/scatter (spawned directly, not via a row swap).
local FLASKS = {
    PC.FlaskCorrosive, PC.FlaskCorrosive, PC.FlaskCorrosive,
    PC.FlaskHoly, PC.FlaskHoly,
    PC.FlaskUpdraft,
}
-- Hard-mode overlays for the Mad Rat's behaviour numbers. Read at USE time, never cached: the flag
-- is a world-load value and a cached copy survives into the next world.
local MAD_HARD = {
    FlaskDamage   = { Normal = 60,  Hard = 100 },
    HeavyDamage   = { Normal = 220, Hard = 300 },
    HeavySpeed    = { Normal = 700, Hard = 1000 },
    HeavyCd       = { Normal = 120, Hard = 100 },   -- FAST_TICKs: 12s -> 10s
    -- HOW MUCH IT IS CARRYING, expressed twice: how long before it spends itself, and how much
    -- comes out when it does. CurrentAmmoCount is inert here (MadLoadout pins it off the native
    -- out-of-ammo path), so this pair IS the flask load it burns through.
    KamikazeDelay = { Normal = { 320, 500 }, Hard = { 640, 1000 } },   -- FAST_TICKs of combat
    KamikazeCount = { Normal = 5, Hard = 10 },                        -- flasks in the death scatter
    -- Throw rhythm - the CustomTimeDilation the alchemist cycles through on each native throw.
    -- Hard is the same shape wound tighter, so it still reads as erratic rather than just fast.
    ThrowTdi = {
        Normal = { 2.2, 1.4, 1.6, 2.4, 2.9, 3.4, 1.1 },
        Hard   = { 2.6, 1.7, 2, 2.9, 3.4, 3.9, 1.4 },
    },
}
local function byMode(t) return STATE.HardModeNoMercy and t.Hard or t.Normal end
local function flaskDamage() return byMode(MAD_HARD.FlaskDamage) end

local FLASK_TUNING = {
    [PC.FlaskCorrosive] = { AoEInner = 60, AoEOuter = 260 },
    [PC.FlaskHoly]      = { AoEInner = 60, AoEOuter = 260 },
    [PC.FlaskUpdraft]   = {},
}

local H = {}


-- =======================================================================
-- SHARED
-- =======================================================================

-- THE NATIVE THROW HAS NO ARC, and it does not aim itself either. Both halves are fixed here,
-- from def.OnThrow - a PRE hook on the throw multicast, i.e. the windup, well before the
-- GrenadeRelease notify that reads these and spawns the flask.
--   * NO ARC: the notify calls FireRanged_Projectile, which points the flask straight down
--     fireSocket -> LastRangedAttackLocation and launches at the ROW's speed under full gravity.
--     A flat aim therefore drops the whole way in - about 2m over 10m at the flasks' 1500uu/s -
--     and lands short. Lifting the aim point IS the arc (AVM.BallisticAimPoint).
--   * NO AIM: LastRangedAttackLocation is written ONLY by Server_DoRangedAttack, and these rats
--     never run one (the rocket is pinned off), so it holds a stale point or (0,0,0) - which is
--     the throw that goes nowhere near the target.
local THROW_SPEED    = 1500   -- every projectile_flask_* row: InitialSpeed and MaxSpeed both 1500
local THROW_GRAVITY  = 1      -- ditto their ProjectileGravityScale
local THROW_MAX_LIFT = 900    -- ~17m of reach; uncapped, a long solve aims into the ceiling indoors

local function aimNativeThrow(actor)
    if Utils.IsActorInvalid(actor) then return end
    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end

    -- The native's own aim point (chest, not feet), so a lifted solve starts where it expects.
    local aim
    pcall(function() aim = actor:GetAttackLocation(target) end)
    if not aim then aim = target:K2_GetActorLocation() end
    if not aim then return end

    local mesh = Utils.GetValidMesh(actor)
    if mesh then
        local socket
        pcall(function() socket = mesh:GetSocketLocation(actor.ProjectileFireSocket) end)
        if socket then
            aim = AVM.BallisticAimPoint(socket, aim, THROW_SPEED, THROW_GRAVITY, THROW_MAX_LIFT)
        end
    end
    pcall(function() actor.LastRangedAttackLocation = aim end)
end


-- Hand socket, with an eye-height fallback for a body whose mesh isn't up yet.
local function handLoc(actor, socket)
    local mesh = Utils.GetValidMesh(actor)
    if mesh then
        local ok, loc = pcall(function() return mesh:GetSocketLocation(FName(socket)) end)
        if ok and loc then return loc end
    end
    local l = actor:K2_GetActorLocation()
    return l and FVector(l.X, l.Y, l.Z + 120) or nil
end


-- THE PUNCH PAIR - one melee swing, two scripted beats, and a shove that throws BOTH bodies apart.
-- Drive it from def.OnMeleeSwing (per attempt, hit or miss - the payload is a detonation, not a
-- connecting fist).
--   cfg.Fire(actor, at, beat)  the payload at each beat; `at` is the punching hand
--   cfg.Beat1Ms / Beat2Ms      when each lands
--   cfg.Rate / cfg.Apex        montage tempo (replicates) and the native contact time, which must
--                              be divided by the rate or the native hit lands ahead of beat 1
--   cfg.Knock / KnockUp        the recoil pair on beat 2
--   cfg.Cd                     FAST_TICKs between pairs, so a swing chain can't stack detonations
--   cfg.Deps                   what the beats touch, re-warmed at swing time
-- The BT still waits out the montage's RAW length, so a variant that wants the faster cadence to
-- show has to fire AVU.ReleaseSoldierBT from its tick (AVU.MeleeReleaseTicks).
local function punchBeat(actor, cfg, beat)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end
    local at = handLoc(actor, (beat == 1) and "l_hand" or "r_hand")
    if not at then return end

    cfg.Fire(actor, at, beat)
    if beat ~= 2 then return end

    -- The recoil. The victim's half rides the blast's own knockback (away from the hand); this is
    -- the other half, so the pivot has to be the TARGET - a launch away from the hand is a launch
    -- away from a point the sapper is standing on, which solves to no direction at all.
    local tgt = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(tgt) then return end
    local tl = tgt:K2_GetActorLocation()
    if tl then AVU.LaunchCharacterFrom(actor, tl, cfg.Knock, cfg.KnockUp, false) end
end

-- Returns true when a pair actually started, so a caller's log line means what it says.
local function punchPair(actor, cdTbl, cfg)
    if not Utils.IsAuthority() or Utils.IsActorInvalid(actor) then return false end
    local key = Utils.ActorKey(actor)
    if not key then return false end
    if not AVU.CooldownReady(cdTbl, key, cfg.Cd) then return false end

    ASSETS.WarmPinned(cfg.Deps)
    pcall(function()
        actor.MeleeAttackPlayRate = cfg.Rate
        actor.MeleeHitApex        = cfg.Apex
    end)

    Utils.QueueWork(function() punchBeat(actor, cfg, 1) end, cfg.Beat1Ms)
    Utils.QueueWork(function() punchBeat(actor, cfg, 2) end, cfg.Beat2Ms)
    return true
end


-- Pin the native ROCKET off (slot 3) + hide its mesh.
function H.StripRocket(actor)
    if Utils.IsActorInvalid(actor) then return end
    AVU.DisableAbility(actor, 3)
    AVU.SetReplicatedProp(actor, "HasRocket", false)   -- the OnRep hides the MainRocket mesh
    pcall(function() if IsValid(actor.SpareRocketIndicator) then actor.SpareRocketIndicator:SetHiddenInGame(true, false) end end)
end


-- Spawn a grenade-family FLASK that ignores the thrower until it lands, then pops on contact.
-- Rides the shared PROJ.SpawnGrenade funnel (see its header for the crash-safe ordering).
-- opts: Class + Location required; Velocity, Gravity, Damage, AoEInner/Outer, Scale optional.
--   * VELOCITY must go through VelocityOverride PRE-Finish + AlignToVelocity - a post-Finish
--     pm.Velocity write gets silently overwritten by the flat forward launch.
local function spawnFlask(actor, opts)
    opts = opts or {}
    if not opts.Class or not opts.Location then return end
    PROJ.SpawnGrenade(actor, opts.Class, {
        Label = "OrderSapper spawnFlask",
        Location = opts.Location,
        Scale = opts.Scale or 1.4,
        AlignToVelocity = true,
        Velocity = opts.Velocity,
        Damage = opts.Damage,
        ArmContactMs = 100,
        AoEInner = opts.AoEInner,
        AoEOuter = opts.AoEOuter,
        MaxSpeed = 4000,               -- so a high arc isn't clamped (row default ~1000)
        Gravity = opts.Gravity or 1.2,
    })
end


-- Drop a frag grenade AT a world location. opts: OnContact, Damage, FallSpeed.
--   * DropGrenades drops at the ACTOR's feet and can't retarget, so this spawns one directly.
--   * The frag-specific fuse/contact flags ride the PreFinish hatch.
local function spawnFragAt(actor, loc, opts)
    if Utils.IsActorInvalid(actor) or not loc then return end
    opts = opts or {}
    local onContact = opts.OnContact == true
    PROJ.SpawnGrenade(actor, ENUMS.ProjectileClasses.GrenadeFrag, {
        Label = "Rocket Rat spawnFragAt",
        Location = loc,
        SpawnMode = 2,                 -- AdjustIfPossibleButAlwaysSpawn (mid-air drop point)
        WasThrown = false,
        -- Straight down; higher FallSpeed = lands sooner, so the rat isn't long gone first.
        --   * Instigator=rat inside the funnel keeps the airborne rat from being caught by its
        --     OWN contact-frag as it arcs over (the mid-air suicide).
        Velocity = FVector(0, 0, -(opts.FallSpeed or 250)),
        SpeedMult = 0.25,
        PreFinish = function(proj)
            pcall(function() proj.FuseStartsImmediately = not onContact end)
            pcall(function() proj.FuseAfterFirstBounce = 2 end)
            pcall(function() proj.FirstBounce = false end)
            pcall(function() proj.ExplodesOnContact = onContact end)
        end,
        PostFinish = function(proj)
            pcall(function() proj.DamageFromWeapon = opts.Damage or 70 end)
            pcall(function() proj["Base Damage"] = opts.Damage or 70 end)
        end,
    })
end


-- =======================================================================
-- SUPER SAPPER: the base Sapper with all three of its own moves escalated. Nothing here replaces a
-- native ability - each piece rides the beat the native one already produces.
--   * ROCKET  - the native launcher shot, then a second rocket a beat later, from the same kneel.
--       BTT_DoSapperRocket crouches to fire and stands back up on the pawn's CombatReset broadcast
--       one second after the shot, so the follow-up has to hold that crouch itself.
--   * GRENADE - sometimes a three-frag barrage instead of the single throw, thrown on the
--       Interfector's knife-throw montage. Same borrowed-animation trick as the Grenadier Guard,
--       and the same beat-timing derivation: AnNotes/AnteNPCs/OrderGrunt.md. Faster here, rate 1 vs 0.75.
--   * MELEE   - the punch pair, detonating a grenade in each fist.
-- =======================================================================

local SUPER = {
    -- ROCKET FOLLOW-UP
    RocketFollowMs = 1000,   -- the "one second later" beat; also when the native stands the body up
    RocketDamage   = 300,    -- the class default is 500, and two of those is not a fight
    RocketSpeed    = 2000,   -- the row's own InitialSpeed, so both rockets travel alike
    RocketGravity  = 0.01,   -- ditto - projectile_rocketsapper flies effectively flat
    KneelTicks     = 16,     -- FAST_TICKs the crouch is held from the first shot

    -- THE BARRAGE. Rel is pre-compensated for QueueWork's 100ms rounding AND PROJ.SpawnGrenade's
    -- own one-tick defer, exactly like the Grenadier's - don't change Rate without re-deriving it.
    -- Raw beats at rate 1 are 0.15 / 0.275 / 0.5s.
    ThrowChance = 0.35,
    Rate        = 1,
    Rel         = { 100, 200, 400 },
    Damage      = 90,
    ArcDeg      = 32,
    Gravity     = 1,      -- MUST match the row's ProjectileGravityScale or the arc solve lies
    MaxSpeed    = 2500,   -- the row caps at 1500 and clamps SILENTLY
    Spread      = 200,    -- lateral fan (uu), so three frags cover ground instead of stacking
    Fuzz        = 80,
    Fan         = { -1, 0.35, 1 },
    RestMs      = 1200,

    -- THE PUNCH PAIR
    PunchCd       = 8,
    PunchRate     = 2,
    PunchApex     = 0.5,   -- MeleeHitApex, base 0.2 - see MAD_PUNCH.Apex
    Punch1Ms      = 250,
    Punch2Ms      = 500,
    Punch1Damage  = 50,
    Punch2Damage  = 100,
    PunchRadius   = 260,
    Knock         = 1500,
    KnockUp       = 250,
    MeleeFallback = 1.4,   -- assumed montage length until AVU.MeleeReleaseTicks measures it
}
SUPER.RocketDeps = { PC.RocketSapper, ENUMS.Effects.EXPLOSION_BIG }
SUPER.ThrowDeps  = { ENUMS.Anims.INTERFECTOR_THROW_KNIVES, PC.GrenadeFrag }
SUPER.PunchDeps  = { ENUMS.Effects.EXPLOSION_BIG, ENUMS.DamageType.ExplosiveDefenseBot }

-- `ss` prefix = the Super Sapper's per-actor state (ActorKey-keyed, as with `mad` / `rj`).
local ssKneelUntil    = {}   -- key -> FAST_TICK the post-rocket crouch hold ends
local ssLastPunchTick = {}   -- key -> FAST_TICK of the last punch pair (also punchPair's cooldown)
local ssReleased      = {}   -- key -> the punch tick whose BT release has already been spent

H.SUPER_ASSETS = {
    ENUMS.Anims.SAPPER_MELEE,                 -- measured for the melee release valve
    ENUMS.Anims.INTERFECTOR_THROW_KNIVES,     -- the barrage animation
    PC.GrenadeFrag,
    PC.RocketSapper,
    ENUMS.Effects.EXPLOSION_BIG,
    ENUMS.DamageType.ExplosiveDefenseBot,     -- the punch blasts; BlastDamage bails on a cold type
}


function H.SuperLoadout(actor)
    -- Two rockets a volley, so it carries enough for several. Staying above zero also keeps it off
    -- the native out-of-ammo enrage, which would fight the tempo being set here.
    pcall(function() actor.MaxAmmoCount = 8 end)
    pcall(function() actor.CurrentAmmoCount = 8 end)
    pcall(function() actor.KamikazeDamage = 900 end)   -- 1200; still lethal, no longer a one-shot
    AVU.SetReplicatedProp(actor, "VoicePitch", 0.91)
end


-- [RENDERER] A hot launcher and a bandolier of frags across the pack - it is carrying two volleys
-- of everything, and that should be visible before it fires any of it.
function H.SuperLook(actor)
    pcall(function()
        local gun = actor.Gun
        if IsValid(gun) then
            AVU.TintComponent(gun, { Color = FVector(4, 1, 0), EmissiveColor = FVector(3, 0.5, 0), Emissive = 12 })
        end
    end)

    for _, loc in ipairs({ FVector(-14, 30, 6), FVector(-4, 34, 0), FVector(6, 34, -6) }) do
        AVU.AttachStaticMesh(actor, ENUMS.Components.SM_GRENADE_FRAG, "Backpack", {
            Location = loc, Scale = FVector(1.1, 1.1, 1.1),
        })
    end
end


-- The launcher muzzle. MainRocket is hidden once HasRocket clears, but a hidden component still
-- reports its socket, so this stays correct through the whole follow-up window.
local function rocketMuzzle(actor)
    local ok, loc = pcall(function() return actor.MainRocket:GetSocketLocation(FName("muzzle")) end)
    if ok and loc then return loc end
    return handLoc(actor, "r_hand")
end


local function superFollowRocket(actor)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end
    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end

    local from = rocketMuzzle(actor)
    local tLoc = target:K2_GetActorLocation()
    if not from or not tLoc then return end

    -- Show the launcher again for the shot: the native reset hides it, and its muzzle FX with it,
    -- one second after the first rocket - which is exactly when this fires. Safe to re-arm, because
    -- the BT's rocket branch sits behind RangedAttack_OnCooldown, which the shot just took for the
    -- row's 1.4s, and the clear below lands well inside that.
    AVU.SetReplicatedProp(actor, "HasRocket", true)
    pcall(function() actor:Broadcast_DoRangedAttackFX() end)

    local dir = Utils.Direction(from, FVector(tLoc.X, tLoc.Y, tLoc.Z + 40))
    PROJ.SpawnGrenade(actor, PC.RocketSapper, {
        Label = "Super Sapper follow-up rocket",
        Location = from,
        AlignToVelocity = true,
        Velocity = FVector(dir.X * SUPER.RocketSpeed, dir.Y * SUPER.RocketSpeed, dir.Z * SUPER.RocketSpeed),
        Damage = SUPER.RocketDamage,
        Gravity = SUPER.RocketGravity,
        MaxSpeed = SUPER.RocketSpeed,
    })
    Utils.QueueWork(function()
        if Utils.IsActorValid(actor) then AVU.SetReplicatedProp(actor, "HasRocket", false) end
    end, 400)
    LogDebug("Super Sapper - follow-up rocket", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- [AUTHORITY, OnRangedAttack] PRE: the native rocket is about to leave. Book the second one, and
-- start holding the kneel it will be fired from.
function H.SuperRocket(actor)
    if not Utils.IsAuthority() or Utils.IsActorInvalid(actor) then return end
    local key = Utils.ActorKey(actor)
    if not key then return end

    ssKneelUntil[key] = STATE.FAST_TICK + SUPER.KneelTicks
    ASSETS.WarmPinned(SUPER.RocketDeps)
    Utils.QueueWork(function() superFollowRocket(actor) end, SUPER.RocketFollowMs)
end


-- ONE arc-solved frag of the barrage. `index` picks its lane in the fan.
local function superLob(actor, index)
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return end
    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end

    local from = handLoc(actor, "r_hand")
    local tLoc = target:K2_GetActorLocation()
    if not from or not tLoc then return end

    -- Hand the held grenade off as the throw leaves, then re-arm it for the next lane. There is ONE
    -- hand slot, so show/hide must interleave exactly one per throw; the last lane leaves the hand
    -- empty, which is correct. Renderer-only, and local - a pure client sees empty hands.
    if Utils.HasRenderer() then
        pcall(function() actor:Local_SpawnGrenadeInHand(true) end)
        if index < #SUPER.Rel then
            Utils.QueueWork(function()
                if Utils.IsActorValid(actor) then pcall(function() actor:Local_SpawnGrenadeInHand(false) end) end
            end, 0)
        end
    end

    -- Fan the landing points ACROSS the line of fire so the volley covers ground.
    local nx, ny = AVM.Normalize2D(tLoc.X - from.X, tLoc.Y - from.Y)
    local off = SUPER.Spread * (SUPER.Fan[index] or 0)
    local aim = Utils.FuzzLocation(FVector(tLoc.X - ny * off, tLoc.Y + nx * off, tLoc.Z), SUPER.Fuzz)

    local speed = AVM.ArcSpeed(from, aim, SUPER.ArcDeg, SUPER.Gravity)
    local dir = AVM.ArcDir(from, aim, SUPER.ArcDeg)
    PROJ.SpawnGrenade(actor, PC.GrenadeFrag, {
        Label = "Super Sapper barrage",
        Location = from,
        AlignToVelocity = true,
        Velocity = FVector(dir.X * speed, dir.Y * speed, dir.Z * speed),
        Damage = SUPER.Damage,
        Gravity = SUPER.Gravity,
        MaxSpeed = SUPER.MaxSpeed,
    })
end


-- [AUTHORITY, OnThrow] PRE: the native throw is about to start. On a roll, take it over.
--   * Replacing the throw montage a beat later is what SUPPRESSES the native grenade - the single
--     frag is spawned by that montage's GrenadeRelease notify, and the knife montage carries no
--     notifies at all, so once it owns the slot we own all three releases.
--   * PlayMontageReplicated, not a local play: the whole point of borrowing an animation is that
--     clients see it too.
function H.SuperThrow(actor)
    if not Utils.IsAuthority() or Utils.IsActorInvalid(actor) then return end
    aimNativeThrow(actor)   -- the 65% that stay single throws still need an arc and an aim point
    if math.random() >= SUPER.ThrowChance then return end
    if Utils.IsActorInvalid(actor:GetCurrentCombatTarget()) then return end

    ASSETS.WarmPinned(SUPER.ThrowDeps)
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        AVU.SetTimeDilation(actor, 1)   -- the release schedule is in REAL ms; TDI would stretch it
        AVU.PlayMontageReplicated(actor, ENUMS.Anims.INTERFECTOR_THROW_KNIVES, SUPER.Rate, false)
        for i = 1, #SUPER.Rel do
            Utils.QueueWork(function() superLob(actor, i) end, SUPER.Rel[i])
        end
        Utils.QueueWork(function()
            if Utils.IsActorValid(actor) then AVU.SetTimeDilation(actor, 1) end
        end, SUPER.RestMs)
        LogDebug("Super Sapper - triple grenade barrage", SETTINGS.DEBUG_NPC_ACTIONS)
    end, 0)
end


-- A grenade goes off in the punching fist. PLAYERS ONLY (HitNpcs stays off): an NPC-inclusive
-- radial thrown from a body in a crowd is the re-entrancy crash, and a sapper shredding its own
-- squad on every swing is not the fight either.
local SUPER_PUNCH = {
    Cd = SUPER.PunchCd, Rate = SUPER.PunchRate, Apex = SUPER.PunchApex,
    Beat1Ms = SUPER.Punch1Ms, Beat2Ms = SUPER.Punch2Ms,
    Knock = SUPER.Knock, KnockUp = SUPER.KnockUp, Deps = SUPER.PunchDeps,
    Fire = function(actor, at, beat)
        AVU.BroadcastFX(at, ENUMS.Effects.EXPLOSION_BIG, nil, FVector(0.5, 0.5, 0.5))
        AVU.BlastDamage(actor, at, {
            Radius = SUPER.PunchRadius,
            Damage = (beat == 1) and SUPER.Punch1Damage or SUPER.Punch2Damage,
            DamageType = ENUMS.DamageType.ExplosiveDefenseBot,   -- explosive, and debuff-free
            Knockback = (beat == 2) and SUPER.Knock or 0,
            KnockbackUp = SUPER.KnockUp,
        })
    end,
}

function H.SuperPunch(actor)
    if punchPair(actor, ssLastPunchTick, SUPER_PUNCH) then
        LogDebug("Super Sapper - double punch", SETTINGS.DEBUG_NPC_ACTIONS)
    end
end


function H.SuperTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    local key = Utils.ActorKey(actor)
    if not key then return end

    -- KNEEL HOLD. Outside the cadence gate below, so the re-crouch lands on the frame after the
    -- native stands the body up rather than up to half a second later. Re-asserted rather than
    -- tested: Crouch only raises a want-flag, so a redundant call costs nothing and reading
    -- bIsCrouched back through a uint8 property is the fiddlier half.
    local kneelUntil = ssKneelUntil[key]
    if kneelUntil then
        if STATE.FAST_TICK <= kneelUntil then
            pcall(function() actor:Crouch(false) end)
        else
            ssKneelUntil[key] = nil
            pcall(function() actor:UnCrouch(false) end)
        end
    end

    if totalTicks % 5 ~= 0 then return end

    -- Hand the tree back once the sped-up swing has really finished, or the punch pair just buys
    -- dead air (the native wait is sized off the montage's RAW length). nil = not measured yet.
    local last = ssLastPunchTick[key]
    if last and ssReleased[key] ~= last then
        local rate = SUPER.PunchRate * (tonumber(actor.CustomTimeDilation) or 1)
        local wait = AVU.MeleeReleaseTicks(ENUMS.Anims.SAPPER_MELEE, rate,
            { Fallback = SUPER.MeleeFallback, Pad = 2 })
        if wait and STATE.FAST_TICK - last >= wait then
            ssReleased[key] = last
            AVU.ReleaseSoldierBT(actor)
        end
    end
end


function H.SuperDeath(actor)
    local key = Utils.ActorKey(actor)
    if not key then return end
    ssKneelUntil[key], ssLastPunchTick[key], ssReleased[key] = nil, nil, nil
end


-- =======================================================================
-- MAD RAT
-- =======================================================================

-- The HEAVY = a manual megaton lob.
--   * NOTE: the megaton BP fires a facility-wide quake + screen shake/fade on detonation
--     (Local_MassiveBlast) - dramatic; if obnoxious on a 12s cadence, swap HEAVY_FLASK_CLASS
--     to PC.FlaskUnstable (a big cluster, no screen-nuke).
local HEAVY_FLASK_CLASS = PC.FlaskMegaton
local HEAVY_SCALE  = 2.6   -- big, readable projectile
local HEAVY_ARC_UP = 500   -- strong upward arc - it LOBS high and drops, telegraphing the landing
local HEAVY_TDI    = 0.4   -- slow-mo wind-up (mirrored to clients)
-- Damage, cruise speed and cadence are MAD_HARD entries: hard mode hits harder, travels faster
-- (less dodge window) and comes round sooner.

-- Weighted rotation for the rapid native throws.
local NATIVE_POOL = {
    FLASK_ROW.Corrosive, FLASK_ROW.Corrosive, FLASK_ROW.Corrosive, FLASK_ROW.Corrosive,
    FLASK_ROW.Corrosive, FLASK_ROW.Corrosive, FLASK_ROW.Corrosive, FLASK_ROW.Corrosive,
    FLASK_ROW.Holy, FLASK_ROW.Holy,
    FLASK_ROW.Updraft, FLASK_ROW.Updraft,
    FLASK_ROW.Portal,   -- rare
}

local MAD_HEAVY_MIN_SQ = 500 * 500
local MAD_HEAVY_MAX_SQ = 3000 * 3000
local MAD_ROW_SWAP_CD  = 35    -- ~3.5s between flask-type swaps
-- ~3.5s of combat before the FIRST heavy - else it fires the instant it aggros, before the
-- anim instance is ready -> the "no montage" heavy.
local MAD_HEAVY_WARMUP = 35
local MAD_MELEE_FLASK_CD = 6   -- FAST_TICKs between melee flask-bursts

-- KAMIKAZE LOCKDOWN: a beat BEFORE the timed charge, HALT the native BT.
--   * Stops any flask throw (and any heavy - gated below) from starting and overlapping the
--     kamikaze equip montage - that overlap was the "primes kamikaze, then a throw interrupts
--     and bypasses part of the montage" bug.
--   * The charge itself is a controller-level AIMoveTo, independent of the BT, so it still runs.
--
-- THE CHARGE CAN REFUSE TO START, AND THE LOCKDOWN IS WHAT STRANDS IT.
-- Broadcast_CombatAbility2 opens with FindPathToActorSynchronously and takes the
-- EndAbility_DoCombatReset(false) exit whenever that path is invalid or PARTIAL - which indoors,
-- through doorways and across nav islands is common. Nothing native re-runs the tree we stopped, so
-- the body is left with no BT and no script: standing still, never moving, never detonating. Hence
-- the watchdog: verify KamikazeActive actually latched, and hand the tree back when it didn't.
local MAD_KAMIKAZE_LEAD    = 15    -- ~1.5s of lockdown before the charge
local MAD_KAMIKAZE_VERIFY  = 50    -- ticks after the request before "it never armed" is a verdict.
                                   --   Must outlast the equip montage the native waits out; being
                                   --   generous only delays a recovery, being short cancels a
                                   --   charge that was going to work.
local MAD_KAMIKAZE_TIMEOUT = 250   -- ticks a LIVE charge may run before we call it stuck. The
                                   --   native re-issues its AIMoveTo every 10s, so this is the
                                   --   backstop for a target it can never path to.
local MAD_KAMIKAZE_RETRY   = 200   -- ticks before a bailed charge re-arms
local MAD_KAMIKAZE_TRIES   = 3     -- attempts before the rat gives up and just keeps throwing

-- Throw-rhythm: on each native throw, cycle CustomTimeDilation through MAD_HARD.ThrowTdi so the
-- alchemist lobs at an erratic, twitchy tempo.
--   * TDI scales the WHOLE actor, so the fast frames are kept SHORT to limit how far it darts.
--   * 1.1 = the baseline it reverts to.
local THROW_TDI_MS    = 900   -- how long a throw's TDI holds before reverting
local THROW_TDI_TICKS = 9     -- the same window in FAST_TICKs, for the newest-throw-wins guard

-- Per-actor state, keyed by Utils.ActorKey (shared across the fresh wrappers each hook gets).
-- `mad` prefix = Mad Rat's block (the Rocket Rat's is `rj`, further down).
local madFirstCombatTick = {}   -- key -> FAST_TICK first seen in combat
local madKamikazeAt      = {}   -- key -> FAST_TICK at which to charge (randomized per actor)
local madKamikazeDone    = {}   -- key -> true once the charge has been fired
local madPriming         = {}   -- key -> true once in the pre-kamikaze lockdown window
local madKamikazeFired   = {}   -- key -> FAST_TICK the charge was REQUESTED (the watchdog's clock)
local madKamikazeTries   = {}   -- key -> charge attempts made, including the ones that never armed
local madLastMeleeTick   = {}   -- key -> FAST_TICK of last melee punch pair
local madThrowStep       = {}   -- key -> index into the throw-TDI pattern (advances each throw)
local madTdiUntil        = {}   -- key -> FAST_TICK the current throw-TDI reverts (newest-throw wins)
local madHeavyUntil      = {}   -- key -> FAST_TICK until which the throw-TDI is suppressed (heavy owns TDI)
local madLastHeavyTick   = {}   -- key -> totalTicks of last megaton heavy
local madLastRowSwapTick = {}   -- key -> totalTicks of last GrenadeData flask-type swap

H.MADRAT_ASSETS = {
    ENUMS.Components.SM_FLASK_DISTILL_INPUT,   -- worn vials; natively-thrown flasks load via the game's own path
    SAPPER_THROW_MONTAGE,   -- the heavy's manual wind-up
    BACKSTEP_MONTAGE,       -- the BackJump hop
    HEAVY_FLASK_CLASS,      -- the megaton projectile (keep it warm)
    ARRIVAL_MONTAGE,        -- the portal step-out (AVU.PortalArrival resolves it non-loading)
}


function H.MadLoadout(actor)
    H.StripRocket(actor)                                                  -- the megaton heavy replaces it
    AVU.SetProjectileRow(actor, "GrenadeData", FLASK_ROW.Corrosive, true) -- native throw -> flask
    pcall(function() actor.KamikazeDamage = 150 end)                      -- declaw the blast (flasks are the payload)
    -- Native 2 -> 10; also keeps it clear of the native "out of ammo -> kamikaze" path,
    -- so only our timed charge fires it.
    pcall(function() actor.MaxAmmoCount = 10 end)
    pcall(function() actor.CurrentAmmoCount = 10 end)
    pcall(function() actor.MeleeAttackRange = 1 end)

    AVU.SetReplicatedProp(actor, "VoicePitch", 1.7)
end


-- [RENDERER] Worn vials on the backpack.
--   * NOTE: on a GRUNT subclass the backpack component is `backpack` (lowercase), not the
--     LabRat's `Backpack` - that's why an earlier tint no-op'd.
function H.MadDress(actor)
    pcall(function()
        local bp = actor.Gun
        if IsValid(bp) then AVU.TintComponent(bp, { Color = FVector(5, 0, 0), EmissiveColor = FVector(0, 0, 5), Emissive = 40 }) end
    end)

    AVU.AttachStaticMesh(actor, ENUMS.Components.SM_FLASK_DISTILL_INPUT, "Backpack", {
        Location = FVector(-27, -10, 20), Rotation = FRotator(45, 0, 180),   -- L+/F+/U+
        Scale = FVector(0.65, 0.65, 0.65), Tint = FVector(1, 0, 1), EmissiveColor = FVector(0, 0, 1), EmissiveStrength = 8,
    })
    AVU.AttachStaticMesh(actor, ENUMS.Components.SM_FLASK_DISTILL_INPUT, "Backpack", {
        Location = FVector(27, -10, 20), Rotation = FRotator(-45, 0, 180),
        Scale = FVector(0.65, 0.65, 0.65), Color = FVector(1, 0, 1), EmissiveColor = FVector(0, 0, 1), EmissiveStrength = 8,
    })
end


-- Repoint GrenadeData at a weighted-random flask row so the NEXT native throw is that type.
local function rotateNativeFlask(actor)
    local row = NATIVE_POOL[math.random(1, #NATIVE_POOL)]
    AVU.SetProjectileRow(actor, "GrenadeData", row, true)   -- inPlace: GrenadeData holds a soft-ptr DataTable
end


-- Give the rat its tree back after a charge that never started, or one that will never arrive, and
-- re-arm a later attempt while it still has tries left. See the KAMIKAZE LOCKDOWN note.
local function abandonKamikaze(actor, key, why)
    madPriming[key]       = nil
    madKamikazeFired[key] = nil
    AVU.SetReplicatedProp(actor, "KamikazeActive", false)   -- clears the beep + the suicide anim set
    pcall(function() actor.MeleeAttack_OnCooldown = false end)
    AVU.StartBehaviorTree(actor)

    local tries = (madKamikazeTries[key] or 0) + 1
    madKamikazeTries[key] = tries
    if tries < MAD_KAMIKAZE_TRIES then
        madKamikazeDone[key] = nil
        madKamikazeAt[key]   = STATE.FAST_TICK + MAD_KAMIKAZE_RETRY
    end
    LogDebug("Mad Rat - kamikaze abandoned (" .. why .. "), attempt " .. tries,
        SETTINGS.DEBUG_NPC_ACTIONS)
end


-- Runs even out of combat and even while stunned: the failure this guards is a body with no tree,
-- and a body with no tree has no way back into either state on its own.
local function kamikazeWatchdog(actor, key)
    local firedAt = madKamikazeFired[key]
    if not firedAt then return end
    if actor.IsDead or actor.IsDBNO then return end   -- a corpse mid-charge needs no tree back

    local live = false
    pcall(function() live = actor.KamikazeActive == true end)
    local waited = STATE.FAST_TICK - firedAt

    if not live then
        if waited >= MAD_KAMIKAZE_VERIFY then abandonKamikaze(actor, key, "never armed") end
    elseif waited >= MAD_KAMIKAZE_TIMEOUT then
        abandonKamikaze(actor, key, "charge stalled")
    end
end


-- The native throw (redirected to flasks) does the rapid lobbing on its own; this rotates the flask
-- TYPE, fires the occasional heavy, and kicks off the kamikaze charge.
function H.MadTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    if totalTicks % 5 ~= 0 then return end

    local key = Utils.ActorKey(actor)
    if not key then return end
    kamikazeWatchdog(actor, key)   -- BEFORE the readiness gate - a stranded rat may not pass it

    if not Utils.IsActorReadyToAttack(actor) then return end
    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end

    -- CORNERED-FANATIC KAMIKAZE: once it's been fighting a while, charge (native slot 2).
    -- The blast is declawed and OnDeath scatters flasks.
    local now = STATE.FAST_TICK
    if not madFirstCombatTick[key] then
        madFirstCombatTick[key] = now
        local delay = byMode(MAD_HARD.KamikazeDelay)   -- the "cornered fanatic" clock
        madKamikazeAt[key] = now + math.random(delay[1], delay[2])
    elseif not madKamikazeDone[key] then
        local kAt = madKamikazeAt[key] or math.huge
        if not madPriming[key] and now >= kAt - MAD_KAMIKAZE_LEAD then
            madPriming[key] = true
            AVU.StopBehaviorTree(actor)   -- stops native throws; the kamikaze AIMoveTo is BT-independent
            AVU.SuppressMelee(actor)
            LogDebug("Mad Rat - kamikaze lockdown (throws off)", SETTINGS.DEBUG_NPC_ACTIONS)
        end
        if now >= kAt then
            madKamikazeDone[key]  = true
            madKamikazeFired[key] = now
            pcall(function() actor:Broadcast_CombatAbility2() end)
            LogDebug("Mad Rat - kamikaze charge", SETTINGS.DEBUG_NPC_ACTIONS)
            return
        end
    end

    -- Keep spacing: hop back if the target crowds it (unless it's committed to the charge).
    if not madKamikazeDone[key] and not madPriming[key] then
        AVU.BackJump(actor, { TriggerRange = 300, Distance = 1000, Up = 320, Cooldown = 60, Montage = BACKSTEP_MONTAGE })
    end

    if AVU.CooldownReady(madLastRowSwapTick, key, MAD_ROW_SWAP_CD, { Now = totalTicks }) then
        rotateNativeFlask(actor)
    end

    -- HEAVY (the rocket replacement): a manual megaton lob, telegraphed by a slow-mo wind-up.
    --   * Slow TDI (mirrored) + the throw montage sell it; the flask is BIG and SLOW so it
    --     reads as a heavy and can be dodged.
    --   * It spawns at the release point ~700ms into the slowed wind-up.
    local aLoc = actor:K2_GetActorLocation()
    local tLoc = target:K2_GetActorLocation()
    local distSq = Utils.DistSq(aLoc, tLoc)
    -- The CooldownReady clause is LAST on purpose: `and` short-circuits, so it only stamps when
    -- every other gate has already passed (exactly what the old inline stamp did).
    if not madKamikazeDone[key]   -- once it commits to the charge, no more heavies (it rooted mid-run)
       and not madPriming[key]
       and (madKamikazeAt[key] == nil or (madKamikazeAt[key] - now) > 30)  -- nor one that would land (~1.8s) near the charge
       and (STATE.FAST_TICK - (madFirstCombatTick[key] or STATE.FAST_TICK)) >= MAD_HEAVY_WARMUP
       and distSq >= MAD_HEAVY_MIN_SQ and distSq <= MAD_HEAVY_MAX_SQ
       and AVU.CooldownReady(madLastHeavyTick, key, byMode(MAD_HARD.HeavyCd), { Now = totalTicks }) then
        madHeavyUntil[key] = STATE.FAST_TICK + 15   -- the heavy owns TDI: mute the throw-rhythm ~1.5s
        AVU.ForceAggro(actor, target)
        pcall(function() actor:K2_SetActorRotation(Utils.RotatorToTarget(aLoc, tLoc), false) end)
        AVU.HoldStill(actor, true)                         -- ROOT it: no running/meleeing mid-wind-up
        AVU.SetTimeDilation(actor, HEAVY_TDI)
        AVU.PlayAnimation(actor, SAPPER_THROW_MONTAGE, 1)
        LogDebug("Mad Rat - megaton heavy (windup)", SETTINGS.DEBUG_NPC_ACTIONS)

        Utils.QueueWork(function()
            AVU.HoldStill(actor, false)     -- unroot (paired; runs even if it went invalid)
            AVU.SetTimeDilation(actor, 1.1)
            if Utils.IsActorInvalid(actor) then return end
            local t2 = actor:GetCurrentCombatTarget()
            local aim = (Utils.IsActorValid(t2) and t2:K2_GetActorLocation()) or tLoc
            local a2 = actor:K2_GetActorLocation()
            local dir = Utils.Direction(a2, aim)
            spawnFlask(actor, {
                Class = HEAVY_FLASK_CLASS,
                Location = FVector(a2.X + dir.X * 50, a2.Y + dir.Y * 50, a2.Z + 110),
                Velocity = AVM.ArcVelocity(dir, byMode(MAD_HARD.HeavySpeed), HEAVY_ARC_UP),
                Gravity = 1.0, Scale = HEAVY_SCALE, Damage = byMode(MAD_HARD.HeavyDamage),
                AoEInner = 140, AoEOuter = 420,
            })
            -- Two SIDE flasks fanned left + right (a scatter). Lesser flasks, NOT more megatons, or
            -- it'd be 3 facility quakes.
            for _, side in ipairs({ -1, 1 }) do
                local sd = AVM.RotateYaw(dir, side * 22)
                local sflask = (math.random() < 0.5) and PC.FlaskCorrosive or PC.FlaskHoly
                spawnFlask(actor, {
                    Class = sflask,
                    Location = FVector(a2.X + sd.X * 50, a2.Y + sd.Y * 50, a2.Z + 110),
                    Velocity = AVM.ArcVelocity(sd, byMode(MAD_HARD.HeavySpeed), HEAVY_ARC_UP + 60),
                    Gravity = 1.0, Damage = flaskDamage(),
                    AoEInner = 60, AoEOuter = 260,
                })
            end
        end, 1800)
    end
end


-- Cycle CustomTimeDilation through the throw-TDI pattern on each native throw, reverting after
-- a short window.
--   * Newest throw wins (madTdiUntil guards a stale revert).
--   * The heavy suppresses this entirely so its slow-mo isn't stomped.
--   * AUTHORITY only - MirrorTimeDilation pushes the value to clients, so a client-side re-fire
--     would just double-set it.
local function madThrowTDI(actor)
    if Utils.IsActorInvalid(actor) or not Utils.IsAuthority() then return end
    local key = Utils.ActorKey(actor); if not key then return end
    local now = STATE.FAST_TICK
    if madHeavyUntil[key] and now < madHeavyUntil[key] then return end   -- heavy owns TDI right now

    local pattern = byMode(MAD_HARD.ThrowTdi)
    local step = ((madThrowStep[key] or 0) % #pattern) + 1
    madThrowStep[key] = step
    AVU.SetTimeDilation(actor, pattern[step])
    madTdiUntil[key] = now + THROW_TDI_TICKS

    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) then return end
        local k = Utils.ActorKey(actor); if not k then return end
        if STATE.FAST_TICK < (madTdiUntil[k] or 0) then return end                  -- a newer throw still holds
        if madHeavyUntil[k] and STATE.FAST_TICK < madHeavyUntil[k] then return end  -- heavy owns TDI
        AVU.SetTimeDilation(actor, 1.1)
    end, THROW_TDI_MS)
end


-- Fired the instant a native throw begins (CombatHooks' Broadcast_ThrowGrenade hook).
function H.MadThrow(actor)
    aimNativeThrow(actor)
    madThrowTDI(actor)
end


-- MELEE: the alchemist's version of the Super Sapper's double punch - it smashes a flask in each
-- hand rather than detonating a grenade, and the second one blows the two bodies apart.
--   * The Mad Rat is itself acid-immune (NpcResistances), so it can crack corrosive at its own feet.
--   * Corrosive first, unstable second: the finisher is the bigger cluster, matching the shove.
local MAD_PUNCH = {
    Cd       = MAD_MELEE_FLASK_CD,
    Rate     = 2,
    Apex     = 0.5,    -- MeleeHitApex, base 0.2 - lifted so the native contact lands ON beat 1
                       --   (0.5 / Rate = the 0.25s beat) instead of ahead of it
    Beat1Ms  = 250,
    Beat2Ms  = 500,
    Knock    = 1500,
    KnockUp  = 250,
    Deps     = { PC.FlaskCorrosive, PC.FlaskUnstable },
}

MAD_PUNCH.Fire = function(actor, at, beat)
    local flask = (beat == 1) and PC.FlaskCorrosive or PC.FlaskUnstable
    local cfg = FLASK_TUNING[flask] or {}
    spawnFlask(actor, {
        Class = flask,
        Location = FVector(at.X, at.Y, at.Z + 10),
        Velocity = FVector(0, 0, -300),   -- straight down out of the fist, cracks on contact
        Gravity = 1.0,
        Damage = flaskDamage() * ((beat == 1) and 1 or 2),
        AoEInner = cfg.AoEInner or 60, AoEOuter = cfg.AoEOuter or 240,
    })
end

function H.MadPunch(actor)
    if punchPair(actor, madLastMeleeTick, MAD_PUNCH) then
        LogDebug("Mad Rat - flask punch pair", SETTINGS.DEBUG_NPC_ACTIONS)
    end
end


-- Where each flask of the death payload lands: evenly spaced on a ring around the body, dropped
-- straight down from a LOW height so it lands on its slot. A random start angle keeps the ring from
-- reading as a compass rose every time.
--   * The ring is the point - a huddle of flasks around one crater is a single overlapping blast,
--     while a ring the width of the corpse denies the ground around it.
local MAD_DEATH_RING = 200   -- uu (2m) from the body

local function madDeathFlask(actor, loc, index, count, spin, class, damage)
    local cfg = FLASK_TUNING[class] or {}
    local at = AVM.RingPoint(loc, MAD_DEATH_RING, index + spin, count, 60)
    spawnFlask(actor, {
        Class = class,
        Location = at,
        Velocity = FVector(0, 0, -80),
        Gravity = 1.0, Damage = damage,
        AoEInner = cfg.AoEInner, AoEOuter = cfg.AoEOuter,
    })
end


-- The death payload, dropped around `loc` (where it actually died/detonated).
--   * KAMIKAZE = a flask scatter (MAD_HARD.KamikazeCount - hard mode doubles the payload it was
--     carrying); killed normally = one of each, the megaton being the "you killed me" finale boom.
function H.MadDeathPayload(actor, loc)
    local key = Utils.ActorKey(actor)
    if key then
        madFirstCombatTick[key] = nil; madKamikazeAt[key] = nil; madKamikazeDone[key] = nil
        madLastMeleeTick[key] = nil; madPriming[key] = nil
        madKamikazeFired[key] = nil; madKamikazeTries[key] = nil
    end
    if not loc then return end

    local kamikaze = false
    pcall(function() kamikaze = actor.KamikazeActive == true end)

    local spin = math.random()   -- fractional slot offset: rotates the whole ring, keeps the spacing

    Utils.QueueWork(function()
        if kamikaze then
            local count = byMode(MAD_HARD.KamikazeCount)
            for i = 0, count - 1 do
                madDeathFlask(actor, loc, i, count, spin,
                    FLASKS[math.random(1, #FLASKS)], flaskDamage())
            end
        else
            local killed = {
                { PC.FlaskCorrosive, flaskDamage() },
                { PC.FlaskHoly,      flaskDamage() },
                { PC.FlaskUpdraft,   flaskDamage() },
                { PC.FlaskMegaton,   150 },
            }
            for i, e in ipairs(killed) do
                madDeathFlask(actor, loc, i - 1, #killed, spin, e[1], e[2])
            end
        end
    end, 120)
end


-- =======================================================================
-- ROCKET RAT: one impulse (up + forward) fired after a windup flourish, at normal gravity.
--   * One impulse only - two impulses (a pop, then an apex thrust) read as a double jump. Don't
--     reintroduce that.
--   * The capsule phase-shifts against the Pawn channel during flight, so a body in the takeoff
--     path can't eat the launch (see rocketPhase); world geometry still blocks normally.
--   * Tuning: RJ_HARD.Cd cadence, RJ_UP arc height, RJ_FWD reach. For a low ceiling, drop both RJ_UP
--     and RJ_FWD together, or the jump turns into a flat skim.
-- =======================================================================

local RJ_MIN_SQ    = 100 * 100
local RJ_MAX_SQ    = 3200 * 3200
local RJ_UP        = 1200   -- vertical impulse (arc height; ~7.5m peak at normal gravity)
local RJ_FWD       = 950    -- forward impulse - re-asserted in flight, so it IS the cruise speed
local RJ_FLIGHT_T  = 30     -- FAST_TICKs (~3s) the flight window lasts; landing ends it early
local RJ_LAND_GRACE = 3     -- FAST_TICKs before a not-falling read counts as "landed"
local RJ_DEFAULT_GRAV = 1.0 -- normal gravity (consistent, predictable arc)
local RJ_WINDUP_TDI = 3     -- fast TDI for the pre-jump flourish (mirrored to clients)
local RJ_WINDUP_MS  = 750   -- flourish length before the launch fires
local RJ_FRAG_FUZZ  = 700   -- scatter around the target (grenades bounce, so spread them)
local RJ_FRAG_FALL  = 700   -- frag drop speed (higher = lands sooner)
-- Drop schedule, in ms from the launch. It has to fit inside the SHORTEST jump, not the arc the
-- tuning assumes: a low-ceiling hop lands early, and a frag queued past touchdown is thrown by a
-- rat standing on the ground next to the crater.
local RJ_FRAG_FIRST = 200   -- first grenade, just after the body clears the ground
local RJ_FRAG_GAP   = 200   -- spacing between the rest

-- Hard-mode overlays, read at USE time (same rule as MAD_HARD). The takeoff shockwave is Blunt -
-- debuff-free, so it's the safe NPC-inclusive path - and hard mode widens, doubles and shoves it
-- harder so the jump itself becomes the threat rather than just the delivery.
local RJ_HARD = {
    Cd          = { Normal = 90,   Hard = 80 },    -- FAST_TICKs: 9s -> 8s
    FragCount   = { Normal = 4,    Hard = 7 },     -- grenades per jump, aimed around the target
    BlastRadius = { Normal = 500,  Hard = 600 },
    BlastDamage = { Normal = 60,   Hard = 120 },
    BlastKnock  = { Normal = 1200, Hard = 1800 },
}

-- `rj` prefix = the Rocket Rat's per-actor state (ActorKey-keyed, same as the Mad Rat's `mad`).
local rjLastJumpTick = {}   -- key -> totalTicks of the last rocket jump
local rjVel          = {}   -- key -> {x,y} launch horizontal, re-asserted in flight
local rjUntil        = {}   -- key -> FAST_TICK the flight window ends
local rjGrace        = {}   -- key -> FAST_TICK after which a not-falling read means LANDED

-- Let the rat pass THROUGH other bodies for the flight only. ALWAYS paired with endFlight.
--   * The capsule answers OVERLAP on the Pawn channel instead of BLOCK (UE takes the weaker of
--     the pair, so one side is enough).
--   * World geometry is a different channel and still blocks, so it can't clip through floors or
--     walls - this only stops a player/NPC in the takeoff path from eating the launch.
local function rocketPhase(actor, on)
    if Utils.IsActorInvalid(actor) then return end
    pcall(function()
        local cap = actor.CapsuleComponent
        if IsValid(cap) then cap:SetCollisionResponseToChannel(2, on and 1 or 2) end  -- Pawn: Overlap/Block
    end)
end

local function endFlight(actor, key)
    if key then rjUntil[key] = nil; rjVel[key] = nil; rjGrace[key] = nil end
    rocketPhase(actor, false)
end

H.ROCKETRAT_ASSETS = {
    ENUMS.Effects.EXPLOSION_BIG,
    ENUMS.ProjectileClasses.GrenadeFrag,   -- keep the frag warm so mid-air drops don't cold-load
    LAUNCHER_MONTAGE,                      -- the pre-jump flourish
    ENUMS.DamageType.Blunt,                -- the takeoff shockwave's type
    ARRIVAL_MONTAGE,                       -- the portal step-out (AVU.PortalArrival resolves it non-loading)
}


-- [AUTHORITY] Ammo stays full so it never hits the native out-of-rockets kamikaze; the rocket fire
-- itself is suppressed via the cooldown/ability pins instead, since the jump IS the ranged attack.
-- RangedAttack_OnCooldown is re-pinned every tick in H.RocketTick, since combat state clears it.
function H.RocketLoadout(actor)
    pcall(function() actor.MaxAmmoCount = 10 end)
    pcall(function() actor.CurrentAmmoCount = 10 end)
    pcall(function() actor.KamikazeDamage = 200 end)
    pcall(function() actor.RangedAttack_Cooldown = 3600 end)
    pcall(function() actor.RangedAttack_OnCooldown = true end)
    pcall(function() actor.Cooldown_CombatAbility3 = 3600 end)
end


function H.RocketTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    local key = Utils.ActorKey(actor)

    -- AIRBORNE MOMENTUM: re-assert the launch's horizontal velocity every tick during the flight
    -- window - a grenade the BT throws mid-air otherwise zeroes it.
    --   * Runs BEFORE the %5 gate so it's responsive; IsFalling-gated so it never ground-slides.
    --   * Also owns the flight window's END, so the Pawn phase-shift closes on TOUCHDOWN (not a
    --     fixed timer) - RJ_FLIGHT_T is just the backstop.
    if key and rjUntil[key] then
        local m = actor.CharacterMovement
        local falling = false
        if IsValid(m) then pcall(function() falling = m:IsFalling() end) end

        if STATE.FAST_TICK >= rjUntil[key] then
            endFlight(actor, key)
        elseif falling then
            local rv = rjVel[key]
            if IsValid(m) and rv then
                pcall(function()
                    local v = m.Velocity
                    m.Velocity = FVector(rv.x, rv.y, (v and v.Z) or 0)
                end)
            end
        elseif STATE.FAST_TICK > (rjGrace[key] or 0) then
            endFlight(actor, key)   -- landed (grace covers the tick or two before falling latches)
        end
    end

    if totalTicks % 5 ~= 0 then return end

    -- Never run dry, keep the real rocket pinned off, and clear any enrage/kamikaze creep.
    if (actor.CurrentAmmoCount or 0) < 3 then pcall(function() actor.CurrentAmmoCount = 10 end) end
    pcall(function() actor.RangedAttack_OnCooldown = true end)
    pcall(function() if actor.NPCEnraged then actor.NPCEnraged = false end end)
    pcall(function() if actor.KamikazeActive then actor.KamikazeActive = false; actor:OnRep_KamikazeActive() end end)

    if not Utils.IsActorReadyToAttack(actor) then return end
    if not key then return end
    -- Peek: the target/range gates below can still veto, and must not eat the cooldown.
    if not AVU.CooldownReady(rjLastJumpTick, key, byMode(RJ_HARD.Cd), { Now = totalTicks, Peek = true }) then return end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end
    local aLoc = actor:K2_GetActorLocation()
    local tLoc = target:K2_GetActorLocation()
    local distSq = Utils.DistSq(aLoc, tLoc)
    if distSq < RJ_MIN_SQ or distSq > RJ_MAX_SQ then return end
    -- A fresh trace, not the blackboard's: the frags drop around the TARGET, so a target on the floor
    -- below would get grenades out of its own ceiling.
    if not AVU.CanSeeActor(actor, target) then return end

    rjLastJumpTick[key] = totalTicks

    -- PRE-JUMP FLOURISH: spike TDI + play the launcher-equip montage (reads as "aim at feet"),
    -- THEN fire the launch - a visible tell before it blasts off.
    AVU.SetTimeDilation(actor, RJ_WINDUP_TDI)
    AVU.PlayAnimation(actor, LAUNCHER_MONTAGE, 1)
    Utils.QueueWork(function()
        AVU.SetTimeDilation(actor, 1.1)
        if Utils.IsActorInvalid(actor) then return end
        local t2 = actor:GetCurrentCombatTarget()
        local a2 = actor:K2_GetActorLocation()
        local aim = (Utils.IsActorValid(t2) and t2:K2_GetActorLocation()) or tLoc

        local m = actor.CharacterMovement
        -- Normal gravity + ZERO the current velocity so prior running can't skew the impulse.
        --   * StopMovement also cancels the controller's MoveTo.
        --   * LaunchCharacter below OVERRIDES velocity, so the arc is identical every time.
        if IsValid(m) then pcall(function() m.GravityScale = RJ_DEFAULT_GRAV; m:StopMovementImmediately() end) end
        pcall(function() local c = actor:GetController(); if IsValid(c) then c:StopMovement() end end)
        pcall(function() actor:K2_SetActorRotation(Utils.RotatorToTarget(a2, aim), false) end)
        pcall(function() AVU.BroadcastFX(a2, ENUMS.Effects.EXPLOSION_BIG, nil, FVector(0.8, 0.8, 0.8)) end)

        AVU.BlastDamage(actor, a2, {
            Radius = byMode(RJ_HARD.BlastRadius), Damage = byMode(RJ_HARD.BlastDamage),
            DamageType = ENUMS.DamageType.Blunt,
            HitNpcs = true, Knockback = byMode(RJ_HARD.BlastKnock), KnockbackUp = 250,
        })

        -- THE LAUNCH: one impulse, up + forward. Phase the capsule against pawns FIRST, so a body
        -- already pressed into the rat can't absorb it.
        local dir = Utils.Direction(a2, aim)
        rocketPhase(actor, true)
        AVU.LaunchCharacterFrom(actor, aim, RJ_FWD, RJ_UP, true)
        rjVel[key]   = { x = dir.X * RJ_FWD, y = dir.Y * RJ_FWD }
        rjUntil[key] = STATE.FAST_TICK + RJ_FLIGHT_T
        rjGrace[key] = STATE.FAST_TICK + RJ_LAND_GRACE
        LogDebug("Rocket Rat - rocket jump", SETTINGS.DEBUG_NPC_ACTIONS)

        -- GRENADES: aimed AT the target + fuzz (they bounce, so scatter them rather than
        -- hitting a precise spot). Explode on contact = no long roll. Staggered to fall mid-arc.
        for i = 0, byMode(RJ_HARD.FragCount) - 1 do
            Utils.QueueWork(function()
                if Utils.IsActorInvalid(actor) then return end
                local ct = actor:GetCurrentCombatTarget()
                local al = (Utils.IsActorValid(ct) and ct:K2_GetActorLocation()) or aim
                spawnFragAt(actor, FVector(
                    al.X + math.random(-RJ_FRAG_FUZZ, RJ_FRAG_FUZZ),
                    al.Y + math.random(-RJ_FRAG_FUZZ, RJ_FRAG_FUZZ),
                    al.Z + 350), { OnContact = true, Damage = 70, FallSpeed = RJ_FRAG_FALL })
            end, RJ_FRAG_FIRST + i * RJ_FRAG_GAP)
        end
    end, RJ_WINDUP_MS)
end


function H.RocketDeathCleanup(actor)
    local key = Utils.ActorKey(actor)
    if key then rjLastJumpTick[key] = nil end
    endFlight(actor, key)   -- also un-phases the capsule if it died mid-flight
end


return H
