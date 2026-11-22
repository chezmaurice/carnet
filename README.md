# Carnet

**Carnet** is the native iOS/iPadOS companion to [Maurice](https://github.com/chezmaurice/chez-maurice) —
a self-hosted, shared AI and memory for families and small groups. Where Maurice's own
SwiftUI app is the conversational front door and the web *garden* is the browsable
read surface, **Carnet is the pocket client for _capturing_ and _consuming_ a household's
signals and content**: log what happened, read and edit what's remembered.

> Carnet sits *on top of* the Maurice design system — editorial, print-derived: warm
> monochrome ink on cream paper, 0.5px hairlines, italic-serif display type, no
> gradients, no glass, no bounce.

This README is a living document. Keep it current as the app's roles evolve.

---

## What Carnet is for

Carnet is a **unified companion** with three co-equal roles ("peers"):

| Role | What it does | Maurice domain |
|---|---|---|
| **Log** | Fast ad-hoc capture — meals, exercise, breathwork, meditation, notes, places, documents, tasks — via a radial FAB, free-text parsing and the Share Extension. | `signals`, `uploads`, `places` |
| **Dashboards** | Server-defined layouts of warm-monochrome widgets over the household's health, activity, and coaching data, navigable by day. | `layouts`, health, `signals`, `coaching` |
| **Content** | Read and edit the household's living memory — daily notes & dreams, garden fiches (books, movies, series, podcasts, people, articles), tasks & calendar, and reading (Calibre / Readwise). | `garden`, `tasks`, `calendar`, `calibre`, `readwise` |

All three are backed by the **same paired Maurice server**, the **same household identity**
(pair once, switch members with a PIN), and the **same design tokens** — shared with Maurice
so the login, member-switching, and visual language are consistent across every surface.

## How it fits the Maurice ecosystem

```
                 ┌──────────────────────────────────────┐
                 │        Maurice server (Mac)           │
                 │  Bun + Hono · chat engine + data API  │
                 └──────────────────────────────────────┘
                    ▲            ▲              ▲
        pairing +   │            │              │  MCP gateway
        member auth │            │              │  (Claude Desktop / claude.ai)
                    │            │              │
        ┌───────────┴──┐  ┌──────┴───────┐  ┌───┴──────────┐
        │   Carnet     │  │ Maurice app  │  │  Web garden  │
        │ (this repo)  │  │ (iOS/iPad/Mac)│ │   (Astro)    │
        │ capture +    │  │ conversation │  │ browse/read  │
        │ consume      │  │              │  │              │
        └──────────────┘  └──────────────┘  └──────────────┘
```

Carnet and Maurice **share** the design system (tokens, fonts, motion) and the
identity model (household pairing → member picker → PIN). Anything that touches
login or user-switching should be designed once and used by both.

## Architecture

- **`CarnetApp/`** — the SwiftUI app.
  - `CarnetApp.swift` — entry point + `RootView` gate: `PairingView` → `MemberPickerView` → `DashboardView`.
  - `CarnetTheme.swift` — the single source of truth for design tokens (colors, type, spacing, radii, sizes). Mirrors the Maurice CSS token sheet. **All views reference this exclusively.**
  - `Models/LayoutSpec.swift` — the server-driven dashboard/layout schema (rows → widgets → data bindings → resolved metrics).
  - `Views/` — dashboard, widgets, log FAB, settings, pairing, member picker, uploads, coaching, queue.
  - `Services/` — `CarnetSession` (household/member state, App Group persistence), `SyncService`, `LayoutService`, `MetricService`.
- **`Shared/`** — `CarnetAPI.swift` (the full HTTP client) and `OfflineQueue.swift`, shared between the app and the Share Extension.
- **`CarnetShareExtension/`** — "Save to Carnet" share sheet target (URLs, files, data) that posts as the currently active member via the App Group.
  - `ShareExtensionPreprocessor.js` runs inside the Safari page and hands back the **rendered DOM**, so an article is saved from what you actually read rather than from a server-side fetch that meets a paywall.
  - `SharedContent.swift` parses the sheet's attachments — deliberately UIKit-free, so the one surface no harness can drive is at least testable where it counts.

### Identity & sessions

`CarnetSession` mirrors Maurice's model and persists everything in the App Group
(`group.eu.chezmaurice.carnet.app`) so the Share Extension acts as whoever is active:

1. **Pair** the device to a server URL (`PairingView`).
2. **Sign in** members; each member's bearer token is cached per-id.
3. **Switch** members instantly (PIN when required) — the active member is who Carnet logs and reads as.

### API surface (Maurice server)

`Shared/CarnetAPI.swift` — `health`, `auth/setup`, `auth/login`, `users`; `v1/signals`
(+ `parse`, `aggregated`), `v1/layouts`, `v1/dashboard/:id/data`, `v1/uploads`,
`v1/places`, `v1/articles/scrape`, `v1/calibre/add`, `v1/bank-transactions`.
`CarnetApp/Services/DomainsAPI.swift` — the domains surface: `domains` (the member's
domains and reading companions), `domains/:id/brief` (read, correct, erase, rewrite now),
`conversations` (the ones Maurice opened on his own, read here and marked read),
`maurices` (follow a book: a `companion` row), `users/me/device-token` (push, platform
`carnet-ios`). Content-role endpoints (garden, tasks, calendar, reading) live in
`CalibreAPI.swift` and `GardenAPI.swift`.

## Design system

Warm monochrome — cream/charcoal, ink-alpha hierarchy, **no hue-based accents**
(one muted sage "good" state aside). Defined in two mirrored places:

- `CarnetApp/CarnetTheme.swift` — the Swift token enum used by the app.
- the Maurice CSS token sheet, in the [Maurice repository](https://github.com/chezmaurice/chez-maurice) (shared vocabulary).

Type: italic-serif display (DM Serif Display), Geist/Inter sans, JetBrains Mono for
eyebrows/timestamps. Light ("paper") and dark ("studio") modes derive from the same
`--ink-rgb` alpha overlays.

## Roadmap

- [x] Household pairing, member picker + PIN, member switching
- [x] Server-driven dashboards + warm-monochrome widget set
- [x] Radial log FAB, Share Extension, offline queue
- [x] Coaching plan editing
- [ ] **Content role** — daily notes & dreams, garden fiches, tasks & calendar, reading
- [ ] Unified navigation across the three peer roles (Log · Dashboards · Content)
- [ ] Refreshed design pass covering the expanded scope

## Development

XcodeGen project (`project.yml`), iOS 17+, bundle `eu.chezmaurice.carnet.app`.

```sh
xcodegen generate      # regenerate Carnet.xcodeproj from project.yml
open Carnet.xcodeproj  # build & run the Carnet scheme
```

The app needs a reachable Maurice server to pair with; enter its URL on first launch.
