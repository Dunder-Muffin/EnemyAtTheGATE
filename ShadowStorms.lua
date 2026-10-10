-- =======================================================================
-- ModuleShadow/ShadowStorms - content half of the boss module: extra spawns during the portal
-- storms (Storm 1/2) and during the boss phases. ShadowBoss.lua owns the clocks and calls us via
-- SB.OnStormContent(phase)/OnStormEnd()/OnStormReset() for storms, SB.OnBossContent(phase)/
-- OnBossContentEnd() for boss phases (armed at each ApplyPhaseStatsToBoss).
-- Everything we spawn goes through SB.Track(npc), so a storm can't end while any of it lives (cap
-- StormMaxSeconds). CleanBodies on a storm sweeps corpses at storm start.
--
-- Storm N runs after BossPhase N (CurrentBossPhase still reads N during it). A storm script is a
-- drip (one spawn from a list every N s, capped) plus timed rifts (a doorway open ~20s that lets
-- a fixed sequence out). Arrivals mostly aggro EACH OTHER before players:
--   * A2 variants marked LockGK lock onto the nearest Gatekeeper for a while.
--   * Every Gatekeeper arrival locks onto the nearest non-player, non-GK enemy for a while.
--   Locks lapse when the target dies, then they turn on the players.
--
-- THREADING: all timing goes through Utils.QueueWork; every callback re-checks the storm TOKEN
-- and STATE.ModEnabled. Spawns route through SP.SummonVariant/SP.PortalSummon (CLAUDE.md S2).
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local ENUMS = require("AnteData.Enums")
local ASSETS = require("AnteCore.AssetManager")

local Log, LogDebug = Utils.Log, Utils.LogDebug
local DBG = SETTINGS.DEBUG_NPC_ACTIONS

local SS = {}

-- Placement bands (uu) around a random live player
local DRIP_MIN, DRIP_MAX = 1200, 2500      -- 12-25m - range players spawn
local RIFT_MIN, RIFT_MAX = 1000, 1500      -- 10-15m - GK doorway
local LOCK_SEARCH = 6000                   -- how far a fresh arrival looks for something to pick on
local LOCK_HOLD_MS = 10000                 -- how long an arrival stays locked on its first target
local FACTION_A2, FACTION_GK = 5, 6        -- E_Factions VALUES (Anteverse2 / Gatekeepers)
local FACTION_ORDER = 3                    -- E_Factions VALUE (the Order)

-- The "big enemies" an A2 arrival picks on (matched by ROW NAME or variant DISPLAY NAME -
-- the list mixes native rows and our variants; Yeti/Orchestrator are the faction-0 bruisers).
local BIG_ENEMIES = {
    ["DarkLens_Witch"] = true, ["DarkLens_Heavy"] = true, ["Interfector"] = true,
    ["Rocket Rat"] = true, ["Purifier"] = true, ["Yeti"] = true, ["Orchestrator"] = true,
}


-- =======================================================================
-- THE ARENA GATES - four fixed island portals, shared by Storm 2 (OpenGates) and BossPhase-3
-- cycles. Opened ONCE (fight-length FX lifetime; StopClientFX is the real close; p3KeysUp is the
-- dedupe latch) and stay up across the storm->phase-3 seam. Close at victory/reset.
-- Z values are capsule-height, in-game captured - see openRift below for the doorway Z lesson.
-- =======================================================================
SS.GATES = { 
    EXOR_A = { Key = "PORTAL_REDVERSE_HOLD", X = 133100, Y = 32090, Z = 134830 }, 
    EXOR_B = { Key = "PORTAL_REDVERSE_HOLD", X = 136580, Y = 36050, Z = 133050 }, 
    GK     = { Key = "GK_PORTAL", X = 132870, Y = 37660, Z = 134680, Yaw = -110 }, 
    ORDER  = { Key = "PORTAL_YELLOW_HOLD", X = 130690, Y = 34050, Z = 134790, Yaw = 0, 
               NoBurst = true },
}

-- Drip names that DON'T belong to a gate faction: they still materialize near a player
-- (the old band) instead of walking in from a gate.
local NONFACTION_NEAR_PLAYER = {
    ["Orchestrator"] = true, ["Yeti"] = true, ["Obsidilisk"] = true, ["Tarasque Slammer"] = true,
}


