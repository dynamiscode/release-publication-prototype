#!/usr/bin/env bash
set -euo pipefail

image=${1:?image required}
intents_file=${2:?intents JSON file required}
tags=$(crane ls "$image")
releases='[]'
aliases='{}'

while IFS= read -r tag; do
	[[ -n "$tag" ]] || continue
	if [[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
		intent=$(jq -ce --arg version "$tag" '[.[] | select(.version == $version)] | if length == 1 then .[0] else empty end' "$intents_file") || {
			echo "registry has unapproved stable version tag: $tag" >&2
			exit 1
		}
		merge_sha=$(jq -r '.merge_sha' <<<"$intent")
		candidate_digest=$(crane digest "$image:candidate-$merge_sha")
		digest=$(crane digest "$image:$tag")
		[[ "$digest" == "$candidate_digest" ]] || {
			echo "version tag $tag digest does not match its authorized candidate" >&2
			exit 1
		}
		releases=$(jq -c --arg version "$tag" --arg digest "$digest" '. + [{version:$version,digest:$digest}]' <<<"$releases")
	elif [[ "$tag" == latest || "$tag" =~ ^v(0|[1-9][0-9]*)$ ]]; then
		digest=$(crane digest "$image:$tag")
		aliases=$(jq -c --arg alias "$tag" --arg digest "$digest" '. + {($alias):$digest}' <<<"$aliases")
	elif [[ "$tag" == candidate-* ]]; then
		continue
	else
		echo "unsupported registry tag: $tag" >&2
		exit 1
	fi
done <<<"$tags"

jq -n --argjson releases "$releases" --argjson aliases "$aliases" '{releases:$releases,aliases:$aliases}'
