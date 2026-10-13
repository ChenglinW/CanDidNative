# Candid 两路 ASR 模型选型

日期：2026 年 10 月 13 日。状态：用户已决定获取阿里云接口并提供 Key 授权保存与最小调用。用户已确认通过 DashScope 使用两路 Qwen 3.1，后续优先官方 SDK；两路均已用公开示例音频调用成功；App 与业务流程尚未接入，未进行质量评测或软件测试。

## 本机接入确认

API Key 保存在仓库根目录的 `.env.dashscope.local`，权限为 `0600`，通过本仓库的 `.git/info/exclude` 忽略，不进入代码或本说明。

| 模型 | 调用方式 | 实际结果 |
|---|---|---|
| `qwen-audio-3.1-asr-flash-streaming` | 北京地域旧兼容域名 WebSocket，发送公开示例的 PCM 音频 | 握手 101，收到中间文字及最终结果，任务成功；最终文字为“欢迎使用阿里云。” |
| `qwen-audio-3.1-asr-flash-filetrans` | 北京地域旧兼容域名提交 HTTP 异步任务并查询结果，启用分人和保留方言 | 提交与查询 HTTP 200，任务成功；得到相同文字、句词时间戳和匿名 `speaker_id=0` |

示例约 1.7 秒、单人普通话，证明当前 Key 的两模型访问和基础协议可用，不证明多人分人质量、中英粤混说、长录音、后台恢复或 App 集成已完成。结果记录在 [调用结果](ASR_CONNECTION_RESULT.json)，不含 Key 或签名下载 URL。使用兼容域名完成调用，尚未配置 Workspace 专属域名。

## 已确认需求

- 多人沟通录音复盘和手机语音 Agent 都需要支持。
- 录音时实时显示文字，无需立即分说话人；结束后从原始音频独立异步处理，优先准确性，最终结果必须分人。
- 最终结果需要逐句时间戳、区分说话人、普通话/英语/粤语混合输入。
- 录音长度不固定，需要长录音处理，不将单次模型限制直接变成产品录音时长上限。
- 保留粤语原话，复盘可以使用普通话。
- 可评估安克之外的模型，包括额外接入 OpenRouter；先比较差异与接入成本，再由用户确认具体组合。保留实时与录后两路分工。

## 安克 SOP 当前开放范围

