> 2026-10-15 录音入口更新：所有版本（含 Release）保留「手机录音（备用）」；录音豆继续作为主入口。云端已允许手机与录音豆两种来源。

> 2026-10-16 云端接入：App 默认固定连接新加坡 `https://47.129.137.212`，自动申请并保存设备独立凭证。设置中无需填写后端地址或令牌。旧地址的设备身份与待上传录音可迁移；见 [云端接入说明](docs/CLOUD_CONNECTION.md)。

> 2026-10-15：完整 onboarding 已接入原生 App，支持可跳过的用途选择、个人介绍、语音转文字和资料导入；后续在记忆库编辑。见 [onboarding 交付说明](docs/ONBOARDING_DELIVERY.md)。

> 2026-10-15 首轮场景改造：销售 BD 与面试采用「我 → 场景 → 项目 → 业务场次」；首页、项目、录音、记忆库统一导航。会前准备、录后结构化资料、客户跟进、内部纪要、项目追踪、本地提醒和 PDF / Word / 图片 / 文字导出已接入。跨场新个人结论集中确认。先看 [首轮交付记录](docs/PRODUCT_REFACTOR_DELIVERY.md)、[已确认计划](docs/PRODUCT_REFACTOR_PLAN.md)与 [队友接入](docs/TEAM_SETUP.md)。飞书下一阶段，真机安装保持暂停。

> 2026-10-14 Agent demo 更新：项目空间、资料/调研、录音/ASR、标签、归档学习与TTS已接入代码；本轮只构建和启动，功能与设备待测开验收。先看[交付说明](docs/AGENT_DELIVERY.md)、[队友接入](docs/TEAM_SETUP.md)及[迁移准备](docs/MIGRATION.md)。团队服务密钥通过加密配置包导入，不需要写进App。

# CanDid 原生 iOS 动态记忆库原型

这是 SwiftUI 原生 iOS 客户端与 FastAPI 后端工程，不是 HTML 或 WebView 包装。产品结构以最新场景流程草图及已确认改造计划为准，沿用此前温暖版视觉。

**当前开发环境为 macOS、Xcode 27.0 与 iOS 27.0 模拟器。** soundcore SDK 已完成原生链接构建，并执行音频转换与页面测试；后端已接入 `deepseek-v4-pro`，本人文字复盘可生成带证据的诊断与待确认素材。详细结果与尚未执行的项目见 [验证记录](验证记录.md)。

录音入口已改为 **soundcore 设备**，使用资料包的 iOS v1.3.01 SDK。设备通过按键开始／结束录音，App 预留授权、扫描、连接、暂停／恢复与文件同步接口；设备文件通过 libopus 解码后转换为可播放、可上传的 m4a。当前没有硬件或有效 token，实际鉴权和蓝牙录音链路尚未验证，模拟器不会冒充设备。环境配置与接口约束见 [macOS 开发说明](macOS开发.md)。

## 1 打开原生 iOS App

需要 Mac、Xcode 26 或更新版本（资料包 SDK 使用 Xcode 26 构建），iOS 17 或更新的模拟器／iPhone。本机使用 Xcode 26.6。

1. 在 Mac 安装并首次打开完整 Xcode，完成组件安装，在 Settings → Components 中安装 iOS 模拟器运行时；随后双击 `ios/CanDid.xcodeproj`。
2. 在项目根目录运行 `sh scripts/prepare-soundcore.sh` 和 `sh scripts/build-opus.sh` 准备本地依赖，再选择 **CanDid** scheme 与一个 iPhone 模拟器，点击 Run（⌘R）。无需后端即可进入明确标识的离线示例。
3. 真机：连接 iPhone，在 Xcode 的 Signing & Capabilities 选择你自己的 Team，并将 Bundle Identifier 改成自己的唯一名称。
4. 选择已连接的 iPhone，启用设备 Developer Mode 后点击 Run。soundcore 连接需要蓝牙权限与有效 SDK 授权；App 不再调用 iPhone 麦克风录音。

在项目根目录执行构建检查（Mac）：

