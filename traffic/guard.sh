#!/usr/bin/env bash
# nginx-next 月度出站流量账本；所有读写经 flock 串行化，不执行账本内容。

TG_DIR=${NGINX_NEXT_TRAFFIC_DIR:-/var/lib/nginx-next/traffic}
TG_NET_ROOT=${NGINX_NEXT_SYS_NET:-/sys/class/net}
TG_BOOT_FILE=${NGINX_NEXT_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}
TG_NGINX=${NGINX_NEXT_NGINX_BIN:-/usr/sbin/nginx}
TG_SELF=$(readlink -f "${BASH_SOURCE[0]}")
TG_STATE=$TG_DIR/state

tg_error() { printf '流量统计：%s\n' "$*" >&2; }
tg_uint() { [[ $1 =~ ^(0|[1-9][0-9]{0,17})$ ]]; }

tg_lock() {
  [[ -d $TG_DIR ]] || { tg_error "找不到流量设置"; return 1; }
  exec {TG_LOCK_FD}>"$TG_DIR/lock" || return 1
  flock -x "$TG_LOCK_FD"
}

tg_unlock() { exec {TG_LOCK_FD}>&-; }

# 启停动作也串行化，防止旧的超额检查在手动重置后才执行停止。
# 启动前检查只取账本锁，不取动作锁，避免 systemctl start 的嵌套死锁。
tg_action_lock() {
  [[ -d $TG_DIR ]] || { tg_error "找不到流量设置"; return 1; }
  exec {TG_ACTION_FD}>"$TG_DIR/action.lock" || return 1
  flock -x "$TG_ACTION_FD"
}

tg_load() {
  local key value seen=' ' count=0
  TG_VERSION= TG_MONTH= TG_IFACE= TG_LIMIT= TG_USED= TG_LAST= TG_BOOT= TG_BLOCKED= TG_RESUME=
  [[ -f $TG_STATE ]] || { tg_error "找不到流量账本"; return 1; }
  while IFS='=' read -r key value; do
    [[ $seen != *" $key "* ]] || { tg_error "流量账本重复"; return 1; }
    seen+="$key "
    count=$((count + 1))
    case "$key" in
      version) TG_VERSION=$value ;;
      month) TG_MONTH=$value ;;
      interface) TG_IFACE=$value ;;
      limit) TG_LIMIT=$value ;;
      used) TG_USED=$value ;;
      last_tx) TG_LAST=$value ;;
      boot_id) TG_BOOT=$value ;;
      blocked) TG_BLOCKED=$value ;;
      resume) TG_RESUME=$value ;;
      *) tg_error "流量账本格式错误"; return 1 ;;
    esac
  done <"$TG_STATE"
  if [[ $count != 9 || $TG_VERSION != 1 || ! $TG_MONTH =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ||
        ! $TG_IFACE =~ ^[a-zA-Z0-9_.:-]{1,15}$ || $TG_IFACE == lo ||
        ! $TG_BOOT =~ ^[a-fA-F0-9-]{36}$ || ! $TG_BLOCKED =~ ^[01]$ || ! $TG_RESUME =~ ^[01]$ ]] ||
     ! tg_uint "$TG_LIMIT" || ((TG_LIMIT == 0)) ||
     ! tg_uint "$TG_USED" || ! tg_uint "$TG_LAST"; then
    tg_error "流量账本损坏，请检查 $TG_STATE"
    return 1
  fi
}

tg_save() {
  local tmp
  tmp=$(mktemp "$TG_DIR/.state.XXXXXX") || return 1
  if ! printf 'version=1\nmonth=%s\ninterface=%s\nlimit=%s\nused=%s\nlast_tx=%s\nboot_id=%s\nblocked=%s\nresume=%s\n' \
    "$TG_MONTH" "$TG_IFACE" "$TG_LIMIT" "$TG_USED" "$TG_LAST" "$TG_BOOT" "$TG_BLOCKED" "$TG_RESUME" >"$tmp" ||
    ! chmod 600 "$tmp" || ! mv -f "$tmp" "$TG_STATE"; then
    rm -f "$tmp"
    tg_error "保存流量账本失败"
    return 1
  fi
}

tg_counters() {
  TG_NOW_MONTH=$(TZ=Asia/Shanghai date +%Y-%m) || return 1
  [[ $TG_NOW_MONTH =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]] || return 1
  if ! IFS= read -r TG_NOW_BOOT <"$TG_BOOT_FILE" ||
     [[ ! $TG_NOW_BOOT =~ ^[a-fA-F0-9-]{36}$ ]]; then
    tg_error "无法读取系统启动标识"
    return 1
  fi
  if ! IFS= read -r TG_NOW_TX <"$TG_NET_ROOT/$TG_IFACE/statistics/tx_bytes" || ! tg_uint "$TG_NOW_TX"; then
    tg_error "无法读取网卡 $TG_IFACE"
    return 1
  fi
}

tg_sample() {
  local delta
  tg_counters || return 1
  # 只在月份向前变化时清零，时间校准回拨不会重复发放额度。
  if [[ $TG_NOW_MONTH > $TG_MONTH ]]; then
    TG_MONTH=$TG_NOW_MONTH
    TG_USED=0
  else
    if [[ $TG_BOOT != "$TG_NOW_BOOT" ]] || ((TG_NOW_TX < TG_LAST)); then
      delta=$TG_NOW_TX
    else
      delta=$((TG_NOW_TX - TG_LAST))
    fi
    TG_USED=$((TG_USED + delta))
    tg_uint "$TG_USED" || { tg_error "流量计数超出范围"; return 1; }
  fi
  TG_LAST=$TG_NOW_TX
  TG_BOOT=$TG_NOW_BOOT
}

