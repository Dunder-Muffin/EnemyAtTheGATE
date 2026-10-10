-- =======================================================================
-- NpcManager (AUTHORITY ONLY) - decides which spawned NPCs become
-- Antevariants and runs the mutation pipeline on them.
--
-- Flow: SpawnerHooks.TrySpawnNPC -> HandleSpawnedActor -> (staggered via
-- WorkQueue) -> MutateActor -> generic pipeline built from the variant's
-- declarative definition (AnteNPCs/Variants).
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local ENUMS = require("AnteData.Enums")
local SPAWNERDATA = require("AnteData.SpawnerData")
local Resolver = require("AnteVariants.VariantResolver")
local Pipeline = require("AnteCore.Pipeline")
local AVU = require("AnteUtils.AVUtils")
local VariantTag = require("AnteVariants.VariantTag")
local CombatHooks = require("AnteVariants.CombatHooks")
local Utils = require("AnteUtils.Utils")
local VARIANTS = require("AnteVariants.Variants")

local LogBad = Utils.LogBad
local LogDebug = Utils.LogDebug

local NPCM = {}

-- Guard for pipeline steps resuming after an async wait (ACTOR_READY poll, the split gate's two
-- delays, LoadAssets).
--   * A sublevel can stream out during that wait (Megalift / bridge / zone-border) with no
--     world teardown: GameMode ReceiveEndPlay never fires, so ModEnabled stays true and the
--     WorkQueue keeps draining.
--   * IsActorValid still passes a mid-EndPlay actor in that window (level still loaded, not
--     yet PendingKill). Native calls there (SetBodyScale, OnReady attaches, Visuals material
--     sets) AV uncatchably by pcall.
--   * Same check trio as MutateActor's entry guard, re-run at every step boundary.
--   * Fails open on an unreadable IsActorBeingDestroyed; ModEnabled + IsActorInvalid are the base net.
local function stepActorGone(actor)
    if not STATE.ModEnabled then return true end
    if Utils.IsActorInvalid(actor) then return true end
    local beingDestroyed = false
    pcall(function() beingDestroyed = actor:IsActorBeingDestroyed() end)
    return beingDestroyed
end


-- Backstop for the SPAWN_FX gate. Comfortably past the longest native entrance (the Order rappel's
-- 3.5s SpawnFXDuration, which the gate only ever sees the tail of), with room for a WorkQueue
-- backed up by a spawn wave.
local SPAWN_FX_TIMEOUT_MS = 6000

-- Is the body done arriving? A gone actor counts as done - the READY step re-checks and bails, and
-- there is nothing to wait for. So does an unreadable flag: the gate is a courtesy, and no base
-- should sit out its timeout because a property read failed.
local function entranceDone(ctx)
    if stepActorGone(ctx.actor) then return true end
    local performing = false
    pcall(function() performing = ctx.actor.IsPerformingSpawnFX == true end)
    return not performing
end


