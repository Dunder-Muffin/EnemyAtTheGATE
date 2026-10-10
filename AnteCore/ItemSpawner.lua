-- =======================================================================
-- ITEMSPAWNER - spawns items. We want some of our NPCs to drop more items
-- 
--   NOTES
--     * Assets/classes are async loaded every spawn (can't rely on cache)
--     * Runs off WorkQueue - so they're 200ms apart
--     * Uses our own deferredSpawn so we can set item props
--        - SetItemRow, ChangeableData can be setup before item BeginPlay() runs
--
--    (!) CRASH POINT: Item's BeginPlay() can cause a hang if run on a hook
--          - LoadAsset block if the item mesh isn't registered
--          - We must run this in its own ExecuteInGameThread()
-- 
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local UEHelpers = require("UEHelpers")
local STATE = require("AnteCore.State")
local ASSETS = require("AnteCore.AssetManager")
local SETTINGS = require("Settings")
local Utils = require("AnteUtils.Utils")
local ENUMS = require("AnteData.Enums")
local Items = require("AnteData.Items")
local SCHEMA = require("AnteData.Schema")

local CD = SCHEMA.Changeable

local Log = Utils.Log
local LogBad = Utils.LogBad
local LogDebug = Utils.LogDebug

local IS = {}

-- Next free FAST_TICK slot to keep item drops apart in queue
local nextSlotTick = 0

-- [Utils.ResetState] See NpcSpawner.ResetSlotCursor - FAST_TICK restarts at 0 each world.
function IS.ResetSlotCursor() nextSlotTick = 0 end

-- Dropped item class
local DROP_CLASS_PATH = "/Game/Blueprints/Items/Abiotic_Item_Dropped.Abiotic_Item_Dropped_C"

-- Drop item offset, if floor not found
local ITEM_Z_OFFSET = 0


local function randomYaw()
    return FRotator(0, math.random(0, 359), 0)
end


-- Spawn one dropped item. 
--   * This must run IGT, but not the IGT the hook is on (see IS.DropItem)
--   * When creating an item, set ItemDataRow + ChangeableData on the deferred actor,
--       then FinishSpawning. Item:BeginPlay will set itself up. 
--     (!) Calling SetupItem will deadlock a server
local function spawnItemActor(dataTablePath, rowName, amount, location, velocity, durability)
    LogDebug("drop[1] enter " .. tostring(rowName), SETTINGS.DEBUG_DROPS)

    local world = Utils.GetWorld()
    local gameplayStatics = UEHelpers.GetGameplayStatics()
    local kismetMath = UEHelpers.GetKismetMathLibrary()
    if IsNotValid(world) or not gameplayStatics or not kismetMath then return end

    -- Both resolves go through ASSETS, not a bare StaticFindObject (~25ms full UObject walk
    -- every call). ItemTable_Global and Abiotic_Item_Dropped_C are both ASSETS.Immortal, so
    -- after the first drop per world these are table hits. Neither path loads - a missing
    -- table still bails exactly as before.
    local dataTable = ASSETS.GetDataTable(dataTablePath)
    if IsNotValid(dataTable) then
        LogBad("ItemSpawner - data table not resident: " .. tostring(dataTablePath))
        return
    end

    -- Ground-correct: project to the navmesh floor under the (fuzzed) X/Y and spawn
    --   just above it.
    --   * DropItem's fuzz shifts X/Y up to ~90uu but keeps the ORIGINAL Z, so a drop
    --     near a wall/slope/stairs could start inside geometry and fall out of the world.
    --   * Best-effort: no floor found (cliff-edge deaths, off-mesh catwalks) = keep the
    --     old fixed offset and let physics settle it.
    --   * Reject a projection ABOVE the drop point (a ledge overhead) - taking that Z
    --     would teleport the item up through geometry.
    local groundZ = Utils.GroundZ(location)
    if groundZ and groundZ <= location.Z + 30 then
        location.Z = groundZ + 15
    else
        location.Z = location.Z + ITEM_Z_OFFSET
    end

    local transform = kismetMath:MakeTransform(location, randomYaw(), FVector(1, 1, 1))
    amount = (amount and amount > 0) and amount or 1

    local itemClass = ASSETS.GetIfValid(DROP_CLASS_PATH)
    if IsNotValid(itemClass) then
        LogBad("ItemSpawner - Item_Dropped class not found")
        return
    end

    -- LogDebug("drop[2] begin spawn", SETTINGS.DEBUG_DROPS)
    -- spawn-> / spawn<- bracket FinishSpawningActor
    LogDebug("spawn-> " .. tostring(rowName), SETTINGS.DEBUG_SPAWN_TRACE)
    
    local item = gameplayStatics:BeginDeferredActorSpawnFromClass(world, itemClass, transform, 1, nil, 0)
    if IsNotValid(item) then
        LogBad("ItemSpawner - deferred spawn failed: " .. rowName)
        return
    end

    -- LogDebug("drop[3] itemdatarow (pre-finish)", SETTINGS.DEBUG_DROPS)
    SCHEMA.SetRow(item.ItemDataRow, rowName, dataTable)
    item.nosave = true

    local cd = item.ChangeableData
    if IsValid(cd) then
        cd[CD.MaxItemDurability] = 100
        -- Current durability defaults to full (100).
        --   * A caller can pass a higher `durability` for food that lasts longer: decay
        --     subtracts from CurrentItemDurability (ItemFunctionLibrary.DecayItem), and
        --     the game lets current run OVER max, so e.g. 500 = ~5x shelf life.
        cd[CD.CurrentItemDurability] = durability or 100
        if amount > 1 then
            cd[CD.CurrentStack] = amount
        end
    end

    -- LogDebug("drop[4] finish spawn", SETTINGS.DEBUG_DROPS)
    item = gameplayStatics:FinishSpawningActor(item, transform, 0)
    LogDebug("spawn<- " .. tostring(rowName), SETTINGS.DEBUG_SPAWN_TRACE)
    if IsNotValid(item) then
        LogBad("ItemSpawner - finish spawn failed: " .. rowName)
        return
    end

    -- Optional: give the created item velocity (if the item spawns in a weird way)
    --   * The spin goes with it. An item spawns upright, and a shove through its centre of mass
    --     only slides it - a long one (a rifle, a pack) never tips over without angular velocity.
    --     SetPhysicsAngularVelocityInDegrees takes its FVector BY VALUE; the SetAllPhysics*
    --     spelling next to it is a const-ref param (CLAUDE.md section 3).
    if velocity then
        pcall(function()
            local root = item:K2_GetRootComponent()
            if IsValid(root) then
                root:SetSimulatePhysics(true)
                root:SetPhysicsLinearVelocity(velocity, false, FName("None"))
                root:SetPhysicsAngularVelocityInDegrees(
                    FVector(math.random(-180, 180), math.random(-180, 180), math.random(-180, 180)),
                    false, FName("None"))
            end
        end)
    end

    LogDebug("drop[5] done " .. rowName, SETTINGS.DEBUG_DROPS)
end


-- Drop an item at location (with fuzzRadius randomizing the loc).
--   * dataTablePath: item table path (Items.Global.BASE)
--   * rowName: row in that table (Items.Global.QUILL)
--   * amount: item stack count if > 1x
--   * location/fuzzLocation - where to drop, and some fuzzRadius 
function IS.DropItem(dataTablePath, rowName, amount, location, fuzzRadius, velocity, explicitDelayMs, durability)
    if not Utils.IsAuthority() then return end
    if not dataTablePath or not rowName or not location then return end

    if fuzzRadius and fuzzRadius > 0 then
        location = Utils.FuzzLocation(location, fuzzRadius)
    end
    
    -- Timing: stagger drops over each tick to prevent flooding
    --   * claim the next available slot, unless already set by the caller
    local delayMs
    if explicitDelayMs then
        delayMs = explicitDelayMs
    else
        nextSlotTick, delayMs = Utils.ClaimSlotTick(nextSlotTick, 2)   -- ~200ms apart
    end

    Utils.QueueWork(function()
        -- Make sure the item's data table is resident (almost always) then spawn
        ASSETS.LoadAsync({ dataTablePath }, function(results)
            if IsNotValid(results[dataTablePath]) then
                LogBad("ItemSpawner - data table failed to load: " .. tostring(dataTablePath))
                return
            end

            local function doSpawn()
                -- Freeze breadcrumb for the DEBUG_FREEZE_TRACE watchdog: the item's BeginPlay
                -- blocking-loads its WorldStaticMesh, so a hang here names the item row.
                STATE.LastWork = "EIGT itemspawn " .. tostring(rowName)
                STATE.LastWorkDone = false
                local ok, err = pcall(spawnItemActor, dataTablePath, rowName, amount or 1, location, velocity, durability)
                STATE.LastWorkDone = true
                if not ok then LogBad("ItemSpawner - spawn error: " .. tostring(err)) end
            end

            -- Spawning items must spawn off a ue4ss hook, for any ROLE
            --   * item:BeginPlay does a LoadAsset of its WorldStaticMesh thats 
            --       a blocking load. 
            --   * If this runs inside a hook callback, the game will deadlock
            --   * EIGT flushes at UE4SS's own clean point (not in a hook)
            ExecuteInGameThread(doSpawn)
        end)
    end, delayMs)
end


-- Drop a single stack of `row` from ItemTable_Global at `location`.
--   * Global is the superset table - every item row resolves there.
--   * The clean path for the common "drop X of one item" case.
function IS.Drop(row, amount, location, fuzzRadius)
    IS.DropItem(Items.Global.BASE, row, amount or 1, location, fuzzRadius)
end

-- Drop `row` at `location` with a custom starting durability (Global table,
--   exact placement - no fuzz).
--   * For perishable food, durability IS the decay meter, so durability > the row's
--     max = proportionally longer shelf life (the game allows current > max).
--     See spawnItemActor.
function IS.DropDurable(row, amount, location, durability)
    IS.DropItem(Items.Global.BASE, row, amount or 1, location, nil, nil, nil, durability)
end

-- LAUNCH one `row` from `location` with an initial `velocity` (FVector) - a
--   thrown/spewed item. Resolves in ItemTable_Global.
--   * fuzzRadius optional (scatter the spawn point).
--   * delayMs optional: the caller's own spacing (bypasses the default
--     serialization so timings don't compound).
--   * amount optional: launch ONE pickup holding a stack of N, rather than
--     N separate pickups the player has to chase down.
function IS.Launch(row, location, velocity, fuzzRadius, delayMs, amount)
    IS.DropItem(Items.Global.BASE, row, amount or 1, location, fuzzRadius, velocity, delayMs)
end

-- True if a DROPPED item of `row` is lying within `radius` of `loc` - the re-drop
--   guard for one-time stashes.
--   * The JSON latch and the game's world save are separate files: a save rollback (or an
--     /eventflags clear) can re-fire a one-time drop onto items still there. This is the
--     cheap check before that fire - look for the marker item first, skip if already down.
--   * FindAllOf is O(all UObjects) - fine here since it's a one-shot call at drop time, not
--     a tick (CLAUDE.md bans the scan only on a <15s cadence).
--   * Only sees items lying in the world, not ones already picked up into an inventory.
--     Pair with the persisted latch: the latch is the real once-ever guard, this only
--     catches the rollback/re-fire case.
--   * Only meaningful for items already spawned - IS.DropItem is deferred, so calling this
--     immediately after a Drop still reports false.
function IS.AnyDroppedNearby(row, loc, radius)
    if not row or not loc or not radius then return false end

    local r2 = radius * radius
    for _, item in ipairs(FindAllOf("Abiotic_Item_Dropped_C") or {}) do
        if IsValid(item) then
            -- Case-folded: RowName is an FName and its ToString() spelling is whatever was
            -- registered first in the process, not the caller's ([[af-fname-casing-not-stable]]).
            -- An exact compare here silently reports "nothing nearby" for custom rows.
            local ok, name = pcall(function() return item.ItemDataRow.RowName:ToString() end)
            if ok and tostring(name):lower() == tostring(row):lower() then
                local ok2, il = pcall(function() return item:K2_GetActorLocation() end)
                if ok2 and il and Utils.DistSq(loc, il) <= r2 then return true end
            end
        end
    end
    return false
