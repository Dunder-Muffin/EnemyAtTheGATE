-- =======================================================================
-- ClientEffects - the RECEIVING half of the server->client FX channel (AVU.SendClientFX /
-- SendClientBeam). Server Niagara doesn't reach clients: a replicated FX actor can't carry a
-- custom system, and the GameState multicast's bAutoDestroy never fires for a LOOPING one. So the
-- server PUSHES a description and every renderer spawns - and frees - its own components.
--   * The push rides AnteCore/NetChannel (opcode FX), which lands with no visible trace on the
--     receiver - the chat RPC it replaced added a blank chat line for every player, every push.
--   * This file owns only the handler and local playback. The wire format is one codec in one file
--     (AnteUtils/ClientFX: packFX / FX.DecodeFrames); the registry is AnteEnums.ClientFX.
--   * A prior design scanned for replicated anchor actors every 800ms on every renderer instead.
--     Dropped: it decorated any matching actor regardless of source (only the server knows which
--     spawner an anchor came from), and it walked the whole UObject array for an actor that lives
--     a few seconds. If a future effect needs an anchor the server can't see, key that scan on
--     something narrower than a class.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local NET = require("AnteCore.NetChannel")
local ENUMS = require("AnteData.Enums")
local ASSETS = require("AnteCore.AssetManager")
local KEEPER = require("AnteCore.AssetKeeper")
local FX = require("AnteUtils.ClientFX")
local Utils = require("AnteUtils.Utils")
local UEHelpers = require("UEHelpers")

local Log = Utils.Log

local CE = {}


-- =======================================================================
-- THE WIRE FORMAT IS NOT DEFINED HERE - both halves live in AnteUtils/ClientFX; an encoder and
-- decoder that disagree fail SILENTLY (the effect just never appears).
--   * FX.DecodeFrames(frames) -> def, location, seconds, yaw, beamEnd, stop, drift, scale.
--   * `stop` = a CLOSE for that entry rather than a play, hence the book of live components below
--     (liveFX).
--   * THREADING (S2): NetChannel assembles frames inside the RPC intercept and dispatches on the
--     drain, so the playback below is already clear of the intercept.
-- =======================================================================
local GAMEPLAY_STATICS = "/Script/Engine.Default__GameplayStatics"


-- =======================================================================
-- LIVE-COMPONENT BOOK, so the channel's STOP opcode has something to close. Entries are
-- { p = object path, loc = spawn location, yaw = spawn yaw }; loc/yaw let a heartbeat re-arm the
-- already-placed component (reviveFX) instead of spawning a second one.
--   * Keyed by NIAGARA PATH, not registry key: a heartbeat-held effect can be a PAIR of entries
--     over one system (NIGHTREALM_OPEN + NIGHTREALM_DOOR), and a close has to take both.
--   * Values are OBJECT PATHS, never wrappers - a component spawned seconds ago may already be
--     freed, and a captured wrapper AVs through a lying IsValid (S3). ResolveByPath returns nil
--     for a freed one, so a stale entry is just skipped.
--   * Self-pruning: every play drops its system's unresolvable entries. Each component also
--     frees itself on its own teardown; a stop is only the early close.
-- =======================================================================
local liveFX = {}

-- How close a re-send must be to count as "the same effect, still burning". The door is re-sent at
-- one authored coord, so this only absorbs float noise - keep it tight or two nearby portals merge.
local FX_SAME_SPOT = 100 * 100   -- 1m, squared

local function trackFX(fxPath, comp, loc, yaw)
    local path = Utils.ObjectPath(comp)
    if not path then return end

    local book = liveFX[fxPath]
    if not book then
        book = {}
        liveFX[fxPath] = book
    end
    for i = #book, 1, -1 do
        if not Utils.ResolveByPath(book[i].p) then table.remove(book, i) end
    end
    -- Plain numbers, not the FVector - nothing engine-owned is held across frames (S3).
    book[#book + 1] = {
        p = path, yaw = yaw or 0,
        loc = loc and { X = loc.X or 0, Y = loc.Y or 0, Z = loc.Z or 0 } or nil,
    }
