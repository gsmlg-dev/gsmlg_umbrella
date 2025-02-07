// See the Tailwind configuration guide for advanced usage
// https://tailwindcss.com/docs/configuration
const path = require("path");

module.exports = {
  content: [
    "./js/**/*.js",
    "../../gsmlg_component/assets/**/*.js",
    "../lib/*_web.ex",
    "../lib/*_web/**/*.*ex",
    path.join(__dirname, "../../gsmlg_component/assets/**/*.js"),
    "../../gsmlg_component/lib/**/*.*ex",
    "../../../deps/phoenix_duskmoon/lib/**/*.*ex",
  ],
}