end


-- =======================================================================
-- LOOT SPILL BAG - the game's own "container burst" bag (Container_LootSpillBag), spawned
-- deployed and pre-filled. The tidy alternative to scattering N stacks on the floor.
--   * Can't be picked up (CanBePackaged=false), 100 slots, `nosave`, DestroyParentWhenEmpty -
--     its inventory component SetLifeSpan(1)s the actor when the last stack is taken.
--   * FILL = in-place writes on the pre-sized empty slots (BeginPlay pads 100), then
--     MarkReplicatedDirty + OnRep_CurrentInventory - the same trio the game's own
--     DestroyDeployable does. Never a whole-array assign (the slot struct holds a DataTable
--     pointer, CLAUDE.md S3), and never CreateNewItemWithDefaultData (const-ref struct param
--     AV, [[ue4ss-const-ref-struct-param-av]]).
--   * Fill runs SYNCHRONOUSLY right after FinishSpawningActor: an empty bag self-destructs
--     ~1s after its first inventory update, so filling on a later tick is a race.
--   * Durability is the same flat 100/100 as every IS drop. Stacks must respect the row's
--     StackSize (an overstack misrenders in the UI) - split big amounts across entries.
-- =======================================================================
local SPILLBAG_CLASS = "/Game/Blueprints/DeployedObjects/Furniture/Container_LootSpillBag.Container_LootSpillBag_C"
local SPILLBAG_MESH  = "/Game/Models/Items/Misc/SM_LootBag_01.SM_LootBag_01"

