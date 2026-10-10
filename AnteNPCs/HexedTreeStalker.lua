-- =======================================================================
-- HexedTreeStalker - specific to Canaan. Authority only.
-- Periodically spawns a Hexwood tree out of LoS to stalk a player; it creeps
-- toward the target unless observed (weeping-angel).
--   * It's a ResourceNode (AResourceNode_HexedTree_C), not an NPC, but lives
--     here since we treat it like one.
--   * Ground-clamps each step to navmesh Z (Canaan is hilly), refusing a step with no floor
--     under it so it can't end up gliding through the air after a player goes upstairs.
--   * On death, Outcasts spawn out of LoS shortly after, and the respawn clock starts.
--   * Hard mode: faster, a shorter respawn, and once wounded it advances in plain sight.
--   * Debug keybind HT.Toggle forces a manual override of the gate.
--   * Spawn placement reuses the shipped Leyak EQS (Placement.FindStalkerPoint),
--     biased out of LoS - no "behind the player" heuristic needed.
--   * Gate: poll for players in the Canaan vignette; arm/disarm on presence.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local UEHelpers = require("UEHelpers")
local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local Utils = require("AnteUtils.Utils")
local ASSETS = require("AnteCore.AssetManager")
local ENUMS = require("AnteData.Enums")
local G = require("AnteData.Items").Global
local AVU = require("AnteUtils.AVUtils")
local AVM = require("AnteUtils.AVMath")
local ItemSpawner = require("AnteCore.ItemSpawner")
local Placement = require("AnteCore.Placement")

local Log = Utils.Log
local LogDebug = Utils.LogDebug

local HT = {}

-- Tree movement + spawn placement
local TREE = {
    IntervalMs  = 500,    -- how often it checks whether anyone's watching
    Speed       = 50,     -- how far it moves per interval
    SpeedHard   = 75,     -- hard mode: it closes noticeably faster
    Scale       = 1.3,    -- ~30% bigger than a normal Hexed Tree
    SpawnRadius = 3500,   -- how far out of LoS it can spawn from its target
    MaxRange    = 7000,   -- despawns once the player gets this far away
    -- Floor-follow limits, per creep step (see floorZ).
    ProbeDrop   = 300,    -- start the nav probe this far BELOW its feet
    StepUp      = 150,    -- most it will climb; a bigger rise is an upper storey, not its floor
    MaxDrop     = 400,    -- most it will descend, so a ledge is walked down instead of dropped
}
-- Safety: spawnPending=true while a spawn is in flight; after this interval, assume EQS failed.
local SPAWN_WATCHDOG_MS = 4000

-- Sound when moving. The wave carries Att_DoorSound (silent past ~1900uu, and occluded through
-- walls), so at the range it stalks from it is inaudible at its authored level - the bands below
-- are what make it land. Two bands rather than a curve: a distant groan, then an unmistakable one.
local CREAK = {
    Sounds = {
        "/Game/Audio/Environment/Nature/S_Forest_Creak1.S_Forest_Creak1",
        "/Game/Audio/Environment/Nature/S_Forest_Creak2.S_Forest_Creak2",
        "/Game/Audio/Environment/Nature/S_Forest_Creak3.S_Forest_Creak3",
    },
    FarRange    = 2000,   -- nobody further out than this hears it at all
    NearRange   = 1000,   -- inside this it switches to the louder mix
    FarVolume   = 2.5,
    NearVolume  = 4.0,
    GapMinTicks = 25,     -- one creak every ~2.5-4s at most, not on every step it takes
    GapMaxTicks = 40,
}

local OUTCAST = {
    DelayMs     = 10000,  -- spawn this long after the tree is killed
    Count       = 1,
    LonerRadius = 1500,   -- don't spawn Outcasts near Canaan villagers
    ZLift       = 100,    -- lift the ground-level EQS point to capsule-center (NPC feet)
}

