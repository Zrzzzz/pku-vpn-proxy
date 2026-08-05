#!/bin/bash
# 进程模型（修复 restart=always 不生效的问题）：
#   - openconnect/connect.sh 一旦退出（会话超时、被服务端踢、断网等），
#     本脚本就退出，让容器退出 → docker 的 --restart=always 自动重连。
#   - 额外跑一个看门狗：定时通过 SOCKS5 真实探测代理是否还能通；
#     若连续失败 N 次（隧道"连着但不通"的假死状态），主动杀掉 openconnect
#     触发上面的退出→重启链路。
set -u

TARGET_URL="${HEALTHCHECK_URL:-https://its.pku.edu.cn/}"
CHECK_INTERVAL="${HEALTHCHECK_INTERVAL:-60}"
MAX_FAILS="${HEALTHCHECK_MAX_FAILS:-3}"
START_DELAY="${HEALTHCHECK_START_DELAY:-30}"

cleanup() {
  echo "[entrypoint] caught signal, terminating..."
  [ -n "${watchdog_pid:-}" ] && kill "${watchdog_pid}" 2>/dev/null
  [ -n "${gost_pid:-}" ] && kill "${gost_pid}" 2>/dev/null
  killall openconnect 2>/dev/null
  exit 0
}
trap cleanup SIGTERM SIGINT

# 备份容器原始 resolv.conf，并在每次启动时恢复。
# 隧道建立后 pku-route.sh 会把 DNS 换成校内解析器；若上一轮进程是被 kill -9
# 打断的，disconnect 回调不会执行，resolv.conf 会残留着隧道已断的校内 DNS，
# 导致本轮连 pacvpn.pku.edu.cn 时域名解析不出来而永远重连失败。
# 恢复用 cat 覆写而非 cp：/etc/resolv.conf 是 Docker 的 bind mount，替换文件会失败。
if [ ! -f /etc/resolv.conf.orig ]; then
  cp /etc/resolv.conf /etc/resolv.conf.orig
else
  cat /etc/resolv.conf.orig > /etc/resolv.conf
fi

# 看门狗：定时真实探测 SOCKS5 代理，连续失败则杀掉 openconnect 触发重连
watchdog() {
  local fails=0
  sleep "${START_DELAY}"   # 先给隧道建立的时间
  while true; do
    if curl --socks5-hostname 127.0.0.1:1080 --connect-timeout 10 -s -o /dev/null "${TARGET_URL}"; then
      fails=0
    else
      fails=$((fails + 1))
      echo "[watchdog] proxy check failed (${fails}/${MAX_FAILS}) -> ${TARGET_URL}"
      if [ "${fails}" -ge "${MAX_FAILS}" ]; then
        echo "[watchdog] proxy is dead, killing openconnect to trigger restart"
        killall openconnect 2>/dev/null
        return
      fi
    fi
    sleep "${CHECK_INTERVAL}"
  done
}

# SOCKS5 服务端。原先这个角色由 ocproxy 兼任（它同时是用户态 TCP 栈），
# 现在 tun 走内核栈，socks 单独由 gost 提供，出站走哪条路由由 pku-route.sh 决定。
echo "[entrypoint] starting gost socks5 on :1080..."
gost -C /gost.yml &
gost_pid=$!

echo "[entrypoint] starting openconnect via connect.sh..."
expect /connect.sh &
child=$!

watchdog &
watchdog_pid=$!

# 等 connect.sh 退出（openconnect 死亡 / 被服务端踢 / 看门狗杀掉）
wait "${child}"
status=$?

kill "${watchdog_pid}" 2>/dev/null
kill "${gost_pid}" 2>/dev/null
echo "[entrypoint] connect.sh exited (status=${status}); exiting so the restart policy reconnects."
exit "${status}"
