-- ============================================================
-- ClientFX - client-local cosmetic FX, driven by the server over the chat
-- NetClient RPC (see Utils.SendClientFX).
--
-- Why: server-spawned FX actors don't replicate to clients, and there's no clean
-- side-effect-free client RPC. The chat RPC (Local_DisplayTextChatMessage) IS
-- reliable and reaches the exact client, so the server sends an EMPTY message
-- with the payload packed into the two FLinearColor params (nothing renders in
-- chat). We hook that function, detect our sentinel, decode the colors, and play
-- the Niagara + sound locally.
--
-- Registered on any machine with a renderer: host/SP (main.lua InitMod) and
-- clients (main.lua ClientBootstrap). The dedicated server has no renderer and
-- never registers it.
--
-- Payload (in the colors):
--   PrefixColor  = { R=X, G=Y, B=Z, A = keyIndex*10000 + seconds }
--   MessageColor = { R = Utils.FX_SENTINEL, ... }
-- ============================================================

---@diagnostic disable: undefined-field, undefined-global, unused-local, param-type-mismatch

local Utils  = require("Utils.Utils")
local Assets = require("Utils.AssetManager")
local Enums  = require("Data.Enums")

local CFX = {}

local CHAT_DISPLAY = "/Game/Blueprints/Meta/Abiotic_PlayerController.Abiotic_PlayerController_C:Local_DisplayTextChatMessage"

-- Effect key -> effect definition. Keys must line up with Utils.FX_KEYS
-- (index order) on the server.
--   fx      Niagara system path
--   sound   optional looping sound path
--   drift   default uu of forward travel over the effect's life (see driftComp)
local EFFECTS = {
    -- PORTAL_SALEM is the loop AnteUp uses for its own GK rift - same doorway, same
    -- sound on a machine running both. (Was PORTAL_SHADOWGATE.)
    GK_PORTAL  = { fx = Enums.FX.PORTAL_DOOR,            sound = Enums.SOUNDS.PORTAL_SALEM,      drift = 100 },
    NIGHTREALM = { fx = Enums.FX.PORTAL_NIGHTREALM_DOOR, sound = Enums.SOUNDS.PORTAL_NIGHTREALM, drift = 100 },
    RAT_PORTAL = { fx = Enums.FX.PORTAL_FRIENDLY,        drift = 0 },  -- radially symmetric; pin it
}


-- ============================================================
-- driftComp - walk a live component from `from` to `to` over `ms`.
--
-- Gives the doorway a slow forward slide, so it reads as a gate advancing on
-- the base rather than a decal hanging in the air. Paired with the yaw, the
-- portal drifts through its own face while bodies step out of it - the
-- "printing an NPC" look.
--
-- THE WRAPPER IS CAPTURED, deliberately. Re-resolving the component per step
-- would mean a StaticFindObject per step, and on this UE4SS build that is a full
-- UObject-array walk (~20-30 ms) with a small per-walk chance of tripping over a
-- dangling Outer and AVing. A drifting portal would be paying that dozens of
-- times for a cosmetic slide. AnteUp's driftComponent captures for the same reason.
-- Two rules make the capture safe:
--   * a generation token, bumped when the caller tears the component down, so a
--     superseded chain stops instead of touching freed memory
--   * we stop one full step BEFORE the teardown fires, never on the same beat
--
-- STEP BUDGET: steps scale with the DISTANCE, not the lifetime, so a 100 uu slide
-- costs ~10 moves however long the portal hangs around - no free-running timer.
-- Each step is one property-set ProcessEvent plus a thread hop; nothing resolves,
-- nothing loads.
-- ============================================================
local DRIFT_UU_PER_STEP = 10     -- ~10 cm per hop: smooth enough on a portal plane
local DRIFT_MAX_STEPS   = 24     -- hard ceiling regardless of distance
local DRIFT_MIN_STEP_MS = 150    -- never schedule faster than this

local function driftComp(comp, genRef, from, to, ms)
    local gen = genRef.gen

    local dx = (to.X or 0) - (from.X or 0)
    local dy = (to.Y or 0) - (from.Y or 0)
    local travel = math.sqrt(dx * dx + dy * dy)
    if travel < 1 then return end

    -- Budget by distance, then spread those steps over the effect's life, stopping
    -- one step short of the teardown.
    local usable = ms - DRIFT_MIN_STEP_MS
    if usable < DRIFT_MIN_STEP_MS then return end

    local steps = math.min(DRIFT_MAX_STEPS,
                           math.max(1, math.floor(travel / DRIFT_UU_PER_STEP)),
                           math.floor(usable / DRIFT_MIN_STEP_MS))
    if steps < 1 then return end

    local stepMs = math.max(DRIFT_MIN_STEP_MS, math.floor(usable / steps))

    local function step(i)
        if genRef.gen ~= gen then return end          -- torn down or superseded
        if not comp or not IsValid(comp) then return end

        local t = i / steps
        pcall(function()
            -- K2_SetWorldLocation's FHitResult out-param is NOT optional: omit
            -- it and the whole call is a silent no-op.
            comp:K2_SetWorldLocation(
                FVector((from.X or 0) + dx * t, (from.Y or 0) + dy * t, from.Z or 0),
                false, {}, true)
        end)

        if i < steps then
            Utils.DelayedGameThread(stepMs, function() step(i + 1) end)
        end
    end

    Utils.DelayedGameThread(stepMs, function() step(1) end)
