## verdict

本次仅评分 `UI_REVIEW.md` 的原四项修复，未重新寻找其他问题。已重读同路径全部 13 张必需截图；重采 `v2-empty-home.png` 单独以 original detail 读取，清楚包含 3:52 状态栏、Candid 固定头部、中央空态、底部 dock 和三 tab，先前 recapture 已清除。其余截图内容与设备类别有效。未运行 App、重新渲染、调用付费服务或改动 UI 代码。

1. **resolved — Chat 上推与 Reduce Motion。** `CompanionHome` 的驻留 Chat 现在位于 `GeometryReader` 中，关闭位置为 `geometry.size.height`；展开、按钮收起、下拉和语音文本展开共用 `revealChat`。Reduce Motion 时显式动画为 nil 且取消位移。最终 `v2-chat-keyboard.png` 显示完整头部、收起动作、保留草稿与键盘上方输入；空态及有数据首页保留原布局。静态截图证明最终状态，位移范围和无障碍降级由所读源码确认，未将静态图片当作动效录像。
2. **resolved — V2 约定同步。** `PRODUCT.md`、`DESIGN.md` 与 `.impeccable/design.json` 已明确三个目的地、单一驻留 Chat、隐藏内部项目／会话选择、浅色会议录音、次要手机备用入口及当前动效；原始 Mascot 的既有资产来源边界保留。与最终 iPhone、iPad 和录音截图一致。
3. **resolved — 准备卡日期对比度。** `CompanionPreparationCard` 日期已使用 `Warm.purple`，最终 `v2-populated-home.png`、`phone-15pro.png`、`tablet.png` 及 `tablet-large-dark.png` 均可见紫色日期；对同一淡紫背景的对比度约 5.16:1，超过小字号 4.5:1 门槛。只读报告仍在纸色背景使用原辅助字色，无需随之改色。
4. **resolved — 连续语音连接恢复。** 最终 `v2-continuous.png` 明确显示“重新连接 Candid”。源码动作执行 `restoreConnection(force:true)`，连接中禁用重复操作并更新标题，失败呈现 `connectionError`；用户可在当前失败页执行恢复，不再只能重复“开始自由对话”。

## remaining

clear。上述修复批次未在已重读截图和对应改动中引入可见回归。本次 ship 仅覆盖原四项修复的评分，不代表重新审查整个产品，也不扩展为物理设备或外部服务验收。

disposition: ship
