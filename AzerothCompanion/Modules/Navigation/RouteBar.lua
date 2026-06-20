--[[
  navigation 路线图组件：在屏幕顶部显示可折叠的导航胶囊与完整时间线。
  组件只管理 navigation 自己的路线状态、历史记录与轻量实时刷新，不影响其他模块。
]]

AzerothCompanion.Modules.Navigation = AzerothCompanion.Modules.Navigation or {}

local RouteBar = {}
AzerothCompanion.Modules.Navigation.RouteBar = RouteBar

local DEFAULT_WIDGET_WIDTH = 420 -- 路线图默认宽度
local DEFAULT_CAPSULE_HEIGHT = 88 -- 精简胶囊高度
local DEFAULT_EXPANDED_HEIGHT = 300 -- 展开态高度
local DEFAULT_HISTORY_DRAWER_WIDTH = 248 -- 历史抽屉宽度
local DEFAULT_HISTORY_LIMIT = 10 -- 最近历史记录上限
local DEFAULT_REFRESH_INTERVAL = 0.5 -- 实时刷新节流秒数
local DEFAULT_NODE_ROW_HEIGHT = 44 -- 节点行高度
local MAX_WIDGET_WIDTH = 960 -- 路线图允许扩展到的最大宽度
local DEFAULT_COLUMN_MIN_WIDTH = 120 -- 胶囊三列的最小宽度
local DEFAULT_COLUMN_GAP = 28 -- 胶囊三列之间的最小间距
local DEFAULT_COLUMN_OUTER_PADDING = 24 -- 胶囊列组左右外边距
local DEFAULT_NODE_ROW_GAP = 6 -- 节点行之间的间距
local DEFAULT_NODE_CONTAINER_PADDING = 8 -- 节点容器上下内边距
local DEFAULT_HISTORY_BUTTON_WIDTH = 76 -- 历史按钮宽度
local DEFAULT_CLOSE_BUTTON_WIDTH = 52 -- 关闭按钮宽度
local DEFAULT_HEADER_BUTTON_HEIGHT = 20 -- 胶囊标题按钮高度
local HISTORY_CONFIRM_DIALOG_KEY = "AZEROTHCOMPANION_NAVIGATION_ROUTE_HISTORY_CONFIRM" -- 历史重规划确认弹框键
local DEFAULT_POSITION = {
  point = "TOP",
  x = 0,
  y = -18,
} -- 默认锚点位置
local ACCOUNT_SCOPE = "account" -- 账号级设置 scope
local CHARACTER_SCOPE = "character" -- 角色级设置 scope
local VALID_POINT_NAME = {
  TOP = true,
  BOTTOM = true,
  LEFT = true,
  RIGHT = true,
  CENTER = true,
  TOPLEFT = true,
  TOPRIGHT = true,
  BOTTOMLEFT = true,
  BOTTOMRIGHT = true,
} -- 允许写入存档的锚点名

local routeBarFrame = nil -- 路线图根 Frame
local activeRouteState = nil -- 当前导航路线状态
local cleanPlayerFacingLabel = nil -- 清洗后的玩家可见动作标签函数前置声明
local buildTargetDisplayName = nil -- 路线终点显示名函数前置声明
local buildRouteDisplayModel = nil -- 统一路线显示模型构建函数前置声明

--- 读取 Config 数字设置 ID。
---@param settingName string SettingId 字段名
---@return number|nil
local function getSettingId(settingName)
  local configTable = AzerothCompanion.Config or nil -- 配置入口
  local settingIdTable = configTable and configTable.SettingId or nil -- 设置 ID 常量表
  return type(settingIdTable) == "table" and settingIdTable[settingName] or nil
end

--- 读取 navigation 设置值；table 由 Config.Get 返回副本。
---@param settingName string SettingId 字段名
---@param scopeName string 存档 scope
---@param fallbackValue any 读取失败时的兜底值
---@return any
local function getNavigationSetting(settingName, scopeName, fallbackValue)
  local configTable = AzerothCompanion.Config or nil -- 配置入口
  local settingId = getSettingId(settingName) -- 数字设置 ID
  if type(configTable) == "table" and type(configTable.Get) == "function" and settingId then
    local settingValue = configTable.Get(settingId, scopeName) -- 当前设置值
    if settingValue ~= nil then
      return settingValue
    end
  end
  return fallbackValue
end

--- 写入 navigation 设置值。
---@param settingName string SettingId 字段名
---@param scopeName string 存档 scope
---@param settingValue any 待写入值
local function setNavigationSetting(settingName, scopeName, settingValue)
  local configTable = AzerothCompanion.Config or nil -- 配置入口
  local settingId = getSettingId(settingName) -- 数字设置 ID
  if type(configTable) == "table" and type(configTable.Set) == "function" and settingId then
    configTable.Set(settingId, scopeName, settingValue)
  end
end

--- 读取一条本地化文案；缺失时返回兜底文本。
---@param key string 文案键
---@param fallbackText string 兜底文本
---@return string
local function getLocaleText(key, fallbackText)
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化字符串表
  local localizedText = localeTable[key] -- 本地化结果
  if type(localizedText) == "string" and localizedText ~= "" then
    return localizedText
  end
  return fallbackText
end

--- 去除首尾空白。
---@param rawText any
---@return string
local function trimText(rawText)
  local trimmedText = tostring(rawText or "") -- 待裁剪文本
  trimmedText = string.gsub(trimmedText, "^%s+", "")
  trimmedText = string.gsub(trimmedText, "%s+$", "")
  return trimmedText
end

--- 归一化导航名称，便于玩家可见文本去重。
---@param rawValue any
---@return string
local function normalizeNavigationName(rawValue)
  local normalizedValue = string.lower(trimText(rawValue)) -- 小写化名称
  normalizedValue = string.gsub(normalizedValue, "%s+", "")
  return normalizedValue
end

--- 判断一组归一化坐标是否有效。
---@param pointX any
---@param pointY any
---@return boolean
local function isNormalizedPosition(pointX, pointY)
  return type(pointX) == "number" and type(pointY) == "number" and pointX >= 0 and pointX <= 1 and pointY >= 0 and pointY <= 1
end

--- 复制一份位置快照，避免后续刷新复用同一引用。
---@param locationSnapshot table|nil 原始位置快照
---@return table|nil
local function copyLocationSnapshot(locationSnapshot)
  if type(locationSnapshot) ~= "table" then
    return nil
  end
  local snapshotMapID = tonumber(locationSnapshot.currentUiMapID or locationSnapshot.uiMapID) -- 快照地图 ID
  local snapshotX = tonumber(locationSnapshot.currentX or locationSnapshot.x) -- 快照 X
  local snapshotY = tonumber(locationSnapshot.currentY or locationSnapshot.y) -- 快照 Y
  if snapshotMapID == nil and snapshotX == nil and snapshotY == nil then
    return nil
  end
  return {
    currentUiMapID = snapshotMapID,
    currentX = snapshotX,
    currentY = snapshotY,
  }
end

--- 读取当前角色位置快照，兼容测试注入。
---@return table|nil
local function getCurrentLocationSnapshot()
  if AzerothCompanion.API.Navigation and type(AzerothCompanion.API.Navigation.GetCurrentLocationSnapshot) == "function" then
    return copyLocationSnapshot(AzerothCompanion.API.Navigation.GetCurrentLocationSnapshot())
  end
  return nil
end

--- 读取地图玩家可见名称；优先使用导出的 NavigationMapNodes。
---@param uiMapID any 地图 ID
---@param fallbackText any 兜底名称
---@return string
local function buildMapDisplayName(uiMapID, fallbackText)
  local numericMapID = tonumber(uiMapID) -- 地图 ID
  local nodeTable = AzerothCompanion.Data and AzerothCompanion.Data.NavigationMapNodes and AzerothCompanion.Data.NavigationMapNodes.nodes or nil -- 地图节点表
  local mapNode = type(nodeTable) == "table" and nodeTable[numericMapID] or nil -- 当前地图节点
  local mapName = trimText(type(mapNode) == "table" and (mapNode.Name_lang or mapNode.name) or nil) -- 导出地图名称
  if mapName ~= "" then
    return mapName
  end
  local fallbackName = trimText(fallbackText) -- 兜底地图名称
  if fallbackName ~= "" then
    return fallbackName
  end
  if numericMapID and numericMapID > 0 then
    return string.format("UiMap %d", numericMapID)
  end
  return ""
end

--- 将地图与坐标格式化为玩家可见文本。
---@param uiMapID any 地图 ID
---@param pointX any 坐标 X
---@param pointY any 坐标 Y
---@param fallbackText any 兜底名称
---@return string
local function buildPositionDisplayText(uiMapID, pointX, pointY, fallbackText)
  local mapText = buildMapDisplayName(uiMapID, fallbackText) -- 地图显示名
  local numericX = tonumber(pointX) -- 坐标 X
  local numericY = tonumber(pointY) -- 坐标 Y
  if mapText == "" then
    return ""
  end
  if isNormalizedPosition(numericX, numericY) then
    return string.format("%s %.1f, %.1f", mapText, numericX * 100, numericY * 100)
  end
  return mapText
end

--- 将存档中的锚点位置归一化为可直接使用的结构。
---@param rawPosition table|nil 原始位置存档
---@return table
local function normalizeWidgetPosition(rawPosition)
  local positionTable = type(rawPosition) == "table" and rawPosition or {} -- 原始位置表
  local pointName = tostring(positionTable.point or DEFAULT_POSITION.point) -- 锚点名
  if not VALID_POINT_NAME[pointName] then
    pointName = DEFAULT_POSITION.point
  end
  return {
    point = pointName,
    x = tonumber(positionTable.x) or DEFAULT_POSITION.x,
    y = tonumber(positionTable.y) or DEFAULT_POSITION.y,
  }
end

--- 读取路线图展开状态。
---@return boolean
local function getRouteWidgetExpanded()
  return getNavigationSetting("NAVIGATION_ROUTE_WIDGET_EXPANDED", ACCOUNT_SCOPE, false) == true
end

--- 写入路线图展开状态。
---@param shouldExpand boolean 是否展开
local function setRouteWidgetExpanded(shouldExpand)
  setNavigationSetting("NAVIGATION_ROUTE_WIDGET_EXPANDED", ACCOUNT_SCOPE, shouldExpand == true)
end

--- 读取历史抽屉展开状态。
---@return boolean
local function getRouteHistoryExpanded()
  return getNavigationSetting("NAVIGATION_ROUTE_HISTORY_EXPANDED", ACCOUNT_SCOPE, false) == true
end

--- 写入历史抽屉展开状态。
---@param shouldExpand boolean 是否展开
local function setRouteHistoryExpanded(shouldExpand)
  setNavigationSetting("NAVIGATION_ROUTE_HISTORY_EXPANDED", ACCOUNT_SCOPE, shouldExpand == true)
end

--- 读取并归一路线图位置。
---@return table
local function getRouteWidgetPosition()
  local rawPosition = getNavigationSetting("NAVIGATION_ROUTE_WIDGET_POSITION", ACCOUNT_SCOPE, DEFAULT_POSITION) -- 原始路线图位置
  return normalizeWidgetPosition(rawPosition)
end

--- 写入路线图位置。
---@param widgetPosition table 路线图位置
local function setRouteWidgetPosition(widgetPosition)
  setNavigationSetting("NAVIGATION_ROUTE_WIDGET_POSITION", ACCOUNT_SCOPE, normalizeWidgetPosition(widgetPosition))
end

--- 读取角色级最近路线历史。
---@return table
local function getRouteHistory()
  local routeHistory = getNavigationSetting("NAVIGATION_ROUTE_HISTORY", CHARACTER_SCOPE, {}) -- 最近路线历史
  if type(routeHistory) ~= "table" then
    return {}
  end
  return routeHistory
end

--- 写入角色级最近路线历史。
---@param routeHistory table 最近路线历史
local function setRouteHistory(routeHistory)
  setNavigationSetting("NAVIGATION_ROUTE_HISTORY", CHARACTER_SCOPE, type(routeHistory) == "table" and routeHistory or {})
end

--- 复制一个顺序数组。
---@param sourceArray table|nil 原始数组
---@return table
local function copyArray(sourceArray)
  local copiedArray = {} -- 复制后的数组
  for index, value in ipairs(type(sourceArray) == "table" and sourceArray or {}) do
    copiedArray[index] = value
  end
  return copiedArray
