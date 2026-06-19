-- Ejecuta este SQL en el editor SQL de Supabase (Lovable Cloud → SQL).
-- Soluciona el 403 al hacer upsert en public.account_links añadiendo
-- las políticas RLS y los GRANTs explícitos que la Data API requiere.

ALTER TABLE public.account_links ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "account_links select own" ON public.account_links;
CREATE POLICY "account_links select own" ON public.account_links
  FOR SELECT TO authenticated
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "account_links insert own" ON public.account_links;
CREATE POLICY "account_links insert own" ON public.account_links
  FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "account_links update own" ON public.account_links;
CREATE POLICY "account_links update own" ON public.account_links
  FOR UPDATE TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "account_links delete own" ON public.account_links;
CREATE POLICY "account_links delete own" ON public.account_links
  FOR DELETE TO authenticated
  USING (auth.uid() = user_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.account_links TO authenticated;
GRANT ALL ON public.account_links TO service_role;