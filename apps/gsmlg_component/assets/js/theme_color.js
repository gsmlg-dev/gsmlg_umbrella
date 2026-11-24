// Page bundles share one observer, including across Hologram navigation.
const state = globalThis[Symbol.for("gsmlg.theme-color")] ??= {};

export function mountThemeColor() {
  if (state.lifecycle?.document === document) {
    state.lifecycle.sync();
    return state.lifecycle;
  }
  state.lifecycle?.dispose();

  const page = document;
  const view = window;
  const canvas = page.createElement("canvas");
  canvas.width = canvas.height = 1;
  const context = canvas.getContext("2d", { colorSpace: "srgb", willReadFrequently: true });
  const sync = () => {
    const meta = page.querySelector('meta[name="theme-color"]');
    const primary = getComputedStyle(page.documentElement).getPropertyValue("--color-primary").trim();
    if (!meta || !primary) return;

    // Browser chrome expects an sRGB color, while Duskmoon tokens use OKLCH.
    let color = primary;
    if (context) {
      context.clearRect(0, 0, 1, 1);
      context.fillStyle = primary;
      context.fillRect(0, 0, 1, 1);
      const [red, green, blue] = context.getImageData(0, 0, 1, 1).data;
      color = `#${[red, green, blue].map(value => value.toString(16).padStart(2, "0")).join("")}`;
    }
    if (meta.getAttribute("content") !== color) meta.setAttribute("content", color);
  };
  const observer = new MutationObserver(sync);
  observer.observe(page.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
  page.addEventListener("load", sync, true);
  view.addEventListener("pageshow", sync);

  const lifecycle = {
    document: page,
    sync,
    dispose() {
      observer.disconnect();
      page.removeEventListener("load", sync, true);
      view.removeEventListener("pageshow", sync);
      if (state.lifecycle === lifecycle) state.lifecycle = undefined;
    },
  };
  state.lifecycle = lifecycle;
  sync();
  return lifecycle;
}
