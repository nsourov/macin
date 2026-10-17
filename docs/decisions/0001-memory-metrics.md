# 0001 — Memory module: validated metrics (Phase 0 spike)

Date: 2026-10-16. Tested on: Apple M3 Pro, 18 GB, macOS 26.6.2, page size 16 KB. Intel not tested yet.

## Decision

- Use only public Darwin APIs, wrapped behind `SystemMemoryProviding` and `ProcessMemoryProviding` (`Sources/FootprintCore/Memory`).
- Ship the Memory module in the **direct-distribution (Developer ID, not sandboxed)** build. In the App Sandbox the process list is completely unavailable (see below).
- Per-process metric is **Memory footprint** (`ri_phys_footprint`). Label it exactly that in the UI.

## Metric sources and formulas

| Metric | Source | Formula | Validated against | Result |
|---|---|---|---|---|
| Physical memory | `sysctl hw.memsize` | bytes as reported | `sysctl hw.memsize` | exact (18.00 GiB) |
| Wired | `host_statistics64(HOST_VM_INFO64)` | `wire_count × page` | `vm_stat` "wired down" | exact |
| Compressed | same | `compressor_page_count × page` | `vm_stat` "occupied by compressor" | exact |
| App memory | same | `(internal_page_count − purgeable_count) × page`, floored at 0 | `vm_stat` anonymous − purgeable | exact |
| Cached files | same | `(external_page_count + purgeable_count) × page` | `vm_stat` file-backed + purgeable | exact |
| Memory used | derived | app + wired + compressed (Apple's Activity Monitor definition); `nil` if any part missing | — | consistent |
| Swap used / total | `sysctl vm.swapusage` (`xsw_usage`) | bytes | `sysctl vm.swapusage` | exact |
| Pressure (initial) | `sysctl kern.memorystatus_vm_pressure_level` | 1 normal, 2 warning, 4 critical, else unknown | same sysctl | matches |
| Pressure (changes) | `DispatchSource.makeMemoryPressureSource` | worst flag wins | unit-tested mapping | transitions not yet observed live |
| Process footprint | `proc_pid_rusage(RUSAGE_INFO_V4)` | `ri_phys_footprint` | `top -stats mem` | matches to ±2 MB |
| Process peak | same | `ri_lifetime_max_phys_footprint` | — | available |
| Process identity | same | PID + `ri_proc_start_abstime` | unit test (stable across samples) | prevents PID-reuse merges |

## Coverage and limits

- Not sandboxed, normal user: **424 of 687 processes readable**. All readable ones belong to the current user. Every process owned by root or other users (for example `WindowServer` 965 MB, `mds` 582 MB) is denied. The UI must show "N of M processes visible; macOS system processes are hidden" instead of implying full coverage. No privileged helper will be added to work around this.
- App Sandbox: system snapshot, swap and pressure still work; **process enumeration returns 0 processes**. A Mac App Store build cannot offer the process table.
- `kern.memorystatus_vm_pressure_level` is a readable sysctl but not formally documented. Use it only for the initial state, then rely on the dispatch source.
- Warning/Critical transitions were not triggered during the spike (forcing them would disturb the user's Mac). Mapping is unit-tested; live behavior to verify in Phase 4 on a test machine.

## Cost

- System snapshot: ~0.04 ms.
- Full process sweep (687 pids): ~7 ms first run, ~2.4 ms average after. Sampling every 2 s is negligible.
