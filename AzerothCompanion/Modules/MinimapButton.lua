--[[
  模块 minimap_button：小地图上的圆形按钮（暴雪小地图图标用底图 + 边框 + 图标圆形遮罩，与 LibDBIcon 视觉一致），点击打开 AzerothCompanion 设置总览。
  悬停时在按钮左侧展开横向操作列（RegisterFlyoutEntry 注册项；启动后 RegisterBuiltinFlyoutCatalog 会登记各模块设置、冒险手册、关于等，设置页通过勾选决定是否加入菜单）。
  位置算法与拖动命中与 LibDBIcon-1.0 同类：角度（度）+ 沿小地图形状约束。
  生命周期：MinimapCluster OnShow；可见性由模块启用与「显示小地图按钮」决定。
]]

--- 正式服小地图圆形图标资源（与 LibDBIcon ResetButton* 一致；边框须 TOPLEFT 对齐按钮，不能用 CENTER，否则环会错位）。
local TEX_MINIMAP_BG = "Interface\\Minimap\\UI-Minimap-Background"
local TEX_MINIMAP_BORDER = "Interface\\Minimap\\MiniMap-TrackingBorder"
local TEX_MINIMAP_HI = "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight"
local TEX_ICON_MASK_PRIMARY = "Interface\\Minimap\\UI-Minimap-IconMask"
local TEX_ICON_MASK_FALLBACK = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"
local ATLAS_ADVENTURE_GUIDE_ICON = "UI-HUD-MicroMenu-AdventureGuide-Up" -- 暴雪冒险手册微按钮正常态 atlas

AzerothCompanion.Modules.MinimapButton = AzerothCompanion.Modules.MinimapButton or {}

local MODULE_ID = "minimap_button"
local launcher
local minimapCoordsFrame  -- 小地图坐标高层容器
local minimapCoordsText  -- 小地图坐标文本
local worldMapCoordsText  -- 大地图左下角坐标文本
local coordsDriverFrame  -- 坐标刷新驱动 Frame
--- 悬停展开面板（UIParent 子级，锚在 launcher 左侧）；子级含圆形按钮与「桥接」透明层（缝补与主按钮之间的空隙，避免误触发隐藏）。
local flyoutFrame
--- 透明命中层：填补主按钮左缘与展开区右缘之间的缝，使光标移入子按钮时不会先被判定为离开。
local flyoutBridge
local flyoutHideHandle
--- 悬停菜单项（按 flyoutCatalog.order 固定排序）；由 syncFlyoutRegistryFromDb 根据 flyoutSlotIds 勾选结果填充。
local flyoutRegistry = {}
--- 已注册的悬停项模板 id → 定义（供 flyoutSlotIds 引用）。
local flyoutCatalog = {}
--- 按钮中心相对小地图「理论圆/方」半径外推像素，与 LibDBIcon lib.radius 一致。
local MINIMAP_ICON_RADIUS_EXTRA = 5

--- 默认角度（度），与 LibDBIcon 默认一致。
local DEFAULT_MINIMAP_ANGLE = 225
local MINIMAP_COORDS_ANCHOR_TOP = "top"
local MINIMAP_COORDS_ANCHOR_BOTTOM = "bottom"
local MINIMAP_COORDS_FRAME_LEVEL = 1000
local COORDS_UPDATE_INTERVAL_SEC = 0.1
local ACCOUNT_SCOPE = "account" -- 账号级设置 scope

local rad, cos, sin, sqrt, max, min, deg, atan2 = math.rad, math.cos, math.sin, math.sqrt, math.max, math.min, math.deg, math.atan2

--- 读取小地图按钮账号级设置。
---@param settingName string SettingId 字段名
---@param fallbackValue any 兜底值
---@return any
local function getMinimapSetting(settingName, fallbackValue)
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

--- 写入小地图按钮账号级设置。
---@param settingName string SettingId 字段名
---@param settingValue any 设置值
local function setMinimapSetting(settingName, settingValue)
  local settingId = AzerothCompanion.Config.SettingId[settingName] -- 数字设置 ID
  AzerothCompanion.Config.Set(settingId, ACCOUNT_SCOPE, settingValue)
end

--- 恢复小地图按钮默认设置。
local function resetMinimapSettings()
  local settingId = AzerothCompanion.Config.SettingId -- 数字设置 ID 表
  AzerothCompanion.Config.Reset(settingId.MINIMAP_ENABLED, ACCOUNT_SCOPE)
  AzerothCompanion.Config.Reset(settingId.MINIMAP_DEBUG, ACCOUNT_SCOPE)
  AzerothCompanion.Config.Reset(settingId.MINIMAP_SHOW_BUTTON, ACCOUNT_SCOPE)
  AzerothCompanion.Config.Reset(settingId.MINIMAP_SHOW_COORDS, ACCOUNT_SCOPE)
  AzerothCompanion.Config.Reset(settingId.MINIMAP_COORDS_ANCHOR, ACCOUNT_SCOPE)
  AzerothCompanion.Config.Reset(settingId.MINIMAP_POS, ACCOUNT_SCOPE)
  AzerothCompanion.Config.Reset(settingId.MINIMAP_FLYOUT_SLOT_IDS, ACCOUNT_SCOPE)
end

--- GetMinimapShape 四象限是否按椭圆弧处理（与 LibDBIcon minimapShapes 一致）。
local minimapShapes = {
  ROUND = { true, true, true, true },
  SQUARE = { false, false, false, false },
  ["CORNER-TOPLEFT"] = { false, false, false, true },
  ["CORNER-TOPRIGHT"] = { false, false, true, false },
  ["CORNER-BOTTOMLEFT"] = { false, true, false, false },
  ["CORNER-BOTTOMRIGHT"] = { true, false, false, false },
  ["SIDE-LEFT"] = { false, true, false, true },
  ["SIDE-RIGHT"] = { true, false, true, false },
  ["SIDE-TOP"] = { false, false, true, true },
  ["SIDE-BOTTOM"] = { true, true, false, false },
  ["TRICORNER-TOPLEFT"] = { false, true, true, true },
  ["TRICORNER-TOPRIGHT"] = { true, false, true, true },
  ["TRICORNER-BOTTOMLEFT"] = { true, true, false, true },
  ["TRICORNER-BOTTOMRIGHT"] = { true, true, true, false },
}

