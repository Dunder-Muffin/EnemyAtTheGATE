-- =======================================================================
-- AVShields (SH) - the BodyShieldComponent absorb layer, its bubble, and the shield-medic kit.
-- Split out of AVUtils, merged back onto AVU: callers still write AVU.AddBodyShield / SetBodyShield
-- / SetShieldColor / ArmBarrierGlow / ...
--
-- MUST-KNOWS
--   * A body shield is a SEPARATE pool from HP and armor, routed by CLASS LOOKUP in the damage
--     pipeline - no BP wiring needed, so it can be added to any character at runtime.
--   * A shield EATS THE WHOLE HIT (LeftoverDamage is hardcoded 0) and the debuff step comes after
--     it - which is why plasma only ignites once the shield is down (CLAUDE.md 6).
--   * WHAT A HIT COSTS THE POOL IS PER DAMAGE TYPE: `BodyShieldDamage_Multiplier`, 1.0 unless the
--     type says otherwise - Laser 0.65, Sharp/Blunt 0.8, Bullet 0.9, Electric 1.1, Fire_Plasma 2.5,
--     and the null grenade's ShieldNeutralizer 1000, which one-shots any pool in the game. A type
--     with `IgnoreBodyShields` (Psychic, Cold, Bleeding, Radiation, DeathFan...) skips the pool
--     entirely and lands on HP. Full table: [[af-damage-types]].
--   * PERMABREAKING A GATEKEEPER means Max = 0, not Current = 0: CombatActivateBodyShield refills
--     Current from Max on every combat entry. The flip side of that same call is SH.ShieldAlwaysOn,
--     which holds the shell up out of combat.
--   * The absorb math is AUTHORITY; the bubble MESH + its materials are RENDERER.
--   * Decode of the flare curve, the combat gate and the shell recipe: AnNotes/AnteSystems/AVUtils.md.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local ASSETS = require("AnteCore.AssetManager")
local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local Utils = require("AnteUtils.Utils")
local ENUMS = require("AnteData.Enums")
local LogDebug = Utils.LogDebug
local LogBad = Utils.LogBad

---@class AVU.Shields      -- merged onto AVU in AVUtils; the name is what makes goto-def work
local SH = {}

local BODYSHIELD_CLASS =
    "/Game/Blueprints/Characters/Components/BodyShieldComponent.BodyShieldComponent_C"
SH.BODYSHIELD_CLASS = BODYSHIELD_CLASS   -- exported so a def can PRELOAD it (AddBodyShield needs it)

-- The energy-shield SHELL material - the overlay the native shields wear.
SH.SHIELD_SHELL_MAT = ENUMS.Components.M_ENERGY_SHIELD

-- Resolve the component the way the damage pipeline does: BP property first, then by class.
-- THE TWO READS ARE SEPARATELY pcall'd ON PURPOSE - a class with no `BodyShieldComponent` property
-- at all (a plain Pest carrying a runtime-added shield) THROWS on the property read, and a shared
-- pcall would abort before the class lookup ran.
local function resolveBodyShield(actor)
    local shield
    pcall(function() shield = actor.BodyShieldComponent end)
    if IsNotValid(shield) then
        pcall(function()
            local cls = ASSETS.GetIfValid(BODYSHIELD_CLASS)
            if IsValid(cls) then shield = actor:GetComponentByClass(cls) end
        end)
    end
    if IsNotValid(shield) then return nil end
    return shield
end

-- Exported so a caller can READ a pool (current/max) without duplicating the two-pcall resolve.
SH.ResolveBodyShield = resolveBodyShield


-- =======================================================================
-- THE ABSORB LAYER (authority)
-- =======================================================================

-- [AUTHORITY] GIVE an NPC a body shield it doesn't natively have (absorb layer only - for the
-- VISUAL shell see SH.AttachShieldShell).
--   * IDEMPOTENT: an NPC that already carries one is RE-TUNED, never given a second component,
--     so it is safe on the re-runnable mutation pipeline.
--   * opts = SH.SetBodyShield's; ShowFX defaults ON.
--   * The class must be RESIDENT (put AVU.BODYSHIELD_CLASS in def.Assets) - AddComponentByClass
--     on a cold class blocking-loads inside the tick hook (CLAUDE.md 2).

