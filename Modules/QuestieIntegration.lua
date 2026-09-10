local addonName, ns = ...

local QuestieModule = {}
ns.QuestieModule = QuestieModule
ns:RegisterModule("QuestieIntegration", QuestieModule)

-- Internal module references
local QuestieDB
local QuestiePlayer
local DistanceUtils
local ZoneDB
local TrackerUtils
local QuestieMap

function QuestieModule:IsLoaded()
    return (_G.QuestieLoader ~= nil) or (_G.Questie ~= nil)
end

-- Safely ensure Questie submodules are imported, even if Questie initialized asynchronously
function QuestieModule:EnsureLoaded()
    if not self:IsLoaded() then return false end

    if _G.QuestieLoader and _G.QuestieLoader.ImportModule then
        pcall(function()
            QuestieDB = QuestieDB or QuestieLoader:ImportModule("QuestieDB")
            ZoneDB = ZoneDB or QuestieLoader:ImportModule("ZoneDB")
            DistanceUtils = DistanceUtils or QuestieLoader:ImportModule("DistanceUtils")
            TrackerUtils = TrackerUtils or QuestieLoader:ImportModule("TrackerUtils")
            QuestieMap = QuestieMap or QuestieLoader:ImportModule("QuestieMap")
            QuestiePlayer = QuestiePlayer or QuestieLoader:ImportModule("QuestiePlayer")
        end)
    end

    QuestieDB = QuestieDB or _G.QuestieDB
    ZoneDB = ZoneDB or _G.ZoneDB
    DistanceUtils = DistanceUtils or _G.DistanceUtils
    TrackerUtils = TrackerUtils or _G.TrackerUtils
    QuestieMap = QuestieMap or _G.QuestieMap
    QuestiePlayer = QuestiePlayer or _G.QuestiePlayer

    return (QuestieDB ~= nil)
end

function QuestieModule:Initialize()
    if not self:IsLoaded() then return end
    if ns.db and ns.db.integrations and not ns.db.integrations.questie then return end

    self:EnsureLoaded()
    ns.Print("Questie detected. Distance sorting and database hooks enabled.")
end

-- Safely retrieve Questie quest data object
function QuestieModule:GetQuestData(questId)
    if not questId then return nil end
    questId = tonumber(questId)
    if not questId then return nil end

    self:EnsureLoaded()

    if QuestieDB then
        if QuestieDB.GetQuest then
            local success, result = pcall(QuestieDB.GetQuest, questId)
            if success and result then return result end
            success, result = pcall(QuestieDB.GetQuest, QuestieDB, questId)
            if success and result then return result end
        end
        if QuestieDB.questData and QuestieDB.questData[questId] then
            return QuestieDB.questData[questId]
        end
    end

    return nil
end

