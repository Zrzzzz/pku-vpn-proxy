#!/bin/sh
# openconnect 的 --script 回调：配置真实 tun 网卡与分流路由。
#
# 为什么不用系统自带的 /etc/vpnc/vpnc-script：它会把默认路由整个接管，导致
#   1) 容器自身到 pacvpn 的拨号流量被路由进还没建好的隧道（死锁）；
#   2) 宿主机映射进来的 1080 入站连接回包走 tun，SOCKS5 直接不可用。
# 这里只添加 PKU 网段的明细路由，默认路由保持不动。
set -eu

# 与 Clash 侧的 🎓 北京大学 规则保持一致
PKU_NETS="162.105.0.0/16 115.27.0.0/16 222.29.0.0/16 211.68.0.0/16 211.69.0.0/16 10.129.0.0/16"
RESOLV_BACKUP=/etc/resolv.conf.orig

case "${reason:-}" in
  pre-init)
    ;;

  connect|reconnect)
    ip link set dev "$TUNDEV" up mtu "${INTERNAL_IP4_MTU:-1400}"
    ip addr add "$INTERNAL_IP4_ADDRESS/32" dev "$TUNDEV" 2>/dev/null || true

    # 到 VPN 网关必须走原始默认路由。222.29.0.0/16 覆盖了 pacvpn 自己的地址，
    # 若不加这条 /32 明细，拨号流量会被下面的网段路由吸进隧道 —— 容器内死锁。
    gw=$(ip route show default | awk '{print $3; exit}')
    dev=$(ip route show default | awk '{print $5; exit}')
    ip route replace "$VPNGATEWAY/32" via "$gw" dev "$dev"

    for net in $PKU_NETS; do
      ip route replace "$net" dev "$TUNDEV"
    done

    # DNS 走校内解析器，否则校内私有域名解析不出来。
    # 解析器地址本身也要有明细路由，否则查询发不进隧道。
    if [ -n "${INTERNAL_IP4_DNS:-}" ]; then
      for d in $INTERNAL_IP4_DNS; do
        ip route replace "$d/32" dev "$TUNDEV"
      done
      for d in $INTERNAL_IP4_DNS; do
        echo "nameserver $d"
      done > /etc/resolv.conf
    fi
    ;;

  disconnect)
    # 隧道断开后校内 DNS 不可达，必须换回容器原始解析器，
    # 否则下一轮重连连 pacvpn.pku.edu.cn 的域名都解析不了。
    #
    # 只能覆写内容，不能 cp/mv 整个文件：Docker 把 /etc/resolv.conf 作为
    # bind mount 挂进来，替换文件会报 "File exists"，在 set -e 下让本脚本
    # 返回 1，openconnect 收到脚本失败就会直接终止会话。
    if [ -f "$RESOLV_BACKUP" ]; then
      cat "$RESOLV_BACKUP" > /etc/resolv.conf
    fi
    ;;
esac

exit 0
