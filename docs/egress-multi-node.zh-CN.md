# Egress 多节点发布与接入

Egress 的发布和节点接入已经分开：

- `make deploy-egress` 只负责构建并上传运行产物。
- Server 负责创建节点 ID、签发一次性接入 Token，并生成安装与卸载命令。
- 节点主动下载公开产物并连接 Server。
- GitHub Actions 不再通过 SSH 部署 Egress 节点。

## GitHub 准备

本地 `one-browser-action/.env` 只需要用于 Workflow Dispatch 的 `GH_TOKEN`。
Action 仓库的 Repository `GH_TOKEN` 需要：

- 读取 `voiceofhu/one-browser-egress` 源码；
- 在 `voiceofhu/one-browser-action` 创建 Egress Release；
- 向 `ghcr.io/voiceofhu/one-browser-egress` 写入镜像。

不需要为每个 Egress 节点创建 GitHub Environment，也不需要
`DEPLOY_SSH_KEY`、`DEPLOY_KNOWN_HOSTS` 或 `egress-targets.json`。

## 统一打包

执行：

```bash
make deploy-egress
```

该命令先进入相邻的 `one-browser-egress` 源码仓库更新 Cargo 版本，只提交
`Cargo.toml` 和 `Cargo.lock`，原子推送当前分支与版本 tag；回到 Action 仓库后
只触发一次 `.github/workflows/egress.yml`。工作流把刚推送的精确提交解析为
Cargo 版本，再从同一个提交并行发布：

1. 原生产物：
   - 构建 `linux/amd64` 与 `linux/arm64` 原生二进制；
   - 发布 `egress-v<版本>` Release；
   - 上传压缩包和 `SHA256SUMS`；
   - 保存同一份 Action Artifact。
2. Docker 镜像：
   - 构建并上传多架构 Docker 镜像；
   - 发布 `sha-<egress_sha>`；
   - 发布 Cargo 语义版本标签；
   - 默认分支同时发布 `latest`；
   - 不连接或修改任何节点。

固定 Egress 版本时使用：

```bash
make deploy-egress VERSION=26.725.1317
```

公开的跨架构入口保留在仓库根目录：

- `install.sh`
- `uninstall.sh`

实际实现按职责拆分在 `scripts/egress/install/` 和
`scripts/egress/uninstall/`。公开入口通过管道运行时，会先从同一个公开仓库加载对应
模块；入口只解析一次 `main`，并从同一个提交快照下载全部模块，避免 CDN 缓存混用
不同版本。因此 Server 已生成的根目录脚本 URL 保持兼容。脚本不复制进 Release。
`install.sh` 支持 `native`、`docker`、`amd64`、`arm64`，并接受可选的
`--version`；不传版本时安装最新版本。

## 开发环境准备

Server 使用：

```dotenv
APP_ENV=development
APP_ADDR=0.0.0.0:27512
APP_PUBLIC_URL=http://host.orb.internal:27512
EGRESS_TOKEN_PEPPER=<至少 32 个字符且保持稳定>
```

OrbStack 节点可使用：

| 节点名称 | 域名 |
| --- | --- |
| `node-1` | `node-1.orb.local` |
| `node-2` | `node-2.orb.local` |
| `node-3` | `node-3.orb.local` |

开发环境返回 `tls_enabled=false`，不检查公网 DNS，也不申请证书。节点需要 root
或 sudo、可访问 GitHub/GHCR/Server，并确保 TCP `27600` 未被占用。

## 正式环境准备

Server 必须使用：

```dotenv
APP_ENV=production
APP_PUBLIC_URL=https://browser.example.com
EGRESS_TOKEN_PEPPER=<独立、稳定、至少 32 个字符>
```

每台 Egress 节点需要：

- 独立的小写公网域名；
- 只包含指向本机公网 IPv4 的 DNS-only A 记录；
- 不发布 AAAA；
- 开放入站 TCP `80`，供 Certbot HTTP-01 使用；
- 开放入站 TCP `27600`，供 Egress 数据通道使用；
- 允许出站 HTTPS 访问 GitHub、GHCR、Let's Encrypt 和 Server；
- TCP `80` 在申请证书时未被其他进程占用。

正式环境返回 `tls_enabled=true`。安装脚本自动安装 Certbot、校验 DNS 并申请证书，
不需要提前上传证书文件。

## 节点接入顺序

1. 在 Web「节点管理」中输入节点域名和节点名称。
2. Server 生成节点 ID、一次性 Token、Native 命令、Docker 命令和卸载命令。
3. 在目标机器上只执行 Native 或 Docker 命令中的一个。
4. 安装器检测已有安装；同一节点可安全重装，不同节点身份不会被静默覆盖。
5. 节点完成接入并发送心跳后，Web 通过 SSE 按 `egress_id` 更新为在线。
6. 依次处理其他节点。

初始接入 Token 默认 15 分钟有效。不要在产物尚未发布、Server 尚未部署或节点网络
尚未准备好时提前创建节点。

## 卸载与重新安装

使用 Server 返回的 `uninstall.sh` 命令删除 Native 服务或 Docker 容器。卸载脚本
保留 Docker 本身和 Certbot 证书。卸载主机运行时不会自动删除 Server 中的节点记录；
确认节点没有任务后，再在 Web 中删除对应节点。
