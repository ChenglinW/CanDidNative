# 记忆库按用户决策合并

后续已按 R1–R6 全部 A 整合远端 `da117b3`，最新状态与验证见 [远端合并交付](UPSTREAM_MERGE_DELIVERY_20261016.md)。以下保留为 M1–M8 阶段记录。

2026-10-16。基线 `6d7821d`，原页面参考为用户提交 `d8a85ca`。用户确认：**M1=B、M2=C、M3=B、M4=B、M5=B、M6=B、M7=C、M8=C**。实现位于本地工作区，尚未提交 Git、部署云端或更新实体设备。

## 决策与实现

| 项目 | 已实现行为 |
|---|---|
| M1=B | 原有卡片及三分类布局连接 library_items；旧 FAQ/表达 HTTP 编辑接口也修改同一条 canonical 记录、共用版本号，旧 assets 保留为历史原件。Agent 检索不再重复选取已导入的旧副本。 |
| M2=C | 新统一分组使用原 Qwen3.7 embedding、0.6646 阈值、Top15 候选边和平均链接规则。按场景和来源范围隔离，使用独立缓存/结果表；旧组保留，并写入 library_group_links 映射。相同来源片段不重复计数。 |
| M3=B | 导入旧 assets、experiences、question_bank，保留 ID 映射、原始载荷、改写/历史、场景、来源范围和归档。不同来源表采用稳定命名空间 ID，避免相撞；原记录不删除。归档及其他场景有单独可达入口。 |
| M4=B | 保留语速/停顿/口头禅/起伏/说话占比五维入口；接入新版三项真实描述指标及逐场/趋势，停顿与起伏明确暂无可靠测量，不生成雷达分数。 |
| M5=B | FAQ 入口进入新版独立 Mock，保存练习轮次、反馈和新说法；不写入普通聊天，不将练习计入实战或真实录音指标。旧聊天记录不自动转换为练习。 |
| M6=B | 旧页面世界内接入新版资料详情：原件预览、图片/扫描 PDF 的本机 OCR、问题页提示、新版本、局部说法同步、历史恢复和重试。用户改写仅提供建议，不能自动覆盖。 |
| M7=C | 销售积累/面试积累两个明确入口，分别保存我/FAQ/背景资料选择，问题、素材、主题和指标按场景区分。销售旧主题保留兼容，面试使用独立主题；原适用期间保留。背景原文件沿用原权限范围，不因场景切换扩大共享。 |
| M8=C | 合并依据提示、原文回听、资料关联、说法历史及恢复；页面不合入实战效果标签和提醒开关，不删除后端已保存的历史效果/提醒数据。 |

## 重要边界

- `Library.migrate` 是幂等导入，不用两套互相独立的版本号决定覆盖。旧版与当前用户改写不同，会保留当前内容、保存旧版历史，并显示“保留当前／采用旧版”的显式选择。
- 选择差异同时绑定当前说法版本与旧记录指纹。用户打开差异后若旧记录又变化，返回 409，要求重读核对，不悄悄解决新冲突。
- 旧日期截止按账号时区覆盖整个选定日；未提供时区使用 UTC。自由文本适用期间保留，非法日期、空白说法和跨场景主题返回明确错误。
- 早期只有时间段、没有 source_id 的引用仅在唯一匹配当前原文时补齐；不明确时保留旧引用和原始记录，并显示依据需核对，不捏造原文来源。
- 归档素材不进入当前 FAQ 分组；依据变化的问题仍可见、可修复，但不与有效来源合并。没有来源录音的历史问法不伪报录音次数；旧题库计数单独标注尚未核对来源。
- 生产历史受影响数量仍未核对：当前没有可用云端 SSH 凭证或数据库副本。测试和本地迁移实现不代表生产资料已经完成迁移。

## 实现入口

- `backend/library_migration.py`：完整历史导入、日期转换、版本与差异保留。
- `backend/library_grouping.py`：统一问题组、场景/范围边界、旧组映射及来源计数。
- `backend/memory_library.py`、`backend/companion_routes.py`：统一写入、旧客户端适配、乐观锁及差异选择。
- `backend/adapters/sqlite_memory.py`：检索以已导入的 canonical 素材为主，历史引用继续可核对。
- `ios/CanDid/MemoryLibrary.swift`：原页面结构中的分场景积累、五维指标、FAQ、资料、练习、历史和差异确认。

## 验证与证据

- 后端最终全量回归：320 项通过，2 项依赖弃用警告，包含差异确认的并发保护。
- 新增隔离测试覆盖各类历史导入、重复导入、归档、双库差异、新旧 API 共用版本、来源范围、旧组映射、场景隔离、日期、资料同步和差异并发保护。
- 手机原生界面共 5 条流程通过：FAQ → 依据资料 → 独立 Mock → 保存新说法；资料原文/版本入口及六场趋势；大字号；场景切换和五维入口；FAQ 编辑和截止日期。
- 截止日期检查已实际打开开关并验证日期控件出现。修正测试对 Form 整行开关区域的点击位置后通过，未跳过检查。
- 最新 iPhoneOS Release 未签名构建通过。iPad 的资料/指标、原布局/场景切换两条流程均通过，已查看原生截图确认布局。iPad 测试修正了浮动导航中同名按钮的定位，未改产品行为。
- 本机 HTTP 验证通过真实 SwiftUI App、FastAPI、SQLite 和任务队列，模型及 embedding 使用确定性替身；不是供应商质量或真人声学测试。全部资料是隔离合成内容，没有调用付费模型或写入线上账号。

日志/结果位于忽略的 `.build/memory-merge*`、`.build/TestResults/Memory-Merge-*`。截图在 `.build/memory-merge/screenshots/`，来自原生模拟器验收而非网页。早期失败和修正后的结果分别保留，不把未完成的结果算作通过。

最终证据：`memory-merge-backend-approved-final.log`（320 项）、`Memory-Merge-Final-20261016.xcresult`（四条手机流程通过，截止日期修正前的失败保留）、`Memory-Merge-Editor-Verified-20261016.xcresult`（截止日期修正后通过）、`Memory-Merge-iPad-20261016.xcresult`（资料/指标通过）、`Memory-Merge-iPad-Verified-20261016.xcresult`（原布局/场景切换修正后通过）、`memory-merge-release-verified.log`（最终 Release 构建通过）。结果包位于 `.build/TestResults/`，日志位于 `.build/`。

可重复的隔离 HTTP 服务：在仓库根目录运行 `backend/.venv/bin/python scripts/test-memory-library-server.py`，仅监听 `127.0.0.1:8897`，数据默认位于 `.build/memory-merge/http-data`。可用 `CANDID_LIBRARY_TEST_DATA_DIR` 指定独立测试目录；该脚本清除供应商密钥并替换模型及 embedding 边界。对应原生测试为 `CanDidUITests` 中以 `testMemoryLibrary` 开头的三个流程，另外两条为 `testMergedMemoryKeepsOriginalLayoutAndSeparatesInterview` 和 `testFAQSearchAndEditingControls`。

## 发布前还需完成

获得云端当前库与发布前备份或可用 SSH 访问后，先生成一致备份并按 owner 统计迁移差异；对实际不同的用户改写保持显式选择。部署包含新增表初始化、统一 API 和对应客户端的同一版本；不能只更新手机来假定云端已采用新的迁移/分组规则。实体设备安装与真实数据迁移应分别留存回执。
