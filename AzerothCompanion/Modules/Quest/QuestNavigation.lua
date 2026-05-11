--[[
  quest 模块任务视图私有实现。
]]

local Internal = AzerothCompanion.Modules.Quest.Internal -- quest 模块内部命名空间
local Runtime = Internal.Runtime
local CreateFrame = Internal.CreateFrame

local function isQuestlineTreeEnabled()
  return Internal.IsQuestlineTreeEnabled()
end

local function normalizeSelectionID(value)
  if type(value) == "number" and value > 0 then
    return value
  end
  return nil
end

local QuestlineTreeView = {
  tabButton = nil,
  panelFrame = nil,
  headerFrame = nil,
  leftTree = nil,
  rightContent = nil,
  modeTabButtonByKey = {},
  scrollFrame = nil,
  scrollChild = nil,
  emptyText = nil,
  rowButtons = {},
  rightScrollFrame = nil,
  rightScrollChild = nil,
  rightRowButtons = {},
  rightTitle = nil,
  activeLogCurrentPanel = nil,
  activeLogCurrentTitle = nil,
  activeLogCurrentScrollFrame = nil,
  activeLogCurrentScrollChild = nil,
  activeLogCurrentRowButtons = {},
  activeLogRecentPanel = nil,
  activeLogRecentTitle = nil,
  activeLogRecentScrollFrame = nil,
  activeLogRecentScrollChild = nil,
  activeLogRecentRowButtons = {},
  activeLogRecentToggleButton = nil,
  activeLogRecentCollapsed = false,
  rowHeight = 21,
  selected = false,
  selectedExpansionID = nil,
  selectedCampaignID = nil,
  selectedAchievementID = nil,
  selectedModeKey = "active_log",
  selectedMapID = nil,
  selectedTypeKey = "",
  searchText = "",
  expandedQuestLineID = nil,
  directQuestLineCollapsed = false,
  selectedQuestID = nil,
  hostJournalFrame = nil,
  hookedNativeTabs = setmetatable({}, {__mode = "k"}),
  wasShowingPanel = false,
  activeRootState = "native",
  nativeTabBeforeQuest = nil,
  pendingNativeSelection = false,
  renderScheduled = false,
  renderTimerHandle = nil,
  selectionLoaded = false,
}

local VIEW_STYLE = {
  leftPanelWidth = 244,
  leftRowGap = 2,
  rightRowGap = 2,
  expansionExtraHeight = 2,
  headerHeight = 34,
  headerGap = 0,
  headerHostLeftInset = 58,
  headerHostRightInset = 34,
  headerTopOffset = 26,
  searchBoxWidth = 184,
  modeTabHeight = 22,
  modeTabGap = 8,
  activeLogPanelGap = 8,
  activeLogRecentRatio = 0.25,
}

local function getQuestlineCollapsedTable()
  local collapseState = Internal.GetCharacterSetting("QUESTLINE_TREE_COLLAPSED") -- 左树折叠状态
  if type(collapseState) ~= "table" then
    collapseState = {}
    Internal.SetCharacterSetting("QUESTLINE_TREE_COLLAPSED", collapseState)
  end
  return collapseState
end

local RECENT_COMPLETED_MIN = 1 -- 最近完成最小保留条数
local RECENT_COMPLETED_MAX = 30 -- 最近完成最大保留条数
local RECENT_COMPLETED_DEFAULT = 10 -- 最近完成默认保留条数
local HIDDEN_QUEST_TYPE_ID_SET = { -- 任务界面隐藏的任务类型集合
  [265] = true, -- 界面规则：隐藏任务类型 265
  [291] = true, -- 界面规则：隐藏任务类型 291
}

local function shouldDisplayQuestByTypeID(typeID)
  if type(typeID) ~= "number" then
    return false
  end
  return HIDDEN_QUEST_TYPE_ID_SET[typeID] ~= true
end

local function resolveQuestTypeIDForFilter(questID, fallbackTypeID, detailContext)
  if type(fallbackTypeID) == "number" then
    return fallbackTypeID
  end
  if type(questID) ~= "number"
    or type(AzerothCompanion.API.Questlines) ~= "table"
    or type(AzerothCompanion.API.Questlines.GetQuestDetailByID) ~= "function"
  then
    return nil
  end
  local detailObject, detailError = AzerothCompanion.API.Questlines.GetQuestDetailByID(questID, detailContext) -- 任务详情（兜底类型读取）
  if detailError or type(detailObject) ~= "table" then
    return nil
  end
  return type(detailObject.typeID) == "number" and detailObject.typeID or nil
end

local function normalizeRecentCompletedMaxValue(rawValue)
  if type(rawValue) ~= "number" then
    return RECENT_COMPLETED_DEFAULT
  end
  local normalizedValue = math.floor(rawValue) -- 归一化后的条数
  if normalizedValue < RECENT_COMPLETED_MIN then
    return RECENT_COMPLETED_MIN
  end
  if normalizedValue > RECENT_COMPLETED_MAX then
    return RECENT_COMPLETED_MAX
  end
  return normalizedValue
end

local function getRecentCompletedQuestMaxValue()
  local storedMaxValue = Internal.GetAccountSetting("QUEST_RECENT_COMPLETED_MAX") -- 最近完成保留条数
  local normalizedMaxValue = normalizeRecentCompletedMaxValue(storedMaxValue) -- 归一化后的保留条数
  if storedMaxValue ~= normalizedMaxValue then
    Internal.SetAccountSetting("QUEST_RECENT_COMPLETED_MAX", normalizedMaxValue)
  end
  return normalizedMaxValue
end

local function getRecentCompletedQuestList()
  local recentCompletedList = Internal.GetCharacterSetting("QUEST_RECENT_COMPLETED_LIST") -- 最近完成任务列表
  if type(recentCompletedList) ~= "table" then
    recentCompletedList = {}
    Internal.SetCharacterSetting("QUEST_RECENT_COMPLETED_LIST", recentCompletedList)
  end
  return recentCompletedList
end

local QUEST_ROOT_TAB_ID = 203 -- 任务根页签 ID（自定义）
local DUNGEON_ROOT_TAB_ID = 4 -- 地下城根页签 ID
local RAID_ROOT_TAB_ID = 5 -- 团队副本根页签 ID

local buildDefaultRootTabOrderIds -- 默认根页签顺序构建函数（前向声明）

