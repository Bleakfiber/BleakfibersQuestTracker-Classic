local addonName, ns = ...

local SocialModule = {}
ns.SocialModule = SocialModule
ns:RegisterModule("SocialModule", SocialModule)

-- Sound effect presets with direct CASC FileDataIDs and SoundKit IDs
local SOUND_PRESETS = {
    peon = { type = "file", id = 558132 },           -- Peon: "Work complete!"
    quest_complete = { type = "file", id = 567400 }, -- Classic Quest Complete Chime
    level_up = { type = "kit", id = 888 },           -- Level Up Fanfare
    raid_warning = { type = "kit", id = 8959 },      -- Raid Warning Chime
    ready_check = { type = "kit", id = 8960 },       -- Ready Check Chime
    map_ping = { type = "kit", id = 3175 },          -- Mini-Map Ping
    pvp_horn = { type = "kit", id = 8456 },          -- PvP Queue Horn
}

function SocialModule:PlaySoundKey(choice)
    local entry = SOUND_PRESETS[choice] or SOUND_PRESETS.peon
    if entry.type == "file" then
        PlaySoundFile(entry.id, "Master")
    elseif entry.type == "kit" then
        PlaySound(entry.id, "Master")
    end
end

function SocialModule:PlayPreviewSound(choice)
    self:PlaySoundKey(choice or (ns.db and ns.db.sound and ns.db.sound.soundChoice) or "peon")
end

-- Helper: Check if automation is currently bypassed by holding Shift
local function IsBypassed()
    local db = ns.db and ns.db.social
    if db and db.shiftBypass and IsShiftKeyDown() then
        return true
    end
    return false
end

-- Helper: Determine if current quest offer is from an NPC vs shared by a party member
local function IsNPCOffer()
    if UnitExists("npc") then return true end
    if UnitExists("target") and not UnitIsPlayer("target") then return true end
    return false
end

-- Track quest and objective completion states so sounds ONLY play on actual completion
local completedQuestsCache = {}
local completedObjectivesCache = {}
local isSoundSystemInitialized = false
local lastSoundPlayTime = 0

function SocialModule:PlayCompletionSound()
    local now = GetTime()
    if (now - lastSoundPlayTime) < 0.5 then return end
    lastSoundPlayTime = now

    local db = ns.db and ns.db.sound
    if not (db and db.enableCompleteSound) then return end
    self:PlaySoundKey(db.soundChoice or "peon")
end

local function AnnouncePartyMessage(msg)
    local db = ns.db and ns.db.social
    if not (db and db.announceToParty) then return end
    if not (IsInGroup() or (GetNumGroupMembers and GetNumGroupMembers() > 0)) then return end

    local chatType = "PARTY"
    if IsInRaid and IsInRaid() then
        chatType = "RAID"
    elseif IsInGroup and LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        chatType = "INSTANCE_CHAT"
    end
    if SendChatMessage then
        SendChatMessage(msg, chatType)
    end
end

local function CheckForCompletions()
    local numEntries = (GetNumQuestLogEntries and select(1, GetNumQuestLogEntries())) or 0
    local shouldPlay = false

    for i = 1, numEntries do
        local title, _, _, isHeader, _, isComplete, _, questID = GetQuestLogTitle(i)
        if not isHeader and questID then
            -- 1. Full Quest Completion (ready for turn-in)
            local wasQuestComplete = completedQuestsCache[questID]
            if isComplete then
                if wasQuestComplete == false and isSoundSystemInitialized then
                    shouldPlay = true
                    AnnouncePartyMessage(string.format("[BFQ] Quest Complete: %s", title or "Quest"))
                end
                completedQuestsCache[questID] = true
            else
                completedQuestsCache[questID] = false
            end

            -- 2. Individual Objective Completion (finished == true)
            local numLeaderBoards = (GetNumQuestLeaderBoards and GetNumQuestLeaderBoards(i)) or 0
            for j = 1, numLeaderBoards do
                local text, objType, finished = GetQuestLogLeaderBoard(j, i)
                local key = questID .. "_" .. j
                local wasObjFinished = completedObjectivesCache[key]
                if finished then
                    if wasObjFinished == false and isSoundSystemInitialized then
                        shouldPlay = true
                        AnnouncePartyMessage(string.format("[BFQ] Completed: %s", text or "Objective"))
                    end
                    completedObjectivesCache[key] = true
                else
                    completedObjectivesCache[key] = false
                end
            end
        end
    end

    if not isSoundSystemInitialized then
        isSoundSystemInitialized = true
        return
    end

    if shouldPlay then
        SocialModule:PlayCompletionSound()
    end
