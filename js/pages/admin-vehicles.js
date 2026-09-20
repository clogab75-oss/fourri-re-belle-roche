/* Véhicules : liste, ajout, fiche détaillée (photos, modification, statut, historique). */
import { h, icon, badge, loading, empty, toast, busy, btn, field, openModal, confirmDialog, debounce } from '../lib/ui.js';
import * as api from '../lib/api.js';
import { adminLayout, pageHead } from '../lib/layout.js';
import { plateEl, colorTag, pathsOf } from '../lib/cards.js';
import { money, dt, rel, norm, plateKey } from '../lib/format.js';
import { photoPicker } from '../lib/photopicker.js';
import { recoveredModal, saleModal, soldModal } from '../lib/actions.js';
import { lightbox } from '../lib/ui.js';

export function addVehicleModal(onCreated) {
  const plate = h('input', { class: 'input', id: 'v-plate', type: 'text', maxlength: '16', autocomplete: 'off', placeholder: 'AB-123-CD', required: true });
  const model = h('input', { class: 'input', id: 'v-model', type: 'text', maxlength: '60', autocomplete: 'off', placeholder: 'Ex. Sultan RS', required: true });
  const color = h('input', { class: 'input', id: 'v-color', type: 'text', maxlength: '40', autocomplete: 'off', placeholder: 'Ex. Noir', required: true });
  const notes = h('textarea', { class: 'input', id: 'v-notes', maxlength: '1000', rows: '3', placeholder: 'Facultatif : dégâts, remarques…' });
  const picker = photoPicker({ label: 'Cliquez ou glissez les photos du véhicule' });
  const status = h('div', { class: 'small muted', role: 'status' });
  const go = btn('Enregistrer le véhicule', { onClick: () => busy(go, async () => {
    if (plate.value.trim().length < 2) throw new Error('Le numéro de plaque est obligatoire.');
    if (!model.value.trim()) throw new Error('Le modèle est obligatoire.');
    if (!color.value.trim()) throw new Error('La couleur est obligatoire.');
    if (picker.count() < 1) throw new Error('Ajoutez au moins une photo.');
    const id = crypto.randomUUID();
    status.textContent = 'Préparation des photos…';
    const blobs = await picker.blobs();
    const paths = await api.uploadPhotos(id, blobs, (i, n) => { status.textContent = `Envoi des photos : ${i}/${n}`; });
    try { await api.createVehicle({ id, plate: plate.value, model: model.value, color: color.value, notes: notes.value, paths }); }
    catch (e) { await api.removeFromStorage(paths); throw e; }
    toast('Véhicule ajouté à la fourrière.', 'ok'); m.close(); picker.reset(); onCreated(id);
  }) });
  const m = openModal({ title: 'Ajouter un véhicule', wide: true, persistent: true,
    body: h('div', { class: 'stack' }, h('div', { class: 'form-grid' }, field('Plaque', plate), field('Modèle', model), field('Couleur', color), h('span', {})), field('Notes internes', notes),
      h('div', { class: 'stack' }, h('span', { class: 'label' }, 'Photos (au moins une)'), picker.el),
      h('p', { class: 'hint' }, "La date, l'heure, l'auteur et le statut sont enregistrés automatiquement par le serveur."), status),
    actions: [btn('Annuler', { kind: 'secondary', onClick: () => m.close() }), go] });
}

