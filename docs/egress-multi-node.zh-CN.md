# Egress 多服务器部署

Egress workflow 采用“一次构建镜像、按节点运行矩阵任务、分波次部署”的方式。
节点的非敏感参数保存在 `.github/config/egress-targets.json`，SSH 私钥和 host key
保存在与节点同名的 GitHub Environment 中。节点控制 Token 只存在于对应服务器和
Server 注册流程，不进入 Action 仓库。

主工作流 `.github/workflows/egress.yml` 负责解析版本、构建镜像和编排波次。每个矩阵
任务直接绑定与节点同名的 GitHub Environment，再调用
`.github/actions/egress/action.yml`。身份校验、Registry 登录、公网检查和回滚脚本都
收拢在 `.github/actions/egress/` 目录。生产容器使用 manifest digest 固定镜像，
而不是可移动标签。

## 当前节点

| ID | 波次 | SSH 主机 | 公网数据地址 | 状态 |
| --- | --- | --- | --- | --- |
| `egress-3` | 1（当前灰度节点） | `51.68.38.135:22` | `egress-3.aicbe.com:27600` | enabled |
| `egress-1` | 2 | `104.194.67.193:22` | `egress-1.aicbe.com:27600` | enabled |
| `egress-2` | 2 | `64.186.255.123:22` | `egress-2.aicbe.com:27600` | enabled |

`deploy_targets=all` 只选择 `enabled: true` 的节点；当前三个节点都会进入批量部署。
新增节点在初始化和验证完成前应保持 `enabled: false`。

## 每个节点的 GitHub Environment

在 `one-browser-action` 仓库的 Settings → Environments 中创建与节点 ID 同名的
Environment，例如 `egress-3`，添加：

- `DEPLOY_SSH_KEY`：该服务器部署账号的 SSH 私钥；
- `DEPLOY_KNOWN_HOSTS`：该服务器经过核对的 SSH host key；
- 可选 required reviewers：用于生产部署人工审批。

服务器地址、端口、用户名和公网 endpoint 是非敏感参数，统一放在版本控制的节点
清单中。所有 workflow 共用的 `GH_TOKEN` 和 Server SSH 用户名放在 Repository
secrets，不要在每个 Environment 重复配置。不要把 Egress Token、`.env`、TLS
私钥或 GitHub Token 写入 JSON。

## GitHub 配置清单

Repository Secrets：

| 名称 | 用途 |
| --- | --- |
| `GH_TOKEN` | 读取私有源码、发布 App Release，以及读写私有 GHCR 镜像 |
| `DEPLOY_USER` | Server 部署使用的 SSH 用户名，当前为 `gh-deploy` |

每个 `egress-N` Environment Secrets：

| 名称 | 用途 |
| --- | --- |
| `DEPLOY_SSH_KEY` | 该节点 `gh-deploy` 用户的私钥 |
| `DEPLOY_KNOWN_HOSTS` | 只包含该节点已核对的 SSH host key |

workflow 会通过 `GH_TOKEN` 自动查询它对应的 GitHub 用户名，因此不再需要
`GHCR_USERNAME`、`GHCR_READ_TOKEN`、`GHCR_TOKEN` 或
`ONE_BROWSER_ACTION_TOKEN`。`DEPLOY_USER` 只是 SSH/Linux 用户名，不是 GHCR
用户名。

Egress workflow 当前不需要任何 GitHub Actions Variables（`vars.*`）。本地执行
`make deploy-egress ...` 只需要仓库 `.env` 中的 `GH_TOKEN`，它用于调用 GitHub
Workflow Dispatch API。Action 运行时使用 Repository `GH_TOKEN` 登录私有 GHCR，
完成拉取后会退出登录，并且不会把 Token 传给 Egress 容器。

Server deploy job 绑定 `egress-3` Environment，复用其中的
`DEPLOY_SSH_KEY`、`DEPLOY_KNOWN_HOSTS`，连接同一台
`51.68.38.135:22` 服务器；不再单独配置 Server 的 Repository 级 SSH 私钥和
known_hosts。Server 与 `egress-3` 使用同一个 concurrency group，避免两次部署在
同一台 Docker 主机上并发登录、退出 GHCR。

## 新服务器初始化顺序

