# 本机文本 Agent

文本 Agent 接入安克 OpenAI 协议网关。前端为 SwiftUI，首页参考飞书文档附件
`CanDid_温暖版产品原型_20261010.html`：奶油色背景、紫色形象与用户气泡、
对话主体、快捷意图与固定输入框。原型中的示例业务结果不作为真实数据。

## 启动

在项目根目录运行：

```sh
cd backend
.venv/bin/python run.py --env-file /Users/tyrone/code/forfun/anker/.env.anker.local
```

模型配置包含 `ANKER_AI_API_KEY`、`ANKER_AI_BASE_URL`，可选 `ANKER_AI_MODEL`。
默认模型为 `hackathon/v_model/deepseek-v4-pro`。密钥只进入后端进程，不进入 App。

另开终端，在项目根目录运行：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer sh scripts/check-ios.sh --build
python3 scripts/launch-chat.py
```

启动助手仅适用于 Debug 模拟器：从后端读取本机访问令牌，通过启动环境交给 App，
然后 App 使用真实 API 连接。App 会恢复已连接的后端与上次对话。
真机仍需在设置中填写后端地址和本机访问令牌。

可选 `python3 scripts/launch-chat.py --thread <会话ID> --message '消息'`，
从原生 App 发送一条真实消息，便于开发时演示。

## 已有能力

- 多轮文本对话、持久化会话历史、创建对话并关联场合。
- 模型按需调用 `search_memory`、`list_occasions`、`list_sessions`、`read_session`；查询仅限当前用户。
- 关键词检索已确认记忆和本人转写，区分确认信息、原文证据与 AI 推断。
- 排除示例录音，未找到资料时明确说明；来源可展开查看并打开对应场次。
- 等待状态、工具执行进度、失败重试；相同请求 ID 不会重复生成已完成的回答。
- 用户主动把回复保留为记忆草稿，沿用现有记忆库编辑与确认流程。
- 会话和消息随记忆导出，并纳入现有全部记忆删除范围。

## 接口

| 方法 | 路径 | 用途 |
|---|---|---|
| GET / POST | `/v1/chat/threads` | 会话列表 / 新会话 |
| GET | `/v1/chat/threads/{id}` | 消息历史及当前工具状态 |
| POST | `/v1/chat/threads/{id}/messages` | 发送或重试消息 |
| POST | `/v1/chat/messages/{id}/draft` | 用户主动保留回复草稿 |

发送消息需要 `content` 和 UUID `client_request_id`，重试复用同一个 ID。
Key 配置状态从 `/v1/capabilities` 的 `agent_configured` / `agent_model` 读取。
已有录音文本诊断使用独立 DeepSeek 适配器，本次没有改变其配置或 ASR 能力。

## 当前范围

文本回答整条返回，工具状态单独轮询；尚未做逐字流式显示、联网公司调研、
ASR、TTS 或语音打断。记忆检索是关键词方式，后续可替换为同事提供的检索 API。
Chat 记录不自动成为已确认长期记忆。
