# CanDid 真机安装脚本

在 Mac 的终端中运行。需要完整 Xcode、Python 3、已有 Apple Development 签名，以及 README 中的 soundcore/libopus 本地依赖。手机和平板需要与 Mac 配对、信任电脑，并开启开发者模式。

```sh
cd /Users/wcl/product/CanDidNative

# 查看设备；不会安装
sh scripts/install-ios.sh --list

# 安装当前本地代码到所有已配对的 iPhone/iPad
sh scripts/install-ios.sh --all

# 只安装指定设备（可重复 --device）
sh scripts/install-ios.sh --device 'iPhone (2)'

# 使用其他 Apple 开发团队
sh scripts/install-ios.sh --device 'iPhone' --team YOUR_TEAM_ID

# 安装完成后不自动启动
sh scripts/install-ios.sh --all --no-launch
```

同名设备请使用 `--list` 输出的标识代替名称。默认团队是本项目当前使用的 `SYG7G3A475`；也可以设置 `CANDID_DEVELOPMENT_TEAM`。

脚本编译本地当前版本，不自动拉取或切换 Git，不卸载原 App。每台设备使用自动签名注册和增量 Release 构建，检查签名及描述文件是否包含目标设备，然后安装并尝试启动。iPhone/iPad 以外的设备不参与安装。安装期间请不要切换 Git 提交。

## 连接和首次运行

- 最稳妥的方法是用数据线连接，解锁设备，并在出现提示时确认信任此电脑。
- 可以临时将自动锁定设为“永不”，完成后恢复。如果线或接口不够，逐台连接，使用 `--device` 分别安装。
- 已配对的无线设备必须在 Mac 可连接的网络上；列表有记录不代表当前在线。
- 首次运行如被安全检查拦截，在设备的“设置 → 通用 → VPN 与设备管理”核对并信任对应开发者，然后再次打开 App。脚本不能代替手机上的手动信任。
- 如果只是锁屏导致启动失败，安装仍然可能已完成；解锁后点 CanDid 即可。

## 日志与结果

每次运行会打印独立的 `.build/DeviceInstall/<时间>-<进程号>/` 目录，包含各设备的构建、签名、安装、启动日志及 `summary.json`。目录可能包含设备信息，请按需分享。

退出码：`0` 表示全部安装且启动成功（或指定不启动）；`1` 表示至少一个设备未完成安装；`2` 表示全部已安装，但至少一台需要解锁、开发者信任或其他启动处理。离线设备不会被报告为安装成功，其他设备仍会继续处理。

构建数据由后续运行复用，多个脚本实例不会同时修改同一个构建目录。安装使用同一应用标识覆盖已有 App；保留数据的实际行为仍受 App 自身的数据迁移逻辑影响。
