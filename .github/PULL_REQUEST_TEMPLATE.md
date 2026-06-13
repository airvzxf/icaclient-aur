## Variant

> `pkgbuilds/<name>/`

## CHANGELOG entry

> Link to the `CHANGELOG.md` entry describing this variant (search by date or title).

## Proposal issue (if any)

> #N, or "no proposal issue; this PR opens the discussion"

## Based on

> Upstream AUR PKGBUILD @ pkgrel=N, or commit SHA / branch of this repo used as the baseline.

## Diff vs upstream

```diff
(paste `git diff <upstream> -- PKGBUILD` here, or attach as a file)
```

## Self-tests run (TESTING.md scenarios)

| Scenario | Result | Evidence |
|---|---|---|
| S1 selfservice | ✅ / ❌ / ⏭️ |  |
| S2 wfica .ica | ✅ / ❌ / ⏭️ |  |
| S3 wfica dialog | ✅ / ❌ / ⏭️ |  |
| S4 no AUR webkit | ✅ / ❌ / ⏭️ |  |
| S5 build time | ✅ / ❌ | (time) |
| S6 real session | ✅ / ❌ / ⏭️ |  |
| S7 no new deps | ✅ / ❌ |  |

## Scenarios NOT run and why

> (e.g., "S6: no real Citrix farm")

## Checklist

- [ ] `pkgbuilds/<name>/README.md` follows the template in [`pkgbuilds/README.md`](pkgbuilds/README.md)
- [ ] `CHANGELOG.md` has an entry for this variant
- [ ] At least one scenario from `TESTING.md` has been run by the PR author
- [ ] The variant does NOT silently regress `libsoup` to `optdepends=` (see `CHANGELOG.md` 2026-06-11)
- [ ] Diff vs upstream is small and focused (target: under 50 lines)
