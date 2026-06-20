# 更新记录 / Changelog

## 0.1.3

### 中文

- 地图导航路线结果新增 `strict / reference / blocked` 证据等级，减少不确定路线被当作可靠路线的情况。
- 严格路线只使用当前角色可证明可用的边；未知公共传送条件和手动飞行 fallback 只在严格无解后作为参考路线。
- 规划诊断补充 `evidenceLevel`，方便反馈路线问题时区分可靠路线、参考路线和暂无可靠路线。
- 正式服兼容范围保持 Retail 12.0.0 / 12.0.1 / 12.0.7。

### English

- Route planning results now include `strict / reference / blocked` evidence levels, reducing cases where uncertain routes look fully reliable.
- Strict routes only use edges that can be proven usable by the current character; unknown public transport conditions and manual taxi fallback are only used as reference routes after strict routing fails.
- Planning diagnostics now include `evidenceLevel`, making route reports easier to separate into reliable routes, reference routes, and no currently reliable route.
- Retail compatibility remains Retail 12.0.0 / 12.0.1 / 12.0.7.
