-- =====================================================================
-- Pasly Astreinte : retour automatique de la résolution depuis le suivi des bâtiments
-- Quand un incident transmis par l'astreinte passe en « Résolu » ou « Clôturé » dans l'application
-- des contrôles (onglet Travaux), l'incident correspondant du carnet passe en « Résolu »,
-- avec une ligne dans son historique. Les téléphones le reçoivent à la synchronisation suivante.
-- À exécuter une fois dans Supabase > SQL Editor (projet mairie-pasly). Ne supprime aucune donnée.
-- =====================================================================
create or replace function public.astreinte_retour_resolution() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare
  ts text := to_char(clock_timestamp() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
  qui text := (select coalesce(nullif(trim(nom), ''), email) from public.profils where id = auth.uid());
begin
  if new.statut in ('resolu', 'cloture') and old.statut is distinct from new.statut then
    update public.astreinte_incidents a set
      statut = 'RESOLU',
      maj_le = clock_timestamp(),
      donnees = a.donnees
        || jsonb_build_object('status', 'RESOLU', 'updatedAt', ts)
        || jsonb_build_object('fieldTs', coalesce(a.donnees->'fieldTs', '{}'::jsonb) || jsonb_build_object('status', ts))
        || jsonb_build_object('history', coalesce(a.donnees->'history', '[]'::jsonb)
             || jsonb_build_array(jsonb_build_object('ts', ts,
                  'text', 'Statut : Résolu dans le suivi des bâtiments' || coalesce(' · par ' || qui, ''))))
    where a.incident_id = new.id and a.statut not in ('RESOLU', 'ARCHIVE');
  end if;
  return new;
end; $$;
revoke execute on function public.astreinte_retour_resolution() from public, anon, authenticated;

drop trigger if exists astreinte_retour on public.incidents;
create trigger astreinte_retour after update of statut on public.incidents
  for each row execute function public.astreinte_retour_resolution();
