/* Fenêtres d'action partagées : récupération, mise en vente, vente. Les droits et les montants sont vérifiés par la base. */
import { h, openModal, confirmDialog, btn, busy, toast, field } from './ui.js';
import * as api from './api.js';
import { money } from './format.js';
import { photoPicker } from './photopicker.js';

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
  const picker = edit ? null : photoPicker({ label: 'Ajouter des photos pour l\'annonce (facultatif)' });
  const status = h('div', { class: 'small muted' });
  const go = btn(edit ? 'Enregistrer' : 'Mettre en vente', { onClick: () => busy(go, async () => {
    const p = Number(price.value); const d = desc.value.trim();
    if (!(p > 0)) throw new Error('Indiquez un prix de vente valide.');
    if (d.length < 3) throw new Error('Ajoutez une description.');
    if (edit) await api.updateSale(v.id, p, d);
    else {
      let paths = [];
      if (picker.count()) { status.textContent = 'Envoi des photos…'; paths = await api.uploadPhotos(v.id, await picker.blobs(), (i, n) => { status.textContent = `Photos : ${i}/${n}`; }); }
      try { await api.listForSale(v.id, p, d, paths); } catch (e) { await api.removeFromStorage(paths); throw e; }
    }
    toast(edit ? 'Annonce mise à jour.' : 'Véhicule mis en vente.', 'ok'); m.close(); onDone();
  }) });
  const m = openModal({ title: edit ? `Modifier l'annonce · ${v.model}` : `Mettre en vente · ${v.model}`, wide: true,
    body: h('div', { class: 'stack' },
      !edit ? h('p', { class: 'muted' }, `Ancien montant de garde : ${money(v.final_amount ?? v.current_amount)}. L'annonce sera visible publiquement.`) : null,
      field('Prix de vente (€)', price), field('Description', desc), picker ? picker.el : null, status),
    actions: [btn('Annuler', { kind: 'secondary', onClick: () => m.close() }), go] });
}

/* Clôture de la vente : le prix proposé tient compte du code promo de l'acheteur choisi */
export function soldModal(v, saleConvs, onDone) {
  const buyer = h('select', { class: 'input', id: 'buyer' }, saleConvs.map((c) => h('option', { value: c.id }, c.client_name + (c.discount_percent ? ` (code −${c.discount_percent} %)` : ''))), h('option', { value: '' }, 'Autre acheteur (saisir le nom)'));
  const name = h('input', { class: 'input', id: 'bname', type: 'text', maxlength: '80', placeholder: 'Nom RP de l\'acheteur' });
  const nameF = field('Nom de l\'acheteur', name);
  const price = h('input', { class: 'input', id: 'sprice', type: 'number', min: '0', step: '1' });
  const hint = h('span', { class: 'hint' });
  const optionsBox = h('div', { class: 'stack' }, h('span', { class: 'label' }, 'Options facultatives'), h('span', { class: 'muted small' }, 'Chargement…'));
  let saleOptions = [];
  const selectedOptionIds = () => [...optionsBox.querySelectorAll('input:checked')].map((i) => i.value);
  let touched = false; price.addEventListener('input', () => { touched = true; });
  const sync = () => {
    nameF.hidden = buyer.value !== '';
    const c = saleConvs.find((x) => x.id === buyer.value); const pct = c ? c.discount_percent : 0;
    if (!touched) price.value = String(reduced(v.sale_price, pct));
    const extra = saleOptions.filter((o) => selectedOptionIds().includes(o.id)).reduce((sum, o) => sum + Number(o.price), 0);
    hint.textContent = `${pct ? `Prix voiture : ${money(v.sale_price)} · code ${c.discount_code} (−${pct} %) : ${money(reduced(v.sale_price, pct))}. ` : `Prix voiture : ${money(v.sale_price)}. `}Options : +${money(extra)}. Le montant final inclut ces options.`;
  };
  buyer.addEventListener('change', () => { touched = false; sync(); }); sync();
  const go = btn('Confirmer la vente', { onClick: () => busy(go, async () => {
    await api.markSold(v.id, buyer.value || null, Number(price.value), buyer.value ? null : name.value, selectedOptionIds()); toast('Vente enregistrée.', 'ok'); m.close(); onDone();
  }) });
  const m = openModal({ title: `Vendre · ${v.model}`, body: h('div', { class: 'stack' }, field('Acheteur', buyer, 'Les personnes ayant cliqué sur « Je suis intéressé » sont listées.'), nameF, field('Prix voiture (€)', price), optionsBox, hint),
    actions: [btn('Annuler', { kind: 'secondary', onClick: () => m.close() }), go] });
  api.saleOptions().then((rows) => {
    saleOptions = rows.filter((o) => o.active);
    optionsBox.replaceChildren(h('span', { class: 'label' }, 'Options facultatives'), ...(saleOptions.length
      ? saleOptions.map((o) => h('label', { class: 'check' }, h('input', { type: 'checkbox', value: o.id, onChange: sync }), h('span', {}, h('strong', {}, o.label), h('div', { class: 'hint' }, money(o.price)))))
      : [h('span', { class: 'muted small' }, 'Aucune option configurée.')]));
    sync();
  }).catch((e) => optionsBox.replaceChildren(h('p', { class: 'form-error' }, e.message)));
}
