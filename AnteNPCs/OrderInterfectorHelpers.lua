-- =======================================================================
-- ORDER INTERFECTOR HELPERS - the blink machinery behind AnteNPCs/OrderInterfector.lua.
--
-- MUST-KNOWS (implementation; the def header carries the base-class decode)
--   * Dagger fade: GRP fade only hides components named Gun/Helmet/backpack, not the four dagger
--     meshes. daggersVisible() hides them mid-fade and restores the in-combat pair on arrival.
--   * Shard throw uses PROJ.Queue, not FireProjectileRow: the shard row (1000uu/s, gravity 0.6)
--     can't reach 10-15m unsolved, so we solve the arc (AVM.ArcSpeed) and raise MaxSpeed past the
--     row's silent 1000 cap.
--   * Freeze-on-hit is gated per VICTIM by H.WINTER.FreezeCdTicks - the only gate. `attacker` may
--     be the projectile or nil (stale DoT tick), never the NPC, so never read it in the handler.
--     The same cooldown also absorbs Sharp/Acid DoT re-firing OnDealtDamage per tick
--     ([[anteup2-ondealtdamage-fires-per-dot-tick]]).
--   * Freeze apply (Utils.ApplyBuffLinked) is EIGT off-hook; BLINK_DEPS preloads
--     BuffObject_Stunned_Frozen + its niagara at fade-out start so the 2.5s fade is the warm-up.
--
-- KNOBS the helpers own are H.WINTER / H.PEREMPTOR (+ a few locals below); the def owns
-- stats/appearance knobs.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local ASSETS = require("AnteCore.AssetManager")
local PROJ = require("AnteCore.Projectile")
local G = require("AnteData.Items").Global
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local AVM = require("AnteUtils.AVMath")
local GRP = require("AnteNPCs.OrderGroupeHelpers")   -- the shared wash/fade kit

local LogDebug = Utils.LogDebug

local H = {}

-- =======================================================================
-- KNOBS
-- =======================================================================

-- The blink cycle (2 regular repositions then 1 shard blink, repeat) + the shard throw.
H.WINTER = {
    BlinkCdTicks      = 80,    -- ~8s between blink attempts (in combat)
    BlinkSpecialEvery = 3,     -- every Nth successful blink is the shard blink
    RegularMin        = 500,   -- regular reposition ring around the TARGET (uu)
    RegularMax        = 1500,
    SpecialMin        = 1000,  -- shard blink ring: 10-15m out
    SpecialMax        = 1500,
    HoldMs            = 700,   -- invisible linger between full fade and the hop
    DaggerHideMs      = 750,   -- knives can't fade (items master ignores params) - pop mid-fade
    PauseS            = 1.5,   -- regular-blink arrival pause (ParryStun; the counterplay window)
    PuffMs            = 1000,  -- exit puff time: body reads gone ~1s into the fade, not at fade-end
    PuffScale         = 0.6,   -- small - keep blink FX cheap (microlag lesson)

    ThrowMontageMs    = 150,   -- arrival -> throw montage start
    ThrowReleaseMs    = 650,   -- arrival -> shard release (montage wind-up before the flick)
    ShardArcDeg       = 18,    -- flat-ish hard throw; ArcSpeed solves the speed for the range
    ShardGravity      = 0.6,   -- MUST match the row's ProjectileGravityScale or the solve lies
    ShardSpeedCap     = 3000,  -- MaxSpeed override (row caps at 1000 = silent clamp)
    ShardDamage       = 45,    -- native knives are 30/hit; the special earns a premium
    ShardLifespan     = 4,
    FreezeSecs        = 2,     -- Debuff_Frost on ANY landed hit (row default is 5)
    FreezeCdTicks     = 80,    -- ~8s per VICTIM - the whole gate (and what eats the DoT re-fires)
    FreezeCdHard      = 65,
    TellScale         = 0.5,   -- the frost tell: hand blizzard burst at throw wind-up
}

-- Everything a blink can touch after mutation. Warmed at fade-out start, so the 2.5s fade beats
-- any cold load (S3: def.Assets preloads do NOT stick - re-warm at fire time).
H.BLINK_DEPS = {
    ENUMS.Anims.INTERFECTOR_THROW_KNIVES,
    ENUMS.Components.SM_THROWING_DART_TECH,
    ENUMS.Effects.NIAGARA_FLASK_BLIZZARD,
    ENUMS.Effects.NIAGARA_SNOWBALL_EXPLODE,  -- the shard's impact frost burst (OnSpawned)
    ENUMS.Effects.NIAGARA_DEBUFF_FROZEN,     -- Frost/SniperRifleIce body FX (first-apply hitch)
    ENUMS.BuffObjects.StunnedFrozen,         -- what Frost + SniperRifleIce apply
    ENUMS.BuffObjects.Stunned,               -- what ParryStun applies (the arrival pause)
}

-- =======================================================================
-- PER-ACTOR / MODULE STATE
-- =======================================================================

local lastBlinkTick = setmetatable({}, { __mode = "k" })   -- actor -> FAST_TICK of last blink attempt (OnTick wrapper is stable)
local blinkCount    = setmetatable({}, { __mode = "k" })   -- actor -> completed-blink counter (drives the 2+1 cycle)
local lastFreezeTick = {}          -- victim ActorKey -> FAST_TICK of that victim's last freeze

-- =======================================================================
-- APPEARANCE (renderer)
-- =======================================================================

-- The winter wash: cool overdrive of the base textures + a cyan glow. Same values as def.Tint -
-- damage-stage texture updates rebuild the body material and drop param writes, so the def
-- re-asserts this from OnDamageTaken and the client tick.
H.WINTER_TINT = {
    Color = FVector(5, 29, 40),
}

function H.WinterWash(actor)
    AVU.TintMesh(actor, H.WINTER_TINT)
end

-- Ice daggers: swap all four dagger components to the icicle material. A SWAP, not a tint -
-- M_Dagger_Interfector parents M_AbioticItems_Master, which ignores every tint param (the
-- Rook-shield lesson). Slot 0 is the whole knife. Fresh-resolved by path (S3).
local DAGGER_COMPONENTS = { "DaggerHeldL", "DaggerHeldR", "DaggerEquipL", "DaggerEquipR" }

