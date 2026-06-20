--[[
  全球化运行时：AzerothCompanion.Localization.Strings 由 Localization.Apply() 根据存档 global.locale 与 GetLocale() 生成。
  文案包由 AzerothCompanion/Locales/*.lua 注册到 AzerothCompanion.Localization.Data。
  可选 "auto" | "zhCN" | "enUS"；新增语言时扩展语言包文件与 GetEffectiveBundleCode。
]]

local fallbackBundleCode = "zhCN" -- 默认兜底语言包代码
local cachedBundles = {} -- 已合并语言包缓存，避免重复分配

-- 取得语言包注册表；测试环境或加载顺序异常时也保持为空表可用。
local function getLocaleData()
  AzerothCompanion_NamespaceEnsure()
  AzerothCompanion.Localization = AzerothCompanion.Localization or {}
  AzerothCompanion.Localization.Data = AzerothCompanion.Localization.Data or {}
  return AzerothCompanion.Localization.Data
end

-- 游戏客户端语言 -> 本插件使用的文案包；未明确支持的客户端语言回退中文。
local function gameLocaleToBundleCode()
  local localeCode = GetLocale() -- 当前客户端语言代码
  if localeCode == "zhCN" or localeCode == "zhTW" then
    return "zhCN"
  end
  if localeCode == "enUS" then
    return "enUS"
  end
  return fallbackBundleCode
end

-- 读取账号级语言设置；Config 尚未加载时回退 auto。
local function getPreferredLocale()
  if AzerothCompanion.Config and type(AzerothCompanion.Config.Get) == "function" and AzerothCompanion.Config.SettingId then
    return AzerothCompanion.Config.Get(AzerothCompanion.Config.SettingId.GLOBAL_LOCALE, "account") or "auto"
  end
  return "auto"
end

--- 返回当前应使用的文案包代码。
---@return string bundleCode 仅 zhCN / enUS 两套表
function AzerothCompanion.Localization.GetEffectiveBundleCode()
  local preferredLocale = getPreferredLocale() -- 用户选择的语言偏好
  if preferredLocale == "auto" then
    return gameLocaleToBundleCode()
  end
  if preferredLocale == "zhCN" or preferredLocale == "enUS" then
    return preferredLocale
  end
  return fallbackBundleCode
end

--- 重建本地化字符串表；调用方请始终读 AzerothCompanion.Localization.Strings，勿缓存旧表。
function AzerothCompanion.Localization.Apply()
  AzerothCompanion_NamespaceEnsure()
  local bundleCode = AzerothCompanion.Localization.GetEffectiveBundleCode() -- 本次要应用的语言包代码

  -- 使用缓存的语言包，避免每次都重新合并
  if not cachedBundles[bundleCode] then
    local localeData = getLocaleData() -- 已加载的语言包注册表
    local fallbackBundle = localeData[fallbackBundleCode] or {} -- 中文兜底语言包
    local selectedBundle = localeData[bundleCode] or fallbackBundle -- 当前语言包，缺失时整体回退中文
    local mergedBundle = {} -- 最终暴露给调用方的文案表
    for localeKey, localeValue in pairs(fallbackBundle) do
      mergedBundle[localeKey] = localeValue
    end
    if selectedBundle ~= fallbackBundle then
      for localeKey, localeValue in pairs(selectedBundle) do
        mergedBundle[localeKey] = localeValue
      end
    end
    cachedBundles[bundleCode] = mergedBundle
  end

  AzerothCompanion.Localization.Strings = cachedBundles[bundleCode]

  if AzerothCompanion._gameMenuBtn then
    AzerothCompanion._gameMenuBtn:SetText(AzerothCompanion.Localization.Strings.GAMEMENU_AZEROTHCOMPANION)
  end
  if _G.AzerothCompanionEJDropFilterLabel and AzerothCompanion.Localization.Strings then
    _G.AzerothCompanionEJDropFilterLabel:SetText(AzerothCompanion.Localization.Strings.EJ_DROP_FILTER_LABEL or "")
  end
end

-- 占位；在 Bootstrap 中于 DB.Init() 之后调用 Localization.Apply() 填充
AzerothCompanion.Localization.Strings = {}
