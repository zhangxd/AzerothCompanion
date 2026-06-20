--[[
@summary navigation V6 能力模板（炉石运行时解析；职业 fixed_node 由 PlayerCondition 与 waypoint 结构化落点两阶段推导并通过可路由校验）
@body_md5 f6eeb372526440b2e187db78ace6bdbc
]]

AzerothCompanion.Data = AzerothCompanion.Data or {}

AzerothCompanion.Data.NavigationAbilityTemplates = {
  schemaVersion = 6,
  sourceMode = "live",
  generatedAt = "2026-05-17T16:10:19Z",

  templates = {
    ["spell_3561"] = { TemplateID = "spell_3561", Mode = "class_teleport", SpellID = 3561, ClassFile = "MAGE", FactionGroup = nil, TargetRuleKind = "fixed_node", ToNodeID = 82, Label = "传送：暴风城", SelfUseOnly = true },
    ["spell_3562"] = { TemplateID = "spell_3562", Mode = "class_teleport", SpellID = 3562, ClassFile = "MAGE", FactionGroup = nil, TargetRuleKind = "fixed_node", ToNodeID = 85, Label = "传送：铁炉堡", SelfUseOnly = true },
    ["spell_3563"] = { TemplateID = "spell_3563", Mode = "class_teleport", SpellID = 3563, ClassFile = "MAGE", FactionGroup = nil, TargetRuleKind = "fixed_node", ToNodeID = 16, Label = "传送：幽暗城", SelfUseOnly = true },
    ["spell_3565"] = { TemplateID = "spell_3565", Mode = "class_teleport", SpellID = 3565, ClassFile = "MAGE", FactionGroup = nil, TargetRuleKind = "fixed_node", ToNodeID = 60, Label = "传送：达纳苏斯", SelfUseOnly = true },
    ["spell_3566"] = { TemplateID = "spell_3566", Mode = "class_teleport", SpellID = 3566, ClassFile = "MAGE", FactionGroup = nil, TargetRuleKind = "fixed_node", ToNodeID = 86, Label = "传送：雷霆崖", SelfUseOnly = true },
    ["spell_3567"] = { TemplateID = "spell_3567", Mode = "class_teleport", SpellID = 3567, ClassFile = "MAGE", FactionGroup = nil, TargetRuleKind = "fixed_node", ToNodeID = 83, Label = "传送：奥格瑞玛", SelfUseOnly = true },
    ["spell_8690"] = { TemplateID = "spell_8690", Mode = "hearthstone", SpellID = 8690, ClassFile = nil, FactionGroup = nil, TargetRuleKind = "hearth_bind", ToNodeID = nil, Label = "炉石", SelfUseOnly = true },
    ["spell_10059"] = { TemplateID = "spell_10059", Mode = "class_portal", SpellID = 10059, ClassFile = "MAGE", FactionGroup = nil, TargetRuleKind = "fixed_node", ToNodeID = 82, Label = "传送门：暴风城", SelfUseOnly = true },
    ["spell_11416"] = { TemplateID = "spell_11416", Mode = "class_portal", SpellID = 11416, ClassFile = "MAGE", FactionGroup = nil, TargetRuleKind = "fixed_node", ToNodeID = 85, Label = "传送门：铁炉堡", SelfUseOnly = true },
    ["spell_11417"] = { TemplateID = "spell_11417", Mode = "class_portal", SpellID = 11417, ClassFile = "MAGE", FactionGroup = nil, TargetRuleKind = "fixed_node", ToNodeID = 83, Label = "传送门：奥格瑞玛", SelfUseOnly = true },
    ["spell_11418"] = { TemplateID = "spell_11418", Mode = "class_portal", SpellID = 11418, ClassFile = "MAGE", FactionGroup = nil, TargetRuleKind = "fixed_node", ToNodeID = 16, Label = "传送门：幽暗城", SelfUseOnly = true },
    ["spell_11419"] = { TemplateID = "spell_11419", Mode = "class_portal", SpellID = 11419, ClassFile = "MAGE", FactionGroup = nil, TargetRuleKind = "fixed_node", ToNodeID = 60, Label = "传送门：达纳苏斯", SelfUseOnly = true },
    ["spell_11420"] = { TemplateID = "spell_11420", Mode = "class_portal", SpellID = 11420, ClassFile = "MAGE", FactionGroup = nil, TargetRuleKind = "fixed_node", ToNodeID = 86, Label = "传送门：雷霆崖", SelfUseOnly = true },
    ["spell_32266"] = { TemplateID = "spell_32266", Mode = "class_portal", SpellID = 32266, ClassFile = "MAGE", FactionGroup = nil, TargetRuleKind = "fixed_node", ToNodeID = 100, Label = "传送门：埃索达", SelfUseOnly = true },
    ["spell_32271"] = { TemplateID = "spell_32271", Mode = "class_teleport", SpellID = 32271, ClassFile = "MAGE", FactionGroup = nil, TargetRuleKind = "fixed_node", ToNodeID = 100, Label = "传送：埃索达", SelfUseOnly = true },
    ["spell_33690"] = { TemplateID = "spell_33690", Mode = "class_teleport", SpellID = 33690, ClassFile = "MAGE", FactionGroup = nil, TargetRuleKind = "fixed_node", ToNodeID = 108, Label = "传送：沙塔斯", SelfUseOnly = true },
    ["spell_33691"] = { TemplateID = "spell_33691", Mode = "class_portal", SpellID = 33691, ClassFile = "MAGE", FactionGroup = nil, TargetRuleKind = "fixed_node", ToNodeID = 108, Label = "传送门：沙塔斯", SelfUseOnly = true },
    ["spell_35715"] = { TemplateID = "spell_35715", Mode = "class_teleport", SpellID = 35715, ClassFile = "MAGE", FactionGroup = nil, TargetRuleKind = "fixed_node", ToNodeID = 108, Label = "传送：沙塔斯", SelfUseOnly = true },
    ["spell_35717"] = { TemplateID = "spell_35717", Mode = "class_portal", SpellID = 35717, ClassFile = "MAGE", FactionGroup = nil, TargetRuleKind = "fixed_node", ToNodeID = 108, Label = "传送门：沙塔斯", SelfUseOnly = true },
    ["spell_49358"] = { TemplateID = "spell_49358", Mode = "class_teleport", SpellID = 49358, ClassFile = "MAGE", FactionGroup = nil, TargetRuleKind = "fixed_node", ToNodeID = 40, Label = "传送：斯通纳德", SelfUseOnly = true },
    ["spell_49359"] = { TemplateID = "spell_49359", Mode = "class_teleport", SpellID = 49359, ClassFile = "MAGE", FactionGroup = nil, TargetRuleKind = "fixed_node", ToNodeID = 68, Label = "传送：塞拉摩", SelfUseOnly = true },
    ["spell_49360"] = { TemplateID = "spell_49360", Mode = "class_portal", SpellID = 49360, ClassFile = "MAGE", FactionGroup = nil, TargetRuleKind = "fixed_node", ToNodeID = 68, Label = "传送门：塞拉摩", SelfUseOnly = true },
    ["spell_49361"] = { TemplateID = "spell_49361", Mode = "class_portal", SpellID = 49361, ClassFile = "MAGE", FactionGroup = nil, TargetRuleKind = "fixed_node", ToNodeID = 40, Label = "传送门：斯通纳德", SelfUseOnly = true },
    ["spell_53140"] = { TemplateID = "spell_53140", Mode = "class_teleport", SpellID = 53140, ClassFile = "MAGE", FactionGroup = nil, TargetRuleKind = "fixed_node", ToNodeID = 122, Label = "传送：达拉然 - 诺森德", SelfUseOnly = true },
    ["spell_53142"] = { TemplateID = "spell_53142", Mode = "class_portal", SpellID = 53142, ClassFile = "MAGE", FactionGroup = nil, TargetRuleKind = "fixed_node", ToNodeID = 122, Label = "传送门：达拉然 - 诺森德", SelfUseOnly = true },
    ["spell_88342"] = { TemplateID = "spell_88342", Mode = "class_teleport", SpellID = 88342, ClassFile = "MAGE", FactionGroup = nil, TargetRuleKind = "fixed_node", ToNodeID = 236, Label = "传送：托尔巴拉德", SelfUseOnly = true },
    ["spell_88345"] = { TemplateID = "spell_88345", Mode = "class_portal", SpellID = 88345, ClassFile = "MAGE", FactionGroup = nil, TargetRuleKind = "fixed_node", ToNodeID = 236, Label = "传送门：托尔巴拉德", SelfUseOnly = true },
  },
}