function H.IceDaggers(actor)
    local mat = ASSETS.GetIfValid(ENUMS.Components.M_ICICLE)
    if IsNotValid(mat) then return end
    for _, name in ipairs(DAGGER_COMPONENTS) do
        pcall(function()
            local comp = actor[name]
            if IsValid(comp) then comp:SetMaterial(0, mat) end
        end)
    end
end

-- Show/hide the knives around a fade (see MUST-KNOWS). Restoring shows the IN-COMBAT pair only.
local function daggersVisible(actor, visible)
    pcall(function()
        if IsValid(actor.DaggerHeldL) then actor.DaggerHeldL:SetVisibility(visible, false) end
        if IsValid(actor.DaggerHeldR) then actor.DaggerHeldR:SetVisibility(visible, false) end
        -- Equip pair stays hidden either way while fighting; only re-hide on restore.
        if IsValid(actor.DaggerEquipL) then actor.DaggerEquipL:SetVisibility(false, false) end
        if IsValid(actor.DaggerEquipR) then actor.DaggerEquipR:SetVisibility(false, false) end
    end)
end

-- =======================================================================
-- THE BLINK CYCLE
-- =======================================================================

-- The shared choreography: warm -> fade out -> hide knives -> exit puff -> hop -> face -> fade
-- in -> arrival act (pause, or the shard throw). Every deferred step re-validates the actor.
local function blinkTo(actor, target, spot, special)
    -- The fade is the preload window: 2.5s from here to anything that fires on arrival.
    ASSETS.WarmPinned(H.BLINK_DEPS)

    GRP.FadeOut(actor)
    local fadeMs = GRP.FADE_OUT_MS

    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) then return end
        daggersVisible(actor, false)
    end, H.WINTER.DaggerHideMs)

    -- Host-local exit puff at the origin, timed to when the body READS gone, not to the hop
    -- (clients get the same look from the def's WarpMirrorTick when the position jumps).
    local origin = actor:K2_GetActorLocation()
    if origin then
        local from = FVector(origin.X, origin.Y, origin.Z)
        Utils.QueueWork(function()
            AVU.SpawnLocalNiagara(from, ENUMS.Effects.NIAGARA_FLASK_BLIZZARD,
                { Lifetime = 4000, Scale = FVector(H.WINTER.PuffScale, H.WINTER.PuffScale, H.WINTER.PuffScale) })
        end, H.WINTER.PuffMs)
    end

    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        pcall(function()
            -- Z lift 60: 30 clipped feet into slopes (Frostpack-tested value).
            actor:K2_SetActorLocation(FVector(spot.X, spot.Y, spot.Z + 60), false, {}, true)
        end)
        if Utils.IsActorValid(target) then AVU.FaceTarget(actor, target) end
        GRP.FadeIn(actor)
        daggersVisible(actor, true)

        if special then
            H.ShardThrow(actor, target)
            LogDebug("Winterfector - shard blink", SETTINGS.DEBUG_NPC_ACTIONS)
        else
            -- The arrival pause: an FX-free native stun. The counterplay window a permanent
            -- projectile-dodger otherwise never offers.
            Utils.AddBuff(actor, ENUMS.Debuffs.ParryStun, true, H.WINTER.PauseS)
            LogDebug("Winterfector - blinked", SETTINGS.DEBUG_NPC_ACTIONS)
        end
    end, fadeMs + H.WINTER.HoldMs)
end

-- [AUTHORITY] The OnTick gate: in combat, off cooldown -> attempt a blink. The cooldown stamps on
-- the ATTEMPT (Frostpack precedent): a failed FindLosPoint just retries on the same cadence, and
-- the counter only advances on a blink that actually happened.
function H.BlinkTick(actor, totalTicks)
    if totalTicks % 10 ~= 0 then return end
    if actor.IsDead then return end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end

    -- FirstDelay: fight ~4s before the first blink instead of vanishing the instant it aggros.
    if not AVU.CooldownReady(lastBlinkTick, actor, H.WINTER.BlinkCdTicks, { FirstDelay = 40 }) then return end

    local special = ((blinkCount[actor] or 0) + 1) % H.WINTER.BlinkSpecialEvery == 0
    local spot = AVU.FindLosPoint(target, {
        Actor = actor,
        MinDist = special and H.WINTER.SpecialMin or H.WINTER.RegularMin,
        MaxDist = special and H.WINTER.SpecialMax or H.WINTER.RegularMax,
    })
    if not spot then return end   -- strict navmesh + LoS or nothing; never teleport blind

    blinkCount[actor] = (blinkCount[actor] or 0) + 1
    blinkTo(actor, target, spot, special)
end

-- =======================================================================
-- THE SHARD THROW (special blink arrival)
-- =======================================================================

-- The throwing hand (the native knife-swish socket), else above the body. nil only when the
-- actor itself has no location.
local function handLoc(actor)
    local mesh = Utils.GetValidMesh(actor)
    if mesh then
        local ok, loc = pcall(function() return mesh:GetSocketLocation(FName("r_hand")) end)
        if ok and loc then return loc end
    end
    local l = actor:K2_GetActorLocation()
    if not l then return nil end
    return FVector(l.X, l.Y, l.Z + 120)
end

