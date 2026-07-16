import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

import { hooks } from './hooks';

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");

// LiveSocket for LiveView — connects to /live
const liveSocket = new LiveSocket("/live", Socket, { params: { _csrf_token: csrfToken }, hooks });

// Separate raw Socket for custom channels — connects to /socket (UserSocket)
const userSocket = new Socket("/socket", { params: { _csrf_token: csrfToken } });

export const joinChannels = () => {
  userSocket.connect();
  const channel = userSocket.channel("node:lobby", {});
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


// connect if there are any LiveViews on the page
liveSocket.connect();

joinChannels();

if (process.env.NODE_ENV === 'development') {
  // expose liveSocket on window for web console debug logs and latency simulation:
  // >> liveSocket.enableDebug()
  // >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
  // >> liveSocket.disableLatencySim()
  window.liveSocket = liveSocket;

  liveSocket.enableDebug()
}
