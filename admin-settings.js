/* Réglages des gérants : tarifs, options de vente, historique des actions, connexion Discord. */
import { h, icon, loading, empty, toast, busy, btn, field, confirmDialog } from '../lib/ui.js';
import * as api from '../lib/api.js';
import { adminLayout, pageHead } from '../lib/layout.js';
import { money, dt, rel } from '../lib/format.js';

/* ---------------- Options de vente (extras choisis à l'achat, ex. « Réservoir plein ») ---------------- */
async function optionsSection() {
  const box = h('div', {}, loading());
  const label = h('input', { class: 'input', id: 'opt-label', maxlength: '60', autocomplete: 'off', placeholder: 'Ex. Réservoir plein' });
  const price = h('input', { class: 'input', id: 'opt-price', type: 'number', min: '0', step: '1', placeholder: '0' });
  const add = h('button', { class: 'btn', type: 'submit' }, icon('plus'), 'Ajouter l\'option');
  async function load() {
    const rows = await api.saleOptions();
    box.replaceChildren(rows.length ? h('div', { class: 'table-wrap' }, h('table', { class: 'table stackable' },
      h('thead', {}, h('tr', {}, ['Option', 'Prix', 'Utilisée', 'État', ''].map((t) => h('th', {}, t)))),
      h('tbody', {}, rows.map((o) => h('tr', {}, h('td', { 'data-label': 'Option' }, h('strong', {}, o.label)), h('td', { 'data-label': 'Prix', class: 'num' }, money(o.price)),
        h('td', { 'data-label': 'Utilisée', class: 'num' }, String(o.uses)), h('td', { 'data-label': 'État' }, h('span', { class: `badge ${o.active ? 'green' : 'gray'}` }, o.active ? 'Active' : 'Désactivée')),
        h('td', { class: 'actions', 'data-label': '' }, h('div', { class: 'row', style: { justifyContent: 'flex-end', gap: '6px' } },
          btn(o.active ? 'Désactiver' : 'Activer', { sm: true, kind: 'secondary', onClick: async () => { try { await api.toggleSaleOption(o.id, !o.active); toast(o.active ? 'Option désactivée.' : 'Option activée.', 'ok'); await load(); } catch (e) { toast(e.message, 'error'); } } }),
          btn('', { sm: true, kind: 'ghost', ic: 'trash', disabled: o.uses > 0, title: o.uses ? 'Déjà utilisée : désactivez-la' : 'Supprimer', onClick: async () => {
            if (await confirmDialog({ title: `Supprimer « ${o.label} » ?`, confirmLabel: 'Supprimer', danger: true })) { try { await api.deleteSaleOption(o.id); toast('Option supprimée.', 'ok'); await load(); } catch (e) { toast(e.message, 'error'); } } } }))))))))
      : empty('Aucune option pour le moment', 'Ajoutez-en une avec le formulaire ci-dessus.'));
  }
  await load();
  return h('section', { class: 'card card-pad stack' }, h('h2', { class: 'card-title' }, 'Options de vente'),
    h('p', { class: 'muted' }, 'Des extras à prix fixe que l\'acheteur peut cocher à l\'achat d\'un véhicule (« Réservoir plein », « Moteur réparé »…), en plus du prix de vente.'),
    h('form', { class: 'row', onSubmit: (e) => { e.preventDefault(); busy(add, async () => {
        await api.createSaleOption(label.value, Number(price.value) || 0); label.value = ''; price.value = ''; toast('Option ajoutée.', 'ok'); await load();
      }); } },
      h('div', { class: 'grow' }, field('Nom de l\'option', label)), h('div', { style: { width: '140px' } }, field('Prix (€)', price)), h('div', { style: { alignSelf: 'flex-end' } }, add)),
    box);
}

