---
name: CanDid Native
description: 沿用 Warm 配色、系统圆角字体和原生 SwiftUI 组件的沟通工作界面。
colors:
  warm-paper: "rgb(96.9% 95.3% 91.4%)"
  warm-white: "rgb(100% 99.6% 98.4%)"
  warm-ink: "rgb(20.4% 20.8% 18%)"
  warm-purple: "rgb(44.7% 31.4% 63.1%)"
  warm-lavender: "rgb(93.3% 90.6% 98%)"
  warm-orange: "rgb(100% 75.3% 47.1%)"
  warm-sage: "rgb(91% 94.1% 84.3%)"
  secondary-text: "rgb(44% 44% 40%)"
  recorder-background: "rgb(9% 8% 12%)"
  recorder-panel: "rgb(15% 13% 20%)"
  recorder-secondary: "rgb(78% 75% 84%)"
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
  project-vertical: "16pt"
  warm-card-padding: "18pt"
  page: "22pt"
  home-section: "24pt"
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
  next-meeting-card:
    backgroundColor: "{colors.warm-lavender}"
    textColor: "{colors.warm-ink}"
    rounded: "{rounded.warm-card}"
    padding: "{spacing.warm-card-padding}"
  project-row:
    backgroundColor: "{colors.warm-white}"
    textColor: "{colors.warm-ink}"
    rounded: "{rounded.action-and-project}"
    padding: "16pt 18pt"
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
    backgroundColor: "{colors.recorder-panel}"
    textColor: "{colors.recorder-white}"
    rounded: "{rounded.warm-card}"
    padding: "{spacing.warm-card-padding}"
---

# Design System: CanDid Native

## Overview

**Creative North Star: "Warm 原生沟通界面"**

本文件是当前实现的提取记录。用户已固定的米白、紫色、橙色与系统圆角风格继续作为视觉依据；名称仅描述已有界面。业务表面约定见 `docs/PRODUCT_SURFACES.md`。

应用主体是浅色 SwiftUI 界面，内容通过留白、圆角卡片和轻微描边组织。录音全屏页使用已确认的局部深色配色，连续语音对话仍使用 Warm 浅色。导航、选择器、表单、弹窗和图标依赖原生 SwiftUI 与 SF Symbols。

**Key Characteristics:**

- 米白页面、近白卡片、紫色交互和橙色主按钮。
- 系统圆角文字与原生导航，保留 Dynamic Type 的语义文字样式。
- 深色录音页以原文、时间戳和状态为主要内容。

提取依据：`ios/CanDid/CanDidApp.swift` 的 `Warm`、`WarmCard`、`PrimaryButton`；`ProductViews.swift` 的产品页；`RecordingUI.swift` 的 `RecordingPrimary`、`RecordingShell`、`LiveRecordingView`；`VoiceViews.swift` 的语音界面与输入。前置 RGB 值以百分比保留 SwiftUI 源码精度。几何单位为原生逻辑点，前置 `pt` 不表示网页 CSS 的物理点；sidecar 的网页预览以同数值 CSS px 展示结构，原生实现是最终依据。

## Colors

### Primary

- `warm-purple`：全局 tint、项目阶段、证据入口和发送按钮。
- `warm-orange`：当前 `RecordingPrimary` 与既有 `PrimaryButton` 的主要操作背景。

### Secondary

- `warm-lavender`：下一场卡片、录音状态条、语音圆形底色，以及录音中尚未稳定的原文文字。
- `warm-sage`：既有事实确认徽标和保留说明卡片。

### Neutral

- `warm-paper`：浅色页面背景与固定输入区背景。
- `warm-white`：卡片、输入框和 TabView 的指定工具栏背景。
- `warm-ink`：浅色正文与橙色按钮文字；卡片和输入框的描边由其透明度构成。
- `secondary-text`：`RecordingFormat.secondary`，用于浅色界面的辅助文字。
- `recorder-background`、`recorder-panel`：仅对应 `LiveRecordingView` 的全屏背景与原文容器。
- `recorder-secondary`：深色录音页的辅助文字、时间戳、状态与录后说明。
- `recorder-white`：深色主文字及发送箭头。

