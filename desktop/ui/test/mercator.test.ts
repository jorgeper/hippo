import test from 'node:test';
import assert from 'node:assert/strict';
import { lonLatToTile, lonLatToWorld, MAP_PX_PER_UNIT, MAX_TILES, TILE_SIZE, tilesFor, tileUrl, worldToLonLat } from '../src/layout/mercator.ts';
import type { Backdrop } from '../src/layout/types.ts';
import { MAP_TILE_ORIGIN } from '../../src/server/server.ts';

type MapBackdrop = Extract<Backdrop, { type: 'map' }>;
const sheet = (over: Partial<MapBackdrop> = {}): MapBackdrop => ({ type: 'map', x: -12, y: 0, width: 96.24, height: 60.87, zoom: 13,
  centerLat: 38.7223, centerLon: -9.1393, labels: [], ...over });

/** Asserts the tiles form one full grid over the sheet: every cell present once, the sheet's pixel rectangle inside it. */
function assertCovers(b: MapBackdrop, tiles: ReturnType<typeof tilesFor>): void {
  const z = tiles[0].z;
  const size = TILE_SIZE * 2 ** (b.zoom - z);
  const w = b.width * MAP_PX_PER_UNIT, h = b.height * MAP_PX_PER_UNIT;
  const cols = [...new Set(tiles.map(t => t.px))].sort((p, q) => p - q);
  const rows = [...new Set(tiles.map(t => t.py))].sort((p, q) => p - q);
  assert.equal(tiles.length, cols.length * rows.length, 'one tile per grid cell');
  for (let k = 1; k < cols.length; k++) assert.ok(Math.abs(cols[k] - cols[k - 1] - size) < 1e-6, 'columns touch');
  for (let k = 1; k < rows.length; k++) assert.ok(Math.abs(rows[k] - rows[k - 1] - size) < 1e-6, 'rows touch');
  assert.ok(cols[0] <= 1e-6 && cols.at(-1)! + size >= w - 1e-6, `columns ${cols[0]}..${cols.at(-1)! + size} cover 0..${w}`);
  assert.ok(rows[0] <= 1e-6 && rows.at(-1)! + size >= h - 1e-6, `rows ${rows[0]}..${rows.at(-1)! + size} cover 0..${h}`);
  // No tile lies wholly off the sheet.
  for (const t of tiles) assert.ok(t.px < w && t.px + size > 0 && t.py < h && t.py + size > 0);
  const keys = new Set(tiles.map(t => `${t.x}/${t.y}`));
  assert.equal(keys.size, tiles.length, 'no tile twice');
}

test('mercator: Lisbon at zoom 12 is tile 1944, 1569; world pixels round-trip', () => {
  assert.deepEqual(lonLatToTile(-9.1393, 38.7223, 12), { x: 1944, y: 1569 });
  assert.deepEqual(lonLatToTile(0, 0, 0), { x: 0, y: 0 });
  const p = lonLatToWorld(-9.1393, 38.7223, 12);
  assert.ok(Math.abs(p.x / 256 - 1944.5) < 0.5 && Math.abs(p.y / 256 - 1569.5) < 0.5);
  const back = worldToLonLat(p.x, p.y, 12);
  assert.ok(Math.abs(back.lon + 9.1393) < 1e-9 && Math.abs(back.lat - 38.7223) < 1e-9);
  assert.deepEqual(lonLatToWorld(0, 0, 1), { x: 256, y: 256 });
});

test('tileUrl: the OpenStreetMap tile server, the one image origin the page allows', () => {
  assert.equal(tileUrl(13, 3888, 3139), 'https://tile.openstreetmap.org/13/3888/3139.png');
  assert.ok(tileUrl(0, 0, 0).startsWith(`${MAP_TILE_ORIGIN}/`));
  for (const bad of [[-1, 0, 0], [1.5, 0, 0], [3, 8, 0], [3, 0, -1], [20, 0, 0], [NaN, 0, 0]] as [number, number, number][])
    assert.throws(() => tileUrl(...bad), /tile/, `${bad}`);
});

test('tilesFor: a sheet over central Lisbon at zoom 13 takes 1 to 24 tiles, all at zoom 13, covering it with no gaps', () => {
  const b = sheet();
  const tiles = tilesFor(b);
  assert.ok(tiles.length >= 1 && tiles.length <= 24, `${tiles.length} tiles`);
  assert.ok(tiles.every(t => t.z === 13));
  assertCovers(b, tiles);
  // The tile under the sheet's centre is the one holding its centre point.
  const c = lonLatToTile(b.centerLon, b.centerLat, 13);
  assert.ok(tiles.some(t => t.x === c.x && t.y === c.y));
  // Its pixel offset: where that tile's corner lies from the sheet's top-left corner.
  const w = lonLatToWorld(b.centerLon, b.centerLat, 13);
  const t = tiles.find(q => q.x === c.x && q.y === c.y)!;
  assert.ok(Math.abs(t.px - (c.x * 256 - (w.x - (b.width * MAP_PX_PER_UNIT) / 2))) < 1e-6);
  assert.ok(Math.abs(t.py - (c.y * 256 - (w.y - (b.height * MAP_PX_PER_UNIT) / 2))) < 1e-6);
});

test('tilesFor: a sheet that would need more than 24 tiles is drawn from a lower zoom, still covered', () => {
  for (const width of [200, 400, 1000]) {
    const b = sheet({ width, height: width * 0.6 });
    const tiles = tilesFor(b);
    assert.ok(tiles.length >= 1 && tiles.length <= MAX_TILES, `${width}: ${tiles.length}`);
    assert.ok(tiles[0].z < 13);
    assert.ok(tiles.every(t => t.z === tiles[0].z));
    assertCovers(b, tiles);
  }
});

test('tilesFor: near the edges of the world, tiles stay inside the tile range', () => {
  for (const b of [sheet({ zoom: 1, centerLon: 179, centerLat: 0 }), sheet({ zoom: 2, centerLon: -170, centerLat: 80 })]) {
    const tiles = tilesFor(b);
    assert.ok(tiles.length >= 1 && tiles.length <= MAX_TILES);
    for (const t of tiles) {
      const n = 2 ** t.z;
      assert.ok(Number.isInteger(t.x) && t.x >= 0 && t.x < n && t.y >= 0 && t.y < n, `${t.z}/${t.x}/${t.y}`);
      assert.doesNotThrow(() => tileUrl(t.z, t.x, t.y));
    }
  }
});
