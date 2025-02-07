// See the Tailwind configuration guide for advanced usage
// https://tailwindcss.com/docs/configuration
const path = require("path");

module.exports = {
  content: [
    path.join(__dirname, "js/**/*.js"),
    path.join(__dirname, "../lib/*_web.ex"),
    path.join(__dirname, "../lib/*_web/**/*.*ex"),
    path.join(__dirname, "../../gsmlg_component/assets/**/*.js"),
    path.join(__dirname, "../../gsmlg_component/lib/**/*.*ex"),
    path.join(__dirname, "../../../deps/phoenix_duskmoon/lib/phoenix_duskmoon/**/*.*ex"),
  ],
}
