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
-- Dashboard "Invite user" creates an unconfirmed account with no code, so it is refused; use "Create new user" with Auto Confirm.
-- Codes are public-readable through invite_ok, so make them long and random (no guessable words).
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


-- Request log: every join, sign-in and password-reset request from the site is saved here for the owner.
-- Read it in Supabase → Table Editor → requests (newest first). The site can write rows but never read them.
-- Passwords are never sent. Kinds the site doesn't send yet (contact, access) are accepted for later forms.
create table if not exists public.requests (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('join', 'signin', 'reset', 'contact', 'access')),
  outcome text not null,
  email text,
  first_name text,
  last_name text,
  phone text,
  invite text,
  detail text,
  created_at timestamptz not null default now()
);

create index if not exists requests_created_idx on public.requests (created_at desc);
alter table public.requests enable row level security; -- no policies: visitors can't read the log

-- The only way in from the site. Runs as its owner so it can insert past the row level security;
-- unknown kinds are dropped, and every text field is capped in length.
-- shortcut: no per-visitor rate limit (the site can't see IPs here), so a determined spammer can fill the table; delete rows in Table Editor, or add a limit when it matters.
create or replace function public.save_request(
  kind text, outcome text, email text default null, first_name text default null, last_name text default null,
  phone text default null, invite text default null, detail text default null
) returns void language plpgsql security definer set search_path = '' as $$
begin
  if kind not in ('join', 'signin', 'reset', 'contact', 'access') then return; end if;
  insert into public.requests (kind, outcome, email, first_name, last_name, phone, invite, detail)
  values (kind, left(outcome, 40), left(email, 254), left(first_name, 60), left(last_name, 60),
          left(phone, 24), left(invite, 40), left(detail, 200));
end $$;

grant execute on function public.save_request(text, text, text, text, text, text, text, text) to anon, authenticated;
