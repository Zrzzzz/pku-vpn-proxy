#!/usr/bin/expect -f

# 设置超时时间（-1 表示不超时）
set timeout -1

# 获取环境变量
set user $env(USER)
set pass $env(PASS)
set url $env(URL)
set id_card $env(ID_CARD)
set phone_number $env(PHONE_NUMBER)
set oc_args $env(OC_ARGS)

# 检查必要的环境变量
if {$user == "" || $pass == ""} {
  puts "Must provide USER and PASS env"
  exit 1
}
if {$url == ""} {
  puts "Must provide URL env"
  exit 1
}

# 开始连接。
# 走真实 tun 网卡 + 内核 TCP 栈；SOCKS5 由 entrypoint 里的 gost 单独提供。
# 早先用的是 --script-tun + ocproxy（lwIP 用户态栈），单条连接实测只有 ~28 KB/s
# （等效窗口约 1 个 MSS），而链路总带宽 ≥230 KB/s —— 瓶颈全在用户态栈上。
#
# --no-dtls：不建 ESP（UDP）数据通道，数据全走 TLS。走 ESP 时实测两种必现的假死：
#   1) TLS 控制通道因空闲在建连后 5/10 分钟被服务端断开（Read error on TLS session），
#      openconnect 重建 TLS 后 ESP 不再恢复；
#   2) 约 20 分钟后 ESP detected dead peer，同样不再恢复。
spawn openconnect $oc_args --no-dtls --script /pku-route.sh --user $user $url

# 期待密码提示
expect "Password:"
send "$pass\r"

# 处理北大 VPN 的多因素认证 / 额外凭据提示。
#
# 注意：这里改用「子串匹配」而非匹配完整的提示语句。
# 北大 VPN 服务端的提示文案近期发生过变化，例如：
#   旧: 北大VPN提示您：此登录需额外补充凭据，请在下面 <验证信息> 或 <输入响应> 框内输入4位缺位电话号码
#   新: 补充额外凭据，4位缺位电话号码：[185****3258]
#   身份证提示也改过：「身份证后6位」→「补充凭据，身份证/护照后6位」
# 只要匹配稳定的关键子串（如「缺位电话号码」「后6位」），
# 即可同时兼容新旧文案，避免服务端再次改动文案时脚本卡死。
expect {
  "Please enter your passcode:" {
    send "$pass\r"
    exp_continue
  }
  "后6位" {
    send "$id_card\r"
    exp_continue
  }
  "缺位电话号码" {
    send "$phone_number\r"
    exp_continue
  }
  # 会话数超限：PKU VPN 只允许有限的并发会话。容器异常退出会在服务端
  # 残留僵尸会话，占满名额后服务端会要求选择一个会话杀掉，提示形如：
  #   Session limit reached. Choose session to kill:
  #    - ff73a645 from ...
  #   Session: [ff73a645|b9c9dccb]:
  # 这里自动杀掉列表里第一个（最旧的）会话以腾出名额。
  -re {Session: \[([0-9a-f]+)} {
    puts "\[INFO\] Session limit reached, killing oldest session: $expect_out(1,string)"
    send "$expect_out(1,string)\r"
    exp_continue
  }
  "Session terminated by server; exiting." {
    puts "\[ERROR\] Session terminated by server; exiting."
    exit 1
  }
  timeout {
    puts "\[ERROR\] Connection timed out"
    exit 1
  }
}

# 保持连接。openconnect 自己的断线重连从未成功过（重建 TLS 后隧道不再通），
# 与其等看门狗几分钟后发现，不如一看到断线就退出，交给容器重启重新登录。
set timeout -1
expect {
  -re {Read error on TLS session|Failed to reconnect} {
    puts "\[ERROR\] Tunnel dropped: $expect_out(0,string); exiting."
    exit 1
  }
  eof {
    exit 1
  }
}
