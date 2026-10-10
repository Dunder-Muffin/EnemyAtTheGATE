-- =======================================================================
-- ModuleTraders/TraderShop - the soda machine's SHOP: custom-item offers, the money-gated purchase
-- hook, and trade-window text overrides. Drink EFFECTS live in ModuleItems/CustomItemEffects, row
-- clones in ModuleItems/CustomItems, the machine itself in ModuleTraders/Traders.
-- See AnNotes/Modules/Traders.md -> TraderShop for the mechanic decode (money-gating, why no UI function
-- hooks, the open-window probe). HOST/SP renderer; a dedicated server's clients need their own
-- arming (TODO).
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local Utils = require("AnteUtils.Utils")
local SCHEMA = require("AnteData.Schema")
local TraderUtils = require("ModuleTraders.TraderUtils")

local Log = Utils.Log
local LogBad = Utils.LogBad

local TS = {}

local SODA_ITEMS_ROW = "ante_soda"         -- our DEDICATED DT_NPC_TraderItems row (cloned from the donor)
local SODA_DONOR_ROW = "trader_thule"      -- live row we CLONE from (never edited); seeds the clone's structs
TS.ITEMS_ROW = SODA_ITEMS_ROW              -- exported so Traders' SodaMachine costume points Fili at the same row
local PURCHASE_HOOK  =
    "/Game/Blueprints/Characters/Components/TraderComponent.TraderComponent_C:Server_PerformItemPurchase"
local F_ENTRY_ITEM = SCHEMA.ItemCount.Item   -- W_TraderItem_Entry.BuyableItem.Item.RowName (legacy)

-- KIZZ Vendor offers (index = trade slot). cost = MONEY ($), stock = per-VISIT limit.
--   * item = CustomItems dataTable name; keep in lockstep with CI.CUSTOM_ITEMS.
--   * label/line2 drive the trade-window text. The ($N) in line2 is PURE TEXT, not derived from
--     `cost` - edit them together or they silently drift apart.
--   * worldflag HIDES the offer until that DT_WorldFlags row is set (holds late-game sodas back).
--     SETTINGS.DEBUG_TRADER_WINDOW lifts all gating for testing.
TS.SODAS = {
    { item = "KIZZ Cubacola", cost = 4, stock = 2, label = "KIZZ Cubacola",
      line2 = "($4) A brand Stapler flavor" },
    { item = "KIZZ Codex Crimson", cost = 5, stock = 2, label = "KIZZ Codex Crimson",
      line2 = "($5) KIZZ with a mild spicy kick" },
    { item = "KIZZ Canned Chips", cost = 6, stock = 2, label = "KIZZ Canned Chips",
      line2 = "($6) 8 essential heavy metals" },
    { item = "KIZZ Hypervolt", cost = 4, stock = 2, label = "KIZZ Hypervolt",              
      line2 = "($4) A hyperenergetic beverage", worldflag = "Security_ExitOpened" },
    { item = "KIZZ Blastoff", cost = 6, stock = 2, label = "KIZZ Blastoff",
      line2 = "($6) LODED with flavor", worldflag = "Salem_Complete" },
    { item = "Arcane Sugar KIZZ", cost = 6, stock = 2, label = "Arcane Sugar KIZZ",
      line2 = "($6) Forbidden.. but organic", worldflag = "Reactors_FirstContact" },
}

local function sodaByItemRow(rowName)
    for _, s in ipairs(TS.SODAS) do if s.item == rowName then return s end end
    return nil
end

local tradesDone = false
local hookRegistered = false
local pollArmed = false

-- Trade-window poll cadence. The poll's only job is re-asserting soda text while a window is open;
-- closed, it's ~5 property reads watching for one to open. Hence two rates: fast while open (the
-- native UI rewrites RemainingCountText after each buy, so line2 must snap back), slow while idle
-- (worst case ~POLL_IDLE_MS of vanilla names on first open).
local POLL_OPEN_MS = 500
local POLL_IDLE_MS = 1500

