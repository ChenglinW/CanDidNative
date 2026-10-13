# 阶段一：Agent 运行结构交付

日期：2026-10-13。范围按完成计划中的第一次实施安排：拆分运行结构、工具注册、最小任务记录与接口草案。

## 已实现代码

| 位置 | 职责 |
|---|---|
| `backend/agent.py` | 兼容原有 `TextAgent` 入口 |
| `backend/agent_runtime/runtime.py` | 执行循环、单对话执行锁、请求幂等、预算和结果保存 |
| `backend/agent_runtime/providers.py` | 已有安克文本网关，模型返回校验与脱敏错误 |
| `backend/agent_runtime/context.py` | 鉴权后的用户/对话/任务上下文；沿用现有历史窗口 |
| `backend/agent_runtime/tools.py` | 工具注册、Pydantic 参数校验、任务权限、读写标记、超时和统一返回格式 |
| `backend/tools/memory_tools.py` | 四个记忆业务工具的定义 |
| `backend/adapters/contracts.py`、`sqlite_memory.py` | 记忆读取接口与当前 SQLite 实现；来源带稳定 ID 与版本标识 |
| `backend/tasks/store.py` | 任务、轮次、输入、状态、配置快照、工具进度和产物引用 |
| `backend/agent_config/runtime.json` | 聊天与调研分别设置预算；调研预算预留但调研工具未启用 |
| `backend/agent_config/services.env.example` | 独立的安克、DashScope、Monid 与记忆服务配置模板 |

现有 App 请求路径及核心返回字段保留。聊天回答新增可选 `task_id`；消息保存 `task_id`、`turn_id`；新增鉴权后的 `GET /v1/agent/tasks` 与 `GET /v1/agent/tasks/{id}`。参数中没有可由模型指定的用户身份。

任务记录位于 SQLite 的 `agent_tasks` 表，沿用 owner/private 和整库删除守卫。保存运行配置、预算、人格原文及工具定义的快照，不保存模型 Key。失败记录可重试错误；用户用原请求 ID 重试时复用任务 ID、增加 attempt；原始配置快照保留，最近重试的配置另存 `attempt_config_snapshot`。该手动重试是新执行，不声称从检查点恢复。

当前聊天仍同步返回完整消息。进度由原有 App 轮询获得。后端启动将正在运行的任务标为 `interrupted`，不自动重新请求供应商；事件流、取消、后台恢复和自动执行检查点在阶段四开发。

记忆服务的读写与版本交接方案见 [记忆服务交接草案](MEMORY_SERVICE_CONTRACT.md)。当前只实现四个查询工具的适配，现有业务写入仍由本机 Memory 承担；远程服务、全量读写迁移及双方确认尚未完成。

## 已确认模型与后续选择

后续通过阿里云百炼 DashScope 接入它支持且用户确认选用的模型，优先用官方 SDK。ASR 为 `qwen-audio-3.1-asr-flash-streaming` 和 `qwen-audio-3.1-asr-flash-filetrans`，保留原语言及录后分人要求。两路接口和官方 SDK 流式调用已成功；这份阶段一代码只读取配置，不启用 App 的 ASR 管线。延迟原因尚未确定，用户已决定暂不继续排查。

本阶段沿用已有安克文本 Agent 与 DeepSeek 文本复盘配置；新的文本型号、TTS、Monid 端点/预算到对应阶段确认。人格本阶段沿用原有提示，文件式 `SOUL.md` 与 Skill 按需加载属于阶段二。

## 本机启动与真机连接

在仓库根目录运行，按需指定现有私有文件；命令中只出现文件路径：

```sh
backend/.venv/bin/python backend/run.py \
  --env-file ../../.env.anker.local \
  --env-file .env.dashscope.local
```

`--env-file` 可重复使用，只读取允许的服务配置项；已设置的 shell 环境变量优先。私有文件名称以当前工作区实际文件为准；模板为 `backend/agent_config/services.env.example`，真实 Key 保存在 Git 忽略的私有文件中，权限设为 0600。配置不会发送给 App。新增渠道的 Key 必须独立保存，不能用安克或 DashScope Key 代替 Monid 凭据。

模拟器连接 `http://127.0.0.1:8000`。真机与 Mac 位于同一可信局域网时，追加 `--lan` 并填 Mac 的局域网地址；App 使用 `backend/data/local-access.txt` 中的本机访问令牌，供应商 Key 留在后端。Mac 必须保持后端运行。

免费 Apple 账号可在 Xcode 添加 Personal Team，设置唯一 Bundle Identifier、启用 iPhone Developer Mode 后使用 Debug 安装；签名有效期及可用设备受账号条件限制。Release 使用 HTTPS，本轮未修改 Release 的网络配置。安克设备另需有效 SDK 授权和硬件，阶段一不包含这些接入动作。

## 验证边界与剩余工作

遵循用户“不要测试软件，能打开就行”的要求，本轮只做源文件语法解析、后端启动及健康/能力信息读取，没有运行 pytest、UI 自动化、聊天或付费模型调用。实际启动成功：`/health` 返回 ok、`/docs` 返回 HTTP 200；读取能力信息显示现有安克 Agent 已配置，四个注册工具可发现，DashScope 两路模型配置已读取且管线仍未启用。离线 `backend/openapi.json` 已按运行服务刷新，结果见 [启动记录](AGENT_STAGE_ONE_STARTUP.json)。

代码实现、启动成功、测试团队验收与外部接口确认分别记录。阶段一的记忆契约已有草案，仍需双方确认；Monid 账号、Key 和预算尚未提供。不能将阶段一或整个 Agent 标为已全部验收。

下一项按计划进入阶段二：把原有身份语气提取为 `SOUL.md`、基础规则独立保存，建立 Skill 索引及按需加载，并在工具层执行 Skill 权限。涉及新的人格或业务行为选择，先向用户汇报确认。
