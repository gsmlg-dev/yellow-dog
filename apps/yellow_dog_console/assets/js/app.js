// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

// Duskmoon hooks and element registration
import * as DuskmoonHooks from "../../../../deps/phoenix_duskmoon/assets/js/hooks/index.js"
// WORKAROUND(upstream): duskmoon-dev/duskmoon-elements#50
// @duskmoon-dev/elements@1.2.0 registerAll() imports el-code-engine eagerly and
// crashes before LiveView hooks mount. The console currently uses CSS/HEEx
// components, so skip custom element registration until the package is fixed.

// Custom Hooks
let CustomHooks = {}

// Copy to Clipboard Hook
CustomHooks.CopyToClipboard = {
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

// CSV Download Hook
// Triggers a file download from server-pushed CSV content
CustomHooks.CsvDownload = {
  mounted() {
    this.handleEvent("download_csv", ({content, filename}) => {
      const blob = new Blob([content], {type: "text/csv;charset=utf-8;"})
      const url = URL.createObjectURL(blob)
      const link = document.createElement("a")
      link.setAttribute("href", url)
      link.setAttribute("download", filename)
      document.body.appendChild(link)
      link.click()
      document.body.removeChild(link)
      URL.revokeObjectURL(url)
    })
  }
}

// Log Auto-Scroll Hook
// Automatically scrolls to bottom when new logs arrive, unless user has scrolled up
CustomHooks.LogAutoScroll = {
  mounted() {
    this.autoScroll = true
    this.el.addEventListener('scroll', () => {
      // Check if user is near the bottom (within 50px)
      const atBottom = this.el.scrollHeight - this.el.scrollTop <= this.el.clientHeight + 50
      this.autoScroll = atBottom
    })
  },
  updated() {
    if (this.autoScroll) {
      this.el.scrollTop = this.el.scrollHeight
    }
  }
}

// Preserve a scroll container's position across LiveView navigation/remounts.
CustomHooks.PreserveScroll = {
  mounted() {
    this.saveScroll = () => {
      try {
        sessionStorage.setItem(this.storageKey(), String(this.el.scrollTop))
      } catch (_err) {
      }
    }

    this.restoreScroll = () => {
      try {
        const value = sessionStorage.getItem(this.storageKey())
        const top = value === null ? 0 : Number.parseInt(value, 10)

        if (Number.isFinite(top)) {
          this.el.scrollTop = top
        }
      } catch (_err) {
      }
    }

    this.el.addEventListener("scroll", this.saveScroll, {passive: true})
    requestAnimationFrame(this.restoreScroll)
  },
  beforeUpdate() {
    this.saveScroll()
  },
  updated() {
    requestAnimationFrame(this.restoreScroll)
  },
  destroyed() {
    this.saveScroll()
    this.el.removeEventListener("scroll", this.saveScroll)
  },
  storageKey() {
    return `yellow-dog:${this.el.dataset.scrollKey || this.el.id}:scroll-top`
  }
}

// Merge Duskmoon hooks with custom hooks
let Hooks = { ...DuskmoonHooks, ...CustomHooks }

// Intercept data-confirm clicks before LiveView processes them
document.body.addEventListener("click", (e) => {
  const el = e.target.closest("[data-confirm]")
  if (el && !confirm(el.dataset.confirm)) {
    e.preventDefault()
    e.stopPropagation()
  }
}, true)

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
