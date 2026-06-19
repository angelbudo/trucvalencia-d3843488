-- ============================================================
--  Moderació v3 — Sistema de PUNTS per gravetat i nous llindars.
--
--  Substitueix la lògica d'`_evaluate_windows` de v2 (que comptava
--  REPORTERS DISTINTS) per una suma de PUNTS, mantenint la regla
--  d'or: només el 1r report d'un mateix reporter contra el mateix
--  target i categoria a la mateixa partida o el mateix dia natural
--  compta (la resta queden `counted=false` per auditoria).
--
--  Escala de gravetat (punts per report):
--     LLEU (1) : antiesportiu, spam
--     GREU (2) : llenguatge, drets-autor, altres-il-legal
--     MOLT GREU (3): assetjament, discurs-odi, contingut-sexual, violencia
--
--  Llindars per +1 strike oficial (per ventana i categoria):
--     1 dia   →  7 punts
--     7 dies  → 13 punts
--    30 dies → 28 punts
--
--  Executa aquest fitxer SENCER al SQL editor de Supabase DESPRÉS
--  de `docs/moderation-v2-schema.sql`.
-- ============================================================

-- ---------- 1) Columna `weight` a room_chat_flags ----------
alter table public.room_chat_flags
  add column if not exists weight smallint not null default 1
    check (weight between 0 and 3);

create index if not exists idx_room_chat_flags_target_cat_time_w
  on public.room_chat_flags(target_device_id, category, created_at desc)
  where counted = true;

-- ---------- 2) Helper: mapeja `reason` (value del formulari) a punts ----------
create or replace function public._reason_weight(_reason text)
returns smallint
language sql
immutable
as $$
  select case lower(coalesce(_reason,''))
    -- Molt greus (3)
    when 'assetjament'      then 3
    when 'discurs-odi'      then 3
    when 'contingut-sexual' then 3
    when 'violencia'        then 3
    -- Greus (2)
    when 'llenguatge'       then 2
    when 'drets-autor'      then 2
    when 'altres-il-legal'  then 2
    -- Lleus (1)
    when 'antiesportiu'     then 1
    when 'spam'             then 1
    -- Compat. retro / fallback raonable
    else 2
  end::smallint;
$$;

-- ---------- 3) Helper: inferir categoria des de `reason` (v3) ----------
create or replace function public._infer_report_category(_reason text)
returns text
language sql
immutable
as $$
  select case lower(coalesce(_reason,''))
    when 'antiesportiu' then 'foul_play'
    when 'spam'         then 'foul_play'
    else 'conduct'
  end;
$$;

-- ---------- 4) Reavaluar ventanes per SUMA DE PUNTS ----------
create or replace function public._evaluate_windows(
  _scope    text,
  _key_val  text,
  _target_device text,
  _target_user   uuid,
  _category text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  pts_today int;
  pts_7d    int;
  pts_30d   int;
  day_key   text;
begin
  -- Suma `weight` només dels flags counted=true del canal humà,
  -- agrupats per dispositiu objectiu + categoria.
  with src as (
    select weight, created_at
      from public.room_chat_flags
     where target_device_id = _target_device
       and category = _category
       and counted = true
       and reporter_device_id <> 'openai-moderation'
       and created_at >= now() - interval '30 days'
  )
  select
    coalesce((select sum(weight) from src where created_at::date = current_date), 0),
    coalesce((select sum(weight) from src where created_at >= now() - interval '7 days'), 0),
    coalesce((select sum(weight) from src where created_at >= now() - interval '30 days'), 0)
  into pts_today, pts_7d, pts_30d;

  day_key := to_char(current_date, 'YYYY-MM-DD');

  -- Llindars definitius v3
  if pts_today >= 7 then
    perform public._maybe_strike_window(
      _scope, _key_val, _category, 'window_day',
      format('day:%s:%s', day_key, _category)
    );
  end if;

  if pts_7d >= 13 then
    perform public._maybe_strike_window(
      _scope, _key_val, _category, 'window_7d',
      format('week:%s:%s', to_char(date_trunc('week', now()), 'IYYY-IW'), _category)
    );
  end if;

  if pts_30d >= 28 then
    perform public._maybe_strike_window(
      _scope, _key_val, _category, 'window_30d',
      format('month:%s:%s', to_char(date_trunc('month', now()), 'YYYY-MM'), _category)
    );
  end if;
end;
$$;

-- ---------- 5) Trigger principal v3: calcula weight + dedup + ventanes ----------
create or replace function public.handle_chat_report()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cat text;
  w   smallint;
  is_dup boolean;
  target_user uuid;
