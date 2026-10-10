-- =======================================================================
-- AVWorldFX (WFX) - weather and per-viewer screen effects: the blizzard whiteout, the screen tint,
-- and the client-side warp mirror. Split out of AVUtils, merged back onto AVU: callers still write
-- AVU.TriggerBlizzard / SetScreenTint / WarpMirrorTick / ...
--
-- MUST-KNOWS
--   * These are RENDERER-LOCAL effects with an AUTHORITY-side registry in front of them. The
--     gameplay answer ("is a whiteout happening here") must never depend on who drew what.
--   * Anything that spawns a level actor is off-hook + preloaded (CLAUDE.md 2) - the blizzard zone
--     froze the host when its FX activated inside our tick-hook drain.
--   * Post-process settings are re-read every frame, so a tint needs no dirty flag - but the
--     game's damage flash writes the SAME field, so a tint must be re-asserted on a heartbeat.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local UEHelpers = require("UEHelpers")
local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local ASSETS = require("AnteCore.AssetManager")
local Utils = require("AnteUtils.Utils")
local ENUMS = require("AnteData.Enums")
local LogDebug = Utils.LogDebug
local LogBad = Utils.LogBad

---@class AVU.WorldFX      -- merged onto AVU in AVUtils; the name is what makes goto-def work
local WFX = {}


-- =======================================================================
-- BLIZZARD - the game's own XMAS-snowglobe whiteout, reused as weather.
-- SubFXZone_Blizzard is a REPLICATED volume whose per-client FX (snow niagara re-centred on the
-- local player, 2D audio, camera shake) activate only for players INSIDE it. Purely COSMETIC -
-- no stats, no perception change; gameplay reads the registry below instead.
-- =======================================================================

WFX.BLIZZARD_ZONE_CLASS = "/Game/Blueprints/Environment/Volumes/SubFXZone_Blizzard.SubFXZone_Blizzard_C"
WFX.BLIZZARD_NIAGARA    = ENUMS.Effects.BLIZZARD_WEATHER
-- The zone's BeginPlay also touches these three, and a cold one blocking-loads inside the spawn.
-- EXPOSED so a variant's def.Assets can warm the set too.
WFX.BLIZZARD_SHAKE      = "/Game/Blueprints/Camera/CameraShake_XMASBlizzard.CameraShake_XMASBlizzard_C"
WFX.BLIZZARD_SFX        = "/Game/Audio/Environment/Snowglobe/SC_Blizzard.SC_Blizzard"
WFX.BLIZZARD_SNOWGLOBE  = "/Game/Blueprints/DeployedObjects/Furniture/Deployed_XMAS_Snowglobe.Deployed_XMAS_Snowglobe_C"
WFX.BLIZZARD_ASSETS     = {
    WFX.BLIZZARD_ZONE_CLASS, WFX.BLIZZARD_NIAGARA,
    WFX.BLIZZARD_SHAKE, WFX.BLIZZARD_SFX, WFX.BLIZZARD_SNOWGLOBE,
}

-- Active-blizzard registry (AUTHORITY): what behaviours ask instead of looking at the visuals.
-- Entries expire by FAST_TICK; the prune also drops an UntilTick absurdly far ahead, which is a
-- stale record from a previous world (FAST_TICK resets to 0 on a world change).
local activeBlizzards = {}   -- array of { X, Y, Z, RadiusSq, UntilTick }

function WFX.BlizzardActiveNear(loc)
    if not loc then return false end
    local now = STATE.FAST_TICK or 0
    for i = #activeBlizzards, 1, -1 do
        local b = activeBlizzards[i]
        if now > b.UntilTick or b.UntilTick > now + 1200 then
            table.remove(activeBlizzards, i)
        elseif Utils.DistSq(loc, b) <= b.RadiusSq then
            return true
        end
    end
    return false
end

