# CodeMi Helper

The optional helper that lets the CodeMi app turn Kimi Code's Remote Control back on. This folder is the exact source of what runs on your computer.

| File | What it is |
|---|---|
| `mac/main.swift` | The macOS helper. `mac/build.sh` builds it as a universal binary signed with a Developer ID. |
| `windows/helper.ps1` | The Windows helper (Windows PowerShell 5.1, also runs on PowerShell 7). |
| `installers/install.sh` | The macOS installer and uninstaller (`--uninstall`). |
| `installers/install.ps1` | The Windows installer and uninstaller (`--uninstall`). |

## What it does
- Keeps one outgoing WebSocket to `relay.mannydlabs.com` for each paired iPhone or iPad (up to 8). It opens no ports.
- Answers three requests: **status** (is Kimi Code running, is Remote Control on), **turn on Remote Control** (through Kimi Code's own local API on `127.0.0.1`, opening Kimi Code first if needed), and **remove** (unpairs that device, and removes the helper when no device is left).
- Runs no other commands, reads no files or projects, needs no admin rights, and never updates itself.

## Where it installs
- **macOS:** `~/Library/Application Support/CodeMi Helper` and a LaunchAgent, `com.mannydlabs.codemi.helper`.
- **Windows:** `%LOCALAPPDATA%\CodeMi Helper` and a startup entry for your user only.

## Verifying a download
The app passes the SHA-256 of the helper it expects to the installer, which refuses anything else. Current checksums are listed at [mannydlabs.com/codemi-helper](https://mannydlabs.com/codemi-helper).

## Removing it
In CodeMi: **Computers → Remove Helper**. Or run the installer with `--uninstall`:

```sh
curl -fsSL https://relay.mannydlabs.com/install.sh | sh -s -- --uninstall
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm https://relay.mannydlabs.com/install.ps1))) --uninstall"
```
