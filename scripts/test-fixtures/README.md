# Test fixtures

Sample `.ica` files and the smoke-test driver used by
`scripts/test-variant.bash`'s `--smoke-test` flag. These files exercise the
S1, S2, S3 scenarios from [`TESTING.md`](../../TESTING.md) without requiring
a real Citrix farm.

## Why TEST-NET-1 (`192.0.2.0/24`)

Every `.ica` in this directory points to `192.0.2.1:1494`. This is the
IANA-reserved **TEST-NET-1** range (RFC 5737), guaranteed not to be routable
on the public Internet. `wfica` will:

1. Parse the `.ica` (validates file format)
2. Attempt a TCP connection to `192.0.2.1:1494` (or HTTPS to `192.0.2.1`)
3. Hang on the SYN (no SYN-ACK ever arrives)
4. Show the "Connecting..." dialog rendered by `UIDialogLibWebKit3.so` →
   `libwebkit2gtk-4.0.so.37` → spawns `WebKitWebProcess` /
   `WebKitNetworkProcess` (the bundle's helpers)

That is exactly the code path S1, S2, S3 from `TESTING.md` cover. The smoke
test inspects `/proc/<pid>/maps` and the helper-process list to validate
that the libraries loaded without errors.

## Files

| File | Purpose | Used for |
|---|---|---|
| `sample-pna.ica` | PNAgent-style `.ica` (direct XenApp launch, TCP). Minimal valid ICA pointing at `192.0.2.1:1494`. | S2, S3 (default fixture the smoke test picks) |
| `sample-storefront.ica` | StoreFront-style `.ica` (HTTPS launch reference). Same target host, different code path in `wfica`'s parser. | Optional — not run by the default smoke test, kept for future expansion |
| `run-smoke.bash` | Driver. Sources `../lib/citrix-smoke.bash`, runs `run_s1_s2_s3` with the fixtures in this dir, prints the result table. | The entry point the orchestrator invokes inside the L3 sandbox |

The actual smoke-test library (`citrix-smoke.bash`) lives in
[`../lib/citrix-smoke.bash`](../lib/citrix-smoke.bash) and is **not** in this
directory. The orchestrator (`scripts/test-variant.bash`) stages this
directory's contents plus `citrix-smoke.bash` into a temporary staging
directory before launching the L3 sandbox. Inside the sandbox the driver
sources the library by relative path (`./citrix-smoke.bash`).

## Safety

The fixtures contain no real hostnames, no real credentials, no session
tokens, and no PII. The only network target is `192.0.2.1` (TEST-NET-1,
non-routable). Safe to commit; safe to run in a sandbox.
