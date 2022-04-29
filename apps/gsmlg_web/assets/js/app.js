// We import the CSS which is extracted to its own file by esbuild.
// Remove this line if you add a your own CSS build pipeline (e.g postcss).
import "../css/app.css";


// import { bindAppMenu } from './base-control';
// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
import { socket, resetSocketWithToken, joinChannels } from "./user_socket.js";

window.addEventListener('DOMContentLoaded', (event) => {
    // console.log('DOM fully loaded and parsed');
    socket.connect();
    joinChannels();

});

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";

// Inclue webcomponet material web componetn and @gsmlg/lit
import "phoenix_webcomponent";

// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import topbar from "../vendor/topbar";

import './components/index';

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, { params: { _csrf_token: csrfToken } });

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", info => topbar.show());
window.addEventListener("phx:page-loading-stop", info => topbar.hide());

// connect if there are any LiveViews on the page
liveSocket.connect();


if (process.env.NODE_ENV === 'development') {

    window.socket = socket;
    window.resetSocketWithToken = resetSocketWithToken;

    // expose liveSocket on window for web console debug logs and latency simulation:
    // >> liveSocket.enableDebug()
    // >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
    // >> liveSocket.disableLatencySim()
    window.liveSocket = liveSocket;

    liveSocket.enableDebug()
    // liveSocket.enableLatencySim(100)
    console.log('NODE_ENV: ', process.env.NODE_ENV);
}

const bindAppMenu = () => {

    const drawer = document.getElementsByTagName('mwc-drawer')[0];
    if (drawer) {
        const container = drawer.parentNode;
        container.addEventListener('MDCTopAppBar:nav', () => {
            drawer.open = !drawer.open;
        });
    }

    const btn = document.getElementById('account');
    const menu = document.getElementById('account-menu');
    if (btn && menu) {
        menu.anchor = btn;
        menu.corner = 'BOTTOM_END';

        btn.addEventListener('click', function (e) {
            menu.open = true;
            // alternatively you can use menu.show();
        });
    }
};

bindAppMenu();

const forms = document.getElementsByTagName('form');

[].slice.call(forms).forEach((f) => {
    f.addEventListener('click', (evt) => {
        const el = evt.srcElement;
        const t = el.getAttribute('type');
        // console.log(evt)
        // console.log(el, el.tagName, t);
        if (el.tagName === 'BX-BTN' && t === 'submit') {
            evt.stopPropagation();
            f.submit();
        }
    });
});
