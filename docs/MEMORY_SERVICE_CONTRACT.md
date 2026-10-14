# Candid 记忆服务交接草案

版本：`candid-memory@4-draft`。更新：2026-10-14。

这份草案供 Agent/App 负责人和记忆服务负责人核对。当前运行仍使用 SQLite；下面的远程接口没有上线，也没有代替同事确定存储实现。阶段三已将 Agent 查询和 App 常规业务读写放到同一个本机适配入口，底层继续复用现有 Memory；事务、队列和文件工作流仍为本机原型。新增 read_evidence 与版本状态接口，远程的完整写入/工作流接入仍待真实协议。迁移时必须一起迁移同类数据的读写，不能让远程查询和本机写入形成两份库。

## 数据归属

| 数据 | 当前责任 | 交接边界 |
|---|---|---|
| Chat、Agent 任务、配置/Skill 快照、任务摘要 | Agent 后端 | 后续仍由 Agent 管理，不作为自动确认记忆 |
| 场合、场次、转写及其修订 | 本机 Memory | 建议同事服务承接统一读写，双方确认后实施 |
| 记忆草稿、确认条目、索引、证据版本 | 本机 Memory | 同事服务承接，确认与索引失效由同一服务处理 |
| 音频、上传文件、调研原文、报告 | Candid 资料存储 | 服务保存稳定资料引用；文件权限和删除同步由双方约定 |

用户身份来自 App 鉴权，后端把身份传给受信的服务客户端；模型工具参数不能指定或改变 `owner_id`。所有查询、证据读取、确认和删除都按该身份隔离。跨用户访问返回统一的不可访问状态，不暴露另一用户的条目内容。

## 统一返回格式

```json
{
  "status": "ok",
  "data": {"items": []},
  "sources": [],
  "error": null
}
```

资料返回的 `status` 为 `ok`、`empty`、`conflict`、`stale` 或 `error`。错误格式为 `{"code":"MEMORY_UNAVAILABLE","message":"暂时无法读取记忆","retryable":true}`。资料不存在/无权限、已删除、版本冲突、暂时不可用须可区分，但客户端和模型都不能收到供应商响应原文、Key 或签名 URL。

`sources` 中的 `source_id` 是稳定且带类型的资料标识；`source_version` 是不透明版本标识。来源还包含类型、原文片段、信任层级、更新时间及位置。音频位置使用全场偏移的整数毫秒；PDF 使用页码及片段 ID；网页包含读取日期、URL 和正文/摘要读取范围。修改正文时产生新版本，不能复用旧版本标识。模型引用旧版本时，产物显示其原版本。

信任层级保持现有规则：`L1_evidence` 为原始证据，`L2_inferred` 为 AI 推断，`L3_confirmed` 为用户确认。用户原话只是证据，不能自动升级为客观事实；匿名说话人标签不能自动归属本人。

## 业务操作草案

下列路径是远程服务的拟议路径；Candid 现有 `/v1/...` App 接口继续保留，由适配器转换。具体认证协议和端点地址待同事确认。

| 操作 | 拟议服务接口 | 输入与输出要求 |
|---|---|---|
| 场合创建/读取/修订 | `POST /occasions`、`GET/PATCH /occasions/{id}` | 幂等键、场景、目标、字段；返回版本；修订带预期版本 |
| 场次创建/读取 | `POST /sessions`、`GET /sessions/{id}` | 幂等键、关联场合、录音告知/同意、输入来源；返回稳定场次 ID |
| 场合与场次列表 | `GET /occasions`、`GET /sessions` | 游标、返回上限、场合过滤；排除示例和已归档项 |
| 转写版本写入 | `POST /sessions/{id}/transcripts` | 幂等键、原音频/任务引用、模型版本、全场时间、匿名说话人及本人归属状态 |
| 转写修订 | `POST /sessions/{id}/transcript-revisions` | 原版本、修订片段、修订人；新版本和受影响资料 ID；L1 原文不原地改写 |
| 条目搜索 | `POST /memory/search` | 查询、场合/场次过滤、信任层级、最多 6 条；可返回无结果、冲突或过期标记 |
| 证据读取 | `POST /evidence/read` | 来源 ID 与版本；最多 20 段证据、4 条推断；原文和推断分别返回 |
| 场合上下文 | `POST /context` | purpose、场合/场次、预算；返回可解释的入选与省略信息 |
| 提出草稿 | `POST /memory/drafts` | 幂等键、正文、来源版本、模型与 Skill 版本；仅建立 L2 草稿 |
| 用户确认/修订 | `POST /memory/{id}/confirm`、`PATCH /memory/{id}` | 用户明确操作、预期版本、修订正文；验证证据后建立/更新 L3 |
| 归档/删除 | `POST /memory/{id}/archive`、`DELETE /memory/{id}` | 当前用户操作、预期版本；同时处理索引、摘要引用失效和文件删除通知 |
| 版本状态查询 | `POST /references/status` | 最多 100 个来源 ID/版本；返回 current/superseded/deleted/inaccessible |
| 获取失效变更 | `GET /changes?after=...` | 持久化游标；修订/归档/删除事件和新版本；允许重放与去重 |

