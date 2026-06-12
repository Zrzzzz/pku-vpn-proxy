#!/bin/bash

# 定义信号处理函数：收到 SIGTERM 时优雅关闭 openconnect
function terminate_openconnect {
  echo "Terminating openconnect..."
  killall openconnect
  exit 0
}

# 捕捉 SIGTERM 信号
trap 'terminate_openconnect' SIGTERM

expect /connect.sh &

while true; do
  wait $!
done
