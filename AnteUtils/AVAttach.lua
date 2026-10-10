-- =======================================================================
-- AVAttach (AVA) - attachment & subactor helpers split out of AVUtils.
-- AVUtils re-exports these onto AVU (merge loop at the end of AVUtils) so
-- callers keep using AVU.Attach* / AVU.ConfigureSubActor / etc.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local UEHelpers = require("UEHelpers")
local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local ASSETS = require("AnteCore.AssetManager")
local ENUMS = require("AnteData.Enums")
local SCHEMA = require("AnteData.Schema")
local Utils = require("AnteUtils.Utils")
local LogDebug = Utils.LogDebug
local LogBad = Utils.LogBad

-- Forward declaration: defined below SweepOrphanSubactors, which calls it (see THE ORPHAN NET).
local orphanNet

-- Native classes resolve through ASSETS.GetIfValid (StaticFindObject +
-- cache); native "/Script/..." classes are always resident, no load needed
local STATIC_MESH_CLASS = "/Script/Engine.StaticMeshComponent"
local SKELETAL_MESH_CLASS = "/Script/Engine.SkeletalMeshComponent"
local NIAGARA_CLASS = "/Script/Niagara.NiagaraComponent"
local POINT_LIGHT_CLASS = "/Script/Engine.PointLightComponent"

-- Serializes subactor spawns a couple ticks apart (AttachSubactor); a single
-- Carbunccary attaches 3, and we don't want them all in one frame.
local subactorSlot = 0

-- ActorKey (GetFullName) -> { [bone] = niagaraComp } so the same effect isn't attached twice
-- (e.g. a re-run pipeline). Keyed by ActorKey, not the wrapper (see anteup2-actor-wrapper-identity).
-- String keys aren't weak-collectable, so entries outlive their actor - bounded and tiny, and a
-- stale entry self-heals (IsValid check replaces it).
local NiagaraTracker = {}

local function trackerKey(actor)
    return Utils.ActorKey(actor) or actor
end

---@class AVU.Attach          -- merged onto AVU (see AVUtils' SUBMODULE MERGE)
local AVA = {}


-- ---- shared attach boilerplate (used by the Attach* helpers below) ----

-- Resolve an asset arg: a PATH string is re-fetched FRESH via ASSETS.GetIfValid (GC-safe -
-- see the crash notes on AttachNiagara), a live object is accepted as-is. Returns nil if unresolvable.
local function resolveAsset(assetOrPath)
    if type(assetOrPath) == "string" then return ASSETS.GetIfValid(assetOrPath) end
    return IsValid(assetOrPath) and assetOrPath or nil
end

-- Optional slot-0 material override (opts.Material = path or object; resolved fresh, GC-safe).
local function applyMaterialOverride(comp, opts)
    if not opts.Material then return end
    local mat = opts.Material
    if type(mat) == "string" then mat = ASSETS.GetIfValid(mat) end
    if IsValid(mat) then pcall(function() comp:SetMaterial(0, mat) end) end
end

-- Optional material-param tint: the first of Color / AccentColor / Tint / EmissiveColor(+Strength).
--   * Emissive is applied SEPARATELY, on its own axis: it is the `EmissiveIntensity` scalar (the
--     glow master families and the Antelight master use that name, not EmissiveStrength), and
--     brightness is independent of whichever hue param above matched. Required for an
--     opts.Material override whose own graph animates the colour - M_Antelight_RGB exposes
--     EmissiveIntensity and NEITHER EmissiveColor NOR EmissiveStrength, so those two write
--     nothing there and the mesh draws at the material instance's authored brightness.
--   * DiffuseColor is applied SEPARATELY: it's the tint param of a DIFFERENT master,
--     M_AbioticItems_Master (parent of every item/prop mesh - Exor skull, Interfector dagger, Rook
--     shield), which declares no "Color"/"Tint" at all. Its base-colour multiply is `DiffuseColor` x
--     DiffuseIntensity. Values multiply the texture and >1 is legal (the game's own M_InkFish_Rare1
--     ships 15,15,15 to overbrighten), so an off-white texture takes a saturated tint directly.
local function applyComponentColors(comp, opts)
    if opts.DiffuseColor then
        comp:SetVectorParameterValueOnMaterials(FName("DiffuseColor"), opts.DiffuseColor)
    end

    if opts.Emissive then
        comp:SetScalarParameterValueOnMaterials(FName("EmissiveIntensity"), opts.Emissive)
    end

    if opts.Color then
        comp:SetVectorParameterValueOnMaterials(FName("Color"), opts.Color)
    elseif opts.AccentColor then
        comp:SetVectorParameterValueOnMaterials(FName("AccentColor"), opts.AccentColor)
    elseif opts.Tint then
        comp:SetVectorParameterValueOnMaterials(FName("Tint"), opts.Tint)
    elseif opts.EmissiveColor and opts.EmissiveStrength then
        comp:SetScalarParameterValueOnMaterials(FName("EmissiveStrength"), opts.EmissiveStrength)
        comp:SetVectorParameterValueOnMaterials(FName("EmissiveColor"), opts.EmissiveColor)
    end
end


-- SetSubactorScale - scale an attached subactor (deployable or NPC).
--   * Uses the actor's RELATIVE scale: for an attached actor this REPLICATES via
--     AttachmentReplication (RelativeScale3D), so the subactor is the right size on joiners too.
--     Scaling the mesh COMPONENT instead was server-local only.
function AVA.SetSubactorScale(child, scale)
    if Utils.IsActorInvalid(child) then return end
    pcall(function() child:SetActorRelativeScale3D(scale or FVector(1, 1, 1)) end)
end


-- =======================================================================
-- AttachStaticMesh - static mesh component on an actor's mesh at a bone. Returns the comp or nil.
--   * assetOrPath = ENUMS PATH string, resolved FRESH (GC-safe; see the AttachNiagara writeup for
--     why a captured wrapper AVs on SetStaticMesh). A live object is accepted for back-compat.
--   * opts: Location/Rotation/Scale, Material, Color|AccentColor|Tint|EmissiveColor+EmissiveStrength,
--     Emissive (the EmissiveIntensity scalar - its own axis; see applyComponentColors),
--     DiffuseColor (the M_AbioticItems_Master tint - see applyComponentColors; that master has no
--     "Color" param, so item/prop meshes need this one), Collision (off unless set),
--     LocRule/RotRule/ScaleRule (EAttachmentRule, default 2 = keep relative)
-- =======================================================================

-- =======================================================================
-- ATTACH STAGGER - spread a spawn-wave's component attaches across ticks.
--   * A spawner wave doing every variant's AddComponentByClass synchronously in one frame hitches.
--     Actors flagged by AVU.SetStaggerAttach (MutateActor, for spawner-spawned NPCs) spread their
--     attaches via ONE shared, global slot ticker. Everything else (summons, debug, story spawns)
--     attaches immediately since those arrive one at a time anyway.
--   * STAGGERED: every component attach except AttachSubactor - AttachStaticMesh,
--     AttachSkeletalMesh (heaviest: allocates transform data for a whole skeleton), AttachNiagara,
--     AttachPointLight, AttachDecal. All five must be included or a wave still hitches on whichever
--     one is left out.
--   * NOT AttachSubactor: it's a full deferred ACTOR SPAWN whose timing can be load-bearing (e.g.
--     the Big Bot's SpawnDelay=150), not just cosmetic - leave it synchronous.
local attachSlot = 0
local ATTACH_SLOT_SPACING = 2   -- ticks between staggered attaches (~200ms each)
local staggerAttachActors = setmetatable({}, { __mode = "k" })

-- Mark an actor's component attaches to STAGGER (true) vs attach immediately (default/nil).
function AVA.SetStaggerAttach(actor, on)
    if Utils.IsActorValid(actor) then staggerAttachActors[actor] = on and true or nil end
end

-- Claim the next shared slot and run `fn` there. Returns TRUE if it deferred (the caller must then
-- return nil), FALSE to run inline.
--   * opts.Immediate forces the inline path: AVU.AttachShieldShell uses the returned component and
--     retries every tick until it gets one, so a caller that needs the component back synchronously
--     must pass Immediate or it welds a fresh shell on every retry.
local function staggerDefer(actor, opts, fn)
    if opts and opts.Immediate then return false end
    if not staggerAttachActors[actor] then return false end

    attachSlot = math.max(attachSlot, STATE.FAST_TICK) + ATTACH_SLOT_SPACING
    local delayMs = (attachSlot - STATE.FAST_TICK) * 100

    Utils.QueueWork(function()
        -- Killed inside the stagger window: don't decorate a corpse, and don't land after an
        -- OnDeath that already tore the cosmetics down (e.g. EndAttachedNiagara).
        if Utils.IsActorInvalid(actor) then return end
        local dead = false
        pcall(function() dead = actor.IsDead == true end)
        if dead then return end
        fn()
    end, delayMs)
    return true
end

-- The synchronous attach (the original AttachStaticMesh body). Re-resolves the asset by path and
-- re-validates the actor + mesh, so it's safe to run deferred (a tick or more after the call).
-- STATE.LastWork breadcrumbs mark each native step (the CastPsychicBeam pattern) so a freeze
-- inside this function names which call wedged instead of just "attach hung".
local function attachStaticMeshNow(actor, assetOrPath, attachPoint, opts)
    opts = opts or {}

    -- LastWork only - never LastWorkDone, which stays owned by the drain's item-level tracking (a
    -- premature Done=true here would hide a later wedge in the same item).
    STATE.LastWork = "asm:valid"
    if Utils.IsActorInvalid(actor) then return nil end

    STATE.LastWork = "asm:asset"
    local asset = resolveAsset(assetOrPath)
    if not asset then return nil end

    STATE.LastWork = "asm:name"
    local name = Utils.GetActorName(actor)

    -- opts.ToRoot: parent to the CAPSULE instead of the skeletal mesh. The mesh component is
    -- yaw-rotated relative to the actor (the skeleton is authored facing sideways), so a relative
    -- offset on it does not point where the actor faces, and the attachment would also ride the
    -- root bone's animation. Anything meant to sit "in front of the body" wants this - it is where
    -- the game's own front-shield components hang.
    local function attachParent()
        if not opts.ToRoot then return Utils.GetValidMesh(actor) end
        local root
        pcall(function() root = actor:K2_GetRootComponent() end)
        return (not Utils.IsComponentInvalid(root)) and root or nil
    end

    STATE.LastWork = "asm:mesh"
    local mesh = attachParent()
    if not mesh then return nil end

    STATE.LastWork = "asm:class"
    local meshClass = ASSETS.GetIfValid(STATIC_MESH_CLASS)
    if IsNotValid(meshClass) then return nil end

    LogDebug("ASM(1) AddComponent on " .. name, SETTINGS.DEBUG_ATTACHMENTS)
    STATE.LastWork = "asm:addcomp " .. name
    local comp = actor:AddComponentByClass(meshClass, false, FTransform(), false)
    if Utils.IsComponentInvalid(comp) then return nil end

    -- Collision off BEFORE attach/SetStaticMesh (see file header)
    if not opts.Collision then
        comp:SetCollisionEnabled(0)
        comp:SetGenerateOverlapEvents(false)
    end
    comp:SetComponentTickEnabled(false)

    -- Re-validate everything; AddComponentByClass can run BP construction
    if Utils.IsActorInvalid(actor) then return nil end
    if Utils.IsComponentInvalid(comp) then return nil end
    if IsNotValid(asset) then return nil end

    mesh = attachParent()
    if not mesh then return nil end

    LogDebug("ASM(2) Attach+SetMesh on " .. name, SETTINGS.DEBUG_ATTACHMENTS_FULL)

    STATE.LastWork = "asm:attach " .. name
    comp:K2_AttachToComponent(
        mesh,
        FName(opts.ToRoot and "None" or (attachPoint or "root")),
        opts.LocRule or 2,
        opts.RotRule or 2,
        opts.ScaleRule or 2,
        true
    )

    STATE.LastWork = "asm:setmesh " .. name
    comp:SetStaticMesh(asset)
    if Utils.IsComponentInvalid(comp) then return nil end

    applyMaterialOverride(comp, opts)   -- optional slot-0 override (e.g. M_Antelight_RGB rainbow)

    -- Guarded and LOUD: the rotation param is an FRotator, and handing it an FVector throws here.
    -- Bare, that stranded the attach at the raw socket transform with no location, scale or tint
    -- either - which reads in game as "it spawned rotated and Rotation does nothing".
    local placed = pcall(function()
        comp:K2_SetRelativeLocationAndRotation(
            opts.Location or FVector(),
            opts.Rotation or FRotator(),
            false,
            {},
            true
        )
    end)
    if not placed then
        LogBad("AttachStaticMesh - transform write threw on " .. name
               .. " (Location wants an FVector, Rotation an FRotator)")
    end

    comp:SetRelativeScale3D(opts.Scale or FVector(1, 1, 1))

    applyComponentColors(comp, opts)

    if opts.Collision then
        comp:SetCollisionEnabled(opts.Collision)
    end

    LogDebug("ASM(3) Complete on " .. name, SETTINGS.DEBUG_ATTACHMENTS)

    return comp
