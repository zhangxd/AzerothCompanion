--[[
  navigation 模块共享命名空间。
  子文件通过 AzerothCompanion.Modules.Navigation 访问模块 DB、启用状态与内部组件。
]]

AzerothCompanion.Modules.Navigation = AzerothCompanion.Modules.Navigation or {}

local ACCOUNT_SCOPE = "account" -- 账号级设置 scope

--- 读取 navigation 模块账号级设置。
---@param settingName string SettingId 字段名
---@param fallbackValue any 读取失败时的兜底值
---@return any
function AzerothCompanion.Modules.Navigation.GetAccountSetting(settingName, fallbackValue)
  local configTable = AzerothCompanion.Config or nil -- 配置入口
  local settingIdTable = configTable and configTable.SettingId or nil -- 设置 ID 常量表
  local settingId = type(settingIdTable) == "table" and settingIdTable[settingName] or nil -- 数字设置 ID
  if type(configTable) == "table" and type(configTable.Get) == "function" and settingId then
    local settingValue = configTable.Get(settingId, ACCOUNT_SCOPE) -- 当前设置值
    if settingValue ~= nil then
      return settingValue
    end
  end
  return fallbackValue
end

--- 判断 navigation 模块当前是否启用。
---@return boolean
function AzerothCompanion.Modules.Navigation.IsEnabled()
  return AzerothCompanion.Modules.Navigation.GetAccountSetting("NAVIGATION_ENABLED", true) ~= false
end
