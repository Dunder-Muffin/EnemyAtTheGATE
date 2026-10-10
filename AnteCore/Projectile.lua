-- =======================================================================
-- Projectile - spawns AbioticProjectile actors. 
--   * Real replicated actors, so we don't need to do client/server stuff
--   * Same spawn and thread rules as NpcSpawner/ItemSpawner:
--     - projectile class + mesh async loaded per shot (preloads can be stale)
--     - the actual spawn runs on the game thread via WorkQueue
--     - shots are serialized 1 tick apart so a barrage doesn't loadspike a frame
--
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local UEHelpers = require("UEHelpers")
local STATE = require("AnteCore.State")
local ASSETS = require("AnteCore.AssetManager")
local SETTINGS = require("Settings")
local Utils = require("AnteUtils.Utils")
local PR = require("AnteCore.ProjectileRows")
local SCHEMA = require("AnteData.Schema")
local P = SCHEMA.Projectile

local LogBad = Utils.LogBad
local LogDebug = Utils.LogDebug

local PROJ = {}

local nextSlotTick = 0

-- [Utils.ResetState] See NpcSpawner.ResetSlotCursor - FAST_TICK restarts at 0 each world. Here a
-- stale cursor is silent: every shot reads as past MaxBacklogMs and is dropped.
function PROJ.ResetSlotCursor() nextSlotTick = 0 end

-- Slack before a fired projectile's dependency set is pinned - see the PinPaths call in Queue.
-- Same reasoning (and the same number) as Pipeline's: long enough that a volley is over, short
-- enough to beat any realistic GC purge.
local PIN_DELAY_MS = 4000


