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
export PATH="$mock_dir:$PATH"

predicate_type=https://spdx.dev/Document
predicate_file="$work_dir/predicate.json"
printf '{"document":"expected"}\n' > "$predicate_file"
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

echo "Publisher attestation idempotency and conflict checks passed"
