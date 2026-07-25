# ==============================================================================
# 全局配置
# ------------------------------------------------------------------------------
# 所有变量都使用 ?=，调用方可以通过环境变量或 `make TARGET VAR=value` 覆盖。
# 此文件只负责配置和 .env 加载，不定义任何可执行目标。
# ==============================================================================

# 中央 Action 仓库与 GitHub API。
ACTION_REPOSITORY ?= voiceofhu/one-browser-action
ACTION_REF ?= main
GITHUB_API_URL ?= https://api.github.com
TAG ?=
VERSION_TAG ?= $(TAG)
DRY_RUN ?= false

# Server 发布输入。
SERVER_REPOSITORY ?= voiceofhu/one-browser-server
SERVER_REF ?=
WEB_REPOSITORY ?= voiceofhu/one-browser-web
WEB_REF ?= main
IMAGE_NAME ?= voiceofhu/one-browser-server
FORCE ?= false
DEPLOY ?= true

# Egress 发布与本地安装脚本服务输入。
EGRESS_REPOSITORY ?= voiceofhu/one-browser-egress
EGRESS_REF ?=
EGRESS_INSTALLER_BIND ?= 0.0.0.0
EGRESS_INSTALLER_PORT ?= 27610

# 桌面 App 发布输入。
APP_REPOSITORY ?= voiceofhu/one-browser-app
APP_REF ?=

# 默认读取项目根目录的 .env；文件不存在时保持环境变量和命令行覆盖逻辑。
ENV_FILE ?= $(PROJECT_ROOT)/.env
ifneq (,$(wildcard $(ENV_FILE)))
include $(ENV_FILE)
export
endif
