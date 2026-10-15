# Onboarding 原生 UI 审查

2026-10-15。状态：**首次审查为 fix；最终独立复核对三项问题均判定 resolved，disposition 为 ship，仅限本轮三项修复评分范围。** 最终代码已冻结，修复后构建、软件测试与 11 张有效原生捕获完成。该结论不表示整个 App、全部设备或全部状态视觉通过；此前锁屏画面仍不作为证据。

## 依据与范围

视觉依据沿用根目录 `DESIGN.md`、`.impeccable/design.json` 与已确认的 [SURFACE.md](prototypes/onboarding/SURFACE.md)、[HTML 原型](prototypes/onboarding/index.html)。本轮属于现有 SwiftUI 界面的扩展，根设计规范、sidecar 与品牌资产保持原样。已补充 [PRODUCT.md](../PRODUCT.md)，仅索引已有的产品、项目、场景、设计与引导约定，不增加需求。实现依据为 `ios/CanDid/Onboarding.swift`；功能与软件证据见 [交付记录](ONBOARDING_DELIVERY.md)。

本记录区分源码规则、自动化可操作性与有效原生画面。以下表格记录代码对应关系；视觉结论以文末限定范围的独立复核为准，不推断未覆盖页面、对比度或设备状态已经合格。

| 已确认的表面约定 | 原生实现对照 |
| --- | --- |
| 欢迎 → 用途 → 个人介绍 → 资料 → 首页 | `OnboardingView` 的欢迎与三步内容；用途为销售 BD／面试可选多选，称呼与背景选填，无重复核对页面。 |
| 主操作固定在底部，内容可滚动 | 首次审查后改为 `VStack` 中并列的 `ScrollViewReader`／`ScrollView` 与自然高度底部操作区；滚动区填满剩余高度。内容和操作区最大宽 550pt，水平 padding 24pt。原型桌面侧栏未作为 App 导航移植。介绍页底部操作已获限定独立复核通过。 |
| 可跳过、回退且保留输入 | 顶部直接进入首页、逐步跳过与返回；状态写入本机，完成独立于后端连接。 |
| 延续 Warm 世界 | `Warm.paper`、`Warm.white`、紫色 tint、橙色 `RecordingPrimary`、`WarmCard` 与 sage 提示；系统圆角字体、语义字号、原生导航和文件选择器。 |
| 清楚表达选择与进度 | 用途同时使用勾选图标、文字和 accessibility value；三步进度有无障碍整句说明，返回／设置／跳过操作有 44pt 框或最小高度。 |
| 可说、可改、稍后补资料 | “用说的”填写介绍；PDF／DOCX／TXT／Markdown 原生导入；文档行显示保存、整理、失败和重试，具备移除入口。 |

## 软件检查与画面证据

修复后的最终产品代码完成 iPhone 13 项单元与 2 项引导 UI 测试、iPad 1 项完整流程 UI 测试；额外 iPhone 稳定捕获完整流程 1 项通过。最后一次只将测试捕获辅助逻辑的键盘等待增加到 10 秒，App 源码未再变更。设备 SDK 无签名 Debug 构建成功。结果包与日志位置见 [交付记录](ONBOARDING_DELIVERY.md)。

布局修复前的 iPhone 13＋8 完整回归、13＋2 引导复核及 iPad 1 项通过保留为历史记录，不与最终检查重复累计。iPad 最终为硬件键盘模式，没有有效软键盘展开图，不能宣称 iPad 软键盘视觉通过。其用例通过后有 `simctl` 诊断收集失败，测试会话仍为 `TEST EXECUTE SUCCEEDED`。

最终有效捕获位于本机 `.impeccable/review/`：`phone-onboarding-*.png` 与 `tablet-onboarding-*.png`，分别覆盖欢迎、用途、介绍、资料和个人资料页，另有 `phone-onboarding-keyboard.png`。首次独立 finish review 对修复前的画面给出 **fix**。修复后主执行已逐页核对 11 张；键盘图以 10 秒稳定等待后的完整画面替换。独立 reviewer 以原分辨率确认介绍页底部操作完整、iPhone 焦点编辑框与底部操作没有遮挡。锁屏截断／空白、早期 iPad 横屏无效图、键盘过渡画面均排除；原型仅作为设计参考。截图不进入 Git。

最终关键画面的原字节副本：`phone-onboarding-introduction-final-e88a2bcc29.png`、`tablet-onboarding-introduction-final-4a7aede795.png`、`phone-onboarding-keyboard-final-5d927625e8.png`，均位于上述本机目录。原分辨率复读用于避免缩放画面遗漏底部内容，不涉及额外产品代码变更。

截图几何等待辅助运行曾超时并停止；后续一次重新捕获运行也被中断，均不作为通过证据。最终使用全屏截图及稳定等待；后续新增的编辑框、底部操作与键盘位置断言在最终 iPhone 回归中通过。旧的截图几何等待运行仍不计为通过。

此前 iPhone 与 iPad 日志均出现 `Invalid frame dimension (negative or non-finite)` 警告。最终三份测试日志未再检出该字符串；历史来源仍未确定，不能直接将该日志与以下可见问题认定为同一原因。

## 首次审查发现与修复方案

| 可见问题 | 当前修复方案与状态 |
| --- | --- |
| iPhone 与 iPad 的介绍页底部“继续／跳过”消失 | **Resolved。** 内容滚动区和底部操作区改为 `VStack` 的同级内容，滚动区填满剩余高度、操作区固定自然高度。独立 reviewer 按原分辨率确认两端操作完整显示。 |
| iPhone 键盘展开时操作区覆盖介绍编辑区域 | **Resolved。** 改用基准 148pt、随正文缩放的 `TextEditor`；通过 `FocusState` 与 `keyboardDidShow` 滚动到焦点，禁用交互式键盘收起。移除系统 keyboard toolbar，将“收起键盘”放在跳过同一行，同时清除 focus 并调用 `resignFirstResponder`。独立 reviewer 确认最终稳定画面无编辑框／底部操作遮挡。 |
| 缺少规范产品入口 | **Resolved。** 新建根目录 `PRODUCT.md`，仅从已有文档提取产品、项目、场景、设计和引导索引，独立 reviewer 确认入口完整。 |

三项修复均保留原设计文件与 sidecar。

## 最终复核与边界

修复后的软件检查和 11 张原生捕获已经完成，最终独立 disposition 为 **ship，仅限上述三项 resolved 问题**。iPad 软键盘、未取得有效证据的横屏、真机视觉及真实 ASR 不包含在该结论中，也不将此前测试或被中断的重新捕获写成最终验收。

本轮没有真机安装、真实麦克风／ASR、付费模型或录音豆物理验证。真机安装按用户要求继续暂停，视觉门槛不改变这一边界。

## 资产与隐私

复用已有 `ios/CanDid/Assets.xcassets/Mascot.imageset/mascot.png`，SHA-256 `c997b11e1570c85a8af0ba5143cfbdc5dce538bbc6fc5a4a01cb387369ff8414`，未生成、下载或替换图像。原作者与最初授权资料沿用根设计文档的未知边界。原生审查截图、数据库、密钥和备份保留本机，Git 中的原型只使用示例内容。
