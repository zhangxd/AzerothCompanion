--[[
  聊天（领域对外 API）（AzerothCompanion.API.Chat）：默认聊天框输出、插件 TOC 元数据读取、默认聊天框最近内容复制到剪贴板。
  凡面向玩家的聊天框展示须经本文件 API；业务逻辑放在各模块，勿在此处堆存档分支。
]]

AzerothCompanion.API = AzerothCompanion.API or {}
AzerothCompanion.API.Chat = AzerothCompanion.API.Chat or {}

local ACCOUNT_SCOPE = "account" -- 账号级设置 scope

--- 读取聊天输出设置。
---@param settingName string SettingId 字段名
---@param fallbackValue any 兜底值
---@return any
local function getChatSetting(settingName, fallbackValue)
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

--- 去掉一行聊天文本中的常见颜色、物品链接等标记，便于粘贴到外部编辑器。
---@param text string|nil
---@return string
local function stripChatFormattingForClipboard(text)
  if type(text) ~= "string" then
    return ""
  end
  if type(canaccessvalue) == "function" then
    local ok, accessible = pcall(canaccessvalue, text) -- 当前执行上下文是否可安全访问该值
    if not ok or accessible == false then
      return ""
    end
  end
  if text == "" then
    return ""
  end
  local s = text
  s = s:gsub("|c%x%x%x%x%x%x%x%x", "")  -- 颜色开始
  s = s:gsub("|r", "")                   -- 颜色重置
  s = s:gsub("|H[^|]+|h(.-)|h", "%1")    -- 超链接（保留文本）
  s = s:gsub("|T.-|t", "")               -- 纹理图标
  s = s:gsub("|K.-|k", "")               -- 按键绑定
  s = s:gsub("|A.-|a", "")               -- Atlas 纹理
  s = s:gsub("|n", "\n")                 -- 换行符
  return s
end

--- 创建聊天复制备用窗口（仅首次调用时创建）
---@return table
local function createCopyTextFallbackFrame()
  AzerothCompanion_NamespaceEnsure()
  local localeTable = AzerothCompanion.Localization.Strings or {}
  local name = "AzerothCompanionChatCopyFallbackFrame"

  local f = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
  f:SetSize(520, 360)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  f:SetFrameStrata("DIALOG")
  f:SetFrameLevel(400)
  f:Hide()
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self)
    self:StartMoving()
  end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
  end)

  pcall(function()
    f:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true,
      tileSize = 32,
      edgeSize = 32,
      insets = { left = 8, right = 8, top = 10, bottom = 8 },
    })
    f:SetBackdropColor(0, 0, 0, 0.92)
  end)

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", f, "TOP", 0, -14)
  f._title = title

  local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  hint:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -42)
  hint:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, -42)
  hint:SetJustifyH("LEFT")
  hint:SetWordWrap(true)
  f._hint = hint

  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -72)
  scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 48)

  local eb = CreateFrame("EditBox", nil, scroll)
  eb:SetMultiLine(true)
  eb:SetFontObject(ChatFontNormal)
  eb:SetWidth(440)
  eb:SetHeight(2000)
  eb:SetAutoFocus(false)
  eb:SetTextInsets(6, 6, 6, 6)
  scroll:SetScrollChild(eb)
  f._eb = eb

  local closeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  closeBtn:SetSize(120, 24)
  closeBtn:SetPoint("BOTTOM", f, "BOTTOM", 0, 14)
  f._closeBtn = closeBtn
  closeBtn:SetScript("OnClick", function()
    f:Hide()
  end)

  f:EnableKeyboard(true)
  pcall(function()
    f:SetPropagateKeyboardInput(false)
  end)
  f:SetScript("OnKeyDown", function(self, key)
    if key == "ESCAPE" then
      self:Hide()
    end
  end)
  f:SetScript("OnShow", function(self)
    local eb2 = self._eb
    if eb2 then
      C_Timer.After(0, function()
        if self:IsShown() and eb2 then
          eb2:SetFocus()
          pcall(function()
            eb2:HighlightText(0, -1)
          end)
        end
      end)
    end
  end)

  _G[name] = f
  return f
end

