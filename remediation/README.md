# remediation/

Scripts that **change** tenant state — fix, clean up, or correct something (e.g. reallocate licenses between smart groups, retag misassigned apps, remove stale profiles). If a reporting script identifies a problem, the fix belongs here as its own script, not folded into the reporting script.

| Script | What it does |
|---|---|
| [`smartgroup-device-commands/Invoke-SmartGroupDeviceCommand.ps1`](smartgroup-device-commands/README.md) | Runs DeviceQuery, SyncDevice and similar commands against one platform's devices in a smart group (ID or UUID), batched and rate limited, dry-run by default. Draft, not yet live-tested. |

See the repo-root `README.md` for folder conventions and `CONTRIBUTING.md` before adding one.
