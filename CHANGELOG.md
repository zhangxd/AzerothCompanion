# Changelog / 更新记录

## 0.1.4 - Route Reliability / 路线可靠性

### English

#### Highlights

- Route planning now reports `strict`, `reference`, or `blocked` evidence levels.
- Uncertain public transport conditions are no longer presented as fully reliable routes.
- If strict routing fails, the addon may provide a reference route or report that no reliable route is currently available.

#### Details

- `strict`: only uses route edges proven usable by the current character.
- `reference`: may include unknown public transport conditions or manual taxi fallback.
- `blocked`: no route has enough structured evidence yet.
- Planning diagnostics now include `evidenceLevel` to make route reports easier to debug.

#### Compatibility

- Supports World of Warcraft Retail 12.0.0 / 12.0.1 / 12.0.7.

### 中文

#### 本次重点

- 地图导航路线现在会标记 `strict / reference / blocked` 证据等级。
- 不再把条件不确定的公共交通路线直接当作可靠路线展示。
- 严格路线无解时，插件可能给出参考路线，或提示当前暂无可靠路线。

#### 详细说明

- `strict`：只使用当前角色可证明可用的路线边。
- `reference`：可能包含未知公共交通条件或手动飞行 fallback。
- `blocked`：当前缺少足够结构化证据，无法给出可靠路线。
- 规划诊断新增 `evidenceLevel`，方便反馈和排查路线问题。

#### 兼容性

- 支持魔兽世界正式服 Retail 12.0.0 / 12.0.1 / 12.0.7。
