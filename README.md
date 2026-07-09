# PortsKiller

<p align="center">
  <img src="https://github.com/iddictive/PortsKiller/releases/download/v0.1.0/app-icon.png" alt="PortsKiller app icon" width="124">
</p>

<p align="center">
  <strong>A compact macOS menu bar app for finding and controlling local TCP listeners.</strong>
</p>

<p align="center">
  <a href="https://github.com/iddictive/PortsKiller/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/iddictive/PortsKiller?display_name=tag"></a>
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-111111">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6.0-F05138">
  <img alt="License" src="https://img.shields.io/badge/license-none-lightgrey">
</p>

<p align="center">
  <a href="#download">Download</a> •
  <a href="#features">Features</a> •
  <a href="#build-from-source">Build</a> •
  <a href="#русский">Русский</a>
</p>

<p align="center">
  <img src="https://github.com/iddictive/PortsKiller/releases/download/v0.1.0/interface-menu.png" alt="PortsKiller menu bar interface" width="760">
</p>

PortsKiller lives in the menu bar and keeps the noisy part of local development visible: ports, PIDs, commands, project folders, CPU/RAM usage, uptime, logs, and one-click process actions.

It is designed for developers who frequently run Vite, Next.js, Astro, Nuxt, Node, npm, pnpm, yarn, bun, tsx, nodemon, MCP servers, and other local listeners.

## Download

Get the latest packaged app from [GitHub Releases](https://github.com/iddictive/PortsKiller/releases/latest):

- [PortsKiller-0.1.0.dmg](https://github.com/iddictive/PortsKiller/releases/download/v0.1.0/PortsKiller-0.1.0.dmg)
- [PortsKiller-0.1.0.zip](https://github.com/iddictive/PortsKiller/releases/download/v0.1.0/PortsKiller-0.1.0.zip)

The current release is signed with an Apple Development identity and is not Developer ID notarized.

## Features

- Scans listening TCP ports with `lsof -nP -iTCP -sTCP:LISTEN`.
- Shows process name, framework, port URL, PID, command, cwd, CPU, RAM, and uptime.
- Separates common JavaScript/dev listeners from the full TCP listener list.
- Opens or copies `http://localhost:<port>` from each row.
- Reveals the detected project folder in Finder when cwd is available.
- Stops non-system process trees with `TERM`, then `KILL` when needed.
- Restarts saved projects from a stored `cwd + command`.
- Captures logs for processes launched by PortsKiller.
- Adds projects by selecting a folder and reading available package scripts.
- Supports login launch from the packaged `.app`.

## Interface

| Surface | What it does |
| --- | --- |
| Menu bar dropdown | Lists local listeners, switches between Dev and All TCP modes, refreshes the scan, and exposes quick actions. |
| Process row | Shows identity, URL, PID, resource usage, command context, and open/copy/reveal/restart/stop controls. |
| Add Project | Starts from a folder, detects package scripts, and saves a runnable project command. |
| Preferences | Controls launch-at-login and app behavior. |

## Build From Source

Requirements:

- macOS 13 or newer
- Xcode command line tools
- Swift 6 toolchain

Build the executable:

```bash
swift build
```

Create a runnable menu bar app bundle and a versioned DMG:

```bash
chmod +x scripts/build-app.sh
scripts/build-app.sh
open .build/PortsKiller.app
```

## Smoke Checks

After building, run:

```bash
.build/debug/PortsKiller --scan-once
.build/debug/PortsKiller --scan-all
```

The command line modes print detected listeners without launching the menu bar UI.

## Notes

- Login launch is implemented through a user LaunchAgent.
- The login toggle requires running from a `.app` bundle, not directly from `swift run`.
- Stop actions intentionally target non-system process trees only.

---

<a id="русский"></a>

## Русский

PortsKiller — нативное macOS menu bar приложение для разработчиков, которым нужно быстро видеть и контролировать локальные TCP listeners: dev servers, Node-процессы, MCP servers и другие сервисы на `localhost`.

Что есть:

- список активных портов, PID, URL, cwd, command, CPU/RAM и uptime;
- режим Dev listeners и режим All TCP listeners;
- кнопки открыть URL, скопировать URL, показать папку, перезапустить или остановить процесс;
- добавление проекта через выбор папки и чтение package scripts;
- логи для процессов, запущенных из PortsKiller;
- сборка в обычный `.app` bundle через `scripts/build-app.sh`.

Скачать готовую сборку можно в [Releases](https://github.com/iddictive/PortsKiller/releases/latest).