local F_SLOT_ROW   = SCHEMA.Slot.ItemDataTable
local F_SLOT_CDATA = SCHEMA.Slot.ChangeableData

local function fillSpillBagSlots(bag, drops, dataTable)
    local inv = bag.ContainerInventory
    if IsNotValid(inv) then return 0 end
    local filled = 0
    local slots = inv.CurrentInventory
    local slotCount = #slots
    for i = 1, math.min(#drops, slotCount) do
        local row, amount = drops[i][1], drops[i][2] or 1
        local slot = slots[i]
        SCHEMA.SetRow(slot[F_SLOT_ROW], row, dataTable)
        local cd = slot[F_SLOT_CDATA]
        cd[CD.MaxItemDurability] = 100
        cd[CD.CurrentItemDurability] = 100
        cd[CD.CurrentStack] = amount
        filled = filled + 1
    end
    Utils.MarkReplicatedDirty(inv, "CurrentInventory")
    inv:OnRep_CurrentInventory()
    return filled
end

local function spawnSpillBagActor(location, drops)
    local world = Utils.GetWorld()
    local gameplayStatics = UEHelpers.GetGameplayStatics()
    local kismetMath = UEHelpers.GetKismetMathLibrary()
    if IsNotValid(world) or not gameplayStatics or not kismetMath then return end

    local dataTable = ASSETS.GetDataTable(Items.Global.BASE)
    local bagClass = ASSETS.GetIfValid(SPILLBAG_CLASS)
    if IsNotValid(dataTable) or IsNotValid(bagClass) then
        LogBad("ItemSpawner - spill bag class/table not resident")
        return
    end

    -- FallOnSpawn (set pre-Finish) sphere-traces 1000uu down and snaps to the floor itself,
    -- so a rough Z is fine. Random yaw like every game-spawned bag.
    local loc = FVector(location.X, location.Y, location.Z + 25)
    local transform = kismetMath:MakeTransform(loc, randomYaw(), FVector(1, 1, 1))

    local bag = gameplayStatics:BeginDeferredActorSpawnFromClass(world, bagClass, transform, 1, nil, 0)
    if IsNotValid(bag) then
        LogBad("ItemSpawner - spill bag deferred spawn failed")
        return
    end
    bag.FallOnSpawn = true
    bag = gameplayStatics:FinishSpawningActor(bag, transform, 0)
    if IsNotValid(bag) then
        LogBad("ItemSpawner - spill bag finish spawn failed")
        return
    end

    local filled = fillSpillBagSlots(bag, drops, dataTable)
    LogDebug("ItemSpawner - spill bag down (" .. filled .. " stacks)", SETTINGS.DEBUG_DROPS)
end

-- Drop a pre-filled loot spill bag at `location`.
--   * drops = ordered list of { row, amount? } - Global-table rows, one SLOT each (split
--     over-StackSize amounts into multiple entries yourself).
--   * Same threading shape as DropItem: deferred off-hook, preloaded, EIGT (the bag's
--     BeginPlay resolves its mesh/inventory - never spawn it inside a hook).
function IS.DropSpillBag(location, drops)
    if not Utils.IsAuthority() then return end
    if not location or not drops or #drops == 0 then return end

    Utils.QueueWork(function()
        ASSETS.LoadAsync({ SPILLBAG_CLASS, SPILLBAG_MESH, Items.Global.BASE }, function(results)
            if IsNotValid(results[SPILLBAG_CLASS]) then
                LogBad("ItemSpawner - spill bag class failed to load")
                return
            end
            ExecuteInGameThread(function()
                STATE.LastWork = "EIGT spillbag"
                STATE.LastWorkDone = false
                local ok, err = pcall(spawnSpillBagActor, location, drops)
                STATE.LastWorkDone = true
                if not ok then LogBad("ItemSpawner - spill bag spawn error: " .. tostring(err)) end
            end)
        end)
    end, 0)
end


-- True when `rowName` is in ItemTable_Global right now. For rows one of OUR modules builds at world
-- init: they are absent when that module is switched off, when this UE4SS cannot build rows, or
-- when the build failed - and an item dropped on a missing row is a dud.
function IS.RowExists(rowName)
    local dt = ASSETS.GetDataTable(Items.Global.BASE)
    if not dt or not rowName then return false end
    local ok, live = pcall(function()
        local row = dt:FindRow(rowName)
        return row ~= nil and row:IsValid()
    end)
    return ok and live == true
end


-- A pool/drop entry is { row, amount? } - resolves in ItemTable_Global, the superset table every
--   item row lives in, and the form every caller should use.
--   * { tablePath, row, amount? } still works for an explicit non-Global table. Detected by
--     item[2]: a string = the 3-field form (row at [2]); a number/nil = the 2-field form.
local function resolveEntry(item)
    if type(item[2]) == "string" then
        return item[1], item[2], item[3] or 1
    end
    return Items.Global.BASE, item[1], item[2] or 1
end

-- Drop from a pool of entries (see resolveEntry for the accepted shapes - bare { row, amount }
-- defaults to Global).
--   * count: nil drops every entry. Else, drop X random entries (repeats allowed)
function IS.DropPool(pool, count, location, fuzzRadius)
    if not Utils.IsAuthority() then return end
    if not pool or #pool == 0 or not location then return end

    if not count then
        for _, item in ipairs(pool) do
            local tablePath, row, amount = resolveEntry(item)
            IS.DropItem(tablePath, row, amount, location, fuzzRadius)
        end
        return
    end

    for _ = 1, count do
        local tablePath, row, amount = resolveEntry(pool[math.random(1, #pool)])
        IS.DropItem(tablePath, row, amount, location, fuzzRadius)
    end
end


-- =======================================================================
-- GIVE TO PLAYER - straight into a player's inventory, the way a harvest pays out. The game's own
-- TryPickupItemAndFindBestSlotForIt tops up existing stacks first and shows the pickup notice;
-- whatever doesn't fit drops at the player's feet.
--   * Off-hook (EIGT, all roles), like every drop here: a stack landing in the held hotbar slot
--     equips, and the held item's BeginPlay can blocking-load.
--   * The ChangeableData is what CreateDefaultChangeableData builds for a plain item: the stack,
--     and durability = the row's MaxItemDurability (food spoils out of it).
--   * One call per StackSize chunk, so a big amount never lands as one overstacked slot.
-- =======================================================================
local GIVE_DROP_FUZZ = 40
local giveResultLogged = false

local function giveNow(getPlayer, row, amount)
    local p = getPlayer()
    if not p then
        LogBad("ItemSpawner - GiveToPlayer: player left before " .. amount .. " " .. row .. " arrived")
        return
    end

    local stack, durability = amount, 100
    pcall(function()
        local r = ASSETS.GetDataTable(Items.Global.BASE):FindRow(row)
        stack = tonumber(r[SCHEMA.Item.StackSize]) or stack
        durability = tonumber(r[SCHEMA.Item.MaxItemDurability]) or durability
    end)
    if stack < 1 then stack = 1 end
    if durability <= 0 then durability = 100 end
    local handle = SCHEMA.MakeHandle(row, { DataTable = ASSETS.GetIfValid(Items.Global.BASE) })

    local spill, left = 0, amount
    while left > 0 do
        local n = math.min(left, stack)
        left = left - n
        local cd = { [CD.CurrentStack] = n, [CD.CurrentItemDurability] = durability, [CD.MaxItemDurability] = durability }
        -- Out-params want a table each; UE4SS hands their values back as extra returns.
        local ok, picked, over = pcall(function()
            return p:TryPickupItemAndFindBestSlotForIt(handle, cd, {}, {})
        end)
        if not giveResultLogged then
            giveResultLogged = true
            Log(string.format("ItemSpawner - GiveToPlayer first result: ok=%s picked=%s leftover=%s",
                tostring(ok), tostring(picked), tostring(over)))
        end
        if ok then
            spill = spill + math.max(0, math.min(n, tonumber(over) or 0))
        else
            LogBad("ItemSpawner - GiveToPlayer: pickup call failed (" .. tostring(picked) .. "); dropping instead")
            spill = spill + n + left
            left = 0
        end
    end

    if spill > 0 then
        local loc; pcall(function() loc = p:K2_GetActorLocation() end)
        if not loc then return end
        while spill > 0 do
            local n = math.min(spill, stack)
            spill = spill - n
            IS.Drop(row, n, loc, GIVE_DROP_FUZZ)
        end
    end
end

-- Give `amount` of ItemTable_Global row `row` to `player`.
function IS.GiveToPlayer(player, row, amount)
    if not Utils.IsAuthority() then return end
    amount = math.floor(tonumber(amount) or 0)
    if amount < 1 or not row or Utils.IsActorInvalid(player) then return end

    local getPlayer = Utils.CarryActor(player)
    ExecuteInGameThread(function()
        STATE.LastWork = "EIGT give " .. tostring(row)
        STATE.LastWorkDone = false
        local ok, err = pcall(giveNow, getPlayer, row, amount)
        STATE.LastWorkDone = true
        if not ok then LogBad("ItemSpawner - GiveToPlayer error: " .. tostring(err)) end
    end)
end

return IS
