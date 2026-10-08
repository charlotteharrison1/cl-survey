/**
 * Survey backend. Stores one row per respondent (keyed by email) in a Google Sheet you own.
 * The server (not the browser) counts coins, draws every spin and caps prizes.
 *
 * Setup:
 *  1. Create a Google Sheet. Extensions > Apps Script. Paste this file in.
 *  2. Deploy > New deployment > Web app. Execute as: Me. Who has access: Anyone.
 *  3. Copy the web app URL into CONFIG.endpoint in index.html.
 *  4. After changing this file, Deploy > Manage deployments > pencil > New version.
 *     If the columns below change, delete the old Responses tab first.
 */
const SLICES = 50;        // must match index.html
const WIN_ODDS = 240;     // gold comes up 1 spin in this many
const PRIZE_LIMIT = 5;    // stop awarding the gold slice after this many winners
const NQ = 6;             // number of questions in index.html (bonus spin needs all of them passed)
const TALKS = [           // must match TALKS in index.html exactly
  'Fighting the Right: What Works?',
  'Training and discussion: Sisters Resist! Feminists Taking On the Trolls',
  'Progressive Pushback: Campaigning Under a Labour Government',
  'Training and discussion: Building Shared Ground with British South Asians: Challenges and Opportunities',
  'Beyond the Algorithm: Building Authentic Voices in the New Media Landscape',
  "Training session: Beyond the Feed: Reaching Voters Where Meta and Google Can't",
  'The AI Campaign Toolkit: Balancing Efficiency with Trust',
  'The Polling Problem: Tactics for a Fragmented Map',
  'Training session: Campaigning Where Voters Actually Are: The New Digital Campaign Toolkit',
  'Unions: New Tactics, Campaigns and Ideas',
  'What Moves People: Lessons from the US Campaign Trail',
  'The Campaign Fringe Awards and Drinks Reception',
];
const TEXT = { how: 'How heard', experience: 'Experience', talks: 'Talks attended', future: 'Future events', comments: 'Comments' };
const short = t => t.slice(0, 50);
const HEAD = ['Started', 'Email', 'Step', 'Earned', 'Coins', 'Spins used', 'Spin results', 'Prize won', 'How heard', 'Experience', 'Talks attended']
  .concat(TALKS.map(t => 'Enjoyed: ' + short(t)), TALKS.map(t => 'Informative: ' + short(t)), ['Session feedback', 'Future events', 'Comments']);
const col = name => HEAD.indexOf(name) + 1;

function doPost(e) {
  const lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try { return out(handle(JSON.parse(e.postData.contents))); }
  catch (err) { return out({ error: String(err.message || err) }); }
  finally { lock.releaseLock(); }
}

const out = o => ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON);
// Stop spreadsheet formulas typed by respondents from running.
const safe = v => /^[=+\-@]/.test(v) ? "'" + v : v;
const str = (v, n) => String(v == null ? '' : v).trim().slice(0, n);
const rating = v => { v = Number(v); return v >= 1 && v <= 5 ? Math.round(v) : 0; };

function handle(r) {
  const email = str(r.email, 200).toLowerCase();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) throw new Error('Bad email');
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const sh = ss.getSheetByName('Responses') || ss.insertSheet('Responses');
  if (sh.getLastRow() === 0) { sh.appendRow(HEAD); sh.setFrozenRows(1); }

  // Read the respondent's whole row once and write it back once: each sheet call is slow.
  const W = HEAD.length, last = sh.getLastRow();
  const emails = last > 1 ? sh.getRange(2, col('Email'), last - 1, 1).getValues() : [];
  const at = emails.findIndex(x => String(x[0]).toLowerCase() === email);
  const row = at >= 0 ? at + 2 : last + 1;
  const v = at >= 0 ? sh.getRange(row, 1, 1, W).getValues()[0] : HEAD.map(() => '');
  if (at < 0) { v[0] = new Date(); v[col('Email') - 1] = email; }
  const get = name => v[col(name) - 1];
  const set = (name, x) => { v[col(name) - 1] = x; };
  const save = () => {
    if (row > sh.getMaxRows()) sh.insertRowsAfter(sh.getMaxRows(), 100);
    sh.getRange(row, 1, 1, W).setValues([v.map(x => typeof x === 'string' ? safe(x) : x)]);
  };
  const earned = () => String(get('Earned')).split(',').filter(Boolean);
  const earn = key => { const e = earned(); if (e.indexOf(key) < 0) { e.push(key); set('Earned', e.join(',')); set('Coins', e.length); } };

  if (r.action === 'start') {
    earn('email');
  } else if (r.action === 'answer') {
    const x = r.value;
    let any = false;
    if (r.q === 'rate') {
      const ra = (x && x.ratings) || {};
      TALKS.forEach(t => {
        const y = ra[t]; if (!y) return;
        const e = rating(y.e), i = rating(y.i);
        if (e) { set('Enjoyed: ' + short(t), e); any = true; }
        if (i) { set('Informative: ' + short(t), i); any = true; }
      });
      const fb = str(x && x.feedback, 1000);
      if (fb) { set('Session feedback', fb); any = true; }
    } else if (TEXT[r.q]) {
      const t = Array.isArray(x) ? x.map(z => str(z, 300)).filter(Boolean).join(' | ') : str(x, 1000);
      if (t && get(TEXT[r.q]) === '') { set(TEXT[r.q], t); any = true; }
    } else throw new Error('Unknown question');
    set('Step', Math.max(Number(get('Step')) || 0, Math.min(NQ, Number(r.step) || 0)));
    if (any) earn(r.q);
  } else if (r.action === 'bonus') {
    if ((Number(get('Step')) || 0) < NQ) throw new Error('Finish the questions first');
    earn('bonus');
  } else if (r.action === 'spin') {
    const used = Number(get('Spins used')) || 0;
    if (used >= (Number(get('Coins')) || 0)) throw new Error('No spins left');
    const prizes = last > 1 ? sh.getRange(2, col('Prize won'), last - 1, 1).getValues().filter(y => y[0] === 'YES').length : 0;
    // Slice 0 is the gold one. The wheel draws 50 slices but gold comes up 1 time in WIN_ODDS.
    const gold = Math.floor(Math.random() * WIN_ODDS) === 0 && prizes < PRIZE_LIMIT;
    const slice = gold ? 0 : 1 + Math.floor(Math.random() * (SLICES - 1));
    set('Spins used', used + 1);
    set('Spin results', [get('Spin results'), slice].filter(y => y !== '').join(','));
    if (slice === 0) set('Prize won', 'YES');
    save();
    return { slice: slice, won: slice === 0, coins: Number(get('Coins')), used: used + 1 };
  } else throw new Error('Unknown action');

  save();
  return {
    coins: Number(get('Coins')) || 0, used: Number(get('Spins used')) || 0, step: Number(get('Step')) || 0,
    won: get('Prize won') === 'YES', bonus: earned().indexOf('bonus') >= 0,
    talks: String(get('Talks attended')).split(' | ').filter(Boolean),
  };
}
