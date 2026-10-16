> 后续更新：主导航仍为系统液态玻璃；页内分类已按用户要求改为实色分段，见 [最新修复](SOLID_SEGMENTS.md)。

# 固定外观，恢复原生 Tab 切换

2026-10-16，替代此前可切换的自定义底栏。用户选定“悬浮胶囊＋液态玻璃＋原版立体”。

Git 中最早的三个目的地导航（`b3d8ebc`，更早版本也相同）使用 SwiftUI TabView。此次恢复该实现方式，转场与玻璃选中效果交给系统，不恢复 fc0ea79 中自定义页面 opacity、重复底栏及整控件匹配变形。独立 NavigationStack、Chat 草稿、完整播放器和逐句播放继续保留。

设置中删除整个“界面外观”分组，并删除对应的枚举、偏好读取、预览与自定义主底栏。无需清空用户资料或重新填写引导；旧外观偏好不再参与运行。快捷按钮固定为原版的暖橙／白底、描边与底边立体效果。系统 Tab 栏在 iOS 26+ 为悬浮玻璃形态；其他系统版本与 iPad 的具体位置、大小、触控与辅助功能由平台处理。

根页通过系统工具栏显示策略隐藏键盘期间的 Tab 栏，二级报告明确隐藏 Tab 栏，返回后恢复。布局与转场由同一个系统 TabView 处理，没有额外的自定义底栏或整页透明度动画。


验证结果：iPhone 上的单一系统 Tab 栏、连续切换、设置项移除、重启保持固定外观、聊天草稿保留、键盘避让、连续对话的显式按钮及头像双击、报告隐藏底栏与返回、逐句播放入口均通过 UI 回归。iPad 的首页和报告导航回归通过。最终原生截图来自 XCTest，不使用此前出现帧流不同步的 simctl 录像作为本次转场证据。

- [固定原生导航与原版按钮](native-tabs/iphone-home.png)
- [已关闭的外观设置](native-tabs/settings.png)
- [准备报告隐藏主导航](native-tabs/preparation.png)
- [原文逐句播放](native-tabs/sentence-playback.png)
- [iPad 系统原生布局](native-tabs/ipad-home.png)

结果包：`.build/TestResults/NativeTabs-Confirm2.xcresult`、`NativeTabs-iPad-Confirm.xcresult`；草稿与连续对话分别在 `.build/TestResults/NativeTabs-iPhone.xcresult` 中通过。一次界面测试用系统菜单的内部标识查找失败，后改为实际显示的“个人与设置”菜单名称，操作及设置移除断言通过。

Release 真机签名构建成功（`.build/native-tabs-device-final-build.log`），codesign 严格校验通过。已覆盖安装至已配对的 iPhone 15 Pro，并通过 devicectl 成功启动；沿用原 Bundle ID 与 Personal Team，不卸载、不清空用户数据。安装和启动回执保存在本机 `.build/native-tabs-device-install.json`、`.build/native-tabs-device-launch.json`。
