# AGENTS.md

This file provides guidance to AI coding agents (Claude Code, etc.) when working with code in this repository. It is symlinked from the repo root as both `CLAUDE.md` and `AGENTS.md`.

## What this is

Siti AI — a private, on-device AI assistant for macOS and iOS (Android planned/supported by the engine). It's a thin Tauri (Rust + React) shell around **Onde**, an open-source on-device LLM inference engine published separately on crates.io. Siti is also the flagship reference app for Onde, so the Rust side is written to be read by people evaluating the engine.

The repo is a pnpm workspace with two independent apps:

| Path | What | Deploys to |
|---|---|---|
| `/` (root) | Tauri + Vite desktop/mobile app — the actual product | App Store / Play Store |
| `src/` | React UI for the Tauri app | (bundled into the app above) |
| `src-tauri/` | Rust core: Tauri commands, on-device inference wiring, platform setup | (native binary) |
| `web/` | Next.js marketing + legal site (getsiti.5mb.app) | smbCloud (`nextjs-ssr`, port 3034) — the *only* thing smbCloud deploys |

## Commands

Prefer `make <target>` — it wraps the underlying `pnpm`/`cargo` calls consistently. See `Makefile` for the full target list (also duplicated as comments at the top of the file).

```bash
pnpm install       # once, from repo root — installs both root and web/ workspaces

make dev           # start the Tauri dev server (pnpm tauri dev)
make build         # debug build (pnpm tauri build)
make fmt           # cargo fmt (src-tauri)
make lint          # clippy --all-targets -D warnings (src-tauri) + tsc --noEmit (root UI)
make clean         # cargo clean (src-tauri)

make web-dev       # Next.js landing page dev server → http://localhost:3034
make web-build     # production build (.next/standalone) for smbCloud
make web-deploy    # web-build + smb deploy
```

Release pipelines (each `make <x>` runs `./scripts/build-<platform>.sh <step>`; see the Makefile header comment for the full step list per platform):
- `make asmacos` — macOS App Store: build → sign → upload
- `make asios` — iOS App Store: clean → init → icons → override → build → upload
- `make psmobile` — Android Play Store: clean → init → icons → override → keystore → build → open (.aab)

No test suite exists yet (no `cargo test` / vitest / jest configured beyond what `cargo clippy --all-targets` type-checks). CI (`.github/workflows/ci.yml`) runs, on every push/PR: `pnpm build` (root UI type-check + build), `web/`'s `pnpm build`, then on macOS runners `cargo fmt --check`, `cargo clippy --all-targets -D warnings`, `cargo build --locked` in `src-tauri`.

