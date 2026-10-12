# AISHELL-4 与 Qwen ASR 测试

更新时间：2026-10-12。当前提供不依赖 soundcore 的后端评测工具，使用本地音频模拟已有语音输入。ASR 模型固定为 `qwen-audio-3.0-asr-flash`，不是 `qwen3-asr-flash`，也不是异步 filetrans 模型。已完成真实调用：14 段可评分语音 CER 为 4.46%，5 段间隙返回未识别到文字；复盘质量部分通过，详见 [首轮实测报告](AISHELL实测报告.md)。

## 已准备的数据和代码

- 从发布方 AISHELL 的 Hugging Face 镜像下载测试集会议 `S_R004S03C01`，固定版本 `aada72727856313b19d4a030383c426364931dbf`。原始 FLAC 为 235,113,956 字节，下载后核对 LFS SHA256；TextGrid 和 RTTM 核对 Git blob 校验值。
- 原数据保存在 `.build/aishell4/source/`，来源记录为 `S_R004S03C01-source.json`。该目录被 Git 忽略，不混入用户记忆或 App 资源。
- 已生成 20 个单声道 16 kHz PCM16 WAV 片段，共约 182.87 秒、5.85 MB。清单：`.build/aishell4/suite/manifest.json`。
- 本轮覆盖：数字 4、含保留意见的表达 5、普通单人发言 5、重叠发言 1、无标注语音间隙 5。类别由时间标注和关键词规则选择，须人工复核语义；“无标注语音”不保证声学上绝对静音。
- `backend/asr.py`：Qwen 原生同步 HTTP 请求，Base64 音频上传、输入验证、错误脱敏；结果默认 `speaker=unknown`。
- `backend/aishell_eval.py`：TextGrid 解析、按标注截取、声道选择、CER、隔离数据库中的 DeepSeek 复盘。
- `backend/evaluation/scenarios.json`：前述面试、客户沟通、路演、学术报告、纠正与归属不明共 5 个脚本化文本案例。它们不是 AISHELL 音频，不伪装成数据集中存在的业务对话。

## 填写密钥

本机已创建 `backend/data/asr-config.json`，权限 `0600`，内容结构与 `backend/asr-config.example.json` 相同。填入 `api_key` 即可；不要填到 iOS 设置或 DeepSeek 配置中。

```json
{
  "model": "qwen-audio-3.0-asr-flash",
  "api_key": "",
  "region": "cn-beijing",
  "workspace_id": ""
}
```

默认北京地域。新加坡密钥应将 `region` 改为 `ap-southeast-1`。`workspace_id` 有值时使用业务空间专属域名；为空时使用官方仍支持的 `dashscope.aliyuncs.com` 或 `dashscope-intl.aliyuncs.com`。接口路径固定为 `/api/v1/services/aigc/multimodal-generation/generation`。

环境变量优先：`QWEN_ASR_API_KEY`（其次 `DASHSCOPE_API_KEY`）、`QWEN_ASR_REGION`、`QWEN_ASR_WORKSPACE_ID`、`QWEN_ASR_MODEL`。ASR 不会使用 DeepSeek Key。评测命令每次重新读取配置，填好后直接运行即可；无需启动或重启 FastAPI。

## 本机运行

在项目根目录运行，使用已有 Python 3.12 虚拟环境：

```sh
backend/.venv/bin/python -m pip install --only-binary=:all: -r backend/requirements-eval.txt

# 首次获取数据；已有且校验通过的文件会跳过
backend/.venv/bin/python scripts/download-aishell4.py

# 首次准备片段；输出目录必须不存在，以保留旧测试结果
backend/.venv/bin/python scripts/evaluate-aishell4.py prepare

# 不调用模型，只校验清单、音频、校验和以及配置状态
backend/.venv/bin/python scripts/evaluate-aishell4.py run \
  --output .build/aishell4/my-dry-run.json

# 填写 Key 后，实际调用 Qwen，产生 ASR 用量
backend/.venv/bin/python scripts/evaluate-aishell4.py run --live-asr \
  --output .build/aishell4/asr-live-01.json

# 在 ASR 后继续调用已配置的 DeepSeek，生成带原文引用的诊断和待确认素材
backend/.venv/bin/python scripts/evaluate-aishell4.py run --live-asr --with-review \
  --output .build/aishell4/asr-review-live-01.json

# 单独对 5 个业务文本案例调用 DeepSeek，不包含 ASR
backend/.venv/bin/python scripts/evaluate-aishell4.py scenarios --live-review \
  --output .build/aishell4/scenarios-live-01.json

# 回归测试默认全部离线，HTTP 由模拟响应替代
CANDID_DATA_DIR=/tmp/candid-asr-tests backend/.venv/bin/python -m pytest backend/tests -q
```

