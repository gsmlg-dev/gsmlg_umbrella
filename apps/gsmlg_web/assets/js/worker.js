
import {Socket} from "phoenix"

const  idToPortMap  = {};

let socket;

const joinChannels = (socket) => {
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

const connectSocket = ({ userToken, csrfToken }) => {
  socket = new Socket("/socket", {params: {_csrf_token: csrfToken }});

  socket.connect();
  console.log('shared worker connected socket', socket);

  joinChannels(socket);
};

const connectChannel = (name) => {
  let channel = socket.channel(name, {});

  channel.join()
    .receive("ok", resp => { console.log("Joined successfully", resp) })
    .receive("error", resp => { console.log("Unable to join", resp) });

  return channel;
};


onconnect = e => {
  console.log('a new tab has connected to shared worker', e);

  // Get the MessagePort from the event. This will be the
  // communication channel between SharedWorker and the Tab
  const port =  e.ports[0];
  
  port.onmessage = msg  => {
    console.log('shared worker recieve message', msg, msg.data);

    idToPortMap[msg.data.from] = port;

    if (msg.data.type === 'start') {
      if (socket == null) {
        console.log('shared worker will connect socket', msg.data.data.csrfToken);
        connectSocket({ csrfToken: msg.data.data.csrfToken });
      } else {
        console.log('shared worker already connected socket');
      }
    } else {
      console.log('shared worker message type not recognized', msg.data.type, msg.data);
    }
  };

  port.start();
};

onerror = (e) => console.error('shared worker error:', e);

console.log('shared worker loaded', idToPortMap);
