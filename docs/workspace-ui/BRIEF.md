# 独立客户工作区 · 2026-10-16

用户参考：`docs/references/CanDid_独立工作区页面_20261016.html`。这是产品/视觉参考，内部示例与模拟流程不作为已完成服务能力的证据。

## 确认的方向

- 首页保持 Warm 米白、现有 Mascot、原生液态玻璃三主导航；结构改为会前准备轮播、最多三位客户 Tracker、消息输入及底部工作区控制。
- 准备包按会议时间倒序；未定时间最后、按生成时间倒序；无自动轮播。过期包保留，由用户明确结束。Tracker 可按活跃、场次、名称排序；短线表示沟通积累，不是成交概率。
- 点击客户或输入，使用 NavigationStack 进入独立客户对话页；客户名称与业务方向、沟通场次/客户信息链接、历史/准备包、固定底部输入。保留显式连续对话按钮、头像双击、长按说话和逐句原文播放。
- 用户明确要求额外保留“复盘上一场”：输入框下方左侧为文件夹＋工作区名称＋下拉箭头，右侧为淡紫实色、12pt 字号、最小 44pt 高的复盘按钮，不恢复旧的大尺寸等分双按钮。
- 复盘按钮直接进入当前客户最近一场已确认录音的复盘页；首页通用/新会话可查看全库最近录音。无对应录音时打开设备引导，不错误复盘另一客户。
- 小型工作区弹出菜单支持搜索与分页、选择已有客户、新建；新会话不要求填写技术或客户表单，首次实际发送/使用语音时创建真实工作区。
- 用户已确认：统一录音库、多个自动/手动标签继续保留；主要客户需用户确认，用于计数和客户对话复盘。可暂不确认。重复确认不重复计数；确认在复盘前/后均可，复盘准备好后只发布一次到该客户。
- 未确认的新录音不通过自动标签进入客户动态上下文。确认后其他客户不会因同名标签自动取得内容；用户显式关联来源仍可跨客户读取，主要归属和计数不改变。
- 既有客户工作区、历史、草稿、阅读位置、归档、准备包只读报告、记忆规则、手机会议录音备用入口保持；未实现客户合并或已确认录音改归属的产品规则。

## Direction contract

Code-led extension of the supplied HTML v1.1: Warm paper #F7F3E9, near-white surfaces, ink text, purple actions, lavender preparation/user-message accents. Follow the supplied proportions and flat page-local controls; retain the explicitly approved native glass root tab bar. No new imagery or dependencies.

FIRST VIEWPORT: a real, fixed dashboard shows a paged preparation and up to three customer Trackers; composer plus workspace/recap actions remain reachable above system navigation. At accessibility text sizes, content is scrollable and bottom actions stack without clipping. A customer push has no root tab bar, a clear back action, contextual links, and an independent thread; there is no overlay/collapse interpretation.

Signature interaction: native push/back between dashboard and independent chat, an anchored workspace chooser, and explicit previous-recording recap. Honor system Reduce Motion; no automatic preparation carousel rotation.

Quality bar: reference structure and hierarchy; >=44pt primary touch targets; typed drafts/reading position remain scoped; real source/report IDs and recording playback stay wired; pending assignment, loading, offline and errors remain honest; valid phone/tablet/large-text Simulator captures, functional XCTest and backend regression evidence. Native path: no HTML/CSS detector is applicable.

## Compatibility

`customer_id` currently equals the stable workspace ID; workspace already owns its stable default thread. No destructive customer migration or entity merge is introduced. Backend persists optional primary-customer fields in existing session JSON; new clients opt in using `customer_assignment_required: true`. Older installed clients keep their prior recording behavior until upgraded, so deploying this server does not strand recordings behind an absent confirmation screen.