begin
  -- Categoria: usa la columna si ve; si no, inferida del `reason`.
  cat := coalesce(new.category, public._infer_report_category(new.reason));
  if cat not in ('conduct','foul_play') then cat := 'conduct'; end if;

  -- Pes (punts) segons el motiu. Per al canal IA: pes fix 2 (no s'usa).
  if new.reporter_device_id = 'openai-moderation' then
    w := 2;
  else
    w := public._reason_weight(new.reason);
  end if;

  -- ─── REGLA D'OR: dedup per (reporter, target, categoria) ───
  -- Mateixa partida O mateix dia natural → no compta (auditoria sí).
  is_dup := false;
  if new.reporter_device_id <> 'openai-moderation' then
    select exists (
      select 1 from public.room_chat_flags f
       where f.id <> new.id
         and f.reporter_device_id = new.reporter_device_id
         and f.target_device_id   = new.target_device_id
         and coalesce(f.category, public._infer_report_category(f.reason)) = cat
         and (f.room_id = new.room_id
              or f.created_at::date = new.created_at::date)
    ) into is_dup;
  end if;

  update public.room_chat_flags
     set category = cat,
         counted  = (not is_dup),
         weight   = w
   where id = new.id;

  if is_dup then
    return new;
  end if;

  -- Resol user_id objectiu (compte vinculat al dispositiu reportat)
  select coalesce(rp.profile_user_id, al.user_id)
    into target_user
    from (select 1) _
    left join public.room_players rp
      on rp.room_id = new.room_id
     and rp.device_id = new.target_device_id
    left join public.account_links al
      on al.device_id = new.target_device_id
    limit 1;

  -- ─── Canal ràpid IA: +1 strike directe (sense ventanes) ───
  if new.reporter_device_id = 'openai-moderation' then
    perform public._apply_official_strike(
      'device_moderation', 'device_id', new.target_device_id, 'ai', cat
    );
    insert into public.moderation_strike_log
      (scope, key_value, source, category, window_key, strike_index)
    select 'device', new.target_device_id, 'ai', cat,
           format('ai:%s', new.id),
           coalesce((select strikes from public.device_moderation
                       where device_id = new.target_device_id), 1)
    on conflict do nothing;

    if target_user is not null then
      perform public._apply_official_strike(
        'account_moderation', 'user_id', target_user::text, 'ai', cat
      );
      insert into public.moderation_strike_log
        (scope, key_value, source, category, window_key, strike_index)
      select 'account', target_user::text, 'ai', cat,
             format('ai:%s', new.id),
             coalesce((select strikes from public.account_moderation
                         where user_id = target_user), 1)
      on conflict do nothing;
    end if;
    return new;
  end if;

  -- ─── Canal humà: avalua ventanes per SUMA DE PUNTS ───
  perform public._evaluate_windows(
    'device', new.target_device_id,
    new.target_device_id, target_user, cat
  );

  if target_user is not null then
    perform public._evaluate_windows(
      'account', target_user::text,
      new.target_device_id, target_user, cat
    );
  end if;

  return new;
end;
$$;

-- (Re)engancha el trigger (idempotent).
drop trigger if exists trg_chat_report on public.room_chat_flags;
create trigger trg_chat_report
  after insert on public.room_chat_flags
  for each row execute function public.handle_chat_report();

-- ---------- 6) Backfill: recalcula weight/category als flags existents ----------
update public.room_chat_flags
   set weight   = public._reason_weight(reason),
       category = coalesce(category, public._infer_report_category(reason))
 where weight is null
    or weight = 1 and reason is not null and public._reason_weight(reason) <> 1;

-- ============================================================
--  FIN v3.
--  · El formulari de report envia `reason` ∈ {assetjament, discurs-odi,
--    contingut-sexual, violencia, spam, drets-autor, altres-il-legal,
--    antiesportiu, llenguatge}.
--  · El trigger calcula `weight` (1/2/3) i `category` (conduct/foul_play),
--    dedupea (regla d'or) i suma punts per ventana.
--  · Llindars per +1 strike oficial: 1d≥7, 7d≥13, 30d≥28.
--  · Progressió 1..9 (avís·avís·ban 24h × 3, fins a ban permanent) sense canvis.
-- ============================================================