-- =======================================================================
-- VariantResolver - SpawnerData rules + a spawned NPC's base row name -> which
-- variant to turn it into ("" = leave it vanilla).
--   * AUTHORITY ONLY: the sole caller is NpcManager.HandleSpawnedActor.
--   * Clients never run this - they re-derive the variant from the replicated
--     WalkSpeed tag, so a story-gated pick here reaches them for free.
--
-- A spawner picks a variant from one of two fields, both plain strings:
--   * Variant        - a single name (this spawner always emits one NPC type)
--   * MultiVariants  - rowName -> name (spawner emits different NPCs; pick by base)
--
-- STORY BANDING LIVES IN SpawnerData.Resolve, NOT HERE. The rules table handed to
-- R.Resolve is already the band in force (SD.Rules picked the winning Phases entry
-- and merged it) - this module never reads StoryProgress or sees a candidate list.
--   * The old per-field banded-list form ({ "A", { "B", StoryMin=60 } }) is GONE.
--     If you find one in SpawnerData it's a missed conversion; it resolves to a
--     table where a name is expected (ValidateSpawnerData flags it).
-- =======================================================================

local R = {}

function R.Resolve(rules, rowName)
    if not rules then return "" end

    if rules.MultiVariants then
        return rules.MultiVariants[rowName] or ""
    end

    return rules.Variant or ""
end

-- EVERY variant name a rule could resolve to, story-UNRESOLVED (all bands).
--   * [SpawnerHooks] Feeds the spawner asset pre-warm: when a spawner streams in, its
--     possible variants' def.Assets get warmed ahead of the first spawn.
--   * Deliberately NOT filtered by story - warming a shut band's candidate only costs
--     a few asset paths, and a band can open between the warm and the spawn.
--   * MUST be handed the RAW SpawnerData entry (SD.Spawners[name]), not SD.Rules(name):
--     a resolved entry has already dropped the bands it isn't in.
local function collect(rules, out)
    if type(rules) ~= "table" then return end

    if type(rules.Variant) == "string" and rules.Variant ~= "" then
        out[#out + 1] = rules.Variant
    end
    if type(rules.MultiVariants) == "table" then
        for _, name in pairs(rules.MultiVariants) do
            if type(name) == "string" and name ~= "" then out[#out + 1] = name end
        end
    end
end

function R.AllNames(rules)
    local out = {}
    if type(rules) ~= "table" then return out end

    collect(rules, out)                                  -- top-level (shared) props
    for _, phase in ipairs(rules.Phases or {}) do        -- plus every band
        collect(phase, out)
    end
    return out
end

return R
