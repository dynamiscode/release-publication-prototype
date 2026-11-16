package releaseplan

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

type Release struct {
	Version string `json:"version"`
	Digest  string `json:"digest"`
}

type Snapshot struct {
	Releases []Release         `json:"releases"`
	Aliases  map[string]string `json:"aliases"`
}

type Request struct {
	Candidate Release  `json:"candidate"`
	Snapshot  Snapshot `json:"snapshot"`
}

type Plan struct {
	CreateVersionTag bool              `json:"create_version_tag"`
	MoveAliases      map[string]string `json:"move_aliases"`
}

var (
	stableVersion = regexp.MustCompile(`^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$`)
	sha256Digest  = regexp.MustCompile(`^sha256:[a-f0-9]{64}$`)
	majorAlias    = regexp.MustCompile(`^v(0|[1-9][0-9]*)$`)
	commitHeader  = regexp.MustCompile(`^([a-z][a-z0-9-]*)(\([^()\r\n]+\))?(!)?: .+`)
	breakingNote  = regexp.MustCompile(`(?m)^BREAKING[- ]CHANGE:`)
)

type parsedVersion struct {
	major uint64
	minor uint64
	patch uint64
	text  string
}

// NextVersion derives the next stable version from commits since the latest stable tag.
func NextVersion(tags, commitMessages []string) (string, bool, error) {
	impact := 0
	for _, message := range commitMessages {
		header := commitHeader.FindStringSubmatch(strings.SplitN(message, "\n", 2)[0])
		switch {
		case len(header) == 4 && (header[3] == "!" || breakingNote.MatchString(message)):
			impact = 3
		case len(header) == 4 && header[1] == "feat" && impact < 2:
			impact = 2
		case len(header) == 4 && header[1] == "fix" && impact < 1:
			impact = 1
		}
	}
	if impact == 0 {
		return "", false, nil
	}

	current, err := latestStableVersion(tags)
	if err != nil {
		return "", false, err
	}
	if current.text == "" {
		return "v0.1.0", true, nil
	}

	switch impact {
	case 3:
		if current.major == 0 {
			current.major = 1
		} else if current.major == ^uint64(0) {
			return "", false, fmt.Errorf("major version overflow")
		} else {
			current.major++
		}
		current.minor, current.patch = 0, 0
	case 2:
		if current.minor == ^uint64(0) {
			return "", false, fmt.Errorf("minor version overflow")
		}
		current.minor++
		current.patch = 0
	case 1:
		if current.patch == ^uint64(0) {
			return "", false, fmt.Errorf("patch version overflow")
		}
		current.patch++
	}
	return fmt.Sprintf("v%d.%d.%d", current.major, current.minor, current.patch), true, nil
}

// LatestStableTag returns the highest reachable stable SemVer tag.
func LatestStableTag(tags []string) (string, error) {
	version, err := latestStableVersion(tags)
	return version.text, err
}

func latestStableVersion(tags []string) (parsedVersion, error) {
	var current parsedVersion
	for _, tag := range tags {
		match := stableVersion.FindStringSubmatch(tag)
		if len(match) != 4 {
			continue
		}
		values := make([]uint64, 3)
		for i, part := range match[1:] {
			value, err := strconv.ParseUint(part, 10, 64)
			if err != nil {
				return parsedVersion{}, fmt.Errorf("invalid stable tag %q: %w", tag, err)
			}
			values[i] = value
		}
		candidate := parsedVersion{major: values[0], minor: values[1], patch: values[2], text: tag}
		if current.text == "" || compareVersion(candidate, current) > 0 {
			current = candidate
		}
	}
	return current, nil
}

