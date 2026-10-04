/* Fenêtres d'action partagées : récupération, mise en vente, vente. Les droits et les montants sont vérifiés par la base. */
import { h, openModal, confirmDialog, btn, busy, toast, field } from './ui.js';
import * as api from './api.js';
import { money } from './format.js';
import { photoPicker } from './photopicker.js';

async function optionCheckboxes(preselected = []) {
  const opts = await api.activeSaleOptions().catch(() => []);
  const checks = {};
  const rows = opts.map((o) => { const cb = h('input', { type: 'checkbox', id: 'opt-' + o.id, checked: preselected.includes(o.id) }); checks[o.id] = cb;
    return h('label', { class: 'check' }, cb, h('span', {}, o.label, h('span', { class: 'muted' }, ' — ' + money(o.price)))); });
  return { el: opts.length ? h('div', { class: 'stack', style: { margin: '4px 0' } }, rows) : h('p', { class: 'small muted' }, 'Aucune option de vente configurée.'), opts, checks };
}

const reduced = (amount, pct) => (pct ? Math.round(Number(amount) * (100 - pct) / 100) : Number(amount));

export async function confirmRecovered(v, claimId, clientName, pct) {
  const total = Number(v.current_amount); const due = reduced(total, pct);
  const ok = await confirmDialog({ title: 'Marquer comme récupéré ?',
    message: `Le véhicule ${v.plate} sera marqué comme récupéré${clientName ? ' par ' + clientName : ''}. Montant à régler : ${money(due)}${pct ? ` (${money(total)} − ${pct} % avec le code promo)` : ''}. Le montant sera figé et toutes les demandes ouvertes seront fermées.`, confirmLabel: 'Oui, récupéré' });
  if (!ok) return false;
  await api.markRecovered(v.id, claimId); toast('Véhicule marqué comme récupéré.', 'ok'); return true;
}

/* Choix de la demande gagnante (fiche véhicule). `openClaims` = conversations de récupération ouvertes. */
export function recoveredModal(v, openClaims, onDone) {
  const sel = h('select', { class: 'input', id: 'claimSel' },
    openClaims.map((c) => h('option', { value: c.claim_id }, c.client_name + (c.discount_percent ? ` (code −${c.discount_percent} %)` : ''))), h('option', { value: '' }, 'Sans demande sur le site'));
  const info = h('p', {});
  const paint = () => { const c = openClaims.find((x) => x.claim_id === sel.value); const pct = c ? c.discount_percent : 0;
    info.textContent = `Montant à régler : ${money(reduced(v.current_amount, pct))}${pct ? ` (${money(v.current_amount)} − ${pct} % avec le code ${c.discount_code})` : ''}. Il sera figé.`; };
  sel.addEventListener('change', paint); paint();
  const go = btn('Marquer comme récupéré', { onClick: () => busy(go, async () => { await api.markRecovered(v.id, sel.value || null); toast('Véhicule marqué comme récupéré.', 'ok'); m.close(); onDone(); }) });
  const m = openModal({ title: `Récupération de ${v.plate}`, body: h('div', { class: 'stack' }, info, field('Récupéré par', sel, 'Les autres demandes ouvertes seront fermées.')),
    actions: [btn('Annuler', { kind: 'secondary', onClick: () => m.close() }), go] });
}

