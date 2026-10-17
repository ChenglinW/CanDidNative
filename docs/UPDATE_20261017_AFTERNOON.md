# Update 同步记录 · 2026-10-17 下午

## 同步

- 本地从 3df8016 快进至组员 master 47936b3，没有合并冲突；保留备份分支 backup/pre-update-20261017-afternoon-3df8016。
- ca263fb：合并表达积累与故事素材入口，同时补充模型流式结果兼容、上游失败详情与分步骤重试显示。
- 47936b3：加入表达评分雷达、声学分析、场景隔离和规则版本；修复记忆库历史期限恢复、问题组返回刷新、资料历史来源与编辑版本冲突。
- 注意：组员版本不只是新增评分，也修改了 FAQ 提取 prompt 与保存结构，分离本场关键问答 session_qa 和长期可复用 items，并使用短来源 ID。这是组员提交带来的变更，不宣称后续 FAQ prompt 与之前相同。
- 模拟引擎 roleplay.py、标记前置语义增强、录音标记逻辑及文本供应商配置文件未被组员提交改写。

## 本地交付

将已有完成的 docs/showcase 静态评委展示页一并纳入版本，包括演示控制、五章节、素材来源和此前验收记录。展示页不调用正式模型或写入用户数据。本轮检查 JS 语法、本地 HTML 资源与 JSON 记录均通过；浏览器交互记录沿用展示页原交付，不冒充本轮重新进行的浏览器测试。

同步前将未跟踪展示页备份至忽略目录 .build/update-20261017-afternoon/showcase-before-update.tar.gz。未跟踪 ios/.DS_Store 保留，不提交。组员已提交的其他 .DS_Store 本轮不改写历史或另行清理。

## 验证

后端全量 405 passed，2 项既有依赖提醒，32.97 秒。日志 .build/update-20261017-afternoon/backend.log。

iOS 通用模拟器目标编译通过（BUILD SUCCEEDED），日志 .build/update-20261017-afternoon/ios-build.log。本轮未重新运行 UI 自动化、付费模型接口或物理麦克风测试。

## 服务器范围

实查 candid 服务 active，当前线上 release 为 /opt/candid/releases/20261017-expression-scoring，健康接口正常。组员发布记录说明这是定向评分与声学补丁，不能将其等同于所有最新 master 文件已完整发布。本轮 update 不重发服务器、不覆盖安装 iPhone。
