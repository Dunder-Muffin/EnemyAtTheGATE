-- =======================================================================
-- ModuleCheats/Cheats - our own versions of cheats that are BROKEN elsewhere.
--
-- Two ways in, both off in exports: chat commands (SETTINGS.DEBUG_CHEATS + DEBUG_CHAT_COMMANDS), and
-- the game console (DEBUG_CONSOLE_CHEATS alone, single player only - ConsoleCheats.lua).
-- Anything we have to reimplement because the shipped version deadlocks or a game
-- update broke it lands here. Why each one exists: AnNotes/Modules/Cheats.md.
--
--   /instantfishing            - LOCAL toggle: skip the fishing minigame       [RENDERER]
--   /au-trapleyak [krasue]     - trap the Leyak/Krasue in the nearest containment, which then never
--                                drains (alias /trapleyak; holding it already = refill) [AUTHORITY]
--   /au-trapkrasue             - same, krasue shortcut (alias /trapkrasue, either spelling of krasue/krause)
--   /npch                   - LOCAL toggle: NPC highlighter (own module, ModuleNpcHighlighter)
--   /topup                     - refill hunger/thirst, clear fatigue/bladder/rads/filth, strip debuffs [AUTHORITY]
--   /craft [on|off]            - free crafting (the game's Debug_FreeCrafting), alias /au-craft [AUTHORITY + the client's copy]
--   /refill [liquid]           - charge every carried energy item + fill the held one [AUTHORITY]
--   /health, /noclip, /invis   - god mode / fly through walls / untargetable, [on|off] or toggle [AUTHORITY]
--   /au-turret [find|break]    - report/mute/destroy the Order tank's automated LMG [AUTHORITY]
--   /au-keypads                - list nearby keypads: coords, distance, locked/unlocked [AUTHORITY]
--   /au-resetportals           - respawn vignette/portal enemies now (alias /au-resetvignette) [AUTHORITY]
--   /au-settime <h|day|night>  - jump the world clock forward to an hour (aliases /settime, /time) [AUTHORITY]
--   /au-tradervisit [costume]  - run a trader visit now via the real placement path [AUTHORITY]
--   /au-revenge [later|tonight|now|reset] <Id> - drive the revenge calendar on demand [AUTHORITY]
--
-- THREADING: every entry point runs from the CHAT-SEND hook, so real work is deferred
-- off-hook via Utils.QueueWork (section 2) - trapping fires containment FX, topup
-- touches the buff component, neither belongs inside a hook.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE   = require("AnteCore.State")
local Utils   = require("AnteUtils.Utils")
local AVU     = require("AnteUtils.AVUtils")
local ASSETS  = require("AnteCore.AssetManager")
local AFUtils = require("AFUtils.AFUtils")   -- GetAIDirector + client-local chat echo
local ENUMS   = require("AnteData.Enums")
local SCHEMA  = require("AnteData.Schema")
local AF2     = require("AnteUtils.AFUtils2")

local Log     = Utils.Log
local LogBad  = Utils.LogBad

local CH = {}

-- Helpers (defined at the bottom)
local echo, nearestContainment, armRodHook


-- =======================================================================
-- INSTANT FISHING  (RENDERER-only, per-machine toggle)
--
-- The stock CheatConsoleCommands version hangs the game: it fires FishingSuccess()
-- from a PRE-hook, before the reward has rolled and while catch montages are still
-- cold-loading (blocking-load-in-hook deadlock, CLAUDE.md section 2). We POST-hook
-- instead, once the reward is rolled, and preload the catch assets first.
-- Full decode: AnNotes/Modules/Cheats.md.
-- =======================================================================

local ROD_CLASS = "/Game/Blueprints/Items/Weapons/Guns/Weapon_FishingRod.Weapon_FishingRod_C"
local ROD_HOOK  = ROD_CLASS .. ":Start Fishing Minigame"   -- the UFunction name really does have spaces

-- Beat between the cast and the catch. Not a safety device (the preload is) -
-- it just stops the fish appearing in the same frame you cast, which reads as a bug.
local CATCH_DELAY_MS = 400

