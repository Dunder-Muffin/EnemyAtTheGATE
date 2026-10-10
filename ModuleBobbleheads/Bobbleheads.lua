-- =======================================================================
-- ModuleBobbleheads/Bobbleheads - CUSTOM BOBBLEHEAD PROTOTYPES.
--
-- Three tiers of customisation prototype, all hosted on ONE deployed class. Placed by
-- `/au-bobble <key>` (AnDebug/ChatCommands); this is a PROTOTYPE rig, not a shipping feature -
-- the figures worth shipping have real item rows (see THE ITEM HALF at the bottom), but nothing
-- yet GIVES you one in normal play (see ACQUISITION at the end).
-- How the vanilla wobble/interact mechanism works: see AnNotes/Modules/Bobbleheads.md.
--
-- ---------------------------------------------------------------------
-- MUST-KNOWS
-- ---------------------------------------------------------------------
--   * HOST CLASS = the bobblehead PARENT (ENUMS.DeployedObjs.BOBBLEHEAD), the one deployed
--     bobblehead class no item row points at - so every instance is OURS, no marker needed to
--     say "mine", only "which". It is also SILENT (the talking subclasses override
--     Broadcast_BobbleMyHead); hosting on one of those would double up its vanilla line.
--
--   * WHICH prototype rides `ChangeableData.PlayerMadeString` ("ante:<key>") - the only
--     per-instance channel a deployable gets that is replicated, saved, and round-trips
--     item -> actor -> item. Invisible to the player (GetItemFullName only surfaces it for
--     `Item.Pet` rows). *** MUTATE IN PLACE. *** ChangeableData holds a DataTable ptr + soft-object
--     ptrs, so a whole-struct writeback is the CLAUDE.md S3 soft-ptr mangle.
--
--   * THE LOOK DOES NOT REPLICATE (SetStaticMesh/AddComponentByClass are runtime component
--     changes, CLAUDE.md S4) - every renderer re-derives it from the marker. Same shape as
--     ModuleTraders/TraderMirror: NotifyOnNewObject + bounded per-actor retry (no OnRep_ChangeableData
--     to wait on) + a rare FindAllOf backstop, deduped by GetFullName.
--
--   * HEADZ TRAVELS WITH THE BODY. Vanilla BPs bake a per-character neck height into
--     BobbleHead.RelativeLocation (humanoids ~24.70-26.70, GKHeavy 31.34) - swap bodies without
--     it and the head floats clear of the neck. ENUMS.Collectibles carries HeadZ per body; always
--     set both together.
--
--   * NEVER route the body swap through AVU.SwapStaticMesh - it zeroes collision, which kills the
--     interaction trace on `FurnitureMesh` (un-pokeable bobblehead). swapMesh below preserves it.
--
--   * AUDIO rides the multicast, not an RPC - Broadcast_BobbleMyHead runs on server AND every
--     client already, so a renderer-side local PlaySoundAtLocation reaches everyone for free. The
--     waves must be resident first (KEEPER-pinned at Register); the hook SKIPS rather than
--     loading, since a cold load in-hook is the CLAUDE.md S2 deadlock.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local UEHelpers = require("UEHelpers")

local SETTINGS = require("Settings")
local STATE    = require("AnteCore.State")
local ENUMS    = require("AnteData.Enums")
local SCHEMA   = require("AnteData.Schema")
local Utils    = require("AnteUtils.Utils")
local ASSETS   = require("AnteCore.AssetManager")
local KEEPER   = require("AnteCore.AssetKeeper")
local AVU      = require("AnteUtils.AVUtils")

local Log     = Utils.Log
local LogBad  = Utils.LogBad

local BB = {}

-- SETTINGS.MODULES.BOBBLEHEADS. A Settings.lua kept from before the switch existed has no entry,
-- and that reads as ON.
local function enabled() return SETTINGS.MODULES.BOBBLEHEADS ~= false end

-- =======================================================================
-- KNOBS
-- =======================================================================

local F_PLAYER_STRING = SCHEMA.Changeable.PlayerMadeString

local MARKER_PREFIX = "ante:"     -- ChangeableData[F_PLAYER_STRING] = MARKER_PREFIX .. key
-- Per-actor retry while ChangeableData hasn't replicated yet. *** ROLE-SPLIT. *** The wait is for
-- REPLICATION latency, which only a pure client has. On the authority ChangeableData is local
-- truth: a bare actor at first sight is either a vanilla bobblehead (never ours) or our own deploy
-- whose copy lands within a tick - so a full client-length retry chain there is pure waste against
-- every vanilla bobblehead in the world. Resolved at call time, not load time - role is only known
-- once a world is up.
local RETRY_MS_CLIENT  = 1500     -- client: ~18s per actor, then give up (seenBare latches it)
local RETRY_MAX_CLIENT = 12
local RETRY_MS_AUTH    = 500      -- authority: two quick looks cover the deploy-copy tick
local RETRY_MAX_AUTH   = 2
local function retryMax() return Utils.IsAuthority() and RETRY_MAX_AUTH or RETRY_MAX_CLIENT end
local function retryMs()  return Utils.IsAuthority() and RETRY_MS_AUTH  or RETRY_MS_CLIENT  end
local SWEEP_MS      = 30000       -- rare FindAllOf backstop (bobbleheads predating the notify)
local SWEEP_FAST_PASSES = 3       -- passes at SWEEP_MS before dropping to the heartbeat (see `sweep`)
local SWEEP_SLOW_MS = 300000      -- ...then one walk per 5 min, purely so a missed notify self-heals

local HOST_CLASS = ENUMS.DeployedObjs.BOBBLEHEAD
-- The class NAME as FindAllOf/notify report it (path tail, minus the _C-bearing package half).
local HOST_CLASS_NAME = "Deployed_Bobblehead_ParentBP_C"

local BOBBLE_HOOK = HOST_CLASS .. ":Broadcast_BobbleMyHead"

-- The authority retag rides furniture BeginPlay (see RETAG).
local FURNITURE_CLASS = ENUMS.DeployedObjs.FURNITURE
local BOBBLE_CLASS_PREFIX = "deployed_bobblehead_"   -- lowercase: FName casing isn't ours

-- Engine class for def.Lights. A /Script/ class never GCs, so ASSETS fast-paths it and it stays
-- out of the preload batch.
local POINT_LIGHT_CLASS = "/Script/Engine.PointLightComponent"

-- =======================================================================
-- THE PROTOTYPES - one per tier
--
-- Full field reference (Look/HideHead/HideBody/Overlay/Tint/Mats/Lights/Sounds, overlay sizing
-- math): see AnNotes/Modules/Bobbleheads.md.
--
-- *** SCALE AND TRANSFORM ARE RELATIVE TO THE PARENT, SO THEY COMPOUND. *** An overlay parented to
-- "head"/"body" sits under a scale-1 component and can use absolute numbers; one parented to
-- ANOTHER OVERLAY inherits that overlay's scale, so repeating it squares it (0.165 under a 0.165
-- torso = 0.027, invisible). Something that should match its parent's size wants Scale = 1.
-- =======================================================================