function SH.AddBodyShield(actor, opts)
    if Utils.IsActorInvalid(actor) or Utils.IsDeadSafe(actor) then return false end
    opts = opts or {}

    local cls = ASSETS.GetIfValid(BODYSHIELD_CLASS)
    if IsNotValid(cls) then
        LogBad("AddBodyShield - BodyShieldComponent class not resident (preload it in def.Assets)")
        return false
    end

    local existing
    pcall(function() existing = actor:GetComponentByClass(cls) end)
    if IsNotValid(existing) then
        local ok, err = pcall(function()
            local comp = actor:AddComponentByClass(cls, false, FTransform(), false)
            if IsNotValid(comp) then error("AddComponentByClass returned nothing") end
        end)
        if not ok then
            LogBad("AddBodyShield - " .. tostring(err))
            return false
        end
    end

    if opts.ShowFX == nil then opts.ShowFX = true end
    return SH.SetBodyShield(actor, opts)
end


-- [AUTHORITY] Tune an EXISTING body shield. Returns true if one was found. opts:
--   Max           MaxShieldHitPoints (native 300). THE main knob - combat entry does Current = Max,
--                 so lowering Max is what weakens it. Current is set to match + marked dirty.
--   Current       starting CurrentShieldHitPoints (for a part-charged spawn)
--   Regen         ShieldRegenPerSecond (native 10; 0 = never)
--   RegenTime     seconds after a hit before regen starts (native 8)
--   RegenTimeZero the longer wait after a full break (native 15)
--   ShowFX        false = absorb-only, no shield visual

function SH.SetBodyShield(actor, opts)
    if Utils.IsActorInvalid(actor) or type(opts) ~= "table" then return false end

    local found = false
    local shield = resolveBodyShield(actor)

    pcall(function()
        if IsNotValid(shield) then return end
        found = true

        if opts.Max then
            shield.MaxShieldHitPoints = opts.Max
            shield.CurrentShieldHitPoints = opts.Max
            Utils.MarkReplicatedDirty(shield, "CurrentShieldHitPoints")
        end
        if opts.Current then
            shield.CurrentShieldHitPoints = opts.Current
            Utils.MarkReplicatedDirty(shield, "CurrentShieldHitPoints")
        end
        if opts.Regen then shield.ShieldRegenPerSecond = opts.Regen end
        if opts.RegenTime then shield.ShieldRegenTime = opts.RegenTime end
        if opts.RegenTimeZero then shield.ShieldRegenTimeWhenZeroHP = opts.RegenTimeZero end
        if opts.ShowFX ~= nil then shield.ShouldShowFX = opts.ShowFX and true or false end
    end)

    if not found then LogDebug("SetBodyShield - no BodyShieldComponent on " .. Utils.GetActorName(actor), true) end
    return found
end


-- [AUTHORITY] Hold a Gatekeeper's shell up OUT of combat, closing the "hit it before it aggros"
-- window. Clearing the flag is only half of it: the parent's BeginPlay pass has already put the
-- shield away by mutation time, so the game's own activate has to be called once by hand - and
-- that call replicates it.
--   * Only the GK line carries `BodyShieldOnlyActiveInCombat`; on anything else the write is a
--     no-op and the activate does nothing, so this is safe to call on any body.
--   * Idempotent. CombatActivateBodyShield refills Current from Max, so a body that has already
--     spent some shell gets it back - call it at mutation, not on a beat.

function SH.ShieldAlwaysOn(actor)
    if Utils.IsActorInvalid(actor) then return end
    pcall(function() actor.BodyShieldOnlyActiveInCombat = false end)
    pcall(function() actor:CombatActivateBodyShield() end)
end


-- [AUTHORITY] Clear `BodyShieldAbsorbedLastHit` a beat after a hit. Call from OnDamageTaken on a
-- shielded variant that must stay FLASK-ABLE.
-- The flag is a LATCH, not per-hit state: while set, AbioticProjectile's BodyShieldCheck skips the
-- target before any buff apply, so a pest that has ever absorbed a shot ignores flasks forever.
-- Deferred because the dispatch is a PRE hook - an inline write would clear the PREVIOUS hit's
-- value instead of this one.

function SH.ClearShieldAbsorbLatch(actor)
    if Utils.IsActorInvalid(actor) then return end

    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) then return end
        pcall(function() actor.BodyShieldAbsorbedLastHit = false end)
    end, 0)
