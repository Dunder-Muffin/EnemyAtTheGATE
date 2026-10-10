-- =======================================================================
-- VariantSignal - DYNAMIC server -> client scalar channel.
--   * Like VariantTag, but for values that change over time
--     (VariantTag rides Walk/SprintSpeed as a static "what to mutate into" Id).
--   * The chosen property's OnRep_ must not trigger other effects -
--     otherwise every replicated change fires that effect.
--   * Channels in use:
--     1) CurrentBleedoutTime - updates CustomTimeDilation.
--        Game only uses it for DBNO, so it's free on NPCs that never go DBNO.
--        Its OnRep_ early-returns for a local player; fine otherwise.
--     2) DamageTakenAfterDeath - updates <unused> (only useful for dead NPCs).
--        Avoid on live NPCs - its OnRep_ calls UpdateFleshCutWoundVFX, which
--        paints gore VFX on the body. Only safe post-death, where that's intended.
--   * Push-model networking: a write only sends if marked dirty (Utils.MarkReplicatedDirty),
--     at the actor's net-update rate (not per-frame) and distance-throttled -
--     so this is "next net update".
--
-- AUTHORITY writes (Set) - CLIENT (and host) reads (Read)
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local Utils = require("AnteUtils.Utils")

local VS = {}

-- Channel names (the replicated double property to ride).
VS.TDI = "CurrentBleedoutTime"      -- CustomTimeDilation mirror (OnRep no-op on NPCs)
VS.AUX = "DamageTakenAfterDeath"    -- spare; WARNING: drives CutDamage wound VFX


-- Authority: write `value` to `channel` and mark it dirty so it replicates.
function VS.Set(actor, channel, value)
    if Utils.IsActorInvalid(actor) then return end
    pcall(function()
        actor[channel] = value
        Utils.MarkReplicatedDirty(actor, channel)
    end)
end

-- Any machine: read the (last replicated) channel value, or nil.
function VS.Read(actor, channel)
    if Utils.IsActorInvalid(actor) then return nil end
    local ok, v = pcall(function() return actor[channel] end)
    if ok then return v end
    return nil
end

return VS
