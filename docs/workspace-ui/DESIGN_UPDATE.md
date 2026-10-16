# 独立工作区规范合并 · 2026-10-16

本轮仅更新 PRODUCT.md、DESIGN.md、.impeccable/design.json 及本记录。按已确认的 BRIEF 和当前 SwiftUI 源码，将独立客户 push/back、首页准备分页与 Tracker、composer 下轻量工作区／复盘控件、明确主要客户确认规则合并到现有约定；保留 Warm、Mascot、原生根 Tab 与其他页面规则。

DESIGN 与 sidecar 同步了 xLarge 起准备卡自然高度和外层滚动、页头 xxxLarge 上限及固定 17pt 设备麦克风、实色页内分段、compact composer 和归属说明完整换行。旧首页 overlay/collapse、工作区 carousel、等宽快捷双按钮已不再作为现行约定。

## 本次静态校验

- JSON 可解析，schemaVersion 保持 2。
- sidecar Overview 与 keyCharacteristics 和 DESIGN.md 原文一致。
- 旧交互的现行规则措辞已移除；PRODUCT.md／DESIGN.md 的 Markdown 相对链接目标存在。
- 对照 CompanionUI.swift、VoiceViews.swift 与 backend/app.py 核对本轮涉及的布局、控件和确认契约；未运行 App、构建、测试或截图采集。

## 后续源码一致性复核

选择器列表现为按结果数自适应的 104–224pt 高度，在原生 popover 内忽略键盘底部安全区；录音归属选择器锚定选择按钮并向上呈现。只读录音页的元数据不因模态选择器键盘而重新避让。归档工作区恢复后清除待新建模式；Product 迁移优先保留工作区现有的 sales／interview 场景。已静态核对对应 CompanionUI.swift、ChatView.swift、backend/product.py。未增加颜色、字体或形状；本次复核对这些设计 token 无改动。

## 主任务报告的最终功能与构建证据

以下由主任务提供，documenter 未重新执行或独立复跑：

- 后端：264 项通过。
- iOS unit：40 项执行，39 项通过，1 项因缺少私有 live SDK 鉴权夹具跳过。
- iPhone UI：6 项通过；iPad UI：2 项通过。
- 独立原生 localhost HTTP 流程：1 项通过，经过真实 FastAPI／SQLite／Agent pipeline，模型输出使用确定性边界；验证沟通场次为 1，且唯一复盘进入正确客户对话。
- Generic iOS device Release 构建在 CODE_SIGNING_ALLOWED=NO 下成功；未安装到真机。

## 证据边界

工作区初审使用大字号及归属说明修正前截图；主任务现已从 AcceptedPhone／AcceptedTablet 更新 .impeccable/review 下的原路径图片。最新三项修复的视觉判断以 UI_REVIEW.md 当前记录为准，本记录不预先推断该 verdict。documenter 本次只核对文档和源码，没有执行 App、测试、构建或截图采集。

既有报告保留自己的时点与范围。上述 localhost 流程验证本地服务与原生 HTTP 路径，但确定性模型边界不证明付费模型输出；模拟器夹具、外部发送、真实 ASR、录音豆及真机声学链路仍是不同证据层。

## 保留的无关漂移

现有 DESIGN.md frontmatter 尚无 primitive token map，sidecar 仍有 color／typography metadata 与 component refersTo；部分旧章节标题尚非 document workflow 的 canonical headings，sidecar 中旧 dos／donts／rules 也未在正文逐项对应。这些是先前格式漂移，本轮只记录，没有补造 token 或重写无关规范。既有 PrimaryButton 硬偏移阴影的 notCanonized 记录继续保留。
