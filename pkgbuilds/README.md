# pkgbuilds/

Proposed `icaclient` PKGBUILD variants, one subdirectory per variant. Each variant is a self-contained proposal: copy the directory to a build location, run `makepkg -sf`, and you have a working build of that variant.

## Layout

```
pkgbuilds/
└── <variant-name>/
    ├── PKGBUILD       # required, no extension, as in AUR
    ├── README.md      # required, rationale + how to test + link to CHANGELOG entry
    ├── *.install      # optional, pacman install hooks (use the upstream name, e.g. icaclient.install)
    ├── *.patch        # optional, source patches
    ├── *.service      # optional, systemd units
    └── *.timer        # optional, systemd timers
```

## Naming convention

- **kebab-case** (lowercase, alphanumerics, hyphens). Matches the rest of the repo (`docs/webkit2gtk-abi.md`, `docs/alternatives.md`).
- The name describes what the variant **changes vs upstream**, not who proposed it or which iteration it is.

Good names:

- `bundle-4.0-icu70/` — extracts and bundles the webkit2gtk-4.0 from the Citrix tarball
- `optdepends-minimal/` — minimal `depends=`, no optdepends
- `quickfix-revert-libsoup/` — reverts buzo's 2026-06-11 `libsoup` regression
- `imgpaste-dep/` — depends on `webkit2gtk-imgpaste` instead of `webkit2gtk`

Bad names:

- `v2/`, `test/`, `foo/`, `my-fix/` — meaningless or personal
- `airv-zxf-attempt/` — names the author, not the change
- `WIP/` — a status, not a name; statuses live in `README.md` and `CHANGELOG.md`

## README.md template for a variant

Every variant directory must contain a `README.md` with the following sections:

```markdown
# <variant name>

**Status:** proposed | candidate | accepted
**Based on:** <commit SHA of upstream AUR PKGBUILD this is diff'd against, or "upstream AUR PKGBUILD @ pkgrel=N">
**CHANGELOG entry:** [../../CHANGELOG.md](../../CHANGELOG.md)

## What this changes vs upstream
<1-2 paragraph diff explanation>

## Why
<what problem this solves; link to docs/alternatives.md#X if applicable>

## Tradeoffs
<pros/cons, or a reference to docs/alternatives.md>

## How to test
<concrete commands, mapped to TESTING.md scenario IDs: S1, S2, ...>

## Known gaps
<what has NOT been verified>
```

## Status lifecycle

A variant moves through these states, recorded in its `README.md` and in `CHANGELOG.md`:

- `proposed` — PR is open, not yet reviewed or tested
- `candidate` — meets the structure and rationale bar; awaiting independent testers
- `accepted` — community agrees; ready to be sent upstream

The promotion criteria from `candidate` to `accepted` are defined in [`docs/alternatives.md`](../docs/alternatives.md) (section "Promotion criteria").

## See also

- [`CONTRIBUTING.md`](../CONTRIBUTING.md) — how to propose a variant
- [`docs/alternatives.md`](../docs/alternatives.md) — full evaluation of each approach
- [`CHANGELOG.md`](../CHANGELOG.md) — decision log
- [`TESTING.md`](../TESTING.md) — testing protocol
