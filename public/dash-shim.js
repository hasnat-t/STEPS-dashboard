// Small stand-in for the Claude dashboard runtime: loads /api/teachers,
// runs the page's calcs in order and re-runs the page's draw callbacks.
(function () {
  const calcs = [];
  const listeners = [];
  const base = { teachers: { status: 'loading', data: [] }, attendance: { status: 'loading', data: [] },
    fico: { status: 'loading', data: [] }, trends: { status: 'loading', data: [] } };
  let results = {};

  function compute() {
    results = {};
    for (const c of calcs) {
      const ins = c.inputs.map((i) => base[i] || results[i] || { status: 'missing', data: [] });
      const ok = ins.every((x) => x.status === 'ok');
      if (!ok) { results[c.id] = { status: base.teachers.status, data: [] }; continue; }
      try { results[c.id] = { status: 'ok', data: c.fn(...ins.map((x) => x.data)) }; }
      catch (e) { console.error(e); results[c.id] = { status: 'error', data: [] }; }
    }
  }

  function emit() {
    compute();
    listeners.forEach((fn) => { try { fn(); } catch (e) { console.error(e); } });
  }

  async function load() {
    try {
      const r = await fetch('/api/teachers', { cache: 'no-store' });
      const j = await r.json();
      window.srMeta = j;
      base.attendance = j.attendance && j.attendance.length
        ? { status: 'ok', data: j.attendance }
        : { status: j.last_error ? 'error' : 'loading', data: [] };
      base.trends = j.trends && j.trends.length
        ? { status: 'ok', data: j.trends }
        : { status: j.last_error ? 'error' : 'loading', data: [] };
      base.fico = j.fico && j.fico.length
        ? { status: 'ok', data: j.fico }
        : { status: j.last_error ? 'error' : 'loading', data: [] };
      if (j.rows && j.rows.length) base.teachers = { status: 'ok', data: j.rows };
      else {
        base.teachers = { status: j.last_error ? 'error' : 'loading', data: [] };
        if (!j.last_error) setTimeout(load, 5000);
      }
    } catch (e) {
      base.teachers = { status: 'error', data: [] };
      setTimeout(load, 15000);
    }
    emit();
  }

  window.dash = {
    calc(id, o) { calcs.push({ id, inputs: o.inputs, fn: o.fn }); },
    data(id) { return base[id] || results[id] || { status: 'missing', data: [] }; },
    onData(fn) { listeners.push(fn); try { fn(); } catch (e) { console.error(e); } },
    setLink(name) { try { history.replaceState(null, '', '#' + name); } catch (e) { /* ignore */ } },
    refresh() { load(); },
    redraw() { listeners.forEach((fn) => { try { fn(); } catch (e) { console.error(e); } }); },
    colors: ['#47BA7D', '#333847', '#8FD3AE', '#6B7184', '#2E8F5C', '#A3A8B8', '#C9EBD7', '#1F2230'],
  };

  let lastW = window.innerWidth;
  window.addEventListener('resize', () => {
    if (Math.abs(window.innerWidth - lastW) < 24) return;
    lastW = window.innerWidth;
    listeners.forEach((fn) => { try { fn(); } catch (e) { console.error(e); } });
  });
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', load);
  else load();
})();
