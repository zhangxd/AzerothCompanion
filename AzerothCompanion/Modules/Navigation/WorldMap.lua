--[[
  navigation 世界地图入口：在 WorldMapFrame 显示时创建“规划路线”按钮。
  目标坐标优先读取当前 supertracked 原生地图 pin，缺失时回退用户 waypoint；
  历史重规划则直接接收显式目标快照。
]]

AzerothCompanion.Modules.Navigation = AzerothCompanion.Modules.Navigation or {}

local WorldMap = {}
AzerothCompanion.Modules.Navigation.WorldMap = WorldMap

local TARGET_BUTTON_WIDTH = 96 -- 世界地图规划按钮宽度
local TARGET_BUTTON_FALLBACK_HEIGHT = 24 -- 找不到导航栏高度时的兜底高度
local TARGET_BUTTON_RIGHT_INSET = 4 -- 规划按钮相对导航栏右侧内缩
local WAYPOINT_UPDATED_EVENT = "USER_WAYPOINT_UPDATED" -- 用户地图标记变化事件
local SUPER_TRACKING_CHANGED_EVENT = "SUPER_TRACKING_CHANGED" -- 超级追踪目标变化事件
local WAYPOINT_REFRESH_EVENT_LIST = {
  WAYPOINT_UPDATED_EVENT,
  SUPER_TRACKING_CHANGED_EVENT,
} -- 需要触发按钮刷新的事件列表
local SUPERTRACKED_PIN_TEMPLATE_LIST = {
  "FlightPointPinTemplate",
  "DungeonEntrancePinTemplate",
  "AreaPOIPinTemplate",
} -- 可作为世界地图目标的暴雪原生 supertrackable pin 模板
local worldMapHookInstalled = false -- WorldMapFrame OnShow 是否已挂接
local waypointEventFrame = nil -- 用户地图标记事件监听 Frame
local waypointEventRegistered = false -- 用户地图标记事件是否已注册
local targetButton = nil -- 世界地图规划按钮
local ACCOUNT_SCOPE = "account" -- 账号级设置 scope

--- 读取 navigation 模块账号级设置。
---@param settingName string SettingId 字段名
---@param fallbackValue any 读取失败时的兜底值
---@return any
local function getAccountSetting(settingName, fallbackValue)
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

--- 输出一条导航相关聊天提示。
---@param messageText string|nil 玩家提示文案
local function printNavigationMessage(messageText)
  if not messageText or messageText == "" then
    return
  end
  if AzerothCompanion.API and AzerothCompanion.API.Chat and type(AzerothCompanion.API.Chat.PrintAddonMessage) == "function" then
    AzerothCompanion.API.Chat.PrintAddonMessage(messageText)
  end
end

--- 校验并归一化可规划目标坐标。
---@param mapID any 地图 ID
---@param pointX any 归一化 X 坐标
---@param pointY any 归一化 Y 坐标
---@return number|nil, number|nil, number|nil
local function normalizeTargetCoordinates(mapID, pointX, pointY)
  local numericMapID = tonumber(mapID) -- 目标地图 ID
  local numericX = tonumber(pointX) -- 目标 X 坐标
  local numericY = tonumber(pointY) -- 目标 Y 坐标
  if not numericMapID or numericMapID <= 0 or type(numericX) ~= "number" or type(numericY) ~= "number" then
    return nil, nil, nil
  end
  if numericX < 0 or numericX > 1 or numericY < 0 or numericY > 1 then
    return nil, nil, nil
  end
  return numericMapID, numericX, numericY
end

--- 读取当前用户 waypoint。
---@return number|nil, number|nil, number|nil
local function getUserWaypointTarget()
  local mapApi = type(C_Map) == "table" and C_Map or nil -- 地图 API 表
  local getUserWaypoint = mapApi and mapApi.GetUserWaypoint or nil -- 用户 waypoint 查询
  if type(getUserWaypoint) ~= "function" then
    return nil, nil, nil
  end

  local success, pointValue = pcall(getUserWaypoint) -- waypoint 查询结果
  if not success or type(pointValue) ~= "table" then
    return nil, nil, nil
  end

  local mapID = tonumber(pointValue.uiMapID) -- waypoint 地图 ID
  local targetX, targetY = AzerothCompanion.API.Navigation.ReadVectorXY(pointValue.position) -- waypoint 坐标
  return normalizeTargetCoordinates(mapID, targetX, targetY)
end

--- 读取当前暴雪 supertracked 地图 pin 的结构化类型和 ID。
---@return any, any
local function getCurrentSupertrackedMapPinData()
  local superTrackApi = type(C_SuperTrack) == "table" and C_SuperTrack or nil -- 超级追踪 API 表
  local getSupertrackedMapPin = superTrackApi and superTrackApi.GetSuperTrackedMapPin or nil -- 原生地图 pin 追踪查询
  if type(getSupertrackedMapPin) ~= "function" then
    return nil, nil
  end

  local success, pinType, pinTypeID = pcall(getSupertrackedMapPin) -- 当前 supertracked pin 结构化键
  if not success or pinType == nil or pinTypeID == nil then
    return nil, nil
  end
  return pinType, pinTypeID
end

--- 安全读取 pin 自身的 supertrack 结构化键。
---@param pinFrame table|nil 地图 pin Frame
---@return any, any
local function getPinSupertrackData(pinFrame)
  local getSupertrackData = type(pinFrame) == "table" and pinFrame.GetSuperTrackData or nil -- pin 结构化键读取方法
  if type(getSupertrackData) ~= "function" then
    return nil, nil
  end

  local success, pinType, pinTypeID = pcall(getSupertrackData, pinFrame) -- pin 自身结构化键
  if not success then
    return nil, nil
  end
  return pinType, pinTypeID
end

--- 判断 pin 是否匹配当前 supertracked 结构化键。
---@param pinFrame table|nil 地图 pin Frame
---@param trackedPinType any 当前 supertracked pin 类型
---@param trackedPinTypeID any 当前 supertracked pin ID
---@return boolean
local function isMatchingSupertrackedPin(pinFrame, trackedPinType, trackedPinTypeID)
  local pinType, pinTypeID = getPinSupertrackData(pinFrame) -- pin 自身结构化键
  return pinType ~= nil and pinTypeID ~= nil and pinType == trackedPinType and pinTypeID == trackedPinTypeID
end

