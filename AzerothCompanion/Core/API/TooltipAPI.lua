--[[
  提示框（领域对外 API）（AzerothCompanion.API.Tooltip）：统一管理默认 tooltip 锚点接管。
  配置读取 tooltip_anchor 数字设置 ID；业务模块 tooltip_anchor 仅负责 RegisterModule 与设置 UI。
  当前实现保留 GameTooltip_SetDefaultAnchor 全局 post-hook，但避免二次 SetOwner 污染后续 tooltip 内容链。
]]

AzerothCompanion.API.Tooltip = AzerothCompanion.API.Tooltip or {}

local MODULE_ID = "tooltip_anchor"
local ACCOUNT_SCOPE = "account" -- 账号级设置 scope

local anchorOverrideSkipState = setmetatable({}, { __mode = "k" }) -- tooltip 私有跳过标记表
local secretFrozenTooltipState = setmetatable({}, { __mode = "k" }) -- 已进入 secret 状态后的冻结标记表
local defaultAnchorHookInstalled = false -- 默认锚点 hook 是否已安装
local encounterJournalTooltipHookInstalled = false -- 冒险指南 tooltip hook 是否已安装
local tooltipObjectHookState = setmetatable({}, { __mode = "k" }) -- 已安装对象级 hook 的 tooltip 集合
local reanchorInProgress = false -- 本 API 正在重锚，避免对象级 hook 递归
local followDriverFrame = nil -- follow 模式每帧重锚驱动
local activeTooltip = nil -- 最近一次被本 API 接管的 tooltip
local SECRET_STATUS_METHODS = { "IsAnchoringSecret", "HasSecretValues", "IsPreventingSecretValues" } -- secret 状态检测方法名

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

-- 标记 tooltip 已进入不能继续由插件重锚的状态。
local function freezeTooltipReanchor(tooltip)
  if type(tooltip) ~= "table" then
    return
  end
  secretFrozenTooltipState[tooltip] = true
  if activeTooltip == tooltip then
    activeTooltip = nil
  end
end

-- 检查 tooltip 是否已经携带 secret value 或 secret anchor；检测失败按高风险处理。
local function isTooltipSecretRestricted(tooltip)
  if type(tooltip) ~= "table" then
    return false
  end
  for _, methodName in ipairs(SECRET_STATUS_METHODS) do
    local method = tooltip[methodName] -- secret 状态检测方法
    if type(method) == "function" then
      local success, restricted = pcall(method, tooltip) -- 检测调用结果
      if not success or restricted == true then
        return true
      end
    end
  end
  return false
end

-- 判断当前 tooltip 是否仍允许由本 API 改锚点。
local function canReanchorTooltip(tooltip, allowFrozenReset)
  if type(tooltip) ~= "table" then
    return false
  end
  if secretFrozenTooltipState[tooltip] == true and allowFrozenReset ~= true then
    return false
  end
  if isTooltipSecretRestricted(tooltip) then
    freezeTooltipReanchor(tooltip)
    return false
  end
  if allowFrozenReset == true then
    secretFrozenTooltipState[tooltip] = nil
  end
  return true
end

-- 取得当前可重锚的可见 tooltip；只沿用已经由默认锚点 hook 接管过的对象。
local function getVisibleOverrideTooltip()
  if activeTooltip and not isTooltipShown(activeTooltip) then
    activeTooltip = nil
    return nil
  end
  if isTooltipShown(activeTooltip) and shouldOverrideDefaultAnchor(activeTooltip) and canReanchorTooltip(activeTooltip, false) then
    return activeTooltip
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
local function applyCursorAnchorOverride(tooltip, shouldResetAnchorType, allowFrozenReset)
  if type(tooltip) ~= "table" or type(tooltip.SetPoint) ~= "function" then
    return false
  end
  if not canReanchorTooltip(tooltip, allowFrozenReset) then
    return false
  end

  local offsetX = tonumber(getTooltipSetting("TOOLTIP_OFFSET_X", 0)) or 0 -- X 偏移
  local offsetY = tonumber(getTooltipSetting("TOOLTIP_OFFSET_Y", 0)) or 0 -- Y 偏移
  local cursorX, cursorY = getCursorUiPosition() -- 缩放后的鼠标坐标

  reanchorInProgress = true
  local anchorApplied = false -- 锚点是否设置成功
  repeat
    -- 暴雪原始 GameTooltip_SetDefaultAnchor 已经设置过 owner；这里仅重锚，不再二次 SetOwner。
    if shouldResetAnchorType ~= false and type(tooltip.SetAnchorType) == "function" then
      local setAnchorTypeSuccess = pcall(tooltip.SetAnchorType, tooltip, "ANCHOR_NONE") -- SetAnchorType 版本兼容结果
      if not setAnchorTypeSuccess then
        debugPrint("[SetDefaultAnchor] SetAnchorType failed")
        freezeTooltipReanchor(tooltip)
        break
      end
    end

    if type(tooltip.ClearAllPoints) == "function" then
      local clearPointsSuccess = pcall(tooltip.ClearAllPoints, tooltip) -- 清理旧锚点结果
      if not clearPointsSuccess then
        debugPrint("[SetDefaultAnchor] ClearAllPoints failed")
        freezeTooltipReanchor(tooltip)
        break
      end
    end
    local setPointSuccess = pcall(tooltip.SetPoint, tooltip, "BOTTOMLEFT", UIParent, "BOTTOMLEFT", cursorX + offsetX, cursorY + offsetY) -- 设置新锚点结果
    if not setPointSuccess then
      debugPrint("[SetDefaultAnchor] SetPoint failed")
      freezeTooltipReanchor(tooltip)
      break
    end
    anchorApplied = true
  until true
  reanchorInProgress = false
  if not anchorApplied then
    return false
  end
  activeTooltip = tooltip
  secretFrozenTooltipState[tooltip] = nil
  return true
