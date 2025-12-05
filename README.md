<div align="center">

# PC-HealthCheck

![Built With PowerShell](https://img.shields.io/badge/Built%20With-PowerShell-007ACC?logo=powershell&logoColor=white)
![License](https://img.shields.io/github/license/calebharper14/PC-HealthCheck)
[![Repository](https://img.shields.io/badge/Repo-PC--HealthCheck-blue?logo=github)](https://github.com/calebharper14/PC-HealthCheck)

</div>

> An inclusive Windows health assessment and optimization script that delivers fast, reliable insights.
> Built for support environments, providing technicians with rapid visibility and clear, guided outputs.

---

## 1. Overview

PC-HealthCheck gives you:
- A fast baseline (default ≈6s) or a sustained sample (30–60s) of core performance signals.
- Plain-language health tiers: **Good / Medium / Critical / Unknown**.
- Reversible tuning (startup hygiene, power plan, GPU scheduling, Game Bar capture).
- Safe-by-default: nothing changes unless flags are provided.
- Clear logs + CSVs you can ingest or hand to another technician.
- Universal PowerShell compatibility (5.1–7.x) with automatic feature detection.
- Professional progress indicators for clarity during longer operations.
- Interactive help menu with actionable recommendations based on detected issues.

<p align="center">
  <b>Scan first. Decide. Then (optionally) remediate—always reversible.</b>
</p>

---

## What's New in Version 1.3

**Enhanced Reliability**
- Fixed storage SMART property validation errors on diverse hardware
- Multi-method boot time detection with automatic fallbacks
- Universal PowerShell 5.1–7.x compatibility

**Better User Experience**
- Professional progress indicators during performance sampling
- Interactive help menu after collection with health-specific recommendations
- Clearer status messages and error reporting

**Improved Diagnostics**
- Startup program impact analysis (Low/Medium/High ratings)
- Boot performance diagnostics with program categorization
- Enhanced detection for security software, cloud sync, and GPU utilities

**Broader Compatibility**
- Windows 10 (1809+) and Windows 11 version detection
- Feature gating based on OS capabilities
- Graceful handling of missing cmdlets

---

## 2. Why It Exists

Most “PC tune-up” scripts:
- Hide what they did,
- Use arbitrary thresholds,
- Or over-correct without context.

This script:
- Shows the exact numbers that drive each health decision.
- Makes “skipped” vs “unavailable” explicit.
- Lets you ratchet sensitivity by extending the sampling window (sustained vs burst).

---

## 3. Quick Run vs Sustained Run

| Mode | When to Use | Command |
|------|-------------|---------|
| Burst (default ~6s) | Quick triage / ticket response | `powershell -ExecutionPolicy Bypass -File .\PC-HealthCheck.ps1` |
| Sustained (30s) | Verify CPU/memory pressure isn’t a spike | `powershell -ExecutionPolicy Bypass -File .\PC-HealthCheck.ps1 -ExtendedPerf` |
| Custom window (e.g., 60s) | Heavier validation for chronic slowness | `powershell -ExecutionPolicy Bypass -File .\PC-HealthCheck.ps1 -PerfSampleSeconds 60` |

Tip: Use sustained mode before escalating “high CPU” or “memory exhaustion” issues.

---

## 4. What It Collects

**Identity & Hardware**  
Manufacturer / Model / Product string, OS caption/build/arch, uptime, CPU, memory modules, disks, GPU.

**Performance Snapshot**  
CPU usage & backlog (threads waiting), memory commit %, available MB, hard faults/sec, disk busy %, queue length, read/write throughput, optional sustained evaluation.

**Reliability & Health**  
Storage health (PhysicalDisk + reliability counters + SMART fallback), boot average (Event ID 100 with multi-method detection and fallback mechanisms), startup program impact analysis, recent System critical/error events (72h), CPU temperature (best-effort).

**Hygiene & Activity**  
Top differential processes (CPU seconds & IO bytes), startup entries classification, power plan state, toggles (HAGS, Game Bar capture).

**Outputs**  
Full & Compact CSV, full execution log, compact executive summary, admin follow-up (if run non-elevated).

---

## 5. Health Scoring

Each component produces a tier independently; overall health is the “worst” tier among CPU, Memory, Disk (performance + SMART), Events, Boot.

Threshold set (optimized):
- CPU usage: Medium ≥85% (only counts as Medium/Critical when sustained over the chosen window); Critical ≥95%.
- CPU backlog: Medium > 1× logical cores; Critical > 2.5×.
- Memory commit: Medium ≥85%; Critical ≥95%.
- Memory hard faults/sec: Medium >100; Critical >500.
- Disk busy: Medium ≥85%; Critical ≥95%.
- Disk queue length: Medium >2; Critical >5.
- Boot time avg: >45s → Medium; >75s → Critical.
- CPU temp: >80°C → Medium; >90°C → Critical.
- SMART: Warning → Medium; PredictFailure/Unhealthy → Critical.
- Missing sensor/counter: Neutral (Unknown).

Sustained sampling (≥30s) reduces false positives by averaging time rather than a short burst. If you only run burst mode and see a single high metric—re-run sustained before intervening.

---

## 6. Parameters

```
-AutoElevate              Try to relaunch as admin (needed for repairs / deeper clean).
-QuietSkipAdmin           Hide verbose admin-skipped lines.
-PowerMode <Balanced|High>  Temporarily apply power plan (restored unless -KeepNewPowerPlan).
-KeepNewPowerPlan         Do not restore original plan.
-ApplyStartupOptimization Audit + optionally disable non-critical startup items.
-ForceStartupOptimization Disable candidates without prompting.
-DeepClean                Offer heavier (prompted) cleanup steps.
-DeepCleanAutoYes         Auto-confirm each Deep Clean prompt.
-EnableHAGS / -DisableHAGS  Hardware Accelerated GPU Scheduling toggle.
-DisableGameBarCapture / -EnableGameBarCapture  Xbox Game Bar background capture toggle.
-ExtendedPerf             Use a 60s sustained sample window (unless -PerfSampleSeconds given).
-PerfSampleSeconds <int>  Custom performance sampling duration (default 6).
```

Conflicting enable/disable pairs cancel out with a log entry (no silent surprises).

---

## 7. Example Scenarios

Diagnose slow startup with detailed program analysis:
```powershell
.\PC-HealthCheck.ps1 -ExtendedPerf
# (Now includes startup program impact assessment with Low/Medium/High ratings)
```
Check high memory complaint with sustained sampling:
```
.\PC-HealthCheck.ps1 -PerfSampleSeconds 45
```
Run full hygiene + deep clean (cautious but automated):
```
.\PC-HealthCheck.ps1 -AutoElevate -ApplyStartupOptimization -DeepClean -DeepCleanAutoYes
```
Disable HAGS and enforce High Performance for a workstation:
```
.\PC-HealthCheck.ps1 -AutoElevate -PowerMode High -DisableHAGS -DisableGameBarCapture
```

---

## 8. Output Files

Outputs land in a stable folder (default `C:\Scripts\PCHealthCheckScript`):
- `PC-Health-Report-<PC>-<timestamp>.csv` (full; feed into BI or trend store)
- `PC-Health-Report-Compact-<PC>-<timestamp>.csv` (executive signal density)
- `PC-Health-Full-<PC>-<timestamp>.txt` (everything: inventory, events, process deltas)
- `PC-Health-Compact-<PC>-<timestamp>.txt` (one-page summary for ticket attachment)
- `Run-As-Admin-Todo-<PC>-<timestamp>.txt` (actionable follow-ups for non-admin runs)

Use the compact CSV to populate dashboards; full CSV for historical baselines; text logs for ticket evidence.

---

## 9. Security Notes / Remediation Philosophy

- Nothing destructive without a prompt (or an explicit “auto” flag).
- Startup changes reversible (keys moved or files renamed `.disabled`).
- Power plan restored unless you say otherwise.
- Deep clean favors reclaiming space & clearing stale caches—never registry “tweaks” for placebo.

---

## 10. Extending / Integrating

Want more?
- JSON export (planned).
- Profiles (`-ThresholdProfile Gaming | Enterprise | LegacyHDD`)—roadmap.
- GPU temperature (requires vendor APIs; longer-term).
- RMM packaging: Wrap this with Intune / Chocolatey / WinGet for fleet rollout.

Raise an issue if your environment needs a variant (e.g., VDI nuance or server-specific counters).

---

## 11. Troubleshooting Cheatsheet

| Symptom | Fix |
|---------|-----|
| Many metrics “N/A” | `lodctr /r`, reboot; ensure performance counters service OK. |
| Throughput missing | `diskperf -y`, reboot. |
| Boot samples empty | Enable Diagnostics-Performance log; get 2 fresh boots. Script will attempt uptime-based fallback calculation if events unavailable. |
| CPU temp “Unavailable” | Consumer board doesn’t expose ACPI zone; confirm via OEM tool. |
| SMART Medium/Critical | Validate with vendor tool, plan backup/replacement. |
| SMART property errors | Normal on older systems—script uses safe property validation and multiple fallback methods. |
| Repairs slow | Normal—don’t abort DISM/SFC mid-run. |
| Persistent high CPU (burst only) | Re-run sustained (`-ExtendedPerf`) before escalating. |

---

## 12. Contribute

Pull requests welcome:
- Keep PowerShell 5.1–7.x compatibility.
- Every new flag must note reversibility.
- Update README if you touch thresholds or behavior.
- Accessibility: Aim for plain language—junior techs should not need a glossary.

---

## 13. License

[MIT License](LICENSE) Use freely. Attribution appreciated but not required.

---

### Final Note

If a number looks scary, re-run with sustained sampling. Burst samples can catch a momentary spike; sustained windows tell the real story.

Need an HTML dashboard, JSON output, or threshold profile pack? Open an issue and describe your environment—happy to iterate.