全新的 Debian amd64 服务器统一使用
`.github/actions/egress/bootstrap-debian-amd64.sh` 初始化。脚本负责：

- 安装 Docker 官方版本、Compose plugin、Nginx、Certbot 和 OpenSSH；
- 创建锁定密码的 `gh-deploy`，加入 `docker` 与 `one-browser-deploy`；
- 创建 `/opt/one-browser-egress`、受保护的 `.env` 和证书目录；
- 为 DNS-only 的 Egress 域名签发证书并安装 Certbot 续期 hook；
- 创建 `one-browser-control` 网络并检查 Action 所需权限；
- 检查 `https://browser.aicbe.com/internal/egress/v1/ready` 未鉴权时返回 `401`。

脚本不会修改云厂商 DNS/防火墙、注册 Server 节点、保存 GHCR 密码、上传 Compose、
拉取镜像或启动 Egress。首次启动仍由 GitHub Action 完成。

### 1. 在操作电脑生成部署密钥

每台 Egress 使用不同的 ed25519 密钥：

```bash
ssh-keygen -t ed25519 \
  -f ~/.ssh/egress-1-gh-deploy \
  -C gh-deploy@egress-1
```

私钥 `~/.ssh/egress-1-gh-deploy` 后续写入 `egress-1` Environment 的
`DEPLOY_SSH_KEY`。执行脚本时需要粘贴 `.pub` 公钥，可先复制：

```bash
cat ~/.ssh/egress-1-gh-deploy.pub
```

### 2. 准备 DNS 和网络

1. 将 `egress-1.aicbe.com` 的 A 记录指向服务器公网 IPv4，并保持 Cloudflare
   DNS only（灰云）。
2. 放行 SSH、入站 TCP `27600`，以及 Certbot HTTP-01 签发和续期所需的 TCP
   `80`。所有节点统一运行 Nginx；未安装时脚本会自动安装并启动。
3. 脚本会为 `egress-1.aicbe.com` 创建独立的 Nginx `webroot` 虚拟主机，只处理
   `/.well-known/acme-challenge/`，其余请求返回 `404`。它可以与其他域名共享
   `80`，只执行配置检查和 graceful reload，不会停止其他网站。
4. Egress 数据流不使用 `80/443`，也不经过 Nginx；`27600` 由容器直接发布。

### 3. 把初始化文件复制到服务器

在 `one-browser-action` 仓库根目录执行：

```bash
scp .github/actions/egress/bootstrap-debian-amd64.sh \
  debian@<服务器公网-IP>:/tmp/
```

### 4. 登录服务器并执行初始化

脚本不接收部署配置参数，直接运行：

```bash
sudo bash /tmp/bootstrap-debian-amd64.sh
```

随后按提示回答：

```text
节点编号或 ID [1]:
Egress 公网域名 [egress-1.aicbe.com]:
Let's Encrypt 联系邮箱:
粘贴 gh-deploy SSH 公钥:
确认继续？[y/N]:
```

Server 控制地址固定为 `https://browser.aicbe.com`，不再询问。节点 Token 会自动
生成并写入 `/root/<节点-ID>.control-token`，不会显示在终端或进入 shell 历史。
使用相同答案可以重跑；已有 `.env` 只有在节点 ID、endpoint、固定控制 URL、Token、
监听和证书路径均一致时才会保留。发现冲突的 Docker 软件包、不匹配的 `.env` 或
被占用的 `80` 时，脚本会停止，不会擅自覆盖或删除。

### 5. 完成 Server 和 GitHub 配置

1. 使用 `/root/egress-1.control-token` 中的同一值，在 Server 执行
   `egress-node upsert`，注册 `egress-1`、`egress-1.aicbe.com:27600`、地域、
   运营商和容量。注册完成后删除这份额外 Token 文件；运行副本已经安全保存在
   `/opt/one-browser-egress/.env`。
