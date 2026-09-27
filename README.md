# Fourrière de Belle Roche

Site web complet pour une fourrière : les visiteurs retrouvent leur véhicule et échangent avec l'équipe, les employés gèrent les véhicules, les gérants gèrent les ventes, les tarifs et le personnel. Tout est **réel et branché sur une vraie base de données** (Supabase) : rien n'est simulé, sauf les paiements — **aucun paiement réel n'existe**, tous les montants sont fictifs.

- Site 100 % statique : hébergé gratuitement sur **GitHub Pages**
- Base de données, comptes, photos et temps réel : **Supabase** (gratuit pour ce volume)
- Notifications et catalogue : **webhooks Discord** pilotés depuis le tableau de bord

---

## 1. Ce que fait le site

**Public et clients**
- Liste des véhicules en fourrière (photo, modèle, couleur, plaque, date d'arrivée, jours, montant) avec **recherche en direct** par plaque, modèle ou couleur.
- Bouton **« C'est ma voiture »** : après connexion, une demande et une conversation privée se créent automatiquement. **Plusieurs clients peuvent réclamer le même véhicule**, chacun a sa conversation.
- Une fois réclamé, le véhicule disparaît de la liste publique (il reste en base avec son statut).
- Page **« À vendre »** avec bouton « Je suis intéressé » (ouvre une conversation d'achat).
- Messagerie en temps réel, compteur de messages non lus, notifications internes.
- Comptes par **Nom RP + Prénom RP** (uniques), session conservée, mot de passe oublié via un **code de récupération** remis à l'inscription.

**Employés** : ajouter / modifier des véhicules (photos multiples), répondre aux conversations, consulter le personnel et les statistiques de base.

**Gérants** : tout ce que font les employés, plus : tarifs, mise en vente, clôture des ventes, personnel (ajout / licenciement), suppression définitive de conversations, statistiques financières, historique complet, réglages Discord.

**Administrateur (Gabin Muller)** : tous les droits, dont la promotion / rétrogradation des membres. Compte unique, protégé, impossible à supprimer ou à dupliquer.

**Codes promo** : les gérants créent des codes de réduction (ex. **−50 %**) depuis *Espace personnel → Codes promo*. Dans une conversation, le client (ou un employé) clique sur **« Code promo »** ou tape **`/code SONCODE`** : la réduction s'affiche dans le chat et s'applique automatiquement, **sur la fourrière** (montant à régler pour récupérer le véhicule) **et sur la vente** (prix d'achat). Un code peut être limité à la fourrière ou à la vente, avoir une date de fin, un nombre d'utilisations maximum et n'être utilisable qu'une fois par personne. Les montants sont toujours recalculés par le serveur.

**Automatique** : à **7 jours** (modifiable) sans réclamation active, un véhicule passe en « En attente de mise en vente », visible **uniquement des gérants et de l'administrateur**.

**Options d'achat** : les gérants les définissent dans *Espace personnel → Tarifs* (ex. plein rempli, moteur réparé). Depuis une conversation d'achat, **Acheter maintenant** ouvre la sélection des options ; leurs prix sont ajoutés par la base au prix de la voiture et conservés dans l'historique.

**Préparation des annonces** : chaque nouveau véhicule apparaît immédiatement dans *Espace personnel → Ventes*. Le gérant peut y saisir prix et description à l'avance. Une annonce renseignée est publiée automatiquement au délai configuré ; sans prix, le véhicule reste dans la file jusqu'à sa mise en vente. **Mettre en vente maintenant** recale la date d'entrée au délai automatique et déclenche le traitement tout de suite. Une réclamation ouverte bloque cette action.

**Saisies** : depuis *Personnel*, créez un compte au rôle Police ou Gendarmerie. Ces comptes disposent uniquement du registre des saisies (plaque, modèle, couleur, service demandeur, récupération) et de statistiques dédiées, séparées des statistiques de la fourrière.

Les codes promo peuvent être limités à **l'achat d'une voiture uniquement** : par exemple, un code de −20 % appliqué dans la conversation réduit un prix de 100 000 € à 80 000 €. Les options facultatives restent en supplément.

### Qui peut faire quoi

| Action | Client | Employé | Gérant | Admin |
|---|:-:|:-:|:-:|:-:|
| Voir les listes publiques, réclamer, discuter | ✅ | ✅ | ✅ | ✅ |
| Ajouter / modifier un véhicule, photos | | ✅ | ✅ | ✅ |
| Supprimer un véhicule | | sa propre fiche, dans les 30 min, sans demande client | ✅ | ✅ |
| Voir les véhicules « en attente de vente » | | | ✅ | ✅ |
| Mettre en vente, clôturer une vente | | | ✅ | ✅ |
| Modifier les tarifs | | | ✅ | ✅ |
| Voir le personnel | | ✅ | ✅ | ✅ |
| Ajouter / virer du personnel, créer un gérant | | | ✅ | ✅ |
| Promouvoir / rétrograder un membre | | | | ✅ |
| Supprimer définitivement une conversation | | | ✅ | ✅ |
| Créer, désactiver, supprimer des codes promo | | | ✅ | ✅ |
| Saisir un code promo dans une conversation | ✅ (la sienne) | ✅ | ✅ | ✅ |
| Retirer un code promo d'une conversation | | | ✅ | ✅ |
| Statistiques de base | | ✅ | ✅ | ✅ |
| Statistiques financières, historique, Discord | | | ✅ | ✅ |

Les rôles **Police** et **Gendarmerie** sont créés depuis *Personnel*. Ils ne voient ni les véhicules, ni les conversations clients, ni les statistiques classiques ; leurs droits se limitent aux saisies et à leurs statistiques dédiées.

Ces droits sont **vérifiés dans la base de données** (fonctions SQL + règles RLS), jamais seulement dans le navigateur.

---

## 2. Technologies

- HTML, CSS et JavaScript « vanilla » (modules ES) : **aucune étape de compilation**
- [Supabase](https://supabase.com) : PostgreSQL, Auth, Storage, Realtime (bibliothèque `supabase-js`, fournie dans `assets/vendor/`)
- [Chart.js](https://www.chartjs.org) pour les graphiques (fourni localement)
- Polices Barlow / Barlow Condensed (fournies localement) : aucun appel à un service externe hormis Supabase
- Extensions Postgres : `pgcrypto` (mots de passe hachés en bcrypt), `pg_net` (envoi vers Discord), `pg_cron` (recommandé)

---

## 3. Installation pas à pas

### Étape 1 — Supabase : créer les tables et les règles de sécurité

1. Ouvrez votre projet sur [supabase.com/dashboard](https://supabase.com/dashboard) → **SQL Editor** → **New query**.
2. Ouvrez le fichier **`supabase/install_all.sql`**, copiez tout son contenu, collez-le, cliquez sur **Run**.
   Si un avertissement « destructive operations » apparaît, confirmez : c'est normal.
   Résultat attendu : *Success. No rows returned*.
   Le script crée les tables, les règles de sécurité (RLS), les fonctions, le stockage des photos (bucket `vehicle-photos`) et active le temps réel.
   Vous pouvez le relancer sans risque si besoin.

### Étape 2 — Créer le compte administrateur « Gabin Muller »

1. Nouvelle requête dans le SQL Editor, collez (en remplaçant par **votre** mot de passe, 8 à 72 caractères) :
   ```sql
   select public.bootstrap_main_admin('VOTRE_MOT_DE_PASSE');
   ```
2. Cliquez sur **Run**. Le résultat contient un `recovery_code` : **notez-le**, c'est votre secours si vous oubliez le mot de passe.
3. Ne mettez jamais ce mot de passe dans GitHub. Cette fonction ne s'exécute que depuis le SQL Editor : personne ne peut la lancer depuis le site, et un second administrateur est refusé.

### Étape 3 — Activer la tâche automatique (recommandé)

Elle passe les véhicules à 7 jours en « attente de vente » et envoie les messages Discord en attente, **même si personne ne visite le site**.

1. Supabase → **Database → Extensions** → activez **pg_cron**.
2. Collez et lancez le contenu de **`supabase/cron_recommended.sql`**.

Sans cela, ces contrôles se déclenchent quand même dès qu'une personne ouvre le site.

### Étape 4 — Discord : activer `pg_net`

Le script de l'étape 1 essaie de l'activer. Vérifiez dans **Database → Extensions** que **pg_net** est bien activé (sinon activez-le).

### Étape 5 — Relier le site à Supabase

Ouvrez **`js/config.js`** : l'adresse du projet (`SUPABASE_URL`) et la clé publique (`SUPABASE_KEY`, commençant par `sb_publishable_`) doivent y figurer. Elles sont déjà remplies si vous avez reçu ce projet avec vos valeurs.

Où les retrouver : Supabase → bouton **Connect** en haut de la page du projet → *Project URL* et clé *publishable*.

**Quelles clés sont sans danger ?**

| Valeur | Dans le site / GitHub ? |
|---|---|
| Adresse du projet `https://xxxx.supabase.co` | ✅ oui, publique |
| Clé `sb_publishable_…` (ex-« anon ») | ✅ oui, faite pour le navigateur |
| Clé `sb_secret_…` (ex-« service_role ») | ⛔ **jamais** |
| Mot de passe de la base de données | ⛔ **jamais** |
| Adresses de webhooks Discord | ⛔ jamais dans le code : elles se saisissent dans le tableau de bord et restent côté serveur |

Le fichier `.env.example` rappelle ces règles. Le site étant statique, il n'y a pas de vrai fichier `.env` à envoyer.

### Étape 6 — Mettre le site sur GitHub

**Méthode simple (sans ligne de commande)**
1. Créez un compte sur [github.com](https://github.com), puis **New repository** (nom au choix, ex. `fourriere`, visibilité *Public*).
2. Sur la page du dépôt : **uploading an existing file**.
3. Décompressez le ZIP, ouvrez le dossier, sélectionnez **tout son contenu** (`index.html`, `assets`, `js`, `supabase`…) et glissez-le dans la page GitHub.
4. Cliquez sur **Commit changes**.

**Méthode avec Git**
```bash
cd fourriere-belle-roche
git init && git add . && git commit -m "Site de la fourrière"
git branch -M main
git remote add origin https://github.com/VOTRE_COMPTE/VOTRE_DEPOT.git
git push -u origin main
```

### Étape 7 — Activer GitHub Pages

1. Dans le dépôt : **Settings → Pages**.
2. *Build and deployment* → **Source : Deploy from a branch** → branche **main**, dossier **/ (root)** → **Save**.
3. Après 1 à 2 minutes, l'adresse du site s'affiche : `https://VOTRE_COMPTE.github.io/VOTRE_DEPOT/`.

### Étape 8 — Tester

1. Ouvrez le site → **Connexion** → nom `Muller`, prénom `Gabin`, votre mot de passe.
2. **Espace personnel → Véhicules → Ajouter un véhicule** (au moins une photo).
3. Ouvrez le site dans une fenêtre privée, créez un compte client, cliquez sur **« C'est ma voiture »** : la conversation apparaît dans **Messages** côté employé.
4. **Espace personnel → Personnel** : créez un employé et un gérant.

> Recommandé : dans Supabase → **Authentication → Sign In / Providers**, si l'option « Allow new users to sign up » existe, désactivez-la. Le site crée lui-même les comptes ; cela empêche seulement les inscriptions « sauvages » par l'API d'authentification.

---

### Mettre à jour une installation existante

Quand une nouvelle version du site est livrée (par exemple avec les codes promo) :
1. **Supabase → SQL Editor** : collez le nouveau `supabase/install_all.sql` et cliquez sur **Run**. Vos comptes, véhicules, conversations, photos, tarifs et webhooks Discord sont **conservés** (le script ne fait qu'ajouter et remplacer les fonctions).
2. **GitHub** : remplacez les fichiers du dépôt par ceux du nouveau ZIP (même méthode qu'à l'étape 6, en acceptant d'écraser les fichiers existants).
3. Actualisez le site (Ctrl + F5).

---

## 4. Discord

Bouton **Discord** en haut à droite du site (lien : `https://discord.gg/3bJfngda2G`, modifiable dans `js/config.js`).

**Espace personnel → Discord** (gérants) permet de relier trois salons avec des webhooks :

| Webhook | Ce qu'il fait |
|---|---|
| **Véhicules en fourrière** | Un message par véhicule (photo, plaque, modèle, couleur, arrivée, tarif). Le message est **supprimé automatiquement** dès que le véhicule est réclamé, récupéré ou supprimé, et republié si la demande est annulée. |
| **Véhicules à vendre** | Un message par annonce, **supprimé automatiquement** à la vente ou au retrait. |
| **Notifications du personnel** | Nouveaux messages des clients et réponses, nouvelles demandes, intérêts pour un achat, véhicules à mettre en vente, actions importantes. **Réservé à l'équipe** : les clients ne reçoivent jamais de notification Discord. Catégories activables une à une, mention d'un rôle possible. |

**Créer un webhook** : Discord → paramètres du salon → **Intégrations → Webhooks → Nouveau webhook → Copier l'URL** → la coller dans le bon cadre du tableau de bord → *Enregistrer* → *Envoyer un test*.

Bon à savoir :
- L'adresse d'un webhook est stockée **côté serveur** ; elle n'est jamais renvoyée au navigateur.
- Les appels vers Discord sont faits par la base (`pg_net`), avec file d'attente, nouvelles tentatives en cas de limite de débit, et un panneau de suivi (erreurs visibles).
- Le contenu des messages de chat est transmis à Discord pour les notifications du personnel : réservez ce salon à l'équipe.
- Une personne qui écrit `@everyone` dans un chat ne peut déclencher aucune mention : le texte du client reste dans un encadré qui ne notifie personne.

---

## 5. Structure du projet

```
index.html               Page unique (le site change de « page » grâce au # dans l'adresse)
404.html                 Redirection vers l'accueil
js/
  config.js              ← À MODIFIER : adresse Supabase, clé publique, nom du site, lien Discord
  main.js                Démarrage, en-tête, notifications, routes
  lib/                   api.js (accès Supabase), router.js, ui.js, cartes, formats, photos…
  pages/                 Une page = un fichier (home, lists, auth, messages, admin*.js, admin-codes.js…)
assets/
  css/                   base.css (composants), app.css (pages)
  img/                   Logo et icônes
  fonts/  vendor/        Polices, supabase-js, Chart.js (tout est local)
supabase/
  install_all.sql        ← À coller dans le SQL Editor (étape 1)
  create_admin.sql       Création de Gabin Muller (étape 2)
  cron_recommended.sql   Tâche automatique (étape 3)
  parts/                 Les parties SQL qui composent install_all.sql (lecture / maintenance)
scripts/build-sql.sh     Régénère install_all.sql à partir de parts/
.env.example             Rappel des valeurs et de leur niveau de confidentialité
```

Les scripts SQL, dans l'ordre : `01` tables · `02` comptes, personnel, triggers · `03` véhicules, demandes, conversations, ventes, statistiques · `04` codes promo · `05` Discord · `06` sécurité (RLS, droits) · `07` stockage et temps réel.

---

## 6. Sécurité en bref

- **Mots de passe** hachés en bcrypt dans la base ; jamais visibles, jamais stockés en clair, jamais dans le code.
- **Aucune écriture directe** depuis le navigateur, hormis l'envoi d'un message : tout passe par des fonctions SQL qui vérifient le rôle. L'auteur, le rôle et l'heure d'un message, la date et l'auteur d'un véhicule, les jours et les montants sont **imposés par le serveur**.
- **RLS activée** sur toutes les tables ; un client ne voit que ses propres conversations ; les véhicules « en attente de vente » sont invisibles hors gérants / admin.
- **Gabin Muller** : identité réservée, création possible uniquement depuis le SQL Editor, non supprimable, non modifiable, non licenciable.
- **Codes promo** : les tables de codes ne sont lisibles par personne depuis le navigateur (accès uniquement par des fonctions vérifiant le rôle). Un client ne peut ni créer un code, ni modifier sa réduction, ni appliquer un code sur la conversation d'un autre. Anti-devinette : 8 essais ratés en 10 minutes bloquent la saisie. Un code abandonné (conversation fermée sans récupération ni vente) est rendu disponible.
- Le texte saisi (modèles, messages…) est toujours affiché comme **du texte**, jamais comme du HTML.
- Une politique de sécurité de contenu (CSP) limite le site à ses propres fichiers et à Supabase.

---

## 7. Dépannage

| Symptôme | À vérifier |
|---|---|
| « Configuration requise » à l'ouverture | `js/config.js` : adresse et clé Supabase renseignées, sans espace. |
| Connexion impossible | Nom / prénom exacts (accents et majuscules sans importance). Le compte Gabin n'existe qu'après l'étape 2. |
| Erreur « function … does not exist » | Le script `install_all.sql` n'a pas été exécuté en entier (étape 1). |
| Les photos ne s'envoient pas | Le bucket `vehicle-photos` est créé par le script ; vérifiez Storage. Photos JPEG / PNG / WebP uniquement. |
| Rien n'arrive sur Discord | *Espace personnel → Discord* : panneau « Synchronisation » (erreurs). Vérifiez que `pg_net` est activé et que l'adresse du webhook est valide. |
| Le message Discord ne disparaît pas tout de suite | Sans `pg_cron`, la suppression est traitée à la prochaine action ou visite ; activez l'étape 3. |
| Un code promo est refusé | Message affiché dans la fenêtre : code inconnu, désactivé, expiré, épuisé, réservé à la fourrière ou à la vente, ou déjà utilisé avec ce compte. *Espace personnel → Codes promo → Utilisations* montre qui l'a utilisé. |
| Le chat met quelques secondes à se mettre à jour | Le temps réel Supabase est utilisé ; à défaut le site interroge la base toutes les 5 secondes. |

**Changer le nom du site** : `SITE_NAME` dans `js/config.js` (et le texte du logo si besoin). **Changer les tarifs / le délai de 7 jours** : *Espace personnel → Tarifs*.
