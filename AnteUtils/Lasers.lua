-- =======================================================================
-- Lasers - everything that touches a ULaserComponent, in one place. Split out of AVUtils because
-- it is a real subsystem with its own decoded rules. Callers: GK_Mage (the Mage Eye, the only NPC
-- that ships with a LaserComponent), RobotDefense (Deatomizer sweep), RobotContainment,
-- PestElectro + TamedPests (the burst), and ClientVisuals (repainting client-built beams).
--
-- Two different things live here, easy to conflate:
--   1. ULaserComponent - the real beam. Traces, damages, bounces, and replicates LaserActive
--      (rep 18) + LaserEnd (rep 17). Everything below except RecolorSight is about this.
--   2. actor.Laser - a plain Niagara laser sight on the Order Sniper. No trace, no damage, no
--      replication. RecolorSight is the only function that touches it.
--
-- The colour never replicates (neither LaserColor nor CurrentLaserColor), so a joined client
-- builds every beam from the component's default red inside OnRep_LaserActive and must be told
-- what to repaint. That's `def.LaserStyle` + ClientVisuals' hook: one declaration, resolved
-- independently per end, nothing on the wire.
--
-- Cold-load risk (CLAUDE.md S2): building a beam runs AddComponentByClass + SetAsset on the beam
-- Niagara. Preload ENUMS.LaserComponent and the beam FX in the variant's Assets, or it blocking-
-- loads inside our tick hook and freezes.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local Utils = require("AnteUtils.Utils")
local ASSETS = require("AnteCore.AssetManager")

local LogBad = Utils.LogBad
local LogDebug = Utils.LogDebug

local Lasers = {}

-- How often the component re-traces (its own TraceInterval default). Used to phase a burst's beams.
Lasers.TRACE_INTERVAL_MS = 200

-- Floor on a beam's activation delay, so no beam can ever activate inside FireBurst's creation
-- loop (see the ACTIVATE note there). One drain tick is enough - this only has to move the work
-- into a different pass, not into a different second.
local ACTIVATE_MIN_MS = 1

-- The three Niagara systems a ULaserComponent builds lazily on a renderer the first time a beam
-- lights (InitParticleComponent -> AddComponentByClass -> SetAsset). Cold-loading them in our tick
-- hook is the S2 deadlock, so any variant that lights a beam - or spawns something that will -
-- lists these in def.Assets. They live here because they belong to the component, not the NPC.
Lasers.FX_BEAM = ENUMS.Effects.LASER_EMITTER_BEAM
Lasers.FX_END  = ENUMS.Effects.LASER_END_IMPACT
Lasers.FX_RECV = ENUMS.Effects.LASER_RECEIVING

-- Everything a beam can touch on its way to being visible. Warm this (ASSETS.LoadAsync)
-- immediately before any Lasers.FireBurst - the class alone is not enough. Lighting one beam runs
-- OnRep_LaserActive -> InitParticleComponent (adds a NiagaraComponent, SetAssets the beam system),
-- Local_ChangeLaserColor (SetVariableMaterials one of three beam materials), ToggleSounds (spawns
-- two looping USoundWaves). All are hard object constants on LaserComponent_C, so it's tempting to
-- assume they ride in with the class - that assumption caused a freeze. Naming them here makes
-- residency our own guarantee. A preload doesn't pin (CLAUDE.md S3), so this still has to be
-- re-done at fire time.
Lasers.BURST_ASSETS = {
    ENUMS.LaserComponent,
    Lasers.FX_BEAM, Lasers.FX_END, Lasers.FX_RECV,
    ENUMS.Effects.M_LASERBEAM,
    ENUMS.Effects.M_LASERBEAM_BLACK,
    ENUMS.Effects.M_LASERBEAM_GLITCHED,
    ENUMS.SOUNDS.LASER_EMIT_LOOP,
    ENUMS.SOUNDS.LASER_HIT_HISS_LOOP,
}


-- =======================================================================
-- STYLE - colour AND material, because EPaintColor drives both. Local_ChangeLaserColor picks the
-- material off the same enum as the colour, then reads the colour from the component's own
-- LaserColor_<name> swatch properties:
--     13 (Glitch) -> M_LaserBeam_Glitched   <- the arcing / lightning beam
--      7 (Black)  -> M_LaserBeam_Black
--      else       -> M_LaserBeam            (plain)
-- So "lightning" is just LaserColor 13, not a separate system. LaserColor_Glitch is flat white by
-- default, so overwrite that swatch property first - the native switch then hands our colour back
-- for case 13, giving an arcing beam in any colour.
--
-- style = { Color = Lasers.COLOR.PURPLE, Arc = true, Tint = <FLinearColor, overrides the swatch> }
-- =======================================================================
Lasers.COLOR = {
    WHITE = 0, BLUE = 1, RED = 2, GREEN = 3, ORANGE = 4, PURPLE = 5, YELLOW = 6,
    BLACK = 7, CYAN = 8, LIME = 9, PINK = 10, BROWN = 11, GLITCH = 13,
}

