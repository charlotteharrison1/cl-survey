-- STEP 1 of 3: the table. Run this first.
-- Campaign Fringe survey database.
-- Run this once: Supabase dashboard > SQL Editor > New query > paste all > Run.
-- Safe to run again; it updates the function and keeps your data.

create table if not exists public.responses (
  email            text primary key,
  started          timestamptz not null default now(),
  step             int         not null default 0,
  earned           text[]      not null default '{}',
  coins            int         not null default 0,
  spins_drawn      int         not null default 0,
  spins_shown      int         not null default 0,
  spin_results     int[]       not null default '{}',
  prize_won        boolean     not null default false,
  how_heard        text,
  experience       text,
  talks_attended   text,
  trainings_attended text,
  ratings          jsonb       not null default '{}',
  talks_feedback   text,
  trainings_feedback text,
  attended_awards  text,
  awards_rating    int,
  awards_informative int,
  awards_comments  text,
  future_events    text,
  comments         text
);
-- Upgrade an older version of the table in place (does nothing on a fresh install).
alter table public.responses
  add column if not exists trainings_attended text,
  add column if not exists talks_feedback text,
  add column if not exists trainings_feedback text,
  add column if not exists attended_awards text,
  add column if not exists awards_rating int,
  add column if not exists awards_informative int,
  add column if not exists awards_comments text;

-- Row level security with no policies: the public key can NOT read or write this table directly.
-- The only door in is the survey() function below.
alter table public.responses enable row level security;
revoke all on public.responses from anon, authenticated;