-- Everything the catch path can COLD-load, preloaded before we force it (see the header).
--   * The two Success montages are the ones that actually bite.
--   * The Fail pair + the fish tables are cheap insurance
--     (a fail roll, or a zone/fish row the client hasn't seen yet).
local FISH_PRELOAD = {
    ENUMS.Anims.ROD_CATCH_SUCCESS,
    ENUMS.Anims.FP_ROD_CATCH_SUCCESS,
    ENUMS.Anims.ROD_CATCH_FAIL,
    ENUMS.Anims.FP_ROD_CATCH_FAIL,
    "/Game/Blueprints/DataTables/Fishing/DT_Fish.DT_Fish",
    "/Game/Blueprints/DataTables/Fishing/DT_FishingZones.DT_FishingZones",
    -- The grant runs in-frame on HOST/SP: the fish item resolves through the global table,
    -- and an inventory overflow spawns a dropped item (whose BeginPlay blocking-loads its world mesh).
    "/Game/Blueprints/Items/ItemTable_Global.ItemTable_Global",
    "/Game/Blueprints/Items/Abiotic_Item_Dropped.Abiotic_Item_Dropped_C",
}

local rodHookArmed = false
local fishing      = false

-- ON/OFF (per machine). `on` nil = flip. Returns the new state.
function CH.ToggleFishing(on)
    if on == nil then on = not fishing end
    fishing = on and true or false

    -- Warm the catch assets the moment it's switched on, so the first cast is already a cache hit
    -- (the per-cast LoadAsync below is then just a no-op lookup). The console path never ran
    -- Register, so the rod hook arms here on first use.
    if fishing then
        ASSETS.WarmPinned(FISH_PRELOAD)
        armRodHook()
    end

    Log("Cheats - instant fishing " .. (fishing and "ON (minigame skipped)" or "OFF"))
    echo("Instant fishing: " .. (fishing and "ON (minigame skipped)" or "OFF"))
    return fishing
end

-- [UNUSED] no live callers; tiny state getter, kept as API.
function CH.IsFishingEnabled() return fishing end


-- =======================================================================
-- TRAP LEYAK / KRASUE  (AUTHORITY)
--
-- Leyak/Krasue share one containment + one *DirectorComponent (see LEYAK_TYPES).
-- Native TrapLeyak(FName RowName) takes one arg and matches by SpawnRow.RowName -
-- the wrong row silently traps nothing.
-- Sequence: fill stability with compatible food -> TrapLeyak(row) ->
-- SetLeyakContainmentID (skip that and the director forgets which containment holds it).
--   * Food = the containment's own LeyakContainmentData.RequiredStabilityItem for that row. The
--     wrong one isn't just cosmetic: HasEnoughStabilityItem compares it, so the catch reads as
--     unfed and is released, and the bar takes the default (red) colour.
--   * A containment this cheat filled never drains (ENDLESS CONTAINMENT below), and running it at a
--     containment already holding that stalker refills it instead of refusing.
-- Full decode: AnNotes/Modules/Cheats.md.
-- =======================================================================

local LEYAK_TYPES = {
    leyak  = { Row = "Leyak",  Food = "food_greyeb", Director = "LeyakDirectorComponent"  },   -- red bar
    krasue = { Row = "Krasue", Food = "food_milk",   Director = "KrasueDirectorComponent" },   -- blue bar
}

-- ENDLESS CONTAINMENT. Each in-game day the containment adds StabilityDecreasePerNight to its bar,
-- clamped to [0, MaxStability], and a reload restores the bar through the same clamp - so overfilling
-- past the max doesn't survive. Zeroing the drain does, if it is re-applied: the drain isn't saved,
-- so every load and every stream-in starts at the class default. The marked containments live in
-- StoryData by AssetID; CH.ArmEndlessContainments re-applies per world. Power is still required.
local CONTAINMENT_PATH = "/Game/Blueprints/DeployedObjects/Furniture/Deployed_LeyakContainment.Deployed_LeyakContainment_C"
local endlessHooked = false
-- The stalker director for `kind`, plus how many directors were seen (for the failure line).
--   * Legacy: a named member of the AI director.
--   * Native: a value of its ClassManagerDirectors map (keyed by class-manager row, e.g.
--     EntityDirector_Leyak), told apart by SpawnRow. GetStalkingComponentByRow takes its key by
--     const ref, which a Lua table can't be passed to.
local function stalkerDirector(kind)
    local ai = SCHEMA.Native and Utils.GetAIDirectorActor() or AFUtils.GetAIDirector()
    if IsNotValid(ai) then return nil, 0 end
    if not SCHEMA.Native then return ai[kind.Director], 1 end
    local found, seen = nil, 0
    ai.ClassManagerDirectors:ForEach(function(_, v)
        local c = v; pcall(function() c = v:get() end)
        seen = seen + 1
        if not found and IsValid(c) then
            local row
            pcall(function() row = SCHEMA.RowOf(c.SpawnRow) end)
            if row and row:lower() == kind.Row:lower() then found = c end
        end
    end)
    return found, seen
end

-- For /au-selftest: the director for "leyak" or "krasue", and how many were seen.
function CH.FindStalkerDirector(which)
    local kind = LEYAK_TYPES[which or "leyak"]
    if not kind then return nil, 0 end
    return stalkerDirector(kind)
end

local CONTAINMENT_CLASS = "Deployed_LeyakContainment_C"
local CONTAINMENT_RANGE = 6000   -- uu; a containment further than this isn't "the one you're at"

-- The containment's persistent id: its ChangeableData AssetID, else the deployable's SpawnedAssetID.
local function containmentId(c)
    local id
    pcall(function() id = c.ChangeableData[SCHEMA.Changeable.AssetID]:ToString() end)
    if not id or id == "" then pcall(function() id = c.SpawnedAssetID:ToString() end) end
    if id == "" then id = nil end
    return id
end

-- Zero this containment's drain if it is marked endless. True if it was.
local function applyEndless(c)
    local marked = STATE.StoryData and STATE.StoryData.EndlessContainments
    local id = marked and containmentId(c)
    if not (id and marked[id]) then return false end
    pcall(function() c.StabilityDecreasePerNight = 0 end)
    return true
end

local function markEndless(c, id)
    STATE.StoryData = STATE.StoryData or {}
    STATE.StoryData.EndlessContainments = STATE.StoryData.EndlessContainments or {}
    STATE.StoryData.EndlessContainments[id] = true
    pcall(function() require("AnteCore.FileIO").SaveStoryData() end)
    applyEndless(c)
    CH.ArmEndlessContainments()
end

-- [AUTHORITY, EVERY WORLD] Re-apply the zero drain to this save's marked containments. A no-op for a
-- save without one, so the containment class is only loaded where it's needed.
function CH.ArmEndlessContainments()
    if not Utils.IsAuthority() then return end
    local marked = STATE.StoryData and STATE.StoryData.EndlessContainments
    if not marked or next(marked) == nil then return end

    ASSETS.LoadAsync({ CONTAINMENT_PATH }, function()
        if not endlessHooked then
            ASSETS.WarmPinned({ CONTAINMENT_PATH })   -- a class that unloads takes its hook with it
            -- A restored or streamed-in containment, before its first nightly drain. The id may not
            -- be written yet at BeginPlay, so a miss looks again a moment later.
            local function onBegin(self)
                local c = self:get()
                if IsNotValid(c) or applyEndless(c) then return end
                local getC = Utils.CarryActor(c)
                Utils.QueueWork(function()
                    local again = getC()
                    if again then applyEndless(again) end
                end, 2000)
            end
            endlessHooked = pcall(RegisterHook, CONTAINMENT_PATH .. ":ReceiveBeginPlay", onBegin, onBegin)
            if not endlessHooked then LogBad("Cheats - endless-containment hook not registered") end
        end
        -- The ones already in play began before the hook existed.
        Utils.QueueWork(function()
            local n = 0
            for _, c in ipairs(FindAllOf(CONTAINMENT_CLASS) or {}) do
                if Utils.IsActorValid(c) and applyEndless(c) then n = n + 1 end
            end
            if n > 0 then Log("Cheats - " .. n .. " endless containment(s): no nightly drain") end
        end, 2000)
    end)
end

-- `which` = "leyak" (default) or "krasue". `pawn` = the sender's player pawn (for "nearest").
function CH.TrapLeyak(pawn, which)
    which = (which or ""):lower():gsub("%s+", "")
    if which == "" then which = "leyak" end

    local kind = LEYAK_TYPES[which]
    if not kind then
        Log("Cheats - /au-trapleyak: unknown type '" .. which .. "' (use leyak or krasue)")
        echo("Trap: unknown type '" .. which .. "' - use /au-trapleyak [leyak|krasue]")
        return
    end

    -- Off-hook: the trap runs the klaxon + frost-glass timeline, which can cold-load (section 2).
    Utils.QueueWork(function()
        local containment = nearestContainment(pawn)
        if not containment then
            Log("Cheats - /au-trapleyak: no containment within " .. CONTAINMENT_RANGE .. "uu")
            echo("Trap: no Leyak containment nearby (build/stand near one)")
            return
        end

        local assetId = containmentId(containment)
        if not assetId then
            LogBad("Cheats - /au-trapleyak: containment has no AssetID")
            return
        end

        -- Already holding something? ContainsLeyak is an FName ("None" = empty), and its casing
        -- isn't stable. The same stalker = refill it with the right food and make it endless;
        -- anything else = say so (TrapLeyak would early-out on DoesContainLeyak() anyway).
        local holding
        pcall(function() holding = containment.ContainsLeyak:ToString() end)
        if holding and holding ~= "" and holding ~= "None" then
            if holding:lower() ~= kind.Row:lower() then
                Log("Cheats - /au-trapleyak: containment already holds " .. holding)
                echo("Trap: that containment already holds " .. holding)
                return
            end
            local okFill = pcall(function()
                containment:ServerUpdateStabilityLevel(containment.MaxStability or 100, FName(kind.Food))
            end)
            if not okFill then
                LogBad("Cheats - /au-trapleyak: refilling the " .. kind.Row .. " containment failed")
                return
            end
            markEndless(containment, assetId)
            Log("Cheats - refilled the " .. kind.Row .. " containment (" .. assetId .. "), endless")
            echo("Refilled the " .. kind.Row .. " containment - it no longer drains")
            return
        end

        local director, seen
        pcall(function() director, seen = stalkerDirector(kind) end)
        if IsNotValid(director) then
            LogBad("Cheats - /au-trapleyak: no " .. kind.Director .. " on the AI Director ("
                .. tostring(seen) .. " director(s) seen)")
            echo("Trap: the " .. which .. " director isn't in this world")
            return
        end

        -- assetId is how the director knows WHICH containment holds the catch.
        local ok = pcall(function()
            local maxStability = containment.MaxStability or 100
            containment:ServerUpdateStabilityLevel(maxStability, FName(kind.Food))
            containment:TrapLeyak(FName(kind.Row))
            director:SetLeyakContainmentID(assetId)
        end)
        if not ok then
            LogBad("Cheats - /au-trapleyak: the native trap call failed")
            return
        end

        -- Verify rather than claim: the director only really owns it if the id stuck.
        local active
        pcall(function() active = director.ActiveLeyakContainmentID:ToString() end)
        if active == assetId then
            markEndless(containment, assetId)
            Log("Cheats - trapped the " .. kind.Row .. " (" .. assetId .. "), endless")
            echo("Trapped the " .. kind.Row .. "! Its containment never drains (power still needed)")
        else
            LogBad("Cheats - /au-trapleyak: trap did not take (ActiveLeyakContainmentID=" ..
                tostring(active) .. ")")
            echo("Trap: didn't take - is the " .. kind.Row .. " already contained or dead?")
        end
    end, 0)
end


-- =======================================================================
-- TOP UP  (AUTHORITY)  - "/topup", the "stop babysitting the survival meters" cheat.
--
-- All five ModifyStat_* clamp Current+change to [0,Max], but polarity differs:
-- Hunger/Thirst/Continence are HIGH=GOOD (+Max tops up); Fatigue is HIGH=BAD
-- (-Max tops up). Continence is "bladder capacity remaining", not "need to pee" -
-- it starts at max and eating/drinking subtracts, the toilet adds back.
-- AddToContinence is passed FALSE on Hunger/Thirst so topping up food/water
-- doesn't drain the bladder we just emptied.
--
-- Every stat reset also runs the game's own CheckFor*Debuffs, which strips that stat's
-- threshold rows for us - so those rows are NOT in the list below.
-- =======================================================================

-- The annoying, curable ones. Deliberately EXCLUDES:
--   * environmental/persistent states (Cold/Hot/Hypothermia/Insanity...) - they re-apply
--     instantly from the world, so stripping them is just a flicker.
--   * very short stuns (ParryStun, Zapped, Netted, Rooted) - they'd be gone before you typed it.
--   * the STAT-DRIVEN thresholds (hungry/thirsty/tired/bladder, the three radiation rows, and
--     Bloody/Filthy) - the game's own CheckFor*Debuffs strips those the moment the stat behind
--     them is reset, which is what the two resets below do.
--   * gear-driven states (HeavyLoad, HeavyArmorWorn) - they come back with the next step.
local TOPUP_DEBUFFS = {
    -- broken bones and sprains. These sit on a LIMB, not on the body - the strip below asks
    -- which limbs carry each row and removes it from every one, so a two-broken-leg player
    -- doesn't walk away with one still snapped.
    "Debuff_LegBroken", "Debuff_LegFracture", "Debuff_LegSprain", "Debuff_RecentLegInjury",
    "Debuff_ArmBroken", "Debuff_ArmFracture", "Debuff_ArmSprain",
    "Debuff_BrokenLegs",
    -- bleeding / trauma (the two bleeds are limb-scoped as well)
    "Debuff_Bleeding", "Debuff_SevereBleeding", "Debuff_Concussed", "Debuff_LastLeg",
    -- infection / illness
    "Debuff_Sick", "Debuff_ZombieBite", "Debuff_ZombieVirus", "Debuff_Contagious",
    -- poisons / burns / stings
    "Debuff_Poisoned", "Debuff_AcidBurn", "Debuff_Spores",
    "Debuff_BeeSting", "Debuff_BeeStingMinor", "Debuff_BeeSwarm",
    -- on fire (every ignite flavour - CLAUDE.md section 5 on why "Holy" is three different classes)
    "Debuff_Ignited", "Debuff_Ignited_Holy", "Debuff_Ignited_Plasma", "Debuff_Ignited_Unstable",
    "Debuff_Ignited_Holy_Coating",
    -- MARKED: the Tracker/Tracer snipers' tag. Worth clearing on its own - the tag loop scans for
    -- it and keeps calling in reinforcements for its whole 30-60s, even once the sniper is dead.
    ENUMS.Debuffs.ReaperTrack,
    -- grabs, tethers and floor hazards
    "Debuff_Tethered", "Debuff_LeyakTentacles", "Debuff_DarkwaterTentacles", "Debuff_EelAttack",
    "debuff_vine_slow", "Debuff_SlipperyIce", "Debuff_MGT_FloorGoo", "Debuff_CorruptBotAcidDamage",
    -- movement / gadget lockouts
    "Debuff_NoJetpack", "Debuff_NoAirControl", "Debuff_CloakScrambler",
    "Debuff_Disruption", "Debuff_QuakeDisruption", "Debuff_PortalSickness",
    -- the long aches: 2min head/neck ones, and workout soreness that runs 48 and 96 MINUTES
    "Debuff_Concussion", "Debuff_Groggy", "Debuff_SoreNeck",
    "Debuff_LacticAcid_Arms", "Debuff_LacticAcid_Legs", "Debuff_Tired_Arms", "Debuff_Tired_Legs",
    -- misc
    "Debuff_Stinky", "Debuff_GurglyTummy",
}

-- The "Filthy" (Debuff_Bloodsoaked) / "Bloody" pair are thresholds on BloodStainsData.BloodyLevel,
-- so removing the buff alone leaves you dirty and it comes straight back. Zero the level instead
-- and let the game's own check strip both rows, exactly as the decontamination shower does.
--   * The struct field carries its UserDefinedStruct GUID suffix, and only the SCALAR is written -
--     writing the whole struct back mangles it (CLAUDE.md section 3).
-- Folded lookup for the strip: FName casing is not authoritative, so a row read off the
-- component can come back spelled differently than it is written above.
local TOPUP_ROWS = {}
for _, row in ipairs(TOPUP_DEBUFFS) do TOPUP_ROWS[tostring(row):lower()] = true end

local BLOODY_LEVEL = "BloodyLevel_2_53621C11426CD8DFC8B706A54703F2AE"

local function washOffStains(pawn)
    local path = Utils.ObjectPath(pawn)
    if not path then return end
    -- EIGT: the strip runs Server_RemoveSpecificBuffs, and a cold buff object blocking-loads.
    ExecuteInGameThread(function()
        local p = Utils.ResolveByPath(path)
        if Utils.IsActorInvalid(p) then return end
        pcall(function()
            p.BloodStainsData[BLOODY_LEVEL] = 0
            Utils.MarkReplicatedDirty(p, "BloodStainsData")
            p:OnRep_BloodStainsData()      -- host/SP applies its own decals locally
            p:CheckForBloodstainDebuffs()  -- below 50 this removes Bloody + Filthy for us
        end)
    end)
end

function CH.TopUp(pawn)
    if Utils.IsActorInvalid(pawn) then return end

    -- Off-hook: buff removal + the stat writes fire OnReps / HUD updates (section 2).
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(pawn) then return end

        -- Survival meters. Passing the FULL max as the delta is fine - each one clamps.
        pcall(function() pawn:ModifyStat_Hunger(pawn.MaxHunger or 100, false) end)
        pcall(function() pawn:ModifyStat_Thirst(pawn.MaxThirst or 100, false) end)
        pcall(function() pawn:ModifyStat_Fatigue(-(pawn.MaxFatigue or 100)) end)
        pcall(function() pawn:ModifyStat_Continence(pawn.MaxContinence or 75) end)

        -- Radiation is a stat too. SkipResistance so rad gear can't scale the dose DOWN, and the
        -- native clamp-then-CheckForRadiationDebuffs drops Irradiated/Sickness/Tingle at zero.
        AVU.AddRadiation(pawn, -(pawn.MaxRadiation or 50), true)
        washOffStains(pawn)

        -- Walk what the player ACTUALLY carries rather than the wish-list: only present rows cost
        -- a RemoveBuff (each is an EIGT flush), each instance is removed from the limb it is
        -- filed under, and a row on two limbs gets two removes. Snapshot once - the removes land
        -- asynchronously, so re-reading the component per row would race them.
        local removed = 0
        for _, e in ipairs(Utils.ActorBuffs(pawn)) do
            if TOPUP_ROWS[e.Row:lower()] then
                removed = removed + 1
                Utils.RemoveBuff(pawn, e.Row, e.Limb)
                Log(string.format("Cheats - topup stripping '%s' (limb %d)", e.Row, e.Limb))
            end
        end

        Log(string.format("Cheats - topped up %s (cleared %d debuff(s))",
            Utils.GetActorName(pawn) or "player", removed))
        echo(string.format("Topped up - food/water full, rested, empty bladder, clean, no rads, %d debuff(s) cleared",
            removed))
    end, 0)
