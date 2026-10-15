disposition: fix

缺少独立 QUALITY BAR card；本次以用户钉选 HTML、SURFACE 和 iOS 平台约定判断完成度。代码主导且已指定精确 HTML，不要求另做概念抽签、comp round、seed、comp-diff。未运行 detector（原生 SwiftUI）。本审查只读截图及源码，未启动、渲染或测试 App；仅写入本报告。

## persistence

**fail：交付文档尚未同步 V2。** `PRODUCT.md` 仍规定“我 → 场景 → 项目”和四个导航目的地，`DESIGN.md` 仍描述旧项目页面、四 tab 与局部深色录音页；它们与已批准的 `docs/v2-validation/SURFACE.md` 和当前三个入口、浅色录音界面冲突。已告知这是文档更新前的审查快照，不能据此重新引入旧 UI；最终交付前需要更新两份约定。

证据检查通过：调用 brief 指定的全部 13 张必需截图均存在且内容有效。11 张 iPhone 17 状态截图为 1206 × 2622，`phone-15pro.png` 为 1179 × 2556，`tablet.png` 和 `tablet-large-dark.png` 为 2064 × 2752。均为完整设备画面，无黑屏或空白采集；文件名对应首页空／有数据、键盘、准备包、原文、记忆库、录音空态、设备引导、录音、连续对话及设备类别。`tablet-large-dark.png` 显示系统深色时 App 有意保留浅色，并展示大字号适配；这符合用户钉选的浅色世界，不应误报为未提供深色画面。主截图证据目录为 `.impeccable/review/product-audit-20261016/`。

另外查看了 `v2-http-chat-report.png` 与 `v2-http-home-report.png`；它们仅作为准备包引用的辅助证据，后者未保留完整顶部与底部，因此没有用它替代已有效的必需首页截图。父任务报告的 19 个原生单元测试和 8 个 UI 测试在本次没有重跑，业务服务和物理设备真实性不由截图证明。既有 Mascot 资产及来源边界在 DESIGN 的资产段已有记录，更新文档时应保留。

## fidelity

先查看必需设备截图，再独立提取 HTML 内嵌 prototype 的最终选择器和 `homeHeader`／`homeView`／`packetCard`。参考要素清单为：纸色底、近白输入及录音行、原始紫色双气泡 Mascot、圆角系统文字、固定 Candid 标题与介绍及麦克风、最多一张淡紫准备卡和三条录音行、橙色报告动作、底部快速动作与输入、唯一上推 Chat 及右上收起、三个导航目的地、带来源的原文。HTML 中间 CSS 曾包含的深紫卡片和旧页面不作为最终渲染规格。

| 要素 | 状态 | 依据 |
| --- | --- | --- |
| TYPE | match | `.title2`／`.headline`／`.body` 等原生圆角系统字承接参考的圆角语气；中文自然回退，标题与正文层级清楚。平台原生 San Francisco 是用户已确认体系，不触发网页展示字体禁令。 |
| MATERIAL | match | 原始 Mascot 位图保持存在；卡片为参考已有的平面淡紫／近白，没有把核心图像改画为几何近似，也没有伪造物理材质。 |
| GROUND | match | HTML 最终纸色 `#f7f3e9`，SwiftUI `Warm.paper=(.969,.953,.914)`，8 位近似同一色；lavender、white、orange 同样保持用户指定色系。 |
| 固定首页拓扑与空态 | match | `v2-populated-home.png` 是固定头部、一张准备卡、三条录音行；`v2-empty-home.png` 只有陪伴空态，没有虚构业务数据。 |
| 准备卡与报告入口 | adaptation | `CompanionPreparationCard` 按同一 `pack.id` 打开只读报告；日期、目标与 CTA 比 HTML 的小字号更易触达。用户要求原生可访问性及真实数据驱动，允许此尺寸适配。 |
| 主导航 | adaptation | 三个原生 tab 为 Candid／记忆库／录音；iPad 顶部 tab 和 iPhone 底部 tab 遵从原生平台，SURFACE 明确批准，不机械复制网页导航壳。 |
| Chat 静态状态与键盘 | match | 保留固定头部、右上收起与原生输入；`v2-chat-keyboard.png` 显示草稿和输入在键盘上方可用，源码通过 `focusComposer` 和 Store 保存草稿、阅读位置。 |
| Chat 上推动效 | contradicted | `CompanionHome` 对已驻留 Chat 只做 `opacity` 及 `offset(y: open ? 0 : 24)`；这只是 24 pt 的短移淡入，未实现用户明确要求的“从底部展开聊天层”。同处显式 `withAnimation` 未读取 Reduce Motion。 |
| 连续语音入口与备用录音 | adaptation | 可见“连续对话”、头像双击及 accessibility action 同时存在；手机会议录音位于设备引导和录音页次要入口，均由用户明确批准。 |
| 记忆、录音、原文及说话人 | match | 原生分段控件、回听、认领、修订与带时间戳原文可见；没有恢复旧项目选择器。来源关联的后台正确性留给独立后端审查。 |
| 设备引导和浅色录音 | match | 主动作仍是录音豆连接同步，备用手机入口较次；录音采用最新参考的浅色表面。 |

