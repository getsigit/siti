import { useEffect, useMemo, useState } from "react";
import type { ChatStatus, ModelInfo } from "./api";
import {
  formatSize,
  getAppVersion,
  getBuildVersion,
  getDownloadProgress,
} from "./api";
import { openUrl } from "@tauri-apps/plugin-opener";

interface SettingsProps {
  open: boolean;
  models: ModelInfo[];
  status: ChatStatus;
  statusError: string | null;
  onSelectModel: (id: string) => void;
  onRemoveModel: (id: string) => void;
  onClose: () => void;
}

// Down-arrow-into-tray: download action for a not-yet-downloaded model.
function DownloadIcon() {
  return (
    <svg viewBox="0 0 20 20" width="18" height="18" aria-hidden>
      <path
        d="M10 3v9m0 0 3.5-3.5M10 12 6.5 8.5M4 14.5V16a1 1 0 0 0 1 1h10a1 1 0 0 0 1-1v-1.5"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

// Trash: remove a downloaded model's weights from disk.
function TrashIcon() {
  return (
    <svg viewBox="0 0 20 20" width="18" height="18" aria-hidden>
      <path
        d="M4 6h12M8 6V4.5a1 1 0 0 1 1-1h2a1 1 0 0 1 1 1V6m1.5 0-.6 9a1.5 1.5 0 0 1-1.5 1.4H8.1A1.5 1.5 0 0 1 6.6 15L6 6m2.5 2.5v5m3-5v5"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

// Filled check badge: model is downloaded and available offline.
function DownloadedIcon() {
  return (
    <svg viewBox="0 0 20 20" width="18" height="18" aria-hidden>
      <circle cx="10" cy="10" r="8" fill="currentColor" />
      <path
        d="m6.5 10.2 2.4 2.4 4.6-4.8"
        fill="none"
        stroke="var(--surface, #1c1c1e)"
        strokeWidth="1.8"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

/** Live weight-download progress, or `null` when there is nothing to report. */
interface DownloadProgress {
  /** 0–1, clamped. */
  fraction: number;
  downloaded: number;
  total: number;
}

/**
 * Treat the download as finished slightly before the byte counts match. The
 * small JSON assets (config, tokenizer) aren't in the model's expected size, and
 * the last blob is renamed off `.part` only once complete, so the tail of the
 * transfer is jumpy. Past this point the wait is the model loading into memory,
 * which is what the user should be told.
 */
const DOWNLOAD_DONE_FRACTION = 0.999;

function statusLine(
  status: ChatStatus,
  error: string | null,
  progress: DownloadProgress | null
) {
  switch (status) {
    case "loading":
      if (progress && progress.fraction < DOWNLOAD_DONE_FRACTION) {
        const pct = Math.floor(progress.fraction * 100);
        // Byte detail is noise before the first chunk lands.
        const detail =
          progress.downloaded > 0
            ? ` · ${formatSize(progress.downloaded)} of ${formatSize(progress.total)}`
            : "";
        return { text: `Downloading… ${pct}%${detail}`, cls: "loading" };
      }
      if (progress) return { text: "Loading into memory…", cls: "loading" };
      return { text: "Downloading / loading…", cls: "loading" };
    case "ready":
      return { text: "Ready", cls: "ready" };
    case "generating":
      return { text: "Generating…", cls: "loading" };
    case "error":
      return { text: error ?? "Failed to load model", cls: "error" };
    default:
      return { text: "Not loaded", cls: "" };
  }
}

export default function Settings({
  open,
  models,
  status,
  statusError,
  onSelectModel,
  onRemoveModel,
  onClose,
}: SettingsProps) {
  const selected = useMemo(
    () => models.find((m) => m.is_selected) ?? models[0],
    [models]
  );
  const busy = status === "loading";

  // Poll the cache while a model loads so the indeterminate spinner becomes a
  // real percentage. mistral.rs owns the transfer and reports progress only to
  // the log, so bytes-on-disk is the only signal available to the UI.
  const [downloadedBytes, setDownloadedBytes] = useState<number | null>(null);
  const selectedId = selected?.id;
  useEffect(() => {
    if (!open || status !== "loading" || !selectedId) {
      setDownloadedBytes(null);
      return;
    }
    let active = true;
    const tick = async () => {
      const bytes = await getDownloadProgress(selectedId).catch(() => null);
      if (active && bytes !== null) setDownloadedBytes(bytes);
    };
    void tick();
    const timer = window.setInterval(tick, 1000);
    return () => {
      active = false;
      window.clearInterval(timer);
    };
  }, [open, status, selectedId]);

  const progress = useMemo<DownloadProgress | null>(() => {
    const total = selected?.size_bytes;
    if (status !== "loading" || !total || downloadedBytes === null) return null;
    return {
      fraction: Math.min(downloadedBytes / total, 1),
      downloaded: downloadedBytes,
      total,
    };
  }, [status, selected?.size_bytes, downloadedBytes]);

  const line = statusLine(status, statusError, progress);

  const handleOpenUrl = (url: string) => (e: React.MouseEvent) => {
    e.preventDefault();
    void openUrl(url);
  };

  // Real app version (CFBundleShortVersionString) and build number
  // (CFBundleVersion), read from the bundle rather than hardcoded.
  const [appVersion, setAppVersion] = useState("");
  useEffect(() => {
    let active = true;
    (async () => {
      const [version, build] = await Promise.all([
        getAppVersion().catch(() => ""),
        getBuildVersion().catch(() => null),
      ]);
      if (!active) return;
      setAppVersion(build && build !== version ? `${version} (${build})` : version);
    })();
    return () => {
      active = false;
    };
  }, []);

  return (
    <div className={`settings-overlay${open ? " open" : ""}`} aria-hidden={!open}>
      <header className="settings-header">
        <h1>Settings</h1>
        <button className="settings-done" onClick={onClose}>
          Done
        </button>
      </header>

      <div className="settings-content">
        <section className="settings-section">
          <p className="section-label">Model</p>

          <div className="settings-card">
            <div className="settings-row">
              <span className="row-label">On-device model</span>
              <div className="select-wrap">
                <select
                  className="model-select"
                  value={selected?.id ?? ""}
                  disabled={busy || models.length === 0}
                  onChange={(e) => onSelectModel(e.target.value)}
                >
                  {models.length === 0 && <option value="">Unavailable</option>}
                  {models.map((m) => (
                    <option key={m.id} value={m.id}>
                      {m.name}
                      {m.size_bytes ? ` · ${formatSize(m.size_bytes)}` : ""}
                    </option>
                  ))}
                </select>
                <svg className="chevron" viewBox="0 0 12 8" aria-hidden>
                  <path
                    d="M1 1.5 6 6.5 11 1.5"
                    stroke="currentColor"
                    strokeWidth="1.6"
                    fill="none"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                  />
                </svg>
              </div>
            </div>

            {selected && (
              <div className="model-detail">
                <span className="model-org">{selected.org}</span>
                <p className="model-desc">{selected.description}</p>
                <div className={`model-status ${line.cls}`}>
                  <span className="model-status-dot" />
                  {line.text}
                </div>
                {progress && progress.fraction < DOWNLOAD_DONE_FRACTION && (
                  <div
                    className="model-progress"
                    role="progressbar"
                    aria-valuenow={Math.floor(progress.fraction * 100)}
                    aria-valuemin={0}
                    aria-valuemax={100}
                    aria-label="Model download progress"
                  >
                    <div
                      className="model-progress-fill"
                      style={{ width: `${progress.fraction * 100}%` }}
                    />
                  </div>
                )}
              </div>
            )}
          </div>

          <p className="settings-note">
            The model downloads the first time you pick it, so use Wi-Fi if you
            can. It then runs on your device, and nothing you type is sent to a
            server.
          </p>
        </section>

        <section className="settings-section">
          <p className="section-label">Supported Models</p>
          <div className="settings-card model-list">
            {models.length === 0 && (
              <div className="settings-row">
                <span className="row-value">No models available.</span>
              </div>
            )}
            {models.map((m) => (
              <div className="model-list-row" key={m.id}>
                <div className="model-list-info">
                  <span className="model-list-name">{m.name}</span>
                  <span className="model-list-meta">
                    {m.org}
                    {m.size_bytes ? ` · ${formatSize(m.size_bytes)}` : ""}
                  </span>
                </div>
                <div className="model-list-actions">
                  {m.is_downloaded ? (
                    <>
                      <span
                        className="model-downloaded"
                        title="Downloaded"
                        aria-label="Downloaded"
                      >
                        <DownloadedIcon />
                      </span>
                      <button
                        className="model-action remove"
                        onClick={() => onRemoveModel(m.id)}
                        disabled={busy}
                        title="Remove download"
                        aria-label={`Remove ${m.name}`}
                      >
                        <TrashIcon />
                      </button>
                    </>
                  ) : (
                    <button
                      className="model-action download"
                      onClick={() => onSelectModel(m.id)}
                      disabled={busy}
                      title="Download"
                      aria-label={`Download ${m.name}`}
                    >
                      <DownloadIcon />
                    </button>
                  )}
                </div>
              </div>
            ))}
          </div>
        </section>

        <section className="settings-section">
          <p className="section-label">About</p>
          <div className="settings-card about">
            <div className="settings-row">
              <span className="row-label">Siti AI</span>
              <span className="row-value">{appVersion}</span>
            </div>
            <div className="settings-row">
              <span className="row-label">Privacy</span>
              <span className="row-value">On-device · private</span>
            </div>
          </div>
        </section>

        <section className="settings-section">
          <p className="section-label">Contact</p>
          <div className="settings-card about">
            <div className="settings-row">
              <span className="row-label">GitHub</span>
              <a
                className="row-value row-link"
                href="https://github.com/getsigit/siti"
                onClick={handleOpenUrl("https://github.com/getsigit/siti")}
              >
                getsigit/siti
              </a>
            </div>
            <div className="settings-row">
              <span className="row-label">Website</span>
              <a
                className="row-value row-link"
                href="https://getsiti.5mb.app"
                onClick={handleOpenUrl("https://getsiti.5mb.app")}
              >
                https://getsiti.5mb.app
              </a>
            </div>
          </div>
          <p className="settings-note">Profoundly personal. Entirely private.</p>
        </section>
      </div>
    </div>
  );
}
