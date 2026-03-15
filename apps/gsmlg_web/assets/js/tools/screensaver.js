import * as THREE from 'https://esm-run.gsmlg.dev/three';

let camera, scene, renderer, clock, smokeParticles;

const canvas = document.querySelector('#screen-saver-canvas');
const video = document.querySelector('#screen-saver-video');

init();
animate();

function init() {
  clock = new THREE.Clock();

  renderer = new THREE.WebGLRenderer({ canvas });
  renderer.setSize(640, 320);

  scene = new THREE.Scene();

  camera = new THREE.PerspectiveCamera(75, screen.width / screen.height, 1, 10000);
  camera.position.z = 1000;
  scene.add(camera);

  const light = new THREE.DirectionalLight(0xffffff, Math.E);
  light.position.set(-1, 0, 1);
  scene.add(light);

  const smokeTexture = new THREE.TextureLoader().load('/images/Smoke-Element.png');
  const smokeMaterial = new THREE.MeshLambertMaterial({
    color: 0x00dddd,
    map: smokeTexture,
    transparent: true,
  });
  const smokeGeo = new THREE.PlaneGeometry(300, 300);
  smokeParticles = [];

  for (let p = 0; p < 150; p++) {
    const particle = new THREE.Mesh(smokeGeo, smokeMaterial);
    const f = 500;
    particle.position.set(
      Math.random() * f - 250,
      Math.random() * f - 250,
      Math.random() * f * 2 - 100,
    );
    particle.rotation.z = Math.random() * 360;
    scene.add(particle);
    smokeParticles.push(particle);
  }
}

function animate() {
  const delta = clock.getDelta();
  requestAnimationFrame(animate);
  let sp = smokeParticles.length;
  while (sp--) {
    smokeParticles[sp].rotation.z += delta * 0.2;
  }
  renderer.render(scene, camera);
}

video.addEventListener('fullscreenchange', () => {
  if (document.fullscreenElement) {
    renderer.setSize(screen.width, screen.height);
    video.classList.remove('hidden');
    video.play();
  } else {
    renderer.setSize(640, 320);
    video.classList.add('hidden');
  }
});

function fullscreenCanvas() {
  const stream = canvas.captureStream(60);
  video.classList.remove('hidden');
  video.srcObject = stream;
  if (video.webkitEnterFullScreen && video.webkitSupportsFullscreen) {
    video.webkitEnterFullScreen();
  } else if (video.requestFullscreen) {
    video.requestFullscreen();
  } else {
    alert('Your browser does not support fullscreen mode.');
    renderer.setSize(screen.width, screen.height);
  }
  video.play();
}

document.querySelector('#screen-saver-trigger').addEventListener('click', fullscreenCanvas);
