# ==============================================================================
# 本地源码版本发布
# ------------------------------------------------------------------------------
# deploy-* 在 dispatch 前统一完成：检查源码仓库、更新版本、只提交版本文件、
# 创建 tag，并将当前分支和 tag 原子推送到 origin。
# ==============================================================================

# 参数:
#   1. 产品显示名
#   2. 本地源码目录
#   3. 读取实际版本的相对文件（package.json 或 Cargo.toml）
#   4. 允许版本命令修改并提交的相对路径（空格分隔）
#   5. commit message 中的产品名
#
# 输出给同一 recipe 后续命令:
#   tag        规范化后的 v-prefixed tag
#   source_ref 已推送版本提交的精确 SHA；DRY_RUN 时为计划中的 tag
define prepare_source_release
source_name="$(1)"; \
source_dir="$(2)"; \
version_file="$(3)"; \
version_paths="$(4)"; \
release_version="$(RELEASE_VERSION)"; \
version_input="$(strip $(VERSION))"; \
tag_input="$(strip $(VERSION_TAG))"; \
tag_input="$${tag_input#v}"; \
if [ -n "$$version_input" ] && [ -n "$$tag_input" ] && [ "$${version_input#v}" != "$$tag_input" ]; then \
	echo "VERSION ($$version_input) and TAG/VERSION_TAG ($$tag_input) must identify the same release." >&2; \
	exit 1; \
fi; \
if [[ ! "$$release_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)([-+][0-9A-Za-z.-]+)?$$ ]]; then \
	echo "Invalid release version: $$release_version" >&2; \
	exit 1; \
fi; \
tag="v$$release_version"; \
if [ ! -d "$$source_dir/.git" ]; then \
	echo "$$source_name source repository not found: $$source_dir" >&2; \
	exit 1; \
fi; \
source_branch="$$(git -C "$$source_dir" symbolic-ref --quiet --short HEAD)" || { \
	echo "$$source_name source repository must be on a branch: $$source_dir" >&2; \
	exit 1; \
}; \
printf '%s\n' \
	"$$source_name source release:" \
	"  source_dir:         $$source_dir" \
	"  source_branch:      $$source_branch" \
	"  release_version:    $$release_version" \
	"  release_tag:        $$tag"; \
case "$(DRY_RUN)" in \
	true|1|yes|y) \
		source_ref="$$tag"; \
		printf '%s\n' "  source_ref:         $$source_ref (planned)"; \
	;; \
	*) \
		source_status="$$(git -C "$$source_dir" status --porcelain --untracked-files=all)"; \
		if [ -n "$$source_status" ]; then \
			echo "$$source_name source repository must be clean before release:" >&2; \
			printf '%s\n' "$$source_status" >&2; \
			exit 1; \
		fi; \
		git -C "$$source_dir" fetch --tags origin \
			"refs/heads/$$source_branch:refs/remotes/origin/$$source_branch"; \
		if ! git -C "$$source_dir" show-ref --verify --quiet "refs/remotes/origin/$$source_branch"; then \
			echo "Remote branch origin/$$source_branch was not found." >&2; \
			exit 1; \
		fi; \
		if ! git -C "$$source_dir" merge-base --is-ancestor "origin/$$source_branch" HEAD; then \
			echo "$$source_name branch is behind or diverged from origin/$$source_branch; update it before release." >&2; \
			exit 1; \
		fi; \
		if git -C "$$source_dir" rev-parse -q --verify "refs/tags/$$tag" >/dev/null; then \
			echo "Git tag $$tag already exists in $$source_name." >&2; \
			exit 1; \
		fi; \
		$(MAKE) --no-print-directory -C "$$source_dir" version VERSION="$$release_version"; \
		case "$$version_file" in \
			*.json) \
				actual_version="$$(node -e 'const fs=require("node:fs");const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));process.stdout.write(p.version||"")' "$$source_dir/$$version_file")" \
			;; \
			*.toml) \
				actual_version="$$(awk -F '"' '/^\[package\]/{in_package=1; next} /^\[/{in_package=0} in_package && /^[[:space:]]*version[[:space:]]*=/ { print $$2; exit }' "$$source_dir/$$version_file")" \
			;; \
			*) \
				echo "Unsupported version file: $$version_file" >&2; \
				exit 1 \
			;; \
		esac; \
		if [ "$$actual_version" != "$$release_version" ]; then \
			echo "$$source_name version update mismatch: expected $$release_version, got $${actual_version:-empty}" >&2; \
			exit 1; \
		fi; \
		changed_paths="$$(git -C "$$source_dir" diff --name-only)"; \
		if [ -z "$$changed_paths" ]; then \
			echo "$$source_name version $$release_version did not change any files." >&2; \
			exit 1; \
		fi; \
		while IFS= read -r changed_path; do \
			case " $$version_paths " in \
				*" $$changed_path "*) ;; \
				*) \
					echo "Version update changed unexpected file: $$changed_path" >&2; \
					exit 1 \
				;; \
			esac; \
		done <<< "$$changed_paths"; \
		git -C "$$source_dir" add -- $$version_paths; \
		if git -C "$$source_dir" diff --cached --quiet; then \
			echo "$$source_name version update produced no staged changes." >&2; \
			exit 1; \
		fi; \
		git -C "$$source_dir" commit -m "chore: bump $(5) version to $$tag"; \
		git -C "$$source_dir" tag "$$tag"; \
		if ! git -C "$$source_dir" push --atomic origin \
			"HEAD:refs/heads/$$source_branch" \
			"refs/tags/$$tag:refs/tags/$$tag"; then \
			echo "Atomic push failed. The local commit and tag $$tag were kept for inspection." >&2; \
			exit 1; \
		fi; \
		source_ref="$$(git -C "$$source_dir" rev-parse "$$tag^{commit}")"; \
		printf '%s\n' "  source_ref:         $$source_ref (pushed)"; \
	;; \
esac
endef
