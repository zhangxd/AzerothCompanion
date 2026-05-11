--[[
  正式服 Settings 宿主：注册 AzerothCompanion 根类目与 5 个左侧子页面。
  宿主负责把通用设置放到根节点，并把模块页组合进“界面 / 地图 / 任务 / 冒险手册 / 关于”，统一默认打开规则。
  `/azerothcompanion`、ESC 菜单按钮与小地图按钮都优先回到上次停留页面；首次打开回退到根节点通用内容。
  战斗中暴雪 `Settings.OpenToCategory` 不可靠：用独立宿主（全屏半透明遮罩 + Dialog 风格底板）托起 Canvas，脱战后仍走系统设置。
  非战斗打开设置前会 `HideUIPanel(GameMenuFrame)`，避免关闭设置后仍显示 ESC 菜单。
  勿缓存 `AzerothCompanion.Localization.Strings`；语言切换后会重建所有页面内容。
]]

AzerothCompanion.SettingsHost = AzerothCompanion.SettingsHost or {}

local SettingId = AzerothCompanion.Config.SettingId -- 稳定数字设置 ID 表
local ACCOUNT_SCOPE = "account" -- 账号级设置 scope
local CHARACTER_SCOPE = "character" -- 角色级设置 scope
local PANEL_WIDTH = 700 -- 保持 AddOns 设置页原生 Canvas 宽度，避免被系统缩放
local PANEL_HEIGHT = 920 -- 设置页固定高度
local SCROLL_CHILD_WIDTH = 640 -- 滚动内容宽度
local MODULE_BOX_WIDTH = 604 -- 设置行容器宽度
local DEFAULT_LEAF_PAGE_KEY = "general" -- 默认打开的页面键名；内部兼容值，对应 Settings 根节点
local SETTINGS_SECTION_TITLE_LEFT = 23 -- 截图像素换算到 UI 单位后的分组标题左缩进
local SETTINGS_ROW_LABEL_LEFT = 59 -- 截图像素换算到 UI 单位后的选项文字左缩进
local SETTINGS_ROW_LABEL_WIDTH = 165 -- 选项文字列宽
local SETTINGS_ROW_TEXT_WIDTH = 480 -- 宽内容说明文本列
local SETTINGS_ROW_CONTROL_LEFT = 244 -- 截图像素换算到 UI 单位后的右侧控件列左缩进
local SETTINGS_ROW_CONTROL_WIDTH = 255 -- 下拉 / 按钮组合总宽
local SETTINGS_DROPDOWN_LEFT = 31 -- 组合控件内下拉可视区左缩进
local SETTINGS_DROPDOWN_WIDTH = 198 -- 下拉可视区宽度
local SETTINGS_DROPDOWN_STEPPER_SIZE = 22 -- 左右步进按钮尺寸
local SETTINGS_DROPDOWN_LEFT_GAP = 8 -- 左步进按钮与下拉之间间距
local SETTINGS_DROPDOWN_RIGHT_GAP = 4 -- 下拉与右步进按钮之间间距
local SETTINGS_CHECKBOX_SIZE = 22 -- checkbox 尺寸
local SETTINGS_CHECKBOX_TOP_OFFSET = 3 -- checkbox 相对文字行向上偏移
local SETTINGS_CONTROL_TOP_OFFSET = 3 -- 下拉 / 菜单控件相对文字行向上偏移
local SETTINGS_ACTION_TOP_OFFSET = 2 -- 动作按钮相对文字行向上偏移
local SETTINGS_ROW_HEIGHT = 22 -- 设置行占用高度
local SETTINGS_ROW_PITCH = 32 -- 常规设置行行距
local SETTINGS_ROW_GAP = SETTINGS_ROW_PITCH - SETTINGS_ROW_HEIGHT -- 设置行默认间隔
local SETTINGS_SECTION_TO_FIRST_ROW_GAP = 27 -- 分组标题到第一行间距
local SETTINGS_BOX_BOTTOM_PADDING = 8 -- 设置容器底部余量
local SETTINGS_BOX_MIN_HEIGHT = 8 -- 设置容器最小高度
local SETTINGS_HEADER_HEIGHT = 50 -- 仿系统设置详情页 Header 高度
local SETTINGS_HEADER_TITLE_LEFT = 7 -- Header 标题左侧偏移
local SETTINGS_HEADER_TITLE_TOP = -22 -- Header 标题顶部偏移
local SETTINGS_HEADER_BUTTON_WIDTH = 96 -- Header 动作按钮宽度
local SETTINGS_HEADER_BUTTON_HEIGHT = 22 -- Header 动作按钮高度
local SETTINGS_HEADER_BUTTON_RIGHT = -36 -- Header 右侧按钮右边距
local SETTINGS_HEADER_BUTTON_TOP = -16 -- Header 右侧按钮顶部偏移
local SETTINGS_HEADER_BUTTON_GAP = 4 -- Header 按钮之间间隔
local SETTINGS_HEADER_DIVIDER_TOP = -50 -- Header 底部分割线位置
local SETTINGS_HEADER_CONTENT_GAP = 10 -- Header 分割线到首个内容块间距
--- 战斗内独立展示时相对裸 `UIParent` 居中略缩小，贴近系统设置窗口内嵌 Canvas 的观感（可按实机再调）。
local STANDALONE_PANEL_SCALE = 0.82
local MODULE_LEAF_KEY_MAP = {
  chat = "chat",
  minimap_button = "general",
  mover = "interface",
  tooltip_anchor = "interface",
  navigation = "map",
  quest = "quest",
  encounter_journal = "encounter_journal",
}
local GENERAL_FEATURE_LIST = {
  {
    moduleId = "navigation",
    nameKey = "MODULE_NAVIGATION",
    flyoutId = "ac_mod_navigation",
  },
  {
    moduleId = "quest",
    nameKey = "MODULE_QUEST",
    flyoutId = "ac_flyout_quest",
  },
  {
    moduleId = "encounter_journal",
    nameKey = "MODULE_ENCOUNTER_JOURNAL",
    flyoutId = "ac_flyout_ej",
  },
} -- 根节点功能列表：只控制地图 / 任务 / 冒险手册
local GENERAL_FEATURE_MODULE_IDS = {} -- 根节点功能列表接管的模块 id 查找表
for _, featureDef in ipairs(GENERAL_FEATURE_LIST) do
  GENERAL_FEATURE_MODULE_IDS[featureDef.moduleId] = true
end
local INTERFACE_COMPACT_MODULE_IDS = {
  mover = true,
  tooltip_anchor = true,
} -- 界面页紧凑模块：关闭态由模块专属设置项承载
local GENERAL_GLOBAL_RESET_REFS = { { id = SettingId.GLOBAL_LOCALE, scope = ACCOUNT_SCOPE } } -- 根节点恢复的全局设置引用
local GENERAL_MINIMAP_RESET_REFS = { -- 根节点小地图按钮设置引用
  { id = SettingId.MINIMAP_ENABLED, scope = ACCOUNT_SCOPE },
  { id = SettingId.MINIMAP_DEBUG, scope = ACCOUNT_SCOPE },
  { id = SettingId.MINIMAP_SHOW_BUTTON, scope = ACCOUNT_SCOPE },
  { id = SettingId.MINIMAP_POS, scope = ACCOUNT_SCOPE },
  { id = SettingId.MINIMAP_FLYOUT_SLOT_IDS, scope = ACCOUNT_SCOPE },
}
local CHAT_PAGE_RESET_REFS = { -- 聊天页聊天提示设置引用
  { id = SettingId.CHAT_ENABLED, scope = ACCOUNT_SCOPE },
  { id = SettingId.CHAT_DEBUG, scope = ACCOUNT_SCOPE },
  { id = SettingId.CHAT_PREFIX_COLOR, scope = ACCOUNT_SCOPE },
  { id = SettingId.CHAT_CONTENT_COLOR, scope = ACCOUNT_SCOPE },
}
local INTERFACE_MOVER_RESET_REFS = { -- 界面页窗口拖动设置引用
  { id = SettingId.MOVER_ENABLED, scope = ACCOUNT_SCOPE },
  { id = SettingId.MOVER_FRAMES, scope = ACCOUNT_SCOPE },
  { id = SettingId.MOVER_DRAG_HIT_MODE, scope = ACCOUNT_SCOPE },
  { id = SettingId.MOVER_ALLOW_DRAG_IN_COMBAT, scope = ACCOUNT_SCOPE },
}
local INTERFACE_TOOLTIP_RESET_REFS = { -- 界面页提示框位置设置引用
  { id = SettingId.TOOLTIP_ENABLED, scope = ACCOUNT_SCOPE },
  { id = SettingId.TOOLTIP_MODE, scope = ACCOUNT_SCOPE },
  { id = SettingId.TOOLTIP_OFFSET_X, scope = ACCOUNT_SCOPE },
  { id = SettingId.TOOLTIP_OFFSET_Y, scope = ACCOUNT_SCOPE },
}
local MAP_MINIMAP_RESET_REFS = { -- 地图页小地图坐标设置引用
  { id = SettingId.MINIMAP_SHOW_COORDS, scope = ACCOUNT_SCOPE },
  { id = SettingId.MINIMAP_COORDS_ANCHOR, scope = ACCOUNT_SCOPE },
}
local QUEST_PAGE_RESET_REFS = { -- 任务页专属设置引用
  { id = SettingId.QUESTLINE_TREE_ENABLED, scope = ACCOUNT_SCOPE },
  { id = SettingId.QUEST_RECENT_COMPLETED_MAX, scope = ACCOUNT_SCOPE },
  { id = SettingId.QUEST_INSPECTOR_LAST_QUEST_ID, scope = CHARACTER_SCOPE },
}
local ENCOUNTER_JOURNAL_PAGE_RESET_REFS = { { id = SettingId.ENCOUNTER_JOURNAL_LIST_PIN_ALWAYS_VISIBLE, scope = ACCOUNT_SCOPE } } -- 冒险手册页专属设置引用
local GENERAL_FEATURE_SETTING_REFS = { -- 根节点功能列表设置引用
  navigation = {
    enabled = { id = SettingId.NAVIGATION_ENABLED, scope = ACCOUNT_SCOPE },
    debug = { id = SettingId.NAVIGATION_DEBUG, scope = ACCOUNT_SCOPE },
  },
  quest = {
    enabled = { id = SettingId.QUEST_ENABLED, scope = ACCOUNT_SCOPE },
    debug = { id = SettingId.QUEST_DEBUG, scope = ACCOUNT_SCOPE },
  },
  encounter_journal = {
    enabled = { id = SettingId.ENCOUNTER_JOURNAL_ENABLED, scope = ACCOUNT_SCOPE },
    debug = { id = SettingId.ENCOUNTER_JOURNAL_DEBUG, scope = ACCOUNT_SCOPE },
  },
}
local MODULE_PRIMARY_SETTING_REFS = { -- 模块公共启用设置引用
  chat = { id = SettingId.CHAT_ENABLED, scope = ACCOUNT_SCOPE },
  minimap_button = { id = SettingId.MINIMAP_ENABLED, scope = ACCOUNT_SCOPE },
  mover = { id = SettingId.MOVER_ENABLED, scope = ACCOUNT_SCOPE },
  tooltip_anchor = { id = SettingId.TOOLTIP_ENABLED, scope = ACCOUNT_SCOPE },
  navigation = { id = SettingId.NAVIGATION_ENABLED, scope = ACCOUNT_SCOPE },
  quest = { id = SettingId.QUEST_ENABLED, scope = ACCOUNT_SCOPE },
  encounter_journal = { id = SettingId.ENCOUNTER_JOURNAL_ENABLED, scope = ACCOUNT_SCOPE },
}
local MODULE_DEBUG_SETTING_REFS = { -- 模块公共调试设置引用
  chat = { id = SettingId.CHAT_DEBUG, scope = ACCOUNT_SCOPE },
  minimap_button = { id = SettingId.MINIMAP_DEBUG, scope = ACCOUNT_SCOPE },
  mover = { id = SettingId.MOVER_DEBUG, scope = ACCOUNT_SCOPE },
  tooltip_anchor = { id = SettingId.TOOLTIP_DEBUG, scope = ACCOUNT_SCOPE },
  navigation = { id = SettingId.NAVIGATION_DEBUG, scope = ACCOUNT_SCOPE },
  quest = { id = SettingId.QUEST_DEBUG, scope = ACCOUNT_SCOPE },
  encounter_journal = { id = SettingId.ENCOUNTER_JOURNAL_DEBUG, scope = ACCOUNT_SCOPE },
}
local FEATURE_LIST_ENABLE_LEFT = SETTINGS_ROW_CONTROL_LEFT -- 功能启用列起点
local FEATURE_LIST_DEBUG_LEFT = SETTINGS_ROW_CONTROL_LEFT + 72 -- 调试输出列起点
local FEATURE_LIST_FLYOUT_LEFT = SETTINGS_ROW_CONTROL_LEFT + 150 -- 悬停菜单列起点
local FEATURE_LIST_HEADER_HEIGHT = SETTINGS_ROW_PITCH -- 功能列表表头高度

--- 判断模块的公共开关 / 诊断 / 悬停菜单是否已由根节点功能列表接管。
---@param moduleId string|nil 模块 id
---@return boolean
local function isGeneralFeatureListModule(moduleId)
  return type(moduleId) == "string" and GENERAL_FEATURE_MODULE_IDS[moduleId] == true
