const base = process.env.HA_BASE_URL.replace(/\/+$/,''), token = process.env.HA_TOKEN;
const h = { Authorization:`Bearer ${token}`, 'Content-Type':'application/json' };
const states = await (await fetch(`${base}/api/states`, {headers:h})).json();
const nodes = new Set();
for (const s of states) {
  const m = s.entity_id.match(/^(?:select|text|sensor)\.(mcp_[a-z0-9]+)_/);
  if (m) nodes.add(m[1]);
}
console.log('stale nodes:', [...nodes].join(', ') || '(none)');
for (const n of nodes) {
  for (const [c,o] of [['select','decision'],['text','reply'],['sensor','status']]) {
    await fetch(`${base}/api/services/mqtt/publish`, {method:'POST',headers:h,
      body: JSON.stringify({ topic:`homeassistant/${c}/${n}/${o}/config`, payload:'', retain:true })});
  }
}
console.log('cleared', nodes.size, 'node(s)');
