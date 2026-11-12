// Every colour and font the desk theme uses. Nothing outside ui/src/themes/desk/ names a colour (spec section 8, "Themes").

export const DESK = {
  /** The surface: this blue in the middle of the view, darkening to `edge` at the corners. */
  centre: '#0f2038',
  edge: '#0a1626',
  /** What shadows darken the surface toward, and how far. */
  shadow: '#01040a',
  shadowOpacity: 0.62,
};

export const LIGHT = {
  key: '#fff3e2',
  keyIntensity: 2.7,
  sky: '#c9d6f2',
  ground: '#0a1424',
  fillIntensity: 0.55,
  environmentIntensity: 0.32,
};

export const PAPER = {
  print: '#f7f5f0',
  card: '#fbfaf6',
  cardEdge: '#e7e3da',
  note: '#f5ecd2',
  noteLine: 'rgba(120, 140, 175, 0.18)',
  sheet: '#fbfbf8',
  fold: '#e4e1d8',
  foldShade: 'rgba(0, 0, 0, 0.16)',
  block: '#ece8de',
  blockLine: 'rgba(90, 84, 70, 0.28)',
  tape: '#e8dcbc',
  tapeEdge: 'rgba(120, 100, 60, 0.18)',
  map: '#d8cfb6',
  mapInk: 'rgba(70, 64, 52, 0.75)',
};

export const INK = {
  text: '#1f2330',
  soft: '#6b7080',
  faint: '#a3a7b2',
  hand: '#2a2c3a',
  handSoft: '#5c5f70',
  /** Word-cloud inks, used in turn. */
  cloud: ['#1e2a44', '#304a7a', '#5a3e2b', '#2f5a4a', '#5b2f4f'],
  /** On the dark desk: column labels and guides. */
  chalk: '#d7deea',
  chalkGuideOpacity: 0.14,
};

export const PHONE = { bezel: '#15171c', bezelEdge: '#2c2f37', screen: '#22252c', bar: 'rgba(255, 255, 255, 0.10)', barStrong: 'rgba(255, 255, 255, 0.22)', text: 'rgba(255, 255, 255, 0.75)' };

export const TAPE = {
  shell: '#25262b',
  shellLight: '#34363d',
  screw: '#8d8f96',
  label: '#efe6cf',
  labelLine: 'rgba(80, 70, 50, 0.22)',
  window: '#121317',
  windowEdge: '#4a4c55',
  reel: '#f1efe9',
  reelHole: '#25262b',
  tape: '#5a3b22',
  /** The coloured band across a label, chosen by the capture id. */
  bands: ['#d9774b', '#4f8fa8', '#c9a23e', '#6e9a5b', '#a8607a'],
};

export const MARK = {
  play: 'rgba(12, 14, 20, 0.62)',
  playIcon: '#ffffff',
  more: 'rgba(20, 24, 34, 0.82)',
  moreText: '#ffffff',
  badge: '#f2c94c',
  badgeText: '#2a2412',
  duration: 'rgba(12, 14, 20, 0.7)',
  durationText: '#ffffff',
};

/** Placeholder washes, two colours each, chosen by the capture id. */
export const WASHES: [string, string][] = [
  ['#e9b38a', '#b9554a'], ['#9fd3b8', '#3e7f6c'], ['#a9bdf0', '#4a52a3'], ['#f0d98a', '#c7843a'],
  ['#d7a8e2', '#7a4c9e'], ['#a7d2e6', '#3d7ea6'], ['#eaa5ae', '#9a4357'], ['#cfd88f', '#667f33'],
];

export const FILE_TYPES: Record<string, string> = { pdf: '#c0473b', csv: '#2f8a57', md: '#3b6fb5', txt: '#6b7080' };
export const FILE_OTHER = '#6b7080';

export const FONT = {
  sans: 'ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif',
  /** System fonts only: nothing is fetched (the page's CSP allows no font loads from elsewhere). */
  hand: '"Bradley Hand", "Segoe Print", "Comic Sans MS", cursive',
};
