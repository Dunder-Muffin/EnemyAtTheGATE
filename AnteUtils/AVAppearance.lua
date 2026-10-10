-- =======================================================================
-- AVAppearance (AP) - how an NPC LOOKS and SOUNDS. Split out of AVUtils, merged back onto AVU:
-- callers still write AVU.TintSlot / SetHelmet / SetMeshOpacity / ...
--
-- MUST-KNOWS
--   * RENDERER-LOCAL, all of it. Material/mesh/audio writes never replicate - call from Visuals,
--     and ClientVisuals re-runs them per client. They no-op on a dedicated server.
--   * Resolve assets by PATH at use-time (ASSETS.GetIfValid), never a wrapper captured at
--     mutation - a freed one still passes IsValid and crashes the setter (CLAUDE.md 3).
--   * A material param the master doesn't own is a SILENT no-op, which is why one call can set
--     both the CHARACTER and ITEM master names.
--   * Use AVU.TintSlot on any multi-slot mesh; TintComponent/TintMesh SPRAY every slot.
--   * Deep decode (helmet masters, the merged modular bodies, gradient params): AnNotes/AnteSystems/AVUtils.md.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local ASSETS = require("AnteCore.AssetManager")
local Utils = require("AnteUtils.Utils")
local ENUMS = require("AnteData.Enums")
local SCHEMA = require("AnteData.Schema")
local LogDebug = Utils.LogDebug
local LogBad = Utils.LogBad

---@class AVU.Appearance      -- merged onto AVU in AVUtils; the name is what makes goto-def work
local AP = {}


-- =======================================================================
-- AUDIO
-- =======================================================================

-- The NPC's persistent audio components. K2_GetComponentsByClass is avoided here: it hands
-- elements back as RemoteUnrealParams that IsValid can't take.
local SILENCE_AUDIO_COMPS = { "BreathingAudio", "CharacterVoiceAudio", "Audio" }

-- [RENDERER] Silence an NPC's looping vocal/ambient audio (a "shade").
--   * Mutes the persistent components + nils the breathing SFX; re-applied once on a delay to
--     catch components created during spawn-in.
--   * One-shot positional SFX (footsteps, impacts) aren't component-routed, so they survive.

function AP.SilenceActor(actor)
    if Utils.IsActorInvalid(actor) then return end
    pcall(function() actor.SFX_Breathing_Idle = nil end)
    pcall(function() actor.SFX_Breathing_Combat = nil end)

    local function muteAll()
        if Utils.IsActorInvalid(actor) then return end
        for _, name in ipairs(SILENCE_AUDIO_COMPS) do
            pcall(function()
                local c = actor[name]
                if IsValid(c) then c:SetVolumeMultiplier(0); c:Stop() end
            end)
        end
    end
    muteAll()
    Utils.QueueWork(muteAll, 2000)   -- catch components created during spawn-in
end


-- [AUTHORITY] Mute an NPC's DEATH rattle only, leaving idle/pain/aggro lines intact.
--   Server picks the line via multicast, so clearing the arrays on authority silences all clients.
--   NPCData is per-actor: only this body is muted. Covers both death lists and NPCVoiceData.
--   Useful for bulk-death summons, where one shared death sound firing 5x sounds like drilling.

function AP.MuteDeathVoice(actor)
    if Utils.IsActorInvalid(actor) then return end

    local npcData = actor.NPCData
    if IsValid(npcData) then
        local lines = npcData[ENUMS.NpcData.VoiceLines]
        if IsValid(lines) then
            pcall(function() lines[ENUMS.NpcVoiceLines.NormalDeath]:Empty() end)
            pcall(function() lines[ENUMS.NpcVoiceLines.ScreamingDeath]:Empty() end)
        end
    end

    pcall(function() actor.NPCVoiceData.DeathNormal:Empty() end)
    pcall(function() actor.NPCVoiceData.DeathExplosive:Empty() end)
end


-- =======================================================================
-- OVERLAY MATERIALS - an extra pass drawn OVER the mesh, base textures kept
-- =======================================================================

-- [RENDERER] Overlay material onto the actor's body mesh (e.g. the Reaper's shadow shimmer).

function AP.SetOverlayMaterial(actor, matPath)
    if Utils.IsActorInvalid(actor) or not matPath then return end
    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return end
    local mat = ASSETS.GetIfValid(matPath)
    if IsNotValid(mat) then return end
    pcall(function() mesh:SetOverlayMaterial(mat) end)
