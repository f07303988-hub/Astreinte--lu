-- =====================================================================
-- Pasly Astreinte : anonymisation automatique des signalements
-- Le nom, le téléphone et le commentaire de l'habitant sont effacés 30 jours après la clôture
-- de l'incident (Résolu ou Archivé), sur le serveur puis sur les téléphones à leur synchronisation.
-- Vérification chaque nuit à 3 h 17. L'effacement est définitif.
-- À exécuter une fois dans Supabase > SQL Editor (projet mairie-pasly). Ne supprime aucun incident.
-- =====================================================================
create extension if not exists pg_cron;

-- Date de clôture de chaque incident
alter table public.astreinte_incidents add column if not exists clos_le timestamptz;

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
      if new.tri = 'ecarte' or (new.tri = 'a_valider' and old.tri = 'ecarte') then
        new.donnees := new.donnees || jsonb_build_object('history', coalesce(new.donnees->'history', '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
          'ts', to_char(clock_timestamp() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
          'text', case when new.tri = 'ecarte'
                    then '🗂️ Écarté par la mairie (pas de suivi bâtiments)' || coalesce(' : ' || nullif(trim(new.tri_motif), ''), '')
                    else '↩️ Remis à valider par la mairie' end
                  || coalesce(' · par ' || (select coalesce(nullif(trim(nom), ''), email) from public.profils where id = auth.uid()), ''))));
      end if;
    end if;
    -- Une anonymisation est définitive : un téléphone ne peut pas renvoyer les coordonnées effacées
    if (old.donnees->>'anonymise') = 'true' then
      new.donnees := new.donnees || jsonb_build_object('anonymise', true,
        'reporterName', case when coalesce(new.donnees->>'reporterName', '') = '' then '' else 'Habitant (anonymisé)' end,
        'reporterPhone', '', 'reporterComment', '');
    end if;
  end if;
  -- Date de clôture : fixée au passage en Résolu ou Archivé, effacée si l'incident est rouvert
  if new.statut in ('RESOLU', 'ARCHIVE') then
    if tg_op = 'UPDATE' and old.statut in ('RESOLU', 'ARCHIVE') then
      new.clos_le := coalesce(old.clos_le, new.clos_le, clock_timestamp());
    else
      new.clos_le := clock_timestamp();
    end if;
  else
    new.clos_le := null;
  end if;
  if new.incident_id is not null and new.tri <> 'transmis' then
    new.tri := 'transmis'; new.tri_le := coalesce(new.tri_le, now()); new.tri_par := coalesce(new.tri_par, auth.uid());
  end if;
  return new;
end; $$;
revoke execute on function public.astreinte_avant_ecriture() from public, anon, authenticated;

-- Incidents déjà clos : date de clôture = dernière modification
update public.astreinte_incidents set clos_le = maj_le where statut in ('RESOLU', 'ARCHIVE') and clos_le is null;

-- Effacement des coordonnées de l'habitant
create or replace function public.astreinte_anonymiser(delai interval default interval '30 days') returns integer
language plpgsql security definer set search_path to 'public' as $$
declare
  n integer;
  ts text := to_char(clock_timestamp() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
begin
  update public.astreinte_incidents a set
    maj_le = clock_timestamp(),
    donnees = a.donnees || jsonb_build_object(
      'reporterName', case when coalesce(a.donnees->>'reporterName', '') = '' then '' else 'Habitant (anonymisé)' end,
      'reporterPhone', '', 'reporterComment', '', 'anonymise', true, 'updatedAt', ts,
      'fieldTs', coalesce(a.donnees->'fieldTs', '{}'::jsonb) || jsonb_build_object('reporterName', ts, 'reporterPhone', ts, 'reporterComment', ts),
      'history', coalesce(a.donnees->'history', '[]'::jsonb) || jsonb_build_array(jsonb_build_object('ts', ts,
        'text', '🔒 Coordonnées de l''habitant effacées (' || extract(day from delai)::int || ' jours après la clôture)')))
  where a.statut in ('RESOLU', 'ARCHIVE') and a.clos_le < now() - delai
    and coalesce(a.donnees->>'anonymise', '') <> 'true'
    and (coalesce(a.donnees->>'reporterName', '') <> '' or coalesce(a.donnees->>'reporterPhone', '') <> '' or coalesce(a.donnees->>'reporterComment', '') <> '');
  get diagnostics n = row_count;
  return n;
end; $$;
revoke execute on function public.astreinte_anonymiser(interval) from public, anon, authenticated;

-- Chaque nuit à 3 h 17 (heure UTC)
select cron.unschedule(jobid) from cron.job where jobname = 'astreinte-anonymisation';
select cron.schedule('astreinte-anonymisation', '17 3 * * *', $$select public.astreinte_anonymiser()$$);
