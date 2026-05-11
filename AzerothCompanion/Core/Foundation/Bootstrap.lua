--[[
  插件入口：事件与斜杠。
  ADDON_LOADED：SV 已就绪，可注册 Settings、构建设置 UI（不依赖角色）。
  PLAYER_LOGIN：角色数据可用，再启用需进世界的模块（示例窗、微型菜单 Hook 等）。
  加载完成聊天提示：在本事件处理末尾调用 Modules.Chat.PrintLoadComplete()（实现见 Modules/Chat.lua，输出经 AzerothCompanion.API.Chat）。
]]

local ADDON_NAME = (AzerothCompanion and AzerothCompanion.ADDON_NAME) or "AzerothCompanion" -- 插件目录 / TOC 技术名
local ADDON_LOG_PREFIX = (AzerothCompanion and AzerothCompanion.ADDON_LOG_PREFIX) or "[AzerothCompanion]" -- 诊断输出前缀
local ADDON_SLASH_TOKEN = (AzerothCompanion and AzerothCompanion.ADDON_SLASH_TOKEN) or "AZEROTHCOMPANION" -- SlashCmdList 槽名
local ADDON_SLASH_COMMAND = (AzerothCompanion and AzerothCompanion.ADDON_SLASH_COMMAND) or "/azerothcompanion" -- 玩家可见命令

-- 辅助函数：注册斜杠命令；参数统一忽略，只负责打开设置。
local function registerSlashCommand()
  _G["SLASH_" .. ADDON_SLASH_TOKEN .. "1"] = ADDON_SLASH_COMMAND
  SlashCmdList[ADDON_SLASH_TOKEN] = function()
    AzerothCompanion_NamespaceEnsure()
    AzerothCompanion.SettingsHost:Open()
  end
end

-- 输出启动阶段错误；仅用于诊断，不进入本地化文案。
local function printBootstrapError(stepName, errorObject)
  print(ADDON_LOG_PREFIX .. " Error in " .. stepName .. ":", errorObject)
end

local frame = CreateFrame("Frame") -- 启动事件 frame
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")

frame:SetScript("OnEvent", function(_, event, addonName)
  if event == "ADDON_LOADED" and addonName == ADDON_NAME then
    AzerothCompanion_NamespaceEnsure()

    -- 初始化数据库
    local success, errorObject = pcall(AzerothCompanion.Config.Init) -- Config 初始化结果
    if not success then
      printBootstrapError("Config.Init", errorObject)
    end

    -- 应用语言包
    success, errorObject = pcall(AzerothCompanion.Localization.Apply)
    if not success then
      printBootstrapError("Localization.Apply", errorObject)
    end

    -- 运行模块加载钩子
    success, errorObject = pcall(AzerothCompanion.ModuleRegistry.RunOnModuleLoad, AzerothCompanion.ModuleRegistry)
    if not success then
      printBootstrapError("RunOnModuleLoad", errorObject)
    end

    -- 构建设置界面
    success, errorObject = pcall(AzerothCompanion.SettingsHost.Build, AzerothCompanion.SettingsHost)
    if not success then
      printBootstrapError("SettingsHost:Build", errorObject)
    end

    -- 注册小地图按钮目录
    if AzerothCompanion.Modules.MinimapButton and AzerothCompanion.Modules.MinimapButton.RegisterBuiltinFlyoutCatalog then
      success, errorObject = pcall(AzerothCompanion.Modules.MinimapButton.RegisterBuiltinFlyoutCatalog)
      if not success then
        printBootstrapError("MinimapButton.RegisterBuiltinFlyoutCatalog", errorObject)
      end
    end

    -- 初始化游戏菜单按钮
    success, errorObject = pcall(AzerothCompanion.GameMenu_Init)
    if not success then
      printBootstrapError("GameMenu_Init", errorObject)
    end

    -- 注册斜杠命令
    registerSlashCommand()

    -- 主流程末尾再通知：此时 DB、语言包、设置 UI、斜杠均已就绪；无需 C_Timer 延迟
    success, errorObject = pcall(AzerothCompanion.Modules.Chat.PrintLoadComplete)
    if not success then
      printBootstrapError("Modules.Chat.PrintLoadComplete", errorObject)
    end
  elseif event == "PLAYER_LOGIN" then
    AzerothCompanion_NamespaceEnsure()

    -- 运行模块启用钩子
    local success, errorObject = pcall(AzerothCompanion.ModuleRegistry.RunOnModuleEnable, AzerothCompanion.ModuleRegistry) -- 模块启用结果
    if not success then
      printBootstrapError("RunOnModuleEnable", errorObject)
    end

    -- GameMenu 在 ADDON_LOADED 时可能尚未加载，登录后再挂 ESC 按钮
    success, errorObject = pcall(AzerothCompanion.GameMenu_Init)
    if not success then
      printBootstrapError("GameMenu_Init (PLAYER_LOGIN)", errorObject)
    end
  end
end)
