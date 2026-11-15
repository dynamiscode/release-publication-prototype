#!/usr/bin/env bash
set -euo pipefail

mode=${1:?mode required}
base_branch=${BASE_BRANCH:?BASE_BRANCH required}

dispatch_gate() {
	local pr_number=$1
	local ref=$2
	gh workflow run release-prototype.yml \
		--ref "$ref" \
		-f mode=gate \
		-f pr_number="$pr_number"
}

case "$mode" in
prepare)
	version=${VERSION:?VERSION required}
	fail_after=${FAIL_AFTER:-none}
	if [[ ! "$version" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
		echo "unsupported version: $version" >&2
		exit 1
	fi
	case "$fail_after" in
	none | after-candidate | after-version | after-release | after-first-alias) ;;
	*)
		echo "unsupported failure point: $fail_after" >&2
		exit 1
		;;
	esac

	branch="release/$version"
	pr_number=$(gh pr list --state all --base "$base_branch" --head "$GITHUB_REPOSITORY_OWNER:$branch" --json number --jq '.[0].number // empty')
	if [[ -z "$pr_number" ]]; then
		git fetch --quiet origin "$base_branch"
		git switch --create "$branch" "origin/$base_branch"
		mkdir -p releases
		jq -n \
			--arg version "$version" \
			--arg source_sha "$GITHUB_SHA" \
			--arg fail_after "$fail_after" \
			'{version:$version,source_sha:$source_sha,revision:1,test_fail_after:$fail_after}' \
			> "releases/$version.json"
		git config user.name "github-actions[bot]"
		git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
		git add "releases/$version.json"
		git commit -m "chore(release): prepare $version"
		git push origin "$branch"
		gh pr create \
			--base "$base_branch" \
			--head "$branch" \
			--title "Release $version" \
			--body "Synthetic release-intent PR for sandbox proof. Version: $version. Source base: $GITHUB_SHA."
		pr_number=$(gh pr view "$branch" --json number --jq '.number')
	fi

	dispatch_gate "$pr_number" "$branch"
	echo "Release PR #$pr_number; dispatched exact-head gate."
	;;
refresh)
	pr_number=${PR_NUMBER:?PR_NUMBER required}
	pr=$(gh api "repos/$GITHUB_REPOSITORY/pulls/$pr_number")
	[[ $(jq -r '.state' <<<"$pr") == open ]] || {
		echo "release PR is not open" >&2
		exit 1
	}
	branch=$(jq -r '.head.ref' <<<"$pr")
	version=${branch#release/}
	[[ "$branch" == "release/$version" ]] || {
		echo "not a release branch: $branch" >&2
		exit 1
	}

	git fetch --quiet origin "refs/pull/$pr_number/head:refs/remotes/origin/pr/$pr_number"
	git switch --create "refresh/$version" "refs/remotes/origin/pr/$pr_number"
	jq '.revision += 1' "releases/$version.json" > "$RUNNER_TEMP/release.json"
	mv "$RUNNER_TEMP/release.json" "releases/$version.json"
	git config user.name "github-actions[bot]"
	git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
	git add "releases/$version.json"
	git commit -m "chore(release): refresh $version intent"
	git push origin "HEAD:refs/heads/$branch"
	dispatch_gate "$pr_number" "$branch"
	echo "Refreshed release PR #$pr_number; dispatched gate on its new head."
	;;
gate)
	pr_number=${PR_NUMBER:?PR_NUMBER required}
	pr=$(gh api "repos/$GITHUB_REPOSITORY/pulls/$pr_number")
	[[ $(jq -r '.state' <<<"$pr") == open ]] || {
		echo "release PR is not open" >&2
		exit 1
	}
	[[ $(jq -r '.user.login' <<<"$pr") == "github-actions[bot]" ]] || {
		echo "release PR author is not GitHub Actions" >&2
		exit 1
	}
	[[ $(jq -r '.base.ref' <<<"$pr") == "$base_branch" ]] || {
		echo "release PR targets the wrong base branch" >&2
		exit 1
	}
	head_ref=$(jq -r '.head.ref' <<<"$pr")
	version=${head_ref#release/}
	[[ "$head_ref" == "release/$version" ]] || {
		echo "release PR has an invalid branch name" >&2
		exit 1
	}
	[[ $(jq -r '.head.repo.full_name // empty' <<<"$pr") == "$GITHUB_REPOSITORY" ]] || {
		echo "release PR head is not in $GITHUB_REPOSITORY" >&2
		exit 1
	}
	[[ "$GITHUB_REF" == "refs/heads/$head_ref" ]] || {
		echo "gate ref $GITHUB_REF does not match PR head $head_ref" >&2
		exit 1
	}
	head_sha=$(jq -r '.head.sha' <<<"$pr")
	[[ "$head_sha" == "$GITHUB_SHA" ]] || {
		echo "gate SHA $GITHUB_SHA does not match PR head $head_sha" >&2
		exit 1
	}
	manifest=$(git show "$GITHUB_SHA:releases/$version.json")
	[[ $(jq -r '.version' <<<"$manifest") == "$version" ]] || {
		echo "release manifest version does not match branch" >&2
		exit 1
	}
	source_sha=$(jq -r '.source_sha' <<<"$manifest")
	git merge-base --is-ancestor "$source_sha" "$GITHUB_SHA"
	go test ./...
	;;
*)
	echo "unknown release PR mode: $mode" >&2
	exit 2
	;;
esac
