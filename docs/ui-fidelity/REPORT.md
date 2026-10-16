# HTML 还原与逐句回听

本轮以 `docs/references/CanDid_v2_iPhone17_20261016.html` 和用户批准的逐页差异清单为准。保留手机备用会议录音、长按输入松开发送／上滑取消、连续对话、个人介绍、说话人认领、原文修订、资料管理、表达编辑和跨场发现集中确认。原文逐句播放是用户指定的 HTML 例外。

## 实现对应

| 原差异 | 本轮实现 | 回归入口 |
| --- | --- | --- |
| 悬浮系统 tab、实心图标 | 全宽纸白底栏，线性图标与淡紫选中底；尊重安全区 | 三个首页目的地、手机／iPad |
| 报告保留主导航 | 报告可见期隐藏底栏，返回恢复 | 准备包、复盘、表达和发现详情 |
| 首页快捷入口改变 | 恢复准备客户／复盘上一场，无录音时显示录音豆 | 有数据／无数据首页 |
| 输入框随展开换组件 | 一个驻留输入框，紫色发送箭头；展开消息不替换草稿控件 | 点按输入、收起、切 tab、再展开 |
| 字号、间距、形状偏离 | 独立的可缩放字号、描边与按钮底边；紧凑标题和录音行 | 标准字号和辅助字号截图 |
| 准备报告缺乏层级 | 目标紫卡、重点关注、编号建议、来源依据卡 | 准备包与真实 HTTP 流程 |
| 参会人没有字段 | 可选 participants；只收录用户对话中明确提供的原话片段 | 工具验证、空字段兼容 |
| 复盘缺乏组织 | 常驻播放器、浅绿总结、跟进、编号改进表达、全部原文问答折叠项 | 复盘和表达详情 |
| 记忆分类与列表不同 | 两个主分类，发现由顶部卡与二级集中确认页管理；空状态隐藏分类 | 空记忆库／有数据记忆库 |
| 原文回听入口丢失 | 每个片段均有播放／暂停，按 start_ms 与 end_ms 回听 | AVPlayer 实音频单元测试、原文 UI |

问答折叠项取自真实转写中含问号的片段及其后续原文，不猜测“谁是本人”。转写没有问号时仍完整提供原文，已有 AI 表达可独立查看；不凭空补问答。模型尚未产出表达／资料依据时显示真实空状态，不拿 HTML 示例冒充用户数据。

## 相对 HTML 保留的调整

- 首页增加一个明确的连续对话线性图标；双击头像仍可进入。设置与全部准备包也可由头像长按菜单打开，下一场区域保留全部准备包入口。
- 手机会议录音备用入口在录音库与设备引导中保留。
- 原文按可播放的实际时间片段保留，提供逐句播放、说话人认领及修订，不强制改成原型的静态客户／本人配对。
- 跨场发现仍需集中核对；保留已确认的个人介绍入口、上传失败恢复与资料移除。
- 系统状态栏、键盘、返回手势和安全区使用原生行为；辅助字号优先保证可读与可操作。

## 测试与证据

已完成：

- 后端完整回归：166 passed；目标服务器 companion 回归：20 passed。
- 原生单元：22 passed，包括相对时间 24 小时格式、原文问答顺序、真实 AVPlayer 定位／句尾停止／重播／停止后的请求恢复保护。
- 12 条不同 UI 流程通过（分批运行，重复用例不累计）：完整 onboarding、逐步跳过、说话人姓名与本人身份、空首页与两个连续对话入口、草稿跨展开与 tab 保存、准备包／复盘／原文、空记忆库／设备／备用录音、有数据表达编辑／发现集中确认、标准尺寸报告布局、辅助字号、本机 HTTP 资料问答与准备包同一 ID、本机 HTTP 逐句回听。
- iPhone 17、iPhone 15 Pro、iPad Pro 13 M5 竖屏及辅助字号截图已检查；固定导航区控制放大范围，正文仍可放大和滚动。
- Release 真机目标未签名构建通过。没有覆盖安装实体 iPhone。
- App → 本机 FastAPI／SQLite → 签名音频 URL → AVPlayer：通过；实际请求 500–3500ms 和 4000–7500ms，见 `playback-evidence.json`。音频为 9 秒 440Hz 合成音，不是 ASR 质量或真人听感评测。
- App → 本机后端 → Agent → 准备包 → Chat／首页：通过；模型边界使用确定性 Gateway。此轮没有用付费云模型做回归，未重新验证 ASR／TTS 服务质量。

初轮新增的两项“详情无主导航”断言失败，修复报告可见期的底栏控制后通过。截图又发现文字阴影及日期格式歧义，分别移到按钮底形、改成 HH:mm，并补了测试。Xcode/iOS 模拟器仍输出 SDK 无硬件、同步音频会话和未来 iPad 全方向配置等提示，本轮未将其当作真实硬件验证。

原型和 App 的演示数据数量不作为内容缺失的证据；测试夹具只在隔离的 DEBUG 测试入口中生效。此前用户报告的真机麦克风无输入未在本轮重新录音验收；真实收音、回声/VAD、TTS 抢话及录音豆硬件仍需实体设备验证。

## 复现

- `backend/.venv/bin/python -m pytest backend/tests -q`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer sh scripts/check-ios.sh --test <模拟器 UDID>`
- 实际本机 HTTP：运行 `backend/.venv/bin/python scripts/v2-test-server.py`，测试命令前增加 `TEST_RUNNER_CANDID_RUN_HTTP_UI=1`。测试数据在 `.build/v2-http-data`，可用 `CANDID_HTTP_TEST_DATA_DIR` 指定独立目录；不读取供应商 Key，也不连接生产库。
- `docs/ui-fidelity/index.html` 是本轮原型／原生截图并排展示，不是替代 App 的功能原型。

## 本地结果位置

- `.build/TestResults/Fidelity-Final.xcresult`：完整原生回归，21 单元＋10 UI 通过、1 个需显式开启的 HTTP 用例跳过。
- `.build/TestResults/Fidelity-Acceptance-Final.xcresult`：21 单元＋6 UI 通过，含两条真实本机 HTTP 流程。
- `.build/TestResults/Fidelity-Delivery.xcresult`：最终 22 单元＋3 UI 通过，覆盖最后的时间修复。
- `.build/TestResults/Fidelity-iPhone15Pro.xcresult`、`Fidelity-iPad.xcresult`、`Fidelity-iPad-Delivery.xcresult`：机型／辅助字号及最终 iPad 报告验证。
- `.build/fidelity-release-delivery-build.log`、`.build/fidelity-deploy.log`：最终 Release 构建和配套字段部署。

服务器发布目录 `/opt/candid/releases/20261016-ui-fidelity`，配套字段文件哈希已核对，candid active，正常 HTTPS 健康检查通过；持久数据、凭证及供应商配置沿用原位置。
