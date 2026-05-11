import {Socket} from "/assets/vendor/phoenix.mjs"
import {LiveSocket} from "/assets/vendor/phoenix_live_view.esm.js"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrfToken}})

liveSocket.connect()

window.liveSocket = liveSocket

// LoadingLive pushes this event when the app is ready, so we can
// replace the current history entry instead of pushing a new one.
// Without this, the loading page would stay in history and "back" from
// the app would land on it (and re-trigger startup).
window.addEventListener("phx:bates:replace-navigate", (event) => {
  window.location.replace(event.detail.url)
})
