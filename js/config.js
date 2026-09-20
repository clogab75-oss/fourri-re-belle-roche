/* =====================================================================
   CONFIGURATION DU SITE
   Ces valeurs sont PUBLIQUES par conception : elles se retrouvent dans le
   navigateur de tous les visiteurs. La sécurité vient des règles (RLS) de
   la base Supabase, pas du secret de ces valeurs.

   ⚠ Ne mettez JAMAIS ici une clé qui commence par « sb_secret_ » ou
     « service_role » : elle donnerait un accès total à la base.
   ===================================================================== */
window.BELLE_ROCHE_CONFIG = {
  // Adresse du projet Supabase (Connect > Project URL)
  SUPABASE_URL: 'https://hwsazkujhryierwtnzbu.supabase.co',

  // Clé « publishable » (Project Settings > API Keys) : utilisable côté navigateur
  SUPABASE_KEY: 'sb_publishable_TfnZSurYzzomdzCnrPSC6w_Np5SoofW',

  // Nom affiché sur le site (titres, pied de page)
  SITE_NAME: 'Fourrière de Belle Roche',

  // Invitation du serveur Discord (bouton en haut à droite)
  DISCORD_INVITE: 'https://discord.gg/3bJfngda2G',

  // Nom du bucket de photos (créé par le script SQL 06)
  PHOTO_BUCKET: 'vehicle-photos'
};
