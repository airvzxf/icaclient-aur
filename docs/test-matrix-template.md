# Test matrix template

Reusable matrix for tracking who has tested a candidate PKGBUILD variant and with what result. Copy the body of this file into a new issue titled `Test matrix: <variant-name>` once a candidate exists. Testers then add one row per tester to each table.

## Header (fill in once per matrix)

- **Variant:** `pkgbuilds/<variant-name>/`
- **Based on:** (upstream AUR PKGBUILD @ pkgrel=N, or commit SHA of this repo used as baseline)
- **Source of truth:** (link to the variant's `README.md` and the `CHANGELOG.md` entry)

## Testers and their configurations

| Tester | Distro / kernel | Display | AUR helper | webkit2gtk installed? | libsoup installed? | Test report |
|---|---|---|---|---|---|---|
| @handle1 | Arch / 6.12.6 | X11 | yay | none (variant provides) | 2.74.3 (`[extra]`) | #N |
| @handle2 |  |  |  |  |  |  |
| @handle3 |  |  |  |  |  |  |

> The "webkit2gtk installed?" column answers the key question: does this test confirm the variant works *without* the AUR `webkit2gtk` package? "none" or "removed for this test" is the interesting case (scenario S4).

## Scenario results

One row per tester. Mark each scenario ✅ pass, ❌ fail, or ⏭️ skipped (with the reason in the linked test report). The full scenario list (S1-S7) lives in [`TESTING.md`](../TESTING.md).

| Tester | S1 | S2 | S3 | S4 | S5 | S6 | S7 |
|---|---|---|---|---|---|---|---|
| @handle1 | ✅ | ✅ | ✅ | ✅ | 3:42 | ⏭️ no farm | ✅ |
| @handle2 |  |  |  |  |  |  |  |
| @handle3 |  |  |  |  |  |  |  |

## How to add yourself

1. Open a test report issue using [`.github/ISSUE_TEMPLATE/test-report.md`](../.github/ISSUE_TEMPLATE/test-report.md).
2. Add a row to each table above, linking to your test report in the first table's last column.
3. Mark skipped scenarios `⏭️` and explain the reason in your test report.

## Promotion signal

A variant is ready to move from `status:candidate` to `status:accepted` when:

- At least 2 independent testers have rows in both tables.
- All filled cells are ✅, OR any ❌ is documented in the `CHANGELOG.md` entry as "out of scope for this variant".
- This matches the criteria in [`docs/alternatives.md`](alternatives.md) (section "Promotion criteria").
