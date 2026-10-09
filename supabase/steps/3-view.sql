-- STEP 3 of 3: the results view for reading/exporting. Run last.
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
