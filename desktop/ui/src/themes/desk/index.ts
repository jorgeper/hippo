// The desk theme (spec section 8): a plain dark blue desk under one soft key light, and the seven kinds of capture as thin
// realistic objects lying on it.
import type { Object3D } from 'three';
import type { DeskItem } from '../../../../src/server/wire.ts';
import type { Kind } from '../../../../src/core/types.ts';
import type { Theme } from '../types.ts';
import { setupStage } from './surface.ts';
import { buildBadge, buildPileLabel } from './labels.ts';
import { buildBackdrop, buildThickness } from './backdrop.ts';
import { motions } from './motions.ts';
import { DEPTHS, SIZES } from './objects/slab.ts';
import { buildPhoto } from './objects/photo.ts';
import { buildScreenshot } from './objects/screenshot.ts';
import { buildLink } from './objects/link.ts';
import { buildNote } from './objects/note.ts';
import { buildRecording } from './objects/recording.ts';
import { buildVideo } from './objects/video.ts';
import { buildFile } from './objects/file.ts';

const builders: Record<Kind, (item: DeskItem, lod: 'small' | 'full') => Object3D> = {
  photo: buildPhoto, screenshot: buildScreenshot, link: buildLink, note: buildNote, recording: buildRecording, video: buildVideo, file: buildFile,
};

export const theme: Theme = {
  name: 'desk',
  sizes: SIZES,
  depths: DEPTHS,
  setupStage,
  buildObject: (item, lod) => (builders[item.kind] ?? buildFile)(item, lod),
  buildPileLabel,
  buildBadge,
  buildThickness,
  buildBackdrop,
  motions,
};
