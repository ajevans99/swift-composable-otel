# Release Policy

This project uses Semantic Versioning and release tags without a `v` prefix, for example `0.3.0`.

## Compatibility and deprecation

Before 1.0:

- Minor releases may contain documented breaking changes.
- Patch releases must remain source compatible and contain fixes or documentation only.
- Public API removals or behavior changes require migration notes in the changelog.

After 1.0:

- Breaking public API, supported-platform, or supported-dependency changes require a major release.
- A public API should be deprecated for at least one minor release before removal in the next
  major release.
- Immediate removal is reserved for a security or correctness issue that cannot be mitigated
  safely; the release notes must explain the exception.

## Changelog convention

Every user-visible pull request adds a concise entry under `CHANGELOG.md`'s `Unreleased` section
using `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, or `Security`. A release moves those
entries into a dated version section and restores an empty `Unreleased` section.

## Release checklist

1. Confirm the release scope and version against the compatibility policy.
2. Update `ComposableOTelMetadata.version` and the README installation requirement to the release
   version. The source version must have no duplicate semantic-version literals.
3. Finalize `CHANGELOG.md`, including migration guidance for behavior or API changes.
4. Confirm `Package.swift` and `SUPPORT.md` agree on platforms and dependency ranges.
5. Confirm the approved repository license is present and referenced by the README.
6. Run baseline validation, strict formatting, minimum/latest dependency builds and tests, and
   every supported-platform CI job.
7. Confirm root `Package.resolved` is not tracked.
8. Merge the release-preparation pull request and record its commit SHA.
9. Create an annotated, immutable tag:

   ```sh
   git tag -a 0.3.0 -m "swift-composable-otel 0.3.0" <release-commit>
   git push origin 0.3.0
   ```

10. Verify `git cat-file -t 0.3.0` reports `tag`, then create a GitHub Release targeting that exact
    tag and commit.
11. Title the GitHub Release `swift-composable-otel 0.3.0`; copy the version's changelog notes,
    link migrations and fixed issues, and mark it as a prerelease only when the version itself is
    a prerelease.
12. Verify the release page, source archive, package resolution, and DocC build from the tag.

Never move or reuse a published tag. If release metadata is wrong, correct the GitHub Release or
publish a new patch version as appropriate.

## Historical metadata

Tags `0.1.0` through `0.2.2` are lightweight tags and have no GitHub Release objects. They remain
unchanged as historical artifacts. The annotated-tag and GitHub Release requirements apply to
all future releases.
