const btn = document.getElementById('svg-convert');
const ipt = document.getElementById('svg-input');
const opt = document.getElementById('svg-output');

function autocropSvg(svgString) {
  return new Promise((resolve, reject) => {
    const container = document.createElement('div');
    container.style.cssText =
      'position:fixed;left:-9999px;top:-9999px;width:1000px;height:1000px;visibility:hidden;';
    document.body.appendChild(container);
    container.innerHTML = svgString;

    const svgEl = container.querySelector('svg');
    if (!svgEl) {
      document.body.removeChild(container);
      reject(new Error('No SVG element found'));
      return;
    }

    requestAnimationFrame(() => {
      try {
        const bbox = svgEl.getBBox();
        const parser = new DOMParser();
        const doc = parser.parseFromString(svgString, 'image/svg+xml');
        const newSvg = doc.querySelector('svg');
        newSvg.setAttribute(
          'viewBox',
          `${bbox.x} ${bbox.y} ${bbox.width} ${bbox.height}`,
        );
        newSvg.removeAttribute('width');
        newSvg.removeAttribute('height');
        resolve(new XMLSerializer().serializeToString(newSvg));
      } catch (e) {
        reject(e);
      } finally {
        document.body.removeChild(container);
      }
    });
  });
}

async function convert() {
  btn.disabled = true;
  try {
    opt.value = await autocropSvg(ipt.value);
  } catch (err) {
    console.error(err);
    opt.value = 'Error: ' + err.message;
  } finally {
    btn.disabled = false;
  }
}

btn.addEventListener('click', convert);
