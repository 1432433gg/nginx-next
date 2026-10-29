#!/usr/bin/env bash
#
# Nginx 端口转发一键脚本
# https://github.com/1432433gg/nginx-next
#
# 用法：
#   wget -N https://raw.githubusercontent.com/1432433gg/nginx-next/main/install.sh && chmod +x install.sh && ./install.sh
#

SCRIPT_VERSION="1.0.3"

# ─── 路径 ───
NGINX_BIN=/usr/sbin/nginx
NGINX_CONF_DIR=/etc/nginx
NGINX_CONF=$NGINX_CONF_DIR/nginx.conf
# 每条转发一个文件：/etc/nginx/stream.d/本机端口.conf
STREAM_DIR=$NGINX_CONF_DIR/stream.d

# nginx.org 官方源（稳定版）
NGINX_KEY_URL=https://nginx.org/keys/nginx_signing.key
NGINX_KEYRING=/usr/share/keyrings/nginx-archive-keyring.gpg
NGINX_APT_LIST=/etc/apt/sources.list.d/nginx.list
NGINX_APT_PREF=/etc/apt/preferences.d/99nginx
# nginx.org 签名密钥的指纹（见 https://nginx.org/en/linux_packages.html），下载的密钥必须含其中之一
NGINX_KEY_FINGERPRINTS="573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62 8540A6F18833A80E9C1653A42FD21310B49F6B46 9E9BE90EACBCDE69FE9B204CBCDCD8A38D88A2B3"

BBR_SCRIPT_URL=https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcp.sh
OS_RELEASE_FILE=/etc/os-release
APT_SOURCES_LIST=/etc/apt/sources.list
APT_SOURCES_DIR=/etc/apt/sources.list.d
APT_CONF_DIR=/etc/apt/apt.conf.d
# 已停止维护、软件源移到 archive.debian.org 的 Debian 版本
EOL_CODENAMES="buster bullseye"
# nginx.org 还在正式支持的系统，其他的（Debian 10 / 11、Ubuntu 20.04）只能装到它最后出的版本
NGINX_OFFICIAL_CODENAMES="bookworm trixie jammy noble resolute"

# 配置文件模板放在仓库的各个目录里；只下载了 install.sh 时，运行时从 GitHub 下载
REPO_RAW=https://raw.githubusercontent.com/1432433gg/nginx-next/main
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
TEMPLATES="nginx/stream-rule.conf nginx/stream-rule-domain.conf chrony/google.conf apt/archive.list"
# 后端填域名时，Nginx 用这两个 DNS 服务器定时重新解析
RESOLVERS="8.8.8.8 1.1.1.1"
TEMPLATE_DIR=""

# ─── 输出 ───
Green="\033[32m"
Red="\033[31m"
Yellow="\033[33m"
Blue="\033[36m"
Font="\033[0m"
OK="${Green}[OK]${Font}"
ERROR="${Red}[错误]${Font}"
WARN="${Yellow}[注意]${Font}"

print_ok() { echo -e "${OK} ${Blue}$1${Font}"; }
print_error() { echo -e "${ERROR} ${Red}$1${Font}"; }
print_warn() { echo -e "${WARN} ${Yellow}$1${Font}"; }
print_info() { echo -e "${Green}==>${Font} $1"; }

# 检查上一条命令的结果，失败就退出
judge() {
  if [[ $? -eq 0 ]]; then
    print_ok "$1 完成"
    sleep 1
  else
    print_error "$1 失败"
    exit 1
  fi
}

# ─── 配置模板 ───
local_templates() {
  local f
  [[ -n $SCRIPT_DIR ]] || return 1
  for f in $TEMPLATES; do
    [[ -f $SCRIPT_DIR/$f ]] || return 1
  done
}

# 在仓库目录里运行就用本地模板，否则下载到临时目录
prepare_templates() {
  local f tmp
  [[ -n $TEMPLATE_DIR ]] && return 0
  if local_templates; then
    TEMPLATE_DIR=$SCRIPT_DIR
    return 0
  fi
  tmp=$(mktemp -d)
  for f in $TEMPLATES; do
    mkdir -p "$tmp/${f%/*}"
    if ! wget -q --timeout=15 --tries=2 -O "$tmp/$f" "$REPO_RAW/$f"; then
      rm -rf "$tmp"
      print_error "下载配置模板失败：$REPO_RAW/$f"
      return 1
    fi
  done
  TEMPLATE_DIR=$tmp
  TEMPLATE_TMP=$tmp
  trap 'rm -rf "$TEMPLATE_TMP"' EXIT
}

