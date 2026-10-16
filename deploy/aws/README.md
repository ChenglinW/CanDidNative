# AWS 部署记录

2026-10-16（香港时间）迁移到新加坡。App 默认地址 `https://47.129.137.212`，自动领取设备专属凭证，无需填写后端配置。

## 当前运行位置

新加坡 `ap-southeast-1`，实例 `i-02d9b4fda6c8cc2d5`，Ubuntu 24.04 LTS，t2.micro（1 vCPU、约 1GiB RAM），根文件系统约 6.8GiB。代码现为 `/opt/candid/releases/20261016-preparation-recovery/backend`（基于工作区版本，修复准备包保存与继续，执行计数改为进展判断），当前链接 `/opt/candid/current`，虚拟环境 `/opt/candid/venv`。

```sh
ssh -i ~/Downloads/candid.pem ubuntu@47.129.137.212
sudo systemctl status candid caddy
sudo journalctl -u candid -n 80 --no-pager
sudo systemctl restart candid
```

`candid.service` 以独立 candid 用户运行，开机启动、异常自动重启。持久数据 `/var/lib/candid`；供应商配置 `/etc/candid/backend.env`（root 0600）。Git 只保存无密钥运维模板。不要把私有环境、访问令牌、签名密钥或数据库加入仓库。

安全组 `sg-049a57de0673f1b40` 的 TCP 80/443 来源为 `0.0.0.0/0`，保留既有 SSH 规则；8000 和 2019 仅监听回环地址。Caddy 支持 HTTPS、SSE、WebSocket，限制请求体 30MB。80 保留 ACME 验证，其余跳转 HTTPS。

## 证书维护

Certbot 5.8 使用 Let's Encrypt `shortlived` IP 证书，首次签发有效至 2026-10-22。`candid-cert-renew.timer` 每天检查两次，hook 更新 `/etc/caddy/tls` 的 root:caddy 0640 副本并重载 Caddy。`default_sni` 兼容不发送 SNI 的 IP 客户端。

```sh
sudo systemctl list-timers candid-cert-renew.timer
sudo /opt/certbot/bin/certbot renew
sudo journalctl -u candid-cert-renew -n 30 --no-pager
```

实例尚无弹性 IP，停止再启动可能改变公网地址；普通服务重启不改变 IP。地址变化需要同步 App、Caddy 和证书。

## 数据切换和回滚

原俄勒冈 `16.144.9.183` / `i-0ec4cda44414f07fc` 继续保留，但其 candid 服务已停止并禁用；Caddy 使用 `Caddyfile.oregon-proxy` 转发到新加坡，包含上游 Host 改写，避免两端分别写库。旧地址证书仍由旧服务器维护。

最终切换时停止旧后端，使用 SQLite backup API 生成一致备份，将数据库、storage、device-auth.key、local-access.txt 一起恢复。备份位于两台服务器 `/var/backups/candid-final-cutover*` 和维护电脑工作区的私有备份目录，权限限制访问。旧服务器 `/etc/caddy/Caddyfile.before-singapore` 保存直接代理本机的配置。

回滚前先停止新加坡写入并反向同步最新数据；随后恢复旧 Caddyfile、启用旧 candid 服务，再切换客户端地址。直接启动旧数据库会遗漏切换后的新数据。

## 验收

- Certbot `renew --dry-run` 续期演练通过，自动续期 timer 已启用。
- 后端 pytest：134 passed，2 warnings；iOS Release 真机目标构建通过，覆盖安装到既有 iPhone App，启动成功。
- 公网正常 TLS 校验：新旧地址 `/health`、鉴权 `/v1/capabilities`、`/v1/profile` 和已有录音详情均 200，无凭证能力接口均 401。
- 原手机凭证继续访问同一条实际录音，12 段转写和 1 份总结保留；SQLite integrity_check 为 ok。
- 新加坡安克模型合成短文本调用返回 OK，约 2.01 秒；手机启动后新加坡日志出现实时语音 WebSocket 接入。
- 迁移前实际手机音频 55.17 秒，已完成异步转写和总结。迁移后尚未重新录制一段新音频作端到端验收；soundcore 硬件未验证。麦克风测试时不要开启 Device Hub 屏幕共享。

设备接入由 `CANDID_DEVICE_AUTH=1` 开启，签名密钥保存在 `/var/lib/candid/device-auth.key`，数据库保存凭证哈希，按 owner 隔离资料。匿名新设备最多 30 台/小时、500 台总量；已有设备恢复不消耗新注册额度。

## PDF 解析修复（2026-10-16）

当前 release 的 PDF 模块已通过隔离测试后切换；原版本为 `/opt/candid/releases/20261016-singapore`。切换前的 SQLite 备份为 `/var/backups/candid-before-pdf-import.sqlite3`，旧代码保留供回滚。未改变配置、鉴权或数据目录。服务器本轮 132 项通过、1 项跳过；真实 HTTPS 已验证个人与项目两个入口的无打开密码加密 PDF、BOM 前缀 PDF，且能在资料列表读取提取文字。独立测试 owner 随后删除。详见 [PDF 修复记录](../../docs/PDF_IMPORT_FIX.md)。

## HTML 还原配套字段（2026-10-16）

本轮在原 V2 release 上复制发布目录，只替换 `tools/companion_tools.py` 并更新对应测试。新增可选 participants，仅保存用户对话里出现的原话片段；旧准备包与旧客户端继续兼容。目标服务器相关测试 20 项通过，本地完整后端测试 166 项通过；原库使用 SQLite backup API 备份到 `/var/backups/candid-before-ui-fidelity.sqlite3`，检查完整性为 ok。切换后 candid active，回环与公网正常 TLS `/health` 均正常。未迁移数据目录或供应商配置。原生 UI、逐句回听和验收见 [本轮报告](../../docs/ui-fidelity/REPORT.md)。

## 2026-10-16 TTS 更新

在现有 release 上更新 `app.py`、`agent_runtime/runtime.py`、`tasks/recordings.py`，补充口语最终回答和按正文／模型／音色／策略区分缓存。三个文件的旧版本备份在 `/opt/candid/rollback/20261016-tts`；数据、环境变量和凭证不变。服务重启、health 及真实供应商音频输出已核对，见 [TTS 交付](../../docs/tts-playback/REPORT.md)。
