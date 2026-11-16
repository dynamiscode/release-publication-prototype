#!/usr/bin/env bash
set -euo pipefail

intents_file=${1:?intents JSON file required}
image=${2:?image name required}
recovery_mode=${3:-false}
repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
workflow_ref="https://github.com/${GITHUB_WORKFLOW_REF:?GITHUB_WORKFLOW_REF is required}"
oidc_issuer=https://token.actions.githubusercontent.com
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

sign_and_verify_image() {
	local ref=$1
	local identity=$2
	local status

	if cosign verify \
		--certificate-identity "$identity" \
		--certificate-oidc-issuer "$oidc_issuer" \
		"$ref" >/dev/null 2>&1; then
		:
	else
		status=$?
		if [[ "$status" != 10 ]]; then
			echo "Cosign image verification failed with status $status" >&2
			return "$status"
		fi
		cosign sign --yes "$ref"
	fi
	cosign verify \
		--certificate-identity "$identity" \
		--certificate-oidc-issuer "$oidc_issuer" \
		"$ref"
}

attestation_matches() {
	local download_file=$1
	local predicate_type=$2
	local predicate_file=$3
	local subject_digest=$4

	jq -e -s \
		--arg predicate_type "$predicate_type" \
		--arg subject_digest "${subject_digest#sha256:}" \
		--slurpfile expected "$predicate_file" '
			length > 0 and all(.[];
				(.dsseEnvelope.payload | @base64d | fromjson) as $statement
				| $statement.predicateType == $predicate_type
				and ($statement.subject | length) == 1
				and $statement.subject[0].digest.sha256 == $subject_digest
				and $statement.predicate == $expected[0]
			)
		' "$download_file" >/dev/null
}

attest_and_verify() {
	local ref=$1
	local identity=$2
	local predicate_type=$3
	local predicate_file=$4
	local subject_digest=$5
	local download_file error_file expected_error expected_error_with_context actual_error status

	download_file=$(mktemp "$work_dir/attestation.XXXXXX")
	error_file=$(mktemp "$work_dir/attestation-error.XXXXXX")
	expected_error="Error: no attestations with predicate type '$predicate_type' found"
	expected_error_with_context=$(printf '%s\n%s' "$expected_error" "error during command execution: no attestations with predicate type '$predicate_type' found")
	if cosign download attestation "$ref" --predicate-type "$predicate_type" >"$download_file" 2>"$error_file"; then
		if [[ ! -s "$download_file" ]]; then
			echo "Cosign attestation download returned no data for $predicate_type" >&2
			return 1
		fi
		if ! attestation_matches "$download_file" "$predicate_type" "$predicate_file" "$subject_digest"; then
			echo "Existing $predicate_type attestation conflicts with expected subject or predicate for $ref" >&2
			return 1
		fi
	else
		status=$?
		actual_error=$(sed -E 's/^[0-9]{4}\/[0-9]{2}\/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} //' "$error_file" | sed '/^$/d')
		if [[ -s "$download_file" || ( "$actual_error" != "$expected_error" && "$actual_error" != "$expected_error_with_context" ) ]]; then
			cat "$error_file" >&2
			return "$status"
		fi
		cosign attest --yes --type "$predicate_type" --predicate "$predicate_file" "$ref"
	fi

	cosign verify-attestation \
		--type "$predicate_type" \
		--certificate-identity "$identity" \
		--certificate-oidc-issuer "$oidc_issuer" \
		"$ref" >/dev/null

	cosign download attestation "$ref" --predicate-type "$predicate_type" >"$download_file" 2>"$error_file" || {
		cat "$error_file" >&2
		return 1
	}
	if ! attestation_matches "$download_file" "$predicate_type" "$predicate_file" "$subject_digest"; then
		echo "Verified $predicate_type attestation does not match expected subject or predicate for $ref" >&2
		return 1
	fi
}