系统语义颜色 `.secondary`、`.green`、`.red`、`.brown` 与材料样式继续由平台提供；没有把它们伪装成固定 RGB。录音状态的小圆点也保留源代码的状态用色，不能单靠圆点代替文字状态。

**The Recorder Scope Rule.** 全局仍是浅色；深色方案局限于录音全屏页，其 presentation 指定 `.preferredColorScheme(.dark)`，状态栏采用浅色文字。

## Typography

全局 `RootView` 使用 `.fontDesign(.rounded)`，录音与连续语音 presentation 同样声明系统圆角字体。中文由系统字体回退处理；没有新增字体文件或下载依赖。

| 实际样式 | 当前用途 |
| --- | --- |
| `.largeTitle.bold()` | 既有欢迎页主标题 |
| `.title2.bold()` | 首页主标题、连续语音状态 |
| `.title3.bold()` / `.title3` | 下一场标题、项目目标 |
| `.headline` | 分区标题、项目和场次标题 |
| `.body` / `.body.weight(.semibold)` | 正文、实时原文、主要按钮 |
| `.subheadline` | 项目描述、会前说明、原文容器标题 |
| `.caption` / `.caption2` | 日期、阶段、范围、状态和时间戳 |
| `recorder-title` / `recorder-timer` | 录音标题与固定数值计时器 |

语义样式保持系统字号与 Dynamic Type 缩放，不记录虚构的固定字号、行高或字距。录音标题与计时器是源码明确指定的固定尺寸，计时器使用 `.monospacedDigit()`。产品正文通常有 (5pt) 行间距，实时原文为 (6pt)；首页下一场目标为 (4pt)。

## Layout

产品页以可滚动单列和原生安全区组织。常见页面内边距为 `page`，首页分区间距为 `home-section`。首页内容居中且最大宽度为 (700pt)；当前项目和场次详情沿可用宽度排布，没有统一 (700pt) 限宽，也没有定义网页式断点。

项目场次使用水平滚动时间线：普通卡片内容宽 (180pt)，内边距 (16pt)；新增场次块为 (150 × 100pt)。移动端的右侧部分卡片是水平滚动内容。固定 `ProductInput` 通过 `.safeAreaInset(edge:.bottom)` 位于系统导航区域旁，范围标签允许按内容换行，输入区设置 `.fixedSize(horizontal:false,vertical:true)`。文本输入为 (1–5) 行。

首页头像与录音入口、输入麦克风与发送按钮的框为 (44 × 44pt)。主要产品文字操作使用最小 (44pt) 高度；`RecordingPrimary` 最小高度见前置 token。连续语音的静音、切文字、结束三个圆形控件为 (54 × 54pt)。

iPhone 与 iPad 由同一 SwiftUI `TabView` / `NavigationStack` 适配。当前 iPhone 使用底部系统 tab，iPad 截图为顶部系统 tab；没有手工绘制替代导航。截图审查覆盖与局限见 `docs/PRODUCT_UI_REVIEW.md`。

## Elevation & Depth

产品页面以色面层次、留白和薄描边为主。`WarmCard` 为 ink (0.08) 透明度描边；输入框为 ink (0.15)，按住语音时改为 purple。录音状态条为 purple (0.22) 描边。原文容器的分隔线叠加 white (0.12)。

既有 `PrimaryButton` 保留棕色 (0.3) 透明度的硬边底影，模糊半径 (0pt)、默认下移 (4pt)，按下时影下移 (1pt) 且内容下移 (2pt)。产品扩展使用的 `RecordingPrimary` 没有这层阴影。系统 tab、工具栏、sheet 与材料层由平台绘制；这里没有新增全局阴影 token。

## Shapes

主要圆角以源码值为准：卡片与录音原文容器使用 `warm-card`；产品项目行、时间线和主要按钮使用 `action-and-project`；输入区使用 `composer`；发送按钮使用 `recorder-note`。徽标使用 `Capsule()`，头像与连续语音控件使用 `Circle()`。图标沿用 SF Symbols。

