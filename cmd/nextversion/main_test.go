package main

import (
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestDeriveNextVersionFromGitHistory(t *testing.T) {
	repo := initRepo(t)
	initial := commit(t, repo, "docs: initial", "README.md")
	tag(t, repo, initial, "v0.1.0")
	fix := commit(t, repo, "fix: correct output", "fix.txt")

	got, err := deriveNextVersion(repo, fix)
	if err != nil {
		t.Fatal(err)
	}
	if got.Version != "v0.1.1" || !got.Release {
		t.Fatalf("deriveNextVersion() = %+v, want v0.1.1 release", got)
	}
}

func TestDeriveNextVersionSkipsWhenNoReleaseCommit(t *testing.T) {
	repo := initRepo(t)
	initial := commit(t, repo, "docs: initial", "README.md")

	got, err := deriveNextVersion(repo, initial)
	if err != nil {
		t.Fatal(err)
	}
	if got.Release || got.Version != "" {
		t.Fatalf("deriveNextVersion() = %+v, want no release", got)
	}
}

func TestDeriveNextVersionUsesOnlyHistoryAfterLatestStableTag(t *testing.T) {
	repo := initRepo(t)
	first := commit(t, repo, "feat: first feature", "one.txt")
	tag(t, repo, first, "v0.1.0")
	second := commit(t, repo, "fix: second change", "two.txt")
	tag(t, repo, second, "v0.1.1")
	head := commit(t, repo, "feat: third change", "three.txt")

	got, err := deriveNextVersion(repo, head)
	if err != nil {
		t.Fatal(err)
	}
	if got.Version != "v0.2.0" || !got.Release {
		t.Fatalf("deriveNextVersion() = %+v, want v0.2.0 release", got)
	}
}

func initRepo(t *testing.T) string {
	t.Helper()
	repo := t.TempDir()
	git(t, repo, "init", "-q")
	git(t, repo, "config", "user.name", "Test")
	git(t, repo, "config", "user.email", "test@example.com")
	return repo
}

func commit(t *testing.T, repo, message, filename string) string {
	t.Helper()
	if err := exec.Command("sh", "-c", "printf x > \"$1\"", "sh", filepath.Join(repo, filename)).Run(); err != nil {
		t.Fatal(err)
	}
	git(t, repo, "add", filename)
	git(t, repo, "commit", "-qm", message)
	return git(t, repo, "rev-parse", "HEAD")
}

func tag(t *testing.T, repo, sha, name string) {
	t.Helper()
	git(t, repo, "tag", name, sha)
}

func git(t *testing.T, repo string, args ...string) string {
	t.Helper()
	command := exec.Command("git", append([]string{"-C", repo}, args...)...)
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, output)
	}
	return strings.TrimSpace(string(output))
}
