-- =====================================================================
-- Pasly Astreinte : correctif du 30/10/2026
-- 1. Rétablit le tri des signalements (À valider / Transmis / Écartés) de l'application des contrôles :
--    date et auteur de la décision, passage automatique en « Transmis », lien vers les Travaux conservé.
--    (Ces règles avaient été effacées par les scripts du mode signalement du 29/10.)
-- 2. Mode signalement (agent, lecteur) : au lieu de refuser une modification, la base ne garde que ce que
--    l'agent a le droit d'ajouter (photos, lignes d'historique) ; statut, lien Travaux et tri restent intacts.
-- 3. Un agent ou un lecteur voit ses propres signalements (et leurs photos), jamais ceux des autres.
-- 4. « Écarter » et « Remettre à valider » apparaissent dans l'historique de l'incident sur les téléphones.
-- À exécuter une fois dans Supabase > SQL Editor (projet mairie-pasly). Ne supprime aucune donnée.
-- =====================================================================
create or replace function public.astreinte_avant_ecriture() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare r text := mon_role();
begin
  new.recu_le := clock_timestamp(); new.maj_par := auth.uid();
  if tg_op = 'INSERT' then
    new.cree_par := auth.uid();
    if r = any (array['lecteur','agent']) then
      new.statut := 'NOUVEAU'; new.incident_id := null; new.tri := 'a_valider'; new.tri_motif := null;
      new.donnees := (new.donnees - 'travauxId' - 'travauxEnCours') || jsonb_build_object('status', 'NOUVEAU');
    end if;
  else
    new.cree_par := old.cree_par;
    new.incident_id := coalesce(new.incident_id, old.incident_id);
    if old.donnees ? 'travauxId' and not (new.donnees ? 'travauxId') then
      new.donnees := new.donnees || jsonb_build_object('travauxId', old.donnees->'travauxId');
    end if;
    if r = any (array['lecteur','agent']) then
      new.statut := old.statut; new.urgence := old.urgence; new.categorie := old.categorie; new.adresse := old.adresse;
      new.latitude := old.latitude; new.longitude := old.longitude; new.numero := old.numero; new.cree_le := old.cree_le;
      new.incident_id := old.incident_id; new.tri := old.tri; new.tri_motif := old.tri_motif;
      new.donnees := old.donnees || jsonb_build_object(
        'photos', (select coalesce(jsonb_agg(p), '[]'::jsonb) from (
            select distinct on (p->>'chemin') p
            from jsonb_array_elements(coalesce(old.donnees->'photos', '[]'::jsonb) || coalesce(new.donnees->'photos', '[]'::jsonb)) p
            where jsonb_typeof(p) = 'object' and p ? 'chemin' order by p->>'chemin') x),
        'history', coalesce(old.donnees->'history', '[]'::jsonb) || coalesce((
            select jsonb_agg(h) from jsonb_array_elements(coalesce(new.donnees->'history', '[]'::jsonb)) h
            where not (coalesce(old.donnees->'history', '[]'::jsonb) @> jsonb_build_array(h))), '[]'::jsonb),
        'updatedAt', coalesce(new.donnees->'updatedAt', old.donnees->'updatedAt'));
    end if;
    if new.tri is distinct from old.tri then
      new.tri_le := now(); new.tri_par := auth.uid();
      -- La décision de la mairie apparaît dans l'historique de l'incident sur les téléphones
      if new.tri = 'ecarte' or (new.tri = 'a_valider' and old.tri = 'ecarte') then
        new.donnees := new.donnees || jsonb_build_object('history', coalesce(new.donnees->'history', '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
          'ts', to_char(clock_timestamp() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
          'text', case when new.tri = 'ecarte'
                    then '🗂️ Écarté par la mairie (pas de suivi bâtiments)' || coalesce(' : ' || nullif(trim(new.tri_motif), ''), '')
                    else '↩️ Remis à valider par la mairie' end
                  || coalesce(' · par ' || (select coalesce(nullif(trim(nom), ''), email) from public.profils where id = auth.uid()), ''))));
      end if;
    end if;
  end if;
  if new.incident_id is not null and new.tri <> 'transmis' then
    new.tri := 'transmis'; new.tri_le := coalesce(new.tri_le, now()); new.tri_par := coalesce(new.tri_par, auth.uid());
  end if;
  return new;
end; $$;
revoke execute on function public.astreinte_avant_ecriture() from public, anon, authenticated;

drop policy if exists "astreinte lecture" on public.astreinte_incidents;
create policy "astreinte lecture" on public.astreinte_incidents for select to authenticated
  using (mon_role() = any (array['admin','contributeur']) or (mon_role() = any (array['lecteur','agent']) and cree_par = auth.uid()));

drop policy if exists "astreinte fichiers lecture" on storage.objects;
create policy "astreinte fichiers lecture" on storage.objects for select to authenticated
  using (bucket_id = 'astreinte' and (mon_role() = any (array['admin','contributeur'])
    or (mon_role() = any (array['lecteur','agent']) and exists (
      select 1 from public.astreinte_incidents a where a.uuid::text = split_part(name, '/', 1) and a.cree_par = auth.uid()))));
