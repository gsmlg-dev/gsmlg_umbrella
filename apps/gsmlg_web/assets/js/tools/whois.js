const form = document.getElementById('whois-form');
const input = document.getElementById('whois-input');
const btn = document.getElementById('whois-submit');
const result = document.getElementById('whois-result');

function selectedProtocol() {
  const radio = form.querySelector('input[name="protocol"]:checked');
  return radio ? radio.value : 'whois';
}

function renderWhois(entries) {
  return entries.map(([server, info]) => `
    <div class="w-full card rounded-lg">
      <div class="card-body">
        <div class="card-title text-secondary">${server}</div>
        <pre class="whitespace-pre-line">${info}</pre>
      </div>
    </div>
  `).join('');
}

function renderRdapValue(value, depth = 0) {
  if (value === null || value === undefined) return '<span class="opacity-50">—</span>';
  if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
    return `<span>${value}</span>`;
  }
  if (Array.isArray(value)) {
    if (value.length === 0) return '<span class="opacity-50">[]</span>';
    return `<ul class="ml-4 list-disc">${value.map(v => `<li>${renderRdapValue(v, depth + 1)}</li>`).join('')}</ul>`;
  }
  if (typeof value === 'object') {
    return `<dl class="ml-4">${Object.entries(value).map(([k, v]) =>
      `<div class="flex gap-2"><dt class="font-semibold min-w-32 text-secondary">${k}</dt><dd>${renderRdapValue(v, depth + 1)}</dd></div>`
    ).join('')}</dl>`;
  }
  return `<span>${String(value)}</span>`;
}

function renderRdap(data) {
  const entries = Object.entries(data);
  return `
    <div class="w-full card rounded-lg">
      <div class="card-body">
        <div class="card-title text-secondary">RDAP</div>
        <dl class="flex flex-col gap-1">
          ${entries.map(([k, v]) => `
            <div class="flex gap-2">
              <dt class="font-semibold min-w-40 text-secondary">${k}</dt>
              <dd class="break-all">${renderRdapValue(v)}</dd>
            </div>
          `).join('')}
        </dl>
      </div>
    </div>
  `;
}

async function lookup() {
  const lookFor = input.value.trim();
  if (!lookFor) return;

  btn.disabled = true;
  result.innerHTML = '';

  const protocol = selectedProtocol();

  try {
    let resp, json;

    if (protocol === 'rdap') {
      resp = await fetch(`/api/toolbox/whois/rdap?look_for=${encodeURIComponent(lookFor)}`);
      json = await resp.json();

      if (!resp.ok) {
        result.innerHTML = `<div role="alert" class="alert alert-error alert-soft"><span>Error! ${json.error}</span></div>`;
        return;
      }

      result.innerHTML = renderRdap(json.data);
    } else {
      resp = await fetch(`/api/toolbox/whois?look_for=${encodeURIComponent(lookFor)}`);
      json = await resp.json();

      if (!resp.ok) {
        result.innerHTML = `<div role="alert" class="alert alert-error alert-soft"><span>Error! ${json.error}</span></div>`;
        return;
      }

      result.innerHTML = renderWhois(json.data);
    }
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
