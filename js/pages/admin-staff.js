/* Personnel : liste, ajout (nouveau compte ou compte existant), licenciement, rôles. */
import { h, icon, loading, empty, toast, busy, btn, field, openModal, confirmDialog, debounce } from '../lib/ui.js';
import * as api from '../lib/api.js';
import { adminLayout, pageHead } from '../lib/layout.js';
import { dt, dateOnly, rel, ROLE } from '../lib/format.js';

const ALPHA = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const randomPassword = () => Array.from(crypto.getRandomValues(new Uint32Array(12)), (n) => ALPHA[n % ALPHA.length]).join('');
const roleBadge = (r) => h('span', { class: `badge ${r === 'admin' ? 'violet' : r === 'gerant' ? 'amber' : ''}` }, ROLE[r] + (r === 'admin' ? ' principal' : ''));

function credentialsModal(title, lines, code) {
  const m = openModal({ title, persistent: true, body: h('div', { class: 'stack' }, ...lines.map((l) => h('p', {}, l)),
    code ? [h('div', { class: 'recovery-box' }, code), h('div', { class: 'banner' }, icon('alert'), h('div', {}, 'Ce code de récupération ne sera plus affiché. Transmettez-le avec le mot de passe à la personne concernée.'))] : null),
    actions: [btn('Fermer', { onClick: () => m.close() })] });
}

