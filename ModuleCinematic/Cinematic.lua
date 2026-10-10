-- =======================================================================
-- ModuleCinematic (DEV) - staging tools for recording video. Hold NPCs still, strip a
-- variant back to its vanilla body and mutate it again on camera, and put the scene
-- back when the shot is done.
--
--   [CTRL][Left/Right] to "(90) Cinema" or "(91) Cinema II", then numpad 1-9 (AnDebug/Keybinds).
--   "/au-cine <verb>" runs the same verbs by name - and is how a CLIENT reaches them.
--   "/au-cine" with no argument lists them.
--
-- MUST-KNOWS
--   * AUTHORITY. Every verb drives AI, spawns or destroys. A client's keybind bridges to
--     "/au-cine" and the SERVER runs it around the sender's pawn.
--   * "Target" is the NPC nearest the CENTRE of your view, not a line trace. A trace on the
--     Pawn channel misses thin bodies and catches held weapons; a cone pick answers the
--     question you actually asked.
--   * `staged` holds strings and numbers only, keyed by ActorKey - never an actor wrapper.
--     A stale key simply never matches; a stale wrapper is a freed-pointer crash.
--   * Unmutate DESTROYS and RESPAWNS. There is no inverse of def.Visuals, so the body swap
--     is the honest revert - and Mutate then runs the real pipeline on the new body, which
--     is the thing worth filming.
--   * A stuck LockedInPlaceMontage is an NPC that never moves again, so `release` sits on
--     numpad 9 of BOTH groups.
--
-- Deep: AnNotes/Modules/Cinematic.md
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local AFUtils      = require("AFUtils.AFUtils")
local Utils        = require("AnteUtils.Utils")
local AVU          = require("AnteUtils.AVUtils")
local AVM          = require("AnteUtils.AVMath")
local ENUMS        = require("AnteData.Enums")
local VARIANTS     = require("AnteVariants.Variants")
local VariantTag   = require("AnteVariants.VariantTag")
local NpcSpawner   = require("AnteCore.NpcSpawner")
-- NpcManager is required lazily inside mutate(): the load cycle it sits in
-- (Variants -> a def file -> AVUtils -> NpcManager -> Variants) makes a top-level require here
-- order-dependent, and it is always loaded by the time a keybind fires.

local CINE = {}


-- =======================================================================
-- KNOBS
-- =======================================================================

local K = {
    AimRange   = 6000,   -- how far the view-cone pick reaches
    AimCos     = 0.978,  -- cos(12 deg) - forgiving enough for a nudge, tight enough to pick one body
    EyeZ       = 60,     -- eye height above the pawn root, so the ray starts where you look from
    BodyZ      = 50,     -- score an NPC's chest, not its feet

    RadiusMaxZ = 600,    -- ~one storey. A sphere overlap reaches the balcony above otherwise
    AreaCap    = 50,     -- most bodies one radius verb will touch (unmutate = N destroys + N spawns)
    ReleaseUu  = 10000,  -- how far `release` sweeps for staged bodies - far past any shot

    SettleMs   = 800,    -- a respawned body falls to the floor before the hold is re-asserted
    MutateMs   = 2500,   -- the pipeline runs across several drains; re-hold once it has landed
    AttackMs   = 30000,  -- how long "attack me" keeps re-asserting the lock
    TurnDeg    = 45,

    -- The statue's time dilation. NOT 0: AActor::SetActorTimeDilation clamps its argument to
    -- KINDA_SMALL_NUMBER, so 0 is outside the contract the engine will hand this property. At
    -- 1e-4 an animation advances one frame per few hours, which is a statue by any measure.
    StatueTdi  = 0.0001,
}

-- Session knobs, not per-world: a radius you set mid-shoot should survive a zone change.
local radius      = 7500
local lastVariant = nil   -- last variant summoned this session - what `reskin` mutates into

-- ActorKey -> what WE changed on that body, so release can put it back.
--   held    the HoldStill park
--   statue  the CustomTimeDilation we replaced (never the 0 we wrote)
--   hidden  we hid it
--   variant what it was before an unmutate, so Mutate knows what to build
local staged = {}


-- =======================================================================
-- Feedback + lookup
-- =======================================================================