end


-- [RENDERER] Overlay material onto a SPECIFIC component (an NPC's Gun / Helmet), not the body.

function AP.SetComponentOverlay(comp, matPath)
    if IsNotValid(comp) or not matPath then return end
    local mat = ASSETS.GetIfValid(matPath)
    if IsNotValid(mat) then return end
    pcall(function() comp:SetOverlayMaterial(mat) end)
end


-- [RENDERER] Clear any overlay layer. Passing nullptr is how the game clears a weapon coating.

function AP.ClearOverlayMaterial(actor)
    if Utils.IsActorInvalid(actor) then return end
    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return end
    pcall(function() mesh:SetOverlayMaterial(nil) end)
end


-- [RENDERER] The overlay as a DYNAMIC instance (MID) so its params can be animated later.
-- Returns the MID (hold it - there is no GetOverlayMaterial to read it back) or nil.

local kismetMaterialLib

function AP.SetOverlayMaterialDynamic(actor, matPath)
    if Utils.IsActorInvalid(actor) or not matPath then return nil end
    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return nil end
    local mat = ASSETS.GetIfValid(matPath)
    if IsNotValid(mat) then return nil end
    if IsNotValid(kismetMaterialLib) then
        kismetMaterialLib = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
    end
    if IsNotValid(kismetMaterialLib) then return nil end
    local world = Utils.GetWorld()
    if IsNotValid(world) then return nil end

    local mid
    pcall(function()
        mid = kismetMaterialLib:CreateDynamicMaterialInstance(world, mat, FName(""), 0)
        if IsValid(mid) then mesh:SetOverlayMaterial(mid) end
    end)
    return IsValid(mid) and mid or nil
end


-- [RENDERER] Paint the game's WEAPON-COATING gradient onto a body mesh (the glowing, pulsing
-- look the coating items give a weapon - nothing about it is weapon-specific).
--   * Base material must be RESIDENT (preload ENUMS.Components.M_WEAPON_COATING).
--   * opts: Color (GradientDirection, doubles as the hue) / Bias .5 / Contrast 1 /
--     PulseIntensity .5 (0 = steady) / PulseSpeed 1 / Masked / Material (override path).
--   * Returns the MID.

function AP.ApplyGradientMaterial(actor, opts)
    if Utils.IsActorInvalid(actor) then return nil end
    opts = opts or {}
    local matPath = opts.Material or ENUMS.Components.M_WEAPON_COATING
    local mid = AP.SetOverlayMaterialDynamic(actor, matPath)
    if not mid or IsNotValid(mid) then
        -- Name the failure: not resident = preload missed / wrong path; resident + nil MID = the
        -- MID creation itself failed.
        LogBad("ApplyGradientMaterial - no overlay MID. material resident=" ..
            tostring(IsValid(ASSETS.GetIfValid(matPath))) .. " path=" .. tostring(matPath))
        return nil
    end
    pcall(function()
        mid:SetScalarParameterValue(FName("FirstPerson"), 0)          -- third-person mesh
        mid:SetScalarParameterValue(FName("MaskedTexture"), opts.Masked and 1 or 0)
        if opts.Color then mid:SetVectorParameterValue(FName("GradientDirection"), opts.Color) end
        mid:SetScalarParameterValue(FName("GradientBias"), opts.Bias or 0.5)
        mid:SetScalarParameterValue(FName("GradientContrast"), opts.Contrast or 1.0)
        mid:SetScalarParameterValue(FName("PulseIntensity"), opts.PulseIntensity or 0.5)
        mid:SetScalarParameterValue(FName("PulseSpeed"), opts.PulseSpeed or 1.0)
    end)
    return mid
end


-- =======================================================================
-- TINTING - whole component (sprays every slot) vs ONE slot (AP.TintSlot)
-- =======================================================================

-- MID setters take an FLinearColor; the ...OnMaterials setters take an FVector. Every per-slot
-- path converts, so the whole-component path never has to.
local function toLinearColor(v)
    if not v then return nil end
    local x
    pcall(function() x = v.X end)
    if x == nil then return v end   -- already an FLinearColor
    local y, z = 0, 0
    pcall(function() y = v.Y or 0; z = v.Z or 0 end)
    return FLinearColor(x, y, z, 1)
