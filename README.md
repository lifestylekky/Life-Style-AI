# Life Style AI

Flutter ecommerce product studio with DeepSeek chat and Flux Kontext Pro image
generation through FluxAPI.ai.

## Run on the web

The included proxy keeps provider and GitHub credentials out of the Flutter
bundle. Start it before launching the app:

```bash
# Terminal 1: text-to-image only
FLUXAPI_KEY=your_fluxapi_key dart run tool/flux_proxy.dart

# Terminal 1: enable attached reference images through a public GitHub repo
FLUXAPI_KEY=your_fluxapi_key \
GITHUB_TOKEN=your_fine_grained_token \
GITHUB_REPOSITORY=owner/public-repo \
dart run tool/flux_proxy.dart

# Terminal 2
flutter run -d web-server --web-port 8082 \
  --dart-define=FLUX_PROXY_URL=http://127.0.0.1:8787
```

The GitHub token needs Contents read/write access to the configured public
repository. Optional `GITHUB_BRANCH` and `GITHUB_UPLOAD_PATH` values default to
`main` and `flux-references`. Reference files are deleted after FluxAPI.ai
finishes, but Git history and CDN caches mean they must still be considered
public.

When the proxy is behind a reverse proxy that does not forward the original
host correctly, set `PUBLIC_BASE_URL` to its public origin, for example
`https://flux-proxy.example.com`. Local development detects `127.0.0.1:8787`
automatically.

For permanent phone access, deploy the stateless Supabase Edge Function in
`supabase/functions/flux-proxy`. GitHub Pages cannot host this API because it is
static hosting; the public GitHub repository is used only for temporary Flux
reference-image URLs.

Link the Supabase CLI to a project, configure the server-only secrets, and
deploy the function:

```bash
npx supabase login
npx supabase link --project-ref YOUR_PROJECT_REF

npx supabase secrets set \
  FLUXAPI_KEY=your_fluxapi_key \
  GITHUB_TOKEN=your_fine_grained_token \
  GITHUB_REPOSITORY=lifestylekky/Life-Style-AI \
  PROXY_SIGNING_SECRET=use_a_long_random_secret

npx supabase functions deploy flux-proxy --no-verify-jwt
```

Verify the deployment and build the release app against its public HTTPS URL:

```bash
curl https://YOUR_PROJECT_REF.supabase.co/functions/v1/flux-proxy/health

flutter build apk --release \
  --dart-define=FLUX_PROXY_URL=https://YOUR_PROJECT_REF.supabase.co/functions/v1/flux-proxy
```

Install that release APK on the phone. It works on Wi-Fi or mobile data without
the development computer. Never expose `FLUXAPI_KEY`, `GITHUB_TOKEN`, or
`PROXY_SIGNING_SECRET` through `--dart-define`; all Flutter targets use the
hosted proxy.

## Run on mobile

Mobile builds also require the proxy because embedding either provider secret
in an APK or IPA would expose it. For an Android emulator, start the proxy on
the development machine and use Android's host alias:

```bash
FLUX_PROXY_HOST=0.0.0.0 \
FLUXAPI_KEY=your_fluxapi_key \
GITHUB_TOKEN=your_fine_grained_token \
GITHUB_REPOSITORY=owner/public-repo \
dart run tool/flux_proxy.dart

flutter run -d emulator-5554 \
  --dart-define=FLUX_PROXY_URL=http://10.0.2.2:8787
```

For a physical device on the same Wi-Fi network, replace `10.0.2.2` with the
development machine's LAN address, such as `192.168.1.20`. Allow port `8787`
through the local firewall. Android debug builds permit this local HTTP setup;
production Android and iOS builds should point `FLUX_PROXY_URL` to the deployed
Supabase Edge Function described above.

## Getting Started

- [Flutter setup](https://docs.flutter.dev/get-started/install)
- [FluxAPI.ai quickstart](https://docs.fluxapi.ai/quickstart)
