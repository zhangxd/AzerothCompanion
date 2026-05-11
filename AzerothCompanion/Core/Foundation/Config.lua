--[[
  配置管理：数字设置 ID、账号 / 角色 KV 存档与统一访问接口。
  存档只写入 values[id]；key 名仅用于代码可读性、日志、测试和文档。
]]

local ACCOUNT_SCOPE = "account" -- 账号级存档 scope
local CHARACTER_SCOPE = "character" -- 角色级存档 scope
local ACCOUNT_DB_VERSION = 3 -- 账号级 KV 存档版本
local CHARACTER_DB_VERSION = 1 -- 角色级 KV 存档版本

local SettingId = {
  GLOBAL_DEBUG = 1001,
  GLOBAL_LOCALE = 1002,
  SETTINGS_LAST_LEAF_PAGE = 1003,

  MOVER_ENABLED = 2001,
  MOVER_DEBUG = 2002,
  MOVER_FRAMES = 2003,
  MOVER_DRAG_HIT_MODE = 2004,
  MOVER_ALLOW_DRAG_IN_COMBAT = 2005,

  TOOLTIP_ENABLED = 3001,
  TOOLTIP_DEBUG = 3002,
  TOOLTIP_MODE = 3003,
  TOOLTIP_OFFSET_X = 3004,
  TOOLTIP_OFFSET_Y = 3005,

  MINIMAP_ENABLED = 4001,
  MINIMAP_DEBUG = 4002,
  MINIMAP_SHOW_BUTTON = 4003,
  MINIMAP_SHOW_COORDS = 4004,
  MINIMAP_COORDS_ANCHOR = 4005,
  MINIMAP_POS = 4006,
  MINIMAP_FLYOUT_SLOT_IDS = 4007,

  CHAT_ENABLED = 5001,
  CHAT_DEBUG = 5002,
  CHAT_PREFIX_COLOR = 5003,
  CHAT_CONTENT_COLOR = 5004,

  ENCOUNTER_JOURNAL_ENABLED = 6001,
  ENCOUNTER_JOURNAL_DEBUG = 6002,
  ENCOUNTER_JOURNAL_MOUNT_FILTER_ENABLED = 6003,
  ENCOUNTER_JOURNAL_LIST_PIN_ALWAYS_VISIBLE = 6004,

  NAVIGATION_ENABLED = 7001,
  NAVIGATION_DEBUG = 7002,
  NAVIGATION_ROUTE_WIDGET_EXPANDED = 7003,
  NAVIGATION_ROUTE_HISTORY_EXPANDED = 7004,
  NAVIGATION_ROUTE_WIDGET_POSITION = 7005,
  NAVIGATION_ROUTE_HISTORY = 7006,

  QUEST_ENABLED = 8001,
  QUEST_DEBUG = 8002,
  QUESTLINE_TREE_ENABLED = 8003,
  QUEST_RECENT_COMPLETED_MAX = 8004,
  QUEST_NAV_EXPANSION_ID = 8005,
  QUEST_NAV_SELECTED_CAMPAIGN_ID = 8006,
  QUEST_NAV_SELECTED_ACHIEVEMENT_ID = 8007,
  QUEST_NAV_MODE_KEY = 8008,
  QUEST_NAV_SELECTED_MAP_ID = 8009,
  QUEST_NAV_SEARCH_TEXT = 8010,
  QUEST_INSPECTOR_LAST_QUEST_ID = 8011,
  QUEST_RECENT_COMPLETED_LIST = 8012,
  QUEST_NAV_EXPANDED_QUESTLINE_ID = 8013,
  QUESTLINE_TREE_COLLAPSED = 8014,
}

AzerothCompanion.Config.SettingId = SettingId
AzerothCompanion.Config.Scope = {
  ACCOUNT = ACCOUNT_SCOPE,
  CHARACTER = CHARACTER_SCOPE,
}

--- 深拷贝配置值；table 递归复制，标量直接返回。
---@param sourceValue any 原始值
---@return any copiedValue 复制结果
local function copyValue(sourceValue)
  if type(sourceValue) ~= "table" then
    return sourceValue
  end
  local copiedTable = {} -- 复制结果表
  for keyName, valueObject in pairs(sourceValue) do
    copiedTable[keyName] = copyValue(valueObject)
  end
  return copiedTable
end

