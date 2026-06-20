--[[
  冒险指南增强模块（encounter_journal）。
  本文件仅保留模块注册、事件入口、调度器与设置页等组装层逻辑。
  具体实现已拆分到 Modules/EncounterJournal/*.lua 私有文件。
]]

local Internal = AzerothCompanion.Modules.EncounterJournal.Internal -- 冒险指南内部命名空间
local MODULE_ID = Internal.MODULE_ID
local Runtime = Internal.Runtime
local CreateFrame = Internal.CreateFrame
local microTooltipAppendState = Internal.microTooltipAppendState
local scrollBoxCache = Internal.scrollBoxCache

local DropFilter = Internal.DropFilter
local DetailEnhancer = Internal.DetailEnhancer
local LockoutOverlay = Internal.LockoutOverlay
local ListNavigationPin = Internal.ListNavigationPin

local function isModuleEnabled()
  return Internal.IsModuleEnabled()
end

local function isDebugEnabled()
  return Internal.GetAccountSetting("ENCOUNTER_JOURNAL_DEBUG", false) == true
end

local function getEncounterInfoFrame()
  return Internal.GetEncounterInfoFrame()
end

local function refreshAll()
  DropFilter = Internal.DropFilter
  DetailEnhancer = Internal.DetailEnhancer
  LockoutOverlay = Internal.LockoutOverlay
  ListNavigationPin = Internal.ListNavigationPin
  DropFilter:createUI()
  DetailEnhancer:refresh()
  DropFilter:updateVisibility()
  DropFilter:applyFilter()
  ListNavigationPin:updateFrames()
  LockoutOverlay:updateFrames()
  LockoutOverlay:hookTooltips()
end

-- ============================================================================
-- 微型菜单「冒险手册」按钮 Tooltip 增补（右下角菜单项）
-- ============================================================================

local microButtonTooltipHooked = false

--- 获取冒险手册微型菜单按钮（Retail 主路径为 EJMicroButton，旧名仅作兜底）。
---@return Button|nil
local function getAdventureGuideMicroButton()
  local microButton = _G.EJMicroButton -- Retail 微型菜单按钮全局名
  if not microButton then
    microButton = _G.EncounterJournalMicroButton -- 历史命名兜底
  end
  return microButton
end

--- 向当前冒险手册微型按钮 tooltip 追加副本 CD 摘要（带单次悬停去重）。
local function appendAdventureGuideMicroButtonLockoutLines()
  if not isModuleEnabled() then
    return
  end
  if not GameTooltip or not GameTooltip.AddLine then
    return
  end
  if microTooltipAppendState[GameTooltip] == true then
    return
  end
  microTooltipAppendState[GameTooltip] = true

  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化字符串表
  local sectionTitle = localeTable.MINIMAP_FLYOUT_ADVENTURE_JOURNAL_LOCKOUTS_TITLE or "Current lockouts" -- 标题文案
  local emptyText = localeTable.MINIMAP_FLYOUT_ADVENTURE_JOURNAL_LOCKOUTS_EMPTY or "No saved instance lockouts." -- 空状态文案
  local moreFormat = localeTable.MINIMAP_FLYOUT_ADVENTURE_JOURNAL_LOCKOUTS_MORE_FMT or "+%d more..." -- 溢出计数文案

  Runtime.TooltipAddLine(GameTooltip, " ")
  Runtime.TooltipAddLine(GameTooltip, sectionTitle, 1, 0.82, 0.2)

  if not AzerothCompanion.API.EncounterJournal or type(AzerothCompanion.API.EncounterJournal.BuildSavedInstanceLockoutTooltipLines) ~= "function" then
    Runtime.TooltipAddLine(GameTooltip, emptyText, 0.75, 0.75, 0.75, true)
    return
  end

  local lineList, overflowCount = AzerothCompanion.API.EncounterJournal.BuildSavedInstanceLockoutTooltipLines(8) -- 锁定摘要行与溢出数量
  if type(lineList) ~= "table" or #lineList == 0 then
    Runtime.TooltipAddLine(GameTooltip, emptyText, 0.75, 0.75, 0.75, true)
    return
  end

  for _, lineText in ipairs(lineList) do
    Runtime.TooltipAddLine(GameTooltip, lineText, 0.82, 0.88, 1, false)
  end
  if type(overflowCount) == "number" and overflowCount > 0 then
    Runtime.TooltipAddLine(GameTooltip, string.format(moreFormat, overflowCount), 0.6, 0.6, 0.6, true)
  end
end

--- 若当前 tooltip 正在显示冒险手册微型按钮提示，则重建一次（用于 UPDATE_INSTANCE_INFO 回刷）。
local function refreshAdventureGuideMicroButtonTooltipIfOwned()
  local microButton = getAdventureGuideMicroButton() -- 冒险手册微型菜单按钮
  if not microButton then
    return
  end
  if not GameTooltip or not GameTooltip.IsOwned or not GameTooltip:IsOwned(microButton) then
    return
  end
  if GameTooltip then
    microTooltipAppendState[GameTooltip] = nil
  end
  local onEnterHandler = microButton.GetScript and microButton:GetScript("OnEnter") -- 微型按钮 OnEnter 脚本
  if type(onEnterHandler) == "function" then
    pcall(onEnterHandler, microButton)
    appendAdventureGuideMicroButtonLockoutLines()
    Runtime.TooltipShow(GameTooltip)
    return
  end
  appendAdventureGuideMicroButtonLockoutLines()
  Runtime.TooltipShow(GameTooltip)
end

--- 在右下角微型菜单的冒险手册按钮 tooltip 末尾追加当前角色副本 CD 摘要。
local function hookAdventureGuideMicroButtonTooltip()
  local microButton = getAdventureGuideMicroButton() -- 冒险手册微型菜单按钮
  if not microButton then
    return
  end

  if not microButtonTooltipHooked and microButton.HookScript then
    microButtonTooltipHooked = true
    microButton:HookScript("OnEnter", function()
      pcall(function()
        if type(RequestRaidInfo) == "function" then
          pcall(RequestRaidInfo)
        end
        if GameTooltip then
          microTooltipAppendState[GameTooltip] = nil
        end
        appendAdventureGuideMicroButtonLockoutLines()
        Runtime.TooltipShow(GameTooltip)
      end)
    end)
    microButton:HookScript("OnLeave", function()
      if GameTooltip then
        microTooltipAppendState[GameTooltip] = nil
      end
    end)
  end

end

--- 刷新调度器（防抖）。
local RefreshScheduler = {
  timer = nil,
  token = 0,
  delays = {
    frame_show = 0.15,
    list_refresh = 0.05,
    tab_change = 0.05,
    lockout_update = 0.1,
  },
}

function RefreshScheduler:schedule(reason)
  if self.timer and self.timer.Cancel then
    self.timer:Cancel()
  end
  self.timer = nil

  local delay = self.delays[reason] or 0.1
  self.token = (self.token or 0) + 1
  local currentToken = self.token -- 当前调度令牌

  local timerHandle = Runtime.NewTimer(delay, function()
    if self.token ~= currentToken then
      return
    end
    self.timer = nil
    self:execute()
  end)
  if timerHandle then
    self.timer = timerHandle
    return
  end

  local afterScheduled = false -- 延时任务是否已调度
  Runtime.After(delay, function()
    afterScheduled = true
    if self.token ~= currentToken then
      return
    end
    self.timer = nil
    self:execute()
  end)
  if afterScheduled then
    return
  end
  self:execute()
end

function RefreshScheduler:cancel()
  if self.timer and self.timer.Cancel then
    self.timer:Cancel()
  end
  self.timer = nil
  self.token = (self.token or 0) + 1
end

function RefreshScheduler:execute()
  local success, err = pcall(refreshAll)
  if not success then
    if isDebugEnabled() then
      print("AzerothCompanion EncounterJournal refresh error:", err)
    end
  end
  self.timer = nil
end

--- Hook 管理器（每个 Blizzard hook 单独记录，允许懒加载时机补挂）。
local hookState = { -- Blizzard hook 安装状态
  listInstances = false,
  lootUpdate = false,
  contentTabSelect = false,
  displayInstance = false,
  displayEncounter = false,
  setDifficulty = false,
  rootOnShow = false,
}
local detailInfoOnShowHooked = false

local function hookDetailInfoOnShow()
  if detailInfoOnShowHooked then
    return
  end
  local infoFrame = getEncounterInfoFrame() -- 详情信息面板
  if not infoFrame or not infoFrame.HookScript then
    return
  end
  detailInfoOnShowHooked = true
  infoFrame:HookScript("OnShow", function()
    RefreshScheduler:schedule("detail_info_show")
  end)
end

local function initHooks()
  if AzerothCompanion.API and AzerothCompanion.API.Tooltip and type(AzerothCompanion.API.Tooltip.InstallEncounterJournalTooltipHook) == "function" then
    AzerothCompanion.API.Tooltip.InstallEncounterJournalTooltipHook()
  end

  -- Hook 1: 列表刷新
  if not hookState.listInstances and hooksecurefunc and type(_G.EncounterJournal_ListInstances) == "function" then
    local hookSuccess = pcall(function() -- 列表刷新 hook 安装结果
      hooksecurefunc("EncounterJournal_ListInstances", function()
        scrollBoxCache.ref = nil
        scrollBoxCache.lastUpdate = 0
        DropFilter:createUI()
        RefreshScheduler:schedule("list_refresh")
      end)
    end)
    if hookSuccess then
      hookState.listInstances = true
    end
  end

  -- Hook 1.5: 详情页战利品更新（用于掉落筛选相关刷新）
  if not hookState.lootUpdate and hooksecurefunc and type(_G.EncounterJournal_LootUpdate) == "function" then
    local hookSuccess = pcall(function() -- 战利品刷新 hook 安装结果
      hooksecurefunc("EncounterJournal_LootUpdate", function()
        RefreshScheduler:schedule("detail_loot_update")
      end)
    end)
    if hookSuccess then
      hookState.lootUpdate = true
    end
  end

  -- Hook 2: 标签切换（用于刷新列表缓存）
  if not hookState.contentTabSelect and hooksecurefunc and type(_G.EJ_ContentTab_Select) == "function" then
    local hookSuccess = pcall(function() -- 内容页签 hook 安装结果
      hooksecurefunc("EJ_ContentTab_Select", function()
        Runtime.After(0, function()
          scrollBoxCache.ref = nil
          scrollBoxCache.lastUpdate = 0
          RefreshScheduler:schedule("tab_change")
        end)
      end)
    end)
    if hookSuccess then
      hookState.contentTabSelect = true
    end
  end

  -- Hook 2.5: 详情页切换实例/首领
  if not hookState.displayInstance and hooksecurefunc and type(_G.EncounterJournal_DisplayInstance) == "function" then
    local hookSuccess = pcall(function() -- 副本详情 hook 安装结果
      hooksecurefunc("EncounterJournal_DisplayInstance", function()
        RefreshScheduler:schedule("detail_display")
        hookDetailInfoOnShow()
      end)
    end)
    if hookSuccess then
      hookState.displayInstance = true
    end
  end
  if not hookState.displayEncounter and hooksecurefunc and type(_G.EncounterJournal_DisplayEncounter) == "function" then
    local hookSuccess = pcall(function() -- 首领详情 hook 安装结果
      hooksecurefunc("EncounterJournal_DisplayEncounter", function()
        RefreshScheduler:schedule("detail_display")
        hookDetailInfoOnShow()
      end)
    end)
    if hookSuccess then
      hookState.displayEncounter = true
    end
  end

  -- Hook 2.6: 右侧难度切换（标题后“重置：xxxx”需与当前难度匹配）
  if not hookState.setDifficulty and hooksecurefunc and type(_G.EJ_SetDifficulty) == "function" then
    local hookSuccess = pcall(function() -- 难度切换 hook 安装结果
      hooksecurefunc("EJ_SetDifficulty", function()
        RefreshScheduler:schedule("detail_difficulty")
      end)
    end)
    if hookSuccess then
      hookState.setDifficulty = true
    end
  end

  -- Hook 3: 主框架显示
  local ej = _G.EncounterJournal -- 冒险指南根框体
  if not hookState.rootOnShow and ej and ej.HookScript then
    local hookSuccess = pcall(function() -- 根框体 OnShow hook 安装结果
      ej:HookScript("OnShow", function()
        RequestRaidInfo()
        hookDetailInfoOnShow()
        -- 页签顺序/显隐在 OnShow 当帧先应用，避免首帧出现默认顺序闪烁。
        if isModuleEnabled() then
          DropFilter:createUI()
          DropFilter:updateVisibility()
        end
        RefreshScheduler:schedule("frame_show")
      end)
    end)
    if hookSuccess then
      hookState.rootOnShow = true
    end
  end

  hookDetailInfoOnShow()

  -- Hook 4: 右下角微型菜单的冒险手册按钮 tooltip
  hookAdventureGuideMicroButtonTooltip()
end

--- 事件管理器
local eventFrame = nil

local function setLockoutUpdateEventEnabled(enabled)
  if not eventFrame then
    return
  end
  if enabled then
    eventFrame:RegisterEvent("UPDATE_INSTANCE_INFO")
  else
    eventFrame:UnregisterEvent("UPDATE_INSTANCE_INFO")
  end
end

local function refreshAfterHookInit()
  -- hook 安装后无条件执行一次统一刷新，消除首次打开时序差异。
  local refreshSuccess, refreshError = pcall(refreshAll) -- 统一刷新执行结果
  if not refreshSuccess and isDebugEnabled() then
    print("AzerothCompanion EncounterJournal post-hook refresh error:", refreshError)
  end
end

local function registerIntegration()
  if eventFrame then return end

  eventFrame = CreateFrame("Frame", "AzerothCompanionEncounterJournalHost")
  eventFrame:RegisterEvent("ADDON_LOADED")
  eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
  setLockoutUpdateEventEnabled(isModuleEnabled())

  eventFrame:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" and name == "Blizzard_EncounterJournal" then
      self:UnregisterEvent("ADDON_LOADED")
      initHooks()
      refreshAfterHookInit()
      RequestRaidInfo()
    elseif event == "UPDATE_INSTANCE_INFO" then
      refreshAdventureGuideMicroButtonTooltipIfOwned()
      if isModuleEnabled() then
        RefreshScheduler:schedule("lockout_update")
      end
    elseif event == "PLAYER_ENTERING_WORLD" then
      self:UnregisterEvent("PLAYER_ENTERING_WORLD")
      RequestRaidInfo()
      initHooks()
      refreshAfterHookInit()
      hookAdventureGuideMicroButtonTooltip()
    end
  end)

  -- 若 EJ 已加载，提前注销一次性 ADDON_LOADED 监听，避免常驻。
  if Runtime.IsAddOnLoaded("Blizzard_EncounterJournal") then
    eventFrame:UnregisterEvent("ADDON_LOADED")
  end

  -- 如果 EJ 已加载，立即初始化。
  if Runtime.IsAddOnLoaded("Blizzard_EncounterJournal") then
    initHooks()
    refreshAfterHookInit()
  end

  RequestRaidInfo()
end

local function exposeTestHooksIfNeeded()
  local testingEnabled = false -- 是否测试模式
  if type(Runtime.IsTesting) == "function" and Runtime.IsTesting() == true then
    testingEnabled = true
  elseif Runtime.__isTesting == true then
    testingEnabled = true
  end
  if not testingEnabled then
    return
  end

  AzerothCompanion.TestHooks = AzerothCompanion.TestHooks or {} -- 测试 hook 容器
  AzerothCompanion.TestHooks.EncounterJournal = {
    appendAdventureGuideMicroButtonLockoutLines = appendAdventureGuideMicroButtonLockoutLines,
    refreshAdventureGuideMicroButtonTooltipIfOwned = refreshAdventureGuideMicroButtonTooltipIfOwned,
    hookAdventureGuideMicroButtonTooltip = hookAdventureGuideMicroButtonTooltip,
    getEventFrame = function()
      return eventFrame
    end,
    getRefreshScheduler = function()
      return RefreshScheduler
    end,
    resetInternalState = function()
      if eventFrame and eventFrame.UnregisterEvent then
        eventFrame:UnregisterEvent("ADDON_LOADED")
        eventFrame:UnregisterEvent("PLAYER_ENTERING_WORLD")
        eventFrame:UnregisterEvent("UPDATE_INSTANCE_INFO")
      end
      eventFrame = nil
      microButtonTooltipHooked = false
      for hookName in pairs(hookState) do -- hook 状态键
        hookState[hookName] = false
      end
      detailInfoOnShowHooked = false
      RefreshScheduler:cancel()
      RefreshScheduler.token = 0
      RefreshScheduler.timer = nil
    end,
  }
end

-- ============================================================================
-- 模块注册
-- ============================================================================

AzerothCompanion.RegisterModule({
  id = MODULE_ID,
  nameKey = "MODULE_ENCOUNTER_JOURNAL",
  settingsIntroKey = "MODULE_ENCOUNTER_JOURNAL_INTRO",
  settingsOrder = 50,

  OnModuleLoad = function()
    exposeTestHooksIfNeeded()
    registerIntegration()
  end,

  OnModuleEnable = function()
    setLockoutUpdateEventEnabled(true)
    initHooks()
    refreshAfterHookInit()
    DetailEnhancer:refresh()
    DropFilter:syncDropdown()
    ListNavigationPin:updateFrames()
    if type(_G.EncounterJournal_ListInstances) == "function" then
      pcall(_G.EncounterJournal_ListInstances)
    end
  end,

  OnEnabledSettingChanged = function(enabled)
    local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
    local msgKey = enabled and "SETTINGS_MODULE_ENABLED_FMT" or "SETTINGS_MODULE_DISABLED_FMT" -- 提示键
    AzerothCompanion.API.Chat.PrintAddonMessage(string.format(localeTable[msgKey] or "%s", localeTable.MODULE_ENCOUNTER_JOURNAL or MODULE_ID))
    setLockoutUpdateEventEnabled(enabled)
    if enabled then
      RequestRaidInfo()
      DetailEnhancer:refresh()
    else
      RefreshScheduler:cancel()
      ListNavigationPin:clearInteractionState()
      LockoutOverlay:clearAllFrames()
      ListNavigationPin:clearAllFrames()
    end
    DropFilter:syncDropdown()
    if type(_G.EncounterJournal_ListInstances) == "function" then
      pcall(_G.EncounterJournal_ListInstances)
    end
  end,

  ResetToDefaultsAndRebuild = function()
    Internal.ResetEncounterJournalSettings()
    ListNavigationPin:clearInteractionState()
    DetailEnhancer:refresh()
    DropFilter:syncDropdown()
    ListNavigationPin:updateFrames()
    if type(_G.EncounterJournal_ListInstances) == "function" then
      pcall(_G.EncounterJournal_ListInstances)
    end
  end,

  RegisterSettings = function(box)
    local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
    box:AddMultiSelectRow({
      label = localeTable.EJ_DROP_FILTER_TYPE_LABEL or "掉落类型",
      description = localeTable.EJ_DROP_FILTER_TYPE_HINT or "",
      options = {
        { value = "mount", label = localeTable.EJ_DROP_FILTER_TYPE_MOUNT or "mount" },
        { value = "pet", label = localeTable.EJ_DROP_FILTER_TYPE_PET or "pet" },
        { value = "recipe", label = localeTable.EJ_DROP_FILTER_TYPE_RECIPE or "recipe" },
        { value = "housing_decoration", label = localeTable.EJ_DROP_FILTER_TYPE_HOUSING_DECORATION or "housing decoration" },
      },
      isSelected = function(value)
        return Internal.IsDropFilterTypeSelected(value)
      end,
      setSelected = function(value, isSelected)
        Internal.SetDropFilterTypeSelected(value, isSelected == true)
      end,
      afterChange = function()
        DropFilter:syncDropdown()
        refreshAfterHookInit()
      end,
    })
    box:AddMultiSelectRow({
      label = localeTable.EJ_DROP_FILTER_OWNERSHIP_LABEL or "获取状态",
      description = localeTable.EJ_DROP_FILTER_OWNERSHIP_HINT or "",
      options = {
        { value = "collected", label = localeTable.EJ_DROP_FILTER_OWNERSHIP_COLLECTED or "collected" },
        { value = "uncollected", label = localeTable.EJ_DROP_FILTER_OWNERSHIP_UNCOLLECTED or "uncollected" },
      },
      isSelected = function(value)
        local ownership = Internal.GetDropFilterOwnership() -- 当前获取状态
        return ownership == "all" or ownership == value
      end,
      setSelected = function(value, isSelected)
        local ownership = Internal.GetDropFilterOwnership() -- 当前获取状态
        local selectedCollected = ownership == "all" or ownership == "collected" -- 已获取勾选状态
        local selectedUncollected = ownership == "all" or ownership == "uncollected" -- 未获取勾选状态
        if value == "collected" then
          selectedCollected = isSelected == true
        elseif value == "uncollected" then
          selectedUncollected = isSelected == true
        end
        if selectedCollected == true and selectedUncollected ~= true then
          Internal.SetDropFilterOwnership("collected")
        elseif selectedUncollected == true and selectedCollected ~= true then
          Internal.SetDropFilterOwnership("uncollected")
        else
          Internal.SetDropFilterOwnership("all")
        end
      end,
      afterChange = function()
        DropFilter:syncDropdown()
        refreshAfterHookInit()
      end,
    })
    box:AddToggleRow({
      label = localeTable.EJ_LIST_PIN_ALWAYS_VISIBLE_LABEL or "定位图标常驻显示",
      getValue = function()
        return Internal.GetAccountSetting("ENCOUNTER_JOURNAL_LIST_PIN_ALWAYS_VISIBLE", false) == true
      end,
      setValue = function(value)
        Internal.SetAccountSetting("ENCOUNTER_JOURNAL_LIST_PIN_ALWAYS_VISIBLE", value == true)
      end,
      afterChange = function()
        ListNavigationPin:updateFrames()
      end,
    })
  end,
})
