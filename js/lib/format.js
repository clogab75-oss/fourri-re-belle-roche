/* Formats français : montants, dates (fuseau de Paris), recherche sans accents. */
const TZ = 'Europe/Paris';
const F = (o) => new Intl.DateTimeFormat('fr-FR', { timeZone: TZ, ...o });
const FMT = { dt: F({ dateStyle: 'medium', timeStyle: 'short' }), d: F({ dateStyle: 'medium' }), t: F({ hour: '2-digit', minute: '2-digit' }),
  day: F({ weekday: 'long', day: 'numeric', month: 'long' }), ymd: F({ year: 'numeric', month: '2-digit', day: '2-digit' }) };
const EUR = new Intl.NumberFormat('fr-FR', { style: 'currency', currency: 'EUR', maximumFractionDigits: 0, useGrouping: 'always' });
export const money = (n) => EUR.format(Number(n) || 0);
export const dt = (d) => (d ? FMT.dt.format(new Date(d)) : '—');
export const dateOnly = (d) => (d ? FMT.d.format(new Date(d)) : '—');
export const timeOnly = (d) => (d ? FMT.t.format(new Date(d)) : '');
export function dayLabel(d) {
  const k = FMT.ymd.format(new Date(d));
  if (k === FMT.ymd.format(new Date())) return "Aujourd'hui";
  if (k === FMT.ymd.format(new Date(Date.now() - 864e5))) return 'Hier';
  return FMT.day.format(new Date(d));
}
export function rel(d) {
  if (!d) return '';
  const s = Math.max(0, Math.round((Date.now() - new Date(d).getTime()) / 1000));
  if (s < 45) return "à l'instant";
  if (s < 3600) return `il y a ${Math.round(s / 60)} min`;
  if (s < 86400) return `il y a ${Math.round(s / 3600)} h`;
  if (s < 86400 * 7) return `il y a ${Math.round(s / 86400)} j`;
  return dateOnly(d);
}
export const norm = (s) => String(s ?? '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
export const plateKey = (s) => String(s ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '');
export const plural = (n, one, many = one + 's') => `${n} ${n > 1 ? many : one}`;
export const ROLE = { client: 'Client', employe: 'Employé', gerant: 'Gérant', admin: 'Administrateur', police: 'Police', gendarmerie: 'Gendarmerie' };
export const initials = (p) => ((p?.prenom || '?')[0] + (p?.nom || '')[0]).toUpperCase();
const COLORS = { noir: '#111', blanc: '#f5f5f5', gris: '#8a949e', argent: '#c0c6cc', rouge: '#c62828', bordeaux: '#7b1e2b', bleu: '#1e5bb8', vert: '#2e7d32', jaune: '#f4c20d',
  orange: '#ef6c00', violet: '#6a3fb5', rose: '#e77fa6', marron: '#6d4c41', beige: '#d7c4a3', or: '#c9a227', turquoise: '#1fb5ad' };
export function colorHex(name) { const n = norm(name); for (const [k, v] of Object.entries(COLORS)) if (n.includes(k)) return v; return null; }
export const STATUS = {
  en_fourriere: ['En fourrière', ''], reclamee: ['Réclamée', 'amber'], recuperee: ['Récupérée', 'green'],
  attente_vente: ['En attente de mise en vente', 'violet'], a_vendre: ['À vendre', 'green'], vendue: ['Vendue', 'gray'], archivee: ['Archivée', 'gray'],
};
