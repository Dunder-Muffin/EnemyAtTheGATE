-- =======================================================================
-- AssetKeeper - pins a curated hot-set of assets so they can't be GCed.
--
-- Preloading isn't enough: AssetManager only caches a wrapper, and once nothing else refs the
-- asset GC recycles it regardless. A pin holds a live component whose asset UPROPERTY points at
-- the asset, so it can't GC. Benefits: fewer cold loads (perf), and it closes
-- [[anteup2-ue4ss-findobject-scan-crash]] for every path it covers (ClientEffects' keep-warm
-- sweep skips pinned paths, so they cost near-zero lookups; stale-wrapper checks still go through
-- ASSETS.GetIfValid).
--
-- LIFECYCLE: Establish on InitMod, release on StopMod. EVERY role: a pin is a hidden component
-- holding a UPROPERTY ref, which needs no renderer, and a dedicated server crashed on the very
-- scan the pins prevent while it was still gated out (2026-09-13). Per-machine and LOCAL only -
-- AddComponentByClass does not replicate.
--
-- ANCHOR: STATE.GameState. Lives for the whole world, survives death/respawn and sublevel
-- streaming, and is already cached. Components use bManualAttachment=true because GameState is an
-- AInfo with no scene root - a registered, owned component hard-refs its asset without attaching.
--
-- THREADING: AddComponentByClass runs on a clean WorkQueue drain, never inside the LoadAsync
-- callback (on a renderer host that callback can be an EIGT - the §2 paint hazard). By drain time
-- the load has finished, so every GetIfValid here is a warm cache hit.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local ASSETS = require("AnteCore.AssetManager")
local Utils = require("AnteUtils.Utils")
local ENUMS = require("AnteData.Enums")

local KEEPER = {}

