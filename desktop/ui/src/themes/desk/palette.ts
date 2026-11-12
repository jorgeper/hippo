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
  /** The tape's outline, so a label still reads where it lies on paper (the map sheet). */
  tapeOutline: 'rgba(58, 46, 24, 0.62)',
};

/** The place layout's paper map sheet. */
export const MAP = {
  /** The paper, and its back and cut edge. */
  paper: '#dcd7c8',
  back: '#d0cabb',
  edge: '#bfb8a5',
  /** The paper darkens a little toward its edges, as handled paper does. */
  age: 'rgba(110, 92, 58, 0.16)',
  /** What the desaturated tiles are multiplied with: the paper's own tone, so streets read as printed on it. */
  tint: '#ebe5d6',
  /** A small share of the tiles' own colour is kept, so water and parks still read. */
  keepColour: 0.14,
  /** Fibres speckled over the paper. */
  fibre: 'rgba(90, 80, 60, 0.05)',
  fibreLight: 'rgba(255, 255, 255, 0.10)',
  /** The two fold creases: a shaded side and a lit side. */
  crease: 'rgba(60, 50, 30, 0.16)',
  creaseLight: 'rgba(255, 255, 255, 0.30)',
  /** The neat line round the printed area, the graticule and its figures, the place names, the scale bar. */
  frame: 'rgba(48, 52, 64, 0.70)',
  grid: 'rgba(56, 70, 96, 0.30)',
  gridMinor: 'rgba(56, 70, 96, 0.13)',
  gridText: 'rgba(56, 66, 86, 0.62)',
  name: 'rgba(36, 40, 54, 0.80)',
  nameMinor: 'rgba(52, 58, 76, 0.66)',
  nameHalo: 'rgba(220, 215, 200, 0.85)',
  scaleDark: 'rgba(40, 44, 56, 0.85)',
  scaleLight: '#f4f1e8',
  attribution: 'rgba(40, 44, 56, 0.78)',
  /** The soft shadow the sheet lays on the desk. */
  shadow: 'rgba(0, 3, 10, 0.55)',
};

/**
 * The page's controls over the canvas, as CSS custom properties (styles.css reads them; nothing there names a colour).
 * Dark glass the colour of the desk, ink of the chalk, and the key light's warm tone for the one thing that is active.
 */
export const CHROME: Record<string, string> = {
  '--ui-ground': '#0d1c33',
  '--ui-ink': '#e4e9f2',
  '--ui-ink-soft': '#9babc6',
  '--ui-ink-faint': '#6c7c99',
  '--ui-glass': 'rgba(8, 17, 33, 0.72)',
  '--ui-glass-strong': 'rgba(7, 14, 28, 0.92)',
  '--ui-glass-hover': 'rgba(150, 175, 220, 0.10)',
  '--ui-line': 'rgba(170, 192, 230, 0.16)',
  '--ui-line-strong': 'rgba(170, 192, 230, 0.32)',
  '--ui-paper': '#efe9da',
  '--ui-paper-ink': '#1f2330',
  '--ui-lamp': '#ffc978',
  '--ui-lamp-glow': 'rgba(255, 201, 120, 0.45)',
  '--ui-focus': 'rgba(255, 214, 150, 0.70)',
  '--ui-danger': '#ff9d8a',
  '--ui-shadow': 'rgba(0, 4, 12, 0.45)',
  '--ui-font': 'ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif',
  '--ui-reply-font': '"Iowan Old Style", "Palatino Linotype", Palatino, Charter, Georgia, serif',
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
  chalkTextOpacity: 0.85,
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
  /** Map lettering: a book serif, italic for places. */
  map: '"Iowan Old Style", "Palatino Linotype", Palatino, Charter, Georgia, serif',
};
