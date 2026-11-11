// Shared renderer doubles for browser lifecycle tests; no network or WebGL required.
export const resources = [];
class Resource {
  constructor() { this.disposed = false; resources.push(this); }
  dispose() { this.disposed = true; }
}
class Position { set() {} }
export class Mesh {
  constructor() { this.position = new Position(); this.rotation = { z: 0 }; }
}
export class WebGLRenderer extends Resource {
  setSize(width, height) { this.size = [width, height]; }
  render() {}
}
export class Clock { getDelta() { return 0.1; } }
export class Scene { add() {} }
export class PerspectiveCamera { constructor() { this.position = {}; } }
export class DirectionalLight { constructor() { this.position = new Position(); } }
export class TextureLoader { load() { return new Resource(); } }
export { Resource as MeshLambertMaterial, Resource as PlaneGeometry };
