-- =======================================================================
-- EVENT 10 - SHADOWGATE CACHE  (Event_Reactors_ShadowgateCache)  [AUTHORITY] - ONE-TIME
--   One-time item drop (Rocket Launcher + a few rockets) inside the Shadowgate building.
--   Physics drops persist on their own (BeginPlay calls SaveItem -> UpdateActorToWorldSave, same
--   as a deployable) and never despawn - TimeToDespawn only arms on the NoPhysics branch.
--   Gate: SM.GateShadowgateCache. EV.ShadowgateCacheAt is also the /rocketcache dev drop.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local Utils = require("AnteUtils.Utils")
local Items = require("AnteData.Items")
local ItemSpawner = require("AnteCore.ItemSpawner")

local Log = Utils.Log

local EV = {}


-- Where the stash lands, inside the Shadowgate building. The story gate reads it too.
local CACHE_AT = FVector(-337150, 212320, 1350)

-- Re-drop guard radius (uu): a rocket launcher already lying within this of the anchor means the
-- stash is placed. 15m covers the ~1m drop spread plus physics roll, without reaching the rest
-- of the building.
local CACHE_DUPE_RADIUS = 1500

local SHADOWGATE_CACHE = {
    { Items.Global.ROCKET_LAUNCHER, 1,  0 },
    { Items.Global.AMMO_ROCKET,     1, 45 },
    { Items.Global.AMMO_ROCKET_PEN, 1, -45 },
    { Items.Global.AMMO_ROCKET_CLUSTER, 1, 90 },
}

-- Drop the cache at an arbitrary point. Shared by the real event (fixed anchor) and the
-- /rocketcache debug command (at your feet), so the contents are defined once.
function EV.ShadowgateCacheAt(loc)
    if not Utils.IsAuthority() or not loc then return end
    for _, e in ipairs(SHADOWGATE_CACHE) do
        ItemSpawner.Drop(e[1], e[2], FVector(loc.X + e[3], loc.Y, loc.Z), 0)
    end
end

function EV.ReactorsShadowgateCache()
    if not Utils.IsAuthority() then return end

    local loc = CACHE_AT

    -- IsLocationLoaded, NOT the usual Utils.AreaLoaded player-radius guard. The gate fires the
    -- moment V_SUOMI streams in - at the ENTRANCE, 200m+ from here - so a proximity radius would
    -- reject while the gate still marked itself done, losing the cache forever. "Is that level
    -- streamed" is the real question, and it's also the right guard for a cross-zone /event.
    if not Utils.IsLocationLoaded(loc) then
        Log("Story EVENT - SHADOWGATE CACHE skipped (V_SUOMI is not streamed in)")
        return
    end

    -- RE-DROP GUARD, with the launcher as the marker item. Our once-ever latch lives in OUR json
    -- (ue4ss/saved/<world>.json) but the items live in the GAME's world save - two files, so a
    -- save rollback or an /eventflags clear can re-fire this onto a stash still lying there.
    --   * Deliberately NOT in ShadowgateCacheAt - /rocketcache is a manual dev drop.
    --   * Only sees UNLOOTED items, so it goes false once a player pockets the launcher: the
    --     persisted latch is still the real once-ever guard.
    if ItemSpawner.AnyDroppedNearby(Items.Global.ROCKET_LAUNCHER, loc, CACHE_DUPE_RADIUS) then
        Log("Story EVENT - SHADOWGATE CACHE skipped (a rocket launcher is already lying there)")
        return
    end

    EV.ShadowgateCacheAt(loc)
    Log("Story EVENT - SHADOWGATE CACHE (rocket launcher + ammo dropped)")
end


-- The anchor StoryManager's gate reads, merged into EVENTS.LOC by ModuleStory/Events
-- (the coord lives next to the event that spawns on it, so there is one copy of each).
EV.LOC = { ShadowgateCache = CACHE_AT }


return EV