--- 调用世界地图 pin 模板枚举器。
---@param worldMapFrame table 大地图根 Frame
---@param templateName string pin 模板名
---@return function|nil, any, any
local function enumerateWorldMapPinsByTemplate(worldMapFrame, templateName)
  local enumeratePins = type(worldMapFrame) == "table" and worldMapFrame.EnumeratePinsByTemplate or nil -- pin 枚举方法
  if type(enumeratePins) ~= "function" then
    return nil, nil, nil
  end

  local success, iterator, state, initialValue = pcall(enumeratePins, worldMapFrame, templateName) -- 模板枚举结果
  if not success or type(iterator) ~= "function" then
    return nil, nil, nil
  end
  return iterator, state, initialValue
end

--- 在当前可见地图 pin 中查找 supertracked pin 对象。
---@param worldMapFrame table 大地图根 Frame
---@param trackedPinType any 当前 supertracked pin 类型
---@param trackedPinTypeID any 当前 supertracked pin ID
---@return table|nil
local function findCurrentSupertrackedPin(worldMapFrame, trackedPinType, trackedPinTypeID)
  if trackedPinType == nil or trackedPinTypeID == nil then
    return nil
  end

  for _, templateName in ipairs(SUPERTRACKED_PIN_TEMPLATE_LIST) do
    local iterator, state, controlValue = enumerateWorldMapPinsByTemplate(worldMapFrame, templateName) -- 模板 pin 迭代器
    while iterator do
      local success, nextControlValue, pinValue = pcall(iterator, state, controlValue) -- 下一枚活动 pin
      if not success or nextControlValue == nil then
        break
      end
      controlValue = nextControlValue
      local pinFrame = type(pinValue) == "table" and pinValue or nextControlValue -- pairs 枚举时 pin 在第一返回值
      if isMatchingSupertrackedPin(pinFrame, trackedPinType, trackedPinTypeID) then
        return pinFrame
      end
    end
  end
  return nil
end

--- 读取世界地图当前 mapID，作为 pin:GetMap() 缺失时的兜底。
---@param worldMapFrame table|nil 大地图根 Frame
---@return number|nil
local function getWorldMapFrameMapID(worldMapFrame)
  local getMapID = type(worldMapFrame) == "table" and worldMapFrame.GetMapID or nil -- 世界地图当前地图读取方法
  if type(getMapID) ~= "function" then
    return nil
  end

  local success, mapID = pcall(getMapID, worldMapFrame) -- 世界地图当前地图 ID
  if not success then
    return nil
  end
  return tonumber(mapID)
end

--- 读取 pin 所属地图 ID。
---@param pinFrame table|nil 地图 pin Frame
---@param worldMapFrame table|nil 大地图根 Frame
---@return number|nil
local function getPinMapID(pinFrame, worldMapFrame)
  local getMap = type(pinFrame) == "table" and pinFrame.GetMap or nil -- pin 所属地图读取方法
  if type(getMap) == "function" then
    local success, pinMap = pcall(getMap, pinFrame) -- pin 所属 MapCanvas
    local getMapID = success and type(pinMap) == "table" and pinMap.GetMapID or nil -- pin 所属地图 ID 方法
    if type(getMapID) == "function" then
      local mapSuccess, mapID = pcall(getMapID, pinMap) -- pin 所属地图 ID
      if mapSuccess and tonumber(mapID) then
        return tonumber(mapID)
      end
    end
  end
  return getWorldMapFrameMapID(worldMapFrame)
end

--- 读取 pin 的归一化坐标。
---@param pinFrame table|nil 地图 pin Frame
---@return number|nil, number|nil
local function getPinPosition(pinFrame)
  local getPosition = type(pinFrame) == "table" and pinFrame.GetPosition or nil -- pin 坐标读取方法
  if type(getPosition) ~= "function" then
    return nil, nil
  end

  local success, pointX, pointY = pcall(getPosition, pinFrame) -- pin 归一化坐标
  if not success then
    return nil, nil
  end
  return pointX, pointY
end

--- 读取当前 supertracked 原生地图 pin 目标。
---@return number|nil, number|nil, number|nil
local function getSupertrackedMapPinTarget()
  local worldMapFrame = _G.WorldMapFrame -- 大地图根 Frame
  local trackedPinType, trackedPinTypeID = getCurrentSupertrackedMapPinData() -- 当前 supertracked pin 键
  local pinFrame = findCurrentSupertrackedPin(worldMapFrame, trackedPinType, trackedPinTypeID) -- 匹配到的原生 pin
  if not pinFrame then
    return nil, nil, nil
  end

  local mapID = getPinMapID(pinFrame, worldMapFrame) -- pin 所属地图 ID
  local pointX, pointY = getPinPosition(pinFrame) -- pin 坐标
  return normalizeTargetCoordinates(mapID, pointX, pointY)
end

--- 读取当前世界地图可规划目标。
---@return number|nil, number|nil, number|nil
local function getCurrentWorldMapTarget()
  local mapID, targetX, targetY = getSupertrackedMapPinTarget() -- 当前 supertracked pin 目标
  if mapID and targetX and targetY then
    return mapID, targetX, targetY
  end
  return getUserWaypointTarget()
end

--- 判断世界地图当前是否正在显示。
---@return boolean
local function isWorldMapShown()
  local worldMapFrame = _G.WorldMapFrame -- 大地图根 Frame
  return worldMapFrame
    and type(worldMapFrame.IsShown) == "function"
    and worldMapFrame:IsShown()
    or false
end

--- 在地图标记变化后刷新可见世界地图入口。
local function refreshVisibleWorldMapEntry()
  if isWorldMapShown() then
    WorldMap.Refresh()
  end
end

--- 确保用户地图标记事件监听 Frame 已创建。
---@return table|nil
local function ensureWaypointEventFrame()
  if waypointEventFrame then
    return waypointEventFrame
  end
  if type(CreateFrame) ~= "function" then
    return nil
  end

  waypointEventFrame = CreateFrame("Frame", nil)
  waypointEventFrame:SetScript("OnEvent", function(_, eventName)
    if eventName == WAYPOINT_UPDATED_EVENT or eventName == SUPER_TRACKING_CHANGED_EVENT then
      refreshVisibleWorldMapEntry()
    end
  end)
  return waypointEventFrame
end

