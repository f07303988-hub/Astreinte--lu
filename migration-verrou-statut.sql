-- =====================================================================
-- Pasly Astreinte : verrou du statut en mode signalement (audit du 29/10/2026)
-- À exécuter une fois dans Supabase > SQL Editor (projet mairie-pasly). Ne supprime aucune donnée.
-- Un agent ou un lecteur ne peut pas non plus changer le statut ni la transmission au suivi des bâtiments
-- en passant par le contenu détaillé de l'incident (colonne donnees), et pas seulement par la colonne statut.
-- =====================================================================
create or replace function public.astreinte_avant_ecriture() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if tg_op = 'INSERT' then new.cree_par := auth.uid(); else new.cree_par := old.cree_par; end if;
  if mon_role() = any (array['lecteur','agent']) then
    if tg_op = 'INSERT' and (new.statut <> 'NOUVEAU' or new.incident_id is not null
        or coalesce(new.donnees->>'status', 'NOUVEAU') <> 'NOUVEAU' or new.donnees->>'travauxId' is not null) then
      raise exception 'Mode signalement : un nouvel incident doit avoir le statut Nouveau';
    end if;
    if tg_op = 'UPDATE' and (old.cree_par is distinct from auth.uid() or new.statut <> old.statut
        or new.incident_id is distinct from old.incident_id
        or (new.donnees->>'status') is distinct from (old.donnees->>'status')
        or (new.donnees->>'travauxId') is distinct from (old.donnees->>'travauxId')) then
      raise exception 'Mode signalement : seul l''auteur peut compléter son incident, sans changer le statut';
    end if;
  end if;
  new.recu_le := clock_timestamp(); new.maj_par := auth.uid();
  return new;
end; $$;
revoke execute on function public.astreinte_avant_ecriture() from public, anon, authenticated;