end


-- [AUTHORITY] "Did this body's shield just SHATTER?" - returns true EXACTLY ONCE per break.
-- No shield-broken event exists, so this polls. Two traps:
--   TRANSITION, not a level - a `<= 0` test would fire every poll while the shield stays down.
--   A DISABLED component is not a break - BodyShieldOnlyActiveInCombat disables it on every
--   disengage (pool reads 0 while off), so state is dropped and re-based next combat.
-- `tbl`/`key` are the caller's book; clear the entry on death alongside other state.

function SH.ShieldBreakPoll(actor, tbl, key)
    if not tbl or not key or Utils.IsActorInvalid(actor) then return false end

    local broke = false
    local ok = pcall(function()
        local sc = actor.BodyShieldComponent
        if IsNotValid(sc) or not sc.IsShieldComponentEnabled then
            tbl[key] = nil
            return
        end
        local hp = sc.CurrentShieldHitPoints or 0
        local prev = tbl[key]
        tbl[key] = hp
        broke = (prev ~= nil and prev > 0 and hp <= 0)
    end)
    if not ok then tbl[key] = nil end
    return broke
end


-- =======================================================================
-- THE BUBBLE - its colours, and holding it lit (renderer)
-- =======================================================================

-- The bubble mesh (actor.ShieldMesh) runs M_EnergyShield_Master, whose param set has NOTHING in
-- common with the character/item masters - which is why AVU.TintMesh does nothing to it.
-- Friendly key -> real param name.
local SHIELD_VEC_PARAMS = {
    Color          = "ForceFieldColor",       -- THE main one
    Base           = "BaseColor",
    BaseDamaged    = "BaseColorDamaged",
    Outline        = "OutlineColor",
    OutlineDamaged = "OutlineColorDamaged",
}
local SHIELD_SCALAR_PARAMS = {
    Glow           = "glow",                  -- lowercase in the material - not "Glow"
    Opacity        = "Opacity",
    Aurora         = "AuroraIntensity",
    AuroraEmission = "AuroraEmission",
    Red            = "Intensity_Red",
    Green          = "Intensity_Green",
    Blue           = "Intensity_Blue",
    Fresnel        = "Fresnel_Exp",
    GlitchStrength = "GlitchStrength",
    GlitchSpeed    = "GlitchSpeed",
}

-- [RENDERER] Recolour / restyle a body shield's bubble (see the param tables above for the keys).
-- Returns false if the actor has no ShieldMesh. Stats live in SH.SetBodyShield; this doesn't
-- replicate.

function SH.SetShieldColor(actor, opts)
    if Utils.IsActorInvalid(actor) or type(opts) ~= "table" then return false end

    local sm
    pcall(function() sm = actor.ShieldMesh end)
    if IsNotValid(sm) then return false end

    for key, val in pairs(opts) do
        local vec = SHIELD_VEC_PARAMS[key]
        local scalar = SHIELD_SCALAR_PARAMS[key]
        if vec then
            pcall(function() sm:SetVectorParameterValueOnMaterials(FName(vec), val) end)
        elseif scalar then
            pcall(function() sm:SetScalarParameterValueOnMaterials(FName(scalar), val) end)
        else
            LogBad("SetShieldColor - unknown key: " .. tostring(key))
        end
    end
    return true
end


-- =======================================================================
-- BARRIER GLOW - hold the bubble CONSTANTLY lit, so "I am invulnerable" reads at a glance.
-- A shield is normally hidden until it takes a hit; ToggleShieldTick(true) on an already-ticking
-- component only re-stamps LastTickStartTime, so re-calling it on a beat keeps the shell up and
-- the whole thing puts itself away within 2s of the last call (nothing to undo).
-- Two traps, both handled below: re-stamping AT the curve's start STROBES (hence the back-date),
-- and the per-frame loop REWRITES ForceFieldColor (hence SH.SetShieldFlareColor).
-- Full decode: AnNotes/AnteSystems/AVUtils.md.
-- =======================================================================

