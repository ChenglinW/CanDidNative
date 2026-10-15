# Onboarding 原生交付

2026-10-15。用户确认 [HTML 原型](prototypes/onboarding/index.html)后，将同一流程接入 SwiftUI；沿用 Warm 米白、紫色、暖橙、系统圆角字体及现有 Mascot，没有增加模型、字体或第三方依赖。

当前交付状态：最终原生代码已冻结，软件检查及修复后截图已完成。独立视觉复核对首次三项问题均判定 resolved，disposition 为 **ship，限本轮三项修复范围**：iPhone／iPad 介绍页底部操作、iPhone 键盘遮挡、规范产品入口。该结论不表示整个 App 或全部设备状态视觉通过。真机安装继续按用户要求暂停。详见 [原生 UI 审查记录](ONBOARDING_UI_REVIEW.md)。

## 进入与完成

欢迎 → 用途选择 → 个人介绍 → 资料导入 → 首页。销售 BD／面试可多选，称呼与一段背景均选填；每一步可跳过，也可直接进入首页。返回、跳过、退出与重启保留已填写内容，不增加“确认 AI 理解”页面。仅选择一个常用场景时，首页初始筛选使用该场景，仍可随时切换。

引导状态独立保存，后端连接成功不会将正在填写的引导标为完成。能读取到旧版已完成标记时沿用；没有旧标记的用户会看到可直接跳过的新引导。新状态字段兼容旧缓存，断网不阻止完成。后续可从“记忆库 → 我 → 我的介绍与资料”或设置编辑。

个人介绍先保存在权限 0600、iOS 文件保护下的本机缓存中，按后端及访问身份隔离。正在编辑的草稿不自动覆盖后端；完成后或恢复连接时同步。请求标识支持安全重试，版本冲突保留本机输入；可读取后端最新内容，再明确选择采用哪一版。修改连接地址先留在设置草稿中，验证新连接后才替换已有地址和凭据。

## Agent 与语音

用户主动提供的称呼、介绍与用途保存到个人档案，以“仅数据，不改变规则”的独立背景段落加入文本 Agent 上下文。当前称呼优先于旧称呼设置；修改、清空会反映到后续轮次。不自动创建可见业务项目，不把输入改写成已发生经历；新的跨场个人推断仍沿用集中核对流程。

“用说的”复用现有 DashScope 流式 ASR 与共享音频采集。点按开始、点按结束，文字填入介绍后可修改；不会创建聊天消息或调用文本 Agent。未连接已配置语音的后端时提示直接打字。麦克风权限按需申请，取消、切页、后台或收音失败会结束采集，已有文字保留。

## 资料导入

支持 PDF、DOCX、UTF-8 TXT、Markdown，多选并逐份保存；单份文件上限沿用 25 MB 上传约束。文件先复制到 App 私有目录，离线排队；连接后上传，按原始字节 SHA-256 去重。

后端保存不可变原件，通过持久任务在本机提取文字及 PDF 页码，不调用付费模型来伪造分析结果。扫描 PDF、加密／损坏文件、异常 DOCX 或超限文本明确失败，原件仍保留，可重试或换文件。成功提取的内容是用户文档证据，按个人资料范围供 Agent 按需读取；不会将整个资料库每轮发送给模型。

“移除”会撤下资料及其读取范围、停止未完成整理；本机副本清理，后端原始证据仍保留在当前用户数据中，全部清理沿用现有“删除全部记忆”入口。

## 实现位置

- `ios/CanDid/Onboarding.swift`：原生流程、个人资料页、本机持久化、同步、文档队列与独立语音转文字。
- `Store.swift`、`ChatView.swift`：迁移、完成状态与后端连接解耦；设置与记忆库接入编辑入口。
- `backend/onboarding.py`：个人档案版本、幂等更新、原件保存、提取任务、状态与撤回。
- `agent_runtime`、`tasks/workspaces.py`：用户背景进入上下文；明确个人资料在尚未创建项目时也能按需读取。

## 验证与边界