end

--------------------------------------------------------------------------------
-- PARTY QUEST PROGRESS SYNC & CLICK-TO-SHARE ENGINE
--------------------------------------------------------------------------------
ns.partyQuestData = {}

-- Register hidden addon communications channel
if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix("BFQ_SYNC")
elseif RegisterAddonMessagePrefix then
    RegisterAddonMessagePrefix("BFQ_SYNC")
end

local function SendSync(msg)
    if not (IsInGroup() or (GetNumGroupMembers and GetNumGroupMembers() > 0)) then return end
    local channel = IsInRaid and IsInRaid() and "RAID" or "PARTY"
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage("BFQ_SYNC", msg, channel)
    elseif SendAddonMessage then
        SendAddonMessage("BFQ_SYNC", msg, channel)
    end
end

-- Broadcast current character's quest progress to the party
function SocialModule:BroadcastMyQuests()
    local db = ns.db and ns.db.social
    if not (db and db.enablePartySync) then return end
    if not (IsInGroup() or (GetNumGroupMembers and GetNumGroupMembers() > 0)) then return end

    local numEntries = (GetNumQuestLogEntries and select(1, GetNumQuestLogEntries())) or 0
    for i = 1, numEntries do
        local title, _, _, isHeader, _, isComplete, _, questID = GetQuestLogTitle(i)
        if not isHeader and questID then
            -- Tell party: I have this quest
            SendSync("H:" .. questID)

            -- Broadcast each objective progress
            local numLeaderBoards = (GetNumQuestLeaderBoards and GetNumQuestLeaderBoards(i)) or 0
            for j = 1, numLeaderBoards do
                local text, objType, finished = GetQuestLogLeaderBoard(j, i)
                if text then
                    local cur, maxVal = text:match("(%d+)%s*/%s*(%d+)")
                    if not cur or not maxVal then
                        cur = finished and 1 or 0
                        maxVal = 1
                    end
                    SendSync(string.format("P:%d:%d:%s:%s:%d", questID, j, cur, maxVal, finished and 1 or 0))
                end
            end
        end
    end
end

-- Share a specific quest with party members
function SocialModule:ShareQuest(questID, questLogIndex)
    if not (IsInGroup() or (GetNumGroupMembers and GetNumGroupMembers() > 0)) then
        ns.Print("You are not in a group.")
        return false
    end

    if questID and C_QuestLog and C_QuestLog.IsPushableQuest and C_QuestLog.IsPushableQuest(questID) then
        C_QuestLog.PushQuestToParty(questID)
        ns.Print("Shared quest with party.")
        return true
    elseif questLogIndex and GetQuestLogPushable and SelectQuestLogEntry and QuestLogPushQuest then
        SelectQuestLogEntry(questLogIndex)
        if GetQuestLogPushable() then
            QuestLogPushQuest()
            ns.Print("Shared quest with party.")
            return true
        end
    end

    ns.Print("This quest cannot be shared.")
    return false
end

-- Retrieve party progress formatted summary for an objective
function SocialModule:GetObjectivePartyProgress(questID, objIndex)
    local qData = ns.partyQuestData and ns.partyQuestData[questID]
    local oData = qData and qData.objectives and qData.objectives[objIndex]
    if not oData then return nil end

    local entries = {}
    local allDone = true
    local count = 0

    for name, prog in pairs(oData) do
        count = count + 1
        if prog.finished then
            table.insert(entries, string.format("|cff00ff00%s (%d/%d)|r", name, prog.max, prog.max))
        else
            allDone = false
            table.insert(entries, string.format("|cff99ccff%s|r (|cffffffff%d/%d|r)", name, prog.current, prog.max))
        end
    end

    if count == 0 then return nil end

    if allDone and count > 0 then
        return "|cff00ff00All Party Complete!|r"
    end

    return table.concat(entries, ", ")
end

-- Check if party members are missing this quest and if it can be shared
function SocialModule:GetMissingPartyInfo(questID, questLogIndex)
    if not (IsInGroup() or (GetNumGroupMembers and GetNumGroupMembers() > 0)) then
        return 0, false
    end

    local isPushable = false
    if questID and C_QuestLog and C_QuestLog.IsPushableQuest then
        isPushable = C_QuestLog.IsPushableQuest(questID)
    elseif questLogIndex and GetQuestLogPushable and SelectQuestLogEntry then
        SelectQuestLogEntry(questLogIndex)
        isPushable = GetQuestLogPushable()
    end
    if not isPushable then
        return 0, false
    end

    local numMembers = GetNumGroupMembers() or 0
    if numMembers <= 1 then return 0, false end

    local haveData = (ns.partyQuestData[questID] and ns.partyQuestData[questID].have) or {}
    local missingCount = 0

    for i = 1, (numMembers - 1) do
        local unit = "party" .. i
        local name = UnitName(unit)
        if name and not haveData[name] then
            missingCount = missingCount + 1
        end
    end

    return missingCount, isPushable
