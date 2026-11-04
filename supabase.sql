-- Run once in Supabase → SQL Editor. Creates the members-only classified case files.

create table if not exists public.casefiles (
  id bigint generated always as identity primary key,
  no int not null,
  title text not null,
  kind text,
  year text,
  note text,
  created_at timestamptz not null default now()
);

-- Row level security: signed-in members can read; nobody can write from the site.
-- Add, edit or delete files in Supabase → Table Editor instead.
alter table public.casefiles enable row level security;

-- The project does not expose new tables automatically, so let signed-in members reach this one (rows still filtered by the policy below).
grant select on public.casefiles to authenticated;

drop policy if exists "members read casefiles" on public.casefiles;
create policy "members read casefiles" on public.casefiles
  for select to authenticated using (true);

-- Example files so the section has something to show; only added when the table is empty.
insert into public.casefiles (no, title, kind, year, note)
select * from (values
  (1, 'BLACK SIGNAL', 'UNRELEASED IDENTITY', '2026', 'Example file. A rejected pitch that is still the best thing in the drawer.'),
  (2, 'DEN', 'PRIVATE PROTOTYPE', '2026', 'Example file. A site that only opens at night, local time.'),
  (3, 'MOONLIGHT TEST', 'MOTION STUDY', '2025', 'Example file. Forty seconds of fur, light and nothing else.')
) as v(no, title, kind, year, note)
where not exists (select 1 from public.casefiles);


-- Member profiles: the join form sends first name, last name and phone as sign-up metadata,
-- and this trigger copies them into public.members. Each member can read only their own row;
-- the owner sees everyone in Table Editor → members.
create table if not exists public.members (
  id uuid primary key references auth.users (id) on delete cascade,
  email text,
  first_name text,
  last_name text,
  phone text,
  created_at timestamptz not null default now()
);

alter table public.members enable row level security;
grant select on public.members to authenticated;

drop policy if exists "members read own profile" on public.members;
create policy "members read own profile" on public.members
  for select to authenticated using ((select auth.uid()) = id);

-- security definer so the insert works during sign-up; empty search_path, so every name is schema-qualified.
-- left() caps lengths instead of a check constraint, because a failing trigger would block the sign-up itself.
create or replace function public.handle_new_member() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.members (id, email, first_name, last_name, phone)
  values (
    new.id, new.email,
    left(new.raw_user_meta_data ->> 'first_name', 60),
    left(new.raw_user_meta_data ->> 'last_name', 60),
    left(new.raw_user_meta_data ->> 'phone', 24)
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_member();

-- Accounts made before this existed get a row too (names stay empty).
insert into public.members (id, email, first_name, last_name, phone)
select id, email, left(raw_user_meta_data ->> 'first_name', 60), left(raw_user_meta_data ->> 'last_name', 60), left(raw_user_meta_data ->> 'phone', 24)
from auth.users
on conflict (id) do nothing;


-- Party briefing: the newest gathering (by start time) fills the HUD side panels for signed-in members.
-- Add one row per party in Supabase → Table Editor → party; the site always shows the latest.
create table if not exists public.party (
  id bigint generated always as identity primary key,
  title text not null,
  starts_at timestamptz not null,
  ends_at timestamptz,
  venue text,
  address text,
  city text,
  lat double precision,
  lon double precision,
  entry text,
  capacity int,
  info text,
  dress_code text,
  dress_notes text[] not null default '{}',
  rules text[] not null default '{}',
  created_at timestamptz not null default now()
);

alter table public.party enable row level security;
grant select on public.party to authenticated;

drop policy if exists "members read party" on public.party;
create policy "members read party" on public.party
  for select to authenticated using (true);

-- Example party so the panels have something to show; only added when the table is empty.
insert into public.party (title, starts_at, ends_at, venue, address, city, lat, lon, entry, capacity, info, dress_code, dress_notes, rules)
select 'FULL MOON · NIGHT 07', '2026-11-28 23:00:00+01', '2026-11-29 06:00:00+01',
  'THE DEN (EXAMPLE)', 'EXACT ADDRESS SENT 24H BEFORE DOORS', 'REYKJAVÍK', 64.1475, -21.9425,
  'SHOW CLEARANCE 07 AT THE DOOR', 120,
  'EXAMPLE BRIEFING. EDIT THIS ROW IN TABLE EDITOR → PARTY.',
  'ALL BLACK. NO LOGOS.',
  array['BLACK FROM COLLAR TO BOOTS', 'ONE RED DETAIL ALLOWED', 'MASKS WELCOME, NOT REQUIRED', 'SHOES YOU CAN DANCE IN TILL SIX'],
  array['NO PHOTOS OR VIDEO ON THE FLOOR', 'PHONES STAY IN POCKETS', 'ASK FIRST. NO MEANS NO', 'NO PLUS-ONES WITHOUT CLEARANCE', 'WHAT HAPPENS IN THE DEN STAYS THERE', 'LOOK AFTER THE PACK']
where not exists (select 1 from public.party);
