// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

// Hooks
let Hooks = {}

// Theme Toggle Hook
Hooks.ThemeToggle = {
  mounted() {
    // Load saved theme from localStorage or default to 'light'
    const savedTheme = localStorage.getItem('theme') || 'light'
    document.documentElement.setAttribute('data-theme', savedTheme)

    // Set checkbox state based on saved theme
    this.el.checked = savedTheme === 'dark'

    // Listen for changes
    this.el.addEventListener('change', (e) => {
      const newTheme = e.target.checked ? 'dark' : 'light'
      document.documentElement.setAttribute('data-theme', newTheme)
      localStorage.setItem('theme', newTheme)
    })
  }
}

// Copy to Clipboard Hook
Hooks.CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", (e) => {
      const target = this.el.dataset.target
      const content = document.getElementById(target)

      if (!content) {
        console.error("Copy target not found:", target)
        return
      }

      const text = content.textContent || content.innerText

      navigator.clipboard.writeText(text).then(() => {
        this.pushEvent("copied", {target: target})
      }).catch(err => {
        console.error("Copy failed:", err)
        this.pushEvent("copy_failed", {target: target, error: err.message})
      })
    })
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket
