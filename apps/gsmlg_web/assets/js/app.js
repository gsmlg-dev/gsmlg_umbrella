
import "phoenix_html";

import { startSocket, joinChannels } from "./user_socket.js";

import { registerSW } from './register_sw.js';

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

registerSW();
