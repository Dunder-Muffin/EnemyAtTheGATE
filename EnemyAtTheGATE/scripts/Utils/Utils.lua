---@diagnostic disable: undefined-field, undefined-global, inject-field, param-type-mismatch


local UEHelpers = require("UEHelpers")
local AFUtils   = require("AFUtils.AFUtils")

local STATE = require("Data.STATE")
local Enums = require("Data.Enums")
local CONFIG = STATE.Config
local QM     = require("Managers.QueueManager")
local Assets = require("Utils.AssetManager")
local Keeper = require("Utils.AssetKeeper")   -- must NOT require Utils back (cycle)
local Utils  = {}

-- ============================================================
-- Logging
-- ============================================================

function Utils.Log(msg)
    print("[GATE] " .. tostring(msg) .. "\n")
end

function Utils.LogBad(msg)
    print("[GATE][ERR] " .. tostring(msg) .. "\n")
end

function Utils.LogDebug(msg, condition)
    if condition then
        print("[GATE] " .. tostring(msg) .. "\n")
    end
end


-- ============================================================
-- Net role
-- * IsServer() / IsDedicatedServer() are globals from AFUtils.BaseUtils.
-- * Role can change between worlds (SP -> join a server), so call
--   DetectRole() once per world in InitMod. IsAuthority() also lazily
--   detects if Role hasn't been set yet, so it is safe to call early.
-- ============================================================

function Utils.DetectRole()
    if IsDedicatedServer() then
        STATE.Role = "DEDICATED"
    elseif IsServer() then
        STATE.Role = "HOST"       -- single player or listen-server host
    else
        STATE.Role = "CLIENT"     -- joined someone else's game
    end
    return STATE.Role
end

-- Authority runs the real assault/director logic (server side).
function Utils.IsAuthority()
    if not STATE.Role then Utils.DetectRole() end
    return STATE.Role == "HOST" or STATE.Role == "DEDICATED"
end

function Utils.IsClient()
    if not STATE.Role then Utils.DetectRole() end
    return STATE.Role == "CLIENT"
end

-- A dedicated server has no local player / renderer; keybinds are pointless there.
function Utils.HasRenderer()
    if not STATE.Role then Utils.DetectRole() end
    return STATE.Role ~= "DEDICATED"
end


-- ============================================================
-- RemoteUnrealParam compatibility (UE4SS 954)
--
-- * 954 wraps many values - out-array elements, some hook params - as
--     RemoteUnrealParam userdata that must be read with :get(). Older builds
--     handed back the value directly.
-- * Unwrap() accepts either form:  local actor = Utils.Unwrap(nearby[i])
-- * GATE already calls :get() at its known out-array sites; this is the safety
--     net for anywhere that turns out to be wrapped differently across versions.
-- ============================================================
function Utils.Unwrap(v)
    if type(v) ~= "userdata" then return v end
    -- RemoteUnrealParam exposes a :get() method; plain UObject userdata does not.
    local hasGet = false
    pcall(function() hasGet = type(v.get) == "function" end)
    if hasGet then
        local ok, inner = pcall(function() return v:get() end)
        if ok then return inner end
    end
    return v
end


-- ============================================================
-- Actor validity
-- ============================================================

function Utils.IsActorValid(actor)
    if IsNotValid(actor) then return false end
    -- IsActorBeingDestroyed / GetWorld removed: they are BP calls that can throw a
    -- C++ exception (uncatchable by pcall) when the actor is being destroyed on the
    -- game thread while this runs on a worker thread (ExecuteWithDelay).
    -- IsNotValid already covers null/pending-kill/unreachable cases.
    return true
end

function Utils.IsActorInvalid(actor)
    return not Utils.IsActorValid(actor)
end

function Utils.IsActorAlive(actor)
    if IsNotValid(actor) then return false end
    if not actor.RootComponent then return false end
    if actor.IsDead then return false end
    if actor.IsDBNO then return false end

    local ok, hp = pcall(function() return actor:GetTotalHealth() end)
    if not ok or not hp or hp <= 0 then return false end

    return true
end

-- Forces an NPC's AI controller to target and attack the given actor.
function Utils.ForceAttackTarget(actor, target, skipAggroAnim)
    skipAggroAnim = skipAggroAnim or false
    if Utils.IsActorInvalid(actor) then return end
    if Utils.IsActorInvalid(target) then return end

    local controller = actor:GetController()
    if not controller or IsNotValid(controller) then return end

    local targetLoc = target:K2_GetActorLocation()
    local success   = {}

    controller:BT_SetCombatState(true, skipAggroAnim, success)
    controller:BT_SetTargetActor(target)
    controller:UpdateTargetSpottedValue(target, true, true)
    controller:BT_SetLastKnownLocation(targetLoc, true, true)
    controller:BT_SetCanSeeTarget(target)
end


-- Returns the NPC display name, or actor:GetFullName() as fallback.
-- * Don't pass player actors. I think they have actor.NPCData [nil]
function Utils.GetActorName(actor)
    local npcData = actor.NPCData
    if npcData and IsValid(npcData) then
        local ok, name = pcall(function()
            return npcData.DisplayName_9_5C4263DF4E1C7D38B677D7A3755C44E8:ToString()
        end)
        if ok and name and name ~= "" then return name end
    end
    local ok, name = pcall(function() return actor:GetFullName() end)
    return (ok and name) or tostring(actor)
end

-- Returns a readable name for a player character via PlayerState.
function Utils.GetPlayerName(actor)
    local ps = actor.PlayerState
    if ps and IsValid(ps) then
        local ok, name = pcall(function() return ps:GetPlayerName():ToString() end)
        if ok and name and name ~= "" then return name end
    end
    local ok, name = pcall(function() return actor:GetFullName() end)
    return (ok and name) or tostring(actor)
end

-- ============================================================
-- Players
-- ============================================================

