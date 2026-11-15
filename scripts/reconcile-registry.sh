#!/usr/bin/env bash
set -euo pipefail

mode=${1:?mode required}
image=${2:?image required}
version=${3:?version required}
digest=${4:?digest required}
intents_file=${5:?intents JSON file required}
fail_after=${6:-none}

snapshot=$(scripts/registry-snapshot.sh "$image" "$intents_file")
request=$(jq -n \
	--arg version "$version" \
	--arg digest "$digest" \
	--argjson snapshot "$snapshot" \
	'{candidate:{version:$version,digest:$digest},snapshot:$snapshot}')
plan=$(go run ./cmd/reconcile <<<"$request")

case "$mode" in
version)
	if [[ $(jq -r '.create_version_tag' <<<"$plan") == true ]]; then
		crane tag "$image@$digest" "$version"
	fi
	[[ $(crane digest "$image:$version") == "$digest" ]] || {
		echo "version tag did not resolve to candidate digest" >&2
		exit 1
	}
	if [[ "$fail_after" == after-version ]]; then
		echo "injected failure after version tag" >&2
		exit 75
	fi
	;;
aliases)
	[[ $(jq -r '.create_version_tag' <<<"$plan") == false ]] || {
		echo "cannot reconcile aliases before version tag exists" >&2
		exit 1
	}
	alias_count=0
	while IFS=$'\t' read -r alias target; do
		[[ -n "$alias" ]] || continue
		crane tag "$image@$target" "$alias"
		[[ $(crane digest "$image:$alias") == "$target" ]] || {
			echo "alias $alias did not resolve to $target" >&2
			exit 1
		}
		alias_count=$((alias_count + 1))
		if [[ "$fail_after" == after-first-alias && "$alias_count" -eq 1 ]]; then
			echo "injected failure after first alias" >&2
			exit 75
		fi
	done < <(jq -r '.move_aliases | to_entries[] | [.key,.value] | @tsv' <<<"$plan")
	;;
*)
	echo "unknown reconciliation mode: $mode" >&2
	exit 2
	;;
esac

printf '%s\n' "$plan"