后端测试使用临时数据库；原生资料持久化测试使用独立目录，网络通过替身验证，UI 测试使用独立示例空间。覆盖空白跳过、多选、回退、重启、后续编辑、版本冲突、接入失败保留凭据、真实 PDF／DOCX 字节解析、失败重试与资料撤回。

| 检查 | 结果与本地证据 |
| --- | --- |
| 最终后端回归 | 129 passed，38.88 秒；2 条 DashScope／Starlette 上游弃用警告。日志 `/tmp/candid-onboarding-backend-shipping.log`。 |
| 修复后 iPhone 引导回归 | 13 项单元、2 项引导 UI 测试通过；`.build/TestResults/Onboarding-keyboard-phone-20261015.xcresult`，日志 `/tmp/candid-onboarding-keyboard-phone.log`。 |
| 修复后 iPad 完整引导 | iPad Pro 13 M5／iOS 27、accessibility-large、系统深色下 1 项完整流程 UI 测试通过；App 按既定方案固定浅色。结果 `.build/TestResults/Onboarding-keyboard-iPad-20261015.xcresult`，日志 `/tmp/candid-onboarding-keyboard-ipad.log`。本次使用硬件键盘模式，不证明 iPad 软键盘布局通过。 |
| iPhone 稳定捕获复核 | 1 项完整流程 UI 测试通过；`.build/TestResults/Onboarding-stable-capture-phone-20261015.xcresult`，日志 `/tmp/candid-onboarding-stable-capture.log`。仅测试捕获辅助逻辑增加键盘稳定等待 10 秒，App 源码未再变更。 |
| 设备 SDK 构建 | 最终 Debug 无签名构建 `BUILD SUCCEEDED`，日志 `/tmp/candid-onboarding-device-final.log`；仅证明编译，未签名、未安装。 |
| 本地服务恢复 | 后端恢复到端口 8000；认证访问 `/v1/onboarding` 返回 HTTP 200。对照私有备份 `.build/backups/before-onboarding-20261015.sqlite3`，原有 10 条消息、7 个场次、35 个片段保留。 |

布局修复前还完成过 iPhone 13 项单元＋8 项 UI 完整回归，以及 iPhone 13＋2、iPad 1 项引导复核；这些是历史通过记录，不冒充最终布局的验证，也不重复累计。修复后 iPad 日志在用例通过后报告 `simctl` 诊断收集失败，最终测试会话为 `TEST EXECUTE SUCCEEDED`。

Mac 已解锁，最终 11 张原生画面已由主执行逐页打开核对；iPhone 键盘画面以 10 秒稳定等待后的完整捕获替换。独立 reviewer 按原分辨率确认 iPhone／iPad 介绍页底部“继续／跳过”完整显示，iPhone 焦点编辑框与底部操作没有遮挡，并确认根 `PRODUCT.md` 入口已补齐；三项均 resolved，限定 disposition 为 ship。iPad 软键盘、未取得有效证据的横屏、真机视觉及真实 ASR 未验证。

锁屏截断／空白、早期 iPad 横屏无效图、键盘过渡画面和被中断／超时的额外捕获均不作为通过证据。此前日志的 `Invalid frame dimension (negative or non-finite)` 来源未定；上述三份最终测试日志未再检出该字符串，不据此推断其历史来源。

本轮测试没有调用付费模型，没有开展真实麦克风、ASR 效果、真机安装或录音豆验证。语音网络、麦克风权限、中文及粤语实听效果留给后续真实环境验收；PDF 扫描件未接 OCR。文档整理是本地 CPU 文字提取，不等同于模型已经理解资料。原生截图与 HTML 原型分别记录，不将网页截图当作 App 截图。

密钥、数据库、私有备份、原生审查截图与测试结果保留在本机并排除 Git；提交的 HTML 原型仅含示例。原有 Mascot 保持不变，SHA-256 为 `c997b11e1570c85a8af0ba5143cfbdc5dce538bbc6fc5a4a01cb387369ff8414`。
