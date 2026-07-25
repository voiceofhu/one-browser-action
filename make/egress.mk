# ==============================================================================
# Egress 发布与本地脚本服务
# ------------------------------------------------------------------------------
# `deploy-egress` 触发 Release 与镜像工作流；本地脚本服务保持独立。
# ==============================================================================

.PHONY: deploy-egress serve-egress-installer

# 先触发原生产物发布，再触发 Docker 镜像构建。
deploy-egress:
	@set -euo pipefail; \
	tag="$(VERSION_TAG)"; \
	if [ -n "$$tag" ] && [[ "$$tag" != v* ]]; then tag="v$$tag"; fi; \
	egress_ref="$(EGRESS_REF)"; \
	printf '%s\n' \
		"Egress package inputs:" \
		"  action_repository: $(ACTION_REPOSITORY)" \
		"  action_ref:        $(ACTION_REF)" \
		"  egress_repository: $(EGRESS_REPOSITORY)" \
		"  egress_ref:        $${egress_ref:-default branch}" \
		"  version_tag:       $${tag:-Cargo.toml}"; \
	case "$(DRY_RUN)" in true|1|yes|y) exit 0 ;; esac; \
	$(require_gh_token); \
	$(normalize_gh_token); \
	payload="$$(ruby -rjson -e 'puts JSON.generate({ref: ARGV[0], inputs: {egress_repository: ARGV[1], egress_ref: ARGV[2], version_tag: ARGV[3]}})' "$(ACTION_REF)" "$(EGRESS_REPOSITORY)" "$$egress_ref" "$$tag")"; \
	$(call dispatch_workflow,egress-release.yml); \
	echo "Triggered egress-release.yml in $(ACTION_REPOSITORY)"; \
	payload="$$(ruby -rjson -e 'puts JSON.generate({ref: ARGV[0], inputs: {egress_ref: ARGV[1]}})' "$(ACTION_REF)" "$$egress_ref")"; \
	$(call dispatch_workflow,egress.yml); \
	echo "Triggered egress.yml Docker image packaging in $(ACTION_REPOSITORY)"

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