-- Local chat echo. Safe from a keybind because keybind work is queued onto the clean game-tick
-- drain (AnDebug/Keybinds `bind`), never run inside the Slate-tick intercept. No-ops on a
-- dedicated server, where the log line is the only record.
local function say(msg)
    Utils.Log(msg)
    if Utils.HasRenderer() then pcall(function() AFUtils.DisplayTextChatMessage(msg) end) end
end

-- Variant name for a tag Id. A linear scan rather than a cached map, deliberately: /reload
-- refills the registry in place, and a snapshot taken at load would hand back stale defs.
local function variantNameById(id)
    if not id then return nil end
    for name, def in pairs(VARIANTS) do
        if def.Id == id then return name end
    end
    return nil
end

local function rec(key)
    local r = staged[key]
    if not r then r = {}; staged[key] = r end
    return r
end

local function isHeld(npc)
    local key = Utils.ActorKey(npc)
    local r = key and staged[key]
    return r ~= nil and r.held == true
end


-- =======================================================================
-- Who you are pointing at
--   The aim ray is the pawn's eye + its CONTROL rotation, on every role. It is what the game
--   itself aims with, it is replicated to the server (so the chat bridge works from a dedicated
--   server), and it needs no camera manager - one code path instead of two.
-- =======================================================================

local function aimNpc(pawn)
    if Utils.IsActorInvalid(pawn) then return nil end

    local eye, fwd
    pcall(function()
        local at = pawn:K2_GetActorLocation()
        eye = FVector(at.X, at.Y, at.Z + K.EyeZ)
        fwd = AVM.ForwardFromRotator(pawn:GetControlRotation())
    end)
    if not eye or not fwd then return nil end

    local list = AVU.GetNearbyNpcs(eye, K.AimRange, {})
    local best, bestCos
    for i = 1, #list do
        local npc = list[i]
        local ok, at = pcall(function() return npc:K2_GetActorLocation() end)
        if ok and at then
            local c = AVM.AimCos(eye, fwd, FVector(at.X, at.Y, at.Z + K.BodyZ))
            if c >= K.AimCos and (not bestCos or c > bestCos) then best, bestCos = npc, c end
        end
    end
    return best
end

-- Live NPCs around the pawn, capped. maxZ keeps the sweep on your own floor - without it a 20m
-- sphere pulls in the garrison on the balcony, which is never what a staged shot wants.
local function nearNpcs(pawn, uu, cap)
    if Utils.IsActorInvalid(pawn) then return {}, 0 end
    local at = pawn:K2_GetActorLocation()
    if not at then return {}, 0 end

    local list = AVU.GetNearbyNpcs(at, uu or radius, { maxZ = K.RadiusMaxZ })
    cap = cap or K.AreaCap
    if #list <= cap then return list, 0 end

    -- Overlap order is arbitrary; over the cap, drop the far edge rather than whoever is in frame.
    local dist = {}
    for i = 1, #list do
        local ok, npcAt = pcall(function() return list[i]:K2_GetActorLocation() end)
        dist[list[i]] = (ok and npcAt) and Utils.DistSq(at, npcAt) or math.huge
    end
    table.sort(list, function(a, b) return dist[a] < dist[b] end)

    local out = {}
    for i = 1, cap do out[i] = list[i] end
    return out, #list - cap
end

-- A tamed pet is the player's, not scenery. Freezing or posing one is fine; DESTROYING one is
-- not, so the swap verbs skip it.
--   * The bare field read, not AVU.GetFollowerBuff: that one falls back to a FindAllOf when the
--     cache is cold, and a radius sweep would pay for that per body. This is the same O(1) test
--     MutateActor's own pet guard uses, so the two agree on what a pet is.
local function isPet(npc)
    local buff
    pcall(function() buff = npc.CachedFollowerBuffActor end)
    return buff ~= nil and IsValid(buff)
end


-- =======================================================================
-- Per-body primitives
-- =======================================================================

-- HoldStill parks the whole behaviour tree AND sets the controller's `Stationary` flag - the
-- half that stops a standing NPC swivelling to keep you in front of it.
local function hold(npc, on)
    AVU.HoldStill(npc, on)
    local key = Utils.ActorKey(npc)
    if not key then return end
    if on then rec(key).held = true
    elseif staged[key] then staged[key].held = nil end
end

