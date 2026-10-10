-- =======================================================================
-- ClientFX (FX) - getting a visual effect onto every machine.
-- Split out of AVUtils, re-exported onto AVU: callers write AVU.SendClientFX / BroadcastFX / etc.
-- Deep dive on specific hazards: AnNotes/AnteSystems/ClientFX.md.
--
-- Niagara does NOT replicate and Lua cannot define an RPC, so there are exactly FOUR paths. Pick
-- the wrong one and the FX works in SP and renders nothing on a dedicated server:
--   1. Utils.CreateEffect - replicated ACTOR, but its ParticleEffect prop does NOT replicate, so
--      remotes get the BP's default burst ([[anteup2-replicated-fx]]).
--   2. FX.BroadcastFX - GameState multicast, takes the Niagara as a parameter so it really plays
--      everywhere. ONE-SHOTS ONLY: spawns with bAutoDestroy, which never fires for a LOOPING
--      system - that would hang forever with no handle to close it.
--   3. FX.SendClientFX / SendClientBeam - the chat side-channel (below). Server pushes a
--      DESCRIPTION; each renderer spawns and frees its own component. Handles looping systems,
--      real lifetimes, beams, per-entry params. FX.StopClientFX closes one on demand.
--   4. FX.PlaySound2DAll - SOUND ONLY, and not ours at all: Client_Play2DSoundEffect, the game's
--      own per-player NetClient RPC. Non-positional, fixed volume.
--
-- Rule of thumb: finite one-shot -> BroadcastFX. Looping / real lifetime / beam -> SendClientFX.
-- A cue that must be HEARD rather than located, with no visual -> PlaySound2DAll.
--
-- THE WIRE FORMAT lives here and nowhere else - packFX + FX.DecodeFrames are two halves of one codec.
-- ClientEffects owns the RPC hook and the playback but decodes through FX.DecodeFrames, so the format
-- changes in one place. The registry (index -> asset/sound/params) is AnteEnums.ClientFX.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local UEHelpers = require("UEHelpers")
local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local ASSETS = require("AnteCore.AssetManager")
local NET = require("AnteCore.NetChannel")
local Utils = require("AnteUtils.Utils")
local ENUMS = require("AnteData.Enums")
local LogBad = Utils.LogBad

