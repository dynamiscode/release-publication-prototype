#!/usr/bin/env bash
set -euo pipefail

mock_dir=$(mktemp -d)
trap 'rm -rf "$mock_dir"' EXIT
export MOCK_TAGS="$mock_dir/tags"
export PATH="$mock_dir:$PATH"
printf '[]\n' > "$mock_dir/intents.json"

cat > "$mock_dir/crane" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == ls ]] || exit 2
cat "$MOCK_TAGS"
MOCK
chmod +x "$mock_dir/crane"

referrer_tag=sha256-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf '%s\n' "$referrer_tag" > "$MOCK_TAGS"
snapshot=$(scripts/registry-snapshot.sh ghcr.io/example/image "$mock_dir/intents.json")
[[ $(jq -c . <<<"$snapshot") == '{"releases":[],"aliases":{}}' ]]

for tag in sha256-not-hex unknown-tag; do
	printf '%s\n' "$tag" > "$MOCK_TAGS"
	if output=$(scripts/registry-snapshot.sh ghcr.io/example/image "$mock_dir/intents.json" 2>"$mock_dir/error"); then
		echo "unsupported tag was accepted: $tag (output: $output)" >&2
		exit 1
	fi
	grep -Fxq "unsupported registry tag: $tag" "$mock_dir/error"
done

echo "Registry snapshot referrer-tag checks passed"