-- Statue = the hold PLUS a stopped actor clock: no idle animation, no montage, no turn at all.
-- CustomTimeDilation is server-local, which is exactly right for a single-machine recording.
--   * The prior value is stashed because a variant's def.TimeDilation is often not 1. A value at
--     or under the statue floor is never stashed - it is one of ours, or near enough, and
--     restoring it would leave the body frozen for good.
--   * Off releases the hold too: "statue off" means fully released, not half.
local function statue(npc, on)
    local key = Utils.ActorKey(npc)
    if not key then return end
    local r = rec(key)

    if on then
        if r.statue == nil then
            local prior = 1
            pcall(function() prior = tonumber(npc.CustomTimeDilation) or 1 end)
            r.statue = (prior > K.StatueTdi) and prior or 1
        end
        hold(npc, true)
        pcall(function() npc.CustomTimeDilation = K.StatueTdi end)
    else
        -- Only write a dilation we actually replaced. Writing a bare 1 here would quietly erase
        -- a variant's own def.TimeDilation on any body we never statued.
        if r.statue ~= nil then pcall(function() npc.CustomTimeDilation = r.statue end) end
        r.statue = nil
        hold(npc, false)
    end
end

local function isStatue(npc)
    local key = Utils.ActorKey(npc)
    local r = key and staged[key]
    return r ~= nil and r.statue ~= nil
end

-- bHidden replicates, so this reaches every machine. Deliberately NOT IsGibbed, which also hides
-- a living NPC but drags its death/loot state along with it.
local function hide(npc, on)
    pcall(function()
        npc:SetActorHiddenInGame(on == true)
        Utils.MarkReplicatedDirty(npc, "bHidden")
    end)
    local key = Utils.ActorKey(npc)
    if not key then return end
    if on then rec(key).hidden = true
    elseif staged[key] then staged[key].hidden = nil end
end

-- Set an NPC's yaw and make it stick: the actor rotation alone is overwritten by the controller
-- on its next pass, so the control rotation goes with it (same pairing as AVU.FaceTarget).
local function setYaw(npc, yaw)
    pcall(function()
        local face = FRotator(0, yaw, 0)
        npc:K2_SetActorRotation(face, false)
        local c = npc:GetController()
        if IsValid(c) then c:SetControlRotation(face) end
    end)
end

-- Undo everything we did to one body - and only what WE did. An unconditional unlock here would
-- also break a variant's own scripted aggro lock, which is nothing to do with staging.
local function releaseBody(npc, r)
    if r.statue ~= nil then pcall(function() npc.CustomTimeDilation = r.statue end) end
    if r.hidden then hide(npc, false) end
    if r.held then AVU.HoldStill(npc, false) end
    if r.locked then AVU.UnlockAggro(npc) end
end

-- Drop everything we staged on one body, then send it at `pawn`. The record is rebuilt with just
-- the lock, so a later `release` can call the fight off again.
local function sendAt(npc, pawn)
    local key = Utils.ActorKey(npc)
    local r = key and staged[key]
    if r then releaseBody(npc, r); staged[key] = nil end

    AVU.LockAggro(npc, pawn, { HoldMs = K.AttackMs })
    if key then rec(key).locked = true end
end


-- =======================================================================
-- Target vs radius
--   Every verb is one of these two shapes, so the fan-out lives here once.
-- =======================================================================

local function onTarget(pawn, fn)
    local npc = aimNpc(pawn)
    if not npc then say("Cine: nothing in your crosshairs"); return nil end
    fn(npc)
    return npc
end

-- `fn` returns truthy for a body it actually acted on, so the count reported is what HAPPENED,
-- not how many bodies were in range - the difference between "swapped 3" and "swept 8, most of
-- them vanilla already".
local function onRadius(pawn, fn)
    local list, dropped = nearNpcs(pawn)
    local n = 0
    for i = 1, #list do
        if fn(list[i]) then n = n + 1 end
    end
    return n, dropped, #list
end

-- What a radius toggle should DO. Toggling each body against its own state lets a group drift
-- out of step and you can never get them all frozen at once, so the group moves together: if
-- anything is still loose, freeze; only when they are all held does the key release them.
local function anyLoose(list, test)
    for i = 1, #list do
        if not test(list[i]) then return true end
    end
    return false
end

local function areaToggle(pawn, test, apply, onWord, offWord)
    local list, dropped = nearNpcs(pawn)
    if #list == 0 then say("Cine: no NPCs within " .. math.floor(radius / 100) .. "m"); return end

    local on = anyLoose(list, test)
    for i = 1, #list do apply(list[i], on) end
    say(string.format("Cine: %s %d%s (%dm)", on and onWord or offWord, #list,
        dropped > 0 and (" [+" .. dropped .. " over the cap]") or "", math.floor(radius / 100)))