export async function list({ query, navigate }) {
  const manager = api.isManager();
  let all = []; let status = query.status || 'tous'; let term = query.q || '';
  const S = [['tous', 'Tous'], ['en_fourriere', 'En fourrière'], ['reclamee', 'Réclamées'], manager && ['attente_vente', 'En attente de vente'], ['a_vendre', 'À vendre'], ['recuperee', 'Récupérées'], ['vendue', 'Vendues'], ['archivee', 'Archivées']].filter(Boolean);
  const search = h('input', { class: 'input', type: 'search', value: term, placeholder: 'Plaque, modèle ou couleur', 'aria-label': 'Rechercher un véhicule' });
  const count = h('span', { class: 'result-count', 'aria-live': 'polite' });
  const body = h('div', {}, loading());
  const chips = h('div', { class: 'chips' }, S.map(([k, l]) => h('button', { class: 'chip', type: 'button', 'aria-pressed': String(k === status), dataset: { k }, onClick: () => { status = k; [...chips.children].forEach((c) => c.setAttribute('aria-pressed', String(c.dataset.k === k))); paint(); } }, l)));
  search.addEventListener('input', debounce(() => { term = search.value; paint(); }, 120));
  function paint() {
    const nq = norm(term).trim(); const pk = plateKey(term);
    const rows = all.filter((v) => (status === 'tous' || v.status === status) && (!nq || (pk && plateKey(v.plate).includes(pk)) || norm(v.model).includes(nq) || norm(v.color).includes(nq)));
    count.textContent = `${rows.length} véhicule${rows.length > 1 ? 's' : ''}`;
    body.replaceChildren(rows.length ? h('section', { class: 'card' }, h('div', { class: 'table-wrap' }, h('table', { class: 'table stack' },
      h('thead', {}, h('tr', {}, ['', 'Plaque', 'Modèle', 'Couleur', 'Statut', 'Arrivée', 'Jours', 'Montant', 'Ajouté par'].map((t) => h('th', {}, t)))),
      h('tbody', {}, rows.map((v) => h('tr', { class: 'click', tabindex: '0', onClick: () => navigate('/admin/vehicules/' + v.id), onKeydown: (e) => { if (e.key === 'Enter') navigate('/admin/vehicules/' + v.id); } },
        h('td', { 'data-label': '' }, v.photos && v.photos[0] ? h('img', { class: 'thumb', src: api.photoUrl(v.photos[0].path), alt: '', loading: 'lazy' }) : h('span', { class: 'thumb' })),
        h('td', { 'data-label': 'Plaque' }, plateEl(v.plate, 'sm')), h('td', { 'data-label': 'Modèle' }, h('strong', {}, v.model)), h('td', { 'data-label': 'Couleur' }, colorTag(v.color)),
        h('td', { 'data-label': 'Statut' }, badge(v.status)), h('td', { 'data-label': 'Arrivée' }, dt(v.created_at)), h('td', { 'data-label': 'Jours', class: 'num' }, String(v.days_in_impound)),
        h('td', { 'data-label': 'Montant', class: 'num' }, money(v.current_amount)), h('td', { 'data-label': 'Ajouté par' }, v.created_by_name || '—'))))))) : empty('Aucun véhicule', term || status !== 'tous' ? 'Aucun véhicule ne correspond à ces critères.' : 'Ajoutez le premier véhicule avec le bouton ci-dessus.'));
  }
  async function load() { all = await api.vehicles(); paint(); }
  const openAdd = () => addVehicleModal((id) => navigate('/admin/vehicules/' + id));
  const el = adminLayout('veh', pageHead('Véhicules', 'Tous les véhicules de la fourrière, avec leur historique.', h('button', { class: 'btn', type: 'button', onClick: openAdd }, icon('plus'), 'Ajouter un véhicule')),
    h('div', { class: 'toolbar' }, h('div', { class: 'searchbox' }, icon('search'), search), count), h('div', { class: 'toolbar' }, chips), body);
  await load();
  if (query.add) setTimeout(openAdd, 50);
  const timer = setInterval(() => load().catch(() => {}), 20000);
  const un = api.watch([{ table: 'vehicles' }], () => load().catch(() => {}), 600);
  return { el, destroy: () => { clearInterval(timer); un(); } };
}

