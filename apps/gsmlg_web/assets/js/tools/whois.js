const form = document.getElementById('whois-form');
const input = document.getElementById('whois-input');
const btn = document.getElementById('whois-submit');
const result = document.getElementById('whois-result');

// ─── Skeleton shimmer ─────────────────────────────────────────────────────────

(function injectSkeletonStyles() {
  const style = document.createElement('style');
  style.textContent = `
    @keyframes whois-shimmer {
      0%   { background-position: -200% 0; }
      100% { background-position:  200% 0; }
    }
    .whois-skel {
      border-radius: 0.375rem;
      background: linear-gradient(
        90deg,
        var(--color-base-300, oklch(90% 0.01 255)) 25%,
        var(--color-base-200, oklch(95% 0.008 255)) 50%,
        var(--color-base-300, oklch(90% 0.01 255)) 75%
      );
      background-size: 200% 100%;
      animation: whois-shimmer 1.4s ease-in-out infinite;
    }
    .whois-skel-card {
      border: 1px solid var(--color-base-300, oklch(90% 0.01 255));
      border-radius: 0.75rem;
      padding: 1.25rem 1.5rem;
      display: flex;
      flex-direction: column;
      gap: 0.75rem;
      width: 100%;
    }
  `;
  document.head.appendChild(style);
})();

function skelBar(w, h = '0.875rem') {
  return `<div class="whois-skel" style="width:${w};height:${h}"></div>`;
}

function renderWhoisSkeleton() {
  return `
    <div class="whois-skel-card">
      ${skelBar('40%', '1.5rem')}
      ${skelBar('100%')}
      ${skelBar('100%')}
      ${skelBar('80%')}
      ${skelBar('100%')}
      ${skelBar('60%')}
    </div>
  `;
}

function renderRdapSkeleton() {
  const box4 = `
    <div style="display:grid;grid-template-columns:repeat(2,1fr);gap:0.75rem">
      ${[1,2,3,4].map(() => `
        <div style="padding:0.75rem;border-radius:0.5rem;display:flex;flex-direction:column;gap:0.5rem;background:var(--color-base-200,oklch(95% 0.008 255))">
          ${skelBar('55%', '0.65rem')}
          ${skelBar('80%', '0.875rem')}
        </div>
      `).join('')}
    </div>
  `;
  const grid2 = (a, b) => `
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:1rem">
      <div class="whois-skel-card">${a}</div>
      <div class="whois-skel-card">${b}</div>
    </div>
  `;
  return `
    <div style="width:100%;display:flex;flex-direction:column;gap:1rem">
      <div class="whois-skel-card">
        <div style="display:flex;justify-content:space-between;align-items:flex-start">
          ${skelBar('45%', '2rem')}
          ${skelBar('4.5rem', '1.5rem')}
        </div>
        ${skelBar('30%', '0.65rem')}
        <div style="display:flex;gap:0.5rem">
          ${skelBar('7rem', '1.25rem')}
          ${skelBar('8rem', '1.25rem')}
          ${skelBar('6rem', '1.25rem')}
        </div>
      </div>
      <div class="whois-skel-card">
        ${skelBar('5rem', '1rem')}
        ${box4}
      </div>
      ${grid2(
        `${skelBar('6rem', '1rem')}
         ${skelBar('90%')} ${skelBar('70%')}`,
        `${skelBar('5rem', '1rem')}
         ${skelBar('100%', '0.65rem')} ${skelBar('100%', '0.65rem')}`
      )}
      <div class="whois-skel-card">
        ${skelBar('5rem', '1rem')}
        ${skelBar('50%', '1.25rem')}
      </div>
    </div>
  `;
}

function selectedProtocol() {
  const radio = form.querySelector('input[name="protocol"]:checked');
  return radio ? radio.value : 'whois';
}

// ─── WHOIS renderer ───────────────────────────────────────────────────────────

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

// ─── RDAP renderer ────────────────────────────────────────────────────────────

