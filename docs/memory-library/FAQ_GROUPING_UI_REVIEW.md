# FAQ unified grouping finish review

2026-10-16。独立、只读、code-led 复核；审阅者仅新增本记录，未改应用代码，也未重新运行测试。方向依据为 BRIEF.md、FAQ_GROUPING.md、PRODUCT.md、DESIGN.md，以及 impeccable 的 craft-floor.md 与 ios.md；现有 Warm 方向优先于通用默认样式。

## Capture validity

逐一使用 `view_image` 查看 `.impeccable/review/faq-unified/` 的八张原生截图：phone／tablet 各自的 `unified-faq-groups`、`unified-faq-group-detail`、`unified-faq-member-detail`、`memory-large-faq`。手机图为 1206×2622，平板图为 2064×2752；两组均包含状态栏、原生返回或根导航，并展示实际 SwiftUI 内容。

`CanDidUITests.swift` 的相应测试通过真实 App 启动环境连接本地 HTTP 后端，按问题进入组，再进入「价格怎么解释？」成员详情；大字号用 Accessibility XXXL 启动。图像内容与当前 `MemoryLibrary.swift` 的页面结构一致。运行通过状态由主任务提供：手机 3 项、平板 2 项；本审阅未独立重跑或从图片反推测试通过。

## Disposition

**Ship：本次 FAQ 分组 UI 可交接，无需为视觉完成度修改代码。**

八张图中未发现新分组路径的实质视觉阻塞：Warm 米白、紫色辅助信息、淡紫当前说法和暖橙 Mock 动作保持一致；根分类、组列表、组详情、独立 FAQ 详情的层级清楚，手机与平板正文均可读。常规字号图中未见意外截断或横向溢出。大字号根列表自然换行，手机下方内容超出首屏属于可滚动正文，不能当成静态截断。

## Material findings

没有需要修复的本轮实质问题。

- 组页明确说明「相似问法放在一起，每次回答与资料依据分别保留」，逐个问法显示状态和各自说法；没有综合答案、统一有效徽章或暗示全组已验证的色面。
- 列表组行及成员入口的 `NavigationLink` 使用全宽容器和矩形命中区域；组行最小 60pt，成员入口沿用最小 60pt 的 `LibraryItemRow`。组内说法是浏览预览，最多四行，完整内容在成员详情；这是明确的内容层级，不能把预览本身当成全文丢失。
- 独立 FAQ 页保留「你的说法 · vN」「尚未实战」「练习记录 · 不计入实战」、版本历史与恢复、资料关联、Mock、会前提醒；源码仍按 item ID 读取、修改与恢复，未从组生成回答副本。原文回听仍按成员的证据引用进入。截图的 0 场沟通与「沟通记录」回退没有冒充已识别客户。

## Scope & limits

结论限于本轮 FAQ 分组衔接及其成员详情，不扩展到其他页面，也不将旧通用样式偏差列为本次阻塞。没有新 comp、网页 detector 或视觉系统替换。

大字号的两张图只覆盖按主题的 FAQ 根页，未覆盖组详情或成员详情；因此不能声称分组全路径已完成大字号实机验证。静态截图也不能证明 edge-swipe、VoiceOver、Reduce Motion、长内容滚动或物理设备上的手势与性能。没有进行逐像素对比度测量。固定 Warm 浅色遵循当前产品约定。

主任务报告的本地 HTTP 测试包含模型替身边界；另有真实 embedding 的四问合成测试。这些均不等于真实用户数据质量、生产部署、硬件、麦克风或声学验证。本审阅仅核对对应证据的表达边界，不重新背书模型效果。

## Handoff

保留本次实现与八张截图，可随主任务交付。对外表述应为「原生手机／平板模拟器 FAQ 分组浏览与独立成员详情通过；根页另有辅助大字号截图」，并将本地 HTTP、真实 embedding 合成测试、未做物理设备验证分别说明。没有新增确认步骤或额外发布审批。
