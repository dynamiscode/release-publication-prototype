#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

origin="$tmp/origin.git"
repo="$tmp/repo"
mock="$tmp/mock"
mkdir -p "$mock"
git init --bare -q "$origin"
git init -q "$repo"
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.com
git -C "$repo" checkout -qb main
printf 'base\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -qm 'docs: baseline'
source_sha=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" tag v0.1.0
git -C "$repo" checkout -qb release/v0.1.1
mkdir -p "$repo/releases"
jq -n --arg source_sha "$source_sha" '{version:"v0.1.1",source_sha:$source_sha}' > "$repo/releases/v0.1.1.json"
git -C "$repo" add releases/v0.1.1.json
git -C "$repo" commit -qm 'chore(release): prepare v0.1.1'
head_sha=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout -q main
git -C "$repo" merge --no-ff -qm 'Merge release intent' release/v0.1.1
merge_sha=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" remote add origin "$origin"
git -C "$repo" push -q origin main refs/tags/v0.1.0
git -C "$repo" push -q origin "$head_sha:refs/pull/1/head" "$head_sha:refs/pull/2/head"

cat > "$mock/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
url=
for arg in "$@"; do
	if [[ "$arg" == repos/* ]]; then
		url=$arg
	fi
done
scenario=${SCENARIO:-valid}
	case "$url" in
	*/pulls?state=closed*)
		if [[ "$scenario" == no-release-pr ]]; then
			exit 0
		elif [[ "$scenario" == duplicate ]]; then
			printf '1\n2\n'
		else
			printf '1\n'
		fi
		;;
	*/pulls/[12])
		number=${url##*/}
		author=github-actions[bot]
		head_repo=example/repo
		head_sha=${MOCK_HEAD_SHA:?}
		version_ref=release/v0.1.1
		case "$scenario" in
			unauthorized) author=human ;;
			fork) head_repo=attacker/repo ;;
			head-moved) head_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
		esac
		jq -cn \
			--arg author "$author" \
			--arg head_repo "$head_repo" \
			--arg head_sha "$head_sha" \
			--arg head_ref "$version_ref" \
			--arg merge_sha "${MOCK_MERGE_SHA:?}" \
			'{merged_at:"2026-01-01T00:00:00Z",base:{ref:"main"},user:{login:$author},head:{ref:$head_ref,sha:$head_sha,repo:{full_name:$head_repo}},merge_commit_sha:$merge_sha}'
		;;
	*/pulls/[12]/commits?*)
		author=github-actions[bot]
		committer=github-actions[bot]
		[[ "$scenario" != nonbot-commit ]] || author=human
		jq -cn --arg author "$author" --arg committer "$committer" \
			'{author:$author,committer:$committer}'
		;;
	*/pulls/[12]/reviews?*)
		review_state=APPROVED
		review_sha=${MOCK_HEAD_SHA:?}
		case "$scenario" in
			stale-approval) review_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
			rejected-approval) review_state=CHANGES_REQUESTED ;;
		esac
		jq -cn --arg state "$review_state" --arg sha "$review_sha" \
			'{user:{login:"davidlondono"},state:$state,commit_id:$sha,submitted_at:"2026-01-01T00:00:00Z"}'
		;;
	*/commits/*/check-runs?*)
		status=completed
		conclusion=success
		case "$scenario" in
			missing-gate)
				exit 0
				;;
			failed-gate) conclusion=failure ;;
			skipped-gate) conclusion=skipped ;;
			pending-gate) status=in_progress; conclusion=null ;;
			newer-failed-gate)
				printf '%s\n' \
					'{"id":1,"name":"release-gate","app":{"id":15368},"started_at":"2026-01-01T00:00:00Z","status":"completed","conclusion":"success"}' \
					'{"id":2,"name":"release-gate","app":{"id":15368},"started_at":"2026-01-02T00:00:00Z","status":"completed","conclusion":"failure"}'
				exit 0
				;;
		esac
		jq -cn --arg status "$status" --arg conclusion "$conclusion" \
			'{id:1,name:"release-gate",app:{id:15368},started_at:"2026-01-01T00:00:00Z",status:$status,conclusion:$conclusion}'
		;;
	*)
		echo "Unexpected gh API request: $url" >&2
		exit 2
		;;
esac
MOCK
chmod +x "$mock/gh"

run_case() {
	local scenario=$1 expected=$2 expected_error=${3:-}
	local output="$tmp/$scenario.out" error="$tmp/$scenario.err"
	if (
		cd "$repo"
		export PATH="$mock:$PATH"
		export BASE_BRANCH=main GITHUB_REPOSITORY=example/repo
		export MOCK_HEAD_SHA="$head_sha" MOCK_MERGE_SHA="$merge_sha"
		export SCENARIO="$scenario"
		"$root/scripts/discover-release-intents.sh"
	) >"$output" 2>"$error"; then
		status=0
	else
		status=$?
	fi
	if [[ "$expected" == pass && "$status" == 0 ]]; then
		jq -e 'length == 1 and .[0].version == "v0.1.1"' "$output" >/dev/null
		return
	fi
	if [[ "$expected" == empty && "$status" == 0 ]]; then
		jq -e 'length == 0' "$output" >/dev/null
		return
	fi
	if [[ "$expected" == fail && "$status" != 0 && -n "$expected_error" ]] &&
		grep -Fq "$expected_error" "$error"; then
		return
	fi
	echo "$scenario: expected $expected ($expected_error), got status $status" >&2
	cat "$output" "$error" >&2
	exit 1
}

run_case valid pass
run_case no-release-pr empty
run_case unauthorized fail 'was not authored by GitHub Actions'
run_case fork fail 'head is not in example/repo'
run_case head-moved fail 'head moved during reconciliation'
run_case nonbot-commit fail 'contains a commit not authored and committed'
run_case stale-approval fail 'lacks a fresh David approval'
run_case rejected-approval fail 'lacks a fresh David approval'
run_case failed-gate fail 'latest exact-head release-gate check is not successful'
run_case missing-gate fail 'latest exact-head release-gate check is not successful'
run_case skipped-gate fail 'latest exact-head release-gate check is not successful'
run_case pending-gate fail 'latest exact-head release-gate check is not successful'
run_case newer-failed-gate fail 'latest exact-head release-gate check is not successful'
run_case duplicate fail 'multiple merged release PRs declare the same version'

echo "Release intent authorization scenarios passed"
