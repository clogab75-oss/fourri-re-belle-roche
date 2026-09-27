#!/bin/sh
# Assemble les scripts SQL 01 à 06 en un seul fichier : supabase/install_all.sql
cd "$(dirname "$0")/../supabase" || exit 1
{
  echo "-- ====================================================================="
  echo "--  FOURRIÈRE DE BELLE ROCHE — INSTALLATION COMPLÈTE DE LA BASE"
  echo "--  À coller en une seule fois dans Supabase > SQL Editor > New query > Run."
  echo "--  (Contenu = les fichiers du dossier parts/ mis bout à bout.)"
  echo "-- ====================================================================="
  echo
  for f in 01_tables 02_functions_core 03_functions_app 04_promo_codes 05_discord 06_security 07_storage_realtime; do
    echo "-- >>>>>>>>>> parts/$f.sql"
    cat "parts/$f.sql"
    echo
  done
  echo "-- Recharge le cache de l'API pour qu'elle voie les nouvelles fonctions"
  echo "notify pgrst, 'reload schema';"
} > install_all.sql
echo "install_all.sql : $(wc -c < install_all.sql) octets"
