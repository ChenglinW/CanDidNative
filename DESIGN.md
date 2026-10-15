---
name: CanDid Native
description: Warm 浅色、系统圆角文字与原生三目的地构成的持续沟通界面。
colors:
  warm-paper: "rgb(96.9% 95.3% 91.4%)"
  warm-white: "rgb(100% 99.6% 98.4%)"
  warm-ink: "rgb(20.4% 20.8% 18%)"
  warm-purple: "rgb(44.7% 31.4% 63.1%)"
  warm-lavender: "rgb(93.3% 90.6% 98%)"
  warm-orange: "rgb(100% 75.3% 47.1%)"
  warm-sage: "rgb(91% 94.1% 84.3%)"
  secondary-text: "rgb(44% 44% 40%)"
  recorder-white: "#FFFFFF"
typography:
  body:
    fontFamily: "System rounded (SwiftUI .rounded)"
  body-semibold:
    fontFamily: "System rounded (SwiftUI .rounded)"
    fontWeight: 600
  recorder-title:
    fontFamily: "System rounded (SwiftUI .rounded)"
    fontSize: "27pt"
    fontWeight: 700
  recorder-timer:
    fontFamily: "System rounded (SwiftUI .rounded)"
    fontSize: "23pt"
    fontWeight: 600
rounded:
  recorder-note: "12pt"
  status-bar: "15pt"
  action-and-project: "16pt"
  composer: "18pt"
  warm-card: "22pt"
spacing:
  composer: "8pt"
  card-content-gap: "12pt"
  row-content: "16pt"
  warm-card-padding: "18pt"
  page: "22pt"
  home-section: "14pt"
components:
  recording-primary:
    backgroundColor: "{colors.warm-orange}"
    textColor: "{colors.warm-ink}"
    typography: "{typography.body-semibold}"
    rounded: "{rounded.action-and-project}"
    height: "50pt"
  recording-primary-disabled:
    backgroundColor: "{colors.warm-orange}"
    textColor: "{colors.warm-ink}"
    typography: "{typography.body-semibold}"
    rounded: "{rounded.action-and-project}"
    height: "50pt"
  warm-card:
    backgroundColor: "{colors.warm-white}"
    textColor: "{colors.warm-ink}"
    rounded: "{rounded.warm-card}"
    padding: "{spacing.warm-card-padding}"
  preparation-card:
    backgroundColor: "{colors.warm-lavender}"
    textColor: "{colors.warm-ink}"
    rounded: "{rounded.warm-card}"
    padding: "16pt"
  recording-row:
    backgroundColor: "{colors.warm-white}"
    textColor: "{colors.warm-ink}"
    rounded: "{rounded.action-and-project}"
    padding: "12pt"
  voice-composer:
    backgroundColor: "{colors.warm-white}"
    textColor: "{colors.warm-ink}"
    rounded: "{rounded.composer}"
    padding: "{spacing.composer}"
  composer-send:
    backgroundColor: "{colors.warm-purple}"
    textColor: "{colors.recorder-white}"
    rounded: "{rounded.recorder-note}"
    size: "44pt"
  recording-status:
    backgroundColor: "{colors.warm-lavender}"
    textColor: "{colors.warm-purple}"
    rounded: "{rounded.status-bar}"
    padding: "0pt 14pt"
    height: "46pt"
  recorder-transcript:
    backgroundColor: "{colors.warm-white}"
    textColor: "{colors.warm-ink}"
    rounded: "{rounded.warm-card}"
    padding: "{spacing.warm-card-padding}"
  expression-filter-selected:
    backgroundColor: "{colors.warm-sage}"
    textColor: "{colors.warm-ink}"
    height: "44pt"
    padding: "0pt 12pt"
---

# Design System: CanDid Native

## Overview

**Creative North Star: "Warm 原生沟通界面"**

本文件提取已批准 V2 的原生实现，沿用已有 Warm 配色、系统圆角字体和紫色双气泡 Mascot。少量信息、清楚的正文层级、浅色圆角容器与原生控件构成持续的沟通界面；页面策略以 `PRODUCT.md` 与 `docs/v2-validation/SURFACE.md` 为准。

应用主体、会议录音全屏页与连续语音页均使用 Warm 浅色世界。深度主要通过色面、留白与轻描边表达，导航、安全区、sheet、系统材料和 SF Symbols 由平台提供。动效解释同一内容层的展开与状态变化，并尊重 Reduce Motion。

**Key Characteristics:**

- 米白页面、近白内容、淡紫准备色面、紫色交互与暖橙主要动作。
- 系统圆角语义文字、原生三目的地和可访问的安全区布局。
- 同一对话层、清晰的原文时间戳与可追溯依据。