-- DEDICATED: spawn the replicated zone so joined clients render it. The server has no local
-- player, so the zone's own FX activation early-returns and can't freeze it.
-- Also reachable on a HOST behind SETTINGS.CORE.BLIZZARD_HOST_ZONE (experiment): the old host freeze
-- came from spawning it IN our drain, which the EIGT hop dodges - the residual risk is EIGT
-- flushing mid-paint on a renderer, hence the opt-in flag.
local function spawnBlizzardZone(location, dur, half)
    ASSETS.LoadAsync(WFX.BLIZZARD_ASSETS, function(results)
        local cls = results[WFX.BLIZZARD_ZONE_CLASS]
        if IsNotValid(cls) then LogBad("TriggerBlizzard - zone class not loaded"); return end
        local function doSpawn()
            local gs = UEHelpers.GetGameplayStatics()
            local km = UEHelpers.GetKismetMathLibrary()
            local world = Utils.GetWorld()
            if not gs or not km or IsNotValid(world) then return end
            local xform = km:MakeTransform(location, FRotator(), FVector(1, 1, 1))
            local ok, err = pcall(function()
                local zone = gs:BeginDeferredActorSpawnFromClass(world, cls, xform, 1, nil, 0)
                if IsNotValid(zone) then return end
                zone.nosave = true
                pcall(function() zone.NetDormancy = 1 end)
                pcall(function() zone.FXZoneSize = FVector(half, half, math.min(half, 1200)) end)
                zone = gs:FinishSpawningActor(zone, xform, 0)
                if IsNotValid(zone) then return end
                pcall(function() zone:SetReplicates(true) end)
                pcall(function() zone:Server_TriggerBlizzard(dur) end)
                Utils.QueueWork(function()
                    pcall(function() if IsValid(zone) then zone:K2_DestroyActor() end end)
                end, (dur + 3) * 1000)
            end)
            if not ok then LogBad("TriggerBlizzard zone spawn failed: " .. tostring(err)) end
        end
        Utils.QueueWork(function() ExecuteInGameThread(doSpawn) end, 0)
    end)
end

