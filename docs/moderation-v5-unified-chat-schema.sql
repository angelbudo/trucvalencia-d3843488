-- ============================================================
--  Moderació v5 — Unificació del búnker per a chat de mesa i de sala (lobby).
--
--  Objectiu:
--    · Permetre que `room_chat_flags` accepti flags del lobby on encara
--      no hi ha `room_id` ni `target_seat` reals.
--    · Afegir `status` a `sala_chat` perquè la IA pugui retirar
--      missatges del lobby igual que ja ho fa amb `room_text_chat`.
--
--  Aplica aquest fitxer SENCER al SQL Editor de Supabase DESPRÉS
--  d'haver corregut moderation-v3 i chat-status-schema.
-- ============================================================

-- 1) Relaxar NOT NULL en `room_chat_flags` per acceptar flags del lobby.
--    Els flags continuen funcionant igual per a partides (room_id i
--    target_seat segueixen omplint-se sempre que el missatge sigui a mesa).
alter table public.room_chat_flags
  alter column room_id drop not null;

alter table public.room_chat_flags
  alter column target_seat drop not null;

-- 2) `sala_chat` necessita columna `status` paral·lela a `room_text_chat`
--    per permetre que la Edge Function la marqui com 'blocked' quan
--    creui la línia roja o el dispositiu estigui en Shadow Ban.
alter table public.sala_chat
  add column if not exists status text not null default 'visible'
    check (status in ('visible','blocked'));

create index if not exists idx_sala_chat_status
  on public.sala_chat(sala_slug, status);

-- 3) Assegura que Realtime difon UPDATEs (necessari per retirar mssgs).
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename = 'sala_chat'
  ) then
    execute 'alter publication supabase_realtime add table public.sala_chat';
  end if;
end$$;

-- ============================================================
--  Després d'executar aquest script:
--    supabase functions deploy rooms-rpc --no-verify-jwt
--  per pujar la nova RPC `sendSalaTextMessage` i la moderació unificada.
-- ============================================================