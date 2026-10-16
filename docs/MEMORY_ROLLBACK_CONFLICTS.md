# 记忆库页面回滚与后端合并待确认清单

2026-10-16。基线：当前 `6d7821d`；页面目标：用户本人提交的 `d8a85ca`（Add memory FAQ management and semantic question grouping）。用户已确认 **M1=B、M2=C、M3=B、M4=B、M5=B、M6=B、M7=C、M8=C**。以下选项文字保留为评审历史；执行状态以 [合并交付记录](MEMORY_MERGE_DELIVERY.md) 为准。

## 页面回滚阶段记录（合并前）

`RecordingUI.swift` 的记忆库 Tab 从 `CompanionMemory()` 切到 `LegacyCompanionMemory()`。已逐字核对：后者主体除类型名称外与 `d8a85ca` 的 `CompanionMemory` 完全一致；`CompanionFAQ.swift` 也与该提交完全一致。恢复的是原有「我／FAQ／背景资料」、五维表达待校准入口、表达积累、问题语义合组、FAQ 编辑与期限、跨场发现和旧资料列表。

首页、独立客户工作区、录音及语音页面保留当前版本；新版 Library 页面和代码保留，但不再由记忆库主入口进入。没有回退 Git HEAD、数据库、后端或部署；没有提交 Git 或更新实体设备。

这次回滚不会产生实际雷达分数：目标提交原本就显示待积累／待校准；目标提交也没有单独的面试积累首页。

## 当前兼容性核对

- 旧页面：`GET /v1/companion/memory`、`PATCH /v1/companion/faq/{id}`、`PATCH /v1/companion/expressions/{id}`。
- 新页面：`GET /v1/library`、`GET/PATCH /v1/library/items/{id}` 及资料、练习子接口。
- 当前本地代码与云端公开 OpenAPI 均包含上述两组接口。此检查仅读取接口定义，不读取用户资料，也不证明两套数据一致。云端回执：`.build/memory-rollback/cloud-contracts.json`。
- 本次没有 Git 文本冲突；以下是数据、接口语义与功能覆盖冲突，不能用“编译通过”替代合并决定。

## M1：素材与 FAQ 的主数据源、编辑版本

旧页面读写 `assets.body.text`，用 `assets.version`、`faq_history` 和 `asset_revisions`。新页面读写 `library_items.text`，用自身 `version` 和 `library_versions`。`Library.migrate` 只做首次复制，已知 legacy_id 会跳过，不持续同步。新版新建条目也没有通用的回写旧表流程。

隔离复现已确认：旧页修改后新版仍是旧内容；新页再修改后，两边版本都可为 2、内容却不同，重新调用迁移也不会消除差异。历史记录分别保存在两套表中。因此不能按同 ID、相同版本号直接覆盖。

**评审选项（选择已确认，见文首）：** A 以旧 assets 为主，将新版独有数据和历史经冲突审核迁回；B 保留旧页面样式，以 library_items 为主改造接口适配；C 暂时两套独立保留，明确展示差异，后续逐条解决。选 A/B 都需要保留用户改写、来源权限和历史版本。

证据：`backend/companion.py` 的 `edit_faq`、`backend/memory_library.py` 的 `migrate/edit`；`.build/memory-rollback/dual-store-reproduction.json`。

## M2：相似问题语义合组、问题次数

旧方案使用 question_embeddings/question_groupings，把带「客户常问」标签且有有效原文的旧表达进行语义合组，展示每次问法、出现次数与录音场数。新版 Library 按问题提取、按场景/工作区/规范化问题做复用，不读取旧语义合组结果。两边的问题 ID、分组边界和统计单位不同；新库条目不自动加入旧合组。

**评审选项（选择已确认，见文首）：** A 旧语义合组继续作为权威，并决定如何接纳新版问题；B 新库负责单条问答、旧合组作为其独立索引；C 合并成新的统一分组模型，并保留旧组到新组的可追踪映射。合组阈值和客户/面试范围不能自动更改。

证据：`backend/question_grouping.py` 的 `questions/snapshot`、`backend/memory_library.py` 的 `extract`、`ios/CanDid/CompanionFAQ.swift`。

## M3：早期故事、手动素材、经历、题库与归档

新版迁移只处理 companion_expression 或 kind=qa_answer；早期 kind=story、普通手动素材会跳过，experiences/question_bank 也未统一接入。旧 Companion 读取同样只包含 companion_expression，因此单纯回滚页面仍不会恢复全部早期内容。符合条件的已归档表达又会被新迁移写为 active。

**评审选项（选择已确认，见文首）：** A 原记录保留为独立的「历史积累」入口；B 补入选定主数据源，明确故事/经历/问答类型与归档状态；C 先拿生产库及发布前备份统计受影响条数，再定迁移规则。当前没有生产库访问，不能报告用户实际条数。

证据：`backend/memory.py` 的 `save_analysis`、`backend/companion.py` 的 `memory`、`backend/memory_library.py:32`；此前隔离复现见 `.build/memory-history-audit/`。

## M4：五维表达／雷达与新版三个测量指标