-- Beat + back-date are ONE calculation: the tick must always read its elapsed time inside the
-- flare curve's flat top [0.1, 0.8], so the window walked is [HOLD_AT, HOLD_AT + beat]. Change
-- them together. Every tick, not every fifth: the game re-stamps the flare itself on every
-- absorbed hit, which drops it to invisible, so a slower beat strobes under sustained fire.
local BARRIER_GLOW_BEAT = 1
local FLARE_HOLD_AT     = 0.3
local barrierGlowOn = {}      -- ActorKey -> true (a respawned boss is a new name -> it re-arms)

-- [RENDERER] One re-pin. Cheap and idempotent - safe to call on a beat forever.
--   * ShouldShowFX FIRST, and it is not optional: ToggleShieldTick opens with
--     `if (!ShouldShowFX) On = false`, so on a shield whose FX are off the call INVERTS into a hide
--     - and the GK parent clears that flag on every disengage.
--   * "Now" is read back off the component because ToggleShieldTick just wrote it into one of the
--     two stamps and which one depends on the branch it took; both are past times, so the later is now.

function SH.HoldShieldFlare(actor)
    if Utils.IsActorInvalid(actor) then return false end
    local shield = resolveBodyShield(actor)
    if not shield then return false end
    pcall(function() shield.ShouldShowFX = true end)
    if not pcall(function() shield:ToggleShieldTick(true) end) then return false end

    pcall(function()
        local first = shield.FirstTickStartTime or 0
        local last  = shield.LastTickStartTime or 0
        local now   = (first > last) and first or last
        shield.LastTickStartTime = now - FLARE_HOLD_AT
    end)
    return true
end


-- [RENDERER] The colour a lit shield settles on, written where the per-frame loop can't stomp it
-- (it lerps ForceFieldColor between these two every frame). BOTH ends, or a damaged pool drifts
-- back toward the stock breaking-red.

function SH.SetShieldFlareColor(actor, color)
    if Utils.IsActorInvalid(actor) or not color then return false end
    local shield = resolveBodyShield(actor)
    if not shield then return false end

    -- Per-channel writes into the live struct, never a whole-struct assignment (CLAUDE.md 3).
    local r, g, b = color.X, color.Y, color.Z
    pcall(function()
        for _, field in ipairs({ "Color_FullShield", "Color_ShieldBreaking" }) do
            local c = shield[field]
            c.R = r
            c.G = g
            c.B = b
            c.A = 1
        end
    end)

    -- Read back: a write UE4SS silently drops looks identical to success, and the symptom here is
    -- a shield that lights up WHITE instead of coloured.
    local ok = false
    pcall(function() ok = shield.Color_FullShield.R == r end)
    if not ok then
        Utils.Log("SetShieldFlareColor - Color_FullShield write did not stick on "
                  .. tostring(Utils.GetActorRowName(actor)))
    end
    return ok
end


-- [RENDERER] Arm the whole thing on one actor: colour it, then keep it lit while its pool is up.
-- A Visuals-time call - it registers ONE renderer tick per actor (hence the latch), and every
-- machine that draws the boss makes its own off the replicated pool.
--   opts.Color     FVector flare colour        opts.MinPoints  pool size that counts as "up" (1)

function SH.ArmBarrierGlow(actor, opts)
    if not Utils.HasRenderer() then return end
    if Utils.IsActorInvalid(actor) then return end
    opts = opts or {}

    if opts.Color then SH.SetShieldFlareColor(actor, opts.Color) end

    local key = Utils.ActorKey(actor)
    if not key or barrierGlowOn[key] then return end
    barrierGlowOn[key] = true

    local AVU = require("AnteUtils.AVUtils")   -- lazy: AVUtils requires US (merge loop)
    local minPoints = opts.MinPoints or 1
    AVU.RegisterOnTickActor(actor, function(a, ticks)
        if Utils.IsActorInvalid(a) then barrierGlowOn[key] = nil return "REMOVE" end
        if a.IsDead then barrierGlowOn[key] = nil return "REMOVE" end
        if ticks % BARRIER_GLOW_BEAT ~= 0 then return end

        -- THE POOL IS THE WHOLE TEST. Do NOT also require IsShieldComponentEnabled: the GK parent
        -- clears it on every disengage, so gating on it makes the barrier go dark out of combat
        -- while it is still holding. Deactivation never touches the pool.
        local up = false
        pcall(function()
            local sc = a.BodyShieldComponent
            if IsValid(sc) and (sc.CurrentShieldHitPoints or 0) >= minPoints then up = true end
        end)
        if up then SH.HoldShieldFlare(a) end
    end)
