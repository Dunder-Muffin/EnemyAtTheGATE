-- =======================================================================
-- Crystallisk helpers - the decloak/overlay/shatter machinery behind AnteNPCs/Crystallisk.lua
--
-- MUST-KNOWS
--   * Tinting is unreliable: the Cloak FSM owns the mesh and hard-sets both material slots on
--     every Decloak flip (own timer, the NoCloak buff, or death) - never permanent.
--   * So the look rides the OVERLAY slot instead. Most overlay materials expose no params, and
--     the one tintable one (M_Ignited) is too translucent - hence the flat OverlayMat below.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local ENUMS = require("AnteData.Enums")
local STATE = require("AnteCore.State")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")

local LogDebug = Utils.LogDebug

local H = {}


-- =======================================================================
-- DECLOAK
-- =======================================================================

-- Reassert offsets: the cloak FSM flips the look back after firing, so one write isn't enough.
local DECLOAK_REASSERT_MS = { 300, 800, 1500, 3000 }

-- Force cloak off. The NoCloak buff grants the tag the cloak FSM checks each firing cycle -
-- without it the look flickers out after every shot.
function H.StayDecloaked(actor, fireDelay)
    Utils.AddBuff(actor, ENUMS.Debuffs.NoCloak, true, 99999)

    local function decloak()
        if Utils.IsActorInvalid(actor) then return end
        pcall(function()
            actor.Decloak = true
            Utils.MarkReplicatedDirty(actor, "Decloak")
            actor:OnRep_Decloak()
            actor.DecloakBeforeFiringDelay = fireDelay or 1
            actor.RecloakAfterFiringDelay = fireDelay or 1
        end)
    end
    decloak()
    for _, ms in ipairs(DECLOAK_REASSERT_MS) do
        Utils.QueueWork(decloak, ms)
    end
end


-- =======================================================================
-- OVERLAY
-- =======================================================================

local CRYSTAL = {
    OverlayMat = ENUMS.Components.M_REAPER_DARKNESS,   -- no color params
    Tint       = nil,
    TintGlow   = 5,
    SeatRange  = 3000,
}
H.OVERLAY_MAT = CRYSTAL.OverlayMat   -- exposed for the def file's Assets preload lists

-- [RENDERER] Set or reset the overlay. It's a ~30ms call and can be pricy.
function H.SetOverlay(actor)
    if not CRYSTAL.Tint then
        AVU.SetOverlayMaterial(actor, CRYSTAL.OverlayMat)
        return
    end
    local mid = AVU.SetOverlayMaterialDynamic(actor, CRYSTAL.OverlayMat)
    if not mid or IsNotValid(mid) then return end
    pcall(function()
        mid:SetVectorParameterValue(FName("Color"), CRYSTAL.Tint)
        mid:SetScalarParameterValue(FName("Boost Emssive"), CRYSTAL.TintGlow)
    end)
end

-- Reset the overlay on cloak, only if a player is nearby.
local function holdOverlay(actor)
    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return end
    local cur
    pcall(function() cur = mesh.OverlayMaterial end)
    if IsValid(cur) then return end
    local loc = actor:K2_GetActorLocation()
    if not loc or not Utils.IsPlayerNearby(loc, CRYSTAL.SeatRange) then return end
    H.SetOverlay(actor)
end

-- [OnTick] ~1s overlay hold, shared by the Obsidilisk and the Shardling. Runs on clients too
-- (ClientTick); HasRenderer skips it on a dedicated server.
function H.OverlayTick(actor, totalTicks)
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    if totalTicks % 10 == 0 and Utils.HasRenderer() then holdOverlay(actor) end
end


-- =======================================================================
-- OBSIDILISK SHATTER
-- =======================================================================

local SHATTER = {
    Count     = 3,     -- bodies; CountHard replaces it under HARDMODE.NoMercy
    CountHard = 5,
    Ring      = 150,   -- how far out each one lands
    RevealMs  = 450,   -- hidden while it phases in small (see shrinkShardling)
    RollMs    = 500,   -- scatter roll, just after the reveal
}
H.SHARD_SCALE = 0.5   -- newborn Shardling size - shared with Crystallisk.lua's Shardling Visuals

-- Size the body down on the spawning frame, ahead of the Visuals step that owns the scale.
-- Visuals runs off the WorkQueue, which drains two items a tick newest-first - with a whole ring
-- landing at once that can slip well past the reveal, and a full-size assassin flashes in.
local function shrinkShardling(actor)
    AVU.SetVisualScale(actor, FVector(H.SHARD_SCALE, H.SHARD_SCALE, H.SHARD_SCALE))
end

-- [AUTHORITY] Ring of Shardlings around the corpse, each facing outward and rolling away.
--   * The facing comes from the AUTHORED angle, not from a look-at off the spawn point: the nav
--     snap can land a body well off the ring, and a look-at from there aims it back inward.
--   * The roll is the base's own power-melee montage, which is a lunge rather than a swing. Its
--     damage comes from the native melee path, so playing it standalone is a pure visual.
function H.ShatterIntoShardlings(center)
    local count = STATE.HardModeNoMercy and SHATTER.CountHard or SHATTER.Count
    local spin  = math.random() * 360   -- so the ring isn't always laid out the same way

    for i = 1, count do
        local yaw = spin + (i - 1) * (360 / count)
        local rad = math.rad(yaw)
        local out = FVector(center.X + math.cos(rad) * SHATTER.Ring,
                            center.Y + math.sin(rad) * SHATTER.Ring,
                            center.Z + 20)
        -- Tight nav fuzz: a wide search around a ring point just undoes the ring.
        local spawnLoc = Utils.GetSpawnPoint(out, 100)
            or Utils.GetSpawnPoint(FVector((center.X + out.X) * 0.5, (center.Y + out.Y) * 0.5, out.Z), 120)
            or Utils.GetSpawnPoint(center, 200)

        if spawnLoc then
            AVU.SummonVariant("Shardling", spawnLoc, { Rotation = FRotator(0, yaw, 0) }, function(npc)
                shrinkShardling(npc)
                AVU.SpawnHidden(npc, SHATTER.RevealMs)
                Utils.QueueWork(function()
                    AVU.PlayMontageReplicated(npc, ENUMS.Anims.ASSASSIN_POWER_MELEE, 1, false)
                end, SHATTER.RollMs)
            end)
        end
    end

    LogDebug("Obsidilisk - shattered into " .. count .. " Shardlings", SETTINGS.DEBUG_NPC_ACTIONS)
end


-- =======================================================================
-- GRAVILISK CRAWL
-- =======================================================================

-- One-time flip to ceiling gravity. The upward nudge is additive (not an override), so it stacks
-- with whatever the character was already doing - AVU.LaunchCharacterFrom always overrides both
-- axes and takes a pivot/direction shape, so it doesn't fit this flat vertical nudge.
function H.StartCrawl(actor, upScale)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end
    if IsNotValid(actor.CharacterMovement) then return end
    AVU.SetCeilingGravity(actor, true, { UpScale = upScale, NudgeZ = 0 })
    pcall(function() actor:LaunchCharacter(FVector(0, 0, 200), false, false) end)
end


return H