end


-- =======================================================================
-- FREE CRAFTING  - "/au-craft [on|off]", bare = toggle.
--
-- The game's own debug flag, Abiotic_PlayerCharacter.Debug_FreeCrafting (no Blueprint ever sets
-- it): DoesInventoryContainItem then answers 9999 for every recipe, bench upgrade and trade, and a
-- construction-mode deployable is placed already built.
--   * Per player and NOT replicated. The server's copy lets the craft through; the owning client's
--     copy is what its crafting UI reads. ChatCommands sets both (on a host they are one object).
-- =======================================================================

function CH.FreeCraft(pawn, rest)
    if Utils.IsActorInvalid(pawn) then return end

    local arg, want = (rest or ""):lower(), nil
    if arg == "on" or arg == "true" then
        want = true
    elseif arg == "off" or arg == "false" then
        want = false
    else
        local ok, cur = pcall(function() return pawn.Debug_FreeCrafting end)
        want = not (ok and cur == true)
    end

    if not pcall(function() pawn.Debug_FreeCrafting = want end) then
        LogBad("Cheats - free crafting: Debug_FreeCrafting write failed")
        return
    end
    Log(string.format("Cheats - free crafting %s for %s", want and "ON" or "OFF",
        Utils.GetActorName(pawn) or "player"))
    echo("Free crafting " .. (want and "ON" or "OFF"))
