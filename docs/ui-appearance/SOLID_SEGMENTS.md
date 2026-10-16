# 页内实色分段与阅读位置修复

2026-10-16。用户要求取消页内分类的液态玻璃，保留底部系统液态玻璃导航、原版按钮及现有功能。

## 原因与复现

旧组件是自绘 Plain Button，加在选中标签上的交互式 glassEffect，未选中为 identity。组件没有显式的完整矩形点击区域。这个组合被替换，但没有把玻璃直接当作已经证实的唯一漏点原因：修复前短内容样本中，复盘和记忆库各 100 次交替点击，覆盖中心、左右留白及上下边缘，全部成功（`.build/TestResults/Segments-Baseline.xcresult`）。

补充复现了直接漏点：按钮之间的 `HStack(spacing: 4)` 留下 4pt 空隙。先选原文，再点分界线左侧 1pt，复盘没有被选中；失败信息记录两按钮间距 4.0pt。见 `.build/TestResults/Segments-Divider-Baseline.xcresult`。这解释了为什么文字中心和一般边缘测试能通过，靠近中缝时仍会点空；不需要假设是云端或 API 延迟。

真实复现的阅读问题：

- 长原文滚动时，播放器和分类一起滚走，分类会变为不可点击；控件跟随可变正文滚动，其位置不稳定。旧长文本测试在分类可达性断言失败，尚未执行到长短切换后的坐标比较，不能将该用例写成“已经实测长短切换导致位移”。
- 指定句子进入后每五秒再次执行 scrollTo。用户滚动后的句子纵坐标从 92.67pt 被拉回 486.67pt，差 394pt。刷新确实抢走阅读位置。两项复现见 `.build/TestResults/Segments-Scroll-Baseline3.xcresult`。

## 修改

- 删除页内 CompanionSelection 与交互玻璃，统一浅暖底槽、白色选中块和轻微底边阴影。各格字重和布局固定，显式定义完整矩形 hit region。两格外部间距改为零，4pt 视觉间距通过按钮背景内部各 2pt 留白保留，因此视觉比例不变、点击区域连续；保留 Button 的原生操作和选中辅助功能语义。
- 复盘的日期／标题、共用播放器及分段成为稳定页头，正文独立滚动；记忆库的共用页头、发现卡及分段同样不再随分类正文变化。常规字号的首屏顺序和原有间距保持一致。极大辅助字号与横屏只固定分段，把完整元信息／播放器／发现卡放入滚动内容，避免页头挤压导致标题省略。
- 原文定位从五秒循环移到正文布局完成后的单次执行；下一主线程周期读取已注册的原文锚点，每次打开只定位一次。后台数据刷新、认领说话人、修订后读取不会把用户拉回原句。
- 底部 TabView 及其系统液态玻璃没有改动；TTS、连续对话、上传、完整播放器、逐句播放和原文编辑保留。新增长原文与指定句子的入口只在 DEBUG 隔离测试中可用，不连接用户数据。

## 验收

后端没有改动，无需部署或调用付费模型。原生测试 26 项通过（`.build/TestResults/Segments-Fixed.xcresult`）。该结果中正常／边缘点击各页 100 次、大字号主页与记忆库、主导航、长短内容切换和逐句原音入口均通过；初始定位测试暴露布局时序问题，已通过单项回归 `.build/TestResults/Segments-Layout-Confirm.xcresult` 修复。

iPhone 15 Pro 尺寸的来源导航、大字号复盘（正文仍超过 100pt、认领及修订按钮可达）和长短内容稳定性在 `.build/TestResults/Segments-Focus-Confirm.xcresult` 中通过；其中旧定位失败项由上述 Layout-Confirm 的通过结果替代。中缝和最终连续点击结果另列于最终交付追加记录。

最终点击验收：`.build/TestResults/Segments-Final.xcresult` 全部通过。复盘和记忆库各 100 次交替点按，覆盖中心、左右和上下边缘；中缝两侧 1pt 连续切换 10 次通过；首次句子定位及六秒后不回跳也通过。自动点按按 XCTest 调度执行，不将其称为高帧率性能基准。

辅助大字号最终确认：`.build/TestResults/Segments-Adaptive-Confirm.xcresult` 四项全部通过。标题和日期完整换行；固定分段下正文仍可阅读，认领和修订按钮可滚动到达；常规字号长短切换与初始定位／刷新回归再次通过。结合本轮结果，26 项原生测试和 10 种 UI 场景均有通过记录，覆盖 iPhone 17 与 iPhone 15 Pro 尺寸。

- [复盘实色分段](solid-segments/report.png)
- [记忆库与保留的系统底栏](solid-segments/memory.png)
- [长原文](solid-segments/long-transcript.png)
- [辅助大字号完整标题及元信息](solid-segments/large-text.png)
- [用户滚动后刷新不回跳](solid-segments/after-refresh.png)

Release 真机签名构建成功（`.build/segments-device-adaptive-build.log`），严格 codesign 验证通过。已覆盖安装到已配对的 iPhone 15 Pro，沿用原 Bundle ID，不卸载、不清空数据。回执在本机 `.build/segments-device-install.json`，真实设备截图不提交到仓库。
