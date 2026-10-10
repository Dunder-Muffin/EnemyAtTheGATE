-- =======================================================================
-- Variants - aggregates all variant definitions into one registry.
--   * Used by AnteVariants.NpcManager (Stats / Visuals)
--   * Used by AnteVariants.ClientVisuals (Visuals)
--
-- ** Add new variant files here as they are ported from AnteUp v1. **
--
-- NOTE: Lua 5.4 require() returns (module, loader path)
--   * Assign each require to its own local first
--   * Calling require() directly expands the string into the table and breaks this
-- =======================================================================

local Utils = require("AnteUtils.Utils")

local Pest = require("AnteNPCs.Pest")
local Peccary = require("AnteNPCs.Peccary")
local PeccaryAlpha = require("AnteNPCs.PeccaryAlpha")
local PeccarySow = require("AnteNPCs.PeccarySow")
local ExorMonk = require("AnteNPCs.ExorMonk")
local Exor = require("AnteNPCs.Exor")
local ExorArmored = require("AnteNPCs.ExorArmored")
local ExorPikeman = require("AnteNPCs.ExorPikeman")
local ExorVolatile = require("AnteNPCs.ExorVolatile")
local PestElectro = require("AnteNPCs.PestElectro")
local PestSnow = require("AnteNPCs.PestSnow")   -- the zigzag-leap snow pests (Pest_Snow)
local PestLeyak = require("AnteNPCs.PestLeyak")   -- the aura/invisibility pest (Pest_Leyak)
local PestVolatile = require("AnteNPCs.PestVolatile")
local Symphonist = require("AnteNPCs.Symphonist")
local RobotSecurity = require("AnteNPCs.RobotSecurity")
local RobotContainment = require("AnteNPCs.RobotContainment")
local RobotDefense = require("AnteNPCs.RobotDefense")
local RobotCorrupt = require("AnteNPCs.RobotCorrupt")
local OrderGrunt = require("AnteNPCs.OrderGrunt")
local OrderBreacher = require("AnteNPCs.OrderBreacher")
local OrderMedic = require("AnteNPCs.OrderMedic")
local OrderCaptain = require("AnteNPCs.OrderCaptain")
local OrderSniper = require("AnteNPCs.OrderSniper")
local OrderLabRat = require("AnteNPCs.OrderLabRat")
local OrderFlameRat = require("AnteNPCs.OrderFlameRat")   -- the flamethrower grunts (Event FlameRat + the Purified cell)
local OrderSapper = require("AnteNPCs.OrderSapper")
local Crystallisk = require("AnteNPCs.Crystallisk")
local OrderClericus = require("AnteNPCs.OrderClericus")   -- the projectile-parrying swordsman (Salii)
local PlayerPets = require("AnteNPCs.PlayerPets")
local Zombies = require("AnteNPCs.Zombies")
local Tarasque = require("AnteNPCs.Tarasque")
local Pillager = require("AnteNPCs.Pillager")
local Shades = require("AnteNPCs.Shades")
local OrderGroupe = require("AnteNPCs.OrderGroupe")
local OrderRook = require("AnteNPCs.OrderRook")    -- the Order shield troopers (Trooper_Shield)
local OrderInterfector = require("AnteNPCs.OrderInterfector")   -- the dual-dagger assassin (Winterfector)
local Yeti = require("AnteNPCs.Yeti")
local GKHeavy = require("AnteNPCs.GK_Heavy")   -- all Gatekeeper_Heavy variants (Jotun + Rocketeer)
local GK_Neophyte = require("AnteNPCs.GK_Neophyte")
local GK_Chieftain = require("AnteNPCs.GK_Chieftain")
local GK_Witch = require("AnteNPCs.GK_Witch")
local GK_DarkLens = require("AnteNPCs.GK_DarkLens")   -- the DarkLens Chieftain boss set (Fallow Patriarch + Phyter escorts)
local Mage = require("AnteNPCs.GK_Mage")           -- the MAGES (Barrier / Abjurer; Beholder archived)
local MageEye = require("AnteNPCs.GK_MageEye")     -- the EYES (Warden standalone + Barrier support)
local TamedPests = require("ModulePets.TamedPests")   -- PET forms of tamed variants (ModulePets)
local TamedPeccary = require("ModulePets.TamedPeccary") -- PET forms of tamed peccaries (Tamed Hive Sow)
local TamedLamogi = require("ModulePets.TamedLamogi")   -- the Plasmogi (fed into being, no wild form)
local ShadowTentacle = require("AnteNPCs.ShadowTentacle")   -- final-boss shield tentacles (ModuleShadow transforms them)

local sources = {
    Pest,
    Peccary,
    PeccaryAlpha,
    PeccarySow,
    ExorMonk,
    Exor,
    ExorArmored,
    ExorPikeman,
    ExorVolatile,
    PestElectro,
    PestSnow,
    PestLeyak,
    PestVolatile,
    Symphonist,
    RobotSecurity,
    RobotContainment,
    RobotDefense,
    RobotCorrupt,
    OrderGrunt,
    OrderBreacher,
    OrderMedic,
    OrderCaptain,
    OrderSniper,
    OrderLabRat,
    OrderFlameRat,
    OrderSapper,
    Crystallisk,
    OrderClericus,
    PlayerPets,
    Zombies,
    Tarasque,
    Pillager,
    Shades,
    OrderGroupe,
    OrderRook,
    OrderInterfector,
    Yeti,
    GKHeavy,
    GK_Neophyte,
    GK_Chieftain,
    GK_Witch,
    GK_DarkLens,
    Mage,
    MageEye,
    TamedPests,
    TamedPeccary,
    TamedLamogi,
    ShadowTentacle,
}

local VARIANTS = {} -- name -> variant. add name to variant (variant.Name)
local seenVariants = {} -- client side uses ID to identify variants

for _, source in ipairs(sources) do
    for name, variant in pairs(source) do
        if VARIANTS[name] then
            Utils.LogBad("Duplicate variant definition: " .. name)
        end

        variant.Name = name

        -- Unique IDs required for client
        if variant.Id then
            if seenVariants[variant.Id] then
                Utils.LogBad("********************************************")
                Utils.LogBad(string.format("Duplicate variant ID %d (%s and %s)",
                                variant.Id, name, seenVariants[variant.Id]))
                Utils.LogBad("********************************************")
            end
            seenVariants[variant.Id] = name
        end

        VARIANTS[name] = variant
    end
end

return VARIANTS
