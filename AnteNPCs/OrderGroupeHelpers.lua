-- =======================================================================
-- Groupe silhouette kit - the shared "white spectre" look (Frostpack / Breacher / Rookram /
-- Groupe Sniper / the Interfector's fade). RENDERER-LOCAL, two independent layers:
--   * GRP.Wash - resting ~70% whiteout tint on body + Helmet. Re-assert from Visuals AND
--     OnDamageTaken (damage-stage textures rebuild the mesh materials and drop it).
--   * GRP.FadeOut / FadeIn - opacity fade of the whole silhouette, for blinks and first appearance.
--   * GRP.StormBlink - the whiteout vanish-and-reposition built on those two (Frostpack, Breacher).
-- Material params don't replicate: runs host/SP + each client's own ClientVisuals pass.
-- Gear (Gun/Helmet/backpack) restore must only restore what the body actually had - see
-- gearBase below and AnNotes/AnteNPCs/OrderGroupe.md.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")

local GROUPE_WASH      = FVector(8, 9, 9)   -- resting look (~70% toward blowout)
local GROUPE_FADE_MS   = 500                -- per-step cadence
local GROUPE_FADE_OUT  = { 0.66, 0.33, 0 }  -- solid -> invisible in 3 steps (~1.5s)
local GROUPE_FADE_IN   = { 0.33, 0.66, 1 }  -- reappear
local GROUPE_FADE_HIDE = 0.5                -- gun/helmet/backpack hard-hide below this opacity
local BLINK_HOLD_MS    = 1000               -- default time spent invisible before the hop
local BLINK_Z_LIFT     = 60                 -- navmesh point -> capsule centre (30 clipped feet into slopes)

local GRP = {}

-- Total fade-out duration (ms) - for callers scheduling a reposition at the invisible moment.
GRP.FADE_OUT_MS = #GROUPE_FADE_OUT * GROUPE_FADE_MS


-- The resting bright-white wash on the body mesh + the soldier Helmet (a separate component, so it
-- washes with the body). mul = nil -> resting GROUPE_WASH, else one brighter step (the Ram and
-- Sniper kits run brighter).

function GRP.Wash(actor, mul)
    local vec = mul and FVector(mul, mul, mul * 1.1) or GROUPE_WASH
    AVU.TintMesh(actor, { Color = vec, Emissive = 8 + (mul or 0), Components = { "Helmet" } })
end


-- GEAR BASELINE - "did this body ever HAVE one", per component. Restore has to put back only
-- what the body actually had - a blanket `visible` conjures a rifle on the knife-and-shield
-- Rook chassis (decode: AnNotes/AnteNPCs/OrderGroupe.md). Captured on first touch (always the pre-fade
-- state). Weak by WRAPPER (Conventions 3): a collected entry just re-captures on next touch.
local gearBase = setmetatable({}, { __mode = "k" })

local function hadGear(actor, comp, slot)
    local base = gearBase[actor]
    if not base then base = {}; gearBase[actor] = base end
    if base[slot] == nil then
        local v
        pcall(function() v = comp.bVisible end)
        if v == nil then pcall(function() v = comp:IsVisible() end) end
        base[slot] = (v ~= false)   -- unreadable -> assume it has one (the old behaviour)
    end
    return base[slot]
end


-- Set the WHOLE silhouette's opacity - body via the material, gear via visibility (header).

function GRP.SetOpacity(actor, o)
    AVU.SetMeshOpacity(actor, o)   -- body mesh
    local vis = o >= GROUPE_FADE_HIDE
    pcall(function()
        if IsValid(actor.Gun) then
            -- Read the baseline BEFORE the write, and NEVER inside the `vis and ...` - Lua
            -- short-circuits, so the hide step would skip the capture and the restore step would
            -- then bake in the state we ourselves just set.
            local had = hadGear(actor, actor.Gun, "Gun")
            actor.Gun:SetScalarParameterValueOnMaterials(FName("Opacity"), o)   -- if it supports it
            actor.Gun:SetVisibility(vis and had, false)
        end
        if IsValid(actor.Helmet) then
            actor.Helmet:SetScalarParameterValueOnMaterials(FName("Opacity"), o)
            actor.Helmet:SetVisibility(vis and actor.HasHelmet == true, false)
        end
        if IsValid(actor.backpack) then
            actor.backpack:SetVisibility(vis and actor.HasBackpack == true, false)
        end
    end)
end

-- One queued opacity step every GROUPE_FADE_MS. Each step re-checks validity, so a fade is safe to
-- kick off and then let the actor die mid-fade.
local function groupeSteps(actor, steps)
    for i, o in ipairs(steps) do
        Utils.QueueWork(function()
            if Utils.IsActorValid(actor) then GRP.SetOpacity(actor, o) end
        end, (i - 1) * GROUPE_FADE_MS)
    end
end


-- Fade the silhouette OUT to invisible (~GRP.FADE_OUT_MS total).

function GRP.FadeOut(actor)
    groupeSteps(actor, GROUPE_FADE_OUT)
end


-- Fade IN from invisible (first appearance / end of a blink). Snaps to 0 first, so it always
-- starts fully hidden.

function GRP.FadeIn(actor)
    GRP.SetOpacity(actor, 0)
    groupeSteps(actor, GROUPE_FADE_IN)
end


-- THE WHITEOUT BLINK - fade out, linger invisible, hop to a spot that can see the target, fade
-- back in facing it. Shared by the Frostpack and the Breacher, which differ only in the ring they
-- pick the new perch from.
--   * [AUTHORITY] the hop is a real teleport (an NPC streams nothing, so it is safe in-drain);
--     the fade either side of it is renderer-local material work.
--   * opts: MinDist / MaxDist (ring around the TARGET), HoldMs, Label (debug prefix).
-- Returns false when nowhere with line of sight was found, so the caller can leave its own
-- cooldown alone if it wants a retry.

function GRP.StormBlink(actor, target, opts)
    opts = opts or {}
    local spot = AVU.FindLosPoint(target, {
        Actor = actor, MinDist = opts.MinDist, MaxDist = opts.MaxDist,
    })
    if not spot then return false end

    GRP.FadeOut(actor)

    -- Once fully faded (+ a short hidden linger), hop and fade back in at the new perch.
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        pcall(function()
            actor:K2_SetActorLocation(FVector(spot.X, spot.Y, spot.Z + BLINK_Z_LIFT), false, {}, true)
        end)
        if Utils.IsActorValid(target) then AVU.FaceTarget(actor, target) end
        GRP.FadeIn(actor)
        Utils.LogDebug((opts.Label or "Groupe") .. " - blinked through the whiteout",
            SETTINGS.DEBUG_NPC_ACTIONS)
    end, GRP.FADE_OUT_MS + (opts.HoldMs or BLINK_HOLD_MS))
    return true
end


return GRP
