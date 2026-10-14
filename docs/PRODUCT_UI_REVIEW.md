# 首轮产品界面视觉验收

记录日期：2026-10-15（Asia/Hong_Kong）。方向依据：`docs/PRODUCT_SURFACES.md`、用户已确认的功能扩展、既有 Warm 紫色／米白／橙色与系统圆角原生设计。新深色方案局限于现场录音全屏页。提取的实际视觉规范见根目录 `DESIGN.md` 和 `.impeccable/design.json`。

**Disposition Ship（本轮视觉验收范围）**

独立 finish reviewer 的最终结论为：完成界面修正后，静止的大字号销售项目页标题、阶段、时间线与固定输入区可读；深色录音页的时间、网络、电池状态现为浅色并可读。最终复核中这两项发现已解决。此结论限于下述模拟器画面和源码核对，不是全功能或真机验收结论。

## 证据范围

| 捕获集 | 环境与状态 | 已查看的表面 | 证据用途 |
| --- | --- | --- | --- |
| `/tmp/candid-product-final-captures/` | iPhone17、iOS27 simulator，`content_size accessibility-large` | `review-home.png`、`review-sales-project.png`、`review-sales-preparation.png`、`review-live-recorder.png` | 修正后的最终静止画面：大字号布局、固定输入、禁用主按钮、深色辅助文字和状态栏 |
| `/tmp/candid-product-captures-2/` | iPhone 正常字号参考 | `product-interview.png` | 面试项目内容层级、准备素材卡片、时间线与系统导航 |
| `/tmp/candid-product-ipad-captures/` | iPadPro13M5、iOS27 simulator，默认字号 | `review-home.png`、`review-sales-project.png`、`review-sales-preparation.png` | 首轮 iPad 表面导航与宽屏布局参考；不作为后续禁用按钮修正后的重捕证据 |

以上截图由模拟器示例资料或 synthetic-caption fixture 生成。已逐张查看表内列出的画面；临时路径仅表示本次本地证据位置，未声称截图已归档到仓库。旧 iPad live-recorder 截图捕获到 presentation 动画过渡，已排除；录音结论使用最终 iPhone 静止且含示例原文的画面。项目页最终复核也使用已稳定的捕获，排除过渡中的导航画面。

## 已完成的修正与核对

| 项目 | 当前实现证据 | 复核结论 |
| --- | --- | --- |
| 深色辅助文字 | `RecordingUI.swift`：辅助文字和时间戳为 `Color(red:0.78,green:0.75,blue:0.84)`；背景为 `(0.09,0.08,0.12)`、原文容器为 `(0.15,0.13,0.20)` | 最终录音画面辅助说明、时间戳与状态可读；稳定文字 white、临时文字 lavender |
| 图标触达 | `ProductViews.swift` 首页头像和录音入口为 `(44 × 44pt)`；`VoiceViews.swift` 麦克风和发送按钮为 `(44 × 44pt)` | 源码尺寸已核对，最终首页画面保留可见入口；没有把视觉检查当作物理触摸测试 |
| 禁用主按钮 | `RecordingPrimary` 读取 `Environment.isEnabled`，禁用 opacity 为 `(0.45)`；离线会前整理按钮 `.disabled(!store.remote)` | 最终大字号会前页显示减弱的禁用主按钮及连接说明。早期 iPad 画面是修正前参考 |
| 深色状态栏 | `RecordingShell` 的 recorder `fullScreenCover` 指定 `.preferredColorScheme(.dark)` | 最终静止录音画面时间、网络与电池使用可读的浅色样式 |
| 大字号项目页 | 最终 `review-sales-project.png`；项目与固定输入使用原生安全区布局，范围标签可换行 | 标题、阶段、水平场次时间线和范围输入区可读。横向场次卡片部分进入画外是滚动结构 |
| 原生导航与层次 | iPhone 正常面试参考和 iPad 三张表面截图 | 场景／阶段选择、项目时间线和返回入口保留原生组织；iPad 系统 tab 位于顶部 |

本记录不新增 UI 方向或待办建议。视觉修正由独立 finish reviewer 完成；文档作者只核对源码、现有资产与提供的截图并写入本记录。

## 验收边界

- 覆盖本地 SwiftUI 模拟器的示例首页、销售项目、面试项目参考、空准备页、最终含合成原文的录音页，以及表内明确列出的字号与设备状态。
- 未查看展开键盘、真实且已填充的准备包与会后跟进、实际系统通知触发或邮件发送画面；不能宣称这些视觉状态已通过本轮截图验收。
- 不证明录音豆按钮、真实手机触摸、设备音频、回声抑制、实际 ASR 延迟／准确性／分人效果，也不证明生产环境能力。
- 文档步骤未运行软件测试、构建、安装包或上下文启动器。软件实施、测试、交付和外部提交记录由本轮主交付文档单独负责。

## 位图来源记录

| 资产 | 可核实来源 | 本轮处置 |
| --- | --- | --- |
| `ios/CanDid/Assets.xcassets/Mascot.imageset/mascot.png` | 已存在的仓库资产；`Mascot` 组件引用 `Image("Mascot")`。原作者、最初制作／生成方式与授权材料未提供 | 保留原图；没有新增、下载或替换 raster |

本地核对大小为 `677795` bytes；SHA-256 为 `c997b11e1570c85a8af0ba5143cfbdc5dce538bbc6fc5a4a01cb387369ff8414`。此记录确认本轮保留的具体文件，不补造来源或授权信息。
