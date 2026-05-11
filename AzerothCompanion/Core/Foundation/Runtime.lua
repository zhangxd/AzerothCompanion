--[[
  Runtime 运行时适配层（Foundation）。
  目的：
    1. 统一封装模块对 WoW 运行时能力的调用入口，减少散落直调。
    2. 为离线逻辑测试提供可注入替身（fake runtime）能力。
  约定：
    - 生产环境默认走本文件中的真实 API 包装。
    - 测试环境可调用 SetOverride 注入实现；ResetOverride 可恢复默认。
]]

AzerothCompanion.Runtime = AzerothCompanion.Runtime or {} -- 运行时命名空间

local Runtime = AzerothCompanion.Runtime -- 运行时适配表

local function getOverride()
  return Runtime._override -- 测试注入实现
end

local function getStubs()
  return Runtime._stubs -- 测试桩返回值
end

local function callOverride(methodName, ...)
  local overrideTable = getOverride() -- 当前注入实现
  if type(overrideTable) == "table" and type(overrideTable[methodName]) == "function" then
    return true, overrideTable[methodName](...)
  end
  return false, nil
end

local function callStub(methodName, ...)
  local stubTable = getStubs() -- 当前桩配置
  if type(stubTable) ~= "table" then
    return false, nil
  end
  local stubValue = stubTable[methodName]
  if stubValue == nil then
    return false, nil
  end
  if type(stubValue) == "function" then
    return true, stubValue(...)
  end
  return true, stubValue
end

local function resolveInjectedResult(methodName, ...)
  local handledByOverride, overrideResult = callOverride(methodName, ...) -- override 结果
  if handledByOverride then
    return true, overrideResult
  end
  local handledByStub, stubResult = callStub(methodName, ...) -- stub 结果
  if handledByStub then
    return true, stubResult
  end
  return false, nil
end

--- 注入运行时替身实现（测试环境使用）。
---@param overrideTable table|nil
function Runtime.SetOverride(overrideTable)
  Runtime._override = overrideTable -- 保存注入实现
end

--- 设置按方法名返回固定值/动态值的测试桩。
---@param stubTable table|nil
function Runtime.SetStubs(stubTable)
  Runtime._stubs = stubTable -- 保存桩配置
end

--- 清理运行时替身实现，恢复默认真实 API。
function Runtime.ResetOverride()
  Runtime._override = nil -- 清空注入实现
end

--- 清理按方法名配置的测试桩。
function Runtime.ResetStubs()
  Runtime._stubs = nil -- 清空桩配置
end

--- 当前是否测试模式（由注入实现显式声明）。
---@return boolean
function Runtime.IsTesting()
  local overrideTable = getOverride() -- 当前注入实现
  if type(overrideTable) == "table" and overrideTable.__isTesting == true then
    return true
  end
  local stubTable = getStubs() -- 当前桩配置
  return type(stubTable) == "table" and stubTable.__isTesting == true
end

--- 创建 Frame。
---@param frameType string
---@param frameName string|nil
---@param parentFrame table|nil
---@param templateName string|nil
---@return table|nil
function Runtime.CreateFrame(frameType, frameName, parentFrame, templateName)
  local handled, injectedFrame = resolveInjectedResult("CreateFrame", frameType, frameName, parentFrame, templateName) -- 注入结果
  if handled then
    return injectedFrame
  end
  if type(_G.CreateFrame) ~= "function" then
    return nil
  end
  return _G.CreateFrame(frameType, frameName, parentFrame, templateName)
end

--- 创建可取消定时器句柄。
---@param delaySeconds number
---@param callback fun()
---@return table|nil
function Runtime.NewTimer(delaySeconds, callback)
  local handled, injectedTimer = resolveInjectedResult("NewTimer", delaySeconds, callback) -- 注入结果
  if handled then
    return injectedTimer
  end
  if C_Timer and type(C_Timer.NewTimer) == "function" then
    return C_Timer.NewTimer(delaySeconds, callback)
  end
  if C_Timer and type(C_Timer.After) == "function" then
    local canceled = false -- 取消标记
    C_Timer.After(delaySeconds, function()
      if canceled then
        return
      end
      if type(callback) == "function" then
        callback()
      end
    end)
    return {
      Cancel = function()
        canceled = true
      end
    }
  end
  if type(callback) == "function" then
    callback()
  end
  return {
    Cancel = function() end
  }
end

--- 延时调用（无句柄语义）。
---@param delaySeconds number
---@param callback fun()
function Runtime.After(delaySeconds, callback)
  local handled, injectedResult = resolveInjectedResult("After", delaySeconds, callback) -- 注入结果
  if handled then
    return injectedResult
  end
  if C_Timer and type(C_Timer.After) == "function" then
    return C_Timer.After(delaySeconds, callback)
  end
  if type(callback) == "function" then
    callback()
  end
  return nil
