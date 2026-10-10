-- =======================================================================
-- ModuleDirector/Director [AUTHORITY] - a light director. Every so often a player who is out in
-- the world (away from any bench, in the right sector, at the right story beat) gets a small pack
-- spawned OUT OF THEIR SIGHT and pointed at them: wandering, walking over to look, or hunting.
-- What may fire and when is the roster in DirectorRules.lua; this file only evaluates rows.
--
--   * ONE loop walks every player, each carrying its own staggered deadline - so a lobby never
--     gets its packs in lockstep, and there is never one WorkQueue chain per player.
--   * A check is arithmetic: story is a cached number, the sector a polygon test, night a property
--     read, the bench test a walk over cached coordinates. The only engine work is the spawn
--     search, which SpawnReinforcements spreads one candidate per pass.
--   * Benches come from AnteCore/BenchCache, shared with the Sleep Shade: plain coordinates, so
--     "is this a base" is a walk over a small array, never an overlap.
--   * Every body is a SpawnReinforcements orphan (self-cleans once no player is near), so a rule
--     that keeps firing while players roam can't leak bodies.
--   * DEBUG_DIRECTOR echoes the decisions into the host's chat (log-only on a dedicated server).
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local BENCHES = require("AnteCore.BenchCache")
local HM = require("ModuleHardMode.HardMode")
local RULES = require("ModuleDirector.DirectorRules")

local Log = Utils.Log
local LogBad = Utils.LogBad

local DIR = {}

local CFG = {
    TickMs             = 2000,  -- loop cadence; each player's own deadline gates the real check
    LockDelayMs        = 500,   -- a fresh body has no controller; an immediate order is a silent no-op
    InvestigateDelayMs = 1000,
    RecallGraceMult    = 2,     -- a Stalk pack still in view at EngageSecs is pulled anyway after this many
    RecallKeepMetres   = 15,    -- ...but never while this close to its player
    CrossfireRing      = { 3, 12 },   -- the search ring around each offset origin
}

-- Per-world runtime, all reset in Register.
local playerState = {}      -- Utils.ActorKey(player) -> { Name, NextCheckMs, QuietUntilMs,
                            --   Cooldowns = {ruleId -> untilMs}, Noted = {ruleId -> true}, StalkLeft = {ruleId -> n},
                            --   SectorSince = {sector -> msEntered}, Cycle = {ruleId -> behaviour index},
                            --   NightFired = {ruleId -> nightEpoch} }
local packs = {}            -- array of { Rule, PlayerKey, PlayerName, Behaviour, Bodies = {actorKey -> npc},
                            --   SpawnedMs, Pending, Failed, Engaged, Stalk, Announced }

-- Which night it is, as a plain counter bumped on each day -> night flip. `OncePerNight` keys off
-- this rather than the in-game day number, which rolls over at midnight and would split one night
-- into two. A server that starts mid-night counts that as a night, so it still gets its firing.
local nightEpoch, wasNight = 0, nil
local nightFiredWorld = {}  -- ruleId -> nightEpoch, for OncePerNight = "world" (not per player)


-- The log line always (under DEBUG_DIRECTOR), plus a chat echo where there is a local player.
-- DisplayTextChatMessage is a widget print, so it rides QueueWork and is safe from any call site.
local function say(msg)
    if not SETTINGS.DEBUG_DIRECTOR then return end
    Log("Director - " .. msg)
    if not Utils.HasRenderer() then return end
    Utils.QueueWork(function()
        pcall(function() require("AFUtils.AFUtils").DisplayTextChatMessage("[Director] " .. msg) end)
    end, 0)
end

local function knob(rule, name)
    local v = rule[name]
    if v == nil then v = RULES.DEFAULTS[name] end
    return v
end

local function actorLoc(actor)
    local loc
    pcall(function() loc = actor:K2_GetActorLocation() end)
    return loc
end

local function nameOf(player)
    local n
    pcall(function()
        local ps = player.MyPlayerState
        if IsValid(ps) then n = ps:GetPlayerName():ToString() end
    end)
    return n or "player"
end

local function findPlayer(key)
    for _, p in ipairs(Utils.LivePlayers()) do
        if Utils.ActorKey(p) == key then return p end
    end
    return nil
end

local function metres(a, b)
    return math.floor(math.sqrt(Utils.DistSq(a, b)) / 100 + 0.5)
end


-- =======================================================================
-- BENCHES
-- =======================================================================