提取依据：`ios/CanDid/CanDidApp.swift` 的 Warm、WarmCard；`CompanionUI.swift` 的 V2 表面；`RecordingUI.swift` 的浅色录音与三目的地；`VoiceViews.swift`、`ChatView.swift` 与 `Onboarding.swift` 的输入和状态。前置 RGB 百分比保留 SwiftUI 源码精度；几何单位为原生逻辑点，前置 pt 不表示网页 CSS 物理点。sidecar 的同数值 CSS px 仅展示组件结构，原生实现是最终依据。

## Colors

### Primary

- `warm-purple`：全局 tint、来源入口、发送与状态文字；淡紫准备卡日期也使用该前景，保持小字清晰。
- `warm-orange`：RecordingPrimary、准备报告入口和连续语音结束动作的暖色强调。

### Secondary

- `warm-lavender`：准备卡、录音状态条、录音图标与连续语音圆背景。
- `warm-sage`：表达筛选的选中面、说明卡片和既有事实徽标。

### Neutral

- `warm-paper`：页面和固定输入区背景。
- `warm-white`：卡片、录音行、实时原文容器、输入框与系统 tab 工具栏背景。
- `warm-ink`：正文和橙色按钮文字，透明度描边以其构成。
- `secondary-text`：RecordingFormat.secondary，用于纸色、近白底上的辅助文字。
- `recorder-white`：保留的白色 token，仅对应发送箭头等白色控件前景；不再表示深色录音世界。

系统 `.secondary`、`.green`、`.red`、`.brown` 和材料继续由平台提供，不记录为虚构固定 RGB。状态圆点同时配文字说明。

**The Light Surface Rule.** 主体、录音全屏与连续语音共享浅色 Warm 世界；系统深色设置不切换当前 App 的色彩方案。

## Typography

全局 RootView 使用 `.fontDesign(.rounded)`；录音及连续语音保持同一系统圆角风格。中文由平台回退，没有新增字体依赖。

| 实际样式 | 当前用途 |
| --- | --- |
| `.largeTitle.bold()` / `.title.bold()` | 准备报告、记忆详情和引导标题 |
| `.title2.bold()` | 固定 Candid 标题、空态、录音复盘标题与连续语音状态 |
| `.title3.bold()` / `.headline` | 发现摘要、准备包客户、分区与资料标题 |
| `.body` / `.body.weight(.semibold)` | 消息、实时原文、正文与主要按钮 |
| `.subheadline` | 录音行标题、说明和报告入口 |
| `.caption` / `.caption2` | 日期、来源、状态、筛选与时间戳 |
| `recorder-title` / `recorder-timer` | 录音标题与固定数值计时器 |

语义文字保留 Dynamic Type，不添加虚构固定字号或行高。录音标题和计时器是前置 token 中源码明确的固定字号；计时器使用 `.monospacedDigit()`。正文行间距通常为 (5–6pt)，消息与实时原文保留文字选择。

## Layout

页面以单列、原生安全区和可滚动详情组织。Candid、录音库、记忆库、报告及消息内容最大宽 (700pt)；设备引导与个人资料最大宽 (600pt)。主要水平边距采用 `page`，详情间距常见 (20–22pt)，首页内容间距采用 `home-section`。没有自定义网页断点。

V2 首页是固定顶部、状态内容区和底部 dock；准备卡、最近录音数量属于表面约定而非全局卡片规则。辅助字号时中部改为 ScrollView，dock 的并排动作可由 ViewThatFits 换为竖排。驻留 Chat 从内容区底部展开，顶部留出 (48pt) 收起动作区域；键盘沿原生布局抬起输入，消息区可滚动。

头像旁动作、输入麦克风、发送与收起控件使用 (44 × 44pt) 框，文字动作通常最小高度 (44pt)。RecordingPrimary 的最小高度见前置 token。连续语音三个圆形控件为 (54 × 54pt)。iPhone 底部与 iPad 顶部 tab 由系统 TabView 安排，不绘制网页状态栏或 Dynamic Island。

## Elevation & Depth

色面层次、留白与轻描边是当前 V2 的主要深度手段。WarmCard 和实时原文容器采用 ink (0.08) 描边；VoiceComposer 使用 ink (0.15)，按住收音改为 purple。首页输入预览为 ink (0.12)，录音状态条为 purple (0.22)，浅色原文分隔为 ink (0.12)。系统 tab、sheet 与材料由平台绘制，没有新增阴影 token。

既有 PrimaryButton 源码仍有棕色硬边底影；这是未在本轮重写的遗留样式，不是 V2 的可复用深度规范。RecordingPrimary、准备卡与录音行均不继承这层影子。

## Shapes

卡片与实时原文容器使用 `warm-card`；录音行和主要按钮沿用 (16pt) 圆角，对应历史 token 名 `action-and-project`。输入使用 `composer`，发送及准备卡按钮使用 `recorder-note`。筛选与徽标采用 Capsule，头像底与连续语音控件采用 Circle，图标沿用 SF Symbols。

