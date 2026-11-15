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

func digest(char byte) string {
	return "sha256:" + strings.Repeat(string(char), 64)
}
