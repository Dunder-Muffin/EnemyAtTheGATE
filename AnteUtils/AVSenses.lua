-- =======================================================================
-- AVSenses (SN) - AI PERCEPTION: sight, hearing, noise events, and the spot meter's Eyesight dial.
-- Split out of AVUtils, merged back onto AVU: callers still write AVU.SetSightConfig /
-- SetHearingSense / ReportNoise / ScaleEyesight / ...
--
-- MUST-KNOWS
--   * AUTHORITY only - perception is server-side.
--   * THERE IS NO SIGHT EVENT. Sight is POLLED by the controller every 0.5s into a hand-rolled
--     spot meter, and only a full meter enters combat. Two stages, two different knobs:
--     the engine sense config (SN.SetSightConfig - is this even a candidate) and Eyesight
--     (SN.ScaleEyesight - how fast the meter fills). Full decode: AnNotes/AnteSystems/NPCPerception.md.
--   * STAGE 1 IS A PER-FRAME TRACE BUDGET (SN.SetSightBudget). Stock MaxTracesPerTick is 6 for
--     the WHOLE WORLD, so with ~22 listeners a pair comes round every 5-20s and no amount of
--     Eyesight/radius/light helps a pair the engine has not traced yet.
--   * SIGHT IS LIGHT-GATED, and "lit" means a POWERED light fixture within 25m of the PLAYER -
--     not brightness. Outdoors/blacked out = light 0 = blind past 5m, and IgnoreLightLevel does
--     NOT fix that (the gain multiplies by light). SN.StartLightFloor is the lever.
--   * HEARING is the one EVENT sense, and a "gunfire"/"touch" tagged noise FORCE-SPOTS through
--     walls (SN.ReportNoise) - the cheapest aggro channel there is, and the easiest to overdo.
--   * ANY SensesConfig write on a live listener costs that NPC ~10s of SIGHT (the
--     RequestStimuliListenerUpdate re-registers it), and doing it DURING mutation can deregister
--     perception outright. Measured, not theoretical - see SN.SetSightConfig before adding one.
--   * A missing UObject property reads back as a TrivialObject, never nil, so a sense config must
--     be picked by IsA, NEVER by duck-typing a field ([[ue4ss-missing-property-trivialobject]]).
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local ASSETS = require("AnteCore.AssetManager")
local ENUMS = require("AnteData.Enums")
local Utils = require("AnteUtils.Utils")

-- Startup chatter (what each hoist/floor armed, what the sweep fixed) is one line per mechanism per
-- world and says nothing once the setup is known-good, so it sits behind SETTINGS.DEBUG_SENSES.
-- FAILURES still log unconditionally through Utils.LogBad - a hoist that didn't arm is not chatter.
local function LogSense(msg)
    if SETTINGS.DEBUG_SENSES then Utils.Log(msg) end
end

---@class AVU.Senses      -- merged onto AVU in AVUtils; the name is what makes goto-def work
local SN = {}

-- Native "/Script/..." classes are always resident, so GetIfValid never loads here.
local SENSE_SIGHT_CLASS = "/Script/AIModule.AISenseConfig_Sight"
local SENSE_HEARING_CLASS = "/Script/AIModule.AISenseConfig_Hearing"
SN.SENSE_SIGHT_CLASS = SENSE_SIGHT_CLASS
SN.SENSE_HEARING_CLASS = SENSE_HEARING_CLASS


-- =======================================================================
-- RANGES - the raw sense-config setters
-- =======================================================================

-- [AUTHORITY] MULTIPLY sight + hearing ranges.
-- Every write GUARDS ITS READ: a 0/nil read (perception not built yet) times a multiplier writes 0
-- and BLINDS the NPC, so a bad read falls back to a sane absolute instead. One listener update at
-- the end - per-sense calls can leave it half-re-registered.