end

--------------------------------------------------------------------------------
-- EVENT INITIALIZATION
--------------------------------------------------------------------------------
function SocialModule:Initialize()
    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("QUEST_ACCEPTED")
    eventFrame:RegisterEvent("QUEST_DETAIL")
    eventFrame:RegisterEvent("QUEST_ACCEPT_CONFIRM")
    eventFrame:RegisterEvent("QUEST_PROGRESS")
    eventFrame:RegisterEvent("QUEST_COMPLETE")
    eventFrame:RegisterEvent("GOSSIP_SHOW")
    eventFrame:RegisterEvent("QUEST_GREETING")
    eventFrame:RegisterEvent("QUEST_WATCH_UPDATE")
    eventFrame:RegisterEvent("QUEST_LOG_UPDATE")
    eventFrame:RegisterEvent("QUEST_REMOVED")
    eventFrame:RegisterEvent("CHAT_MSG_ADDON")
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    eventFrame:RegisterEvent("GROUP_LEFT")

    local lastSharedQuestID = nil
    local lastSharedTime = 0
    local lastBroadcastTime = 0

    eventFrame:SetScript("OnEvent", function(self, event, arg1, arg2, arg3, arg4, ...)
        local db = ns.db and ns.db.social
        if not db then return end

        -- 1. Auto-Share Quests upon accepting when in a party
        if event == "QUEST_ACCEPTED" then
            local questLogIndex, questID = arg1, arg2
            if not questID and type(questLogIndex) == "number" and C_QuestLog and C_QuestLog.GetQuestIDForLogIndex then
                questID = C_QuestLog.GetQuestIDForLogIndex(questLogIndex)
            end

            if db.autoShare and (IsInGroup() or (GetNumGroupMembers and GetNumGroupMembers() > 0)) then
                local now = GetTime()
                if questID and (questID ~= lastSharedQuestID or (now - lastSharedTime) > 2) then
                    lastSharedQuestID = questID
                    lastSharedTime = now

                    C_Timer.After(0.3, function()
                        SocialModule:ShareQuest(questID, questLogIndex)
                    end)
                end
            end

            -- Update quest completion and party broadcast
            C_Timer.After(0.5, function()
                CheckForCompletions()
                SocialModule:BroadcastMyQuests()
            end)

        -- 2. Auto-Accept Quests (Split: NPC quests and Shared party quests)
        elseif event == "QUEST_DETAIL" then
            if IsBypassed() then return end

            local isNPC = IsNPCOffer()
            if isNPC and db.autoAcceptNPC then
                AcceptQuest()
            elseif (not isNPC) and db.autoAcceptShared then
                AcceptQuest()
            end

        elseif event == "QUEST_ACCEPT_CONFIRM" then
            if IsBypassed() then return end
            if db.autoAcceptNPC or db.autoAcceptShared then
                ConfirmAcceptQuest()
            end

        -- 3. Auto-Progress / Gossip Dialogs
        elseif event == "GOSSIP_SHOW" then
            if IsBypassed() then return end

            -- Prioritize turning in active complete quests first
            if db.autoTurnIn and C_GossipInfo and C_GossipInfo.GetActiveQuests then
                local active = C_GossipInfo.GetActiveQuests()
                if active then
                    for _, q in ipairs(active) do
                        if q.isComplete then
                            C_GossipInfo.SelectActiveQuest(q.questID)
                            return
                        end
                    end
                end
            end

            -- Auto-accept available quest if only 1 is available
            if db.autoAcceptNPC and C_GossipInfo and C_GossipInfo.GetAvailableQuests then
                local available = C_GossipInfo.GetAvailableQuests()
                if available and #available == 1 then
                    C_GossipInfo.SelectAvailableQuest(available[1].questID)
                end
            end

        elseif event == "QUEST_GREETING" then
            if IsBypassed() then return end

            -- Auto turn-in complete active quests
            if db.autoTurnIn and GetNumActiveQuests then
                local numActive = GetNumActiveQuests() or 0
                for i = 1, numActive do
                    local _, isComplete = GetActiveTitle(i)
                    if isComplete then
                        SelectActiveQuest(i)
                        return
                    end
                end
            end

            -- Auto-select available quest if only 1 is offered
            if db.autoAcceptNPC and GetNumAvailableQuests then
                local numAvailable = GetNumAvailableQuests() or 0
                if numAvailable == 1 then
                    SelectAvailableQuest(1)
                end
            end

        -- 4. Auto Turn-In (Only for quests with 1 or less reward choice)
        elseif event == "QUEST_PROGRESS" then
            if IsBypassed() then return end
            if db.autoTurnIn and IsQuestCompletable and IsQuestCompletable() then
                CompleteQuest()
            end

        elseif event == "QUEST_COMPLETE" then
            if IsBypassed() then return end
            if db.autoTurnIn then
                local numChoices = (GetNumQuestChoices and GetNumQuestChoices()) or 0
                if numChoices <= 1 then
                    -- 0 or 1 choice: automatically claim reward
                    GetQuestReward(numChoices == 1 and 1 or 0)
                end
                -- If numChoices > 1: pause so player can pick their gear upgrade!
            end

        -- 5. Completion Sound Alerts & Party Sync Broadcast
        elseif event == "QUEST_WATCH_UPDATE" or event == "QUEST_LOG_UPDATE" then
            CheckForCompletions()

            local now = GetTime()
            if (now - lastBroadcastTime) > 1.5 then
                lastBroadcastTime = now
                SocialModule:BroadcastMyQuests()
            end

        elseif event == "QUEST_REMOVED" then
            if arg1 then
                completedQuestsCache[arg1] = nil
                if ns.partyQuestData then
                    ns.partyQuestData[arg1] = nil
                end
            end

        -- 6. Addon Message Communications (Party Quest Sync)
        elseif event == "CHAT_MSG_ADDON" then
            local prefix, msg, channel, sender = arg1, arg2, arg3, arg4
            if prefix == "BFQ_SYNC" and msg and sender then
                local senderName = sender:match("^([^-]+)") or sender
                local playerName = UnitName("player")
                if senderName ~= playerName then
                    if msg:sub(1, 2) == "P:" then
                        -- Format: P:questID:objIndex:cur:max:finished
                        local qID, oIdx, cur, mx, fin = msg:sub(3):match("^(%d+):(%d+):(%d+):(%d+):(%d+)")
                        qID, oIdx = tonumber(qID), tonumber(oIdx)
                        if qID and oIdx then
                            ns.partyQuestData[qID] = ns.partyQuestData[qID] or { objectives = {}, have = {} }
                            ns.partyQuestData[qID].have[senderName] = true
                            ns.partyQuestData[qID].objectives[oIdx] = ns.partyQuestData[qID].objectives[oIdx] or {}
                            ns.partyQuestData[qID].objectives[oIdx][senderName] = {
                                current = tonumber(cur) or 0,
                                max = tonumber(mx) or 1,
                                finished = (fin == "1"),
                            }
                            if ns.StandaloneTracker and ns.StandaloneTracker.UpdateTracker then
                                ns.StandaloneTracker:UpdateTracker()
                            end
                        end
                    elseif msg:sub(1, 2) == "H:" then
                        -- Format: H:questID
                        local qID = tonumber(msg:sub(3))
                        if qID then
                            ns.partyQuestData[qID] = ns.partyQuestData[qID] or { objectives = {}, have = {} }
                            ns.partyQuestData[qID].have[senderName] = true
                            if ns.StandaloneTracker and ns.StandaloneTracker.UpdateTracker then
                                ns.StandaloneTracker:UpdateTracker()
                            end
                        end
                    elseif msg == "REQ" then
                        SocialModule:BroadcastMyQuests()
                    end
                end
            end

        -- 7. Group Roster Changes
        elseif event == "GROUP_ROSTER_UPDATE" then
            if IsInGroup() or (GetNumGroupMembers and GetNumGroupMembers() > 0) then
                SendSync("REQ")
                SocialModule:BroadcastMyQuests()
            else
                ns.partyQuestData = {}
            end
            if ns.StandaloneTracker and ns.StandaloneTracker.UpdateTracker then
                ns.StandaloneTracker:UpdateTracker()
            end

        elseif event == "GROUP_LEFT" then
            ns.partyQuestData = {}
            if ns.StandaloneTracker and ns.StandaloneTracker.UpdateTracker then
                ns.StandaloneTracker:UpdateTracker()
            end
        end
    end)

    -- Initial silent population of quest cache
    C_Timer.After(1, function()
        CheckForCompletions()
        if IsInGroup() or (GetNumGroupMembers and GetNumGroupMembers() > 0) then
            SendSync("REQ")
            SocialModule:BroadcastMyQuests()
        end
    end)
end