-- Native component classes (always resident, never GC'd - GetIfValid fast-paths /Script/).
local CLASS_FOR = {
    SM       = "/Script/Engine.StaticMeshComponent",
    SK       = "/Script/Engine.SkeletalMeshComponent",
    NIAGARA  = "/Script/Niagara.NiagaraComponent",
    SOUND    = "/Script/Engine.AudioComponent",   -- UAudioComponent.Sound is a UPROPERTY = hard ref
    TEXTURE  = "/Script/Engine.BillboardComponent",   -- UBillboardComponent.Sprite (UTexture2D*) is
                                                      -- a UPROPERTY = hard ref; written directly
    MATERIAL = "/Script/Engine.StaticMeshComponent",   -- OverrideMaterials[0] is a UPROPERTY = hard
                                                       -- ref, and SetMaterial works on a MESH-LESS
                                                       -- component (nothing is ever drawn)
    ANIM     = "/Script/Engine.SkeletalMeshComponent", -- AnimationData.AnimToPlay is a UPROPERTY =
                                                       -- hard ref, written directly (see pin - the
                                                       -- SetAnimation setter needs a mesh, a field
                                                       -- write does not)
    CLASS    = "/Script/Engine.ChildActorComponent",   -- ChildActorClass (TSubclassOf<AActor>) is a
                                                       -- UPROPERTY = hard ref to a UCLASS. Written
                                                       -- directly POST-registration, so nothing ever
                                                       -- calls CreateChildActor (that only runs from
                                                       -- OnRegister / the SetChildActorClass setter)
                                                       -- - no child is ever spawned. Pinning a class
                                                       -- pins its CDO + every hard default the CDO
                                                       -- holds (a DamageType, a BuffObject, an NPC's
                                                       -- default meshes) as one unit.
}

-- Classify a LOADED asset into a pin kind by class name (PinPaths callers hand us bare paths).
--   * nil = no component type can hold it; the caller's rewarm sweep keeps covering it.
--   * No MaterialInstanceDynamic: MIDs are runtime-created per body - pinning one is meaningless.
local KIND_FOR_CLASS = {
    NiagaraSystem = "NIAGARA",
    StaticMesh = "SM",
    SkeletalMesh = "SK",
    SoundCue = "SOUND", SoundWave = "SOUND", MetaSoundSource = "SOUND",
    Material = "MATERIAL", MaterialInstanceConstant = "MATERIAL",
    AnimMontage = "ANIM", AnimSequence = "ANIM",
    Texture2D = "TEXTURE",   -- a texture swapped onto a MID (AVU.SetMeshTextureParam)
    -- A loaded "_C" path IS the class object itself. Gated separately below (CLASS_PINS)
    -- because for NON-actor classes (DamageTypes, BuffObjects) the hold depends on UE4SS not
    -- enforcing ChildActorClass's AActor metaclass on the write - the read-back in pin() decides.
    BlueprintGeneratedClass = "CLASS",
}
-- Returns kind, class name (the class names an unpinnable path in the PinPaths line).
local function kindForAsset(asset)
    local cls
    pcall(function() cls = asset:GetClass():GetFName():ToString() end)
    local kind = cls and KIND_FOR_CLASS[cls] or nil
    if kind == "CLASS" and not SETTINGS.CORE.CLASS_PINS then return nil, cls end
    return kind, cls
end

-- The curated hot-set. Each entry = { <asset path>, <kind: "SM"|"SK"|"NIAGARA"> }.
--
-- STARTER LIST = the hottest Niagara FX in the LABS spawner data. Labs's expensive assets are FX,
-- not skeletal meshes (AVU.SwapBodyMesh is unused; Signal Pests spawn AS Pest_Volatile, no swap).
--   1. EXOR beam set  - shared by EVERY Exor variant (~6 Labs spawners). Most-shared FX in Labs.
--   2. LASER set      - Laser Pest x4 in Labs + the documented laser freeze family.
--   3. TECHSPEAR set  - Electro Peccary x3 (chain-lightning beam + impact).
-- Edit freely: add { ENUMS.Components.SK_*, "SK" } etc. to pin meshes
-- (e.g. seed the Pillager Hex-armor SKs to stress the SK-mesh memory path in Canaan/Reactors).
KEEPER.KEEP = {
    { ENUMS.Effects.EXOR_BEAM,          "NIAGARA" },   -- Exor tether beam
    { ENUMS.Effects.EXOR_CHARGEUP,      "NIAGARA" },   -- Exor windup

    -- THE LASER SET = Lasers.BURST_ASSETS, minus the class (pinned below with the other CLASS
    -- entries). Not just the three Niagara systems: lighting ONE beam also SetVariableMaterials a
    -- beam material and SpawnSoundAttached-es two looping waves, and any of those cold-loading in
    -- the drain is the same S2 wedge - that is the whole point of BURST_ASSETS existing. Keep the
    -- two lists in step.
    { ENUMS.Effects.LASER_EMITTER_BEAM, "NIAGARA" },   -- Laser Pest / laser component beam
    { ENUMS.Effects.LASER_END_IMPACT,   "NIAGARA" },
    { ENUMS.Effects.LASER_RECEIVING,    "NIAGARA" },
    { ENUMS.Effects.M_LASERBEAM,        "MATERIAL" },  -- the plain beam material: the ONLY one the
                                                       -- pests' BURST_PALETTE can select (Black and
                                                       -- Glitched are not in it)
    { ENUMS.SOUNDS.LASER_EMIT_LOOP,     "SOUND" },     -- ToggleSounds, per beam, per renderer
    { ENUMS.SOUNDS.LASER_HIT_HISS_LOOP, "SOUND" },

    { ENUMS.Effects.TECHSPEAR_BEAM,     "NIAGARA" },   -- Electro Peccary chain-lightning
    { ENUMS.Effects.TECHSPEAR_IMPACT,   "NIAGARA" },

    -- Early OFFICE sector - pegging the first enemies (Pest / Peccary / Exor_Monk).
    { ENUMS.Effects.LIGHTNING_STUN,     "NIAGARA" },   -- Charge Peccary crackle (+ tamed peccary windup)
    { ENUMS.Effects.DUST_RAINBOW,       "NIAGARA" },   -- Phase Peccary aura
    { ENUMS.Components.SM_QUILL,        "SM" },         -- Exor quill: Pest attachments + native projectile + dropped item

    -- THE DENSE-SECTOR SHARED SET. Every path here is a def.Assets entry of three or more
    -- variants that spawn across Office / Manufacturing / Labs / Reactors, so it is loaded and
    -- re-loaded on level entry no matter which of them a spawner picks.
    -- SpawnerHooks already warms + pins these when a spawner streams in, but that warm is the
    -- single most expensive WorkQueue site in the mod - it pays the load DURING the arrival
    -- burst, which is the sector-entry stutter. Boot-pinning the shared core moves that cost to
    -- world start and leaves the per-spawner warm to handle only what is genuinely local to it.
    { ENUMS.Components.SM_EXOR_QUILLSTATE,   "SM" },       -- back-quill rack: every Exor line
    { ENUMS.Components.SM_EXOR_SKULL,        "SM" },       -- Pikeman skull trophy
    { ENUMS.Effects.EXOR_SHOCKWAVE,          "NIAGARA" },  -- completes the Exor beam set above
    { ENUMS.Effects.EXOR_BLINK,              "NIAGARA" },  -- Monk/Spiritwalker teleport, both halves
    { ENUMS.Effects.EXOR_BLINK_SFX,          "SOUND" },
    { ENUMS.Anims.PECCARY_CHARGE_START,      "ANIM" },     -- charge windup: every Peccary variant
    { ENUMS.Components.SM_LASER_GRENADE,     "SM" },       -- Labs staple; also the Order belt kit
    { ENUMS.Components.SM_GLOWSTICK,         "SM" },       -- Order soldier belt kit
    { ENUMS.Components.SM_FLASK,             "SM" },       -- thrown flask: Rats, Witches, Grunts
    { ENUMS.Components.M_ANTELIGHT_RGB,      "MATERIAL" },
    { ENUMS.Effects.NIAGARA_ASSASSIN_TRACER, "NIAGARA" },  -- Assassin dash trail
    { ENUMS.Anims.ASSASSIN_POWER_MELEE,      "ANIM" },
    -- The soldier evade set. Shared by every Skirmisher/dodging Order body, and it fires on a
    -- combat beat rather than on spawn - a cold montage here is a visible hitch mid-fight.
    { ENUMS.Anims.GK_DODGE_LEFT,             "ANIM" },
    { ENUMS.Anims.GK_DODGE_RIGHT,            "ANIM" },
    { ENUMS.Anims.GK_DODGE_BACK,             "ANIM" },
    { ENUMS.Anims.GRUNT_STAGGER_BACK,        "ANIM" },
    { ENUMS.Anims.GRUNT_STAGGER_LEFT,        "ANIM" },   -- both sides re-loaded mid-run when only
    { ENUMS.Anims.GRUNT_STAGGER_RIGHT,       "ANIM" },   -- BACK was pinned: the set is indivisible
    -- The Magus pushback nova (NOVA_DEPS in AnteNPCs/ExorMonkHelpers). The Exorrior Magus is
    -- placed throughout the levels and nothing else references these, so unpinned they GC and
    -- cold-load again on every nova. Its two classes (Blunt, Stunned) are in CLASS_PINS.
    { ENUMS.Effects.SHADOW_IMPACT_LITE,      "NIAGARA" },
    { ENUMS.Effects.M_PARRY_INDICATOR,       "MATERIAL" },
    { ENUMS.Anims.EXOR_VOLATILE_DETONATE,    "ANIM" },
    { ENUMS.Anims.EXOR_AGGRO,                "ANIM" },
    { ENUMS.SOUNDS.EXOR_VOLATILE_LEAP,       "SOUND" },   -- its wind-up roar (client FX EXOR_NOVA_ROAR)
    -- Collected inside the 4 s def.Assets pin delay during a Gale Reactor war and reloaded by the pin.
    { ENUMS.Effects.WISP_RED,                "NIAGARA" }, -- Beholder amber eye, MolotovFlat trail
    { ENUMS.Effects.FLASK_RESTORATIVE_BURST, "NIAGARA" }, -- Order Medic heal burst
    { ENUMS.Components.SM_SPEAR_HARDLIGHT_TIP, "SM" },    -- Gatekeeper Mage hardlight spear
}

