--[[
  冒险指南（领域对外 API）：封装 WoW 原生 API，提供高层查询接口。
  职责：
    1. 锁定查询：GetAllLockoutsForInstance - 查询副本所有难度的锁定信息
    2. 首领查询：GetKilledBosses - 查询副本已击杀的首领列表
    3. UI 状态查询：IsRaidOrDungeonInstanceListTab - 检查当前是否在副本列表标签页
    4. 掉落筛选：HasMatchingDropsForInstance - 按类型与获取状态检查副本掉落
]]

AzerothCompanion.API.EncounterJournal = AzerothCompanion.API.EncounterJournal or {}

-- ============================================================================
-- 内部辅助函数
-- ============================================================================

--- 读取 journalInstanceID 对应的地图 ID（优先运行时 API，静态表兜底）。
---@param journalInstanceID number 冒险手册副本 ID
---@return number|nil mapID
local function getJournalMapID(journalInstanceID)
  if type(journalInstanceID) ~= "number" then
    return nil
  end

  -- Blizzard AdventureGuideUtil 使用 select(10, EJ_GetInstanceInfo(journalInstanceID)) 读取 mapID。
  if type(EJ_GetInstanceInfo) == "function" then
    local infoSuccess, _, _, _, _, _, _, _, _, _, mapID = pcall(EJ_GetInstanceInfo, journalInstanceID)
    if infoSuccess and type(mapID) == "number" and mapID > 0 then
      return mapID
    end
  end

  local mapData = AzerothCompanion.Data and AzerothCompanion.Data.InstanceMapIDs
  local staticMapID = type(mapData) == "table" and mapData[journalInstanceID] or nil
  if type(staticMapID) == "number" and staticMapID > 0 then
    return staticMapID
  end

  return nil
end

--- 读取 journalInstanceID 对应的副本名称（用于 mapID 不可用时兜底）。
---@param journalInstanceID number 冒险手册副本 ID
---@return string|nil instanceName
local function getJournalInstanceName(journalInstanceID)
  if type(journalInstanceID) ~= "number" then
    return nil
  end

  if type(EJ_GetInstanceInfo) ~= "function" then
    return nil
  end

  local infoSuccess, instanceName = pcall(EJ_GetInstanceInfo, journalInstanceID)
  if infoSuccess and type(instanceName) == "string" and instanceName ~= "" then
    return instanceName
  end

  return nil
end

--- 将地图 ID 映射到 journalInstanceID（运行时权威路径）。
---@param mapID number 地图 ID（GetSavedInstanceInfo 第14个返回值）
---@return number|nil journalInstanceID
local function mapGameMapIDToJournalID(mapID)
  if type(mapID) ~= "number" then
    return nil
  end

  if C_EncounterJournal and type(C_EncounterJournal.GetInstanceForGameMap) == "function" then
    local mapSuccess, journalInstanceID = pcall(C_EncounterJournal.GetInstanceForGameMap, mapID)
    if mapSuccess and type(journalInstanceID) == "number" and journalInstanceID > 0 then
      return journalInstanceID
    end
  end

  return nil
end

local function doesSavedInstanceNameMatch(savedInstanceName, targetInstanceName)
  if type(savedInstanceName) ~= "string" or savedInstanceName == "" then
    return false
  end
  if type(targetInstanceName) ~= "string" or targetInstanceName == "" then
    return false
  end
  return savedInstanceName == targetInstanceName
end

--- 判断 SavedInstances 条目是否属于目标 journalInstanceID。
---@param savedMapID number SavedInstances 的 instanceId（mapID）
---@param savedInstanceName string|nil SavedInstances 副本名
---@param journalInstanceID number 目标冒险手册副本 ID
---@param targetMapID number|nil 目标副本 mapID（可选）
---@param targetInstanceName string|nil 目标副本名（可选）
---@return boolean
local function isSavedInstanceForJournal(savedMapID, savedInstanceName, journalInstanceID, targetMapID, targetInstanceName)
  if type(journalInstanceID) ~= "number" then
    return false
  end

  if type(savedMapID) == "number" and savedMapID > 0 then
    local runtimeJournalID = mapGameMapIDToJournalID(savedMapID)
    if type(runtimeJournalID) == "number" then
      return runtimeJournalID == journalInstanceID
    end

    if type(targetMapID) == "number" and targetMapID > 0 then
      return savedMapID == targetMapID
    end

    -- 运行时 API 不可用时，保留静态表同键对齐兜底（禁止 mapID 反向遍历，避免歧义）。
    local mapData = AzerothCompanion.Data and AzerothCompanion.Data.InstanceMapIDs
    if type(mapData) == "table" and mapData[journalInstanceID] == savedMapID then
      return true
    end
  end

  -- mapID 缺失或不可判定时，按副本名称兜底匹配。
  return doesSavedInstanceNameMatch(savedInstanceName, targetInstanceName)
end

--- 格式化重置剩余时间（用于 tooltip 文本）。
---@param seconds number
---@return string
local function formatResetDuration(seconds)
  local loc = AzerothCompanion.Localization.Strings or {}
  local days = math.floor(seconds / 86400)
  local hours = math.floor((seconds % 86400) / 3600)
  local mins = math.floor((seconds % 3600) / 60)
  if days > 0 then
    return string.format(loc.EJ_LOCKOUT_TIME_DAY_HOUR_FMT or "%dd %dh", days, hours)
  end
  if hours > 0 then
    return string.format(loc.EJ_LOCKOUT_TIME_HOUR_MIN_FMT or "%dh %dm", hours, mins)
  end
  return string.format(loc.EJ_LOCKOUT_TIME_MIN_FMT or "%dm", mins)