-- =======================================================================
-- THE SCRIPTS - one per storm. Missing entries = that storm gets no extras. Field reference and
-- full targeting rules: AnNotes/Modules/ShadowStorms.md.
--   Drip:  EverySeconds, MaxSpawns (per-storm cap), MaxAlive, List (variant names), LockGK
--          (names that lock onto a nearby GK). UseGates = true -> spawn from a random EXOR gate.
--   Rifts: At (s after storm start), Spawns = { {T=s, Npc=<row>} | {T=s, Variant=<name>} }, T =
--          seconds after the rift opens. Gate = "GK"|"ORDER"|... steps the column out of that
--          fixed gate; without Gate, a roaming doorway near a random player.
--   OpenGates = true -> open ALL of SS.GATES at storm start (persist into phase 3).
--   CleanBodies = true -> corpse sweep at storm start (loot untouched).
-- =======================================================================
SS.STORMS = {
    [1] = {
        Drip = {
            EverySeconds = 5, MaxSpawns = 12, MaxAlive = 8,
            List = {
                "Razor Pest", "Exor Magus", "Charge Peccary", "Chonky Pest", "Exorrior",
                "Phase Peccary", "Magma Exor", "Pestilence", "Exor Hunter", "Volatile Pest",
                "Exor Repeller", "Hive Sow", "Volatile Peccary", "Exorrior Magus", "Magma Peccary",
                "Flurry Pest", "Exor Spiritwalker", "Flurry Pest", "Exor Spiritwalker",

            },
            LockGK = { ["Exorrior"] = true, ["Magma Exor"] = true, ["Exor Hunter"] = true,
                       ["Exor Magus"] = true, ["Exor Spiritwalker"] = true },
        },
        Rifts = {
            { At = 10, OpenSeconds = 20, Spawns = {
                { T = 5,  Variant = "Hospitality Bot" },   -- a VARIANT (base Robot_Security), not a row
                { T = 10, Variant = "Neophyte Trainer" },
                { T = 15, Base = "Gatekeeper_Phyter" },
                { T = 19, Variant = "Warrior Witch" },
            } },
            { At = 50, OpenSeconds = 20, Spawns = {
                { T = 5,  Variant = "Constrictor Bot" },
                { T = 10, Variant = "Storm Witch" },
                { T = 15, Variant = "Gatekeeper Provisioner" },   -- the supply mule: kill for its loot bag
                { T = 19, Variant = "Jotun Rocketeer" },
            } },
        },
    },
    [2] = {
        CleanBodies = true,   -- sweep every NPC corpse off the field at storm start
        OpenGates = true,     -- tear open all four island gates; they stay up through phase 3
        Drip = {
            EverySeconds = 5, MaxSpawns = 12, MaxAlive = 8,
            UseGates = true,   -- A2 bodies walk in from the EXOR gates (nonfaction: near player)
            List = {
                "Exor Dislocator", "Flurry Pest", "Leyak Pest", "Obsidilisk",
                "Winter Exor", "Charge Peccary", "Pestilence", "Orchestrator",
                "Exor Spiritwalker", "Chonky Signal Pest", "Acidic Exor", "Tarasque Charger",
                "Exor Repeller", "Volatile Peccary", "Leyak Pest", "Tarasque Slammer",
                "Armored Peccary", "Exor Hunter", "Hive Sow", "Armored Peccary", 

            },
            LockGK = { ["Yeti"] = true, ["Exor Dislocator"] = true, ["Tarasque Slammer"] = true,
                       ["Winter Exor"] = true, ["Exor Spiritwalker"] = true },
        },
        Rifts = {
            { At = 10, Gate = "GK", Spawns = {
                { T = 5,  Npc = "DarkLens_Witch" },
                { T = 10, Npc = "Gatekeeper_Phyter" },
                { T = 15, Variant = "Gatekeeper Provisioner" },
                { T = 20, Variant = "Neophyte Tamer" },
                { T = 25, Npc = "Robot_Corrupt" },
                { T = 35, Variant = "Barrier Mage" },
                { T = 40, Npc = "Gatekeeper_Phyter" },
                { T = 50, Variant = "Deatomizer Bot" },
                { T = 55, Variant = "Esoteric Chieftain" },
                { T = 75, Npc = "DarkLens_Heavy" },
                { T = 80, Variant = "Gatekeeper Provisioner" },
            } },
            { At = 10, Gate = "ORDER", Spawns = {
                { T = 1,  Npc = "Grunt_LabRat_Mechanic" },
                { T = 5,  Npc = "Grunt_Captain" },
                { T = 9,  Variant = "Velites Guard" },
                { T = 13, Variant = "Grenadier Guard" },
                { T = 17, Npc = "Mad Rat" },
                { T = 21, Npc = "Interfector" },
                { T = 25, Variant = "Centurion Grunt" },
                { T = 29, Variant = "Suppressor Grunt" },
                { T = 33, Npc = "Grunt_Sapper" }, 
                { T = 37, Variant = "Dioscoridian" },
                { T = 41, Variant = "Skirmisher" },
                { T = 45, Variant = "Shield Embolon" },
                { T = 49, Variant = "Shield Embolon" },
                { T = 53, Variant = "Signifer" },
                { T = 57, Npc = "Interfector" },
                { T = 61, Variant = "Rocket Rat" },
                { T = 70, Variant = "Purified Grunt" },
                { T = 72, Variant = "Purified Grunt" },
                { T = 74, Variant = "Purified Breacher" },
                { T = 77, Variant = "Purifier" },
                { T = 90, Variant = "Rocket Rat" },
                { T = 100, Npc = "Interfector" },
                { T = 105, Npc = "Interfector" },
            } },
        },
    },
}


