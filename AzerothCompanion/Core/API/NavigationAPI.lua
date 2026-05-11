--[[
  地图导航（领域对外 API）（AzerothCompanion.API.Navigation）：路径图、可用性过滤与最短路径求解。
  业务模块只负责入口与 UI，本文件不直接操作世界地图 Frame。
]]

AzerothCompanion.API.Navigation = AzerothCompanion.API.Navigation or {}

local WALK_LOCAL_MODE = "walk_local" -- 本地步行模式
local WALK_LOCAL_EDGE_COST = 1 -- 本地步行边缺少距离时的最小估值，避免零成本循环
local ACTION_TRAVEL_COST = 1 -- 传送类动作的低成本估值
local CONDITIONAL_PUBLIC_PORTAL_COST = 180 -- 带 PlayerCondition 的公共传送门估值，避免压过已知常规交通
local TAXI_TRAVERSED_MAP_COST = 60 -- 飞行 / 手动飞行每个经过地图的估值
local TRANSPORT_TRAVERSED_MAP_COST = 40 -- 船、飞艇、控制台等交通每个经过地图的估值

--- 按 from 节点为边建立索引，便于路径查询相邻边。
---@param edgeList table|nil 路径边列表
---@return table edgeListByFrom 按起点分组的边表
local function buildEdgeListByFrom(edgeList)
  local edgeListByFrom = {} -- 起点到边列表的索引
  for _, edge in ipairs(edgeList or {}) do
    local fromNodeId = edge and (edge.from or edge.FromNodeID or edge.From) -- 边起点
    local toNodeId = edge and (edge.to or edge.ToNodeID or edge.To) -- 边终点
    if fromNodeId and toNodeId then
      edgeListByFrom[fromNodeId] = edgeListByFrom[fromNodeId] or {}
      edgeListByFrom[fromNodeId][#edgeListByFrom[fromNodeId] + 1] = edge
    end
  end
  return edgeListByFrom
end

--- 向路径图追加边，并同步维护按起点分组的相邻边索引。
---@param routeGraph table 正在构建的路径图
---@param edge table|nil 路径边
local function appendRouteGraphEdge(routeGraph, edge)
  if type(routeGraph) ~= "table" or type(edge) ~= "table" then
    return
  end
  routeGraph.edges = routeGraph.edges or {}
  routeGraph.edgeListByFrom = routeGraph.edgeListByFrom or {}
  routeGraph.edges[#routeGraph.edges + 1] = edge

  local fromNodeId = edge.from or edge.FromNodeID or edge.From -- 边起点
  local toNodeId = edge.to or edge.ToNodeID or edge.To -- 边终点
  if fromNodeId and toNodeId then
    local fromEdgeList = routeGraph.edgeListByFrom[fromNodeId] -- 起点对应的相邻边列表
    if type(fromEdgeList) ~= "table" then
      fromEdgeList = {}
      routeGraph.edgeListByFrom[fromNodeId] = fromEdgeList
    end
    fromEdgeList[#fromEdgeList + 1] = edge
  end
end

--- 复制一个 Lua 数组。
---@param rawList table|nil 原始数组
---@return table
local function copyArray(rawList)
  local copiedList = {} -- 复制后的数组
  for _, value in ipairs(type(rawList) == "table" and rawList or {}) do
    copiedList[#copiedList + 1] = value
  end
  return copiedList
end

--- 判断路线边是否为 taxi 拓扑转出的手动飞行兜底边。
---@param edge table|nil 路线边
---@return boolean
local function isManualTravelEdge(edge)
  return type(edge) == "table" and (edge.manualTravel == true or edge.ManualTravel == true)
end

--- 去除首尾空白，避免节点显示名里残留多余空格。
---@param rawText any 原始文本
---@return string
local function trimText(rawText)
  local trimmedText = tostring(rawText or "") -- 待裁剪文本
  trimmedText = string.gsub(trimmedText, "^%s+", "")
  trimmedText = string.gsub(trimmedText, "%s+$", "")
  return trimmedText
end

--- 读取导航本地化文案；测试环境未加载 Locales 时使用兜底文本。
---@param key string 文案键
---@param fallbackText string 兜底文本
---@return string
local function getNavigationLocaleText(key, fallbackText)
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化字符串表
  local localizedText = localeTable[key] -- 本地化文案
  if type(localizedText) == "string" and localizedText ~= "" then
    return localizedText
  end
  return fallbackText
end

--- 将来源数组里的值追加到目标数组，保持去重。
---@param targetList table 目标数组
---@param sourceList table|nil 来源数组
local function appendUniqueArray(targetList, sourceList)
  local seenValue = {} -- 已写入值集合
  for _, value in ipairs(targetList or {}) do
    seenValue[tostring(value)] = true
  end
  for _, value in ipairs(type(sourceList) == "table" and sourceList or {}) do
    local marker = tostring(value) -- 去重标记
    if not seenValue[marker] then
      seenValue[marker] = true
      targetList[#targetList + 1] = value
    end
  end
end

--- 读取路线边模式。
---@param edge table|nil 路线边
---@return string
local function readEdgeMode(edge)
  return tostring((type(edge) == "table" and (edge.mode or edge.Mode)) or "unknown")
end

--- 读取路线边显示标签。
---@param edge table|nil 路线边
---@return string
local function readEdgeLabel(edge)
  return tostring((type(edge) == "table" and (edge.label or edge.Label or edge.name or edge.Name_lang)) or "")
end

--- 从方向性交通节点名里抽取真正的到站 / 出发枢纽名。
---@param rawName any 原始节点名
---@return string
local function extractTransportHubName(rawName)
  local normalizedName = trimText(rawName) -- 去空白后的节点名
  local hubName = string.match(normalizedName, "^乘坐(.+)的飞艇前往.+$") -- 飞艇出发枢纽
    or string.match(normalizedName, "^搭乘(.+)的飞艇前往.+$") -- 另一种飞艇文案
    or string.match(normalizedName, "^乘坐(.+)的船前往.+$") -- 船只出发枢纽
    or string.match(normalizedName, "^搭乘(.+)的船前往.+$") -- 另一种船只文案
  return trimText(hubName)
end

--- 按当前展示场景读取更适合输出的节点名。
---@param nodeDef table|nil 运行时节点定义
---@param fallbackNodeId any 节点 ID 兜底
---@param normalizeTransportHub boolean 是否将交通节点归一化为枢纽名
---@return string
local function buildRouteNodeDisplayName(nodeDef, fallbackNodeId, normalizeTransportHub)
  local visibleName = trimText(type(nodeDef) == "table" and nodeDef.visibleName or nil) -- 正式步行组件提供的玩家可见名
  if visibleName ~= "" then
    return visibleName
  end
  local rawName = trimText(type(nodeDef) == "table" and nodeDef.name or fallbackNodeId) -- 原始节点名
  if normalizeTransportHub and type(nodeDef) == "table" and tostring(nodeDef.kind or "") == "transport" then
    local transportHubName = extractTransportHubName(rawName) -- 交通枢纽名
    if transportHubName ~= "" then
      return transportHubName
    end
  end
  return rawName ~= "" and rawName or tostring(fallbackNodeId)
end

--- 读取步行边标签两端更适合展示的名称。
---@param traversedUiMapNames table|nil 步行边经过名
---@param fallbackName string 兜底名称
---@param useDestination boolean 是否读取终点侧
---@return string
local function buildWalkLabelEndpointName(traversedUiMapNames, fallbackName, useDestination)
  local traversedNameList = type(traversedUiMapNames) == "table" and traversedUiMapNames or nil -- 经过名列表
  local nameIndex = useDestination and (type(traversedNameList) == "table" and #traversedNameList or 0) or 1 -- 标签端点索引
  local endpointName = trimText(type(traversedNameList) == "table" and traversedNameList[nameIndex] or nil) -- 标签端点名
  if endpointName ~= "" then
    return endpointName
  end
  return trimText(fallbackName)
end

--- 为路线边生成稳定排序标记。
---@param edge table|nil 路线边
---@return string
local function buildEdgeStableMarker(edge)
  local edgeValue = type(edge) == "table" and edge or {} -- 路线边定义
  local edgeID = edgeValue.id or edgeValue.ID or edgeValue.SourceRowID or readEdgeLabel(edgeValue) -- 稳定边 ID
  local fromNodeId = edgeValue.from or edgeValue.FromNodeID or edgeValue.From or "" -- 边起点
  local toNodeId = edgeValue.to or edgeValue.ToNodeID or edgeValue.To or "" -- 边终点
  return table.concat({
    tostring(readEdgeMode(edgeValue)),
    tostring(edgeID),
    tostring(fromNodeId),
    tostring(toNodeId),
  }, "::")
end

--- 比较两个路径分数；返回 -1 表示左侧更优，1 表示右侧更优，0 表示相同。
---@param leftScore table 左侧分数
---@param rightScore table 右侧分数
---@return integer
local function compareRouteScore(leftScore, rightScore)
  local leftOriginDisplacement = tonumber(leftScore and leftScore.originDisplacement) or 0 -- 左侧从当前位置被能力带离的地图父链距离
  local rightOriginDisplacement = tonumber(rightScore and rightScore.originDisplacement) or 0 -- 右侧从当前位置被能力带离的地图父链距离
  if leftOriginDisplacement > 0 and rightOriginDisplacement > 0 and leftOriginDisplacement ~= rightOriginDisplacement then
    return leftOriginDisplacement < rightOriginDisplacement and -1 or 1
  end

  local leftTravelCost = tonumber(leftScore and leftScore.travelCost) or math.huge -- 左侧结构化旅行成本
  local rightTravelCost = tonumber(rightScore and rightScore.travelCost) or math.huge -- 右侧结构化旅行成本
  if leftTravelCost ~= rightTravelCost then
    return leftTravelCost < rightTravelCost and -1 or 1
  end

  local leftSteps = tonumber(leftScore and leftScore.steps) or math.huge -- 左侧总步数
  local rightSteps = tonumber(rightScore and rightScore.steps) or math.huge -- 右侧总步数
  if leftSteps ~= rightSteps then
    return leftSteps < rightSteps and -1 or 1
  end

  local leftManualTravelSegments = tonumber(leftScore and leftScore.manualTravelSegments) or 0 -- 左侧手动飞行段数
  local rightManualTravelSegments = tonumber(rightScore and rightScore.manualTravelSegments) or 0 -- 右侧手动飞行段数
  if leftManualTravelSegments ~= rightManualTravelSegments then
    return leftManualTravelSegments < rightManualTravelSegments and -1 or 1
  end

  local leftWalkSegments = tonumber(leftScore and leftScore.walkSegments) or math.huge -- 左侧步行段数
  local rightWalkSegments = tonumber(rightScore and rightScore.walkSegments) or math.huge -- 右侧步行段数
  if leftWalkSegments ~= rightWalkSegments then
    return leftWalkSegments < rightWalkSegments and -1 or 1
  end

  local leftWalkDistance = tonumber(leftScore and leftScore.walkDistance) or math.huge -- 左侧步行距离
  local rightWalkDistance = tonumber(rightScore and rightScore.walkDistance) or math.huge -- 右侧步行距离
  if leftWalkDistance ~= rightWalkDistance then
    return leftWalkDistance < rightWalkDistance and -1 or 1
  end

  local leftDisplayChanges = tonumber(leftScore and leftScore.displayChanges) or math.huge -- 左侧步骤切换数
  local rightDisplayChanges = tonumber(rightScore and rightScore.displayChanges) or math.huge -- 右侧步骤切换数
  if leftDisplayChanges ~= rightDisplayChanges then
    return leftDisplayChanges < rightDisplayChanges and -1 or 1
  end

  local leftStableKey = tostring(leftScore and leftScore.stableKey or "") -- 左侧稳定键
  local rightStableKey = tostring(rightScore and rightScore.stableKey or "") -- 右侧稳定键
  if leftStableKey ~= rightStableKey then
    return leftStableKey < rightStableKey and -1 or 1
  end
  return 0
end

--- 计算进入一条路线边后新增的路线步数。
---@param edge table 路线边
---@param lastMode string|nil 上一条边模式
---@return number
local function buildEdgeStepIncrement(edge, lastMode)
  local edgeMode = readEdgeMode(edge) -- 当前边模式
  if edgeMode == WALK_LOCAL_MODE and lastMode == WALK_LOCAL_MODE then
    return 0
  end
  local stepCost = tonumber(edge and (edge.stepCost or edge.StepCost)) -- 边步数成本
  return (stepCost and stepCost > 0) and stepCost or 1
end

--- 计算进入一条路线边后新增的步行段数。
---@param edge table 路线边
---@param lastMode string|nil 上一条边模式
---@return number
local function buildWalkSegmentIncrement(edge, lastMode)
  local edgeMode = readEdgeMode(edge) -- 当前边模式
  if edgeMode == WALK_LOCAL_MODE and lastMode ~= WALK_LOCAL_MODE then
    return 1
  end
  return 0
end

--- 计算进入一条路线边后新增的本地步行距离。
---@param edge table 路线边
---@return number
local function buildWalkDistanceIncrement(edge)
  if readEdgeMode(edge) ~= WALK_LOCAL_MODE then
    return 0
  end
  local walkDistance = tonumber(edge and (edge.walkDistance or edge.WalkDistance or edge.cost or edge.Cost)) -- 导出或运行时提供的步行距离
  if walkDistance and walkDistance > 0 then
    return walkDistance
  end
  return WALK_LOCAL_EDGE_COST
end

--- 读取路线边经过地图数量，供飞行和交通成本估值使用。
---@param edge table 路线边
---@return number
local function countTraversedUiMaps(edge)
  local traversedUiMapIDList = type(edge) == "table" and (edge.traversedUiMapIDs or edge.TraversedUiMapIDs) or nil -- 经过地图 ID 列表
  if type(traversedUiMapIDList) ~= "table" or #traversedUiMapIDList <= 0 then
    return 1
  end
  return #traversedUiMapIDList
end

--- 判断路线边是否为带静态 PlayerCondition 门槛的中转公共传送门。
---@param edge table 路线边
---@param targetUiMapID number|nil 当前目标地图 ID
---@param targetExpansionID number|nil 当前目标资料片 ID
---@return boolean
local function isConditionalPublicPortalTransit(edge, targetUiMapID, targetExpansionID)
  if tonumber(type(edge) == "table" and (edge.playerConditionID or edge.PlayerConditionID)) == nil then
    return false
  end
  local edgeTargetUiMapID = tonumber(edge.toUiMapID or edge.ToUiMapID) -- 传送门落点地图
  local routeTargetUiMapID = tonumber(targetUiMapID) -- 当前规划目标地图
  if routeTargetUiMapID and edgeTargetUiMapID == routeTargetUiMapID then
    return false
  end
  local edgeTargetExpansionID = tonumber(edge.toExpansionID or edge.ToExpansionID) -- 传送门落点资料片
  local routeTargetExpansionID = tonumber(targetExpansionID) -- 当前规划目标资料片
  if routeTargetExpansionID ~= nil and edgeTargetExpansionID ~= nil and edgeTargetExpansionID == routeTargetExpansionID then
    return false
  end
  return true
end

--- 计算进入一条路线边后的结构化旅行成本。
---@param edge table 路线边
---@param targetUiMapID number|nil 当前目标地图 ID
---@param targetExpansionID number|nil 当前目标资料片 ID
---@return number
local function buildTravelCostIncrement(edge, targetUiMapID, targetExpansionID)
  local edgeMode = readEdgeMode(edge) -- 当前边模式
  if edgeMode == WALK_LOCAL_MODE then
    return buildWalkDistanceIncrement(edge)
  end
  if edgeMode == "taxi" then
    if isManualTravelEdge(edge) then
      return TAXI_TRAVERSED_MAP_COST
    end
    return countTraversedUiMaps(edge) * TAXI_TRAVERSED_MAP_COST
  end
  if edgeMode == "transport" then
    return countTraversedUiMaps(edge) * TRANSPORT_TRAVERSED_MAP_COST
  end
  if edgeMode == "public_portal" and isConditionalPublicPortalTransit(edge, targetUiMapID, targetExpansionID) then
    return CONDITIONAL_PUBLIC_PORTAL_COST
  end
  if edgeMode == "public_portal"
    or edgeMode == "class_portal"
    or edgeMode == "class_teleport"
    or edgeMode == "hearthstone" then
    return ACTION_TRAVEL_COST
  end
  return buildEdgeStepIncrement(edge, nil) * ACTION_TRAVEL_COST
end

--- 计算进入一条路线边后新增的手动飞行段数。
---@param edge table 路线边
---@return number
local function buildManualTravelSegmentIncrement(edge)
  return isManualTravelEdge(edge) and 1 or 0
end

--- 生成状态键，允许同一节点按“上一动作模式”分离状态。
---@param nodeId any 节点 ID
---@param lastMode string|nil 上一动作模式
---@return string
local function buildRouteStateKey(nodeId, lastMode)
  return tostring(nodeId) .. "::" .. tostring(lastMode or "")
end

--- 从开放列表中取出当前最优状态。
---@param openStateList table 开放状态列表
---@param bestStateByKey table 当前最佳状态表
---@return table|nil
local function popBestOpenState(openStateList, bestStateByKey)
  while #openStateList > 0 do
    local bestIndex = 1 -- 最优状态索引
    local bestState = openStateList[1] -- 当前最优状态
    for stateIndex = 2, #openStateList do
      local candidateState = openStateList[stateIndex] -- 候选状态
      if compareRouteScore(candidateState.score, bestState.score) < 0 then
        bestIndex = stateIndex
        bestState = candidateState
      end
    end
    table.remove(openStateList, bestIndex)
    if bestStateByKey[bestState.stateKey] == bestState then
      return bestState
    end
  end
  return nil
end

--- 把原始路线边上的来源与条件背景复制到展示段，供聊天诊断解释路线来源。
---@param segment table|nil 展示段
---@param edge table|nil 原始路线边
local function copyRouteSegmentBackgroundFields(segment, edge)
  if type(segment) ~= "table" or type(edge) ~= "table" then
    return
  end

  local requirements = type(edge.requirements) == "table" and edge.requirements or nil -- 边的运行时可用性要求
  segment.source = edge.source or edge.Source
  segment.sourceID = edge.sourceID or edge.SourceID
  segment.originalMode = edge.originalMode or edge.OriginalMode
  segment.manualTravel = isManualTravelEdge(edge)
  segment.abilityTemplateID = edge.abilityTemplateID or edge.AbilityTemplateID
  segment.spellID = edge.spellID or edge.SpellID or (requirements and requirements.spellID)
  segment.classFile = edge.classFile or edge.ClassFile or (requirements and requirements.classFile)
  segment.factionRequirement = edge.factionRequirement or edge.FactionRequirement or (requirements and requirements.faction)
  segment.playerConditionID = edge.playerConditionID or edge.PlayerConditionID
  segment.fromTaxiNodeID = edge.fromTaxiNodeID or edge.FromTaxiNodeID
  segment.toTaxiNodeID = edge.toTaxiNodeID or edge.ToTaxiNodeID
  segment.fromExpansionID = edge.fromExpansionID or edge.FromExpansionID
  segment.toExpansionID = edge.toExpansionID or edge.ToExpansionID
end

--- 将路径边数组压缩为最终展示段。
---@param routeGraph table 路径图
---@param edgePath table 原始边路径
---@return table segments 展示段
---@return table stepLabels 兼容步骤文案
local function buildRouteSegments(routeGraph, edgePath)
  local segments = {} -- 展示段列表
  for _, edge in ipairs(edgePath or {}) do
    local edgeMode = readEdgeMode(edge) -- 当前边模式
    local fromNodeId = edge.from or edge.FromNodeID or edge.From -- 边起点
    local toNodeId = edge.to or edge.ToNodeID or edge.To -- 边终点
    local fromNode = routeGraph.nodes[fromNodeId] or {} -- 起点节点
    local toNode = routeGraph.nodes[toNodeId] or {} -- 终点节点
    local edgeLabel = readEdgeLabel(edge) -- 当前边显示标签

    if edgeMode == WALK_LOCAL_MODE and #segments > 0 and segments[#segments].mode == WALK_LOCAL_MODE then
      local lastSegment = segments[#segments] -- 最近一个步行段
      lastSegment.to = toNodeId
      lastSegment.toName = tostring(toNode.name or toNodeId)
      lastSegment.walkDistance = tonumber(lastSegment.walkDistance or 0) + buildWalkDistanceIncrement(edge)
      lastSegment.label = edgeLabel
      appendUniqueArray(lastSegment.traversedUiMapIDs, edge.traversedUiMapIDs or edge.TraversedUiMapIDs)
      appendUniqueArray(lastSegment.traversedUiMapNames, edge.traversedUiMapNames or edge.TraversedUiMapNames)
    else
      local segment = { -- 新增展示段
        mode = edgeMode,
        from = fromNodeId,
        to = toNodeId,
        fromName = buildRouteNodeDisplayName(fromNode, fromNodeId, edgeMode == WALK_LOCAL_MODE),
        toName = buildRouteNodeDisplayName(toNode, toNodeId, false),
        fromUiMapID = tonumber(fromNode.uiMapID),
        toUiMapID = tonumber(toNode.uiMapID),
        label = edgeLabel,
        traversedUiMapIDs = copyArray(edge.traversedUiMapIDs or edge.TraversedUiMapIDs),
        traversedUiMapNames = copyArray(edge.traversedUiMapNames or edge.TraversedUiMapNames),
        walkDistance = buildWalkDistanceIncrement(edge),
      }
      copyRouteSegmentBackgroundFields(segment, edge)
      segments[#segments + 1] = segment
    end
  end

  local stepLabels = {} -- 兼容旧界面的步骤文案
  for _, segment in ipairs(segments) do
    local segmentLabel = segment.label -- 当前段显示标签
    if segmentLabel == nil or segmentLabel == "" then
      segmentLabel = string.format("%s: %s -> %s", tostring(segment.mode), tostring(segment.fromName), tostring(segment.toName))
    end
    stepLabels[#stepLabels + 1] = segmentLabel
  end
  return segments, stepLabels
end

--- 从显示文本里提取地图级名称。
---@param rawText any 原始文本
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

--- 清理边标签里导出用的后缀节点补充，仅保留玩家需要执行的动作。
---@param rawLabel any 原始标签
---@return string
local function cleanPlayerFacingLabel(rawLabel)
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

--- 判断一段路线是否应该生成显式动作节点。
---@param modeText string|nil 路线方式
---@return boolean
local function isSemanticActionMode(modeText)
  return modeText == "public_portal"
    or modeText == "class_portal"
    or modeText == "transport"
    or modeText == "hearthstone"
    or modeText == "class_teleport"
end

--- 由路线方式映射语义动作节点类型。
---@param modeText string|nil 路线方式
---@return string
local function buildSemanticActionKind(modeText)
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

--- 为一段路线读取更适合语义层使用的地图名。
---@param segment table|nil 路线段
---@param useDestination boolean 是否读取终点侧
---@return string
local function buildSemanticMapName(segment, useDestination)
  if type(segment) ~= "table" then
    return ""
  end
  local traversedNameList = type(segment.traversedUiMapNames) == "table" and segment.traversedUiMapNames or nil -- 经过地图名列表
  if type(traversedNameList) == "table" and #traversedNameList > 0 then
    local traversedIndex = useDestination and #traversedNameList or 1 -- 读取的经过地图索引
    local traversedMapName = extractMapLevelName(traversedNameList[traversedIndex]) -- 经过地图名
    if traversedMapName ~= "" then
      return traversedMapName
    end
  end
  local fallbackName = useDestination and segment.toName or segment.fromName -- 兜底名称
  return extractMapLevelName(fallbackName)
end

--- 生成动作节点显示文本。
---@param segment table|nil 路线段
---@return string
local function buildSemanticActionText(segment)
  if type(segment) ~= "table" then
    return ""
  end

  local cleanedLabel = cleanPlayerFacingLabel(segment.label) -- 清洗后的动作标签
  if cleanedLabel ~= "" then
    return cleanedLabel
  end

  local modeText = tostring(segment.mode or "") -- 路线方式
  local destinationMapName = buildSemanticMapName(segment, true) -- 动作目标地图名
  if destinationMapName == "" then
    destinationMapName = extractMapLevelName(segment.toName or segment.to)
  end
  if destinationMapName == "" then
    destinationMapName = "目标地图"
  end

  if segment.manualTravel == true then
    local formatText = getNavigationLocaleText("NAVIGATION_ROUTE_MANUAL_FLIGHT_ACTION_FMT", "飞行前往%s") -- 手动飞行动作文案
    return string.format(formatText, destinationMapName)
  end
  if modeText == "public_portal" or modeText == "class_portal" then
    return string.format("使用传送门前往%s", destinationMapName)
  end
  if modeText == "transport" then
    return string.format("乘坐交通前往%s", destinationMapName)
  end
  if modeText == "hearthstone" then
    return string.format("使用炉石前往%s", destinationMapName)
  end
  if modeText == "class_teleport" then
    return string.format("使用职业传送前往%s", destinationMapName)
  end
  return destinationMapName
end

--- 向语义节点链追加一个节点，并避免相邻重复。
---@param nodeList table 语义节点链
---@param text string 节点文本
---@param kind string 节点类型
---@param uiMapID number|nil 地图 ID
---@param mode string|nil 动作方式
local function appendSemanticNode(nodeList, text, kind, uiMapID, mode)
  local trimmedText = trimText(text) -- 去空白后的节点文本
  if trimmedText == "" then
    return
  end
  local lastNode = nodeList[#nodeList] -- 最近一个语义节点
  if type(lastNode) == "table" and trimText(lastNode.text) == trimmedText and tostring(lastNode.kind or "") == tostring(kind or "") then
    if tonumber(uiMapID) and not tonumber(lastNode.uiMapID) then
      lastNode.uiMapID = tonumber(uiMapID)
    end
    if trimText(mode) ~= "" and trimText(lastNode.mode) == "" then
      lastNode.mode = trimText(mode)
    end
    return
  end
  nodeList[#nodeList + 1] = {
    kind = trimText(kind) ~= "" and trimText(kind) or "map",
    mode = trimText(mode),
    text = trimmedText,
    uiMapID = tonumber(uiMapID) or nil,
  }
end

--- 把一段路线中的中间地图补进语义节点链。
---@param nodeList table 语义节点链
---@param segment table|nil 路线段
local function appendSemanticIntermediateMapNodes(nodeList, segment)
  local traversedNameList = type(segment) == "table" and segment.traversedUiMapNames or nil -- 原始经过地图名列表
  local traversedMapIDList = type(segment) == "table" and segment.traversedUiMapIDs or nil -- 原始经过地图 ID 列表
  local lastInteriorIndex = type(traversedNameList) == "table" and (#traversedNameList - 1) or 0 -- 最后一个中间节点索引
  if type(traversedNameList) ~= "table" or lastInteriorIndex < 2 then
    return
  end
  for traversedIndex = 2, lastInteriorIndex do
    appendSemanticNode(
      nodeList,
      extractMapLevelName(traversedNameList[traversedIndex]),
      "map",
      type(traversedMapIDList) == "table" and traversedMapIDList[traversedIndex] or nil,
      nil
    )
  end
end

--- 判断动作段的到站地图是否应由最后一步本地步行目标吸收。
---@param segmentList table|nil 路线分段列表
---@param segmentIndex number 当前段序号
---@return boolean
local function shouldMergeSemanticArrivalIntoFinalWalk(segmentList, segmentIndex)
  local currentSegment = type(segmentList) == "table" and segmentList[segmentIndex] or nil -- 当前路线段
  local nextSegment = type(segmentList) == "table" and segmentList[segmentIndex + 1] or nil -- 下一段路线
  return type(nextSegment) == "table"
    and segmentIndex + 1 == #segmentList
    and tostring(nextSegment.mode or "") == WALK_LOCAL_MODE
    and tonumber(currentSegment and currentSegment.toUiMapID) ~= nil
    and tonumber(currentSegment and currentSegment.toUiMapID) == tonumber(nextSegment.toUiMapID)
end

--- 基于 segments 构建语义节点链。
---@param segmentList table|nil 路线分段列表
---@return table
local function buildSemanticNodes(segmentList)
  if type(segmentList) ~= "table" or #segmentList == 0 then
    return {}
  end

  local nodeList = {} -- 语义节点链
  local firstSegment = segmentList[1] or nil -- 第一段路线
  appendSemanticNode(nodeList, buildSemanticMapName(firstSegment, false), "map", firstSegment and firstSegment.fromUiMapID, nil)

  for segmentIndex, segment in ipairs(segmentList) do
    local modeText = tostring(type(segment) == "table" and segment.mode or "") -- 当前段方式
    if modeText == WALK_LOCAL_MODE then
      appendSemanticIntermediateMapNodes(nodeList, segment)
      if segmentIndex == #segmentList then
        appendSemanticNode(nodeList, buildSemanticMapName(segment, true), "map", segment.toUiMapID, nil)
      end
    elseif modeText == "taxi" then
      if segment.manualTravel == true then
        appendSemanticNode(nodeList, buildSemanticActionText(segment), "flight", segment.fromUiMapID, modeText)
        appendSemanticIntermediateMapNodes(nodeList, segment)
      end
      if not shouldMergeSemanticArrivalIntoFinalWalk(segmentList, segmentIndex) then
        appendSemanticNode(nodeList, buildSemanticMapName(segment, true), "map", segment.toUiMapID, nil)
      end
    elseif isSemanticActionMode(modeText) then
      appendSemanticNode(nodeList, buildSemanticActionText(segment), buildSemanticActionKind(modeText), segment.fromUiMapID, modeText)
      if not shouldMergeSemanticArrivalIntoFinalWalk(segmentList, segmentIndex) then
        appendSemanticNode(nodeList, buildSemanticMapName(segment, true), "map", segment.toUiMapID, nil)
      end
    else
      appendSemanticNode(nodeList, buildSemanticMapName(segment, true), "map", segment.toUiMapID, nil)
    end
  end

  return nodeList
end

--- 回溯路径状态，生成路线结果。
---@param routeGraph table 路径图
---@param finalState table 最终状态
---@return table
local function buildRouteResult(routeGraph, finalState)
  local reversedNodePath = {} -- 反向节点路径
  local reversedEdgePath = {} -- 反向边路径
  local currentState = finalState -- 当前回溯状态

  while currentState do
    reversedNodePath[#reversedNodePath + 1] = currentState.nodeId
    if currentState.previousEdge then
      reversedEdgePath[#reversedEdgePath + 1] = currentState.previousEdge
    end
    currentState = currentState.previousState
  end

  local rawNodePath = {} -- 正向节点路径
  for pathIndex = #reversedNodePath, 1, -1 do
    rawNodePath[#rawNodePath + 1] = reversedNodePath[pathIndex]
  end

  local rawEdgePath = {} -- 正向边路径
  for pathIndex = #reversedEdgePath, 1, -1 do
    rawEdgePath[#rawEdgePath + 1] = reversedEdgePath[pathIndex]
  end

  local segments, stepLabels = buildRouteSegments(routeGraph, rawEdgePath) -- 展示段与兼容文案
  local semanticNodes = buildSemanticNodes(segments) -- 语义节点链
  return {
    totalSteps = tonumber(finalState and finalState.score and finalState.score.steps) or #segments,
    segments = segments,
    semanticNodes = semanticNodes,
    rawNodePath = rawNodePath,
    rawEdgePath = rawEdgePath,
    totalCost = tonumber(finalState and finalState.score and finalState.score.travelCost) or #segments,
    nodePath = rawNodePath,
    stepLabels = stepLabels,
  }
end

--- 判断单条边是否满足当前角色可用性要求。
---@param edge table 路径边
---@param availabilityContext table|nil 当前角色可用性快照
---@return boolean
local function isEdgeAvailable(edge, availabilityContext)
  local requirements = edge and edge.requirements or nil -- 边可用性要求
  local context = availabilityContext or {} -- 当前角色上下文
  if type(requirements) ~= "table" then
    requirements = nil
  else
    if requirements.classFile and requirements.classFile ~= context.classFile then
      return false
    end
    if requirements.faction and requirements.faction ~= context.faction then
      return false
    end
    if requirements.spellID then
      local knownSpellByID = context.knownSpellByID -- 已确认技能集合
      if type(knownSpellByID) ~= "table" or knownSpellByID[requirements.spellID] ~= true then
        return false
      end
    end
  end

  local factionRequirement = edge and edge.FactionRequirement or nil -- 静态公共边的阵营限制
  if factionRequirement and factionRequirement ~= context.faction then
    return false
  end

  local edgeMode = readEdgeMode(edge)
  if edgeMode == "taxi" then
    local knownTaxiNodeByID = context.knownTaxiNodeByID -- 已开航点集合
    local fromTaxiNodeID = tonumber(edge and (edge.fromTaxiNodeID or edge.FromTaxiNodeID)) -- 起点飞行点 ID
    local toTaxiNodeID = tonumber(edge and (edge.toTaxiNodeID or edge.ToTaxiNodeID)) -- 终点飞行点 ID
    if type(knownTaxiNodeByID) ~= "table" or not fromTaxiNodeID or not toTaxiNodeID then
      return false
    end
    if knownTaxiNodeByID[fromTaxiNodeID] ~= true or knownTaxiNodeByID[toTaxiNodeID] ~= true then
      return false
    end
  end

  if edgeMode == "transport" then
    local fromTaxiNodeID = tonumber(edge and (edge.fromTaxiNodeID or edge.FromTaxiNodeID)) -- 起点飞行点 ID
    local toTaxiNodeID = tonumber(edge and (edge.toTaxiNodeID or edge.ToTaxiNodeID)) -- 终点飞行点 ID
    if fromTaxiNodeID or toTaxiNodeID then
      local knownTaxiNodeByID = context.knownTaxiNodeByID -- 已开航点集合
      if type(knownTaxiNodeByID) ~= "table" or not fromTaxiNodeID or not toTaxiNodeID then
        return false
      end
      if knownTaxiNodeByID[fromTaxiNodeID] ~= true or knownTaxiNodeByID[toTaxiNodeID] ~= true then
        return false
      end
    end
  end

  return true
end

--- 过滤路径图中当前角色不可用或未知可用性的边。
---@param routeGraph table 路径图，包含 `nodes` 与 `edges`
---@param availabilityContext table|nil 当前角色可用性快照
---@return table filteredGraph 过滤后的路径图
function AzerothCompanion.API.Navigation.FilterRouteGraph(routeGraph, availabilityContext)
  local filteredGraph = {
    nodes = type(routeGraph) == "table" and routeGraph.nodes or {},
    edges = {},
  } -- 过滤后的路径图

  if type(routeGraph) ~= "table" then
    return filteredGraph
  end

  for _, edge in ipairs(routeGraph.edges or {}) do
    if isEdgeAvailable(edge, availabilityContext) then
      filteredGraph.edges[#filteredGraph.edges + 1] = edge
    end
  end

  return filteredGraph
end

--- 沿父地图链构建 UiMap 祖先列表。
---@param uiMapID number|nil 起点地图 ID
---@param mapNodes table|nil 地图节点表
---@return table
local function buildUiMapAncestorList(uiMapID, mapNodes)
  local ancestorList = {} -- 从当前地图到根地图的祖先链
  local seenMapID = {} -- 防止异常父链循环
  local currentMapID = tonumber(uiMapID) -- 当前处理地图 ID
  local guardCount = 0 -- 父链保护计数
  while currentMapID and currentMapID > 0 and not seenMapID[currentMapID] and guardCount < 24 do
    ancestorList[#ancestorList + 1] = currentMapID
    seenMapID[currentMapID] = true
    guardCount = guardCount + 1
    local nodeDef = type(mapNodes) == "table" and mapNodes[currentMapID] or nil -- 当前地图节点
    currentMapID = tonumber(nodeDef and nodeDef.ParentUiMapID)
  end
  return ancestorList
end

--- 用 UiMap 父链生成一段手动飞行可展示的地图路径。
---@param fromUiMapID number|nil 起点地图 ID
---@param toUiMapID number|nil 终点地图 ID
---@return table
local function buildManualTravelUiMapPath(fromUiMapID, toUiMapID)
  local mapNodes = AzerothCompanion.Data and AzerothCompanion.Data.NavigationMapNodes and AzerothCompanion.Data.NavigationMapNodes.nodes or {} -- 地图基础节点
  local fromAncestorList = buildUiMapAncestorList(fromUiMapID, mapNodes) -- 起点父链
  local toAncestorList = buildUiMapAncestorList(toUiMapID, mapNodes) -- 终点父链
  local toAncestorIndexByMapID = {} -- 终点父链索引
  for ancestorIndex, ancestorMapID in ipairs(toAncestorList) do
    toAncestorIndexByMapID[ancestorMapID] = ancestorIndex
  end

  local commonFromIndex = nil -- 起点父链公共祖先位置
  local commonToIndex = nil -- 终点父链公共祖先位置
  for ancestorIndex, ancestorMapID in ipairs(fromAncestorList) do
    local toAncestorIndex = toAncestorIndexByMapID[ancestorMapID] -- 终点父链对应位置
    if toAncestorIndex then
      commonFromIndex = ancestorIndex
      commonToIndex = toAncestorIndex
      break
    end
  end

  local pathList = {} -- 可展示地图路径
  if not commonFromIndex or not commonToIndex then
    if tonumber(fromUiMapID) then
      pathList[#pathList + 1] = tonumber(fromUiMapID)
    end
    if tonumber(toUiMapID) and tonumber(toUiMapID) ~= tonumber(fromUiMapID) then
      pathList[#pathList + 1] = tonumber(toUiMapID)
    end
    return pathList
  end

  for pathIndex = 1, commonFromIndex do
    pathList[#pathList + 1] = fromAncestorList[pathIndex]
  end
  for pathIndex = commonToIndex - 1, 1, -1 do
    pathList[#pathList + 1] = toAncestorList[pathIndex]
  end
  return pathList
end

--- 计算两个地图在父链上的结构化距离，用于 fallback 阶段压低“先传走再绕回”的路线。
---@param fromUiMapID number|nil 起点地图 ID
---@param toUiMapID number|nil 终点地图 ID
---@return number
local function buildUiMapAncestorDistance(fromUiMapID, toUiMapID)
  local mapNodes = AzerothCompanion.Data and AzerothCompanion.Data.NavigationMapNodes and AzerothCompanion.Data.NavigationMapNodes.nodes or {} -- 地图基础节点
  local fromAncestorList = buildUiMapAncestorList(fromUiMapID, mapNodes) -- 起点父链
  local toAncestorList = buildUiMapAncestorList(toUiMapID, mapNodes) -- 终点父链
  local toAncestorIndexByMapID = {} -- 终点父链索引
  for ancestorIndex, ancestorMapID in ipairs(toAncestorList) do
    toAncestorIndexByMapID[ancestorMapID] = ancestorIndex
  end

  for ancestorIndex, ancestorMapID in ipairs(fromAncestorList) do
    local toAncestorIndex = toAncestorIndexByMapID[ancestorMapID] -- 终点父链对应位置
    if toAncestorIndex then
      return (ancestorIndex - 1) + (toAncestorIndex - 1)
    end
  end

  return (#fromAncestorList > 0 and #toAncestorList > 0) and (#fromAncestorList + #toAncestorList) or 0
end

--- fallback 阶段计算从当前位置直接能力位移的结构化代价。
---@param routeGraph table 路径图
---@param routeEdge table 路线边
---@param currentState table 当前搜索状态
---@param availabilityContext table|nil 当前角色可用性快照
---@param allowTaxiManualTravelFallback boolean|nil 是否处于手动飞行 fallback 搜索
---@return number
local function buildOriginDisplacementIncrement(routeGraph, routeEdge, currentState, availabilityContext, allowTaxiManualTravelFallback)
  if allowTaxiManualTravelFallback ~= true or type(currentState) ~= "table" or currentState.nodeId ~= "current" then
    return 0
  end

  local edgeMode = readEdgeMode(routeEdge) -- 当前边模式
  if edgeMode ~= "class_portal" and edgeMode ~= "class_teleport" and edgeMode ~= "hearthstone" then
    return 0
  end

  local currentMapID = tonumber(availabilityContext and availabilityContext.currentUiMapID) -- 当前角色地图 ID
  local toNodeId = routeEdge and (routeEdge.to or routeEdge.ToNodeID or routeEdge.To) -- 能力落点节点 ID
  local toNode = type(routeGraph) == "table" and type(routeGraph.nodes) == "table" and routeGraph.nodes[toNodeId] or nil -- 能力落点节点
  local toUiMapID = tonumber(toNode and toNode.uiMapID) -- 能力落点地图 ID
  if not currentMapID or not toUiMapID then
    return 0
  end
  return buildUiMapAncestorDistance(currentMapID, toUiMapID)
end

--- 将地图 ID 路径转换为显示名路径。
---@param uiMapIDList table|nil 地图 ID 路径
---@return table
local function buildUiMapNameList(uiMapIDList)
  local mapNodes = AzerothCompanion.Data and AzerothCompanion.Data.NavigationMapNodes and AzerothCompanion.Data.NavigationMapNodes.nodes or {} -- 地图基础节点
  local nameList = {} -- 地图名路径
  for _, uiMapID in ipairs(type(uiMapIDList) == "table" and uiMapIDList or {}) do
    local numericMapID = tonumber(uiMapID) -- 当前地图 ID
    local mapNode = numericMapID and mapNodes[numericMapID] or nil -- 当前地图节点
    local mapName = trimText(mapNode and mapNode.Name_lang) -- 当前地图名
    if mapName ~= "" then
      nameList[#nameList + 1] = mapName
    elseif numericMapID then
      nameList[#nameList + 1] = "Map #" .. tostring(numericMapID)
    end
  end
  return nameList
end

--- 把不可用 taxi 边标记为手动飞行展示，保留原始飞行点拓扑和经过地图。
---@param routeGraph table 路径图
---@param edge table 原始 taxi 边
---@return table
local function buildManualTaxiTravelEdge(routeGraph, edge)
  local edgeCopy = {} -- 手动飞行边副本
  for key, value in pairs(type(edge) == "table" and edge or {}) do
    edgeCopy[key] = value
  end

  local originalMode = readEdgeMode(edge) -- 原始边模式
  local fromNodeId = edge and (edge.from or edge.FromNodeID or edge.From) -- 原始边起点
  local toNodeId = edge and (edge.to or edge.ToNodeID or edge.To) -- 原始边终点
  local fromNode = type(routeGraph) == "table" and type(routeGraph.nodes) == "table" and routeGraph.nodes[fromNodeId] or nil -- 起点节点
  local toNode = type(routeGraph) == "table" and type(routeGraph.nodes) == "table" and routeGraph.nodes[toNodeId] or nil -- 终点节点
  local fromUiMapID = tonumber(edgeCopy.fromUiMapID or edgeCopy.FromUiMapID or (fromNode and fromNode.uiMapID)) -- 起点地图 ID
  local toUiMapID = tonumber(edgeCopy.toUiMapID or edgeCopy.ToUiMapID or (toNode and toNode.uiMapID)) -- 终点地图 ID
  local exportedUiMapIDList = copyArray(edgeCopy.traversedUiMapIDs or edgeCopy.TraversedUiMapIDs) -- 导出边经过地图 ID
  local exportedUiMapNameList = copyArray(edgeCopy.traversedUiMapNames or edgeCopy.TraversedUiMapNames) -- 导出边经过地图名
  local fallbackUiMapIDList = buildManualTravelUiMapPath(fromUiMapID, toUiMapID) -- 兜底经过地图 ID
  local uiMapIDList = #exportedUiMapIDList > 0 and exportedUiMapIDList or fallbackUiMapIDList -- 手动飞行经过地图 ID
  local uiMapNameList = #exportedUiMapNameList > 0 and exportedUiMapNameList or buildUiMapNameList(uiMapIDList) -- 手动飞行经过地图名
  local fromMapName = trimText(uiMapNameList[1] or (fromNode and fromNode.name) or fromNodeId) -- 起点地图名
  local toMapName = trimText(uiMapNameList[#uiMapNameList] or (toNode and toNode.name) or toNodeId) -- 终点地图名
  local formatText = getNavigationLocaleText("NAVIGATION_ROUTE_MANUAL_FLIGHT_LABEL_FMT", "飞行前往：%s -> %s") -- 手动飞行段文案

  edgeCopy.mode = "taxi"
  edgeCopy.Mode = "taxi"
  edgeCopy.manualTravel = true
  edgeCopy.ManualTravel = true
  edgeCopy.originalMode = originalMode
  edgeCopy.OriginalMode = originalMode
  edgeCopy.label = string.format(formatText, fromMapName, toMapName)
  edgeCopy.Label = edgeCopy.label
  edgeCopy.stepCost = tonumber(edgeCopy.stepCost or edgeCopy.StepCost) or 1
  edgeCopy.StepCost = edgeCopy.stepCost
  edgeCopy.traversedUiMapIDs = uiMapIDList
  edgeCopy.TraversedUiMapIDs = edgeCopy.traversedUiMapIDs
  edgeCopy.traversedUiMapNames = uiMapNameList
  edgeCopy.TraversedUiMapNames = edgeCopy.traversedUiMapNames
  return edgeCopy
end

--- 在路径图中查找起点到终点的最少步数路线。
---@param routeGraph table 路径图，包含 `nodes` 与 `edges`
---@param startNodeId any 起点节点 ID
---@param targetNodeId any 终点节点 ID
---@param availabilityContext table|nil 当前角色可用性快照；传入时在展开相邻边时过滤不可用边
---@param allowTaxiManualTravelFallback boolean|nil 是否允许不可用 taxi 边标记为手动飞行
---@param targetUiMapID number|nil 当前目标地图 ID；用于区分目标传送门与中转传送门
---@param targetExpansionID number|nil 当前目标资料片 ID；用于优先进入目标资料片的条件传送门
---@return table|nil routeResult 成功时包含 `totalSteps`、`segments`、`rawNodePath`、`rawEdgePath`
---@return table|nil errorObject 失败时包含 `code`
local function findShortestPath(routeGraph, startNodeId, targetNodeId, availabilityContext, allowTaxiManualTravelFallback, targetUiMapID, targetExpansionID)
  if type(routeGraph) ~= "table" or type(routeGraph.nodes) ~= "table" then
    return nil, { code = "NAVIGATION_ERR_BAD_GRAPH" }
  end
  if routeGraph.nodes[startNodeId] == nil or routeGraph.nodes[targetNodeId] == nil then
    return nil, { code = "NAVIGATION_ERR_UNKNOWN_NODE" }
  end

  local edgeListByFrom = type(routeGraph.edgeListByFrom) == "table" and routeGraph.edgeListByFrom or buildEdgeListByFrom(routeGraph.edges) -- 起点到边列表索引
  local shouldCheckAvailability = availabilityContext ~= nil -- 是否在搜索展开时过滤当前角色不可用边
  local bestStateByKey = {} -- 每个状态键的当前最优状态
  local openStateList = {} -- 待展开状态列表

  local startState = {
    nodeId = startNodeId,
    lastMode = nil,
    previousState = nil,
    previousEdge = nil,
    score = {
      steps = 0,
      travelCost = 0,
      manualTravelSegments = 0,
      originDisplacement = 0,
      walkSegments = 0,
      walkDistance = 0,
      displayChanges = 0,
      stableKey = "",
    },
  } -- 起点状态
  startState.stateKey = buildRouteStateKey(startNodeId, nil)
  bestStateByKey[startState.stateKey] = startState
  openStateList[#openStateList + 1] = startState

  while true do
    local currentState = popBestOpenState(openStateList, bestStateByKey) -- 当前最优状态
    if currentState == nil then
      break
    end
    if currentState.nodeId == targetNodeId then
      return buildRouteResult(routeGraph, currentState), nil
    end

    for _, edge in ipairs(edgeListByFrom[currentState.nodeId] or {}) do
      local edgeMode = readEdgeMode(edge) -- 当前边模式
      local isAvailable = (not shouldCheckAvailability) or isEdgeAvailable(edge, availabilityContext) -- 当前角色是否可直接使用此边
      local routeEdge = edge -- 实际进入搜索的边
      if not isAvailable and allowTaxiManualTravelFallback == true and edgeMode == "taxi" then
        routeEdge = buildManualTaxiTravelEdge(routeGraph, edge)
        edgeMode = readEdgeMode(routeEdge)
        isAvailable = true
      end

      local toNodeId = routeEdge.to or routeEdge.ToNodeID or routeEdge.To -- 边终点
      if toNodeId ~= nil and routeGraph.nodes[toNodeId] ~= nil and isAvailable then
        local candidateState = {
          nodeId = toNodeId,
          lastMode = edgeMode,
          previousState = currentState,
          previousEdge = routeEdge,
          score = {
            steps = tonumber(currentState.score.steps) + buildEdgeStepIncrement(routeEdge, currentState.lastMode),
            travelCost = (tonumber(currentState.score.travelCost) or 0) + buildTravelCostIncrement(routeEdge, targetUiMapID, targetExpansionID),
            manualTravelSegments = (tonumber(currentState.score.manualTravelSegments) or 0) + buildManualTravelSegmentIncrement(routeEdge),
            originDisplacement = (tonumber(currentState.score.originDisplacement) or 0) + buildOriginDisplacementIncrement(routeGraph, routeEdge, currentState, availabilityContext, allowTaxiManualTravelFallback),
            walkSegments = tonumber(currentState.score.walkSegments) + buildWalkSegmentIncrement(routeEdge, currentState.lastMode),
            walkDistance = tonumber(currentState.score.walkDistance) + buildWalkDistanceIncrement(routeEdge),
            displayChanges = tonumber(currentState.score.displayChanges) + ((currentState.lastMode and currentState.lastMode ~= edgeMode) and 1 or 0),
            stableKey = tostring(currentState.score.stableKey or "") .. "|" .. buildEdgeStableMarker(routeEdge),
          },
        } -- 候选状态
        candidateState.stateKey = buildRouteStateKey(candidateState.nodeId, candidateState.lastMode)

        local bestState = bestStateByKey[candidateState.stateKey] -- 该状态键的已知最优状态
        if bestState == nil or compareRouteScore(candidateState.score, bestState.score) < 0 then
          bestStateByKey[candidateState.stateKey] = candidateState
          openStateList[#openStateList + 1] = candidateState
        end
      end
    end
  end

  return nil, { code = "NAVIGATION_ERR_NO_ROUTE" }
end

--- 在路径图中查找起点到终点的最少步数路线。
---@param routeGraph table 路径图，包含 `nodes` 与 `edges`
---@param startNodeId any 起点节点 ID
---@param targetNodeId any 终点节点 ID
---@param availabilityContext table|nil 当前角色可用性快照；传入时在展开相邻边时过滤不可用边
---@return table|nil routeResult 成功时包含 `totalSteps`、`segments`、`rawNodePath`、`rawEdgePath`
---@return table|nil errorObject 失败时包含 `code`
function AzerothCompanion.API.Navigation.FindShortestPath(routeGraph, startNodeId, targetNodeId, availabilityContext)
  return findShortestPath(routeGraph, startNodeId, targetNodeId, availabilityContext, false)
end

--- 按当前角色可用性过滤路径图后规划最少步数路线。
---@param routeGraph table 路径图，包含 `nodes` 与 `edges`
---@param startNodeId any 起点节点 ID
---@param targetNodeId any 终点节点 ID
---@param availabilityContext table|nil 当前角色可用性快照
---@return table|nil routeResult 成功时包含 `totalSteps`、`segments`、`rawNodePath`、`rawEdgePath`
---@return table|nil errorObject 失败时包含 `code`
function AzerothCompanion.API.Navigation.PlanRoute(routeGraph, startNodeId, targetNodeId, availabilityContext)
  local routeAvailabilityContext = availabilityContext or {} -- 规划入口保持当前角色过滤语义
  return AzerothCompanion.API.Navigation.FindShortestPath(routeGraph, startNodeId, targetNodeId, routeAvailabilityContext)
end

--- 从路径数据中收集所有需要检查的 spellID，供运行时构建当前角色可用性快照。
---@param routeData table|nil 路径数据；导航运行时只允许传入契约导出的数据表
---@return table spellIDList 去重后的技能 ID 序列
function AzerothCompanion.API.Navigation.GetRequiredSpellIDList(routeData)
  local exportedData = routeData or {} -- 契约导出的路径数据
  local seenSpellID = {} -- 已收集技能 ID 集合
  local spellIDList = {} -- 技能 ID 序列

  for _, edge in ipairs(type(exportedData.edges) == "table" and exportedData.edges or {}) do
    local requirements = type(edge) == "table" and edge.requirements or nil -- 边可用性要求
    local spellID = type(requirements) == "table" and tonumber(requirements.spellID) or nil -- 技能 ID
    if spellID and not seenSpellID[spellID] then
      seenSpellID[spellID] = true
      spellIDList[#spellIDList + 1] = spellID
    end
  end

  local abilityTemplateData = AzerothCompanion.Data and AzerothCompanion.Data.NavigationAbilityTemplates or {} -- 契约导出的能力模板
  local templateTable = type(abilityTemplateData.templates) == "table" and abilityTemplateData.templates or {} -- 模板表
  local templateIDList = {} -- 稳定模板键列表
  for templateID in pairs(templateTable) do
    templateIDList[#templateIDList + 1] = tostring(templateID)
  end
  table.sort(templateIDList)
  for _, templateID in ipairs(templateIDList) do
    local templateDef = templateTable[templateID] -- 模板定义
    local spellID = type(templateDef) == "table" and tonumber(templateDef.SpellID or templateDef.spellID) or nil -- 模板技能 ID
    if spellID and not seenSpellID[spellID] then
      seenSpellID[spellID] = true
      spellIDList[#spellIDList + 1] = spellID
    end
  end

  return spellIDList
end

--- 从 Vector2DMixin 或普通表读取归一化坐标。
---@param vectorValue table|nil 坐标对象
---@return number|nil, number|nil
local function readVectorXY(vectorValue)
  if type(vectorValue) ~= "table" then
    return nil, nil
  end
  if type(vectorValue.GetXY) == "function" then
    local success, x, y = pcall(vectorValue.GetXY, vectorValue) -- GetXY 返回值
    if success and type(x) == "number" and type(y) == "number" then
      return x, y
    end
  end
  local x = vectorValue.x -- 坐标 X
  local y = vectorValue.y -- 坐标 Y
  if type(x) ~= "number" or type(y) ~= "number" then
    return nil, nil
  end
  return x, y
end
AzerothCompanion.API.Navigation.ReadVectorXY = readVectorXY

--- 判断归一化坐标是否合法。
---@param x number|nil 坐标 X
---@param y number|nil 坐标 Y
---@return boolean
local function isNormalizedPosition(x, y)
  return type(x) == "number" and type(y) == "number" and x >= 0 and x <= 1 and y >= 0 and y <= 1
end

-- 炉石落点：faction 枚举 → 阵营主城 UiMapID（枚举来自 UnitFactionGroup，不依赖任何字符串字段做映射）
local FACTION_CAPITAL_UI_MAP_ID = {
  Horde = 85,       -- 奥格瑞玛
  Alliance = 84,    -- 暴风城
}

---@class HearthBindInfo  炉石绑定信息
---@field areaID number|nil  绑定区 ID；当前数据管线尚未提供稳定数值来源，先保留为 nil
---@field uiMapID number|nil  绑定落点对应的 UiMapID；当前由 faction 主城降级推导
---@field nodeID number|nil  解析后的导航节点 ID；当前由 route nodes 的 source lookup 在运行时补解

--- 构建当前角色的炉石绑定信息。
--- 当前 Retail 公开 API 仍只能稳定拿到本地化绑定地点名（GetBindLocation），
--- 在未导出显式静态映射前，这里只保留 faction -> 主城的数值降级路径。
---@param faction string|nil  角色阵营（UnitFactionGroup 枚举）
---@return HearthBindInfo
local function buildHearthBindInfo(faction)
  return {
    areaID = nil,
    uiMapID = FACTION_CAPITAL_UI_MAP_ID[faction],
    nodeID = nil,
  }
end

--- 按 UiMapID 从导出的 route nodes 中解析炉石绑定的 map_anchor 节点。
--- 数字 node ID 迁移后优先返回数字节点；旧版字符串键数据仍兼容返回原字符串键。
---@param uiMapID number|nil 绑定落点 UiMapID
---@return any
local function resolveHearthBindRouteNodeIDByUiMapID(uiMapID)
  local numericUiMapID = tonumber(uiMapID) -- 绑定落点地图 ID
  if not numericUiMapID or numericUiMapID <= 0 then
    return nil
  end

  local routeNodeTable = AzerothCompanion.Data and AzerothCompanion.Data.NavigationRouteEdges and AzerothCompanion.Data.NavigationRouteEdges.nodes or nil -- 统一路线边导出的节点表
  local bestNodeID = nil -- 当前命中的最优 route node ID
  for nodeId, nodeDef in pairs(type(routeNodeTable) == "table" and routeNodeTable or {}) do
    if type(nodeDef) == "table"
      and tostring(nodeDef.Source or nodeDef.source) == "uimap"
      and tostring(nodeDef.Kind or nodeDef.kind) == "map_anchor"
      and tonumber(nodeDef.UiMapID or nodeDef.uiMapID) == numericUiMapID then
      local runtimeNodeID = tonumber(nodeDef.NodeID or nodeDef.nodeID) or tonumber(nodeId) or nodeId -- 兼容新旧节点 ID 口径
      if bestNodeID == nil then
        bestNodeID = runtimeNodeID
      elseif tonumber(runtimeNodeID) and tonumber(bestNodeID) and tonumber(runtimeNodeID) < tonumber(bestNodeID) then
        bestNodeID = runtimeNodeID
      elseif tostring(runtimeNodeID) < tostring(bestNodeID) then
        bestNodeID = runtimeNodeID
      end
    end
  end
  return bestNodeID
end

--- 从导出的导航节点表中收集当前角色已开航点集合。
---@return table
local function buildKnownTaxiNodeByID()
  local knownTaxiNodeByID = {} -- 已开航点集合
  local taxiMapApi = type(C_TaxiMap) == "table" and C_TaxiMap or nil -- 飞行点 API 表
  local getTaxiNodesForMap = taxiMapApi and taxiMapApi.GetTaxiNodesForMap or nil -- 指定地图飞行点查询
  if type(getTaxiNodesForMap) ~= "function" then
    return knownTaxiNodeByID
  end

  local routeNodeTable = AzerothCompanion.Data and AzerothCompanion.Data.NavigationRouteEdges and AzerothCompanion.Data.NavigationRouteEdges.nodes or {} -- 导出的导航节点表
  local checkedUiMapID = {} -- 已查询过的飞行点地图 ID
  for _, nodeDef in pairs(type(routeNodeTable) == "table" and routeNodeTable or {}) do
    local nodeKind = tostring(type(nodeDef) == "table" and (nodeDef.Kind or nodeDef.kind) or "") -- 节点类型
    local nodeUiMapID = tonumber(type(nodeDef) == "table" and (nodeDef.UiMapID or nodeDef.uiMapID) or 0) -- 节点地图 ID
    if nodeKind == "taxi" and nodeUiMapID and nodeUiMapID > 0 and not checkedUiMapID[nodeUiMapID] then
      checkedUiMapID[nodeUiMapID] = true
      local success, taxiNodeList = pcall(getTaxiNodesForMap, nodeUiMapID) -- 当前地图飞行点列表
      if success and type(taxiNodeList) == "table" then
        for _, taxiNodeInfo in ipairs(taxiNodeList) do
          local taxiNodeID = tonumber(type(taxiNodeInfo) == "table" and taxiNodeInfo.nodeID) -- 飞行点 ID
          local isUndiscovered = type(taxiNodeInfo) == "table" and taxiNodeInfo.isUndiscovered == true -- 是否未开启
          if taxiNodeID and taxiNodeID > 0 and not isUndiscovered then
            knownTaxiNodeByID[taxiNodeID] = true
          end
        end
      end
    end
  end

  return knownTaxiNodeByID
end

--- 估算同一地图内两点之间的移动成本。
---@param uiMapID number|nil 地图 ID
---@param fromX number|nil 起点 X
---@param fromY number|nil 起点 Y
---@param toX number|nil 终点 X
---@param toY number|nil 终点 Y
---@return number|nil
local function estimateInMapTravelCost(uiMapID, fromX, fromY, toX, toY)
  if not tonumber(uiMapID) or not isNormalizedPosition(fromX, fromY) or not isNormalizedPosition(toX, toY) then
    return nil
  end
  local deltaX = toX - fromX -- X 轴归一化偏移
  local deltaY = toY - fromY -- Y 轴归一化偏移
  local distance = math.sqrt((deltaX * deltaX) + (deltaY * deltaY)) -- 归一化平面距离
  return math.floor((distance * 120) + 0.5)
end

--- 读取当前角色所在地图与归一化坐标。
---@return table locationSnapshot 仅包含 currentUiMapID/currentX/currentY
local function buildCurrentLocationSnapshot()
  local locationSnapshot = {
    currentUiMapID = nil,
    currentX = nil,
    currentY = nil,
  } -- 当前角色位置快照

  local mapApi = type(C_Map) == "table" and C_Map or nil -- 地图 API 表
  local getBestMapForUnit = mapApi and mapApi.GetBestMapForUnit or nil -- 当前单位所在 UiMap 查询
  if type(getBestMapForUnit) == "function" then
    local success, currentMapID = pcall(getBestMapForUnit, "player") -- 当前角色所在地图查询结果
    if success and type(currentMapID) == "number" and currentMapID > 0 then
      locationSnapshot.currentUiMapID = currentMapID
    end
  end

  local getPlayerMapPosition = mapApi and mapApi.GetPlayerMapPosition or nil -- 当前单位坐标查询
  if locationSnapshot.currentUiMapID and type(getPlayerMapPosition) == "function" then
    local success, positionValue = pcall(getPlayerMapPosition, locationSnapshot.currentUiMapID, "player") -- 当前角色坐标查询结果
    if success then
      local currentX, currentY = readVectorXY(positionValue) -- 当前角色归一化坐标
      if isNormalizedPosition(currentX, currentY) then
        locationSnapshot.currentX = currentX
        locationSnapshot.currentY = currentY
      end
    end
  end

  return locationSnapshot
end

--- 构建当前角色位置快照，供轻量 UI 刷新读取。
---@return table locationSnapshot 仅包含 currentUiMapID/currentX/currentY
function AzerothCompanion.API.Navigation.GetCurrentLocationSnapshot()
  return buildCurrentLocationSnapshot()
end

--- 从当前角色运行时状态构建路径边可用性快照。
--- `C_SpellBook.IsSpellInSpellBook` 是当前 Retail 推荐的 spellbook 查询入口；
--- 旧客户端或测试环境缺失时回退到 `C_SpellBook.IsSpellKnown`，调用失败按未知处理。
---@param spellIDList table|nil 需要确认的技能 ID 列表
---@return table availabilityContext 当前角色可用性快照
function AzerothCompanion.API.Navigation.BuildCurrentCharacterAvailability(spellIDList)
  local availabilityContext = {
    classFile = nil,
    faction = nil,
    currentUiMapID = nil,
    currentX = nil,
    currentY = nil,
    knownSpellByID = {},
    knownTaxiNodeByID = {},
    hearthBindNodeID = nil,
    hearthBindInfo = nil,
  } -- 当前角色可用性快照

  if type(UnitClass) == "function" then
    local success, localizedClassName, classFile = pcall(UnitClass, "player") -- 职业查询结果
    if success then
      availabilityContext.classFile = classFile
    end
  end

  if type(UnitFactionGroup) == "function" then
    local success, factionName = pcall(UnitFactionGroup, "player") -- 阵营查询结果
    if success then
      availabilityContext.faction = factionName
    end
  end

  local locationSnapshot = buildCurrentLocationSnapshot() -- 当前角色位置快照
  availabilityContext.currentUiMapID = locationSnapshot.currentUiMapID
  availabilityContext.currentX = locationSnapshot.currentX
  availabilityContext.currentY = locationSnapshot.currentY

  availabilityContext.knownTaxiNodeByID = buildKnownTaxiNodeByID()

  -- 炉石绑定信息：当前先保留 faction -> 主城的数值降级路径
  -- 兼容层继续回填 hearthBindNodeID；数字 node ID 迁移后优先返回数字节点 ID
  availabilityContext.hearthBindInfo = buildHearthBindInfo(availabilityContext.faction)
  availabilityContext.hearthBindNodeID = resolveHearthBindRouteNodeIDByUiMapID(
    availabilityContext.hearthBindInfo and availabilityContext.hearthBindInfo.uiMapID
  )
  if type(availabilityContext.hearthBindInfo) == "table" and tonumber(availabilityContext.hearthBindNodeID) then
    availabilityContext.hearthBindInfo.nodeID = tonumber(availabilityContext.hearthBindNodeID)
  end

  local spellBookApi = type(C_SpellBook) == "table" and C_SpellBook or nil -- spellbook API 表
  local spellCheckFn = spellBookApi and (spellBookApi.IsSpellInSpellBook or spellBookApi.IsSpellKnown) or nil -- 技能已学判定
  if type(spellCheckFn) == "function" then
    for _, spellID in ipairs(spellIDList or {}) do
      local numericSpellID = tonumber(spellID) -- 技能 ID
      if numericSpellID then
        local success, isKnown = pcall(spellCheckFn, numericSpellID) -- 技能已学查询结果
        if success and isKnown == true then
          availabilityContext.knownSpellByID[numericSpellID] = true
        end
      end
    end
  end

  -- 炉石（SpellID 8690）由物品触发，不依赖于法术书；检查玩家背包中是否有炉石物品（ItemID 6948）
  if not availabilityContext.knownSpellByID[8690] then
    local itemApi = type(C_Item) == "table" and C_Item or nil
    local getItemCountFn = (itemApi and itemApi.GetItemCount) or GetItemCount
    if type(getItemCountFn) == "function" then
      local itemSuccess, itemCount = pcall(getItemCountFn, 6948)
      if itemSuccess and tonumber(itemCount) and tonumber(itemCount) > 0 then
        availabilityContext.knownSpellByID[8690] = true
      end
    end
  end

  return availabilityContext
end

--- 生成最终目标坐标点的步骤文案。
---@param target table 地图目标
---@param targetName string 目标显示名
---@return string
local function buildTargetPointLabel(target, targetName)
  local targetX = tonumber(target and target.x) -- 目标 X
  local targetY = tonumber(target and target.y) -- 目标 Y
  if isNormalizedPosition(targetX, targetY) then
    return string.format("目标位置：%s %.1f, %.1f", tostring(targetName), targetX * 100, targetY * 100)
  end
  return "目标位置：" .. tostring(targetName)
end

--- 为指定地图 ID 建立一组可回退的候选地图 ID。
---@param mapID number|nil 原始地图 ID
---@param mapNodes table 地图节点表
---@return table
local function buildRouteMapCandidateSet(mapID, mapNodes)
  local candidateSet = {} -- 可回退地图 ID 集合
  local currentMapID = tonumber(mapID) -- 当前候选地图 ID
  local guardCount = 0 -- 父链保护计数

  while currentMapID and currentMapID > 0 and guardCount < 16 do
    if candidateSet[currentMapID] then
      break
    end
    candidateSet[currentMapID] = true
    local nodeDef = type(mapNodes) == "table" and mapNodes[currentMapID] or nil -- 当前地图定义
    currentMapID = tonumber(nodeDef and nodeDef.ParentUiMapID) -- 父地图 ID
    guardCount = guardCount + 1
  end
  -- guardCount >= 16: 父链异常过长，静默截断以避免死循环

  return candidateSet
end

--- 统计每个 UiMap 节点参与的路线边数量。
---@param edgeList table|nil 路线边列表
---@return table
local function buildEdgeDegreeByUiMapID(edgeList)
  local degreeByUiMapID = {} -- 地图节点关联边数量
  for _, edge in ipairs(type(edgeList) == "table" and edgeList or {}) do
    local fromUiMapID = tonumber(edge and edge.fromUiMapID) -- 边起点地图 ID
    local toUiMapID = tonumber(edge and edge.toUiMapID) -- 边终点地图 ID
    if fromUiMapID and fromUiMapID > 0 then
      degreeByUiMapID[fromUiMapID] = (degreeByUiMapID[fromUiMapID] or 0) + 1
    end
    if toUiMapID and toUiMapID > 0 then
      degreeByUiMapID[toUiMapID] = (degreeByUiMapID[toUiMapID] or 0) + 1
    end
  end
  return degreeByUiMapID
end

--- 将地图 ID 解析为更适合参与导航的路线节点地图 ID。
---@param rawMapID number|nil 原始地图 ID
---@param resolvedAtPositionMapID number|nil 指定点位解析出的地图 ID
---@param mapNodes table 地图节点表
---@param edgeDegreeByUiMapID table 地图边数量表
---@return number|nil
local function resolveRouteMapID(rawMapID, resolvedAtPositionMapID, mapNodes, edgeDegreeByUiMapID)
  local searchMapIDList = {} -- 需要展开候选的地图 ID 列表
  local searchSet = {} -- 已加入的地图 ID 集合
  local function appendSearchMapID(mapID)
    local numericMapID = tonumber(mapID) -- 目标地图 ID
    if numericMapID and numericMapID > 0 and not searchSet[numericMapID] then
      searchSet[numericMapID] = true
      searchMapIDList[#searchMapIDList + 1] = numericMapID
    end
  end

  appendSearchMapID(rawMapID)
  appendSearchMapID(resolvedAtPositionMapID)

  local rankedCandidateList = {} -- 排序后的候选地图列表
  local rankedSet = {} -- 已加入候选的地图 ID 集合
  local candidateSourceRankByMapID = {} -- 候选来源优先级（原图优先于父链）
  local function pushRankedCandidate(mapID, sourceRank)
    local numericMapID = tonumber(mapID) -- 候选地图 ID
    local numericSourceRank = tonumber(sourceRank) or 99 -- 候选来源分层
    if numericMapID and numericMapID > 0 then
      local previousSourceRank = tonumber(candidateSourceRankByMapID[numericMapID]) -- 已记录来源优先级
      if previousSourceRank == nil or numericSourceRank < previousSourceRank then
        candidateSourceRankByMapID[numericMapID] = numericSourceRank
      end
      if not rankedSet[numericMapID] then
        rankedSet[numericMapID] = true
        rankedCandidateList[#rankedCandidateList + 1] = numericMapID
      end
    end
  end

  for _, searchMapID in ipairs(searchMapIDList) do
    local parentCandidateSet = buildRouteMapCandidateSet(searchMapID, mapNodes) -- 原始地图与父链候选
    pushRankedCandidate(searchMapID, 0)
    for candidateMapID in pairs(parentCandidateSet) do
      if candidateMapID ~= searchMapID then
        pushRankedCandidate(candidateMapID, 1)
      end
    end
  end

  local bestMapID = nil -- 最优候选地图 ID
  local bestScore = nil -- 最优候选评分
  local function isScoreBetter(candidateScore, currentBestScore)
    if currentBestScore == nil then
      return true
    end
    for scoreIndex = 1, #candidateScore do
      local candidateValue = tonumber(candidateScore[scoreIndex]) or 0 -- 当前层级评分
      local bestValue = tonumber(currentBestScore[scoreIndex]) or 0 -- 已知最优层级评分
      if candidateValue ~= bestValue then
        return candidateValue < bestValue
      end
    end
    return false
  end
  for _, candidateMapID in ipairs(rankedCandidateList) do
    local nodeDef = type(mapNodes) == "table" and mapNodes[candidateMapID] or nil -- 候选地图定义
    local mapType = tonumber(nodeDef and nodeDef.MapType) or 99 -- 候选地图类型
    local degree = tonumber(edgeDegreeByUiMapID and edgeDegreeByUiMapID[candidateMapID]) or 0 -- 候选地图关联边数量
    local sourceRank = tonumber(candidateSourceRankByMapID[candidateMapID]) or 99 -- 候选来源优先级
    local mapTypeRank = 4 -- 地图类型优先级
    if mapType == 3 then
      mapTypeRank = 0
    elseif mapType == 6 then
      mapTypeRank = 1
    elseif mapType == 4 or mapType == 5 then
      mapTypeRank = 2
    elseif mapType < 3 then
      mapTypeRank = 3
    end
    local score = {
      mapTypeRank,
      degree > 0 and 0 or 1,
      sourceRank,
      candidateMapID,
    } -- 候选排序分数：只消费原始 ID、点位命中 ID 与父链，不用本地化地图名做逻辑
    if isScoreBetter(score, bestScore) then
      bestScore = score
      bestMapID = candidateMapID
    end
  end

  return bestMapID or tonumber(rawMapID)
end

--- 若目标点位于更具体的子图，优先把目标解析为该子图。
---@param target table 地图目标
---@return table
local function resolveConcreteTarget(target)
  if type(target) ~= "table" then
    return target
  end
  local targetMapID = tonumber(target.uiMapID) -- 原始目标地图 ID
  local targetX = tonumber(target.x) -- 原始目标 X
  local targetY = tonumber(target.y) -- 原始目标 Y
  local mapNodes = AzerothCompanion.Data and AzerothCompanion.Data.NavigationMapNodes and AzerothCompanion.Data.NavigationMapNodes.nodes or {} -- 地图基础节点
  local routeEdgeData = AzerothCompanion.Data and AzerothCompanion.Data.NavigationRouteEdges or {} -- 契约导出的统一路线边数据
  local edgeDegreeByUiMapID = buildEdgeDegreeByUiMapID(routeEdgeData.edges) -- 地图边数量
  if not targetMapID then
    return target
  end

  local mapApi = type(C_Map) == "table" and C_Map or nil -- 地图 API 表
  local getMapInfoAtPosition = mapApi and mapApi.GetMapInfoAtPosition or nil -- 指定点位命中的更具体地图
  local resolvedAtPositionMapID = nil -- 指定点位解析出的更具体地图 ID
  local resolvedName = nil -- 指定点位解析出的地图名
  if isNormalizedPosition(targetX, targetY) and type(getMapInfoAtPosition) == "function" then
    local success, mapInfo = pcall(getMapInfoAtPosition, targetMapID, targetX, targetY) -- 命中的地图信息
    resolvedAtPositionMapID = success and type(mapInfo) == "table" and tonumber(mapInfo.mapID) or nil
    resolvedName = success and type(mapInfo) == "table" and mapInfo.name or nil
  end

  local resolvedMapID = resolveRouteMapID(targetMapID, resolvedAtPositionMapID, mapNodes, edgeDegreeByUiMapID) -- 参与导航的目标地图 ID
  if not resolvedMapID or resolvedMapID <= 0 or resolvedMapID == targetMapID then
    return target
  end

  local resolvedTarget = {} -- 解析后的目标
  for key, value in pairs(target) do
    resolvedTarget[key] = value
  end
  resolvedTarget.uiMapID = resolvedMapID
  if type(resolvedName) == "string" and resolvedName ~= "" then
    resolvedTarget.name = resolvedName
  elseif type(mapNodes[resolvedMapID]) == "table" and type(mapNodes[resolvedMapID].Name_lang) == "string" then
    resolvedTarget.name = mapNodes[resolvedMapID].Name_lang
  end
  return resolvedTarget
end

--- 读取路线边文案。
---@param edge table|nil 路线边
---@return string|nil
local function buildRouteEdgeLabel(edge)
  return type(edge) == "table" and edge.label or nil
end

--- 解析旧版字符串节点键，返回来源与来源侧 ID。
---@param rawNodeKey any 旧版字符串节点键，例如 "uimap_85"
---@return string|nil, number|nil
local function parseLegacyRouteNodeKey(rawNodeKey)
  local normalizedNodeKey = tostring(rawNodeKey or "") -- 旧版字符串节点键
  local sourcePrefix, numericSourceID = string.match(normalizedNodeKey, "^(%a+)_([0-9]+)$")
  if not sourcePrefix or not numericSourceID then
    return nil, nil
  end

  local routeSourceByPrefix = {
    uimap = "uimap",
    taxi = "taxi",
    portal = "portal",
    transport = "waypoint_transport",
    trigger = "areatrigger",
    areatrigger = "areatrigger",
  } -- 旧版节点键前缀到运行时 route source 的映射
  local routeSource = routeSourceByPrefix[sourcePrefix] -- 归一化后的 route source
  if routeSource == nil then
    return nil, nil
  end

  return routeSource, tonumber(numericSourceID)
end

--- 从导出的 route nodes 构建 source/sourceID/kind 到运行时 node ID 的查找表。
---@param nodeTable table|nil 节点定义表
---@return table
local function buildRouteNodeLookupBySource(nodeTable)
  local lookupBySource = {} -- 来源 -> sourceID -> { any = nodeID, [kind] = nodeID }
  for nodeId, nodeDef in pairs(type(nodeTable) == "table" and nodeTable or {}) do
    local routeSource = tostring(type(nodeDef) == "table" and (nodeDef.Source or nodeDef.source) or "") -- 节点来源
    local runtimeNodeID = tonumber(type(nodeDef) == "table" and (nodeDef.id or nodeDef.NodeID or nodeDef.nodeID) or nil) or tonumber(nodeId) or nodeId -- 运行时节点 ID（兼容旧版字符串键）
    local sourceID = tonumber(type(nodeDef) == "table" and (nodeDef.SourceID or nodeDef.sourceID) or nil) -- 来源侧主键
    if sourceID == nil and type(nodeDef) == "table" then
      if routeSource == "uimap" then
        sourceID = tonumber(nodeDef.UiMapID or nodeDef.uiMapID)
      elseif routeSource == "taxi" then
        sourceID = tonumber(nodeDef.TaxiNodeID or nodeDef.taxiNodeID)
      else
        local parsedSource, parsedSourceID = parseLegacyRouteNodeKey(nodeDef.NodeID or nodeDef.nodeID or nodeId) -- 从旧版字符串节点键回推来源侧主键
        if parsedSource == routeSource then
          sourceID = parsedSourceID
        end
      end
    end

    if routeSource ~= "" and sourceID and sourceID > 0 and runtimeNodeID ~= nil then
      lookupBySource[routeSource] = lookupBySource[routeSource] or {}
      local sourceLookup = lookupBySource[routeSource] -- 当前来源查找表
      sourceLookup[sourceID] = sourceLookup[sourceID] or {}
      local sourceEntry = sourceLookup[sourceID] -- 当前来源+主键查找项
      local routeKind = tostring(type(nodeDef) == "table" and (nodeDef.Kind or nodeDef.kind) or "") -- 节点类型
      local currentBestNodeID = sourceEntry.any -- 当前已登记的最优节点 ID
      if currentBestNodeID == nil then
        sourceEntry.any = runtimeNodeID
      elseif tonumber(runtimeNodeID) and tonumber(currentBestNodeID) and tonumber(runtimeNodeID) < tonumber(currentBestNodeID) then
        sourceEntry.any = runtimeNodeID
      elseif tostring(runtimeNodeID) < tostring(currentBestNodeID) then
        sourceEntry.any = runtimeNodeID
      end
      if routeKind ~= "" then
        local currentBestKindNodeID = sourceEntry[routeKind] -- 当前已登记的最优来源+类型节点 ID
        if currentBestKindNodeID == nil then
          sourceEntry[routeKind] = runtimeNodeID
        elseif tonumber(runtimeNodeID) and tonumber(currentBestKindNodeID) and tonumber(runtimeNodeID) < tonumber(currentBestKindNodeID) then
          sourceEntry[routeKind] = runtimeNodeID
        elseif tostring(runtimeNodeID) < tostring(currentBestKindNodeID) then
          sourceEntry[routeKind] = runtimeNodeID
        end
      end
    end
  end
  return lookupBySource
end

--- 按来源与来源侧 ID 查找 route node ID。
---@param lookupBySource table|nil 节点来源查找表
---@param routeSource string|nil 节点来源
---@param sourceID number|nil 来源侧主键
---@param routeKind string|nil 可选节点类型
---@return any
local function findRouteNodeIDBySourceID(lookupBySource, routeSource, sourceID, routeKind)
  local normalizedSource = tostring(routeSource or "") -- 节点来源
  local numericSourceID = tonumber(sourceID) -- 来源侧主键
  if normalizedSource == "" or not numericSourceID or numericSourceID <= 0 then
    return nil
  end
  local sourceLookup = type(lookupBySource) == "table" and lookupBySource[normalizedSource] or nil -- 来源查找表
  local sourceEntry = type(sourceLookup) == "table" and sourceLookup[numericSourceID] or nil -- 来源+主键查找项
  if type(sourceEntry) ~= "table" then
    return nil
  end
  local normalizedKind = tostring(routeKind or "") -- 可选节点类型
  if normalizedKind ~= "" and sourceEntry[normalizedKind] ~= nil then
    return sourceEntry[normalizedKind]
  end
  return sourceEntry.any
end

--- 读取节点的正式步行组件归属与显示代理信息。
---@param runtimeNodeID any 运行时节点 ID
---@return table
local function readFormalWalkNodeMetadata(runtimeNodeID)
  local walkComponentData = AzerothCompanion.Data and AzerothCompanion.Data.NavigationWalkComponents or nil -- 正式步行组件导出
  local assignmentTable = type(walkComponentData) == "table" and walkComponentData.nodeAssignments or nil -- 节点归属表
  local displayProxyTable = type(walkComponentData) == "table" and walkComponentData.displayProxies or nil -- 显示代理表
  local assignmentDef = type(assignmentTable) == "table" and assignmentTable[runtimeNodeID] or nil -- 当前节点归属
  if type(assignmentDef) ~= "table" and type(assignmentTable) == "table" then
    assignmentDef = assignmentTable[tonumber(runtimeNodeID)] or assignmentTable[tostring(runtimeNodeID)]
  end
  if type(assignmentDef) ~= "table" then
    return {}
  end

  local proxyNodeID = tonumber(assignmentDef.DisplayProxyNodeID or assignmentDef.displayProxyNodeID) -- 归属里指定的显示代理节点
  local proxyDef = type(displayProxyTable) == "table" and displayProxyTable[runtimeNodeID] or nil -- 以当前节点为键的显示代理定义
  if type(proxyDef) ~= "table" and type(displayProxyTable) == "table" then
    proxyDef = displayProxyTable[tostring(runtimeNodeID)]
  end
  if type(proxyDef) ~= "table" and type(displayProxyTable) == "table" and proxyNodeID then
    proxyDef = displayProxyTable[proxyNodeID] or displayProxyTable[tostring(proxyNodeID)]
  end

  local hiddenInSemanticChain = assignmentDef.HiddenInSemanticChain -- 是否在语义链路中隐藏
  if type(hiddenInSemanticChain) ~= "boolean" then
    hiddenInSemanticChain = false
  end
  local roleName = trimText(assignmentDef.Role or assignmentDef.role) -- 正式步行组件角色
  local visibleName = assignmentDef.VisibleName or assignmentDef.visibleName -- 归属层显式可见名
  if trimText(visibleName) == "" then
    visibleName = type(proxyDef) == "table" and (proxyDef.VisibleName or proxyDef.visibleName) or nil
  end

  return {
    componentID = assignmentDef.ComponentID or assignmentDef.componentID,
    role = roleName,
    hiddenInSemanticChain = hiddenInSemanticChain,
    visibleName = trimText(visibleName),
  }
end

--- 向路径图写入一组节点定义。
---@param routeGraph table 正在构建的路径图
---@param nodeTable table|nil 节点定义表
local function addRouteGraphNodes(routeGraph, nodeTable)
  for nodeId, nodeDef in pairs(type(nodeTable) == "table" and nodeTable or {}) do
    if type(nodeDef) == "table" then
      local numericNodeID = tonumber(nodeDef.NodeID or nodeDef.nodeID) or tonumber(nodeId) -- 数字节点 ID
      local runtimeNodeID = numericNodeID or nodeId -- 运行时节点 ID
      local formalWalkMetadata = readFormalWalkNodeMetadata(runtimeNodeID) -- 正式步行组件归属与显示代理
      routeGraph.nodes[runtimeNodeID] = {
        id = runtimeNodeID,
        name = nodeDef.Name_lang or tostring(runtimeNodeID),
        uiMapID = tonumber(nodeDef.UiMapID),
        mapID = tonumber(nodeDef.MapID or nodeDef.mapID),
        expansionID = tonumber(nodeDef.ExpansionID or nodeDef.expansionID),
        source = nodeDef.Source or nodeDef.source,
        sourceID = tonumber(nodeDef.SourceID or nodeDef.sourceID),
        kind = nodeDef.Kind or nodeDef.kind,
        taxiNodeID = tonumber(nodeDef.TaxiNodeID or nodeDef.taxiNodeID),
        walkComponentID = formalWalkMetadata.componentID,
        walkComponentRole = formalWalkMetadata.role,
        hiddenInSemanticChain = formalWalkMetadata.hiddenInSemanticChain,
        visibleName = formalWalkMetadata.visibleName,
      }
    end
  end
end

--- 向路径图追加一组边定义。
---@param routeGraph table 正在构建的路径图
---@param edgeList table|nil 边定义列表
local function addRouteGraphEdges(routeGraph, edgeList)
  for _, edge in ipairs(type(edgeList) == "table" and edgeList or {}) do
    local edgeCopy = {} -- 运行时路线边副本
    for key, value in pairs(type(edge) == "table" and edge or {}) do
      edgeCopy[key] = value
    end
    edgeCopy.label = buildRouteEdgeLabel(edgeCopy) or edgeCopy.label
    edgeCopy.stepCost = tonumber(edgeCopy.stepCost or edgeCopy.StepCost) or 1
    edgeCopy.mode = edgeCopy.mode or edgeCopy.Mode or "unknown"
    edgeCopy.traversedUiMapIDs = copyArray(edgeCopy.traversedUiMapIDs or edgeCopy.TraversedUiMapIDs)
    edgeCopy.traversedUiMapNames = copyArray(edgeCopy.traversedUiMapNames or edgeCopy.TraversedUiMapNames)
    appendRouteGraphEdge(routeGraph, edgeCopy)
  end
end

--- 若当前角色已在某个路径节点对应地图，添加零成本起点边。
---@param routeGraph table 正在构建的路径图
---@param availabilityContext table|nil 当前角色可用性快照
---@param routeNodeLookupBySource table|nil route node 来源查找表
local function addCurrentLocationEdges(routeGraph, availabilityContext, routeNodeLookupBySource)
  local currentMapID = tonumber(availabilityContext and availabilityContext.currentUiMapID) -- 当前角色所在地图
  if not currentMapID then
    return
  end

  local currentX = tonumber(availabilityContext and availabilityContext.currentX) -- 当前角色 X
  local currentY = tonumber(availabilityContext and availabilityContext.currentY) -- 当前角色 Y
  local resolvedAtPositionMapID = nil -- 当前点位命中的更具体地图 ID
  local mapApi = type(C_Map) == "table" and C_Map or nil -- 地图 API 表
  local getMapInfoAtPosition = mapApi and mapApi.GetMapInfoAtPosition or nil -- 指定点位命中的更具体地图
  if isNormalizedPosition(currentX, currentY) and type(getMapInfoAtPosition) == "function" then
    local success, mapInfo = pcall(getMapInfoAtPosition, currentMapID, currentX, currentY) -- 当前点位命中的地图信息
    resolvedAtPositionMapID = success and type(mapInfo) == "table" and tonumber(mapInfo.mapID) or nil
  end

  local mapNodes = AzerothCompanion.Data and AzerothCompanion.Data.NavigationMapNodes and AzerothCompanion.Data.NavigationMapNodes.nodes or {} -- 地图基础节点
  local routeEdgeData = AzerothCompanion.Data and AzerothCompanion.Data.NavigationRouteEdges or {} -- 契约导出的统一路线边数据
  local edgeDegreeByUiMapID = buildEdgeDegreeByUiMapID(routeEdgeData.edges) -- 地图边数量
  local resolvedCurrentMapID = resolveRouteMapID(currentMapID, resolvedAtPositionMapID, mapNodes, edgeDegreeByUiMapID) -- 可参与导航的当前地图 ID

  local currentNodeID = findRouteNodeIDBySourceID(routeNodeLookupBySource, "uimap", resolvedCurrentMapID, "map_anchor") -- 当前地图对应的 route node ID
  local currentNode = currentNodeID and routeGraph.nodes[currentNodeID] or nil -- 当前地图 route node
  if currentNodeID and currentNode then
    appendRouteGraphEdge(routeGraph, {
      from = "current",
      to = currentNodeID,
      cost = 0,
      stepCost = 1,
      label = "当前位置：" .. tostring(currentNode.name or currentNodeID),
      mode = WALK_LOCAL_MODE,
      traversedUiMapIDs = { resolvedCurrentMapID },
      traversedUiMapNames = { tostring(currentNode.name or currentNodeID) },
    })
  end
end

--- 向路径图追加一条本地步行边。
---@param routeGraph table 正在构建的路径图
---@param fromNodeId any 起点节点 ID
---@param toNodeId any 终点节点 ID
---@param traversedUiMapIDs table|nil 经过地图 ID 列表
---@param traversedUiMapNames table|nil 经过地图名称列表
local function addWalkLocalEdge(routeGraph, fromNodeId, toNodeId, traversedUiMapIDs, traversedUiMapNames)
  if fromNodeId == nil or toNodeId == nil or fromNodeId == toNodeId then
    return
  end
  if routeGraph.nodes[fromNodeId] == nil or routeGraph.nodes[toNodeId] == nil then
    return
  end
  local fromNode = routeGraph.nodes[fromNodeId] or {} -- 起点节点
  local toNode = routeGraph.nodes[toNodeId] or {} -- 终点节点
  local fromDisplayName = buildWalkLabelEndpointName(traversedUiMapNames, tostring(fromNode.name or fromNodeId), false) -- 步行段起点显示名
  local toDisplayName = buildWalkLabelEndpointName(traversedUiMapNames, tostring(toNode.name or toNodeId), true) -- 步行段终点显示名
  appendRouteGraphEdge(routeGraph, {
    from = fromNodeId,
    to = toNodeId,
    cost = 0,
    stepCost = 1,
    label = string.format("步行：%s -> %s", fromDisplayName, toDisplayName),
    mode = WALK_LOCAL_MODE,
    walkDistance = 0,
    traversedUiMapIDs = copyArray(traversedUiMapIDs),
    traversedUiMapNames = copyArray(traversedUiMapNames),
  })
end

--- 从 formal walk component 的显式 localEdges 读取本地步行接线。
---@param routeGraph table 正在构建的路径图
local function addFormalWalkLocalEdges(routeGraph)
  local walkComponentData = AzerothCompanion.Data and AzerothCompanion.Data.NavigationWalkComponents or nil -- 正式步行组件导出
  local localEdgeTable = type(walkComponentData) == "table" and walkComponentData.localEdges or nil -- 显式本地步行边
  if type(localEdgeTable) ~= "table" then
    return
  end

  for _, localEdgeDef in pairs(localEdgeTable) do
    if type(localEdgeDef) == "table" then
      local fromNodeID = tonumber(localEdgeDef.FromNodeID or localEdgeDef.fromNodeID or localEdgeDef.from) -- 本地边起点
      local toNodeID = tonumber(localEdgeDef.ToNodeID or localEdgeDef.toNodeID or localEdgeDef.to) -- 本地边终点
      local modeName = trimText(localEdgeDef.Mode or localEdgeDef.mode) -- 本地边模式
      if modeName == "" or modeName == WALK_LOCAL_MODE then
        addWalkLocalEdge(
          routeGraph,
          fromNodeID,
          toNodeID,
          localEdgeDef.TraversedUiMapIDs or localEdgeDef.traversedUiMapIDs,
          localEdgeDef.TraversedUiMapNames or localEdgeDef.traversedUiMapNames
        )
      end
    end
  end
end

--- 判断能力模板是否满足当前角色可用性。
---@param templateDef table|nil 能力模板
---@param availabilityContext table|nil 当前角色可用性快照
---@return boolean
local function isAbilityTemplateAvailable(templateDef, availabilityContext)
  if type(templateDef) ~= "table" then
    return false
  end
  local context = availabilityContext or {} -- 当前角色上下文
  local classFile = templateDef.ClassFile or templateDef.classFile -- 模板职业限制
  local factionGroup = templateDef.FactionGroup or templateDef.factionGroup -- 模板阵营限制
  local spellID = tonumber(templateDef.SpellID or templateDef.spellID) -- 模板技能 ID
  if classFile and classFile ~= context.classFile then
    return false
  end
  if factionGroup and factionGroup ~= context.faction then
    return false
  end
  if spellID then
    local knownSpellByID = context.knownSpellByID -- 已确认技能集合
    if type(knownSpellByID) ~= "table" or knownSpellByID[spellID] ~= true then
      return false
    end
  end
  return true
end

--- 解析能力模板本次查询的目标节点。
---@param templateDef table|nil 能力模板
---@param availabilityContext table|nil 当前角色可用性快照
---@param routeNodeLookupBySource table|nil route node 来源查找表
---@return any
local function resolveAbilityTemplateTargetNodeID(templateDef, availabilityContext, routeNodeLookupBySource)
  local targetRuleKind = tostring(type(templateDef) == "table" and (templateDef.TargetRuleKind or templateDef.targetRuleKind) or "") -- 目标规则
  if targetRuleKind == "fixed_node" then
    local rawToNodeID = type(templateDef) == "table" and (templateDef.ToNodeID or templateDef.toNodeID) or nil -- 模板原始目标节点
    local numericToNodeID = tonumber(rawToNodeID) -- 新版数字节点 ID
    if numericToNodeID then
      return numericToNodeID
    end
    local routeSource, sourceID = parseLegacyRouteNodeKey(rawToNodeID) -- 旧版字符串节点键
    return findRouteNodeIDBySourceID(routeNodeLookupBySource, routeSource, sourceID)
  end
  if targetRuleKind == "hearth_bind" then
    local explicitNodeID = availabilityContext and availabilityContext.hearthBindNodeID -- 兼容旧输入字段的炉石落点节点
    local numericExplicitNodeID = tonumber(explicitNodeID) -- 数字节点 ID 优先
    if numericExplicitNodeID then
      return numericExplicitNodeID
    end
    local explicitRouteSource, explicitSourceID = parseLegacyRouteNodeKey(explicitNodeID) -- 旧版字符串节点键
    local compatibilityNodeID = findRouteNodeIDBySourceID(routeNodeLookupBySource, explicitRouteSource, explicitSourceID)
    if compatibilityNodeID ~= nil then
      return compatibilityNodeID
    end

    local info = availabilityContext and availabilityContext.hearthBindInfo
    local resolvedNodeID = tonumber(info and info.nodeID) -- 直接解析出的目标节点
    if resolvedNodeID then
      return resolvedNodeID
    end
    return findRouteNodeIDBySourceID(routeNodeLookupBySource, "uimap", info and info.uiMapID, "map_anchor")
  end
  return nil
end

--- 按当前角色配置从能力模板展开边。
---@param routeGraph table 正在构建的路径图
---@param availabilityContext table|nil 当前角色可用性快照
---@param routeNodeLookupBySource table|nil route node 来源查找表
local function addAbilityTemplateEdges(routeGraph, availabilityContext, routeNodeLookupBySource)
  local abilityTemplateData = AzerothCompanion.Data and AzerothCompanion.Data.NavigationAbilityTemplates or {} -- 契约导出的能力模板
  local templateTable = type(abilityTemplateData.templates) == "table" and abilityTemplateData.templates or {} -- 模板表
  local templateIDList = {} -- 稳定模板键列表
  for templateID in pairs(templateTable) do
    templateIDList[#templateIDList + 1] = tostring(templateID)
  end
  table.sort(templateIDList)

  for _, templateID in ipairs(templateIDList) do
    local templateDef = templateTable[templateID] -- 模板定义
    if isAbilityTemplateAvailable(templateDef, availabilityContext) then
      local toNodeId = resolveAbilityTemplateTargetNodeID(templateDef, availabilityContext, routeNodeLookupBySource) -- 模板展开后的目标节点
      local targetNode = toNodeId and routeGraph.nodes[toNodeId] or nil -- 目标节点定义
      if toNodeId and targetNode then
        local templateSpellID = tonumber(templateDef.SpellID or templateDef.spellID) -- 模板技能 ID
        local templateClassFile = trimText(templateDef.ClassFile or templateDef.classFile) -- 模板职业限制
        local templateFactionGroup = trimText(templateDef.FactionGroup or templateDef.factionGroup) -- 模板阵营限制
        local requirements = {} -- 展开边的可用性背景
        if templateClassFile == "" then
          templateClassFile = nil
        end
        if templateFactionGroup == "" then
          templateFactionGroup = nil
        end
        if templateClassFile then
          requirements.classFile = templateClassFile
        end
        if templateFactionGroup then
          requirements.faction = templateFactionGroup
        end
        if templateSpellID then
          requirements.spellID = templateSpellID
        end
        appendRouteGraphEdge(routeGraph, {
          from = "current",
          to = toNodeId,
          cost = 0,
          stepCost = 1,
          label = tostring(templateDef.Label or templateDef.label or templateID),
          mode = tostring(templateDef.Mode or templateDef.mode or "unknown"),
          Source = "ability_template",
          SourceID = templateID,
          AbilityTemplateID = templateID,
          SpellID = templateSpellID,
          ClassFile = templateClassFile,
          FactionRequirement = templateFactionGroup,
          requirements = next(requirements) and requirements or nil,
          traversedUiMapIDs = targetNode.uiMapID and { targetNode.uiMapID } or {},
          traversedUiMapNames = { tostring(targetNode.name or toNodeId) },
        })
      end
    end
  end
end

--- 计算当前位置直接前往目标点的成本。
---@param target table 地图目标
---@param availabilityContext table|nil 当前角色可用性快照
---@return number
local function buildDirectTargetCost(target, availabilityContext)
  local targetMapID = tonumber(target and target.uiMapID) -- 目标地图 ID
  local currentMapID = tonumber(availabilityContext and availabilityContext.currentUiMapID) -- 当前地图 ID
  local currentX = tonumber(availabilityContext and availabilityContext.currentX) -- 当前 X
  local currentY = tonumber(availabilityContext and availabilityContext.currentY) -- 当前 Y
  local targetX = tonumber(target and target.x) -- 目标 X
  local targetY = tonumber(target and target.y) -- 目标 Y
  if targetMapID and currentMapID and targetMapID == currentMapID then
    local travelCost = estimateInMapTravelCost(targetMapID, currentX, currentY, targetX, targetY) -- 同图直接移动成本
    if tonumber(travelCost) then
      return travelCost
    end
  end
  return 180
end

--- 构建第一版地图目标路径图。
---@param target table 目标，包含 `uiMapID` 与可选 `x` / `y`
---@param availabilityContext table|nil 当前角色可用性快照
---@return table routeGraph 路径图
local function buildMapTargetRouteGraph(target, availabilityContext)
  local targetMapID = tonumber(target and target.uiMapID) or 0 -- 目标地图 ID
  local mapNodes = AzerothCompanion.Data and AzerothCompanion.Data.NavigationMapNodes and AzerothCompanion.Data.NavigationMapNodes.nodes or {} -- 地图基础节点
  local routeEdgeData = AzerothCompanion.Data and AzerothCompanion.Data.NavigationRouteEdges or {} -- 契约导出的统一路线边数据
  local targetNodeId = "target" -- 目标节点 ID
  local targetNode = mapNodes[targetMapID] -- 目标地图节点
  local targetName = tostring((target and target.name) or (targetNode and targetNode.Name_lang) or ("Map #" .. tostring(targetMapID))) -- 目标显示名
  local targetPointLabel = buildTargetPointLabel(target, targetName) -- 目标坐标点步骤文案
  local mergedNodes = {} -- 契约导出节点的合并视图
  local routeGraph = {
    nodes = {
      current = { id = "current", name = "当前位置" },
      target = { id = targetNodeId, name = targetName },
    },
    edges = {},
    edgeListByFrom = {},
  } -- 目标路径图；所有跨地图路线边由契约导出，运行时只补当前位置与目标坐标点

  for nodeId, nodeDef in pairs(type(routeEdgeData.nodes) == "table" and routeEdgeData.nodes or {}) do
    if mergedNodes[nodeId] == nil then
      mergedNodes[nodeId] = nodeDef
    end
  end

  addRouteGraphNodes(routeGraph, mergedNodes)
  local routeNodeLookupBySource = buildRouteNodeLookupBySource(routeGraph.nodes) -- 统一 route node 来源查找表
  local targetMapNodeId = findRouteNodeIDBySourceID(routeNodeLookupBySource, "uimap", targetMapID, "map_anchor") -- 目标 UiMap 对应的 route node ID
  addRouteGraphEdges(routeGraph, routeEdgeData.edges)
  addFormalWalkLocalEdges(routeGraph)
  addCurrentLocationEdges(routeGraph, availabilityContext, routeNodeLookupBySource)
  addAbilityTemplateEdges(routeGraph, availabilityContext, routeNodeLookupBySource)

  if targetMapNodeId and routeGraph.nodes[targetMapNodeId] ~= nil then
    appendRouteGraphEdge(routeGraph, {
      from = targetMapNodeId,
      to = targetNodeId,
      cost = buildDirectTargetCost(target, { currentUiMapID = targetMapID }),
      stepCost = 1,
      label = targetPointLabel,
      mode = WALK_LOCAL_MODE,
      traversedUiMapIDs = { targetMapID },
      traversedUiMapNames = { targetName },
    })
  end

  return routeGraph
end

--- 按目标 UiMapID 从运行时图中读取资料片 ID。
---@param routeGraph table 路径图
---@param uiMapID number|nil 目标地图 ID
---@return number|nil
local function findRouteGraphExpansionIDByUiMapID(routeGraph, uiMapID)
  local targetUiMapID = tonumber(uiMapID) -- 需要查询的地图 ID
  if targetUiMapID == nil or type(routeGraph) ~= "table" or type(routeGraph.nodes) ~= "table" then
    return nil
  end
  for _, nodeDef in pairs(routeGraph.nodes) do
    local nodeUiMapID = tonumber(type(nodeDef) == "table" and nodeDef.uiMapID) -- 节点地图 ID
    local nodeExpansionID = tonumber(type(nodeDef) == "table" and nodeDef.expansionID) -- 节点资料片 ID
    if nodeUiMapID == targetUiMapID and nodeExpansionID ~= nil then
      return nodeExpansionID
    end
  end
  return nil
end

--- 规划当前角色前往世界地图目标的第一版路线。
---@param target table 目标，包含 `uiMapID` 与可选 `x` / `y`
---@param availabilityContext table|nil 当前角色可用性快照
---@return table|nil routeResult 成功时包含 `totalCost`、`nodePath`、`stepLabels`
---@return table|nil errorObject 失败时包含 `code`
function AzerothCompanion.API.Navigation.PlanRouteToMapTarget(target, availabilityContext)
  if type(target) ~= "table" or type(target.uiMapID) ~= "number" then
    return nil, { code = "NAVIGATION_ERR_BAD_TARGET" }
  end
  local resolvedTarget = resolveConcreteTarget(target) -- 解析后的具体目标
  local targetMapID = tonumber(resolvedTarget.uiMapID) -- 目标地图 ID
  local mapNodes = AzerothCompanion.Data and AzerothCompanion.Data.NavigationMapNodes and AzerothCompanion.Data.NavigationMapNodes.nodes or {} -- 地图基础节点
  local targetMapNode = mapNodes[targetMapID] -- 目标地图定义
  local targetMapType = tonumber(targetMapNode and targetMapNode.MapType) -- 目标地图类型
  if targetMapType and targetMapType < 3 then
    return nil, { code = "NAVIGATION_ERR_UNSUPPORTED_MAP_LEVEL" }
  end
  local routeGraph = buildMapTargetRouteGraph(resolvedTarget, availabilityContext) -- 第一版目标路径图
  local targetExpansionID = findRouteGraphExpansionIDByUiMapID(routeGraph, targetMapID) -- 目标资料片 ID
  local routeResult, errorObject = findShortestPath(routeGraph, "current", "target", availabilityContext or {}, false, targetMapID, targetExpansionID) -- 当前角色真实可用路线
  if routeResult or type(errorObject) ~= "table" or errorObject.code ~= "NAVIGATION_ERR_NO_ROUTE" then
    return routeResult, errorObject
  end
  return findShortestPath(routeGraph, "current", "target", availabilityContext or {}, true, targetMapID, targetExpansionID)
end