end


-- "on" / "off" / anything else = flip `current`.
local function toggleArg(rest, current)
    local arg = (rest or ""):lower()
    if arg == "on" or arg == "true" then return true end
    if arg == "off" or arg == "false" then return false end
    return not current
end


-- =======================================================================
-- REFILL  - "/refill [liquid]".
--   * Bare: charges every energy/laser item you carry (held, worn, hotbar, backpack), and fills the
--     held item with its current liquid (else the first it accepts).
--   * A liquid name is about the held item only, and picks the liquid for a container that takes
--     several (a barrel): /refill ink. Names: ENUMS.LiquidType.
--   * Writes the slot AND the live held item (it keeps its own copy), then refreshes the hotbar
--     through AVU.RefreshHotbar (RefreshHotbarState loads).
-- =======================================================================

function CH.Refill(pawn, rest)
    if Utils.IsActorInvalid(pawn) then return end
    local arg = (rest or ""):gsub("%s+", ""):lower()
    if arg == "gear" or arg == "all" then arg = "" end   -- the old "worn items only" mode is now the default

    Utils.QueueWork(function()
        if not Utils.IsActorValid(pawn) then return end

        local want = AF2.LiquidByName(arg)
        if arg ~= "" and not want then
            echo("Refill: unknown liquid '" .. arg .. "'")
            return
        end

        -- The held item, in whatever liquid it takes.
        local used
        local slot, inv = AF2.HeldSlot(pawn)
        local item
        pcall(function() item = pawn.ItemInHand_BP end)
        if slot and not Utils.IsActorInvalid(item) then
            local data = item.ItemData
            used = AF2.FillLiquid(slot[SCHEMA.Slot.ChangeableData], data, want)
            if used then
                AF2.FillLiquid(item.ChangeableData, data, used)
                if inv then Utils.MarkReplicatedDirty(inv, "CurrentInventory") end
            end
        end

        local charged = want and 0 or AF2.FillAllCarriedWithEnergy(pawn)
        AVU.RefreshHotbar(pawn)

        local msg
        if want then
            if not used then
                msg = "Refill: hold the container you want filled"
            else
                msg = "Refill: filled with " .. AF2.LiquidName(used)
                if used ~= want then msg = msg .. " (it doesn't take " .. AF2.LiquidName(want) .. ")" end
            end
        else
            msg = "Refill: charged " .. charged .. " energy item(s)"
            if used and not AF2.IsEnergyLiquid(used) then
                msg = msg .. ", held item filled with " .. AF2.LiquidName(used)
            end
        end
        Log("Cheats - " .. msg)
        echo(msg)
    end, 0)
