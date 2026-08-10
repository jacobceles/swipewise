// Minimal R2 client over the S3-compatible API, signed with aws4fetch. Used by
// the publish CLI only — the Worker reaches R2 through its native binding and
// never needs credentials.

import { AwsClient } from 'aws4fetch';

export interface R2Config {
  accountId: string;
  accessKeyId: string;
  secretAccessKey: string;
  bucket: string;
}

export class R2 {
  private readonly client: AwsClient;
  private readonly base: string;

  constructor(cfg: R2Config) {
    this.client = new AwsClient({
      accessKeyId: cfg.accessKeyId,
      secretAccessKey: cfg.secretAccessKey,
      service: 's3',
      region: 'auto',
    });
    this.base = `https://${cfg.accountId}.r2.cloudflarestorage.com/${cfg.bucket}`;
  }

  /** GET an object as text, or null on 404. */
  async getText(key: string): Promise<string | null> {
    const res = await this.client.fetch(this.url(key));
    if (res.status === 404) return null;
    if (!res.ok) throw new Error(`R2 GET ${key} -> ${res.status}`);
    return res.text();
  }

  /** True if an object exists at `key` (HEAD — no body transfer). */
  async exists(key: string): Promise<boolean> {
    const res = await this.client.fetch(this.url(key), { method: 'HEAD' });
    if (res.status === 404) return false;
    if (!res.ok) throw new Error(`R2 HEAD ${key} -> ${res.status}`);
    return true;
  }

  /** PUT an object. `metadata` becomes `x-amz-meta-*` (R2 customMetadata). */
  async put(
    key: string,
    body: Uint8Array | string,
    contentType: string,
    metadata: Record<string, string> = {},
  ): Promise<void> {
    const headers: Record<string, string> = { 'content-type': contentType };
    for (const [k, v] of Object.entries(metadata)) headers[`x-amz-meta-${k}`] = v;

    const res = await this.client.fetch(this.url(key), { method: 'PUT', body, headers });
    if (!res.ok) throw new Error(`R2 PUT ${key} -> ${res.status} ${await res.text()}`);
  }

  private url(key: string): string {
    const encoded = key.split('/').map(encodeURIComponent).join('/');
    return `${this.base}/${encoded}`;
  }
}