五项方向承诺核对：THESIS 和 STORY 已在首页状态、单 Chat 及报告 ID 入口体现；OWN-WORLD 的颜色、资产和字形保持；FIRST VIEWPORT 的卡片数量与空态保持；FORM 的原生三个目的地及隐藏内部 workspace 成立，Chat 动效存在上述偏差。首屏记忆点仍是紫色双气泡及淡紫下一场卡，内容没有被新仪表盘替代。

## ceiling

平台布局、安全区、原生 tab、分段控件、sheet、语义字号和主要 44 pt 触达区已使用。iPad 大字号截图的卡片与输入保持可见，首页在 accessibility size 可滚动是已批准适配。没有需要新增的装饰、纹理、品牌字体或素材。

尚未用好的原生能力是 Reduce Motion 的聊天展开降级，以及失败状态中的可执行恢复入口。`v2-continuous.png` 显示“需要重新连接”与“请先连接 Candid”，主按钮却仍是“开始自由对话”；`VoiceSession.begin` 的前置条件不满足时，该按钮只再次返回相同错误。返回首页后可经菜单进入设置，但当前失败页面没有说明这条恢复路径。

craft floor 的确定失败是准备卡辅助日期的对比度：`RecordingFormat.secondary=(.44,.44,.40)` 对 `Warm.lavender=(.933,.906,.98)` 为 **4.144:1**，小字号 `.caption` 应达到 4.5:1；相同颜色对纸色约 4.503:1、对白卡约 4.945:1，不应笼统宣称所有辅助字都不合格。未在必需截图发现额外眉题、渐变文字、字符冒充图标、硬块阴影或装饰玻璃。既有系统材料和用户原型中的圆角卡片不作风格性返工。

## material_fixes

1. **Fidelity／FORM：** `ios/CanDid/CompanionUI.swift` 的 `CompanionHome` 把 Chat 的 24 pt 淡入改为真正从底部上推的同一驻留层，并为 Reduce Motion 提供无大幅位移的降级；保留现有消息、草稿、阅读位置与收起行为，补动效或状态转换证据。
2. **Persistence：** 更新 `PRODUCT.md`、`DESIGN.md` 为已批准 V2：三个入口、单 Chat、隐藏旧项目 UI、浅色录音、次要手机备用录音及当前控件与布局；保留 Mascot 的既有来源边界，不补写资产授权推测。
3. **Floor／contrast：** 深化准备卡日期等淡紫底小字使用的辅助前景，使实际组合达到至少 4.5:1；检查 `CompanionPreparationCard` 及同配色的现有状态文字，保留原定淡紫底与主色。
4. **States／恢复：** 连续语音未满足连接前提时提供正确且可执行的连接／重试动作，或明确带用户返回连接设置；不要让“开始自由对话”重复落回同一未连接错误。依据 `VoiceViews.swift` 的失败截图和 `VoiceSession.swift` 的 guard，验证从该失败页面能完成恢复。

## keep

保留原始紫色 Mascot、纸色与淡紫／暖橙层次、固定首页的一包三录音、原生三 tab、单 Chat 状态保留、只读报告及次要手机录音入口；修复限定在上述四项。
