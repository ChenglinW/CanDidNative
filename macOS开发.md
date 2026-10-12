# macOS 开发与 soundcore 接入

更新时间：2026-10-12。macOS 是开发主机，App 为原生 iOS SwiftUI 工程。当前按用户要求预留 soundcore 接口，没有设备和有效 token；已验证的范围为 SDK 构建、音频处理和模拟器页面。

## 本机环境

- macOS 26.7.1，Intel Mac。
- Xcode 26.6（17F113），安装于 `/Applications/Xcode.app`。
- iOS 26.5（23F77）模拟器；本次使用 iPhone 17 Pro。
- 系统开发目录仍可为 Command Line Tools；项目脚本通过 `DEVELOPER_DIR` 局部选择 Xcode，不修改全局设置。
- 后端 `.venv` 使用 Python 3.12.14；系统 Python 3.9.6 不满足项目要求。

资料包最初位于 Downloads，现已复制到项目 `资料包/`；该目录和 `ios/Vendor/` 均忽略版本控制。保留用户提供的资料包，不提交大赛凭证。

## 准备与运行

在项目根目录执行：

```sh
sh scripts/prepare-soundcore.sh
sh scripts/build-opus.sh
sh scripts/check-ios.sh --build
sh scripts/check-ios.sh --run
sh scripts/check-ios.sh --test
```

`prepare-soundcore.sh` 使用本地 iOS v1.3.01 的 Release 版 `module_spplinkKit.xcframework` 与 `SoundcoreWorkAppleSDK.xcframework`。框架均有 iPhone arm64 和模拟器 arm64/x86_64 slice，作为静态库链接，不嵌入动态框架。资料包的 podspec 排除了全部模拟器架构，与实际二进制不一致，因此直接链接 XCFramework，不沿用该排除设置。

`build-opus.sh` 从 [Opus 官方下载站](https://opus-codec.org/downloads/) 下载 libopus 1.6.1，检查公布的 SHA256，构建 iPhone 与两种模拟器架构；首次运行需要联网。构建配置日志和源码在 `.build/opus/`，许可证复制到 `ios/Vendor/opus/COPYING`。脚本检查缺失依赖并明确退出。

`--test` 执行 XCTest 和 XCUITest，保存 `.xcresult` 至 `.build/TestResults/`。`--run` 安装并启动 App。非默认 Xcode 路径可显式指定：

```sh
DEVELOPER_DIR='/完整路径/Xcode.app/Contents/Developer' sh scripts/check-ios.sh --test
```

后端使用 Python 3.12 或更新版本创建虚拟环境并安装依赖：

```sh
cd backend
python3.12 -m venv .venv
source .venv/bin/activate
python -m pip install --only-binary=:all: -r requirements.txt
python -m pytest tests -q
python run.py
```

本机 Intel 环境的普通安装曾尝试编译最新版 cryptography；使用预编译依赖安装后选择兼容的 cryptography 48.0.1，避免引入 Rust 构建工具。后端依赖与录音 SDK 无关。

## 预留的 soundcore 接口

`Soundcore.swift` 管理 SDK 和主线程状态，`SoundcoreCallbacks.swift` 按资料包二进制头文件实现必要回调。SDK 回调可能来自后台线程，统一转交主线程后更新页面。当前提供：

| App 操作 | v1.3.01 实际接口 | 说明 |
|---|---|---|
| 授权 | `doInitSDK(logInterface:config:authResultListener:)` | 与文档示例 `initSDK` 名称有差异，以头文件及实际编译为准 |
| 注册业务回调 | `registerBusinessCallback(callback:)` | 仅在鉴权成功后注册 |
| 查找设备 | `startScan` / `stopScan` | BLE，扫描超时 15 秒，离开页面／后台停止扫描 |
| 连接／断开 | `connect` / `disconnect` | 连接超时 20 秒，断开时结束等待中的同步任务 |
| 时间同步 | `syncTime` | 每次连接立即发送 Unix 秒时间戳，不能使用毫秒 |
| 录音控制 | `pauseRecord` / `resumeRecord` | 仅控制设备已开始的录音，开始与结束使用硬件按键 |
| 设备信息／文件列表 | `getDeviceInfo` / `getAllAudioRecordFiles` | 读取当前录音状态与离线文件，显示设备时长（毫秒） |
| 文件同步 | `startSyncAudioFile` | 使用 BLE；单次同步超时 300 秒，进度按字节计算 |
| 同步完成 | `onDecodeFileCompleted` | 校验回调路径位于本次独立临时目录，再处理音频 |

Swift 初始化参数不支持 Kotlin 示例的省略默认值；代码显式提供完整参数。同步文件参数使用 `FileInfoModel` 对象列表，不能照旧注释只传文件 ID。实际 SDK 业务 API 无远程开始／结束录音接口，不伪造按钮。

设置 → soundcore 连接与授权中可填写与云端授权匹配的 `userID`、`deviceID`、token，或离线 license JSON 与签名；这些保存在独立 Keychain 项中，后端令牌不受影响。模拟器明确显示设备限制并禁用真实设备授权入口，不自动请求蓝牙或麦克风。

资料包提供 `app_id/app_key`，文档要求云端换取 token，但请求参数、返回参数和签名规则为空；Word 中也没有外部 Swagger 链接。因此未猜测云端签发实现、未把 app_key 放入 App。收到完整鉴权接口后再实现服务器签发适配；当前预留的是 SDK 授权配置入口与调用接口。

## 音频与场次

资料包 Q&A 规定导出的是裸 Opus：16 kHz、16 bit、双声道、20 ms 一帧、160 字节一包，不能直接将文件当 m4a 或 Ogg Opus 播放。`SoundcoreAudio.swift` 按固定包长度调用 libopus，写入 PCM WAV，再由 AVFoundation 转成 m4a。转换在后台执行，拒绝空文件、尾包不完整、异常解码结果和已有目标文件；成功转换后清理中间 WAV。

录音入口是 soundcore，旧 iPhone 麦克风录音实现已移除。用户在设备结束录音后选择文件，App 建立场次、同步、转换和保存。新场次请求可带 `recording_source: "soundcore"` 与 `device_file_id`；旧场次仍可读取。时长保留毫秒精度，不先截断到整秒。上传仍需字节数、SHA256 和服务端确认，上传失败保留本机 m4a 副本。

m4a 是转换后的回放副本；同步临时 Opus 和 WAV 在处理后清理，设备中的原始文件不自动删除。App 的删除与保留期仅管理 App／后端的副本，不能承诺清理设备上的音频。

## 测试与后续验收

自动化使用合成 Opus 数据验证真实 libopus 解码和 AVFoundation 转换，不产生用户录音或 AI 分析。UI 测试使用独立临时快照，不删除正常离线记忆；验证保存许可、记忆确认与 soundcore 入口。测试范围和结果见 `验证记录.md`。

有设备和授权后，在 iPhone 上验收：鉴权成功／失败／过期；权限拒绝、设备发现、连接与重连；物理按键录音、暂停／恢复与结束；离线文件列表、同步进度、断连失败、音频时长与可听性；后端上传成功／失败重试、回放和删除。

当前只预留 BLE 离线文件流程。实时音频、设备标记导入、WiFi/MFi、OTA 与设备删除没有接入。资料包 MFi 协议文字与截图存在差异，需供应商确认后才能配置该通道；当前不添加后台录音或 External Accessory 后台模式。
