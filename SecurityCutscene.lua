-- =======================================================================
-- EVENT 5 - SECURITY CUTSCENE  (Event_Security_Cutscene)  [AUTHORITY] - ONE-TIME
--   Triggers when the Security keypad unlocks the first gate (the gate watches the keypad
--   itself - SM.GateSecurityCutscene). Preview of the Reaper reaping stuff:
--     * 3 Order npcs spawn run towards the door
--     * The Sweeper is killed, a Grunt is DBNO, and the Grunt_Captain disappears under view
--     * Deeper in, the kit of the squads that went first is strewn down the halls
--   Why a keypad and not a world flag: AnNotes/Modules/Events.md.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local EVU = require("ModuleStory.EventUtils")
local ENUMS = require("AnteData.Enums")
local Items = require("AnteData.Items")
local ItemSpawner = require("AnteCore.ItemSpawner")
local ASSETS = require("AnteCore.AssetManager")

local LogDebug = Utils.LogDebug

local EV = {}


-- ONE table for the set-piece rather than a dozen file-scope locals (the OfficeGardens pattern).
local SC = {}

SC.STAGE     = FVector(-11190, -3115, 695)  -- the Security entrance: the cutscene's stage
SC.LOCK      = FVector(-11075, -1097, 1194) -- ...and the keypad on the walkway above it, whose
                                            -- unlock is what starts it (the story gate watches it)
SC.RALLY     = FVector(-11150, -850, 695)   -- they run here; the grunt falls, the beret drops
SC.BERET_ROW = "armor_helmet_beret"         -- the captain's hat (ItemTable_Global)
SC.SQUAD     = { "Sweeper", "Grunt_Captain", "Grunt" }   -- Sweeper dies immediately
SC.VANISH_FX = "REAPER_MELD"   -- what a Shade melds through; stands in for whatever took him
SC.VANISH_S  = 3

-- The kit of the troops who went in ahead, strewn down the halls past the rally:
-- { row, X, Y, Z }. Nobody is within sight of these for well over half a minute, so they go
-- down one at a time - each is an EIGT item spawn whose BeginPlay loads a mesh.
SC.LITTER = {
    { "armor_helmet_military", -11870, -4240, 690 },
    { "backpack_medium",       -11890, -4300, 690 },
    { "armor_helmet_military", -11630, -4740, 790 },
    { "smg_military",          -12140, -4560, 690 },
    { "armor_helmet_military", -12370, -4890, 690 },
    { "armor_helmet_military", -12610, -5060, 690 },
    { "armor_helmet_breacher", -12610, -5060, 690 },
    { "backpack_medium",       -12600, -5050, 690 },
    { "magnum_military",       -12610, -5560, 790 },
    { "smg_military",          -13000, -5040, 690 },
    { "armor_helmet_military", -13000, -5440, 690 },
    { "armor_helmet_medic",    -13290, -5380, 690 },
}
SC.LITTER_FROM_MS = 12000   -- after the captain is taken, and long before anyone is down there
SC.LITTER_GAP_MS  = 1500
SC.LITTER_FUZZ    = 40      -- three marks sit on one spot; keep them from spawning inside each other

-- A dropped item spawns upright on its mark. A small shove makes it fall over and settle like
-- something that was dropped rather than placed (ItemSpawner already randomises the yaw).
local function scDropLitter(row, loc, delayMs)
    ItemSpawner.Launch(row, loc, FVector(math.random(-60, 60), math.random(-60, 60), -20),
                       SC.LITTER_FUZZ, delayMs)
end

function EV.SecurityCutscene()
    if not Utils.IsAuthority() then return end
    if not Utils.AreaLoaded(SC.STAGE, 6000, "SECURITY CUTSCENE") then return end
    LogDebug("Story EVENT - SECURITY CUTSCENE", SETTINGS.DEBUG_STORY)

    -- The vanish burst is ~8s out - long enough for GC to take a niagara nothing else references.
    ASSETS.WarmPinned({ ENUMS.Effects.FLASK_PHEROMONE_IMPACT })

    -- Cast, recorded by row name as the async spawns land. SkipSpawnFX so they just appear.
    local cast = {}
    for _, name in ipairs(SC.SQUAD) do
        EVU.SpawnAt(name, SC.STAGE, {
            Fuzz = 100, ZLift = 0, SkipSpawnFX = true,
            callback = function(npc)
                cast[name] = npc
                -- They are already running for their lives, so no startle and no roar. The aggro
                -- montage doubles as the combat-entry delay, so skipping it is also what gets
                -- them moving on the beat instead of a second late.
                AVU.SkipAggroAnim(npc)
            end,
        })
    end

    -- t+2s: the sweeper drops; the captain + grunt RUN to the rally, the grunt bleeding out.
    Utils.QueueWork(function()
        AVU.KillNpc(cast.Sweeper)
        AVU.AttackMove({ cast.Grunt_Captain, cast.Grunt }, SC.RALLY)
        if Utils.IsActorValid(cast.Grunt) then
            Utils.AddBuff(cast.Grunt, ENUMS.Debuffs.SevereBleeding)
        end
    end, 2000)

    -- t+4s: drop the grunt to 1 HP - the bleed will DBNO it on its own.
    Utils.QueueWork(function()
        if Utils.IsActorValid(cast.Grunt) then
            AVU.SetLimbHealth(cast.Grunt, { Head = 1, Torso = 1 })
        end
    end, 4000)

    -- t+8.5s: the captain is gone (taken under the bridge) - only the beret is left.
    Utils.QueueWork(function()
        local dropAt = SC.RALLY
        if Utils.IsActorValid(cast.Grunt_Captain) then
            local ok, loc = pcall(function() return cast.Grunt_Captain:K2_GetActorLocation() end)
            if ok and loc then dropAt = loc end
            pcall(function() cast.Grunt_Captain:K2_DestroyActor() end)
        end
        -- (the AttackMove bait is pooled and self-managed now - see AVU.SpawnAggroBait; don't destroy it)
        -- Sent at capsule centre; the registry entry drops it to the feet, where ground smoke reads.
        AVU.SendClientFX(dropAt, SC.VANISH_FX, SC.VANISH_S)
        ItemSpawner.DropItem(Items.Global.BASE, SC.BERET_ROW, 1,
            FVector(dropAt.X, dropAt.Y, dropAt.Z + 100))
    end, 8500)

    -- The halls beyond the rally, on their own slow drip - see SC.LITTER.
    for i, mark in ipairs(SC.LITTER) do
        scDropLitter(mark[1], FVector(mark[2], mark[3], mark[4]),
                     SC.LITTER_FROM_MS + (i - 1) * SC.LITTER_GAP_MS)
    end
end


-- The anchor StoryManager's gate reads, merged into EVENTS.LOC by ModuleStory/Events
-- (the coord lives next to the event that spawns on it, so there is one copy of each).
EV.LOC = { SecurityLock = SC.LOCK }


return EV
