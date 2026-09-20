import { h, icon } from '../lib/ui.js';
import * as api from '../lib/api.js';
import { money } from '../lib/format.js';

export default async function home({ navigate }) {
  const [pr, imp, sale] = await Promise.all([api.pricing().catch(() => null), api.impound().catch(() => []), api.forSale().catch(() => [])]);
  const fee = Number(pr?.handling_fee ?? 1000); const rate = Number(pr?.daily_rate ?? 1500); const days = Number(pr?.auto_sale_days ?? 7);
  const total = (d) => fee + rate * d;

  const input = h('input', { type: 'text', placeholder: 'AB-123-CD', maxlength: '16', autocomplete: 'off', spellcheck: 'false', 'aria-label': 'Numéro de plaque' });
  const form = h('form', { class: 'plate-search', onSubmit: (e) => { e.preventDefault(); const v = input.value.trim(); navigate('/vehicules' + (v ? '?q=' + encodeURIComponent(v) : '')); } },
    h('label', { class: 'plate lg' }, input),
    h('button', { class: 'btn amber lg', type: 'submit' }, icon('search'), 'Rechercher'));

  const hero = h('section', { class: 'hero' },
    h('div', { class: 'container hero-in' },
      h('div', {},
        h('h1', {}, 'Votre véhicule est à la ', h('span', { class: 'nowrap' }, h('em', {}, 'fourrière'), '\u00a0?')),
        h('p', { class: 'lead' }, 'Entrez votre plaque, retrouvez-le en quelques secondes et échangez directement avec un employé pour le récupérer.'),
        form,
        h('div', { class: 'hero-stats' },
          h('div', {}, h('div', { class: 'n num' }, imp.length), h('div', { class: 'l' }, imp.length > 1 ? 'véhicules en fourrière' : 'véhicule en fourrière')),
          h('div', {}, h('div', { class: 'n num' }, sale.length), h('div', { class: 'l' }, sale.length > 1 ? 'véhicules à vendre' : 'véhicule à vendre')))),
      h('aside', { class: 'ticket', 'aria-label': 'Grille tarifaire' },
        h('div', { class: 't-head' }, h('strong', {}, 'Grille tarifaire'), h('span', {}, 'Ticket de fourrière')),
        h('dl', {},
          h('div', { class: 'line' }, h('dt', {}, 'Frais de dossier'), h('dd', {}, money(fee))),
          h('div', { class: 'line' }, h('dt', {}, 'Garde, par jour'), h('dd', {}, money(rate)))),
        h('div', { class: 'ex' },
          [1, 3, 7].map((d) => h('div', {}, h('b', {}, money(total(d))), h('span', {}, d === 1 ? '1 jour' : `${d} jours`)))),
        h('p', { class: 'foot' }, `Le premier jour est compté en entier. Sans réclamation au bout de ${days} jours, le véhicule est mis en vente.`))),
    h('div', { class: 'hazard' }));

  const steps = h('section', { class: 'container section' }, h('h2', {}, 'Comment ça marche'),
    h('div', { class: 'steps', style: { marginTop: '14px' } },
      [['Retrouvez votre véhicule', 'Cherchez par plaque, modèle ou couleur parmi les véhicules actuellement en fourrière.'],
        ['Cliquez sur « C\'est ma voiture »', 'Connectez-vous : une conversation privée s\'ouvre automatiquement avec l\'équipe.'],
        ['Récupérez-le', 'Un employé valide la remise et vous indique le montant à régler.']]
        .map(([t, p]) => h('div', { class: 'card step' }, h('h3', {}, t), h('p', {}, p)))));

  const cta = h('section', { class: 'container section' }, h('div', { class: 'cta-grid' },
    h('a', { class: 'card cta-card', href: '#/vehicules' }, h('span', { class: 'ic' }, icon('truck')), h('div', {}, h('h3', {}, 'Véhicules en fourrière'), h('p', { class: 'muted' }, `${imp.length} en ce moment · voir la liste`))),
    h('a', { class: 'card cta-card', href: '#/vente' }, h('span', { class: 'ic' }, icon('tag')), h('div', {}, h('h3', {}, 'Véhicules à vendre'), h('p', { class: 'muted' }, `${sale.length} annonce${sale.length > 1 ? 's' : ''} · voir les offres`)))));

  const discord = h('section', { class: 'container section' }, h('div', { class: 'discord-band' },
    h('div', {}, h('h3', {}, 'Rejoignez notre Discord'), h('p', {}, 'Restez informé des nouveaux véhicules et échangez avec la communauté.')),
    h('a', { class: 'btn', href: api.cfg.DISCORD_INVITE, target: '_blank', rel: 'noopener noreferrer' }, icon('discord'), 'Ouvrir Discord')));

  return h('div', {}, hero, steps, cta, discord);
}