local function buildEffectiveRootTabOrderIds()
  local defaultOrderIds = buildDefaultRootTabOrderIds and buildDefaultRootTabOrderIds() or {} -- 运行时默认顺序（ID）
  local effectiveOrderIds = {} -- 生效顺序结果（ID）
  local addedTabIdSet = {} -- 去重记录

  for _, defaultTabId in ipairs(defaultOrderIds) do
    if not addedTabIdSet[defaultTabId] then
      effectiveOrderIds[#effectiveOrderIds + 1] = defaultTabId
      addedTabIdSet[defaultTabId] = true
    end
  end

  if not addedTabIdSet[QUEST_ROOT_TAB_ID] then
    effectiveOrderIds[#effectiveOrderIds + 1] = QUEST_ROOT_TAB_ID
    addedTabIdSet[QUEST_ROOT_TAB_ID] = true
  end

  return effectiveOrderIds
end

local function ensureEncounterJournalAddonLoaded()
  -- 独立 quest 模块只依赖自身宿主 Frame，不主动拉起冒险手册插件。
  return _G.AzerothCompanionQuestFrame ~= nil
end

local function isStandaloneQuestHost(hostFrame)
  return hostFrame ~= nil and hostFrame == _G.AzerothCompanionQuestFrame
end

buildDefaultRootTabOrderIds = function()
  ensureEncounterJournalAddonLoaded()

  local defaultOrderIds = {} -- 默认顺序（按 ID）
  local addedTabIdSet = {} -- 已纳入默认顺序的页签 ID 集合
  local journalFrame = _G.AzerothCompanionQuestFrame -- quest 模块根面板
  local nativeTabs = journalFrame and journalFrame.Tabs -- 原生根页签数组

  local function appendTabId(rootTabId)
    if type(rootTabId) ~= "number" or rootTabId <= 0 then
      return
    end
    if rootTabId == QUEST_ROOT_TAB_ID or addedTabIdSet[rootTabId] then
      return
    end
    defaultOrderIds[#defaultOrderIds + 1] = rootTabId
    addedTabIdSet[rootTabId] = true
  end

  if type(nativeTabs) == "table" then
    for _, rootTabButton in ipairs(nativeTabs) do
      if rootTabButton and rootTabButton.GetID then
        appendTabId(rootTabButton:GetID())
      end
    end
  end

  if #defaultOrderIds == 0 then
    return { QUEST_ROOT_TAB_ID }
  end

  local questInsertAfterIndex = nil -- 任务页签插入基准索引
  for orderIndex, rootTabId in ipairs(defaultOrderIds) do
    if rootTabId == RAID_ROOT_TAB_ID then
      questInsertAfterIndex = orderIndex
      break
    end
  end
  if type(questInsertAfterIndex) ~= "number" then
    for orderIndex, rootTabId in ipairs(defaultOrderIds) do
      if rootTabId == DUNGEON_ROOT_TAB_ID then
        questInsertAfterIndex = orderIndex
        break
      end
    end
  end

  if type(questInsertAfterIndex) == "number" then
    table.insert(defaultOrderIds, questInsertAfterIndex + 1, QUEST_ROOT_TAB_ID)
  else
    defaultOrderIds[#defaultOrderIds + 1] = QUEST_ROOT_TAB_ID
  end

  return defaultOrderIds
end

local function getRootTabFallbackName(rootTabId)
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  if rootTabId == QUEST_ROOT_TAB_ID then
    return localeTable.EJ_QUESTLINE_TREE_LABEL or "任务"
  end
  local unknownFormat = localeTable.EJ_ROOT_TAB_NAME_UNKNOWN_FMT or "Tab #%d" -- 未解析页签名格式
  if type(rootTabId) == "number" then
    return string.format(unknownFormat, rootTabId)
  end
  return tostring(rootTabId or "")
end

local function formatQuestStatusPrefix(statusText)
  if statusText == "completed" then
    return "[OK]"
  end
  if statusText == "ready" then
    return "[!]"
  end
  if statusText == "active" then
    return "[>]"
  end
  return "[ ]"
end

local function getQuestStatusTextColor(statusText)
  if statusText == "completed" then
    return 0.2, 0.8, 0.2
  end
  if statusText == "ready" then
    return 1.0, 0.82, 0.18
  end
  if statusText == "active" then
    return 0.35, 0.85, 1
  end
  return nil
end

local function isTreeNodeCollapsed(collapseState, collapseKey)
  if type(collapseState) ~= "table" or type(collapseKey) ~= "string" then
    return false
  end
  return collapseState[collapseKey] == true
end

local function setTreeNodeCollapsed(collapseState, collapseKey, collapsed)
  if type(collapseState) ~= "table" or type(collapseKey) ~= "string" then
    return
  end
  if collapsed == true then
    collapseState[collapseKey] = true
  else
    collapseState[collapseKey] = nil
  end
  Internal.SetCharacterSetting("QUESTLINE_TREE_COLLAPSED", collapseState)
end

local function buildExpansionCollapseKey(expansionID)
  return "expansion:" .. tostring(expansionID or "")
end

local function buildModeCollapseKey(expansionID, modeKey)
  return "mode:" .. tostring(expansionID or "") .. ":" .. tostring(modeKey or "")
end

local function buildCampaignCollapseKey(expansionID, campaignID)
  return "campaign:" .. tostring(expansionID or "") .. ":" .. tostring(campaignID or "")
end

local function normalizeSearchText(rawText)
  if type(rawText) ~= "string" then
    return ""
  end
  local trimmedText = rawText:gsub("^%s+", ""):gsub("%s+$", "") -- 去除首尾空白
  if trimmedText == "" then
    return ""
  end
  return string.lower(trimmedText)
end

local function textContainsKeyword(sourceText, keyword)
  if type(keyword) ~= "string" or keyword == "" then
    return true
  end
  if type(sourceText) ~= "string" or sourceText == "" then
    return false
  end
  return string.find(string.lower(sourceText), keyword, 1, true) ~= nil
end

--- 读取滚动框当前垂直偏移
---@param scrollFrame table|nil 滚动框
---@return number scrollOffset 当前滚动偏移
local function readVerticalScrollOffset(scrollFrame)
  if not scrollFrame or type(scrollFrame.GetVerticalScroll) ~= "function" then
    return 0
  end

  local scrollOffset = tonumber(scrollFrame:GetVerticalScroll()) or 0 -- 当前垂直偏移
  return math.max(0, scrollOffset)
end

--- 在重排内容后恢复滚动位置，并按内容高度裁剪边界
---@param scrollFrame table|nil 滚动框
---@param scrollOffset number 期望恢复的偏移
---@param contentHeight number 当前内容高度
local function restoreVerticalScrollOffset(scrollFrame, scrollOffset, contentHeight)
  if not scrollFrame or type(scrollFrame.SetVerticalScroll) ~= "function" then
    return
  end

  local restoredOffset = math.max(0, tonumber(scrollOffset) or 0) -- 归一化后的滚动偏移
  local frameHeight = type(scrollFrame.GetHeight) == "function" and tonumber(scrollFrame:GetHeight()) or nil -- 滚动框高度
  local normalizedContentHeight = tonumber(contentHeight) or 0 -- 内容总高度
  if type(frameHeight) == "number" and frameHeight > 0 and normalizedContentHeight > frameHeight then
    local maxOffset = math.max(0, normalizedContentHeight - frameHeight) -- 当前内容允许的最大偏移
    restoredOffset = math.min(restoredOffset, maxOffset)
  end

  scrollFrame:SetVerticalScroll(restoredOffset)
end

local function formatProgressText(progressInfo, localeTable)
  if type(progressInfo) ~= "table" then
    return nil
  end
  return string.format(
    localeTable.EJ_QUESTLINE_PROGRESS_FMT or "%d/%d",
    progressInfo.completed or 0,
    progressInfo.total or 0
  )
end

local function formatCompletedAtText(completedAt)
  if type(completedAt) ~= "number" or completedAt <= 0 then
    return ""
  end
  if type(date) ~= "function" then
    return tostring(completedAt)
  end
  local formatSuccess, formattedText = pcall(date, "%m-%d %H:%M", completedAt) -- 完成时间显示文本
  if formatSuccess and type(formattedText) == "string" and formattedText ~= "" then
    return formattedText
  end
  return tostring(completedAt)
end

local function resolveQuestLineDisplayName(questLineEntry)
  if type(questLineEntry) ~= "table" then
    return nil
  end

  local questLineID = type(questLineEntry.id) == "number" and questLineEntry.id or nil -- 当前任务线 ID
  if type(questLineID) == "number"
    and AzerothCompanion.API.Questlines
    and type(AzerothCompanion.API.Questlines.GetQuestLineDisplayName) == "function"
  then
    local displayName, errorObject = AzerothCompanion.API.Questlines.GetQuestLineDisplayName(questLineID) -- 任务线显示名
    if not errorObject and type(displayName) == "string" and displayName ~= "" then
      return displayName
    end
  end

  if type(questLineEntry.name) == "string" and questLineEntry.name ~= "" then
    return questLineEntry.name
  end
  return nil
end

local function buildBreadcrumbButtonWidth(textValue)
  local textLength = #(tostring(textValue or "")) -- 文本长度
  return math.max(56, textLength * 9 + 18)
end

local function applyBreadcrumbButtonState(buttonObject, crumbEntry, crumbIndex, crumbCount)
  if not buttonObject then
    return
  end

  if type(crumbEntry.onClick) == "function" and crumbIndex < crumbCount then
    buttonObject:SetEnabled(true)
    buttonObject:SetScript("OnClick", function()
      crumbEntry.onClick()
    end)
  else
    buttonObject:SetEnabled(false)
    buttonObject:SetScript("OnClick", nil)
  end
end

local function syncNavBarBreadcrumbButtons(viewObject, breadcrumbList)
  if not viewObject or not viewObject.breadcrumbFrame then
    return false
  end

  viewObject.breadcrumbButtons = viewObject.breadcrumbButtons or {}
  local previousButton = nil -- 上一个导航按钮
  local frameWidth = type(viewObject.breadcrumbFrame.GetWidth) == "function"
    and tonumber(viewObject.breadcrumbFrame:GetWidth())
    or 0 -- 导航容器可用宽度
  local shownCount = 0 -- 已显示按钮数量
  for crumbIndex, crumbEntry in ipairs(breadcrumbList) do
    local buttonObject = viewObject.breadcrumbButtons[crumbIndex] -- 当前导航按钮
    if not buttonObject then
      local createSuccess, createdButton = pcall(CreateFrame, "Button", nil, viewObject.breadcrumbFrame, "NavButtonTemplate") -- NavBar 按钮模板
      if not createSuccess or not createdButton then
        return false
      end
      buttonObject = createdButton
      viewObject.breadcrumbButtons[crumbIndex] = buttonObject
    end

    buttonObject:SetText(tostring(crumbEntry.text or ""))
    local requestedWidth = buildBreadcrumbButtonWidth(crumbEntry.text) -- 当前按钮理想宽度
    local finalWidth = requestedWidth -- 实际按钮宽度
    if type(frameWidth) == "number" and frameWidth > 0 then
      local gapWidth = shownCount > 0 and 2 or 0 -- 当前按钮前置间距
      local remainingWidth = frameWidth - gapWidth -- 当前剩余宽度
      if previousButton and previousButton.GetWidth then
        remainingWidth = remainingWidth - (tonumber(previousButton:GetWidth()) or 0)
      end
      if shownCount > 1 then
        for widthIndex = 1, shownCount - 1 do
          local previousWidthButton = viewObject.breadcrumbButtons[widthIndex] -- 之前已显示按钮
          if previousWidthButton and previousWidthButton.GetWidth then
            remainingWidth = remainingWidth - (tonumber(previousWidthButton:GetWidth()) or 0) - 2
          end
        end
      end
      if remainingWidth <= 0 then
        buttonObject:Hide()
        break
      end
      finalWidth = math.min(requestedWidth, math.max(1, remainingWidth))
    end
    buttonObject:SetWidth(finalWidth)
    buttonObject:SetHeight(VIEW_STYLE.headerHeight)
    if buttonObject.SetJustifyH then
      buttonObject:SetJustifyH("LEFT")
    end
    buttonObject:ClearAllPoints()
    if previousButton then
      buttonObject:SetPoint("LEFT", previousButton, "RIGHT", 2, 0)
    else
      buttonObject:SetPoint("LEFT", viewObject.breadcrumbFrame, "LEFT", 0, 0)
    end
    applyBreadcrumbButtonState(buttonObject, crumbEntry, crumbIndex, #breadcrumbList)
    buttonObject:Show()
    previousButton = buttonObject
    shownCount = shownCount + 1
  end

  for hideIndex = shownCount + 1, #viewObject.breadcrumbButtons do
    viewObject.breadcrumbButtons[hideIndex]:Hide()
  end
  return true
end

local function syncFallbackBreadcrumbButtons(viewObject, breadcrumbList)
  if not viewObject or not viewObject.breadcrumbFrame then
    return
  end

  viewObject.breadcrumbButtons = viewObject.breadcrumbButtons or {}
  local previousButton = nil -- 上一个 breadcrumb 按钮
  local frameWidth = type(viewObject.breadcrumbFrame.GetWidth) == "function"
    and tonumber(viewObject.breadcrumbFrame:GetWidth())
    or 0 -- fallback 导航容器可用宽度
  local shownCount = 0 -- 已显示按钮数量
  for crumbIndex, crumbEntry in ipairs(breadcrumbList) do
    local buttonObject = viewObject.breadcrumbButtons[crumbIndex] -- 当前 breadcrumb 按钮
    if not buttonObject then
      buttonObject = CreateFrame("Button", nil, viewObject.breadcrumbFrame, "UIPanelButtonTemplate")
      viewObject.breadcrumbButtons[crumbIndex] = buttonObject
    end
    buttonObject:SetText(tostring(crumbEntry.text or ""))
    buttonObject:SetHeight(VIEW_STYLE.headerHeight)
    local requestedWidth = math.max(72, (buttonObject.GetText and #(buttonObject:GetText() or "") or 8) * 10) -- fallback 理想宽度
    local finalWidth = requestedWidth -- fallback 实际宽度
    if type(frameWidth) == "number" and frameWidth > 0 then
      local gapWidth = shownCount > 0 and 4 or 0 -- fallback 当前前置间距
      local remainingWidth = frameWidth - gapWidth -- fallback 剩余宽度
      if previousButton and previousButton.GetWidth then
        remainingWidth = remainingWidth - (tonumber(previousButton:GetWidth()) or 0)
      end
      if shownCount > 1 then
        for widthIndex = 1, shownCount - 1 do
          local previousWidthButton = viewObject.breadcrumbButtons[widthIndex] -- 之前已显示按钮
          if previousWidthButton and previousWidthButton.GetWidth then
            remainingWidth = remainingWidth - (tonumber(previousWidthButton:GetWidth()) or 0) - 4
          end
        end
      end
      if remainingWidth <= 0 then
        buttonObject:Hide()
        break
      end
      finalWidth = math.min(requestedWidth, math.max(1, remainingWidth))
    end
    buttonObject:SetWidth(finalWidth)
    if buttonObject.SetJustifyH then
      buttonObject:SetJustifyH("LEFT")
    end
    buttonObject:ClearAllPoints()
    if previousButton then
      buttonObject:SetPoint("LEFT", previousButton, "RIGHT", 4, 0)
    else
      buttonObject:SetPoint("LEFT", viewObject.breadcrumbFrame, "LEFT", 0, 0)
    end
    applyBreadcrumbButtonState(buttonObject, crumbEntry, crumbIndex, #breadcrumbList)
    buttonObject:Show()
    previousButton = buttonObject
    shownCount = shownCount + 1
  end

  for hideIndex = shownCount + 1, #viewObject.breadcrumbButtons do
    viewObject.breadcrumbButtons[hideIndex]:Hide()
  end
end


function QuestlineTreeView:syncTabLabel()
  if isStandaloneQuestHost(self.hostJournalFrame) then
    if self.tabButton and self.tabButton.Hide then
      self.tabButton:Hide()
    end
    return
  end
  if not self.tabButton or not self.tabButton.SetText then
    return
  end
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  self.tabButton:SetText(localeTable.EJ_QUESTLINE_TREE_LABEL or "任务")
  if type(PanelTemplates_TabResize) == "function" then
    pcall(PanelTemplates_TabResize, self.tabButton, 0)
  end
  if self.tabButton.Text and self.tabButton.Text.SetPoint then
    self.tabButton.Text:ClearAllPoints()
    self.tabButton.Text:SetPoint("CENTER", self.tabButton, "CENTER", 0, -1)
  end
end


function QuestlineTreeView:hookVanillaTabsOnce()
  if isStandaloneQuestHost(self.hostJournalFrame) then
    return
  end
  if not self.hostJournalFrame then
    return
  end
  local nativeTabList = self:getNativeRootTabs(true) -- 原生根页签列表（含隐藏）
  for _, childButton in ipairs(nativeTabList) do
    if childButton ~= self.tabButton
      and childButton
      and childButton.GetObjectType
      and childButton:GetObjectType() == "Button"
      and childButton.GetID
      and type(childButton:GetID()) == "number"
      and childButton.HookScript
      and not self.hookedNativeTabs[childButton]
    then
      self.hookedNativeTabs[childButton] = true
      childButton:HookScript("OnClick", function()
        self.pendingNativeSelection = true
        self.selected = false
        self:updateVisibility()
      end)
    end
  end
end

function QuestlineTreeView:setTabVisualSelected(selected)
  if not self.tabButton then
    return
  end
  if selected then
    if type(PanelTemplates_SelectTab) == "function" then
      pcall(PanelTemplates_SelectTab, self.tabButton)
    elseif self.tabButton.LockHighlight then
      self.tabButton:LockHighlight()
    end
  else
    if type(PanelTemplates_DeselectTab) == "function" then
      pcall(PanelTemplates_DeselectTab, self.tabButton)
    elseif self.tabButton.UnlockHighlight then
      self.tabButton:UnlockHighlight()
    end
  end
end

function QuestlineTreeView:hideAllRows()
  for _, rowButton in ipairs(self.rowButtons) do
    rowButton:Hide()
  end
end

function QuestlineTreeView:hideAllRightRows()
  for _, rowButton in ipairs(self.rightRowButtons) do
    rowButton:Hide()
  end
end

function QuestlineTreeView:hideRowButtonList(rowButtonList)
  for _, rowButton in ipairs(rowButtonList or {}) do
    rowButton:Hide()
  end
end

function QuestlineTreeView:cancelPendingRender()
  if self.renderTimerHandle and type(self.renderTimerHandle.Cancel) == "function" then
    self.renderTimerHandle:Cancel()
  end
  self.renderTimerHandle = nil
  self.renderScheduled = false
end

function QuestlineTreeView:requestRender()
  self:ensureWidgets()
  if self.renderScheduled == true then
    return
  end
  if Runtime and Runtime.__isTesting == true then
    self:render()
    return
  end
  if Runtime and type(Runtime.After) == "function" then
    self.renderScheduled = true
    self.renderTimerHandle = Runtime.After(0, function()
      self.renderTimerHandle = nil
      self.renderScheduled = false
      self:render()
    end)
    return
  end
  self:render()
end

function QuestlineTreeView:setSelected(selected, suppressVisibilityUpdate)
  if selected == true and self.selected ~= true and self.hostJournalFrame and type(self.hostJournalFrame.selectedTab) == "number" then
    self.nativeTabBeforeQuest = self.hostJournalFrame.selectedTab -- 进入任务页前的原生页签 ID
  end
  local normalizedSelected = selected == true -- 归一化后的选中状态
  if self.selected == normalizedSelected then
    return
  end
  self.selected = normalizedSelected
  if self.selected ~= true then
    self:cancelPendingRender()
  end
  if suppressVisibilityUpdate == true then
    return
  end
  self:updateVisibility()
end

function QuestlineTreeView:getNativeRootTabs(includeHidden)
  local nativeTabList = {} -- 原生根页签数组
  local journalFrame = self.hostJournalFrame -- 冒险手册根面板
  if journalFrame and type(journalFrame.Tabs) == "table" then
    for _, rootTabButton in ipairs(journalFrame.Tabs) do
      if rootTabButton and rootTabButton ~= self.tabButton then
        local shouldInclude = includeHidden == true -- 是否纳入当前页签
        if not shouldInclude and rootTabButton.IsShown then
          local shownSuccess, isShown = pcall(function() return rootTabButton:IsShown() end)
          shouldInclude = shownSuccess and isShown == true
        end
        if shouldInclude then
          nativeTabList[#nativeTabList + 1] = rootTabButton
        end
      end
    end
  end
  return nativeTabList
end

function QuestlineTreeView:getRaidRootTab()
  local nativeTabList = self:getNativeRootTabs(true) -- 原生根页签列表（含隐藏）
  for _, rootTabButton in ipairs(nativeTabList) do
    local rootTabId = self:resolveNativeRootTabId(rootTabButton) -- 当前根页签 ID
    if rootTabId == RAID_ROOT_TAB_ID then
      return rootTabButton
    end
  end
  return nil
end

function QuestlineTreeView:resolveNativeRootTabId(rootTabButton)
  if not rootTabButton or not rootTabButton.GetID then
    return nil
  end
  local rootTabId = rootTabButton:GetID() -- 根页签 ID
  if type(rootTabId) == "number" and rootTabId > 0 then
    return rootTabId
  end
  return nil
end

function QuestlineTreeView:readRootTabDisplayName(rootTabButton)
  if not rootTabButton then
    return ""
  end
  if rootTabButton.GetText then
    local buttonText = rootTabButton:GetText() -- 页签主文本
    if type(buttonText) == "string" and buttonText ~= "" then
      return buttonText
    end
  end
  local textRegion = rootTabButton.Text -- 页签文本区域
  if textRegion and textRegion.GetText then
    local regionText = textRegion:GetText() -- 页签文本区域内容
    if type(regionText) == "string" then
      return regionText
    end
  end
  local rootTabId = self:resolveNativeRootTabId(rootTabButton) -- 根页签 ID
  return type(rootTabId) == "number" and tostring(rootTabId) or ""
end

function QuestlineTreeView:buildRootTabDisplayNameById(rootTabIdList)
  local displayNameById = {} -- 页签显示名映射（按 ID）
  local sourceTabIdList = rootTabIdList -- 传入页签 ID 顺序列表
  if type(sourceTabIdList) ~= "table" or #sourceTabIdList == 0 then
    sourceTabIdList = buildEffectiveRootTabOrderIds()
  end

  ensureEncounterJournalAddonLoaded()

  for _, rootTabId in ipairs(sourceTabIdList) do
    if type(rootTabId) == "number" and rootTabId > 0 then
      displayNameById[rootTabId] = getRootTabFallbackName(rootTabId)
    end
  end
  displayNameById[QUEST_ROOT_TAB_ID] = getRootTabFallbackName(QUEST_ROOT_TAB_ID)

  self:ensureWidgets()
  local nativeRootTabList = self:getNativeRootTabs(true) -- 原生根页签（含隐藏）
  for _, rootTabButton in ipairs(nativeRootTabList) do
    local rootTabId = self:resolveNativeRootTabId(rootTabButton) -- 页签 ID
    local displayName = self:readRootTabDisplayName(rootTabButton) -- 动态页签名
    if type(rootTabId) == "number" and type(displayName) == "string" and displayName ~= "" then
      displayNameById[rootTabId] = displayName
    end
  end

  return displayNameById
end

function QuestlineTreeView:buildDefaultRootTabOrderIds()
  return buildDefaultRootTabOrderIds()
end

function QuestlineTreeView:buildEffectiveRootTabOrderIds()
  return buildEffectiveRootTabOrderIds()
end

function QuestlineTreeView:setNativeRootTabShown(rootTabButton, shouldShow)
  if not rootTabButton then
    return
  end
  local rootTabID = rootTabButton.GetID and rootTabButton:GetID() or nil -- 根页签 ID
  if type(rootTabID) == "number"
    and self.hostJournalFrame
    and type(PanelTemplates_ShowTab) == "function"
    and type(PanelTemplates_HideTab) == "function"
  then
    if shouldShow then
      pcall(PanelTemplates_ShowTab, self.hostJournalFrame, rootTabID)
    else
      pcall(PanelTemplates_HideTab, self.hostJournalFrame, rootTabID)
    end
    return
  end
  if shouldShow then
    rootTabButton:Show()
  else
    rootTabButton:Hide()
  end
end

function QuestlineTreeView:deselectAllNativeTabs()
  local nativeTabList = self:getNativeRootTabs(true) -- 原生根页签列表（含隐藏）
  for _, rootTabButton in ipairs(nativeTabList) do
    if rootTabButton and rootTabButton ~= self.tabButton then
      if rootTabButton and rootTabButton.GetID then
        if type(PanelTemplates_DeselectTab) == "function" then
          pcall(PanelTemplates_DeselectTab, rootTabButton)
        end
      end
    end
  end
end

function QuestlineTreeView:hideNativeRootChrome()
  if not self.hostJournalFrame then
    return
  end
  local navBar = self.hostJournalFrame.navBar -- 顶部导航条
  if navBar and navBar.Hide then
    navBar:Hide()
  end
  local searchBox = self.hostJournalFrame.searchBox -- 右上搜索框
  if searchBox and searchBox.Hide then
    searchBox:Hide()
  end
  local journeysFrame = self.hostJournalFrame.JourneysFrame -- Journeys 独立内容面板
  if journeysFrame and journeysFrame.Hide then
    journeysFrame:Hide()
  end
  if type(EncounterJournal_HideGreatVaultButton) == "function" then
    pcall(EncounterJournal_HideGreatVaultButton)
  end
end

function QuestlineTreeView:restoreNativeRootTab()
  if not self.hostJournalFrame or type(EJ_ContentTab_Select) ~= "function" then
    return
  end
  local restoreTabId = self.hostJournalFrame.selectedTab -- 恢复目标页签 ID（优先当前原生状态）
  if type(restoreTabId) ~= "number" then
    restoreTabId = self.nativeTabBeforeQuest
  end
  if type(restoreTabId) ~= "number" then
    restoreTabId = RAID_ROOT_TAB_ID
  end
  if type(restoreTabId) == "number" then
    pcall(EJ_ContentTab_Select, restoreTabId)
  end
end

local rootStateStrategies = {
  quest = function(view)
    if type(view.nativeTabBeforeQuest) ~= "number"
      and view.hostJournalFrame
      and type(view.hostJournalFrame.selectedTab) == "number"
    then
      view.nativeTabBeforeQuest = view.hostJournalFrame.selectedTab -- 首次进入任务页签时记录原生页签
    end
    if type(EJ_HideNonInstancePanels) == "function" then
      pcall(EJ_HideNonInstancePanels)
    end
    view:hideNativeRootChrome()
    view:render()
    view.panelFrame:Show()
    view:deselectAllNativeTabs()
    if view.hostJournalFrame then
      local instanceSelect = view.hostJournalFrame.instanceSelect -- 副本列表容器
      local encounterFrame = view.hostJournalFrame.encounter -- 首领详情容器
      if instanceSelect and instanceSelect.Hide then
        instanceSelect:Hide()
      end
      if encounterFrame and encounterFrame.Hide then
        encounterFrame:Hide()
      end
    end
  end,
  native = function(view, stateContext)
    view.panelFrame:Hide()
    if stateContext and stateContext.shouldRestoreNative then
      view:restoreNativeRootTab()
    end
    view.nativeTabBeforeQuest = nil
  end,
}

function QuestlineTreeView:resolveRootState(canShow)
  if canShow and self.selected then
    return "quest"
  end
  return "native"
end

function QuestlineTreeView:applyRootState(rootState, stateContext)
  local strategy = rootStateStrategies[rootState] -- 根状态策略
  if not strategy then
    return
  end
  strategy(self, stateContext)
  self.activeRootState = rootState
end

function QuestlineTreeView:layoutRootTabs()
  if isStandaloneQuestHost(self.hostJournalFrame) then
    if self.tabButton and self.tabButton.Hide then
      self.tabButton:Hide()
    end
    return
  end
  if not self.tabButton or not self.hostJournalFrame then
    return
  end

  local allNativeTabList = self:getNativeRootTabs(true) -- 全量原生页签（含隐藏）
  if #allNativeTabList == 0 then
    self.tabButton:ClearAllPoints()
    self.tabButton:SetPoint("BOTTOMLEFT", self.hostJournalFrame, "BOTTOMLEFT", 110, 3)
    return
  end

  local effectiveRootTabOrderIds = buildEffectiveRootTabOrderIds() -- 生效顺序配置（按 ID）
  local visibleNativeEntryById = {} -- 可见原生页签 ID 映射
  local visibleNativeTabList = {} -- 可见原生页签顺序列表

  for _, rootTabButton in ipairs(allNativeTabList) do
    local rootTabId = self:resolveNativeRootTabId(rootTabButton) -- 当前页签 ID
    local rootTabName = self:readRootTabDisplayName(rootTabButton) -- 当前页签名（动态读取）
    self:setNativeRootTabShown(rootTabButton, true)
    local entry = {
      id = rootTabId,
      name = rootTabName,
      button = rootTabButton,
    }
    visibleNativeTabList[#visibleNativeTabList + 1] = entry
    if type(rootTabId) == "number" and not visibleNativeEntryById[rootTabId] then
      visibleNativeEntryById[rootTabId] = entry
    end
  end

  local orderedTabList = {} -- 最终重排后的显示页签
  local addedTabSet = {} -- 已添加页签集合
  local shouldShowQuestTab = isQuestlineTreeEnabled() -- 任务页签是否可见

  self.tabButton:SetShown(shouldShowQuestTab)

  local function appendRootTab(rootTabButton)
    if not rootTabButton or addedTabSet[rootTabButton] then
      return
    end
    orderedTabList[#orderedTabList + 1] = rootTabButton
    addedTabSet[rootTabButton] = true
  end

  for _, rootTabId in ipairs(effectiveRootTabOrderIds) do
    if rootTabId == QUEST_ROOT_TAB_ID then
      if shouldShowQuestTab then
        appendRootTab(self.tabButton)
      end
    else
      local nativeEntry = visibleNativeEntryById[rootTabId] -- 对应原生页签
      appendRootTab(nativeEntry and nativeEntry.button or nil)
    end
  end

  for _, nativeEntry in ipairs(visibleNativeTabList) do
    appendRootTab(nativeEntry.button)
  end

  if shouldShowQuestTab then
    appendRootTab(self.tabButton)
  end

  if #orderedTabList == 0 then
    self.tabButton:Hide()
    return
  end

  local previousTab = nil -- 上一个已锚定页签
  for _, rootTabButton in ipairs(orderedTabList) do
    rootTabButton:ClearAllPoints()
    if previousTab then
      rootTabButton:SetPoint("LEFT", previousTab, "RIGHT", 3, 0)
    else
      rootTabButton:SetPoint("TOPLEFT", self.hostJournalFrame, "BOTTOMLEFT", 11, 2)
    end
    previousTab = rootTabButton
  end
end

local function normalizeQuestNavModeKey(modeKey)
  if modeKey == "active_log" then
    return "active_log"
  end
  if modeKey == "campaign" then
    return "campaign"
  end
  if modeKey == "achievement" then
    return "achievement"
  end
  return "map_questline"
end

local function getActiveLogRootText(localeTable)
  return localeTable.QUEST_VIEW_TAB_ACTIVE or "当前任务"
end

local function getQuestlineRootText(localeTable)
  return localeTable.QUEST_VIEW_TAB_QUESTLINE or "任务线"
end

local function getCampaignRootText(localeTable)
  return localeTable.QUEST_VIEW_TAB_CAMPAIGN or "战役"
end

local function getAchievementRootText(localeTable)
  return localeTable.QUEST_VIEW_TAB_ACHIEVEMENT or "成就"
end

local function getFactionLabelByTag(localeTable, factionTag)
  if factionTag == "alliance" then
    return localeTable.EJ_QUEST_FACTION_LABEL_ALLIANCE or "联盟"
  end
  if factionTag == "horde" then
    return localeTable.EJ_QUEST_FACTION_LABEL_HORDE or "部落"
  end
  if factionTag == "shared" then
    return localeTable.EJ_QUEST_FACTION_LABEL_SHARED or "通用"
  end
  return ""
end

local function buildFactionBadgeText(localeTable, factionTagList)
  if type(factionTagList) ~= "table" or #factionTagList == 0 then
    return ""
  end
  local factionLabelList = {} -- 阵营标签文本列表
  for _, factionTag in ipairs(factionTagList) do
    local factionLabel = getFactionLabelByTag(localeTable, factionTag) -- 当前阵营标签
    if type(factionLabel) == "string" and factionLabel ~= "" then
      factionLabelList[#factionLabelList + 1] = factionLabel
    end
  end
  if #factionLabelList == 0 then
    return ""
  end
  return string.format("[%s]", table.concat(factionLabelList, "/"))
end

local function getRecentCompletedToggleText(localeTable, collapsed)
  if collapsed == true then
    return localeTable.QUEST_VIEW_RECENT_TOGGLE_EXPAND or "展开历史完成"
  end
  return localeTable.QUEST_VIEW_RECENT_TOGGLE_COLLAPSE or "折叠历史完成"
end

local function getMapQuestlineModeEntry(expansionEntry)
  return expansionEntry and expansionEntry.modeByKey and expansionEntry.modeByKey.map_questline or nil
end

local function isCampaignEntryList(modeEntry)
  local entryList = type(modeEntry) == "table" and modeEntry.entries or nil -- 导航条目列表
  if type(entryList) ~= "table" then
    return false
  end
  for _, entryObject in ipairs(entryList) do
    if type(entryObject) == "table" then
      return entryObject.kind == "campaign"
    end
  end
  return false
end

local function getCampaignModeEntry(expansionEntry)
  local campaignModeEntry = expansionEntry and expansionEntry.modeByKey and expansionEntry.modeByKey.campaign or nil -- 战役模式
  if type(campaignModeEntry) == "table" then
    return campaignModeEntry
  end
  local legacyModeEntry = getMapQuestlineModeEntry(expansionEntry) -- 旧版复用模式
  if isCampaignEntryList(legacyModeEntry) then
    return legacyModeEntry
  end
  return nil
end

local function getAchievementModeEntry(expansionEntry)
  local achievementModeEntry = expansionEntry and expansionEntry.modeByKey and expansionEntry.modeByKey.achievement or nil -- 成就模式
  if type(achievementModeEntry) == "table" then
    return achievementModeEntry
  end
  return nil
end

local function findCampaignEntryByID(modeEntry, campaignID)
  if type(campaignID) ~= "number" then
    return nil
  end
  for _, campaignEntry in ipairs(modeEntry and modeEntry.entries or {}) do
    if type(campaignEntry) == "table" and campaignEntry.kind == "campaign" and campaignEntry.id == campaignID then
      return campaignEntry
    end
  end
  return nil
end

local function findAchievementEntryByID(modeEntry, achievementID)
  if type(achievementID) ~= "number" then
    return nil
  end
  for _, achievementEntry in ipairs(modeEntry and modeEntry.entries or {}) do
    if type(achievementEntry) == "table" and achievementEntry.kind == "achievement" and achievementEntry.id == achievementID then
      return achievementEntry
    end
  end
  return nil
end

local function setModeTabSelected(tabButton, selected)
  if not tabButton then
    return
  end
  if selected == true then
    if type(PanelTemplates_SelectTab) == "function" then
      pcall(PanelTemplates_SelectTab, tabButton)
    elseif tabButton.LockHighlight then
      tabButton:LockHighlight()
    end
  else
    if type(PanelTemplates_DeselectTab) == "function" then
      pcall(PanelTemplates_DeselectTab, tabButton)
    elseif tabButton.UnlockHighlight then
      tabButton:UnlockHighlight()
    end
  end
end

local function getMapNameByID(uiMapID)
  if type(uiMapID) == "number" and type(C_Map) == "table" and type(C_Map.GetMapInfo) == "function" then
    local success, mapInfo = pcall(C_Map.GetMapInfo, uiMapID) -- 安全查询地图信息
    if success and type(mapInfo) == "table" and type(mapInfo.name) == "string" and mapInfo.name ~= "" then
      return mapInfo.name
    end
  end
  return "Map #" .. tostring(uiMapID or "?")
end

function QuestlineTreeView:loadSelection()
  self.selectedExpansionID = normalizeSelectionID(Internal.GetCharacterSetting("QUEST_NAV_EXPANSION_ID"))
  self.selectedCampaignID = normalizeSelectionID(Internal.GetCharacterSetting("QUEST_NAV_SELECTED_CAMPAIGN_ID"))
  self.selectedAchievementID = normalizeSelectionID(Internal.GetCharacterSetting("QUEST_NAV_SELECTED_ACHIEVEMENT_ID"))
  self.selectedModeKey = normalizeQuestNavModeKey(Internal.GetCharacterSetting("QUEST_NAV_MODE_KEY"))
  self.selectedMapID = normalizeSelectionID(Internal.GetCharacterSetting("QUEST_NAV_SELECTED_MAP_ID"))
  self.selectedTypeKey = ""
  local searchText = Internal.GetCharacterSetting("QUEST_NAV_SEARCH_TEXT") -- 任务导航搜索文本
  self.searchText = type(searchText) == "string" and searchText or ""
  self.expandedQuestLineID = normalizeSelectionID(Internal.GetCharacterSetting("QUEST_NAV_EXPANDED_QUESTLINE_ID"))
  if self.selectedModeKey == "active_log" then
    self.selectedCampaignID = nil
    self.selectedAchievementID = nil
    self.selectedMapID = nil
    self.expandedQuestLineID = nil
  elseif self.selectedModeKey == "campaign" then
    self.selectedAchievementID = nil
    self.selectedMapID = nil
  elseif self.selectedModeKey == "achievement" then
    self.selectedCampaignID = nil
    self.selectedMapID = nil
  else
    self.selectedCampaignID = nil
    self.selectedAchievementID = nil
  end
  self.directQuestLineCollapsed = false
  self.activeLogRecentCollapsed = false
  self:trimRecentCompletedQuestRecords()
  self.selectedQuestID = nil
end

function QuestlineTreeView:saveSelection()
  Internal.SetCharacterSetting("QUEST_NAV_EXPANSION_ID", type(self.selectedExpansionID) == "number" and self.selectedExpansionID or 0)
  Internal.SetCharacterSetting("QUEST_NAV_SELECTED_CAMPAIGN_ID", type(self.selectedCampaignID) == "number" and self.selectedCampaignID or 0)
  Internal.SetCharacterSetting("QUEST_NAV_SELECTED_ACHIEVEMENT_ID", type(self.selectedAchievementID) == "number" and self.selectedAchievementID or 0)
  Internal.SetCharacterSetting("QUEST_NAV_MODE_KEY", normalizeQuestNavModeKey(self.selectedModeKey))
  Internal.SetCharacterSetting("QUEST_NAV_SELECTED_MAP_ID", type(self.selectedMapID) == "number" and self.selectedMapID or 0)
  Internal.SetCharacterSetting("QUEST_NAV_SEARCH_TEXT", type(self.searchText) == "string" and self.searchText or "")
  Internal.SetCharacterSetting("QUEST_NAV_EXPANDED_QUESTLINE_ID", type(self.expandedQuestLineID) == "number" and self.expandedQuestLineID or 0)
end

function QuestlineTreeView:trimRecentCompletedQuestRecords()
  local recentCompletedList = getRecentCompletedQuestList() -- 最近完成任务列表
  local maxCount = getRecentCompletedQuestMaxValue() -- 当前最大保留条数
  local uniqueQuestIdSet = {} -- 去重索引
  local normalizedRecentList = {} -- 归一化后的列表
  for _, recentEntry in ipairs(recentCompletedList) do
    local questID = type(recentEntry) == "table" and recentEntry.questID or nil -- 当前任务 ID
    if type(questID) == "number" and questID > 0 and uniqueQuestIdSet[questID] ~= true then
      uniqueQuestIdSet[questID] = true
      normalizedRecentList[#normalizedRecentList + 1] = {
        questID = questID,
        questName = type(recentEntry.questName) == "string" and recentEntry.questName or "",
        completedAt = type(recentEntry.completedAt) == "number" and recentEntry.completedAt or 0,
      }
      if #normalizedRecentList >= maxCount then
        break
      end
    end
  end
  Internal.SetCharacterSetting("QUEST_RECENT_COMPLETED_LIST", normalizedRecentList)
end

function QuestlineTreeView:recordRecentlyCompletedQuest(questID, completedAt)
  if type(questID) ~= "number" or questID <= 0 then
    return
  end
  getRecentCompletedQuestMaxValue()
  local recentCompletedList = getRecentCompletedQuestList() -- 最近完成任务列表
  local questName = nil -- 任务显示名
  if C_QuestLog and type(C_QuestLog.GetTitleForQuestID) == "function" then
    local questTitle = C_QuestLog.GetTitleForQuestID(questID) -- 任务标题
    if type(questTitle) == "string" and questTitle ~= "" then
      questName = questTitle
    end
  end
  if type(questName) ~= "string" or questName == "" then
    questName = "Quest #" .. tostring(questID)
  end
  local completedTimestamp = type(completedAt) == "number" and completedAt or 0 -- 完成时间戳
  if completedTimestamp <= 0 then
    if type(GetServerTime) == "function" then
      completedTimestamp = GetServerTime()
    elseif type(time) == "function" then
      completedTimestamp = time()
    end
  end
  for index = #recentCompletedList, 1, -1 do
    local recentEntry = recentCompletedList[index] -- 当前遍历条目
    if type(recentEntry) == "table" and recentEntry.questID == questID then
      table.remove(recentCompletedList, index)
    end
  end
  table.insert(recentCompletedList, 1, {
    questID = questID,
    questName = questName,
    completedAt = completedTimestamp,
  })
  Internal.SetCharacterSetting("QUEST_RECENT_COMPLETED_LIST", recentCompletedList)
  self:trimRecentCompletedQuestRecords()
  if self.selected == true and self.selectedModeKey == "active_log" then
    self:requestRender()
  end
end

function QuestlineTreeView:resolveNavigationDefaults(navigationModel)
  local expansionList = navigationModel and navigationModel.expansionList or {} -- 资料片列表
  local expansionByID = navigationModel and navigationModel.expansionByID or {} -- 资料片索引
  if type(self.selectedExpansionID) ~= "number" or type(expansionByID[self.selectedExpansionID]) ~= "table" then
    self.selectedExpansionID = expansionList[1] and expansionList[1].id or nil
  end

  local expansionEntry = type(self.selectedExpansionID) == "number" and expansionByID[self.selectedExpansionID] or nil -- 当前资料片
  if type(expansionEntry) ~= "table" then
    self.selectedMapID = nil
    self.selectedCampaignID = nil
    self.selectedTypeKey = ""
    self.expandedQuestLineID = nil
    self.directQuestLineCollapsed = false
    return nil
  end

  self.selectedModeKey = normalizeQuestNavModeKey(self.selectedModeKey)

  if self.selectedModeKey == "campaign" then
    local campaignMode = getCampaignModeEntry(expansionEntry) -- 战役模式
    local campaignEntry = findCampaignEntryByID(campaignMode, self.selectedCampaignID) -- 当前战役条目
    if type(campaignEntry) ~= "table" then
      local firstCampaignEntry = campaignMode and campaignMode.entries and campaignMode.entries[1] or nil -- 首个战役条目
      self.selectedCampaignID = type(firstCampaignEntry) == "table" and firstCampaignEntry.id or nil
      campaignEntry = type(firstCampaignEntry) == "table" and firstCampaignEntry or nil
    end
    local hasSelectedQuestLine = false -- 当前任务线是否属于选中战役
    for _, questLineEntry in ipairs(campaignEntry and campaignEntry.questLines or {}) do
      if type(questLineEntry) == "table" and questLineEntry.id == self.expandedQuestLineID then
        hasSelectedQuestLine = true
        break
      end
    end
    if not hasSelectedQuestLine then
      self.expandedQuestLineID = nil
    end
    self.selectedAchievementID = nil
    self.selectedMapID = nil
    self.selectedTypeKey = ""
    self.directQuestLineCollapsed = false
  elseif self.selectedModeKey == "achievement" then
    local achievementMode = getAchievementModeEntry(expansionEntry) -- 成就模式
    local achievementEntry = findAchievementEntryByID(achievementMode, self.selectedAchievementID) -- 当前成就条目
    if type(achievementEntry) ~= "table" then
      local firstAchievementEntry = achievementMode and achievementMode.entries and achievementMode.entries[1] or nil -- 首个成就条目
      self.selectedAchievementID = type(firstAchievementEntry) == "table" and firstAchievementEntry.id or nil
      achievementEntry = type(firstAchievementEntry) == "table" and firstAchievementEntry or nil
    end
    local hasSelectedQuestLine = false -- 当前任务线是否属于选中成就
    for _, questLineEntry in ipairs(achievementEntry and achievementEntry.questLines or {}) do
      if type(questLineEntry) == "table" and questLineEntry.id == self.expandedQuestLineID then
        hasSelectedQuestLine = true
        break
      end
    end
    if not hasSelectedQuestLine then
      self.expandedQuestLineID = nil
    end
    self.selectedCampaignID = nil
    self.selectedMapID = nil
    self.selectedTypeKey = ""
    self.directQuestLineCollapsed = false
  elseif self.selectedModeKey == "map_questline" then
    local mapMode = getMapQuestlineModeEntry(expansionEntry) -- 地图任务线模式
    self.selectedCampaignID = nil
    self.selectedAchievementID = nil
    local hasSelectedMap = false -- 当前地图是否存在
    local hasSelectedQuestLine = false -- 当前直接任务线是否存在
    for _, mapEntry in ipairs(mapMode and mapMode.entries or {}) do
      if mapEntry.kind == "map" and mapEntry.id == self.selectedMapID then
        hasSelectedMap = true
        break
      end
      if mapEntry.kind == "questline" and mapEntry.id == self.expandedQuestLineID and self.selectedMapID == nil then
        hasSelectedQuestLine = true
      end
    end
    if not hasSelectedMap and not hasSelectedQuestLine then
      if type(self.selectedMapID) == "number" or type(self.expandedQuestLineID) == "number" then
        local firstEntry = mapMode and mapMode.entries and mapMode.entries[1] or nil -- 默认子项
        if type(firstEntry) == "table" and firstEntry.kind == "questline" then
          self.selectedMapID = nil
          self.expandedQuestLineID = firstEntry.id
          self.directQuestLineCollapsed = false
        else
          self.selectedMapID = firstEntry and firstEntry.id or nil
          self.expandedQuestLineID = nil
          self.directQuestLineCollapsed = false
        end
      end
    end
    self.selectedTypeKey = ""
  else
    self.selectedMapID = nil
    self.selectedCampaignID = nil
    self.selectedAchievementID = nil
    self.selectedTypeKey = ""
    self.expandedQuestLineID = nil
    self.directQuestLineCollapsed = false
  end

  return expansionEntry
end

function QuestlineTreeView:buildLeftTreeRows(navigationModel)
  local rowDataList = {} -- 左侧树行
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  local expansionList = navigationModel and navigationModel.expansionList or {} -- 资料片列表
  local expansionByID = navigationModel and navigationModel.expansionByID or {} -- 资料片索引
  local collapseState = getQuestlineCollapsedTable() -- 左树折叠状态
  for _, expansionSummary in ipairs(expansionList) do
    local expansionSelected = self.selectedExpansionID == expansionSummary.id -- 资料片是否选中
    local expansionCollapseKey = buildExpansionCollapseKey(expansionSummary.id) -- 资料片折叠键
    local expansionCollapsed = isTreeNodeCollapsed(collapseState, expansionCollapseKey) -- 资料片是否折叠
    rowDataList[#rowDataList + 1] = {
      kind = "expansion",
      text = string.format("%s %s", expansionCollapsed and "[+]" or "[-]", tostring(expansionSummary.name or "")),
      selected = expansionSelected,
      expansionID = expansionSummary.id,
      collapseKey = expansionCollapseKey,
      collapsed = expansionCollapsed,
    }
    if expansionSelected and not expansionCollapsed then
      local expansionEntry = expansionByID[expansionSummary.id] -- 当前资料片对象
      if self.selectedModeKey == "campaign" then
        local campaignMode = getCampaignModeEntry(expansionEntry) -- 战役模式
        for _, campaignEntry in ipairs(campaignMode and campaignMode.entries or {}) do
          local campaignID = type(campaignEntry) == "table" and campaignEntry.id or nil -- 当前战役 ID
          if type(campaignID) == "number" then
            local campaignCollapseKey = buildCampaignCollapseKey(expansionSummary.id, campaignID) -- 战役折叠键
            local campaignCollapsed = isTreeNodeCollapsed(collapseState, campaignCollapseKey) -- 战役是否折叠
            local campaignSelected = self.selectedCampaignID == campaignID -- 战役是否选中
            rowDataList[#rowDataList + 1] = {
              kind = "campaign",
              text = string.format("%s %s", campaignCollapsed and "[+]" or "[-]", tostring(campaignEntry.name or "")),
              selected = campaignSelected,
              expansionID = expansionSummary.id,
              campaignID = campaignID,
              collapseKey = campaignCollapseKey,
              collapsed = campaignCollapsed,
            }
            if campaignSelected and not campaignCollapsed then
              for _, questLineEntry in ipairs(campaignEntry.questLines or {}) do
                local questLineID = type(questLineEntry) == "table" and questLineEntry.id or nil -- 当前任务线 ID
                if type(questLineID) == "number" then
                  rowDataList[#rowDataList + 1] = {
                    kind = "questline",
                    text = resolveQuestLineDisplayName(questLineEntry) or ("QuestLine #" .. tostring(questLineID)),
                    selected = self.expandedQuestLineID == questLineID,
                    expansionID = expansionSummary.id,
                    campaignID = campaignID,
                    questLineID = questLineID,
                  }
                end
              end
            end
          end
        end
      elseif self.selectedModeKey == "achievement" then
        local achievementMode = getAchievementModeEntry(expansionEntry) -- 成就模式
        for _, achievementEntry in ipairs(achievementMode and achievementMode.entries or {}) do
          local achievementID = type(achievementEntry) == "table" and achievementEntry.id or nil -- 当前成就 ID
          if type(achievementID) == "number" then
            local achievementName = tostring(achievementEntry.name or "") -- 成就显示名称
            local factionBadgeText = buildFactionBadgeText(localeTable, achievementEntry.factionTags) -- 成就阵营标识
            local displayText = factionBadgeText ~= "" and string.format("%s %s", achievementName, factionBadgeText) or achievementName -- 左侧树显示文本
            rowDataList[#rowDataList + 1] = {
              kind = "achievement",
              text = displayText,
              selected = self.selectedAchievementID == achievementID,
              expansionID = expansionSummary.id,
              achievementID = achievementID,
            }
          end
        end
      else
        local mapMode = getMapQuestlineModeEntry(expansionEntry) -- 地图任务线模式
        for _, childEntry in ipairs(mapMode and mapMode.entries or {}) do
          local childKind = childEntry.kind -- 导航子项类型
          if type(childKind) ~= "string" or childKind == "" then
            childKind = "map"
          end
          rowDataList[#rowDataList + 1] = {
            kind = childKind,
            text = childEntry.name,
            selected = (childKind == "map" and self.selectedMapID == childEntry.id)
              or (childKind == "questline" and self.selectedMapID == nil and self.expandedQuestLineID == childEntry.id),
            expansionID = expansionSummary.id,
            mapID = childKind == "map" and childEntry.id or nil,
            questLineID = childKind == "questline" and childEntry.id or nil,
          }
        end
      end
    end
  end
  return rowDataList
end

--- 判断左侧树行文本是否发生截断。
---@param rowButton table|nil
---@return boolean
local function isLeftRowTextTruncated(rowButton)
  if type(rowButton) ~= "table" then
    return false
  end
  local rowFont = rowButton.rowFont -- 左树行文本对象
  if type(rowFont) ~= "table" then
    return false
  end
  if type(rowFont.IsTruncated) == "function" then
    local success, isTruncated = pcall(rowFont.IsTruncated, rowFont) -- 直接截断检测结果
    return success == true and isTruncated == true
  end
  local textWidth = type(rowFont.GetStringWidth) == "function" and rowFont:GetStringWidth() or nil -- 文本实际像素宽度
  local availableWidth = type(rowFont.GetWidth) == "function" and rowFont:GetWidth() or nil -- 文本可用像素宽度
  if (type(availableWidth) ~= "number" or availableWidth <= 0)
    and type(rowButton.GetWidth) == "function"
  then
    availableWidth = (rowButton:GetWidth() or 0) - 14
  end
  if type(textWidth) ~= "number" or textWidth <= 0 then
    return false
  end
  if type(availableWidth) ~= "number" or availableWidth <= 0 then
    return false
  end
  return textWidth > (availableWidth + 1)
end

--- 显示左侧树行截断提示。
---@param rowButton table|nil
local function showLeftRowOverflowTooltip(rowButton)
  if type(rowButton) ~= "table" or not GameTooltip then
    return
  end
  local tooltipText = rowButton.leftRowTooltipText -- 行完整文本
  if type(tooltipText) ~= "string" or tooltipText == "" then
    return
  end
  if not isLeftRowTextTruncated(rowButton) then
    return
  end
  GameTooltip:SetOwner(rowButton, "ANCHOR_RIGHT")
  GameTooltip:ClearLines()
  GameTooltip:SetText(tooltipText)
  GameTooltip:Show()
end

--- 隐藏左侧树行截断提示。
---@param rowButton table|nil
local function hideLeftRowOverflowTooltip(rowButton)
  if not GameTooltip then
    return
  end
  if type(GameTooltip.IsOwned) == "function"
    and type(rowButton) == "table"
    and not GameTooltip:IsOwned(rowButton)
  then
    return
  end
  GameTooltip:Hide()
end

function QuestlineTreeView:getOrCreateRowButton(rowIndex)
  local rowButton = self.rowButtons[rowIndex] -- 左树行按钮
  if rowButton then
    return rowButton
  end
  rowButton = CreateFrame("Button", nil, self.scrollChild, "BackdropTemplate")
  rowButton:SetHeight(self.rowHeight)
  rowButton:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
  rowButton:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 10,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
  })
  rowButton:SetBackdropColor(0.12, 0.1, 0.07, 0.68)
  rowButton:SetBackdropBorderColor(0.45, 0.36, 0.19, 0.55)
  local highlightTexture = rowButton:GetHighlightTexture() -- 高亮贴图
  if highlightTexture and highlightTexture.SetBlendMode then
    highlightTexture:SetBlendMode("ADD")
  end
  local rowFont = rowButton:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  rowFont:SetPoint("LEFT", rowButton, "LEFT", 8, 0)
  rowFont:SetPoint("RIGHT", rowButton, "RIGHT", -6, 0)
  rowFont:SetJustifyH("LEFT")
  rowFont:SetJustifyV("MIDDLE")
  rowFont:SetWordWrap(false)
  if rowFont.SetNonSpaceWrap then
    rowFont:SetNonSpaceWrap(false)
  end
  if rowFont.SetMaxLines then
    rowFont:SetMaxLines(1)
  end
  if rowFont.SetTextTruncateMode then
    rowFont:SetTextTruncateMode("END")
  end
  rowButton.rowFont = rowFont
  rowButton:SetScript("OnEnter", function(button)
    showLeftRowOverflowTooltip(button)
  end)
  rowButton:SetScript("OnLeave", function(button)
    hideLeftRowOverflowTooltip(button)
  end)
  rowButton:SetScript("OnClick", function(button)
    local rowData = button.rowData -- 当前行数据
    if type(rowData) ~= "table" then
      return
    end

    local collapseState = getQuestlineCollapsedTable() -- 左树折叠状态
    if rowData.kind == "expansion" and type(rowData.expansionID) == "number" then
      local collapseKey = rowData.collapseKey -- 当前资料片折叠键
      if self.selectedExpansionID == rowData.expansionID and type(collapseKey) == "string" then
        setTreeNodeCollapsed(collapseState, collapseKey, not isTreeNodeCollapsed(collapseState, collapseKey))
      else
        self.selectedExpansionID = rowData.expansionID
        if self.selectedModeKey == "campaign" then
          self.selectedModeKey = "campaign"
        elseif self.selectedModeKey == "achievement" then
          self.selectedModeKey = "achievement"
        else
          self.selectedModeKey = "map_questline"
        end
        self.selectedCampaignID = nil
        self.selectedAchievementID = nil
        self.selectedMapID = nil
        self.selectedTypeKey = ""
        self.expandedQuestLineID = nil
        self.directQuestLineCollapsed = false
        if type(collapseKey) == "string" then
          setTreeNodeCollapsed(collapseState, collapseKey, false)
        end
      end
    elseif rowData.kind == "campaign" and type(rowData.campaignID) == "number" then
      local collapseKey = rowData.collapseKey -- 当前战役折叠键
      if self.selectedCampaignID == rowData.campaignID and type(collapseKey) == "string" then
        setTreeNodeCollapsed(collapseState, collapseKey, not isTreeNodeCollapsed(collapseState, collapseKey))
      else
        self.selectedExpansionID = rowData.expansionID
        self.selectedModeKey = "campaign"
        self.selectedCampaignID = rowData.campaignID
        self.selectedAchievementID = nil
        self.selectedMapID = nil
        self.selectedTypeKey = ""
        self.expandedQuestLineID = nil
        self.directQuestLineCollapsed = false
        if type(collapseKey) == "string" then
          setTreeNodeCollapsed(collapseState, collapseKey, false)
        end
      end
    elseif rowData.kind == "achievement" and type(rowData.achievementID) == "number" then
      self.selectedExpansionID = rowData.expansionID
      self.selectedModeKey = "achievement"
      self.selectedCampaignID = nil
      self.selectedAchievementID = rowData.achievementID
      self.selectedMapID = nil
      self.selectedTypeKey = ""
      self.expandedQuestLineID = nil
      self.directQuestLineCollapsed = false
    elseif rowData.kind == "map" and type(rowData.mapID) == "number" then
      self.selectedModeKey = "map_questline"
      self.selectedCampaignID = nil
      self.selectedAchievementID = nil
      self.selectedMapID = rowData.mapID
      self.selectedTypeKey = ""
      self.expandedQuestLineID = nil
      self.directQuestLineCollapsed = false
    elseif rowData.kind == "questline" and type(rowData.questLineID) == "number" then
      local inCampaignMode = type(rowData.campaignID) == "number" -- 是否战役上下文
      local inAchievementMode = type(rowData.achievementID) == "number" -- 是否成就上下文
      if inCampaignMode then
        self.selectedModeKey = "campaign"
      elseif inAchievementMode then
        self.selectedModeKey = "achievement"
      else
        self.selectedModeKey = "map_questline"
      end
      self.selectedCampaignID = inCampaignMode and rowData.campaignID or nil
      self.selectedAchievementID = inAchievementMode and rowData.achievementID or nil
      if type(rowData.campaignID) == "number" then
        self.selectedMapID = nil
      end
      if inAchievementMode then
        self.selectedMapID = nil
      end
      self.selectedTypeKey = ""
      self.expandedQuestLineID = rowData.questLineID
      self.directQuestLineCollapsed = false
    end
    self:hideQuestDetailPopup()
    self:saveSelection()
    self:requestRender()
  end)
  self.rowButtons[rowIndex] = rowButton
  return rowButton
end

local function buildQuestTooltip(detailObject, localeTable)
  if type(detailObject) ~= "table" or not GameTooltip then
    return
  end

  GameTooltip:SetOwner(UIParent, "ANCHOR_RIGHT")
  GameTooltip:ClearLines()
  GameTooltip:SetText(tostring(detailObject.name or ("Quest #" .. tostring(detailObject.questID or "?"))))
  if type(detailObject.questLineName) == "string" and detailObject.questLineName ~= "" then
    GameTooltip:AddLine(tostring(detailObject.questLineName))
  end
  if type(detailObject.UiMapID) == "number" then
    GameTooltip:AddLine(string.format("Map: %s", tostring(detailObject.UiMapID)))
  end
  if type(detailObject.status) == "string" then
    GameTooltip:AddLine(string.format("Status: %s", tostring(detailObject.status)))
  end
  if type(detailObject.typeID) == "number" then
    GameTooltip:AddLine(string.format("%s: %s", localeTable.EJ_QUEST_VIEW_TYPE or "类型", tostring(detailObject.typeID)))
  end
  GameTooltip:Show()
end

local function buildQuestDetailLines(detailObject, localeTable)
  local detailLines = {} -- 弹框详情文本行
  if type(detailObject) ~= "table" then
    detailLines[#detailLines + 1] = localeTable.EJ_QUEST_DATA_INVALID or "任务数据无效。"
    return detailLines
  end

  detailLines[#detailLines + 1] = string.format("ID: %s", tostring(detailObject.questID or ""))
  detailLines[#detailLines + 1] = string.format("%s: %s", localeTable.EJ_QUESTLINE_TREE_LABEL or "任务", tostring(detailObject.name or ""))
  if type(detailObject.questLineName) == "string" and detailObject.questLineName ~= "" then
    detailLines[#detailLines + 1] = string.format("%s: %s", localeTable.EJ_QUESTLINE_LIST_TITLE or "任务线", detailObject.questLineName)
  end
  if type(detailObject.UiMapID) == "number" then
    detailLines[#detailLines + 1] = string.format("Map: %s", tostring(detailObject.UiMapID))
  end
  if type(detailObject.typeID) == "number" then
    local typeText = tostring(detailObject.typeID) -- 类型显示文本
    if type(detailObject.typeLabel) == "string" and detailObject.typeLabel ~= "" then
      typeText = string.format("%s(%s)", detailObject.typeLabel, tostring(detailObject.typeID))
    end
    detailLines[#detailLines + 1] = string.format("%s: %s", localeTable.EJ_QUEST_VIEW_TYPE or "类型", typeText)
  end
  if type(detailObject.prerequisiteQuestIDs) == "table" and #detailObject.prerequisiteQuestIDs > 0 then
    detailLines[#detailLines + 1] = "Prerequisite: " .. table.concat(detailObject.prerequisiteQuestIDs, ", ")
  end
  if type(detailObject.nextQuestIDs) == "table" and #detailObject.nextQuestIDs > 0 then
    detailLines[#detailLines + 1] = "Next: " .. table.concat(detailObject.nextQuestIDs, ", ")
  end
  return detailLines
end

--- 构建任务详情上下文参数。
---@param questLineID number|nil
---@param mapID number|nil
---@param expansionID number|nil
---@return table|nil
local function buildQuestDetailContextOptions(questLineID, mapID, expansionID)
  local contextOptions = {} -- 详情上下文参数
  if type(questLineID) == "number" then
    contextOptions.questLineID = questLineID
  end
  if type(mapID) == "number" then
    contextOptions.mapID = mapID
  end
  if type(expansionID) == "number" then
    contextOptions.expansionID = expansionID
  end
  if next(contextOptions) == nil then
    return nil
  end
  return contextOptions
end

--- 在导航模型中按任务线反查资料片/战役定位。
---@param navigationModel table|nil 导航模型
---@param questLineID number|nil 任务线 ID
---@return number|nil expansionID
---@return number|nil campaignID
local function findCampaignSelectionByQuestLineID(navigationModel, questLineID)
  if type(navigationModel) ~= "table" or type(questLineID) ~= "number" then
    return nil, nil
  end

  for _, expansionSummary in ipairs(navigationModel.expansionList or {}) do
    local expansionID = type(expansionSummary) == "table" and expansionSummary.id or nil -- 当前资料片 ID
    local expansionEntry = type(expansionID) == "number" and navigationModel.expansionByID and navigationModel.expansionByID[expansionID] or nil -- 当前资料片对象
    local campaignMode = getCampaignModeEntry(expansionEntry) -- 当前资料片战役模式
    for _, campaignEntry in ipairs(campaignMode and campaignMode.entries or {}) do
      local campaignID = type(campaignEntry) == "table" and campaignEntry.id or nil -- 当前战役 ID
      for _, questLineEntry in ipairs(campaignEntry and campaignEntry.questLines or {}) do
        if type(questLineEntry) == "table" and questLineEntry.id == questLineID then
          return expansionID, campaignID
        end
      end
    end
  end

  return nil, nil
end

--- 计算主区任务行高度。
---@param baseRowHeight number
---@param rowData table|nil
---@return number
local function getQuestContentRowHeight(baseRowHeight, rowData)
  if type(rowData) ~= "table" then
    return baseRowHeight
  end
  if rowData.kind == "quest_detail" then
    return 110
  end
  if rowData.kind == "questline" then
    return baseRowHeight + 16
  end
  if (rowData.kind == "quest" or rowData.kind == "recent_quest")
    and rowData.showQuestLineName ~= false
    and type(rowData.questLineName) == "string"
    and rowData.questLineName ~= ""
  then
    return baseRowHeight + 16
  end
  return baseRowHeight
end

--- 构建行内展开详情行。
---@param questID number
---@param detailContext table|nil
---@return table
function QuestlineTreeView:buildInlineQuestDetailRow(questID, detailContext)
  local detailObject, detailError = AzerothCompanion.API.Questlines.GetQuestDetailByID(questID, detailContext) -- 当前任务详情
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  return {
    kind = "quest_detail",
    questID = questID,
    detailObject = detailError and nil or detailObject,
    detailText = table.concat(buildQuestDetailLines(detailObject, localeTable), "\n"),
  }
end

--- 若当前任务处于展开状态，则在其下追加详情行。
---@param rowDataList table
---@param questRowData table
function QuestlineTreeView:appendInlineQuestDetailRow(rowDataList, questRowData)
  if type(rowDataList) ~= "table" or type(questRowData) ~= "table" then
    return
  end
  if self.selectedQuestID ~= questRowData.questID then
    return
  end
  rowDataList[#rowDataList + 1] = self:buildInlineQuestDetailRow(questRowData.questID, questRowData.detailContext)
end

function QuestlineTreeView:getOrCreateRightRowButton(rowIndex, rowButtonList, scrollChild)
  local buttonList = type(rowButtonList) == "table" and rowButtonList or self.rightRowButtons -- 目标按钮缓存
  local targetScrollChild = scrollChild or self.rightScrollChild -- 目标滚动子容器
  local rowButton = buttonList[rowIndex] -- 主区行按钮
  if rowButton then
    return rowButton
  end
  rowButton = CreateFrame("Button", nil, targetScrollChild, "BackdropTemplate")
  rowButton:SetHeight(self.rowHeight)
  rowButton:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
  rowButton:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 10,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
  })
  rowButton:SetBackdropColor(0.09, 0.09, 0.11, 0.75)
  rowButton:SetBackdropBorderColor(0.28, 0.28, 0.3, 0.65)
  local progressTexture = rowButton:CreateTexture(nil, "BACKGROUND") -- 进度底色
  progressTexture:SetColorTexture(0.85, 0.64, 0.2, 0.2)
  progressTexture:SetPoint("TOPLEFT", rowButton, "TOPLEFT", 2, -2)
  progressTexture:SetPoint("BOTTOMLEFT", rowButton, "BOTTOMLEFT", 2, 2)
  progressTexture:SetWidth(0)
  progressTexture:Hide()
  rowButton.progressTexture = progressTexture
  local highlightTexture = rowButton:GetHighlightTexture() -- 高亮贴图
  if highlightTexture and highlightTexture.SetBlendMode then
    highlightTexture:SetBlendMode("ADD")
  end
  local rowFont = rowButton:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  rowFont:SetPoint("LEFT", rowButton, "LEFT", 8, 0)
  rowFont:SetPoint("RIGHT", rowButton, "RIGHT", -128, 0)
  rowFont:SetJustifyH("LEFT")
  rowFont:SetJustifyV("MIDDLE")
  rowButton.rowFont = rowFont
  local rowMetaFont = rowButton:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall") -- 行右侧信息
  rowMetaFont:SetPoint("RIGHT", rowButton, "RIGHT", -8, 0)
  rowMetaFont:SetWidth(156)
  rowMetaFont:SetJustifyH("RIGHT")
  rowMetaFont:SetJustifyV("MIDDLE")
  rowMetaFont:SetWordWrap(false)
  rowMetaFont:SetText("")
  rowButton.rowMetaFont = rowMetaFont
  local questLineFont = rowButton:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall") -- 任务线副标题
  questLineFont:SetJustifyH("LEFT")
  questLineFont:SetJustifyV("BOTTOM")
  questLineFont:SetTextColor(0.78, 0.74, 0.68)
  questLineFont:Hide()
  rowButton.questLineFont = questLineFont
  local detailText = rowButton:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall") -- 行内详情文本
  detailText:SetJustifyH("LEFT")
  detailText:SetJustifyV("TOP")
  detailText:SetWordWrap(true)
  detailText:Hide()
  rowButton.detailText = detailText
  local jumpActionButton = CreateFrame("Button", nil, rowButton, "UIPanelButtonTemplate") -- 行内跳转按钮
  jumpActionButton:SetSize(180, 20)
  jumpActionButton:SetScript("OnClick", function(button)
    local detailRowData = button.detailRowData -- 当前行内详情数据
    local detailObject = type(detailRowData) == "table" and detailRowData.detailObject or nil -- 当前详情对象
    if type(detailObject) ~= "table" then
      return
    end
    local resolvedExpansionID = nil -- 反查得到的资料片 ID
    local resolvedCampaignID = nil -- 反查得到的战役 ID
    if type(detailObject.questLineID) == "number"
      and AzerothCompanion.API.Questlines
      and type(AzerothCompanion.API.Questlines.GetQuestNavigationModel) == "function"
    then
      local navigationModel = select(1, AzerothCompanion.API.Questlines.GetQuestNavigationModel()) -- 当前导航模型
      resolvedExpansionID, resolvedCampaignID = findCampaignSelectionByQuestLineID(navigationModel, detailObject.questLineID)
    end
    if type(resolvedExpansionID) == "number" then
      self.selectedExpansionID = resolvedExpansionID
    elseif type(detailObject.questLineExpansionID) == "number" then
      self.selectedExpansionID = detailObject.questLineExpansionID
    end
    if type(resolvedCampaignID) == "number" then
      self.selectedModeKey = "campaign"
      self.selectedCampaignID = resolvedCampaignID
      self.selectedAchievementID = nil
      self.selectedMapID = nil
    elseif type(detailObject.UiMapID) == "number" then
      self.selectedModeKey = "map_questline"
      self.selectedCampaignID = nil
      self.selectedAchievementID = nil
      self.selectedMapID = detailObject.UiMapID
    else
      self.selectedModeKey = "map_questline"
      self.selectedCampaignID = nil
      self.selectedAchievementID = nil
      self.selectedMapID = nil
    end
    if type(detailObject.questLineID) == "number" then
      self.expandedQuestLineID = detailObject.questLineID
      self.directQuestLineCollapsed = false
    end
    self.selectedTypeKey = ""
    self:hideQuestDetailPopup()
    self:saveSelection()
    self:requestRender()
  end)
  jumpActionButton:Hide()
  rowButton.jumpActionButton = jumpActionButton
  rowButton:SetScript("OnClick", function(button)
    local rowData = button.rowData -- 当前行数据
    if type(rowData) ~= "table" then
      return
    end
    if rowData.kind == "questline" and type(rowData.questLineID) == "number" then
      if self.expandedQuestLineID == rowData.questLineID then
        if type(self.selectedMapID) == "number" then
          self.expandedQuestLineID = nil
          self.directQuestLineCollapsed = false
        else
          self.directQuestLineCollapsed = self.directQuestLineCollapsed ~= true
        end
      else
        self.expandedQuestLineID = rowData.questLineID
        self.directQuestLineCollapsed = false
      end
      self:hideQuestDetailPopup()
      self:saveSelection()
      self:requestRender()
      return
    end
    if (rowData.kind == "quest" or rowData.kind == "recent_quest") and type(rowData.questID) == "number" then
      if self.selectedQuestID == rowData.questID then
        self.selectedQuestID = nil
      else
        self.selectedQuestID = rowData.questID
      end
      self:hideQuestDetailPopup()
      self:saveSelection()
      self:requestRender()
    end
  end)
  buttonList[rowIndex] = rowButton
  return rowButton
end

local function buildQuestStatusKey(statusText, readyForTurnIn)
  if readyForTurnIn == true then
    return "ready"
  end
  if statusText == "completed" then
    return "completed"
  end
  if statusText == "active" then
    return "active"
  end
  return "pending"
end

local function getQuestStatusRank(statusKey)
  if statusKey == "ready" then
    return 1
  end
  if statusKey == "active" then
    return 2
  end
  if statusKey == "pending" then
    return 3
  end
  return 4
end

local function buildQuestlineMetaText(progressInfo, localeTable)
  if type(progressInfo) ~= "table" then
    return ""
  end
  if progressInfo.isCompleted == true then
    return localeTable.EJ_QUEST_STATUS_COMPLETED or "Completed"
  end
  return ""
end

function QuestlineTreeView:buildMainRowsForMap()
  local rowDataList = {} -- 地图模式主区行
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  local searchKeyword = normalizeSearchText(self.searchText) -- 搜索关键词
  local useCampaignSelection = self.selectedModeKey == "campaign" and type(self.selectedCampaignID) == "number" -- 当前是否战役任务线模式
  local useAchievementSelection = self.selectedModeKey == "achievement" and type(self.selectedAchievementID) == "number" -- 当前是否成就任务线模式
  local questLineList = nil -- 当前主区任务线列表
  if type(self.selectedMapID) == "number" and not useCampaignSelection and not useAchievementSelection then
    local errorObject = nil -- 地图查询错误
    questLineList, errorObject = AzerothCompanion.API.Questlines.GetQuestLinesForMap(self.selectedMapID, self.selectedExpansionID) -- 当前资料片地图下任务线
    if errorObject then
      return {}, errorObject
    end
  elseif useAchievementSelection then
    local errorObject = nil -- 成就查询错误
    questLineList, errorObject = AzerothCompanion.API.Questlines.GetQuestLinesForAchievement(self.selectedAchievementID, self.selectedExpansionID) -- 当前成就下任务线
    if errorObject then
      return {}, errorObject
    end
  elseif type(self.expandedQuestLineID) == "number" then
    local questTabModel, errorObject = AzerothCompanion.API.Questlines.GetQuestTabModel() -- 任务页签模型
    if errorObject then
      return {}, errorObject
    end
    local questLineEntry = questTabModel and questTabModel.questLineByID and questTabModel.questLineByID[self.expandedQuestLineID] or nil -- 当前直接任务线
    if type(questLineEntry) == "table" then
      questLineList = { questLineEntry }
    else
      questLineList = {}
    end
  else
    questLineList = {}
  end

  for _, questLineEntry in ipairs(questLineList or {}) do
    local questLineID = questLineEntry.id -- 当前任务线 ID
    local questLineName = resolveQuestLineDisplayName(questLineEntry) or ("QuestLine #" .. tostring(questLineID or "?")) -- 任务线显示名
    local progressInfo, progressError = AzerothCompanion.API.Questlines.GetQuestLineProgress(questLineID) -- 任务线进度
    local progressText = not progressError and formatProgressText(progressInfo, localeTable) or nil -- 进度文本
    local shouldQueryQuestList = useCampaignSelection
      or self.expandedQuestLineID == questLineID
      or searchKeyword ~= "" -- 是否需要查询任务列表
    local questList = nil -- 任务线下任务列表
    if shouldQueryQuestList then
      local listError = nil -- 任务列表查询错误
      questList, listError = AzerothCompanion.API.Questlines.GetQuestListByQuestLineID(questLineID)
      if listError then
        return {}, listError
      end
    end

    local matchQuestRows = {} -- 搜索命中的任务行
    local hasQuestMatch = false -- 当前任务线是否命中任务名
    for _, questEntry in ipairs(questList or {}) do
      local questTypeID = questEntry.typeID -- 当前任务类型 ID
      local canDisplayQuest = shouldDisplayQuestByTypeID(questTypeID) -- 当前任务是否允许显示
      local questName = tostring(questEntry.name or ("Quest #" .. tostring(questEntry.id or "?"))) -- 任务显示名
      local questMatched = searchKeyword == "" or textContainsKeyword(questName, searchKeyword) -- 任务名是否匹配搜索
      if canDisplayQuest and questMatched then
        hasQuestMatch = true
        local statusKey = buildQuestStatusKey(questEntry.status, questEntry.readyForTurnIn) -- 任务状态键
        local questMapID = type(self.selectedMapID) == "number" and self.selectedMapID or questLineEntry.UiMapID -- 当前任务地图 ID
        matchQuestRows[#matchQuestRows + 1] = {
          kind = "quest",
          text = questName,
          questID = questEntry.id,
          questLineName = type(questEntry.questLineName) == "string" and questEntry.questLineName or questLineName,
          showQuestLineName = false,
          status = statusKey,
          readyForTurnIn = questEntry.readyForTurnIn,
          selected = self.selectedQuestID == questEntry.id,
          detailContext = buildQuestDetailContextOptions(questLineID, questMapID, self.selectedExpansionID),
        }
      end
    end

    local questLineMatched = searchKeyword == "" or textContainsKeyword(questLineName, searchKeyword) -- 任务线名是否匹配搜索
    if searchKeyword == "" or questLineMatched or hasQuestMatch then
      if useCampaignSelection then
        local sectionText = questLineName -- 战役视图标题文本
        if type(progressText) == "string" then
          sectionText = string.format("%s  %s", sectionText, progressText)
        end
        if type(questLineEntry.questCount) == "number" then
          sectionText = string.format("%s · " .. (localeTable.EJ_QUEST_CARD_QUEST_COUNT_FMT or "%d quests"), sectionText, questLineEntry.questCount)
        end
        rowDataList[#rowDataList + 1] = {
          kind = "section_header",
          text = sectionText,
          metaText = buildQuestlineMetaText(progressInfo, localeTable),
        }
        if #matchQuestRows == 0 then
          rowDataList[#rowDataList + 1] = {
            kind = "section_empty",
            text = localeTable.EJ_QUEST_FILTER_EMPTY or "当前筛选下没有可显示的任务。",
          }
        else
          for _, questRow in ipairs(matchQuestRows) do
            rowDataList[#rowDataList + 1] = questRow
            self:appendInlineQuestDetailRow(rowDataList, questRow)
          end
        end
      else
        local isDirectQuestLineContext = type(self.selectedMapID) ~= "number"
          and self.expandedQuestLineID == questLineID -- 当前是否处于直连任务线上下文
        local shouldExpand = ((self.expandedQuestLineID == questLineID)
          and not (isDirectQuestLineContext and self.directQuestLineCollapsed == true))
          or (searchKeyword ~= "" and hasQuestMatch) -- 当前任务线是否展开
        local linePrefix = shouldExpand and "[-]" or "[+]" -- 展开前缀
        local lineText = string.format("%s %s", linePrefix, questLineName) -- 任务线主文本
        if type(progressText) == "string" then
          lineText = string.format("%s  %s", lineText, progressText)
        end
        if type(questLineEntry.questCount) == "number" then
          lineText = string.format("%s · " .. (localeTable.EJ_QUEST_CARD_QUEST_COUNT_FMT or "%d quests"), lineText, questLineEntry.questCount)
        end

        rowDataList[#rowDataList + 1] = {
          kind = "questline",
          text = lineText,
          questLineID = questLineID,
          selected = shouldExpand,
          progressInfo = progressInfo,
          metaText = buildQuestlineMetaText(progressInfo, localeTable),
        }

        if shouldExpand then
          for _, questRow in ipairs(matchQuestRows) do
            rowDataList[#rowDataList + 1] = questRow
            self:appendInlineQuestDetailRow(rowDataList, questRow)
          end
        end
      end
    end
  end

  if useCampaignSelection and #rowDataList == 0 then
    if type(self.expandedQuestLineID) == "number" then
      rowDataList[#rowDataList + 1] = {
        kind = "section_empty",
        text = localeTable.EJ_QUEST_FILTER_EMPTY or "当前筛选下没有可显示的任务。",
      }
    else
      rowDataList[#rowDataList + 1] = {
        kind = "section_empty",
        text = localeTable.EJ_QUEST_CAMPAIGN_QUESTLINE_EMPTY or "请在左侧选择任务线后查看任务列表。",
      }
    end
  end
  if useAchievementSelection and #rowDataList == 0 then
    rowDataList[#rowDataList + 1] = {
      kind = "section_empty",
      text = localeTable.EJ_QUEST_ACHIEVEMENT_QUESTLINE_EMPTY or "请先在左侧选择成就后查看任务线列表。",
    }
  end

  return rowDataList, nil
end

function QuestlineTreeView:buildRecentCompletedRows()
  local rowDataList = {} -- 最近完成行
  local searchKeyword = normalizeSearchText(self.searchText) -- 搜索关键词
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  local recentCompletedList = getRecentCompletedQuestList() -- 最近完成任务列表
  local recentMatchCount = 0 -- 最近完成命中条数
  for _, recentEntry in ipairs(recentCompletedList) do
    local recentQuestName = tostring(recentEntry.questName or ("Quest #" .. tostring(recentEntry.questID or "?"))) -- 最近完成任务显示名
    local questMatched = searchKeyword == "" or textContainsKeyword(recentQuestName, searchKeyword) -- 最近完成任务名是否匹配搜索
    if questMatched then
      local detailObject, detailError = AzerothCompanion.API.Questlines.GetQuestDetailByID(recentEntry.questID) -- 最近完成任务详情
      if detailError then
        detailObject = nil
      end
      local recentTypeID = type(detailObject) == "table" and detailObject.typeID or nil -- 最近完成任务类型 ID
      local canDisplayRecent = shouldDisplayQuestByTypeID(recentTypeID) -- 最近完成任务是否允许显示
      if canDisplayRecent then
        recentMatchCount = recentMatchCount + 1
        rowDataList[#rowDataList + 1] = {
          kind = "recent_quest",
          text = recentQuestName,
          questID = recentEntry.questID,
          questLineName = type(detailObject) == "table" and detailObject.questLineName or nil,
          status = "completed",
          readyForTurnIn = false,
          selected = self.selectedQuestID == recentEntry.questID,
          metaText = formatCompletedAtText(recentEntry.completedAt),
          detailContext = buildQuestDetailContextOptions(
            type(detailObject) == "table" and detailObject.questLineID or nil,
            type(detailObject) == "table" and detailObject.UiMapID or nil,
            type(detailObject) == "table" and detailObject.questLineExpansionID or nil
          ),
        }
        self:appendInlineQuestDetailRow(rowDataList, rowDataList[#rowDataList])
      end
    end
  end
  if recentMatchCount == 0 then
    rowDataList[#rowDataList + 1] = {
      kind = "section_empty",
      text = localeTable.EJ_QUEST_RECENT_COMPLETED_EMPTY or "No recently completed quests.",
    }
  end
  return rowDataList, nil
end

function QuestlineTreeView:buildCurrentQuestRows()
  local rowDataList = {} -- 当前任务行
  local searchKeyword = normalizeSearchText(self.searchText) -- 搜索关键词
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  local questEntryList, errorObject = AzerothCompanion.API.Questlines.GetCurrentQuestLogEntries() -- 当前任务日志条目
  if errorObject then
    return {}, errorObject
  end

  local activeQuestRows = {} -- 当前任务行列表
  for _, questEntry in ipairs(questEntryList or {}) do
    local detailContext = buildQuestDetailContextOptions(
      questEntry.questLineID,
      questEntry.UiMapID,
      questEntry.questLineExpansionID
    ) -- 当前任务详情查询上下文
    local resolvedTypeID = questEntry.typeID -- 当前任务可用类型 ID
    local canDisplayQuest = shouldDisplayQuestByTypeID(resolvedTypeID) -- 当前任务是否允许显示
    local questName = tostring(questEntry.name or ("Quest #" .. tostring(questEntry.questID or "?"))) -- 任务显示名
    if canDisplayQuest and (searchKeyword == "" or textContainsKeyword(questName, searchKeyword)) then
      activeQuestRows[#activeQuestRows + 1] = {
        kind = "quest",
        text = questName,
        questID = questEntry.questID,
        questLineName = questEntry.questLineName,
        status = buildQuestStatusKey(questEntry.status, questEntry.readyForTurnIn),
        readyForTurnIn = questEntry.readyForTurnIn,
        selected = self.selectedQuestID == questEntry.questID,
        detailContext = detailContext,
      }
    end
  end

  table.sort(activeQuestRows, function(leftRow, rightRow)
    local leftRank = getQuestStatusRank(leftRow.status) -- 左侧状态排序权重
    local rightRank = getQuestStatusRank(rightRow.status) -- 右侧状态排序权重
    if leftRank ~= rightRank then
      return leftRank < rightRank
    end
    return tostring(leftRow.text or "") < tostring(rightRow.text or "")
  end)

  if #activeQuestRows == 0 then
    rowDataList[#rowDataList + 1] = {
      kind = "section_empty",
      text = localeTable.EJ_QUEST_ACTIVE_EMPTY or "No active quests in the quest log.",
    }
  else
    for _, activeQuestRow in ipairs(activeQuestRows) do
      rowDataList[#rowDataList + 1] = activeQuestRow
      self:appendInlineQuestDetailRow(rowDataList, activeQuestRow)
    end
  end

  return rowDataList, nil
end

function QuestlineTreeView:renderLeftRows(rowDataList)
  local scrollWidth = self.scrollFrame:GetWidth() -- 左树宽度
  if type(scrollWidth) ~= "number" or scrollWidth <= 0 then
    scrollWidth = 230
  end
  local rowWidth = math.max(150, scrollWidth - 24) -- 行宽
  local rowOffsetY = 6 -- 顶部留白
  local currentOffsetY = rowOffsetY -- 当前累计偏移
  local rowIndex = 0 -- 行索引
  for _, rowData in ipairs(rowDataList or {}) do
    rowIndex = rowIndex + 1
    local rowButton = self:getOrCreateRowButton(rowIndex) -- 当前左树行按钮
    rowButton.rowData = rowData
    rowButton:ClearAllPoints()
    rowButton:SetPoint("TOPLEFT", self.scrollChild, "TOPLEFT", 6, -currentOffsetY)
    rowButton:SetWidth(rowWidth)
    local rowHeight = rowData.kind == "expansion" and (self.rowHeight + VIEW_STYLE.expansionExtraHeight) or self.rowHeight -- 当前行高度
    rowButton:SetHeight(rowHeight)
    local indentLevel = 0 -- 缩进层级
    if rowData.kind == "campaign" then
      indentLevel = 1
    elseif rowData.kind == "achievement" then
      indentLevel = 1
    elseif rowData.kind == "map" then
      indentLevel = 1
    elseif rowData.kind == "questline" then
      if type(rowData.campaignID) == "number" then
        indentLevel = 2
      else
        indentLevel = 1
      end
    elseif rowData.kind == "mode" then
      indentLevel = 1
    end
    local rowText = tostring(rowData.text or "") -- 行完整文本
    local displayText = string.rep("  ", indentLevel) .. rowText -- 含缩进的显示文本
    rowButton.leftRowTooltipText = rowText
    rowButton.rowFont:SetText(displayText)
    if rowData.selected == true then
      rowButton.rowFont:SetTextColor(0.35, 0.85, 1)
      rowButton:SetBackdropBorderColor(0.86, 0.68, 0.28, 0.95)
      rowButton:SetBackdropColor(0.2, 0.16, 0.1, 0.88)
    elseif rowData.kind == "expansion" then
      rowButton.rowFont:SetTextColor(1.0, 0.9, 0.68)
      rowButton:SetBackdropBorderColor(0.48, 0.4, 0.24, 0.65)
      rowButton:SetBackdropColor(0.14, 0.11, 0.08, 0.78)
    elseif rowData.kind == "mode" then
      rowButton.rowFont:SetTextColor(0.9, 0.85, 0.72)
      rowButton:SetBackdropBorderColor(0.34, 0.3, 0.22, 0.55)
      rowButton:SetBackdropColor(0.11, 0.1, 0.09, 0.7)
    elseif rowData.kind == "campaign" then
      rowButton.rowFont:SetTextColor(0.9, 0.85, 0.72)
      rowButton:SetBackdropBorderColor(0.36, 0.31, 0.2, 0.6)
      rowButton:SetBackdropColor(0.12, 0.1, 0.08, 0.72)
    elseif rowData.kind == "achievement" then
      rowButton.rowFont:SetTextColor(0.9, 0.85, 0.72)
      rowButton:SetBackdropBorderColor(0.36, 0.31, 0.2, 0.6)
      rowButton:SetBackdropColor(0.12, 0.1, 0.08, 0.72)
    else
      rowButton.rowFont:SetTextColor(1, 1, 1)
      rowButton:SetBackdropBorderColor(0.3, 0.3, 0.32, 0.5)
      rowButton:SetBackdropColor(0.1, 0.1, 0.12, 0.68)
    end
    rowButton:Show()
    currentOffsetY = currentOffsetY + rowHeight + VIEW_STYLE.leftRowGap
  end
  for hideIndex = rowIndex + 1, #self.rowButtons do
    local hiddenRowButton = self.rowButtons[hideIndex] -- 待隐藏行按钮
    hiddenRowButton:Hide()
    hideLeftRowOverflowTooltip(hiddenRowButton)
  end
  local contentHeight = math.max(currentOffsetY + 4, 10) -- 左树内容高度
  self.scrollChild:SetSize(rowWidth, contentHeight)
  return contentHeight
end

local function buildQuestContentRowLayoutList(viewObject, rowDataList)
  local layoutList = {} -- 行布局列表
  local currentOffsetY = 6 -- 当前累计偏移
  for rowIndex, rowData in ipairs(rowDataList or {}) do
    local rowHeight = getQuestContentRowHeight(viewObject.rowHeight, rowData) -- 当前行高度
    layoutList[#layoutList + 1] = {
      rowIndex = rowIndex,
      rowData = rowData,
      rowHeight = rowHeight,
      offsetY = currentOffsetY,
    }
    currentOffsetY = currentOffsetY + rowHeight + VIEW_STYLE.rightRowGap
  end
  return layoutList, math.max(currentOffsetY + 4, 10)
end

local function getQuestRowRenderFrameHeight(scrollFrame)
  local frameHeight = type(scrollFrame.GetHeight) == "function" and tonumber(scrollFrame:GetHeight()) or nil -- 当前滚动框高度
  if type(frameHeight) == "number" and frameHeight > 0 then
    return frameHeight
  end
  return 220
end

local function collectVisibleQuestContentLayouts(scrollFrame, layoutList, contentHeight)
  local frameHeight = getQuestRowRenderFrameHeight(scrollFrame) -- 当前滚动框高度
  local maxOffset = math.max(0, (tonumber(contentHeight) or 0) - frameHeight) -- 当前允许的最大偏移
  local effectiveScrollOffset = math.min(readVerticalScrollOffset(scrollFrame), maxOffset) -- 当前用于布局的滚动偏移
  local overscanHeight = 84 -- 上下预渲染高度
  local visibleTop = math.max(0, effectiveScrollOffset - overscanHeight) -- 可见区域顶部
  local visibleBottom = effectiveScrollOffset + frameHeight + overscanHeight -- 可见区域底部
  local visibleLayoutList = {} -- 可见布局列表

  for _, rowLayout in ipairs(layoutList) do
    local rowTop = rowLayout.offsetY -- 当前行顶部
    local rowBottom = rowLayout.offsetY + rowLayout.rowHeight -- 当前行底部
    if rowBottom >= visibleTop and rowTop <= visibleBottom then
      visibleLayoutList[#visibleLayoutList + 1] = rowLayout
    end
  end

  if #visibleLayoutList == 0 and #layoutList > 0 then
    visibleLayoutList[1] = layoutList[1]
  end

  return visibleLayoutList
end

function QuestlineTreeView:renderRowList(scrollFrame, scrollChild, rowButtonList, rowDataList)
  local scrollWidth = scrollFrame:GetWidth() -- 主区宽度
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  if type(scrollWidth) ~= "number" or scrollWidth <= 0 then
    scrollWidth = 520
  end
  local rowWidth = math.max(200, scrollWidth - 24) -- 行宽
  local layoutList, contentHeight = buildQuestContentRowLayoutList(self, rowDataList) -- 当前内容布局
  local visibleLayoutList = collectVisibleQuestContentLayouts(scrollFrame, layoutList, contentHeight) -- 当前可见布局
  local visibleButtonCount = 0 -- 当前使用的按钮数量

  if scrollFrame and not scrollFrame._azerothCompanionQuestRowListHooked and scrollFrame.SetScript then
    scrollFrame._azerothCompanionQuestRowListHooked = true
    scrollFrame:SetScript("OnVerticalScroll", function(frameObject, scrollOffset)
      frameObject:SetVerticalScroll(scrollOffset)
      local refreshVisibleRows = frameObject._azerothCompanionRefreshVisibleRows -- 当前滚动区可见行刷新函数
      if type(refreshVisibleRows) == "function" and frameObject._azerothCompanionRenderingRows ~= true then
        refreshVisibleRows()
      end
    end)
  end

  scrollFrame._azerothCompanionRefreshVisibleRows = function()
    if scrollFrame._azerothCompanionRenderingRows == true then
      return
    end
    scrollFrame._azerothCompanionRenderingRows = true
    self:renderRowList(scrollFrame, scrollChild, rowButtonList, rowDataList)
    scrollFrame._azerothCompanionRenderingRows = false
  end

  for _, rowLayout in ipairs(visibleLayoutList) do
    local rowData = rowLayout.rowData -- 当前行数据
    local rowHeight = rowLayout.rowHeight -- 当前行高度
    visibleButtonCount = visibleButtonCount + 1
    local rowButton = self:getOrCreateRightRowButton(visibleButtonCount, rowButtonList, scrollChild) -- 当前主区行按钮
    rowButton.rowData = rowData
    rowButton._azerothCompanionRowIndex = rowLayout.rowIndex
    rowButton:ClearAllPoints()
    rowButton:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 6, -rowLayout.offsetY)
    rowButton:SetWidth(rowWidth)
    rowButton:SetHeight(rowHeight)

    if rowButton.rowFont and rowButton.rowFont.ClearAllPoints then
      rowButton.rowFont:ClearAllPoints()
    end
    if rowButton.rowMetaFont and rowButton.rowMetaFont.ClearAllPoints then
      rowButton.rowMetaFont:ClearAllPoints()
    end
    if rowButton.questLineFont then
      rowButton.questLineFont:Hide()
      if rowButton.questLineFont.ClearAllPoints then
        rowButton.questLineFont:ClearAllPoints()
      end
      rowButton.questLineFont:SetText("")
    end
    if rowButton.detailText then
      rowButton.detailText:Hide()
      if rowButton.detailText.ClearAllPoints then
        rowButton.detailText:ClearAllPoints()
      end
      rowButton.detailText:SetText("")
    end
    if rowButton.jumpActionButton then
      rowButton.jumpActionButton:Hide()
      rowButton.jumpActionButton.detailRowData = nil
    end
    local indentLevel = (rowData.kind == "quest" or rowData.kind == "recent_quest") and 1 or 0 -- 任务缩进
    local statusPrefix = (rowData.kind == "quest" or rowData.kind == "recent_quest")
      and formatQuestStatusPrefix(rowData.status)
      or "" -- 任务状态前缀
    if rowData.kind == "quest_detail" then
      rowButton.rowFont:SetPoint("TOPLEFT", rowButton, "TOPLEFT", 8, -6)
      rowButton.rowFont:SetPoint("TOPRIGHT", rowButton, "TOPRIGHT", -8, -6)
      rowButton.rowFont:SetText("")
      if rowButton.rowMetaFont then
        rowButton.rowMetaFont:SetPoint("RIGHT", rowButton, "RIGHT", -8, 0)
        rowButton.rowMetaFont:SetText("")
      end
      if rowButton.detailText then
        rowButton.detailText:SetPoint("TOPLEFT", rowButton, "TOPLEFT", 10, -10)
        rowButton.detailText:SetPoint("TOPRIGHT", rowButton, "TOPRIGHT", -10, -10)
        rowButton.detailText:SetText(tostring(rowData.detailText or ""))
        rowButton.detailText:Show()
      end
      local detailObject = rowData.detailObject -- 行内详情对象
      if rowButton.jumpActionButton then
        local canJump = type(detailObject) == "table"
          and type(detailObject.questLineID) == "number"
          and type(detailObject.UiMapID) == "number" -- 是否显示跳转按钮
        rowButton.jumpActionButton.detailRowData = rowData
        rowButton.jumpActionButton:SetPoint("BOTTOMLEFT", rowButton, "BOTTOMLEFT", 10, 8)
        rowButton.jumpActionButton:SetText(localeTable.EJ_QUEST_JUMP_TO_QUESTLINE or "跳转到对应战役/任务线")
        rowButton.jumpActionButton:SetShown(canJump)
      end
    else
      local rowText = statusPrefix ~= ""
        and (string.rep("  ", indentLevel) .. statusPrefix .. " " .. tostring(rowData.text or ""))
        or (string.rep("  ", indentLevel) .. tostring(rowData.text or "")) -- 当前行主文本
      if (rowData.kind == "quest" or rowData.kind == "recent_quest")
        and rowData.showQuestLineName ~= false
        and rowButton.questLineFont
        and type(rowData.questLineName) == "string"
        and rowData.questLineName ~= ""
      then
        rowButton.rowFont:SetPoint("TOPLEFT", rowButton, "TOPLEFT", 8, -4)
        rowButton.rowFont:SetPoint("TOPRIGHT", rowButton, "TOPRIGHT", -128, -4)
        rowButton.questLineFont:SetPoint("BOTTOMLEFT", rowButton, "BOTTOMLEFT", 24, 4)
        rowButton.questLineFont:SetPoint("BOTTOMRIGHT", rowButton, "BOTTOMRIGHT", -128, 4)
        rowButton.questLineFont:SetText(tostring(rowData.questLineName))
        rowButton.questLineFont:Show()
      else
        rowButton.rowFont:SetPoint("LEFT", rowButton, "LEFT", 8, 0)
        rowButton.rowFont:SetPoint("RIGHT", rowButton, "RIGHT", -128, 0)
      end
      rowButton.rowFont:SetText(rowText)
      if rowButton.rowMetaFont then
        rowButton.rowMetaFont:SetPoint("RIGHT", rowButton, "RIGHT", -8, 0)
      end
    end

    if rowData.kind == "section_header" then
      rowButton.rowFont:SetTextColor(1.0, 0.9, 0.68)
      rowButton:SetBackdropBorderColor(0.5, 0.4, 0.22, 0.7)
      rowButton:SetBackdropColor(0.15, 0.11, 0.07, 0.78)
    elseif rowData.kind == "quest_detail" then
      rowButton.rowFont:SetTextColor(0.95, 0.9, 0.78)
      rowButton:SetBackdropBorderColor(0.68, 0.54, 0.28, 0.82)
      rowButton:SetBackdropColor(0.11, 0.09, 0.06, 0.9)
    elseif rowData.kind == "section_empty" then
      rowButton.rowFont:SetTextColor(0.7, 0.7, 0.74)
      rowButton:SetBackdropBorderColor(0.32, 0.32, 0.34, 0.46)
      rowButton:SetBackdropColor(0.09, 0.09, 0.11, 0.62)
    elseif rowData.selected == true then
      rowButton.rowFont:SetTextColor(0.35, 0.85, 1)
      rowButton:SetBackdropBorderColor(0.86, 0.68, 0.28, 0.95)
      rowButton:SetBackdropColor(0.2, 0.16, 0.1, 0.88)
    else
      local colorR, colorG, colorB = getQuestStatusTextColor(rowData.status) -- 状态文本颜色
      if type(colorR) == "number" then
        rowButton.rowFont:SetTextColor(colorR, colorG, colorB)
      else
        rowButton.rowFont:SetTextColor(1, 1, 1)
      end
      if rowData.kind == "questline" then
        rowButton:SetBackdropBorderColor(0.52, 0.4, 0.2, 0.82)
        rowButton:SetBackdropColor(0.13, 0.1, 0.08, 0.82)
      else
        rowButton:SetBackdropBorderColor(0.3, 0.3, 0.34, 0.52)
        rowButton:SetBackdropColor(0.1, 0.1, 0.12, 0.7)
      end
    end

    if rowButton.rowMetaFont then
      local metaText = (rowData.kind == "section_header" or rowData.kind == "quest_detail") and "" or tostring(rowData.metaText or "")
      rowButton.rowMetaFont:SetText(metaText)
      if rowData.kind == "questline" then
        rowButton.rowMetaFont:SetTextColor(0.95, 0.88, 0.6)
      elseif rowData.kind == "recent_quest" then
        rowButton.rowMetaFont:SetTextColor(0.88, 0.82, 0.65)
      elseif rowData.kind == "quest_detail" then
        rowButton.rowMetaFont:SetTextColor(0.95, 0.88, 0.6)
      else
        rowButton.rowMetaFont:SetTextColor(0.72, 0.72, 0.76)
      end
    end

    if rowButton.progressTexture then
      local progressInfo = rowData.progressInfo -- 当前行进度信息
      local totalCount = type(progressInfo) == "table" and tonumber(progressInfo.total) or nil -- 总任务数
      local completedCount = type(progressInfo) == "table" and tonumber(progressInfo.completed) or nil -- 已完成数
      if rowData.kind == "questline" and type(totalCount) == "number" and totalCount > 0 and type(completedCount) == "number" then
        local ratio = math.max(0, math.min(1, completedCount / totalCount)) -- 进度比例
        rowButton.progressTexture:SetWidth(math.max(0, (rowWidth - 4) * ratio))
        rowButton.progressTexture:Show()
      else
        rowButton.progressTexture:Hide()
      end
    end

    rowButton:Show()
  end

  for hideIndex = visibleButtonCount + 1, #rowButtonList do
    rowButtonList[hideIndex]:Hide()
  end

  scrollChild:SetSize(rowWidth, contentHeight)
  scrollFrame:SetShown(#layoutList > 0)
  return contentHeight
end

function QuestlineTreeView:renderRightRows(rowDataList)
  return self:renderRowList(self.rightScrollFrame, self.rightScrollChild, self.rightRowButtons, rowDataList)
end

function QuestlineTreeView:updateActiveLogPanelTitles(currentRows, recentRows)
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  local currentCount = 0 -- 当前任务条数
  local recentCount = 0 -- 最近完成条数

  for _, rowData in ipairs(currentRows or {}) do
    if type(rowData) == "table" and rowData.kind == "quest" then
      currentCount = currentCount + 1
    end
  end
  for _, rowData in ipairs(recentRows or {}) do
    if type(rowData) == "table" and rowData.kind == "recent_quest" then
      recentCount = recentCount + 1
    end
  end

  if self.activeLogCurrentTitle then
    self.activeLogCurrentTitle:SetText(string.format(
      localeTable.EJ_QUEST_ACTIVE_SECTION_COUNT_FMT or "Current Quests (%d)",
      currentCount
    ))
  end
  if self.activeLogRecentTitle then
    self.activeLogRecentTitle:SetText(string.format(
      localeTable.EJ_QUEST_RECENT_COMPLETED_COUNT_FMT or "Recently Completed (%d)",
      recentCount
    ))
  end
  if self.activeLogRecentToggleButton then
    self.activeLogRecentToggleButton:SetText(getRecentCompletedToggleText(localeTable, self.activeLogRecentCollapsed))
  end
end

function QuestlineTreeView:renderActiveLogPanels()
  local currentRows, currentError = self:buildCurrentQuestRows() -- 当前任务行
  if currentError then
    return nil, currentError
  end
  local recentRows, recentError = self:buildRecentCompletedRows() -- 最近完成行
  if recentError then
    return nil, recentError
  end

  self:updateActiveLogPanelTitles(currentRows, recentRows)
  local currentHeight = self:renderRowList(
    self.activeLogCurrentScrollFrame,
    self.activeLogCurrentScrollChild,
    self.activeLogCurrentRowButtons,
    currentRows
  ) -- 当前任务区内容高度

  if self.activeLogRecentCollapsed == true then
    if self.activeLogRecentScrollFrame then
      self.activeLogRecentScrollFrame:Hide()
    end
    if self.activeLogRecentScrollChild then
      self.activeLogRecentScrollChild:SetSize(10, 10)
    end
    self:hideRowButtonList(self.activeLogRecentRowButtons)
    return {
      currentHeight = currentHeight,
      recentHeight = 0,
      currentRows = currentRows,
      recentRows = recentRows,
    }, nil
  end

  local recentHeight = self:renderRowList(
    self.activeLogRecentScrollFrame,
    self.activeLogRecentScrollChild,
    self.activeLogRecentRowButtons,
    recentRows
  ) -- 最近完成区内容高度

  return {
    currentHeight = currentHeight,
    recentHeight = recentHeight,
    currentRows = currentRows,
    recentRows = recentRows,
  }, nil
end

function QuestlineTreeView:hideQuestDetailPopup()
  if self.detailPopupFrame then
    self.detailPopupFrame:Hide()
  end
  if self.detailPopupActiveButton then
    self.detailPopupActiveButton:Hide()
  end
end

function QuestlineTreeView:showQuestDetailPopup(questID)
  local detailObject, detailError = AzerothCompanion.API.Questlines.GetQuestDetailByID(questID) -- 任务详情
  if detailError or type(detailObject) ~= "table" then
    return
  end
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  if self.detailPopupTitle then
    self.detailPopupTitle:SetText(localeTable.EJ_QUEST_DETAIL_TITLE or "任务详情")
  end
  if self.detailPopupText then
    self.detailPopupText:SetText(table.concat(buildQuestDetailLines(detailObject, localeTable), "\n"))
  end
  if self.detailPopupJumpButton then
    local resolvedExpansionID = nil -- 反查得到的资料片 ID
    local resolvedCampaignID = nil -- 反查得到的战役 ID
    if type(detailObject.questLineID) == "number"
      and AzerothCompanion.API.Questlines
      and type(AzerothCompanion.API.Questlines.GetQuestNavigationModel) == "function"
    then
      local navigationModel = select(1, AzerothCompanion.API.Questlines.GetQuestNavigationModel()) -- 当前导航模型
      resolvedExpansionID, resolvedCampaignID = findCampaignSelectionByQuestLineID(navigationModel, detailObject.questLineID)
    end
    local canJump = type(detailObject.questLineID) == "number"
      and (type(resolvedCampaignID) == "number" or type(detailObject.UiMapID) == "number") -- 是否可回跳
    self.detailPopupJumpButton.questLineID = detailObject.questLineID
    self.detailPopupJumpButton.mapID = detailObject.UiMapID
    self.detailPopupJumpButton.expansionID = type(resolvedExpansionID) == "number" and resolvedExpansionID or detailObject.questLineExpansionID
    self.detailPopupJumpButton.campaignID = resolvedCampaignID
    self.detailPopupJumpButton:SetShown(canJump)
    self.detailPopupJumpButton:SetText(localeTable.EJ_QUEST_JUMP_TO_QUESTLINE or "跳转到对应战役/任务线")
  end
  if self.detailPopupActiveButton then
    self.detailPopupActiveButton.questID = detailObject.questID
    self.detailPopupActiveButton:SetText(localeTable.EJ_QUEST_ACTION_OPEN_ACTIVE or "Open in Active View")
    self.detailPopupActiveButton:Show()
  end
  if self.detailPopupFrame then
    self.detailPopupFrame:Show()
  end
end
-- ============================================================================
-- 任务页签 breadcrumb 最终覆盖定义
-- ============================================================================

function QuestlineTreeView:syncBreadcrumb(expansionEntry)
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  local breadcrumbList = {} -- 当前路径段

  if self.selectedModeKey == "active_log" then
    breadcrumbList[#breadcrumbList + 1] = {
      text = getActiveLogRootText(localeTable),
    }
  elseif type(expansionEntry) == "table" then
    local mapMode = getMapQuestlineModeEntry(expansionEntry) -- 地图任务线模式
    local campaignMode = getCampaignModeEntry(expansionEntry) -- 战役模式
    local achievementMode = getAchievementModeEntry(expansionEntry) -- 成就模式
    local useCampaignMode = self.selectedModeKey == "campaign" -- 当前是否战役页签
    local useAchievementMode = self.selectedModeKey == "achievement" -- 当前是否成就页签
    breadcrumbList[#breadcrumbList + 1] = {
      text = useCampaignMode
        and getCampaignRootText(localeTable)
        or useAchievementMode
        and getAchievementRootText(localeTable)
        or getQuestlineRootText(localeTable),
      onClick = function()
        if useCampaignMode then
          self.selectedModeKey = "campaign"
        elseif useAchievementMode then
          self.selectedModeKey = "achievement"
        else
          self.selectedModeKey = "map_questline"
        end
        self.selectedCampaignID = nil
        self.selectedAchievementID = nil
        self.selectedMapID = nil
        self.expandedQuestLineID = nil
        self.directQuestLineCollapsed = false
        self.selectedQuestID = nil
        self:hideQuestDetailPopup()
        self:saveSelection()
        self:requestRender()
      end,
    }
    breadcrumbList[#breadcrumbList + 1] = {
      text = tostring(expansionEntry.name or ""),
      onClick = function()
        if useCampaignMode then
          self.selectedModeKey = "campaign"
        elseif useAchievementMode then
          self.selectedModeKey = "achievement"
        else
          self.selectedModeKey = "map_questline"
        end
        self.selectedCampaignID = nil
        self.selectedAchievementID = nil
        self.expandedQuestLineID = nil
        self.selectedMapID = nil
        self.directQuestLineCollapsed = false
        self:hideQuestDetailPopup()
        self:saveSelection()
        self:requestRender()
      end,
    }

    if useCampaignMode then
      local campaignEntry = findCampaignEntryByID(campaignMode, self.selectedCampaignID) -- 当前战役条目
      if type(campaignEntry) == "table" then
        breadcrumbList[#breadcrumbList + 1] = {
          text = tostring(campaignEntry.name or ""),
          onClick = function()
            self.expandedQuestLineID = nil
            self.directQuestLineCollapsed = false
            self:hideQuestDetailPopup()
            self:saveSelection()
            self:requestRender()
          end,
        }
        if type(self.expandedQuestLineID) == "number" then
          for _, questLineEntry in ipairs(campaignEntry.questLines or {}) do
            if type(questLineEntry) == "table" and questLineEntry.id == self.expandedQuestLineID then
              breadcrumbList[#breadcrumbList + 1] = {
                text = resolveQuestLineDisplayName(questLineEntry) or ("QuestLine #" .. tostring(self.expandedQuestLineID)),
              }
              break
            end
          end
        end
      end
    elseif useAchievementMode then
      local achievementEntry = findAchievementEntryByID(achievementMode, self.selectedAchievementID) -- 当前成就条目
      if type(achievementEntry) == "table" then
        breadcrumbList[#breadcrumbList + 1] = {
          text = tostring(achievementEntry.name or ""),
          onClick = function()
            self.expandedQuestLineID = nil
            self.directQuestLineCollapsed = false
            self:hideQuestDetailPopup()
            self:saveSelection()
            self:requestRender()
          end,
        }
        if type(self.expandedQuestLineID) == "number" then
          for _, questLineEntry in ipairs(achievementEntry.questLines or {}) do
            if type(questLineEntry) == "table" and questLineEntry.id == self.expandedQuestLineID then
              breadcrumbList[#breadcrumbList + 1] = {
                text = resolveQuestLineDisplayName(questLineEntry) or ("QuestLine #" .. tostring(self.expandedQuestLineID)),
              }
              break
            end
          end
        end
      end
    else
      if type(self.selectedMapID) == "number" then
        for _, mapEntry in ipairs(mapMode and mapMode.entries or {}) do
          if mapEntry.id == self.selectedMapID then
            breadcrumbList[#breadcrumbList + 1] = {
              text = tostring(mapEntry.name or ""),
              onClick = function()
                self.expandedQuestLineID = nil
                self.directQuestLineCollapsed = false
                self:hideQuestDetailPopup()
                self:saveSelection()
                self:requestRender()
              end,
            }
            break
          end
        end
      end
      if type(self.expandedQuestLineID) == "number" and AzerothCompanion.API.Questlines and type(AzerothCompanion.API.Questlines.GetQuestTabModel) == "function" then
        local questTabModel = select(1, AzerothCompanion.API.Questlines.GetQuestTabModel()) -- 任务页签模型
        local questLineEntry = questTabModel and questTabModel.questLineByID and questTabModel.questLineByID[self.expandedQuestLineID] or nil -- 当前任务线
        if type(questLineEntry) ~= "table" and type(self.selectedMapID) == "number" and AzerothCompanion.API.Questlines and type(AzerothCompanion.API.Questlines.GetQuestLinesForMap) == "function" then
          local questLineList = select(1, AzerothCompanion.API.Questlines.GetQuestLinesForMap(self.selectedMapID)) -- 当前地图任务线列表
          for _, currentQuestLineEntry in ipairs(questLineList or {}) do
            if type(currentQuestLineEntry) == "table" and currentQuestLineEntry.id == self.expandedQuestLineID then
              questLineEntry = currentQuestLineEntry
              break
            end
          end
        end
        if type(questLineEntry) == "table" then
          local mapID = type(questLineEntry.UiMapID) == "number" and questLineEntry.UiMapID
            or type(questLineEntry.PrimaryUiMapID) == "number" and questLineEntry.PrimaryUiMapID
            or nil -- 任务线所属地图 ID
          if type(self.selectedMapID) ~= "number" and type(mapID) == "number" then
            breadcrumbList[#breadcrumbList + 1] = {
              text = getMapNameByID(mapID),
              onClick = function()
                self.selectedMapID = mapID
                self.expandedQuestLineID = nil
                self.directQuestLineCollapsed = false
                self:hideQuestDetailPopup()
                self:saveSelection()
                self:requestRender()
              end,
            }
          end
          breadcrumbList[#breadcrumbList + 1] = {
            text = resolveQuestLineDisplayName(questLineEntry) or ("QuestLine #" .. tostring(self.expandedQuestLineID)),
          }
        end
      end
    end
  else
    breadcrumbList[#breadcrumbList + 1] = {
      text = self.selectedModeKey == "achievement"
        and getAchievementRootText(localeTable)
        or getQuestlineRootText(localeTable),
    }
  end

  if self.breadcrumbFrame and self.breadcrumbFrame.templateName == "NavBarTemplate" then
    if syncNavBarBreadcrumbButtons(self, breadcrumbList) then
      return
    end
  end
  syncFallbackBreadcrumbButtons(self, breadcrumbList)
end

function QuestlineTreeView:applyContentLayout()
  if not self.panelFrame or not self.headerFrame or not self.leftTree or not self.rightContent then
    return
  end
  local hostFrame = self.hostJournalFrame or self.panelFrame -- 任务宿主框体
  local activeModeKey = normalizeQuestNavModeKey(self.selectedModeKey) -- 当前激活视图
  if self.modeTabButtonByKey.active_log then
    self.modeTabButtonByKey.active_log:ClearAllPoints()
    self.modeTabButtonByKey.active_log:SetPoint("TOPLEFT", self.hostJournalFrame or self.panelFrame, "BOTTOMLEFT", 14, 2)
    setModeTabSelected(self.modeTabButtonByKey.active_log, activeModeKey == "active_log")
    self.modeTabButtonByKey.active_log:Show()
  end
  if self.modeTabButtonByKey.map_questline then
    self.modeTabButtonByKey.map_questline:ClearAllPoints()
    if self.modeTabButtonByKey.active_log then
      self.modeTabButtonByKey.map_questline:SetPoint("LEFT", self.modeTabButtonByKey.active_log, "RIGHT", VIEW_STYLE.modeTabGap, 0)
    else
      self.modeTabButtonByKey.map_questline:SetPoint("TOPLEFT", self.hostJournalFrame or self.panelFrame, "BOTTOMLEFT", 126, 2)
    end
    setModeTabSelected(self.modeTabButtonByKey.map_questline, activeModeKey == "map_questline")
    self.modeTabButtonByKey.map_questline:Show()
  end
  if self.modeTabButtonByKey.campaign then
    self.modeTabButtonByKey.campaign:ClearAllPoints()
    if self.modeTabButtonByKey.map_questline then
      self.modeTabButtonByKey.campaign:SetPoint("LEFT", self.modeTabButtonByKey.map_questline, "RIGHT", VIEW_STYLE.modeTabGap, 0)
    elseif self.modeTabButtonByKey.active_log then
      self.modeTabButtonByKey.campaign:SetPoint("LEFT", self.modeTabButtonByKey.active_log, "RIGHT", VIEW_STYLE.modeTabGap, 0)
    else
      self.modeTabButtonByKey.campaign:SetPoint("TOPLEFT", self.hostJournalFrame or self.panelFrame, "BOTTOMLEFT", 126, 2)
    end
    setModeTabSelected(self.modeTabButtonByKey.campaign, activeModeKey == "campaign")
    self.modeTabButtonByKey.campaign:Show()
  end
  if self.modeTabButtonByKey.achievement then
    self.modeTabButtonByKey.achievement:ClearAllPoints()
    if self.modeTabButtonByKey.campaign then
      self.modeTabButtonByKey.achievement:SetPoint("LEFT", self.modeTabButtonByKey.campaign, "RIGHT", VIEW_STYLE.modeTabGap, 0)
    elseif self.modeTabButtonByKey.map_questline then
      self.modeTabButtonByKey.achievement:SetPoint("LEFT", self.modeTabButtonByKey.map_questline, "RIGHT", VIEW_STYLE.modeTabGap, 0)
    elseif self.modeTabButtonByKey.active_log then
      self.modeTabButtonByKey.achievement:SetPoint("LEFT", self.modeTabButtonByKey.active_log, "RIGHT", VIEW_STYLE.modeTabGap, 0)
    else
      self.modeTabButtonByKey.achievement:SetPoint("TOPLEFT", self.hostJournalFrame or self.panelFrame, "BOTTOMLEFT", 126, 2)
    end
    setModeTabSelected(self.modeTabButtonByKey.achievement, activeModeKey == "achievement")
    self.modeTabButtonByKey.achievement:Show()
  end

  self.headerFrame:ClearAllPoints()
  self.headerFrame:SetPoint("TOPLEFT", hostFrame, "TOPLEFT", VIEW_STYLE.headerHostLeftInset, -VIEW_STYLE.headerTopOffset)
  self.headerFrame:SetPoint("TOPRIGHT", hostFrame, "TOPRIGHT", -VIEW_STYLE.headerHostRightInset, -VIEW_STYLE.headerTopOffset)
  self.headerFrame:SetHeight(VIEW_STYLE.headerHeight)
  self.headerFrame:Show()

  self.rightContent:ClearAllPoints()
  if activeModeKey == "active_log" then
    self.leftTree:Hide()
    self.scrollFrame:Hide()
    self.rightContent:SetPoint("TOPLEFT", self.panelFrame, "TOPLEFT", 8, -8)
    self.rightContent:SetPoint("BOTTOMRIGHT", self.panelFrame, "BOTTOMRIGHT", -8, 8)
  else
    self.leftTree:ClearAllPoints()
    self.leftTree:SetPoint("TOPLEFT", self.panelFrame, "TOPLEFT", 8, -8)
    self.leftTree:SetPoint("BOTTOMLEFT", self.panelFrame, "BOTTOMLEFT", 8, 8)
    self.leftTree:SetWidth(VIEW_STYLE.leftPanelWidth)
    self.leftTree:Show()
    self.scrollFrame:ClearAllPoints()
    self.scrollFrame:SetPoint("TOPLEFT", self.leftTree, "TOPLEFT", 6, -6)
    self.scrollFrame:SetPoint("BOTTOMRIGHT", self.leftTree, "BOTTOMRIGHT", -28, 6)
    self.scrollFrame:Show()
    self.rightContent:SetPoint("TOPLEFT", self.leftTree, "TOPRIGHT", 6, 0)
    self.rightContent:SetPoint("BOTTOMRIGHT", self.panelFrame, "BOTTOMRIGHT", -8, 8)
  end
  self.rightContent:Show()
  if self.searchBoxFrame then
    self.searchBoxFrame:ClearAllPoints()
    self.searchBoxFrame:SetPoint("TOPRIGHT", self.headerFrame, "TOPRIGHT", 0, 0)
    self.searchBoxFrame:SetSize(VIEW_STYLE.searchBoxWidth, VIEW_STYLE.headerHeight - 2)
    self.searchBoxFrame:Show()
  end
  if self.breadcrumbFrame then
    self.breadcrumbFrame:ClearAllPoints()
    self.breadcrumbFrame:SetPoint("TOPLEFT", self.headerFrame, "TOPLEFT", 0, 0)
    if self.searchBoxFrame then
      self.breadcrumbFrame:SetPoint("TOPRIGHT", self.searchBoxFrame, "TOPLEFT", -10, 0)
    else
      self.breadcrumbFrame:SetPoint("TOPRIGHT", self.headerFrame, "TOPRIGHT", 0, 0)
    end
    self.breadcrumbFrame:SetHeight(VIEW_STYLE.headerHeight)
    local hostWidth = hostFrame and hostFrame.GetWidth and tonumber(hostFrame:GetWidth()) or 0 -- 宿主宽度
    local availableWidth = hostWidth - VIEW_STYLE.headerHostLeftInset - VIEW_STYLE.headerHostRightInset - VIEW_STYLE.searchBoxWidth - 10 -- 导航可用宽度
    if type(availableWidth) ~= "number" or availableWidth <= 0 then
      availableWidth = 320
    end
    self.breadcrumbFrame:SetWidth(availableWidth)
    self.breadcrumbFrame:Show()
  end
  if self.searchBox then
    self.searchBox:ClearAllPoints()
    if self.searchBoxFrame then
      self.searchBox:SetPoint("TOPLEFT", self.searchBoxFrame, "TOPLEFT", 4, -1)
      self.searchBox:SetPoint("BOTTOMRIGHT", self.searchBoxFrame, "BOTTOMRIGHT", -4, 1)
    else
      self.searchBox:SetPoint("TOPRIGHT", self.headerFrame, "TOPRIGHT", 0, 0)
      self.searchBox:SetSize(VIEW_STYLE.searchBoxWidth, 20)
    end
  end
  if self.rightTitle then
    self.rightTitle:ClearAllPoints()
    self.rightTitle:SetPoint("TOPLEFT", self.rightContent, "TOPLEFT", 10, -10)
    self.rightTitle:SetPoint("TOPRIGHT", self.rightContent, "TOPRIGHT", -10, -10)
  end
  if self.rightHeaderDivider then
    self.rightHeaderDivider:ClearAllPoints()
    self.rightHeaderDivider:SetPoint("TOPLEFT", self.rightContent, "TOPLEFT", 10, -28)
    self.rightHeaderDivider:SetPoint("TOPRIGHT", self.rightContent, "TOPRIGHT", -10, -28)
    self.rightHeaderDivider:SetHeight(1)
  end

  if activeModeKey == "active_log" then
    local contentHeight = self.rightContent.GetHeight and self.rightContent:GetHeight() or 0 -- 当前内容区高度
    if type(contentHeight) ~= "number" or contentHeight <= 0 then
      contentHeight = 520
    end
    local bodyHeight = math.max(220, contentHeight - 90) -- 头部以下可用高度
    local recentHeight = self.activeLogRecentCollapsed == true and 0 or math.floor(bodyHeight * VIEW_STYLE.activeLogRecentRatio) -- 历史完成面板高度
    local currentHeight = self.activeLogRecentCollapsed == true and bodyHeight or math.max(140, bodyHeight - recentHeight - VIEW_STYLE.activeLogPanelGap) -- 当前任务面板高度

    self:hideAllRightRows()
    if self.rightTitle then
      self.rightTitle:Hide()
    end
    if self.rightScrollFrame then
      self.rightScrollFrame:Hide()
    end

    if self.activeLogRecentToggleButton then
      self.activeLogRecentToggleButton:ClearAllPoints()
      self.activeLogRecentToggleButton:SetPoint("TOPRIGHT", self.rightContent, "TOPRIGHT", -10, -10)
      self.activeLogRecentToggleButton:Show()
    end

    if self.activeLogCurrentPanel then
      self.activeLogCurrentPanel:ClearAllPoints()
      self.activeLogCurrentPanel:SetPoint("TOPLEFT", self.rightContent, "TOPLEFT", 10, -36)
      self.activeLogCurrentPanel:SetPoint("TOPRIGHT", self.rightContent, "TOPRIGHT", -10, -36)
      self.activeLogCurrentPanel:SetHeight(currentHeight)
      self.activeLogCurrentPanel:Show()
    end
    if self.activeLogCurrentTitle then
      self.activeLogCurrentTitle:ClearAllPoints()
      self.activeLogCurrentTitle:SetPoint("TOPLEFT", self.activeLogCurrentPanel, "TOPLEFT", 10, -10)
      self.activeLogCurrentTitle:SetPoint("TOPRIGHT", self.activeLogCurrentPanel, "TOPRIGHT", -10, -10)
      self.activeLogCurrentTitle:Show()
    end
    if self.activeLogCurrentScrollFrame then
      self.activeLogCurrentScrollFrame:ClearAllPoints()
      self.activeLogCurrentScrollFrame:SetPoint("TOPLEFT", self.activeLogCurrentPanel, "TOPLEFT", 8, -32)
      self.activeLogCurrentScrollFrame:SetPoint("BOTTOMRIGHT", self.activeLogCurrentPanel, "BOTTOMRIGHT", -26, 8)
      self.activeLogCurrentScrollFrame:Show()
    end

    if self.activeLogRecentPanel then
      if self.activeLogRecentCollapsed == true then
        self.activeLogRecentPanel:Hide()
      else
        self.activeLogRecentPanel:ClearAllPoints()
        self.activeLogRecentPanel:SetPoint("TOPLEFT", self.activeLogCurrentPanel, "BOTTOMLEFT", 0, -VIEW_STYLE.activeLogPanelGap)
        self.activeLogRecentPanel:SetPoint("TOPRIGHT", self.activeLogCurrentPanel, "BOTTOMRIGHT", 0, -VIEW_STYLE.activeLogPanelGap)
        self.activeLogRecentPanel:SetHeight(recentHeight)
        self.activeLogRecentPanel:Show()
      end
    end
    if self.activeLogRecentTitle then
      if self.activeLogRecentCollapsed == true then
        self.activeLogRecentTitle:Hide()
      else
        self.activeLogRecentTitle:ClearAllPoints()
        self.activeLogRecentTitle:SetPoint("TOPLEFT", self.activeLogRecentPanel, "TOPLEFT", 10, -10)
        self.activeLogRecentTitle:SetPoint("TOPRIGHT", self.activeLogRecentPanel, "TOPRIGHT", -10, -10)
        self.activeLogRecentTitle:Show()
      end
    end
    if self.activeLogRecentScrollFrame then
      if self.activeLogRecentCollapsed == true then
        self.activeLogRecentScrollFrame:Hide()
      else
        self.activeLogRecentScrollFrame:ClearAllPoints()
        self.activeLogRecentScrollFrame:SetPoint("TOPLEFT", self.activeLogRecentPanel, "TOPLEFT", 8, -32)
        self.activeLogRecentScrollFrame:SetPoint("BOTTOMRIGHT", self.activeLogRecentPanel, "BOTTOMRIGHT", -26, 8)
        self.activeLogRecentScrollFrame:Show()
      end
    end
  else
    if self.rightTitle then
      self.rightTitle:Show()
    end
    if self.rightScrollFrame then
      self.rightScrollFrame:ClearAllPoints()
      self.rightScrollFrame:SetPoint("TOPLEFT", self.rightContent, "TOPLEFT", 10, -36)
      self.rightScrollFrame:SetPoint("BOTTOMRIGHT", self.rightContent, "BOTTOMRIGHT", -26, 10)
      self.rightScrollFrame:Show()
    end
    if self.activeLogCurrentPanel then
      self.activeLogCurrentPanel:Hide()
    end
    if self.activeLogRecentPanel then
      self.activeLogRecentPanel:Hide()
    end
    if self.activeLogRecentToggleButton then
      self.activeLogRecentToggleButton:Hide()
    end
    self:hideRowButtonList(self.activeLogCurrentRowButtons)
    self:hideRowButtonList(self.activeLogRecentRowButtons)
  end
end

function QuestlineTreeView:render()
  if not self.scrollFrame or not self.rightScrollFrame or not self.emptyText then
    return
  end
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  self:applyContentLayout()

  if self.selectedModeKey == "active_log" then
    self:syncBreadcrumb(nil)
    local activeLayoutState, activeError = self:renderActiveLogPanels() -- 当前任务布局状态
    if activeError then
      self:hideAllRows()
      self:hideAllRightRows()
      self:hideRowButtonList(self.activeLogCurrentRowButtons)
      self:hideRowButtonList(self.activeLogRecentRowButtons)
      self.emptyText:SetText(localeTable.EJ_QUEST_DATA_INVALID or "任务数据无效。")
      self.emptyText:Show()
      return
    end
    self:hideAllRows()
    self:hideAllRightRows()
    restoreVerticalScrollOffset(
      self.activeLogCurrentScrollFrame,
      readVerticalScrollOffset(self.activeLogCurrentScrollFrame),
      activeLayoutState.currentHeight
    )
    if self.activeLogRecentCollapsed ~= true then
      restoreVerticalScrollOffset(
        self.activeLogRecentScrollFrame,
        readVerticalScrollOffset(self.activeLogRecentScrollFrame),
        activeLayoutState.recentHeight
      )
    end
    local hasAnyActiveRow = false -- 当前任务视图是否有内容
    for _, rowData in ipairs(activeLayoutState.currentRows or {}) do
      if type(rowData) == "table" and rowData.kind ~= "section_empty" then
        hasAnyActiveRow = true
        break
      end
    end
    if not hasAnyActiveRow then
      for _, rowData in ipairs(activeLayoutState.recentRows or {}) do
        if type(rowData) == "table" and rowData.kind ~= "section_empty" then
          hasAnyActiveRow = true
          break
        end
      end
    end
    self.emptyText:SetShown(not hasAnyActiveRow)
    if self.emptyText:IsShown() then
      self.emptyText:SetText(localeTable.EJ_QUEST_ACTIVE_EMPTY or "No active quests in the quest log.")
    end
    return
  end

  local leftScrollOffset = readVerticalScrollOffset(self.scrollFrame) -- 左树滚动偏移
  local rightScrollOffset = readVerticalScrollOffset(self.rightScrollFrame) -- 主区滚动偏移
  local navigationModel, queryError = AzerothCompanion.API.Questlines.GetQuestNavigationModel() -- 导航模型
  if queryError then
    self:hideAllRows()
    self:hideAllRightRows()
    self:hideRowButtonList(self.activeLogCurrentRowButtons)
    self:hideRowButtonList(self.activeLogRecentRowButtons)
    self.rightScrollFrame:Hide()
    self.emptyText:SetText(localeTable.EJ_QUEST_DATA_INVALID or "任务数据无效。")
    self.emptyText:Show()
    return
  end
  local expansionEntry = self:resolveNavigationDefaults(navigationModel or {}) -- 当前资料片
  self:syncBreadcrumb(expansionEntry)

  local leftRows = self:buildLeftTreeRows(navigationModel or {}) -- 左树行
  local mainRows, mainError = self:buildMainRowsForMap() -- 主区行与错误
  if mainError then
    self:hideAllRows()
    self:hideAllRightRows()
    self.rightScrollFrame:Hide()
    self.emptyText:SetText(localeTable.EJ_QUEST_DATA_INVALID or "任务数据无效。")
    self.emptyText:Show()
    return
  end
  local leftContentHeight = self:renderLeftRows(leftRows) -- 左树内容高度
  local rightContentHeight = self:renderRightRows(mainRows) -- 主区内容高度
  restoreVerticalScrollOffset(self.scrollFrame, leftScrollOffset, leftContentHeight)
  restoreVerticalScrollOffset(self.rightScrollFrame, rightScrollOffset, rightContentHeight)
  self:hideRowButtonList(self.activeLogCurrentRowButtons)
  self:hideRowButtonList(self.activeLogRecentRowButtons)
  self.emptyText:SetShown(#leftRows == 0 and #mainRows == 0)
  if self.emptyText:IsShown() then
    self.emptyText:SetText(localeTable.EJ_QUESTLINE_TREE_EMPTY or "当前暂无任务线数据。")
  end
  if self.rightTitle then
    local titleText = localeTable.EJ_QUESTLINE_LIST_TITLE or "Questlines" -- 主区标题文本
    local titleCount = 0 -- 标题计数
    local countKind = "questline" -- 计数行类型
    if self.selectedModeKey == "campaign" and type(self.selectedCampaignID) == "number" then
      titleText = localeTable.EJ_QUEST_TASK_LIST_TITLE or "Quests"
      countKind = "quest"
    elseif self.selectedModeKey == "achievement" and type(self.selectedAchievementID) == "number" then
      if type(self.expandedQuestLineID) == "number" then
        titleText = localeTable.EJ_QUEST_TASK_LIST_TITLE or "Quests"
        countKind = "quest"
      else
        titleText = localeTable.EJ_QUESTLINE_LIST_TITLE or "Questlines"
        countKind = "questline"
      end
    elseif self.selectedModeKey == "achievement" then
      titleText = localeTable.EJ_QUESTLINE_LIST_TITLE or "Questlines"
      countKind = "questline"
    end
    for _, rowData in ipairs(mainRows) do
      if type(rowData) == "table" and rowData.kind == countKind then
        titleCount = titleCount + 1
      end
    end
    self.rightTitle:SetText(string.format("%s (%d)", titleText, titleCount))
  end
end

function QuestlineTreeView:ensureWidgets()
  local journalFrame = _G.AzerothCompanionQuestFrame -- quest 模块根面板
  if not journalFrame then
    return
  end
  self.hostJournalFrame = journalFrame
  if self.headerFrame and self.headerFrame.parentFrame ~= journalFrame and self.headerFrame.SetParent then
    self.headerFrame:SetParent(journalFrame)
  end
  self.breadcrumbButtons = self.breadcrumbButtons or {}
  self.modeTabButtonByKey = self.modeTabButtonByKey or {}
  if self.tabButton
    and self.panelFrame
    and self.headerFrame
    and self.modeTabButtonByKey.active_log
    and self.modeTabButtonByKey.map_questline
    and self.modeTabButtonByKey.campaign
    and self.modeTabButtonByKey.achievement
    and self.leftTree
    and self.rightContent
    and self.scrollFrame
    and self.scrollChild
    and self.rightScrollFrame
    and self.rightScrollChild
    and self.activeLogCurrentPanel
    and self.activeLogCurrentScrollFrame
    and self.activeLogCurrentScrollChild
    and self.activeLogRecentPanel
    and self.activeLogRecentScrollFrame
    and self.activeLogRecentScrollChild
    and self.activeLogRecentToggleButton
    and self.emptyText
    and self.detailPopupFrame
    and self.detailPopupJumpButton
    and self.detailPopupActiveButton
    and self.detailPopupCloseButton
    and self.breadcrumbFrame
    and self.searchBox
    and self.searchBoxFrame
    and self.rightHeaderDivider
  then
    if self.selectionLoaded ~= true then
      self:loadSelection()
      self.selectionLoaded = true
    end
    if self.searchBox then
      self.searchBox:SetText(self.searchText or "")
    end
    if self.searchPlaceholder then
      local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
      self.searchPlaceholder:SetText(localeTable.EJ_QUEST_SEARCH_PLACEHOLDER or "Search campaigns / questlines / quests...")
      self.searchPlaceholder:SetShown((self.searchText or "") == "")
    end
    local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
    if self.modeTabButtonByKey.active_log then
      self.modeTabButtonByKey.active_log:SetText(getActiveLogRootText(localeTable))
      self.modeTabButtonByKey.active_log:SetWidth(108)
    end
    if self.modeTabButtonByKey.map_questline then
      self.modeTabButtonByKey.map_questline:SetText(getQuestlineRootText(localeTable))
      self.modeTabButtonByKey.map_questline:SetWidth(92)
    end
    if self.modeTabButtonByKey.campaign then
      self.modeTabButtonByKey.campaign:SetText(getCampaignRootText(localeTable))
      self.modeTabButtonByKey.campaign:SetWidth(92)
    end
    if self.modeTabButtonByKey.achievement then
      self.modeTabButtonByKey.achievement:SetText(getAchievementRootText(localeTable))
      self.modeTabButtonByKey.achievement:SetWidth(92)
    end
    if self.activeLogRecentToggleButton then
      self.activeLogRecentToggleButton:SetText(getRecentCompletedToggleText(localeTable, self.activeLogRecentCollapsed))
      self.activeLogRecentToggleButton:SetWidth(108)
    end
    self:layoutRootTabs()
    self:syncTabLabel()
    self:applyContentLayout()
    self:hookVanillaTabsOnce()
    return
  end
  if not self.tabButton then
    local tabButton = CreateFrame("Button", "AzerothCompanionQuestRootTab", journalFrame, "PanelTabButtonTemplate")
    tabButton:SetID(QUEST_ROOT_TAB_ID)
    tabButton:SetScript("OnClick", function()
      self:setSelected(true)
    end)
    self.tabButton = tabButton
    self:layoutRootTabs()
  end
  if not self.panelFrame then
    local panelFrame = CreateFrame("Frame", "AzerothCompanionQuestMainPanel", journalFrame, "InsetFrameTemplate")
    local instanceSelect = journalFrame.instanceSelect -- 主内容区
    if instanceSelect then
      panelFrame:SetPoint("TOPLEFT", instanceSelect, "TOPLEFT", 0, 0)
      panelFrame:SetPoint("BOTTOMRIGHT", instanceSelect, "BOTTOMRIGHT", 0, 0)
    else
      panelFrame:SetPoint("TOPLEFT", journalFrame, "TOPLEFT", 4, -60)
      panelFrame:SetPoint("BOTTOMRIGHT", journalFrame, "BOTTOMRIGHT", -4, 5)
    end
    panelFrame:Hide()
    self.panelFrame = panelFrame
  end
  if not self.modeTabButtonByKey.active_log then
    local activeButton = CreateFrame("Button", nil, journalFrame, "PanelTabButtonTemplate") -- 当前任务视图页签
    activeButton:SetHeight(VIEW_STYLE.modeTabHeight)
    activeButton:SetScript("OnClick", function()
      self.selectedModeKey = "active_log"
      self.selectedCampaignID = nil
      self.selectedAchievementID = nil
      self.selectedMapID = nil
      self.expandedQuestLineID = nil
      self.directQuestLineCollapsed = false
      self.selectedQuestID = nil
      self:hideQuestDetailPopup()
      self:saveSelection()
      self:requestRender()
    end)
    self.modeTabButtonByKey.active_log = activeButton
  end
  if not self.modeTabButtonByKey.map_questline then
    local mapButton = CreateFrame("Button", nil, journalFrame, "PanelTabButtonTemplate") -- 任务线视图页签
    mapButton:SetHeight(VIEW_STYLE.modeTabHeight)
    mapButton:SetScript("OnClick", function()
      self.selectedModeKey = "map_questline"
      self.selectedCampaignID = nil
      self.selectedAchievementID = nil
      self.selectedQuestID = nil
      self:hideQuestDetailPopup()
      self:saveSelection()
      self:requestRender()
    end)
    self.modeTabButtonByKey.map_questline = mapButton
  end
  if not self.modeTabButtonByKey.campaign then
    local campaignButton = CreateFrame("Button", nil, journalFrame, "PanelTabButtonTemplate") -- 战役视图页签
    campaignButton:SetHeight(VIEW_STYLE.modeTabHeight)
    campaignButton:SetScript("OnClick", function()
      self.selectedModeKey = "campaign"
      self.selectedMapID = nil
      self.selectedAchievementID = nil
      self.selectedQuestID = nil
      self:hideQuestDetailPopup()
      self:saveSelection()
      self:requestRender()
    end)
    self.modeTabButtonByKey.campaign = campaignButton
  end
  if not self.modeTabButtonByKey.achievement then
    local achievementButton = CreateFrame("Button", nil, journalFrame, "PanelTabButtonTemplate") -- 成就视图页签
    achievementButton:SetHeight(VIEW_STYLE.modeTabHeight)
    achievementButton:SetScript("OnClick", function()
      self.selectedModeKey = "achievement"
      self.selectedCampaignID = nil
      self.selectedMapID = nil
      self.selectedQuestID = nil
      self:hideQuestDetailPopup()
      self:saveSelection()
      self:requestRender()
    end)
    self.modeTabButtonByKey.achievement = achievementButton
  end
  if not self.leftTree then
    self.leftTree = CreateFrame("Frame", nil, self.panelFrame)
  end
  if not self.headerFrame then
    self.headerFrame = CreateFrame("Frame", nil, journalFrame) -- 标题栏下方、位于图标右侧的独立头部带
  end
  if not self.rightContent then
    self.rightContent = CreateFrame("Frame", nil, self.panelFrame)
  end
  if not self.scrollFrame then
    self.scrollFrame = CreateFrame("ScrollFrame", "AzerothCompanionQuestLeftScrollFrame", self.leftTree, "UIPanelScrollFrameTemplate")
  end
  if not self.scrollChild then
    local scrollChild = CreateFrame("Frame", "AzerothCompanionQuestLeftScrollChild", self.scrollFrame)
    scrollChild:SetSize(180, 32)
    self.scrollChild = scrollChild
  end
  if self.scrollFrame:GetScrollChild() ~= self.scrollChild then
    self.scrollFrame:SetScrollChild(self.scrollChild)
  end
  if not self.rightTitle then
    local rightTitle = self.rightContent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    rightTitle:SetJustifyH("LEFT")
    rightTitle:SetTextColor(1.0, 0.9, 0.68)
    self.rightTitle = rightTitle
  end
  if not self.rightHeaderDivider then
    local dividerTexture = self.rightContent:CreateTexture(nil, "ARTWORK")
    dividerTexture:SetColorTexture(0.6, 0.48, 0.24, 0.5)
    self.rightHeaderDivider = dividerTexture
  end
  if not self.breadcrumbFrame then
    local createSuccess, breadcrumbFrame = pcall(CreateFrame, "Frame", nil, self.headerFrame, "NavBarTemplate") -- 冒险指南同款 NavBar 容器
    if createSuccess and breadcrumbFrame then
      self.breadcrumbFrame = breadcrumbFrame
    else
      self.breadcrumbFrame = CreateFrame("Frame", nil, self.headerFrame)
    end
  end
  if not self.searchBoxFrame then
    local searchBoxFrame = CreateFrame("Frame", nil, self.headerFrame) -- 搜索框纯布局容器，避免与 InputBoxTemplate 形成双层边框
    self.searchBoxFrame = searchBoxFrame
  end
  if not self.searchBox then
    local searchBox = CreateFrame("EditBox", nil, self.headerFrame, "InputBoxTemplate")
    searchBox:SetAutoFocus(false)
    searchBox:SetMaxLetters(80)
    searchBox:SetHeight(24)
    searchBox:SetTextInsets(0, 0, 0, 0)
    searchBox:SetScript("OnEscapePressed", function(editBox)
      editBox:ClearFocus()
    end)
    searchBox:SetScript("OnEnterPressed", function(editBox)
      editBox:ClearFocus()
    end)
    searchBox:SetScript("OnTextChanged", function(editBox, userInput)
      local currentText = editBox:GetText() or "" -- 当前输入文本
      if self.searchPlaceholder then
        self.searchPlaceholder:SetShown(currentText == "" and not editBox:HasFocus())
      end
      self.searchText = currentText
      if userInput then
        self:saveSelection()
        self:requestRender()
      end
    end)
    searchBox:SetScript("OnEditFocusGained", function(editBox)
      if self.searchPlaceholder then
        self.searchPlaceholder:Hide()
      end
    end)
    searchBox:SetScript("OnEditFocusLost", function(editBox)
      if self.searchPlaceholder then
        self.searchPlaceholder:SetShown((editBox:GetText() or "") == "")
      end
    end)
    self.searchBox = searchBox
  end
  if not self.searchPlaceholder then
    local placeholderText = self.searchBox:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    placeholderText:SetPoint("LEFT", self.searchBox, "LEFT", 6, 0)
    placeholderText:SetPoint("RIGHT", self.searchBox, "RIGHT", -6, 0)
    placeholderText:SetJustifyH("LEFT")
    self.searchPlaceholder = placeholderText
  end
  if not self.rightScrollFrame then
    self.rightScrollFrame = CreateFrame("ScrollFrame", nil, self.rightContent, "UIPanelScrollFrameTemplate")
  end
  if not self.rightScrollChild then
    local rightScrollChild = CreateFrame("Frame", nil, self.rightScrollFrame)
    rightScrollChild:SetSize(200, 32)
    self.rightScrollChild = rightScrollChild
  end
  if self.rightScrollFrame:GetScrollChild() ~= self.rightScrollChild then
    self.rightScrollFrame:SetScrollChild(self.rightScrollChild)
  end
  if not self.activeLogCurrentPanel then
    self.activeLogCurrentPanel = CreateFrame("Frame", nil, self.rightContent)
  end
  if not self.activeLogCurrentTitle then
    local currentTitle = self.activeLogCurrentPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlight") -- 当前任务区标题
    currentTitle:SetJustifyH("LEFT")
    currentTitle:SetTextColor(1.0, 0.9, 0.68)
    self.activeLogCurrentTitle = currentTitle
  end
  if not self.activeLogCurrentScrollFrame then
    self.activeLogCurrentScrollFrame = CreateFrame("ScrollFrame", nil, self.activeLogCurrentPanel, "UIPanelScrollFrameTemplate")
  end
  if not self.activeLogCurrentScrollChild then
    local currentScrollChild = CreateFrame("Frame", nil, self.activeLogCurrentScrollFrame)
    currentScrollChild:SetSize(200, 32)
    self.activeLogCurrentScrollChild = currentScrollChild
  end
  if self.activeLogCurrentScrollFrame:GetScrollChild() ~= self.activeLogCurrentScrollChild then
    self.activeLogCurrentScrollFrame:SetScrollChild(self.activeLogCurrentScrollChild)
  end
  if not self.activeLogRecentPanel then
    self.activeLogRecentPanel = CreateFrame("Frame", nil, self.rightContent)
  end
  if not self.activeLogRecentTitle then
    local recentTitle = self.activeLogRecentPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlight") -- 最近完成区标题
    recentTitle:SetJustifyH("LEFT")
    recentTitle:SetTextColor(1.0, 0.9, 0.68)
    self.activeLogRecentTitle = recentTitle
  end
  if not self.activeLogRecentToggleButton then
    local toggleButton = CreateFrame("Button", nil, self.rightContent, "UIPanelButtonTemplate") -- 最近完成折叠按钮
    toggleButton:SetHeight(18)
    toggleButton:SetScript("OnClick", function()
      self.activeLogRecentCollapsed = self.activeLogRecentCollapsed ~= true
      self:hideQuestDetailPopup()
      self:applyContentLayout()
      self:requestRender()
    end)
    self.activeLogRecentToggleButton = toggleButton
  end
  if not self.activeLogRecentScrollFrame then
    self.activeLogRecentScrollFrame = CreateFrame("ScrollFrame", nil, self.activeLogRecentPanel, "UIPanelScrollFrameTemplate")
  end
  if not self.activeLogRecentScrollChild then
    local recentScrollChild = CreateFrame("Frame", nil, self.activeLogRecentScrollFrame)
    recentScrollChild:SetSize(200, 32)
    self.activeLogRecentScrollChild = recentScrollChild
  end
  if self.activeLogRecentScrollFrame:GetScrollChild() ~= self.activeLogRecentScrollChild then
    self.activeLogRecentScrollFrame:SetScrollChild(self.activeLogRecentScrollChild)
  end
  if self.activeLogCurrentPanel and self.activeLogCurrentPanel.SetBackdropColor then
    self.activeLogCurrentPanel:SetBackdropColor(0.09, 0.09, 0.11, 1)
    if self.activeLogCurrentPanel.SetBackdropBorderColor then
      self.activeLogCurrentPanel:SetBackdropBorderColor(0.38, 0.34, 0.28, 1)
    end
  end
  if self.activeLogRecentPanel and self.activeLogRecentPanel.SetBackdropColor then
    self.activeLogRecentPanel:SetBackdropColor(0.09, 0.09, 0.11, 1)
    if self.activeLogRecentPanel.SetBackdropBorderColor then
      self.activeLogRecentPanel:SetBackdropBorderColor(0.38, 0.34, 0.28, 1)
    end
  end
  if not self.emptyText then
    local emptyText = self.panelFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    emptyText:SetPoint("CENTER", self.panelFrame, "CENTER", 0, 0)
    emptyText:SetWidth(360)
    emptyText:SetJustifyH("CENTER")
    emptyText:SetJustifyV("MIDDLE")
    emptyText:SetWordWrap(true)
    self.emptyText = emptyText
  end
  if not self.detailPopupFrame then
    local popupFrame = CreateFrame("Frame", nil, self.panelFrame, "InsetFrameTemplate3")
    popupFrame:SetPoint("CENTER", self.panelFrame, "CENTER", 0, 0)
    popupFrame:SetSize(360, 220)
    popupFrame:SetFrameStrata("DIALOG")
    popupFrame:SetFrameLevel(120)
    popupFrame:Hide()
    self.detailPopupFrame = popupFrame
  end
  if self.detailPopupFrame and self.detailPopupFrame.SetBackdropColor then
    self.detailPopupFrame:SetBackdropColor(0.09, 0.08, 0.06, 0.96)
    if self.detailPopupFrame.SetBackdropBorderColor then
      self.detailPopupFrame:SetBackdropBorderColor(0.72, 0.58, 0.3, 0.92)
    end
  end
  if not self.detailPopupTitleBar then
    local titleBarTexture = self.detailPopupFrame:CreateTexture(nil, "BACKGROUND")
    titleBarTexture:SetColorTexture(0.32, 0.24, 0.12, 0.58)
    titleBarTexture:SetPoint("TOPLEFT", self.detailPopupFrame, "TOPLEFT", 6, -6)
    titleBarTexture:SetPoint("TOPRIGHT", self.detailPopupFrame, "TOPRIGHT", -6, -6)
    titleBarTexture:SetHeight(24)
    self.detailPopupTitleBar = titleBarTexture
  end
  if not self.detailPopupTitle then
    local popupTitle = self.detailPopupFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    popupTitle:SetPoint("TOPLEFT", self.detailPopupFrame, "TOPLEFT", 14, -12)
    popupTitle:SetPoint("TOPRIGHT", self.detailPopupFrame, "TOPRIGHT", -40, -12)
    popupTitle:SetJustifyH("LEFT")
    popupTitle:SetTextColor(1.0, 0.9, 0.68)
    self.detailPopupTitle = popupTitle
  end
  if not self.detailPopupText then
    local popupText = self.detailPopupFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    popupText:SetPoint("TOPLEFT", self.detailPopupFrame, "TOPLEFT", 12, -38)
    popupText:SetPoint("BOTTOMRIGHT", self.detailPopupFrame, "BOTTOMRIGHT", -12, 40)
    popupText:SetJustifyH("LEFT")
    popupText:SetJustifyV("TOP")
    popupText:SetWordWrap(true)
    self.detailPopupText = popupText
  end
  if not self.detailPopupJumpButton then
    local jumpButton = CreateFrame("Button", nil, self.detailPopupFrame, "UIPanelButtonTemplate")
    jumpButton:SetSize(180, 20)
    jumpButton:SetPoint("BOTTOMLEFT", self.detailPopupFrame, "BOTTOMLEFT", 12, 12)
    jumpButton:SetScript("OnClick", function(button)
      if type(button.expansionID) == "number" then
        self.selectedExpansionID = button.expansionID
      end
      if type(button.campaignID) == "number" then
        self.selectedModeKey = "campaign"
        self.selectedCampaignID = button.campaignID
        self.selectedAchievementID = nil
        self.selectedMapID = nil
      elseif type(button.mapID) == "number" then
        self.selectedModeKey = "map_questline"
        self.selectedCampaignID = nil
        self.selectedAchievementID = nil
        self.selectedMapID = button.mapID
      else
        self.selectedModeKey = "map_questline"
        self.selectedCampaignID = nil
        self.selectedAchievementID = nil
        self.selectedMapID = nil
      end
      if type(button.questLineID) == "number" then
        self.expandedQuestLineID = button.questLineID
        self.directQuestLineCollapsed = false
      end
      self.selectedTypeKey = ""
      self:hideQuestDetailPopup()
      self:saveSelection()
      self:requestRender()
    end)
    jumpButton:Hide()
    self.detailPopupJumpButton = jumpButton
  end
  if not self.detailPopupActiveButton then
    local activeButton = CreateFrame("Button", nil, self.detailPopupFrame, "UIPanelButtonTemplate")
    activeButton:SetSize(164, 20)
    activeButton:SetPoint("BOTTOMRIGHT", self.detailPopupFrame, "BOTTOMRIGHT", -12, 12)
    activeButton:SetScript("OnClick", function(button)
      self.selectedModeKey = "active_log"
      self.selectedCampaignID = nil
      self.selectedAchievementID = nil
      self.selectedMapID = nil
      self.selectedQuestID = button.questID
      self:hideQuestDetailPopup()
      self:saveSelection()
      self:requestRender()
    end)
    activeButton:Hide()
    self.detailPopupActiveButton = activeButton
  end
  if not self.detailPopupCloseButton then
    local closeButton = CreateFrame("Button", nil, self.detailPopupFrame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", self.detailPopupFrame, "TOPRIGHT", -6, -6)
    closeButton:SetScript("OnClick", function()
      self:hideQuestDetailPopup()
    end)
    self.detailPopupCloseButton = closeButton
  end
  if self.selectionLoaded ~= true then
    self:loadSelection()
    self.selectionLoaded = true
  end
  if self.searchBox then
    self.searchBox:SetText(self.searchText or "")
  end
  if self.searchPlaceholder then
    local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
    self.searchPlaceholder:SetText(localeTable.EJ_QUEST_SEARCH_PLACEHOLDER or "Search campaigns / questlines / quests...")
    self.searchPlaceholder:SetShown((self.searchText or "") == "")
  end
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  if self.modeTabButtonByKey.active_log then
    self.modeTabButtonByKey.active_log:SetText(getActiveLogRootText(localeTable))
    self.modeTabButtonByKey.active_log:SetWidth(108)
  end
  if self.modeTabButtonByKey.map_questline then
    self.modeTabButtonByKey.map_questline:SetText(getQuestlineRootText(localeTable))
    self.modeTabButtonByKey.map_questline:SetWidth(92)
  end
  if self.modeTabButtonByKey.campaign then
    self.modeTabButtonByKey.campaign:SetText(getCampaignRootText(localeTable))
    self.modeTabButtonByKey.campaign:SetWidth(92)
  end
  if self.modeTabButtonByKey.achievement then
    self.modeTabButtonByKey.achievement:SetText(getAchievementRootText(localeTable))
    self.modeTabButtonByKey.achievement:SetWidth(92)
  end
  if self.activeLogRecentToggleButton then
    self.activeLogRecentToggleButton:SetText(getRecentCompletedToggleText(localeTable, self.activeLogRecentCollapsed))
    self.activeLogRecentToggleButton:SetWidth(108)
  end
  self:syncTabLabel()
  self:applyContentLayout()
  self:hookVanillaTabsOnce()
end

function QuestlineTreeView:updateVisibility()
  if not self.panelFrame then
    return
  end

  if isStandaloneQuestHost(self.hostJournalFrame) then
    local hostShown = self.hostJournalFrame and self.hostJournalFrame.IsShown and self.hostJournalFrame:IsShown() or false -- 主界面显示状态
    local shouldShowPanel = isQuestlineTreeEnabled() and hostShown and self.selected == true -- 是否显示 quest 主内容
    self:applyContentLayout()
    if self.tabButton and self.tabButton.Hide then
      self.tabButton:Hide()
    end
    if shouldShowPanel then
      if self.headerFrame and self.headerFrame.Show then
        self.headerFrame:Show()
      end
      self.panelFrame:Show()
      self.activeRootState = "quest"
      self:render()
    else
      if self.headerFrame and self.headerFrame.Hide then
        self.headerFrame:Hide()
      end
      self.panelFrame:Hide()
      self.activeRootState = "native"
    end
    return
  end

  if not self.tabButton then
    return
  end

  self:layoutRootTabs()
  self:applyContentLayout()

  local journalShown = self.hostJournalFrame and self.hostJournalFrame.IsShown and self.hostJournalFrame:IsShown() or false -- 冒险手册显示状态
  local treeEnabled = isQuestlineTreeEnabled() -- 模块+设置开关状态
  local canShow = treeEnabled and journalShown -- 模块可用且主框体可见
  local canShowQuestTab = canShow -- 任务页签可见性

  if not canShowQuestTab then
    self.selected = false
  end
  self.tabButton:SetShown(canShowQuestTab)
  self:setTabVisualSelected(canShowQuestTab and self.selected)

  local previousRootState = self.activeRootState or "native" -- 上一轮根状态
  local currentRootState = self:resolveRootState(canShowQuestTab) -- 目标根状态
  local shouldRestoreNative = previousRootState == "quest"
    and currentRootState == "native"
    and not self.pendingNativeSelection -- 是否需要主动恢复原生页签
  if self.headerFrame then
    self.headerFrame:SetShown(currentRootState == "quest")
  end
  self:applyRootState(currentRootState, {
    shouldRestoreNative = shouldRestoreNative,
  })
  self.pendingNativeSelection = false
  self.wasShowingPanel = currentRootState == "quest"
end

function QuestlineTreeView:refresh()
  self:ensureWidgets()
  self:updateVisibility()
end

--- 返回 quest 模块底部分页签模式键顺序。
---@return string[]
function QuestlineTreeView:getBottomTabModeKeys()
  return {
    "active_log",
    "map_questline",
    "campaign",
    "achievement",
  }
end

Internal.QuestlineTreeView = QuestlineTreeView
