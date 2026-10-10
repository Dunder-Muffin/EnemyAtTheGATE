-- =======================================================================
-- Order Captain helpers - the machinery behind AnteNPCs/OrderCaptain.lua
-- Trident net investigation moved to AnNotes/AnteNPCs/OrderCaptain.md.
--
-- MUST-KNOWS
--   * The net's hit is engine-resolved, not a scripted radius - it carries its own stun. See the
--     TRIDENT banner below for why the dispatch hook forces the net to be armed out of band.
--   * SIGNIFER KITING IS SCRIPTED (FindLosPoint ring + MoveToLocation), NOT BT_Flee/Buff.Fear.
--     Fear renders a fear particle and reads as terrified. Suppressing fire via
--     OverrideSoldierFireLogic was tried and REVERTED: a suppressed captain idles aiming at
--     nothing while muzzle flash and fire noise still leak through.
--   * The Signifer's call-in montage fires 15s+ after mutation, so it is re-LoadAsync'd at fire
--     time - a preload does not pin against GC (S3).
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local AVM = require("AnteUtils.AVMath")
local ASSETS = require("AnteCore.AssetManager")
local Projectile = require("AnteCore.Projectile")

local LogDebug = Utils.LogDebug

local H = {}


-- =======================================================================
-- COMMANDER
-- =======================================================================

-- Variant names and raw rows mixed; a raw row (Grunt_Guard) arrives vanilla.
local SUMMON_TABLE = { "Grunt_Guard", "Grunt_Guard", "Grunt_Guard", "Velites Guard", "Grenadier Guard", "Suppressor Grunt" }
local RESUMMON_TICKS = 100      -- resummon check cadence (FAST_TICK)
local SUMMON_RANGE   = 4000     -- only calls in while a player is within range
-- Alive = reinforcements standing at once; Total = a LIFETIME budget per body (resets if the body
-- unloads and remutates) - a safeguard, not a mechanic the player should count on.
local COMMANDER_CAPS      = { MaxAlive = 1, MaxTotal = 3 }
local COMMANDER_CAPS_HARD = { MaxAlive = 2, MaxTotal = 4 }

-- Reinforcements arrive in a donut, never on top of the caller: the Commander stands inside its
-- own sandbag ring, and a body placed in there is walled in.
local SUMMON_MIN_DIST  = 300    -- 3m, the floor
local SUMMON_MAX_DIST  = 900
local SUMMON_PT_TRIES  = 4      -- donut picks before the hand-walked ring takes over
local SUMMON_RING_DIST = 450
local SUMMON_RING_SLOTS = 8

-- The same radio gesture the Centurion and Signifer use, and the same slice of it: the clip is a
-- ~7s ambient "fiddle with a radio", so START skips the reach-for-the-handset wind-up and MS ends
-- the gesture before the tree walks through it.
local CALL_IN_ANIM  = ENUMS.Anims.STAND_AND_RADIO
local CALL_IN_START = 2      -- seconds into the clip: the handset is already at the ear
local CALL_IN_MS    = 1000   -- how long the gesture parks it
local CALL_IN_SFX   = "RADIO_CALL"   -- the chirp again, loud enough to carry over the fight

-- commander ActorKey -> { alive = { npc, ... }, total = n }
local cmdSummons = {}
-- commander ActorKey -> true, left by OnEnterCombat and spent on the next tick
local cmdOpening = {}

H.COMMANDER_ASSETS = {
    ENUMS.DeployedObjs.BAGWALLCURVE,
    ENUMS.ResourceNodes.RADIO,
    CALL_IN_ANIM,   -- so the call-in montage is resident for PlayMontageReplicated
}


