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
RUN apk add --no-cache libevent bash openconnect expect
COPY --from=builder /root/ocproxy/ocproxy /usr/local/bin/
COPY entrypoint.sh /entrypoint.sh
COPY keep-alive.sh /keep-alive.sh
COPY connect.sh /connect.sh
RUN chmod +x /entrypoint.sh /keep-alive.sh
STOPSIGNAL SIGTERM
CMD ["/entrypoint.sh"]