end

-- ============================================================================
-- 锁定查询 API
-- ============================================================================

--- 获取副本的所有难度锁定信息
---@param journalInstanceID number 冒险指南副本 ID
---@return table[] lockouts 锁定列表
--- 返回格式：[{
---   difficultyID = number,
---   difficultyName = string,
---   resetTime = number,        -- 剩余秒数
---   encounterProgress = number, -- 已击杀数
---   numEncounters = number,     -- 总首领数
---   isRaid = boolean,
---   isExtended = boolean
--- }]
function AzerothCompanion.API.EncounterJournal.GetAllLockoutsForInstance(journalInstanceID)
  -- 参数校验
  if type(journalInstanceID) ~= "number" then
    return {}
  end

  -- API 可用性检查
  if not GetNumSavedInstances or not GetSavedInstanceInfo then
    return {}
  end

  local lockouts = {}
  local numSaved = GetNumSavedInstances()
  local targetMapID = getJournalMapID(journalInstanceID)
  local targetInstanceName = getJournalInstanceName(journalInstanceID)

  for i = 1, numSaved do
    -- 安全调用（防止 API 变更）
    -- 返回值：name, lockoutId, reset, difficultyId, locked, extended, instanceIDMostSig,
    --         isRaid, maxPlayers, difficultyName, numEncounters, encounterProgress, extendDisabled, instanceId
    local success, name, lockoutId, reset, difficulty, locked, extended,
          instanceIDMostSig, isRaid, maxPlayers, difficultyName,
          numEncounters, encounterProgress, extendDisabled, instanceId = pcall(GetSavedInstanceInfo, i)

    local mappedSuccess = isSavedInstanceForJournal(instanceId, name, journalInstanceID, targetMapID, targetInstanceName)
    -- 只添加未过期的锁定（reset > 0 表示还有剩余时间）
    if mappedSuccess and reset and reset > 0 then
      table.insert(lockouts, {
        difficultyID = difficulty,
        difficultyName = difficultyName or "Unknown",
        resetTime = reset or 0,
        encounterProgress = encounterProgress or 0,
        numEncounters = numEncounters or 0,
        isRaid = isRaid == true,
        isExtended = extended == true
      })
    end
  end

  return lockouts
end

--- 获取冒险手册当前选中的难度 ID（来自右侧难度下拉）。
---@return number|nil difficultyID
function AzerothCompanion.API.EncounterJournal.GetSelectedDifficultyID()
  if type(EJ_GetDifficulty) ~= "function" then
    return nil
  end
  local ok, difficultyID = pcall(EJ_GetDifficulty)
  if ok and type(difficultyID) == "number" then
    return difficultyID
  end
  return nil
end

--- 获取指定副本在指定难度下的锁定信息（精确匹配难度 ID）。
---@param journalInstanceID number
---@param difficultyID number|nil
---@return table|nil lockout
function AzerothCompanion.API.EncounterJournal.GetLockoutForInstanceAndDifficulty(journalInstanceID, difficultyID)
  if type(journalInstanceID) ~= "number" then
    return nil
  end
  local lockouts = AzerothCompanion.API.EncounterJournal.GetAllLockoutsForInstance(journalInstanceID)
  if #lockouts == 0 then
    return nil
  end
  if type(difficultyID) == "number" then
    for _, lockout in ipairs(lockouts) do
      if lockout and lockout.difficultyID == difficultyID then
        return lockout
      end
    end
    return nil
  end
  if #lockouts == 1 then
    return lockouts[1]
  end
  return nil
end

--- 汇总当前角色所有已锁定副本（按剩余时间升序）。
---@return table[] lockouts
--- 返回格式：[{ instanceName=string, difficultyName=string, resetTime=number, isRaid=boolean, encounterProgress=number, numEncounters=number, isExtended=boolean }]
function AzerothCompanion.API.EncounterJournal.GetSavedInstanceLockoutSummary()
  if not GetNumSavedInstances or not GetSavedInstanceInfo then
    return {}
  end

  local lockouts = {}
  local savedCount = GetNumSavedInstances()
  for idx = 1, savedCount do
    local ok, instanceName, lockoutId, resetTime, difficultyId, isLocked, isExtended,
      instanceIDMostSig, isRaid, maxPlayers, difficultyName, numEncounters,
      encounterProgress = pcall(GetSavedInstanceInfo, idx)
    -- Retail 下部分有效 CD 记录会出现 isLocked=false（尤其是非实例 ID 绑定场景），
    -- 这里以 resetTime>0 作为“仍有锁定信息”的主判据，避免摘要漏报。
    if ok and resetTime and resetTime > 0 then
      lockouts[#lockouts + 1] = {
        instanceName = instanceName or "",
        difficultyName = difficultyName or "",
        resetTime = resetTime or 0,
        isRaid = isRaid == true,
        encounterProgress = encounterProgress or 0,
        numEncounters = numEncounters or 0,
        isExtended = isExtended == true,
      }
    end
  end

  table.sort(lockouts, function(left, right)
    local leftReset = left.resetTime or 0
    local rightReset = right.resetTime or 0
    if leftReset ~= rightReset then
      return leftReset < rightReset
    end
    local leftName = left.instanceName or ""
    local rightName = right.instanceName or ""
    if leftName ~= rightName then
      return leftName < rightName
    end
    local leftDifficulty = left.difficultyName or ""
    local rightDifficulty = right.difficultyName or ""
    return leftDifficulty < rightDifficulty
  end)

  return lockouts