**Single-package pnpm workspace note:** the root app and `web/` are independent pnpm workspace packages (see `pnpm-workspace.yaml`) sharing one lockfile. Use `pnpm --filter @siti/web <cmd>` to target `web/` specifically from the repo root (that's what `make web-*` does).

**Ruby tooling is irrelevant here** — this is a Rust/TS repo; ignore any global Ruby (`rv`) guidance for this project.

## Architecture

```
┌──────────────────────────────┐
│  React + Vite UI (src/)       │  chat view, model settings
├──────────────────────────────┤
│  Tauri command layer          │  src-tauri/src/chat/command_*.rs
│  (load/unload model, send,    │  typed IPC between UI and Rust
│   stream tokens, history)     │
├──────────────────────────────┤
│  Onde engine (crates.io)      │  GGUF load + streaming generation;
│  Metal on Apple, CPU on       │
│  Android                      │
└──────────────────────────────┘
```

### Rust core (`src-tauri/src/`)

- `lib.rs` — Tauri app entry (`run()`): registers the log plugin, runs `setup::setup()` before anything else, registers all `#[tauri::command]` handlers via `invoke_handler!`.
- `chat/mod.rs` — shared state and types for the whole chat feature: the `ENGINE` static (`onde::inference::ChatEngine`, lazily initialized), `SELECTED_MODEL` static, model/sampling config resolution, the system prompt, and small helpers (`fmt_duration`, `emit_chat_status`). Every `command_*.rs` file does `use super::*` to pull these in.
- `chat/command_*.rs` — one file per Tauri command (`chat_load_model`, `chat_send_message`, `chat_get_status`, `chat_list_models`, `chat_set_model`, `chat_clear_history`, `chat_get_history`, `chat_unload_model`). This is the cleanest place to see how a Tauri app wires into Onde.
- `setup/setup_application_filesystem.rs` — redirects `HF_HOME`, `HF_HUB_CACHE`, and `TMPDIR` into the shared Apple App Group container (`group.com.ondeinference.apps`) before any Onde/hf-hub/mistral.rs code runs, so sandboxed iOS/macOS builds can actually write the model cache. Must run before the `ENGINE` static initializes.
- `app_info.rs` — exposes the native build number to the frontend (`app_build_version` command).
- `events.rs` — Tauri event name constants (`chat_status_changed`, `chat_reply`) shared between Rust and the frontend's `listen()` calls.
- `constants.rs` — the `ChatStatus` enum mirrored to the frontend.

**Platform gating is pervasive and load-bearing.** Most chat internals (`ENGINE`, `SELECTED_MODEL`, model/sampling config functions, `chat_list_models`'s real implementation) are `#[cfg(any(target_os = "macos", target_os = "ios", target_os = "android"))]`-gated because on-device inference only exists on those targets; non-Apple/Android builds get stub implementations (e.g. `chat_list_models` returns `Vec::new()`). **This means CI only fully compiles and lints this code on `macos-latest`** — an `ubuntu-latest` runner would silently skip type-checking/linting everything behind that `cfg`, which is why the Rust CI job stays macOS-only even though it's slower.

Two other non-obvious constraints:
- `src-tauri/.cargo/config.toml` sets `+fullfp16,+fp16` target features for iOS/tvOS/Android arm64 targets — required for `gemm-common`'s NEON fp16 SIMD path used by inference; omitting it fails to assemble with `error: instruction requires: fullfp16`.
- `command_list_models.rs`'s `sanitize_description()` strips Android/Windows/Linux and cross-product ("siGit Code") mentions from the shared Onde model catalogue's descriptions on Apple builds only, per App Store Review Guideline 2.3.10 (Accurate Metadata). Don't let other-platform references leak back into Apple-facing strings anywhere in this file's descendants.

### Frontend (`src/`)

- `api.ts` — the only place that calls `invoke()`/`listen()` directly; every Tauri command/event has a typed wrapper here. Add new IPC surface here, not ad hoc in components.
- `App.tsx` / `Settings.tsx` — chat view and model-selection settings, respectively.

### Onde SDK development

Onde is normally pulled from crates.io (`onde = "1.3"` in `src-tauri/Cargo.toml`) — no separate SDK checkout needed for day-to-day work. To develop against a local sibling `onde` checkout instead, uncomment the `[patch.crates-io]` block at the bottom of `src-tauri/Cargo.toml`. Keep that block commented on `main`.

### `web/` (Next.js landing site)

Independent Next.js 15 app, App Router, Tailwind v4. Deployed standalone to smbCloud — see `next.config.mjs` (`output: "standalone"`, `images.unoptimized: true` to avoid needing a runtime `sharp`/`/_next/image` route in the multi-tenant smbCloud deploy, `outputFileTracingRoot` pinned to the monorepo root since it's nested in a pnpm workspace above it). Nothing else in this repo deploys to smbCloud.

## Contribution norms (from CONTRIBUTING.md)

- First-time contributors must sign the CLA (bot comments on the PR with a link).
- Before opening a PR: `make fmt`, `make lint` (must have zero warnings), `make build` (must compile).
- The codebase is deliberately well-commented where the *why* is non-obvious (see the platform-gating and fullfp16 notes above) — match that style; don't strip these comments or add ones that just restate the code.
- One logical change per PR; discuss non-trivial changes in an issue first.