--- 注册用户地图标记变化事件；模块启用期间保持监听。
local function registerWaypointEvent()
  if waypointEventRegistered then
    return
  end
  local eventFrame = ensureWaypointEventFrame() -- 事件监听 Frame
  if eventFrame and type(eventFrame.RegisterEvent) == "function" then
    for _, refreshEventName in ipairs(WAYPOINT_REFRESH_EVENT_LIST) do
      eventFrame:RegisterEvent(refreshEventName)
    end
    waypointEventRegistered = true
  end
end

--- 注销用户地图标记变化事件，避免模块禁用后仍触发刷新。
local function unregisterWaypointEvent()
  if not waypointEventRegistered then
    return
  end
  if waypointEventFrame and type(waypointEventFrame.UnregisterEvent) == "function" then
    for _, refreshEventName in ipairs(WAYPOINT_REFRESH_EVENT_LIST) do
      waypointEventFrame:UnregisterEvent(refreshEventName)
    end
  end
  waypointEventRegistered = false
end

--- 将路线规划错误转换成玩家可见文案。
---@param errorObject table|nil 路线规划错误对象
---@return string|nil
local function getRouteFailureMessage(errorObject)
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化字符串表
  local errorCode = type(errorObject) == "table" and errorObject.code or nil -- 路线错误码
  if errorCode == "NAVIGATION_ERR_UNSUPPORTED_MAP_LEVEL" or errorCode == "NAVIGATION_ERR_BAD_TARGET" then
    return localeTable.NAVIGATION_ROUTE_UNSUPPORTED_TARGET or "当前目标层级暂不支持规划路线，请缩放到区域或子地图后再试。"
  end
  if errorCode == "NAVIGATION_ERR_NO_ROUTE" then
    return localeTable.NAVIGATION_ROUTE_NO_ROUTE or "当前目标暂无可用路线。"
  end
  if errorCode then
    return localeTable.NAVIGATION_ROUTE_PLAN_FAILED or "路线规划失败。"
  end
  return nil
end

--- 去除首尾空白，避免诊断输出里混入空节点名。
---@param rawText any 原始文本
---@return string
local function trimText(rawText)
  local trimmedText = tostring(rawText or "") -- 待裁剪文本
  trimmedText = string.gsub(trimmedText, "^%s+", "")
  trimmedText = string.gsub(trimmedText, "%s+$", "")
  return trimmedText
end

--- 从可用性快照里提取规划起点位置。
---@param availabilityContext table|nil 当前角色可用性快照
---@return table|nil
local function buildStartLocationSnapshot(availabilityContext)
  if type(availabilityContext) ~= "table" then
    return nil
  end
  local currentMapID = tonumber(availabilityContext.currentUiMapID) -- 当前地图 ID
  local currentX = tonumber(availabilityContext.currentX) -- 当前 X
  local currentY = tonumber(availabilityContext.currentY) -- 当前 Y
  if currentMapID == nil and currentX == nil and currentY == nil then
    return nil
  end
  return {
    currentUiMapID = currentMapID,
    currentX = currentX,
    currentY = currentY,
  }
end

--- 构建位置显示文本，优先复用 RouteBar 的地图 / 坐标格式化。
---@param routeBar table|nil 路线图模块
---@param uiMapID any 地图 ID
---@param pointX any 归一化 X 坐标
---@param pointY any 归一化 Y 坐标
---@param fallbackText any 兜底位置文案
---@return string
local function buildLocationDisplayText(routeBar, uiMapID, pointX, pointY, fallbackText)
  local displayText = "" -- 格式化后的位置文案
  if type(routeBar) == "table" and type(routeBar.BuildPositionDisplayText) == "function" then
    displayText = trimText(routeBar.BuildPositionDisplayText(uiMapID, pointX, pointY, fallbackText))
    if displayText ~= "" then
      return displayText
    end
  end

  displayText = trimText(fallbackText)
  if displayText ~= "" then
    return displayText
  end

  local numericMapID = tonumber(uiMapID) -- 地图 ID 兜底
  if numericMapID then
    return "Map #" .. tostring(numericMapID)
  end
  return "未知"
end

--- 从目标和静态地图节点中提取终点兜底名称。
---@param routeTarget table|nil 路线目标
---@return string
local function buildTargetFallbackName(routeTarget)
  local targetName = trimText(type(routeTarget) == "table" and routeTarget.name or nil) -- 目标显式名称
  if targetName ~= "" then
    return targetName
  end
  local targetMapID = tonumber(type(routeTarget) == "table" and routeTarget.uiMapID or nil) -- 目标地图 ID
  local mapNodeTable = AzerothCompanion.Data and AzerothCompanion.Data.NavigationMapNodes and AzerothCompanion.Data.NavigationMapNodes.nodes or nil -- 地图节点表
  local targetMapNode = targetMapID and type(mapNodeTable) == "table" and mapNodeTable[targetMapID] or nil -- 目标地图节点
  return trimText(type(targetMapNode) == "table" and targetMapNode.Name_lang or nil)
end

--- 构建无可用路线时的起终点诊断输出。
---@param routeBar table|nil 路线图模块
---@param routeTarget table|nil 路线目标
---@param availabilityContext table|nil 当前角色可用性快照
---@param errorObject table|nil 路线规划错误对象
---@return string|nil
local function buildNoRouteDiagnosticMessage(routeBar, routeTarget, availabilityContext, errorObject)
  local errorCode = trimText(type(errorObject) == "table" and errorObject.code or nil) -- 路线错误码
  if errorCode ~= "NAVIGATION_ERR_NO_ROUTE" then
    return nil
  end

  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化字符串表
  local startLocationSnapshot = buildStartLocationSnapshot(availabilityContext) -- 规划起点快照
  local targetFallbackName = buildTargetFallbackName(routeTarget) -- 终点兜底名称
  local startText = buildLocationDisplayText(
    routeBar,
    startLocationSnapshot and startLocationSnapshot.currentUiMapID,
    startLocationSnapshot and startLocationSnapshot.currentX,
    startLocationSnapshot and startLocationSnapshot.currentY,
    nil
  ) -- 起点诊断文本
  local targetText = buildLocationDisplayText(
    routeBar,
    routeTarget and routeTarget.uiMapID,
    routeTarget and routeTarget.x,
    routeTarget and routeTarget.y,
    targetFallbackName
  ) -- 终点诊断文本
  local formatText = localeTable.NAVIGATION_ROUTE_FAILURE_DIAGNOSTIC_FMT -- 失败诊断格式
  if not formatText or formatText == "" then
    formatText = "规划失败 | 起点：%s | 终点：%s | 错误：%s"
  end
  return string.format(formatText, startText, targetText, errorCode)