-- [AUTHORITY] Native throw montage + one arc-solved Throwing Shard at the target.
function H.ShardThrow(actor, target)
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        AVU.PlayMontageReplicated(actor, ENUMS.Anims.INTERFECTOR_THROW_KNIVES, 1.0)
        -- The frost tell: a small blizzard burst in the throwing hand at wind-up, on ALL
        -- machines (GameState multicast; scale is an FVector - a bare number throws, S6).
        local hand = handLoc(actor)
        if hand then
            AVU.BroadcastFX(hand, ENUMS.Effects.NIAGARA_FLASK_BLIZZARD, nil,
                FVector(H.WINTER.TellScale, H.WINTER.TellScale, H.WINTER.TellScale))
        end
    end, H.WINTER.ThrowMontageMs)

    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        if Utils.IsActorInvalid(target) then return end
        local tLoc = target:K2_GetActorLocation()
        if not tLoc then return end

        local from = handLoc(actor)
        if not from then return end

        -- Aim at the body, not the feet: the solve wants the impact height it must reach.
        local aim = FVector(tLoc.X, tLoc.Y, tLoc.Z + 20)
        local speed = AVM.ArcSpeed(from, aim, H.WINTER.ShardArcDeg, H.WINTER.ShardGravity)

        PROJ.Queue(from, AVM.ArcDir(from, aim, H.WINTER.ShardArcDeg),
            ENUMS.ProjectileClasses.ThrowingIceShard, ENUMS.Components.SM_THROWING_DART_TECH, {
                Owner = actor,
                Instigator = actor,     -- damage credit + the overlap gate + OnDealtDamage fallback
                -- ThrownWeapon family: replicated body is the ItemDataRow (clients OnRep the mesh).
                -- Velocity must ride VelocityOverride so simulated proxies fly the same path.
                Item = { Table = G.BASE, Row = G.THROWING_SHARD },
                VelocityOverride = true,
                Velocity = speed,
                MaxSpeed = H.WINTER.ShardSpeedCap,   -- the row caps at 1000 and clamps silently
                GravityScale = H.WINTER.ShardGravity,
                Damage = H.WINTER.ShardDamage,
                LifeSpan = H.WINTER.ShardLifespan,
                SerializeTicks = 2,
                -- Impact frost burst: ExplosionParticleFX replicates (parent spawns it on impact).
                -- Resolved by path at use time; warmed via BLINK_DEPS.
                OnSpawned = function(proj)
                    local fx = ASSETS.GetIfValid(ENUMS.Effects.NIAGARA_SNOWBALL_EXPLODE)
                    if IsValid(fx) then pcall(function() proj.ExplosionParticleFX = fx end) end
                end,
                _traceName = "winterfectorShard",
            })
    end, H.WINTER.ThrowReleaseMs)
end

-- [AUTHORITY] def.OnDealtDamage (def.ProjectileDealtDamage). `attacker` may be the projectile or
-- nil (stale DoT tick) - never assume it's the NPC. Players only: freezing an NPC ally would be
-- friendly fire.
function H.FreezeOnHit(_attacker, victim)
    if Utils.IsActorInvalid(victim) then return end
    if IsValid(victim.NPCData) then return end   -- players only
    local key = Utils.ActorKey(victim)
    if not key then return end
    local cd = STATE.HardModeNoMercy and H.WINTER.FreezeCdHard or H.WINTER.FreezeCdTicks
    if not AVU.CooldownReady(lastFreezeTick, key, cd) then return end

    Utils.ApplyBuffLinked(victim, ENUMS.Debuffs.Frost, H.WINTER.FreezeSecs)
    LogDebug("Winterfector - freeze landed", SETTINGS.DEBUG_NPC_ACTIONS)
end

-- =======================================================================
-- PURIFIED INTERFECTOR - the holy half. Shield/skin/feed machinery is REUSED from the Purified
-- cell (OrderFlameRatHelpers). Only the disc throw + Interfector stat glue live here.
--   * PH.PurifiedStats is NOT reused - it's grunt-only glue (helmet/backpack, loot clearing).
--   * The disc replaces the native knife burst (its row is bytecode, see def header): ranged is
--     disabled (HasRangedAttack=false) and the disc fires via FireProjectileRow on our own
--     cadence. Native fire still decrements CurrentAmmoCount, so pin the clip before each throw.
-- =======================================================================

local PH = require("AnteNPCs.OrderFlameRatHelpers")

local DISC_CD_TICKS   = 45     -- ~4.5s between discs
local DISC_FIRST_WAIT = 30     -- ~3s of melee pressure before the first disc
local DISC_MIN_SQ     = 500 * 500     -- point-blank -> let the (holy) daggers work
local DISC_MAX_SQ     = 3500 * 3500   -- beyond this the BT should close distance instead
local DISC_DAMAGE     = 50     -- native knives are 30/hit; one disc per beat, and it bounces
local DISC_RELEASE_MS = 400    -- montage wind-up before the disc leaves

H.PURIFIED_SHIELD     = 250    -- Regen=0 pool; ONLY holy damage refills it (PH.PurifiedHit)
local PURIFIED_SHIELD_FRAC = 0.5   -- spawn at half so a holy-armed player sees the feed loop

