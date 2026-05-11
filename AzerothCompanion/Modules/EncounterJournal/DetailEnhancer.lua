--[[
  冒险指南详情增强与列表“仅坐骑”筛选私有实现。
]]

local Internal = AzerothCompanion.Modules.EncounterJournal.Internal -- 冒险指南内部命名空间
local Runtime = Internal.Runtime
local CreateFrame = Internal.CreateFrame

local function isModuleEnabled()
  return Internal.IsModuleEnabled()
end

local function isMountFilterChecked()
  return Internal.IsMountFilterChecked()
end

local function getCurrentScrollBox()
  return Internal.GetCurrentScrollBox()
end

local function getJournalInstanceID(elementData)
  return Internal.GetJournalInstanceID(elementData)
end

local function formatResetTime(seconds)
  return Internal.FormatResetTime(seconds)
end

local function getEncounterInfoFrame()
  return Internal.GetEncounterInfoFrame()
end

local function isListPinAlwaysVisible()
  return Internal.IsListPinAlwaysVisible()
end

local function getListNavigationState()
  return Internal.GetListNavigationState()
end

local function resetListNavigationState()
  return Internal.ResetListNavigationState()
end

local MountFilter = {
  checkButton = nil,
  label = nil,
}

local ListNavigationPin = {}
local PIN_BUTTON_KEY = "_AzerothCompanionEntrancePinButton"
local ROW_HOOKS_INSTALLED_KEY = "_AzerothCompanionEntranceRowHooksInstalled"

--- 检查是否应显示坐骑筛选 UI
---@return boolean
local function shouldShowMountFilterUI()
  local ej = _G.EncounterJournal
  local instSel = ej and ej.instanceSelect
  if not instSel then return false end
  return AzerothCompanion.API.EncounterJournal.IsRaidOrDungeonInstanceListTab() == true
end

--- 创建坐骑筛选 UI
function MountFilter:createUI()
  if self.checkButton then
    self:updateVisibility()
    return
  end

  local ej = _G.EncounterJournal
  local instSel = ej and ej.instanceSelect
  if not instSel then return end
  local anchorTarget = instSel.ExpansionDropdown or instSel -- 按钮锚点目标（优先资料片下拉）

  -- 创建复选框
  local checkBtn = CreateFrame("CheckButton", "AzerothCompanionEJMountFilterCheck", instSel, "UICheckButtonTemplate")
  checkBtn:SetSize(22, 22)
  checkBtn:SetChecked(isMountFilterChecked())
  checkBtn:SetScript("OnClick", function(btn)
    if not isModuleEnabled() then
      btn:SetChecked(false)
      return
    end
    local mountFilterEnabled = btn:GetChecked() and true or false -- 仅坐骑筛选开关
    Internal.SetAccountSetting("ENCOUNTER_JOURNAL_MOUNT_FILTER_ENABLED", mountFilterEnabled)
    local loc = AzerothCompanion.Localization.Strings or {}
    if mountFilterEnabled then
      AzerothCompanion.API.Chat.PrintAddonMessage(loc.EJ_MOUNT_FILTER_NOTIFY_ON or "")
    else
      AzerothCompanion.API.Chat.PrintAddonMessage(loc.EJ_MOUNT_FILTER_NOTIFY_OFF or "")
    end
    if type(_G.EncounterJournal_ListInstances) == "function" then
      pcall(_G.EncounterJournal_ListInstances)
    end
  end)
  checkBtn:SetScript("OnEnter", function(btn)
    local loc = AzerothCompanion.Localization.Strings or {}
    if AzerothCompanion.API.Tooltip and AzerothCompanion.API.Tooltip.SetSkipAnchorOverride then
      AzerothCompanion.API.Tooltip.SetSkipAnchorOverride(GameTooltip, true)
    end
    Runtime.TooltipSetOwner(GameTooltip, btn, "ANCHOR_RIGHT")
    Runtime.TooltipClear(GameTooltip)
    if not isModuleEnabled() then
      Runtime.TooltipSetText(GameTooltip, loc.EJ_MOUNT_FILTER_LABEL or "")
      Runtime.TooltipAddLine(GameTooltip, loc.EJ_MOUNT_FILTER_SETTINGS_DEPENDENCY_DISABLED or "", 1, 0.2, 0.2, true)
    else
      Runtime.TooltipSetText(GameTooltip, loc.EJ_MOUNT_FILTER_HINT or "")
    end
    Runtime.TooltipShow(GameTooltip)
  end)
  checkBtn:SetScript("OnLeave", function()
    if AzerothCompanion.API.Tooltip and AzerothCompanion.API.Tooltip.SetSkipAnchorOverride then
      AzerothCompanion.API.Tooltip.SetSkipAnchorOverride(GameTooltip, false)
    end
    Runtime.TooltipHide(GameTooltip)
  end)

  local anchorSuccess = pcall(function() checkBtn:SetPoint("RIGHT", anchorTarget, "LEFT", -8, 0) end)
  if not anchorSuccess then
    checkBtn:Hide()
    return
  end

  -- 创建标签
  local label = instSel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetJustifyH("RIGHT")
  label:SetText((AzerothCompanion.Localization.Strings and AzerothCompanion.Localization.Strings.EJ_MOUNT_FILTER_LABEL) or "")
  pcall(function() label:SetPoint("RIGHT", checkBtn, "LEFT", -4, 0) end)

  self.checkButton = checkBtn
  self.label = label
  _G.AzerothCompanionEJMountFilterLabel = label

  self:updateVisibility()
