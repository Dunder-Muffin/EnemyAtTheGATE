-- =======================================================================
-- Mystagogue helpers - machinery for AnteNPCs/GK_Mage.lua (Barrier + Abjurer)
--
-- MUST-KNOWS
--   * Eye tracking is a HEARTBEAT, not a scan: eyes stamp STATE.BarrierPings, the mage counts
--     fresh stamps. A SphereOverlap scan was too slow in a crowded arena.
--   * Barrier CLEAR also runs from OnDamageTaken, since OnTick can stop permanently on a
--     stream-out that never re-registers, which would latch Invincible=true forever.
--   * Meditate pose is a single-node mesh: no montage can play, so the native grab is dead.
--     Reviving it needs a hand-driven payload; an unreleased grab softlocks the player.
--   * Disc cadence can't go faster than it does: BTT_DoRangedAttack waits on a CombatReset
--     broadcast with a hardcoded Delay(0.5) after the projectile.
--   * The Abjurer's shield WALL is an arc test, not geometry - the plate it attaches is cosmetic.
--     Why, and what that costs: the banner over AVU.AddShieldWall in AnteUtils/AVShields.
--   * Eye spawns route through PortalSummon/SummonVariant because native SpawnMageEye blocking-loads.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local ENUMS = require("AnteData.Enums")
local SCHEMA = require("AnteData.Schema")
local ASSETS = require("AnteCore.AssetManager")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local AVM = require("AnteUtils.AVMath")
local Lasers = require("AnteUtils.Lasers")
local PROJ = require("AnteCore.Projectile")
local VS = require("AnteVariants.VariantSignal")

local LogDebug = Utils.LogDebug
local LogBad = Utils.LogBad

local H = {}

-- Read at USE time, never cached: the flag is a world-load property and a def is shared.
local function byMode(t) return STATE.HardModeNoMercy and t.Hard or t.Normal end


-- =======================================================================
-- SHARED
-- =======================================================================

-- Stock GREEN + ORANGE material sets for the 3 body regions (red = base). Barrier orange, Abjurer green
local MYST_RECOLOR = {
    Orange = {
        Head  = ENUMS.Components.M_MYST_HEAD_ORANGE,
        Torso = ENUMS.Components.M_MYST_TORSO_ORANGE,
        Legs  = ENUMS.Components.M_MYST_LEGS_ORANGE,
    },
    Green = {
        Head  = ENUMS.Components.M_MYST_HEAD_GREEN,
        Torso = ENUMS.Components.M_MYST_TORSO_GREEN,
        Legs  = ENUMS.Components.M_MYST_LEGS_GREEN,
    },
}


-- [AUTHORITY] Kill the gravity wave: overlap + impulse source + cooldown flag, so CheckGravityWave
-- can't re-arm it.
local function stripGravityWave(actor)
    pcall(function()
        local overlap = actor.GravityWaveOverlap
        if IsValid(overlap) then overlap:SetCollisionEnabled(0) end
    end)
    pcall(function()
        local rf = actor.RadialForce
        if IsValid(rf) then rf:Deactivate() end
    end)
    pcall(function() actor.GravityWaveOnCooldown = true end)
end


-- [AUTHORITY] Kill the native eye; MageEyeDestroyed=true makes CheckMageEye bail forever.
--   * BeginPlay ALREADY spawned one, and STATS can land before BeginPlay ends -> destroy deferred.
local function suppressNativeEye(actor)
    pcall(function() actor.MageEyeDestroyed = true end)
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) then return end
        pcall(function()
            local eye = actor.ActiveMageEye
            if IsValid(eye) then eye:K2_DestroyActor() end
            actor.MageEyeDestroyed = true
        end)
    end, 1500)
end


-- [AUTHORITY] Kill the TurtleMode front shield ALONE.
--   * ShieldOnCooldown is the native raise's own gate, and only the raise's 20s delay ever clears
--     it - so set once, it holds for good. The def's DebuffsImmune is the belt: the class applies
--     AI_TurtleMode straight onto the buff component, which does not ask that list.
--   * The zeroed mesh only covers what the SERVER traces. A client's copy stays full size and a
--     player's shots are traced there, so a plate that did raise would block them for real.
local function stripMageShield(actor)
    pcall(function() actor.ShieldOnCooldown = true end)
    pcall(function()
        local shield = actor.Shield
        if IsValid(shield) then shield:SetRelativeScale3D(FVector(0, 0, 0)) end
    end)
end

-- [AUTHORITY] Take away everything that makes the base Mage a duellist, leaving the fireball.
--   keep (optional): { Grab = true } - spare the choke grab.
--                    { GravityWave = true } - spare the shove that clears melee off it.
local function stripMageKit(actor, keep)
    keep = keep or {}
    stripMageShield(actor)

    if not keep.GravityWave then stripGravityWave(actor) end

    -- The grab (its only melee - MeleeAttacks holds exactly one entry).
    if not keep.Grab then
        pcall(function() actor.GrabCooldown = 99999 end)
    end

    suppressNativeEye(actor)
end

-- Exported for the DarkLens Magus' Astral add (GK_DarkLensMageHelpers) - same de-duellist kit,
-- without duplicating the shield/wave/eye internals; the Magus itself takes the shield and wave
-- halves but keeps its grab and its (already-dead) eye.
H.StripMageKit = stripMageKit
H.StripMageShield = stripMageShield
H.StripGravityWave = stripGravityWave


