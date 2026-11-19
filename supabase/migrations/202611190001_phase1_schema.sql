-- KinCare Phase 1 shared database schema

create extension if not exists pgcrypto;

create table if not exists public.CAREGIVERS (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  created_at timestamptz not null default now()
);

create table if not exists public.ELDERLY_PROFILES (
  id uuid primary key default gen_random_uuid(),
  caregiver_id uuid not null references public.CAREGIVERS(id) on delete cascade,
  display_name text not null,
  preferred_language text not null default 'en',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists elderly_profiles_caregiver_id_idx
  on public.ELDERLY_PROFILES(caregiver_id);

create table if not exists public.ENROLLED_DEVICES (
  id uuid primary key default gen_random_uuid(),
  caregiver_id uuid not null references public.CAREGIVERS(id) on delete cascade,
  device_uuid text not null,
  device_name text,
  enrolled_at timestamptz not null default now(),
  last_seen_at timestamptz,
  revoked_at timestamptz,
  unique(caregiver_id, device_uuid)
);

create index if not exists enrolled_devices_caregiver_id_idx
  on public.ENROLLED_DEVICES(caregiver_id);

create table if not exists public.ACTIVITY_TYPES (
  id uuid primary key default gen_random_uuid(),
  stable_key text not null unique,
  name text not null,
  description text
);

create table if not exists public.ACTIVITY_SESSIONS (
  id uuid primary key default gen_random_uuid(),
  elderly_profile_id uuid not null references public.ELDERLY_PROFILES(id) on delete restrict,
  activity_type_id uuid not null references public.ACTIVITY_TYPES(id) on delete restrict,
  device_id uuid not null references public.ENROLLED_DEVICES(id) on delete restrict,
  memory_deck_id uuid,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  status text not null default 'in_progress'
    check (status in ('in_progress', 'completed', 'abandoned')),
  created_at timestamptz not null default now()
);

create index if not exists activity_sessions_profile_id_idx
  on public.ACTIVITY_SESSIONS(elderly_profile_id);
create index if not exists activity_sessions_device_id_idx
  on public.ACTIVITY_SESSIONS(device_id);

create table if not exists public.MEMORY_DECKS (
  id uuid primary key default gen_random_uuid(),
  elderly_profile_id uuid not null references public.ELDERLY_PROFILES(id) on delete cascade,
  created_by_caregiver_id uuid not null references public.CAREGIVERS(id) on delete restrict,
  title text not null,
  language_code text not null default 'en',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists memory_decks_profile_id_idx
  on public.MEMORY_DECKS(elderly_profile_id);

create table if not exists public.MEDIA_ASSETS (
  id uuid primary key default gen_random_uuid(),
  elderly_profile_id uuid not null references public.ELDERLY_PROFILES(id) on delete cascade,
  uploaded_by_caregiver_id uuid not null references public.CAREGIVERS(id) on delete restrict,
  storage_bucket text not null,
  storage_path text not null,
  media_type text not null,
  mime_type text,
  created_at timestamptz not null default now(),
  unique(storage_bucket, storage_path)
);

create index if not exists media_assets_profile_id_idx
  on public.MEDIA_ASSETS(elderly_profile_id);

create table if not exists public.MEMORY_CARDS (
  id uuid primary key default gen_random_uuid(),
  deck_id uuid not null references public.MEMORY_DECKS(id) on delete cascade,
  photo_asset_id uuid not null references public.MEDIA_ASSETS(id) on delete restrict,
  question_audio_asset_id uuid references public.MEDIA_ASSETS(id) on delete restrict,
  answer_audio_asset_id uuid references public.MEDIA_ASSETS(id) on delete restrict,
  question_text text not null,
  answer_context text not null,
  display_order integer not null default 0
);

create index if not exists memory_cards_deck_id_idx
  on public.MEMORY_CARDS(deck_id);

alter table public.ACTIVITY_SESSIONS
  drop constraint if exists activity_sessions_memory_deck_fk;
alter table public.ACTIVITY_SESSIONS
  add constraint activity_sessions_memory_deck_fk
  foreign key (memory_deck_id) references public.MEMORY_DECKS(id) on delete restrict;

create table if not exists public.ACTIVITY_RESPONSES (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.ACTIVITY_SESSIONS(id) on delete cascade,
  memory_card_id uuid references public.MEMORY_CARDS(id) on delete restrict,
  response_audio_asset_id uuid references public.MEDIA_ASSETS(id) on delete restrict,
  response_index integer not null default 0,
  response_payload jsonb not null default '{}'::jsonb,
  is_correct boolean,
  responded_at timestamptz not null default now()
);

create index if not exists activity_responses_session_id_idx
  on public.ACTIVITY_RESPONSES(session_id);

-- Seed only lookup data; no users, caregivers or profile records.
insert into public.ACTIVITY_TYPES(stable_key, name, description)
values
  ('memory_decks', 'Memory Decks', 'Personalised family-photo reminiscence'),
  ('odd_one_out', 'Odd One Out', 'Find the item that differs'),
  ('everyday_object_sorting', 'Everyday Object Sorting', 'Place familiar objects into categories')
ON CONFLICT (stable_key) do update set
  name = excluded.name,
  description = excluded.description;
