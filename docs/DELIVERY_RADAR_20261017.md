# 表达习惯五维参考评分雷达图

入口：记忆库 → 我 → 表达。顶部展示 **参考评分** 五维雷达（语速 / 停顿 / 口头禅 / 起伏 / 时长控制）。说话占比保留为原始指标，不参与评分轴。

规则说明见 [EXPRESSION_SCORING_RULES_v1.md](./EXPRESSION_SCORING_RULES_v1.md)。后端集中评分（`expression_scoring.py`），客户端展示；半径 = `score / 4`。未评分不画成 0 分。

同场景近三场 / 满六场起点对比：先逐场评分，再取中位数汇总。声学策略 `claimed-acoustics@2` 按需重算。

旧客户端忽略未知 `expression_scores` 字段仍可运行。本轮不自动部署生产、不覆盖实体机 App。