ensure_git_tag() {
	local version=$1
	local merge_sha=$2
	local remote_sha
	local local_ref="refs/prototype/tags/$version"

	remote_sha=$(git ls-remote --refs origin "refs/tags/$version" | awk 'NR == 1 { print $1 }')
	if [[ -n "$remote_sha" ]]; then
		git fetch --quiet --no-tags origin "refs/tags/$version:$local_ref"
		[[ $(git cat-file -t "$local_ref") == tag ]] || {
			echo "Git tag $version is not annotated" >&2
			return 1
		}
		[[ $(git rev-parse "$local_ref^{}") == "$merge_sha" ]] || {
			echo "Git tag $version points at the wrong commit" >&2
			return 1
		}
		return
	fi

	git tag -a "$version" "$merge_sha" -m "Release $version"
	git push origin "refs/tags/$version"
}

build_assets() {
	local version=$1
	local merge_sha=$2
	local digest=$3
	local asset_dir=$4
	local source_dir="$work_dir/source-$version"
	local binary_dir="$work_dir/bin-$version"

	mkdir -p "$source_dir" "$binary_dir" "$asset_dir"
	git archive "$merge_sha" | tar -xf - -C "$source_dir"

	for arch in amd64 arm64; do
		(
			cd "$source_dir"
			GOOS=linux GOARCH="$arch" go build \
				-trimpath \
				-buildvcs=false \
				-ldflags="-X main.version=$version -X main.sourceSHA=$merge_sha" \
				-o "$binary_dir/synthetic" \
				./cmd/synthetic
		)
		tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
			-cf - -C "$binary_dir" synthetic | gzip -n > "$asset_dir/synthetic-linux-$arch.tar.gz"
	done

	jq -n \
		--arg version "$version" \
		--arg source_sha "$merge_sha" \
		--arg image "$image" \
		--arg image_digest "$digest" \
		'{
			version: $version,
			source_sha: $source_sha,
			image: $image,
			image_digest: $image_digest,
			platforms: ["linux/amd64", "linux/arm64"]
		}' > "$asset_dir/release.json"

	(
		cd "$asset_dir"
		sha256sum release.json synthetic-linux-amd64.tar.gz synthetic-linux-arm64.tar.gz > SHA256SUMS
	)
}

verify_or_sign_assets() {
	local version=$1
	local asset_dir=$2
	local existing_dir=$3
	local release_json=$4
	local identity=$5
	local source_assets=(SHA256SUMS release.json synthetic-linux-amd64.tar.gz synthetic-linux-arm64.tar.gz)
	local expected_assets=()
	local readback_dir="$work_dir/readback-$version"
	local asset bundle exists

	for asset in "${source_assets[@]}"; do
		expected_assets+=("$asset" "$asset.sigstore.json")
	done

	while IFS= read -r asset; do
		if [[ ! " ${expected_assets[*]} " == *" $asset "* ]]; then
			echo "Unexpected release asset: $asset" >&2
			return 1
		fi
	done < <(jq -r '.assets[].name' "$release_json")

	for asset in "${source_assets[@]}"; do
		exists=$(jq -r --arg name "$asset" '[.assets[].name] | index($name) != null' "$release_json")
		if [[ "$exists" == true ]]; then
			gh release download "$version" --pattern "$asset" --dir "$existing_dir"
			cmp -s "$asset_dir/$asset" "$existing_dir/$asset" || {
				echo "Release asset conflicts with generated $asset" >&2
				return 1
			}
		fi

		bundle="$asset.sigstore.json"
		exists=$(jq -r --arg name "$bundle" '[.assets[].name] | index($name) != null' "$release_json")
		if [[ "$exists" == true ]]; then
			gh release download "$version" --pattern "$bundle" --dir "$existing_dir"
			cosign verify-blob \
				--bundle "$existing_dir/$bundle" \
				--certificate-identity "$identity" \
				--certificate-oidc-issuer "$oidc_issuer" \
				"$asset_dir/$asset"
		else
			cosign sign-blob --yes --bundle "$asset_dir/$bundle" "$asset_dir/$asset"
			cosign verify-blob \
				--bundle "$asset_dir/$bundle" \
				--certificate-identity "$identity" \
				--certificate-oidc-issuer "$oidc_issuer" \
				"$asset_dir/$asset"
		fi
	done

	for asset in "${expected_assets[@]}"; do
		exists=$(jq -r --arg name "$asset" '[.assets[].name] | index($name) != null' "$release_json")
		if [[ "$exists" == false ]]; then
			gh release upload "$version" "$asset_dir/$asset"
		fi
	done

	mkdir -p "$readback_dir"
	for asset in "${source_assets[@]}"; do
		gh release download "$version" --pattern "$asset" --dir "$readback_dir"
		cmp -s "$asset_dir/$asset" "$readback_dir/$asset" || {
			echo "Release readback differs from generated $asset" >&2
			return 1
		}

		bundle="$asset.sigstore.json"
		gh release download "$version" --pattern "$bundle" --dir "$readback_dir"
		cosign verify-blob \
			--bundle "$readback_dir/$bundle" \
			--certificate-identity "$identity" \
			--certificate-oidc-issuer "$oidc_issuer" \
			"$readback_dir/$asset"
	done
}