```sh
sh scripts/check-ios.sh --build
# 构建、启动可用 iPhone 模拟器、安装并打开 App
sh scripts/check-ios.sh --run
# 也可指定模拟器 UDID
sh scripts/check-ios.sh --run <模拟器UDID>
# 运行音频处理与页面自动化测试
sh scripts/check-ios.sh --test
```

脚本优先使用 `DEVELOPER_DIR`／系统选择的 Xcode；若系统仅选中命令行工具，会尝试 `/Applications/Xcode.app`，不修改系统配置。构建产物位于 `.build/DerivedData`；测试记录位于 `.build/TestResults`。`--run` 完成安装和启动检查，`--test` 执行 XCTest/XCUITest。设备录音仍需真机验收。当前未生成 IPA，也未提交 TestFlight。

## 2 启动持久化后端

使用 Python 3.12 或更新版本：

```sh
cd backend
python3.12 -m venv .venv
source .venv/bin/activate
python -m pip install --only-binary=:all: -r requirements.txt
python run.py
```

默认监听 `127.0.0.1:8000`。首次运行生成 `backend/data/local-access.txt`；把其中令牌填入 App 右上角设置。不要把该文件加入仓库或发给其他人。令牌保存在 App Keychain。

在 App 设置中：

- 模拟器：后端地址 `http://127.0.0.1:8000`。
- iPhone 真机：电脑运行 `python run.py --lan`，手机与电脑处于同一可信局域网，填写 `http://电脑局域网IP:8000`。按需允许防火墙访问该端口。
- 勾选保存许可，输入令牌后点“连接并读取真实后端数据”。服务模式不会在断线时悄悄回退到示例。

本机令牌仅用于原型，不是生产登录。Debug 构建允许 HTTP 以连接本机服务；Release 不开放 ATS HTTP，客户端也要求 HTTPS。后端不对外网部署。

接口说明在 `http://127.0.0.1:8000/docs`。提供的 `backend/openapi.json` 是离线接口契约。

## DeepSeek 模型配置

