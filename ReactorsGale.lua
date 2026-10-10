-- =======================================================================
-- EVENT 9 - REACTORS GALE POWERED  (Event_ReactorsGale_Powered1 / 2 / 3)  [AUTHORITY] - ONE-TIME
--   The S2War station: each of the three war buttons powers up a front, streaming enemies onto
--   CENTER, the objective the players hold. Three near-identical events, one per button - only
--   the waves differ, so all three share one engine (galeRun) and one file.
--   * DEFAULT spawns AVU.AttackMove the whole wave onto Center once it's out (converge-on-
--     objective, not scatter-to-nearest). FIXATE ("+") spawns instead lock onto a random nearby
--     player for a temporary window (see galeFixate for the 500ms re-assert cadence).
--   * Every spawn slot re-checks player proximity first (the transition-crash guard).
--   Gate: SM.GateReactorsGale, one persisted latch per button.
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


-- The arena. Center is the shared anchor - the story gate reads it too (EV.LOC below).
local GALE_CENTER = FVector(4440, 51060, -16240)
local GALE_L1     = FVector(5130, 48595, -16590)   -- Left 1F
local GALE_L2     = FVector(3950, 48439, -16140)   -- Left 2F
local GALE_M1     = FVector(2880, 48480, -16830)   -- Middle 1F
local GALE_M2     = FVector(2940, 48300, -16230)   -- Middle 2F
local GALE_R1     = FVector(1940, 50280, -16430)   -- Right 1F
local GALE_R2     = FVector(2600, 49630, -15670)   -- Right 2F

-- Cadence (ms). Relaxed: waves 30s apart, each wave's spawns trickle in over ~12s.
local GALE_FIRST_WAVE_MS   = 1000    -- first wave a beat after the flag trips
local GALE_WAVE_GAP_MS     = 30000   -- ...and every 30s after
local GALE_WAVE_SPREAD_MS  = 12000   -- spawns WITHIN a wave spread over this long
local GALE_SEND_DELAY_MS   = 1500    -- after a wave's last spawn, wait this long (controllers up) then march to Center

local GALE_GUARD_RADIUS    = 10000   -- a player must be within this of Center to keep spawning (= sector loaded)
local GALE_SPAWN_FUZZ      = 200     -- spread around each floor point (also the navmesh search radius)

-- FIXATE ("+"): a TEMPORARY player-lock. Not permanent - it holds GALE_FIXATE_HOLD_MS then releases.
local GALE_FIXATE_HOLD_MS  = 15000   -- how long a "+" NPC stays glued to its player
local GALE_FIXATE_RADIUS   = 12000   -- pick the fixate target among players THIS close to Center

-- Mark an NPC entry as a FIXATE ("+") spawn. Plain strings are ordinary (march-to-Center) spawns.
local function F(name) return { name, Fixate = true } end

-- WAVES: each wave is a list of { Point, Npcs }. Npcs entries are a row/variant name, or F(name) for
-- a fixate ("+") spawn. Mixed base rows + variants (EVU.SpawnAt takes either).
-- NOTE: the brief's "Velites Grunt" / "Grenadier Grunt" aren't registered - the only Velites/Grenadier
-- variants are the "... Guard" ones, so those are used here. Retag if dedicated Grunt reskins land.
local GALE1_WAVES = {
    -- WAVE 1
    {
        { Point = GALE_L1, Npcs = { "Dioscoridian" } },
        { Point = GALE_L2, Npcs = { "Grunt_Guard" } },
        { Point = GALE_R1, Npcs = { "Velites Guard" } },
        { Point = GALE_R2, Npcs = { "Grunt_Captain" } },
    },
    -- WAVE 2
    {
        { Point = GALE_L2, Npcs = { "Grenadier Guard", "Grunt_Captain" } },
        { Point = GALE_M2, Npcs = { "Velites Guard" } },
        { Point = GALE_R2, Npcs = { "Velites Guard", "Neophyte Trainer", "Grunt_Shotgun" } },
    },
    -- WAVE 3
    {
        { Point = GALE_L2, Npcs = { "Adjurer Mage", "Grunt" } },
        { Point = GALE_R1, Npcs = { "Grunt_Shotgun", "Neophyte Trainer", "Grunt_Guard" } },
    },
    -- WAVE 4
    {
        { Point = GALE_L1, Npcs = { "Grunt_Guard" } },
        { Point = GALE_M1, Npcs = { "Centurion Grunt", "Centurion Grunt", "Esoteric Chieftain" } },
        { Point = GALE_R1, Npcs = { "Grunt_Guard", } }, 
    },
    -- WAVE 5
    {
    },
}

