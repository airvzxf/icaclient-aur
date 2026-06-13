---
name: Test report
about: Report results from running one or more TESTING.md scenarios against a PKGBUILD variant
title: 'Test report: YYYY-MM-DD - <distro> - <S-IDs>'
labels: ['test-report']
assignees: []
---

**System**

- Distro / version: (e.g., Arch Linux, 2026.06.01 installer)
- Kernel: (output of `uname -r`)
- AUR helper: (yay / paru / makepkg directly)
- Existing webkit2gtk packages: (output of `pacman -Q | grep -i webkit`)
- Existing libsoup packages: (output of `pacman -Q | grep -i soup`)
- Display server: (X11 / Wayland / Wayland+XWayland)

**PKGBUILD variant tested**

- Source: (commit SHA of this repo, or `pkgbuilds/<name>/`, or "upstream AUR pkgrel=N")
- Diff vs upstream: (`git diff <upstream> -- PKGBUILD`, attached or pasted)

**Results**

Result codes: ✅ pass, ❌ fail, ⏭️ skipped (with reason in the test report).

| Scenario | Result | Evidence |
|---|---|---|
| S1 selfservice launches | ✅ / ❌ / ⏭️ | (paste of relevant output) |
| S2 wfica opens .ica | ✅ / ❌ / ⏭️ |  |
| S3 wfica Connecting dialog | ✅ / ❌ / ⏭️ |  |
| S4 install without AUR webkit2gtk | ✅ / ❌ / ⏭️ |  |
| S5 build time | ✅ / ❌ | (e.g., "3:42") |
| S6 real Citrix session | ✅ / ❌ / ⏭️ |  |
| S7 no new system deps | ✅ / ❌ | (list of new packages, or "none") |

**Observations**

- (anything weird, even if everything passes; e.g., "selfservice shows the window but the URL bar is blank for 5 seconds, then loads")

**Caveats**

- (anything you did not test; e.g., "I do not have a real Citrix farm, only ran ldd")

**Local checklist outputs**

Attach or paste:

- [ ] `journalctl --user -xe | grep -i citrix` and `journalctl -xe | grep -i citrix` for the past 5 min
- [ ] `readelf -d /opt/Citrix/ICAClient/selfservice | grep -E "RUNPATH|RPATH|NEEDED"`
- [ ] `ldd /opt/Citrix/ICAClient/selfservice | grep -iE "not found|webkit|soup"`
- [ ] `pacman -Q | grep -iE "webkit|soup|patchelf"`
- [ ] `time makepkg -sf 2>&1 | tail -30`
