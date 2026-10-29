-- =====================================================================
-- Pasly Astreinte : mode signalement pour les comptes « lecteur »
-- À exécuter une fois dans Supabase > SQL Editor (projet mairie-pasly).
-- Ne supprime aucune donnée et peut être relancé sans risque.
-- Un compte lecteur peut créer un incident d'astreinte et ajouter des photos aux siens,
-- sans changer de statut, toucher aux incidents des autres ni transmettre au suivi des bâtiments.
-- Il reçoit aussi les réglages communs et le planning (dont les numéros des élus d'astreinte).
-- Les contrôles des bâtiments ne changent pas : un lecteur y reste en lecture seule.
-- =====================================================================
alter table public.astreinte_incidents add column if not exists cree_par uuid default auth.uid();

create or replace function public.astreinte_avant_ecriture() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if tg_op = 'INSERT' then new.cree_par := auth.uid(); else new.cree_par := old.cree_par; end if;
  if mon_role() = 'lecteur' then
    if tg_op = 'INSERT' and (new.statut <> 'NOUVEAU' or new.incident_id is not null) then
      raise exception 'Mode signalement : un nouvel incident doit avoir le statut Nouveau';
    end if;
    if tg_op = 'UPDATE' and (old.cree_par is distinct from auth.uid() or new.statut <> old.statut
        or new.incident_id is distinct from old.incident_id) then
      raise exception 'Mode signalement : seul l''auteur peut compléter son incident, sans changer le statut';
    end if;
  end if;
  new.recu_le := clock_timestamp(); new.maj_par := auth.uid();
  return new;
end; $$;
revoke execute on function public.astreinte_avant_ecriture() from public, anon, authenticated;

drop policy if exists "astreinte ajout" on public.astreinte_incidents;
drop policy if exists "astreinte modification" on public.astreinte_incidents;
create policy "astreinte ajout" on public.astreinte_incidents for insert to authenticated
  with check (mon_role() = any (array['admin','contributeur','lecteur']));
create policy "astreinte modification" on public.astreinte_incidents for update to authenticated
  using (mon_role() = any (array['admin','contributeur']) or (mon_role() = 'lecteur' and cree_par = auth.uid()))
  with check (mon_role() = any (array['admin','contributeur']) or (mon_role() = 'lecteur' and cree_par = auth.uid()));

drop policy if exists "astreinte fichiers ajout" on storage.objects;
create policy "astreinte fichiers ajout" on storage.objects for insert to authenticated
  with check (bucket_id = 'astreinte' and mon_role() = any (array['admin','contributeur','lecteur']));

drop policy if exists "parametres astreinte lecture" on public.parametres;
create policy "parametres astreinte lecture" on public.parametres as restrictive for select to authenticated
  using ((cle <> all (array['astreinte_config','planning_astreinte'])) or mon_role() = any (array['admin','contributeur','lecteur']));
