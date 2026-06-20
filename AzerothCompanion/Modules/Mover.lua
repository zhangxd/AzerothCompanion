--[[
  模块 mover：窗口拖动与位置记忆（MOVER_* 数字设置 ID）。
  - 本插件自建 Frame：AzerothCompanion.Modules.Mover.RegisterFrame（`opts.dragRegion` 优先；否则 `dragHitMode`：仅根或栈底空白层）。
  - 暴雪顶层：拖动条解析（resolveBlizzardDragRegion）；`dragHitMode` 为标题栏 + 空白时另挂栈底全窗层；自 UIPanel 管线 detach/reattach（ignoreFramePositionManager、
    UIPanelWindows、UISpecialFrames、UIPanelLayout）；位移用手动 SetPoint 非 StartMoving；ShowUIPanel/HideUIPanel
    与 OnShow 重挂；多面板打开后经 C_Timer 合并补正存档位置（见文内说明，主路径仍为 hook）。
  - ContainerFrameCombinedBags（组合背包）：不经 ShowUIPanel，通过 PANEL_KEYS + OnShow hook 补挂；
    顶部创建 20px 透明拖动手柄（__azerothCompanion_mm_baghandle），随 mover 模块开关，无独立设置项。
  - 存档：MOVER_FRAMES 数字设置 ID 下的 `frames[全局名]`（TOPLEFT 相对 UIParent 为主）；暴雪顶层仅 `PANEL_KEYS` 内置名单。
]]

AzerothCompanion.Modules.Mover = AzerothCompanion.Modules.Mover or {}

local MODULE_ID = "mover"
local ACCOUNT_SCOPE = "account" -- 账号级设置 scope

--- 读取 mover 账号级设置。
---@param settingName string SettingId 字段名
---@param fallbackValue any 兜底值
---@return any
local function getMoverSetting(settingName, fallbackValue)
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

--- 写入 mover 账号级设置。
---@param settingName string SettingId 字段名
---@param settingValue any 设置值
local function setMoverSetting(settingName, settingValue)
  local settingId = AzerothCompanion.Config.SettingId[settingName] -- 数字设置 ID
  AzerothCompanion.Config.Set(settingId, ACCOUNT_SCOPE, settingValue)
end

--- 读取窗口位置表；调用方修改后必须写回。
---@return table
local function getMoverFrames()
  local moverFrames = getMoverSetting("MOVER_FRAMES", {}) -- 窗口位置表
  return type(moverFrames) == "table" and moverFrames or {}
end

--- 写回窗口位置表。
---@param moverFrames table 窗口位置表
local function setMoverFrames(moverFrames)
  setMoverSetting("MOVER_FRAMES", type(moverFrames) == "table" and moverFrames or {})
end

--- 判断 mover 模块是否启用。
---@return boolean
local function isMoverEnabled()
  return getMoverSetting("MOVER_ENABLED", true) ~= false
end

--- 恢复 mover 模块默认设置。
local function resetMoverSettings()
  local settingId = AzerothCompanion.Config.SettingId -- 数字设置 ID 表
  AzerothCompanion.Config.Reset(settingId.MOVER_ENABLED, ACCOUNT_SCOPE)
  AzerothCompanion.Config.Reset(settingId.MOVER_DEBUG, ACCOUNT_SCOPE)
  AzerothCompanion.Config.Reset(settingId.MOVER_FRAMES, ACCOUNT_SCOPE)
  AzerothCompanion.Config.Reset(settingId.MOVER_DRAG_HIT_MODE, ACCOUNT_SCOPE)
  AzerothCompanion.Config.Reset(settingId.MOVER_ALLOW_DRAG_IN_COMBAT, ACCOUNT_SCOPE)
end

local function isDebugEnabled()
  return getMoverSetting("MOVER_DEBUG", false) == true
end

local function debugPrint(message)
  if not isDebugEnabled() or not message or message == "" then
    return
  end
  AzerothCompanion.API.Chat.PrintAddonMessage(message)
end

--- 是否启用「暴雪面板」拖动（与 `RegisterFrame` 一致，仅受模块总开关 `enabled` 控制）。
local function blizzardDragEnabled()
  return isMoverEnabled()
end

--- 命中模式：`titlebar` 仅标题/解析条；`titlebar_and_empty` 另加栈底全窗层以接住空白像素。
local HIT_DISABLED = "disabled" -- 设置页关闭拖动的哨兵值
local HIT_TITLEBAR = "titlebar" -- 仅标题栏命中
local HIT_TITLEBAR_EMPTY = "titlebar_and_empty" -- 标题栏与窗口空白处命中

--- 将存档命中模式归一到当前支持的取值。
---@param mode any 存档中的命中模式
---@return string normalizedMode 当前支持的命中模式
local function normalizeDragHitMode(mode)
  if mode == HIT_TITLEBAR_EMPTY then
    return HIT_TITLEBAR_EMPTY
  end
  return HIT_TITLEBAR
end

--- 自建窗 `RegisterFrame` 登记项，供命中模式变更时重绑。
local addonDragRegistry = {}

--- 战斗中是否应阻止开始拖动（读 `allowDragInCombat`）。
---@return boolean 为 true 时应阻止
local function shouldBlockDragDueToCombat()
  if getMoverSetting("MOVER_ALLOW_DRAG_IN_COMBAT", false) == true then
    return false
  end
  return InCombatLockdown()
end

--- 卸下单个 Region 上的拖动脚本。
---@param region Frame|nil
local function stripDragSurface(region)
  if not region then
    return
  end
  pcall(function()
    if region.RegisterForDrag then
      region:RegisterForDrag()
    end
  end)
  region:SetScript("OnDragStart", nil)
  region:SetScript("OnDragStop", nil)
end

---@param opts table|nil
---@return table
local function copyRegisterFrameOpts(opts)
  if type(opts) ~= "table" then
    return {}
  end
  return { dragRegion = opts.dragRegion }
end

---@param frame Frame
local function removeAddonRegistryEntry(frame)
  for i = #addonDragRegistry, 1, -1 do
    if addonDragRegistry[i].frame == frame then
      table.remove(addonDragRegistry, i)
    end
  end
end

---@param frame Frame
---@param key string
---@param opts table|nil
local function pushAddonRegistry(frame, key, opts)
  removeAddonRegistryEntry(frame)
  addonDragRegistry[#addonDragRegistry + 1] = {
    frame = frame,
    key = key,
    opts = copyRegisterFrameOpts(opts),
  }
end

local function saveFrameAddon(frame, key)
  local moverFrames = getMoverFrames() -- 窗口位置表
  local point, _, rel, x, y = frame:GetPoint()
  moverFrames[key] = { point = point, rel = rel or "CENTER", x = x, y = y }
  setMoverFrames(moverFrames)
  local localeTable = AzerothCompanion.Localization.Strings or {}
  debugPrint(string.format(
    localeTable.MOVER_DEBUG_SAVE_FMT or "%s",
    tostring(key),
    tostring(point),
    tostring(rel or "CENTER"),
    tostring(x or 0),
    tostring(y or 0)
  ))
end

local function restoreFrameAddon(frame, key)
  local moverFrames = getMoverFrames() -- 窗口位置表
  local saved = moverFrames[key] -- 当前窗口存档
  if not saved then
    return
  end
  frame:ClearAllPoints()
  frame:SetPoint(saved.point, UIParent, saved.rel or "CENTER", saved.x, saved.y)
  local localeTable = AzerothCompanion.Localization.Strings or {}
  debugPrint(string.format(
    localeTable.MOVER_DEBUG_RESTORE_FMT or "%s",
    tostring(key),
    tostring(saved.point),
    tostring(saved.rel or "CENTER"),
    tostring(saved.x or 0),
    tostring(saved.y or 0)
  ))
end

--- 对单框应用 `RegisterFrame` 拖动：`opts.dragRegion` 有则仅用该区域；否则按 `dragHitMode`。
---@param frame Frame
---@param key string
---@param opts table|nil
local function applyAddonFrameDrag(frame, key, opts)
  opts = opts or {}
  if not isMoverEnabled() then
    return
  end
  stripDragSurface(opts.dragRegion)
  stripDragSurface(frame)
  stripDragSurface(frame.__azerothCompanion_mm_draglayer)
  restoreFrameAddon(frame, key)
  frame:SetMovable(true)
  frame:SetUserPlaced(true)
  frame:SetClampedToScreen(true)
  if opts.dragRegion then
    if frame.__azerothCompanion_mm_draglayer then
      pcall(function()
        frame.__azerothCompanion_mm_draglayer:Hide()
      end)
    end
    local drag = opts.dragRegion
    pcall(function()
      drag:EnableMouse(true)
    end)
    drag:RegisterForDrag("LeftButton")
    drag:SetScript("OnDragStart", function()
      if shouldBlockDragDueToCombat() then
        return
      end
      frame:StartMoving()
    end)
    drag:SetScript("OnDragStop", function()
      frame:StopMovingOrSizing()
      saveFrameAddon(frame, key)
    end)
    local localeTable = AzerothCompanion.Localization.Strings or {}
    debugPrint(string.format(localeTable.MOVER_DEBUG_REGISTER_FMT or "%s", tostring(key)))
    return
  end
  local mode = normalizeDragHitMode(getMoverSetting("MOVER_DRAG_HIT_MODE", HIT_TITLEBAR))
  if mode == HIT_TITLEBAR_EMPTY then
    local layer = frame.__azerothCompanion_mm_draglayer
    if not layer then
      layer = CreateFrame("Frame", nil, frame)
      frame.__azerothCompanion_mm_draglayer = layer
    end
    layer:SetAllPoints(frame)
    layer:Show()
    pcall(function()
      layer:Lower()
    end)
    pcall(function()
      layer:EnableMouse(true)
    end)
    layer:RegisterForDrag("LeftButton")
    layer:SetScript("OnDragStart", function()
      if shouldBlockDragDueToCombat() then
        return
      end
      frame:StartMoving()
    end)
    layer:SetScript("OnDragStop", function()
      frame:StopMovingOrSizing()
      saveFrameAddon(frame, key)
    end)
  else
    if frame.__azerothCompanion_mm_draglayer then
      pcall(function()
        frame.__azerothCompanion_mm_draglayer:Hide()
      end)
    end
    local drag = frame
    pcall(function()
      drag:EnableMouse(true)
    end)
    drag:RegisterForDrag("LeftButton")
    drag:SetScript("OnDragStart", function()
      if shouldBlockDragDueToCombat() then
        return
      end
      frame:StartMoving()
    end)
    drag:SetScript("OnDragStop", function()
      frame:StopMovingOrSizing()
      saveFrameAddon(frame, key)
    end)
  end
  local localeTable = AzerothCompanion.Localization.Strings or {}
  debugPrint(string.format(localeTable.MOVER_DEBUG_REGISTER_FMT or "%s", tostring(key)))
end

--- 仅重绑自建登记窗（不跑暴雪 hook）。
local function refreshAddonRegisteredFramesOnly()
  for i = 1, #addonDragRegistry do
    local e = addonDragRegistry[i]
    if e.frame and e.key then
      pcall(function()
        applyAddonFrameDrag(e.frame, e.key, e.opts)
      end)
    end
  end
end

--- 关闭单个 RegisterFrame 自定义窗体的拖动行为（不影响其业务逻辑）。
---@param frame Frame
---@param opts table|nil
local function disableAddonFrameDrag(frame, opts)
  if not frame then
    return
  end
  opts = opts or {}
  stripDragSurface(opts.dragRegion)
  stripDragSurface(frame)
  stripDragSurface(frame.__azerothCompanion_mm_draglayer)
  if frame.__azerothCompanion_mm_draglayer then
    pcall(function()
      frame.__azerothCompanion_mm_draglayer:Hide()
    end)
  end
end

--- 关闭所有 RegisterFrame 已登记窗体的拖动行为（用于模块禁用态）。
local function disableAddonRegisteredFrames()
  for i = 1, #addonDragRegistry do
    local e = addonDragRegistry[i]
    if e and e.frame then
      pcall(function()
        disableAddonFrameDrag(e.frame, e.opts)
      end)
    end
  end
end

--- 为本插件自建框体启用拖动与位置记忆；战斗中是否可拖由 `allowDragInCombat` 与 `shouldBlockDragDueToCombat` 决定。
---@param frame Frame 目标框体
---@param key string 存档键
---@param opts table|nil 可选；`dragRegion` 为仅作为拖动命中区的子 Region（指定时忽略命中模式）
function AzerothCompanion.Modules.Mover.RegisterFrame(frame, key, opts)
  opts = opts or {}
  pushAddonRegistry(frame, key, opts)
  if not isMoverEnabled() then
    disableAddonFrameDrag(frame, opts)
    return
  end
  applyAddonFrameDrag(frame, key, opts)
end

--[[
  暴雪窗口拖动 · 原理（对齐 MoveAnything 等对 UIPanel 的处理）

  1) 移动谁：在「要记忆位置的根 Frame」上改锚点（全局名 = 存档键，如 CharacterFrame）。子 Frame 单独拖无法带动整块。

  2) 从哪拖：RegisterForDrag 挂在命中区（见 resolveBlizzardDragRegion）。

  3) 与面板管线：UIPanelWindows / UIPARENT_MANAGED_FRAME_POSITIONS 会驱动 FramePositionManager 每帧重锚，
     仅用 StartMoving 常被立刻抵消。故在 apply 时 detach（ignoreFramePositionManager、暂移出 UIPanelWindows、
     UISpecialFrames、UIPanelLayout-enabled），disable 时 reattach；位移用光标 delta + SetPoint(TOPLEFT)，
     与 MoveAnything 存盘思路一致。

  4) 入口：ShowUIPanel、HideUIPanel 与 OnShow；
     Show/Hide 后对已可见窗口做「位置与存档比对」补正；C_Timer.After(0) 仅下一帧合并执行（AGENTS：非等布局主路径），
     0.06s 为同次打开流程内可能分帧重锚的二次补正。

  5) 生命周期：HookScript(OnShow) 重挂；受保护界面见 BLIZZARD_DRAG_DENY；恢复接管的高风险宿主在注册表中标记 forceTitlebarOnly。
]]

local WORLD_MAP_PANEL_KEY = "WorldMapFrame" -- 世界地图根框体全局名
local GUILD_PANEL_KEY = "CommunitiesFrame" -- 公会 / 社区根框体全局名
local SETTINGS_PANEL_KEY = "SettingsPanel" -- 系统选项根框体全局名
local GUILD_RELATED_PANEL_KEYS = { GUILD_PANEL_KEY } -- 公会子面板打开后需要补回的主窗口