export default async function staffPage() {
  const manager = api.isManager(); const admin = api.isAdmin(); const me = api.state.profile;
  const root = h('div', { class: 'stack-lg' }, loading());
  const addBtn = manager ? h('button', { class: 'btn', type: 'button', onClick: () => addModal() }, icon('plus'), 'Ajouter un membre') : null;
  const el = adminLayout('staff', pageHead('Personnel', manager ? 'Ajoutez ou retirez des membres. Un licenciement conserve l\'historique et les véhicules ajoutés.' : 'Les membres de l\'équipe de la fourrière.', addBtn), root);
  const reload = () => load().catch((e) => toast(e.message, 'error'));

  async function load() {
    const rows = await api.staffMembers();
    const active = rows.filter((r) => r.status === 'actif'); const former = rows.filter((r) => r.status === 'vire');
    const fire = (r) => { const reason = h('textarea', { class: 'input', id: 'reason', maxlength: '300', rows: '3', placeholder: 'Motif (facultatif)' });
      const go = btn('Virer', { kind: 'danger', onClick: () => busy(go, async () => { await api.staffFire(r.user_id, reason.value); toast('Membre retiré du personnel.', 'ok'); m.close(); reload(); }) });
      const m = openModal({ title: `Virer ${r.profile.prenom} ${r.profile.nom} ?`, body: h('div', { class: 'stack' }, h('p', {}, 'Son compte repasse en simple client. Son historique et les véhicules qu\'il a ajoutés sont conservés.'), field('Motif', reason)), actions: [btn('Annuler', { kind: 'secondary', onClick: () => m.close() }), go] }); };
    const reset = (r) => { const pw = h('input', { class: 'input', id: 'npw', type: 'text', autocomplete: 'off', value: randomPassword(), maxlength: '72' });
      const go = btn('Réinitialiser', { onClick: () => busy(go, async () => { await api.staffResetPassword(r.user_id, pw.value); m.close(); credentialsModal('Mot de passe réinitialisé', [`Nouveau mot de passe de ${r.profile.prenom} ${r.profile.nom} :`, pw.value]); }) });
      const m = openModal({ title: 'Réinitialiser le mot de passe', body: field('Nouveau mot de passe', pw, 'Les sessions ouvertes de cette personne seront fermées.'), actions: [btn('Annuler', { kind: 'secondary', onClick: () => m.close() }), go] }); };
    const setRole = async (r, role) => { try { await api.staffSetRole(r.user_id, role); toast('Rôle modifié.', 'ok'); } catch (e) { toast(e.message, 'error'); } reload(); };

    const tbl = h('section', { class: 'card' }, h('div', { class: 'table-wrap' }, h('table', { class: 'table stackable' },
      h('thead', {}, h('tr', {}, ['Nom', 'Prénom', 'Rôle', "Date d'arrivée", 'Statut', 'Dernière connexion', ''].map((t) => h('th', {}, t)))),
      h('tbody', {}, active.map((r) => { const p = r.profile || {}; const isMain = p.is_main_admin; const self = p.id === me.id;
        return h('tr', {}, h('td', { 'data-label': 'Nom' }, h('strong', {}, p.nom)), h('td', { 'data-label': 'Prénom' }, p.prenom), h('td', { 'data-label': 'Rôle' }, roleBadge(r.role)),
          h('td', { 'data-label': 'Arrivée' }, dateOnly(r.hired_at)), h('td', { 'data-label': 'Statut' }, h('span', { class: 'badge green' }, 'Actif')), h('td', { 'data-label': 'Dernière connexion' }, p.last_seen_at ? rel(p.last_seen_at) : 'Jamais'),
          h('td', { class: 'actions', 'data-label': '' }, manager && !isMain && !self ? h('div', { class: 'row', style: { justifyContent: 'flex-end', gap: '6px' } },
            admin ? h('select', { class: 'input', style: { width: 'auto', minHeight: '34px', padding: '4px 30px 4px 10px' }, 'aria-label': `Rôle de ${p.prenom} ${p.nom}`, onChange: (e) => setRole(r, e.target.value) }, ['employe', 'gerant'].map((x) => h('option', { value: x, selected: x === r.role }, ROLE[x]))) : null,
            btn('Mot de passe', { sm: true, kind: 'secondary', ic: 'key', onClick: () => reset(r) }), btn('Virer', { sm: true, kind: 'danger', onClick: () => fire(r) })) : (isMain ? h('span', { class: 'small muted' }, 'Compte protégé') : null))); })))));
    const past = former.length ? h('section', { class: 'stack' }, h('h2', {}, `Anciens membres (${former.length})`), h('section', { class: 'card' }, h('div', { class: 'table-wrap' }, h('table', { class: 'table stackable' },
      h('thead', {}, h('tr', {}, ['Nom', 'Rôle', 'Arrivée', 'Départ', 'Par', 'Motif'].map((t) => h('th', {}, t)))),
      h('tbody', {}, former.map((r) => h('tr', {}, h('td', { 'data-label': 'Nom' }, h('strong', {}, r.profile ? `${r.profile.prenom} ${r.profile.nom}` : '—')), h('td', { 'data-label': 'Rôle' }, ROLE[r.role]), h('td', { 'data-label': 'Arrivée' }, dateOnly(r.hired_at)),
        h('td', { 'data-label': 'Départ' }, dt(r.fired_at)), h('td', { 'data-label': 'Par' }, r.fired_by_name || '—'), h('td', { 'data-label': 'Motif' }, r.fire_reason || '—')))))))) : null;
    root.replaceChildren(tbl, past);
  }

  /* ---------------- Comptes des forces de l'ordre : consultation des saisies uniquement ---------------- */
  const policeBox = manager ? h('div', {}, loading()) : null;
  async function loadPolice() {
    const rows = await api.policeAccounts();
    policeBox.replaceChildren(rows.length ? h('div', { class: 'table-wrap' }, h('table', { class: 'table stackable' },
      h('thead', {}, h('tr', {}, ['Nom', 'Prénom', 'Créé le', 'Dernière connexion', ''].map((t) => h('th', {}, t)))),
      h('tbody', {}, rows.map((p) => h('tr', {}, h('td', { 'data-label': 'Nom' }, h('strong', {}, p.nom)), h('td', { 'data-label': 'Prénom' }, p.prenom),
        h('td', { 'data-label': 'Créé le' }, dateOnly(p.created_at)), h('td', { 'data-label': 'Dernière connexion' }, p.last_seen_at ? rel(p.last_seen_at) : 'Jamais'),
        h('td', { class: 'actions', 'data-label': '' }, h('div', { class: 'row', style: { justifyContent: 'flex-end', gap: '6px' } },
          btn('Mot de passe', { sm: true, kind: 'secondary', ic: 'key', onClick: () => { const pw = h('input', { class: 'input', id: 'ppw', type: 'text', autocomplete: 'off', value: randomPassword(), maxlength: '72' });
            const go = btn('Réinitialiser', { onClick: () => busy(go, async () => { await api.staffResetPassword(p.id, pw.value); m.close(); credentialsModal('Mot de passe réinitialisé', [`Nouveau mot de passe de ${p.prenom} ${p.nom} :`, pw.value]); }) });
            const m = openModal({ title: 'Réinitialiser le mot de passe', body: field('Nouveau mot de passe', pw), actions: [btn('Annuler', { kind: 'secondary', onClick: () => m.close() }), go] }); } }),
          btn('Retirer l\'accès', { sm: true, kind: 'danger', onClick: async () => {
            if (await confirmDialog({ title: `Retirer l'accès de ${p.prenom} ${p.nom} ?`, message: 'Ce compte redevient un simple client et perd tout accès aux saisies.', confirmLabel: 'Retirer', danger: true })) { try { await api.revokePolice(p.id); toast('Accès retiré.', 'ok'); await loadPolice(); } catch (e) { toast(e.message, 'error'); } } } }))))))))
      : empty('Aucun compte', 'Ajoutez-en un avec le formulaire ci-dessus.'));
  }
  function addPoliceModal() {
    const nom = h('input', { class: 'input', id: 'p-nom', maxlength: '40', autocomplete: 'off' }); const prenom = h('input', { class: 'input', id: 'p-prenom', maxlength: '40', autocomplete: 'off' });
    const pw = h('input', { class: 'input', id: 'p-pw', type: 'text', autocomplete: 'off', value: randomPassword(), maxlength: '72' });
    const go = btn('Créer le compte', { onClick: () => busy(go, async () => {
      const r = await api.createPoliceAccount(nom.value.trim(), prenom.value.trim(), pw.value); m.close(); await loadPolice();
      credentialsModal('Compte créé', [`${prenom.value.trim()} ${nom.value.trim()} — Forces de l'ordre`, `Mot de passe : ${pw.value}`], r.recovery_code); }) });
    const m = openModal({ title: 'Nouveau compte forces de l\'ordre', body: h('div', { class: 'stack' },
      h('p', { class: 'muted' }, 'Ce compte ne voit que la page des saisies : aucun accès aux véhicules, conversations ou personnel de la fourrière.'),
      h('div', { class: 'form-grid' }, field('Nom RP', nom), field('Prénom RP', prenom), h('div', { class: 'full' }, field('Mot de passe provisoire', pw)))),
      actions: [btn('Annuler', { kind: 'secondary', onClick: () => m.close() }), go] });
  }
  function addModal() {
    let tab = 'new'; const body = h('div', {}); const foot = h('div', { class: 'row', style: { display: 'contents' } });
    const m = openModal({ title: 'Ajouter un membre du personnel', wide: true, body, actions: [] });
    const tabs = h('div', { class: 'tabs', role: 'tablist' }, [['new', 'Nouveau compte'], ['old', 'Compte existant']].map(([k, l]) => h('button', { class: 'tab', role: 'tab', type: 'button', 'aria-selected': String(k === tab), dataset: { k }, onClick: () => { tab = k; [...tabs.children].forEach((b) => b.setAttribute('aria-selected', String(b.dataset.k === k))); paint(); } }, l)));
    function paint() { body.replaceChildren(tabs, tab === 'new' ? formNew() : formOld()); }
    function formNew() {
      const nom = h('input', { class: 'input', id: 'n-nom', maxlength: '40', autocomplete: 'off' }); const prenom = h('input', { class: 'input', id: 'n-prenom', maxlength: '40', autocomplete: 'off' });
      const pw = h('input', { class: 'input', id: 'n-pw', type: 'text', autocomplete: 'off', value: randomPassword(), maxlength: '72' });
      const role = h('select', { class: 'input', id: 'n-role' }, h('option', { value: 'employe' }, 'Employé'), h('option', { value: 'gerant' }, 'Gérant'));
      const go = btn('Créer le compte', { onClick: () => busy(go, async () => {
        const r = await api.staffCreate(nom.value.trim(), prenom.value.trim(), pw.value, role.value); m.close(); reload();
        credentialsModal('Compte créé', [`${prenom.value.trim()} ${nom.value.trim()} — ${ROLE[role.value]}`, `Mot de passe : ${pw.value}`], r.recovery_code); }) });
      return h('div', { class: 'stack' }, h('div', { class: 'form-grid' }, field('Nom RP', nom), field('Prénom RP', prenom), field('Mot de passe provisoire', pw, 'Généré automatiquement, modifiable.'), field('Rôle', role)), h('div', { class: 'row', style: { justifyContent: 'flex-end' } }, go));
    }
    function formOld() {
      const q = h('input', { class: 'input', id: 'o-q', type: 'search', placeholder: 'Rechercher un nom ou un prénom (2 lettres minimum)', autocomplete: 'off' });
      const out = h('div', { class: 'stack' }, h('p', { class: 'muted small' }, 'Seuls les comptes clients apparaissent.'));
      q.addEventListener('input', debounce(async () => {
        try { const list = await api.searchClients(q.value);
          out.replaceChildren(...(list.length ? list.map((p) => h('div', { class: 'row between card card-pad', style: { padding: '10px 14px' } }, h('strong', {}, `${p.prenom} ${p.nom}`),
            h('div', { class: 'row', style: { gap: '6px' } }, btn('Employé', { sm: true, onClick: async () => { try { await api.staffRecruit(p.id, 'employe'); toast('Membre recruté.', 'ok'); m.close(); reload(); } catch (e) { toast(e.message, 'error'); } } }),
              admin ? btn('Gérant', { sm: true, kind: 'secondary', onClick: async () => { try { await api.staffRecruit(p.id, 'gerant'); toast('Gérant nommé.', 'ok'); m.close(); reload(); } catch (e) { toast(e.message, 'error'); } } }) : null))) : [h('p', { class: 'muted' }, q.value.trim().length < 2 ? '' : 'Aucun compte client trouvé.')]));
        } catch (e) { toast(e.message, 'error'); }
      }, 250));
      return h('div', { class: 'stack' }, field('Compte à recruter', q), out, admin ? null : h('p', { class: 'hint' }, "Seul l'administrateur peut nommer un gérant à partir d'un compte existant. Vous pouvez en revanche créer directement un compte gérant."));
    }
    paint();
  }

  if (manager) await loadPolice();

  const el2 = manager ? h('section', { class: 'stack' }, h('div', { class: 'row between' },
    h('h2', {}, 'Comptes forces de l\'ordre'), h('button', { class: 'btn secondary', type: 'button', onClick: addPoliceModal }, icon('plus'), 'Ajouter un compte')),
    h('p', { class: 'muted' }, 'Ces comptes consultent uniquement le registre des saisies (page « Saisies »), pour savoir si un véhicule a été saisi. Ils n\'ont aucun accès à la fourrière.'),
    policeBox) : null;

  await load();
  const un = api.watch([{ table: 'staff' }], () => reload(), 600);
  return { el: h('div', { class: 'stack-lg' }, el, el2), destroy: un };
}
