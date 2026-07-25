# 所有命令统一使用 Bash；各模块中的脚本依赖 pipefail 和 [[ ... ]] 语法。
SHELL := /bin/bash

# 无论从哪个目录通过 make -f 调用，都以本 Makefile 所在目录作为项目根目录。
PROJECT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

# 未指定目标时展示帮助，避免误触发发布或部署命令。
.DEFAULT_GOAL := help

# 配置必须最先加载，后续命令模块会读取仓库、版本和 GitHub API 变量。
include $(PROJECT_ROOT)/make/config.mk

# 共享 GitHub API 能力应先于具体发布模块加载。
include $(PROJECT_ROOT)/make/github.mk
include $(PROJECT_ROOT)/make/server.mk
include $(PROJECT_ROOT)/make/egress.mk
include $(PROJECT_ROOT)/make/app.mk

.PHONY: help

# help 是根 Makefile 唯一直接实现的命令；新增目标时请同步维护这里。
help:
	@printf '%s\n' \
		"One Browser Action" \
		"" \
		"用法:" \
		"  make <目标> [变量=值]" \
		"" \
		"检查:" \
		"  help                     显示此帮助" \
		"  check-token              检查 GH_TOKEN、源仓库和工作流访问权限" \
		"" \
		"Server:" \
		"  deploy-server            触发 Server 构建，并按 DEPLOY 决定是否部署" \
		"" \
		"Egress:" \
		"  deploy-egress            触发 Egress Release 与 Docker 镜像构建" \
		"  serve-egress-installer   在本地提供 Egress 安装和卸载脚本" \
		"" \
		"App:" \
		"  deploy-app               触发桌面 App 正式发布" \
		"  debug-app                触发 Windows App 调试包构建" \
		"" \
		"常用变量:" \
		"  GH_TOKEN                 GitHub PAT；可写入 $(ENV_FILE)" \
		"  TAG / VERSION_TAG        发布标签，省略 v 前缀时会自动补齐" \
		"  SERVER_REF / EGRESS_REF / APP_REF" \
		"                           指定各源仓库分支、标签或提交" \
		"  DRY_RUN=true             只打印参数，不调用 GitHub API" \
		"  FORCE=true               强制执行 Server 发布流程" \
		"  DEPLOY=false             仅构建 Server，不执行部署" \
		"" \
		"示例:" \
		"  make check-token" \
		"  make deploy-server DRY_RUN=true" \
		"  make deploy-egress TAG=v26.725.1" \
		"  make deploy-app APP_REF=main"
