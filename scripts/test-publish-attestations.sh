#!/usr/bin/env bash
set -euo pipefail

export GITHUB_REPOSITORY=example/repo
export GITHUB_WORKFLOW_REF=example/repo/.github/workflows/release.yml@refs/heads/main
source ./scripts/publish-release-intents.sh <(printf '[]') ghcr.io/example/image false

mock_dir="$work_dir/cosign-mock"
mkdir -p "$mock_dir"
export MOCK_BUNDLE="$mock_dir/bundle.json"
export MOCK_COUNT="$mock_dir/attest-count"
cat > "$mock_dir/cosign" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

case "$1" in
	download)
		shift 2
		while (($#)); do
			case "$1" in
				--predicate-type) predicate_type=$2; shift 2 ;;
				*) shift ;;
			esac
		done
		if [[ -s "$MOCK_BUNDLE" ]]; then
			cat "$MOCK_BUNDLE"
		else
			printf "Error: no attestations with predicate type '%s' found\nerror during command execution: no attestations with predicate type '%s' found\n" "$predicate_type" "$predicate_type" >&2
			exit 1
		fi
		;;
	attest)
		shift
		while (($#)); do
			case "$1" in
				--type) predicate_type=$2; shift 2 ;;
				--predicate) predicate_file=$2; shift 2 ;;
				*) ref=$1; shift ;;
			esac
		done
		subject_digest="${ref#*@sha256:}"
		statement=$(jq -cn \
			--arg predicate_type "$predicate_type" \
			--arg subject_digest "$subject_digest" \
			--slurpfile predicate "$predicate_file" \
			'{predicateType:$predicate_type,subject:[{digest:{sha256:$subject_digest}}],predicate:$predicate[0]}')
		payload=$(printf '%s' "$statement" | base64 | tr -d '\n')
		printf '{"dsseEnvelope":{"payload":"%s"}}\n' "$payload" > "$MOCK_BUNDLE"
		printf 'attested\n' >> "$MOCK_COUNT"
		;;
	verify-attestation)
		;;
	*)
		echo "Unexpected cosign command: $*" >&2
		exit 2
		;;
esac
MOCK
chmod +x "$mock_dir/cosign"
cat > "$mock_dir/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == release && "$2" == view && "$MOCK_RELEASE_MODE" == draft ]]; then
	printf '{"databaseId":447003394,"id":"RE_kwDOVvL_Es4apLsC","isDraft":true,"tagName":"v0.1.0","assets":[]}\n'
	exit 0
fi
if [[ "$1" == release && "$2" == view && "$MOCK_RELEASE_MODE" == missing ]]; then
	echo "release not found" >&2
	exit 1
fi
echo "Unexpected gh command: $*" >&2
exit 2
MOCK
chmod +x "$mock_dir/gh"
export PATH="$mock_dir:$PATH"

predicate_type=https://spdx.dev/Document
predicate_file="$work_dir/predicate.json"
printf '{"document":"expected"}\n' > "$predicate_file"
release_json="$work_dir/release.json"
release_error="$work_dir/release.error"
export MOCK_RELEASE_MODE=draft
read_release v0.1.0 "$release_json" "$release_error"
jq -e '.id == 447003394 and .draft == true and .tag_name == "v0.1.0" and .assets == []' "$release_json" >/dev/null
export MOCK_RELEASE_MODE=missing
if read_release v0.1.1 "$release_json" "$release_error"; then
	echo "Missing release was accepted" >&2
	exit 1
else
	[[ $? == 1 ]]
fi
ref=ghcr.io/example/image@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

attest_and_verify "$ref" "$workflow_ref" "$predicate_type" "$predicate_file" "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
attest_and_verify "$ref" "$workflow_ref" "$predicate_type" "$predicate_file" "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
[[ $(wc -l < "$MOCK_COUNT") -eq 1 ]]

if attest_and_verify "$ref" "$workflow_ref" "$predicate_type" "$predicate_file" "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" 2>/dev/null; then
	echo "Mismatched subject was accepted" >&2
	exit 1
fi
[[ $(wc -l < "$MOCK_COUNT") -eq 1 ]]

printf '{"document":"different"}\n' > "$predicate_file"
if attest_and_verify "$ref" "$workflow_ref" "$predicate_type" "$predicate_file" "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" 2>/dev/null; then
	echo "Conflicting predicate was accepted" >&2
	exit 1
fi
[[ $(wc -l < "$MOCK_COUNT") -eq 1 ]]

tag_test_dir="$work_dir/tag-test"
mkdir -p "$tag_test_dir"
git init --bare "$tag_test_dir/remote.git" >/dev/null
git init "$tag_test_dir/repo" >/dev/null
(
	export GIT_CONFIG_GLOBAL=/dev/null
	export GIT_CONFIG_SYSTEM=/dev/null
	export GITHUB_ACTOR=test-user
	export GITHUB_ACTOR_ID=1234
	cd "$tag_test_dir/repo"
	git -c user.name=fixture -c user.email=fixture@example.com commit --allow-empty -m fixture >/dev/null
	git remote add origin "$tag_test_dir/remote.git"
	merge_sha=$(git rev-parse HEAD)
	ensure_git_tag v0.0.1 "$merge_sha"
	[[ $(git cat-file -t refs/tags/v0.0.1) == tag ]]
	[[ $(git for-each-ref --format='%(taggername)|%(taggeremail)' refs/tags/v0.0.1) == \
		'test-user|<1234+test-user@users.noreply.github.com>' ]]
)

echo "Publisher attestation and Git tag identity checks passed"