end


-- [RENDERER] Build a shield's VISUAL shell for an NPC with no native one, the way the ShieldPest
-- does: the NPC's own body mesh, leader-posed, wearing the energy-shield material, hidden, and
-- component-TAGGED "bodyshield" - that tag is the entire wiring (BodyShieldComponent finds its
-- meshes via GetComponentsByTag and re-scans when its list is empty).
--   Pair with SH.AddBodyShield (the authority-side absorb layer).
--   meshOrPath OPTIONAL - omitted, uses the actor's own body mesh.
--   Color -> ForceFieldColor, blended with the material's own Base/Outline, so Color alone leaves
--   the stock hue showing through. Pass Base / Outline / Glow too to fully own the look.
--   Material swaps the shell material PATH (the stock GK instance exposes no params). Must be preloaded.
--   NOT idempotent (AddComponentByClass) - guard the call site once per actor.

function SH.AttachShieldShell(actor, meshOrPath, opts)
    opts = opts or {}
    local shellMat = opts.Material or SH.SHIELD_SHELL_MAT
    if Utils.IsActorInvalid(actor) then return nil end
    local AVU = require("AnteUtils.AVUtils")   -- lazy: AVUtils requires US (merge loop)

    if not meshOrPath then
        local mesh = Utils.GetValidMesh(actor)
        if not mesh then return nil end
        pcall(function() meshOrPath = mesh:GetSkeletalMeshAsset() end)
        if IsNotValid(meshOrPath) then return nil end   -- mesh not streamed in yet; caller retries
    end

    -- Immediate = true: OPT OUT of the spawner attach-stagger. This is the one caller that USES
    -- the returned component, and its contract with ITS callers is "nil = not ready, retry next
    -- tick" - a staggered attach returns nil while still welding a shell, so the retry loop would
    -- stack a fresh shell every tick.
    local comp = AVU.AttachSkeletalMesh(actor, meshOrPath, "root",
        { LeaderPose = true, Material = shellMat, Immediate = true })
    if not comp then return nil end

    -- EVERY material slot: AttachSkeletalMesh's `Material` opt only overrides slot 0, so a
    -- multi-slot body (the Mage: body + robe + gas mask) would render as a normal-looking
    -- duplicate with one glowing piece.
    pcall(function()
        local mat = ASSETS.GetIfValid(shellMat)
        if IsNotValid(mat) then return end
        local n = comp:GetNumMaterials()
        for i = 0, (n or 1) - 1 do
            pcall(function() comp:SetMaterial(i, mat) end)
        end
    end)

    pcall(function() table.insert(comp.ComponentTags, FName("bodyshield")) end)

    -- Nudge the (authority-added) component's tag re-scan now that the shell exists.
    pcall(function()
        local cls = ASSETS.GetIfValid(BODYSHIELD_CLASS)
        if IsNotValid(cls) then return end
        local shield = actor:GetComponentByClass(cls)
        if IsValid(shield) then shield:UpdateMaterials() end
    end)

    pcall(function()
        if opts.Color then comp:SetVectorParameterValueOnMaterials(FName("ForceFieldColor"), opts.Color) end
        if opts.Base then
            comp:SetVectorParameterValueOnMaterials(FName("BaseColor"), opts.Base)
            comp:SetVectorParameterValueOnMaterials(FName("BaseColorDamaged"), opts.Base)
        end
        if opts.Outline then
            comp:SetVectorParameterValueOnMaterials(FName("OutlineColor"), opts.Outline)
            comp:SetVectorParameterValueOnMaterials(FName("OutlineColorDamaged"), opts.Outline)
        end
        if opts.Glow then comp:SetScalarParameterValueOnMaterials(FName("glow"), opts.Glow) end
        comp:SetVisibility(false, false)   -- the component shows it on an absorbed hit
    end)
    return comp
end


-- =======================================================================
-- THE MEDIC KIT (decoded off NarrativeNPC_BossAlly_Mage)
-- =======================================================================

-- [AUTHORITY] Top a body shield back up; FALSE if the actor has none (fall back to a real HP heal).
--   * CurrentShieldHitPoints replicates once marked dirty, and the component ships its own
--     multicast for the recharge FX - so we let the game draw its own effect.
--   * amount = HP to restore (nil / <=0 = fill to max).

