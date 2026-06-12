# pku-vpn-proxy

把北大 VPN（PKU VPN）变成一个本地 SOCKS5 代理端口，方便配合 Clash / Surge / PAC 做**校内流量分流**——只有访问校内资源（如 `*.pku.edu.cn`）的请求才走 VPN，其余流量直连，不影响日常上网速度。

底层基于 [cernekee/ocproxy](https://github.com/cernekee/ocproxy) + [openconnect](https://www.infradead.org/openconnect/)，在容器内以用户态方式建立 Pulse 隧道并暴露 SOCKS5 端口，**无需 root、无需 TUN 设备、不接管全局网络**。

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
  ghcr.io/zrzzzz/pku-vpn-proxy:latest
```

> macOS 上 `--env-file` 不会展开 `~`，如果用绝对路径请写 `$HOME/pku.env`，不要写 `~/pku.env`。

### 3. 验证

```sh
docker logs pku-vpn          # 看到 "ESP session established with server" 即连接成功
curl --socks5 127.0.0.1:11080 -I https://portal.pku.edu.cn   # 返回 HTTP 200 即代理可用
```

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
docker restart pku-vpn        # 断线后重连
docker rm -f pku-vpn          # 删除容器
```

容器已加 `--restart=always`，断线后 Docker 会自动重启重连。

## 本地构建

不想用预构建镜像，可以自己 build：

```sh
docker build -t pku-vpn-proxy .
docker run -d --restart=always --name pku-vpn \
  --env-file=pku.env -p 11080:1080 pku-vpn-proxy
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

本仓库把匹配从「完整句子」改为「稳定关键子串」（`身份证后6位`、`缺位电话号码`），同时兼容新旧文案，避免服务端再次改文案时重蹈覆辙。

> 日志里的 `Failed to open /dev/vhost-net: No such file or directory` 只是容器内缺少虚拟网络加速设备，**不影响连接**，可忽略。

## 致谢

- [thezzisu/ocproxy-oci](https://github.com/thezzisu/ocproxy-oci) — 原始镜像
- [cernekee/ocproxy](https://github.com/cernekee/ocproxy)
- [openconnect](https://www.infradead.org/openconnect/)
- 参考文章：[arthals.ink](https://arthals.ink/blog/pku-vpn)