时间统一为 UTC ISO 8601，音频偏移为整数毫秒。正文引用必须来自实际读到的片段。列表上限由服务端执行；单条供模型使用的来源片段暂沿用 2,200 字符，不能把被截断的内容标记为完整正文。

## 搜索与证据样例

模型传入的业务参数只有查询和过滤条件，身份来自服务调用上下文：

```json
{"query":"客户沟通中的报价异议","occasion_id":"occasion-example","limit":6}
```

```json
{
  "status":"ok",
  "data":{"items":[{"id":"memory-example","version":2,"status":"confirmed","trust":"L3_confirmed","title":"报价异议的回应","text":"先确认客户比较的是总价还是交付范围。","evidence_refs":[{"source_id":"transcript:segment-example","source_version":"transcript-v1","session_id":"session-example","start_ms":12000,"end_ms":18000}]}]},
  "sources":[{"source_id":"transcript:segment-example","source_version":"transcript-v1","kind":"transcript","text":"我们先确认一下，你比较的是总价还是交付范围？","trust":"L1_evidence","session_id":"session-example","start_ms":12000,"end_ms":18000}],
  "error":null
}
```

无结果时使用 `status=empty`、`data.items=[]`，不能生成一条看起来像真实记忆的占位内容。当前 SQLite 适配器的来源还兼容 App 原有的 `ref`、`citation`、`title`、`text`、`trust` 字段；新增 `source_id` 与 `source_version` 不要求 App 立即修改。

## 写入、确认及失效样例

```json
{"client_request_id":"draft-request-example","body":{"text":"先确认客户比较的报价范围。"},"evidence_refs":[{"source_id":"transcript:segment-example","source_version":"transcript-v1"}],"producer":"candid:confirmed-text-model","skill_version":"memory_draft@1"}
```

草稿返回 `status=draft`、`trust=L2_inferred`、`version=1`。随后用户在 App 点击确认，Candid 后端凭用户身份调用确认接口：

```json
{"expected_version":1,"body":{"text":"先确认客户比较的报价范围。"}}
```

确认返回版本 2、`trust=L3_confirmed`、`confirmed_by` 和 `confirmed_at`。模型调用不能代替该用户操作。版本不符返回 `MEMORY_VERSION_CONFLICT`，不自动覆盖用户编辑。

证据修订后，变更事件示例为：

```json
{"change_id":"change-example","cursor":"cursor-example","kind":"evidence_revised","source_id":"transcript:segment-example","old_version":"transcript-v1","new_version":"transcript-v2","affected_memory_ids":["memory-example"],"at":"2026-10-13T15:00:00Z"}
```

记忆服务立即更新检索索引并标记依赖条目；Agent 收到事件后使相关摘要/检查点失效，在下一次回答或恢复任务前再核对来源状态。事件确认失败可以重放，按 `change_id` 去重。整库删除还须删除 Agent 侧聊天、任务和摘要，禁止用旧任务重新创建已删资料。

## 双方仍需核对

- 场合、场次、转写是否全部由同事服务承接，以及已有 SQLite 数据的迁移方式。
- 服务鉴权、URL、错误码和写入幂等键保存期限。
- 调研原文与音频的解析权限、保留期、文件删除回执和备份删除范围。
- 修订事件的投递方式与过期策略；跨段说话人标签合并及本人归属的用户确认流程。

