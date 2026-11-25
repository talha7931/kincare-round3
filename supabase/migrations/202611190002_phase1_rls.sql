-- KinCare Phase 1 authentication profile and RLS policies

create or replace function public.handle_new_caregiver()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.CAREGIVERS(id, display_name)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1))
  )
  on conflict (id) do update
    set display_name = coalesce(excluded.display_name, public.CAREGIVERS.display_name);
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_caregiver();

create or replace function public.is_caregiver(profile_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.ELDERLY_PROFILES p
    where p.id = profile_id
      and p.caregiver_id = auth.uid()
  );
$$;

alter table public.CAREGIVERS enable row level security;
alter table public.ELDERLY_PROFILES enable row level security;
alter table public.ENROLLED_DEVICES enable row level security;
alter table public.ACTIVITY_TYPES enable row level security;
alter table public.ACTIVITY_SESSIONS enable row level security;
alter table public.ACTIVITY_RESPONSES enable row level security;
alter table public.MEMORY_DECKS enable row level security;
alter table public.MEMORY_CARDS enable row level security;
alter table public.MEDIA_ASSETS enable row level security;

create policy "Caregivers read own profile"
  on public.CAREGIVERS for select
  using (id = auth.uid());
create policy "Caregivers insert own profile"
  on public.CAREGIVERS for insert
  with check (id = auth.uid());
create policy "Caregivers update own profile"
  on public.CAREGIVERS for update
  using (id = auth.uid())
  with check (id = auth.uid());

create policy "Caregivers read own elderly profiles"
  on public.ELDERLY_PROFILES for select
  using (caregiver_id = auth.uid());
create policy "Caregivers insert own elderly profiles"
  on public.ELDERLY_PROFILES for insert
  with check (caregiver_id = auth.uid());
create policy "Caregivers update own elderly profiles"
  on public.ELDERLY_PROFILES for update
  using (caregiver_id = auth.uid())
  with check (caregiver_id = auth.uid());
create policy "Caregivers delete own elderly profiles"
  on public.ELDERLY_PROFILES for delete
  using (caregiver_id = auth.uid());

create policy "Caregivers manage own devices"
  on public.ENROLLED_DEVICES for all
  using (caregiver_id = auth.uid())
  with check (caregiver_id = auth.uid());

create policy "Activity types readable by authenticated caregivers"
  on public.ACTIVITY_TYPES for select
  to authenticated
  using (true);

create policy "Caregivers manage own memory decks"
  on public.MEMORY_DECKS for all
  using (
    created_by_caregiver_id = auth.uid()
    and public.is_caregiver(elderly_profile_id)
  )
  with check (
    created_by_caregiver_id = auth.uid()
    and public.is_caregiver(elderly_profile_id)
  );

create policy "Caregivers read own media assets"
  on public.MEDIA_ASSETS for select
  using (
    uploaded_by_caregiver_id = auth.uid()
    and public.is_caregiver(elderly_profile_id)
  );
create policy "Caregivers insert own media assets"
  on public.MEDIA_ASSETS for insert
  with check (
    uploaded_by_caregiver_id = auth.uid()
    and public.is_caregiver(elderly_profile_id)
  );
create policy "Caregivers delete own media assets"
  on public.MEDIA_ASSETS for delete
  using (
    uploaded_by_caregiver_id = auth.uid()
    and public.is_caregiver(elderly_profile_id)
  );

create policy "Caregivers read cards for owned decks"
  on public.MEMORY_CARDS for select
  using (exists (
    select 1
    from public.MEMORY_DECKS d
    where d.id = MEMORY_CARDS.deck_id
      and d.created_by_caregiver_id = auth.uid()
      and public.is_caregiver(d.elderly_profile_id)
 ));
create policy "Caregivers manage cards for owned decks"
  on public.MEMORY_CARDS for all
  using (exists (
    select 1
    from public.MEMORY_DECKS d
    where d.id = MEMORY_CARDS.deck_id
      and d.created_by_caregiver_id = auth.uid()
      and public.is_caregiver(d.elderly_profile_id)
  ))
  with check (exists (
    select 1
    from public.MEMORY_DECKS d
    where d.id = MEMORY_CARDS.deck_id
      and d.created_by_caregiver_id = auth.uid()
      and public.is_caregiver(d.elderly_profile_id)
  ));

create policy "Caregivers read own activity sessions"
  on public.ACTIVITY_SESSIONS for select
  using (
    public.is_caregiver(elderly_profile_id)
    and exists (
      select 1
      from public.ENROLLED_DEVICES d
      where d.id = ACTIVITY_SESSIONS.device_id
        and d.caregiver_id = auth.uid()
    )
  );
create policy "Caregivers insert own activity sessions"
  on public.ACTIVITY_SESSIONS for insert
  with check (
    public.is_caregiver(elderly_profile_id)
    and exists (
      select 1
      from public.ENROLLED_DEVICES d
      where d.id = ACTIVITY_SESSIONS.device_id
        and d.caregiver_id = auth.uid()
    )
  );
create policy "Caregivers update own activity sessions"
  on public.ACTIVITY_SESSIONS for update
  using (
    public.is_caregiver(elderly_profile_id)
    and exists (
      select 1
      from public.ENROLLED_DEVICES d
      where d.id = ACTIVITY_SESSIONS.device_id
        and d.caregiver_id = auth.uid()
    )
  )
  with check (
    public.is_caregiver(elderly_profile_id)
    and exists (
      select 1
      from public.ENROLLED_DEVICES d
      where d.id = ACTIVITY_SESSIONS.device_id
        and d.caregiver_id = auth.uid()
    )
  );

create policy "Caregivers read own activity responses"
  on public.ACTIVITY_RESPONSES for select
  using (exists (
    select 1
    from public.ACTIVITY_SESSIONS s
    where s.id = ACTIVITY_RESPONSES.session_id
      and public.is_caregiver(s.elderly_profile_id)
  ));
create policy "Caregivers insert own activity responses"
  on public.ACTIVITY_RESPONSES for insert
  with check (exists (
    select 1
    from public.ACTIVITY_SESSIONS s
    where s.id = ACTIVITY_RESPONSES.session_id
      and public.is_caregiver(s.elderly_profile_id)
  ));

insert into storage.buckets(id, name, public)
values ('kincare-media', 'kincare-media', false)
ON CONFLICT (id) do update set public = false;

create policy "Caregivers upload own family media"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'kincare-media'
    and public.is_caregiver(((storage.foldername(name))[1])::uuid)
  );

create policy "Caregivers read own family media"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'kincare-media'
    and public.is_caregiver(((storage.foldername(name))[1])::uuid)
  );

create policy "Caregivers delete own family media"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'kincare-media'
    and public.is_caregiver(((storage.foldername(name))[1])::uuid)
  );