本机已完成数据准备，不需要重复 prepare。想重新选片可增加 `--output .build/aishell4/suite-v2`；运行该套片段时使用 `run --manifest .build/aishell4/suite-v2/manifest.json`。输出报告文件同样不覆盖，重复评测请更换文件名。

不带 `--live-asr` / `--live-review` 时不会调用任何外部模型。没有密钥时实际调用命令明确报错退出。评测没有自动重试，以免隐藏失败或产生额外计费；可以检查错误后另存一次报告重新运行。

## 如何读结果

`run` 的 JSON 报告包含每段标准文本、识别文本、源录音时间范围、音频路径、耗时、错误码和 CER；`--with-review` 还保存诊断、逐字引文和待确认素材。临时 SQLite 在测试后删除，报告仅保存在指定位置，不读取正式后端记忆。

- `prepared_not_run` 和 `micro_cer_successful_clips: null` 表示尚未识别；不能解释为 0% 错误率。
- CER 使用 Unicode NFKC、小写转换、去除标点和空白后的字符编辑距离。总分按总错误数／总参考字符数计算，不对片段 CER 简单平均；汉字数字与阿拉伯数字不自动互换。金额、自我纠正等还应结合原文人工检查。
- 总分只统计成功识别、参考文本非空且无重叠的片段。必须同时查看 `failed`、`scored_expected`、`scored_actual` 和 `complete_asr_evaluation`；不能把失败片段遗漏后的分数当作完整结果。
- `ASR_NO_WORDS` 表示服务端未识别到文字，仍作为失败保留，不能据此认定为静音或计为正确转写。
- 无标注语音间隙在返回转写时报告输出字符数；参考为空时 CER 为 null。重叠片段仅用于人工检查，不计算普通 CER，也不送进本人复盘。
- 当前模型不做说话人分离。单人片段的“本人”归属和边界来自数据集标注，是已知答案辅助的测试条件；八个声道是麦克风，不是八位说话人。测试报告不会给出说话人识别准确率。
- 不把参考文本、说话人标签、标准答案、热词或业务验收要求发给 ASR。复盘只接收本次 ASR 结果；标准文本留在报告中供人工检查错误传播。
- 自动验证能证明 JSON、引文和草稿存储符合约束；“建议是否合理、有没有漏掉承诺冲突、金额是否理解正确”需按 5 个案例中的 `human_checks` 人工评估，不能仅凭有输出宣称通过。

这 20 段是单场会议中的工程回归子集，按人工标注切段，不能作为完整 AISHELL-4 基准成绩，也不能代表 soundcore 的实际录音效果。

## 当前范围与来源

已实现 ASR 评测适配及 ASR → DeepSeek → 草稿的测试链路。本轮没有改动 soundcore，也没有将正式 App 的音频上传任务自动切换为云端转写；App 原有音频转写未启用提示仍准确。后续可在确认实际识别效果后增加正式音频导入、用户选择转写及说话人归属确认页面。

官方依据：[Qwen 同步 HTTP API](https://help.aliyun.com/zh/model-studio/fun-asr-flash-recorded-speech-recognition-http-api)、[音频与模型限制](https://help.aliyun.com/zh/model-studio/asr-model)、[OpenSLR 数据说明](https://www.openslr.org/111/)、[AISHELL 发布方镜像](https://huggingface.co/datasets/AISHELL/AISHELL-4)。

许可元数据存在差异：OpenSLR 标为 CC BY-SA 4.0，Hugging Face 页面标为 Apache-2.0。本轮仅在本地评测并保留来源，不向代码仓库分发音频或标注；对外分发前应核对所用数据的实际许可文件。