end


-- =======================================================================
-- GOD MODE / NOCLIP / INVISIBLE  - "/health", "/noclip", "/invis", each [on|off]; bare = toggle.
--   * God: the character's own Invincible flag plus a full heal - the CheatConsoleCommands health
--     cheat.
--   * Noclip: CharacterMovement's cheat flying plus a capsule that ignores the first three
--     collision channels (world static, world dynamic, pawn) - the CheatConsoleCommands recipe. On
--     it is re-applied each pass; off restores Block on those channels and walking.
--   * Invisible: NPC_Targetable = false, the switch every NPC target check reads (the game's own
--     end-credits ghost state). NPCs drop you as a target and can't acquire you; a variant that
--     picks its own targets without AVU.IsTargetableByNPCs can still see you.
--   * The game resets all three (a landing drops the flying mode, a revive clears Invincible, the
--     credits flip NPC_Targetable back), so a keeper re-asserts them every KEEP_MS while any is on.
--   * Movement is client-predicted: ChatCommands also runs NoClip on a pure client's own pawn.
-- =======================================================================

local KEEP_MS = 500
local godOn, noclipOn, invisOn = {}, {}, {}   -- ActorKey -> pawn wrapper
local keeperArmed = false

local function healFully(pawn)
    for _ = 1, 6 do AVU.HealRandomLimb(pawn, 1000) end
end

local function applyGod(pawn)
    local was
    pcall(function() was = pawn.Invincible end)
    if was == true then return end
    pcall(function() pawn.Invincible = true end)
    Utils.MarkReplicatedDirty(pawn, "Invincible")
    if Utils.IsAuthority() then healFully(pawn) end
end

local function applyFlying(move, on)
    if on then
        if move.bCheatFlying ~= true or tonumber(move.MovementMode) ~= 5 then
            move.bCheatFlying = true
            move:SetMovementMode(5, 0)       -- MOVE_Flying
        end
    else
        move.bCheatFlying = false
        move:SetMovementMode(1, 0)           -- MOVE_Walking
    end
end

-- Off the drain, like a player teleport: a capsule response change begins or ends every overlap
-- around the player at once (zone FX, level triggers, buff zones), and a handler that cold-loads
-- wedges the hook frame. Flying goes first on the way in and last on the way out, so the capsule
-- is never walking without a floor.
local function applyNoClip(pawn, on)
    local path = Utils.ObjectPath(pawn)
    if not path then return end
    Utils.DelayedGameThread(50, function()
        local p = Utils.ResolveByPath(path)
        if IsNotValid(p) then return end
        STATE.LastWork = "OFFHOOK noclip " .. (on and "on " or "off ") .. path
        STATE.LastWorkDone = false
        local ok = pcall(function()
            local move, cap = p.CharacterMovement, p.CapsuleComponent
            if on then applyFlying(move, true) end
            for ch = 0, 2 do cap:SetCollisionResponseToChannel(ch, on and 0 or 2) end
            if not on then applyFlying(move, false) end
        end)
        STATE.LastWorkDone = true
        if not ok then LogBad("Cheats - noclip: movement/capsule write failed") end
    end)
end

-- Keeper pass: flying is re-asserted in place (no overlap change); the capsule only hops again if
-- something put its responses back.
local function keepNoClip(pawn)
    pcall(function()
        applyFlying(pawn.CharacterMovement, true)
        local resp = tonumber(pawn.CapsuleComponent:GetCollisionResponseToChannel(0))
        if resp and resp ~= 0 then applyNoClip(pawn, true) end
    end)
end

-- Write-on-change, so the keeper's steady state is a bool read.
local function applyInvis(pawn, on)
    local want = not on
    local cur
    pcall(function() cur = pawn.NPC_Targetable end)
    if cur == want then return end
    pcall(function()
        pawn:FlushNetDormancy()
        pawn.NPC_Targetable = want
    end)
    Utils.MarkReplicatedDirty(pawn, "NPC_Targetable")
end

local function keep()
    local any = false
    for key, pawn in pairs(godOn) do
        if Utils.IsActorValid(pawn) then applyGod(pawn); any = true else godOn[key] = nil end
    end
    for key, pawn in pairs(noclipOn) do
        if Utils.IsActorValid(pawn) then keepNoClip(pawn); any = true else noclipOn[key] = nil end
    end
    for key, pawn in pairs(invisOn) do
        if Utils.IsActorValid(pawn) then applyInvis(pawn, true); any = true else invisOn[key] = nil end
    end
    if any then Utils.QueueWork(keep, KEEP_MS, true) else keeperArmed = false end
end

local function armKeeper()
    if keeperArmed then return end
    keeperArmed = true
    Utils.QueueWork(keep, KEEP_MS, true)
end

function CH.God(pawn, rest)
    if Utils.IsActorInvalid(pawn) then return end
    local key = Utils.ActorKey(pawn)
    if not key then return end
    local want = toggleArg(rest, godOn[key] ~= nil)
    Utils.QueueWork(function()
        if not Utils.IsActorValid(pawn) then return end
        if want then
            godOn[key] = pawn
            applyGod(pawn)
            armKeeper()
        else
            godOn[key] = nil
            pcall(function() pawn.Invincible = false end)
            Utils.MarkReplicatedDirty(pawn, "Invincible")
        end
        Log("Cheats - god mode " .. (want and "ON" or "OFF") .. " for " .. (Utils.GetActorName(pawn) or "player"))
        echo("God mode " .. (want and "ON" or "OFF"))
    end, 0)
end

function CH.NoClip(pawn, rest)
    if Utils.IsActorInvalid(pawn) then return end
    local key = Utils.ActorKey(pawn)
    if not key then return end
    local want = toggleArg(rest, noclipOn[key] ~= nil)
    Utils.QueueWork(function()
        if not Utils.IsActorValid(pawn) then return end
        noclipOn[key] = want and pawn or nil
        applyNoClip(pawn, want)
        if want then armKeeper() end
        Log("Cheats - noclip " .. (want and "ON" or "OFF") .. " for " .. (Utils.GetActorName(pawn) or "player"))
        echo("Noclip " .. (want and "ON" or "OFF"))
    end, 0)
