// The themes by name, each loaded on demand. Only `desk` exists (spec section 8, "Themes"); the setting `theme` picks one.
import type { Theme } from './types.ts';

export type { Edge, Motions, MotionSpec, StageContext, Theme } from './types.ts';

export const themes: Record<string, () => Promise<Theme>> = {
  // Task C2 builds ui/src/themes/desk/ and replaces this with `() => import('./desk/index.ts').then(m => m.theme)`.
  desk: () => Promise.reject(new Error('The desk theme is not built yet.')),
};