-- The base-footprint test, for the player and for every spawn candidate (AnteCore/BenchCache).
local function nearAnyBench(loc, clearMetres)
    return BENCHES.NearAny(loc, clearMetres or RULES.DEFAULTS.BenchClearMetres,
        RULES.DEFAULTS.BenchClearZMetres)
end


-- =======================================================================
-- CONDITIONS
-- =======================================================================

-- nil when the clock isn't up yet; a rule with a Night condition then can't fire.
local function isNight()
    local mgr = Utils.GetDayNightManager()
    if not mgr then return nil end
    local ok, n = pcall(function() return mgr.IsNight end)
    if not ok then return nil end
    return n == true
end

local function inCombat(npc)
    local fighting = false
    pcall(function()
        local c = npc.NPC_Controller
        if IsNotValid(c) then c = npc:GetController() end
        if IsValid(c) and c.IsInCombat == true then fighting = true end
    end)
    return fighting
end

-- Drops dead / gone bodies as it counts. A pack whose search is still running counts as alive.
local function packAlive(pack)
    if pack.Pending then return true end
    for key, npc in pairs(pack.Bodies) do
        if Utils.IsActorInvalid(npc) or Utils.IsDeadSafe(npc) then pack.Bodies[key] = nil end
    end
    return next(pack.Bodies) ~= nil
end

local function countActive(ruleId, playerKey)
    local n = 0
    for _, pack in ipairs(packs) do
        if pack.Rule.Id == ruleId and pack.PlayerKey == playerKey and packAlive(pack) then n = n + 1 end
    end
    return n
end

-- A night is only ~270 real seconds against a ~30 minute day, so the DEFAULT cooldown is shorter
-- at night. A row that names its own CooldownSecs means that number whatever the clock says.
local function cooldownSecs(rule, ctx)
    if rule.CooldownSecs then return rule.CooldownSecs end
    local D = RULES.DEFAULTS
    return (ctx.night == true and D.CooldownSecsNight) or D.CooldownSecs
end

-- A row's Behaviour is one name, or a CYCLE that advances per firing: { "Hunt", "Investigate" }
-- on a 3-minute cooldown is each of them every 6 minutes, landing 3 minutes apart.
local function pickBehaviour(rule, rec)
    local b = rule.Behaviour
    if type(b) ~= "table" then return b or "Wander" end
    local i = (rec.Cycle[rule.Id] or 0) % #b + 1
    rec.Cycle[rule.Id] = i
    return b[i] or "Wander"
end

-- Seconds left of the sector's settle-in grace, or nil. Walking into a zone shouldn't be an ambush,
-- and the arrival itself is usually a streaming hitch - so a sector rule holds off for a bit.
local function settlingSecs(rule, rec, ctx)
    if not rule.Sector then return nil end
    local area = RULES.SECTORS[rule.Sector]
    local grace = ((area and area.GraceSecs) or RULES.DEFAULTS.SectorGraceSecs) * 1000
    local left = (rec.SectorSince[rule.Sector] or ctx.now) + grace - ctx.now
    return (left > 0) and math.ceil(left / 1000) or nil
end

-- nil = may fire, else why not. Cheapest first; the bench walk is the caller's, once per player.
local function blockedBy(rule, rec, ctx)
    local band = rule.Story
    if band and (ctx.story < band[1] or ctx.story >= band[2]) then return "story" end
    if rule.Night ~= nil and rule.Night ~= ctx.night then return "clock" end
    if rule.Hard ~= nil and rule.Hard ~= ctx.hard then return "hard" end
    -- checkPlayer stamped the sectors the player stands in, so this is a table read.
    if rule.Sector and not rec.SectorSince[rule.Sector] then return "sector" end
    local once = rule.OncePerNight
    if once == "world" then
        if nightFiredWorld[rule.Id] == ctx.nightEpoch then return "tonight" end
    elseif once and rec.NightFired[rule.Id] == ctx.nightEpoch then return "tonight" end
    local untilMs = rec.Cooldowns[rule.Id]
    if untilMs and ctx.now < untilMs then return "cooldown" end
    if countActive(rule.Id, ctx.key) >= (rule.MaxActive or 1) then return "active" end
    return nil
end


-- =======================================================================
-- SPAWNING
-- =======================================================================

