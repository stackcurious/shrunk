export interface Env {
  DB: D1Database;
  /** Label photos for submissions awaiting review. Deleted on accept/reject (spec §6.3). */
  PHOTOS: R2Bucket;
  FDC_API_KEY: string;
  /** Bearer secret for every /v1/admin/* route. */
  ADMIN_SECRET: string;
  ENV: string;
}