-- Retrieve best coordinates for waypoint navigation (TomTom / Arrow)
function QuestieModule:GetQuestCoordinates(questId)
    if not questId then return nil end
    local quest = self:GetQuestData(questId)
    if not quest then return nil end

    self:EnsureLoaded()

    local spawn, zone, targetName

    -- 1. Use Questie's built-in DistanceUtils if available
    if DistanceUtils and DistanceUtils.GetNearestSpawnForQuest then
        local ok, s, z, n = pcall(DistanceUtils.GetNearestSpawnForQuest, quest)
        if ok and s and z then
            spawn = s
            zone = z
            targetName = n
        end
    end

    -- 2. If no spawn from DistanceUtils, check finisher if quest is ready for turn-in
    local isDone = false
    if type(quest.IsComplete) == "function" then
        local ok, res = pcall(quest.IsComplete, quest)
        if ok and (res == 1 or res == true) then isDone = true end
    elseif quest.IsComplete == 1 or quest.IsComplete == true or quest.isComplete == 1 or quest.isComplete == true then
        isDone = true
    end

    if (not spawn) and isDone and quest.Finisher then
        targetName = quest.Finisher.Name or (quest.Finisher.Type and quest.name)
        local fId = quest.Finisher.Id
        if fId and QuestieDB then
            local npcData = (QuestieDB.GetNPC and select(2, pcall(QuestieDB.GetNPC, fId)))
                or (QuestieDB.npcData and QuestieDB.npcData[fId])
            if npcData and npcData.spawns then
                for z, sList in pairs(npcData.spawns) do
                    if sList and #sList > 0 then
                        spawn = sList[1]
                        zone = z
                        break
                    end
                end
            end
            if not spawn then
                local objData = (QuestieDB.GetObject and select(2, pcall(QuestieDB.GetObject, fId)))
                    or (QuestieDB.objectData and QuestieDB.objectData[fId])
                if objData and objData.spawns then
                    for z, sList in pairs(objData.spawns) do
                        if sList and #sList > 0 then
                            spawn = sList[1]
                            zone = z
                            break
                        end
                    end
                end
            end
        end
    end

    -- 3. If in-progress, check uncompleted objectives
    if (not spawn) and quest.Objectives then
        for _, obj in pairs(quest.Objectives) do
            if not (obj.Completed or obj.completed) and obj.spawnList then
                if DistanceUtils and DistanceUtils.GetNearestObjective then
                    local ok, s, z, n = pcall(DistanceUtils.GetNearestObjective, obj.spawnList)
                    if ok and s and z then
                        spawn = s
                        zone = z
                        targetName = n or obj.Description or quest.name
                        break
                    end
                else
                    for _, spawnData in pairs(obj.spawnList) do
                        if spawnData.Spawns then
                            for z, sList in pairs(spawnData.Spawns) do
                                if sList and #sList > 0 then
                                    spawn = sList[1]
                                    zone = z
                                    targetName = obj.Description or quest.name
                                    break
                                end
                            end
                        end
                        if spawn then break end
                    end
                end
            end
            if spawn then break end
        end
    end

    -- 4. If still no spawn, check quest starter
    if (not spawn) and quest.Starts then
        if quest.Starts.NPC and QuestieDB then
            for _, npcId in ipairs(quest.Starts.NPC) do
                local npcData = (QuestieDB.GetNPC and select(2, pcall(QuestieDB.GetNPC, npcId))) or (QuestieDB.npcData and QuestieDB.npcData[npcId])
                if npcData and npcData.spawns then
                    for z, sList in pairs(npcData.spawns) do
                        if sList and #sList > 0 then
                            spawn = sList[1]
                            zone = z
                            targetName = npcData.name or quest.name
                            break
                        end
                    end
                end
                if spawn then break end
            end
        end
    end

    -- 5. Convert Questie zone (AreaID) to uiMapId and return
    if spawn and zone then
        local uiMapId = nil
        if ZoneDB and ZoneDB.GetUiMapIdByAreaId then
            local ok, res = pcall(ZoneDB.GetUiMapIdByAreaId, ZoneDB, zone)
            if ok and res then uiMapId = res end
            if not uiMapId then
                ok, res = pcall(ZoneDB.GetUiMapIdByAreaId, zone)
                if ok and res then uiMapId = res end
            end
        end
        if not uiMapId and C_Map and C_Map.GetBestMapForUnit then
            uiMapId = C_Map.GetBestMapForUnit("player")
        end

        local x = spawn[1]
        local y = spawn[2]
        return uiMapId, x, y, targetName or quest.name, zone
    end

    return nil
end

-- Place a TomTom waypoint for a given quest using Questie coordinates
function QuestieModule:SetTomTomWaypoint(questId, title)
    local mapID, x, y, targetName, zone = self:GetQuestCoordinates(questId)
    if not (x and y) then return false end

    local waypointTitle = targetName and string.format("%s: %s", title or "Quest", targetName) or (title or "Quest")

    -- 1. Try Questie's native TrackerUtils TomTom hook
    if zone and TrackerUtils and TrackerUtils.SetTomTomTarget then
        local ok = pcall(TrackerUtils.SetTomTomTarget, TrackerUtils, waypointTitle, zone, x, y)
        if ok then return true, waypointTitle end
    end

    -- 2. Direct TomTom API with converted uiMapId
    if _G.TomTom and _G.TomTom.AddWaypoint and mapID then
        local tx = (x > 1) and (x / 100) or x
        local ty = (y > 1) and (y / 100) or y
        local ok = pcall(_G.TomTom.AddWaypoint, _G.TomTom, mapID, tx, ty, {
            title = waypointTitle,
            persistent = false,
            minimap = true,
            world = true,
        })
        if ok then return true, waypointTitle end
    end

    return false