-- The Purified family look (same values as the cell's PURIFIED_TINT): white blowout + gold glow.
H.PURIFIED_TINT = { Color = FVector(9, 9, 8), EmissiveColor = FVector(1, 0.85, 0.4), Emissive = 30 }

local lastDiscTick = setmetatable({}, { __mode = "k" })   -- actor -> FAST_TICK of last disc (OnTick wrapper is stable)

-- Purified holy kit + melee retype's debuff chain. Shield-skin rides PH.PURIFIED_ASSETS.
-- FireHoly melee applies Debuff_Ignited_Holy natively, so its buff object + DoT carrier are
-- preloaded here too.
H.PURIFIED_INTERFECTOR_ASSETS = {}
for _, p in ipairs(PH.PURIFIED_ASSETS) do
    H.PURIFIED_INTERFECTOR_ASSETS[#H.PURIFIED_INTERFECTOR_ASSETS + 1] = p
end
H.PURIFIED_INTERFECTOR_ASSETS[#H.PURIFIED_INTERFECTOR_ASSETS + 1] = ENUMS.DamageType.FireHoly
H.PURIFIED_INTERFECTOR_ASSETS[#H.PURIFIED_INTERFECTOR_ASSETS + 1] = ENUMS.BuffObjects.IgnitedHoly
H.PURIFIED_INTERFECTOR_ASSETS[#H.PURIFIED_INTERFECTOR_ASSETS + 1] = ENUMS.BuffObjects.HPDamage

-- [RENDERER] The holy shell: the Purified cell's copy-of-own-body-mesh wearing the Preacher
-- energy material (PH.AttachShell is host/SP-only + ActorKey-latched + retries internally).
function H.AttachHolyShell(actor)
    PH.AttachShell(actor)
end

-- [AUTHORITY] def.Stats: holy daggers + the holy-fed body shield.
function H.PurifiedStats(actor)
    AVU.ChangeDamageType(actor, ENUMS.DamageType.FireHoly, true)   -- melee: acid knife -> holy flame
    AVU.AddBodyShield(actor, {
        Max = H.PURIFIED_SHIELD, Regen = 0, ShowFX = true,
        Current = math.floor(H.PURIFIED_SHIELD * PURIFIED_SHIELD_FRAC),
    })
    PH.HolyShieldSkin(actor)
end

-- [AUTHORITY] The disc cadence: in combat, inside the band, off cooldown -> throw montage + one
-- lodestone disc at the target. Out-of-band replacement for the disabled native burst.
function H.DiscTick(actor, totalTicks)
    if totalTicks % 10 ~= 0 then return end
    if actor.IsDead then return end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end

    local aLoc, tLoc = actor:K2_GetActorLocation(), target:K2_GetActorLocation()
    if not aLoc or not tLoc then return end
    local distSq = Utils.DistSq(aLoc, tLoc)
    if distSq < DISC_MIN_SQ or distSq > DISC_MAX_SQ then return end

    if not AVU.CooldownReady(lastDiscTick, actor, DISC_CD_TICKS, { FirstDelay = DISC_FIRST_WAIT }) then return end

    AVU.PlayMontageReplicated(actor, ENUMS.Anims.INTERFECTOR_THROW_KNIVES, 1.0)

    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        if Utils.IsActorInvalid(target) then return end
        local t = target:K2_GetActorLocation()
        if not t then return end

        -- Nothing reloads a HasRangedAttack=false NPC, and native fire still decrements
        -- CurrentAmmoCount - pin the clip or the throws dry up at 0.
        pcall(function() actor.CurrentAmmoCount = actor.MaxAmmoCount end)

        AVU.FireProjectileRow(actor, ENUMS.ProjectileRows.DiscLodestone, DISC_DAMAGE,
            FVector(t.X, t.Y, t.Z + 40), "projectile_fraggrenade")   -- restore the native handle
        LogDebug("Purified Interfector - lodestone disc", SETTINGS.DEBUG_NPC_ACTIONS)
    end, DISC_RELEASE_MS)
end

-- [AUTHORITY] def.OnDamageTaken: runs the holy feed loop and re-applies the white-gold wash
-- through damage-stage rebuilds. PH.PurifiedHit matches by damage-type name containing "Holy" -
-- absorbed hits and Holy=0-nulled hits both count.
function H.PurifiedHit(victim, damage, dmgType)
    PH.PurifiedHit(victim, damage, dmgType)
    AVU.TintMesh(victim, H.PURIFIED_TINT)
end


-- =======================================================================
-- PEREMPTOR - THE DELAYED CUT
--
-- Four beats run off the variant's own OnTick, one phase per tick. It is a state machine and NOT a
-- QueueWork chain on purpose: a chain of short steps is exactly the shape that starves the drain
-- ([[anteup2-workqueue-drain-starvation]]).
--
--   FLIP    backflip montage, held in place, melee suppressed - the tell something is coming
--   STANCE  the dagger swipe montage crawling forward + a mirrored time dilation, so it settles
--           mid-swing and hangs there; a wind tunnel at its feet AND on its target, both aimed
--           down the line the blink will take - the telegraph and the attack are the same line
--   BLINK   one teleport to the FURTHEST clear step of BlinkUU, so an open corridor lands it
--           BEHIND its target; the pose carries through
--   HOLD    it stands in that pose where it arrived. The cut resolves PART WAY THROUGH this, so
--           the damage lands while the body is still frozen mid-swing rather than as it recovers.
--
-- WHY A TELEPORT AND NOT A SLIDE: a per-tick swept translation is 10 discrete position writes a
-- second, and position replication cannot interpolate those - remote clients see 3-4 frames of
-- chop, not a dash. One jump reads as intent; ten small ones read as a bug.
--
-- WHY THE STANCE IS A SLOW MONTAGE AND NOT A PAUSED ONE: scrubbing to a frame and pausing means
-- Montage_SetPosition / Montage_Pause, which are AnimInstance writes and never leave the server -
-- the host would hold the pose while every client watched the swing play out. A play RATE passed
-- to PlayThirdPersonMontage is a multicast parameter, and CustomTimeDilation reaches clients over
-- VariantSignal (def.MirrorTimeDilation), so both halves of the held look are things a client
-- actually sees. StanceRate/StanceTdi are the dials for WHERE in the swing it settles - that is a
-- look-at-it number, not a computed one.
--
-- The dilation runs from the stance to the end of the hold. That is safe because the body is held
-- still for all of it: mirrored CTD rubber-bands a body under continuous movement on client
-- proxies, and a teleport has no velocity for it to scale.
--
-- IT IS HELD BY HoldGround, NOT A PIN. A pin is SetMovementMode(None), which the stagger path
-- restores when it finishes - so a single hit during the windup let the body walk out of its own
-- stance and the attack died with no trace. Zeroed NPCData speeds survive that.
--
-- THE PLAYER HIT CAN'T KILL, BY CONSTRUCTION. It asks for exactly (current HP - the floor), and
-- for a player victim every remaining step in ProcessDamage only ever REDUCES that: armour, the
-- per-limb split (a player head hit is x0.1, not x2), body shields. The weakness/resistance step
-- is driven by DT_NPCList columns, which no player has. So the floor is a floor.
--
-- THE KNIVES ARE PINNED, NOT DISABLED. `HasRangedAttack` does not reach the knife burst at all:
-- BT_Attack_Interfector gates its ranged branch on BTD_IsRangeAttackOnCooldown alone, which reads
-- the pawn's `RangedAttack_OnCooldown`. Holding that true is the whole lever (the Mage/Chieftain
-- precedent), and the native clear is only ever scheduled BY a shot - so a body that never fires
-- never re-arms. Re-asserted on a slow cadence anyway.
-- =======================================================================

H.PEREMPTOR = {
    RangeUU     = 1000,   -- 10m: the band it commits from
    CdTicks     = 130,    -- ~13s between attempts; the whole combo is ~6.5s of that
    FirstDelay  = 40,     -- fight normally for ~4s before the first one

    FlipTicks   = 6,      -- backflip
    FlipRate    = 1.5,    -- ours plays fast so it reads as part of the wind-up, not as the BT's own
                          -- backstep, which it often follows straight out of
    StanceTicks = 20,     -- + FlipTicks = 2.6s windup
    StanceHard  = 15,     -- + FlipTicks = 2.1s windup
    StanceRate  = 0.45,   -- montage play rate (multicast param, so clients match)
    StanceTdi   = 0.6,    -- mirrored CustomTimeDilation, stance through hold

    BehindUU    = 300,    -- it aims for 3m PAST where its target stood at the wind-up
    BlinkUU     = 2500,   -- hard cap on that, for a target across a hangar
    BlinkMin    = 400,    -- below this the blink is not worth taking
    BlinkSteps  = 5,      -- fallbacks tried when that spot is blocked, longest first
    NearFxUU    = 300,    -- the third tunnel, 3m up the line from where it starts
    CutRadius   = 220,    -- how wide the corridor it cuts reads

    HoldTicks   = 30,     -- the pose, held where it landed
    HoldHard    = 20,
    StrikeTicks = 15,     -- when the cut resolves, measured from the blink

    NpcDamage   = 700,    -- and any NON-SCIENTIST body whose HEAD is at or under this just dies -
                          -- head hp is the size dial on this roster, so the survivors are the big
                          -- ones (Defense/Corrupt bots, Jotun, Armored Exor)
    PlayerFloor = 0.10,   -- leave the player at this fraction of max HP
    FloorHard   = 0.05,

    PinEvery    = 10,     -- re-assert the ranged pin, on the Mage's cadence
    FxSecs      = 3,

    -- The twin cut trails, one per hand, spanning the whole blink.
    BoltSecs    = 2,      -- how long they hang after the pass
    BoltUnitUU  = 200,    -- the trail's length at scale 1 (~2m, measured against /fx <path> 0 10)
    BoltReach   = 1.15,   -- drawn length as a fraction of the span. The asset's own fade-in/out
                          -- eats a little at each end, and because the WHOLE system scales
                          -- uniformly that loss stays proportional - so one factor covers every
                          -- blink distance rather than needing a per-distance fudge
    BoltBias    = 0,      -- it draws FORWARD from its origin, so spawn at the start of the span.
                          -- At 0.5 the line began half a blink downrange of the body
    BoltHandZ   = 0,      -- relative to the CAPSULE CENTRE, which already sits ~90uu up and is
                          -- about chest height - the first pass added 100 on top and drew overhead
    BoltHandRise = 7,     -- right trail above left, so a side-on view reads two rays, not one
    BoltHandOut = 35,     -- how far each trail sits off the centre line

    -- The on-hit slow. Each cooldown sits PAST its own debuff's duration, so a hit never refreshes
    -- something already running - see H.PeremptorSlowOnHit for why that matters more than it looks.
    RootSecs     = 2,     -- how long a struck NPC is held
    SlowCdNpc    = 30,    -- 3s per victim
    VineSecs     = 10,    -- debuff_vine_slow's own duration
    SlowCdPlayer = 110,   -- 11s per victim
}

-- Warmed at the START of the windup, which is ~3s of head start. The Sharp bleed rows are the
-- S6 debuff-preload trap: loading the DamageType does not pull them in, and a 400 hit lands in
-- SevereBleeding's tier. WarmPinned rather than LoadAsync so the second call onward is a table
-- read instead of a ~25ms UObject-array walk per path.
local CUT_DEPS = {
    ENUMS.DamageType.Sharp,
    ENUMS.BuffObjects.Bleeding,
    ENUMS.BuffObjects.SevereBleeding,
    AVU.BODYSHIELD_CLASS,   -- the instakill breaks shields, and an unpinned class lookup is a
                            -- UObject-array walk per body on the line
}

local BLINK_EYE_Z = 70   -- trace height for the blink's clearance check
local SCIENTIST_FACTION = 2   -- players and their own; spared the instakill rule

-- [RENDERER] A dark purple body (legs darkest) under a cyan glow, with gold knives.
-- Keyed by the SK mesh's four material slot names, one TintSlot each - a whole-mesh tint sprays a
-- single colour over all four. The knives read DiffuseColor (items master); the skin reads Color.
-- The glow is skin only: cyan over the gold would take the knives back to the body's colour.
local CYAN = FVector(0, 1, 1)
local PEREMPTOR_LOOK = {
    M_Interfector_Head   = { Color = FVector(0.05, 0.02, 0.15),  EmissiveColor = CYAN, Emissive = 12 },
    M_Interfector_Body   = { Color = FVector(0.3, 0.05, 0.7),  EmissiveColor = CYAN, Emissive = 12 },
    M_Interfector_Legs   = { Color = FVector(0.05, 0.02, 0.05), EmissiveColor = CYAN, Emissive = 12 },
    -- The knives are SELF-LIT, like the Winterfector's icicle swap. A DiffuseColor multiply alone
    -- only reads as gold where something lights it: sheathed at the hip they sit inside the body's
    -- own cyan glow, but the moment they come out for a swing they leave it and go back to dull
    -- metal. The emissive is what makes the gold a constant.
    M_Dagger_Interfector = {
        DiffuseColor       = FVector(40, 10, 0.5),
        EmissiveTexture    = ENUMS.Components.T_WHITE_GENERIC,
        EmissiveColor      = FVector(20, 10, 0.5),
        Emissive           = 25,
        EmissiveMultiply   = 25,
    },
}

-- The Velites' makeshift NVGs; transform is the grunt-head fit, bone-local on `head`.
local PEREMPTOR_GOGGLES = {
    Location = FVector(0, -5, 0),
    Rotation = FRotator(90, 90, 0),
    Scale = FVector(0.5, 1.2, 1.2),
    Color = FVector(0.05, 0, 0.05),
}

function H.PeremptorLook(actor)
    AVU.SkipStaggerAnim(actor)   -- renderer half of Stats' CCImmune
    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return end
    for slot, opts in pairs(PEREMPTOR_LOOK) do
        AVU.TintSlot(mesh, slot, opts)
    end
    AVU.AttachStaticMesh(actor, ENUMS.Components.SM_HELM_MAKESHIFT_NVGS, "head", PEREMPTOR_GOGGLES)
    -- The knives it actually holds are separate static components; they share only the material
    -- name with the body's slot, so the mesh pass above leaves them stock.
    for _, name in ipairs(DAGGER_COMPONENTS) do
        pcall(function()
            local comp = actor[name]
            if IsValid(comp) then AVU.TintSlot(comp, 0, PEREMPTOR_LOOK.M_Dagger_Interfector) end
        end)
    end
end

local perCut = {}        -- ActorKey -> { phase, at, stance, hold, hard, from, dir, tdi, yaw, strikeAt }
local lastCutTick = {}   -- ActorKey -> FAST_TICK of the last ATTEMPT
local lastSlowTick = {}  -- VICTIM ActorKey -> FAST_TICK of that victim's last slow


local function forwardOf(actor)
    local rot
    pcall(function() rot = actor:K2_GetActorRotation() end)
    if not rot then return nil end
    return AVM.ForwardFromRotator(rot)
end


-- Hold the knife burst shut. See the banner: this bool is the only gate the BT reads.
local function pinKnives(actor)
    pcall(function()
        actor.RangedAttack_Cooldown = 99999
        actor.RangedAttack_OnCooldown = true
    end)
end


local function locOf(actor)
    local loc
    pcall(function() loc = actor:K2_GetActorLocation() end)
    return loc
end


-- The wind tunnel. The entry is tipped horizontal in the registry, so the yaw here is what aims
-- it - always down the line of the cut, whether it is drawn at the body, the target or the landing.
local function updraft(loc, yaw, key)
    if loc then AVU.SendClientFX(loc, key or "PEREMPTOR_UPDRAFT", H.PEREMPTOR.FxSecs, yaw) end
end


-- The furthest clear step along `dir`, longest first, so an open corridor puts it BEHIND its
-- target rather than stopping on them. The trace ignores both bodies - only world geometry should
-- shorten a blink - and runs at eye height so a kerb doesn't read as a wall. nil = nowhere to go.
local function blinkDest(actor, from, dir, target, wanted)
    local ignore = { actor }
    if Utils.IsActorValid(target) then ignore[#ignore + 1] = target end
    local a = FVector(from.X, from.Y, from.Z + BLINK_EYE_Z)
    wanted = math.min(wanted or H.PEREMPTOR.BlinkUU, H.PEREMPTOR.BlinkUU)

    for i = 0, H.PEREMPTOR.BlinkSteps - 1 do
        local d = wanted * (1 - i / H.PEREMPTOR.BlinkSteps)
        if d >= H.PEREMPTOR.BlinkMin then
            local cand = FVector(from.X + dir.X * d, from.Y + dir.Y * d, from.Z)
            local b = FVector(cand.X, cand.Y, cand.Z + BLINK_EYE_Z)
            if not AVU.IsPathBlocked(actor, a, b, ignore) then
                -- Drop it onto the floor it is actually over; the trace only proved the air was
                -- clear, not that the ground came with it.
                return Utils.ProjectToNav(cand, 300, 60) or cand
            end
        end
    end
    return nil
end


-- Two trails spanning `from` -> `to`, one off each hand, so the pass leaves a pair of rays down
-- the line it actually cut. Drawn off the plain point channel rather than the beam one: this system
-- has no endpoint param, but it IS a line whose length follows a uniform scale, so yaw aims it and
-- the scale stretches it. Length and centring are both guesses at the asset - see the knobs.
local function cutTrails(from, to, dir, yaw)
    if not from or not to or not dir then return end
    local dist = math.sqrt(Utils.DistSqXY(from, to))
    if dist < 1 then return end

    local b = H.PEREMPTOR.BoltBias
    local baseX = from.X + (to.X - from.X) * b
    local baseY = from.Y + (to.Y - from.Y) * b
    local scale = (dist / H.PEREMPTOR.BoltUnitUU) * H.PEREMPTOR.BoltReach

    -- Offset each hand off the cut LINE, not off a from->spawn vector: at bias 0 those two points
    -- are the same and the direction between them is undefined. `dir` is already the unit line.
    local px, py = -dir.Y, dir.X

    for _, side in ipairs({ 1, -1 }) do
        local z = from.Z + H.PEREMPTOR.BoltHandZ
        if side > 0 then z = z + H.PEREMPTOR.BoltHandRise end
        AVU.SendClientFX(
            FVector(baseX + px * H.PEREMPTOR.BoltHandOut * side,
                    baseY + py * H.PEREMPTOR.BoltHandOut * side, z),
            "PEREMPTOR_CUT_TRAIL", H.PEREMPTOR.BoltSecs, yaw, 0, scale)
    end
end


-- The pose the whole attack hangs on. Re-played at the blink so it survives into the hold instead
-- of running out mid-flight.
local function holdPose(actor)
    AVU.PlayMontageReplicated(actor, ENUMS.Anims.INTERFECTOR_MELEE_01, H.PEREMPTOR.StanceRate, false)
end


-- Everything the blink passed through, resolved one beat late. Players and NPCs are collected
-- separately: the player array is an O(players) GameState read, and the NPC sweep is a sphere over
-- the midpoint that then gets narrowed to the actual corridor.
local function resolveCut(actor, st)
    local from, dir = st.from, st.dir
    local to = actor:K2_GetActorLocation()
    if not from or not dir or not to then return end

    local travelled = math.sqrt(Utils.DistSqXY(from, to)) + H.PEREMPTOR.CutRadius
    local floorPct = st.hard and H.PEREMPTOR.FloorHard or H.PEREMPTOR.PlayerFloor

    local gs = STATE.GameState
    local players = IsValid(gs) and gs.PlayerCharacterInGame or nil
    for i = 1, (players and #players or 0) do
        local p = players[i]
        if IsValid(p) then
            local pl
            pcall(function() pl = p:K2_GetActorLocation() end)
            local hit, along
            if pl then hit, along = AVM.PointNearRay2D(from, dir, pl, H.PEREMPTOR.CutRadius) end
            if hit and along <= travelled then
                local cur, mx
                pcall(function() cur, mx = p:GetTotalHealth(), p:GetMaxTotalHealth() end)
                cur, mx = tonumber(cur), tonumber(mx)
                if cur and mx then
                    local dmg = math.floor(cur - mx * floorPct)
                    if dmg > 0 then
                        AVU.PointDamageOffHook(actor, p, dmg, ENUMS.DamageType.Sharp)
                    end
                end
            end
        end
    end

    -- Anything NON-SCIENTIST small enough is cut in half outright; everything else takes NpcDamage
    -- and lives with it. The instakill is dealt as damage rather than as a health write so the body
    -- still runs its own death - and PointDamageOffHook is what keeps that death sequence out of
    -- the drain.
    local mid = FVector((from.X + to.X) * 0.5, (from.Y + to.Y) * 0.5, (from.Z + to.Z) * 0.5)
    local myFaction
    pcall(function() myFaction = actor.Faction end)

    local npcs = AVU.GetNearbyNpcs(mid, travelled * 0.5 + H.PEREMPTOR.CutRadius,
        { ignoreActor = actor, maxZ = 300 })
    for i = 1, #npcs do
        local n = npcs[i]
        local nl
        pcall(function() nl = n:K2_GetActorLocation() end)
        local hit, along
        if nl then hit, along = AVM.PointNearRay2D(from, dir, nl, H.PEREMPTOR.CutRadius) end
        if hit and along <= travelled then
            local fac
            pcall(function() fac = n.Faction end)
            if fac == nil or myFaction == nil or fac ~= myFaction then
                -- CURRENT head hp, not max: at full health this is the size test the roster was
                -- picked against, and a big body already cut down to it dies to the follow-up.
                local head
                pcall(function() head = n:GetLimbHealth(ENUMS.EBodyLimbs.Head) end)
                head = tonumber(head)

                -- A player's pet is spared the instakill and takes the flat hit instead, so it can
                -- go down and be picked back up the way any other pet does. Faction won't tell you:
                -- a tamed body keeps its wild one.
                local follower = false
                pcall(function() follower = n:IsFollower() end)

                local dmg = H.PEREMPTOR.NpcDamage
                if not follower and fac ~= SCIENTIST_FACTION
                   and head and head <= H.PEREMPTOR.NpcDamage then
                    dmg = head * 4 + 2000   -- past any armour or resistance still to come
                    -- ...but a body shield would eat all of that, so the cut breaks it on the way
                    -- through. Zero is enough: the native absorb gate needs Current > 0, and the
                    -- shield's own tick raises the broken FX. Not Max, which is a permabreak the
                    -- body will not live to notice.
                    AVU.SetBodyShield(n, { Current = 0 })
                end
                AVU.PointDamageOffHook(actor, n, dmg, ENUMS.DamageType.Sharp)
            end
        end
    end

    LogDebug("Peremptor - cut resolved", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- Give the body back: dilation, movement, and the state entry. Runs on every exit path, including
-- a death mid-combo - a Peremptor that dies dilated leaves a 0.6x corpse.
local function endCut(actor, key, st)
    AVU.SetTimeDilation(actor, (st and st.tdi) or 1)
    AVU.ReleaseGround(actor)
    perCut[key] = nil
end


local function startCut(actor, key, target, totalTicks)
    ASSETS.WarmPinned(CUT_DEPS)

    local hard = STATE.HardModeNoMercy
    local stance = hard and H.PEREMPTOR.StanceHard or H.PEREMPTOR.StanceTicks
    local hold = hard and H.PEREMPTOR.HoldHard or H.PEREMPTOR.HoldTicks
    local lockTicks = H.PEREMPTOR.FlipTicks + stance + hold

    AVU.FaceTarget(actor, target)
    -- HoldGround, not RootInPlace: a pin is SetMovementMode(None), and the stagger path restores
    -- walking when it finishes - so one hit during the windup let it stroll off mid-stance and the
    -- attack silently died. Zeroed NPCData speeds survive that, because every native restore copies
    -- speed back FROM NPCData. It costs the automatic facing, which is why FaceTarget is driven by
    -- hand at both the flip and the stance.
    AVU.HoldGround(actor)
    AVU.SuppressMelee(actor, lockTicks * 100)
    AVU.PlayMontageReplicated(actor, ENUMS.Anims.INTERFECTOR_DODGE_BACK, H.PEREMPTOR.FlipRate, false)

    perCut[key] = { phase = "flip", at = totalTicks + H.PEREMPTOR.FlipTicks,
                    stance = stance, hold = hold, hard = hard,
                    tdi = tonumber(actor.CustomTimeDilation) or 1 }
    LogDebug("Peremptor - windup", SETTINGS.DEBUG_NPC_ACTIONS)
end


local function runCut(actor, key, st, totalTicks)
    if actor.IsDead then return endCut(actor, key, st) end

    if st.phase == "flip" then
        if totalTicks < st.at then return end
        local t = AVU.GetCurrentTarget(actor)
        local here = locOf(actor)
        if Utils.IsActorValid(t) then AVU.FaceTarget(actor, t) end
        holdPose(actor)
        AVU.SetTimeDilation(actor, H.PEREMPTOR.StanceTdi)

        -- The line the cut will take, fixed HERE and never recomputed: the blink aims at where the
        -- target stood when the wind-up began, so stepping aside during it actually works. Flat in
        -- XY - a target on a stair would otherwise aim the blink into the floor.
        local there = Utils.IsActorValid(t) and locOf(t) or nil
        if here and there then
            st.mark = there
            st.dir = Utils.Direction(FVector(here.X, here.Y, 0), FVector(there.X, there.Y, 0))
            st.yaw = AVM.YawTo(here, there)
        end
        updraft(here, st.yaw)
        updraft(there, st.yaw, "PEREMPTOR_UPDRAFT_UP")   -- upright: this one names WHO, not which way
        if here and st.dir then
            updraft(FVector(here.X + st.dir.X * H.PEREMPTOR.NearFxUU,
                            here.Y + st.dir.Y * H.PEREMPTOR.NearFxUU, here.Z), st.yaw)
        end
        st.phase, st.at = "stance", totalTicks + st.stance

    elseif st.phase == "stance" then
        if totalTicks < st.at then return end
        st.from = locOf(actor)
        st.dir = st.dir or forwardOf(actor)
        if not st.from or not st.dir then return endCut(actor, key, st) end

        -- Land BehindUU past the marked spot, not as far as it can get: the point is to end up just
        -- through them, not across the room.
        local wanted = H.PEREMPTOR.BehindUU
        if st.mark then
            wanted = math.sqrt(Utils.DistSqXY(st.from, st.mark)) + H.PEREMPTOR.BehindUU
        end

        -- A blink with nowhere to go still cuts: it just cuts the ground it is standing on.
        local dest = blinkDest(actor, st.from, st.dir, AVU.GetCurrentTarget(actor), wanted)
        if dest then
            pcall(function() actor:K2_SetActorLocation(dest, false, {}, true) end)
        end
        holdPose(actor)
        -- The pass draws itself rather than marking its ends: two rays down the line it cut, from
        -- where it left to where it actually arrived.
        cutTrails(st.from, locOf(actor), st.dir, st.yaw)

        st.phase = "hold"
        st.at = totalTicks + st.hold
        st.strikeAt = totalTicks + H.PEREMPTOR.StrikeTicks

    elseif st.phase == "hold" then
        if st.strikeAt and totalTicks >= st.strikeAt then
            st.strikeAt = nil
            resolveCut(actor, st)
        end
        if totalTicks < st.at then return end
        endCut(actor, key, st)
    end
end


-- [AUTHORITY] def.OnTick. Drives a running combo every tick; otherwise looks for a trigger on a
-- lazy cadence. The cooldown stamps on the ATTEMPT, matching the Winterfector's blink gate.
function H.PeremptorTick(actor, totalTicks)
    local key = Utils.ActorKey(actor)
    if not key then return end

    if totalTicks % H.PEREMPTOR.PinEvery == 0 then pinKnives(actor) end

    local st = perCut[key]
    if st then return runCut(actor, key, st, totalTicks) end

    if totalTicks % 5 ~= 0 or actor.IsDead then return end

    local target = AVU.GetCurrentTarget(actor)
    if Utils.IsActorInvalid(target) then return end

    local here, there = actor:K2_GetActorLocation(), target:K2_GetActorLocation()
    if not here or not there then return end
    if Utils.DistSq(here, there) > H.PEREMPTOR.RangeUU * H.PEREMPTOR.RangeUU then return end

    if not AVU.CooldownReady(lastCutTick, key, H.PEREMPTOR.CdTicks,
        { FirstDelay = H.PEREMPTOR.FirstDelay }) then return end

    startCut(actor, key, target, totalTicks)
end


-- [AUTHORITY] def.OnDealtDamage. Its ordinary swings drag: players to 70% speed, other NPCs to a
-- standstill. `attacker` is never read - on this base it can arrive as a stale DoT tick.
--
-- THE TWO VICTIMS TAKE DIFFERENT ROUTES, and not for flavour. A player gets debuff_vine_slow, a
-- pure stat row. An NPC gets AVU.HoldGround instead, because Debuff_Rooted was measured NOT to take
-- on one - the stat layer Speed_Multiply rides never reaches the body. HoldGround zeroes the
-- NPCData speeds LocalUpdateWalkSpeed actually reads, which is the same lever this variant already
-- uses to hold ITSELF still through a wind-up.
--
-- THE PER-VICTIM COOLDOWN IS THE POINT, not politeness. Every buff apply is a UObject-array scan
-- behind an EIGT flush, and OnDealtDamage re-fires on each DoT TICK
-- ([[anteup2-ondealtdamage-fires-per-dot-tick]]) - so an ungated apply on a bleeding target is a
-- stutter rather than a slow, which is the shape the Hive_Sow re-apply turned out to be. Each gate
-- is longer than the debuff it guards, so a landed hit never re-applies something still running.
--
-- ApplyBuffLinked, not AddBuff: AddBuff routes through Server_TryApplyBuff, which silently NO-OPS
-- when a server applies to a player. One path for both victims is one fewer thing to get wrong.
function H.PeremptorSlowOnHit(_attacker, victim)
    if Utils.IsActorInvalid(victim) then return end
    local key = Utils.ActorKey(victim)
    if not key then return end

    local player = Utils.IsPlayer(victim)
    local cd = player and H.PEREMPTOR.SlowCdPlayer or H.PEREMPTOR.SlowCdNpc
    if not AVU.CooldownReady(lastSlowTick, key, cd) then return end

    if player then
        -- Vine over TurtleMode purely for the UI: both are stat-only, but TurtleMode is
        -- FullVisibility and leaves a blank icon-less row in the player's debuff list.
        Utils.ApplyBuffLinked(victim, ENUMS.Debuffs.VineSlow, H.PEREMPTOR.VineSecs)
        return
    end

    -- The hold self-maintains (every native speed restore copies back from NPCData), so it needs no
    -- re-assert - only the release. A re-hold keeps the ORIGINAL stash, so overlapping hits cannot
    -- strand the body at zero.
    if not AVU.HoldGround(victim) then return end
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(victim) then return end
        AVU.ReleaseGround(victim)
    end, H.PEREMPTOR.RootSecs * 1000)
end


-- [AUTHORITY] def.Stats. Melee-only, and it never rolls: the blink IS its repositioning move, and
-- a blind ~300uu backstep in the middle of a committed windup would throw the cut off its line.
-- CC-immune for the same reason - nothing takes the windup away once it starts. Bleed still lands
-- (damage, not control); slows and knockbacks are separate systems and still apply.
function H.PeremptorStats(actor)
    AVU.CCImmune(actor, { Bleed = false })   -- includes SkipBackstepAnim
    pcall(function() actor.EvadesProjectiles = false end)
    -- Every NPC ships DamageToNPCs = 0.5, and CheckForNPCDamageMultiplier applies it to any hit
    -- whose instigator is a non-Scientist NPC - so the cut was landing at HALF its number on other
    -- NPCs (400 read as 200 on a Phyter) with nothing in the log to say why. This is the whole
    -- correction; the weakness/resist steps are on the other branch and never ran for us anyway.
    pcall(function() actor.DamageToNPCs = 1 end)
    pinKnives(actor)
end


-- [def.OnDeath]
function H.PeremptorForget(actor)
    if Utils.IsActorInvalid(actor) then return end
    AVU.ReleaseGround(actor)   -- the speed stash is string-keyed and never collects on its own
    local key = Utils.ActorKey(actor)
    if not key then return end
    perCut[key], lastCutTick[key] = nil, nil
end


return H
