// ReceiptLens dashboard. Data is only ever inserted with textContent / attributes, never innerHTML.
const API = '/api';
const $ = (id) => document.getElementById(id);
const vnd = new Intl.NumberFormat('vi-VN', { style: 'currency', currency: 'VND', maximumFractionDigits: 0 });
const day = new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeZone: 'Asia/Ho_Chi_Minh' });
const STATUS = { uploaded: 'Reading…', parsed: 'Read', corrected: 'Corrected', failed: 'Failed' };
let pollTimer = null;
let current = null; // receipt open in the dialog

async function api(path, opts) {
  const r = await fetch(API + path, opts);
  if (!r.ok) {
    let detail = r.statusText;
    try { detail = (await r.json()).detail || detail; } catch { /* not JSON */ }
    throw new Error(typeof detail === 'string' ? detail : 'Request rejected');
  }
  return r;
}

function cell(text, cls) {
  const td = document.createElement('td');
  td.textContent = text;
  if (cls) td.className = cls;
  return td;
}

async function loadReceipts() {
  const list = await (await api('/receipts?limit=100')).json();
  const rows = $('rows');
  rows.replaceChildren();
  if (!list.length) {
    const tr = document.createElement('tr');
    tr.append(cell('No receipts yet. Add one above.', 'empty'));
    tr.firstChild.colSpan = 4;
    rows.append(tr);
  }
  for (const r of list) {
    const tr = document.createElement('tr');
    tr.tabIndex = 0;
    tr.append(
      cell(day.format(new Date(r.purchased_at || r.created_at))),
      cell(r.merchant || '—'),
      cell(r.total_vnd == null ? '—' : vnd.format(r.total_vnd), 'num'),
    );
    const st = cell(STATUS[r.status] || r.status);
    st.className = `badge ${r.status}`;
    tr.append(st);
    tr.addEventListener('click', () => openDetail(r.id));
    tr.addEventListener('keydown', (e) => { if (e.key === 'Enter') openDetail(r.id); });
    rows.append(tr);
  }
  // Keep refreshing while OCR is still running on something.
  clearTimeout(pollTimer);
  if (list.some((r) => r.status === 'uploaded')) pollTimer = setTimeout(refresh, 2000);
}

async function loadStats() {
  const stats = await (await api('/stats/monthly')).json();
  const box = $('stats');
  box.replaceChildren();
  if (!stats.length) {
    const p = document.createElement('p');
    p.className = 'empty';
    p.textContent = 'No totals yet.';
    box.append(p);
    return;
  }
  const max = Math.max(...stats.map((s) => s.total_vnd), 1);
  for (const s of stats.slice(0, 12)) {
    const row = document.createElement('div');
    row.className = 'bar';
    const label = document.createElement('span');
    label.textContent = s.month;
    const track = document.createElement('span');
    track.className = 'track';
    const fill = document.createElement('span');
    fill.className = 'fill';
    fill.style.width = `${(100 * s.total_vnd) / max}%`;
    track.append(fill);
    const value = document.createElement('span');
    value.className = 'num';
    value.textContent = `${vnd.format(s.total_vnd)} · ${s.count}`;
    row.append(label, track, value);
    box.append(row);
  }
}

function refresh() {
  loadReceipts().catch((e) => say('msg', `Could not load receipts: ${e.message}`, true));
  loadStats().catch(() => {});
}

function say(id, text, bad = false) {
  const el = $(id);
  el.textContent = text;
  el.classList.toggle('bad', bad);
}

async function upload(file) {
  if (!file) return;
  if (file.size > 10 * 1024 * 1024) return say('msg', 'That file is larger than 10 MB.', true);
  const body = new FormData();
  body.append('file', file);
  say('msg', 'Uploading…');
  try {
    await api('/receipts', { method: 'POST', body });
    say('msg', 'Uploaded. Reading the receipt, this takes a few seconds.');
    refresh();
  } catch (e) {
    say('msg', `Upload failed: ${e.message}`, true);
  }
}

// <input type="datetime-local"> works in local time; show/save Vietnam time explicitly.
function toLocalInput(iso) {
  if (!iso) return '';
  const vn = new Date(new Date(iso).getTime() + 7 * 3600 * 1000);
  return vn.toISOString().slice(0, 16);
}

async function openDetail(id) {
  current = await (await api(`/receipts/${id}`)).json();
  const f = $('edit');
  f.merchant.value = current.merchant || '';
  f.total_vnd.value = current.total_vnd ?? '';
  f.purchased_at.value = toLocalInput(current.purchased_at);
  $('d-raw').textContent = current.raw_text || '(no text yet)';
  say('d-msg', '');
  const img = $('d-img');
  if (img.src.startsWith('blob:')) URL.revokeObjectURL(img.src);
  img.removeAttribute('src');
  $('detail').showModal();
  const blob = await (await api(`/receipts/${id}/image`)).blob();
  img.src = URL.createObjectURL(blob);
}

$('edit').addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = e.target;
  const patch = {};
  if (f.merchant.value.trim()) patch.merchant = f.merchant.value.trim();
  if (f.total_vnd.value !== '') patch.total_vnd = Number(f.total_vnd.value);
  if (f.purchased_at.value) patch.purchased_at = `${f.purchased_at.value}:00+07:00`;
  try {
    await api(`/receipts/${current.id}`, {
      method: 'PATCH', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(patch),
    });
    say('d-msg', 'Saved.');
    refresh();
  } catch (err) {
    say('d-msg', `Not saved: ${err.message}`, true);
  }
});

$('file').addEventListener('change', (e) => upload(e.target.files[0]));
const drop = $('drop');
['dragenter', 'dragover'].forEach((t) => drop.addEventListener(t, (e) => { e.preventDefault(); drop.classList.add('over'); }));
['dragleave', 'drop'].forEach((t) => drop.addEventListener(t, () => drop.classList.remove('over')));
drop.addEventListener('drop', (e) => { e.preventDefault(); upload(e.dataTransfer.files[0]); });

refresh();