function SH.RechargeBodyShield(actor, amount)
    if not Utils.IsAuthority() or Utils.IsActorInvalid(actor) then return false end

    local shield = resolveBodyShield(actor)
    if not shield then return false end

    local healed = false
    pcall(function()
        local cur = shield.CurrentShieldHitPoints or 0
        local max = shield.MaxShieldHitPoints or 0
        if max <= 0 or cur >= max then return end   -- nothing to give back

        local want = (amount and amount > 0) and math.min(max, cur + amount) or max
        shield.CurrentShieldHitPoints = want
        Utils.MarkReplicatedDirty(shield, "CurrentShieldHitPoints")
        shield:OnRep_CurrentShieldHitPoints()   -- host: the local bar/material update
        healed = true
    end)

    if healed then pcall(function() shield:Broadcast_PlayRegenShieldParticle() end) end
    return healed
end


-- [AUTHORITY] Knock `amount` off a body shield's pool with no hit behind it - a DIRECT pool write,
-- so no damage pipeline runs and nothing can cascade. False if the actor has no enabled shield with
-- anything left in it.
--   * Mirrors Server_TryApplyDamageToShield's own tail: clamp at 0, mark dirty, OnRep (the break FX
--     and the regen-tick toggle live there), then restart the post-damage regen wait.
--   * Zero is the native broken state - the same thing a shattering hit leaves behind.

function SH.DrainBodyShield(actor, amount)
    if not Utils.IsAuthority() or Utils.IsActorInvalid(actor) then return false end

    local shield = resolveBodyShield(actor)
    if not shield then return false end

    local drained = false
    pcall(function()
        if not shield.IsShieldComponentEnabled then return end
        local cur = tonumber(shield.CurrentShieldHitPoints) or 0
        if cur <= 0 then return end

        shield.CurrentShieldHitPoints = math.max(0, cur - (tonumber(amount) or 0))
        Utils.MarkReplicatedDirty(shield, "CurrentShieldHitPoints")
        shield:OnRep_CurrentShieldHitPoints()   -- host: the local bar/material/break FX
        drained = true
    end)

    if drained then pcall(function() shield:RestartShieldRegenWaitTime() end) end
    return drained
end


-- [AUTHORITY] Kick a shield into REGENERATING instead of handing it points - the "I could not heal
-- you, but I can restart your recharge" branch (it resets the post-damage lockout).

function SH.StartShieldRegen(actor)
    if not Utils.IsAuthority() or Utils.IsActorInvalid(actor) then return false end

    local shield = resolveBodyShield(actor)
    if not shield then return false end

    return (pcall(function() shield:RestartShieldRegenWaitTime() end))
end


-- [AUTHORITY] Heal real HP: restores `amount` to ONE damaged limb, so repeated calls walk the
-- whole body back up. Returns the native Success flag (false = nothing was damaged).
--   * `Server_HealRandomLimb(Amount, bool& Success)` is an OUT-PARAM UFunction and the out is NOT
--     optional - omitting it makes UE4SS error, the pcall eat it, and the heal never happen, which
--     reads exactly like a body that had nothing to heal (CLAUDE.md 3). AFUtils' own call is the
--     reference shape.
--   * The flag comes back as the return on this build; the table is read as well, so a build that
--     fills it instead still answers.

function SH.HealRandomLimb(actor, amount)
    if not Utils.IsAuthority() or Utils.IsActorInvalid(actor) then return false end
    local out, ret = { Success = false }, nil
    if not pcall(function() ret = actor:Server_HealRandomLimb(amount or 25, out) end) then
        LogBad("HealRandomLimb - Server_HealRandomLimb call FAILED on " .. Utils.GetActorName(actor))
        return false
    end
    return ret == true or out.Success == true
end


