--[[
  模块 chat：加载完成聊天提示、输出颜色与「复制默认聊天框最近内容」等聊天相关设置。
  输出与复制经 Core/API/ChatAPI.lua（AzerothCompanion.API.Chat）；设置页公共区负责启用/调试，页头负责恢复默认。
]]

AzerothCompanion.Modules = AzerothCompanion.Modules or {}
AzerothCompanion.Modules.Chat = AzerothCompanion.Modules.Chat or {}

local MODULE_ID = "chat"
local ACCOUNT_SCOPE = "account" -- 账号级设置 scope

--- 读取聊天提示账号级设置。
---@param settingName string SettingId 字段名
---@param fallbackValue any 兜底值
---@return any
local function getAccountSetting(settingName, fallbackValue)
  AzerothCompanion.Config.Init()
  local settingId = AzerothCompanion.Config.SettingId[settingName] -- 数字设置 ID
  local settingValue = AzerothCompanion.Config.Get(settingId, ACCOUNT_SCOPE) -- 当前设置值
  if settingValue ~= nil then
    return settingValue
  end
  return fallbackValue
end

--- 写入聊天提示账号级设置。
---@param settingName string SettingId 字段名
---@param settingValue any 设置值
local function setAccountSetting(settingName, settingValue)
  AzerothCompanion.Config.Set(AzerothCompanion.Config.SettingId[settingName], ACCOUNT_SCOPE, settingValue)
end

--- 恢复聊天设置默认值。
local function resetChatSettings()
  local settingId = AzerothCompanion.Config.SettingId -- 数字设置 ID 表
  AzerothCompanion.Config.Reset(settingId.CHAT_ENABLED, ACCOUNT_SCOPE)
  AzerothCompanion.Config.Reset(settingId.CHAT_DEBUG, ACCOUNT_SCOPE)
  AzerothCompanion.Config.Reset(settingId.CHAT_PREFIX_COLOR, ACCOUNT_SCOPE)
  AzerothCompanion.Config.Reset(settingId.CHAT_CONTENT_COLOR, ACCOUNT_SCOPE)
end

local function isDebugEnabled()
  return getAccountSetting("CHAT_DEBUG", false) == true
end

local function debugPrint(message)
  if not isDebugEnabled() or not message or message == "" then
    return
  end
  AzerothCompanion.API.Chat.PrintAddonMessage(message)
end

local function shouldPrint()
  return getAccountSetting("CHAT_ENABLED", true) ~= false
end

--- 根据当前模块开关输出加载完成提示。
function AzerothCompanion.Modules.Chat.PrintLoadComplete()
  AzerothCompanion_NamespaceEnsure()
  local localeTable = AzerothCompanion.Localization.Strings or {}
  if not shouldPrint() then
    debugPrint(localeTable.CHAT_DEBUG_SKIP or "")
    return
  end
  local body = localeTable.LOAD_COMPLETE_MSG or AzerothCompanion.ADDON_DISPLAY_NAME or "AzerothCompanion" -- 加载完成正文
  local ver = AzerothCompanion.API.Chat.GetAddOnMetadata(AzerothCompanion.ADDON_NAME, "Version")
  if ver and ver ~= "" then
    local cc = getAccountSetting("CHAT_CONTENT_COLOR", "ffffff")
    body = body .. string.format("  |cff%sv%s|r", cc, ver)
  end
  AzerothCompanion.API.Chat.PrintAddonMessage(body)
  debugPrint(string.format(localeTable.CHAT_DEBUG_PRINT_FMT or "%s", tostring(ver or "")))
end

