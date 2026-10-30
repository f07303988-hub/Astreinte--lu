-- =====================================================================
-- Pasly Astreinte : notifications de nouveaux incidents
-- À exécuter une fois dans Supabase > SQL Editor (projet mairie-pasly). Ne supprime aucune donnée.
-- Ces tables ne sont accessibles qu'au serveur (fonction alerter-astreinte), jamais depuis les téléphones.
-- =====================================================================

-- Téléphones qui reçoivent les notifications
create table if not exists public.astreinte_abonnements (
  endpoint text primary key,
  p256dh text not null,
  auth text not null,
  compte uuid references public.profils(id) on delete cascade,
  appareil text,
  cree_le timestamptz not null default now(),
  vu_le timestamptz not null default now()
);
-- Une seule notification par incident, même si plusieurs téléphones la demandent
create table if not exists public.astreinte_alertes_envoyees (
  incident uuid primary key,
  le timestamptz not null default now(),
  destinataires int
);
-- Clé de signature des notifications (créée et lue uniquement par le serveur)
create table if not exists public.cles_serveur (
  cle text primary key,
  valeur jsonb not null,
  cree_le timestamptz not null default now()
);

alter table public.astreinte_abonnements enable row level security;
alter table public.astreinte_alertes_envoyees enable row level security;
alter table public.cles_serveur enable row level security;
revoke all on public.astreinte_abonnements, public.astreinte_alertes_envoyees, public.cles_serveur from anon, authenticated;
