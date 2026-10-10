-- =======================================================================
-- VariantTag - tells clients (hosted / server game) which NPCs are mutating.
--   * DisplayName / visual effects don't replicate, so this is how the client
--     learns which NPC to visually change.
--   * The replicated value must be marked dirty (Utils.MarkReplicatedDirty).
--
-- TWO TAGS ARE WRITTEN, one being retired:
--   1. TAG_PROP (`TempThreshold_Default`) holds the Id as a plain integer. It is the ONLY one
--      Decode reads. A DEAD replicated double on the shared character class: no Blueprint reads or
--      writes it anywhere (its TempThreshold siblings only ever hold their class defaults), it
--      defaults to 0, has no OnRep and is not saved.
--      It replaced `LastActiveCamoCooldown`, which the PARENT ProcessDamage overwrites with world
--      time on every hit (Server_TriggerActiveCamoCooldown). A tag there died with its body's
--      first hit, and every "did we mutate this?" check then re-mutated it - a heal mid-fight
--      and a second OnReady. Audit a spare property's writers in the parent character class,
--      not just the NPC classes.
--   2. The old tag rides the decimal FRACTION of NPCData Walk/SprintSpeed and the live WalkSpeed
--      (400.022 = Id 22), with the game recomputing WalkSpeed from the NPCData defaults on any
--      speed-state change - which is why both defaults carry it. WRITE-ONLY now: it is there for
--      clients on a build that predates TAG_PROP, and nothing here reads it back.
--
-- WHY THE MOVE: the speed recompute is `(sprinting ? DefaultSprint : DefaultWalk) * Speed_Multiply`,
-- so any slow or speed buff multiplies the fraction and the Id decodes as another variant (or as
-- nothing) until the buff ends; a peccary charge's `WalkSpeed = 4500` clears it outright.
-- The new property survives both, and being an integer it is not capped at Id 999.
--
-- DECODE NO LONGER READS THE FRACTION. TAG_PROP is 0 on an untagged body, so every vanilla NPC
-- fell through to it - and a buffed one (a 650 sprint at -35% = 422.5) decoded as a live-looking
-- Id, which the "did we mutate this?" checks read as YES and then skipped forever. It only ever
-- covered a server older than TAG_PROP itself, and a false MISS is now just a re-mutation rather
-- than a free heal (AVU.SetLimbHealth preserves damage), so it was insuring the wrong direction.
--
-- Ids stay <= 999 while the fraction is still written. Dropping that write retires AVU.TagSpeed.
--
-- ON THE WIRE: `/au-netprobe prop` and `propsave` test whatever VT.TAG_PROP names. The previous
-- property passed both (bit-exact doubles to non-owning clients, not in the world save, so a
-- save-restored body reads untagged - Law 2's test holds); this one carries the same flags on the
-- same class. Re-run both after changing TAG_PROP. [[anteup2-variant-tag-wiped-by-damage]]
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local Utils = require("AnteUtils.Utils")
local ENUMS = require("AnteData.Enums")

local WALK   = ENUMS.NpcData.WalkSpeed
local SPRINT = ENUMS.NpcData.SprintSpeed

-- 3-decimal fraction; Id 1..999 (frac 0.001..0.999 never reaches 1.0, so it never overflows
-- into WalkSpeed's integer part; float32 holds 3 decimals fine at NPC walk speeds).
-- 4-digit Ids would break (precision + overflow).
local TAG_SCALE = 1000

-- The primary tag: a replicated double with no OnRep that no Blueprint reads or writes.
local TAG_PROP = "TempThreshold_Default"
-- A sane Id band, so a stray value can't read as an Id.
local MAX_ID = 9999

local VT = {}
VT.TAG_PROP = TAG_PROP   -- AnDebug/NetProbe tests this name


-- Server / authority: tag actor with def.Id.
--   * Call AFTER the variant's Stats fn has set its intended speeds (we floor them, add the tag).
function VT.Apply(actor, variant)
    if not variant or not variant.Id then return end
    if Utils.IsActorInvalid(actor) then return end

    local npcData = actor.NPCData
    if IsNotValid(npcData) then return end

    local frac = variant.Id / TAG_SCALE

    -- tonumber: a field name for the wrong game build reads a placeholder, not a number, and
    -- floor(0) + frac would pin the NPC at a walk speed of 0.0xx. Skip the fraction, keep the tag.
    local walkNow, sprintNow = tonumber(npcData[WALK]), tonumber(npcData[SPRINT])
    if walkNow and sprintNow then
        local walk = math.floor(walkNow) + frac
        npcData[WALK] = walk
        npcData[SPRINT] = math.floor(sprintNow) + frac

        -- WalkSpeed is the replicated value the client actually reads;
        -- set it directly too so the tag lands immediately (before any recompute)
        actor.WalkSpeed = walk
        Utils.MarkReplicatedDirty(actor, "WalkSpeed")
    else
        Utils.LogBad(string.format("VariantTag.Apply - %s: NPCData speeds unreadable (%s / %s); "
            .. "speed fraction skipped", tostring(variant.Name or variant.Id), WALK, SPRINT))
    end

    -- The primary tag. Written last so it lands with the same mutation beat as the fraction.
    pcall(function() actor[TAG_PROP] = variant.Id end)
    Utils.MarkReplicatedDirty(actor, TAG_PROP)
end


-- Any machine: decode a variant Id off TAG_PROP. Returns an integer Id (>=1), or nil if untagged.
-- A body whose TAG_PROP write failed reads untagged and is re-mutated by the heal walk.
function VT.Decode(actor)
    if Utils.IsActorInvalid(actor) then return nil end

    local ok, raw = pcall(function() return actor[TAG_PROP] end)
    if not ok then return nil end

    -- tonumber, not a type check: a property the class lacks reads as a TrivialObject, never nil.
    local id = tonumber(raw)
    if id and id >= 1 and id <= MAX_ID and id == math.floor(id) then return id end
    return nil
end


-- Id -> def, built on first use. VariantReload refills the registry in place, so it calls
-- VT.RebuildIdMap, or this would keep handing back the pre-reload defs.
--   * The registry is required here, not at load: the variant files require this module.
local defById

function VT.RebuildIdMap()
    defById = {}
    for _, variant in pairs(require("AnteVariants.Variants")) do
        if variant.Id then defById[variant.Id] = variant end
    end
end

-- Any machine: the def this body was mutated into, or nil. The tag, not the DisplayName (Law 2),
-- and a number read rather than a copy of the name's FText.
function VT.DefOf(actor)
    local id = VT.Decode(actor)
    if not id then return nil end
    if not defById then VT.RebuildIdMap() end
    return defById[id]
end


-- True if a spawned NPC's base game row (rowName) is a base this variant accepts:
-- its primary `Base`, or any of its optional `AltBases`.
--   * AltBases = closely-related rows sharing the skeleton + NPCData (e.g. a base-"Grunt"
--     variant accepting "Grunt_Guard" / "Grunt_Guard_Offduty" - both NPC_Soldier_Grunt subclasses).
--   * Used by the integrity check on BOTH server (NpcManager) and client (ClientVisuals)
--     so they agree.
--   * No Base = no constraint (accept anything).
function VT.AcceptsBase(variant, rowName)
    if not variant or not variant.Base then return true end
    if rowName == variant.Base then return true end
    local alts = variant.AltBases
    if alts then
        for i = 1, #alts do
            if alts[i] == rowName then return true end
        end
    end
    return false
end

return VT
