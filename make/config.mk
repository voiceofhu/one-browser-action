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
VERSION ?=
DRY_RUN ?= false

# 相邻源码仓库与统一发布版本。VERSION、TAG、VERSION_TAG 均可覆盖自动版本，
# 最终始终规范化为不带 v 前缀的三段 SemVer。
SOURCE_ROOT ?= $(abspath $(PROJECT_ROOT)/..)
SERVER_DIR ?= $(SOURCE_ROOT)/one-browser-server
EGRESS_DIR ?= $(SOURCE_ROOT)/one-browser-egress
APP_DIR ?= $(SOURCE_ROOT)/one-browser-app
GENERATED_VERSION ?= $(shell node -e "\
  const d=new Date(new Date().toLocaleString('en-US',{timeZone:'Asia/Shanghai'}));\
  const stripLeadingZero=value=>String(Number(value));\
  const year=String(d.getFullYear()).slice(-2);\
  const monthDay=String(d.getMonth()+1).padStart(2,'0')+String(d.getDate()).padStart(2,'0');\
  const hourMinute=String(d.getHours()).padStart(2,'0')+String(d.getMinutes()).padStart(2,'0');\
  process.stdout.write([year,monthDay,hourMinute].map(stripLeadingZero).join('.'));\
")
RELEASE_VERSION = $(patsubst v%,%,$(strip $(if $(VERSION),$(VERSION),$(if $(VERSION_TAG),$(VERSION_TAG),$(GENERATED_VERSION)))))

# Server 发布输入。
SERVER_REPOSITORY ?= voiceofhu/one-browser-server
WEB_REPOSITORY ?= voiceofhu/one-browser-web
WEB_REF ?= main
IMAGE_NAME ?= voiceofhu/one-browser-server
FORCE ?= false
DEPLOY ?= true

# Egress 发布与本地安装脚本服务输入。
EGRESS_REPOSITORY ?= voiceofhu/one-browser-egress
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
