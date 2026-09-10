local addonName, ns = ...

-- Addon metadata & global access
ns.addonName = addonName
ns.title = "|cff00c0ffBleakfiber's Quest Tracker|r"
ns.version = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(addonName, "Version")) 
    or (GetAddOnMetadata and GetAddOnMetadata(addonName, "Version")) 
    or "0.0.1"

-- Print helper with colored prefix
function ns.Print(...)
    print("|cff00c0ff[" .. addonName .. "]|r", ...)
end

-- Default Settings
ns.defaultDB = {
    profile = {
        -- Positioning & Sizing
        point = "TOPRIGHT",
        relativePoint = "TOPRIGHT",
        xOfs = -250,
        yOfs = -200,
        width = 280,
        maxHeight = 600,
        scale = 1.0,
        isLocked = false,
        collapsedQuests = {},     -- [questID or title] = true when user collapsed the quest
        collapsedZones = {},      -- [zoneName] = true when user collapsed a zone header

        -- Headers Configuration
        headers = {
            -- Main Tracker Header Bar
            texture = "flat",              -- "none", "flat", "gradient", "blizzard"
            textureColor = { r = 0.05, g = 0.08, b = 0.12, a = 0.85 },
            textureColorShare = false,     -- Share color with tracker border
            textColor = { r = 0.0, g = 0.75, b = 1.0 },
            textColorShare = false,        -- Share text color with tracker border
            buttonColor = { r = 0.0, g = 0.75, b = 1.0 },
            buttonColorShare = false,      -- Share button color with tracker border
            countFormat = "short",         -- "none", "short" ((5/20)), "full" ((5/20 Quests))
            collapsedText = "counter",     -- "none", "counter", "title"
            showQuestLogBtn = true,        -- [Log] button that toggles QuestLogFrame
            showZoneBtn = true,            -- [Zone] filter toggle button
            showAllBtn = true,             -- [All] filter toggle button
            showMenuBtn = true,            -- [...] options menu button
            showCollapseBtn = true,        -- [-] collapse button

            -- Zone / Section Headers in Tracker
            showZoneHeaders = true,        -- Group quests under collapsible Zone headers
            showZoneCount = true,          -- Show count e.g. Durotar (3)
            zoneHeaderTexture = "gradient", -- "none", "flat", "gradient", "blizzard"
            zoneHeaderColor = { r = 1.0, g = 0.82, b = 0.0, a = 1.0 }, -- Classic gold
            zoneHeaderColorShare = false,  -- Share with border color
        },

        -- Appearance & Backdrop
        backdrop = {
            show = true,
            bgFile = "Solid", -- Default or SharedMedia
            edgeFile = "Solid",
            edgeSize = 1,
            bgColor = { r = 0.05, g = 0.05, b = 0.05, a = 0.65 },
            borderColor = { r = 0.15, g = 0.15, b = 0.15, a = 0.9 },
            padding = 8,
        },

        -- Typography
        fonts = {
            font = "Friz Quadrata TT",
            headerFont = "Friz Quadrata TT",
            headerSize = 13,
            headerOutline = "OUTLINE",
            objectiveFont = "Friz Quadrata TT",
            objectiveSize = 11,
            objectiveOutline = "NONE",
            colorDifficulty = true,
        },

        -- Filtering & Behavior
        filtering = {
            filterMode = "all", -- "all", "zone", "watched"
            zoneOnly = false,
            autoHideInInstances = false,
            autoHideEmpty = true,
            collapseInCombat = false,
        },

        -- Sorting
        sorting = {
            mode = "distance", -- "distance", "level", "zone"
            moveCompletedToBottom = false, -- Push "Ready for turn-in" quests to bottom of tracker
            showGroupTags = true,          -- Show [11+] elite/group and dungeon badges
        },

        -- Integrations
        integrations = {
            elvui = true,
            questie = true,
        },

        -- Social & Quest Automation
        social = {
            autoShare = false,           -- Auto-share quests to party upon accept
            autoAcceptNPC = false,       -- Auto-accept quests from NPCs
            autoAcceptShared = false,    -- Auto-accept quests shared by party members
            autoTurnIn = false,          -- Auto-turnin quests with 0 or 1 reward choice
            shiftBypass = true,          -- Hold Shift to temporarily bypass automation
            enablePartySync = false,     -- Party quest progress sync and click-to-share
            announceToParty = false,     -- Announce objective/quest completion to party chat
        },

        -- Audio & Sounds
        sound = {
            enableCompleteSound = false, -- Play sound on quest/objective complete
            soundChoice = "peon",        -- "peon", "quest_complete", "raid_warning", "level_up"
        },
    },
}

-- Recursive table copy for defaults merging
local function CopyDefaults(src, dest)
    if type(src) ~= "table" then return {} end
    if type(dest) ~= "table" then dest = {} end
    for k, v in pairs(src) do
        if type(v) == "table" then
            dest[k] = CopyDefaults(v, dest[k])
        elseif dest[k] == nil then
            dest[k] = v
        end
    end
    return dest
end
ns.CopyDefaults = CopyDefaults

-- Simple internal event/callback bus
ns.callbacks = {}

function ns:RegisterCallback(event, func)
    if not self.callbacks[event] then
        self.callbacks[event] = {}
    end
    table.insert(self.callbacks[event], func)
end

function ns:FireCallback(event, ...)
    if self.callbacks[event] then
        for _, func in ipairs(self.callbacks[event]) do
            func(...)
        end
    end
end

-- Module Management System
ns.modules = {}

function ns:RegisterModule(name, moduleTable)
    if not name or type(moduleTable) ~= "table" then return end
    self.modules[name] = moduleTable
    moduleTable.name = name
end

function ns:GetModule(name)
    return self.modules[name]
end

function ns:InitializeModules()
    for name, mod in pairs(self.modules) do
        if type(mod.Initialize) == "function" then
            local success, err = pcall(mod.Initialize, mod)
            if not success then
                print("|cffff3333[" .. addonName .. " Error]|r Failed to initialize module '" .. name .. "': " .. tostring(err))
            end
        end
    end
end

-- Main Event Engine Frame
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

eventFrame:SetScript("OnEvent", function(self, event, arg1, ...)
    if event == "ADDON_LOADED" and arg1 == addonName then
        -- Initialize or update SavedVariables
        if not BleakfiberTrackerDB then
            BleakfiberTrackerDB = {}
        end
        BleakfiberTrackerDB = CopyDefaults(ns.defaultDB, BleakfiberTrackerDB)
        ns.db = BleakfiberTrackerDB.profile
        if not ns.db.collapsedQuests then
            ns.db.collapsedQuests = {}
        end

        self:UnregisterEvent("ADDON_LOADED")

    elseif event == "PLAYER_LOGIN" then
        -- Initialize Tracker container frame before modules hook into it
        if ns.Tracker and ns.Tracker.Initialize then
            ns.Tracker:Initialize()
        end

        -- Initialize registered modules
        ns:InitializeModules()
        ns:FireCallback("ON_INITIALIZE")

    elseif event == "PLAYER_ENTERING_WORLD" then
        ns:FireCallback("PLAYER_ENTERING_WORLD", ...)
    end
end)