AzerothCompanion.RegisterModule({
  id = MODULE_ID,
  nameKey = "MODULE_CHAT",
  settingsIntroKey = "MODULE_CHAT_INTRO",
  settingsOrder = 10,
  OnModuleLoad = function() end,
  OnModuleEnable = function() end,
  OnEnabledSettingChanged = function(enabled)
    local localeTable = AzerothCompanion.Localization.Strings or {}
    local title = localeTable.MODULE_CHAT or MODULE_ID
    local key = enabled and "SETTINGS_MODULE_ENABLED_FMT" or "SETTINGS_MODULE_DISABLED_FMT"
    AzerothCompanion.API.Chat.PrintAddonMessage(string.format(localeTable[key] or "%s", title))
  end,
  OnDebugSettingChanged = function(enabled)
    local localeTable = AzerothCompanion.Localization.Strings or {}
    local title = localeTable.MODULE_CHAT or MODULE_ID
    local key = enabled and "SETTINGS_MODULE_DEBUG_ON_FMT" or "SETTINGS_MODULE_DEBUG_OFF_FMT"
    AzerothCompanion.API.Chat.PrintAddonMessage(string.format(localeTable[key] or "%s", title))
  end,
  ResetToDefaultsAndRebuild = function()
    resetChatSettings()
  end,
  RegisterSettings = function(box)
    local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案

    -- 与 Core/API/ChatAPI.PrintAddonMessage、存档 prefixColor / contentColor 一致
    local colors = {
      { nameKey = "CHAT_COLOR_GREEN", color = "00ff00" },
      { nameKey = "CHAT_COLOR_GOLD", color = "ffd700" },
      { nameKey = "CHAT_COLOR_ORANGE", color = "ffaa00" },
      { nameKey = "CHAT_COLOR_BLUE", color = "00aaff" },
      { nameKey = "CHAT_COLOR_PURPLE", color = "cc88ff" },
      { nameKey = "CHAT_COLOR_WHITE", color = "ffffff" },
    } -- 可选颜色列表

    local function labelForHex(hex)
      for _, c in ipairs(colors) do
        if c.color == hex then
          return localeTable[c.nameKey] or c.nameKey
        end
      end
      return hex
    end

    local function menuTextForHex(hex)
      return string.format("|cff%s%s|r", hex, labelForHex(hex))
    end

    local function buildColorOptions()
      local optionList = {} -- box helper 菜单项
      for _, colorInfo in ipairs(colors) do
        optionList[#optionList + 1] = {
          value = colorInfo.color,
          label = menuTextForHex(colorInfo.color),
        }
      end
      return optionList
    end

    ---@param settingName string SettingId 字段名
    ---@param defaultHex string 缺省或非法存档时的十六进制色（无 |cff）
    ---@param labelKey string 本地化标签键
    local function addColorMenuRow(settingName, defaultHex, labelKey)
      box:AddMenuRow({
        label = localeTable[labelKey] or labelKey,
        options = buildColorOptions(),
        defaultValue = defaultHex,
        buttonWidth = 240,
        getValue = function()
          local storedHex = getAccountSetting(settingName, defaultHex) -- 当前存档色值
          if type(storedHex) ~= "string" or storedHex == "" then
            return defaultHex
          end
          return storedHex
        end,
        setValue = function(value)
          setAccountSetting(settingName, value)
        end,
      })
    end

    box:AddActionRow({
      label = localeTable.CHAT_COPY_SECTION or "",
      description = localeTable.CHAT_COPY_HINT or "",
      buttonText = localeTable.CHAT_COPY_BUTTON or "",
      buttonWidth = 200,
      onClick = function()
        local success, resultKey = AzerothCompanion.API.Chat.CopyDefaultChatToClipboard(30) -- 复制最近聊天结果
        local latestLocaleTable = AzerothCompanion.Localization.Strings or {} -- 点击时最新本地化文案
        if success then
          if resultKey == "CHAT_COPY_SUCCESS" then
            AzerothCompanion.API.Chat.PrintAddonMessage(latestLocaleTable.CHAT_COPY_DONE or "")
          elseif resultKey == "CHAT_COPY_FALLBACK" then
            AzerothCompanion.API.Chat.PrintAddonMessage(latestLocaleTable.CHAT_COPY_FALLBACK_MESSAGE or "")
          end
          return
        end
        AzerothCompanion.API.Chat.PrintAddonMessage(latestLocaleTable[resultKey or "CHAT_COPY_ERR_FAILED"] or "")
      end,
    })
    box:AddNoteRow({
      text = localeTable.CHAT_COLORS_SECTION or "",
      fontObject = "GameFontNormal",
      gap = 8,
    })
    addColorMenuRow("CHAT_PREFIX_COLOR", "ffd700", "CHAT_PREFIX_COLOR_LABEL")
    addColorMenuRow("CHAT_CONTENT_COLOR", "ffffff", "CHAT_CONTENT_COLOR_LABEL")
  end,
})