--- 无 `C_CopyText` 或调用失败时：弹出多行输入框并全选，供玩家 Ctrl+C 复制。
---@param plainText string
---@return boolean ok
local function openCopyTextFallbackWindow(plainText)
  local name = "AzerothCompanionChatCopyFallbackFrame"
  local f = _G[name]
  if not f then
    f = createCopyTextFallbackFrame()
  end

  local localeTable = AzerothCompanion.Localization.Strings or {}
  f._title:SetText(localeTable.CHAT_COPY_WINDOW_TITLE or "Copy")
  f._hint:SetText(localeTable.CHAT_COPY_WINDOW_HINT or "")
  f._closeBtn:SetText(localeTable.CHAT_COPY_WINDOW_CLOSE or "Close")
  f._eb:SetText(plainText or "")
  f:Show()
  return true
end

--- 将默认聊天框（`DEFAULT_CHAT_FRAME`）中最近若干条消息拼成纯文本：优先 `C_CopyText`，否则打开复制窗口。
---@param maxLines number|nil 最多条数，默认 30，上限 200
---@return boolean ok
---@return string|nil resultKey 成功时：`"CHAT_COPY_SUCCESS"` 表示已写入剪贴板；`"CHAT_COPY_FALLBACK"` 表示已打开备用窗口。失败时为 `"CHAT_COPY_ERR_*"`
function AzerothCompanion.API.Chat.CopyDefaultChatToClipboard(maxLines)
  maxLines = tonumber(maxLines) or 30
  if maxLines < 1 then
    maxLines = 1
  end
  if maxLines > 200 then
    maxLines = 200
  end
  local f = _G.DEFAULT_CHAT_FRAME
  if not f or not f.GetNumMessages or not f.GetMessageInfo then
    return false, "CHAT_COPY_ERR_NO_FRAME"
  end
  local n = f:GetNumMessages()
  local parts = {}
  if n >= 1 then
    local startIndex = math.max(1, n - maxLines + 1)
    for i = startIndex, n do
      local text = f:GetMessageInfo(i)
      local plainText = stripChatFormattingForClipboard(text) -- 已过滤 secret value 的安全文本
      if plainText ~= "" then
        parts[#parts + 1] = plainText
      end
    end
  end
  local joined = table.concat(parts, "\n")

  if C_CopyText then
    local ok = pcall(C_CopyText, joined)
    if ok then
      return true, "CHAT_COPY_SUCCESS"
    end
  end

  local ok2 = pcall(openCopyTextFallbackWindow, joined)
  if ok2 then
    return true, "CHAT_COPY_FALLBACK"
  end
  return false, "CHAT_COPY_ERR_FAILED"
end

--- 读取插件 TOC 元数据；正式服优先使用 `C_AddOns.GetAddOnMetadata`，失败时回落旧全局。
---@param name string 插件目录 / TOC 技术名，如 `AzerothCompanion.ADDON_NAME`
---@param field string TOC 字段名，如 `"Version"`
---@return string|nil value 字段值；读取失败时为 nil
function AzerothCompanion.API.Chat.GetAddOnMetadata(name, field)
  if C_AddOns and C_AddOns.GetAddOnMetadata then
    local ok, v = pcall(C_AddOns.GetAddOnMetadata, name, field)
    if ok then
      return v
    end
  end
  if GetAddOnMetadata then
    local ok, v = pcall(GetAddOnMetadata, name, field)
    if ok then
      return v
    end
  end
  return nil
end

--- 在默认聊天框输出一行；前缀色与正文色来自聊天设置数字 ID。
---@param body string|nil 玩家可见正文；nil 或空字符串时不输出
function AzerothCompanion.API.Chat.PrintAddonMessage(body)
  if not body or body == "" then
    return
  end
  AzerothCompanion_NamespaceEnsure()

  local prefixColor = getChatSetting("CHAT_PREFIX_COLOR", "ffd700")
  local contentColor = getChatSetting("CHAT_CONTENT_COLOR", "ffffff")
  local addonDisplayName = (AzerothCompanion.Localization.Strings and AzerothCompanion.Localization.Strings.ADDON_DISPLAY_NAME) or AzerothCompanion.ADDON_DISPLAY_NAME or AzerothCompanion.ADDON_NAME or "AzerothCompanion" -- 聊天前缀显示名
  local prefix = string.format("|cff%s[%s]|r ", prefixColor, addonDisplayName)
  local bodyColored = string.format("|cff%s%s|r", contentColor, body)

  local f = DEFAULT_CHAT_FRAME
  if f and f.AddMessage then
    f:AddMessage(prefix .. bodyColored)
  end
end
