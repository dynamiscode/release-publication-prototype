# release-publication-prototype

Synthetic-only prototype for merge-authorized releases and GHCR digest promotion. Throwaway; no production code or secrets.

## Run

Temporarily set the repository default branch to `prototype/merge-authorized`, then:

```sh
gh workflow run release-prototype.yml \
  --ref prototype/merge-authorized \
  -f mode=prepare \
  -f fail_after=none
```

The workflow derives the next stable version from Conventional Commits since the latest reachable stable tag. `feat` selects a minor bump, `fix` a patch bump, and a breaking change a major bump; the highest impact wins. The first release is `v0.1.0`; breaking changes before `v1.0.0` select `v1.0.0`. If no release-worthy commit exists, no PR is opened.

Wait for the `release-gate` check, approve the bot-authored release PR as David, and merge it. The merge triggers publication from that exact merge commit.

To exercise recovery, prepare with `fail_after=after-candidate`, `after-version`, `after-release`, or `after-first-alias`; then run:

```sh
gh workflow run release-prototype.yml --ref prototype/merge-authorized -f mode=retry
```

Use `mode=refresh -f pr_number=<number>` to bot-update a release PR and verify stale approval is dismissed.

GHCR creates the package private initially. A package admin must change it to public in the package settings; public visibility cannot be reversed. Keep contents synthetic. After the proof, restore the default branch to `main`.

## Limitation

GitHub's ruleset bypass actor is the entire GitHub Actions integration, not one workflow. The sandbox allows that integration to create version tags, so another Actions workflow granted `contents:write` could also create them. This prototype cannot prove workflow-level isolation.
