# Cloudflare Tunnel 一键部署管理脚本

> 🚀 CF Tunnel 管理脚本！支持 Debian/Ubuntu/Alpine，自动处理依赖，无需公网 IP 即可让外网访问你的内网服务！

---

## 🔥 脚本特色

*   **多系统支持**: 完美支持 Debian, Ubuntu, Alpine Linux (amd64/arm64)
*   **智能兼容**: 自动识别 Systemd / OpenRC，Alpine 下自动安装 Bash
*   **双模认证**: 支持 Tunnel Token 和 浏览器授权 (高级)
*   **DNS 冲突解决**: 智能检测 DNS 记录冲突，提供交互式删除引导
*   **彻底卸载**: 支持一键从本地和云端彻底清除隧道及残留文件
*   **全功能管理**: 安装、更新、配置、服务管理、日志查看一站式搞定

## 📖 什么是 Cloudflare Tunnel？

Cloudflare Tunnel (原 Argo Tunnel) 可以让你：
- **无需公网 IP** - 家庭宽带、NAT 网络都能用
- **无需开放端口** - 不用配置防火墙端口转发，更安全
- **免费 HTTPS** - 自动获得 Cloudflare SSL 证书
- **全球加速** - 依托 Cloudflare 庞大的边缘网络

**使用场景：**
- 在家搭建网站、博客
- 远程访问家里的 NAS、软路由、PVE
- 访问开发中的本地项目调试
- 穿透公司内网访问内部服务

---

## 📋 准备工作

1. ✅ 一个 [Cloudflare 账户](https://dash.cloudflare.com/sign-up)（免费）
2. ✅ 一个已添加到 Cloudflare 的域名
3. ✅ 一台 Linux 服务器（Debian/Ubuntu 或 Alpine）

---

## 🚀 快速开始

### 第一步：一键运行

SSH 登录到你的服务器，直接执行以下命令：

```
(curl -LfsS https://raw.githubusercontent.com/0xdabiaoge/cf-tunnel/main/cf-tunnel.sh -o /usr/local/bin/cft || wget -q https://raw.githubusercontent.com/0xdabiaoge/cf-tunnel/main/cf-tunnel.sh -O /usr/local/bin/cft) && chmod +x /usr/local/bin/cft && cft
```

**快捷命令：cft**

### 第二步：安装 cloudflared

脚本启动后，你会看到主菜单：

```text
╔═══════════════════════════════════════════════════════════════╗
║           Cloudflare Tunnel 部署管理脚本                      ║
║           支持: Debian/Ubuntu, Alpine Linux                   ║
╚═══════════════════════════════════════════════════════════════╝

系统: Alpine Linux (alpine) | 架构: amd64
cloudflared: 未安装

════════════════════════════════════════
  1. 安装 cloudflared        <-- 第一步：安装核心组件
  2. 配置隧道认证            <-- 第二步：绑定账号
  3. 域名管理                <-- 第三步：配置域名映射
  4. 查看 Tunnel 列表
  5. 服务管理
  6. 查看状态
  7. 更新 cloudflared
  8. 查看日志
  9. 卸载 cloudflared
════════════════════════════════════════
  0. 退出
```

**输入 `1` 回车**，脚本会自动从 GitHub 下载并安装最新版 cloudflared。

### 第三步：配置隧道认证（二选一）

**方式一：Tunnel Token（极力推荐 🔥）**
适合已有 Cloudflare Dashboard 操作经验或新手用户。
1. 在 [Cloudflare Dashboard](https://one.dash.cloudflare.com) -> Networks -> Tunnels 创建 Tunnels。
2. 复制页面显示的 Connector 命令中的 Token (`eyJh...`那一长串)。
3. 脚本菜单选择 `2` -> `1. Tunnel Token` -> 粘贴 Token。

**方式二：浏览器授权**
适合无头服务器首次配置。
1. 脚本菜单选择 `2` -> `2. 浏览器授权登录`。
2. 复制屏幕上的链接，在电脑浏览器打开并登录授权。
3. 授权后脚本会自动获取证书。

---

## 🛠️ 高级功能

### 🌐 智能 DNS 管理
在配置域名时，脚本会自动添加 DNS 记录。
*   **冲突检测**：如果该域名已被其他记录占用（Error 1003），脚本会红色报警提示。
*   **交互解决**：此时你可以去 Dashboard 删除旧记录，回到脚本界面直接按 **Y** 即可重试，无需重启脚本。

### 🧹 彻底卸载与清理
主菜单选择 `9. 卸载 cloudflared`，提供真正的**彻底清理**：
1.  **云端清理**：智能识别并在你确认后**自动删除云端隧道**（仅限已登录状态）。
2.  **本地清理**：停止服务、移除开机自启、删除二进制文件。
3.  **残留清理**：自动清空 `/etc/cloudflared` 及所有日志文件。
4.  **脚本自删**：最后会自动删除脚本文件自身，不留痕迹。

---

## ❓ 常见问题

### Q: Alpine 系统提示 `bash: not found`？
**无需担心**。本脚本内置自举逻辑，在 Alpine 下运行时会自动检测并安装 Bash 环境，您直接运行脚本即可。

### Q: 服务启动失败怎么办？
脚本内置了容错机制，如果启动失败不会直接退出。请使用菜单 `8. 查看日志` 获取详细错误信息。如果不方便查看，也可以使用命令：
- Debian/Ubuntu: `journalctl -u cloudflared -n 50`
- Alpine (OpenRC): `tail -n 50 /var/log/cloudflared.log`

### Q: 出现 "DNS 记录冲突" 怎么处理？
这是因为该域名已经被其他记录（如 A记录或旧的 CNAME）占用了。请登录 Cloudflare 后台，删除该域名的 DNS 记录，然后回到脚本按 Y 重试。

---

## 📂 文件结构
| 文件/目录 | 说明 |
|------|------|
| `/usr/local/bin/cloudflared` | 主程序 |
| `/etc/cloudflared/` | 配置文件目录 |
| `/etc/init.d/cloudflared` | OpenRC 服务脚本 (Alpine) |
| `/etc/systemd/system/cloudflared.service` | Systemd 服务文件 (Debian) |
| `~/.cloudflared/cert.pem` | 用户授权证书 |

---

## License
MIT License