end

--- 拼接一段路线的 traversedUiMapNames 调试文本。
---@param segment table|nil 路线段
---@return string
local function buildTraversedMapNamesText(segment)
  local textList = {} -- 经过地图名列表
  local traversedNameList = type(segment) == "table" and segment.traversedUiMapNames or nil -- 原始经过地图名
  for _, mapName in ipairs(type(traversedNameList) == "table" and traversedNameList or {}) do
    local trimmedName = trimText(mapName) -- 当前地图名
    if trimmedName ~= "" then
      textList[#textList + 1] = trimmedName
    end
  end
  if #textList == 0 then
    return "-"
  end
  return table.concat(textList, " -> ")
end

--- 提取一段路线的有效经过地图名列表。
---@param segment table|nil 路线段
---@return table
local function buildTraversedMapNameList(segment)
  local textList = {} -- 清洗后的经过地图名
  local traversedNameList = type(segment) == "table" and segment.traversedUiMapNames or nil -- 原始经过地图名
  for _, mapName in ipairs(type(traversedNameList) == "table" and traversedNameList or {}) do
    local trimmedName = trimText(mapName) -- 当前地图名
    if trimmedName ~= "" then
      textList[#textList + 1] = trimmedName
    end
  end
  return textList
end

--- 判断一段路线是否属于应按到站地图显示终点的动作。
---@param modeText string|nil 路线方式
---@return boolean
local function isSemanticArrivalMode(modeText)
  return modeText == "transport"
    or modeText == "public_portal"
    or modeText == "class_portal"
    or modeText == "hearthstone"
    or modeText == "class_teleport"
end

--- 基于 routeResult.semanticNodes 构建规划期节点摘要。
---@param routeResult table|nil 路线结果
---@return string
local function buildSemanticNodeSummaryText(routeResult)
  local semanticNodeList = type(routeResult) == "table" and routeResult.semanticNodes or nil -- API 生成的语义节点链
  if type(semanticNodeList) ~= "table" or #semanticNodeList == 0 then
    return ""
  end

  local textList = {} -- 语义节点文本列表
  local firstKind = trimText(type(semanticNodeList[1]) == "table" and semanticNodeList[1].kind or nil) -- 第一节点类型
  local lastKind = trimText(type(semanticNodeList[#semanticNodeList]) == "table" and semanticNodeList[#semanticNodeList].kind or nil) -- 最后一节点类型
  if firstKind ~= "map" or lastKind ~= "map" then
    return ""
  end
  local lastText = nil -- 最近一个已写入的节点文本
  for _, nodeInfo in ipairs(semanticNodeList) do
    local trimmedText = trimText(type(nodeInfo) == "table" and nodeInfo.text or nil) -- 当前语义节点文本
    if trimmedText ~= "" and trimmedText ~= lastText then
      textList[#textList + 1] = trimmedText
      lastText = trimmedText
    end
  end
  if #textList < 2 then
    return ""
  end
  return table.concat(textList, " -> ")
end

--- 为规划期逐段诊断生成更适合玩家理解的端点文案。
---@param segment table|nil 路线段
---@param useDestination boolean 是否读取终点侧
---@return string
local function buildPlanningSegmentEndpointText(segment, useDestination)
  if type(segment) ~= "table" then
    return ""
  end
  local modeText = tostring(segment.mode or "") -- 当前路线方式
  if useDestination and isSemanticArrivalMode(modeText) then
    local traversedMapNameList = buildTraversedMapNameList(segment) -- 当前段经过地图名
    local arrivalMapName = trimText(traversedMapNameList[#traversedMapNameList]) -- 当前动作段到站地图名
    if arrivalMapName ~= "" then
      return arrivalMapName
    end
  end
  return trimText(useDestination and (segment.toName or segment.to) or (segment.fromName or segment.from))
end

--- 归一化节点文案，便于规划节点摘要去重。
---@param rawText any 原始文案
---@return string
local function normalizeNodeText(rawText)
  local normalizedText = string.lower(trimText(rawText)) -- 归一化前的节点文案
  normalizedText = string.gsub(normalizedText, "%s+", "")
  return normalizedText
end

--- 向规划诊断节点列表追加一个节点，避免相邻重复。
---@param nodeList table 节点列表
---@param nodeText any 待追加节点
local function appendPlanningNode(nodeList, nodeText)
  local trimmedText = trimText(nodeText) -- 去空白后的节点文案
  if trimmedText == "" then
    return
  end
  local lastNodeText = nodeList[#nodeList] -- 最近一个节点
  if normalizeNodeText(lastNodeText) == normalizeNodeText(trimmedText) then
    return
  end
  nodeList[#nodeList + 1] = trimmedText
end

--- 生成地图级节点文案；规划诊断摘要里不带坐标。
---@param routeBar table|nil 路线图模块
---@param uiMapID any 地图 ID
---@param fallbackText any 兜底文案
---@return string
local function buildMapNodeText(routeBar, uiMapID, fallbackText)
  if type(routeBar) == "table" and type(routeBar.BuildPositionDisplayText) == "function" then
    local mapText = trimText(routeBar.BuildPositionDisplayText(uiMapID, nil, nil, fallbackText)) -- RouteBar 格式化后的地图文案
    if mapText ~= "" then
      return mapText
    end
  end
  return trimText(fallbackText)
end

--- 基于路线段构建规划期诊断节点摘要。
---@param routeBar table|nil 路线图模块
---@param routeResult table|nil 路线结果
---@param routeTarget table|nil 路线目标
---@param startLocationSnapshot table|nil 规划起点快照
---@return string
local function buildPlanningNodeSummaryText(routeBar, routeResult, routeTarget, startLocationSnapshot)
  local semanticNodeList = type(routeResult) == "table" and routeResult.semanticNodes or nil -- 路线结果携带的语义节点链
  local hasSemanticNodeList = type(semanticNodeList) == "table" and #semanticNodeList > 0 -- 当前是否带了语义节点
  local semanticNodeSummaryText = buildSemanticNodeSummaryText(routeResult) -- API 已生成的语义节点摘要
  if semanticNodeSummaryText ~= "" then
    return semanticNodeSummaryText
  end
  if hasSemanticNodeList and type(routeBar) == "table" and type(routeBar.BuildRouteNodePathText) == "function" then
    local routeBarSummaryText = trimText(routeBar.BuildRouteNodePathText(routeResult, routeTarget, startLocationSnapshot)) -- RouteBar 统一节点链摘要
    if routeBarSummaryText ~= "" then
      return routeBarSummaryText
    end
  end

  local segmentList = type(routeResult) == "table" and routeResult.segments or nil -- 路线分段列表
  if type(segmentList) ~= "table" or #segmentList == 0 then
    return ""
  end

  local firstSegment = segmentList[1] or nil -- 第一段路线
  local targetMapText = buildMapNodeText(
    routeBar,
    routeTarget and routeTarget.uiMapID,
    routeTarget and routeTarget.name
  ) -- 终点地图节点文案
  local nodeList = {} -- 规划期诊断节点列表
  appendPlanningNode(nodeList, buildMapNodeText(
    routeBar,
    startLocationSnapshot and startLocationSnapshot.currentUiMapID or (firstSegment and firstSegment.fromUiMapID),
    firstSegment and firstSegment.fromName
  ))

  for segmentIndex, segment in ipairs(segmentList) do
    local modeText = tostring(type(segment) == "table" and segment.mode or "") -- 当前路线方式
    local nextSegment = segmentList[segmentIndex + 1] -- 下一段路线
    local traversedMapNameList = buildTraversedMapNameList(segment) -- 当前段经过地图名
    if modeText == "walk_local" then
      for traversedIndex = 2, math.max(#traversedMapNameList - 1, 1) do
        appendPlanningNode(nodeList, traversedMapNameList[traversedIndex])
      end
      if nextSegment then
        appendPlanningNode(nodeList, segment and segment.toName)
      else
        appendPlanningNode(nodeList, targetMapText ~= "" and targetMapText or (segment and segment.toName))
      end
    else
      local lastTraversedMapName = traversedMapNameList[#traversedMapNameList] -- 当前段落点所在地图
      if normalizeNodeText(lastTraversedMapName) ~= normalizeNodeText(segment and segment.toName) then
        appendPlanningNode(nodeList, lastTraversedMapName)
      end
      appendPlanningNode(nodeList, segment and segment.toName)
    end
  end

  if #nodeList == 0 then
    return ""
  end
  return table.concat(nodeList, " -> ")
end

--- 向诊断字段列表追加一个 key=value 背景字段。
---@param textList table 字段文本列表
---@param fieldName string 字段名
---@param fieldValue any 字段值
---@param includeEmpty boolean|nil 是否用 "-" 显示空值
local function appendDiagnosticBackgroundField(textList, fieldName, fieldValue, includeEmpty)
  local valueText = trimText(fieldValue) -- 字段值文本
  if valueText == "" and includeEmpty then
    valueText = "-"
  end
  if valueText ~= "" then
    textList[#textList + 1] = tostring(fieldName) .. "=" .. valueText
  end
end

--- 拼接一段路线的来源 / 条件背景，帮助区分职业能力边与公共传送边。
---@param segmentInfo table|nil 路线段或诊断段
---@return string
local function buildDiagnosticBackgroundText(segmentInfo)
  if type(segmentInfo) ~= "table" then
    return ""
  end

  local sourceText = trimText(segmentInfo.source or segmentInfo.Source) -- 来源类型
  local sourceIDText = trimText(segmentInfo.sourceID or segmentInfo.SourceID) -- 来源主键
  local routeEdgeIndexText = trimText(segmentInfo.routeEdgeIndex or segmentInfo.RouteEdgeIndex) -- 统一路线边表下标
  local edgeIDText = trimText(segmentInfo.edgeID or segmentInfo.EdgeID or segmentInfo.id or segmentInfo.ID) -- 路线边 ID
  local originalModeText = trimText(segmentInfo.originalMode or segmentInfo.OriginalMode) -- 原始路线方式
  local manualTravelText = (segmentInfo.manualTravel == true or segmentInfo.ManualTravel == true) and "true" or "" -- 是否手动飞行展示
  local abilityTemplateIDText = trimText(segmentInfo.abilityTemplateID or segmentInfo.AbilityTemplateID) -- 能力模板 ID
  local spellIDText = trimText(segmentInfo.spellID or segmentInfo.SpellID) -- 技能 ID
  local classFileText = trimText(segmentInfo.classFile or segmentInfo.ClassFile) -- 职业限制
  local factionRequirementText = trimText(segmentInfo.factionRequirement or segmentInfo.FactionRequirement) -- 阵营限制
  local playerConditionIDText = trimText(segmentInfo.playerConditionID or segmentInfo.PlayerConditionID) -- 玩家条件 ID
  local fromNodeIDText = trimText(segmentInfo.fromNodeID or segmentInfo.FromNodeID or segmentInfo.from or segmentInfo.From) -- 起点运行时节点 ID
  local toNodeIDText = trimText(segmentInfo.toNodeID or segmentInfo.ToNodeID or segmentInfo.to or segmentInfo.To) -- 终点运行时节点 ID
  local fromSourceText = trimText(segmentInfo.fromSource or segmentInfo.FromSource) -- 起点来源类型
  local fromSourceIDText = trimText(segmentInfo.fromSourceID or segmentInfo.FromSourceID) -- 起点来源侧 ID
  local toSourceText = trimText(segmentInfo.toSource or segmentInfo.ToSource) -- 终点来源类型
  local toSourceIDText = trimText(segmentInfo.toSourceID or segmentInfo.ToSourceID) -- 终点来源侧 ID
  local fromUiMapIDText = trimText(segmentInfo.fromUiMapID or segmentInfo.FromUiMapID) -- 起点地图 ID
  local toUiMapIDText = trimText(segmentInfo.toUiMapID or segmentInfo.ToUiMapID) -- 终点地图 ID
  local fromTaxiNodeIDText = trimText(segmentInfo.fromTaxiNodeID or segmentInfo.FromTaxiNodeID) -- 起点飞行点 ID
  local toTaxiNodeIDText = trimText(segmentInfo.toTaxiNodeID or segmentInfo.ToTaxiNodeID) -- 终点飞行点 ID
  local hasBackground = sourceText ~= "" -- 是否存在任一背景字段
    or sourceIDText ~= ""
    or routeEdgeIndexText ~= ""
    or edgeIDText ~= ""
    or originalModeText ~= ""
    or manualTravelText ~= ""
    or abilityTemplateIDText ~= ""
    or spellIDText ~= ""
    or classFileText ~= ""
    or factionRequirementText ~= ""
    or playerConditionIDText ~= ""
    or fromNodeIDText ~= ""
    or toNodeIDText ~= ""
    or fromSourceText ~= ""
    or fromSourceIDText ~= ""
    or toSourceText ~= ""
    or toSourceIDText ~= ""
    or fromUiMapIDText ~= ""
    or toUiMapIDText ~= ""
    or fromTaxiNodeIDText ~= ""
    or toTaxiNodeIDText ~= ""
  local textList = {} -- 背景字段文本

  if not hasBackground then
    return ""
  end

  appendDiagnosticBackgroundField(textList, "source", sourceText)
  appendDiagnosticBackgroundField(textList, "sourceID", sourceIDText)
  appendDiagnosticBackgroundField(textList, "routeEdgeIndex", routeEdgeIndexText)
  appendDiagnosticBackgroundField(textList, "edgeID", edgeIDText)
  appendDiagnosticBackgroundField(textList, "originalMode", originalModeText)
  appendDiagnosticBackgroundField(textList, "manualTravel", manualTravelText)
  appendDiagnosticBackgroundField(textList, "abilityTemplateID", abilityTemplateIDText)
  appendDiagnosticBackgroundField(textList, "spellID", spellIDText)
  appendDiagnosticBackgroundField(textList, "classFile", classFileText)
  appendDiagnosticBackgroundField(textList, "playerConditionID", playerConditionIDText)
  appendDiagnosticBackgroundField(textList, "factionRequirement", factionRequirementText, true)
  appendDiagnosticBackgroundField(textList, "fromNodeID", fromNodeIDText)
  appendDiagnosticBackgroundField(textList, "toNodeID", toNodeIDText)
  appendDiagnosticBackgroundField(textList, "fromSource", fromSourceText)
  appendDiagnosticBackgroundField(textList, "fromSourceID", fromSourceIDText)
  appendDiagnosticBackgroundField(textList, "toSource", toSourceText)
  appendDiagnosticBackgroundField(textList, "toSourceID", toSourceIDText)
  appendDiagnosticBackgroundField(textList, "fromUiMapID", fromUiMapIDText)
  appendDiagnosticBackgroundField(textList, "toUiMapID", toUiMapIDText)
  appendDiagnosticBackgroundField(textList, "fromTaxiNodeID", fromTaxiNodeIDText)
  appendDiagnosticBackgroundField(textList, "toTaxiNodeID", toTaxiNodeIDText)
  return table.concat(textList, " | ")
end

--- 根据 RouteBar 的统一显示模型生成规划期聊天诊断。
---@param displayModel table|nil 统一显示模型
---@return table|nil
local function buildPlanningDiagnosticMessagesFromDisplayModel(displayModel)
  if type(displayModel) ~= "table" then
    return nil
  end
  local diagnosticSegmentList = type(displayModel.diagnosticSegments) == "table" and displayModel.diagnosticSegments or nil -- 逐段诊断模型
  if type(diagnosticSegmentList) ~= "table" or #diagnosticSegmentList == 0 then
    return nil
  end

  local startText = trimText(displayModel.startPositionText) -- 起点文本
  local targetText = trimText(displayModel.targetPositionText) -- 终点文本
  local nodeSummaryText = trimText(displayModel.nodeSummaryText) -- 节点摘要
  if startText == "" then
    startText = "未知"
  end
  if targetText == "" then
    targetText = "未知"
  end
  if nodeSummaryText == "" then
    nodeSummaryText = "暂无路线"
  end

  local messageList = {
    string.format(
      "规划成功 | 起点：%s | 终点：%s | 总步数：%d | 节点：%s",
      startText,
      targetText,
      tonumber(displayModel.totalSteps) or #diagnosticSegmentList,
      nodeSummaryText
    ),
  } -- 规划成功后的诊断文本列表
  for segmentIndex, segmentInfo in ipairs(diagnosticSegmentList) do
    local segmentPrefix = string.format( -- 段落前缀
      "第%d段 | mode=%s",
      tonumber(segmentInfo.index) or segmentIndex,
      tostring(segmentInfo.mode or "")
    )
    local backgroundText = buildDiagnosticBackgroundText(segmentInfo) -- 来源与条件背景
    if backgroundText ~= "" then
      segmentPrefix = segmentPrefix .. " | " .. backgroundText
    end
    messageList[#messageList + 1] = string.format(
      "%s | from=%s | to=%s | traversedUiMapNames=%s",
      segmentPrefix,
      trimText(segmentInfo.fromText),
      trimText(segmentInfo.toText),
      trimText(segmentInfo.traversedMapText) ~= "" and trimText(segmentInfo.traversedMapText) or "-"
    )
  end
  return messageList
end

--- 构建规划成功后的聊天诊断输出。
---@param routeBar table|nil 路线图模块
---@param routeResult table|nil 路线结果
---@param routeTarget table|nil 路线目标
---@param availabilityContext table|nil 当前角色可用性快照
---@return table
local function buildPlanningDiagnosticMessages(routeBar, routeResult, routeTarget, availabilityContext)
  local segmentList = type(routeResult) == "table" and routeResult.segments or nil -- 路线分段列表
  if type(segmentList) ~= "table" or #segmentList == 0 then
    return {}
  end

  local startLocationSnapshot = buildStartLocationSnapshot(availabilityContext) -- 规划起点快照
  if type(routeBar) == "table" and type(routeBar.BuildRouteDisplayModel) == "function" then
    local displayModel = routeBar.BuildRouteDisplayModel(routeResult, routeTarget, startLocationSnapshot, startLocationSnapshot) -- 统一显示模型
    local displayMessageList = buildPlanningDiagnosticMessagesFromDisplayModel(displayModel) -- 统一模型诊断输出
    if type(displayMessageList) == "table" then
      return displayMessageList
    end
  end

  local firstSegment = segmentList[1] or nil -- 第一段路线
  local finalSegment = segmentList[#segmentList] or nil -- 最后一段路线
  local startText = "" -- 起点调试文本
  local targetText = "" -- 终点调试文本
  local nodeSummaryText = "" -- 节点摘要文本

  if type(routeBar) == "table" and type(routeBar.BuildPositionDisplayText) == "function" then
    startText = routeBar.BuildPositionDisplayText(
      startLocationSnapshot and startLocationSnapshot.currentUiMapID or (firstSegment and firstSegment.fromUiMapID),
      startLocationSnapshot and startLocationSnapshot.currentX,
      startLocationSnapshot and startLocationSnapshot.currentY,
      firstSegment and firstSegment.fromName
    )
    targetText = routeBar.BuildPositionDisplayText(
      routeTarget and routeTarget.uiMapID,
      routeTarget and routeTarget.x,
      routeTarget and routeTarget.y,
      routeTarget and routeTarget.name
    )
  end
  nodeSummaryText = buildPlanningNodeSummaryText(routeBar, routeResult, routeTarget, startLocationSnapshot)

  if startText == "" then
    startText = trimText(firstSegment and firstSegment.fromName) ~= "" and trimText(firstSegment.fromName) or "未知"
  end
  if targetText == "" then
    targetText = trimText(routeTarget and routeTarget.name) ~= "" and trimText(routeTarget.name) or trimText(finalSegment and finalSegment.toName)
    if targetText == "" then
      targetText = "未知"
    end
  end
  if nodeSummaryText == "" then
    if type(routeBar) == "table" and type(routeBar.BuildRouteNodePathText) == "function" then
      nodeSummaryText = trimText(routeBar.BuildRouteNodePathText(routeResult, routeTarget, startLocationSnapshot))
    end
  end
  if nodeSummaryText == "" then
    nodeSummaryText = trimText(type(routeBar) == "table" and type(routeBar.BuildRouteText) == "function" and routeBar.BuildRouteText(routeResult) or "")
    nodeSummaryText = string.gsub(nodeSummaryText, "^%s*%d+步%s*|%s*", "")
    if nodeSummaryText == "" then
      nodeSummaryText = "暂无路线"
    end
  end

  local messageList = {
    string.format(
      "规划成功 | 起点：%s | 终点：%s | 总步数：%d | 节点：%s",
      startText,
      targetText,
      tonumber(routeResult and routeResult.totalSteps) or #segmentList,
      nodeSummaryText
    ),
  } -- 规划成功后的诊断文本列表
  for segmentIndex, segment in ipairs(segmentList) do
    local segmentPrefix = string.format( -- 段落前缀
      "第%d段 | mode=%s",
      segmentIndex,
      tostring(segment and segment.mode or "")
    )
    local backgroundText = buildDiagnosticBackgroundText(segment) -- 来源与条件背景
    if backgroundText ~= "" then
      segmentPrefix = segmentPrefix .. " | " .. backgroundText
    end
    messageList[#messageList + 1] = string.format(
      "%s | from=%s | to=%s | traversedUiMapNames=%s",
      segmentPrefix,
      buildPlanningSegmentEndpointText(segment, false),
      buildPlanningSegmentEndpointText(segment, true),
      buildTraversedMapNamesText(segment)
    )
  end
  return messageList
end

--- 规划指定世界地图目标，并刷新顶部路线图。
---@param routeTarget table|nil 目标快照，至少包含 uiMapID/x/y
---@return table|nil, table|nil
function WorldMap.PlanRouteToTarget(routeTarget)
  local target = type(routeTarget) == "table" and routeTarget or nil -- 规划目标
  local numericMapID = tonumber(target and target.uiMapID) -- 目标地图 ID
  local targetX = tonumber(target and target.x) -- 目标 X
  local targetY = tonumber(target and target.y) -- 目标 Y
  local routeBar = AzerothCompanion.Modules.Navigation and AzerothCompanion.Modules.Navigation.RouteBar or nil -- 顶部路线图模块
  if not numericMapID or not targetX or not targetY then
    if routeBar and type(routeBar.ClearRoute) == "function" then
      routeBar.ClearRoute()
    end
    printNavigationMessage((AzerothCompanion.Localization.Strings or {}).NAVIGATION_ROUTE_NEEDS_WAYPOINT or "请先在世界地图上放置目标标记。")
    return nil, { code = "NAVIGATION_ERR_BAD_TARGET" }
  end

  local spellIDList = AzerothCompanion.API.Navigation.GetRequiredSpellIDList(AzerothCompanion.Data and AzerothCompanion.Data.NavigationRouteEdges) -- 需要确认的统一路线边技能列表
  local availabilityContext = AzerothCompanion.API.Navigation.BuildCurrentCharacterAvailability(spellIDList) -- 当前角色可用性快照
  local routeResult, errorObject = AzerothCompanion.API.Navigation.PlanRouteToMapTarget({
    uiMapID = numericMapID,
    x = targetX,
    y = targetY,
    name = target.name,
  }, availabilityContext)

  if routeResult and routeBar and type(routeBar.ShowRoute) == "function" then
    routeBar.ShowRoute(routeResult, {
      uiMapID = numericMapID,
      x = targetX,
      y = targetY,
      name = target.name,
    })
    local planningMessageList = buildPlanningDiagnosticMessages(routeBar, routeResult, {
      uiMapID = numericMapID,
      x = targetX,
      y = targetY,
      name = target.name,
    }, availabilityContext) -- 规划成功后的诊断输出
    if #planningMessageList > 0 then
      for _, messageText in ipairs(planningMessageList) do
        printNavigationMessage(messageText)
      end
    elseif type(routeBar.BuildRouteText) == "function" then
      printNavigationMessage(routeBar.BuildRouteText(routeResult))
    end
    return routeResult, nil
  end

  if routeBar and type(routeBar.ClearRoute) == "function" then
    routeBar.ClearRoute()
  end
  local failureMessage = getRouteFailureMessage(errorObject) -- 规划失败提示
  if failureMessage then
    printNavigationMessage(failureMessage)
  end
  local diagnosticMessage = buildNoRouteDiagnosticMessage(routeBar, { -- 无可用路线时的起终点诊断
    uiMapID = numericMapID,
    x = targetX,
    y = targetY,
    name = target.name,
  }, availabilityContext, errorObject)
  if diagnosticMessage then
    printNavigationMessage(diagnosticMessage)
  end
  return nil, errorObject
end

--- 规划当前世界地图目标，并刷新顶部路线图。
local function planRouteFromCurrentWorldMapTarget()
  local mapID, targetX, targetY = getCurrentWorldMapTarget() -- 当前世界地图目标
  if not mapID or not targetX or not targetY then
    local routeBar = AzerothCompanion.Modules.Navigation and AzerothCompanion.Modules.Navigation.RouteBar or nil -- 顶部路线图模块
    if routeBar and type(routeBar.ClearRoute) == "function" then
      routeBar.ClearRoute()
    end
    printNavigationMessage((AzerothCompanion.Localization.Strings or {}).NAVIGATION_ROUTE_NEEDS_WAYPOINT or "请先在世界地图上放置目标标记。")
    return
  end
  WorldMap.PlanRouteToTarget({
    uiMapID = mapID,
    x = targetX,
    y = targetY,
  })
end

--- 获取世界地图原生导航栏 Frame。
---@param worldMapFrame table 大地图根 Frame
---@return table|nil
local function getWorldMapNavBar(worldMapFrame)
  if type(worldMapFrame) ~= "table" then
    return nil
  end
  local navBarFrame = worldMapFrame.NavBar -- Retail 世界地图导航栏
  if type(navBarFrame) == "table" then
    return navBarFrame
  end
  navBarFrame = worldMapFrame.navBar -- 兼容少数测试或旧命名注入
  if type(navBarFrame) == "table" then
    return navBarFrame
  end
  local borderFrame = worldMapFrame.BorderFrame -- 大地图边框 Frame
  navBarFrame = type(borderFrame) == "table" and borderFrame.NavBar or nil
  if type(navBarFrame) == "table" then
    return navBarFrame
  end
  return nil
end

--- 解析世界地图规划按钮父级与是否为导航栏布局。
---@param worldMapFrame table 大地图根 Frame
---@return table, boolean
local function resolveTargetButtonParent(worldMapFrame)
  local navBarFrame = getWorldMapNavBar(worldMapFrame) -- 原生导航栏
  if navBarFrame then
    return navBarFrame, true
  end
  return worldMapFrame.BorderFrame or worldMapFrame, false
end

--- 读取导航栏高度，缺失时返回稳定兜底值。
---@param parentFrame table 按钮父级
---@return number
local function resolveTargetButtonHeight(parentFrame)
  local parentHeight = type(parentFrame) == "table" and type(parentFrame.GetHeight) == "function"
    and tonumber(parentFrame:GetHeight())
    or nil -- 父级高度
  if parentHeight and parentHeight > 0 then
    return parentHeight
  end
  return TARGET_BUTTON_FALLBACK_HEIGHT
end

--- 刷新世界地图规划按钮布局。
---@param buttonFrame table 规划按钮
---@param worldMapFrame table 大地图根 Frame
local function layoutTargetButton(buttonFrame, worldMapFrame)
  if type(buttonFrame) ~= "table" or type(worldMapFrame) ~= "table" then
    return
  end
  local parentFrame, usesNavBar = resolveTargetButtonParent(worldMapFrame) -- 实际父级
  local currentParent = type(buttonFrame.GetParent) == "function" and buttonFrame:GetParent() or nil -- 当前父级
  if type(buttonFrame.SetParent) == "function" and currentParent ~= parentFrame then
    buttonFrame:SetParent(parentFrame)
  end
  if type(buttonFrame.ClearAllPoints) == "function" then
    buttonFrame:ClearAllPoints()
  end
  local buttonHeight = resolveTargetButtonHeight(parentFrame) -- 按钮高度
  if usesNavBar then
    buttonFrame:SetSize(TARGET_BUTTON_WIDTH, buttonHeight)
    buttonFrame:SetPoint("TOPRIGHT", parentFrame, "TOPRIGHT", -TARGET_BUTTON_RIGHT_INSET, 0)
    buttonFrame:SetPoint("BOTTOMRIGHT", parentFrame, "BOTTOMRIGHT", -TARGET_BUTTON_RIGHT_INSET, 0)
  else
    buttonFrame:SetSize(TARGET_BUTTON_WIDTH, buttonHeight)
    buttonFrame:SetPoint("TOP", parentFrame, "TOP", 0, -36)
  end
end

--- 确保世界地图规划按钮已创建。
---@return table|nil
local function ensureTargetButton()
  local worldMapFrame = _G.WorldMapFrame -- 大地图根 Frame
  if not worldMapFrame or type(CreateFrame) ~= "function" then
    return nil
  end
  if targetButton then
    layoutTargetButton(targetButton, worldMapFrame)
    return targetButton
  end

  local parentFrame = resolveTargetButtonParent(worldMapFrame) -- 按钮父级
  targetButton = CreateFrame("Button", nil, parentFrame, "UIPanelButtonTemplate")
  layoutTargetButton(targetButton, worldMapFrame)
  targetButton:SetText((AzerothCompanion.Localization.Strings or {}).NAVIGATION_WORLD_MAP_BUTTON or "Route")
  targetButton:SetScript("OnClick", planRouteFromCurrentWorldMapTarget)
  targetButton:Show()
  return targetButton
end

--- 刷新世界地图入口可见性。
function WorldMap.Refresh()
  local isNavigationEnabled = getAccountSetting("NAVIGATION_ENABLED", true) ~= false -- navigation 模块是否启用
  local button = ensureTargetButton() -- 世界地图规划按钮
  if not button then
    return
  end
  if not isNavigationEnabled then
    button:Hide()
  else
    local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化字符串表
    local mapID = getCurrentWorldMapTarget() -- 当前世界地图目标地图 ID
    if mapID then
      button:SetText(localeTable.NAVIGATION_WORLD_MAP_BUTTON or "Route")
      if type(button.Enable) == "function" then
        button:Enable()
      else
        button:SetEnabled(true)
      end
    else
      button:SetText(localeTable.NAVIGATION_WORLD_MAP_BUTTON_NEEDS_WAYPOINT or "Set waypoint")
      if type(button.Disable) == "function" then
        button:Disable()
      else
        button:SetEnabled(false)
      end
    end
    button:Show()
  end
end

--- 安装 WorldMapFrame 显示生命周期挂接。
function WorldMap.Install()
  registerWaypointEvent()
  if worldMapHookInstalled then
    if isWorldMapShown() then
      WorldMap.Refresh()
    end
    return
  end
  local worldMapFrame = _G.WorldMapFrame -- 大地图根 Frame
  if not worldMapFrame or type(worldMapFrame.HookScript) ~= "function" then
    return
  end
  worldMapFrame:HookScript("OnShow", function()
    WorldMap.Refresh()
  end)
  worldMapHookInstalled = true
  if type(worldMapFrame.IsShown) == "function" and worldMapFrame:IsShown() then
    WorldMap.Refresh()
  end
end

--- 隐藏世界地图入口。
function WorldMap.Hide()
  unregisterWaypointEvent()
  if targetButton then
    targetButton:Hide()
  end
end

--- 获取世界地图规划按钮，供测试使用。
---@return table|nil
function WorldMap.GetTargetButton()
  return targetButton
end
