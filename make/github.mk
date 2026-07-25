# ==============================================================================
# GitHub API 公共能力
# ------------------------------------------------------------------------------
# 负责 Token 校验、规范化和 workflow_dispatch 请求。具体产品发布目标放在
# server.mk、egress.mk 和 app.mk，避免在多个模块重复认证与错误处理逻辑。
# ==============================================================================

.PHONY: check-token

# 所有需要调用 GitHub API 的目标都必须先执行此检查。
define require_gh_token
if [ -z "$${GH_TOKEN:-}" ]; then \
	echo "GH_TOKEN is required. Add GH_TOKEN=... to .env or export it in your shell." >&2; \
	exit 1; \
fi
endef

# 兼容历史 .env 中的引号或 Bearer 前缀，但后续请求始终使用纯 Token。
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

# GitHub API 失败时统一给出可操作提示，不输出 Token 本身。
define print_github_api_hint
echo "Check .env has a raw token such as GH_TOKEN=ghp_... or GH_TOKEN=github_pat_..., without a Bearer prefix, and that the token can read the source repos and dispatch workflows in $(ACTION_REPOSITORY)." >&2
endef

# 参数 1 是工作流文件名；调用方需提前设置 api_token 和 payload。
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

# 在真实发布前检查 Token 身份、源仓库读取权限和工作流可见性。
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
	check_api "egress repository" "repos/$(EGRESS_REPOSITORY)"; \
	check_api "app repository" "repos/$(APP_REPOSITORY)"; \
	check_api "server workflow" "repos/$(ACTION_REPOSITORY)/actions/workflows/server.yml"; \
	check_api "egress release workflow" "repos/$(ACTION_REPOSITORY)/actions/workflows/egress-release.yml"; \
	check_api "egress workflow" "repos/$(ACTION_REPOSITORY)/actions/workflows/egress.yml"; \
	check_api "app workflow" "repos/$(ACTION_REPOSITORY)/actions/workflows/app.yml"; \
	check_api "app debug workflow" "repos/$(ACTION_REPOSITORY)/actions/workflows/app-debug.yml"; \
	echo "Token basic checks passed. Workflow dispatch still requires Actions: write on $(ACTION_REPOSITORY)."
