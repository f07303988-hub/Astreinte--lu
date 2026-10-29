-- =====================================================================
-- Pasly Astreinte : enregistrement des incidents dans la base mairie-pasly
-- À exécuter une fois dans Supabase > SQL Editor (projet mairie-pasly).
-- Le script ne supprime aucune donnée et peut être relancé sans risque.
-- =====================================================================

-- Incidents d'astreinte (copie serveur du carnet de bord des téléphones)
create table if not exists public.astreinte_incidents (
  uuid uuid primary key,
  numero text not null,
  statut text not null,
  urgence text,
  categorie text,
  adresse text,
  latitude double precision,
  longitude double precision,
  donnees jsonb not null check (jsonb_typeof(donnees) = 'object'),
  cree_le timestamptz not null,
  maj_le timestamptz not null,                     -- heure de la modification sur le téléphone
  recu_le timestamptz not null default now(),      -- heure de réception par le serveur (fixée par la base)
  maj_par uuid default auth.uid(),
  incident_id uuid references public.incidents(id) on delete set null   -- incident transmis au suivi des bâtiments
);
create index if not exists astreinte_incidents_recu_idx on public.astreinte_incidents (recu_le);
create index if not exists astreinte_incidents_incident_idx on public.astreinte_incidents (incident_id);

alter table public.astreinte_incidents enable row level security;
revoke all on public.astreinte_incidents from anon;
grant select, insert, update on public.astreinte_incidents to authenticated;
drop policy if exists "compte actif" on public.astreinte_incidents;
drop policy if exists "astreinte lecture" on public.astreinte_incidents;
drop policy if exists "astreinte ajout" on public.astreinte_incidents;
drop policy if exists "astreinte modification" on public.astreinte_incidents;
create policy "compte actif" on public.astreinte_incidents as restrictive for all to authenticated using (compte_actif()) with check (compte_actif());
create policy "astreinte lecture" on public.astreinte_incidents for select to authenticated using (true);
create policy "astreinte ajout" on public.astreinte_incidents for insert to authenticated with check (mon_role() = any (array['admin','contributeur']));
create policy "astreinte modification" on public.astreinte_incidents for update to authenticated
  using (mon_role() = any (array['admin','contributeur'])) with check (mon_role() = any (array['admin','contributeur']));
-- Pas de suppression : un incident se clôt en « Archivé ».

-- Heure de réception et auteur fixés par la base (et non par le téléphone)
create or replace function public.astreinte_avant_ecriture() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  new.recu_le := clock_timestamp(); new.maj_par := auth.uid();
  return new;
end; $$;
revoke execute on function public.astreinte_avant_ecriture() from public, anon, authenticated;
drop trigger if exists astreinte_avant on public.astreinte_incidents;
create trigger astreinte_avant before insert or update on public.astreinte_incidents
  for each row execute function public.astreinte_avant_ecriture();

-- Photos des incidents d'astreinte (espace de stockage privé)
insert into storage.buckets (id, name, public) values ('astreinte', 'astreinte', false) on conflict (id) do nothing;
drop policy if exists "astreinte fichiers lecture" on storage.objects;
drop policy if exists "astreinte fichiers ajout" on storage.objects;
drop policy if exists "astreinte fichiers suppression" on storage.objects;
create policy "astreinte fichiers lecture" on storage.objects for select to authenticated using (bucket_id = 'astreinte');
create policy "astreinte fichiers ajout" on storage.objects for insert to authenticated
  with check (bucket_id = 'astreinte' and mon_role() = any (array['admin','contributeur']));
create policy "astreinte fichiers suppression" on storage.objects for delete to authenticated
  using (bucket_id = 'astreinte' and mon_role() = 'admin');

-- Corrige au passage une alerte de sécurité Supabase : cette fonction de déclencheur n'a pas à être appelable depuis l'API
revoke execute on function public.pei_avant_ecriture() from public, anon, authenticated;