# 用模板生成文件，把 {{名字}} 换成对应的值
# 用法：render_template 模板 目标文件 名字=值 ...
render_template() {
  local name=$1 dest=$2 content pair key
  prepare_templates || return 1
  content=$(<"$TEMPLATE_DIR/$name") || return 1
  shift 2
  for pair in "$@"; do
    key="{{${pair%%=*}}}"
    content=${content//"$key"/"${pair#*=}"}
  done
  if [[ $content == *"{{"*"}}"* ]]; then
    print_error "模板 $name 里还有没填的内容"
    return 1
  fi
  mkdir -p "$(dirname "$dest")"
  printf '%s\n' "$content" >"$dest"
}

# ─── 系统检查 ───
is_root() {
  if [[ $EUID -ne 0 ]]; then
    print_error "请用 root 运行"
    exit 1
  fi
}

# Debian 10+、Ubuntu 20.04+ 的 LTS 版本。nginx.org 现在正式支持的是 Debian 12 / 13 和
# Ubuntu 22.04 / 24.04 / 26.04（https://nginx.org/en/linux_packages.html），更早的系统软件源还在，
# 只是停止更新了
detect_system() {
  if [[ ! -f $OS_RELEASE_FILE ]]; then
    print_error "无法识别系统"
    exit 1
  fi
  # shellcheck disable=SC1090
  OS_ID=$(. "$OS_RELEASE_FILE" && echo "$ID")
  # shellcheck disable=SC1090
  OS_VERSION=$(. "$OS_RELEASE_FILE" && echo "${VERSION_ID:-0}")
  # shellcheck disable=SC1090
  OS_CODENAME=$(. "$OS_RELEASE_FILE" && echo "${VERSION_CODENAME:-}")
  case "$OS_ID" in
    debian)
      if [[ ${OS_VERSION%%.*} -lt 10 ]]; then
        print_error "仅支持 Debian 10 及以上"
        exit 1
      fi
      ;;
    ubuntu)
      # LTS 版本号是偶数年的 .04
      if ! [[ $OS_VERSION =~ ^([0-9]+)\.04$ ]] || ((BASH_REMATCH[1] < 20 || BASH_REMATCH[1] % 2 != 0)); then
        print_error "仅支持 Ubuntu 20.04 及以上的 LTS 版本（20.04 / 22.04 / 24.04 / 26.04）"
        exit 1
      fi
      ;;
    *)
      print_error "仅支持 Debian / Ubuntu"
      exit 1
      ;;
  esac
  if [[ -z $OS_CODENAME ]]; then
    print_error "无法识别系统版本代号"
    exit 1
  fi

  case "$(uname -m)" in
    x86_64 | amd64) ARCH=amd64 ;;
    aarch64 | arm64) ARCH=arm64 ;;
    *)
      print_error "不支持的架构：$(uname -m)"
      exit 1
      ;;
  esac
}

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 -y -qq install "$@" >/dev/null
}

# 新开的机器上系统可能正在自动更新，占着 apt，等它结束
wait_for_apt() {
  local i
  for i in $(seq 1 60); do
    pgrep -x 'apt|apt-get|dpkg|unattended-upgr' >/dev/null 2>&1 || return 0
    [[ $i -eq 1 ]] && print_info "系统正在自动更新，等待完成（最多 5 分钟）"
    sleep 5
  done
  print_warn "等待超时，继续执行"
}

is_eol_debian() {
  [[ $OS_ID == debian && " $EOL_CODENAMES " == *" $OS_CODENAME "* ]]
}

