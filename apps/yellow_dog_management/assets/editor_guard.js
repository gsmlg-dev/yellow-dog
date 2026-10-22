// Page-local navigation protection. Only explicit editor resets acknowledge input;
// submission tokens and clean polling patches are not editor reset signals.
const editorStates = new WeakMap();
let activeEditorGuard = null;
const capturePopstate = event => activeEditorGuard?.onPop(event);
// This module is imported before LiveSocket connects. Suppress rejected pops
// before LiveView changes the mounted editor; retain no inactive DOM reference.
if (typeof window !== "undefined") window.addEventListener("popstate", capturePopstate, true);

const EditorGuard = {
  hasNewerInput(form) {
    const editor = editorStates.get(form);
    return !!editor?.dirty && (editor.submitted === undefined || editor.sequence > editor.submitted);
  },
  mounted() {
    window.addEventListener("popstate", capturePopstate, true);
    this.editors = new Map();
    this.syncEditors();
    this.selectedEditors = id => id && id !== "true"
      ? [this.editors.get(id)].filter(Boolean)
      : [...this.editors.values()];
    this.dirty = id => this.selectedEditors(id).some(editor =>
      editor.dirty || editor.form.dataset.editorDirty === "true");
    this.allowLeave = id => {
      if (!this.dirty(id)) return true;
      if (!window.confirm("Discard unsaved data changes?")) return false;
      for (const editor of this.selectedEditors(id)) {
        editor.dirty = false;
        editor.form.dataset.editorDirty = "false";
      }
      return true;
    };
    this.onInput = event => {
      const form = event.target.closest("form[data-editor]");
      if (!form || !this.el.contains(form)) return;
      this.syncEditors();
      const editor = this.editors.get(form.id);
      editor.dirty = true;
      editor.sequence++;
    };
    this.onSubmit = event => {
      const editor = this.editors.get(event.target.dataset.editorSubmit || event.target.id);
      if (editor) editor.submitted = editor.sequence;
    };
    this.onClick = event => {
      const confirm = event.target.closest("[data-editor-confirm]");
      if (confirm && this.dirty(confirm.dataset.editorConfirm)) {
        event.preventDefault();
        event.stopImmediatePropagation();
        window.alert("Save or explicitly discard the unsaved content before confirming its saved revision.");
        return;
      }
      const action = event.target.closest("[data-editor-discard], [data-editor-navigation], a[href]");
      if (!action || event.defaultPrevented || action.target === "_blank" || action.hasAttribute?.("download")) return;
      if (action.dataset.editorPreserve === "true") return;
      if (action.href) {
        const url = new URL(action.href, location.href);
        if (url.hash && url.pathname === location.pathname && url.search === location.search && !action.hasAttribute("data-phx-link")) return;
      }
      const wasDirty = this.dirty(action.dataset.editorDiscard);
      if (action.dataset.editorNavigation) action.setAttribute("phx-value-_discard", "false");
      if (!this.allowLeave(action.dataset.editorDiscard)) {
        event.preventDefault();
        event.stopImmediatePropagation();
      } else if (action.dataset.editorDiscard) {
        for (const editor of this.selectedEditors(action.dataset.editorDiscard)) editor.submitted = undefined;
      } else if (action.dataset.editorNavigation && wasDirty) {
        action.setAttribute("phx-value-_discard", "true");
      }
    };
    this.onSelection = event => {
      if (!event.target.matches("[data-editor-navigation], #server-selection-form-select, #netman-selection-form-select")) return;
      const discard = event.target.form?.querySelector('input[name="_discard"]');
      if (discard) discard.value = "false";
      const wasDirty = this.dirty();
      if (!this.allowLeave()) {
        event.target.value = event.target.querySelector("option[selected]")?.value || "";
        event.stopImmediatePropagation();
      } else if (discard && wasDirty) {
        discard.value = "true";
      }
    };
    this.onUnload = event => {
      if (!this.dirty()) return;
      event.preventDefault();
      event.returnValue = "";
    };
    this.remember = () => {
      this.path = location.href;
      this.position = history.state?.position;
      this.entryIndex = window.navigation?.currentEntry?.index;
      this.entryKey = window.navigation?.currentEntry?.key;
    };
    this.remember();
    this.atRememberedEntry = () => this.entryKey
      ? window.navigation?.currentEntry?.key === this.entryKey
      : location.href === this.path && history.state?.position === this.position;
    this.restoreEntry = () => {
      if (this.entryKey && window.navigation?.traverseTo) {
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
    activeEditorGuard = this;
    window.addEventListener("phx:navigate", this.remember);
    this.el.addEventListener("input", this.onInput);
    this.el.addEventListener("change", this.onInput);
    this.el.addEventListener("submit", this.onSubmit);
    document.addEventListener("click", this.onClick, true);
    document.addEventListener("change", this.onSelection, true);
    window.addEventListener("beforeunload", this.onUnload);
  },
  syncEditors() {
    const present = new Set();
    for (const form of this.el.querySelectorAll("form[data-editor]")) {
      present.add(form.id);
      let editor = this.editors.get(form.id);
      if (!editor) {
        editor = { form, reset: form.dataset.editorReset, dirty: false, sequence: 0 };
        this.editors.set(form.id, editor);
      } else {
        editor.form = form;
        if (editor.reset !== form.dataset.editorReset) {
          editor.dirty = editor.submitted !== undefined && editor.sequence > editor.submitted;
          editor.submitted = undefined;
          editor.reset = form.dataset.editorReset;
        }
      }
      editorStates.set(form, editor);
    }
    for (const id of this.editors.keys()) if (!present.has(id)) this.editors.delete(id);
  },
  updated() {
    this.syncEditors();
  },
  destroyed() {
    this.el.removeEventListener("input", this.onInput);
    this.el.removeEventListener("change", this.onInput);
    this.el.removeEventListener("submit", this.onSubmit);
    document.removeEventListener("click", this.onClick, true);
    document.removeEventListener("change", this.onSelection, true);
    window.removeEventListener("beforeunload", this.onUnload);
    window.removeEventListener("phx:navigate", this.remember);
    if (activeEditorGuard === this) activeEditorGuard = null;
  },
};

export default EditorGuard;
