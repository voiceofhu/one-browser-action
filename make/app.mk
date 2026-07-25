# ==============================================================================
# 桌面 App 发布命令
# ------------------------------------------------------------------------------
# 正式包和 Windows 调试包使用不同工作流，但共享 github.mk 的认证与请求逻辑。
# ==============================================================================

.PHONY: deploy-app debug-app

# 触发 app.yml，构建并发布桌面 App。
deploy-app:
	@set -euo pipefail; \
	tag="$(VERSION_TAG)"; \
	if [ -n "$$tag" ] && [[ "$$tag" != v* ]]; then tag="v$$tag"; fi; \
	app_ref="$(APP_REF)"; \
	printf '%s\n' \
		"App release inputs:" \
		"  action_repository: $(ACTION_REPOSITORY)" \
		"  action_ref:        $(ACTION_REF)" \
		"  app_repository:    $(APP_REPOSITORY)" \
		"  app_ref:           $${app_ref:-default branch}" \
		"  version_tag:       $${tag:-package.json}"; \
	case "$(DRY_RUN)" in true|1|yes|y) exit 0 ;; esac; \
	$(require_gh_token); \
	$(normalize_gh_token); \
	payload="$$(ruby -rjson -e 'puts JSON.generate({ref: ARGV[0], inputs: {app_repository: ARGV[1], app_ref: ARGV[2], version_tag: ARGV[3]}})' "$(ACTION_REF)" "$(APP_REPOSITORY)" "$$app_ref" "$$tag")"; \
	$(call dispatch_workflow,app.yml); \
	echo "Triggered app.yml in $(ACTION_REPOSITORY)"

# 触发 app-debug.yml，仅生成 Windows 调试构建，不创建正式发布。
debug-app:
	@set -euo pipefail; \
	app_ref="$(APP_REF)"; \
	if [ -z "$$app_ref" ]; then app_ref="main"; fi; \
	printf '%s\n' \
		"Windows app debug inputs:" \
		"  action_repository: $(ACTION_REPOSITORY)" \
		"  action_ref:        $(ACTION_REF)" \
		"  app_repository:    $(APP_REPOSITORY)" \
		"  app_ref:           $$app_ref"; \
	case "$(DRY_RUN)" in true|1|yes|y) exit 0 ;; esac; \
	$(require_gh_token); \
	$(normalize_gh_token); \
	payload="$$(ruby -rjson -e 'puts JSON.generate({ref: ARGV[0], inputs: {app_repository: ARGV[1], app_ref: ARGV[2]}})' "$(ACTION_REF)" "$(APP_REPOSITORY)" "$$app_ref")"; \
	$(call dispatch_workflow,app-debug.yml); \
	echo "Triggered app-debug.yml in $(ACTION_REPOSITORY)"
