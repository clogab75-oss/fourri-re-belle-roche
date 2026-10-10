import { h, icon, busy, toast, field } from '../lib/ui.js';
import * as api from '../lib/api.js';
import { ROLE, dateOnly, initials } from '../lib/format.js';

export default async function account({ navigate }) {
  const p = api.state.profile;
  const phone = h('input', { class: 'input', id: 'phone', type: 'tel', value: p.phone_rp || '', maxlength: '20', placeholder: '555-0123' });
  const phoneBtn = h('button', { class: 'btn', type: 'submit' }, 'Enregistrer');
  const cur = h('input', { class: 'input', id: 'cur', type: 'password', autocomplete: 'current-password', required: true });
  const nw = h('input', { class: 'input', id: 'nw', type: 'password', autocomplete: 'new-password', required: true, maxlength: '72' });
  const nw2 = h('input', { class: 'input', id: 'nw2', type: 'password', autocomplete: 'new-password', required: true, maxlength: '72' });
  const pwBtn = h('button', { class: 'btn', type: 'submit' }, 'Changer le mot de passe');
  const rc = h('input', { class: 'input', id: 'rcpw', type: 'password', autocomplete: 'current-password', required: true });
  const rcBtn = h('button', { class: 'btn secondary', type: 'submit' }, 'Générer un nouveau code');
  const rcOut = h('div', { hidden: true });

  return h('div', { class: 'container page', style: { maxWidth: '820px' } },
    h('div', { class: 'card card-pad row', style: { gap: '18px', marginBottom: '20px' } },
      h('span', { class: 'avatar lg' }, initials(p)),
      h('div', {}, h('h1', { style: { fontSize: '2rem' } }, `${p.prenom} ${p.nom}`),
        h('div', { class: 'row', style: { marginTop: '6px' } }, h('span', { class: 'badge' }, ROLE[p.role]), h('span', { class: 'muted small' }, `Membre depuis le ${dateOnly(p.created_at)}`))),
      h('button', { class: 'btn secondary', style: { marginLeft: 'auto' }, type: 'button', onClick: async () => { await api.logout(); toast('Vous êtes déconnecté.', 'ok'); navigate('/'); } }, icon('logout'), 'Se déconnecter')),
    h('div', { class: 'stack-lg' },
      h('form', { class: 'card card-pad stack', onSubmit: (e) => { e.preventDefault(); busy(phoneBtn, async () => { await api.updatePhone(phone.value); await api.syncSession(); toast('Numéro enregistré.', 'ok'); }); } },
        h('h2', { class: 'card-title' }, 'Mes informations'), field('Téléphone RP (facultatif)', phone, 'Visible uniquement par le personnel.'), h('div', {}, phoneBtn)),
      h('form', { class: 'card card-pad stack', onSubmit: (e) => {
        e.preventDefault();
        if (nw.value !== nw2.value) return toast('Les deux mots de passe ne sont pas identiques.', 'error');
        busy(pwBtn, async () => { await api.changePassword(cur.value, nw.value); cur.value = nw.value = nw2.value = ''; toast('Mot de passe modifié. Les autres appareils sont déconnectés.', 'ok'); });
      } }, h('h2', { class: 'card-title' }, 'Mot de passe'),
        h('div', { class: 'form-grid' }, field('Mot de passe actuel', cur), h('span', {}), field('Nouveau mot de passe', nw, '8 caractères minimum.'), field('Confirmer', nw2)), h('div', {}, pwBtn)),
      h('form', { class: 'card card-pad stack', onSubmit: (e) => {
        e.preventDefault();
        busy(rcBtn, async () => {
          const code = await api.newRecoveryCode(rc.value); rc.value = '';
          rcOut.hidden = false;
          rcOut.replaceChildren(h('div', { class: 'recovery-box' }, code), h('p', { class: 'small muted', style: { marginTop: '8px' } }, "Notez-le : l'ancien code ne fonctionne plus et celui-ci ne sera plus affiché."));
        });
      } }, h('h2', { class: 'card-title' }, 'Code de récupération'),
        h('p', { class: 'muted' }, 'Ce code permet de réinitialiser votre mot de passe si vous l\'oubliez. Vous pouvez en générer un nouveau à tout moment.'),
        field('Confirmez avec votre mot de passe', rc), h('div', {}, rcBtn), rcOut)));
}