-- EPaintColor -> the HDR swatch to paint it with.
local SWATCH = {
    [Lasers.COLOR.WHITE]  = FLinearColor(10, 10, 10, 1),
    [Lasers.COLOR.BLUE]   = FLinearColor(0, 0, 10, 1),
    [Lasers.COLOR.RED]    = FLinearColor(10, 0, 0, 1),
    [Lasers.COLOR.GREEN]  = FLinearColor(0, 10, 0, 1),
    [Lasers.COLOR.ORANGE] = FLinearColor(10, 4, 0, 1),
    [Lasers.COLOR.PURPLE] = FLinearColor(5, 0, 10, 1),
    [Lasers.COLOR.YELLOW] = FLinearColor(10, 9.794715, 0.36, 1),
    [Lasers.COLOR.CYAN]   = FLinearColor(2.62251, 10, 9.646877, 1),
    [Lasers.COLOR.LIME]   = FLinearColor(2.430993, 10, 0.31194, 1),
    [Lasers.COLOR.PINK]   = FLinearColor(10, 0.056038, 7.443662, 1),
}

-- The palette a burst falls back to when nothing declares a style (the Laser Pest). Each machine
-- rolls its own, so host and client see different colours for one beam - cosmetic, and exactly why
-- the Laser Pest reads as chaotic rather than uniform.
local BURST_PALETTE = {
    Lasers.COLOR.BLUE, Lasers.COLOR.RED, Lasers.COLOR.GREEN, Lasers.COLOR.ORANGE,
    Lasers.COLOR.PURPLE, Lasers.COLOR.YELLOW, Lasers.COLOR.CYAN, Lasers.COLOR.LIME,
    Lasers.COLOR.PINK,
}

-- `def.LaserStyle = Lasers.RANDOM` - the OPT-OUT sentinel. SETTINGS.GAMEPLAY.CLIENT_LASER_COLOR pins every
-- undeclared beam to one colour so a session agrees on it; a variant whose point IS the chaos (the
-- Laser Pests) declares this and keeps rolling per beam, per machine. A string, so it can't be
-- mistaken for a real style table.
Lasers.RANDOM = "RANDOM"

