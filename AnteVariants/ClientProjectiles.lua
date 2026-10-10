-- =======================================================================
-- ClientProjectiles (RENDERER) - the LOOK of one of our shots, on a machine that didn't dress it.
--   * A projectile replicates; its dressing does not. The trail is a runtime Niagara component,
--     the hidden bottle a component visibility, the size an actor scale, the spear's heading a
--     mesh rotation. PROJ.Queue applies them on the server; a joined player's copy showed none.
--   * The replicated ROW HANDLE is the shot's identity - every dressed shot flies a row of OURS
--     (AnteCore/ProjectileRows) - and PR.LOOKS says what a row looks like. One table, both ends.
--   * NotifyOnNewObject on the projectile parent, one queued item per shot (never touch the object
--     inside the notify). A native shot reads a row with no look and costs one table read.
--   * The mesh lands by an async load inside the projectile's own BeginPlay and is switched
--     visible when it does, so a hide or a rotation has to FOLLOW it: a short poll, re-finding the
--     shot BY ADDRESS in the engine's actor list each step. A projectile has no EndPlay to stamp,
--     so its wrapper is never held across a wait (the arm hop in AnteCore/Projectile, same reason).
--   * A HOST dresses only the `Native` looks - rows a native gun fires, which no PROJ.Queue dressed
--     on the way out. With none registered, a host never arms the notify at all.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local ASSETS = require("AnteCore.AssetManager")
local PR = require("AnteCore.ProjectileRows")
local Utils = require("AnteUtils.Utils")
local UEHelpers = require("UEHelpers")
local TAP = require("AnteCore.TestTap")   -- AnTest's client suite counts the shots dressed, by row

local Log = Utils.Log
local LogBad = Utils.LogBad
local LogDebug = Utils.LogDebug

local CP = {}

local PARENT = "/Game/Blueprints/Projectiles/AbioticProjectile_ParentBP.AbioticProjectile_ParentBP_C"
local NIAGARA_COMPONENT = "/Script/Niagara.NiagaraComponent"
local STEP_MS = 100
local MAX_STEPS = 30   -- the mesh is normally a frame behind the actor; 3 s covers a cold load

