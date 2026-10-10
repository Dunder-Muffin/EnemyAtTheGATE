-- =======================================================================
-- NpcResistances - per-variant elemental weakness / resistance multipliers
--
--   [Variant DisplayName] = { <DamageTypeDisplayName> = multiplier, ... }
--     0 = immune   < 1 = resistance   1 = neutral (no-op)   > 1 = weakness
--     1.5x=should negate an NPCs natural resistance
--
--     - Read by the [CheckForNPCDamageMultiplier] hook (AnteVariants/CombatHooks),
--       which multiplies the incoming damage and floors it. Nothing else uses it.
--     - Outer key is the VARIANT DisplayName (Utils.GetActorName), not a DT_NPCList row.
--
--   * VALID TYPE KEYS:
--      Sharp  Blunt  Bullet  Bleeding  Explosive
--      Fire  Cold  Electricity  Acid  Laser
--      Psychic     Holy      Radiation
--
--     - Key off Damage Type [Display Name]
--         > Damage Types have subclasses, and subclasses INHERIT the display name
--         > There's 20+ DamageType_Sharp subclasses. We just do Sharp
--         > Subclasses modify behavior which we don't need to worry about
--             - ex: DamageType_Fire_Plasma has a chance to ignite
--                   DamageType_Bullet_Large has a chance to heavy bleed
--     - UNMATCHABLE, don't add: "Plasma" (Fire_Plasma keeps the "Fire" display name)
--       and the hardlight saber / sledge (Laser subclasses -> read as "Laser")
--
--   * NATIVE BEHAVIOR: The native game does weakneeses / resistances differently
--       - It uses GamePlayTags
--       - Resist is 65% damage taken, Weakness increases critical chance
--       - A 0 here can make an NPC immune, but this table can never UN-immune one:
--         the native body already multiplied by ImmuneDamageMultiplier (0) first.
--         To override native npc immunity use AVU.SetImmuneDamageMultiplier(actor, 1)
--
-- =======================================================================

