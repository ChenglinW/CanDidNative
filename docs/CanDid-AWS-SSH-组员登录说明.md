# CanDid AWS 服务器登录说明

核验时间：2026-10-17（香港时间）。SSH 登录及 HTTPS 健康接口均正常。

## 连接信息

| 项目 | 值 |
|---|---|
| 公网 IP | 47.129.137.212 |
| SSH 端口 | 22 |
| SSH 用户名 | ubuntu |
| 认证方式 | PEM 私钥 |
| 需单独接收的文件 | candid.pem |
| 后端地址 | https://47.129.137.212 |
| 健康检查 | https://47.129.137.212/health |

## macOS / Linux 登录

把 candid.pem 放到自己的 ~/.ssh/ 目录，再运行：

```bash
chmod 600 ~/.ssh/candid.pem
ssh -i ~/.ssh/candid.pem ubuntu@47.129.137.212
```

首次连接会要求确认服务器指纹。请与文末指纹核对。

如果密钥放在下载目录：

```bash
chmod 600 ~/Downloads/candid.pem
ssh -i ~/Downloads/candid.pem ubuntu@47.129.137.212
```

## Windows PowerShell 登录

把 candid.pem 放到自己的用户目录下 .ssh 文件夹，用系统 OpenSSH：

```powershell
ssh -i "$env:USERPROFILE\.ssh\candid.pem" ubuntu@47.129.137.212
```

若提示私钥权限过宽，在文件“属性 → 安全 → 高级”关闭继承，并仅保留本人所需的读取权限后重试。

## 服务器目录

| 内容 | 路径 |
|---|---|
| 当前运行版本入口 | /opt/candid/current |
| 当前版本实际目录（本次核验） | /opt/candid/releases/20261017-roleplay |
| Python 虚拟环境 | /opt/candid/venv |
| 后端环境配置 | /etc/candid/backend.env |
| 持久数据目录 | /var/lib/candid |
| SQLite 数据库 | /var/lib/candid/memory.sqlite3 |
| 录音和附件 | /var/lib/candid/storage |
| systemd 服务名 | candid |

## 查看服务和日志

```bash
sudo systemctl status candid --no-pager
sudo journalctl -u candid -n 100 --no-pager
sudo journalctl -u candid -f
curl -fsS http://127.0.0.1:8000/health
readlink -f /opt/candid/current
sudo systemctl cat candid
```

需要发布或修改配置时，先确认当前版本与备份。服务重启命令：

```bash
sudo systemctl restart candid
```

## 文件传输（在自己电脑上执行）

上传文件到服务器用户目录：

```bash
scp -i ~/.ssh/candid.pem ./your-file.zip ubuntu@47.129.137.212:~/
```

从服务器下载文件：

```bash
scp -i ~/.ssh/candid.pem ubuntu@47.129.137.212:~/your-file.zip ./
```

## 常见连接问题

- Permission denied (publickey)：使用 ubuntu 用户，检查密钥是否为 candid.pem。
- UNPROTECTED PRIVATE KEY FILE：macOS / Linux 执行 chmod 600 后重试。
- Connection timed out：检查网络/VPN，以及 AWS 安全组是否允许自己的出口 IP 访问 TCP 22。
- Connection refused：目标可达但 SSH 端口未接受连接，需要检查 ssh 服务或端口规则。

## 交接

本说明不包含私钥内容。请将 candid.pem 单独通过团队私密渠道交给需要登录的组员，不要提交到 GitHub。私钥允许登录线上服务器，应只发给实际需要访问的人。

## 服务器指纹（通过已登录服务器核验）

ED25519：`SHA256:sWgIe9n/VIDOB288RdU0vtf3Ti97AQ1sNY7Jf+jMsQk`