local looks = {}   -- lowercased row name -> PR.LOOKS entry (an FName's casing is not ours to trust)
local said = {}    -- row -> true once this world has logged its first dressing


-- The live actor at `addr`, or nil. The engine supplies the actors of the (pinned) parent class,
-- so no wrapper is held and no by-path walk runs.
local function liveAt(addr)
    local cls = ASSETS.GetIfPinned(PARENT) or ASSETS.GetIfValid(PARENT)
    if not cls then return nil end
    local gs, world = UEHelpers.GetGameplayStatics(), Utils.GetWorld()
    if not gs or IsNotValid(world) then return nil end

    local out = {}
    if not pcall(function() gs:GetAllActorsOfClass(world, cls, out) end) then return nil end
    for i = 1, #out do
        local a = out[i]
        local okg, inner = pcall(function() return out[i]:get() end)
        if okg and inner then a = inner end
        local aAddr
        pcall(function() aAddr = a:GetAddress() end)
        if aAddr == addr then return a end
    end
    return nil
end


-- Has BeginPlay's row-driven mesh load landed? The hide and the rotation wait for it.
local function meshLanded(p)
    local landed = false
    pcall(function()
        local sm = p.SM_Appearance
        if IsValid(sm) and IsValid(sm.StaticMesh) then landed = true; return end
        local sk = p.SK_Appearance
        if IsValid(sk) and IsValid(sk.SkeletalMeshAsset) then landed = true end
    end)
    return landed
end

local function hideMesh(p)
    pcall(function() if IsValid(p.SM_Appearance) then p.SM_Appearance:SetVisibility(false, false) end end)
    pcall(function() if IsValid(p.SK_Appearance) then p.SK_Appearance:SetVisibility(false, false) end end)
    pcall(function() if IsValid(p.ProjectileGlint) then p.ProjectileGlint:SetVisibility(false, false) end end)
end

-- Returns true once the trail is on. False = its asset is not resident yet; try again next step.
local function attachTrail(p, look)
    local fx = ASSETS.GetIfValid(look.Trail)
    local ngClass = ASSETS.GetIfValid(NIAGARA_COMPONENT)
    if not IsValid(fx) or not IsValid(ngClass) then return false end
    pcall(function()
        local ng = p:AddComponentByClass(ngClass, false, FTransform(), false)
        if IsNotValid(ng) then return end
        ng:SetAsset(fx, false)
        local ts = tonumber(look.TrailScale)
        if ts then ng:SetRelativeScale3D(FVector(ts, ts, ts)) end
        local r = look.TrailRot
        if r then ng:K2_SetRelativeRotation(FRotator(r[1], r[2], r[3]), false, {}, false) end
        ng:Activate(true)
    end)
    return true
end


-- One new projectile on this client. Everything runs from the WorkQueue; the notify only queues.
local function onNew(proj)
    if not STATE.ModEnabled or IsNotValid(proj) then return end
    local addr
    pcall(function() addr = proj:GetAddress() end)
    if not addr then return end

    local look, steps = nil, 0
    local scaleDone, trailDone = false, false

    local function step()
        if not STATE.ModEnabled then return end
        steps = steps + 1
        local p = liveAt(addr)
        if not p then return end   -- already gone (a point-blank hit), or nothing to consult

        if not look then
            local row
            pcall(function() row = p.ProjectileDataRowHandle.RowName:ToString() end)
            look = row and looks[row:lower()] or nil
            if not look then
                -- The handle arrives in the actor's first bunch, ahead of this item, so a miss is
                -- a native shot. One more look covers a bunch split across frames.
                if steps < 2 then Utils.QueueWork(step, STEP_MS) end
                return
            end
            if TAP.on then TAP.Count("cpdressed", row:lower()) end
            if not said[row] then
                said[row] = true
                LogDebug("ClientProjectiles - dressing '" .. row .. "' (first this world)", SETTINGS.DEBUG_CLIENT)
            end
        end

        local landed = meshLanded(p)
        if not scaleDone then
            scaleDone = true
            if look.Scale then
                pcall(function() p:SetActorScale3D(FVector(look.Scale, look.Scale, look.Scale)) end)
            end
        end
        if look.Trail and not trailDone then trailDone = attachTrail(p, look) end
        -- Hidden every step until the mesh has landed: the load's own SetVisibility(true) runs
        -- as it lands, and the step that sees it landed is the one after that.
        if look.HideMesh then hideMesh(p) end
        if landed and look.MeshRot then
            pcall(function()
                local sm = p.SM_Appearance
                if IsValid(sm) then
                    sm:K2_SetRelativeRotation(FRotator(look.MeshRot[1], look.MeshRot[2], look.MeshRot[3]),
                        false, {}, false)
                end
            end)
        end

        local pending = (look.Trail and not trailDone) or ((look.HideMesh or look.MeshRot) and not landed)
        if pending and steps < MAX_STEPS then Utils.QueueWork(step, STEP_MS) end
    end
    step()
end


-- Every world, on every renderer (a host: the `Native` looks only). The notify is per UE4SS session
-- (it cannot be removed), so it latches on STATE and is armed once the parent class is resident - a
-- notify on an unloaded class throws. Its callback reads `looks`, so a role change between worlds
-- is picked up here. Trails are pinned so the per-shot resolve is a table read.
function CP.Register()
    if not Utils.HasRenderer() then return end
    local hostOnly = Utils.IsAuthority()

    looks, said = {}, {}
    local pins, n = { PARENT }, 0
    for row, look in pairs(PR.LOOKS) do
        if look.Native or not hostOnly then
            looks[row:lower()] = look
            n = n + 1
            if look.Trail then pins[#pins + 1] = look.Trail end
        end
    end
    if n == 0 then return end
    ASSETS.WarmPinned(pins)

    if STATE.ClientProjNotifyArmed then return end
    ASSETS.LoadAsync({ PARENT }, function()
        if STATE.ClientProjNotifyArmed then return end
        local ok, err = pcall(NotifyOnNewObject, PARENT, function(proj)
            Utils.QueueWork(function() onNew(proj) end, 0)
        end)
        if ok then
            STATE.ClientProjNotifyArmed = true
            Log("ClientProjectiles - notify registered (" .. n .. " looks)")
        else
            LogBad("ClientProjectiles - notify FAILED: " .. tostring(err))
        end
    end)
end

return CP
