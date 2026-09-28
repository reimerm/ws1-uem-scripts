# diagnostics/

Standalone scripts for inspecting/dumping raw API data during troubleshooting — no report is produced, no tenant state is changed. (Note: several reporting scripts, e.g. `reporting/vpp-license-allocation/`, already include their own built-in diagnostic switches like `-DumpRawSample`/`-InspectApplicationId` rather than needing a separate script here — check there first before adding a new one-off diagnostic script for the same endpoint.)

No standalone scripts here yet. See the repo-root `README.md` for folder conventions and `CONTRIBUTING.md` before adding one.
