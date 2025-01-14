import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

let token;

export const startSocket = (t) => {
  if (t) token = t;
  const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
  const params = { _csrf_token: csrfToken };
  if (token != null) {
    params.token = token;
  }
  const socket = new LiveSocket("/socket", Socket, { params, hooks: {} });
  return socket;
};

export const joinChannels = (socket) => {
  const channel = socket.channel("node:lobby", {});
  channel.join()
    .receive("ok", resp => { console.log("Joined successfully", resp) })
    .receive("error", resp => { console.log("Unable to join", resp) });

  channel.on('node_info', (info) => {
    console.log('node info: ', info);
  });
  channel.on('list_info', (info) => {
    console.log('list info: ', info);
  });
};