end

-- [RENDERER] A heartbeat landing on an effect already burning at this spot: push its teardown out
-- instead of building a second Niagara. Returns true if it took.
--   * Deliberately NOT used for beams - a beam's endpoint is a USER param set at spawn, so a
--     re-send is genuinely a different effect. Yaw is matched for the same reason.
local function reviveFX(def, loc, yaw, ms)
    local book = def.FX and liveFX[def.FX]
    local n = book and #book or 0

    local function bail(reason)
        Utils.LogDebug(string.format("reviveFX MISS (%s) fx=%s book=%d",
            reason, tostring(def.FX), n), SETTINGS.DEBUG_CLIENT)
        return false
    end

    if def.Beam then return false end            -- by design, not a miss
    if not book or n == 0 then return bail("no book") end
    if not loc then return bail("no loc") end

    local dead, spot = 0, nil
    for i = #book, 1, -1 do
        local e = book[i]
        if not Utils.ResolveByPath(e.p) then
            dead = dead + 1
            table.remove(book, i)
        elseif e.loc and e.yaw == (yaw or 0) and Utils.DistSq(e.loc, loc) <= FX_SAME_SPOT then
            if FX.KeepAlive(e.p, ms) then
                Utils.LogDebug("reviveFX HIT - re-armed " .. tostring(e.p), SETTINGS.DEBUG_CLIENT)
                return true
            end
            return bail("KeepAlive refused")
        elseif e.loc then
            spot = string.format("d2=%.0f yaw %s vs %s",
                Utils.DistSq(e.loc, loc), tostring(e.yaw), tostring(yaw or 0))
        end
    end
    return bail(dead > 0 and ("stale x" .. dead) or (spot or "no match"))
end