-- CLASS-pin experiment set (CLASS_PINS; merged into KEEP below when enabled).
-- One of each category, so the boot log answers three questions at once:
--   * Pest       - an ACTOR class: fully type-correct for ChildActorClass, must read HELD.
--   * FirePlasma - a DamageType (UDamageType, non-actor): probes whether UE4SS enforces the
--                  AActor metaclass. Also a real preload pain point (soft-ref'd on plasma
--                  projectiles).
--   * SuddenDeath pair - BuffObject classes (plain UObjects), the stat-floor freeze rows no
--                  normal session ever has resident. A held pin closes that trap on this machine.
--                  The fire-time preloads stay regardless - a pin can fail or be rejected, and
--                  the preload is what covers that path.
local KEEP_CLASSES = {
    { ENUMS.DamageType.FirePlasma,          "CLASS" },
    -- LaserComponent_C: every FireBurst does N AddComponentByClass on it, and a burst rides every
    -- Laser Pest leap. Pinning the class also holds the hard object constants in its bytecode
    -- (the beam FX/materials/sounds pinned above) - but they stay listed explicitly, because
    -- "it rides in with the class" is exactly the inference that produced the 2026-08-17 freeze.
    { ENUMS.LaserComponent,                 "CLASS" },
    { ENUMS.BuffObjects.SuddenDeathThirst,  "CLASS" },
    { ENUMS.BuffObjects.SuddenDeathHunger,  "CLASS" },

    -- Measured GC-cyclers (2026-08-08 long-play log): each cold-loaded 6+ times in one session
    -- because nothing pinned them - BuffObject_Stunned showed the same once-a-MINUTE churn for
    -- 12 minutes straight until its first call-site pin landed, then never loaded again.
    { ENUMS.BuffObjects.BeeSwarm,           "CLASS" },   -- bee-swarm debuff (Hive Sow / bees)
    { ENUMS.Components.AREA_HOLY_FIRE,      "CLASS" },   -- holy molotov fire patch (Pillager/INQ)
    { ENUMS.BuffObjects.Stunned,            "CLASS" },   -- the once-a-minute churner itself: its
                                                         -- call-site pin only lands on a mutation,
                                                         -- so boot-pin to close the early window

    -- THE EXOR RELOAD SET. Every Exor variant throws something on each reload through PROJ.Queue,
    -- and PROJ.Queue re-resolves its whole dependency list PER SHOT - class, DamageType, trail,
    -- impact AreaEffect. Unpinned that is one ~15-25ms UObject-array walk each, in the WorkQueue
    -- drain, which profiled as "WQ AnteCore\Projectile.lua:779 = 29ms" on a two-path seeker shot.
    -- Pinned, LoadAsset takes the trusted-cache branch and the same resolve is table reads.
    -- Keep this list in step with the Deps/Preload tables in AnteNPCs/Exor.lua.
    { ENUMS.ProjectileClasses.QuillSpear,   "CLASS" },   -- Antegrav seeker quill (+ Displacer/Dislocator)
    { ENUMS.ProjectileClasses.ExorSpike,    "CLASS" },   -- its base, and what every native Exor fires
    { ENUMS.DamageType.SharpExorQuill,      "CLASS" },   -- the type on all three quill rows
    { ENUMS.ProjectileClasses.PlasmaBall,   "CLASS" },   -- Antefire PRIMARY fire, one per shot
    { ENUMS.BuffObjects.IgnitedPlasma,      "CLASS" },   -- what its Fire_Plasma type ignites with
    { ENUMS.BuffObjects.HPDamage,           "CLASS" },   -- that debuff's parent (the DoT tick)
    { ENUMS.ProjectileClasses.Molotov,      "CLASS" },   -- Magma mortar (twice per reload in hard)
    { ENUMS.ProjectileClasses.MageFireball, "CLASS" },   -- Antefire mortar
    { ENUMS.DamageType.Fire,                "CLASS" },   -- the Magma mortar's own preload
    { ENUMS.Components.AREA_MOLOTOV_FIRE,   "CLASS" },   -- the patch the molotov drops on impact
    { ENUMS.Components.AREA_PLASMA_FIRE,    "CLASS" },   -- the blue patch the mage fireball drops
    { ENUMS.Effects.PLASMA_PROJECTILE,      "NIAGARA" }, -- Antefire mortar comet + the seeker's trail
    { ENUMS.Effects.NIAGARA_FIREBALL,       "NIAGARA" }, -- Magma mortar comet

    -- =======================================================================
    -- THE SHARED ELEMENTAL CORE - the damage types the mod deals, paired with the debuff each
    -- one applies.
    --
    -- These are the cheapest pins in the file and the widest-reaching: a DamageType or
    -- BuffObject class is a CDO with no mesh behind it, and this set is what ~20 different
    -- variant files each list in their own Deps table and re-warm on their own beat. Pinned
    -- once at boot, every one of those WarmPinned calls finds its whole list already pinned and
    -- does nothing.
    --
    -- The reason they need pinning at all rather than preloading is the debuff-preload trap
    -- (CLAUDE.md section 5): a DamageType names its debuff by ROW, so loading the type does not
    -- pull the buff object in, and the buff then blocking-loads inside the victim's
    -- ProcessDamage - which for damage dealt in the drain is the deadlock. A per-site preload
    -- closes that for one ability; a pin closes it for the whole world, including the hits the
    -- native game deals with the same types.
    --
    -- PAIRING RULE: a type and its debuff go in together, and a DoT's debuff also needs the
    -- type its own ticks deal. Adding a type alone re-opens the trap for it.
    --   * Fire / FirePlasma / FireHoly -> Ignited / Ignited_Plasma / Ignited_Holy (all on HPDamage)
    --   * Sharp -> Bleeding or SevereBleeding, picked by the damage of that hit
    --   * Acid + Acid_VolPestExplode -> AcidBurn, whose ticks deal Acid_Burn
    -- Electric, Explosive, Blunt and Laser carry no debuff - the type alone is the whole pin.
    { ENUMS.DamageType.Electric,            "CLASS" },   -- the mod's most-dealt type (Witches,
                                                         -- Chieftain, Captains, tamed peccaries)
    { ENUMS.DamageType.Explosive,           "CLASS" },   -- charge novas, Tarasque marks, Shadow boss
    { ENUMS.DamageType.ExplosiveDefenseBot, "CLASS" },   -- the debuff-free blast (Sapper, mortars)
    { ENUMS.DamageType.Blunt,               "CLASS" },
    { ENUMS.DamageType.Laser,               "CLASS" },
    { ENUMS.DamageType.PsychicMonk,         "CLASS" },   -- AVU.CastPsychicBeam resolves it per beam

    { ENUMS.BuffObjects.Ignited,            "CLASS" },   -- plain Fire's DoT; DamageType.Fire is
                                                         -- already pinned with the Exor set above
    { ENUMS.DamageType.FireHoly,            "CLASS" },   -- Pillager / Rook / Purified Interfector
    { ENUMS.BuffObjects.IgnitedHoly,        "CLASS" },

    { ENUMS.DamageType.Sharp,               "CLASS" },   -- every melee weapon in the game
    { ENUMS.BuffObjects.Bleeding,           "CLASS" },   -- 50-149 damage band
    { ENUMS.BuffObjects.SevereBleeding,     "CLASS" },   -- 150+

    { ENUMS.DamageType.Acid,                "CLASS" },   -- Volatile Exor / Acidic Exor line
    { ENUMS.DamageType.AcidVolatile,        "CLASS" },
    { ENUMS.DamageType.AcidBurn,            "CLASS" },   -- what the AcidBurn DoT ticks deal
    { ENUMS.BuffObjects.AcidBurn,           "CLASS" },

    { ENUMS.BuffObjects.Netted,             "CLASS" },   -- net rounds; Netted extends Stunned
    { ENUMS.BuffObjects.NettedCannon,       "CLASS" },   -- its ticks deal Electric, pinned above
    { ENUMS.BuffObjects.StunnedFrozen,      "CLASS" },   -- every cold/frost apply

    -- THE AILMENTS. Applied by row name, so each blocking-loads its object on first use, and nothing
    -- in a normal session keeps them resident. All four reloaded mid-soak.
    { ENUMS.BuffObjects.Stinky,             "CLASS" },   -- Signal Pests; natively every poop/liquid deployable
    { ENUMS.BuffObjects.Sick,               "CLASS" },   -- Signal Pests, the plague pests
    { ENUMS.BuffObjects.Spores,             "CLASS" },   -- the mushroom families
    { ENUMS.BuffObjects.FatigueExhausted,   "CLASS" },   -- the Twilight Sniper's fatigue ceiling

    -- The DefenseBot's native mortar and frag rounds (their type, ExplosiveDefenseBot, is above).
    { ENUMS.ProjectileClasses.MortarDefenseBot, "CLASS" },
    { ENUMS.ProjectileClasses.FragDefenseBot,   "CLASS" },
}