-- 常见顶层名（补丁变更时请对照 /fstack）；当前只允许显式 registry 中的面板进入拖动接管。
-- `forceTitlebarOnly` 表示即使玩家选择“标题栏 + 空白区域”，该窗口仍只绑定顶部手柄，避免遮挡物品、金币、订单等交互区。
-- `relatedPositionKeys` 表示该面板打开 / 重排时，需同步恢复的 no-detach 关联主窗位置。
local BLIZZARD_PANEL_REGISTRY = {
  { key = "CharacterFrame", forceTitlebarOnly = true },
  { key = "SpellBookFrame", forceTitlebarOnly = true },
  { key = "ClassTalentFrame", forceTitlebarOnly = true },
  { key = "PlayerSpellsFrame", forceTitlebarOnly = true },
  { key = "AchievementFrame", forceTitlebarOnly = true },
  { key = "QuestFrame", forceTitlebarOnly = true, storageKey = "QuestFrame" },
  { key = "GossipFrame", forceTitlebarOnly = true, storageKey = "QuestFrame" },
  { key = "ObjectiveTrackerFrame", forceTitlebarOnly = true },
  { key = "CollectionsJournal", forceTitlebarOnly = true },
  { key = "PVEFrame", forceTitlebarOnly = true },
  { key = "EncounterJournal", forceTitlebarOnly = true },
  { key = "MerchantFrame", forceTitlebarOnly = true },
  -- 组合背包：不经 ShowUIPanel，通过 OnShow hook 补挂；拖动条为顶部透明手柄（见 resolveBlizzardDragRegion）。
  { key = "ContainerFrameCombinedBags", forceTitlebarOnly = true },
  -- 常用 Blizzard 内置窗口：对齐 BlizzMove 类显式注册表，默认强制标题栏拖动。
  { key = "ProfessionsFrame", forceTitlebarOnly = true, restoreMethods = { "SetTab", "ApplyDesiredWidth" } },
  { key = "ProfessionsBookFrame", forceTitlebarOnly = true },
  { key = "ProfessionsCustomerOrdersFrame", forceTitlebarOnly = true, restoreMethods = { "SetDisplayMode" } },
  { key = "InspectRecipeFrame", forceTitlebarOnly = true },
  { key = "ArchaeologyFrame", forceTitlebarOnly = true },
  { key = "MailFrame", forceTitlebarOnly = true },
  { key = "OpenMailFrame", forceTitlebarOnly = true },
  { key = "BankFrame", forceTitlebarOnly = true, restoreMethods = { "SetTab", "UpdateWidthForSelectedTab" } },
  { key = "AuctionHouseFrame", forceTitlebarOnly = true, restoreMethods = { "SetDisplayMode" } },
  { key = "DressUpFrame", forceTitlebarOnly = true },
  { key = "FriendsFrame", forceTitlebarOnly = true },
  { key = "AddonList", forceTitlebarOnly = true },
  { key = "CalendarFrame", forceTitlebarOnly = true },
  { key = "ChannelFrame", forceTitlebarOnly = true },
  { key = "ChatConfigFrame", forceTitlebarOnly = true },
  { key = "ClickBindingFrame", forceTitlebarOnly = true },
  { key = "MacroFrame", forceTitlebarOnly = true },
  { key = "TokenFrame", forceTitlebarOnly = true },
  { key = "CurrencyTransferMenu", forceTitlebarOnly = true },
  { key = "InspectFrame", forceTitlebarOnly = true },
  { key = "GuildBankFrame", forceTitlebarOnly = true },
  { key = "GuildControlUI", forceTitlebarOnly = true, topHandleProfile = "compactTitle", relatedPositionKeys = GUILD_RELATED_PANEL_KEYS },
  { key = "GuildRenameFrame", forceTitlebarOnly = true },
  { key = "CommunitiesGuildLogFrame", forceTitlebarOnly = true, topHandleProfile = "compactTitle", relatedPositionKeys = GUILD_RELATED_PANEL_KEYS },
  { key = "CommunitiesGuildTextEditFrame", forceTitlebarOnly = true, topHandleProfile = "compactTitle", relatedPositionKeys = GUILD_RELATED_PANEL_KEYS },
  { key = "CommunitiesGuildNewsFiltersFrame", forceTitlebarOnly = true, topHandleProfile = "compactTitle", relatedPositionKeys = GUILD_RELATED_PANEL_KEYS },
  { key = "ClubFinderGuildRecruitmentDialog", forceTitlebarOnly = true, relatedPositionKeys = GUILD_RELATED_PANEL_KEYS },
  { key = "ClassTrainerFrame", forceTitlebarOnly = true },
  { key = "FlightMapFrame", forceTitlebarOnly = true },
  { key = "AdventureMapFrame", forceTitlebarOnly = true },
  { key = "BlackMarketFrame", forceTitlebarOnly = true },
  { key = "ItemUpgradeFrame", forceTitlebarOnly = true },
  { key = "ItemSocketingFrame", forceTitlebarOnly = true },
  { key = "ItemInteractionFrame", forceTitlebarOnly = true },
  { key = "WeeklyRewardsFrame", forceTitlebarOnly = true },
  { key = "StableFrame", forceTitlebarOnly = true },
  { key = "TransmogFrame", forceTitlebarOnly = true },
  { key = "GenericTraitFrame", forceTitlebarOnly = true },
  { key = "GuideFrame", forceTitlebarOnly = true },
  { key = "QuestLogPopupDetailFrame", forceTitlebarOnly = true },
  { key = "PVPUIFrame", forceTitlebarOnly = true },
  { key = "PVPBannerFrame", forceTitlebarOnly = true },
  { key = "RaidParentFrame", forceTitlebarOnly = true },
  { key = "RaidBrowserFrame", forceTitlebarOnly = true },
  { key = "ItemTextFrame", forceTitlebarOnly = true },
  { key = "LootFrame", forceTitlebarOnly = true },
  { key = "PetitionFrame", forceTitlebarOnly = true },
  { key = "GuildRegistrarFrame", forceTitlebarOnly = true },
  { key = "HelpFrame", forceTitlebarOnly = true },
  { key = "ModelPreviewFrame", forceTitlebarOnly = true },
  { key = "PetStableFrame", forceTitlebarOnly = true },
  { key = "TradeFrame", forceTitlebarOnly = true },
  { key = "TaxiFrame", forceTitlebarOnly = true },
  { key = "TabardFrame", forceTitlebarOnly = true },
  -- 住宅相关 Blizzard_Housing* 顶层；统一走通用顶部手柄，不为住宅逐个写专用拖动函数。
  { key = "HousingDashboardFrame", forceTitlebarOnly = true },
  { key = "HouseFinderFrame", forceTitlebarOnly = true },
  { key = "HousingBulletinBoardFrame", forceTitlebarOnly = true },
  { key = "HousingInviteResidentFrame", forceTitlebarOnly = true },
  { key = "HousingCornerstoneFrame", forceTitlebarOnly = true },
  { key = "HousingCornerstoneHouseInfoFrame", forceTitlebarOnly = true },
  { key = "HousingCornerstonePurchaseFrame", forceTitlebarOnly = true },
  { key = "HousingCornerstoneVisitorFrame", forceTitlebarOnly = true },
  { key = "HousingCreateNeighborhoodCharterFrame", forceTitlebarOnly = true },
  { key = "HousingCreateCharterNeighborhoodConfirmationFrame", forceTitlebarOnly = true },
  { key = "HousingHouseSettingsFrame", forceTitlebarOnly = true },
  { key = "HousingModelPreviewFrame", forceTitlebarOnly = true },
  { key = "HouseListFrame", forceTitlebarOnly = true },
  { key = "HousingCharterFrame", forceTitlebarOnly = true },
  { key = "HousingCreateGuildNeighborhoodFrame", forceTitlebarOnly = true },
  { key = "HousingCharterRequestSignatureDialog", forceTitlebarOnly = true },
  { key = "NeighborhoodChangeNameDialog", forceTitlebarOnly = true },
  { key = "ImportHouseConfirmationDialog", forceTitlebarOnly = true },
  { key = "MoveHouseConfirmationDialog", forceTitlebarOnly = true },
  { key = "BuyHouseConfirmationDialog", forceTitlebarOnly = true },
  { key = "AbandonHouseConfirmationDialog", forceTitlebarOnly = true },
  -- 资料片 / 旧版本场景窗口：仍使用统一顶部手柄，不为每个资料片写专用拖动函数。
  { key = "DelvesCompanionAbilityListFrame", forceTitlebarOnly = true },
  { key = "DelvesCompanionConfigurationFrame", forceTitlebarOnly = true },
  { key = "DelvesDifficultyPickerFrame", forceTitlebarOnly = true },
  { key = "CooldownViewerSettings", forceTitlebarOnly = true },
  { key = "ChromieTimeFrame", forceTitlebarOnly = true },
  { key = "ExpansionLandingPage", forceTitlebarOnly = true },
  { key = "PlayerChoiceFrame", forceTitlebarOnly = true },
  { key = "SoulbindViewer", forceTitlebarOnly = true },
  { key = "RuneforgeFrame", forceTitlebarOnly = true },
  { key = "ScrappingMachineFrame", forceTitlebarOnly = true },
  { key = "ObliterumForgeFrame", forceTitlebarOnly = true },
  { key = "GarrisonMissionFrame", forceTitlebarOnly = true },
  { key = "OrderHallMissionFrame", forceTitlebarOnly = true },
  { key = "CovenantMissionFrame", forceTitlebarOnly = true },
}