/* ---------------- Tarifs ---------------- */
export async function pricing() {
  const p = await api.pricing();
  const fee = h('input', { class: 'input', id: 'fee', type: 'number', min: '0', step: '1', value: String(Math.round(p.handling_fee)) });
  const rate = h('input', { class: 'input', id: 'rate', type: 'number', min: '0', step: '1', value: String(Math.round(p.daily_rate)) });
  const days = h('input', { class: 'input', id: 'days', type: 'number', min: '1', max: '365', step: '1', value: String(p.auto_sale_days) });
  const mins = h('input', { class: 'input', id: 'mins', type: 'number', min: '0', max: '1440', step: '1', value: String(p.employee_delete_minutes) });
  const apply = h('input', { id: 'apply', type: 'checkbox' });
  const prev = h('div', { class: 'ex', style: { display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(110px,1fr))', gap: '10px' } });
  const paintPrev = () => prev.replaceChildren(...[1, 2, 3, 5, days.value > 7 ? Number(days.value) : 7].map((d) => h('div', { class: 'stat navy' }, h('div', { class: 'n num', style: { fontSize: '1.7rem' } }, money(Number(fee.value) + Number(rate.value) * d)), h('div', { class: 'l' }, d === 1 ? '1 jour' : `${d} jours`))));
  [fee, rate, days].forEach((i) => i.addEventListener('input', paintPrev)); paintPrev();
  const save = h('button', { class: 'btn', type: 'submit' }, 'Enregistrer les tarifs');
  const form = h('form', { class: 'card card-pad stack', onSubmit: (e) => { e.preventDefault();
    busy(save, async () => { await api.updatePricing({ fee: Number(fee.value), rate: Number(rate.value), days: Number(days.value), minutes: Number(mins.value), apply: apply.checked }); apply.checked = false; toast('Tarifs enregistrés.', 'ok'); }); } },
    h('div', { class: 'form-grid' }, field('Frais de dossier (€)', fee, 'Facturés une seule fois.'), field('Prix de garde par jour (€)', rate, 'Le premier jour est compté en entier.'),
      field('Mise en vente automatique après (jours)', days, 'Sans réclamation active, le véhicule passe en attente de mise en vente.'), field('Suppression par un employé (minutes)', mins, "Un employé peut supprimer sa propre fiche pendant ce délai, si aucun client n'a réagi.")),
    h('label', { class: 'check' }, apply, h('span', {}, h('strong', {}, 'Appliquer aussi aux véhicules déjà en fourrière'), h('div', { class: 'hint' }, 'Sinon, seuls les nouveaux véhicules utiliseront ces tarifs.'))),
    h('div', {}, save));
  return adminLayout('pricing', pageHead('Tarifs', 'Ces valeurs servent à calculer automatiquement le montant de chaque véhicule.'), h('div', { class: 'stack-lg' }, form,
    h('section', { class: 'card card-pad stack' }, h('h2', { class: 'card-title' }, 'Aperçu du montant total'), prev),
    p.updated_by_name ? h('p', { class: 'muted small' }, `Dernière modification par ${p.updated_by_name}, ${dt(p.updated_at)}.`) : null,
    await optionsSection()));
}

/* ---------------- Historique ---------------- */
const GROUPS = [['', 'Toutes les actions'], ['vehicle.', 'Véhicules'], ['claim.,interest.,conversation.', 'Demandes et conversations'], ['sale.', 'Ventes'], ['staff.', 'Personnel'], ['pricing.', 'Tarifs'], ['discord.', 'Discord']];
export async function history() {
  let rows = []; let group = ''; let term = ''; let more = true; const PAGE = 100;
  const tbody = h('tbody', {}); const moreBtn = h('button', { class: 'btn secondary', type: 'button' }, 'Charger plus');
  const sel = h('select', { class: 'input', style: { width: 'auto' }, 'aria-label': 'Filtrer', onChange: () => { group = sel.value; paint(); } }, GROUPS.map(([v, l]) => h('option', { value: v }, l)));
  const q = h('input', { class: 'input', type: 'search', placeholder: 'Rechercher dans l\'historique', 'aria-label': 'Rechercher' }); q.addEventListener('input', () => { term = q.value.toLowerCase(); paint(); });
  const box = h('div', {});
  function paint() {
    const pre = group ? group.split(',') : [];
    const list = rows.filter((l) => (!pre.length || pre.some((x) => l.action.startsWith(x))) && (!term || (l.summary + l.actor_name).toLowerCase().includes(term)));
    box.replaceChildren(list.length ? h('section', { class: 'card' }, h('div', { class: 'table-wrap' }, h('table', { class: 'table stackable' }, h('thead', {}, h('tr', {}, ['Date', 'Qui', 'Action', ''].map((t) => h('th', {}, t)))),
      h('tbody', {}, list.map((l) => h('tr', {}, h('td', { 'data-label': 'Date', class: 'nowrap' }, dt(l.created_at)), h('td', { 'data-label': 'Qui' }, l.actor_name), h('td', { 'data-label': 'Action' }, l.summary),
        h('td', { class: 'actions', 'data-label': '' }, l.vehicle_id && !l.action.endsWith('delete') ? h('a', { class: 'btn ghost sm', href: '#/admin/vehicules/' + l.vehicle_id }, 'Fiche') : null))))))) : empty('Aucune action', 'Rien ne correspond à ce filtre.'),
      more ? h('div', { class: 'center', style: { marginTop: '14px' } }, moreBtn) : null);
  }
  async function loadMore() { const r = await api.logs(PAGE, rows.length); rows = rows.concat(r); more = r.length === PAGE; paint(); }
  moreBtn.addEventListener('click', () => busy(moreBtn, loadMore));
  await loadMore();
  return adminLayout('history', pageHead('Historique', 'Toutes les actions importantes : qui a fait quoi, et quand.'), h('div', { class: 'toolbar' }, h('div', { class: 'searchbox' }, icon('search'), q), sel), box);
}

/* ---------------- Discord ---------------- */
const SLOTS = [
  ['impound', 'Véhicules en fourrière', 'Un message par véhicule en fourrière, avec sa photo. Il est SUPPRIMÉ AUTOMATIQUEMENT dès que le véhicule est réclamé, récupéré ou supprimé.'],
  ['sale', 'Véhicules à vendre', 'Un message par annonce. Il est SUPPRIMÉ AUTOMATIQUEMENT dès que le véhicule est vendu ou retiré de la vente.'],
  ['staff', 'Notifications du personnel', 'Nouveaux messages dans les conversations, nouvelles demandes, véhicules à mettre en vente, actions importantes… Réservé à l\'équipe : les clients ne sont jamais notifiés par Discord.'],
];
const EVENTS = [['messages_client', 'Messages des clients'], ['messages_staff', 'Réponses du personnel'], ['claims', 'Nouvelles demandes et intérêts pour un achat'], ['vehicles', 'Véhicules (ajout, modification, récupération, mise en vente auto…)'],
  ['sales', 'Ventes (mise en vente, vente, retrait)'], ['staff', 'Personnel (recrutement, licenciement, rôles)'], ['other', 'Autres (tarifs, conversations fermées…)']];
const JOB = { post: 'Publication', delete: 'Suppression', notify: 'Notification', test: 'Test' };
const JOB_STATE = { queued: 'En attente', sent: 'Envoyé', done: 'Terminé', failed: 'Échec', cancelled: 'Annulé' };

export async function discord() {
  const root = h('div', { class: 'stack-lg' }, loading());
  const el = adminLayout('discord', pageHead('Discord', 'Reliez le site à vos salons Discord grâce aux webhooks.'), root);
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  let s = await api.discordSettings();
  const siteUrl = location.origin + location.pathname.replace(/index\.html$/, ''); const storageUrl = `${api.cfg.SUPABASE_URL}/storage/v1/object/public/${api.cfg.PHOTO_BUCKET}/`;
  if (s.site_url !== siteUrl || s.storage_url !== storageUrl) { try { await api.discordSave({ site_url: siteUrl, storage_url: storageUrl, site_name: api.cfg.SITE_NAME }); s = await api.discordSettings(); } catch { /* non bloquant */ } }
  async function reload() { s = await api.discordSettings(); paint(); }

  function slotCard([key, title, text]) {
    const st = s.slots[key]; const url = h('input', { class: 'input secret', id: `url-${key}`, type: 'text', autocomplete: 'off', spellcheck: 'false', placeholder: st.configured ? `Webhook enregistré (…${st.hint}) — collez une nouvelle adresse pour le remplacer` : 'https://discord.com/api/webhooks/…' });
    const on = h('input', { type: 'checkbox', checked: st.enabled }); const save = btn('Enregistrer', { type: 'button' });
    save.addEventListener('click', () => busy(save, async () => { const patch = { [`${key}_enabled`]: on.checked }; if (url.value.trim()) patch[`${key}_url`] = url.value.trim();
      const extra = key === 'staff' ? { staff_events: Object.fromEntries(EVENTS.map(([k]) => [k, document.getElementById('ev-' + k).checked])), mention: document.getElementById('mention').value.trim() } : {};
      await api.discordSave({ ...patch, ...extra }); url.value = ''; toast('Réglages enregistrés.', 'ok'); await reload(); }));
    const test = btn('Envoyer un test', { kind: 'secondary', ic: 'send', onClick: () => busy(test, async () => { await api.discordTest(key); toast('Test envoyé, vérification…'); await sleep(2500); await api.discordRun(); await reload(); toast('Regardez votre salon Discord.', 'ok'); }) });
    const del = st.configured ? btn('Retirer l\'adresse', { kind: 'ghost', onClick: async () => { if (await confirmDialog({ title: 'Retirer ce webhook ?', message: 'Plus aucun message ne sera envoyé. Les messages déjà publiés resteront dans Discord.', confirmLabel: 'Retirer', danger: true })) { try { await api.discordSave({ [`${key}_url`]: '' }); toast('Webhook retiré.', 'ok'); await reload(); } catch (e) { toast(e.message, 'error'); } } } }) : null;
    return h('section', { class: 'card wh-card', dataset: { slot: key } },
      h('div', { class: 'row between' }, h('h2', { class: 'card-title' }, title), h('span', { class: `badge ${st.configured && st.enabled ? 'green' : 'gray'}` }, !st.configured ? 'Non configuré' : st.enabled ? 'Actif' : 'En pause')),
      h('p', { class: 'muted' }, text), field('Adresse du webhook', url, 'Elle reste stockée côté serveur et n\'est jamais réaffichée en entier.'),
      h('label', { class: 'switch' }, on, h('span', { class: 'track' }), h('span', {}, 'Envoi activé')),
      key === 'staff' ? h('div', { class: 'stack' }, h('span', { class: 'label' }, 'Événements envoyés'), EVENTS.map(([k, l]) => h('label', { class: 'check' }, h('input', { type: 'checkbox', id: 'ev-' + k, checked: s.staff_events[k] !== false }), h('span', {}, l))),
        field('Mentionner un rôle (facultatif)', h('input', { class: 'input', id: 'mention', type: 'text', value: s.mention || '', placeholder: '<@&123456789012345678>', autocomplete: 'off' }), 'Utilisé pour les messages de clients, les nouvelles demandes et les véhicules à mettre en vente. Dans Discord : clic droit sur le rôle → « Copier l\'identifiant du rôle » (mode développeur), puis écrivez <@&identifiant>.')) : null,
      h('div', { class: 'row' }, save, st.configured ? test : null, del));
  }
  function paint() {
    const stt = s.status;
    root.replaceChildren(
      !stt.pg_net ? h('div', { class: 'banner' }, icon('alert'), h('div', {}, h('strong', {}, "L'extension pg_net n'est pas activée. "), 'Dans Supabase : Database → Extensions → activez « pg_net ». Sans elle, aucun message ne peut partir vers Discord.')) : null,
      SLOTS.map(slotCard),
      h('section', { class: 'card card-pad stack' }, h('h2', { class: 'card-title' }, 'Synchronisation'),
        h('div', { class: 'stat-grid' }, [['Messages « fourrière » en ligne', stt.impound_posted, 'blue'], ['Messages « à vendre » en ligne', stt.sale_posted, 'green'], ['Envois en attente', stt.pending, 'amber'], ['Échecs (24 h)', stt.failed, stt.failed ? 'red' : 'navy']].map(([l, n, t]) => h('div', { class: `stat ${t}` }, h('div', { class: 'n num' }, n), h('div', { class: 'l' }, l)))),
        h('div', { class: 'row' },
          (() => { const b = btn('Synchroniser maintenant', { ic: 'refresh' }); b.addEventListener('click', () => busy(b, async () => { await api.discordResync(); await sleep(1500); await api.discordRun(); await reload(); toast('Synchronisation lancée.', 'ok'); })); return b; })(),
          (() => { const b = btn('Actualiser', { kind: 'secondary' }); b.addEventListener('click', () => busy(b, async () => { await api.discordRun(); await reload(); })); return b; })(),
          (() => { const b = btn('Supprimer tous les messages du catalogue', { kind: 'danger', ic: 'trash' }); b.addEventListener('click', async () => { if (await confirmDialog({ title: 'Supprimer les messages du catalogue ?', message: 'Tous les messages « fourrière » et « à vendre » seront retirés de Discord. Utilisez « Synchroniser » pour les republier.', confirmLabel: 'Supprimer', danger: true })) busy(b, async () => { const n = await api.discordPurge(null); await sleep(1200); await api.discordRun(); await reload(); toast(`${n} message(s) en cours de suppression.`, 'ok'); }); }); return b; })()),
        s.recent.length ? h('div', { class: 'table-wrap' }, h('table', { class: 'table jobs' }, h('thead', {}, h('tr', {}, ['Quand', 'Salon', 'Action', 'État', 'Détail'].map((t) => h('th', {}, t)))),
          h('tbody', {}, s.recent.map((j) => h('tr', {}, h('td', {}, rel(j.created_at)), h('td', {}, { impound: 'Fourrière', sale: 'À vendre', staff: 'Personnel' }[j.slot]), h('td', {}, JOB[j.op]), h('td', {}, h('span', { class: `badge plain ${j.state === 'failed' ? 'red' : j.state === 'done' ? 'green' : 'gray'}` }, JOB_STATE[j.state])), h('td', { class: 'muted' }, j.last_error || '')))))) : h('p', { class: 'muted' }, 'Aucun envoi pour le moment.')),
      h('section', { class: 'card card-pad stack' }, h('h2', { class: 'card-title' }, 'Comment créer un webhook Discord ?'),
        h('ol', { style: { margin: 0, paddingLeft: '20px', display: 'grid', gap: '6px' } }, ['Dans Discord, ouvrez les paramètres du salon (icône engrenage) → Intégrations → Webhooks.', 'Cliquez sur « Nouveau webhook », donnez-lui un nom, puis « Copier l\'URL du webhook ».', 'Collez l\'adresse dans le bon cadre ci-dessus, activez l\'envoi et cliquez sur « Enregistrer ».', 'Utilisez « Envoyer un test » pour vérifier. Un webhook par salon : « fourrière », « à vendre » et « personnel ».'].map((t) => h('li', {}, t))),
        h('p', { class: 'muted small' }, 'Ne partagez jamais ces adresses : quiconque les possède peut écrire dans votre salon.')));
  }
  paint();
  const timer = setInterval(() => reload().catch(() => {}), 15000);
  return { el, destroy: () => clearInterval(timer) };
}
