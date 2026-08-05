FROM alpine
LABEL maintainer="Zrzzzz"
LABEL description="PKU VPN SOCKS5 proxy via openconnect (kernel tun) + gost"

# iproute2: pku-route.sh 需要 ip route/addr（busybox 的 ip 功能不全）
# gost:     提供 SOCKS5，取代原先由 ocproxy 兼任的角色
RUN apk add --no-cache bash openconnect expect curl iproute2 gost

COPY entrypoint.sh /entrypoint.sh
COPY keep-alive.sh /keep-alive.sh
COPY connect.sh /connect.sh
COPY pku-route.sh /pku-route.sh
COPY gost.yml /gost.yml
RUN chmod +x /entrypoint.sh /keep-alive.sh /pku-route.sh

STOPSIGNAL SIGTERM
# 健康检查：通过 SOCKS5 真实探测代理是否可用（仅用于 docker ps 的健康状态展示；
# 自愈靠 entrypoint 的看门狗 + --restart=always）
HEALTHCHECK --interval=60s --timeout=15s --start-period=40s --retries=3 \
  CMD curl --socks5-hostname 127.0.0.1:1080 --connect-timeout 10 -sf -o /dev/null "${HEALTHCHECK_URL:-https://its.pku.edu.cn/}" || exit 1
CMD ["/entrypoint.sh"]

# 注意：必须用 --device /dev/net/tun --cap-add NET_ADMIN 运行，否则建不了 tun 网卡。