# Debian 10 / 11 已停止维护，软件源已从 deb.debian.org 移到 archive.debian.org
use_archive_sources() {
  local security f
  is_eol_debian || return 0
  if grep -qs "archive.debian.org" "$APT_SOURCES_LIST"; then
    return 0
  fi
  if [[ $OS_CODENAME == buster ]]; then
    security="buster/updates"
  else
    security="${OS_CODENAME}-security"
  fi
  if [[ -f $APT_SOURCES_LIST && ! -f $APT_SOURCES_LIST.nginx-next.bak ]]; then
    cp "$APT_SOURCES_LIST" "$APT_SOURCES_LIST.nginx-next.bak"
  fi
  render_template apt/archive.list "$APT_SOURCES_LIST" CODENAME="$OS_CODENAME" SECURITY="$security" || return 1
  # 其他源文件里还指向旧地址的，先停用（改名加 .disabled）
  for f in "$APT_SOURCES_DIR"/*.list "$APT_SOURCES_DIR"/*.sources; do
    [[ -f $f ]] || continue
    if grep -qE "(deb|security|ftp)[.]debian[.]org" "$f"; then
      mv "$f" "$f.disabled"
    fi
  done
  # 归档源的签名有效期已过，不检查
  mkdir -p "$APT_CONF_DIR"
  echo 'Acquire::Check-Valid-Until "false";' >"$APT_CONF_DIR/99nginx-next-archive"
  print_warn "Debian $OS_CODENAME 已停止维护，软件源已切换到 archive.debian.org"
}

# nginx.org 已经不再给这个系统出新版本时提醒一下
nginx_support_note() {
  [[ " $NGINX_OFFICIAL_CODENAMES " == *" $OS_CODENAME "* ]] && return 0
  print_warn "nginx.org 已不再正式支持 $OS_ID $OS_CODENAME：装的是它给这个系统出的最后一个版本，以后不会再有更新；转发功能不受影响"
}

apt_update() {
  wait_for_apt
  use_archive_sources || return 1
  if ! apt-get -qq update; then
    print_error "apt update 失败，请检查软件源"
    return 1
  fi
}

install_deps() {
  print_info "安装依赖"
  apt_update || exit 1
  apt_install wget curl lsof gnupg ca-certificates chrony
  judge "安装依赖"
}

disable_firewall() {
  local svc
  for svc in nftables ufw; do
    systemctl stop "$svc" >/dev/null 2>&1
    systemctl disable "$svc" >/dev/null 2>&1
  done
  print_ok "已关闭防火墙（nftables / ufw）"
}

# ─── 时间同步 ───
# 注释掉原有的时间服务器，只用谷歌的；重复运行只保留一份
configure_chrony_file() {
  local conf=$1
  prepare_templates || return 1
  sed -i '/^# BEGIN nginx-next$/,/^# END nginx-next$/d' "$conf"
  sed -i -E 's/^((pool|server|sourcedir)[[:space:]].*)$/# \1/' "$conf"
  if [[ -s $conf && -n $(tail -c1 "$conf") ]]; then
    echo >>"$conf"
  fi
  printf '%s\n' "# BEGIN nginx-next" "$(<"$TEMPLATE_DIR/chrony/google.conf")" "# END nginx-next" >>"$conf"
}

configure_chrony() {
  local conf=/etc/chrony/chrony.conf
  [[ -f $conf ]] || conf=/etc/chrony.conf
  if [[ ! -f $conf ]]; then
    print_error "找不到 chrony 配置文件"
    return 1
  fi
  configure_chrony_file "$conf" || return 1
  timedatectl set-timezone Asia/Shanghai >/dev/null 2>&1
  systemctl enable chrony >/dev/null 2>&1
  systemctl restart chrony
  timedatectl set-ntp true >/dev/null 2>&1
  print_ok "时间同步已设置（谷歌时间服务器，时区 Asia/Shanghai）"
  wait_time_sync
}

now_time() {
  date '+%Y-%m-%d %H:%M:%S %Z'
}

# 等 chrony 连上时间服务器，立即校准一次，再显示同步后的时间
wait_time_sync() {
  local server
  print_info "等待时间同步（最多 30 秒）"
  if ! chronyc waitsync 15 0 0 2 >/dev/null 2>&1; then
    print_warn "30 秒内没有同步上，当前时间 $(now_time)，chrony 会在后台继续同步"
    return 0
  fi
  chronyc makestep >/dev/null 2>&1
  server=$(chronyc tracking 2>/dev/null | awk -F'[()]' '/^Reference ID/ {print $2; exit}')
  print_ok "时间已同步：$(now_time)（时间服务器 ${server:-未知}）"
}

time_sync_state() {
  if chronyc tracking 2>/dev/null | grep -qE '^Leap status +: Normal'; then
    echo -e "${Green}已同步${Font}"
  else
    echo -e "${Red}未同步${Font}"
  fi
}

# ─── 输入 ───
is_ipv4() {
  local part
  [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  for part in ${1//./ }; do
    ((10#$part <= 255)) || return 1
  done
}

# 本机端口：1-65535，不能已经有转发规则，TCP 和 UDP 都不能被占用
read_local_port() {
  local input
  while true; do
    read -rp "本机端口：" input
    input=$(echo "$input" | tr -d '[:space:]')
    if [[ ! $input =~ ^[0-9]{1,5}$ ]] || ((10#$input < 1 || 10#$input > 65535)); then
      print_error "请输入 1-65535 之间的数字"
      continue
    fi
    input=$((10#$input))
    if [[ -f $STREAM_DIR/$input.conf ]]; then
      print_error "端口 $input 已经有转发规则：→ $(rule_target "$STREAM_DIR/$input.conf")，要改请先删掉"
      continue
    fi
    if port_in_use "$input"; then
      print_warn "请换一个端口"
      continue
    fi
    LOCAL_PORT=$input
    return 0
  done
}

is_domain() {
  [[ $1 =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]
}

# 后端：IPv4 或域名（不用 IPv6）。域名用 TARGET_IS_DOMAIN=1 标出来，规则里会定时重新解析，只取 IPv4
read_target() {
  local input
  while true; do
    read -rp "后端 IP 或域名：" input
    input=$(echo "$input" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    TARGET_IS_DOMAIN=0
    if is_ipv4 "$input"; then
      TARGET=$input
      return 0
    elif is_domain "$input"; then
      TARGET=$input
      TARGET_IS_DOMAIN=1
      return 0
    else
      print_error "请输入 IPv4 地址或域名（不支持 IPv6）"
    fi
  done
}

read_target_port() {
  local input
  while true; do
    read -rp "后端端口：" input
    input=$(echo "$input" | tr -d '[:space:]')
    if [[ $input =~ ^[0-9]{1,5}$ ]] && ((10#$input >= 1 && 10#$input <= 65535)); then
      TARGET_PORT=$((10#$input))
      return 0
    fi
    print_error "请输入 1-65535 之间的数字"
  done
}

# TCP 或 UDP 被占用时显示占用信息并返回成功；不结束别人的进程，换个端口就好
port_in_use() {
  local port=$1 used=1
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    print_error "端口 $port 的 TCP 已被占用，以下为占用信息"
    lsof -nP -iTCP:"$port" -sTCP:LISTEN
    used=0
  fi
  # UDP 用 ss 只看本机端口；lsof -iUDP:端口 会把「对方端口是它」的出站连接也算进去
  if ss -Hlnu "sport = :$port" 2>/dev/null | grep -q .; then
    print_error "端口 $port 的 UDP 已被占用，以下为占用信息"
    ss -lnup "sport = :$port"
    used=0
  fi
  return $used
}

# ─── Nginx ───
nginx_installed() {
  [[ -x $NGINX_BIN ]]
}

nginx_version() {
  nginx_installed || return 0
  "$NGINX_BIN" -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

require_installed() {
  if ! nginx_installed || [[ ! -d $STREAM_DIR ]]; then
    print_error "还没安装 Nginx，请先选「1. 安装 Nginx」"
    return 1
  fi
}

check_nginx_config() {
  local out
  if ! out=$("$NGINX_BIN" -t 2>&1); then
    echo "$out" | tail -n 5
    print_error "Nginx 配置检查未通过"
    return 1
  fi
}

# 在运行就重新加载，没在运行就启动
reload_nginx() {
  check_nginx_config || return 1
  systemctl enable nginx >/dev/null 2>&1
  if systemctl is-active --quiet nginx; then
    systemctl reload nginx
  else
    systemctl restart nginx
  fi
  sleep 1
  if systemctl is-active --quiet nginx; then
    print_ok "Nginx 运行中"
  else
    print_error "Nginx 启动失败，可以运行 journalctl -u nginx -n 20 查看原因"
    return 1
  fi
}

# Nginx 正在监听的 TCP 端口，空格分隔
nginx_listen_ports() {
  lsof -nP -c nginx -a -iTCP -sTCP:LISTEN 2>/dev/null |
    awk 'NR > 1 {sub(/.*:/, "", $9); print $9}' | sort -un | tr '\n' ' '
}

# 自检：Nginx 只能监听转发规则里的端口，不能开 80
check_listen() {
  local ports port
  ports=$(nginx_listen_ports)
  # 转发规则本身用了 80 端口就不算（那是转发，不是网页）
  if grep -qw 80 <<<"$ports" && [[ ! -f $STREAM_DIR/80.conf ]]; then
    print_error "Nginx 还在监听 80 端口，请检查 $NGINX_CONF 里的 http 是否已注释掉"
    return 1
  fi
  for port in $(rule_ports); do
    if ! grep -qw "$port" <<<"$ports"; then
      print_warn "转发规则里的端口 $port 没有在监听，可能被别的程序占用了"
    fi
  done
  if [[ -z $ports ]]; then
    print_ok "Nginx 没有监听任何端口（还没有转发规则）"
  else
    print_ok "Nginx 只监听转发端口：${ports% }"
  fi
}

# 添加 nginx.org 官方源（稳定版）：下载签名密钥并核对指纹，优先用它的包
add_nginx_source() {
  local tmp fps fp ok=0
  print_info "添加 nginx.org 软件源"
  if ! curl -fsSL --max-time 30 -o /dev/null "http://nginx.org/packages/$OS_ID/dists/$OS_CODENAME/Release"; then
    print_error "nginx.org 没有 $OS_ID $OS_CODENAME 的软件源，或者访问不了 nginx.org"
    return 1
  fi
  tmp=$(mktemp)
  if ! curl -fsSL --max-time 30 -o "$tmp" "$NGINX_KEY_URL"; then
    rm -f "$tmp"
    print_error "下载 nginx.org 签名密钥失败：$NGINX_KEY_URL"
    return 1
  fi
  if ! gpg --batch --yes --dearmor -o "$NGINX_KEYRING" "$tmp" 2>/dev/null; then
    rm -f "$tmp" "$NGINX_KEYRING"
    print_error "签名密钥格式不对"
    return 1
  fi
  rm -f "$tmp"
  fps=$(gpg --dry-run --quiet --no-keyring --import --import-options import-show "$NGINX_KEYRING" 2>/dev/null | grep -oE '[0-9A-F]{40}')
  for fp in $NGINX_KEY_FINGERPRINTS; do
    grep -qx "$fp" <<<"$fps" && ok=1
  done
  if [[ $ok -eq 0 ]]; then
    rm -f "$NGINX_KEYRING"
    print_error "nginx.org 签名密钥的指纹对不上，已删掉，没有添加软件源"
    echo "下载到的指纹：${fps:-无}"
    return 1
  fi
  echo "deb [signed-by=$NGINX_KEYRING] http://nginx.org/packages/$OS_ID $OS_CODENAME nginx" >"$NGINX_APT_LIST"
  printf 'Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n' >"$NGINX_APT_PREF"
  print_ok "已添加 nginx.org 软件源（$OS_ID $OS_CODENAME，稳定版）"
}

# 系统自带源装的 Nginx（有 nginx-common 包）配置目录结构不一样，先卸掉再装 nginx.org 的。
# 卸载会连 /etc/nginx 里的配置一起删掉，所以先整个备份
remove_distro_nginx() {
  local backup
  local -a pkgs
  dpkg -s nginx-common >/dev/null 2>&1 || return 0
  print_warn "检测到系统自带源安装的 Nginx，先卸载"
  if [[ -d $NGINX_CONF_DIR ]]; then
    backup=$NGINX_CONF_DIR.bak-$(date +%Y%m%d%H%M%S)
    if ! cp -a "$NGINX_CONF_DIR" "$backup"; then
      print_error "备份 $NGINX_CONF_DIR 失败，已停止，没有卸载"
      return 1
    fi
    print_ok "原来的配置已备份到 $backup"
  fi
  systemctl stop nginx >/dev/null 2>&1
  mapfile -t pkgs < <(dpkg-query -W -f='${Package} ${db:Status-Abbrev}\n' 'nginx*' 'libnginx-mod-*' 2>/dev/null | awk '$2 ~ /^ii/ {print $1}')
  DEBIAN_FRONTEND=noninteractive apt-get -y -qq purge "${pkgs[@]}" >/dev/null 2>&1
  print_ok "已卸载系统自带的 Nginx：${pkgs[*]}"
}

# 在官方包的 nginx.conf 上改：http { } 整块注释掉（不开 80，不提供任何网页），
# error_log 改成不记录，最后加上 stream，包含 stream.d 里的每条转发。
# user、pid 等保持原样，和官方包自带的 systemd 服务对得上
write_nginx_conf() {
  local tmp
  if [[ ! -f $NGINX_CONF ]]; then
    print_error "找不到 $NGINX_CONF"
    return 1
  fi
  [[ -f $NGINX_CONF.nginx-next.bak ]] || cp "$NGINX_CONF" "$NGINX_CONF.nginx-next.bak"
  tmp=$(mktemp)
  # 只用 [ \t]，不用 [[:space:]]：Debian 10 自带的 mawk 1.3.3 不认字符类
  awk '
    # 空行先攒着，后面有内容才输出，文件末尾的空行就丢掉了（重复运行不会越加越多）
    function out(s) {
      if (s ~ /^[ \t]*$/) { blanks++; return }
      while (blanks > 0) { print ""; blanks-- }
      print s
    }
    # 上次加的 stream 块先删掉，下面重新加
    /^# BEGIN nginx-next$/ { skip = 1 }
    skip { if (/^# END nginx-next$/) skip = 0; next }
    # http { ... } 整块注释掉，按花括号配对找到结尾
    depth == 0 && /^[ \t]*http[ \t]*\{/ { inhttp = 1 }
    inhttp {
      line = $0
      depth += gsub(/\{/, "", line)
      depth -= gsub(/\}/, "", line)
      out("#" $0)
      if (depth == 0) inhttp = 0
      next
    }
    /^[ \t]*error_log[ \t]/ { out("error_log  /dev/null crit;"); next }
    { out($0) }
  ' "$NGINX_CONF" >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  if ! grep -q '^error_log' "$tmp"; then
    sed -i '1i error_log  /dev/null crit;' "$tmp"
  fi
  if [[ -s $tmp && -n $(tail -c1 "$tmp") ]]; then
    echo >>"$tmp"
  fi
  cat >>"$tmp" <<EOF

# BEGIN nginx-next
# 只做端口转发：上面的 http 已整个注释掉，不开 80，也不提供任何网页。
# 每条转发一个文件，放在 $STREAM_DIR/ 里，用脚本菜单添加或删除。
stream {
    include $STREAM_DIR/*.conf;
}
# END nginx-next
EOF
  mv -f "$tmp" "$NGINX_CONF"
  chmod 644 "$NGINX_CONF"
}

# ─── 转发规则 ───
# 已有规则的本机端口，按数字排序
rule_ports() {
  find "$STREAM_DIR" -maxdepth 1 -name '[0-9]*.conf' -printf '%f\n' 2>/dev/null | sed 's/\.conf$//' | sort -n
}

# 规则文件里的后端，比如 1.2.3.4:443；后端是域名时取 set $backend 那一行
rule_target() {
  local target
  target=$(sed -n 's/^[[:space:]]*proxy_pass[[:space:]]\+\([^;]*\);.*/\1/p' "$1" | head -n1)
  # shellcheck disable=SC2016 # $backend 是 Nginx 变量名，按原样匹配
  if [[ $target == '$backend' ]]; then
    # shellcheck disable=SC2016
    target=$(sed -n 's/^[[:space:]]*set[[:space:]]\+\$backend[[:space:]]\+\([^;]*\);.*/\1/p' "$1" | head -n1)
  fi
  echo "$target"
}