end

-- Calculate or retrieve distance to quest objectives / turn-in
function QuestieModule:GetQuestDistance(questId)
    if not questId then return 999999 end

    local quest = self:GetQuestData(questId)
    if not quest then return 999999 end

    -- Check if Questie already calculated distance
    if quest.distance and type(quest.distance) == "number" then
        return quest.distance
    end

    self:EnsureLoaded()

    -- Check if DistanceUtils can compute distance
    if DistanceUtils and DistanceUtils.GetNearestSpawnForQuest then
        local ok, spawn, zone, _, dist = pcall(DistanceUtils.GetNearestSpawnForQuest, quest)
        if ok and dist and type(dist) == "number" then
            return dist
        end
    end

    -- Fallback: calculate Euclidean distance to player coordinates
    local uiMapId, x, y = self:GetQuestCoordinates(questId)
    if uiMapId and x and y and C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition then
        local playerMap = C_Map.GetBestMapForUnit("player")
        if playerMap == uiMapId then
            local pos = C_Map.GetPlayerMapPosition(uiMapId, "player")
            if pos then
                local px, py = pos:GetXY()
                if px and py then
                    local dx = px - (x / 100)
                    local dy = py - (y / 100)
                    return math.sqrt(dx * dx + dy * dy)
                end
            end
        end
    end

    return 999999
end

-- Retrieve quest giver or turn-in NPC name
function QuestieModule:GetQuestFinisherName(questId)
    local quest = self:GetQuestData(questId)
    if not quest or not quest.Finisher then return nil end

    if quest.Finisher.Type == "monster" and quest.Finisher.Name then
        return quest.Finisher.Name
    end
    return nil
end

-- Helper to scan inventory bags for a specific item ID
local function FindItemInBags(targetItemId)
    if not targetItemId or targetItemId <= 0 then return nil end

    local numBags = NUM_BAG_SLOTS or 4
    for bag = 0, numBags do
        local numSlots = 0
        if C_Container and C_Container.GetContainerNumSlots then
            numSlots = C_Container.GetContainerNumSlots(bag) or 0
        elseif _G.GetContainerNumSlots then
            numSlots = _G.GetContainerNumSlots(bag) or 0
        end

        for slot = 1, numSlots do
            local itemID, hyperlink, icon, stackCount
            if C_Container and C_Container.GetContainerItemInfo then
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if info then
                    itemID = info.itemID
                    hyperlink = info.hyperlink
                    icon = info.iconFileID
                    stackCount = info.stackCount
                end
            elseif _G.GetContainerItemInfo then
                local itemTexture, count, _, _, _, _, link, _, _, id = _G.GetContainerItemInfo(bag, slot)
                itemID = id
                hyperlink = link
                icon = itemTexture
                stackCount = count
            end

            if itemID and itemID == targetItemId then
                return hyperlink, icon, stackCount
            end
        end
    end
    return nil
end
QuestieModule.FindItemInBags = FindItemInBags

-- Retrieve quest item information (hyperlink, icon, stackCount) via Questie source item & bag scan
function QuestieModule:GetQuestItemInfo(questId)
    if not self:IsLoaded() or not questId then return nil end

    local quest = self:GetQuestData(questId)
    if not quest then return nil end

    -- 1. Check direct sourceItemId
    if quest.sourceItemId and type(quest.sourceItemId) == "number" and quest.sourceItemId > 0 then
        local link, icon, count = FindItemInBags(quest.sourceItemId)
        if link and icon then
            return link, icon, count
        end
    end

    -- 2. Check requiredSourceItems list
    if quest.requiredSourceItems and type(quest.requiredSourceItems) == "table" then
        for _, itemId in ipairs(quest.requiredSourceItems) do
            if type(itemId) == "number" and itemId > 0 then
                local link, icon, count = FindItemInBags(itemId)
                if link and icon then
                    return link, icon, count
                end
            end
        end
    end

    return nil
end
