export type Kind = 'link' | 'photo' | 'screenshot' | 'note' | 'recording' | 'video' | 'file';
export type Confidence = 'low' | 'medium' | 'high';
export interface Facet { version: number; status: string; generated_at: string; provenance: string; data?: unknown; [k: string]: unknown }
export interface EnrichmentDoc { schema_version: 1; schema_minor?: number; capture_id: string; layer: 'device' | 'server';
  package_digest: string; producer: { name: string; version: string; build: string }; generated_at: string;
  facets: Record<string, Facet>; [k: string]: unknown }
export interface CommentFile { id: string; added_at: string; text?: string; audioPath?: string }   // audioPath absolute
export interface RawCapture {
  id: string; dir: string;               // absolute capture directory
  datePath: string;                      // "2026/11/07"
  metadata: Record<string, any>;         // metadata.json as parsed
  packageDigest: string;
  noteBody?: string;                     // text of a typed note's text attachment
  comments: CommentFile[];               // sorted by added_at
  device?: EnrichmentDoc; deviceDir?: string;   // deviceDir holds verified assets
  server?: EnrichmentDoc; serverPath: string;   // where the server document is or would be
  serverUnreadable?: string;             // set when a server file exists and cannot be parsed, is not schema_version 1, or has no facets object
}
export interface FolderScan { captures: RawCapture[]; pending: { id: string; reason: string }[] }
