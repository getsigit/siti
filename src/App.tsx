import { useState, useRef, useEffect, KeyboardEvent, useCallback } from "react";
import "./App.css";
import Settings from "./Settings";
import {
  type ChatStatus,
  type ModelInfo,
  listModels,
  setModel,
  removeModel,
  sendMessage as sendMessageCmd,
  getStatus,
  getHistory,
  onStatusChanged,
  onReply,
  onTextDelta,
} from "./api";

type Role = "user" | "assistant";

interface Message {
  id: number;
  role: Role;
  text: string;
}

let nextId = 1;

function SendIcon() {
  return (
    <svg viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg">
      <path
        d="M2 8L14 8M14 8L9 3M14 8L9 13"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function GearIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
      <circle cx="12" cy="12" r="3" stroke="currentColor" strokeWidth="1.6" />
      <path
        d="M12 2.5v2M12 19.5v2M21.5 12h-2M4.5 12h-2M18.7 5.3l-1.4 1.4M6.7 17.3l-1.4 1.4M18.7 18.7l-1.4-1.4M6.7 6.7 5.3 5.3"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
      />
    </svg>
  );
}

function TypingBubble() {
  return (
    <div className="message-row assistant">
      <div className="bubble typing-indicator">
        <span className="typing-dot" />
        <span className="typing-dot" />
        <span className="typing-dot" />
      </div>
    </div>
  );
}

