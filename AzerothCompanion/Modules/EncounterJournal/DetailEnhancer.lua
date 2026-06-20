--[[
  冒险指南详情增强与列表掉落筛选私有实现。
]]

local Internal = AzerothCompanion.Modules.EncounterJournal.Internal -- 冒险指南内部命名空间
local Runtime = Internal.Runtime -- 运行时适配器
local CreateFrame = Internal.CreateFrame -- Frame 创建函数

local function isModuleEnabled()
  return Internal.IsModuleEnabled()
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

local DropFilter = { -- 副本列表掉落筛选控件状态
  dropdown = nil,
  label = nil,
}

local DROP_TYPE_ORDER = { "mount", "pet", "recipe", "housing_decoration" } -- 列表下拉可勾选的掉落类型顺序
local DROP_OWNERSHIP_ORDER = { "collected", "uncollected" } -- 合并下拉中的获取状态顺序
local DETAIL_LOOT_FILTER_ALL = "all" -- 详情页不过滤掉落类型

local ListNavigationPin = {} -- 副本列表入口图钉控制器
local PIN_BUTTON_KEY = "_AzerothCompanionEntrancePinButton" -- 列表行图钉缓存字段
local ROW_HOOKS_INSTALLED_KEY = "_AzerothCompanionEntranceRowHooksInstalled" -- 列表行 hook 安装标记字段

--- 读取掉落类型文案。
---@param dropType string 掉落类型
---@return string
local function getDropTypeLabel(dropType)
  local loc = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  local labels = { -- 掉落类型显示文案
    all = loc.EJ_DROP_FILTER_TYPE_ALL or "全部",
    mount = loc.EJ_DROP_FILTER_TYPE_MOUNT or "坐骑",
    pet = loc.EJ_DROP_FILTER_TYPE_PET or "宠物",
    recipe = loc.EJ_DROP_FILTER_TYPE_RECIPE or "图纸",
    housing_decoration = loc.EJ_DROP_FILTER_TYPE_HOUSING_DECORATION or "住宅装饰",
  }
  return labels[dropType] or labels.mount
end

