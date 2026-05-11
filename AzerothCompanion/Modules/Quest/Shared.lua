--[[
  quest 模块内部共享状态。
  仅供 Modules/Quest/*.lua 私有实现文件复用，不作为对外 API。
]]

AzerothCompanion.Modules.Quest = AzerothCompanion.Modules.Quest or {}
AzerothCompanion.Modules.Quest.Internal = AzerothCompanion.Modules.Quest.Internal or {}

local Internal = AzerothCompanion.Modules.Quest.Internal -- quest 模块内部命名空间
local MODULE_ID = "quest" -- 模块 ID
local ACCOUNT_SCOPE = "account" -- 账号级设置 scope
local CHARACTER_SCOPE = "character" -- 角色级设置 scope

Internal.MODULE_ID = MODULE_ID
Internal.Runtime = AzerothCompanion.Runtime
Internal.CreateFrame = Internal.Runtime.CreateFrame

--- 读取账号级 quest 设置。
---@param settingName string `AzerothCompanion.Config.SettingId` 中的设置名
---@return any
function Internal.GetAccountSetting(settingName)
  AzerothCompanion.Config.Init()
  local settingId = AzerothCompanion.Config.SettingId[settingName] -- 设置 ID
  return AzerothCompanion.Config.Get(settingId, ACCOUNT_SCOPE)
end

--- 写入账号级 quest 设置。
---@param settingName string `AzerothCompanion.Config.SettingId` 中的设置名
---@param settingValue any 设置值
---@return boolean
function Internal.SetAccountSetting(settingName, settingValue)
  AzerothCompanion.Config.Init()
  local settingId = AzerothCompanion.Config.SettingId[settingName] -- 设置 ID
  return AzerothCompanion.Config.Set(settingId, ACCOUNT_SCOPE, settingValue)
end

--- 读取角色级 quest 设置；table 返回副本，修改后必须调用 SetCharacterSetting 写回。
---@param settingName string `AzerothCompanion.Config.SettingId` 中的设置名
---@return any
function Internal.GetCharacterSetting(settingName)
  AzerothCompanion.Config.Init()
  local settingId = AzerothCompanion.Config.SettingId[settingName] -- 设置 ID
  return AzerothCompanion.Config.Get(settingId, CHARACTER_SCOPE)
end

--- 写入角色级 quest 设置。
---@param settingName string `AzerothCompanion.Config.SettingId` 中的设置名
---@param settingValue any 设置值
---@return boolean
function Internal.SetCharacterSetting(settingName, settingValue)
  AzerothCompanion.Config.Init()
  local settingId = AzerothCompanion.Config.SettingId[settingName] -- 设置 ID
  return AzerothCompanion.Config.Set(settingId, CHARACTER_SCOPE, settingValue)
end

--- 恢复 quest 模块所有设置默认值。
function Internal.ResetQuestSettings()
  AzerothCompanion.Config.Init()
  local settingId = AzerothCompanion.Config.SettingId -- 设置 ID 常量表
  local accountSettingNames = { -- 账号级 quest 设置名
    "QUEST_ENABLED",
    "QUEST_DEBUG",
    "QUESTLINE_TREE_ENABLED",
    "QUEST_RECENT_COMPLETED_MAX",
  }
  local characterSettingNames = { -- 角色级 quest 设置名
    "QUEST_NAV_EXPANSION_ID",
    "QUEST_NAV_SELECTED_CAMPAIGN_ID",
    "QUEST_NAV_SELECTED_ACHIEVEMENT_ID",
    "QUEST_NAV_MODE_KEY",
    "QUEST_NAV_SELECTED_MAP_ID",
    "QUEST_NAV_SEARCH_TEXT",
    "QUEST_INSPECTOR_LAST_QUEST_ID",
    "QUEST_RECENT_COMPLETED_LIST",
    "QUEST_NAV_EXPANDED_QUESTLINE_ID",
    "QUESTLINE_TREE_COLLAPSED",
  }

  for _, settingName in ipairs(accountSettingNames) do
    AzerothCompanion.Config.Reset(settingId[settingName], ACCOUNT_SCOPE)
  end
  for _, settingName in ipairs(characterSettingNames) do
    AzerothCompanion.Config.Reset(settingId[settingName], CHARACTER_SCOPE)
  end
end

--- 检查模块是否启用。
---@return boolean
function Internal.IsModuleEnabled()
  return Internal.GetAccountSetting("QUEST_ENABLED") ~= false
end

--- 检查任务视图是否启用。
---@return boolean
function Internal.IsQuestlineTreeEnabled()
  return Internal.IsModuleEnabled() and Internal.GetAccountSetting("QUESTLINE_TREE_ENABLED") ~= false
end
