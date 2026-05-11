--[[
  模块 navigation：世界地图目标导航与跨地图路径规划。
  当前文件只负责模块注册、设置页与开关回调；路径算法在 Core/API/NavigationAPI.lua。
]]

local MODULE_ID = "navigation"
local ACCOUNT_SCOPE = "account" -- 账号级设置 scope
local CHARACTER_SCOPE = "character" -- 角色级设置 scope

local RESET_SETTING_LIST = {
  { name = "NAVIGATION_ENABLED", scope = ACCOUNT_SCOPE },
  { name = "NAVIGATION_DEBUG", scope = ACCOUNT_SCOPE },
  { name = "NAVIGATION_ROUTE_WIDGET_EXPANDED", scope = ACCOUNT_SCOPE },
  { name = "NAVIGATION_ROUTE_HISTORY_EXPANDED", scope = ACCOUNT_SCOPE },
  { name = "NAVIGATION_ROUTE_WIDGET_POSITION", scope = ACCOUNT_SCOPE },
  { name = "NAVIGATION_ROUTE_HISTORY", scope = CHARACTER_SCOPE },
} -- navigation 模块恢复默认设置项

--- 安装世界地图入口。
local function installWorldMapEntry()
  local worldMap = AzerothCompanion.Modules.Navigation and AzerothCompanion.Modules.Navigation.WorldMap or nil -- 世界地图入口模块
  if worldMap and type(worldMap.Install) == "function" then
    worldMap.Install()
  end
end

--- 隐藏 navigation 创建的玩家可见 UI。
local function hideNavigationUi()
  local navigationModule = AzerothCompanion.Modules.Navigation or {} -- navigation 模块内部命名空间
  local worldMap = navigationModule.WorldMap -- 世界地图入口模块
  local routeBar = navigationModule.RouteBar -- 顶部路径条模块
  if worldMap and type(worldMap.Hide) == "function" then
    worldMap.Hide()
  end
  if routeBar and type(routeBar.ClearRoute) == "function" then
    routeBar.ClearRoute()
  end
end

--- 按数字设置 ID 恢复 navigation 模块默认值。
local function resetNavigationSettings()
  local configTable = AzerothCompanion.Config or nil -- 配置入口
  local settingIdTable = configTable and configTable.SettingId or nil -- 设置 ID 常量表
  if type(configTable) ~= "table" or type(configTable.Reset) ~= "function" or type(settingIdTable) ~= "table" then
    return
  end
  for _, settingInfo in ipairs(RESET_SETTING_LIST) do
    local settingId = settingIdTable[settingInfo.name] -- 当前数字设置 ID
    if settingId then
      configTable.Reset(settingId, settingInfo.scope)
    end
  end
end

AzerothCompanion.RegisterModule({
  id = MODULE_ID,
  nameKey = "MODULE_NAVIGATION",
  settingsIntroKey = "MODULE_NAVIGATION_INTRO",
  settingsOrder = 70,
  OnModuleEnable = function()
    installWorldMapEntry()
  end,
  OnEnabledSettingChanged = function(enabled)
    local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化字符串表
    local title = localeTable.MODULE_NAVIGATION or MODULE_ID -- 模块显示名
    local key = enabled and "SETTINGS_MODULE_ENABLED_FMT" or "SETTINGS_MODULE_DISABLED_FMT" -- 状态文案键
    if AzerothCompanion.API and AzerothCompanion.API.Chat and AzerothCompanion.API.Chat.PrintAddonMessage then
      AzerothCompanion.API.Chat.PrintAddonMessage(string.format(localeTable[key] or "%s", title))
    end
    if enabled then
      installWorldMapEntry()
    else
      hideNavigationUi()
    end
  end,
  OnDebugSettingChanged = function(enabled)
    local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化字符串表
    local title = localeTable.MODULE_NAVIGATION or MODULE_ID -- 模块显示名
    local key = enabled and "SETTINGS_MODULE_DEBUG_ON_FMT" or "SETTINGS_MODULE_DEBUG_OFF_FMT" -- 调试文案键
    if AzerothCompanion.API and AzerothCompanion.API.Chat and AzerothCompanion.API.Chat.PrintAddonMessage then
      AzerothCompanion.API.Chat.PrintAddonMessage(string.format(localeTable[key] or "%s", title))
    end
  end,
  ResetToDefaultsAndRebuild = function()
    resetNavigationSettings()
  end,
  RegisterSettings = function(box)
    -- 地图页承载小地图玩家坐标设置；具体存档和刷新仍由 MinimapButton 模块维护。
    if AzerothCompanion.Modules.MinimapButton and type(AzerothCompanion.Modules.MinimapButton.RegisterCoordinateSettings) == "function" then
      AzerothCompanion.Modules.MinimapButton.RegisterCoordinateSettings(box)
    end
  end,
})