function Utils.GetPlayers()
    -- APlayerState has no GetPlayerController(); use FindAllOf for reliability.
    local all = FindAllOf("Abiotic_PlayerCharacter_C")
    if not all then return nil end

    local playerActors = {}
    for _, pawn in ipairs(all) do
        if pawn and IsValid(pawn) and not pawn.IsDead then
            playerActors[#playerActors + 1] = pawn
        end
    end
    return #playerActors > 0 and playerActors or nil
end

-- ============================================================
-- Broadcast helpers
-- ============================================================


-- Textbox message
function Utils.Chat(msg)
    AFUtils.DisplayTextChatMessage(msg)
    Utils.Log(msg)
end


function Utils.BroadcastWarningMessage(msg, color)
    color = color or AFUtils.CriticalityLevels.Purple

    local players = Utils.GetPlayers()
    if not players or #players == 0 then return end

    for i = 1, #players do
        local player = players[i]
        if IsValid(player) and player.Client_DisplayWarningMessage then
            player:Client_DisplayWarningMessage(FText(msg), color, false)
        end
    end
end

function Utils.Broadcast2DSound(soundPath)
    if not soundPath or soundPath == "" then return end
    -- 954: never LoadAsset synchronously here (deadlocks inside the spawn hook).
    -- Use the resident/cached asset; if missing, warm it for next time and skip.
    local sound = Assets.GetIfValid(soundPath)
    if not sound then Assets.Warm(soundPath); return end

    local players = Utils.GetPlayers()
    if not players or #players == 0 then return end

    for i = 1, #players do
        local player = players[i]
        if IsValid(player) and player.Client_Play2DSoundEffect then
            player:Client_Play2DSoundEffect(sound)
        end
    end
end

-- Spawns a sound at loc and returns the AudioComponent
--   * Return the sound because for loops, we have to stop it (audioComp:Stop())
--   * Used to return Broadcast2DSound as a fallback, but not great for looping sounds
-- 
function Utils.SpawnSound(soundPath, location, volume)
    volume = volume or 1.0

    -- Lets load the asset but skip this time
    --   If we LoadAsset here it can deadlock, so try and get the asset ready for future calls 
    local sound = Assets.GetIfValid(soundPath)
    if not sound then
        Assets.Warm(soundPath)
        Utils.LogBad("[GATE] SpawnSound() - not resident (warming): " .. tostring(soundPath))
        return nil
    end

    local world = UEHelpers.GetWorld()
    if not world or IsNotValid(world) then return nil end

    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if not gs or IsNotValid(gs) then
        Utils.Broadcast2DSound(soundPath)
        return nil
    end

    -- bAutoDestroy=false so looping sounds persist until we call Stop()
    local ok, comp = pcall(function()
        return gs:SpawnSoundAtLocation(world, sound, location,
            FRotator(0, 0, 0), volume, 1.0, 0.0, nil, nil, false)
    end)
    if ok and comp and IsValid(comp) then
        return comp
    end

    -- Utils.Broadcast2DSound(soundPath)
    return nil
end


-- ============================================================
-- SpawnReplicatedFX - server-side REPLICATED particle FX that renders on
-- clients (a dedicated server has no renderer of its own).
--
-- Uses the game's own ReplicatedParticleFX_BP actor:
--   * bReplicates = true, plays a Niagara + a sound
--   * its ActivateFX() is a NetMulticast that skips the dedicated server and
--     fires on every client (and on a listen host)
--
-- Call this on the AUTHORITY (server/host). opts:
--   particle - Niagara system path to override the BP default portal burst [opt]
--   sound    - SoundWave/Cue path to override the BP default portal sound   [opt]
--   rotation, scale
--   lifetime - ms before the actor is auto-destroyed (nil = caller destroys it)
-- onReady(actor) gets the spawned actor (or nil) so the caller can destroy it
-- (e.g. to close a portal when a drop finishes).
--
-- NOTE: overrides are set on the server before BeginPlay. ParticleEffect /
-- SoundToPlay may not be replicated properties, in which case remote clients
-- fall back to the BP defaults (portal burst + portal_spawn sound) - fine for
-- "place something". The host always gets the override.
-- ============================================================
local REPLICATED_FX_CLASS = "/Game/Blueprints/Environment/Effects/ReplicatedParticleFX_BP.ReplicatedParticleFX_BP_C"

function Utils.SpawnReplicatedFX(location, opts, onReady)
    opts = opts or {}
    onReady = onReady or function() end

    Assets.LoadAsset(REPLICATED_FX_CLASS, function(fxClass)
        if not fxClass or IsNotValid(fxClass) then onReady(nil); return end

        -- Spawn on a clean game-thread flush point (not inline in the hook), same
        -- reasoning as SpawnNpc.
        ExecuteInGameThread(function()
            local world  = UEHelpers.GetWorld()
            local kismet = GetKismetMathLibrary()
            local gs     = GetGameplayStatics()
            if IsNotValid(world) or not kismet or not gs then onReady(nil); return end

            local rotation = opts.rotation or FRotator(0, 0, 0)
            local scale    = opts.scale    or FVector(1.0, 1.0, 1.0)
            local transform = kismet:MakeTransform(location, rotation, scale)

            -- 2 = AdjustIfPossibleButAlwaysSpawn
            local actor = gs:BeginDeferredActorSpawnFromClass(world, fxClass, transform, 2, nil, 0)
            if not actor or IsNotValid(actor) then onReady(nil); return end

            -- Force this runtime-spawned actor to replicate to clients. The class
            -- is bReplicates=true but the game only ever PLACES these in levels
            -- (never runtime-spawns one), so a cold spawn may be net-dormant or
            -- distance-culled and never reaches clients. Configure replication
            -- before FinishSpawning: bAlwaysRelevant defeats distance culling,
            -- DORM_Awake (1) keeps it non-dormant.
            pcall(function() actor.bAlwaysRelevant = true end)
            pcall(function() actor.NetDormancy = 1 end)

            -- Optional asset overrides (applied before BeginPlay's SetAsset).
            if opts.particle then
                local sys = Assets.GetIfValid(opts.particle)
                if sys then pcall(function() actor.ParticleEffect = sys end) end
            end
            if opts.sound then
                local snd = Assets.GetIfValid(opts.sound)
                if snd then pcall(function() actor.SoundToPlay = snd end) end
            end

            gs:FinishSpawningActor(actor, transform, 0)
            -- Belt-and-suspenders: ensure replication is on and wake any dormancy
            -- so the actor is pushed to clients this/next net update.
            pcall(function() actor:SetReplicates(true) end)
            pcall(function() actor:FlushNetDormancy() end)

            -- (DEBUG) net-state readback. RemoteRole ~= 0 means it IS set to
            -- replicate (issue would be relevancy/timing); 0 means not configured.
            if CONFIG.DEBUG_LOG then
                local function rd(f) local ok, v = pcall(f); return ok and tostring(v) or "?" end
                Utils.LogDebug(string.format("SpawnReplicatedFX: spawned bRep=%s alwaysRel=%s dormancy=%s remoteRole=%s",
                    rd(function() return actor.bReplicates end),
                    rd(function() return actor.bAlwaysRelevant end),
                    rd(function() return actor.NetDormancy end),
                    rd(function() return actor.RemoteRole end)), true)
            end

            -- Multicast play. ActivateFX is a NetMulticast: clients that don't yet
            -- have the actor channel open when it fires will MISS it (multicasts
            -- aren't buffered). Delay long enough for the fresh actor to replicate
            -- to nearby clients first.
            Utils.QueueSpawn(function()
                if IsValid(actor) then pcall(function() actor:ActivateFX() end) end
            end, 800)

            if opts.lifetime then
                Utils.QueueSpawn(function()
                    if IsValid(actor) then actor:K2_DestroyActor() end
                end, opts.lifetime)
            end

            onReady(actor)
        end)
    end)
end


-- ============================================================
-- SendClientFX - reliable server->client cosmetic FX signal.
--
-- Server-spawned FX actors don't replicate to clients and Lua can't define an
-- RPC, so we borrow the chat NetClient RPC as a data pipe.
--   * Local_DisplayTextChatMessage is reliable and reaches exactly that client.
--   * We send EMPTY strings (nothing renders) and pack the payload into its two
--     FLinearColor params.
--   * Reaches host + every client uniformly - a listen host runs the client RPC
--     on its own controller - and arrives immediately, so it can fire BEFORE the
--     NPCs spawn.
--
-- WIRE FORMAT (Hooks/ClientFX decodes it; change one end and you MUST change
-- the other):
--   PrefixColor  = { R=X, G=Y, B=Z, A = keyIndex*10000 + seconds }
--   MessageColor = { R = FX_SENTINEL, G = yaw, B = drift, A = 0 }
--
--   yaw    degrees. The portal Niagara is a flat plane and is invisible edge-on,
--          so anything that isn't radially symmetric needs it.
--   drift  uu of travel along `yaw` over the effect's whole life: it starts
--          drift/2 AHEAD of `location` and ends drift/2 behind it, so the gate
--          reads as advancing on whatever it faces. -1 = "not specified", use
--          the ClientFX registry default; 0 pins it still.
--
-- FX_SENTINEL marks the message as ours - real chat colors are 0..1, so an
-- out-of-range R can't be a genuine message. AnteUp uses a DIFFERENT sentinel
-- on the same RPC on purpose; sharing one made each mod decode the other's
-- pushes against its own registry.
--
-- Call on the AUTHORITY (server/host).
-- ============================================================
Utils.FX_KEYS = { "GK_PORTAL", "NIGHTREALM", "RAT_PORTAL" }   -- index <-> key (shared w/ ClientFX)
Utils.FX_SENTINEL = 12321.0                      -- real chat colors are 0..1, so this marks ours
local FX_KEY_IDX = {}
for i, k in ipairs(Utils.FX_KEYS) do FX_KEY_IDX[k] = i end

function Utils.SendClientFX(location, effectKey, seconds, yaw, drift)
    if not location then return end
    local x = math.floor((location.X or 0) + 0.5)
    local y = math.floor((location.Y or 0) + 0.5)
    local z = math.floor((location.Z or 0) + 0.5)
    local keyIdx = FX_KEY_IDX[effectKey] or 1
    local secs   = math.max(1, math.min(9999, math.floor(seconds or 10)))

    local dataColor = { R = x, G = y, B = z, A = keyIdx * 10000 + secs }
    local markColor = {
        R = Utils.FX_SENTINEL,
        G = (yaw or 0) % 360,
        -- A real drift is never negative (flip the yaw instead), so -1 is free
        -- to mean "sender didn't say".
        B = drift and math.max(0, math.floor(drift + 0.5)) or -1.0,
        A = 0.0,
    }

    local controllers = FindAllOf("Abiotic_PlayerController_C")
    if not controllers then return end
    for _, pc in ipairs(controllers) do
        if IsValid(pc) and pc.Local_DisplayTextChatMessage then
            local ps = pc.PlayerState
            pcall(function()
                pc:Local_DisplayTextChatMessage("", dataColor, "", markColor, ps, false)
            end)
        end
    end
end


-- Yaw in degrees pointing from `from` at `to`. Feed it to SendClientFX (which
-- way the portal faces / drifts) and to SpawnNpc's rotation (which way the body
-- that steps out of it is looking).
function Utils.YawTo(from, to)
    if not from or not to then return 0 end
    local dx = (to.X or 0) - (from.X or 0)
    local dy = (to.Y or 0) - (from.Y or 0)
    if dx == 0 and dy == 0 then return 0 end
    return math.deg(math.atan(dy, dx))
end


-- ============================================================
-- Assault helpers
-- ============================================================

function Utils.FNameToString(Fname)
    return (Fname and Fname:ToString()) or nil
end

-- Replaces TArray<FName> contents with a Lua string-table.
function Utils.SetFNameArray(tarray, names)
    for i = 1, #names do
        tarray[#tarray + 1] = FName("None")
    end
    local i = 1
    tarray:ForEach(function(_, elem)
        if i > #names then return end
        elem:set(FName(names[i]))
        i = i + 1
    end)
end

-- Gets the Crafting Bench that the assault is targeting
-- * Returns bench, benchLoc
function Utils.GetAssaultBench()

    local director = FindFirstOf("Abiotic_AIDirector_C")
    if not director or IsNotValid(director) then return end

    local bench = director.TargetAssaultBench
    if not bench or IsNotValid(bench) then return end

    local benchLoc = bench:K2_GetActorLocation()

    return bench, benchLoc
end

-- Crafting-bench deployable classes (all derive from the ParentBP base).
local BENCH_CLASSES = {
    "AbioticDeployed_CraftingBench_ParentBP_C",
    "Deployed_CraftingBench_Default_C",
    "Deployed_CraftingBench_Repair_C",
    "Deployed_CraftingBench_SIGNAL_C",
    "Deployed_CraftingBench_Upgrade_C",
}

-- Returns a list of FVector for every crafting-bench deployable EXCEPT the one
-- at targetLoc (the assault's target bench). A base can have 2-3 benches; the
-- non-target ones are often walled off in a different room, so spawning beside
-- them strands NPCs. Callers feed this to GetSpawnPoint's `avoid` arg.
-- * De-duped by rounded X,Y (one bench can match more than one class query).
function Utils.GetOtherBenchLocations(targetLoc)
    local out, seen = {}, {}
    for _, cls in ipairs(BENCH_CLASSES) do
        local list = FindAllOf(cls)
        if list then
            for _, b in ipairs(list) do
                if Utils.IsActorValid(b) then
                    local ok, loc = pcall(function() return b:K2_GetActorLocation() end)
                    if ok and loc then
                        local key = math.floor(loc.X) .. "," .. math.floor(loc.Y)
                        if not seen[key]
                            and (not targetLoc or Utils.DistSq(loc, targetLoc) > 100 * 100) then
                            seen[key] = true
                            out[#out + 1] = FVector(loc.X, loc.Y, loc.Z)
                        end
                    end
                end
            end
        end
    end
    return out
end

-- ============================================================
-- EnsureAssaultPatrolLocation - the guard against the silent assault abort.
--
-- BeginAssault (for every spawn method EXCEPT 1) does:
--     TryUpdateAssaultPatrolLocation() -> wait 1s -> HasValidAssaultPatrolLocation()
--       false -> SpawnPowerLeechCheck() -> Assault_CurrentPhase = 6
--
-- "Valid" means only Assault_PatrolTargetLocation ~= (0,0,0). When it's zero the
-- assault dies on the spot: a couple of power leeches pop onto the base's
-- batteries, the end sting plays, and NOT ONE assault NPC spawns. The phase is
-- written directly rather than through ChangeAssaultPhase, and
-- SortAssaultSpawnLists is only reached on the success branch, so nothing about
-- it appears in any log.
--
-- Zero happens when the EQS behind TryUpdateAssaultPatrolLocation returns
-- nothing, doesn't answer inside that 1s window, or is never run at all
-- (PatrolTargetRequiresUpdate false / bench level not streamed). Only spawn
-- methods 2 and 3 assign the location in OnAssaultEQSResult - method 0 falls
-- through a broadcast and assigns NOTHING, so a method-0 row aborts every time.
--
-- So: if it's still zero, write a real navmesh point near the target bench. The
-- patrol point is where assault NPCs head for, and the bench is exactly that -
-- a plausible value here costs nothing and saves the assault.
--
-- Returns true if it wrote one. Call on the game thread; property reads/writes
-- only, loads nothing.
-- ============================================================
function Utils.EnsureAssaultPatrolLocation(director)
    if not director or IsNotValid(director) then return false end

    local ok, wrote = pcall(function()
        local p = director.Assault_PatrolTargetLocation
        if p and not (p.X == 0 and p.Y == 0 and p.Z == 0) then return false end

        local benchLoc = director.Assault_BenchTargetLocation
        if not benchLoc or (benchLoc.X == 0 and benchLoc.Y == 0 and benchLoc.Z == 0) then
            return false   -- no bench either; this one is not ours to save
        end

        -- A navmesh point 10-25m out, same as where the EQS would have landed.
        -- GetSpawnPoint never fails, so the worst case is still a real location.
        local point = Utils.GetSpawnPoint(benchLoc, 2500, 1000, 12, 400, 0)
                      or FVector(benchLoc.X, benchLoc.Y, benchLoc.Z)

        director.Assault_PatrolTargetLocation = point
        return true
    end)

    if ok and wrote then
        Utils.Log(string.format(
            "[GATE] EnsureAssaultPatrolLocation - patrol point was (0,0,0); wrote a bench-side " ..
            "navmesh point so BeginAssault doesn't abort the assault (power-leech bail)"))
        return true
    end
    return false
end


-- ============================================================
-- The director's OWN wave spawn points.
--
-- Assault_CurrentTargetLocation is the EQS result set (EQ_FindAssaultSpawn):
-- up to 3 points for spawn method 2, all of them for method 3. The director
-- picks one at random per wave NPC and spawns it there +100 Z.
--
-- So this is exactly where the native waves come from - use it to land a GATE
-- drop ON TOP of a wave instead of somewhere else around the base. That's what
-- turns two hostile factions into an actual crossfire rather than two separate
-- attacks on the bench.
--
-- Returns a list of FVector (possibly empty).
-- ============================================================
function Utils.GetAssaultSpawnPoints()
    local out = {}
    local director = FindFirstOf("Abiotic_AIDirector_C")
    if not director or IsNotValid(director) then return out end

    pcall(function()
        local arr = director.Assault_CurrentTargetLocation
        if not arr then return end
        for i = 1, (arr:GetArrayNum() or 0) do
            local v = Utils.Unwrap(arr[i])
            if v then out[#out + 1] = FVector(v.X, v.Y, v.Z) end
        end
    end)
    return out
end

-- One of the above at random, or nil if the director has none yet.
function Utils.GetAssaultSpawnPoint()
    local pts = Utils.GetAssaultSpawnPoints()
    if #pts == 0 then return nil end
    return pts[math.random(1, #pts)]
end


-- ============================================================
-- CROSSFIRE - make an assault NPC pick a fight with another faction first.
-- ============================================================

-- Live NPCs of `faction` within `radius` of `origin`. faction nil = any.
--   * SphereOverlapActors, not FindAllOf - FindAllOf walks every UObject.
--   * maxZ is a STOREY BAND, and it matters. The overlap is a true 3D sphere, so
--     in a multi-storey interior a 25m sweep reaches the balcony above as easily
--     as the room you're in - and this sweep hands out AGGRO. Floor separation is
--     ~1000uu, so the 600 default is about one storey.
--   * Overlap results come back wrapped on 954; Unwrap handles both forms.
function Utils.FindNearbyNPCs(origin, radius, faction, maxZ)
    local out = {}
    if not origin then return out end
    maxZ = maxZ or 600

    local baseClass = Assets.GetIfValid(Enums.BASE_PARENT_NPC)
    if not baseClass then
        Assets.Warm(Enums.BASE_PARENT_NPC)
        return out
    end

    local nearby = Utils.GetNearbyActorClass(origin, radius or 2500, baseClass)
    for i = 1, #nearby do
        local npc = Utils.Unwrap(nearby[i])
        if npc and Utils.IsActorAlive(npc) then
            local keep = true

            if faction ~= nil then
                local ok, f = pcall(function() return npc.Faction end)
                keep = ok and f == faction
            end

            if keep then
                local ok, at = pcall(function() return npc:K2_GetActorLocation() end)
                keep = ok and at and math.abs(at.Z - (origin.Z or 0)) <= maxZ
            end

            if keep then out[#out + 1] = npc end
        end
    end
    return out
end


-- ============================================================
-- LockTargetOnce - "go hit THAT one first".
--
-- The game's own force-target recipe (Buff_Command_Attack / BP_SquadManager),
-- applied ONCE. Every attack task clears TargetLocked when it completes, so the
-- lock dies on the NPC's first finished swing and normal target selection takes
-- over - the NPC bounces off and rejoins the assault. That one-shot behaviour is
-- the point here; AnteUp re-asserts on a timer when it wants a lock to hold.
--
-- AddOrUpdatePotentialTarget is the load-bearing call - it seeds the perception
-- entry the BT root gates on, and it BAILS if the two aren't hostile. So this is
-- faction-gated by design: you can't set an NPC on its own team.
--
-- Authority only. Returns true if the lock was applied.
-- ============================================================
function Utils.LockTargetOnce(npc, target)
    if Utils.IsActorInvalid(npc) or Utils.IsActorInvalid(target) then return false end
    if npc.IsDead or target.IsDead then return false end

    local controller = npc:GetController()
    if not controller or IsNotValid(controller) then return false end

    local ok = pcall(function()
        local success = {}
        controller:AddOrUpdatePotentialTarget(target, true)
        controller:BT_SetTargetActor(target)
        controller:BT_SetCombatState(true, true, success)   -- skip the aggro roar

        local bb = controller.Blackboard
        if IsValid(bb) then
            bb:SetValueAsBool(FName("TargetLocked"), true)
            bb:SetValueAsBool(FName("CanSeeTarget"), true)
        end
    end)
    return ok
end


-- ============================================================
-- AggroFavoredEnemy - send a freshly spawned NPC at a rival faction.
--
-- Looks for NPCs of `faction` within `radius` of `origin` (the bench) and
-- one-shot locks onto a random one. No candidates = do nothing, so the NPC just
-- runs the assault normally.
--
-- Delayed by default: a just-spawned NPC has no controller/BT for a moment.
-- ============================================================
function Utils.AggroFavoredEnemy(npc, origin, faction, radius, delayMs)
    if not faction or not origin or Utils.IsActorInvalid(npc) then return end

    -- Copy the origin NOW. It came off a BP call, and we're about to hold it
    -- across a delay - a captured engine struct wrapper can go stale.
    origin = FVector(origin.X, origin.Y, origin.Z)

    Utils.DelayedGameThread(delayMs or 1500, function()
        if Utils.IsActorInvalid(npc) or npc.IsDead then return end

        local candidates = Utils.FindNearbyNPCs(origin, radius or 2500, faction)
        if #candidates == 0 then return end

        local target = candidates[math.random(1, #candidates)]
        if Utils.LockTargetOnce(npc, target) then
            Utils.LogDebug(string.format("[GATE] crossfire: %s -> %s",
                Utils.GetActorName(npc), Utils.GetActorName(target)), CONFIG.DEBUG_LOG)
        end
    end)
end


-- Resolve an assault-file FavoredEnemy value to a faction number.
-- Accepts a faction name ("Exor") or a raw number. nil / unknown -> nil.
function Utils.ResolveFaction(value)
    if value == nil then return nil end
    if type(value) == "number" then return value end

    local f = Enums.Faction[value]
    if f == nil then
        Utils.LogBad("[GATE] unknown faction name: " .. tostring(value) ..
                     " (see Enums.Faction in scripts/Data/Enums.lua)")
    end
    return f
end


function Utils.IsAssaultHappening()
    local director = FindFirstOf("Abiotic_AIDirector_C")
    if IsNotValid(director) then return false end
    return director:IsAssaultHappening()
end

-- Calls director:SelectRandomAssaultType and prints the result.
-- * excludeRows: optional list of assaults to exclude
-- * queueForEndless: if true, stores the chosen row in STATE.EndlessQueuedRow
--   so the SelectRandomAssaultType post-hook preserves it when
--   ServerForceBeginAssault re-rolls internally. Returns the row name or nil.
function Utils.ShuffleAssault(excludeRows, queueForEndless)
    local director = FindFirstOf("Abiotic_AIDirector_C")
    if IsNotValid(director) then return nil end

    local MAX_TRIES = 1000
    local chosenRow

    for _ = 1, MAX_TRIES do
        local out = {}
        director:SelectRandomAssaultType(out)
        if not out.FoundValidRow then return nil end

        local rowStr = director.Assault_CurrentRow and director.Assault_CurrentRow:ToString() or ""
        Utils.Log("RowStr is " .. rowStr)
        if rowStr == "" or rowStr == "None" then return nil end

        local excluded = false
        if excludeRows then
            for _, ex in ipairs(excludeRows) do
                if rowStr:find(ex, 1, true) then excluded = true; break end
            end
        end

        if not excluded then
            chosenRow = rowStr
            break
        end
    end

    if not chosenRow then return nil end

    if queueForEndless then
        STATE.EndlessQueuedRow = chosenRow
    else
        AFUtils.DisplayTextChatMessage("[GATE] Next native assault: " .. chosenRow)
    end

    return chosenRow
end

-- Force begin an assault (for debug keybinds).
function Utils.TriggerAssault()
    local director = FindFirstOf("Abiotic_AIDirector_C")
    if IsNotValid(director) then return end
    director:ServerForceBeginAssault()
end

-- Free all deployed turrets from power requirements. Returns laser/disc counts.
-- Authority-only work (touches replicated actors); callers should be on the
-- game thread (QueueSpawn) and on the server.
function Utils.FreeAllTurrets()
    local laserCount, discCount = 0, 0

    local lasers = FindAllOf("Deployed_Turret_Laser_C")
    if lasers then
        for _, t in ipairs(lasers) do
            if IsValid(t) then
                t.HasLaserPower = true
                t:RefreshIsBrokenState()
                laserCount = laserCount + 1
            end
        end
    end

    local discs = FindAllOf("Deployed_Turret_Disc_C")
    if discs then
        for _, t in ipairs(discs) do
            if IsValid(t) then
                t.RequiresPower = false
                t:RefreshIsBrokenState()
                discCount = discCount + 1
            end
        end
    end

    return laserCount, discCount
end

-- Set the next native assault type by row name (used before TriggerAssault).
function Utils.SetNextAssaultType(name)
    local director = FindFirstOf("Abiotic_AIDirector_C")
    if IsNotValid(director) then return end
    local out = {}
    director:SelectNewAssaultType(FName(name), true, out)
end

-- Move time ahead x hours
function Utils.AdvanceTime(hoursToAdvance)
    hoursToAdvance = hoursToAdvance or 4

    AFUtils.AddGameTime(hoursToAdvance)

    local dayNight = AFUtils.GetDayNightManager()
    if not dayNight or IsNotValid(dayNight) then return end

    local t = dayNight.CurrentTimeInSeconds
    local hour = math.floor(t / 3600)
    local minute = math.floor((t % 3600) / 60)
    local day = dayNight.CurrentDay or 0

    local assaultSuffix = ""
    local director = FindFirstOf("Abiotic_AIDirector_C")
    if director and IsValid(director) then
        local rowFName = director.Assault_CurrentRow
        if rowFName then
            local rowStr = rowFName:ToString()
            if rowStr ~= "" and rowStr ~= "None" then
                assaultSuffix = " [" .. rowStr .. "]"
            end
        end
    end

    Utils.Chat(string.format("[TIME] (Day %d)  %02d:%02d - %s", day, hour, minute, assaultSuffix))
end


-- Get the game name for the assault
function Utils.GetNativeAssaultName()
    local director = FindFirstOf("Abiotic_AIDirector_C")
    if not director or IsNotValid(director) then return nil, nil end
    local rowFName = director.Assault_CurrentRow
    local assaultRow = (rowFName and rowFName:ToString()) or "None"
    return director, assaultRow
end

-- Spawn an NPC (async; see callback note below)
function Utils.SpawnNpc(classPath, location, rotation, onSpawned)
    rotation  = rotation  or FRotator(0, math.random(0, 359), 0)
    onSpawned = onSpawned or function() end

    -- ASYNC: AssetManager loads the class on the game thread (954: classes get
    -- GC'd and can't be LoadAsset'd synchronously inside a hook), then we spawn
    -- and call onSpawned(npc) - on the game thread - with the new actor (or nil
    -- on failure). For resident/cached classes the callback fires immediately.
    Assets.LoadAsset(classPath, function(actorClass)
        if not actorClass or IsNotValid(actorClass) then
            Utils.LogBad("[GATE] SpawnNpc: class unavailable: " .. tostring(classPath))
            onSpawned(nil)
            return
        end

        -- Pin the class now that it's loaded. Every later spawn of it resolves from
        -- the cache instead of paying another StaticFindObject object-array walk, and
        -- the class can't GC out from under a mid-assault wave. Capped and no-ops
        -- once the budget is spent (see Utils/AssetKeeper).
        Keeper.PinClass(classPath)

        -- Spawn on a CLEAN game-thread flush point (ExecuteInGameThread), NOT inline
        --   * doSpawn runs inside the tick hook (mid-ProcessEvent)
        --   * spawning a complex NPC there runs its whole construction and BeginPlay
        --       inside our hook which can hang the game thread
        --   * Note: NPC_Monster_Exor froze FinishSpawningActor. It has its own LoadAssets
        -- 
        ExecuteInGameThread(function()
            local world  = UEHelpers.GetWorld()
            local kismet = GetKismetMathLibrary()
            local gs     = GetGameplayStatics()
            if IsNotValid(world) or not kismet or not gs then onSpawned(nil); return end

            local transform = kismet:MakeTransform(location, rotation, FVector(1.0, 1.0, 1.0))

            -- (DEBUG) a "spawn->" with no matching "spawn<-" names the class whose
            -- actor spawn hung the game thread.
            Utils.LogDebug("spawn-> " .. tostring(classPath), CONFIG.DEBUG_LOG)

            -- 2 = AdjustIfPossibleButAlwaysSpawn
            local deferred = gs:BeginDeferredActorSpawnFromClass(world, actorClass, transform, 2, nil, 0)
            if not deferred or IsNotValid(deferred) then onSpawned(nil); return end

            local npc = gs:FinishSpawningActor(deferred, transform, 0)
            Utils.LogDebug("spawn<- " .. tostring(classPath), CONFIG.DEBUG_LOG)
            onSpawned(npc)
        end)
    end)
end

-- ============================================================
-- Spawn a list of NPCs near the assault bench.
--
-- classList  : { classPath, ... }
-- delay      : ms before the first spawn fires
-- opts table :
--   radius        - spawn radius from bench                 [2000]
--   minRadius     - min distance from bench                 [1200]
--   spawnInterval - delay between successive spawns            [500]
--   maxZDelta     - max height diff for nav-point           [250]
--   zClearance    - z-offset above nav point                [100]
--   isGiant       - call ShrinkNavAgent on each NPC         [false]
--   dilationStart - temporarily change NPC's overall speed  [true, or nil to ignore]
--   dilationDelay - ms before restoring dilation to 1.0     [3000]
--   forceAttack   - call ForceAttackTarget(npc,bench)       [false]
--   spawnFx       - Niagara asset path; fires at spawn loc  [nil=none]
--   fxDelay       - delay between FX fire and NPC appearing [0]
--   fxDuration    - delay before the FX is destroyed        [nil=asset lifetime]
--   onSpawned     - function called after dilation/forceAttack are applied
--   pointFinder   - fn(benchLoc, avoidList) -> FVector|nil. Overrides the
--                   default GetSpawnPoint pick, so a caller can impose its own
--                   band/fallback ladder (see EM.DirectDrop). nil result falls
--                   back to the default pick.               [nil]
--   favoredEnemy  - faction NUMBER. Each NPC one-shot locks onto a random NPC
--                   of that faction near the bench, so it opens on a rival
--                   instead of the players.                 [nil = off]
--   favoredRadius - search radius for that                  [2500 = 25m]
-- ============================================================
function Utils.SpawnBenchNPCs(classList, delay, opts)
    opts = opts or {}
    delay = delay or 0

    local isGiant       = opts.isGiant       or false
    local radius        = opts.radius        or 2000
    local minRadius     = opts.minRadius     or 1200
    local interval      = opts.spawnInterval or 500
    local maxZDelta     = opts.maxZDelta     or 250
    local zClearance    = opts.zClearance    or 100
    local dilateStart   = opts.dilationStart
    local dilateDelay   = opts.dilationDelay or 3000
    local forceAttack   = opts.forceAttack   or true
    local spawnFx       = opts.spawnFx
    local fxDelay       = opts.fxDelay       or 100
    local fxDuration    = opts.fxDuration
    local onSpawned     = opts.onSpawned
    local pointFinder   = opts.pointFinder
    local pulseStuck    = opts.pulseStuck    or true
    local pulseInterval = opts.pulseInterval or 25000
    local favoredEnemy  = Utils.ResolveFaction(opts.favoredEnemy)
    local favoredRadius = opts.favoredRadius or 2500

    local spawnedNPCs   = {}
    local targetBench = nil
    local otherBenches  = nil      -- non-target bench locations, resolved once
    local total         = #classList
    local completed     = 0       -- spawn attempts finished (success or fail)
    local pulseStarted  = false

    for i, classPath in ipairs(classList) do
        Utils.QueueSpawn(function()
            if not Utils.IsAssaultHappening() then return end

            local bench, benchLoc = Utils.GetAssaultBench()
            if not benchLoc then return end

            -- Resolve the other-bench avoid list once (cheap to reuse; the
            -- base's bench layout doesn't change mid-assault).
            if not otherBenches then
                otherBenches = Utils.GetOtherBenchLocations(benchLoc)
            end

            if pulseStuck and not targetBench then
                targetBench = benchLoc
            end

            -- A caller-supplied finder wins; nil from it falls through to the
            -- default (which never fails), so a drop is never silently skipped.
            local spawnLoc
            if pointFinder then
                local ok, found = pcall(pointFinder, benchLoc, otherBenches)
                if ok then spawnLoc = found
                else Utils.LogBad("[GATE] SpawnBenchNPCs pointFinder error: " .. tostring(found)) end
            end
            spawnLoc = spawnLoc or Utils.GetSpawnPoint(benchLoc, radius, minRadius,
                                                       nil, maxZDelta, zClearance, otherBenches)
            if not spawnLoc then return end

            -- Fire FX at the chosen location before the NPC appears
            if spawnFx then
                Utils.SpawnEffect(spawnLoc, spawnFx, { duration = fxDuration })
            end

            -- Start the stuck-NPC pulse once every spawn attempt has finished
            -- (success or fail), 5 s after the last one. Uses an attempt counter
            -- (not #spawnedNPCs) so a failed async load can't stall the trigger.
            local function maybeStartPulse()
                if not pulseStuck or pulseStarted then return end
                if completed < total then return end
                if #spawnedNPCs == 0 then return end
                pulseStarted = true
                local loc = targetBench
                Utils.Delay(5000, function()
                    Utils.PulseStuckNPCs(spawnedNPCs, loc, pulseInterval)
                end)
            end

            -- Spawn the NPC immediately or after an FX wind-up delay.
            -- SpawnNpc is async (loads the class on demand); all per-NPC setup
            -- runs in its callback, on the game thread, once the actor exists.
            local function doSpawn()
                if not Utils.IsAssaultHappening() then
                    completed = completed + 1
                    maybeStartPulse()
                    return
                end

                Utils.SpawnNpc(classPath, spawnLoc, nil, function(npc)
                    completed = completed + 1

                    if Utils.IsActorValid(npc) then
                        if isGiant then
                            Utils.ShrinkNavAgent(npc, 15, 160)
                        end

                        if dilateStart then
                            npc.CustomTimeDilation = dilateStart
                            Utils.DelayedGameThread(dilateDelay, function()
                                if Utils.IsActorValid(npc) then
                                    npc.CustomTimeDilation = 1.0
                                end
                            end)
                        end

                        -- Callback fires before forceAttack so faction/state is set first
                        if onSpawned then
                            local ok, err = pcall(onSpawned, npc, bench, spawnLoc)
                            if not ok then
                                Utils.LogBad("[GATE] SpawnBenchNPCs onSpawned error: " .. tostring(err))
                            end
                        end

                        if forceAttack and bench then
                            Utils.ForceAttackTarget(npc, bench)
                        end

                        -- Crossfire: applied LAST so its lock overrides the
                        -- bench aggro above. One-shot, so once this NPC lands a
                        -- hit it falls back to attacking the base.
                        if favoredEnemy then
                            Utils.AggroFavoredEnemy(npc, benchLoc, favoredEnemy, favoredRadius)
                        end

                        if pulseStuck then
                            spawnedNPCs[#spawnedNPCs + 1] = npc
                        end
                    end

                    maybeStartPulse()
                end)
            end

            if fxDelay > 0 then
                Utils.QueueSpawn(doSpawn, fxDelay)
            else
                doSpawn()
            end

        end, delay + (i * interval))
    end
end


-- ============================================================
-- Spawn a Niagara particle effect at a world location.
-- 
-- * Uses NiagaraFunctionLibrary:SpawnSystemAtLocation
-- * Deactivate this effect at opts.Duration, or any looping effect won't end
-- 
-- Returns the component or nil. Returning lets the caller call comp:Deactivate when it wants
--   e.g. EventManager.GatekeeperDrop()
--
-- ============================================================
function Utils.SpawnEffect(location, niagaraPath, opts)
    opts = opts or {}

    -- Lets load the asset but skip this time
    --   If we LoadAsset here it can deadlock, so try and get the asset ready for future calls 
    local system = Assets.GetIfValid(niagaraPath)
    if not system then
        Assets.Warm(niagaraPath)
        Utils.LogBad("[GATE] SpawnEffect() - effect not resident (warming): " .. tostring(niagaraPath))
        return
    end

    local kismet = GetKismetMathLibrary()
    if not kismet then return end

    local rotation = opts.rotation or FRotator(0, 0, 0)
    local scale    = opts.scale    or FVector(1.0, 1.0, 1.0)
    local duration = opts.duration  -- ms; nil = asset-controlled lifetime

    -- Primary path: NiagaraFunctionLibrary gives us a component we can destroy.
    local niagaraLib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
    if niagaraLib and IsValid(niagaraLib) then
        local world = UEHelpers.GetWorld()
        if world and IsValid(world) then
            local ok, comp = pcall(function()
                -- SpawnSystemAtLocation(WorldContext, System, Location, Rotation, Scale,
                --                       bAutoDestroy, bAutoActivate, PoolingMethod, bPreCullCheck)
                --
                -- bAutoDestroy = true: after Deactivate() stops emission UE auto-destroys
                -- the ANiagaraActor once the last particle expires, no extra cleanup needed.
                --
                -- bPreCullCheck = FALSE deliberately. With TRUE the significance manager
                -- can hand back a component that is valid but DORMANT - it renders nothing,
                -- so a portal just silently doesn't appear. The game's own SubFXZone
                -- passes false and force-Activates for the same reason. (Ported from
                -- AnteUp's AVU.SpawnLocalNiagara after a scalability update surfaced it.)
                return niagaraLib:SpawnSystemAtLocation(
                    world, system, location, rotation, scale,
                    true,  -- bAutoDestroy
                    true,  -- bAutoActivate
                    0,     -- ENCPoolMethod::None
                    false  -- bPreCullCheck
                )
            end)
            -- Explicit Activate: belt-and-braces against a pre-culled/deferred spawn.
            -- bReset=true re-runs the emitter spawn scripts, which also makes any USER
            -- param set before this point take effect on a one-shot system.
            if ok and comp and IsValid(comp) then
                pcall(function() comp:Activate(true) end)
            end
            if ok and comp and IsValid(comp) then
                -- Utils.LogDebug("[GATE] SpawnEffect() - NiagaraLib path OK", CONFIG.DEBUG_LOG)
                if opts.sound then Utils.Broadcast2DSound(opts.sound) end
                
                if duration then
                    -- Game thread only: Deactivate() from the delay's worker thread races the
                    -- game thread's GC (and IsValid cannot vouch for a freed wrapper either way).
                    -- The extra hop costs at most a frame on a seconds-long effect.
                    Utils.DelayedGameThread(duration, function()
                        if comp and IsValid(comp) then
                            comp:Deactivate()
                            -- bAutoDestroy handles actor cleanup once particles die.
                        end
                    end)
                end
                return comp  -- caller may hold this to Deactivate() on their own schedule
            end
            Utils.LogDebug("[GATE] SpawnEffect() - NiagaraLib spawn failed", CONFIG.DEBUG_LOG)
        end
    end

    -- No component to hand back. Callers treat nil as "no FX this time".
    return nil
end

-- Shrink a large NPC's nav agent to match the facility nav mesh,
-- and shrink the model a bit (this part isn't necessary)
function Utils.ShrinkNavAgent(actor, radius, height)
    radius = radius or 15
    height = height or 160

    local move = actor.CharacterMovement
    if not (move and IsValid(move)) then return end

    -- Shrink actor slightly
    if move.NavAgentProps.AgentHeight > 300 then
        actor:SetActorScale3D(FVector(0.9, 0.9, 0.9))
    elseif move.NavAgentProps.AgentHeight > 350 then
        actor:SetActorScale3D(FVector(0.8, 0.8, 0.8))
    end

    move.NavAgentProps.AgentRadius = radius
    move.NavAgentProps.AgentHeight = height
end


-- Returns the cloest player to the provided actor
function Utils.ClosestPlayer(actor)
    local all = FindAllOf("Abiotic_PlayerCharacter_C")
    if not all then return nil end
    local npcLoc = actor:K2_GetActorLocation()

    local targetPlayer, closest = nil, math.huge
    for _, p in ipairs(all) do
        if Utils.IsActorAlive(p) then
            local dist = Utils.DistSq(npcLoc, p:K2_GetActorLocation())
            if dist < closest then 
                closest = dist
                targetPlayer = p
            end
        end
    end
    return targetPlayer
end




-- ============================================================
-- Misc
-- ============================================================

-- Wraps ExecuteWithDelay - the callback fires on a UE4SS WORKER thread, so PURE LUA ONLY:
-- no actor/BP calls, no StaticFindObject (a find from this thread is FATAL if it lands during a
-- game-thread GC). Anything that touches the engine goes through Utils.DelayedGameThread.
-- NOTE: ExecuteWithDelay requires an INTEGER delay - a float (e.g. from arithmetic on a
-- decoded value) throws "No overload found", so floor it here to protect all callers.
function Utils.Delay(ms, fn)
    if not fn then return end
    ExecuteWithDelay(math.floor(ms or 0), function()
        if fn then fn() end
    end)
end

-- Wraps a function in ExecuteInGameThread with a pcall guard.
function Utils.RunOnGameThread(fn)
    ExecuteInGameThread(function()
        local ok, err = pcall(fn)
        if not ok then
            Utils.LogBad("[GameThread] " .. tostring(err))
        end
    end)
end

-- Delayed function in game thread.
-- Stuff like spawning NPCs must be done in the game thread
function Utils.DelayedGameThread(ms, fn)
    if not fn then return end

    ExecuteWithDelay(math.floor(ms or 0), function()
        ExecuteInGameThread(function()
            if fn then fn() end
        end)
    end)
end

-- Distance squared from loc to loc
function Utils.DistSq(a, b)
    local dx = (a.X or a.x or 0) - (b.X or b.x or 0)
    local dy = (a.Y or a.y or 0) - (b.Y or b.y or 0)
    local dz = (a.Z or a.z or 0) - (b.Z or b.z or 0)
    return dx*dx + dy*dy + dz*dz -- Multi > Division
end

-- Schedules a function to run on the game thread after a delay (ms)
-- * Delegating a future task to QueueManager
-- * NPC spawning must be queued - 
--      - ExecuteWithDelay callbacks can fire on animation worker threads and
--        spawning an actor there corrupts UE's animation state
function Utils.QueueSpawn(fn, delayMs)
    QM.Queue(fn, delayMs)
end

-- Picks a random location within a radius (square distribution, no navmesh).
function Utils.FuzzLocation(origin, radius)
    local x = origin.X + math.random(-radius, radius)
    local y = origin.Y + math.random(-radius, radius)
    return FVector(math.floor(x + 0.5), math.floor(y + 0.5), math.floor(origin.Z + 0.5))
end


-- ============================================================
-- HasPathTo - can something actually WALK from fromLoc to toLoc?
--
--   * "On the navmesh" and "connected to the bench" are different questions.
--       K2_ProjectPointToNavigation only answers the first - which is how a
--       spawn ends up on a mezzanine or in a sealed room: technically a floor,
--       no route to the bench. This answers the second.
--   * FindPathToLocationSynchronously returns a UNavigationPath. Partial = the
--       pathfinder got as close as it could and gave up, so treat it as no path.
--   * FAILS OPEN. No nav system / call unavailable returns true, so a broken
--       lookup can never silently stop a wave from spawning.
--   * Chosen over GetPathLength deliberately: that one has a `double&` out-param,
--       and a pcall'd out-param call that omits its outs is a SILENT no-op that
--       looks exactly like success.
-- ============================================================
function Utils.HasPathTo(fromLoc, toLoc)
    if not fromLoc or not toLoc then return true end

    local world = UEHelpers.GetWorld()
    if not world or IsNotValid(world) then return true end

    local navSys = FindFirstOf("NavigationSystemV1")
    if not navSys or IsNotValid(navSys) then return true end

    local ok, reachable = pcall(function()
        local path = navSys:FindPathToLocationSynchronously(world, fromLoc, toLoc, nil, nil)
        if not path or IsNotValid(path) then return false end
        if not path:IsValid() then return false end
        return not path:IsPartial()
    end)

    if not ok then return true end   -- call unavailable: don't block the spawn
    return reachable
end


-- Find a reachable navmesh point within [minRadius, radius] of origin.
--   * K2_GetRandomReachablePointInRadius - Leyak/Stalking director's EQS query uses this
--       to place the Leyak. The result has a navigation path from origin, 
--       not just proximity to navmesh objects
--
--   * Fallback: Use K2_ProjectPointToNavigation if retries are exhausted
--   * avoid: optional list of FVector (e.g. non-target crafting benches).
--       Candidates within 600u of any are rejected. If every navigable point
--       found is near one of them, we still return the best navigable point
--       (never a raw off-navmesh fuzz) so the spawn stays on the navmesh.
function Utils.GetSpawnPoint(origin, radius, minRadius, retries, maxZDelta, zClearance, avoid)
    retries    = retries    or 25
    minRadius  = minRadius  or 0
    maxZDelta  = maxZDelta  or 250
    zClearance = zClearance or 100

    if minRadius >= radius then minRadius = 0 end
    if radius <= 0 then radius = 1000 end

    local world = UEHelpers.GetWorld()
    if not world or IsNotValid(world) then
        return Utils.FuzzLocation(origin, radius)
    end

    local navSys = FindFirstOf("NavigationSystemV1")
    if not navSys or IsNotValid(navSys) then
        return Utils.FuzzLocation(origin, radius)
    end

    local minRadiusSq = minRadius * minRadius
    local AVOID_SQ    = 600 * 600
    local fallbackNav = nil       -- best navigable point, even if avoid-rejected
    local function avoided(pt)
        if not avoid then return false end
        for i = 1, #avoid do
            if Utils.DistSq(pt, avoid[i]) < AVOID_SQ then return true end
        end
        return false
    end

    -- Snap origin to navmesh so distance checks are meaningful
    local searchCenter = FVector(origin.X, origin.Y, origin.Z)
    local snapped      = FVector()
    local snappedOk    = navSys:K2_ProjectPointToNavigation(
        world, origin, snapped, nil, nil, FVector(600, 600, 600)
    )
    if snappedOk then searchCenter = snapped end

    -- Primary: reachable-point query. Guarantees the result has a nav path
    -- from searchCenter, matching the reliability of the Leyak EQS approach.
    for _ = 1, retries do
        local candidate = FVector()
        local ok = navSys:K2_GetRandomReachablePointInRadius(
            world, searchCenter, candidate, radius, nil, nil
        )

        if ok then
            local distSq = Utils.DistSq(candidate, searchCenter)
            local zDiff  = math.abs(candidate.Z - searchCenter.Z)

            if distSq >= minRadiusSq and zDiff <= maxZDelta then
                candidate.Z = candidate.Z + zClearance
                if not avoided(candidate) then return candidate end
                fallbackNav = fallbackNav or candidate
            end
        end
    end

    -- Fallback: projection-based search (original method)
    for _ = 1, retries do
        local angle = math.random() * math.pi * 2
        local dist  = math.random(minRadius, radius)

        local pt = FVector(
            searchCenter.X + math.cos(angle) * dist,
            searchCenter.Y + math.sin(angle) * dist,
            searchCenter.Z + 50
        )

        local projected = FVector()
        local ok = navSys:K2_ProjectPointToNavigation(
            world, pt, projected, nil, nil, FVector(300, 300, 400)
        )

        -- The projection extent is 300/300/400, i.e. taller than maxZDelta, so
        -- this rung can and does snap to a mezzanine or the far side of a wall.
        -- Unlike the reachable-point rung above it carries NO connectivity
        -- guarantee, so verify the route to the bench before accepting it.
        if ok and math.abs(projected.Z - searchCenter.Z) <= maxZDelta
           and Utils.HasPathTo(searchCenter, projected) then
            projected.Z = projected.Z + zClearance
            if not avoided(projected) then return projected end
            fallbackNav = fallbackNav or projected
        end
    end

    -- Every navigable point sat near a non-target bench: still prefer a real
    -- navmesh point over a raw fuzz.
    if fallbackNav then return fallbackNav end

    Utils.LogBad("[GATE] GetSpawnPoint() - navmesh projection failed after " .. retries .. " retries; using fallback")
    if snappedOk then
        snapped.Z = snapped.Z + zClearance
        return snapped
    end
    return Utils.FuzzLocation(origin, radius)
end

-- ============================================================
-- GetNavPointInBand - STRICT version of GetSpawnPoint.
--
--   * Returns a reachable navmesh point inside [minRadius, maxRadius] of
--       origin, or NIL if it can't find one.
--   * GetSpawnPoint never fails - it widens, projects, then fuzzes. Right for
--       "put a body near the bench", wrong when the band IS the point
--       (EM.DirectDrop's 5-10m ring). Here the caller decides what a miss means,
--       usually "try a wider band", instead of silently getting a spawn 40m away.
--   * Same reachability guarantee as GetSpawnPoint's primary path: a
--       K2_GetRandomReachablePointInRadius result has a nav PATH from origin.
--
--   opts:
--     retries     candidate draws before giving up               [30]
--     maxZDelta   max height diff from origin                   [250]
--     zClearance  z-offset added to the returned point          [100]
--     avoid       list of FVector to stay 600u away from        [nil]
-- ============================================================
function Utils.GetNavPointInBand(origin, minRadius, maxRadius, opts)
    opts = opts or {}
    local retries    = opts.retries    or 30
    local maxZDelta  = opts.maxZDelta  or 250
    local zClearance = opts.zClearance or 100
    local avoid      = opts.avoid

    minRadius = minRadius or 0
    maxRadius = maxRadius or 1000
    if minRadius >= maxRadius then return nil end

    local world = UEHelpers.GetWorld()
    if not world or IsNotValid(world) then return nil end

    local navSys = FindFirstOf("NavigationSystemV1")
    if not navSys or IsNotValid(navSys) then return nil end

    local minSq, maxSq = minRadius * minRadius, maxRadius * maxRadius
    local AVOID_SQ = 600 * 600

    -- Snap origin to the navmesh so the distance band is measured from a real
    -- nav point, not from a bench that sits 40u above the floor.
    local searchCenter = FVector(origin.X, origin.Y, origin.Z)
    local snapped   = FVector()
    local snappedOk = navSys:K2_ProjectPointToNavigation(
        world, origin, snapped, nil, nil, FVector(600, 600, 600)
    )
    if snappedOk then searchCenter = snapped end

    for _ = 1, retries do
        local candidate = FVector()
        local ok = navSys:K2_GetRandomReachablePointInRadius(
            world, searchCenter, candidate, maxRadius, nil, nil
        )

        if ok then
            local distSq = Utils.DistSq(candidate, searchCenter)
            local zDiff  = math.abs(candidate.Z - searchCenter.Z)

            if distSq >= minSq and distSq <= maxSq and zDiff <= maxZDelta then
                candidate.Z = candidate.Z + zClearance

                local blocked = false
                if avoid then
                    for i = 1, #avoid do
                        if Utils.DistSq(candidate, avoid[i]) < AVOID_SQ then
                            blocked = true
                            break
                        end
                    end
                end

                if not blocked then return candidate end
            end
        end
    end

    return nil
end


-- ============================================================
-- PulseStuckNPCs - periodically checks whether NPCs are on the navmesh
--   * NPCs inside walls or closed-off areas get moved to a valid navmesh point
--   * NPCs merely blocked by deployables are left alone
-- ============================================================
function Utils.PulseStuckNPCs(npcList, benchLoc, interval)
    interval = interval or 30000

    -- ExecuteWithDelay fires on worker threads, so hop to the game thread before
    -- any actor BP call - otherwise the actor can be destroyed between our
    -- IsValid check and the call.
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local world  = UEHelpers.GetWorld()
            local navSys = world and FindFirstOf("NavigationSystemV1")

            local anyAlive = false

            for _, npc in ipairs(npcList) do
                -- Use UE4SS IsValid (no BP call) to avoid crashing on a dying actor
                if not IsValid(npc) or npc.IsDead then goto continue end
                anyAlive = true

                if not world or IsNotValid(world) or not navSys or IsNotValid(navSys) then
                    goto continue
                end

                -- Re-check immediately before each BP call on the actor
                if not IsValid(npc) then goto continue end
                local loc = npc:K2_GetActorLocation()
                local projected = FVector()

                -- LogDebug, not Log: this runs per NPC per pulse for the whole assault.
                Utils.LogDebug(Utils.GetActorName(npc) .. " - OnNav check", CONFIG.DEBUG_LOG)

                -- Large Z extent for larger NPCs
                local onNav = navSys:K2_ProjectPointToNavigation(
                    world, loc, projected, nil, nil, FVector(120, 120, 500)
                )
                if onNav then goto continue end

                -- Not onNav, try to move this NPC
                local moveLoc = Utils.GetSpawnPoint(benchLoc, 2500, 1000)
                if moveLoc then
                    if IsValid(npc) then
                        npc:K2_SetActorLocation(moveLoc, false, {}, false)
                        Utils.Log(string.format("[GATE] PulseStuckNPCs - teleported %s off-navmesh NPC to bench area",
                            Utils.GetActorName(npc)))
                    end
                else
                    moveLoc = Utils.GetSpawnPoint(benchLoc, 1000, 500)
                    if moveLoc and IsValid(npc) then
                        npc:K2_SetActorLocation(moveLoc, false, {}, false)
                        Utils.Log(string.format("[GATE] PulseStuckNPCs - teleported %s off-navmesh NPC to bench area",
                            Utils.GetActorName(npc)))
                    end
                end

                ::continue::
            end

            if anyAlive then
                Utils.Delay(interval, function()
                    Utils.PulseStuckNPCs(npcList, benchLoc, interval)
                end)
            end
        end)

        if not ok then
            Utils.LogBad("[GATE] PulseStuckNPCs - error: " .. tostring(err))
        end
    end)
end


function Utils.VecOff(v, x, y, z)
    return FVector(v.X + (x or 0), v.Y + (y or 0), v.Z + (z or 0))
end

function Utils.MakeActorFaceTarget(actor, target)
    if Utils.IsActorInvalid(actor) then return end
    if Utils.IsActorInvalid(target) then return end

    local targetLoc = target:K2_GetActorLocation()
    local actorLoc = actor:K2_GetActorLocation()
    local yaw  = math.deg(math.atan(targetLoc.Y - actorLoc.Y, targetLoc.X - actorLoc.X))
    actor:K2_SetActorRotation(FRotator(0, yaw, 0), false)

end


function Utils.GetNearbyActorClass(loc, radius, actorClass)
    radius = radius or 10000
    local kismet = UEHelpers.GetKismetSystemLibrary()
    local world  = UEHelpers.GetWorld()
    if not kismet or not world or not actorClass then return {} end
    local nearby = {}
    kismet:SphereOverlapActors(world, loc, radius, {}, actorClass, {}, nearby)
    return nearby
end


function Utils.MergeTables(dest, src)
    for rowKey, entries in pairs(src) do
        if not dest[rowKey] then
            dest[rowKey] = {}
        end
        for _, entry in ipairs(entries) do
            table.insert(dest[rowKey], entry)
        end
    end
end


-- ============================================================
-- PreloadAssets - DEPRECATED
--   954: preloading doesn't work - assets load fine but UE GCs 
--   and LoadAsset can't be called synchronously from a spawn hook. 
--   Loading is now on-demand via Utils.AssetManager 
-- ============================================================
function Utils.PreloadAssets()
    -- see Utils.AssetManager
end


-- Force save - works around the exit-to-main-menu rollback.
--   * Most ue4ss + AbioticFactor mods hit a GC error on exiting a world to the
--     main menu, more likely the longer the game has run and the more you've
--     been doing with actors
--   * Per the UE4SS developer, AbioticFactor is unusually Blueprint-dominant and
--     the resulting friction is unlikely to get fixed
--   * The symptom: the world files save but the character rolls back a bit
--   * So: force a save here, including on the way out to the main menu
function Utils.SaveGame()
    local controller = FindFirstOf("Abiotic_PlayerController_C")
    if not controller or IsNotValid(controller) then
        Utils.Chat("[GATE] ForceSave: no player controller")
        return
    end

    local pawn = controller.MyPlayerCharacter
    if pawn and IsValid(pawn) then
        local ps = pawn.MyPlayerState
        if ps and IsValid(ps) then
            local loc = pawn:K2_GetActorLocation()
            pcall(function()
                ps.CurrentPlayerSaveData.LastSafeWorldLocation_30_486FB66C419E431BD6B754B0C04C9F5B = loc
            end)
        end
    end

    controller:SaveCharacter()
    if IsHost() then
        controller:Request_ForceWorldSave()
    end
end

-- ============================================================
-- Modify damage dealt to structures
-- ============================================================

function Utils.GetDeployableDamageMultiplier(deployable)
    local multiplier = CONFIG.DEPLOYABLE_DAMAGE_MULTIPLIER
    if not multiplier then return 1 end
    
    if IsNotValid(deployable) then return 1 end
    
    local name = deployable:GetClass():GetFullName():lower()
    -- Utils.LogDebug(name, CONFIG.DEBUG_LOG)
    
    if not name then
        Utils.LogDebug("[GATE] GetDeployableDamageMultiplier() - failed to get name", CONFIG.DEBUG_LOG)
        return 1
    end
    

    -- DEFENSE: Barricades
    if name:find("barricade") or 
        name:find("bagwall") then
        return multiplier.Barricade or 1

    -- TURRETS 
    elseif name:find("turret") or
        name:find("teslacoil") then
        return multiplier.Turrets or 1
    
    -- BENCHES
    elseif name:find("bench") or 
         name:find("craftedbed") then
        return multiplier.Bench or 1
    
    -- -- STORAGE 
    -- elseif name:find("storage") or
    --     name:find("crate") or
    --     name:find("refrigerator") or
    --     name:find("freezer") or
    --     name:find("shelf") or
    --     name:find("aquarium") or
    --     name:find("gardenplot")
    --  then
    --     return multiplier.Storage or 1
    -- Other furniture
    
    else
        return multiplier.Other or 1
    end
end

-- ============================================================
-- Forces a Snowman NPC to attack players outside the VWinter event zone.
--
-- Root cause (from AI_Controller_NPC_Snowman_C source):
--   CheckCombatTargetValidity() only accepts targets with the
--   "Character.SnowmanZone" gameplay tag. 
--   Otherwise BTS_ChooseBestTarget resets 
--
-- ============================================================

function Utils.HandleSnowman(npc)
    Utils.SetNPCSenseEnabled(npc, "Sight", true)
    Utils.SetNPCSenseEnabled(npc, "Hearing", true)

    npc.Faction = 5

    -- Register snowman hook
    if not STATE.IsSnowmanHookRegistered then
        STATE.IsSnowmanHookRegistered = true

        -- The Snowman checks for a gameplayTag on a player (Character.SnowmanZone) or it won't attack 
        -- We need to override this
        --   * As far as I know we can't create Gameplay tags
        RegisterHook(
            "/Game/Blueprints/Characters/NPCs/AI_Controller_NPC_Snowman.AI_Controller_NPC_Snowman_C:CheckCombatTargetValidity",
            function(_, targetParam, _, validParam)
                local ok, err = pcall(function()
                    local target = targetParam:get()
                    if not target or IsNotValid(target) then return end
                    local ps = target.PlayerState
                    if not ps or IsNotValid(ps) then return end
                    validParam:set(true)
                end)
                if not ok then
                    Utils.LogBad("[GATE-HOOK] Snowman CheckCombatTargetValidity: " .. tostring(err))
                end
                -- if above is not working
                -- return false
            end
        )
        Utils.LogDebug("[GATE] Snowman CheckCombatTargetValidity hook registered", CONFIG.DEBUG_LOG)
    end

    local director = FindFirstOf("Abiotic_AIDirector_C")
    if director and IsValid(director) then
        director:AlertNPCToNearbyPlayers(npc)
    end

    local aiLib     = StaticFindObject("/Script/AIModule.Default__AIBlueprintHelperLibrary")
    local aggroTick = 0
    local prevDBNO  = false

    local function snowmanTick()
        if Utils.IsActorInvalid(npc) or npc.IsDead then return end
        if aggroTick > 3000 then return end
        aggroTick = aggroTick + 1

        local ok, err = pcall(function()
            local controller = npc:GetController()
            if IsNotValid(controller) then return end

            local isDBNO = npc.IsDBNO

            -- prevent idle lock, teleport loop, visibility clear
            if IsValid(aiLib) then
                local bb = aiLib:GetBlackboard(controller)
                if IsValid(bb) then
                    bb:SetValueAsInt  (FName("PotentialCombatTargetCount"), 1)
                    bb:SetValueAsBool (FName("CanSeeTarget"), true)
                    bb:SetValueAsInt  (FName("FailedHits"), 0)
                end
            end

            -- Re-engage after DBNO exits
            if prevDBNO and not isDBNO then
                pcall(function() controller:PerformCombatEngage() end)
            end
            prevDBNO = isDBNO

            -- Slow path: explicitly set target every ~1s; BTS_ChooseBestTarget
            -- would otherwise clear it (CheckCombatTargetValidity is overridden
            -- in AssaultHooks to accept players)
            if not isDBNO and aggroTick % 5 == 0 then
                local target = Utils.ClosestPlayer(npc)
                if target then
                    Utils.ForceAttackTarget(npc, target, true)
                end
            end
        end)
        if not ok then
            Utils.LogBad("[GATE-SNOWMAN] tick error: " .. tostring(err))
        end

        Utils.DelayedGameThread(1500, snowmanTick)
    end

    Utils.DelayedGameThread(1500, function()
        if not Utils.IsActorAlive(npc) then return end
        local controller = npc:GetController()
        if IsNotValid(controller) then return end
        pcall(function() controller:PerformCombatEngage() end)
        snowmanTick()
    end)
end


-- ============================================================
-- Enable or disable a specific sense on an NPC's AIPerceptionComponent.
-- * "Sight", "Hearing", "Smell"
-- * Mostly using this for Symphonists, so they don't stall out on furniture
-- * Slight delay because the Symphonist will disable its senses after creation
-- ============================================================

function Utils.SetNPCSenseEnabled(npc, senseType, enabled)

    Utils.DelayedGameThread(500, function()
        if not npc or IsNotValid(npc) then return end

        local perc = npc.AIPerception
        if not perc or IsNotValid(perc) then return end

        local senseClass
        if senseType == "Sight" then
            senseClass = StaticFindObject("/Script/AIModule.AISense_Sight")
        elseif senseType == "Hearing" then
            senseClass = StaticFindObject("/Script/AIModule.AISense_Hearing")
        elseif senseType == "Smell" then
            senseClass = StaticFindObject("/Game/Blueprints/Characters/NPCs/AISense_Smell.AISense_Smell_C")
        end

        if not senseClass or IsNotValid(senseClass) then
            Utils.LogBad("[SetNPCSenseEnabled] sense class not found for: " .. tostring(senseType))
            return
        end

        perc:SetSenseEnabled(senseClass, enabled)
    end)
end


-- ============================================================
-- Toggle some settings from CONFIG
-- ============================================================

function Utils.DisableAssaultRebalancing()
    Utils.Log("MAIN - DISABLING ASSAULT REBALANCING")
    CONFIG.ASSAULT_TIMEOUT = 150
    CONFIG.ASSAULT_NPCS_RUN = false

    CONFIG.DEPLOYABLE_DAMAGE_MULTIPLIER = {
            Barricade   = 1,    -- Defensive walls
            Turrets     = 1,    -- Turrets (+ Tesla Coils)
            Bench       = 1,  -- Benches, Beds
            Storage     = 1,    -- Boxes, fridges, shelves
            Other       = 1,    -- Other stuff
    }

    CONFIG.FURNITURE_DESTRUCTION = nil
end

function Utils.ToggleFurnitureDestruction()
    
    if CONFIG.FURNITURE_DESTRUCTION ~= nil then
        local gameState = AFUtils.GetSurvivalGameState()
        if gameState and IsValid(gameState) then
            local ok, err = pcall(function()
                gameState:SetSandboxOption_Bool(
                    FName("PlayerFurnitureDestruction"),
                    CONFIG.FURNITURE_DESTRUCTION == true
                )
            end)
            if ok then
                Utils.Log("[GATE] PlayerFurnitureDestruction = " .. tostring(CONFIG.FURNITURE_DESTRUCTION))
            else
                Utils.LogBad("[GATE] SetSandboxOption_Bool failed (PlayerFurnitureDestruction): " .. tostring(err))
            end
        end
    end
end

return Utils
