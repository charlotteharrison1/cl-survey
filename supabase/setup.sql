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
  ratings          jsonb       not null default '{}',
  session_feedback text,
  future_events    text,
  comments         text
);

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
    'Fighting the Right: What Works?',
    'Training and discussion: Sisters Resist! Feminists Taking On the Trolls',
    'Progressive Pushback: Campaigning Under a Labour Government',
    'Training and discussion: Building Shared Ground with British South Asians: Challenges and Opportunities',
    'Beyond the Algorithm: Building Authentic Voices in the New Media Landscape',
    'Training session: Beyond the Feed: Reaching Voters Where Meta and Google Can''t',
    'The AI Campaign Toolkit: Balancing Efficiency with Trust',
    'The Polling Problem: Tactics for a Fragmented Map',
    'Training session: Campaigning Where Voters Actually Are: The New Digital Campaign Toolkit',
    'Unions: New Tactics, Campaigns and Ideas',
    'What Moves People: Lessons from the US Campaign Trail',
    'The Campaign Fringe Awards and Drinks Reception'
  ];
  nq          constant int := 6;      -- number of questions in index.html
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
    if q = 'rate' then
      new_ratings := r.ratings;
      if jsonb_typeof(v) = 'object' and jsonb_typeof(v->'ratings') = 'object' then
        foreach t in array talks loop
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
        r.session_feedback := fb;
        gained := true;
      end if;
    elsif q in ('how', 'experience', 'talks', 'future', 'comments') then
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
          when 'future' then r.future_events := s;
          else r.comments := s;
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
    talks_attended = r.talks_attended, ratings = r.ratings, session_feedback = r.session_feedback,
    future_events = r.future_events, comments = r.comments
  where email = em;

  return jsonb_build_object(
    'coins', r.coins, 'step', r.step, 'won', r.prize_won, 'bonus', 'bonus' = any(r.earned),
    'earned', to_jsonb(r.earned),
    'talks', coalesce(to_jsonb(string_to_array(r.talks_attended, ' | ')), '[]'::jsonb),
    'shown', r.spins_shown, 'results', to_jsonb(r.spin_results));
end;
$$;

revoke all on function public.survey(jsonb) from public;
grant execute on function public.survey(jsonb) to anon, authenticated;

-- One row per person with each talk's ratings in its own column. Open this one to read or export results.
create or replace view public.responses_wide as
select
  email, started, step, coins, spins_drawn, spins_shown, spin_results, prize_won,
  how_heard, experience, talks_attended,
  (ratings -> 'Fighting the Right: What Works?' ->> 'e')::int as "Enjoyed: Fighting the Right: What Works?",
  (ratings -> 'Training and discussion: Sisters Resist! Feminists Taking On the Trolls' ->> 'e')::int as "Enjoyed: Training and discussion: Sisters Resist! Feminists",
  (ratings -> 'Progressive Pushback: Campaigning Under a Labour Government' ->> 'e')::int as "Enjoyed: Progressive Pushback: Campaigning Under a Labour G",
  (ratings -> 'Training and discussion: Building Shared Ground with British South Asians: Challenges and Opportunities' ->> 'e')::int as "Enjoyed: Training and discussion: Building Shared Ground wi",
  (ratings -> 'Beyond the Algorithm: Building Authentic Voices in the New Media Landscape' ->> 'e')::int as "Enjoyed: Beyond the Algorithm: Building Authentic Voices in",
  (ratings -> 'Training session: Beyond the Feed: Reaching Voters Where Meta and Google Can''t' ->> 'e')::int as "Enjoyed: Training session: Beyond the Feed: Reaching Voters",
  (ratings -> 'The AI Campaign Toolkit: Balancing Efficiency with Trust' ->> 'e')::int as "Enjoyed: The AI Campaign Toolkit: Balancing Efficiency with",
  (ratings -> 'The Polling Problem: Tactics for a Fragmented Map' ->> 'e')::int as "Enjoyed: The Polling Problem: Tactics for a Fragmented Map",
  (ratings -> 'Training session: Campaigning Where Voters Actually Are: The New Digital Campaign Toolkit' ->> 'e')::int as "Enjoyed: Training session: Campaigning Where Voters Actuall",
  (ratings -> 'Unions: New Tactics, Campaigns and Ideas' ->> 'e')::int as "Enjoyed: Unions: New Tactics, Campaigns and Ideas",
  (ratings -> 'What Moves People: Lessons from the US Campaign Trail' ->> 'e')::int as "Enjoyed: What Moves People: Lessons from the US Campaign Tr",
  (ratings -> 'The Campaign Fringe Awards and Drinks Reception' ->> 'e')::int as "Enjoyed: The Campaign Fringe Awards and Drinks Reception",
  (ratings -> 'Fighting the Right: What Works?' ->> 'i')::int as "Informative: Fighting the Right: What Works?",
  (ratings -> 'Training and discussion: Sisters Resist! Feminists Taking On the Trolls' ->> 'i')::int as "Informative: Training and discussion: Sisters Resist! Feminists",
  (ratings -> 'Progressive Pushback: Campaigning Under a Labour Government' ->> 'i')::int as "Informative: Progressive Pushback: Campaigning Under a Labour G",
  (ratings -> 'Training and discussion: Building Shared Ground with British South Asians: Challenges and Opportunities' ->> 'i')::int as "Informative: Training and discussion: Building Shared Ground wi",
  (ratings -> 'Beyond the Algorithm: Building Authentic Voices in the New Media Landscape' ->> 'i')::int as "Informative: Beyond the Algorithm: Building Authentic Voices in",
  (ratings -> 'Training session: Beyond the Feed: Reaching Voters Where Meta and Google Can''t' ->> 'i')::int as "Informative: Training session: Beyond the Feed: Reaching Voters",
  (ratings -> 'The AI Campaign Toolkit: Balancing Efficiency with Trust' ->> 'i')::int as "Informative: The AI Campaign Toolkit: Balancing Efficiency with",
  (ratings -> 'The Polling Problem: Tactics for a Fragmented Map' ->> 'i')::int as "Informative: The Polling Problem: Tactics for a Fragmented Map",
  (ratings -> 'Training session: Campaigning Where Voters Actually Are: The New Digital Campaign Toolkit' ->> 'i')::int as "Informative: Training session: Campaigning Where Voters Actuall",
  (ratings -> 'Unions: New Tactics, Campaigns and Ideas' ->> 'i')::int as "Informative: Unions: New Tactics, Campaigns and Ideas",
  (ratings -> 'What Moves People: Lessons from the US Campaign Trail' ->> 'i')::int as "Informative: What Moves People: Lessons from the US Campaign Tr",
  (ratings -> 'The Campaign Fringe Awards and Drinks Reception' ->> 'i')::int as "Informative: The Campaign Fringe Awards and Drinks Reception",
  session_feedback, future_events, comments
from public.responses
order by started;
revoke all on public.responses_wide from anon, authenticated;
