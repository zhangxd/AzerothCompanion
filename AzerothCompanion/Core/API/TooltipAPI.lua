--[[
  提示框（领域对外 API）（AzerothCompanion.API.Tooltip）：统一管理默认 tooltip 锚点接管。
  配置读取 tooltip_anchor 数字设置 ID；业务模块 tooltip_anchor 仅负责 RegisterModule 与设置 UI。
  当前实现保留 GameTooltip_SetDefaultAnchor 全局 post-hook，但避免二次 SetOwner 污染后续 tooltip 内容链。
]]

AzerothCompanion.API.Tooltip = AzerothCompanion.API.Tooltip or {}

local MODULE_ID = "tooltip_anchor"
local ACCOUNT_SCOPE = "account" -- 账号级设置 scope

local anchorOverrideSkipState = setmetatable({}, { __mode = "k" }) -- tooltip 私有跳过标记表
local defaultAnchorHookInstalled = false -- 默认锚点 hook 是否已安装
local followDriverFrame = nil -- follow 模式每帧重锚驱动
local activeTooltip = nil -- 最近一次被本 API 接管的 tooltip

--- 读取提示框账号级设置。
---@param settingName string SettingId 字段名
---@param fallbackValue any 兜底值
---@return any
local function getTooltipSetting(settingName, fallbackValue)
  AzerothCompanion_NamespaceEnsure()
  local configTable = AzerothCompanion.Config or nil -- 配置入口
  local settingIdTable = configTable and configTable.SettingId or nil -- 设置 ID 表
  local settingId = type(settingIdTable) == "table" and settingIdTable[settingName] or nil -- 数字设置 ID
  if type(configTable) == "table" and type(configTable.Get) == "function" and settingId then
    local settingValue = configTable.Get(settingId, ACCOUNT_SCOPE) -- 当前设置值
    if settingValue ~= nil then
      return settingValue
    end
  end
  return fallbackValue
end

local function isDebugEnabled()
  return getTooltipSetting("TOOLTIP_DEBUG", false) == true
end

local function debugPrint(message)
  if not isDebugEnabled() or not message or message == "" then
    return
  end
  if AzerothCompanion.API and AzerothCompanion.API.Chat and AzerothCompanion.API.Chat.PrintAddonMessage then
    AzerothCompanion.API.Chat.PrintAddonMessage(message)
  end
end

-- 判断 tooltip 是否正在淡出；淡出期间 IsShown() 仍可能为 true，不应继续跟随重锚。
local function isTooltipFadingOut(tooltip)
  if type(tooltip) ~= "table" then
    return false
  end
  if tooltip.fadeOut == true then
    return true
  end
  if tooltip.mode == "OUT" then
    return true
  end
  return false
end

-- 判断 tooltip 当前是否显示。
local function isTooltipShown(tooltip)
  if type(tooltip) ~= "table" then
    return false
  end
  if isTooltipFadingOut(tooltip) then
    return false
  end
  if type(tooltip.IsShown) == "function" then
    return tooltip:IsShown() == true
  end
  return true
end

-- 判断当前默认锚点 hook 是否应接管此 tooltip。
local function shouldOverrideDefaultAnchor(tooltip)
  local isEnabled = getTooltipSetting("TOOLTIP_ENABLED", true) ~= false -- tooltip 模块是否启用
  local mode = getTooltipSetting("TOOLTIP_MODE", "cursor") -- 当前锚点模式
  if not isEnabled then
    return false
  end
  if mode ~= "cursor" and mode ~= "follow" then
    return false
  end
  if AzerothCompanion.API.Tooltip.ShouldSkipAnchorOverride(tooltip) then
    return false
  end
  return true
end

-- 取得当前可重锚的可见 tooltip，优先沿用最近一次 hook 接管对象。
local function getVisibleOverrideTooltip()
  if isTooltipShown(activeTooltip) and shouldOverrideDefaultAnchor(activeTooltip) then
    return activeTooltip
  end
  if isTooltipShown(GameTooltip) and shouldOverrideDefaultAnchor(GameTooltip) then
    return GameTooltip
  end
  return nil
end

-- 读取缩放后的鼠标 UI 坐标，用于 SetPoint 重锚。
local function getCursorUiPosition()
  if type(GetCursorPosition) ~= "function" then
    return 0, 0
  end

  local cursorX, cursorY = GetCursorPosition() -- 当前鼠标屏幕坐标
  local effectiveScale = 1 -- UIParent 当前有效缩放
  if UIParent and type(UIParent.GetEffectiveScale) == "function" then
    effectiveScale = tonumber(UIParent:GetEffectiveScale()) or 1
  end
  if effectiveScale <= 0 then
    effectiveScale = 1
  end

  return (tonumber(cursorX) or 0) / effectiveScale, (tonumber(cursorY) or 0) / effectiveScale
end

