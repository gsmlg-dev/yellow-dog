
import "../../../deps/phoenix_html/priv/static/phoenix_html.js";

import { Socket } from "../../../deps/phoenix/priv/static/phoenix.mjs";
import { LiveSocket } from "../../../deps/phoenix_live_view/priv/static/phoenix_live_view.esm.js";

import * as DuskmoonHooks from "../../../deps/phoenix_duskmoon/assets/js/hooks/index.js";





try {
  const theme = localStorage.getItem("theme");

  if (theme && theme !== "default") {
    document.documentElement.setAttribute("data-theme", theme);
  }
} catch (_err) {}

import EditorGuard from "./editor_guard.js";

let CustomHooks = {};
CustomHooks.EditorGuard = EditorGuard;

// Register before LiveSocket connects so rejected node traversals never reach
// its popstate handler. Inactive pages retain no hook or DOM reference.
let activeNodeWorkflow = null;
window.addEventListener("popstate", event => activeNodeWorkflow?.onPop(event), true);

// Guard only unsaved node forms; never persist form or credential values.
CustomHooks.NodeWorkflow = {
  mounted() {
    this.localDirty = false;
    this.sawServerDirty = false;
    this.resetKey = this.el.dataset.resetKey;
    this.allowLeave = () => {
      if (!this.localDirty && this.el.dataset.dirty !== "true") return true;
      if (!window.confirm("Discard unsaved node changes?")) return false;
      this.localDirty = false;
      this.sawServerDirty = false;
      this.el.dataset.dirty = "false";
      return true;
    };
    this.onInput = event => {
      if (event.target.closest("#worker-edit-form, #service-form, #worker-enrollment-form, #worker-form")) this.localDirty = true;
    };
    this.el.addEventListener("input", this.onInput);
    this.el.addEventListener("change", this.onInput);
    this.remember = () => {
      this.path = location.href;
      this.position = history.state?.position;
      this.entryIndex = window.navigation?.currentEntry?.index;
      this.entryKey = window.navigation?.currentEntry?.key;
    };
    // LiveView commits patch history after updated(). This event observes the
    // committed address; observation/validation diffs must not move the snapshot.
    this.remember();
    window.addEventListener("phx:navigate", this.remember);
    this.onClick = event => {
      const link = event.target.closest("a[href]");
      if (!link || event.defaultPrevented || link.target === "_blank" || link.hasAttribute("download")) return;
      const url = new URL(link.href, location.href);
      if (url.hash && url.pathname === location.pathname && url.search === location.search && !link.hasAttribute("data-phx-link")) return;
      if (!this.allowLeave()) {
        event.preventDefault();
        event.stopImmediatePropagation();
      }
    };
    this.onSelection = event => {
      if (!event.target.matches("#server-selection-form-select, #netman-selection-form-select")) return;
      if (!this.allowLeave()) {
        event.target.value = event.target.querySelector("option[selected]")?.value || "";
        event.stopImmediatePropagation();
      }
    };
    this.onUnload = event => {
      if (!this.localDirty && this.el.dataset.dirty !== "true") return;
      event.preventDefault();
      event.returnValue = "";
    };
    this.atRememberedEntry = () => this.entryKey
      ? window.navigation?.currentEntry?.key === this.entryKey
      : location.href === this.path && history.state?.position === this.position;
    this.restoreEntry = () => {
      if (this.entryKey && window.navigation?.traverseTo) {
        // Retarget the original entry even if another Back arrives before this
        // restoration finishes. A newer traversal may abort an earlier request.
        window.navigation.traverseTo(this.entryKey).finished.catch(() => {});
      } else {
        const currentIndex = window.navigation?.currentEntry?.index;
        const currentPosition = history.state?.position;
        const delta = Number.isInteger(this.entryIndex) && Number.isInteger(currentIndex)
          ? this.entryIndex - currentIndex
          : Number.isInteger(this.position) && Number.isInteger(currentPosition)
            ? this.position - currentPosition
            : 0;
        if (delta) history.go(delta);
      }
    };
    this.onPop = event => {
      if (this.restoring) {
        event.stopImmediatePropagation();
        if (this.atRememberedEntry()) this.restoring = false;
        else this.restoreEntry();
      } else if (!this.allowLeave()) {
        event.stopImmediatePropagation();
        this.restoring = true;
        this.restoreEntry();
      }
    };
    activeNodeWorkflow = this;
    document.addEventListener("click", this.onClick, true);
    document.addEventListener("change", this.onSelection, true);
    window.addEventListener("beforeunload", this.onUnload);
  },
  updated() {
    if (this.el.dataset.dirty === "true") this.sawServerDirty = true;
    else if (this.sawServerDirty || this.resetKey !== this.el.dataset.resetKey) {
      this.localDirty = false;
      this.sawServerDirty = false;
    }
    this.resetKey = this.el.dataset.resetKey;
  },
  destroyed() {
    this.el.removeEventListener("input", this.onInput);
    this.el.removeEventListener("change", this.onInput);
    document.removeEventListener("click", this.onClick, true);
    document.removeEventListener("change", this.onSelection, true);
    window.removeEventListener("beforeunload", this.onUnload);
    window.removeEventListener("phx:navigate", this.remember);
    if (activeNodeWorkflow === this) activeNodeWorkflow = null;
  },
};