export default function App() {
  const [messages, setMessages] = useState<Message[]>([]);
  const [input, setInput] = useState("");
  const [thinking, setThinking] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [models, setModels] = useState<ModelInfo[]>([]);
  const [status, setStatus] = useState<ChatStatus>("unloaded");
  const [statusModel, setStatusModel] = useState<string | null>(null);
  const [statusError, setStatusError] = useState<string | null>(null);

  const bottomRef = useRef<HTMLDivElement>(null);
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  // Backend present? false when running in a plain browser (vite preview).
  const backendRef = useRef(true);
  // Message id of the assistant bubble being filled by `chat_text_delta`
  // events, or null when no reply is streaming.
  const streamingRef = useRef<number | null>(null);

  const refreshModels = useCallback(async () => {
    try {
      setModels(await listModels());
    } catch {
      /* backend unavailable, ignore */
    }
  }, []);

  // ── Wire backend: initial state, history, and live events ─────────────────
  useEffect(() => {
    let unStatus: (() => void) | undefined;
    let unReply: (() => void) | undefined;
    let unDelta: (() => void) | undefined;

    (async () => {
      try {
        const s = await getStatus();
        setStatus(s.status);
        setStatusModel(s.model_name);

        const history = await getHistory();
        const visible = history.filter(
          (m): m is typeof m & { role: Role } => m.role !== "system"
        );
        if (visible.length) {
          setMessages(
            visible.map((m) => ({
              id: nextId++,
              role: m.role,
              text: m.content,
            }))
          );
        }
        await refreshModels();
      } catch {
        backendRef.current = false;
      }

      try {
        unStatus = await onStatusChanged((p) => {
          setStatus(p.status);
          setStatusModel(p.model_name);
          setStatusError(p.error);
          if (p.status === "ready" || p.status === "error") refreshModels();
        });
        unDelta = await onTextDelta((p) => {
          // The first delta ends the typing indicator and opens the bubble.
          setThinking(false);
          if (streamingRef.current === null) {
            const id = nextId++;
            streamingRef.current = id;
            setMessages((prev) => [
              ...prev,
              { id, role: "assistant", text: p.delta },
            ]);
          } else {
            const id = streamingRef.current;
            setMessages((prev) =>
              prev.map((m) =>
                m.id === id ? { ...m, text: m.text + p.delta } : m
              )
            );
          }
        });
        unReply = await onReply((p) => {
          setThinking(false);
          const text = p.reply ?? (p.error ? `⚠️ ${p.error}` : null);
          const streamed = streamingRef.current;
          streamingRef.current = null;
          if (text === null) return;
          if (streamed !== null) {
            // The streamed bubble becomes the final text (or the error).
            setMessages((prev) =>
              prev.map((m) => (m.id === streamed ? { ...m, text } : m))
            );
          } else {
            setMessages((prev) => [
              ...prev,
              { id: nextId++, role: "assistant", text },
            ]);
          }
        });
      } catch {
        backendRef.current = false;
      }
    })();

    return () => {
      unStatus?.();
      unReply?.();
      unDelta?.();
    };
  }, [refreshModels]);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages, thinking]);

  function autoResize() {
    const el = textareaRef.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = Math.min(el.scrollHeight, 120) + "px";
  }

  async function sendMessage() {
    const text = input.trim();
    if (!text || thinking) return;

    setMessages((prev) => [...prev, { id: nextId++, role: "user", text }]);
    setInput("");
    if (textareaRef.current) textareaRef.current.style.height = "auto";
    setThinking(true);

    if (!backendRef.current) {
      // Browser preview fallback: no on-device engine available.
      await new Promise((r) => setTimeout(r, 700));
      setMessages((prev) => [
        ...prev,
        {
          id: nextId++,
          role: "assistant",
          text: `(preview) I'm Siti. On a device I'd answer: "${text}"`,
        },
      ]);
      setThinking(false);
      return;
    }

    try {
      // Reply arrives asynchronously via the `chat_reply` event listener.
      await sendMessageCmd(text);
    } catch (e) {
      setThinking(false);
      setMessages((prev) => [
        ...prev,
        { id: nextId++, role: "assistant", text: `⚠️ ${String(e)}` },
      ]);
    }
  }

  async function handleSelectModel(id: string) {
    setModels((prev) => prev.map((m) => ({ ...m, is_selected: m.id === id })));
    setStatus("loading");
    setStatusError(null);
    try {
      await setModel(id);
    } catch (e) {
      setStatus("error");
      setStatusError(String(e));
    }
  }

  async function handleRemoveModel(id: string) {
    try {
      await removeModel(id);
    } catch (e) {
      setStatusError(String(e));
    } finally {
      await refreshModels();
    }
  }

  function handleKeyDown(e: KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      sendMessage();
    }
  }

  const dotThinking =
    thinking || status === "loading" || status === "generating";
  const dotClass =
    status === "error" ? " error" : dotThinking ? " thinking" : "";

  const subtitle =
    status === "loading"
      ? `Loading ${statusModel ?? "model"}…`
      : status === "error"
      ? "Model error · tap ⚙"
      : statusModel
      ? `${statusModel} · private`
      : "on-device · private";

  return (
    <div className="app">
      <header className="header">
        <div className="header-title">
          <h1>Siti AI</h1>
          <span className="header-subtitle">{subtitle}</span>
        </div>
        <div className="header-actions">
          <span className={`status-dot${dotClass}`} />
          <button
            className="icon-button"
            onClick={() => setSettingsOpen(true)}
            aria-label="Settings"
          >
            <GearIcon />
          </button>
        </div>
      </header>

      <div className="messages">
        {messages.length === 0 && !thinking ? (
          <div className="empty-state">
            <div className="empty-icon">◇</div>
            <h2>How can I help?</h2>
            <p>Your personal assistant, running entirely on your device.</p>
          </div>
        ) : (
          messages.map((msg) => (
            <div key={msg.id} className={`message-row ${msg.role}`}>
              <div className="bubble">{msg.text}</div>
            </div>
          ))
        )}
        {thinking && <TypingBubble />}
        <div ref={bottomRef} />
      </div>

      <div className="input-area">
        <div className="input-form">
          <textarea
            ref={textareaRef}
            className="input-field"
            value={input}
            placeholder="Message Siti…"
            rows={1}
            onChange={(e) => {
              setInput(e.target.value);
              autoResize();
            }}
            onKeyDown={handleKeyDown}
          />
          <button
            className="send-button"
            onClick={sendMessage}
            disabled={!input.trim() || thinking}
            aria-label="Send"
          >
            <SendIcon />
          </button>
        </div>
        <p className="input-hint">Return to send · Shift+Return for new line</p>
      </div>

      <Settings
        open={settingsOpen}
        models={models}
        status={status}
        statusError={statusError}
        onSelectModel={handleSelectModel}
        onRemoveModel={handleRemoveModel}
        onClose={() => setSettingsOpen(false)}
      />
    </div>
  );
}