func Reconcile(request Request) (Plan, error) {
	candidate, err := parseRelease(request.Candidate)
	if err != nil {
		return Plan{}, fmt.Errorf("candidate: %w", err)
	}

	releases := make(map[string]Release, len(request.Snapshot.Releases)+1)
	for _, release := range request.Snapshot.Releases {
		if _, err := parseRelease(release); err != nil {
			return Plan{}, fmt.Errorf("snapshot release: %w", err)
		}
		if prior, exists := releases[release.Version]; exists && prior.Digest != release.Digest {
			return Plan{}, fmt.Errorf("version %s has conflicting digests", release.Version)
		}
		releases[release.Version] = release
	}

	createVersionTag := true
	if prior, exists := releases[candidate.text]; exists {
		if prior.Digest != request.Candidate.Digest {
			return Plan{}, fmt.Errorf("version %s already points to %s, not %s", candidate.text, prior.Digest, request.Candidate.Digest)
		}
		createVersionTag = false
	} else {
		releases[candidate.text] = request.Candidate
	}

	versions := make([]parsedVersion, 0, len(releases))
	for _, release := range releases {
		version, err := parseRelease(release)
		if err != nil {
			return Plan{}, err
		}
		versions = append(versions, version)
	}

	desired := desiredAliases(versions, releases)
	moves := make(map[string]string)
	for alias := range request.Snapshot.Aliases {
		if _, exists := desired[alias]; !exists {
			return Plan{}, fmt.Errorf("alias %s has no eligible stable release", alias)
		}
	}

	for alias, target := range desired {
		currentDigest := request.Snapshot.Aliases[alias]
		if currentDigest == "" {
			moves[alias] = target.Digest
			continue
		}
		if currentDigest == target.Digest {
			continue
		}

		current, found := highestMatchingDigest(versions, releases, currentDigest, alias)
		if !found {
			return Plan{}, fmt.Errorf("alias %s points to unknown digest %s", alias, currentDigest)
		}
		if compareVersion(current, target.Version) > 0 {
			return Plan{}, fmt.Errorf("alias %s would move backward from %s to %s", alias, current.text, target.Version.text)
		}
		if compareVersion(current, target.Version) == 0 {
			return Plan{}, fmt.Errorf("alias %s has a conflicting digest for %s", alias, target.Version.text)
		}
		moves[alias] = target.Digest
	}

	return Plan{CreateVersionTag: createVersionTag, MoveAliases: moves}, nil
}

type aliasTarget struct {
	Version parsedVersion
	Digest  string
}

func desiredAliases(versions []parsedVersion, releases map[string]Release) map[string]aliasTarget {
	desired := make(map[string]aliasTarget)
	var latest parsedVersion
	for _, version := range versions {
		release := releases[version.text]
		if latest.text == "" || compareVersion(version, latest) > 0 {
			latest = version
		}
		alias := "v" + strconv.FormatUint(version.major, 10)
		current, exists := desired[alias]
		if !exists || compareVersion(version, current.Version) > 0 {
			desired[alias] = aliasTarget{Version: version, Digest: release.Digest}
		}
	}
	desired["latest"] = aliasTarget{Version: latest, Digest: releases[latest.text].Digest}
	return desired
}

func highestMatchingDigest(versions []parsedVersion, releases map[string]Release, digest, alias string) (parsedVersion, bool) {
	var highest parsedVersion
	found := false
	majorFilter := uint64(0)
	filterMajor := false
	if alias != "latest" {
		match := majorAlias.FindStringSubmatch(alias)
		if len(match) != 2 {
			return parsedVersion{}, false
		}
		majorFilter, _ = strconv.ParseUint(match[1], 10, 64)
		filterMajor = true
	}
	for _, version := range versions {
		if filterMajor && version.major != majorFilter {
			continue
		}
		if releases[version.text].Digest != digest {
			continue
		}
		if !found || compareVersion(version, highest) > 0 {
			highest = version
			found = true
		}
	}
	return highest, found
}

func parseRelease(release Release) (parsedVersion, error) {
	if !sha256Digest.MatchString(release.Digest) {
		return parsedVersion{}, fmt.Errorf("invalid digest %q", release.Digest)
	}
	match := stableVersion.FindStringSubmatch(release.Version)
	if len(match) != 4 {
		return parsedVersion{}, fmt.Errorf("unsupported stable version %q", release.Version)
	}
	values := make([]uint64, 3)
	for i, part := range match[1:] {
		value, err := strconv.ParseUint(part, 10, 64)
		if err != nil {
			return parsedVersion{}, fmt.Errorf("invalid version %q: %w", release.Version, err)
		}
		values[i] = value
	}
	return parsedVersion{major: values[0], minor: values[1], patch: values[2], text: release.Version}, nil
}

func compareVersion(a, b parsedVersion) int {
	if a.major != b.major {
		if a.major < b.major {
			return -1
		}
		return 1
	}
	if a.minor != b.minor {
		if a.minor < b.minor {
			return -1
		}
		return 1
	}
	if a.patch != b.patch {
		if a.patch < b.patch {
			return -1
		}
		return 1
	}
	return 0
}