--- 按角度将按钮置于 Minimap 边缘内侧（LibDBIcon-1.0 updatePosition）。
---@param button Frame
---@param positionDeg number|nil 角度（度），nil 用默认
local function updateLauncherPositionFromAngle(button, positionDeg)
  local minimap = _G.Minimap
  if not minimap or not button then
    return
  end
  local mw, mh = minimap:GetWidth(), minimap:GetHeight()
  if not mw or not mh or mw < 8 or mh < 8 then
    return
  end
  local angle = rad(positionDeg or DEFAULT_MINIMAP_ANGLE)
  local x, y, q = cos(angle), sin(angle), 1
  if x < 0 then
    q = q + 1
  end
  if y > 0 then
    q = q + 2
  end
  local shapeName = "ROUND"
  if _G.GetMinimapShape then
    local ok, s = pcall(_G.GetMinimapShape)
    if ok and s and minimapShapes[s] then
      shapeName = s
    end
  end
  local quadTable = minimapShapes[shapeName] or minimapShapes.ROUND
  local w = (minimap:GetWidth() / 2) + MINIMAP_ICON_RADIUS_EXTRA
  local h = (minimap:GetHeight() / 2) + MINIMAP_ICON_RADIUS_EXTRA
  if quadTable[q] then
    x, y = x * w, y * h
  else
    local diagRadiusW = sqrt(2 * w * w) - 10
    local diagRadiusH = sqrt(2 * h * h) - 10
    x = max(-w, min(x * diagRadiusW, w))
    y = max(-h, min(y * diagRadiusH, h))
  end
  button:ClearAllPoints()
  button:SetPoint("CENTER", minimap, "CENTER", x, y)
end

--- 是否应显示小地图按钮。
---@return boolean
local function shouldShowLauncher()
  if getMinimapSetting("MINIMAP_ENABLED", true) == false then
    return false
  end
  if getMinimapSetting("MINIMAP_SHOW_BUTTON", true) == false then
    return false
  end
  return true
end

--- 拖动中根据光标更新角度并存档（LibDBIcon OnUpdate：光标用 Minimap:GetEffectiveScale()）。
local function onDragPositionUpdate(self)
  local minimap = _G.Minimap
  if not minimap then
    return
  end
  local mx, my = minimap:GetCenter()
  if not mx or not my then
    return
  end
  local px, py = GetCursorPosition()
  local scale = minimap:GetEffectiveScale()
  px = px / scale
  py = py / scale
  local pos = deg(atan2(py - my, px - mx)) % 360
  setMinimapSetting("MINIMAP_POS", pos)
  updateLauncherPositionFromAngle(self, pos)
end

--- 打开 AzerothCompanion 设置总览。
local function openSettings()
  AzerothCompanion_NamespaceEnsure()
  if AzerothCompanion.SettingsHost and AzerothCompanion.SettingsHost.Open then
    pcall(function()
      AzerothCompanion.SettingsHost:Open()
    end)
  end
end

--- 按存档放置按钮。
local function applyLauncherPosition()
  if not launcher then
    return
  end
  local angle = getMinimapSetting("MINIMAP_POS", nil)
  if angle == nil then
    angle = DEFAULT_MINIMAP_ANGLE
  end
  updateLauncherPositionFromAngle(launcher, angle)
end

--- 返回小地图坐标锚点（top / bottom）；非法值回退 bottom 并写档。
---@return string
local function getMinimapCoordsAnchor()
  local anchor = getMinimapSetting("MINIMAP_COORDS_ANCHOR", MINIMAP_COORDS_ANCHOR_BOTTOM)  -- 小地图坐标锚点字符串
  if anchor ~= MINIMAP_COORDS_ANCHOR_TOP and anchor ~= MINIMAP_COORDS_ANCHOR_BOTTOM then
    anchor = MINIMAP_COORDS_ANCHOR_BOTTOM
    setMinimapSetting("MINIMAP_COORDS_ANCHOR", anchor)
  end
  return anchor
end

--- 获取玩家当前最佳地图 id。
---@return number|nil
local function getPlayerBestMapID()
  if not C_Map or type(C_Map.GetBestMapForUnit) ~= "function" then
    return nil
  end
  local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
  if not ok or type(mapID) ~= "number" or mapID <= 0 then
    return nil
  end
  return mapID
end

--- 读取指定地图下玩家归一化坐标（0~1）。
---@param mapID number|nil
---@return number|nil, number|nil
local function getPlayerNormalizedCoords(mapID)
  if type(mapID) ~= "number" or mapID <= 0 then
    return nil, nil
  end
  if not C_Map or type(C_Map.GetPlayerMapPosition) ~= "function" then
    return nil, nil
  end
  local ok, mapPos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
  if not ok or not mapPos then
    return nil, nil
  end
  local posX = mapPos.x  -- 玩家坐标 X（0~1）
  local posY = mapPos.y  -- 玩家坐标 Y（0~1）
  if type(posX) ~= "number" or type(posY) ~= "number" then
    return nil, nil
  end
  return posX, posY
end

--- 读取当前大地图显示地图 id。
---@return number|nil
local function getWorldMapShownMapID()
  local worldMapFrame = _G.WorldMapFrame  -- 大地图根 Frame
  if not worldMapFrame or type(worldMapFrame.GetMapID) ~= "function" then
    return nil
  end
  local ok, mapID = pcall(worldMapFrame.GetMapID, worldMapFrame)
  if not ok or type(mapID) ~= "number" or mapID <= 0 then
    return nil
  end
  return mapID
end

--- 读取大地图当前鼠标归一化坐标（0~1）；鼠标不在地图区域时返回 nil。
---@return number|nil, number|nil
local function getWorldMapMouseNormalizedCoords()
  local worldMapFrame = _G.WorldMapFrame  -- 大地图根 Frame
  if not worldMapFrame or not worldMapFrame:IsShown() then
    return nil, nil
  end
  local scrollFrame = worldMapFrame.ScrollContainer  -- 地图滚动容器
  if not scrollFrame or type(scrollFrame.GetNormalizedCursorPosition) ~= "function" then
    return nil, nil
  end
  if type(scrollFrame.IsMouseOver) == "function" and not scrollFrame:IsMouseOver() then
    return nil, nil
  end
  local ok, posX, posY = pcall(scrollFrame.GetNormalizedCursorPosition, scrollFrame)
  if not ok or type(posX) ~= "number" or type(posY) ~= "number" then
    return nil, nil
  end
  if posX < 0 or posX > 1 or posY < 0 or posY > 1 then
    return nil, nil
  end
  return posX, posY
end

--- 将归一化坐标格式化为百分比文本（保留 1 位小数）。
---@param posX number|nil
---@param posY number|nil
---@return string
local function formatPercentCoords(posX, posY)
  local loc = AzerothCompanion.Localization.Strings or {}
  local unknown = loc.WORLD_MAP_COORDS_UNKNOWN or "--, --"
  if type(posX) ~= "number" or type(posY) ~= "number" then
    return unknown
  end
  return string.format("%.1f, %.1f", posX * 100, posY * 100)
end

