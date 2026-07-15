.PHONY: deploy-server deploy-app debug-app check-token

define require_gh_token
if [ -z "$${GH_TOKEN:-}" ]; then \
	echo "GH_TOKEN is required. Add GH_TOKEN=... to .env or export it in your shell." >&2; \
	exit 1; \
fi
endef

define normalize_gh_token
api_token="$${GH_TOKEN}"; \
api_token="$${api_token%\"}"; \
api_token="$${api_token#\"}"; \
api_token="$${api_token%\'}"; \
api_token="$${api_token#\'}"; \
api_token="$${api_token#Bearer }"; \
api_token="$${api_token#bearer }"; \
if [ -z "$$api_token" ]; then \
	echo "GH_TOKEN is empty after normalization. Use GH_TOKEN=ghp_... or GH_TOKEN=github_pat_... in .env." >&2; \
	exit 1; \
fi
endef

define print_github_api_hint
echo "Check .env has a raw token such as GH_TOKEN=ghp_... or GH_TOKEN=github_pat_..., without a Bearer prefix, and that the token can read the source repos and dispatch workflows in $(ACTION_REPOSITORY)." >&2
endef

define dispatch_workflow
dispatch_response="$$(mktemp)"; \
if ! dispatch_status="$$(curl -sS -o "$$dispatch_response" -w "%{http_code}" \
	-X POST \
	-H "Authorization: Bearer $$api_token" \
	-H "Accept: application/vnd.github+json" \
	-H "X-GitHub-Api-Version: 2022-11-28" \
	"$(GITHUB_API_URL)/repos/$(ACTION_REPOSITORY)/actions/workflows/$(1)/dispatches" \
	-d "$$payload")"; then \
	echo "GitHub API request failed while dispatching $(1) in $(ACTION_REPOSITORY)." >&2; \
	$(print_github_api_hint); \
	cat "$$dispatch_response" >&2 || true; \
	rm -f "$$dispatch_response"; \
	exit 1; \
fi; \
if [ "$$dispatch_status" -lt 200 ] || [ "$$dispatch_status" -ge 300 ]; then \
	echo "GitHub API failed while dispatching $(1) in $(ACTION_REPOSITORY): HTTP $$dispatch_status" >&2; \
	$(print_github_api_hint); \
	cat "$$dispatch_response" >&2 || true; \
	rm -f "$$dispatch_response"; \
	exit 1; \
fi; \
rm -f "$$dispatch_response"
endef

check-token:
	@set -euo pipefail; \
	$(require_gh_token); \
	$(normalize_gh_token); \
	check_api() { \
		label="$$1"; \
		path="$$2"; \
		response_file="$$(mktemp)"; \
		status="$$(curl -sS -o "$$response_file" -w "%{http_code}" \
			-H "Authorization: Bearer $$api_token" \
			-H "Accept: application/vnd.github+json" \
			-H "X-GitHub-Api-Version: 2022-11-28" \
			"$(GITHUB_API_URL)/$$path")" || { \
				echo "FAIL $$label: request failed" >&2; \
				cat "$$response_file" >&2 || true; \
				rm -f "$$response_file"; \
				exit 1; \
			}; \
		if [ "$$status" -lt 200 ] || [ "$$status" -ge 300 ]; then \
			echo "FAIL $$label: HTTP $$status" >&2; \
			cat "$$response_file" >&2 || true; \
			rm -f "$$response_file"; \
			exit 1; \
		fi; \
		echo "OK   $$label"; \
		rm -f "$$response_file"; \
	}; \
	user_response="$$(mktemp)"; \
	user_status="$$(curl -sS -o "$$user_response" -w "%{http_code}" \
		-H "Authorization: Bearer $$api_token" \
		-H "Accept: application/vnd.github+json" \
		-H "X-GitHub-Api-Version: 2022-11-28" \
		"$(GITHUB_API_URL)/user")" || { \
			echo "FAIL token identity: request failed" >&2; \
			cat "$$user_response" >&2 || true; \
			rm -f "$$user_response"; \
			exit 1; \
		}; \
	if [ "$$user_status" -lt 200 ] || [ "$$user_status" -ge 300 ]; then \
		echo "FAIL token identity: HTTP $$user_status" >&2; \
		cat "$$user_response" >&2 || true; \
		rm -f "$$user_response"; \
		exit 1; \
	fi; \
	login="$$(ruby -rjson -e 'user = JSON.parse(ARGF.read); puts user["login"]' "$$user_response")"; \
	rm -f "$$user_response"; \
	echo "OK   token identity: $$login"; \
	check_api "server repository" "repos/$(SERVER_REPOSITORY)"; \
	check_api "app repository" "repos/$(APP_REPOSITORY)"; \
	check_api "server workflow" "repos/$(ACTION_REPOSITORY)/actions/workflows/server.yml"; \
	check_api "app workflow" "repos/$(ACTION_REPOSITORY)/actions/workflows/app.yml"; \
	check_api "app debug workflow" "repos/$(ACTION_REPOSITORY)/actions/workflows/app-debug.yml"; \
	echo "Token basic checks passed. Workflow dispatch still requires Actions: write on $(ACTION_REPOSITORY)."

