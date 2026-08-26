# shrunk-api

Cloudflare Worker backend for Shrunk (Hono 4 + D1 + R2).

## Stack

- Hono 4 on Cloudflare Workers
- D1 (`shrunk`) for products, observations, submissions, alert jobs
- R2 (`shrunk-photos`) for label photos awaiting review

## Develop

```
npm run dev
npm test
npm run typecheck
```

## Deploy

```
npm run migrate:remote
npm run deploy
```

Endpoints: `GET /health`, `GET /v1/product/:gtin?locationId=`, `POST /v1/observations` (multipart crowd submission),
`GET /v1/admin/review` (paste `ADMIN_SECRET` in the browser), `GET /v1/admin/photo/:id`, `POST /v1/admin/review/:id`.

Secrets: `FDC_API_KEY`, `ADMIN_SECRET`. R2 bucket `shrunk-photos` holds label photos for pending submissions only.