end


-- [RENDERER] Tint a mesh COMPONENT's material params - EVERY slot (see AP.TintSlot for one).
-- Sets both master families' names, so one call covers body meshes and item attachments.
--   Color / Tint    FVector base colour multiply (>1 brightens, <1 darkens)
--   DiffuseColor    the same multiply on M_AbioticItems_Master (weapons, props, shields), which
--                   declares no Color/Tint at all. Its own write, so one call can carry both.
--   Emissive        scalar glow      EmissiveColor  FVector glow hue (independent of Emissive)
--   EmScale         EmissiveStrength/EmissiveIntensity ratio (default 3)
--   EmissiveMultiply  the items master's SECOND glow scalar - it multiplies EmissiveIntensity, so
--                   a glow that has to read against scene lighting usually wants both
--   Metallic        scalar - "cloth dyed yellow" vs "gold"

function AP.TintComponent(comp, opts)
    if IsNotValid(comp) then return end
    opts = opts or {}
    pcall(function()
        if opts.DiffuseColor then
            comp:SetVectorParameterValueOnMaterials(FName("DiffuseColor"), opts.DiffuseColor)
        end
        if opts.Color then
            comp:SetVectorParameterValueOnMaterials(FName("Color"), opts.Color)
            comp:SetVectorParameterValueOnMaterials(FName("Tint"), opts.Color)
        end
        if opts.Emissive then
            comp:SetScalarParameterValueOnMaterials(FName("EmissiveIntensity"), opts.Emissive)
            comp:SetScalarParameterValueOnMaterials(FName("EmissiveStrength"), opts.Emissive * (opts.EmScale or 3))
        end
        if opts.EmissiveMultiply then
            comp:SetScalarParameterValueOnMaterials(FName("EmissiveMultiplier"), opts.EmissiveMultiply)
        end
        if opts.Metallic then
            comp:SetScalarParameterValueOnMaterials(FName("Metallic"), opts.Metallic)
        end
        local emColor = opts.EmissiveColor or (opts.Emissive and FVector(1, 1, 1) or nil)
        if emColor then
            comp:SetVectorParameterValueOnMaterials(FName("EmissiveColor"), emColor)
        end
    end)
end


-- [RENDERER] Tint an actor's BODY mesh, plus any GEAR components named in opts.Components.
-- `Components` takes two forms:
--   ARRAY  { "Helmet", "Shield" }        tint these with the body's own opts.
--   MAP    { Helmet = {Color=...} }      per-component opts (what a def.Tint usually wants).
-- A map entry with `Slot` routes to AP.TintSlot (one slot, writes DiffuseColor); without one it
-- routes to AP.TintComponent (every slot). See those two for the full opts.
-- `actor.Helmet` THROWS on a class with no such property, so the field read (not the tint) needs
-- the pcall - AP.TintComponent/TintSlot are already internally guarded.

local function tintNamedComponent(actor, name, opts)
    local comp
    if not pcall(function() comp = actor[name] end) then return end
    if IsNotValid(comp) then return end
    if opts.Slot ~= nil then AP.TintSlot(comp, opts.Slot, opts)
    else AP.TintComponent(comp, opts) end
end

function AP.TintMesh(actor, opts)
    if Utils.IsActorInvalid(actor) then return end
    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return end
    AP.TintComponent(mesh, opts)

    local comps = opts and opts.Components
    if type(comps) ~= "table" then return end
    for _, name in ipairs(comps) do              -- array form: the body's own opts
        tintNamedComponent(actor, name, opts)
    end
    for name, sub in pairs(comps) do             -- map form: per-component opts
        if type(name) == "string" and type(sub) == "table" then
            tintNamedComponent(actor, name, sub)
        end
    end
end


-- Resolve a material-SLOT argument (name or index) to an index, nil if the mesh has no such slot.
-- Prefer NAMES at call sites - an index moves when a mesh is re-authored, a name doesn't
-- (`/dumpmat` prints both). An index is still range-checked, so a candidate list can mix forms.

function AP.MaterialSlot(comp, slot)
    if IsNotValid(comp) or slot == nil then return nil end

    if type(slot) == "number" then
        local n = 0
        pcall(function() n = comp:GetNumMaterials() end)
        return (slot >= 0 and slot < n) and slot or nil
    end

    local idx
    pcall(function() idx = comp:GetMaterialIndex(FName(slot)) end)
    if not idx or idx < 0 then return nil end
    return idx