end


-- =======================================================================
-- Mutation showcase
--   Unmutate replaces the body; Mutate runs the real pipeline on what is left standing.
-- =======================================================================

-- `quiet` suppresses the per-body chatter for the radius sweep, which would otherwise print a
-- line for every vanilla NPC in the room. Returns true if a body was actually swapped.
local function unmutate(npc, quiet)
    local function nope(msg)
        if not quiet then say(msg) end
        return false
    end

    if isPet(npc) then return nope("Cine: that one is somebody's pet - not swapping it") end

    local id   = VariantTag.Decode(npc)
    local name = variantNameById(id)
    if not name then return nope("Cine: " .. tostring(Utils.GetActorName(npc)) .. " is not an Antevariant") end

    -- The body's ACTUAL row, not def.Base. A SpawnAs variant stands on a different row than its
    -- nominal base (a Signal Pest is really a Pest_Volatile), and the vanilla version of what was
    -- standing there is that row - full-strength, which is why the new body is frozen on arrival.
    local row = Utils.GetActorRowName(npc)
    if not row or not ENUMS.NpcClasses[row] then
        return nope("Cine: no spawnable class for row " .. tostring(row))
    end

    local loc, rot
    pcall(function()
        loc = npc:K2_GetActorLocation()
        rot = npc:K2_GetActorRotation()
    end)
    if not loc then return false end

    local key = Utils.ActorKey(npc)
    if key then staged[key] = nil end
    pcall(function() npc:K2_DestroyActor() end)

    NpcSpawner.SpawnNpc(row, loc, {
        Rotation    = rot,
        SkipSpawnFX = true,   -- no arrival burst: this should read as "it was always standing here"
        NoLift      = true,   -- the coord came off a live root, already clear of the floor
        callback    = function(body)
            hold(body, true)
            local k = Utils.ActorKey(body)
            if k then rec(k).variant = name end
            -- A scaled-up variant's root sits higher than its vanilla twin's, so the new body has
            -- a short fall. Re-assert once it has landed.
            Utils.QueueWork(function()
                if Utils.IsActorInvalid(body) then return end
                hold(body, true)
            end, K.SettleMs)
        end,
    })
    if not quiet then say(string.format("Cine: %s -> vanilla %s, frozen", name, row)) end
    return true
end

local function mutate(npc, want, opts, quiet)
    local function nope(msg)
        if not quiet then say(msg) end
        return false
    end

    local key = Utils.ActorKey(npc)
    local name = want or (key and staged[key] and staged[key].variant) or lastVariant
    if not name or not VARIANTS[name] then
        return nope("Cine: nothing to mutate into - unmutate a variant first, or /au-cine mutate <name>")
    end
    if VariantTag.Decode(npc) then
        return nope("Cine: " .. tostring(Utils.GetActorName(npc)) .. " is already an Antevariant")
    end

    local wasHeld = isHeld(npc)
    require("AnteVariants.NpcManager").MutateActor(name, npc, opts or {})

    -- The pipeline runs across several drains and ends in the visuals; re-assert the hold after
    -- it lands, so the finished variant is still standing where you framed it.
    if wasHeld then
        Utils.QueueWork(function()
            if Utils.IsActorInvalid(npc) then return end
            hold(npc, true)
        end, K.MutateMs)
    end
    if not quiet then say("Cine: mutating -> " .. name) end
    return true
end


-- =======================================================================
-- VERBS - the whole feature surface. The keybind groups and /au-cine both index this.
-- =======================================================================

