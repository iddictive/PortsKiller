# PortsKiller

Native macOS menu bar app for finding and controlling local JavaScript dev servers.

## Build

```sh
swift build
```

To create a runnable menu bar app bundle:

```sh
chmod +x scripts/build-app.sh
scripts/build-app.sh
open .build/PortsKiller.app
```

## MVP behavior

- Scans listening TCP ports with `lsof -nP -iTCP -sTCP:LISTEN`.
- Reads process command and parent PID with `ps`.
- Reads cwd with `lsof -a -p <pid> -d cwd -Fn`.
- Filters for JS/dev processes such as `node`, `npm`, `pnpm`, `yarn`, `bun`, `vite`, `next`, `astro`, `nuxt`, `tsx`, and `nodemon`.
- Excludes common system and desktop app listeners.
- Opens and copies `http://localhost:<port>`.
- Stops a process tree by sending `TERM` to descendants and parent, then `KILL` if needed.
- Restarts manually saved projects from `cwd + command`.
- Captures logs for processes launched by PortsKiller.

## Notes

Login launch is implemented through a user LaunchAgent. The toggle requires running from a `.app` bundle, not directly from `swift run`.