旧 delivery 提供录音总数、复盘/下一步计数和完整认领后估算的说话占比；五维为语速/停顿/口头禅/起伏/说话占比，雷达状态为 awaiting_calibration。新版 metrics 提供转写语速、时长占比、转写口头禅、认领覆盖，按场景显示三场趋势与六场比较。两套样本过滤及聚合方式也不同，数字不能直接等同。

**评审选项（选择已确认，见文首）：** A 完全保留旧五维待校准行为；B 保留旧五维入口并接入有依据的新版指标，停顿/起伏明确暂无测量；C 在旧页面下另保留新版趋势详情。任何雷达评分规则需另行明确，不能把三个指标换算成五轴分数。

证据：`backend/companion.py` 的 `delivery`、`backend/memory_library.py` 的 `metrics`、`CompanionDeliveryPage` 与 `LibraryMetricsPage`。

## M5：Mock 练习的会话、历史与保存

旧 FAQ 练习切到通用个人范围，在普通 Chat 中发送模拟提示并打开聊天；没有 library_practices 记录。新版使用独立 practice API、后台任务和 library_practices，支持多轮反馈及保存新说法，明确不计实战。两类旧练习不能仅靠聊天内容自动推断成新版结构化记录。

**评审选项（选择已确认，见文首）：** A 保留旧 Chat 练习；B 旧入口接新版独立练习；C 两种都保留并明确区分。历史聊天是否导入练习记录需要单独确认。

证据：`CompanionFAQDetail.practice`、`LibraryMockPage`、`backend/memory_library.py` 的 `practice/mock`。

## M6：背景资料、OCR、新版本与回答同步

旧页展示个人资料导入记录、解析文字和页码，提供上传/重试/移除。当前共享上传实现已经加入本机 OCR，因此回滚页面不等于回退全部上传处理；旧文件选择器没有图片类型。新版详情还提供原文件预览、问题页提示、document_families、替换/恢复版本，以及关联回答的局部同步；该同步仅更新 library_items，旧 assets 说法不会跟着变。

**评审选项（选择已确认，见文首）：** A 保留旧资料管理能力，新版高级入口暂不显示；B 旧视觉接入新版原件/OCR/版本详情；C 先只接 OCR 和原件预览，资料版本与说法自动同步单独决定。自动修改回答必须等 M1 主数据源确认。

证据：`LegacyCompanionMemory.documents`、`CompanionDocumentPage`、`Onboarding.swift` 的 `uploadOnboarding`、`LibraryDocumentDetail`、`Library.sync`。

## M7：销售/面试分类、主题与适用时间

旧 FAQ 主题固定为汽车销售的车型/价格/金融/置换/售后/用车场景，旧后端也校验这套枚举；新版主题按销售与面试分开。旧字段 faq_period、faq_expires_on(YYYY-MM-DD) 与新字段 valid_until(ISO 时间) 不同，新版缺少旧的自由文本适用期间。回滚后不能直接把新版面试主题和期限写回旧接口。

**评审选项（选择已确认，见文首）：** A 完全沿用旧主题与期限；B 保留旧视觉，主题按场景区分，并明确自由文本期间和日期的映射；C 销售和面试独立入口、独立分类。日期边界、空值清除和旧期间信息保留需一并决定。

证据：`CompanionFAQ.topics`、`Companion.edit_faq`、`Library.TOPICS/Edit`、`LibraryFAQDetail`。

## M8：依据、实战效果、会前提醒与历史恢复

旧 UI 通过来源有效性、用户是否改写、标签和截止日期判断待改进/还没用过；历史主要可读。新版分开保存说法、依据、实战效果，增加真实使用记录、提醒开关和恢复历史为新版本。旧页面不会显示新库的正向效果、提醒状态或资料修改建议；旧页编辑也不会维护这些状态。

**评审选项（选择已确认，见文首）：** A 使用旧状态语义；B 保留旧视觉，接新版三维状态、提醒与历史恢复；C 先只合并依据和历史，效果/提醒后置。Mock 不应被自动计作实战，用户改写不应被自动视为有事实依据。

证据：`CompanionFAQ.status/needsWork`、`Library.item/edit`、`LibraryFAQDetail`。

## 确认格式

可按编号回复，例如 `M1=B，M2=B，M3=C，M4=B，M5=B，M6=C，M7=B，M8=C`。这只是回复格式示例，**不是已经采用的方案**。也可以逐项指定其他方案。上述八项已有明确授权；新出现的产品或数据冲突仍需用户确认，不自动覆盖不同版本的用户改写。

## 验证记录

- 旧页面主体、FAQ 文件与目标提交的一致性：通过。
- 本地隔离的旧 FAQ 保存/版本/账号隔离及新版迁移版本契约：3 项通过；使用临时库，无生产写入或付费模型调用。
- 两套表分叉的隔离复现：通过，见上述 JSON。
- 原生 FAQ 界面回归：1 项通过，44.129 秒、0 失败；覆盖搜索空结果、清除搜索、进入详情、编辑说法、适用期间、截止日期与取消。结果包 `.build/TestResults/Memory-Rollback-20261016.xcresult`；使用合成数据，未保存线上数据或执行真实 Mock。
- 生产历史素材受影响数量、实体设备更新、后端合并及部署均未执行。