--- 读取掉落类型下拉摘要。
---@param selectedTypes table 当前类型勾选集合
---@return string
local function getDropTypeSummaryLabel(selectedTypes)
  local labelList = {} -- 已选类型文案
  for _, dropType in ipairs(DROP_TYPE_ORDER) do
    if type(selectedTypes) == "table" and selectedTypes[dropType] == true then
      labelList[#labelList + 1] = getDropTypeLabel(dropType)
    end
  end
  if #labelList == 0 then
    return getDropTypeLabel("all")
  end
  return table.concat(labelList, "+")
end

--- 读取获取状态文案。
---@param ownership string 获取状态
---@return string
local function getOwnershipLabel(ownership)
  local loc = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  local labels = { -- 获取状态显示文案
    all = loc.EJ_DROP_FILTER_OWNERSHIP_ALL or "全部",
    collected = loc.EJ_DROP_FILTER_OWNERSHIP_COLLECTED or "已获取",
    uncollected = loc.EJ_DROP_FILTER_OWNERSHIP_UNCOLLECTED or "未获取",
  }
  return labels[ownership] or labels.all
end

--- 根据两个状态勾选值归一成单值存档。
---@param selectedCollected boolean 已获取是否勾选
---@param selectedUncollected boolean 未获取是否勾选
---@return string nextOwnership 获取状态存档值
local function resolveOwnershipSelection(selectedCollected, selectedUncollected)
  if selectedCollected == true and selectedUncollected ~= true then
    return "collected"
  elseif selectedUncollected == true and selectedCollected ~= true then
    return "uncollected"
  end
  return "all"
end

--- 读取合并下拉摘要。
---@return string
local function getDropFilterSummaryLabel()
  local typeText = getDropTypeSummaryLabel(Internal.GetDropFilterTypes()) -- 类型摘要
  local ownership = Internal.GetDropFilterOwnership() -- 获取状态
  if ownership == "all" then
    return typeText
  end
  return typeText .. " · " .. getOwnershipLabel(ownership)
end

--- 刷新副本列表，让原生列表重建后再应用插件筛选。
local function refreshListInstances()
  if type(_G.EncounterJournal_ListInstances) == "function" then
    pcall(_G.EncounterJournal_ListInstances)
  end
end

--- 创建下拉按钮；原生模板不可用时回退到普通按钮。
---@param parentFrame table 父框体
---@param frameName string 全局框体名
---@return table|nil
local function createDropdownButton(parentFrame, frameName)
  local success, dropdownButton = pcall(CreateFrame, "DropdownButton", frameName, parentFrame, "WowStyle1DropdownTemplate")
  if success and dropdownButton then
    return dropdownButton
  end
  return CreateFrame("Button", frameName, parentFrame, "UIPanelButtonTemplate")
end

--- 设置菜单勾选项；兼容测试替身与 Retail 下拉菜单描述。
---@param rootDescription table 菜单描述
---@param optionLabel string 菜单项文本
---@param isSelectedFunc function 选中判断
---@param setSelectedFunc function 选中回调
---@param optionValue any 菜单值
local function createMenuCheckbox(rootDescription, optionLabel, isSelectedFunc, setSelectedFunc, optionValue)
  if rootDescription and type(rootDescription.CreateCheckbox) == "function" then
    rootDescription:CreateCheckbox(optionLabel, isSelectedFunc, setSelectedFunc, optionValue)
  elseif rootDescription and type(rootDescription.CreateRadio) == "function" then
    rootDescription:CreateRadio(optionLabel, isSelectedFunc, setSelectedFunc, optionValue)
  end
end

--- 检查是否应显示掉落筛选 UI。
---@return boolean
local function shouldShowDropFilterUI()
  local encounterJournalFrame = _G.EncounterJournal -- 冒险手册根框体
  local instanceSelectFrame = encounterJournalFrame and encounterJournalFrame.instanceSelect -- 副本列表面板
  if not instanceSelectFrame then return false end
  return AzerothCompanion.API.EncounterJournal.IsRaidOrDungeonInstanceListTab() == true
end

--- 创建掉落筛选 UI。
function DropFilter:createUI()
  if self.dropdown then
    self:updateVisibility()
    self:syncDropdown()
    return
  end

  local encounterJournalFrame = _G.EncounterJournal -- 冒险手册根框体
  local instanceSelectFrame = encounterJournalFrame and encounterJournalFrame.instanceSelect -- 副本列表面板
  if not instanceSelectFrame then return end
  local anchorTarget = instanceSelectFrame.ExpansionDropdown or instanceSelectFrame -- 按钮锚点目标（优先资料片下拉）

  local dropdown = createDropdownButton(instanceSelectFrame, "AzerothCompanionEJDropFilterDropdown") -- 合并掉落筛选下拉
  dropdown:SetSize(132, 22)
  if type(dropdown.SetupMenu) == "function" then
    dropdown:SetupMenu(function(_, rootDescription)
      for _, dropType in ipairs(DROP_TYPE_ORDER) do
        local currentType = dropType -- 捕获当前掉落类型
        createMenuCheckbox(
          rootDescription,
          getDropTypeLabel(currentType),
          function()
            return Internal.IsDropFilterTypeSelected(currentType)
          end,
          function()
            local wasSelected = Internal.IsDropFilterTypeSelected(currentType) -- 当前是否已选
            Internal.SetDropFilterTypeSelected(currentType, wasSelected ~= true)
            DropFilter:syncDropdown()
            refreshListInstances()
          end,
          currentType
        )
      end
      if rootDescription and type(rootDescription.CreateDivider) == "function" then
        rootDescription:CreateDivider()
      end
      for _, ownershipKey in ipairs(DROP_OWNERSHIP_ORDER) do
        local currentOwnership = ownershipKey -- 捕获当前获取状态
        createMenuCheckbox(
          rootDescription,
          getOwnershipLabel(currentOwnership),
          function()
            local ownership = Internal.GetDropFilterOwnership() -- 当前获取状态
            return ownership == "all" or ownership == currentOwnership
          end,
          function()
            local ownership = Internal.GetDropFilterOwnership() -- 当前获取状态
            local selectedCollected = ownership == "all" or ownership == "collected" -- 已获取勾选状态
            local selectedUncollected = ownership == "all" or ownership == "uncollected" -- 未获取勾选状态
            if currentOwnership == "collected" then
              selectedCollected = selectedCollected ~= true
            elseif currentOwnership == "uncollected" then
              selectedUncollected = selectedUncollected ~= true
            end
            local nextOwnership = resolveOwnershipSelection(selectedCollected, selectedUncollected) -- 归一后的状态
            Internal.SetDropFilterOwnership(nextOwnership)
            DropFilter:syncDropdown()
            refreshListInstances()
          end,
          currentOwnership
        )
      end
    end)
  end
  dropdown:SetScript("OnEnter", function(buttonFrame)
    local loc = AzerothCompanion.Localization.Strings or {} -- 本地化文案
    if AzerothCompanion.API.Tooltip and AzerothCompanion.API.Tooltip.SetSkipAnchorOverride then
      AzerothCompanion.API.Tooltip.SetSkipAnchorOverride(GameTooltip, true)
    end
    Runtime.TooltipSetOwner(GameTooltip, buttonFrame, "ANCHOR_RIGHT")
    Runtime.TooltipClear(GameTooltip)
    if not isModuleEnabled() then
      Runtime.TooltipSetText(GameTooltip, loc.EJ_DROP_FILTER_LABEL or "")
      Runtime.TooltipAddLine(GameTooltip, loc.EJ_DROP_FILTER_SETTINGS_DEPENDENCY_DISABLED or "", 1, 0.2, 0.2, true)
    else
      Runtime.TooltipSetText(GameTooltip, loc.EJ_DROP_FILTER_HINT or loc.EJ_DROP_FILTER_TYPE_HINT or "")
    end
    Runtime.TooltipShow(GameTooltip)
  end)
  dropdown:SetScript("OnLeave", function()
    if AzerothCompanion.API.Tooltip and AzerothCompanion.API.Tooltip.SetSkipAnchorOverride then
      AzerothCompanion.API.Tooltip.SetSkipAnchorOverride(GameTooltip, false)
    end
    Runtime.TooltipHide(GameTooltip)
  end)

  local anchorSuccess = pcall(function()
    dropdown:SetPoint("RIGHT", anchorTarget, "LEFT", -8, 0)
  end) -- 锚点设置结果
  if not anchorSuccess then
    dropdown:Hide()
    return
  end

  local label = instanceSelectFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") -- 筛选控件标签
  label:SetJustifyH("RIGHT")
  label:SetText((AzerothCompanion.Localization.Strings and AzerothCompanion.Localization.Strings.EJ_DROP_FILTER_LABEL) or "掉落筛选")
  pcall(function() label:SetPoint("RIGHT", dropdown, "LEFT", -4, 0) end)

  self.dropdown = dropdown
  self.label = label
  _G.AzerothCompanionEJDropFilterLabel = label
  _G.AzerothCompanionEJDropFilterDropdown = dropdown
  _G.AzerothCompanionEJDropFilterOwnershipButton = nil
  _G.AzerothCompanionEJMountFilterLabel = nil

  self:syncDropdown()
  self:updateVisibility()
end

--- 更新掉落筛选 UI 可见性。
function DropFilter:updateVisibility()
  if not self.dropdown or not self.label then return end
  local success, shouldShow = pcall(shouldShowDropFilterUI) -- 可见性判断结果
  if not success then shouldShow = false end
  self.dropdown:SetShown(shouldShow == true)
  self.label:SetShown(shouldShow == true)
end

--- 同步合并下拉文案。
function DropFilter:syncDropdown()
  if self.dropdown then
    self.dropdown:SetText(getDropFilterSummaryLabel())
  end
end

--- 检查筛选是否激活。
---@return boolean
function DropFilter:isActive()
  return self.dropdown ~= nil
    and isModuleEnabled()
    and shouldShowDropFilterUI()
end

--- 应用掉落筛选。
function DropFilter:applyFilter()
  if not self:isActive() then return end

  local box = getCurrentScrollBox() -- 当前列表 ScrollBox
  if not box or type(box.GetDataProvider) ~= "function" then return end

  local success, dataProv = pcall(function() return box:GetDataProvider() end) -- 列表数据源读取结果
  if not success or type(dataProv) ~= "table" or type(dataProv.ForEach) ~= "function" then return end

  local toRemove = {} -- 待从列表移除的数据项
  local dropTypes = Internal.GetDropFilterTypes() -- 当前掉落类型筛选
  local ownership = Internal.GetDropFilterOwnership() -- 当前获取状态筛选
  pcall(function()
    dataProv:ForEach(function(elementData)
      local journalInstanceID = getJournalInstanceID(elementData) -- 当前列表项副本 ID
      if journalInstanceID and not AzerothCompanion.API.EncounterJournal.HasMatchingDropsForInstance(journalInstanceID, dropTypes, ownership) then
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
-- 详情页增强对象（掉落筛选 + 标题后锁定文本）
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

local detailLootFilterType = DETAIL_LOOT_FILTER_ALL -- 当前详情页临时掉落类型筛选

--- 获取详情页战利品容器。
---@return table|nil
local function getDetailLootContainer()
  local infoFrame = getEncounterInfoFrame() -- 详情信息面板
  return infoFrame and infoFrame.LootContainer or nil
end

--- 获取详情页战利品数据源。
---@return table|nil dataProvider 战利品数据源
local function getDetailLootDataProvider()
  local lootContainer = getDetailLootContainer() -- 战利品容器
  local scrollBox = lootContainer and lootContainer.ScrollBox -- 战利品 ScrollBox
  if not scrollBox or type(scrollBox.GetDataProvider) ~= "function" then
    return nil
  end
  local success, dataProvider = pcall(function() return scrollBox:GetDataProvider() end) -- 数据源读取结果
  if success and type(dataProvider) == "table" and type(dataProvider.ForEach) == "function" then
    return dataProvider
  end
  return nil
end

--- 从详情页战利品 elementData 中读取 itemID。
---@param elementData table|nil 战利品行数据
---@return number|nil itemID 物品 ID
local function getDetailLootItemID(elementData)
  if type(elementData) ~= "table" then
    return nil
  end
  if type(elementData.itemID) == "number" then
    return elementData.itemID
  end
  if type(elementData.itemInfo) == "table" and type(elementData.itemInfo.itemID) == "number" then
    return elementData.itemInfo.itemID
  end
  local lootIndex = tonumber(elementData.index or elementData.lootIndex) -- Blizzard 战利品索引
  if lootIndex and C_EncounterJournal and type(C_EncounterJournal.GetLootInfoByIndex) == "function" then
    local infoSuccess, itemInfo = pcall(C_EncounterJournal.GetLootInfoByIndex, lootIndex)
    if infoSuccess and type(itemInfo) == "table" and type(itemInfo.itemID) == "number" then
      return itemInfo.itemID
    end
  end
  return nil
end

--- 读取原生无栏位过滤值。
---@return number|string
local function getNoSlotFilterValue()
  return Enum and Enum.ItemSlotFilterType and Enum.ItemSlotFilterType.NoFilter or 0
end

--- 安全触发原生栏位过滤。
---@param slotFilter any 原生栏位过滤值
local function setBlizzardSlotFilter(slotFilter)
  if type(_G.EncounterJournal_SetSlotFilterInternal) == "function" then
    pcall(_G.EncounterJournal_SetSlotFilterInternal, _G.EncounterJournal, slotFilter)
  elseif C_EncounterJournal and type(C_EncounterJournal.SetSlotFilter) == "function" then
    pcall(C_EncounterJournal.SetSlotFilter, slotFilter)
  end
end

--- 安全刷新详情页战利品列表。
local function refreshDetailLoot()
  if type(_G.EncounterJournal_LootUpdate) == "function" then
    pcall(_G.EncounterJournal_LootUpdate)
  end
end

--- 为详情页栏位下拉创建一个原生栏位单选项。
---@param rootDescription table 菜单描述
---@param optionLabel string 菜单项文本
---@param slotFilter any 原生栏位过滤值
local function createNativeSlotFilterRadio(rootDescription, optionLabel, slotFilter)
  if not rootDescription or type(rootDescription.CreateRadio) ~= "function" then
    return
  end
  rootDescription:CreateRadio(
    optionLabel,
    function()
      if detailLootFilterType ~= DETAIL_LOOT_FILTER_ALL then
        return false
      end
      if C_EncounterJournal and type(C_EncounterJournal.GetSlotFilter) == "function" then
        local success, currentFilter = pcall(C_EncounterJournal.GetSlotFilter)
        return success and currentFilter == slotFilter
      end
      return slotFilter == getNoSlotFilterValue()
    end,
    function()
      detailLootFilterType = DETAIL_LOOT_FILTER_ALL
      setBlizzardSlotFilter(slotFilter)
      refreshDetailLoot()
    end,
    slotFilter
  )
end

--- 构建 Retail 原生栏位过滤值到显示名的映射。
---@return table filterNameMap 栏位过滤名表
local function buildSlotFilterNameMap()
  local enumTable = Enum and Enum.ItemSlotFilterType -- 原生栏位过滤枚举
  if type(enumTable) ~= "table" then
    return {}
  end
  local filterNameMap = {} -- 原生栏位名表
  local function addFilter(filterValue, filterName)
    if filterValue ~= nil and type(filterName) == "string" then
      filterNameMap[filterValue] = filterName
    end
  end
  addFilter(enumTable.Head, _G.INVTYPE_HEAD)
  addFilter(enumTable.Neck, _G.INVTYPE_NECK)
  addFilter(enumTable.Shoulder, _G.INVTYPE_SHOULDER)
  addFilter(enumTable.Cloak, _G.INVTYPE_CLOAK)
  addFilter(enumTable.Chest, _G.INVTYPE_CHEST)
  addFilter(enumTable.Wrist, _G.INVTYPE_WRIST)
  addFilter(enumTable.Hand, _G.INVTYPE_HAND)
  addFilter(enumTable.Hands, _G.INVTYPE_HAND)
  addFilter(enumTable.Waist, _G.INVTYPE_WAIST)
  addFilter(enumTable.Legs, _G.INVTYPE_LEGS)
  addFilter(enumTable.Feet, _G.INVTYPE_FEET)
  addFilter(enumTable.MainHand, _G.INVTYPE_WEAPONMAINHAND)
  addFilter(enumTable.OffHand, _G.INVTYPE_WEAPONOFFHAND)
  addFilter(enumTable.Finger, _G.INVTYPE_FINGER)
  addFilter(enumTable.Trinket, _G.INVTYPE_TRINKET)
  addFilter(enumTable.Other, _G.EJ_LOOT_SLOT_FILTER_OTHER)
  return filterNameMap
end

--- 扫描当前详情页实际存在的原生栏位过滤类型。
---@return table presentMap 当前战利品存在的栏位过滤集合
local function getLootSlotsPresent()
  local presentMap = {} -- 已出现的栏位过滤集合
  if not C_EncounterJournal or type(C_EncounterJournal.GetSlotFilter) ~= "function" or type(C_EncounterJournal.ResetSlotFilter) ~= "function"
    or type(C_EncounterJournal.SetSlotFilter) ~= "function" or type(C_EncounterJournal.GetLootInfoByIndex) ~= "function" or type(EJ_GetNumLoot) ~= "function" then
    return presentMap
  end
  local currentFilter = nil -- 扫描前原生栏位过滤
  local filterSuccess, filterValue = pcall(C_EncounterJournal.GetSlotFilter)
  if filterSuccess then
    currentFilter = filterValue
  end
  pcall(C_EncounterJournal.ResetSlotFilter)
  local countSuccess, lootCount = pcall(EJ_GetNumLoot)
  if countSuccess and type(lootCount) == "number" then
    for lootIndex = 1, lootCount do
      local infoSuccess, itemInfo = pcall(C_EncounterJournal.GetLootInfoByIndex, lootIndex)
      local filterType = infoSuccess and type(itemInfo) == "table" and itemInfo.filterType or nil -- 当前物品栏位过滤
      if filterType ~= nil then
        presentMap[filterType] = true
      end
    end
  end
  if currentFilter ~= nil then
    pcall(C_EncounterJournal.SetSlotFilter, currentFilter)
  end
  return presentMap
end

--- 添加详情页掉落类型单选项。
---@param rootDescription table 菜单描述
---@param dropType string 掉落类型
local function createDetailLootTypeRadio(rootDescription, dropType)
  if not rootDescription or type(rootDescription.CreateRadio) ~= "function" then
    return
  end
  rootDescription:CreateRadio(
    getDropTypeLabel(dropType),
    function()
      return detailLootFilterType == dropType
    end,
    function()
      detailLootFilterType = dropType
      setBlizzardSlotFilter(getNoSlotFilterValue())
      refreshDetailLoot()
    end,
    dropType
  )
end

--- 为详情页原“所有栏位”下拉安装插件类型筛选选项。
local function setupDetailLootSlotFilterDropdown()
  local lootContainer = getDetailLootContainer() -- 战利品容器
  local slotFilter = lootContainer and (lootContainer.slotFilter or lootContainer.SlotFilter) -- 原生栏位下拉
  if not slotFilter or type(slotFilter.SetupMenu) ~= "function" then
    return
  end
  slotFilter._AzerothCompanionDetailLootFilterInstalled = true
  slotFilter:SetupMenu(function(_, rootDescription)
    if rootDescription and type(rootDescription.SetTag) == "function" then
      rootDescription:SetTag("MENU_AZEROTHCOMPANION_EJ_DETAIL_LOOT_FILTER")
    end
    createNativeSlotFilterRadio(rootDescription, _G.ALL_INVENTORY_SLOTS or "所有栏位", getNoSlotFilterValue())
    local slotNameMap = buildSlotFilterNameMap() -- 原生栏位名表
    local presentMap = getLootSlotsPresent() -- 当前掉落存在的栏位
    local currentSlotFilter = nil -- 当前原生栏位过滤
    if C_EncounterJournal and type(C_EncounterJournal.GetSlotFilter) == "function" then
      local filterSuccess, filterValue = pcall(C_EncounterJournal.GetSlotFilter)
      if filterSuccess then
        currentSlotFilter = filterValue
      end
    end
    for slotFilterValue, slotName in pairs(slotNameMap) do
      if slotName and (presentMap[slotFilterValue] == true or currentSlotFilter == slotFilterValue) then
        createNativeSlotFilterRadio(rootDescription, slotName, slotFilterValue)
      end
    end
    if rootDescription and type(rootDescription.CreateDivider) == "function" then
      rootDescription:CreateDivider()
    end
    if rootDescription and type(rootDescription.CreateTitle) == "function" then
      local loc = AzerothCompanion.Localization.Strings or {} -- 本地化文案
      rootDescription:CreateTitle(loc.EJ_DROP_FILTER_TYPE_LABEL or "掉落类型")
    end
    createDetailLootTypeRadio(rootDescription, "mount")
    createDetailLootTypeRadio(rootDescription, "pet")
    createDetailLootTypeRadio(rootDescription, "recipe")
    createDetailLootTypeRadio(rootDescription, "housing_decoration")
  end)
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

--- 按详情页临时掉落类型过滤当前战利品列表。
function DetailEnhancer:applyDetailLootTypeFilter()
  if detailLootFilterType == DETAIL_LOOT_FILTER_ALL or not isModuleEnabled() or not isEncounterDetailVisible() then
    return
  end
  local journalInstanceID = getCurrentDetailJournalInstanceID() -- 当前详情页副本 ID
  if type(journalInstanceID) ~= "number" then
    return
  end
  local dataProvider = getDetailLootDataProvider() -- 战利品数据源
  if not dataProvider or type(dataProvider.Remove) ~= "function" then
    return
  end
  local dropSet = nil -- 当前类型掉落集合
  if AzerothCompanion.API.EncounterJournal and type(AzerothCompanion.API.EncounterJournal.GetDropSetForInstance) == "function" then
    dropSet = AzerothCompanion.API.EncounterJournal.GetDropSetForInstance(journalInstanceID, detailLootFilterType)
  end

  local keepMap = {} -- 需要保留的数据行
  local headerKeepMap = {} -- 需要保留的分组标题
  local pendingHeader = nil -- 等待确认是否保留的标题行
  local allRows = {} -- 遍历到的全部行
  pcall(function()
    dataProvider:ForEach(function(elementData)
      allRows[#allRows + 1] = elementData
      if type(elementData) == "table" and elementData.header == true then
        pendingHeader = elementData
        return
      end
      local itemID = getDetailLootItemID(elementData) -- 当前战利品 itemID
      if type(dropSet) == "table" and itemID and dropSet[itemID] == true then
        keepMap[elementData] = true
        if pendingHeader then
          headerKeepMap[pendingHeader] = true
        end
      end
    end)
  end)

  for _, elementData in ipairs(allRows) do
    local shouldRemove = true -- 当前行是否移除
    if type(elementData) == "table" and elementData.header == true then
      shouldRemove = headerKeepMap[elementData] ~= true
    else
      shouldRemove = keepMap[elementData] ~= true
    end
    if shouldRemove then
      pcall(function() dataProvider:Remove(elementData) end)
    end
  end
end

function DetailEnhancer:refresh()
  self:ensureLockoutLabel()
  setupDetailLootSlotFilterDropdown()
  self:updateVisibility()
  self:updateLockoutLabel()
  self:applyDetailLootTypeFilter()
end

Internal.DropFilter = DropFilter
Internal.ListNavigationPin = ListNavigationPin
Internal.DetailEnhancer = DetailEnhancer
