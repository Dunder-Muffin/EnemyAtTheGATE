-- =======================================================================
-- LAB EVENTS [AUTHORITY] - the two Labs set-pieces, both ONE-TIME:
--     EVENT 3  Containment Breach  (Event_Lab_ContBreach)   - gate SM.GateLabContBreach
--     EVENT 4  Portal Pests        (Event_Lab_PortalPests)  - gate SM.GateLabPortalPests
--   They share nothing but the zone; kept in one file because neither is big enough to own one.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local EVU = require("ModuleStory.EventUtils")

local Log = Utils.Log
local LogDebug = Utils.LogDebug

local EV = {}


-- =======================================================================
-- EVENT 3 - LAB CONTAINMENT BREACH  (Event_Lab_ContBreach)
--   The facility-wide counterattack once the turrets are cut. One-time.
--     1) Clear the room (KILL, not despawn - it's a battlefield; the bodies stay).
--     2) Sound the assault klaxon, then the "labs day" announcement over it.
--     3) Pour enemies in from every floor, priority tier by tier (ground floor first).
--   Groups with moveTo push their spawns at another group's location once they're all out.
-- =======================================================================

local CB_CENTER       = FVector(8458, 5645, -1143)   -- the room; also the clear + area-loaded anchor
local CB_CLEAR_RADIUS = 20000
local CB_GUARD_RADIUS = 15000   -- a player must be this close for the area to count as loaded

local CB_AUDIO_KLAXON = "/Game/Audio/NarrativeNPCs/Announcements/s_announcement_assault_02.s_announcement_assault_02"
local CB_AUDIO_DAY    = "/Game/Audio/NarrativeNPCs/Announcements/s_announcement_labs_day.s_announcement_labs_day"

-- Cadence
local CB_START_MS      = 500    -- let the kill + klaxon land before the first spawn
local CB_STAGGER_MS    = 300    -- between NPCs within a group
local CB_GROUP_GAP_MS  = 500    -- between groups
local CB_TIER_GAP_MS   = 1500   -- between priority tiers
local CB_MOVE_AFTER_MS = 5000   -- force-move a group this long after it finishes spawning

-- p = priority tier (1 first), r = spawn spread, moveTo = group index to push toward.
local CB_GROUPS = {
    -- Ground floor
    [1]  = { p=1, loc = FVector(7220, 3580, -880),  r=150, npcs = { "Grunt_Guard", "Grunt_Guard", "Grunt_Medic", "Grunt_Captain", "Carbunccary" } },
    [2]  = { p=1, loc = FVector(6460, 2360, -880),  r=150, npcs = { "EventBreach Bot" }, moveTo=1 },
    [3]  = { p=1, loc = FVector(6310, 3290, -880),  r=150, npcs = { "Exor", "Electro Peccary", "Antegrav Exor", "Armored Peccary", "Chonky Pest", "Laser Pest" }, moveTo=1 },
    -- 2nd floor
    [4]  = { p=2, loc = FVector(9750, 3070, -140),  r=150, npcs = { "Gravilisk", "Grunt" }, moveTo=5 },
    [5]  = { p=2, loc = FVector(10969, 4404, -140), r=150, npcs = { "Antegrav Exor" }, moveTo=4 },
    [6]  = { p=2, loc = FVector(5925, 7270, -140),  r=150, npcs = { "Grunt_Guard", "Grunt_Guard", "Sow", "Electro Peccary", "Antegrav Pest", "Antegrav Pest" } },
    -- 3rd floor
    [7]  = { p=3, loc = FVector(6660, 6760, 610),   r=150, npcs = { "EventBreach Bot", "Peccary", "Electro Peccary", "Exor_Monk" } },
    [8]  = { p=3, loc = FVector(7550, 6190, 610),   r=150, npcs = { "Pest_Electro", "Pest_Electro" } },
    -- 4th floor
    [9]  = { p=3, loc = FVector(9070,2840, 600), r=150, npcs = { "EventBreach Bot", "EventBreach Bot", "Orchestrator" } },
    -- 5th floor
    [10] = { p=2, loc = FVector(5580, 7400, 2050),  r=150, npcs = { "Magma Exor", "Magma Exor", "Peccary_Mushroom", "Peccary_Mushroom", "EventBreach Bot", "Leyak Pest" } },
    [11] = { p=1, loc = FVector(5400, 5580, 2050),  r=150, npcs = { "Grunt_Guard", "Grunt_Guard" }, moveTo=10 },
    -- 5th floor flavor (the autoturrets mow these down)
    [12] = { p=1, loc = FVector(11640, 3760, 2050), r=150, npcs = { "Exor", "Exor_Monk" } },
}

