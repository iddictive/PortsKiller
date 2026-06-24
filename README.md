# PortsKiller

<p align="center">
  <img src="assets/app-icon.png" alt="PortsKiller app icon" width="128">
</p>

<p align="center">
  <a href="#english">English</a> • <a href="#russian">Русский</a>
</p>

## Interface Snapshot

<p align="center">
  <img src="assets/interface-menu.png" alt="PortsKiller menu interface" width="720">
</p>

---

<a id="english"></a>

## English

> Native macOS menu bar app for finding, opening, restarting, and stopping local TCP listeners.

PortsKiller scans local listening ports, separates JavaScript dev servers from other processes, and gives each listener a compact row with URL, PID, resource use, project folder, logs, and process controls.

## What It Handles

- Scans listening TCP ports with `lsof -nP -iTCP -sTCP:LISTEN`.
- Reads process command, parent PID, cwd, CPU, RAM, and uptime.
- Filters JS/dev processes such as `node`, `npm`, `pnpm`, `yarn`, `bun`, `vite`, `next`, `astro`, `nuxt`, `tsx`, and `nodemon`.
- Switches between Dev mode and All TCP listeners mode.
- Opens and copies `http://localhost:<port>`.
- Reveals the project folder when cwd is available.
- Stops non-system process trees with `TERM`, then `KILL` if needed.
- Restarts saved projects from `cwd + command`.
- Captures logs for processes launched by PortsKiller.

## Interface Surfaces

- **Menu bar dropdown:** process list, mode switch, refresh, quick actions.
- **Process row:** name, framework, port URL, PID, CPU/RAM/uptime, open/copy/reveal/restart/stop actions.
- **Add Project:** folder-first project setup with package script detection.
- **Preferences:** login launch and app behavior.

## Build

```bash
swift build
```

To create a runnable menu bar app bundle:

```bash
chmod +x scripts/build-app.sh
scripts/build-app.sh
open .build/PortsKiller.app
```

## Smoke Checks

```bash
.build/debug/PortsKiller --scan-once
.build/debug/PortsKiller --scan-all
```

## Notes

Login launch is implemented through a user LaunchAgent. The toggle requires running from a `.app` bundle, not directly from `swift run`.

---

<a id="russian"></a>

## Русский

> Нативное macOS menu bar приложение для поиска, открытия, рестарта и остановки локальных TCP listeners.

PortsKiller сканирует локальные listening ports, отделяет JavaScript dev servers от остальных процессов и показывает каждый listener компактной строкой: URL, PID, ресурсы, папка проекта, логи и действия над процессом.

## Что умеет приложение

- Сканирует listening TCP ports через `lsof -nP -iTCP -sTCP:LISTEN`.
- Читает command, parent PID, cwd, CPU, RAM и uptime процесса.
- Фильтрует JS/dev процессы: `node`, `npm`, `pnpm`, `yarn`, `bun`, `vite`, `next`, `astro`, `nuxt`, `tsx`, `nodemon`.
- Переключается между Dev mode и All TCP listeners mode.
- Открывает и копирует `http://localhost:<port>`.
- Открывает папку проекта в Finder, если доступен cwd.
- Останавливает non-system process trees через `TERM`, затем `KILL`, если нужно.
- Перезапускает сохранённые проекты из `cwd + command`.
- Собирает логи процессов, запущенных через PortsKiller.

## Интерфейс

- **Menu bar dropdown:** список процессов, переключатель mode, refresh, быстрые действия.
- **Process row:** name, framework, port URL, PID, CPU/RAM/uptime, open/copy/reveal/restart/stop.
- **Add Project:** выбор папки проекта и чтение package scripts.
- **Preferences:** login launch и поведение приложения.

## Сборка

```bash
swift build
```

Чтобы собрать запускаемый menu bar app bundle:

```bash
chmod +x scripts/build-app.sh
scripts/build-app.sh
open .build/PortsKiller.app
```

## Smoke Checks

```bash
.build/debug/PortsKiller --scan-once
.build/debug/PortsKiller --scan-all
```

## Заметки

Login launch реализован через пользовательский LaunchAgent. Toggle работает из `.app` bundle, а не из прямого `swift run`.
