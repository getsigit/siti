// Typed wrappers around the Siti on-device chat backend (Rust/Tauri commands
// and events). Keeping the IPC surface in one place means components never
// touch raw command-name strings.

import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { getVersion } from "@tauri-apps/api/app";

export type ChatStatus =
  | "unloaded"
  | "loading"
  | "ready"
  | "generating"
  | "error";

export interface ModelInfo {
  id: string;
  name: string;
  org: string;
  description: string;
  approx_memory: string;
  size_bytes: number | null;
  is_downloaded: boolean;
  is_selected: boolean;
}

export interface ChatStatusResponse {
  status: ChatStatus;
  model_name: string | null;
  approx_memory: string | null;
  history_length: number;
}

export interface ChatStatusPayload {
  status: ChatStatus;
  model_name: string | null;
  error: string | null;
}

export interface ChatReplyPayload {
  reply: string | null;
  duration: string | null;
  error: string | null;
}

export interface ChatMessagePayload {
  role: "user" | "assistant";
  content: string;
}

// ── Commands ────────────────────────────────────────────────────────────────

export const listModels = () => invoke<ModelInfo[]>("chat_list_models");

export const setModel = (modelId: string) =>
  invoke<void>("chat_set_model", { modelId });

export const removeModel = (modelId: string) =>
  invoke<string>("chat_remove_model", { modelId });

export const sendMessage = (message: string) =>
  invoke<void>("chat_send_message", { message });

export const getStatus = () => invoke<ChatStatusResponse>("chat_get_status");

export const getHistory = () =>
  invoke<ChatMessagePayload[]>("chat_get_history");

export const clearHistory = () => invoke<void>("chat_clear_history");

/**
 * Bytes of a model's weights on disk so far, including a download still in
 * flight. Poll while the model is loading and compare against the model's
 * `size_bytes` to render real progress.
 */
export const getDownloadProgress = (modelId: string) =>
  invoke<number>("chat_download_progress", { modelId });

// ── App metadata ──────────────────────────────────────────────────────────

/** Marketing version (CFBundleShortVersionString) from tauri.conf.json. */
export const getAppVersion = () => getVersion();

/** Native build number (Apple CFBundleVersion); `null` when unavailable. */
export const getBuildVersion = () =>
  invoke<string | null>("app_build_version");

// ── Events ──────────────────────────────────────────────────────────────────

export const onStatusChanged = (cb: (p: ChatStatusPayload) => void): Promise<UnlistenFn> =>
  listen<ChatStatusPayload>("chat_status_changed", (e) => cb(e.payload));

export const onReply = (cb: (p: ChatReplyPayload) => void): Promise<UnlistenFn> =>
  listen<ChatReplyPayload>("chat_reply", (e) => cb(e.payload));

// ── Helpers ───────────────────────────────────────────────────────────────

/** Format a byte count as a compact "1.9 GB" / "941 MB" string. */
export function formatSize(bytes: number | null): string {
  if (!bytes) return "";
  const gb = bytes / 1e9;
  if (gb >= 1) return `${gb.toFixed(gb >= 10 ? 0 : 1)} GB`;
  return `${Math.round(bytes / 1e6)} MB`;
}
