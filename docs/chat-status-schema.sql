-- ============================================================
--  Chat status — "Botón rojo" de la IA.
--
--  Añade la columna `status` a `room_text_chat` para que la IA
--  pueda vetar mensajes ya publicados (línea roja o shadow-ban
--  por superar 28 puntos en 30 días).
--
--  Flujo:
--    1. El cliente envía el mensaje → se inserta con status='visible'.
--    2. La edge function `rooms-rpc.sendTextMessage` llama a OpenAI
--       Moderation. Si cae en categoría grave o el emisor está en
--       shadow-ban, hace UPDATE status='blocked'.
--    3. Realtime propaga el UPDATE y `useRoomTextChat` retira el
--       mensaje de la pantalla de todos los jugadores.
--
--  Ejecuta este script ENTERO en el SQL Editor de Supabase tras
--  haber aplicado moderation-v3 / v4.
-- ============================================================

alter table public.room_text_chat
  add column if not exists status text not null default 'visible'
    check (status in ('visible','blocked'));

create index if not exists idx_room_text_chat_status
  on public.room_text_chat(room_id, status);

-- Asegura que Realtime difunde UPDATEs además de INSERT.
-- (La publicación supabase_realtime ya emite todos los eventos por
--  defecto si la tabla está incluida; el ADD TABLE es idempotente.)
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename = 'room_text_chat'
  ) then
    execute 'alter publication supabase_realtime add table public.room_text_chat';
  end if;
end$$;

-- Helper opcional: comprueba si un dispositivo está en shadow-ban
-- (>=28 puntos en los últimos 30 días). La edge function suma los
-- puntos directamente, pero exponemos también un RPC por si en el
-- futuro algún cliente quiere consultarlo.
create or replace function public.chat_shadow_banned(_device text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(weight),0) >= 28
    from public.room_chat_flags
   where target_device_id = _device
     and counted = true
     and created_at >= now() - interval '30 days';
$$;

grant execute on function public.chat_shadow_banned(text) to anon, authenticated, service_role;

-- ============================================================
--  FIN. Tras ejecutar:
--    supabase functions deploy rooms-rpc --no-verify-jwt
--  para subir la nueva lógica de la edge function.
-- ============================================================