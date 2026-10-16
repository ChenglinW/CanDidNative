# Tab 切换闪烁修复

2026-10-16。基线为 `fc0ea79`。

原实现把底栏放进三个各自驻留的 NavigationStack，又通过 `withAnimation` 修改共享 section。此事务同时驱动三页 opacity 和三份玻璃／Material 底栏的透明度；切换录像可见页面叠影、图标和底栏变淡。另一个原因是选中修饰器把完整 label 放在不同条件分支里，导致选中／未选中切换时重建文字和图标。

修复将底栏移到三页以外的单一 VStack 布局位置，实际给输入框与列表留出高度。页面可见性直接切换。前景 label 始终挂载，玻璃用同一修饰器的 `.regular`／`.identity` 切换材质；取消整控件的匹配变形及外加的 Tab 动画，保留系统玻璃按压反馈。原有三套 NavigationStack 与 Chat 草稿继续驻留；系统 push/pop、键盘和详情隐藏底栏规则保留。

同一个新回归用例在基线上检测到 3 份“记忆库”主导航按钮而失败，修复后检测到 1 份并通过。录像为合成数据的原生模拟器捕获，用于检查视觉过渡，不代表真机帧率或 ProMotion 性能基准。


对照证据：[基线过渡帧序列](tab-switch/before.png)、[基线复现短片](tab-switch/before.mp4)，以及最终 XCTest 捕获的[手机界面](tab-switch/iphone-home.png)、[平板界面](tab-switch/ipad-home.png)。真机用户资料截图仅保存在本机 `.build`，不上传仓库。

最终检查覆盖全宽／悬浮胶囊 × 玻璃／经典选中态四种组合、两种按钮质感、设置重启保存、Chat 草稿、键盘避让、辅助功能大字号、详情隐藏底栏与逐句播放入口。原生单元测试 22 项通过。主测试结果为 `.build/TestResults/TabSwitch-Stable-Verified.xcresult`、`TabSwitch-iPad-Stable.xcresult`、`TabSwitch-Layout-Verified.xcresult`。

保留三个页面各自的 NavigationStack，不重建聊天或清理资料。手机采用原应用标识覆盖安装；未增加后端调用、付费模型调用或依赖。


后续 simctl 录像中出现与当前 XCTest 截图时间／画面不一致的帧流，因此未将其作为最终版本的动态对照证据上传；最终外观以 XCTest 附件及当前源文件摘要为准，不宣称完成了真机帧率测量。真机已覆盖安装并成功启动；截图显示后端已连接。
