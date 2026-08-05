# pku-vpn-proxy

把北大 VPN（PKU VPN）变成一个本地 SOCKS5 代理端口，方便配合 Clash / Surge / PAC 做**校内流量分流**——只有访问校内资源（如 `*.pku.edu.cn`）的请求才走 VPN，其余流量直连，不影响日常上网速度。

底层基于 [openconnect](https://www.infradead.org/openconnect/)（真实 tun 网卡 + 内核 TCP 栈）+ [gost](https://github.com/go-gost/gost) 提供 SOCKS5 入口。容器内只给 PKU 网段装明细路由，**不接管默认路由、不影响宿主机全局网络**。

> Fork & fix of [thezzisu/ocproxy-oci](https://github.com/thezzisu/ocproxy-oci)。
> **修复点**：北大 VPN 服务端近期修改了多因素认证的提示文案，导致原镜像里 `connect.sh` 的 `expect` 匹配失败、登录时卡死。本仓库改用稳定子串匹配，兼容新旧两种文案。详见 [为什么需要这个 fork](#为什么需要这个-fork)。

## 快速开始

### 1. 准备配置文件 `pku.env`

复制 `.env.example` 并填入你自己的信息：

```sh
cp .env.example pku.env
```

```ini
USER=你的学号
PASS=你的IAAA密码
URL=pacvpn.pku.edu.cn
OC_ARGS=--protocol=pulse
ID_CARD=身份证后6位
PHONE_NUMBER=手机号第4到7位
```

| 变量           | 必填 | 说明                                                        |
| -------------- | ---- | ----------------------------------------------------------- |
| `USER`         | ✅   | VPN 用户名（学号）                                          |
| `PASS`         | ✅   | VPN 密码（IAAA 密码）                                       |
| `URL`          | ✅   | VPN 入口，推荐 `pacvpn.pku.edu.cn`（内网模式，限制更少）    |
| `OC_ARGS`      |      | 传给 openconnect 的额外参数，固定为 `--protocol=pulse`      |
| `ID_CARD`      | ✅   | 身份证后 6 位（认证可能用到）                               |
| `PHONE_NUMBER` | ✅   | 手机号第 4~7 位，例如 `13912345678` → `1234`                |

> `*.env` 已被 `.gitignore` 排除，不会被提交，放心填写。

### 2. 启动容器

```sh
docker run -d --restart=always --name pku-vpn \
  --env-file=pku.env -p 11080:1080 \
  --device /dev/net/tun --cap-add NET_ADMIN \
  ghcr.io/zrzzzz/pku-vpn-proxy:latest
```

> `--device /dev/net/tun --cap-add NET_ADMIN` 是必需的，缺了建不出 tun 网卡，容器会一直重连失败。

> macOS 上 `--env-file` 不会展开 `~`，如果用绝对路径请写 `$HOME/pku.env`，不要写 `~/pku.env`。

### 3. 验证

```sh
docker logs pku-vpn          # 看到 "ESP session established with server" 即连接成功
docker ps                    # STATUS 显示 (healthy) 即代理探测通过
# 验证代理：务必用 --socks5-hostname（让代理远端解析），不要用 --socks5
curl --socks5-hostname 127.0.0.1:11080 -I https://portal.pku.edu.cn   # 返回 HTTP 200 即可用
```

> ⚠️ 测试时用 `--socks5-hostname`（远端解析）而不是 `--socks5`（本地解析）：校内私有域名只有校内 DNS 能解析，容器连上后会把解析器切成校内的，交给代理远端解析才对。Clash/Surge 走 SOCKS5 对域名规则默认就是远端解析，不受影响。

成功后，`127.0.0.1:11080` 就是一个走北大内网的 **SOCKS5 代理**。

## 分流配置

拿到本地 SOCKS5 端口（`127.0.0.1:11080`）后，按你用的工具选一种分流方式。

### A. 系统 PAC（零依赖，不需要任何代理软件）

新建 `~/pku_proxy.pac`：

```js
function FindProxyForURL(url, host) {
  if (shExpMatch(host, "*.pku.edu.cn")) {
    return "SOCKS5 127.0.0.1:11080";
  }
  return "DIRECT";
}
```

然后到 **系统设置 → 网络 → Wi-Fi → 详细信息 → 代理 → 自动代理配置**，填入 `file:///Users/你的用户名/pku_proxy.pac`。

### B. Clash / Mihomo Party

```yaml
proxies:
  - name: PKU
    type: socks5
    server: 127.0.0.1
    port: 11080

proxy-groups:
  - name: 🎓 北京大学
    type: select
    proxies: [PKU, DIRECT]

rules:
  - DOMAIN-SUFFIX,pku.edu.cn,🎓 北京大学
  - IP-CIDR,162.105.0.0/16,🎓 北京大学
  - IP-CIDR,10.0.0.0/8,🎓 北京大学
```

> Mihomo Party 用户可在「覆写」里追加，key 前加 `+` 表示 prepend。

### C. Surge

```ini
[Proxy]
PKU = socks5, 127.0.0.1, 11080

[Proxy Group]
🎓 北京大学 = select, PKU, DIRECT

[Rule]
DOMAIN-SUFFIX,pku.edu.cn,🎓 北京大学
IP-CIDR,162.105.0.0/16,🎓 北京大学
```

## 常用运维

```sh
docker logs -f pku-vpn        # 查看实时日志
docker ps                     # 看 STATUS 的 (healthy)/(unhealthy)
docker restart pku-vpn        # 手动重连（正常情况下不需要）
docker rm -f pku-vpn          # 删除容器
```

### 自愈机制

PKU VPN 的会话约几小时后会**自然超时过期**（日志里是 `Pulse fatal error (reason: 8): session timed out`）。本镜像做了自愈，配合 `--restart=always` 全自动恢复，无需手动干预：

1. **进程退出即重连**：openconnect 一旦死亡（超时 / 被踢 / 断网），entrypoint 立即退出 → 容器退出 → `--restart=always` 自动拉起重连。
   （原镜像用 `while true; wait` 死循环保活，openconnect 死了容器还 Up 着、代理却不通——本仓库已修复。）
2. **看门狗探活**：内置看门狗每 60s 通过 SOCKS5 真实探测代理；连续失败 3 次（隧道"连着但不通"的假死）会主动杀掉 openconnect，触发上面的重连链路。
3. **HEALTHCHECK**：`docker ps` 的 STATUS 会显示 `(healthy)`/`(unhealthy)`，方便监控。

可调环境变量（写进 `pku.env` 或 `-e` 传入）：

| 变量 | 默认 | 说明 |
| ---- | ---- | ---- |
| `HEALTHCHECK_URL` | `https://its.pku.edu.cn/` | 看门狗 / 健康检查探测的目标 |
| `HEALTHCHECK_INTERVAL` | `60` | 看门狗探测间隔（秒） |
| `HEALTHCHECK_MAX_FAILS` | `3` | 连续失败多少次触发重连 |
| `HEALTHCHECK_START_DELAY` | `30` | 启动后多久开始探测（秒，留给隧道建立） |

## 本地构建

不想用预构建镜像，可以自己 build：

```sh
docker build -t pku-vpn-proxy .
docker run -d --restart=always --name pku-vpn \
  --env-file=pku.env -p 11080:1080 \
  --device /dev/net/tun --cap-add NET_ADMIN \
  pku-vpn-proxy
```

## 为什么需要这个 fork

原镜像 `connect.sh` 用 `expect` 自动应答北大 VPN 的交互式认证，硬编码了完整的中文提示语，例如：

```
北大VPN提示您：此登录需额外补充凭据，请在下面 <验证信息> 或 <输入响应> 框内输入4位缺位电话号码
```

但服务端现在的提示文案已变成：

```
补充额外凭据，4位缺位电话号码：[185****3258]
```

字符串不再匹配，`expect` 等不到对应提示就一直挂着，最终超时或被服务端断开（日志里表现为 `Pulse fatal error (reason: 6): agentd error` / `Session terminated by server`）。

本仓库相对原镜像做了四处修复：

1. **认证提示匹配**：把 `connect.sh` 的 `expect` 匹配从「完整句子」改为「稳定关键子串」（`身份证后6位`、`缺位电话号码`），同时兼容新旧文案，避免服务端再次改文案时重蹈覆辙。
2. **会话超时自愈**：原 entrypoint 用 `while true; wait` 死循环保活，openconnect 死后容器仍 Up 但代理不通，`--restart=always` 不触发。改为「进程退出即容器退出」+ 看门狗探活，实现自动重连（见上文[自愈机制](#自愈机制)）。
3. **健康检查**：新增 `HEALTHCHECK` 与 `curl`，可在 `docker ps` 直接看到代理是否真的可用。
4. **用内核 tun 取代 ocproxy**：见下节。

### 为什么换掉 ocproxy

原方案 `openconnect --script-tun --script "ocproxy -D 1080 -g"` 不建真实网卡，而是用 lwIP 在用户态实现一整套 TCP/IP 栈。实测（2026-08-05，校外访问校内 Proxmox）：

| 指标 | ocproxy（用户态栈） | 内核 tun + gost |
| --- | --- | --- |
| 单条连接 | 28 KB/s | 42~53 KB/s |
| 6 并发总吞吐 | 134 KB/s | 285 KB/s |
| 校内镜像站单流 | 1.4 KB/s | 61 KB/s |

隧道 RTT 约 45 ms，反推 ocproxy 单流的有效 TCP 窗口只有 **约 1.2 KB（≈1 个 MSS）**——几乎退化成「发一包等一个 ACK」，完全没有流水线。带宽和延迟都不是瓶颈，用户态栈才是。

换成真实 tun 后走内核 TCP 栈，代价是需要 `--device /dev/net/tun --cap-add NET_ADMIN`。路由由 `pku-route.sh` 控制，**只给 PKU 网段装明细路由，默认路由保持不动**——这样既不劫持容器的其它出站流量，也保证宿主机映射进来的 1080 入站连接回包不会被吸进隧道。

> ⚠️ `pku-route.sh` 里有一条 `ip route replace "$VPNGATEWAY/32" via <原网关>` 不能删。`222.29.0.0/16` 覆盖了 pacvpn 自己的地址，少了这条 /32 明细，拨号流量会被路由进还没建好的隧道，死锁在那里无限重连。

> 日志里的 `Failed to open /dev/vhost-net: No such file or directory` 只是容器内缺少虚拟网络加速设备，**不影响连接**，可忽略。
>
> `ocproxy` 时代的 IPv4-only 限制已随之解除，但 PKU 的 IPv6 段默认仍未加进 `pku-route.sh` 的 `PKU_NETS`；需要的话自行添加并同步分流规则。

## 致谢

- [thezzisu/ocproxy-oci](https://github.com/thezzisu/ocproxy-oci) — 原始镜像
- [cernekee/ocproxy](https://github.com/cernekee/ocproxy)
- [openconnect](https://www.infradead.org/openconnect/)
- 参考文章：[arthals.ink](https://arthals.ink/blog/pku-vpn)