end

-- 外部 tooltip 改 owner、显示或重设锚点后，下一帧前尽量恢复到鼠标附近。
local function recoverExternalTooltipAnchor(tooltip)
  if reanchorInProgress then
    return
  end
  AzerothCompanion.API.Tooltip.NotifyTooltipOwnerChanged(tooltip)
end

-- 为具体 tooltip 对象安装通用后置 hook，覆盖不走默认锚点的外部 SetOwner/SetPoint 路径。
local function installTooltipObjectHooks(tooltip)
  if type(tooltip) ~= "table" or tooltipObjectHookState[tooltip] == true then
    return
  end
  tooltipObjectHookState[tooltip] = true

  if type(tooltip.HookScript) == "function" then
    pcall(tooltip.HookScript, tooltip, "OnShow", function(self)
      recoverExternalTooltipAnchor(self)
    end)
    pcall(tooltip.HookScript, tooltip, "OnHide", function(self)
      if activeTooltip == self then
        activeTooltip = nil
      end
    end)
  end

  if type(hooksecurefunc) == "function" then
    if type(tooltip.SetOwner) == "function" then
      pcall(hooksecurefunc, tooltip, "SetOwner", function(self)
        recoverExternalTooltipAnchor(self)
      end)
    end
    if type(tooltip.SetAnchorType) == "function" then
      pcall(hooksecurefunc, tooltip, "SetAnchorType", function(self)
        recoverExternalTooltipAnchor(self)
      end)
    end
    if type(tooltip.SetPoint) == "function" then
      pcall(hooksecurefunc, tooltip, "SetPoint", function(self)
        recoverExternalTooltipAnchor(self)
      end)
    end
  end
end

-- 对当前可见 tooltip 立即应用一次锚点，供设置切换后即时生效。
local function applyVisibleTooltipAnchor()
  local tooltip = getVisibleOverrideTooltip() -- 当前可接管 tooltip
  if tooltip then
    applyCursorAnchorOverride(tooltip, true, false)
  end
end

-- follow 模式每帧重锚已显示 tooltip，避免只在默认锚点 hook 时生效一次。
local function updateFollowTooltipAnchor()
  local tooltip = getVisibleOverrideTooltip() -- 当前可接管 tooltip
  if tooltip then
    applyCursorAnchorOverride(tooltip, false, false)
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
  installTooltipObjectHooks(GameTooltip)
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
    applyCursorAnchorOverride(tooltip, true, true)
  end)

  defaultAnchorHookInstalled = true
end

--- 通知 tooltip 已由外部路径重新设置 owner，必要时纳入 cursor/follow 接管。
--- 用于不经过 GameTooltip_SetDefaultAnchor 的 Blizzard UI tooltip，例如冒险指南战利品。
---@param tooltip table|nil 需要接管的 tooltip 对象；nil 时使用 GameTooltip
---@return boolean applied 是否成功接管
function AzerothCompanion.API.Tooltip.NotifyTooltipOwnerChanged(tooltip)
  local tooltipRef = tooltip or GameTooltip -- 需要接管的 tooltip
  installTooltipObjectHooks(tooltipRef)
  if not shouldOverrideDefaultAnchor(tooltipRef) then
    return false
  end
  if not isTooltipShown(tooltipRef) then
    return false
  end
  return applyCursorAnchorOverride(tooltipRef, true, true)
end

--- 安装冒险指南战利品 tooltip hook。
--- Blizzard 战利品行直接 SetOwner("ANCHOR_RIGHT") 后调用 EncounterJournal_SetTooltipWithCompare，
--- 不会触发 GameTooltip_SetDefaultAnchor，因此需要在该函数返回后补一次安全重锚。
function AzerothCompanion.API.Tooltip.InstallEncounterJournalTooltipHook()
  if encounterJournalTooltipHookInstalled then
    return
  end
  if type(_G.EncounterJournal_SetTooltipWithCompare) ~= "function" or type(hooksecurefunc) ~= "function" then
    return
  end

  local hookSuccess = pcall(function() -- hook 安装结果
    hooksecurefunc("EncounterJournal_SetTooltipWithCompare", function(tooltip)
      AzerothCompanion.API.Tooltip.NotifyTooltipOwnerChanged(tooltip)
    end)
  end)
  if hookSuccess then
    encounterJournalTooltipHookInstalled = true
  end
end