-- HOST/SP: render the whiteout LOCALLY, doing what the zone does internally - a blizzard niagara
-- centred on each local player inside the storm and re-centred as they move, plus the 2D audio.
-- SpawnLocalNiagara is the proven in-hook-safe primitive (the system is preloaded, so it's a hit).
local function renderLocalWhiteout(location, dur, half)
    if not Utils.HasRenderer() then return end
    local AVU = require("AnteUtils.AVUtils")   -- lazy: AVUtils requires US (merge loop)
    local gs = STATE.GameState
    local players = gs and gs.PlayerCharacterInGame
    if not players then return end
    local radSq = (half * 1.4) * (half * 1.4)
    local endTick = (STATE.FAST_TICK or 0) + dur * 10

    pcall(function()
        local snd = ASSETS.GetIfValid(WFX.BLIZZARD_SFX)
        local gstat = UEHelpers.GetGameplayStatics()
        local world = Utils.GetWorld()
        if IsValid(snd) and gstat and IsValid(world) then
            local comp = gstat:CreateSound2D(world, snd, 0.8, 1.0, 0.0, nil, false, false)
            if IsValid(comp) then
                comp:Play(0.0)
                Utils.QueueWork(function() pcall(function() if IsValid(comp) then comp:Stop() end end) end, dur * 1000)
            end
        end
    end)

    for i = 1, #players do
        local p = players[i]
        local isLocal = false
        pcall(function() isLocal = IsValid(p) and p:IsLocallyControlled() end)
        if isLocal then
            local ploc = p:K2_GetActorLocation()
            if ploc and Utils.DistSq(ploc, location) <= radSq then
                local comp = AVU.SpawnLocalNiagara(ploc, WFX.BLIZZARD_NIAGARA, { Lifetime = dur * 1000 })
                if IsValid(comp) then
                    -- Follow the player; deactivate early if they leave the storm. Lifetime owns
                    -- the destroy.
                    local c = comp
                    local function recenter()
                        if not IsValid(c) or (STATE.FAST_TICK or 0) >= endTick then return end
                        local pl = IsValid(p) and p:K2_GetActorLocation() or nil
                        if pl and Utils.DistSq(pl, location) <= radSq then
                            pcall(function() c:K2_SetWorldLocation(pl, false, {}, false) end)
                            Utils.QueueWork(recenter, 120)
                        else
                            pcall(function() c:Deactivate() end)
                        end
                    end
                    Utils.QueueWork(recenter, 120)
                end
            end
        end
    end
    LogDebug("TriggerBlizzard - local whiteout " .. dur .. "s (radius " .. half .. ")", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- [AUTHORITY] Trigger a WHITEOUT at `location`: register it for gameplay, then render it.
--   * The VISUAL is ROLE-SPLIT (see the two helpers above).
--   * KNOWN GAP: on a LISTEN host, remote clients get no visual - gameplay still works everywhere
--     via the registry.
--   opts: Duration (s, default 10), Size (half-extents, default 2000).

function WFX.TriggerBlizzard(location, opts)
    if not Utils.IsAuthority() or not location then return end
    opts = opts or {}
    local dur = opts.Duration or 10
    local half = opts.Size or 2000

    table.insert(activeBlizzards, {
        X = location.X, Y = location.Y, Z = location.Z,
        RadiusSq = (half * 1.5) * (half * 1.5),   -- gameplay reach a bit past the visual box
        UntilTick = (STATE.FAST_TICK or 0) + dur * 10,
    })

    if STATE.Role == "DEDICATED" or SETTINGS.CORE.BLIZZARD_HOST_ZONE then
        spawnBlizzardZone(location, dur, half)
    else
        renderLocalWhiteout(location, dur, half)
    end
end


-- =======================================================================
-- SCREEN TINT - the real "blackout", via the PLAYER's own post-process component.
-- `PlayerPostProcess.Settings.SceneColorTint` is a flat MULTIPLY over the final image, so pushing
-- it dark dims the scene AND the light pools in one write - which no fog actor achieves. It is
-- per-PLAYER and client-local, so a vignette is not special and there is nothing to restore on a
-- level change.
--   1. Write the SCALAR FIELDS IN PLACE - never assign the whole `Settings` struct back, it is
--      packed with soft-object pointers UE4SS mangles (CLAUDE.md 3).
--   2. RE-ASSERT ON A HEARTBEAT - the damage-flash timeline writes the same field and finishes on
--      white, so one hit would wipe the tint permanently. The beat is deliberately SLOW so the
--      flash still reads as a flash and we simply take the field back afterwards.
-- =======================================================================

WFX.SCREENTINT_DEFAULT = FLinearColor(0.25, 0.25, 0.25, 0.7)
WFX.SCREENTINT_BEAT    = 1000                                -- ms between re-asserts (rule 2)

-- Run fn(player) for each LOCALLY-controlled player character (SP/host = one; splitscreen = more).
local function eachLocalPlayer(fn)
    local gs = STATE.GameState
    local players = gs and gs.PlayerCharacterInGame
    if not players then return end
    for i = 1, #players do
        local p = players[i]
        local isLocal = false
        pcall(function() isLocal = IsValid(p) and p:IsLocallyControlled() end)
        if isLocal then pcall(fn, p) end
    end
end

-- Push a tint onto every LOCAL player's PlayerPostProcess. `on=false` releases the override.
local function applyScreenTint(color, on)
    eachLocalPlayer(function(p)
        local pp
        pcall(function() pp = p.PlayerPostProcess end)
        if IsNotValid(pp) then return end
        pcall(function()
            pp.Settings.SceneColorTint = color
            pp.Settings.bOverride_SceneColorTint = on and true or false
        end)
    end)
end

-- Heartbeat: re-assert until toggled off, and SELF-EXPIRE at a timed tint's deadline.
-- The expiry lives HERE rather than in a separate queued clear, because the beat is the one item
-- guaranteed to be alive for exactly as long as the tint is. os.clock, not FAST_TICK: a world
-- change resets FAST_TICK to 0, which would read as "not expired" for the whole next world.
-- (State lives in STATE, not module locals, so a world reset can't leave the toggle inverted with
-- the beat dead.)
local function screenTintBeat()
    if not STATE.ScreenTintOn then return end
    if STATE.ScreenTintUntil and os.clock() >= STATE.ScreenTintUntil then
        WFX.ClearScreenTint()
        return
    end
    applyScreenTint(STATE.ScreenTintColor or WFX.SCREENTINT_DEFAULT, true)
    Utils.QueueWork(screenTintBeat, WFX.SCREENTINT_BEAT)
end


-- [RENDERER] Darken this machine's screen. `color` = FLinearColor, or a plain number 0..1 as a
-- brightness shorthand. Re-calling re-tunes in place (no second beat).
--   * `seconds` AUTO-CLEARS. Use it for anything event-driven: a raiser that never runs its clear
--     (the player died, portalled out, the event was interrupted) would leave the screen dark with
--     nothing able to reach it. Pass none for the dev toggle, which stays until toggled off.

function WFX.SetScreenTint(color, seconds)
    if not Utils.HasRenderer() then return false end
    if type(color) == "number" then color = FLinearColor(color, color, color, 1) end
    STATE.ScreenTintColor = color or WFX.SCREENTINT_DEFAULT
    STATE.ScreenTintUntil = seconds and (os.clock() + seconds) or nil
    if not STATE.ScreenTintOn then
        STATE.ScreenTintOn = true
        Utils.QueueWork(screenTintBeat, 0)
    else
        applyScreenTint(STATE.ScreenTintColor, true)   -- live re-tune without restarting the beat
    end
    return true
end


-- Release the tint: neutral white AND drop the override, so the game's own writes (the damage
-- flash) own the field again. Safe when no tint is up.

function WFX.ClearScreenTint()
    STATE.ScreenTintOn = false
    STATE.ScreenTintColor = nil
    STATE.ScreenTintUntil = nil
    applyScreenTint(FLinearColor(1, 1, 1, 1), false)
    return true
end


-- Dev toggle. Returns the new state (true = now darkened).

function WFX.ToggleScreenTint(color)
    if not Utils.HasRenderer() then return false end
    if STATE.ScreenTintOn then
        WFX.ClearScreenTint()
        Utils.Log("ScreenTint OFF")
        return false
    end
    WFX.SetScreenTint(color)
    local c = STATE.ScreenTintColor or WFX.SCREENTINT_DEFAULT
    Utils.Log(string.format("ScreenTint ON (%.2f, %.2f, %.2f)",
        c and c.R or 0, c and c.G or 0, c and c.B or 0))
    return true
end


-- =======================================================================
-- CLIENT WARP MIRROR
-- =======================================================================

-- A server-side FX can't be pushed to clients, but POSITION replicates - so a teleport shows up as
-- a one-tick DISCONTINUITY in the actor's location. Draw `fxPath` (+ an optional cue) at the JUMP
-- ORIGIN when the actor moves further than `jumpDist` in one tick (e.g. the Whiteout Sniper's
-- flask puff left where it vanished). Imperfect by design - a net hitch can fake a jump - which is
-- fine for a cosmetic. Renderer-local; defs opt in via ClientTick + OnTick.
--   * `bothEnds` also draws at the ARRIVAL point, for a warp that is meant to read as an entrance
--     as well as an exit (the Flurry Pest retreat) rather than a disappearance (the snipers, which
--     fade back in and must NOT announce where they went). The CUE stays origin-only either way -
--     two glass cracks a few frames apart just reads as a stutter.
-- Weak-keyed by the OnTick wrapper (stable for the life of one registration; freed with it).
local warpMirrorLast = setmetatable({}, { __mode = "k" })   -- OnTick wrapper -> last {X,Y,Z}

function WFX.WarpMirrorTick(actor, fxPath, jumpDist, sfxPath, fxScale, bothEnds)
    local loc
    pcall(function() loc = actor:K2_GetActorLocation() end)
    if not loc then return end
    local last = warpMirrorLast[actor]
    warpMirrorLast[actor] = { X = loc.X, Y = loc.Y, Z = loc.Z }
    if not last then return end
    local dx, dy = loc.X - last.X, loc.Y - last.Y
    local j = jumpDist or 900
    if dx * dx + dy * dy < j * j then return end

    local AVU = require("AnteUtils.AVUtils")   -- lazy: AVUtils requires US (merge loop)
    local origin = FVector(last.X, last.Y, last.Z)
    local s = fxScale or 1
    AVU.SpawnLocalNiagara(origin, fxPath, { Lifetime = 4000, Scale = FVector(s, s, s) })
    -- Safe to spawn the same system twice in a frame: the teardown book is keyed by the COMPONENT's
    -- object path, not the asset's, so these are two independent single-owner entries.
    if bothEnds then
        AVU.SpawnLocalNiagara(FVector(loc.X, loc.Y, loc.Z), fxPath,
            { Lifetime = 4000, Scale = FVector(s, s, s) })
    end
    if sfxPath then
        pcall(function()
            local snd = ASSETS.GetIfValid(sfxPath)
            local gs = UEHelpers.GetGameplayStatics()
            local world = Utils.GetWorld()
            if IsValid(snd) and gs and IsValid(world) then
                gs:PlaySoundAtLocation(world, snd, origin, FRotator(0, 0, 0), 1.0, 1.0, 0.0, nil, nil, nil, nil)
            end
        end)
    end
end


return WFX
