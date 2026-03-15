const form = document.getElementById('whois-form');
const input = document.getElementById('whois-input');
const btn = document.getElementById('whois-submit');
const result = document.getElementById('whois-result');

async function lookup() {
  const lookFor = input.value.trim();
  if (!lookFor) return;

  btn.disabled = true;
  result.innerHTML = '';

  try {
    const resp = await fetch(`/api/toolbox/whois?look_for=${encodeURIComponent(lookFor)}`);
    const json = await resp.json();

    if (!resp.ok) {
      result.innerHTML = `<div role="alert" class="alert alert-error alert-soft"><span>Error! ${json.error}</span></div>`;
      return;
    }

    const entries = json.data;
    result.innerHTML = entries.map(([server, info]) => `
      <div class="w-full card rounded-lg">
        <div class="card-body">
          <div class="card-title text-secondary">${server}</div>
          <pre class="whitespace-pre-line">${info}</pre>
        </div>
      </div>
    `).join('');
  } catch (err) {
    result.innerHTML = `<div role="alert" class="alert alert-error alert-soft"><span>Error! ${err.message}</span></div>`;
  } finally {
    btn.disabled = false;
  }
}

form.addEventListener('submit', (e) => {
  e.preventDefault();
  lookup();
});