-- Cooldowns between stalking events, in FAST_TICKs (10/s). The respawn clock starts when the tree
-- DIES, not when it spawned, and it survives a disarm - otherwise stepping out of the Canaan box
-- and back in wipes it and the next tree arrives on the arm delay alone.
local COOLDOWN_TICKS      = 6000   -- 10 min between stalks
local COOLDOWN_TICKS_HARD = 4200   -- 7 min in hard mode
local FAIL_COOLDOWN_TICKS = 600    -- 1 min retry after a failed spawn attempt

-- Canaan gate. Driven by StoryManager.Tick (passes StoryProgress) - no own poll loop.
--   * Arm delay shortens once Salem is complete (haunting intensifies late-game).
--   * Presence is a coordinate box, not GetLevelName: V_Salem sits in an isolated
--     coordinate island far from every other level, so a box test is safe and much
--     faster than a level-name spatial query.
--   * Box = AABB of nine walked edge points, padded out generously.
local CANAAN_BOX = {
    min = { X = 128000, Y =  6000, Z = 44000 },
    max = { X = 173000, Y = 62000, Z = 62000 },
}
-- Canaan (V_Salem) is unreachable until the NightRealm shadows open it (Salem_Opened = 44), so
-- the vignette-presence poll is dead weight for most of a playthrough - skip it entirely below this.
local CANAAN_MIN_PROGRESS = 43   -- NightRealm_ShadowB_Destroyed
local SALEM = {
    CompleteProgress = 45,       -- Salem_Complete world flag
    PreDelayMs  = 1200000,       -- 20 min arm delay before Canaan is beaten
    PostDelayMs = 300000,        -- 5 min arm delay after
}

