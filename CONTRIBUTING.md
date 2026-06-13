# Contributing

Three ways to help. Pick the one that matches your time and your setup.

---

## As a tester

**You don't need to know PKGBUILD internals.** You need:
- An Arch-based system (Arch, Manjaro, Endeavour, etc.)
- The ability to run `pacman`, `makepkg`, and Citrix binaries
- 30-60 minutes per scenario

**Steps:**

1. Read [TESTING.md](TESTING.md) end-to-end (5 min), and skim [docs/testing-infrastructure.md](docs/testing-infrastructure.md) (5 min) for the tooling layer.
2. Wait for a candidate PKGBUILD to be posted under `pkgbuilds/` (we'll announce in Issues).
3. Once one is up, pick the scenarios that match your setup. S1 (selfservice launch) and S4 (install without webkit2gtk) are the two that catch the most regressions.
4. Run them. Collect the five outputs listed in the "Local checklist" section of TESTING.md.
5. Open a GitHub issue with the report template filled in.

**What you should NOT do:**
- Don't propose new PKGBUILD variants in your test report. Open a separate issue.
- Don't commit to the repo. Just open issues.
- Don't worry about breaking your system. S4 (uninstall webkit2gtk, reinstall) is reversible.

---

## As a developer (proposing a PKGBUILD variant)

**Steps:**

1. Read [docs/alternatives.md](docs/alternatives.md) to see what's already on the table. If your idea isn't there as a section, add it *first*, before writing code. Also skim [docs/testing-infrastructure.md](docs/testing-infrastructure.md) for how your variant will be tested (so you know what "tested" means before you claim it).
2. Read the upstream AUR PKGBUILD: `git clone https://aur.archlinux.org/icaclient.git` or browse https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=icaclient.
3. Read the [CHANGELOG.md](CHANGELOG.md) decisions. Do not propose anything that contradicts an `accepted` decision.
4. Create a directory `pkgbuilds/<descriptive-name>/` containing at minimum a `PKGBUILD` (no extension, matching AUR) and a `README.md` explaining the variant. Use kebab-case in the directory name. Examples of good names:
   - `bundle-4.0-icu70/`
   - `optdepends-minimal/`
   - `imgpaste-dep/`
   - `no-bundle-baseline-v2/`

   Bad names: `my-fix/`, `v2/`, `test/`, `foo/`. The name should tell the reader what is different vs upstream.

   See [`pkgbuilds/README.md`](pkgbuilds/README.md) for the full convention, the internal structure, and the README template.
5. In the **same commit** (or at least the same PR), update [CHANGELOG.md](CHANGELOG.md) with a new decision entry. The entry must include:
   - A one-line title describing the variant
   - The status (`proposed` until promoted)
   - Rationale: what problem does this solve, and what tradeoff does it make
   - Evidence: at least one concrete thing you tested (output, ldd, or a real session)
6. Open a GitHub PR with title `Proposal: <descriptive-name>`. In the PR description:
   - Link the relevant CHANGELOG entry
   - List which scenarios from TESTING.md you ran yourself
   - List which scenarios you did NOT run and why (e.g., "no real Citrix farm")
7. **Do not propose a variant you haven't tested yourself on at least one machine.** "Should work" is not a test result. If you can only verify ldd resolves, say so explicitly.

---

## As a reviewer

**Steps:**

1. Watch the Issues and PRs.
2. When a new proposal is opened, read:
   - The variant file under `pkgbuilds/`
   - The new CHANGELOG entry
   - The PR description
3. Check the CHANGELOG entry has a real rationale, not just "I tried this and it works".
4. If you have a different machine config (different distro, GPU, Wayland vs X11, etc.), try the variant yourself and add a row to the test matrix in the corresponding issue.
5. Comment with concrete feedback: not "looks good" but "I tested on Manjaro with kernel 6.12, S1 passed, S3 failed because the connection dialog appeared but the URL bar was blank until I clicked it".

---

## Commit message convention

We use a lightweight prefix to keep `git log` scannable:

- `docs: …` — documentation only (no functional change)
- `variant <name>: …` — change to a specific variant under `pkgbuilds/<name>/`
- `upstream-sync: …` — recording a buzo AUR change in `CHANGELOG.md`
- `chore: …` — repo maintenance (`.gitignore`, `.github/`, scripts, etc.)

Examples:

- `docs: explain S5 build-time target in TESTING.md`
- `variant bundle-4.0-icu70: add patchelf loop in package()`
- `upstream-sync: buzo moved libsoup to optdepends on 2026-06-11`
- `chore: add GitHub issue templates`

## Code of conduct

This is a slow process by design. The goal is to not break Citrix for thousands of Arch users, not to be first.

- **Be specific.** "It works" is not useful. "`selfservice` launches, the GUI window appears within 3 seconds, no library error in `journalctl --user -xe`" is useful.
- **Be honest about what you didn't test.** "I didn't try selfservice" is fine. "Selfservice works" when you didn't test it is harmful.
- **Be patient.** A change to a widely-used AUR package shouldn't be merged in 24 hours.
- **Be respectful of buzo.** He maintains the package in his spare time. He is not required to accept any patch. We propose; he decides.
- **Cite evidence, not opinion.** If you say "this breaks S3", paste the output. If you say "I think this is cleaner", explain what you mean by cleaner.

---

## Communication channels

- **For coordination across contributors (this repo):** GitHub Issues and PRs.
- **For proposing the final patch to the AUR maintainer:** e-mail to buzo (`buzo+arch@Lini.de`, from the upstream PKGBUILD). Per his 2026-06-11 AUR comment, he prefers e-mail to keep the AUR comment section clean. Only send e-mail after at least 2-3 independent testers have validated the variant.
- **For AUR-specific issues** (out-of-date flag, etc.): the [AUR comment thread](https://aur.archlinux.org/packages/icaclient) on the package page.
- **For Citrix product bugs:** Citrix support, not here.

---

## What we will not accept

- Variants that depend on the user running post-install shell commands or symlink hacks manually. If it isn't in the PKGBUILD, it isn't a fix.
- Variants that haven't been tested by the proposer.
- Variants that silently regress the `libsoup` hard dependency (see [CHANGELOG.md](CHANGELOG.md) 2026-06-11).
- Variants that violate the Citrix EULA (e.g., redistributing the upstream tarball inside this repo — don't, the PKGBUILD references it by URL only).