local VERBS
VERBS = {
    freeze = { Help = "freeze/unfreeze the NPC in your crosshairs", Run = function(pawn)
        onTarget(pawn, function(npc)
            local on = not isHeld(npc)
            hold(npc, on)
            say("Cine: " .. (on and "froze " or "released ") .. tostring(Utils.GetActorName(npc)))
        end)
    end },

    freezearea = { Help = "freeze/unfreeze every NPC within the radius", Run = function(pawn)
        areaToggle(pawn, isHeld, hold, "froze", "released")
    end },

    statue = { Help = "stop the crosshair NPC's clock outright (mid-animation)", Run = function(pawn)
        onTarget(pawn, function(npc)
            local on = not isStatue(npc)
            statue(npc, on)
            say("Cine: " .. (on and "froze solid " or "released ") .. tostring(Utils.GetActorName(npc)))
        end)
    end },

    statuearea = { Help = "stop every NPC's clock within the radius", Run = function(pawn)
        areaToggle(pawn, isStatue, statue, "froze solid", "released")
    end },

    faceme = { Help = "turn the crosshair NPC to look at you", Run = function(pawn)
        onTarget(pawn, function(npc)
            AVU.FaceTarget(npc, pawn)
            say("Cine: facing you")
        end)
    end },

    turn = { Help = "yaw the crosshair NPC 45 degrees (negative arg turns the other way)",
        Run = function(pawn, arg)
            local step = tonumber(arg) or K.TurnDeg
            onTarget(pawn, function(npc)
                local yaw
                pcall(function() yaw = npc:K2_GetActorRotation().Yaw end)
                if not yaw then return end
                setYaw(npc, yaw + step)
                say(string.format("Cine: turned %+d deg", math.floor(step + 0.5)))
            end)
        end },

    attack = { Help = "release the crosshair NPC and send it at you", Run = function(pawn)
        onTarget(pawn, function(npc)
            sendAt(npc, pawn)
            say("Cine: " .. tostring(Utils.GetActorName(npc)) .. " is coming for you")
        end)
    end },

    attackarea = { Help = "release everything within the radius and send it at you", Run = function(pawn)
        local n, dropped = onRadius(pawn, function(npc) sendAt(npc, pawn); return true end)
        say(string.format("Cine: %d incoming%s", n,
            dropped > 0 and (" [+" .. dropped .. " over the cap]") or ""))
    end },

    hide = { Help = "hide/show the crosshair NPC (replicated)", Run = function(pawn)
        onTarget(pawn, function(npc)
            local key = Utils.ActorKey(npc)
            local on = not (key and staged[key] and staged[key].hidden)
            hide(npc, on)
            say("Cine: " .. (on and "hid " or "revealed ") .. tostring(Utils.GetActorName(npc)))
        end)
    end },

    unmutate = { Help = "swap the crosshair variant for its frozen vanilla body", Run = function(pawn)
        onTarget(pawn, unmutate)
    end },

    mutate = { Help = "mutate the crosshair NPC back into its remembered variant (or <name>)",
        Run = function(pawn, arg)
            local want = arg and arg ~= "" and arg or nil
            if want and not VARIANTS[want] then
                for k in pairs(VARIANTS) do
                    if k:lower() == want:lower() then want = k; break end
                end
            end
            if want and not VARIANTS[want] then say("Cine: unknown variant " .. want); return end
            if want then lastVariant = want end
            onTarget(pawn, function(npc) mutate(npc, want) end)
        end },

    reskin = { Help = "mutate the crosshair NPC into the last variant you summoned", Run = function(pawn)
        if not lastVariant then say("Cine: summon a variant first, or /au-cine mutate <name>"); return end
        onTarget(pawn, function(npc) mutate(npc, lastVariant) end)
    end },

    unmutatearea = { Help = "swap every variant within the radius for its vanilla body", Run = function(pawn)
        local n, dropped, seen = onRadius(pawn, function(npc) return unmutate(npc, true) end)
        say(string.format("Cine: unmutated %d of %d%s", n, seen,
            dropped > 0 and (" [+" .. dropped .. " over the cap]") or ""))
    end },

    mutatearea = { Help = "mutate every remembered body within the radius", Run = function(pawn)
        -- Stagger: several pipelines landing their attach bursts in one frame is a visible hitch,
        -- and that is exactly what the spawner path's stagger flag exists for.
        local n, dropped, seen = onRadius(pawn, function(npc)
            return mutate(npc, nil, { Stagger = true }, true)
        end)
        say(string.format("Cine: mutated %d of %d%s", n, seen,
            dropped > 0 and (" [+" .. dropped .. " over the cap]") or ""))
    end },

    -- The one verb that scans wide, and the only one that costs anything: matching bodies to
    -- records means a GetFullName per NPC in range, which is not cheap in a crowd. Fine for a
    -- key you press between takes; never put it on a cadence.
    release = { Help = "unfreeze, unhide and unlock every staged NPC in range", Run = function(pawn)
        if Utils.IsActorInvalid(pawn) then return end
        if next(staged) == nil then say("Cine: nothing staged"); return end
        local at = pawn:K2_GetActorLocation()
        if not at then return end

        local n = 0
        local list = AVU.GetNearbyNpcs(at, K.ReleaseUu, {})
        for i = 1, #list do
            local npc = list[i]
            local key = Utils.ActorKey(npc)
            local r = key and staged[key]
            if r then releaseBody(npc, r); staged[key] = nil; n = n + 1 end
        end

        -- Whatever is left is out of range, not forgotten: keep the records so a release run in
        -- that room still finds those bodies. An orphaned hold is the one failure worth carrying
        -- a little bookkeeping to avoid.
        local left = 0
        for _ in pairs(staged) do left = left + 1 end
        say(string.format("Cine: released %d%s", n,
            left > 0 and (" (" .. left .. " staged out of range)") or ""))
    end },

    radius = { Help = "set the radius verbs' reach, in metres", NoPawn = true, Run = function(_, arg)
        local m = tonumber(arg)
        if m and m > 0 then radius = math.floor(m * 100) end
        say("Cine: radius " .. math.floor(radius / 100) .. "m")
    end },

    list = { Help = "log every verb", NoPawn = true, Run = function()
        local names = {}
        for k in pairs(VERBS) do names[#names + 1] = k end
        table.sort(names)
        for _, k in ipairs(names) do Utils.Log(string.format("  /au-cine %-13s %s", k, VERBS[k].Help)) end
        say("Cine: " .. #names .. " verbs listed in the log")
    end },
}


-- =======================================================================
-- Public
-- =======================================================================

-- Per world. The keys are GetFullName strings, which a new world can re-issue, so a carried-over
-- record could claim a body we never touched.
function CINE.Register()
    for k in pairs(staged) do staged[k] = nil end
end

-- Remember what a summon spawned, so `reskin` has something to build. Called by the summon paths
-- (AnDebug/Keybinds), not by the pipeline - this is "what did the DEV last ask for".
function CINE.NoteVariant(name)
    if name and VARIANTS[name] then lastVariant = name end
end

-- AUTHORITY. `pawn` anchors the verb: its aim picks the target, its position centres the radius.
function CINE.Do(verb, pawn, arg)
    if not Utils.IsAuthority() then return end
    local v = VERBS[verb]
    if not v then say("Cine: unknown verb " .. tostring(verb)); return end
    if not v.NoPawn and Utils.IsActorInvalid(pawn) then return end
    local ok, err = pcall(v.Run, pawn, arg)
    if not ok then Utils.LogBad("Cine: " .. verb .. " failed - " .. tostring(err)) end
end

-- Keybind entry. The authority runs it directly; a CLIENT bridges to /au-cine so the server does
-- the work around the sender's pawn - the same split as every other keybind in AnDebug.
function CINE.Key(verb)
    if not Utils.IsAuthority() then
        local pc = AFUtils.GetMyPlayerController()
        if IsValid(pc) then pc:Request_SendTextChatMessage("/au-cine " .. verb) end
        return
    end
    CINE.Do(verb, AFUtils.GetMyPlayer())
end

-- "/au-cine <verb> [arg]" (AnDebug/ChatCommands, server side).
function CINE.Command(rest, controller)
    local verb, arg = (rest or ""):match("^(%S*)%s*(.-)%s*$")
    if not verb or verb == "" then verb = "list" end
    CINE.Do(verb:lower(), IsValid(controller) and controller:K2_GetPawn() or nil, arg)
end

-- The numpad layout. AnDebug/Keybinds turns each row into a summon-group entry, so cycling to
-- one of these makes numpad 1-9 the cinematic verbs and costs no new keys.
--   * `release` is slot 9 of BOTH groups on purpose: it is the valve for a stuck hold, and
--     hunting for the right group while an NPC is wedged is exactly when you don't want to.
CINE.GROUPS = {
    { Name = "(90) Cinema",
      Verbs = { "freeze", "freezearea", "statue", "statuearea",
                "unmutate", "mutate", "unmutatearea", "mutatearea", "release" } },

    { Name = "(91) Cinema II",
      Verbs = { 
                "faceme", "turn", "attack", "attackarea", 
                "freeze", "freezearea", "reskin", "hide", "release" } },
}

function CINE.VerbHelp(verb)
    local v = VERBS[verb]
    return v and v.Help or verb
end

return CINE