-- Trade-window TITLE override, keyed by the trader's DT_NPC_TraderItems row so ANY custom trader
-- can brand its window. The native title reads "with <NPCName>"; the value here replaces that
-- whole part, SetText'd by the poll.
local WINDOW_TITLES = {
    [SODA_ITEMS_ROW] = "with IS-0053?",                 -- the soda machine (nameplate = DATA NOT FOUND)
    ante_hank        = "with Hank (not that Hank)",      -- = Traders HANK_ITEM_ROW
}


-- =======================================================================
-- Trade setup + purchase hook (AUTHORITY)
-- =======================================================================

-- Install the machine's offers into SODA_ITEMS_ROW. Runs on EVERY role: DataTable edits are
-- process-local, and only TradeStock replicates. An unedited client would build its trade grid
-- from a vanilla/flag-hidden row and render a blank window (the dedicated-server bug).
-- Authority calls this pre-spawn; clients call it from TraderMirror on first sighting.
function TS.SetupTrades()
    if tradesDone then return true end
    if not TraderUtils.Available() then
        LogBad("TraderShop - trader DataTable API unavailable; soda trades skipped")
        return false
    end

    if Utils.IsAuthority() then
        -- Register the purchase hook here: the machine is being made, so TraderComponent is loaded
        -- and its UFunction resolves. At world-init it could miss.
        TS.Register()
        -- The drink-effect consume hook is armed at WORLD INIT so effects work on sodas you already
        -- own with no machine around. This is a RETRY for when the consumable class wasn't loadable
        -- that early; Arm is idempotent.
        require("ModuleItems.CustomItemEffects").Arm()
    end

    -- If a soda's clone row is missing (custom items off / clone failed), fall back to the donor
    -- soda_anom - selling a MISSING row renders a broken "{ITEM_NAME}" entry.
    local CustomItems = require("ModuleItems.CustomItems")
    for _, s in ipairs(TS.SODAS) do
        if not CustomItems.RowExists(s.item) then
            LogBad("TraderShop - row '" .. s.item .. "' missing (custom items off?); falling back to soda_anom")
            s.item = "soda_anom"
        end
    end

    -- Clone the dedicated soda row from the donor FIRST (an engine copy, leaving the real Thule row
    -- untouched), then edit the CLONE. Idempotent, and runs on every role - each has its own DT.
    if not TraderUtils.CloneItemRow(SODA_DONOR_ROW, SODA_ITEMS_ROW) then
        LogBad("TraderShop - could not clone soda row; soda trades skipped")
        return false
    end

    local trades = {}
    for _, s in ipairs(TS.SODAS) do
        trades[#trades + 1] = { item = s.item, count = 1, cost = "money", costCount = 0,
                                stock = s.stock or -1, worldflag = s.worldflag }
    end
    -- Edit the CLONE in place; hideExtras retires the cloned-in leftover vanilla offers.
    if not TraderUtils.SetTrades(SODA_ITEMS_ROW, trades, { hideExtras = true }) then return false end

    tradesDone = true
    Log("TraderShop - soda trades installed in " .. SODA_ITEMS_ROW)
    return true
end

-- Identify our machine + which offer by the component's trade-items row + the (0-based) index.
local function sodaForPurchase(comp, tradeIndex)
    if IsNotValid(comp) then return nil end
    local ok, rowName = pcall(function() return comp.TradeItemsRow.RowName:ToString() end)
    if not ok or rowName ~= SODA_ITEMS_ROW then return nil end
    return TS.SODAS[(tradeIndex or 0) + 1]
end

