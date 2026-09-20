-- =====================================================================
--  TÂCHE AUTOMATIQUE (recommandée) : toutes les minutes, la base
--    • passe en « attente de mise en vente » les véhicules arrivés à 7 jours ;
--    • envoie/supprime les messages Discord en attente.
--
--  Avant de lancer ce script : Supabase > Database > Extensions > activer « pg_cron ».
--  Sans pg_cron, le site déclenche ces contrôles tout seul quand quelqu'un le visite.
-- =====================================================================
create extension if not exists pg_cron;

do $$
begin
  perform cron.unschedule(jobid) from cron.job where jobname = 'belle-roche-auto';
end $$;

select cron.schedule('belle-roche-auto', '* * * * *', $job$select public.process_auto_sale();$job$);
