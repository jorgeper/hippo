import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';

export function homeDir(): string {
  const override = process.env.HIPPO_DESK_HOME;
  if (override) return override;
  if (process.platform === 'win32') {
    return path.join(process.env.LOCALAPPDATA ?? path.join(os.homedir(), 'AppData', 'Local'), 'hippo-desk');
  }
  if (process.platform === 'darwin') return path.join(os.homedir(), 'Library', 'Application Support', 'hippo-desk');
  return path.join(process.env.XDG_DATA_HOME ?? path.join(os.homedir(), '.local', 'share'), 'hippo-desk');
}

export interface Config { folder?: string; provider: string; enrichModel: string; askModel: string; concurrency: number; mapTiles: boolean; theme: string }

const defaults: Config = { provider: 'claude-cli', enrichModel: 'haiku', askModel: 'haiku', concurrency: 3, mapTiles: true, theme: 'desk' };

function configPath(): string { return path.join(homeDir(), 'config.json'); }

export function loadConfig(): Config {
  try {
    const raw = JSON.parse(fs.readFileSync(configPath(), 'utf8'));
    if (raw && typeof raw === 'object' && !Array.isArray(raw)) return { ...defaults, ...raw };
  } catch { /* missing or unreadable: defaults */ }
  return { ...defaults };
}

export function saveConfig(c: Config): void {
  fs.mkdirSync(homeDir(), { recursive: true });
  fs.writeFileSync(configPath(), JSON.stringify(c, null, 2) + '\n');
}

export function resolveFolder(flag?: string): string {
  if (flag) {
    const folder = path.resolve(flag);
    const c = loadConfig();
    if (c.folder !== folder) saveConfig({ ...c, folder });
    return folder;
  }
  const remembered = loadConfig().folder;
  if (remembered) return remembered;
  throw new Error('No Hippo folder known yet: pass --folder <path> once and it is remembered.');
}

export function indexPath(folder: string): string {
  const h = crypto.createHash('sha256').update(path.resolve(folder)).digest('hex').slice(0, 12);
  return path.join(homeDir(), `index-${h}.sqlite`);
}

export function thumbsDir(): string { return path.join(homeDir(), 'thumbs'); }