-- [RENDERER] One fresh palette colour. Rolled independently on each machine - nothing here
-- replicates, and that mismatch is the effect.
function Lasers.RandomStyle()
    return { Color = BURST_PALETTE[math.random(#BURST_PALETTE)] }
end


-- [ANY ROLE] Resolve the ULaserComponent from either the component itself or an actor that owns one
-- as a `LaserComponent` property (the Mage Eye). Returns nil if there is none.
function Lasers.Of(target)
    if IsNotValid(target) then return nil end

    -- Separately pcall'd: a component has no `.LaserComponent` property at all, and that read
    -- throws rather than returning nil.
    local comp = target
    pcall(function()
        local own = target.LaserComponent
        if IsValid(own) then comp = own end
    end)

    if IsNotValid(comp) then return nil end
    return comp
end


-- [RENDERER] Paint a beam; `target` = the component or its owning actor. Machine-local (none of
-- these props replicate), so every renderer calls it for itself - the server when it builds the
-- beam, the client in ClientVisuals' OnRep hook.
function Lasers.SetStyle(target, style)
    if not style then return end

    local comp = Lasers.Of(target)
    if not comp then return end

    local color = style.Color or Lasers.COLOR.RED
    local tint = style.Tint or SWATCH[color]

    pcall(function()
        if style.Arc then
            if tint then comp.LaserColor_Glitch = tint end   -- repaint the swatch, then select it
            comp.LaserColor = Lasers.COLOR.GLITCH
        else
            comp.LaserColor = color
        end
        if tint then comp.CurrentLaserColor = tint end
    end)

    -- Repaint an existing beam Niagara now. If there isn't one, InitParticleComponent will call
    -- Local_ChangeLaserColor with the LaserColor we just wrote - so the style lands either way and
    -- this is safe before the beam is ever up.
    pcall(function()
        local beam = comp.NiagaraComponent
        if IsValid(beam) then comp:Local_ChangeLaserColor(beam, comp.LaserColor) end
    end)
end


-- An actor's variant-declared `def.LaserStyle`, or nil - the single source of truth: the server
-- applies it when building the beams, the client re-applies it in ClientVisuals' OnRep hook, and
-- nothing crosses the wire. Lazy require: this module loads long before the variant registry.
function Lasers.GetStyle(actor)
    if Utils.IsActorInvalid(actor) then return nil end
    local ok, style = pcall(function()
        local id = require("AnteVariants.VariantTag").Decode(actor)
        if not id then return nil end
        for _, def in pairs(require("AnteVariants.Variants")) do
            if def.Id == id then return def.LaserStyle end
        end
        return nil
    end)
    if not ok then return nil end
    return style
end


-- [RENDERER] The style decision for a beam `actor` owns, in priority order:
--   1. `explicit`                 - the caller's own override (FireBurst's opts.Style)
--   2. def.LaserStyle             - what the variant declares...
--      ...or Lasers.RANDOM, its OPT-OUT: returned verbatim so the caller re-rolls PER BEAM
--   3. SETTINGS.GAMEPLAY.CLIENT_LASER_COLOR - pins every remaining beam to one colour for multiplayer
--   4. nil                        - caller decides (legacy opts.Color, else a random colour)
-- Both ends call this (server at build, ClientVisuals in its OnRep hook), so they agree.
function Lasers.ResolveStyle(actor, explicit)
    if explicit then return explicit end

    local declared = Lasers.GetStyle(actor)
    if declared then return declared end   -- a table, or the RANDOM sentinel

    if SETTINGS.GAMEPLAY.CLIENT_LASER_COLOR then return { Color = SETTINGS.GAMEPLAY.CLIENT_LASER_COLOR } end
    return nil
end


-- [RENDERER] Recolor an NPC's laser sight - `actor.Laser`, a plain Niagara (the Order Snipers).
-- Not a ULaserComponent: it does not trace, damage or replicate. Sets both the Color and BeamColor
-- params (a wrong name just no-ops, so one call covers either master). color = FLinearColor.
-- Niagara doesn't replicate -> call from Visuals (and ClientVisuals mirrors it per client).
function Lasers.RecolorSight(actor, color)
    if Utils.IsActorInvalid(actor) then return end
    local laser = actor.Laser
    if IsNotValid(laser) then return end
    pcall(function() laser:SetColorParameter(FName("Color"), color) end)
    pcall(function() laser:SetColorParameter(FName("BeamColor"), color) end)
end


-- =======================================================================
-- LIVE BEAM CONTROL - for an actor that already OWNS a LaserComponent (the Mage Eye).
-- FireBurst below is the other case: building throwaway beams on something that has none.
-- =======================================================================

-- [AUTHORITY] Light a beam with its opening trace disarmed. Every activation goes through here.
--   * OnRep_LaserActive(true) arms the trace timer, then runs one LaserTrace inline. From the
--     drain or an OnTick, a kill on that trace runs the victim's whole death sequence (native
--     loot spawns, death FX) inside our hook - the S5 kill-path wedge.
--   * LaserTrace reads LaserDamage live and ApplyPointDamage ignores 0, so zeroing it across the
--     call disarms only the inline trace. Every damaging trace then comes off the native timer.
--   * `damage` is the value to restore; omit it to restore whatever the component held.
local function lightBeam(comp, damage)
    if type(damage) ~= "number" then
        pcall(function() damage = comp.LaserDamage end)
    end
    local disarm = type(damage) == "number"   -- never zero a value we can't put back
    if disarm then pcall(function() comp.LaserDamage = 0 end) end
    pcall(function()
        comp.LaserActive = true
        Utils.MarkReplicatedDirty(comp, "LaserActive")
        comp:OnRep_LaserActive()
    end)
    if disarm then pcall(function() comp.LaserDamage = damage end) end
end


-- [AUTHORITY] Turn the beam on/off.
--   * OnRep_LaserActive is not optional on the server - it starts the TickLaserTrace timer that
--     produces LaserEnd (what clients draw the beam to). Skip it and the beam never appears or
--     damages. MarkReplicatedDirty pushes LaserActive so clients run their half (sound + FX start).
--   * Turning it off matters just as much: death doesn't touch LaserActive, so a live beam keeps
--     re-tracing and hangs until the corpse is destroyed. The dirty `false` makes each client's own
--     OnRep tear down its own beam Niagara - a server-side destroy can't reach the client's copy.
function Lasers.SetActive(target, on)
    local comp = Lasers.Of(target)
    if not comp then return end

    local cur
    pcall(function() cur = comp.LaserActive end)
    if cur == on then return end   -- latched: re-dirtying an unchanged bool is pure wire traffic

    if on then lightBeam(comp); return end

    pcall(function()
        comp.LaserActive = false
        Utils.MarkReplicatedDirty(comp, "LaserActive")
        comp:OnRep_LaserActive()
    end)
end


-- [AUTHORITY] Point the beam at an actor. LaserTrace uses ONLY the component's world location and
-- forward vector, so rotation is the whole aiming mechanism - and it never needs to replicate,
-- since clients draw from the component to the replicated LaserEnd. Re-call every tick on an
-- animated mesh: world rotation is re-derived from the parent each frame, so a one-shot aim drifts.
function Lasers.AimAt(target, atActor, zOff)
    local comp = Lasers.Of(target)
    if not comp or Utils.IsActorInvalid(atActor) then return end

    pcall(function()
        local from = comp:K2_GetComponentLocation()
        local to = atActor:K2_GetActorLocation()
        if not from or not to then return end
        local rot = Utils.RotatorToTarget(from, FVector(to.X, to.Y, to.Z + (zOff or 0)))
        comp:K2_SetWorldRotation(rot, false, {}, true)
    end)
end


-- AUTHORITY: component fullname -> its ORIGINAL LaserDamage, stashed before we zero it.
local damageBase = {}

-- [AUTHORITY] Set / restore a beam's damage knobs. GetLaserDamage() reads LaserDamage live per hit,
-- so 0 is a true no-damage beam (the Mage Eye's channel, the Warden's searchlight).
--   opts.Damage       the new damage (default 0)
--   opts.Bounces      MaxLaserBounces
--   opts.MaxDistance  LaserMaxDistance, and the way to stop an owner from showing a beam at all:
--                     set 1 and the trace ends a centimetre out, so there's nothing to draw.
--                     Switching the beam off doesn't work - the Mage Eye re-lights it from its own
--                     0.5s server loop, so a per-tick SetActive(false) just flickers. This is a
--                     one-shot property the loop has no opinion about.
--   opts.Restore      put the ORIGINAL damage back (stashed on the first Tune)
function Lasers.Tune(target, opts)
    local comp = Lasers.Of(target)
    if not comp then return end
    opts = opts or {}

    local ok, key = pcall(function() return comp:GetFullName() end)
    if not ok or not key then return end

    if opts.Restore then
        pcall(function() comp.LaserDamage = damageBase[key] or 5 end)
        pcall(function() comp.FriendlyFireEnabled = true end)
        damageBase[key] = nil
        return
    end

    if damageBase[key] == nil then
        local d
        pcall(function() d = comp.LaserDamage end)
        damageBase[key] = d
    end

    pcall(function() comp.LaserDamage = opts.Damage or 0 end)
    -- Belt-and-braces: ProcessLaserHit's FriendlyFireEnabled branch is goto-flattened in the
    -- decompile and genuinely ambiguous. LaserDamage = 0 is what we trust.
    pcall(function() comp.FriendlyFireEnabled = false end)
    if opts.Bounces ~= nil then pcall(function() comp.MaxLaserBounces = opts.Bounces end) end
    if opts.MaxDistance ~= nil then pcall(function() comp.LaserMaxDistance = opts.MaxDistance end) end
end


-- Drop an actor's stashed damage (call from OnDeath, so the table can't grow forever).
function Lasers.Forget(target)
    local comp = Lasers.Of(target)
    if not comp then return end
    pcall(function() damageBase[comp:GetFullName()] = nil end)
