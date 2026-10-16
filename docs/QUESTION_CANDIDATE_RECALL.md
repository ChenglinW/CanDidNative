# Qwen3.7 问题候选召回

实现位于 `backend/question_candidates.py`，可由 Python 业务代码或 `scripts/recall-question-candidates.py` 调用。独立召回组件已由 `backend/question_grouping.py` 接入 App V2 的录音复盘和记忆库问题自动分组流程；参见 [接入与页面报告](memory-redesign/REPORT.md)。

给定一个问题集合，使用 `qwen3.7-text-embedding` 批量生成向量，归一化后按余弦相似度返回 Top K 问句。默认 K=15，返回 `id`、原文和 `score`。可指定最低分数、排除当前问题、增量新增或更新、删除、保存和重新载入索引。分数表示相似度，不是“同一个问题”的概率。

同 ID、同文本的增量更新会复用已有向量；修改过的文本会重新编码。批次向量完整性和维度通过检查后才修改索引，服务失败不会留下半个批次。保存文件不含 API Key。

## 调用

依赖项目已有的 `dashscope`。服务读取环境变量 `DASHSCOPE_API_KEY`。每个用户、场景应使用独立索引；组件不包含身份认证和访问权限判断，调用方负责限定题库范围。当前采用本地逐条精确搜索，查询开销随题库规模线性增长；适用于当前小题库验证，尚未做大规模索引测试。

在 `backend` 可导入的 Python 环境中：

```python
from question_candidates import Qwen37Embedding, QuestionCandidateIndex

index = QuestionCandidateIndex(Qwen37Embedding())
index.upsert([
    {"id": "q1", "text": "工资待遇是多少？"},
    {"id": "q2", "text": "办公地点在哪儿？"},
])
candidates = index.search("请问薪资有多少？", top_k=15)
# [{"id": "q1", "text": "工资待遇是多少？", "score": ...}, ...]
```

命令行输入文件是 JSONL，每行包含 `id` 和 `text`。在项目根目录运行：

```sh
backend/.venv/bin/python scripts/recall-question-candidates.py \
  --index /private/tmp/questions-index.json build --questions /path/to/questions.jsonl

backend/.venv/bin/python scripts/recall-question-candidates.py \
  --index /private/tmp/questions-index.json search --query '请问薪资有多少？' --top-k 15
```

`build` 根据输入文件重新建库并替换索引。索引内包含问题原文和向量，应存放在调用者可控的位置。默认无最低分，因此陌生问题也会返回最接近的候选；业务需用二次判断或经自身数据校准的 `min_score` 决定是否属于同组。

## 本次验证

- 四项离线测试覆盖召回排序、排除自身、更新和删除、保存和载入、空匹配、非法向量、服务返回乱序及缺失向量。
- 真实 Qwen3.7 服务调用中，“请问薪资有多少？”将“工资待遇是多少？”排在首位，相似度 0.8543。
- 中文译文人工修订测试集 199 问中，有同组伙伴的 147 问，有 141 问在 Top 15 找到至少一个同组伙伴，命中率 **95.9%**。孤立问题不计入该指标，它也不表示所有召回候选都正确。
- 用此组件逐条查询 199 问，向量已就绪时两次测量平均每问约 **9.4–10.6 毫秒**；单次新问句向量计算加搜索约 **842 毫秒**。后者包含网络且仅测一次，不是稳定的 P95 服务指标。

完整中文聚类比较见 [测试报告](QUESTION_CLUSTERING_BENCHMARK.md)。模型接口依据 [Model Studio 同步向量接口](https://help.aliyun.com/en/model-studio/text-embedding-synchronous-api)。


后续接入了低相似度时的 Qwen3.8-Max 回退，经单变量对照未提升 F1，生产回到纯向量基线；见 [回退对照结论](memory-redesign/MERGE_CONTROL.md) 与 [回退策略记录](memory-redesign/QUESTION_FALLBACK.md)。