当前模型为 `deepseek-v4-pro`，官方接口 `https://api.deepseek.com/chat/completions`。实现位于 `backend/llm.py`，系统提示词为 `PROMPT`。参考 [DeepSeek 官方接口](https://api-docs.deepseek.com/api/create-chat-completion/)。

本机已保存私有配置 `backend/data/llm-config.json`，文件权限为 `0600`，`backend/data/` 已被 Git 忽略。更改 `model` 或 `api_key` 后重启后端。新环境可复制 `backend/llm-config.example.json` 到该路径，再填写自己的密钥；也可设置 `DEEPSEEK_MODEL` 和 `DEEPSEEK_API_KEY` 环境变量，它们优先于文件。指定 `CANDID_DATA_DIR` 时从该目录读取 `llm-config.json`。

App 设置中的令牌是 `backend/data/local-access.txt` 内的**本机访问令牌**，不要在 App 中填写 DeepSeek Key。连接后，设置 → 文本分析模型显示后端模型与配置状态。Key 不返回客户端、不进入导出记忆或日志。

调用链：本人原文 → 明确选择 DeepSeek 分析 → 后台任务 → 结构化诊断和逐字引文校验 → 待确认素材。API `POST /v1/sessions/{id}/transcript` 的 `analyze` 默认为 `false`；设为 `true` 表示同意分析。已保存的原文可通过 `POST /v1/sessions/{id}/analyze` 显式选择分析。重复提交不会重复入队；`/retry` 用于明确重新执行。

仅发送该场次 `speaker=self` 的文本和场景，不发送音频、对方原话或历史记忆。单次上限 20,000 字、100 段，输出上限 4,096 tokens；使用非思考模式。模型生成的诊断须引用实际原文；素材为原文摘录，仍需用户确认。手工输入的时间范围是证据定位占位，不用于估算语速。暂不将真实诊断加入示例短板与基线聚合。

鉴权失败、余额不足、引用不匹配会显示具体错误；超时、限流或暂时不可用最多自动尝试三次。模型调用期间不占用数据库锁，删除记忆或重新提交会使旧任务结果失效。本地 SQLite 仅支持一个后端进程；重启会恢复未完成任务，极端中断可能造成供应商重复计费。

显式运行真实模型验证（使用合成文本，会产生少量 API 用量，不写入实际记忆）：

```sh
backend/.venv/bin/python scripts/check-deepseek.py --live
```

## AISHELL-4 / Qwen ASR 评测

已新增 `qwen-audio-3.0-asr-flash` 评测适配器，并准备 20 个真实 AISHELL-4 音频片段和 5 个独立业务文本案例。密钥留在本机 `backend/data/asr-config.json`，已完成真实调用；14 段可评分语音 CER 为 4.46%，5 段无标注间隙返回未识别到文字。复盘质量部分通过，详见 [首轮实测报告](AISHELL实测报告.md)。工具支持音频校验、转写 CER、错误报告，以及将单人片段识别结果送入现有 DeepSeek 复盘流程。数据和测试结果与正式用户记忆隔离。

运行命令、模型地域配置及结果解释见 [AISHELL 测试说明](AISHELL测试.md)。本轮只接入评测工具，正式 App 音频自动转写仍未启用。

## 3 推荐演示闭环

1. 欢迎页阅读保存与保留说明，同意后进入 App。
2. 离线示例：场次 → 预处理示例 → 原文与复盘；记忆库 → 待确认 → 修改表达 → 确认。
3. 到场合中打开准备上下文，确认后的素材才会标为 FACT。草稿不会被混作已确认事实。
4. 连接后端：新建四种场景中的任一场合 → 运行预处理示例闭环 → 场次列表下拉刷新 → 查看示例诊断及素材草稿 → 确认 → 再查看准备上下文。
5. soundcore 真机待验收流程：场合 → 练习或记录 → 本人练习／已告知的真实沟通 → 连接与授权 → 在设备上按键录音并结束 → 刷新设备录音 → 选择文件 → 同步并保存。服务模式上传校验成功后删除本机 m4a 副本；后端保留回放副本。设备中的原始文件不会自动删除。
6. 选择口述复盘，输入本人文字复述。连接后端后可勾选“同意将本次本人复述发送给 DeepSeek 分析”，点击“保存并分析本人复述”，到场次详情查看自动刷新的诊断与待确认素材；不勾选则只保存原文。
7. 场次详情播放音频；设置调整保留期、导出 JSON；单场次删除 App 音频后保留本人转写及既有诊断。soundcore 设备原文件的删除由设备另行管理。

**DeepSeek 文本诊断已接入；真实录音目前没有自动转写。** 只有音频时返回 `ASR_NOT_CONFIGURED`；提交本人文字并选择分析后才调用模型。示例管线的 producer 为 `fixture@1`，不会把示例结果套到真实音频上。本人练习是真实录音流程，不是已接入的模拟听众语音 Agent。

## 4 已实现的记忆后端

- 21 张命名业务表、三层归属、owner 隔离、private 可见性。
- SQLite 持久化、数据库 L1 更新拒绝、L2 版本/生产者约束、L3 当前用户守卫。
- 素材用户确认／编辑／归档、乐观锁、旧内容版本记录、11 条以上写入。
- 场合和场次幂等创建、听众选择、结果回填、手动本人原文、时间标记。
- 录音告知守卫、流式分块上传及 offset 校验、SHA256 回调、私有音频及五分钟签名链接。
- 五种用途的上下文，FACT/INFERRED 区分、评分版本过滤、排除对方原话、预算截断；预算使用字符数估计，未接入模型 tokenizer。
- 预处理示例分阶段任务、阶段重试、原文不重写、无覆盖用户确认素材、短板状态机、同标准示例聚合。
- 音频到期清理、缩短保留期影响旧场次、延长只影响新场次、删除音频不删本人证据、导出与整库删除。

SQLite 是**本地原型存储**，不是生产 Supabase。`backend/supabase/schema_2_0_reference.sql` 提供 21 张有类型的 Postgres 业务表、用户 RLS、L1/L2/L3 守卫、证据校验、私有 Storage 策略与 `SKIP LOCKED` 队列领取函数。它是独立新 schema 的参考脚本，不是对未知现有 1.2.0 数据库自动升级；未在 Supabase 执行。本机 API 当前不会切换到这份 SQL，生产需要另写 Postgres/Storage 适配层。

可选 `CANDID_AUTH_MODE=supabase` + `SUPABASE_URL` 验证 ES256/RS256 Supabase 用户 JWT。JWT 鉴权不等于数据库已迁移；应用仍使用本地 SQLite。service role 不进入 App，不能触发用户确认。

## 5 未接入及验证边界

- 没有 ASR、TTS、联网背调、Supabase 实际项目或云端部署。DeepSeek 当前用于本人文本诊断和原文素材摘录，未生成完整准备包或实时语音对话。soundcore SDK 已链接，尚无硬件、token 或 license，真机接口未执行；云端 token 签发请求格式待供应商完整文档补充。
- 本次接入 BLE 离线录音同步。边录边传、设备标记导入、WiFi/MFi、OTA 等功能未接入；资料包 MFi 协议文本与截图不一致，当前未开启该通道。
- 未完整实现四类准备包生成、讲稿 AI 版本生成、CV 解析、五场跨场景表达基线算法、模型版本全量重算、旧 stories 数据迁移、模型调用性能与成本监测。
- 表结构预留这些记录；当前示例基线只是同场景字符数指标，不能当成完整 PRD 表达评分。短板状态机可验证，示例数据不能证明真实用户短板。
- 后端运行时每分钟扫描到期任务；尚未接入 03:00 Asia/Hong_Kong 的 Supabase pg_cron，也未测试生产多进程队列。
- 离线模式只在启动与回前台检查到期，不提供 iOS 后台自动清理承诺。服务模式依赖后端持续运行。
- 单文件上限 25MB；后端支持分块续传，iOS 当前整体上传并保留失败文件，尚未提供跨启动续传界面。
- 原音频证据回听返回签名完整文件与起止时间，由客户端定位；当前 App 只提供整场播放／暂停。
- 云端跨境处理未启用；单独同意页、处理者政策、备份删除窗口和上线法律复核需要在实际部署前落实。
- 本机 SQL guards 和 API 测试通过，Supabase RLS/Storage 和原生 iPhone 端到端测试尚未执行。

## 6 测试

```sh
cd backend
python -m pytest tests -q
```

`验证记录.md` 记录本次结果及未执行项目。测试在临时数据库中操作，不接触用户实际记忆；删除用例仅删除测试创建的数据。

## 工程目录

```text
ios/CanDid.xcodeproj          原生 iOS 工程与共享 scheme
ios/CanDid/                  SwiftUI、API、Keychain、soundcore 适配、音频转换、模型、视觉资源
ios/CanDidTests/             裸 Opus 转换与模拟器设备边界测试
ios/CanDidUITests/           欢迎页、记忆确认与 soundcore 录音入口测试
ios/Vendor/                 本地 SDK 与 libopus（忽略版本控制，可用脚本重建）
backend/app.py               FastAPI 路由、用户鉴权、签名文件访问
backend/memory.py            持久化、数据库守卫、上下文、状态机、模型与示例任务
backend/llm.py               DeepSeek 适配、结构化结果与逐字证据校验
backend/llm-config.example.json  无密钥配置模板
scripts/check-deepseek.py    隔离数据库的真实模型闭环验证（显式 --live）
backend/config.json          保留期、预算、评分版本和阈值
backend/tests/               后端业务与接口回归测试
backend/supabase/            Postgres/Supabase 参考结构
scripts/check-ios.sh         Mac/Xcode 构建、模拟器安装启动与自动化测试
scripts/prepare-soundcore.sh 从本地资料包准备 SDK，不复制凭证
scripts/build-opus.sh        校验官方源码并构建多架构 libopus
macOS开发.md                 macOS 配置、soundcore 接入前提和验收步骤
```

技术依据：资料包的 SDK 集成文档、v1.3.01 二进制头文件；[libopus 官方下载与校验值](https://opus-codec.org/downloads/)；Apple [SwiftUI](https://developer.apple.com/documentation/swiftui) 与 [设备运行](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)；[FastAPI JWT](https://fastapi.tiangolo.com/tutorial/security/oauth2-jwt/)；[Supabase JWT](https://supabase.com/docs/guides/auth/jwts) 与 [数据隔离](https://supabase.com/docs/guides/database/secure-data)。
