# icaclient-aur

Collaborative workspace for maintaining [`icaclient`](https://aur.archlinux.org/packages/icaclient) on AUR, currently focused on the `webkit2gtk-4.0` dependency problem.

> **Status (2026-06-11):** strategy phase. No candidate PKGBUILD yet — we are collecting test data and writing down what has been tried before proposing anything to the maintainer.
>
> See [CHANGELOG.md](CHANGELOG.md) for the decision log and [TESTING.md](TESTING.md) for how to help.

## How to read this repo

- **As a tester:** start at [TESTING.md](TESTING.md). Pick a scenario that matches your setup, run it, open a Test report issue (template provided by GitHub).
- **As a developer proposing a PKGBUILD variant:** read [docs/alternatives.md](docs/alternatives.md) first to see what is on the table, then [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow.
- **As a reviewer:** browse the [open issues](../../issues) and [pull requests](../../pulls); see [docs/workflow.md](docs/workflow.md) for the labels schema.

## What is the problem?

Citrix's `selfservice` and the dialog library `UIDialogLibWebKit3.so` (loaded by `wfica` at runtime) were compiled against the **webkit2gtk-4.0** ABI, which uses **libsoup-2.4**. Arch dropped the `webkit2gtk` (4.0 ABI) metapackage from the official repositories; only `webkit2gtk-4.1` and `webkitgtk-6.0` remain, both of which use **libsoup-3.0** and are **not ABI-compatible** with -4.0. The `webkit2gtk` (4.0 ABI) package now lives only in the AUR, and compiling it from source takes several hours.

A symlink hack (`libwebkit2gtk-4.0.so.37 → libwebkit2gtk-4.1.so.0`) appears to "work" for some users but actually crashes for anyone using `selfservice` or the `wfica` connection dialog. See [docs/webkit2gtk-abi.md](docs/webkit2gtk-abi.md) for the full technical background.

## What is in this repo

| Path | Purpose |
|---|---|
| [`README.md`](README.md) | This file |
| [`TESTING.md`](TESTING.md) | Test matrix and reporting protocol |
| [`CHANGELOG.md`](CHANGELOG.md) | Decision log, upstream sync log, and "in progress" pointer |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | How to participate as tester, developer, or reviewer |
| [`docs/`](docs/) | Technical background, evaluated alternatives, glossary |
| [`docs/workflow.md`](docs/workflow.md) | Operational conventions: labels, status lifecycle |
| [`docs/test-matrix-template.md`](docs/test-matrix-template.md) | Reusable template for variant test matrices |
| [`docs/testing-infrastructure.md`](docs/testing-infrastructure.md) | Testing tooling: the 5 layers (L0-L4), clean builds, GUI smoke testing, display/audio/GPU forwarding |
| [`pkgbuilds/`](pkgbuilds/) | Proposed PKGBUILD variants, one subdirectory per variant (see [`pkgbuilds/README.md`](pkgbuilds/README.md)) |
| [`.github/`](.github/) | Issue and PR templates (test report, variant proposal) |

## How to participate

- **As a tester:** read [TESTING.md](TESTING.md), pick a scenario that matches your setup, open a GitHub issue with the report template filled in.
- **As a developer with a PKGBUILD variant idea:** read [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/alternatives.md](docs/alternatives.md) first.
- **As a reviewer:** comment on open issues, run someone else's variant on your machine, update the test matrix.

## What this repo is NOT

- Not a fork of the AUR git. The maintainer (buzo) is the one who merges to AUR. We propose; they decide.
- Not a place for bug reports against the Citrix software itself. Use [Citrix support](https://www.citrix.com/support/) for that.
- Not a place to package different versions of Citrix Workspace. There is exactly one upstream tarball per release; we work with that.

## In progress

Active variant proposals and their state. Updated when a contributor starts, pauses, or finishes a variant. Conventions and naming rules live in [`pkgbuilds/README.md`](pkgbuilds/README.md).

- **`add-lldpd-bind-optdeps`** (proposed) — adds `lldpd` and `bind` to `optdepends=`. Diff vs upstream is 3 lines (a variant comment + 2 optdepends entries); the 9 support files are byte-identical copies of `latest/`. Targets two AUR-reported issues: the `lldpcli: command not found` log line (capadocia, bstrdsmkr) and the first-launch selfservice StoreFront DNS failure (ironhak). Lowest-risk variant in the repo; ready for L0+L2 + e-mail to buzo. See [`pkgbuilds/add-lldpd-bind-optdeps/`](pkgbuilds/add-lldpd-bind-optdeps/) and the [`CHANGELOG.md`](CHANGELOG.md) 2026-06-12 entry "Variant `add-lldpd-bind-optdeps`".
- **`bundle-4.0-icu70`** (proposed) — D.3 variant, the most ambitious candidate. Extracts the prebuilt `webkit2gtk-4.0` Debian bundle that Citrix ships inside the upstream tarball, copies it to `$ICAROOT/lib/`, sets `RUNPATH` / `RPATH` on the Citrix binaries and the WebKit helpers, and string-patches the hardcoded `/usr/lib/<arch>-linux-gnu/webkit2gtk-4.0/...` paths. `libsoup-2.4.so.1` is extracted from a `libsoup2.4-1` Debian .deb pinned to bookworm (the bundle does not contain libsoup, per the [2026-06-12 CHANGELOG](CHANGELOG.md) entry on the bundle's actual contents). Implementation plan in [`docs/d3-bundle-implementation-plan.md`](docs/d3-bundle-implementation-plan.md); the candidate's PKGBUILD is under [`pkgbuilds/bundle-4.0-icu70/`](pkgbuilds/bundle-4.0-icu70/). The biggest open item is verifying the `LIBSOUP_DEB_VERSION=2.74.3-1+deb12u1` URL and replacing the `SKIP` sha256 with a real hash before sending to buzo. L0 namcap + bash -n + end-to-end simulation of the 7 install phases are clean on the dev host; L2 chroot build + S1-S3 smoke test are the next gates.

## Acknowledgments

- **buzo (Stephan Springer)** — current AUR maintainer, receptive to patches via e-mail (`buzo+arch@Lini.de`).
- All the commenters on the [AUR thread](https://aur.archlinux.org/packages/icaclient) whose findings made this work possible: codemonkey777, bstrdsmkr, mag37, ironhak, rogueai, johnnybash, stoffel, yrf, cziss, megamik, RiskCapCap, kleinph, emild, JohnDoe79, Drake, mm-germany, and anyone I missed. (See [CHANGELOG.md](CHANGELOG.md) for the specific contributions.)

## License

This coordination repo is MIT (see [LICENSE](LICENSE)). The `pkgbuilds/` directory will contain PKGBUILDs derived from the AUR one (also MIT) plus the upstream Citrix tarball (LicenseRef-Citrix, non-redistributable — the PKGBUILDs reference it but the tarball itself must be downloaded by the builder, not committed here).
