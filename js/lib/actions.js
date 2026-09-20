/* Fenêtres d'action partagées : récupération, mise en vente, vente. Les droits sont vérifiés par la base. */
import { h, openModal, confirmDialog, btn, busy, toast, field } from './ui.js';
import * as api from './api.js';
import { money } from './format.js';
import { photoPicker } from './photopicker.js';

export async function confirmRecovered(v, claimId, clientName) {
  const ok = await confirmDialog({ title: 'Marquer comme récupéré ?',
    message: `Le véhicule ${v.plate} sera marqué comme récupéré${clientName ? ' par ' + clientName : ''}. Le montant (${money(v.current_amount)}) sera figé et toutes les demandes ouvertes seront fermées.`, confirmLabel: 'Oui, récupéré' });
  if (!ok) return false;
  await api.markRecovered(v.id, claimId); toast('Véhicule marqué comme récupéré.', 'ok'); return true;
}

/* Choix de la demande gagnante (fiche véhicule) */
export function recoveredModal(v, openClaims, onDone) {
  const sel = h('select', { class: 'input', id: 'claimSel' }, openClaims.map((c) => h('option', { value: c.id }, c.client_name)), h('option', { value: '' }, 'Sans demande sur le site'));
  const go = btn('Marquer comme récupéré', { onClick: () => busy(go, async () => { await api.markRecovered(v.id, sel.value || null); toast('Véhicule marqué comme récupéré.', 'ok'); m.close(); onDone(); }) });
  const m = openModal({ title: `Récupération de ${v.plate}`, body: h('div', { class: 'stack' },
    h('p', {}, `Montant à régler : ${money(v.current_amount)}. Il sera figé.`), field('Récupéré par', sel, 'Les autres demandes ouvertes seront fermées.')), actions: [btn('Annuler', { kind: 'secondary', onClick: () => m.close() }), go] });
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

/* Clôture de la vente */
export function soldModal(v, saleConvs, onDone) {
  const buyer = h('select', { class: 'input', id: 'buyer' }, saleConvs.map((c) => h('option', { value: c.id }, c.client_name)), h('option', { value: '' }, 'Autre acheteur (saisir le nom)'));
  const name = h('input', { class: 'input', id: 'bname', type: 'text', maxlength: '80', placeholder: 'Nom RP de l\'acheteur' });
  const nameF = field('Nom de l\'acheteur', name);
  const price = h('input', { class: 'input', id: 'sprice', type: 'number', min: '1', step: '1', value: String(Math.round(v.sale_price || 0)) });
  const sync = () => { nameF.hidden = buyer.value !== ''; }; buyer.addEventListener('change', sync); sync();
  const go = btn('Confirmer la vente', { onClick: () => busy(go, async () => {
    await api.markSold(v.id, buyer.value || null, Number(price.value) || null, buyer.value ? null : name.value); toast('Vente enregistrée.', 'ok'); m.close(); onDone();
  }) });
  const m = openModal({ title: `Vendre · ${v.model}`, body: h('div', { class: 'stack' }, field('Acheteur', buyer, 'Les personnes ayant cliqué sur « Je suis intéressé » sont listées.'), nameF, field('Prix final (€)', price)),
    actions: [btn('Annuler', { kind: 'secondary', onClick: () => m.close() }), go] });
}