BB.PROTOTYPES = {

    -- -------------------------------------------------------------------
    -- TIER 2 - MESH SWAP. Same host class, both ends of the HeadZ size band: `sniper` is the
    -- humanoid case (small nudge), `jotun` is the outlier (+5.8uu) that proves HeadZ has to move
    -- with the body.
    -- -------------------------------------------------------------------
    sniper = {
        Label = "Order Sniper (mesh swap)",
        Tier  = 2,
        Look  = ENUMS.Collectibles.SNIPER,
    },

    jotun = {
        Label = "Gatekeeper Jotun (mesh swap, outlier HeadZ)",
        Tier  = 2,
        Look  = ENUMS.Collectibles.GKHEAVY,
    },
    -- NEITHER sniper NOR jotun gets a custom item row: both render identically to a vanilla
    -- bobblehead whose item already exists, so a row would just be a duplicate. Only prototypes
    -- that are actually new content earn one - see THE ITEM HALF at the bottom.

    -- -------------------------------------------------------------------
    -- TIER 3 - OVERLAY GEOMETRY. The Chieftain: no Chieftain collectible sculpt exists, so the
    -- Jotun's is borrowed and the mask (the one thing that actually distinguishes a Chieftain) is
    -- overlaid. Head/mask choice reasoning, and why the numbers below are measured not derived:
    -- see AnNotes/Modules/Bobbleheads.md.
    -- -------------------------------------------------------------------
    chieftain = {
        Label = "Gatekeeper Chieftain (mask overlay + barks)",
        Tier  = 3,
        Look  = ENUMS.Collectibles.GKHEAVY,
        Overlay = {
            { Path = ENUMS.GateKeeperParts.HELMET, Parent = "head",
              Scale = 0.70, Loc = { 2.0, 0, 2.04 } },
        },
        Sounds = ENUMS.SOUNDS.GKCHIEF_IDLE,
    },

    -- The Chieftain on a NORMAL-sized (sniper) body - better proportions than the oversized Jotun
    -- sculpt. Measured with /au-bobbletune; see AnNotes/Modules/Bobbleheads.md for what porting the scale
    -- vs. translation from `chieftain` did and didn't predict correctly.
    chieftain_sniper = {
        Label = "Chieftain mask on a sniper body (normal proportions)",
        Tier  = 3,
        Look  = ENUMS.Collectibles.SNIPER,
        Overlay = {
            { Path = ENUMS.GateKeeperParts.HELMET, Parent = "head",
              Scale = 0.46, Loc = { 0, 0, 2.0 } },
        },
        Sounds = ENUMS.SOUNDS.GKCHIEF_IDLE,
        -- NO ITEM: the "Chieftain Bobblehead" row moved to chieftain_full, which is the better
        -- figure; this one stays as the collectible-body comparison and is chat-command only.
    },

    -- Phyter: a real NPC head on a collectible body - NV goggles instead of the skull mask, which
    -- per the base game is the whole Phyter/Chieftain difference. Tier 2 and tier 3 combined.
    -- Modular skeletal parts DO work as overlays here (once written off - see AnNotes/Modules/Bobbleheads.md
    -- for why and how the root-origin offset was solved).
    phyter_sniper = {
        Label = "Gatekeeper Phyter (real NPC head on a sniper body)",
        Tier  = 3,
        Look  = ENUMS.Collectibles.SNIPER,
        HideHead = true,
        Overlay = {
            { Path = ENUMS.GateKeeperParts.HEAD_PHYTER, Skeletal = true, Parent = "head",
              Scale = 0.41, Loc = { 1, 0, -67 } },
        },
        Sounds = ENUMS.SOUNDS.GKCHIEF_IDLE,
        -- Sniper hologram so the placement ghost matches this figure's (sniper) height.
        Item = { Row = "Phyter Bobblehead", HologramFrom = "bobblehead_sniper" },
        -- NOT A REAL PHYTER YET: NV goggles (ENUMS.GateKeeperParts.NV_GOGGLES) are still missing -
        -- one more Overlay entry, measured the same way the Chieftain's mask was.
    },

    -- REPLACE THE BORROWED BODY. Builds the whole figure from the NPC's own skeletal parts
    -- (Gatekeeper all the way down) instead of a real head on a collectible body.
    -- Open question: the T-pose-free reference pose risk, and the scale derivation. Posed and
    -- armed (Chieftain's own firing anim frame, pistol on the torso hand bone). Full reasoning
    -- and the porting math: see AnNotes/Modules/Bobbleheads.md.
    --   * Pose.Time is a GUESS at the best-reading frame - tune live with
    --     `/au-bobbletune i=2 t=<seconds>` (i=1 is the legs; keep both on the SAME time or the
    --     figure tears at the waist).
    --   * THE HEAD IS NOT POSED - its Loc was measured against the reference pose, so a firing
    --     clip that moves the neck needs the head/mask (i=3, i=4) re-tuned alongside it.
    chieftain_full = {
        Label = "Gatekeeper Chieftain, full skeletal figure (posed)",
        Tier  = 3,
        Look  = ENUMS.Collectibles.SNIPER,   -- kept for HeadZ; both meshes are hidden below
        HideBody = true,
        HideHead = true,
        Overlay = {
            -- 1 legs, 2 torso, 3 head, 4 mask, 5 pistol - these are the /au-bobbletune `i` indices.
            { Path = ENUMS.GateKeeperParts.LEGS,  Skeletal = true, Parent = "body",
              Scale = 0.165, Loc = { 0, 0, 0 },
              Pose = { Anim = ENUMS.GateKeeperParts.ANIM_FIRE, Time = 0.5 } },
            { Path = ENUMS.GateKeeperParts.TORSO, Skeletal = true, Parent = "body",
              Scale = 0.165, Loc = { 0, 0, 0 },
              Pose = { Anim = ENUMS.GateKeeperParts.ANIM_FIRE, Time = 0.5 } },
            -- Head + mask as measured on chieftain_sniper (ref pose - see the caveat above).
            { Path = ENUMS.GateKeeperParts.HEAD, Skeletal = true, Parent = "head",
              Scale = 0.41, Loc = { 1, 0, -67 } },
            { Path = ENUMS.GateKeeperParts.HELMET, Parent = "head",
              Scale = 0.46, Loc = { 0, 0, 2.0 } },
            -- The pistol rides the TORSO's hand bone (Parent = 2, socket confirmed against
            -- NPC_Base_ParentBP: `Right Hand = FName("r_hand")`), so it follows the posed arm on
            -- its own and needs no offset.
            -- *** SCALE 1, NOT 0.165. SCALE COMPOUNDS. *** It is RELATIVE to the parent, and the
            -- torso is already at 0.165 - repeating that here gave 0.165*0.165 = 0.027, a pistol
            -- at 1/37th size, which read as "no pistol at all". A weapon in a hand wants exactly
            -- the body's scale, i.e. relative 1.
            { Path = ENUMS.GateKeeperParts.PISTOL, Parent = 2, Socket = "r_hand",
              Scale = 2.5, Rot = { 0, 270, 0 } },
        },
        Sounds = ENUMS.SOUNDS.GKCHIEF_IDLE,
        -- THE item - lives here (not chieftain_sniper) as the figure worth shipping; the Fallow
        -- Patriarch drops this row (GK_DarkLensPatriarchHelpers). HologramFrom is the SNIPER, not
        -- the jotun: the hologram is the placement ghost and this figure is sniper-height (an
        -- earlier jotun hologram drew an oversized ghost - see AnNotes/Modules/Bobbleheads.md).
        Item = { Row = "Chieftain Bobblehead",
                 IconFrom = "armor_helmet_horned",   -- the horned-helmet icon, via a live row
                 HologramFrom = "bobblehead_sniper" },
    },

    -- Same figure, the skull prop instead of the helmet, with its authored tilt countered by a
    -- Roll of -30 (found by bisection - see AnNotes/Modules/Bobbleheads.md for the derivation).
    -- *** If the roll changes, Loc must be recomputed - it is downstream of Roll. Only Loc.X isn't. ***
    chieftain_skull = {
        Label = "Gatekeeper Chieftain (skull prop variant)",
        Tier  = 3,
        Look  = ENUMS.Collectibles.GKHEAVY,
        Overlay = {
            { Path = ENUMS.GateKeeperParts.SKULL, Parent = "head",
              Scale = 0.35, Loc = { 1.43, -3.30, 2.28 }, Rot = { 0, 0, -30 } },
        },
        Sounds = ENUMS.SOUNDS.GKCHIEF_IDLE,
    },

    -- THE MYSTAGOGUE - one whole-body skeletal, meditating, floating. Dropped by the Magus of the
    -- Fallow (GK_DarkLensMageHelpers.MagusDeath), the same acquisition route as the Chieftain's.
    -- *** PARENTED TO THE HEAD ON PURPOSE - THE WHOLE FIGURE IS THE BOBBLE. *** No modular parts
    -- and no collectible sculpt to borrow a head from, so the whole figure hangs off `BobbleHead`
    -- and floats (rather than stands) so the nod-wobble doesn't swing its feet off the base.
    -- Want it standing instead? Parent = "body", Loc = {0,0,0} - a static figure, since
    -- FurnitureMesh never moves. Full derivation and wobble-timeline decode: AnNotes/Modules/Bobbleheads.md.
    -- Numbers are the chieftain_full derivation PORTED, not fresh measurements - settle by eye with
    -- `/au-bobbletune i=1 s= z=`, `t=` to scrub the meditate frame. Look is kept only for HeadZ
    -- (the pivot height); both its meshes hide.
    mystagogue = {
        Label = "Mystagogue (floating meditation, full skeletal)",
        Tier  = 3,
        Look  = ENUMS.Collectibles.SNIPER,
        HideBody = true,
        HideHead = true,
        Overlay = {
            { Path = ENUMS.Components.SK_MYSTAGOGUE, Skeletal = true, Parent = "head",
              Scale = 0.165, Loc = { 0, 0, -12 },
              -- The robe ships Chaos cloth, which does not scale down with the component - see
              -- addOverlay. Turn this off to try the sim if the robe reads too stiff.
              NoCloth = true,
              Pose = { Anim = ENUMS.Anims.MAGE_MEDITATE, Time = 0.5 } },
        },
        Sounds = ENUMS.SOUNDS.MAGE_NARRATIVE,
        -- armor_helmet_mage is the Mystagogue hood, same trick as the Chieftain's horned helmet.
        -- Hologram stays sniper-height to match this figure's proportions.
        Item = { Row = "Mystagogue Bobblehead",
                 IconFrom = "armor_helmet_mage",
                 HologramFrom = "bobblehead_sniper" },
    },

    -- -------------------------------------------------------------------
    -- TIER 3 - THE SYMPH COLLECTIBLE. Same shape as `mystagogue` (whole-body skeletal, host meshes
    -- hidden, hung off BobbleHead, frozen anim frame) plus two new things: a NON-BOBBLEHEAD sculpt
    -- as the base, and def.Lights. Full reasoning (why the composer sculpt hides, wobble-pivot
    -- geometry, scale porting) in AnNotes/Modules/Bobbleheads.md.
    symph = {
        Label = "Symphonist Collectible (floating Symphonist, composer-figurine item)",
        Tier  = 3,
        Look  = ENUMS.Collectibles.COMPOSER,
        HideHead = true,   -- mandatory: COMPOSER has no head mesh to swap in
        -- Composer sculpt hidden on purpose: it can't be split from its standee (one static mesh),
        -- so showing it stacks a whole composer figure under the Symphonist. It still earns its
        -- keep on the ITEM side via fig_comp (icon + placement ghost). HideBody = false to compare.
        HideBody = true,
        Overlay = {
            { Path = ENUMS.Components.SK_SYMPHONIST, Skeletal = true, Parent = "head",
              -- MEASURED with /au-bobbletune (cold guess was under half the real scale).
              Scale = 0.22, Loc = { 0, 0, -25 },
              NoCloth = true,   -- cheap insurance; harmless on a mesh with no cloth assets
              Pose = { Anim = ENUMS.Anims.SYMPH_IDLE, Time = 0.5 } },
        },

        -- The Orchestrator's four finger lights, ported off H.OrchLights (AnteNPCs/SymphonistHelpers.lua) -
        -- same bones/colours only. Numbers cut ~10x: Intensity/Radius/SourceRadius are absolute
        -- world values the 0.22 overlay scale does NOT shrink, so NPC-sized values would light the
        -- whole room; Radius is also kept small so the four close-together finger bones don't blend.
        Lights = {
            { Parent = 1, Socket = "l_index2", Color = { 0.1, 0.1, 0.8 },
              Intensity = 30, Radius = 15, SourceRadius = 10, Scattering = 2 },
            { Parent = 1, Socket = "l_pinky2", Color = { 0.9, 0.8, 0.1 },
              Intensity = 30, Radius = 15, SourceRadius = 10, Scattering = 2 },
            { Parent = 1, Socket = "r_index2", Color = { 0.9, 0.1, 0.1 },
              Intensity = 30, Radius = 15, SourceRadius = 10, Scattering = 2 },
            { Parent = 1, Socket = "r_pinky2", Color = { 0.2, 0.9, 0.1 },
              Intensity = 30, Radius = 15, SourceRadius = 10, Scattering = 2 },
        },

        -- BOTH donors are `fig_comp`, the vanilla Composer Figurine row - its hologram/icon match
        -- Look's own sculpt, so ghost/icon/figure finally agree. ItemClass/DeployedItemClass still
        -- come from ITEM_DONOR (bobblehead_sci) so this deploys a wobbling bobblehead, not
        -- fig_comp's own (BobbleHead-less) class. fig_comp's WorldStaticMesh is the standard
        -- SM_ItemBox_Default, so the packaged/dropped box is unchanged.
        Item = { Row = "Symphonist Collectible",
                 IconFrom = "fig_comp",
                 HologramFrom = "fig_comp" },
    },

    -- -------------------------------------------------------------------
    -- TIER 1 - MATERIAL SWAP, hand-rolled.
    -- *** THE NATIVE TEXTURE-VARIANT CHANNEL WAS ABANDONED HERE. DON'T RE-TRY IT BLIND. ***
    -- `ChangeableData.TextureVariantRow` -> DT_TextureVariants looked ideal (replicates/saves for
    -- free) but applied nothing on a bobblehead across two rounds of testing with every
    -- precondition confirmed good; cause unknown, not worth a third round when the whole payload
    -- is one `SetMaterial` call we can just make ourselves. See AnNotes/Modules/Bobbleheads.md for the
    -- full test record, and why Tint (a MID over the existing material) beats a Mats swap here -
    -- M_CPU_Gold's own texture smears across the sculpt's UVs.
    -- -------------------------------------------------------------------
    gold = {
        Label = "Gold Scientist (tint)",
        Tier  = 1,
        Tint  = { 1.0, 0.78, 0.20 },
        Item  = { Row = "Gilded Scientist Bobblehead", IconFrom = "bobblehead_sci" },
    },
}

