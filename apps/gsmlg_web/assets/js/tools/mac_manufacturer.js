const form = document.getElementById('mac-form');
const input = document.getElementById('mac-input');
const btn = document.getElementById('mac-submit');
const result = document.getElementById('mac-result');

async function lookup() {
  const mac = input.value.trim();
  if (!mac) return;

  btn.disabled = true;
  result.innerHTML = '';

  try {
    const resp = await fetch(`/api/toolbox/mac_manufacturer?mac=${encodeURIComponent(mac)}`);
    const json = await resp.json();

    if (!resp.ok) {
      result.innerHTML = `
        <div class="w-96 flex flex-row justify-start items-start">
          <div class="w-32 text-right pr-2 after:content-[':']">Short</div>
          <div>Unknown</div>
        </div>
      `;
      return;
    }

    const { short, full } = json.data;
    result.innerHTML = `
      <div class="w-96 flex flex-row justify-start items-start">
        <div class="w-32 text-right pr-2 after:content-[':']">Short</div>
        <div>${short}</div>
      </div>
      ${full ? `
      <div class="w-96 flex flex-row justify-start items-start">
        <div class="w-32 text-right pr-2 after:content-[':']">Full Information</div>
        <div>${full}</div>
      </div>` : ''}
    `;
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