end

--- 更新坐骑筛选 UI 可见性
function MountFilter:updateVisibility()
  if not self.checkButton or not self.label then return end
  local success, shouldShow = pcall(shouldShowMountFilterUI)
  if not success then shouldShow = false end
  self.checkButton:SetShown(shouldShow == true)
  self.label:SetShown(shouldShow == true)
end

--- 同步复选框状态
function MountFilter:syncCheckbox()
  if self.checkButton then
    self.checkButton:SetChecked(isMountFilterChecked())
  end
end

--- 检查筛选是否激活
---@return boolean
function MountFilter:isActive()
  return self.checkButton ~= nil
    and self.checkButton:GetChecked() == true
    and isModuleEnabled()
    and shouldShowMountFilterUI()
end

--- 应用坐骑筛选
function MountFilter:applyFilter()
  if not self:isActive() then return end

  local box = getCurrentScrollBox()
  if not box or type(box.GetDataProvider) ~= "function" then return end

  local success, dataProv = pcall(function() return box:GetDataProvider() end)
  if not success or type(dataProv) ~= "table" or type(dataProv.ForEach) ~= "function" then return end

  local toRemove = {}
  pcall(function()
    dataProv:ForEach(function(elementData)
      local jid = getJournalInstanceID(elementData)
      if jid and not AzerothCompanion.API.EncounterJournal.HasMountDrops(jid) then
        toRemove[#toRemove + 1] = elementData
      end
    end)
  end)

  if #toRemove > 0 and type(dataProv.Remove) == "function" then
    for _, elementData in ipairs(toRemove) do
      pcall(function() dataProv:Remove(elementData) end)
    end
  end
end

--- 创建副本列表行右下角的入口导航图钉。
---@param rowFrame table 副本列表行
---@return table button 图钉按钮
function ListNavigationPin:createButton(rowFrame)
  local button = rowFrame[PIN_BUTTON_KEY] -- 复用列表行上的图钉按钮
  if button then
    return button
  end

  local loc = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  button = CreateFrame("Button", nil, rowFrame)
  button:SetSize(30, 30)
  button:SetPoint("BOTTOMRIGHT", rowFrame, "BOTTOMRIGHT", -4, 2)
  if button.SetMotionScriptsWhileDisabled then
    button:SetMotionScriptsWhileDisabled(true)
  end

  local iconTexture = button:CreateTexture(nil, "ARTWORK") -- 地图标记图标
  iconTexture:SetSize(30, 30)
  iconTexture:SetPoint("CENTER", button, "CENTER", 0, 0)
  if iconTexture.SetAtlas then
    iconTexture:SetAtlas("Waypoint-MapPin-Tracked", true)
  else
    iconTexture:SetTexture("Interface\\MINIMAP\\POIIcons")
    iconTexture:SetTexCoord(0.125, 0.25, 0.125, 0.25)
  end
  button._AzerothCompanionEntrancePinIcon = iconTexture

  local highlightTexture = button:CreateTexture(nil, "HIGHLIGHT") -- 悬停高亮
  highlightTexture:SetSize(30, 30)
  highlightTexture:SetPoint("CENTER", button, "CENTER", 0, 0)
  if highlightTexture.SetAtlas then
    highlightTexture:SetAtlas("Waypoint-MapPin-Highlight", true)
  else
    highlightTexture:SetColorTexture(1, 0.82, 0.1, 0.22)
    if highlightTexture.SetBlendMode then
      highlightTexture:SetBlendMode("ADD")
    end
  end
  button._AzerothCompanionEntrancePinHighlight = highlightTexture

  button:SetScript("OnClick", function(buttonFrame)
    local journalInstanceID = buttonFrame._AzerothCompanionJournalInstanceID -- 当前列表行副本 ID
    if type(journalInstanceID) ~= "number" then
      AzerothCompanion.API.Chat.PrintAddonMessage(loc.EJ_ENTRANCE_NAV_UNAVAILABLE or "未找到该副本的入口位置。")
      return
    end
    if not AzerothCompanion.API.EncounterJournal or type(AzerothCompanion.API.EncounterJournal.NavigateToDungeonEntrance) ~= "function" then
      AzerothCompanion.API.Chat.PrintAddonMessage(loc.EJ_ENTRANCE_NAV_UNAVAILABLE or "未找到该副本的入口位置。")
      return
    end

    local navigateSuccess, navigateResult = AzerothCompanion.API.EncounterJournal.NavigateToDungeonEntrance(journalInstanceID)
    if navigateSuccess == true then
      local entranceName = type(navigateResult) == "table" and navigateResult.name or nil -- 入口名称
      AzerothCompanion.API.Chat.PrintAddonMessage(string.format(
        loc.EJ_ENTRANCE_NAV_NOTIFY_FMT or "已导航到：%s",
        tostring(entranceName or loc.EJ_ENTRANCE_NAV_FALLBACK_NAME or "副本入口")
      ))
      return
    end

    AzerothCompanion.API.Chat.PrintAddonMessage(loc.EJ_ENTRANCE_NAV_UNAVAILABLE or "未找到该副本的入口位置。")
  end)

  button:SetScript("OnEnter", function(buttonFrame)
    if AzerothCompanion.API.Tooltip and AzerothCompanion.API.Tooltip.SetSkipAnchorOverride then
      AzerothCompanion.API.Tooltip.SetSkipAnchorOverride(GameTooltip, true)
    end
    Runtime.TooltipSetOwner(GameTooltip, buttonFrame, "ANCHOR_RIGHT")
    Runtime.TooltipClear(GameTooltip)
    Runtime.TooltipSetText(GameTooltip, loc.EJ_ENTRANCE_NAV_BUTTON or "导航入口")
    Runtime.TooltipAddLine(GameTooltip, loc.EJ_ENTRANCE_NAV_TOOLTIP or "打开地图并导航到该副本入口。", 1, 1, 1, true)
    Runtime.TooltipShow(GameTooltip)
  end)

  button:SetScript("OnLeave", function()
    if AzerothCompanion.API.Tooltip and AzerothCompanion.API.Tooltip.SetSkipAnchorOverride then
      AzerothCompanion.API.Tooltip.SetSkipAnchorOverride(GameTooltip, false)
    end
    Runtime.TooltipHide(GameTooltip)

    local parentRow = button.GetParent and button:GetParent() or nil -- 图钉所属列表行
    local journalInstanceID = button._AzerothCompanionJournalInstanceID -- 当前图钉副本 ID
    local state = getListNavigationState() -- 列表交互状态
    local rowStillHovered = parentRow and parentRow.IsMouseOver and parentRow:IsMouseOver() -- 鼠标是否回到列表行
    if state.hoveredJournalInstanceID == journalInstanceID and rowStillHovered ~= true then
      state.hoveredJournalInstanceID = nil
      ListNavigationPin:updateFrames()
    end
  end)

  rowFrame[PIN_BUTTON_KEY] = button
  return button
end

--- 检查指定列表行是否应显示图钉。
---@param journalInstanceID number|nil 副本 ID
---@return boolean
function ListNavigationPin:shouldShowForJournalInstance(journalInstanceID)
  if type(journalInstanceID) ~= "number" then
    return false
  end
  if isListPinAlwaysVisible() then
    return true
  end

  local state = getListNavigationState() -- 列表交互状态
  return state.hoveredJournalInstanceID == journalInstanceID
end

--- 为副本列表行安装悬停脚本。
---@param rowFrame table 副本列表行
function ListNavigationPin:ensureRowHooks(rowFrame)
  if not rowFrame or rowFrame[ROW_HOOKS_INSTALLED_KEY] == true or not rowFrame.HookScript then
    return
  end

  rowFrame[ROW_HOOKS_INSTALLED_KEY] = true
  rowFrame:HookScript("OnEnter", function(buttonFrame, ...)
    local journalInstanceID = buttonFrame._AzerothCompanionJournalInstanceID -- 当前悬停行副本 ID
    if type(journalInstanceID) == "number" then
      getListNavigationState().hoveredJournalInstanceID = journalInstanceID
    end
    ListNavigationPin:updateFrames()
  end)

  rowFrame:HookScript("OnLeave", function(buttonFrame, ...)
    local pinButton = buttonFrame[PIN_BUTTON_KEY] -- 当前行图钉按钮
    local pinStillHovered = pinButton and pinButton.IsMouseOver and pinButton:IsMouseOver() -- 鼠标是否移入图钉
    if pinStillHovered == true then
      return
    end
    local state = getListNavigationState() -- 列表交互状态
    if state.hoveredJournalInstanceID == buttonFrame._AzerothCompanionJournalInstanceID then
      state.hoveredJournalInstanceID = nil
    end
    ListNavigationPin:updateFrames()
  end)
end

--- 刷新副本列表行图钉。
function ListNavigationPin:updateFrames()
  if not isModuleEnabled() or AzerothCompanion.API.EncounterJournal.IsRaidOrDungeonInstanceListTab() ~= true then
    self:clearAllFrames()
    return
  end

  local box = getCurrentScrollBox()
  if not box or type(box.ForEachFrame) ~= "function" then
    return
  end

  pcall(function()
    box:ForEachFrame(function(rowFrame)
      if not rowFrame or type(rowFrame.GetElementData) ~= "function" then
        return
      end
      local dataSuccess, elementData = pcall(function() return rowFrame:GetElementData() end)
      local journalInstanceID = dataSuccess and getJournalInstanceID(elementData) or nil -- 当前行副本 ID
      if type(journalInstanceID) ~= "number" then
        local oldButton = rowFrame[PIN_BUTTON_KEY] -- 旧图钉按钮
        if oldButton then
          oldButton:Hide()
        end
        return
      end

      rowFrame._AzerothCompanionJournalInstanceID = journalInstanceID
      self:ensureRowHooks(rowFrame)

      local button = self:createButton(rowFrame)
      button._AzerothCompanionJournalInstanceID = journalInstanceID
      button:SetShown(self:shouldShowForJournalInstance(journalInstanceID))
      if button.SetEnabled then
        button:SetEnabled(true)
      end
    end)
  end)
end

--- 清理当前列表行上的图钉按钮。
function ListNavigationPin:clearAllFrames()
  local box = getCurrentScrollBox()
  if not box or type(box.ForEachFrame) ~= "function" then
    getListNavigationState().hoveredJournalInstanceID = nil
    return
  end

  getListNavigationState().hoveredJournalInstanceID = nil
  pcall(function()
    box:ForEachFrame(function(rowFrame)
      local button = rowFrame and rowFrame[PIN_BUTTON_KEY] or nil -- 当前行图钉按钮
      if button then
        button:Hide()
      end
    end)
  end)
end

--- 清理副本列表交互状态。
function ListNavigationPin:clearInteractionState()
  resetListNavigationState()
end

-- ============================================================================
-- 详情页增强对象（仅坐骑筛选 + 标题后锁定文本）
-- ============================================================================

local function getCurrentDetailJournalInstanceID()
  if type(EJ_GetCurrentInstance) ~= "function" then
    local encounterJournalFrame = _G.EncounterJournal -- 冒险手册根框体
    local fallbackInstanceID = encounterJournalFrame and encounterJournalFrame.instanceID -- 当前界面记录的副本 ID
    if type(fallbackInstanceID) == "number" and fallbackInstanceID > 0 then
      return fallbackInstanceID
    end
    return nil
  end
  local ok, journalInstanceID = pcall(EJ_GetCurrentInstance)
  if ok and type(journalInstanceID) == "number" and journalInstanceID > 0 then
    return journalInstanceID
  end

  local encounterJournalFrame = _G.EncounterJournal -- 冒险手册根框体
  local fallbackInstanceID = encounterJournalFrame and encounterJournalFrame.instanceID -- 当前界面记录的副本 ID
  if type(fallbackInstanceID) == "number" and fallbackInstanceID > 0 then
    return fallbackInstanceID
  end

  return nil
end

local function isEncounterDetailVisible()
  local infoFrame = getEncounterInfoFrame() -- 详情信息面板
  if infoFrame and infoFrame.IsShown then
    local infoSuccess, infoShown = pcall(function() return infoFrame:IsShown() end)
    if infoSuccess and infoShown == true then
      return true
    end
  end

  local ej = _G.EncounterJournal
  local encounterFrame = ej and ej.encounter
  if encounterFrame and encounterFrame.IsShown then
    local encounterSuccess, encounterShown = pcall(function() return encounterFrame:IsShown() end)
    if encounterSuccess and encounterShown == true then
      return true
    end
  end

  return false
end

local function getDetailDifficultyControl()
  local info = getEncounterInfoFrame()
  if not info then
    return nil
  end
  return info.Difficulty or info.difficulty or _G.EncounterJournalEncounterFrameInfoDifficulty
end

local function getDetailInstanceTitleControl()
  local info = getEncounterInfoFrame() -- 详情信息面板
  if not info then
    return nil
  end
  return info.InstanceTitle or info.instanceTitle or _G.EncounterJournalEncounterFrameInfoInstanceTitle
end

local function getVisibleTitleTextWidth(titleControl)
  if not titleControl then
    return 0
  end
  local stringWidth = 0 -- 标题文本宽度
  if titleControl.GetStringWidth then
    local stringWidthSuccess, widthValue = pcall(function() return titleControl:GetStringWidth() end)
    if stringWidthSuccess and type(widthValue) == "number" and widthValue > 0 then
      stringWidth = widthValue
    end
  end
  if titleControl.GetWidth then
    local controlWidthSuccess, controlWidth = pcall(function() return titleControl:GetWidth() end)
    if controlWidthSuccess and type(controlWidth) == "number" and controlWidth > 0 and stringWidth > controlWidth then
      stringWidth = controlWidth
    end
  end
  return stringWidth
end

local function isDetailInstanceTitleVisible()
  local titleControl = getDetailInstanceTitleControl() -- 副本标题控件
  if not titleControl or not titleControl.IsShown then
    return false
  end
  local shownSuccess, shownValue = pcall(function() return titleControl:IsShown() end)
  return shownSuccess and shownValue == true
end

local function pickFallbackLockout(lockoutList)
  if type(lockoutList) ~= "table" or #lockoutList == 0 then
    return nil
  end

  local chosenLockout = nil -- 回退锁定记录
  for _, lockoutEntry in ipairs(lockoutList) do
    if type(lockoutEntry) == "table" and (lockoutEntry.resetTime or 0) > 0 then
      if not chosenLockout or (lockoutEntry.resetTime or math.huge) < (chosenLockout.resetTime or math.huge) then
        chosenLockout = lockoutEntry
      end
    end
  end

  return chosenLockout or lockoutList[1]
end

local function resolveDetailLockout(journalInstanceID, difficultyID)
  local lockoutInfo = nil -- 当前难度锁定信息
  if AzerothCompanion.API.EncounterJournal and AzerothCompanion.API.EncounterJournal.GetLockoutForInstanceAndDifficulty then
    lockoutInfo = AzerothCompanion.API.EncounterJournal.GetLockoutForInstanceAndDifficulty(journalInstanceID, difficultyID)
  end
  if lockoutInfo then
    return lockoutInfo
  end

  -- 当前难度未命中时，回退到该副本已有锁定（优先最近重置）。
  if AzerothCompanion.API.EncounterJournal and AzerothCompanion.API.EncounterJournal.GetAllLockoutsForInstance then
    local allLockouts = AzerothCompanion.API.EncounterJournal.GetAllLockoutsForInstance(journalInstanceID)
    return pickFallbackLockout(allLockouts)
  end

  return nil
end

local DetailEnhancer = {
  lockoutLabel = nil,
}

function DetailEnhancer:ensureLockoutLabel()
  if self.lockoutLabel then
    return
  end

  local info = getEncounterInfoFrame()
  if not info then
    return
  end

  local label = info:CreateFontString("AzerothCompanionEJDetailLockoutLabel", "OVERLAY", "GameFontHighlightSmall")
  label:SetJustifyH("LEFT")
  label:SetText("")

  self.lockoutLabel = label
  self:refreshLockoutLabelAnchor()
end

function DetailEnhancer:refreshLockoutLabelAnchor()
  if not self.lockoutLabel then
    return
  end

  local info = getEncounterInfoFrame() -- 详情信息面板
  if not info then
    return
  end

  local label = self.lockoutLabel -- 重置时间标签
  local titleAnchor = getDetailInstanceTitleControl() -- 副本名称锚点（右侧详情区标题）
  local difficultyControl = getDetailDifficultyControl() -- 难度控件锚点

  if label.ClearAllPoints then
    label:ClearAllPoints()
  end
  if titleAnchor and titleAnchor.SetPoint then
    local textWidth = getVisibleTitleTextWidth(titleAnchor) -- 副本标题可见文本宽度
    label:SetPoint("LEFT", titleAnchor, "LEFT", textWidth + 8, 0)
  elseif difficultyControl and difficultyControl.SetPoint then
    label:SetPoint("RIGHT", difficultyControl, "LEFT", -12, 0)
  else
    label:SetPoint("TOPLEFT", info, "TOPLEFT", 180, -10)
  end
end

function DetailEnhancer:updateVisibility()
  local detailShown = isEncounterDetailVisible()
  local instanceTitleShown = isDetailInstanceTitleVisible()
  if self.lockoutLabel then
    self:refreshLockoutLabelAnchor()
    self.lockoutLabel:SetShown(detailShown and instanceTitleShown and isModuleEnabled())
  end
end

function DetailEnhancer:updateLockoutLabel()
  if not self.lockoutLabel then
    return
  end
  if not isEncounterDetailVisible() or not isModuleEnabled() or not isDetailInstanceTitleVisible() then
    self.lockoutLabel:SetText("")
    self.lockoutLabel:SetShown(false)
    return
  end

  local loc = AzerothCompanion.Localization.Strings or {}
  local journalInstanceID = getCurrentDetailJournalInstanceID()
  local difficultyID = AzerothCompanion.API.EncounterJournal.GetSelectedDifficultyID and AzerothCompanion.API.EncounterJournal.GetSelectedDifficultyID() or nil
  local lockout = resolveDetailLockout(journalInstanceID, difficultyID) -- 展示用锁定信息
  if lockout and (lockout.resetTime or 0) > 0 then
    local timeText = formatResetTime(lockout.resetTime or 0)
    self.lockoutLabel:SetText(string.format(loc.EJ_DETAIL_LOCKOUT_FMT or "重置：%s", timeText))
    self.lockoutLabel:SetShown(true)
  else
    self.lockoutLabel:SetText("")
    self.lockoutLabel:SetShown(false)
  end
end

function DetailEnhancer:refresh()
  self:ensureLockoutLabel()
  self:updateVisibility()
  self:updateLockoutLabel()
end

Internal.MountFilter = MountFilter
Internal.ListNavigationPin = ListNavigationPin
Internal.DetailEnhancer = DetailEnhancer
