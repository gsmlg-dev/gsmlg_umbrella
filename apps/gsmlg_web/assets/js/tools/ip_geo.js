const form = document.getElementById('ip-geo-form');
const input = document.getElementById('ip-input');
const btn = document.getElementById('ip-submit');
const result = document.getElementById('ip-result');

async function lookup() {
  const ip = input.value.trim();
  if (!ip) return;

  btn.disabled = true;
  result.innerHTML = '';

  try {
    const resp = await fetch(`/api/toolbox/ip_geo?ip=${encodeURIComponent(ip)}`);
    const json = await resp.json();

    if (!resp.ok) {
      result.innerHTML = `<div role="alert" class="alert alert-error alert-soft"><span>Error: ${json.error}</span></div>`;
      return;
    }

    const info = json.data;
    result.innerHTML = `
      <div class="w-96 flex flex-row justify-start items-start">
        <div class="w-24 min-w-max text-right pr-2 after:content-[':']">continent</div>
        <div>${info.continent ?? ''}</div>
      </div>
      <div class="w-96 flex flex-row justify-start items-start">
        <div class="w-24 min-w-max text-right pr-2 after:content-[':']">country</div>
        <div>${info.country ?? ''}</div>
      </div>
      <div class="w-96 flex flex-row justify-start items-start">
        <div class="w-24 min-w-max text-right pr-2 after:content-[':']">city</div>
        <div>${info.city ?? ''}</div>
      </div>
      <div class="w-96 flex flex-row justify-start items-start">
        <div class="w-24 min-w-max text-right pr-2 after:content-[':']">coordinate</div>
        <div>latitude: ${info.latitude}  longitude: ${info.longitude}</div>
      </div>
      <div class="2xl:w-2/3 xl:w-3/4 lg:w-4/5 w-full aspect-2/1 flex flex-row justify-center items-center">
        <d3-world-map
          class="w-full h-full"
          points="${JSON.stringify([[info.longitude, info.latitude]])}"
          center-longitude="${info.longitude}"
        ></d3-world-map>
      </div>
    `;

    import('https://esm-run.gsmlg.dev/@gsmlg/lit/d3-geo');
  } catch (err) {
    result.innerHTML = `<div role="alert" class="alert alert-error alert-soft"><span>Error: ${err.message}</span></div>`;
  } finally {
    btn.disabled = false;
  }
}

form.addEventListener('submit', (e) => {
  e.preventDefault();
  lookup();
});
