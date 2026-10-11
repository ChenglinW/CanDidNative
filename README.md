# CanDid 原生 iOS 动态记忆库原型

这是 SwiftUI 原生 iOS 客户端与 FastAPI 后端工程，不是 HTML 或 WebView 包装。依据《Can Did 动态记忆库 PRD 与技术规格 v0.1》和此前温暖版视觉开发。

**当前交付是源码工程，尚未在 Xcode 编译、签名或真机安装。** 开发主机为 Windows，无法在此验证 Apple SDK。后端已在本机运行自动化测试；Swift/SQL 已完成语法检查，不能替代 Xcode 编译验证。

## 1 打开原生 iOS App

需要 Mac、Xcode 16 或更新版本、iOS 17 或更新的模拟器／iPhone。

1. 把整个工程包复制到 Mac，双击 `ios/CanDid.xcodeproj`。
2. 选择 **CanDid** scheme 与一个 iPhone 模拟器，点击 Run（⌘R）。无需后端即可进入明确标识的离线示例。
3. 真机：连接 iPhone，在 Xcode 的 Signing & Capabilities 选择你自己的 Team，并将 Bundle Identifier 改成自己的唯一名称。
4. 选择已连接的 iPhone，启用设备 Developer Mode 后点击 Run。首次录音由 iOS 弹出麦克风权限。

命令行构建检查（Mac）：

```sh
cd ios
xcodebuild -project CanDid.xcodeproj -scheme CanDid -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

`scripts/check-ios.sh` 包含同一检查，可在 Mac 上执行。构建错误应以 Xcode/Apple SDK 的结果为准；本次未生成 IPA，也未提交 TestFlight。

## 2 启动持久化后端

使用 Python 3.12 或更新版本：

```sh
cd backend
python -m venv .venv
# macOS/Linux
source .venv/bin/activate
# Windows PowerShell 则使用：.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
python run.py
```

默认监听 `127.0.0.1:8000`。首次运行生成 `backend/data/local-access.txt`；把其中令牌填入 App 右上角设置。不要把该文件加入仓库或发给其他人。令牌保存在 App Keychain。

在 App 设置中：

- 模拟器：后端地址 `http://127.0.0.1:8000`。
- iPhone 真机：电脑运行 `python run.py --lan`，手机与电脑处于同一可信局域网，填写 `http://电脑局域网IP:8000`。按需允许防火墙访问该端口。
- 勾选保存许可，输入令牌后点“连接并读取真实后端数据”。服务模式不会在断线时悄悄回退到示例。

本机令牌仅用于原型，不是生产登录。Debug 构建允许 HTTP 以连接本机服务；Release 不开放 ATS HTTP，客户端也要求 HTTPS。后端不对外网部署。

接口说明在 `http://127.0.0.1:8000/docs`。提供的 `backend/openapi.json` 是离线接口契约。

## 3 推荐演示闭环

1. 欢迎页阅读保存与保留说明，同意后进入 App。
2. 离线示例：场次 → 预处理示例 → 原文与复盘；记忆库 → 待确认 → 修改表达 → 确认。
3. 到场合中打开准备上下文，确认后的素材才会标为 FACT。草稿不会被混作已确认事实。
4. 连接后端：新建四种场景中的任一场合 → 运行预处理示例闭环 → 场次列表下拉刷新 → 查看示例诊断及素材草稿 → 确认 → 再查看准备上下文。
5. 真实录音：场合 → 练习或记录 → 本人练习／已告知的真实沟通 → 请求麦克风 → 暂停、继续、标记 → 结束保存。服务模式上传校验成功后删本机副本，后端保留原音频。
6. 无法取得对方同意时选择口述复盘，文字复述以用户原文证据存储；不采集对方声音。
7. 场次详情播放原音频；设置调整保留期、导出 JSON；单场次删除音频后保留本人转写及既有诊断。

**真实录音目前没有自动转写或 AI 诊断。** 后端返回明确的 `ASR_NOT_CONFIGURED`／等待模型状态。示例管线的 producer 为 `fixture@1`，不会把示例结果套到真实音频上。本人练习是真实录音流程，不是已接入的模拟听众语音 Agent。

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

- 没有 ASR、LLM、TTS、联网背调、D3200 SDK、Supabase 实际项目或云端部署。
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
ios/CanDid/                  SwiftUI、API、Keychain、录音、模型、视觉资源
backend/app.py               FastAPI 路由、用户鉴权、签名文件访问
backend/memory.py            持久化、数据库守卫、上下文、状态机与示例任务
backend/config.json          保留期、预算、评分版本和阈值
backend/tests/               后端业务与接口回归测试
backend/supabase/            Postgres/Supabase 参考结构
scripts/check-ios.sh         Mac/Xcode 构建检查
```

技术依据：Apple [SwiftUI](https://developer.apple.com/documentation/swiftui)、[麦克风许可](https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission(completionhandler:))、[设备运行](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)；[FastAPI JWT](https://fastapi.tiangolo.com/tutorial/security/oauth2-jwt/)；[Supabase JWT](https://supabase.com/docs/guides/auth/jwts) 与 [数据隔离](https://supabase.com/docs/guides/database/secure-data)。
