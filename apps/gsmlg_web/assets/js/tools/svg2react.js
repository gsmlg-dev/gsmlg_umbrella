const path = window.location.pathname;
const btn = document.getElementById('svg-convert');
const ipt = document.getElementById('svg-input');
const opt = document.getElementById('svg-output');

async function convert() {
  btn.disabled = true;
  const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute('content');

  try {
    const resp = await fetch(path, {
      method: 'POST',
      body: JSON.stringify({ code: ipt.value, options: {} }),
      headers: {
        'content-type': 'application/json',
        'x-csrf-token': csrfToken,
      },
    });
    const { data } = await resp.json();
    opt.value = data.output;
  } catch (err) {
    console.error(err);
  } finally {
    btn.disabled = false;
  }
}

btn.addEventListener('click', convert);