--- allowlist 与元数据快速查表，供 ShowUIPanel / OnShow / 延迟补正统一使用。
local PANEL_KEYS = {} -- 保持注册表声明顺序
local PANEL_KEY_SET = {} -- 顶层名 allowlist
local PANEL_REGISTRY_BY_KEY = {} -- 顶层名到注册元数据
for _, panelRecord in ipairs(BLIZZARD_PANEL_REGISTRY) do
  local panelKey = panelRecord.key -- Blizzard 顶层全局名
  if type(panelKey) == "string" and panelKey ~= "" then
    PANEL_KEYS[#PANEL_KEYS + 1] = panelKey
    PANEL_KEY_SET[panelKey] = true
    PANEL_REGISTRY_BY_KEY[panelKey] = panelRecord
  end
end

-- 不参与拖动（受保护或容易污染系统交互）。
-- GameMenuFrame：经 ShowUIPanel 打开；若 detach UIPanel 管线会破坏 ESC 菜单与战斗中安全路径，表现为菜单/选项无法操作。
-- SettingsPanel：零售系统「选项」独立顶层（若存在）；同上勿剥离管线。
-- CommunitiesFrame：接受社区邀请 / 票据等路径会调用暴雪限制的 C_Club API，根框体被插件接管后容易触发 Blizzard-only UI 拦截。
local BLIZZARD_DRAG_DENY = {
  StoreFrame = true,
  AccountStoreFrame = true,
  OrderHallTalentFrame = true,
  GameMenuFrame = true,
  SettingsPanel = true,
  WorldMapFrame = true,
  CommunitiesFrame = true,
}

--- 是否跳过 Blizzard 拖动挂接（内置受保护名单：商城、职业大厅天赋、ESC 菜单、系统选项顶层等）。
---@param name string 顶层 Frame 全局名
---@return boolean
local function isBlizzardPanelDragDenied(name)
  if type(name) ~= "string" or name == "" then
    return true
  end
  return BLIZZARD_DRAG_DENY[name] == true
end

--- 当前是否属于允许接管的 Blizzard 根面板。
---@param name string 顶层 Frame 全局名
---@return boolean
local function isTrackedBlizzardPanelName(name)
  return type(name) == "string" and name ~= "" and PANEL_KEY_SET[name] == true
end

--- 仅内置 `PANEL_KEYS`；ShowUIPanel hook 也必须先命中同一 allowlist。
local function getAllPanelKeys()
  return PANEL_KEYS
end

--- 暴雪窗口真实根框体名与位置存档键的映射。
--- GossipFrame 是 NPC 初次对话任务列表，但视觉上属于同一套任务交互窗口，位置与 QuestFrame 共用。
---@param key string 根框体全局名
---@return string storageKey MOVER_FRAMES 中使用的位置键
local function getBlizzardPanelStorageKey(key)
  local panelRecord = PANEL_REGISTRY_BY_KEY[key] -- Blizzard 面板注册元数据
  if type(panelRecord) == "table" and type(panelRecord.storageKey) == "string" then
    return panelRecord.storageKey
  end
  return key
end

local NPC_DIALOG_HANDLE_LEFT = 68 -- NPC 任务窗口顶部拖动区左侧避开头像
local NPC_DIALOG_HANDLE_RIGHT = -44 -- NPC 任务窗口顶部拖动区右侧避开关闭按钮
local NPC_DIALOG_HANDLE_TOP = -4 -- NPC 任务窗口顶部拖动区上边距
local NPC_DIALOG_HANDLE_HEIGHT = 28 -- NPC 任务窗口顶部拖动区高度
local OBJECTIVE_TRACKER_HANDLE_RIGHT = -44 -- 目标追踪顶部拖动区右侧避开折叠 / 过滤按钮
local OBJECTIVE_TRACKER_HANDLE_HEIGHT = 32 -- 目标追踪标题区高度
local TOP_HANDLE_LEFT = 58 -- 通用顶部拖动区左侧避开肖像区域
local TOP_HANDLE_RIGHT = -86 -- 通用顶部拖动区右侧避开关闭 / 最大化按钮
local TOP_HANDLE_TOP = -1 -- 通用顶部拖动区上边距
local TOP_HANDLE_HEIGHT = 24 -- 通用顶部拖动区高度
local CALENDAR_HANDLE_PADDING = 8 -- 日历标题拖动区与翻月按钮之间的安全留白
local CALENDAR_HANDLE_FALLBACK_LEFT = 112 -- 日历按钮未布局时的保守左边界
local CALENDAR_HANDLE_FALLBACK_RIGHT = -148 -- 日历按钮未布局时的保守右边界
local CALENDAR_HANDLE_MIN_WIDTH = 96 -- 日历标题拖动区最小可用宽度
local CALENDAR_PREV_BUTTON_FIELDS = { "PrevMonthButton", "PreviousMonthButton", "PrevButton", "previousMonthButton", "prevMonthButton" } -- 日历左翻月按钮字段候选
local CALENDAR_NEXT_BUTTON_FIELDS = { "NextMonthButton", "NextButton", "nextMonthButton" } -- 日历右翻月按钮字段候选
local CALENDAR_CLOSE_BUTTON_FIELDS = { "CloseButton", "closeButton" } -- 日历关闭按钮字段候选
local CALENDAR_PREV_BUTTON_GLOBALS = { "CalendarFramePrevMonthButton", "CalendarFramePreviousMonthButton", "CalendarPrevMonthButton" } -- 日历左翻月按钮全局候选
local CALENDAR_NEXT_BUTTON_GLOBALS = { "CalendarFrameNextMonthButton", "CalendarNextMonthButton" } -- 日历右翻月按钮全局候选
local CALENDAR_CLOSE_BUTTON_GLOBALS = { "CalendarFrameCloseButton", "CalendarCloseButton" } -- 日历关闭按钮全局候选
local COMPACT_TITLE_HANDLE_LEFT = 18 -- 半透明弹窗标题拖动区左侧
local COMPACT_TITLE_HANDLE_TOP = -10 -- 半透明弹窗标题拖动区上边距
local COMPACT_TITLE_HANDLE_WIDTH = 112 -- 半透明弹窗标题拖动区宽度，避开右侧下拉 / 关闭按钮
local COMPACT_TITLE_HANDLE_HEIGHT = 26 -- 半透明弹窗标题拖动区高度
local WORLD_MAP_RESIZE_HANDLE_SIZE = 32 -- 世界地图右下角改大小手柄尺寸
local WORLD_MAP_RESIZE_HANDLE_OFFSET = 6 -- 世界地图改大小手柄向外偏移
local WORLD_MAP_RESIZE_MARK_THICKNESS = 2 -- 世界地图改大小角标线条粗细
local WORLD_MAP_RESIZE_MARK_INSET = 6 -- 世界地图改大小角标向内留白
local WORLD_MAP_RESIZE_MARK_ALPHA = 0.9 -- 世界地图改大小角标透明度
local WORLD_MAP_RESIZE_MARK_LENGTHS = { 18, 13, 8 } -- 世界地图改大小角标线条长度
local WORLD_MAP_RESIZE_MARK_OFFSETS = { 7, 12, 17 } -- 世界地图改大小角标线条纵向偏移
local WORLD_MAP_MIN_WIDTH = 520 -- 世界地图允许的最小宽度
local WORLD_MAP_MIN_HEIGHT = 360 -- 世界地图允许的最小高度
local WORLD_MAP_RESIZE_EPSILON = 0.5 -- 世界地图尺寸变化小于该值时跳过重复刷新
local WORLD_MAP_SCALE_EPSILON = 0.001 -- 世界地图整体缩放变化小于该值时跳过
local GUILD_PANEL_TAB_KEYS = { -- 会触发布局重排的左侧页签字段名
  "ChatTab",
  "RosterTab",
  "GuildBenefitsTab",
  "GuildInfoTab",
}
local TOP_HANDLE_PROFILES = {
  default = {
    left = TOP_HANDLE_LEFT,
    right = TOP_HANDLE_RIGHT,
    top = TOP_HANDLE_TOP,
    height = TOP_HANDLE_HEIGHT,
  },
  compactTitle = {
    left = COMPACT_TITLE_HANDLE_LEFT,
    top = COMPACT_TITLE_HANDLE_TOP,
    width = COMPACT_TITLE_HANDLE_WIDTH,
    height = COMPACT_TITLE_HANDLE_HEIGHT,
  },
} -- 顶部拖动手柄几何配置

--- 前向声明：Blizzard 页签 / 显示模式切换后需要复用 ShowUIPanel 的位置补正。
local schedulePostShowPanelRestore
local installRegisteredPanelRestoreHooks
local restoreAllVisibleTrackedPanelsIfMisplaced
local scheduleRelatedPanelPositionRestore

--- 读取 Frame 当前尺寸；方法缺失或返回无效时返回 nil。
---@param frame Frame|nil 目标 Frame
---@param methodName string 读取方法名
---@return number|nil dimensionValue 当前尺寸
local function readFrameDimension(frame, methodName)
  if not frame or type(methodName) ~= "string" or type(frame[methodName]) ~= "function" then
    return nil
  end
  local success, rawValue = pcall(function() -- Blizzard Frame 尺寸读取
    return frame[methodName](frame)
  end)
  local dimensionValue = success and tonumber(rawValue) or nil -- 数字化尺寸
  if dimensionValue and dimensionValue > 0 then
    return dimensionValue
  end
  return nil
end

--- 安全读取 Frame 的屏幕左边界。
---@param frame Frame|nil 目标 Frame
---@return number|nil leftValue 左边界
local function readFrameLeft(frame)
  if not frame or type(frame.GetLeft) ~= "function" then
    return nil
  end
  local success, rawValue = pcall(function() -- Blizzard Frame 坐标读取
    return frame:GetLeft()
  end)
  local leftValue = success and tonumber(rawValue) or nil -- 数字化左边界
  return leftValue
end

--- 安全读取 Frame 的屏幕右边界；缺少 GetRight 时用 left + width 推导。
---@param frame Frame|nil 目标 Frame
---@return number|nil rightValue 右边界
local function readFrameRight(frame)
  if not frame then
    return nil
  end
  if type(frame.GetRight) == "function" then
    local success, rawValue = pcall(function() -- Blizzard Frame 右边界读取
      return frame:GetRight()
    end)
    local rightValue = success and tonumber(rawValue) or nil -- 数字化右边界
    if rightValue then
      return rightValue
    end
  end
  local leftValue = readFrameLeft(frame) -- 左边界
  local widthValue = readFrameDimension(frame, "GetWidth") -- 宽度
  if leftValue and widthValue then
    return leftValue + widthValue
  end
  return nil
end

--- 安全读取 Frame 的本体缩放；缺失或异常时按未缩放处理。
---@param frame Frame|nil 目标 Frame
---@return number scaleValue 当前本体缩放
local function readFrameScale(frame)
  if not frame or type(frame.GetScale) ~= "function" then
    return 1
  end
  local success, rawValue = pcall(function() -- Blizzard Frame 缩放读取
    return frame:GetScale()
  end)
  local scaleValue = success and tonumber(rawValue) or nil -- 数字化缩放
  if scaleValue and scaleValue > 0 then
    return scaleValue
  end
  return 1
end

--- 安全读取 Frame 的有效缩放；用于把屏幕光标坐标折算到当前 Frame 的锚点坐标系。
---@param frame Frame|nil 目标 Frame
---@return number scaleValue 当前有效缩放
local function readFrameEffectiveScale(frame)
  if not frame or type(frame.GetEffectiveScale) ~= "function" then
    return 1
  end
  local success, rawValue = pcall(function() -- Blizzard Frame 有效缩放读取
    return frame:GetEffectiveScale()
  end)
  local scaleValue = success and tonumber(rawValue) or nil -- 数字化缩放
  if scaleValue and scaleValue > 0 then
    return scaleValue
  end
  return 1
end

--- 仅在需要时设置世界地图根缩放。
---@param frame Frame|nil 世界地图根框体
---@param scaleValue number 目标缩放
---@return boolean changed 是否实际改变缩放
local function setWorldMapRootScale(frame, scaleValue)
  if not frame or type(frame.SetScale) ~= "function" then
    return false
  end
  local normalizedScale = tonumber(scaleValue) or 1 -- 归一目标缩放
  if normalizedScale <= 0 then
    normalizedScale = 1
  end
  if math.abs(readFrameScale(frame) - normalizedScale) < WORLD_MAP_SCALE_EPSILON then
    return false
  end
  frame:SetScale(normalizedScale)
  return true
end

--- 优先读取当前 TOPLEFT 锚点偏移；缩放后的边界读数不一定适合反推存档锚点。
---@param frame Frame|nil 目标 Frame
---@return number|nil offsetX TOPLEFT 横向偏移
---@return number|nil offsetY TOPLEFT 纵向偏移
local function readTopLeftPointOffset(frame)
  if not frame or type(frame.GetPoint) ~= "function" then
    return nil, nil
  end
  local pointName, relativeFrame, relativePoint, offsetX, offsetY = frame:GetPoint()
  if pointName ~= "TOPLEFT" or relativePoint ~= "TOPLEFT" then
    return nil, nil
  end
  if relativeFrame and relativeFrame ~= UIParent then
    return nil, nil
  end
  return tonumber(offsetX) or 0, tonumber(offsetY) or 0
end

--- 从缩放后的边界读数反推 TOPLEFT 锚点偏移。
---@param frame Frame|nil 目标 Frame
---@return number|nil offsetX TOPLEFT 横向偏移
---@return number|nil offsetY TOPLEFT 纵向偏移
local function readTopLeftOffsetFromBounds(frame)
  if not frame then
    return nil, nil
  end
  local left, top = frame:GetLeft(), frame:GetTop()
  local parentLeft, parentTop = UIParent:GetLeft(), UIParent:GetTop()
  if not left or not top or not parentLeft or not parentTop then
    return nil, nil
  end
  local parentScale = readFrameEffectiveScale(UIParent) -- UIParent 有效缩放
  local targetScale = readFrameEffectiveScale(frame) -- 目标 Frame 有效缩放
  return left - parentLeft * parentScale / targetScale, top - parentTop * parentScale / targetScale
end

--- 重新应用单个地图 pin 的当前归一化位置；地图层级切换后用于修正玩家箭头覆盖层锚点。
---@param pinFrame Frame|nil 地图 pin Frame
local function reapplyWorldMapPinPosition(pinFrame)
  if type(pinFrame) ~= "table" then
    return
  end
  local applyCurrentPosition = pinFrame.ApplyCurrentPosition -- MapCanvasPinMixin 当前坐标重应用方法
  if type(applyCurrentPosition) == "function" then
    pcall(applyCurrentPosition, pinFrame)
    return
  end

  local getPosition = pinFrame.GetPosition -- pin 当前归一化坐标读取方法
  local setPosition = pinFrame.SetPosition -- pin 当前归一化坐标写回方法
  if type(getPosition) ~= "function" or type(setPosition) ~= "function" then
    return
  end
  local success, posX, posY, insetIndex = pcall(getPosition, pinFrame) -- 当前 pin 坐标
  if not success or type(posX) ~= "number" or type(posY) ~= "number" then
    return
  end
  pcall(setPosition, pinFrame, posX, posY, insetIndex)
end

--- 重新应用世界地图所有现有 pin 的位置，不重建地图画布。
---@param frame Frame|nil 世界地图根框体
local function reapplyWorldMapPinPositions(frame)
  local executeOnAllPins = type(frame) == "table" and frame.ExecuteOnAllPins or nil -- MapCanvas pin 枚举入口
  if type(executeOnAllPins) ~= "function" then
    return
  end
  pcall(function()
    frame:ExecuteOnAllPins(reapplyWorldMapPinPosition)
  end)
end

--- 安装世界地图层级切换后的 pin 位置修正；顶部回退父级地图会走 OnMapChanged。
---@param frame Frame|nil 世界地图根框体
local function installWorldMapPinPositionRefreshHook(frame)
  if not frame or frame.__azerothCompanion_mm_pinposition_hooked then
    return
  end
  if type(hooksecurefunc) ~= "function" or type(frame.OnMapChanged) ~= "function" then
    return
  end
  local success = pcall(function()
    hooksecurefunc(frame, "OnMapChanged", function(mapFrame)
      reapplyWorldMapPinPositions(mapFrame or frame)
    end)
  end)
  if success then
    frame.__azerothCompanion_mm_pinposition_hooked = true
  end
end

--- 读取世界地图视觉尺寸；逻辑宽高保持 Blizzard 原生值，视觉尺寸由整体 scale 得到。
---@param frame Frame|nil 世界地图根框体
---@return number|nil visualWidth 世界地图视觉宽度
---@return number|nil visualHeight 世界地图视觉高度
local function readWorldMapVisualSize(frame)
  local baseWidth = readFrameDimension(frame, "GetWidth") -- Blizzard 原生逻辑宽度
  local baseHeight = readFrameDimension(frame, "GetHeight") -- Blizzard 原生逻辑高度
  if not baseWidth or not baseHeight then
    return nil, nil
  end
  local scaleValue = readFrameScale(frame) -- 当前整体缩放
  return baseWidth * scaleValue, baseHeight * scaleValue
end

--- 把待恢复的世界地图视觉尺寸折算为整体 scale。
--- 不改 `WorldMapFrame:SetSize()`：MapCanvas 的贴图、迷雾和区域层依赖原生画布尺寸。
---@param frame Frame|nil 世界地图根框体
---@param widthValue number 待恢复视觉宽度
---@param heightValue number 待恢复视觉高度
---@return number scaleValue 归一后的整体缩放
local function calculateWorldMapScaleFromVisualSize(frame, widthValue, heightValue)
  local baseWidth = readFrameDimension(frame, "GetWidth") or widthValue -- Blizzard 原生逻辑宽度
  local baseHeight = readFrameDimension(frame, "GetHeight") or heightValue -- Blizzard 原生逻辑高度
  if baseWidth <= 0 or baseHeight <= 0 then
    return 1
  end
  local widthScale = widthValue / baseWidth -- 视觉宽度对应缩放
  local heightScale = heightValue / baseHeight -- 视觉高度对应缩放
  local scaleValue = widthScale -- 最终整体缩放
  local widthBasedHeight = baseHeight * widthScale -- 保留宽度时的视觉高度
  local heightBasedWidth = baseWidth * heightScale -- 保留高度时的视觉宽度
  if math.abs(heightBasedWidth - widthValue) < math.abs(widthBasedHeight - heightValue) then
    scaleValue = heightScale
  end
  local minScale = math.max(WORLD_MAP_MIN_WIDTH / baseWidth, WORLD_MAP_MIN_HEIGHT / baseHeight) -- 最小允许缩放
  if scaleValue < minScale then
    scaleValue = minScale
  end
  return scaleValue
end

--- 对世界地图存档记录补充当前尺寸。
---@param frame Frame|nil 世界地图根框体
---@param key string 存档键
---@param savedRecord table|nil 当前存档记录
local function addWorldMapSizeToSavedRecord(frame, key, savedRecord)
  if key ~= WORLD_MAP_PANEL_KEY or type(savedRecord) ~= "table" then
    return
  end
  local widthValue, heightValue = readWorldMapVisualSize(frame) -- 当前世界地图视觉尺寸
  if widthValue and heightValue then
    savedRecord.width = widthValue
    savedRecord.height = heightValue
  end
end

--- 从存档恢复世界地图视觉尺寸；位置恢复仍由通用 Blizzard 面板路径处理。
---@param frame Frame|nil 世界地图根框体
---@param key string 存档键
---@param savedRecord table|nil 当前存档记录
local function restoreWorldMapSizeFromSavedRecord(frame, key, savedRecord)
  if key ~= WORLD_MAP_PANEL_KEY or not frame or type(savedRecord) ~= "table" or type(frame.SetScale) ~= "function" then
    return
  end
  local widthValue = tonumber(savedRecord.width) -- 存档视觉宽度
  local heightValue = tonumber(savedRecord.height) -- 存档视觉高度
  if widthValue and heightValue and widthValue > 0 and heightValue > 0 then
    local scaleValue = calculateWorldMapScaleFromVisualSize(frame, widthValue, heightValue) -- 归一整体缩放
    setWorldMapRootScale(frame, scaleValue)
  end
end

--- 按拖动起点宽高比计算世界地图下一帧视觉尺寸与整体 scale。
---@param resizeState table 当前改大小状态
---@param deltaX number 鼠标横向位移
---@param deltaY number 鼠标向下位移
---@return number nextWidth 新视觉宽度
---@return number nextHeight 新视觉高度
---@return number nextScale 新整体缩放
local function calculateWorldMapResizeSize(resizeState, deltaX, deltaY)
  local aspectRatio = resizeState.aspectRatio or resizeState.startVisualWidth / resizeState.startVisualHeight -- 起点视觉宽高比
  local widthDrivenHeightDelta = deltaX / aspectRatio -- 横向位移折算出的视觉高度位移
  local heightDelta = deltaY -- 最终高度位移
  if math.abs(widthDrivenHeightDelta) >= math.abs(deltaY) then
    heightDelta = widthDrivenHeightDelta
  end
  local nextHeight = resizeState.startVisualHeight + heightDelta -- 按比例得到的新视觉高度
  local nextWidth = resizeState.startVisualWidth + heightDelta * aspectRatio -- 按比例得到的新视觉宽度
  local minScale = math.max(WORLD_MAP_MIN_WIDTH / resizeState.baseWidth, WORLD_MAP_MIN_HEIGHT / resizeState.baseHeight) -- 最小允许缩放
  local nextScale = nextHeight / resizeState.baseHeight -- 当前整体缩放
  if nextScale < minScale then
    nextScale = minScale
    nextWidth = resizeState.baseWidth * nextScale
    nextHeight = resizeState.baseHeight * nextScale
  end
  return nextWidth, nextHeight, nextScale
end

local function saveAsTopLeft(frame, key, moverFrames)
  local originX, originY = readTopLeftPointOffset(frame) -- 当前 TOPLEFT 锚点偏移
  if not originX or not originY then
    originX, originY = readTopLeftOffsetFromBounds(frame)
    if not originX or not originY then
      return false
    end
  end
  moverFrames[key] = {
    point = "TOPLEFT",
    rel = "TOPLEFT",
    x = originX,
    y = originY,
  }
  addWorldMapSizeToSavedRecord(frame, key, moverFrames[key])
  return true
end

local function migrateSavedToTopLeft(frame, key, s)
  if not s or s.point == "TOPLEFT" and (s.rel == "TOPLEFT" or s.rel == nil) then
    return s
  end
  frame:ClearAllPoints()
  frame:SetPoint(s.point, UIParent, s.rel or "CENTER", s.x, s.y)
  local moverFrames = getMoverFrames() -- 窗口位置表
  if saveAsTopLeft(frame, key, moverFrames) then
    setMoverFrames(moverFrames)
    return moverFrames[key]
  end
  return s
end

--- 修复旧版在世界地图缩放后用边界坐标写坏的 TOPLEFT y。
---@param frame Frame|nil 世界地图根框体
---@param key string 存档键
---@param savedRecord table|nil 当前存档记录
---@return boolean repaired 是否修复
local function repairLegacyWorldMapSavedPosition(frame, key, savedRecord)
  if key ~= WORLD_MAP_PANEL_KEY or not frame or type(savedRecord) ~= "table" then
    return false
  end
  if savedRecord.point ~= "TOPLEFT" or savedRecord.rel and savedRecord.rel ~= "TOPLEFT" then
    return false
  end
  local savedY = tonumber(savedRecord.y) -- 当前存档 y
  local widthValue = tonumber(savedRecord.width) -- 当前存档视觉宽度
  local heightValue = tonumber(savedRecord.height) -- 当前存档视觉高度
  local parentTop = UIParent:GetTop() -- UIParent 顶部
  local baseHeight = readFrameDimension(frame, "GetHeight") -- Blizzard 原生逻辑高度
  if not savedY or not widthValue or not heightValue or not parentTop or not baseHeight then
    return false
  end
  local scaleValue = calculateWorldMapScaleFromVisualSize(frame, widthValue, heightValue) -- 存档视觉尺寸对应缩放
  if scaleValue <= 1 + WORLD_MAP_SCALE_EPSILON then
    return false
  end
  local bottomValue = parentTop + savedY * scaleValue - baseHeight * scaleValue -- 当前存档会恢复出的底边
  if bottomValue >= 0 then
    return false
  end
  local repairedY = savedY + parentTop * (1 - 1 / scaleValue) -- 旧版边界坐标反算回锚点偏移
  local repairedBottom = parentTop + repairedY * scaleValue - baseHeight * scaleValue -- 修复后的底边
  if repairedBottom < 0 then
    repairedY = math.max(baseHeight - parentTop / scaleValue, repairedY)
  end
  local roundedY = math.floor(repairedY + 0.5) -- 接近整数时清理浮点误差
  if math.abs(repairedY - roundedY) < WORLD_MAP_SCALE_EPSILON then
    repairedY = roundedY
  end
  savedRecord.y = repairedY
  return true
end

local function saveBlizzardPanel(frame, key)
  local moverFrames = getMoverFrames() -- 窗口位置表
  if saveAsTopLeft(frame, key, moverFrames) then
    setMoverFrames(moverFrames)
    local saved = moverFrames[key] -- 当前窗口存档
    local localeTable = AzerothCompanion.Localization.Strings or {}
    debugPrint(string.format(
      localeTable.MICROMENU_DEBUG_SAVE_FMT or "%s",
      tostring(key),
      tostring(saved and saved.x or 0),
      tostring(saved and saved.y or 0)
    ))
    return
  end
  local p, _, rel, x, y = frame:GetPoint()
  moverFrames[key] = { point = p, rel = rel or "CENTER", x = x, y = y }
  addWorldMapSizeToSavedRecord(frame, key, moverFrames[key])
  setMoverFrames(moverFrames)
end

local function restoreBlizzardPanel(frame, key)
  local moverFrames = getMoverFrames() -- 窗口位置表
  local s = moverFrames[key] -- 当前窗口存档
  if not s then
    return
  end
  s = migrateSavedToTopLeft(frame, key, s)
  if repairLegacyWorldMapSavedPosition(frame, key, s) then
    moverFrames[key] = s
    setMoverFrames(moverFrames)
  end
  frame:ClearAllPoints()
  if s.point == "TOPLEFT" then
    frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", s.x, s.y)
  else
    frame:SetPoint(s.point, UIParent, s.rel or "CENTER", s.x, s.y)
  end
  restoreWorldMapSizeFromSavedRecord(frame, key, s)
end

local POS_MATCH_EPS = 2
local function positionMatchesSaved(frame, key)
  local moverFrames = getMoverFrames() -- 窗口位置表
  local s = moverFrames[key] -- 当前窗口存档
  if not s then
    return true
  end
  if s.point ~= "TOPLEFT" then
    return false
  end
  local left, top = frame:GetLeft(), frame:GetTop()
  local ul, ut = UIParent:GetLeft(), UIParent:GetTop()
  if not left or not top or not ul or not ut then
    return false
  end
  if math.abs((left - ul) - s.x) >= POS_MATCH_EPS then
    return false
  end
  if math.abs((top - ut) - s.y) >= POS_MATCH_EPS then
    return false
  end
  return true
end

local function restoreBlizzardPanelIfMisplaced(frame, key)
  local storageKey = getBlizzardPanelStorageKey(key) -- 位置存档键
  if isBlizzardPanelDragDenied(key) then
    return
  end
  if not isMoverEnabled() or not frame or not frame:IsShown() or not frame.__azerothCompanion_mm_inited then
    return
  end
  if positionMatchesSaved(frame, storageKey) then
    return
  end
  restoreBlizzardPanel(frame, storageKey)
end

--- NPC 任务相关窗口继承 ButtonFrameTemplate，但正式服结构中的 TitleContainer 命中不稳定。
--- 使用顶部中间透明手柄，只覆盖标题区域，避免遮挡头像与关闭按钮。
---@param frame Frame
---@return Frame|nil
local function ensureNpcDialogDragHandle(frame)
  if not frame then
    return nil
  end
  if not frame.__azerothCompanion_mm_questhandle then
    local handle = CreateFrame("Frame", nil, frame) -- 任务窗口顶部专用拖动手柄
    handle:SetHeight(NPC_DIALOG_HANDLE_HEIGHT)
    handle:SetPoint("TOPLEFT", frame, "TOPLEFT", NPC_DIALOG_HANDLE_LEFT, NPC_DIALOG_HANDLE_TOP)
    handle:SetPoint("TOPRIGHT", frame, "TOPRIGHT", NPC_DIALOG_HANDLE_RIGHT, NPC_DIALOG_HANDLE_TOP)
    handle:EnableMouse(true)
    frame.__azerothCompanion_mm_questhandle = handle
  end
  return frame.__azerothCompanion_mm_questhandle
end

--- 主界面目标追踪不走 ShowUIPanel；用 Header 上的透明手柄拖动，避开右侧按钮。
---@param frame Frame
---@return Frame|nil
local function ensureObjectiveTrackerDragHandle(frame)
  if not frame then
    return nil
  end
  if not frame.__azerothCompanion_mm_objectivehandle then
    local headerFrame = frame.Header or frame -- 目标追踪标题区域
    local handle = CreateFrame("Frame", nil, headerFrame) -- 目标追踪顶部专用拖动手柄
    handle:SetHeight(OBJECTIVE_TRACKER_HANDLE_HEIGHT)
    handle:SetPoint("TOPLEFT", headerFrame, "TOPLEFT", 0, 0)
    handle:SetPoint("TOPRIGHT", headerFrame, "TOPRIGHT", OBJECTIVE_TRACKER_HANDLE_RIGHT, 0)
    handle:EnableMouse(true)
    frame.__azerothCompanion_mm_objectivehandle = handle
  end
  return frame.__azerothCompanion_mm_objectivehandle
end

--- 从字段或全局名候选中解析日历按钮 Frame。
---@param frame Frame|nil 日历根框体
---@param fieldNames table 字段名候选
---@param globalNames table 全局名候选
---@return Frame|nil buttonFrame 命中的按钮 Frame
local function resolveCalendarButtonFrame(frame, fieldNames, globalNames)
  if frame and type(fieldNames) == "table" then
    for _, fieldName in ipairs(fieldNames) do
      local fieldValue = frame[fieldName] -- 日历按钮字段候选
      if type(fieldValue) == "table" then
        return fieldValue
      end
    end
  end
  if type(globalNames) == "table" then
    for _, globalName in ipairs(globalNames) do
      local globalValue = rawget(_G, globalName) -- 日历按钮全局候选
      if type(globalValue) == "table" then
        return globalValue
      end
    end
  end
  return nil
end

--- 计算日历动态标题手柄左右偏移；按钮未布局时返回保守静态范围。
---@param frame Frame|nil 日历根框体
---@return number leftOffset 左侧偏移
---@return number rightOffset 右侧偏移
local function calculateCalendarHandleOffsets(frame)
  local frameLeft = readFrameLeft(frame) -- 日历根框体左边界
  local frameWidth = readFrameDimension(frame, "GetWidth") -- 日历根框体宽度
  if not frameLeft or not frameWidth then
    return CALENDAR_HANDLE_FALLBACK_LEFT, CALENDAR_HANDLE_FALLBACK_RIGHT
  end

  local prevButton = resolveCalendarButtonFrame(frame, CALENDAR_PREV_BUTTON_FIELDS, CALENDAR_PREV_BUTTON_GLOBALS) -- 左翻月按钮
  local nextButton = resolveCalendarButtonFrame(frame, CALENDAR_NEXT_BUTTON_FIELDS, CALENDAR_NEXT_BUTTON_GLOBALS) -- 右翻月按钮
  local closeButton = resolveCalendarButtonFrame(frame, CALENDAR_CLOSE_BUTTON_FIELDS, CALENDAR_CLOSE_BUTTON_GLOBALS) -- 关闭按钮
  local prevRight = readFrameRight(prevButton) -- 左翻月按钮右边界
  local nextLeft = readFrameLeft(nextButton) -- 右翻月按钮左边界
  local closeLeft = readFrameLeft(closeButton) -- 关闭按钮左边界

  if not prevRight or not nextLeft or prevRight <= frameLeft or nextLeft <= frameLeft then
    return CALENDAR_HANDLE_FALLBACK_LEFT, CALENDAR_HANDLE_FALLBACK_RIGHT
  end

  local leftOffset = prevRight - frameLeft + CALENDAR_HANDLE_PADDING -- 动态左侧偏移
  local rightLimit = nextLeft - frameLeft - CALENDAR_HANDLE_PADDING -- 动态右侧局部边界
  if closeLeft and closeLeft > frameLeft then
    local closeLimit = closeLeft - frameLeft - CALENDAR_HANDLE_PADDING -- 关闭按钮前的右侧局部边界
    rightLimit = math.min(rightLimit, closeLimit)
  end

  if rightLimit - leftOffset < CALENDAR_HANDLE_MIN_WIDTH then
    return CALENDAR_HANDLE_FALLBACK_LEFT, CALENDAR_HANDLE_FALLBACK_RIGHT
  end
  return leftOffset, rightLimit - frameWidth
end

--- 日历窗口右上有翻月按钮，拖动手柄必须按按钮实际位置裁成标题中段。
---@param frame Frame|nil 日历根框体
---@return Frame|nil handle 日历顶部拖动手柄
local function ensureCalendarDragHandle(frame)
  if not frame then
    return nil
  end
  if not frame.__azerothCompanion_mm_tophandle then
    local handle = CreateFrame("Frame", nil, frame) -- 日历顶部动态拖动手柄
    handle:EnableMouse(true)
    frame.__azerothCompanion_mm_tophandle = handle
  end
  local handle = frame.__azerothCompanion_mm_tophandle -- 日历顶部动态拖动手柄
  local leftOffset, rightOffset = calculateCalendarHandleOffsets(frame) -- 日历手柄左右偏移
  handle:ClearAllPoints()
  handle:SetHeight(TOP_HANDLE_HEIGHT)
  handle:SetPoint("TOPLEFT", frame, "TOPLEFT", leftOffset, TOP_HANDLE_TOP)
  handle:SetPoint("TOPRIGHT", frame, "TOPRIGHT", rightOffset, TOP_HANDLE_TOP)
  pcall(function()
    local titleContainer = frame.TitleContainer -- 日历标题容器
    local titleLevel = titleContainer and titleContainer.GetFrameLevel and titleContainer:GetFrameLevel() or nil -- 标题容器层级
    local frameLevel = frame.GetFrameLevel and frame:GetFrameLevel() or 0 -- 日历根框体层级
    local baseLevel = titleLevel or frameLevel -- 手柄层级基准
    handle:SetFrameLevel(baseLevel + 5)
  end)
  return handle
end

--- 注册表窗口统一使用根框体顶部透明手柄，避免依赖不同 Blizzard 模板内部的 TitleContainer。
--- 手柄层级高于继承标题容器，并避开常见肖像、关闭和最大化按钮。
---@param frame Frame
---@return Frame|nil
local function ensureBlizzardTopDragHandle(frame)
  if not frame then
    return nil
  end
  local frameName = frame.GetName and frame:GetName() or nil -- Blizzard 根框体名
  local panelRecord = frameName and PANEL_REGISTRY_BY_KEY[frameName] or nil -- 注册表元数据
  local profileName = type(panelRecord) == "table" and panelRecord.topHandleProfile or "default" -- 手柄配置名
  local handleProfile = TOP_HANDLE_PROFILES[profileName] or TOP_HANDLE_PROFILES.default -- 手柄几何配置
  if not frame.__azerothCompanion_mm_tophandle then
    local handle = CreateFrame("Frame", nil, frame) -- 通用顶部安全拖动手柄
    handle:EnableMouse(true)
    frame.__azerothCompanion_mm_tophandle = handle
  end
  local handle = frame.__azerothCompanion_mm_tophandle -- 通用顶部安全拖动手柄
  handle:ClearAllPoints()
  handle:SetHeight(handleProfile.height or TOP_HANDLE_HEIGHT)
  if type(handleProfile.width) == "number" then
    handle:SetWidth(handleProfile.width)
    handle:SetPoint("TOPLEFT", frame, "TOPLEFT", handleProfile.left or TOP_HANDLE_LEFT, handleProfile.top or TOP_HANDLE_TOP)
  else
    handle:SetPoint("TOPLEFT", frame, "TOPLEFT", handleProfile.left or TOP_HANDLE_LEFT, handleProfile.top or TOP_HANDLE_TOP)
    handle:SetPoint("TOPRIGHT", frame, "TOPRIGHT", handleProfile.right or TOP_HANDLE_RIGHT, handleProfile.top or TOP_HANDLE_TOP)
  end
  pcall(function()
    local titleContainer = frame.TitleContainer -- 继承标题容器
    local titleLevel = titleContainer and titleContainer.GetFrameLevel and titleContainer:GetFrameLevel() or nil
    local frameLevel = frame.GetFrameLevel and frame:GetFrameLevel() or 0
    local baseLevel = titleLevel or frameLevel -- 手柄层级基准
    handle:SetFrameLevel(baseLevel + 5)
  end)
  return handle
end

--- 解析世界地图专用拖动条；只使用标题容器，避免覆盖 NavBar / TitleCanvasSpacerFrame。
---@param frame Frame|nil 世界地图根框体
---@return Frame|nil
local function resolveWorldMapDragRegion(frame)
  if not frame then
    return nil
  end
  local borderFrame = frame.BorderFrame -- 世界地图边框
  if borderFrame and borderFrame.TitleContainer then
    return borderFrame.TitleContainer
  end
  if frame.TitleContainer then
    return frame.TitleContainer
  end
  if borderFrame then
    return borderFrame
  end
  return nil
end

--- 创建或刷新世界地图右下角可见改大小角标。
---@param resizeHandle Frame|nil 世界地图改大小手柄
local function ensureWorldMapResizeMarker(resizeHandle)
  if not resizeHandle or type(resizeHandle.CreateTexture) ~= "function" then
    return
  end
  local resizeMarks = resizeHandle.__azerothCompanion_mm_worldmap_resizemark -- 可见角标贴图列表
  if type(resizeMarks) ~= "table" then
    resizeMarks = {} -- 可见角标贴图列表
    for markIndex = 1, #WORLD_MAP_RESIZE_MARK_LENGTHS do
      local resizeMark = resizeHandle:CreateTexture(nil, "OVERLAY") -- 可见角标单条贴图
      resizeMarks[markIndex] = resizeMark
    end
    resizeHandle.__azerothCompanion_mm_worldmap_resizemark = resizeMarks
  end
  for markIndex, resizeMark in ipairs(resizeMarks) do
    local markLength = WORLD_MAP_RESIZE_MARK_LENGTHS[markIndex] or WORLD_MAP_RESIZE_MARK_LENGTHS[#WORLD_MAP_RESIZE_MARK_LENGTHS] -- 角标线条长度
    local markOffset = WORLD_MAP_RESIZE_MARK_OFFSETS[markIndex] or WORLD_MAP_RESIZE_MARK_OFFSETS[#WORLD_MAP_RESIZE_MARK_OFFSETS] -- 角标线条偏移
    resizeMark:ClearAllPoints()
    resizeMark:SetSize(markLength, WORLD_MAP_RESIZE_MARK_THICKNESS)
    resizeMark:SetPoint("BOTTOMRIGHT", resizeHandle, "BOTTOMRIGHT", -WORLD_MAP_RESIZE_MARK_INSET, markOffset)
    resizeMark:SetColorTexture(1, 0.82, 0.32, WORLD_MAP_RESIZE_MARK_ALPHA)
    resizeMark:Show()
  end
end

--- 创建或刷新世界地图右下角改大小手柄。
---@param frame Frame|nil 世界地图根框体
---@return Frame|nil
local function ensureWorldMapResizeHandle(frame)
  if not frame then
    return nil
  end
  if not frame.__azerothCompanion_mm_worldmap_resizehandle then
    local resizeHandle = CreateFrame("Frame", nil, frame) -- 世界地图右下角改大小手柄
    resizeHandle:EnableMouse(true)
    frame.__azerothCompanion_mm_worldmap_resizehandle = resizeHandle
  end
  local resizeHandle = frame.__azerothCompanion_mm_worldmap_resizehandle -- 世界地图右下角改大小手柄
  resizeHandle:ClearAllPoints()
  resizeHandle:SetSize(WORLD_MAP_RESIZE_HANDLE_SIZE, WORLD_MAP_RESIZE_HANDLE_SIZE)
  resizeHandle:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", WORLD_MAP_RESIZE_HANDLE_OFFSET, -WORLD_MAP_RESIZE_HANDLE_OFFSET)
  pcall(function()
    if type(resizeHandle.SetFrameStrata) == "function" then
      resizeHandle:SetFrameStrata("TOOLTIP")
    end
    if type(resizeHandle.SetToplevel) == "function" then
      resizeHandle:SetToplevel(true)
    end
  end)
  pcall(function()
    local layerFrame = frame.BorderFrame or frame -- 世界地图层级参考框体
    local frameLevel = layerFrame.GetFrameLevel and layerFrame:GetFrameLevel() or 0 -- 世界地图边框层级
    resizeHandle:SetFrameLevel(frameLevel + 30)
  end)
  ensureWorldMapResizeMarker(resizeHandle)
  resizeHandle:Show()
  return resizeHandle
end

--- 开始世界地图手动改大小；独立使用 resize handle 的 OnUpdate，避免与标题拖动状态冲突。
---@param frame Frame 世界地图根框体
---@param resizeHandle Frame 改大小手柄
local function startWorldMapResize(frame, resizeHandle)
  if shouldBlockDragDueToCombat() or not frame or not resizeHandle then
    return
  end
  local parentScale = UIParent:GetEffectiveScale() or 1 -- UIParent 有效缩放
  if parentScale == 0 then
    parentScale = 1
  end
  local cursorStartX, cursorStartY = GetCursorPosition() -- 鼠标起点坐标
  cursorStartX, cursorStartY = cursorStartX / parentScale, cursorStartY / parentScale
  local baseWidth = readFrameDimension(frame, "GetWidth") or WORLD_MAP_MIN_WIDTH -- Blizzard 原生逻辑宽度
  local baseHeight = readFrameDimension(frame, "GetHeight") or WORLD_MAP_MIN_HEIGHT -- Blizzard 原生逻辑高度
  local startScale = readFrameScale(frame) -- 起始整体缩放
  local startVisualWidth = baseWidth * startScale -- 起始视觉宽度
  local startVisualHeight = baseHeight * startScale -- 起始视觉高度
  resizeHandle.__azerothCompanion_mm_resize = {
    targetFrame = frame,
    startX = cursorStartX,
    startY = cursorStartY,
    baseWidth = baseWidth,
    baseHeight = baseHeight,
    startScale = startScale,
    startVisualWidth = startVisualWidth,
    startVisualHeight = startVisualHeight,
    aspectRatio = startVisualWidth / startVisualHeight,
    lastWidth = startVisualWidth,
    lastHeight = startVisualHeight,
  }
  resizeHandle:SetScript("OnUpdate", function(self)
    local resizeState = self.__azerothCompanion_mm_resize -- 当前改大小状态
    if not resizeState or not resizeState.targetFrame then
      return
    end
    local currentCursorX, currentCursorY = GetCursorPosition() -- 当前鼠标坐标
    currentCursorX, currentCursorY = currentCursorX / parentScale, currentCursorY / parentScale
    local deltaX = currentCursorX - resizeState.startX -- 鼠标横向位移
    local deltaY = resizeState.startY - currentCursorY -- 鼠标向下位移
    local targetFrame = resizeState.targetFrame -- 世界地图根框体
    local nextWidth, nextHeight, nextScale = calculateWorldMapResizeSize(resizeState, deltaX, deltaY) -- 按固定宽高比约束的新视觉尺寸
    if math.abs(nextWidth - resizeState.lastWidth) < WORLD_MAP_RESIZE_EPSILON
        and math.abs(nextHeight - resizeState.lastHeight) < WORLD_MAP_RESIZE_EPSILON then
      return
    end
    resizeState.lastWidth = nextWidth
    resizeState.lastHeight = nextHeight
    targetFrame:SetScale(nextScale)
  end)
end

--- 结束世界地图手动改大小并保存当前位置与尺寸。
---@param frame Frame 世界地图根框体
---@param resizeHandle Frame 改大小手柄
local function stopWorldMapResize(frame, resizeHandle)
  if not resizeHandle then
    return
  end
  resizeHandle:SetScript("OnUpdate", nil)
  resizeHandle.__azerothCompanion_mm_resize = nil
  if frame then
    saveBlizzardPanel(frame, WORLD_MAP_PANEL_KEY)
  end
end

--- 绑定世界地图右下角改大小手柄。
---@param frame Frame|nil 世界地图根框体
local function bindWorldMapResizeHandle(frame)
  local resizeHandle = ensureWorldMapResizeHandle(frame) -- 世界地图右下角改大小手柄
  if not resizeHandle then
    return
  end
  stripDragSurface(resizeHandle)
  resizeHandle:SetScript("OnUpdate", nil)
  resizeHandle.__azerothCompanion_mm_resize = nil
  resizeHandle:EnableMouse(true)
  resizeHandle:RegisterForDrag("LeftButton")
  resizeHandle:SetScript("OnDragStart", function()
    startWorldMapResize(frame, resizeHandle)
  end)
  resizeHandle:SetScript("OnDragStop", function()
    stopWorldMapResize(frame, resizeHandle)
  end)
end

--- 清理世界地图改大小手柄。
---@param frame Frame|nil 世界地图根框体
local function disableWorldMapResizeHandle(frame)
  local resizeHandle = frame and frame.__azerothCompanion_mm_worldmap_resizehandle or nil -- 世界地图右下角改大小手柄
  if not resizeHandle then
    return
  end
  stripDragSurface(resizeHandle)
  resizeHandle:SetScript("OnUpdate", nil)
  resizeHandle.__azerothCompanion_mm_resize = nil
  local resizeMarks = resizeHandle.__azerothCompanion_mm_worldmap_resizemark -- 可见角标贴图列表
  if type(resizeMarks) == "table" then
    for _, resizeMark in ipairs(resizeMarks) do
      resizeMark:Hide()
    end
  end
  resizeHandle:Hide()
end

--- 解析拖动条：注册表窗口默认使用通用顶部手柄；只有结构或风险特殊的窗口保留专用手柄。
---@param frame Frame
---@return Frame
local function resolveBlizzardDragRegion(frame)
  if not frame then
    return frame
  end
  local fname = frame.GetName and frame:GetName() or nil
  if fname == "QuestFrame" or fname == "GossipFrame" then
    return ensureNpcDialogDragHandle(frame) or frame
  end
  if fname == "ObjectiveTrackerFrame" then
    return ensureObjectiveTrackerDragHandle(frame) or frame
  end
  if fname == "CalendarFrame" then
    return ensureCalendarDragHandle(frame) or frame
  end
  -- 组合背包：无标题栏，在顶部创建一条透明拖动手柄（仅创建一次，复用同一对象）。
  if fname == "ContainerFrameCombinedBags" then
    if not frame.__azerothCompanion_mm_baghandle then
      local handle = CreateFrame("Frame", nil, frame)
      handle:SetHeight(20)
      handle:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
      handle:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
      handle:EnableMouse(true)
      frame.__azerothCompanion_mm_baghandle = handle
    end
    return frame.__azerothCompanion_mm_baghandle
  end
  return ensureBlizzardTopDragHandle(frame) or frame
end

--- 参考 MoveAnything Modules/Position：受 FramePositionManager / UIPanel 管线管理的窗口若不排除，
--- 暴雪每帧会重锚，StartMoving 几乎立刻被抵消，表现为「拖不动」。此处临时剥离并在禁用时恢复。
local function detachBlizzardPanelLayout(frame, key)
  if not frame or not key or frame.__azerothCompanion_mm_detached then
    return
  end
  if UIPARENT_MANAGED_FRAME_POSITIONS and UIPARENT_MANAGED_FRAME_POSITIONS[key] then
    frame.ignoreFramePositionManager = true
    frame.__azerothCompanion_mm_ifpm = true
  end
  if UIPanelWindows and UIPanelWindows[key] then
    frame.__azerothCompanion_savedUIPanelWindows = UIPanelWindows[key]
    UIPanelWindows[key] = nil
    pcall(function()
      frame:SetAttribute("UIPanelLayout-enabled", false)
    end)
    if UISpecialFrames then
      local found = false
      for i, v in ipairs(UISpecialFrames) do
        if v == key then
          found = true
          break
        end
      end
      if not found then
        table.insert(UISpecialFrames, key)
      end
      frame.__azerothCompanion_mm_uispecial = true
    end
  end
  frame.__azerothCompanion_mm_detached = true
end

local function reattachBlizzardPanelLayout(frame, key)
  if not frame or not key or not frame.__azerothCompanion_mm_detached then
    return
  end
  if frame.__azerothCompanion_mm_ifpm then
    frame.ignoreFramePositionManager = nil
    frame.__azerothCompanion_mm_ifpm = nil
  end
  if frame.__azerothCompanion_savedUIPanelWindows and UIPanelWindows then
    UIPanelWindows[key] = frame.__azerothCompanion_savedUIPanelWindows
    frame.__azerothCompanion_savedUIPanelWindows = nil
    pcall(function()
      frame:SetAttribute("UIPanelLayout-enabled", true)
    end)
  end
  if frame.__azerothCompanion_mm_uispecial and UISpecialFrames then
    for i, v in ipairs(UISpecialFrames) do
      if v == key then
        table.remove(UISpecialFrames, i)
        break
      end
    end
    frame.__azerothCompanion_mm_uispecial = nil
  end
  frame.__azerothCompanion_mm_detached = nil
end

--- 不用 StartMoving：以光标位移驱动 TOPLEFT 相对 UIParent；scale 取拖动起点时目标 Frame 有效缩放，拖动中不变更。
---@param frame Frame 要移动的暴雪根 Frame
---@param updateDriver Frame|nil OnUpdate 承载 Frame，nil 时使用被移动根框体
local function blizzardPanelManualDragStart(frame, updateDriver)
  local scale = readFrameEffectiveScale(frame) -- 目标 Frame 当前有效缩放
  local cx, cy = GetCursorPosition()
  cx, cy = cx / scale, cy / scale
  local originX, originY = readTopLeftPointOffset(frame) -- 当前 TOPLEFT 锚点偏移
  if not originX or not originY then
    originX, originY = readTopLeftOffsetFromBounds(frame)
  end
  if not originX or not originY then
    return
  end
  local driverFrame = updateDriver or frame -- OnUpdate 承载对象
  driverFrame.__azerothCompanion_mm_drag = {
    targetFrame = frame,
    startX = cx,
    startY = cy,
    originX = originX,
    originY = originY,
  }
  driverFrame:SetScript("OnUpdate", function(self)
    local dragState = self.__azerothCompanion_mm_drag -- 当前拖动状态
    if not dragState or not dragState.targetFrame then
      return
    end
    local cursorX, cursorY = GetCursorPosition()
    cursorX, cursorY = cursorX / scale, cursorY / scale
    local deltaX = cursorX - dragState.startX -- 光标横向位移
    local deltaY = cursorY - dragState.startY -- 光标纵向位移
    local targetFrame = dragState.targetFrame -- 被移动的 Blizzard 根框体
    targetFrame:ClearAllPoints()
    targetFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", dragState.originX + deltaX, dragState.originY + deltaY)
  end)
end

---@param frame Frame
---@param key string 全局名，与 saveBlizzardPanel 存档键一致
---@param updateDriver Frame|nil OnUpdate 承载 Frame，nil 时使用被移动根框体
local function blizzardPanelManualDragStop(frame, key, updateDriver)
  local driverFrame = updateDriver or frame -- OnUpdate 承载对象
  driverFrame:SetScript("OnUpdate", nil)
  driverFrame.__azerothCompanion_mm_drag = nil
  saveBlizzardPanel(frame, key)
end

--- 绑定通用手动位移拖动面；调用方决定是否 detach Blizzard UIPanel 管线。
---@param frame Frame 被移动的 Blizzard 根框体
---@param storageKey string 位置存档键
---@param drag Frame 拖动命中区
---@param updateDriver Frame|nil OnUpdate 承载 Frame，nil 时使用被移动根框体
local function bindBlizzardPanelManualDrag(frame, storageKey, drag, updateDriver)
  if not frame or not storageKey or not drag then
    return
  end
  local driverFrame = updateDriver or frame -- OnUpdate 承载对象
  pcall(function()
    drag:EnableMouse(true)
  end)
  drag:RegisterForDrag("LeftButton")
  drag:SetScript("OnDragStart", function()
    if shouldBlockDragDueToCombat() then
      return
    end
    blizzardPanelManualDragStart(frame, driverFrame)
  end)
  drag:SetScript("OnDragStop", function()
    blizzardPanelManualDragStop(frame, storageKey, driverFrame)
  end)
end

--- 对单个已挂接面板应用：读档、detach、挂拖动条与手动位移；重复调用会覆盖同名拖动脚本。
---@param frame Frame
---@param key string
local function applyBlizzardPanel(frame, key)
  if not blizzardDragEnabled() then
    return
  end
  if isBlizzardPanelDragDenied(key) then
    return
  end
  local storageKey = getBlizzardPanelStorageKey(key) -- 位置存档键
  local titleDrag = resolveBlizzardDragRegion(frame)
  stripDragSurface(titleDrag)
  stripDragSurface(frame.__azerothCompanion_mm_draglayer)
  restoreBlizzardPanel(frame, storageKey)
  detachBlizzardPanelLayout(frame, key)
  frame:SetMovable(true)
  frame:SetUserPlaced(true)
  frame:SetClampedToScreen(true)
  local mode = normalizeDragHitMode(getMoverSetting("MOVER_DRAG_HIT_MODE", HIT_TITLEBAR))
  local panelRecord = PANEL_REGISTRY_BY_KEY[key] -- Blizzard 面板注册元数据
  if type(panelRecord) == "table" and panelRecord.forceTitlebarOnly == true then
    mode = HIT_TITLEBAR
  end
  if mode == HIT_TITLEBAR_EMPTY then
    local layer = frame.__azerothCompanion_mm_draglayer
    if not layer then
      layer = CreateFrame("Frame", nil, frame)
      frame.__azerothCompanion_mm_draglayer = layer
    end
    layer:SetAllPoints(frame)
    layer:Show()
    pcall(function()
      layer:Lower()
    end)
    bindBlizzardPanelManualDrag(frame, storageKey, titleDrag)
    bindBlizzardPanelManualDrag(frame, storageKey, layer)
  else
    if frame.__azerothCompanion_mm_draglayer then
      pcall(function()
        frame.__azerothCompanion_mm_draglayer:Hide()
      end)
    end
    bindBlizzardPanelManualDrag(frame, storageKey, titleDrag)
  end
  --- 提高标题/解析条层级，避免顶栏装饰/子控件盖住标题区导致 RegisterForDrag 点不中（成就等）。
  pcall(function()
    local dl = titleDrag:GetFrameLevel() or 0
    local fl = frame:GetFrameLevel() or 0
    if dl < fl + 20 then
      titleDrag:SetFrameLevel(fl + 25)
    end
  end)
  local localeTable = AzerothCompanion.Localization.Strings or {}
  debugPrint(string.format(localeTable.MICROMENU_DEBUG_APPLY_FMT or "%s", tostring(key)))
end

--- 标记已挂接并应用暴雪拖动（与 ShowUIPanel / 可见刷新等路径共用，避免 __azerothCompanion_mm_inited 与 apply 分叉）。
---@param frame Frame
---@param key string 全局名
local function ensureBlizzardPanelApplied(frame, key)
  if isBlizzardPanelDragDenied(key) then
    return
  end
  if not frame.__azerothCompanion_mm_inited then
    frame.__azerothCompanion_mm_inited = true
  end
  installRegisteredPanelRestoreHooks(frame, key)
  applyBlizzardPanel(frame, key)
  if scheduleRelatedPanelPositionRestore then
    scheduleRelatedPanelPositionRestore(key)
  end
end

--- 安全读取世界地图最大化状态。
---@param frame Frame|nil 世界地图根框体
---@return boolean
local function isWorldMapMaximized(frame)
  if not frame or type(frame.IsMaximized) ~= "function" then
    return false
  end
  local success, maximized = pcall(function() -- Blizzard 世界地图最大化状态
    return frame:IsMaximized()
  end)
  return success and maximized == true
end

--- 安全读取世界地图黑色遮罩显示状态。
---@param frame Frame|nil 世界地图根框体
---@return boolean
local function isWorldMapBlackoutShown(frame)
  local blackoutFrame = frame and frame.BlackoutFrame or nil -- Blizzard 最大化黑色遮罩
  if not blackoutFrame or type(blackoutFrame.IsShown) ~= "function" then
    return false
  end
  local success, shown = pcall(function() -- 黑色遮罩显示状态
    return blackoutFrame:IsShown()
  end)
  return success and shown == true
end

--- 通过 Blizzard 自有最小化路径把世界地图切回小地图状态；不直接隐藏 BlackoutFrame。
---@param frame Frame|nil 世界地图根框体
local function minimizeWorldMapForMover(frame)
  if not frame or not isWorldMapMaximized(frame) and not isWorldMapBlackoutShown(frame) then
    return
  end
  if type(frame.HandleUserActionMinimizeSelf) == "function" then
    pcall(function()
      frame:HandleUserActionMinimizeSelf()
    end)
    return
  end
  if type(frame.Minimize) == "function" then
    pcall(function()
      frame:Minimize()
    end)
  end
end

--- 记录世界地图小地图状态的根缩放，便于最大化后再最小化时恢复。
---@param frame Frame|nil 世界地图根框体
local function rememberWorldMapMinimizedScale(frame)
  if not frame then
    return
  end
  local scaleValue = readFrameScale(frame) -- 小地图状态整体缩放
  if scaleValue > 0 and math.abs(scaleValue - 1) >= WORLD_MAP_SCALE_EPSILON then
    frame.__azerothCompanion_mm_minimized_scale = scaleValue
  end
end

--- 世界地图最大化时必须回到根缩放 1，避免全屏地图被小地图尺寸缩放污染。
---@param frame Frame|nil 世界地图根框体
local function resetWorldMapScaleForMaximized(frame)
  if not frame then
    return
  end
  rememberWorldMapMinimizedScale(frame)
  setWorldMapRootScale(frame, 1)
end

--- 世界地图返回小地图状态后恢复保存的视觉尺寸。
---@param frame Frame|nil 世界地图根框体
local function restoreWorldMapScaleForMinimized(frame)
  if not frame then
    return
  end
  local moverFrames = getMoverFrames() -- 窗口位置表
  local savedRecord = moverFrames[WORLD_MAP_PANEL_KEY] -- 世界地图存档记录
  if type(savedRecord) == "table" and tonumber(savedRecord.width) and tonumber(savedRecord.height) then
    restoreBlizzardPanel(frame, WORLD_MAP_PANEL_KEY)
    return
  end
  local scaleValue = tonumber(frame.__azerothCompanion_mm_minimized_scale) -- 本次会话记录的缩放
  if scaleValue and scaleValue > 0 then
    setWorldMapRootScale(frame, scaleValue)
  end
end

--- 安装单个世界地图显示模式缩放 hook。
---@param frame Frame 世界地图根框体
---@param methodName string|nil Blizzard 方法名
---@param callback function hook 回调
---@return boolean installed 是否安装成功
local function hookWorldMapScaleModeMethod(frame, methodName, callback)
  if not methodName or type(frame[methodName]) ~= "function" or type(hooksecurefunc) ~= "function" then
    return false
  end
  local success = pcall(function() -- hooksecurefunc 安装结果
    hooksecurefunc(frame, methodName, function(self)
      callback(self or frame)
    end)
  end)
  return success == true
end

--- 只处理根缩放在最大化 / 小地图状态之间的切换；不接管 WorldMapFrame 显示状态。
---@param frame Frame|nil 世界地图根框体
local function installWorldMapScaleModeHooks(frame)
  if not frame or frame.__azerothCompanion_mm_scalemode_hooked then
    return
  end
  local maximizeMethod = nil -- 最大化用户动作方法
  if type(frame.HandleUserActionMaximizeSelf) == "function" then
    maximizeMethod = "HandleUserActionMaximizeSelf"
  elseif type(frame.Maximize) == "function" then
    maximizeMethod = "Maximize"
  end
  local minimizeMethod = nil -- 最小化用户动作方法
  if type(frame.HandleUserActionMinimizeSelf) == "function" then
    minimizeMethod = "HandleUserActionMinimizeSelf"
  elseif type(frame.Minimize) == "function" then
    minimizeMethod = "Minimize"
  end
  local maximizeHooked = hookWorldMapScaleModeMethod(frame, maximizeMethod, resetWorldMapScaleForMaximized) -- 最大化缩放 hook
  local minimizeHooked = hookWorldMapScaleModeMethod(frame, minimizeMethod, restoreWorldMapScaleForMinimized) -- 最小化缩放 hook
  if maximizeHooked or minimizeHooked then
    frame.__azerothCompanion_mm_scalemode_hooked = true
  end
end

--- 为世界地图小地图状态绑定专用标题拖动；不剥离 UIPanel 管线，不 hook 显示状态函数。
---@param frame Frame|nil 世界地图根框体
local function applyWorldMapFrameSafeDrag(frame)
  if not blizzardDragEnabled() or not frame then
    return
  end
  installWorldMapScaleModeHooks(frame)
  minimizeWorldMapForMover(frame)
  if isWorldMapMaximized(frame) or isWorldMapBlackoutShown(frame) then
    return
  end
  installWorldMapPinPositionRefreshHook(frame)
  local titleDrag = resolveWorldMapDragRegion(frame) -- 世界地图标题拖动区
  if not titleDrag then
    return
  end
  stripDragSurface(titleDrag)
  restoreBlizzardPanel(frame, WORLD_MAP_PANEL_KEY)
  rememberWorldMapMinimizedScale(frame)
  frame.__azerothCompanion_mm_worldmap_inited = true
  pcall(function()
    frame:SetMovable(true)
  end)
  pcall(function()
    frame:SetUserPlaced(true)
  end)
  pcall(function()
    frame:SetClampedToScreen(true)
  end)
  pcall(function()
    titleDrag:EnableMouse(true)
  end)
  bindBlizzardPanelManualDrag(frame, WORLD_MAP_PANEL_KEY, titleDrag)
  bindWorldMapResizeHandle(frame)
end

--- 关闭世界地图专用拖动；仅清理本插件脚本，不触碰 Blizzard 显示状态。
local function disableWorldMapFrameSafeDrag()
  local frame = _G[WORLD_MAP_PANEL_KEY] -- 世界地图根框体
  if not frame then
    return
  end
  frame:SetScript("OnUpdate", nil)
  frame.__azerothCompanion_mm_drag = nil
  frame.__azerothCompanion_mm_worldmap_inited = nil
  stripDragSurface(resolveWorldMapDragRegion(frame))
  disableWorldMapResizeHandle(frame)
end

--- 关闭拖动：清 OnUpdate、reattach 布局管线、卸 RegisterForDrag。
--- 不在此调用 SetMovable(false)：第三方插件可能对根 Frame 仍执行
--- StartMoving；若强行不可移动会导致其 OnDrag 路径报错。
---@param frame Frame|nil
local function disableBlizzardPanel(frame)
  if not frame then
    return
  end
  local key = frame.GetName and frame:GetName() or nil
  frame:SetScript("OnUpdate", nil)
  frame.__azerothCompanion_mm_drag = nil
  if key then
    reattachBlizzardPanelLayout(frame, key)
  end
  local titleDrag = resolveBlizzardDragRegion(frame)
  stripDragSurface(titleDrag)
  stripDragSurface(frame.__azerothCompanion_mm_draglayer)
  if frame.__azerothCompanion_mm_draglayer then
    pcall(function()
      frame.__azerothCompanion_mm_draglayer:Hide()
    end)
  end
end

local hooked = {}
local skipped = {}

local tabRestoreDriver
local tabRestoreUntil = {}
local tabRestoreKeys = {} -- 页签补正驱动复用的 key 列表，避免每帧分配新表
local TAB_RESTORE_BURST_SEC = 0.18
local globalUIPanelPositionGuardInstalled = false -- 是否已安装全局 UIPanel 重排保护

local function tabRestoreDriverTick()
  if not isMoverEnabled() then
    wipe(tabRestoreUntil)
    if tabRestoreDriver then
      tabRestoreDriver:SetScript("OnUpdate", nil)
    end
    return
  end
  local now = GetTime()
  wipe(tabRestoreKeys)
  for key in pairs(tabRestoreUntil) do
    tabRestoreKeys[#tabRestoreKeys + 1] = key
  end
  for _, key in ipairs(tabRestoreKeys) do
    local restoreEndTime = tabRestoreUntil[key] -- 当前窗口短时补正截止时间
    if restoreEndTime and now >= restoreEndTime then
      tabRestoreUntil[key] = nil
    elseif restoreEndTime then
      local frame = _G[key] -- Blizzard 根面板
      if frame and frame:IsShown() and frame.__azerothCompanion_mm_inited then
        restoreBlizzardPanelIfMisplaced(frame, key)
      end
    end
  end
  wipe(tabRestoreKeys)
  if not next(tabRestoreUntil) and tabRestoreDriver then
    tabRestoreDriver:SetScript("OnUpdate", nil)
  end
end

local function beginTabRestoreBurst(key)
  tabRestoreUntil[key] = GetTime() + TAB_RESTORE_BURST_SEC
  if not tabRestoreDriver then
    tabRestoreDriver = CreateFrame("Frame", "AzerothCompanionMoverTabRestoreDriver", UIParent)
  end
  tabRestoreDriver:SetScript("OnUpdate", tabRestoreDriverTick)
end

--- 当前 Frame 是否属于需要拦截直接 UpdateUIPanelPositions 的已接管布局重排窗口。
---@param frame Frame|nil 当前重排目标
---@return string|nil key Blizzard 根面板全局名
local function getGlobalUIPanelPositionGuardKey(frame)
  if not blizzardDragEnabled() or not frame or not frame.GetName then
    return nil
  end
  local key = frame:GetName() -- Blizzard 根面板全局名
  local panelRecord = key and PANEL_REGISTRY_BY_KEY[key] or nil -- 注册表元数据
  if type(panelRecord) ~= "table" then
    return nil
  end
  if isBlizzardPanelDragDenied(key) or not frame.__azerothCompanion_mm_inited then
    return nil
  end
  local storageKey = getBlizzardPanelStorageKey(key) -- 位置存档键
  local moverFrames = getMoverFrames() -- 窗口位置表
  if type(moverFrames[storageKey]) ~= "table" then
    return nil
  end
  return key
end

--- 获取已登记 Blizzard 面板名；不要求已接管或已有存档，用于关联主窗恢复。
---@param frame Frame|nil 当前重排目标
---@return string|nil key Blizzard 根面板全局名
local function getTrackedBlizzardPanelKey(frame)
  if not frame or not frame.GetName then
    return nil
  end
  local key = frame:GetName() -- Blizzard 根面板全局名
  if not isTrackedBlizzardPanelName(key) or isBlizzardPanelDragDenied(key) then
    return nil
  end
  return key
end

--- Blizzard 布局方法或 UpdateUIPanelPositions 被拦截后，统一执行位置恢复与短时保护。
---@param frame Frame Blizzard 根面板
---@param key string 根面板全局名
local function restoreAfterBlizzardLayout(frame, key)
  restoreBlizzardPanelIfMisplaced(frame, key)
  if scheduleRelatedPanelPositionRestore then
    scheduleRelatedPanelPositionRestore(key)
  end
  beginTabRestoreBurst(key)
  if schedulePostShowPanelRestore then
    schedulePostShowPanelRestore()
  end
end

--- 安装全局 UIPanel 重排保护，覆盖已接管且已保存位置窗口直接调用 UpdateUIPanelPositions 的路径。
local function installGlobalUIPanelPositionGuard()
  if globalUIPanelPositionGuardInstalled or type(_G.UpdateUIPanelPositions) ~= "function" then
    return
  end
  local originalUpdate = _G.UpdateUIPanelPositions -- Blizzard 原始 UIPanel 重排函数
  _G.UpdateUIPanelPositions = function(currentFrame, ...)
    local guardedKey = getGlobalUIPanelPositionGuardKey(currentFrame) -- 需要保护的根面板全局名
    local trackedKey = getTrackedBlizzardPanelKey(currentFrame) -- 关联恢复用面板名
    if guardedKey then
      restoreAfterBlizzardLayout(currentFrame, guardedKey)
      return
    end
    originalUpdate(currentFrame, ...)
    if trackedKey and scheduleRelatedPanelPositionRestore then
      scheduleRelatedPanelPositionRestore(trackedKey)
    end
    --- HideUIPanel / MoveUIPanel 可能用 nil 或其它面板触发全局重排；原始布局必须保留，
    --- 但本插件已保存位置且仍可见的窗口需要在同一调用栈内补回，避免下一帧才恢复造成闪回。
    if restoreAllVisibleTrackedPanelsIfMisplaced then
      restoreAllVisibleTrackedPanelsIfMisplaced()
    end
  end
  globalUIPanelPositionGuardInstalled = true
end

--- 为已登记的 Blizzard 根面板安装方法级位置恢复；用于覆盖 SetTab / SetDisplayMode 等内部重排。
---@param frame Frame Blizzard 根面板
---@param key string 根面板全局名
installRegisteredPanelRestoreHooks = function(frame, key)
  if not frame or not key or type(hooksecurefunc) ~= "function" then
    return
  end
  installGlobalUIPanelPositionGuard()
  local panelRecord = PANEL_REGISTRY_BY_KEY[key] -- Blizzard 面板注册元数据
  local methodNames = type(panelRecord) == "table" and panelRecord.restoreMethods or nil -- 需要补正的 Blizzard 方法名列表
  if type(methodNames) ~= "table" then
    return
  end
  frame.__azerothCompanion_mm_restoreHooks = frame.__azerothCompanion_mm_restoreHooks or {}
  for _, methodName in ipairs(methodNames) do
    local methodHooked = frame.__azerothCompanion_mm_restoreHooks[methodName] -- 当前方法是否已挂接
    if not methodHooked and type(frame[methodName]) == "function" then
      local hookSuccess = pcall(function()
        hooksecurefunc(frame, methodName, function(self)
          pcall(function()
            local targetFrame = self or frame -- Blizzard 方法所属根面板
            restoreAfterBlizzardLayout(targetFrame, key)
          end)
        end)
      end)
      if hookSuccess then
        frame.__azerothCompanion_mm_restoreHooks[methodName] = true
      end
    end
  end
end

--- 页签控件常在子 Frame 上，向上找到已挂接的顶层 Global（如 AchievementFrame）。
local function resolveHookedRootPanel(startFrame)
  local f = startFrame
  local depth = 0
  while f and depth < 24 do
    depth = depth + 1
    local n = f.GetName and f:GetName()
    if type(n) == "string" and n ~= "" and hooked[n] then
      return f, n
    end
    f = f.GetParent and f:GetParent()
  end
  return nil, nil
end

--- `installTabSwitchHook` 需在切页后与 ShowUIPanel 一样做延迟位置补正（第三方插件可能分帧改布局）。

local tabSwitchHookAttempted = false
local function installTabSwitchHook()
  if tabSwitchHookAttempted or not hooksecurefunc then
    return
  end
  tabSwitchHookAttempted = true
  pcall(function()
    hooksecurefunc("PanelTemplates_SetTab", function(frame, id)
      if not frame then
        return
      end
      local root, name = resolveHookedRootPanel(frame)
      if not root or not name then
        return
      end
      restoreBlizzardPanelIfMisplaced(root, name)
      beginTabRestoreBurst(name)
      --- 部分第三方插件会在切页后继续改子面板锚点，与 ShowUIPanel 相同做下一帧/短延迟全量补正。
      if schedulePostShowPanelRestore then
        schedulePostShowPanelRestore()
      end
    end)
  end)
end

local function attachBlizzardOnShow(name, frame)
  if hooked[name] or skipped[name] then
    return
  end
  if not isTrackedBlizzardPanelName(name) or isBlizzardPanelDragDenied(name) then
    return
  end
  if not frame or not frame.HookScript then
    return
  end
  local hookOk = pcall(function()
    frame:HookScript("OnShow", function(self)
      local function run()
        if blizzardDragEnabled() then
          ensureBlizzardPanelApplied(self, name)
        else
          if not self.__azerothCompanion_mm_inited then
            self.__azerothCompanion_mm_inited = true
          end
          disableBlizzardPanel(self)
        end
      end
      pcall(run)
    end)
  end)
  if not hookOk then
    skipped[name] = true
    return
  end
  hooked[name] = true
end

local function hookPanelByKey(key)
  if hooked[key] or skipped[key] then
    return
  end
  if not isTrackedBlizzardPanelName(key) or isBlizzardPanelDragDenied(key) then
    return
  end
  local f = _G[key]
  if not f or not f.HookScript then
    return
  end
  attachBlizzardOnShow(key, f)
end

--- 先内置+额外名单，再已挂接名；同名只执行一次（与 restore 一致）。
local function forEachUniqueTrackedPanelKey(fn)
  local seen = {}
  local function run(key)
    if type(key) ~= "string" or key == "" or seen[key] then
      return
    end
    seen[key] = true
    fn(key)
  end
  for _, key in ipairs(getAllPanelKeys()) do
    run(key)
  end
  for name in pairs(hooked) do
    run(name)
  end
end

local function applyVisibleBlizzardPanels()
  forEachUniqueTrackedPanelKey(function(key)
    local f = _G[key]
    if f and f:IsShown() then
      pcall(function()
        ensureBlizzardPanelApplied(f, key)
      end)
    end
  end)
end

local function disableVisibleBlizzardPanels()
  forEachUniqueTrackedPanelKey(function(key)
    local frame = _G[key]
    if frame then
      pcall(function()
        disableBlizzardPanel(frame)
      end)
    end
  end)
end

local function tryHookPendingPanels()
  for _, key in ipairs(getAllPanelKeys()) do
    hookPanelByKey(key)
  end
end

--- 对已挂接且仍显示的暴雪窗口，若当前位置与存档偏差则 restore（多面板切换后 UIParent 可能重锚）。
restoreAllVisibleTrackedPanelsIfMisplaced = function()
  if not blizzardDragEnabled() then
    return
  end
  forEachUniqueTrackedPanelKey(function(key)
    local f = _G[key]
    if not f or not f.IsShown or not f:IsShown() or not f.__azerothCompanion_mm_inited then
      return
    end
    pcall(function()
      restoreBlizzardPanelIfMisplaced(f, key)
    end)
  end)
end

--- ShowUIPanel / PanelTemplates_SetTab 后下一帧与短延迟各补一次位置（主路径为 hook；见 AGENTS 定时器例外说明）。
schedulePostShowPanelRestore = function()
  --- After(0)：下一帧合并补正，主路径已为 hooksecurefunc(ShowUIPanel)。
  C_Timer.After(0, function()
    if blizzardDragEnabled() then
      restoreAllVisibleTrackedPanelsIfMisplaced()
    end
  end)
  --- 同次打开流程内部分客户端仍分帧重锚，短延迟二次比对。
  C_Timer.After(0.06, function()
    if blizzardDragEnabled() then
      restoreAllVisibleTrackedPanelsIfMisplaced()
    end
  end)
end

--- no-detach 窗口走通用顶部手柄和手动位移，不触碰 UIPanelWindows / UIPanelLayout。
---@param frame Frame|nil Blizzard 根框体
---@param key string 根框体全局名
---@param blockInCombat boolean 是否在战斗中跳过受保护操作
local function applyNoDetachSafeDrag(frame, key, blockInCombat)
  if not blizzardDragEnabled() or not frame then
    return
  end
  if blockInCombat and type(InCombatLockdown) == "function" and InCombatLockdown() then
    return
  end
  local topHandle = ensureBlizzardTopDragHandle(frame) -- 顶部安全拖动手柄
  if not topHandle then
    return
  end
  stripDragSurface(topHandle)
  restoreBlizzardPanel(frame, key)
  bindBlizzardPanelManualDrag(frame, key, topHandle, topHandle)
end

--- 公会 / 社区界面走 no-detach 安全拖动。
---@param frame Frame|nil 公会 / 社区根框体
local function applyGuildPanelSafeDrag(frame)
  applyNoDetachSafeDrag(frame, GUILD_PANEL_KEY, false)
end

--- 系统选项界面走 no-detach 安全拖动。
---@param frame Frame|nil 系统选项根框体
local function applySettingsPanelSafeDrag(frame)
  applyNoDetachSafeDrag(frame, SETTINGS_PANEL_KEY, true)
end

--- 关闭 no-detach 安全拖动，不触碰 Blizzard 原生管线。
---@param key string 根框体全局名
local function disableNoDetachSafeDrag(key)
  local frame = _G[key] -- Blizzard 根框体
  if not frame then
    return
  end
  local topHandle = frame.__azerothCompanion_mm_tophandle -- no-detach 顶部手柄
  if topHandle then
    topHandle:SetScript("OnUpdate", nil)
    topHandle.__azerothCompanion_mm_drag = nil
  end
  --- 旧版本曾把拖动 OnUpdate 挂在根框体，禁用时一并清理。
  frame:SetScript("OnUpdate", nil)
  frame.__azerothCompanion_mm_drag = nil
  stripDragSurface(topHandle)
end

--- 关闭公会 / 社区 no-detach 安全拖动。
local function disableGuildPanelSafeDrag()
  disableNoDetachSafeDrag(GUILD_PANEL_KEY)
end

--- 关闭系统选项 no-detach 安全拖动。
local function disableSettingsPanelSafeDrag()
  disableNoDetachSafeDrag(SETTINGS_PANEL_KEY)
end

--- CommunitiesFrame 不进入通用拖动接管；若已有 Mover 存档，页签重排后只补回根框体位置。
---@param frame Frame|nil 公会 / 社区根框体
local function restoreGuildPanelSavedPosition(frame)
  if not blizzardDragEnabled() then
    return
  end
  if type(InCombatLockdown) == "function" and InCombatLockdown() then
    return
  end
  if not frame or not frame.IsShown or not frame:IsShown() then
    return
  end
  local moverFrames = getMoverFrames() -- 窗口位置表
  if type(moverFrames[GUILD_PANEL_KEY]) ~= "table" then
    return
  end
  if positionMatchesSaved(frame, GUILD_PANEL_KEY) then
    return
  end
  restoreBlizzardPanel(frame, GUILD_PANEL_KEY)
end

--- 页签 / 显示模式切换后执行即时与短延迟补正，覆盖 Blizzard 内部分帧重排。
---@param frame Frame|nil 公会 / 社区根框体
local function scheduleGuildPanelSavedPositionRestore(frame)
  restoreGuildPanelSavedPosition(frame)
  if not C_Timer or type(C_Timer.After) ~= "function" then
    return
  end
  --- After(0)：同一点击链路结束后补正，主触发路径为 HookScript / hooksecurefunc。
  C_Timer.After(0, function()
    restoreGuildPanelSavedPosition(frame)
  end)
  --- 0.06s：覆盖 CommunitiesFrame.UpdateCommunitiesTabs 内部 UIPanel 重排后的短延迟二次补正。
  C_Timer.After(0.06, function()
    restoreGuildPanelSavedPosition(frame)
  end)
end

--- 注册表面板打开后，恢复与其成组的 no-detach 主窗口。
---@param key string 当前 Blizzard 面板全局名
scheduleRelatedPanelPositionRestore = function(key)
  local panelRecord = PANEL_REGISTRY_BY_KEY[key] -- 当前面板注册元数据
  local relatedKeys = type(panelRecord) == "table" and panelRecord.relatedPositionKeys or nil -- 关联主窗列表
  if type(relatedKeys) ~= "table" then
    return
  end
  for _, relatedKey in ipairs(relatedKeys) do
    if relatedKey == GUILD_PANEL_KEY then
      scheduleGuildPanelSavedPositionRestore(_G[GUILD_PANEL_KEY])
    end
  end
end

--- 为公会 / 社区界面安装存档位置保护，不注册拖动面、不剥离 UIPanel 管线。
local function installGuildPanelPositionGuard()
  local frame = _G[GUILD_PANEL_KEY] -- 公会 / 社区根框体
  if not frame then
    return
  end
  if not frame.__azerothCompanion_mm_guildGuard then
    if frame.HookScript then
      pcall(function()
        frame:HookScript("OnShow", function(self)
          applyGuildPanelSafeDrag(self)
          scheduleGuildPanelSavedPositionRestore(self)
        end)
      end)
    end
    if type(hooksecurefunc) == "function" and type(frame.SetDisplayMode) == "function" then
      pcall(function()
        hooksecurefunc(frame, "SetDisplayMode", function(self)
          scheduleGuildPanelSavedPositionRestore(self)
        end)
      end)
    end
    if type(hooksecurefunc) == "function" and type(frame.UpdateCommunitiesTabs) == "function" then
      pcall(function()
        hooksecurefunc(frame, "UpdateCommunitiesTabs", function(self)
          scheduleGuildPanelSavedPositionRestore(self)
        end)
      end)
    end
    frame.__azerothCompanion_mm_guildGuard = true
  end
  for _, tabKey in ipairs(GUILD_PANEL_TAB_KEYS) do
    local tabFrame = frame[tabKey] -- 左侧页签 Frame
    if tabFrame and tabFrame.HookScript and not tabFrame.__azerothCompanion_mm_guildGuard then
      pcall(function()
        tabFrame:HookScript("OnClick", function()
          applyGuildPanelSafeDrag(frame)
          scheduleGuildPanelSavedPositionRestore(frame)
        end)
      end)
      tabFrame.__azerothCompanion_mm_guildGuard = true
    end
  end
  applyGuildPanelSafeDrag(frame)
  scheduleGuildPanelSavedPositionRestore(frame)
end

--- SettingsPanel 不进入通用拖动接管；只安装 no-detach 顶部手柄并恢复已保存位置。
local function installSettingsPanelPositionGuard()
  local frame = _G[SETTINGS_PANEL_KEY] -- 系统选项根框体
  if not frame then
    return
  end
  if not frame.__azerothCompanion_mm_settingsGuard then
    if frame.HookScript then
      pcall(function()
        frame:HookScript("OnShow", function(self)
          applySettingsPanelSafeDrag(self)
        end)
      end)
    end
    frame.__azerothCompanion_mm_settingsGuard = true
  end
  applySettingsPanelSafeDrag(frame)
end

local addonLoadedHookInstalled = false
local addonLoadedHookFrame = nil  -- 持久监听 Frame，禁用时 UnregisterEvent
local universalShowUIPanelHookInstalled = false
local hideUIPanelHookInstalled = false
local enteringWorldHookInstalled = false
local enteringWorldHookFrame = nil  -- 持久监听 Frame，禁用时 UnregisterEvent
local worldMapSafeDragHookInstalled = false

--- 经 ShowUIPanel 打开的顶层界面：尽可能全部挂接（排除受保护名单），行为接近 BlizzMove 类插件。
local function installUniversalShowUIPanelHook()
  if universalShowUIPanelHookInstalled or not hooksecurefunc then
    return
  end
  local ok = pcall(function()
    hooksecurefunc("ShowUIPanel", function(frame)
      if not blizzardDragEnabled() then
        return
      end
      if not frame or not frame.GetName or not frame.HookScript then
        return
      end
      local name = frame:GetName()
      if not name or name == "" then
        return
      end
      if not isTrackedBlizzardPanelName(name) or isBlizzardPanelDragDenied(name) then
        return
      end
      if not hooked[name] then
        attachBlizzardOnShow(name, frame)
      end
      pcall(function()
        ensureBlizzardPanelApplied(frame, name)
      end)
      schedulePostShowPanelRestore()
    end)
  end)
  if ok then
    universalShowUIPanelHookInstalled = true
  end
end

--- 世界地图专用路径：等待 Blizzard OnShow 完成后再最小化并绑定标题拖动。
local function installWorldMapSafeDragHook()
  if worldMapSafeDragHookInstalled then
    return
  end
  local frame = _G[WORLD_MAP_PANEL_KEY] -- 世界地图根框体
  if not frame or not frame.HookScript then
    return
  end
  local hookOk = pcall(function()
    frame:HookScript("OnShow", function(self)
      pcall(function()
        applyWorldMapFrameSafeDrag(self)
      end)
    end)
  end)
  if not hookOk then
    return
  end
  worldMapSafeDragHookInstalled = true
  if frame.IsShown and frame:IsShown() then
    pcall(function()
      applyWorldMapFrameSafeDrag(frame)
    end)
  end
end

--- HideUIPanel 后其余仍可见的面板也可能被重排，补断言存档位置。
local function installHideUIPanelHook()
  if hideUIPanelHookInstalled or not hooksecurefunc then
    return
  end
  local ok = pcall(function()
    hooksecurefunc("HideUIPanel", function()
      if not blizzardDragEnabled() then
        return
      end
      --- Hide 后其余可见面板可能被重排；After(0) 下一帧合并补正（主路径为 hook）。
      C_Timer.After(0, function()
        if blizzardDragEnabled() then
          restoreAllVisibleTrackedPanelsIfMisplaced()
        end
      end)
    end)
  end)
  if ok then
    hideUIPanelHookInstalled = true
  end
end

--- ADDON_LOADED / PLAYER_ENTERING_WORLD 共用：补挂待处理面板并刷新可见面板。
local function runLazyHookRefresh()
  if not isMoverEnabled() then
    return
  end
  tryHookPendingPanels()
  installWorldMapSafeDragHook()
  installGuildPanelPositionGuard()
  installSettingsPanelPositionGuard()
  applyVisibleBlizzardPanels()
  applyWorldMapFrameSafeDrag(_G[WORLD_MAP_PANEL_KEY])
end

local function installAddonLoadedHook()
  if addonLoadedHookInstalled then
    return
  end
  addonLoadedHookInstalled = true
  addonLoadedHookFrame = CreateFrame("Frame", "AzerothCompanionMoverLazyHook", UIParent)
  addonLoadedHookFrame:RegisterEvent("ADDON_LOADED")
  addonLoadedHookFrame:SetScript("OnEvent", runLazyHookRefresh)
end

local function installEnteringWorldHook()
  if enteringWorldHookInstalled then
    return
  end
  enteringWorldHookInstalled = true
  enteringWorldHookFrame = CreateFrame("Frame", "AzerothCompanionMoverPEWHook", UIParent)
  enteringWorldHookFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
  enteringWorldHookFrame:SetScript("OnEvent", runLazyHookRefresh)
end

local function installLazyBlizzardHooks()
  installAddonLoadedHook()
  installGlobalUIPanelPositionGuard()
  installUniversalShowUIPanelHook()
  installHideUIPanelHook()
  installWorldMapSafeDragHook()
  installEnteringWorldHook()
end

local function blizzardRunHooks()
  if not isMoverEnabled() then
    return
  end
  installTabSwitchHook()
  installLazyBlizzardHooks()
  tryHookPendingPanels()
  installGuildPanelPositionGuard()
  installSettingsPanelPositionGuard()
  applyVisibleBlizzardPanels()
  applyWorldMapFrameSafeDrag(_G[WORLD_MAP_PANEL_KEY])
end

--- 供设置页：命中模式等变更后，重绑已登记自建窗并刷新当前可见暴雪窗。
function AzerothCompanion.Modules.Mover.RefreshDragConfiguration()
  refreshAddonRegisteredFramesOnly()
  if blizzardDragEnabled() then
    applyVisibleBlizzardPanels()
    applyWorldMapFrameSafeDrag(_G[WORLD_MAP_PANEL_KEY])
    installGuildPanelPositionGuard()
    installSettingsPanelPositionGuard()
  else
    disableWorldMapFrameSafeDrag()
    disableGuildPanelSafeDrag()
    disableSettingsPanelSafeDrag()
  end
end

--- 供设置页与旧 API 刷新：重新尝试懒加载 Hook 与当前可见面板的拖动应用。
function AzerothCompanion.Modules.Mover.BlizzardPanelsRefresh()
  blizzardRunHooks()
  refreshAddonRegisteredFramesOnly()
end

--- 应用模块启用状态，不负责输出聊天提示。
---@param enabled boolean 是否启用窗口拖动
local function applyMoverEnabledState(enabled)
  if enabled then
    -- 重新挂接事件监听（禁用时已注销）
    if addonLoadedHookFrame then
      addonLoadedHookFrame:RegisterEvent("ADDON_LOADED")
    end
    if enteringWorldHookFrame then
      enteringWorldHookFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    end
    blizzardRunHooks()
    refreshAddonRegisteredFramesOnly()
  else
    -- 持久监听 Frame 禁用时注销，避免模块关闭后仍触发回调
    if addonLoadedHookFrame then
      addonLoadedHookFrame:UnregisterEvent("ADDON_LOADED")
    end
    if enteringWorldHookFrame then
      enteringWorldHookFrame:UnregisterEvent("PLAYER_ENTERING_WORLD")
    end
    disableVisibleBlizzardPanels()
    disableWorldMapFrameSafeDrag()
    disableGuildPanelSafeDrag()
    disableSettingsPanelSafeDrag()
    disableAddonRegisteredFrames()
  end
end

AzerothCompanion.RegisterModule({
  id = MODULE_ID,
  nameKey = "MODULE_MOVER",
  settingsOrder = 20,
  OnModuleLoad = function() end,
  OnModuleEnable = function()
    blizzardRunHooks()
    refreshAddonRegisteredFramesOnly()
  end,
  OnEnabledSettingChanged = function(enabled)
    local localeTable = AzerothCompanion.Localization.Strings or {}
    local key = enabled and "SETTINGS_MODULE_ENABLED_FMT" or "SETTINGS_MODULE_DISABLED_FMT"
    AzerothCompanion.API.Chat.PrintAddonMessage(string.format(localeTable[key] or "%s", localeTable.MODULE_MOVER or MODULE_ID))
    applyMoverEnabledState(enabled == true)
  end,
  OnDebugSettingChanged = function(enabled)
    local localeTable = AzerothCompanion.Localization.Strings or {}
    local key = enabled and "SETTINGS_MODULE_DEBUG_ON_FMT" or "SETTINGS_MODULE_DEBUG_OFF_FMT"
    AzerothCompanion.API.Chat.PrintAddonMessage(string.format(localeTable[key] or "%s", localeTable.MODULE_MOVER or MODULE_ID))
  end,
  ResetToDefaultsAndRebuild = function()
    resetMoverSettings()
    blizzardRunHooks()
    refreshAddonRegisteredFramesOnly()
  end,
  RegisterSettings = function(box)
    local localeTable = AzerothCompanion.Localization.Strings or {} -- 本地化文案

    box:AddChoiceRow({
      label = localeTable.MOVER_SETTINGS_HIT_TITLE or "",
      description = localeTable.MOVER_SETTINGS_HIT_SUB or "",
      buttonWidth = 132,
      refreshMode = "local",
      options = {
        { value = HIT_DISABLED, label = localeTable.MOVER_SETTINGS_HIT_DISABLED or "" },
        { value = HIT_TITLEBAR, label = localeTable.MOVER_SETTINGS_HIT_TITLEBAR or "" },
        { value = HIT_TITLEBAR_EMPTY, label = localeTable.MOVER_SETTINGS_HIT_TITLEBAR_EMPTY or "" },
      },
      getValue = function()
        if not isMoverEnabled() then
          return HIT_DISABLED
        end
        return normalizeDragHitMode(getMoverSetting("MOVER_DRAG_HIT_MODE", HIT_TITLEBAR))
      end,
      setValue = function(value)
        if value == HIT_DISABLED then
          setMoverSetting("MOVER_ENABLED", false)
        else
          setMoverSetting("MOVER_ENABLED", true)
          setMoverSetting("MOVER_DRAG_HIT_MODE", normalizeDragHitMode(value))
        end
      end,
      afterChange = function(value)
        if value == HIT_DISABLED then
          applyMoverEnabledState(false)
        else
          applyMoverEnabledState(true)
          AzerothCompanion.Modules.Mover.RefreshDragConfiguration()
        end
      end,
    })

    box:AddToggleRow({
      label = localeTable.MOVER_SETTINGS_COMBAT_CHECK or "",
      description = localeTable.MOVER_SETTINGS_COMBAT_SUB or "",
      refreshMode = "local",
      enabledWhen = function()
        return isMoverEnabled()
      end,
      getValue = function()
        return getMoverSetting("MOVER_ALLOW_DRAG_IN_COMBAT", false) == true
      end,
      setValue = function(value)
        setMoverSetting("MOVER_ALLOW_DRAG_IN_COMBAT", value == true)
      end,
    })
  end,
})
