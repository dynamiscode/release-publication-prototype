#!/usr/bin/env bash
set -euo pipefail

base_branch=${BASE_BRANCH:?BASE_BRANCH required}
repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}
intents='[]'

pr_numbers=$(gh api --paginate \
	"repos/$repo/pulls?state=closed&base=$base_branch&per_page=100" \
	--jq '.[] | select(.merged_at != null and (.head.ref | startswith("release/"))) | .number')

while IFS= read -r pr_number; do
	[[ -n "$pr_number" ]] || continue
	pr=$(gh api "repos/$repo/pulls/$pr_number")
	[[ $(jq -r '.merged_at // empty' <<<"$pr") != "" ]] || continue
	[[ $(jq -r '.base.ref' <<<"$pr") == "$base_branch" ]] || continue
	[[ $(jq -r '.user.login' <<<"$pr") == "github-actions[bot]" ]] || {
		echo "release PR #$pr_number was not authored by GitHub Actions" >&2
		exit 1
	}

	head_ref=$(jq -r '.head.ref' <<<"$pr")
	version=${head_ref#release/}
	if [[ "$head_ref" != "release/$version" || ! "$version" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
		echo "release PR #$pr_number has an invalid version branch: $head_ref" >&2
		exit 1
	fi
	[[ $(jq -r '.head.repo.full_name // empty' <<<"$pr") == "$repo" ]] || {
		echo "release PR #$pr_number head is not in $repo" >&2
		exit 1
	}
	[[ $(jq -r '.head.ref' <<<"$pr") == "release/$version" ]] || {
		echo "release PR #$pr_number head ref does not match its version" >&2
		exit 1
	}
	head_sha=$(jq -r '.head.sha' <<<"$pr")
	merge_sha=$(jq -r '.merge_commit_sha' <<<"$pr")
	git fetch --quiet origin "refs/pull/$pr_number/head:refs/remotes/origin/pr/$pr_number"
	manifest=$(git show "$merge_sha:releases/$version.json")
	[[ $(jq -r '.version' <<<"$manifest") == "$version" ]] || {
		echo "release PR #$pr_number manifest version mismatch" >&2
		exit 1
	}
	source_sha=$(jq -r '.source_sha' <<<"$manifest")
	git merge-base --is-ancestor "$source_sha" "$merge_sha"
	[[ $(git cat-file -t "refs/remotes/origin/pr/$pr_number") == commit ]] || {
		echo "release PR #$pr_number head is not a commit" >&2
		exit 1
	}
	[[ $(git rev-parse "refs/remotes/origin/pr/$pr_number") == "$head_sha" ]] || {
		echo "release PR #$pr_number head moved during reconciliation" >&2
		exit 1
	}
	commits=$(gh api --paginate "repos/$repo/pulls/$pr_number/commits?per_page=100" \
		--jq '.[] | {author: (.author.login // ""), committer: (.committer.login // "")}')
	if ! jq -se 'length > 0 and all(.[]; .author == "github-actions[bot]" and .committer == "github-actions[bot]")' <<<"$commits" >/dev/null; then
		echo "release PR #$pr_number contains a commit not authored and committed by GitHub Actions" >&2
		exit 1
	fi

	reviews=$(gh api --paginate "repos/$repo/pulls/$pr_number/reviews?per_page=100" --jq '.[]')
	latest_review=$(jq -s '[.[] | select(.user.login == "davidlondono")] | sort_by(.submitted_at) | last // empty' <<<"$reviews")
	[[ -n "$latest_review" ]] || {
		echo "release PR #$pr_number has no David review" >&2
		exit 1
	}
	[[ $(jq -r '.state' <<<"$latest_review") == APPROVED && $(jq -r '.commit_id' <<<"$latest_review") == "$head_sha" ]] || {
		echo "release PR #$pr_number lacks a fresh David approval on $head_sha" >&2
		exit 1
	}
	gate_runs=$(gh api --paginate "repos/$repo/commits/$head_sha/check-runs?per_page=100" \
		--jq '.check_runs[] | select(.name == "release-gate" and .app.id == 15368)')
	latest_gate=$(jq -s 'sort_by(.started_at, .id) | last // empty' <<<"$gate_runs")
	[[ -n "$latest_gate" && $(jq -r '.status' <<<"$latest_gate") == completed && $(jq -r '.conclusion' <<<"$latest_gate") == success ]] || {
		echo "release PR #$pr_number latest exact-head release-gate check is not successful" >&2
		exit 1
	}

	intent=$(jq -n \
		--arg pr_number "$pr_number" \
		--arg version "$version" \
		--arg head_sha "$head_sha" \
		--arg merge_sha "$merge_sha" \
		--arg source_sha "$source_sha" \
		--arg fail_after "$(jq -r '.test_fail_after // "none"' <<<"$manifest")" \
		'{pr_number:($pr_number|tonumber),version:$version,head_sha:$head_sha,merge_sha:$merge_sha,source_sha:$source_sha,fail_after:$fail_after}')
	intents=$(jq -c --argjson intent "$intent" '. + [$intent]' <<<"$intents")
done <<<"$pr_numbers"

duplicate=$(jq '[group_by(.version)[] | select(length > 1)] | length' <<<"$intents")
[[ "$duplicate" == 0 ]] || {
	echo "multiple merged release PRs declare the same version" >&2
	exit 1
}
printf '%s\n' "$intents"