-- =======================================================================
-- THE FRONT SHIELD-WALL (authority absorb + renderer plate)
--
-- The Mystagogue's forward plate, lent to any character for a few seconds. Two halves that are
-- deliberately INDEPENDENT of each other:
--
--   1. The BLOCK is an ARC TEST, answered here and read by CombatHooks' damage-multiplier hook.
--      A shot from inside the wearer's frontal cone is absorbed; anything from the flank or
--      behind lands in full. Walking around it is the counter-play.
--   2. The PLATE is a cosmetic StaticMeshComponent with NO COLLISION - it is the tell, not the
--      mechanism.
--
-- WHY THE PLATE DOES NOT COLLIDE, even though the native one does. The native block is
-- NPC_Mage::ProcessDamage early-outing on `HitComponent == Shield`; a class without that line
-- takes the hit in FULL, so a colliding plate on a borrowed body is a HITBOX EXTENDER, not cover.
-- Reproducing the check needs the component identity to reach whoever applies the damage, and a
-- Lua-added component does not replicate - a remote client's trace has no plate to name. The arc
-- is decided from two transforms, so every role agrees. It also means the plate can never eat the
-- wearer's own outgoing shots or snag on level geometry.
--
-- LIFETIME IS OWNED BY THE WEARER, never the caster: expiry rides the wearer's own OnTick entry,
-- so a caster that dies or streams out mid-cast cannot strand a permanent ward.
-- =======================================================================

SH.SHIELD_WALL_MESH = ENUMS.Components.SM_SHIELD_MAGE

-- Lower-body plate for an average humanoid, at half the size the Mystagogue carries.
--   * Parented to the CAPSULE (opts.ToRoot), like the native shield component, so +X really is
--     "in front of the body" and the offsets below are directly comparable to the native
--     (70, 0, 150) at scale 1.
--   * The mesh is NOT centred - it spans local Z -140..+112 - so at 0.5 scale an offset of -20
--     from the capsule centre puts the plate at roughly shin to mid-chest above the feet. Head and
--     shoulders stay clear, which is what keeps the wearer shooting over it.
local WALL = {
    Scale  = FVector(0.6, 0.6, 0.6),
    Offset = FVector(45, 0, -20),
    Arc    = 60,    -- half-angle; past ~65 deg the plate is edge-on and narrower than the body
    Absorb = 1.0,   -- fraction of a frontal hit eaten; < 1 turns the wall into partial cover
}


-- Expiry, owned by the WEARER, never the caster (see the banner). Doubles as the teardown for a
-- wearer that dies or streams out with the wall still up.
local function armWallExpiry(actor, key)
    local AVU = require("AnteUtils.AVUtils")
    AVU.RegisterOnTickActor(actor, function(self)
        if Utils.IsActorInvalid(self) then
            STATE.ShieldWalls[key] = nil   -- the plate went with the body
            return "REMOVE"
        end
        local live = STATE.ShieldWalls[key]
        if not live or STATE.FAST_TICK >= live.Until or Utils.IsDeadSafe(self) then
            SH.RemoveShieldWall(self)
            return "REMOVE"
        end
    end)
end


-- Drop a wearer's wall: destroy the plate, forget the ward. Safe to call on anything.
function SH.RemoveShieldWall(actor)
    local key = Utils.ActorKey(actor)
    local rec = key and STATE.ShieldWalls[key]
    if not rec then return false end

    STATE.ShieldWalls[key] = nil
    -- The wrapper is only ever handed to DestroyComponent, and only inside its own few seconds of
    -- life - no setter ever sees it (CLAUDE.md S3).
    if not Utils.IsComponentInvalid(rec.Comp) then
        pcall(function() rec.Comp:K2_DestroyComponent(rec.Comp) end)
    end
    return true
end


