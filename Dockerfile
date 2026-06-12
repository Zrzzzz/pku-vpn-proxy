FROM alpine AS builder
WORKDIR /root
RUN apk add --no-cache git libevent-dev linux-headers autoconf automake build-base make bash \
  && git clone https://github.com/cernekee/ocproxy.git \
  && cd ocproxy \
  && ./autogen.sh \
  && ./configure \
  && make

FROM alpine
LABEL maintainer="Zrzzzz"
LABEL description="PKU VPN SOCKS5 proxy via openconnect + ocproxy (fixed auth prompts)"
RUN apk add --no-cache libevent bash openconnect expect curl
COPY --from=builder /root/ocproxy/ocproxy /usr/local/bin/
COPY entrypoint.sh /entrypoint.sh
COPY keep-alive.sh /keep-alive.sh
COPY connect.sh /connect.sh
RUN chmod +x /entrypoint.sh /keep-alive.sh
STOPSIGNAL SIGTERM
# 健康检查：通过 SOCKS5 真实探测代理是否可用（仅用于 docker ps 的健康状态展示；
# 自愈靠 entrypoint 的看门狗 + --restart=always）
HEALTHCHECK --interval=60s --timeout=15s --start-period=40s --retries=3 \
  CMD curl --socks5-hostname 127.0.0.1:1080 --connect-timeout 10 -sf -o /dev/null "${HEALTHCHECK_URL:-https://its.pku.edu.cn/}" || exit 1
CMD ["/entrypoint.sh"]