--- 判断表是否为序列；用于校验数组型设置。
---@param valueObject any 待检查值
---@return boolean
local function isArrayTable(valueObject)
  if type(valueObject) ~= "table" then
    return false
  end
  local itemCount = 0 -- 遍历得到的元素数量
  for keyName in pairs(valueObject) do
    if type(keyName) ~= "number" or keyName < 1 or math.floor(keyName) ~= keyName then
      return false
    end
    itemCount = itemCount + 1
  end
  return itemCount == #valueObject
end

--- 将小地图角度归一到 0..360；nil 表示使用默认位置。
---@param rawValue any 原始角度
---@return number|nil normalizedValue 归一值
---@return boolean isValid 是否有效
local function normalizeMinimapPosition(rawValue)
  if rawValue == nil then
    return nil, true
  end
  if type(rawValue) ~= "number" then
    return nil, false
  end
  return rawValue % 360, true
end

--- 归一路线图组件位置。
---@param rawValue any 原始位置表
---@return table
local function normalizeRouteWidgetPosition(rawValue)
  local positionTable = type(rawValue) == "table" and rawValue or {} -- 原始位置表
  return {
    point = type(positionTable.point) == "string" and positionTable.point or "TOP",
    x = tonumber(positionTable.x) or 0,
    y = tonumber(positionTable.y) or -18,
  }
end

--- 归一路线历史。
---@param rawValue any 原始路线历史
---@return table
local function normalizeRouteHistory(rawValue)
  local normalizedList = {} -- 归一后的路线历史
  if not isArrayTable(rawValue) then
    return normalizedList
  end
  for _, historyEntry in ipairs(rawValue) do
    local targetUiMapID = tonumber(type(historyEntry) == "table" and (historyEntry.targetUiMapID or historyEntry.uiMapID)) -- 目标地图 ID
    if targetUiMapID and targetUiMapID > 0 then
      normalizedList[#normalizedList + 1] = {
        targetUiMapID = targetUiMapID,
        targetX = tonumber(type(historyEntry) == "table" and (historyEntry.targetX or historyEntry.x)) or 0,
        targetY = tonumber(type(historyEntry) == "table" and (historyEntry.targetY or historyEntry.y)) or 0,
        targetName = type(historyEntry) == "table" and type(historyEntry.targetName or historyEntry.name) == "string" and (historyEntry.targetName or historyEntry.name) or "",
        summaryText = type(historyEntry) == "table" and type(historyEntry.summaryText) == "string" and historyEntry.summaryText or "",
      }
      if #normalizedList >= 10 then
        break
      end
    end
  end
  return normalizedList
end

--- 归一最近完成任务列表。
---@param rawValue any 原始最近完成任务列表
---@return table
local function normalizeQuestRecentCompletedList(rawValue)
  local normalizedList = {} -- 归一后的最近完成任务列表
  if not isArrayTable(rawValue) then
    return normalizedList
  end
  for _, recentEntry in ipairs(rawValue) do
    if type(recentEntry) == "table" and type(recentEntry.questID) == "number" and recentEntry.questID > 0 then
      normalizedList[#normalizedList + 1] = {
        questID = math.floor(recentEntry.questID),
        questName = type(recentEntry.questName) == "string" and recentEntry.questName or "",
        completedAt = type(recentEntry.completedAt) == "number" and recentEntry.completedAt or 0,
      }
    end
  end
  return normalizedList
end

--- 归一左侧任务树折叠状态。
---@param rawValue any 原始折叠状态
---@return table
local function normalizeCollapseMap(rawValue)
  local normalizedMap = {} -- 归一后的折叠状态
  if type(rawValue) ~= "table" then
    return normalizedMap
  end
  for collapseKey, collapseFlag in pairs(rawValue) do
    if collapseFlag == true then
      normalizedMap[collapseKey] = true
    end
  end
  return normalizedMap
end