end


-- yaw  = which way the doorway faces (degrees). The Niagara is a flat plane and
--        is invisible edge-on, so this matters on every portal.
-- drift = uu travelled along yaw over the effect's life; nil takes the registry
--        default, 0 pins it.
local function playFX(x, y, z, key, seconds, yaw, drift)
    local def = EFFECTS[key] or EFFECTS.GK_PORTAL
    if not def or not def.fx then return end
    local loc = FVector(x, y, z)
    -- seconds is decoded from a color (a float); floor to an integer so the
    -- delay math (and ExecuteWithDelay) stay integer-typed.
    local ms  = math.floor(math.max(1, seconds or 10)) * 1000

    -- Start half the travel AHEAD of the sent point and end half behind it, so
    -- the anchor stays the middle of the slide.
    local travel = drift or def.drift or 0
    local startLoc, endLoc = loc, nil
    if travel > 0 then
        local r  = math.rad(yaw or 0)
        local hx = math.cos(r) * travel * 0.5
        local hy = math.sin(r) * travel * 0.5
        startLoc = FVector(loc.X + hx, loc.Y + hy, loc.Z)
        endLoc   = FVector(loc.X - hx, loc.Y - hy, loc.Z)
    end

    -- Clean game-thread flush point. We hold the Niagara + (looping) sound
    -- components and DESTROY them when the portal closes: Deactivate()/Stop()
    -- alone left hard-looping portals and sounds running in SP/host.
    ExecuteInGameThread(function()
        local fxComp, sndComp
        local genRef = { gen = 1 }

        -- No `duration` here - we own the cleanup below (so SpawnEffect doesn't
        -- also schedule its own deactivate).
        pcall(function()
            fxComp = Utils.SpawnEffect(startLoc, def.fx, {
                scale    = FVector(1.2, 1.2, 1.2),
                rotation = FRotator(0, yaw or 0, 0),
            })
        end)

        -- The sound stays put: separate component, own teardown, and a metre of
        -- slide is inaudible through the cue's attenuation.
        if def.sound then
            pcall(function() sndComp = Utils.SpawnSound(def.sound, loc) end)
        end

        if fxComp and endLoc then
            driftComp(fxComp, genRef, startLoc, endLoc, ms)
        end

        Utils.DelayedGameThread(ms, function()   -- component teardown: game thread only
            genRef.gen = genRef.gen + 1     -- stop any drift step still pending
            if fxComp and IsValid(fxComp) then
                pcall(function() fxComp:Deactivate() end)
                pcall(function() fxComp:DestroyComponent(false) end)
            end
            if sndComp and IsValid(sndComp) then
                pcall(function() sndComp:Stop() end)
                pcall(function() sndComp:DestroyComponent(false) end)
            end
        end)
    end)
end


function CFX.Register()
    -- Pre-warm the assets. SpawnEffect/SpawnSound both resolve through the
    -- non-loading GetIfValid, so anything not resident is silently skipped -
    -- without this the FIRST portal of a session has no visual and no audio.
    for _, def in pairs(EFFECTS) do
        if def.fx    then Assets.Warm(def.fx)    end
        if def.sound then Assets.Warm(def.sound) end
    end

    RegisterHook(CHAT_DISPLAY,
        function(self, Prefix, PrefixColor, MessageToReceive, MessageColor, PlayerState, IsPlayerChatTextMessage)
            pcall(function()
                -- Is this one of ours? Sentinel lives in MessageColor.R (real chat
                -- colors are 0..1, so an out-of-range value can't be a real message).
                local mc = MessageColor and MessageColor:get()
                if not mc then return end
                local r = mc.R
                if not r or math.abs(r - Utils.FX_SENTINEL) > 0.5 then return end

                local d = PrefixColor and PrefixColor:get()
                if not d then return end
                local x, y, z, a = d.R, d.G, d.B, d.A
                if not (x and y and z and a) then return end

                local keyIdx = math.floor(a / 10000)
                local secs   = a - keyIdx * 10000
                local key    = Utils.FX_KEYS[keyIdx] or "GK_PORTAL"

                -- The sentinel's spare channels: G = yaw, B = drift.
                -- B < 0 means the sender didn't specify one (an old server, or
                -- a caller that wants the registry default); B == 0 pins it.
                local yaw   = mc.G or 0
                local drift = (mc.B and mc.B >= 0) and mc.B or nil

                playFX(x, y, z, key, secs, yaw, drift)
            end)
        end)

    Utils.Log("client FX channel registered")
end

return CFX