end

function CH.Invis(pawn, rest)
    if Utils.IsActorInvalid(pawn) then return end
    local key = Utils.ActorKey(pawn)
    if not key then return end
    local want = toggleArg(rest, invisOn[key] ~= nil)
    Utils.QueueWork(function()
        if not Utils.IsActorValid(pawn) then return end
        invisOn[key] = want and pawn or nil
        applyInvis(pawn, want)
        if want then armKeeper() end
        Log("Cheats - invisible " .. (want and "ON" or "OFF") .. " for " .. (Utils.GetActorName(pawn) or "player"))
        echo("Invisible to NPCs " .. (want and "ON" or "OFF"))
    end, 0)
end


-- =======================================================================
-- LIST BUFFS  - "/aubuffs", the companion to /topup.
--
-- Prints the component's live CurrentBuffs: exact row name + the limb it is filed under.
-- Written for the case /topup can't fix - a row spelled differently than TOPUP_DEBUFFS expects,
-- or one that survives the strip - where the answer is which of those two happened.
-- =======================================================================

local LIMB_NAMES = { [0] = "all", "randombone", "randomnohead", "head", "torso",
                     "leftarm", "rightarm", "leftleg", "rightleg" }

function CH.ListBuffs(pawn)
    if Utils.IsActorInvalid(pawn) then return end

    local buffs = Utils.ActorBuffs(pawn)
    if #buffs == 0 then
        echo("Buffs: none")
        return
    end

    -- One chat line per buff: a single joined line is unreadable past a handful, and the strip
    -- list is long enough that a fracture hides in it.
    echo(string.format("Buffs (%d):", #buffs))
    for _, e in ipairs(buffs) do
        local where = LIMB_NAMES[e.Limb] or ("limb " .. tostring(e.Limb))
        echo(string.format("  %s  [%s]", e.Row, where))
        Log(string.format("Cheats - buff '%s' on %s", e.Row, where))
    end
end


-- =======================================================================
-- ORDER TANK TURRET  (AUTHORITY)  - "/au-turret [find|break]"
--
-- The automated LMG on the Order tank (Deployed_S2WarTurret on a DestructibleTank).
-- MaxDurability=0 so it can't be shot down; the tank itself only accepts
-- DamageType_Explosive. Full decode: EVENT 13 banner in ModuleStory/Events - this
-- is just the "at your feet" entry point, sharing that code.
-- `find` reports the tank's exact world coords, for TANK_AT in ModuleStory/InqAssault.
-- =======================================================================

local TANK_CLASS_CH = "DestructibleTank_C"
local TANK_FIND_RANGE = 15000   -- uu; a tank further than this isn't "the one you're standing at"

-- `which` = "" (disable), "find" (report only), or "break" (blow the tank up - permanent).
function CH.TankTurret(pawn, which)
    which = (which or ""):lower():gsub("%s+", "")

    if which ~= "" and which ~= "find" and which ~= "break" then
        echo("Turret: unknown mode '" .. which .. "' - use /au-turret [find|break]")
        return
    end

    -- Off-hook like the other cheats: we're inside the chat-send hook, and the break path
    -- loads FX assets. FindAllOf is fine here - one-shot typed command, not a tick.
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(pawn) then return end
        local origin = pawn:K2_GetActorLocation()
        if not origin then return end

        local best, bestDistSq, bestLoc
        for _, t in ipairs(FindAllOf(TANK_CLASS_CH) or {}) do
            if Utils.IsActorValid(t) then
                local loc = t:K2_GetActorLocation()
                -- The distance test also rejects the class-default object (it reads as origin).
                if loc and Utils.WithinDistance(origin, loc, TANK_FIND_RANGE) then
                    local d = Utils.DistSq(origin, loc)
                    if d and (not bestDistSq or d < bestDistSq) then best, bestDistSq, bestLoc = t, d, loc end
                end
            end
        end

        if not best then
            Log("Cheats - /au-turret: no Order tank within " .. TANK_FIND_RANGE .. "uu")
            echo("Turret: no Order tank nearby (is its level streamed in?)")
            return
        end

        -- The coords line - the whole point of `find`, and useful on the other modes too.
        -- %.0f, NOT %d: a location is a float, and Lua 5.4's %d throws on a non-integer number.
        local coords = string.format("FVector(%.0f, %.0f, %.0f)", bestLoc.X, bestLoc.Y, bestLoc.Z)
        local broken = false
        pcall(function() broken = best.Broken end)
        Log("Cheats - /au-turret: tank at " .. coords .. (broken and " [ALREADY BROKEN]" or ""))
        echo("Tank at " .. coords .. (broken and " (already destroyed)" or "") ..
            "  -> paste into TANK_AT in ModuleStory/InqAssault")
        if which == "find" then return end

        -- Tight radius: act on THIS tank only, never a second one elsewhere in the level.
        local hits = require("ModuleStory.Events").DisableTankTurretsAt(bestLoc, 500, {
            Break = (which == "break"),
            Label = "/au-turret",
        })

        if hits == 0 then
            echo("Turret: nothing to do (already broken, or the tank has no LMG attached)")
        elseif which == "break" then
            echo("Turret: breaking the tank (permanent - saved to the world)")
        else
            echo("Turret: muted (may fire one last queued shot)")
        end
    end, 0)
end


-- =======================================================================
-- KEYPADS  (AUTHORITY)  - "/au-keypads"
--
-- Reports every Button_Keypad near you: coords, distance and whether it is already unlocked.
-- The story gates that trigger off a lock (GATE 7, Security) match their keypad by LOCATION -
-- a placed prop has no other identity - so this is how the anchor coord gets read in the first
-- place, and how "the gate never fired" gets told apart from "the coord is wrong".
-- =======================================================================

-- Button_Generic is the parent of every button in the game, and FindAllOf matches SUBCLASSES,
-- so this one query covers keypads too - the same shape SC_LOCK_CLASS uses in StoryManager.
local KEYPAD_CLASS_CH = "Button_Generic_C"
local KEYPAD_RANGE_CH = 3000   -- 30m: what's in this room, not the whole wing

-- `mode` = "" (list) or "relock" (clear the NEAREST button's Activated, in memory only).
function CH.Keypads(pawn, mode)
    mode = (mode or ""):lower():gsub("%s+", "")
    if mode ~= "" and mode ~= "relock" then
        echo("Keypads: unknown mode '" .. mode .. "' - use /au-keypads [relock]")
        return
    end

    -- Off-hook like the other cheats (we're inside the chat-send hook). FindAllOf is fine here -
    -- a one-shot typed command, not a tick.
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(pawn) then return end
        local origin = pawn:K2_GetActorLocation()
        if not origin then return end

        local found, nearest, nearestDistSq = 0, nil, nil
        for _, b in ipairs(FindAllOf(KEYPAD_CLASS_CH) or {}) do
            if Utils.IsActorValid(b) then
                local loc = b:K2_GetActorLocation()
                -- The distance test also rejects the class-default object (it reads as origin).
                if loc and Utils.WithinDistance(origin, loc, KEYPAD_RANGE_CH) then
                    found = found + 1
                    local d = Utils.DistSq(origin, loc)
                    if d and (not nearestDistSq or d < nearestDistSq) then nearest, nearestDistSq = b, d end

                    if mode == "" then
                        local on = false
                        pcall(function() on = b.Activated == true end)
                        -- %.0f, NOT %d: a location is a float, and Lua 5.4's %d throws on a non-integer.
                        local line = string.format("%s  FVector(%.0f, %.0f, %.0f)  %.0fm  %s",
                            Utils.GetActorClassName(b) or "?", loc.X, loc.Y, loc.Z,
                            math.sqrt(d or 0) / 100, on and "UNLOCKED" or "locked")
                        Log("Cheats - /au-keypads: " .. line)
                        echo(line)
                    end
                end
            end
        end

        if found == 0 then
            echo("Keypads: no buttons within " .. (KEYPAD_RANGE_CH / 100) .. "m (is its level streamed in?)")
            return
        end
        if mode ~= "relock" then return end

        -- RELOCK - retesting a gate that triggers off a lock, on a save that already opened it.
        -- A BARE property write: no MarkReplicatedDirty, no OnRep_Activated, no
        -- UpdateButtonSaveData. Nothing else in the game is told, so the door it opened stays
        -- open, the button keeps its opened look, and the world save is untouched - the only
        -- thing that changes is what a watcher polling Activated reads. Using the keypad again
        -- takes the ordinary unlock arm (the ubergraph branches on Activated being false) and
        -- sets it true for real, which is the whole point. Gone on the next reload.
        pcall(function() nearest.Activated = false end)
        local loc = nearest:K2_GetActorLocation()
        Log(string.format("Cheats - /au-keypads relock: %s at FVector(%.0f, %.0f, %.0f)",
            Utils.GetActorClassName(nearest) or "?", loc.X, loc.Y, loc.Z))
        echo("Relocked the nearest button in memory (not saved, door left open).")
        echo("Now: /eventflags Reaper to clear the latch, then use the keypad again.")
    end, 0)
end


-- =======================================================================
-- VIGNETTE / PORTAL RESET  (AUTHORITY)  - "/au-resetportals" / "/au-resetvignette"
--
-- Calls Abiotic_GameInstance:ResetVignettes() - the same call DayNightManager
-- makes on a PortalResetDays morning, so vignette enemies respawn on demand
-- instead of waiting for the weekly day. Our SystemHooks post-hook still fires,
-- so the per-vignette story-flag bookkeeping happens too.
-- =======================================================================

function CH.ResetVignettes()
    Utils.QueueWork(function()
        local gi
        pcall(function() gi = Utils.GetWorld().OwningGameInstance end)
        if IsNotValid(gi) then gi = FindFirstOf("Abiotic_GameInstance_C") end
        if IsNotValid(gi) then echo("Reset portals: no GameInstance (world not up?)"); return end

        local ok, err = pcall(function() gi:ResetVignettes() end)
        if ok then
            Log("Cheats - ResetVignettes fired")
            echo("Portals/vignettes reset - vignette enemies respawn")
        else
            echo("Reset portals FAILED: " .. tostring(err))
        end
    end, 0)
end


-- =======================================================================
-- SET TIME  (AUTHORITY)  - "/au-settime <0-23|day|night>"
--
-- Native path: DayNightManager:ProgressTimeSeconds(delta), the same jump SLEEPING
-- uses. FORWARD ONLY - an earlier hour means advancing to TOMORROW's. Replication
-- and the sky update are handled natively (nothing to mark here). Crossing hours
-- fires the real HourChanged chain (announcements, weather, AssaultCheckHour),
-- which is why this is useful for EATG assault testing.
-- =======================================================================

function CH.SetTime(rest)
    Utils.QueueWork(function()
        local mgr = Utils.GetDayNightManager()
        if not mgr then echo("Set time: no DayNightManager (world not up?)"); return end

        local arg = (rest or ""):lower():match("^(%S*)") or ""
        local hour
        if arg == "day" or arg == "morning" then
            pcall(function() hour = mgr.MorningStartHour end)
            hour = hour or 8
        elseif arg == "night" then
            pcall(function() hour = mgr.NightfallStartHour end)
            hour = hour or 20
        else
            hour = tonumber(arg)
        end
        if not hour or hour < 0 or hour >= 24 then
            echo("Usage: /au-settime <0-23|day|night>  (forward only)")
            return
        end

        local now, dayLen = 0, 86400
        pcall(function() now = mgr.CurrentTimeInSeconds or 0 end)
        pcall(function() dayLen = mgr["24HoursInSeconds"] or 86400 end)

        local delta = (hour * 3600 - now) % dayLen
        if delta < 1 then delta = delta + dayLen end   -- asked for "now" = a full day ahead

        local ok, err = pcall(function() mgr:ProgressTimeSeconds(delta) end)
        if ok then
            Log(string.format("Cheats - settime %02d:00 (advancing %.1fh)", hour, delta / 3600))
            echo(string.format("Time -> %02d:00 (advancing %.1f in-game hours)", hour, delta / 3600))
        else
            echo("Set time FAILED: " .. tostring(err))
        end
    end, 0)
end


-- =======================================================================
-- TRADER VISIT  (AUTHORITY)  - "/au-tradervisit [costume]"
--
-- Runs a scheduled visit NOW through TraderDirector's real placement path - not
-- the keybind spawn, which drops one at your feet and skips placement entirely.
-- No arg = whatever's queued; an arg names a costume, resolved loosely by
-- TR.ResolveCostume. Needs a base with a Crafting Bench nearby or the director
-- skips the visit by design.
-- =======================================================================

function CH.TraderVisit(rest)
    Utils.QueueWork(function()
        local TD = require("ModuleTraders.TraderDirector")
        local TR = require("ModuleTraders.Traders")

        local arg = (rest or ""):match("^%s*(%S*)") or ""
        local costume
        if arg ~= "" then
            costume = TR.ResolveCostume(arg)
            if not costume then
                echo("Trader visit: unknown costume '" .. arg .. "'")
                return
            end
        end

        local ok, why = TD.ForceVisit(costume)
        if ok then
            Log("Cheats - forced trader visit" .. (costume and (" (" .. costume .. ")") or ""))
            echo("Trader visit forced" .. (costume and (": " .. costume) or "")
                .. " - the log says where it landed")
        else
            echo("Trader visit FAILED: " .. tostring(why))
        end
    end, 0)
end


-- =======================================================================
-- Register
-- =======================================================================

-- Every world: the keeper's queue item died with the last world's WorkQueue, and its pawns with it.
function CH.ResetWorld()
    godOn, noclipOn, invisOn, keeperArmed = {}, {}, {}, false
end

-- Per world under DEBUG_CHEATS. Chat cheats need no arming - ChatCommands calls straight into
-- them - so this is the world reset plus the fishing-rod hook, up front.
function CH.Register()
    CH.ResetWorld()
    armRodHook()
end

-- Arm the fishing-rod hook, once per session. RENDERER ONLY - a dedicated server never runs the
-- minigame. Force-loads the rod class first since RegisterHook can't resolve a UFunction until its
-- class is in memory. Idempotent.
function armRodHook()
    if rodHookArmed or not Utils.HasRenderer() then return end

    ASSETS.LoadAsync({ ROD_CLASS }, function()
        if rodHookArmed then return end
        ASSETS.WarmPinned({ ROD_CLASS })   -- a class that unloads takes its hook with it
        local ok, err = pcall(function()
            -- POST hook (the no-op pre is just how UE4SS takes a post callback):
            -- by the time this runs, the body has rolled the reward (Local_DetermineReward)
            -- and armed the minigame.
            RegisterHook(ROD_HOOK, function() end, function(self)
                if not fishing then return end
                local rod = self:get()
                if IsNotValid(rod) then return end

                -- RequiredCaptures = 1 (junk) or 3 (fish) after a successful roll; stays -1 if
                -- Local_DetermineReward bailed (no fish/bait, rod broke). Forcing a catch on -1
                -- would eat the cast on an empty reward, so: no roll, no cheat.
                local req = -1
                pcall(function() req = rod.RequiredCaptures end)
                if req == -1 then return end

                -- Re-resolve BY PATH across the hop: a wrapper captured into a deferred callback
                -- can be freed, and IsValid lies about it (section 3).
                local path = Utils.ObjectPath(rod)
                if not path then return end

                ASSETS.LoadAsync(FISH_PRELOAD, function()
                    Utils.QueueWork(function()
                        local r = Utils.ResolveByPath(path)
                        if IsNotValid(r) then return end
                        pcall(function() r:FishingSuccess() end)
                    end, CATCH_DELAY_MS)
                end)
            end)
        end)

        if ok then
            rodHookArmed = true
            Log("Cheats - fishing rod hook armed (/instantfishing to toggle)")
        else
            LogBad("Cheats - fishing rod hook not registered (" .. tostring(err) .. ")")
        end
    end)
end


-- =======================================================================
-- Helpers
-- =======================================================================

-- Echo to the sender's own chat.
--   * DEFERRED (QueueWork): we may be inside the chat-send hook, and writing to the chat widget
--     from there is the Slate-tree hazard (section 2).
--   * No-op on a dedicated server (no renderer, no chat widget to write to).
function echo(msg)
    if not Utils.HasRenderer() then return end
    Utils.QueueWork(function() AFUtils.DisplayTextChatMessage(msg) end, 0)
end


-- =======================================================================
-- REVENGE ASSAULTS  (AUTHORITY) - drive ModuleRevenge's calendar without waiting on in-game days.
--   "/au-revenge"               - status: day, clock, fire window, booked nights
--   "/au-revenge later <Id>"    - book via the real scheduler, ignoring its trigger
--   "/au-revenge tonight <Id>"  - book for TODAY (pair with /au-settime 22 to fire it)
--   "/au-revenge now [<Id>]"    - start one right now, no hour/bench check
--   "/au-revenge reset"         - wipe the calendar and re-baseline to today
--
-- <Id> is a case-insensitive substring ("train" finds Revenge_Train).
-- Not a keybind: the Id argument is the point, and a keybind can't carry one.
-- =======================================================================
function CH.Revenge(rest)
    Utils.QueueWork(function()
        local RD = require("ModuleRevenge.RevengeDirector")
        local arg, id = (rest or ""):match("^%s*(%S*)%s*(.-)%s*$")
        arg = (arg or ""):lower()

        if arg == "reset" then
            local n = RD.ResetCalendar()
            echo("Revenge: calendar wiped (" .. n .. " cleared); triggers will re-book on the next beat")
            return
        end

        if arg == "later" or arg == "queue" or arg == "book" or arg == "tonight" then
            local tonight = (arg == "tonight")
            if id == "" then
                echo("Revenge: which one? \"/au-revenge " .. arg .. " <Id>\""); return
            end
            local ok, res = RD.QueueLater(id, tonight)
            if ok then
                echo(string.format("Revenge: booked for night %s%s", tostring(res),
                    tonight and " (TONIGHT - jump to 22:00 to fire it)" or ""))
                for _, line in ipairs(RD.Describe()) do echo(line) end
            else
                echo("Revenge: " .. tostring(res))
            end
            return
        end

        if arg == "now" or arg == "force" or arg == "start" then
            local ok, why = RD.ForceNow(id ~= "" and id or nil)
            echo(ok and ("Revenge: starting " .. tostring(why))
                    or ("Revenge: " .. tostring(why)))
            return
        end

        for _, line in ipairs(RD.Describe()) do echo(line) end
    end, 0)
end

-- The Leyak containment closest to `pawn`, within CONTAINMENT_RANGE. nil if there is none.
-- Skips destroyed ones. FindAllOf is fine here: this is a one-shot chat cheat, not a tick.
function nearestContainment(pawn)
    if Utils.IsActorInvalid(pawn) then return nil end
    local origin = pawn:K2_GetActorLocation()
    if not origin then return nil end

    local best, bestDistSq
    for _, c in ipairs(FindAllOf(CONTAINMENT_CLASS) or {}) do
        if Utils.IsActorValid(c) then
            local destroyed = false
            pcall(function() destroyed = c.DeployableDestroyed end)
            if not destroyed then
                local loc = c:K2_GetActorLocation()
                if loc and Utils.WithinDistance(origin, loc, CONTAINMENT_RANGE) then
                    local d = Utils.DistSq(origin, loc)
                    if d and (not bestDistSq or d < bestDistSq) then
                        best, bestDistSq = c, d
                    end
                end
            end
        end
    end
    return best
end


return CH