[黑客松大模型使用文档](https://anker-in.feishu.cn/docx/HAtJdgo45otz2Px31bYcu3PDnRf)目前只列出一个 ASR：`hackathon/v_model/qwen-audio-3.0-asr-flash`，并明确当前只支持 HTTP 调用。示例通过 `/openai_passthrough/services/aigc/multimodal-generation/generation` 传入完整音频；返回示例包含句子及词时间戳，但 `speaker_id` 为 null。

文档另列 TTS `hackathon/v_model/qwen-audio-3.0-tts-flash`，其余模型用于文本或多模态理解。SOP 未列 streaming、filetrans 型号或对应实时 WebSocket、异步任务提交/查询入口。因此它不能证明现有 Key 可完成两路 ASR。

## 安克当前型号的能力缺口

| 要求 | 当前 SOP 依据 | 计划处理 |
|---|---|---|
| 真正实时流式输入 | 只列出 3.0 Flash 的完整音频 HTTP 调用 | 缺口未解决；不擅自改成短音频 HTTP 轮询 |
| 两个不同 ASR 模型 | 当前只有一个 ASR 型号 | 无法在已列范围内选出两个；不把同模型调用两次称为两模型 |
| 录后异步处理 | 可以由 Candid 后端任务编排 HTTP 调用；SOP 没有原生 Filetrans 入口 | 可设计任务接口，但模型选择与准确性仍需确认，不能承诺重跑就更准 |
| 最终说话人分离 | 官方注明 3.0 Flash 不支持，SOP 示例 `speaker_id=null` | 仍需分人方案；不让文本模型根据对话内容猜身份 |
| 逐句时间戳 | SOP 返回示例包含句级和词级时间戳 | 接入时核对真实结构并加上分段的全场偏移；当前评估适配器只保留整段文字，须调整 |
| 中英粤语混说与粤语原话 | 官方列出英语、普通话、粤语支持，不证明三语混说质量或原话输出方式 | 保留要求，核对允许型号的方言输出能力，交测试团队验收 |
| 不固定录音长度 | 当前型号单次输入限制为 5 分钟 | 产品保留长录音，通过分段处理解决单次限制，仍需解决跨段分人 |

以上说明当前安克型号无法单独满足需求。用户现已允许扩展选型，下面比较 OpenRouter 与原生服务；不据渠道或版本号声称识别质量已得到提升。[安克 SOP](https://anker-in.feishu.cn/docx/HAtJdgo45otz2Px31bYcu3PDnRf)、[官方模型能力](https://help.aliyun.com/zh/model-studio/asr-model/)

## OpenRouter 的适用范围

OpenRouter 已提供 `/api/v1/audio/transcriptions`，支持转写、结构化时间戳与供应商特定分人参数。当前公开模型目录含 Scribe v2、MAI-Transcribe 2、Qwen3 ASR 等。该接口上传文件并返回结果，尚未从公开文档确认持续音频输入的实时 WebSocket 入口；模型具备 streaming 推理能力不等于路由渠道提供对应协议。[STT 文档](https://openrouter.ai/docs/guides/overview/multimodal/stt)

| 候选 | 可补足的能力 | 当前判断 |
|---|---|---|
| OpenRouter `elevenlabs/scribe-v2` | 普通话、英语、粤语；词级时间戳和可选分人 | 可作为录后候选，需核对转发参数与长录音限制 |
| OpenRouter `microsoft/mai-transcribe-2` | 粤语、混语切换、逐词时间戳、分人、原话输出模式 | 可作为录后对照候选；原生服务为预览，长音频分人约束需核对 |
| 原生 `qwen-audio-3.1-asr-flash-streaming` + `qwen-audio-3.1-asr-flash-filetrans` | 真正流式输入、录后分人和时间戳；Filetrans 可设置保留方言表达 | 优先评估完整两路方案，不默认推定安克已开放，也不宣称准确率已胜过其他模型 |

Scribe 支持的语言包含 Cantonese、Mandarin Chinese 和 English；分人及时间戳来自语音模型，不由文本模型猜测。MAI-Transcribe 2 的语言表含 `yue` 和 `zh`，并提供 code switching 与 verbatim 输出。单语支持或一般混语能力不能证明中英粤三语实际混说准确率；这部分交测试团队用目标录音比较。[ElevenLabs 能力](https://elevenlabs.io/docs/overview/capabilities/speech-to-text)、[Microsoft 能力](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/mai-transcribe)、[阿里云能力](https://help.aliyun.com/zh/model-studio/asr-model/)

OpenRouter 的 multipart 上传上限为 25 MB，并说明供应商请求有 60 秒处理超时。其文档也提供部分供应商的大文件 JSON 或 URL 输入例外，但不能据此推定任意长录音都能成功。分段后需合并全场时间与说话人标签；原生服务的最大文件时长不直接等于 OpenRouter 的接入上限。[接口限制](https://openrouter.ai/docs/guides/overview/multimodal/stt)

## 费用参考

2026 年 10 月 13 日，OpenRouter 公开模型页面与端点目录显示 Scribe v2 模型费约 0.11 美元/音频小时，为截至 10 月 19 日的五折活动价，按原价约 0.22 美元/小时；MAI-Transcribe 2 为 0.10 美元/小时。费用不包含未核对的平台充值费用、额外功能与重试；实现时重新确认。[Scribe 价格](https://openrouter.ai/elevenlabs/scribe-v2)、[MAI 价格](https://openrouter.ai/microsoft/mai-transcribe-2)

安克活动网关额度独立核对；原生 Qwen 3.1 两路按输入、输出 Token 计费，不能用未经证实的换算给出每小时价格。分段重叠、重复处理与费用上限在选型后汇报。[阿里云计价](https://help.aliyun.com/zh/model-studio/model-pricing)

## 已确认选择及剩余事项

1. 两路均采用阿里云百炼 DashScope：实时 `qwen-audio-3.1-asr-flash-streaming`，录后 `qwen-audio-3.1-asr-flash-filetrans`。后续支持的模型通过该渠道接入，具体新型号仍先向用户确认。
2. 官方 Python SDK 1.27.7 已用同一 17.6 秒样例复测成功：首字 2.21 秒，停止发送后完成 11.39 秒。延迟原因未确定，用户已决定暂不继续排查；记录见 [SDK 结果](ASR_STREAMING_SDK_RESULT.json)。
3. 目标录音的混说准确率、长音频稳定性与跨段分人一致性由测试团队验证；本轮未进行质量评测。
4. App ASR 管线、长录音处理与费用上限在接入阶段核对。阶段一已支持读取独立 DashScope 配置，但尚未调用该服务处理 App 音频。

实时字幕与最终转写分别保存，最终版本供复盘引用；实时的句子确认状态不等于用户确认或最终证据版本。设备实时音频取流还需核对 SDK 能力，当前 App 音频片段回调尚未接入，不能因存在回调就宣称设备实时字幕已实现。