publish_one() {
	local intent=$1
	local version merge_sha pr_number fail_after candidate_tag digest ref
	local asset_dir existing_dir release_json release_error release_exists
	local expected_names actual_names release_id
	local index_file sbom_map_file provenance_map_file source_url platform child_digest child_ref sbom_file provenance_file

	version=$(jq -r '.version' <<<"$intent")
	merge_sha=$(jq -r '.merge_sha' <<<"$intent")
	pr_number=$(jq -r '.pr_number' <<<"$intent")
	fail_after=$(jq -r '.fail_after' <<<"$intent")
	[[ "$recovery_mode" == true ]] && fail_after=none

	candidate_tag="candidate-$merge_sha"
	digest=$(crane digest "$image:$candidate_tag")
	ref="$image@$digest"
	echo "Verifying $version from merge $merge_sha at $ref"

	if [[ "$fail_after" == after-candidate ]]; then
		echo "Injected failure after candidate image" >&2
		return 75
	fi

	sign_and_verify_image "$ref" "$workflow_ref"
	index_file="$work_dir/$version.index.json"
	sbom_map_file="$work_dir/$version.sbom-map.json"
	provenance_map_file="$work_dir/$version.provenance-map.json"
	source_url="https://github.com/$repo"
	docker buildx imagetools inspect "$ref" --raw > "$index_file"
	docker buildx imagetools inspect "$ref" --format '{{json .SBOM}}' > "$sbom_map_file"
	docker buildx imagetools inspect "$ref" --format '{{json .Provenance}}' > "$provenance_map_file"
	for platform in linux/amd64 linux/arm64; do
		child_digest=$(jq -er --arg platform "$platform" '
			($platform | split("/")) as $parts
			| [.manifests[] | select(.platform.os == $parts[0] and .platform.architecture == $parts[1]) | .digest] as $digests
			| if ($digests | length) == 1 then $digests[0] else error("expected one manifest for " + $platform) end
		' "$index_file")
		[[ "$child_digest" =~ ^sha256:[a-f0-9]{64}$ ]] || {
			echo "Invalid $platform manifest digest: $child_digest" >&2
			return 1
		}
		child_ref="$image@$child_digest"
		sbom_file="$work_dir/$version-${platform//\//-}.sbom.json"
		provenance_file="$work_dir/$version-${platform//\//-}.provenance.json"
		jq -e --arg platform "$platform" '.[$platform].SPDX | select(type == "object")' "$sbom_map_file" > "$sbom_file"
		jq -e --arg platform "$platform" '.[$platform].SLSA | select(type == "object")' "$provenance_map_file" > "$provenance_file"
		jq -e --arg revision "$merge_sha" --arg source "$source_url" '
			.runDetails.metadata.buildkit_metadata.vcs.revision == $revision and
			.runDetails.metadata.buildkit_metadata.vcs.source == $source and
			.buildDefinition.externalParameters.request.args["build-arg:SOURCE_SHA"] == $revision
		' "$provenance_file" >/dev/null || {
			echo "BuildKit $platform provenance does not identify merge commit $merge_sha from $source_url" >&2
			return 1
		}
		attest_and_verify "$child_ref" "$workflow_ref" https://spdx.dev/Document "$sbom_file" "$child_digest"
		attest_and_verify "$child_ref" "$workflow_ref" https://slsa.dev/provenance/v0.2 "$provenance_file" "$child_digest"
	done

	scripts/reconcile-registry.sh version "$image" "$version" "$digest" "$intents_file" "$fail_after"
	crane manifest "$ref" > "$work_dir/source-index.json"
	crane manifest "$image:$version" > "$work_dir/version-index.json"
	cmp -s "$work_dir/source-index.json" "$work_dir/version-index.json" || {
		echo "Version tag did not preserve the original index bytes" >&2
		return 1
	}
	jq -S '[.manifests[] | {digest,platform}]' "$work_dir/source-index.json" > "$work_dir/source-platforms.json"
	jq -S '[.manifests[] | {digest,platform}]' "$work_dir/version-index.json" > "$work_dir/version-platforms.json"
	cmp -s "$work_dir/source-platforms.json" "$work_dir/version-platforms.json" || {
		echo "Version tag platform descriptors changed" >&2
		return 1
	}
	cosign verify --certificate-identity "$workflow_ref" --certificate-oidc-issuer "$oidc_issuer" "$image:$version"

	ensure_git_tag "$version" "$merge_sha"

	asset_dir="$work_dir/assets-$version"
	existing_dir="$work_dir/existing-$version"
	release_json="$work_dir/release-$version.json"
	release_error="$work_dir/release-$version.error"
	mkdir -p "$asset_dir" "$existing_dir"
	build_assets "$version" "$merge_sha" "$digest" "$asset_dir"

	if gh api "repos/$repo/releases/tags/$version" > "$release_json" 2> "$release_error"; then
		release_exists=true
	elif grep -q 'HTTP 404' "$release_error"; then
		release_exists=false
	else
		cat "$release_error" >&2
		return 1
	fi
	if [[ "$release_exists" == false ]]; then
		gh release create "$version" --draft --verify-tag --title "$version" --notes "Synthetic release for PR #$pr_number at $merge_sha; image $ref."
		gh api "repos/$repo/releases/tags/$version" > "$release_json"
	elif [[ "$(jq -r '.draft' "$release_json")" == false ]]; then
		expected_names=$(printf '%s\n' SHA256SUMS SHA256SUMS.sigstore.json release.json release.json.sigstore.json synthetic-linux-amd64.tar.gz synthetic-linux-amd64.tar.gz.sigstore.json synthetic-linux-arm64.tar.gz synthetic-linux-arm64.tar.gz.sigstore.json | jq -R . | jq -sc 'sort')
		actual_names=$(jq -c '[.assets[].name] | sort' "$release_json")
		if [[ "$actual_names" != "$expected_names" ]]; then
			echo "Published release has an incomplete or unexpected asset set" >&2
			return 1
		fi
	fi
	verify_or_sign_assets "$version" "$asset_dir" "$existing_dir" "$release_json" "$workflow_ref"
	gh api "repos/$repo/releases/tags/$version" > "$release_json"
	expected_names=$(printf '%s\n' SHA256SUMS SHA256SUMS.sigstore.json release.json release.json.sigstore.json synthetic-linux-amd64.tar.gz synthetic-linux-amd64.tar.gz.sigstore.json synthetic-linux-arm64.tar.gz synthetic-linux-arm64.tar.gz.sigstore.json | jq -R . | jq -sc 'sort')
	actual_names=$(jq -c '[.assets[].name] | sort' "$release_json")
	if [[ "$actual_names" != "$expected_names" ]]; then
		echo "Release asset set is incomplete or contains unexpected assets" >&2
		return 1
	fi
	if [[ "$(jq -r '.draft' "$release_json")" == true ]]; then
		release_id=$(jq -r '.id' "$release_json")
		printf '{"draft":false}' | gh api --method PATCH "repos/$repo/releases/$release_id" --input - >/dev/null
	fi
	gh api "repos/$repo/releases/tags/$version" > "$release_json"
	if [[ "$(jq -r '.draft' "$release_json")" != false ]] || [[ "$(jq -c '[.assets[].name] | sort' "$release_json")" != "$expected_names" ]]; then
		echo "Release publish readback did not confirm complete published assets" >&2
		return 1
	fi

	if [[ "$fail_after" == after-release ]]; then
		echo "Injected failure after GitHub release" >&2
		return 75
	fi

	scripts/reconcile-registry.sh aliases "$image" "$version" "$digest" "$intents_file" "$fail_after"
}

while IFS= read -r intent; do
	[[ -n "$intent" ]] || continue
	publish_one "$intent"
done < <(jq -c '.[]' "$intents_file")