end

--- 构建“当前副本锁定”tooltip 行文本。
---@param maxLines number|nil 最多行数，默认 8，上限 30
---@return string[] lines
---@return number overflow 未显示的其余条数
function AzerothCompanion.API.EncounterJournal.BuildSavedInstanceLockoutTooltipLines(maxLines)
  local lineLimit = tonumber(maxLines) or 8
  if lineLimit < 1 then
    lineLimit = 1
  end
  if lineLimit > 30 then
    lineLimit = 30
  end

  local loc = AzerothCompanion.Localization.Strings or {}
  local allLockouts = AzerothCompanion.API.EncounterJournal.GetSavedInstanceLockoutSummary()
  local lineCount = math.min(#allLockouts, lineLimit)
  local lines = {}

  for idx = 1, lineCount do
    local lockout = allLockouts[idx]
    local instanceName = lockout.instanceName or ""
    local difficultyName = lockout.difficultyName or ""
    local resetText = formatResetDuration(lockout.resetTime or 0)
    local lineText
    if lockout.isRaid and (lockout.numEncounters or 0) > 0 then
      lineText = string.format(
        "%s · %s %d/%d · %s",
        instanceName,
        difficultyName,
        lockout.encounterProgress or 0,
        lockout.numEncounters or 0,
        resetText
      )
    else
      lineText = string.format("%s · %s · %s", instanceName, difficultyName, resetText)
    end
    if lockout.isExtended then
      lineText = lineText .. " " .. (loc.EJ_LOCKOUT_EXTENDED or "(Extended)")
    end
    lines[#lines + 1] = lineText
  end

  return lines, math.max(0, #allLockouts - lineCount)
end

-- ============================================================================
-- 首领查询 API
-- ============================================================================

--- 获取副本已击杀的首领列表
---@param journalInstanceID number
---@param difficultyID number|nil 指定难度 ID；为空时走非难度特定兜底判定
---@return table[] bosses 首领列表
--- 返回格式：[{ name = string, encounterID = number }]
local function isEncounterKilledForDifficulty(encounterID, difficultyID)
  if type(encounterID) ~= "number" then
    return false
  end

  -- 优先走难度敏感判定：C_RaidLocks.IsEncounterComplete(mapID, dungeonEncounterID, difficultyID)
  -- mapID / dungeonEncounterID 由 EJ_GetEncounterInfo 返回（参照 Blizzard_EncounterJournal.lua）。
  if type(difficultyID) == "number"
      and C_RaidLocks and type(C_RaidLocks.IsEncounterComplete) == "function"
      and type(EJ_GetEncounterInfo) == "function" then
    local infoSuccess, _, _, _, _, _, _, dungeonEncounterID, mapID = pcall(EJ_GetEncounterInfo, encounterID)
    if infoSuccess
        and type(mapID) == "number" and mapID > 0
        and type(dungeonEncounterID) == "number" and dungeonEncounterID > 0 then
      local lockoutSuccess, isComplete = pcall(C_RaidLocks.IsEncounterComplete, mapID, dungeonEncounterID, difficultyID)
      if lockoutSuccess then
        return isComplete == true
      end
    end
  end

  -- 兜底：当难度敏感路径不可用时，退回 EncounterJournal 维度的完成判定。
  if C_EncounterJournal and type(C_EncounterJournal.IsEncounterComplete) == "function" then
    local completeSuccess, isComplete = pcall(C_EncounterJournal.IsEncounterComplete, encounterID)
    if completeSuccess then
      return isComplete == true
    end
  end

  return false
end

function AzerothCompanion.API.EncounterJournal.GetKilledBosses(journalInstanceID, difficultyID)
  if type(journalInstanceID) ~= "number" then
    return {}
  end

  if not EJ_SelectInstance or not EJ_GetNumEncounters or not EJ_GetEncounterInfoByIndex then
    return {}
  end

  local killed = {}

  -- 保存当前选中的 EJ 副本，避免本查询影响 UI 上下文
  local previousInstanceID = nil
  if type(EJ_GetCurrentInstance) == "function" then
    local currentSuccess, currentID = pcall(EJ_GetCurrentInstance)
    if currentSuccess and type(currentID) == "number" then
      previousInstanceID = currentID
    end
  end

  -- 选择副本
  local success = pcall(EJ_SelectInstance, journalInstanceID)
  if not success then
    return {}
  end

  -- 遍历首领
  local numEncounters = EJ_GetNumEncounters()
  for i = 1, numEncounters do
    local name, _, encounterID = EJ_GetEncounterInfoByIndex(i)
    if name and encounterID then
      if isEncounterKilledForDifficulty(encounterID, difficultyID) then
        table.insert(killed, {
          name = name,
          encounterID = encounterID
        })
      end
    end
  end

  -- 恢复调用前的选中上下文，避免对用户当前 EJ 页面造成副作用
  if previousInstanceID and previousInstanceID ~= journalInstanceID then
    pcall(EJ_SelectInstance, previousInstanceID)
  end

  return killed
end

-- ============================================================================
-- 副本入口导航 API
-- ============================================================================

--- 构建可传给 UiMapPoint 的归一化坐标对象。
---@param x number 归一化 X 坐标
---@param y number 归一化 Y 坐标
---@return table position 坐标对象
local function createEntrancePosition(x, y)
  if type(CreateVector2D) == "function" then
    local vectorSuccess, vectorValue = pcall(CreateVector2D, x, y) -- 暴雪 Vector2D 构造结果
    if vectorSuccess and type(vectorValue) == "table" then
      return vectorValue
    end
  end

  return {
    x = x,
    y = y,
    GetXY = function(self)
      return self.x, self.y
    end,
  }
end

--- 读取入口候选的结构化目标字段。
---@param entranceDef table|nil 入口或候选记录
---@return number|nil targetUiMapID 外部目标地图 ID
---@return number|nil targetX 外部目标 X 坐标
---@return number|nil targetY 外部目标 Y 坐标
local function readEntranceTarget(entranceDef)
  if type(entranceDef) ~= "table" then
    return nil, nil, nil
  end

  local targetUiMapID = tonumber(entranceDef.TargetUiMapID or entranceDef.targetUiMapID) -- 外部目标地图
  local targetX = tonumber(entranceDef.TargetX or entranceDef.targetX) -- 外部目标 X
  local targetY = tonumber(entranceDef.TargetY or entranceDef.targetY) -- 外部目标 Y
  if targetUiMapID and targetUiMapID > 0 and targetX and targetY and targetX >= 0 and targetX <= 1 and targetY >= 0 and targetY <= 1 then
    return targetUiMapID, targetX, targetY
  end

  return nil, nil, nil
end

--- 判断路线边是否显式经过指定 UiMapID。
---@param traversedUiMapIDs table|nil 经过地图列表
---@param targetUiMapID number 目标地图 ID
---@return boolean
local function routeEdgeTraversesUiMapID(traversedUiMapIDs, targetUiMapID)
  if type(traversedUiMapIDs) ~= "table" then
    return false
  end

  for _, traversedUiMapID in pairs(traversedUiMapIDs) do
    if tonumber(traversedUiMapID) == targetUiMapID then
      return true
    end
  end

  return false
end

--- 判断指定 UiMapID 是否已经出现在统一运行时路线边中。
---@param uiMapID number|nil 地图 ID
---@return boolean
local function hasNavigationRouteEdgesForUiMapID(uiMapID)
  local targetUiMapID = tonumber(uiMapID) -- 待检查地图 ID
  if not targetUiMapID or targetUiMapID <= 0 then
    return false
  end

  local routeEdgeData = AzerothCompanion.Data and AzerothCompanion.Data.NavigationRouteEdges -- 统一运行时路线边
  local edgeList = type(routeEdgeData) == "table" and routeEdgeData.edges or nil -- 路线边列表
  if type(edgeList) ~= "table" then
    return false
  end

  for _, edgeDef in pairs(edgeList) do
    if type(edgeDef) == "table" then
      local fromUiMapID = tonumber(edgeDef.FromUiMapID or edgeDef.fromUiMapID) -- 边起点地图
      local toUiMapID = tonumber(edgeDef.ToUiMapID or edgeDef.toUiMapID) -- 边终点地图
      local traversedUiMapIDs = edgeDef.TraversedUiMapIDs or edgeDef.traversedUiMapIDs -- 边经过地图
      if fromUiMapID == targetUiMapID or toUiMapID == targetUiMapID or routeEdgeTraversesUiMapID(traversedUiMapIDs, targetUiMapID) then
        return true
      end
    end
  end

  return false
end

--- 从入口候选中优先选择可参与导航路线的目标。
---@param candidateList table|nil 候选入口列表
---@param fallbackEntrance table|nil 首选入口记录
---@return table|nil entranceDef 被选中的入口或候选记录
local function selectRouteableEntranceCandidate(candidateList, fallbackEntrance)
  local firstValidCandidate = nil -- 第一个结构化字段完整的候选
  if type(candidateList) == "table" then
    for _, candidateDef in ipairs(candidateList) do
      local targetUiMapID = readEntranceTarget(candidateDef) -- 候选目标地图
      if targetUiMapID then
        if not firstValidCandidate then
          firstValidCandidate = candidateDef
        end
        if hasNavigationRouteEdgesForUiMapID(targetUiMapID) then
          return candidateDef
        end
      end
    end
  end

  if firstValidCandidate then
    return firstValidCandidate
  end

  local fallbackUiMapID = readEntranceTarget(fallbackEntrance) -- 首选入口目标地图
  if fallbackUiMapID then
    return fallbackEntrance
  end

  return nil
end

--- 从规范化运行时入口导出表读取入口位置。
---@param journalInstanceID number 冒险指南副本 ID
---@param options table|nil 保留参数；当前运行时入口查找不再使用调用方候选地图扫描
---@return table|nil entrance 入口信息，含 uiMapID / position / areaPoiID / name / journalInstanceID
function AzerothCompanion.API.EncounterJournal.FindDungeonEntranceForJournalInstance(journalInstanceID, options)
  if type(journalInstanceID) ~= "number" or journalInstanceID <= 0 then
    return nil
  end

  local _ = options -- 预留给历史调用方，当前不再使用调用方候选地图兜底

  local entranceData = AzerothCompanion.Data and AzerothCompanion.Data.NavigationInstanceEntrances -- 导出的副本入口数据
  local entrancesByJournalInstanceID = type(entranceData) == "table" and entranceData.entrancesByJournalInstanceID or nil -- 按副本 ID 索引
  local exportedEntrance = type(entrancesByJournalInstanceID) == "table" and entrancesByJournalInstanceID[journalInstanceID] or nil -- 命中的入口记录
  local candidatesByJournalInstanceID = type(entranceData) == "table" and entranceData.candidatesByJournalInstanceID or nil -- 按副本 ID 索引的候选列表
  local candidateList = type(candidatesByJournalInstanceID) == "table" and candidatesByJournalInstanceID[journalInstanceID] or nil -- 命中的候选列表
  local selectedEntrance = selectRouteableEntranceCandidate(candidateList, exportedEntrance) -- 可路由优先的入口目标
  local targetUiMapID, targetX, targetY = readEntranceTarget(selectedEntrance) -- 最终外部目标
  if targetUiMapID and targetX and targetY then
    local metadataEntrance = type(exportedEntrance) == "table" and exportedEntrance or selectedEntrance -- 用于保留副本元数据的记录
    return {
      source = "exported",
      uiMapID = targetUiMapID,
      position = createEntrancePosition(targetX, targetY),
      entranceID = selectedEntrance.EntranceID or metadataEntrance.EntranceID,
      areaPoiID = metadataEntrance.AreaPoiID or selectedEntrance.AreaPoiID,
      name = metadataEntrance.Name_lang or metadataEntrance.AreaPoiName_lang or selectedEntrance.Name_lang or selectedEntrance.AreaPoiName_lang,
      journalInstanceID = metadataEntrance.JournalInstanceID or selectedEntrance.JournalInstanceID or journalInstanceID,
      instanceMapID = metadataEntrance.InstanceMapID or selectedEntrance.InstanceMapID,
      worldMapID = metadataEntrance.WorldMapID or selectedEntrance.WorldMapID,
      worldX = metadataEntrance.WorldX or selectedEntrance.WorldX,
      worldY = metadataEntrance.WorldY or selectedEntrance.WorldY,
      worldZ = metadataEntrance.WorldZ or selectedEntrance.WorldZ,
    }
  end

  return nil
end

--- 打开世界地图到指定地图 ID。Retail 优先使用 C_Map.OpenWorldMap，避免旧全局入口再额外触发一次 SetMapID。
---@param uiMapID number 地图 ID
local function openWorldMapToMap(uiMapID)
  if type(uiMapID) ~= "number" or uiMapID <= 0 then
    return
  end

  if C_Map and type(C_Map.OpenWorldMap) == "function" then
    local openSuccess = pcall(C_Map.OpenWorldMap, uiMapID) -- 官方地图打开 API 调用结果
    if openSuccess then
      return
    end

    -- Retail 存在 C_Map.OpenWorldMap 时，失败多半来自战斗限制或外部地图插件回调；
    -- 此时不再降级重复触发旧路径，仍允许后续 waypoint 设置继续执行。
    return
  end

  if type(OpenWorldMap) == "function" then
    local openSuccess = pcall(OpenWorldMap, uiMapID)
    if openSuccess then
      local worldMapFrame = _G.WorldMapFrame -- 世界地图框体
      if worldMapFrame and type(worldMapFrame.SetMapID) == "function" then
        pcall(worldMapFrame.SetMapID, worldMapFrame, uiMapID)
      end
      return
    end
  end

  if type(ToggleWorldMap) == "function" then
    pcall(ToggleWorldMap)
  end

  local worldMapFrame = _G.WorldMapFrame -- 世界地图框体
  if worldMapFrame and type(worldMapFrame.SetMapID) == "function" then
    pcall(worldMapFrame.SetMapID, worldMapFrame, uiMapID)
  end
end

--- 导航到指定副本入口：打开地图、设置用户 waypoint，并启用系统追踪。
---@param journalInstanceID number 冒险指南副本 ID
---@param options table|nil 可选：candidateMapIDs 用于测试或调用方传入更小地图范围
---@return boolean success 是否成功
---@return table|string result 成功时为入口信息；失败时为原因：not_found / waypoint_api_missing / waypoint_forbidden / point_api_missing / set_failed
function AzerothCompanion.API.EncounterJournal.NavigateToDungeonEntrance(journalInstanceID, options)
  local entranceInfo = AzerothCompanion.API.EncounterJournal.FindDungeonEntranceForJournalInstance(journalInstanceID, options) -- 命中的入口信息
  if not entranceInfo then
    return false, "not_found"
  end

  if not C_Map or type(C_Map.CanSetUserWaypointOnMap) ~= "function" or type(C_Map.SetUserWaypoint) ~= "function" then
    return false, "waypoint_api_missing"
  end

  local canSetSuccess, canSetWaypoint = pcall(C_Map.CanSetUserWaypointOnMap, entranceInfo.uiMapID)
  if not canSetSuccess or canSetWaypoint ~= true then
    return false, "waypoint_forbidden"
  end

  if not UiMapPoint or type(UiMapPoint.CreateFromVector2D) ~= "function" then
    return false, "point_api_missing"
  end

  local pointSuccess, mapPoint = pcall(UiMapPoint.CreateFromVector2D, entranceInfo.uiMapID, entranceInfo.position)
  if not pointSuccess or not mapPoint then
    return false, "point_api_missing"
  end

  openWorldMapToMap(entranceInfo.uiMapID)

  local setSuccess = pcall(C_Map.SetUserWaypoint, mapPoint)
  if not setSuccess then
    return false, "set_failed"
  end

  if C_SuperTrack and type(C_SuperTrack.SetSuperTrackedUserWaypoint) == "function" then
    pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
  end

  return true, entranceInfo
end

-- ============================================================================
-- UI 状态查询 API
-- ============================================================================

--- 检查当前是否在副本列表标签页
---@return boolean
function AzerothCompanion.API.EncounterJournal.IsRaidOrDungeonInstanceListTab()
  local encounterJournalFrame = _G.EncounterJournal -- 冒险手册根框体
  if not encounterJournalFrame then
    return false
  end

  local journalIsOpen = true -- 冒险手册是否打开
  if encounterJournalFrame.IsShown then
    local shownSuccess, shownValue = pcall(function() return encounterJournalFrame:IsShown() end)
    if shownSuccess then
      journalIsOpen = shownValue == true
    end
  end
  if not journalIsOpen then
    return false
  end

  local dungeonTabButton = encounterJournalFrame.dungeonsTab -- 地下城页签按钮
  local raidTabButton = encounterJournalFrame.raidsTab -- 团队副本页签按钮

  local dungeonTabID = dungeonTabButton and dungeonTabButton.GetID and dungeonTabButton:GetID() or nil -- 地下城页签 ID
  local raidTabID = raidTabButton and raidTabButton.GetID and raidTabButton:GetID() or nil -- 团队副本页签 ID
  if type(dungeonTabID) ~= "number" and type(raidTabID) ~= "number" then
    return false
  end

  local selectedRootTabID = encounterJournalFrame.selectedTab -- 当前选中的根页签 ID
  if type(selectedRootTabID) ~= "number" then
    return false
  end
  if selectedRootTabID ~= dungeonTabID and selectedRootTabID ~= raidTabID then
    return false
  end

  local instanceSelectFrame = encounterJournalFrame.instanceSelect -- Blizzard 副本列表面板
  if not instanceSelectFrame or not instanceSelectFrame.IsShown then
    return false
  end

  local listShownSuccess, listShown = pcall(function() return instanceSelectFrame:IsShown() end)
  if not listShownSuccess or listShown ~= true then
    return false
  end

  return true
end

-- ============================================================================
-- 掉落筛选查询 API
-- ============================================================================

local dropItemSetCache = {} -- 按掉落类型和副本 ID 缓存的 itemID 集合
local DROP_DATA_TABLES = { -- 掉落类型到导出数据表字段的映射
  mount = "MountDrops",
  pet = "PetDrops",
  recipe = "RecipeDrops",
  housing_decoration = "HousingDecorationDrops",
}

local DROP_TYPE_ORDER = { "mount", "pet", "recipe", "housing_decoration" } -- all 类型合并时的子类型遍历顺序

--- 归一掉落类型。
---@param dropType string|nil 掉落类型
---@return string normalizedType 归一后的类型
local function normalizeDropType(dropType)
  if dropType == "all" or dropType == "mount" or dropType == "pet" or dropType == "recipe" or dropType == "housing_decoration" then
    return dropType
  end
  return "mount"
end

--- 归一化掉落类型筛选集合。
---@param dropFilter string|table|nil 掉落类型或类型勾选集合
---@return table typeList 需要检查的掉落类型序列
---@return boolean typeFilterActive 是否存在类型过滤
local function normalizeDropTypeSelection(dropFilter)
  if type(dropFilter) == "table" then
    local typeList = {} -- 归一后的类型序列
    for _, dropType in ipairs(DROP_TYPE_ORDER) do
      if dropFilter[dropType] == true then
        typeList[#typeList + 1] = dropType
      end
    end
    if #typeList > 0 then
      return typeList, true
    end
    return DROP_TYPE_ORDER, false
  end
  local normalizedType = normalizeDropType(dropFilter) -- 归一后的单值类型
  if normalizedType == "all" then
    return DROP_TYPE_ORDER, false
  end
  return { normalizedType }, true
end

--- 归一获取状态筛选。
---@param ownership string|nil 获取状态
---@return string normalizedOwnership 归一后的状态
local function normalizeOwnership(ownership)
  if ownership == "all" or ownership == "collected" or ownership == "uncollected" then
    return ownership
  end
  return "all"
end

--- 检查布尔结果是否与获取状态筛选匹配。
---@param isCollected boolean|nil 是否已收集；nil 表示未知
---@param ownership string 获取状态筛选
---@return boolean
local function doesOwnershipMatch(isCollected, ownership)
  if ownership == "all" then
    return true
  end
  if isCollected == nil then
    -- 缓存或职业 API 不可用时，未知状态按“未确认已获取”处理，避免未获取筛选误清空列表。
    return ownership == "uncollected"
  end
  if ownership == "collected" then
    return isCollected == true
  end
  return isCollected == false
end

--- 安全读取坐骑物品是否已收集。
---@param itemID number 物品 ID
---@return boolean|nil isCollected 是否已收集
local function getMountCollectedState(itemID)
  if not C_MountJournal or type(C_MountJournal.GetMountFromItem) ~= "function" or type(C_MountJournal.GetMountInfoByID) ~= "function" then
    return nil
  end
  local mountSuccess, mountID = pcall(C_MountJournal.GetMountFromItem, itemID) -- 坐骑物品反查结果
  if not mountSuccess or type(mountID) ~= "number" then
    return nil
  end
  local infoResults = { pcall(C_MountJournal.GetMountInfoByID, mountID) } -- GetMountInfoByID 返回字段
  if infoResults[1] ~= true then
    return nil
  end
  if type(infoResults[12]) == "boolean" then
    return infoResults[12]
  end
  return nil
end

--- 安全读取宠物物品是否已收集。
---@param itemID number 物品 ID
---@return boolean|nil isCollected 是否已收集
local function getPetCollectedState(itemID)
  if not C_PetJournal or type(C_PetJournal.GetPetInfoByItemID) ~= "function" or type(C_PetJournal.GetNumCollectedInfo) ~= "function" then
    return nil
  end
  -- GetPetInfoByItemID 的 speciesID 是第 13 个返回值；pcall 成功标记占第 1 位。
  local infoResults = { pcall(C_PetJournal.GetPetInfoByItemID, itemID) } -- 宠物物品查询返回字段
  if infoResults[1] ~= true or infoResults[14] == nil then
    return nil
  end
  local speciesID = infoResults[14] -- 宠物 speciesID
  local countSuccess, collectedCount = pcall(C_PetJournal.GetNumCollectedInfo, speciesID) -- 宠物已收集数量查询结果
  if not countSuccess or type(collectedCount) ~= "number" then
    return nil
  end
  return collectedCount > 0
end

--- 安全读取图纸物品是否已学会。
---@param itemID number 物品 ID
---@return boolean|nil isCollected 是否已学会
local function getRecipeCollectedState(itemID)
  local spellID = nil -- 图纸学习法术 ID
  if C_Item and type(C_Item.GetItemSpell) == "function" then
    local spellSuccess, _, itemSpellID = pcall(C_Item.GetItemSpell, itemID) -- C_Item 图纸法术查询结果
    if spellSuccess and type(itemSpellID) == "number" then
      spellID = itemSpellID
    end
  end
  if not spellID and type(GetItemSpell) == "function" then
    local spellSuccess, _, itemSpellID = pcall(GetItemSpell, itemID) -- 旧全局图纸法术查询结果
    if spellSuccess and type(itemSpellID) == "number" then
      spellID = itemSpellID
    end
  end
  if type(spellID) ~= "number" then
    return nil
  end
  if C_TradeSkillUI and type(C_TradeSkillUI.GetRecipeInfo) == "function" then
    local recipeSuccess, recipeInfo = pcall(C_TradeSkillUI.GetRecipeInfo, spellID) -- 专业配方状态查询结果
    if recipeSuccess and type(recipeInfo) == "table" and type(recipeInfo.learned) == "boolean" then
      return recipeInfo.learned
    end
  end
  if C_SpellBook and type(C_SpellBook.IsSpellKnown) == "function" then
    local knownSuccess, isKnown = pcall(C_SpellBook.IsSpellKnown, spellID) -- SpellBook 已学状态查询结果
    if knownSuccess then
      return isKnown == true
    end
  end
  if type(IsPlayerSpell) == "function" then
    local knownSuccess, isKnown = pcall(IsPlayerSpell, spellID) -- 旧全局已学法术查询结果
    if knownSuccess then
      return isKnown == true
    end
  end
  return nil
end

--- 安全读取住宅装饰物品是否已获取。
---@param itemID number 物品 ID
---@return boolean|nil isCollected 是否已获取
local function getHousingDecorationCollectedState(itemID)
  if not C_HousingCatalog or type(C_HousingCatalog.GetCatalogEntryInfoByItem) ~= "function" then
    return nil
  end
  local infoSuccess, catalogInfo = pcall(C_HousingCatalog.GetCatalogEntryInfoByItem, itemID, true) -- 住宅目录条目查询结果（要求返回拥有信息）
  if not infoSuccess or type(catalogInfo) ~= "table" then
    return nil
  end
  local quantity = tonumber(catalogInfo.quantity or catalogInfo.numOwned or catalogInfo.ownedQuantity or catalogInfo.count) -- 已拥有数量
  if type(quantity) == "number" and quantity > 0 then
    return true
  end
  local placedQuantity = tonumber(catalogInfo.numPlaced or catalogInfo.placedQuantity) -- 已摆放数量
  if type(placedQuantity) == "number" and placedQuantity > 0 then
    return true
  end
  local redeemableQuantity = tonumber(catalogInfo.remainingRedeemable or catalogInfo.redeemableQuantity) -- 可兑换数量
  if type(redeemableQuantity) == "number" and redeemableQuantity > 0 then
    return true
  end
  if quantity ~= nil or placedQuantity ~= nil or redeemableQuantity ~= nil then
    return false
  end
  return nil
end

--- 读取指定掉落类型的获取状态。
---@param itemID number 物品 ID
---@param dropType string 掉落类型
---@return boolean|nil isCollected 是否已收集
local function getCollectedStateForDrop(itemID, dropType)
  if dropType == "mount" then
    return getMountCollectedState(itemID)
  elseif dropType == "pet" then
    return getPetCollectedState(itemID)
  elseif dropType == "recipe" then
    return getRecipeCollectedState(itemID)
  elseif dropType == "housing_decoration" then
    return getHousingDecorationCollectedState(itemID)
  end
  return nil
end

--- 获取副本指定类型掉落 itemID 集合（集合键为 itemID，值为 true）。
---@param journalInstanceID number
---@param dropType string|nil 掉落类型；all 返回全部类型合并集合
---@return table|nil itemSet
function AzerothCompanion.API.EncounterJournal.GetDropSetForInstance(journalInstanceID, dropType)
  if type(journalInstanceID) ~= "number" then
    return nil
  end
  if type(dropType) == "table" then
    local mergedSet = {} -- 多选类型合并集合
    local hasItem = false -- 是否存在任一物品
    local typeList = normalizeDropTypeSelection(dropType) -- 多选类型序列
    for _, currentType in ipairs(typeList) do
      local typeSet = AzerothCompanion.API.EncounterJournal.GetDropSetForInstance(journalInstanceID, currentType) -- 单类型集合
      if type(typeSet) == "table" then
        for itemID in pairs(typeSet) do
          mergedSet[itemID] = true
          hasItem = true
        end
      end
    end
    return hasItem and mergedSet or nil
  end
  local normalizedType = normalizeDropType(dropType) -- 归一后的掉落类型
  dropItemSetCache[normalizedType] = dropItemSetCache[normalizedType] or {}
  if dropItemSetCache[normalizedType][journalInstanceID] then
    return dropItemSetCache[normalizedType][journalInstanceID]
  end

  local itemSet = {} -- 当前副本命中的掉落集合
  local hasItem = false -- 是否找到至少一个物品
  local typeList = normalizedType == "all" and DROP_TYPE_ORDER or { normalizedType } -- 待读取类型
  for _, currentType in ipairs(typeList) do
    local tableName = DROP_DATA_TABLES[currentType] -- 数据表名
    local drops = AzerothCompanion.Data and AzerothCompanion.Data[tableName] -- 导出的掉落表
    local itemList = type(drops) == "table" and drops[journalInstanceID] or nil -- 当前副本掉落列表
    if type(itemList) == "table" then
      for _, itemID in ipairs(itemList) do
        if type(itemID) == "number" then
          itemSet[itemID] = true
          hasItem = true
        end
      end
    end
  end

  if not hasItem then
    return nil
  end
  dropItemSetCache[normalizedType][journalInstanceID] = itemSet
  return itemSet
end

--- 获取副本坐骑掉落 itemID 集合（兼容旧调用方）。
---@param journalInstanceID number
---@return table|nil itemSet
function AzerothCompanion.API.EncounterJournal.GetMountItemSetForInstance(journalInstanceID)
  return AzerothCompanion.API.EncounterJournal.GetDropSetForInstance(journalInstanceID, "mount")
end

--- 检查副本是否有指定类型掉落。
---@param journalInstanceID number 冒险指南副本 ID
---@param dropType string|nil 掉落类型
---@return boolean
function AzerothCompanion.API.EncounterJournal.HasDropsForInstance(journalInstanceID, dropType)
  return AzerothCompanion.API.EncounterJournal.GetDropSetForInstance(journalInstanceID, dropType) ~= nil
end

--- 检查副本是否有符合类型与获取状态的掉落。
---@param journalInstanceID number 冒险指南副本 ID
---@param dropType string|nil 掉落类型
---@param ownership string|nil 获取状态
---@return boolean
function AzerothCompanion.API.EncounterJournal.HasMatchingDropsForInstance(journalInstanceID, dropType, ownership)
  if type(journalInstanceID) ~= "number" then
    return false
  end
  local normalizedOwnership = normalizeOwnership(ownership) -- 归一后的获取状态
  local typeList, typeFilterActive = normalizeDropTypeSelection(dropType) -- 待检查类型与类型过滤态
  if typeFilterActive ~= true and normalizedOwnership == "all" then
    return true
  end
  for _, currentType in ipairs(typeList) do
    local tableName = DROP_DATA_TABLES[currentType] -- 数据表名
    local drops = AzerothCompanion.Data and AzerothCompanion.Data[tableName] -- 导出的掉落表
    local itemList = type(drops) == "table" and drops[journalInstanceID] or nil -- 当前副本掉落列表
    if type(itemList) == "table" then
      for _, itemID in ipairs(itemList) do
        if type(itemID) == "number" then
          if normalizedOwnership == "all" then
            return true
          end
          local isCollected = getCollectedStateForDrop(itemID, currentType) -- 当前物品获取状态
          if doesOwnershipMatch(isCollected, normalizedOwnership) then
            return true
          end
        end
      end
    end
  end
  return false
end

--- 检查副本是否掉落坐骑。
---@param journalInstanceID number
---@return boolean
function AzerothCompanion.API.EncounterJournal.HasMountDrops(journalInstanceID)
  return AzerothCompanion.API.EncounterJournal.HasDropsForInstance(journalInstanceID, "mount")
end