--- 确保小地图坐标有独立高层容器；挂在 MinimapCluster 下，复用系统隐藏小地图时的父级显隐链路。
---@param minimapFrame Frame 小地图根 Frame
---@return Frame|nil
local function ensureMinimapCoordsFrame(minimapFrame)
  if not minimapFrame then
    return nil
  end
  local anchorParent = _G.MinimapCluster or minimapFrame -- 坐标容器父级，跟随小地图集群显隐
  if not anchorParent then
    return nil
  end
  if minimapCoordsFrame and minimapCoordsFrame:GetParent() ~= anchorParent then
    minimapCoordsFrame:SetParent(anchorParent)
  end
  if not minimapCoordsFrame then
    minimapCoordsFrame = CreateFrame("Frame", "AzerothCompanionMinimapCoordsFrame", anchorParent)
    minimapCoordsFrame:SetSize(170, 18)
    minimapCoordsFrame:EnableMouse(false)
  end

  minimapCoordsFrame:SetFrameStrata("TOOLTIP")
  if minimapCoordsFrame.SetToplevel then
    minimapCoordsFrame:SetToplevel(true)
  end
  minimapCoordsFrame:SetFrameLevel(MINIMAP_COORDS_FRAME_LEVEL)

  minimapCoordsFrame:ClearAllPoints()
  local anchor = getMinimapCoordsAnchor() -- 小地图坐标锚点
  if anchor == MINIMAP_COORDS_ANCHOR_TOP then
    minimapCoordsFrame:SetPoint("BOTTOM", minimapFrame, "TOP", 0, 2)
  else
    minimapCoordsFrame:SetPoint("TOP", minimapFrame, "BOTTOM", 0, -2)
  end
  minimapCoordsFrame:Show()
  return minimapCoordsFrame
end

--- 确保小地图坐标文本已创建并按设置锚点摆放。
---@return FontString|nil
local function ensureMinimapCoordsText()
  local minimapFrame = _G.Minimap  -- 小地图根 Frame
  if not minimapFrame then
    return nil
  end
  local coordsFrame = ensureMinimapCoordsFrame(minimapFrame) -- 小地图坐标高层容器
  if not coordsFrame then
    return nil
  end
  if not minimapCoordsText then
    minimapCoordsText = coordsFrame:CreateFontString("AzerothCompanionMinimapCoordsText", "OVERLAY", "GameFontNormalSmall")
    minimapCoordsText:SetWidth(170)
    minimapCoordsText:SetJustifyH("CENTER")
    minimapCoordsText:SetTextColor(1, 0.82, 0.18, 1)
  end
  minimapCoordsText:SetDrawLayer("OVERLAY", 7)
  minimapCoordsText:ClearAllPoints()
  minimapCoordsText:SetPoint("CENTER", coordsFrame, "CENTER", 0, 0)
  return minimapCoordsText
end

--- 确保大地图左下角坐标文本已创建并锚定。
---@return FontString|nil
local function ensureWorldMapCoordsText()
  local worldMapFrame = _G.WorldMapFrame  -- 大地图根 Frame
  if not worldMapFrame then
    return nil
  end
  local anchorParent = worldMapFrame.BorderFrame or worldMapFrame  -- 左下角锚点父级
  if not anchorParent then
    return nil
  end
  if worldMapCoordsText and worldMapCoordsText:GetParent() ~= anchorParent then
    worldMapCoordsText:SetParent(anchorParent)
    worldMapCoordsText:ClearAllPoints()
  end
  if not worldMapCoordsText then
    worldMapCoordsText = anchorParent:CreateFontString("AzerothCompanionWorldMapCoordsText", "OVERLAY", "GameFontHighlightSmall")
    worldMapCoordsText:SetWidth(420)
    worldMapCoordsText:SetJustifyH("LEFT")
    worldMapCoordsText:SetTextColor(1, 0.82, 0.18, 1)
  end
  worldMapCoordsText:ClearAllPoints()
  worldMapCoordsText:SetPoint("BOTTOMLEFT", anchorParent, "BOTTOMLEFT", 16, 10)
  return worldMapCoordsText
end

--- 刷新小地图坐标文本（玩家坐标）。
local function updateMinimapCoordsText()
  local coordsText = ensureMinimapCoordsText()  -- 小地图坐标文本对象
  if not coordsText then
    return
  end
  if getMinimapSetting("MINIMAP_ENABLED", true) == false or getMinimapSetting("MINIMAP_SHOW_COORDS", true) == false then
    coordsText:Hide()
    if minimapCoordsFrame then
      minimapCoordsFrame:Hide()
    end
    return
  end
  local mapID = getPlayerBestMapID()
  local playerX, playerY = getPlayerNormalizedCoords(mapID)
  local loc = AzerothCompanion.Localization.Strings or {}
  coordsText:SetText(string.format(loc.MINIMAP_COORDS_PLAYER_FMT or "Player: %s", formatPercentCoords(playerX, playerY)))
  coordsText:Show()
end

--- 刷新大地图左下角坐标文本（玩家坐标 + 鼠标坐标）。
local function updateWorldMapCoordsText()
  if getMinimapSetting("MINIMAP_ENABLED", true) == false then
    if worldMapCoordsText then
      worldMapCoordsText:Hide()
    end
    return
  end
  local worldMapFrame = _G.WorldMapFrame  -- 大地图根 Frame
  if not worldMapFrame or not worldMapFrame:IsShown() then
    if worldMapCoordsText then
      worldMapCoordsText:Hide()
    end
    return
  end
  local coordsText = ensureWorldMapCoordsText()  -- 大地图坐标文本对象
  if not coordsText then
    return
  end
  local mapID = getWorldMapShownMapID() or getPlayerBestMapID()
  local playerX, playerY = getPlayerNormalizedCoords(mapID)
  local mouseX, mouseY = getWorldMapMouseNormalizedCoords()
  local loc = AzerothCompanion.Localization.Strings or {}
  local playerText = string.format(loc.WORLD_MAP_COORDS_PLAYER_FMT or "Player: %s", formatPercentCoords(playerX, playerY))
  local mouseText = string.format(loc.WORLD_MAP_COORDS_MOUSE_FMT or "Mouse: %s", formatPercentCoords(mouseX, mouseY))
  coordsText:SetText(playerText .. "    " .. mouseText)
  coordsText:Show()
end

--- 停止坐标刷新驱动并隐藏相关文本。
local function stopCoordinateDisplays()
  if coordsDriverFrame then
    coordsDriverFrame:SetScript("OnUpdate", nil)
    coordsDriverFrame._azerothCompanionCoordElapsed = 0
  end
  if minimapCoordsText then
    minimapCoordsText:Hide()
  end
  if minimapCoordsFrame then
    minimapCoordsFrame:Hide()
  end
  if worldMapCoordsText then
    worldMapCoordsText:Hide()
  end
end