-- =======================================================================
-- HandleSpawnedActor - called from the TrySpawnNPC hook (game thread).
--   * Decides on an NPC variant. Queues the mutation with a random stagger
--     (the game fires many spawners in the same frame on area load).
--   * rowName = the spawned NPC's base game identifier (Utils.GetActorRowName,
--     e.g. "Pest", "Pest_Carbonated", "Exor_Monk"). It's stable across our
--     DisplayName mutation, so re-running on saved/already-mutated NPCs
--     Just Works - no special-casing needed.
--   * Returns the resolved variant name or nil.
-- =======================================================================
function NPCM.HandleSpawnedActor(spawner, actor, rowName, spawnedCount)

    local spawnerName = Utils.GetSpawnerName(spawner)
    if not spawnerName then return nil end

    if NPCM.ShouldSkipMutation(rowName) then return nil end

    -- SD.Rules, not SD.Spawners: a phased entry must resolve to the band in force NOW.
    local rules = SPAWNERDATA.Rules(spawnerName)
    local variantName = Resolver.Resolve(rules, rowName)

    -- HARD MODE fallback: a spawner with no verdict of its own defers to SD.HardVariants
    -- (row -> hard variant), so e.g. every native Exor Monk hardens without per-spawner
    -- entries. An authored mapping above always wins; VariantLimit below still applies.
    if variantName == "" and STATE.HardModeNoMercy then
        variantName = SPAWNERDATA.HardVariants[rowName] or ""
    end

    if variantName == "" then return nil end

    -- SpawnAs spawners can fire one pre-swap cycle of the original NPC type;
    -- only mutate when the spawned NPC is one of this variant's accepted bases
    -- (its Base or an AltBase - closely-related rows that share the skeleton,
    -- e.g. a base-"Grunt" variant accepting "Grunt_Guard").
    local variant = VARIANTS[variantName]
    if variant and not VariantTag.AcceptsBase(variant, rowName) then
        LogDebug(string.format("[%s] %s is not a base of %s (%s) - skipping",
            spawnerName, rowName, variantName, variant.Base), SETTINGS.DEBUG_NPC_ACTIONS)
        return nil
    end

    -- VariantLimit: only the first X NPCs this spawner has out become variants;
    -- the rest stay vanilla.
    --   * Orthogonal to client tagging - only mutated NPCs get the WalkSpeed tag,
    --     so a capped-out NPC reads as vanilla on the client too (nothing to special-case).
    if rules and rules.VariantLimit and spawnedCount
             and spawnedCount > rules.VariantLimit then
        return nil
    end

    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) then return end
        -- THIS is the only path that runs off a real placed spawner, so it is the only one
        -- that sets FromSpawner. Two things read it:
        --   * Stagger - spread a wave's AddComponent cost over ticks instead of hitching one
        --     frame (summons/story/debug attach immediately; they arrive one at a time).
        --   * opts.FromSpawner is handed to def.Stats, so a variant can behave differently
        --     when it was placed in the world vs conjured by a script/summon/debug keybind -
        --     e.g. the Constrictor Bot only keeps its native grab on wild, spawner-born bots.
        NPCM.MutateActor(variantName, actor, { Stagger = true, FromSpawner = true })
    end, math.random(300, 1000))

    return variantName
end


-- =======================================================================
-- PET GUARD - a tamed animal belongs to the GAME unless we ship a pet form for it.
--   * PlayerPets defs (Magma Pest, Electro Peccary, ...) are the native craftable pets
--     redressed as wild enemies, mostly via Faction = 5.
--   * The game sets a pet's faction to its owner's team exactly ONCE, at buff-apply
--     (Buff_Follower.UpdateFaction), and nothing re-runs it. A later re-mutation that writes
--     Faction = 5 over that makes the pet permanently hostile to its owner.
--   * Every route that can re-mutate a LIVE pet funnels through MutateActor (pest-trap
--     re-apply, spawner save-restore heal, PlacedSpawns, debug /spawn), so one guard here
--     covers all of them.
--   * Allowed on a pet: the tamed forms themselves, and a wild variant with def.TamedVariant
--     (PetManager swaps it to that form once registered; such defs never override Faction).
--     Everything else has no pet form, so leave the animal to the game.
--   * "Is it a pet" = the O(1) CachedFollowerBuffActor field, not AVU.GetFollowerBuff (that
--     falls back to FindAllOf, and this check runs on every spawn).
-- =======================================================================
local petFormNames   -- { tamedVariantName -> true }, built once from the registry
local function variantAllowedOnPet(variantName, varData)
    if varData.TamedVariant then return true end        -- a WILD variant that has a pet form
    if varData.PetForm then return true end             -- a PET-ONLY def (no wild counterpart to
                                                        -- point at it - the Plasmogi, fed into
                                                        -- being). Same contract: sets no Faction.
    if not petFormNames then
        petFormNames = {}
        for _, d in pairs(VARIANTS) do
            if d.TamedVariant then petFormNames[d.TamedVariant] = true end
        end
    end
    return petFormNames[variantName] == true            -- the pet form itself
end

local function isTamedPet(actor)
    local buff
    pcall(function() buff = actor.CachedFollowerBuffActor end)
    return IsValid(buff)
end


