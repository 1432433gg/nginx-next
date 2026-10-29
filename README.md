# nginx-next

Nginx 端口转发一键脚本：把本机端口的 TCP 和 UDP 转发到后端服务器，不开 80，不提供任何网页。

## 使用

```bash
wget -N https://raw.githubusercontent.com/1432433gg/nginx-next/main/install.sh && chmod +x install.sh && ./install.sh
```

如果提示 `wget: command not found`，先运行 `apt update && apt install -y wget`。

先选「1. 安装 Nginx」，再用「3. 添加转发」一条条加规则：输入本机端口、后端 IP 或域名、后端端口，TCP 和 UDP 一起转发。

## 要求

- Debian 10+ 或 Ubuntu 20.04+ 的 LTS 版本，amd64 / arm64，root 用户
- nginx.org 现在只正式支持 Debian 12 / 13 和 Ubuntu 22.04 / 24.04 / 26.04。Debian 10 / 11、Ubuntu 20.04 装的是它最后出的版本（Debian 10 是 1.22，Debian 11 是 1.30.5，Ubuntu 20.04 是 1.28），以后不会再更新，转发功能不受影响
- 能访问 nginx.org（安装和更新 Nginx 用的是它的官方源）

## 菜单

```
—————— 安装 ——————
1.  安装 Nginx
2.  升级 脚本
—————— 转发规则 ——————
3.  添加转发
4.  删除转发
5.  查看转发
—————— 查看信息 ——————
6.  查看服务运行状态
—————— 其他 ——————
7.  更新 Nginx
8.  更新 Linux 内核
9.  安装 BBR 加速
0.  退出
```

## 安装做了什么

- 关闭防火墙（nftables / ufw）
- 时间同步：chrony 用谷歌时间服务器，时区 Asia/Shanghai
- 添加 nginx.org 官方源（稳定版），核对签名密钥指纹后安装 Nginx；系统自带源装的 Nginx 会先卸掉，原来的 `/etc/nginx` 先备份到 `/etc/nginx.bak-日期时间`
- 改 `/etc/nginx/nginx.conf`：`http { }` 整块注释掉，所以不开 80、没有欢迎页；`error_log` 改成不记录；最外层加上 `stream { include /etc/nginx/stream.d/*.conf; }`
- 启动并设为开机自启，最后自检 Nginx 只监听转发规则里的端口

## 转发规则

- 一条规则一个文件：`/etc/nginx/stream.d/本机端口.conf`，TCP 和 UDP 都转发
- 添加时会检查本机端口有没有被占用、有没有重复的规则；写好后先 `nginx -t` 检查，通过才重新加载，不通过就删掉这条恢复原样
- 后端可以填 IPv4 地址或域名。填域名时 Nginx 每 60 秒重新解析一次（DNS 用 1.1.1.1 和 8.8.8.8，只取 IPv4），域名的 IP 变了会自动跟上
- 只用 IPv4：本机只监听 IPv4，后端也只走 IPv4
- 要改一条规则，删掉再加

「5. 查看转发」显示成这样：

```
序号  本机端口     后端
1     10000     →  1.2.3.4:443
2     10010     →  1.2.3.4:443
3     10020     →  node.example.com:443
```

## 注意

- 转发是原样转给后端的。后端如果有网页（比如 [mihomo-next](https://github.com/1432433gg/mihomo-next) 装的 Reality 回落到 Reader），用浏览器带上域名访问这台机器的转发端口照样能看到，这是 Reality 伪装本来的设计。转发到 Shadowsocks 端口没有这个问题。
- 「7. 更新 Nginx」用 apt 升级到 nginx.org 的最新版，会保留改过的配置，80 端口不会被重新打开；旧版本脚本加的规则也会顺便补上新设置（UDP reuseport、连接后端超时 10 秒）。

## 目录

```
install.sh                     安装脚本
nginx/stream-rule.conf         转发规则模板（后端是 IP）
nginx/stream-rule-domain.conf  转发规则模板（后端是域名）
chrony/google.conf             谷歌时间服务器
apt/archive.list               Debian 10 / 11 的归档软件源
LICENSE                        MIT 许可证
```

模板里的 `{{PORT}}`、`{{TARGET}}` 等在添加规则时自动填入。只下载 `install.sh` 运行时，脚本会从本仓库下载这些文件。

## 文件位置

| 路径 | 内容 |
| --- | --- |
| `/etc/nginx/nginx.conf` | Nginx 主配置（原文件备份在 `nginx.conf.nginx-next.bak`） |
| `/etc/nginx/stream.d/` | 转发规则，一条一个文件 |
| `/etc/apt/sources.list.d/nginx.list` | nginx.org 软件源 |
| `/etc/apt/preferences.d/99nginx` | 优先使用 nginx.org 的包 |