local GALE2_WAVES = {
    -- WAVE 1
    {
        { Point = GALE_L1, Npcs = { "Grunt_Guard" } },
        { Point = GALE_L2, Npcs = { "Tracker Sniper" } },
        { Point = GALE_R1, Npcs = { "Grunt_Guard", "Grunt_Guard" } },
        { Point = GALE_R2, Npcs = { "Centurion Grunt" } },
    },
    -- WAVE 2
    {
        { Point = GALE_L2, Npcs = { "Velites Guard" } },
        { Point = GALE_M1, Npcs = { "Rocket Rat", "Abjurer Mage" } },
        { Point = GALE_R1, Npcs = { "Grunt_Guard", "Dioscoridian" } },
        { Point = GALE_R2, Npcs = { "Neophyte Trainer" } },
    },
    -- WAVE 3
    {
        { Point = GALE_M1, Npcs = { "Grunt_Shotgun", "Grunt_Medic", "Jotun Steed", "Mad Rat" } },
        { Point = GALE_M2, Npcs = { F("Barrier Mage") } },
        { Point = GALE_R2, Npcs = { "Grunt_Guard", "Grunt" } },
    },
    -- WAVE 4
    {
		{ Point = GALE_L2, Npcs = { "Grenadier Grunt", "Suppressor Grunt" } },
        { Point = GALE_M1, Npcs = { "Sweeper", "Jotun Steed", "Skirmisher", "Skirmisher"  } },
		{ Point = GALE_M2, Npcs = { "Grunt_Guard", "Velites Guard" } },
    },
    -- WAVE 5
    {
        { Point = GALE_M1, Npcs = { "Neophyte Trainer", "Velites Guard", "Grunt_Shotgun", } },
    },
}

-- Order heavy, before strong GK and Bots show up
local GALE3_WAVES = {
    -- WAVE 1
    {
        { Point = GALE_L1, Npcs = { "Skirmisher", } },
        { Point = GALE_M1, Npcs = { "Sweeper"} },
        { Point = GALE_R1, Npcs = { "Skirmisher"} },
    },
    -- WAVE 2
    {
        { Point = GALE_L1, Npcs = { "Abjurer Mage" } },
        { Point = GALE_R1, Npcs = { "Suppressor Grunt", "Grunt_Captain", "Skirmisher" } },
        { Point = GALE_R2, Npcs = { "Grenadier Guard", "Groupe Sniper" } },
    },
    -- WAVE 3
    {
        { Point = GALE_L2, Npcs = { "Deatomizer Bot" } },
        { Point = GALE_R1, Npcs = { "Event Corrupted Robot" } },
    },
    -- WAVE 4
    {
		{ Point = GALE_L1, Npcs = { "Esoteric Chieftain", "Neophyte Shade", "Grunt Shade", "Neophyte Shade", } },
		{ Point = GALE_R1, Npcs = { "Mad Rat", "Grunt Shade", "Breacher Shade", "Grunt Shade" } },
		{ Point = GALE_R2, Npcs = { "Grunt Shade" } },
    },
    -- WAVE 5
    {
		{ Point = GALE_L1, Npcs = { "Breacher Shade" } },
		{ Point = GALE_M1, Npcs = { "Grunt Shade" } },
		{ Point = GALE_M2, Npcs = { "Monk Shade" } },
		{ Point = GALE_R1, Npcs = { "Grunt Shade" } },
		{ Point = GALE_R2, Npcs = { "Grunt Shade", } },
    }
}

local galeRun, galeSpawnWave, galeSendToCenter, galeFixate, galePickPlayer, galeEntry   -- below

-- The three handles. Each just runs the shared engine with its own wave list (see galeRun).
function EV.ReactorsGalePowered1() galeRun(1, GALE1_WAVES) end
function EV.ReactorsGalePowered2() galeRun(2, GALE2_WAVES) end
function EV.ReactorsGalePowered3() galeRun(3, GALE3_WAVES) end


-- =======================================================================
-- HELPERS
-- =======================================================================

-- Run one Powered event - schedule every wave at its beat. An empty wave list is a stub
-- that just logs and returns. [AUTHORITY], area-gated at t0 like the other set-pieces.
function galeRun(n, waves)
    if not Utils.IsAuthority() then return end
    if not Utils.AreaLoaded(GALE_CENTER, GALE_GUARD_RADIUS, "REACTORS GALE " .. n) then return end
    Log("Story EVENT - REACTORS GALE POWERED " .. n)

    if not waves or #waves == 0 then
        LogDebug("REACTORS GALE " .. n .. " - no waves defined yet (stub)", SETTINGS.DEBUG_STORY)
        return
    end

    for wi, wave in ipairs(waves) do
        local at = GALE_FIRST_WAVE_MS + (wi - 1) * GALE_WAVE_GAP_MS
        Utils.QueueWork(function() galeSpawnWave(n, wi, wave) end, at)
    end
