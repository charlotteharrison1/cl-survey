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
  add column if not exists awards_comments text;

-- Row level security with no policies: the public key can NOT read or write this table directly.
-- The only door in is the survey() function below.
alter table public.responses enable row level security;
revoke all on public.responses from anon, authenticated;

create or replace function public.survey(req jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  talks constant text[] := array[
    'Beyond the Algorithm: Building Authentic Voices in the New Media Landscape',
    'Fighting the Right: What Works?',
    'Progressive Pushback: Campaigning Under a Labour Government',
    'The AI Campaign Toolkit: Balancing Efficiency with Trust',
    'The Polling Problem: Tactics for a Fragmented Map',
    'Unions: New Tactics, Campaigns and Ideas',
    'What Moves People: Lessons from the US Campaign Trail'
  ];
  trainings constant text[] := array[
    'Beyond the Feed: Reaching Voters Where Meta and Google Can''t',
    'Building Shared Ground with British South Asians: Challenges and Opportunities',
    'Campaigning Where Voters Actually Are: The New Digital Campaign Toolkit',
    'Sisters Resist! Feminists Taking On the Trolls'
  ];
  nq          constant int := 8;      -- number of questions in index.html
  slices      constant int := 50;     -- slices on the wheel; slice 0 is gold
  win_odds    constant int := 240;    -- gold comes up 1 draw in this many
  prize_limit constant int := 5;      -- at most this many people are ever dealt a gold result
  total       constant int := nq + 1; -- one result per question plus the bonus spin

  em   text := lower(btrim(coalesce(req->>'email', '')));
  act  text := req->>'action';
  r    public.responses%rowtype;
  q    text;
  v    jsonb;
  t    text;
  s    text;
  fb   text;
  allowed text[];
  e    int;
  i    int;
  n    int;
  golds int;
  earned_spins int;
  gained boolean := false;
  new_ratings jsonb;
begin
  if length(em) > 200 or em !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'Bad email';
  end if;

  insert into responses (email) values (em) on conflict (email) do nothing;
  select * into r from responses where email = em for update;

  if act = 'start' or act = 'seen' then
    null;   -- nothing to record; the draw and shown count are handled below
  elsif act = 'answer' then
    q := req->>'q';
    v := req->'value';
    if q in ('rate_talks', 'rate_trainings') then
      allowed := case q when 'rate_talks' then talks else trainings end;
      new_ratings := r.ratings;
      if jsonb_typeof(v) = 'object' and jsonb_typeof(v->'ratings') = 'object' then
        foreach t in array allowed loop
          if jsonb_typeof(v->'ratings'->t) = 'object' then
            e := case when (v->'ratings'->t->>'e') ~ '^[1-5]$' then (v->'ratings'->t->>'e')::int end;
            i := case when (v->'ratings'->t->>'i') ~ '^[1-5]$' then (v->'ratings'->t->>'i')::int end;
            if e is not null or i is not null then
              new_ratings := new_ratings || jsonb_build_object(t,
                coalesce(new_ratings->t, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object('e', e, 'i', i)));
              gained := true;
            end if;
          end if;
        end loop;
      end if;
      r.ratings := new_ratings;
      fb := case when jsonb_typeof(v) = 'object' then left(btrim(coalesce(v->>'feedback', '')), 1000) else '' end;
      if fb <> '' then
        if fb ~ '^[=+@-]' then fb := chr(39) || fb; end if;   -- stop spreadsheet apps running typed formulas
        if q = 'rate_talks' then r.talks_feedback := fb; else r.trainings_feedback := fb; end if;
        gained := true;
      end if;
    elsif q = 'awards' then
      if jsonb_typeof(v) = 'object' and (v->>'attended') in ('Yes', 'No') then
        r.attended_awards := v->>'attended';
        if v->>'attended' = 'Yes' then
          r.awards_rating := case when (v->>'rating') ~ '^[1-5]$' then (v->>'rating')::int end;
          fb := left(btrim(coalesce(v->>'comments', '')), 1000);
          if fb ~ '^[=+@-]' then fb := chr(39) || fb; end if;
          r.awards_comments := nullif(fb, '');
        else
          r.awards_rating := null;
          r.awards_comments := null;
        end if;
        gained := true;
      end if;
    elsif q = 'closing' then
      if jsonb_typeof(v) = 'object' then
        fb := left(btrim(coalesce(v->>'comments', '')), 1000);
        if fb <> '' then
          if fb ~ '^[=+@-]' then fb := chr(39) || fb; end if;   -- stop spreadsheet apps running typed formulas
          r.comments := fb;
          gained := true;
        end if;
        if jsonb_typeof(v->'future') = 'array' then
          select string_agg(left(btrim(x), 300), ' | ') into s from jsonb_array_elements_text(v->'future') x where btrim(x) <> '';
          if coalesce(s, '') <> '' then r.future_events := s; gained := true; end if;
        end if;
      end if;
    elsif q in ('how', 'experience', 'talks', 'trainings') then
      if jsonb_typeof(v) = 'array' then
        select string_agg(left(btrim(x), 300), ' | ') into s from jsonb_array_elements_text(v) x where btrim(x) <> '';
      elsif jsonb_typeof(v) = 'string' then
        s := left(btrim(v #>> '{}'), 1000);
      end if;
      s := coalesce(s, '');
      if s <> '' then
        if s ~ '^[=+@-]' then s := chr(39) || s; end if;   -- stop spreadsheet apps running typed formulas
        case q
          when 'how' then r.how_heard := s;
          when 'experience' then r.experience := s;
          when 'talks' then r.talks_attended := s;
          else r.trainings_attended := s;
        end case;
        gained := true;
      end if;
    else
      raise exception 'Unknown question';
    end if;
    n := case when (req->>'step') ~ '^[0-9]{1,3}$' then (req->>'step')::int else 0 end;
    r.step := greatest(r.step, least(nq, n));
    if gained and not (q = any(r.earned)) then
      r.earned := array_append(r.earned, q);
      r.coins := cardinality(r.earned);
    end if;
  elsif act = 'bonus' then
    if r.step < nq then raise exception 'Finish the questions first'; end if;
    if not ('bonus' = any(r.earned)) then
      r.earned := array_append(r.earned, 'bonus');
      r.coins := cardinality(r.earned);
    end if;
  else
    raise exception 'Unknown action';
  end if;

  -- Deal every spin result this person can ever get, once, on their first request.
  -- Gold comes up 1 in win_odds, at most once per person, and never after prize_limit people have one.
  if cardinality(r.spin_results) < total then
    perform pg_advisory_xact_lock(7001);   -- one person at a time, so the prize limit cannot be overshot
    select count(*) into golds from responses where email <> em and 0 = any(spin_results);
    while cardinality(r.spin_results) < total loop
      if golds < prize_limit and not (0 = any(r.spin_results)) and floor(random() * win_odds)::int = 0 then
        r.spin_results := array_append(r.spin_results, 0);
        golds := golds + 1;
      else
        r.spin_results := array_append(r.spin_results, 1 + floor(random() * (slices - 1))::int);
      end if;
    end loop;
    r.spins_drawn := total;
  end if;

  -- A win only counts once the gold result is within the spins the person has actually earned.
  earned_spins := least(cardinality(r.spin_results), r.coins);
  if earned_spins > 0 and 0 = any(r.spin_results[1:earned_spins]) then r.prize_won := true; end if;
  n := case when (req->>'shown') ~ '^[0-9]{1,3}$' then (req->>'shown')::int else 0 end;
  if n > 0 then r.spins_shown := greatest(r.spins_shown, least(earned_spins, n)); end if;

  update responses set
    step = r.step, earned = r.earned, coins = r.coins, spins_drawn = r.spins_drawn, spins_shown = r.spins_shown,
    spin_results = r.spin_results, prize_won = r.prize_won, how_heard = r.how_heard, experience = r.experience,
    talks_attended = r.talks_attended, trainings_attended = r.trainings_attended, ratings = r.ratings,
    talks_feedback = r.talks_feedback, trainings_feedback = r.trainings_feedback,
    attended_awards = r.attended_awards, awards_rating = r.awards_rating, awards_comments = r.awards_comments,
    future_events = r.future_events, comments = r.comments
  where email = em;

  return jsonb_build_object(
    'coins', r.coins, 'step', r.step, 'won', r.prize_won, 'bonus', 'bonus' = any(r.earned),
    'earned', to_jsonb(r.earned),
    'talks', coalesce(to_jsonb(string_to_array(r.talks_attended, ' | ')), '[]'::jsonb),
    'trainings', coalesce(to_jsonb(string_to_array(r.trainings_attended, ' | ')), '[]'::jsonb),
    'shown', r.spins_shown, 'results', to_jsonb(r.spin_results));
end;
$$;

revoke all on function public.survey(jsonb) from public;
grant execute on function public.survey(jsonb) to anon, authenticated;

-- One row per person with each session's ratings in its own column. Open this one to read or export results.
drop view if exists public.responses_wide;
create view public.responses_wide as
select
  email, started, step, coins, spins_drawn, spins_shown, spin_results, prize_won,
  how_heard, experience, talks_attended, trainings_attended,
  (ratings -> 'Beyond the Algorithm: Building Authentic Voices in the New Media Landscape' ->> 'e')::int as "Enjoyed: Beyond the Algorithm: Building Authentic Voices in",
  (ratings -> 'Fighting the Right: What Works?' ->> 'e')::int as "Enjoyed: Fighting the Right: What Works?",
  (ratings -> 'Progressive Pushback: Campaigning Under a Labour Government' ->> 'e')::int as "Enjoyed: Progressive Pushback: Campaigning Under a Labour G",
  (ratings -> 'The AI Campaign Toolkit: Balancing Efficiency with Trust' ->> 'e')::int as "Enjoyed: The AI Campaign Toolkit: Balancing Efficiency with",
  (ratings -> 'The Polling Problem: Tactics for a Fragmented Map' ->> 'e')::int as "Enjoyed: The Polling Problem: Tactics for a Fragmented Map",
  (ratings -> 'Unions: New Tactics, Campaigns and Ideas' ->> 'e')::int as "Enjoyed: Unions: New Tactics, Campaigns and Ideas",
  (ratings -> 'What Moves People: Lessons from the US Campaign Trail' ->> 'e')::int as "Enjoyed: What Moves People: Lessons from the US Campaign Tr",
  (ratings -> 'Beyond the Algorithm: Building Authentic Voices in the New Media Landscape' ->> 'i')::int as "Informative: Beyond the Algorithm: Building Authentic Voices in",
  (ratings -> 'Fighting the Right: What Works?' ->> 'i')::int as "Informative: Fighting the Right: What Works?",
  (ratings -> 'Progressive Pushback: Campaigning Under a Labour Government' ->> 'i')::int as "Informative: Progressive Pushback: Campaigning Under a Labour G",
  (ratings -> 'The AI Campaign Toolkit: Balancing Efficiency with Trust' ->> 'i')::int as "Informative: The AI Campaign Toolkit: Balancing Efficiency with",
  (ratings -> 'The Polling Problem: Tactics for a Fragmented Map' ->> 'i')::int as "Informative: The Polling Problem: Tactics for a Fragmented Map",
  (ratings -> 'Unions: New Tactics, Campaigns and Ideas' ->> 'i')::int as "Informative: Unions: New Tactics, Campaigns and Ideas",
  (ratings -> 'What Moves People: Lessons from the US Campaign Trail' ->> 'i')::int as "Informative: What Moves People: Lessons from the US Campaign Tr",
  (ratings -> 'Beyond the Feed: Reaching Voters Where Meta and Google Can''t' ->> 'e')::int as "Enjoyed: Beyond the Feed: Reaching Voters Where Meta and Go",
  (ratings -> 'Building Shared Ground with British South Asians: Challenges and Opportunities' ->> 'e')::int as "Enjoyed: Building Shared Ground with British South Asians: ",
  (ratings -> 'Campaigning Where Voters Actually Are: The New Digital Campaign Toolkit' ->> 'e')::int as "Enjoyed: Campaigning Where Voters Actually Are: The New Dig",
  (ratings -> 'Sisters Resist! Feminists Taking On the Trolls' ->> 'e')::int as "Enjoyed: Sisters Resist! Feminists Taking On the Trolls",
  (ratings -> 'Beyond the Feed: Reaching Voters Where Meta and Google Can''t' ->> 'i')::int as "Informative: Beyond the Feed: Reaching Voters Where Meta and Go",
  (ratings -> 'Building Shared Ground with British South Asians: Challenges and Opportunities' ->> 'i')::int as "Informative: Building Shared Ground with British South Asians: ",
  (ratings -> 'Campaigning Where Voters Actually Are: The New Digital Campaign Toolkit' ->> 'i')::int as "Informative: Campaigning Where Voters Actually Are: The New Dig",
  (ratings -> 'Sisters Resist! Feminists Taking On the Trolls' ->> 'i')::int as "Informative: Sisters Resist! Feminists Taking On the Trolls",
  talks_feedback, trainings_feedback, attended_awards, awards_rating, awards_comments, future_events, comments
from public.responses
order by started;
revoke all on public.responses_wide from anon, authenticated;
