// Bring in Phoenix channels client library:
import { Socket } from "phoenix"

export const resetSocketWithToken = (t) => {
  let token = window.userToken;
  if (t) token = t;
  const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
  const params = { _csrf_token: csrfToken };
  if (token != null) {
    params.token = token;
  }
  const socket = new Socket("/socket", { params });
  return socket;
};

// And connect to the path in "lib/gsmlg_web/endpoint.ex". We pass the
// token for authentication. Read below how it should be used.
export const socket = resetSocketWithToken();

export const joinChannels = () => {
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