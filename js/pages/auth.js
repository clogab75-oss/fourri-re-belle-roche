import { h, icon, busy, toast, field } from '../lib/ui.js';
import * as api from '../lib/api.js';

const safeNext = (n) => (typeof n === 'string' && n.startsWith('/') && !n.startsWith('//') ? n : '/');
const nameInput = (id, ac) => h('input', { class: 'input', id, type: 'text', autocomplete: ac, maxlength: '40', required: true, autocapitalize: 'words' });
const pwInput = (id, ac = 'current-password') => h('input', { class: 'input', id, type: 'password', autocomplete: ac, maxlength: '72', required: true });
const shell = (...c) => h('div', { class: 'auth-wrap' }, h('div', { class: 'card auth-card stack-lg' }, c));

function codePanel(code, onDone, text) {
  const box = h('div', { class: 'recovery-box', 'data-testid': 'recovery-code' }, code);
  return shell(
    h('div', {}, h('h1', {}, 'Notez votre code'), h('p', { class: 'muted', style: { marginTop: '8px' } }, text)),
    box,
    h('div', { class: 'banner' }, icon('alert'), h('div', {}, 'Ce code ne sera plus jamais affiché. Il est votre seul moyen de récupérer votre compte si vous oubliez votre mot de passe.')),
    h('div', { class: 'row' },
      h('button', { class: 'btn secondary', type: 'button', onClick: async () => { try { await navigator.clipboard.writeText(code); toast('Code copié.', 'ok'); } catch { toast('Sélectionnez le code pour le copier.', 'warn'); } } }, icon('copy'), 'Copier'),
      h('button', { class: 'btn grow', type: 'button', onClick: onDone }, "J'ai noté mon code")));
}

export function login({ query, navigate }) {
  const nom = nameInput('nom', 'family-name'); const prenom = nameInput('prenom', 'given-name'); const pw = pwInput('pw');
  const err = h('div', { class: 'form-error', role: 'alert', hidden: true });
  const submit = h('button', { class: 'btn lg block', type: 'submit' }, 'Se connecter');
  const form = h('form', { class: 'stack', onSubmit: (e) => {
    e.preventDefault(); err.hidden = true;
    busy(submit, async () => {
      try { await api.login(nom.value.trim(), prenom.value.trim(), pw.value); navigate(safeNext(query.next), true); }
      catch (x) { err.textContent = x.message; err.hidden = false; }
    });
  } },
    h('div', { class: 'form-grid' }, field('Nom RP', nom), field('Prénom RP', prenom)), field('Mot de passe', pw), err, submit);
  return shell(h('div', {}, h('h1', {}, 'Connexion'), h('p', { class: 'muted', style: { marginTop: '6px' } }, 'Connectez-vous avec votre nom et prénom RP.')), form,
    h('div', { class: 'stack small' }, h('a', { href: '#/mot-de-passe-oublie' }, 'Mot de passe oublié ?'), h('span', {}, 'Pas encore de compte ? ', h('a', { href: '#/inscription' }, 'Créer un compte'))));
}

export function register({ navigate }) {
  const nom = nameInput('nom', 'family-name'); const prenom = nameInput('prenom', 'given-name');
  const pw = pwInput('pw', 'new-password'); const pw2 = pwInput('pw2', 'new-password');
  const err = h('div', { class: 'form-error', role: 'alert', hidden: true });
  const submit = h('button', { class: 'btn lg block', type: 'submit' }, 'Créer mon compte');
  const root = h('div', {});
  const form = h('form', { class: 'stack', onSubmit: (e) => {
    e.preventDefault(); err.hidden = true;
    if (pw.value !== pw2.value) { err.textContent = 'Les deux mots de passe ne sont pas identiques.'; err.hidden = false; return; }
    busy(submit, async () => {
      try {
        const code = await api.register(nom.value.trim(), prenom.value.trim(), pw.value);
        root.replaceChildren(codePanel(code, () => navigate('/vehicules'), 'Votre compte est créé et vous êtes connecté. Conservez ce code de récupération en lieu sûr.'));
        window.scrollTo(0, 0);
      } catch (x) { err.textContent = x.message; err.hidden = false; }
    });
  } },
    h('div', { class: 'form-grid' }, field('Nom RP', nom), field('Prénom RP', prenom)),
    field('Mot de passe', pw, '8 caractères minimum.'), field('Confirmer le mot de passe', pw2), err, submit);
  root.append(shell(h('div', {}, h('h1', {}, 'Créer un compte'), h('p', { class: 'muted', style: { marginTop: '6px' } }, 'Un seul compte par nom et prénom RP.')), form,
    h('p', { class: 'small' }, 'Déjà inscrit ? ', h('a', { href: '#/connexion' }, 'Se connecter'))));
  return root;
}

export function forgot({ navigate }) {
  const nom = nameInput('nom', 'family-name'); const prenom = nameInput('prenom', 'given-name');
  const code = h('input', { class: 'input', id: 'code', type: 'text', autocomplete: 'off', required: true, placeholder: 'XXXX-XXXX-XXXX-XXXX', maxlength: '24', spellcheck: 'false' });
  const pw = pwInput('pw', 'new-password'); const pw2 = pwInput('pw2', 'new-password');
  const err = h('div', { class: 'form-error', role: 'alert', hidden: true });
  const submit = h('button', { class: 'btn lg block', type: 'submit' }, 'Changer mon mot de passe');
  const root = h('div', {});
  const form = h('form', { class: 'stack', onSubmit: (e) => {
    e.preventDefault(); err.hidden = true;
    if (pw.value !== pw2.value) { err.textContent = 'Les deux mots de passe ne sont pas identiques.'; err.hidden = false; return; }
    busy(submit, async () => {
      try {
        const r = await api.resetPassword(nom.value.trim(), prenom.value.trim(), code.value.trim(), pw.value);
        if (!r.ok) { err.textContent = r.message; err.hidden = false; return; }
        root.replaceChildren(codePanel(r.recovery_code, () => navigate('/connexion'), 'Mot de passe modifié. Voici votre NOUVEAU code de récupération : l\'ancien n\'est plus valable.'));
      } catch (x) { err.textContent = x.message; err.hidden = false; }
    });
  } },
    h('div', { class: 'form-grid' }, field('Nom RP', nom), field('Prénom RP', prenom)),
    field('Code de récupération', code, 'Le code à 16 caractères donné à la création de votre compte.'),
    field('Nouveau mot de passe', pw, '8 caractères minimum.'), field('Confirmer le mot de passe', pw2), err, submit);
  root.append(shell(h('div', {}, h('h1', {}, 'Mot de passe oublié'), h('p', { class: 'muted', style: { marginTop: '6px' } }, 'Utilisez votre code de récupération. Sans code, demandez à un gérant de réinitialiser votre mot de passe.')), form,
    h('p', { class: 'small' }, h('a', { href: '#/connexion' }, 'Retour à la connexion'))));
  return root;
}
