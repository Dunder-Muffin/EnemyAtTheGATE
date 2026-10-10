
-- ============================================================
-- StoryManager.lua
-- * Sets STATE.StoryProgress
-- * Relative 'score' of how far players are in the game
-- * We use that value to choose harder assaults as the game continues
-- ============================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE  = require("Data.STATE")
local CONFIG = STATE.Config
local Utils  = require("Utils.Utils")

local LogDebug = Utils.LogDebug

local SM = {}


-- WorldFlag to StoryProgress lookup table
local STORY_FLAG_VALUES = {
    Office_ReachedLobby          = 10,
    Office_Silo3PortalOpened     = 11,
    Fog_Completed                = 12,
    WeatherFogTriggeredOnce      = 14,
    Office_ForkliftDoorOpened    = 15,

    Manufacturing_Arrived        = 20,
    MF_MetVarsha                 = 21,
    MF_OpenTrainStation          = 22,
    MF_MetBlacksmith2            = 23,
    TrainCompletedOnce           = 24,
    MF_PumpsFixed                = 27,
    MF_ExitOpened                = 28,

    LABS_EnteredLabs             = 30,
    LABS_Met_Thule               = 31,
    Labs_Helmholtz_Opened        = 32,
    LABS_TurretsDeactivated      = 33,
    LABS_AnteverseBFixed         = 34,
    LABS_CompletedAnteverseB     = 35,
    LABS_OpenVacuumDoor          = 36,

    Security_Entered             = 40,
    NightRealm_ShadowA_Destroyed = 41,
    Salem_Opened                 = 42,
    Salem_Complete               = 43,
    NightRealm_ShadowB_Destroyed = 44,
    NightRealm_ShadowC_Destroyed = 45,
    NightRealm_ShadowD_Destroyed = 46,
    Security_ExitOpened          = 47,

    Dams_DarkWaterDrained        = 50,
    Dams_MetIsaiah               = 51,
    Dams_ReachedCentral          = 52,
    Dams_MetSwimInstructor       = 53,
    Voussoir_Entered             = 54,
    DAMS_CompletedVoussoir       = 55,
    Dams_AllPumpsActivated       = 56,
    Dams_SpillwayOpen            = 57,

    Plant_EnteredPlant           = 60,
    Plant_AnteC_Entered          = 61,
    Plant_FungusDestroyed        = 62,
    Plant_ExitOpened             = 63,

    Reactors_FirstContact           = 70,
    Reactors_S1_Fixit               = 71,
    Reactors_S4RadWaste_Complete    = 72,
    Reactors_S3Overgrowth_Complete  = 73,
    Reactors_S2War_Complete         = 74,
    Reactors_AllStations_Complete   = 75,
    Reactors_SG_Entered             = 76,
    Reactors_SG_End                 = 77,
    
    V_INQ_Entrance               = 80,
    V_INQ_HastaMet               = 81,
    V_INQ_SunDiskTouched         = 82,
    Res_HastaTria_EndCutscene    = 83,

    Residence_Entered            = 90,
    Residence_AbeJanetMet        = 91,
    Res_Objective1_Complete      = 92,
    Residence_IceWallRemoved     = 93,
    Res_EnteredBotanicals        = 94,
    Wall_AG_met                  = 95,
    Fracture_Forcefield_Complete = 96,
    Residence_Fracture_Complete  = 97,

    End_Contact                  = 100,
    EndBossDefeated              = 101,
    End_MainStoryComplete        = 102,
    
}


local function GetWorldFlags()
    local flags = {}
    local wfs   = FindFirstOf("WorldFlagSubsystem")
    if not wfs then return flags end
    if not wfs:HasWorldFlagsLoaded() then return flags end

    local rawFlags = {}
    wfs:GetWorldFlags(rawFlags)
    for _, flag in ipairs(rawFlags) do
        flags[flag:get():ToString()] = true
    end
    return flags
end

-- GetWorldFlags then update STATE.StoryProgress if there's relative story progression
function SM.GetStoryProgress()
    local flags = GetWorldFlags()
    local sp = STATE.StoryProgress

    for flagName, value in pairs(STORY_FLAG_VALUES) do
        --LogDebug(flagName, Config.DEBUG_LOG) -- Can log WorldFlags to check them
        if flags[flagName] and value > sp then
            sp = value
        end
    end

    -- No change
    if sp == STATE.StoryProgress then return end
    
    -- StoryProgress updated
    LogDebug(string.format("[GATE] STORY [%d] -> [%d]",
        STATE.StoryProgress, sp), CONFIG.DEBUG_LOG)
    STATE.StoryProgress = sp
    
end

return SM