end

--- 判断 AddOn 是否已加载。
---@param addonName string
---@return boolean
function Runtime.IsAddOnLoaded(addonName)
  local handled, injectedResult = resolveInjectedResult("IsAddOnLoaded", addonName) -- 注入结果
  if handled then
    return injectedResult == true
  end
  if C_AddOns and type(C_AddOns.IsAddOnLoaded) == "function" then
    local success, loaded = pcall(C_AddOns.IsAddOnLoaded, addonName) -- 新 API 查询结果
    if success then
      return loaded == true
    end
  end
  return false
end

--- 加载 AddOn。
---@param addonName string
---@return boolean
function Runtime.LoadAddOn(addonName)
  local handled, injectedResult = resolveInjectedResult("LoadAddOn", addonName) -- 注入结果
  if handled then
    return injectedResult == true
  end
  if C_AddOns and type(C_AddOns.LoadAddOn) == "function" then
    local success = pcall(C_AddOns.LoadAddOn, addonName) -- 新 API 加载结果
    if success then
      return true
    end
  end
  if type(_G.LoadAddOn) == "function" then
    local success = pcall(_G.LoadAddOn, addonName) -- 旧 API 加载兜底
    if success then
      return true
    end
  end
  return false
end

local function pickTooltip(tooltipObject)
  if type(tooltipObject) == "table" then
    return tooltipObject
  end
  return _G.GameTooltip -- 默认 Tooltip 对象
end

--- 设置 tooltip owner。
---@param tooltipObject table|nil
---@param ownerFrame table|nil
---@param anchorType string|nil
function Runtime.TooltipSetOwner(tooltipObject, ownerFrame, anchorType)
  local handled = resolveInjectedResult("TooltipSetOwner", tooltipObject, ownerFrame, anchorType) -- 注入处理标记
  if handled then
    return
  end
  local tooltipRef = pickTooltip(tooltipObject) -- 目标 tooltip
  if tooltipRef and type(tooltipRef.SetOwner) == "function" then
    tooltipRef:SetOwner(ownerFrame, anchorType or "ANCHOR_RIGHT")
  end
end

--- 清空 tooltip 行。
---@param tooltipObject table|nil
function Runtime.TooltipClear(tooltipObject)
  local handled = resolveInjectedResult("TooltipClear", tooltipObject) -- 注入处理标记
  if handled then
    return
  end
  local tooltipRef = pickTooltip(tooltipObject) -- 目标 tooltip
  if tooltipRef and type(tooltipRef.ClearLines) == "function" then
    tooltipRef:ClearLines()
  end
end

--- 设置 tooltip 标题文本。
---@param tooltipObject table|nil
---@param text string
function Runtime.TooltipSetText(tooltipObject, text)
  local handled = resolveInjectedResult("TooltipSetText", tooltipObject, text) -- 注入处理标记
  if handled then
    return
  end
  local tooltipRef = pickTooltip(tooltipObject) -- 目标 tooltip
  if tooltipRef and type(tooltipRef.SetText) == "function" then
    tooltipRef:SetText(text)
  end
end

--- 追加 tooltip 文本行。
---@param tooltipObject table|nil
---@param text string
---@param red number|nil
---@param green number|nil
---@param blue number|nil
---@param wrapText boolean|nil
function Runtime.TooltipAddLine(tooltipObject, text, red, green, blue, wrapText)
  local handled = resolveInjectedResult("TooltipAddLine", tooltipObject, text, red, green, blue, wrapText) -- 注入处理标记
  if handled then
    return
  end
  local tooltipRef = pickTooltip(tooltipObject) -- 目标 tooltip
  if tooltipRef and type(tooltipRef.AddLine) == "function" then
    tooltipRef:AddLine(text, red, green, blue, wrapText)
  end
end

--- 显示 tooltip。
---@param tooltipObject table|nil
function Runtime.TooltipShow(tooltipObject)
  local handled = resolveInjectedResult("TooltipShow", tooltipObject) -- 注入处理标记
  if handled then
    return
  end
  local tooltipRef = pickTooltip(tooltipObject) -- 目标 tooltip
  if tooltipRef and type(tooltipRef.Show) == "function" then
    tooltipRef:Show()
  end
end

--- 隐藏 tooltip。
---@param tooltipObject table|nil
function Runtime.TooltipHide(tooltipObject)
  local handled = resolveInjectedResult("TooltipHide", tooltipObject) -- 注入处理标记
  if handled then
    return
  end
  local tooltipRef = pickTooltip(tooltipObject) -- 目标 tooltip
  if tooltipRef and type(tooltipRef.Hide) == "function" then
    tooltipRef:Hide()
  end
end