function SN.BoostSenses(actor, sightMultiplier, hearingMultiplier)
    sightMultiplier = sightMultiplier or 1.5
    hearingMultiplier = hearingMultiplier or 1.5

    local perception = actor.AIPerception
    if IsNotValid(perception) then return end

    local sensesConfig = perception.SensesConfig
    if not sensesConfig then return end

    local sightClass = ASSETS.GetIfValid(SENSE_SIGHT_CLASS)
    local hearingClass = ASSETS.GetIfValid(SENSE_HEARING_CLASS)
    local changed = false

    for i = 1, math.min(#sensesConfig, 5) do
        local sense = sensesConfig[i]

        if sightClass and sense and sense:IsA(sightClass) then
            local r  = sense.SightRadius or 0
            local lr = sense.LoseSightRadius or 0
            sense.SightRadius     = (r  > 0) and (r  * sightMultiplier) or 3000
            sense.LoseSightRadius = (lr > 0) and (lr * sightMultiplier) or 6000
            changed = true
        end

        if hearingClass and sense and sense:IsA(hearingClass) then
            local h  = sense.HearingRange or 0
            local lh = sense.LoSHearingRange or 0
            sense.HearingRange    = (h  > 0) and (h  * hearingMultiplier) or 3000
            sense.LoSHearingRange = (lh > 0) and (lh * hearingMultiplier) or 5000
            changed = true
        end
    end

    if changed then
        perception:RequestStimuliListenerUpdate()
    end
end


-- [AUTHORITY] Absolute sight values; nil arguments are left unchanged.

function SN.SetSightSense(actor, sightRadius, loseSightRadius, peripheral)
    local perception = actor.AIPerception
    if IsNotValid(perception) then return end

    local sensesConfig = perception.SensesConfig
    if not sensesConfig then return end

    local sightClass = ASSETS.GetIfValid(SENSE_SIGHT_CLASS)
    if not sightClass then return end

    for i = 1, math.min(#sensesConfig, 10) do
        local config = sensesConfig[i]
        if config and config:IsA(sightClass) then
            if sightRadius and sightRadius > 0 then config.SightRadius = sightRadius end
            if loseSightRadius and loseSightRadius > 0 then config.LoseSightRadius = loseSightRadius end
            if peripheral and peripheral > 0 then config.PeripheralVisionAngleDegrees = peripheral end
            perception:RequestStimuliListenerUpdate()
            return
        end
    end
end


-- [AUTHORITY] Absolute hearing values; nil = leave unchanged.
--   * 0 is VALID and DEAFENS the NPC - it then ignores every noise stimulus, including the
--     damage-alert one, so a deaf guard doesn't aggro off a cellmate getting shot.
--   * SN.BoostSenses reads 0 as a bad read and restores its 3000 fallback, so re-assert after a
--     re-mutation (a delayed setter queued from Stats does this naturally). SN.SweepHearing is the
--     other way round: an exact 0 is the one value it reads as deliberate and leaves alone.

function SN.SetHearingSense(actor, hearingRange, losHearingRange)
    local perception = actor.AIPerception
    if IsNotValid(perception) then return end

    local sensesConfig = perception.SensesConfig
    if not sensesConfig then return end

    local hearingClass = ASSETS.GetIfValid(SENSE_HEARING_CLASS)
    if not hearingClass then return end

    for i = 1, math.min(#sensesConfig, 10) do
        local config = sensesConfig[i]
        if config and config:IsA(hearingClass) then
            if hearingRange then config.HearingRange = hearingRange end
            if losHearingRange then config.LoSHearingRange = losHearingRange end
            perception:RequestStimuliListenerUpdate()
            return
        end
    end
end


-- Current HearingRange as a real Lua NUMBER, or nil when the NPC has NO hearing config at all
-- (the Composer - deafness is expressed as an absent config). The read half of SetHearingSense.
-- Picked by IsA, and tonumber'd: a duck-typed read would match the SIGHT config and then blow up
-- as "attempt to compare TrivialObject with number" at the first arithmetic.

function SN.GetHearingRange(actor)
    if Utils.IsActorInvalid(actor) then return nil end

    local perception = actor.AIPerception
    if IsNotValid(perception) then return nil end

    local sensesConfig = perception.SensesConfig
    if not sensesConfig then return nil end

    local hearingClass = ASSETS.GetIfValid(SENSE_HEARING_CLASS)
    if not hearingClass then return nil end

    local found
    pcall(function()
        for i = 1, math.min(#sensesConfig, 10) do
            local config = sensesConfig[i]
            if config and IsValid(config) and config:IsA(hearingClass) then
                found = tonumber(config.HearingRange)
                return
            end
        end
    end)
    return found
end


-- Apply SetSightSense a few seconds after mutation, so the write can't land inside the mutation
-- drain (which can deregister perception outright).
-- This only delays the ~10s sight outage every SensesConfig write causes; it does not avoid it.
-- See SN.SetSightConfig for the full hazard. Only worth it for a large permanent gain.

function SN.SetSightSenseDelayed(actor, sightRadius, loseSightRadius, peripheral, delayMs)
    Utils.QueueWork(function()
        if Utils.IsActorValid(actor) then
            SN.SetSightSense(actor, sightRadius, loseSightRadius, peripheral)
        end
    end, delayMs or 4000)
end


-- =======================================================================
-- NOISE EVENTS - the one aggro channel that is EVENT-driven, not polled
-- =======================================================================
-- One native call reaches every hearing listener via the engine's listener map: no scan, no
-- per-NPC loop, doesn't degrade with crowd size. The TAG picks the branch (Aggro/Touch force-spot
-- instantly, skipping cone/light/meter but still checking hostility; Loud/Soft/Smell just seed an
-- investigate). Full decode + measurements: AnNotes/AnteSystems/NPCPerception.md.
--   * INSTIGATOR is the aggro TARGET, not a position.
--   * Two range gates, smaller wins: HearingRange (SN.HoistHearing) is a hard ceiling on `Range`.
--   * Never fire Aggro from something that itself reacts to a noise - that cascades.
-- Safe in a WorkQueue drain: only appends to the sense's pending list, nothing loadable.

SN.NOISE_TAGS = {
    Aggro = "playersound_gunfire",   -- forced: instant target + startle
    Touch = "touch",                 -- forced (native: taking a hit, 100uu)
    Loud  = "playersound_loud",      -- soft: investigate, treated as the "loud" variant
    Soft  = "playersound",           -- soft: investigate
    Smell = "stinky",                -- pest family: investigate. Everyone else: unforced seed
}

-- [AUTHORITY] Fire a noise event. Returns true if it was reported.
--   instigator  WHO the hearers should attack/investigate. Required, must be a valid actor.
--   opts        { Tag = AVU.NOISE_TAGS.* (default Soft), Range = uu (default 1500),
--                 Loudness = number (default 1), Pos = {X,Y,Z} (default the instigator's spot) }

function SN.ReportNoise(instigator, opts)
    if not Utils.IsAuthority() then return false end
    if Utils.IsActorInvalid(instigator) then return false end

    local hearing = Utils.GetHearingSense()
    if IsNotValid(hearing) then return false end

    opts = opts or {}
    local pos = opts.Pos or instigator:K2_GetActorLocation()
    if not pos or not pos.X then return false end

    -- pcall'd: a UE4SS build that resolves this static UFunction differently must degrade to
    -- "no noise", never take the caller down with it.
    local ok = pcall(function()
        hearing:ReportNoiseEvent(Utils.GetWorld(), pos, opts.Loudness or 1, instigator,
                                 opts.Range or 1500, FName(opts.Tag or SN.NOISE_TAGS.Soft))
    end)
    return ok
end


-- [AUTHORITY] "Everyone within `range` who can hear, come kill `target` NOW." Keep range modest
-- (1000-2500) - this is the one knob that can genuinely over-aggro a room.

function SN.AlertNoise(target, range)
    return SN.ReportNoise(target, { Tag = SN.NOISE_TAGS.Aggro, Range = range or 1500 })
end


-- [AUTHORITY] Make the Stinky debuff BITE, by widening the smell it already emits.
-- Only the pest family lists "stinky" in SmellTags; everyone else falls through to an unforced
-- seed with no line-of-sight check, so a stinky player near a grunt gets spotted through a wall
-- (see AnNotes/AnteSystems/NPCPerception.md). This just adds a second event at StinkyRange rather than
-- editing the native 1200uu one - a duplicate stimulus on the same instigator+tag is idempotent.

function SN.RegisterStinkyNoise()
    if STATE.StinkyNoiseHookRegistered then return end
    if not Utils.IsAuthority() then return end

    local range = tonumber(SETTINGS.GAMEPLAY.AI_SENSE.StinkyRange) or 0
    if range <= 1200 then return end   -- <= the native reach: nothing to add

    local HOOK = "/Game/Blueprints/BuffsDebuffs/BuffObject_Stinky.BuffObject_Stinky_C:Server_OnBuffTick"
    local ok = pcall(RegisterHook, HOOK, function(self, Character)
        local char = Character and Character:get()
        if Utils.IsActorInvalid(char) then return end
        SN.ReportNoise(char, { Tag = SN.NOISE_TAGS.Smell, Range = range, Loudness = 1 })
    end)

    STATE.StinkyNoiseHookRegistered = true
    LogSense("AnteUp2 - stinky smell radius " .. range .. "uu "
        .. (ok and "armed" or "FAILED (hook)"))
end


-- =======================================================================
-- THE LIGHT GATE (authority) - the one write that stops NPCs going blind in bright daylight
-- =======================================================================
-- The spot meter multiplies its gain by the TARGET's light level, and only the PLAYER class ever
-- computes one - a powered-fixture proximity test, not a brightness sample, so sunlight and muzzle
-- flashes count for nothing and an outdoor arena reads light 0. IgnoreLightLevel is NOT the lever
-- (still gains 0 at light 0); only raising the VALUE works. Full decode: AnNotes/AnteSystems/NPCPerception.md.
--
-- SAFE TO WRITE: CurrentLightValue has exactly one gameplay consumer (the AI's light read), isn't
-- replicated, and is unrelated to darkness/sanity (a separate field).
local LIGHT_POLL_MS = 250
local lightFloorGen = 0
local lightFloorLevel, lightFloorFires, lightFloorWrites = 0, 0, 0

-- What /ai prints. `fires` = poll passes, `writes` = passes that actually had to raise a value.
-- fires climbing with writes at 0 means every player was already lit; fires stuck at 0 means the
-- loop is dead, which is the failure the hook version had.
function SN.LightFloorStatus()
    return lightFloorGen > 0, lightFloorLevel, lightFloorFires, lightFloorWrites
end

function SN.StartLightFloor(level)
    level = tonumber(level) or 0
    if level <= 0 or not Utils.IsAuthority() then return end
    if level > 1 then level = 1 end   -- a 0..1 fraction; >1 would scale meter gain past vanilla-lit
    lightFloorLevel = level

    lightFloorGen = lightFloorGen + 1
    local gen = lightFloorGen

    -- The generation check is the only retirement test, so the re-queue below must stay
    -- unconditional. Bailing the whole loop on `not STATE.ModEnabled` breaks it: this arms before
    -- main.lua sets ModEnabled, so a skipped first pass would never re-queue and the poll would be
    -- dead from birth. StopMod tears down via the WorkQueue, so teardown is covered regardless.
    local function pass()
        if gen ~= lightFloorGen then return end   -- a newer arm superseded this loop; retire quietly
        if STATE.ModEnabled then
            lightFloorFires = lightFloorFires + 1
            for _, player in ipairs(Utils.LivePlayers()) do
                local cur = tonumber(player.CurrentLightValue) or 0
                if cur < level then
                    player.CurrentLightValue = level
                    lightFloorWrites = lightFloorWrites + 1
                end
            end
        end
        Utils.QueueWork(pass, LIGHT_POLL_MS, true)   -- quiet: 4/s of pure property reads
    end
    pass()

    LogSense("AnteUp2 - NPC sight light floor " .. level .. " armed (poll)")
end


-- =======================================================================
-- THE ENGINE SIGHT BUDGET (authority) - stage 1, and why NPCs stare through you at 5m
-- =======================================================================
-- UAISense_Sight services at most MaxTracesPerTick listener-target pairs per FRAME (stock 6, never
-- raised by the game), so in a busy level one pair can go 5-20s between traces regardless of
-- Eyesight/cone/SightRadius/light - all of those are downstream of a pair the engine hasn't traced
-- yet. Raising the trace cap is the only lever that touches stage 1. Full measurements:
-- AnNotes/AnteSystems/NPCPerception.md.
-- Per WORLD: re-arms with the rest of per-world wiring, and retries because the sense instance
-- doesn't exist until the first listener registers.
local SIGHT_BUDGET_RETRY_MS, SIGHT_BUDGET_MAX_TRIES = 3000, 5

function SN.SetSightBudget(tracesPerTick, timeSlice, attempt)
    tracesPerTick = tonumber(tracesPerTick) or 0
    if tracesPerTick <= 0 or not Utils.IsAuthority() then return false end

    local sense
    pcall(function() sense = FindFirstOf("AISense_Sight") end)
    if IsNotValid(sense) then
        attempt = (attempt or 1)
        if attempt < SIGHT_BUDGET_MAX_TRIES then
            Utils.QueueWork(function()
                SN.SetSightBudget(tracesPerTick, timeSlice, attempt + 1)
            end, SIGHT_BUDGET_RETRY_MS)
        else
            Utils.LogBad("AnteUp2 - sight trace budget: no live AISense_Sight (no NPCs in world?)")
        end
        return false
    end

    local cur = tonumber(sense.MaxTracesPerTick) or 0
    if cur < tracesPerTick then sense.MaxTracesPerTick = tracesPerTick end

    local slice = tonumber(timeSlice)
    if slice and slice > 0 then
        local curSlice = tonumber(sense.MaxTimeSlicePerTick) or 0
        if curSlice < slice then sense.MaxTimeSlicePerTick = slice end
    end

    LogSense(string.format("AnteUp2 - sight trace budget %d/frame (was %d)", tracesPerTick, cur))
    return true
end


-- =======================================================================
-- GLOBAL HEARING HOIST (authority) - THREE MECHANISMS, the middle one does the real work
-- =======================================================================
-- Native HearingRange is 750uu (400 on Pests), under every noise mechanic in the mod.
--   1. SN.HoistHearing: a NotifyOnNewObject hoist at construction, before the listener digests its
--      config, so it needs no listener update. Free, but races the engine's subobject instancing
--      and catches only a fraction.
--   2. SN.ArmHearingSpawnTopUp: the reliable path - one hook on ReceiveBeginPlay, one deferred
--      per-NPC write. Ordered, covers un-mutated NPCs too.
--   3. SN.SweepHearing / StartHearingSweep: backstop (30s cadence) for anything both miss.
-- All three are a FLOOR: a class shipping better than `range` is left alone, and an NPC with no
-- hearing config (the Composer) stays deaf by design.

-- ONE top-up pass over resident NPCs (what `/ai hearing fix` calls). Returns the NPC count.
-- Writes to a LIVE listener (unlike the notify path), so it must re-digest - hence the stagger, so
-- it never rides a mutation's drain. One-shot per NPC: a body at the floor is skipped on later
-- passes, so a healthy session logs a burst per streamed-in sector then goes quiet.
--
-- A run of passes that keeps fixing the SAME count is the bug signal; the report distinguishes:
--   stuck    the write didn't survive to the next read - the config we found isn't what the
--            listener actually reads.
--   frozen   the body is IsDisabled (AI-director freeze past MaxVisibleDistance), which also
--            disables hearing - the raise is cosmetic until it thaws. Far more common on a
--            dedicated server with players spread out than in SP.
--   neither  a clean write a later writer puts back - would be game-side, nothing here lowers
--            hearing except the deliberate-deafness case below.

local SWEEP_SPREAD_MS   = 20000   -- the whole pass is queued inside this
local SWEEP_STALE_TICKS = 250     -- dropped past this: under Utils.IsDeparted's 300-tick stamp

function SN.SweepHearing(range)
    range = tonumber(range) or 0
    if range <= 0 or not Utils.IsAuthority() then return 0 end

    local npcs = FindAllOf("NPC_Base_ParentBP_C") or {}
    local n = 0
    -- Boxed: the per-NPC work below runs on LATER drains, after we return.
    local tally = { fixed = 0, stuck = 0, frozen = 0 }
    -- Every item holds a wrapper from this snapshot, and a departed body is only caught while its
    -- stamp lasts (Utils.IsDeparted, 300 ticks). So the spread is capped under that, and an item the
    -- drain delayed past it is dropped untouched - the next sweep covers that NPC.
    local takenAt = STATE.FAST_TICK
    local spacing = math.min(40, math.floor(SWEEP_SPREAD_MS / math.max(#npcs, 1)))
    for i = 1, #npcs do
        local npc = npcs[i]
        if Utils.IsActorValid(npc) then
            n = n + 1
            local target = npc
            Utils.QueueWork(function()
                if STATE.FAST_TICK - takenAt > SWEEP_STALE_TICKS then return end
                if Utils.IsActorInvalid(target) then return end
                local cur = SN.GetHearingRange(target)   -- nil = no config = deaf by design
                if not cur or cur >= range then return end

                -- DELIBERATE DEAFNESS IS NOT A GAP TO FILL. Native values are 400/500/750/1200 and
                -- a class that ships deaf has NO config at all (nil, handled above), so an exact 0
                -- can only be a write of OURS - AVU.SetHearingSense(actor, 0, 0), the Order Flame
                -- Rat's "doesn't aggro off a cellmate getting shot". This sweep was raising it
                -- straight back to the floor on the next pass and silently undoing the variant.
                if cur == 0 then return end

                SN.SetHearingSense(target, range)
                tally.fixed = tally.fixed + 1

                local after = SN.GetHearingRange(target)
                if after and after < range then tally.stuck = tally.stuck + 1 end
                local frozen = false
                pcall(function() frozen = target.IsDisabled == true end)
                if frozen then tally.frozen = tally.frozen + 1 end
            end, spacing * n, true)   -- ~25 NPCs/sec, so a full sector spreads over a few seconds
                                 --   quiet: one read + a rare write, x every NPC x every sweep
        end
    end

    -- Report after the staggered work drains, and only when it changed something.
    --   * +1000ms rather than one more slot: the drain is capped per tick and takes items
    --     NEWEST-FIRST, so a report sharing the last NPCs' 100ms tick bucket is pulled BEFORE them
    --     and under-counts its own pass.
    Utils.QueueWork(function()
        if tally.fixed <= 0 then return end
        local note = ""
        if tally.stuck > 0 then note = note .. ", " .. tally.stuck .. " DID NOT STICK" end
        if tally.frozen > 0 then
            note = note .. ", " .. tally.frozen .. " frozen (deaf until they thaw)"
        end
        LogSense("AnteUp2 - hearing raised on " .. tally.fixed .. "/" .. n .. " NPCs to "
            .. range .. "uu" .. note)
    end, spacing * n + 1000)

    return n
end


-- [AUTHORITY] Arm the repeating top-up (30s, comfortably outside the "never FindAllOf under 15s"
-- rule). GENERATION-guarded rather than latched: a world teardown kills the in-flight timer, so
-- the arm must be re-callable, and any older loop retires itself on its next tick.
local SWEEP_MS = 30000
local sweepGen = 0

function SN.StartHearingSweep(range)
    range = tonumber(range) or 0
    if range <= 0 or not Utils.IsAuthority() then return end

    sweepGen = sweepGen + 1
    local gen = sweepGen

    local function pass()
        if gen ~= sweepGen then return end   -- a newer arm superseded this loop; retire quietly
        SN.SweepHearing(range)
        Utils.QueueWork(pass, SWEEP_MS, true)
    end
    pass()
end


-- =======================================================================
-- SPAWN-TIME TOP-UP - the reliable path (mechanism 2 in the banner)
-- =======================================================================
-- One hook on the NPC parent's ReceiveBeginPlay, one deferred per-NPC write. No scan, no polling,
-- fires in a defined order rather than racing the engine's subobject instancing like the notify.
--
-- The 4s delay matters: writing SensesConfig on a LIVE listener needs RequestStimuliListenerUpdate,
-- and doing that inside a mutation's drain can DEREGISTER perception outright - a blind NPC is far
-- worse than one that hears only 750uu. 4s clears the whole variant pipeline with room to spare,
-- leaving a native-range window on a fresh spawn, which beats the sweep's old 30s window.
--
-- NOTE: ModuleGATE/GateBridge registers a SECOND hook on this same UFunction (only when
-- ENEMY_AT_THE_GATE/MODULE_REVENGE_ASSAULTS are on) - same Lua state, so callbacks just chain. Merge
-- rather than adding a third.
local NPC_BEGINPLAY_HOOK = ENUMS.BASE_PARENT_NPC .. ":ReceiveBeginPlay"
local SPAWN_TOPUP_MS = 4000    -- see the trade above before shortening this
local spawnTopUpArmed = false

function SN.ArmHearingSpawnTopUp(range)
    if spawnTopUpArmed then return end
    range = tonumber(range) or 0
    if range <= 0 or not Utils.IsAuthority() then return end
    spawnTopUpArmed = true   -- module-local: a RegisterHook cannot be undone, and re-arming
                             --   per world would stack a second callback on the same function

    local ok, err = pcall(RegisterHook, NPC_BEGINPLAY_HOOK, function(self)
        -- CLAUDE.md 2: NOTHING in a hook body but the queue insert (pure Lua).
        if not STATE.ModEnabled then return end
        local npc = self and self:get()
        if not npc then return end
        Utils.QueueWork(function()
            if Utils.IsActorInvalid(npc) then return end
            local cur = SN.GetHearingRange(npc)   -- nil = no config = deaf by design, leave it
            -- Same two guards as the sweep: only ever raise, and an exact 0 is a deliberate
            -- deafening of ours (the Order Flame Rat) that must not be filled in.
            if cur and cur > 0 and cur < range then SN.SetHearingSense(npc, range) end
        end, SPAWN_TOPUP_MS)
    end)

    LogSense("AnteUp2 - NPC spawn hearing top-up " .. (ok and "armed" or
        ("FAILED (hook): " .. tostring(err))))
    if not ok then spawnTopUpArmed = false end   -- let a later arm retry
end


-- [AUTHORITY] Arm the construction-time hoist (+ the spawn top-up and the sweep). Once per session.
-- Deliberate exception to "do nothing in a NotifyOnNewObject but QueueWork it": this body is just
-- two table reads and a float write (nothing blocking-load-able), and it cannot be deferred -
-- landing before the listener digests the config is the whole reason it needs no listener update.
-- Do not "fix" this into a QueueWork.

local hearingHoisted = false

function SN.HoistHearing(range)
    if hearingHoisted then return end
    range = tonumber(range) or 0
    if range <= 0 then return end
    hearingHoisted = true

    local ok = pcall(NotifyOnNewObject, SENSE_HEARING_CLASS, function(cfg)
        if not Utils.IsAuthority() then return end
        local cur = cfg.HearingRange or 0
        if cur < range then cfg.HearingRange = range end
    end)
    LogSense("AnteUp2 - NPC hearing hoist to " .. range .. "uu "
        .. (ok and "armed" or "FAILED (NotifyOnNewObject)"))

    SN.ArmHearingSpawnTopUp(range) -- the notify races and mostly loses; THIS is the real path
    SN.StartHearingSweep(range)    -- ...and the sweep is the backstop for what both miss
end


-- =======================================================================
-- THE SPOT METER - Eyesight, and the engine-side sight gate
-- =======================================================================

-- [AUTHORITY] Eyesight is a straight MULTIPLIER on the spot-meter increment, read in exactly one
-- place and allocating nothing - the cheapest lever there is. The game uses it as its own
-- "notices you fast" dial (Robot Defense 3, Sniper 50, Turret 100, Reaper/Leyak 1000 = instant).
--   * ABSOLUTE set; for "x the native value" use SN.ScaleEyesight, which is idempotent.
--   * Called from a spawn callback the controller may not be possessed yet, so it retries ONCE
--     off-hook. Returns true if it stuck.

function SN.SetEyesight(npc, value, _retry)
    if Utils.IsActorInvalid(npc) or not value then return false end

    local c = npc.NPC_Controller
    if IsNotValid(c) then c = npc:GetController() end
    if IsNotValid(c) then
        if not _retry then
            Utils.QueueWork(function() SN.SetEyesight(npc, value, true) end, 1000)
        end
        return false
    end

    local ok = false
    pcall(function()
        if c.Eyesight == nil then return end        -- not an Abiotic AI controller
        if c.Eyesight == value then ok = true; return end
        c.Eyesight = value
        ok = true
    end)
    return ok
end


-- The controller class's UNTOUCHED Eyesight, cached per class name. Resolved from the CLASS
-- DEFAULT OBJECT, which is what makes ScaleEyesight idempotent under re-mutation (pet re-mutate,
-- save-restore, /reload + respawn) instead of compounding 3 -> 9 -> 27. Fallback: the FIRST
-- instance of a class we see is pristine by definition. Bounded by ~40 controller classes.
local eyesightBase = {}   -- controller class name -> native Eyesight

local function nativeEyesight(c)
    local cls, clsName
    pcall(function()
        cls = c:GetClass()
        clsName = cls:GetFName():ToString()
    end)
    if not clsName then return nil end
    if eyesightBase[clsName] then return eyesightBase[clsName] end

    local v
    -- The CDO straight off the class: no path lookup (one per controller class, ~40 per session).
    -- The path is the fallback: "/Game/A/B.B_C" -> "/Game/A/B.Default__B_C".
    local cdo
    pcall(function() cdo = cls:GetCDO() end)
    if IsNotValid(cdo) then
        cdo = nil
        local clsPath = cls and Utils.ObjectPath(cls)
        if clsPath then cdo = Utils.ResolveByPath((clsPath:gsub("%.([^%.]+)$", ".Default__%1"))) end
    end
    if cdo then pcall(function() v = cdo.Eyesight end) end
    if type(v) ~= "number" then pcall(function() v = c.Eyesight end) end
    if type(v) ~= "number" or v <= 0 then return nil end

    eyesightBase[clsName] = v
    return v
end

-- Past ~20 the meter fills on the first poll anyway; the cap also keeps a fat-fingered setting off
-- the specialists that already ship at 50-1000.
local EYESIGHT_CAP = 100

-- [AUTHORITY] Multiply an NPC's NATIVE Eyesight. IDEMPOTENT (see nativeEyesight).
-- mult <= 1 is a no-op, so the setting at its default costs one comparison.

function SN.ScaleEyesight(npc, mult, _retry)
    mult = tonumber(mult)
    if not mult or mult <= 1 then return false end
    if Utils.IsActorInvalid(npc) then return false end

    local c = npc.NPC_Controller
    if IsNotValid(c) then c = npc:GetController() end
    if IsNotValid(c) then
        if not _retry then
            Utils.QueueWork(function() SN.ScaleEyesight(npc, mult, true) end, 1000)
        end
        return false
    end

    local base = nativeEyesight(c)
    if not base then return false end
    return SN.SetEyesight(npc, math.min(base * mult, EYESIGHT_CAP), true)
end


-- [AUTHORITY] Rewrite the pawn's AISenseConfig_Sight - the ENGINE-side gate deciding whether a
-- target is a spot-meter candidate at all. Writes only on a real difference, so a caller can
-- re-assert on a poll for free; returns true if anything changed.
--   opts.Degrees    the TOTAL cone a human would quote (85 stock is a HALF-angle = 170 total, so
--                   the perpendicular is the excluded slice - that knife edge is what reads as
--                   "blind from the side"). 360 = omnidirectional.
--   opts.Radius / opts.LoseRadius   sight distances. INVARIANT: lose must stay >= sight or a
--                   target is dropped the instant it is acquired, so raising Radius drags it up.
--   opts.Floor      only ever RAISE a field - use it for blanket settings, so a class that ships
--                   better (the BogMan's 180 cone, the Sniper's 200m) is never nerfed by a global.
-- Per-class native values (a tamed PEST sees EIGHT METRES): AnNotes/AnteSystems/NPCPerception.md.
local LOSE_SIGHT_MARGIN = 1.5   -- the stock 3000/2000 ratio

function SN.SetSightConfig(npc, opts)
    if Utils.IsActorInvalid(npc) or not opts then return false end

    -- Every call here costs the NPC ~10s of sight: RequestStimuliListenerUpdate re-registers the
    -- listener, and the engine doesn't resume perceiving that pair promptly. Measured on a live
    -- NPC: AnNotes/AnteSystems/NPCPerception.md. That's why there's no global cone floor - native cones
    -- (170 / 140 pest / 120 sniper) stand. Call this only for a one-time change worth the outage
    -- (a pest pet's 800->2000uu sight), never per tick or for a few degrees.
    -- opts.DelayMs moves the outage off the mutation drain - it does not avoid it, and landing
    -- right after a spawn is the worst moment, so prefer no write at all.
    local delay = tonumber(opts.DelayMs)
    if delay and delay > 0 then
        local later = {}
        for k, v in pairs(opts) do later[k] = v end
        later.DelayMs = nil
        local target = npc
        Utils.QueueWork(function()
            if Utils.IsActorInvalid(target) then return end
            SN.SetSightConfig(target, later)
        end, delay)
        return false
    end

    local perc = npc.AIPerception
    if IsNotValid(perc) then return false end

    local half = tonumber(opts.Degrees)
    if half then half = math.min(math.max(half, 1), 360) / 2 end

    local floor = opts.Floor == true
    local changed = false
    -- IsA, NOT a duck-type on PeripheralVisionAngleDegrees - see the file header.
    local sightClass = ASSETS.GetIfValid(SENSE_SIGHT_CLASS)
    if not sightClass then return false end
    pcall(function()
        local cfgs = perc.SensesConfig
        if not cfgs then return end
        for i = 1, #cfgs do
            local cfg = cfgs[i]
            if cfg and IsValid(cfg) and cfg:IsA(sightClass) then
                local function put(field, want)
                    if not want then return end
                    local now = cfg[field] or 0
                    if floor and now >= want then return end
                    if math.abs(now - want) < 0.01 then return end
                    cfg[field] = want
                    changed = true
                    return true
                end
                put("PeripheralVisionAngleDegrees", half)

                local radius = tonumber(opts.Radius)
                if put("SightRadius", radius) then
                    local lose = cfg.LoseSightRadius or 0
                    if lose < radius then
                        cfg.LoseSightRadius = radius * LOSE_SIGHT_MARGIN
                    end
                end
                put("LoseSightRadius", tonumber(opts.LoseRadius))
            end
        end
    end)

    if changed then pcall(function() perc:RequestStimuliListenerUpdate() end) end
    return changed
end


return SN