end

-- Attach a static mesh. opts.ToRoot parents to the capsule rather than the skeletal mesh (see the
-- note in attachStaticMeshNow - it is what makes a relative offset line up with the actor's facing).
-- Immediate by default; spawner-spawned actors (AVU.SetStaggerAttach) spread
-- the attach across ticks (see ATTACH STAGGER). Returns the component on the immediate path only -
-- a deferred attach returns nil, so a caller that needs it back must pass opts.Immediate. The PATH,
-- not a wrapper, crosses the delay: attachStaticMeshNow re-resolves and re-validates (CLAUDE.md S3).
function AVA.AttachStaticMesh(actor, assetOrPath, attachPoint, opts)
    if Utils.IsActorInvalid(actor) then return nil end

    if staggerDefer(actor, opts, function()
        attachStaticMeshNow(actor, assetOrPath, attachPoint, opts)
    end) then return nil end

    return attachStaticMeshNow(actor, assetOrPath, attachPoint, opts)
end


-- AttachSkeletalMesh - like AttachStaticMesh but a SkeletalMeshComponent (armor/helmets/scarves
-- on a bone). Cosmetic -> call from Visuals. assetOrPath resolved fresh (GC-safe, see AttachNiagara).
--   * opts: Location/Rotation/Scale, Color|AccentColor|Tint|EmissiveColor+Strength, Emissive, Material (slot 0),
--     LocRule/RotRule/ScaleRule (default 2).
--   * LeaderPose=true: binds this mesh's pose to the body Mesh so it deforms with the animation -
--     required for body armor sharing the human skeleton. Needs matching bone names; Location/
--     Rotation should be zero (bones map by name).
--   * STAGGERED on spawner-spawned actors (heaviest attach in the set). Pass opts.Immediate for the
--     component back synchronously (AVU.AttachShieldShell does). `_staggered` is internal, marking
--     the deferred re-entry so it runs inline instead of claiming another slot forever.
function AVA.AttachSkeletalMesh(actor, assetOrPath, attachPoint, opts, _staggered)
    opts = opts or {}

    if Utils.IsActorInvalid(actor) then return nil end

    if not _staggered and staggerDefer(actor, opts, function()
        AVA.AttachSkeletalMesh(actor, assetOrPath, attachPoint, opts, true)
    end) then return nil end

    local asset = resolveAsset(assetOrPath)
    if not asset then return nil end

    -- Guard the wrong-asset-type crash: a non-SkeletalMesh (e.g. a USkeleton from a stray
    -- "_Skeleton" path) makes SetSkeletalMeshAsset AV in AllocateTransformData. Reject it here.
    -- Only blocks on a CONFIRMED non-mesh; if the class/IsA check is unavailable, proceed.
    local skMeshAssetClass = ASSETS.GetIfValid("/Script/Engine.SkeletalMesh")
    if IsValid(skMeshAssetClass) then
        local okIsA, isMesh = pcall(function() return asset:IsA(skMeshAssetClass) end)
        if okIsA and not isMesh then
            Utils.LogBad("AttachSkeletalMesh - not a SkeletalMesh asset: " .. tostring(assetOrPath))
            return nil
        end
    end

    local name = Utils.GetActorName(actor)
    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return nil end

    local meshClass = ASSETS.GetIfValid(SKELETAL_MESH_CLASS)
    if IsNotValid(meshClass) then return nil end

    LogDebug("ASK(1) AddComponent on " .. name, SETTINGS.DEBUG_ATTACHMENTS)
    local comp = actor:AddComponentByClass(meshClass, false, FTransform(), false)
    if Utils.IsComponentInvalid(comp) then return nil end

    -- Re-validate (AddComponentByClass can run BP construction)
    if Utils.IsActorInvalid(actor) then return nil end
    if IsNotValid(asset) then return nil end
    mesh = Utils.GetValidMesh(actor)
    if not mesh then return nil end

    comp:K2_AttachToComponent(mesh, FName(attachPoint or "root"),
        opts.LocRule or 2, opts.RotRule or 2, opts.ScaleRule or 2, true)
    if Utils.IsComponentInvalid(comp) then return nil end

    comp:SetComponentTickEnabled(false)
    comp:SetCollisionEnabled(0)
    comp:SetGenerateOverlapEvents(false)

    comp:SetSkeletalMeshAsset(asset)
    if Utils.IsComponentInvalid(comp) then return nil end

    comp:K2_SetRelativeLocationAndRotation(
        opts.Location or FVector(), opts.Rotation or FRotator(), false, {}, true)
    comp:SetRelativeScale3D(opts.Scale or FVector(1, 1, 1))

    -- Drive the pose from the body so body armor deforms with animation.
    --   * Must run after SetSkeletalMeshAsset
    --   * Leader pose binds against the live skeleton
    if opts.LeaderPose then
        pcall(function() comp:SetLeaderPoseComponent(mesh, true, false) end)
    end

    applyMaterialOverride(comp, opts)   -- optional slot-0 override (e.g. M_HexArmor)

    applyComponentColors(comp, opts)

    LogDebug("ASK(4) Complete on " .. name, SETTINGS.DEBUG_ATTACHMENTS)
    return comp
end


-- SwapBodyMesh - replace the actor's MAIN body SkeletalMesh asset in place (a whole-body reskin,
-- NOT an attached extra piece like AttachSkeletalMesh).
--   * assetOrPath resolved FRESH (GC-safe; a freed asset -> SetSkeletalMeshAsset AV / 111GB OOM,
--     see CLAUDE.md S3).
--   * The new mesh MUST share the actor's skeleton (same bone names) or the existing AnimBP drives
--     garbage - e.g. any SK_NPC_Hopper_* onto a Pest (all use SK_NPC_Hopper_Skeleton).
--   * Rejects a non-SkeletalMesh asset (guards the AllocateTransformData AV, same as
--     AttachSkeletalMesh).
--   * Renderer-local (a runtime mesh swap does NOT replicate) -> call from Visuals so SP / host /
--     each client applies it.
function AVA.SwapBodyMesh(actor, assetOrPath)
    if Utils.IsActorInvalid(actor) then return end
    AVA.SwapSkeletalMesh(Utils.GetValidMesh(actor), assetOrPath)
end

