# 队友接入

GitHub 包含服务接入代码、配置模板和 `config/team-services.enc.json` 加密配置包。包内为现有安克文本、DashScope ASR/TTS、Monid 服务配置，采用 AES-256-GCM 认证加密，口令用 PBKDF2-HMAC-SHA256 派生。真实密钥不写进 Swift、源码或配置模板。

安装 Python 3.12 后，在项目根目录执行：

```sh
python3 -m venv backend/.venv
backend/.venv/bin/python -m pip install -r backend/requirements.txt
backend/.venv/bin/python scripts/team-secrets.py import
backend/.venv/bin/python backend/run.py
```

导入时会隐式输入口令，不显示或保存口令。项目负责人通过 GitHub 以外的私有渠道提供口令。负责人本机口令位于 `.secrets/team-services.password`；此目录被 Git 忽略。不要把口令放进 Issue、PR、提交记录或同一个公开配置包。导入产生 `.env.team.local`（0600），后端自动加载；显式 shell 环境和 `--env-file` 优先。

音频处理需安装 ffmpeg；iOS 需完整 Xcode 和 iOS 模拟器。SDK 与 Opus 本地构建按项目 `scripts/prepare-soundcore.sh`、`scripts/build-opus.sh` 和 README 操作，授权仍使用真实设备对应的 token/license。供应商密钥不能替代设备授权。SDK 二进制不随本 PR 提交。

```sh
sh scripts/check-ios.sh --build
backend/.venv/bin/python scripts/launch-chat.py
```

第二条命令只启动 App，不传测试消息。真机与队友手机需设置可达后端地址。需要局域网访问时显式使用 `backend/run.py --lan`，在 App 连接设置填写后端地址及其自己的 `backend/data/local-access.txt` 访问令牌；不使用供应商密钥作为 App 登录令牌。

开发配置默认允许临时手机会议录音；正式部署设置 `CANDID_RECORDING_MODE=device`，Release App 始终隐藏临时会议录音。手机语音消息是独立获准的功能，继续保留。

服务开关及非密钥配置见 `backend/agent_config/services.env.example`。本 demo 经负责人确认不设 Monid 金额限额，仍限定每任务工具调用次数和单次结果数量，记录原始 billing 与运行 ID。ASR/TTS 保存供应商用量；关闭 `CANDID_SPEECH_ENABLED` 可停止新语音调用。

密钥更新后由负责人重新打包：

```sh
backend/.venv/bin/python scripts/team-secrets.py pack --password-file .secrets/team-services.password
```

仅提交加密文件。队友再次导入时明确添加 `--replace`。不要把 Base64、App 内字符串或把解密口令随密文提交当作加密共享。