-- =======================================================================
-- BOSS-PHASE content - pressure during the boss fight itself (not storms). Same script idea, own
-- lifecycle: armed at ApplyPhaseStatsToBoss (SB.OnBossContent), stopped on boss death / storm
-- start / world reset (SB.OnBossContentEnd, reason-tagged) - its own token, independent of the
-- storm token above.
--   Drip: EverySeconds, MaxAlive, List of { Npc=<row> } | { Variant=<name> }. No MaxSpawns -
--         phase-long pressure.
--   Portals: fixed SS.GATES held open all phase; each gate runs its own spawn loop in parallel,
--         cycling its Spawns list (EverySeconds, or PortalEverySeconds default).
--   MaxAlive: cap on our phase spawns alive at once - the real pressure knob.
--   MaxTotal: whole-phase gate budget across all gates; nil = unlimited.
--   CoaxSeconds: nudges our spawns far from every player toward a random one.
-- Full mechanics (gate loop cursor/stagger, phase-3 feud, coax rules): AnNotes/Modules/ShadowStorms.md.
-- =======================================================================
SS.BOSS_PHASES = {
    [2] = {
        Drip = {
            EverySeconds = 10, MaxAlive = 2,
            List = { { Variant = "Chonky Pest" }, { Npc = "Pest_Volatile" },
                     { Variant = "Phase Peccary" }, { Npc = "Peccary_Snow" },
                     { Variant = "Exorrior Magus" }, { Npc = "Exor" }, }
        },
    },
    [3] = {
        MaxAlive = 20,
        MaxTotal = 20,       -- the whole phase's gate budget, all gates together (then the gates go quiet)
        CoaxSeconds = 15,
        PortalEverySeconds = 8,
        Portals = {
            { Gate = "EXOR_A", Spawns = {
                { Variant = "Exor Hunter" }, { Variant = "Exorrior" }, { Variant = "Winter Exor" },
                { Variant = "Armored Peccary" }, { Variant = "Acidic Exor" }, { Variant = "Chonky Pest" },
                { Npc = "Exor_Monk" }, 
            } },
            { Gate = "EXOR_B", Spawns = {
                { Npc = "Exor" }, { Variant = "Razor Pest" }, { Variant = "Armored Peccary" },
                { Variant = "Volatile Peccary" }, { Variant = "Exor Repeller" },
                { Variant = "Exor Magus" },
            } },
            { Gate = "ORDER", EverySeconds = 12, Spawns = {
                { Variant = "Purified Grunt" }, { Variant = "Sweeper" }, { Variant = "Grenadier Guard" },
                { Variant = "Signifer" }, { Variant = "Mad Rat" }, { Npc = "Interfector" },
                { Npc = "Grunt_FlameRat" }, { Variant = "Purified Breacher" },
            } },
            { Gate = "GK", EverySeconds = 12, Spawns = {
                { Variant = "Deatomizer Bot" }, { Variant = "Weak Phyter" }, 
                { Variant = "Neophyte Trainer" }, { Variant = "Weak Phyter" },
                { Npc = "Warrior Witch" }, { Variant = "Plague Witch" },
                { Variant = "Advanced Hospitality Bot" }, { Npc = "Gatekeeper_Phyter" },
                { Variant = "Neophyte Trainer" }, { Variant = "Weak Phyter" },
            } },
        },
    },
}

local BOSS_DRIP_MIN, BOSS_DRIP_MAX = 500, 1500   -- 5-15m from a random player
local CLEAN_DELAY_MS = 4000                       -- body sweep: let the boss death settle first
local NPC_CLASS_SHORT = "NPC_Base_ParentBP_C"

-- Phase-3 arena gates
local P3_PORTAL_LIFE_S = 1800     -- FX lifetime backstop; StopClientFX at phase end is the real close
local P3_FX_STEP_MS = 400         -- spacing between ClientFX pushes (never two in one channel beat)
local P3_SPREAD = 250             -- arrivals nav-project within this of the gate
local P3_GATE_STAGGER_MS = 2000   -- offset between the gates' first spawns (one body per drain tick)
local P3_COAX_FAR_SQ = 4000 * 4000  -- a gate spawn farther than this from EVERY player gets coaxed...
local P3_COAX_NEAR = 1500           -- ...to a nav point within this of a random player


-- =======================================================================
-- Per-storm state
-- =======================================================================
local token = 0          -- bumped on every start/end/reset; pending steps compare against it
local dripSpawned = 0    -- this storm's drip count (MaxSpawns)
local dripAlive = {}     -- ActorKey -> npc: OUR drip spawns still standing (MaxAlive)
local bossToken = 0      -- boss-phase content lifecycle (independent of `token` - see above)
local bossAlive = {}     -- ActorKey -> npc: our boss-phase drip spawns still standing (MaxAlive)
local p3Alive = {}       -- ActorKey -> npc: phase-3 GATE spawns still standing (cap + coax + sweep)
local p3Spawned = 0      -- phase-3 gate spawns REQUESTED this phase (MaxTotal - claimed at request, not at arrival)
local p3FeudUntilTick = {}   -- ActorKey -> FAST_TICK the arrival's feud window ends (the coax leaves feuding bodies alone)
local p3KeysUp = nil     -- ClientFX keys currently held open (nil = no gates up) - the dedupe latch
local stormPlan = nil    -- { drip, planEndS }: this storm's script shape, read by SS.Pending
local SB                 -- ShadowBoss module, required lazily (it requires us first)

local function sb() SB = SB or require("ModuleShadow.ShadowBoss"); return SB end

local function live(tok) return STATE.ModEnabled and tok == token end

-- A nav point in [minR, maxR] around a random live player, or nil (no players).
local function nearRandomPlayer(minR, maxR)
    local p = Utils.RandomPlayer()
    if not p then return nil end
    local loc; pcall(function() loc = p:K2_GetActorLocation() end)
    if not loc then return nil end
    return Utils.GetSpawnPoint(loc, maxR, minR), loc
end

-- Nearest live NPC of `faction` around `npc` (excluding itself), or nil.
local function nearestOfFaction(npc, faction, radius)
    local loc; pcall(function() loc = npc:K2_GetActorLocation() end)
    if not loc then return nil end
    local best, bestSq
    for _, other in ipairs(AVU.GetNearbyNpcs(loc, radius, { faction = faction, ignoreActor = npc })) do
        if not Utils.IsDeadSafe(other) then
            local ol; pcall(function() ol = other:K2_GetActorLocation() end)
            local d = ol and Utils.DistSq(loc, ol)
            if d and (not bestSq or d < bestSq) then best, bestSq = other, d end
        end
    end
    return best