-- SpawnReinforcements rolls uniformly from its Npcs array, so a weight is that many copies.
local function rosterOf(spawns)
    local r = {}
    for _, e in ipairs(spawns or {}) do
        for _ = 1, math.max(1, math.floor(e[2] or 1)) do r[#r + 1] = e[1] end
    end
    return r
end

local function announce(pack, npc)
    if pack.Announced then return end
    pack.Announced = true
    local player = findPlayer(pack.PlayerKey)
    local ploc, nloc = player and actorLoc(player), actorLoc(npc)
    local dist = (ploc and nloc) and (metres(ploc, nloc) .. "m away") or "?m"
    say(("%s: SPAWN %s -> %s x%d, %s (%s)"):format(pack.PlayerName, pack.Rule.Id,
        tostring(Utils.GetActorRowName(npc)), pack.Total or 1, dist, pack.Behaviour))
end

-- One search + wave for a pack. `group` is what to put on this bearing ({ Roster, Count }); a
-- Crossfire row has one per bearing, everything else has the single group built in `fire`.
-- `onSpawned` is the behaviour's per-body wiring.
local function spawnPack(pack, player, origin, ring, group, target, holdMs, onSpawned)
    local rule = pack.Rule
    AVU.SpawnReinforcements({
        Npcs = group.Roster, Origin = origin, Count = group.Count,
        MinDist = ring[1] * 100, MaxDist = ring[2] * 100,
        OutOfSight = player,
        -- Every pack lands out of sight, so the native spawn-in burst has nobody to sell it to -
        -- it only announces the pack to whoever wanders past a second later. `SpawnFX = true` on a
        -- rule buys it back; nil rather than false, so a variant's own def.SkipSpawnFX still holds.
        SkipSpawnFX = (not knob(rule, "SpawnFX")) or nil,
        Reject = function(pt) return nearAnyBench(pt, knob(rule, "BenchClearMetres")) end,
        Target = target, HoldMs = holdMs, LockDelayMs = CFG.LockDelayMs,
        Track = pack.Bodies,
        Label = "Director:" .. rule.Id,
        OnSpawned = function(npc)
            pack.Pending = false
            announce(pack, npc)
            if onSpawned then onSpawned(npc) end
        end,
        OnFail = function()
            pack.Pending = false
            pack.Failed = true
            -- Not a cooldown consumed: the next check simply tries again.
            local rec = playerState[pack.PlayerKey]
            if rec then rec.Cooldowns[rule.Id] = nil end
            say(pack.PlayerName .. ": " .. rule.Id .. " found no spot out of sight - will retry")
        end,
    })
end

local function fire(rule, player, rec, ctx)
    -- The cooldown and the night latch are SPENT whether or not Chance lands, so Chance reads as
    -- "this fraction of the openings happen" rather than "re-roll every check until it passes".
    local cd = cooldownSecs(rule, ctx)
    rec.Cooldowns[rule.Id] = ctx.now + math.random(cd[1], cd[2]) * 1000
    rec.Noted[rule.Id] = nil
    if rule.OncePerNight == "world" then nightFiredWorld[rule.Id] = ctx.nightEpoch
    elseif rule.OncePerNight then rec.NightFired[rule.Id] = ctx.nightEpoch end

    if rule.Chance and math.random() > rule.Chance then
        say(("%s: %s rolled off (Chance %g)"):format(rec.Name, rule.Id, rule.Chance))
        return
    end

    local total = 0
    for _, g in ipairs(rule._Groups) do total = total + g.Count end
    local behaviour = pickBehaviour(rule, rec)
    local pack = { Rule = rule, PlayerKey = ctx.key, PlayerName = rec.Name, Behaviour = behaviour,
                   Bodies = {}, SpawnedMs = ctx.now, Pending = true, Engaged = false, Total = total }
    packs[#packs + 1] = pack
    rec.QuietUntilMs = ctx.now + knob(rule, "PlayerQuietSecs") * 1000

    -- Where the player WAS at the check - a plain copy, since the orders below fire ticks later.
    local anchor = { X = ctx.loc.X, Y = ctx.loc.Y, Z = ctx.loc.Z }
    local ring = knob(rule, "SpawnRingMetres")
    local solo = rule._Groups[1]

    if behaviour == "Investigate" then
        spawnPack(pack, player, ctx.loc, ring, solo, nil, nil, function(npc)
            Utils.QueueWork(function()
                if Utils.IsActorValid(npc) then AVU.SetPointOfInterest(npc, FVector(anchor.X, anchor.Y, anchor.Z)) end
            end, CFG.InvestigateDelayMs)
        end)
    elseif behaviour == "Hunt" then
        spawnPack(pack, player, ctx.loc, ring, solo, player, nil)
    elseif behaviour == "Stalk" then
        pack.Stalk = true
        spawnPack(pack, player, ctx.loc, ring, solo, player, knob(rule, "EngageSecs") * 1000)
    elseif behaviour == "Crossfire" then
        local groups = rule._Groups
        local base = math.random() * 2 * math.pi
        local reach = ring[2] * 100
        for i, group in ipairs(groups) do
            local a = base + (i - 1) * (2 * math.pi / #groups)
            local origin = FVector(ctx.loc.X + math.cos(a) * reach, ctx.loc.Y + math.sin(a) * reach, ctx.loc.Z)
            spawnPack(pack, player, origin, CFG.CrossfireRing, group, nil, nil, function(npc)
                Utils.QueueWork(function()
                    if Utils.IsActorValid(npc) then AVU.AttackMove({ npc }, FVector(anchor.X, anchor.Y, anchor.Z)) end
                end, CFG.LockDelayMs)
            end)
        end
    else
        spawnPack(pack, player, ctx.loc, ring, solo, nil, nil)
    end
end


-- =======================================================================
-- STALK RECALL - a pack that never engaged is pulled out of sight and the rule re-armed.
-- =======================================================================

-- Never pull a body the player can see: that's the one tell worse than leaving it.
local function canPull(npc, player, pack, now)
    if not player then return true end
    local engage = knob(pack.Rule, "EngageSecs") * 1000
    if now - pack.SpawnedMs >= engage * CFG.RecallGraceMult then return true end
    local ploc, nloc = actorLoc(player), actorLoc(npc)
    if not ploc or not nloc then return true end
    if Utils.DistSq(ploc, nloc) < (CFG.RecallKeepMetres * 100) ^ 2 then return false end
    -- IsPathBlocked fails OPEN (false = "visible"), which is the safe direction here: keep it.
    return AVU.IsPathBlocked(player, FVector(ploc.X, ploc.Y, ploc.Z + 70),
        FVector(nloc.X, nloc.Y, nloc.Z + 60), { player, npc }, 3) == true
end

local function recallPack(pack, now)
    local player = findPlayer(pack.PlayerKey)
    local pulled, kept = 0, 0
    for key, npc in pairs(pack.Bodies) do
        if canPull(npc, player, pack, now) then
            pcall(function() npc:K2_DestroyActor() end)
            pack.Bodies[key] = nil
            pulled = pulled + 1
        else
            kept = kept + 1
        end
    end
    if kept > 0 then return end   -- try again next tick

    local rule = pack.Rule
    local rec = playerState[pack.PlayerKey]
    if not rec then return end
    local left = rec.StalkLeft[rule.Id]
    if left == nil then left = knob(rule, "Retries") end
    if left > 0 then
        rec.StalkLeft[rule.Id] = left - 1
        rec.Cooldowns[rule.Id] = nil   -- re-armed: the next check re-fires (sector / bench / quiet still apply)
        say(("%s: %s never engaged - recalled %d, re-armed (%d left)"):format(rec.Name, rule.Id, pulled, left - 1))
    else
        rec.StalkLeft[rule.Id] = nil   -- retries spent; the normal cooldown stands
        say(("%s: %s never engaged - recalled %d, retries spent"):format(rec.Name, rule.Id, pulled))
    end
end

local function prunePacks(now)
    for i = #packs, 1, -1 do
        local pack = packs[i]
        if not packAlive(pack) then
            table.remove(packs, i)
        elseif pack.Stalk and not pack.Engaged and not pack.Pending then
            for _, npc in pairs(pack.Bodies) do
                if inCombat(npc) then pack.Engaged = true; break end
            end
            if pack.Engaged then
                local rec = playerState[pack.PlayerKey]
                if rec then rec.StalkLeft[pack.Rule.Id] = nil end   -- a fresh retry budget next cycle
                say(pack.PlayerName .. ": " .. pack.Rule.Id .. " engaged")
            elseif now - pack.SpawnedMs >= knob(pack.Rule, "EngageSecs") * 1000 then
                recallPack(pack, now)
            end
        end
    end
end


-- =======================================================================
-- THE CHECK
-- =======================================================================

local function checkPlayer(player, rec, ctx)
    if Utils.IsDeadSafe(player) then return end
    ctx.loc = actorLoc(player)
    if not ctx.loc then return end

    -- Which sectors hold the player, and since when: ONE polygon test per sector per check rather
    -- than one per rule, and the arrival stamp settlingSecs measures from. Sectors may overlap, so
    -- each is tracked on its own instead of picking "the" sector the player is in.
    for name, area in pairs(RULES.SECTORS) do
        if Utils.LocInArea(ctx.loc, area) then
            rec.SectorSince[name] = rec.SectorSince[name] or ctx.now
        else
            rec.SectorSince[name] = nil
        end
    end

    local eligible = {}
    for _, rule in ipairs(RULES.RULES) do
        if blockedBy(rule, rec, ctx) then
            rec.Noted[rule.Id] = nil     -- a fresh "eligible" line once it comes back
        else
            eligible[#eligible + 1] = rule
        end
    end
    if #eligible == 0 then return end

    local quiet = ctx.now < (rec.QuietUntilMs or 0)
    local clock = (ctx.night == true) and "night" or (ctx.night == false) and "day" or "no clock"
    local ready = {}
    for _, rule in ipairs(eligible) do
        local settle = settlingSecs(rule, rec, ctx)
        local wait = quiet and "quiet" or (settle and ("settling " .. settle .. "s"))
            or (nearAnyBench(ctx.loc, knob(rule, "BenchClearMetres")) and "at base") or nil
        if not rec.Noted[rule.Id] then
            rec.Noted[rule.Id] = true
            say(("%s: %s eligible%s (%s, story %d, %d/%d active)"):format(rec.Name, rule.Id,
                wait and (" - waiting: " .. wait) or "", clock, ctx.story,
                countActive(rule.Id, ctx.key), rule.MaxActive or 1))
        end
        if not wait then ready[#ready + 1] = rule end
    end
    if #ready == 0 then return end
    fire(ready[math.random(#ready)], player, rec, ctx)
end

function DIR.Tick()
    if not STATE.ModEnabled then return end
    local now = Utils.NowMs()
    prunePacks(now)

    local story, night, hard = STATE.StoryProgress or 0, isNight(), HM.On("NoEnd")
    if night ~= nil then
        if night and not wasNight then nightEpoch = nightEpoch + 1 end
        wasNight = night
    end
    local seen = {}
    for _, p in ipairs(Utils.LivePlayers()) do
        local key = Utils.ActorKey(p)
        if key then
            seen[key] = true
            local rec = playerState[key]
            if not rec then
                rec = { Name = nameOf(p), QuietUntilMs = 0, Cooldowns = {}, Noted = {}, StalkLeft = {},
                        SectorSince = {}, Cycle = {}, NightFired = {},
                        NextCheckMs = now + math.random(0, RULES.DEFAULTS.CheckEverySecs * 1000) }
                playerState[key] = rec
            end
            if now >= rec.NextCheckMs then
                rec.NextCheckMs = now + RULES.DEFAULTS.CheckEverySecs * 1000
                checkPlayer(p, rec, { now = now, story = story, night = night, hard = hard, key = key,
                                      nightEpoch = nightEpoch })
            end
        end
    end
    for key in pairs(playerState) do
        if not seen[key] then playerState[key] = nil end
    end
end


-- =======================================================================
-- REGISTER
-- =======================================================================

-- Every row is flattened to `_Groups` - one entry per spawn wave, so `fire` never branches on
-- whether the author wrote a plain Spawns list or per-bearing Crossfire Groups.
-- Every field a row may carry. An unknown one is a TYPO that would otherwise pass silently: an
-- unknown key reads nil, so a misspelled Story simply drops that row's story gate.
local ROW_FIELDS = {
    Id = true, Story = true, Sector = true, Night = true, Hard = true, Behaviour = true,
    Spawns = true, Count = true, MaxActive = true, Groups = true, Packs = true,
    CooldownSecs = true, OncePerNight = true, Chance = true,
    -- DEFAULTS a row may override (knob())
    SpawnFX = true, BenchClearMetres = true, PlayerQuietSecs = true, SpawnRingMetres = true,
    EngageSecs = true, Retries = true,
    _Groups = true,   -- written below, and RULES survives into the next world
}

local function validateRules()
    local VARIANTS = require("AnteVariants.Variants")
    local seen = {}
    for _, rule in ipairs(RULES.RULES) do
        for field in pairs(rule) do
            if not ROW_FIELDS[field] then
                LogBad(("Director - rule %s: unknown field '%s' (typo? it would read as nil)")
                    :format(tostring(rule.Id), tostring(field)))
            end
        end
        if not rule.Story then
            LogBad(("Director - rule %s: no Story band - it can fire at ANY story progress"):format(tostring(rule.Id)))
        end
        -- Per-player state (cooldown, MaxActive budget, night latch) is keyed by Id, so two rows
        -- sharing one are the same rule to the engine. Deliberate where the story bands can't both
        -- be live (the Labs pairs); a real clash where they can.
        local band = rule.Story or { 0, 999 }
        for _, other in ipairs(seen[rule.Id] or {}) do
            if band[1] < other[2] and other[1] < band[2] then
                LogBad(("Director - rule %s: a second row shares this Id over an overlapping story "
                     .. "band, so they share one cooldown and MaxActive budget"):format(tostring(rule.Id)))
            end
        end
        seen[rule.Id] = seen[rule.Id] or {}
        table.insert(seen[rule.Id], band)
        local function build(spawns, count)
            for _, e in ipairs(spawns or {}) do
                if not VARIANTS[e[1]] and not ENUMS.NpcClasses[e[1]] then
                    LogBad(("Director - rule %s: unknown spawn '%s' (not a variant or an NpcClasses row)"):format(rule.Id, tostring(e[1])))
                end
            end
            return { Roster = rosterOf(spawns), Count = count or 1 }
        end

        -- Crossfire shapes _Groups per BEARING and every other behaviour has one group, so the two
        -- can't share a cycle - there would be no single right shape for the row.
        local cycle = (type(rule.Behaviour) == "table") and rule.Behaviour or { rule.Behaviour or "Wander" }
        local crossfire = false
        for _, b in ipairs(cycle) do if b == "Crossfire" then crossfire = true end end
        if crossfire and #cycle > 1 then
            LogBad(("Director - rule %s: Crossfire cannot share a Behaviour cycle with another behaviour"):format(rule.Id))
        end

        rule._Groups = {}
        if rule.Groups then
            for _, g in ipairs(rule.Groups) do
                rule._Groups[#rule._Groups + 1] = build(g.Spawns or rule.Spawns, g.Count)
            end
        else
            -- A Crossfire row with no Groups puts the same pack on each bearing.
            local base = build(rule.Spawns, rule.Count)
            for _ = 1, crossfire and (rule.Packs or 2) or 1 do
                rule._Groups[#rule._Groups + 1] = base
            end
        end
        if #rule._Groups == 0 or #rule._Groups[1].Roster == 0 then
            LogBad(("Director - rule %s: no spawns"):format(rule.Id))
        end
        if rule.OncePerNight ~= nil and rule.OncePerNight ~= true and rule.OncePerNight ~= "world" then
            LogBad(("Director - rule %s: OncePerNight must be true or \"world\""):format(rule.Id))
        end
        if rule.Chance and (rule.Chance <= 0 or rule.Chance > 1) then
            LogBad(("Director - rule %s: Chance must be in (0, 1]"):format(rule.Id))
        end
        if rule.Sector and not RULES.SECTORS[rule.Sector] then
            LogBad(("Director - rule %s: unknown sector '%s'"):format(rule.Id, tostring(rule.Sector)))
        end
    end
    return #RULES.RULES
end

-- Idempotent and re-armed per world: StopMod wipes the loop with the WorkQueue and ResetState
-- clears DirectorArmed, so the next InitMod starts a fresh one.
function DIR.Register()
    local cfg = SETTINGS.MODULES and SETTINGS.MODULES.DIRECTOR
    if not (cfg and cfg.Enabled) then return end
    if not Utils.IsAuthority() then return end
    if STATE.DirectorArmed then return end
    STATE.DirectorArmed = true

    playerState, packs = {}, {}
    nightEpoch, wasNight, nightFiredWorld = 0, nil, {}
    local n = validateRules()

    local function loop()
        if not STATE.ModEnabled or not STATE.DirectorArmed then STATE.DirectorArmed = false; return end
        local ok, err = pcall(DIR.Tick)
        if not ok then LogBad("Director tick error: " .. tostring(err)) end
        Utils.QueueWork(loop, CFG.TickMs)
    end
    Utils.QueueWork(loop, CFG.TickMs)
    Log(("Director registered - %d rules, %d benches cached, hard tier %s"):format(
        n, BENCHES.Count(), HM.On("NoEnd") and "ON" or "off"))
end

return DIR
