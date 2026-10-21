
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

let CustomHooks = {};

// Guard only unsaved node forms; never persist form or credential values.
CustomHooks.NodeWorkflow = {
  mounted() {
    this.localDirty = false;
    this.sawServerDirty = false;
    this.resetKey = this.el.dataset.resetKey;
    this.allowLeave = () => (!this.localDirty && this.el.dataset.dirty !== "true") || window.confirm("Discard unsaved node changes?");
    this.onInput = event => {
      if (event.target.closest("#worker-edit-form, #service-form, #worker-enrollment-form, #worker-form")) this.localDirty = true;
    };
    this.el.addEventListener("input", this.onInput);
    this.el.addEventListener("change", this.onInput);
    this.remember = () => {
      this.path = location.href;
      this.position = history.state?.position;
    };
    this.remember();
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
    this.onPop = event => {
      if (this.restoring) {
        this.restoring = false;
        event.stopImmediatePropagation();
        return;
      }
      if (this.allowLeave()) return;
      event.stopImmediatePropagation();
      const distance = this.position - event.state?.position;
      if (Number.isFinite(distance) && distance !== 0) {
        this.restoring = true;
        history.go(distance);
      } else {
        history.pushState(history.state, "", this.path);
      }
    };
    document.addEventListener("click", this.onClick, true);
    document.addEventListener("change", this.onSelection, true);
    window.addEventListener("beforeunload", this.onUnload);
    window.addEventListener("popstate", this.onPop, true);
  },
  updated() {
    this.remember();
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
    window.removeEventListener("popstate", this.onPop, true);
  },
};

CustomHooks.ResetForm = {
  mounted() {
    this.handleEvent("reset_form", ({ id }) => {
      if (this.el.id === id) this.el.reset();
    });
    this.handleEvent("set_form_values", ({ id, values }) => {
      if (this.el.id !== id) return;
      for (const [name, value] of Object.entries(values)) {
        const field = this.el.elements.namedItem(name);
        if (field) field.value = value;
      }
    });
  },
};

CustomHooks.CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", (event) => {
      const target = this.el.dataset.target;
      const content = document.getElementById(target);

      if (!content) {
        console.error("Copy target not found:", target);
        return;
      }

      const text = content.textContent || content.innerText;

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
