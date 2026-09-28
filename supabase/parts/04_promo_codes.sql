-- =====================================================================
--  FOURRIÈRE DE BELLE ROCHE — Base de données
--  Fichier 4/8 : codes promo
--
--  • Les gérants créent des codes (ex. −50 %), valables sur la fourrière,
--    sur la vente, ou les deux.
--  • Dans une conversation, le client (ou un employé) saisit le code : la
--    réduction est enregistrée et appliquée au moment de la récupération ou
--    de la vente. Les montants sont TOUJOURS recalculés par le serveur.
--  • Un code peut être limité (nombre d'utilisations, date de fin, une fois
--    par personne). Une utilisation abandonnée (conversation fermée sans
--    récupération ni vente) est rendue disponible.
--  • Anti-devinette : 8 essais ratés en 10 minutes bloquent la saisie.
-- =====================================================================

create or replace function private.norm_code(p text) returns text
language sql immutable set search_path = '' as $$
  select upper(regexp_replace(btrim(coalesce(p, '')), '\s+', '', 'g'));
$$;

-- Rend disponible l'utilisation d'un code si la conversation se ferme sans aboutir
create or replace function private.release_redemption(p_conv uuid) returns void
language plpgsql security definer set search_path = public, private as $$
begin
  update public.discount_redemptions set status = 'annulee', released_at = now()
   where conversation_id = p_conv and status = 'appliquee';
  if found then  -- la réduction n'est plus valable : elle disparaît de la conversation (l'historique reste dans les utilisations)
    update public.conversations set discount_code = null, discount_percent = null, discount_redemption_id = null
     where id = p_conv;
  end if;
end $$;

-- ---------------------------------------------------------------------
--  Gestion des codes (gérants et administrateur)
-- ---------------------------------------------------------------------
create or replace function public.create_discount_code(
  p_code text, p_percent integer, p_scope text default 'tous', p_max_uses integer default null,
  p_expires_at timestamptz default null, p_once_per_client boolean default true, p_note text default null)
returns uuid
language plpgsql security definer set search_path = public, private as $$
declare
  v_uid uuid := private.require_manager();
  v_code text := private.norm_code(p_code);
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_id uuid;
begin
  if v_code !~ '^[A-Z0-9][A-Z0-9_-]{2,23}$' then
    raise exception 'Code invalide : 3 à 24 caractères (lettres, chiffres, tirets), sans espace ni accent.';
  end if;
  if p_percent is null or p_percent not between 1 and 100 then
    raise exception 'La réduction doit être comprise entre 1 et 100 %%.';
  end if;
  if p_scope not in ('fourriere', 'vente', 'tous') then raise exception 'Portée invalide.'; end if;
  if p_max_uses is not null and p_max_uses not between 1 and 100000 then
    raise exception 'Le nombre d''utilisations doit être compris entre 1 et 100000.';
  end if;
  if p_expires_at is not null and p_expires_at <= now() then
    raise exception 'La date de fin doit être dans le futur.';
  end if;
  if v_note is not null and char_length(v_note) > 200 then raise exception 'Note trop longue (200 caractères maximum).'; end if;
  begin
    insert into public.discount_codes (code, percent, scope, max_uses, once_per_client, expires_at, note, created_by, created_by_name)
    values (v_code, p_percent, p_scope, p_max_uses, coalesce(p_once_per_client, true), p_expires_at, v_note, v_uid, private.display_name(v_uid))
    returning id into v_id;
  exception when unique_violation then
    raise exception 'Ce code existe déjà.';
  end;
  perform private.log_action('discount.create', 'discount_code', v_id, null,
    format('%s a créé le code promo %s (−%s %%, %s)', private.display_name(v_uid), v_code, p_percent,
           case p_scope when 'fourriere' then 'fourrière' when 'vente' then 'vente' else 'fourrière et vente' end));
  return v_id;
end $$;

create or replace function public.set_discount_code_active(p_id uuid, p_active boolean) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_manager(); v_d public.discount_codes;
begin
  update public.discount_codes set active = coalesce(p_active, false) where id = p_id returning * into v_d;
  if not found then raise exception 'Code introuvable.'; end if;
  perform private.log_action('discount.toggle', 'discount_code', p_id, null,
    format('%s a %s le code promo %s', private.display_name(v_uid), case when v_d.active then 'réactivé' else 'désactivé' end, v_d.code));
end $$;