end

--- 判断界面页模块是否跳过宿主公共启用 / 诊断区。
---@param moduleId string|nil 模块 id
---@return boolean
local function isInterfaceCompactModule(moduleId)
  return type(moduleId) == "string" and INTERFACE_COMPACT_MODULE_IDS[moduleId] == true
end

local function sanitizePageName(value)
  return tostring(value or "Page"):gsub("[^%w_]", "_")
end

local function createCanvasPanel(frameName)
  local panel = CreateFrame("Frame", frameName, UIParent) -- 叶子页面板
  panel:SetSize(PANEL_WIDTH, PANEL_HEIGHT)
  panel:Hide()

  local scrollFrame = CreateFrame("ScrollFrame", nil, panel, "ScrollFrameTemplate") -- 页面滚动框
  scrollFrame:SetPoint("TOPLEFT", 8, -8)
  scrollFrame:SetPoint("BOTTOMRIGHT", -28, 8)

  local childFrame = CreateFrame("Frame", nil, scrollFrame) -- 页面滚动内容根节点
  childFrame:SetSize(SCROLL_CHILD_WIDTH, 800)
  scrollFrame:SetScrollChild(childFrame)

  panel._azerothCompanionScroll = scrollFrame
  panel._azerothCompanionChild = childFrame
  return panel
end

local function resetCanvasPanel(panel)
  local scrollFrame = panel._azerothCompanionScroll -- 页面滚动框
  local oldChild = panel._azerothCompanionChild -- 旧内容节点
  if oldChild then
    oldChild:SetParent(nil)
    oldChild:Hide()
  end

  local childFrame = CreateFrame("Frame", nil, scrollFrame) -- 新内容节点
  childFrame:SetSize(SCROLL_CHILD_WIDTH, 800)
  scrollFrame:SetScrollChild(childFrame)
  panel._azerothCompanionChild = childFrame
  if scrollFrame.SetVerticalScroll then
    scrollFrame:SetVerticalScroll(0)
  end
  return childFrame
end

