-- =======================================================================
-- ORDER - FLAME RAT machinery: the PURIFIED cell (defs: AnteNPCs/OrderFlameRat.lua)
--
-- MUST-KNOWS (implementation) - full decode + decision log: AnNotes/AnteNPCs/OrderPurified.md
--   * The holy shield look IS the Preacher's, as COMPONENT DEFAULTS: H.HolyShieldSkin replays
--     them (MaterialOverride + 4 holy particles + Color_* fields written IN PLACE). Never
--     param-tint the GK shell MI - it exposes no params (silent no-op).
--   * Runtime shield comps DON'T REPLICATE: absorb math is server-side everywhere; shell/FX
--     are host-only (why H.AttachShell is authority-gated + ActorKey-guarded).
--   * Holy->recharge runs INSIDE ProcessDamage - the actor work is deferred (Fanatic lesson).
--   * The blessing fires the gun VIA THE BT (pooled aggro bait parked on the ward), NEVER from
--     Lua (S6 kill-path). The ward is Holy=0, so the spray only feeds it.
--   * Ammo pin: CurrentAmmoCount held at max so RequiresReload() never fires. MaxAmmoCount is
--     NEVER touched - that reload branch is the Cinderlord wedge.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local ENUMS = require("AnteData.Enums")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local ASSETS = require("AnteCore.AssetManager")
local STATE = require("AnteCore.State")

local LogDebug = Utils.LogDebug

local H = {}

-- ----- knobs -----------------------------------------------------------

H.SHIELD_PURIFIER = 300   -- Purifier
H.SHIELD_SMALL    = 200   -- Purified Grunt / Breacher shield pool
H.SHIELD_BIG      = 400   -- Purified Rat
H.SHIELD_EVENT_PURIFIER = 50   -- ...Event Purifier (weaker)
H.PURIFIER_REGEN_TIME = 15   -- seconds out of damage before the Purifier's own shield refills

local RECHARGE_AMOUNT = 30   -- shield HP given back per holy proc
local RECHARGE_TICKS  = 10    -- min FAST_TICKs between procs per actor (~1s; a DoT ticks ~1/s)

local BLESS_TICKS      = 50    -- ally check cadence in combat (ticks are 100ms: 5s)
local BLESS_IDLE_TICKS = 100    -- ..and out of combat (7s)
local BLESS_RADIUS     = 800
local BLESS_SECONDS    = 10    -- ignite duration, outlasts cooldown
local BLESS_FIRE_MS    = 1200  -- how long the aggro bait holds