# 列出所有转发规则，没有时返回失败；RULE_PORTS 里是对应序号的端口
list_rules() {
  local port i=0
  mapfile -t RULE_PORTS < <(rule_ports)
  if [[ ${#RULE_PORTS[@]} -eq 0 ]]; then
    print_warn "还没有转发规则，选「3. 添加转发」添加"
    return 1
  fi
  echo
  echo "序号  本机端口     后端"
  for port in "${RULE_PORTS[@]}"; do
    i=$((i + 1))
    printf '%-4d  %-8d  →  %s\n' "$i" "$port" "$(rule_target "$STREAM_DIR/$port.conf")"
  done
  echo
}

# 旧版本加的规则补上 UDP reuseport（多核时同一个客户端的 UDP 包交给同一个进程）和连接后端超时 10 秒。
# 有改动时 RULES_UPGRADED=1，重新加载 Nginx 就生效
upgrade_rule_files() {
  local f n=0
  RULES_UPGRADED=0
  for f in "$STREAM_DIR"/[0-9]*.conf; do
    [[ -f $f ]] || continue
    grep -qE '^[[:space:]]*listen[[:space:]]+[0-9]+[[:space:]]+udp;' "$f" || continue
    sed -i -E 's/^([[:space:]]*listen[[:space:]]+[0-9]+[[:space:]]+udp);/\1 reuseport;/' "$f"
    if ! grep -q 'proxy_connect_timeout' "$f"; then
      sed -i -E '/^[[:space:]]*listen[[:space:]]+[0-9]+[[:space:]]+udp reuseport;/a\    proxy_connect_timeout 10s;' "$f"
    fi
    n=$((n + 1))
  done
  if ((n > 0)); then
    RULES_UPGRADED=1
    print_ok "已更新 $n 条旧规则：UDP 加上 reuseport，连接后端超时 10 秒"
  fi
}

# ─── 3. 添加转发 ───
add_rule() {
  local file
  require_installed || return 1
  prepare_templates || return 1
  read_local_port
  read_target
  read_target_port
  file=$STREAM_DIR/$LOCAL_PORT.conf
  if [[ $TARGET_IS_DOMAIN -eq 1 ]]; then
    render_template nginx/stream-rule-domain.conf "$file" PORT="$LOCAL_PORT" TARGET="$TARGET" TARGET_PORT="$TARGET_PORT" RESOLVERS="$RESOLVERS" || return 1
  else
    render_template nginx/stream-rule.conf "$file" PORT="$LOCAL_PORT" TARGET="$TARGET" TARGET_PORT="$TARGET_PORT" || return 1
  fi
  # 配置检查不通过就删掉这条，恢复原样
  if ! check_nginx_config; then
    rm -f "$file"
    print_warn "已删掉这条规则，配置恢复原样"
    return 1
  fi
  reload_nginx || return 1
  if ! grep -qw "$LOCAL_PORT" <<<"$(nginx_listen_ports)"; then
    print_error "Nginx 没有监听端口 $LOCAL_PORT，可能刚被别的程序占用了"
    return 1
  fi
  print_ok "已添加转发：本机 $LOCAL_PORT → $TARGET:$TARGET_PORT（TCP + UDP）"
  if [[ $TARGET_IS_DOMAIN -eq 1 ]]; then
    print_info "后端是域名，Nginx 每 60 秒重新解析一次（DNS：${RESOLVERS// /、}）"
  fi
}

# ─── 4. 删除转发 ───
del_rule() {
  local input port target file tmp
  require_installed || return 1
  list_rules || return 1
  read -rp "请输入要删除的序号：" input
  input=$(echo "$input" | tr -d '[:space:]')
  if [[ ! $input =~ ^[0-9]{1,5}$ ]] || ((10#$input < 1 || 10#$input > ${#RULE_PORTS[@]})); then
    print_error "请输入正确的序号"
    return 1
  fi
  port=${RULE_PORTS[$((10#$input - 1))]}
  file=$STREAM_DIR/$port.conf
  target=$(rule_target "$file")
  # 先挪走再检查，检查不通过就放回去
  tmp=$(mktemp)
  mv -f "$file" "$tmp"
  if ! check_nginx_config; then
    mv -f "$tmp" "$file"
    print_warn "这条规则没有删除，配置恢复原样"
    return 1
  fi
  rm -f "$tmp"
  reload_nginx || return 1
  print_ok "已删除转发：本机 $port → $target"
}

# ─── 5. 查看转发 ───
show_rules() {
  require_installed || return 1
  list_rules
}

# ─── 1. 安装 Nginx ───
install_nginx() {
  prepare_templates || exit 1
  install_deps
  disable_firewall
  configure_chrony || exit 1

  add_nginx_source || exit 1
  nginx_support_note
  remove_distro_nginx || exit 1
  print_info "安装 Nginx（nginx.org 稳定版）"
  apt_update || exit 1
  apt_install nginx
  judge "安装 Nginx"

  systemctl stop nginx >/dev/null 2>&1
  mkdir -p "$STREAM_DIR"
  write_nginx_conf || exit 1
  upgrade_rule_files
  check_nginx_config || exit 1
  # 不记日志，原来的日志也删掉
  rm -f /var/log/nginx/*.log
  reload_nginx || exit 1
  check_listen

  print_ok "安装完成：Nginx $(nginx_version)"
  if [[ -z $(rule_ports) ]]; then
    echo "现在还没有转发规则，选「3. 添加转发」添加"
  fi
  echo
}

# ─── 6. 服务状态 ───
service_state() {
  if systemctl is-active --quiet "$1"; then
    echo -e "${Green}运行中${Font}"
  elif systemctl list-unit-files "$1.service" >/dev/null 2>&1 && [[ -f /etc/systemd/system/$1.service || -f /lib/systemd/system/$1.service ]]; then
    echo -e "${Red}未运行${Font}"
  else
    echo -e "${Yellow}未安装${Font}"
  fi
}

# 当前的 TCP 拥塞控制算法，并说明 BBR 有没有开
congestion_state() {
  local cc
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  case "$cc" in
    "") echo -e "${Yellow}未知${Font}" ;;
    bbr*) echo -e "${cc}  ${Green}已开启${Font}" ;;
    *) echo -e "${cc}  ${Yellow}未开启${Font}" ;;
  esac
}

show_status() {
  local count ports
  count=$(rule_ports | wc -l)
  ports=$(nginx_listen_ports)
  ports=${ports% }
  echo
  echo -e "Nginx：$(service_state nginx)  $(nginx_version)"
  echo -e "转发规则：${count} 条"
  echo -e "监听端口：${ports:-无}"
  echo -e "时间同步：$(service_state chrony)  $(time_sync_state)"
  echo -e "当前时间：$(now_time)"
  echo -e "Linux 内核：$(uname -r)"
  echo -e "拥塞控制：$(congestion_state)"
  echo
}

# ─── 7. 更新 Nginx ───
update_nginx() {
  local old new installed candidate
  require_installed || return 1
  upgrade_rule_files
  if [[ $RULES_UPGRADED -eq 1 ]]; then
    reload_nginx || return 1
  fi
  if [[ ! -f $NGINX_APT_LIST ]]; then
    add_nginx_source || return 1
  fi
  print_info "检查 Nginx 新版本"
  apt_update || return 1
  nginx_support_note
  installed=$(apt-cache policy nginx 2>/dev/null | awk '/Installed:/ {print $2}')
  candidate=$(apt-cache policy nginx 2>/dev/null | awk '/Candidate:/ {print $2}')
  old=$(nginx_version)
  if [[ -z $candidate || $candidate == "(none)" ]]; then
    print_error "软件源里找不到 nginx"
    return 1
  fi
  if [[ $installed == "$candidate" ]]; then
    print_ok "Nginx 已是最新版 $old"
    return 0
  fi
  print_info "更新 Nginx $old → ${candidate%%-*}"
  # 保留改过的 nginx.conf，不让 http 和 80 端口被恢复
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 -y -qq \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    install --only-upgrade nginx >/dev/null
  judge "更新 Nginx"
  reload_nginx || return 1
  new=$(nginx_version)
  print_ok "Nginx 已从 $old 更新到 $new"
  check_listen
}

# ─── 8. 更新 Linux 内核 ───
# 已安装的具体版本内核包里，除了新内核和正在运行的内核，其余都删掉
kernel_packages_to_remove() {
  local new_ver=$1 running=$2 pkg ver
  dpkg-query -W -f='${binary:Package} ${db:Status-Abbrev}\n' 'linux-image-[0-9]*' 2>/dev/null |
    awk '$2 ~ /^ii/ {print $1}' |
    while read -r pkg; do
      ver=${pkg#linux-image-}
      [[ $ver == "$new_ver" || $ver == "$running" ]] && continue
      echo "$pkg"
      if dpkg-query -W -f='${db:Status-Abbrev}' "linux-headers-$ver" 2>/dev/null | grep -q '^ii'; then
        echo "linux-headers-$ver"
      fi
    done
}

backports_enabled() {
  grep -rhs -- "${OS_CODENAME}-backports" "$APT_SOURCES_LIST" "$APT_SOURCES_DIR" |
    grep -qv '^[[:space:]]*#'
}

update_kernel() {
  local choice flavor meta other_meta new_pkg new_ver running yn
  local -a remove
  if [[ $OS_ID != debian ]]; then
    print_error "更新 Linux 内核仅支持 Debian"
    return 1
  fi
  echo "1. 安装最新完整内核"
  echo "2. 安装最新云内核"
  read -rp "请选择 [1]：" choice
  case "${choice:-1}" in
    1)
      flavor=$ARCH
      other_meta=linux-image-cloud-$ARCH
      ;;
    2)
      flavor=cloud-$ARCH
      other_meta=linux-image-$ARCH
      ;;
    *)
      print_error "请输入正确的数字"
      return 1
      ;;
  esac
  meta=linux-image-$flavor

  use_archive_sources || return 1
  if ! backports_enabled; then
    echo "deb https://deb.debian.org/debian ${OS_CODENAME}-backports main" >"$APT_SOURCES_DIR/backports.list"
    print_ok "已添加 ${OS_CODENAME}-backports 源"
  fi
  print_info "安装 $meta（${OS_CODENAME}-backports）"
  apt_update || return 1
  DEBIAN_FRONTEND=noninteractive apt-get -y -t "${OS_CODENAME}-backports" install "$meta"
  judge "安装内核"

  # 先确认新内核真的装好了，才删旧内核
  new_pkg=$(dpkg-query -W -f='${Depends}' "$meta" 2>/dev/null | grep -oE 'linux-image-[0-9][^ ,|]*' | head -n1)
  new_ver=${new_pkg#linux-image-}
  if [[ -z $new_ver || ! -f /boot/vmlinuz-$new_ver || ! -f /boot/initrd.img-$new_ver ]]; then
    print_error "没有找到新内核文件，已停止，不会删除任何内核"
    return 1
  fi

  running=$(uname -r)
  mapfile -t remove < <(kernel_packages_to_remove "$new_ver" "$running")
  if dpkg-query -W -f='${db:Status-Abbrev}' "$other_meta" 2>/dev/null | grep -q '^ii'; then
    remove+=("$other_meta")
  fi
  if [[ ${#remove[@]} -gt 0 ]]; then
    print_info "卸载旧内核：${remove[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get -y purge "${remove[@]}"
  fi
  if [[ ! -f /boot/vmlinuz-$new_ver ]]; then
    print_error "新内核文件不见了，千万别重启！"
    return 1
  fi
  command -v update-grub >/dev/null 2>&1 && update-grub >/dev/null 2>&1

  print_ok "新内核：$new_ver（当前运行：$running）"
  if [[ $running == "$new_ver" ]]; then
    print_ok "已经在使用最新内核"
    return 0
  fi
  print_warn "重启后才会使用新内核；重启后再运行一次「更新 Linux 内核」会清理现在这个旧内核"
  read -rp "是否现在重启？[Y/n]：" yn
  if [[ -z $yn || $yn == [Yy] ]]; then
    print_info "正在重启"
    reboot
  fi
}

# ─── 9. BBR ───
install_bbr() {
  local dir
  dir=$(mktemp -d)
  if ! wget -q --connect-timeout=5 --timeout=30 -O "$dir/tcp.sh" "$BBR_SCRIPT_URL"; then
    rm -rf "$dir"
    print_error "BBR 脚本下载失败：$BBR_SCRIPT_URL"
    return 1
  fi
  chmod +x "$dir/tcp.sh"
  (cd "$dir" && bash ./tcp.sh)
  rm -rf "$dir"
}

# ─── 2. 升级脚本 ───
# $1 比 $2 新时返回成功
version_gt() {
  [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1) == "$1" ]]
}

update_script() {
  local self tmp latest
  if [[ -d $SCRIPT_DIR/.git ]]; then
    print_warn "这是克隆下来的仓库，请在 $SCRIPT_DIR 里用 git pull 更新"
    return 0
  fi
  self=$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")
  if [[ ! -f $self ]]; then
    print_error "找不到脚本文件，请重新下载：wget -N $REPO_RAW/install.sh"
    return 1
  fi
  print_info "检查最新版本"
  # 下载到同一目录再改名替换，正在运行的脚本不受影响
  tmp=$(mktemp "$SCRIPT_DIR/.install.sh.XXXXXX") || return 1
  if ! wget -q --timeout=15 --tries=2 -O "$tmp" "$REPO_RAW/install.sh"; then
    rm -f "$tmp"
    print_error "下载失败，请检查网络"
    return 1
  fi
  latest=$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$tmp" | head -n1)
  if [[ -z $latest ]] || ! bash -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    print_error "下载的脚本不完整，请稍后再试"
    return 1
  fi
  if ! version_gt "$latest" "$SCRIPT_VERSION"; then
    rm -f "$tmp"
    print_ok "已是最新版本 $SCRIPT_VERSION"
    return 0
  fi
  chmod 755 "$tmp"
  mv -f "$tmp" "$self"
  print_ok "已从 $SCRIPT_VERSION 升级到 $latest"
  sleep 1
  exec bash "$self"
}

# ─── 菜单 ───
menu() {
  is_root
  detect_system

  # 标题缩进 3 格
  echo -e "   Nginx 端口转发一键脚本 ${Red}[${SCRIPT_VERSION}]${Font}"
  echo -e "   https://github.com/1432433gg/nginx-next"
  echo
  echo -e "—————— 安装 ——————"
  echo -e "${Green}1.${Font}  安装 Nginx"
  echo -e "${Green}2.${Font}  升级 脚本"
  echo -e "—————— 转发规则 ——————"
  echo -e "${Green}3.${Font}  添加转发"
  echo -e "${Green}4.${Font}  删除转发"
  echo -e "${Green}5.${Font}  查看转发"
  echo -e "—————— 查看信息 ——————"
  echo -e "${Green}6.${Font}  查看服务运行状态"
  echo -e "—————— 其他 ——————"
  echo -e "${Green}7.${Font}  更新 Nginx"
  if [[ $OS_ID == debian ]]; then
    echo -e "${Green}8.${Font}  更新 Linux 内核"
  else
    echo -e "${Green}8.${Font}  更新 Linux 内核（仅 Debian）"
  fi
  echo -e "${Green}9.${Font}  安装 BBR 加速"
  echo -e "${Green}0.${Font}  退出"
  read -rp "请输入数字：" menu_num
  case "$menu_num" in
    1) install_nginx ;;
    2) update_script ;;
    3) add_rule ;;
    4) del_rule ;;
    5) show_rules ;;
    6) show_status ;;
    7) update_nginx ;;
    8) update_kernel ;;
    9) install_bbr ;;
    0) exit 0 ;;
    *) print_error "请输入正确的数字" ;;
  esac
}

# 被 source 时（测试用）不执行菜单
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  menu "$@"
fi