end


-- [RENDERER] Silence a beam. Three sources, all client-side - on a host, IsServer is true in
-- OnRep_LaserActive so the sound branch never runs, and this only matters to a pure client:
--   * LaserComponent.EmitterAudio  - s_laser_emit_loop, the emitter hum
--   * LaserComponent.LaserHitAudio - s_laser_hit_hiss_loop, the hiss where the beam lands
--   * NPC_MageEye.Audio_LaserLoop  - the eye's own loop (StartLaserBeamLoop, on LaserFX_Start)
-- NoEmitterSound kills the first at source; the other two are spawned dynamically by ToggleSounds,
-- so we mute the components. Not latchable - ToggleSounds destroys and re-spawns them on every
-- toggle, so a cached handle silently stops muting. Call it on tick while the beam is up.
function Lasers.Mute(target)
    local comp = Lasers.Of(target)
    if not comp then return end

    pcall(function() comp.NoEmitterSound = true end)
    pcall(function()
        local a = comp.EmitterAudio
        if IsValid(a) then a:SetVolumeMultiplier(0) end
    end)
    pcall(function()
        local a = comp.LaserHitAudio
        if IsValid(a) then a:SetVolumeMultiplier(0) end
    end)
    -- The eye's own loop lives on the ACTOR, not the component.
    pcall(function()
        local a = target.Audio_LaserLoop
        if IsValid(a) then a:SetVolumeMultiplier(0) end
    end)
end


