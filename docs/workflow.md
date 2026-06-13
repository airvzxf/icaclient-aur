# Workflow

Operational conventions for the repo: GitHub labels, status lifecycle, and how the docs / issues / PRs interact.

This document is for contributors who need to *label*, *categorize*, or *find* issues and PRs. For *how to write a PKGBUILD variant* see [`CONTRIBUTING.md`](../CONTRIBUTING.md) and [`docs/alternatives.md`](alternatives.md).

## GitHub labels

We use a fixed set of labels. Apply them when opening the issue or PR; do not invent new ones without updating this document.

### Status of a variant

One per variant. Move the label forward as the variant's status changes (and update the `CHANGELOG.md` entry at the same time).

- `status:proposed` — variant is being discussed; no PKGBUILD yet
- `status:candidate` — a PKGBUILD exists in the repo and is awaiting independent testers
- `status:accepted` — community agrees; ready to be sent upstream to buzo
- `status:rejected` — explicitly ruled out (see the `CHANGELOG.md` entry that explains why)
- `status:informational` — not a real variant, just a historical record (e.g., "we tried webkit2gtk-4.1 as a replacement and it did not work")

### Identity of a variant

- `variant:<name>` — applied to anything tracking a specific variant, where `<name>` matches the directory name under `pkgbuilds/`. Example: `variant:bundle-4.0-icu70`. Use this label on both the issue and the PR for the same variant.

### Cross-cutting

- `needs-tester` — a candidate is ready and is waiting for an independent tester (not the proposer). Apply together with `status:candidate`.
- `test-report` — an issue containing a test result, filed from [`.github/ISSUE_TEMPLATE/test-report.md`](../.github/ISSUE_TEMPLATE/test-report.md).
- `documentation` — docs-only change (no functional effect on a PKGBUILD).
- `upstream-sync` — recording a buzo AUR change in `CHANGELOG.md` (see the "Upstream sync" section there).

## Anti-patterns

- Do not use `bug` for variant proposals — variants are intentional alternatives, not bugs.
- Do not use `enhancement` for upstream-sync entries — they are observations of changes we do not control, not changes we are making.
- Do not stack multiple `status:*` labels on the same issue — pick the one that matches the current state.

## Status lifecycle in code

The same status values appear in three places, and all three should agree:

- the `README.md` of a variant (top of the file, `**Status:**` line),
- the `CHANGELOG.md` entry for the variant (header `proposed` / `candidate` / `accepted` / etc.),
- the GitHub label on the issue and PR for the variant.

When a status changes, update all three.

## See also

- [`CONTRIBUTING.md`](../CONTRIBUTING.md) — how to participate
- [`docs/alternatives.md`](alternatives.md) — evaluated alternatives
- [`pkgbuilds/README.md`](../pkgbuilds/README.md) — variant directory convention
