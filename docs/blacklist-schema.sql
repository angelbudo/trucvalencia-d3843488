-- =====================================================================
-- Blacklist de paraules per al filtre del xat online
-- =====================================================================
-- Crea una taula pública (només lectura per a usuaris) que conté la
-- llista d'insults que filtra el xat. L'administrador la pot editar
-- des del panell de Supabase per afegir o eliminar paraules sense
-- haver de tocar el codi de l'aplicació.
--
-- IMPORTANT: executa aquest fitxer una sola vegada al SQL Editor.
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.blacklist (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  word        text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- Una mateixa paraula (en minúscules i sense accents) no es pot repetir.
CREATE UNIQUE INDEX IF NOT EXISTS blacklist_word_unique
  ON public.blacklist (lower(word));

-- ----------------------------------------------------------------------
-- Permisos del Data API
-- ----------------------------------------------------------------------
-- Tothom (anon + authenticated) pot LLEGIR la llista: així el filtre del
-- xat pot carregar-la des de qualsevol client.
-- Només el service_role (panell d'admin) pot INSERTAR / ACTUALITZAR /
-- ESBORRAR paraules.
GRANT SELECT ON public.blacklist TO anon, authenticated;
GRANT ALL    ON public.blacklist TO service_role;

ALTER TABLE public.blacklist ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "blacklist_public_read" ON public.blacklist;
CREATE POLICY "blacklist_public_read"
  ON public.blacklist
  FOR SELECT
  TO anon, authenticated
  USING (true);

-- ----------------------------------------------------------------------
-- Llavor inicial: les mateixes paraules que abans estaven hard-coded
-- al fitxer src/online/profanityFilter.ts
-- ----------------------------------------------------------------------
INSERT INTO public.blacklist (word) VALUES
  -- Castellà
  ('puta'),('putas'),('puto'),('putos'),
  ('gilipollas'),('gilipuertas'),
  ('cabron'),('cabrones'),('cabrona'),
  ('hijoputa'),('hijodeputa'),('hdp'),
  ('mierda'),('mierdas'),
  ('joder'),('jodete'),
  ('coño'),('cono'),
  ('polla'),('pollas'),
  ('follar'),('follate'),
  ('maricon'),('maricones'),
  ('zorra'),('zorras'),
  ('imbecil'),('imbeciles'),
  ('idiota'),('idiotas'),
  ('subnormal'),('subnormales'),
  ('estupido'),('estupida'),
  ('tonto'),('tonta'),
  ('capullo'),('capullos'),
  ('panoli'),
  ('retrasado'),('retrasada'),
  -- Valencià / català
  ('fillputa'),('fillsdeputa'),('fillputes'),
  ('cabro'),('cabrons'),
  ('merda'),('merdes'),
  ('collons'),
  ('punyeta'),('punyetes'),
  ('carall'),
  ('imbecils'),
  ('estupit'),
  ('ximple'),('ximplos'),
  ('tarat'),('tarats'),
  ('burro'),('burros'),
  ('amaricat')
ON CONFLICT ((lower(word))) DO NOTHING;