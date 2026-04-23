import {Socket} from "/assets/vendor/phoenix.mjs"
import {LiveSocket} from "/assets/vendor/phoenix_live_view.esm.js"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrfToken}})

liveSocket.connect()

window.liveSocket = liveSocket