## Components

### Buttons

`RecordingPrimary` 是产品页和录音页当前主按钮：橙底、ink 字、语义正文半粗体、圆角 (16pt)，最小高度 (50pt)，按下 opacity (0.8)，禁用时整体 opacity (0.45)，两个状态修饰按源码叠加。既有 `PrimaryButton` 仍用于欢迎和素材页，保留 (15pt) 内边距与硬边按下反馈；不把这两个 ButtonStyle 的状态混为一套。

### Chips

既有 `TrustBadge` 使用 capsule，水平内边距 (10pt)、竖直 (6pt)，事实状态为 sage 背景与系统 green 文字，待确认状态为 lavender 背景与 purple 文字，并同时显示文字和图标。场景与场次阶段采用原生 segmented picker。

### Cards / Containers

`WarmCard` 默认近白，内部纵向间距 `card-content-gap`，内边距 `warm-card-padding`，ink 轻描边。下一场仅替换为 lavender 背景。`ProductProjectRow` 为近白圆角行，竖直内边距 (16pt)、水平 (18pt)，描述限制两行并显示场景、阶段和示例标识。场次时间线卡片遵循 Layout 中的独立尺寸。

### Inputs / Fields

`VoiceComposer` 包含麦克风、垂直可增长 TextField 和发送按钮。容器内边距、间距均为 (8pt)；TextField 竖直内边距 (9pt)。发送箭头为白色，空输入时 opacity (0.45)；禁用条件还包含聊天控制忙碌、加载中和连续语音活跃，不能由颜色推断全部禁用原因。整个输入在项目非 active 或聊天加载中时禁用。表单编辑器继续使用原生 `Form`、`TextEditor` 与工具栏动作；本轮截图未验证键盘展开。

### Navigation

四个系统导航目的地为首页、项目、录音、记忆库。深入页面使用 `NavigationStack` 与原生返回。录音使用深色 `fullScreenCover`，保留收起和更多菜单；连续语音也是全屏，但继续使用浅色 Warm 背景。系统 hover、focus 与导航装饰没有被重写为网页样式。

### Recorder transcript

深色原文容器在页面中占据可用滚动空间，稳定文字为 white，尚未稳定文字为 lavender，辅助状态与时间戳用 `recorder-secondary`。时间戳位于每条原文上方，支持文字选择。用户向上查看时暂停跟随，提供 capsule「回到最新」，按钮最小高度 (44pt)。容器内边距为 (18pt)，外侧水平边距为 (16pt)。

### Voice motion and imagery

连续语音的 lavender 圆背景大小为 (152pt)，Mascot 为 (106pt)，按音量放大系数为 `1 + level × 0.12`，使用 `.easeOut(duration:0.12)`；Reduce Motion 开启时关闭该显式动画。没有新增运动规则。

唯一保留的品牌位图是 `ios/CanDid/Assets.xcassets/Mascot.imageset/mascot.png`，由既有 `Mascot` 组件缩放显示，accessibility label 为「Candid 紫色双气泡」。本轮没有生成、下载或替换它。可核实来源是任务开始前已存在的仓库资产；原作者、最初生成方式与授权资料未随本轮提供，不能补写推测来源。资产审计记录见 `docs/PRODUCT_UI_REVIEW.md`。

## Do's and Don'ts

### Do:

- Do 沿用 Warm 源码配色、系统圆角文字和 SF Symbols。
- Do 为录音全屏页保留局部深色 scheme 与浅色状态文字。
- Do 保留原生导航、安全区输入、Dynamic Type 语义样式与已实现的禁用反馈。
- Do 用文字与图标共同表达状态，并保留示例、草稿、待确认和原文依据标记。

### Don't:

- Don't 把局部深色录音方案扩展为整个应用的新视觉方向。
- Don't 新增字体或替换现有 Mascot 来改变已固定的视觉体系。
- Don't 把系统动态字体、语义颜色或原生导航伪装成已定义的固定网页 token。
- Don't 用示例截图推断真实数据、外部发送、ASR 或硬件已经通过验收。