-- 将 tooltip 重锚到鼠标附近；不调用 SetOwner，避免重建 tooltip owner。
local function applyCursorAnchorOverride(tooltip, shouldResetAnchorType)
  if type(tooltip) ~= "table" or type(tooltip.SetPoint) ~= "function" then
    return
  end

  local offsetX = tonumber(getTooltipSetting("TOOLTIP_OFFSET_X", 0)) or 0 -- X 偏移
  local offsetY = tonumber(getTooltipSetting("TOOLTIP_OFFSET_Y", 0)) or 0 -- Y 偏移
  local cursorX, cursorY = getCursorUiPosition() -- 缩放后的鼠标坐标

  -- 暴雪原始 GameTooltip_SetDefaultAnchor 已经设置过 owner；这里仅重锚，不再二次 SetOwner。
  if shouldResetAnchorType ~= false and type(tooltip.SetAnchorType) == "function" then
    local setAnchorTypeSuccess = pcall(tooltip.SetAnchorType, tooltip, "ANCHOR_NONE") -- SetAnchorType 版本兼容结果
    if not setAnchorTypeSuccess then
      debugPrint("[SetDefaultAnchor] SetAnchorType failed")
    end
  end

  if type(tooltip.ClearAllPoints) == "function" then
    tooltip:ClearAllPoints()
  end
  tooltip:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", cursorX + offsetX, cursorY + offsetY)
  activeTooltip = tooltip
end

-- 对当前可见 tooltip 立即应用一次锚点，供设置切换后即时生效。
local function applyVisibleTooltipAnchor()
  local tooltip = getVisibleOverrideTooltip() -- 当前可接管 tooltip
  if tooltip then
    applyCursorAnchorOverride(tooltip, true)
  end
end

-- follow 模式每帧重锚已显示 tooltip，避免只在默认锚点 hook 时生效一次。
local function updateFollowTooltipAnchor()
  local tooltip = getVisibleOverrideTooltip() -- 当前可接管 tooltip
  if tooltip then
    applyCursorAnchorOverride(tooltip, false)
  end
end

-- 开关 follow 模式驱动；非 follow 时必须清掉 OnUpdate。
local function setFollowDriverEnabled(enabled)
  if enabled then
    if not followDriverFrame then
      followDriverFrame = CreateFrame("Frame", nil, UIParent)
    end
    followDriverFrame:SetScript("OnUpdate", function()
      updateFollowTooltipAnchor()
    end)
  elseif followDriverFrame then
    followDriverFrame:SetScript("OnUpdate", nil)
  end
end

function AzerothCompanion.API.Tooltip.RefreshDriver()
  local isEnabled = getTooltipSetting("TOOLTIP_ENABLED", true) ~= false -- tooltip 模块是否启用
  local mode = getTooltipSetting("TOOLTIP_MODE", "cursor") -- 当前锚点模式
  local offsetX = getTooltipSetting("TOOLTIP_OFFSET_X", 0) -- X 偏移
  local offsetY = getTooltipSetting("TOOLTIP_OFFSET_Y", 0) -- Y 偏移
  if not isEnabled or mode == "default" then
    setFollowDriverEnabled(false)
    activeTooltip = nil
    debugPrint((AzerothCompanion.Localization.Strings or {}).TOOLTIP_DEBUG_DRIVER_OFF or "")
    return
  end

  setFollowDriverEnabled(mode == "follow")
  applyVisibleTooltipAnchor()

  debugPrint(string.format(
    ((AzerothCompanion.Localization.Strings or {}).TOOLTIP_DEBUG_DRIVER_ON_FMT or "mode=%s offsetX=%s offsetY=%s"),
    tostring(mode or "default"),
    tostring(offsetX or 0),
    tostring(offsetY or 0)
  ))
end

--- 设置是否跳过默认锚点接管。
---@param tooltip table|nil
---@param shouldSkip boolean
function AzerothCompanion.API.Tooltip.SetSkipAnchorOverride(tooltip, shouldSkip)
  if type(tooltip) ~= "table" then
    return
  end
  if shouldSkip then
    anchorOverrideSkipState[tooltip] = true
  else
    anchorOverrideSkipState[tooltip] = nil
  end
end

--- 判断 tooltip 是否应跳过默认锚点接管。
---@param tooltip table|nil
---@return boolean
function AzerothCompanion.API.Tooltip.ShouldSkipAnchorOverride(tooltip)
  return type(tooltip) == "table" and anchorOverrideSkipState[tooltip] == true or false
end

function AzerothCompanion.API.Tooltip.InstallDefaultAnchorHook()
  if defaultAnchorHookInstalled then
    return
  end

  hooksecurefunc("GameTooltip_SetDefaultAnchor", function(tooltip)
    if not shouldOverrideDefaultAnchor(tooltip) then
      return
    end
    applyCursorAnchorOverride(tooltip, true)
  end)

  defaultAnchorHookInstalled = true
end
