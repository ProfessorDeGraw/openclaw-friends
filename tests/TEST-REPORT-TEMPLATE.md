# OpenClaw Install Test Report

## Summary

| Field | Value |
|-------|-------|
| **Date** | _yyyy-mm-dd hh:mm_ |
| **Tester** | _name or "automated"_ |
| **Machine** | _hostname_ |
| **OS** | _Windows 11 Pro 23H2 / macOS 15 / Ubuntu 24.04_ |
| **Build** | _OS build number_ |
| **Docker** | _version or "not pre-installed"_ |
| **Install method** | _irm + iex / manual / script_ |
| **Result** | _X / Y passed_ ✅❌ |
| **Duration** | _total time_ |

## Pre-Install State

- [ ] Fresh OS install (no Docker, no WSL)
- [ ] Internet connection working
- [ ] At least 5GB free disk space
- [ ] Running PowerShell as Administrator

## Test Results

| # | Test | Status | Notes |
|---|------|--------|-------|
| 1 | WSL2 install/detection | ⬜ | |
| 2 | Docker Desktop install | ⬜ | |
| 3 | Docker engine starts | ⬜ | |
| 4 | Install directory created | ⬜ | |
| 5 | Config files generated | ⬜ | |
| 6 | Token not placeholder | ⬜ | |
| 7 | docker-compose.yml valid | ⬜ | |
| 8 | Container starts | ⬜ | |
| 9 | Container stays running (no crash loop) | ⬜ | |
| 10 | Port 18789 accessible | ⬜ | |
| 11 | Web UI loads in browser | ⬜ | |
| 12 | Token auth works | ⬜ | |
| 13 | Can send a message to assistant | ⬜ | |
| 14 | Assistant responds | ⬜ | |
| 15 | Discord prompts shown (if selected) | ⬜ | |
| 16 | Discord config saved correctly | ⬜ | |
| 17 | CONNECTION-INFO.txt created | ⬜ | |
| 18 | SOUL.md in workspace | ⬜ | |

## Issues Found

_Describe any problems, with steps to reproduce:_

### Issue 1: _title_

**Severity:** 🔴 Blocker / 🟡 Major / 🟢 Minor

**What happened:**

**Expected:**

**Steps to reproduce:**
1.
2.
3.

**Logs / screenshots:**

```
paste relevant logs here
```

---

## Timing Breakdown

| Phase | Duration | Notes |
|-------|----------|-------|
| WSL2 setup | | _skip if already installed_ |
| Docker install | | _includes download time_ |
| Docker engine start | | _time until daemon ready_ |
| Installer run | | _after Docker is ready_ |
| Container pull + start | | _first run is slowest_ |
| Gateway ready | | _until HTTP 200_ |
| **Total** | | |

## Environment Notes

_Anything unusual about the test environment:_

- Network speed:
- Antivirus/firewall:
- VPN:
- Other software running:

## Verdict

- [ ] **PASS** — Installer works on fresh Windows 11
- [ ] **FAIL** — Blocked by issues listed above
- [ ] **PARTIAL** — Works with workarounds noted above

## Recommendations

_Any changes needed to the installer based on this test:_

1.
2.
3.

---

_Template: /tests/TEST-REPORT-TEMPLATE.md_
_Test script: /tests/win11-fresh-test.ps1_