end

--- 从玩家可见文本里抽取地图级名称。
---@param rawText any
---@return string
local function extractMapLevelName(rawText)
  local displayText = trimText(rawText) -- 原始显示文本
  displayText = string.gsub(displayText, "^当前位置[:：]?", "")
  displayText = string.gsub(displayText, "^目标位置[:：]?", "")
  displayText = trimText(displayText)
  local coordinatePrefix = string.match(displayText, "^(.-)%s+[%d%.]+,%s*[%d%.]+$") -- 去掉坐标后的前缀
  if coordinatePrefix then
    displayText = trimText(coordinatePrefix)
  end
  displayText = string.gsub(displayText, "目标点$", "")
  return trimText(displayText)
end

--- 读取路线段某一侧更适合展示给玩家的地图名。
---@param segment table|nil 路线段
---@param useDestination boolean 是否读取终点侧
---@return string
local function buildSegmentMapName(segment, useDestination)
  if type(segment) ~= "table" then
    return ""
  end
  local traversedNameList = type(segment.traversedUiMapNames) == "table" and segment.traversedUiMapNames or nil -- 经过地图名列表
  if useDestination and type(traversedNameList) == "table" and #traversedNameList > 0 then
    local lastTraversedName = extractMapLevelName(traversedNameList[#traversedNameList]) -- 最后一个经过地图名
    if lastTraversedName ~= "" then
      return lastTraversedName
    end
  end
  local uiMapID = useDestination and segment.toUiMapID or segment.fromUiMapID -- 路线段地图 ID
  local fallbackName = useDestination and segment.toName or segment.fromName -- 路线段兜底名
  return extractMapLevelName(buildMapDisplayName(uiMapID, fallbackName))
end

--- 判断路线方式是否属于需要保留交通枢纽表达的类型。
---@param modeText string|nil 路线方式
---@return boolean
local function isTransportMode(modeText)
  return modeText == "public_portal"
    or modeText == "class_portal"
    or modeText == "transport"
    or modeText == "hearthstone"
    or modeText == "class_teleport"
end

--- 为交通段生成玩家可见的枢纽节点名。
---@param segment table|nil 路线段
---@return string, string
local function buildTransportHubDisplay(segment)
  if type(segment) ~= "table" then
    return "", "map"
  end
  local modeText = tostring(segment.mode or "") -- 当前路线方式
  local cleanedLabel = cleanPlayerFacingLabel(segment.label) -- 清洗后的动作标签
  local fromName = extractMapLevelName(segment.fromName) -- 起点名
  local fromMapName = buildMapDisplayName(segment.fromUiMapID, fromName) -- 起点地图名
  if modeText == "public_portal" or modeText == "class_portal" then
    if string.find(fromName, "传送门", 1, true) then
      return fromName, "portal"
    end
    if fromMapName ~= "" then
      return fromMapName .. "传送门", "portal"
    end
    if string.find(cleanedLabel, "传送门", 1, true) then
      return "传送门", "portal"
    end
  elseif modeText == "transport" then
    if string.find(fromName, "飞艇", 1, true) then
      return fromName, "transport"
    end
    if string.find(cleanedLabel, "飞艇", 1, true) then
      if fromMapName ~= "" then
        return fromMapName .. "飞艇", "transport"
      end
      return "飞艇", "transport"
    end
    if string.find(fromName, "港口", 1, true) or string.find(fromName, "船", 1, true) then
      return fromName, "transport"
    end
    if string.find(cleanedLabel, "港口", 1, true) or string.find(cleanedLabel, "船", 1, true) then
      if fromMapName ~= "" then
        return fromMapName .. "港口", "transport"
      end
      return "港口", "transport"
    end
    if string.find(cleanedLabel, "地铁", 1, true) then
      if fromMapName ~= "" then
        return fromMapName .. "地铁", "transport"
      end
      return "地铁", "transport"
    end
  elseif modeText == "hearthstone" then
    return "炉石", "hearthstone"
  elseif modeText == "class_teleport" then
    return "职业传送", "teleport"
  end
  return "", "map"
end

--- 向节点链追加一个玩家可见节点，并避免相邻重复。
---@param nodeList table 节点列表
---@param displayText string 节点显示名
---@param nodeKind string 节点类型
---@param nodeMeta table|nil 节点补充信息
local function appendDisplayNode(nodeList, displayText, nodeKind, nodeMeta)
  local normalizedText = normalizeNavigationName(displayText) -- 节点归一化名
  if normalizedText == "" then
    return
  end
  local lastNode = nodeList[#nodeList] -- 最近一个节点
  if type(lastNode) == "table" and normalizeNavigationName(lastNode.text) == normalizedText then
    if tostring(lastNode.kind or "") == "map" and tostring(nodeKind or "") ~= "map" then
      lastNode.kind = nodeKind
    end
    local incomingMapID = tonumber(type(nodeMeta) == "table" and nodeMeta.uiMapID) -- 待写入地图 ID
    local incomingDetailText = trimText(type(nodeMeta) == "table" and nodeMeta.detailText or nil) -- 待写入节点明细
    if incomingMapID and not tonumber(lastNode.uiMapID) then
      lastNode.uiMapID = incomingMapID
    end
    if incomingDetailText ~= "" then
      local currentDetailText = trimText(lastNode.detailText) -- 旧节点明细
      if currentDetailText ~= "" and currentDetailText ~= incomingDetailText then
        lastNode.detailText = currentDetailText .. " -> " .. incomingDetailText
      else
        lastNode.detailText = incomingDetailText
      end
    end
    return
  end
  nodeList[#nodeList + 1] = {
    text = trimText(displayText),
    kind = trimText(nodeKind) ~= "" and nodeKind or "map",
    uiMapID = tonumber(type(nodeMeta) == "table" and nodeMeta.uiMapID) or nil,
    detailText = trimText(type(nodeMeta) == "table" and nodeMeta.detailText or nil),
  }
end

--- 向节点链补入一段路线中的中间地图级节点。
---@param nodeList table 节点列表
---@param segment table|nil 路线段
local function appendIntermediateTraversedMapNodes(nodeList, segment)
  local traversedNameList = type(segment) == "table" and segment.traversedUiMapNames or nil -- 原始经过地图名列表
  local traversedMapIDList = type(segment) == "table" and segment.traversedUiMapIDs or nil -- 原始经过地图 ID 列表
  local lastInteriorIndex = type(traversedNameList) == "table" and (#traversedNameList - 1) or 0 -- 最后一个中间节点索引
  if type(traversedNameList) ~= "table" or lastInteriorIndex < 2 then
    return
  end
  for traversedIndex = 2, lastInteriorIndex do
    appendDisplayNode(nodeList, extractMapLevelName(traversedNameList[traversedIndex]), "map", {
      uiMapID = type(traversedMapIDList) == "table" and traversedMapIDList[traversedIndex] or nil,
    })
  end
end

--- 将 semantic node 的模式映射到 RouteBar 现有图标类型。
---@param nodeInfo table|nil 语义节点
---@return string
local function buildSemanticDisplayKind(nodeInfo)
  local nodeKind = trimText(type(nodeInfo) == "table" and nodeInfo.kind or nil) -- 语义节点类型
  local modeText = trimText(type(nodeInfo) == "table" and nodeInfo.mode or nil) -- 动作方式
  if nodeKind ~= "action" then
    return nodeKind ~= "" and nodeKind or "map"
  end
  if modeText == "public_portal" or modeText == "class_portal" then
    return "portal"
  end
  if modeText == "transport" then
    return "transport"
  end
  if modeText == "hearthstone" then
    return "hearthstone"
  end
  if modeText == "class_teleport" then
    return "teleport"
  end
  return "action"
end

--- 判断 RouteBar 当前能否直接消费一条完整 semantic path。
---@param nodeList table|nil RouteBar 显示节点链
---@return boolean
local function isSemanticDisplayNodeListUsable(nodeList)
  if type(nodeList) ~= "table" or #nodeList < 2 then
    return false
  end
  local firstNode = nodeList[1] -- 第一条显示节点
  local lastNode = nodeList[#nodeList] -- 最后一条显示节点
  return trimText(type(firstNode) == "table" and firstNode.kind or nil) == "map"
    and trimText(type(lastNode) == "table" and lastNode.kind or nil) == "map"
end

--- 基于 API 已生成的 semantic nodes 构建 RouteBar 显示节点链。
---@param routeResult table|nil 路线结果
---@param routeTarget table|nil 路线目标
---@param startLocationSnapshot table|nil 规划起点快照
---@return table|nil
local function buildDisplayNodesFromSemanticPath(routeResult, routeTarget, startLocationSnapshot)
  local semanticNodeList = type(routeResult) == "table" and routeResult.semanticNodes or nil -- API 生成的语义节点链
  if type(semanticNodeList) ~= "table" or #semanticNodeList == 0 then
    return nil
  end

  local nodeList = {} -- RouteBar 显示节点链
  for nodeIndex, nodeInfo in ipairs(semanticNodeList) do
    local displayText = trimText(type(nodeInfo) == "table" and nodeInfo.text or nil) -- 当前节点文案
    local nodeKind = buildSemanticDisplayKind(nodeInfo) -- 当前节点图标类型
    local uiMapID = tonumber(type(nodeInfo) == "table" and nodeInfo.uiMapID) -- 当前节点地图 ID
    if nodeIndex == 1 and nodeKind == "map" then
      displayText = buildPositionDisplayText(
        startLocationSnapshot and startLocationSnapshot.currentUiMapID or uiMapID,
        startLocationSnapshot and startLocationSnapshot.currentX,
        startLocationSnapshot and startLocationSnapshot.currentY,
        displayText
      )
      uiMapID = tonumber(startLocationSnapshot and startLocationSnapshot.currentUiMapID) or uiMapID
    elseif nodeIndex == #semanticNodeList and nodeKind == "map" then
      displayText = buildPositionDisplayText(
        type(routeTarget) == "table" and routeTarget.uiMapID or uiMapID,
        type(routeTarget) == "table" and routeTarget.x,
        type(routeTarget) == "table" and routeTarget.y,
        extractMapLevelName(buildTargetDisplayName(routeTarget, routeResult))
      )
      uiMapID = tonumber(type(routeTarget) == "table" and routeTarget.uiMapID) or uiMapID
    end
    appendDisplayNode(nodeList, displayText, nodeKind, {
      uiMapID = uiMapID,
    })
  end
  if not isSemanticDisplayNodeListUsable(nodeList) then
    return nil
  end
  return nodeList
end

--- 基于路线段构建玩家可见的地图 / 枢纽节点链。
---@param routeResult table|nil 路线结果
---@param routeTarget table|nil 路线目标
---@param startLocationSnapshot table|nil 规划起点快照
---@return table
local function buildRouteDisplayNodes(routeResult, routeTarget, startLocationSnapshot)
  local semanticDisplayNodeList = buildDisplayNodesFromSemanticPath(routeResult, routeTarget, startLocationSnapshot) -- API 级语义节点链
  if type(semanticDisplayNodeList) == "table" then
    return semanticDisplayNodeList
  end

  local segmentList = type(routeResult) == "table" and routeResult.segments or nil -- 路线分段列表
  if type(segmentList) ~= "table" or #segmentList == 0 then
    return {}
  end

  local nodeList = {} -- 玩家可见节点链
  local firstSegment = segmentList[1] or nil -- 第一段路线
  local startUiMapID = startLocationSnapshot and startLocationSnapshot.currentUiMapID or (firstSegment and firstSegment.fromUiMapID) -- 规划起点地图 ID
  local startPositionText = buildPositionDisplayText(
    startUiMapID,
    startLocationSnapshot and startLocationSnapshot.currentX,
    startLocationSnapshot and startLocationSnapshot.currentY,
    buildSegmentMapName(firstSegment, false)
  ) -- 规划起点节点文案
  appendDisplayNode(nodeList, startPositionText, "map", {
    uiMapID = startUiMapID,
  })

  for segmentIndex, segment in ipairs(segmentList) do
    local modeText = tostring(type(segment) == "table" and segment.mode or "") -- 当前段方式
    local nextSegment = segmentList[segmentIndex + 1] -- 下一段路线
    if modeText == "walk_local" then
      appendIntermediateTraversedMapNodes(nodeList, segment)
      if type(nextSegment) == "table" and isTransportMode(tostring(nextSegment.mode or "")) then
        local hubName = extractMapLevelName(segment.toName) -- 步行段落点
        if hubName == "" then
          local fallbackHubName, fallbackHubKind = buildTransportHubDisplay(nextSegment) -- 下一段的交通枢纽名
          appendDisplayNode(nodeList, fallbackHubName, fallbackHubKind, {
            uiMapID = segment.toUiMapID,
          })
        else
          local fallbackHubName, fallbackHubKind = buildTransportHubDisplay(nextSegment) -- 交通枢纽兜底类型
          appendDisplayNode(nodeList, hubName, fallbackHubKind, {
            uiMapID = segment.toUiMapID,
          })
          if fallbackHubName ~= "" then
            appendDisplayNode(nodeList, fallbackHubName, fallbackHubKind, {
              uiMapID = segment.toUiMapID,
            })
          end
        end
      elseif nextSegment == nil then
        local destinationPositionText = buildPositionDisplayText(
          routeTarget and routeTarget.uiMapID or segment.toUiMapID,
          routeTarget and routeTarget.x,
          routeTarget and routeTarget.y,
          extractMapLevelName(buildTargetDisplayName(routeTarget, routeResult))
        ) -- 最终终点节点文案
        appendDisplayNode(nodeList, destinationPositionText, "map", {
          uiMapID = routeTarget and routeTarget.uiMapID or segment.toUiMapID,
        })
      end
    else
      local hubName, hubKind = buildTransportHubDisplay(segment) -- 当前交通枢纽节点
      if hubName ~= "" and (modeText == "hearthstone" or modeText == "class_teleport" or modeText == "class_portal") then
        appendDisplayNode(nodeList, hubName, hubKind, {
          uiMapID = segment.fromUiMapID,
        })
      end
      local mergesIntoFinalWalkTarget = type(nextSegment) == "table"
        and segmentIndex + 1 == #segmentList
        and tostring(nextSegment.mode or "") == "walk_local"
        and tonumber(segment.toUiMapID) ~= nil
        and tonumber(segment.toUiMapID) == tonumber(nextSegment.toUiMapID) -- 是否会并入最后一步本地目标
      if not mergesIntoFinalWalkTarget then
        local destinationMapName = buildSegmentMapName(segment, true) -- 当前段落点地图名
        appendDisplayNode(nodeList, destinationMapName, "map", {
          uiMapID = segment.toUiMapID,
        })
      end
    end
  end

  local finalTargetPositionText = buildPositionDisplayText(
    type(routeTarget) == "table" and routeTarget.uiMapID,
    type(routeTarget) == "table" and routeTarget.x,
    type(routeTarget) == "table" and routeTarget.y,
    extractMapLevelName(buildTargetDisplayName(routeTarget, routeResult))
  ) -- 最终目标节点文案
  appendDisplayNode(nodeList, finalTargetPositionText, "map", {
    uiMapID = type(routeTarget) == "table" and routeTarget.uiMapID,
  })
  return nodeList
end

--- 将节点链格式化为一行路线摘要。
---@param routeResult table|nil 路线结果
---@param routeTarget table|nil 路线目标
---@param startLocationSnapshot table|nil 规划起点快照
---@return string
local function buildRouteNodePathText(routeResult, routeTarget, startLocationSnapshot)
  local displayNodeList = buildRouteDisplayNodes(routeResult, routeTarget, startLocationSnapshot) -- 玩家可见节点链
  if #displayNodeList == 0 then
    return getLocaleText("NAVIGATION_ROUTE_EMPTY", "暂无路线")
  end
  local textList = {} -- 节点文本列表
  for _, nodeInfo in ipairs(displayNodeList) do
    textList[#textList + 1] = nodeInfo.text
  end
  return table.concat(textList, " -> ")
end

--- 将节点链格式化为一行路线摘要。
---@param routeResult table|nil 路线结果
---@param routeTarget table|nil 路线目标
---@param startLocationSnapshot table|nil 规划起点快照
---@return string
local function buildRouteNodeSummaryText(routeResult, routeTarget, startLocationSnapshot)
  return string.format(
    "%s步 | %s",
    tostring(tonumber(routeResult and routeResult.totalSteps) or 0),
    buildRouteNodePathText(routeResult, routeTarget, startLocationSnapshot)
  )
end

--- 清理边标签里导出用的后缀节点补充，仅保留玩家需要执行的动作。
---@param rawLabel any
---@return string
cleanPlayerFacingLabel = function(rawLabel)
  local cleanedLabel = trimText(rawLabel) -- 原始显示标签
  if cleanedLabel == "" then
    return ""
  end

  local splitMarkers = {
    "→",
    "â",
  } -- 导出时可能拼入的箭头补充
  local firstSplitIndex = nil -- 最早箭头位置
  for _, marker in ipairs(splitMarkers) do
    local markerIndex = string.find(cleanedLabel, marker, 1, true) -- 箭头位置
    if markerIndex and (not firstSplitIndex or markerIndex < firstSplitIndex) then
      firstSplitIndex = markerIndex
    end
  end
  if firstSplitIndex then
    cleanedLabel = trimText(string.sub(cleanedLabel, 1, firstSplitIndex - 1))
  end
  return cleanedLabel
end

--- 生成路线段的玩家可见主文案。
---@param segment table|nil 路线段
---@return string
local function buildPrimarySegmentText(segment)
  if type(segment) ~= "table" then
    return ""
  end

  local modeText = tostring(segment.mode or "unknown") -- 路线方式
  local fromName = tostring(segment.fromName or segment.from or "?") -- 起点显示名
  local toName = tostring(segment.toName or segment.to or "?") -- 终点显示名
  local cleanedLabel = cleanPlayerFacingLabel(segment.label) -- 统一动作标签
  if segment.manualTravel == true then
    if cleanedLabel ~= "" then
      return cleanedLabel
    end
    return string.format(getLocaleText("NAVIGATION_ROUTE_MANUAL_FLIGHT_LABEL_FMT", "飞行前往：%s -> %s"), fromName, toName)
  end
  if modeText == "walk_local" then
    if string.find(cleanedLabel, "目标位置：", 1, true) == 1 or string.find(cleanedLabel, "当前位置：", 1, true) == 1 then
      return cleanedLabel
    end
    return string.format("步行：%s -> %s", fromName, toName)
  end
  if modeText == "hearthstone" then
    return string.format("炉石：%s", toName)
  end

  if cleanedLabel ~= "" then
    return cleanedLabel
  end
  return string.format("%s: %s -> %s", modeText, fromName, toName)
end

--- 构建路线段需要展示的“经过地图”文本。
---@param segment table|nil 路线段
---@return string
local function buildTraversedNameText(segment)
  if type(segment) ~= "table" then
    return ""
  end
  if tostring(segment.mode or "") == "walk_local" then
    return ""
  end

  local fromName = normalizeNavigationName(segment.fromName or segment.from) -- 起点归一化名称
  local toName = normalizeNavigationName(segment.toName or segment.to) -- 终点归一化名称
  local traversedNameList = {} -- 经过地图显示名
  local seenName = {} -- 已写入地图名
  for _, traversedName in ipairs(type(segment.traversedUiMapNames) == "table" and segment.traversedUiMapNames or {}) do
    local displayName = trimText(traversedName) -- 当前经过地图名
    local normalizedName = normalizeNavigationName(displayName) -- 当前地图归一化名
    if displayName ~= "" and normalizedName ~= "" and normalizedName ~= fromName and normalizedName ~= toName and not seenName[normalizedName] then
      seenName[normalizedName] = true
      traversedNameList[#traversedNameList + 1] = displayName
    end
  end
  if #traversedNameList == 0 then
    return ""
  end
  return string.format("（途经：%s）", table.concat(traversedNameList, "、"))
end

--- 生成单段路线文本。
---@param segment table|nil 路线段
---@return string
local function buildSegmentText(segment)
  if type(segment) ~= "table" then
    return ""
  end
  local primaryText = buildPrimarySegmentText(segment) -- 玩家可见主文案
  local traversedNameText = buildTraversedNameText(segment) -- 经过地图名串
  if primaryText == "" then
    return ""
  end
  if traversedNameText ~= "" then
    return primaryText .. traversedNameText
  end
  return primaryText
end

--- 拼接路线步骤文本。
---@param routeResult table|nil 路线结果
---@return string
local function buildRouteText(routeResult)
  if type(buildRouteDisplayModel) == "function" then
    local displayModel = buildRouteDisplayModel(routeResult, nil, nil, nil) -- 统一显示模型
    local summaryText = trimText(type(displayModel) == "table" and displayModel.historySummaryText or nil) -- 历史摘要文案
    if summaryText ~= "" then
      return summaryText
    end
  end
  return buildRouteNodeSummaryText(routeResult, nil, nil)
end

--- 将目标快照编码为去重签名。
---@param routeTarget table|nil 路线目标
---@return string
local function buildHistorySignature(routeTarget)
  local numericMapID = tonumber(type(routeTarget) == "table" and routeTarget.uiMapID) or 0 -- 目标地图 ID
  local targetX = tonumber(type(routeTarget) == "table" and routeTarget.x) or 0 -- 目标 X
  local targetY = tonumber(type(routeTarget) == "table" and routeTarget.y) or 0 -- 目标 Y
  return string.format("%d:%.4f:%.4f", numericMapID, targetX, targetY)
end

--- 生成路线目标显示名。
---@param routeTarget table|nil 路线目标
---@param routeResult table|nil 路线结果
---@return string
buildTargetDisplayName = function(routeTarget, routeResult)
  local targetName = trimText(type(routeTarget) == "table" and routeTarget.name or nil) -- 外部传入的终点名
  if targetName ~= "" then
    return targetName
  end
  local segmentList = type(routeResult) == "table" and routeResult.segments or nil -- 路线分段列表
  local lastSegment = type(segmentList) == "table" and segmentList[#segmentList] or nil -- 最后一段
  local lastName = trimText(lastSegment and lastSegment.toName) -- 路线最后终点名
  if lastName ~= "" then
    return lastName
  end
  return "目标点"
end

--- 将当前路线记录进最近历史；同目标重新规划时移动到最前面。
---@param routeTarget table|nil 路线目标
---@param routeResult table|nil 路线结果
local function pushRouteHistory(routeTarget, routeResult, startLocationSnapshot)
  local numericMapID = tonumber(type(routeTarget) == "table" and routeTarget.uiMapID) -- 目标地图 ID
  if not numericMapID or numericMapID <= 0 then
    return
  end

  local routeHistory = getRouteHistory() -- 最近路线历史
  local historySignature = buildHistorySignature(routeTarget) -- 当前目标签名
  for historyIndex = #routeHistory, 1, -1 do
    local entry = routeHistory[historyIndex] -- 旧历史项
    local entrySignature = buildHistorySignature({
      uiMapID = entry and entry.targetUiMapID,
      x = entry and entry.targetX,
      y = entry and entry.targetY,
    }) -- 历史项签名
    if entrySignature == historySignature then
      table.remove(routeHistory, historyIndex)
    end
  end

  local historyDisplayModel = type(buildRouteDisplayModel) == "function"
    and buildRouteDisplayModel(routeResult, routeTarget, startLocationSnapshot, startLocationSnapshot)
    or nil -- 历史项显示模型
  local historySummaryText = trimText(type(historyDisplayModel) == "table" and historyDisplayModel.historySummaryText or nil) -- 历史项摘要
  if historySummaryText == "" then
    historySummaryText = buildRouteNodeSummaryText(routeResult, routeTarget, startLocationSnapshot)
  end

  table.insert(routeHistory, 1, {
    targetUiMapID = numericMapID,
    targetX = tonumber(type(routeTarget) == "table" and routeTarget.x) or 0,
    targetY = tonumber(type(routeTarget) == "table" and routeTarget.y) or 0,
    targetName = buildTargetDisplayName(routeTarget, routeResult),
    summaryText = historySummaryText,
  })

  while #routeHistory > DEFAULT_HISTORY_LIMIT do
    table.remove(routeHistory)
  end
  setRouteHistory(routeHistory)
end

--- 将根 Frame 锚定到当前存档位置。
---@param frame table 路线图根 Frame
local function applyWidgetPosition(frame)
  local widgetPosition = getRouteWidgetPosition() -- 当前路线图位置
  setRouteWidgetPosition(widgetPosition)
  frame:ClearAllPoints()
  frame:SetPoint(widgetPosition.point, UIParent, widgetPosition.point, widgetPosition.x, widgetPosition.y)
end

--- 根据当前位置与路线段，判断是否命中某一段的经过地图集合。
---@param segment table|nil 路线段
---@param currentUiMapID number 当前地图 ID
---@return boolean
local function isSegmentMatchedByTraversedMap(segment, currentUiMapID)
  for _, traversedMapID in ipairs(type(segment) == "table" and type(segment.traversedUiMapIDs) == "table" and segment.traversedUiMapIDs or {}) do
    if tonumber(traversedMapID) == currentUiMapID then
      return true
    end
  end
  return false
end

--- 基于当前位置推导当前步骤、到达状态与偏离状态。
---@param routeResult table|nil 路线结果
---@param routeTarget table|nil 路线目标
---@param locationSnapshot table|nil 当前位置快照
---@return number, boolean, boolean
local function resolveLiveProgress(routeResult, routeTarget, locationSnapshot)
  local segmentList = type(routeResult) == "table" and routeResult.segments or nil -- 路线分段列表
  local totalSteps = type(segmentList) == "table" and #segmentList or 0 -- 路线总段数
  if totalSteps == 0 then
    return 0, false, false
  end

  local currentUiMapID = tonumber(type(locationSnapshot) == "table" and locationSnapshot.currentUiMapID) -- 当前地图 ID
  local targetUiMapID = tonumber(type(routeTarget) == "table" and routeTarget.uiMapID) -- 目标地图 ID
  local currentX = tonumber(type(locationSnapshot) == "table" and locationSnapshot.currentX) -- 当前 X
  local currentY = tonumber(type(locationSnapshot) == "table" and locationSnapshot.currentY) -- 当前 Y
  local targetX = tonumber(type(routeTarget) == "table" and routeTarget.x) -- 目标 X
  local targetY = tonumber(type(routeTarget) == "table" and routeTarget.y) -- 目标 Y

  if currentUiMapID and targetUiMapID and currentUiMapID == targetUiMapID then
    if isNormalizedPosition(currentX, currentY) and isNormalizedPosition(targetX, targetY) then
      local deltaX = currentX - targetX -- 目标 X 偏差
      local deltaY = currentY - targetY -- 目标 Y 偏差
      local distance = math.sqrt(deltaX * deltaX + deltaY * deltaY) -- 当前点与终点的距离
      if distance <= 0.04 then
        return totalSteps, true, false
      end
    else
      return totalSteps, true, false
    end
  end

  if not currentUiMapID then
    return 1, false, false
  end

  for segmentIndex, segment in ipairs(segmentList) do
    local fromUiMapID = tonumber(segment and segment.fromUiMapID) -- 当前段起点地图
    local toUiMapID = tonumber(segment and segment.toUiMapID) -- 当前段终点地图
    local nextSegment = segmentList[segmentIndex + 1] -- 下一段
    local nextFromUiMapID = tonumber(nextSegment and nextSegment.fromUiMapID) -- 下一段起点地图

    if fromUiMapID and currentUiMapID == fromUiMapID then
      return segmentIndex, false, false
    end
    if toUiMapID and currentUiMapID == toUiMapID then
      if nextFromUiMapID and nextFromUiMapID == currentUiMapID then
        return segmentIndex + 1, false, false
      end
      return segmentIndex, false, false
    end
    if isSegmentMatchedByTraversedMap(segment, currentUiMapID) then
      return segmentIndex, false, false
    end
  end

  return 1, false, true
end

--- 构建胶囊状态文案。
---@param routeState table 路线状态
---@return string
local function buildStatusText(routeState)
  if routeState.arrived then
    return getLocaleText("NAVIGATION_ROUTE_WIDGET_STATUS_ARRIVED", "已到达终点")
  end
  if routeState.deviated then
    return getLocaleText("NAVIGATION_ROUTE_WIDGET_STATUS_DEVIATED", "你已偏离路线")
  end
  return getLocaleText("NAVIGATION_ROUTE_WIDGET_STATUS_READY", "按当前路线前进")
end

--- 构建胶囊步骤进度文案。
---@param routeState table 路线状态
---@return string
local function buildStepProgressText(routeState)
  local segmentList = type(routeState.routeResult) == "table" and routeState.routeResult.segments or {} -- 路线分段列表
  local totalSteps = tonumber(routeState.routeResult and routeState.routeResult.totalSteps) or #segmentList -- 总步数
  local stepIndex = math.max(1, math.min(tonumber(routeState.currentStepIndex) or 1, math.max(totalSteps, 1))) -- 当前步骤索引
  return string.format(getLocaleText("NAVIGATION_ROUTE_WIDGET_STEP_FMT", "第%d/%d步"), stepIndex, math.max(totalSteps, 1))
end

--- 构建胶囊起始位置文案。
---@param routeState table 路线状态
---@return string
local function buildStartPositionText(routeState)
  local segmentList = type(routeState.routeResult) == "table" and routeState.routeResult.segments or {} -- 路线分段列表
  local firstSegment = segmentList[1] or nil -- 第一段路线
  local startLocationSnapshot = type(routeState.startLocationSnapshot) == "table" and routeState.startLocationSnapshot or nil -- 规划起点快照
  local fallbackName = buildSegmentMapName(firstSegment, false) -- 起点地图名
  local positionText = buildPositionDisplayText(
    startLocationSnapshot and startLocationSnapshot.currentUiMapID or (firstSegment and firstSegment.fromUiMapID),
    startLocationSnapshot and startLocationSnapshot.currentX,
    startLocationSnapshot and startLocationSnapshot.currentY,
    fallbackName
  ) -- 起始位置文案
  if positionText ~= "" then
    return positionText
  end
  if fallbackName ~= "" then
    return fallbackName
  end
  return getLocaleText("NAVIGATION_ROUTE_WIDGET_START", "起始位置")
end

--- 构建胶囊终点位置文案。
---@param routeState table 路线状态
---@return string
local function buildTargetPositionText(routeState)
  local targetName = buildTargetDisplayName(routeState.routeTarget, routeState.routeResult) -- 终点显示名
  local positionText = buildPositionDisplayText(
    routeState.routeTarget and routeState.routeTarget.uiMapID,
    routeState.routeTarget and routeState.routeTarget.x,
    routeState.routeTarget and routeState.routeTarget.y,
    targetName
  ) -- 终点位置文案
  if positionText ~= "" then
    return positionText
  end
  return extractMapLevelName(targetName)
end

--- 构建胶囊当前位置文案。
---@param routeState table 路线状态
---@param locationSnapshot table|nil 当前位置快照
---@return string
local function buildCurrentPositionText(routeState, locationSnapshot)
  local segmentList = type(routeState.routeResult) == "table" and routeState.routeResult.segments or {} -- 路线分段列表
  local currentSegment = segmentList[routeState.currentStepIndex] or segmentList[1] or nil -- 当前高亮段
  local livePositionText = buildPositionDisplayText(
    locationSnapshot and locationSnapshot.currentUiMapID,
    locationSnapshot and locationSnapshot.currentX,
    locationSnapshot and locationSnapshot.currentY,
    buildSegmentMapName(currentSegment, false)
  ) -- 当前实时位置文案
  if livePositionText ~= "" then
    return livePositionText
  end
  if routeState.arrived then
    return buildTargetPositionText(routeState)
  end
  local fallbackName = buildSegmentMapName(currentSegment, false) -- 当前路线所在地图
  if fallbackName ~= "" then
    return fallbackName
  end
  return buildTargetPositionText(routeState)
end

--- 拼接路线段的经过地图诊断文本。
---@param segment table|nil 路线段
---@return string
local function buildDiagnosticTraversedMapText(segment)
  local textList = {} -- 经过地图文案列表
  local traversedNameList = type(segment) == "table" and segment.traversedUiMapNames or nil -- 路线段经过地图
  for _, mapName in ipairs(type(traversedNameList) == "table" and traversedNameList or {}) do
    local displayName = trimText(mapName) -- 当前地图名
    if displayName ~= "" then
      textList[#textList + 1] = displayName
    end
  end
  if #textList == 0 then
    return "-"
  end
  return table.concat(textList, " -> ")
end

--- 读取路线段诊断端点文本，动作到站侧优先使用到站地图。
---@param segment table|nil 路线段
---@param useDestination boolean 是否读取终点侧
---@return string
local function buildDiagnosticSegmentEndpointText(segment, useDestination)
  if type(segment) ~= "table" then
    return ""
  end
  local modeText = tostring(segment.mode or "") -- 路线方式
  if useDestination and (isTransportMode(modeText) or segment.manualTravel == true) then
    local traversedNameList = type(segment.traversedUiMapNames) == "table" and segment.traversedUiMapNames or nil -- 经过地图列表
    local arrivalMapName = extractMapLevelName(type(traversedNameList) == "table" and traversedNameList[#traversedNameList] or nil) -- 动作到站地图
    if arrivalMapName ~= "" then
      return arrivalMapName
    end
  end
  return trimText(useDestination and (segment.toName or segment.to) or (segment.fromName or segment.from))
end

--- 把路线段背景字段带入诊断模型，便于聊天输出解释来源和条件。
---@param diagnosticSegment table 诊断段
---@param segment table|nil 路线段
local function copyDiagnosticSegmentBackgroundFields(diagnosticSegment, segment)
  if type(diagnosticSegment) ~= "table" or type(segment) ~= "table" then
    return
  end

  diagnosticSegment.source = segment.source or segment.Source
  diagnosticSegment.sourceID = segment.sourceID or segment.SourceID
  diagnosticSegment.routeEdgeIndex = segment.routeEdgeIndex or segment.RouteEdgeIndex
  diagnosticSegment.edgeID = segment.edgeID or segment.EdgeID or segment.id or segment.ID
  diagnosticSegment.originalMode = segment.originalMode or segment.OriginalMode
  diagnosticSegment.manualTravel = segment.manualTravel == true or segment.ManualTravel == true
  diagnosticSegment.abilityTemplateID = segment.abilityTemplateID or segment.AbilityTemplateID
  diagnosticSegment.spellID = segment.spellID or segment.SpellID
  diagnosticSegment.classFile = segment.classFile or segment.ClassFile
  diagnosticSegment.factionRequirement = segment.factionRequirement or segment.FactionRequirement
  diagnosticSegment.playerConditionID = segment.playerConditionID or segment.PlayerConditionID
  diagnosticSegment.fromNodeID = segment.fromNodeID or segment.FromNodeID or segment.from or segment.From
  diagnosticSegment.toNodeID = segment.toNodeID or segment.ToNodeID or segment.to or segment.To
  diagnosticSegment.fromSource = segment.fromSource or segment.FromSource
  diagnosticSegment.fromSourceID = segment.fromSourceID or segment.FromSourceID
  diagnosticSegment.toSource = segment.toSource or segment.ToSource
  diagnosticSegment.toSourceID = segment.toSourceID or segment.ToSourceID
  diagnosticSegment.fromUiMapID = segment.fromUiMapID or segment.FromUiMapID
  diagnosticSegment.toUiMapID = segment.toUiMapID or segment.ToUiMapID
  diagnosticSegment.fromTaxiNodeID = segment.fromTaxiNodeID or segment.FromTaxiNodeID
  diagnosticSegment.toTaxiNodeID = segment.toTaxiNodeID or segment.ToTaxiNodeID
end

--- 构建用于聊天诊断的逐段显示模型。
---@param segmentList table|nil 路线分段列表
---@param evidenceLevel string|nil 路线证据等级
---@return table
local function buildDiagnosticSegmentList(segmentList, evidenceLevel)
  local diagnosticSegmentList = {} -- 逐段诊断显示模型
  for segmentIndex, segment in ipairs(type(segmentList) == "table" and segmentList or {}) do
    local diagnosticSegment = { -- 当前诊断段
      index = segmentIndex,
      mode = tostring(segment and segment.mode or ""),
      fromText = buildDiagnosticSegmentEndpointText(segment, false),
      toText = buildDiagnosticSegmentEndpointText(segment, true),
      traversedMapText = buildDiagnosticTraversedMapText(segment),
      evidenceLevel = evidenceLevel,
    }
    copyDiagnosticSegmentBackgroundFields(diagnosticSegment, segment)
    diagnosticSegmentList[#diagnosticSegmentList + 1] = diagnosticSegment
  end
  return diagnosticSegmentList
end

--- 构建胶囊、展开节点链、历史与聊天诊断共用的显示模型。
---@param routeResult table|nil 路线结果
---@param routeTarget table|nil 路线目标快照
---@param startLocationSnapshot table|nil 规划起点快照
---@param currentLocationSnapshot table|nil 当前实时位置快照
---@return table
buildRouteDisplayModel = function(routeResult, routeTarget, startLocationSnapshot, currentLocationSnapshot)
  local segmentList = type(routeResult) == "table" and routeResult.segments or {} -- 路线分段列表
  local evidenceLevel = type(routeResult) == "table" and routeResult.evidenceLevel or nil -- 路线证据等级
  local stepIndex, arrived, deviated = resolveLiveProgress(routeResult, routeTarget, currentLocationSnapshot) -- 实时进度
  local routeState = {
    routeResult = routeResult,
    routeTarget = routeTarget or {},
    currentStepIndex = stepIndex,
    deviated = deviated,
    arrived = arrived,
    startLocationSnapshot = startLocationSnapshot,
  } -- 临时路线状态
  local nodeList = buildRouteDisplayNodes(routeResult, routeTarget, startLocationSnapshot) -- 玩家可见节点链
  local nodeTextList = {} -- 节点摘要文本列表
  for _, nodeInfo in ipairs(nodeList) do
    local nodeText = trimText(type(nodeInfo) == "table" and nodeInfo.text or nil) -- 当前节点文本
    if nodeText ~= "" then
      nodeTextList[#nodeTextList + 1] = nodeText
    end
  end
  local nodeSummaryText = table.concat(nodeTextList, " -> ") -- 节点摘要文本
  if nodeSummaryText == "" then
    nodeSummaryText = getLocaleText("NAVIGATION_ROUTE_EMPTY", "暂无路线")
  end
  local totalSteps = tonumber(type(routeResult) == "table" and routeResult.totalSteps) or #segmentList -- 总步数
  return {
    totalSteps = totalSteps,
    startPositionText = buildStartPositionText(routeState),
    currentPositionText = buildCurrentPositionText(routeState, currentLocationSnapshot),
    targetPositionText = buildTargetPositionText(routeState),
    nodeList = nodeList,
    nodeSummaryText = nodeSummaryText,
    historySummaryText = string.format("%s步 | %s", tostring(totalSteps), nodeSummaryText),
    diagnosticSegments = buildDiagnosticSegmentList(segmentList, evidenceLevel),
    evidenceLevel = evidenceLevel,
    currentStepIndex = stepIndex,
    arrived = arrived,
    deviated = deviated,
  }
end

--- 刷新精简胶囊文案。
---@param frame table 路线图根 Frame
---@param routeState table 路线状态
---@param displayModel table|nil 统一显示模型
local function refreshCapsuleText(frame, routeState, displayModel)
  frame._capsuleHeaderStatus:SetText(buildStatusText(routeState))
  frame._capsuleHeaderProgress:SetText(buildStepProgressText(routeState))
  frame._capsuleStartLabel:SetText(getLocaleText("NAVIGATION_ROUTE_WIDGET_START", "起始位置"))
  frame._capsuleCurrentLabel:SetText(getLocaleText("NAVIGATION_ROUTE_WIDGET_CURRENT", "当前位置"))
  frame._capsuleTargetLabel:SetText(getLocaleText("NAVIGATION_ROUTE_WIDGET_END", "终点位置"))
  frame._capsuleStartValue:SetText(trimText(type(displayModel) == "table" and displayModel.startPositionText or nil))
  frame._capsuleCurrentValue:SetText(trimText(type(displayModel) == "table" and displayModel.currentPositionText or nil))
  frame._capsuleTargetValue:SetText(trimText(type(displayModel) == "table" and displayModel.targetPositionText or nil))
  if frame._capsuleSummary then
    frame._capsuleSummary:SetText("")
  end
  if frame._capsuleStatus then
    frame._capsuleStatus:SetText("")
  end
end

--- 读取 FontString 的近似宽度。
---@param fontString table|nil 文本对象
---@return number
local function readFontStringWidth(fontString)
  if type(fontString) ~= "table" then
    return 0
  end
  if type(fontString.GetStringWidth) == "function" then
    return tonumber(fontString:GetStringWidth()) or 0
  end
  if type(fontString.GetTextWidth) == "function" then
    return tonumber(fontString:GetTextWidth()) or 0
  end
  return 0
end

--- 将数值限制在给定区间内。
---@param value number 原始值
---@param minValue number 下限
---@param maxValue number 上限
---@return number
local function clampNumber(value, minValue, maxValue)
  local clampedValue = tonumber(value) or tonumber(minValue) or 0 -- 待限制的值
  if clampedValue < minValue then
    return minValue
  end
  if clampedValue > maxValue then
    return maxValue
  end
  return clampedValue
end

--- 测量胶囊三列各自需要的文本宽度。
---@param frame table 路线图根 Frame
---@return number, number, number
local function measureCapsuleColumnWidths(frame)
  local startColumnWidth = math.max(
    DEFAULT_COLUMN_MIN_WIDTH,
    readFontStringWidth(frame._capsuleStartLabel),
    readFontStringWidth(frame._capsuleStartValue)
  ) -- 左列宽度
  local currentColumnWidth = math.max(
    DEFAULT_COLUMN_MIN_WIDTH,
    readFontStringWidth(frame._capsuleCurrentLabel),
    readFontStringWidth(frame._capsuleCurrentValue)
  ) -- 中列宽度
  local targetColumnWidth = math.max(
    DEFAULT_COLUMN_MIN_WIDTH,
    readFontStringWidth(frame._capsuleTargetLabel),
    readFontStringWidth(frame._capsuleTargetValue)
  ) -- 右列宽度
  return startColumnWidth, currentColumnWidth, targetColumnWidth
end

--- 根据当前胶囊文本测量所需宽度。
---@param frame table 路线图根 Frame
---@return number
local function resolveCapsuleWidth(frame)
  local historyButtonWidth = type(frame._historyToggleButton) == "table" and type(frame._historyToggleButton.GetWidth) == "function"
    and (tonumber(frame._historyToggleButton:GetWidth()) or DEFAULT_HISTORY_BUTTON_WIDTH)
    or DEFAULT_HISTORY_BUTTON_WIDTH -- 历史按钮宽度
  local closeButtonWidth = type(frame._closeButton) == "table" and type(frame._closeButton.GetWidth) == "function"
    and (tonumber(frame._closeButton:GetWidth()) or DEFAULT_CLOSE_BUTTON_WIDTH)
    or DEFAULT_CLOSE_BUTTON_WIDTH -- 关闭按钮宽度
  local headerWidth = readFontStringWidth(frame._capsuleHeaderStatus)
    + readFontStringWidth(frame._capsuleHeaderProgress)
    + historyButtonWidth
    + closeButtonWidth
    + 64 -- 标题区总宽度
  local startColumnWidth, currentColumnWidth, targetColumnWidth = measureCapsuleColumnWidths(frame) -- 三列文本宽度
  local bodyWidth = (DEFAULT_COLUMN_OUTER_PADDING * 2)
    + startColumnWidth
    + currentColumnWidth
    + targetColumnWidth
    + (DEFAULT_COLUMN_GAP * 2) -- 三列真实排布后的主体宽度
  return clampNumber(math.ceil(math.max(DEFAULT_WIDGET_WIDTH, headerWidth, bodyWidth)), DEFAULT_WIDGET_WIDTH, MAX_WIDGET_WIDTH)
end

--- 把胶囊三列与分隔线重新对齐到当前宽度。
---@param frame table 路线图根 Frame
---@param resolvedWidth number 当前路线图宽度
local function applyCapsuleColumnLayout(frame, resolvedWidth)
  local capsuleButton = frame._capsuleButton -- 胶囊按钮
  if type(capsuleButton) ~= "table" then
    return
  end
  local safeWidth = tonumber(resolvedWidth) or DEFAULT_WIDGET_WIDTH -- 当前可用宽度
  local startColumnWidth, currentColumnWidth, targetColumnWidth = measureCapsuleColumnWidths(frame) -- 三列文本宽度
  local bandWidth = startColumnWidth + currentColumnWidth + targetColumnWidth + (DEFAULT_COLUMN_GAP * 2) -- 三列内容带宽
  local bandStartX = math.max(math.floor((safeWidth - bandWidth) / 2), DEFAULT_COLUMN_OUTER_PADDING) -- 三列带起点
  local startCenterX = bandStartX + (startColumnWidth / 2) -- 左列中心点
  local currentCenterX = bandStartX + startColumnWidth + DEFAULT_COLUMN_GAP + (currentColumnWidth / 2) -- 中列中心点
  local targetCenterX = bandStartX + startColumnWidth + DEFAULT_COLUMN_GAP + currentColumnWidth + DEFAULT_COLUMN_GAP + (targetColumnWidth / 2) -- 右列中心点
  local leftDividerX = bandStartX + startColumnWidth + math.floor(DEFAULT_COLUMN_GAP / 2) -- 左分隔线 X
  local rightDividerX = bandStartX + startColumnWidth + DEFAULT_COLUMN_GAP + currentColumnWidth + math.floor(DEFAULT_COLUMN_GAP / 2) -- 右分隔线 X

  frame._capsuleStartLabel:ClearAllPoints()
  frame._capsuleStartLabel:SetPoint("TOP", capsuleButton, "TOPLEFT", startCenterX, -38)
  frame._capsuleCurrentLabel:ClearAllPoints()
  frame._capsuleCurrentLabel:SetPoint("TOP", capsuleButton, "TOPLEFT", currentCenterX, -38)
  frame._capsuleTargetLabel:ClearAllPoints()
  frame._capsuleTargetLabel:SetPoint("TOP", capsuleButton, "TOPLEFT", targetCenterX, -38)

  frame._capsuleDividerLeft:ClearAllPoints()
  frame._capsuleDividerLeft:SetPoint("TOPLEFT", capsuleButton, "TOPLEFT", leftDividerX, -34)
  frame._capsuleDividerRight:ClearAllPoints()
  frame._capsuleDividerRight:SetPoint("TOPLEFT", capsuleButton, "TOPLEFT", rightDividerX, -34)
end

--- 按显示节点数计算节点容器所需高度。
---@param displayNodeCount number 可见节点数
---@return number
local function calculateNodeContainerHeight(displayNodeCount)
  local visibleNodeCount = math.max(tonumber(displayNodeCount) or 0, 0) -- 可见节点数
  local requiredHeight = (DEFAULT_NODE_CONTAINER_PADDING * 2)
    + (visibleNodeCount * DEFAULT_NODE_ROW_HEIGHT)
    + (math.max(visibleNodeCount - 1, 0) * DEFAULT_NODE_ROW_GAP) -- 节点区所需高度
  return math.max(requiredHeight, DEFAULT_EXPANDED_HEIGHT - DEFAULT_CAPSULE_HEIGHT - 6)
end

--- 按节点类型选择一个可落地的通用图标。
---@param nodeKind string|nil 节点类型
---@return string
local function getNodeIconTexture(nodeKind)
  if nodeKind == "portal" then
    return "Interface\\Icons\\Spell_Arcane_PortalShattrath"
  end
  if nodeKind == "transport" then
    return "Interface\\Icons\\INV_Misc_Toy_10"
  end
  if nodeKind == "hearthstone" then
    return "Interface\\Icons\\INV_Misc_Rune_01"
  end
  if nodeKind == "teleport" then
    return "Interface\\Icons\\Spell_Arcane_TeleportOrgrimmar"
  end
  if nodeKind == "action" then
    return "Interface\\Icons\\INV_Misc_Note_01"
  end
  return "Interface\\Icons\\INV_Misc_Map_01"
end

--- 根据当前位置推导当前应高亮的显示节点。
---@param displayNodeList table 节点链
---@param routeState table 路线状态
---@param locationSnapshot table|nil 当前位置快照
---@return number
local function resolveActiveDisplayNodeIndex(displayNodeList, routeState, locationSnapshot)
  local currentUiMapID = tonumber(type(locationSnapshot) == "table" and locationSnapshot.currentUiMapID) -- 当前地图 ID
  if currentUiMapID then
    local matchedIndex = nil -- 命中的节点序号
    for nodeIndex, nodeInfo in ipairs(displayNodeList) do
      if tostring(nodeInfo.kind or "") == "map" and tonumber(nodeInfo.uiMapID) == currentUiMapID then
        matchedIndex = nodeIndex
      end
    end
    if matchedIndex then
      return matchedIndex
    end
  end

  local stepIndex = tonumber(type(routeState) == "table" and routeState.currentStepIndex) or 1 -- 当前步骤序号
  if stepIndex < 1 then
    stepIndex = 1
  end
  if stepIndex > #displayNodeList then
    stepIndex = #displayNodeList
  end
  return math.max(stepIndex, 1)
end

--- 创建一个竖向节点行。
---@param parentFrame table 父容器
---@param nodeIndex number 节点序号
---@return table
local function createNodeRow(parentFrame, nodeIndex)
  local rowFrame = CreateFrame("Frame", nil, parentFrame, "BackdropTemplate") -- 节点行容器
  rowFrame:SetSize(DEFAULT_WIDGET_WIDTH - 28, DEFAULT_NODE_ROW_HEIGHT)
  rowFrame:SetPoint("TOPLEFT", parentFrame, "TOPLEFT", 8, -DEFAULT_NODE_CONTAINER_PADDING - ((nodeIndex - 1) * (DEFAULT_NODE_ROW_HEIGHT + DEFAULT_NODE_ROW_GAP)))
  if type(rowFrame.SetBackdrop) == "function" then
    rowFrame:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8x8",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true,
      tileSize = 8,
      edgeSize = 10,
      insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    rowFrame:SetBackdropColor(0.08, 0.07, 0.06, 0.92)
    rowFrame:SetBackdropBorderColor(0.52, 0.41, 0.2, 0.88)
  end

  local activeGlow = rowFrame:CreateTexture(nil, "BACKGROUND") -- 当前节点高亮底色
  activeGlow:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", 3, -3)
  activeGlow:SetPoint("BOTTOMRIGHT", rowFrame, "BOTTOMRIGHT", -3, 3)
  activeGlow:SetColorTexture(0.86, 0.73, 0.3, 0.14)
  activeGlow:Hide()
  rowFrame._activeGlow = activeGlow

  local connectorTop = rowFrame:CreateTexture(nil, "BACKGROUND") -- 上方连线
  connectorTop:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", 14, 0)
  connectorTop:SetSize(3, math.floor(DEFAULT_NODE_ROW_HEIGHT / 2))
  connectorTop:SetColorTexture(0.72, 0.58, 0.3, 0.95)
  rowFrame._connectorTop = connectorTop

  local connectorBottom = rowFrame:CreateTexture(nil, "BACKGROUND") -- 下方连线
  connectorBottom:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", 14, -math.floor(DEFAULT_NODE_ROW_HEIGHT / 2))
  connectorBottom:SetSize(3, math.floor(DEFAULT_NODE_ROW_HEIGHT / 2))
  connectorBottom:SetColorTexture(0.72, 0.58, 0.3, 0.95)
  rowFrame._connectorBottom = connectorBottom

  local nodeMarker = rowFrame:CreateTexture(nil, "ARTWORK") -- 节点圆点标记
  nodeMarker:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", 9, -math.floor((DEFAULT_NODE_ROW_HEIGHT - 12) / 2))
  nodeMarker:SetSize(12, 12)
  nodeMarker:SetColorTexture(0.82, 0.67, 0.29, 1)
  rowFrame._nodeMarker = nodeMarker

  local iconTexture = rowFrame:CreateTexture(nil, "ARTWORK") -- 节点类型图标
  iconTexture:SetPoint("LEFT", rowFrame, "LEFT", 28, 0)
  iconTexture:SetSize(18, 18)
  rowFrame._iconTexture = iconTexture

  local labelText = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight") -- 节点标签
  labelText:SetPoint("TOPLEFT", iconTexture, "TOPRIGHT", 12, -2)
  labelText:SetPoint("TOPRIGHT", rowFrame, "TOPRIGHT", -12, -2)
  labelText:SetJustifyH("CENTER")
  labelText:SetWordWrap(false)
  labelText:SetText("")
  rowFrame._labelText = labelText

  local detailText = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") -- 起终点坐标明细
  detailText:SetPoint("TOPLEFT", labelText, "BOTTOMLEFT", 0, -3)
  detailText:SetPoint("TOPRIGHT", labelText, "BOTTOMRIGHT", 0, -3)
  detailText:SetJustifyH("CENTER")
  detailText:SetWordWrap(false)
  detailText:SetText("")
  detailText:Hide()
  rowFrame._detailText = detailText
  return rowFrame
end

--- 刷新展开态竖向节点链。
---@param frame table 路线图根 Frame
---@param routeState table 路线状态
---@param displayModel table|nil 统一显示模型
---@param locationSnapshot table|nil 当前位置快照
local function refreshTimelineText(frame, routeState, displayModel, locationSnapshot)
  local displayNodeList = type(displayModel) == "table" and type(displayModel.nodeList) == "table" and displayModel.nodeList or {} -- 玩家可见节点链
  local activeNodeIndex = resolveActiveDisplayNodeIndex(displayNodeList, routeState, locationSnapshot) -- 当前高亮节点
  frame._timelineText:SetText("")
  frame._nodeRows = frame._nodeRows or {}
  frame._resolvedNodeContainerHeight = calculateNodeContainerHeight(#displayNodeList)

  for nodeIndex, nodeInfo in ipairs(displayNodeList) do
    local rowFrame = frame._nodeRows[nodeIndex] -- 当前节点行
    if not rowFrame then
      rowFrame = createNodeRow(frame._nodeListContainer, nodeIndex)
      frame._nodeRows[nodeIndex] = rowFrame
    end
    rowFrame:SetWidth(math.max((tonumber(frame._resolvedWidgetWidth) or DEFAULT_WIDGET_WIDTH) - 28, DEFAULT_WIDGET_WIDTH - 28))
    local isActiveNode = nodeIndex == activeNodeIndex -- 当前节点是否为高亮节点
    local detailText = trimText(nodeInfo.detailText) -- 当前节点明细
    rowFrame._iconTexture:SetTexture(getNodeIconTexture(nodeInfo.kind))
    rowFrame._labelText:SetText(nodeInfo.text)
    rowFrame._detailText:SetText(detailText)
    rowFrame._detailText:SetShown(detailText ~= "")
    rowFrame._activeGlow:SetShown(isActiveNode)
    rowFrame._connectorTop:SetShown(nodeIndex > 1)
    rowFrame._connectorBottom:SetShown(nodeIndex < #displayNodeList)
    rowFrame._nodeMarker:SetShown(true)
    rowFrame._nodeMarker:SetColorTexture(
      isActiveNode and 0.95 or 0.82,
      isActiveNode and 0.82 or 0.67,
      isActiveNode and 0.39 or 0.29,
      1
    )
    if type(rowFrame.SetBackdropColor) == "function" then
      if isActiveNode then
        rowFrame:SetBackdropColor(0.16, 0.12, 0.06, 0.96)
        rowFrame:SetBackdropBorderColor(0.9, 0.74, 0.31, 0.96)
      else
        rowFrame:SetBackdropColor(0.08, 0.07, 0.06, 0.92)
        rowFrame:SetBackdropBorderColor(0.52, 0.41, 0.2, 0.88)
      end
    end
    rowFrame:Show()
  end

  for nodeIndex = #displayNodeList + 1, #frame._nodeRows do
    local rowFrame = frame._nodeRows[nodeIndex] -- 多余的旧节点行
    if rowFrame then
      rowFrame._labelText:SetText("")
      rowFrame._detailText:SetText("")
      rowFrame._detailText:Hide()
      rowFrame._activeGlow:Hide()
      rowFrame:Hide()
    end
  end
end

--- 刷新历史记录按钮区。
---@param frame table 路线图根 Frame
local function refreshHistoryButtons(frame)
  local routeHistory = getRouteHistory() -- 最近路线历史
  local hasHistory = false -- 是否存在可显示历史

  frame._historyTitle:SetText(getLocaleText("NAVIGATION_ROUTE_WIDGET_HISTORY_TITLE", "最近路线"))
  for historyIndex, buttonFrame in ipairs(frame._historyButtons) do
    local entry = routeHistory[historyIndex] -- 当前历史项
    if type(entry) == "table" then
      local titleText = trimText(entry.targetName) -- 按钮目标名
      if titleText == "" then
        titleText = string.format("UiMap %s", tostring(entry.targetUiMapID or "?"))
      end
      local summaryText = trimText(entry.summaryText) -- 历史一行摘要
      buttonFrame._historyIndex = historyIndex
      buttonFrame:SetText("")
      buttonFrame._titleText:SetText(titleText)
      buttonFrame._summaryText:SetText(summaryText)
      buttonFrame:Show()
      hasHistory = true
    else
      buttonFrame._historyIndex = nil
      buttonFrame:SetText("")
      buttonFrame._titleText:SetText("")
      buttonFrame._summaryText:SetText("")
      buttonFrame:Hide()
    end
  end

  if hasHistory then
    frame._historyEmptyText:Hide()
  else
    frame._historyEmptyText:SetText(getLocaleText("NAVIGATION_ROUTE_WIDGET_HISTORY_EMPTY", "暂无历史路线"))
    frame._historyEmptyText:Show()
  end
end

--- 应用历史抽屉展开 / 收起状态。
---@param frame table 路线图根 Frame
---@param isExpanded boolean 是否展开
local function applyHistoryDrawerState(frame, isExpanded)
  local shouldExpand = isExpanded == true -- 当前是否展开历史抽屉
  setRouteHistoryExpanded(shouldExpand)
  if shouldExpand then
    frame._historyDrawer:Show()
  else
    frame._historyDrawer:Hide()
  end
end

--- 应用展开 / 收起状态到当前路线图。
---@param frame table 路线图根 Frame
---@param isExpanded boolean 是否展开
local function applyExpandedState(frame, isExpanded)
  local shouldExpand = isExpanded == true -- 当前是否展开
  local resolvedWidth = tonumber(frame._resolvedWidgetWidth) or DEFAULT_WIDGET_WIDTH -- 当前路线图宽度
  local nodeContainerHeight = tonumber(frame._resolvedNodeContainerHeight) or (DEFAULT_EXPANDED_HEIGHT - DEFAULT_CAPSULE_HEIGHT - 6) -- 节点容器高度
  local expandedHeight = DEFAULT_CAPSULE_HEIGHT + 6 + nodeContainerHeight -- 展开态总高度
  setRouteWidgetExpanded(shouldExpand)
  frame._expandedContent:SetHeight(nodeContainerHeight)
  frame._nodeListContainer:SetHeight(nodeContainerHeight)
  if frame._historyDrawer then
    frame._historyDrawer:SetHeight(math.max(420, expandedHeight))
  end

  if shouldExpand then
    frame:SetSize(resolvedWidth, expandedHeight)
    frame._expandedContent:Show()
  else
    frame:SetSize(resolvedWidth, DEFAULT_CAPSULE_HEIGHT)
    frame._expandedContent:Hide()
  end
end

--- 刷新整个路线图组件。
---@param locationSnapshot table|nil 当前位置快照
local function refreshRouteBar(locationSnapshot)
  if not routeBarFrame or not activeRouteState then
    return
  end
  local displayModel = buildRouteDisplayModel(
    activeRouteState.routeResult,
    activeRouteState.routeTarget,
    activeRouteState.startLocationSnapshot,
    locationSnapshot
  ) -- 当前统一显示模型
  activeRouteState.displayModel = displayModel
  refreshCapsuleText(routeBarFrame, activeRouteState, displayModel)
  routeBarFrame._resolvedWidgetWidth = resolveCapsuleWidth(routeBarFrame)
  applyCapsuleColumnLayout(routeBarFrame, routeBarFrame._resolvedWidgetWidth)
  refreshTimelineText(routeBarFrame, activeRouteState, displayModel, locationSnapshot)
  refreshHistoryButtons(routeBarFrame)
  applyExpandedState(routeBarFrame, getRouteWidgetExpanded())
  applyHistoryDrawerState(routeBarFrame, getRouteHistoryExpanded())
end

--- 读取光标位置并转换到 UIParent 坐标系，避免 UI 缩放下拖动位移失真。
---@return number|nil, number|nil
local function getScaledCursorPosition()
  if type(GetCursorPosition) ~= "function" then
    return nil, nil
  end
  local cursorX, cursorY = GetCursorPosition() -- 物理像素光标坐标
  local parentScale = 1 -- UIParent 有效缩放
  if UIParent and type(UIParent.GetEffectiveScale) == "function" then
    parentScale = tonumber(UIParent:GetEffectiveScale()) or 1
  end
  if parentScale == 0 then
    parentScale = 1
  end
  local scaledX = tonumber(cursorX) and tonumber(cursorX) / parentScale or nil -- UI 坐标 X
  local scaledY = tonumber(cursorY) and tonumber(cursorY) / parentScale or nil -- UI 坐标 Y
  return scaledX, scaledY
end

--- 根据当前光标位置更新拖动中的路线图位置。
local function updateDragPosition()
  if not routeBarFrame or type(routeBarFrame._dragState) ~= "table" then
    return
  end
  local dragState = routeBarFrame._dragState -- 当前拖动状态
  local cursorX, cursorY = getScaledCursorPosition() -- 当前 UI 坐标系光标位置
  if not cursorX or not cursorY then
    return
  end
  local deltaX = tonumber(cursorX) - tonumber(dragState.startCursorX or 0) -- 光标 X 位移
  local deltaY = tonumber(cursorY) - tonumber(dragState.startCursorY or 0) -- 光标 Y 位移
  if not deltaX or not deltaY then
    return
  end

  setRouteWidgetPosition({
    point = dragState.point,
    x = tonumber(dragState.startX or 0) + deltaX,
    y = tonumber(dragState.startY or 0) + deltaY,
  })
  dragState.didMove = math.abs(deltaX) > 0 or math.abs(deltaY) > 0
  applyWidgetPosition(routeBarFrame)
end

--- 开始拖动路线图组件。
local function startWidgetDrag()
  if not routeBarFrame then
    return
  end
  local widgetPosition = getRouteWidgetPosition() -- 当前组件位置
  local cursorX, cursorY = getScaledCursorPosition() -- 当前 UI 坐标系光标位置
  if not cursorX or not cursorY then
    return
  end
  routeBarFrame._dragState = {
    point = widgetPosition.point,
    startX = widgetPosition.x,
    startY = widgetPosition.y,
    startCursorX = tonumber(cursorX) or 0,
    startCursorY = tonumber(cursorY) or 0,
    didMove = false,
  }
end

--- 结束拖动路线图组件。
local function stopWidgetDrag()
  if not routeBarFrame then
    return
  end
  updateDragPosition()
  local dragState = routeBarFrame._dragState -- 当前拖动状态
  routeBarFrame._dragState = nil
  if type(dragState) == "table" and dragState.didMove then
    routeBarFrame._suppressNextClick = true
  end
end

--- 创建最近历史按钮。
---@param parentFrame table 父容器
---@param historyIndex number 历史序号
---@return table
local function createHistoryButton(parentFrame, historyIndex)
  local buttonFrame = CreateFrame("Button", nil, parentFrame, "UIPanelButtonTemplate") -- 历史路线按钮
  buttonFrame:SetSize(DEFAULT_HISTORY_DRAWER_WIDTH - 24, 34)
  buttonFrame:SetPoint("TOPLEFT", parentFrame, "TOPLEFT", 12, -36 - ((historyIndex - 1) * 38))
  buttonFrame:SetText("")
  buttonFrame:Hide()

  local titleText = buttonFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight") -- 历史项标题
  titleText:SetPoint("TOPLEFT", buttonFrame, "TOPLEFT", 8, -6)
  titleText:SetPoint("TOPRIGHT", buttonFrame, "TOPRIGHT", -8, -6)
  titleText:SetJustifyH("LEFT")
  titleText:SetWordWrap(false)
  titleText:SetText("")
  buttonFrame._titleText = titleText

  local summaryText = buttonFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") -- 历史项摘要
  summaryText:SetPoint("TOPLEFT", titleText, "BOTTOMLEFT", 0, -4)
  summaryText:SetPoint("TOPRIGHT", titleText, "BOTTOMRIGHT", 0, -4)
  summaryText:SetJustifyH("LEFT")
  summaryText:SetWordWrap(false)
  summaryText:SetText("")
  buttonFrame._summaryText = summaryText

  buttonFrame:SetScript("OnClick", function(self)
    if type(self._historyIndex) == "number" then
      RouteBar.TriggerHistoryEntry(self._historyIndex)
    end
  end)
  return buttonFrame
end

--- 确保路线图根 Frame 已创建。
---@return table|nil
local function ensureRouteBarFrame()
  if routeBarFrame then
    return routeBarFrame
  end
  if not UIParent or type(CreateFrame) ~= "function" then
    return nil
  end

  routeBarFrame = CreateFrame("Frame", "AzerothCompanionNavigationRouteBar", UIParent, "BackdropTemplate")
  routeBarFrame:SetSize(DEFAULT_WIDGET_WIDTH, DEFAULT_CAPSULE_HEIGHT)
  routeBarFrame:SetFrameStrata("DIALOG")
  routeBarFrame:EnableMouse(true)
  routeBarFrame:Hide()
  routeBarFrame:SetScript("OnUpdate", function(self, elapsed)
    if type(self._dragState) == "table" then
      updateDragPosition()
    end
    if not activeRouteState then
      return
    end
    self._elapsedSeconds = tonumber(self._elapsedSeconds) or 0
    self._elapsedSeconds = self._elapsedSeconds + (tonumber(elapsed) or 0)
    if self._elapsedSeconds < DEFAULT_REFRESH_INTERVAL then
      return
    end
    self._elapsedSeconds = 0
    RouteBar.RefreshLiveState()
  end)
  applyWidgetPosition(routeBarFrame)

  if type(routeBarFrame.SetBackdrop) == "function" then
    routeBarFrame:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true,
      tileSize = 16,
      edgeSize = 12,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    routeBarFrame:SetBackdropColor(0, 0, 0, 0.85)
    routeBarFrame:SetBackdropBorderColor(0.78, 0.64, 0.31, 0.9)
  end

  local capsuleButton = CreateFrame("Button", nil, routeBarFrame, "BackdropTemplate") -- 可点击精简胶囊
  capsuleButton:SetPoint("TOPLEFT", routeBarFrame, "TOPLEFT", 0, 0)
  capsuleButton:SetPoint("TOPRIGHT", routeBarFrame, "TOPRIGHT", 0, 0)
  capsuleButton:SetHeight(DEFAULT_CAPSULE_HEIGHT)
  capsuleButton:EnableMouse(true)
  capsuleButton:RegisterForClicks("LeftButtonUp")
  capsuleButton:RegisterForDrag("LeftButton")
  capsuleButton:SetScript("OnClick", function()
    if routeBarFrame._suppressNextClick then
      routeBarFrame._suppressNextClick = false
      return
    end
    RouteBar.ToggleExpanded()
  end)
  capsuleButton:SetScript("OnDragStart", startWidgetDrag)
  capsuleButton:SetScript("OnDragStop", stopWidgetDrag)
  routeBarFrame._capsuleButton = capsuleButton

  local closeButton = CreateFrame("Button", nil, capsuleButton, "UIPanelButtonTemplate") -- 路线图关闭按钮
  closeButton:SetSize(DEFAULT_CLOSE_BUTTON_WIDTH, DEFAULT_HEADER_BUTTON_HEIGHT)
  closeButton:SetPoint("TOPRIGHT", capsuleButton, "TOPRIGHT", -10, -8)
  closeButton:SetText(getLocaleText("NAVIGATION_ROUTE_WIDGET_CLOSE_BUTTON", "关闭"))
  closeButton:SetScript("OnClick", function()
    RouteBar.HideWidget()
  end)
  routeBarFrame._closeButton = closeButton

  local historyToggleButton = CreateFrame("Button", nil, capsuleButton, "UIPanelButtonTemplate") -- 历史抽屉开关按钮
  historyToggleButton:SetSize(DEFAULT_HISTORY_BUTTON_WIDTH, DEFAULT_HEADER_BUTTON_HEIGHT)
  historyToggleButton:SetPoint("TOPRIGHT", closeButton, "TOPLEFT", -6, 0)
  historyToggleButton:SetText(getLocaleText("NAVIGATION_ROUTE_WIDGET_HISTORY_BUTTON", "最近路线"))
  historyToggleButton:SetScript("OnClick", function()
    RouteBar.ToggleHistoryExpanded()
  end)
  routeBarFrame._historyToggleButton = historyToggleButton

  local capsuleHeaderStatus = capsuleButton:CreateFontString(nil, "OVERLAY", "GameFontHighlight") -- 胶囊标题状态
  capsuleHeaderStatus:SetPoint("TOPLEFT", capsuleButton, "TOPLEFT", 12, -10)
  capsuleHeaderStatus:SetPoint("TOPRIGHT", historyToggleButton, "TOPLEFT", -10, 0)
  capsuleHeaderStatus:SetJustifyH("LEFT")
  capsuleHeaderStatus:SetWordWrap(false)
  capsuleHeaderStatus:SetText("")
  routeBarFrame._capsuleHeaderStatus = capsuleHeaderStatus

  local capsuleHeaderProgress = capsuleButton:CreateFontString(nil, "OVERLAY", "GameFontHighlight") -- 胶囊标题进度
  capsuleHeaderProgress:SetPoint("TOPRIGHT", historyToggleButton, "TOPLEFT", -10, 0)
  capsuleHeaderProgress:SetJustifyH("RIGHT")
  capsuleHeaderProgress:SetWordWrap(false)
  capsuleHeaderProgress:SetText("")
  routeBarFrame._capsuleHeaderProgress = capsuleHeaderProgress

  local capsuleSummary = capsuleButton:CreateFontString(nil, "OVERLAY", "GameFontHighlight") -- 胶囊主摘要
  capsuleSummary:SetPoint("TOPLEFT", capsuleButton, "TOPLEFT", 12, -8)
  capsuleSummary:SetPoint("TOPRIGHT", capsuleButton, "TOPRIGHT", -12, -8)
  capsuleSummary:SetJustifyH("LEFT")
  capsuleSummary:SetWordWrap(false)
  capsuleSummary:SetText("")
  routeBarFrame._capsuleSummary = capsuleSummary

  local capsuleStatus = capsuleButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") -- 胶囊状态摘要
  capsuleStatus:SetPoint("TOPLEFT", capsuleSummary, "BOTTOMLEFT", 0, -6)
  capsuleStatus:SetPoint("TOPRIGHT", capsuleSummary, "BOTTOMRIGHT", 0, -6)
  capsuleStatus:SetJustifyH("LEFT")
  capsuleStatus:SetWordWrap(false)
  capsuleStatus:SetText("")
  routeBarFrame._capsuleStatus = capsuleStatus

  local function createCapsuleColumn(anchorPoint, offsetX)
    local labelText = capsuleButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall") -- 胶囊列标题
    labelText:SetPoint(anchorPoint, capsuleButton, anchorPoint, offsetX, -38)
    labelText:SetJustifyH("CENTER")
    labelText:SetWordWrap(false)
    labelText:SetText("")

    local valueText = capsuleButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") -- 胶囊列值
    valueText:SetPoint("TOP", labelText, "BOTTOM", 0, -4)
    valueText:SetJustifyH("CENTER")
    valueText:SetWordWrap(false)
    valueText:SetText("")
    return labelText, valueText
  end

  routeBarFrame._capsuleStartLabel, routeBarFrame._capsuleStartValue = createCapsuleColumn("TOPLEFT", 48)
  routeBarFrame._capsuleCurrentLabel, routeBarFrame._capsuleCurrentValue = createCapsuleColumn("TOP", 0)
  routeBarFrame._capsuleTargetLabel, routeBarFrame._capsuleTargetValue = createCapsuleColumn("TOPRIGHT", -48)

  local capsuleDividerLeft = capsuleButton:CreateTexture(nil, "BORDER") -- 左中分隔线
  capsuleDividerLeft:SetPoint("TOP", capsuleButton, "TOP", -70, -34)
  capsuleDividerLeft:SetSize(1, 40)
  capsuleDividerLeft:SetColorTexture(0.78, 0.64, 0.31, 0.72)
  routeBarFrame._capsuleDividerLeft = capsuleDividerLeft

  local capsuleDividerRight = capsuleButton:CreateTexture(nil, "BORDER") -- 中右分隔线
  capsuleDividerRight:SetPoint("TOP", capsuleButton, "TOP", 70, -34)
  capsuleDividerRight:SetSize(1, 40)
  capsuleDividerRight:SetColorTexture(0.78, 0.64, 0.31, 0.72)
  routeBarFrame._capsuleDividerRight = capsuleDividerRight

  local expandedContent = CreateFrame("Frame", nil, routeBarFrame, "BackdropTemplate") -- 展开态内容容器
  expandedContent:SetPoint("TOPLEFT", capsuleButton, "BOTTOMLEFT", 0, -6)
  expandedContent:SetPoint("TOPRIGHT", capsuleButton, "BOTTOMRIGHT", 0, -6)
  expandedContent:SetHeight(DEFAULT_EXPANDED_HEIGHT - DEFAULT_CAPSULE_HEIGHT - 6)
  expandedContent:Hide()
  routeBarFrame._expandedContent = expandedContent

  local timelineText = expandedContent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") -- 时间线文本
  timelineText:SetPoint("TOPLEFT", expandedContent, "TOPLEFT", 0, 0)
  timelineText:SetJustifyH("LEFT")
  timelineText:SetText("")
  routeBarFrame._timelineText = timelineText

  local nodeListContainer = CreateFrame("Frame", nil, expandedContent, "BackdropTemplate") -- 节点链容器
  nodeListContainer:SetPoint("TOPLEFT", expandedContent, "TOPLEFT", 0, 0)
  nodeListContainer:SetPoint("TOPRIGHT", expandedContent, "TOPRIGHT", 0, 0)
  nodeListContainer:SetHeight(DEFAULT_EXPANDED_HEIGHT - DEFAULT_CAPSULE_HEIGHT - 6)
  routeBarFrame._nodeListContainer = nodeListContainer
  routeBarFrame._nodeRows = {}

  local historyDrawer = CreateFrame("Frame", nil, routeBarFrame, "BackdropTemplate") -- 侧贴历史抽屉
  historyDrawer:SetPoint("TOPLEFT", routeBarFrame, "TOPRIGHT", 8, 0)
  historyDrawer:SetSize(DEFAULT_HISTORY_DRAWER_WIDTH, 420)
  historyDrawer:Hide()
  routeBarFrame._historyDrawer = historyDrawer
  if type(historyDrawer.SetBackdrop) == "function" then
    historyDrawer:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true,
      tileSize = 16,
      edgeSize = 12,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    historyDrawer:SetBackdropColor(0.05, 0.04, 0.03, 0.92)
    historyDrawer:SetBackdropBorderColor(0.78, 0.64, 0.31, 0.88)
  end

  local historyTitle = historyDrawer:CreateFontString(nil, "OVERLAY", "GameFontNormal") -- 历史标题
  historyTitle:SetPoint("TOPLEFT", historyDrawer, "TOPLEFT", 12, -12)
  historyTitle:SetPoint("TOPRIGHT", historyDrawer, "TOPRIGHT", -12, -12)
  historyTitle:SetJustifyH("LEFT")
  historyTitle:SetText("")
  routeBarFrame._historyTitle = historyTitle

  local historyEmptyText = historyDrawer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") -- 空历史提示
  historyEmptyText:SetPoint("TOPLEFT", historyTitle, "BOTTOMLEFT", 0, -10)
  historyEmptyText:SetPoint("TOPRIGHT", historyDrawer, "TOPRIGHT", -12, -10)
  historyEmptyText:SetJustifyH("LEFT")
  historyEmptyText:SetWordWrap(true)
  historyEmptyText:SetText("")
  routeBarFrame._historyEmptyText = historyEmptyText

  routeBarFrame._historyButtons = {}
  for historyIndex = 1, DEFAULT_HISTORY_LIMIT do
    routeBarFrame._historyButtons[historyIndex] = createHistoryButton(historyDrawer, historyIndex)
  end

  refreshHistoryButtons(routeBarFrame)
  applyExpandedState(routeBarFrame, getRouteWidgetExpanded())
  applyHistoryDrawerState(routeBarFrame, getRouteHistoryExpanded())
  return routeBarFrame
end

--- 构建可显示的路线摘要文本。
---@param routeResult table|nil 路线结果
---@return string
function RouteBar.BuildRouteText(routeResult)
  return buildRouteText(routeResult)
end

--- 复用 RouteBar 的地图与坐标格式化规则。
---@param uiMapID any 地图 ID
---@param pointX any 坐标 X
---@param pointY any 坐标 Y
---@param fallbackText any 兜底名称
---@return string
function RouteBar.BuildPositionDisplayText(uiMapID, pointX, pointY, fallbackText)
  return buildPositionDisplayText(uiMapID, pointX, pointY, fallbackText)
end

--- 复用 RouteBar 的节点链摘要规则，仅返回节点路径文本。
---@param routeResult table|nil 路线结果
---@param routeTarget table|nil 路线目标
---@param startLocationSnapshot table|nil 规划起点快照
---@return string
function RouteBar.BuildRouteNodePathText(routeResult, routeTarget, startLocationSnapshot)
  return buildRouteNodePathText(routeResult, routeTarget, startLocationSnapshot)
end

--- 构建胶囊、展开节点链、历史摘要与聊天诊断共用的显示模型。
---@param routeResult table|nil 路线结果
---@param routeTarget table|nil 路线目标快照
---@param startLocationSnapshot table|nil 规划起点快照
---@param currentLocationSnapshot table|nil 当前实时位置快照
---@return table
function RouteBar.BuildRouteDisplayModel(routeResult, routeTarget, startLocationSnapshot, currentLocationSnapshot)
  return buildRouteDisplayModel(routeResult, routeTarget, startLocationSnapshot, currentLocationSnapshot)
end

--- 切换展开 / 收起状态。
function RouteBar.ToggleExpanded()
  local frame = ensureRouteBarFrame() -- 路线图根 Frame
  if not frame then
    return
  end
  applyExpandedState(frame, not getRouteWidgetExpanded())
end

--- 切换历史抽屉展开 / 收起状态。
function RouteBar.ToggleHistoryExpanded()
  local frame = ensureRouteBarFrame() -- 路线图根 Frame
  if not frame then
    return
  end
  applyHistoryDrawerState(frame, not getRouteHistoryExpanded())
end

--- 真正执行一条历史记录的重规划。
---@param historyEntry table|nil 历史记录项
local function replanHistoryEntry(historyEntry)
  local worldMap = AzerothCompanion.Modules.Navigation and AzerothCompanion.Modules.Navigation.WorldMap or nil -- 世界地图入口模块
  if type(historyEntry) ~= "table" or type(worldMap) ~= "table" or type(worldMap.PlanRouteToTarget) ~= "function" then
    return
  end
  worldMap.PlanRouteToTarget({
    uiMapID = tonumber(historyEntry.targetUiMapID) or 0,
    x = tonumber(historyEntry.targetX) or 0,
    y = tonumber(historyEntry.targetY) or 0,
    name = trimText(historyEntry.targetName),
  })
end

--- 确保历史重规划确认弹框定义已注册。
---@return table|nil
local function ensureHistoryConfirmDialog()
  if type(StaticPopupDialogs) ~= "table" then
    return nil
  end
  local dialogDef = StaticPopupDialogs[HISTORY_CONFIRM_DIALOG_KEY] -- 已注册弹框定义
  if type(dialogDef) ~= "table" then
    dialogDef = {}
    StaticPopupDialogs[HISTORY_CONFIRM_DIALOG_KEY] = dialogDef
  end
  dialogDef.text = getLocaleText("NAVIGATION_ROUTE_WIDGET_HISTORY_CONFIRM", "是否重新规划到%s？")
  dialogDef.button1 = rawget(_G, "ACCEPT") or "确认"
  dialogDef.button2 = rawget(_G, "CANCEL") or "取消"
  dialogDef.OnAccept = function(_, dataObject)
    replanHistoryEntry(dataObject)
  end
  dialogDef.OnCancel = function() end
  dialogDef.hideOnEscape = 1
  dialogDef.whileDead = 1
  return dialogDef
end

--- 触发一条历史记录的重规划。
---@param historyIndex number 历史序号（1 为最近一次）
function RouteBar.TriggerHistoryEntry(historyIndex)
  local routeHistory = getRouteHistory() -- 最近路线历史
  local historyEntry = routeHistory[historyIndex] -- 历史记录项
  if type(historyEntry) ~= "table" then
    return
  end

  local dialogDef = ensureHistoryConfirmDialog() -- 历史重规划确认弹框
  if type(dialogDef) == "table" and type(StaticPopup_Show) == "function" then
    StaticPopup_Show(
      HISTORY_CONFIRM_DIALOG_KEY,
      trimText(historyEntry.targetName),
      getLocaleText("NAVIGATION_ROUTE_WIDGET_HISTORY_CONFIRM_DETAIL", "将以你的当前位置为起点重新规划。"),
      historyEntry
    )
    return
  end
  replanHistoryEntry(historyEntry)
end

--- 显示并刷新当前路线。
---@param routeResult table|nil 路线结果
---@param routeTarget table|nil 路线目标快照
function RouteBar.ShowRoute(routeResult, routeTarget)
  local frame = ensureRouteBarFrame() -- 路线图根 Frame
  local segmentList = type(routeResult) == "table" and routeResult.segments or nil -- 路线分段列表
  local startLocationSnapshot = getCurrentLocationSnapshot() -- 规划起点快照
  if not frame or type(segmentList) ~= "table" or #segmentList == 0 then
    return
  end

  activeRouteState = {
    routeResult = routeResult,
    routeTarget = routeTarget or {},
    currentStepIndex = 1,
    deviated = false,
    arrived = false,
    startLocationSnapshot = startLocationSnapshot,
  }
  applyWidgetPosition(frame)
  pushRouteHistory(routeTarget, routeResult, startLocationSnapshot)
  frame._elapsedSeconds = 0
  frame:Show()
  RouteBar.RefreshLiveState()
end

--- 根据当前角色位置刷新路线图状态。
function RouteBar.RefreshLiveState()
  if not activeRouteState then
    return
  end
  local locationSnapshot = getCurrentLocationSnapshot() -- 当前角色位置快照
  if type(activeRouteState.startLocationSnapshot) ~= "table" and type(locationSnapshot) == "table" then
    activeRouteState.startLocationSnapshot = copyLocationSnapshot(locationSnapshot)
  end
  local stepIndex, arrived, deviated = resolveLiveProgress(activeRouteState.routeResult, activeRouteState.routeTarget, locationSnapshot) -- 当前步骤状态
  activeRouteState.currentStepIndex = stepIndex
  activeRouteState.arrived = arrived
  activeRouteState.deviated = deviated
  refreshRouteBar(locationSnapshot)
end

--- 只隐藏路线图界面，不清除当前路线与历史记录。
function RouteBar.HideWidget()
  if routeBarFrame then
    routeBarFrame._dragState = nil
    routeBarFrame._suppressNextClick = false
    routeBarFrame:Hide()
  end
end

--- 清除并隐藏当前路线。
function RouteBar.ClearRoute()
  activeRouteState = nil
  if routeBarFrame then
    routeBarFrame._elapsedSeconds = 0
    routeBarFrame._dragState = nil
    routeBarFrame._suppressNextClick = false
    if routeBarFrame._capsuleSummary then
      routeBarFrame._capsuleSummary:SetText("")
    end
    if routeBarFrame._capsuleStatus then
      routeBarFrame._capsuleStatus:SetText("")
    end
    if routeBarFrame._capsuleHeaderStatus then
      routeBarFrame._capsuleHeaderStatus:SetText("")
    end
    if routeBarFrame._capsuleHeaderProgress then
      routeBarFrame._capsuleHeaderProgress:SetText("")
    end
    if routeBarFrame._capsuleStartValue then
      routeBarFrame._capsuleStartValue:SetText("")
    end
    if routeBarFrame._capsuleCurrentValue then
      routeBarFrame._capsuleCurrentValue:SetText("")
    end
    if routeBarFrame._capsuleTargetValue then
      routeBarFrame._capsuleTargetValue:SetText("")
    end
    if routeBarFrame._timelineText then
      routeBarFrame._timelineText:SetText("")
    end
    if routeBarFrame._historyDrawer then
      routeBarFrame._historyDrawer:Hide()
    end
    routeBarFrame:Hide()
  end
end

--- 获取当前路径图 Frame，供测试或模块内部刷新使用。
---@return table|nil
function RouteBar.GetFrame()
  return routeBarFrame
end
