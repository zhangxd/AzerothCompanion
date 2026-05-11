--[[
  AzerothCompanion — 根命名空间（须最先加载）。
  使用独立全局 AzerothCompanionAddon 存根；若其它脚本覆盖 _G.AzerothCompanion，仍可通过 AzerothCompanionAddon 与 AzerothCompanion_NamespaceEnsure 恢复。
  插件技术标识与玩家显示名统一在本文件定义，后续改名时先从这里收口。
]]

local ADDON_NAME = "AzerothCompanion" -- 插件目录 / TOC 技术名
local ADDON_DISPLAY_NAME_ENUS = "AzerothCompanion" -- 英文设置类目显示名
local ADDON_DISPLAY_NAME_ZHCN = "艾泽拉斯助手" -- 中文设置类目显示名
local ADDON_BRAND_NAME_ENUS = "AzerothCompanion" -- 英文品牌文本
local ADDON_BRAND_NAME_ZHCN = "艾泽拉斯助手" -- 中文文案中的品牌文本
local ADDON_SAVED_VARIABLES_NAME = "AzerothCompanionDB" -- 账号级 SavedVariables 名称
local ADDON_CHARACTER_SAVED_VARIABLES_NAME = "AzerothCompanionDBChar" -- 角色级 SavedVariables 名称
local ADDON_GLOBAL_NAME = "AzerothCompanion" -- 公开全局命名空间
local ADDON_STUB_GLOBAL_NAME = "AzerothCompanionAddon" -- 命名空间恢复用存根全局
local ADDON_SLASH_TOKEN = "AZEROTHCOMPANION" -- SlashCmdList 使用的命令槽名
local ADDON_SLASH_COMMAND = "/azerothcompanion" -- 玩家可见 slash 命令
local ADDON_LOG_PREFIX = "[AzerothCompanion]" -- print 诊断前缀

-- 使用更安全的初始化方式：检查现有全局变量是否为本插件所有
local addonStub = _G[ADDON_STUB_GLOBAL_NAME] -- 命名空间存根
if not addonStub or type(addonStub) ~= "table" or addonStub.ADDON_NAME ~= ADDON_NAME then
  addonStub = { ADDON_NAME = ADDON_NAME }
  _G[ADDON_STUB_GLOBAL_NAME] = addonStub
end

AzerothCompanion = addonStub
AzerothCompanion.ADDON_NAME = ADDON_NAME
AzerothCompanion.ADDON_DISPLAY_NAME = ADDON_DISPLAY_NAME_ENUS
AzerothCompanion.ADDON_DISPLAY_NAME_ENUS = ADDON_DISPLAY_NAME_ENUS
AzerothCompanion.ADDON_DISPLAY_NAME_ZHCN = ADDON_DISPLAY_NAME_ZHCN
AzerothCompanion.ADDON_BRAND_NAME_ENUS = ADDON_BRAND_NAME_ENUS
AzerothCompanion.ADDON_BRAND_NAME_ZHCN = ADDON_BRAND_NAME_ZHCN
AzerothCompanion.ADDON_SAVED_VARIABLES_NAME = ADDON_SAVED_VARIABLES_NAME
AzerothCompanion.ADDON_CHARACTER_SAVED_VARIABLES_NAME = ADDON_CHARACTER_SAVED_VARIABLES_NAME
AzerothCompanion.ADDON_GLOBAL_NAME = ADDON_GLOBAL_NAME
AzerothCompanion.ADDON_STUB_GLOBAL_NAME = ADDON_STUB_GLOBAL_NAME
AzerothCompanion.ADDON_SLASH_TOKEN = ADDON_SLASH_TOKEN
AzerothCompanion.ADDON_SLASH_COMMAND = ADDON_SLASH_COMMAND
AzerothCompanion.ADDON_LOG_PREFIX = ADDON_LOG_PREFIX
AzerothCompanion.API = AzerothCompanion.API or {}
AzerothCompanion.Modules = AzerothCompanion.Modules or {}
AzerothCompanion.Localization = AzerothCompanion.Localization or {}
AzerothCompanion.Config = AzerothCompanion.Config or {}
_G.AzerothCompanion = AzerothCompanion

-- 在事件/回调入口调用，将 _G.AzerothCompanion 指回本插件
function AzerothCompanion_NamespaceEnsure()
  local azerothCompanionStub = _G[ADDON_STUB_GLOBAL_NAME] -- 命名空间存根
  if azerothCompanionStub and type(azerothCompanionStub) == "table" and azerothCompanionStub.ADDON_NAME == ADDON_NAME then
    _G.AzerothCompanion = azerothCompanionStub
  end
end