上述事项是待核对的交接项，不影响当前本机文本 Agent 的模块拆分，也不表示远程记忆服务已接通。

## 阶段三本机约定补充

本机适配实现的来源版本是内容/状态 SHA256 指纹，格式为 sha256:<hash>；远程版本仍按不透明字符串约定，由远程适配器解释，不假定对方数据库使用相同算法。旧消息未保存可核对版本时返回 unverifiable，不能自动视为当前事实。

本机来源状态为 current、superseded、archived、stale、conflict、unverifiable、unavailable。跨用户或不存在的记录统一不可访问；没有明示时效不按年龄自动过期，conflict 需要明确元信息，本轮不实现语义矛盾检测。

Agent 摘要只存于 agent_summaries，属于 AI 整理的任务状态；修订或删除时清理受影响的摘要文本缓存，并核对活动流程的资料输入。Chat 历史仍是历史；整库删除覆盖这些 Agent 表。来源读写与删除仍需由同事服务共同承接后才能启用远程模式。

AgentSourceStore 提供后端资料保存和 research:<id> 引用；公开公司资料、用户输入和 AI 建议分别保留 material_kind 与 L1/L2，正文不得自动升级为个人确认事实。远程记忆草稿引用这些资料时，需要约定用户权限、解析端点与删除通知；目前同事尚未提供接口地址，因此此项保持待确认。

## 项目空间与两段式知识补充

四 A 的本机接口增加服务端 workspace_id：相关检索、原文读取与引用版本校验均按当前空间过滤，模型不能通过参数扩大范围。资料显式范围为 unassigned、spaces 或 personal；后两者分别携带多个稳定空间 ID 或表示通用个人资料。范围修订参与来源版本，旧摘要、引用与恢复检查点重新核对。用户自己的统一库继续保存原始录音，不按空间复制或移动。

第一段知识由七 A 在最终转写后产生：每项资料/信息/记忆候选绑定录音、片段和转写版本，原始证据与 AI 整理分开。项目空间按标签与范围读取，不能由候选解析自动伪造本人归属。

第二段由阶段六在项目归档后产生：Agent 提取空间中的可复用个人记忆、资料与信息。用户已选择直接自动确认为个人记忆，允许减少逐条确认；必须保存 AI 来源、原空间、原文依据、归档授权/策略引用和 archive_auto 确认方式。源于客户的特定信息继续带客户/项目标签，不能因进入个人库而在所有空间无条件检索。

本机自动确认路径已独立实现 personal_memories 表，保留 source=ai、producer、archive_workspace_id、归档授权所有者/时间和 confirmation_mode=archive_auto。插入触发器要求 archive:<workspace_id> 专用 actor，并验证该所有者已归档空间和自动确认策略。旧 L3 人工表保持 source=user 的保护。远程服务需承接此专用授权后才可切换，不能把模型产物伪装为用户逐条人工确认。原有用户主动确认路径继续有效，未授权的一般模型调用不得直接写入 L3。


## 本机阶段五至九接口

录音知识为 `knowledge:<id>`，自动个人资料为 `personal:<id>`，用户消息依据为 `message:<id>`。录音转写每次修订插入新的不可变分段，当前revision由session决定。知识只在当前revision有效；相关摘要/恢复来源不匹配时失效。个人记忆保留evidence_refs，原依据版本变化后检索返回冲突，不默默继续使用。编辑/撤回接口要求expected_version。

全局录音标签可关联多个空间；修改每条标签要求expected_revision，人为删除保留抑制记录。空间引用同一session，不复制原音频。原始知识和公司资料不自动提升为个人经历；归档分析把非本人来源保存为原空间范围的项目资料，只有直接本人依据允许通用个人标记。

App新增入口详见OpenAPI：materials/PDF、recordings/tags/transcript/self-speaker、business-jobs、personal-memories。导出和整库删除覆盖这些表、provider_runs及device_actions；远程替换须覆盖全部读写，不只替换Agent搜索。

资料产物的evidence_refs绑定原始内容指纹；Agent检索返回的引用额外绑定当前空间/标签范围指纹。读取会先检查当前空间权限，再接受匹配的内容指纹或完整范围指纹；旧Agent范围指纹不会因此被视作新范围。
