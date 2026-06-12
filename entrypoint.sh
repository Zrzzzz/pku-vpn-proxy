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
  killall openconnect 2>/dev/null
  exit 0
}
trap cleanup SIGTERM SIGINT

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

echo "[entrypoint] starting openconnect via connect.sh..."
expect /connect.sh &
child=$!

watchdog &
watchdog_pid=$!

# 等 connect.sh 退出（openconnect 死亡 / 被服务端踢 / 看门狗杀掉）
wait "${child}"
status=$?

kill "${watchdog_pid}" 2>/dev/null
echo "[entrypoint] connect.sh exited (status=${status}); exiting so the restart policy reconnects."
exit "${status}"