-- [RENDERER] Swap a Mystagogue to its "Green"/"Orange" material set, per slot.
--   * Whole-material, not a tint: a Color tint only multiplies the base texture, never repaints it.
--   * Slots matched on a region keyword in the material name (via the dynamic-instance Parent if
--     wrapped), so it doesn't depend on the base's exact suffix.
--   * SetMaterial doesn't replicate -> call from Visuals; ClientVisuals re-applies per client.
--   * tint (optional): AVU.TintMesh opts, applied AFTER the swap. Can't be def.Tint - that runs
--     BEFORE Visuals and the SetMaterial would wipe it.
--   * Called from the DEFS' Visuals (GK_Mage.lua), which carry their own tint tables.
function H.MystagogueRecolor(actor, color, tint)
    local set = MYST_RECOLOR[color]
    if not set then return end
    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return end

    local head  = ASSETS.GetIfValid(set.Head)
    local torso = ASSETS.GetIfValid(set.Torso)
    local legs  = ASSETS.GetIfValid(set.Legs)

    local swapped = 0
    pcall(function()
        local n = mesh:GetNumMaterials()
        for i = 0, n - 1 do
            local cur = mesh:GetMaterial(i)
            if IsValid(cur) then
                local name = cur:GetFName():ToString()
                -- Already-wrapped slot: resolve through the dynamic-instance parent.
                if not string.find(name, "Mystagogue", 1, true)
                   and not string.find(name, "Mystagouge", 1, true) then
                    local p = cur.Parent
                    if IsValid(p) then name = p:GetFName():ToString() end
                end
                local mat
                if string.find(name, "Head", 1, true) then mat = head
                elseif string.find(name, "Torso", 1, true) then mat = torso
                elseif string.find(name, "Legs", 1, true) then mat = legs end
                if IsValid(mat) then mesh:SetMaterial(i, mat); swapped = swapped + 1 end
            end
        end
    end)

    if tint then AVU.TintMesh(actor, tint) end

    LogDebug("Mystagogue recolour (" .. color .. ") - " .. swapped .. " slot(s)", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- =======================================================================
-- BARRIER MAGE
-- =======================================================================

local MAX_EYES = 2
local PING_FRESH_TICKS = 15      -- stamps older than 1.5s don't count (sets DROP speed only)
local EYE_SCAN_TICKS = 20        -- combat: re-count + top-up every 2s (drop is faster via on-hit)
local EYE_SCAN_TICKS_IDLE = 30   -- out of combat: 3s
local EYE_SUMMON_TICKS = 150     -- re-summon cooldown
local EYE_SPAWN_UP = 40
local EYE_SPAWN_OUT = 180
local HIT_SCAN_TICKS = 15        -- throttle the on-hit re-check to ~1.5s during a barrage

-- Sanity backstop: drop invuln if pings are fresh but no eye body is actually nearby.
local EYE_SANITY_TICKS  = 150    -- ~15s cadence, only while the barrier is believed up
local EYE_SANITY_RADIUS = 2500   -- matches the 25m eye scan (leash is 22m, always inside)

local BARRIER_COLOR = FVector(1, 1, 0)   -- ForceField/Base/Outline colour (all three slots)

-- "Is the barrier up" pushed to clients. Using TDI on something nothing reads (and not using MirrorTimeDilation)
local SIG_BARRIER = VS.TDI

-- AUTHORITY: fullname -> { LastScan, LastSummon, Present, Fighting, LastHitScan } (live eye count
-- lives in countPings, not here).
local barrierState = {}
local barrierOn = {}     -- AUTHORITY: fullname -> barrier currently up (latch; see setBarrier)
local sheenOn = {}       -- RENDERER:  fullname -> shell currently visible (latch)
local barrierShell = {}  -- RENDERER:  fullname -> its shell component (attach-once)

-- Eye class (its BeginPlay must be a warm hit), channel-laser FX, shell material, emerge burst.
-- NOT the PORTAL: that rides the client-FX channel (warmed in ClientEffects).
H.BARRIER_ASSETS = {
    ENUMS.NpcClasses["Gatekeeper_MageEye"],
    Lasers.FX_BEAM, Lasers.FX_END, Lasers.FX_RECV,
    AVU.SHIELD_SHELL_MAT,
    AVU.PORTAL_FX, AVU.PORTAL_SFX,
    ENUMS.Anims.MAGE_FIREBALL,       -- the summon cast (SOFT path -> must be warm)
    ENUMS.Components.M_MYST_HEAD_ORANGE, ENUMS.Components.M_MYST_TORSO_ORANGE,
    ENUMS.Components.M_MYST_LEGS_ORANGE,
}


-- [AUTHORITY] Count live eyes from their HEARTBEATS - a table walk; no overlap, no GetFullName.
--   * Stamps fresher than PING_FRESH_TICKS count; the rest are pruned, so dead eyes age out.
local function countPings(mageKey)
    local t = mageKey and STATE.BarrierPings[mageKey]
    if not t then return 0 end
    local now = STATE.FAST_TICK
    local n = 0
    for ek, tick in pairs(t) do
        -- Fresh = inside the window AND not from before a world reset (now < tick => stale).
        if type(tick) == "number" and now >= tick and (now - tick) < PING_FRESH_TICKS then
            n = n + 1
        else
            t[ek] = nil
        end
    end
    return n
end


-- [AUTHORITY] Spawn one Barrier Eye. PortalSummon owns the spawn/burst/faction copy; the only
-- Barrier-specific part is linking the eye BACK to its mage.
local function createBarrierEye(mage, at)
    -- Rift = false: no rectangular GK doorway (too much theatre for a small eye) - it just POPS IN
    -- on the spawn burst.
    AVU.PortalSummon(at, { { Variant = "Barrier Eye" } }, {
        Rift = false,
        EmergeMs = 1000,
        FactionFrom = mage,
        Guard = function()   -- died mid-cast -> it does not get its eye
            return Utils.IsActorValid(mage) and not Utils.IsDeadSafe(mage)
        end,

        OnSpawned = function(eye)
            -- THE link: OwningMage keeps CanFireLaser() FALSE while the mage lives, so the beam is
            -- ours to drive instead of the native enrage.
            pcall(function() eye.OwningMage = mage end)
            LogDebug("Barrier Mage - summoned a Barrier Eye", SETTINGS.DEBUG_NPC_ACTIONS)
        end,
    })
end


-- [AUTHORITY] Summon ONE more Barrier Eye. Nothing is tracked here - the next scan picks it up.
local function topUpEyes(mage, have)
    local loc = mage:K2_GetActorLocation()
    if not loc then return end

    -- Its own slot on the ring, so a second eye doesn't open its portal inside the first. Keep it
    -- near the FLOOR (the eye flies up on its own) - a high offset hangs the portal in mid-air.
    local at = AVM.RingPoint(loc, EYE_SPAWN_OUT, have, MAX_EYES, EYE_SPAWN_UP)

    -- THE CAST (the tell). Replicated, and safe alone - the projectile is Server_DoRangedAttack's.
    AVU.PlayMontageReplicated(mage, ENUMS.Anims.MAGE_FIREBALL, 1, true)

    createBarrierEye(mage, at)
end


-- [AUTHORITY] Set invulnerability + the replicated bit for clients.
--   * VS.Set marks dirty, so only write on change.
--   * The latch is verified against the ACTUAL Invincible bool - they desync (see the header) and a
--     stale-true latch must not block the re-write.
local function setBarrier(mage, barrierUp)
    local key = AVU.CachedFullName(mage)
    if not key then return end
    if barrierOn[key] == barrierUp then
        local actual
        pcall(function() actual = mage.Invincible end)
        if (actual == true) == barrierUp then return end
    end
    barrierOn[key] = barrierUp

    pcall(function() mage.Invincible = barrierUp and true or false end)
    VS.Set(mage, SIG_BARRIER, barrierUp and 1 or 0)
end


-- [RENDERER] The energy-shield sheen while the barrier is up. Built lazily, on first raise.
--   * A BodyShieldComponent normally flashes this on absorbed hits; this mage has none, so we own
--     its visibility outright and leave it on for the duration.
--   * Set ALL THREE colours: the material blends ForceFieldColor with its own Base/Outline, so
--     tinting Color alone bleeds the stock hue through (a "yellow" shield reads pink).
local function setSheen(actor, on)
    local key = AVU.CachedFullName(actor)
    if not key or sheenOn[key] == on then return end

    local shell = barrierShell[key]
    if IsNotValid(shell) then
        -- Never BUILD one just to hide it, and never latch on either failure path below - the shell
        -- has to build on the first real raise.
        if not on then return end

        -- No mesh arg = the actor's own body mesh. Returns nil until that mesh has streamed in.
        shell = AVU.AttachShieldShell(actor, nil, {
            Color   = BARRIER_COLOR,
            Base    = BARRIER_COLOR,
            Outline = BARRIER_COLOR,
            Glow    = 5,
        })
        if not shell then return end
        barrierShell[key] = shell
    end

    sheenOn[key] = on
    pcall(function() shell:SetVisibility(on and true or false, false) end)
end


-- [Stats] Strip the shield + gravity wave, own the eyes, start vulnerable.
function H.BarrierStats(actor)
    stripMageShield(actor)   -- zero the shield scale for authority/host too

    -- Not a full stripMageKit - it keeps eyes, grab and fireball. Only the gravity wave goes: the
    -- barrier is the defence, and its RadialForce/reposition churn reads as "jerking".
    stripGravityWave(actor)

    -- It fields its OWN eyes. Also kills the "adopt a stray native eye" path (a 45ms per-scan
    -- GetFullName hitch) and guarantees every nearby eye is ours.
    suppressNativeEye(actor)

    -- Fail-safe invuln: Stats runs on EVERY mutation (incl. re-mutation on stream-back), so start
    -- vulnerable with FRESH tracking - the barrier is only ever raised by a live scan.
    local key = actor:GetFullName()
    barrierState[key] = nil
    barrierOn[key] = nil
    pcall(function() actor.Invincible = false end)
end


-- [OnTick] AUTHORITY: count eyes, raise the barrier, top up. RENDERER: mirror the sheen.
function H.BarrierTick(actor, ticks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    if ticks % 5 ~= 0 then return end

    if Utils.IsAuthority() then
        local key = AVU.CachedFullName(actor)

        if Utils.IsDeadSafe(actor) then
            setBarrier(actor, false)      -- drop invuln so the corpse is a corpse
            if key then barrierState[key] = nil end
            return "REMOVE"
        end

        local st = key and barrierState[key]
        if key and not st then
            st = { LastScan = -9999, LastSummon = -9999, Present = 0, Fighting = false }
            barrierState[key] = st
        end

        if st then
            local fighting = false
            pcall(function() fighting = actor.CombatState == true end)

            -- Re-count on a cadence (faster in combat), forced on a combat-state flip. Clock-backwards
            -- guard: a world reset zeroes FAST_TICK but this state survives (module tables aren't in
            -- ResetState), so a future LastScan would gate the count off forever.
            local now = STATE.FAST_TICK
            if now < st.LastScan or now < st.LastSummon then
                st.LastScan, st.LastSummon, st.LastSanity = -9999, -9999, nil
            end
            if fighting ~= st.Fighting then st.Fighting = fighting; st.LastScan = -9999 end
            local due = fighting and EYE_SCAN_TICKS or EYE_SCAN_TICKS_IDLE

            if AVU.CooldownReady(st, "LastScan", due) then
                local present = countPings(key)
                st.Present = present

                -- RAISE only. The CLEAR also lives in the damage hook, so it survives this tick dying.
                setBarrier(actor, present > 0)

                -- ONE eye at a time, capped. The first summon fires immediately (LastSummon starts
                -- far in the past), so a fresh mage gets its first eye ~one portal later.
                if present < MAX_EYES and AVU.CooldownReady(st, "LastSummon", EYE_SUMMON_TICKS) then
                    topUpEyes(actor, present)
                end
            end

            -- Physical sanity (see the knob): fresh pings but no eye BODY nearby = wipe +
            -- clear DIRECTLY (setBarrier's latch can be stale-true, the on-hit lesson).
            if (st.Present or 0) > 0 and AVU.CooldownReady(st, "LastSanity", EYE_SANITY_TICKS) then
                local loc
                pcall(function() loc = actor:K2_GetActorLocation() end)
                if loc and #AVU.GetNearbyActorsOfClass(loc, EYE_SANITY_RADIUS,
                        ENUMS.NpcClasses["Gatekeeper_MageEye"]) == 0 then
                    STATE.BarrierPings[key] = {}
                    st.Present = 0
                    pcall(function() actor.Invincible = false end)
                    VS.Set(actor, SIG_BARRIER, 0)
                    barrierOn[key] = false
                    LogDebug("Barrier Mage - sanity: no eye bodies nearby, barrier dropped",
                        SETTINGS.DEBUG_NPC_ACTIONS)
                end
            end
        end
    end

    if Utils.HasRenderer() then
        -- Both host and pure client read the SAME replicated bit.
        setSheen(actor, VS.Read(actor, SIG_BARRIER) == 1)
    end
end


-- [OnDamageTaken] AUTHORITY: another barrier self correct that fires on every hit it takes
function H.BarrierHit(victim, damage, dmgType)
    if Utils.IsActorInvalid(victim) then return end

    local inv = false
    pcall(function() inv = victim.Invincible == true end)
    if not inv then return end

    local key = victim:GetFullName()
    local st = barrierState[key]
    if not st then
        -- No tick state (OnTick never ran / wiped on stream-out): build a FULL entry so the throttle
        -- works here AND a later tick finds well-formed fields.
        st = { LastScan = -9999, LastSummon = -9999, Present = 0, Fighting = false }
        barrierState[key] = st
    end
    local now = STATE.FAST_TICK
    if st.LastHitScan and now >= st.LastHitScan and (now - st.LastHitScan) < HIT_SCAN_TICKS then
        return
    end
    st.LastHitScan = now

    if countPings(key) == 0 then
        -- Clear DIRECTLY: setBarrier's latch can be stale-true and would early-return.
        pcall(function() victim.Invincible = false end)
        VS.Set(victim, SIG_BARRIER, 0)
        barrierOn[key] = false
        LogDebug("Barrier Mage - hit with no live eyes -> barrier dropped", SETTINGS.DEBUG_NPC_ACTIONS)
    end
end


-- [OnDeath] Drop the invuln and forget all per-mage state.
function H.BarrierDeath(actor)
    if Utils.IsActorInvalid(actor) then return end
    local key = actor:GetFullName()

    pcall(function() actor.Invincible = false end)   -- never leave a corpse invulnerable
    barrierState[key] = nil
    barrierOn[key] = nil
    sheenOn[key] = nil
    barrierShell[key] = nil
end


-- =======================================================================
-- ABJURER MAGE
--
-- A support caster: no reinforcements, no duellist kit, three buffs on a fixed rotation.
--   * ROTATION is ABAC, one cast per SUPPORT_CADENCE, and only while CombatState is on. The
--     pattern is fixed rather than rolled so the shield beam lands twice per cycle and the two
--     disruptive casts never stack back to back.
--   * Every ability may pick the mage ITSELF - it is the squad's last patient, not an exception
--     to it. The beam's deficit ranking is what usually keeps it pointed at someone else.
-- =======================================================================

local SUPPORT_SHIELD_HP    = 100
local SUPPORT_SHIELD_COLOR = FVector(0.2, 1.4, 0.4)   -- green, to match the robes

-- RENDERER: mage fullname -> its shield shell (AttachShieldShell is not idempotent).
local abjurerShell = {}
local SUPPORT_SHIELD_REGEN = 5

-- Less delay before attacking. It's in a meditate montage and doesn't animate to attack
local SUPPORT_FIREBALL_DELAY = 0.1   -- 0.5

-- Hardlight spearhead - replaces its attack with this projectile
--   * `projectile_spear_hardlight` projectile row names the bare parent class and
--     carries the mesh and Laser_Gib_Hardlight type.
--       - So the spear arrives off replicated ProjectileData
--       - This is why the row write happens. A previous added Niagara trail is host-local and did not draw
local BOLT = {
    Row      = "None",     -- invalid on purpose: this IS the native-spawn suppressor
    Class    = ENUMS.ProjectileClasses.BASE,      -- what the row names
    Fires    = ENUMS.ProjectileRows.HardlightSpear,
    Speed    = 1000,       -- 1000
    LifeSpan = 3,
    Type     = ENUMS.DamageType.LaserHardlight,
    AimZ     = 40,
    -- Scale and the mesh heading ride the HardlightBolt row's look (AnteCore/ProjectileRows
    -- PR.LOOKS), so a remote client applies them to its copy as well.
}
-- The per-shot re-warm. The CLASS is not listed: PROJ.Queue loads that itself. The MESH is, because
-- the row soft-loads it inside the projectile's own BeginPlay. The row carries no debuff.
local BOLT_DEPS = {
    ENUMS.DamageType.LaserHardlight, ENUMS.Components.SM_SPEAR_HARDLIGHT_TIP,
}

-- Who counts as "my squad", decided ONCE per fight (see H.AbjurerCombat).
local ALLY_RADIUS = 3000            -- 30m
local ALLY_MAX_Z  = 600             -- ~one storey; the overlap is a true 3D sphere, and a mage
                                    -- should not tether a garrison it never fought with

-- One cast per this many ticks, whatever the rotation lands on.
local SUPPORT_CADENCE = { Normal = 70, Hard = 50 }

-- A: the shield beam.
local BEAM_SECONDS   = 2            -- tether duration
local SHIELD_RESTORE = 100
local HP_RESTORE     = 10           -- residual heal for the PICKED ally only (shield full/absent)

-- B: the lent front plate. Hard mode holds it LONGER on top of casting it more often.
local WALL_SECONDS = { Normal = 5, Hard = 7 }

-- C: the displacement hop. The ally lands in the rear half of the target's own facing, so a player
-- tracking it loses the body off the edge of the screen rather than watching it slide.
local WARP = {
    Range     = 500,    -- ~5m out from the target
    RearArc   = 100,    -- +/- degrees off the target's BACK; 180 is straight behind
    MinFromMe = 250,    -- don't bother hopping an ally that is already there
    ZExtent   = 250,    -- how far below the bearing point to look for floor
    FxOut     = "EXOR_SHOCKWAVE_CHA",   -- blue: leaving
    FxIn      = "EXOR_SHOCKWAVE",       -- red + the blink cue: arriving
}

-- Warmed immediately before each cast that can cold-load. A def.Assets preload beats GC by timing,
-- not pinning, and these fire minutes into a fight (CLAUDE.md S3).
local WALL_DEPS = { AVU.SHIELD_WALL_MESH }

local BODYSHIELD_CLASS = AVU.BODYSHIELD_CLASS

-- AUTHORITY: mage fullname -> { Roster, LastPulse, Step }.
local supportState = {}

H.ABJURER_ASSETS = {
    ENUMS.Anims.MAGE_MEDITATE,
    ENUMS.Effects.MAGEEYE_BEAM_ALLY,   -- the heal tether (host warms it; clients warm it themselves)
    ENUMS.Effects.SHIELD_REGEN_HOLY,   -- the pop on whoever the beam lands on
    ENUMS.Components.SM_SPEAR_HARDLIGHT_TIP,
    ENUMS.Components.SM_SHIELD_MAGE,   -- the lent front plate
    BODYSHIELD_CLASS,                  -- its own shield (AddComponentByClass needs it resident)
    AVU.SHIELD_SHELL_MAT,              -- the mesh that shield actually flares
    ENUMS.Components.M_MYST_HEAD_GREEN, ENUMS.Components.M_MYST_TORSO_GREEN,
    ENUMS.Components.M_MYST_LEGS_GREEN,
}


-- The mage's support record, created on demand: Stats, the combat hook, the tick and the damage
-- hook all reach for it and any of them can be first.
local function abjurerState(key)
    if not key then return nil end
    local st = supportState[key]
    if not st then
        st = { Step = 1 }
        supportState[key] = st
    end
    return st
end


-- [AUTHORITY] One spear at the current target, from the fireball socket.
local function fireBolt(actor)
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return end

    local target = actor:GetCurrentCombatTarget()
    if Utils.IsActorInvalid(target) then return end

    -- The projectile table, off the mage's own (still-pointed) handle - only its RowName was
    -- blanked. No resolve, so no UObject-array walk per shot.
    -- (Legacy only: a native handle has no table pointer, and needs none.)
    local projTable
    if not SCHEMA.Native then
        pcall(function() projTable = actor.FireballProjectile.DataTable end)
        if IsNotValid(projTable) then return end
    end

    local from
    pcall(function()
        local mesh = Utils.GetValidMesh(actor)
        from = mesh and mesh:GetSocketLocation(actor.ProjectileFireSocket)
    end)
    if not from then from = actor:K2_GetActorLocation() end
    if not from then return end

    local t = target:K2_GetActorLocation()
    local aim = FVector(t.X, t.Y, t.Z + BOLT.AimZ)
    if Utils.DistSq(from, aim) < 1 then return end

    local dmg = 0
    pcall(function() dmg = tonumber(actor.NPCData[ENUMS.NpcData.RangedDamage]) or 0 end)

    PROJ.Queue(from, Utils.Direction(from, aim), BOLT.Class, nil, {
        Owner = actor,
        Instigator = actor,
        Velocity = BOLT.Speed,
        MaxSpeed = BOLT.Speed,   -- the row's own cap is 1000; ours has to win
        GravityScale = 0,        -- the row throws it at gravity 1, i.e. into the floor
        FlightRow = ENUMS.ProjectileRows.HardlightBolt,   -- ...on every client too; wins over the PreFinish row below
        LifeSpan = BOLT.LifeSpan,
        Damage = dmg,
        DamageTypeClass = BOLT.Type,
        Preload = BOLT_DEPS,

        -- The bare parent ships an EMPTY row handle, and BeginPlay is what turns a row into the
        -- mesh, the collision and the damage type - so the write has to land before FinishSpawning.
        -- Both fields on the legacy build: unlike the thrown-weapon classes there is no table
        -- pointer to inherit. A native handle is the row name alone.
        PreFinish = function(proj)
            pcall(function()
                local h = proj.ProjectileDataRowHandle
                SCHEMA.SetRow(h, BOLT.Fires, projTable)
                proj.ProjectileDataRowHandle = h
            end)
        end,

        -- Clients build the spear from this handle, and a push-model write only sends when it is
        -- marked - the same belt PROJ.Queue puts on a thrown weapon's ItemDataRow.
        PostFinish = function(proj)
            Utils.MarkReplicatedDirty(proj, "ProjectileDataRowHandle")
        end,
    })
end


-- =======================================================================
-- THE PATIENT LIST
-- =======================================================================

-- The squad, plus the mage LAST - so a "first best" scan naturally prefers an ally and only falls
-- back to the caster when nobody else qualifies.
local function patients(mage, st)
    local out = {}
    for _, npc in ipairs(st.Roster or {}) do
        if Utils.IsActorValid(npc) and Utils.IsActorAlive(npc) then out[#out + 1] = npc end
    end
    st.Roster = out                      -- the walk doubles as the roster's dead-squadmate purge
    out[#out + 1] = mage
    return out
end


-- Is `actor` missing HP? GetTotalHealth sums the limb map, which is the authoritative read.
local function isHurt(actor)
    local hurt = false
    pcall(function() hurt = (actor:GetTotalHealth() or 0) < (actor:GetMaxTotalHealth() or 0) end)
    return hurt
end


-- How many shield points `actor` is down. 0 = full, absent, or unreadable.
local function shieldDeficit(actor)
    local gap = 0
    pcall(function()
        local sc = AVU.ResolveBodyShield(actor)
        if not sc then return end
        gap = math.max(0, (sc.MaxShieldHitPoints or 0) - (sc.CurrentShieldHitPoints or 0))
    end)
    return gap
end


-- =======================================================================
-- ABILITY A - THE SHIELD BEAM
-- =======================================================================

-- Draw the casting tether, unless the mage is treating ITSELF - a beam from a hand to the body
-- holding it reads as a glitch, and the recipient FX is tell enough. Shared by A and B.
--   * A tether needs 2 points and the replicated-FX path only takes a transform, so it rides the
--     client-FX BEAM channel rather than BroadcastFX.
local function castTether(mage, pick)
    if AVU.CachedFullName(pick) == AVU.CachedFullName(mage) then return end
    local from, to
    pcall(function()
        local mesh = Utils.GetValidMesh(mage)
        from = mesh and mesh:GetSocketLocation(FName("l_hand")) or mage:K2_GetActorLocation()
        to = pick:K2_GetActorLocation()
    end)
    if from and to then AVU.SendClientBeam(from, to, "MAGEEYE_BEAM_ALLY", BEAM_SECONDS) end
end


-- [AUTHORITY] One healing tether that replenishes shields.
--   * Picks the BIGGEST shield deficit; ties go to whoever is earlier in the list, i.e. an ally
--     over the mage. Nobody missing shields at all -> the first body with a damaged limb.
--   * The recharge flash is inside AVU.RechargeBodyShield; SHIELD_REGEN is the louder pop that
--     marks WHO was topped up, and it plays whether or not there was a tether to draw.
local function castShieldBeam(mage, pool)
    local pick, best = nil, 0
    for _, npc in ipairs(pool) do
        local gap = shieldDeficit(npc)
        if gap > best then pick, best = npc, gap end
    end
    if not pick then
        for _, npc in ipairs(pool) do
            if isHurt(npc) then
                pick = npc
                break
            end
        end
    end
    pick = pick or pool[math.random(#pool)]
    if Utils.IsActorInvalid(pick) then return end

    castTether(mage, pick)

    local at
    pcall(function() at = pick:K2_GetActorLocation() end)
    if at then AVU.SendClientFX(at, "SHIELD_REGEN", BEAM_SECONDS) end

    -- Shields first; a pick with none (or a full one) still gets the residual heal.
    if not AVU.RechargeBodyShield(pick, SHIELD_RESTORE) then
        AVU.StartShieldRegen(pick)
        AVU.HealRandomLimb(pick, HP_RESTORE)
    end
    LogDebug("Abjurer Mage - shield beam on " .. tostring(Utils.GetActorName(pick)),
        SETTINGS.DEBUG_NPC_ACTIONS)
end


-- =======================================================================
-- ABILITY B - THE SHIELD WALL
-- =======================================================================

-- [AUTHORITY] Raise the mage's OWN native plate for `secs` - the self-cast branch of ability B.
--   * Its real shield is strictly better than the lent copy: full size, replicated, and blocked by
--     the class's own `HitComponent == Shield` line rather than our arc test.
--   * Stats zeroed the mesh so a native raise would cover nothing, so the scale goes back first
--     and is re-zeroed on the way down. That write is authority-local, which is fine: a client
--     never ran Stats, so its copy is still full size.
--   * The AI_TurtleMode immunity stays on the def. This drives ShieldActive directly, so the
--     rotation is the ONLY thing that can raise the shield - CheckForTurtleMode still can't.
--   * HELD, not set once: any buff landing on or leaving the mage runs the class's BuffTagsUpdated,
--     which re-syncs ShieldActive to the TurtleMode tag this raise doesn't carry, and drops the plate
--     ([[af-mage-turtle-shield]]). A short beat puts it back up for the rest of the window.
local WALL_HOLD_MS = 300

local function setPlate(mage, up)
    AVU.SetReplicatedProp(mage, "ShieldActive", up)
    -- UpdateShieldState is the belt on the host: SetReplicatedProp's OnRep_ShieldActive call is
    -- the class's own private receiver, and it is the half that paints visibility and collision.
    -- Both are absolute writes off ShieldActive, so calling it twice costs nothing.
    pcall(function() mage:UpdateShieldState() end)
end

local function raiseNativeShield(mage, secs)
    pcall(function()
        local sh = mage.Shield
        if IsValid(sh) then sh:SetRelativeScale3D(FVector(1, 1, 1)) end
    end)
    setPlate(mage, true)

    local getMage, downAt = Utils.CarryActor(mage), Utils.NowMs() + math.floor(secs * 1000)
    local function hold()
        local m = getMage()
        if not m or Utils.IsDeadSafe(m) then return end
        if Utils.NowMs() < downAt then
            local up
            pcall(function() up = m.ShieldActive end)
            if up ~= true then setPlate(m, true) end
            Utils.QueueWork(hold, WALL_HOLD_MS)
            return
        end
        setPlate(m, false)
        pcall(function()
            local sh = m.Shield
            if IsValid(sh) then sh:SetRelativeScale3D(FVector(0, 0, 0)) end
        end)
    end
    Utils.QueueWork(hold, WALL_HOLD_MS)
end


-- [AUTHORITY] Lend the Mystagogue's forward plate to one of the squad. Prefers a body that is not
-- already wearing one, so a second cast spreads the cover instead of refreshing the same wall.
--   * The tether is drawn to it as well: same channel, same cast tell.
--   * Warm-then-cast, because AddShieldWall's AttachStaticMesh runs inside the drain.
local function castShieldWall(mage, pool)
    local pick
    for _, npc in ipairs(pool) do
        if not AVU.HasShieldWall(npc) then
            pick = npc
            break
        end
    end
    pick = pick or pool[math.random(#pool)]
    if Utils.IsActorInvalid(pick) then return end

    local secs = byMode(WALL_SECONDS)
    if AVU.CachedFullName(pick) == AVU.CachedFullName(mage) then
        raiseNativeShield(mage, secs)
        return
    end

    castTether(mage, pick)

    -- Load THEN hop back onto the drain: the attach runs AddComponentByClass, and a cold mesh
    -- there is the in-hook blocking load. Once the combat-entry pin has landed this is a cache hit.
    ASSETS.LoadAsync(WALL_DEPS, function()
        Utils.QueueWork(function() AVU.AddShieldWall(pick, { Seconds = secs }) end, 0)
    end)
end


-- =======================================================================
-- ABILITY C - DISPLACEMENT
-- =======================================================================

-- [AUTHORITY] Drop one of the squad behind whatever the mage is fighting.
--   * Needs a live combat target: with nobody to flank there is no disruption to cause, so the
--     cast is skipped rather than spent on a random hop.
--   * NPC teleports are safe in-drain - an NPC streams nothing (CLAUDE.md S2). TeleportTo does the
--     collision + movement-stop dance; the FX ride the client channel so both ends are seen.
local function castDisplace(mage, pool)
    local target = AVU.GetCurrentTarget(mage)
    if Utils.IsActorInvalid(target) then return false end

    local tLoc, tRot
    pcall(function()
        tLoc = target:K2_GetActorLocation()
        tRot = target:K2_GetActorRotation()
    end)
    if not tLoc or not tRot then return false end

    -- A bearing in the TARGET's rear arc, so the arrival is off the edge of its view rather than
    -- somewhere it was already looking.
    local yaw = (tRot.Yaw or 0) + 180 + math.random(-WARP.RearArc, WARP.RearArc)
    local ideal = AVM.RotateYaw(FVector(WARP.Range, 0, 0), yaw)

    -- ProjectToNav, not GetSpawnPoint: this is a COMPUTED coord, and the answer we need is "is
    -- there floor there, yes or no". GetSpawnPoint means "somewhere near here" and never fails -
    -- its last resort is an unprojected fuzz, which would drop the body inside a wall. A nil here
    -- is a bearing that happened to point through geometry; skipping is correct, and the cast
    -- keeps its slot so the next cycle tries a fresh angle.
    local dest = Utils.ProjectToNav(
        FVector(tLoc.X + ideal.X, tLoc.Y + ideal.Y, tLoc.Z), WARP.ZExtent)
    if not dest then return false end

    -- Everyone who would actually move, then one at random - a first-match scan would pick the
    -- same squadmate every cycle.
    local able = {}
    for _, npc in ipairs(pool) do
        local at
        pcall(function() at = npc:K2_GetActorLocation() end)
        if at and Utils.DistSq(at, dest) > (WARP.MinFromMe * WARP.MinFromMe) then
            able[#able + 1] = npc
        end
    end
    if #able == 0 then return false end
    local pick = able[math.random(#able)]
    if Utils.IsActorInvalid(pick) then return false end

    local from
    pcall(function() from = pick:K2_GetActorLocation() end)
    if from then AVU.SendClientFX(from, WARP.FxOut, 2) end
    AVU.SendClientFX(dest, WARP.FxIn, 2)

    AVU.TeleportTo(pick, dest, {
        NoFX = true,   -- the pair above IS the tell; Broadcast_TeleportFX only exists on the Monk
        OnDone = function()
            if Utils.IsActorInvalid(pick) or Utils.IsActorInvalid(target) then return end
            -- Land it facing the target, or it spends its first seconds turning around.
            pcall(function()
                pick:K2_SetActorRotation(Utils.RotatorToTarget(dest, tLoc), false)
            end)
        end,
    })
    LogDebug("Abjurer Mage - displaced " .. tostring(Utils.GetActorName(pick)),
        SETTINGS.DEBUG_NPC_ACTIONS)
    return true
end


-- The rotation. Fixed order, so the beam lands on every other cast and the two disruptive
-- abilities are always a full cadence apart.
local ROTATION = { castShieldBeam, castShieldWall, castShieldBeam, castDisplace }


-- [Stats] Strip the duellist kit, swap in the spore bolt, give it its own body shield.
function H.AbjurerStats(actor, opts)
    stripMageKit(actor)   -- no forward shield, no eyes, no grab, no gravity wave

    -- Stats runs on EVERY mutation, including a stream-back re-mutation. These stamps are FAST_TICK
    -- values that a world reset zeroes while the table survives, so a stranded future stamp would
    -- gate the cast off for good - start fresh.
    local st = abjurerState(Utils.ActorKey(actor))
    if st then st.LastPulse, st.Roster, st.Step = nil, nil, 1 end

    pcall(function() actor.FireballDelay = SUPPORT_FIREBALL_DELAY end)

    -- Replace the native fireball with the hardlight spearhead
    AVU.SetProjectileRow(actor, "FireballProjectile", BOLT.Row)

    -- Give it a small body shield. ShowFX needs a SHELL to be worth anything: the component reveals
    -- itself by un-hiding meshes tagged "bodyshield" and a mage owns none, so without the attach in
    -- Visuals below it absorbs hits with no flare at all - which reads as having no shield.
    AVU.AddBodyShield(actor, {
        Max = SUPPORT_SHIELD_HP,
        Regen = SUPPORT_SHIELD_REGEN,
        ShowFX = true,
    })
    -- The lit colour, written where the component's per-frame lerp can't stomp it.
    AVU.SetShieldFlareColor(actor, SUPPORT_SHIELD_COLOR)
end


-- [RENDERER] The shell the body shield flares. Attach-once; returns nil until the body mesh has
-- streamed in, so a miss is not latched and the next pass gets it.
function H.AbjurerShieldShell(actor)
    if not Utils.HasRenderer() or Utils.IsActorInvalid(actor) then return end
    local key = AVU.CachedFullName(actor)
    if not key or abjurerShell[key] then return end

    local shell = AVU.AttachShieldShell(actor, nil, {
        Color   = SUPPORT_SHIELD_COLOR,
        Base    = SUPPORT_SHIELD_COLOR,
        Outline = SUPPORT_SHIELD_COLOR,
        Glow    = 4,
    })
    if shell then abjurerShell[key] = shell end
end


-- [OnEnterCombat] AUTHORITY: Marks allies one time when it enters combat. It only ever supports
-- these, so a fight it walks into late is fought with the squad it started with.
function H.AbjurerCombat(actor)
    if Utils.IsActorInvalid(actor) then return end
    local st = abjurerState(Utils.ActorKey(actor))
    if not st then return end
    st.Roster = AVU.GetAllies(actor, ALLY_RADIUS, { maxZ = ALLY_MAX_Z })
    ASSETS.WarmPinned(WALL_DEPS)   -- pin the plate for the fight; the cast itself is then free
    LogDebug("Abjurer Mage - roster of " .. #st.Roster, SETTINGS.DEBUG_NPC_ACTIONS)
end


-- [OnExitCombat] The roster belongs to the fight that built it.
function H.AbjurerExitCombat(actor)
    if Utils.IsActorInvalid(actor) then return end
    local st = supportState[Utils.ActorKey(actor)]
    if st then st.Roster = nil end
end


-- [OnRangedAttack] AUTHORITY: the spear, in place of the blanked native fireball. Held for the
-- cast delay so it leaves on the beat the native spawn would have.
function H.AbjurerRangedAttack(actor)
    if not Utils.IsAuthority() or Utils.IsActorInvalid(actor) then return end
    Utils.QueueWork(function() fireBolt(actor) end, math.floor(SUPPORT_FIREBALL_DELAY * 1000))
end


-- [OnTick] AUTHORITY: one rotation step per cadence while fighting.
function H.AbjurerTick(actor, ticks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end

    local key = AVU.CachedFullName(actor)
    if Utils.IsDeadSafe(actor) then
        if key then supportState[key] = nil end
        return "REMOVE"
    end

    if not Utils.IsAuthority() then return end

    local st = abjurerState(key)
    if not st then return end

    -- Supports only while the fight is on.
    local fighting = false
    pcall(function() fighting = actor.CombatState == true end)
    if not fighting then
        st.Roster = nil
        return
    end

    -- Per-actor, so two Abjurers in the same fight don't cast in lockstep.
    if not AVU.CooldownReady(st, "LastPulse", byMode(SUPPORT_CADENCE)) then return end

    -- Mutated mid-fight (a stream-back), so the combat hook never fired: scan once, here.
    if not st.Roster then st.Roster = AVU.GetAllies(actor, ALLY_RADIUS, { maxZ = ALLY_MAX_Z }) end

    local pool = patients(actor, st)
    local step = st.Step or 1

    -- A skipped cast does NOT advance the rotation: displacement with no combat target would
    -- otherwise burn its slot and the pattern would drift out of ABAC.
    local ok, cast = pcall(ROTATION[step], actor, pool)
    if not ok then
        LogBad("Abjurer Mage - rotation step " .. step .. ": " .. tostring(cast))
    elseif cast ~= false then
        st.Step = (step % #ROTATION) + 1
    end
end


-- [OnDeath] Forget its support state.
function H.AbjurerDeath(actor)
    if Utils.IsActorInvalid(actor) then return end
    local key = Utils.ActorKey(actor)
    if key then supportState[key] = nil end
end


return H
