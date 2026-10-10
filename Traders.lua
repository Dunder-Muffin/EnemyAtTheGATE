-- =======================================================================
-- Traders (AUTHORITY) - spawn-on-demand trader NPCs reusing an EXISTING DT_NPC_Traders row's
-- inventory. A named registry mirroring ModuleStory/Events, so a dev keybind/chat can drop one.
--
-- Spawns the trader's real narrative class when known (else a generic human body), then calls
-- TraderComponent.SetTraderRow to pull/generate its stock. TR.SpawnCostume dresses a normal
-- trader in attached meshes so it keeps the native [F] trade window (furniture can't).
-- Full mechanism: see AnNotes/Modules/Traders.md.
--
-- THREADING: spawns go through NpcSpawner.SpawnClass with OffHook = true (the worker-thread hop,
-- every role) - the body's own spawn blocking-loads when its class is cold. The callback rides
-- the same clean pump, so applyTraderRow's customization loads are legal there too.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local TraderUtils = require("ModuleTraders.TraderUtils")
local TraderShop = require("ModuleTraders.TraderShop")
local ASSETS = require("AnteCore.AssetManager")
local NpcSpawner = require("AnteCore.NpcSpawner")
local ENUMS = require("AnteData.Enums")
local SCHEMA = require("AnteData.Schema")

local Log = Utils.Log
local LogBad = Utils.LogBad

local TR = {}

local TRADERS_TABLE  = "/Game/Blueprints/DataTables/NarrativeNPCs/DT_NPC_Traders.DT_NPC_Traders"
local ITEMS_TABLE    = "/Game/Blueprints/DataTables/NarrativeNPCs/DT_NPC_TraderItems.DT_NPC_TraderItems"
local GLOBAL_ITEMS   = "/Game/Blueprints/Items/ItemTable_Global.ItemTable_Global"
local CONV_TABLE     = "/Game/Blueprints/DataTables/DT_NPC_Conversations.DT_NPC_Conversations"

-- Native HumanCustomizationComponent slots -> their DT_Customization_<Table>, for asset warming.
-- Most match the slot name; FacialTrait uses Beards and Labcoat the plural Labcoats.
local CUSTOM_DT_BASE   = "/Game/Blueprints/DataTables/Customization/DT_Customization_"
local CUSTOM_SLOT_TABLE = {
    Head = "Head", HeadAccessory = "HeadAccessory", HairStyle = "HairStyle", HairColor = "HairColor",
    FacialTrait = "Beards", UpperBody = "UpperBody", ShirtColor = "ShirtColor", Tie = "Tie",
    IDCard = "IDCard", LowerBody = "LowerBody", Belt = "Belt", Shoes = "Shoes", Watch = "Watch",
    Labcoat = "Labcoats",
}
-- The mesh/material soft-object fields every DT_Customization_* row shares.
local CUST_SOFT_FIELDS = {
    SCHEMA.Customization.SkeletalMesh,
    SCHEMA.Customization.StaticMesh,
    SCHEMA.Customization.Material,
}

-- Pull a "/Game/..." path out of a soft-object property read - UE4SS gives an FSoftObjectPath-ish
-- value with an AssetPathName FName. Best-effort, nil if unreadable, never throws.
local function softObjPath(sp)
    if sp == nil then return nil end
    local path
    pcall(function()
        local ap = sp.AssetPathName
        if ap ~= nil then path = (type(ap) ~= "string" and ap.ToString) and ap:ToString() or tostring(ap) end
    end)
    if type(path) == "string" and path:sub(1, 6) == "/Game/" then return path end
    return nil
end

-- Read the SkeletalMesh/StaticMesh/Material soft-refs off each chosen customization ROW so the
-- caller can PRELOAD them - RefreshAllCustomization LoadAsset_Blocking's each, an S2 freeze if
-- cold. Derived from whatever slots a costume uses, so tweaking a value needs no warm-list edit.
-- Fully pcall'd; returns a flat list of "/Game/..." paths, or {} if the row API is unavailable
-- (the explicit CustomizationWarm list then covers it).
--   * RESIDENT tables only: this runs in the WorkQueue drain (TraderDirector's tick), where a
--     blocking LoadAsset is the CLAUDE.md law 4 deadlock. A cold table just skips its slot - the
--     caller warms every slot table in the same pass, so the next visit reads them.
local function customizationAssets(customization)
    local out = {}
    if type(customization) ~= "table" then return out end
    if not Utils.SoftRefsSafe() then return out end   -- a soft READ; the explicit warm list covers it
    for slot, rowName in pairs(customization) do
        local t = CUSTOM_SLOT_TABLE[slot]
        if t and rowName then
            local dtPath = CUSTOM_DT_BASE .. t .. ".DT_Customization_" .. t
            local dt = ASSETS.GetDataTable(dtPath)
            if dt then
                local row
                pcall(function() row = dt:FindRow(rowName) end)
                if row and pcall(function() return row:IsValid() end) and row:IsValid() then
                    for _, f in ipairs(CUST_SOFT_FIELDS) do
                        local p
                        pcall(function() p = softObjPath(row[f]) end)
                        if p then out[#out + 1] = p end
                    end
                end
            end
        end
    end
    return out
end

-- Generic friendly human body, used when a row has no dedicated class (or a DedicatedOnly
-- one is requested on a HOST - see below).
local NARR          = "/Game/Blueprints/Characters/NarrativeNPCs/"
local TRADER_CLASS  = NARR .. "NarrativeNPC_Human_TravelingTrader.NarrativeNPC_Human_TravelingTrader_C"

-- COSTUMES = a trader NPC dressed as something via attached meshes. Furniture/machines can't open
-- the [F] trade window (that interaction is NarrativeNPC-only), so a "vending machine" is a
-- regular trader wearing meshes. Renderer-LOCAL, so it shows on host/SP; a dedicated server's
-- clients go through TraderMirror.
-- Each costume: Row (which wares), Immobile?, HideBody?, and Attach[] entries of
-- { Mesh, Bone, Mat?, Location?, Scale? }. Bones: "head" for a hat, "root" (mesh origin, ~feet)
-- for body overlays. Tune Location in-game.
local ARMOR = "/Game/Models/Characters/Armor/"
local COSTUMES = {
    -- Vending machine: hide the body, wear the machine mesh, stand still. Wares = Blacksmith.
    Vendor = {
        Row = "Blacksmith", Immobile = true, HideBody = true,
        Attach = {
            -- Generic vending mesh + the KizzCola body material (what the KizzCola BP overrides
            -- slot 0 with). Only slot 0 - the body, not the buttons.
            { Mesh = ENUMS.Components.SM_VENDING_MACHINE, Bone = "root",
              Mat = ENUMS.Components.M_VENDING_MACHINE },
        },
    },
    -- Soda machine: the Vendor look, selling the money-gated custom sodas (TraderShop; drink
    -- effects in CustomItemEffects). Shares the "Fili" costume trader slot. We repoint Fili's
    -- inventory to the dedicated ante_soda row BEFORE spawn, so SetTraderRow caches it and the
    -- screen matches the purchase hook.
    -- Conv = false: no nameplate conversation (hover reads "DATA NOT FOUND"). Trading still works
    -- since it's TraderComponent-driven, not conversation-driven.
    SodaMachine = {
        -- KeepStock honors the per-visit AvailableStock instead of applyTraderRow's debug
        -- SetStock(-1), so a player buys at most N sodas per visit (restocked on respawn via
        -- GenerateNewInventory). Without it the money-gate still works but the count is ignored.
        Row = "Fili", ItemsRow = TraderShop.ITEMS_ROW, Conv = false, KeepStock = true,
        Immobile = true, HideBody = true, Setup = "SodaTrades",
        -- Arrival: the machine "plugs in" - coin-accept chirp, then the dispense rumble.
        SpawnSounds = {
            { "/Game/Audio/VendingMachine/vendingmachine_accept_Cue.vendingmachine_accept_Cue", 0 },
            { "/Game/Audio/VendingMachine/VendingMachine_Dispense1_Cue.VendingMachine_Dispense1_Cue", 1100 },
        },
        Attach = {
            -- Collision=1 (QueryOnly): the body is HIDDEN, so interact/camera traces need the
            -- MACHINE mesh hittable - otherwise only the invisible capsule answers, which is the
            -- flaky [F] prompt.
            { Mesh = ENUMS.Components.SM_VENDING_MACHINE, Bone = "root",
              Mat = ENUMS.Components.M_VENDING_MACHINE, Collision = 1 },
        },
    },
    -- Fisherman: a normal (mobile) trader in waders + a fishing hat, body visible. Wares are the
    -- empty "Fili" slot, whose item row we fill with scrap->fish trades at spawn.
    Fisherman = {
        -- Row = placeholder wares (Chef food), used if the DT edit is off. FishRow = "Fili",
        -- repointed to the dedicated ante_fish row we fill. ItemsRow lets TraderMirror repoint
        -- Fili the same way client-side. KeepStock keeps the per-trade limits.
        Row = "Chef", FishRow = "Fili", ItemsRow = "ante_fish", Setup = "FishTrades", KeepStock = true,
        SpeakOnSpawn = true,   -- arrival: speaks one of his beckon/intro lines
        Attach = {
            -- Hat: the WORN skeletal mesh, leader-posed - bones map by name, so no offset needed.
            -- (SM_FishingHat is the ground/pickup mesh, like the waders.)
            { Mesh = ARMOR.."SKMeshes/SK_FishingHat.SK_FishingHat", Bone = "root", Mat = ARMOR.."M_FishingHat.M_FishingHat",
              Skeletal = true, LeaderPose = true },
            -- Waders: the EQUIPPED skeletal mesh (SM_Armor_Waders is the folded pickup), leader-
            -- posed so it deforms with animation, like the Outcast's armor.
            { Mesh = ARMOR.."SKMeshes/SK_Waders.SK_Waders", Bone = "root", Mat = ARMOR.."M_Waders.M_Waders",
              Skeletal = true, LeaderPose = true },
            -- Fishing rod in the one-handed grip SOCKET r_weapon_default (the right-hand BONE is
            -- r_hand, not "RightHand" - why it floated). Use SK_FishingRod_T1, not _Skeleton
            -- (USkeleton metadata). Other grips if the angle's off: r_net, r_pitchfork,
            -- r_weapon_melee1.
            { Mesh = ENUMS.Components.SK_FISHING_ROD, Bone = "r_weapon_default",
              Skeletal = true },
        },
    },
    -- Hank: a customized male scientist via the native HumanCustomizationComponent, not attached
    -- meshes. Customization slots have per-slot OnReps, so the look (and BodyScale) reaches
    -- clients with no TraderMirror work. Row "Chef" is DedicatedOnly, so on a host it falls back
    -- to the generic TravelingTrader body (still a NarrativeNPC_Human_ParentBP, so it carries the
    -- same customization component).
    Hank = {
        -- Wares = the custom stapler shop (dedicated ante_hank row), sharing the "Fili" slot like
        -- the Fisherman; Row "Chef" is the placeholder if the DT edit is off. Conv drives the
        -- nameplate + title. Beckon-ifying happens in SetupHankTrades (all roles).
        Row = "Chef", Conv = "Reactors_Hank", HankRow = "Fili", ItemsRow = "ante_hank",
        Setup = "HankTrades", KeepStock = true,
        SpeakOnSpawn = true,
        BodyScale = { X = 1.3, Y = 1.15, Z = 0.85 },
        Customization = {
            HairStyle = "Hair_Hudson", HairColor = "HairColor_Red", 
            HeadAccessory = "Glasses_Lenses",
            UpperBody = "UpperBody_Shirt", ShirtColor = "ShirtColor_Cyan", 
            LowerBody = "Pants_Grey",
            Tie = "Tie_SolidGray",
        },
        -- CustomizationWarm is an OPTIONAL fallback: SpawnCostume auto-derives the mesh/material
        -- preload from the chosen slots, so a slot change no longer needs a warm-list edit to
        -- avoid the S2 freeze. Belt-and-suspenders in case the auto-read misses one - keep it
        -- roughly in sync, or drop it once the auto-read proves solid.
        CustomizationWarm = {
            ENUMS.Components.SK_HAIR_HUDSON,        -- HairStyle
            ENUMS.Components.SK_GLASSES_BUBBLES,    -- HeadAccessory
            ENUMS.Components.SK_TORSO_DRESSSHIRT_M, -- UpperBody
            ENUMS.Components.SK_LEGS_LABPANTS,      -- LowerBody mesh
            ENUMS.Components.M_SCIENTIST_PANTS_02,  -- LowerBody material
            ENUMS.Components.M_SCIENTIST_TIE_GRAY,  -- Tie material
        },
    },
}

-- Custom trade offers for the Fisherman. Index-paired: pay `cost` x`costCount` -> get `item`
-- x`count`, with `stock` available (default worldflag "None" = always shown). Installed via
-- TraderUtils into the dedicated `ante_fish` row, which the empty `Fili` trader slot points at.
-- We clone trader_corn rather than edit it in place, since that row backs the live corn
-- dispenser. `worldflag` is a native DT_WorldFlags row gating the trade until it's set, same as
-- native traders use; the late fish gates (story milestones) are commented per row below.
local FISH_TRADES = {
    { cost = "scrap_bio", costCount = 6, item = "fish_antefish", count = 1, stock = 15 },
    { cost = "scrap_bio", costCount = 5, item = "fish_portal",   count = 1, stock = 10 },
    { cost = "scrap_bio", costCount = 5, item = "fish_fog",      count = 1, stock = 10 },
    { cost = "scrap_bio", costCount = 5, item = "fish_moon",     count = 1, stock = 10 },
    { cost = "scrap_bio", costCount = 5, item = "fish_rad",      count = 1, stock = 10 },
    { cost = "scrap_bio", costCount = 6, item = "fish_is98",     count = 1, stock = 10, worldflag = "Labs_Helmholtz_Opened" },
    { cost = "scrap_bio", costCount = 5, item = "fish_eel",      count = 1, stock = 10, worldflag = "Salem_Complete" },        -- story 45
    { cost = "scrap_bio", costCount = 5, item = "fish_reaper",   count = 1, stock = 10, worldflag = "Salem_Complete" },        -- story 45
    { cost = "scrap_bio", costCount = 5, item = "fish_darkwater", count = 1, stock = 10, worldflag = "Dams_ReachedCentral" },  -- story 51
    { cost = "scrap_bio", costCount = 5, item = "fish_ice",      count = 1, stock = 10, worldflag = "VWinter_Complete" },  
    { cost = "scrap_bio", costCount = 6, item = "fish_silk",     count = 1, stock = 10, worldflag = "Plant_FungusDestroyed" }, -- story 63
    { cost = "scrap_bio", costCount = 6, item = "fish_umbra",    count = 1, stock = 10, worldflag = "Reactors_SG_Entered" },   -- story 78
    { cost = "woodplank", costCount = 5, item = "screws",        count = 3, stock = 5 },
}
local FISH_ITEM_ROW = "ante_fish"          -- our DEDICATED item row (cloned from the donor; grown + filled)
local FISH_DONOR_ROW = "trader_corn"       -- live corn-dispenser row we CLONE from (never edited)
local FISH_TRADER   = "Fili"               -- empty DT_NPC_Traders slot we point at it (= Fisherman FishRow)
local FISH_CONV     = "Canaan_Fisherman"   -- existing conversation row whose NPCName is "Fisherman"

-- Now uses the proven per-index TraderUtils technique; the old whole-array assignment
-- native-crashed. Flip off if a future build regresses the DataTable API.
local ENABLE_FISH_TRADES = true

-- Hank's shop: he only wants STAPLERS (cost = "stapler") and trades a mix of items, story-gated by
-- worldflag. Same index-paired shape as FISH_TRADES. Filled into the dedicated `ante_hank` row.
-- Keep the row count near the no-scroll trade grid's practical ceiling.
local HANK_TRADES = {
    { cost = "stapler", costCount = 3, item = "soilbag",           count = 2, stock = 3 },
    { cost = "stapler", costCount = 1, item = "pressuregauge",     count = 3, stock = 2 },
    { cost = "stapler", costCount = 4, item = "coating_thermal",   count = 1, stock = 1 },
    { cost = "stapler", costCount = 3, item = "soup_pepper",       count = 1, stock = 1 },
    { cost = "stapler", costCount = 1, item = "chains",            count = 2, stock = 3, worldflag = "TrainCompletedOnce" },
    { cost = "stapler", costCount = 2, item = "lens",              count = 2, stock = 2, worldflag = "TrainCompletedOnce" },
    { cost = "stapler", costCount = 1, item = "gunpowder",         count = 5, stock = 2, worldflag = "LABS_Met_Thule" },
    { cost = "stapler", costCount = 1, item = "thermite_molotov",  count = 3, stock = 2, worldflag = "LABS_AnteverseBFixed" },
    { cost = "stapler", costCount = 2, item = "flask_holy",        count = 1, stock = 3, worldflag = "Salem_Complete" },
    { cost = "stapler", costCount = 3, item = "lodestone_fragment",count = 3, stock = 2, worldflag = "Salem_Complete" },
    { cost = "stapler", costCount = 2, item = "petn",              count = 2, stock = 4, worldflag = "Reactors_S1Labs_Complete" },
    { cost = "stapler", costCount = 2, item = "238",               count = 1, stock = 5, worldflag = "Reactors_S1Labs_Complete" },
    { cost = "stapler", costCount = 4, item = "clustergrenade",    count = 1, stock = 2, worldflag = "Reactors_S4RadWaste_Complete" },
    { cost = "stapler", costCount = 5, item = "cpu_red",           count = 1, stock = 2, worldflag = "Reactors_S3Overgrowth_Complete" },
    { cost = "stapler", costCount = 6, item = "thermocell",        count = 1, stock = 5, worldflag = "Residence_IceWallRemoved" },
}
local HANK_ITEM_ROW  = "ante_hank"          -- dedicated row (cloned from the donor; grown + filled)
local HANK_DONOR_ROW = "trader_corn"        -- clone seed (has >=1 buyable + tradeable to grow from)
local HANK_TRADER    = "Fili"               -- shared empty DT_NPC_Traders slot we point at it
local HANK_CONV      = "Reactors_Hank"       -- conversation row whose NPCName is "Hank"

-- The conversation each costume points the shared "Fili" slot at - its trade-window title. The
-- server re-points it at every spawn (SpawnCostume); a client has to as well (TraderMirror), or
-- after one of each has been seen every later visit carries the last-installed name.
local COSTUME_CONV = { Fisherman = FISH_CONV, Hank = HANK_CONV }

-- Per DT_NPC_Traders row: the actor Class to spawn as the body (nil -> generic), the Conv row for
-- the world nameplate, and DedicatedOnly.
-- The human trader classes blocking-load a character customization in BeginPlay, which freezes
-- a HOST (in-hook spawn) - hence DedicatedOnly, so the appearance instead loads on clients'
-- threads. A host falls back to the generic body (correct name/stock, generic look). Larva and
-- the generic body carry no customization rows, so that load is absent - but their spawn still
-- wedged in-drain when the class was cold, hence OffHook in TR.Spawn. Blacksmith/Warren/Fili
-- have no NPC of their own (object/placed), so they use the generic body too.
local TRADER_ROWS = {
    Marion     = { Class = NARR.."NarrativeNPC_MarionTrader.NarrativeNPC_MarionTrader_C",                              Conv = "Trader_Marion",   DedicatedOnly = true },
    Chef       = { Class = NARR.."NarrativeNPC_Human_ChefTrader.NarrativeNPC_Human_ChefTrader_C",                      Conv = "Chef_Trader",     DedicatedOnly = true },
    Grayson    = { Class = NARR.."NarrativeNPC_Human_GraysonTrader.NarrativeNPC_Human_GraysonTrader_C",                Conv = "Grayson_Trader",  DedicatedOnly = true },
    Jimmy      = { Class = NARR.."NarrativeNPC_Human_TravelingTrader_Jimmy.NarrativeNPC_Human_TravelingTrader_Jimmy_C", Conv = "Res_Jimmy_Trader", DedicatedOnly = true },
    Thule      = { Class = NARR.."NarrativeNPC_Human_TravelingTrader_Thule.NarrativeNPC_Human_TravelingTrader_Thule_C", Conv = "Res_Thule_Trader", DedicatedOnly = true },
    Larva      = { Class = NARR.."NarrativeNPC_Larva.NarrativeNPC_Larva_C",                                            Conv = nil, NeedsTagClear = true },
    Blacksmith = { Class = nil, Conv = nil },
    Warren     = { Class = nil, Conv = nil },
    Fili       = { Class = nil, Conv = "Canaan_Fisherman" },   -- Fisherman costume host; "Fisherman" nameplate
}

-- ARRIVAL BELL (deployable "arrivalbell"): its BeginPlay binds TraderSpawned to the AI Director's
-- OnTraderSpawn delegate, which only the game's native narrative spawner fires. Our traders spawn
-- directly, so no bell hears them - we call each nearby bell's own TraderSpawned event instead,
-- which keeps every rule native (construction-mode gate, Range=5000 cutoff, ring-type roll, and
-- the client-replicating Broadcast_BellDing multicast). Drain-safe: ring sounds are hard refs on
-- the bell class, so nothing blocking-loads.
local BELL_SCAN_RANGE = 6000    -- slightly > the bell's own Range; its native check does the exact cut
local BELL_RING_DELAY = 300     -- ms after the trader lands, so the ding reads as "it just arrived"

local function ringArrivalBells(npc)
    if not Utils.IsAuthority() then return end
    if Utils.IsActorInvalid(npc) then return end
    local ok, loc = pcall(function() return npc:K2_GetActorLocation() end)
    if not ok or not loc then return end

    -- Class resolved by PATH with NO load: no bell deployed -> class never loaded -> {} -> no-op.
    local bells = AVU.GetNearbyActorsOfClass(loc, BELL_SCAN_RANGE, ENUMS.DeployedObjs.ARRIVAL_BELL) or {}
    local rung = 0
    for i = 1, #bells do
        -- Overlap out-param elements can arrive as RemoteUnrealParam (SpawnerHooks note); unwrap
        -- when they do, pass through when they don't.
        local bell = bells[i]
        local okg, inner = pcall(function() return bells[i]:get() end)
        if okg and inner then bell = inner end
        if IsValid(bell) then
            -- AtLure = false: our traders never arrive at a Narrative Lure, and the bell ignores
            -- both the NPC and the flag anyway (only SpawnLocation is read).
            if pcall(function() bell:TraderSpawned(npc, loc, false) end) then rung = rung + 1 end
        end
    end
    if rung > 0 then Log("Traders - rang " .. rung .. " arrival bell(s)") end
end

-- GROUNDING (opts.FloorZ) - see TR.Spawn's lift comment / AnNotes/Modules/Traders.md for why this exists.
-- Sets the actor's Z from its OWN scaled capsule so the feet sit exactly on `floorZ`, instead of
-- a constant that's wrong for a body of a different height. bSweep = false since we're correcting
-- a penetration and a swept move would be blocked by the thing we're climbing out of. Not fatal
-- if it fails - SPAWN_LIFT alone already beats the old flush +15.
local SPAWN_LIFT   = 100        -- ~a human capsule half-height: spawn standing, never embedded
local GROUND_MARGIN = 2         -- hair of clearance so the capsule rests on the floor, not in it

local function groundTrader(npc, floorZ)
    if Utils.IsActorInvalid(npc) or not floorZ then return end
    pcall(function()
        local cap = npc.CapsuleComponent
        if IsNotValid(cap) then return end
        local half = cap:GetScaledCapsuleHalfHeight()
        if not half or half <= 0 then return end

        local at = npc:K2_GetActorLocation()
        local rot = npc:K2_GetActorRotation()
        npc:K2_SetActorLocationAndRotation(
            FVector(at.X, at.Y, floorZ + half + GROUND_MARGIN), rot, false, {}, true)
    end)
end

-- WALK-IN (opts.WalkTo): a trader that had to arrive further out (TraderDirector's fallback) walks
-- itself to the base instead of standing where it landed - otherwise it's "spawned and never
-- found". We drive it with AAIController:MoveToLocation, re-issued on a poll, while parking the
-- native idle-wander via TimeOfLastIdlePatrol so it doesn't fight us. Immobile costumes never get
-- a WalkTo. WALK_ARRIVED must stay above WALK_ACCEPT (the path follower's own acceptance radius)
-- or "arrived" never reads true. Full mechanism: AnNotes/Modules/Traders.md.
local WALK_ACCEPT     = 120     -- MoveToLocation's acceptance radius
local WALK_ARRIVED    = 200     -- our "close enough, stop driving" test
local WALK_POLL_MS    = 3000    -- re-issue cadence
local WALK_POLL_TRIES = 24      -- ~72s of walking, then give up and let it wander where it is
local WALK_STAMP      = 1e12    -- game-seconds; parks BTD_CanNarrativeNPCPatrol while we drive

-- Park / restore the narrative idle-patrol branch on this trader's controller.
local function setNarrativePatrol(npc, enabled)
    pcall(function()
        local c = npc:GetController()
        if IsNotValid(c) then return end
        if c.TimeOfLastIdlePatrol == nil then return end   -- not AI_Controller_NPC_Narrative
        if enabled then
            local ksl = require("UEHelpers").GetKismetSystemLibrary()
            c.TimeOfLastIdlePatrol = ksl and ksl:GetGameTimeInSeconds(npc) or 0
        else
            c.TimeOfLastIdlePatrol = WALK_STAMP
        end
    end)
end

local function walkToward(npc, dest, tries)
    if Utils.IsActorInvalid(npc) or not dest then return end

    local ok, here = pcall(function() return npc:K2_GetActorLocation() end)
    if ok and here and Utils.WithinDistanceXY(here, dest, WALK_ARRIVED) then
        setNarrativePatrol(npc, true)                      -- arrived: wander normally, from here
        Log("Traders - trader reached the base")
        return
    end

    tries = (tries or 0) + 1
    if tries > WALK_POLL_TRIES then
        setNarrativePatrol(npc, true)
        LogBad("Traders - trader never reached the base; leaving it where it is")
        return
    end

    setNarrativePatrol(npc, false)
    pcall(function()
        local c = npc:GetController()
        if IsNotValid(c) then return end
        -- bStopOnOverlap=false, bUsePathfinding=true, bProjectDestinationToNavigation=true,
        -- bCanStrafe=false, no filter, bAllowPartialPath=true (walk as far as it can rather than
        -- refuse the whole trip when the base is behind a door).
        c:MoveToLocation(dest, WALK_ACCEPT, false, true, true, false, nil, true)
    end)
    Utils.QueueWork(function() walkToward(npc, dest, tries) end, WALK_POLL_MS)
end

-- helpers (defined below)
local applyTraderRow, applySkin


-- =======================================================================
-- Public
-- =======================================================================

-- True if a keybind/chat name is a trader handle (so summonVariant can branch off it).
function TR.IsTrader(name)
    return type(name) == "string" and name:sub(1, 7) == "Trader_"
end

-- Does this costume stand still? COSTUMES is the single source of truth for it, so the placement
-- side (TraderDirector) asks rather than keeping its own list: an Immobile costume can never walk
-- in from a far spawn, so it has to be PLACED well.
function TR.CostumeIsImmobile(costumeKey)
    local skin = COSTUMES[costumeKey]
    return (skin and skin.Immobile) and true or false
end

-- Resolve a loose chat spelling to a real COSTUMES key: exact, then case-insensitive, then prefix
-- ("soda" -> "SodaMachine"). nil when nothing matches. Dev-facing (the /au-tradervisit argument),
-- so an ambiguous prefix picking arbitrarily - `pairs` order is undefined - is acceptable.
function TR.ResolveCostume(name)
    if type(name) ~= "string" or name == "" then return nil end
    if COSTUMES[name] then return name end

    local want = name:lower()
    for key in pairs(COSTUMES) do
        if key:lower() == want then return key end
    end
    for key in pairs(COSTUMES) do
        if key:lower():sub(1, #want) == want then return key end
    end
    return nil
end

-- Strip the "Trader_" prefix to the bare DT_NPC_Traders row name (if present).
function TR.RowName(name)
    return (tostring(name):gsub("^Trader_", ""))
end

-- Spawn a trader at `loc` whose stock = the given existing DT_NPC_Traders row. AUTHORITY.
-- opts (optional): Immobile = stand still, Skin = hide the body + wear the vending-machine mesh,
-- WalkTo = an FVector to walk to after arriving (ignored when Immobile - see walkToward),
-- FaceTo = an FVector to face on arrival,
-- FloorZ = "loc.Z is FLOOR level, not a capsule centre" (see the lift comment below).
function TR.Spawn(rowName, loc, opts)
    if not Utils.IsAuthority() then return false end
    if not rowName or not loc then return false end

    local info = TRADER_ROWS[rowName]
    if not info then
        LogBad("Traders - unknown row '" .. tostring(rowName) .. "'")
        return false
    end
    -- The row's real class, except a DedicatedOnly (human-customization) one on a HOST, where its
    -- customization load would freeze the in-hook spawn - use the generic body there.
    local class = info.Class or TRADER_CLASS
    if info.DedicatedOnly and STATE.Role ~= "DEDICATED" then
        class = TRADER_CLASS
        Log("Traders - '" .. rowName .. "' uses the generic body on a host (real class is dedicated-only)")
    end

    -- LIFT the spawn point: an ACharacter's origin is its capsule centre, so a floor point spawns
    -- the body buried to the waist and can leave it stuck if depenetration fails. opts.FloorZ
    -- means "loc.Z is floor level" - spawn a capsule half-height up so it starts standing, then
    -- groundTrader() sets the exact Z once the actor exists. No FloorZ (keybind spawn, whose loc
    -- is already a player's capsule centre) just uses the old flush +15. Full rationale:
    -- AnNotes/Modules/Traders.md.
    local floorZ = opts and opts.FloorZ
    loc = FVector(loc.X, loc.Y, loc.Z + (floorZ and SPAWN_LIFT or 15))
    local faceTo = opts and opts.FaceTo
    local faceRot = faceTo and Utils.RotatorToTarget(FVector(loc.X, loc.Y, 0), FVector(faceTo.X, faceTo.Y, 0))

    -- A costume driving its own customization (Hank) must skip the body's default one: the
    -- generic human body blocking-loads its default outfit in BeginPlay (inside the host's spawn
    -- hook), an S2 freeze if cold. Setting IgnoreCustomization here makes BeginPlay skip it;
    -- AVU.SetHumanCustomization re-enables it with our preloaded look in the callback.
    local preFinish
    if opts and opts.Customization then
        preFinish = function(npc)
            local comp = npc.HumanCustomizationComponent
            if IsValid(comp) then pcall(function() comp.IgnoreCustomization = true end) end
        end
    end

    ASSETS.LoadAsync({ TRADERS_TABLE, CONV_TABLE }, function()
        Log("Traders - spawning '" .. rowName .. "' trader")
        NpcSpawner.SpawnClass(class, loc, {
            _traceName = "Trader_" .. rowName,
            -- A trader class is cold every visit (one body, nothing else references it), and
            -- FinishSpawningActor loads past what the class load brought in - an in-drain freeze
            -- on a host. Same family as NpcSpawner's OFFHOOK_ROWS.
            OffHook = true,
            PreFinish = preFinish,
            Rotation = faceRot,
            callback = function(npc)
                -- Track for the despawn bind. In STATE so a world unload drops the refs and they
                -- can't leak old-world wrappers (as STATE.PlacedSpawnActors does).
                if Utils.IsActorValid(npc) then
                    STATE.SpawnedTraders = STATE.SpawnedTraders or {}
                    STATE.SpawnedTraders[#STATE.SpawnedTraders + 1] = npc
                end
                applyTraderRow(npc, rowName, opts)
                -- AFTER applyTraderRow, so a costume's BodyScale is already on the capsule and
                -- GetScaledCapsuleHalfHeight reads the real one (Hank is scaled 0.93 in Z).
                if floorZ then groundTrader(npc, floorZ) end
            end,
        })
    end)
    return true
end

-- [AUTHORITY] Edit a spawned trader's live stock QUANTITIES (-1 = unlimited). Mutates the
-- replicated TradeStock in place, marks it dirty, and refreshes any open screen.
function TR.SetStock(npc, value)
    if not Utils.IsAuthority() then return false end
    if Utils.IsActorInvalid(npc) then return false end
    local comp = npc.TraderComponent
    if IsNotValid(comp) then return false end

    -- Build a same-length array for the native setter. Server_SetTradeStockData assigns TradeStock,
    -- marks it dirty, refreshes the screen, AND writes back to the AI Director's per-row stock
    -- cache - so a later trader on the same row inherits this value too.
    local ok, err = pcall(function()
        local n = #comp.TradeStock                 -- length = the row's BuyableItems count
        if not n or n <= 0 then return end
        local arr = {}
        for i = 1, n do arr[i] = value end
        comp:Server_SetTradeStockData(arr)
    end)
    if not ok then LogBad("Traders - SetStock failed: " .. tostring(err)) end
    return ok
end

-- Destroy every trader WE spawned (leaves the game's real traders alone). AUTHORITY.
function TR.DespawnAll()
    if not Utils.IsAuthority() then return 0 end
    local list = STATE.SpawnedTraders or {}
    local n = 0
    for _, npc in ipairs(list) do
        if Utils.IsActorValid(npc) then
            pcall(function() npc:K2_DestroyActor() end)
            n = n + 1
        end
    end
    STATE.SpawnedTraders = {}
    Log("Traders - despawned " .. n .. " spawned trader(s)")
    return n
end

-- Install a real-item-cost custom shop (Fisherman, Hank): clone a dedicated items row from a
-- donor (leaving the donor's live row alone), fill it with `cfg.trades`, point the shared trader
-- slot at it, name it via its conv row, and beckon-ify the dialog. Native trade handles payment -
-- no money/purchase hook (that's the soda machine's TraderShop.SetupTrades).
-- cfg = { name, donor, itemRow, trader, conv, trades, hideExtras? }. Idempotent per itemRow;
-- false on an old UE4SS without the DataTable row API (falls back to the placeholder Row).
-- Runs on EVERY role, same reason as TraderShop.SetupTrades: authority pre-spawn, clients via
-- TraderMirror on first sighting.
local setupDone = {}   -- itemRow -> true once installed
local function setupCustomTrades(cfg)
    if setupDone[cfg.itemRow] then return true end
    if not TraderUtils.Available() then
        LogBad("Traders - DataTable row API unavailable; " .. cfg.name .. " trades skipped")
        return false
    end
    if not TraderUtils.CloneItemRow(cfg.donor, cfg.itemRow) then
        LogBad("Traders - could not clone " .. cfg.name .. " row; trades skipped")
        return false
    end
    if not TraderUtils.SetTrades(cfg.itemRow, cfg.trades, cfg.hideExtras and { hideExtras = true } or nil) then return false end
    if not TraderUtils.SetTraderInventory(cfg.trader, cfg.itemRow) then return false end
    TraderUtils.SetTraderConversation(cfg.trader, cfg.conv)
    TraderUtils.SpeakBeckonOnInteract(cfg.conv)

    setupDone[cfg.itemRow] = true
    Log("Traders - " .. cfg.name .. " trades installed (" .. cfg.trader .. " -> " .. cfg.itemRow .. ")")
    return true
end

function TR.SetupFishTrades()
    return setupCustomTrades({ name = "fish", donor = FISH_DONOR_ROW, itemRow = FISH_ITEM_ROW,
                               trader = FISH_TRADER, conv = FISH_CONV, trades = FISH_TRADES })
end

function TR.SetupHankTrades()
    return setupCustomTrades({ name = "Hank", donor = HANK_DONOR_ROW, itemRow = HANK_ITEM_ROW,
                               trader = HANK_TRADER, conv = HANK_CONV, trades = HANK_TRADES, hideExtras = true })
end

-- Spawn a COSTUMED trader (a normal trader wearing a skin) by costume key ("Vendor",
-- "Fisherman"). Warms the skin meshes (+ data tables for a Setup) first, runs the costume's
-- one-time Setup, then spawns. AUTHORITY.
--   opts (optional): WalkTo = FVector to walk to after arriving (an Immobile costume ignores it),
--   FaceTo = FVector to face on arrival, FloorZ = loc.Z is FLOOR level. All pass through to TR.Spawn.
function TR.SpawnCostume(costumeKey, loc, opts)
    if not Utils.IsAuthority() then return false end
    if not loc then return false end
    local skin = COSTUMES[costumeKey]
    if not skin then LogBad("Traders - unknown costume '" .. tostring(costumeKey) .. "'"); return false end

    local doFish = (skin.Setup == "FishTrades") and ENABLE_FISH_TRADES
    local doSoda = (skin.Setup == "SodaTrades")
    local doHank = (skin.Setup == "HankTrades")
    if doSoda and not SETTINGS.MODULES.TRADERS.CustomItems then
        LogBad("Traders - '" .. costumeKey .. "' needs MODULES.TRADERS.CustomItems")
        return false
    end

    local warm = {}
    for _, a in ipairs(skin.Attach or {}) do   -- a customization-only costume (Hank) has no Attach
        warm[#warm + 1] = a.Mesh
        if a.Mat then warm[#warm + 1] = a.Mat end
    end
    for _, s in ipairs(skin.SpawnSounds or {}) do warm[#warm + 1] = s[1] end
    if doFish or doSoda or doHank then
        warm[#warm + 1] = ITEMS_TABLE; warm[#warm + 1] = TRADERS_TABLE; warm[#warm + 1] = GLOBAL_ITEMS
        warm[#warm + 1] = CONV_TABLE   -- SetTraderConversation below resolves it (blocking if cold)
    end
    -- Native customization (Hank): warm the chosen slots' DT tables plus every mesh/material
    -- RefreshAllCustomization touches, so it's all cache hits - a cold load in the spawn callback
    -- is the S2 freeze. customizationAssets() reads the soft-refs off the live rows and survives
    -- slot tweaks; CustomizationWarm is the explicit fallback.
    if skin.Customization then
        for _, p in ipairs(skin.CustomizationWarm or {}) do warm[#warm + 1] = p end
        for slot in pairs(skin.Customization) do
            local t = CUSTOM_SLOT_TABLE[slot]
            if t then warm[#warm + 1] = CUSTOM_DT_BASE .. t .. ".DT_Customization_" .. t end
        end
        for _, p in ipairs(customizationAssets(skin.Customization)) do warm[#warm + 1] = p end
    end

    ASSETS.LoadAsync(warm, function()
        -- ONE custom trader at a time: costumes SHARE the "Fili" row (inventory + conversation
        -- repointed per costume below), so a lingering previous costume would show the new one's
        -- wares. Despawning everything we spawned keeps it unambiguous.
        TR.DespawnAll()

        local row = skin.Row
        if doFish and TR.SetupFishTrades() then
            row = skin.FishRow or row
            -- Re-point the shared slot at the FISH pool + name; a prior SodaMachine left it on the
            -- soda row/conv, and SetupFishTrades only does this on its FIRST run.
            TraderUtils.SetTraderInventory(row, FISH_ITEM_ROW)
            TraderUtils.SetTraderConversation(row, FISH_CONV)
        end
        if doSoda and TraderShop.SetupTrades() then
            -- Point the shared slot at the SODA pool + machine name BEFORE spawning (pre-spawn
            -- repoint = SetTraderRow caches it = screen == purchase; post-spawn repoints split them).
            TraderUtils.SetTraderInventory(row, skin.ItemsRow)
            if skin.Conv then TraderUtils.SetTraderConversation(row, skin.Conv) end
        end
        if doHank and TR.SetupHankTrades() then
            row = skin.HankRow or row   -- "Fili"
            -- Re-point the shared slot at Hank's pool + name (a prior costume may have moved Fili).
            TraderUtils.SetTraderInventory(row, HANK_ITEM_ROW)
            TraderUtils.SetTraderConversation(row, HANK_CONV)
        end
        TR.Spawn(row, loc, {
            Immobile = skin.Immobile, Skin = costumeKey, KeepStock = skin.KeepStock, Conv = skin.Conv,
            SpeakOnSpawn = skin.SpeakOnSpawn, SpawnSounds = skin.SpawnSounds,
            Customization = skin.Customization, BodyScale = skin.BodyScale, BeckonConv = skin.BeckonConv,
            WalkTo = opts and opts.WalkTo, FaceTo = opts and opts.FaceTo, FloorZ = opts and opts.FloorZ,
        })
    end)
    return true
end

-- Keybind/chat entry: "Trader_Marion" -> NPC trader; "Trader_Vendor"/"Trader_Fisherman" ->
-- costumed trader (COSTUMES). AUTHORITY.
function TR.Run(name, loc)
    local row = TR.RowName(name)
    if COSTUMES[row] then return TR.SpawnCostume(row, loc) end
    return TR.Spawn(row, loc)
end


-- =======================================================================
-- Helpers
-- =======================================================================

-- Point a freshly-spawned trader's component at an existing trader row; the native SetTraderRow
-- pulls/generates stock and marks it dirty. Also clears the trade-gate tag (so Larva is tradeable
-- without the Larva Suit) and sets the nameplate conversation, without which the world name reads
-- "DATA NOT FOUND".
function applyTraderRow(npc, rowName, opts)
    if Utils.IsActorInvalid(npc) then return end
    opts = opts or {}

    -- Every trader NarrativeNPC subclass names the component "TraderComponent"; the class lookup
    -- is a fallback in case a body ever doesn't.
    local comp = npc.TraderComponent
    if IsNotValid(comp) then
        local compClass = ASSETS.GetIfValid("/Game/Blueprints/Characters/Components/TraderComponent.TraderComponent_C")
        if IsValid(compClass) then
            pcall(function() comp = npc:GetComponentByClass(compClass) end)
        end
    end
    if IsNotValid(comp) then
        LogBad("Traders - spawned actor has no TraderComponent")
        return
    end

    local dt = ASSETS.GetIfValid(TRADERS_TABLE)
    if IsNotValid(dt) then
        LogBad("Traders - DT_NPC_Traders not resolvable")
        return
    end

    -- SetTraderRow takes its row handle by value, so a plain table in the build's handle shape works.
    local ok, err = pcall(function()
        comp:SetTraderRow(SCHEMA.MakeHandle(rowName, { DataTable = dt }))
    end)
    if not ok then
        LogBad("Traders - SetTraderRow failed: " .. tostring(err))
        return
    end

    -- Force a fresh inventory from the data table. SetTraderRow prefers the AI Director's
    -- per-row cache, so a costume swap on the shared row inherited the previous costume's pool -
    -- screen and purchases disagreed. GenerateNewInventory re-reads the DT live and writes back to
    -- the cache. Server-only, no asset loads.
    pcall(function() comp:GenerateNewInventory() end)

    -- Only the Larva ships tag requirements (Character.LarvaSuit) - clear them there and skip
    -- the write for every other trader. FGameplayTagContainer writes go through UE4SS's broken
    -- struct converter; a non-empty copy hard-crashed with an FName::ToString AV, and even an
    -- "empty" write risks silent corruption. To mute a trader, point its Conv at a lineless
    -- conversation row instead - never touch these tags.
    local info = TRADER_ROWS[rowName]
    if info and info.NeedsTagClear then
        pcall(function() npc.TagsRequiredToTradeWith = {} end)
        pcall(function() npc.TagsRequiredToSpeakWith = {} end)
    end

    -- Disable head-look (it drives the head/neck toward the player's backpack socket; on the
    -- Larva that stretched its neck a metre up). Cosmetic-only, safe on all bodies.
    pcall(function() npc.NoHeadLook = true end)

    -- Quiet the narrative chatter so the trade [F] stays available. Beckoning speaks on a timer
    -- that gates interactivity (IsSpeakingDialog), and nearby copies can suppress each other -
    -- both matched the flaky [F]. Set before any player enters the beckon zone, so it never starts.
    pcall(function() npc.NoBeckonZone = true end)
    pcall(function() npc.NoDialogZone = true end)
    pcall(function() npc.CheckIfNearbyNPCsSpeaking = false end)
    pcall(function() npc.AutoSpeakNextDialog = false end)
    -- The No*Zone bools alone do NOT disable the zones - their collision was turned on at
    -- BeginPlay. CheckIfConversationZonesActive() re-reads the flags and turns the collisions off,
    -- so entering never triggers a stray dialog line (e.g. the soda machine speaking Thule's).
    pcall(function() npc:CheckIfConversationZonesActive() end)

    -- Nameplate: set the NPC's own conversation row - the spawner normally does this, and we
    -- skipped it by spawning directly, so without it the world name reads "DATA NOT FOUND".
    -- opts.Conv is the per-costume override and wins over the row default; `false` means
    -- EXPLICITLY no nameplate (leave it DATA NOT FOUND), nil means "use the row default".
    local convName
    if opts.Conv == false then
        convName = nil
    else
        convName = opts.Conv or (info and info.Conv)
    end
    if convName then
        local convDt = ASSETS.GetIfValid(CONV_TABLE)
        if IsValid(convDt) then
            -- In place: a whole-struct write carrying a field the build's handle lacks (DataTable on
            -- the native layout) is an AV inside UE4SS's struct converter, not a Lua error.
            pcall(function() SCHEMA.SetRow(npc.NarrativeNPC_ConversationRow, convName, convDt) end)
            -- Replicated (push model), so dirty it or clients keep the default - and flush
            -- dormancy first, the way the native setter does, since a narrative NPC may be dormant.
            pcall(function() npc:FlushNetDormancy() end)
            Utils.MarkReplicatedDirty(npc, "NarrativeNPC_ConversationRow")
        end
    end

    -- Debug convenience: unlimited stock so you can re-buy while testing. Skipped for KeepStock
    -- traders like the Fisherman, whose per-trade limits we honor.
    if not opts.KeepStock then TR.SetStock(npc, -1) end

    -- Immobile: narrative NPCs wander by default; stop it so the "machine" stays put.
    if opts.Immobile then
        pcall(function() npc.CanWander = false end)
        pcall(function()
            local move = npc.CharacterMovement
            if IsValid(move) then move:StopMovementImmediately() end
        end)
    end

    -- Arrival: face opts.FaceTo, then walk to opts.WalkTo. Never walks an Immobile costume - a
    -- vending machine that walks is worse than one you have to find. Either can fail on its own.
    --   * Faced now and again after the delay: once the controller possesses the pawn, its control
    --     rotation overrides the actor's yaw.
    --   * The delay lets the controller possess the pawn first (MoveToLocation needs a controller).
    if opts.FaceTo then AVU.FaceSpot(npc, opts.FaceTo) end
    if opts.FaceTo or (opts.WalkTo and not opts.Immobile) then
        Utils.QueueWork(function()
            if not Utils.IsActorValid(npc) then return end
            if opts.FaceTo then AVU.FaceSpot(npc, opts.FaceTo) end
            if opts.WalkTo and not opts.Immobile then walkToward(npc, opts.WalkTo) end
        end, 1500)
    end

    -- Skin: dress the body via the named costume (attach meshes, optionally hide the body).
    if opts.Skin then applySkin(npc, COSTUMES[opts.Skin]) end

    -- Native customization (Hank): drive the HumanCustomizationComponent (shirt/pants/tie/hair).
    -- Replicates per-slot, so clients get the look with no mirror, and the meshes were warmed in
    -- SpawnCostume, so RefreshAllCustomization here is a cache hit.
    if opts.Customization then AVU.SetHumanCustomization(npc, opts.Customization) end

    -- Body scale. Actor scale covers the whole body incl. the customization meshes and replicates;
    -- apply AFTER customization so the new meshes inherit it.
    if opts.BodyScale then AVU.SetBodyScale(npc, opts.BodyScale) end

    -- Rewrite this trader's conv row so its interact/return lines are its plain BECKON lines (no
    -- posed montage, no story side-effects). Edits the shared conv row in place on authority -
    -- fine for the keybind test; clone the row to isolate a real same-name NPC.
    if opts.BeckonConv then pcall(function() TraderUtils.SpeakBeckonOnInteract(opts.BeckonConv) end) end

    -- Arrival FX per costume: a spoken line and/or positional sounds a beat after spawn, once the
    -- NPC is initialised. Runs for scheduled (TraderDirector) AND keybind spawns.
    if opts.SpeakOnSpawn then
        Utils.QueueWork(function()
            if Utils.IsActorInvalid(npc) then return end
            -- Speaks one of the interact lines, which for the Fisherman are his beckon/intro lines
            -- (SpeakBeckonOnInteract), picked at random by the native speak.
            pcall(function() npc:TrySpeakAppropriateDialog(true) end)
        end, 1200)
    end
    for _, s in ipairs(opts.SpawnSounds or {}) do
        local path, delay = s[1], s[2] or 0
        Utils.QueueWork(function()
            if Utils.IsActorInvalid(npc) then return end
            pcall(function()
                local sound = ASSETS.GetIfValid(path)
                local gs = require("UEHelpers").GetGameplayStatics()
                if IsValid(sound) and gs then
                    gs:PlaySoundAtLocation(npc, sound, npc:K2_GetActorLocation(), FRotator(0, 0, 0),
                        1.0, 1.0, 0.0, nil, nil, nil, nil)
                end
            end)
        end, 400 + delay)
    end

    -- Any deployed Arrival Bell in earshot dings, exactly as it would for a narrative trader.
    Utils.QueueWork(function() ringArrivalBells(npc) end, BELL_RING_DELAY)

    Log("Traders - '" .. rowName .. "' inventory applied (stock set unlimited)")
end

-- Apply a costume's attachments to a spawned trader. Renderer-local. Each Attach entry is a
-- static mesh on a bone (+ optional material/offset). HideBody hides the character mesh with
-- propagate=false so the attached meshes (its children) stay visible.
function applySkin(npc, def)
    if Utils.IsActorInvalid(npc) or not def then return end

    for _, a in ipairs(def.Attach or {}) do
        local o = {
            Location  = a.Location or FVector(),
            Rotation  = a.Rotation,
            Scale     = a.Scale,
            Material  = a.Mat,
            Collision = a.Collision,   -- 1 = QueryOnly (interact/camera traces hit the mesh)
        }
        if a.Skeletal then
            o.LeaderPose = a.LeaderPose   -- true = deform with the body (armor); false = rigid prop (held rod)
            AVU.AttachSkeletalMesh(npc, a.Mesh, a.Bone or "root", o)
        else
            AVU.AttachStaticMesh(npc, a.Mesh, a.Bone or "root", o)
        end
    end

    if def.HideBody then
        local mesh = Utils.GetValidMesh(npc)
        if mesh then pcall(function() mesh:SetVisibility(false, false) end) end
    end
end


-- =======================================================================
-- CLIENT-mirror access (ModuleTraders/TraderMirror): costume attaches/HideBody are renderer-local,
-- so a joined client re-applies the skin itself. Read-only costume lookup + the skin applier.
-- =======================================================================
function TR.GetCostume(key) return COSTUMES[key] end
function TR.CostumeConv(key) return COSTUME_CONV[key] end
function TR.ApplySkin(npc, key) applySkin(npc, COSTUMES[key]) end


return TR
