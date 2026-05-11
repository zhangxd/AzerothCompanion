--[[
  RegisterModule：各 Modules/*.lua 在加载时调用，仅登记定义。
  Bootstrap 在 ADDON_LOADED 里 RunOnModuleLoad，PLAYER_LOGIN 里 RunOnModuleEnable。
  dependencies 用于拓扑排序：被依赖的模块先执行。
  模块定义可含 nameKey（对应 AzerothCompanion.Localization.Strings 键），由 SettingsHost 显示本地化标题。
  设置页相关约定：
  - settingsIntroKey：页面简介文案键
  - settingsOrder：子页面顺序（数字越小越靠前）
  - RegisterSettings(box)：仅绘制模块专属设置区
  - GetSettingsPages()：返回额外设置子页面定义列表；每项至少含 `id`、`titleKey`、`build(page, box)`
  - OnEnabledSettingChanged(enabled)：公共启用开关变化后同步模块状态
  - OnDebugSettingChanged(enabled)：公共调试开关变化后同步模块状态
  - ResetToDefaultsAndRebuild()：模块级完整重置与重建入口；页面级恢复默认可按需调用
]]

local list = {}

function AzerothCompanion.RegisterModule(def)
  assert(type(def) == "table" and def.id, "AzerothCompanion.RegisterModule: need def.id")
  list[#list + 1] = def
end

local function indexById()
  local t = {}
  for _, m in ipairs(list) do
    t[m.id] = m
  end
  return t
end

-- 依赖先出队：DFS + visiting 防环（环内依赖本实现不展开，仅防死循环）
local function topoSort()
  local byId = indexById()
  local sorted = {}
  local visiting = {}
  local visited = {}
  local circularDeps = {}

  local function visit(id)
    if visited[id] then
      return
    end
    local m = byId[id]
    if not m then
      return
    end
    if visiting[id] then
      -- 检测到环，记录警告
      if not circularDeps[id] then
        circularDeps[id] = true
      end
      return
    end
    visiting[id] = true
    if m.dependencies then
      for _, dep in ipairs(m.dependencies) do
        visit(dep)
      end
    end
    visiting[id] = nil
    visited[id] = true
    sorted[#sorted + 1] = m
  end

  for _, m in ipairs(list) do
    visit(m.id)
  end

  -- 输出环检测警告
  if next(circularDeps) then
    local configTable = AzerothCompanion.Config or nil -- 配置入口
    local settingIdTable = configTable and configTable.SettingId or nil -- 设置 ID 表
    local debugSettingId = type(settingIdTable) == "table" and settingIdTable.GLOBAL_DEBUG or nil -- 全局调试设置 ID
    local debugEnabled = type(configTable) == "table" and type(configTable.Get) == "function" and debugSettingId and configTable.Get(debugSettingId, "account") == true -- 全局调试开关
    if debugEnabled then
      local logPrefix = AzerothCompanion.ADDON_LOG_PREFIX or "[AzerothCompanion]" -- 统一诊断前缀
      for moduleId in pairs(circularDeps) do
        print(string.format("%s Warning: circular dependency detected for module '%s'", logPrefix, moduleId))
      end
    end
  end

  return sorted
end

AzerothCompanion.ModuleRegistry = {}

function AzerothCompanion.ModuleRegistry:GetSorted()
  return topoSort()
end

function AzerothCompanion.ModuleRegistry:RunOnModuleLoad()
  AzerothCompanion_NamespaceEnsure()
  for _, m in ipairs(self:GetSorted()) do
    if m.OnModuleLoad then
      m.OnModuleLoad()
    end
  end
end

function AzerothCompanion.ModuleRegistry:RunOnModuleEnable()
  AzerothCompanion_NamespaceEnsure()
  for _, m in ipairs(self:GetSorted()) do
    if m.OnModuleEnable then
      m.OnModuleEnable()
    end
  end
end
