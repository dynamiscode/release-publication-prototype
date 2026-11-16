package releaseplan

import (
	"strings"
	"testing"
)

func TestReconcileCreatesVersionAndInitialAliases(t *testing.T) {
	request := Request{
		Candidate: Release{Version: "v0.1.0", Digest: digest('a')},
		Snapshot:  Snapshot{Aliases: map[string]string{}},
	}

	plan, err := Reconcile(request)
	if err != nil {
		t.Fatal(err)
	}
	if !plan.CreateVersionTag || plan.MoveAliases["latest"] != digest('a') || plan.MoveAliases["v0"] != digest('a') {
		t.Fatalf("unexpected plan: %+v", plan)
	}
}

func TestReconcileMatchingRetryIsNoop(t *testing.T) {
	request := Request{
		Candidate: Release{Version: "v0.1.0", Digest: digest('a')},
		Snapshot: Snapshot{
			Releases: []Release{{Version: "v0.1.0", Digest: digest('a')}},
			Aliases:  map[string]string{"latest": digest('a'), "v0": digest('a')},
		},
	}

	plan, err := Reconcile(request)
	if err != nil {
		t.Fatal(err)
	}
	if plan.CreateVersionTag || len(plan.MoveAliases) != 0 {
		t.Fatalf("retry should be a no-op: %+v", plan)
	}
}

func TestReconcileRejectsVersionTagConflict(t *testing.T) {
	request := Request{
		Candidate: Release{Version: "v0.1.0", Digest: digest('b')},
		Snapshot:  Snapshot{Releases: []Release{{Version: "v0.1.0", Digest: digest('a')}}},
	}

	if _, err := Reconcile(request); err == nil {
		t.Fatal("expected conflicting version digest to fail")
	}
}

func TestReconcileKeepsAliasesMonotonicOnStaleRun(t *testing.T) {
	request := Request{
		Candidate: Release{Version: "v0.1.0", Digest: digest('a')},
		Snapshot: Snapshot{
			Releases: []Release{
				{Version: "v0.1.0", Digest: digest('a')},
				{Version: "v0.1.1", Digest: digest('b')},
			},
			Aliases: map[string]string{"latest": digest('b'), "v0": digest('b')},
		},
	}

	plan, err := Reconcile(request)
	if err != nil {
		t.Fatal(err)
	}
	if plan.CreateVersionTag || len(plan.MoveAliases) != 0 {
		t.Fatalf("stale replay moved state backward: %+v", plan)
	}
}

func TestReconcileUsesHighestStableSemVerPerAlias(t *testing.T) {
	request := Request{
		Candidate: Release{Version: "v0.10.0", Digest: digest('c')},
		Snapshot: Snapshot{
			Releases: []Release{
				{Version: "v0.9.9", Digest: digest('a')},
				{Version: "v1.0.0", Digest: digest('b')},
			},
			Aliases: map[string]string{"latest": digest('b'), "v0": digest('a'), "v1": digest('b')},
		},
	}

	plan, err := Reconcile(request)
	if err != nil {
		t.Fatal(err)
	}
	if !plan.CreateVersionTag || plan.MoveAliases["v0"] != digest('c') {
		t.Fatalf("v0 alias should advance numerically: %+v", plan)
	}
	if _, moved := plan.MoveAliases["latest"]; moved {
		t.Fatalf("latest must remain on v1.0.0: %+v", plan)
	}
}

func TestReconcileRejectsUnknownAliasDigest(t *testing.T) {
	request := Request{
		Candidate: Release{Version: "v0.1.0", Digest: digest('a')},
		Snapshot:  Snapshot{Aliases: map[string]string{"latest": digest('d')}},
	}

	if _, err := Reconcile(request); err == nil {
		t.Fatal("expected an unknown alias target to fail closed")
	}
}

func TestReconcileRejectsUnsupportedVersions(t *testing.T) {
	for _, version := range []string{"v01.0.0", "v1.0.0-rc.1", "v18446744073709551616.0.0"} {
		t.Run(version, func(t *testing.T) {
			request := Request{Candidate: Release{Version: version, Digest: digest('a')}}
			if _, err := Reconcile(request); err == nil {
				t.Fatalf("expected unsupported version %q to fail", version)
			}
		})
	}
}

func TestNextVersionUsesHighestConventionalCommitImpact(t *testing.T) {
	tests := []struct {
		name     string
		tags     []string
		commits  []string
		want     string
		wantBump bool
	}{
		{
			name:     "first release defaults to minor",
			commits:  []string{"fix: correct output"},
			want:     "v0.1.0",
			wantBump: true,
		},
		{
			name:    "no release-worthy commits",
			tags:    []string{"v0.1.0"},
			commits: []string{"docs: clarify setup"},
		},
		{
			name:    "breaking footer on nonconventional commit is ignored",
			tags:    []string{"v0.1.0"},
			commits: []string{"clarify setup\n\nBREAKING CHANGE: not a conventional commit"},
		},
		{
			name:     "fix bumps patch",
			tags:     []string{"v0.1.0"},
			commits:  []string{"fix(cli): correct output"},
			want:     "v0.1.1",
			wantBump: true,
		},
		{
			name:     "feature bumps minor",
			tags:     []string{"v0.1.0"},
			commits:  []string{"feat(api): add endpoint"},
			want:     "v0.2.0",
			wantBump: true,
		},
		{
			name:     "breaking change before one point oh bumps to one point oh",
			tags:     []string{"v0.8.4"},
			commits:  []string{"refactor!: replace old API"},
			want:     "v1.0.0",
			wantBump: true,
		},
		{
			name: "breaking footer wins over feature",
			tags: []string{"v1.2.3"},
			commits: []string{
				"feat: add endpoint",
				"fix: correct output\n\nBREAKING CHANGE: remove old flag",
			},
			want:     "v2.0.0",
			wantBump: true,
		},
		{
			name:     "select highest stable tag",
			tags:     []string{"v0.9.0", "v1.2.3", "v2.0.0-rc.1"},
			commits:  []string{"fix: correct output"},
			want:     "v1.2.4",
			wantBump: true,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, bumped, err := NextVersion(test.tags, test.commits)
			if err != nil {
				t.Fatal(err)
			}
			if got != test.want || bumped != test.wantBump {
				t.Fatalf("NextVersion() = (%q, %t), want (%q, %t)", got, bumped, test.want, test.wantBump)
			}
		})
	}
}

func TestNextVersionRejectsOverflow(t *testing.T) {
	if _, _, err := NextVersion([]string{"v1.0.18446744073709551615"}, []string{"fix: change"}); err == nil {
		t.Fatal("expected version overflow to fail")
	}
}

func digest(char byte) string {
	return "sha256:" + strings.Repeat(string(char), 64)
}
