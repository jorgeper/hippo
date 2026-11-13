// When the set on the desk changes: who leaves (in the old order), who stays and who arrives (in the new order). Each
// capture is one persistent object, so the scene animates these three groups with the theme's motions.
export function reconcile(prev: string[], next: string[]): { leave: string[]; stay: string[]; arrive: string[] } {
  const before = new Set(prev), after = new Set(next);
  return {
    leave: prev.filter(id => !after.has(id)),
    stay: next.filter(id => before.has(id)),
    arrive: next.filter(id => !before.has(id)),
  };
}