-- SwapSkeletalMesh - the same swap on ANY SkeletalMeshComponent, not just the body: the soldier
-- family's `Gun` is one, so this is how you RESKIN A WEAPON.
--   * You cannot TINT a weapon - M_AbioticItems_Master's albedo isn't an exposed param (same dead
--     end as the riot shield); a swap is the only lever. See [[anteup2-order-sniper]].
--   * The new mesh must share the component's skeleton, and carries its OWN material slots - any
--     per-slot work (e.g. AVU.SetGlass on a scope lens) has to run AFTER this, not before.
function AVA.SwapSkeletalMesh(comp, assetOrPath)
    if IsNotValid(comp) then return end

    local asset = resolveAsset(assetOrPath)
    if not asset then
        -- Log it: a silent nil here is indistinguishable from a wrong path, so a def.Assets list
        -- that drifted out of sync with what Visuals asks for reads as "the swap doesn't work".
        LogBad("SwapSkeletalMesh - asset not resident (preload it in def.Assets): " .. tostring(assetOrPath))
        return
    end

    -- Reject a non-SkeletalMesh (a USkeleton from a stray "_Skeleton" path AVs in AllocateTransformData).
    local skMeshAssetClass = ASSETS.GetIfValid("/Script/Engine.SkeletalMesh")
    if IsValid(skMeshAssetClass) then
        local okIsA, isMesh = pcall(function() return asset:IsA(skMeshAssetClass) end)
        if okIsA and not isMesh then
            LogBad("SwapSkeletalMesh - not a SkeletalMesh asset: " .. tostring(assetOrPath))
            return
        end
    end

    pcall(function() comp:SetSkeletalMeshAsset(asset) end)
end

-- SwapStaticMesh - replaces a mesh on a component the actor owns
--   * Re-arming ex: Pillager npcs have one `Weapon_Right` StaticMeshComponent
--   * Renderer-local: Does not replicate so call from Visuals. Path re-resolved FRESH (GC-safe,
--     CLAUDE.md S3): a wrapper captured at mutation can be freed by the time Visuals runs, and
--     SetStaticMesh on a freed asset is an uncatchable AV.
function AVA.SwapStaticMesh(comp, assetOrPath)
    if IsNotValid(comp) then return end

    local asset = resolveAsset(assetOrPath)
    if not asset then
        LogBad("SwapStaticMesh - asset not resident (preload it in def.Assets): " .. tostring(assetOrPath))
        return
    end

    pcall(function()
        comp:SetCollisionEnabled(0)
        comp:SetStaticMesh(asset)
    end)
end


-- =======================================================================
-- AttachNiagara - Niagara system on an actor's mesh at a bone. Returns comp or nil; dedupes per
-- (actor, attachPoint) so a re-run pipeline won't stack effects.
--
-- THE GC-SAFE-ASSET RULE (canonical writeup; the other Attach* helpers reference this):
-- assetOrPath must be the ENUMS PATH string, re-resolved fresh here via ASSETS.GetIfValid - never a
-- wrapper captured back at mutation time. A cached asset can GC between mutation and this
-- (renderer-only) Visuals step; the stale wrapper still passes IsValid while pointing at freed
-- memory, and SetAsset then AVs inside FNiagaraParameterStore::operator= - an uncatchable native
-- crash. A live object is accepted for back-compat; if unresolvable we just skip this pass.
--
--   * opts: Location/Rotation/Scale, AutoActivate (default true), LocRule/RotRule/ScaleRule (default 2)
-- =======================================================================

function AVA.AttachNiagara(actor, assetOrPath, attachPoint, opts, _staggered)
    opts = opts or {}

    if Utils.IsActorInvalid(actor) then return nil end

    -- STAGGERED on spawner-spawned actors (see ATTACH STAGGER). No current caller reads the
    -- returned component - all fire-and-forget, torn down via EndAttachedNiagara - so returning
    -- nil on the deferred path costs nothing.
    if not _staggered and staggerDefer(actor, opts, function()
        AVA.AttachNiagara(actor, assetOrPath, attachPoint, opts, true)
    end) then return nil end

    local asset = resolveAsset(assetOrPath)
    if not asset then return nil end

    local name = Utils.GetActorName(actor)
    local key = attachPoint or "root"

    -- Dedupe: one effect per bone per actor
    local tkey = trackerKey(actor)
    local actorData = NiagaraTracker[tkey]
    if not actorData then
        actorData = {}
        NiagaraTracker[tkey] = actorData
    end
    if actorData[key] and IsValid(actorData[key]) then
        LogDebug("ANIA skipped (already attached) on " .. name, SETTINGS.DEBUG_ATTACHMENTS)
        return actorData[key]
    end

    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return nil end

    local niagaraClass = ASSETS.GetIfValid(NIAGARA_CLASS)
    if IsNotValid(niagaraClass) then return nil end

    LogDebug("ANIA(1) AddComponent on " .. name, SETTINGS.DEBUG_ATTACHMENTS)
    local comp = actor:AddComponentByClass(niagaraClass, false, FTransform(), false)
    if Utils.IsComponentInvalid(comp) then return nil end

    -- Don't fire until fully set up
    comp:SetAutoActivate(false)

    -- Re-validate after AddComponentByClass (can run BP construction)
    if Utils.IsActorInvalid(actor) then return nil end
    if Utils.IsComponentInvalid(comp) then return nil end
    if IsNotValid(asset) then return nil end

    mesh = Utils.GetValidMesh(actor)
    if not mesh then return nil end

    LogDebug("ANIA(2) Attach+SetAsset on " .. name, SETTINGS.DEBUG_ATTACHMENTS_FULL)

    comp:K2_AttachToComponent(
        mesh,
        FName(key),
        opts.LocRule or 2,
        opts.RotRule or 2,
        opts.ScaleRule or 2,
        true
    )
    if Utils.IsComponentInvalid(comp) then return nil end

    comp:SetAsset(asset, false)
    if Utils.IsComponentInvalid(comp) then return nil end

    comp:K2_SetRelativeLocationAndRotation(
        opts.Location or FVector(),
        opts.Rotation or FRotator(),
        false,
        {},
        true
    )
    comp:SetRelativeScale3D(opts.Scale or FVector(1, 1, 1))

    if opts.AutoActivate ~= false then
        comp:Activate(true)
    end

    if Utils.IsComponentValid(comp) then
        actorData[key] = comp
    end

    LogDebug("ANIA(3) Complete on " .. name, SETTINGS.DEBUG_ATTACHMENTS)

    return comp
end


-- EndAttachedNiagara - stop AttachNiagara's system(s) on an actor early (e.g. trailing
-- dust/lightning FX on a ragdoll) before corpse-despawn frees them. Walks the per-actor
-- NiagaraTracker (no FindAllOf), loads nothing (hook/OnDeath-safe). Deactivate (default) lets
-- particles fade; destroy=true pops the component now. RENDERER-LOCAL + non-replicating: calling
-- on the AUTHORITY only tears down the host copy, MP clients keep theirs until corpse despawn.

function AVA.EndAttachedNiagara(actor, destroy)
    if not actor then return end
    -- Must use the SAME key as the attach side, or teardown silently finds nothing and every
    -- attached system leaks (this read was wrapper-keyed too).
    local actorData = NiagaraTracker[trackerKey(actor)]
    if not actorData then return end

    for key, comp in pairs(actorData) do
        local c = comp
        if IsValid(c) then
            pcall(function() c:Deactivate() end)
            if destroy then
                -- Let the fade settle a moment before freeing the component.
                Utils.QueueWork(function()
                    pcall(function() if IsValid(c) then c:K2_DestroyComponent(c) end end)
                end, 1500)
            end
        end
        actorData[key] = nil
    end
end


-- =======================================================================
-- AttachPointLight - PointLightComponent on an actor's mesh at a bone. Cosmetic (renderer-only,
-- non-replicating) -> call from Visuals like AttachNiagara; each renderer spawns its own.
--   * opts: Location/Scale, Color (FLinearColor), Intensity, IndirectIntensity, ScatteringIntensity
--     (volumetric), AttenuationRadius, SourceRadius, UseInverseSquaredFalloff, Shadows (default false),
--     LocRule/RotRule/ScaleRule.
--   * COST: a movable shadow light renders a depth cubemap per frame, so Shadows defaults false -
--     keep AttenuationRadius small and count low (overlaps multiply).
-- =======================================================================
function AVA.AttachPointLight(actor, attachPoint, opts, _staggered)
    opts = opts or {}
    if Utils.IsActorInvalid(actor) then return nil end

    -- STAGGERED on spawner-spawned actors (see ATTACH STAGGER). No caller reads the return.
    if not _staggered and staggerDefer(actor, opts, function()
        AVA.AttachPointLight(actor, attachPoint, opts, true)
    end) then return nil end

    local name = Utils.GetActorName(actor)
    local key = attachPoint or "root"

    local lightClass = ASSETS.GetIfValid(POINT_LIGHT_CLASS)
    if IsNotValid(lightClass) then return nil end

    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return nil end

    LogDebug("APL(1) AddComponent on " .. name, SETTINGS.DEBUG_ATTACHMENTS)
    local comp = actor:AddComponentByClass(lightClass, false, FTransform(), false)
    if Utils.IsComponentInvalid(comp) then return nil end

    -- Re-validate after AddComponentByClass (can run BP construction)
    if Utils.IsActorInvalid(actor) then return nil end
    mesh = Utils.GetValidMesh(actor)
    if not mesh then return nil end

    LogDebug("APL(2) Attach+Set on " .. name, SETTINGS.DEBUG_ATTACHMENTS_FULL)
    comp:K2_AttachToComponent(
        mesh,
        FName(key),
        opts.LocRule or 2,
        opts.RotRule or 2,
        opts.ScaleRule or 2,
        true
    )
    if Utils.IsComponentInvalid(comp) then return nil end

    comp:SetComponentTickEnabled(false)

    -- Shadows OFF unless asked: the depth-cubemap render is the costly part, and a
    -- cosmetic glow light doesn't need cast shadows.
    comp:SetCastShadows(opts.Shadows == true)

    comp:SetLightColor(opts.Color or FLinearColor(1, 1, 1, 1), true)

    comp:K2_SetRelativeLocationAndRotation(opts.Location or FVector(), FRotator(), false, {}, true)
    comp:SetRelativeScale3D(opts.Scale or FVector(1, 1, 1))

    if opts.Intensity then comp:SetIntensity(opts.Intensity) end
    if opts.IndirectIntensity then comp:SetIndirectLightingIntensity(opts.IndirectIntensity) end
    if opts.ScatteringIntensity then comp:SetVolumetricScatteringIntensity(opts.ScatteringIntensity) end
    if opts.AttenuationRadius then comp:SetAttenuationRadius(opts.AttenuationRadius) end
    if opts.SourceRadius then comp:SetSourceRadius(opts.SourceRadius) end
    if opts.UseInverseSquaredFalloff then comp.bUseInverseSquaredFalloff = true end

    LogDebug("APL(3) Complete on " .. name, SETTINGS.DEBUG_ATTACHMENTS)
    return comp
