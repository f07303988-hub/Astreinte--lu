-- Pasly Astreinte : consultation seule pour les comptes « lecteur »
-- Permet aux téléphones connectés avec un compte lecteur de recevoir les réglages communs
-- (catégories, numéros utiles, consignes) et de savoir qui est d'astreinte d'après le planning.
-- À exécuter une fois dans Supabase > SQL Editor (projet mairie-pasly). Ne supprime aucune donnée.
drop policy if exists "parametres astreinte lecture" on public.parametres;
create policy "parametres astreinte lecture" on public.parametres as restrictive for select to authenticated
  using ((cle <> all (array['astreinte_config','planning_astreinte'])) or mon_role() = any (array['admin','contributeur','lecteur']));
