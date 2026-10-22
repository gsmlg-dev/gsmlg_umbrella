// Each Hologram page bundles this adapter; keep one owner for the document.
const layoutState = globalThis[Symbol.for('gsmlg.toolbox.layout')] ??= {};

export function unmountLayout() {
  layoutState.lifecycle?.dispose();
  layoutState.lifecycle = undefined;
}

export function mountLayout() {
  if (layoutState.lifecycle?.document !== document) unmountLayout();
  if (layoutState.lifecycle) return layoutState.lifecycle.sync();

  const headers = new Map();
  const media = window.matchMedia('(prefers-color-scheme: dark)');
  const lifecycle = { document, suspended: false };
  const applyTheme = () => {
    const stored = localStorage.getItem('theme') || 'default';
    const theme = stored === 'default' ? (media.matches ? 'moonlight' : 'sunshine') : stored;
    document.documentElement.setAttribute('data-theme', theme);
    document.querySelectorAll('.theme-controller-item').forEach((input) => {
      input.checked = input.value === stored;
    });
    return theme;
  };
  const sync = () => {
    if (lifecycle.suspended) return;
    for (const [header, observer] of headers) {
      if (!header.isConnected) {
        observer.disconnect();
        headers.delete(header);
      }
    }
    document.querySelectorAll('header[data-nav-id]').forEach((header) => {
      if (headers.has(header)) return;
      const nav = document.getElementById(header.getAttribute('data-nav-id'));
      if (!nav) return;
      const observer = new IntersectionObserver((entries) => {
        entries.forEach(({ intersectionRatio }) => {
          if (intersectionRatio <= 0.5) {
            nav.classList.remove('hidden');
            nav.setAttribute('aria-hidden', 'false');
            nav.style.opacity = 1 - intersectionRatio;
          } else {
            nav.classList.add('hidden');
            nav.setAttribute('aria-hidden', 'true');
          }
        });
      }, { threshold: Array.from({ length: 11 }, (_, index) => index / 10) });
      observer.observe(header);
      headers.set(header, observer);
    });
    return applyTheme();
  };
  const onChange = (event) => {
    if (!event.target.matches('.theme-controller-item')) return;
    localStorage.setItem('theme', event.target.value);
    applyTheme();
    event.target.closest('details').removeAttribute('open');
  };
  const onMediaChange = () => {
    if (!localStorage.getItem('theme') || localStorage.getItem('theme') === 'default') applyTheme();
  };
  const mutation = new MutationObserver(sync);
  const suspend = () => {
    lifecycle.suspended = true;
    mutation.disconnect();
    headers.forEach((observer) => observer.disconnect());
    headers.clear();
    document.removeEventListener('change', onChange);
    media.removeEventListener('change', onMediaChange);
  };
  const resume = () => {
    lifecycle.suspended = false;
    document.addEventListener('change', onChange);
    media.addEventListener('change', onMediaChange);
    mutation.observe(document, { childList: true, subtree: true });
    return sync();
  };
  const onPageShow = (event) => {
    if (event.persisted && lifecycle.suspended) resume();
  };
  lifecycle.sync = sync;
  lifecycle.dispose = () => {
    suspend();
    window.removeEventListener('pagehide', suspend);
    window.removeEventListener('pageshow', onPageShow);
  };
  window.addEventListener('pagehide', suspend);
  window.addEventListener('pageshow', onPageShow);
  layoutState.lifecycle = lifecycle;
  return resume();
}

// Restored history can skip component setup; the SSR header is already present.
if (typeof document !== 'undefined' && document.querySelectorAll('header[data-nav-id]').length) {
  mountLayout();
}
