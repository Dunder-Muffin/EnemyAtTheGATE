-- =======================================================================
-- ModuleTraders/TraderMirror (CLIENT) - re-applies costume visuals on joined clients, since
-- costume attaches/HideBody are renderer-local component adds that don't replicate. Identifies our
-- traders by replicated TraderComponent state: TraderRow "Fili" (shared costume slot) plus
-- TradeItemsRow (which costume). Event-driven pickup (NotifyOnNewObject) + a rare FindAllOf safety
-- sweep, replacing an old 2s FindAllOf loop. Full mechanism: see AnNotes/Modules/Traders.md.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local Utils = require("AnteUtils.Utils")
local ASSETS = require("AnteCore.AssetManager")
local Traders = require("ModuleTraders.Traders")

local Log = Utils.Log

local TM = {}

local SHARED_TRADER_ROW = "Fili"
local ITEMS_TO_COSTUME = {
    ante_soda = "SodaMachine",   -- = TraderShop.ITEMS_ROW (soda offers)
    ante_fish = "Fisherman",     -- = Traders FISH_ITEM_ROW (fish trades)
    ante_hank = "Hank",          -- = Traders HANK_ITEM_ROW (stapler shop; the LOOK replicates natively)
}
-- All costumes spawn the generic trader body (TRADER_ROWS.Fili has no dedicated class).
local TRADER_BODY = "NarrativeNPC_Human_TravelingTrader_C"
local TRADER_BODY_PATH = "/Game/Blueprints/Characters/NarrativeNPCs/NarrativeNPC_Human_TravelingTrader.NarrativeNPC_Human_TravelingTrader_C"
local RETRY_MS = 2000        -- per-actor retry while its trade props haven't replicated yet
local RETRY_MAX = 15         -- ~30s per trader, then give up (the safety sweep re-seeds it)
-- The FindAllOf backstop is a STARTUP job (the bobblehead sweep's reasoning): everything built
-- after the notify arms comes through the notify, so a re-walk only ever finds traders that were
-- already in the world at Register. A few fast passes for a still-streaming world, then a slow
-- heartbeat purely so a missed notify self-heals.
local SAFETY_SCAN_MS = 30000     -- fast-pass cadence
local SAFETY_FAST_PASSES = 3
local SAFETY_SLOW_MS = 300000    -- heartbeat
local sweepsDone = 0

local mirrored = {}     -- GetFullName -> true (skin applied)
local retrying = {}     -- GetFullName -> true (a retry chain is in flight)

-- Which costume this trader wears, from replicated state. nil = not ours, or the trade props
-- haven't replicated yet - either way retry later, with no dedup mark.
local function costumeFor(npc)
    local comp = npc.TraderComponent
    if IsNotValid(comp) then return nil end
    local ok, trader = pcall(function() return comp.TraderRow.RowName:ToString() end)
    if not ok or trader ~= SHARED_TRADER_ROW then return nil end
    local ok2, items = pcall(function() return comp.TradeItemsRow.RowName:ToString() end)
    if not ok2 or not items then return nil end
    return ITEMS_TO_COSTUME[items]
end

-- One attempt on one trader. Returns true when no further attempt is needed (skin applied, already
-- done, or unreadable), false while the replicated trade props aren't in yet - they can land a
-- beat after the actor, which the caller's retry chain covers.
local function mirrorOne(npc)
    local fn
    pcall(function() fn = npc:GetFullName() end)
    if not fn or mirrored[fn] then return true end

    local key = costumeFor(npc)
    if not key then return false end
    mirrored[fn] = true

    local skin = Traders.GetCostume(key)
    if not skin then return end

    -- Client-side DT alignment: the trade grid is built from OUR local DTs (only TradeStock
    -- replicates) and reads the trader row's NPCTradeInventory slot live. So we fill the costume's
    -- items row AND point the shared Fili slot at it, the same pre-spawn repoint the server does -
    -- otherwise a later sighting inherits whatever costume repointed the slot last.
    if key == "SodaMachine" then
        pcall(function() require("ModuleTraders.TraderShop").SetupTrades() end)
    elseif key == "Fisherman" then
        pcall(function() Traders.SetupFishTrades() end)
    elseif key == "Hank" then
        pcall(function() Traders.SetupHankTrades() end)
    end
    if skin.ItemsRow then
        pcall(function()
            require("ModuleTraders.TraderUtils").SetTraderInventory(SHARED_TRADER_ROW, skin.ItemsRow)
        end)
    end
    -- ...and its name. The Setup* calls above only name the slot on their FIRST run, so without
    -- this every visit after the first of each costume carried whichever name was installed last.
    local conv = Traders.CostumeConv(key)
    if conv then
        pcall(function()
            require("ModuleTraders.TraderUtils").SetTraderConversation(SHARED_TRADER_ROW, conv)
        end)
    end

    -- Warm the skin assets, then attach + arrival sounds (the LoadAsync callback runs on the
    -- clean client drain; Attach* helpers re-resolve assets by path at use-time).
    local warm = {}
    for _, a in ipairs(skin.Attach or {}) do
        warm[#warm + 1] = a.Mesh
        if a.Mat then warm[#warm + 1] = a.Mat end
    end
    for _, s in ipairs(skin.SpawnSounds or {}) do warm[#warm + 1] = s[1] end

    ASSETS.LoadAsync(warm, function()
        if Utils.IsActorInvalid(npc) then mirrored[fn] = nil; return end
        Traders.ApplySkin(npc, key)
        for _, s in ipairs(skin.SpawnSounds or {}) do
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
        Log("TraderMirror - applied '" .. key .. "' costume")
    end)
    return true
end

-- A bounded per-actor retry chain: attempt now, then every RETRY_MS up to RETRY_MAX while the
-- trade props haven't replicated. What the old 2s global loop was really for, scoped to ONE
-- unresolved trader. A native traveling trader (never "Fili") just runs the chain out on cheap
-- property reads and is dropped.
local function watchTrader(npc, fresh)
    local fn
    pcall(function() fn = npc:GetFullName() end)
    if not fn then return end
    -- A brand-new UObject can reuse a retired trader's full name; state under that name is the
    -- old one's and would make the new body skip its costume for good.
    if fresh then mirrored[fn] = nil; retrying[fn] = nil end
    if mirrored[fn] or retrying[fn] then return end
    retrying[fn] = true

    local attempts = 0
    local function attempt()
        if not STATE.ModEnabled or Utils.IsActorInvalid(npc) then retrying[fn] = nil; return end
        local ok, done = pcall(mirrorOne, npc)
        attempts = attempts + 1
        if not ok or done or attempts >= RETRY_MAX then retrying[fn] = nil; return end
        Utils.QueueWork(attempt, RETRY_MS)
    end
    attempt()
end

-- Rare FindAllOf backstop: traders constructed BEFORE the notify armed (join-in-progress) or
-- whose retry chain expired. No-ops per already-mirrored trader.
local function safetySweep()
    if not STATE.ModEnabled then return end   -- teardown: die; next Register re-queues
    local seeded = 0
    for _, npc in ipairs(FindAllOf(TRADER_BODY) or {}) do
        if Utils.IsActorValid(npc) then
            local fn
            pcall(function() fn = npc:GetFullName() end)
            if fn and not mirrored[fn] and not retrying[fn] then seeded = seeded + 1 end
            pcall(watchTrader, npc)
        end
    end
    -- Past the seed passes, a catch means the notify missed one: worth knowing about.
    if sweepsDone >= SAFETY_FAST_PASSES and seeded > 0 then
        Log("TraderMirror - safety sweep seeded " .. seeded .. " trader(s) the notify did not deliver")
    end
    sweepsDone = sweepsDone + 1
    Utils.QueueWork(safetySweep, (sweepsDone < SAFETY_FAST_PASSES) and SAFETY_SCAN_MS or SAFETY_SLOW_MS)
end

-- Arm the client costume mirror. CLIENT only - host/SP applies skins at spawn, a dedicated server
-- has no renderer. The notify arms once per UE4SS session (it can't be unregistered, so it gates
-- on role at fire time); the safety sweep re-arms each InitMod and exits on teardown.
function TM.Register()
    if STATE.Role ~= "CLIENT" then return end
    if not SETTINGS.MODULES.TRADERS.Enabled then return end
    mirrored = {}
    retrying = {}   -- stale chains died with the WorkQueue wipe on teardown
    sweepsDone = 0  -- a new world = a new set of pre-existing traders to catch up on

    if not STATE.TraderNotifyArmed then
        STATE.TraderNotifyArmed = true
        -- NEVER touch the object inside the notify - queue it (the Coworker precedent).
        pcall(NotifyOnNewObject, TRADER_BODY_PATH, function(npc)
            Utils.QueueWork(function()
                if STATE.ModEnabled and STATE.Role == "CLIENT" then watchTrader(npc, true) end
            end, 0)
        end)
    end

    -- Always (re-)queue. Register runs once per world, after teardown wiped the previous world's
    -- queued sweep, so a "still armed" latch would leave later worlds with no sweep at all - the
    -- old loop's exact hole (the wipe killed it before it could clear its flag).
    Utils.QueueWork(safetySweep, 1000)   -- seed soon (pre-existing traders), then slow cadence
    Log("TraderMirror registered (event-driven costume mirror)")
end

return TM
