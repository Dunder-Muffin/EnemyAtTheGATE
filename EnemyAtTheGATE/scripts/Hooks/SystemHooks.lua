
-- ============================================================
-- SystemHooks.lua
-- Odds and ends hooks
-- ============================================================

---@diagnostic disable: undefined-field, undefined-global, unused-local

local STATE        = require("Data.STATE")
local StoryManager = require("Managers.StoryManager")
local Utils        = require("Utils.Utils")

local hook
local HOOKS = {}
local CONFIG    = STATE.Config

local Log = Utils.Log
local LogDebug = Utils.LogDebug

-- If modifying damage dealt to deployables
local pendingDeployableMulti = nil



function HOOKS.Register()

    -- ============================================================
    -- WorldFlagsChanged - called when the game sets a new world flag
    -- * If called, we should check it and advance our STATE.StoryProgress score
    -- ============================================================
    hook = "/Script/AbioticFactor.GameActivitySubsystem:WorldFlagsChanged"
    RegisterHook(hook, function(self)
        -- (was CONFIG.Debug, which is nil - this line never printed)
        LogDebug("[GATE-HOOK] WorldFlagsChanged", CONFIG.DEBUG_LOG)
        
        StoryManager.GetStoryProgress()
    end)


    

    -- ============================================================
    -- Deployed:Process Damage - called when a deployable takes damage
    -- 
    -- * IF we're rebalancing structure damage and damage instigator is an NPC,
    --     we are getting the damage multiplier (in CONFIG) and assigning the multiplier
    --     to pendingDeployableDamageMulti. 
    --
    -- * The other hook GetDamageReduction will scale the damage
    -- 
    -- * While we can do Damage:set() here, it gets set too late and does not apply
    -- ============================================================
    RegisterHook(
        "/Game/Blueprints/DeployedObjects/AbioticDeployed_ParentBP.AbioticDeployed_ParentBP_C:Process Damage",
        function(self, Damage, DamageType, HitLocation, HitNormal, HitComponent, BoneName, ShotFromDirection, InstigatedBy, DamageCauser, HitInfo)
            
            pendingDeployableMulti = nil
            
            local ok, err = pcall(function()

                local instigator = InstigatedBy:get()

                -- NPCs only
                if Utils.IsActorInvalid(instigator) then return end
                if not instigator.NPCData then return end

                local deployable = self:get()
                if IsNotValid(deployable) then return end

                local multiplier = Utils.GetDeployableDamageMultiplier(deployable)
                if multiplier < 0 then return end

                pendingDeployableMulti = multiplier
            end)
            if not ok then
                Utils.LogBad("[GATE] Process Damage (pre) - error: " .. tostring(err))
            end
        end
    )

    -- ============================================================
    -- Deployed:GetDamageReduction - called when applying damage reduction 
    -- 
    -- ============================================================
    RegisterHook(
        "/Game/Blueprints/DeployedObjects/AbioticDeployed_ParentBP.AbioticDeployed_ParentBP_C:GetDamageReduction",
        function(self, BaseDamage, DamageTypeMultiplier, FinalDamageToApply)
            
            if not pendingDeployableMulti then return end
            
            FinalDamageToApply:set(FinalDamageToApply:get() * pendingDeployableMulti)
            
            pendingDeployableMulti = nil
        end,
        true  -- post-hook
    )
    
    -- ============================================================
    -- Pause / unpause
    -- * Track if the game is paused
    -- * We should probably add some pause logic in the Delay functions at some point
    -- ============================================================
    -- SetGamePaused(WorldContextObject, bPaused) - the SETTER, so it fires only
    -- on a real state change and carries the new value.
    --
    -- Why not IsGamePaused (what this used to hook):
    --   * it's a QUERY - engine and BP code call it constantly regardless of
    --     pause state, so STATE.IsPaused latched true the first time anything
    --     asked and never cleared
    --   * it also put a Lua callback on one of the hottest engine statics
    --
    -- Nothing reads STATE.IsPaused today (the endless-assault loop that did is
    -- gone; the director's own poll drives that, and UE timers respect pause).
    -- Kept because it's the correct signal for pause-aware Delay handling.
    hook = "/Script/Engine.GameplayStatics:SetGamePaused"
    RegisterHook(hook, function(self, worldContext, bPaused)
        -- 954 wraps params - :get() them; 553 hands over the raw value.
        local ok, v = pcall(function() return bPaused:get() end)
        if not ok then v = bPaused end
        STATE.IsPaused = (v == true)
    end)

    hook = "/Game/Blueprints/Meta/Abiotic_PlayerController.Abiotic_PlayerController_C:CloseEscapeMenuAndResumeGame"
    RegisterHook(hook, function(self)
        STATE.IsPaused = false
    end)


end

return HOOKS
