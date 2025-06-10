// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import 'phoenix_html';
import './socket';

import { registerSW } from './register_sw.js';

registerSW();
