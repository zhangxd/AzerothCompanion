--[[
  冒险指南副本列表锁定叠加私有实现。
]]

local Internal = AzerothCompanion.Modules.EncounterJournal.Internal -- 冒险指南内部命名空间
local Runtime = Internal.Runtime

local function getCurrentScrollBox()
  return Internal.GetCurrentScrollBox()
end

local function getJournalInstanceID(elementData)
  return Internal.GetJournalInstanceID(elementData)
end

local function formatResetTime(seconds)
  return Internal.FormatResetTime(seconds)
end

local function isOverlayEnabled()
  return Internal.IsOverlayEnabled()
end

local LockoutOverlay = {}

local OVERLAY_FS_KEY = "_AzerothCompanionLockoutFS"

--- 检查是否启用
---@return boolean
function LockoutOverlay:isEnabled()
  return isOverlayEnabled()
end

--- 创建 FontString
---@param frame table
---@return table fontString
function LockoutOverlay:createFontString(frame)
  local fontStr = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  -- 锚定到 frame 的左下角
  fontStr:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 4, 4)
  fontStr:SetPoint("RIGHT", frame, "RIGHT", -4, 0)
  fontStr:SetJustifyH("LEFT")
  fontStr:SetJustifyV("BOTTOM")

  return fontStr
end

--- 渲染锁定文字
---@param frame table
---@param lockouts table[]
function LockoutOverlay:renderLockoutText(frame, lockouts)
  local fontString = frame[OVERLAY_FS_KEY]
  if not fontString then
    fontString = self:createFontString(frame)
    frame[OVERLAY_FS_KEY] = fontString
  end

  if #lockouts > 0 then
    local lines = {}
    for _, lockout in ipairs(lockouts) do
      local timeStr = formatResetTime(lockout.resetTime or 0)
      local line
      if lockout.isRaid then
        line = string.format("|cffFFD700%s %d/%d %s|r",
          lockout.difficultyName or "", lockout.encounterProgress or 0, lockout.numEncounters or 0, timeStr)
      else
        line = string.format("|cffFFD700%s %s|r", lockout.difficultyName or "", timeStr)
      end
      table.insert(lines, line)
    end
    fontString:SetText(table.concat(lines, "\n"))
    fontString:Show()
  else
    fontString:SetText("")
    fontString:Hide()
  end
end

--- 更新所有 frame 的锁定显示
function LockoutOverlay:updateFrames()
  if not self:isEnabled() then
    self:clearAllFrames()
    return
  end
  if type(AzerothCompanion.API.EncounterJournal.IsRaidOrDungeonInstanceListTab) ~= "function" then
    self:clearAllFrames()
    return
  end
  if AzerothCompanion.API.EncounterJournal.IsRaidOrDungeonInstanceListTab() ~= true then
    self:clearAllFrames()
    return
  end

  local box = getCurrentScrollBox()
  if not box or type(box.ForEachFrame) ~= "function" then return end

  pcall(function()
    box:ForEachFrame(function(frame)
      if not frame or not frame.GetElementData then return end
      local success, elementData = pcall(function() return frame:GetElementData() end)
      if not success or not elementData then return end
      local jid = getJournalInstanceID(elementData)
      if not jid then return end

      local lockouts = AzerothCompanion.API.EncounterJournal.GetAllLockoutsForInstance(jid)
      self:renderLockoutText(frame, lockouts)
    end)
  end)
end

--- 清理所有可见列表项上的锁定叠加文本（用于关闭功能时立即去残留）
function LockoutOverlay:clearAllFrames()
  local box = getCurrentScrollBox()
  if not box or type(box.ForEachFrame) ~= "function" then return end

  pcall(function()
    box:ForEachFrame(function(frame)
      if not frame then return end
      local fontString = frame[OVERLAY_FS_KEY]
      if fontString then
        fontString:SetText("")
        fontString:Hide()
      end
    end)
  end)
end

--- Hook frame tooltip
local hookedFrames = setmetatable({}, {__mode = "k"})

function LockoutOverlay:hookTooltips()
  local box = getCurrentScrollBox()
  if not box or type(box.ForEachFrame) ~= "function" then return end

  pcall(function()
    box:ForEachFrame(function(frame)
      if not frame or hookedFrames[frame] then return end
      if not frame.HookScript then return end
      hookedFrames[frame] = true
      frame:HookScript("OnEnter", function(self)
        if not isOverlayEnabled() then return end
        if type(AzerothCompanion.API.EncounterJournal.IsRaidOrDungeonInstanceListTab) ~= "function" then return end
        if AzerothCompanion.API.EncounterJournal.IsRaidOrDungeonInstanceListTab() ~= true then return end
        local success, elementData = pcall(function() return self:GetElementData() end)
        if not success or not elementData then return end
        local jid = getJournalInstanceID(elementData)
        if not jid then return end

        local lockouts = AzerothCompanion.API.EncounterJournal.GetAllLockoutsForInstance(jid)
        if #lockouts == 0 then return end

        local loc = AzerothCompanion.Localization.Strings or {}
        Runtime.TooltipAddLine(GameTooltip, " ")
        for _, lockout in ipairs(lockouts) do
          local timeStr = formatResetTime(lockout.resetTime or 0)
          local resetLabel = string.format(loc.EJ_LOCKOUT_RESET_FMT or "%s - Resets in: %s",
            lockout.difficultyName or "", timeStr)
          if lockout.isExtended then
            resetLabel = resetLabel .. " " .. (loc.EJ_LOCKOUT_EXTENDED or "(Extended)")
          end
          Runtime.TooltipAddLine(GameTooltip, resetLabel, 1, 0.8, 0)
          if lockout.isRaid and (lockout.numEncounters or 0) > 0 then
            local progressLabel = string.format(loc.EJ_LOCKOUT_PROGRESS_FMT or "Progress: %d / %d bosses",
              lockout.encounterProgress or 0, lockout.numEncounters or 0)
            Runtime.TooltipAddLine(GameTooltip, progressLabel, 0.8, 0.8, 0.8)
            local killed = AzerothCompanion.API.EncounterJournal.GetKilledBosses(jid, lockout.difficultyID)
            for _, boss in ipairs(killed) do
              Runtime.TooltipAddLine(GameTooltip, "  " .. (boss.name or ""), 0.6, 0.6, 0.6)
            end
          end
        end
        Runtime.TooltipShow(GameTooltip)
      end)
    end)
  end)
end

Internal.LockoutOverlay = LockoutOverlay
