-- =======================================================================================
-- AssetManager - manager that caches and fetches assets safely
-- 
--   + LoadAsset() - if called from a hook, this mostly gets called from the game thread
--       but sometimes the hook ends up on a worker thread
--         * ue4ss (553) - can throw a 'LoadAsset can't be called outside of a game thread'
--         * ue4ss (954) - can freeze the game (probably a deadlock in a thread)
-- 
--   + So we always want to call LoadAsset in an ExecuteInGameThread. But we want to wait
--       on that thread too. So put the work that requires the asset in a callback fn
-- 
--   + Creating a cache for performance, but still validate the entry (IsValid(cache[N]))
--       as UE will occasionally GC unused assets
-- 
--   + Mainly Blueprints. Native classes "/Script/..." can always be found with StaticFindObject
--  
-- 
-- General usage
-- 
--    local Assets = require("Utils.AssetManager")
-- 
--    ASSETS.LoadAsset(classPath, function(actorClass)
--       -- Spawn an actor. This should be loaded now
--       local deferred = gs:BeginDeferredActorSpawnFromClass(world, actorClass, transform, 2, nil, 0)
--    end)
-- 
-- NOTES
--   * LoadAsset spam can freeze the game. Currently running this in a throttled queue
-- =======================================================================================

---@diagnostic disable: undefined-field, undefined-global

local ASSETS = {}
ASSETS.Cache   = {} -- Cached assets
ASSETS.Loading = {} -- Assets that are currently being loaded, so we don't relook it up
ASSETS.Waiters = {} -- Everything we want to run after the asset loads

-- Paths a live pin component hard-refs, so UE cannot GC them and the cache entry
-- can be trusted outright. Written by Utils/AssetKeeper (this IS its table, shared
-- by reference) and cleared when it releases its pins.
ASSETS.Pinned  = {}


-- local Utils = require("Utils.Utils") DO NOT USE, CIRCULAR REF
local function logBad(msg) print("[GATE][ERR] " .. tostring(msg) .. "\n") end


-- Pure Cache read, no waiting. Returns the live object or nil.
--
-- TWO COMPETING HAZARDS, hence the trust check before the fallback:
--
-- 1. A CACHED /Game/ WRAPPER CAN BE A LIE. Once UE frees a UObject slot and
--    reuses it, the stale wrapper still passes IsValid(). Handing that to
--    Niagara SpawnSystemAtLocation / SetAsset is a native access violation
--    pcall CANNOT catch. StaticFindObject re-resolves by path, so it returns
--    the live object or nil - never a freed pointer.
--
-- 2. StaticFindObject IS NOT FREE. On this UE4SS build it walks the whole
--    UObject array (~20-30 ms even for a resident object), and each walk is
--    another chance to trip over a dangling Outer mid-teardown and AV. Calling
--    it on every lookup would put that cost on every NPC spawn and every FX.
--
-- So the cache is trusted ONLY where the object provably can't be GC'd:
--   * /Script/ classes and CDOs - never collected
--   * ASSETS.Pinned - a live component in Utils/AssetKeeper hard-refs it
-- Everything else re-resolves. Pin the hot paths; that's what makes this cheap.
function ASSETS.GetIfValid(path)

    if not path or path == "" then return nil end

    local cached = ASSETS.Cache[path]
    if cached and IsValid(cached)
       and (ASSETS.Pinned[path] or path:sub(1, 8) == "/Script/") then
        return cached
    end

    local obj = StaticFindObject(path)
    if obj and IsValid(obj) then
        ASSETS.Cache[path] = obj
        return obj
    end

    -- Gone from memory. Drop the entry so a later LoadAsset actually reloads.
    if cached then ASSETS.Cache[path] = nil end
    return nil
end


-- Load an asset, then run the callback fn
--   * If the asset is already cached we just run the callback
--   * If this fails, return nil for the callback
-- 
function ASSETS.LoadAsset(path, callback)
    callback = callback or function() end
    if not path or path == "" then callback(nil); return end

    -- Already resident? (GetIfValid re-resolves /Game/ paths, so this can't
    -- hand back a freed wrapper - see the note on GetIfValid.)
    local resident = ASSETS.GetIfValid(path)
    if resident then callback(resident); return end

    -- An earlier LoadAsset call started loading the same asset 
    --   so we don't need to try and load it again.
    --   Append this cb function to ASSETS.Waiters and call it when done
    -- 
    if ASSETS.Loading[path] then
        ASSETS.Waiters[path] = ASSETS.Waiters[path] or {}
        table.insert(ASSETS.Waiters[path], callback)
        return
    end

    -- Mark this asset as something being loaded
    ASSETS.Loading[path] = true
    ASSETS.Waiters[path] = { callback }


    -- Now let's load the asset. When its done, fire all the callbacks waiting on it
    ExecuteInGameThread(function()
        
        local asset, found, loaded = LoadAsset(path)
        if found and loaded and IsValid(asset) then
            ASSETS.Cache[path] = asset
        else
            logBad("AssetManager failed to load: " .. path)
            ASSETS.Cache[path] = nil
        end

        -- Clear Loading and Waiters
        local waiters = ASSETS.Waiters[path] or {}
        ASSETS.Loading[path] = nil
        ASSETS.Waiters[path] = nil

        -- Call everything waiting on this asset
        for _, cb in ipairs(waiters) do
            local ok, err = pcall(cb, ASSETS.Cache[path])
            if not ok then logBad("AssetManager callback error: " .. tostring(err)) end
        end
    end)
end


-- Will load the asset, but not wait on it
--   done for some assets that aren't super important and can be missed occasionally
function ASSETS.Warm(path)
    ASSETS.LoadAsset(path, nil)
end

return ASSETS