--- 归一小地图悬停菜单勾选项。
---@param rawValue any 原始悬停项列表
---@return table
local function normalizeFlyoutSlotIds(rawValue)
  if not isArrayTable(rawValue) then
    return { "reload_ui", "ac_flyout_quest" }
  end
  local normalizedList = {} -- 归一后的悬停项列表
  for _, slotId in ipairs(rawValue) do
    if type(slotId) == "string" and slotId ~= "" then
      normalizedList[#normalizedList + 1] = slotId
    end
  end
  if #normalizedList == 0 then
    normalizedList = { "reload_ui", "ac_flyout_quest" }
  end
  return normalizedList
end

--- 归一世界地图尺寸字段；nil 表示不保存该尺寸。
---@param rawValue any 原始尺寸值
---@return number|nil dimensionValue 合法尺寸值
local function normalizeWorldMapDimension(rawValue)
  local dimensionValue = tonumber(rawValue) -- 世界地图尺寸值
  if dimensionValue and dimensionValue > 0 then
    return dimensionValue
  end
  return nil
end

--- 归一 mover 窗口位置表。
---@param rawValue any 原始窗口位置表
---@return table
local function normalizeMoverFrames(rawValue)
  local normalizedFrames = {} -- 归一后的窗口位置表
  if type(rawValue) ~= "table" then
    return normalizedFrames
  end
  for frameKey, framePosition in pairs(rawValue) do
    if type(frameKey) == "string" and type(framePosition) == "table" then
      local normalizedFrame = { -- 归一后的单个窗口记录
        point = type(framePosition.point) == "string" and framePosition.point or "CENTER",
        rel = type(framePosition.rel) == "string" and framePosition.rel or "CENTER",
        x = tonumber(framePosition.x) or 0,
        y = tonumber(framePosition.y) or 0,
      }
      local widthValue = normalizeWorldMapDimension(framePosition.width) -- 世界地图可选宽度
      local heightValue = normalizeWorldMapDimension(framePosition.height) -- 世界地图可选高度
      if frameKey == "WorldMapFrame" and widthValue and heightValue then
        normalizedFrame.width = widthValue
        normalizedFrame.height = heightValue
      end
      normalizedFrames[frameKey] = normalizedFrame
    end
  end
  return normalizedFrames
end

local accountOnly = { account = true } -- 仅账号级 scope
local characterOnly = { character = true } -- 仅角色级 scope

local settingDefinitions = {
  [SettingId.GLOBAL_DEBUG] = { key = "debug", scopes = accountOnly, default = false, valueType = "boolean" },
  [SettingId.GLOBAL_LOCALE] = { key = "locale", scopes = accountOnly, default = "auto", valueType = "string", allowedValues = { auto = true, zhCN = true, enUS = true } },
  [SettingId.SETTINGS_LAST_LEAF_PAGE] = { key = "settingsLastLeafPage", scopes = accountOnly, default = "general", valueType = "string" },

  [SettingId.MOVER_ENABLED] = { key = "mover.enabled", scopes = accountOnly, default = true, valueType = "boolean" },
  [SettingId.MOVER_DEBUG] = { key = "mover.debug", scopes = accountOnly, default = false, valueType = "boolean" },
  [SettingId.MOVER_FRAMES] = { key = "mover.frames", scopes = accountOnly, default = {}, valueType = "table", normalize = normalizeMoverFrames },
  [SettingId.MOVER_DRAG_HIT_MODE] = { key = "mover.dragHitMode", scopes = accountOnly, default = "titlebar", valueType = "string", allowedValues = { titlebar = true, titlebar_and_empty = true } },
  [SettingId.MOVER_ALLOW_DRAG_IN_COMBAT] = { key = "mover.allowDragInCombat", scopes = accountOnly, default = false, valueType = "boolean" },

  [SettingId.TOOLTIP_ENABLED] = { key = "tooltip_anchor.enabled", scopes = accountOnly, default = true, valueType = "boolean" },
  [SettingId.TOOLTIP_DEBUG] = { key = "tooltip_anchor.debug", scopes = accountOnly, default = false, valueType = "boolean" },
  [SettingId.TOOLTIP_MODE] = { key = "tooltip_anchor.mode", scopes = accountOnly, default = "cursor", valueType = "string", allowedValues = { default = true, cursor = true, follow = true } },
  [SettingId.TOOLTIP_OFFSET_X] = { key = "tooltip_anchor.offsetX", scopes = accountOnly, default = 0, valueType = "number" },
  [SettingId.TOOLTIP_OFFSET_Y] = { key = "tooltip_anchor.offsetY", scopes = accountOnly, default = 0, valueType = "number" },

  [SettingId.MINIMAP_ENABLED] = { key = "minimap_button.enabled", scopes = accountOnly, default = true, valueType = "boolean" },
  [SettingId.MINIMAP_DEBUG] = { key = "minimap_button.debug", scopes = accountOnly, default = false, valueType = "boolean" },
  [SettingId.MINIMAP_SHOW_BUTTON] = { key = "minimap_button.showMinimapButton", scopes = accountOnly, default = true, valueType = "boolean" },
  [SettingId.MINIMAP_SHOW_COORDS] = { key = "minimap_button.showCoordsOnMinimap", scopes = accountOnly, default = true, valueType = "boolean" },
  [SettingId.MINIMAP_COORDS_ANCHOR] = { key = "minimap_button.minimapCoordsAnchor", scopes = accountOnly, default = "bottom", valueType = "string", allowedValues = { top = true, bottom = true } },
  [SettingId.MINIMAP_POS] = { key = "minimap_button.minimapPos", scopes = accountOnly, default = nil, valueType = "number", normalize = normalizeMinimapPosition },
  [SettingId.MINIMAP_FLYOUT_SLOT_IDS] = { key = "minimap_button.flyoutSlotIds", scopes = accountOnly, default = { "reload_ui", "ac_flyout_quest" }, valueType = "table", normalize = normalizeFlyoutSlotIds },

  [SettingId.CHAT_ENABLED] = { key = "chat.enabled", scopes = accountOnly, default = true, valueType = "boolean" },
  [SettingId.CHAT_DEBUG] = { key = "chat.debug", scopes = accountOnly, default = false, valueType = "boolean" },
  [SettingId.CHAT_PREFIX_COLOR] = { key = "chat.prefixColor", scopes = accountOnly, default = "ffd700", valueType = "string" },
  [SettingId.CHAT_CONTENT_COLOR] = { key = "chat.contentColor", scopes = accountOnly, default = "ffffff", valueType = "string" },

  [SettingId.ENCOUNTER_JOURNAL_ENABLED] = { key = "encounter_journal.enabled", scopes = accountOnly, default = true, valueType = "boolean" },
  [SettingId.ENCOUNTER_JOURNAL_DEBUG] = { key = "encounter_journal.debug", scopes = accountOnly, default = false, valueType = "boolean" },
  [SettingId.ENCOUNTER_JOURNAL_MOUNT_FILTER_ENABLED] = { key = "encounter_journal.mountFilterEnabled", scopes = accountOnly, default = true, valueType = "boolean" },
  [SettingId.ENCOUNTER_JOURNAL_LIST_PIN_ALWAYS_VISIBLE] = { key = "encounter_journal.listPinAlwaysVisible", scopes = accountOnly, default = false, valueType = "boolean" },

  [SettingId.NAVIGATION_ENABLED] = { key = "navigation.enabled", scopes = accountOnly, default = true, valueType = "boolean" },
  [SettingId.NAVIGATION_DEBUG] = { key = "navigation.debug", scopes = accountOnly, default = false, valueType = "boolean" },
  [SettingId.NAVIGATION_ROUTE_WIDGET_EXPANDED] = { key = "navigation.routeWidgetExpanded", scopes = accountOnly, default = false, valueType = "boolean" },
  [SettingId.NAVIGATION_ROUTE_HISTORY_EXPANDED] = { key = "navigation.routeHistoryExpanded", scopes = accountOnly, default = false, valueType = "boolean" },
  [SettingId.NAVIGATION_ROUTE_WIDGET_POSITION] = { key = "navigation.routeWidgetPosition", scopes = accountOnly, default = { point = "TOP", x = 0, y = -18 }, valueType = "table", normalize = normalizeRouteWidgetPosition },
  [SettingId.NAVIGATION_ROUTE_HISTORY] = { key = "navigation.routeHistory", scopes = characterOnly, default = {}, valueType = "table", normalize = normalizeRouteHistory },

  [SettingId.QUEST_ENABLED] = { key = "quest.enabled", scopes = accountOnly, default = true, valueType = "boolean" },
  [SettingId.QUEST_DEBUG] = { key = "quest.debug", scopes = accountOnly, default = false, valueType = "boolean" },
  [SettingId.QUESTLINE_TREE_ENABLED] = { key = "quest.questlineTreeEnabled", scopes = accountOnly, default = true, valueType = "boolean" },
  [SettingId.QUEST_RECENT_COMPLETED_MAX] = { key = "quest.questRecentCompletedMax", scopes = accountOnly, default = 10, valueType = "number", integer = true, min = 1, max = 30 },
  [SettingId.QUEST_NAV_EXPANSION_ID] = { key = "questNavExpansionID", scopes = characterOnly, default = 0, valueType = "number", integer = true, min = 0 },
  [SettingId.QUEST_NAV_SELECTED_CAMPAIGN_ID] = { key = "questNavSelectedCampaignID", scopes = characterOnly, default = 0, valueType = "number", integer = true, min = 0 },
  [SettingId.QUEST_NAV_SELECTED_ACHIEVEMENT_ID] = { key = "questNavSelectedAchievementID", scopes = characterOnly, default = 0, valueType = "number", integer = true, min = 0 },
  [SettingId.QUEST_NAV_MODE_KEY] = { key = "questNavModeKey", scopes = characterOnly, default = "active_log", valueType = "string", allowedValues = { active_log = true, map_questline = true, campaign = true, achievement = true } },
  [SettingId.QUEST_NAV_SELECTED_MAP_ID] = { key = "questNavSelectedMapID", scopes = characterOnly, default = 0, valueType = "number", integer = true, min = 0 },
  [SettingId.QUEST_NAV_SEARCH_TEXT] = { key = "questNavSearchText", scopes = characterOnly, default = "", valueType = "string" },
  [SettingId.QUEST_INSPECTOR_LAST_QUEST_ID] = { key = "questInspectorLastQuestID", scopes = characterOnly, default = 0, valueType = "number", integer = true, min = 0 },
  [SettingId.QUEST_RECENT_COMPLETED_LIST] = { key = "questRecentCompletedList", scopes = characterOnly, default = {}, valueType = "table", normalize = normalizeQuestRecentCompletedList },
  [SettingId.QUEST_NAV_EXPANDED_QUESTLINE_ID] = { key = "questNavExpandedQuestLineID", scopes = characterOnly, default = 0, valueType = "number", integer = true, min = 0 },
  [SettingId.QUESTLINE_TREE_COLLAPSED] = { key = "questlineTreeCollapsed", scopes = characterOnly, default = {}, valueType = "table", normalize = normalizeCollapseMap },
}

--- 按 scope 返回根存档表并确保 values 存在。
---@param scope string 存档层级
---@return table|nil storeTable 根存档
local function ensureStore(scope)
  if scope == ACCOUNT_SCOPE then
    if type(AzerothCompanionDB) ~= "table" then
      AzerothCompanionDB = {}
    end
    AzerothCompanionDB.version = ACCOUNT_DB_VERSION
    AzerothCompanionDB.values = type(AzerothCompanionDB.values) == "table" and AzerothCompanionDB.values or {}
    AzerothCompanionDB.global = nil
    AzerothCompanionDB.modules = nil
    return AzerothCompanionDB
  elseif scope == CHARACTER_SCOPE then
    if type(AzerothCompanionDBChar) ~= "table" then
      AzerothCompanionDBChar = {}
    end
    AzerothCompanionDBChar.version = CHARACTER_DB_VERSION
    AzerothCompanionDBChar.values = type(AzerothCompanionDBChar.values) == "table" and AzerothCompanionDBChar.values or {}
    AzerothCompanionDBChar.global = nil
    AzerothCompanionDBChar.modules = nil
    return AzerothCompanionDBChar
  end
  return nil
end

--- 检查定义是否允许指定 scope。
---@param definition table|nil 设置定义
---@param scope string 存档层级
---@return boolean
local function isScopeAllowed(definition, scope)
  return type(definition) == "table" and type(definition.scopes) == "table" and definition.scopes[scope] == true
end

--- 根据定义归一化待写入的值。
---@param definition table 设置定义
---@param rawValue any 原始值
---@return any normalizedValue 归一结果
---@return boolean isValid 是否可写入
local function normalizeValue(definition, rawValue)
  if rawValue == nil then
    return nil, true
  end
  if type(definition.normalize) == "function" then
    local normalizedValue, isValid = definition.normalize(rawValue) -- 自定义归一结果
    if isValid == false then
      return nil, false
    end
    return normalizedValue, true
  end
  if definition.valueType == "boolean" then
    if type(rawValue) ~= "boolean" then
      return nil, false
    end
    return rawValue, true
  elseif definition.valueType == "string" then
    if type(rawValue) ~= "string" then
      return nil, false
    end
    if type(definition.allowedValues) == "table" and definition.allowedValues[rawValue] ~= true then
      return nil, false
    end
    return rawValue, true
  elseif definition.valueType == "number" then
    if type(rawValue) ~= "number" then
      return nil, false
    end
    local normalizedNumber = rawValue -- 归一后的数值
    if definition.integer == true then
      normalizedNumber = math.floor(normalizedNumber)
    end
    if type(definition.min) == "number" and normalizedNumber < definition.min then
      normalizedNumber = definition.min
    end
    if type(definition.max) == "number" and normalizedNumber > definition.max then
      normalizedNumber = definition.max
    end
    return normalizedNumber, true
  elseif definition.valueType == "table" then
    if type(rawValue) ~= "table" then
      return nil, false
    end
    return copyValue(rawValue), true
  end
  return rawValue, true
end

--- 读取底层存档值；可选择是否复制 table。
---@param settingId number 设置 ID
---@param scope string 存档层级
---@param shouldCopy boolean 是否复制 table
---@param ensureTableStore boolean 是否将 table 默认值写入存档供代理原地修改
---@return any
local function readValue(settingId, scope, shouldCopy, ensureTableStore)
  local definition = settingDefinitions[settingId] -- 设置定义
  if not isScopeAllowed(definition, scope) then
    return nil
  end
  local storeTable = ensureStore(scope) -- 根存档
  if not storeTable then
    return nil
  end
  local storedValue = storeTable.values[settingId] -- 当前存档值
  if storedValue == nil then
    if ensureTableStore == true and definition.valueType == "table" then
      local defaultTable = copyValue(definition.default or {}) -- 默认表副本
      storeTable.values[settingId] = defaultTable
      return defaultTable
    end
    return copyValue(definition.default)
  end
  local normalizedValue, isValid = normalizeValue(definition, storedValue) -- 归一后的存档值
  if isValid ~= true then
    storeTable.values[settingId] = nil
    return copyValue(definition.default)
  end
  storeTable.values[settingId] = normalizedValue
  if shouldCopy == true then
    return copyValue(normalizedValue)
  end
  return normalizedValue
end

--- 写入底层存档值。
---@param settingId number 设置 ID
---@param scope string 存档层级
---@param rawValue any 原始值
---@return boolean
local function writeValue(settingId, scope, rawValue)
  local definition = settingDefinitions[settingId] -- 设置定义
  if not isScopeAllowed(definition, scope) then
    return false
  end
  local storeTable = ensureStore(scope) -- 根存档
  if not storeTable then
    return false
  end
  if rawValue == nil then
    storeTable.values[settingId] = nil
    return true
  end
  local normalizedValue, isValid = normalizeValue(definition, rawValue) -- 归一后的待写值
  if isValid ~= true then
    return false
  end
  storeTable.values[settingId] = normalizedValue
  return true
end

--- 清理指定 scope 的 values 表，只保留当前定义允许的有效 ID。
---@param scope string 存档层级
local function normalizeStoreValues(scope)
  local storeTable = ensureStore(scope) -- 根存档
  if not storeTable then
    return
  end
  for settingId, storedValue in pairs(storeTable.values) do
    local numericId = type(settingId) == "number" and settingId or tonumber(settingId) -- 数字设置 ID
    local definition = numericId and settingDefinitions[numericId] or nil -- 设置定义
    if numericId ~= settingId then
      storeTable.values[settingId] = nil
    end
    if not isScopeAllowed(definition, scope) then
      storeTable.values[numericId or settingId] = nil
    else
      local normalizedValue, isValid = normalizeValue(definition, storedValue) -- 归一值
      if isValid == true and normalizedValue ~= nil then
        storeTable.values[numericId] = normalizedValue
      else
        storeTable.values[numericId] = nil
      end
    end
  end
end

--- 读取设置定义副本。
---@param settingId number 设置 ID
---@return table|nil
function AzerothCompanion.Config.GetSettingDefinition(settingId)
  local definition = settingDefinitions[settingId] -- 设置定义
  return definition and copyValue(definition) or nil
end

--- ADDON_LOADED 时调用；SavedVariables 已由客户端载入到全局表。
function AzerothCompanion.Config.Init()
  ensureStore(ACCOUNT_SCOPE)
  ensureStore(CHARACTER_SCOPE)
  normalizeStoreValues(ACCOUNT_SCOPE)
  normalizeStoreValues(CHARACTER_SCOPE)
end

--- 读取指定设置值；table 返回副本，调用方修改后必须 Set 回去。
---@param settingId number 设置 ID
---@param scope string "account" 或 "character"
---@return any
function AzerothCompanion.Config.Get(settingId, scope)
  return readValue(settingId, scope, true, false)
end

--- 写入指定设置值；会校验 ID、scope 与值类型。
---@param settingId number 设置 ID
---@param scope string "account" 或 "character"
---@param value any 待写值
---@return boolean
function AzerothCompanion.Config.Set(settingId, scope, value)
  return writeValue(settingId, scope, value)
end

--- 删除指定设置值；后续读取回落到默认值。
---@param settingId number 设置 ID
---@param scope string "account" 或 "character"
---@return boolean
function AzerothCompanion.Config.Reset(settingId, scope)
  return writeValue(settingId, scope, nil)
end
