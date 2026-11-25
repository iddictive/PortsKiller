# Changelog

## 0.5.0

- Right-click the menu bar icon to search running apps and ask them to quit normally. Left-click opens the process window.
- Agents now groups local Codex commands separately from runtimes and services. Sort by RAM, expand rows for context, and copy individual or grouped process IDs.
- Stop eligible local command groups after confirmation. Codex runtimes and services such as Computer Use, hooks, and the artifact runtime remain read-only.
- Search across Agents, Dev, Ports, and Activity in the updated native process window.

## 0.2.0

- Resizable native windows preserve their size, with compact process cards, inline actions, and grouped preferences.
- Update checks include release notes and explicit errors, and verify the app identity and version before installation with rollback on failure.
- Processes without a known restart command offer project setup; session recovery is disabled behind a feature flag.

## 0.1.0

- Initial release with TCP listener inspection, saved projects, process controls, and system resource monitoring.