/* Mise en vente (nouvelle annonce) ou modification d'annonce */
export function saleModal(v, onDone, edit = false) {
  const price = h('input', { class: 'input', id: 'price', type: 'number', min: '1', step: '1', inputmode: 'numeric', required: true, value: edit ? String(Math.round(v.sale_price)) : '' });
  const desc = h('textarea', { class: 'input', id: 'desc', maxlength: '2000', rows: '5', placeholder: 'État, options, particularités…' }, edit ? v.sale_description || '' : '');
  const promo = h('input', { class: 'input', id: 'promo', type: 'number', min: '1', max: '99', step: '1', value: edit && v.sale_promo_percent ? String(v.sale_promo_percent) : '', placeholder: 'Aucune' });
  const preview = h('p', { class: 'small' });
  const paintPreview = () => { const p = Number(price.value); const pc = Number(promo.value);
    preview.replaceChildren(pc >= 1 && pc <= 99 && p > 0 ? [h('s', { class: 'strike' }, money(p)), ' → ', h('strong', {}, money(Math.round(p * (100 - pc) / 100))), ' affiché sur la page publique, sans code.'] : ''); };
  price.addEventListener('input', paintPreview); promo.addEventListener('input', paintPreview); paintPreview();
  const picker = edit ? null : photoPicker({ label: 'Ajouter des photos pour l\'annonce (facultatif)' });
  const status = h('div', { class: 'small muted' });
  const go = btn(edit ? 'Enregistrer' : 'Mettre en vente', { onClick: () => busy(go, async () => {
    const p = Number(price.value); const d = desc.value.trim(); const pc = promo.value.trim() ? Number(promo.value) : null;
    if (!(p > 0)) throw new Error('Indiquez un prix de vente valide.');
    if (d.length < 3) throw new Error('Ajoutez une description.');
    if (pc !== null && (pc < 1 || pc > 99)) throw new Error('La promotion affichée doit être comprise entre 1 et 99 %.');
    if (edit) await api.updateSale(v.id, p, d, pc);
    else {
      let paths = [];
      if (picker.count()) { status.textContent = 'Envoi des photos…'; paths = await api.uploadPhotos(v.id, await picker.blobs(), (i, n) => { status.textContent = `Photos : ${i}/${n}`; }); }
      try { await api.listForSale(v.id, p, d, paths, pc); } catch (e) { await api.removeFromStorage(paths); throw e; }
    }
    toast(edit ? 'Annonce mise à jour.' : 'Véhicule mis en vente.', 'ok'); m.close(); onDone();
  }) });
  const m = openModal({ title: edit ? `Modifier l'annonce · ${v.model}` : `Mettre en vente · ${v.model}`, wide: true,
    body: h('div', { class: 'stack' },
      !edit ? h('p', { class: 'muted' }, `Ancien montant de garde : ${money(v.final_amount ?? v.current_amount)}. L'annonce sera visible publiquement.`) : null,
      field('Prix de vente (€)', price), field('Description', desc),
      field('Promotion affichée (%, facultatif)', promo, 'Barre le prix sur la page publique, sans code à saisir.'), preview,
      picker ? picker.el : null, status),
    actions: [btn('Annuler', { kind: 'secondary', onClick: () => m.close() }), go] });
}

/* Clôture de la vente : le prix proposé tient compte de la promotion affichée, du code promo de
   l'acheteur choisi et des options cochées. Un gérant garde la main pour ajuster le montant final. */
