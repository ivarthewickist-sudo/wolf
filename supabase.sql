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


-- Invite-only joining: the site offers only SIGN IN; new members join through a link like
-- https://ivarthewickist-sudo.github.io/wolf/?invite=CODE. The site sends the code with the sign-up,
-- and the trigger below refuses any new account without a valid, unused, unexpired code, so the rule
-- holds even for someone calling Supabase directly with the public key.
-- Manage codes in Table Editor -> invites (max_uses = how many people one link admits).
create table if not exists public.invites (
  code text primary key,
  note text,
  max_uses int not null default 1,
  uses int not null default 0,
  expires_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.invites enable row level security; -- no policies: the site can't read or edit codes

-- Lets the site check a link before showing the join form; reveals only yes/no for one exact code.
create or replace function public.invite_ok(c text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.invites where code = c and uses < max_uses and (expires_at is null or expires_at > now()));
$$;
grant execute on function public.invite_ok(text) to anon, authenticated;

-- Runs inside the sign-up insert, so a refused code rolls the whole account back.
-- Users you add yourself in Authentication -> Users with "Auto Confirm User" arrive already confirmed and
-- skip the check. Public sign-ups arrive unconfirmed because email confirmation is on: keep it on, since
-- turning it off would let unconfirmed-at-insert sign-ups through this bypass.
create or replace function public.check_invite() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.email_confirmed_at is not null then return new; end if;
  update public.invites set uses = uses + 1
   where code = new.raw_user_meta_data ->> 'invite'
     and uses < max_uses and (expires_at is null or expires_at > now());
  if not found then raise exception 'invite required'; end if;
  return new;
end $$;

drop trigger if exists before_auth_user_created on auth.users;
create trigger before_auth_user_created before insert on auth.users
  for each row execute function public.check_invite();

-- Record which link each member used.
alter table public.members add column if not exists invite text;
create or replace function public.handle_new_member() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.members (id, email, first_name, last_name, phone, invite)
  values (
    new.id, new.email,
    left(new.raw_user_meta_data ->> 'first_name', 60),
    left(new.raw_user_meta_data ->> 'last_name', 60),
    left(new.raw_user_meta_data ->> 'phone', 24),
    left(new.raw_user_meta_data ->> 'invite', 40)
  )
  on conflict (id) do nothing;
  return new;
end $$;


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


-- ===================== ADMIN DASHBOARD (admin.html) =====================
-- Run this section once. Then make yourself admin (put your own sign-in email in the quotes):
--   insert into public.admins (user_id) select id from auth.users where email = 'YOUR-EMAIL';
create table if not exists public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade
);
alter table public.admins enable row level security; -- no policies: only is_admin() below reads it

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.admins where user_id = (select auth.uid()));
$$;
grant execute on function public.is_admin() to authenticated;

-- New party fields: theme tag (replaces the moon line), door directions, sold-out/cancelled override,
-- and a draft switch so test parties never reach members.
alter table public.party add column if not exists theme text;
alter table public.party add column if not exists directions text;
alter table public.party add column if not exists status text check (status in ('sold_out', 'cancelled'));
alter table public.party add column if not exists published boolean not null default true;

-- Members see published parties only; admins see and edit everything.
drop policy if exists "members read party" on public.party;
create policy "members read party" on public.party
  for select to authenticated using (published or (select public.is_admin()));
grant insert, update, delete on public.party to authenticated;
drop policy if exists "admins write party" on public.party;
create policy "admins write party" on public.party
  for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

-- Internal notes live in their own table, because a column of party would be readable by every member.
create table if not exists public.party_notes (
  party_id bigint primary key references public.party (id) on delete cascade,
  notes text
);
alter table public.party_notes enable row level security;
grant select, insert, update, delete on public.party_notes to authenticated;
drop policy if exists "admins manage notes" on public.party_notes;
create policy "admins manage notes" on public.party_notes
  for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));
-- the old info text was an internal note shown to members; move it here and stop showing it
insert into public.party_notes (party_id, notes)
select id, info from public.party where coalesce(info, '') <> ''
on conflict (party_id) do nothing;

-- Admins read the whole member list (names, emails, phones); members still see only themselves.
drop policy if exists "admins read members" on public.members;
create policy "admins read members" on public.members
  for select to authenticated using ((select public.is_admin()));