--- 刷新坐标显示生命周期：模块启用时启动节流刷新，禁用时关闭。
local function refreshCoordinateDisplays()
  if getMinimapSetting("MINIMAP_ENABLED", true) == false then
    stopCoordinateDisplays()
    return
  end
  if not coordsDriverFrame then
    coordsDriverFrame = CreateFrame("Frame", "AzerothCompanionMapCoordDriver", UIParent)
  end
  coordsDriverFrame._azerothCompanionCoordElapsed = COORDS_UPDATE_INTERVAL_SEC
  coordsDriverFrame:SetScript("OnUpdate", function(self, elapsed)
    local elapsedTotal = (self._azerothCompanionCoordElapsed or 0) + elapsed
    if elapsedTotal < COORDS_UPDATE_INTERVAL_SEC then
      self._azerothCompanionCoordElapsed = elapsedTotal
      return
    end
    self._azerothCompanionCoordElapsed = 0
    updateMinimapCoordsText()
    updateWorldMapCoordsText()
  end)
  updateMinimapCoordsText()
  updateWorldMapCoordsText()
end

--- 与主按钮同 31×31；悬停菜单固定为横向圆形按钮组。
local FLYOUT_BUTTON_SIZE = 31
local FLYOUT_ATLAS_ICON_SIZE = 24
local FLYOUT_TEXTURE_ICON_SIZE = 18
local FLYOUT_PAD = 4
local FLYOUT_GAP = 0
local FLYOUT_LAUNCHER_GAP = 0
--- 略加长，配合桥接层；仍依赖桥接消除主按钮与面板之间的死区。
local FLYOUT_HIDE_DELAY_SEC = 0.35

