# 记忆库 FAQ

参考：`docs/references/candid_memory_faq_docs_sales_prototype.html`。

记忆库分为「我 / FAQ / 背景资料」。原有表达积累、跨场发现移到「我」下，资料上传、失败重试、移除与查看沿用真实接口。

FAQ 包含搜索问题和说法、待改进列表就地展开、主题与问题浏览、提问次数与最近更新排序、说法编辑、主题调整、适用时间和截止日期、历史版本、每次原始问法、按来源录音定位回听。Mock 入口会进入真实聊天发起该题的模拟，不会用提示条冒充已练习。

说法、主题、有效期通过 `PATCH /v1/companion/faq/{expression_id}` 存入现有账号隔离的数据存储，使用版本号保护并发更新。表达积累页更新说法同样保留 FAQ 历史。用户修改后状态为「还没用过」；过期或原文依据失效回到待改进。模拟不自动标记实战有效。

使用真实问题分组和原文依据，不复制 HTML 里的虚构客户、数字和效果。主题的初始归类使用关键词，未匹配归为「其他」，允许用户修改。没有真实客户关联统计时显示沟通场数。

当前范围不包含：从客户后续反应判定「管用」、资料更新后自动改写引用回答、资料缺口的自动检测、会前提醒开关、系统到期通知。截止日期在 FAQ 中提示更新；背景资料支持既有文件类型。修改后的接口需要随服务端一起部署，尚未部署至线上。

验证记录见本目录截图和 `.build/faq-*-tests.log`；编译记录见 `.build/faq-final-build.log`。

## 已完成检查

- iOS 模拟器 Debug 编译通过。
- `backend/tests/test_companion.py`：24 项通过，包含 FAQ 域与 HTTP 保存、历史保留、空输入及非法日期、账号隔离和版本冲突。
- `testFidelityPopulatedMemoryAndSourceNavigation`：通过，涵盖搜索、问题详情、原有表达修改入口和跨场发现。
- `testMemorySegmentsAcceptRepeatedEdgeTaps`：100 次分类点击通过。
- `testFAQSearchAndEditingControls`：通过，涵盖搜索空结果、清除搜索、说法编辑、适用时间、截止日期选择与取消。

截图：[首页](faq-home.png)、[详情](faq-detail.png)、[编辑](faq-edit.png)。截图使用仅测试模式下的既有示例数据，真实账号不填充示例。