export async function detail({ params, navigate }) {
  const manager = api.isManager(); const id = params.id;
  const root = h('div', { class: 'stack-lg' }, loading());
  const el = adminLayout('veh', root);
  let sel = 0; let editing = false;

  async function load() {
    const v = await api.vehicle(id);
    if (!v) { root.replaceChildren(pageHead('Fiche introuvable', 'Ce véhicule n\'existe pas, a été supprimé ou est réservé aux gérants.', h('a', { class: 'btn secondary', href: '#/admin/vehicules' }, 'Retour à la liste'))); return; }
    const [convs, logs] = await Promise.all([api.vehicleConversations(id).catch(() => []), api.vehicleLogs(id).catch(() => [])]);
    paint(v, convs, logs);
  }
  const reload = () => load().catch((e) => toast(e.message, 'error'));

  function paint(v, convs, logs) {
    const photos = v.photos || []; if (sel >= photos.length) sel = 0;
    const urls = pathsOf(photos).map(api.photoUrl);
    const openClaims = convs.filter((c) => c.type === 'claim' && c.status === 'ouverte');
    const saleConvs = convs.filter((c) => c.type === 'vente' && c.status === 'ouverte');
    const addInput = h('input', { type: 'file', accept: 'image/jpeg,image/png,image/webp', multiple: true, class: 'sr-only', tabindex: '-1', 'aria-label': 'Ajouter des photos', onChange: () => addPhotos([...addInput.files]) });
    async function addPhotos(files) {
      if (!files.length) return;
      const { compress } = await import('../lib/photos.js');
      try { toast('Envoi des photos…'); const blobs = []; for (const f of files) blobs.push(await compress(f)); const paths = await api.uploadPhotos(id, blobs);
        try { await api.addPhotos(id, paths); } catch (e) { await api.removeFromStorage(paths); throw e; }
        toast('Photos ajoutées.', 'ok'); reload(); } catch (e) { toast(e.message, 'error'); }
    }
    const gallery = h('section', { class: 'card', style: { overflow: 'hidden' } },
      photos.length ? h('button', { class: 'gallery-main', type: 'button', 'aria-label': 'Agrandir la photo', onClick: () => lightbox(urls, sel) }, h('img', { src: urls[sel], alt: `Photo ${sel + 1} du véhicule` })) : h('div', { class: 'gallery-main' }, h('div', { class: 'empty' }, 'Aucune photo')),
      h('div', { class: 'gallery-strip' }, photos.map((p, i) => h('div', { class: 'g' }, h('button', { class: 'pick', type: 'button', 'aria-label': `Voir la photo ${i + 1}`, 'aria-current': String(i === sel), onClick: () => { sel = i; paint(v, convs, logs); } }, h('img', { src: urls[i], alt: '' })),
        photos.length > 1 ? h('button', { class: 'x', type: 'button', 'aria-label': `Supprimer la photo ${i + 1}`, onClick: async () => {
          if (!(await confirmDialog({ title: 'Supprimer cette photo ?', confirmLabel: 'Supprimer', danger: true }))) return;
          try { const path = await api.removePhoto(p.id); await api.removeFromStorage([path]); toast('Photo supprimée.', 'ok'); reload(); } catch (e) { toast(e.message, 'error'); } } }, '×') : null)),
        h('button', { class: 'btn secondary sm', type: 'button', style: { alignSelf: 'center', flex: 'none' }, onClick: () => addInput.click() }, icon('plus'), 'Photos'), addInput),
      photos.length > 1 && sel > 0 ? h('div', { style: { padding: '0 12px 12px' } }, btn('Définir comme photo principale', { sm: true, kind: 'secondary', onClick: async () => { try { await api.setCover(photos[sel].id); sel = 0; toast('Photo principale mise à jour.', 'ok'); reload(); } catch (e) { toast(e.message, 'error'); } } })) : null);

    /* Informations / modification */
    let info;
    if (!editing) {
      info = h('section', { class: 'card card-pad stack' },
        h('div', { class: 'row between' }, h('h2', { class: 'card-title' }, 'Informations'), h('button', { class: 'btn secondary sm', type: 'button', onClick: () => { editing = true; paint(v, convs, logs); } }, icon('edit'), 'Modifier')),
        h('dl', { class: 'kv' },
          h('dt', {}, 'Plaque'), h('dd', {}, plateEl(v.plate)), h('dt', {}, 'Modèle'), h('dd', {}, v.model), h('dt', {}, 'Couleur'), h('dd', {}, colorTag(v.color)),
          h('dt', {}, 'Statut'), h('dd', {}, badge(v.status)), h('dt', {}, 'Ajouté le'), h('dd', {}, dt(v.created_at)), h('dt', {}, 'Ajouté par'), h('dd', {}, v.created_by_name || '—'),
          h('dt', {}, 'Jours en fourrière'), h('dd', { class: 'num' }, String(v.days_in_impound)), h('dt', {}, 'Frais de dossier'), h('dd', {}, money(v.handling_fee)), h('dt', {}, 'Garde par jour'), h('dd', {}, money(v.daily_rate)),
          h('dt', {}, v.final_amount != null ? 'Montant figé' : 'Montant total'), h('dd', { class: 'num', style: { fontSize: '1.3rem', fontFamily: 'var(--font-display)' } }, money(v.current_amount)),
          v.recovered_at ? [h('dt', {}, 'Récupéré le'), h('dd', {}, `${dt(v.recovered_at)}${v.recovered_by_name ? ' par ' + v.recovered_by_name : ''}`)] : null,
          v.auto_flagged_at ? [h('dt', {}, 'Passé en vente auto'), h('dd', {}, dt(v.auto_flagged_at))] : null,
          v.sale_status === 'a_vendre' ? [h('dt', {}, 'Prix de vente'), h('dd', {}, money(v.sale_price)), h('dt', {}, 'Annonce'), h('dd', {}, v.sale_description)] : null,
          v.sale_status === 'vendue' ? [h('dt', {}, 'Vendu à'), h('dd', {}, `${v.buyer_name || '—'} · ${money(v.sold_price)} · ${dt(v.sold_at)}`)] : null,
          v.notes ? [h('dt', {}, 'Notes'), h('dd', {}, v.notes)] : null,
          v.updated_by_name ? [h('dt', {}, 'Dernière modification'), h('dd', {}, `${v.updated_by_name} · ${rel(v.updated_at)}`)] : null));
    } else {
      const f = { plate: h('input', { class: 'input', id: 'e-plate', value: v.plate, maxlength: '16' }), model: h('input', { class: 'input', id: 'e-model', value: v.model, maxlength: '60' }), color: h('input', { class: 'input', id: 'e-color', value: v.color, maxlength: '40' }),
        notes: h('textarea', { class: 'input', id: 'e-notes', maxlength: '1000', rows: '3' }, v.notes || ''), fee: h('input', { class: 'input', id: 'e-fee', type: 'number', min: '0', value: String(v.handling_fee) }), rate: h('input', { class: 'input', id: 'e-rate', type: 'number', min: '0', value: String(v.daily_rate) }) };
      const save = btn('Enregistrer', { onClick: () => busy(save, async () => {
        await api.updateVehicle({ id, plate: f.plate.value, model: f.model.value, color: f.color.value, notes: f.notes.value, fee: manager ? Number(f.fee.value) : null, rate: manager ? Number(f.rate.value) : null });
        editing = false; toast('Fiche mise à jour.', 'ok'); reload(); }) });
      info = h('section', { class: 'card card-pad stack' }, h('h2', { class: 'card-title' }, 'Modifier la fiche'),
        h('div', { class: 'form-grid' }, field('Plaque', f.plate), field('Modèle', f.model), field('Couleur', f.color), h('span', {}), manager ? field('Frais de dossier (€)', f.fee) : null, manager ? field('Garde par jour (€)', f.rate) : null, h('div', { class: 'full' }, field('Notes internes', f.notes))),
        h('div', { class: 'row' }, save, btn('Annuler', { kind: 'secondary', onClick: () => { editing = false; paint(v, convs, logs); } })));
    }

    /* Actions */
    const A = [];
    if (['en_fourriere', 'reclamee'].includes(v.status) || (v.status === 'attente_vente' && manager)) A.push(btn('Marquer comme récupéré', { ic: 'check', onClick: () => recoveredModal(v, openClaims, () => { editing = false; reload(); }) }));
    if (manager && v.status === 'attente_vente') A.push(btn('Mettre en vente', { kind: 'amber', ic: 'tag', onClick: () => saleModal(v, reload) }));
    if (manager && v.status === 'a_vendre') A.push(btn("Modifier l'annonce", { kind: 'secondary', ic: 'edit', onClick: () => saleModal(v, reload, true) }), btn('Marquer comme vendu', { ic: 'check', onClick: () => soldModal(v, saleConvs, reload) }),
      btn('Retirer de la vente', { kind: 'secondary', onClick: async () => { if (await confirmDialog({ title: 'Retirer de la vente ?', message: 'Le véhicule repasse en attente de mise en vente et les conversations d\'achat sont fermées.', confirmLabel: 'Retirer' })) { try { await api.withdrawSale(id); toast('Annonce retirée.', 'ok'); reload(); } catch (e) { toast(e.message, 'error'); } } } }));
    if (manager && ['recuperee', 'vendue'].includes(v.status)) A.push(btn('Archiver', { kind: 'secondary', ic: 'archive', onClick: async () => { try { await api.archive(id); toast('Véhicule archivé.', 'ok'); reload(); } catch (e) { toast(e.message, 'error'); } } }));
    if (manager && v.status === 'archivee') A.push(btn('Désarchiver', { kind: 'secondary', ic: 'archive', onClick: async () => { try { await api.unarchive(id); toast('Véhicule désarchivé.', 'ok'); reload(); } catch (e) { toast(e.message, 'error'); } } }));
    A.push(btn('Supprimer', { kind: 'danger', ic: 'trash', onClick: async () => {
      if (!(await confirmDialog({ title: 'Supprimer ce véhicule ?', message: `La fiche ${v.plate}, ses photos et ses conversations seront supprimées définitivement. L'action est enregistrée dans l'historique.`, confirmLabel: 'Supprimer définitivement', danger: true }))) return;
      try { const paths = await api.deleteVehicle(id); await api.removeFromStorage(paths); toast('Véhicule supprimé.', 'ok'); navigate('/admin/vehicules'); } catch (e) { toast(e.message, 'error'); } } }));

    const convTable = convs.length ? h('div', { class: 'table-wrap' }, h('table', { class: 'table stack' }, h('thead', {}, h('tr', {}, ['Client', 'Type', 'Statut', 'Dernier message', ''].map((t) => h('th', {}, t)))),
      h('tbody', {}, convs.map((c) => h('tr', {}, h('td', { 'data-label': 'Client' }, h('strong', {}, c.client_name)), h('td', { 'data-label': 'Type' }, c.type === 'claim' ? 'Récupération' : 'Achat'),
        h('td', { 'data-label': 'Statut' }, h('span', { class: `badge plain ${c.status === 'ouverte' ? 'green' : 'gray'}` }, c.status === 'ouverte' ? 'Ouverte' : 'Fermée')), h('td', { 'data-label': 'Dernier message' }, rel(c.last_message_at)),
        h('td', { class: 'actions', 'data-label': '' }, h('a', { class: 'btn secondary sm', href: '#/messages/' + c.id }, 'Ouvrir')))))))
      : h('p', { class: 'muted' }, 'Aucune demande ni conversation pour ce véhicule.');

    root.replaceChildren(pageHead(`${v.plate} · ${v.model}`, null, h('a', { class: 'btn secondary', href: '#/admin/vehicules' }, icon('left'), 'Liste')),
      h('div', { class: 'detail' }, h('div', { class: 'stack-lg' }, gallery, h('section', { class: 'card card-pad stack' }, h('h2', { class: 'card-title' }, 'Demandes et conversations'), convTable)),
        h('div', { class: 'stack-lg' }, info, h('section', { class: 'card card-pad stack' }, h('h2', { class: 'card-title' }, 'Actions'), h('div', { class: 'row' }, A)),
          h('section', { class: 'card card-pad' }, h('h2', { class: 'card-title', style: { marginBottom: '12px' } }, 'Historique'),
            logs.length ? h('ul', { class: 'timeline' }, logs.map((l) => h('li', {}, h('div', {}, l.summary), h('div', { class: 'when' }, `${dt(l.created_at)} · ${l.actor_name}`)))) : h('p', { class: 'muted' }, 'Aucun événement enregistré.')))));
  }
  await load();
  const timer = setInterval(() => { if (!editing && !document.querySelector('.overlay')) load().catch(() => {}); }, 20000);
  return { el, destroy: () => clearInterval(timer) };
}