local PT_TOPUP_TICKS = 10     -- ammo pin cadence (1/s)
local PT_WEDGE_TICKS = 120    -- LockedInPlaceMontage hot this long -> cleared + logged (12s)
local ANCHOR_KICK_UU = 300    -- out of combat + farther than this from the anchor -> walk home
local ANCHOR_LEASH_UU = 1200  -- HARD leash: past this the kick fires even IN combat and the blessing
                              -- pass stops, so a lapsed ForceAggro lets the next kick walk it home
                              -- (else it trails its ward's escort walk forever).
local ANCHOR_BAIT_TICKS = 150 -- 15s: a non-holy hit suspends the kicks this long (the bait window
                              -- that replaced the old PERMANENT anchor release - see H.OpenBaitWindow)

local BACKPACK_HP      = 400   -- native 170
local SENSE_SIGHT      = 1000  -- eyesight sense overrides
local SENSE_LOSE_SIGHT = 2000  
local SENSE_DELAY_MS   = 6000  -- also make Purifiers defa so the event ones don't aggro as hard

local PURIFIED_HELMET = { Color = FVector(9, 9, 9), EmissiveColor = FVector(1, 1, 1), Emissive = 20 }

-- The Preacher's component-default colors (rounded)
local HOLY_FULL     = { R = 5.0, G = 4.1, B = 0.8,  A = 1.0 }
local HOLY_BREAKING = { R = 5.0, G = 2.6, B = 0.3, A = 1.0 }
local HOLY_PATTERN_FULL = 20   -- PatternIntensity_ShieldFull (GK default 230 - much harsher)

-- Which variants the Purifier blesses (the holy-fed shield carriers).
local PURIFIED_NAMES = {
    ["Purified Grunt"]    = true,
    ["Purified Breacher"] = true,
    ["Purified Rat"]      = true,
}

-- ----- shared asset sets (def.Assets) -----------------------------------

-- Everything the holy shield skin assigns (once assigned, the component holds hard refs).
local SHIELD_KIT = {
    AVU.BODYSHIELD_CLASS,
    ENUMS.Components.M_PREACHER_ENERGY_SHIELD,
    ENUMS.Effects.SHIELD_BROKEN_HOLY,
    ENUMS.Effects.SHIELD_BREAK_HOLY,
    ENUMS.Effects.SHIELD_REGEN_HOLY,
    ENUMS.Effects.SHIELD_IMPACT_HOLY,
}

H.PURIFIED_ASSETS = {}
for _, p in ipairs(SHIELD_KIT) do H.PURIFIED_ASSETS[#H.PURIFIED_ASSETS + 1] = p end
H.PURIFIED_ASSETS[#H.PURIFIED_ASSETS + 1] = ENUMS.Components.M_GLASS_LENS_GOLD

-- The PURIFIED RAT alone also portals in (AVU.PortalArrival in its OnReady), so it needs the
-- step-out montage warm - PlayMontageReplicated resolves through the non-loading GetIfValid and
-- skips SILENTLY on a cold asset. Its own list rather than an addition to the shared one: the
-- Grunt and Breacher don't play it, and def.Assets is a per-spawn load.
H.PURIFIED_RAT_ASSETS = { ENUMS.Anims.HASTATRIA_EXIT_PORTAL }
for _, p in ipairs(H.PURIFIED_ASSETS) do H.PURIFIED_RAT_ASSETS[#H.PURIFIED_RAT_ASSETS + 1] = p end

-- + the holy-fire kit: the ignite buff (row-name soft-ref - the S6 debuff-preload trap),
-- its DoT carrier, and the spray's damage type.
H.PURIFIER_ASSETS = {}
for _, p in ipairs(SHIELD_KIT) do H.PURIFIER_ASSETS[#H.PURIFIER_ASSETS + 1] = p end
H.PURIFIER_ASSETS[#H.PURIFIER_ASSETS + 1] = ENUMS.BuffObjects.IgnitedHoly
H.PURIFIER_ASSETS[#H.PURIFIER_ASSETS + 1] = ENUMS.BuffObjects.HPDamage
H.PURIFIER_ASSETS[#H.PURIFIER_ASSETS + 1] = ENUMS.DamageType.FireHoly
-- + the rift arrival's step-out montage (AVU.PortalArrival, from OnReady) - same "must be
-- resident before OnReady fires" reason as above. Warm by TIMING (def.Assets preloads, OnReady
-- follows a beat later), never pinned. The doorway FX itself needs nothing here - it's client-FX,
-- each renderer cold-loads its own copy.
H.PURIFIER_ASSETS[#H.PURIFIER_ASSETS + 1] = ENUMS.Anims.HASTATRIA_EXIT_PORTAL

-- ----- per-actor state (keyed by Utils.ActorKey - wrappers differ across hooks) ---------

local lastRechargeTick = {}   -- ActorKey -> FAST_TICK of the last holy recharge proc
local shellState   = {}   -- ActorKey -> "pending" | "done" (AttachShieldShell is NOT idempotent)
local lockedSince  = {}   -- ActorKey -> tick LockedInPlaceMontage was first seen (wedge watchdog)
local lastBaitHitTick = {} -- ActorKey -> FAST_TICK of the last non-holy hit (the bait window opens)

-- ActorKey -> true: this Purifier's anchor NEVER releases on damage. PUBLIC: the Purifier's
-- inline OnDamageTaken (OrderFlameRat.lua) reads it.
H.GuardAnchors = {}

-- [AUTHORITY] Mark/unmark a Purifier as a GUARD post: the Purifier's OnDamageTaken will not
-- release its anchor, so it always walks back (the event's basement pair). Caller: PA.AnchorRats.
-- (/reload note: this table dies with the helpers module - the event re-registers on start.)
function H.SetGuardAnchor(actor, on)
    local key = Utils.ActorKey(actor)
    if key then H.GuardAnchors[key] = on and true or nil end
end


-- [AUTHORITY, safe in the damage hook - a pure Lua stamp] Open a Purifier's BAIT WINDOW: for
-- ANCHOR_BAIT_TICKS the anchor kicks are suspended, so a hit can pull it off its post to fight,
-- then it walks home once the window closes. Guard posts never open one. See AnNotes/AnteNPCs/OrderPurified.md.
function H.OpenBaitWindow(actor)
    local key = Utils.ActorKey(actor)
    if key then lastBaitHitTick[key] = STATE.FAST_TICK end
end

-- [AUTHORITY] def.OnDamageTaken for both Purifiers. Non-holy damage opens the bait window (an
-- ally's own Fire_Holy gout is excluded, or it would friendly-fire the window open); a guard post
-- (H.SetGuardAnchor) never opens one - it always walks back.
function H.PurifierReleaseAnchor(victim, damage, dmgType)
    local key = Utils.ActorKey(victim)
    if key and H.GuardAnchors[key] then return end
    local name = Utils.DamageTypeName(dmgType)
    if name and name:find("Holy") then return end
    H.OpenBaitWindow(victim)
end


-- =======================================================================
-- THE HOLY SHIELD (shared by the Purifier and its wards)
-- =======================================================================

-- [AUTHORITY] Resolve the shield comp the way the damage pipeline does (property, then class).
-- Separate pcalls: the property read throws on classes without it.
local function getShield(actor)
    local shield
    pcall(function() shield = actor.BodyShieldComponent end)
    if IsNotValid(shield) then
        pcall(function()
            local cls = ASSETS.GetIfValid(AVU.BODYSHIELD_CLASS)
            if IsValid(cls) then shield = actor:GetComponentByClass(cls) end
        end)
    end
    if IsNotValid(shield) then return nil end
    return shield
end

-- True if the actor's body shield is below max (the idle-blessing gate).
local function shieldDown(npc)
    local shield = getShield(npc)
    if not shield then return false end
    local down = false
    pcall(function()
        down = (shield.CurrentShieldHitPoints or 0) < (shield.MaxShieldHitPoints or 0)
    end)
    return down
end

-- [AUTHORITY] Reskin a (runtime-added, GK-defaulted) body shield into the Preacher's holy one.
-- Call right after AVU.AddBodyShield; everything assigned is preloaded via SHIELD_KIT.
function H.HolyShieldSkin(actor)
    local shield = getShield(actor)
    if not shield then return false end

    pcall(function()
        local mi = ASSETS.GetIfValid(ENUMS.Components.M_PREACHER_ENERGY_SHIELD)
        if IsValid(mi) then shield:SetMaterialOverride(mi) end
    end)

    for prop, path in pairs({
        Particle_ShieldBrokeLoop = ENUMS.Effects.SHIELD_BROKEN_HOLY,
        Particle_ShieldBroken    = ENUMS.Effects.SHIELD_BREAK_HOLY,
        Particle_ShieldRestore   = ENUMS.Effects.SHIELD_REGEN_HOLY,
        Particle_ShieldHit       = ENUMS.Effects.SHIELD_IMPACT_HOLY,
    }) do
        pcall(function()
            local sys = ASSETS.GetIfValid(path)
            if IsValid(sys) then shield[prop] = sys end
        end)
    end

    -- The shield tick lerps these component fields into ForceFieldColor/AuroraIntensity -
    -- they ARE the recolor.
    pcall(function()
        local c = shield.Color_FullShield
        c.R, c.G, c.B, c.A = HOLY_FULL.R, HOLY_FULL.G, HOLY_FULL.B, HOLY_FULL.A
        c = shield.Color_ShieldBreaking
        c.R, c.G, c.B, c.A = HOLY_BREAKING.R, HOLY_BREAKING.G, HOLY_BREAKING.B, HOLY_BREAKING.A
        shield.PatternIntensity_ShieldFull = HOLY_PATTERN_FULL
    end)
    return true
end


-- =======================================================================
-- PURIFIED SHARED KIT (Stats / Visuals / OnDamageTaken)
-- =======================================================================

-- [AUTHORITY] Purifier's own Stats step - unlike its wards, it self-regens (it IS the battery).
--   * Shield uses the Preacher's real numbers (100/12s), not the class default (300/8s).
--   * Senses DIALED DOWN, not boosted: absolutes land at SENSE_DELAY_MS to beat the variant's
--     own x2 BoostSensesDelayed, which would otherwise multiply them.
--   * `shieldMax` lets the Event Purifier use a smaller, killable pool.
--   * Also opens the rift arrival (hides the body) - shared here since both Purifiers are the
--     same trooper and differ only in numbers. Full rationale: AnNotes/AnteNPCs/OrderPurified.md.
function H.PurifierStats(actor, shieldMax)
    -- FIRST, and in the FIRST pipeline step: Stats runs a full mutation ahead of OnReady - mesh
    -- wait, asset load, both halves of the split gate - which is long enough to watch a body stand
    -- on the floor waiting for its own portal. See the AVU.PortalArrival header for the cadence.
    AVU.HideForArrival(actor)

    AVU.AddBodyShield(actor, { Max = shieldMax or H.SHIELD_PURIFIER, RegenTime = H.PURIFIER_REGEN_TIME })
    H.HolyShieldSkin(actor)

    pcall(function()
        actor.BackpackHealth    = BACKPACK_HP
        actor.MaxBackpackHealth = BACKPACK_HP
        Utils.MarkReplicatedDirty(actor, "BackpackHealth")
        Utils.MarkReplicatedDirty(actor, "MaxBackpackHealth")
    end)

    AVU.SetSightSenseDelayed(actor, SENSE_SIGHT, SENSE_LOSE_SIGHT, nil, SENSE_DELAY_MS)
    Utils.QueueWork(function()
        if Utils.IsActorValid(actor) then AVU.SetHearingSense(actor, 0, 0) end
    end, SENSE_DELAY_MS)
end

-- [dropped] The old one-shot PortalFX burst arrival was replaced by the shared rift arrival
-- (AVU.HideForArrival above + AVU.PortalArrival in OnReady) - don't add both, they'd contradict.

-- [AUTHORITY] Common Stats step for the three Purified bodies: no normal-path drops, forced gear
-- (helmet ON and welded, backpack OFF), then the holy shield.
-- startFrac spawns the shield part-charged (nil = full) - bait for the Purifier's hose.
function H.PurifiedStats(actor, shieldMax, startFrac)
    AVU.ClearLoot(actor, true)   -- preserveGib
    pcall(function() actor.RemainingLootDrops = 0 end)

    pcall(function() actor.CanLoseHelmet = false end)
    pcall(function() actor.Apoc_ForceHelmetOffOnDeath = false end)
    AVU.SetReplicatedProp(actor, "HasHelmet", true)

    -- Backpack OFF (undoing the native 20% BeginPlay roll, Server_DecideIfWearingBackpack).
    -- Grunt-family only: the LabRat has a Backpack component but no HasBackpack bool, so the
    -- Purified Rat silently keeps its pack (which is its look anyway).
    AVU.SetReplicatedProp(actor, "HasBackpack", false)

    local max = shieldMax or H.SHIELD_SMALL
    AVU.AddBodyShield(actor, {
        Max = max, Regen = 0, ShowFX = true,
        Current = startFrac and math.floor(max * startFrac) or nil,
    })
    H.HolyShieldSkin(actor)
end

-- [RENDERER] The shared white-gold look: gold-lensed white helmet (silent no-op on the
-- LabRat) + the holy shield shell. Body tint rides def.Tint.
function H.PurifiedLook(actor)
    pcall(function()
        AVU.SetHelmet(actor, {
            Color         = PURIFIED_HELMET.Color,
            EmissiveColor = PURIFIED_HELMET.EmissiveColor,
            Emissive      = PURIFIED_HELMET.Emissive,
            LensMaterial  = ENUMS.Components.M_GLASS_LENS_GOLD,
        })
    end)
    H.AttachShell(actor)
end

-- [RENDERER, host/SP only] Guarded holy-shell attach.
--   * ActorKey latch = dedupe (AttachShieldShell is NOT idempotent); retries since the body
--     mesh can lag the spawn by a tick.
--   * Host-gated: the shell flashes via the non-replicating absorb component, so a pure client
--     would see it stuck hidden forever.
--   * meshPath optional: nil copies the actor's own body (all the grunt kit has); Pillagers can
--     pass SK_BODYSHIELD_PREACHER, the authored holy shell.
function H.AttachShell(actor, meshPath)
    if not Utils.IsAuthority() then return end

    local key = Utils.ActorKey(actor)
    if not key or shellState[key] then return end
    shellState[key] = "pending"

    local attempt = 0
    local function try()
        if Utils.IsActorInvalid(actor) or Utils.IsDeadSafe(actor) then shellState[key] = nil return end
        local comp = AVU.AttachShieldShell(actor, meshPath, {
            Material = ENUMS.Components.M_PREACHER_ENERGY_SHIELD,
        })
        if comp then
            shellState[key] = "done"
        elseif attempt < 4 then
            attempt = attempt + 1
            Utils.QueueWork(try, 500)
        else
            shellState[key] = nil   -- give a later Visuals re-run a fresh chance
        end
    end
    try()
end

-- [AUTHORITY, in the ProcessDamage hook] ANY holy hit feeds the shield (+RECHARGE_AMOUNT, 1s
-- per-actor throttle). That includes ABSORBED hits and ones NpcResistances zeroed (Holy=0) -
-- which is the whole loop. Actor work is deferred off the damage hook (Fanatic lesson).
function H.PurifiedHit(victim, damage, dmgType)
    local name = Utils.DamageTypeName(dmgType)
    if not name or not name:find("Holy") then return end

    local key = Utils.ActorKey(victim)
    if not key then return end
    if not AVU.CooldownReady(lastRechargeTick, key, RECHARGE_TICKS) then return end

    Utils.QueueWork(function()
        if Utils.IsActorInvalid(victim) or Utils.IsDeadSafe(victim) then return end
        if AVU.RechargeBodyShield(victim, RECHARGE_AMOUNT) then
            LogDebug("Purified - holy recharge +" .. RECHARGE_AMOUNT, SETTINGS.DEBUG_NPC_ACTIONS)
        end
    end, 0)
end


-- =======================================================================
-- PURIFIER (the FlameRat support) - live tick
-- =======================================================================

-- [AUTHORITY, OnTick 100ms] 1/s ammo pin (RequiresReload() can never fire) + anchor re-kick,
-- 12s LockedInPlaceMontage watchdog, and the blessing pass (in/out-of-combat cadences).
function H.PurifierTick(actor, tick)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return "REMOVE" end

    local inCombat = Utils.IsActorReadyToAttack(actor)

    if tick % PT_TOPUP_TICKS == 0 then
        pcall(function()
            local max = actor.MaxAmmoCount
            if max and max > 0 and (actor.CurrentAmmoCount or 0) < max then
                actor.CurrentAmmoCount = max
                Utils.MarkReplicatedDirty(actor, "CurrentAmmoCount")
            end
        end)

        local key = Utils.ActorKey(actor)

        -- Anchor re-kick: walks a drifted Purifier home once out of combat (past ANCHOR_KICK_UU) -
        -- the BT doesn't reliably re-arm this on its own. In combat the kick only fires past the
        -- HARD leash (ANCHOR_LEASH_UU); a fresh non-holy hit suspends both (the bait window).
        -- See AnNotes/AnteNPCs/OrderPurified.md.
        local baited = key and lastBaitHitTick[key]
            and (tick - lastBaitHitTick[key]) < ANCHOR_BAIT_TICKS
        if not baited then
            pcall(function()
                local poi = actor.LocationOfInterest
                if poi and (poi.X ~= 0 or poi.Y ~= 0 or poi.Z ~= 0) then
                    local at = actor:K2_GetActorLocation()
                    local limit = inCombat and ANCHOR_LEASH_UU or ANCHOR_KICK_UU
                    if at and Utils.DistSq(at, poi) > limit * limit then
                        local c = actor.NPC_Controller
                        if IsValid(c) then c:MoveToLocationOfInterest() end
                    end
                end
            end)
        end

        if key then
            if actor.LockedInPlaceMontage == true then
                lockedSince[key] = lockedSince[key] or tick
                if tick - lockedSince[key] >= PT_WEDGE_TICKS then
                    lockedSince[key] = nil
                    pcall(function() actor.LockedInPlaceMontage = false end)
                    Utils.Log("Purifier - LockedInPlaceMontage latched >12s, cleared (unwedge)")
                end
            else
                lockedSince[key] = nil
            end
        end
    end

    if tick % (inCombat and BLESS_TICKS or BLESS_IDLE_TICKS) == 0 then
        H.PurifyAlly(actor, inCombat)
    end
end

-- [AUTHORITY] One blessing pass = one visible gout at one ward. Full rationale: AnNotes/AnteNPCs/OrderPurified.md.
--   * NATIVE fire: park the pooled aggro bait ON the ward + ForceAggro, so BT_Main_FlameRat
--     sprays it itself and leaves its own fire patches; aggro lapses ~5s later.
--   * Guarantee: a DIRECT RechargeBodyShield backs the best-effort Ignited_Holy overlay.
--   * Idle passes only serve a ward whose shield is actually down.
--   * Bait is SHARED with AttackMove callers - NEVER destroy it.
function H.PurifyAlly(actor, inCombat)
    local ok, loc = pcall(function() return actor:K2_GetActorLocation() end)
    if not ok or not loc then return end

    -- THE LEASH GATE: an anchored Purifier blesses from its POST, not wherever bait dragged it -
    -- centering the ward search there (not on "nearest to me") keeps it from towing along the
    -- escort walk. Past ANCHOR_LEASH_UU the pass is skipped so the kick walks it home instead.
    local center, anchored = loc, false
    pcall(function()
        local poi = actor.LocationOfInterest
        if poi and (poi.X ~= 0 or poi.Y ~= 0 or poi.Z ~= 0) then
            center = FVector(poi.X, poi.Y, poi.Z)
            anchored = true
        end
    end)
    if anchored and Utils.DistSq(loc, center) > ANCHOR_LEASH_UU * ANCHOR_LEASH_UU then
        return
    end

    -- Nearest live ward; when idle, nearest one whose shield is down.
    local ward, wardD
    for _, npc in ipairs(AVU.GetNearbyNpcs(center, BLESS_RADIUS)) do
        if PURIFIED_NAMES[Utils.GetActorName(npc)] and not Utils.IsDeadSafe(npc)
            and (inCombat or shieldDown(npc)) then
            local okL, at = pcall(function() return npc:K2_GetActorLocation() end)
            local d = (okL and at) and Utils.DistSq(center, at) or math.huge
            if not wardD or d < wardD then ward, wardD = npc, d end
        end
    end
    if not ward then return end

    local okW, wardLoc = pcall(function() return ward:K2_GetActorLocation() end)
    if not okW or not wardLoc then return end

    -- 1. The attack: bait ON the ward, force-aggro, park the bait after the gout window.
    AVU.SpawnAggroBait(FVector(wardLoc.X, wardLoc.Y, wardLoc.Z), function(bait)
        AVU.ForceAggro(actor, bait)
        Utils.QueueWork(function()
            if Utils.IsActorValid(bait) then
                pcall(function() bait:K2_SetActorLocation(FVector(0, 0, 0), false, {}, true) end)
            end
        end, BLESS_FIRE_MS)
    end)

    -- 2. Behind the scenes: overlay attempt + the guaranteed shield top-up.
    Utils.AddBuff(ward, ENUMS.Debuffs.IgnitedHoly, true, BLESS_SECONDS)
    AVU.RechargeBodyShield(ward, RECHARGE_AMOUNT)

    LogDebug("Purifier - gout at " .. tostring(Utils.GetActorName(ward)), SETTINGS.DEBUG_NPC_ACTIONS)
end

return H