create or replace function public.delete_discount_code(p_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_manager(); v_d public.discount_codes;
begin
  select * into v_d from public.discount_codes where id = p_id for update;
  if not found then raise exception 'Code introuvable.'; end if;
  if exists (select 1 from public.discount_redemptions where code_id = p_id) then
    raise exception 'Ce code a déjà été utilisé : désactivez-le plutôt que de le supprimer.';
  end if;
  delete from public.discount_codes where id = p_id;
  perform private.log_action('discount.delete', 'discount_code', p_id, null,
    format('%s a supprimé le code promo %s', private.display_name(v_uid), v_d.code));
end $$;

create or replace function public.list_discount_codes()
returns table (id uuid, code text, percent integer, scope text, max_uses integer, once_per_client boolean,
               expires_at timestamptz, active boolean, note text, created_by_name text, created_at timestamptz,
               uses integer, used_count integer, state text)
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_manager();
  return query
    select d.id, d.code, d.percent, d.scope, d.max_uses, d.once_per_client, d.expires_at, d.active, d.note,
           d.created_by_name, d.created_at,
           (select count(*)::integer from public.discount_redemptions r where r.code_id = d.id and r.status in ('appliquee', 'utilisee')),
           (select count(*)::integer from public.discount_redemptions r where r.code_id = d.id and r.status = 'utilisee'),
           case when not d.active then 'desactive'
                when d.expires_at is not null and d.expires_at <= now() then 'expire'
                when d.max_uses is not null and (select count(*) from public.discount_redemptions r
                       where r.code_id = d.id and r.status in ('appliquee', 'utilisee')) >= d.max_uses then 'epuise'
                else 'actif' end
      from public.discount_codes d
     order by d.created_at desc;
end $$;

create or replace function public.list_discount_redemptions(p_code_id uuid)
returns table (id uuid, client_name text, applied_by_name text, kind text, status text, percent integer,
               original_amount numeric, final_amount numeric, applied_at timestamptz, vehicle_label text)
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_manager();
  return query
    select r.id, r.client_name, r.applied_by_name, r.kind, r.status, r.percent, r.original_amount, r.final_amount,
           r.applied_at, case when v.id is null then null else v.plate || ' · ' || v.model end
      from public.discount_redemptions r
      left join public.vehicles v on v.id = r.vehicle_id
     where r.code_id = p_code_id
     order by r.applied_at desc;
end $$;

-- ---------------------------------------------------------------------
--  Saisie d'un code dans une conversation (client concerné ou personnel)
--  Renvoie {ok, message, ...} au lieu de lever une erreur pour que les
--  essais ratés soient bien comptés.
-- ---------------------------------------------------------------------
create or replace function public.apply_discount_code(p_conversation_id uuid, p_code text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare
  v_uid uuid := private.require_login();
  v_name text := private.display_name(v_uid);
  v_norm text := private.norm_code(p_code);
  v_c public.conversations; v_v public.vehicles; v_s public.vehicle_sales; v_d public.discount_codes;
  v_kind text; v_orig numeric; v_new numeric; v_red uuid; v_msg text;
begin
  select * into v_c from public.conversations where id = p_conversation_id for update;
  if not found or (v_c.client_id is distinct from v_uid and not private.is_staff()) then
    raise exception 'Conversation introuvable.' using errcode = '42501';
  end if;
  if v_c.status <> 'ouverte' then raise exception 'Cette conversation est fermée.'; end if;
  if v_c.discount_redemption_id is not null then
    return jsonb_build_object('ok', false, 'message', 'Un code promo est déjà appliqué à cette conversation.');
  end if;

  v_kind := case v_c.type when 'claim' then 'fourriere' else 'vente' end;
  select * into v_v from public.vehicles where id = v_c.vehicle_id for update;
  if v_kind = 'fourriere' then
    if not found or coalesce(v_v.status, '') not in ('en_fourriere', 'reclamee') then
      raise exception 'Ce véhicule n''est plus en fourrière.';
    end if;
    v_orig := private.billing_amount(v_v.handling_fee, v_v.daily_rate, v_v.created_at, v_v.billing_end_at);
  else
    select * into v_s from public.vehicle_sales where vehicle_id = v_c.vehicle_id and status = 'a_vendre';
    if not found or coalesce(v_v.status, '') <> 'a_vendre' then raise exception 'Ce véhicule n''est plus à vendre.'; end if;
    v_orig := case when v_s.promo_percent is null then v_s.price else round(v_s.price * (100 - v_s.promo_percent) / 100) end;
  end if;

  delete from private.discount_attempts where at < now() - interval '1 day';
  if (select count(*) from private.discount_attempts where user_id = v_uid and at > now() - interval '10 minutes') >= 8 then
    return jsonb_build_object('ok', false, 'message', 'Trop d''essais. Réessayez dans quelques minutes.');
  end if;

  select * into v_d from public.discount_codes where code = v_norm for update;
  if not found or not v_d.active or (v_d.expires_at is not null and v_d.expires_at <= now()) then
    insert into private.discount_attempts (user_id) values (v_uid);
    return jsonb_build_object('ok', false, 'message', 'Code invalide ou expiré.');
  end if;
  if v_d.scope <> 'tous' and v_d.scope <> v_kind then
    insert into private.discount_attempts (user_id) values (v_uid);
    return jsonb_build_object('ok', false, 'message',
      case v_d.scope when 'fourriere' then 'Ce code est réservé aux véhicules en fourrière.' else 'Ce code est réservé à l''achat d''un véhicule.' end);
  end if;
  if v_d.max_uses is not null and (select count(*) from public.discount_redemptions
        where code_id = v_d.id and status in ('appliquee', 'utilisee')) >= v_d.max_uses then
    return jsonb_build_object('ok', false, 'message', 'Ce code a atteint sa limite d''utilisations.');
  end if;
  if v_d.once_per_client and exists (select 1 from public.discount_redemptions
        where code_id = v_d.id and client_id = v_c.client_id and status in ('appliquee', 'utilisee')) then
    return jsonb_build_object('ok', false, 'message', 'Ce code a déjà été utilisé avec ce compte.');
  end if;

  v_new := round(v_orig * (100 - v_d.percent) / 100);
  insert into public.discount_redemptions (code_id, code, conversation_id, vehicle_id, client_id, client_name, applied_by_name, kind, percent, original_amount)
  values (v_d.id, v_d.code, v_c.id, v_c.vehicle_id, v_c.client_id, v_c.client_name, v_name, v_kind, v_d.percent, v_orig)
  returning id into v_red;
  update public.conversations
     set discount_code = v_d.code, discount_percent = v_d.percent, discount_redemption_id = v_red
   where id = v_c.id;

  v_msg := case v_kind
    when 'fourriere' then format('Code %s appliqué (−%s %%) : montant à régler actuellement %s au lieu de %s.', v_d.code, v_d.percent, private.fmt_money(v_new), private.fmt_money(v_orig))
    else format('Code %s appliqué (−%s %%) : %s au lieu de %s.', v_d.code, v_d.percent, private.fmt_money(v_new), private.fmt_money(v_orig)) end;
  perform private.post_system_message(v_c.id, v_msg);
  perform private.log_action('discount.apply', 'conversation', v_c.id, v_c.vehicle_id,
    format('%s a utilisé le code %s (−%s %%) sur %s (%s)',
           case when v_uid = v_c.client_id then v_c.client_name else v_name || ' pour ' || v_c.client_name end,
           v_d.code, v_d.percent, v_v.plate, v_v.model),
    jsonb_build_object('code', v_d.code, 'percent', v_d.percent, 'original', v_orig, 'discounted', v_new, 'kind', v_kind));
  perform private.notify_roles(array['employe', 'gerant', 'admin'], 'discount', 'Code promo utilisé',
    format('%s a utilisé le code %s (−%s %%)', v_c.client_name, v_d.code, v_d.percent),
    '#/messages/' || v_c.id, v_c.id, v_c.vehicle_id, v_uid);
  return jsonb_build_object('ok', true, 'code', v_d.code, 'percent', v_d.percent, 'kind', v_kind,
                            'original', v_orig, 'discounted', v_new, 'message', v_msg);
end $$;

-- Un gérant peut retirer un code encore non utilisé d'une conversation
create or replace function public.remove_conversation_discount(p_conversation_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_manager(); v_c public.conversations; v_name text := private.display_name(v_uid);
begin
  select * into v_c from public.conversations where id = p_conversation_id for update;
  if not found then raise exception 'Conversation introuvable.'; end if;
  if v_c.discount_redemption_id is null then raise exception 'Aucun code promo actif sur cette conversation.'; end if;
  if exists (select 1 from public.discount_redemptions where id = v_c.discount_redemption_id and status = 'utilisee') then
    raise exception 'Ce code a déjà servi à une transaction terminée : il ne peut plus être retiré.';
  end if;
  update public.discount_redemptions set status = 'annulee', released_at = now()
   where id = v_c.discount_redemption_id and status = 'appliquee';
  update public.conversations set discount_code = null, discount_percent = null, discount_redemption_id = null
   where id = p_conversation_id;
  if v_c.status = 'ouverte' then
    perform private.post_system_message(p_conversation_id, format('Le code %s a été retiré par %s.', v_c.discount_code, v_name));
  end if;
  perform private.log_action('discount.remove', 'conversation', p_conversation_id, v_c.vehicle_id,
    format('%s a retiré le code %s de la conversation de %s', v_name, v_c.discount_code, v_c.client_name));
end $$;