end


-- [RENDERER] Tint ONE material SLOT via its own MID, leaving the component's others alone.
-- Use on any multi-slot mesh (face/body/glasses, merged modular bodies): TintComponent/TintMesh
-- spray every slot, so one "make it cyan" call would repaint all of them.
--   slot                        slot NAME (stable) or index - see AP.MaterialSlot
--   Material / Texture / EmissiveTexture   paths, swapped in before the tint. Must be RESIDENT.
--   Color|Tint|DiffuseColor / Emissive / EmissiveColor / EmScale / EmissiveMultiply / Metallic
-- Returns the slot MID (keep it to drive params later) or nil.

function AP.TintSlot(comp, slot, opts)
    if IsNotValid(comp) then return nil end
    opts = opts or {}

    local idx = AP.MaterialSlot(comp, slot)
    if not idx then
        LogBad("TintSlot - no material slot '" .. tostring(slot) .. "' on this mesh (run /dumpmat)")
        return nil
    end

    -- Material swap BEFORE the MID: CreateDynamicMaterialInstance instances whatever is on the
    -- slot at that moment, so a swap afterwards throws the MID (and every param) away.
    if opts.Material then
        local mat = ASSETS.GetIfValid(opts.Material)
        if IsValid(mat) then pcall(function() comp:SetMaterial(idx, mat) end)
        else LogBad("TintSlot - material not resident (preload it in def.Assets): " .. tostring(opts.Material)) end
    end

    local mid
    pcall(function() mid = comp:CreateDynamicMaterialInstance(idx, nil, FName("")) end)
    if IsNotValid(mid) then
        LogBad("TintSlot - MID creation failed on slot " .. tostring(idx))
        return nil
    end

    pcall(function()
        if opts.Texture then
            local tex = ASSETS.GetIfValid(opts.Texture)
            if IsValid(tex) then mid:SetTextureParameterValue(FName("Texture"), tex)
            else LogBad("TintSlot - texture not resident (preload it in def.Assets): " .. tostring(opts.Texture)) end
        end
        if opts.EmissiveTexture then
            local em = ASSETS.GetIfValid(opts.EmissiveTexture)
            if IsValid(em) then mid:SetTextureParameterValue(FName("EmissiveTexture"), em)
            else LogBad("TintSlot - emissive texture not resident (preload it in def.Assets): "
                        .. tostring(opts.EmissiveTexture)) end
        end

        local base = toLinearColor(opts.Color or opts.Tint)
        if base then
            mid:SetVectorParameterValue(FName("Color"), base)
            mid:SetVectorParameterValue(FName("Tint"), base)
        end
        if opts.DiffuseColor then
            mid:SetVectorParameterValue(FName("DiffuseColor"), toLinearColor(opts.DiffuseColor))
        end

        if opts.Emissive then
            mid:SetScalarParameterValue(FName("EmissiveIntensity"), opts.Emissive)
            mid:SetScalarParameterValue(FName("EmissiveStrength"), opts.Emissive * (opts.EmScale or 3))
        end
        if opts.EmissiveMultiply then
            mid:SetScalarParameterValue(FName("EmissiveMultiplier"), opts.EmissiveMultiply)
        end
        local emColor = toLinearColor(opts.EmissiveColor) or (opts.Emissive and FLinearColor(1, 1, 1, 1) or nil)
        if emColor then mid:SetVectorParameterValue(FName("EmissiveColor"), emColor) end

        if opts.Metallic then mid:SetScalarParameterValue(FName("Metallic"), opts.Metallic) end
    end)

    return mid
end


-- [RENDERER] Set a TEXTURE param on the body mesh; returns the MID or nil.
-- UMeshComponent has no texture equivalent of Set*ParameterValueOnMaterials, so this must go
-- through a MID. Needed when a TEXTURE-driven emissive can't be recoloured by tinting (the tint
-- multiplies against the baked colour and comes out muddy - the Mage Eye case).
-- The texture must already be RESIDENT (def.Assets): a cold load here would be an in-hook
-- blocking load (CLAUDE.md 2).

