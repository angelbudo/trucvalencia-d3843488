-- ============================================================
--  Sistema de penalització per abandonament de partides online
--  (Leaver Penalty) — INDEPENDENT del sistema de moderació
--  per comportament/IA. Mai accumula cap al baneig permanent.
--
--  Regles:
--   * 1 abandó = +1 al leave_count.
--   * leave_count == 3  → baneig 24h + leave_count = 0, ban_count++.
--   * 24h sense abandons → leave_count -= 1 (mín. 0). Decaiment
--     oportunista executat dins de register_leave (sense pg_cron).
--   * Solo bloqueja l'accés online; la resta de l'app segueix lliure.
--
--  Executar al SQL editor de Supabase.
-- ============================================================

-- ---------- TAULA: leaver per dispositiu ----------
create table if not exists public.leaver_penalty_device (
  device_id       text primary key,
  leave_count     int not null default 0,
  ban_count       int not null default 0,
  banned_until    timestamptz,
  last_leave_at   timestamptz,
  last_decay_at   timestamptz,
  updated_at      timestamptz not null default now()
);

grant select on public.leaver_penalty_device to authenticated;
grant all    on public.leaver_penalty_device to service_role;

alter table public.leaver_penalty_device enable row level security;

drop policy if exists "leaver_penalty_device read all" on public.leaver_penalty_device;
create policy "leaver_penalty_device read all"
  on public.leaver_penalty_device for select
  using (true);

-- ---------- TAULA: leaver per compte (user_id) ----------
create table if not exists public.leaver_penalty_account (
  user_id         uuid primary key,
  leave_count     int not null default 0,
  ban_count       int not null default 0,
  banned_until    timestamptz,
  last_leave_at   timestamptz,
  last_decay_at   timestamptz,
  updated_at      timestamptz not null default now()
);

grant select on public.leaver_penalty_account to authenticated;
grant all    on public.leaver_penalty_account to service_role;

alter table public.leaver_penalty_account enable row level security;

drop policy if exists "leaver_penalty_account read all" on public.leaver_penalty_account;
create policy "leaver_penalty_account read all"
  on public.leaver_penalty_account for select
  using (true);

-- ---------- Funció auxiliar: aplica un step de leaver ----------
create or replace function public._apply_leaver_step(
  _table   text,
  _key_col text,
  _key_val text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  rec record;
  decay_steps int;
begin
  execute format(
    'insert into public.%I(%I) values ($1) on conflict (%I) do nothing',
    _table, _key_col, _key_col
  ) using _key_val;

  execute format(
    'select * from public.%I where %I = $1 for update',
    _table, _key_col
  ) into rec using _key_val;

  -- 1) Decaiment oportunista: si fa >=24h del darrer abandó (o del darrer
  --    decay), restem 1 per cada bloc de 24h transcorregut, fins a 0.
  if rec.leave_count > 0
     and (rec.banned_until is null or rec.banned_until <= now()) then
    decay_steps := floor(
      extract(epoch from (now() - coalesce(rec.last_decay_at, rec.last_leave_at, now())))
      / 86400
    )::int;
    if decay_steps > 0 then
      rec.leave_count := greatest(rec.leave_count - decay_steps, 0);
      rec.last_decay_at := now();
    end if;
  end if;

  -- 2) Si encara està baneat actiu, no apliquem cap step nou
  --    (no té sentit penalitzar dues vegades el mateix abandó).
  if rec.banned_until is not null and rec.banned_until > now() then
    execute format(
      'update public.%I set leave_count=$1, last_decay_at=$2, updated_at=now() where %I = $3',
      _table, _key_col
    ) using rec.leave_count, rec.last_decay_at, _key_val;
    return;
  end if;

  -- 3) Sumem aquest abandó
  rec.leave_count := rec.leave_count + 1;
  rec.last_leave_at := now();

  -- 4) Tres abandons → 24h de baneig + reset comptador
  if rec.leave_count >= 3 then
    rec.ban_count    := rec.ban_count + 1;
    rec.leave_count  := 0;
    rec.banned_until := now() + interval '24 hours';
    rec.last_decay_at := now();
  end if;

  execute format(
    'update public.%I set
       leave_count   = $1,
       ban_count     = $2,
       banned_until  = $3,
       last_leave_at = $4,
       last_decay_at = $5,
       updated_at    = now()
     where %I = $6',
    _table, _key_col
  ) using rec.leave_count, rec.ban_count, rec.banned_until,
          rec.last_leave_at, rec.last_decay_at, _key_val;
end;
$$;

-- ---------- RPC pública: register_leave ----------
-- Crida quan un jugador abandona una partida en curs.
-- Penalitza el dispositiu i, si està vinculat, la cuenta.
create or replace function public.register_leave(
  p_device_id text,
  p_room_id   uuid default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  target_user uuid;
begin
  if p_device_id is null or length(p_device_id) = 0 then
    return;
  end if;

  perform public._apply_leaver_step(
    'leaver_penalty_device', 'device_id', p_device_id
  );

  -- Vincula amb una cuenta real (account_links o room_players actuals).
  select coalesce(rp.profile_user_id, al.user_id)
    into target_user
    from (select 1) _
    left join public.room_players rp
      on rp.device_id = p_device_id
     and (p_room_id is null or rp.room_id = p_room_id)
    left join public.account_links al
      on al.device_id = p_device_id
    limit 1;

  if target_user is not null then
    perform public._apply_leaver_step(
      'leaver_penalty_account', 'user_id', target_user::text
    );
  end if;
end;
$$;

grant execute on function public.register_leave(text, uuid) to anon, authenticated, service_role;

-- ---------- Decaiment oportunista en lectura (refresh) ----------
-- Permet al client refrescar el seu propi estat aplicant el decay
-- sense haver d'abandonar res. Idempotent.
create or replace function public.refresh_leaver_decay(
  p_device_id text,
  p_user_id   uuid default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  rec record;
  decay_steps int;
begin
  if p_device_id is not null and length(p_device_id) > 0 then
    select * into rec from public.leaver_penalty_device
      where device_id = p_device_id for update;
    if found and rec.leave_count > 0
       and (rec.banned_until is null or rec.banned_until <= now()) then
      decay_steps := floor(
        extract(epoch from (now() - coalesce(rec.last_decay_at, rec.last_leave_at, now())))
        / 86400
      )::int;
      if decay_steps > 0 then
        update public.leaver_penalty_device
          set leave_count = greatest(leave_count - decay_steps, 0),
              last_decay_at = now(),
              updated_at = now()
          where device_id = p_device_id;
      end if;
    end if;
  end if;

  if p_user_id is not null then
    select * into rec from public.leaver_penalty_account
      where user_id = p_user_id for update;
    if found and rec.leave_count > 0
       and (rec.banned_until is null or rec.banned_until <= now()) then
      decay_steps := floor(
        extract(epoch from (now() - coalesce(rec.last_decay_at, rec.last_leave_at, now())))
        / 86400
      )::int;
      if decay_steps > 0 then
        update public.leaver_penalty_account
          set leave_count = greatest(leave_count - decay_steps, 0),
              last_decay_at = now(),
              updated_at = now()
          where user_id = p_user_id;
      end if;
    end if;
  end if;
end;
$$;

grant execute on function public.refresh_leaver_decay(text, uuid) to anon, authenticated, service_role;

-- ---------- Realtime ----------
do $$
begin
  begin
    alter publication supabase_realtime add table public.leaver_penalty_device;
  exception when duplicate_object then null; end;
  begin
    alter publication supabase_realtime add table public.leaver_penalty_account;
  exception when duplicate_object then null; end;
end $$;