return {
    -- =======================================================================
    -- HARD MODE overrides (SETTINGS.MODULES.HARDMODE.NoMercy) - layered over the base variant
    -- =======================================================================
    HardMode = {
        ["Razor Pest"]      = { Sharp=0.33 },
        ["Chonky Pest"]      = { Blunt=0.33 },
        ["Anterazor Pest"]  = { Sharp=0.33 },
        ["Tarasque Summoner"] = { Explosive=0.33 },
        ["Tarasque Charger"] = { Explosive=0.33 },
        ["Tarasque Slammer"] = { Explosive=0.33 },

    },

    -------------------
    -- A2 Entities
    -------------------
    ["Razor Pest"]      = { Sharp=0.5, Blunt=3 }, --Native blunt resistance
    ["Chonky Pest"]     = { Sharp=2, Blunt=0.5 },
    ["Antegrav Pest"]   = { Blunt=2 },
    ["Laser Pest"]      = { Laser=0 },
    ["Telepest"]        = { Blunt=2 },
    ["Anterazor Pest"]  = { Sharp=0.5, Blunt=2 },
    ["Chonky Signal Pest"] = { Sharp=2, Blunt=0.5 },
    ["Pestilence"]     = { Acid=0, Fire=2, Laser=2 },
    ["Flurry Pest"]     = { Cold=0, Fire=2 },

    ["Charge Peccary"] = { Electricity=0 },
    ["Whiteout Peccary"]   = { Cold=0, Fire=2 },
    ["Carbunccary"]    = { Sharp=0.5, Blunt=2 },
    
    ["Magma Peccary"]  = { Blunt=2, Fire=0, Holy=0, Explosive=0.25 },
    ["Hive Sow"]       = { Fire=2, Acid=0 },

    ["Exor Magus"]      = { Blunt=2, Explosive=0.5 },
    ["Exorrior Magus"]  = { Blunt=2, Explosive=0.5 },

    ["Magma Exor"]           = { Fire=0, Holy=0, Explosive=0.25 },
    ["Antefire Exor"]       = { Fire=0, Holy=0, Explosive=0.25 }, 
    ["Exor Displacer"]      = { Fire=2, Electricity=2, Acid=0 },
    ["Exor Repeller"]     = { Electricity=2, Acid=2 },
    ["Exor Dislocator"]     = { Fire=2, Electricity=2, Acid=0 },
    ["Winter Exor"]         = { Cold=0, Fire=2 },
    ["Exor Spiritwalker"]       = { Fire=0, Electricity=0, Laser=0, Holy=0, Blunt=2 },
    ["Exor Wraith"]         = { Sharp=0, Blunt=0, Bullet=0, Acid=0, Explosive=0, Holy=2 },
    ["Exor Hunter"]      = { Sharp=3, Explosive=0.5 },
    ["Exor Killer"]     = { Blunt=3, Explosive=0.5 },
    ["Acidic Exor"]         = { Acid=0 },

    -------------------
    -- Order
    -------------------
    ["Velites Guard"]    = { Blunt=3.1 },
    ["Grenadier Guard"]  = { Explosive=0.5, Blunt=3.1 },
    ["Centurion Grunt"]  = { Electricity=2 },
    ["Dioscoridian"]     = { Blunt=3.1 },
    ["Sweeper"]          = { Blunt=3.1, Electricity=2, Sharp=2, Explosive=0.5 },
    ["Skirmisher"]       = { Bullet=1.6, Explosive=0.5 }, --1.6 resistance weight (TODO: look at vanilla resistance bypassing for Sharp/Blunt)
    ["Shield Embolon"]   = { Bullet=0.25, Electricity=0.5, Holy=0.5, Explosive=0.5 },

    ["Flask Rat"]        = { Blunt=2 },
    ["Super Sapper"]     = { Explosive=0.25, Electricity=2, Laser=1.5 },
    ["Rocket Rat"]       = { Electricity=2, Explosive=0.25, Laser=1.65 }, --Explosive, Laser native resist
    ["Mad Rat"]          = { Electricity=2, Laser=1.5, Explosive=0.5, Psychic=0.5, Acid=0.25, Holy=0.25},

    ["Groupe Frostpack"] = { Fire=2, Holy=2 },
    ["Groupe Breacher"]  = { Fire=2, Holy=2 },
    ["Groupe Rookram"]  = { Fire=2, Holy=2 },
    ["Groupe Sniper"]    = { Fire=2, Holy=2 },
    
    ["Purified Grunt"]    = { Holy=0 },
    ["Purified Breacher"] = { Holy=0 },
    ["Purified Rat"]      = { Holy=0 },
    ["Purified Interfector"] = { Holy=0 },
    ["Winterfector"]     = { Cold=0, Fire=2, Acid=1.65 }, -- Resists acid


    -------------------
    -- Robots
    -------------------
    ["Cafeteria Bot"]    = { Sharp=0.5, Blunt=2, Acid=2 },
    ["Advanced Cafeteria Bot"] = { Sharp=0.5, Blunt=2, Acid=2 },
    ["Office Bot"]       = { Sharp=0.5, Blunt=2, Electricity=0 },
    ["Hospitality Bot"]  = { Sharp=0.5, Acid=2, Blunt=2, Psychic=0.25, Laser=0.25, Electricity=0,  },
    ["Event Hospitality Bot"]  = { Acid=2, Blunt=2, Electricity=0, Psychic=0.5, Laser=0.25 },
    ["Big Bot"]          = { Acid=2, Blunt=2, Electricity=0.5, Psychic=0.5, Laser=0.5 },
    ["Advanced Big Bot"] = { Acid=2, Blunt=2, Electricity=0.5, Psychic=0.5, Laser=0.5 },
    ["Constrictor Bot"]  = { Fire=3, Holy=3 },
    ["Artillery Bot"]  = { Electricity=2,  Blunt=2 }, --Native: Acid Laser
    ["Deatomizer Bot"]  = { Electricity=2, Blunt=2, Explosive=0.5, Laser=0 }, --Native: Acid Laser

    -------------------
    -- Gatekeepers
    -------------------
    ["Jotun Rider"]    = { Psychic=0 }, --ignore Peccary explosion damage
    ["Jotun Steed"]    = { Explosive=0.25, Bullet=0.5 },
    ["Jotun Rocketeer"]    = { Explosive=0.25 },
    ["Plague Witch"]   = { Explosive=0.5, Acid=0 },
    ["Storm Witch"]    = { Explosive=0.5, Electricity=0 },
    ["Warrior Witch"]      = { Explosive=0.5 },

    -------------------
    -- Gatekeeper Bosses
    -------------------
    ["Fallow Patriarch"] = { Explosive=0.5 },

    ["Mother of the Fallow"] = { Explosive=0.5, Laser=0.5 },

    ["DarkLens Phyter"]  = { Explosive=0.5 },
    ["Weak Phyter"]      = { Explosive=0.25 },

    ["Jotun of the Fallow"] = { Acid=1.5, Explosive=0.25 },
    ["Fallow Steed"]        = { Explosive=0.25 },

    ["Magus of the Fallow"] = { Explosive=0.33 },

    ["Astral Magus"] = { Sharp=0, Blunt=0, Bullet=0, Bleeding=0,
        Acid=0, Explosive=0, Holy=2 },

    -------------------
    -- Canaanites
    -------------------
    ["Canaan Marksman"]      = { Blunt=2, Acid=2, Sharp=0.5 },
    ["Canaan Lumberjack"]    = { Blunt=2, Acid=2 },
    ["Canaan Farmer"]        = { Blunt=2, Acid=2 },
    ["Chosen Canaan Farmer"] = { Blunt=2, Acid=2 },
    ["Chosen Canaan Miner"] = { Blunt=2, Acid=2 },
    ["Outcast"]              = { Blunt=2, Holy=2 },
    
    -------------------
    -- Shades
    -------------------
    ["LabRat Shade"]     = { Holy=4, Fire=2, Laser=2, Electricity=2, Psychic=2 },
    ["Grunt Shade"]      = { Holy=4, Fire=2, Laser=2, Electricity=2, Psychic=2 },
    ["Breacher Shade"]   = { Holy=4, Fire=2, Laser=2, Electricity=2, Psychic=2 },
    ["Peccary Shade"]    = { Holy=4, Fire=2, Laser=2, Electricity=2, Psychic=2 },
    ["Monk Shade"]       = { Holy=4, Fire=2, Laser=2, Electricity=2, Psychic=2 },
    ["Neophyte Shade"]   = { Holy=4, Fire=2, Laser=2, Electricity=2, Psychic=2 },

    -------------------
    -- Other
    -------------------
    ["Tarasque Summoner"] = { Explosive=0.5 },
    ["Tarasque Charger"] = { Explosive=0.5 },
    ["Tarasque Slammer"] = { Explosive=0.5 },


    -------------------
    -- Tamed pets
    -------------------
    ["Tamed Razor Pest"]    = { Sharp=0.5, Blunt=1.5, Explosive=0.5 },
    ["Tamed Chonky Pest"]   = { Sharp=1.5, Blunt=0.5, Explosive=0.5 },
    ["Tamed Laser Pest"]    = { Laser=0, Explosive=0.5 },
    ["Tamed Telepest"]      = { Blunt=0.5, Explosive=0.5 },
    ["Tamed Shield Pest"]   = { Explosive=0.5, Bullet=0.5 },
    ["Tamed Flurry Pest"]   = { Cold=0, Fire=2, Explosive=0.5 },

    ["Tamed Charge Peccary"]= { Electricity=0, Explosive=0.5 },
    ["Tamed Magma Peccary"] = { Fire=0, Holy=0, Explosive=0.05 },
    ["Tamed Hive Sow"]      = { Fire=2, Acid=0, Explosive=0.5 },
    
    ["Plasmogi"]    = { Fire=0, Explosive=0.5 },

}
