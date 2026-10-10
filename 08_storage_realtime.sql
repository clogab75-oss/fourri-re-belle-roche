-- =====================================================================
--  FOURRIÈRE DE BELLE ROCHE — Base de données
--  Fichier 8/8 : stockage des photos et temps réel
-- =====================================================================

-- Bucket public (lecture des photos par tous), écriture réservée au personnel
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('vehicle-photos', 'vehicle-photos', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists vehicle_photos_staff_insert on storage.objects;
create policy vehicle_photos_staff_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'vehicle-photos' and private.is_staff());

drop policy if exists vehicle_photos_staff_select on storage.objects;
create policy vehicle_photos_staff_select on storage.objects for select to authenticated
  using (bucket_id = 'vehicle-photos' and private.is_staff());

drop policy if exists vehicle_photos_staff_delete on storage.objects;
create policy vehicle_photos_staff_delete on storage.objects for delete to authenticated
  using (bucket_id = 'vehicle-photos' and private.is_staff());

-- Temps réel (Supabase Realtime) : les règles RLS s'appliquent aussi aux abonnements
do $$
declare t text;
begin
  foreach t in array array['messages', 'conversations', 'notifications', 'vehicles', 'claims',
                           'vehicle_sales', 'profiles', 'staff'] loop
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