end

-- Lock a fresh arrival onto its first grudge (deferred: its controller isn't up on spawn).
local function pickOn(npc, faction, label)
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(npc) or Utils.IsDeadSafe(npc) then return end
        local target = nearestOfFaction(npc, faction, LOCK_SEARCH)
        if not target then return end
        AVU.LockAggro(npc, target, { HoldMs = LOCK_HOLD_MS })
        LogDebug("ShadowStorms - " .. label .. " picks on " .. tostring(Utils.GetActorName(target)), DBG)
    end, 1200)
end

-- Nearest BIG enemy (BIG_ENEMIES, matched by row or display name) around `npc`, any faction.
local function nearestBigEnemy(npc, radius)
    local loc; pcall(function() loc = npc:K2_GetActorLocation() end)
    if not loc then return nil end
    local best, bestSq
    for _, other in ipairs(AVU.GetNearbyNpcs(loc, radius, { ignoreActor = npc })) do
        if not Utils.IsDeadSafe(other)
            and (BIG_ENEMIES[Utils.GetActorRowName(other) or ""]
                 or BIG_ENEMIES[Utils.GetActorName(other) or ""]) then
            local ol; pcall(function() ol = other:K2_GetActorLocation() end)
            local d = ol and Utils.DistSq(loc, ol)
            if d and (not bestSq or d < bestSq) then best, bestSq = other, d end
        end
    end
    return best
end

-- Nearest live NPC of the FIRST faction in `factions` (an ordered priority list) that has one in
-- range - "the nearest Order body, else the nearest A2". Excludes `npc` itself.
local function nearestOfFactions(npc, factions, radius)
    for _, f in ipairs(factions) do
        local t = nearestOfFaction(npc, f, radius)
        if t then return t, f end
    end
    return nil
end

-- Faction-keyed first grudge for a fresh RIFT arrival: Order -> nearest GK; GK -> nearest Order
-- body else nearest A2; everything else -> nearest BIG enemy, or nothing.
-- GK<->ORDER is a FEUD, not a one-shot: LockAggro alone doesn't close distance without LoS, so
-- those two also get a MoveOrder and re-pick the nearest rival every FEUD_EVERY_MS for
-- FEUD_TOTAL_MS, then revert to the BT. `isLive` ties the feud's lifetime to its storm/phase token.
local FEUD_EVERY_MS = 6000
local FEUD_TOTAL_MS = 45000

local function feudStep(isLive, npc, theirFactions, label, untilTick)
    if not isLive() or Utils.IsActorInvalid(npc) or Utils.IsDeadSafe(npc) then return end
    if STATE.FAST_TICK > untilTick then return end
    local target = nearestOfFactions(npc, theirFactions, LOCK_SEARCH)
    if target then
        AVU.LockAggro(npc, target, { HoldMs = FEUD_EVERY_MS })
        -- Walk toward it: a nav point ~4m short of the target, so the pair actually meets.
        local tl; pcall(function() tl = target:K2_GetActorLocation() end)
        local dest = tl and Utils.GetSpawnPoint(tl, 500, 300)
        if dest then AVU.MoveOrder(npc, dest) end
    end
    Utils.QueueWork(function()
        feudStep(isLive, npc, theirFactions, label, untilTick)
    end, FEUD_EVERY_MS)
end

-- Rift arrivals (storms): the GK/Order feud for those two factions, one BIG-enemy grudge for
-- everyone else.
local RIFT_FEUD = {
    [FACTION_ORDER] = { FACTION_GK },
    [FACTION_GK]    = { FACTION_ORDER, FACTION_A2 },
}

local function pickFirstTarget(tok, npc, label)
    Utils.QueueWork(function()
        if not live(tok) or Utils.IsActorInvalid(npc) or Utils.IsDeadSafe(npc) then return end
        local f; pcall(function() f = tonumber(npc.Faction) end)
        local theirs = f and RIFT_FEUD[f]
        if theirs then
            LogDebug("ShadowStorms - " .. label .. " joins the GK/Order feud", DBG)
            feudStep(function() return live(tok) end, npc, theirs, label,
                STATE.FAST_TICK + FEUD_TOTAL_MS / 100)
            return
        end
        local target = nearestBigEnemy(npc, LOCK_SEARCH)
        if not target then return end
        AVU.LockAggro(npc, target, { HoldMs = LOCK_HOLD_MS })
        LogDebug("ShadowStorms - " .. label .. " picks on " .. tostring(Utils.GetActorName(target)), DBG)
    end, 1200)
end

-- PHASE-3 GATE ARRIVALS: a three-way feud. Each arrival hunts the nearest rival-faction body
-- (priority per faction below), re-picking and walking toward it for FEUD_TOTAL_MS - native
-- hostility exists but sight is a polled cone, so without this the camps never walk into range
-- of each other. Locks lapse on the target's death; after the window they're the BT's again.
-- Unlisted factions (faction-0 bruisers, player-faction oddities) get the BIG-enemy grudge or
-- nothing.
local P3_FEUD = {
    [FACTION_A2]    = { FACTION_GK, FACTION_ORDER },
    [FACTION_ORDER] = { FACTION_GK, FACTION_A2 },
    [FACTION_GK]    = { FACTION_ORDER, FACTION_A2 },
}