2. 在每台 Egress 服务器执行下面命令，自动获取本机公网 IPv4，并将本机 ED25519
   Host Key 拼成 `known_hosts` 格式：

   ```bash
   # 自动获取当前服务器公网 IPv4，并输出完整的 DEPLOY_KNOWN_HOSTS 记录。
   # 把命令输出的整行复制到该节点的 DEPLOY_KNOWN_HOSTS。
   EGRESS_PUBLIC_IPV4="$(curl -4fsS https://api.ipify.org)" &&
     sudo awk -v host="$EGRESS_PUBLIC_IPV4" \
       '{print host, $1, $2}' \
       /etc/ssh/ssh_host_ed25519_key.pub
   ```

   正确输出格式为 `IP ssh-ed25519 AAAA...`。`ssh-keygen -lf` 输出的
   `SHA256:...` 只是用于人工核对的指纹，不能直接填入 `DEPLOY_KNOWN_HOSTS`。
   自动获取的 IP 必须与 `.github/config/egress-targets.json` 中该节点的 `host`
   完全一致。当前统一使用 SSH `22`；如果以后改为其他端口，host 字段必须写成
   `[IP]:端口`。公网 IPv4 由 [ipify](https://www.ipify.org/) 查询。
3. 创建 `egress-1` GitHub Environment，只设置 `DEPLOY_SSH_KEY` 和
   `DEPLOY_KNOWN_HOSTS`。共用的 `GH_TOKEN`、`DEPLOY_USER` 只需在 Repository
   secrets 配置一次。
4. 在 `.github/config/egress-targets.json` 中确认 host、endpoint、control URL 和
   用户均匹配，随后将 `enabled` 改为 `true`。
5. 首次只部署这个节点：`make deploy-egress 1`。确认容器健康和公网 TLS/H2 检查
   通过后，再让它参与 `make deploy-egress all`。

## 触发部署

部署节点 1、2 或 3：

```bash
make deploy-egress 1
make deploy-egress 2
make deploy-egress 3
```

部署全部已启用节点。第一波成功后才会进入后续波次：

```bash
make deploy-egress all
```

只构建和发布镜像，不部署：

```bash
make deploy-egress all DEPLOY=false
```

必须且只能提供一个位置参数。`1`、`2`、`3` 分别映射为 `egress-1`、
`egress-2`、`egress-3`；`all` 选择清单中所有 `enabled: true` 的节点。缺少参数、
未知参数或同时输入多个参数都会在发起 Action 前失败。

Action 对每个节点独立执行 SSH 配置、节点身份校验、候选镜像校验、Compose 更新、
容器健康等待和公网 endpoint 检查。公网 TLS/H2 或 `407 Bearer` 协议检查失败时，
会恢复部署前的 Compose 文件和镜像；第一轮节点失败后，后续波次不会启动。不同节点
拥有独立 concurrency key，不会互相覆盖 Compose 参数。

部署前要求服务器 `.env` 中的 `EGRESS_ID`、`EGRESS_PUBLIC_ENDPOINT` 和
`EGRESS_CONTROL_URL` 与节点清单完全对应。校验过程不会读取或输出
`EGRESS_CONTROL_TOKEN`。

## 修改节点参数

编辑 `.github/config/egress-targets.json`。常用字段：

| 字段 | 说明 |
| --- | --- |
| `id` | workflow 选择用的稳定节点 ID |
| `enabled` | 是否允许 `all` 自动选择 |
| `wave` | 部署波次；所选节点中最小波次先作为 canary |
| `environment` | 获取节点 Secret 的 GitHub Environment |
| `host`、`port`、`user` | SSH 参数 |
| `endpoint` | 部署后验证的公网 `host:port` |
| `control_url` | 节点 `.env` 必须匹配的 Server 公网 HTTPS 地址 |
| `remote_dir` | 固定部署目录 `/opt/one-browser-egress` |
| `control_network` | 该宿主机本地 Docker network |
| `use_sudo` | `0` 为直接使用 Docker，`1` 为精确免密 sudo |
| `public_check` | 是否执行公网 TLS/H2 协议检查 |

本地验证节点选择逻辑：

```bash
output=$(mktemp)
GITHUB_OUTPUT="$output" \
  EGRESS_TARGETS_INPUT=egress-3 \
  EGRESS_ROLLOUT_INPUT=full \
  bash .github/scripts/resolve-egress-targets.sh \
  .github/config/egress-targets.json
cat "$output"
```

选择不存在或 `enabled: false` 的节点会直接失败，不会尝试 SSH。