-- =======================================================================
-- TRACE INTERVAL - the knob behind "the beam looks choppy". The component's TraceInterval
-- (default 0.2) drives the TickLaserTrace timer, whose trace writes the replicated LaserEnd.
--   * The beam is drawn to LaserEnd, not along the rotation - a re-aim shows nothing until the
--     next trace. Steering at 10 Hz over 0.2s = a 5 Hz staircase lagging up to 200ms.
--   * Read once, at timer creation, so set it before activation (FireBurst's opts.TraceInterval).
--     A write to a live beam does nothing until re-activation.
--   * It also scales native damage (TickLaserTrace both traces and applies point damage), so
--     halving the interval doubles DPS. Free on a Damage=0 beam; otherwise re-tune LaserDamage.
-- =======================================================================
function Lasers.SetTraceInterval(target, seconds)
    local comp = Lasers.Of(target)
    if not comp then return end
    pcall(function() comp.TraceInterval = seconds end)
end


-- =======================================================================
-- SweptBeamHits - who did this beam actually cross? A steered beam is a 3D segment from its origin
-- (the emitter bone, barely moving) to its impact point (which sweeps). Over one step the impact
-- travels p0 -> p1, so the beam sweeps the triangle (origin, p0, p1); anything within `radius` of
-- it was in the beam. Three ways this was wrong in the Deatomizer:
--   * Testing only the impact point ignores everyone standing in the beam between emitter and
--     ground - most of what a waist-height beam passes through.
--   * Testing only the endpoint (not the p0->p1 segment) tunnels: at 3000 u/s a 100ms step moves
--     300 units, so a target inside a 150 radius falls between samples.
--   * Testing in XY only hits people on the floor above.
-- So: sub-sample along p0 -> p1 at spacing <= radius, and per sample take the true 3D
-- point-to-segment distance from victim to beam. A handful of dot products per victim, no traces.
--
-- Pure geometry - no line-of-sight check, so it "hits" through a wall. Pass the beam's real impact
-- point as p0/p1 and the native trace (which is what LaserEnd is) has already bounded it.
--
-- opts:
--   Players   (default true)  include players
--   Npcs      (default false) include NPCs (a SphereOverlap around the beam - see GetNearbyNpcs)
--   Ignore    array of actors to skip (always pass the carrier - it sits at the beam's origin)
--   Skip      fn(actor) -> true to skip (e.g. a per-sweep once-only set)
-- Returns an array of actors; nearest-first is not guaranteed (order is players then NPCs).
-- =======================================================================

local function dist3(a, b)
    local dx, dy, dz = b.X - a.X, b.Y - a.Y, b.Z - a.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Squared distance from point P to the 3D segment A->B. Standard clamp-the-projection form.
local function segDistSq3D(p, a, b)
    local abx, aby, abz = b.X - a.X, b.Y - a.Y, b.Z - a.Z
    local len2 = abx * abx + aby * aby + abz * abz
    local t = 0
    if len2 > 0 then
        t = ((p.X - a.X) * abx + (p.Y - a.Y) * aby + (p.Z - a.Z) * abz) / len2
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local dx = p.X - (a.X + abx * t)
    local dy = p.Y - (a.Y + aby * t)
    local dz = p.Z - (a.Z + abz * t)
    return dx * dx + dy * dy + dz * dz
end

-- Was `loc` within `radius` of the beam swept from origin->p0 to origin->p1 this step?
local MAX_SUBSAMPLES = 8
local function inSweptBeam(loc, origin, p0, p1, radius, r2)
    local dx, dy, dz = p1.X - p0.X, p1.Y - p0.Y, p1.Z - p0.Z
    local travel = math.sqrt(dx * dx + dy * dy + dz * dz)

    -- Spacing <= radius means a victim can never slip between two sampled beams.
    local n = math.ceil(travel / math.max(radius, 1))
    if n < 1 then n = 1 elseif n > MAX_SUBSAMPLES then n = MAX_SUBSAMPLES end

    for s = 0, n do
        local t = s / n
        local at = FVector(p0.X + dx * t, p0.Y + dy * t, p0.Z + dz * t)
        if segDistSq3D(loc, origin, at) <= r2 then return true end
    end
    return false
end

function Lasers.SweptBeamHits(origin, p0, p1, radius, opts)
    opts = opts or {}
    if not origin or not p0 or not p1 then return {} end

    local r2 = radius * radius
    local skip = {}
    for _, a in ipairs(opts.Ignore or {}) do
        local k = Utils.IsActorValid(a) and Utils.ActorKey(a)
        if k then skip[k] = true end
    end

    local hits = {}
    local function test(victim)
        if Utils.IsActorInvalid(victim) then return end
        local key = Utils.ActorKey(victim)
        if not key or skip[key] then return end
        if opts.Skip and opts.Skip(victim) then return end

        local vl
        pcall(function() vl = victim:K2_GetActorLocation() end)
        if not vl then return end

        if inSweptBeam(vl, origin, p0, p1, radius, r2) then
            skip[key] = true          -- never return the same actor twice from one call
            hits[#hits + 1] = victim
        end
    end

    if opts.Players ~= false then
        -- The GameState's player array, not FindAllOf (see [[anteup2-microlag-and-profiler]]).
        local gs = STATE.GameState
        local players = IsValid(gs) and gs.PlayerCharacterInGame
        if players then
            for i = 1, #players do test(players[i]) end
        end
    end

    if opts.Npcs then
        -- One SphereOverlap bounding the whole swept beam: centred midway to the farther impact
        -- point, sized to reach both ends. GetNearbyNpcs already filters to living NPCs.
        -- Lazy require - AVUtils is heavy and this is its only use here.
        local AVU = require("AnteUtils.AVUtils")
        local far = (dist3(origin, p1) > dist3(origin, p0)) and p1 or p0
        local mid = FVector((origin.X + far.X) * 0.5, (origin.Y + far.Y) * 0.5, (origin.Z + far.Z) * 0.5)
        for _, npc in ipairs(AVU.GetNearbyNpcs(mid, dist3(mid, far) + radius) or {}) do
            test(npc)
        end
    end

    return hits
end


-- =======================================================================
-- SteeredSweep - the shared "steered beam channel" engine (the Deatomizer's ground sweep and the
-- Beholder eye's chase beam are both this machine). The impact POINT crawls at constant speed
-- toward whatever cfg.Heading returns; each step re-aims the component and hands everything the
-- beam SWEPT (the origin->prev->pt triangle, via SweptBeamHits) to cfg.OnHit.
--   * The engine owns: the WorkQueue step loop, clock, constant-speed advance, re-aim, the swept
--     hit test, and a finish-once funnel.
--   * The caller owns: heading/lock geometry, damage, sounds, stance, beam creation + teardown.
--
-- cfg:
--   From (FVector)   - initial impact point (required)
--   Speed (cm/s), Radius (beam thickness), MaxMs (hard lifetime cap) - required
--   StepMs           - cadence (default 100)
--   ElapsedMs        - clock seed; the Deatomizer charges its telegraph hold to the lock budget
--   FirstDelayMs     - delay before the FIRST step (the telegraph hold; default StepMs)
--   Heading(st)      - FVector to crawl toward this step, or nil to finish. Lock logic lives here
--                      (return the locked end once committed).
--   Arrive (bool)    - true: finish on reaching the heading (locked-line sweeps). false: snap to
--                      it and keep channeling (chase beams).
--   Hits             - { Npcs?, Players?, Skip(victim) } SweptBeamHits opts. The actor is always
--                      ignored; Players defaults ON, pass false for a beam that must spare them.
--   OnHit(victim, st)- per victim caught this step (dedupe via Hits.Skip + caller state).
--   OnStep(st, pt)   - optional per-step extra (move a loop SFX, turn the actor).
--   OnFinish(st, reason) - cleanup funnel, exactly once ("dead"/"comp"/"timeout"/"arrived"/
--                      "no-heading", or a caller reason via st.Finish).
--
-- Returns st: { x, y, z, elapsed, Finish(reason) } - callers stash their own fields on it.
-- =======================================================================
function Lasers.SteeredSweep(actor, comp, cfg)
    local st = { x = cfg.From.X, y = cfg.From.Y, z = cfg.From.Z, elapsed = cfg.ElapsedMs or 0 }
    local stepMs = cfg.StepMs or 100
    local km = ASSETS.GetIfValid("/Script/Engine.Default__KismetMathLibrary")

    local finished = false
    local function finish(reason)
        if finished then return end
        finished = true
        if cfg.OnFinish then pcall(cfg.OnFinish, st, reason) end
    end
    st.Finish = finish

    local function step()
        if Utils.IsActorInvalid(actor) or Utils.IsDeadSafe(actor) then finish("dead"); return end
        if not Utils.IsComponentValid(comp) then finish("comp"); return end
        st.elapsed = st.elapsed + stepMs
        if st.elapsed > cfg.MaxMs then finish("timeout"); return end

        local dest = cfg.Heading(st)
        if finished then return end                    -- Heading may call st.Finish itself
        if not dest then finish("no-heading"); return end

        local stepLen = cfg.Speed * stepMs / 1000
        local dx, dy, dz = dest.X - st.x, dest.Y - st.y, dest.Z - st.z
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if cfg.Arrive and d <= stepLen then finish("arrived"); return end

        -- Impact point before and after this step - the beam swept between the two.
        local prev = FVector(st.x, st.y, st.z)
        if d > stepLen and d > 1 then
            st.x = st.x + dx / d * stepLen
            st.y = st.y + dy / d * stepLen
            st.z = st.z + dz / d * stepLen
        else
            st.x, st.y, st.z = dest.X, dest.Y, dest.Z
        end
        local pt = FVector(st.x, st.y, st.z)

        -- Re-aim at the new point (one rotation set). The emitter's world position is the beam
        -- segment's origin, which the hit test needs.
        local eye
        pcall(function()
            eye = comp:K2_GetComponentLocation()
            if km and eye then
                comp:K2_SetWorldRotation(km:FindLookAtRotation(eye, pt), false, {}, false)
            end
        end)

        if cfg.OnStep then pcall(cfg.OnStep, st, pt) end

        if eye and cfg.OnHit then
            local victims = Lasers.SweptBeamHits(eye, prev, pt, cfg.Radius, {
                Npcs = cfg.Hits and cfg.Hits.Npcs,
                -- Players defaults to on in SweptBeamHits (`~= false`), so nil here keeps every
                -- existing caller's behaviour; only an explicit false opts out. A pet sweep needs
                -- that - it must never catch its own owner.
                Players = cfg.Hits and cfg.Hits.Players,
                Ignore = { actor },
                Skip = cfg.Hits and cfg.Hits.Skip,
            })
            for _, victim in ipairs(victims) do
                pcall(cfg.OnHit, victim, st)
            end
        end

        Utils.QueueWork(step, stepMs)
    end

    Utils.QueueWork(step, cfg.FirstDelayMs or stepMs)
    return st
end


-- Point a beam's FORWARD at a world location.
--   * Must be re-applied at ACTIVATION, not just at creation: the component is welded to its
--     emitter bone, so a world rotation is stored relative to that bone and turns with it, while
--     LaserTrace fires from whatever transform the component has at the moment it traces. On a
--     moving emitter - an arm mid-swing - the two are a drain tick and a whole swing apart.
local function aimBeamAt(comp, aimAt)
    local km = ASSETS.GetIfValid("/Script/Engine.Default__KismetMathLibrary")
    if not km then return end
    local from = comp:K2_GetComponentLocation()
    if not from then return end
    comp:K2_SetWorldRotation(km:FindLookAtRotation(from, aimAt), false, {}, false)
end


-- =======================================================================
-- FireBurst - build N throwaway ULaserComponents on an actor's mesh, fire them, tear them down.
-- The module's other half: for an NPC that does not own a laser (Laser Pest, the Containment Bot's
-- hand, the Deatomizer sweep) we bolt beams on for the duration of an attack.
--   * The component ticks server-side and damages every TRACE_INTERVAL_MS.
--   * The carrier should be laser-immune, or it shoots itself.
--   * Returns the components so a caller can steer one mid-life (the Deatomizer re-aims made[1]
--     each step). Teardown at `duration` is still owned here.
--
-- opts: Count (6), Damage (8), Duration ms (5000), MaxDistance (4000), PitchMin/Max, Spread
--       (FVector half-extents on the origin), Location (bone-relative origin), AimAt (world loc -
--       a single aimed beam), SideBias / SideSpread / YawOffset (aim shaping), Stagger (true),
--       Style (overrides def.LaserStyle), Color (legacy { enum, FLinearColor } pair),
--       TraceInterval (seconds; default native 0.2 - lower it for a STEERED beam, see above).
-- =======================================================================
function Lasers.FireBurst(actor, bone, opts)
    opts = opts or {}
    if Utils.IsActorInvalid(actor) then return end

    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return end

    local cls = ASSETS.GetIfValid(ENUMS.LaserComponent)
    if IsNotValid(cls) then LogBad("Lasers.FireBurst - LaserComponent class not loaded"); return end

    local count       = opts.Count or 6
    local damage      = opts.Damage or 8
    local duration    = opts.Duration or 5000
    local maxDistance = opts.MaxDistance or 4000
    local pitchMin    = opts.PitchMin or -10
    local pitchMax    = opts.PitchMax or 70

    -- One style for the whole burst (ResolveStyle). Lasers.RANDOM or nil falls through to the
    -- per-beam palette roll below, which keeps the Laser Pest's beams individually coloured.
    local burstStyle = Lasers.ResolveStyle(actor, opts.Style)

    -- We do not set actor.Instigator: it's a TWeakObjectPtr, which UE4SS can't assign from Lua, so
    -- the write silently fails and used to spam the log per beam. Unnecessary too - LaserTrace has
    -- a nullptr-instigator branch, so beams still damage (attributed via DamageCauser).
    local spread = opts.Spread
    local baseLoc = opts.Location or FVector()

    -- SideBias: fire out the two perpendicular sides of the actor's facing instead of an even 360
    -- spread, off the actor (capsule) yaw, which points along the leap even while the mesh
    -- somersaults. YawOffset: every beam at a fixed yaw - deterministic, so a caller can fire one
    -- explicitly left (-90) and one right (+90).
    local actorYaw, sideFlip
    if opts.SideBias or opts.YawOffset then
        pcall(function() actorYaw = actor:K2_GetActorRotation().Yaw end)
        actorYaw = actorYaw or 0
        sideFlip = math.random(0, 1)   -- randomize which flank gets the extra beam (odd counts)
    end

    -- Phase consecutive beams' trace timers across one interval, so the group samples ~count x
    -- denser in time (a fast target is less likely to slip every beam's 0.2s gap).
    local staggerStep = (opts.Stagger ~= false) and (Lasers.TRACE_INTERVAL_MS / count) or 0

    -- Dispatch for the per-beam activation below - named here so a freeze label tells the truth.
    local dedicated = STATE.Role == "DEDICATED"
    local mode = dedicated and "EIGT" or "WQ"

    -- Hang trace (reuses DEBUG_SPAWN_TRACE): brackets the synchronous creation loop, where each
    -- beam's AddComponentByClass / OnRep_LaserActive can blocking-load the beam FX in-drain (S2).
    -- A freeze here logs "laserburst-> N" with no matching "laserburst<-".
    LogDebug("Lasers.FireBurst-> " .. tostring(count) .. " beams", SETTINGS.DEBUG_SPAWN_TRACE)

    local made = {}
    for i = 1, count do
        local ok, comp = pcall(function()
            return actor:AddComponentByClass(cls, false, FTransform(), false)
        end)
        if ok and comp and Utils.IsComponentValid(comp) then
            pcall(function()
                comp:K2_AttachToComponent(mesh, FName(bone or "head"), 0, 0, 0, true)

                -- Origin: relative to the bone (with optional scatter)...
                local loc = baseLoc
                if spread then
                    loc = FVector(
                        baseLoc.X + math.random(-spread.X, spread.X),
                        baseLoc.Y + math.random(-spread.Y, spread.Y),
                        baseLoc.Z + math.random(-spread.Z, spread.Z))
                end
                local hit = {}
                comp:K2_SetRelativeLocation(loc, false, hit, false)

                -- ...but aim in world space. A rotation relative to the bone follows the bone's
                -- forward axis - sideways on the pest, so every beam fanned out one flank. World
                -- aim sprays evenly regardless of bone orientation.
                if opts.AimAt then
                    aimBeamAt(comp, opts.AimAt)   -- provisional; activate() re-aims for real
                else
                    -- Average-of-two (triangular) roll, so beams cluster toward the middle of
                    -- [pitchMin,pitchMax]. Centre that range near horizontal to bias hits.
                    local pitch = (math.random(pitchMin, pitchMax) + math.random(pitchMin, pitchMax)) * 0.5
                    local yaw
                    if opts.YawOffset then
                        local sp = opts.SideSpread or 0
                        yaw = actorYaw + opts.YawOffset + math.random(-sp, sp)
                    elseif opts.SideBias then
                        -- Alternate by index so beams always split left/right - independent random
                        -- picks could land them all on one flank.
                        local side = ((i + sideFlip) % 2 == 0) and 90 or -90
                        local sp = opts.SideSpread or 35
                        yaw = actorYaw + side + math.random(-sp, sp)
                    else
                        yaw = math.random(0, 359)
                    end
                    comp:K2_SetWorldRotation(FRotator(pitch, yaw, 0), false, hit, false)
                end

                -- Beam style. Everything shared with the client end was resolved once into
                -- burstStyle above, and ClientVisuals' OnRep hook runs the same resolver, so a
                -- joined client paints an identical beam though none of it replicates. Per beam:
                --   * Lasers.RANDOM - opted out of the forced colour: re-roll every beam
                --   * nothing declared - opts.Color (legacy { enum, FLinearColor }), else random
                local style = burstStyle
                if style == Lasers.RANDOM then
                    style = Lasers.RandomStyle()
                elseif not style then
                    if opts.Color then
                        style = { Color = opts.Color[1], Tint = opts.Color[2] }
                    else
                        style = Lasers.RandomStyle()
                    end
                end
                Lasers.SetStyle(comp, style)

                comp.LaserDamage = damage
                comp.LaserMaxDistance = maxDistance

                -- Re-trace cadence (see Lasers.SetTraceInterval above: read once at creation, set
                -- before activate(), scales native damage). Its users (the Deatomizer sweep) run
                -- Damage = 0 and script their own hits.
                if opts.TraceInterval then
                    pcall(function() comp.TraceInterval = opts.TraceInterval end)
                end

                -- Activate. The server never auto-fires OnRep, so without this manual call the
                -- beam never appears and never damages. Staggered per beam so trace timers start
                -- out of phase; guarded since the actor can die before a late phase lands.
                --
                -- Never inline this, not even for beam 1. OnRep_LaserActive is by far the heaviest
                -- call here (adds a NiagaraComponent, SetAssets, swaps a material, spawns two
                -- looping sounds), so running it inside this creation loop packs N of those into one
                -- WorkQueue drain pass alongside N AddComponentByClass calls - the freeze shape S2
                -- warns about. Giving each beam its own pass fixed that.
                --
                -- The activation also TRACES immediately, and a kill on that trace wedges the
                -- drain - lightBeam disarms it on every role. The dedicated hop stays as a second
                -- layer; a renderer host can't take it (an EIGT can flush mid widget paint).
                local cc = comp
                local function activate()
                    if not Utils.IsComponentValid(cc) then return end
                    STATE.LastWork = mode .. " laser-activate"
                    STATE.LastWorkDone = false
                    -- Re-aim BEFORE the flag: OnRep_LaserActive traces immediately, and that trace
                    -- is what sets LaserEnd (the beam is drawn to LaserEnd, not along the
                    -- rotation). See aimBeamAt for why the creation-time aim is already stale.
                    if opts.AimAt then pcall(aimBeamAt, cc, opts.AimAt) end
                    lightBeam(cc, damage)
                    STATE.LastWorkDone = true
                end
                local phase = staggerStep * (i - 1)
                if phase < ACTIVATE_MIN_MS then phase = ACTIVATE_MIN_MS end
                if dedicated then
                    Utils.DelayedGameThread(phase, activate)
                else
                    Utils.QueueWork(activate, phase)
                end
            end)
            made[#made + 1] = comp
        end
    end

    LogDebug("Lasers.FireBurst<- " .. tostring(#made) .. " made", SETTINGS.DEBUG_SPAWN_TRACE)

    -- Teardown in two phases - do not collapse them.
    --   1. At `duration`: deactivate (false + dirty + OnRep). Stops the server's trace timer and
    --      replicates the `false`, so each client's OnRep_LaserActive frees its own beam Niagara.
    --      Only the machine that created a beam can clean it.
    --   2. ~400ms later: destroy the server-side components, once clients have had the `false`.
    --      The old single-phase version destroyed in the same tick it marked dirty, so the update
    --      never left before the channel closed and client beams persisted forever.
    Utils.QueueWork(function()
        for _, c in ipairs(made) do
            if Utils.IsComponentValid(c) then
                pcall(function() c.LaserActive = false end)
                pcall(function() Utils.MarkReplicatedDirty(c, "LaserActive") end)
                pcall(function() c:OnRep_LaserActive() end)
            end
        end

        Utils.QueueWork(function()
            for _, c in ipairs(made) do
                if Utils.IsComponentValid(c) then
                    -- The laser's own ReceiveEndPlay only frees LaserEndComponent, so the beam
                    -- Niagara (added to the owner) would pile up server-side on every burst.
                    pcall(function()
                        local ng = c.NiagaraComponent
                        if IsValid(ng) then ng:K2_DestroyComponent(ng) end
                    end)
                    pcall(function()
                        local le = c.LaserEndComponent
                        if IsValid(le) then le:K2_DestroyComponent(le) end
                    end)
                    pcall(function() c:K2_DestroyComponent(c) end)
                end
            end
        end, 400)
    end, duration)

    return made
end


return Lasers