--- 返回按 order / id 固定排序后的悬停菜单模板 id 列表。
---@return table
local function getSortedFlyoutEntryIds()
  local entryIdList = {} -- 已排序的悬停菜单模板 id 列表
  for entryId in pairs(flyoutCatalog) do
    entryIdList[#entryIdList + 1] = entryId
  end
  table.sort(entryIdList, function(leftId, rightId)
    local leftDef = flyoutCatalog[leftId] -- 左侧模板定义
    local rightDef = flyoutCatalog[rightId] -- 右侧模板定义
    local leftOrder = tonumber(leftDef and leftDef.order) or 100 -- 左侧排序值
    local rightOrder = tonumber(rightDef and rightDef.order) or 100 -- 右侧排序值
    if leftOrder ~= rightOrder then
      return leftOrder < rightOrder
    end
    return leftId < rightId
  end)
  return entryIdList
end

--- 确保悬停菜单勾选列表可用。
---@return table
local function getFlyoutSlotIds()
  local selectedIdList = getMinimapSetting("MINIMAP_FLYOUT_SLOT_IDS", { "reload_ui", "ac_flyout_quest" }) -- 已勾选 id 列表
  if type(selectedIdList) ~= "table" then
    selectedIdList = { "reload_ui", "ac_flyout_quest" }
  end
  return selectedIdList
end

--- 取消悬停面板的延迟隐藏计时器。
local function cancelFlyoutHideTimer()
  if flyoutHideHandle then
    flyoutHideHandle:Cancel()
    flyoutHideHandle = nil
  end
end

--- 判断指定 Frame 当前是否被鼠标指向。
---@param frameObject Frame|nil 待检查 Frame
---@return boolean
local function isFrameMouseOver(frameObject)
  if frameObject and type(frameObject.IsMouseOver) == "function" then
    return frameObject:IsMouseOver() == true
  end
  return false
end

--- 判断鼠标是否仍在小地图主按钮、飞出面板、桥接层或任一飞出子按钮上。
---@return boolean
local function isFlyoutMouseActive()
  if isFrameMouseOver(launcher) or isFrameMouseOver(flyoutFrame) or isFrameMouseOver(flyoutBridge) then
    return true
  end
  local buttonList = flyoutFrame and flyoutFrame._buttons or nil -- 当前飞出子按钮列表
  if type(buttonList) == "table" then
    for _, buttonFrame in ipairs(buttonList) do
      if isFrameMouseOver(buttonFrame) then
        return true
      end
    end
  end
  return false
end

--- 立即隐藏悬停面板（拖动主按钮或刷新可见性时调用）。
local function hideFlyoutPanel()
  cancelFlyoutHideTimer()
  if flyoutFrame then
    flyoutFrame:Hide()
  end
end

--- 离开主按钮/面板后短延迟再隐藏，便于光标移入横向菜单。
local function scheduleFlyoutHide()
  cancelFlyoutHideTimer()
  flyoutHideHandle = C_Timer.NewTimer(FLYOUT_HIDE_DELAY_SEC, function()
    flyoutHideHandle = nil
    if isFlyoutMouseActive() then
      return
    end
    if flyoutFrame then
      flyoutFrame:Hide()
    end
  end)
end

--- 与主按钮图标层相同的 SetMask 圆形裁切（失败则仅靠 TexCoord）。
---@param tex Texture
---@return boolean
local function applyCircularIconMask(tex)
  for _, maskPath in ipairs({ TEX_ICON_MASK_PRIMARY, TEX_ICON_MASK_FALLBACK }) do
    local ok = pcall(function()
      tex:SetMask(maskPath)
    end)
    if ok then
      return true
    end
  end
  return false
end

--- 悬停子按钮：固定使用圆形按钮样式。
---@param parent Frame
---@param def table
---@param localeTable table
---@return Button
local function createFlyoutItemButton(parent, def, localeTable)
  local btn = CreateFrame("Button", nil, parent) -- 悬停菜单圆形按钮
  btn:SetSize(FLYOUT_BUTTON_SIZE, FLYOUT_BUTTON_SIZE)
  local bg = btn:CreateTexture(nil, "BACKGROUND") -- 按钮底图
  bg:SetTexture(TEX_MINIMAP_BG)
  bg:SetSize(24, 24)
  bg:SetPoint("CENTER", btn, "CENTER", 0, 0)
  local border = btn:CreateTexture(nil, "OVERLAY") -- 按钮边框
  border:SetTexture(TEX_MINIMAP_BORDER)
  border:SetSize(50, 50)
  border:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
  local hasAtlasIcon = type(def.iconAtlas) == "string" and def.iconAtlas ~= "" -- 是否使用 Blizzard atlas 图标
  local hasTextureIcon = type(def.icon) == "string" and def.icon ~= "" -- 是否使用普通文件贴图图标
  if hasAtlasIcon or hasTextureIcon then
    local icon = btn:CreateTexture(nil, "ARTWORK") -- 功能图标
    icon:SetPoint("CENTER", btn, "CENTER", 0, 0)
    if hasAtlasIcon and type(icon.SetAtlas) == "function" then
      -- 微按钮 atlas 本身已是裁切后的暴雪资源；放到圆形底图时要铺满底图，且不要再叠加圆形遮罩。
      icon:SetSize(FLYOUT_ATLAS_ICON_SIZE, FLYOUT_ATLAS_ICON_SIZE)
      icon:SetAtlas(def.iconAtlas, false)
    elseif hasTextureIcon then
      icon:SetSize(FLYOUT_TEXTURE_ICON_SIZE, FLYOUT_TEXTURE_ICON_SIZE)
      icon:SetTexture(def.icon)
      icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
      if not applyCircularIconMask(icon) then
        icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
      end
    end
  else
    local labelText = (def.titleKey and (localeTable[def.titleKey] or def.titleKey)) or def.title or "?" -- 无图标时的文本
    local fontString = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall") -- 无图标时的文本节点
    fontString:SetPoint("CENTER", 0, 0)
    fontString:SetWidth(26)
    fontString:SetMaxLines(2)
    fontString:SetText(labelText)
    fontString:SetJustifyH("CENTER")
  end
  btn:SetHighlightTexture(TEX_MINIMAP_HI)
  local highlightTexture = btn:GetHighlightTexture() -- 高亮纹理
  if highlightTexture then
    highlightTexture:SetBlendMode("ADD")
  end
  btn:RegisterForClicks("LeftButtonUp")
  return btn
end

--- 桥接层与展开区锚点：主按钮与展开区之间留窄缝，由透明桥接层接收鼠标。
local function layoutFlyoutAndBridge()
  if not flyoutFrame or not launcher then
    return
  end
  flyoutFrame:ClearAllPoints()
  flyoutFrame:SetPoint("RIGHT", launcher, "LEFT", -FLYOUT_LAUNCHER_GAP, 0)
  if flyoutBridge then
    flyoutBridge:ClearAllPoints()
    flyoutBridge:SetPoint("LEFT", flyoutFrame, "RIGHT", 0, 0)
    flyoutBridge:SetPoint("RIGHT", launcher, "LEFT", 0, 0)
    flyoutBridge:SetPoint("TOP", flyoutFrame, "TOP", 0, 0)
    flyoutBridge:SetPoint("BOTTOM", flyoutFrame, "BOTTOM", 0, 0)
  end
end

--- 拓展菜单项在提示框第一行显示的名称（与 titleKey / title 一致，与图标旁可见文案对齐）。
---@param def table RegisterFlyoutEntry 的 entry
---@param localeTable table AzerothCompanion.Localization.Strings
---@return string
local function getFlyoutEntryDisplayName(def, localeTable)
  localeTable = localeTable or {}
  if def.titleKey and type(localeTable[def.titleKey]) == "string" and localeTable[def.titleKey] ~= "" then
    return localeTable[def.titleKey]
  end
  if type(def.title) == "string" and def.title ~= "" then
    return def.title
  end
  if type(def.id) == "string" and def.id ~= "" then
    return def.id
  end
  return "?"
end

--- 鼠标指向拓展按钮：第一行为具体功能名称；若有 tooltipKey / tooltip 则第二行为补充说明。
---@param owner Region
---@param def table
---@param localeTable table
local function showFlyoutButtonTooltip(owner, def, localeTable)
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  if GameTooltip.ClearLines then
    GameTooltip:ClearLines()
  end
  local name = getFlyoutEntryDisplayName(def, localeTable)
  GameTooltip:SetText(name, 1, 1, 1)
  if def.tooltipKey then
    local desc = localeTable[def.tooltipKey]
    if type(desc) == "string" and desc ~= "" then
      GameTooltip:AddLine(desc, 0.82, 0.88, 1, true)
    end
  elseif type(def.tooltip) == "string" and def.tooltip ~= "" then
    GameTooltip:AddLine(def.tooltip, 0.82, 0.88, 1, true)
  end
  if type(def.augmentTooltip) == "function" then
    pcall(def.augmentTooltip)
  end
  GameTooltip:Show()
end

--- 根据 flyoutRegistry 重建悬停面板内按钮（固定为横向圆形菜单）。
local function rebuildFlyoutButtons()
  if not flyoutFrame then
    return
  end
  local oldButtonList = flyoutFrame._buttons or {} -- 旧按钮列表
  for _, buttonFrame in ipairs(oldButtonList) do
    buttonFrame:Hide()
    buttonFrame:SetParent(nil)
  end
  flyoutFrame._buttons = {}
  local buttonCount = #flyoutRegistry -- 当前选中的悬停按钮数量
  if buttonCount == 0 then
    flyoutFrame:SetWidth(FLYOUT_PAD * 2)
    flyoutFrame:SetHeight(FLYOUT_PAD * 2)
    layoutFlyoutAndBridge()
    return
  end
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案
  local buttonStep = FLYOUT_BUTTON_SIZE + FLYOUT_GAP -- 横向相邻按钮步长
  local flyoutWidth = FLYOUT_PAD * 2 + buttonCount * FLYOUT_BUTTON_SIZE + math.max(0, buttonCount - 1) * FLYOUT_GAP -- 展开区总宽
  local flyoutHeight = FLYOUT_PAD * 2 + FLYOUT_BUTTON_SIZE -- 展开区总高
  flyoutFrame:SetWidth(flyoutWidth)
  flyoutFrame:SetHeight(flyoutHeight)
  for index = 1, buttonCount do
    local entryDef = flyoutRegistry[index] -- 当前按钮定义
    local buttonFrame = createFlyoutItemButton(flyoutFrame, entryDef, localeTable) -- 当前按钮
    buttonFrame:ClearAllPoints()
    buttonFrame:SetPoint("TOPRIGHT", flyoutFrame, "TOPRIGHT", -(FLYOUT_PAD + (index - 1) * buttonStep), -FLYOUT_PAD)
    buttonFrame:SetScript("OnClick", function()
      if entryDef.onClick then
        pcall(entryDef.onClick, buttonFrame)
      end
      hideFlyoutPanel()
    end)
    buttonFrame:SetScript("OnEnter", function(self)
      cancelFlyoutHideTimer()
      showFlyoutButtonTooltip(self, entryDef, localeTable)
    end)
    buttonFrame:SetScript("OnLeave", function()
      GameTooltip:Hide()
      scheduleFlyoutHide()
    end)
    flyoutFrame._buttons[#flyoutFrame._buttons + 1] = buttonFrame
  end
  layoutFlyoutAndBridge()
end

--- 根据勾选的 flyoutSlotIds 从 flyoutCatalog 填充 flyoutRegistry 并重建展开区。
local function syncFlyoutRegistryFromDb()
  wipe(flyoutRegistry)
  local selectedIdList = getFlyoutSlotIds() -- 已勾选 id 列表
  local selectedMap = {} -- 已勾选 id 查找表
  for _, entryId in ipairs(selectedIdList) do
    if type(entryId) == "string" and entryId ~= "" then
      selectedMap[entryId] = true
    end
  end
  for _, entryId in ipairs(getSortedFlyoutEntryIds()) do
    if selectedMap[entryId] and flyoutCatalog[entryId] then
      flyoutRegistry[#flyoutRegistry + 1] = flyoutCatalog[entryId]
    end
  end
  rebuildFlyoutButtons()
end

--- 主按钮外观：固定使用圆形小地图按钮样式。
local function applyLauncherSkin(button)
  if not button or not button._ac_bg or not button._ac_icon or not button._ac_border then
    return
  end
  local bg = button._ac_bg -- 主按钮底图
  local icon = button._ac_icon -- 主按钮图标
  local border = button._ac_border -- 主按钮边框
  if button.ClearBackdrop then
    button:ClearBackdrop()
  end
  border:Show()
  bg:ClearAllPoints()
  bg:SetTexture(TEX_MINIMAP_BG)
  bg:SetVertexColor(1, 1, 1, 1)
  bg:SetSize(24, 24)
  bg:SetPoint("CENTER", button, "CENTER", 0, 0)
  icon:ClearAllPoints()
  icon:SetTexture("Interface\\Icons\\Trade_Engineering")
  icon:SetSize(18, 18)
  icon:SetPoint("CENTER", button, "CENTER", 0, 0)
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  if not applyCircularIconMask(icon) then
    icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
  end
  button:SetHighlightTexture(TEX_MINIMAP_HI)
  local highlightTexture = button:GetHighlightTexture() -- 主按钮高亮纹理
  if highlightTexture then
    highlightTexture:SetBlendMode("ADD")
  end
end

--- 创建主按钮底图 / 图标 / 外圈引用并应用当前圆形样式。
---@param button Button
local function createLauncherChrome(button)
  local bg = button:CreateTexture(nil, "BACKGROUND")
  local icon = button:CreateTexture(nil, "ARTWORK")
  local border = button:CreateTexture(nil, "OVERLAY")
  border:SetTexture(TEX_MINIMAP_BORDER)
  border:SetSize(50, 50)
  border:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
  button._ac_bg = bg
  button._ac_icon = icon
  button._ac_border = border
  applyLauncherSkin(button)
end

--- 创建悬停展开面板（仅一次，依赖已存在的 launcher）。
local function ensureFlyoutFrame()
  if flyoutFrame or not launcher then
    return
  end
  flyoutFrame = CreateFrame("Frame", "AzerothCompanionMinimapFlyout", UIParent)
  -- 飞出按钮本身不占用 TOOLTIP 层，避免遮挡主按钮或子按钮的 GameTooltip。
  flyoutFrame:SetFrameStrata("DIALOG")
  flyoutFrame:SetFrameLevel((launcher:GetFrameLevel() or 0) + 50)
  flyoutFrame:EnableMouse(true)
  flyoutFrame:SetClampedToScreen(true)
  if flyoutFrame.SetClipsChildren then
    flyoutFrame:SetClipsChildren(false)
  end
  flyoutFrame:Hide()
  flyoutFrame:SetScript("OnEnter", function()
    cancelFlyoutHideTimer()
  end)
  flyoutFrame:SetScript("OnLeave", function()
    scheduleFlyoutHide()
  end)

  flyoutBridge = CreateFrame("Frame", "AzerothCompanionMinimapFlyoutBridge", flyoutFrame)
  flyoutBridge:SetFrameLevel(flyoutFrame:GetFrameLevel() + 10)
  flyoutBridge:EnableMouse(true)
  flyoutBridge:SetScript("OnEnter", function()
    cancelFlyoutHideTimer()
  end)
  flyoutBridge:SetScript("OnLeave", function()
    scheduleFlyoutHide()
  end)

  rebuildFlyoutButtons()
end

--- 注册悬停时展开的菜单项模板（其它模块可在加载时调用）；是否出现在菜单中由存档 flyoutSlotIds 决定。
---@param entry table id: string 唯一；order: number 可选（仅作同批注册时的排序提示）；icon 为普通贴图路径，iconAtlas 为 Blizzard atlas 名；titleKey / tooltipKey / onClick 等同前
function AzerothCompanion.Modules.MinimapButton.RegisterFlyoutEntry(entry)
  if type(entry) ~= "table" or type(entry.id) ~= "string" or entry.id == "" then
    return
  end
  flyoutCatalog[entry.id] = entry
  syncFlyoutRegistryFromDb()
end

local function onLauncherDragStart(self)
  GameTooltip:Hide()
  hideFlyoutPanel()
  self:SetScript("OnUpdate", onDragPositionUpdate)
end

local function onLauncherDragStop(self)
  self:SetScript("OnUpdate", nil)
end

--- 创建按钮（仅一次）。
---@return boolean
local function ensureLauncher()
  if launcher then
    return true
  end
  local minimap = _G.Minimap
  if not minimap then
    return false
  end
  launcher = CreateFrame("Button", "AzerothCompanionMinimapLauncherButton", minimap, "BackdropTemplate")
  -- 与 LibDBIcon 默认 31x31 一致；固定使用圆形小地图按钮观感
  launcher:SetSize(31, 31)
  launcher:SetFrameStrata("MEDIUM")
  if launcher.SetFixedFrameStrata then
    pcall(function()
      launcher:SetFixedFrameStrata(true)
    end)
  end
  launcher:SetFrameLevel(minimap:GetFrameLevel() + 10)
  if launcher.SetFixedFrameLevel then
    pcall(function()
      launcher:SetFixedFrameLevel(true)
    end)
  end
  launcher:EnableMouse(true)
  launcher:RegisterForClicks("anyUp")
  launcher:RegisterForDrag("LeftButton")

  -- 必须先锚定到 Minimap，再挂子纹理；否则按钮会落在父框架默认位置（常表现为小地图左上角）
  applyLauncherPosition()

  createLauncherChrome(launcher)

  launcher:SetScript("OnDragStart", onLauncherDragStart)
  launcher:SetScript("OnDragStop", onLauncherDragStop)
  launcher:SetScript("OnClick", function(_, button)
    if button == "LeftButton" then
      openSettings()
    end
  end)

  ensureFlyoutFrame()

  -- 小地图首帧宽可能为 0，OnShow 后再算一次边缘位置（下一帧合并，非秒级等布局）
  if not minimap.__azerothCompanion_minimapBtnLayoutHook then
    minimap.__azerothCompanion_minimapBtnLayoutHook = true
    minimap:HookScript("OnShow", function()
      if launcher and launcher:IsShown() then
        applyLauncherPosition()
      end
    end)
  end

  launcher:SetScript("OnEnter", function(self)
    cancelFlyoutHideTimer()
    ensureFlyoutFrame()
    if flyoutFrame and #flyoutRegistry > 0 then
      rebuildFlyoutButtons()
      flyoutFrame:Show()
    end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    local localeTable = AzerothCompanion.Localization.Strings or {}
    GameTooltip:SetText(localeTable.MINIMAP_BUTTON_TOOLTIP_TITLE or AzerothCompanion.ADDON_DISPLAY_NAME or "AzerothCompanion", 1, 1, 1)
    GameTooltip:AddLine(localeTable.MINIMAP_BUTTON_TOOLTIP_HINT or "", 1, 1, 1, true)
    if localeTable.MINIMAP_BUTTON_TOOLTIP_FLYOUT and localeTable.MINIMAP_BUTTON_TOOLTIP_FLYOUT ~= "" then
      GameTooltip:AddLine(localeTable.MINIMAP_BUTTON_TOOLTIP_FLYOUT, 0.75, 0.9, 1, true)
    end
    GameTooltip:AddLine(localeTable.MINIMAP_BUTTON_TOOLTIP_DRAG or "", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  launcher:SetScript("OnLeave", function()
    GameTooltip:Hide()
    scheduleFlyoutHide()
  end)

  return true
end

--- 将按钮恢复为默认角度并写档。
function AzerothCompanion.Modules.MinimapButton.ResetPositionToDefault()
  setMinimapSetting("MINIMAP_POS", nil)
  applyLauncherPosition()
end

--- 向设置页容器追加小地图玩家坐标显示设置。
--- 设置归属在地图页，但运行时文本由小地图按钮模块维护；因此仍读写 minimap_button 模块存档。
---@param box table SettingsHost 创建的设置容器，需提供 AddToggleRow / AddChoiceRow
function AzerothCompanion.Modules.MinimapButton.RegisterCoordinateSettings(box)
  if not box then
    return
  end
  local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案

  box:AddToggleRow({
    label = localeTable.MINIMAP_COORDS_SETTING_SHOW or "",
    refreshMode = "local",
    getValue = function()
      return getMinimapSetting("MINIMAP_SHOW_COORDS", true) ~= false
    end,
    setValue = function(value)
      setMinimapSetting("MINIMAP_SHOW_COORDS", value == true)
    end,
    afterChange = function()
      refreshCoordinateDisplays()
    end,
  })

  box:AddChoiceRow({
    label = localeTable.MINIMAP_COORDS_SETTING_ANCHOR or "",
    refreshMode = "local",
    buttonWidth = 120,
    enabledWhen = function()
      return getMinimapSetting("MINIMAP_SHOW_COORDS", true) ~= false
    end,
    options = {
      { value = MINIMAP_COORDS_ANCHOR_TOP, label = localeTable.MINIMAP_COORDS_SETTING_ANCHOR_TOP or "" },
      { value = MINIMAP_COORDS_ANCHOR_BOTTOM, label = localeTable.MINIMAP_COORDS_SETTING_ANCHOR_BOTTOM or "" },
    },
    getValue = function()
      return getMinimapCoordsAnchor()
    end,
    setValue = function(value)
      setMinimapSetting("MINIMAP_COORDS_ANCHOR", value)
    end,
    afterChange = function()
      refreshCoordinateDisplays()
    end,
  })
end

--- 刷新显示与位置。
function AzerothCompanion.Modules.MinimapButton.Refresh()
  local launcherReady = ensureLauncher()  -- 小地图按钮是否已创建
  if launcherReady then
    applyLauncherPosition()
    if shouldShowLauncher() then
      launcher:Show()
    else
      hideFlyoutPanel()
      launcher:Hide()
    end
    -- 与 ensureLauncher 内创建链一致；保证提交间距后必有 flyoutFrame 可重建（避免仅 rebuild 时早退）
    ensureFlyoutFrame()
    -- 设置页会直接修改 flyoutSlotIds；刷新前从存档同步一次，避免悬停按钮仍使用旧 registry。
    syncFlyoutRegistryFromDb()
    if launcher and launcher._ac_bg then
      applyLauncherSkin(launcher)
    end
  end
  refreshCoordinateDisplays()
end

local clusterHooked

local function initClusterHook()
  if clusterHooked then
    return
  end
  local cluster = _G.MinimapCluster
  if not cluster then
    return
  end
  clusterHooked = true
  cluster:HookScript("OnShow", function()
    AzerothCompanion.Modules.MinimapButton.Refresh()
  end)
end

function AzerothCompanion.Modules.MinimapButton.Init()
  initClusterHook()
  AzerothCompanion.Modules.MinimapButton.Refresh()
end

AzerothCompanion.RegisterModule({
  id = MODULE_ID,
  nameKey = "MODULE_MINIMAP_BUTTON",
  settingsIntroKey = "MODULE_MINIMAP_BUTTON_INTRO",
  settingsOrder = 15,
  OnModuleLoad = function()
    AzerothCompanion.Modules.MinimapButton.Init()
  end,
  OnModuleEnable = function()
    AzerothCompanion.Modules.MinimapButton.Init()
  end,
  OnEnabledSettingChanged = function(enabled)
    local localeTable = AzerothCompanion.Localization.Strings or {}
    local key = enabled and "SETTINGS_MODULE_ENABLED_FMT" or "SETTINGS_MODULE_DISABLED_FMT"
    AzerothCompanion.API.Chat.PrintAddonMessage(string.format(localeTable[key] or "%s", localeTable.MODULE_MINIMAP_BUTTON or MODULE_ID))
    if not enabled then
      -- 模块禁用时取消待执行的延迟隐藏计时器，避免禁用后仍触发
      cancelFlyoutHideTimer()
    end
    AzerothCompanion.Modules.MinimapButton.Refresh()
  end,
  OnDebugSettingChanged = function(enabled)
    local localeTable = AzerothCompanion.Localization.Strings or {}
    local key = enabled and "SETTINGS_MODULE_DEBUG_ON_FMT" or "SETTINGS_MODULE_DEBUG_OFF_FMT"
    AzerothCompanion.API.Chat.PrintAddonMessage(string.format(localeTable[key] or "%s", localeTable.MODULE_MINIMAP_BUTTON or MODULE_ID))
  end,
  ResetToDefaultsAndRebuild = function()
    resetMinimapSettings()
    AzerothCompanion.Modules.MinimapButton.Refresh()
  end,
  RegisterSettings = function(box)
    local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案

    box:AddToggleRow({
      label = localeTable.MINIMAP_BUTTON_SETTING_SHOW or "",
      description = localeTable.MINIMAP_BUTTON_SETTING_HINT or "",
      refreshMode = "local",
      getValue = function()
        return getMinimapSetting("MINIMAP_SHOW_BUTTON", true) ~= false
      end,
      setValue = function(value)
        setMinimapSetting("MINIMAP_SHOW_BUTTON", value == true)
      end,
      afterChange = function()
        AzerothCompanion.Modules.MinimapButton.Refresh()
      end,
    })

    box:AddActionRow({
      label = localeTable.MINIMAP_BUTTON_RESET_POSITION or "",
      buttonText = localeTable.MINIMAP_BUTTON_RESET_POSITION or "",
      buttonWidth = 200,
      refreshMode = "local",
      onClick = function()
        AzerothCompanion.Modules.MinimapButton.ResetPositionToDefault()
      end,
    })
  end,
})

-- 内置悬停项：重载界面（其它模块可在加载后调用 RegisterFlyoutEntry 追加，order 建议 20+）
AzerothCompanion.Modules.MinimapButton.RegisterFlyoutEntry({
  id = "reload_ui",
  order = 10,
  titleKey = "MINIMAP_FLYOUT_RELOAD",
  tooltipKey = "MINIMAP_FLYOUT_RELOAD_TOOLTIP",
  icon = "Interface\\Icons\\Spell_Nature_TimeStop",
  onClick = function()
    if _G.ReloadUI then
      _G.ReloadUI()
    end
  end,
})

AzerothCompanion.Modules.MinimapButton.RegisterFlyoutEntry({
  id = "open_settings",
  order = 15,
  titleKey = "MINIMAP_FLYOUT_OPEN_SETTINGS",
  tooltipKey = "MINIMAP_FLYOUT_OPEN_SETTINGS_TOOLTIP",
  icon = "Interface\\Icons\\INV_Misc_Gear_03",
  onClick = function()
    if AzerothCompanion.SettingsHost and AzerothCompanion.SettingsHost.Open then
      AzerothCompanion.SettingsHost:Open()
    end
  end,
})

--- 在 ADDON_LOADED 末尾调用：为每个设置模块、冒险手册、关于页注册悬停项模板（供玩家勾选加入菜单）。
function AzerothCompanion.Modules.MinimapButton.RegisterBuiltinFlyoutCatalog()
  if AzerothCompanion.Modules.MinimapButton._builtinFlyoutCatalogDone then
    return
  end
  AzerothCompanion.Modules.MinimapButton._builtinFlyoutCatalogDone = true
  if AzerothCompanion.ModuleRegistry and AzerothCompanion.ModuleRegistry.GetSorted then
    for _, m in ipairs(AzerothCompanion.ModuleRegistry:GetSorted()) do
      if m.RegisterSettings and m.id then
        local mid = m.id
        AzerothCompanion.Modules.MinimapButton.RegisterFlyoutEntry({
          id = "ac_mod_" .. mid,
          order = 50,
          titleKey = m.nameKey,
          tooltipKey = "MINIMAP_FLYOUT_OPEN_MODULE_TOOLTIP",
          icon = "Interface\\Icons\\Trade_Engineering",
          onClick = function()
            if AzerothCompanion.SettingsHost and AzerothCompanion.SettingsHost.OpenToModulePage then
              AzerothCompanion.SettingsHost:OpenToModulePage(mid)
            end
          end,
        })
      end
    end
  end
  AzerothCompanion.Modules.MinimapButton.RegisterFlyoutEntry({
    id = "ac_flyout_ej",
    order = 22,
    titleKey = "MINIMAP_FLYOUT_ADVENTURE_JOURNAL",
    tooltipKey = "MINIMAP_FLYOUT_ADVENTURE_JOURNAL_TOOLTIP",
    iconAtlas = ATLAS_ADVENTURE_GUIDE_ICON,
    augmentTooltip = function()
      local loc = AzerothCompanion.Localization.Strings or {}
      local sectionTitle = loc.MINIMAP_FLYOUT_ADVENTURE_JOURNAL_LOCKOUTS_TITLE or "Current lockouts"
      local emptyText = loc.MINIMAP_FLYOUT_ADVENTURE_JOURNAL_LOCKOUTS_EMPTY or "No saved instance lockouts."
      local moreFmt = loc.MINIMAP_FLYOUT_ADVENTURE_JOURNAL_LOCKOUTS_MORE_FMT or "+%d more..."

      GameTooltip:AddLine(" ")
      GameTooltip:AddLine(sectionTitle, 1, 0.82, 0.2)

      if not AzerothCompanion.API.EncounterJournal or type(AzerothCompanion.API.EncounterJournal.BuildSavedInstanceLockoutTooltipLines) ~= "function" then
        GameTooltip:AddLine(emptyText, 0.75, 0.75, 0.75, true)
        return
      end

      local lines, overflow = AzerothCompanion.API.EncounterJournal.BuildSavedInstanceLockoutTooltipLines(8)
      if type(lines) ~= "table" or #lines == 0 then
        GameTooltip:AddLine(emptyText, 0.75, 0.75, 0.75, true)
        return
      end

      for _, line in ipairs(lines) do
        GameTooltip:AddLine(line, 0.82, 0.88, 1, true)
      end
      if type(overflow) == "number" and overflow > 0 then
        GameTooltip:AddLine(string.format(moreFmt, overflow), 0.6, 0.6, 0.6, true)
      end
    end,
    onClick = function()
      pcall(function()
        local ejName = "Blizzard_EncounterJournal"
        if C_AddOns and C_AddOns.LoadAddOn then
          pcall(C_AddOns.LoadAddOn, ejName)
        elseif LoadAddOn then
          LoadAddOn(ejName)
        end
        if ToggleEncounterJournal then
          ToggleEncounterJournal()
        end
      end)
    end,
  })
  AzerothCompanion.Modules.MinimapButton.RegisterFlyoutEntry({
    id = "ac_flyout_quest",
    order = 23,
    titleKey = "MINIMAP_FLYOUT_QUEST",
    tooltipKey = "MINIMAP_FLYOUT_QUEST_TOOLTIP",
    icon = "Interface\\Icons\\INV_Misc_Book_09",
    onClick = function()
      if AzerothCompanion.Modules.Quest and type(AzerothCompanion.Modules.Quest.OpenMainFrame) == "function" then
        AzerothCompanion.Modules.Quest.OpenMainFrame()
        return
      end
      if AzerothCompanion.SettingsHost and type(AzerothCompanion.SettingsHost.OpenToModulePage) == "function" then
        AzerothCompanion.SettingsHost:OpenToModulePage("quest")
      end
    end,
  })
  AzerothCompanion.Modules.MinimapButton.RegisterFlyoutEntry({
    id = "ac_flyout_about",
    order = 24,
    titleKey = "MINIMAP_FLYOUT_ABOUT",
    tooltipKey = "MINIMAP_FLYOUT_ABOUT_TOOLTIP",
    icon = "Interface\\Icons\\INV_Misc_QuestionMark",
    onClick = function()
      if AzerothCompanion.SettingsHost and AzerothCompanion.SettingsHost.OpenToAbout then
        AzerothCompanion.SettingsHost:OpenToAbout()
      end
    end,
  })
end
