-- Réglages communs des téléphones d'astreinte (déjà appliqué le 29/10/2026 sur mairie-pasly)
insert into public.parametres (cle, valeur) values ('astreinte_config', '{}'::jsonb) on conflict (cle) do nothing;
drop policy if exists "parametres astreinte modification" on public.parametres;
create policy "parametres astreinte modification" on public.parametres for update to authenticated
  using (cle = 'astreinte_config' and mon_role() = any (array['admin','contributeur']))
  with check (cle = 'astreinte_config' and mon_role() = any (array['admin','contributeur']));
drop policy if exists "parametres astreinte lecture" on public.parametres;
create policy "parametres astreinte lecture" on public.parametres as restrictive for select to authenticated
  using (cle <> 'astreinte_config' or mon_role() = any (array['admin','contributeur']));