function AP.SetMeshTextureParam(actor, paramName, texPath, elemIndex)
    if Utils.IsActorInvalid(actor) or not paramName or not texPath then return nil end
    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return nil end

    local tex = ASSETS.GetIfValid(texPath)
    if IsNotValid(tex) then
        LogBad("SetMeshTextureParam - texture not resident (preload it in def.Assets): " .. tostring(texPath))
        return nil
    end

    local mid
    pcall(function()
        mid = mesh:CreateDynamicMaterialInstance(elemIndex or 0, nil, FName(""))
        if IsNotValid(mid) then mid = nil return end
        mid:SetTextureParameterValue(FName(paramName), tex)
    end)
    return mid
end


-- Swap material SLOTS by NAME: map = { ["M_Groupe_Torso_01"] = "<path to _02>", ... }.
-- Use this when the game ships an alternate palette as separate MATERIALS (e.g. the Groupe arctic
-- set) - tinting can't turn a dark texture white, only multiply it.
-- Matches each slot's current material (or its Parent, if already a MID) by leaf name; preload the
-- replacement paths or a cold miss skips that slot.
-- SOLDIER GOTCHA: the torso texture is HealthTextures-driven - swap that array too, or the first
-- hit reverts it.
-- [UNUSED] no live callers. Renderer-local. Returns the swap count.

function AP.SwapMaterialsByName(actor, map)
    local mesh = Utils.GetValidMesh(actor)
    if not mesh or not map then return 0 end

    local n = 0
    pcall(function() n = mesh:GetNumMaterials() end)
    local swapped = 0
    for i = 0, n - 1 do
        pcall(function()
            local cur = mesh:GetMaterial(i)
            if IsNotValid(cur) then return end
            local leaf = cur:GetFName():ToString()
            if not map[leaf] then
                local parent = cur.Parent
                if IsValid(parent) then leaf = parent:GetFName():ToString() end
            end
            local path = map[leaf]
            if not path then return end
            local mat = ASSETS.GetIfValid(path)
            if IsValid(mat) then
                mesh:SetMaterial(i, mat)
                swapped = swapped + 1
            end
        end)
    end
    return swapped
end


-- =======================================================================
-- HELMET + GOGGLES - the soldier `Helmet` component's shell AND its glass, one call.
-- No actor property holds goggle colour: the glass is a MATERIAL SLOT resolved BY NAME (falling
-- back to the first M_Glass* slot), and every master's param names are written onto its MID - a
-- param the material lacks is a silent no-op. Per-mesh slot table + master params: AnNotes/AnteSystems/AVUtils.md.
-- =======================================================================

local HELMET_LENS_SLOTS = { "Lens", "Visor", "Glass", "M_Glass", "M_Glass_Dirty" }
local HELMET_LENS_MAIN  = { "Color1", "Color", "OuterColor" }        -- primary, one name per master
local HELMET_LENS_ALT   = { "Color2", "InnerColor" }                 -- secondary
local HELMET_LENS_ALPHA = { "Opacity", "Glass Opacity", "TextureOpacity" }

