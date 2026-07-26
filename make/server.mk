# ==============================================================================
# Server 发布命令
# ------------------------------------------------------------------------------
# 本地版本提交由 release.mk 处理，GitHub 请求由 github.mk 处理。
# ==============================================================================

.PHONY: deploy-server

# 在本地 Server 仓库更新版本、提交并推送 tag，再按 DEPLOY 触发工作流。
deploy-server:
	@set -euo pipefail; \
	case "$(DRY_RUN)" in true|1|yes|y) ;; *) $(require_gh_token); $(normalize_gh_token) ;; esac; \
	$(call prepare_source_release,Server,$(SERVER_DIR),Cargo.toml,Cargo.toml Cargo.lock,server); \
	server_ref="$$source_ref"; \
	image_name="$(IMAGE_NAME)"; \
	if [ -z "$$image_name" ]; then image_name="$(SERVER_REPOSITORY)"; fi; \
	force="$(FORCE)"; \
	deploy="$(DEPLOY)"; \
	case "$$force" in true|1|yes|y) force=true ;; *) force=false ;; esac; \
	case "$$deploy" in false|0|no|n) deploy=false ;; *) deploy=true ;; esac; \
	printf '%s\n' \
		"Server release inputs:" \
		"  action_repository: $(ACTION_REPOSITORY)" \
		"  action_ref:        $(ACTION_REF)" \
		"  server_repository: $(SERVER_REPOSITORY)" \
		"  server_ref:        $$server_ref" \
		"  version_tag:       $$tag" \
		"  web_repository:    $(WEB_REPOSITORY)" \
		"  web_ref:           $(WEB_REF)" \
		"  image_name:        $$image_name" \
		"  force:             $$force" \
		"  deploy:            $$deploy"; \
	case "$(DRY_RUN)" in true|1|yes|y) exit 0 ;; esac; \
	payload="$$(ruby -rjson -e 'puts JSON.generate({ref: ARGV[0], inputs: {server_repository: ARGV[1], server_ref: ARGV[2], version_tag: ARGV[3], web_repository: ARGV[4], web_ref: ARGV[5], image_name: ARGV[6], force: ARGV[7] == "true", deploy: ARGV[8] == "true"}})' "$(ACTION_REF)" "$(SERVER_REPOSITORY)" "$$server_ref" "$$tag" "$(WEB_REPOSITORY)" "$(WEB_REF)" "$$image_name" "$$force" "$$deploy")"; \
	$(call dispatch_workflow,server.yml); \
	echo "Triggered server.yml in $(ACTION_REPOSITORY)"
