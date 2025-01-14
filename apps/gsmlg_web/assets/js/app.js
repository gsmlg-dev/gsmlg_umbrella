
import "phoenix_html";
// import '@gsmlg/lit/remark-element';
// import '@gsmlg/lit/d3-geo';

import { startSocket, joinChannels } from "./user_socket.js";
import topbar from "../vendor/topbar";


topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });

window.addEventListener("phx:page-loading-start", info => topbar.show());
window.addEventListener("phx:page-loading-stop", info => topbar.hide());

if (process.env.NODE_ENV === 'development') {
  console.log('NODE_ENV: ', process.env.NODE_ENV);
}

let socket;
document.addEventListener('socket:start', (event) => {
  const { token } = event.detail;
  socket = startSocket(token);
  joinChannels(socket);
});

document.addEventListener('socket:stop', (event) => {
  socket?.close();
});