-- Every /Game path the module can touch, for the preload + pin batch.
local function allAssetPaths()
    local out = { HOST_CLASS }
    local seen = { [HOST_CLASS] = true }
    local function add(p)
        if p and not seen[p] then seen[p] = true; out[#out + 1] = p end
    end
    for _, def in pairs(BB.PROTOTYPES) do
        if def.Look then add(def.Look.Body); add(def.Look.Head) end
        for _, o in ipairs(def.Overlay or {}) do
            add(o.Path)
            if o.Pose then add(o.Pose.Anim) end
        end
        -- def.Lights needs no entry: PointLightComponent is a /Script/ class, which never GCs.
        for _, s in ipairs(def.Sounds or {}) do add(s) end
        for _, m in pairs(def.Mats or {}) do add(m) end   -- pairs: Mats is slot-keyed, 0-based
    end
    return out
end

-- =======================================================================
-- THE ITEM HALF - custom rows, and getting the marker onto an item
--
-- Every custom bobblehead item deploys `Deployed_Bobblehead_Scientist_C`, not the parent class the
-- chat command uses. Forced, not chosen: CustomItems can only copy a soft-ptr from a LIVE donor
-- row, and no vanilla row points at the parent (all 13 point at subclasses) - bobblehead_sci is
-- the donor. Harmless: it's one of the SILENT subclasses, and identity comes from the marker, not
-- the class; a packaged custom bobblehead redeploys and re-dresses correctly, confirming the
-- notify/sweep covers subclasses.
--
-- WHY THE MARKER HAS TO GO ON THE ITEM. Deploy copies exactly one thing from item to actor -
-- ChangeableData - and does NOT set DeconstructedItemData; that copy lives inside an ubergraph
-- with no discrete UFunction to hook. The actor can't learn which item made it, so the item has to
-- arrive already carrying the answer.
--
-- *** COVERAGE GAP, KNOWN: we stamp in `Abiotic_Item_Dropped_C`'s BeginPlay. *** That covers
-- every item that exists in the world as an actor (/giveitem, loot, drops) and package->redeploy
-- carries the marker itself. It does NOT cover an item created straight into an inventory
-- (crafting result, trader purchase) - those deploy as a plain Scientist bobblehead. Closing that
-- needs a hook on the inventory-add path; worth doing once these are obtainable that way.
-- =======================================================================

-- Item-row soft-ptr fields (same family as ModuleItems/CustomItems' F_* set).
local F_ITEM_ICON     = SCHEMA.Item.InventoryIcon
local F_ITEM_CLASS    = SCHEMA.Item.ItemClass
local F_ITEM_DEPLOYED = SCHEMA.Item.DeployedItemClass
local F_ITEM_HOLOGRAM = SCHEMA.Item.DeployHologramMesh
local F_ITEM_WORLDSM  = SCHEMA.Item.WorldStaticMesh

local ITEM_DONOR = "bobblehead_sci"   -- class/behaviour donor; icon+hologram come from IconFrom
local DROPPED_ITEM_CLASS =
    "/Game/Blueprints/Items/Abiotic_Item_Dropped.Abiotic_Item_Dropped_C"

-- Scalars a FROM-SCRATCH row needs or it comes out wrong (unset = 0/None: a Scale_* of 0 is an
-- invisible item). Deliberately a subset of CustomItems' COMMON_COPY_FIELDS - the weapon/anim
-- entries do not apply to a deployable.
local ITEM_COPY_FIELDS = {
    SCHEMA.Item.Scale_WorldMesh,
    SCHEMA.Item.Scale_FirstPersonMesh,
    SCHEMA.Item.Scale_TPHeldMesh,
    SCHEMA.Item.Scale_Hologram,
    SCHEMA.Item.Weight,
    SCHEMA.Item.StackSize,
    SCHEMA.Item.TryPlaceInHotbar,
    SCHEMA.Item.CanLoseDurability,
    SCHEMA.Item.MaxItemDurability,
    SCHEMA.Item.PlacementOrientationsAllowed,
}

-- Row name -> prototype key, built by RegisterItems and read by stampDroppedItem.
-- *** KEYED LOWERCASE. *** An FName's ToString() returns whatever spelling was registered FIRST
-- in the process, not necessarily ours - an exact-case key would work or not depending on load
-- order ([[af-fname-casing-not-stable]]). A miss here is silent and total: the item never gets
-- marked, so it deploys as an undressed host Scientist.
local itemRowToKey = {}

-- Inject our rows into ModuleItems/CustomItems' table. MUST run before CustomItems.Apply()
-- (main.lua calls it immediately before). Recipe B (FromScratch) because the ROW NAME becomes the
-- display name - which is the only way to get a custom name at all, FText being unwritable.
--   *** THE ROW NAME IS THE SAVE IDENTITY. Choose once, never rename: a rename orphans every
--       saved copy into an invisible dud slot. ***
function BB.RegisterItems()
    if not enabled() then return end

    local CustomItems = require("ModuleItems.CustomItems")
    for key, def in pairs(BB.PROTOTYPES) do
        local item = def.Item
        if item and item.Row then
            itemRowToKey[item.Row:lower()] = key
            CustomItems.CUSTOM_ITEMS["Bobble_" .. key] = {
                Owner = "Bobbleheads",   -- built even with the trader's own items switched off
                Row = item.Row,
                FromScratch = true,
                CopyFrom = ITEM_DONOR,
                CopyFields = ITEM_COPY_FIELDS,
                SoftCopy = {
                    -- Behaviour from the donor; the two LOOK fields are separately sourced.
                    --   * IconFrom can be ANY row - just "whose InventoryIcon do I want" (the
                    --     Chieftain borrows a horned helmet from armor_helmet_horned).
                    --   * HologramFrom must stay a COLLECTIBLE-DEPLOYABLE row: it supplies the
                    --     deploy hologram AND the packaged world mesh, so an armour row would give
                    --     a helmet-shaped (or blank) ghost. It does not need to be a bobblehead_*
                    --     row - the vanilla FIGURINE family (fig_*) is the same shape
                    --     (SM_Collectible_* hologram over SM_ItemBox_Default) and is where the
                    --     orphan sculpts live, e.g. `symph`'s composer ghost. Donor -> hologram:
                    --         fig_comp            SM_Collectible_Composer
                    --         fig_exor            SM_Collectible_Exor
                    --         fig_exor_armored    SM_Collectible_Exor_Armor
                    --         fig_reaper          SM_Collectible_Reaper
                    --         fig_security_bot    SM_Collectible_Security_Bot
                    --         fig_snowman         SM_Collectible_Snowman
                    --         fig_pestplush       SM_Collectible_Plush_Pest
                    --         bobblehead_jotun    SM_Collectible_GKHeavy_Full
                    --         bobblehead_order    SM_Collectible_Grunt_Full
                    --         bobblehead_sniper   SM_Collectible_Sniper_Full
                    [F_ITEM_CLASS]    = ITEM_DONOR,
                    [F_ITEM_DEPLOYED] = ITEM_DONOR,
                    [F_ITEM_WORLDSM]  = item.HologramFrom or ITEM_DONOR,
                    [F_ITEM_ICON]     = item.IconFrom or ITEM_DONOR,
                    [F_ITEM_HOLOGRAM] = item.HologramFrom or ITEM_DONOR,
                },
            }
        end
    end
end

-- [AUTHORITY] Stamp a dropped item, if it is one of ours and not already marked. A packaged one
-- arrives already carrying the marker, so this no-ops on those. Returns true when it stamped.
local function stampDroppedItem(item)
    if Utils.IsActorInvalid(item) then return end

    local row
    pcall(function() row = item.ItemDataRow.RowName:ToString() end)
    local key = row and itemRowToKey[row:lower()]
    if not key then
        -- Every dropped item in the world comes through here, so this is the one place that can
        -- prove "our row never matched" vs "the stamp ran and the deploy lost it".
        Utils.LogDebug("Bobbleheads - dropped item not ours: " .. tostring(row),
            SETTINGS.DEBUG_BOBBLEHEADS)
        return
    end

    local cur
    pcall(function()
        local raw = item.ChangeableData[F_PLAYER_STRING]
        cur = (type(raw) == "string") and raw or raw:ToString()
    end)
    if cur and cur ~= "" then return end   -- already marked (a package drop)

    pcall(function() item.ChangeableData[F_PLAYER_STRING] = MARKER_PREFIX .. key end)
    Utils.LogDebug("Bobbleheads - stamped dropped item " .. row, SETTINGS.DEBUG_BOBBLEHEADS)
    return true
end

-- [AUTHORITY] The stamp, done in the dropped item's BeginPlay on the hook's own live `self`.
--   * Every drop path (the game's Blueprints and our ItemSpawner) sets ItemDataRow and ChangeableData
--     on the deferred actor before FinishSpawningActor, and the item's BeginPlay never rewrites
--     PlayerMadeString - so the row is readable here and the stamp survives the body.
--   * Same reason as the retag (see RETAG): it replaced a NotifyOnNewObject job that read the
--     construction-time wrapper later, for every dropped item in the world.
local stampSlotSeen = {}   -- slot -> true once that slot has stamped an item

local function onDroppedItemBeginPlay(slot, self)
    if not STATE.ModEnabled or not Utils.IsAuthority() then return end
    local ok, stamped = pcall(stampDroppedItem, self:get())
    if ok and stamped and not stampSlotSeen[slot] then
        stampSlotSeen[slot] = true
        Log("Bobbleheads - stamp hook live [" .. slot .. "]")
    end
end

-- =======================================================================
-- MARKER - read/write ChangeableData.PlayerMadeString
-- =======================================================================

-- The prototype key on this actor, or nil for "not stamped yet" (which on a client means
-- ChangeableData hasn't replicated, NOT that it isn't ours - so the caller must retry, never
-- dedup on a nil).
local function markerOf(actor)
    if Utils.IsActorInvalid(actor) then return nil end
    -- UE4SS hands an FString back as userdata on some builds and a bare Lua string on others;
    -- take either rather than letting a :ToString() error read as "no marker" forever.
    local ok, s = pcall(function()
        local raw = actor.ChangeableData[F_PLAYER_STRING]
        if type(raw) == "string" then return raw end
        return raw:ToString()
    end)
    if not ok or type(s) ~= "string" then return nil end
    if s:sub(1, #MARKER_PREFIX) ~= MARKER_PREFIX then return nil end
    local key = s:sub(#MARKER_PREFIX + 1)
    return BB.PROTOTYPES[key] and key or nil
end

-- [AUTHORITY] Stamp the key, then push it. In-place field write only (see MUST-KNOWS).
--   * READS IT BACK. A wrong field name here does not error - it silently writes nowhere and the
--     actor renders as an untouched host default, which looks like a rendering bug and sends you
--     hunting in the wrong half of the module. Verifying makes that specific failure loud.
local function stampMarker(actor, key)
    local ok = pcall(function()
        actor.ChangeableData[F_PLAYER_STRING] = MARKER_PREFIX .. key
    end)
    if not ok then LogBad("Bobbleheads - PlayerMadeString write threw"); return false end

    if markerOf(actor) ~= key then
        LogBad("Bobbleheads - STAMP DID NOT STICK (" .. key .. "). Field name suspect: "
            .. F_PLAYER_STRING)
        return false
    end

    Utils.MarkReplicatedDirty(actor, "ChangeableData")
    return true
end

-- (stampVariant removed with the native texture-variant channel - see the gold def.)

-- =======================================================================
-- THE LOOK (renderer-local; every machine runs this for itself)
-- =======================================================================

-- SetStaticMesh WITHOUT touching collision - see MUST-KNOWS on AVU.SwapStaticMesh.
-- Path re-resolved here, never a wrapper captured earlier (CLAUDE.md S3).
local function swapMesh(comp, path)
    if Utils.IsComponentInvalid(comp) or not path then return false end
    local asset = ASSETS.GetIfValid(path)
    if IsNotValid(asset) then
        LogBad("Bobbleheads - mesh not resident: " .. tostring(path))
        return false
    end
    local ok = pcall(function() comp:SetStaticMesh(asset) end)
    if not ok then LogBad("Bobbleheads - SetStaticMesh failed: " .. tostring(path)) end
    return ok
end

-- Live overlay components per actor, so /au-bobbletune can reach them without re-deriving which
-- of the actor's components are ours. Renderer-local like everything else here; cleared in
-- Register alongside `dressed`.
local overlays = {}   -- GetFullName -> { component, ... }

-- Same book for the light components. Kept SEPARATE from `overlays` rather than appended to it,
-- because /au-bobbletune indexes that table by def order (`i=`) and drives it with scale +
-- rotation - neither of which means anything on a point light. Cleared alongside it in Register.
local lights = {}     -- GetFullName -> { component, ... }

-- Add one overlay component and attach it to the head (wobbles) or body (static).
--   * Deliberately NOT AVU.AttachStaticMesh/AttachSkeletalMesh: both resolve their attach parent
--     via Utils.GetValidMesh(actor), i.e. an NPC's `Mesh` property, which a deployed actor has
--     none of. If these prototypes graduate, that helper grows an opts.ParentComponent and this
--     goes away.
local function addOverlay(actor, parentComp, spec)
    if Utils.IsComponentInvalid(parentComp) then return nil end

    local asset = ASSETS.GetIfValid(spec.Path)
    if IsNotValid(asset) then
        LogBad("Bobbleheads - overlay not resident: " .. tostring(spec.Path))
        return nil
    end

    local clsPath = spec.Skeletal and "/Script/Engine.SkeletalMeshComponent"
                                  or  "/Script/Engine.StaticMeshComponent"
    local cls = ASSETS.GetIfValid(clsPath)
    if IsNotValid(cls) then return nil end

    local comp = actor:AddComponentByClass(cls, false, FTransform(), false)
    if Utils.IsComponentInvalid(comp) then return nil end

    -- Collision off BEFORE the mesh lands, and re-validate: AddComponentByClass can run BP
    -- construction, so the actor/asset are re-checked rather than trusted.
    comp:SetCollisionEnabled(0)
    comp:SetGenerateOverlapEvents(false)
    -- *** A POSED SKELETAL MUST KEEP ITS TICK. *** A SkeletalMeshComponent evaluates its
    -- animation during its own tick, so a component created with tick OFF never runs
    -- RefreshBoneTransforms and renders the REFERENCE pose forever - no matter what SetAnimation
    -- says. That is why the first posed chieftain_full still T-posed. Un-posed overlays keep tick
    -- off: ref pose is exactly what they want, and it is free.
    if not (spec.Skeletal and spec.Pose) then
        comp:SetComponentTickEnabled(false)
    end
    -- *** CLOTH MUST BE KILLED BEFORE THE MESH LANDS. *** The clothing actors are created inside
    -- SetSkeletalMeshAsset (RecreateClothingActors reads this flag), so a write AFTER the swap is
    -- too late for the sim that is already running. Chaos cloth does not scale with the component
    -- either - on a 0.165 figurine a robe authored for a full-size character hangs and swings at
    -- full-size gravity, which reads as the mesh being broken. Only meaningful on a skeletal that
    -- HAS cloth (SK_Gatekeeper_Mystagogue's robe is the first); harmless everywhere else.
    if spec.NoCloth then
        pcall(function() comp.bDisableClothSimulation = true end)
    end
    if Utils.IsActorInvalid(actor) or IsNotValid(asset) then return nil end

    -- spec.Socket attaches to a BONE on the parent instead of its origin ("r_hand" / "l_hand" are
    -- what NPC_Base_ParentBP names the hands on this family). Only meaningful when the parent is
    -- itself a skeletal overlay - see the Parent-index note in the def-shape banner.
    comp:K2_AttachToComponent(parentComp, FName(spec.Socket or "None"), 2, 2, 2, true)
    if Utils.IsComponentInvalid(comp) then return nil end

    if spec.Skeletal then
        comp:SetSkeletalMeshAsset(asset)
    else
        comp:SetStaticMesh(asset)
    end
    if Utils.IsComponentInvalid(comp) then return nil end

    -- POSE: freeze a single frame of an animation, so a skeletal renders something other than its
    -- arms-out reference pose. Single-node mode + SetPosition + Stop is the standard way to hold
    -- one frame; without Stop() it would play.
    --   * Must come AFTER SetSkeletalMeshAsset (the anim binds against the live skeleton).
    --   * The anim is preloaded with the rest of the set (allAssetPaths pulls Pose.Anim), and
    --     re-resolved here by path like everything else (CLAUDE.md S3).
    --   * Skipped rather than risked if it is not resident.
    if spec.Skeletal and spec.Pose and spec.Pose.Anim then
        local anim = ASSETS.GetIfValid(spec.Pose.Anim)
        if IsNotValid(anim) then
            LogBad("Bobbleheads - pose anim not resident: " .. tostring(spec.Pose.Anim))
        else
            -- *** BOTH ARGS, ALWAYS. *** SetAnimationMode is
            -- (EAnimationMode, bool bForceInitAnimScriptInstance) - a one-arg call is the
            -- silent-no-op family (CLAUDE.md S3: UE4SS errors, the pcall eats it, and it reads
            -- exactly like success). `true` also forces the single-node instance to exist NOW,
            -- rather than whenever the component next feels like initialising one.
            local ok = pcall(function()
                comp:SetAnimationMode(1, true)    -- EAnimationMode::AnimationSingleNode
                comp:SetAnimation(anim)
                comp:SetPosition(spec.Pose.Time or 0, false)
                comp:Stop()                       -- hold the frame instead of playing it
            end)
            if not ok then LogBad("Bobbleheads - pose call threw on " .. tostring(spec.Path)) end
        end
    end

    local s = spec.Scale or 1
    local l = spec.Loc or {}
    local r = spec.Rot or {}
    comp:K2_SetRelativeLocationAndRotation(
        FVector(l[1] or 0, l[2] or 0, l[3] or 0),
        FRotator(r[1] or 0, r[2] or 0, r[3] or 0),   -- pitch, yaw, roll
        false, {}, true)
    comp:SetRelativeScale3D(FVector(s, s, s))

    return comp
end

-- A PointLightComponent on the same Parent grammar as addOverlay, so it can ride a BONE of a
-- posed skeletal overlay (the symph collectible's four finger lights). See the def-shape banner
-- for why this is not AVU.AttachPointLight.
--   * Renderer-only and non-replicating, like everything else in applyLook - each machine builds
--     its own from the marker.
--   * The class is a /Script/ one, so GetIfValid fast-paths it and it needs no preload entry.
local function addLight(actor, parentComp, spec)
    if Utils.IsComponentInvalid(parentComp) then return nil end

    local cls = ASSETS.GetIfValid(POINT_LIGHT_CLASS)
    if IsNotValid(cls) then
        LogBad("Bobbleheads - PointLightComponent class missing")
        return nil
    end

    local comp = actor:AddComponentByClass(cls, false, FTransform(), false)
    if Utils.IsComponentInvalid(comp) then return nil end
    -- AddComponentByClass can run BP construction, so the actor and the parent are re-checked
    -- rather than trusted across it (same guard addOverlay uses).
    if Utils.IsActorInvalid(actor) or Utils.IsComponentInvalid(parentComp) then return nil end

    comp:K2_AttachToComponent(parentComp, FName(spec.Socket or "None"), 2, 2, 2, true)
    if Utils.IsComponentInvalid(comp) then return nil end

    comp:SetComponentTickEnabled(false)
    comp:SetCastShadows(false)

    local c = spec.Color or {}
    comp:SetLightColor(FLinearColor(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1), true)

    local l = spec.Loc or {}
    comp:K2_SetRelativeLocationAndRotation(
        FVector(l[1] or 0, l[2] or 0, l[3] or 0), FRotator(), false, {}, true)
    -- Scale 1 under a SnapToTarget attach: a light has no geometry to size, and the parent
    -- overlay's 0.13 must NOT compound into anything here.
    comp:SetRelativeScale3D(FVector(1, 1, 1))

    if spec.Intensity    then comp:SetIntensity(spec.Intensity) end
    if spec.Scattering   then comp:SetVolumetricScatteringIntensity(spec.Scattering) end
    if spec.Radius       then comp:SetAttenuationRadius(spec.Radius) end
    if spec.SourceRadius then comp:SetSourceRadius(spec.SourceRadius) end

    return comp
end

-- Build one prototype's look on one actor. Renderer-local, idempotent, and safe to re-run (a
-- level re-stream re-sights the actor under a fresh name and re-applies).
--
-- *** STEP ORDER IS LOAD-BEARING: meshes -> materials -> overlays -> lights. ***
--   * Meshes BEFORE materials, because SetStaticMesh resets a component's materials to the new
--     mesh's defaults - a material set first would be silently wiped by the swap.
--   * Overlays LAST, so a def that both recolours and overlays does not tint its own overlay:
--     the material step targets only FurnitureMesh + BobbleHead, which by then are the only two
--     mesh components on the actor.
local function applyLook(actor, key)
    local def = BB.PROTOTYPES[key]
    if not def or Utils.IsActorInvalid(actor) then return false end

    -- Every step below needs these, so fetch once and fail loudly rather than per-step.
    local body, head
    pcall(function() body = actor.FurnitureMesh end)
    pcall(function() head = actor.BobbleHead end)
    if Utils.IsComponentInvalid(body) or Utils.IsComponentInvalid(head) then
        LogBad("Bobbleheads - " .. key .. ": mesh components missing")
        return false
    end

    -- STEP 1 - MESHES.
    if def.Look then
        if def.HideBody then
            -- VISIBILITY only, never SetStaticMesh(nil): the interaction trace and
            -- GetHighlightComponents both run off FurnitureMesh, so clearing the mesh would make
            -- the bobblehead un-pokeable. Hidden geometry still collides.
            pcall(function() body:SetVisibility(false, false) end)
        else
            swapMesh(body, def.Look.Body)
            pcall(function() body:SetVisibility(true, false) end)
        end

        if def.HideHead then
            -- Hide the MESH, keep the COMPONENT: it still carries the timeline's wobble and any
            -- overlay is parented to it.
            pcall(function() head:SetVisibility(false, false) end)
        else
            swapMesh(head, def.Look.Head)
            pcall(function() head:SetVisibility(true, false) end)
        end

        -- HeadZ travels with the body (see MUST-KNOWS). Rotation is the timeline's; location is ours.
        if def.Look.HeadZ then
            pcall(function()
                head:K2_SetRelativeLocation(FVector(0.22, 0, def.Look.HeadZ), false, {}, false)
            end)
        end
    end

    -- STEP 2 - MATERIALS (tier 1), on the two visible components. See the gold def for why this
    -- does not go through the native texture-variant channel.
    --   * AFTER the mesh swap, because SetStaticMesh resets materials to the new mesh's defaults.
    --   * Paths re-resolved here, never captured (CLAUDE.md S3); a missing one is logged and
    --     skipped rather than handed to a setter.
    for slot, path in pairs(def.Mats or {}) do
        local mat = ASSETS.GetIfValid(path)
        if IsNotValid(mat) then
            LogBad("Bobbleheads - " .. key .. ": material not resident: " .. tostring(path))
        else
            pcall(function() body:SetMaterial(slot, mat) end)
            pcall(function() head:SetMaterial(slot, mat) end)
        end
    end

    -- Tint: a MID over each component's CURRENT material, so the sculpt keeps its own texture.
    --   * Every slot, because a multi-slot sculpt half-tinted looks like a bug.
    --   * SetVectorParameterValue takes FLinearColor BY VALUE (Engine.hpp:19244), so a Lua table
    --     is safe here. The KISMET overload of the same name takes a `const FLinearColor&` and
    --     WOULD be the uncatchable AV - do not "simplify" this onto it.
    --     ([[ue4ss-const-ref-struct-param-av]])
    --   * MID creation is per-dress, never per-tick (the microlag rule).
    if def.Tint then
        local c = def.Tint
        local col = { R = c[1] or 1, G = c[2] or 1, B = c[3] or 1, A = c[4] or 1 }
        for _, comp in ipairs({ body, head }) do
            local n = 0
            pcall(function() n = comp:GetNumMaterials() or 0 end)
            for slot = 0, n - 1 do
                pcall(function()
                    local mid = comp:CreateAndSetMaterialInstanceDynamic(slot)
                    if not IsNotValid(mid) then
                        mid:SetVectorParameterValue(FName("DiffuseColor"), col)
                    end
                end)
            end
        end
    end

    -- STEP 3 - OVERLAYS, last (they are additive and nothing above should see them).
    local id = Utils.ActorKey(actor)
    if id then overlays[id] = nil; lights[id] = nil end
    local made = {}   -- index -> component, so a later spec can parent onto an earlier one
    for i, spec in ipairs(def.Overlay or {}) do
        -- Parent: "body" / "head" (the two real components), or the INDEX of an earlier overlay -
        -- which is how a weapon hangs off a posed torso's hand bone rather than off the base.
        local parent
        if type(spec.Parent) == "number" then
            parent = made[spec.Parent]
            if not parent then
                LogBad("Bobbleheads - " .. key .. ": overlay " .. i .. " wants overlay "
                    .. spec.Parent .. ", which does not exist yet (parents must come first)")
            end
        else
            parent = (spec.Parent == "body") and body or head
        end

        local comp = parent and addOverlay(actor, parent, spec)
        if comp then
            made[i] = comp
            if id then
                overlays[id] = overlays[id] or {}
                overlays[id][#overlays[id] + 1] = comp
            end
        end
    end

    -- STEP 4 - LIGHTS, after the overlays, because a light almost always wants to hang off one
    -- (an index Parent reads `made`, so the overlay has to exist first).
    for i, spec in ipairs(def.Lights or {}) do
        local parent
        if type(spec.Parent) == "number" then
            parent = made[spec.Parent]
            if not parent then
                LogBad("Bobbleheads - " .. key .. ": light " .. i .. " wants overlay "
                    .. spec.Parent .. ", which does not exist (a light cannot precede its overlay)")
            end
        else
            parent = (spec.Parent == "body") and body or head
        end

        local comp = parent and addLight(actor, parent, spec)
        if comp and id then
            lights[id] = lights[id] or {}
            lights[id][#lights[id] + 1] = comp
        end
    end

    return true
end

-- =======================================================================
-- LIVE TUNING - /au-bobbletune
--
-- Overlay placement is derived from mesh bounds, but "sits proud" and authored-tilt judgement
-- calls can only be settled by looking - this applies numbers live so that loop is seconds instead
-- of a code edit + mod restart. RENDERER-local: tunes only the copy on this machine, and a
-- re-dress (level re-stream) reverts it to the def - not a persistence mechanism, put whatever
-- converges back into the def by hand.
-- =======================================================================

-- Nearest host-class bobblehead to `fromLoc`, or nil.
local function nearestBobblehead(fromLoc)
    local ok, actors = pcall(FindAllOf, HOST_CLASS_NAME)
    if not ok or not actors then return nil end
    local best, bestD
    for _, a in ipairs(actors) do
        if Utils.IsActorValid(a) then
            local loc
            pcall(function() loc = a:K2_GetActorLocation() end)
            if loc then
                local d = Utils.DistSq(fromLoc, loc)
                if d and (not bestD or d < bestD) then best, bestD = a, d end
            end
        end
    end
    return best
end

-- [RENDERER] Apply s/x/y/z/pitch/yaw/roll to the nearest bobblehead's overlays. Omitted values
-- keep whatever the component currently has, so one axis can be nudged at a time.
function BB.Tune(fromLoc, p)
    if not Utils.HasRenderer() or not fromLoc then return end

    local actor = nearestBobblehead(fromLoc)
    if not actor then Log("Bobbleheads - tune: no bobblehead nearby"); return end

    local id = Utils.ActorKey(actor)
    local comps = id and overlays[id]
    if not comps or #comps == 0 then
        Log("Bobbleheads - tune: nearest bobblehead has no overlays (mesh-swap or material only)")
        return
    end

    -- `i` picks ONE overlay (1-based, in def order); omitted tunes them all. Required for any
    -- multi-part prototype - chieftain_full's legs/torso/head/mask are at deliberately different
    -- scales, and tuning them together would flatten all four to one value.
    if p.i and not comps[p.i] then
        Log(string.format("Bobbleheads - tune: no overlay %d (this one has %d)", p.i, #comps))
        return
    end

    local n = 0
    local s, x, y, z, pitch, yaw, roll
    for idx, comp in ipairs(comps) do
        if (not p.i or p.i == idx) and not Utils.IsComponentInvalid(comp) then
            -- Read current values so an omitted key means "leave this axis alone".
            local cr, cs, cl
            pcall(function() cr = comp.RelativeRotation end)
            pcall(function() cs = comp.RelativeScale3D end)
            pcall(function() cl = comp.RelativeLocation end)

            s     = p.s     or (cs and cs.X)     or 1
            x     = p.x     or (cl and cl.X)     or 0
            y     = p.y     or (cl and cl.Y)     or 0
            z     = p.z     or (cl and cl.Z)     or 0
            pitch = p.pitch or (cr and cr.Pitch) or 0
            yaw   = p.yaw   or (cr and cr.Yaw)   or 0
            roll  = p.roll  or (cr and cr.Roll)  or 0

            pcall(function()
                comp:K2_SetRelativeLocationAndRotation(
                    FVector(x, y, z), FRotator(pitch, yaw, roll), false, {}, true)
                comp:SetRelativeScale3D(FVector(s, s, s))
            end)

            -- `t` re-poses: scrub to a different frame of whatever anim this overlay already
            -- holds. Only meaningful on a skeletal that was given a Pose - on anything else
            -- SetPosition has no animation to scrub and simply does nothing.
            if p.t then
                pcall(function()
                    comp:SetPosition(p.t, false)
                    comp:Stop()
                end)
            end
            n = n + 1
        end
    end

    if n == 0 then Log("Bobbleheads - tune: overlays all stale"); return end

    -- Echo it in def-paste form, so a good result can go straight into the prototype.
    Log(string.format("Bobbleheads - tuned overlay %s of %d:  Scale = %.3f, "
        .. "Loc = { %.2f, %.2f, %.2f }, Rot = { %.1f, %.1f, %.1f }%s",
        p.i and tostring(p.i) or ("ALL(" .. n .. ")"), #comps, s, x, y, z, pitch, yaw, roll,
        p.t and string.format(", Pose.Time = %.2f", p.t) or ""))
end

-- =======================================================================
-- RENDERER - pick up every host-class actor and dress it
-- (TraderMirror's shape: notify + bounded retry + rare sweep, dedup by GetFullName)
-- =======================================================================

-- *** THESE STORE THE KEY, NOT `true`. *** A destroyed actor's GetFullName can be reused by the
-- next actor in that UObject slot ([[anteup2-actor-wrapper-identity]]), and bobbleheads are
-- spawned/packaged repeatedly - a bare boolean would let a fresh bobblehead inherit a dead one's
-- "already handled". Comparing the stored KEY makes a slot reuse self-correcting.
local dressed  = {}   -- GetFullName -> prototype key the look was applied for
local retrying = {}   -- GetFullName -> true (a retry chain is in flight)

-- *** THE CHAIN IS FOR REPLICATION LATENCY, NOT FOR "IS THIS ONE OURS". *** A world with a
-- decorated base is full of vanilla bobbleheads that have no marker and never will; a re-sight
-- must NOT re-seed a retry chain for those, or a sweep re-triggers thousands of pointless
-- WorkQueue drains per minute (see AnNotes/Modules/Bobbleheads.md). One cheap markerOf read and out -
-- only a genuinely new object gets a chain.
local seenBare = {}   -- GetFullName -> true (a chain already ran to exhaustion; do not re-seed)

-- `fresh` = this sighting came from NotifyOnNewObject, i.e. a brand-new UObject. It clears the
-- no-re-seed latch, which is also what keeps a GetFullName slot REUSE honest ([[anteup2-actor-wrapper-identity]]):
-- a new bobblehead landing in a dead one's slot arrives through the notify, so it cannot inherit
-- the dead one's "already gave up" and skip its own retries.
local retagRow   -- defined in the RETAG section below; consider() needs it on a pure client

local function consider(actor, attemptsLeft, fresh)
    if Utils.IsActorInvalid(actor) then return end

    local id = Utils.ActorKey(actor)
    if not id then return end
    if fresh then seenBare[id] = nil end

    local key = markerOf(actor)
    if not key then
        -- No marker YET: either ChangeableData hasn't replicated, or this is one of the game's own
        -- bobbleheads. Retry (bounded), and do NOT mark dressed.
        if seenBare[id] then return end                                 -- gave up on this one already
        if (attemptsLeft or 0) <= 0 then
            retrying[id] = nil
            seenBare[id] = true                                         -- waited it out: it is not ours
            return
        end
        if retrying[id] and attemptsLeft == retryMax() then return end   -- a chain is already running
        retrying[id] = true
        Utils.QueueWork(function() consider(actor, (attemptsLeft or retryMax()) - 1) end, retryMs())
        return
    end

    -- The marker is here, so this machine can name the figure too (see RETAG: the row does not
    -- replicate, and a client only learns WHICH figure this is at this point).
    pcall(retagRow, actor)

    if dressed[id] == key then return end   -- same actor, same prototype: nothing to redo

    retrying[id] = nil
    seenBare[id] = nil
    if applyLook(actor, key) then
        dressed[id] = key
        Utils.LogDebug("Bobbleheads - dressed " .. key, SETTINGS.DEBUG_BOBBLEHEADS)
    end
end

-- =======================================================================
-- RETAG - make packaging give back OUR item, and the hover text name OUR figure
-- =======================================================================

local retagged = {}   -- GetFullName -> prototype key the retag was done for (see `dressed`)

-- [EVERY MACHINE] Point DeconstructedItemData at the prototype's own row.
-- Without this, packaging returns whatever the DEPLOYED CLASS's CDO names - `bobblehead_sci` for
-- every custom bobblehead, since they all deploy the Scientist subclass - and the custom item is
-- destroyed by its own round-trip. Deploy never sets this field, so it is ours to write.
--   * THE FIELD DOES NOT REPLICATE, and two different machines read it: the AUTHORITY when it
--     packages (DropPackagedItem), and WHOEVER IS LOOKING when the hover text is built
--     (GetItemFullName off this row). So each machine writes its own copy - a server-only retag
--     left every joined client reading "GATE Scientist Bobblehead" on a figure that looked right.
--   * `force` skips the `retagged` short-cut, for a caller that knows this is a new actor.
retagRow = function(actor, force)
    if Utils.IsActorInvalid(actor) then return end

    local id = Utils.ActorKey(actor)
    if not id then return end

    local key = markerOf(actor)
    if not key then return end   -- not ours, or placed by /au-bobble with no item row
    if not force and retagged[id] == key then return end   -- same actor, same prototype (see `dressed`)

    local def = BB.PROTOTYPES[key]
    local row = def and def.Item and def.Item.Row
    if not row then retagged[id] = key; return end   -- prototype has no item; nothing to fix

    local ok = pcall(function() actor.DeconstructedItemData.RowName = FName(row) end)
    if not ok then LogBad("Bobbleheads - DeconstructedItemData write threw"); return end

    -- *** CASE-FOLDED READBACK. *** The WRITE is fine either way (FNames compare
    -- case-insensitively, so packaging resolves the right row), but ToString() returns whatever
    -- spelling was registered FIRST in the process ([[af-fname-casing-not-stable]]), which can
    -- differ from ours. An exact compare would report a false failure AND return early without
    -- setting retagged[id], so the retag would re-run on every single sighting, forever.
    local back
    pcall(function() back = actor.DeconstructedItemData.RowName:ToString() end)
    if tostring(back):lower() ~= row:lower() then
        LogBad("Bobbleheads - RETAG DID NOT STICK (" .. row .. "; read back "
            .. tostring(back) .. ") - packaging will return the vanilla item")
        return
    end

    retagged[id] = key
    Utils.LogDebug("Bobbleheads - retagged " .. key .. " -> " .. row, SETTINGS.DEBUG_BOBBLEHEADS)
end

-- [AUTHORITY] The packaging retag, done in BeginPlay on the hook's own live `self`.
--   * The marker is already aboard: a player deploy and a save restore both set ChangeableData on the
--     deferred actor before FinishSpawningActor. BB.Place stamps after BeginPlay, so it retags itself.
--   * Field work only, so it runs in the hook and keeps no wrapper. The queued read through a
--     NotifyOnNewObject wrapper it replaces is the suspect in a dedicated-server AV
--     ([[anteup2-queued-fstring-read-av]]).
--   * Fires for every piece of furniture; the class-name test is the cheap filter.
local retagSlotSeen = {}   -- slot -> true once that slot has delivered a bobblehead

local function onFurnitureBeginPlay(slot, self)
    if not STATE.ModEnabled or not Utils.IsAuthority() then return end
    local actor = self:get()
    local cls = Utils.GetActorClassName(actor)
    if not cls or cls:lower():sub(1, #BOBBLE_CLASS_PREFIX) ~= BOBBLE_CLASS_PREFIX then return end

    if not retagSlotSeen[slot] then
        retagSlotSeen[slot] = true
        Log("Bobbleheads - retag hook live [" .. slot .. "]")
    end
    pcall(retagRow, actor, true)
end

-- Arm one authority BeginPlay hook (the retag and the dropped-item stamp).
--   * Session-latched on STATE[latch], and the class loaded first, for the same reasons as
--     armBobbleHook below.
--   * Engine-dispatched, so both slots fire; armed on both because the bodies are idempotent.
local function armBeginPlayHook(latch, classPath, body, label)
    if STATE[latch] then return end
    STATE[latch] = true

    ASSETS.LoadAsync({ classPath }, function()
        ASSETS.WarmPinned({ classPath })   -- a class that unloads takes its hook with it
        local ok, err = pcall(RegisterHook, classPath .. ":ReceiveBeginPlay",
            function(self) body("pre", self) end,
            function(self) body("post", self) end)
        if ok then
            Log("Bobbleheads - " .. label .. " hook registered")
        else
            STATE[latch] = false
            LogBad("Bobbleheads - " .. label .. " hook not registered: " .. tostring(err))
        end
    end)
end

-- One renderer sighting: dress it, and retag from inside consider() once the marker has arrived.
local function onSighted(actor, fresh)
    if Utils.IsActorInvalid(actor) then return end
    if Utils.HasRenderer() then pcall(consider, actor, retryMax(), fresh) end
end

-- Backstop for actors that predate the notify: a save/reload restores every bobblehead at once,
-- and a client joining mid-session inherits a world full of them. Rare on purpose - FindAllOf is
-- O(all UObjects). Dies on teardown; the next Register re-queues it.
--
-- *** IT BACKS OFF, because the job it does is a STARTUP job. *** Everything created after the
-- notify is armed comes through the notify, so the only actors a re-walk can ever find that the
-- notify missed are the ones already in the world at Register - all of them, on the first pass
-- only. A flat re-walk cadence cost real frame time for a job that stops mattering after pass one
-- (see AnNotes/Modules/Bobbleheads.md). So: a few fast passes to cover a still-streaming world, then a
-- slow heartbeat that only exists so a missed notify self-heals eventually.
--
-- On the AUTHORITY it also retags whatever began play before the retag hook was armed (a save restore
-- lands before InitMod), straight off FindAllOf's wrapper. A dedicated server has nothing else to
-- sweep for, so it stops after the fast passes.
local sweepsDone = 0
local function sweep()
    if not STATE.ModEnabled then return end
    local renderer = Utils.HasRenderer()
    local ok, actors = pcall(FindAllOf, HOST_CLASS_NAME)
    if ok and actors then
        for _, a in ipairs(actors) do
            if Utils.IsActorValid(a) then
                if Utils.IsAuthority() then pcall(retagRow, a) end
                if renderer then onSighted(a) end
            end
        end
    end
    sweepsDone = sweepsDone + 1
    if not renderer and sweepsDone >= SWEEP_FAST_PASSES then return end
    Utils.QueueWork(sweep, (sweepsDone < SWEEP_FAST_PASSES) and SWEEP_MS or SWEEP_SLOW_MS)
end

-- =======================================================================
-- AUDIO - one hook, fires on every machine because the function is a multicast
-- =======================================================================

-- The bark. Lifted out of the registration below so the arming reads as arming; it also keeps the
-- LoadAsync callback capturing nothing but a function reference.
local function onBobble(self)
    if not STATE.ModEnabled then return end
    -- Multicast: this also runs on the server/dedicated, which has no ears. Sound is renderer
    -- work, and PlaySoundAtLocation on a dedicated is pure waste.
    if not Utils.HasRenderer() then return end

    local actor = self:get()
    local key = markerOf(actor)
    if not key then return end

    local def = BB.PROTOTYPES[key]
    local lines = def and def.Sounds
    if not lines or #lines == 0 then return end

    -- NOTE: each machine rolls its own line, so in MP two players at the same shelf can hear
    -- different barks. The game's own fix is server-rolls-then-broadcasts-the-index (see
    -- Deployed_Bobblehead_Leyak's Broadcast_LeyakSFX); ours would be a ClientFX push. Left as
    -- a known gap - it costs nothing in SP, which is what these prototypes are for.
    local snd = ASSETS.GetIfValid(lines[math.random(1, #lines)])
    -- SKIP, never load: this is inside a UE4SS hook, so a cold load here is the S2 deadlock.
    -- Register pins these; an unpinned miss means the pin failed, and silence beats a freeze.
    if IsNotValid(snd) then return end

    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) then return end
        local gs = UEHelpers.GetGameplayStatics()
        local world = Utils.GetWorld()
        if not gs or IsNotValid(world) then return end

        local loc
        pcall(function() loc = actor.HeadCollider:K2_GetComponentLocation() end)
        if not loc then pcall(function() loc = actor:K2_GetActorLocation() end) end
        if not loc then return end

        pcall(function()
            gs:PlaySoundAtLocation(world, snd, loc, FRotator(0, 0, 0),
                1.0, 1.0, 0.0, nil, nil, nil, nil)
        end)
    end, 0)
end

-- Arms ONCE PER UE4SS SESSION (a hook can't be unregistered), so it gates on role at FIRE time,
-- not here - the same contract as the notify below.
--
-- Load the class first rather than just pcall'ing the register: RegisterHook throws while the
-- target /Game/ class is unloaded (CLAUDE.md 2), and a save that has never had a bobblehead in it never
-- loads Deployed_Bobblehead_ParentBP - a bare pcall'd register throws on every world load of such
-- a save and the barks go silently off for the whole session. LoadAsync, then register inside its
-- callback (the HardMode/ItemMods recipe). The latch releases only on a real registration failure,
-- so the next InitMod still gets a retry.
local function armBobbleHook()
    if STATE.BobbleHookArmed then return end
    STATE.BobbleHookArmed = true

    ASSETS.LoadAsync({ HOST_CLASS }, function()
        ASSETS.WarmPinned({ HOST_CLASS })   -- a class that unloads takes its hook with it
        local ok, err = pcall(RegisterHook, BOBBLE_HOOK, onBobble)
        if ok then
            Log("Bobbleheads - bobble hook registered")
        else
            STATE.BobbleHookArmed = false
            LogBad("Bobbleheads - bobble hook not registered: " .. tostring(err))
        end
    end)
end

-- =======================================================================
-- AUTHORITY - place one
-- =======================================================================

-- [AUTHORITY] Drop a prototype bobblehead at `location`. Off-hook + preloaded via
-- AVU.SpawnDeployable (CLAUDE.md S2); the stamp happens in OnSpawned, i.e. after
-- FinishSpawningActor, so the replicated push has a live actor to travel from.
function BB.Place(key, location, rotation)
    if not Utils.IsAuthority() then return false end

    local def = BB.PROTOTYPES[key]
    if not def then LogBad("Bobbleheads - unknown prototype: " .. tostring(key)); return false end
    if not location then return false end

    AVU.SpawnDeployable(HOST_CLASS, location, rotation, {
        Preload = allAssetPaths(),
        OnSpawned = function(actor)
            if Utils.IsActorInvalid(actor) then return end

            -- SpawnDeployable defaults every deployable to no-save. These prototypes exist partly
            -- to test that the marker SURVIVES a save/reload, so opt back in.
            pcall(function() actor.NoSave = false end)

            -- Report the STAMP, not the spawn. An unstamped bobblehead still exists, still
            -- bobbles, and renders as the untouched host default - so "placed" alone would read
            -- as success for the one failure that looks exactly like a rendering bug.
            local stamped = stampMarker(actor, key)
            if stamped then pcall(retagRow, actor, true) end   -- BeginPlay saw no marker yet

            -- Host/SP has a renderer and gets no notify for an actor it just spawned itself, so
            -- dress it here. Clients come through the notify path.
            if Utils.HasRenderer() then
                Utils.QueueWork(function() consider(actor, retryMax(), true) end, 0)
            end

            if stamped then
                Log("Bobbleheads - placed " .. def.Label)
            else
                LogBad("Bobbleheads - placed " .. def.Label
                    .. " but UNSTAMPED; it will render as a plain Scientist bobblehead")
            end
        end,
    })
    return true
end

function BB.PrototypeKeys()
    local keys = {}
    for k in pairs(BB.PROTOTYPES) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

-- =======================================================================
-- REGISTER
-- =======================================================================

-- Runs ONCE PER WORLD (InitMod), so it must be safe to re-enter and must RE-QUEUE anything that
-- lives on the WorkQueue - teardown wipes the queue, and a "still armed" latch would leave every
-- world after the first with no sweep at all (the exact hole TraderMirror's old loop had).
-- Session-scoped things (the notify and the hook, neither of which can be unregistered) latch on
-- STATE instead and gate on role at fire time.
function BB.Register()
    if not enabled() then return end

    -- Drop old-world wrappers (CLAUDE.md S3 world-leak rule); stale retry chains already died
    -- with the WorkQueue wipe.
    dressed  = {}
    retrying = {}
    seenBare = {}
    overlays = {}
    lights   = {}
    retagged = {}
    retagSlotSeen = {}
    stampSlotSeen = {}
    sweepsDone = 0   -- new world = a new set of pre-existing bobbleheads to catch up on

    -- AUTHORITY: stamp our marker onto dropped custom bobblehead items, so it is already aboard by
    -- the time one is deployed (see THE ITEM HALF for the coverage gap), and the packaging retag
    -- (see RETAG). Session-latched, role-checked at fire time.
    if Utils.IsAuthority() then
        armBeginPlayHook("BobbleItemHookArmed", DROPPED_ITEM_CLASS, onDroppedItemBeginPlay, "stamp")
        armBeginPlayHook("BobbleRetagHookArmed", FURNITURE_CLASS, onFurnitureBeginPlay, "retag")
    end

    -- Everything below is renderer work - no meshes to dress or bark to hear on a dedicated server -
    -- except the sweep's catch-up retag.
    local renderer = Utils.HasRenderer()

    -- Pin the asset set so neither the dress nor the bark can cold-load. PinPaths is a no-op
    -- without ASSET_KEEPER; the LoadAsync in front of it covers that case.
    if renderer then
        local paths = allAssetPaths()
        ASSETS.LoadAsync(paths, function() KEEPER.PinPaths(paths) end)
    end

    if renderer and not STATE.BobbleNotifyArmed then
        STATE.BobbleNotifyArmed = true
        -- NEVER touch the object inside the notify - queue it (the Coworker/TraderMirror precedent).
        -- This fires for SUBCLASSES too, which is load-bearing: a custom item deploys the Scientist
        -- subclass, not the parent (see THE ITEM HALF), and that path is already confirmed working.
        pcall(NotifyOnNewObject, HOST_CLASS, function(actor)
            Utils.QueueWork(function()
                -- fresh=true: a brand-new UObject, so it gets a full retry chain even if its
                -- GetFullName matches one we previously gave up on (see `seenBare`).
                if STATE.ModEnabled then onSighted(actor, true) end
            end, 0)
        end)
    end

    if renderer then armBobbleHook() end

    -- Always (re-)queue: see the banner.
    Utils.QueueWork(sweep, 2000)   -- seed soon (restored/pre-existing), then the slow cadence
    Log("Bobbleheads registered (" .. #BB.PrototypeKeys() .. " prototypes)")
end

-- =======================================================================
-- ACQUISITION - still open
--
-- The items exist and round-trip, but nothing GIVES you one yet except `/giveitem "<row>"`.
-- Whichever route is chosen it must put the marker on the item - see THE ITEM HALF's coverage
-- gap above for what's already handled and what isn't. ModuleTraders/TraderShop is the nearest
-- precedent for a purchase route.
-- =======================================================================

return BB