-- Hook the trade purchase once, on authority: the PRE callback money-gates the buy. POST proved
-- unreliable on this function - PRE fired and matched, POST never did its work.
function TS.Register()
    if hookRegistered then return end
    hookRegistered = true

    RegisterHook(PURCHASE_HOOK,
        function(self, TradeIndex, Customer, PurchaseAmount)
            if not STATE.ModEnabled then return end
            local soda = sodaForPurchase(self:get(), TradeIndex:get())
            if not soda then return end   -- not our machine

            local customer = Customer:get()
            if Utils.IsActorInvalid(customer) then return end
            local amount = PurchaseAmount:get() or 1
            local cost = (soda.cost or 0) * amount

            local money = 0
            pcall(function() money = customer.CurrentMoney or 0 end)
            if money < cost then
                -- Can't afford. The native grant still gives 1 can (the unblockable Pickup
                -- Purchased Items clamp), so take it back right after. No money moves.
                pcall(function() PurchaseAmount:set(0) end)
                local itemRow = soda.item
                Utils.QueueWork(function()
                    pcall(function() customer:ConsumeItemOfSpecificCount(SCHEMA.NameArg(itemRow), 1) end)
                end, 300)
                Log("TraderShop - buy blocked (need $" .. cost .. ", have $" .. money .. ")")
                return
            end

            -- Affordable: charge money and let the native purchase hand over the can.
            pcall(function() customer:Request_ModifyMoney(-cost) end)
            Log("TraderShop - bought " .. tostring(soda.label) .. " ($" .. cost .. ")")
        end)

    Log("TraderShop - purchase hook registered")

    -- Arm the trade-window text poll here too (main.lua's attempt can be too early on some roles).
    if Utils.HasRenderer() then TS.RegisterUI() end
end


-- =======================================================================
-- Trade-window text overrides (RENDERER, via the 500ms poll)
-- =======================================================================

-- Override one W_TraderItem_Entry's text if it's one of our sodas. SetText only, so safe.
-- Non-entry children (the Blank filler) fail the BuyableItem read and are skipped.
local function overrideSodaEntry(entry, quiet)
    -- Native: the entry's item sits inside an FInstancedStruct UE4SS can't read, and no soda offers
    -- exist there to relabel (TraderUtils.SetTrades).
    if SCHEMA.Native or IsNotValid(entry) then return false end
    local ok, row = pcall(function() return entry.BuyableItem[F_ENTRY_ITEM].RowName:ToString() end)
    if not ok or not row then return false end
    local soda = sodaByItemRow(row)
    if not soda then return false end
    pcall(function()
        if soda.label and IsValid(entry.ItemNameText) then entry.ItemNameText:SetText(FText(soda.label)) end
    end)
    pcall(function()
        if soda.line2 and IsValid(entry.RemainingCountText) then
            -- Unlimited-stock (-1) items hide this text block, so force it visible
            -- (ESlateVisibility::Visible = 0) before overriding the text.
            entry.RemainingCountText:SetVisibility(0)
            entry.RemainingCountText:SetText(FText(soda.line2))
        end
    end)
    if not quiet then Log("TraderShop UI - overrode entry '" .. tostring(soda.label) .. "'") end
    return true
end

-- Walk the open trade window's entry grid and override our soda entries + the screen title.
-- `inv` is the local player's InventoryReference, resolved once by the poll to avoid a repeat
-- GetPlayerController FindAllOf per tick. `quiet` marks a re-assert pass.
local function overrideOpenTradeWindow(inv, quiet)
    local screen = IsValid(inv) and inv.Panel_TraderScreen or nil
    if IsNotValid(screen) then if not quiet then Log("TraderShop UI - trade screen not resolvable") end return end
    local grid = screen.ShopGridPanel
    if IsNotValid(grid) then if not quiet then Log("TraderShop UI - no ShopGridPanel") end return end
    local n = 0
    pcall(function() n = grid:GetChildrenCount() end)
    for i = 0, n - 1 do
        local child
        pcall(function() child = grid:GetChildAt(i) end)
        overrideSodaEntry(child, quiet)
    end
    -- Brand the title by WHICH custom trader this is (its TradeItemsRow), not by finding soda
    -- entries, so Hank gets branded too. inv.ActiveTrader IS the UTraderComponent_C, not the NPC,
    -- so read TradeItemsRow straight off it.
    local itemsRow
    pcall(function() itemsRow = inv.ActiveTrader.TradeItemsRow.RowName:ToString() end)
    local title = itemsRow and WINDOW_TITLES[itemsRow]
    if title then
        pcall(function()
            if IsValid(screen.TitleWith_Trading) then
                screen.TitleWith_Trading:SetText(FText(title))
            end
        end)
    end
end

-- =======================================================================
-- OPEN-EDGE PROBE - hooks TraderComponent.Local_OpenTraderWindow, called cross-object by the NPC's
-- interact event (same shape as the purchase hook above, which fires reliably) - unlike the widget
-- functions the top banner rules out. Purely ADDITIVE for now: one early override pass so soda
-- text is right the instant the window opens, instead of up to POLL_IDLE_MS late. If it proves
-- reliable the idle poll below could be retired in favor of it. See AnNotes/Modules/Traders.md.
-- =======================================================================
local OPEN_HOOK =
    "/Game/Blueprints/Characters/Components/TraderComponent.TraderComponent_C:Local_OpenTraderWindow"
local openHookArmed = false
local openHookFired = false   -- logged loudly on the FIRST fire; that log IS the test result

local function armOpenProbe(resolveInv)
    if openHookArmed then return end
    local ok, err = pcall(function()
        RegisterHook(OPEN_HOOK, function()
            if not STATE.ModEnabled then return end
            if not openHookFired then
                openHookFired = true
                Log("TraderShop UI - *** Local_OpenTraderWindow HOOK FIRED *** the idle poll can go")
            end
            -- Off-hook, per CLAUDE.md §2: never touch widgets from inside the hook callback. The
            -- 150ms delay matters: ActiveTrader is set BEFORE ToggleInventory, so entry widgets
            -- don't exist yet at hook time - an immediate pass would find an empty grid.
            Utils.QueueWork(function()
                local inv = resolveInv()
                if inv then overrideOpenTradeWindow(inv, false) end
            end, 150)
        end)
    end)
    if ok then
        openHookArmed = true
        Log("TraderShop - open-window probe hook registered")
    else
        -- Not fatal: the poll covers us. A failure here means TraderComponent_C was not resolvable
        -- yet and this needs main.lua's registerHookWithRetry treatment.
        LogBad("TraderShop - open-window probe hook FAILED to register: " .. tostring(err))
    end
end


-- Arms the trade-window poll (once per session, renderer roles). Re-asserts every poll while open,
-- since the native UI rewrites RemainingCountText after each buy, clobbering line2 (`walked` only
-- gates log spam). PlayerController is CACHED: UEHelpers.GetPlayerController() is a full FindAllOf
-- scan, and calling it every tick was a visible microstutter - re-resolve only when invalid.
function TS.RegisterUI()
    if pollArmed then return end
    pollArmed = true

    local UEHelpers = require("UEHelpers")
    local walked = false
    local cachedPC = nil

    -- The local player's InventoryReference, or nil. Shared by the poll AND the open probe, which
    -- is why the PC cache is hoisted out of the loop.
    local function resolveInv()
        local inv = nil
        pcall(function()
            if not (cachedPC and IsValid(cachedPC)) then
                cachedPC = UEHelpers.GetPlayerController()
            end
            local pc = cachedPC
            local pawn = IsValid(pc) and pc:K2_GetPawn() or nil
            local i = pawn and pawn.InventoryReference or nil
            if i and IsValid(i) then inv = i end
        end)
        return inv
    end

    local function loop()
        if not STATE.ModEnabled then pollArmed = false; return end
        local inv = resolveInv()
        local open = false
        pcall(function()
            open = (inv and IsValid(inv.ActiveTrader) and inv:IsVisible()) or false
        end)
        if open then
            overrideOpenTradeWindow(inv, walked)
            walked = true
        else
            walked = false
        end
        -- Fast while a window is open (snap line2 back after each buy); slow while idle.
        Utils.QueueWork(loop, open and POLL_OPEN_MS or POLL_IDLE_MS)
    end
    Utils.QueueWork(loop, POLL_IDLE_MS)
    Log("TraderShop - trade-window poll armed (" .. POLL_OPEN_MS .. "ms open / " .. POLL_IDLE_MS .. "ms idle)")

    armOpenProbe(resolveInv)
end

return TS