deploy-server:
	@set -euo pipefail; \
	$(require_gh_token); \
	$(normalize_gh_token); \
	tag="$(VERSION_TAG)"; \
	if [ -n "$$tag" ] && [[ "$$tag" != v* ]]; then tag="v$$tag"; fi; \
	server_ref="$(SERVER_REF)"; \
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
		"  server_ref:        $${server_ref:-default branch}" \
		"  version_tag:       $${tag:-none}" \
		"  web_repository:    $(WEB_REPOSITORY)" \
		"  web_ref:           $(WEB_REF)" \
		"  image_name:        $$image_name" \
		"  force:             $$force" \
		"  deploy:            $$deploy"; \
	case "$(DRY_RUN)" in true|1|yes|y) exit 0 ;; esac; \
	payload="$$(ruby -rjson -e 'puts JSON.generate({ref: ARGV[0], inputs: {server_repository: ARGV[1], server_ref: ARGV[2], version_tag: ARGV[3], web_repository: ARGV[4], web_ref: ARGV[5], image_name: ARGV[6], force: ARGV[7] == "true", deploy: ARGV[8] == "true"}})' "$(ACTION_REF)" "$(SERVER_REPOSITORY)" "$$server_ref" "$$tag" "$(WEB_REPOSITORY)" "$(WEB_REF)" "$$image_name" "$$force" "$$deploy")"; \
	$(call dispatch_workflow,server.yml); \
	echo "Triggered server.yml in $(ACTION_REPOSITORY)"

deploy-app:
	@set -euo pipefail; \
	$(require_gh_token); \
	$(normalize_gh_token); \
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
	payload="$$(ruby -rjson -e 'puts JSON.generate({ref: ARGV[0], inputs: {app_repository: ARGV[1], app_ref: ARGV[2], version_tag: ARGV[3]}})' "$(ACTION_REF)" "$(APP_REPOSITORY)" "$$app_ref" "$$tag")"; \
	$(call dispatch_workflow,app.yml); \
	echo "Triggered app.yml in $(ACTION_REPOSITORY)"

debug-app:
	@set -euo pipefail; \
	$(require_gh_token); \
	$(normalize_gh_token); \
	app_ref="$(APP_REF)"; \
	if [ -z "$$app_ref" ]; then app_ref="main"; fi; \
	printf '%s\n' \
		"Windows app debug inputs:" \
		"  action_repository: $(ACTION_REPOSITORY)" \
		"  action_ref:        $(ACTION_REF)" \
		"  app_repository:    $(APP_REPOSITORY)" \
		"  app_ref:           $$app_ref"; \
	case "$(DRY_RUN)" in true|1|yes|y) exit 0 ;; esac; \
	payload="$$(ruby -rjson -e 'puts JSON.generate({ref: ARGV[0], inputs: {app_repository: ARGV[1], app_ref: ARGV[2]}})' "$(ACTION_REF)" "$(APP_REPOSITORY)" "$$app_ref")"; \
	$(call dispatch_workflow,app-debug.yml); \
	echo "Triggered app-debug.yml in $(ACTION_REPOSITORY)"