-- Common-spawn NPC classes (the per-zone spawner staples: Office/Labs pests+exors, Order grunt
-- line, GATE gatekeepers). Pinning the class turns NpcSpawner's per-spawn class resolve into a
-- trusted table hit (was one ~20-30ms walk per spawn, NpcSpawner.lua:149), and stops the class +
-- its CDO defaults from GC-cycling between waves.
-- MEMORY: the first pin set with real weight - each class holds its CDO's default meshes/anim
-- refs (textures still mip-stream, so expect tens of MB, not hundreds). Trim here first if a
-- low-memory report ever fingers the keeper.
-- ORDERED BY ZONE PRIORITY:
--   P1 = Office / Manufacturing / Labs - where nearly every player spends their first hours.
--   P2 = the later facility levels.
--   Vignettes are deliberately ABSENT. They are visited rarely, and a vignette-only body
--   (Pillager, Yeti, Groupe, DarkLens) still pins itself through NpcSpawner the moment it first
--   spawns, then releases with the world - self-scoping, which is the right cost for a place most
--   runs see once.
--
-- RANK THESE BY REAL SPAWN COUNTS FROM A PLAY LOG, never by how many SpawnerData entries name the
-- row. A spawner's NPCsToSpawn is a WEIGHTED list, so a row we rarely override barely appears in
-- SpawnerData and still spawns constantly - Grunt_Guard reads as 4 slots and spawned 27 times.
--   grep -oE "\] spawned [A-Za-z_0-9]+ =>" UE4SS.log | sort | uniq -c | sort -rn
--
-- Trim from the BOTTOM: this is the one pin category with real memory weight (each class holds its
-- CDO's default meshes and anims), and the tail rows are the narrowest.
local COMMON_NPC_CLASSES = {
    -- P1 core.
    "Grunt", "Exor_Monk", "Pest", "Peccary", "Exor",
    "Pest_Volatile",   -- the Signal/Antevolatile line, and every SpawnAs onto it
    "Pest_Electro", "Pest_Carbonated",
    "Assassin",           -- Skirmisher/Trident
    "Grunt_Captain", "Grunt_Shotgun", "Grunt_Medic", "Grunt_LabRat", "Grunt_Guard",
    "Robot_Security",     -- the nightly Office wave: spawns every session, so the pin costs nothing extra

    -- P2 facility. Little or no P1 presence, but they carry whole sectors.
    "Exor_Armored", "Grunt_Sapper", "Exor_Volatile", "Exor_Pikeman", "Grunt_Sniper",
    "Peccary_Volatile",
    -- Trooper_Shield EXTENDS Groupe_Rook's class (NPC_OrderGrunt_Shield < NPC_Groupe_Shield), so
    -- this one entry keeps both shield lines resident.
    "Trooper", "Trooper_Shield",
    "Gatekeeper_Phyter", "Gatekeeper_Mage", "Gatekeeper_Witch",
}
for _, row in ipairs(COMMON_NPC_CLASSES) do
    local p = ENUMS.NpcClasses[row]
    if p then
        KEEP_CLASSES[#KEEP_CLASSES + 1] = { p, "CLASS" }
    else
        Utils.LogBad("AssetKeeper - COMMON_NPC_CLASSES unknown row: " .. tostring(row))
    end
end

if SETTINGS.CORE.CLASS_PINS then
    for _, e in ipairs(KEEP_CLASSES) do KEEPER.KEEP[#KEEPER.KEEP + 1] = e end
end

-- Kinds only a renderer draws. A dedicated server pins the rest of KEEP: the classes and debuff
-- objects its own spawns and damage load, and the meshes and montages its bodies carry.
local RENDER_ONLY = { NIAGARA = true, SOUND = true, MATERIAL = true, TEXTURE = true }

-- The pin anchor: this world's GameState, or nil. A plain IsValid, never Utils.IsActorValid: the
-- GameState is no character, and that check's level test read it as unloaded on a dedicated server at
-- InitMod - which skipped the whole KEEP set there without a word.
local function anchorOf()
    local gs = STATE.GameState
    if IsValid(gs) then return gs end
    return nil
end

local heldComponents = {}   -- live pin components; destroyed on Release
local established = false
local keepStatus = {}       -- the last Establish's outcome, for KEEPER.Status (AnTest's server suite)
local PIN_CHUNK = 8         -- KEEP entries pinned per drain item (see Establish)


-- True for an object whose name is already gone: a slot being destroyed (a sublevel stream-out
-- collects classes with no instances left). IsValid still passes it, and holding it in a UPROPERTY
-- keeps a pointer to freed memory. Such a path stays unpinned; the next PinPaths call retries it.
local function isDying(asset)
    local ok, name = pcall(function() return asset:GetFName():ToString() end)
    return not ok or name == nil or name == "" or name == "None"
end

-- Add ONE hidden, inert pin component to `anchor` holding `asset`. Returns the comp or nil.
local function pin(anchor, asset, kind)
    local compClass = ASSETS.GetIfValid(CLASS_FOR[kind])
    if IsNotValid(compClass) then return nil end

    -- bManualAttachment=true: the GameState has no scene root to attach to.
    -- A created, REGISTERED, OWNED component (bDeferredFinish=false) is all the pin needs.
    local comp = anchor:AddComponentByClass(compClass, true, FTransform(), false)
    if Utils.IsComponentInvalid(comp) then return nil end

    -- Inert: no tick, no collision, invisible. Re-validate after AddComponentByClass (BP construction).
    pcall(function() comp:SetComponentTickEnabled(false) end)
    pcall(function() comp:SetVisibility(false, false) end)
    pcall(function() comp:SetCollisionEnabled(0) end)
    if Utils.IsComponentInvalid(comp) or IsNotValid(asset) then return nil end

    if kind == "NIAGARA" then
        pcall(function() comp:SetAutoActivate(false) end)   -- hold the ref, never emit
        pcall(function() comp:SetAsset(asset, false) end)
        pcall(function() comp:Deactivate() end)
    elseif kind == "MATERIAL" then
        pcall(function() comp:SetMaterial(0, asset) end)    -- hold the ref; mesh-less = never drawn
    elseif kind == "SOUND" then
        pcall(function() comp:SetAutoActivate(false) end)   -- hold the ref, never play
        pcall(function() comp:SetSound(asset) end)
        pcall(function() comp:Stop() end)
    elseif kind == "SK" then
        pcall(function() comp:SetSkeletalMeshAsset(asset) end)
    elseif kind == "CLASS" then
        -- Direct field write. The SetChildActorClass SETTER would call CreateChildActor and spawn
        -- one; a field write holds the ref with no side effect.
        -- READ-BACK VERIFIED for two reasons: a silent no-op would mark the path trusted with no
        -- ref behind it (the ANIM hole), and for non-actor classes this is the live probe of
        -- whether UE4SS enforces the AActor metaclass. Per-path verdict logged so a REJECTED kind
        -- is visible in bug-report logs.
        local held, name = false, "?"
        pcall(function()
            name = asset:GetFullName()
            if isDying(asset) then return end
            comp.ChildActorClass = asset
            held = comp.ChildActorClass:GetFullName() == name
        end)
        Utils.Log("AssetKeeper - CLASS pin " .. (held and "HELD " or "REJECTED ") .. name)
        if not held then
            pcall(function() comp:K2_DestroyComponent(comp) end)
            return nil
        end
    elseif kind == "TEXTURE" then
        -- Direct field write: SetSprite would push render state for a sprite nothing ever draws.
        -- READ-BACK VERIFIED, for the ANIM reason below.
        local held = false
        pcall(function()
            comp.Sprite = asset
            held = comp.Sprite:GetFullName() == asset:GetFullName()
        end)
        if not held then
            pcall(function() comp:K2_DestroyComponent(comp) end)
            return nil
        end
    elseif kind == "ANIM" then
        -- No setter works MESH-LESS (SetAnimation needs a single-node instance, which needs a
        -- mesh). But AnimationData.AnimToPlay is a plain UPROPERTY object ref, so a direct field
        -- write holds it just as hard.
        -- READ-BACK VERIFIED: a silent no-op write here would mark the path trusted
        -- (ASSETS.Pinned) with no ref actually behind it - the one §3 hole this kind could open.
        local held = false
        pcall(function()
            comp.AnimationData.AnimToPlay = asset
            held = comp.AnimationData.AnimToPlay:GetFullName() == asset:GetFullName()
        end)
        if not held then
            pcall(function() comp:K2_DestroyComponent(comp) end)
            return nil
        end
    else -- SM
        pcall(function() comp:SetStaticMesh(asset) end)
    end

    return comp
end


-- =======================================================================
-- PinPaths - pin an ad-hoc list of asset PATHS (kind auto-classified from the loaded asset).
--   * Rider: the ClientEffects keep-warm list. Each pinned path its sweep skips is one fewer
--     UE4SS object-array walk ([[anteup2-ue4ss-findobject-scan-crash]]).
--   * Safe to call repeatedly: pinned paths are skipped; /Script/ never GCs = always-pinned.
--   * A path that fails to load/classify/pin stays UNPINNED - the caller's sweep keeps covering
--     it, so a pin failure degrades to today's behavior.
--   * Same gating and threading as Establish: every role, flag-gated, pin on a clean drain.
-- =======================================================================
-- path -> true once a live component holds it. THE SAME TABLE as ASSETS.Pinned: a pinned path is
-- trusted straight from the AssetManager cache (no StaticFindObject walk), so the trust must
-- appear exactly when the hard ref exists and vanish exactly when Release drops it.
local pinnedPaths = ASSETS.Pinned

function KEEPER.IsPinned(path)
    return pinnedPaths[path] == true or (path and path:sub(1, 8) == "/Script/")
end

-- path -> true for paths PinPaths has already proven it cannot hold (class not in KIND_FOR_CLASS,
-- or pin() read-back failed). Without this, an unpinnable path never enters pinnedPaths, so every
-- later call re-adds it to `todo` and pays another LoadAsync + GetIfValid SCAN + log line - forever.
-- That only became a real cost once Pipeline started pinning def.Assets on EVERY mutation.
--   * Deliberately NOT cleared by Release: unpinnability is a property of the asset's CLASS, not of
--     the world, so the verdict survives a zone change (the PINS themselves do not).
local unpinnable = {}

-- A path that comes back unresolved is asked for once more before it counts as an error. A soak
-- caught a pin losing the race to a GC: the assets were collected between their load and the pin
-- 4s later, and pinned fine on a later call. A path that is simply wrong fails both times.
local PIN_RETRY_MS = 1000

-- True once PinPaths has proven it cannot hold this path (so a caller can stop asking).
function KEEPER.IsUnpinnable(path) return unpinnable[path] == true end

function KEEPER.PinPaths(paths, isRetry)
    if not SETTINGS.CORE.ASSET_KEEPER then return end

    local todo = {}
    for _, p in ipairs(paths or {}) do
        if not KEEPER.IsPinned(p) and not unpinnable[p] then todo[#todo + 1] = p end
    end
    if #todo == 0 then return end

    -- `loaded` = the path -> asset map LoadAsync already built. Use it rather than re-resolving:
    -- a per-path ASSETS.GetIfValid here is a full UObject-array WALK (~25ms each), so re-resolving
    -- would pay for every path twice ([[anteup2-ue4ss-findobject-scan-crash]]).
    --   * Re-resolve is NOT needed for safety: these wrappers are seconds old, from THIS load, and
    --     each is re-checked with IsNotValid below before anything is done with it.
    ASSETS.LoadAsync(todo, function(loaded)
        Utils.QueueWork(function()
            local anchor = anchorOf()
            if not anchor then return end   -- world tore down mid-load; next call retries
            -- Four buckets so a shortfall in the log is self-explaining: `already` = another pin
            -- call (usually Establish's overlapping KEEP list) beat this drain to the path -
            -- benign. `failed` = pin() returned nil (component creation / read-back) - a real
            -- failure, named per path. "pinned + already == total" is the healthy shape.
            local ok, unknown, already, failed = 0, 0, 0, 0
            local unknownNames, retry = {}, {}
            for _, p in ipairs(todo) do
                if pinnedPaths[p] then
                    already = already + 1
                else
                    local asset = loaded and loaded[p]
                    if IsNotValid(asset) or isDying(asset) then asset = nil end
                    local kind, cls
                    if asset then kind, cls = kindForAsset(asset) end
                    if kind then
                        local comp = pin(anchor, asset, kind)
                        if comp then
                            heldComponents[#heldComponents + 1] = comp
                            pinnedPaths[p] = true
                            ok = ok + 1
                        else
                            failed = failed + 1
                            unpinnable[p] = true   -- read-back said no: don't retry it every mutation
                            Utils.LogBad("AssetKeeper - PinPaths pin FAILED for " .. tostring(p))
                        end
                    elseif asset then
                        unknown = unknown + 1      -- unpinnable class; the sweep keeps covering it
                        unpinnable[p] = true
                        unknownNames[#unknownNames + 1] = tostring(cls) .. " " .. (p:match("([^/]+)$") or p)
                    elseif not isRetry then
                        retry[#retry + 1] = p
                    else
                        failed = failed + 1
                        unpinnable[p] = true   -- twice unresolved: a bad path; stop asking this session
                        Utils.LogBad("AssetKeeper - PinPaths could not resolve " .. tostring(p))
                    end
                end
            end
            Utils.Log(string.format(
                "AssetKeeper - PinPaths pinned %d/%d (%d already pinned, %d unpinnable, %d failed%s)",
                ok, #todo, already, unknown, failed, #retry > 0 and (", " .. #retry .. " unresolved, retrying") or "")
                .. (unknown > 0 and (" - unpinnable: " .. table.concat(unknownNames, ", ")) or ""))
            if #retry > 0 then
                Utils.QueueWork(function() pcall(KEEPER.PinPaths, retry, true) end, PIN_RETRY_MS)
            end
        end, 0)
    end)
end


-- Pin an asset the caller has just loaded, on the next drain item, without PinPaths' load round
-- trip. For a class about to be spawned: until its first instance lands nothing holds a fresh class,
-- and a GC mark in that window condemns it under the spawn ([[anteup2-condemned-class-skink-crash]]).
-- A dying or unclassifiable asset is left to the caller's PinPaths backstop.
-- [DRAIN ITEM ONLY] The same pin, now. AddComponentByClass is component work, so never from an
-- EIGT on a renderer (CLAUDE.md 2); a load callback queues one item for it.
function KEEPER.PinNow(path, asset)
    if not SETTINGS.CORE.ASSET_KEEPER then return end
    if pinnedPaths[path] or unpinnable[path] then return end
    local anchor = anchorOf()
    if not anchor then return end
    if IsNotValid(asset) or isDying(asset) then return end
    local kind = kindForAsset(asset)
    if not kind then return end
    local comp = pin(anchor, asset, kind)
    if comp then
        heldComponents[#heldComponents + 1] = comp
        pinnedPaths[path] = true
    end
end

function KEEPER.PinLoaded(path, asset)
    if not SETTINGS.CORE.ASSET_KEEPER then return end
    if pinnedPaths[path] or unpinnable[path] then return end
    Utils.QueueWork(function() KEEPER.PinNow(path, asset) end, 0)
end


-- [InitMod] Establish the keeper for the CURRENT world - load the KEEP set, then pin it.
--   * Idempotent (guards on `established`); every role (a dedicated server crashed on the same
--     scan the pins exist to avoid), gated by the SETTINGS flag.
function KEEPER.Establish()
    if not SETTINGS.CORE.ASSET_KEEPER then return end
    if established then return end
    if not anchorOf() then
        Utils.QueueWork(KEEPER.Establish, 2000)   -- no GameState yet: try again (dies with the world)
        return
    end

    established = true   -- claim now so a re-entrant InitMod can't double-load

    local renderer = Utils.HasRenderer()
    local list, paths = {}, {}
    for _, e in ipairs(KEEPER.KEEP) do
        if renderer or not RENDER_ONLY[e[2]] then
            list[#list + 1] = e
            paths[#paths + 1] = e[1]
        end
    end

    -- Load the whole set, THEN pin on a clean drain (see THREADING - never AddComponent in-callback).
    -- `loaded` = the path -> asset map the load already built, used the same way PinPaths uses
    -- it: a per-entry ASSETS.GetIfValid would be a full UObject-array walk each, so re-resolving
    -- the whole KEEP set costs more than the pinning does. These wrappers are seconds old and
    -- from this load, and pin() re-checks each one before touching it. GetIfValid stays as the
    -- fallback for the rare path the load did not return.
    ASSETS.LoadAsync(paths, function(loaded)
        -- CHUNKED across drain items. The set is large enough that pinning it in one item is a
        -- visible boot frame, and a pin only has to beat the first GC.
        local idx, ok = 1, 0
        local function step()
            local anchor = anchorOf()   -- re-fetch each chunk; the world may tear down mid-run
            if not anchor then established = false; return end

            for _ = 1, PIN_CHUNK do
                local e = list[idx]
                if not e then
                    Utils.Log("AssetKeeper - pinned " .. ok .. "/" .. #list .. " assets (GameState"
                        .. (renderer and "" or ", server set") .. ")")
                    keepStatus = { done = true, pinned = ok, total = #list, serverSet = not renderer }
                    return
                end
                idx = idx + 1

                if pinnedPaths[e[1]] then   -- PinPaths may have beaten us to it (lists overlap)
                    ok = ok + 1
                else
                    local asset = loaded and loaded[e[1]]
                    if IsNotValid(asset) then asset = ASSETS.GetIfValid(e[1]) end
                    if asset then
                        local comp = pin(anchor, asset, e[2])
                        if comp then
                            heldComponents[#heldComponents + 1] = comp
                            pinnedPaths[e[1]] = true   -- let sweeps (IsPinned) skip these too
                            ok = ok + 1
                        end
                    else
                        Utils.LogBad("AssetKeeper - could not resolve " .. tostring(e[1]))
                    end
                end
            end
            Utils.QueueWork(step, 0)
        end
        Utils.QueueWork(step, 0)
    end)
end

-- =======================================================================
-- VerifyPins - authoritative residency audit (the "/pins" chat command).
-- GetIfValid TRUSTS pinned paths (that IS the fast-path), so it can never detect a pin that
-- failed to hold - this walks the real object array per path (raw StaticFindObject, ~25ms each),
-- ONE path per WorkQueue item so the audit never stacks a multi-hundred-ms frame.
-- A "PIN GONE" line = the hard ref did not actually survive GC - a §3 hole, report it.
-- =======================================================================
-- { done, pinned, total, serverSet } for this world's KEEP set, plus every pin held now.
function KEEPER.Status()
    local all = 0
    for _ in pairs(pinnedPaths) do all = all + 1 end
    return { established = established, done = keepStatus.done, pinned = keepStatus.pinned,
             total = keepStatus.total, serverSet = keepStatus.serverSet, allPins = all }
end

-- onDone(gone, total) - optional, once the walk is through (AnTest's server suite).
function KEEPER.VerifyPins(onDone)
    local paths = {}
    for p in pairs(pinnedPaths) do paths[#paths + 1] = p end

    local live = 0
    for _, comp in ipairs(heldComponents) do
        if IsValid(comp) then live = live + 1 end
    end
    Utils.Log(string.format("AssetKeeper - verifying %d pins (%d/%d holder comps live)",
        #paths, live, #heldComponents))

    local gone, idx = 0, 0
    local function step()
        idx = idx + 1
        local p = paths[idx]
        if not p then
            Utils.Log(string.format("AssetKeeper - verify done: %d/%d resident, %d GONE",
                #paths - gone, #paths, gone))
            if onDone then pcall(onDone, gone, #paths) end
            return
        end
        local obj = StaticFindObject(p)
        if IsNotValid(obj) then
            gone = gone + 1
            Utils.LogBad("AssetKeeper - PIN GONE (ref did not hold): " .. p)
        end
        Utils.QueueWork(step, 0)
    end
    Utils.QueueWork(step, 0)
end


-- [StopMod] Release all pins - destroy the held components, reset state for the next world.
--   * Most components are already invalid at teardown (the anchor died with the world);
--     the IsValid guard makes those destroys safe no-ops.
function KEEPER.Release()
    for _, comp in ipairs(heldComponents) do
        pcall(function() if IsValid(comp) then comp:K2_DestroyComponent(comp) end end)
    end
    heldComponents = {}
    -- Cleared IN PLACE - pinnedPaths IS ASSETS.Pinned, and the cache-trust must die with the pins.
    for p in pairs(pinnedPaths) do pinnedPaths[p] = nil end
    established = false
    keepStatus = {}
end


return KEEPER