end


-- =======================================================================
-- AttachSubactor - spawn a whole ACTOR (Chopinator deployable, Carbuncle NPC, ...) and attach it to
-- the carrier's mesh at a bone. AUTHORITY ONLY - it's a real replicated actor, so the attachment
-- replicates to clients for free.
--   * ASYNC: STAGGERED (a few ticks each; a Carbunccary attaches 4-5) and, on a DEDICATED server,
--     run off the ProcessSpawns_Quick hook via ExecuteInGameThread - a subactor BeginPlay can
--     blocking-load and a pile of them inline hangs the server (same fix as NpcSpawner). Returns
--     true = "queued once class is loaded", NOT the spawn result.
--   * classPath must be preloaded (put it in the variant's Assets so LoadAssets caches it pre-OnReady).
--   * opts: Location/Rotation/Scale; Chopinator / Turret / (NPC) config flags.
-- =======================================================================
function AVA.AttachSubactor(parent, classPath, attachPoint, opts)
    opts = opts or {}

    if Utils.IsActorInvalid(parent) then return false end

    if IsNotValid(ASSETS.GetIfValid(classPath)) then
        LogBad("AttachSubactor - class not loaded: " .. tostring(classPath))
        return false
    end

    -- The real spawn+attach. Runs on the game thread a few ticks later, so it
    -- re-fetches and re-validates everything (parent/class/world can change).
    local function doAttach()
        if Utils.IsActorInvalid(parent) then return end

        local mesh = Utils.GetValidMesh(parent)
        if not mesh then return end

        local class = ASSETS.GetIfValid(classPath)
        if IsNotValid(class) then return end

        local gameplayStatics = UEHelpers.GetGameplayStatics()
        local kismetMath = UEHelpers.GetKismetMathLibrary()
        local world = Utils.GetWorld()
        if not gameplayStatics or not kismetMath or IsNotValid(world) then return end

        local parentLoc = parent:K2_GetActorLocation()
        local spawnRot = FRotator()

        -- NPC passengers (Rider / Carbuncle): spawn in CLEAR AIR above the carrier, already facing
        -- its way. A capsule spawned INSIDE the carrier's capsule gets depenetrated by the engine -
        -- the carrier "teleported" ~20m forward on spawn. The attach snaps the passenger to the
        -- bone a moment later, so the spawn spot only has to be collision-free.
        local npcPassenger = (opts.Rider or opts.Carbuncle) and true or false
        if npcPassenger then
            parentLoc = FVector(parentLoc.X, parentLoc.Y, parentLoc.Z + 350)
            pcall(function() spawnRot = parent:K2_GetActorRotation() end)
        end

        local transform = kismetMath:MakeTransform(parentLoc, spawnRot, FVector(1, 1, 1))

        LogDebug("spawn-> subactor " .. tostring(classPath), SETTINGS.DEBUG_SPAWN_TRACE)
        local ok, err = pcall(function()
            -- Deferred spawn so nosave/collision are set before BeginPlay. NPC
            -- passenger: CollisionHandlingOverride 1 (AlwaysSpawn, NO adjust) - the
            -- spawn spot is deliberate (clear air above the carrier) and the adjust
            -- would relocate it.
            local child = gameplayStatics:BeginDeferredActorSpawnFromClass(world, class,
                transform, npcPassenger and 1 or 0, nil, 0)
            if IsNotValid(child) then LogBad("AttachSubactor - BeginDeferredActorSpawn gave nothing: " .. tostring(classPath)); return end

            -- nosave MUST be set before ReceiveBeginPlay: the save system registers actors during
            -- init, so post-spawn is too late.
            --   * A saved subactor reloads orphaned (no parent) and can still deal damage.
            child.nosave = true

            -- NPC passenger: neutralize the root capsule BEFORE BeginPlay (QueryOnly + Pawn->Overlap
            -- - see pinWeldedNpc below / AnNotes/AnteSystems/AVAttach.md for why QueryOnly alone isn't enough).
            -- pinWeldedNpc re-asserts this after.
            if npcPassenger then
                local cap = child.CapsuleComponent
                if IsValid(cap) then
                    pcall(function() cap:SetCollisionEnabled(1) end)               -- QueryOnly
                    pcall(function() cap:SetCollisionResponseToChannel(2, 1) end)  -- Pawn -> Overlap
                end
            end

            -- Disc turret: mark broken BEFORE BeginPlay (pre-finish only) - else it briefly
            -- registers as an interactable, triggers an ActionLabel widget, and AutoSettings
            -- throws a C++ exception (missing input action).
            if opts.Turret then
                child.IsBrokenState = true
                child.RequiresPower = true
            end

            child = gameplayStatics:FinishSpawningActor(child, transform, 0)
            if IsNotValid(child) then LogBad("AttachSubactor - FinishSpawningActor gave nothing: " .. tostring(classPath)); return end

            -- BEFORE the first validity check: a welded NPC reads "level not loaded" on a dedicated
            -- server, which is what threw every fresh one away (Utils.SetLevelProxy has the why).
            if npcPassenger then Utils.SetLevelProxy(child, parent) end

            child:K2_AttachToComponent(mesh, FName(attachPoint), 0, 0, 0, true)

            -- Re-validate after attach (BP construction can invalidate either)
            -- Every exit here used to be silent, which made "the subactor never arrived" undiagnosable.
            if Utils.IsActorInvalid(parent) then
                LogBad("AttachSubactor - carrier reads invalid after the spawn; destroying " .. tostring(classPath))
                if Utils.IsActorValid(child) then child:K2_DestroyActor() end
                return
            end
            if Utils.IsActorInvalid(child) then
                local departed, levelLoaded = Utils.IsDeparted(child), "?"
                pcall(function() levelLoaded = tostring(child:IsLevelLoaded(false)) end)
                LogBad(string.format("AttachSubactor - fresh subactor reads invalid (departed=%s, IsLevelLoaded=%s): %s",
                    tostring(departed), levelLoaded, tostring(classPath)))
                return
            end

            child.nosave = true

            local loc = opts.Location or FVector()
            local rot = opts.Rotation or FRotator()
            local hit = {}
            child:K2_SetActorRelativeTransform(FTransform(loc, FVector(), FVector(1, 1, 1)), false, hit, false)
            child:K2_SetActorRotation(rot, false)

            AVA.ConfigureSubActor(child, parent, opts)

            -- The same false reading makes the GAME freeze and hide the body (ParentLevelDeloaded ->
            -- IsDisabled, which replicates). Hand it back; the log says whether this ever bites.
            if npcPassenger then
                pcall(function()
                    if child.ParentLevelDeloaded == true or child.IsDisabled == true then
                        child.ParentLevelDeloaded = false
                        child:CheckForDisabledState()
                        LogDebug("AttachSubactor - welded NPC was natively disabled (level read unloaded); re-enabled: "
                            .. tostring(classPath), SETTINGS.DEBUG_NPC_ACTIONS)
                    end
                end)
            end
        end)
        LogDebug("spawn<- subactor " .. tostring(classPath), SETTINGS.DEBUG_SPAWN_TRACE)
        if not ok then LogBad("AttachSubactor failed - " .. tostring(err)) end
    end

    -- Stagger subactors a couple ticks apart; spawn off-hook on a dedicated server.
    subactorSlot = math.max(subactorSlot, STATE.FAST_TICK) + 2
    local delayMs = (subactorSlot - STATE.FAST_TICK) * 100

    Utils.QueueWork(function()
        if STATE.Role == "DEDICATED" then
            ExecuteInGameThread(doAttach)
        else
            doAttach()
        end
    end, delayMs)

    return true
end


-- =======================================================================
-- THE SUBACTOR BOOK - subactor -> its captured carrier, for SweepOrphanSubactors.
-- STRONG + keyed by Utils.ActorKey (GetFullName), NOT a weak table keyed by wrapper - a weak table
-- relied on the per-subactor tick entry as its only strong ref, and that entry gets dropped often
-- (TickManager, pcall errors, our own "REMOVE"), which silently forgot the subactor and leaked
-- floating invincible Carbuncles. Cleared on world teardown by AVA.ResetSubactorBook - mandatory
-- now that it's strong, or a surviving entry is a freed cross-world pointer.
-- Full rationale: AnNotes/AnteSystems/AVAttach.md - "The subactor book".
-- =======================================================================
-- actorKey -> { sub, carrier (wrappers, read by ADDRESS only), getSub / getCarrier (Utils.CarryActor),
--              char = the sub carries a departed stamp, carrierGone, missing = int }
local subactorCarrier = {}

-- How many consecutive sweeps (5s each) a tracked subactor may read unreadable before we give up
-- on it. Generous on purpose: unreadable is what a streamed-out level looks like, and forgetting
-- one early is precisely the leak above, whereas holding a dead entry costs a table slot.
local SUB_MISSING_LIMIT = 24   -- ~2 minutes


-- Drop the whole book (and the orphan net's strike counts, which are old-world ActorKeys). Called
-- from Utils.ResetState on world teardown - see the banner.
function AVA.ResetSubactorBook()
    subactorCarrier = {}
    AVA.ResetWeldSeats()
    STATE.CarbunclePassengerSeen = false   -- passengers die with their world; the net re-arms on the next weld
    AVA.ResetOrphanStrikes()
end


-- No public "forget this one": every destroy path either holds the key it was filed under, or lets
-- the sweep below notice the dead object next pass. Re-reading GetFullName off a body we just
-- destroyed is exactly the read that can come back nil.


-- Destroy our attached subactors whose carrier is GONE (despawned/destroyed) or DEAD.
-- AUTHORITY-only (the book is populated server-side in ConfigureSubActor; on a client it's
-- empty so this no-ops). The independent backup to the per-subactor self-cleanup tick.
--   * Nothing here dereferences a held wrapper. A shot-off fan carries no departed stamp, and a
--     passenger's or carrier's stamp expires (~30 s) while an entry can sit for minutes: departures
--     are read by address (Utils.IsDeparted), the carrier's remembered once seen, and the bodies
--     themselves come back through their CarryActor getters.
--   * The sub is only resolved when the carrier is gone - a fan on a living bot is never touched.
function AVA.SweepOrphanSubactors()
    for key, rec in pairs(subactorCarrier) do
        if not rec.carrierGone and (Utils.IsDeparted(rec.carrier) or Utils.CarrierDeparted(rec.sub)) then
            rec.carrierGone = true
        end
        if rec.char and Utils.IsDeparted(rec.sub) then
            subactorCarrier[key] = nil          -- the passenger itself left play: nothing to clean
        else
            local carrier = (not rec.carrierGone) and rec.getCarrier() or nil
            local gone = not carrier
            if carrier then pcall(function() gone = carrier.IsDead == true end) end
            if gone then
                local sub = rec.getSub()
                if sub then
                    pcall(function() sub:K2_DestroyActor() end)
                    subactorCarrier[key] = nil
                elseif rec.char then
                    -- A passenger whose level reads unloaded. KEEP IT and destroy it once it streams
                    -- back: dropping it here is how a wandering Carbunccary's passengers used to
                    -- escape tracking for good.
                    rec.missing = (rec.missing or 0) + 1
                    if rec.missing > SUB_MISSING_LIMIT then subactorCarrier[key] = nil end
                else
                    subactorCarrier[key] = nil      -- a non-character no longer at its path: gone
                end
            end
        end
    end

    orphanNet()
end


-- =======================================================================
-- THE ORPHAN NET - last resort, for a welded passenger the book never got to see (spawned before a
-- /reload, key unreadable at spawn, leftover from an old session). Scans for bodies wearing our
-- welded-passenger fingerprint (Invincible + gravity 0 + unattached + untracked, cheapest-first)
-- that nothing else is cleaning up. Two consecutive strikes (NET_EVERY sweeps apart) before it
-- destroys anything - a false positive would delete a passenger off a living carrier.
-- Different from AVA.DestroyOrphanedSubactors below: that's a one-shot FindAllOf a variant fires
-- from its own OnReady; this is periodic, tracked, and carrier-independent.
-- Full rationale: AnNotes/AnteSystems/AVAttach.md - "The orphan net".
-- =======================================================================
local NET_EVERY  = 6       -- sweeps between net passes (5s sweep -> every 30s; 2 strikes -> ~60s)
local NET_RADIUS = 8000    -- 80m around each player
local netCounter = 0

-- Rebuilt from each pass's candidates, so anything that stops qualifying silently loses its strike.
local netStrikes = {}      -- actorKey -> consecutive passes this body has looked orphaned

-- Called by AVA.ResetSubactorBook (world teardown): these are old-world keys.
function AVA.ResetOrphanStrikes()
    netStrikes = {}
end

-- The classes we weld as NPC passengers AND mark Invincible. Keep this list exact: it is the only
-- thing standing between the net and a legitimately spawned NPC of the same class.
local NET_CLASSES = { ENUMS.NpcClasses["Carbuncle"] }

-- (declared at the top of the file - SweepOrphanSubactors above calls it)
--   * Armed only once a passenger has been welded this world (STATE.CarbunclePassengerSeen, set
--     in the Carbuncle branch below, survives /reload, cleared with the book). Before that there
--     is nothing to net, and the class resolve inside GetNearbyActorsOfClass is one full
--     UObject-array walk per pass - two while the class isn't even loaded - which made an idle
--     30 s scanner out of a sweep meant to cost nothing ([[anteup2-ue4ss-findobject-scan-crash]]).
--     Once armed, the class is resident and Pipeline has pinned it (Carbunccary def.Assets), so
--     the resolve is a table read.
function orphanNet()
    if not Utils.IsAuthority() or not STATE.CarbunclePassengerSeen then return end
    netCounter = netCounter + 1
    if netCounter % NET_EVERY ~= 0 then return end

    local gs = STATE.GameState
    local players = gs and gs.PlayerCharacterInGame
    if not players then netStrikes = {} return end

    local AVU = require("AnteUtils.AVUtils")   -- lazy: AVUtils merges THIS file (load-time cycle)
    local seen, killed = {}, 0
    for p = 1, #players do
        local player = players[p]
        local loc
        if IsValid(player) then pcall(function() loc = player:K2_GetActorLocation() end) end
        if loc then
            for c = 1, #NET_CLASSES do
                local hits = AVU.GetNearbyActorsOfClass(loc, NET_RADIUS, NET_CLASSES[c]) or {}
                for i = 1, #hits do
                    local a = hits[i]
                    local okg, inner = pcall(function() return hits[i]:get() end)
                    if okg and inner then a = inner end

                    local key = AVA.IsOrphanPassenger(a)
                    -- Two players in range of the same orphan must not double-strike it.
                    if key and not seen[key] then
                        seen[key] = (netStrikes[key] or 0) + 1
                        if seen[key] >= 2 then
                            pcall(function() a:K2_DestroyActor() end)
                            seen[key] = nil
                            killed = killed + 1
                        end
                    end
                end
            end
        end
    end
    netStrikes = seen

    if killed > 0 then
        Utils.Log("AnteUp2 - orphan net destroyed " .. killed
            .. " untracked welded passenger(s) (see AVAttach: THE ORPHAN NET)")
    end
end


-- This body's ActorKey if it carries our welded-passenger fingerprint and nothing is tracking it,
-- else nil. Returns the KEY (not a bool) since every caller needs it anyway, to strike-count or
-- file it. Split out so any future cleanup command can reuse the exact same test.
function AVA.IsOrphanPassenger(a)
    if Utils.IsActorInvalid(a) then return nil end

    local invincible = false
    pcall(function() invincible = a.Invincible == true end)
    if not invincible then return nil end

    local floating = false
    pcall(function()
        local move = a.CharacterMovement
        if IsValid(move) then floating = tonumber(move.GravityScale) == 0 end
    end)
    if not floating then return nil end

    local parent
    pcall(function() parent = a:GetAttachParentActor() end)
    if IsValid(parent) then return nil end

    local key = Utils.ActorKey(a)
    if not key or subactorCarrier[key] then return nil end   -- tracked = someone else's job
    return key
end

-- =======================================================================
-- Shared pin + collision for WELDED NPC PASSENGERS (Rider + Carbuncle).
--   * Movement: MOVE_None + gravity 0 holds the weld; DefaultLandMovementMode=None makes the NPC's
--     own native restores land back on the pin; DEACTIVATE the component so nothing drives the
--     root between re-asserts (an active CMC at zero gravity = AI-driven free flight).
--   * Capsule: QueryOnly + Pawn->Overlap - QueryOnly alone still blocks the carrier's own movement
--     (CMC moves via sweep queries), so a capsule welded inside the carrier's caused
--     depenetration zooms / wall-climbing. Weapon traces still Block.
--   Full rationale: AnNotes/AnteSystems/AVAttach.md - "ConfigureSubActor branches".
-- =======================================================================
local function pinWeldedNpc(sub)
    if Utils.IsActorInvalid(sub) then return end
    local move = sub.CharacterMovement
    if IsValid(move) then
        pcall(function() move:StopMovementImmediately() end)
        pcall(function() move:SetMovementMode(0, 0) end)   -- MOVE_None
        pcall(function() move.GravityScale = 0 end)
        pcall(function() move:SetAvoidanceEnabled(false) end)
        pcall(function() move.DefaultLandMovementMode = 0 end)
        pcall(function() move:Deactivate() end)
    end
    local cap = sub.CapsuleComponent
    if IsValid(cap) then
        pcall(function() cap:SetCollisionEnabled(1) end)               -- QueryOnly
        pcall(function() cap:SetCollisionResponseToChannel(2, 1) end)  -- Pawn -> Overlap
    end
end

-- Carrier and passenger swept moves ignore each other (Flask Rat MoveIgnore
-- precedent; AddUnique semantics - safe to re-issue).
local function moveIgnorePair(child, parent)
    pcall(function()
        if IsValid(parent.CapsuleComponent) then
            parent.CapsuleComponent:IgnoreActorWhenMoving(child, true)
        end
        if IsValid(child.CapsuleComponent) then
            child.CapsuleComponent:IgnoreActorWhenMoving(parent, true)
        end
    end)
end


-- lockPassengerFacing - hold a welded DECORATIVE passenger (Carbuncle) at its intended
-- BONE-RELATIVE facing. AttachSubactor applies opts.Rotation at attach time, before
-- ConfigureSubActor pins the passenger; in that window the NPC's own CharacterMovement/AI can
-- silently re-orient it. MOVE_None alone isn't enough - bOrientRotationToMovement and
-- bUseControllerRotationYaw must also be cleared, or the re-applied rotation gets stomped again.
-- NOT used for the Jotun rider - a live combatant that must turn to aim.
-- Full rationale: AnNotes/AnteSystems/AVAttach.md - "lockPassengerFacing".
local function lockPassengerFacing(sub, rot)
    if Utils.IsActorInvalid(sub) or not rot then return end

    local move = sub.CharacterMovement
    if IsValid(move) then
        pcall(function() move.bOrientRotationToMovement = false end)
    end
    pcall(function() sub.bUseControllerRotationYaw = false end)
    pcall(function() sub.bUseControllerRotationPitch = false end)
    pcall(function() sub.bUseControllerRotationRoll = false end)

    local hit = {}
    pcall(function() sub:K2_SetActorRelativeRotation(rot, false, hit, false) end)
end


-- =======================================================================
-- THE WELD SEAT - where a welded NPC belongs, in its attach parent's space. Opt-in per subactor.
--   * An attachment keeps whatever offset the body ends up at, and a welded CHARACTER gets
--     moved: the game hands back its movement mode and collision whenever it re-enables the NPC
--     (a level update, an AI unfreeze), and the capsule is then pushed out of its carrier.
--   * The self-cleanup tick checks once a second: past SEAT_DRIFT the body is re-pinned and put
--     back. The Jotun rider does its own, every tick (GK_HeavyHelpers reweldRider).
-- =======================================================================
local weldSeat = {}     -- ActorKey -> { X, Y, Z }
local SEAT_DRIFT = 25

function AVA.SetWeldSeat(sub, loc)
    local key = Utils.ActorKey(sub)
    if not key or not loc then return end
    weldSeat[key] = { X = loc.X, Y = loc.Y, Z = loc.Z }
end

function AVA.ResetWeldSeats() weldSeat = {} end


-- A welded NPC's own level test reads FALSE on a dedicated server (Utils.SetLevelProxy has the
-- why), and the game re-runs that test on EVERY streaming update: ParentLevelDeloaded ->
-- IsDisabled, which switches its sight and hearing off, freezes it, and replicates. One fix at
-- spawn is therefore not enough - the first player to leave and return undoes it.
--   * Only ever called while the carrier reads valid, so "its level is loaded" is already known.
--   * ParentLevelDeloaded alone: an IsDisabled without it is the Director's freeze, not ours.
-- Returns true when it had to step in.
function AVA.KeepWeldedEnabled(sub)
    local fixed = false
    pcall(function()
        if sub.ParentLevelDeloaded == true then
            sub.ParentLevelDeloaded = false
            sub:CheckForDisabledState()
            fixed = true
        end
    end)
    return fixed
end


-- Configure a freshly attached subactor. Split out so it can also be run on an existing subactor.
-- Per-opts branches below: Chopinator (electric fan), disc Turret, Laser grenade, NPC Rider, and
-- Carbuncle passenger.
function AVA.ConfigureSubActor(child, parent, opts)
    local AVU = require("AnteUtils.AVUtils")
    if Utils.IsActorInvalid(child) then return end

    child:SetOwner(parent)
    -- Riders keep their NATIVE faction - their variant syncs the CARRIER onto it instead
    -- (Jotun.lua riderConfigured). The live actor Faction from BeginPlay is the only trustworthy
    -- source; clobbering it here put the whole pair on the carrier's team.
    if not opts.Rider then child.Faction = parent.Faction end

    -- Track for the periodic orphan sweep. Keyed by ActorKey and held STRONGLY, so this book is
    -- genuinely independent of the OnTick entry registered just below - see THE SUBACTOR BOOK.
    local childKey = Utils.ActorKey(child)
    if childKey then
        subactorCarrier[childKey] = {
            sub = child, carrier = parent, missing = 0,
            getSub = Utils.CarryActor(child), getCarrier = Utils.CarryActor(parent),
            char = Utils.StampsDeparture(child),
        }
    else
        -- No key = no tracking, and the tick below is the ONLY thing watching it - the one path
        -- that can still leak; the orphan net catches it later.
        LogBad("ConfigureSubActor - could not key subactor for the orphan sweep")
    end

    -- SELF-CLEANUP: ties the subactor's lifetime to its CARRIER, watched directly (not via
    -- GetOwner/GetAttachParentActor - both give false "orphan" signals). Destroys the subactor when
    -- the carrier is gone/dead or the subactor itself dies. Bails quietly on an unreadable read
    -- (streamed-out level) rather than unregistering - the subactor book's sweep is the backstop.
    -- Full rationale: AnNotes/AnteSystems/AVAttach.md - "The self-cleanup tick".
    local weldedNpc = (opts.Rider or opts.Carbuncle) and true or false
    AVU.RegisterOnTickActor(child, function(sub, ticks)
        if Utils.IsActorInvalid(sub) then return end
        if weldedNpc and ticks % 10 == 0 then
            if AVA.KeepWeldedEnabled(sub) then
                pinWeldedNpc(sub)   -- the re-enable is what hands movement and collision back
                LogDebug("AttachSubactor - welded NPC re-enabled after a level update", SETTINGS.DEBUG_NPC_ACTIONS)
            end
            local seat = childKey and weldSeat[childKey]
            if seat then
                pcall(function()
                    local rel = sub.RootComponent.RelativeLocation
                    local dx, dy, dz = rel.X - seat.X, rel.Y - seat.Y, rel.Z - seat.Z
                    local dsq = dx * dx + dy * dy + dz * dz
                    if dsq <= SEAT_DRIFT * SEAT_DRIFT then return end
                    pinWeldedNpc(sub)
                    sub:K2_SetActorRelativeLocation(FVector(seat.X, seat.Y, seat.Z), false, {}, true)
                    LogDebug(string.format("Welded NPC re-seated (drift %d)", math.floor(math.sqrt(dsq))),
                        SETTINGS.DEBUG_NPC_ACTIONS)
                end)
            end
        end
        local subDead = false
        pcall(function() subDead = sub.IsDead == true end)
        local carrierGone = Utils.CarrierDeparted(sub) or Utils.IsActorInvalid(parent)
        if not carrierGone then pcall(function() carrierGone = parent.IsDead == true end) end
        if carrierGone or subDead then
            -- opts.DeathLingerMs: a subactor that DIES (vs carrier-gone) keeps its corpse welded
            -- for a beat (e.g. the Jotun rider slumping in the saddle) before the destroy.
            -- Drop the book entry by the key captured at spawn, not by re-reading the actor -
            -- GetFullName on a body we're destroying is exactly the read that can come back nil.
            if subDead and not carrierGone and opts.DeathLingerMs then
                Utils.QueueWork(function()
                    if Utils.IsActorValid(sub) then pcall(function() sub:K2_DestroyActor() end) end
                    if childKey then subactorCarrier[childKey] = nil end
                end, opts.DeathLingerMs)
            else
                pcall(function() sub:K2_DestroyActor() end)
                if childKey then subactorCarrier[childKey] = nil end
            end
            return "REMOVE"
        end
    end)

    -- The subactor is welded to a moving bone - turn movement replication OFF, or the server also
    -- streams its absolute world transform, which fights the replicated attachment on clients and
    -- makes the subactor and the bot it's bolted to rapidly shake.
    pcall(function() child:SetReplicateMovement(false) end)

    if opts.Chopinator then
        child.nosave = true
        child.RequiresPower = false
        child.DeployedByPlayer = false
        child.MaxDurability = opts.Durability or 200
        child.CurrentDurability = opts.Durability or 200
        child.DeployableDestroyed = false
        child.IsBrokenState = false
        child:RefreshIsBrokenState()

        -- The body shouldn't collide (it'd shove the carrier around); only the
        -- spinning blade VOLUME should overlap-damage.
        if IsValid(child.FurnitureMesh) then
            child.FurnitureMesh:SetCollisionEnabled(0)
        end

        -- FanBlade (the spinning blade static mesh) ships BLOCKING collision, which snags level
        -- geometry on a moving carrier and stutters it - disable it too. See AnNotes/AnteSystems/AVAttach.md
        -- "ConfigureSubActor branches" for why the server has to do this and not just the client.
        if IsValid(child.FanBlade) then
            child.FanBlade:SetCollisionEnabled(0)
        end

        local blade = child.FanBladeVolume
        if IsValid(blade) then
            blade:SetCollisionEnabled(1)            -- QueryOnly
            blade:SetGenerateOverlapEvents(true)
            blade:SetCollisionResponseToAllChannels(0)
            blade:SetCollisionResponseToChannel(2, 1) -- Pawn -> Overlap
        end

        -- FanFriendlyVolume populates FriendliesInBladeZone (damaged every 0.5s) - disable it so
        -- the Chopinator can't friendly-fire the bot carrying it.
        local friendly = child.FanFriendlyVolume
        if IsValid(friendly) then
            friendly:SetCollisionEnabled(0)
            friendly:SetGenerateOverlapEvents(false)
        end

    -- Disc-turret subactor (Big Bot eye turrets) - cosmetic mount; fires nothing on its own (the
    -- bot's pattern fires discs via Projectile.Queue). It is scenery bolted to a moving fighter,
    -- so it wants no collision, no damage and no interaction at all.
    elseif opts.Turret then
        child.RequiresPower = true
        child.DeployedByPlayer = false
        child.DeployableDestroyed = false
        child.CurrentDurability = 0

        -- Broken + unplugged is what keeps TurretTimerState(false) forever, i.e. the whole reason
        -- these can be aimed without ever arming. Don't "repair" them.
        child.IsBrokenState = true
        child:RefreshIsBrokenState()

        -- WHOLE-ACTOR, not FurnitureMesh alone: TurretRotator ships the blocking `Furniture`
        -- profile and TurretTop a QueryOnly one, and on a mount welded above the shoulders those
        -- are three separate bugs - the carrier's own movement sweep catches them and it jogs on
        -- the spot, its melee sweep (WorldStatic/WorldDynamic, bTraceComplex=false) is EATEN by
        -- them before it reaches the target, and whatever the sweep does catch it damages, since
        -- the robot line's CanMeleeMultiHit skips the hostility filter.
        pcall(function() child:SetActorEnableCollision(false) end)
        moveIgnorePair(child, parent)

        -- Inert: ProcessDamage opens on bCanBeDamaged, and the other two keep it out of the
        -- interact prompt and off NPC obstruction targeting. CanBePackaged doesn't replicate and
        -- the client prompt decides, so the renderer pass re-writes these too.
        pcall(function() child.bCanBeDamaged = false end)
        pcall(function() child.CanBePackaged = false end)
        pcall(function() child.CanBeNPCTarget = false end)

    -- Laser-grenade "turtle shell": a Projectile_Grenade_Laser welded to the carrier's back. Frozen
    -- in place, then native Detonate() fires 8 auto-aiming lasers (~6s) radiating from the weld
    -- point. opts.Damage -> DamageFromWeapon (LaserDamage). Carrier should carry laser immunity
    -- (NpcResistances "Laser" = 0) so its own sweep can't hurt it.
    elseif opts.Laser then
        child.nosave = true

        -- It finishes by trying to drop a "grenade_laser" pickup - suppress it
        pcall(function() child.SpawnImpactItemAfterHit = false end)
        pcall(function() child.SpawnImpactItemIfBuffApplyFails = false end)

        -- Freeze on the bone: no velocity, no bounce, no gravity, and DEACTIVATE
        -- the movement component - otherwise it keeps driving the root each tick
        -- and the grenade trails behind the moving pest instead of staying welded.
        local pm = child.ProjectileMovement
        if IsValid(pm) then
            pcall(function() pm.Velocity = FVector(0, 0, 0) end)
            pcall(function() pm.bShouldBounce = false end)
            pcall(function() pm.ProjectileGravityScale = 0 end)
            pcall(function() pm:StopMovementImmediately() end)
            pcall(function() pm:Deactivate() end)
        end
        -- Kill its own collision so it can't bounce/fuse against the carrier
        if IsValid(child.ProjectileCollision) then
            pcall(function() child.ProjectileCollision:SetCollisionEnabled(0) end)
        end

        -- "Liquid" drives GetLaserDuration (0 -> no lasers, LiquidPerUse=10 ->
        -- full LaserDuration=6s; it maps linearly, so ~8 -> ~5s). opts.Liquid
        -- tunes how long the lasers fire.
        pcall(function()
            child.ChangeableData[SCHEMA.Changeable.LiquidLevel] = opts.Liquid or 10
        end)
        if opts.Damage then pcall(function() child.DamageFromWeapon = opts.Damage end) end

        -- Run the native laser sequence (latent; self-destructs when done)
        pcall(function() child:Detonate() end)

    -- NPC "rider": a live, FIGHTING NPC welded to the carrier (vs the Carbuncle below, a decorative
    -- grabber). pinWeldedNpc holds the weld while keeping it killable, its AI/BT alive, and its
    -- loot. Re-pinned ~250ms later, and must be re-asserted periodically by the variant's own
    -- OnTick - native fire/freeze paths call SetMovementMode themselves (see GK_Heavy.lua
    -- reassertPin).
    elseif opts.Rider then
        pinWeldedNpc(child)
        Utils.QueueWork(function() pinWeldedNpc(child) end, 250)
        moveIgnorePair(child, parent)

    -- Carbuncle "passenger": a live Carbuncle NPC welded to a carrier's bone that auto-tethers
    -- (grabs + slows) nearby players. The grab is fully native and event-driven (CheckTetherOverlaps
    -- over a ~450u capsule) - we don't drive the tick, just freeze MOVEMENT and force Invincible
    -- (the tether gate checks the target player, not the Carbuncle's own targetability, so an
    -- invincible Carbuncle still grabs; it also stops the carrier walking it through a hazard).
    -- Permanent welded decoration, gone only when the carrier dies/despawns.
    -- opts.Carbuncle = { MaxTetherDistance, MaxTetherTime, TetherCooldownTime, Damage(bool) }.
    -- Full rationale: AnNotes/AnteSystems/AVAttach.md - "ConfigureSubActor branches".
    elseif opts.Carbuncle then
        local c = opts.Carbuncle
        STATE.CarbunclePassengerSeen = true   -- arms the orphan net (see orphanNet)
        pcall(function() child.MaxTetherDistance = c.MaxTetherDistance or 800 end)
        pcall(function() child.MaxTetherTime = c.MaxTetherTime or 2 end)
        pcall(function() child.TetherCooldownTime = c.TetherCooldownTime or 7 end)
        pcall(function() child.DamageTargetWhileTethering = c.Damage or false end)

        -- Make it a STUCK, INDESTRUCTIBLE passenger. Invincible via the engine setter (direct-assign
        -- didn't stick, same as HasDroppedLoot). Movement/capsule via the shared pinWeldedNpc.
        -- Applied now and re-applied ~250ms later to beat the Carbuncle's own AI/movement re-init.
        local function pinPassenger(sub)
            if Utils.IsActorInvalid(sub) then return end
            local ksl = UEHelpers.GetKismetSystemLibrary()
            if IsValid(ksl) then pcall(function() ksl:SetBoolPropertyByName(sub, FName("Invincible"), true) end) end
            pcall(function() sub.Invincible = true end)
            Utils.MarkReplicatedDirty(sub, "Invincible")
            pinWeldedNpc(sub)
            -- Re-assert the weld FACING after the pin - see lockPassengerFacing. Runs on both
            -- passes (now + ~250ms).
            lockPassengerFacing(sub, opts.Rotation)
        end
        pinPassenger(child)
        Utils.QueueWork(function() pinPassenger(child) end, 250)
        moveIgnorePair(child, parent)

        AVU.ClearLoot(child)
    end

    -- Scale LAST: the Chopinator branch's RefreshIsBrokenState() rebuilds the deployable and resets
    -- its transform, so an earlier scale write gets clobbered.
    if opts.Scale then AVA.SetSubactorScale(child, opts.Scale) end

    -- Variant-specific follow-up (e.g. the Jotun rider mutates its welded NPC into a
    -- variant + syncs factions). Runs LAST, after the generic config + scale, still on
    -- the same off-hook attach path.
    if opts.OnConfigured then
        local ok, err = pcall(opts.OnConfigured, child, parent)
        if not ok then LogBad("ConfigureSubActor OnConfigured - " .. tostring(err)) end
    end
end


-- CLIENT-side fixups for attached deployable subactors. ConfigureSubActor runs AUTHORITY only and
-- none of it replicates, so a pure client's copy needs move-ignore, collision-off, and fan-spin
-- re-applied locally. CLIENT ONLY - on host/authority the subactor is the real actor (killing its
-- collision would kill server-side contact damage). Full rationale: AnNotes/AnteSystems/AVAttach.md -
-- "Client-side fixups for welded subactors".
function AVA.DisableClientSubactorCollision(parent, attemptsLeft, didSpin)
    if not Utils.IsClient() then return end
    if Utils.IsActorInvalid(parent) then return end
    -- Stop the watchdog once the carrier dies (corpse no longer moves, so no vibration to fix).
    local dead = false
    pcall(function() dead = parent.IsDead end)
    if dead then return end

    attemptsLeft = attemptsLeft or 60
    didSpin = didSpin or false
    local found = false

    for _, a in ipairs(Utils.GetAttachedActors(parent)) do
        local sub = a:get()
        -- FurnitureMesh marks a deployable. Re-disable ALL its collision even if already off -
        -- cheap, and the deployable can re-assert collision on a later replication tick, which is
        -- what made the bot intermittently re-vibrate after a one-shot disable.
        if sub and Utils.IsActorValid(sub) and IsValid(sub.FurnitureMesh) then
            pcall(function() sub:SetActorEnableCollision(false) end)

            -- THE durable vibration fix: on a client the carrier is a simulated proxy whose
            -- CharacterMovement corrects position with a swept move toward the replicated location
            -- while moving. The welded fan's default blocking collision catches that sweep, causing
            -- rapid shake. MoveIgnoreActors (AddUnique) fixes it for good - unlike the collision-off
            -- above, the fan's replication can't re-assert this away. See AnNotes/AnteSystems/AVAttach.md.
            pcall(function()
                if IsValid(parent.CapsuleComponent) then
                    parent.CapsuleComponent:IgnoreActorWhenMoving(sub, true)
                end
                if IsValid(sub.CapsuleComponent) then
                    sub.CapsuleComponent:IgnoreActorWhenMoving(parent, true)
                end
            end)

            -- Fan spin (Chopinator only - FanBlade present). On a client IsPowered reads false
            -- (server's RequiresPower=false doesn't replicate) - force it powered locally and kick
            -- the spin timeline ONCE (TogglePowerFX toggles; per-pass would flicker). Visual only.
            if not didSpin and IsValid(sub.FanBlade) then
                pcall(function() sub.RequiresPower = false end)
                pcall(function() sub:TogglePowerFX() end)
                didSpin = true
            end

            found = true
        end
    end

    -- Retry quickly (30 x 500ms = 15s) to cover a late-replicating fan (laggy join, far spawn),
    -- capped so a genuinely fan-less carrier doesn't retry forever. Once found: a slow watchdog
    -- for the carrier's life so any re-enabled collision gets knocked back down.
    if found then
        Utils.QueueWork(function()
            AVA.DisableClientSubactorCollision(parent, attemptsLeft, didSpin)
        end, 2000)
    elseif attemptsLeft > 0 then
        Utils.QueueWork(function()
            AVA.DisableClientSubactorCollision(parent, attemptsLeft - 1, didSpin)
        end, 500)
    end
end


-- =======================================================================
-- CalmClientNpcPassengers - the NPC-passenger analog of DisableClientSubactorCollision.
-- ConfigureSubActor's pin runs AUTHORITY only and nothing about it replicates, so a pure client's
-- local copy of a welded NPC (Jotun rider, Carbunccary Carbuncles) still runs its own
-- CharacterMovement tick and a default blocking capsule, fighting the replicated attachment while
-- the carrier moves. Re-applies the calm locally, per passenger. Call from the CARRIER variant's
-- Visuals. CLIENT ONLY - on host/authority ConfigureSubActor already did this.
-- =======================================================================
function AVA.CalmClientNpcPassengers(parent, attemptsLeft)
    if not Utils.IsClient() then return end
    if Utils.IsActorInvalid(parent) then return end
    local dead = false
    pcall(function() dead = parent.IsDead end)
    if dead then return end

    attemptsLeft = attemptsLeft or 30
    local found = false

    for _, a in ipairs(Utils.GetAttachedActors(parent)) do
        local sub = a:get()
        -- CharacterMovement marks an NPC passenger (deployables lack it; they're
        -- DisableClientSubactorCollision's department).
        if sub and Utils.IsActorValid(sub) and IsValid(sub.CharacterMovement) then
            pcall(function()
                local move = sub.CharacterMovement
                move.NetworkSmoothingMode = 0   -- Disabled - no interpolation fighting the weld
                move:StopMovementImmediately()
                move:SetMovementMode(0, 0)      -- MOVE_None
                move.GravityScale = 0
                move:Deactivate()
            end)
            pcall(function()
                local cap = sub.CapsuleComponent
                if IsValid(cap) then
                    cap:SetCollisionEnabled(1)                -- QueryOnly
                    cap:SetCollisionResponseToChannel(2, 1)   -- Pawn -> Overlap (local sweeps)
                end
            end)
            moveIgnorePair(sub, parent)
            found = true
        end
    end

    if found then
        Utils.QueueWork(function()
            AVA.CalmClientNpcPassengers(parent, attemptsLeft)
        end, 2500)
    elseif attemptsLeft > 0 then
        Utils.QueueWork(function()
            AVA.CalmClientNpcPassengers(parent, attemptsLeft - 1)
        end, 500)
    end
end


-- =======================================================================
-- AttachDecal - project a decal material onto an actor via a DecalActor on its mesh. Cosmetic ->
-- Visuals; local-only (SetReplicates false) so the host copy doesn't double up with a client's
-- ClientVisuals copy. assetOrPath (decal material) resolved fresh (GC-safe, see AttachNiagara).
--   * opts: Location/Rotation, Size (FVector: X=depth, Y/Z=extent), Color.
-- =======================================================================
local DECAL_CLASS = "/Script/Engine.DecalActor"
function AVA.AttachDecal(actor, assetOrPath, bone, opts, _staggered)
    opts = opts or {}

    if Utils.IsActorInvalid(actor) then return nil end

    -- STAGGERED on spawner-spawned actors (see ATTACH STAGGER). No caller reads the return.
    --   * Must be staggered like the other Attach* calls, or a spawner wave's decals all land in
    --     one frame even though its other attaches are spread out.
    if not _staggered and staggerDefer(actor, opts, function()
        AVA.AttachDecal(actor, assetOrPath, bone, opts, true)
    end) then return nil end

    local asset = resolveAsset(assetOrPath)
    if not asset then LogBad("AttachDecal - invalid material"); return nil end

    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return nil end

    local class = ASSETS.GetIfValid(DECAL_CLASS)
    if IsNotValid(class) then return nil end

    local gameplayStatics = UEHelpers.GetGameplayStatics()
    local kismetMath = UEHelpers.GetKismetMathLibrary()
    local world = Utils.GetWorld()
    if not gameplayStatics or not kismetMath or IsNotValid(world) then return nil end

    local transform = kismetMath:MakeTransform(actor:K2_GetActorLocation(), FRotator(), FVector(1, 1, 1))

    local ok, decal = pcall(function()
        local d = gameplayStatics:BeginDeferredActorSpawnFromClass(world, class, transform, 0, nil, 0)
        if IsNotValid(d) then return nil end
        d.nosave = true
        d:SetReplicates(false)
        d = gameplayStatics:FinishSpawningActor(d, transform, 0)
        if IsNotValid(d) then return nil end

        d:SetOwner(actor)
        d:SetActorEnableCollision(false)

        local comp = d.Decal
        if IsNotValid(comp) then d:K2_DestroyActor(); return nil end

        comp:SetDecalMaterial(asset)
        comp.DecalSize = opts.Size or FVector(8, 32, 32)
        if opts.Color then comp.DecalColor = opts.Color end

        comp:K2_AttachToComponent(mesh, FName(bone or "root"), 0, 0, 0, false)
        local hit = {}
        comp:K2_SetRelativeLocation(opts.Location or FVector(), false, hit, false)
        comp:K2_SetRelativeRotation(opts.Rotation or FRotator(), false, hit, false)
        return d
    end)

    if not ok then LogBad("AttachDecal failed: " .. tostring(decal)); return nil end
    return decal
end


-- =======================================================================
-- MountRider / DismountRider - weld an ALREADY-LIVING NPC onto a carrier, and let it off again.
-- NOT AttachSubactor(Rider): that path SPAWNS the passenger and ties its lifetime to the carrier -
-- wrong for a boss whose second phase must OUTLIVE its mount. Same weld treatment (pinWeldedNpc +
-- moveIgnorePair + SetReplicateMovement(false)) but no spawn, no lifetime link, real release. Pin
-- re-applied ~250ms later and must still be re-asserted from the variant's own OnTick.
--   * opts: Location (bone-relative seat), Scale, Yaw (false = leave facing alone).
--   * SCALE IS RELATIVE: KeepRelative scale makes world scale = carrier * rider, so welding onto a
--     BodyScale-1.5 mount silently scales the rider too. Pass wanted/carrier to land on a chosen size.
-- =======================================================================
function AVA.MountRider(rider, mount, bone, opts)
    opts = opts or {}
    if Utils.IsActorInvalid(rider) or Utils.IsActorInvalid(mount) then return false end

    local mesh = Utils.GetValidMesh(mount)
    if not mesh then return false end

    local ok = pcall(function()
        rider:K2_AttachToComponent(mesh, FName(bone or "Spine1"), 0, 0, 0, true)
        rider:K2_SetActorRelativeLocation(opts.Location or FVector(), false, {}, true)
    end)
    if not ok then return false end
    if Utils.IsActorInvalid(rider) or Utils.IsActorInvalid(mount) then return false end

    -- WORLD-space facing, applied AFTER the attach: the baked relative offset otherwise depends on
    -- whichever way the carrier happened to be facing (the riderConfigured lesson).
    if opts.Yaw ~= false then
        pcall(function()
            local mrot = mount:K2_GetActorRotation()
            rider:K2_SetActorRotation(FRotator(0, mrot.Yaw, 0), false)
        end)
    end

    -- Welded to a MOVING bone, so the server must stop streaming an absolute transform that fights
    -- the (replicated) attachment on clients.
    pcall(function() rider:SetReplicateMovement(false) end)

    -- Relative scale, so it rides AttachmentReplication (FRepAttachment carries RelativeScale3D)
    -- and joiners see the same size.
    if opts.Scale then AVA.SetSubactorScale(rider, opts.Scale) end

    pinWeldedNpc(rider)
    Utils.QueueWork(function() pinWeldedNpc(rider) end, 250)
    moveIgnorePair(rider, mount)
    return true
end


-- Undo the weld's MOVEMENT + COLLISION treatment, leaving attachment alone. Split out because the
-- authority dismount (below) and a client's local undo of its own calmed proxy both need it
-- (attachment replicates, the calm does not). Capsule restores via
-- SetCollisionProfileName("Pawn") rather than hand-restored enum values. MOVE_Falling, not
-- Walking, since the seat sits above the ground and must drop onto it.
function AVA.RestoreRiderMovement(rider)
    if Utils.IsActorInvalid(rider) then return false end

    pcall(function()
        local cap = rider.CapsuleComponent
        if IsValid(cap) then cap:SetCollisionProfileName(FName("Pawn"), true) end
    end)

    pcall(function()
        local move = rider.CharacterMovement
        if IsNotValid(move) then return end
        move:Activate(true)
        move.GravityScale = 1
        move.DefaultLandMovementMode = 1   -- MOVE_Walking, so native restores land on "walk"
        move:SetMovementMode(3, 0)         -- MOVE_Falling -> settles onto the floor
        move:SetAvoidanceEnabled(true)
    end)
    return true
end


-- Release a MountRider'd passenger back into a normal walking NPC (AUTHORITY - it detaches).
--   * Detach KeepWorld on all three rules, so it stays exactly where it was when the mount died -
--     and at the SIZE it was, since KeepWorld scale bakes carrier*relative into its own scale.
--     That is deliberate: a boss shouldn't visibly shrink the moment it steps off.
function AVA.DismountRider(rider, mount)
    if Utils.IsActorInvalid(rider) then return false end

    pcall(function() rider:K2_DetachFromActor(1, 1, 1) end)
    pcall(function() rider:SetReplicateMovement(true) end)
    AVA.RestoreRiderMovement(rider)

    -- Drop the move-ignore pairing while the mount's corpse is still around, or the dismounted
    -- rider walks through it.
    if Utils.IsActorValid(mount) then
        pcall(function()
            if IsValid(mount.CapsuleComponent) then mount.CapsuleComponent:IgnoreActorWhenMoving(rider, false) end
            if IsValid(rider.CapsuleComponent) then rider.CapsuleComponent:IgnoreActorWhenMoving(mount, false) end
        end)
    end
    return true
end


-- Destroy orphaned attached actors (subactors/deployables) of `className` that reloaded without
-- their carrier - they have no attach parent.
--   * `predicate` (optional) further filters eligible actors (e.g. our subactors are
--     RequiresPower=false and not DeployedByPlayer).
--   * Some deployables don't override ReceiveBeginPlay, so a spawn-time scan is the only cleanup
--     hook we get.
function AVA.DestroyOrphanedSubactors(className, predicate)
    local all = FindAllOf(className)
    if not all then return end
    for _, a in ipairs(all) do
        if not Utils.IsActorInvalid(a) and (not predicate or predicate(a)) then
            local ok, parent = pcall(function() return a:GetAttachParentActor() end)
            if ok and (not parent or IsNotValid(parent)) then
                Utils.Log("DestroyOrphanedSubactors: destroying orphaned " .. tostring(className))
                a:K2_DestroyActor()
            end
        end
    end
end


return AVA
