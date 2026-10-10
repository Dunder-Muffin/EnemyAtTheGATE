-- =======================================================================
-- AudioFix - gives shipped voice waves the SoundClass they were authored without.
--
-- A wave with an empty SoundClassObject sits outside the Abiotic_Master tree that every volume
-- slider adjusts, so it plays at a flat 1.0 no matter where the sliders are - roughly 15-20x the
-- rest of the mix at low master. ENUMS.VoiceFix carries the affected paths and the reasoning.
--
-- REPAIRS ONLY WHAT IS STILL BROKEN: a wave that already resolves a SoundClass is left alone, so
-- if the game ever ships these assets fixed this module quietly stops doing anything.
--
-- LIFECYCLE: Establish on InitMod, per world. RENDERER-only and purely local - a SoundClass is a
-- playback property, so each machine repairs its own copy and nothing replicates.
--
-- RESIDENCY: the write lives on the loaded UObject, so a collected-and-reloaded wave comes back
-- unclassed. The waves are pinned first and the repair runs after the pins land. With
-- SETTINGS.CORE.ASSET_KEEPER off nothing pins and the repair holds only until the next GC.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local ASSETS = require("AnteCore.AssetManager")
local Utils = require("AnteUtils.Utils")
local ENUMS = require("AnteData.Enums")

local AudioFix = {}

-- Long enough for PinPaths' own load + drain to have run, so the repair writes onto a pinned wave.
local PIN_SETTLE_MS = 3000

-- path -> true once the wave resolves a SoundClass, ours or the game's. Module-local on purpose:
-- a /reload drops it and the next pass re-verifies, which costs one skip per wave.
local classed = {}

-- True only when the field really holds a SoundClass. An empty object field can read back as a
-- placeholder rather than nil, so IsA is what decides.
local function hasSoundClass(wave, scType)
    local ok, yes = pcall(function()
        local c = wave.SoundClassObject
        return c ~= nil and not IsNotValid(c) and c:IsA(scType)
    end)
    return ok and yes == true
end

local function repair()
    local scType = ASSETS.GetIfValid("/Script/Engine.SoundClass")
    local sc = ASSETS.GetIfValid(ENUMS.VoiceFix.SoundClass)
    if IsNotValid(sc) or IsNotValid(scType) then
        Utils.LogBad("AudioFix - " .. ENUMS.VoiceFix.SoundClass .. " not resolvable; barks left unclassed")
        return
    end

    local scName = sc:GetFullName()
    -- `shipped` = the game classed it itself. Counted separately so an upstream fix is visible in
    -- the log as this module standing down, not as a silent success.
    local set, shipped, failed = 0, 0, 0
    for _, path in ipairs(ENUMS.VoiceFix.Unclassed) do
        if not classed[path] then
            local wave = ASSETS.GetIfValid(path)
            if IsNotValid(wave) then
                failed = failed + 1
                Utils.LogBad("AudioFix - wave not resident: " .. path)
            elseif hasSoundClass(wave, scType) then
                classed[path] = true
                shipped = shipped + 1
            else
                -- Read back: a rejected write would otherwise look exactly like a repaired wave.
                local held = false
                pcall(function()
                    wave.SoundClassObject = sc
                    held = wave.SoundClassObject:GetFullName() == scName
                end)
                if held then
                    classed[path] = true
                    set = set + 1
                else
                    failed = failed + 1
                    Utils.LogBad("AudioFix - SoundClass write rejected: " .. path)
                end
            end
        end
    end

    Utils.Log(("AudioFix - voice waves: %d repaired, %d already classed, %d failed (of %d)")
        :format(set, shipped, failed, #ENUMS.VoiceFix.Unclassed))
end


function AudioFix.Establish()
    if not SETTINGS.CORE.VOICE_SOUNDCLASS_FIX then return end
    if not Utils.HasRenderer() then return end

    local paths = ENUMS.VoiceFix.Unclassed
    ASSETS.LoadAsync(paths, function()
        Utils.QueueWork(function()
            pcall(function() require("AnteCore.AssetKeeper").PinPaths(paths) end)
            Utils.QueueWork(repair, PIN_SETTLE_MS)
        end, 0)
    end)
end


return AudioFix