local spawnPending = false
local cooldownUntil = 0        -- FAST_TICK before which we won't (re)spawn
local pendingArm = false       -- a gate arm is queued (the start delay)
local lastTreeLoc = nil        -- last known tree location (for on-kill loot, since it's gone by then)
local treeWounded = false      -- someone has hit the live tree: hard mode stops respecting eyes
local nextCreakTick = 0        -- FAST_TICK the next creak may play on
local tickGen = 0              -- only the newest manager loop runs; arming again retires the old


-- =======================================================================
-- Helpers
-- =======================================================================

-- The tree's current + max HP, or nil if the fields can't be read (treat nil as "alive, untouched").
local function readHP(tree)
    local ok, hp, maxHp = pcall(function() return tree.CurrentHitPoints, tree.MaxHitPoints end)
    if ok then return hp, maxHp end
    return nil
end

-- A FAST_TICK deadline that outlived its world reads as hours away (the clock restarts at 0), which
-- would park the tree for the whole session. Anything further out than it could legitimately be is
-- a survivor, so treat it as elapsed.
local function deadlinePassed(deadline, maxTicks)
    local now = STATE.FAST_TICK
    return now >= deadline or deadline - now > maxTicks
end

-- [AUTHORITY] One wood-creak at `loc`, for each player near enough to hear it, at that player's
-- own volume band.
--   * PlayerController:ClientPlaySoundAtLocation is positional AND takes a volume multiplier, and a
--     listen host's own controller plays it locally - so one call covers every role. The old split
--     sent remotes Client_Play2DSoundEffect, which is non-spatial and hardcodes volume to 1.
--   * A creak carries a real sound, so NetChannel (which rides this same RPC with a NULL one and a
--     sentinel pitch) ignores it.
--   * Not Utils.CreateEffect: ReplicatedParticleFX's ParticleEffect/SoundToPlay don't
--     replicate, so its multicast played the BP defaults on clients instead.
local function playCreak(loc)
    local path = CREAK.Sounds[math.random(1, #CREAK.Sounds)]
    local sound = ASSETS.GetIfValid(path)
    if IsNotValid(sound) then return end

    local gs = STATE.GameState
    local players = gs and gs.PlayerCharacterInGame
    if not players then return end

    for i = 1, #players do
        local p = players[i]
        if IsValid(p) then
            local ok, pl = pcall(function() return p:K2_GetActorLocation() end)
            local dSq = ok and pl and Utils.DistSq(loc, pl)
            if dSq and dSq <= CREAK.FarRange * CREAK.FarRange then
                local vol = (dSq <= CREAK.NearRange * CREAK.NearRange)
                            and CREAK.NearVolume or CREAK.FarVolume
                pcall(function()
                    local pc = p:GetController()
                    if IsNotValid(pc) or not pc.ClientPlaySoundAtLocation then return end
                    pc:ClientPlaySoundAtLocation(sound, loc, vol, 1.0)
                end)
            end
        end
    end
end

-- End the current stalk: start the cooldown before another tree can spawn.
local function endSession(now, reason)
    local ticks = STATE.HardModeNoMercy and COOLDOWN_TICKS_HARD or COOLDOWN_TICKS
    cooldownUntil = now + ticks
    treeWounded = false
    LogDebug("HexedTree - session ended (" .. reason .. "), next stalk in ~"
        .. math.floor(ticks / 600) .. " min", SETTINGS.DEBUG_STORY)
end

-- Check if any player is watching this
local function anyPlayerLooking(tl)
    local gs = STATE.GameState
    local players = gs and gs.PlayerCharacterInGame
    if not players then return false end
    for i = 1, #players do
        local p = players[i]
        if IsValid(p) then
            local ok, pl = pcall(function() return p:K2_GetActorLocation() end)
            if ok and pl then
                if AVM.DistXY(pl, tl) > 1 then
                    local fwd = Utils.HorizontalForward(p)
                    if fwd and AVM.InArc(pl, fwd, tl, 60) then return true end   -- 60 deg half-angle
                end
            end
        end
    end
    return false
end

-- Floor the tree can stand on at (x, y), or nil if there is none it can reach from `fromZ`.
-- The nav probe returns the CLOSEST navmesh inside a box around the point it is given, so a
-- balcony or the storey a player just walked onto can win over the ground the tree is on - and once
-- it has been lifted, every later probe starts from up there and it glides through mid-air.
-- Probing from below its feet biases the answer downward, and the two limits keep it honest:
-- a rise bigger than a step means the floor wasn't found, and a fall is walked down, not dropped.
local function floorZ(x, y, fromZ)
    local z = Utils.GroundZ(FVector(x, y, fromZ - TREE.ProbeDrop), 0)
    if not z or z > fromZ + TREE.StepUp then return nil end
    return math.max(z, fromZ - TREE.MaxDrop)
end

-- Move towards the target while no player is watching
local function weepingTreeCreep(tree, tl, pl)
    -- Continually face the target
    local r = Utils.RotatorToTarget(tl, pl)
    pcall(function() tree:K2_SetActorRotation(FRotator(0, r.Yaw, 0), false) end)

    -- Hard mode: once it has been hit, it comes for you whether you're looking or not.
    local unblinking = STATE.HardModeNoMercy and treeWounded
    if not unblinking and anyPlayerLooking(tl) then return end

    local ux, uy, d = AVM.Normalize2D(tl.X - pl.X, tl.Y - pl.Y)
    if d < 1 then return end

    -- Creep toward the player (tl moves opposite the player->tree vector)
    local speed = STATE.HardModeNoMercy and TREE.SpeedHard or TREE.Speed
    local nx = tl.X - ux * speed
    local ny = tl.Y - uy * speed
    local nz = floorZ(nx, ny, tl.Z)
    if not nz then return end   -- nothing to stand on there: hold rather than walk out over a drop

    pcall(function() tree:K2_SetActorLocation(FVector(nx, ny, nz), false, {}, true) end)
    -- Push position now in case the ResourceNode re-dormants between steps.
    -- Otherwise the creep only syncs to clients when it's hit or woken.
    pcall(function() tree:FlushNetDormancy() end)

    LogDebug("HexedTree is creeping", SETTINGS.DEBUG_NPC_ACTIONS)
    -- A wood-creak on its own clock, so a full-speed creep doesn't groan twice a second.
    if deadlinePassed(nextCreakTick, CREAK.GapMaxTicks) then
        nextCreakTick = STATE.FAST_TICK + math.random(CREAK.GapMinTicks, CREAK.GapMaxTicks)
        playCreak(FVector(nx, ny, nz))
    end
end

-- Leyak EQS to find a point
local function findStalkSpot(player, canaanClear, cb)
    if Utils.IsActorInvalid(player) then return cb(nil) end
    local ok, ploc = pcall(function() return player:K2_GetActorLocation() end)
    if not ok or not ploc then return cb(nil) end

    Placement.FindStalkerPoint(player, { Origin = ploc, MaxDist = TREE.SpawnRadius }, function(points)
        if not points or #points == 0 then return cb(nil) end

        -- Shuffle for variety (Fisher-Yates), then take the first that satisfies the filter.
        for i = #points, 2, -1 do
            local j = math.random(1, i)
            points[i], points[j] = points[j], points[i]
        end

        for i = 1, #points do
            local spot = points[i]
            if (not canaanClear)
                or #AVU.GetNearbyNpcs(spot, OUTCAST.LonerRadius, { faction = ENUMS.Faction.Canaan }) == 0 then
                return cb(spot)
            end
        end
        cb(nil)
    end)
end

-- A while after a kill: spawn OUTCAST.Count Outcasts, each at its own out-of-LoS spot
-- clear of Canaan NPCs, aggro'd onto a random player.
--   * Skips quietly if there's no room / nobody around.
local function spawnOutcast()
    for _ = 1, OUTCAST.Count do
        local target = Utils.RandomPlayer()
        if not Utils.IsActorInvalid(target) then
            findStalkSpot(target, true, function(spot)
                if not spot then
                    LogDebug("HexedTree - no Canaan-clear spot for an Outcast, skipping one", SETTINGS.DEBUG_STORY)
                    return
                end
                -- EQS points sit at ground level; lift to capsule-center so feet don't clip.
                local at = FVector(spot.X, spot.Y, spot.Z + OUTCAST.ZLift)
                AVU.SummonVariant("Outcast", at, {}, function(npc)
                    if Utils.IsActorInvalid(npc) then return end
                    AVU.ForceAggro(npc, target)
                    LogDebug("HexedTree - Outcast spawned from the felled tree", SETTINGS.DEBUG_STORY)
                end)
            end)
        end
    end
end

-- [HT.Tick] AUTHORITY. A player destroyed the tree:
-- drop extra hexwood at its last spot, then queue the delayed Outcasts.
local function onTreeKilled()
    local loc = lastTreeLoc
    if loc then
        ItemSpawner.DropPool({ { G.HEXWOOD, 2 } }, 3, loc, 80)   -- 3 stacks of 2, fuzzed
    end
    Utils.QueueWork(spawnOutcast, OUTCAST.DelayMs)   -- the felled-tree payoff, later
end

-- LoadAsync the ResourceNode class (so BeginPlay is a cache hit, no in-hook cold-load freeze),
-- then deferred-spawn it.
--   * Dedicated server flushes via EIGT (off the spawn-hook drain).
local function spawnTreeAt(spot)
    ASSETS.WarmPinned(CREAK.Sounds)   -- warm the creak SFX (played per-move)
    ASSETS.LoadAsync({ ENUMS.ResourceNodes.HEXED_TREE }, function(results)
        local cls = (results and results[ENUMS.ResourceNodes.HEXED_TREE]) or ASSETS.GetIfValid(ENUMS.ResourceNodes.HEXED_TREE)
        if IsNotValid(cls) then
            spawnPending = false
            cooldownUntil = STATE.FAST_TICK + FAIL_COOLDOWN_TICKS
            LogDebug("HexedTree - class failed to load", SETTINGS.DEBUG_STORY)
            return
        end

        local function finishSpawn()
            spawnPending = false
            local gs = UEHelpers.GetGameplayStatics()
            local kMath = UEHelpers.GetKismetMathLibrary()
            local world = Utils.GetWorld()
            if not gs or not kMath or IsNotValid(world) then
                cooldownUntil = STATE.FAST_TICK + FAIL_COOLDOWN_TICKS
                return
            end

            local xform = kMath:MakeTransform(spot, FRotator(0, 0, 0), FVector(TREE.Scale, TREE.Scale, TREE.Scale))
            local okSpawn, errSpawn = pcall(function()
                local tree = gs:BeginDeferredActorSpawnFromClass(world, cls, xform, 0, nil, 0)
                if IsNotValid(tree) then return end
                tree = gs:FinishSpawningActor(tree, xform, 0)
                if Utils.IsActorValid(tree) then
                    -- ResourceNodes don't replicate movement by default; turn it on so
                    -- clients see the tree creep too.
                    pcall(function() tree:SetReplicateMovement(true) end)
                    -- ResourceNodes are also net-dormant by default (assumed to never move).
                    -- Without DORM_Never, position only reaches clients once something wakes
                    -- it (e.g. a melee hit), which is why it only synced in melee range.
                    pcall(function() tree:SetNetDormancy(0) end)
                    pcall(function() tree:FlushNetDormancy() end)
                    STATE.HexedTreeActor = tree
                    treeWounded = false
                    Log("HexedTreeStalker - spawned a stalker tree")
                end
            end)
            if not okSpawn then
                Utils.LogBad("HexedTree spawn - " .. tostring(errSpawn))
                cooldownUntil = STATE.FAST_TICK + FAIL_COOLDOWN_TICKS
            end
        end

        if STATE.Role == "DEDICATED" then ExecuteInGameThread(finishSpawn) else finishSpawn() end
    end)
end

-- Pick an out-of-LoS spot near a player, then spawn the tree there.
--   * Holds spawnPending across the async EQS + class load;
--     a watchdog releases it if neither ever calls back.
local function doSpawn()
    if spawnPending then return end
    local target = Utils.AnyPlayer()
    if Utils.IsActorInvalid(target) then cooldownUntil = STATE.FAST_TICK + FAIL_COOLDOWN_TICKS; return end

    spawnPending = true
    Utils.QueueWork(function()
        if spawnPending and Utils.IsActorInvalid(STATE.HexedTreeActor) then spawnPending = false end
    end, SPAWN_WATCHDOG_MS)

    findStalkSpot(target, false, function(spot)
        if not spot then
            spawnPending = false
            cooldownUntil = STATE.FAST_TICK + FAIL_COOLDOWN_TICKS
            LogDebug("HexedTree - no out-of-LoS spawn spot, retrying soon", SETTINGS.DEBUG_STORY)
            return
        end
        spawnTreeAt(spot)
    end)
end


-- =======================================================================
-- Manager loop
-- =======================================================================

-- Self-reschedules while armed: keep exactly one stalker creeping at the nearest player;
-- spawn (after cooldown) when none is alive; end the session if it's killed or out of range.
function HT.Tick(gen)
    if gen ~= tickGen then return end          -- a re-arm retired this loop; exactly one may run
    if not STATE.ModEnabled or not STATE.HexedTreeArmed then return end
    local now = STATE.FAST_TICK
    local tree = STATE.HexedTreeActor

    if not tree or Utils.IsActorInvalid(tree) then
        if STATE.HexedTreeActor ~= nil then
            -- We had a tree and it's gone -> the player killed it. Pay it off + end session.
            STATE.HexedTreeActor = nil
            onTreeKilled()
            endSession(now, "destroyed")
        elseif deadlinePassed(cooldownUntil, COOLDOWN_TICKS) and not spawnPending then
            doSpawn()                          -- cooldown elapsed -> try to stalk again
        end
    else
        local tl = tree:K2_GetActorLocation()
        if tl then lastTreeLoc = tl end        -- snapshot for the on-kill drop (it's gone by then)

        -- HP backstop: if it's been reduced to 0 but the actor isn't gone yet, treat as killed.
        local hp, maxHp = readHP(tree)
        if hp and maxHp and hp < maxHp then treeWounded = true end
        if hp and hp <= 0 then
            pcall(function() tree:K2_DestroyActor() end)
            STATE.HexedTreeActor = nil
            onTreeKilled()
            endSession(now, "destroyed")
        else
            local target = tl and Utils.NearestPlayer(tl)
            if target then
                local pl = target:K2_GetActorLocation()
                if pl and Utils.DistSq(tl, pl) > TREE.MaxRange * TREE.MaxRange then
                    -- Target outran it -> despawn and cool down (NO loot/Outcast - not a kill).
                    pcall(function() tree:K2_DestroyActor() end)
                    STATE.HexedTreeActor = nil
                    endSession(now, "out of range")
                elseif pl then
                    weepingTreeCreep(tree, tl, pl)
                end
            end
        end
    end

    Utils.QueueWork(function() HT.Tick(gen) end, TREE.IntervalMs)
end


-- =======================================================================
-- Canaan gate
-- =======================================================================

-- Checks for players in Canaan vignette to arm the tree
--   * Polls off StoryManager tick
--   * Starts up X seconds after, duration based on storyProgress
function HT.GateTick(story)
    if not STATE.ModEnabled or STATE.HexedTreeManual then return end
    if (story or 0) <= CANAAN_MIN_PROGRESS then return end   -- Canaan not reachable yet: skip the scan

    if Utils.AnyPlayerInBox(CANAAN_BOX.min, CANAAN_BOX.max) then
        if not STATE.HexedTreeArmed and not pendingArm then
            pendingArm = true
            local delay = ((story or 0) >= SALEM.CompleteProgress) and SALEM.PostDelayMs
                          or SALEM.PreDelayMs
            Utils.QueueWork(function()
                pendingArm = false
                if not STATE.HexedTreeManual and Utils.AnyPlayerInBox(CANAAN_BOX.min, CANAAN_BOX.max) then HT.Start() end
            end, delay)
        end
    elseif STATE.HexedTreeArmed then
        -- pendingArm is left alone on purpose: the arm delay is one clock per visit, and clearing
        -- it here would restart the whole wait every time someone stepped over the box edge.
        HT.Stop()
    end
end


-- =======================================================================
-- Arm / disarm
-- =======================================================================

-- `immediate` skips whatever respawn cooldown is left (the debug toggle). The gate never passes it:
-- a kill's cooldown has to outlive the disarm, or re-entering Canaan would hand back a free tree.
function HT.Start(immediate)
    if STATE.HexedTreeArmed then return end
    STATE.HexedTreeArmed = true
    if immediate then cooldownUntil = 0 end
    tickGen = tickGen + 1
    local gen = tickGen
    Utils.QueueWork(function() HT.Tick(gen) end, TREE.IntervalMs)
    LogDebug("HexedTreeStalker - armed and ready to creep", SETTINGS.DEBUG_STORY)
end

function HT.Stop()
    STATE.HexedTreeArmed = false
    tickGen = tickGen + 1      -- retire the live loop, so a quick re-arm can't leave two running
    local tree = STATE.HexedTreeActor
    if tree and Utils.IsActorValid(tree) then
        pcall(function() tree:K2_DestroyActor() end)
    end
    STATE.HexedTreeActor = nil
    treeWounded = false
    LogDebug("HexedTreeStalker - stopped and ready to sleep", SETTINGS.DEBUG_STORY)
end

-- Debug keybind: toggle a MANUAL override (ignores the Canaan gate so it works anywhere).
function HT.Toggle()
    STATE.HexedTreeManual = not STATE.HexedTreeManual
    if STATE.HexedTreeManual then HT.Start(true) else HT.Stop() end
end

-- [Utils.ResetState] Drop the per-world clocks and latches. cooldownUntil and nextCreakTick are
-- FAST_TICKs, and that clock restarts at 0 next world - a survivor reads as a deadline hours out.
function HT.ResetWorld()
    spawnPending, pendingArm, treeWounded = false, false, false
    cooldownUntil, nextCreakTick = 0, 0
    tickGen = tickGen + 1   -- bumped, never zeroed: a gen must not be reachable twice
    lastTreeLoc = nil
end

-- Debug "clear" swept our tracked tree away externally.
--   * Drop the ref so the manager doesn't fire the on-kill loot/Outcast for a debug wipe.
--   * Cool down so it doesn't instantly respawn.
function HT.NotifyCleared()
    STATE.HexedTreeActor = nil
    treeWounded = false
    cooldownUntil = STATE.FAST_TICK + FAIL_COOLDOWN_TICKS
end


return HT
