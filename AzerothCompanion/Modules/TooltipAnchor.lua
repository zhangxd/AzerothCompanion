--[[
  模块 tooltip_anchor：提示框锚点与跟随的配置与设置 UI。
  实现见 Core/Tooltip.lua（AzerothCompanion.API.Tooltip）；本文件不直接 hook GameTooltip。
]]

local ACCOUNT_SCOPE = "account" -- 账号级设置 scope

--- 读取提示框模块账号级设置。
---@param settingName string SettingId 字段名
---@param fallbackValue any 兜底值
---@return any
local function getTooltipSetting(settingName, fallbackValue)
  local settingId = AzerothCompanion.Config.SettingId[settingName] -- 数字设置 ID
  local settingValue = AzerothCompanion.Config.Get(settingId, ACCOUNT_SCOPE) -- 当前设置值
  if settingValue ~= nil then
    return settingValue
  end
  return fallbackValue
end

--- 写入提示框模块账号级设置。
---@param settingName string SettingId 字段名
---@param settingValue any 设置值
local function setTooltipSetting(settingName, settingValue)
  AzerothCompanion.Config.Set(AzerothCompanion.Config.SettingId[settingName], ACCOUNT_SCOPE, settingValue)
end

--- 恢复提示框模块默认设置。
local function resetTooltipSettings()
  local settingId = AzerothCompanion.Config.SettingId -- 数字设置 ID 表
  AzerothCompanion.Config.Reset(settingId.TOOLTIP_ENABLED, ACCOUNT_SCOPE)
  AzerothCompanion.Config.Reset(settingId.TOOLTIP_DEBUG, ACCOUNT_SCOPE)
  AzerothCompanion.Config.Reset(settingId.TOOLTIP_MODE, ACCOUNT_SCOPE)
  AzerothCompanion.Config.Reset(settingId.TOOLTIP_OFFSET_X, ACCOUNT_SCOPE)
  AzerothCompanion.Config.Reset(settingId.TOOLTIP_OFFSET_Y, ACCOUNT_SCOPE)
end

AzerothCompanion.RegisterModule({
  id = "tooltip_anchor",
  nameKey = "MODULE_TOOLTIP",
  settingsOrder = 40,
  OnModuleLoad = function()
    AzerothCompanion.API.Tooltip.InstallDefaultAnchorHook()
    AzerothCompanion.API.Tooltip.InstallEncounterJournalTooltipHook()
  end,
  OnModuleEnable = function()
    AzerothCompanion.API.Tooltip.RefreshDriver()
  end,
  OnEnabledSettingChanged = function(enabled)
    local localeTable = AzerothCompanion.Localization.Strings or {}
    local key = enabled and "SETTINGS_MODULE_ENABLED_FMT" or "SETTINGS_MODULE_DISABLED_FMT"
    AzerothCompanion.API.Chat.PrintAddonMessage(string.format(localeTable[key] or "%s", localeTable.MODULE_TOOLTIP or "tooltip_anchor"))
    AzerothCompanion.API.Tooltip.RefreshDriver()
  end,
  OnDebugSettingChanged = function(enabled)
    local localeTable = AzerothCompanion.Localization.Strings or {}
    local key = enabled and "SETTINGS_MODULE_DEBUG_ON_FMT" or "SETTINGS_MODULE_DEBUG_OFF_FMT"
    AzerothCompanion.API.Chat.PrintAddonMessage(string.format(localeTable[key] or "%s", localeTable.MODULE_TOOLTIP or "tooltip_anchor"))
    AzerothCompanion.API.Tooltip.RefreshDriver()
  end,
  ResetToDefaultsAndRebuild = function()
    resetTooltipSettings()
    AzerothCompanion.API.Tooltip.RefreshDriver()
  end,
  RegisterSettings = function(box)
    local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案

    box:AddMenuRow({
      label = localeTable.MODULE_TOOLTIP or "tooltip_anchor",
      description = localeTable.TOOLTIP_HINT or "",
      buttonWidth = 160,
      options = {
        { value = "default", label = localeTable.TOOLTIP_MODE_DEFAULT or "default" },
        { value = "cursor", label = localeTable.TOOLTIP_MODE_CURSOR or "cursor" },
        { value = "follow", label = localeTable.TOOLTIP_MODE_FOLLOW or "follow" },
      },
      defaultValue = "default",
      getValue = function()
        if getTooltipSetting("TOOLTIP_ENABLED", true) == false then
          return "default"
        end
        return getTooltipSetting("TOOLTIP_MODE", "cursor")
      end,
      setValue = function(value)
        if value == "default" then
          setTooltipSetting("TOOLTIP_ENABLED", false)
          setTooltipSetting("TOOLTIP_MODE", "default")
        else
          setTooltipSetting("TOOLTIP_ENABLED", true)
          setTooltipSetting("TOOLTIP_MODE", value)
        end
      end,
      afterChange = function()
        AzerothCompanion.API.Tooltip.RefreshDriver()
      end,
    })
  end,
})
