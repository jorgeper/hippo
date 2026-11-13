// Web Mercator (EPSG:3857) as slippy-map tiles use it: world pixels at 256-pixel tiles, x to the east, y to the south.
// Pure arithmetic, shared by the place layout and the map backdrop.

export const TILE_SIZE = 256;
/** World pixels per desk unit on the map sheet: the place layout picks the zoom at this scale. */
export const MAP_PX_PER_UNIT = 8;
/** The latitude where Web Mercator's square world ends. */
export const MAX_LAT = 85.0511287798066;

const worldSize = (zoom: number) => TILE_SIZE * 2 ** zoom;

export function lonLatToWorld(lon: number, lat: number, zoom: number): { x: number; y: number } {
  const phi = (Math.max(-MAX_LAT, Math.min(MAX_LAT, lat)) * Math.PI) / 180;
  const size = worldSize(zoom);
  return { x: ((lon + 180) / 360) * size, y: ((1 - Math.log(Math.tan(phi) + 1 / Math.cos(phi)) / Math.PI) / 2) * size };
}

export function worldToLonLat(x: number, y: number, zoom: number): { lon: number; lat: number } {
  const size = worldSize(zoom);
  const n = Math.PI * (1 - (2 * y) / size);
  return { lon: (x / size) * 360 - 180, lat: (Math.atan(Math.sinh(n)) * 180) / Math.PI };
}

/** The tile holding a point, clamped to the zoom's tile range. */
export function lonLatToTile(lon: number, lat: number, zoom: number): { x: number; y: number } {
  const p = lonLatToWorld(lon, lat, zoom);
  const last = 2 ** zoom - 1;
  const tile = (v: number) => Math.max(0, Math.min(last, Math.floor(v / TILE_SIZE)));
  return { x: tile(p.x), y: tile(p.y) };
}

/** Where map tiles come from: the one image origin the page's Content-Security-Policy allows besides itself. */
export const TILE_ORIGIN = 'https://tile.openstreetmap.org';
/** The tile server's deepest zoom. */
export const MAX_TILE_ZOOM = 19;
/** A map sheet never asks for more tiles than this; a bigger sheet is drawn from a lower zoom, each tile scaled up. */
export const MAX_TILES = 24;

/** The URL of one raster tile. Throws on a tile that does not exist, so nothing else is ever asked of the tile server. */
export function tileUrl(z: number, x: number, y: number): string {
  const n = 2 ** z;
  const ok = Number.isInteger(z) && z >= 0 && z <= MAX_TILE_ZOOM && Number.isInteger(x) && Number.isInteger(y)
    && x >= 0 && x < n && y >= 0 && y < n;
  if (!ok) throw new Error(`no such map tile ${z}/${x}/${y}`);
  return `${TILE_ORIGIN}/${z}/${x}/${y}.png`;
}

/**
 * The tiles that cover a map sheet. `px`, `py`: where the tile's top-left corner lies from the sheet's top-left corner, in the
 * sheet's own pixels (world pixels at the backdrop's zoom, MAP_PX_PER_UNIT to a desk unit; x right, y down). A tile at zoom
 * `z` spans TILE_SIZE · 2^(backdrop zoom − z) of those pixels: when the sheet would need more than MAX_TILES tiles at its own
 * zoom, they come from the highest lower zoom that needs no more. Columns past the antimeridian wrap; rows past the poles are
 * left out (the sheet shows bare paper there).
 */
export function tilesFor(b: { width: number; height: number; zoom: number; centerLat: number; centerLon: number }): { z: number; x: number; y: number; px: number; py: number }[] {
  const zoom = Math.max(0, Math.min(MAX_TILE_ZOOM, Math.round(b.zoom)));
  const w = b.width * MAP_PX_PER_UNIT, h = b.height * MAP_PX_PER_UNIT;
  const c = lonLatToWorld(b.centerLon, b.centerLat, zoom);
  const left = c.x - w / 2, top = c.y - h / 2;
  for (let z = zoom; z >= 0; z--) {
    const size = TILE_SIZE * 2 ** (zoom - z), n = 2 ** z;
    const tx0 = Math.floor(left / size), tx1 = Math.ceil((left + w) / size) - 1;
    const ty0 = Math.max(0, Math.floor(top / size)), ty1 = Math.min(n - 1, Math.ceil((top + h) / size) - 1);
    const count = (tx1 - tx0 + 1) * Math.max(0, ty1 - ty0 + 1);
    if (count > MAX_TILES && z > 0) continue;
    const out: { z: number; x: number; y: number; px: number; py: number }[] = [];
    for (let ty = ty0; ty <= ty1; ty++)
      for (let tx = tx0; tx <= tx1; tx++) out.push({ z, x: ((tx % n) + n) % n, y: ty, px: tx * size - left, py: ty * size - top });
    return out.slice(0, MAX_TILES);
  }
  return [];
}