export async function soldModal(v, saleConvs, onDone) {
  const base = v.sale_promo_percent ? Math.round(Number(v.sale_price) * (100 - v.sale_promo_percent) / 100) : Number(v.sale_price);
  const buyer = h('select', { class: 'input', id: 'buyer' }, saleConvs.map((c) => h('option', { value: c.id }, c.client_name + (c.discount_percent ? ` (code −${c.discount_percent} %)` : ''))), h('option', { value: '' }, 'Autre acheteur (saisir le nom)'));
  const name = h('input', { class: 'input', id: 'bname', type: 'text', maxlength: '80', placeholder: 'Nom RP de l\'acheteur' });
  const nameF = field('Nom de l\'acheteur', name);
  const price = h('input', { class: 'input', id: 'sprice', type: 'number', min: '0', step: '1' });
  const hint = h('span', { class: 'hint' });
  const { el: optionsEl, opts, checks } = await optionCheckboxes();
  let touched = false; price.addEventListener('input', () => { touched = true; });
  const suggested = () => { const c = saleConvs.find((x) => x.id === buyer.value); const pct = c ? c.discount_percent : 0;
    const optsTotal = opts.reduce((s, o) => s + (checks[o.id].checked ? Number(o.price) : 0), 0);
    return reduced(base, pct) + optsTotal; };
  const sync = () => {
    nameF.hidden = buyer.value !== '';
    const c = saleConvs.find((x) => x.id === buyer.value); const pct = c ? c.discount_percent : 0;
    if (!touched) price.value = String(suggested());
    const bits = [`Prix de l'annonce : ${money(v.sale_price)}`];
    if (v.sale_promo_percent) bits.push(`promo affichée −${v.sale_promo_percent} % (${money(base)})`);
    if (pct) bits.push(`code ${c.discount_code} −${pct} %`);
    hint.textContent = bits.join(' · ') + '. Vous pouvez modifier le montant final.';
  };
  buyer.addEventListener('change', () => { touched = false; sync(); });
  opts.forEach((o) => checks[o.id].addEventListener('change', () => { if (!touched) price.value = String(suggested()); }));
  sync();
  const go = btn('Confirmer la vente', { onClick: () => busy(go, async () => {
    const ids = opts.filter((o) => checks[o.id].checked).map((o) => o.id);
    await api.markSold(v.id, buyer.value || null, Number(price.value), buyer.value ? null : name.value, ids); toast('Vente enregistrée.', 'ok'); m.close(); onDone();
  }) });
  const m = openModal({ title: `Vendre · ${v.model}`, body: h('div', { class: 'stack' }, field('Acheteur', buyer, 'Les personnes ayant cliqué sur « Je suis intéressé » sont listées.'), nameF,
    h('div', { class: 'field' }, h('span', { class: 'label' }, 'Options'), optionsEl), field('Prix final (€)', price), hint),
    actions: [btn('Annuler', { kind: 'secondary', onClick: () => m.close() }), go] });
}

/* Remettre en vente un véhicule déjà vendu (l'acheteur se rétracte, par exemple).
   Une nouvelle annonce est créée ; la vente précédente reste inchangée dans l'historique. */
export function relistModal(v, onDone) {
  const price = h('input', { class: 'input', id: 'rl-price', type: 'number', min: '1', step: '1', required: true, value: String(Math.round(v.sale_price || v.sold_price || 0)) });
  const desc = h('textarea', { class: 'input', id: 'rl-desc', maxlength: '2000', rows: '5' }, v.sale_description || '');
  const promo = h('input', { class: 'input', id: 'rl-promo', type: 'number', min: '1', max: '99', step: '1', placeholder: 'Aucune' });
  const preview = h('p', { class: 'small' });
  const paintPreview = () => { const p = Number(price.value); const pc = Number(promo.value);
    preview.replaceChildren(pc >= 1 && pc <= 99 && p > 0 ? [h('s', { class: 'strike' }, money(p)), ' → ', h('strong', {}, money(Math.round(p * (100 - pc) / 100)))] : ''); };
  price.addEventListener('input', paintPreview); promo.addEventListener('input', paintPreview); paintPreview();
  const go = btn('Remettre en vente', { kind: 'amber', onClick: () => busy(go, async () => {
    const p = Number(price.value); const d = desc.value.trim(); const pc = promo.value.trim() ? Number(promo.value) : null;
    if (!(p > 0)) throw new Error('Indiquez un prix de vente valide.');
    if (d.length < 3) throw new Error('Ajoutez une description.');
    await api.relistAfterSale(v.id, p, d, pc); toast('Véhicule remis en vente.', 'ok'); m.close(); onDone();
  }) });
  const m = openModal({ title: `Remettre en vente · ${v.model}`, wide: true,
    body: h('div', { class: 'stack' }, h('p', { class: 'muted' }, 'La vente précédente reste conservée dans l\'historique ; une nouvelle annonce est créée.'),
      field('Prix de vente (€)', price), field('Description', desc), field('Promotion affichée (%, facultatif)', promo), preview),
    actions: [btn('Annuler', { kind: 'secondary', onClick: () => m.close() }), go] });
}
