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