local function p3PickFight(tok, npc, label)
    Utils.QueueWork(function()
        if not STATE.ModEnabled or tok ~= bossToken then return end
        if Utils.IsActorInvalid(npc) or Utils.IsDeadSafe(npc) then return end
        local f; pcall(function() f = tonumber(npc.Faction) end)
        local theirs = f and P3_FEUD[f]
        if theirs then
            local untilTick = STATE.FAST_TICK + FEUD_TOTAL_MS / 100
            local key = Utils.ActorKey(npc)
            if key then p3FeudUntilTick[key] = untilTick end   -- the coax leaves it alone meanwhile
            LogDebug("ShadowStorms - " .. label .. " joins the phase-3 feud (faction " .. f .. ")", DBG)
            feudStep(function() return STATE.ModEnabled and tok == bossToken end, npc, theirs, label,
                untilTick)
            return
        end
        local target = nearestBigEnemy(npc, LOCK_SEARCH)
        if not target then return end
        AVU.LockAggro(npc, target, { HoldMs = LOCK_HOLD_MS })
        LogDebug("ShadowStorms - " .. label .. " picks on " .. tostring(Utils.GetActorName(target)), DBG)
    end, 1200)
end


-- =======================================================================
-- Drip
-- =======================================================================
local function dripAliveCount()
    local n = 0
    for key, npc in pairs(dripAlive) do
        if Utils.IsActorInvalid(npc) or Utils.IsDeadSafe(npc) then dripAlive[key] = nil else n = n + 1 end
    end
    return n
end

-- A nav point at a fixed gate (the gate Z is capsule-height; the projection grounds it).
local function gateSpot(gate)
    local loc = FVector(gate.X, gate.Y, gate.Z)
    return Utils.GetSpawnPoint(loc, P3_SPREAD) or loc
end