-- Lend `actor` a front shield-wall for `opts.Seconds`.
--   opts: Seconds (default 5) . Arc / Absorb / Scale / Offset (default WALL above)
--        Local = true - build the PLATE ONLY, no client push. This is what the SHIELD_WALL channel
--        entry passes on arrival; every other caller wants the default.
--   * Only SECONDS crosses to clients - the channel carries a point and a duration, nothing else.
--     A caller that overrides Scale/Offset/Arc gets its shape on the authority and the defaults on
--     every renderer, so change the defaults rather than passing a one-off.
--   * RUNS ON EVERY ROLE, deliberately. The authority needs the record for the arc test, and each
--     renderer needs its own plate (a runtime-added component does not replicate) - and both are
--     the same attach with the same wearer-owned expiry, so it is one function.
--   * The mesh must be RESIDENT - warm SH.SHIELD_WALL_MESH right before the cast; a def.Assets
--     preload does not pin, and this fires minutes after mutation (CLAUDE.md S3).
--   * Re-applying to a wearer that already has one REFRESHES it rather than stacking a plate.
function SH.AddShieldWall(actor, opts)
    opts = opts or {}
    if Utils.IsActorInvalid(actor) or Utils.IsDeadSafe(actor) then return false end

    local AVU = require("AnteUtils.AVUtils")   -- lazy: AVUtils requires US (merge loop)
    local key = Utils.ActorKey(actor)
    if not key then return false end

    local secs = opts.Seconds or 5
    local expiry = STATE.FAST_TICK + math.max(1, math.floor(secs * 10))

    -- Renderers that are also the authority (host/SP) push once and build once; a pure client only
    -- ever arrives here through the channel, with Local set.
    if not opts.Local and Utils.IsAuthority() then
        local at
        pcall(function() at = actor:K2_GetActorLocation() end)
        if at then AVU.SendClientFX(at, "SHIELD_WALL", secs) end
    end

    local rec = STATE.ShieldWalls[key]
    if rec and not Utils.IsComponentInvalid(rec.Comp) then
        rec.Until = expiry
        return true
    end

    if not Utils.HasRenderer() then
        -- Dedicated server: no plate to build, but the arc test still needs its record.
        STATE.ShieldWalls[key] = {
            Until = expiry,
            Cos = math.cos(math.rad(opts.Arc or WALL.Arc)),
            Absorb = opts.Absorb or WALL.Absorb,
        }
        armWallExpiry(actor, key)
        return true
    end

    local comp = AVU.AttachStaticMesh(actor, SH.SHIELD_WALL_MESH, nil, {
        ToRoot = true,
        Immediate = true,   -- the record needs the component back, so no stagger
        Location = opts.Offset or WALL.Offset,
        Scale = opts.Scale or WALL.Scale,
    })
    if Utils.IsComponentInvalid(comp) then
        LogBad("AddShieldWall - plate attach failed (mesh not resident?)")
        return false
    end

    STATE.ShieldWalls[key] = {
        Until = expiry,
        Cos = math.cos(math.rad(opts.Arc or WALL.Arc)),
        Absorb = opts.Absorb or WALL.Absorb,
        Comp = comp,
    }

    armWallExpiry(actor, key)

    LogDebug("ShieldWall - " .. tostring(Utils.GetActorName(actor)) .. " warded for " .. secs .. "s",
        SETTINGS.DEBUG_NPC_ACTIONS)
    return true
end


-- Is a wall currently up on `actor`? (ShieldWallSurvival needs a shooter, so it cannot answer this.)
function SH.HasShieldWall(actor)
    local key = Utils.ActorKey(actor)
    local rec = key and STATE.ShieldWalls[key]
    if not rec then return false end
    if STATE.FAST_TICK >= rec.Until then
        SH.RemoveShieldWall(actor)
        return false
    end
    return true
end


-- Does `actor`'s wall eat a hit thrown from `fromLoc`? Returns the SURVIVING fraction (1 = no wall
-- or flanked, 0 = fully absorbed), so a caller can just multiply.
--   * Hot path: called per NPC damage event, so CombatHooks gates it on the registry being
--     non-empty first. Everything past that is two transform reads and a dot product.
function SH.ShieldWallSurvival(actor, fromLoc)
    local key = fromLoc and Utils.ActorKey(actor)
    local rec = key and STATE.ShieldWalls[key]
    if not rec then return 1 end

    if STATE.FAST_TICK >= rec.Until then
        SH.RemoveShieldWall(actor)
        return 1
    end

    local at, rot
    pcall(function()
        at = actor:K2_GetActorLocation()
        rot = actor:K2_GetActorRotation()
    end)
    if not at or not rot then return 1 end

    local AVM = require("AnteUtils.AVMath")
    -- Flat cone: the plate is a vertical slab, so a shooter's height says nothing about whether
    -- they are in front of it.
    local fwd = AVM.ForwardFromRotator(FRotator(0, rot.Yaw, 0))
    local dx, dy = (fromLoc.X or 0) - at.X, (fromLoc.Y or 0) - at.Y
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1 then return 1 end   -- contact range: no meaningful bearing to test

    if ((fwd.X * dx) + (fwd.Y * dy)) / len < rec.Cos then return 1 end
    return 1 - rec.Absorb
end


return SH