CustomHooks.ResetForm = {
  mounted() {
    this.handleEvent("reset_form", ({ id }) => {
      if (this.el.id === id && !EditorGuard.hasNewerInput(this.el)) this.el.reset();
    });
    this.handleEvent("set_form_values", ({ id, values }) => {
      if (this.el.id !== id || EditorGuard.hasNewerInput(this.el)) return;
      for (const [name, value] of Object.entries(values)) {
        const field = this.el.elements.namedItem(name);
        if (field) field.value = value;
      }
    });
  },
};

let retiredBootstrap = null;
CustomHooks.TransientCredential = {
  mounted() {
    this.issuance = this.el.dataset.issuance;
    this.retired = retiredBootstrap === this.issuance;
    if (this.retired) {
      this.erase();
      this.pushEvent("retire_connection", { id: this.issuance });
    }
  },
  erase() {
    for (const field of this.el.querySelectorAll("textarea")) {
      field.value = "";
      field.defaultValue = "";
      field.textContent = "";
    }
    for (const button of this.el.querySelectorAll("[data-target]")) button.disabled = true;
    this.el.dataset.retired = "true";
  },
  disconnected() {
    this.offline = true;
    this.retired = true;
    retiredBootstrap = this.issuance;
    this.erase();
  },
  updated() {
    if (this.issuance !== this.el.dataset.issuance) {
      this.issuance = this.el.dataset.issuance;
      this.retired = this.offline || retiredBootstrap === this.issuance;
      if (this.retired) retiredBootstrap = this.issuance;
      else {
        delete this.el.dataset.retired;
        for (const button of this.el.querySelectorAll("[data-target]")) button.disabled = false;
      }
    }
    if (this.retired) this.erase();
  },
  reconnected() {
    this.offline = false;
    if (this.retired) {
      this.erase();
      this.pushEvent("retire_connection", { id: this.issuance });
    }
  },
};

CustomHooks.CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", (event) => {
      const target = this.el.dataset.target;
      const content = document.getElementById(target);

      if (this.el.disabled || content?.closest?.('[data-retired="true"]')) return;
      if (!content) {
        console.error("Copy target not found:", target);
        return;
      }

      const text = content.value ?? content.textContent ?? content.innerText;

      navigator.clipboard
        .writeText(text)
        .then(() => {
          this.pushEvent("copied", { target: target });
        })
        .catch((err) => {
          console.error("Copy failed:", err);
          this.pushEvent("copy_failed", { target: target, error: err.message });
        });
    });
  },
};


CustomHooks.CsvDownload = {
  mounted() {
    this.handleEvent("download_csv", ({ content, filename }) => {
      const blob = new Blob([content], { type: "text/csv;charset=utf-8;" });
      const url = URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.setAttribute("href", url);
      link.setAttribute("download", filename);
      document.body.appendChild(link);
      link.click();
      document.body.removeChild(link);
      URL.revokeObjectURL(url);
    });
  },
};

CustomHooks.TextDownload = {
  mounted() {
    this.handleEvent("download_text", ({ content, filename }) => {
      const blob = new Blob([content], { type: "text/plain;charset=utf-8;" });
      const url = URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.setAttribute("href", url);
      link.setAttribute("download", filename);
      document.body.appendChild(link);
      link.click();
      document.body.removeChild(link);
      URL.revokeObjectURL(url);
    });
  },
};


CustomHooks.LogAutoScroll = {
  mounted() {
    this.autoScroll = true;
    this.el.addEventListener("scroll", () => {

      const atBottom = this.el.scrollHeight - this.el.scrollTop <= this.el.clientHeight + 50;
      this.autoScroll = atBottom;
    });
  },
  updated() {
    if (this.autoScroll) {
      this.el.scrollTop = this.el.scrollHeight;
    }
  },
};

CustomHooks.PreserveScroll = {
  mounted() {
    this.saveScroll = () => {
      try {
        sessionStorage.setItem(this.storageKey(), String(this.scrollElement().scrollTop));
      } catch (_err) {}
    };

    this.restoreScroll = () => {
      try {
        const value = sessionStorage.getItem(this.storageKey());
        const top = value === null ? 0 : Number.parseInt(value, 10);

        if (Number.isFinite(top)) {
          this.scrollElement().scrollTop = top;
        }
      } catch (_err) {}
    };

    this.el.addEventListener("scroll", this.saveScroll, { passive: true, capture: true });
    requestAnimationFrame(this.restoreScroll);
  },
  beforeUpdate() {
    this.saveScroll();
  },
  updated() {
    requestAnimationFrame(this.restoreScroll);
  },
  destroyed() {
    this.saveScroll();
    this.el.removeEventListener("scroll", this.saveScroll, { capture: true });
  },
  scrollElement() {
    return this.el.querySelector(this.el.dataset.scrollTarget || ":scope") || this.el;
  },
  storageKey() {
    return `yellow-dog:${this.el.dataset.scrollKey || this.el.id}:scroll-top`;
  },
};

let Hooks = { ...DuskmoonHooks, ...CustomHooks };

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: Hooks,
});

liveSocket.connect();




window.liveSocket = liveSocket;
