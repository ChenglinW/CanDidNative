# 单变量对照：大模型回退是否提升合组 F1

2026-10-16。结论：**没有提升，生产保留纯向量基线。**

## 背景

之前的回退策略把三件事同时改了：把候选边平均合组改成逐条分配、把自动门槛从 0.6646 提到 0.85、低于门槛时交给 Qwen3.8-Max。因此无法单独说明大模型的作用，小样本上也出现了漏合并增加（见 [HYBRID_ERROR_ANALYSIS.md](HYBRID_ERROR_ANALYSIS.md)）。

本实验按建议的下一步执行：**保留原候选边平均合组算法，只替换阈值附近不确定的合并判定**，让 Qwen3.8-Max 复核两个完整问题组（返回是否整体合并），做单变量对照。

## 方法

- 算法：`question_merge.candidate_average_groups`。`width=0` 时与原 `average_groups` 完全一致；`width>0` 时，只有组间平均相似度落在 `0.6646 ± width` 区间内的候选合并，才由 `qwen3.8-max` 判断是否合并，其余按阈值直接决定。
- 数据：中文译文集，复用缓存的 `qwen3.7-text-embedding` 向量（不含 embedding API 耗时）。按组（含重复译文）切出 calibration / validation / extra 三个不重叠集合。
- 选择规则（预先声明）：在 calibration 上选 pair F1 最高者（并列时偏好更少模型调用、更窄区间）；仅在 validation 上满足「F1 ≥ 基线 且 Recall ≥ 基线 − 0.02」才接受；接受后冻结，再跑 extra。参数不使用 test 标签调参。
- 实现与结果：`scripts/benchmark-question-merge.py`、[merge-control-results.json](merge-control-results.json)（含预注册计划与逐样本划分）。

## 结果

| 集合 | width | pair P | pair R | pair F1 | 新 LLM 调用 |
|---|---|---:|---:|---:|---:|
| calibration | 0（基线） | 81.6% | 96.3% | **88.3%** | 0 |
| calibration | 0.04 | 85.5% | 84.3% | 84.9% | 45 |
| calibration | 0.08 | 85.1% | 50.3% | 63.2% | 86 |
| validation | 0（基线） | 72.7% | 100% | 84.2% | 0 |
| extra | 0（基线） | 60.6% | 95.4% | 74.1% | 0 |

selection：`calibration_best_width = 0`，validation 门通过（因为最优就是基线本身），`frozen_width = 0`。

## 解读

- 越宽的复核区间，越多的合并交给大模型，precision 略升但 recall 明显下降，pair F1 单调下降（88.3% → 84.9% → 63.2%）。大模型在当前提示词下偏保守，把阈值附近本该合并的组拆开了。
- 这与此前 [HYBRID_ERROR_ANALYSIS.md](HYBRID_ERROR_ANALYSIS.md) 的判断一致：**漏合并主要来自更严的判定标准，而不是 Top 15 没召回。**
- 因此没有证据支持在默认路径启用 Qwen3.8-Max 回退。它增加每次约 1 秒的请求耗时和成本，却不提升 F1。

## 落地决定

- 生产归类回到纯向量基线：`qwen3.7-text-embedding` → Top 15 候选边 → 组间平均相似度 ≥ 0.6646 合并（`backend/question_grouping.py` 的 `average_groups`）。
- `question_fallback.py`（逐条回退）与 `question_merge.py`（组复核）保留为实验模块，不接入默认路由。`CANDID_QUESTION_AUTO_THRESHOLD` 环境变量及 `question_judgments` 缓存在默认路径中不再使用。

## 边界与后续

- 结果来自机器翻译的通用问句，标签偏向宽意图；不能据此断言销售实录的绝对 F1。生产准确率仍需真实销售标注（见 [SALES_QUESTION_LABELING.md](SALES_QUESTION_LABELING.md)）。
- 若要在真实销售数据上重试大模型回退，应先按“同一个问题”标注，再在训练/验证集上校准，独立评估 test；不要在本次 test 子集上反复挑阈值。
