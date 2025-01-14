// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import 'phoenix_html';
import 'phoenix_duskmoon';
import './socket';
import {topbar} from '../vendor/topbar';

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: '#29d' }, shadowColor: 'rgba(0, 0, 0, .3)' });
window.addEventListener('phx:page-loading-start', info => topbar.show());
window.addEventListener('phx:page-loading-stop', info => topbar.hide());