-- [AUTHORITY] Build the barricade + radios on spawn (runs on dedicated too). SpawnDeployable
-- off-hooks each spawn so a deployable's BeginPlay can't hang the spawn hook.
function H.CommanderDeploy(actor)
    if Utils.IsActorInvalid(actor) then return end
    local loc = actor:K2_GetActorLocation()
    if not loc then return end

    local wall = ENUMS.DeployedObjs.BAGWALLCURVE
    local radio = ENUMS.ResourceNodes.RADIO

    -- Don't re-stack: another Commander's wall (or this one's, from a re-run) within 15m = skip.
    local existing = AVU.GetNearbyActorsOfClass(loc, 1500, wall)
    if #existing > 0 then
        LogDebug("Commander - wall already nearby, not rebuilding", SETTINGS.DEBUG_NPC_ACTIONS)
        return
    end

    local floorZ = loc.Z - 88   -- ~capsule half-height (no GetFloorZ in AnteUp2)

    -- PaintColor 11 = Brown = the default M_Sandbag material (/dumppaint-confirmed). PaintPreload
    -- keeps SetPaintColor a cache hit: cold, it blocking-loads in-hook (S2) - this was a crasher.
    local wallOpts = { Faction = 3, Durability = 150, PaintColor = 11,
                       Scale = FVector(1, 1, 1.45), CollisionHandling = 1,
                       PaintPreload = { ENUMS.Components.M_SANDBAG } }
    AVU.SpawnDeployable(wall, FVector(loc.X - 5, loc.Y, floorZ + 5), FRotator(0, 0, 0), wallOpts)
    AVU.SpawnDeployable(wall, FVector(loc.X + 5, loc.Y, floorZ + 5), FRotator(0, 180, 0), wallOpts)

    local radioOpts = { Faction = 3 }
    AVU.SpawnDeployable(radio, FVector(loc.X + 100, loc.Y, loc.Z), FRotator(0, 180, 0), radioOpts)
    AVU.SpawnDeployable(radio, FVector(loc.X - 100, loc.Y, loc.Z), FRotator(0, 0, 0), radioOpts)
    AVU.SpawnDeployable(radio, FVector(loc.X - 75, loc.Y - 72, loc.Z), FRotator(0, 30, 0), radioOpts)
    LogDebug("Commander - barricade deployed", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- [AUTHORITY] Radio-in gesture. LOCKED-IN-PLACE parks the BT (BTD_IsNPCBusy) so it stands still
-- for the call; the chirp is native + replicated on its own. The anim fires minutes after
-- mutation, so it is re-LoadAsync'd at fire time (S3).
local function commanderGesture(actor)
    ASSETS.LoadAsync({ CALL_IN_ANIM }, function()
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        pcall(function()
            local move = actor.CharacterMovement
            if IsValid(move) then move:StopMovementImmediately() end
        end)
        AVU.PlayMontageReplicated(actor, CALL_IN_ANIM, 1, true)
        pcall(function() actor:Broadcast_RadioChirp() end)
        local loc = actor:K2_GetActorLocation()
        if loc then AVU.SendClientFX(loc, CALL_IN_SFX, 2) end
        -- Server-local, so a remote client watches the wind-up instead - the stop is the half that
        -- has to reach everyone.
        AVU.SkipIntoAnimation(actor, CALL_IN_ANIM, CALL_IN_START)
        Utils.QueueWork(function()
            if Utils.IsActorInvalid(actor) then return end
            AVU.StopMontageReplicated(actor, CALL_IN_ANIM)
        end, CALL_IN_MS)
    end)
end


-- A navmesh point in [SUMMON_MIN_DIST, SUMMON_MAX_DIST] of the Commander. GetSpawnPoint's
-- minRadius is a SOFT rule - its projection and fuzz fallbacks can land straight back on the
-- origin - so the distance is re-checked here and the pick retried. When the nav query keeps
-- coming back short, the ring is walked by hand instead. nil = nowhere to put a body this call.
--   * Every candidate also passes AVU.IsSpawnSpotClear with the Commander as the viewer. Its cave
--     posts have navmesh running under sloped rock, and a body placed there stands inside the
--     wall - shooting and throwing grenades through it.
local function commanderSpawnPoint(actor, origin)
    local floorSq = SUMMON_MIN_DIST * SUMMON_MIN_DIST
    local clear = { From = origin }

    for _ = 1, SUMMON_PT_TRIES do
        local pt = Utils.GetSpawnPoint(origin, SUMMON_MAX_DIST, SUMMON_MIN_DIST, 8)
        if pt and Utils.DistSqXY(pt, origin) >= floorSq and AVU.IsSpawnSpotClear(actor, pt, clear) then
            return pt
        end
    end

    local start = math.random(0, SUMMON_RING_SLOTS - 1)
    for i = 0, SUMMON_RING_SLOTS - 1 do
        local slot = AVM.RingPoint(origin, SUMMON_RING_DIST, (start + i) % SUMMON_RING_SLOTS, SUMMON_RING_SLOTS)
        local pt = Utils.ProjectToNav(slot, 200)
        if pt and Utils.DistSqXY(pt, origin) >= floorSq and AVU.IsSpawnSpotClear(actor, pt, clear) then
            return pt
        end
    end

    return nil
end


-- [AUTHORITY] Call in one reinforcement, subject to the alive + lifetime caps. `key` is the
-- caller's ActorKey (the tick already has one memoized).
local function commanderCallIn(actor, key)
    local st = cmdSummons[key]
    if not st then st = { alive = {}, total = 0 }; cmdSummons[key] = st end

    local caps = STATE.HardModeNoMercy and COMMANDER_CAPS_HARD or COMMANDER_CAPS
    if st.total >= caps.MaxTotal then return end

    local alive = {}
    for _, npc in ipairs(st.alive) do
        if Utils.IsActorValid(npc) and not npc.IsDead then alive[#alive + 1] = npc end
    end
    st.alive = alive
    if #alive >= caps.MaxAlive then return end

    local actorLoc = actor:K2_GetActorLocation()
    if not actorLoc or not Utils.IsPlayerNearby(actorLoc, SUMMON_RANGE) then return end

    local spawnLoc = commanderSpawnPoint(actor, actorLoc)
    if not spawnLoc then
        LogDebug("Commander - no clear spawn point this call (distance or geometry)", SETTINGS.DEBUG_NPC_ACTIONS)
        return
    end

    -- Spend the lifetime slot HERE, not in the callback: the spawn is async, and a cap that only
    -- counts arrivals lets a second call start before the first one lands.
    st.total = st.total + 1
    commanderGesture(actor)

    local variantName = SUMMON_TABLE[math.random(1, #SUMMON_TABLE)]
    LogDebug(string.format("Commander - summoning %s (%d/%d)", variantName, st.total, caps.MaxTotal),
        SETTINGS.DEBUG_NPC_ACTIONS)

    -- Render the variant FAST: this one appears directly, with no rappel anim to wait out, so the
    -- base row's SpawnDelay (Grunts = 2700ms) would leave it vanilla-looking while it's fighting.
    AVU.SummonVariant(variantName, spawnLoc, { SpawnDelay = 250 }, function(npc)
        st.alive[#st.alive + 1] = npc
        local target = actor:GetCurrentCombatTarget()
        if Utils.IsActorValid(target) then AVU.ForceAggro(npc, target) end
    end)
end


-- [AUTHORITY, OnEnterCombat] Hard mode opens the fight with a reinforcement already on the way.
-- Only marks the body: the tick owns the stable wrapper and every cap check.
function H.CommanderAggro(actor)
    if not STATE.HardModeNoMercy then return end
    if Utils.IsActorInvalid(actor) then return end
    local key = Utils.ActorKey(actor)
    if key then cmdOpening[key] = true end
end


-- [AUTHORITY, OnDeath] Drop the roster. Plain table, STRING key - it never collects on its own.
function H.CommanderDeath(actor)
    local key = Utils.ActorKey(actor)
    if key then cmdSummons[key], cmdOpening[key] = nil, nil end
end


-- [AUTHORITY] Refill the squad on a slow cadence, or immediately when hard mode's aggro mark is up.
function H.CommanderTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    if not Utils.IsActorReadyToAttack(actor) then return end

    local key = AVU.CachedFullName(actor)
    if not key then return end
    local opening = cmdOpening[key]
    if opening then cmdOpening[key] = nil end

    if not opening and totalTicks % RESUMMON_TICKS ~= 0 then return end

    AVU.SuppressMelee(actor)   -- it doesn't melee
    commanderCallIn(actor, key)
end


-- =======================================================================
-- TRIDENT
-- =======================================================================

-- TRIDENT NET DECODE - full investigation in AnNotes/AnteNPCs/OrderCaptain.md.
-- OnRangedAttack is effectively a POST hook ([[ue4ss-local-script-call-hook-is-post]]), so the net
-- is armed OUT OF BAND: H.TridentArmNet sets OverrideSoldierFireLogic at mutation and at each
-- reload start, suppressing the first shot of the magazine; the dispatch fires our net in its place.
-- projectile_net_ammo (the net gun's own round, 2250/0.8) deals zero damage, so its native buff
-- step never runs - we apply Debuff_NettedCannon ourselves on Projectile.Queue's OnHit, via
-- Utils.ApplyBuffLinked (players get Debuff_Zapped instead; NettedCannon silently no-ops on them).
-- BuffsIgnoreAllies defaults true on the row (blocks players); PreFinish clears it.
-- Net duration varies per NPC class (native escape timers / NetDurationReductionPercentage) -
-- that's the game's own design, not a bug here.
local TRIDENT_NET_CLASS   = ENUMS.ProjectileClasses.Net
local TRIDENT_NET_SPEED   = 2200          -- flat cruise; it is a gun now, not a lob
-- Scale is COLLISION as well as looks: the row's CollisionRadius is 20, so a 3x net swept a 60uu
-- sphere and clipped doorframes and cover on the way out. 2x is still an obvious net.
local TRIDENT_NET_LIFE_S  = 3             -- missed net despawns shortly

-- Muzzle and aim height must match, or every shot aims downward. They used to differ (60/30),
-- which drove the net into the floor at close range.
local TRIDENT_MUZZLE_Z    = 60            -- actor chest height
local TRIDENT_AIM_Z       = 60            -- target chest height
-- Spawn the net clear of the firer's own collision: at 2x scale its sphere is a 40uu radius on top
-- of the capsule, so a net born at the chest overlaps its own thrower on the first frame.
local TRIDENT_MUZZLE_FWD  = 110           -- along the aim, from the chest
local TRIDENT_STUN_S      = 2.5           -- stun duration (native 2.5s)
local TRIDENT_FIRE_DELAY_MS = 100         -- delay after Server_DoRangedAttack, so it has a pose
local TRIDENT_RESET_MS    = 100           -- after the shot, before the BT release

-- Net runtime dependencies
local TRIDENT_NET_DEPS = { ENUMS.DamageType.Parent,
                           ENUMS.BuffObjects.NettedCannon, ENUMS.DamageType.Electric,
                           ENUMS.BuffObjects.Stunned, ENUMS.Effects.LIGHTNING_STUN }

-- Appearance - gun replacement
local TRIDENT_GUN_SCALE      = FVector(0.9, 0.9, 0.9)
local TRIDENT_GUN_LOC        = FVector(0, -4, 0)
local TRIDENT_GUN_ROT        = FRotator(0, 0, 0)
local TRIDENT_GUN_DIFFUSE    = FVector(0.05, 0.05, 0)   -- M_NetLauncher parents M_AbioticItems_Master,
local TRIDENT_GUN_EMISSIVE   = FVector(10, 3, 0)        -- so DiffuseColor tints it and "Color" is inert
local TRIDENT_GUN_EMSTRENGTH = 1                        -- the emissive area is tiny; raise to brighten

-- Kept warm for hitching
local TRIDENT_RELOAD_ANIM = ENUMS.Anims.CAPTAIN_RELOAD
local TRIDENT_RELOAD_RATE = { Normal = 2, Hard = 3 }   -- reload playrate: the gap between nets

-- Has a chance to dodge when hit
local TRIDENT_DODGE = { Chance = 0.5, CooldownTicks = 30 }

-- Chance to roll aside before reloading - guessed from remaining ammo since this fires on
-- Server_DoRangedAttack, with a delay to let the shot finish first.
local TRIDENT_LAST_BURST     = 2
local TRIDENT_ROLL_RATE      = 0.6
local TRIDENT_ROLL_DELAY_MS  = 900

local netArmed = {}   -- Utils.ActorKey (fresh wrapper per dispatch fire) -> true while the next shot owes a net

H.TRIDENT_ASSETS = {
    ENUMS.Components.SM_NETGUN,
    TRIDENT_NET_CLASS,
    ENUMS.BuffObjects.NettedCannon,
    ENUMS.BuffObjects.Stunned,
    ENUMS.Effects.LIGHTNING_STUN,
    ENUMS.DamageType.Parent,
    ENUMS.DamageType.Electric,
    TRIDENT_RELOAD_ANIM,
    AVU.GK_DODGE_ANIMS[1], AVU.GK_DODGE_ANIMS[2],
}


-- [RENDERER] Swap the magnum for a pistol-sized net launcher. The gun COMPONENT is only HIDDEN,
-- never destroyed - the native fire path still reads it for the muzzle-flash socket.
function H.TridentGear(actor)
    if Utils.IsActorInvalid(actor) then return end
    pcall(function()
        local gun = actor.Gun
        if IsNotValid(gun) then return end
        gun:SetVisibility(false, false)

        local sock = gun:GetAttachSocketName()
        AVU.AttachStaticMesh(actor, ENUMS.Components.SM_NETGUN,
            sock and sock:ToString() or "r_weapon_ranged1", {
                Location = TRIDENT_GUN_LOC,
                Rotation = TRIDENT_GUN_ROT,
                Scale = TRIDENT_GUN_SCALE,
                DiffuseColor = TRIDENT_GUN_DIFFUSE,
                -- applyComponentColors is an if/elseif chain a Color/Tint key would WIN outright,
                -- and its EmissiveColor branch only runs when EmissiveStrength comes with it.
                EmissiveColor = TRIDENT_GUN_EMISSIVE,
                EmissiveStrength = TRIDENT_GUN_EMSTRENGTH,
            })
    end)
end


-- [AUTHORITY] ARM the net for the next shot. Called at mutation (first magazine) and at the START
-- of every reload - never from the ranged dispatch, which is too late (see the banner).
function H.TridentArmNet(actor)
    if Utils.IsActorInvalid(actor) then return end
    local key = Utils.ActorKey(actor)
    if key then netArmed[key] = true end
    pcall(function() actor.OverrideSoldierFireLogic = true end)
end


-- [AUTHORITY, OnReload] Retime the reload AND re-arm the net for the fresh magazine.
function H.TridentReload(actor)
    AVU.ReloadDilation(actor, STATE.HardModeNoMercy and TRIDENT_RELOAD_RATE.Hard
                                                    or TRIDENT_RELOAD_RATE.Normal)
    H.TridentArmNet(actor)
end


-- [DEBUG] Sample the net's actual flight values off the live component (BeginPlay may not keep
-- what Projectile.Queue set). Sampled at spawn and +300ms: right at spawn but wrong later means
-- something RE-APPLIED the row rather than our write failing. DEBUG_NPC_ACTIONS only.
local function netFlightProbe(proj)
    if not SETTINGS.DEBUG_NPC_ACTIONS then return end
    -- PLAIN IsValid, not Utils.IsActorValid: that helper reads actor.NPCData, which a projectile
    -- lacks, so it would report every projectile as invalid.
    local function sample(tag)
        if IsNotValid(proj) then return end
        pcall(function()
            local pm = proj.ProjectileMovement
            if IsNotValid(pm) then return end
            local v = pm.Velocity
            local speed = math.sqrt((v.X or 0) ^ 2 + (v.Y or 0) ^ 2 + (v.Z or 0) ^ 2)
            LogDebug(string.format("Trident net %s: speed=%.0f max=%.0f grav=%.2f vz=%.0f",
                tag, speed, tonumber(pm.MaxSpeed) or -1,
                tonumber(pm.ProjectileGravityScale) or -1, v.Z or 0), true)
        end)
    end
    sample("spawn")
    Utils.QueueWork(function() sample("+300ms") end, 300)
end


-- [AUTHORITY, Projectile OnHit] The net connected with something - net it if it is a character.
--   * Runs INSIDE the impact hook, so nothing here may spawn or load. ApplyBuffLinked is already
--     off-hook (EIGT) and is the server->player path; that is the whole body.
--   * `CharacterMovement` is the cheap "is this a character" test - present on players and NPCs,
--     absent on the walls and props a missed net hits (the AVU.UnstickFromProp lesson).
local function tridentNetHit(proj, other)
    if IsNotValid(other) then return end
    local isCharacter = false
    pcall(function() isCharacter = IsValid(other.CharacterMovement) end)
    if not isCharacter then return end

    -- A player silently refuses Debuff_NettedCannon (the game never nets a player), so they get
    -- Debuff_Zapped instead - the proven player stun (same as AVU.BlastDamage's Chieftain nova),
    -- whose electric FX also reads as an electrified net. NPCs keep the real net: mesh, NPC_Base's
    -- netted state, native escape timers.
    local isPlayer = Utils.IsPlayer(other)
    local row = isPlayer and ENUMS.Debuffs.Zapped or ENUMS.Debuffs.NettedCannon

    -- Applying by hand skips the immunity list the native appliers honour, so ask it ourselves -
    -- this is what keeps a Trident (and its net-immune Order kin) out of another Trident's net.
    if AVU.IsDebuffImmune(other, row) then return end

    Utils.ApplyBuffLinked(other, row, TRIDENT_STUN_S, nil, 0)
    LogDebug("Trident - net caught " .. tostring(Utils.GetActorName(other))
        .. (isPlayer and " (zapped)" or " (netted)"), SETTINGS.DEBUG_NPC_ACTIONS)
end


-- [AUTHORITY] Loose one net at the current target.
local function tridentFireNet(actor)
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then
        AVU.ReleaseSoldierBT(actor)   -- nothing to shoot at, but the BT still needs its valve
        return
    end

    local o = actor:K2_GetActorLocation()
    local t = target:K2_GetActorLocation()
    if not o or not t then return end
    local chest = FVector(o.X, o.Y, o.Z + TRIDENT_MUZZLE_Z)
    local aim = FVector(t.X, t.Y, t.Z + TRIDENT_AIM_Z)
    local dir = Utils.Direction(chest, aim)
    local origin = FVector(chest.X + dir.X * TRIDENT_MUZZLE_FWD,
                           chest.Y + dir.Y * TRIDENT_MUZZLE_FWD,
                           chest.Z + dir.Z * TRIDENT_MUZZLE_FWD)

    pcall(function() actor:ConsumeAmmo() end)   -- our spawn, so nothing else burns the round

    Projectile.Queue(origin, dir, TRIDENT_NET_CLASS, nil, {
        Owner = actor,               -- ignore the thrower for the whole flight
        VelocityOverride = true,     -- flat velocity set pre-spawn -> never arcs, client matches
        Velocity = TRIDENT_NET_SPEED,
        MaxSpeed = TRIDENT_NET_SPEED + 1000,   -- > Velocity, else the row's own cap clamps it
        GravityScale = 0,
        FlightRow = ENUMS.ProjectileRows.NetFlat,   -- the net's own row arcs at 0.8 on a client; its size rides the row too
        LifeSpan = TRIDENT_NET_LIFE_S,
        NoTravelAudio = true,
        Preload = TRIDENT_NET_DEPS,
        -- REQUIRED: Projectile.Queue wipes the row's BuffDebuffToApply by default. NettedCannon is
        -- the entire payload here (row's CanDealDamage = false) - without this the net does nothing.
        KeepDebuff = true,
        -- Both plain bools the impact path reads: let the net buff a PLAYER, and stop it dropping
        -- a lootable `net` item every shot (a Trident left alone would carpet the room).
        PreFinish = function(proj)
            pcall(function() proj.BuffsIgnoreAllies = false end)
            pcall(function() proj.SpawnImpactItemAfterHit = false end)
            pcall(function() proj.SpawnImpactItemIfBuffApplyFails = false end)
        end,
        -- Re-assert post-Finish as well: BeginPlay runs inside FinishSpawningActor and rebuilds
        -- the projectile from its row, so a pre-Finish bool is only safe if nothing there touches
        -- it. Cheap to do both rather than rely on that.
        PostFinish = function(proj)
            pcall(function() proj.BuffsIgnoreAllies = false end)
            pcall(function() proj.SpawnImpactItemAfterHit = false end)
            netFlightProbe(proj)
        end,
        -- The payload. See the banner: the projectile's own buff step cannot run on a zero-damage
        -- row, so this is what actually nets anybody.
        OnHit = tridentNetHit,
    })

    LogDebug("Trident - net fired", SETTINGS.DEBUG_NPC_ACTIONS)

    -- The override suppressed the native burst, so nobody broadcasts CombatReset and the BT's
    -- ranged task would otherwise wait on it forever.
    Utils.QueueWork(function() AVU.ReleaseSoldierBT(actor) end, TRIDENT_RESET_MS)
end


-- [AUTHORITY, OnRangedAttack] Consume the arm: this shot was the suppressed one, so put the net
-- where the burst would have been and hand the gun back for the rest of the magazine.
function H.TridentRangedAttack(actor)
    if Utils.IsActorInvalid(actor) then return end
    local key = Utils.ActorKey(actor)
    if not key then return end

    if netArmed[key] then
        netArmed[key] = nil
        -- Clears for the NEXT body, which is exactly right: this one already ran suppressed.
        pcall(function() actor.OverrideSoldierFireLogic = false end)
        Utils.QueueWork(function() tridentFireNet(actor) end, TRIDENT_FIRE_DELAY_MS)
        return
    end

    -- Nearly dry -> roll aside before the reload. The ammo read is POST-first-shot, so this is
    -- "few rounds left", not an exact magazine boundary.
    local cur = 0
    pcall(function() cur = actor.CurrentAmmoCount or 0 end)
    if cur > 0 and cur <= TRIDENT_LAST_BURST then
        Utils.QueueWork(function()
            if AVU.DodgeRoll(actor, { Chance = 1, CooldownTicks = 0, Rate = TRIDENT_ROLL_RATE }) then
                LogDebug("Trident - magazine-out roll", SETTINGS.DEBUG_NPC_ACTIONS)
            end
        end, TRIDENT_ROLL_DELAY_MS)
    end
end


-- [OnDeath] Drop the arm. Plain table, STRING key - it never collects on its own.
function H.TridentDeath(actor)
    local key = Utils.ActorKey(actor)
    if key then netArmed[key] = nil end
end


-- [AUTHORITY, OnDamageTaken] Reflex side-roll when hit. Thin wrapper: AVU.DodgeRoll already
-- handles the fresh-wrapper keying and one-tick defer a ProcessDamage dispatch needs.
function H.TridentDodge(actor, damage, dmgType)
    AVU.DodgeRoll(actor, TRIDENT_DODGE)
end


-- =======================================================================
-- SIGNIFER
-- =======================================================================

local SIG_CHECK_TICKS   = 20     -- ~2s decision cadence
local SIG_CALL_COOLDOWN = 150    -- ~15s between call-ins 
local SIG_MAX_ALIVE     = 2      -- max reinforcements alive
local SIG_CALL_MAX_DIST = 1500   -- only radios in while a player is within ~15m
local SIG_KITE_DIST     = 1000   -- player closer than ~10m -> retreat. Doubles as the call-in floor:
                                 -- the retreat branch returns first, so calls only happen beyond it
local SIG_KITE_MIN      = 1500   -- preferred distance from target
local SIG_KITE_MAX      = 2500
local SIG_KITE_FALLBACK = 1200   -- cornered (no navmesh/LoS point in band): back straight away this far
local SIG_SUMMON_NAME   = "Tiro Trooper"
local SIG_CALL_ANIM     = ENUMS.Anims.STAND_AND_RADIO
-- The clip is a ~7s ambient "fiddle with a radio" and the lock outlasts it by a second, so only a
-- slice of it is used: START skips the reach-for-the-handset wind-up, MS ends the gesture and the
-- busy window together. See AnNotes/AnteNPCs/OrderGrunt.md - the Centurion's mark works the same way.
local SIG_CALL_START    = 2      -- seconds into the clip: the handset is already at the ear
local SIG_CALL_MS       = 1000   -- how long the gesture parks it
local SIG_CALL_SFX      = "RADIO_CALL_FAR"   -- louder than the others: it radios from the back

-- Banner/helm bone axes are rotated vs world-up, so the Rotation values are hand-tuned guesses.
local SIG_BANNER_SCALE  = FVector(0.45, 0.45, 0.45)   -- 5.4m pole -> ~2.4m standard
local SIG_BANNER_OFFSET = FVector(0, -5, -20)
local SIG_BANNER_ROT    = FRotator(0, 90, 0)
local SIG_HELM_TINT     = FVector(2.2, 1.7, 0.6)      -- greyblack helm x warm >1 = dark gold
local SIG_HELM_OFFSET   = FVector(0, -2, 0)
local SIG_HELM_ROT      = FRotator(-90, 90, 0)        -- the NVGS "head"-bone attach orientation
local SIG_HELM_SCALE    = FVector(1.15, 1.15, 1.15)

-- signifer -> its living summons / last call-in tick (weak keys: GC'd bearers drop)
local sigSummons     = setmetatable({}, { __mode = "k" })   -- actor wrapper -> array of live Tiros
local sigLastCallTick = setmetatable({}, { __mode = "k" })  -- actor wrapper -> FAST_TICK

H.SIGNIFER_ASSETS = {
    SIG_CALL_ANIM,   -- also re-loaded at each fire
    ENUMS.Components.SM_BANNER_POLE,
    ENUMS.Components.M_BANNER_ORDER,
    ENUMS.Components.SM_HELM_PREACHER,
}


-- [RENDERER] Hide the radio pack (the magnum stays - it shoots), mount the banner, swap the beret
-- for the gold-washed Preacher helm. Attach* re-resolves by path, so it is GC-safe (S3).
function H.SigniferDress(actor)
    pcall(function() actor.backpack:SetVisibility(false, true) end)
    pcall(function() actor.Helmet:SetVisibility(false, true) end)

    AVU.AttachStaticMesh(actor, ENUMS.Components.SM_BANNER_POLE, "backpack", {
        Material = ENUMS.Components.M_BANNER_ORDER,   -- slot 0: the cloth defaults to GATEKEEPER
        Location = SIG_BANNER_OFFSET,
        Rotation = SIG_BANNER_ROT,
        Scale = SIG_BANNER_SCALE,
    })
    AVU.AttachStaticMesh(actor, ENUMS.Components.SM_HELM_PREACHER, "head", {
        Location = SIG_HELM_OFFSET,
        Rotation = SIG_HELM_ROT,
        Scale = SIG_HELM_SCALE,
        Color = SIG_HELM_TINT,
    })
end


-- [AUTHORITY] Back out to a navmesh point 15-25m from the player WITH eye-line (it wants to watch
-- its troops work). Cornered = no such point -> back straight away as far as the nav allows, which
-- is the OPT-IN half of AVU.KiteFrom: safe here (open ground), NOT safe on an edged arena.
local function signiferRetreat(actor, player)
    AVU.KiteFrom(actor, player, {
        MinDist = SIG_KITE_MIN, MaxDist = SIG_KITE_MAX,
        Fallback = SIG_KITE_FALLBACK, Label = "Signifer",
    })
end


-- [AUTHORITY] Radio-in gesture + one Tiro Trooper rappelling in beside the Signifer.
local function signiferCallIn(actor, loc)
    -- HALT first (cancels any in-flight move order, ours or the BT's), then play LOCKED-IN-PLACE:
    -- that also parks the BT (BTD_IsNPCBusy), so it stands still for the whole call instead of
    -- walking through it. The chirp is native + replicated on its own.
    ASSETS.LoadAsync({ SIG_CALL_ANIM }, function()
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        pcall(function()
            local c = actor:GetController()
            if IsValid(c) then c:StopMovement() end
        end)
        pcall(function()
            local move = actor.CharacterMovement
            if IsValid(move) then move:StopMovementImmediately() end
        end)
        AVU.PlayMontageReplicated(actor, SIG_CALL_ANIM, 1, true)
        pcall(function() actor:Broadcast_RadioChirp() end)
        local at = actor:K2_GetActorLocation()
        if at then AVU.SendClientFX(at, SIG_CALL_SFX, 2) end
        -- Server-local, so a remote client watches the wind-up instead - the stop is the half that
        -- has to reach everyone.
        AVU.SkipIntoAnimation(actor, SIG_CALL_ANIM, SIG_CALL_START)
        Utils.QueueWork(function()
            AVU.StopMontageReplicated(actor, SIG_CALL_ANIM)
        end, SIG_CALL_MS)
    end)

    local spawnLoc = Utils.GetSpawnPoint(loc, 350, 150)
    if not spawnLoc then return end

    -- Always rappel, headroom or not (def.RopeSpawn on the Tiro). The rope grows UPWARD from a body
    -- that never leaves the floor, so a low ceiling costs a clipped rope - a far smaller tell than a
    -- reinforcement popping into existence, which is what the old headroom veto produced indoors.
    local aggroDelayMs = 4200   -- rope-down parks the BT ~3.5s

    AVU.SummonVariant(SIG_SUMMON_NAME, spawnLoc, {}, function(npc)
        local list = sigSummons[actor]
        if list then list[#list + 1] = npc end
        -- March orders: the Signifer's own target, else the nearest player.
        local target = actor:GetCurrentCombatTarget()
        if not Utils.IsActorValid(target) then target = Utils.NearestPlayer(spawnLoc) end
        if Utils.IsActorValid(target) then AVU.ForceAggro(npc, target, aggroDelayMs) end
    end)
    LogDebug("Signifer - calling in a Tiro", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- [AUTHORITY] Back away from target and call in reinforcements
function H.SigniferTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    if totalTicks % SIG_CHECK_TICKS ~= 0 then return end
    if not Utils.IsActorReadyToAttack(actor) then return end

    AVU.SuppressMelee(actor)

    local loc = actor:K2_GetActorLocation()
    if not loc then return end
    local player, distSq = Utils.NearestPlayer(loc)
    if not player then return end

    if distSq < SIG_KITE_DIST * SIG_KITE_DIST then
        signiferRetreat(actor, player)
        return
    end

    -- Comfortable distance -> periodic radio-in (loose cooldown, capped alive count).
    if distSq > SIG_CALL_MAX_DIST * SIG_CALL_MAX_DIST then return end
    local now = STATE.FAST_TICK
    -- Peek: the alive-count cap below can still veto the call, and must not eat the cooldown.
    if not AVU.CooldownReady(sigLastCallTick, actor, SIG_CALL_COOLDOWN, { Now = now, Peek = true }) then return end

    local alive = {}
    for _, npc in ipairs(sigSummons[actor] or {}) do
        if Utils.IsActorValid(npc) and not npc.IsDead then alive[#alive + 1] = npc end
    end
    sigSummons[actor] = alive
    if #alive >= SIG_MAX_ALIVE then return end

    sigLastCallTick[actor] = now
    signiferCallIn(actor, loc)
end

return H
