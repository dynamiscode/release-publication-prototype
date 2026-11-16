package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/dynamiscode/release-publication-prototype/internal/releaseplan"
)

type versionPlan struct {
	Version string `json:"version"`
	Release bool   `json:"release"`
}

func main() {
	if len(os.Args) != 2 {
		fatal(fmt.Errorf("usage: nextversion <commit>"))
	}
	plan, err := deriveNextVersion(".", os.Args[1])
	if err != nil {
		fatal(err)
	}
	if err := json.NewEncoder(os.Stdout).Encode(plan); err != nil {
		fatal(err)
	}
}

func deriveNextVersion(repo, target string) (versionPlan, error) {
	commit, err := gitOutput(repo, "rev-parse", "--verify", "--end-of-options", target+"^{commit}")
	if err != nil {
		return versionPlan{}, fmt.Errorf("resolve target commit: %w", err)
	}

	tagOutput, err := gitOutput(repo, "tag", "--merged", commit)
	if err != nil {
		return versionPlan{}, fmt.Errorf("list reachable tags: %w", err)
	}
	var tags []string
	if tagOutput != "" {
		tags = strings.Split(tagOutput, "\n")
	}
	latestTag, err := releaseplan.LatestStableTag(tags)
	if err != nil {
		return versionPlan{}, err
	}

	revision := commit
	if latestTag != "" {
		revision = latestTag + ".." + commit
	}
	logOutput, err := gitOutput(repo, "log", "--format=%B%x00", revision)
	if err != nil {
		return versionPlan{}, fmt.Errorf("read commit messages: %w", err)
	}
	var messages []string
	for _, message := range strings.Split(logOutput, "\x00") {
		if message = strings.TrimSpace(message); message != "" {
			messages = append(messages, message)
		}
	}

	version, release, err := releaseplan.NextVersion(tags, messages)
	if err != nil {
		return versionPlan{}, err
	}
	return versionPlan{Version: version, Release: release}, nil
}

func gitOutput(repo string, args ...string) (string, error) {
	command := exec.Command("git", append([]string{"-C", repo}, args...)...)
	output, err := command.Output()
	return strings.TrimSpace(string(output)), err
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
