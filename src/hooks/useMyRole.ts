import { useEffect, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/hooks/useAuth";

export type AppRole = "user" | "moderator" | "admin";

interface State {
  role: AppRole;
  isAdmin: boolean;
  isModerator: boolean; // true per a 'moderator' O 'admin'
  ready: boolean;
}

/**
 * Llegeix els rols de l'usuari logat des de la taula public.user_roles.
 * RLS només deixa veure les pròpies files, així que és segur cridar-ho
 * directament des del client. La seguretat real està a les policies del
 * servidor: encara que un atacant manipuli aquest hook a la consola,
 * no podrà modificar `room_chat_flags` ni `room_chat_flags_audit` sense
 * tenir el rol real a la base de dades.
 */
export function useMyRole(): State {
  const { user, ready: authReady } = useAuth();
  const [state, setState] = useState<State>({
    role: "user",
    isAdmin: false,
    isModerator: false,
    ready: false,
  });

  useEffect(() => {
    if (!authReady) return;
    if (!user) {
      setState({ role: "user", isAdmin: false, isModerator: false, ready: true });
      return;
    }
    let cancelled = false;
    void (async () => {
      const { data, error } = await supabase
        .from("user_roles" as never)
        .select("role")
        .eq("user_id", user.id);
      if (cancelled) return;
      if (error || !data) {
        setState({ role: "user", isAdmin: false, isModerator: false, ready: true });
        return;
      }
      const roles = (data as Array<{ role: AppRole }>).map((r) => r.role);
      const isAdmin = roles.includes("admin");
      const isMod = isAdmin || roles.includes("moderator");
      setState({
        role: isAdmin ? "admin" : isMod ? "moderator" : "user",
        isAdmin,
        isModerator: isMod,
        ready: true,
      });
    })();
    return () => {
      cancelled = true;
    };
  }, [authReady, user?.id]);

  return state;
}