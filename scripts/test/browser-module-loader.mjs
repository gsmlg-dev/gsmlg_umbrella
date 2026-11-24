// Substitute the same browser-only remote modules in every page-bundle import.
export async function resolve(specifier, context, nextResolve) {
  if (specifier === "https://esm-run.gsmlg.dev/three") {
    return { url: new URL("./browser-three.mjs", import.meta.url).href, shortCircuit: true };
  }
  return nextResolve(specifier, context);
}