local cbSpawnGroup   -- below

function EV.LabContBreach()
    if not Utils.IsAuthority() then return end
    if not Utils.AreaLoaded(CB_CENTER, CB_GUARD_RADIUS, "LAB CONT BREACH") then return end
    Log("Story EVENT - LAB CONTAINMENT BREACH")

    -- 1) Clear the room (bodies kept - it's a battlefield, not a vanish).
    AVU.KillNpcsInRadius(CB_CENTER, CB_CLEAR_RADIUS, "LabContBreach")

    -- 2) Klaxon, then the announcement over the top of it.
    EVU.PlayAnnouncement(CB_AUDIO_KLAXON, 4000)
    Utils.QueueWork(function() EVU.PlayAnnouncement(CB_AUDIO_DAY, 5000) end, 4500)

    -- 3) Pour in the wave, tier by tier, accumulating delay.
    local delay = CB_START_MS
    for tier = 1, 3 do
        for i = 1, #CB_GROUPS do
            local g = CB_GROUPS[i]
            if g.p == tier then
                cbSpawnGroup(g, delay)
                delay = delay + #g.npcs * CB_STAGGER_MS + CB_GROUP_GAP_MS
            end
        end
        delay = delay + CB_TIER_GAP_MS
    end
end

-- Spawn a whole group on a stagger starting at baseDelayMs; if it has moveTo, push the
-- spawned NPCs toward that group's location once they're all out.
function cbSpawnGroup(g, baseDelayMs)
    local spawned = {}
    for i, name in ipairs(g.npcs) do
        Utils.QueueWork(function()
            -- RE-CHECK per slot: the wave runs 10s+ and the entry Utils.AreaLoaded() only guarded
            -- the START. Every player having left (Megalift out mid-event) means the sector is
            -- STREAMING OUT, and spawning + mutating into an unloading level is the transition-
            -- crash window. Drop this spawn; no catch-up, the wave stays partial.
            if not Utils.IsPlayerNearby(g.loc, CB_GUARD_RADIUS) then
                LogDebug("LabContBreach - spawn slot skipped (area no longer loaded)", SETTINGS.DEBUG_STORY)
                return
            end
            EVU.SpawnAt(name, g.loc, {
                Fuzz = g.r, ZLift = 0,
                callback = function(npc) spawned[#spawned + 1] = npc end,
            })
        end, baseDelayMs + (i - 1) * CB_STAGGER_MS)
    end

    if g.moveTo and CB_GROUPS[g.moveTo] then
        local target = CB_GROUPS[g.moveTo].loc
        local moveAt = baseDelayMs + #g.npcs * CB_STAGGER_MS + CB_MOVE_AFTER_MS
        Utils.QueueWork(function() AVU.ForceMoveAll(spawned, target) end, moveAt)
    end
end


-- =======================================================================
-- EVENT 4 - LAB PORTAL PESTS  (Event_Lab_PortalPests)
--   Two Magma Pests follow the players back out of the Anteverse B exit portal, a few seconds
--   after they step through. Spawned midair at the portal's mouth so they drop to the floor.
--   StoryManager fires this 5s after LABS_CompletedAnteverseB lands; the proximity check is
--   here so a force-run far from the Labs is a no-op.
-- =======================================================================

local LPP = {
    NAME     = "Magma Pest",
    SPOTS    = { FVector(3360, 8960, 1900), FVector(3160, 8960, 1900) },   -- midair, one per pest
    NEAR     = 2500,   -- ~25m: a player must still be at the portal
    GAP_MS   = 3000,   -- between the two
}

function EV.LabPortalPests()
    if not Utils.IsAuthority() then return end
    if not Utils.IsPlayerNearby(LPP.SPOTS[1], LPP.NEAR) then
        Log("Story EVENT - LAB PORTAL PESTS skipped (no player at the portal)")
        return
    end
    Log("Story EVENT - LAB PORTAL PESTS")

    -- SkipSpawnFX: the portal is their entrance.
    for i, spot in ipairs(LPP.SPOTS) do
        Utils.QueueWork(function()
            if not STATE.ModEnabled then return end
            EVU.SpawnOne(LPP.NAME, spot, nil, { SkipSpawnFX = true })
        end, (i - 1) * LPP.GAP_MS)
    end
end


return EV