-- [RENDERER] Close every component live for one registry entry's system. Same two-step as the
-- SpawnLocalNiagara teardown - Deactivate, free a beat later - so in-flight particles fade rather
-- than pop.
local function stopClientFX(def)
    local book = def.FX and liveFX[def.FX]
    if not book then return end
    liveFX[def.FX] = nil

    -- Logged (not LogDebug'd) with counts: a stop happens once per event, and "closed 0 of 2" is
    -- what separates "the stop never arrived" from "they were already freed".
    local closed = 0
    for _, e in ipairs(book) do
        local path = e.p
        local c = Utils.ResolveByPath(path)
        if c then
            closed = closed + 1
            -- Take ownership OFF the teardown book first: this is now the only chain that will
            -- free the component, and anything else still holding the path (its scheduled
            -- teardown, a drift walk) must see the generation vanish and bail rather than touch
            -- a wrapper we are about to destroy ([[anteup2-clientfx-teardown-uaf]]).
            FX.Forget(path)
            pcall(function() c:Deactivate() end)
            Utils.QueueWork(function()
                local c2 = Utils.ResolveByPath(path)
                if c2 then pcall(function() c2:K2_DestroyComponent(c2) end) end
            end, 1500)
        end
    end
    Log(string.format("ClientEffects - stop: closed %d of %d live component(s)", closed, #book))
end


-- [RENDERER] Play one registry entry locally and tear its components down after `secs`.
-- `retried` is set only by the cold-load re-entry below; callers never pass it.
local function playClientFX(loc, def, secs, yaw, beamEnd, drift, scale, retried)
    local ms = math.max(1, secs) * 1000

    -- MESH opcode (def.Wall): no Niagara either - build the lent front plate on the live NPC
    -- nearest the sent point. Same nearest-body addressing as OUTLINE below, and the same reason
    -- for existing: a runtime-added component never replicates, so each renderer builds its own.
    -- AddShieldWall owns the plate's whole lifetime (the wearer's own tick destroys it), so this
    -- entry is fire-and-forget here exactly like a one-shot Niagara.
    if def.Wall then
        pcall(function()
            local AVU = require("AnteUtils.AVUtils")
            local best, bestSq
            for _, npc in ipairs(AVU.GetNearbyNpcs(loc, def.WallRadius or 200)) do
                local d = Utils.DistSq(loc, npc:K2_GetActorLocation())
                if not bestSq or d < bestSq then best, bestSq = npc, d end
            end
            if best then AVU.AddShieldWall(best, { Seconds = secs, Local = true }) end
        end)
        return
    end

    -- OUTLINE opcode (def.Outline): no Niagara at all - outline the live NPC nearest the sent
    -- point through walls, for `secs`. The sender sends the NPC's own location, so the nearest
    -- overlap hit IS the intended body; the radius only has to beat replication lag. Uses the
    -- same OutlineComponent call as ModuleNpcHighlighter (a purely local visual - which is the
    -- whole reason it has to ride this channel to reach clients). SphereOverlapActors is a world
    -- query, fine on a pure client. No cold-load: nothing to load.
    if def.Outline then
        pcall(function()
            local AVU = require("AnteUtils.AVUtils")
            local best, bestSq
            for _, npc in ipairs(AVU.GetNearbyNpcs(loc, def.OutlineRadius or 300)) do
                local at = npc:K2_GetActorLocation()
                local d = Utils.DistSq(loc, at)
                if not bestSq or d < bestSq then best, bestSq = npc, d end
            end
            if not best then return end
            local outline = best.OutlineComponent
            if IsValid(outline) then
                outline:ToggleOutlineOverlay(def.OutlineMode or 5, math.max(1, secs), false)
            end
        end)
        return
    end

    -- COLD ON ARRIVAL - load, then play. Both spawns below resolve through the deliberately
    -- non-loading GetIfValid, so an entry whose Niagara/sound isn't resident the instant the push
    -- lands renders NOTHING, silently. The keep-warm loop only reaches each path every ~75s and a
    -- preload never pins (S3), so a system nothing else references can be collected right before
    -- its event fires.
    --   * LoadAsync is safe here (loads via EIGT, genuinely off-hook); the retry goes back on the
    --     drain rather than running in the EIGT callback, where component work must not happen
    --     (S2). Resident assets skip this branch entirely.
    --   * ONE retry only - a path that fails to load stays silent. Benign known case: a STOP
    --     during the load leaves the retry's copy up for its own lifetime, bounded by teardown.
    if not retried then
        local cold = {}
        if def.FX and not ASSETS.GetIfValid(def.FX) then cold[#cold + 1] = def.FX end
        if def.Sound and not ASSETS.GetIfValid(def.Sound) then cold[#cold + 1] = def.Sound end
        if #cold > 0 then
            Utils.LogDebug("ClientEffects - cold FX asset, loading before play: " .. cold[1],
                SETTINGS.DEBUG_CLIENT)
            ASSETS.LoadAsync(cold, function()
                Utils.QueueWork(function()
                    playClientFX(loc, def, secs, yaw, beamEnd, drift, scale, true)
                end, 0)
            end)
            return
        end
    end

    -- Entry-authored vertical shift (def.ZOffset): a GROUND system (REAPER_MELD's flask smoke)
    -- plays at the feet, but senders send capsule-center. MUST sit AFTER the cold-load branch -
    -- the retry re-enters with the original loc, so shifting earlier would stack the offset twice.
    if def.ZOffset and loc then
        loc = { X = loc.X, Y = loc.Y, Z = loc.Z + def.ZOffset }
    end

    -- A BEAM is drawn from `loc` to `beamEnd`: point the system AT the far end so directional
    -- emitters line up, and hand the endpoint to its Vector3 USER param - how NPC_Exor_Pikeman
    -- draws its own tether.
    local rot, vec3
    if def.Beam and beamEnd then
        rot = Utils.RotatorToTarget(loc, beamEnd)
        vec3 = { [def.BeamParam or "User.BeamEnd"] = beamEnd }
    else
        -- def.Pitch tips the whole system: an upward column at -90 becomes a horizontal one blowing
        -- along the sender's yaw. Registry data, so it is per-ENTRY - the yaw stays per-send.
        rot = FRotator(def.Pitch or 0, yaw or 0, 0)
    end

    -- Lifetime = Deactivate then FREE, mandatory for a LOOPING system (PORTAL_DOOR) that never
    -- self-completes, so bAutoDestroy never fires. The registry owns param tuning: def.Vec2Params
    -- carries HSV-shift USER params, def.FloatParams any scalar (e.g. a spore burst's `Charge`,
    -- which sizes the system). Booked so a STOP can close it early, and a heartbeat landing on a
    -- still-burning copy just re-arms it (reviveFX) instead of doubling the component.
    -- SOUND-ONLY entries (no def.FX) skip this half entirely - nothing to spawn, book, or revive.
    -- ONE-SHOT entries (def.OneShot) spawn but skip the book: booking only serves a later STOP or
    -- heartbeat re-arm, and every book touch here is a ResolveByPath - a full UObject-array scan.
    -- A dense volley of one-shots would hammer that scan repeatedly, risking the FindObject-scan
    -- crash ([[anteup2-ue4ss-findobject-scan-crash]]), so one-shots stay unbooked.
    if def.FX then
        -- Sender's scale wins, uniformly; nil falls back to the registry entry's own Scale.
        local spawnOpts = {
            Scale = scale and FVector(scale, scale, scale) or def.Scale,
            Rotation = rot, Lifetime = ms,
            Vec3Params = vec3, Vec2Params = def.Vec2Params, FloatParams = def.FloatParams,
            ColorParams = def.ColorParams, NoCull = def.NoCull,
            Dilation = def.Dilation,
        }

        -- DRIFT (the GK portal's warp-gate slide): spawn half the travel AHEAD of the sent point
        -- and walk it half PAST it, backwards along the entry's yaw, so the doorway passes
        -- through the anchor. Sender's value wins; nil falls back to the registry entry's Drift.
        --   * Beams are excluded: their placement IS their two endpoints.
        --   * `startLoc` is a separate variable on purpose - the book and sound keep the original
        --     loc, so reviveFX still matches a heartbeat against the sent coordinate no matter how
        --     far the component has slid. A re-armed component is not re-drifted.
        --   * The sound stays put: separate component, own teardown, and a small offset is
        --     inaudible through the cue's attenuation.
        local startLoc = loc
        local travel = drift or def.Drift
        if travel and travel > 0 and not def.Beam and loc then
            local r = math.rad(yaw or 0)
            local hx, hy = math.cos(r) * travel * 0.5, math.sin(r) * travel * 0.5
            startLoc = FVector(loc.X + hx, loc.Y + hy, loc.Z)
            spawnOpts.DriftTo = FVector(loc.X - hx, loc.Y - hy, loc.Z)
        end

        if def.OneShot then
            FX.SpawnLocalNiagara(startLoc, def.FX, spawnOpts)
        elseif not reviveFX(def, loc, yaw, ms) then
            trackFX(def.FX, FX.SpawnLocalNiagara(startLoc, def.FX, spawnOpts), loc, yaw)
        end
    end

    if not def.Sound then return end

    -- The doorway hum is looping too, so we hold the audio component and stop + free it ourselves.
    local snd = ASSETS.GetIfValid(def.Sound)
    local gps = ASSETS.GetIfValid(GAMEPLAY_STATICS)
    if IsNotValid(snd) or IsNotValid(gps) then return end

    local world = Utils.GetWorld()
    if IsNotValid(world) then return end

    -- def.Volume multiplies the cue's own level, for an entry that has to be heard over a fight
    -- rather than at the distance it was authored for.
    local vol = def.Volume or 1.0

    -- Sound2D: play it AT THE PLAYER instead of at the location, for a cue that must be heard
    -- rather than located. A world sound carries its own attenuation, and a cue authored to be
    -- heard from a metre away goes inaudible across a hall - wrong for a telegraph.
    --   * Fire-and-forget: a 2D one-shot needs no component, so `seconds` is ignored and there is
    --     nothing for StopClientFX to close. Only use it for short one-shots.
    --   * Still PER RENDERER (runs on each machine), unlike EVU.PlayAnnouncement (host/SP-local).
    if def.Sound2D then
        -- (World, Sound, Vol, Pitch, StartTime, Concurrency, OwningController, bIsUISound)
        pcall(function() gps:PlaySound2D(world, snd, vol, 1.0, 0.0, nil, nil, true) end)
        return
    end

    local comp
    pcall(function()
        -- (WorldContext, Sound, Location, Rotation, Volume, Pitch, StartTime,
        --  Attenuation, Concurrency, bAutoDestroy)
        -- bAutoDestroy=FALSE, matching SpawnLocalNiagara: the teardown below must be this
        -- component's ONLY owner. With it true the engine frees a finite cue the moment it
        -- finishes and our destroy lands on the corpse - two owners, which is the UAF this file
        -- already fought.
        comp = gps:SpawnSoundAtLocation(world, snd, loc, FRotator(0, 0, 0),
            vol, 1.0, 0.0, nil, nil, false)
    end)
    if IsNotValid(comp) then return end

    -- HOLD THE WRAPPER, no path resolve. Sole ownership is what makes a captured wrapper safe
    -- here, exactly as argued for the ClientFX teardown book:
    --   * Nothing else can free it, so the wrapper cannot go stale under us.
    --   * StopMod drops the WorkQueue on world teardown, so this closure - and the wrapper it
    --     holds - dies with the world rather than surviving into the next one.
    --   * A STOP never touched the sound (only the FX book), so there is no second chain.
    -- The resolve it replaces was a full UObject-array walk per cue: the mod's hottest remaining
    -- scan and the one that AV'd on a dangling Outer during a portal FX cycle.
    -- Cost of sole ownership: a finished cue lingers silent until `ms`, same as a completed
    -- Niagara does.
    Utils.QueueWork(function()
        if IsNotValid(comp) then return end
        pcall(function() comp:Stop() end)
        pcall(function() comp:K2_DestroyComponent(comp) end)
    end, ms)
end


local function registerClientFXChannel()
    if STATE.ClientFXHookArmed then return end   -- once per UE4SS session (persistent flag)
    STATE.ClientFXHookArmed = true

    NET.RegisterReceiver()
    NET.On(NET.OP.FX, function(frames)
        local def, loc, secs, yaw, beamEnd, stop, drift, scale = FX.DecodeFrames(frames)
        if not def then return end
        if stop then return stopClientFX(def) end
        playClientFX(loc, def, secs, yaw, beamEnd, drift, scale)
    end)

    Log("ClientEffects - client FX channel registered")
end


-- =======================================================================
-- KEEP-WARM - a teleport/portal/beam can silently fail to render on a client. Both our lookup
-- (FX.SpawnLocalNiagara -> ASSETS.GetIfValid) and the game's own native multicasts (raw
-- FindObject<UNiagaraSystem>(path), e.g. the Exor's Broadcast_TeleportFX) are NON-LOADING: a miss
-- spawns nothing, silently. The multicast is one-shot, so the FX must already be resident when it
-- fires - a mutation-time preload doesn't pin (S3) and can be collected long before the NPC
-- actually uses it.
--   * Fix: PIN the list via AssetKeeper.PinPaths (hard refs on the GameState) so it can't GC, and
--     periodically sweep only the unpinned remainder as a safety net.
--   * Every probe is a full UObject-array walk even when resident and sits on the
--     FindObject-scan crash surface ([[anteup2-ue4ss-findobject-scan-crash]]), hence pinning
--     instead of probing every sweep. Full investigation: AnNotes/AnteSystems/ClientEffects.md.
-- =======================================================================
local REWARM_MS = 60000
local REWARM_STEP_MS = 300   -- gap between single-path warm steps, not every drain tick - a
                             -- tighter step stacks loads onto already-busy drains.

-- FX the GAME spawns by FindObject on a multicast WE trigger. Not in the ClientFX registry (the
-- native multicast carries them), so nothing else keeps them alive.
local NATIVE_FX = {
    -- Exor blink. ARMORED (Displacer / Dislocator swap-bomb) uses the plain set; the PIKEMAN family
    -- (the Spiritwalker's own teleport ability) uses the _Cha set. Both call Broadcast_TeleportFX.
    -- The Spiritwalker/Wraith transpose no longer does - it draws its own FX over the client channel.
    ENUMS.Effects.EXOR_BLINK, ENUMS.Effects.EXOR_BEAM, ENUMS.Effects.EXOR_BLINK_SFX,
    ENUMS.Effects.EXOR_BLINK_CHA, ENUMS.Effects.EXOR_BEAM_CHA,
}

-- ONE PATH PER DRAIN STEP. A whole-batch LoadAsync can cost hundreds of ms in a single WorkQueue
-- item: a cache hit is a StaticFindObject, but a GC'd asset reloads via EIGT, which runs
-- SYNCHRONOUSLY when called from the game thread - so every collected asset in the batch would
-- block one frame. One path per REWARM_STEP_MS spreads that cost: a sweep takes ~15s, then rests
-- REWARM_MS, so each asset re-warms every ~75s, well inside the GC horizon.
local warmList = nil     -- built once per session (ENUMS is static)
local warmIdx = 1

local function buildWarmList()
    local warm = { GAMEPLAY_STATICS }
    for _, def in ipairs(ENUMS.ClientFX) do
        if def.FX then warm[#warm + 1] = def.FX end
        if def.Sound then warm[#warm + 1] = def.Sound end
        if def.Mesh then warm[#warm + 1] = def.Mesh end
    end
    for _, path in ipairs(NATIVE_FX) do warm[#warm + 1] = path end
    return warm
end

local function rewarmLoop()
    if not STATE.ModEnabled then
        STATE.ClientEffectsArmed = false   -- Register re-arms on the next InitMod
        return
    end

    warmList = warmList or buildWarmList()
    -- Advance through PINNED paths for free: a pin is a hard ref, so no probe is needed, and
    -- skipping the probe is the point - each probe is a full object-array walk (scan-crash surface).
    while true do
        local path = warmList[warmIdx]
        if not path then break end
        warmIdx = warmIdx + 1
        if not KEEPER.IsPinned(path) then
            ASSETS.LoadAsync({ path }, function() end)
            Utils.QueueWork(rewarmLoop, REWARM_STEP_MS)
            return
        end
    end

    warmIdx = 1
    -- Re-pin on every sweep wrap. Idempotent (pinned paths are skipped, so a full set is a pure
    -- Lua no-op) and it self-heals pins that failed at Register - GameState not up yet, an asset
    -- that wouldn't load, a mid-load world teardown.
    KEEPER.PinPaths(warmList)
    Utils.QueueWork(rewarmLoop, REWARM_MS)
end


function CE.Register()
    if STATE.ClientEffectsArmed then return end
    STATE.ClientEffectsArmed = true

    -- PIN the whole warm list first (hard refs); once held, the sweep skips them forever. If the
    -- keeper is off or fails, nothing pins, IsPinned stays false, and the sweep behaves as before.
    KEEPER.PinPaths(buildWarmList())

    -- Warm every pushable effect AND every native-multicast FX up front, then every REWARM_MS. The
    -- up-front pass makes the FIRST portal/cloud/beam appear; the loop stops the LAST one
    -- silently vanishing to GC.
    rewarmLoop()

    registerClientFXChannel()
    Log("ClientEffects registered")
end

return CE
