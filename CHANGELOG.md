# Changelog / 更新记录

## 0.1.4 - Route Reliability / 路线可靠性

### English

#### Highlights

- Route planning now distinguishes between reliable routes and lower-confidence fallback suggestions.
- Uncertain public transport conditions are no longer presented as fully reliable routes.
- When a fully reliable route cannot be confirmed, the addon now makes that limitation clear instead of overstating the result.

#### Details

- Route planning prioritizes paths that can be confirmed for the current character.
- Public transport routes with incomplete condition data are now treated more conservatively.
- In edge cases, the addon may offer a lower-confidence fallback route instead of presenting uncertain data as guaranteed.
- Messaging around unavailable or uncertain routes has been refined to better match what the addon can currently verify.

#### Compatibility

- Supports World of Warcraft Retail 12.0.0 / 12.0.1 / 12.0.7.

### 中文

#### 本次重点

- 地图导航现在会区分可靠路线与低置信度的兜底建议。
- 不再把条件不确定的公共交通路线直接当作可靠路线展示。
- 当插件暂时无法确认完全可靠的路线时，会更明确地提示当前限制，而不是把结果说得过满。

#### 详细说明

- 路线规划会优先使用当前角色可以确认可用的路径。
- 对条件数据不完整的公共交通路线，现在会采用更保守的展示方式。
- 在少数边界场景下，插件可能给出低置信度的兜底建议，而不会把不确定数据当成必然可达。
- 无法确认或暂时不可规划的情况会用更直观的提示说明当前状态。

#### 兼容性

- 支持魔兽世界正式服 Retail 12.0.0 / 12.0.1 / 12.0.7。
