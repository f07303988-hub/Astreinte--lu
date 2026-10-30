-- =====================================================================
-- Durées de conservation (mairie-pasly)
--  · Photos des incidents d'astreinte : supprimées 1 an après la clôture (fonction entretien-astreinte)
--  · Incidents d'astreinte clos et journal des modifications : effacés après 5 ans
--  · Abonnements aux notifications inutilisés depuis 6 mois, traces d'envoi de plus d'un an : effacés
--  · Dernière activité des comptes, pour repérer les comptes inactifs (administrateurs uniquement)
-- Tâches chaque nuit. À exécuter une fois dans Supabase > SQL Editor. Ne touche pas aux incidents des Travaux.
-- =====================================================================
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Clé interne qui autorise la tâche de nuit à appeler la fonction de nettoyage des photos
insert into public.cles_serveur (cle, valeur)
values ('entretien', jsonb_build_object('v', replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')))
on conflict (cle) do nothing;

create or replace function public.astreinte_avant_ecriture() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare r text := mon_role();
begin
  new.recu_le := clock_timestamp(); new.maj_par := auth.uid();
  if tg_op = 'INSERT' then
    if new.statut in ('RESOLU', 'ARCHIVE') and new.cree_le < now() - interval '5 years' then return null; end if;
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
    -- Photos supprimées par la mairie : un téléphone ne peut pas les renvoyer
    if jsonb_typeof(old.donnees->'photosSupprimees') = 'array' then
      new.donnees := new.donnees || jsonb_build_object(
        'photosSupprimees', (select coalesce(jsonb_agg(distinct c), '[]'::jsonb) from jsonb_array_elements(
            old.donnees->'photosSupprimees' || case when jsonb_typeof(new.donnees->'photosSupprimees') = 'array' then new.donnees->'photosSupprimees' else '[]'::jsonb end) c),
        'photos', (select coalesce(jsonb_agg(p), '[]'::jsonb) from jsonb_array_elements(coalesce(new.donnees->'photos', '[]'::jsonb)) p
            where not (old.donnees->'photosSupprimees' @> jsonb_build_array(p->'chemin'))));
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

-- Effacements après les durées de conservation
create or replace function public.conservation_purger() returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare a int; j int; e int; s int;
begin
  delete from public.astreinte_incidents where statut in ('RESOLU', 'ARCHIVE') and clos_le < now() - interval '5 years';
  get diagnostics a = row_count;
  delete from public.journal where created_at < now() - interval '5 years';
  get diagnostics j = row_count;
  delete from public.astreinte_alertes_envoyees where le < now() - interval '1 year';
  get diagnostics e = row_count;
  delete from public.astreinte_abonnements where vu_le < now() - interval '6 months';
  get diagnostics s = row_count;
  return jsonb_build_object('incidents_astreinte', a, 'journal', j, 'traces_alertes', e, 'abonnements', s);
end; $$;
revoke execute on function public.conservation_purger() from public, anon, authenticated;

-- Dernière activité de chaque compte (connexion ou utilisation d'une appli), pour les administrateurs
create or replace function public.comptes_activite() returns table (id uuid, derniere_activite timestamptz)
language sql stable security definer set search_path to 'public' as $$
  select u.id, greatest(u.last_sign_in_at,
    (select max(coalesce(s.refreshed_at, s.updated_at))::timestamptz from auth.sessions s where s.user_id = u.id))
  from auth.users u
  where public.mon_role() = 'admin';
$$;
revoke execute on function public.comptes_activite() from public, anon;
grant execute on function public.comptes_activite() to authenticated;

-- Tâches de nuit (heure UTC)
select cron.unschedule(jobid) from cron.job where jobname in ('conservation-purge', 'astreinte-photos');
select cron.schedule('conservation-purge', '37 3 * * *', $$select public.conservation_purger()$$);
select cron.schedule('astreinte-photos', '27 3 * * *', $$
  select net.http_post(
    url := 'https://idswkljjaoajhevgsnfh.supabase.co/functions/v1/entretien-astreinte',
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'x-cle-entretien', (select valeur->>'v' from public.cles_serveur where cle = 'entretien')),
    body := '{}'::jsonb)
$$);
