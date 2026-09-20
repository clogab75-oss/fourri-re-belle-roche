-- =====================================================================
--  FOURRIÈRE DE BELLE ROCHE — Base de données
--  Fichier 4/6 : intégration Discord (webhooks)
--
--  • Catalogue "En fourrière" et catalogue "À vendre" : un message par
--    véhicule, SUPPRIMÉ AUTOMATIQUEMENT dès que le véhicule n'est plus
--    dans la catégorie (réclamé, récupéré, vendu, etc.).
--  • Notifications du personnel : nouveaux messages, demandes, etc.
--    (uniquement pour les employés, jamais pour les clients).
--
--  Les URL de webhook sont stockées dans le schéma "private" : elles ne
--  sont jamais renvoyées au navigateur. Les appels vers Discord sont faits
--  par la base (extension pg_net), de manière asynchrone, avec file
--  d'attente et nouvelles tentatives.
-- =====================================================================

do $$
begin
  begin
    create extension if not exists pg_net with schema extensions;
  exception when others then
    begin
      create extension if not exists pg_net;
    exception when others then
      raise notice 'pg_net n''a pas pu être activé automatiquement (%). Activez-le dans Database > Extensions.', sqlerrm;
    end;
  end;
end $$;

-- ---------------------------------------------------------------------
--  Tables (schéma private : invisibles depuis l'API)
-- ---------------------------------------------------------------------
create table if not exists private.discord_settings (
  id             smallint primary key default 1 check (id = 1),
  site_name      text not null default 'Fourrière de Belle Roche',
  site_url       text,
  storage_url    text,
  impound_url    text,
  impound_enabled boolean not null default true,
  sale_url       text,
  sale_enabled   boolean not null default true,
  staff_url      text,
  staff_enabled  boolean not null default true,
  staff_events   jsonb not null default
    '{"messages_client":true,"messages_staff":true,"claims":true,"vehicles":true,"sales":true,"staff":true,"other":true}',
  mention        text,
  updated_at     timestamptz not null default now(),
  updated_by_name text
);
insert into private.discord_settings (id) values (1) on conflict (id) do nothing;

create table if not exists private.discord_messages (
  id               uuid primary key default gen_random_uuid(),
  vehicle_id       uuid not null,      -- sans clé étrangère : on doit pouvoir supprimer le message d'un véhicule supprimé
  kind             text not null check (kind in ('impound', 'sale')),
  message_id       text,
  state            text not null default 'queued'
                   check (state in ('queued', 'posting', 'posted', 'deleting', 'deleted', 'cancelled', 'failed')),
  delete_requested boolean not null default false,
  last_error       text,
  created_at       timestamptz not null default now(),
  posted_at        timestamptz,
  deleted_at       timestamptz
);
create index if not exists discord_messages_vehicle_idx on private.discord_messages (vehicle_id, kind);
create index if not exists discord_messages_state_idx on private.discord_messages (state);

create table if not exists private.discord_outbox (
  id                 bigint generated always as identity primary key,
  slot               text not null check (slot in ('impound', 'sale', 'staff')),
  op                 text not null check (op in ('post', 'delete', 'notify', 'test')),
  message_ref        uuid references private.discord_messages (id) on delete set null,
  discord_message_id text,
  payload            jsonb,
  state              text not null default 'queued' check (state in ('queued', 'sent', 'done', 'failed', 'cancelled')),
  request_id         bigint,
  attempts           integer not null default 0,
  next_attempt_at    timestamptz not null default now(),
  sent_at            timestamptz,
  finished_at        timestamptz,
  last_error         text,
  created_at         timestamptz not null default now()
);
create index if not exists discord_outbox_state_idx on private.discord_outbox (state, next_attempt_at);

alter table private.discord_settings enable row level security;
alter table private.discord_messages enable row level security;
alter table private.discord_outbox enable row level security;

-- ---------------------------------------------------------------------
--  Validation des saisies (protège contre les URL arbitraires)
-- ---------------------------------------------------------------------
create or replace function private.discord_clean_url(p text) returns text
language plpgsql immutable set search_path = '' as $$
declare v text := btrim(coalesce(p, ''));
begin
  if v = '' then return null; end if;
  if v !~ '^https://(canary\.|ptb\.)?discord(app)?\.com/api(/v[0-9]+)?/webhooks/[0-9]{15,25}/[A-Za-z0-9._-]{20,120}$' then
    raise exception 'URL de webhook Discord invalide. Elle doit ressembler à https://discord.com/api/webhooks/123456789012345678/abcdef…';
  end if;
  return v;
end $$;

-- ---------------------------------------------------------------------
--  Envoi : construit et poste les messages, supprime les anciens
-- ---------------------------------------------------------------------
create or replace function private.discord_eligible(p_vehicle uuid, p_kind text) returns boolean
language sql stable security definer set search_path = public, private as $$
  select exists (select 1 from public.vehicles v
                  where v.id = p_vehicle
                    and ((p_kind = 'impound' and v.status = 'en_fourriere')
                      or (p_kind = 'sale' and v.status = 'a_vendre')));
$$;

-- Prépare le retrait d'un message du catalogue
create or replace function private.discord_retire(p_msg uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare m private.discord_messages;
begin
  select * into m from private.discord_messages where id = p_msg for update;
  if not found then return; end if;
  if m.state = 'queued' then
    update private.discord_messages set state = 'cancelled' where id = m.id;
    update private.discord_outbox set state = 'cancelled', finished_at = now()
     where message_ref = m.id and op = 'post' and state = 'queued';
  elsif m.state = 'posting' then
    update private.discord_messages set delete_requested = true where id = m.id;
  elsif m.state = 'posted' then
    if m.message_id is null then
      update private.discord_messages set state = 'deleted', deleted_at = now() where id = m.id;
    else
      update private.discord_messages set state = 'deleting' where id = m.id;
      insert into private.discord_outbox (slot, op, message_ref, discord_message_id)
      values (m.kind, 'delete', m.id, m.message_id);
    end if;
  end if;
end $$;

-- Compare l'état du véhicule et les messages Discord, puis corrige.
create or replace function private.discord_sync_vehicle(p_vehicle uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare
  s private.discord_settings; k text; v_elig boolean; m private.discord_messages; v_ref uuid;
begin
  select * into s from private.discord_settings where id = 1;
  if not found then return; end if;
  foreach k in array array['impound', 'sale'] loop
    v_elig := private.discord_eligible(p_vehicle, k);
    select * into m from private.discord_messages
     where vehicle_id = p_vehicle and kind = k and state in ('queued', 'posting', 'posted')
     order by created_at desc limit 1;
    if v_elig and not found then
      if (k = 'impound' and s.impound_enabled and s.impound_url is not null)
         or (k = 'sale' and s.sale_enabled and s.sale_url is not null) then
        insert into private.discord_messages (vehicle_id, kind) values (p_vehicle, k) returning id into v_ref;
        insert into private.discord_outbox (slot, op, message_ref) values (k, 'post', v_ref);
      end if;
    elsif (not v_elig) and found then
      perform private.discord_retire(m.id);
    end if;
  end loop;
end $$;

-- Remplace le message publié (le véhicule a été modifié : photo, modèle, prix…)
create or replace function private.discord_repost(p_vehicle uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare s private.discord_settings; k text; m private.discord_messages; v_ref uuid;
begin
  select * into s from private.discord_settings where id = 1;
  if not found then return; end if;
  foreach k in array array['impound', 'sale'] loop
    select * into m from private.discord_messages
     where vehicle_id = p_vehicle and kind = k and state in ('queued', 'posting', 'posted')
     order by created_at desc limit 1;
    if found and m.state = 'posted' and private.discord_eligible(p_vehicle, k) then
      perform private.discord_retire(m.id);
      if (k = 'impound' and s.impound_enabled and s.impound_url is not null)
         or (k = 'sale' and s.sale_enabled and s.sale_url is not null) then
        insert into private.discord_messages (vehicle_id, kind) values (p_vehicle, k) returning id into v_ref;
        insert into private.discord_outbox (slot, op, message_ref) values (k, 'post', v_ref);
      end if;
    end if;
  end loop;
end $$;

create or replace function private.discord_vehicle_payload(p_vehicle uuid, p_kind text) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare
  s private.discord_settings; v public.vehicles; sale public.vehicle_sales;
  v_photo text; v_embed jsonb; v_ts text;
begin
  select * into s from private.discord_settings where id = 1;
  select * into v from public.vehicles where id = p_vehicle;
  if not found then return null; end if;
  select storage_path into v_photo from public.vehicle_photos
   where vehicle_id = p_vehicle order by position, created_at limit 1;
  v_ts := extract(epoch from v.created_at)::bigint::text;

  if p_kind = 'impound' then
    v_embed := jsonb_build_object(
      'title', left('🚗 ' || v.model || ' — ' || v.plate, 250),
      'description', 'Véhicule en fourrière. Si c''est le vôtre, cliquez sur **« C''est ma voiture »** sur le site.',
      'color', x'1F5FBF'::int,
      'url', case when s.site_url is not null then s.site_url || '#/vehicules' end,
      'fields', jsonb_build_array(
        jsonb_build_object('name', 'Plaque', 'value', '`' || replace(v.plate, '`', '') || '`', 'inline', true),
        jsonb_build_object('name', 'Modèle', 'value', left(v.model, 200), 'inline', true),
        jsonb_build_object('name', 'Couleur', 'value', left(v.color, 200), 'inline', true),
        jsonb_build_object('name', 'Arrivée', 'value', '<t:' || v_ts || ':f>', 'inline', true),
        jsonb_build_object('name', 'En fourrière', 'value', '<t:' || v_ts || ':R>', 'inline', true),
        jsonb_build_object('name', 'Tarif (RP)', 'value',
          private.fmt_money(v.handling_fee) || ' + ' || private.fmt_money(v.daily_rate) || ' / jour', 'inline', true)),
      'footer', jsonb_build_object('text', 'Le message disparaît quand le véhicule quitte la fourrière'));
  else
    select * into sale from public.vehicle_sales where vehicle_id = p_vehicle and status = 'a_vendre';
    if not found then return null; end if;
    v_embed := jsonb_build_object(
      'title', left('🏷️ ' || v.model || ' — ' || private.fmt_money(sale.price), 250),
      'description', left(sale.description, 1800),
      'color', x'1E8E5A'::int,
      'url', case when s.site_url is not null then s.site_url || '#/vente' end,
      'fields', jsonb_build_array(
        jsonb_build_object('name', 'Prix (RP)', 'value', private.fmt_money(sale.price), 'inline', true),
        jsonb_build_object('name', 'Modèle', 'value', left(v.model, 200), 'inline', true),
        jsonb_build_object('name', 'Couleur', 'value', left(v.color, 200), 'inline', true)),
      'footer', jsonb_build_object('text', 'Cliquez sur « Je suis intéressé » sur le site · le message disparaît une fois vendu'));
  end if;
  if v_photo is not null and s.storage_url is not null then
    v_embed := v_embed || jsonb_build_object('image', jsonb_build_object('url', s.storage_url || v_photo));
  end if;
  return jsonb_build_object('username', left(s.site_name, 80),
    'allowed_mentions', jsonb_build_object('parse', '[]'::jsonb),
    'embeds', jsonb_build_array(jsonb_strip_nulls(v_embed)));
end $$;

-- ---------------------------------------------------------------------
--  Le "travailleur" : envoie les messages en attente et traite les réponses
-- ---------------------------------------------------------------------
create or replace function private.discord_worker(p_max integer default 4) returns integer
language plpgsql security definer set search_path = public, private as $$
declare
  s private.discord_settings; j private.discord_outbox; m private.discord_messages; resp record;
  v_sent integer := 0; v_url text; v_payload jsonb; v_req bigint; v_mid text; v_retry numeric; v_err text;
begin
  if to_regclass('net._http_response') is null then return 0; end if;
  select * into s from private.discord_settings where id = 1;
  if not found then return 0; end if;

  -- 1) Traiter les réponses de Discord pour les requêtes déjà envoyées
  for j in select * from private.discord_outbox where state = 'sent' order by id limit 50 for update skip locked loop
    select status_code, content into resp from net._http_response where id = j.request_id;
    if not found then
      if j.sent_at < now() - interval '3 minutes' then
        update private.discord_outbox
           set state = 'queued', next_attempt_at = now(), last_error = 'Aucune réponse de Discord'
         where id = j.id;
        if j.op = 'post' then
          update private.discord_messages set state = 'queued' where id = j.message_ref and state = 'posting';
        end if;
      end if;
      continue;
    end if;

    if (resp.status_code between 200 and 299) or (j.op = 'delete' and resp.status_code = 404) then
      update private.discord_outbox set state = 'done', finished_at = now(), last_error = null where id = j.id;
      if j.op = 'post' and j.message_ref is not null then
        v_mid := null;
        begin v_mid := (resp.content::jsonb) ->> 'id'; exception when others then v_mid := null; end;
        select * into m from private.discord_messages where id = j.message_ref for update;
        if found then
          if m.delete_requested and v_mid is not null then
            update private.discord_messages set state = 'deleting', message_id = v_mid, posted_at = now() where id = m.id;
            insert into private.discord_outbox (slot, op, message_ref, discord_message_id)
            values (m.kind, 'delete', m.id, v_mid);
          elsif m.delete_requested then
            update private.discord_messages
               set state = 'deleted', deleted_at = now(), last_error = 'ID de message inconnu : suppression impossible'
             where id = m.id;
          else
            update private.discord_messages
               set state = 'posted', message_id = v_mid, posted_at = now(),
                   last_error = case when v_mid is null then 'ID de message inconnu' end
             where id = m.id;
          end if;
        end if;
      elsif j.op = 'delete' and j.message_ref is not null then
        update private.discord_messages set state = 'deleted', deleted_at = now() where id = j.message_ref;
      end if;

    elsif resp.status_code is null or resp.status_code = 429 or resp.status_code >= 500 then
      v_retry := 5;
      if resp.status_code = 429 then
        begin v_retry := coalesce(((resp.content::jsonb) ->> 'retry_after')::numeric, 5); exception when others then v_retry := 5; end;
      end if;
      if j.attempts >= 5 then
        update private.discord_outbox
           set state = 'failed', finished_at = now(),
               last_error = 'Discord indisponible ou débit dépassé (code ' || coalesce(resp.status_code::text, 'délai dépassé') || ')'
         where id = j.id;
        update private.discord_messages set state = 'failed', last_error = 'Échec d''envoi vers Discord' where id = j.message_ref;
      else
        select * into m from private.discord_messages where id = j.message_ref;
        if j.op = 'post' and found and m.delete_requested then
          update private.discord_outbox set state = 'cancelled', finished_at = now() where id = j.id;
          update private.discord_messages set state = 'cancelled' where id = m.id;
        else
          update private.discord_outbox
             set state = 'queued', next_attempt_at = now() + make_interval(secs => greatest(v_retry, 1) + j.attempts * 10),
                 last_error = 'Nouvelle tentative (code ' || coalesce(resp.status_code::text, 'délai dépassé') || ')'
           where id = j.id;
          if j.op = 'post' then
            update private.discord_messages set state = 'queued' where id = j.message_ref and state = 'posting';
          end if;
        end if;
      end if;

    else
      v_err := 'Discord a refusé la requête (code ' || resp.status_code || ') : ' || left(coalesce(resp.content, ''), 200);
      update private.discord_outbox set state = 'failed', finished_at = now(), last_error = v_err where id = j.id;
      if j.message_ref is not null then
        update private.discord_messages set state = 'failed', last_error = v_err where id = j.message_ref;
      end if;
    end if;
  end loop;

  -- 2) Envoyer les requêtes prêtes
  for j in select * from private.discord_outbox
            where state = 'queued' and next_attempt_at <= now()
            order by id limit p_max for update skip locked loop
    v_url := case j.slot when 'impound' then s.impound_url when 'sale' then s.sale_url else s.staff_url end;
    if v_url is null then
      update private.discord_outbox set state = 'failed', finished_at = now(), last_error = 'Webhook non configuré' where id = j.id;
      if j.message_ref is not null then
        update private.discord_messages set state = 'failed', last_error = 'Webhook non configuré' where id = j.message_ref;
      end if;
      continue;
    end if;
    begin
      if j.op = 'post' then
        select * into m from private.discord_messages where id = j.message_ref;
        if not found or m.state <> 'queued' or not private.discord_eligible(m.vehicle_id, m.kind) then
          update private.discord_outbox set state = 'cancelled', finished_at = now() where id = j.id;
          if found and m.state = 'queued' then
            update private.discord_messages set state = 'cancelled' where id = m.id;
          end if;
          continue;
        end if;
        v_payload := private.discord_vehicle_payload(m.vehicle_id, m.kind);
        if v_payload is null then
          update private.discord_outbox set state = 'cancelled', finished_at = now() where id = j.id;
          update private.discord_messages set state = 'cancelled' where id = m.id;
          continue;
        end if;
        v_req := net.http_post(url := v_url || '?wait=true', body := v_payload);
        update private.discord_messages set state = 'posting' where id = m.id;
      elsif j.op = 'delete' then
        v_req := net.http_delete(url := v_url || '/messages/' || j.discord_message_id);
      else
        v_req := net.http_post(url := v_url, body := j.payload);
      end if;
      update private.discord_outbox
         set state = 'sent', request_id = v_req, sent_at = now(), attempts = attempts + 1
       where id = j.id;
      v_sent := v_sent + 1;
    exception when others then
      update private.discord_outbox set state = 'failed', finished_at = now(), last_error = left(sqlerrm, 300) where id = j.id;
      if j.message_ref is not null then
        update private.discord_messages set state = 'failed', last_error = left(sqlerrm, 300) where id = j.message_ref;
      end if;
    end;
  end loop;

  -- 3) Ménage
  delete from private.discord_outbox where state in ('done', 'cancelled', 'failed') and finished_at < now() - interval '3 days';
  delete from private.discord_messages
   where state in ('deleted', 'cancelled', 'failed') and coalesce(deleted_at, created_at) < now() - interval '3 days';
  return v_sent;
end $$;

-- Envoi immédiat à la fin de la transaction (les données sont alors complètes : photos comprises)
create or replace function private.discord_kick() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  begin
    perform private.discord_worker(4);
  exception when others then null;
  end;
  return null;
end $$;

drop trigger if exists discord_outbox_kick on private.discord_outbox;
create constraint trigger discord_outbox_kick
  after insert on private.discord_outbox
  deferrable initially deferred
  for each row execute function private.discord_kick();

-- ---------------------------------------------------------------------
--  Notifications du personnel (jamais envoyées aux clients)
-- ---------------------------------------------------------------------
create or replace function private.discord_enqueue_staff(
  p_group text, p_title text, p_description text, p_fields jsonb, p_color integer,
  p_link text, p_ping boolean, p_footer text, p_vehicle uuid default null)
returns void
language plpgsql security definer set search_path = public, private as $$
declare s private.discord_settings; v_embed jsonb; v_payload jsonb; v_photo text; v_ping boolean;
begin
  select * into s from private.discord_settings where id = 1;
  if not found or not s.staff_enabled or s.staff_url is null then return; end if;
  if coalesce((s.staff_events ->> p_group)::boolean, true) is not true then return; end if;
  v_ping := p_ping and coalesce(s.mention, '') <> '';
  if p_vehicle is not null and s.storage_url is not null then
    select storage_path into v_photo from public.vehicle_photos
     where vehicle_id = p_vehicle order by position, created_at limit 1;
  end if;
  v_embed := jsonb_strip_nulls(jsonb_build_object(
    'title', left(p_title, 250),
    'description', nullif(left(coalesce(p_description, ''), 1800), ''),
    'color', p_color,
    'url', case when s.site_url is not null and p_link is not null then s.site_url || p_link end,
    'fields', case when p_fields is not null and jsonb_array_length(p_fields) > 0 then p_fields end,
    'thumbnail', case when v_photo is not null then jsonb_build_object('url', s.storage_url || v_photo) end,
    'footer', jsonb_build_object('text', left(coalesce(nullif(p_footer, ''), s.site_name), 200)),
    'timestamp', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')));
  v_payload := jsonb_build_object(
    'username', left(s.site_name, 80),
    'allowed_mentions', case when v_ping then jsonb_build_object('parse', jsonb_build_array('roles', 'users'))
                             else jsonb_build_object('parse', '[]'::jsonb) end,
    'embeds', jsonb_build_array(v_embed));
  if v_ping then v_payload := v_payload || jsonb_build_object('content', s.mention); end if;
  insert into private.discord_outbox (slot, op, payload) values ('staff', 'notify', v_payload);
end $$;

-- Chaque action de l'historique alimente le salon du personnel
create or replace function private.discord_on_log() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v_group text; v_title text; v_color integer; v_link text; v_conv uuid; v_role text;
begin
  begin
    v_group := case
      when new.action like 'claim.%' or new.action like 'interest.%' then 'claims'
      when new.action like 'vehicle.%' then 'vehicles'
      when new.action like 'sale.%' then 'sales'
      when new.action like 'staff.%' then 'staff'
      else 'other' end;
    v_title := case new.action
      when 'vehicle.create' then '🚗 Nouveau véhicule en fourrière'
      when 'vehicle.update' then '✏️ Véhicule modifié'
      when 'vehicle.delete' then '🗑️ Véhicule supprimé'
      when 'vehicle.photos' then '🖼️ Photos modifiées'
      when 'vehicle.recovered' then '✅ Véhicule récupéré'
      when 'vehicle.auto_sale' then '⏰ Véhicule à mettre en vente'
      when 'vehicle.archive' then '📦 Véhicule archivé'
      when 'vehicle.unarchive' then '📤 Véhicule désarchivé'
      when 'claim.create' then '🙋 Nouvelle demande de récupération'
      when 'interest.create' then '🏷️ Intérêt pour un véhicule à vendre'
      when 'conversation.close' then '🔒 Conversation fermée'
      when 'conversation.delete' then '🗑️ Conversation supprimée'
      when 'sale.list' then '🏷️ Véhicule mis en vente'
      when 'sale.update' then '✏️ Annonce modifiée'
      when 'sale.withdraw' then '↩️ Véhicule retiré de la vente'
      when 'sale.sold' then '💶 Véhicule vendu'
      when 'staff.create' then '👥 Nouveau compte du personnel'
      when 'staff.recruit' then '👥 Nouveau membre du personnel'
      when 'staff.fire' then '🚪 Membre du personnel viré'
      when 'staff.role' then '🔧 Rôle modifié'
      when 'staff.reset_password' then '🔑 Mot de passe réinitialisé'
      when 'pricing.update' then '💰 Tarifs modifiés'
      when 'discord.settings' then '⚙️ Paramètres Discord modifiés'
      else '📋 ' || new.action end;
    v_color := case v_group
      when 'claims' then x'F5B400'::int when 'vehicles' then x'1F5FBF'::int
      when 'sales' then x'1E8E5A'::int when 'staff' then x'7A5CD6'::int else x'6B7785'::int end;
    if new.action = 'claim.create' then
      select id into v_conv from public.conversations where claim_id = new.entity_id;
    end if;
    v_link := case
      when v_conv is not null then '#/messages/' || v_conv
      when new.entity_type = 'conversation' and new.entity_id is not null then '#/messages/' || new.entity_id
      when new.vehicle_id is not null and new.action not like 'vehicle.delete' then '#/admin/vehicules/' || new.vehicle_id
      when new.action like 'staff.%' then '#/admin/personnel'
      when new.action like 'pricing.%' then '#/admin/tarifs'
      else null end;
    v_role := case new.actor_role when 'client' then 'client' when 'employe' then 'employé'
              when 'gerant' then 'gérant' when 'admin' then 'administrateur' else 'système' end;
    perform private.discord_enqueue_staff(
      v_group, v_title, new.summary, null, v_color, v_link,
      new.action in ('claim.create', 'interest.create', 'vehicle.auto_sale'),
      new.actor_name || ' (' || v_role || ')',
      case when new.action = 'vehicle.delete' then null else new.vehicle_id end);
  exception when others then null;
  end;
  return null;
end $$;

drop trigger if exists discord_log_trg on public.activity_logs;
create trigger discord_log_trg after insert on public.activity_logs
  for each row execute function private.discord_on_log();

-- Chaque message d'une conversation alimente le salon du personnel
create or replace function private.discord_on_message() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v_c public.conversations; v_v public.vehicles; v_client boolean; v_role text;
begin
  begin
    select * into v_c from public.conversations where id = new.conversation_id;
    select * into v_v from public.vehicles where id = v_c.vehicle_id;
    v_client := new.sender_role = 'client';
    v_role := case new.sender_role when 'client' then 'client' when 'employe' then 'employé'
              when 'gerant' then 'gérant' else 'administrateur' end;
    perform private.discord_enqueue_staff(
      case when v_client then 'messages_client' else 'messages_staff' end,
      case when v_client then '💬 Message de ' || new.sender_name else '↩️ Réponse de ' || new.sender_name end,
      new.content,
      jsonb_build_array(
        jsonb_build_object('name', 'Véhicule', 'value', left(coalesce(v_v.plate || ' · ' || v_v.model, 'Inconnu'), 200), 'inline', true),
        jsonb_build_object('name', 'Type', 'value', case v_c.type when 'claim' then 'Récupération' else 'Achat' end, 'inline', true),
        jsonb_build_object('name', 'Client', 'value', left(v_c.client_name, 200), 'inline', true)),
      case when v_client then x'F5B400'::int else x'6B7785'::int end,
      '#/messages/' || new.conversation_id, v_client,
      new.sender_name || ' (' || v_role || ')', null);
  exception when others then null;
  end;
  return null;
end $$;

drop trigger if exists discord_message_trg on public.messages;
create trigger discord_message_trg after insert on public.messages
  for each row when (new.kind = 'text')
  execute function private.discord_on_message();

-- ---------------------------------------------------------------------
--  Déclencheurs : le catalogue se met à jour tout seul
-- ---------------------------------------------------------------------
create or replace function private.discord_on_vehicle() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  begin
    if tg_op = 'DELETE' then
      perform private.discord_sync_vehicle(old.id);
    else
      perform private.discord_sync_vehicle(new.id);
    end if;
  exception when others then null;
  end;
  return null;
end $$;

drop trigger if exists discord_vehicle_trg on public.vehicles;
create trigger discord_vehicle_trg after insert or delete or update of status on public.vehicles
  for each row execute function private.discord_on_vehicle();

create or replace function private.discord_on_vehicle_edit() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  begin
    perform private.discord_repost(new.id);
  exception when others then null;
  end;
  return null;
end $$;

drop trigger if exists discord_vehicle_edit_trg on public.vehicles;
create trigger discord_vehicle_edit_trg after update of plate, model, color on public.vehicles
  for each row
  when (old.plate is distinct from new.plate or old.model is distinct from new.model or old.color is distinct from new.color)
  execute function private.discord_on_vehicle_edit();

create or replace function private.discord_on_photo() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  begin
    perform private.discord_repost(case when tg_op = 'DELETE' then old.vehicle_id else new.vehicle_id end);
  exception when others then null;
  end;
  return null;
end $$;

drop trigger if exists discord_photo_trg on public.vehicle_photos;
create trigger discord_photo_trg after insert or delete or update of position on public.vehicle_photos
  for each row execute function private.discord_on_photo();

create or replace function private.discord_on_sale_edit() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  begin
    perform private.discord_repost(new.vehicle_id);
  exception when others then null;
  end;
  return null;
end $$;

drop trigger if exists discord_sale_edit_trg on public.vehicle_sales;
create trigger discord_sale_edit_trg after update of price, description on public.vehicle_sales
  for each row
  when (old.price is distinct from new.price or old.description is distinct from new.description)
  execute function private.discord_on_sale_edit();

-- ---------------------------------------------------------------------
--  Fonctions du tableau de bord (réservées aux gérants et à l'admin)
-- ---------------------------------------------------------------------
create or replace function public.get_discord_settings() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare s private.discord_settings;
begin
  perform private.require_manager();
  select * into s from private.discord_settings where id = 1;
  return jsonb_build_object(
    'site_name', s.site_name, 'site_url', s.site_url, 'storage_url', s.storage_url, 'mention', s.mention,
    'slots', jsonb_build_object(
      'impound', jsonb_build_object('configured', s.impound_url is not null, 'enabled', s.impound_enabled,
                                    'hint', case when s.impound_url is not null then right(s.impound_url, 4) end),
      'sale', jsonb_build_object('configured', s.sale_url is not null, 'enabled', s.sale_enabled,
                                 'hint', case when s.sale_url is not null then right(s.sale_url, 4) end),
      'staff', jsonb_build_object('configured', s.staff_url is not null, 'enabled', s.staff_enabled,
                                  'hint', case when s.staff_url is not null then right(s.staff_url, 4) end)),
    'staff_events', s.staff_events,
    'status', jsonb_build_object(
      'impound_posted', (select count(*) from private.discord_messages where kind = 'impound' and state in ('posted', 'posting')),
      'sale_posted', (select count(*) from private.discord_messages where kind = 'sale' and state in ('posted', 'posting')),
      'pending', (select count(*) from private.discord_outbox where state in ('queued', 'sent')),
      'failed', (select count(*) from private.discord_outbox where state = 'failed' and finished_at > now() - interval '1 day'),
      'pg_net', to_regclass('net._http_response') is not null),
    'recent', (select coalesce(jsonb_agg(to_jsonb(t) order by t.id desc), '[]'::jsonb)
                 from (select id, slot, op, state, last_error, created_at
                         from private.discord_outbox order by id desc limit 12) t));
end $$;

create or replace function public.save_discord_settings(p_settings jsonb) returns void
language plpgsql security definer set search_path = public, private as $$
declare
  v_uid uuid := private.require_manager();
  s private.discord_settings; v_old private.discord_settings;
  k text; v text; v_events jsonb;
  c_keys constant text[] := array['messages_client', 'messages_staff', 'claims', 'vehicles', 'sales', 'staff', 'other'];
begin
  select * into s from private.discord_settings where id = 1 for update;
  v_old := s;
  if p_settings ? 'impound_url' then s.impound_url := private.discord_clean_url(p_settings ->> 'impound_url'); end if;
  if p_settings ? 'sale_url' then s.sale_url := private.discord_clean_url(p_settings ->> 'sale_url'); end if;
  if p_settings ? 'staff_url' then s.staff_url := private.discord_clean_url(p_settings ->> 'staff_url'); end if;
  if p_settings ? 'impound_enabled' then s.impound_enabled := (p_settings ->> 'impound_enabled')::boolean; end if;
  if p_settings ? 'sale_enabled' then s.sale_enabled := (p_settings ->> 'sale_enabled')::boolean; end if;
  if p_settings ? 'staff_enabled' then s.staff_enabled := (p_settings ->> 'staff_enabled')::boolean; end if;
  if p_settings ? 'staff_events' then
    v_events := p_settings -> 'staff_events';
    if jsonb_typeof(v_events) <> 'object' then raise exception 'Paramètres d''événements invalides.'; end if;
    foreach k in array c_keys loop
      if v_events ? k then s.staff_events := s.staff_events || jsonb_build_object(k, (v_events ->> k)::boolean); end if;
    end loop;
  end if;
  if p_settings ? 'mention' then
    v := btrim(coalesce(p_settings ->> 'mention', ''));
    if v <> '' and v !~ '^<@&?[0-9]{15,25}>( <@&?[0-9]{15,25}>){0,4}$' then
      raise exception 'Mention invalide. Exemple : <@&123456789012345678> (identifiant du rôle Discord).';
    end if;
    s.mention := nullif(v, '');
  end if;
  if p_settings ? 'site_name' then
    v := btrim(coalesce(p_settings ->> 'site_name', ''));
    if char_length(v) < 2 or char_length(v) > 80 then raise exception 'Nom du site invalide.'; end if;
    s.site_name := v;
  end if;
  if p_settings ? 'site_url' then
    v := btrim(coalesce(p_settings ->> 'site_url', ''));
    if v <> '' then
      if v !~ '^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~%/-]*)?$' then raise exception 'Adresse du site invalide.'; end if;
      if right(v, 1) <> '/' then v := v || '/'; end if;
    end if;
    s.site_url := nullif(v, '');
  end if;
  if p_settings ? 'storage_url' then
    v := btrim(coalesce(p_settings ->> 'storage_url', ''));
    if v <> '' and v !~ '^https://[A-Za-z0-9.-]+/storage/v1/object/public/vehicle-photos/$' then
      raise exception 'Adresse du stockage des photos invalide.';
    end if;
    s.storage_url := nullif(v, '');
  end if;

  update private.discord_settings
     set site_name = s.site_name, site_url = s.site_url, storage_url = s.storage_url, mention = s.mention,
         impound_url = s.impound_url, impound_enabled = s.impound_enabled,
         sale_url = s.sale_url, sale_enabled = s.sale_enabled,
         staff_url = s.staff_url, staff_enabled = s.staff_enabled, staff_events = s.staff_events,
         updated_at = now(), updated_by_name = private.display_name(v_uid)
   where id = 1;
  perform private.log_action('discord.settings', 'settings', null, null,
    private.display_name(v_uid) || ' a modifié les paramètres Discord');
  -- Un webhook vient d'être activé ou changé : on publie le catalogue existant
  if (s.impound_url is distinct from v_old.impound_url or s.impound_enabled is distinct from v_old.impound_enabled
      or s.sale_url is distinct from v_old.sale_url or s.sale_enabled is distinct from v_old.sale_enabled) then
    perform public.discord_resync_all();
  end if;
end $$;

-- Aligne Discord sur l'état réel : publie ce qui manque, retire ce qui ne devrait plus y être
create or replace function public.discord_resync_all() returns integer
language plpgsql security definer set search_path = public, private as $$
declare r record; v_n integer := 0;
begin
  perform private.require_manager();
  for r in select id from public.vehicles where status in ('en_fourriere', 'a_vendre') loop
    perform private.discord_sync_vehicle(r.id);
  end loop;
  for r in select id from private.discord_messages
            where state in ('queued', 'posting', 'posted') and not private.discord_eligible(vehicle_id, kind) loop
    perform private.discord_retire(r.id);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- Supprime tous les messages du catalogue ('impound', 'sale' ou tous si null)
create or replace function public.discord_purge(p_kind text default null) returns integer
language plpgsql security definer set search_path = public, private as $$
declare r record; v_n integer := 0;
begin
  perform private.require_manager();
  if p_kind is not null and p_kind not in ('impound', 'sale') then raise exception 'Catégorie invalide.'; end if;
  for r in select id from private.discord_messages
            where state in ('queued', 'posting', 'posted') and (p_kind is null or kind = p_kind) loop
    perform private.discord_retire(r.id);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

create or replace function public.discord_send_test(p_slot text) returns void
language plpgsql security definer set search_path = public, private as $$
declare s private.discord_settings; v_url text; v_uid uuid := private.require_manager();
begin
  if p_slot not in ('impound', 'sale', 'staff') then raise exception 'Webhook inconnu.'; end if;
  select * into s from private.discord_settings where id = 1;
  v_url := case p_slot when 'impound' then s.impound_url when 'sale' then s.sale_url else s.staff_url end;
  if v_url is null then raise exception 'Enregistrez d''abord l''URL de ce webhook.'; end if;
  insert into private.discord_outbox (slot, op, payload) values (p_slot, 'test', jsonb_build_object(
    'username', left(s.site_name, 80),
    'allowed_mentions', jsonb_build_object('parse', '[]'::jsonb),
    'embeds', jsonb_build_array(jsonb_build_object(
      'title', '✅ Test réussi',
      'description', 'Le webhook « ' || case p_slot when 'impound' then 'véhicules en fourrière' when 'sale' then 'véhicules à vendre'
                                   else 'notifications du personnel' end || ' » est bien connecté.',
      'color', x'1E8E5A'::int,
      'footer', jsonb_build_object('text', 'Test lancé par ' || private.display_name(v_uid))))));
end $$;

-- Force l'envoi et la lecture des réponses (bouton "Actualiser" du tableau de bord)
create or replace function public.discord_run_worker() returns integer
language plpgsql security definer set search_path = public, private as $$
begin
  perform private.require_manager();
  return private.discord_worker(8);
end $$;