---@class AVU.ClientFX        -- merged onto AVU (see AVUtils' SUBMODULE MERGE)
local FX = {}


-- =======================================================================
-- SpawnLocalNiagara - a CLIENT-LOCAL (non-replicated) Niagara system at a world location.
-- The renderer-side counterpart to Utils.CreateEffect: it renders only on THIS machine, so the
-- dedicated replication gap (remotes get the BP's default yellow portal) doesn't apply.
--   * Caller must be a renderer; ClientEffects drives it off the pushed effects below.
--   * The system must be RESIDENT (GetIfValid is non-loading) - LoadAsync it first.
--   * opts: Scale, Rotation, Lifetime (ms -> Deactivate then free), FloatParams, Vec2Params,
--     Vec3Params, ColorParams, NoCull (render at ANY range - see the block at the Activate call;
--     set-piece portals only, it defeats every distance cull the engine has).
-- =======================================================================

local NIAGARA_FUNC_LIB = "/Script/Niagara.Default__NiagaraFunctionLibrary"
-- Backstop lifetime when the caller passes none, so a LOOPING system can't leak its component
-- forever. Generous; anything wanting longer passes Lifetime.
local DEFAULT_NIAGARA_LIFETIME_MS = 12000

-- The PreviewMaxDistance handed to SetPreviewLODDistance (see the NoCull block). Only the LOD
-- FRACTION is derived from it; the cull decision reads the forced distance of 0, so this just has
-- to be comfortably larger than any range we care about.
local NOCULL_LOD_MAX_UU = 200000

-- =======================================================================
-- TEARDOWN BOOK - object path -> { gen, comp } for the teardown chain that OWNS that component.
-- Lets a lifetime be EXTENDED (FX.KeepAlive) with no two owners racing to free one component - the
-- crash this file already fought ([[anteup2-clientfx-teardown-uaf]]). Re-arming bumps the
-- generation; the superseded chain sees the mismatch and returns, so exactly one chain frees.
-- Without it, a heartbeat-held effect (the Night Realm door) spawned a WHOLE NEW system every beat
-- over the live one instead of reusing it. Now a beat on a live component is a table write, and a
-- machine that missed the first send still spawns on its next beat.
--
-- The book holds the wrapper; nothing here re-resolves by path - a deliberate, bounded exception to
-- CLAUDE.md S3, and the one place in this file that takes it. Why it's sound:
--   1. The re-resolve was never the fix for the earlier client AVs. Those were `bAutoDestroy=true`
--      at spawn plus a scheduled destroy - two owners, engine frees first, our destroy lands on the
--      corpse. The fix was `bAutoDestroy=false` (sole ownership); `ResolveByPath` was only
--      belt-and-braces on top.
--   2. The belt-and-braces became the bigger risk. Every resolve is a full UObject-array walk, and
--      one that trips a dangling Outer is the uncatchable AV in
--      [[anteup2-ue4ss-findobject-scan-crash]]. This site was the mod's top repeating lookup and its
--      single largest hitch source - guarding a UAF with the scan that causes that crash family is a
--      bad trade.
--   3. The book is already the ownership record: `driftComponent` below has shipped for months
--      holding a captured wrapper across frames on this same argument. The teardown has strictly
--      better standing than the drift chain - it IS the owner, not a passenger.
-- What must stay true for this to hold - all four, or put the resolve back:
--   a. Components enter the book ONLY from SpawnLocalNiagara, with `bAutoDestroy=false`, so for the
--      whole life of the entry we are the only thing that can free it.
--   b. Whoever frees or hands off ownership clears its entry in the same breath (teardown below,
--      FX.Forget, FX.ResetBook).
--   c. World teardown drops the book - `Utils.ResetState` calls FX.ResetBook. StopMod wiping the
--      WorkQueue kills the pending chains, but the table outlives the world, and a wrapper surviving
--      into the next one IS the freed cross-world pointer S3 warns about (same reason ASSETS.Immortal
--      and the singleton cache are cleared there).
--   d. Nothing outside this file reads `comp` out of the book.
-- =======================================================================
local fxBook = {}

-- [RENDERER] Drop the whole book. Called from Utils.ResetState on world teardown - see (c) above.
function FX.ResetBook()
    fxBook = {}
end

local function scheduleTeardown(path, comp, ms, hardFree)
    if not path then return end
    local e = fxBook[path]
    local gen = ((e and e.gen) or 0) + 1
    -- A KeepAlive re-arm passes no component (or hardFree): keep what is already booked.
    fxBook[path] = {
        gen = gen,
        comp = comp or (e and e.comp),
        hardFree = hardFree or (e and e.hardFree),
    }

    -- ONE ITEM, NO LOOKUP. Which of two things happens depends on whether the system is still
    -- running:
    --   STILL ACTIVE (looping, or finite still emitting) - Deactivate() stops emitters and lets
    --     live particles finish; bAutoDestroy then hands the free to the engine's completion
    --     callback. SetAutoDestroy BEFORE Deactivate: the flag is read by OnSystemComplete, which
    --     can fire inside Deactivate itself. This is also how a LOOPING system gets terminated.
    --   ALREADY COMPLETE (the common one-shot case) - no completion left to fire, so an
    --     auto-destroy handoff would leak it forever; destroy right here instead.
    -- Exactly ONE owner frees the component at every instant - the invariant
    -- [[anteup2-clientfx-teardown-uaf]] cost us. hardFree is only ever set here, at the moment we
    -- give ownership up, which is also why the entry drops on the SAME line, not after.
    Utils.QueueWork(function()
        local cur = fxBook[path]
        if not cur or cur.gen ~= gen then return end   -- a KeepAlive re-armed it, or the book reset
        local c = cur.comp
        fxBook[path] = nil                             -- ours now; nothing else may touch it
        if IsNotValid(c) then return end

        local active = false
        pcall(function() active = c:IsActive() end)

        -- HARD FREE (NoCull components): Deactivate, then free it OURSELVES, never handing off to
        -- bAutoDestroy. The graceful branch above is a HANDOFF that only frees on COMPLETION, and a
        -- NoCull component is scalability-exempt so it may never reach one - culling used to be
        -- what finished these off, and exempting it left an arrival portal stuck on screen forever.
        -- Still exactly ONE owner at every instant, so this cannot reintroduce
        -- [[anteup2-clientfx-teardown-uaf]]. Cost is the particle fade on a forced close.
        -- Read off the BOOK ENTRY, not the parameter: a KeepAlive re-arm passes hardFree=nil and
        -- the entry is what carries the original spawn's answer forward.
        if cur.hardFree then
            pcall(function() c:Deactivate() end)
            pcall(function() c:K2_DestroyComponent(c) end)
        elseif active then
            pcall(function() c:SetAutoDestroy(true) end)
            pcall(function() c:Deactivate() end)
        else
            pcall(function() c:K2_DestroyComponent(c) end)
        end
    end, ms)
end

-- [RENDERER] Drop a path from the teardown book WITHOUT freeing anything. For a caller that is
-- taking ownership of the component itself (ClientEffects' early STOP), so the generation stops
-- matching and every chain still holding that path - the teardown AND any drift below - bails
-- instead of touching a component somebody else is about to free.
function FX.Forget(path)
    if path then fxBook[path] = nil end
end

-- [RENDERER] Slide a live component from `from` to `to` over `ms`, so it reads as MOVING rather
-- than a decal hanging in the air (the GK portal's warp-gate drift).
--
-- Captures the wrapper instead of re-resolving, riding the teardown book's generation as its
-- single-owner record (see fxBook above): a superseded/forgotten/reset book entry stops the chain,
-- and FX.ResetBook is scheduled before the teardown drain so the wrapper can't outlive its owner.
-- Nothing outside this file may capture a component across frames.
--
-- Step count is spaced by DISTANCE, not by a fixed clock tick - a fixed 100ms-forever version could
-- queue far more steps than the eye could see for a short, slow drift. The interval now stretches
-- to fill the lifetime instead, capped at DRIFT_MAX_STEPS.
local DRIFT_MIN_STEP_UU = 5     -- don't queue a step for less movement than this
local DRIFT_MIN_STEP_MS = 100   -- ...and never faster than the drain (steps are 10Hz work items)
local DRIFT_MAX_STEPS = 120

local function driftComponent(comp, path, from, to, ms)
    if not path or not fxBook[path] then return end
    local gen = fxBook[path].gen

    local dx, dy, dz = (to.X or 0) - (from.X or 0), (to.Y or 0) - (from.Y or 0), (to.Z or 0) - (from.Z or 0)
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)

    -- Stop one step short of the teardown; a step landing on the same drain as the free is the
    -- exact race [[anteup2-clientfx-teardown-uaf]] cost us - so the time budget is one step short
    -- and the interval divides THAT.
    local budget = ms - DRIFT_MIN_STEP_MS
    local steps = math.floor(dist / DRIFT_MIN_STEP_UU)
    steps = math.min(steps, DRIFT_MAX_STEPS, math.floor(budget / DRIFT_MIN_STEP_MS))
    if steps < 1 then return end

    local stepMs = math.max(DRIFT_MIN_STEP_MS, math.floor(budget / steps))

    local function step(i)
        local cur = fxBook[path]
        if not cur or cur.gen ~= gen then return end   -- superseded, stopped, or already torn down
        local t = i / steps
        pcall(function()
            -- Out-param UFunction: the FHitResult table is NOT optional. Omitting it makes the
            -- whole call a silent no-op (CLAUDE.md S3).
            comp:K2_SetWorldLocation(
                FVector((from.X or 0) + dx * t, (from.Y or 0) + dy * t, (from.Z or 0) + dz * t),
                false, {}, true)
        end)
        if i < steps then Utils.QueueWork(function() step(i + 1) end, stepMs) end
    end

    Utils.QueueWork(function() step(1) end, stepMs)
end

-- [RENDERER] Push a live component's teardown out to `ms` from now. Takes a wrapper or an object
-- path. Returns true if it took; false means nothing to re-arm (never spawned here, or already
-- freed) and the caller should spawn instead.
function FX.KeepAlive(comp, ms)
    local path = type(comp) == "string" and comp or Utils.ObjectPath(comp)
    if not path then return false end
    -- The BOOK is the wrapper, not a lookup - this runs on a HEARTBEAT (every beat, for as long as
    -- an event holds its portal/door open), so it was one full UObject-array walk per beat forever.
    local e = fxBook[path]
    if not e then return false end
    local c = e.comp
    if IsNotValid(c) then fxBook[path] = nil return false end

    -- Re-Activate, bReset=FALSE: a no-op on an already-running system (a reset would restart the
    -- sim and pop). Matters for a FINITE system that quietly ran to completion inside its own
    -- lifetime - still there, still ours, but dormant; without this a re-arm keeps reviving an
    -- invisible ghost that never visibly comes back.
    -- A beat arriving mid-teardown finds no book entry (dropped in the same step that hands the
    -- component over), returns false, and the caller spawns fresh instead of reviving a freed one.
    pcall(function() c:Activate(false) end)

    -- nil component: keep the one already booked (this IS that component's owner re-arming).
    scheduleTeardown(path, nil, ms or DEFAULT_NIAGARA_LIFETIME_MS)
    return true
end

-- How many components the teardown book currently owns - read by /fxcount. A healthy number is
-- small (a handful of live effects); a large one means scheduled teardowns are not draining.
function FX.BookCount()
    local n = 0
    for _ in pairs(fxBook) do n = n + 1 end
    return n
end

function FX.SpawnLocalNiagara(location, niagaraPath, opts)
    opts = opts or {}
    if not location then return nil end

    local sys = ASSETS.GetIfValid(niagaraPath)
    if IsNotValid(sys) then return nil end
    local lib = ASSETS.GetIfValid(NIAGARA_FUNC_LIB)
    local world = Utils.GetWorld()
    if not lib or IsNotValid(lib) or IsNotValid(world) then return nil end

    local comp
    pcall(function()
        -- (WorldContext, System, Location, Rotation, Scale, bAutoDestroy,
        --  bAutoActivate, PoolingMethod, bPreCullCheck)
        -- bAutoDestroy=FALSE: the scheduled teardown below must be the component's ONLY owner, or a
        -- delayed destroy can land on a wrapper the engine already freed
        -- ([[anteup2-clientfx-teardown-uaf]] - IsValid lies after slot reuse, not pcall-catchable).
        -- bPreCullCheck=FALSE: TRUE can hand back a valid but DORMANT (pre-culled) component that
        -- renders nothing - we force-Activate ourselves below instead, same as the game's own FX
        -- zones do.
        -- bAutoActivate=FALSE ONLY under NoCull: a component registers with the scalability manager
        -- at Activate(), reading bAllowScalability at that instant - nothing later can un-register
        -- it once that's happened. So NoCull defers activation to Activate(true) below, AFTER the
        -- flag is cleared. See AnNotes/AnteSystems/ClientFX.md for the full NoCull decode.
        comp = lib:SpawnSystemAtLocation(world, sys, location,
            opts.Rotation or FRotator(0, 0, 0), opts.Scale or FVector(1, 1, 1),
            false, not opts.NoCull, 0, false)
    end)

    -- Params first, the (resetting) Activate after them.
    -- A BURST reads its USER params in the emitter SPAWN script, i.e. once at activation, so a
    -- param set on an already-running one-shot lands after it emitted with the default. (A LOOPING
    -- system re-reads every frame, which is why the beams/portal never exposed this.) The game
    -- spawns with bAutoActivate=FALSE, sets params, then Activates; our Activate(bReset=TRUE) below
    -- re-runs the spawn scripts for the same result without touching the spawn flags.

    -- Optional USER params (float) - for a system that sizes itself off a PARAMETER rather than
    -- its transform (e.g. the mushroom-skink spore burst's `Charge`). Skipping this and inflating
    -- the transform instead is a translucent overdraw bomb. Both spellings are tried:
    -- SetVariableFloat takes a BARE name, SetNiagaraVariableFloat the full "User." name - the
    -- wrong one just no-ops. SetVariableFloat's name is an FName, so it gets a built one: a raw Lua
    -- string handed to a reference param is the uncatchable-AV shape ([[ue4ss-const-ref-struct-param-av]]).
    if IsValid(comp) and opts.FloatParams then
        for name, v in pairs(opts.FloatParams) do
            local bare = name:gsub("^User%.", "")
            pcall(function() comp:SetVariableFloat(FName(bare), v) end)
            pcall(function() comp:SetNiagaraVariableFloat("User." .. bare, v) end)
        end
    end

    -- Optional USER params (Vector2f), values {X=,Y=} (a min,max range) - lets a caller HSV-shift a
    -- system with no direct Color param (the spore cloud's HueShiftRange / SaturationRange / ...).
    -- pcall'd per param, so a wrong name/type just no-ops. Try BOTH spellings: SetNiagaraVariable*
    -- resolves only the FULL "User.X" name, so a bare-name-only call silently misses.
    if IsValid(comp) and opts.Vec2Params then
        for name, v in pairs(opts.Vec2Params) do
            local bare = name:gsub("^User%.", "")
            pcall(function() comp:SetNiagaraVariableVec2(bare, v) end)
            pcall(function() comp:SetNiagaraVariableVec2("User." .. bare, v) end)
        end
    end

    -- Same for Vector3 USER params. The one that matters is a BEAM's endpoint: Niagara_Exor_Beam /
    -- _Cha draw from the component to "User.BeamEnd" (how Exor_Pikeman and BossAlly_Mage tether).
    --   * The "User." prefix is NOT optional - SetNiagaraVariableVec3 resolves by FULL name and
    --     every native caller passes "User.BeamEnd". A bare name spawns a beam with no endpoint.
    --   * That's the OPPOSITE of SetVariableVec3 / SetVariableLinearColor, which the LaserComponent
    --     calls with bare names ("Beam End"). The two APIs disagree; we try both and let one no-op.
    if IsValid(comp) and opts.Vec3Params then
        for name, v in pairs(opts.Vec3Params) do
            pcall(function() comp:SetNiagaraVariableVec3(name, v) end)
            if not string.find(name, "^User%.") then
                pcall(function() comp:SetNiagaraVariableVec3("User." .. name, v) end)
            end
        end
    end

    -- Optional user params (LinearColor) - direct recolor for a system with a Color param
    --   * Params can be > 1 (Lasers are 10)
    if IsValid(comp) and opts.ColorParams then
        for name, v in pairs(opts.ColorParams) do
            local bare = name:gsub("^User%.", "")
            pcall(function() comp:SetColorParameter(FName(bare), v) end)   -- an FName, as above
        end
    end

    -- opts.Dilation - playback speed (0.5 = half speed), the component's own tick multiplier.
    -- This is the ONLY channel that can pace an effect: BroadcastFX hands back no component.
    -- A slowed system takes proportionally longer to finish, so give it a longer Lifetime.
    if IsValid(comp) and opts.Dilation then
        pcall(function() comp:SetCustomTimeDilation(opts.Dilation) end)
    end

    -- opts.NoCull - exempt THIS instance from distance culling (a set-piece portal is otherwise a
    -- 20-80m effect). Full decode + investigation: AnNotes/AnteSystems/ClientFX.md.
    -- SetPreviewLODDistance(true, 0, …) is what actually stops the cull. SetAllowScalability(false)
    -- only works if set BEFORE the first Activate (hence bAutoActivate=false under NoCull above) -
    -- nothing later can un-register an already-registered component.
    -- Can make a looping system immortal (see the teardown's hard-free branch); NoCull spawns must
    -- be freed by us, never by bAutoDestroy.
    -- Debug log fields below: scal/lp mirror the two calls above; maxDD (CachedMaxDrawDistance) is
    -- the real disambiguator (0 = no limit imposed by the primitive path); ldDD is the component's
    -- own authored LDMaxDrawDistance.
    local function applyNoCull(when)
        local ok1 = pcall(function() comp:SetAllowScalability(false) end)
        local ok2 = pcall(function() comp:SetForceLocalPlayerEffect(true) end)
        local ok3 = pcall(function()
            comp:SetPreviewLODDistance(true, 0.0, NOCULL_LOD_MAX_UU)
        end)

        -- THE RANGE CAP. `true` = uncapped; a NUMBER caps DRAWING (not simulation) at that many uu.
        -- Mutually exclusive with bNeverDistanceCull - don't write both, or the flag silently voids
        -- the cap. SetCullDistance (not a raw field write) is what marks the render state dirty; a
        -- raw write can't reach the proxy's snapshot taken at creation. Trade-off: a render cull
        -- pops cleanly with distance, where falling back into scalability's range costs a manager
        -- update plus a multi-second delay before the effect returns.
        local ok4, capped
        if type(opts.NoCull) == "number" then
            ok4 = pcall(function() comp:SetCullDistance(opts.NoCull) end)
            capped = opts.NoCull
        else
            ok4 = pcall(function() comp.bNeverDistanceCull = true end)
        end

        local scal, lp, maxDD
        pcall(function() scal = comp:GetAllowScalability() end)
        pcall(function() lp = comp:GetForceLocalPlayerEffect() end)
        pcall(function() maxDD = comp.CachedMaxDrawDistance end)
        Utils.LogDebug("SpawnLocalNiagara - NoCull " .. when .. ": ok " .. tostring(ok1) .. "/" ..
            tostring(ok2) .. "/" .. tostring(ok3) .. "/" .. tostring(ok4) ..
            "  scal=" .. tostring(scal) .. " lp=" .. tostring(lp) ..
            " cap=" .. tostring(capped or "none") .. " maxDD=" .. tostring(maxDD) ..
            " fx=" .. tostring(niagaraPath), SETTINGS.DEBUG_CLIENT)
    end
    if IsValid(comp) and opts.NoCull then applyNoCull("pre") end

    -- NOW activate, bReset=TRUE. Two jobs: re-run the emitter spawn scripts so the USER params set
    -- above are actually read, and force a system that bAutoActivate left dormant under a
    -- significance handler (the whiteout regression) to play.
    if IsValid(comp) then pcall(function() comp:Activate(true) end) end

    -- Re-assert after the reset. SetForceLocalPlayerEffect and the LOD state live on the SYSTEM
    -- INSTANCE, which Activate(bReset=true) can rebuild, so a pre-activation write is not proof the
    -- live instance carries it. Costs three no-op calls on a handful of set-piece spawns, and the
    -- "post" log line next to the "pre" one is what tells us which side actually stuck.
    if IsValid(comp) and opts.NoCull then applyNoCull("post") end

    -- ALWAYS schedule the teardown - with bAutoDestroy=false above it is the ONLY thing that
    -- frees the component (looping or finite), backstopped when the caller forgot Lifetime.
    -- opts.DriftTo (optional) then walks it there over that same lifetime; it must be armed AFTER
    -- the teardown, because the teardown is what writes the generation the drift chain rides.
    if IsValid(comp) then
        local ms = opts.Lifetime or DEFAULT_NIAGARA_LIFETIME_MS
        local path = Utils.ObjectPath(comp)
        -- The ONLY place a component enters the book, and it is spawned bAutoDestroy=false above -
        -- condition (a) of the book's wrapper-holding contract.
        -- NoCull => hard free. See the teardown: a scalability-exempt system may never complete,
        -- and the graceful branch only frees on completion.
        scheduleTeardown(path, comp, ms, opts.NoCull)
        if opts.DriftTo then driftComponent(comp, path, location, opts.DriftTo, ms) end
    end
    return comp
end


-- =======================================================================
-- BroadcastFX - path 2: the GameState multicast. ONE authority call spawns the named Niagara
-- (+ optional SoundWave) on EVERY machine, no ClientVisuals mirroring needed.
--   * HARD CONSTRAINT - it spawns with bAutoDestroy, which only fires for a FINITE system. A
--     LOOPING one (Niagara_Portal_Door) hangs forever on every machine with no way for the server
--     to close it. Self-completing effects only; anything else goes over SendClientFX.
--   * Preload what you name here in def.Assets: a cold Niagara load in a tick hook is the S2
--     deadlock, and GetIfValid is deliberately non-loading (it no-ops and logs).
-- =======================================================================
FX.PORTAL_FX  = ENUMS.Effects.PORTAL_BURST_ONCE
FX.PORTAL_SFX = "/Game/Audio/Environment/Portals/portal_spawn.portal_spawn"

function FX.BroadcastFX(location, fxPath, sfxPath, scale)
    if not Utils.IsAuthority() or not location or not fxPath then return end

    local fx = ASSETS.GetIfValid(fxPath)
    if IsNotValid(fx) then
        LogBad("BroadcastFX - Niagara not resident (preload it in def.Assets): " .. tostring(fxPath))
        return
    end
    local sfx = sfxPath and ASSETS.GetIfValid(sfxPath) or nil   -- optional; a nil sound is fine

    -- STATE.GameState, NOT UEHelpers.GetGameStateBase(): that returns a cached AGameStateBase that
    -- can be stale/nil after a level load, and the multicast lives on Abiotic_Survival_GameState
    -- (main.lua caches the real one). Getting it wrong is SILENT - the pcall eats it, no FX.
    local gs = STATE.GameState
    if IsNotValid(gs) then
        LogBad("BroadcastFX - no GameState")
        return
    end

    local ok = pcall(function()
        -- Build the transform via KismetMathLibrary, NOT the AFUtils FTransform() helper. That one
        -- is FTransform(Translation, Rotation, Scale3D), and we used to pass the QUAT as the
        -- translation: it silently resolved to (0,0,0), so every BroadcastFX spawned at WORLD
        -- ORIGIN with its sound attenuated to nothing, and read as "the asset is wrong".
        local kMath = UEHelpers.GetKismetMathLibrary()
        if not kMath then return end
        local xf = kMath:MakeTransform(location, FRotator(0, 0, 0), scale or FVector(1, 1, 1))
        gs:Broadcast_SpawnParticleSystemAtLocation(fx, sfx, xf)
    end)
    if not ok then LogBad("BroadcastFX - multicast failed: " .. tostring(fxPath)) end
end


-- The blue Anteverse spawn-in burst at `actor`'s feet - what Pests and Exors play on arrival
-- (OnSpawnFXStarted). Every OTHER NPC inherits SpawnFXDuration = 0 from NPC_Base and plays
-- NOTHING, so leaving SkipSpawnFX alone buys no portal: there's no FX to skip. Call this instead.
-- opts (all optional):
--   NoSound  - visual only; the burst is loud and a summoner popping 2-4 stacks the cue.
--   Sound/Fx - override either asset path (preload what you name in def.Assets).
--   Scale    - FVector, default 1.
function FX.SpawnPortalFX(actor, opts)
    if Utils.IsActorInvalid(actor) then return end
    opts = opts or {}

    local loc
    pcall(function() loc = actor:K2_GetActorLocation() end)

    local sfx = (not opts.NoSound) and (opts.Sound or FX.PORTAL_SFX) or nil
    FX.BroadcastFX(loc, opts.Fx or FX.PORTAL_FX, sfx, opts.Scale)
end


-- =======================================================================
-- THE CLIENT-FX CHANNEL (path 3) - ask EVERY renderer to play a registered effect LOCALLY, at a
-- world location, for N seconds. Ported from EnemyAtTheGATE. Fires on the HOST too (its own
-- controller is in the list), so host and clients share one path.
--
-- The transport is AnteCore/NetChannel, opcode FX. Both halves of the codec live here (packFX /
-- FX.DecodeFrames) and a push is two frames:
--   frame 1  x/y/z = the world location, a = fxIndex * 10000 + seconds
--   frame 2  read per the entry's SHAPE (the registry's `Beam` flag):
--              point effect - x is a YAW in degrees, needed by anything not radially symmetric
--                (the GK portal is a flat plane, invisible edge-on). y is a DRIFT in uu and z a
--                SCALE, each with its own "not specified" marker (see FX.SendClientFX) so the
--                registry entry's own value stays the default.
--              beam effect  - x/y/z are the far endpoint, so a beam entry has no yaw, drift or
--                scale.
-- A STOP is frame 1 on its own, with seconds = 0.
--
-- Coordinates go out unrounded now: NetChannel's location slot keeps full double precision, where
-- the chat colours this replaced were float32 and had to be floored.
-- =======================================================================

-- ENCODE half: location + effect index/duration -> frame 1, shared by all three senders.
-- FX.DecodeFrames below is the matching half; change one and you MUST change the other.
-- SECONDS IS FLOORED TO 1, which frees a duration of ZERO to be the channel's STOP opcode
-- (FX.StopClientFX / DecodeFrames' `stop`). No live effect can encode 0, so they can't be confused.
local function packFX(location, idx, seconds)
    local secs = math.max(1, math.min(9999, math.floor(seconds or 10)))
    return { x = location.X or 0, y = location.Y or 0, z = location.Z or 0, a = idx * 10000 + secs }
end

-- The shared wire push. `key` only names the effect in the debug line.
local function pushClientFX(key, frames)
    local reached = NET.Broadcast(NET.OP.FX, frames)
    Utils.LogDebug("SendClientFX - " .. key .. " -> " .. reached .. " renderer(s)", SETTINGS.DEBUG_CLIENT)
end


-- [AUTHORITY] Play a registered point effect on every renderer. `key` is an AnteEnums.ClientFX key;
-- `yaw` (degrees, optional) is its facing - set it for anything that isn't radially symmetric.
-- `drift` (uu, optional) overrides the entry's own Drift: the effect starts drift/2 AHEAD of the
-- location along `yaw` and slides drift/2 BEHIND it over its lifetime - i.e. it advances on
-- whatever it faces. Pass 0 to pin an entry that normally drifts; omit it for the registry default.
-- `scale` (optional) overrides the entry's own Scale, uniformly.
--   * Both ride frame 2, which a POINT entry has to itself. A BEAM entry spends that frame on
--     its far endpoint, which is why SendClientBeam takes neither: a beam's placement and length
--     ARE its two ends.
--   * Each has a "not specified" marker so the registry entry stays the default: -1 for drift (a
--     real drift is never negative - flip the yaw instead), 0 for scale.
--   * Scale rides the wire rather than sitting in the registry so a variant can tune it through
--     /reload - a registry edit needs a full restart (Enums is not re-required).
function FX.SendClientFX(location, key, seconds, yaw, drift, scale)
    if not Utils.IsAuthority() or not location or not key then return end

    local idx = ENUMS.ClientFXIndex[key]
    if not idx then
        LogBad("SendClientFX - unknown effect key: " .. tostring(key))
        return
    end

    pushClientFX(key, {
        packFX(location, idx, seconds),
        { x = (yaw or 0) % 360, y = drift and math.max(0, drift) or -1, z = scale or 0 },
    })
end


-- [AUTHORITY] Outline `npc` through walls on EVERY renderer for `seconds` (the OUTLINE opcode -
-- an `Outline = true` registry entry; the receiver outlines the live NPC nearest the sent point,
-- so this sends the body's own location). Outlines are a purely local component visual, which
-- is why a "highlight this enemy for everyone" has to ride the channel. `key` defaults to
-- OUTLINE_YELLOW. Re-send on a cadence shorter than `seconds` to hold it (it expires).
function FX.OutlineNpcAll(npc, seconds, key)
    if not Utils.IsAuthority() or Utils.IsActorInvalid(npc) then return end
    local loc
    pcall(function() loc = npc:K2_GetActorLocation() end)
    if not loc then return end
    FX.SendClientFX(loc, key or "OUTLINE_YELLOW", seconds or 5)
end


-- =======================================================================
-- [AUTHORITY] STOP a live effect on every renderer - the channel's "stop" opcode. Every renderer
-- destroys whatever it currently has live for that entry's Niagara.
--   * Before this, closing a LOOPING system meant letting its lifetime expire, so an event-length
--     effect was held by a HEARTBEAT and "closed" by the sender going quiet - which leaves the last
--     instance up for its full lifetime, or FOREVER if one machine misses a teardown.
--   * The receiver keys off the entry's NIAGARA, not the registry key: a heartbeat-held effect is
--     usually a PAIR over one system (NIGHTREALM_OPEN + NIGHTREALM_DOOR), so either key closes both.
--   * Rides frame 1 with seconds = 0, so beams stop exactly like point effects.
-- =======================================================================
function FX.StopClientFX(key)
    if not Utils.IsAuthority() or not key then return end

    local idx = ENUMS.ClientFXIndex[key]
    if not idx then
        LogBad("StopClientFX - unknown effect key: " .. tostring(key))
        return
    end

    -- Location is meaningless for a stop (the receiver closes by system, not by proximity), so it
    -- goes out as the origin. An INDEX WITH NO SECONDS is the stop, and it needs no second frame.
    pushClientFX(key .. " [stop]", { { x = 0, y = 0, z = 0, a = idx * 10000 } })
end


-- [AUTHORITY] Draw a BEAM between two world points on every renderer. Same channel, different
-- payload shape: the far end rides frame 2 as an XYZ. This CANNOT go over
-- BroadcastFX - that multicast only takes a transform, and a beam with no endpoint draws nothing.
function FX.SendClientBeam(from, to, key, seconds)
    if not Utils.IsAuthority() or not from or not to or not key then return end

    local idx = ENUMS.ClientFXIndex[key]
    local def = idx and ENUMS.ClientFX[idx]
    if not def then
        LogBad("SendClientBeam - unknown effect key: " .. tostring(key))
        return
    end
    if not def.Beam then
        LogBad("SendClientBeam - '" .. key .. "' is not a Beam entry (it has no BeamParam)")
        return
    end

    pushClientFX(key, {
        packFX(from, idx, seconds),
        { x = to.X or 0, y = to.Y or 0, z = to.Z or 0 },
    })
end


-- =======================================================================
-- PlaySound2DAll - plays a non-positional sound on the announcement channel, for all players.
--   * Abiotic_PlayerCharacter's native NetClient RPC Client_Play2DSoundEffect(USoundBase*) just
--     calls PlaySound2D(Sound, 1, 1, 0, UI=true). Used natively by the AI Director's assault
--     stings, Sun Disk, Composer, the drowning buff. USoundBase, so SoundWave or SoundCue both bind.
--   * No component handle - a looping sound plays indefinitely with no way to stop it.
--   * Called off-hook: preload the asset (LoadAsync) to avoid the S2 deadlock, then hop back onto
--     the WorkQueue drain.
-- =======================================================================
function FX.PlaySound2DAll(soundPath)
    if not Utils.IsAuthority() or not soundPath then return end

    ASSETS.LoadAsync({ soundPath }, function()
        Utils.QueueWork(function()
            local snd = ASSETS.GetIfValid(soundPath)
            if IsNotValid(snd) then
                LogBad("PlaySound2DAll - sound not resident after load: " .. tostring(soundPath))
                return
            end

            -- The GameState's player array, not FindAllOf (avoids a walk of every UObject in the world)
            -- slow and a very slim chance of an AV crash
            local gs = STATE.GameState
            if IsNotValid(gs) then return end
            local players = gs.PlayerCharacterInGame
            if not players then return end

            local sent = 0
            for i = 1, #players do
                local p = players[i]
                if IsValid(p) then
                    pcall(function()
                        if not p.Client_Play2DSoundEffect then return end
                        p:Client_Play2DSoundEffect(snd)
                        sent = sent + 1
                    end)
                end
            end

            Utils.LogDebug("PlaySound2DAll - " .. tostring(soundPath) .. " -> " .. sent .. " player(s)",
                SETTINGS.DEBUG_CLIENT)
        end, 0)
    end)
end


-- =======================================================================
-- DECODE half - the inverse of packFX, called by the ClientEffects handler on every renderer.
-- It lives next to the encoder so the wire format is defined exactly once.
--   * Takes the frames NetChannel assembled, returns def, location, seconds, yaw, beamEnd, stop,
--     drift, scale - or NIL when the index names no registry entry.
--   * `drift` / `scale` are nil when the sender didn't specify one; the caller falls back to
--     def.Drift / def.Scale.
--   * Pure arithmetic - it touches no actor or component.
--   * `stop` = a CLOSE for that entry, not a play. Location/yaw/beamEnd are meaningless then.
-- =======================================================================
function FX.DecodeFrames(frames)
    local head = frames and frames[1]
    if not head or not head.a then return nil end

    local idx = math.floor(head.a / 10000)
    local secs = head.a - idx * 10000
    local def = ENUMS.ClientFX[idx]
    -- A REGISTRY ENTRY IS ENOUGH - do NOT also require def.FX. Requiring it silently dropped every
    -- SOUND-ONLY entry (NIGHTREALM_STING), since downstream already handles a def with no Niagara.
    if not def then return nil end

    -- Frame 2, read per the entry's SHAPE (wire-format block above).
    local extra = frames[2]
    local yaw, beamEnd, drift, scale
    if def.Beam then
        if extra then beamEnd = FVector(extra.x, extra.y, extra.z) end
    elseif extra then
        yaw = extra.x or 0
        -- y < 0 is the "not specified" marker (fall back to def.Drift); y == 0 is an explicit
        -- "pin this one still", so the test is >= 0, not > 0.
        if extra.y and extra.y >= 0 then drift = extra.y end
        -- z is "not specified" at 0 - a zero-scale effect draws nothing, so there is no legitimate
        -- value to confuse it with.
        if extra.z and extra.z > 0 then scale = extra.z end
    end

    -- secs == 0 is the STOP opcode: packFX floors a real duration to 1, so a play never lands here.
    return def, FVector(head.x, head.y, head.z), secs, yaw, beamEnd, (secs == 0), drift, scale
end


return FX