## Components

### Buttons

RecordingPrimary 使用暖橙底、ink 字、语义正文半粗体；最小高度与圆角见前置 token。按下 opacity (0.8)，禁用 opacity (0.45)，两个 modifier 按源码依次叠加。准备卡中的报告 CTA 使用同色、(12pt) 圆角、水平内边距 (14pt)，最小高度 (44pt)。文字次要动作使用 purple tint 和原生交互。

### Chips

表达标签筛选为 capsule，水平内边距 (12pt)、最小高度 (44pt)，选中为 sage，未选中近白。记忆分区与录音复盘／原文使用系统 segmented Picker。既有 TrustBadge 仍用文字、图标和 sage／lavender 区分事实与推断。

### Cards / Containers

WarmCard 内部间距、内边距和圆角见前置 token。CompanionPreparationCard 为 lavender、(16pt) 内边距与 (10pt) 内容间距，日期为 purple。CompanionRecordingRow 为近白、(12pt) 内边距与间距，图标放在淡紫圆角底，内容包含单行标题、时间／时长／处理状态。记忆表达行使用近白、(16pt) 内边距，保留原文依据或待重核标记。组件预览中的业务文字均为示例。

### Inputs / Fields

首页输入是进入同一 Chat 的按钮预览，显示保留草稿或提示语，支持长按语音；展开后的 VoiceComposer 包含麦克风、(1–5) 行 TextField 与发送动作。容器间距及内边距均为 (8pt)，TextField 竖直内边距 (9pt)。空草稿发送箭头 opacity (0.45)；禁用条件还包含聊天控制忙碌、加载或连续语音活跃。未编辑输入区由透明覆盖层分别处理普通点按与长按：普通点按进入编辑；只有长按 (0.35s) 成立后的 sequenced second 阶段开始收音，上滑超过 (60pt) 标示取消。发送按钮不注册该输入区的长按手势；键盘编辑保留原生选字。独立麦克风按钮仍支持点击开始、再次点击发送。焦点、取消手势和输入保持由原生实现处理。资料编辑继续使用 Form、TextEditor 和原生工具栏。

### Navigation

三个系统目的地是 Candid、记忆库、录音，深入内容使用 NavigationStack。首页菜单进入个人与设置、全部准备包；持续对话直接在首页内容区上推，右上收起或顶部下拉收起，不提供项目或会话选择器。录音与连续语音使用 fullScreenCover，保持浅色 Warm 世界。系统 hover、focus 和导航装饰不由网页预览替代。

### Recorder transcript

实时原文容器为近白，稳定文字为 ink，临时识别为 purple，时间戳与辅助说明使用 secondary-text。每条时间戳在文字上方，支持文字选择；用户上翻时暂停跟随，提供最小 (44pt) 高度的淡紫 capsule「回到最新」。容器内边距为 (18pt)，外侧水平边距为 (16pt)，录后原文通过带来源入口进入。

### Voice motion and imagery

Chat 使用 `.easeOut(duration:0.3)` 从内容区底部上推；Reduce Motion 关闭显式动画及大幅位移，并保留同一层状态。连续语音 lavender 圆为 (152pt)，Mascot 为 (106pt)，音量缩放为 `1 + level × 0.12`，`.easeOut(duration:0.12)`；Reduce Motion 关闭该显式动画。未连接时有「重新连接 Candid」及连接中反馈。

唯一保留的品牌位图是 `ios/CanDid/Assets.xcassets/Mascot.imageset/mascot.png`，由既有 Mascot 缩放显示，accessibility label 为「Candid 紫色双气泡」。本轮没有生成、下载或替换它。可核实来源是任务开始前已存在的仓库资产；原作者、最初生成方式与授权资料未提供，不能补写推测来源。原有 SHA-256 与字节记录保留于 sidecar。当前验收证据见 `docs/v2-validation/REPORT.md`。

## Do's and Don'ts

### Do:

- Do 沿用 Warm 源码配色、系统圆角文字和 SF Symbols。
- Do 为主体、全屏录音与连续语音保留浅色 scheme。
- Do 保留原生导航、安全区、Dynamic Type 与 Reduce Motion 降级。
- Do 用文字与图标共同表达状态，保留原文、待确认、依据已更新与示例标记。

### Don't:

- Don't 新增字体或替换现有 Mascot 来改变已固定的视觉体系。
- Don't 把旧项目页面、四 tab 或深色录音记录作为新表面的依据。
- Don't 把系统动态字体、语义颜色或原生导航伪装成固定网页 token。
- Don't 用示例截图推断真实数据、外部发送、ASR 或硬件已经通过验收。
