-- ============================================================
--  Garbage Collection — neteja automàtica de partides, sales
--  i missatges de xat antics.
--
--  ESTRATÈGIA (combinada):
--    1) ON DELETE CASCADE entre `rooms` i les filles efímeres
--       (`room_members`, `room_text_chat`, `room_chat`, ...).
--    2) Funció `gc_cleanup_rooms_and_chats()` que esborra:
--         - Sales finished/abandoned/cancelled de més de 30 min.
--         - Sales sense activitat de més de 6 h (abandonades).
--         - Missatges de room_text_chat de més de 24 h (xarxa
--           de seguretat; els orfes ja cauen per CASCADE).
--    3) pg_cron crida la funció cada 10 minuts.
--
--  NO ES TOQUEN:  profiles, player_stats, player_xp, user_roles,
--                 reports, admin_alerts, account_links, friends,
--                 messages_inbox, room_chat_flags (historial de
--                 penalitzacions 7/13/28 → desvinculat amb SET NULL).
-- ============================================================

-- ---------- 1) CASCADE en les filles efímeres de `rooms` ----------
do $mig$
begin
  if exists (select 1 from information_schema.table_constraints
             where table_schema='public' and table_name='room_text_chat'
               and constraint_name='room_text_chat_room_id_fkey') then
    alter table public.room_text_chat drop constraint room_text_chat_room_id_fkey;
  end if;
  alter table public.room_text_chat
    add constraint room_text_chat_room_id_fkey
    foreign key (room_id) references public.rooms(id) on delete cascade;

  if to_regclass('public.room_chat') is not null then
    if exists (select 1 from information_schema.table_constraints
               where table_schema='public' and table_name='room_chat'
                 and constraint_name='room_chat_room_id_fkey') then
      alter table public.room_chat drop constraint room_chat_room_id_fkey;
    end if;
    alter table public.room_chat
      add constraint room_chat_room_id_fkey
      foreign key (room_id) references public.rooms(id) on delete cascade;
  end if;

  if to_regclass('public.room_members') is not null then
    if exists (select 1 from information_schema.table_constraints
               where table_schema='public' and table_name='room_members'
                 and constraint_name='room_members_room_id_fkey') then
      alter table public.room_members drop constraint room_members_room_id_fkey;
    end if;
    alter table public.room_members
      add constraint room_members_room_id_fkey
      foreign key (room_id) references public.rooms(id) on delete cascade;
  end if;

  if to_regclass('public.room_state') is not null then
    begin alter table public.room_state drop constraint if exists room_state_room_id_fkey;
    exception when others then null; end;
    alter table public.room_state
      add constraint room_state_room_id_fkey
      foreign key (room_id) references public.rooms(id) on delete cascade;
  end if;

  if to_regclass('public.room_invites') is not null then
    begin alter table public.room_invites drop constraint if exists room_invites_room_id_fkey;
    exception when others then null; end;
    alter table public.room_invites
      add constraint room_invites_room_id_fkey
      foreign key (room_id) references public.rooms(id) on delete cascade;
  end if;
end
$mig$;

-- ---------- 2) `room_chat_flags` NO en cascade (SET NULL) ----------
do $flags$
begin
  if to_regclass('public.room_chat_flags') is not null then
    begin alter table public.room_chat_flags drop constraint if exists room_chat_flags_room_id_fkey;
    exception when others then null; end;
    begin alter table public.room_chat_flags alter column room_id drop not null;
    exception when others then null; end;
    alter table public.room_chat_flags
      add constraint room_chat_flags_room_id_fkey
      foreign key (room_id) references public.rooms(id) on delete set null;
  end if;
end
$flags$;

-- ---------- 3) Funció de neteja ----------
create or replace function public.gc_cleanup_rooms_and_chats()
returns table(rooms_deleted int, chats_deleted int)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_rooms int := 0;
  v_extra int := 0;
  v_chats int := 0;
begin
  -- 3.1 Sales finalitzades / cancel·lades amb >30 min
  with del as (
    delete from public.rooms
    where status in ('finished','abandoned','cancelled','closed')
      and coalesce(updated_at, created_at) < now() - interval '30 minutes'
    returning 1
  )
  select count(*) into v_rooms from del;

  -- 3.2 Sales sense activitat de més de 6 h.
  begin
    with del as (
      delete from public.rooms
      where coalesce(last_activity_at, updated_at, created_at) < now() - interval '6 hours'
      returning 1
    )
    select count(*) into v_extra from del;
  exception when undefined_column then
    with del as (
      delete from public.rooms
      where coalesce(updated_at, created_at) < now() - interval '6 hours'
      returning 1
    )
    select count(*) into v_extra from del;
  end;
  v_rooms := v_rooms + v_extra;

  -- 3.3 Missatges de xat de més de 24 h.
  with del as (
    delete from public.room_text_chat
    where created_at < now() - interval '24 hours'
    returning 1
  )
  select count(*) into v_chats from del;

  -- 3.4 Frases del joc (si existeix).
  if to_regclass('public.room_chat') is not null then
    execute 'delete from public.room_chat where created_at < now() - interval ''24 hours''';
  end if;

  return query select v_rooms, v_chats;
end;
$fn$;

revoke all on function public.gc_cleanup_rooms_and_chats() from public;
grant execute on function public.gc_cleanup_rooms_and_chats() to service_role;

-- ---------- 4) Planificació amb pg_cron ----------
create extension if not exists pg_cron;

do $cron$
declare jid bigint;
begin
  select jobid into jid from cron.job where jobname = 'gc_rooms_chats';
  if jid is not null then perform cron.unschedule(jid); end if;
  perform cron.schedule(
    'gc_rooms_chats',
    '*/10 * * * *',
    'select public.gc_cleanup_rooms_and_chats();'
  );
end
$cron$;

-- ---------- 5) Verificació manual ----------
-- select * from public.gc_cleanup_rooms_and_chats();
-- select * from cron.job where jobname='gc_rooms_chats';
-- select * from cron.job_run_details
--   where jobid=(select jobid from cron.job where jobname='gc_rooms_chats')
--   order by start_time desc limit 5;
