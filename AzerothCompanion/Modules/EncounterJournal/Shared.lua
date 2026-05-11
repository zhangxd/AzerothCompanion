--[[
  冒险指南内部共享状态（encounter_journal）。
  仅供 Modules/EncounterJournal/*.lua 私有实现文件复用，不作为对外 API。
]]

AzerothCompanion.Modules.EncounterJournal = AzerothCompanion.Modules.EncounterJournal or {}
AzerothCompanion.Modules.EncounterJournal.Internal = AzerothCompanion.Modules.EncounterJournal.Internal or {}

local Internal = AzerothCompanion.Modules.EncounterJournal.Internal -- 冒险指南内部命名空间
local MODULE_ID = "encounter_journal" -- 模块 ID
local ACCOUNT_SCOPE = "account" -- 账号级设置 scope

Internal.MODULE_ID = MODULE_ID
Internal.Runtime = AzerothCompanion.Runtime
Internal.CreateFrame = Internal.Runtime.CreateFrame
Internal.microTooltipAppendState = Internal.microTooltipAppendState or setmetatable({}, { __mode = "k" })
Internal.scrollBoxCache = Internal.scrollBoxCache or {
  ref = nil,
  lastUpdate = 0,
  ttl = 5,
}
Internal.listNavigationState = Internal.listNavigationState or {
  hoveredJournalInstanceID = nil,
}

--- 读取冒险手册账号级设置。
---@param settingName string SettingId 字段名
---@param fallbackValue any 兜底值
---@return any
function Internal.GetAccountSetting(settingName, fallbackValue)
  AzerothCompanion.Config.Init()
  local settingId = AzerothCompanion.Config.SettingId[settingName] -- 数字设置 ID
  local settingValue = AzerothCompanion.Config.Get(settingId, ACCOUNT_SCOPE) -- 当前设置值
  if settingValue ~= nil then
    return settingValue
  end
  return fallbackValue
end

--- 写入冒险手册账号级设置。
---@param settingName string SettingId 字段名
---@param settingValue any 设置值
---@return boolean
function Internal.SetAccountSetting(settingName, settingValue)
  AzerothCompanion.Config.Init()
  local settingId = AzerothCompanion.Config.SettingId[settingName] -- 数字设置 ID
  return AzerothCompanion.Config.Set(settingId, ACCOUNT_SCOPE, settingValue)
end

--- 恢复冒险手册模块默认设置。
function Internal.ResetEncounterJournalSettings()
  AzerothCompanion.Config.Init()
  local settingId = AzerothCompanion.Config.SettingId -- 数字设置 ID 表
  AzerothCompanion.Config.Reset(settingId.ENCOUNTER_JOURNAL_ENABLED, ACCOUNT_SCOPE)
  AzerothCompanion.Config.Reset(settingId.ENCOUNTER_JOURNAL_DEBUG, ACCOUNT_SCOPE)
  AzerothCompanion.Config.Reset(settingId.ENCOUNTER_JOURNAL_MOUNT_FILTER_ENABLED, ACCOUNT_SCOPE)
  AzerothCompanion.Config.Reset(settingId.ENCOUNTER_JOURNAL_LIST_PIN_ALWAYS_VISIBLE, ACCOUNT_SCOPE)
end

--- 检查模块是否启用。
---@return boolean
function Internal.IsModuleEnabled()
  return Internal.GetAccountSetting("ENCOUNTER_JOURNAL_ENABLED", true) ~= false
end

--- 检查列表“仅坐骑”筛选是否启用。
---@return boolean
function Internal.IsMountFilterChecked()
  return Internal.GetAccountSetting("ENCOUNTER_JOURNAL_MOUNT_FILTER_ENABLED", true) == true
end

--- 检查列表锁定叠加当前是否可运行。
---@return boolean
function Internal.IsOverlayEnabled()
  return Internal.IsModuleEnabled()
end

--- 检查副本列表图钉是否常驻显示。
---@return boolean
function Internal.IsListPinAlwaysVisible()
  return Internal.IsModuleEnabled() and Internal.GetAccountSetting("ENCOUNTER_JOURNAL_LIST_PIN_ALWAYS_VISIBLE", false) == true
end

--- 格式化重置时间。
---@param seconds number
---@return string
function Internal.FormatResetTime(seconds)
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  local days = math.floor(seconds / 86400)
  local hours = math.floor((seconds % 86400) / 3600)
  local mins = math.floor((seconds % 3600) / 60)
  if days > 0 then
    return string.format(localeTable.EJ_LOCKOUT_TIME_DAY_HOUR_FMT or "%dd %dh", days, hours)
  elseif hours > 0 then
    return string.format(localeTable.EJ_LOCKOUT_TIME_HOUR_MIN_FMT or "%dh %dm", hours, mins)
  end
  return string.format(localeTable.EJ_LOCKOUT_TIME_MIN_FMT or "%dm", mins)
end

--- 从 elementData 提取 journalInstanceID。
---@param elementData table|nil
---@return number|nil
function Internal.GetJournalInstanceID(elementData)
  if type(elementData) ~= "table" then
    return nil
  end
  local instId = elementData.instanceID or elementData.journalInstanceID -- 当前实例 ID
  if type(instId) == "number" then
    return instId
  end
  local nested = elementData.data or elementData.elementData or elementData.node -- 嵌套节点数据
  if type(nested) == "table" and nested ~= elementData then
    local nestedId = nested.instanceID or nested.journalInstanceID -- 嵌套实例 ID
    if type(nestedId) == "number" then
      return nestedId
    end
  end
  return nil
end

--- 读取当前 ScrollBox。
---@return table|nil
function Internal.GetCurrentScrollBox()
  local cache = Internal.scrollBoxCache -- ScrollBox 缓存
  local currentTime = GetTime()
  if cache.ref and (currentTime - cache.lastUpdate) < cache.ttl then
    return cache.ref
  end
  local journalFrame = _G.EncounterJournal -- 冒险手册根面板
  if journalFrame and journalFrame.instanceSelect then
    cache.ref = journalFrame.instanceSelect.ScrollBox or journalFrame.instanceSelect.scrollBox
    cache.lastUpdate = currentTime
  end
  return cache.ref
end

--- 清空 ScrollBox 缓存。
function Internal.ResetScrollBoxCache()
  Internal.scrollBoxCache.ref = nil
  Internal.scrollBoxCache.lastUpdate = 0
end

--- 读取当前列表交互状态。
---@return table
function Internal.GetListNavigationState()
  return Internal.listNavigationState
end

--- 清空当前列表交互状态。
function Internal.ResetListNavigationState()
  Internal.listNavigationState.hoveredJournalInstanceID = nil
end

--- 获取详情信息面板。
---@return table|nil
function Internal.GetEncounterInfoFrame()
  local journalFrame = _G.EncounterJournal -- 冒险手册根面板
  local encounterFrame = journalFrame and journalFrame.encounter -- 首领详情面板
  return encounterFrame and encounterFrame.info or nil
end
