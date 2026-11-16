# nginx-next

Nginx 端口转发一键脚本：把本机端口的 TCP 和 UDP 转发到后端服务器，不开 80，不提供任何网页。

## 使用

```bash
wget -N https://raw.githubusercontent.com/1432433gg/nginx-next/main/install.sh && chmod +x install.sh && ./install.sh
```

如果提示 `wget: command not found`，先运行 `apt update && apt install -y wget`。

先选「1. 安装 Nginx」，再用「3. 添加转发」一条条加规则：输入本机端口、后端 IP 或域名、后端端口，TCP 和 UDP 一起转发。

## 升级

直接下载脚本使用的，选「2. 升级脚本」即可。升级后自动更新已启用的流量监控组件，保留转发规则、流量上限和本月已用量；不用重新安装 Nginx。缺少流量统计依赖时会自动安装。

还没启用流量统计的，升级后进入「6. 流量统计」设置一次。通过 Git 克隆使用的，在仓库目录里运行 `git pull`，再运行 `./install.sh`。

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
6.  流量统计
7.  查看服务运行状态
—————— 其他 ——————
8.  更新 Nginx
9.  更新 Linux 内核
10. 安装 BBR 加速
0.  退出
```

主菜单执行一次所选操作后返回系统命令行。流量统计中的 `0` 退出统计页，返回系统命令行；后台流量监控继续运行。

## 安装做了什么

- 关闭防火墙（nftables / ufw）
- 时间同步：chrony 用谷歌时间服务器，时区 Asia/Shanghai
- 添加 nginx.org 官方源（稳定版），核对签名密钥指纹后安装 Nginx；系统自带源装的 Nginx 会先卸掉，原来的 `/etc/nginx` 先备份到 `/etc/nginx.bak-日期时间`
- 改 `/etc/nginx/nginx.conf`：`http { }` 整块注释掉，所以不开 80、没有欢迎页；`error_log` 改成不记录；最外层加上 `stream { include /etc/nginx/stream.d/*.conf; }`
- 启动并设为开机自启，最后自检 Nginx 只监听转发规则里的端口

## 转发规则

- 一条规则一个文件：`/etc/nginx/stream.d/本机端口.conf`，TCP 和 UDP 都转发
- 添加时会检查本机端口有没有被占用、有没有重复的规则；写好后先 `nginx -t` 检查，通过才重新加载，不通过就删掉这条恢复原样
- 后端可以填 IPv4 地址或域名。填域名时 Nginx 每 60 秒重新解析一次（DNS 用 8.8.8.8 和 1.1.1.1，只取 IPv4），域名的 IP 变了会自动跟上
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
- 「8. 更新 Nginx」用 apt 升级到 nginx.org 的最新版，会保留改过的配置，80 端口不会被重新打开；旧版本脚本加的规则也会顺便补上新设置（UDP reuseport、连接后端超时 10 秒）。

## 流量统计

安装 Nginx 后选「6. 流量统计」，首次只输入两项：

```text
流量上限（GB）：
已用流量（GB）：
```

流量上限的输入规则如下：

| 输入 | 结果 |
| --- | --- |
| 直接回车 | 使用 1 GB |
| 输入 `0` | 使用 1 GB |
| 输入 `500` | 使用 500 GB |

已用流量留空采用 0，可填入本月启用前已经使用的流量。两项均支持最多九位小数。设置保存后不再重复询问。

统计页面如下（数字仅为示例）：

```text
—————— 流量统计 ——————

已用流量：63.20 GB
流量上限：500.00 GB
剩余流量：436.80 GB
Nginx状态：运行中

1.  重置流量
2.  设置流量上限
3.  设置已用流量
0.  退出

请输入数字：
```

「7. 查看服务运行状态」在时间同步下方显示同一份流量统计：

```text
时间同步：运行中  已同步
流量统计：已用 63.20 GB  上限 500.00 GB  剩余 436.80 GB
```

- 读取默认 IPv4 出口网卡的总发送字节数，每 10 秒更新一次。只计算出站 TX，包含这张网卡上 Nginx、时间同步等所有程序的出站流量，也可能包含内网流量。1 GB 按 1,000,000,000 字节计算。
- 达到上限后，记录超额状态并快速停止 Nginx，结束已有 TCP/UDP 转发，规则文件保留。Nginx 启动前也检查额度，重启、更新或增删规则不会绕过限制；超额期间新增规则会保存，恢复后生效。
- 每月 1 日北京时间 00:00 清零本月已用量，保留自定义上限，并恢复因超额停止的转发。错过月初的机器下次开机会补做，定时器和监控同时触发也不会重复清零。没有超额恢复记录时，不会仅因打开统计页或进入新月份强制启动 Nginx。
- 重置流量会清零本月已用；修改已用量会覆盖原累计值，不是追加。修改后立即重新判断额度，达到上限就停，低于上限则恢复因超额停止的转发。
- 账本写入磁盘，重启和脚本升级保留用量。突然断电可能丢失最后一次采样尚未记入的少量流量；月界线和停止动作也存在少量采样误差。
- 统计依赖网卡和账本可读；异常时停止转发并保留原账本，不把错误当成 0。配置检查或启动失败时保留恢复状态，由后续检查重试。
- 初次设置后，systemd 管理后台监控和月度任务，退出脚本或断开 SSH 后继续运行。新版脚本启动时会更新已启用的配套组件，不重新初始化账本。

## 目录

```
install.sh                     安装脚本
nginx/stream-rule.conf         转发规则模板（后端是 IP）
nginx/stream-rule-domain.conf  转发规则模板（后端是域名）
chrony/google.conf             谷歌时间服务器
apt/archive.list               Debian 10 / 11 的归档软件源
traffic/guard.sh               月度出站流量监控
systemd/                       流量服务、月度任务和 Nginx 启动检查模板
tests/test_traffic.py           本地隔离测试
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
| `/var/lib/nginx-next/traffic/` | 流量账本和组件版本 |
| `/usr/local/lib/nginx-next/traffic-guard.sh` | 后台流量管理脚本 |
| `/etc/systemd/system/nginx-next-traffic.service` | 每 10 秒检查流量的后台服务 |
| `/etc/systemd/system/nginx-next-traffic-monthly.*` | 月初检查及错过后补执行的任务 |
| `/etc/systemd/system/nginx.service.d/traffic.conf` | Nginx 启动前额度检查和快速停止设置 |

## 本地测试

```bash
bash -n install.sh
bash -n traffic/guard.sh
python3 -m unittest discover -s tests -v
```

测试使用临时账本、模拟网卡、模拟时间和模拟 systemctl/nginx，不安装软件、不连接后端、不停止真实服务。Python 仅用于本地测试，服务器运行本功能不需要 Python。