local function collectSettingsModules()
  local moduleList = {} -- 带设置页的模块列表
  for _, moduleObject in ipairs(AzerothCompanion.ModuleRegistry:GetSorted()) do
    if moduleObject.RegisterSettings then
      moduleList[#moduleList + 1] = moduleObject
    end
  end

  table.sort(moduleList, function(leftModule, rightModule)
    local leftOrder = tonumber(leftModule.settingsOrder) or 9999 -- 左侧排序值
    local rightOrder = tonumber(rightModule.settingsOrder) or 9999 -- 右侧排序值
    if leftOrder ~= rightOrder then
      return leftOrder < rightOrder
    end
    return tostring(leftModule.id) < tostring(rightModule.id)
  end)

  return moduleList
end

local function getModuleTitle(moduleObject)
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  if moduleObject.nameKey and localeTable[moduleObject.nameKey] then
    return localeTable[moduleObject.nameKey]
  end
  if moduleObject.name then
    return moduleObject.name
  end
  return moduleObject.id
end

local function getModuleIntro(moduleObject)
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  if moduleObject.settingsIntroKey and localeTable[moduleObject.settingsIntroKey] then
    return localeTable[moduleObject.settingsIntroKey]
  end
  return ""
end

local function getPageTitle(pageObject)
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  if pageObject.titleKey and localeTable[pageObject.titleKey] then
    return localeTable[pageObject.titleKey]
  end
  if pageObject.titleText then
    return pageObject.titleText
  end
  if pageObject.module then
    return getModuleTitle(pageObject.module)
  end
  return pageObject.key
end

--- 读取设置引用当前值。
---@param settingRef table|nil 设置引用；包含 id 与 scope
---@return any
local function getSettingValue(settingRef)
  if type(settingRef) ~= "table" or settingRef.id == nil or settingRef.scope == nil then
    return nil
  end
  return AzerothCompanion.Config.Get(settingRef.id, settingRef.scope)
end

--- 写入设置引用当前值。
---@param settingRef table|nil 设置引用；包含 id 与 scope
---@param settingValue any 新设置值
local function setSettingValue(settingRef, settingValue)
  if type(settingRef) ~= "table" or settingRef.id == nil or settingRef.scope == nil then
    return
  end
  AzerothCompanion.Config.Set(settingRef.id, settingRef.scope, settingValue)
end

--- 恢复一组设置引用的默认值。
---@param settingRefList table 设置引用列表
local function resetSettingRefs(settingRefList)
  if type(settingRefList) ~= "table" then
    return
  end
  for _, settingRef in ipairs(settingRefList) do
    if type(settingRef) == "table" and settingRef.id ~= nil and settingRef.scope ~= nil then
      AzerothCompanion.Config.Reset(settingRef.id, settingRef.scope)
    end
  end
end

local function applyModuleCallbacks(moduleObject)
  local enabledRef = MODULE_PRIMARY_SETTING_REFS[moduleObject.id] -- 模块启用设置引用
  local debugRef = MODULE_DEBUG_SETTING_REFS[moduleObject.id] -- 模块调试设置引用
  if moduleObject.OnEnabledSettingChanged then
    moduleObject.OnEnabledSettingChanged(getSettingValue(enabledRef) ~= false)
  end
  if moduleObject.OnDebugSettingChanged then
    moduleObject.OnDebugSettingChanged(getSettingValue(debugRef) == true)
  end
end

local function getChoiceOptions(optionList)
  if type(optionList) ~= "table" then
    return {}
  end
  return optionList
end

local function normalizeChoiceValue(currentValue, optionList, defaultValue)
  local choiceList = getChoiceOptions(optionList) -- 选项列表
  for _, optionObject in ipairs(choiceList) do
    if optionObject and optionObject.value == currentValue then
      return currentValue, false
    end
  end

  if defaultValue ~= nil then
    for _, optionObject in ipairs(choiceList) do
      if optionObject and optionObject.value == defaultValue then
        return defaultValue, true
      end
    end
  end

  local firstOption = choiceList[1] -- 首项兜底
  if firstOption ~= nil then
    return firstOption.value, true
  end
  return defaultValue, true
end

local function normalizeToggleValue(currentValue, defaultValue)
  if type(currentValue) == "boolean" then
    return currentValue, false
  end
  if defaultValue ~= nil then
    return defaultValue == true, true
  end
  if currentValue == nil then
    return false, true
  end
  return currentValue == true, true
end

local refreshMinimapFlyout -- 小地图悬停菜单刷新函数，供页面级恢复默认处理提前引用

local function setFontStringTextColor(fontString, isEnabled)
  if not fontString or not fontString.SetTextColor then
    return
  end
  if isEnabled == false then
    fontString:SetTextColor(0.55, 0.55, 0.55)
  else
    fontString:SetTextColor(1, 0.82, 0)
  end
end

--- 按设置引用恢复默认值，并按需触发模块公共回调。
---@param settingsHost table SettingsHost 实例
---@param moduleId string 模块 id
---@param settingRefList table 设置引用序列
---@param applyCallbacks boolean 是否触发启用 / 诊断回调
local function resetModuleSettings(settingsHost, moduleId, settingRefList, applyCallbacks)
  resetSettingRefs(settingRefList)
  if applyCallbacks == true then
    local moduleObject = settingsHost.modulesById and settingsHost.modulesById[moduleId] or nil -- 当前模块定义
    if moduleObject then
      applyModuleCallbacks(moduleObject)
    end
  end
end

--- 恢复根节点承载的通用设置，不触碰其它叶子页专属字段。
---@param settingsHost table SettingsHost 实例
---@return string refreshMode 刷新模式；根节点语言可能变化，需要重建全部页面
local function resetGeneralPageToDefaults(settingsHost)
  resetSettingRefs(GENERAL_GLOBAL_RESET_REFS)
  if type(AzerothCompanion.Localization.Apply) == "function" then
    AzerothCompanion.Localization.Apply()
  end
  resetModuleSettings(settingsHost, "minimap_button", GENERAL_MINIMAP_RESET_REFS, true)
  for _, featureDef in ipairs(GENERAL_FEATURE_LIST) do
    local featureRefs = GENERAL_FEATURE_SETTING_REFS[featureDef.moduleId] -- 功能行设置引用
    resetModuleSettings(settingsHost, featureDef.moduleId, { featureRefs.enabled, featureRefs.debug }, true)
  end
  refreshMinimapFlyout()
  return "all_pages"
end

--- 恢复界面页设置：窗口拖动与提示框位置。
---@param settingsHost table SettingsHost 实例
local function resetInterfacePageToDefaults(settingsHost)
  resetModuleSettings(settingsHost, "mover", INTERFACE_MOVER_RESET_REFS, true)
  if AzerothCompanion.Modules.Mover and type(AzerothCompanion.Modules.Mover.RefreshDragConfiguration) == "function" then
    AzerothCompanion.Modules.Mover.RefreshDragConfiguration()
  end
  resetModuleSettings(settingsHost, "tooltip_anchor", INTERFACE_TOOLTIP_RESET_REFS, true)
  if AzerothCompanion.API.Tooltip and type(AzerothCompanion.API.Tooltip.RefreshDriver) == "function" then
    AzerothCompanion.API.Tooltip.RefreshDriver()
  end
end

--- 恢复地图页设置：只处理小地图玩家坐标相关字段。
---@param settingsHost table SettingsHost 实例
local function resetMapPageToDefaults(settingsHost)
  resetModuleSettings(settingsHost, "minimap_button", MAP_MINIMAP_RESET_REFS, false)
  refreshMinimapFlyout()
end

--- 恢复聊天页设置：只处理聊天提示模块字段。
---@param settingsHost table SettingsHost 实例
local function resetChatPageToDefaults(settingsHost)
  resetModuleSettings(settingsHost, "chat", CHAT_PAGE_RESET_REFS, true)
end

--- 恢复任务页专属设置，不改变根节点功能列表中的启用 / 诊断状态。
---@param settingsHost table SettingsHost 实例
local function resetQuestPageToDefaults(settingsHost)
  resetModuleSettings(settingsHost, "quest", QUEST_PAGE_RESET_REFS, false)
end

--- 恢复冒险手册页专属设置，不改变根节点功能列表中的启用 / 诊断状态。
---@param settingsHost table SettingsHost 实例
local function resetEncounterJournalPageToDefaults(settingsHost)
  resetModuleSettings(settingsHost, "encounter_journal", ENCOUNTER_JOURNAL_PAGE_RESET_REFS, false)
  if type(_G.EncounterJournal_ListInstances) == "function" then
    pcall(_G.EncounterJournal_ListInstances)
  end
end

local function triggerBoxRefresh(boxFrame, options)
  local refreshMode = type(options) == "table" and options.refreshMode or nil -- 刷新模式
  if refreshMode == "page" then
    boxFrame:RequestPageRebuild()
  elseif refreshMode == "all_pages" then
    AzerothCompanion.SettingsHost:RefreshAllPages()
  elseif refreshMode == "none" then
    return
  else
    boxFrame:RequestLocalRefresh()
  end
end

--- 检查字符串序列中是否包含目标值。
---@param valueList table|nil 字符串序列；非 table 时视为空列表
---@param targetValue string 目标字符串
---@return boolean
local function hasStringValue(valueList, targetValue)
  if type(valueList) ~= "table" then
    return false
  end
  for _, currentValue in ipairs(valueList) do
    if currentValue == targetValue then
      return true
    end
  end
  return false
end

--- 从字符串序列中移除所有目标值。
---@param valueList table|nil 字符串序列；非 table 时不处理
---@param targetValue string 目标字符串
local function removeStringValue(valueList, targetValue)
  if type(valueList) ~= "table" then
    return
  end
  for index = #valueList, 1, -1 do
    if valueList[index] == targetValue then
      table.remove(valueList, index)
    end
  end
end

--- 读取小地图悬停菜单勾选列表，缺失时补齐当前默认值。
---@return table
local function getFlyoutSlotIds()
  local selectedSlotIds = AzerothCompanion.Config.Get(SettingId.MINIMAP_FLYOUT_SLOT_IDS, ACCOUNT_SCOPE) -- 小地图悬停菜单勾选列表
  if type(selectedSlotIds) ~= "table" then
    selectedSlotIds = { "reload_ui", "ac_flyout_quest" }
  end
  return selectedSlotIds
end

--- 通知小地图按钮按最新 flyoutSlotIds 重建悬停菜单。
refreshMinimapFlyout = function()
  if AzerothCompanion.Modules.MinimapButton and type(AzerothCompanion.Modules.MinimapButton.Refresh) == "function" then
    AzerothCompanion.Modules.MinimapButton.Refresh()
  end
end

local function anchorInset(frameObject, parentObject, insetValue)
  if not frameObject or not parentObject then
    return
  end
  local insetAmount = tonumber(insetValue) or 0 -- 统一内缩值
  frameObject:ClearAllPoints()
  frameObject:SetPoint("TOPLEFT", parentObject, "TOPLEFT", insetAmount, -insetAmount)
  frameObject:SetPoint("BOTTOMRIGHT", parentObject, "BOTTOMRIGHT", -insetAmount, insetAmount)
end

local function setObjectShown(frameObject, shouldShow)
  if not frameObject then
    return
  end
  if shouldShow then
    frameObject:Show()
  else
    frameObject:Hide()
  end
end

local function setControlLabelText(controlObject, textValue)
  if controlObject and controlObject._azerothCompanionLabel and controlObject._azerothCompanionLabel.SetText then
    controlObject._azerothCompanionLabel:SetText(textValue or "")
  end
  if controlObject and controlObject.SetText then
    controlObject:SetText(textValue or "")
  end
end

local function getChoiceCurrentValue(rowOptions, choiceList)
  local currentValue = type(rowOptions.getValue) == "function" and rowOptions.getValue() or rowOptions.value -- 当前取值
  local normalizedValue, wasNormalized = normalizeChoiceValue(currentValue, choiceList, rowOptions.defaultValue) -- 归一后的取值
  if wasNormalized and normalizedValue ~= nil and type(rowOptions.setValue) == "function" then
    rowOptions.setValue(normalizedValue)
  end
  return normalizedValue
end

local function findChoiceIndex(choiceList, currentValue)
  for indexNumber, optionObject in ipairs(choiceList or {}) do
    if optionObject and optionObject.value == currentValue then
      return indexNumber
    end
  end
  return nil
end

local function getChoiceOption(choiceList, currentValue)
  local currentIndex = findChoiceIndex(choiceList, currentValue) or 1 -- 当前索引
  return choiceList[currentIndex], currentIndex
end

local function setDropdownDisplayText(dropdownButton, textValue)
  if not dropdownButton then
    return
  end
  if type(dropdownButton.SetDefaultText) == "function" then
    dropdownButton:SetDefaultText(textValue or "")
  end
  if type(dropdownButton.OverrideText) == "function" then
    dropdownButton:OverrideText(textValue or "")
  elseif type(dropdownButton.SetText) == "function" then
    dropdownButton:SetText(textValue or "")
  end
end

local function ensureDropdownWithButtonsControl(parentFrame, controlWidth)
  local widthValue = tonumber(controlWidth) or SETTINGS_ROW_CONTROL_WIDTH -- 整个右侧控件列宽度
  local dropdownWidth = math.min(SETTINGS_DROPDOWN_WIDTH, math.max(
    80,
    widthValue - SETTINGS_DROPDOWN_LEFT - SETTINGS_DROPDOWN_STEPPER_SIZE - SETTINGS_DROPDOWN_RIGHT_GAP
  )) -- 中间下拉按钮宽度，给左右步进按钮留空间
  local controlObject = nil -- 下拉+步进组合控件
  local createdWithTemplate = false -- 是否成功使用原生模板
  local okFlag, frameObject = pcall(function()
    return CreateFrame("Frame", nil, parentFrame, "SettingsDropdownWithButtonsTemplate")
  end)
  if okFlag and frameObject then
    controlObject = frameObject
    createdWithTemplate = true
  else
    controlObject = CreateFrame("Frame", nil, parentFrame)
  end

  controlObject.templateName = createdWithTemplate and "SettingsDropdownWithButtonsTemplate" or controlObject.templateName
  controlObject:SetSize(widthValue, SETTINGS_CHECKBOX_SIZE)

  if not controlObject.Dropdown then
    local dropdownButton = CreateFrame("Button", nil, controlObject) -- 兜底下拉按钮
    dropdownButton:RegisterForClicks("LeftButtonUp")
    controlObject.Dropdown = dropdownButton
  end
  if not controlObject.IncrementButton then
    local incrementButton = CreateFrame("Button", nil, controlObject) -- 兜底右箭头
    incrementButton:RegisterForClicks("LeftButtonUp")
    controlObject.IncrementButton = incrementButton
  end
  if not controlObject.DecrementButton then
    local decrementButton = CreateFrame("Button", nil, controlObject) -- 兜底左箭头
    decrementButton:RegisterForClicks("LeftButtonUp")
    controlObject.DecrementButton = decrementButton
  end

  if controlObject.Dropdown.ClearAllPoints and controlObject.Dropdown.SetPoint then
    controlObject.Dropdown:ClearAllPoints()
    controlObject.Dropdown:SetPoint("LEFT", controlObject, "LEFT", SETTINGS_DROPDOWN_LEFT, 0)
  end
  if controlObject.Dropdown.SetWidth then
    controlObject.Dropdown:SetWidth(dropdownWidth)
  end
  if controlObject.Dropdown.SetHeight then
    controlObject.Dropdown:SetHeight(22)
  end

  if controlObject.IncrementButton.ClearAllPoints and controlObject.IncrementButton.SetPoint then
    controlObject.IncrementButton:ClearAllPoints()
    controlObject.IncrementButton:SetPoint("LEFT", controlObject.Dropdown, "RIGHT", SETTINGS_DROPDOWN_RIGHT_GAP, 0)
  end
  if controlObject.DecrementButton.ClearAllPoints and controlObject.DecrementButton.SetPoint then
    controlObject.DecrementButton:ClearAllPoints()
    controlObject.DecrementButton:SetPoint("RIGHT", controlObject.Dropdown, "LEFT", -SETTINGS_DROPDOWN_LEFT_GAP, 0)
  end
  if controlObject.IncrementButton.SetSize then
    controlObject.IncrementButton:SetSize(SETTINGS_DROPDOWN_STEPPER_SIZE, SETTINGS_DROPDOWN_STEPPER_SIZE)
  end
  if controlObject.DecrementButton.SetSize then
    controlObject.DecrementButton:SetSize(SETTINGS_DROPDOWN_STEPPER_SIZE, SETTINGS_DROPDOWN_STEPPER_SIZE)
  end

  if type(controlObject.SetSteppersShown) ~= "function" then
    function controlObject:SetSteppersShown(isShown)
      setObjectShown(self.IncrementButton, isShown ~= false)
      setObjectShown(self.DecrementButton, isShown ~= false)
    end
  end
  if type(controlObject.SetSteppersEnabled) ~= "function" then
    function controlObject:SetSteppersEnabled(canDecrement, canIncrement)
      if self.DecrementButton and self.DecrementButton.SetEnabled then
        self.DecrementButton:SetEnabled(canDecrement == true)
      end
      if self.IncrementButton and self.IncrementButton.SetEnabled then
        self.IncrementButton:SetEnabled(canIncrement == true)
      end
    end
  end

  return controlObject
end

local function createSurfaceControl(parentFrame, frameType)
  local controlObject = CreateFrame(frameType or "Button", nil, parentFrame) -- 通用表面控件
  local borderTexture = controlObject:CreateTexture(nil, "BORDER") -- 外边框贴图
  borderTexture:SetAllPoints()
  borderTexture:SetColorTexture(0.27, 0.31, 0.4, 1)
  controlObject._azerothCompanionBorderTexture = borderTexture

  local backgroundTexture = controlObject:CreateTexture(nil, "BACKGROUND") -- 主背景贴图
  anchorInset(backgroundTexture, controlObject, 1)
  backgroundTexture:SetColorTexture(0.09, 0.11, 0.16, 0.96)
  controlObject._azerothCompanionBackgroundTexture = backgroundTexture

  local accentTexture = controlObject:CreateTexture(nil, "ARTWORK") -- 选中高亮贴图
  anchorInset(accentTexture, controlObject, 1)
  accentTexture:SetColorTexture(0.21, 0.45, 0.82, 0.36)
  accentTexture:Hide()
  controlObject._azerothCompanionAccentTexture = accentTexture

  local labelText = controlObject:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") -- 控件标签文本
  labelText:SetPoint("CENTER", controlObject, "CENTER", 0, 0)
  labelText:SetJustifyH("CENTER")
  controlObject._azerothCompanionLabel = labelText
  return controlObject
end

local function applySurfaceControlState(controlObject, isEnabled, isSelected, isOpen)
  if not controlObject then
    return
  end
  local borderTexture = controlObject._azerothCompanionBorderTexture -- 控件边框贴图
  local backgroundTexture = controlObject._azerothCompanionBackgroundTexture -- 控件背景贴图
  local accentTexture = controlObject._azerothCompanionAccentTexture -- 控件高亮贴图
  local labelText = controlObject._azerothCompanionLabel -- 控件标签文本

  if borderTexture and borderTexture.SetColorTexture then
    if isEnabled == false then
      borderTexture:SetColorTexture(0.2, 0.22, 0.28, 1)
    elseif isSelected or isOpen then
      borderTexture:SetColorTexture(0.46, 0.63, 0.95, 1)
    else
      borderTexture:SetColorTexture(0.27, 0.31, 0.4, 1)
    end
  end

  if backgroundTexture and backgroundTexture.SetColorTexture then
    if isEnabled == false then
      backgroundTexture:SetColorTexture(0.08, 0.09, 0.12, 0.82)
    elseif isSelected or isOpen then
      backgroundTexture:SetColorTexture(0.14, 0.2, 0.33, 0.96)
    else
      backgroundTexture:SetColorTexture(0.09, 0.11, 0.16, 0.96)
    end
  end

  if accentTexture then
    setObjectShown(accentTexture, isEnabled ~= false and (isSelected or isOpen))
  end

  if labelText and labelText.SetTextColor then
    if isEnabled == false then
      labelText:SetTextColor(0.5, 0.52, 0.58)
    elseif isSelected or isOpen then
      labelText:SetTextColor(0.96, 0.97, 1)
    else
      labelText:SetTextColor(0.86, 0.88, 0.93)
    end
  end
end

local function createCheckboxControl(parentFrame)
  local okFlag, nativeCheckbox = pcall(function()
    return CreateFrame("CheckButton", nil, parentFrame, "SettingsCheckboxTemplate")
  end)
  if okFlag and nativeCheckbox then
    return nativeCheckbox
  end

  local checkButton = CreateFrame("CheckButton", nil, parentFrame) -- 自绘勾选控件
  checkButton:RegisterForClicks("LeftButtonUp")

  local borderTexture = checkButton:CreateTexture(nil, "BORDER") -- 勾选框边框
  borderTexture:SetAllPoints()
  borderTexture:SetColorTexture(0.27, 0.31, 0.4, 1)
  checkButton._azerothCompanionBorderTexture = borderTexture

  local backgroundTexture = checkButton:CreateTexture(nil, "BACKGROUND") -- 勾选框底色
  anchorInset(backgroundTexture, checkButton, 1)
  backgroundTexture:SetColorTexture(0.09, 0.11, 0.16, 0.96)
  checkButton._azerothCompanionBackgroundTexture = backgroundTexture

  local checkTexture = checkButton:CreateTexture(nil, "ARTWORK") -- 勾选标记贴图
  anchorInset(checkTexture, checkButton, 3)
  checkTexture:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
  checkTexture:Hide()
  checkButton._azerothCompanionCheckTexture = checkTexture
  return checkButton
end

local function applyCheckboxState(checkButton, isEnabled, isChecked)
  if not checkButton then
    return
  end
  local borderTexture = checkButton._azerothCompanionBorderTexture -- 勾选框边框
  local backgroundTexture = checkButton._azerothCompanionBackgroundTexture -- 勾选框底色
  local checkTexture = checkButton._azerothCompanionCheckTexture -- 勾选标记贴图
  local inlineLabel = checkButton._azerothCompanionInlineLabel -- 行内标签文本

  if borderTexture and borderTexture.SetColorTexture then
    if isEnabled == false then
      borderTexture:SetColorTexture(0.2, 0.22, 0.28, 1)
    elseif isChecked then
      borderTexture:SetColorTexture(0.46, 0.63, 0.95, 1)
    else
      borderTexture:SetColorTexture(0.27, 0.31, 0.4, 1)
    end
  end

  if backgroundTexture and backgroundTexture.SetColorTexture then
    if isEnabled == false then
      backgroundTexture:SetColorTexture(0.08, 0.09, 0.12, 0.82)
    elseif isChecked then
      backgroundTexture:SetColorTexture(0.13, 0.19, 0.31, 0.96)
    else
      backgroundTexture:SetColorTexture(0.09, 0.11, 0.16, 0.96)
    end
  end

  if checkTexture then
    setObjectShown(checkTexture, isChecked == true)
  end

  if inlineLabel and inlineLabel.SetTextColor then
    if isEnabled == false then
      inlineLabel:SetTextColor(0.5, 0.52, 0.58)
    else
      inlineLabel:SetTextColor(0.86, 0.88, 0.93)
    end
  end
end

-- 为设置行挂统一悬停提示；说明文字不再占用主界面布局高度。
local function attachSettingsRowTooltip(controlObject, titleText, descriptionText)
  if not controlObject or type(descriptionText) ~= "string" or descriptionText == "" then
    return
  end
  if type(controlObject.SetScript) ~= "function" then
    return
  end

  controlObject._azerothCompanionTooltipTitle = titleText or "" -- tooltip 标题
  controlObject._azerothCompanionTooltipText = descriptionText -- tooltip 正文
  if type(controlObject.EnableMouse) == "function" then
    controlObject:EnableMouse(true)
  end
  if type(controlObject.SetMotionScriptsWhileDisabled) == "function" then
    controlObject:SetMotionScriptsWhileDisabled(true)
  end

  local showTooltip = function(ownerFrame) -- 显示当前设置行提示
    local tooltipObject = _G.GameTooltip -- 系统 tooltip
    if not tooltipObject then
      return
    end
    if AzerothCompanion.API.Tooltip and type(AzerothCompanion.API.Tooltip.SetSkipAnchorOverride) == "function" then
      AzerothCompanion.API.Tooltip.SetSkipAnchorOverride(tooltipObject, true)
    end
    tooltipObject:SetOwner(ownerFrame, "ANCHOR_RIGHT")
    if tooltipObject.ClearLines then
      tooltipObject:ClearLines()
    end
    tooltipObject:SetText(controlObject._azerothCompanionTooltipTitle or "")
    if tooltipObject.AddLine then
      tooltipObject:AddLine(controlObject._azerothCompanionTooltipText or "", 1, 1, 1, true)
    end
    tooltipObject:Show()
  end
  local hideTooltip = function() -- 隐藏当前设置行提示
    local tooltipObject = _G.GameTooltip -- 系统 tooltip
    if tooltipObject and AzerothCompanion.API.Tooltip and type(AzerothCompanion.API.Tooltip.SetSkipAnchorOverride) == "function" then
      AzerothCompanion.API.Tooltip.SetSkipAnchorOverride(tooltipObject, false)
    end
    if tooltipObject and tooltipObject.Hide then
      tooltipObject:Hide()
    end
  end

  if type(controlObject.HookScript) == "function" and type(controlObject.GetScript) == "function" and type(controlObject:GetScript("OnEnter")) == "function" then
    controlObject:HookScript("OnEnter", showTooltip)
  else
    controlObject:SetScript("OnEnter", showTooltip)
  end
  if type(controlObject.HookScript) == "function" and type(controlObject.GetScript) == "function" and type(controlObject:GetScript("OnLeave")) == "function" then
    controlObject:HookScript("OnLeave", hideTooltip)
  else
    controlObject:SetScript("OnLeave", hideTooltip)
  end
end

-- 下拉组合控件包含多个子按钮，统一复用同一条设置说明。
local function attachDropdownTooltip(controlObject, titleText, descriptionText)
  attachSettingsRowTooltip(controlObject, titleText, descriptionText)
  if controlObject and controlObject.Dropdown then
    attachSettingsRowTooltip(controlObject.Dropdown, titleText, descriptionText)
  end
  if controlObject and controlObject.IncrementButton then
    attachSettingsRowTooltip(controlObject.IncrementButton, titleText, descriptionText)
  end
  if controlObject and controlObject.DecrementButton then
    attachSettingsRowTooltip(controlObject.DecrementButton, titleText, descriptionText)
  end
end

local function CreateSettingsBox(parentFrame, startY, pageKey)
  local boxFrame = CreateFrame("Frame", nil, parentFrame) -- 统一设置构建容器
  boxFrame:SetSize(MODULE_BOX_WIDTH, SETTINGS_BOX_MIN_HEIGHT)
  boxFrame:SetPoint("TOPLEFT", parentFrame, "TOPLEFT", 0, startY)
  boxFrame.realHeight = SETTINGS_BOX_MIN_HEIGHT
  boxFrame._azerothCompanionCursorY = 0
  boxFrame._azerothCompanionRefreshers = {}
  boxFrame._azerothCompanionPageKey = pageKey
  boxFrame._azerothCompanionHasRows = false

  function boxFrame:_UpdateRealHeight()
    self.realHeight = math.max(SETTINGS_BOX_MIN_HEIGHT, math.abs(self._azerothCompanionCursorY) + SETTINGS_BOX_BOTTOM_PADDING)
    self:SetHeight(self.realHeight)
  end

  function boxFrame:_ConsumeHeight(heightValue, gapValue)
    local usedHeight = tonumber(heightValue) or 0 -- 当前占用高度
    local usedGap = tonumber(gapValue) or 0 -- 行尾间距
    self._azerothCompanionCursorY = self._azerothCompanionCursorY - usedHeight - usedGap
    self:_UpdateRealHeight()
  end

  function boxFrame:_RegisterRefresher(refreshFunc)
    if type(refreshFunc) == "function" then
      self._azerothCompanionRefreshers[#self._azerothCompanionRefreshers + 1] = refreshFunc
    end
  end

  function boxFrame:_MarkHasRows()
    self._azerothCompanionHasRows = true
  end

  function boxFrame:_IsRowEnabled(options)
    if type(options) ~= "table" then
      return true
    end
    if type(options.enabledWhen) == "function" then
      return options.enabledWhen() ~= false
    end
    if type(options.isEnabled) == "function" then
      return options.isEnabled() ~= false
    end
    return true
  end

  function boxFrame:RequestLocalRefresh()
    for _, refreshFunc in ipairs(self._azerothCompanionRefreshers or {}) do
      refreshFunc()
    end
  end

  function boxFrame:RequestPageRebuild()
    AzerothCompanion.SettingsHost:BuildPage(self._azerothCompanionPageKey)
  end

  function boxFrame:AddSectionHeader(titleOrOptions, descriptionText)
    self:_MarkHasRows()
    local options = type(titleOrOptions) == "table" and titleOrOptions or { title = titleOrOptions, description = descriptionText } -- 分节配置
    local rowTop = self._azerothCompanionCursorY -- 行顶部位置
    local usedHeight = 17 -- 当前分节高度

    local titleLabel = self:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge") -- 分节标题
    titleLabel:SetPoint("TOPLEFT", self, "TOPLEFT", SETTINGS_SECTION_TITLE_LEFT, rowTop)
    titleLabel:SetWidth(SETTINGS_ROW_TEXT_WIDTH + 180)
    titleLabel:SetJustifyH("LEFT")
    titleLabel:SetText(options.title or "")

    self:_ConsumeHeight(usedHeight, SETTINGS_SECTION_TO_FIRST_ROW_GAP - usedHeight)
  end

  function boxFrame:AddNoteRow(options)
    self:_MarkHasRows()
    local rowOptions = type(options) == "table" and options or { text = tostring(options or "") } -- 说明配置
    local rowTop = self._azerothCompanionCursorY -- 行顶部位置
    local noteLabel = self:CreateFontString(nil, "OVERLAY", rowOptions.fontObject or "GameFontHighlightSmall") -- 说明文本
    noteLabel:SetPoint("TOPLEFT", self, "TOPLEFT", SETTINGS_ROW_LABEL_LEFT, rowTop)
    noteLabel:SetWidth(rowOptions.width or (SETTINGS_ROW_TEXT_WIDTH + 180))
    noteLabel:SetJustifyH("LEFT")
    noteLabel:SetText(rowOptions.text or "")
    self:_ConsumeHeight(math.max(18, math.ceil((noteLabel:GetStringHeight() or 0) + 8)), rowOptions.gap or 8)
    return noteLabel
  end

  function boxFrame:AddToggleRow(options)
    self:_MarkHasRows()
    local rowOptions = options or {} -- 开关行配置
    local rowTop = self._azerothCompanionCursorY -- 行顶部位置
    local rowHeight = SETTINGS_ROW_HEIGHT -- 当前行高度

    local titleLabel = self:CreateFontString(nil, "OVERLAY", "GameFontNormal") -- 行标题
    titleLabel:SetPoint("TOPLEFT", self, "TOPLEFT", SETTINGS_ROW_LABEL_LEFT, rowTop)
    titleLabel:SetWidth(SETTINGS_ROW_LABEL_WIDTH)
    titleLabel:SetJustifyH("LEFT")
    titleLabel:SetText(rowOptions.label or "")
    attachSettingsRowTooltip(titleLabel, rowOptions.label, rowOptions.description)

    local stateButton = createCheckboxControl(self) -- 开关勾选控件
    stateButton:SetSize(SETTINGS_CHECKBOX_SIZE, SETTINGS_CHECKBOX_SIZE)
    stateButton:SetPoint("TOPLEFT", self, "TOPLEFT", SETTINGS_ROW_CONTROL_LEFT, rowTop + SETTINGS_CHECKBOX_TOP_OFFSET)
    attachSettingsRowTooltip(stateButton, rowOptions.label, rowOptions.description)

    local function getValue()
      if type(rowOptions.getValue) == "function" then
        return rowOptions.getValue()
      end
      return rowOptions.value
    end

    local function setValue(newValue)
      if type(rowOptions.setValue) == "function" then
        rowOptions.setValue(newValue == true)
      end
      if type(rowOptions.afterChange) == "function" then
        rowOptions.afterChange(newValue == true)
      end
    end

    local function refresh()
      local rawValue = getValue() -- 当前原始取值
      local isChecked, wasNormalized = normalizeToggleValue(rawValue, rowOptions.defaultValue) -- 当前开关值
      if wasNormalized and type(rowOptions.setValue) == "function" then
        rowOptions.setValue(isChecked == true)
      end
      local isEnabled = self:_IsRowEnabled(rowOptions) -- 当前行启用态
      stateButton:SetEnabled(isEnabled)
      stateButton:SetChecked(isChecked == true)
      applyCheckboxState(stateButton, isEnabled, isChecked == true)
      setFontStringTextColor(titleLabel, isEnabled)
    end

    stateButton:SetScript("OnClick", function()
      local currentValue = select(1, normalizeToggleValue(getValue(), rowOptions.defaultValue)) -- 当前归一后的布尔值
      setValue(not currentValue)
      triggerBoxRefresh(self, rowOptions)
    end)

    self:_RegisterRefresher(refresh)
    refresh()
    self:_ConsumeHeight(rowHeight, rowOptions.gap or SETTINGS_ROW_GAP)
    return stateButton
  end

  function boxFrame:AddChoiceRow(options)
    self:_MarkHasRows()
    local rowOptions = options or {} -- 单值选择配置
    local choiceList = getChoiceOptions(rowOptions.options) -- 选项列表
    local rowTop = self._azerothCompanionCursorY -- 行顶部位置
    local rowHeight = SETTINGS_ROW_HEIGHT -- 当前行高度

    local titleLabel = self:CreateFontString(nil, "OVERLAY", "GameFontNormal") -- 行标题
    titleLabel:SetPoint("TOPLEFT", self, "TOPLEFT", SETTINGS_ROW_LABEL_LEFT, rowTop)
    titleLabel:SetWidth(SETTINGS_ROW_LABEL_WIDTH)
    titleLabel:SetJustifyH("LEFT")
    titleLabel:SetText(rowOptions.label or "")
    attachSettingsRowTooltip(titleLabel, rowOptions.label, rowOptions.description)

    local dropdownControl = ensureDropdownWithButtonsControl(self, SETTINGS_ROW_CONTROL_WIDTH) -- 原生箭头+下拉控件
    dropdownControl:SetPoint("TOPLEFT", self, "TOPLEFT", SETTINGS_ROW_CONTROL_LEFT, rowTop + SETTINGS_CONTROL_TOP_OFFSET)
    attachDropdownTooltip(dropdownControl, rowOptions.label, rowOptions.description)

    local function refresh()
      local currentValue = getChoiceCurrentValue(rowOptions, choiceList) -- 当前归一后的取值
      local currentOption, currentIndex = getChoiceOption(choiceList, currentValue) -- 当前选项与索引
      local isEnabled = self:_IsRowEnabled(rowOptions) -- 当前行启用态
      local currentLabel = currentOption and (currentOption.label or tostring(currentOption.value)) or "" -- 当前显示文本
      dropdownControl._azerothCompanionCurrentLabel = currentLabel
      if dropdownControl.Dropdown and dropdownControl.Dropdown.SetEnabled then
        dropdownControl.Dropdown:SetEnabled(isEnabled)
      end
      setDropdownDisplayText(dropdownControl.Dropdown, currentLabel)

      local canDecrement = isEnabled and currentIndex and currentIndex > 1 or false -- 左箭头是否可用
      local canIncrement = isEnabled and currentIndex and currentIndex < #choiceList or false -- 右箭头是否可用
      dropdownControl:SetSteppersShown(#choiceList > 1)
      dropdownControl:SetSteppersEnabled(canDecrement == true, canIncrement == true)

      if dropdownControl.IncrementButton and dropdownControl.IncrementButton.SetEnabled then
        dropdownControl.IncrementButton:SetEnabled(canIncrement == true)
      end
      if dropdownControl.DecrementButton and dropdownControl.DecrementButton.SetEnabled then
        dropdownControl.DecrementButton:SetEnabled(canDecrement == true)
      end
      setFontStringTextColor(titleLabel, isEnabled)
    end

    local function commitValueByIndex(indexNumber)
      local optionObject = choiceList[indexNumber] -- 目标选项
      if not optionObject then
        return
      end
      if type(rowOptions.setValue) == "function" then
        rowOptions.setValue(optionObject.value)
      end
      if type(rowOptions.afterChange) == "function" then
        rowOptions.afterChange(optionObject.value)
      end
      triggerBoxRefresh(self, rowOptions)
    end

    if dropdownControl.IncrementButton then
      dropdownControl.IncrementButton:SetScript("OnClick", function()
        local currentValue = getChoiceCurrentValue(rowOptions, choiceList) -- 当前归一后的取值
        local currentIndex = findChoiceIndex(choiceList, currentValue) or 1 -- 当前索引
        if currentIndex < #choiceList then
          commitValueByIndex(currentIndex + 1)
        end
      end)
    end
    if dropdownControl.DecrementButton then
      dropdownControl.DecrementButton:SetScript("OnClick", function()
        local currentValue = getChoiceCurrentValue(rowOptions, choiceList) -- 当前归一后的取值
        local currentIndex = findChoiceIndex(choiceList, currentValue) or 1 -- 当前索引
        if currentIndex > 1 then
          commitValueByIndex(currentIndex - 1)
        end
      end)
    end

    if dropdownControl.Dropdown and type(dropdownControl.Dropdown.SetupMenu) == "function" then
      dropdownControl.Dropdown:SetupMenu(function(_, rootDescription)
        for _, optionObject in ipairs(choiceList) do
          local optionValue = optionObject.value -- 菜单项值
          local optionLabel = optionObject.label or tostring(optionValue) -- 菜单项文本
          rootDescription:CreateRadio(
            optionLabel,
            function()
              return getChoiceCurrentValue(rowOptions, choiceList) == optionValue
            end,
            function()
              if type(rowOptions.setValue) == "function" then
                rowOptions.setValue(optionValue)
              end
              if type(rowOptions.afterChange) == "function" then
                rowOptions.afterChange(optionValue)
              end
              triggerBoxRefresh(self, rowOptions)
            end,
            optionValue
          )
        end
      end)
    end

    self:_RegisterRefresher(refresh)
    refresh()
    self:_ConsumeHeight(rowHeight, rowOptions.gap or SETTINGS_ROW_GAP)
    return dropdownControl
  end

  function boxFrame:AddMenuRow(options)
    self:_MarkHasRows()
    local rowOptions = options or {} -- 菜单行配置
    local choiceList = getChoiceOptions(rowOptions.options) -- 菜单选项
    local rowTop = self._azerothCompanionCursorY -- 行顶部位置
    local rowHeight = SETTINGS_ROW_HEIGHT -- 当前行高度

    local titleLabel = self:CreateFontString(nil, "OVERLAY", "GameFontNormal") -- 行标题
    titleLabel:SetPoint("TOPLEFT", self, "TOPLEFT", SETTINGS_ROW_LABEL_LEFT, rowTop)
    titleLabel:SetWidth(SETTINGS_ROW_LABEL_WIDTH)
    titleLabel:SetJustifyH("LEFT")
    titleLabel:SetText(rowOptions.label or "")
    attachSettingsRowTooltip(titleLabel, rowOptions.label, rowOptions.description)

    local menuButton = ensureDropdownWithButtonsControl(self, SETTINGS_ROW_CONTROL_WIDTH) -- 原生箭头+下拉控件
    menuButton:SetPoint("TOPLEFT", self, "TOPLEFT", SETTINGS_ROW_CONTROL_LEFT, rowTop + SETTINGS_CONTROL_TOP_OFFSET)
    attachDropdownTooltip(menuButton, rowOptions.label, rowOptions.description)

    local function refresh()
      local currentValue = getChoiceCurrentValue(rowOptions, choiceList) -- 当前归一后的取值
      local currentOption, currentIndex = getChoiceOption(choiceList, currentValue) -- 当前选项与索引
      local isEnabled = self:_IsRowEnabled(rowOptions) -- 当前行启用态
      local currentLabel = currentOption and (currentOption.label or tostring(currentOption.value)) or "" -- 当前按钮文案
      menuButton._azerothCompanionCurrentLabel = currentLabel
      if menuButton.Dropdown and menuButton.Dropdown.SetEnabled then
        menuButton.Dropdown:SetEnabled(isEnabled)
      end
      setDropdownDisplayText(menuButton.Dropdown, currentLabel)

      local canDecrement = isEnabled and currentIndex and currentIndex > 1 or false -- 左箭头是否可用
      local canIncrement = isEnabled and currentIndex and currentIndex < #choiceList or false -- 右箭头是否可用
      menuButton:SetSteppersShown(#choiceList > 1)
      menuButton:SetSteppersEnabled(canDecrement == true, canIncrement == true)
      setFontStringTextColor(titleLabel, isEnabled)
    end

    local function commitValueByIndex(indexNumber)
      local optionObject = choiceList[indexNumber] -- 目标选项
      if not optionObject then
        return
      end
      if type(rowOptions.setValue) == "function" then
        rowOptions.setValue(optionObject.value)
      end
      if type(rowOptions.afterChange) == "function" then
        rowOptions.afterChange(optionObject.value)
      end
      triggerBoxRefresh(self, rowOptions)
    end

    if menuButton.IncrementButton then
      menuButton.IncrementButton:SetScript("OnClick", function()
        local currentValue = getChoiceCurrentValue(rowOptions, choiceList) -- 当前归一后的取值
        local currentIndex = findChoiceIndex(choiceList, currentValue) or 1 -- 当前索引
        if currentIndex < #choiceList then
          commitValueByIndex(currentIndex + 1)
        end
      end)
    end
    if menuButton.DecrementButton then
      menuButton.DecrementButton:SetScript("OnClick", function()
        local currentValue = getChoiceCurrentValue(rowOptions, choiceList) -- 当前归一后的取值
        local currentIndex = findChoiceIndex(choiceList, currentValue) or 1 -- 当前索引
        if currentIndex > 1 then
          commitValueByIndex(currentIndex - 1)
        end
      end)
    end

    if menuButton.Dropdown and type(menuButton.Dropdown.SetupMenu) == "function" then
      menuButton.Dropdown:SetupMenu(function(_, rootDescription)
        for _, optionObject in ipairs(choiceList) do
          local optionValue = optionObject.value -- 菜单项值
          local optionLabel = optionObject.label or tostring(optionValue) -- 菜单项文本
          rootDescription:CreateRadio(
            optionLabel,
            function()
              return getChoiceCurrentValue(rowOptions, choiceList) == optionValue
            end,
            function()
              if type(rowOptions.setValue) == "function" then
                rowOptions.setValue(optionValue)
              end
              if type(rowOptions.afterChange) == "function" then
                rowOptions.afterChange(optionValue)
              end
              triggerBoxRefresh(self, rowOptions)
            end,
            optionValue
          )
        end
      end)
    end

    self:_RegisterRefresher(refresh)
    refresh()
    self:_ConsumeHeight(rowHeight, rowOptions.gap or SETTINGS_ROW_GAP)
    return menuButton
  end

  function boxFrame:AddMultiSelectRow(options)
    self:_MarkHasRows()
    local rowOptions = options or {} -- 多选列表配置
    local choiceList = getChoiceOptions(rowOptions.options) -- 多选项列表
    local rowTop = self._azerothCompanionCursorY -- 行顶部位置
    local rowHeight = 0 -- 当前累计高度

    local titleLabel = self:CreateFontString(nil, "OVERLAY", "GameFontNormal") -- 列表标题
    titleLabel:SetPoint("TOPLEFT", self, "TOPLEFT", SETTINGS_ROW_LABEL_LEFT, rowTop)
    titleLabel:SetWidth(SETTINGS_ROW_LABEL_WIDTH)
    titleLabel:SetJustifyH("LEFT")
    titleLabel:SetText(rowOptions.label or "")
    attachSettingsRowTooltip(titleLabel, rowOptions.label, rowOptions.description)
    rowHeight = rowHeight + SETTINGS_ROW_PITCH

    local buttonList = {} -- 勾选按钮列表
    local optionTop = rowTop - rowHeight -- 第一项顶部
    for _, optionObject in ipairs(choiceList) do
      local checkButton = createCheckboxControl(self) -- 多选按钮
      checkButton:SetSize(SETTINGS_CHECKBOX_SIZE, SETTINGS_CHECKBOX_SIZE)
      checkButton:SetPoint("TOPLEFT", self, "TOPLEFT", SETTINGS_ROW_CONTROL_LEFT, optionTop + SETTINGS_CHECKBOX_TOP_OFFSET)
      checkButton._azerothCompanionValue = optionObject.value
      local optionLabel = checkButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") -- 多选项文本
      optionLabel:SetPoint("LEFT", checkButton, "RIGHT", 8, 0)
      optionLabel:SetWidth(SETTINGS_ROW_CONTROL_WIDTH - SETTINGS_CHECKBOX_SIZE - 8)
      optionLabel:SetJustifyH("LEFT")
      optionLabel:SetText(optionObject.label or tostring(optionObject.value))
      checkButton._azerothCompanionInlineLabel = optionLabel
      attachSettingsRowTooltip(checkButton, rowOptions.label, rowOptions.description)
      checkButton:SetScript("OnClick", function()
        local currentlySelected = type(rowOptions.isSelected) == "function" and rowOptions.isSelected(optionObject.value) == true or false
        if type(rowOptions.setSelected) == "function" then
          rowOptions.setSelected(optionObject.value, currentlySelected ~= true)
        end
        if type(rowOptions.afterChange) == "function" then
          rowOptions.afterChange(optionObject.value, currentlySelected ~= true)
        end
        triggerBoxRefresh(self, rowOptions)
      end)
      buttonList[#buttonList + 1] = checkButton
      optionTop = optionTop - SETTINGS_ROW_PITCH
      rowHeight = rowHeight + SETTINGS_ROW_PITCH
    end

    local function refresh()
      local isEnabled = self:_IsRowEnabled(rowOptions) -- 当前行启用态
      for _, checkButton in ipairs(buttonList) do
        local isSelected = type(rowOptions.isSelected) == "function" and rowOptions.isSelected(checkButton._azerothCompanionValue) == true or false
        checkButton:SetEnabled(isEnabled)
        checkButton:SetChecked(isSelected == true)
        applyCheckboxState(checkButton, isEnabled, isSelected == true)
      end
      setFontStringTextColor(titleLabel, isEnabled)
    end

    self:_RegisterRefresher(refresh)
    refresh()
    self:_ConsumeHeight(rowHeight, rowOptions.gap or SETTINGS_ROW_GAP)
    return buttonList
  end

  function boxFrame:AddActionRow(options)
    self:_MarkHasRows()
    local rowOptions = options or {} -- 操作行配置
    local rowTop = self._azerothCompanionCursorY -- 行顶部位置
    local rowHeight = SETTINGS_ROW_HEIGHT -- 当前行高度

    local titleLabel = self:CreateFontString(nil, "OVERLAY", "GameFontNormal") -- 行标题
    titleLabel:SetPoint("TOPLEFT", self, "TOPLEFT", SETTINGS_ROW_LABEL_LEFT, rowTop)
    titleLabel:SetWidth(SETTINGS_ROW_LABEL_WIDTH)
    titleLabel:SetJustifyH("LEFT")
    titleLabel:SetText(rowOptions.label or "")
    attachSettingsRowTooltip(titleLabel, rowOptions.label, rowOptions.description)

    local actionButton = CreateFrame("Button", nil, self, "UIPanelButtonTemplate") -- 操作按钮
    actionButton:SetSize(SETTINGS_ROW_CONTROL_WIDTH, 18)
    actionButton:SetPoint("TOPLEFT", self, "TOPLEFT", SETTINGS_ROW_CONTROL_LEFT, rowTop + SETTINGS_ACTION_TOP_OFFSET)
    actionButton:SetText(rowOptions.buttonText or rowOptions.label or "")
    attachSettingsRowTooltip(actionButton, rowOptions.label, rowOptions.description)
    actionButton:SetScript("OnClick", function()
      if type(rowOptions.onClick) == "function" then
        rowOptions.onClick()
      end
      triggerBoxRefresh(self, rowOptions)
    end)

    local function refresh()
      local isEnabled = self:_IsRowEnabled(rowOptions) -- 当前行启用态
      actionButton:SetEnabled(isEnabled)
      setFontStringTextColor(titleLabel, isEnabled)
    end

    self:_RegisterRefresher(refresh)
    refresh()
    self:_ConsumeHeight(rowHeight, rowOptions.gap or SETTINGS_ROW_GAP)
    return actionButton
  end

  function boxFrame:AddCustomBlock(builderFunc)
    self:_MarkHasRows()
    local rowTop = self._azerothCompanionCursorY -- 当前块顶部
    local blockFrame = CreateFrame("Frame", nil, self) -- 自定义内容块
    blockFrame:SetPoint("TOPLEFT", self, "TOPLEFT", 0, rowTop)
    blockFrame:SetSize(MODULE_BOX_WIDTH, 1)
    local reportedHeight = 0 -- 上报高度
    if type(builderFunc) == "function" then
      reportedHeight = tonumber(builderFunc(blockFrame, self)) or 0
    end
    if reportedHeight <= 0 then
      reportedHeight = tonumber(blockFrame.realHeight) or tonumber(blockFrame:GetHeight()) or 0
    end
    if reportedHeight <= 0 then
      reportedHeight = 1
    end
    blockFrame:SetHeight(reportedHeight)
    self:_ConsumeHeight(reportedHeight, 8)
    return blockFrame
  end

  boxFrame:_UpdateRealHeight()
  return boxFrame
end

local function buildSectionHeader(childFrame, startY, titleText)
  local yOffset = startY -- 当前纵向游标

  local titleLabel = childFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge") -- 分节标题
  titleLabel:SetPoint("TOPLEFT", childFrame, "TOPLEFT", SETTINGS_SECTION_TITLE_LEFT, yOffset)
  titleLabel:SetText(titleText or "")
  yOffset = yOffset - SETTINGS_SECTION_TO_FIRST_ROW_GAP

  return yOffset
end

local function setChildHeight(childFrame, yOffset)
  childFrame:SetHeight(math.max(800, math.abs(yOffset) + 40))
end

function AzerothCompanion.SettingsHost:GetPageByKey(pageKey)
  self.pagesByKey = self.pagesByKey or {}
  return self.pagesByKey[pageKey]
end

function AzerothCompanion.SettingsHost:GetModulePageKey(moduleId)
  return MODULE_LEAF_KEY_MAP[tostring(moduleId or "")] or DEFAULT_LEAF_PAGE_KEY
end

--- 兼容旧调用面：额外子页已并回叶子页时，统一回到所属叶子页。
function AzerothCompanion.SettingsHost:GetModuleSubPageKey(moduleId)
  return self:GetModulePageKey(moduleId)
end

--- 记录最近一次停留的叶子页，供 `/azerothcompanion` 与各入口回到相同位置。
---@param pageKey string 叶子页键名
function AzerothCompanion.SettingsHost:RememberLeafPageKey(pageKey)
  self:EnsureCreated()
  local pageObject = self:GetPageByKey(pageKey) -- 目标页面
  if not pageObject or pageObject.isLeaf ~= true then
    return
  end
  AzerothCompanion.Config.Set(SettingId.SETTINGS_LAST_LEAF_PAGE, ACCOUNT_SCOPE, pageKey)
end

--- 返回默认应打开的叶子页：优先上次停留，否则回退到“通用”。
---@return string
function AzerothCompanion.SettingsHost:GetPreferredLeafPageKey()
  self:EnsureCreated()
  local savedPageKey = tostring(AzerothCompanion.Config.Get(SettingId.SETTINGS_LAST_LEAF_PAGE, ACCOUNT_SCOPE) or "") -- 记录中的叶子页键名
  local savedPage = self:GetPageByKey(savedPageKey) -- 记录中的页面
  if savedPage and savedPage.isLeaf == true then
    return savedPageKey
  end
  return DEFAULT_LEAF_PAGE_KEY
end

--- 重建单个设置页内容；用于语言切换、模块公共开关变化后刷新 UI。
---@param pageKey string 页面键
function AzerothCompanion.SettingsHost:BuildPage(pageKey)
  self:EnsureCreated()
  local pageObject = self:GetPageByKey(pageKey) -- 目标页面
  if not pageObject or not pageObject.builder then
    return
  end
  pageObject.builder(pageObject)
end

--- 重建所有已注册的设置页内容。
function AzerothCompanion.SettingsHost:RefreshAllPages()
  self:EnsureCreated()
  if self.category and self.category.SetName and AzerothCompanion.Localization.Strings then
    self.category:SetName(AzerothCompanion.Localization.Strings.SETTINGS_CATEGORY_TITLE or AzerothCompanion.ADDON_DISPLAY_NAME or "AzerothCompanion")
  end
  for _, pageObject in ipairs(self.pages or {}) do
    if pageObject.category and pageObject.category.SetName then
      pageObject.category:SetName(getPageTitle(pageObject))
    end
    if pageObject.builder then
      pageObject.builder(pageObject)
    end
  end
end

--- 兼容旧调用面：构建（现语义为重建）所有页面。
function AzerothCompanion.SettingsHost:Build()
  self:RefreshAllPages()
end

--- 执行当前页面声明的独立恢复默认动作，并重建当前页面。
---@param pageObject table 页面定义；`resetHandler` 决定当前页面恢复范围
function AzerothCompanion.SettingsHost:ResetPageToDefaults(pageObject)
  if type(pageObject) ~= "table" or type(pageObject.resetHandler) ~= "function" then
    return
  end
  local refreshMode = pageObject.resetHandler(self) -- 页面恢复后的刷新模式
  if refreshMode == "all_pages" then
    self:RefreshAllPages()
  else
    self:BuildPage(pageObject.key)
  end
end

--- 构建仿系统 Settings 详情页的统一页头。
---@param childFrame Frame 页面内容根节点
---@param startY number 旧布局纵向游标；保留参数以便调用方统一处理
---@param pageObject table 页面定义
---@return number yOffset 分割线下方的内容起点
function AzerothCompanion.SettingsHost:BuildPageHeader(childFrame, startY, pageObject)
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  local titleText = getPageTitle(pageObject) -- 页面标题
  local titleLabel = childFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightHuge") -- Header 标题
  titleLabel:SetPoint("TOPLEFT", childFrame, "TOPLEFT", SETTINGS_HEADER_TITLE_LEFT, SETTINGS_HEADER_TITLE_TOP)
  titleLabel:SetText(titleText or "")
  childFrame._azerothCompanionHeaderTitle = titleLabel

  local resetButton = nil -- Header 恢复默认按钮
  if type(pageObject.resetHandler) == "function" then
    resetButton = CreateFrame("Button", nil, childFrame, "UIPanelButtonTemplate")
    resetButton:SetSize(SETTINGS_HEADER_BUTTON_WIDTH, SETTINGS_HEADER_BUTTON_HEIGHT)
    resetButton:SetPoint("TOPRIGHT", childFrame, "TOPRIGHT", SETTINGS_HEADER_BUTTON_RIGHT, SETTINGS_HEADER_BUTTON_TOP)
    resetButton:SetText(localeTable.SETTINGS_PAGE_RESET_DEFAULTS or "Defaults")
    resetButton:SetScript("OnClick", function()
      AzerothCompanion.SettingsHost:ResetPageToDefaults(pageObject)
    end)
    childFrame._azerothCompanionHeaderResetButton = resetButton
  end

  if pageObject.isRoot == true then
    local reloadButton = CreateFrame("Button", nil, childFrame, "UIPanelButtonTemplate") -- Header 重载页面按钮
    reloadButton:SetSize(SETTINGS_HEADER_BUTTON_WIDTH, SETTINGS_HEADER_BUTTON_HEIGHT)
    if resetButton then
      reloadButton:SetPoint("TOPRIGHT", resetButton, "TOPLEFT", -SETTINGS_HEADER_BUTTON_GAP, 0)
    else
      reloadButton:SetPoint("TOPRIGHT", childFrame, "TOPRIGHT", SETTINGS_HEADER_BUTTON_RIGHT, SETTINGS_HEADER_BUTTON_TOP)
    end
    reloadButton:SetText(localeTable.SETTINGS_PAGE_RELOAD or "Reload UI")
    reloadButton:SetScript("OnClick", function()
      ReloadUI()
    end)
    childFrame._azerothCompanionHeaderReloadButton = reloadButton
  end

  local dividerTexture = childFrame:CreateTexture(nil, "ARTWORK") -- Header 底部分割线
  dividerTexture:SetPoint("TOP", childFrame, "TOP", 0, SETTINGS_HEADER_DIVIDER_TOP)
  dividerTexture:SetSize(SCROLL_CHILD_WIDTH, 1)
  local atlasSuccess = false -- Atlas 设置是否成功
  if type(dividerTexture.SetAtlas) == "function" then
    atlasSuccess = pcall(function()
      dividerTexture:SetAtlas("Options_HorizontalDivider", true)
    end)
  end
  if atlasSuccess ~= true and type(dividerTexture.SetColorTexture) == "function" then
    dividerTexture:SetColorTexture(1, 1, 1, 0.85)
  end
  childFrame._azerothCompanionHeaderDivider = dividerTexture

  return math.min(
    (tonumber(startY) or 0) - SETTINGS_HEADER_HEIGHT - SETTINGS_HEADER_CONTENT_GAP,
    SETTINGS_HEADER_DIVIDER_TOP - SETTINGS_HEADER_CONTENT_GAP
  )
end

--- 构建界面语言区。
---@param childFrame Frame 页面根 child
---@param startY number 当前纵向游标
---@param pageKey string 当前叶子页键名
---@return number
function AzerothCompanion.SettingsHost:BuildLanguageSection(childFrame, startY, pageKey)
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  local settingsBox = CreateSettingsBox(childFrame, startY, pageKey) -- 语言设置容器
  settingsBox:AddMenuRow({
    label = localeTable.LOCALE_SECTION_TITLE,
    description = localeTable.LOCALE_HINT,
    defaultValue = "auto",
    refreshMode = "none",
    buttonWidth = 140,
    getValue = function()
      return AzerothCompanion.Config.Get(SettingId.GLOBAL_LOCALE, ACCOUNT_SCOPE) or "auto"
    end,
    setValue = function(localeKey)
      AzerothCompanion.Config.Set(SettingId.GLOBAL_LOCALE, ACCOUNT_SCOPE, localeKey)
    end,
    afterChange = function()
      AzerothCompanion.Localization.Apply()
      AzerothCompanion.SettingsHost:RefreshAllPages()
    end,
    options = {
      { value = "auto", label = localeTable.LOCALE_OPTION_AUTO or "Auto" },
      { value = "zhCN", label = localeTable.LOCALE_OPTION_ZHCN or "zhCN" },
      { value = "enUS", label = localeTable.LOCALE_OPTION_ENUS or "enUS" },
    },
  })
  return startY - settingsBox.realHeight - 10
end

--- 构建根节点三功能列表（地图 / 任务 / 冒险手册）。
---@param childFrame Frame 页面根 child
---@param startY number 当前纵向游标
---@param pageKey string 当前叶子页键名
---@return number
function AzerothCompanion.SettingsHost:BuildGeneralFeatureList(childFrame, startY, pageKey)
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  local yOffset = buildSectionHeader(childFrame, startY, localeTable.SETTINGS_GENERAL_FEATURE_LIST_TITLE or "") -- 当前纵向游标
  local settingsBox = CreateSettingsBox(childFrame, yOffset, pageKey) -- 功能列表容器
  local headerTop = settingsBox._azerothCompanionCursorY -- 表头顶部位置
  childFrame._azerothCompanionGeneralFeatureBox = settingsBox
  childFrame._azerothCompanionGeneralFeatureControls = {}

  local featureHeader = settingsBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall") -- 功能列表功能列标题
  featureHeader:SetPoint("TOPLEFT", settingsBox, "TOPLEFT", SETTINGS_ROW_LABEL_LEFT, headerTop)
  featureHeader:SetWidth(SETTINGS_ROW_LABEL_WIDTH)
  featureHeader:SetJustifyH("LEFT")
  featureHeader:SetText(localeTable.SETTINGS_GENERAL_FEATURE_LIST_FEATURE or "")

  local enableHeader = settingsBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall") -- 功能启用列标题
  enableHeader:SetPoint("TOPLEFT", settingsBox, "TOPLEFT", FEATURE_LIST_ENABLE_LEFT - 14, headerTop)
  enableHeader:SetWidth(68)
  enableHeader:SetJustifyH("CENTER")
  enableHeader:SetText(localeTable.SETTINGS_GENERAL_FEATURE_LIST_ENABLE or "")

  local debugHeader = settingsBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall") -- 调试输出列标题
  debugHeader:SetPoint("TOPLEFT", settingsBox, "TOPLEFT", FEATURE_LIST_DEBUG_LEFT - 14, headerTop)
  debugHeader:SetWidth(68)
  debugHeader:SetJustifyH("CENTER")
  debugHeader:SetText(localeTable.SETTINGS_GENERAL_FEATURE_LIST_DEBUG or "")

  local flyoutHeader = settingsBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall") -- 悬停菜单列标题
  flyoutHeader:SetPoint("TOPLEFT", settingsBox, "TOPLEFT", FEATURE_LIST_FLYOUT_LEFT - 14, headerTop)
  flyoutHeader:SetWidth(68)
  flyoutHeader:SetJustifyH("CENTER")
  flyoutHeader:SetText(localeTable.SETTINGS_GENERAL_FEATURE_LIST_FLYOUT or "")

  settingsBox:_ConsumeHeight(FEATURE_LIST_HEADER_HEIGHT, 0)

  for _, featureDef in ipairs(GENERAL_FEATURE_LIST) do
    local rowTop = settingsBox._azerothCompanionCursorY -- 功能行顶部位置
    local moduleId = featureDef.moduleId -- 功能模块 id
    local moduleObject = self.modulesById and self.modulesById[moduleId] or nil -- 功能模块定义
    local featureRefs = GENERAL_FEATURE_SETTING_REFS[moduleId] -- 功能行设置引用
    local featureTitle = localeTable[featureDef.nameKey or ""] or (moduleObject and getModuleTitle(moduleObject)) or moduleId -- 功能显示名

    local titleLabel = settingsBox:CreateFontString(nil, "OVERLAY", "GameFontNormal") -- 功能名称
    titleLabel:SetPoint("TOPLEFT", settingsBox, "TOPLEFT", SETTINGS_ROW_LABEL_LEFT, rowTop)
    titleLabel:SetWidth(SETTINGS_ROW_LABEL_WIDTH)
    titleLabel:SetJustifyH("LEFT")
    titleLabel:SetText(featureTitle)
    setFontStringTextColor(titleLabel, true)

    local enabledButton = createCheckboxControl(settingsBox) -- 功能启用勾选框
    enabledButton:SetSize(SETTINGS_CHECKBOX_SIZE, SETTINGS_CHECKBOX_SIZE)
    enabledButton:SetPoint("TOPLEFT", settingsBox, "TOPLEFT", FEATURE_LIST_ENABLE_LEFT, rowTop + SETTINGS_CHECKBOX_TOP_OFFSET)
    enabledButton._azerothCompanionFeatureModuleId = moduleId
    enabledButton._azerothCompanionFeatureColumnKey = "enabled"
    enabledButton._azerothCompanionFlyoutEntryId = featureDef.flyoutId

    local debugButton = createCheckboxControl(settingsBox) -- 调试输出勾选框
    debugButton:SetSize(SETTINGS_CHECKBOX_SIZE, SETTINGS_CHECKBOX_SIZE)
    debugButton:SetPoint("TOPLEFT", settingsBox, "TOPLEFT", FEATURE_LIST_DEBUG_LEFT, rowTop + SETTINGS_CHECKBOX_TOP_OFFSET)
    debugButton._azerothCompanionFeatureModuleId = moduleId
    debugButton._azerothCompanionFeatureColumnKey = "debug"
    debugButton._azerothCompanionFlyoutEntryId = featureDef.flyoutId

    local flyoutButton = createCheckboxControl(settingsBox) -- 悬停菜单勾选框
    flyoutButton:SetSize(SETTINGS_CHECKBOX_SIZE, SETTINGS_CHECKBOX_SIZE)
    flyoutButton:SetPoint("TOPLEFT", settingsBox, "TOPLEFT", FEATURE_LIST_FLYOUT_LEFT, rowTop + SETTINGS_CHECKBOX_TOP_OFFSET)
    flyoutButton._azerothCompanionFeatureModuleId = moduleId
    flyoutButton._azerothCompanionFeatureColumnKey = "flyout"
    flyoutButton._azerothCompanionFlyoutEntryId = featureDef.flyoutId
    childFrame._azerothCompanionGeneralFeatureControls[moduleId] = {
      enabled = enabledButton,
      debug = debugButton,
      flyout = flyoutButton,
    }

    -- 刷新当前功能行三个选择框的视觉状态。
    local function refreshRow()
      local isEnabled = getSettingValue(featureRefs.enabled) ~= false -- 功能启用状态
      local isDebug = getSettingValue(featureRefs.debug) == true -- 调试输出状态
      local selectedSlotIds = getFlyoutSlotIds() -- 当前悬停菜单勾选列表
      local isFlyoutSelected = hasStringValue(selectedSlotIds, featureDef.flyoutId) -- 悬停菜单状态
      enabledButton:SetChecked(isEnabled)
      debugButton:SetChecked(isDebug)
      flyoutButton:SetChecked(isFlyoutSelected)
      applyCheckboxState(enabledButton, true, isEnabled)
      applyCheckboxState(debugButton, true, isDebug)
      applyCheckboxState(flyoutButton, true, isFlyoutSelected)
    end

    enabledButton:SetScript("OnClick", function()
      setSettingValue(featureRefs.enabled, not (getSettingValue(featureRefs.enabled) ~= false))
      if moduleObject and type(moduleObject.OnEnabledSettingChanged) == "function" then
        moduleObject.OnEnabledSettingChanged(getSettingValue(featureRefs.enabled) ~= false)
      end
      refreshRow()
    end)

    debugButton:SetScript("OnClick", function()
      setSettingValue(featureRefs.debug, not (getSettingValue(featureRefs.debug) == true))
      if moduleObject and type(moduleObject.OnDebugSettingChanged) == "function" then
        moduleObject.OnDebugSettingChanged(getSettingValue(featureRefs.debug) == true)
      end
      refreshRow()
    end)

    flyoutButton:SetScript("OnClick", function()
      local selectedSlotIds = getFlyoutSlotIds() -- 当前悬停菜单勾选列表
      if hasStringValue(selectedSlotIds, featureDef.flyoutId) then
        removeStringValue(selectedSlotIds, featureDef.flyoutId)
      else
        selectedSlotIds[#selectedSlotIds + 1] = featureDef.flyoutId
      end
      AzerothCompanion.Config.Set(SettingId.MINIMAP_FLYOUT_SLOT_IDS, ACCOUNT_SCOPE, selectedSlotIds)
      refreshMinimapFlyout()
      refreshRow()
    end)

    settingsBox:_RegisterRefresher(refreshRow)
    refreshRow()
    settingsBox:_ConsumeHeight(SETTINGS_ROW_HEIGHT, SETTINGS_ROW_GAP)
  end

  return yOffset - settingsBox.realHeight - 10
end

--- 构建模块页首的高频主开关。
---@param childFrame Frame 页面根 child
---@param startY number 当前纵向游标
---@param moduleObject table 模块定义
---@param pageKey string 所属叶子页键名
---@return number
function AzerothCompanion.SettingsHost:BuildModulePrimaryControls(childFrame, startY, moduleObject, pageKey)
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  local enabledRef = MODULE_PRIMARY_SETTING_REFS[moduleObject.id] -- 模块启用设置引用
  local settingsBox = CreateSettingsBox(childFrame, startY, pageKey) -- 模块主控件容器
  settingsBox:AddToggleRow({
    label = localeTable.SETTINGS_MODULE_ENABLE or "",
    description = getModuleIntro(moduleObject),
    defaultValue = true,
    refreshMode = "page",
    getValue = function()
      return getSettingValue(enabledRef) ~= false
    end,
    setValue = function(value)
      setSettingValue(enabledRef, value == true)
    end,
    afterChange = function(enabled)
      if moduleObject.OnEnabledSettingChanged then
        moduleObject.OnEnabledSettingChanged(enabled == true)
      end
    end,
  })
  return startY - settingsBox.realHeight
end

--- 构建模块页尾的诊断开关区；恢复默认统一放到页头。
---@param childFrame Frame 页面根 child
---@param startY number 当前纵向游标
---@param moduleObject table 模块定义
---@param pageKey string 所属叶子页键名
---@return number
function AzerothCompanion.SettingsHost:BuildModuleSecondaryControls(childFrame, startY, moduleObject, pageKey)
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  local debugRef = MODULE_DEBUG_SETTING_REFS[moduleObject.id] -- 模块调试设置引用
  local settingsBox = CreateSettingsBox(childFrame, startY, pageKey) -- 模块次级控件容器
  settingsBox:AddToggleRow({
    label = localeTable.SETTINGS_MODULE_DEBUG or "",
    refreshMode = "page",
    getValue = function()
      return getSettingValue(debugRef) == true
    end,
    setValue = function(value)
      setSettingValue(debugRef, value == true)
    end,
    afterChange = function(enabled)
      if moduleObject.OnDebugSettingChanged then
        moduleObject.OnDebugSettingChanged(enabled == true)
      end
    end,
  })
  return startY - settingsBox.realHeight
end

--- 构建叶子页中的单个模块分节。
---@param childFrame Frame 页面根 child
---@param startY number 当前纵向游标
---@param moduleObject table 模块定义
---@param pageKey string 所属叶子页键名
---@param showSectionHeader boolean 是否显示模块标题与简介
---@return number
function AzerothCompanion.SettingsHost:BuildModuleSection(childFrame, startY, moduleObject, pageKey, showSectionHeader)
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  local yOffset = startY -- 当前纵向游标
  local isCompactModule = isInterfaceCompactModule(moduleObject.id) -- 是否使用紧凑界面模块布局

  if showSectionHeader == true or isCompactModule then
    yOffset = buildSectionHeader(childFrame, yOffset, getModuleTitle(moduleObject))
  end

  if not isGeneralFeatureListModule(moduleObject.id) and not isInterfaceCompactModule(moduleObject.id) then
    yOffset = self:BuildModulePrimaryControls(childFrame, yOffset, moduleObject, pageKey)
  end

  local boxFrame = CreateSettingsBox(childFrame, yOffset, pageKey) -- 模块专属设置容器
  moduleObject.RegisterSettings(boxFrame)

  if boxFrame._azerothCompanionHasRows ~= true then
    boxFrame:Hide()
  else
    if not isCompactModule then
      local settingsTitle = childFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge") -- 模块设置标题
      settingsTitle:SetPoint("TOPLEFT", childFrame, "TOPLEFT", SETTINGS_SECTION_TITLE_LEFT, yOffset)
      settingsTitle:SetText(localeTable.SETTINGS_MODULE_SECTION_TITLE or "")
      yOffset = yOffset - SETTINGS_SECTION_TO_FIRST_ROW_GAP
    end
    boxFrame:ClearAllPoints()
    boxFrame:SetPoint("TOPLEFT", childFrame, "TOPLEFT", 0, yOffset)
    boxFrame.realHeight = math.max(tonumber(boxFrame.realHeight) or 0, SETTINGS_BOX_MIN_HEIGHT)
    boxFrame:SetHeight(boxFrame.realHeight)
    yOffset = yOffset - boxFrame.realHeight - 16
  end

  if not isGeneralFeatureListModule(moduleObject.id) and not isInterfaceCompactModule(moduleObject.id) then
    yOffset = self:BuildModuleSecondaryControls(childFrame, yOffset, moduleObject, pageKey)
  end
  return yOffset - 12
end

--- 构建根节点通用内容或功能叶子页。
---@param pageObject table 页面定义
function AzerothCompanion.SettingsHost:BuildLeafPage(pageObject)
  local childFrame = resetCanvasPanel(pageObject.panel) -- 页面内容根节点
  local moduleIdList = pageObject.moduleIds or {} -- 叶子页包含的模块 id 列表
  local yOffset = -8 -- 当前纵向游标

  yOffset = self:BuildPageHeader(childFrame, yOffset, pageObject)

  if pageObject.includeLanguageSection == true then
    yOffset = self:BuildLanguageSection(childFrame, yOffset, pageObject.key)
  end
  if pageObject.includeFeatureList == true then
    yOffset = self:BuildGeneralFeatureList(childFrame, yOffset, pageObject.key)
  end

  for indexNumber, moduleId in ipairs(moduleIdList) do
    local moduleObject = self.modulesById and self.modulesById[moduleId] or nil -- 当前叶子页对应模块
    if moduleObject then
      local showSectionHeader = #moduleIdList > 1 -- 多模块页显示分节标题
      yOffset = self:BuildModuleSection(childFrame, yOffset, moduleObject, pageObject.key, showSectionHeader)
      if indexNumber < #moduleIdList then
        yOffset = yOffset - 8
      end
    end
  end

  setChildHeight(childFrame, yOffset)
end

--- 构建关于页。
---@param pageObject table 页面定义
function AzerothCompanion.SettingsHost:BuildAboutPage(pageObject)
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  local childFrame = resetCanvasPanel(pageObject.panel) -- 页面内容根节点
  local yOffset = -8 -- 当前纵向游标

  yOffset = self:BuildPageHeader(childFrame, yOffset, pageObject)

  local versionLabel = childFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight") -- 版本文本
  versionLabel:SetPoint("TOPLEFT", childFrame, "TOPLEFT", SETTINGS_ROW_LABEL_LEFT, yOffset)
  versionLabel:SetJustifyH("LEFT")
  versionLabel:SetText(string.format(
    localeTable.SETTINGS_ABOUT_VERSION_FMT or "%s",
    tostring(AzerothCompanion.API.Chat.GetAddOnMetadata(AzerothCompanion.ADDON_NAME, "Version") or "")
  ))
  yOffset = yOffset - 24

  local clientLabel = childFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight") -- 客户端文本
  clientLabel:SetPoint("TOPLEFT", childFrame, "TOPLEFT", SETTINGS_ROW_LABEL_LEFT, yOffset)
  clientLabel:SetJustifyH("LEFT")
  clientLabel:SetText(localeTable.SETTINGS_ABOUT_CLIENT or "")
  yOffset = yOffset - 32

  local introText = localeTable.SETTINGS_ABOUT_INTRO or "" -- 对外插件说明
  if introText ~= "" then
    local introLabel = childFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") -- 插件说明文本
    introLabel:SetPoint("TOPLEFT", childFrame, "TOPLEFT", SETTINGS_ROW_LABEL_LEFT, yOffset)
    introLabel:SetWidth(560)
    introLabel:SetJustifyH("LEFT")
    introLabel:SetWordWrap(true)
    introLabel:SetText(introText)
    yOffset = yOffset - math.max(24, math.ceil((introLabel:GetStringHeight() or 0) + 10))
  end

  setChildHeight(childFrame, yOffset)
end

--- 确保 Settings 根类目与各叶子页已注册。
function AzerothCompanion.SettingsHost:EnsureCreated()
  AzerothCompanion_NamespaceEnsure()
  if self.category then
    return
  end

  if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterCanvasLayoutSubcategory) then
    error("AzerothCompanion: " .. (AzerothCompanion.Localization.Strings and AzerothCompanion.Localization.Strings.ERR_SETTINGS_API or "Retail Settings API required"))
  end

  self.pages = {}
  self.pagesByKey = {}
  self.modulesById = {}

  local moduleList = collectSettingsModules() -- 带设置页的模块列表
  for _, moduleObject in ipairs(moduleList) do
    self.modulesById[moduleObject.id] = moduleObject
  end

  local rootPanel = createCanvasPanel("AzerothCompanionSettingsRootPanel") -- AzerothCompanion 根类目页面
  local category = Settings.RegisterCanvasLayoutCategory(rootPanel, (AzerothCompanion.Localization.Strings and AzerothCompanion.Localization.Strings.SETTINGS_CATEGORY_TITLE) or AzerothCompanion.ADDON_DISPLAY_NAME or "AzerothCompanion")
  Settings.RegisterAddOnCategory(category)
  self.category = category

  local pageList = {
    {
      key = "general",
      panel = rootPanel,
      titleKey = "SETTINGS_CATEGORY_TITLE",
      includeLanguageSection = true,
      includeFeatureList = true,
      moduleIds = { "minimap_button" },
      isLeaf = true,
      isRoot = true,
      resetHandler = resetGeneralPageToDefaults,
      builder = function(pageDef)
        AzerothCompanion.SettingsHost:BuildLeafPage(pageDef)
      end,
    },
    {
      key = "interface",
      panel = createCanvasPanel("AzerothCompanionSettingsInterfacePanel"),
      titleKey = "SETTINGS_PAGE_INTERFACE_TITLE",
      moduleIds = { "mover", "tooltip_anchor" },
      isLeaf = true,
      resetHandler = resetInterfacePageToDefaults,
      builder = function(pageDef)
        AzerothCompanion.SettingsHost:BuildLeafPage(pageDef)
      end,
    },
    {
      key = "map",
      panel = createCanvasPanel("AzerothCompanionSettingsMapPanel"),
      titleKey = "SETTINGS_PAGE_MAP_TITLE",
      moduleIds = { "navigation" },
      isLeaf = true,
      resetHandler = resetMapPageToDefaults,
      builder = function(pageDef)
        AzerothCompanion.SettingsHost:BuildLeafPage(pageDef)
      end,
    },
    {
      key = "chat",
      panel = createCanvasPanel("AzerothCompanionSettingsChatPanel"),
      titleKey = "SETTINGS_PAGE_CHAT_TITLE",
      moduleIds = { "chat" },
      isLeaf = true,
      resetHandler = resetChatPageToDefaults,
      builder = function(pageDef)
        AzerothCompanion.SettingsHost:BuildLeafPage(pageDef)
      end,
    },
    {
      key = "quest",
      panel = createCanvasPanel("AzerothCompanionSettingsQuestPanel"),
      titleKey = "SETTINGS_PAGE_QUEST_TITLE",
      moduleIds = { "quest" },
      isLeaf = true,
      resetHandler = resetQuestPageToDefaults,
      builder = function(pageDef)
        AzerothCompanion.SettingsHost:BuildLeafPage(pageDef)
      end,
    },
    {
      key = "encounter_journal",
      panel = createCanvasPanel("AzerothCompanionSettingsEncounterJournalPanel"),
      titleKey = "SETTINGS_PAGE_ENCOUNTER_JOURNAL_TITLE",
      moduleIds = { "encounter_journal" },
      isLeaf = true,
      resetHandler = resetEncounterJournalPageToDefaults,
      builder = function(pageDef)
        AzerothCompanion.SettingsHost:BuildLeafPage(pageDef)
      end,
    },
    {
      key = "about",
      panel = createCanvasPanel("AzerothCompanionSettingsAboutPanel"),
      titleKey = "SETTINGS_PAGE_ABOUT_TITLE",
      isLeaf = true,
      builder = function(pageDef)
        AzerothCompanion.SettingsHost:BuildAboutPage(pageDef)
      end,
    },
  }

  for _, pageObject in ipairs(pageList) do
    self.pages[#self.pages + 1] = pageObject
    self.pagesByKey[pageObject.key] = pageObject

    if pageObject.isRoot == true then
      pageObject.category = category
      if pageObject.builder then
        pageObject.builder(pageObject)
      end
    else
      local subcategory = Settings.RegisterCanvasLayoutSubcategory(
        category,
        pageObject.panel,
        getPageTitle(pageObject)
      ) -- 左侧子页面
      Settings.RegisterAddOnCategory(subcategory)
      pageObject.category = subcategory
    end
  end
end

--- 战斗内独立展示：全屏遮罩 + 底板（与 Canvas 分层，避免全透明与比例失调）。
local standalonePresentation

---@return table host, dimmer, box
local function ensureStandalonePresentationHost()
  if standalonePresentation then
    return standalonePresentation
  end
  local host = CreateFrame("Frame", "AzerothCompanionSettingsStandaloneHost", UIParent) -- 独立展示宿主
  host:SetFrameStrata("DIALOG")
  host:SetFrameLevel(100)
  host:SetAllPoints(UIParent)
  host:Hide()

  local dimmer = CreateFrame("Button", nil, host) -- 全屏遮罩按钮
  dimmer:SetAllPoints(host)
  dimmer:SetFrameLevel(0)
  local dimTexture = dimmer:CreateTexture(nil, "BACKGROUND") -- 遮罩纹理
  dimTexture:SetAllPoints()
  dimTexture:SetColorTexture(0, 0, 0, 0.5)
  dimmer:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  dimmer:SetScript("OnClick", function()
    AzerothCompanion.SettingsHost:HideStandalonePresentation()
  end)

  local boxFrame -- 独立展示底板
  do
    local okFlag, backdropFrame = pcall(function()
      return CreateFrame("Frame", nil, host, "BackdropTemplate")
    end)
    boxFrame = (okFlag and backdropFrame) and backdropFrame or CreateFrame("Frame", nil, host)
  end
  boxFrame:SetFrameLevel(5)
  local padding = 40 -- 底板边距
  boxFrame:SetSize(PANEL_WIDTH + padding, PANEL_HEIGHT + padding)
  boxFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  local backdropOk = pcall(function()
    boxFrame:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true,
      tileSize = 32,
      edgeSize = 32,
      insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    boxFrame:SetBackdropColor(0.06, 0.06, 0.08, 0.98)
    boxFrame:SetBackdropBorderColor(0.5, 0.5, 0.55, 1)
  end)
  if not backdropOk then
    local fallbackTexture = boxFrame:CreateTexture(nil, "ARTWORK") -- 兜底底色
    fallbackTexture:SetAllPoints()
    fallbackTexture:SetColorTexture(0.09, 0.09, 0.11, 0.98)
  end

  standalonePresentation = { host = host, dimmer = dimmer, box = boxFrame }
  return standalonePresentation
end

--- 打开系统设置前收起 ESC 菜单，避免仅关闭设置后仍留在游戏菜单栈顶。
local function dismissGameMenuIfShown()
  local gameMenuFrame = _G.GameMenuFrame -- ESC 菜单框
  if gameMenuFrame and gameMenuFrame.IsShown and gameMenuFrame:IsShown() and HideUIPanel then
    pcall(HideUIPanel, gameMenuFrame)
  end
end

--- 关闭按钮模板：不同版本名称略有差异，依次尝试。
local STANDALONE_CLOSE_TEMPLATES = {
  "UIPanelCloseButtonDefaultTemplate",
  "UIPanelCloseButton",
}

---@param panel Frame
---@return Button
local function createStandaloneCloseButton(panel)
  for _, templateName in ipairs(STANDALONE_CLOSE_TEMPLATES) do
    local okFlag, closeButton = pcall(function()
      return CreateFrame("Button", nil, panel, templateName)
    end)
    if okFlag and closeButton then
      return closeButton
    end
  end
  local fallbackButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate") -- 兜底关闭按钮
  fallbackButton:SetSize(24, 22)
  fallbackButton:SetText("X")
  return fallbackButton
end

--- 隐藏所有已注册的 Canvas 面板与战斗内嵌独立展示用的关闭键（不卸载内容）。
function AzerothCompanion.SettingsHost:HideStandalonePresentation()
  self:EnsureCreated()
  if standalonePresentation and standalonePresentation.host then
    standalonePresentation.host:Hide()
  end
  for _, pageObject in ipairs(self.pages or {}) do
    local panel = pageObject.panel -- 当前页面面板
    if panel then
      if panel._azerothCompanionStandaloneScaleApplied then
        panel:SetScale(panel._azerothCompanionStandaloneSavedScale or 1)
        panel._azerothCompanionStandaloneScaleApplied = nil
        panel._azerothCompanionStandaloneSavedScale = nil
      end
      panel:Hide()
      panel:SetScript("OnKeyDown", nil)
      panel:EnableKeyboard(false)
      if panel._azerothCompanionStandaloneClose then
        panel._azerothCompanionStandaloneClose:Hide()
      end
    end
  end
end

--- 战斗等场景：不经过 `Settings.OpenToCategory`，将指定叶子页 Canvas 置于遮罩+底板之上。
---@param pageKey string 叶子页键名
function AzerothCompanion.SettingsHost:ShowStandalonePageByKey(pageKey)
  self:EnsureCreated()
  local pageObject = self:GetPageByKey(pageKey) -- 目标页面
  if not pageObject or not pageObject.panel then
    return
  end
  self:HideStandalonePresentation()
  dismissGameMenuIfShown()
  local presentation = ensureStandalonePresentationHost() -- 独立展示宿主
  local panel = pageObject.panel -- 页面面板
  local boxFrame = presentation.box -- 对话框底板
  panel:ClearAllPoints()
  panel:SetPoint("CENTER", boxFrame, "CENTER", 0, 0)
  panel:SetFrameStrata("DIALOG")
  panel:SetFrameLevel(200)
  panel._azerothCompanionStandaloneSavedScale = panel:GetScale() or 1
  panel._azerothCompanionStandaloneScaleApplied = true
  panel:SetScale(panel._azerothCompanionStandaloneSavedScale * STANDALONE_PANEL_SCALE)
  panel:EnableMouse(true)
  panel:EnableKeyboard(true)
  pcall(function()
    panel:SetPropagateKeyboardInput(false)
  end)
  panel:SetScript("OnKeyDown", function(_, keyName)
    if keyName == "ESCAPE" then
      AzerothCompanion.SettingsHost:HideStandalonePresentation()
    end
  end)
  if not panel._azerothCompanionStandaloneClose then
    local closeButton = createStandaloneCloseButton(panel) -- 独立展示关闭按钮
    closeButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, -4)
    closeButton:SetScript("OnClick", function()
      AzerothCompanion.SettingsHost:HideStandalonePresentation()
    end)
    panel._azerothCompanionStandaloneClose = closeButton
  else
    panel._azerothCompanionStandaloneClose:Show()
  end
  presentation.host:Show()
  panel:Show()
end

--- 打开设置并定位到指定叶子页。
---@param pageKey string 叶子页键名
function AzerothCompanion.SettingsHost:OpenToPageKey(pageKey)
  self:EnsureCreated()
  local fallbackPage = self:GetPageByKey(DEFAULT_LEAF_PAGE_KEY) -- 默认页
  local pageObject = self:GetPageByKey(pageKey) or fallbackPage -- 目标页
  if not pageObject then
    return
  end

  self:BuildPage(pageObject.key)
  self:RememberLeafPageKey(pageObject.key)
  if InCombatLockdown() then
    self:ShowStandalonePageByKey(pageObject.key)
    return
  end

  self:HideStandalonePresentation()
  dismissGameMenuIfShown()
  if Settings and Settings.OpenToCategory and pageObject.category then
    pcall(function()
      Settings.OpenToCategory(pageObject.category:GetID())
    end)
  end
end

--- 打开默认叶子页：优先上次停留，否则回退到“通用”。
function AzerothCompanion.SettingsHost:Open()
  self:OpenToPageKey(self:GetPreferredLeafPageKey())
end

--- 打开设置并定位到指定功能模块所属叶子页。
---@param moduleId string 功能模块 id
function AzerothCompanion.SettingsHost:OpenToModulePage(moduleId)
  self:OpenToPageKey(self:GetModulePageKey(moduleId))
end

--- 打开设置并定位到关于页。
function AzerothCompanion.SettingsHost:OpenToAbout()
  self:OpenToPageKey("about")
end

local function tryGameMenuAttach()
  if AzerothCompanion._gameMenuBtn then
    return true
  end
  AzerothCompanion_NamespaceEnsure()
  AzerothCompanion.SettingsHost:EnsureCreated()
  local gameMenuFrame = _G.GameMenuFrame -- ESC 菜单框
  if not gameMenuFrame then
    return false
  end
  local anchorButton = _G.GameMenuButtonOptions or _G.GameMenuButtonSettings -- 设置按钮锚点
  if not anchorButton then
    return false
  end
  local azerothCompanionButton = CreateFrame("Button", "GameMenuButtonAzerothCompanion", gameMenuFrame, "GameMenuButtonTemplate") -- ESC 菜单 AzerothCompanion 按钮
  azerothCompanionButton:SetText(AzerothCompanion.Localization.Strings.GAMEMENU_AZEROTHCOMPANION)
  azerothCompanionButton:SetPoint("TOP", anchorButton, "BOTTOM", 0, -1)
  azerothCompanionButton:SetScript("OnClick", function()
    HideUIPanel(_G.GameMenuFrame)
    AzerothCompanion.SettingsHost:Open()
  end)
  AzerothCompanion._gameMenuBtn = azerothCompanionButton
  return true
end

--- 注册 ESC 菜单中的 AzerothCompanion 入口；当锚点按钮延迟创建时通过 OnShow/事件重试。
function AzerothCompanion.GameMenu_Init()
  if tryGameMenuAttach() then
    return
  end
  if AzerothCompanion._gameMenuHooked then
    return
  end
  AzerothCompanion._gameMenuHooked = true

  local function attemptAttach()
    local gameMenuFrame = _G.GameMenuFrame -- ESC 菜单框
    if gameMenuFrame and not AzerothCompanion._gameMenuShowHooked then
      AzerothCompanion._gameMenuShowHooked = true
      gameMenuFrame:HookScript("OnShow", tryGameMenuAttach)
    end
    tryGameMenuAttach()
  end

  local watcherFrame = CreateFrame("Frame") -- 延迟重试监听器
  watcherFrame:RegisterEvent("ADDON_LOADED")
  watcherFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
  watcherFrame:SetScript("OnEvent", function()
    attemptAttach()
  end)
  attemptAttach()
end