-- Every glass slot on `comp`, in NAME priority order first (found[1] is what single-slot callers
-- take), then any slot whose material resolves to an M_Glass* leaf. A LIST because a helmet has
-- one but the sniper rifle has two (front + rear scope lens) and one-only looks two-tone.
local function helmetLensSlots(comp)
    local found, seen = {}, {}
    for _, name in ipairs(HELMET_LENS_SLOTS) do
        local idx
        pcall(function() idx = comp:GetMaterialIndex(FName(name)) end)
        if idx and idx >= 0 and not seen[idx] then seen[idx] = true; found[#found + 1] = idx end
    end
    local n = 0
    pcall(function() n = comp:GetNumMaterials() or 0 end)
    for i = 0, n - 1 do
        if not seen[i] then
            local leaf
            pcall(function()
                local m = comp:GetMaterial(i)
                if IsNotValid(m) then return end
                leaf = m:GetFName():ToString()
                -- An already-MID'd slot reads as "MaterialInstanceDynamic_N" - check its parent.
                if not leaf:match("^M_Glass") and IsValid(m.Parent) then
                    leaf = m.Parent:GetFName():ToString()
                end
            end)
            if leaf and leaf:match("^M_Glass") then seen[i] = true; found[#found + 1] = i end
        end
    end
    return found
end

-- Every failure here is a SILENT no-op (no component, no glass slot, a param the material lacks),
-- so say what we found. DEBUG_ATTACHMENTS.
local function helmetTrace(comp, slot, note)
    if not SETTINGS.DEBUG_ATTACHMENTS then return end
    local n, mesh, mat = -1, "?", "?"
    pcall(function() n = comp:GetNumMaterials() end)
    pcall(function() mesh = comp:GetStaticMesh():GetFName():ToString() end)
    if mesh == "?" then pcall(function() mesh = comp:GetSkeletalMeshAsset():GetFName():ToString() end) end
    if slot then pcall(function() mat = comp:GetMaterial(slot):GetFullName() end) end
    LogDebug(string.format("SetGlass - %s mesh=%s slots=%d lensSlot=%s mat=%s",
        note, tostring(mesh), n, tostring(slot), tostring(mat)), SETTINGS.DEBUG_ATTACHMENTS)
end


-- [RENDERER] Shell + glass in one call, for anything carrying the soldier `Helmet` component.
--   Color / Emissive / EmissiveColor / EmScale   the SHELL (via AP.TintComponent). "Color"
--                MULTIPLIES the dark-grey helmet texture: >1 brightens, <1 darkens.
--   Lens*        the glass - see AP.SetGlass.
-- Returns the glass MID, or nil when the helmet has no glass.

function AP.SetHelmet(actor, opts)
    if Utils.IsActorInvalid(actor) then return nil end
    opts = opts or {}

    local comp
    pcall(function() comp = actor.Helmet end)
    if IsNotValid(comp) then
        LogDebug("SetHelmet - actor has NO valid .Helmet component (nothing applied)",
            SETTINGS.DEBUG_ATTACHMENTS)
        return nil
    end

    if opts.Color or opts.Emissive or opts.EmissiveColor then AP.TintComponent(comp, opts) end
    return AP.SetGlass(comp, opts)
end


-- [RENDERER] The GLASS half, on ANY component with a glass slot. Also applies to guns: a sniper
-- scope's lenses share the same M_Glass_Lens_Master family, and it's the one paintable surface
-- on a weapon body.
--   Lens          goggle/visor colour           LensInner   second colour, defaults to Lens
--   LensGlow      EmissiveColor on the glass     LensOpacity number
--   LensMaterial  swap the glass slot's material before tinting (must be RESIDENT)
--   LensSlot      force the slot index           LensAll     paint every glass slot, not just first
-- Returns the glass MID or nil.

function AP.SetGlass(comp, opts)
    if IsNotValid(comp) then return nil end
    opts = opts or {}

    if not (opts.Lens or opts.LensInner or opts.LensGlow or opts.LensOpacity or opts.LensMaterial) then
        helmetTrace(comp, nil, "shell only")
        return nil
    end

    local slots
    if opts.LensSlot then
        slots = { opts.LensSlot }
    else
        slots = helmetLensSlots(comp)
        if not opts.LensAll and #slots > 1 then slots = { slots[1] } end
    end
    if #slots == 0 then   -- SM_GruntHelmet_01 / mesh-less Helmet comps have no glass
        helmetTrace(comp, nil, "NO GLASS SLOT FOUND")
        return nil
    end

    local mat
    if opts.LensMaterial then
        mat = ASSETS.GetIfValid(opts.LensMaterial)
        if IsNotValid(mat) then
            mat = nil
            LogBad("SetGlass - lens material not resident (preload it in def.Assets): "
                .. tostring(opts.LensMaterial))
        end
    end

    local main  = toLinearColor(opts.Lens)
    local alt   = toLinearColor(opts.LensInner) or main
    local glow  = toLinearColor(opts.LensGlow)

    local last
    for _, slot in ipairs(slots) do
        if mat then pcall(function() comp:SetMaterial(slot, mat) end) end

        local mid
        pcall(function() mid = comp:CreateDynamicMaterialInstance(slot, nil, FName("")) end)
        if IsNotValid(mid) then
            helmetTrace(comp, slot, "MID creation FAILED")
        else
            helmetTrace(comp, slot, "applied")
            pcall(function()
                if main then for _, p in ipairs(HELMET_LENS_MAIN) do mid:SetVectorParameterValue(FName(p), main) end end
                if alt  then for _, p in ipairs(HELMET_LENS_ALT)  do mid:SetVectorParameterValue(FName(p), alt)  end end
                if glow then mid:SetVectorParameterValue(FName("EmissiveColor"), glow) end
                if opts.LensOpacity then
                    for _, p in ipairs(HELMET_LENS_ALPHA) do mid:SetScalarParameterValue(FName(p), opts.LensOpacity) end
                end
            end)
            last = mid
        end
    end
    return last
end


-- =======================================================================
-- SCALE + OPACITY
-- =======================================================================

-- Cosmetic body scale via the MESH component. Safe on authority AND client.
--   * NOT actor:SetActorScale3D - actor scale rides the replicated root transform, so a local set
--     on a CLIENT fights movement replication and the NPC bobs/jitters.
--   * Tradeoff: the collision capsule keeps its size. Use AVU.SetBodyScale when the HITBOX matters.

function AP.SetVisualScale(actor, scale)
    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return end
    mesh:SetRelativeScale3D(scale or FVector(1, 1, 1))
end


-- [RENDERER] Fade the whole body via the character master's "Opacity" scalar (1 solid, 0 gone).
-- If a fade doesn't show, the material's blend mode doesn't honour Opacity - not this code.

function AP.SetMeshOpacity(actor, opacity)
    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return end
    pcall(function() mesh:SetScalarParameterValueOnMaterials(FName("Opacity"), opacity) end)
end


-- Step opacity across `steps` (a list of values), one every `stepMs` (default 500) - e.g.
-- { 0.8, 0.6, 0.4, 0.2, 0 } fades out over 2.5s. Each step re-checks validity, so it is safe to
-- kick off and let the actor die mid-fade.

function AP.FadeMeshOpacity(actor, steps, stepMs)
    if Utils.IsActorInvalid(actor) or not steps then return end
    stepMs = stepMs or 500
    for i, o in ipairs(steps) do
        Utils.QueueWork(function()
            if Utils.IsActorValid(actor) then AP.SetMeshOpacity(actor, o) end
        end, (i - 1) * stepMs)
    end
end


-- =======================================================================
-- ROBOT EYE / SPOTLIGHT (NPC_Robot family)
-- =======================================================================

-- [RENDERER] The robot family's eye + combat-light look. The parent drives a SpotLight (the
-- projected cone) and a "Light" lens mesh; OnRep_CombatState flips both to the Combat colour on
-- aggro, so we own the look by writing the state props and let the native flip do the rest.
--   Idle / Combat (FVector rgb)  LightColor_Idle / _Combat. Combat=(0,0,0) hides the cone, no hook needed.
--   Color          sets BOTH (one pinned colour, no flip)
--   Lens / EyeIntensity   eye lens tint (default Idle/Color) / lens emissive
--   SpotIntensity  live intensity (0 = dark spotlight that survives LOD re-toggle)
--   HideSpotlight  hide now       HideBeamMesh  scale the beam-cone mesh to 0 (the reliable kill -
--                  a LOD function re-toggles visibility, but nothing rescales it)
--   NoLens         skip the lens material-pin + tint

function AP.SetRobotEye(actor, opts)
    opts = opts or {}
    if Utils.IsActorInvalid(actor) then return end
    local idle   = opts.Idle   or opts.Color
    local combat = opts.Combat or opts.Color
    local function lc(v) return v and FLinearColor(v.X, v.Y, v.Z, 1) or nil end

    pcall(function() if idle   then actor.LightColor_Idle   = lc(idle)   end end)
    pcall(function() if combat then actor.LightColor_Combat = lc(combat) end end)

    -- Live spotlight (assume idle at Visuals time).
    pcall(function()
        local sl = actor.SpotLight
        if IsValid(sl) then
            if idle then sl:SetLightColor(lc(idle), true) end
            if opts.SpotIntensity then sl:SetIntensity(opts.SpotIntensity) end
            if opts.HideSpotlight then sl:SetVisibility(false, false) end
        end
    end)

    if opts.HideBeamMesh then
        pcall(function()
            local lm = actor.Light
            if IsValid(lm) then lm:SetRelativeScale3D(FVector(0, 0, 0)) end
        end)
        return
    end

    if opts.NoLens then return end
    -- Pin the lens material to the idle one so combat can't swap it to the red beam mat, then tint.
    local lensCol = opts.Lens or idle
    pcall(function() if actor.LightMat_Idle then actor.LightMat_Combat = actor.LightMat_Idle end end)
    pcall(function()
        local lm = actor.Light
        if IsValid(lm) then
            if actor.LightMat_Idle then lm:SetMaterial(0, actor.LightMat_Idle) end
            if lensCol then
                lm:SetVectorParameterValueOnMaterials(FName("Color"), lensCol)
                lm:SetVectorParameterValueOnMaterials(FName("EmissiveColor"), lensCol)
            end
            if opts.EyeIntensity then
                lm:SetScalarParameterValueOnMaterials(FName("EmissiveIntensity"), opts.EyeIntensity)
            end
        end
    end)
end


-- [RENDERER] Show/hide the robot's SpotLight cone NOW - the host-certain reaction to pair with
-- SetRobotEye's black Combat colour from OnEnterCombat / OnExitCombat.
-- [UNUSED] no live callers.

function AP.SetRobotSpotlight(actor, visible)
    if Utils.IsActorInvalid(actor) then return end
    pcall(function()
        local sl = actor.SpotLight
        if IsValid(sl) then sl:SetVisibility(visible and true or false, false) end
    end)
end


-- =======================================================================
-- HUMAN CUSTOMIZATION - the character-creator system (shirt / hair / labcoat / ...)
-- `fields` is keyed by the SHORT slot names below -> a ROW NAME in DT_Customization_<Slot>.
-- Beats attached-mesh costumes: these props REPLICATE with per-slot OnReps, so one dirty write
-- reskins the NPC on every client.
-- THREADING: each OnRep blocking-loads its slot's mesh/material. Run this OFF-HOOK, PRELOAD every
-- chosen slot's assets, and spawn with IgnoreCustomization=true or BeginPlay cold-loads first.
-- Every per-slot OnRep IS a full RefreshAllCustomization (all 14 slots), so a body whose unset
-- slots carry real rows needs those preloaded too. The generic trader body's are all "None".

local CUSTOM_SLOTS = {
    Head = "Customization_Head", HeadAccessory = "Customization_HeadAccessory",
    HairStyle = "Customization_HairStyle", HairColor = "Customization_HairColor",
    FacialTrait = "Customization_FacialTrait",   -- beard (DT_Customization_Beards)
    UpperBody = "Customization_UpperBody", ShirtColor = "Customization_ShirtColor",
    Tie = "Customization_Tie", IDCard = "Customization_IDCard",
    LowerBody = "Customization_LowerBody", Belt = "Customization_Belt",
    Shoes = "Customization_Shoes", Watch = "Customization_Watch",
    Labcoat = "Customization_Labcoat",
}
-- MESH slots before COLOR slots (HairColor/ShirtColor tint a mesh that must exist first).
local CUSTOM_APPLY_ORDER = {
    "Head", "UpperBody", "LowerBody", "HairStyle", "HeadAccessory", "Tie", "Labcoat",
    "Belt", "Shoes", "Watch", "IDCard", "FacialTrait", "HairColor", "ShirtColor",
}

function AP.SetHumanCustomization(actor, fields)
    if Utils.IsActorInvalid(actor) or type(fields) ~= "table" then return false end
    local comp = actor.HumanCustomizationComponent
    if IsNotValid(comp) then
        Utils.LogBad("SetHumanCustomization - actor has no HumanCustomizationComponent")
        return false
    end

    -- Let our writes apply (a body left at IgnoreCustomization = true would ignore them).
    pcall(function() comp.IgnoreCustomization = false end)

    local any = false
    for slot, rowName in pairs(fields) do
        local prop = CUSTOM_SLOTS[slot]
        if not prop then
            Utils.LogBad("SetHumanCustomization - unknown slot '" .. tostring(slot) .. "'")
        elseif rowName then
            -- An FName on legacy, a row handle on native: an FName written over a handle is an AV
            -- inside UE4SS's struct converter, so it goes through SCHEMA.
            pcall(function() SCHEMA.SetNameProp(comp, prop, rowName) end)
            Utils.MarkReplicatedDirty(comp, prop)   -- push-model -> clients get it + OnRep applies
            any = true
        end
    end

    -- On a renderer, apply locally: the authority's own OnReps don't fire (CLAUDE.md 4).
    if any and Utils.HasRenderer() then
        for _, slot in ipairs(CUSTOM_APPLY_ORDER) do
            if fields[slot] then
                local prop = CUSTOM_SLOTS[slot]
                pcall(function() comp["OnRep_" .. prop](comp) end)   -- pass comp as self
            end
        end
    end
    return any
end


return AP
