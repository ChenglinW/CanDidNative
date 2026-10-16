# 百炼文本模型接入

2026-10-17：使用已有北京区 DashScope Key，通过百炼 OpenAI 兼容接口直连 `qwen3.8-max`，设置 `enable_thinking=false`。推荐优先用于现有 Agent 工具调用、语义理解和结构化提取；本轮未作跨模型质量基准，不宣称优于之前的 DeepSeek。

Key 的 `/models` 返回 Qwen3.8-Max、Qwen3.8-Flash、Qwen3.7-Plus、DeepSeek 等；模型列表可见不代表全部逐一验证。前三个分别实调成功，本轮默认选择 Max。官方目录：https://help.aliyun.com/zh/model-studio/getting-started/models 。完整模型列表和原始实测仅保存在本机 `.build/bailian-text/`，不包含 Key。

只改 provider 选择、请求参数适配、配置加载和真实供应商来源标识。保留原有流式/非流式接收方式，不新增供应商自动回退。`CANDID_TEXT_PROVIDER=dashscope` 时复用服务端 `DASHSCOPE_API_KEY`，模型与地址由 `DASHSCOPE_TEXT_MODEL` / `DASHSCOPE_TEXT_BASE_URL` 指定。未配置 provider 的旧安装仍沿用 Anker；当前私有配置和团队加密配置包已显式切换百炼。

后续复盘、FAQ、记忆、前置增强的实现和 prompt 文件均与修改前逐字节一致。现有 FAQ 语义分组仍使用百炼 embedding；未启用的 Anker 实验性问题归类脚本未改。

验证：70 项相关回归通过，含 provider 请求适配、流式、工具 schema、原 prompt 校验及现有 Agent 流程回归。真实接口流式回复 0.86 秒，工具调用 1.13 秒。之前同一段录音的隔离副本，实际语义增强 12.56 秒、复盘 16.78 秒、FAQ 23.40 秒并保存 7 条，来源通过既有校验；原始转写不变、个人记忆写入为 0。此次未修改、安装 iOS 客户端，也未修改正式录音或批量重跑旧任务。单次成功不能证明所有长录音都不会超时。
