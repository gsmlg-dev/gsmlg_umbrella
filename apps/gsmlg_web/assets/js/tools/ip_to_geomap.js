import 'https://esm-run.gsmlg.dev/@gsmlg/lit/d3-geo';

const btn = document.getElementById('submit-ip');
const ipGeoMap = document.getElementById('ip-geo-map');

document.querySelectorAll('d3-world-map').forEach((el) => {
  el.classList.remove('skeleton');
});

async function sendResult() {
  btn.disabled = true;

  const ipList = document.getElementById('ip-data').value
    .split(/\s+/)
    .filter((line) => !/^\s*$/.test(line));

  const points = [];

  for (const ip of ipList) {
    try {
      const resp = await fetch(`/api/toolbox/ip_to_geomap?ip=${encodeURIComponent(ip)}`);
      const { data } = await resp.json();
      if (data.latitude && data.longitude) {
        points.push([data.longitude, data.latitude]);
        ipGeoMap.setAttribute('points', JSON.stringify(points));
      }
    } catch {
      // skip failed lookups
    }
  }

  btn.disabled = false;
}

btn.addEventListener('click', sendResult);
