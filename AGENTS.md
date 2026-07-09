# PortsKiller Agent Notes

- Keep `.codex/environments/environment.toml` in sync when adding or changing canonical repo commands. Treat it as the launcher source for build, package, smoke, and run actions.
- Treat the menu dropdown, Add Project sheet, Preferences sheet, and Logs surface as one UI contract. Do not polish only the currently visible dropdown while leaving adjacent sheets in raw Form/List styling.
- Add Project is folder-first: selecting a project folder should read `package.json`, infer the package manager from lockfiles, expose npm scripts immediately, and produce a runnable saved `cwd + command`.
- Folder-picking flows must run in a dedicated app window/panel, not inside the MenuBarExtra popover; `NSOpenPanel` can collapse the popover and lose the user's form context.
- Keep the app compact and system-like. Prefer icon actions, quiet row surfaces, literal port/PID formatting, and honest disabled states over explanatory copy or decorative panels.
- Inline menu panels use one scroll owner for the whole variable body. Do not add nested scroll/overflow inside scripts, project rows, logs, or other child blocks unless the user explicitly asks for an independently scrollable subpanel.