local function dripTick(tok, cfg)
    if not live(tok) then return end
    if dripSpawned >= (cfg.MaxSpawns or 0) then return end
    if not sb().StormActive() then return end

    if dripAliveCount() < (cfg.MaxAlive or 999) then
        local name = cfg.List[math.random(1, #cfg.List)]
        -- Gated drip: A2 bodies step out of a RANDOM EXOR gate and walk in - the storm coax
        -- delivers stragglers. Nonfaction bruisers keep materializing near a player.
        local spot
        if cfg.UseGates and not NONFACTION_NEAR_PLAYER[name] then
            spot = gateSpot(math.random(2) == 1 and SS.GATES.EXOR_A or SS.GATES.EXOR_B)
        else
            spot = nearRandomPlayer(DRIP_MIN, DRIP_MAX)
        end
        if spot then
            dripSpawned = dripSpawned + 1
            local n = dripSpawned
            require("AnteUtils.Spawning").SummonVariant(name, spot, {}, function(npc)
                if not live(tok) or Utils.IsActorInvalid(npc) then return end
                sb().Track(npc)
                local key = Utils.ActorKey(npc)
                if key then dripAlive[key] = npc end
                if cfg.LockGK and cfg.LockGK[name] then pickOn(npc, FACTION_GK, name) end
            end)
            LogDebug(string.format("ShadowStorms - drip %d/%d: %s", n, cfg.MaxSpawns or 0, name), DBG)
        end
    end
    Utils.QueueWork(function() dripTick(tok, cfg) end, (cfg.EverySeconds or 5) * 1000)
end


-- =======================================================================
-- Rifts
-- =======================================================================
local function openRift(tok, rift)
    if not live(tok) or not sb().StormActive() then return end
    local SP = require("AnteUtils.Spawning")

    local spot, yaw, noBurst
    local gate = rift.Gate and SS.GATES[rift.Gate]
    if gate then
        -- The held-open island gate IS the doorway - no drop of our own; the column just
        -- steps out of it. Arrivals land far from the fight; the coax delivers them.
        spot = gateSpot(gate)
        yaw = gate.Yaw or 0
        noBurst = gate.NoBurst
        Log(string.format("ShadowStorms - %s gate column inbound (%d arrivals)",
            tostring(rift.Gate), #rift.Spawns))
    else
        -- Roaming doorway 10-15m from a random player (Storm 1 style).
        local pLoc
        spot, pLoc = nearRandomPlayer(RIFT_MIN, RIFT_MAX)
        if not spot then return end
        yaw = 0
        pcall(function() yaw = Utils.RotatorToTarget(spot, pLoc).Yaw or 0 end)
        noBurst = rift.Order
        local openMs = (rift.OpenSeconds or 20) * 1000
        -- Yellow ring's ZOffset is dialled for capsule-centre sends; lift the DOORWAY send ~90 or
        -- it spawns buried. Arrivals keep the grounded spot.
        SP.PortalDrop(rift.Order and FVector(spot.X, spot.Y, spot.Z + 90) or spot, {
            OpenMs = openMs, EmergeMs = openMs + 1, Yaw = yaw,
            Key = rift.Order and "PORTAL_YELLOW" or nil,
            Drift = rift.Order and 0 or nil,
        })
        Log(string.format("ShadowStorms - %s rift open for %ds (%d arrivals)",
            rift.Order and "Order" or "GK", rift.OpenSeconds or 20, #rift.Spawns))
    end

    for _, e in ipairs(rift.Spawns) do
        Utils.QueueWork(function()
            if not live(tok) then return end
            local entry = e.Variant and { Variant = e.Variant } or { Npc = e.Npc }
            SP.PortalSummon(spot, { entry }, {
                Rift = false, EmergeMs = 0, Yaw = yaw, Spread = 150,
                EmergeFX = not noBurst,
                OnSpawned = function(npc)
                    if not live(tok) or Utils.IsActorInvalid(npc) then return end
                    sb().Track(npc)
                    pickFirstTarget(tok, npc, e.Variant or e.Npc)
                end,
            })
        end, (e.T or 0) * 1000)
    end
end


-- =======================================================================
-- Body sweep - remove every NPC corpse on the field, LOOT UNTOUCHED (dropped items are separate
-- actors; AVU.HideOnDeath hides now and destroys on a de-clumped schedule, which matters at this
-- scale - the D3D12 draw-UAF family). One-shot FindAllOf, never a tick.
--   * Skips the boss row: its death lifespan (2s / 50s cinematic) IS the phase transition.
-- =======================================================================
local function cleanBodies()
    local n = 0
    for _, npc in ipairs(FindAllOf(NPC_CLASS_SHORT) or {}) do
        if Utils.IsActorValid(npc) then
            local dead = false
            pcall(function() dead = npc.IsDead == true end)
            if dead and Utils.GetActorRowName(npc) ~= "Boss_Shadow" then
                AVU.HideOnDeath(npc)
                n = n + 1
            end
        end
    end
    if n > 0 then Log("ShadowStorms - swept " .. n .. " bodies (loot untouched)") end
end


-- =======================================================================
-- Boss-phase drip
-- =======================================================================
local function bossAliveCount()
    local n = 0
    for key, npc in pairs(bossAlive) do
        if Utils.IsActorInvalid(npc) or Utils.IsDeadSafe(npc) then bossAlive[key] = nil else n = n + 1 end
    end
    return n
end

local function bossDripTick(tok, phase, cfg)
    if not STATE.ModEnabled or tok ~= bossToken then return end
    local SBm = sb()
    if SBm.Phase() ~= phase or SBm.StormActive() then return end
    local boss = SBm.Boss()
    if not boss or Utils.IsDeadSafe(boss) then return end

    if bossAliveCount() < (cfg.MaxAlive or 999) then
        local e = cfg.List[math.random(1, #cfg.List)]
        local spot = nearRandomPlayer(BOSS_DRIP_MIN, BOSS_DRIP_MAX)
        if spot then
            local entry = e.Variant and { Variant = e.Variant } or { Npc = e.Npc }
            require("AnteUtils.Spawning").PortalSummon(spot, { entry }, {
                Rift = false, EmergeMs = 0,
                OnSpawned = function(npc)
                    if tok ~= bossToken or Utils.IsActorInvalid(npc) then return end
                    SBm.Track(npc)   -- a leftover gates the NEXT storm's all-dead end
                    local key = Utils.ActorKey(npc)
                    if key then bossAlive[key] = npc end
                end,
            })
            LogDebug("ShadowStorms - boss-phase drip: " .. tostring(e.Variant or e.Npc), DBG)
        end
    end
    Utils.QueueWork(function() bossDripTick(tok, phase, cfg) end, (cfg.EverySeconds or 10) * 1000)
end


-- =======================================================================
-- Phase-3 arena gates - fixed held-open portals, each cycling its Spawns list in order.
-- FX lifecycle: ONE SendClientFX per gate with a fight-length lifetime; FX.StopClientFX at the
-- phase's end (event-driven - no removal poll at all; the lifetime is only the backstop for a
-- machine that misses the stop). p3KeysUp is the dedupe latch: gates already up = don't re-send.
-- =======================================================================
local function p3AliveCount()
    local n = 0
    for key, npc in pairs(p3Alive) do
        if Utils.IsActorInvalid(npc) or Utils.IsDeadSafe(npc) then p3Alive[key] = nil else n = n + 1 end
    end
    return n
end

-- Stop every held gate key (deduped - A and B share the redverse entry). Also the defensive
-- pre-open clear: StopClientFX keys off the entry's NIAGARA, so a stray copy from a bad restart
-- dies before we open the real set.
local function stopGates(keys)
    local seen = {}
    for i, key in ipairs(keys or {}) do
        if not seen[key] then
            seen[key] = true
            Utils.QueueWork(function() pcall(function() AVU.StopClientFX(key) end) end, i * P3_FX_STEP_MS)
        end
    end
end

-- Open ALL of SS.GATES (defensive stop first - the "already exists" corner case - then one
-- paced send per gate) and latch p3KeysUp. Called at Storm 2 start (OpenGates) or, if that
-- never ran (a start-at-phase-3 test), from BossStart; the latch makes the second call a no-op.
local function openAllGates()
    local keys, gates = {}, {}
    for _, g in pairs(SS.GATES) do
        keys[#keys + 1] = g.Key
        gates[#gates + 1] = g
    end
    stopGates(keys)
    local sendAt = (#keys + 2) * P3_FX_STEP_MS
    for i, g in ipairs(gates) do
        Utils.QueueWork(function()
            if not STATE.ModEnabled then return end
            AVU.SendClientFX(FVector(g.X, g.Y, g.Z), g.Key, P3_PORTAL_LIFE_S, g.Yaw, 0)
        end, sendAt + i * P3_FX_STEP_MS)
    end
    p3KeysUp = keys
    Log("ShadowStorms - island gates opened (" .. #gates .. ")")
end

-- ONE loop PER GATE, running in parallel: every EverySeconds (the gate's own, else
-- PortalEverySeconds) it spawns the next body of ITS list, wrapping. The shared MaxAlive cap
-- pauses every gate (cursor holds, advances only on a spawn); MaxTotal is claimed AT REQUEST
-- (a summon is invisible to a scan for a couple ticks, so counting arrivals would overshoot).
-- Each arrival joins the phase-3 feud (p3PickFight). Starts are staggered by BossStart.
local function gateLoop(tok, phase, pi, cur)
    if not STATE.ModEnabled or tok ~= bossToken then return end
    local SBm = sb()
    if SBm.Phase() ~= phase or SBm.StormActive() then return end
    local boss = SBm.Boss()
    if not boss or Utils.IsDeadSafe(boss) then return end

    local script = SS.BOSS_PHASES[phase]
    local portal = script and script.Portals and script.Portals[pi]
    local gate = portal and SS.GATES[portal.Gate]
    if not portal or not gate or #(portal.Spawns or {}) == 0 then return end
    local everyS = portal.EverySeconds or script.PortalEverySeconds or 10

    if script.MaxTotal and p3Spawned >= script.MaxTotal then
        LogDebug("ShadowStorms - gate " .. tostring(portal.Gate) .. " done (MaxTotal " .. script.MaxTotal .. " reached)", DBG)
        return
    end

    if p3AliveCount() < (script.MaxAlive or 999) then
        local e = portal.Spawns[cur]
        cur = cur % #portal.Spawns + 1   -- advance ONLY on a spawn
        p3Spawned = p3Spawned + 1
        local label = e.Variant or e.Npc
        local spot = gateSpot(gate)
        local entry = e.Variant and { Variant = e.Variant } or { Npc = e.Npc }
        require("AnteUtils.Spawning").PortalSummon(spot, { entry }, {
            Rift = false, EmergeMs = 0, Yaw = gate.Yaw,
            EmergeFX = not gate.NoBurst,
            OnSpawned = function(npc)
                if tok ~= bossToken or Utils.IsActorInvalid(npc) then return end
                SBm.Track(npc)
                local key = Utils.ActorKey(npc)
                if key then p3Alive[key] = npc end
                p3PickFight(tok, npc, label)
            end,
        })
        LogDebug("ShadowStorms - gate spawn (" .. tostring(portal.Gate) .. ", " .. p3Spawned
            .. "/" .. tostring(script.MaxTotal or "-") .. "): " .. tostring(label), DBG)
    end
    Utils.QueueWork(function() gateLoop(tok, phase, pi, cur) end, everyS * 1000)
end

-- Every CoaxSeconds: gate spawns far from every player walk toward a random one. Wander-toward,
-- not aggro - they pick their own fights on arrival.
-- DELIBERATELY no teleport escalation here (unlike the storm coax): a straggler that can't path
-- just stays lost, since phase 3 has no clock to hold hostage. If bodies pile up AT a gate, that
-- spot isn't nav-connected to the arena - move the gate coords.
local function p3CoaxLoop(tok, phase, everyS)
    if not STATE.ModEnabled or tok ~= bossToken then return end
    local SBm = sb()
    if SBm.Phase() == phase and not SBm.StormActive() then
        local players = Utils.LivePlayers()
        local nudged = 0
        for key, npc in pairs(p3Alive) do
            -- A body still in its feud window is walking toward a rival - don't yank it toward a
            -- player (the feud MoveOrder every 6s would just fight this one every 15s).
            local feuding = p3FeudUntilTick[key] and STATE.FAST_TICK <= p3FeudUntilTick[key]
            if not feuding and Utils.IsActorValid(npc) and not Utils.IsDeadSafe(npc) and #players > 0 then
                local loc; pcall(function() loc = npc:K2_GetActorLocation() end)
                if loc then
                    local farFromAll = true
                    for _, p in ipairs(players) do
                        local pl; pcall(function() pl = p:K2_GetActorLocation() end)
                        if pl and Utils.DistSq(loc, pl) < P3_COAX_FAR_SQ then farFromAll = false break end
                    end
                    if farFromAll then
                        local t = players[math.random(1, #players)]
                        local tl; pcall(function() tl = t:K2_GetActorLocation() end)
                        local dest = tl and Utils.GetSpawnPoint(tl, P3_COAX_NEAR)
                        if dest and AVU.MoveOrder(npc, dest) then nudged = nudged + 1 end
                    end
                end
            end
        end
        if nudged > 0 then LogDebug("ShadowStorms - gate coax: nudged " .. nudged, DBG) end
    end
    Utils.QueueWork(function() p3CoaxLoop(tok, phase, everyS) end, everyS * 1000)
end

-- VICTORY: the boss is dead - dismiss every leftover we own, each with the blue portal burst
-- (sound on the first few only; two dozen stacked cues is a wall of noise). Staggered destroys -
-- the D3D12 teardown family hates a same-frame batch.
local function p3VictorySweep()
    local doomed = {}
    for _, tbl in ipairs({ p3Alive, bossAlive }) do
        for key, npc in pairs(tbl) do
            if Utils.IsActorValid(npc) and not Utils.IsDeadSafe(npc) then doomed[#doomed + 1] = npc end
            tbl[key] = nil
        end
    end
    if #doomed == 0 then return end
    Log("ShadowStorms - victory: dismissing " .. #doomed .. " leftover enemies")
    ASSETS.LoadAsync({ ENUMS.Effects.PORTAL_BURST_ONCE }, function()
        for i, npc in ipairs(doomed) do
            Utils.QueueWork(function()
                if Utils.IsActorInvalid(npc) then return end
                pcall(function() AVU.SpawnPortalFX(npc, { NoSound = i > 3 }) end)
                pcall(function() npc:K2_DestroyActor() end)
            end, 500 + i * 200)
        end
    end)
end


-- =======================================================================
-- Seams (assigned onto ShadowBoss at load)
-- =======================================================================
function SS.Start(phase)
    token = token + 1
    local tok = token
    dripSpawned, dripAlive = 0, {}

    local script = SS.STORMS[phase]
    if not script then
        LogDebug("ShadowStorms - no script for Storm " .. tostring(phase), DBG)
        return
    end
    Log("ShadowStorms - Storm " .. phase .. " content armed")

    -- The script's shape, for SS.Pending: the last scheduled rift moment (+ a settle beat).
    local planEndS = 0
    for _, rift in ipairs(script.Rifts or {}) do
        local lastT = 0
        for _, e in ipairs(rift.Spawns or {}) do lastT = math.max(lastT, e.T or 0) end
        planEndS = math.max(planEndS, (rift.At or 0) + lastT + 3)
    end
    stormPlan = { drip = script.Drip, planEndS = planEndS }

    if script.CleanBodies then
        Utils.QueueWork(function()
            if tok == token and STATE.ModEnabled then cleanBodies() end
        end, CLEAN_DELAY_MS)
    end
    if script.OpenGates and not p3KeysUp then
        openAllGates()   -- they stay up through phase 3; BossStart's open is then a no-op
    end
    if script.Drip then
        Utils.QueueWork(function() dripTick(tok, script.Drip) end, (script.Drip.EverySeconds or 5) * 1000)
    end
    for _, rift in ipairs(script.Rifts or {}) do
        Utils.QueueWork(function() openRift(tok, rift) end, (rift.At or 0) * 1000)
    end
end

function SS.Stop()
    token = token + 1
    dripSpawned, dripAlive = 0, {}
    stormPlan = nil
end

-- True while this storm's SCRIPT still has work in flight: drip spawns remaining, or a rift
-- whose schedule (open time + last arrival) hasn't passed. The clock's all-dead end consults
-- this so a slaughter-pace fight can't cut the authored content short.
function SS.Pending(elapsedS)
    if not stormPlan then return false end
    local d = stormPlan.drip
    if d and (d.MaxSpawns or 0) > 0 and dripSpawned < d.MaxSpawns then return true end
    return elapsedS < stormPlan.planEndS
end

-- Boss-phase content lifecycle (own token - see the BOSS_PHASES banner).
function SS.BossStart(phase)
    bossToken = bossToken + 1
    local tok = bossToken
    bossAlive = {}
    p3Alive = {}
    p3Spawned = 0
    p3FeudUntilTick = {}

    local script = SS.BOSS_PHASES[phase]
    if not script then return end
    Log("ShadowStorms - BossPhase " .. phase .. " content armed")

    if script.Drip then
        Utils.QueueWork(function() bossDripTick(tok, phase, script.Drip) end,
            (script.Drip.EverySeconds or 10) * 1000)
    end

    if script.Portals and #script.Portals > 0 then
        -- The gates are usually already up (Storm 2's OpenGates); the latch makes this a no-op
        -- then. Cycles + coax start either way.
        if not p3KeysUp then openAllGates() end
        -- One independent loop per gate, first spawns staggered P3_GATE_STAGGER_MS apart so the
        -- opening wave (and every wrap-around when cadences align) isn't four spawns in one tick.
        for pi = 1, #script.Portals do
            local firstS = script.Portals[pi].EverySeconds or script.PortalEverySeconds or 10
            Utils.QueueWork(function() gateLoop(tok, phase, pi, 1) end,
                firstS * 1000 + (pi - 1) * P3_GATE_STAGGER_MS)
        end
        if (script.CoaxSeconds or 0) > 0 then
            Utils.QueueWork(function() p3CoaxLoop(tok, phase, script.CoaxSeconds) end,
                script.CoaxSeconds * 1000)
        end
        Log("ShadowStorms - " .. #script.Portals .. " gate cycles armed (phase " .. phase .. ")")
    end
end

-- reason: "bossdeath" (+ the phase it died in), "storm", or "reset" (world teardown).
function SS.BossStop(reason, phase)
    bossToken = bossToken + 1
    if reason == "bossdeath" and (tonumber(phase) or 0) >= 3 then
        p3VictorySweep()   -- reads + clears the alive books
    end
    bossAlive = {}
    p3Alive = {}
    p3Spawned = 0
    p3FeudUntilTick = {}
    if p3KeysUp then
        -- Close the gates. On a world reset the renderers' books are torn down anyway - don't
        -- push opcodes at a dying world.
        if reason ~= "reset" then stopGates(p3KeysUp) end
        p3KeysUp = nil
    end
end

-- Wire the seams. ShadowBoss requires us from SB.Register (after it has fully loaded), so this
-- require just returns the loaded module - no cycle. Runtime callers still go through sb().
local SBmod = require("ModuleShadow.ShadowBoss")
SBmod.OnStormContent = SS.Start
SBmod.OnStormEnd = SS.Stop
SBmod.OnStormReset = SS.Stop
SBmod.OnStormContentPending = SS.Pending
SBmod.OnBossContent = SS.BossStart
SBmod.OnBossContentEnd = SS.BossStop

return SS
