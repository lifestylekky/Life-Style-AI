# Life Style AI

Flutter ecommerce product studio with DeepSeek chat, Flux Kontext Pro image
generation, Supabase product/chat persistence, and GitHub-backed image storage.

## Production architecture

- The Flutter app calls one Supabase Edge Function over HTTPS.
- Flux, DeepSeek, GitHub, and Supabase service-role credentials stay in Edge
  Function secrets and are never bundled in the app.
- Product records and ordered chat messages live in Supabase Postgres with
  server-generated timestamps.
- Reference and generated image bytes live under `app-images/` in the public
  GitHub repository; Supabase stores their stable raw URLs.
- Database tables have RLS enabled and no client policies. The Edge Function is
  the only database writer.

## Deploy Supabase

Link the project and apply migrations:

```bash
npx supabase login
npx supabase link --project-ref xlgkxryniiokathvmtxo
npx supabase db push --linked
```

Configure these Edge Function secrets in the Supabase dashboard or CLI:

```text
FLUXAPI_KEY
DEEPSEEK_API_KEY
GITHUB_TOKEN
GITHUB_REPOSITORY=lifestylekky/Life-Style-AI
GITHUB_BRANCH=assets
PROXY_SIGNING_SECRET
APP_CLIENT_TOKEN
PUBLIC_BASE_URL=https://xlgkxryniiokathvmtxo.supabase.co/functions/v1/flux-proxy
```

The GitHub token needs access only to `lifestylekky/Life-Style-AI` with
repository **Contents: Read and write** permission. Image commits stay on the
`assets` branch so they do not advance the application source branch. Deploy
directly to Supabase; local Docker is not required:

```bash
npx supabase functions deploy flux-proxy \
  --no-verify-jwt \
  --project-ref xlgkxryniiokathvmtxo
```

Verify Flux authentication:

```bash
curl https://xlgkxryniiokathvmtxo.supabase.co/functions/v1/flux-proxy/health
```

## Build Android

`APP_CLIENT_TOKEN` must match the Supabase secret. It protects the private app
API from anonymous internet traffic; provider keys must never be passed as Dart
defines.

```bash
flutter build apk --release \
  --dart-define=SUPABASE_FUNCTION_URL=https://xlgkxryniiokathvmtxo.supabase.co/functions/v1/flux-proxy \
  --dart-define=APP_CLIENT_TOKEN=your_app_client_token
```

Install `build/app/outputs/flutter-apk/app-release.apk`. The release works over
Wi-Fi or mobile data without the development computer.

## Verification

```bash
flutter analyze
flutter test
```

The test suite covers chat workflows, Flux submission/polling/download behavior,
poster generation, product description generation, and route disposal behavior.
