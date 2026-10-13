# Monid 接入准备

日期：2026-10-13。本轮随阶段二准备渠道配置，实际公司调研在后续阶段接入。

用户提供的 Key 已保存在 `.env.monid.local`，文件权限为 0600，Git 忽略 `.env.*.local`。后端通过 `--env-file .env.monid.local` 读取，不把 Key 放进 App、模型提示或任务快照。

已阅读用户提供的 [官方接入教程](https://monid.ai/SKILL.md)，并核对其官方 npm 包 `@monid-ai/cli` 0.1.7 的 HTTP 客户端实现。教程介绍 CLI 的能力发现、参数规范读取、异步运行、查询和费用控制；Candid 后端可以按同一协议封装业务请求。教程中的全局 Skill 安装和工作流建议不是本项目的自动启用指令。

| 项目 | 已核对的协议 |
|---|---|
| API 地址 | `https://api.monid.ai` |
| 鉴权 | `Authorization: Bearer <本机私有 Key>` |
| 鉴权信息读取 | `GET /v1/auth/whoami` |
| 发现能力 | `POST /v1/discover`，query 与可选 limit 等 |
| 读取业务端点规范 | `POST /v1/inspect`，provider 与 endpoint |
| 提交调研任务 | `POST /v1/run`，provider、endpoint、input.body/queryParams/pathParams |
| 查询结果 | `GET /v1/runs/{id}` |
| 余额读取 | `GET /v1/wallet/balance` |

本轮仅调用只读鉴权接口，返回 HTTP 200；结果文件为 [MONID_SETUP_RESULT.json](MONID_SETUP_RESULT.json)，不保存账号身份、Key 或供应商原始响应。未提交 run，尚未选择或验证任何抓取业务端点。

后续调研采用发现能力 → 读取实际输入规范 → 在数量和费用限制内提交 → 查询状态 → 保存资料与来源的顺序。不同端点的结果限额可能按查询分别应用，必须核对具体规范。供应商任务进入终态后停止查询；是否可停止以接口返回的 stoppable 为准。[官方教程](https://monid.ai/SKILL.md)

实施业务接入前仍需向用户汇报确认：优先的公司资料/平台、实际供应商与端点、单次资料数量和费用上限。当前 MONID_BUDGET_YUAN 尚未设置，三个调研业务工具尚未注册，company_research 保持待接入状态。

本机启动时可以同时加载三个私有文件：

```sh
backend/.venv/bin/python backend/run.py \
  --env-file ../../.env.anker.local \
  --env-file .env.dashscope.local \
  --env-file .env.monid.local
```


## 2026-10-14 更新

用户已确认首三家供应商并授权平台增强选择。Search1API `/search`、Firecrawl `/scrape`、PDL `/v5/company/enrich` 已通过当前账号inspect并接入工具；Apify `/starvibe/youtube-video-transcript` 同样inspect并接入。配置快照在research/endpoints.json。只读目录查询不等于业务结果验证，本轮没有run。demo金额限额由用户明确取消，仍有单任务调用数与结果量保护。run ID、billing、24小时缓存、未知提交阻止重发及资料引用已实现。详细状态见AGENT_DELIVERY.md。
