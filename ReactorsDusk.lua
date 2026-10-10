-- =======================================================================
-- EVENT 7 - REACTORS DUSK DEFENSE  (Event_ReactorsDusk_Defense)  [AUTHORITY] - ONE-TIME
--   A doorway tears open across the hall; a Gatekeeper raid walks out and throws itself at the
--   hall's native Behemoth. The players walk in on someone else's fight.
--   Without AVU.SetInvincibleToNPCs there is no fight: the Behemoth subclasses the Tarasque,
--   which ships InvincibleToNPCs = true and discards all non-player damage. See AnNotes/Modules/Events.md.
--   Gate: SM.GateReactorsDusk.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local EVU = require("ModuleStory.EventUtils")

local Log = Utils.Log
local LogDebug = Utils.LogDebug

local EV = {}


local RD_TEAR          = FVector(-25650, 47230, -15640)   -- the Gatekeepers' doorway (gate anchor)
local RD_BEHEMOTH_SP   = FVector(-26033, 50216, -15735)   -- SP1: Behemoth spawnpoint
local RD_GK_SP         = FVector(-25770, 47110, -15635)   -- SP2: the raid steps out here
local RD_GK_YAW        = 45      -- SP2 facing (into the hall, toward the Behemoth)
local RD_PORTAL_YAW    = 45      -- ...and the doorway they come through faces the same way
local RD_GUARD_RADIUS  = 12000   -- a player must be this close for the hall to count as loaded
local RD_BEHEMOTH_NEAR = 10000   -- ~100m: a live Behemoth this close = don't place another
local RD_BEHEMOTH_ROW  = "Behemoth"

-- The raid: { name, ms }. Names are mixed variant/base row - EVU.SpawnAt takes either.
local RD_MAGE  = "Gatekeeper_Mage"
local RD_SQUAD = {
    { "Gatekeeper_Phyter", 2000 },
    { "Neophyte Trainer",  2500 },
    { "Neophyte Trainer",  3000 },
    { "Gatekeeper_Phyter", 3500 },
    { RD_MAGE,             5000 },
}

-- Beats (ms). The Behemoth check is t0; everything else hangs off the portal.
local RD_PORTAL_MS      = 1000
local RD_PORTAL_OPEN_MS = 7000    -- open at t1, shut a beat after the last of RD_SQUAD is through
local RD_ENGAGE_MS      = 8000
local RD_SPAWN_FUZZ     = 150

local rdOpenBehemoths, rdEngage   -- below

function EV.ReactorsDuskDefense()
    if not Utils.IsAuthority() then return end
    if not Utils.AreaLoaded(RD_TEAR, RD_GUARD_RADIUS, "REACTORS DUSK DEFENSE") then return end
    Log("Story EVENT - REACTORS DUSK DEFENSE")

    local cast = { squad = {} }

    -- t0: the Behemoth. Whatever is already standing in the hall is opened up to NPC damage and IS
    -- the target; we only place one if there is none.
    cast.behemoth = rdOpenBehemoths()[1]
    if cast.behemoth then
        LogDebug("REACTORS DUSK - Behemoth already in the hall (no respawn)", SETTINGS.DEBUG_STORY)
    else
        EVU.SpawnAt(RD_BEHEMOTH_ROW, RD_BEHEMOTH_SP, {
            Fuzz = RD_SPAWN_FUZZ,
            callback = function(npc)
                cast.behemoth = npc
                AVU.SetInvincibleToNPCs(npc, false)
            end,
        })
    end

    -- t1: tear the doorway open, facing the hall.
    Utils.QueueWork(function()
        AVU.PortalDrop(RD_TEAR, { Yaw = RD_PORTAL_YAW, OpenMs = RD_PORTAL_OPEN_MS })
    end, RD_PORTAL_MS)

    -- The raid walks out, one at a time. SkipSpawnFX: the PORTAL is their entrance, a second
    -- spawn-in burst on top of it just muddies the beat.
    for _, m in ipairs(RD_SQUAD) do
        Utils.QueueWork(function()
            EVU.SpawnAt(m[1], RD_GK_SP, {
                Fuzz = RD_SPAWN_FUZZ, Yaw = RD_GK_YAW, SkipSpawnFX = true,
                callback = function(npc)
                    cast.squad[#cast.squad + 1] = npc
                    if m[1] == RD_MAGE then cast.mage = npc end
                end,
            })
        end, m[2])
    end

    -- t8: the fight starts.
    Utils.QueueWork(function() rdEngage(cast) end, RD_ENGAGE_MS)
end


-- =======================================================================
-- HELPERS
-- =======================================================================

-- Every live Behemoth in range, opened up to NPC damage (see the InvincibleToNPCs note in
-- the banner) and handed back so the caller can pick a target. Idempotent - safe on every beat.
-- Matched by DT_NPCList ROW NAME, the only identity stable everywhere (DisplayName is ours to
-- overwrite; see CLAUDE.md). GetNearbyNpcs is alive-only, so a corpse correctly reads as "no
-- Behemoth here" and we place a fresh one.
function rdOpenBehemoths()
    local found = {}
    for _, npc in ipairs(AVU.GetNearbyNpcs(RD_BEHEMOTH_SP, RD_BEHEMOTH_NEAR)) do
        if Utils.GetActorRowName(npc) == RD_BEHEMOTH_ROW then
            AVU.SetInvincibleToNPCs(npc, false)
            found[#found + 1] = npc
        end
    end
    return found
end


-- Point the raid at the Behemoth, and the Behemoth back at the MAGE. Without it they mill
-- about and then notice the players instead. Dead cast members are skipped (LivingActors).
-- The target comes from a fresh sweep, not the t0 ref: it re-opens anything that wandered in since,
-- and it's the one place guaranteed to see the Behemoth we placed (async spawn). The t0 ref is the
-- fallback, for a spawn slow enough to miss even this.
function rdEngage(cast)
    local boss = rdOpenBehemoths()[1]
    if not boss and Utils.IsActorValid(cast.behemoth) then boss = cast.behemoth end
    if not boss then
        Log("REACTORS DUSK - no Behemoth to send the raid at")
        return
    end

    local raid = Utils.LivingActors(cast.squad)
    for _, npc in ipairs(raid) do
        AVU.ForceAggro(npc, boss)
    end

    if Utils.IsActorValid(cast.mage) then AVU.ForceAggro(boss, cast.mage) end

    LogDebug("REACTORS DUSK - " .. #raid .. " Gatekeeper(s) sent at the Behemoth", SETTINGS.DEBUG_STORY)
end


-- The anchor StoryManager's gate reads, merged into EVENTS.LOC by ModuleStory/Events
-- (the coord lives next to the event that spawns on it, so there is one copy of each).
EV.LOC = { ReactorsDusk = RD_TEAR }


return EV