-- =======================================================================
-- MutateActor - run the variant's mutation pipeline.
-- Steps:
--   STATS        (authority data: movement/damage/immunities/DisplayName)
--   ACTOR_READY  (wait until the actor's mesh exists)
--   LoadAssets   (async; skipped when neither OnReady nor render visuals need them)
--   VISUAL_DELAY (short settle - the appearance half of the split gate)
--   BODYSCALE / NAVRADIUS / HITPAD
--   VISUALS      (tint/attachments - host & single player only; pure clients
--                 run this through ClientVisuals instead)
--   READY_DELAY + SPAWN_FX  (the behaviour half: wait the native entrance out)
--   READY        (def.OnReady - authority, dedicated included)
-- The two gates and why they differ: the SPLIT GATE comment down in the step list.
-- =======================================================================
function NPCM.MutateActor(variantName, actor, opts)
    opts = opts or {}

    if not variantName or variantName == "" then return end

    -- WORLD TEARDOWN GUARD (zone transition): the mutation is staggered 300-1000ms after
    -- the spawn, so a player leaving the zone in that window fires it mid-teardown.
    --   * StopMod (GameMode ReceiveEndPlay) flips ModEnabled=false as the old world unloads;
    --     once it's down, the old actors are being destroyed and the STATS native calls
    --     (ApplyBaseStats / InitalizeHealthValues / MarkReplicatedDirty) would AV on them -
    --     an UNCATCHABLE-by-pcall crash. Bail.
    if not STATE.ModEnabled then return end

    local varData = VARIANTS[variantName]
    if not varData then
        LogDebug("MutateActor - no dispatch for: " .. variantName, SETTINGS.DEBUG_NPC_ACTIONS)
        return
    end

    -- UNUSED AS OF LABS UPDATE (06.26.26) -
    -- Spawn-time UPGRADE roll: a variant can declare UpgradeChance (0..1) + UpgradeInto
    -- (another variant name) to become a rarer version on spawn.
    --   * Re-route BEFORE anything is applied, so the upgrade gets its own Id/Stats/Visuals
    --     (and thus client-side mirroring). (Generic infra - no variant currently uses it.)
    if varData.UpgradeInto and varData.UpgradeChance and math.random() < varData.UpgradeChance then
        local up = VARIANTS[varData.UpgradeInto]
        if up then
            LogDebug("MutateActor - upgraded " .. variantName .. " -> " .. varData.UpgradeInto,
                SETTINGS.DEBUG_NPC_ACTIONS)
            variantName, varData = varData.UpgradeInto, up
        end
    end

    if Utils.IsActorInvalid(actor) then
        LogBad("MutateActor - actor invalid: " .. variantName)
        return
    end

    -- Stronger than IsActorValid for the transition window: that passes an actor whose level
    -- is only PARTWAY unloaded (IsLevelLoaded still true) and that isn't PendingKill yet
    -- (IsValid still true) but is mid-EndPlay - IsActorBeingDestroyed catches that.
    --   * Fail-open (proceed if unreadable) - ModEnabled + IsActorInvalid are the main net.
    local beingDestroyed = false
    pcall(function() beingDestroyed = actor:IsActorBeingDestroyed() end)
    if beingDestroyed then
        LogDebug("MutateActor - actor being destroyed, skipping: " .. variantName, SETTINGS.DEBUG_NPC_ACTIONS)
        return
    end

    -- PET GUARD (see the banner above): a tamed animal is the game's unless we ship a pet
    -- form for this variant.
    --   * Checked BEFORE anything is applied - ApplySafetyStats included - so a pet never
    --     takes a single field write from a wild-only redress.
    if not variantAllowedOnPet(variantName, varData) and isTamedPet(actor) then
        LogDebug("MutateActor - " .. variantName .. " has no pet form; leaving the tamed "
            .. tostring(Utils.GetActorRowName(actor)) .. " to the game", SETTINGS.DEBUG_NPC_ACTIONS)
        return
    end

    -- An instance of this base NPC now exists, register its class-specific hooks
    --   * Crumbed: registering resolves the hook path, and the "registered" line only prints
    --     once that has come back.
    if varData.Base then
        Utils.Crumb("mut:classhooks")
        CombatHooks.RegisterClassHooks(varData.Base, variantName)
    end

    -- TAMABLE variant: stamp the actor's wild identity with the PetManager NOW.
    --   * The native TAME re-inits the NPC (DisplayName reverts to base) - on a dedicated
    --     server before the pet poll ever sees it - so registration needs an identity that
    --     survives the tame (same actor).
    if varData.TamedVariant then
        pcall(function() require("ModulePets.PetManager").NoteWildVariant(actor, variantName) end)
    end

    -- Stagger the VISUALS step's component-attach burst across ticks (vs all in one frame).
    --   * Default: ON for spawner waves (opts.Stagger from the spawner dispatch),
    --     OFF for summons / story / debug.
    --   * A variant can force it either way with def.StaggerAttach (true/false).
    local stagger = (opts.Stagger == true)
    if varData.StaggerAttach ~= nil then stagger = varData.StaggerAttach end
    AVU.SetStaggerAttach(actor, stagger)

    LogDebug("MutateActor - mutating into " .. variantName, SETTINGS.DEBUG_NPC_ACTIONS)

    -- HARD MODE (HARDMODE.NoMercy): def.HardMode = { BasicStats, TimeDilation, DebuffsImmune }
    -- overlays def.* into transient locals used below.
    --   * Transient by design: never written into the def, since combat hooks resolve the
    --     shared registry table by name at fire time, and tamed forms are separate defs.
    --   * Values are absolute, like BasicStats itself (the safety pass re-applies them).
    --   * A hard TimeDilation only reaches clients as fast movement: CustomTimeDilation
    --     doesn't replicate, and ClientVisuals re-applies the def's base value instead.
    local hardMode = STATE.HardModeNoMercy and varData.HardMode or nil
    local basicStats = varData.BasicStats
    if hardMode and hardMode.BasicStats then
        basicStats = {}
        for k, v in pairs(varData.BasicStats or {}) do basicStats[k] = v end
        for k, v in pairs(hardMode.BasicStats) do basicStats[k] = v end
    end
    local timeDilation = (hardMode and hardMode.TimeDilation) or varData.TimeDilation

    -- def.HardMode.DebuffsImmune APPENDS (it never replaces): the def's own list is what the
    -- variant IS, the hard block is what hard mode adds on top - most of them just Fear, so a
    -- hard body doesn't flee the fight it was tuned for. Duplicate rows are harmless (the native
    -- list is only ever searched), so no dedup pass.
    local debuffsImmune = varData.DebuffsImmune
    if hardMode and hardMode.DebuffsImmune then
        debuffsImmune = {}
        for _, v in ipairs(varData.DebuffsImmune or {}) do debuffsImmune[#debuffsImmune + 1] = v end
        for _, v in ipairs(hardMode.DebuffsImmune) do debuffsImmune[#debuffsImmune + 1] = v end
    end

    -- NEUTER-FIRST. Every step below is deferred (WorkQueue drain), and STATS - the step that
    -- tones the NPC down - can bail via stepActorGone if the sublevel streams out.
    --   * For a variant weaker than its base (the SpawnAs pattern: a Signal Pest is really a
    --     Pest_Volatile at 10 HP / 1 dmg instead of 200 / 150) that bail leaves a full-strength
    --     late-game enemy in an early zone.
    --   * So apply the danger knobs synchronously here, before STATS: a half-finished mutation
    --     is ugly, not deadly. STATS re-applies the same block; absolute values make that a no-op.
    --   * See AVU.ApplySafetyStats for why speed/armor are excluded.
    if basicStats then
        Utils.Crumb("mut:safety")
        AVU.ApplySafetyStats(actor, basicStats)
    end

    local steps = {
        Pipeline.Do("STATS", function(ctx)
            if stepActorGone(ctx.actor) then return end
            AVU.ApplyBaseStats(ctx.actor, opts, variantName)

            -- def.BasicStats: declarative movement/damage/HP/armor block, applied BEFORE Stats()
            -- so a computed Stats() can override any field.
            --   * See AVU.ApplyBasicStats (HP -> faction-safe limb rebuild, Armor -> read live,
            --     rest -> NPCData writes).
            --   * `basicStats` = def.BasicStats with the def.HardMode overlay merged (above).
            if basicStats then AVU.ApplyBasicStats(ctx.actor, basicStats) end

            -- def.DebuffsImmune: the rows Server_ApplyBuff must refuse on this NPC.
            --   * Also BEFORE Stats(), so a variant can still add conditional ones itself.
            --   * def.DebuffsImmuneReplace wipes the base's own list first (rare - see AVU).
            --   * `debuffsImmune` = def.DebuffsImmune with def.HardMode's list appended (above).
            if debuffsImmune then
                AVU.AddDebuffImmunities(ctx.actor, debuffsImmune, varData.DebuffsImmuneReplace)
            end

            -- def.ImmuneToBackstabs: opt out of the Sneak skill's double-damage entirely. A native
            -- bool on NPC_Base that CheckForStealthAttackBonusDamage checks before it applies the
            -- bonus, alongside IsDeadOrDBNO and RecentlyCriticalHit. Nothing in the game sets it.
            -- For bodies a fight is supposed to be built around, so an unaware opening shot cannot
            -- simply delete them. Not hard-mode gated - a boss being un-backstabbable is a trait,
            -- not a difficulty. (HARDMODE.NoAvail also caps the bonus globally; this is absolute.)
            if varData.ImmuneToBackstabs then
                pcall(function() ctx.actor.ImmuneToBackstabs = true end)
            end

            -- def.NoHitReaction: no physics flinch on impact. This is the authority's half (a
            -- weapon hit traces the physics asset, which a limp body has moved); a listen host is
            -- its own renderer, and a pure client blanks its own copy in ClientVisuals.
            if varData.NoHitReaction then AVU.DisableHitReaction(ctx.actor) end

            -- def.NoAggroAnim / def.HardMode.NoAggroAnim: no aggro cower on combat entry, no
            -- startle spook. First step on purpose - a body that lands beside a player enters
            -- combat before OnReady's entrance wait is over.
            if AVU.NoAggroAnimFor(varData) then AVU.SkipAggroAnim(ctx.actor) end

            -- GAMEPLAY.AI_SENSE.Eyesight - how fast the "spotted" meter fills once the target is
            -- visible at all (the two stages are independent; see AnNotes/AnteSystems/NPCPerception.md).
            --   * Runs before Stats() so a def can still override it outright.
            --   * Idempotent: ScaleEyesight multiplies the CLASS DEFAULT, not the live value, so
            --     re-mutation can't compound it. No-ops at nil.
            local senses = SETTINGS.GAMEPLAY.AI_SENSE
            AVU.ScaleEyesight(ctx.actor, senses.Eyesight)
            -- NO CONE WRITE HERE, deliberately: a SensesConfig write on a live listener costs the
            -- NPC ~10s of sight (RequestStimuliListenerUpdate re-registers it) for the ~10 degrees
            -- a global floor would buy, so variants keep their native cone. Eyesight is safe: a
            -- plain controller field with no listener involvement. See SN.SetSightConfig in AVSenses.

            if varData.Stats then
                Utils.Crumb("stats:def")
                varData.Stats(ctx.actor, opts)
            end
            if varData.OnTick then AVU.RegisterOnTickActor(ctx.actor, varData.OnTick, "def") end

            -- def.Faction: override the NPC's team (e.g. put a repurposed pet on the A2 side).
            --   * Applied AFTER Stats because AVU.SetNpcLevel re-runs InitializeNPCVariables,
            --     which resets Faction to the NPCData row default.
            --   * See AVU.SetFaction for the hostility rules
            --     (0 = hostile to all non-same-class, 1 = all, N>=2 = team).
            if varData.Faction ~= nil then AVU.SetFaction(ctx.actor, varData.Faction) end

            -- Baseline CustomTimeDilation. Doesn't replicate, so ClientVisuals re-applies it.
            --   * MirrorTimeDilation variants also push the baseline over VariantSignal
            --     (AVU.SetTimeDilation) so the client matches before any ability changes it;
            --     others just set it locally.
            -- (`timeDilation` = def.TimeDilation, or def.HardMode.TimeDilation in hard mode.)
            if timeDilation then
                if varData.MirrorTimeDilation then
                    AVU.SetTimeDilation(ctx.actor, timeDilation)
                else
                    ctx.actor.CustomTimeDilation = timeDilation
                end
            end

            -- Sets the ID tag for client-side identification
            --   For clients, Visuals and DisplayName don't replicate so we're embedding an ID in WalkSpeed
            VariantTag.Apply(ctx.actor, varData)

            -- The damage hook resolves a causer's name once, on its first hit, and dispatches
            -- OnDealtDamage by it. A pet thrown before its re-mutation bites under the base name,
            -- which would silence its on-hit behaviors for good - so forget the stale one now.
            pcall(function() Utils.ForgetCauserAddr(ctx.actor:GetAddress()) end)

            -- PUSH THE SPEEDS LIVE. BasicStats/Stats only write NPCData.Default(Walk|Sprint)Speed;
            -- MaxWalkSpeed is recomputed from those only by LocalUpdateWalkSpeed, which the soldier
            -- line otherwise only reaches via OnRep_CombatState / UpdateHealthTextureIndex. So a
            -- body mutated while already in combat (save-restore, /reload, an assault spawn that
            -- aggros mid-stagger) would keep its base speed until it next disengages.
            --   * This call is the fix, and the right one: it picks walk-vs-sprint off
            --     WantsToSprint() (CombatState, for a non-pet NPC), applies Speed_Multiply, marks
            --     dirty, and OnReps. A hand-rolled AVU.SetMoveSpeed would slam the walk value onto
            --     a sprinting body.
            --   * Must run AFTER VariantTag.Apply - it re-derives from NPCData, where the tag
            --     fraction now lives, so this is tag-safe.
            pcall(function() ctx.actor:LocalUpdateWalkSpeed() end)
        end),

        -- A body that leaves play mid-wait (a summoner's orchestra dying with it) just stops here.
        Pipeline.WaitFor("ACTOR_READY", function(ctx)
            return Utils.GetValidMesh(ctx.actor) ~= nil
        end, 5000, function(ctx)
            if not stepActorGone(ctx.actor) then return false end
            local TAP = require("AnteCore.TestTap")
            if TAP.on then TAP.Count("abandoned", "ACTOR_READY", variantName) end
            LogDebug("MutateActor - " .. variantName .. " left play before its mesh was ready",
                SETTINGS.DEBUG_NPC_ACTIONS)
            return true
        end),
    }

    -- OnReady is an AUTHORITY-side post-spawn hook (subactor attach, etc.) - it runs
    -- everywhere the NPC is authoritative, including dedicated servers.
    --   * Visuals are renderer-only (host/SP; pure clients use ClientVisuals).
    --   * def.Tint is a DECLARATIVE Visuals: the body-mesh recolor nearly every variant wants,
    --     so a purely-recolored variant needs no Visuals() function. It counts as render work.
    local renderVisuals = Utils.HasRenderer() and (varData.Visuals or varData.Tint)

    -- Load assets once if either step needs them (subactor classes go in Assets so they're cached
    -- before OnReady's AttachSubactor runs). Ahead of both gates below: the load is async, so
    -- sitting it behind them only stacked a cold load's cost onto whichever ran first.
    if varData.OnReady or renderVisuals then
        table.insert(steps, Pipeline.LoadAssets())
    end

    -- THE SPLIT GATE. Appearance and behaviour used to share one wait, sized for the slowest
    -- entrance in the set - which is why a rappelling grunt roped down looking vanilla and
    -- reskinned a beat after it landed. They want different things:
    --   * APPEARANCE dresses the body's own mesh, which is up and on screen for the whole
    --     entrance. It needs the mesh plus a short settle, and nothing else.
    --   * BEHAVIOUR (OnReady) often reads where the body IS or drives its controller - a Commander
    --     mid-rappel would build its barricade in mid-air - so it waits the entrance OUT.
    -- def.SpawnDelay keeps its old meaning and still gates OnReady; def.VisualDelay overrides the
    -- appearance half on its own (per-spawn opts win over both, as everywhere else).
    local spawnDelay  = opts.SpawnDelay or varData.SpawnDelay or AVU.SpawnAnimDelay(varData.Base)
    local visualDelay = opts.VisualDelay or varData.VisualDelay or AVU.VisualDelay(spawnDelay)

    table.insert(steps, Pipeline.Delay("VISUAL_DELAY", visualDelay))

    -- TRUE actor scale (capsule + mesh -> hitbox scales too).
    --   * AUTHORITY: runs everywhere the NPC is authoritative (incl. dedicated, which owns
    --     hit reg). Pure clients mirror the same value in ClientVisuals; host/SP get it here.
    --   * Applied post-settle (after VISUAL_DELAY) so the spawn anim/capsule init doesn't stomp it.
    if varData.BodyScale then
        table.insert(steps, Pipeline.Do("BODYSCALE", function(ctx)
            if stepActorGone(ctx.actor) then return end   -- async: sublevel may have streamed out since VISUAL_DELAY
            AVU.SetBodyScale(ctx.actor, varData.BodyScale)
        end))
    end

    -- Movement footprint WITHOUT the size: pull the root capsule back to an absolute radius so an
    -- upscaled body still fits its hallways, while the mesh (and the physics asset a weapon hit
    -- actually traces) stays big. MUST run after BODYSCALE - the write is absolute and divides the
    -- final actor scale back out. Same both-ends contract as BodyScale; ClientVisuals mirrors it.
    if varData.NavRadius then
        table.insert(steps, Pipeline.Do("NAVRADIUS", function(ctx)
            if stepActorGone(ctx.actor) then return end
            AVU.SetNavRadius(ctx.actor, varData.NavRadius)
        end))
    end

    -- Hitbox WITHOUT the size: an invisible hit sphere for a body whose physics asset is much
    -- tighter than its silhouette (the Mage Eye). Same both-ends contract as BodyScale - the weapon
    -- trace runs on the SHOOTER and the component doesn't replicate, so ClientVisuals mirrors it.
    if varData.HitPad then
        table.insert(steps, Pipeline.Do("HITPAD", function(ctx)
            if stepActorGone(ctx.actor) then return end
            local p = varData.HitPad
            if type(p) == "table" then
                AVU.PadHitbox(ctx.actor, p.Radius, p)
            else
                AVU.PadHitbox(ctx.actor, p)
            end
        end))
    end

    if renderVisuals then
        table.insert(steps, Pipeline.Do("VISUALS", function(ctx)
            if stepActorGone(ctx.actor) then return end

            -- def.Tint FIRST, so a Visuals() can still override any of it (same contract
            -- as BasicStats -> Stats). ClientVisuals applies the identical block, same order.
            if varData.Tint then AVU.TintMesh(ctx.actor, varData.Tint) end

            if varData.Visuals then varData.Visuals(ctx.actor, ctx.assets or {}) end
        end))
    end

    -- The behaviour half of the split gate: whatever is left of def.SpawnDelay, then the entrance.
    if varData.OnReady then
        local readyDelay = spawnDelay - visualDelay
        if readyDelay > 0 then
            table.insert(steps, Pipeline.Delay("READY_DELAY", readyDelay))
        end

        -- Wait the native spawn-in out for real rather than guessing at its length. The flag is the
        -- game's own "still arriving" state (the same one that parks the BT through IsNPCBusy), and
        -- the server clears it during BeginPlay on any base without an entrance - so this costs one
        -- poll on everything that pops straight in, and lands OnReady as a rappel touches down.
        table.insert(steps, Pipeline.WaitAtMost("SPAWN_FX", entranceDone, SPAWN_FX_TIMEOUT_MS,
            function()
                LogDebug("MutateActor - " .. variantName .. " still arriving after "
                    .. SPAWN_FX_TIMEOUT_MS .. "ms; running OnReady anyway",
                    SETTINGS.DEBUG_NPC_ACTIONS)
            end))

        table.insert(steps, Pipeline.Do("READY", function(ctx)
            if stepActorGone(ctx.actor) then return end
            -- `opts` too: the summoner's per-spawn table (the same one Stats gets), so one variant
            -- can be spawned in two shapes without a near-duplicate def - e.g. an Artillery Bot
            -- portalled into an arena with { NoBunker = true }.
            varData.OnReady(ctx.actor, ctx.assets or {}, opts)
        end))
    end

    Pipeline.Run(steps, { actor = actor, paths = varData.Assets or {}, name = variantName })
end


-- =======================================================================
-- Mod compatibility skips. rowName is the base game identifier
-- (Utils.GetActorRowName); NpcGroupings is keyed by row name.
-- =======================================================================
function NPCM.ShouldSkipMutation(rowName)

    if SETTINGS.MOD_COMPATIBILITY.DISABLE_ORDER_ANTEVARIANTS
        and ENUMS.NpcGroupings.ORDER[rowName] then
        LogDebug(rowName .. " skipped (Order variants disabled)", SETTINGS.DEBUG_NPC_ACTIONS)
        return true
    end

    if SETTINGS.MOD_COMPATIBILITY.DISABLE_GK_ANTEVARIANTS
        and ENUMS.NpcGroupings.GATEKEEPERS[rowName] then
        LogDebug(rowName .. " skipped (Gatekeeper variants disabled)", SETTINGS.DEBUG_NPC_ACTIONS)
        return true
    end

    return false
end

return NPCM