function fmtDate(iso) {
  try {
    return new Date(iso).toLocaleDateString('en-US', { year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
  } catch { return iso; }
}

function extractVcardFn(entity) {
  try {
    const fields = entity.vcardArray[1];
    const fn = fields.find(f => f[0] === 'fn');
    return fn ? fn[3] : null;
  } catch { return null; }
}

function extractVcardEmail(entity) {
  try {
    const fields = entity.vcardArray[1];
    const email = fields.find(f => f[0] === 'email');
    return email ? email[3] : null;
  } catch { return null; }
}

function statusBadgeClass(s) {
  if (s === 'ok' || s === 'active') return 'badge-success';
  if (s.includes('prohibited')) return 'badge-warning';
  if (s.includes('hold') || s.includes('redemption') || s.includes('delete')) return 'badge-error';
  return 'badge-primary';
}

const EVENT_META = {
  'registration':                   { label: 'Registered',    cls: 'text-success' },
  'expiration':                     { label: 'Expires',       cls: 'text-warning' },
  'last changed':                   { label: 'Last Changed',  cls: 'text-secondary' },
  'last update of RDAP database':   { label: 'DB Updated',    cls: 'text-secondary' },
  'transfer':                       { label: 'Transferred',   cls: 'text-info' },
  'deletion':                       { label: 'Deleted',       cls: 'text-error' },
};

function renderRdapHeader(data) {
  const name = data.ldhName || data.handle || data.name || 'Unknown';
  const cls = data.objectClassName || 'object';
  const handle = data.handle || '';
  const status = data.status || [];

  return `
    <div class="card w-full rounded-xl border border-base-300 shadow-sm">
      <div class="card-body gap-3">
        <div class="flex items-start justify-between flex-wrap gap-2">
          <div class="flex flex-col gap-1">
            <span class="font-mono text-3xl font-bold tracking-tight">${name}</span>
            ${handle ? `<span class="font-mono text-xs opacity-50">${handle}</span>` : ''}
          </div>
          <span class="badge badge-primary badge-md self-start">${cls}</span>
        </div>
        ${status.length ? `
          <div class="flex flex-wrap gap-1.5">
            ${status.map(s => `<span class="badge ${statusBadgeClass(s)} badge-sm">${s}</span>`).join('')}
          </div>
        ` : ''}
      </div>
    </div>
  `;
}

function renderRdapEvents(events) {
  if (!events || !events.length) return '';
  return `
    <div class="card w-full rounded-xl border border-base-300 shadow-sm">
      <div class="card-body gap-3">
        <div class="card-title text-base">Timeline</div>
        <div class="grid grid-cols-2 lg:grid-cols-4 gap-3">
          ${events.map(e => {
            const meta = EVENT_META[e.eventAction] || { label: e.eventAction, cls: 'text-base-content' };
            return `
              <div class="flex flex-col gap-1 p-3 rounded-lg bg-base-200">
                <span class="text-xs font-semibold uppercase tracking-widest ${meta.cls}">${meta.label}</span>
                <span class="font-mono text-sm leading-snug">${fmtDate(e.eventDate)}</span>
              </div>
            `;
          }).join('')}
        </div>
      </div>
    </div>
  `;
}

function renderRdapNameserversAndDNS(nameservers, secureDNS) {
  if (!nameservers?.length && !secureDNS) return '';

  let nsHtml = '';
  if (nameservers?.length) {
    nsHtml = `
      <div class="card rounded-xl border border-base-300 shadow-sm">
        <div class="card-body gap-3">
          <div class="card-title text-base">Nameservers</div>
          <ul class="flex flex-col gap-2">
            ${nameservers.map(ns => `
              <li class="flex items-center gap-2 font-mono text-sm">
                <span class="text-primary text-xs">▸</span>
                ${ns.ldhName}
              </li>
            `).join('')}
          </ul>
        </div>
      </div>
    `;
  }

  let dnsHtml = '';
  if (secureDNS) {
    const signed = secureDNS.delegationSigned;
    const dsData = secureDNS.dsData || [];
    dnsHtml = `
      <div class="card rounded-xl border border-base-300 shadow-sm">
        <div class="card-body gap-3">
          <div class="card-title text-base flex items-center gap-2">
            DNSSEC
            <span class="badge ${signed ? 'badge-success' : 'badge-ghost'} badge-sm">${signed ? '✓ Signed' : 'Unsigned'}</span>
          </div>
          ${dsData.map(ds => `
            <div class="p-3 rounded-lg bg-base-200 font-mono text-xs flex flex-col gap-1.5 break-all">
              <div class="flex gap-3">
                <span class="opacity-50 shrink-0">Key Tag</span><span>${ds.keyTag}</span>
                <span class="opacity-50 shrink-0 ml-4">Algorithm</span><span>${ds.algorithm}</span>
              </div>
              <div class="flex gap-3">
                <span class="opacity-50 shrink-0">Digest</span><span class="break-all">${ds.digest}</span>
              </div>
            </div>
          `).join('')}
        </div>
      </div>
    `;
  }

  return `<div class="grid grid-cols-1 md:grid-cols-2 gap-4">${nsHtml}${dnsHtml}</div>`;
}

function renderRdapRegistrar(entities) {
  const registrar = (entities || []).find(e => (e.roles || []).includes('registrar'));
  if (!registrar) return '';

  const name = extractVcardFn(registrar) || registrar.handle || '—';
  const publicId = registrar.publicIds?.[0];
  const abuseContact = (registrar.entities || []).find(e => (e.roles || []).includes('abuse'));
  const abuseEmail = abuseContact ? extractVcardEmail(abuseContact) : null;

  return `
    <div class="card w-full rounded-xl border border-base-300 shadow-sm">
      <div class="card-body gap-2">
        <div class="card-title text-base">Registrar</div>
        <div class="flex flex-wrap items-center gap-3">
          <span class="font-semibold">${name}</span>
          ${publicId ? `<span class="badge badge-ghost badge-sm font-mono">${publicId.type}: ${publicId.identifier}</span>` : ''}
          ${abuseEmail ? `<a href="mailto:${abuseEmail}" class="text-xs text-secondary opacity-70 hover:opacity-100">${abuseEmail}</a>` : ''}
        </div>
      </div>
    </div>
  `;
}

function renderRdapLinks(links) {
  const self = (links || []).filter(l => l.rel === 'self');
  if (!self.length) return '';
  return `
    <div class="flex flex-wrap gap-2">
      ${self.map(l => `
        <a href="${l.href}" target="_blank" rel="noopener"
           class="btn btn-sm btn-ghost font-mono text-xs border border-base-300 truncate max-w-full">
          ↗ ${l.href}
        </a>
      `).join('')}
    </div>
  `;
}

function renderRdap(data) {
  return `
    <div class="w-full flex flex-col gap-4">
      ${renderRdapHeader(data)}
      ${renderRdapEvents(data.events)}
      ${renderRdapNameserversAndDNS(data.nameservers, data.secureDNS)}
      ${renderRdapRegistrar(data.entities)}
      ${renderRdapLinks(data.links)}
    </div>
  `;
}

// ─── Lookup ───────────────────────────────────────────────────────────────────

async function lookup() {
  const lookFor = input.value.trim();
  if (!lookFor) return;

  btn.disabled = true;

  const protocol = selectedProtocol();
  result.innerHTML = protocol === 'rdap' ? renderRdapSkeleton() : renderWhoisSkeleton();

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
