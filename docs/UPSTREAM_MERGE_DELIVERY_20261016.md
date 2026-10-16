# 最新远端与原记忆库合并交付

2026-10-16 开始，跨日于 2026-10-17 验证。用户确认 R1–R6 全部 A。远端 7 个提交已快进到本地 master：`da117b3797ccd0a6774af8325f59888200fa8999`。此前 M1–M8 的本地改动已恢复并整合，没有产生新的本地提交、推送或本次部署。

## 已实现

| 决策 | 最终行为 |
|---|---|
| R1=A | 保留 assets/故事/手动素材/经历/题库的完整迁移、归档和差异确认。兼容远端 schema=2、原问法和期间字段，原地升级为 schema=3；保留当前手改、期限和范围。远端已导入的相同历史版本不重复复制。 |
| R2=A | canonical FAQ 保留独立分组表、客户/工作区范围和场景隔离、同源计数及旧组映射。使用 original_question 或原始问法作为分组输入。识别远端 library-* policy 的合并前 canonical 组，分别保存对应关系，不冒充更早的 legacy 组。模型/阈值/Top15/链接算法不变。 |
| R3=A | 旧 HTTP 编辑接口继续连接同一 canonical 记录和版本号，保留原主题。period/legacy_period 兼容读写；同时提交不同期间返回明确错误。日期按账号时区包含完整选定日，已有带时区截止时间保持有效，新增经历/题库记录不依赖同 ID assets 才可编辑。 |
| R4=A | 保留原卡片、销售/面试独立入口、五维入口、归档/历史/差异选择；统一分组类型，原问法参与搜索，组内逐条打开独立回答、资料和版本。保留 M8 页面规则，不重新显示实战效果标签/提醒设置。 |
| R5=A | 保留双方测试：原布局/五维/场景切换、FAQ 编辑/日期、独立 Mock/资料/指标，以及远端组导航、标记回听、Agent 与大字号测试；导航统一到最终页面。后端远端分组测试连接 canonical 服务，新增线上 schema 升级及缓存来源/并发容量回归。 |
| R6=A | 接入录音标记、实时标记提示、重点回听、片段提问及关联资料。分析只增强原文副本，保存引用仍用原文。旧录音路径不再重复产 FAQ；故事/表达仍进入完整迁移。FAQ 同源重提取继续复用条目、保留手改。library_grouping 和录音标记纳入低优先排序/单回填任务配额，为新录音与交互保留后台容量。 |

## 验证

- 后端最终全量 **338 passed**，2 项依赖弃用警告；最终日志 `.build/upstream-merge-backend-complete.log`。新增回归覆盖线上 schema 升级、历史不重复、期间兼容、合并前组来源、后台容量，以及标题被概括后仍按原问法去重。
- 旧素材未写场景时，只在真实来源录音有场景的情况下继承该场景；来源也未知时保留未分类。回归期间发现并修正了此处与同源去重的衔接，不把失败的中间日志算作最终通过。
- iPhone 17 Pro 模拟器 **8 条界面流程全部通过**：编辑/期限、组到独立详情、重点回听/Agent、大字号重点、FAQ/资料/Mock/版本、资料/指标、记忆库大字号、原布局/五维/场景切换。结果 `.build/TestResults/Upstream-Merge-Phone-20261016.xcresult`，日志 `.build/upstream-merge-phone.log`。
- 最新 iPhoneOS Release 未签名构建通过：`.build/upstream-merge-release.log`。不代表签名、实体安装或物理录音验证。
- iPad 模拟器 **4 条界面流程通过**：FAQ 组/独立详情、重点大字号、资料/指标、原布局/五维/场景切换；另 **1 项原生测试通过**，验证标记上传失败后持久恢复、去重重试和后端账号隔离。结果 `.build/TestResults/Upstream-Merge-iPad-20261016.xcresult`，日志 `.build/upstream-merge-ipad.log`。
- OpenAPI 已从最终路由在隔离临时目录重新生成，包含录音标记和迁移差异确认字段；Git 未解决冲突条目及源码冲突标记已清零。

隔离服务脚本为 `scripts/test-memory-library-server.py`：只监听 127.0.0.1:8897，使用合成资料与无声 WAV，模型及 embedding 边界为确定性替身。Agent 仍经过实际任务队列、上下文和 HTTP 链路；本次不测试供应商模型质量或真实声学效果。

本轮日志为 `.build/upstream-merge-*.log`，原生结果包为 `.build/TestResults/Upstream-Merge-*`。

手机及 iPad 原生截图已导出并查看：`.build/upstream-merge/screenshots/phone-memory-me.png`、`phone-marks-detail.png`、`ipad-marks-large-detail.png` 等；保持原记忆库布局，标记片段使用相同阅读样式。隔离验收服务已停止，合成数据与测试结果保留以便复核。

## Git 与数据状态

- Git 文本冲突已解决，修改保留在工作区，方便继续审阅；没有新建本地提交或推送。
- 合并前完整暂存备份保留在 Git stash，消息为 `Before approved R1-R6 upstream merge 2026-10-16`；同时保留 `.build/upstream-review-20261016-233959/` 中的文件/差异备份。
- 原 `.DS_Store` 等无关文件未清理，前一轮安装脚本和教程保留。
- 没有把本次代码部署到云端、迁移生产资料或重装实体设备。远端提交自带的部署回执作为历史保留，不表示本次组合版本已经发布；生产历史资料数量仍需可用云端访问后核对。