tg_stop() {
  systemctl stop nginx || { tg_error "停止 Nginx 失败"; return 1; }
}

# 账本异常时停止转发，但不清零或覆盖原账本。下次采样仍会重试。
tg_fail_closed() {
  systemctl stop nginx >/dev/null 2>&1 || true
  return 1
}

tg_mark_quota() {
  if ((TG_USED >= TG_LIMIT)); then
    TG_BLOCKED=1
    TG_RESUME=1
    TG_ACTION=stop
  else
    TG_BLOCKED=0
    TG_ACTION=none
    [[ $TG_RESUME == 1 ]] && TG_ACTION=start
  fi
  return 0
}

tg_apply_action() {
  case "$TG_ACTION" in
    stop) tg_stop ;;
    start)
      # 已释放账本锁，ExecStartPre 可以再次加锁，避免启动时互相等待。
      "$TG_NGINX" -t >/dev/null 2>&1 || { tg_error "Nginx 配置检查失败"; return 1; }
      systemctl reset-failed nginx >/dev/null 2>&1 || true
      systemctl start nginx || { tg_error "恢复 Nginx 失败"; return 1; }
      tg_lock || return 1
      if ! tg_load || ! tg_sample; then
        tg_unlock
        tg_fail_closed
        return 1
      fi
      if ((TG_USED < TG_LIMIT)); then
        TG_BLOCKED=0
        TG_RESUME=0
        tg_save || { tg_unlock; tg_fail_closed; return 1; }
        tg_unlock
      else
        TG_BLOCKED=1
        TG_RESUME=1
        tg_save || { tg_unlock; tg_fail_closed; return 1; }
        tg_unlock
        tg_stop
      fi
      ;;
  esac
}

tg_tick() {
  local mode=${1:-tick}
  tg_lock || { [[ $mode != tick ]] || tg_fail_closed; return 1; }
  if ! tg_load || ! tg_sample; then
    tg_unlock
    [[ $mode != tick ]] || tg_fail_closed
    return 1
  fi
  tg_mark_quota
  if ! tg_save; then
    tg_unlock
    [[ $mode != tick ]] || tg_fail_closed
    return 1
  fi
  tg_unlock
  # 启动前检查不能反过来启动/停止正在启动的同一个 systemd 单元。
  if [[ $mode == check-start ]]; then
    [[ $TG_BLOCKED == 0 ]]
  elif [[ $mode != flush ]]; then
    tg_apply_action
  fi
}

tg_init() {
  local interface=${1:-} limit=${2:-} used=${3:-}
  [[ $interface =~ ^[a-zA-Z0-9_.:-]{1,15}$ && $interface != lo ]] || return 1
  tg_uint "$limit" && ((limit > 0)) && tg_uint "$used" || return 1
  mkdir -p -m 700 "$TG_DIR" || return 1
  tg_action_lock || return 1
  tg_lock || return 1
  [[ ! -e $TG_STATE ]] || { tg_error "流量统计已设置"; tg_unlock; return 1; }
  TG_IFACE=$interface TG_LIMIT=$limit TG_USED=$used TG_BLOCKED=0 TG_RESUME=0
  tg_counters || { tg_unlock; return 1; }
  TG_MONTH=$TG_NOW_MONTH TG_BOOT=$TG_NOW_BOOT TG_LAST=$TG_NOW_TX
  tg_mark_quota
  tg_save || { tg_unlock; return 1; }
  tg_unlock
}

tg_set() {
  local key=$1 value=$2
  tg_uint "$value" || return 1
  [[ $key != limit ]] || ((value > 0)) || return 1
  tg_lock || return 1
  if ! tg_load || ! tg_sample; then
    tg_unlock
    tg_fail_closed
    return 1
  fi
  case "$key" in
    limit) TG_LIMIT=$value ;;
    used) TG_USED=$value ;;
    *) tg_unlock; return 1 ;;
  esac
  tg_mark_quota
  tg_save || { tg_unlock; tg_fail_closed; return 1; }
  tg_unlock
  tg_apply_action
}

tg_status() {
  tg_tick || true
  tg_lock || return 1
  tg_load || { tg_unlock; return 1; }
  printf 'used=%s\nlimit=%s\nblocked=%s\n' "$TG_USED" "$TG_LIMIT" "$TG_BLOCKED"
  tg_unlock
}

tg_main() {
  umask 077
  case "${1:-}" in
    tick | reset | set-limit | set-used | status)
      tg_action_lock || { tg_fail_closed; return 1; }
      ;;
  esac
  case "${1:-}" in
    init) [[ $# == 4 ]] && tg_init "$2" "$3" "$4" ;;
    tick | check-start | flush) [[ $# == 1 ]] && tg_tick "$1" ;;
    reset) [[ $# == 1 ]] && tg_set used 0 ;;
    set-limit) [[ $# == 2 ]] && tg_set limit "$2" ;;
    set-used) [[ $# == 2 ]] && tg_set used "$2" ;;
    status) [[ $# == 1 ]] && tg_status ;;
    daemon)
      [[ $# == 1 ]] || return 1
      trap 'exit 0' TERM INT
      while true; do
        "$TG_SELF" tick || tg_error "本次检查失败，10秒后重试"
        sleep 10 &
        wait $! || true
      done
      ;;
    *) tg_error "无效操作"; return 1 ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  tg_main "$@"
fi
