import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { open } from '../src/db.js';
import { createApp } from '../src/app.js';

let server, base, db;
before(async () => {
  db = open(':memory:');
  const dir = new URL('../migrations/', import.meta.url);
  for (const f of readdirSync(dir).filter((f) => f.endsWith('.up.sql')).sort())
    db.exec(readFileSync(new URL(f, dir), 'utf8'));          // every migration, in order
  db.exec("INSERT INTO menu_items (name, price) VALUES ('Phở bò', 45.5), ('Trà đá', 5)");
  server = createApp(db).listen(0);
  await new Promise((r) => server.once('listening', r));
  base = `http://localhost:${server.address().port}`;
});
after(() => server.close());

const call = async (method, path, body) => {
  const res = await fetch(base + path, { method, headers: { 'content-type': 'application/json' }, body: body && JSON.stringify(body) });
  return { status: res.status, body: await res.json() };
};

const stored = (id) => ({ ...db.prepare('SELECT price, price_vnd FROM menu_items WHERE id = ?').get(id) });

test('GET /menu/:id returns price in thousands of dong, and priceVnd in dong', async () => {
  assert.deepEqual(await call('GET', '/menu/1'), { status: 200, body: { id: 1, name: 'Phở bò', price: 45.5, priceVnd: 45500 } });
});

test('PATCH /menu/:id changes the price', async () => {
  const r = await call('PATCH', '/menu/2', { price: 6 });
  assert.equal(r.status, 200);
  assert.equal(r.body.price, 6);
});

test('PATCH with price writes both columns', async () => {
  const r = await call('PATCH', '/menu/2', { price: 7.5 });
  assert.deepEqual(r.body, { id: 2, name: 'Trà đá', price: 7.5, priceVnd: 7500 });
  assert.deepEqual(stored(2), { price: 7.5, price_vnd: 7500 });
});

test('PATCH with priceVnd (new client) writes both columns', async () => {
  const r = await call('PATCH', '/menu/2', { priceVnd: 6000 });
  assert.deepEqual(r.body, { id: 2, name: 'Trà đá', price: 6, priceVnd: 6000 });
  assert.deepEqual(stored(2), { price: 6, price_vnd: 6000 });
});

test('POST /menu writes both columns, from price or from priceVnd', async () => {
  const a = await call('POST', '/menu', { name: 'Cơm tấm', price: 35.5 });
  assert.equal(a.status, 201);
  assert.deepEqual(a.body, { id: a.body.id, name: 'Cơm tấm', price: 35.5, priceVnd: 35500 });
  assert.deepEqual(stored(a.body.id), { price: 35.5, price_vnd: 35500 });
  const b = await call('POST', '/menu', { name: 'Bún chả', priceVnd: 40000 });
  assert.equal(b.status, 201);
  assert.deepEqual(b.body, { id: b.body.id, name: 'Bún chả', price: 40, priceVnd: 40000 });
  assert.deepEqual(stored(b.body.id), { price: 40, price_vnd: 40000 });
  db.exec(`DELETE FROM menu_items WHERE id IN (${a.body.id}, ${b.body.id})`);
});

test('price and priceVnd must agree; priceVnd must be a positive integer', async () => {
  assert.equal((await call('PATCH', '/menu/2', { price: 6, priceVnd: 6000 })).status, 200);
  assert.equal((await call('PATCH', '/menu/2', { price: 6, priceVnd: 7000 })).status, 400);
  assert.equal((await call('PATCH', '/menu/2', { priceVnd: 6000.5 })).status, 400);
  assert.equal((await call('PATCH', '/menu/2', { priceVnd: -1 })).status, 400);
  assert.equal((await call('POST', '/menu', { name: 'x', priceVnd: '5000' })).status, 400);
  assert.deepEqual(stored(2), { price: 6, price_vnd: 6000 });
});

test('POST /orders totals at the current price', async () => {
  const r = await call('POST', '/orders', { items: [{ menuItemId: 1, qty: 2 }, { menuItemId: 2, qty: 1 }] });
  assert.deepEqual(r, { status: 201, body: { id: 1, total: 97 } });
});

test('errors have one shape', async () => {
  assert.deepEqual((await call('GET', '/menu/999')).body.error, 'not_found');
  assert.equal((await call('PATCH', '/menu/1', { price: -1 })).status, 400);
});