-- =======================================================================
-- ANTI-SELF-COLLISION - how a projectile decides to blow up, and how to tell it not to.
--
-- THERE ARE TWO IMPACT FUNNELS, WITH DIFFERENT GATES.
--   * Which one a projectile class uses decides which levers can reach it at all,
--     and getting this wrong is silent - the "fix" applies cleanly and the barrage
--     keeps exploding.
--
--   A) ProjectileOverlap   - ComponentBeginOverlap on ProjectileCollision.
--        gate: "NoProjectileHit" tag on the overlapped COMPONENT
--           -> overlapped ACTOR is the INSTIGATOR (or attached to it)   <- note: NOT Owner
--           -> overlapped ACTOR is in ProjectileCollision's MoveIgnoreActors
--
--   B) ReceiveHit          - a BLOCKING hit (AActor's OnActorHit). **Projectile_ThrownWeapon
--        OVERRIDES ReceiveHit**, so every thrown item (the Office Bot's supplies, the Trident net)
--        takes THIS door, not A.
--        gate: HasImpacted -> MoveIgnoreActors -> CheckOverriddenByBlock
--        *** NO tag check. NO instigator check. MoveIgnoreActors is the ONLY lever. ***
--
-- Consequences:
--   * opts.NoProjectileHit is INERT for a thrown weapon (it is real, and it works,
--     but only on door A); IgnoreActorWhenMoving is the whole game for a barrage of them.
--   * Both gates re-read MoveIgnoreActors BY HAND - that array does NOT suppress the
--     event, it only suppresses the sweeps of the component that OWNS it. If B sweeps
--     into A, A still gets the hit. **Hence every ignore must be registered in BOTH
--     directions.**
--   * WHEN it is armed also matters. FinishSpawningActor is what CONSTRUCTS the
--     Blueprint's components and registers them - so pre-finish there is usually
--     nothing to arm (verified: ThrownWeapon logs "ProjectileCollision only exists
--     POST-finish"), while post-finish the sphere has already fired its registration
--     overlaps. We try pre-finish, fall back to post-finish, and log which branch ran.
-- =======================================================================

-- Append an FName to a component's ComponentTags, and VERIFY it landed.
--   * `table.insert` on a UE4SS TArray property is not guaranteed to write through to
--     the UObject - it can silently mutate a detached copy, and wrapped in the usual
--     pcall that failure is invisible. Same silent-no-op family as CLAUDE.md S3's
--     out-param trap - exactly the kind of thing that makes a "fix" look applied when
--     it never was.
--   * So: read the length, insert, read it back, and fall back to a whole-array
--     assignment if nothing changed.
--   * Whole-array is safe HERE specifically because it is a TArray<FName> - no
--     soft-object pointers, so the S3 struct-mangling hazard does not apply.
--   * Returns true only if the tag is verifiably present.
local function addComponentTag(comp, tagName)
    local function count()
        local n = 0
        pcall(function() n = #comp.ComponentTags end)
        return n
    end

    local before = count()
    pcall(function() table.insert(comp.ComponentTags, FName(tagName)) end)
    if count() > before then return true end

    -- Rebuild the array by hand, preserving whatever was already on it.
    local list = {}
    pcall(function()
        local tags = comp.ComponentTags
        for i = 1, #tags do list[#list + 1] = tags[i] end
    end)
    list[#list + 1] = FName(tagName)
    pcall(function() comp.ComponentTags = list end)

    return count() > before
end


-- Arm both mechanisms on `proj`.
--   * Returns false if ProjectileCollision doesn't exist yet (i.e. the Blueprint's
--     components haven't been constructed) so the caller can retry after
--     FinishSpawningActor.
local function armAntiSelfCollision(proj, opts)
    local col
    pcall(function() col = proj.ProjectileCollision end)
    if IsNotValid(col) then return false end

    -- (1) THE TAG. Nothing can ever detonate ON this projectile.
    --   * Order-independent, and it does NOT change what this projectile itself hits -
    --     the gate only ever reads the tag off the component that was overlapped,
    --     never its own.
    if opts.NoProjectileHit then
        if not addComponentTag(col, "NoProjectileHit") then
            LogBad("Projectile - NoProjectileHit tag did NOT stick (barrage will self-detonate)")
        end
    end

    -- (2) THE IGNORE GROUP - for a THROWN weapon this is not just "still worth keeping",
    --   it is the ONLY lever that exists.
    --   * Projectile_ThrownWeapon impacts through ReceiveHit (a blocking hit), whose gate
    --     reads MoveIgnoreActors and nothing else - no tag, no instigator. See the
    --     HIT TRACE block.
    --   * BOTH DIRECTIONS, always. MoveIgnoreActors only suppresses the sweeps of the
    --     component that owns it, so A ignoring B does nothing about B sweeping into A -
    --     A would still take the ReceiveHit.
    --   * The two calls are pcall'd SEPARATELY: sharing one pcall meant a throw on the
    --     first silently skipped the second, leaving the pair ignoring each other in one
    --     direction only.
    if opts.IgnoreGroup then
        for i = #opts.IgnoreGroup, 1, -1 do
            local other = opts.IgnoreGroup[i]
            if not Utils.IsActorValid(other) then
                table.remove(opts.IgnoreGroup, i)
            elseif other ~= proj then
                local okA = pcall(function() col:IgnoreActorWhenMoving(other, true) end)
                local okB = pcall(function()
                    local ocol = other.ProjectileCollision
                    if IsValid(ocol) then ocol:IgnoreActorWhenMoving(proj, true) end
                end)
                if not (okA and okB) then
                    LogBad("Projectile - IgnoreActorWhenMoving failed (mine=" .. tostring(okA) ..
                        " theirs=" .. tostring(okB) .. ") - the volley WILL self-collide")
                end
            end
        end

        -- VERIFY, don't assume. Read the array back through the same accessor the
        --   impact gate uses.
        --   * If this count is not growing shot by shot, the ignore never landed and nothing
        --     downstream can save the barrage - a failure a silent pcall would hide completely.
        if SETTINGS.DEBUG_PROJECTILE_HITS then
            local n = -1
            pcall(function() n = #col:CopyArrayOfMoveIgnoreActors() end)
            LogDebug(string.format("Projectile - MoveIgnoreActors now holds %d actor(s) (volley of %d)",
                n, #opts.IgnoreGroup), SETTINGS.DEBUG_PROJECTILE_HITS)
        end
    end

    return true
end


-- =======================================================================
-- Arm the projectile's damage OFF-HOOK (EIGT + path re-resolve, the
-- PointDamageOffHook escape).
--   * Server_StartDealDamage is not just an "arm": for an AoE ProjectileData row it runs
--     ApplyRadialDamageWithFalloff + a furniture sweep SYNCHRONOUSLY, at the CURRENT location -
--     the spawn point, i.e. the middle of whatever crowd the shot was fired into.
--   * projectile_disc_plasma is the one AoE disc row. Calling this in-drain is the S6 kill-path
--     wedge: every victim's ProcessDamage runs inline, and one the blast KILLS runs its whole
--     death sequence (cold loot/FX loads) nested in the WQ drain hook - a permanent freeze.
--   * opts.DamageTypeClass covers the other half: the native arm path latent-loads the row's
--     DamageType and only calls Server_StartDealDamage from the OnLoaded. Our spawn-time arm
--     races that, so a cold cycle deals damage typed Default__Abiotic_DamageType_ParentBP_C
--     (untyped - no resists/weaknesses). A caller that already preloads its type names it here
--     and we assert it on the projectile before arming.
--   * We cannot use the native path instead (DoProjectileDamageEvent): its OnLoaded chain ends in
--     explode-FX + TrySpawnImpactItem + destroy - that is the IMPACT sequence, and would detonate
--     the shot at the muzzle.
-- =======================================================================

-- RE-FINDING THE SHOT WITHOUT A BY-PATH LOOKUP.
--   * The hop used to re-resolve the projectile with Utils.ResolveByPath: one full UObject-array
--     walk per shot, on every projectile the mod fires - the FindObject-scan AV's biggest single
--     source (a Big Bot turret phase alone is 15 of them).
--   * The projectile BP has no EndPlay or Destroyed event to stamp, so its wrapper cannot be held
--     across the hop. Its ADDRESS can: it is a number. The engine then supplies the live actors
--     of the (pinned) class, and the match is a fresh wrapper the engine vouches for. No walk,
--     and the captured wrapper is never touched.
--   * Self-checking, because a list that silently came back short would make every shot a dud:
--     the first VERIFY misses are cross-checked against the old walk. A projectile the walk
--     finds ALIVE that the list missed means the list cannot be trusted, and the walk takes over
--     for the rest of the session. One the walk finds mid-destroy is a genuine miss.
--   * Until the class pin lands (the first shots of a class) GetIfPinned is nil and the walk runs.
local armFind = { ok = true, checked = 0, said = false, VERIFY = 25 }

-- Returns (projectile|nil, ran). ran = false: the list was not consulted, so nil means nothing.
local function liveProjectileAt(clsPath, addr)
    local cls = ASSETS.GetIfPinned(clsPath)
    if not cls then return nil, false end
    local gs, world = UEHelpers.GetGameplayStatics(), Utils.GetWorld()
    if not gs or IsNotValid(world) then return nil, false end

    local out = {}
    if not pcall(function() gs:GetAllActorsOfClass(world, cls, out) end) then return nil, false end
    for i = 1, #out do
        local a = out[i]
        local okg, inner = pcall(function() return out[i]:get() end)
        if okg and inner then a = inner end
        local aAddr
        pcall(function() aAddr = a:GetAddress() end)
        if aAddr == addr then return a, true end
    end
    return nil, true
end

local function armDealDamageOffHook(proj, opts)
    -- An AoE row's Server_StartDealDamage IS the blast, dealt wherever the shot is right now -
    -- at spawn, the muzzle. The real one comes from the native impact path regardless, so such
    -- a shot only has its type asserted: no full-damage blast around the shooter, and no hop.
    local aoe = false
    pcall(function() aoe = proj.ProjectileData[PR.F.AreaOfEffect] == true end)
    if aoe then
        if opts.DamageTypeClass then
            local dt = ASSETS.GetIfValid(opts.DamageTypeClass)
            if IsValid(dt) then pcall(function() proj.DamageType = dt end) end
        end
        return
    end

    local pPath = Utils.ObjectPath(proj)
    if not pPath then return end
    local addr
    pcall(function() addr = proj:GetAddress() end)
    local clsPath = opts._ClassPath
    local dtPath = opts.DamageTypeClass
    ExecuteInGameThread(function()
        STATE.LastWork = "EIGT armProj " .. pPath
        STATE.LastWorkDone = false
        pcall(function()
            local p, ran
            if armFind.ok and addr and clsPath then p, ran = liveProjectileAt(clsPath, addr) end
            if p and not armFind.said then
                armFind.said = true
                LogDebug("Projectile - arm re-find via the engine's actor list (no by-path walk)",
                    SETTINGS.DEBUG_NPC_ACTIONS)
            end

            if not p and (not ran or armFind.checked < armFind.VERIFY) then
                local walked = Utils.ResolveByPath(pPath)
                if ran then
                    armFind.checked = armFind.checked + 1
                    local dying = true   -- unreadable = treat as gone
                    if walked then pcall(function() dying = walked:IsActorBeingDestroyed() end) end
                    if walked and not dying then
                        armFind.ok = false
                        LogBad("Projectile - the engine's actor list missed a live shot ("
                            .. tostring(clsPath) .. "); arm re-find back on the by-path walk")
                    else
                        walked = nil   -- hit something and died inside the hop: nothing to arm
                    end
                end
                p = walked
            end
            if not p then return end
            if dtPath then
                local dt = ASSETS.GetIfValid(dtPath)
                if IsValid(dt) then p.DamageType = dt end
            end
            p:Server_StartDealDamage()
        end)
        STATE.LastWorkDone = true
    end)
end


-- =======================================================================
-- opts.OnHit - "tell me WHO this projectile actually hit". [AUTHORITY]
--
-- WHY IT EXISTS: a projectile's own payload is not reliably reachable. The parent BP applies its
-- row's BuffDebuffToApply from deep inside an impact chain gated on damage
-- (Server_StartDealDamage early-returns when `DamageFromWeapon == 0 || !CanDealDamage`).
-- PROJ.Queue arms damage itself instead of running the native impact sequence, so a ZERO-DAMAGE
-- projectile whose whole point is its debuff - the net - can travel, impact, and apply nothing.
-- Instead of reverse-engineering which native branch will run, OnHit reports the one thing the
-- engine is unambiguous about (WHAT DID IT TOUCH) and lets the caller apply the debuff itself
-- with the mod's own primitives.
--
-- Fires ONCE per projectile, on the first character-or-anything overlap, with (proj, otherActor).
--   * Runs in the hook. Must not spawn or blocking-load - defer with Utils.QueueWork /
--     Utils.ApplyBuffLinked (both already off-hook), like any other hook body.
--   * This is a POST dispatch (ProjectileOverlap is reached by EX_LocalVirtualFunction). That is
--     what we want: the native attempt, if any, has already run, so a debuff applied here lands
--     LAST and its duration is the one that sticks (net rows are ReplaceExisting).
--
-- COST: the hook is global once armed. `bookCount == 0` (no OnHit projectile in flight, almost
-- always) exits before touching the wrapper at all. Only while one IS in flight do we pay a
-- GetFullName per overlap, for the ~half-second it is alive.
-- =======================================================================
local onHitBook, onHitCount = {}, 0   -- Utils.ActorKey(proj) -> { fn, expires }

-- Drop entries whose projectile died without hitting anything (a miss despawns on LifeSpan).
-- STRING keys never collect on their own, so this is the whole reason the book has an expiry.
local function pruneOnHit(now)
    for key, rec in pairs(onHitBook) do
        if now >= rec.expires then
            onHitBook[key] = nil
            onHitCount = onHitCount - 1
        end
    end
end

-- Is this "hit" the shooter itself? A projectile spawns inside its thrower's own collision, so
-- both funnels report that overlap - the NATIVE bodies discard it (the overlap door on Instigator,
-- ReceiveHit on MoveIgnoreActors), but our dispatch is POST and runs even when the body took that
-- early return. Without this the first thing a net or a bomb "hits" is the NPC that fired it.
local function hitOwnThrower(proj, otherActor)
    local otherName
    pcall(function() otherName = otherActor:GetFullName() end)
    if not otherName then return false end

    local mine = false
    pcall(function()
        -- Instigator and Owner are usually the same actor (Queue defaults one to the other), but a
        -- caller may split them; either one being the thrower disqualifies the hit.
        local src = proj.Instigator
        if IsValid(src) and src:GetFullName() == otherName then mine = true return end
        src = proj:GetOwner()
        if IsValid(src) and src:GetFullName() == otherName then mine = true end
    end)
    return mine
end

local function dispatchOnHit(proj, otherActor)
    if onHitCount <= 0 then return end            -- the fast path: no OnHit shot is in flight
    if IsNotValid(proj) or IsNotValid(otherActor) then return end

    local key
    pcall(function() key = proj:GetFullName() end)
    local rec = key and onHitBook[key]
    if not rec then return end

    -- Checked AFTER the book lookup (so a shot with no OnHit pays nothing) and WITHOUT consuming
    -- the entry - the shot is still in flight and its real target is still to come.
    if hitOwnThrower(proj, otherActor) then return end

    onHitBook[key] = nil                          -- ONCE per projectile, whatever it went on to hit
    onHitCount = onHitCount - 1
    local ok, err = pcall(rec.fn, proj, otherActor)
    if not ok then LogBad("Projectile OnHit - " .. tostring(err)) end
end

-- Register a just-spawned projectile's OnHit. `lifeS` bounds the book entry, so a shot that never
-- connects cannot leak one.
local function noteOnHit(proj, fn, lifeS)
    local key
    pcall(function() key = proj:GetFullName() end)
    if not key then return end
    local now = STATE.FAST_TICK
    pruneOnHit(now)
    if not onHitBook[key] then onHitCount = onHitCount + 1 end
    onHitBook[key] = { fn = fn, expires = now + math.ceil((lifeS or 5) * 10) + 20 }
end


-- =======================================================================
-- WHAT A REMOTE CLIENT FLIES. [AUTHORITY, pre-Finish]
-- The projectile replicates but its movement does not: a client spawns its own copy and
-- simulates the whole flight from three replicated properties. Everything this file writes onto
-- the live ProjectileMovement after spawn is server-only - so an un-mirrored setting shows up
-- only in MP, as a shot that visibly lands somewhere the damage does not. AnNotes/AnteSystems/Projectile.md.
--   * The ROW is gravity, homing, bounce and the speed cap. opts.FlightRow repoints it at one
--     of ours (AnteCore/ProjectileRows); the bare parent class ships no table, so that is set too.
--   * VelocityOverride is the launch velocity, verbatim. Set on EVERY shot: without it a client
--     launches at the row's InitialSpeed whatever opts.Velocity says.
--   * ProjectileSpeedMultiplier scales the row's MaxSpeed at BeginPlay, on every machine - the
--     only way opts.MaxSpeed reaches a client. Left alone when the caller's PreFinish set one.
--   * A gravity the row does not agree with is reported once per shot type: with a FlightRow the
--     row wins on the server too (both ends then agree); without one it is the desync itself.
-- Returns the flight row in use, or nil.
-- =======================================================================
local flightWarned = {}

local function applyClientFlight(proj, direction, opts)
    local flightRow = opts.FlightRow
    if flightRow and not PR.Ready(flightRow) then flightRow = nil end

    local rowName
    pcall(function()
        local handle = proj.ProjectileDataRowHandle
        if flightRow then
            local legacyTable = (not SCHEMA.Native and IsNotValid(handle.DataTable)) and PR.Table() or nil
            SCHEMA.SetRow(handle, flightRow, legacyTable)
        end
        rowName = handle.RowName:ToString()
    end)

    if direction then
        local s = opts.Velocity or 1000
        pcall(function()
            proj.VelocityOverride = FVector(direction.X * s, direction.Y * s, direction.Z * s)
        end)
    end

    local rowCap = opts.MaxSpeed and PR.RowNumber(rowName, "MaxSpeed")
    if rowCap and rowCap > 0 and math.abs(opts.MaxSpeed - rowCap) > 1 then
        pcall(function()
            if math.abs((tonumber(proj.ProjectileSpeedMultiplier) or 1) - 1) < 0.001 then
                proj.ProjectileSpeedMultiplier = opts.MaxSpeed / rowCap
            end
        end)
    end

    -- Once per shot type: the proof, in a server log, of what its clients were told to fly.
    local rowSlot = "row|" .. tostring(opts.FlightRow)   -- by ROW: one class carries several shots
    if opts.FlightRow and not flightWarned[rowSlot] then
        flightWarned[rowSlot] = true
        local mult = 1
        pcall(function() mult = tonumber(proj.ProjectileSpeedMultiplier) or 1 end)
        if flightRow then
            Utils.Log(string.format("Projectile - %s flies row '%s' (speed x%.2f)",
                tostring(opts._traceName), flightRow, mult))
        -- Expected, not an error, when rows are off by choice or this UE4SS has no row API.
        elseif SETTINGS.CORE.CUSTOM_PROJECTILE_ROWS ~= false and STATE.HasDataTableApi ~= false then
            LogBad(string.format("Projectile - %s: flight row '%s' is not ready; its gravity/homing stay server-only",
                tostring(opts._traceName), tostring(opts.FlightRow)))
        end
    end

    local rowGravity = opts.GravityScale and PR.RowNumber(rowName, "GravityScale")
    if rowGravity and math.abs(rowGravity - opts.GravityScale) > 0.001 then
        local slot = tostring(opts._traceName) .. "|" .. tostring(rowName)
        if flightRow then
            if not flightWarned[slot] then
                flightWarned[slot] = true
                LogBad(string.format("Projectile - %s: opts.GravityScale %.2f disagrees with flight row '%s' (%.2f); flying the row",
                    tostring(opts._traceName), opts.GravityScale, rowName, rowGravity))
            end
            opts.GravityScale = rowGravity
        elseif not flightWarned[slot] and SETTINGS.CORE.CUSTOM_PROJECTILE_ROWS ~= false then
            flightWarned[slot] = true
            LogBad(string.format("Projectile - %s: GravityScale %.2f is SERVER-ONLY (row '%s' flies %.2f) - a remote client sees another arc. Give the shot an opts.FlightRow",
                tostring(opts._traceName), opts.GravityScale, tostring(rowName), rowGravity))
        end
    end

    return flightRow
end


local function spawnProjectile(projClass, meshAsset, location, direction, opts)
    local world = Utils.GetWorld()
    local gameplayStatics = UEHelpers.GetGameplayStatics()
    local kMath = UEHelpers.GetKismetMathLibrary()
    if IsNotValid(world) or not gameplayStatics or not kMath then return end

    local rotation = kMath:Conv_VectorToRotator(direction)
    local transform = kMath:MakeTransform(location, rotation, FVector(1, 1, 1))

    -- spawn-> / spawn<- bracket FinishSpawningActor to trace crashes
    local traceName = opts._traceName or "proj"
    LogDebug("spawn-> proj " .. tostring(traceName), SETTINGS.DEBUG_SPAWN_TRACE)

    -- Deferred so we can set owner/scale before the projectile starts moving
    local proj = gameplayStatics:BeginDeferredActorSpawnFromClass(world, projClass, transform, 0, nil, 0)
    if IsNotValid(proj) then
        LogBad("Projectile - deferred spawn failed")
        return
    end

    -- Projectiles with owners: 
    --   * Should not hit their owner
    --   * Default - ignore owner forever. Set IgnoreOwnerDuration to override this
    --      (Native projectiles only ignore for a short time)
    if opts.Owner and Utils.IsActorValid(opts.Owner) then
        proj:SetOwner(opts.Owner)
        if opts.IgnoreOwnerDuration then
            proj.StopIgnoringOwnerAfterShortPeriod = true
            proj.IgnoreOwnerDuration = opts.IgnoreOwnerDuration
        else
            proj.StopIgnoringOwnerAfterShortPeriod = false
        end
    end

    -- opts.Instigator (a PAWN): who gets damage CREDIT + faction for hostility checks.
    --   * The native NPC fire path sets this (NPC_Base Server_DoRangedAttack:
    --     Instigator = the NPC).
    --   * REQUIRED for a projectile whose IMPACT spawns an AreaEffect that ignores its instigator
    --     + allies (e.g. AreaEffect_MolotovBurn_Mage, IgnoreInstigatorAndAllies=true): the
    --     fireball COPIES its own Instigator onto that patch, and the patch's damage loop calls
    --     GetHostilityTowardsTarget(instigator, target) - which returns FALSE for EVERYONE when
    --     the instigator is null. A null-instigator patch deals ZERO damage. Setting it to the
    --     (faction-hostile, controller-having) shooter both makes the patch damage enemies and
    --     makes it skip the shooter itself.
    --   * SetInstigator is the reliable path - the .Instigator property is a weak ptr UE4SS often
    --     can't push-assign - so set the property too as belt-and-suspenders (it replicates).
    --   * *** DEFAULTS TO opts.Owner. *** The OVERLAP door's gate is INSTIGATOR, not Owner (see
    --     the HIT TRACE block), so a projectile that set only Owner has nothing stopping it
    --     detonating on its own shooter. A self-hit like that re-enters our ProcessDamage hook
    --     from inside Server_StartDealDamage - already nested in the spawn drain - and freezes
    --     single player.
    --   * Defaulting rather than fixing the one caller is right because it matches the native
    --     path (NPC_Base Server_DoRangedAttack sets Instigator = the NPC); pass Instigator
    --     explicitly to override.
    local instigator = opts.Instigator or opts.Owner
    if instigator and Utils.IsActorValid(instigator) then
        pcall(function() proj:SetInstigator(instigator) end)
        pcall(function() proj.Instigator = instigator end)
    end

    proj.WasThrown = true

    -- Optionally disable projectile audio
    --   * Projectiles play a looping travel-audio component (TravelLoopAudio).
    --   * Multi-projectiles (shotgun pellets) can cause a dozen audio events.
    --   * A machine-gun spawns dozens fast, and one sound wave freed mid audio-tick
    --     AV'd the audio device (FAudioDevice::UpdateReferencedSoundWaves).
    if opts.NoTravelAudio then
        Utils.BlankSoftRef(proj, "LoopingAudio")
    end

    -- ThrownWeapons build their mesh from ItemDataRow, and we need to set it 
    --   before FinishSpawningActor, so clients OnRep also creates the mesh 
    --     * SM_Appearance does not replicate, just covers host/SP
    if opts._ItemTable and opts.Item and opts.Item.Row then
        local ok = pcall(function()
            SCHEMA.SetRow(proj.ItemDataRow, opts.Item.Row, opts._ItemTable)
        end)
        if not ok then LogBad("Projectile - ItemDataRow set failed: " .. tostring(opts.Item.Row)) end
    end

    -- Anti-self-collision, FIRST attempt - see the block at the top of this file.
    --   * Pre-finish is the only place that can beat the sphere's own registration
    --     overlaps, but the Blueprint's components may not be constructed yet, in which
    --     case this returns false and we retry below.
    local armed = armAntiSelfCollision(proj, opts)

    -- Caller escape hatch for class-specific properties that must be set BEFORE BeginPlay runs.
    --   * The opts block above has promised PreFinish/PostFinish for a while, but only
    --     PROJ.SpawnGrenade ever called them - so every Queue caller passing one was writing dead
    --     code that failed SILENTLY (it cost the Trident's net: BuffsIgnoreAllies was never
    --     cleared, so the net could not buff a player, and the debug probe never ran either).
    if opts.PreFinish then pcall(opts.PreFinish, proj) end

    -- AFTER the caller's PreFinish: a FlightRow has to win over a native repoint kept there as
    -- the fallback, and the multiplier is sized off whichever row ends up in the handle.
    local flightRow = applyClientFlight(proj, direction, opts)

    proj = gameplayStatics:FinishSpawningActor(proj, transform, 0)
    LogDebug("spawn<- proj " .. tostring(traceName), SETTINGS.DEBUG_SPAWN_TRACE)
    if IsNotValid(proj) then
        LogBad("Projectile - finish spawn failed")
        return
    end

    -- In the case of ThrownWeapon, don't leave the item behind 
    --   (may override this later)
    proj.SpawnImpactItemAfterHit = false
    proj.SpawnImpactItemIfBuffApplyFails = false

    -- Push the row to clients in case it didn't ride the initial bunch
    if opts._ItemTable and opts.Item then
        Utils.MarkReplicatedDirty(proj, "ItemDataRow")
    end
    -- ...and the same belt on the three flight properties.
    Utils.MarkReplicatedDirty(proj, "VelocityOverride")
    Utils.MarkReplicatedDirty(proj, "ProjectileSpeedMultiplier")
    if flightRow then Utils.MarkReplicatedDirty(proj, "ProjectileDataRowHandle") end

    -- Anti-self-collision, SECOND attempt - and in practice the ONLY one that ever runs.
    --   * A Blueprint's components are constructed by ExecuteConstruction, which
    --     FinishSpawningActor is what triggers, so pre-finish there is simply no
    --     ProjectileCollision to arm. (Verified: every ThrownWeapon takes this branch.)
    --   * The pre-finish attempt stays for any projectile class whose collision is a
    --     NATIVE component - it costs one nil check - but do not build anything on it firing.
    if not armed then
        LogDebug("Projectile - arming self-collision post-finish (" .. tostring(traceName) .. ")",
            SETTINGS.DEBUG_PROJECTILE_HITS)
        armAntiSelfCollision(proj, opts)
    end

    -- Join the volley LAST, and exactly once: every later shot registers against
    --   everything already in here (both directions), so a member must be fully
    --   spawned before anyone ignores it.
    if opts.IgnoreGroup then table.insert(opts.IgnoreGroup, proj) end

    if opts.Scale then proj:SetActorScale3D(opts.Scale) end
    if opts.SpeedMultiplier then proj.ProjectileSpeedMultiplier = opts.SpeedMultiplier end
    if opts.Damage then proj.DamageFromWeapon = opts.Damage end
    if opts.LifeSpan then proj:SetLifeSpan(opts.LifeSpan) end

    -- Swap the visible mesh (ThrownWeapon-style projectiles expose SM_Appearance).
    --   * *** COLLISION OFF FIRST. *** SetStaticMesh triggers RecreatePhysicsState, which
    --     registers a fresh Chaos body. Doing that with collision still ENABLED can corrupt
    --     Chaos. It does not crash here - it crashes LATER, on a physics worker thread, reading a
    --     garbage pointer, with a stack that names none of this (the Beholder's lightning orb hit
    --     this: an access violation on a task-graph thread a few hundred ms after spawning).
    --   * AVAttach has always done this for its attachments (see the AVUtils header), but this
    --     path never did - nothing had swapped a mesh onto a MOVING, COLLIDING projectile before.
    --   * SM_Appearance is a cosmetic mesh: the projectile's real collision is its
    --     ProjectileCollision component, so leaving the appearance mesh's own collision OFF
    --     afterwards is correct anyway - it can only cause the projectile to snag on itself.
    if IsValid(meshAsset) and proj.SM_Appearance then
        pcall(function() proj.SM_Appearance:SetCollisionEnabled(0) end)   -- NoCollision
        proj.SM_Appearance:SetStaticMesh(meshAsset)
    end

    -- Optionally hide the projectile's own appearance mesh (SM_Appearance/SK_Appearance)
    --   * The projectile trail will still show
    --       Ex: Magma Exor launches a molotov, but we only want a fireball not the item
    --   * And rehide the projectile in case BeginPlay rebuilds it
    -- 
    -- DEDICATED COMPLICATION: component SetVisibility is server/local, so a client
    --   rebuilds and shows the item from replicated ProjectileData. 
    --     * Can't use SetActorHiddenInGame - bHidden replicates but also hides the trail
    --     * Hiding only the mesh on a dedicated client needs clearing
    --     * TODO: Need to fix this it stays visible for clients
    if opts.HideMesh then
        local function hideBottle()
            pcall(function() if IsValid(proj.SM_Appearance) then proj.SM_Appearance:SetVisibility(false, false) end end)
            pcall(function() if IsValid(proj.SK_Appearance) then proj.SK_Appearance:SetVisibility(false, false) end end)
            pcall(function() if IsValid(proj.ProjectileGlint) then proj.ProjectileGlint:SetVisibility(false, false) end end)
        end
        hideBottle()
        Utils.QueueWork(hideBottle, 50)
        Utils.QueueWork(hideBottle, 150)
    end

    -- Optionally add a Niagara asset to add a trail to the projectile
    --   * May not work on dedicated clients? TODO: Double check this
    --   * opts.TrailScale sizes it - a trail system authored for one job is rarely the right size
    --     for a projectile, and a Niagara's own scale is the only handle we have on a system whose
    --     user params we can't reach from here.
    if opts._TrailFXAsset and IsValid(opts._TrailFXAsset) then
        pcall(function()
            local ngClass = ASSETS.GetIfValid("/Script/Niagara.NiagaraComponent")
            if IsValid(ngClass) then
                local ng = proj:AddComponentByClass(ngClass, false, FTransform(), false)
                if IsValid(ng) then
                    ng:SetAsset(opts._TrailFXAsset, false)
                    local ts = tonumber(opts.TrailScale)
                    if ts then ng:SetRelativeScale3D(FVector(ts, ts, ts)) end
                    if opts.TrailRot then ng:K2_SetRelativeRotation(opts.TrailRot, false, {}, false) end
                    ng:Activate(true)
                end
            end
        end)
    end

    local pData = proj.ProjectileData
    if pData then
        pData[P.RotationRemainsVertical] = opts.KeepVertical or false
        if opts.GravityScale then
            pData[P.ProjectileGravityScale] = opts.GravityScale
        end
        if opts.Bounces then
            pData[P.ShouldBounce] = true
            pData[P.NumberOfBounce] = opts.Bounces
        end
        -- WIPE THE ROW'S DEBUFF LIST BY DEFAULT - thrown office supplies shouldn't bleed anyone.
        --   * opts.KeepDebuff OPTS BACK IN, and a projectile whose whole POINT is its debuff needs
        --     it: this line is what silently disarmed the Trident's net (the row carries
        --     debuff_netted and nothing else - CanDealDamage is false - so a wiped list made the
        --     net a purely cosmetic object that hit people and did nothing).
        --   * Default kept as-is deliberately: every existing caller has been running with the
        --     wipe, and flipping it would hand several of them a debuff they never had.
        if not opts.KeepDebuff then
            pData[P.BuffDebuffToApply] = nil
        end
    end

    local speed = opts.Velocity or 1000
    local velocity = FVector(direction.X * speed, direction.Y * speed, direction.Z * speed)
    if proj.ProjectileMovement then
        -- ProjectileMovement clamps to MaxSpeed (the ThrownWeapon's BeginPlay sets it from
        -- ProjectileData ~1000), so a higher opts.Velocity is otherwise capped. Raise the
        -- live MaxSpeed first (post-FinishSpawning runs after BeginPlay, so it sticks).
        if opts.MaxSpeed then
            pcall(function() proj.ProjectileMovement.MaxSpeed = opts.MaxSpeed end)
        end
        -- pcall'd for consistency with the MaxSpeed / GravityScale writes around it.
        --   * If this ONE write threw a catchable Lua error (e.g. ProjectileMovement went
        --     nil between the guard and here), the bare form aborted the rest of
        --     spawnProjectile via the outer pcall (Queue's doSpawn) - so the disc spawned
        --     but never reached Server_StartDealDamage (a dud that deals no damage).
        --     This lets the spawn finish.
        --   * NOTE: this does NOT stop an access violation (a "corrupted pointer" crash
        --     is uncatchable by pcall - see below / CLAUDE.md 3).
        pcall(function() proj.ProjectileMovement.Velocity = velocity end)
        -- Gravity must be set on the LIVE movement component, not just ProjectileData
        --   (above).
        --   * The data struct is read at BeginPlay, but we set velocity post-spawn, so a
        --     config-only gravity never reaches the live component and the projectile
        --     flies dead straight (no arc/drop).
        if opts.GravityScale then
            pcall(function() proj.ProjectileMovement.ProjectileGravityScale = opts.GravityScale end)
        end
    end

    -- =======================================================================
    -- "Simulate Projectile" does not mean "make the projectile move" - it is the flag that
    -- turns SM_Appearance into a PHYSICS BODY.
    --   * AbioticProjectile_ParentBP's `Projectile Simulate Update()` is gated on this bool and
    --     does, verbatim:
    --       SM_Appearance->SetSimulatePhysics(true)
    --       SM_Appearance->SetCollisionEnabled(QueryAndPhysics)
    --       SM_Appearance->SetCollisionObjectType(PhysicsBody)
    --       SM_Appearance->SetCollisionResponseToAllChannels(BLOCK)
    --     The game calls this from the mesh-update path, so it re-asserts all of that AFTER any
    --     collision we turn off elsewhere - a block-everything physics body welded to the
    --     cosmetic mesh.
    --   * Movement comes from ProjectileMovement + SetVelocityNextTick below; none of it needs
    --     this flag. Default OFF. opts.SimulatePhysicsMesh opts back in for a projectile that
    --     genuinely wants to be a tumbling physical prop - nothing does today.
    --   * See AnNotes/AnteSystems/Projectile.md for how this was found (the Office Bot "invisible wall" and
    --     the Beholder orb Chaos crash).
    -- =======================================================================
    pcall(function() proj["Simulate Projectile"] = opts.SimulatePhysicsMesh == true end)

    proj:SetVelocityNextTick(velocity)
    proj:SM_Updated()
    armDealDamageOffHook(proj, opts)   -- was a direct Server_StartDealDamage: see the helper's header

    -- Belt and braces: with the flag off nothing re-enables it, so this now STICKS (it never did
    -- before - Projectile Simulate Update just turned it straight back on).
    if not opts.SimulatePhysicsMesh then
        pcall(function()
            if IsValid(proj.SM_Appearance) then
                proj.SM_Appearance:SetSimulatePhysics(false)
                proj.SM_Appearance:SetCollisionEnabled(0)   -- NoCollision
                proj.SM_Appearance:SetGenerateOverlapEvents(false)
            end
        end)
    end

    -- Backup for the pre-finish LoopingAudio clear above: 
    --   * Stop the travel-audio component again in case it started
    --   * Stop() releases the sound-wave ref cleanly
    if opts.NoTravelAudio then
        local function stopLoop()
            pcall(function() if IsValid(proj.TravelLoopAudio) then proj.TravelLoopAudio:Stop() end end)
        end
        stopLoop()
        Utils.QueueWork(stopLoop, 150)
        Utils.QueueWork(stopLoop, 500)
    end

    -- Hand the live projectile back.
    --   * The ONLY way a caller can keep steering / reading one after it is away (an orb
    --     that drags a damage field behind it, a shot you want to watch land).
    --   * Fired LAST, so everything above has already been applied.
    --   * AUTHORITY - this is the server's actor; do not stash the wrapper long-term
    --     (CLAUDE.md S3), re-check IsActorValid on every use.
    -- Class-specific properties that must land AFTER BeginPlay (which rebuilds the projectile from
    -- its row and can clobber a pre-Finish write). Before OnSpawned, so a caller using both sees a
    -- fully configured projectile.
    -- opts.MeshRot first: SM_Appearance's relative rotation, AFTER BeginPlay - its row-driven
    -- SetProjectileMesh rebuilds the component and would clobber an earlier write.
    if opts.MeshRot then
        pcall(function()
            if IsValid(proj.SM_Appearance) then proj.SM_Appearance:K2_SetRelativeRotation(opts.MeshRot, false, {}, false) end
        end)
    end
    if opts.PostFinish then pcall(opts.PostFinish, proj) end

    -- Book the impact callback LAST, so it can never fire against a half-configured projectile.
    if opts.OnHit then noteOnHit(proj, opts.OnHit, opts.LifeSpan) end

    if opts.OnSpawned then pcall(opts.OnSpawned, proj) end

    LogDebug("Projectile - fired " .. tostring(opts.Damage or 0) .. " dmg", SETTINGS.DEBUG_QUEUES)
end


-- =======================================================================
-- Queue a projectile.
--   location       - FVector spawn point
--   direction      - FVector travel direction. NORMALIZED FOR YOU (see PROJ.Queue) - speed comes
--                    from opts.Velocity alone, so a raw (target - origin) is fine to pass.
--   projectileClass- ENUMS.ProjectileClasses path (use a ThrownWeapon-style
--                    class for opts.Item)
--   meshClass      - optional static-mesh path; SERVER/HOST-only visual swap
--   opts           - Owner, Damage, Velocity, Scale, SpeedMultiplier,
--                    GravityScale, LifeSpan, Bounces, KeepVertical
--                    Instigator = <pawn> - DEFAULTS TO Owner. Damage CREDIT + faction for the
--                      projectile AND any AreaEffect it spawns on impact, and it is the gate that
--                      stops the shot detonating on its own shooter (the OVERLAP door checks
--                      Instigator, NOT Owner). REQUIRED for impact patches that
--                      ignore-instigator-and-allies (e.g. AreaEffect_MolotovBurn_Mage) - a
--                      null instigator makes that patch deal ZERO damage.
--                    DamageTypeClass = <ENUMS.DamageType path> - assert the projectile's DamageType
--                      at arm time. Our arm races the native latent type load, so without this an
--                      early hit (an AoE row's spawn blast especially) deals PARENT-DEFAULT-typed
--                      damage (no resists). Pass the row's own type and ALSO put it in opts.Preload
--                      so it's resident (a nil resolve just falls back to the native race).
--                    MaxSpeed - raise the movement speed cap (Velocity is otherwise
--                      clamped to the projectile's ProjectileData MaxSpeed, ~1000). Reaches
--                      clients as ProjectileSpeedMultiplier - see applyClientFlight.
--                    FlightRow = <ENUMS.ProjectileRows name of OURS> - REQUIRED whenever
--                      GravityScale, homing or bounce differ from the row the class flies: those
--                      writes are server-only, and a remote client simulates its own copy off
--                      the row. Falls back to the scripted numbers when the row is not ready.
--                    SerializeTicks - ticks between successive shots (default 1 = 100ms);
--                      widen so a barrage spreads in time and doesn't self-collide
--                    NoProjectileHit = true - tag this projectile's collision sphere so nothing can
--                      detonate ON it (the game's own "NoProjectileHit" component tag). NOTE this is
--                      only read on the OVERLAP door - a THROWN weapon impacts via ReceiveHit, which
--                      does not check it. See the ANTI-SELF-COLLISION block.
--                    SimulatePhysicsMesh = true - make SM_Appearance a simulating, block-everything
--                      PHYSICS BODY. Almost certainly NOT what you want: it makes the projectile
--                      collide with itself and with its volley-mates. Default off. See the big
--                      comment at the "Simulate Projectile" write - this flag was on for everything
--                      and was the real cause of the Office Bot's "invisible wall".
--                    TrailFX = <Niagara path> - in-flight cosmetic trail welded
--                      to the projectile (host/SP only; doesn't replicate)
--                    TrailScale = n - uniform scale for that trail (default 1). ⚠ MANY NIAGARA
--                      SYSTEMS IGNORE IT: a system that sizes itself off a user param, or emits in
--                      world space, is unmoved by its component's scale. If a trail comes out too
--                      small to read, prefer a projectile whose MESH is class-baked (it replicates
--                      too, which a runtime-added trail does not).
--                    HideMesh = true - hide the projectile's own SM_/SK_Appearance
--                      mesh (e.g. the molotov bottle), leaving just TrailFX/impact
--                    MeshRot = FRotator - SM_Appearance's relative rotation, set after BeginPlay
--                    TrailRot = FRotator - the trail's relative rotation
--                    ALL FOUR (TrailFX/TrailScale/HideMesh/Scale) plus MeshRot default from
--                      PR.LOOKS[opts.FlightRow], which is also what a remote client applies to
--                      its copy (AnteVariants/ClientProjectiles). Put a new look THERE, not here.
--                    Item = { Table=<datatable path>, Row=<rowname> } - the
--                      REPLICATED, client-visible mesh (data-driven). Prefer
--                      this over meshClass when clients must see the
--                      projectile (e.g. on a dedicated server).
--                    OnSpawned = fn(proj) - AUTHORITY, called with the LIVE projectile actor once
--                      it is fully spawned and configured. The only way to keep hold of one after
--                      it is away (e.g. an orb you want to trail a damage field behind). Re-check
--                      IsActorValid on every later use - it is destroyed on impact.
--                    OnHit = fn(proj, otherActor) - AUTHORITY, fires ONCE on this projectile's
--                      first impact, with whatever it touched. THE way to land a payload the
--                      native impact chain will not: that chain gates its buff/damage work on
--                      `DamageFromWeapon > 0 && CanDealDamage`, so a zero-damage projectile
--                      (the net) applies nothing on its own. Runs IN the hook - defer anything
--                      that spawns or loads. See AnteNPCs/OrderCaptainHelpers (the Trident net).
--                    KeepDebuff = true - keep the ProjectileData row's BuffDebuffToApply list
--                      instead of wiping it (the wipe is the DEFAULT - see the write). Required by
--                      any projectile whose point IS its debuff: the net, a freeze shard, a tar bolt.
--                    Preload = { <asset paths> } - the projectile's OWN runtime
--                      deps (its DamageType class, LoopingAudio, mesh, impact
--                      AreaEffect). Loaded in the spawn batch so the projectile's
--                      internal LoadAsset/LoadAssetClass calls are cache hits and
--                      don't blocking-load (freeze) in the host in-hook drain. Pass
--                      these for any projectile with rare/holy/etc. assets.
-- =======================================================================

-- =======================================================================
-- HIT TRACE (SETTINGS.DEBUG_PROJECTILE_HITS) - the answer to "why is this barrage
-- exploding in mid-air". The impact FX tells you WHERE a shot died; this tells you WHAT
-- it died on. Same two impact funnels as the ANTI-SELF-COLLISION block at the top of this
-- file - hook BOTH, or a trace that only watches one door misses every thrown-weapon impact.
--   * THREADING: the body reads names and logs. It touches no component and spawns nothing, so
--     it is safe inside the hook (CLAUDE.md S2). Register once per UE4SS session - a
--     re-registered hook is a trampoline AV (see [[anteup2-shared-hook-teardown]]).
-- =======================================================================
-- EVERY CLASS THAT DECLARES A DOOR NEEDS ITS OWN HOOK. A subclass that redeclares one owns a
-- separate UFunction, and a hook on the parent's copy never fires for it. The GRENADE family
-- (flasks, molotovs, mugnades) redeclares BOTH, so a Beholder flask's impacts reached neither this
-- trace nor opts.OnHit - which is how "the corrosive flask breaks in mid-air" survived a trace
-- session with nothing in the log.
local PROJ_BP = "/Game/Blueprints/Projectiles/"
local HIT_DOORS = {
    { how = "overlap",  name = "projectile",
      path = PROJ_BP .. "AbioticProjectile_ParentBP.AbioticProjectile_ParentBP_C:ProjectileOverlap" },
    { how = "overlap",  name = "grenade",
      path = PROJ_BP .. "Projectile_Grenade_ParentBP.Projectile_Grenade_ParentBP_C:ProjectileOverlap" },
    { how = "blockhit", name = "thrownweapon",
      path = PROJ_BP .. "Projectile_ThrownWeapon.Projectile_ThrownWeapon_C:ReceiveHit" },
    { how = "blockhit", name = "grenade",
      path = PROJ_BP .. "Projectile_Grenade_ParentBP.Projectile_Grenade_ParentBP_C:ReceiveHit" },
}

-- Log one impact. `how` names the funnel so the two are never confused in the log.
local function logProjHit(how, self, OtherActor, OtherComp)
    -- NOT wrapped in a silent pcall: a trace that swallows its own errors can produce an empty
    --   log and send you chasing the wrong door. Report the failure instead.
    local ok, err = pcall(function()
        local proj = self:get()
        if IsNotValid(proj) then return end

        local other = OtherActor and OtherActor:get()
        local comp = OtherComp and OtherComp:get()

        local otherName = IsValid(other) and other:GetFullName() or "<none>"
        local compName = IsValid(comp) and comp:GetFullName() or "<none>"

        -- Distance from the thrower, which is what makes "it dies 5m out" mean something.
        local dist = -1
        pcall(function()
            local src = proj.Instigator
            if IsNotValid(src) then src = proj:GetOwner() end
            if IsValid(src) then
                dist = math.sqrt(Utils.DistSq(proj:K2_GetActorLocation(), src:K2_GetActorLocation()))
            end
        end)

        Utils.Log(string.format("PROJHIT[%s] %s hit %s (comp %s) %.0fcm from its thrower",
            how, proj:GetFullName(), otherName, compName, dist))
    end)
    if not ok then Utils.LogBad("PROJHIT[" .. how .. "] trace error: " .. tostring(err)) end
end

-- ONE registration for BOTH consumers - the debug trace and opts.OnHit. They share a latch because
-- re-registering a UE4SS hook is a trampoline AV ([[anteup2-shared-hook-teardown]]), so this can
-- never be split into two arms of its own.
--   * `wantOnHit` arms it for a gameplay reason rather than a debug flag; the dispatch is a table
--     lookup that exits immediately when no OnHit projectile is in flight.
local function registerHitTrace(wantOnHit)
    if not (SETTINGS.DEBUG_PROJECTILE_HITS or wantOnHit) then return end
    if STATE.ProjHitTraceArmed then return end
    STATE.ProjHitTraceArmed = true

    --   ProjectileOverlap(OtherActor, OtherComp)
    --   ReceiveHit(MyComp, Other, OtherComp, bSelfMoved, HitLocation, HitNormal, NormalImpulse, Hit)
    local armed, missed = {}, {}
    for _, door in ipairs(HIT_DOORS) do
        local how = door.how
        local ok = pcall(RegisterHook, door.path, function(self, a, b, c)
            local other = (how == "overlap") and a or b
            local comp  = (how == "overlap") and b or c
            if SETTINGS.DEBUG_PROJECTILE_HITS then logProjHit(how, self, other, comp) end
            dispatchOnHit(self:get(), other and other:get() or nil)
        end)
        local tag = door.name .. "/" .. how
        if ok then armed[#armed + 1] = tag else missed[#missed + 1] = tag end
    end

    Utils.Log("Projectile - impact hooks armed: " .. table.concat(armed, " ") .. " (trace="
        .. tostring(SETTINGS.DEBUG_PROJECTILE_HITS ~= false) .. ")")
    -- A door whose class was not yet loaded is a blind spot for the rest of the session, and a
    -- silent one: the shots it would have reported simply never appear.
    if #missed > 0 then
        LogBad("Projectile - impact door NOT armed (class unloaded): " .. table.concat(missed, " "))
    end
end


function PROJ.Queue(location, direction, projectileClass, meshClass, opts)
    if not Utils.IsAuthority() then return end
    if not location or not direction or not projectileClass then return end
    opts = opts or {}
    opts._traceName = projectileClass

    -- The row's LOOK (PR.LOOKS) fills in what the caller did not say. One definition serves this
    -- end and ClientProjectiles on a remote client; it applies whether or not the row built.
    local look = opts.FlightRow and PR.LOOKS[opts.FlightRow]
    if look then
        if opts.TrailFX == nil then opts.TrailFX = look.Trail end
        if opts.TrailScale == nil then opts.TrailScale = look.TrailScale end
        if opts.TrailRot == nil and look.TrailRot then
            opts.TrailRot = FRotator(look.TrailRot[1], look.TrailRot[2], look.TrailRot[3])
        end
        if opts.HideMesh == nil then opts.HideMesh = look.HideMesh end
        if opts.Scale == nil and look.Scale then opts.Scale = FVector(look.Scale, look.Scale, look.Scale) end
        if opts.MeshRot == nil and look.MeshRot then
            opts.MeshRot = FRotator(look.MeshRot[1], look.MeshRot[2], look.MeshRot[3])
        end
    end

    registerHitTrace(opts.OnHit ~= nil)   -- armed once per session (trace flag OR an OnHit caller)

    -- *** NORMALIZE HERE, ONCE. ***
    --   * The spawn does `velocity = direction * opts.Velocity`, component by component - so a
    --     RAW (to - from) direction multiplies the speed by the DISTANCE to the target. Aim at
    --     something 1000 units away with Velocity = 260 and the thing leaves at 260,000: gone
    --     before the frame renders.
    --   * Normalizing a unit vector is a no-op, so this is safe for callers that already
    --     hand-normalize.
    --   * A zero-length direction has no meaning: drop the shot rather than divide by zero.
    local dx, dy, dz = direction.X or 0, direction.Y or 0, direction.Z or 0
    local len = math.sqrt(dx * dx + dy * dy + dz * dz)
    if len < 0.0001 then
        LogBad("Projectile - zero-length direction, shot dropped: " .. tostring(projectileClass))
        return
    end
    direction = FVector(dx / len, dy / len, dz / len)

    -- Serialize shots ~1 tick (100ms) apart by default; opts.SerializeTicks widens the
    -- gap so a barrage spreads out in TIME (each shot clears the spawn zone before the
    -- next appears, so they don't overlap-detonate on each other).
    local delayMs
    nextSlotTick, delayMs = Utils.ClaimSlotTick(nextSlotTick, opts.SerializeTicks or 1)

    -- BACKLOG CAP: a shot that can't fire within MaxBacklogMs is DROPPED instead of
    --   fired late.
    --   * The serialize slots are GLOBAL (every NPC's shots share the ticker), so under
    --     stress the queue stretches seconds long and shots land visibly AFTER their
    --     animation.
    --   * A throw that lands 2s after the wind-up reads as a bug, not an attack.
    if delayMs > (opts.MaxBacklogMs or 1500) then
        nextSlotTick = nextSlotTick - (opts.SerializeTicks or 1)   -- give the slot back
        LogDebug("Projectile - DROPPED (backlog " .. delayMs .. "ms): " .. tostring(projectileClass),
            SETTINGS.DEBUG_QUEUES)
        return
    end

    Utils.QueueWork(function()
        local toLoad = { projectileClass }
        if meshClass then toLoad[#toLoad + 1] = meshClass end
        if opts.Item and opts.Item.Table then toLoad[#toLoad + 1] = opts.Item.Table end
        if opts.TrailFX then toLoad[#toLoad + 1] = opts.TrailFX end
        -- opts.Preload: the projectile's OWN BeginPlay/StartDealDamage dependencies
        --   (its ProjectileData DamageType class, LoopingAudio, mesh, impact AreaEffect...).
        --   * These are LoadAsset/LoadAssetClass'd inside the projectile and, if not
        --     resident, BLOCKING-LOAD nested in our in-hook spawn drain on HOST/SP -> freeze.
        --   * Loading them HERE (same batch as the class, right before the spawn) keeps
        --     them fresh + resident through the spawn, so the projectile's own loads are
        --     cache hits.
        --   * Preloading via the variant's Assets is NOT enough: those resolve by
        --     StaticFindObject and get GC'd in the seconds between spawn and firing.
        --     See CLAUDE.md S2.
        if opts.Preload then
            for _, p in ipairs(opts.Preload) do toLoad[#toLoad + 1] = p end
        end

        ASSETS.LoadAsync(toLoad, function(results)
            if IsNotValid(results[projectileClass]) then
                LogBad("Projectile - class failed to load: " .. tostring(projectileClass))
                return
            end

            -- GC-PIN the whole dependency set, exactly as Pipeline does for def.Assets and for the
            -- same two reasons: no re-cold-load, and every later resolve of these paths is a
            -- trusted cache hit instead of a full UObject-array WALK. That walk is what this
            -- function pays PER SHOT - unpinned it profiled at ~15-25ms per path inside the drain,
            -- which is the whole cost of firing a scripted projectile.
            --   * On the next drain item, from these results (ASSETS.PinSoon): doSpawn re-resolves a
            --     frame later, and a GC in that gap takes anything unpinned. A delayed PinPaths
            --     backs it up.
            --   * Free from the second shot of a given projectile onward: both dedupe against
            --     pinned + known-unpinnable and return before doing any work.
            ASSETS.PinSoon(toLoad, results)

            local function doSpawn()
                -- Re-resolve by path: doSpawn runs a frame after the load callback, and a class or
                -- mesh collected in that window passes IsValid ([[anteup2-stale-class-spawn-av]]).
                -- Free once PinPaths above has landed (trusted cache hit).
                local cls = ASSETS.GetIfValid(projectileClass)
                if IsNotValid(cls) then
                    LogBad("Projectile - class collected between load and spawn, shot dropped: "
                        .. tostring(projectileClass))
                    return
                end
                local mesh = meshClass and ASSETS.GetIfValid(meshClass) or nil
                if opts.Item and opts.Item.Table then opts._ItemTable = ASSETS.GetIfValid(opts.Item.Table) end
                if opts.TrailFX then opts._TrailFXAsset = ASSETS.GetIfValid(opts.TrailFX) end
                opts._ClassPath = projectileClass   -- the arm hop re-finds the shot by class + address
                local ok, err = pcall(spawnProjectile, cls, mesh, location, direction, opts)
                if not ok then LogBad("Projectile - spawn error: " .. tostring(err)) end
            end

            -- On a DEDICATED server, spawn OFF our ProcessSpawns_Quick hook (the
            -- projectile's BeginPlay can do its own blocking loads; nested in the
            -- hook that can hang the server). Same fix as NpcSpawner/ItemSpawner.
            if STATE.Role == "DEDICATED" then
                ExecuteInGameThread(doSpawn)
            else
                Utils.QueueWork(doSpawn, 0)
            end
        end)
    end, delayMs)
end


-- =======================================================================
-- SpawnGrenade - deferred-spawn a NATIVE grenade/flask class as if an NPC threw or
-- dropped it.
--   * The one crash-safe funnel for what OrderSapper (thrown flask + manual frag) and
--     OrderLabRat (dropped flask) each used to hand-roll.
--   * THE ORDERING IN THE BODY IS LOAD-BEARING - each step carries its own crash note;
--     do not re-order or "simplify" without reading them.
--
-- opts:
--   Location (required), Scale (1), SpawnMode (0; 2 = AdjustIfPossibleButAlwaysSpawn),
--   AlignToVelocity - point the spawn rotation along Velocity (a THROWN flask's mesh +
--                     forward-fired init velocity; without it a throw flies 90 deg off),
--   Velocity (FVector), VelocityViaPM (post-Finish pm.Velocity write - see body),
--   WasThrown (default true; false for a placed/air-dropped grenade),
--   Damage - DamageFromWeapon, pre-Finish,
--   ArmContactMs - arm ExplodesOnContact(+WithCharacter) this many ms AFTER the spawn,
--   NoiseOnImpact - landing fires the parent's own 1000uu "playersound" (NPCs go look). Additive
--     to the damage event, soft tag, no knob - see the write site,
--   AoEInner / AoEOuter - blast radii (GUID-suffixed ProjectileData fields, in place),
--   ArmDamage - flip THIS INSTANCE's CanDealDamage on, for a row that ships harmless
--     (projectile_snowball). Without it the shot flies and lands but deals nothing,
--   MaxSpeed - raise pm.MaxSpeed (a high arc gets clamped by the row default ~1000),
--   Gravity - pm.ProjectileGravityScale, SpeedMult - ProjectileSpeedMultiplier,
--   PreFinish(proj) / PostFinish(proj) - caller escape hatches for class-specific props
--     (the frag's fuse flags, its "Base Damage" field, ...),
--   Label - log prefix for failures.
-- =======================================================================
function PROJ.SpawnGrenade(actor, clsPath, opts)
    opts = opts or {}
    if not clsPath or not opts.Location then return end
    local label = opts.Label or "SpawnGrenade"

    -- LoadAsync, NOT GetIfValid: the class must be GUARANTEED resident at spawn
    --   time - a cached class can be GC'd, silently stopping drops after a handful.
    ASSETS.LoadAsync({ clsPath }, function(results)
        if IsNotValid(results[clsPath]) then LogBad(label .. " - class not loaded: " .. tostring(clsPath)); return end

        -- Pin the class (delayed, same as Queue) so the re-resolve in doSpawn is a cache hit.
        Utils.QueueWork(function()
            pcall(function() require("AnteCore.AssetKeeper").PinPaths({ clsPath }) end)
        end, PIN_DELAY_MS)

        local function doSpawn()
            -- Re-resolve by path, never the wrapper captured in the load callback
            -- ([[anteup2-stale-class-spawn-av]]).
            local cls = ASSETS.GetIfValid(clsPath)
            if IsNotValid(cls) then
                LogBad(label .. " - class collected between load and spawn: " .. tostring(clsPath))
                return
            end
            local gs = UEHelpers.GetGameplayStatics()
            local kMath = UEHelpers.GetKismetMathLibrary()
            local world = Utils.GetWorld()
            if not gs or not kMath or IsNotValid(world) then return end

            local rot = FRotator()
            if opts.AlignToVelocity and opts.Velocity then
                pcall(function() rot = kMath:Conv_VectorToRotator(opts.Velocity) end)
            end
            local scale = opts.Scale or 1
            local mode = opts.SpawnMode or 0
            local xform = kMath:MakeTransform(opts.Location, rot, FVector(scale, scale, scale))

            local ok, err = pcall(function()
                local proj = gs:BeginDeferredActorSpawnFromClass(world, cls, xform, mode, nil, 0)
                if IsNotValid(proj) then return end

                -- Instigator PRE-Finish.
                --   * The grenade's contact handler skips its own Instigator until the
                --     first bounce, and Instigator REPLICATES (MoveIgnoreActors is
                --     server-only) - both ends ignore the thrower until it lands.
                if Utils.IsActorValid(actor) then
                    pcall(function() proj:SetInstigator(actor) end)
                    pcall(function() proj.Instigator = actor end)
                    -- Belt-and-suspenders on the server: the physical sweep also ignores the
                    -- thrower (set pre-BeginPlay so the very first sweep skips it).
                    pcall(function()
                        if IsValid(proj.ProjectileCollision) then
                            proj.ProjectileCollision:IgnoreActorWhenMoving(actor, true)
                        end
                    end)
                end

                pcall(function() proj.WasThrown = opts.WasThrown ~= false end)
                -- VelocityOverride PRE-Finish so InitializeProjectile uses it verbatim
                --   (a post-Finish pm.Velocity is overwritten by the flat forward launch).
                --   * The opts.VelocityViaPM variant instead writes pm.Velocity
                --     POST-Finish (the LabRat's gentle drop path - preserved because the
                --     two interact with init differently).
                if opts.Velocity and not opts.VelocityViaPM then
                    pcall(function() proj.VelocityOverride = opts.Velocity end)
                end
                if opts.Damage then pcall(function() proj.DamageFromWeapon = opts.Damage end) end
                -- Landing makes NPCs go LOOK: the parent's own impact handler fires
                -- ReportNoiseEvent(impact, 1, <this projectile>, 1000, "playersound") when set.
                --   * ADDITIVE, not a swap for the damage event - the shipped crossbow bolt,
                --     harpoon, science bolt, net and thrown weapon all set it and all still deal
                --     damage (the impact bytecode reads like an either/or, but isn't).
                --   * Plain bool, no soft-ptr, so pre-Finish is safe and BeginPlay won't clobber it.
                --   * SOFT tag, so it can never chain-aggro (a forced tag would be wrong anyway:
                --     a noise aggros its INSTIGATOR, which here is the projectile itself).
                if opts.NoiseOnImpact then
                    pcall(function() proj.ReportNoiseOnImpact = true end)
                end
                if opts.PreFinish then pcall(opts.PreFinish, proj) end

                proj = gs:FinishSpawningActor(proj, xform, mode)
                if Utils.IsActorInvalid(proj) then return end
                if Utils.IsActorValid(actor) then pcall(function() proj:SetOwner(actor) end) end

                -- Contact-explosion armed on a LATER drain, never pre-Finish.
                --   * Armed early, a flask spawning in contact with a chasing player detonates
                --     INSIDE FinishSpawningActor - radial damage re-entering our hooks inside the
                --     drain (CLAUDE.md S6).
                if opts.ArmContactMs then
                    local armProj = proj
                    Utils.QueueWork(function()
                        if Utils.IsActorInvalid(armProj) then return end
                        pcall(function() armProj.ExplodesOnContact = true end)
                        pcall(function() armProj.ExplodesOnContactWithCharacter = true end)
                    end, opts.ArmContactMs)
                end

                -- AoE radii mutated on the instance ProjectileData IN PLACE, POST-Finish.
                --   * A whole-struct write-back mangles its soft-pointers (CLAUDE.md S3),
                --     and a pre-Finish write is clobbered by BeginPlay's build-from-row.
                if opts.AoEInner or opts.AoEOuter then
                    pcall(function()
                        local pd = proj.ProjectileData
                        if pd then
                            if opts.AoEInner then pd[P.AoE_InnerRadius] = opts.AoEInner end
                            if opts.AoEOuter then pd[P.AoE_OuterRadius] = opts.AoEOuter end
                        end
                    end)
                end

                -- ARM A HARMLESS ROW. A few rows ship CanDealDamage = false - projectile_snowball
                -- is the game's only visible-mesh one - and the parent's impact bails to
                -- NoDamageFromProjectile before ApplyPointDamage, so the shot flies, lands, plays
                -- its FX and does NOTHING. The row is shared with the player's own throwables, so
                -- the flag is flipped on THIS INSTANCE, in place, post-Finish - same rule as the
                -- AoE radii above.
                if opts.ArmDamage then
                    pcall(function()
                        local pd = proj.ProjectileData
                        if pd then pd[P.CanDealDamage] = true end
                    end)
                end

                -- Re-assert the collision ignore post-Finish (BeginPlay can rebuild collision).
                if Utils.IsActorValid(actor) then
                    pcall(function()
                        if IsValid(proj.ProjectileCollision) then
                            proj.ProjectileCollision:IgnoreActorWhenMoving(actor, true)
                        end
                    end)
                end

                if opts.SpeedMult then pcall(function() proj.ProjectileSpeedMultiplier = opts.SpeedMult end) end

                local pm = proj.ProjectileMovement
                if IsValid(pm) then
                    if opts.MaxSpeed then pcall(function() pm.MaxSpeed = opts.MaxSpeed end) end
                    if opts.Gravity then pcall(function() pm.ProjectileGravityScale = opts.Gravity end) end
                    if opts.Velocity and opts.VelocityViaPM then
                        pcall(function() pm.Velocity = opts.Velocity end)
                    end
                end

                if opts.PostFinish then pcall(opts.PostFinish, proj) end
            end)
            if not ok then LogBad(label .. " - " .. tostring(err)) end
        end

        -- Off-hook with the role split (CLAUDE.md S2): EIGT on dedicated, WorkQueue on a
        -- renderer host (EIGT there can flush mid component/widget paint).
        if STATE.Role == "DEDICATED" then ExecuteInGameThread(doSpawn) else Utils.QueueWork(doSpawn, 0) end
    end)
end

return PROJ
