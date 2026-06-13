---
name: Variant proposal
about: Propose a new PKGBUILD variant before writing code
title: 'Variant proposal: <descriptive-name>'
labels: ['status:proposed']
assignees: []
---

**Proposed variant directory name (kebab-case):**

`pkgbuilds/<name>/`

> Names should describe the *change vs upstream*. Good: `bundle-4.0-icu70`, `optdepends-minimal`. Bad: `v2`, `test`, `my-fix`. See [`pkgbuilds/README.md`](../../pkgbuilds/README.md).

**One-sentence summary of the change vs upstream:**

**Problem it solves:**

**Link to the relevant section in `docs/alternatives.md` (if it exists):**

> If your idea is not yet in `docs/alternatives.md`, add a section there first, then link it here.

**Evidence / prior art (at minimum one of):**

- `ldd` output showing the dependency
- `readelf -d ... | grep NEEDED` output
- `journalctl` / log excerpt
- A similar approach already in another AUR package

**Status of the PKGBUILD itself:**

- [ ] Not yet (this is a discussion issue, open to gather feedback first)
- [ ] Drafted locally, not yet committed: <branch / fork URL>
- [ ] Drafted and committed to this repo: <branch name>

**Self-test scenarios run so far (per `TESTING.md`):**

| Scenario | Result |
|---|---|
| S1 | ✅ / ❌ / ⏭️ |
| S2 | ✅ / ❌ / ⏭️ |
| S3 | ✅ / ❌ / ⏭️ |
| S4 | ✅ / ❌ / ⏭️ |
| S5 | ✅ / ❌ |
| S6 | ✅ / ❌ / ⏭️ |
| S7 | ✅ / ❌ |

**Scenarios you do NOT plan to test yourself, and why:**

> (e.g., "no real Citrix farm, S6 will need a second tester")