end


-- Spawn one wave - flatten its floor-groups into an even stagger across
-- GALE_WAVE_SPREAD_MS, collect the non-fixate spawns, then march them at Center once they're out.
-- Fixate ("+") spawns peel off to a player instead (galeFixate) and are NOT in the Center march.
function galeSpawnWave(n, wi, wave)
    if not STATE.ModEnabled then return end

    -- Flatten { {Point, Npcs}, ... } -> ordered { Point, entry } slots, so the stagger is even
    -- across the whole wave rather than per floor-group.
    local flat = {}
    for _, grp in ipairs(wave) do
        for _, entry in ipairs(grp.Npcs) do
            flat[#flat + 1] = { point = grp.Point, entry = entry }
        end
    end
    local total = #flat
    if total == 0 then return end
    local per = (total > 1) and math.floor(GALE_WAVE_SPREAD_MS / (total - 1)) or 0

    local collected = {}   -- the wave's non-fixate spawns, marched at Center once out
    for i, s in ipairs(flat) do
        local name, fixate = galeEntry(s.entry)
        Utils.QueueWork(function()
            -- RE-CHECK per slot (the wave runs ~12s, the t0 AreaLoaded only guarded the start): all
            -- players gone = the sector is streaming out, and spawning into it is the transition-
            -- crash window. Drop this slot; no catch-up.
            if not Utils.IsPlayerNearby(GALE_CENTER, GALE_GUARD_RADIUS) then
                LogDebug("REACTORS GALE " .. n .. " - spawn slot skipped (area no longer loaded)",
                    SETTINGS.DEBUG_STORY)
                return
            end
            EVU.SpawnAt(name, s.point, {
                Fuzz = GALE_SPAWN_FUZZ,
                callback = function(npc)
                    if Utils.IsActorInvalid(npc) then return end
                    if fixate then galeFixate(npc) else collected[#collected + 1] = npc end
                end,
            })
        end, (i - 1) * per)
    end

    -- After the last spawn (+ a beat for controllers to come up), send the wave at Center.
    Utils.QueueWork(function()
        galeSendToCenter(n, wi, collected)
    end, (total - 1) * per + GALE_SEND_DELAY_MS)
end


-- March a wave's non-fixate spawns onto Center. AVU.AttackMove is the mod's "commit a
-- group to a spot" primitive (one shared aggro bait as their move goal, then parked) - cheap even
-- for a dense wave. They walk to Center and fight whatever's there: the players holding it.
function galeSendToCenter(n, wi, collected)
    local live = Utils.LivingActors(collected)
    if #live == 0 then return end

    AVU.AttackMove(live, GALE_CENTER)   -- bait is pooled/self-managed (AVU.SpawnAggroBait); don't destroy it
    LogDebug("REACTORS GALE " .. n .. " wave " .. wi .. " - " .. #live .. " sent toward Center",
        SETTINGS.DEBUG_STORY)
end


-- The "+" behavior - glue this NPC to a random nearby player, temporarily. AVU.LockAggro
-- holds for GALE_FIXATE_HOLD_MS (15s) then self-releases. Its own 500ms re-assert is what makes
-- the hold stick, since a lock otherwise lapses on the NPC's first completed swing. DelayMs lets
-- the just-spawned controller come up before the first lock.
function galeFixate(npc)
    local player = galePickPlayer()
    if Utils.IsActorInvalid(player) then return end
    AVU.LockAggro(npc, player, { HoldMs = GALE_FIXATE_HOLD_MS, DelayMs = 1000 })
end


-- A random live player near Center (the brief's "in the area"), falling back to any live
-- player. Pure-Lua distance walk against the live-player list.
function galePickPlayer()
    local near = {}
    local r2 = GALE_FIXATE_RADIUS * GALE_FIXATE_RADIUS
    for _, p in ipairs(Utils.LivePlayers()) do
        local ok, l = pcall(function() return p:K2_GetActorLocation() end)
        if ok and l and Utils.DistSq(l, GALE_CENTER) <= r2 then near[#near + 1] = p end
    end
    if #near > 0 then return near[math.random(#near)] end
    return Utils.RandomPlayer()
end


-- Decode a wave Npcs entry -> (name, fixate). A plain string is an ordinary spawn; F(name)
-- (a { name, Fixate = true } table) is a "+" fixate spawn.
function galeEntry(entry)
    if type(entry) == "table" then return entry[1], entry.Fixate == true end
    return entry, false
end


-- The anchor StoryManager's gate reads, merged into EVENTS.LOC by ModuleStory/Events
-- (the coord lives next to the event that spawns on it, so there is one copy of each).
EV.LOC = { ReactorsGale = GALE_CENTER }


return EV
