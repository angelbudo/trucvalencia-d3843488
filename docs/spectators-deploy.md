# Espectadores — pasos de despliegue (Supabase externo)

Este proyecto usa un Supabase propio (no Lovable Cloud), así que la migración
y el redeploy del edge function se aplican manualmente.

## 1) Migración SQL — `room_text_chat`

Ejecuta en SQL editor del dashboard:

```sql
ALTER TABLE public.room_text_chat
  ALTER COLUMN seat DROP NOT NULL;

ALTER TABLE public.room_text_chat
  ADD COLUMN IF NOT EXISTS sender_name text;

ALTER TABLE public.room_text_chat
  DROP CONSTRAINT IF EXISTS room_text_chat_seat_or_sender_chk;

ALTER TABLE public.room_text_chat
  ADD CONSTRAINT room_text_chat_seat_or_sender_chk
  CHECK (seat IS NOT NULL OR (sender_name IS NOT NULL AND length(btrim(sender_name)) > 0));
```

## 2) Redeploy del edge function `rooms-rpc`

El cambio está aplicado en `supabase/functions/rooms-rpc/index.ts`
(`sendTextMessage` ahora acepta espectadores con `senderName`).

```bash
supabase functions deploy rooms-rpc
```

## 3) Frontend

El frontend ya está adaptado:
- `useRoomPresence`: nuevo canal Realtime por sala que registra a quien entre
  en `?spectator=1` y a los jugadores sentados (para descubrir espectadores).
- `RoomMembersPanel`: lista unificada — jugadores activos (negrita) arriba,
  espectadores debajo con sufijo `(espectador)`.
- Chat (`TableChat`, `BoardRoomChat`): mensajes con `seat == null` se renderizan
  con el nombre del espectador y `(espectador)` al lado, sin negrita.
- Acciones de juego (`submitAction`, `sendChatPhrase`, etc.) ya rechazaban a
  los que no están en `room_players`; sigue intacto.

## 3) Migració SQL — `apply_xp_penalty` (penalització per abandonar)

Quan un jugador abandona una partida en curs i encara hi ha altres humans
a la taula, perd 10XP. Crea la RPC al SQL editor del dashboard:

```sql
create or replace function public.apply_xp_penalty(p_amount integer)
returns public.user_stats
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.user_stats;
  v_new_xp integer;
  v_new_level integer;
  v_threshold integer;
begin
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;
  if p_amount is null or p_amount <= 0 then
    select * into v_row from public.user_stats where user_id = v_uid;
    return v_row;
  end if;

  insert into public.user_stats (user_id)
  values (v_uid)
  on conflict (user_id) do nothing;

  select * into v_row from public.user_stats where user_id = v_uid for update;

  v_new_xp := greatest(0, coalesce(v_row.xp, 0) - p_amount);
  v_new_level := greatest(1, coalesce(v_row.level, 1));

  -- Threshold per a nivell L = 100 * (L - 1) * L / 2
  loop
    v_threshold := (100 * (v_new_level - 1) * v_new_level) / 2;
    exit when v_new_level <= 1 or v_new_xp >= v_threshold;
    v_new_level := v_new_level - 1;
  end loop;

  update public.user_stats
     set xp = v_new_xp,
         level = v_new_level
   where user_id = v_uid
   returning * into v_row;

  return v_row;
end;
$$;

grant execute on function public.apply_xp_penalty(integer) to authenticated;
```

Mentre la RPC no estiga desplegada, el client crida `apply_xp_penalty` i
falla silenciosament: l'usuari pot abandonar normalment però no perdrà XP
fins que s'aplique aquesta migració.