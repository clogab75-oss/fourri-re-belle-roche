/* Sélecteur de photos : clic ou glisser-déposer, aperçus, retrait, compression avant envoi. */
import { h, icon, toast } from './ui.js';
import { compress, MAX_PHOTOS } from './photos.js';

export function photoPicker({ max = MAX_PHOTOS, label = 'Cliquez ou glissez vos photos ici' } = {}) {
  const files = [];
  const input = h('input', { type: 'file', accept: 'image/jpeg,image/png,image/webp', multiple: true, class: 'sr-only', 'aria-label': 'Choisir des photos', tabindex: '-1' });
  const drop = h('div', { class: 'dropzone', tabindex: '0', role: 'button', 'aria-label': 'Ajouter des photos' }, icon('camera'), h('div', { style: { fontWeight: '600', marginTop: '4px' } }, label), h('div', { class: 'small' }, `JPEG, PNG ou WebP · ${max} photos maximum`));
  const previews = h('div', { class: 'previews' });
  function draw() {
    previews.replaceChildren(...files.map((x, i) => h('div', { class: 'p' }, h('img', { src: x.url, alt: '' }),
      h('button', { type: 'button', 'aria-label': `Retirer la photo ${i + 1}`, onClick: () => { URL.revokeObjectURL(x.url); files.splice(i, 1); draw(); } }, icon('x')),
      h('div', { class: 'st' }, h('i', {})))));
  }
  function add(list) {
    for (const f of list) {
      if (!/^image\/(jpeg|png|webp)$/i.test(f.type)) { toast(`« ${f.name} » n'est pas une image JPEG, PNG ou WebP.`, 'warn'); continue; }
      if (files.length >= max) { toast(`Maximum ${max} photos.`, 'warn'); break; }
      files.push({ file: f, url: URL.createObjectURL(f) });
    }
    draw();
  }
  input.addEventListener('change', () => { add([...input.files]); input.value = ''; });
  drop.addEventListener('click', () => input.click());
  drop.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); input.click(); } });
  ['dragenter', 'dragover'].forEach((t) => drop.addEventListener(t, (e) => { e.preventDefault(); drop.classList.add('over'); }));
  ['dragleave', 'drop'].forEach((t) => drop.addEventListener(t, (e) => { e.preventDefault(); drop.classList.remove('over'); }));
  drop.addEventListener('drop', (e) => add([...(e.dataTransfer?.files || [])]));
  return {
    el: h('div', {}, drop, input, previews), input,
    count: () => files.length,
    async blobs(onProgress) { const out = []; for (let i = 0; i < files.length; i++) { out.push(await compress(files[i].file)); if (onProgress) onProgress(i + 1, files.length); } return out; },
    reset() { files.forEach((x) => URL.revokeObjectURL(x.url)); files.length = 0; draw(); },
  };
}
