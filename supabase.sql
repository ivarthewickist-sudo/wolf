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
