# 香港 AIqua：修复后的真实调研复核

2026-10-16，实际通过已部署 CanDid HTTPS API、Monid 与现有文本模型完成。输入与之前的公司调研请求一致，未预先塞入公司事实；临时账号完成后删除，profile 返回 410。完整 Agent 原始输出保存在本机 `.build/reading-fix/cloud-aiqua.md`，本页为复核摘要。

## 公司信息

- **身份**：香港 Aiqua Corporation Limited（安快發展有限公司），官网 [aiqua.ai](https://www.aiqua.ai/)，可在 [香港科技园公司目录](https://www.hkstp.org/en/directory/information-communications-technology/aiqua-corporation-limited)交叉定位，区别于 Appier 的 AIQUA 营销产品。
- **产品**：官网展示 SwimNet 水下声纳 AI 溺水侦测，以及接驳现有摄像机的 SPB-300 池边安全产品，目标场景包括酒店、会所、住宅、学校及体育中心。准确率、合规和落地案例仍应按企业自述理解，不等于独立验证。[企业官网](https://www.aiqua.ai/)
- **业务人员**：官网列 Norman Chan 为联合创始人兼董事、Larry Ho 负责业务拓展。本次读到了真实团队正文，未再说“官网找不到团队”。职务仍属公司网站自述。[企业官网](https://www.aiqua.ai/)
- **时效**：近 90 天窗口明确为 **2026-07-18 至 2026-10-16**，本次未查到能核实发布日期的公司近期新闻。2024 年 WAIC、2025 年底实习资料放历史背景，不能说明最新规模；没有把未点名 AIqua 的政府试点当作其客户。[历史 WAIC 公告](https://www.hkstp.org/zh-hk/park-life/news-and-events/news/hkstp-leads-seven-pioneering-park-companies-to-showcase-innovative-ai-solutions-at-waic-2024)

## 人工复核补充：团队资料冲突

这一部分是本次人工读取学校官网后的补充，**不是 Agent 在上述原始报告里已完成的核实**。

公司网页把 Sun Yanni 标为 CUHK、Yan Zhenyu 标为 CityU；但本次读取的 [CityU Sun Yanni 官方人员页](https://www.cityu.edu.hk/stfprofile/yannisun.htm)将她列为城大教授，[CUHK Yan Zhenyu 官方人员页](https://www.ie.cuhk.edu.hk/faculty/yan-zhenyu/)将他列为中大助理教授。两者与公司网站的院校标注不一致。仅凭姓名也不能确认他们与公司的实际任职关系，不能直接把公司团队页抄成已确认的人事事实。

Agent 原始报告将这些信息标为官网自述、未独立核实，但仍重复了院校标注；因此应连同本段冲突提示阅读，不能把“七项流程验收通过”理解为所有商业信息都已经独立证实。

## 读取与验收证据

- 完整任务 **222.22 秒**；4 次搜索、2 次正文抓取、7 次长文读取。
- 官网入库 47,201 字符，实际返回正文范围合并后覆盖 **28,886 字符**，涵盖团队、产品、奖项等相关章节；没有声称已读完整网站。
- 七项检查通过：任务完成、团队正文确已读取、报告含 Norman/Larry、分段读取实际执行、近期章节未把旧日期当新动态、时间范围明确、临时账号清理。
- 原始失败迭代、日期/覆盖范围证据与四项既有云端流程结果见 [验收记录](READING_FRESHNESS_EVIDENCE.json) 和 [修复说明](READING_FRESHNESS_FIX.md)。
