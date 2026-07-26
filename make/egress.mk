# ==============================================================================
# Egress 发布与本地脚本服务
# ------------------------------------------------------------------------------
# `deploy-egress` 触发统一的 Release 与镜像工作流；本地脚本服务保持独立。
# ==============================================================================

.PHONY: deploy-egress serve-egress-installer

# 在本地 Egress 仓库更新版本、提交并推送 tag，再统一发布原生产物和镜像。
deploy-egress:
	@set -euo pipefail; \
	case "$(DRY_RUN)" in true|1|yes|y) ;; *) $(require_gh_token); $(normalize_gh_token) ;; esac; \
	$(call prepare_source_release,Egress,$(EGRESS_DIR),Cargo.toml,Cargo.toml Cargo.lock,egress); \
	egress_ref="$$source_ref"; \
	printf '%s\n' \
		"Egress package inputs:" \
		"  action_repository: $(ACTION_REPOSITORY)" \
		"  action_ref:        $(ACTION_REF)" \
		"  egress_repository: $(EGRESS_REPOSITORY)" \
		"  egress_ref:        $$egress_ref" \
		"  version_tag:       $$tag"; \
	case "$(DRY_RUN)" in true|1|yes|y) exit 0 ;; esac; \
	payload="$$(ruby -rjson -e 'puts JSON.generate({ref: ARGV[0], inputs: {egress_repository: ARGV[1], egress_ref: ARGV[2], version_tag: ARGV[3]}})' "$(ACTION_REF)" "$(EGRESS_REPOSITORY)" "$$egress_ref" "$$tag")"; \
	$(call dispatch_workflow,egress.yml); \
	echo "Triggered unified egress.yml release in $(ACTION_REPOSITORY)"

# 从项目根目录提供 install.sh / uninstall.sh，便于本机和 OrbStack 节点访问。
serve-egress-installer:
	@command -v python3 >/dev/null 2>&1 || { \
		echo "python3 is required to serve the development installer." >&2; \
		exit 1; \
	}
	@printf '%s\n' \
		"Serving the Egress scripts for development:" \
		"  local install:      http://127.0.0.1:$(EGRESS_INSTALLER_PORT)/install.sh" \
		"  local uninstall:    http://127.0.0.1:$(EGRESS_INSTALLER_PORT)/uninstall.sh" \
		"  OrbStack install:   http://host.orb.internal:$(EGRESS_INSTALLER_PORT)/install.sh" \
		"  OrbStack uninstall: http://host.orb.internal:$(EGRESS_INSTALLER_PORT)/uninstall.sh" \
		"  module base env:    ONE_BROWSER_EGRESS_SCRIPT_BASE_URL=http://host.orb.internal:$(EGRESS_INSTALLER_PORT)/scripts/egress"
	@python3 -m http.server "$(EGRESS_INSTALLER_PORT)" \
		--bind "$(EGRESS_INSTALLER_BIND)" \
		--directory "$(PROJECT_ROOT)"
