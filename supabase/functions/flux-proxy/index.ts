const fluxApiBase = "https://api.fluxapi.ai";
const deepSeekApiUrl = "https://api.deepseek.com/chat/completions";
const githubApiBase = "https://api.github.com";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-app-token",
};

type GitHubUpload = {
  path: string;
  sha: string;
  downloadUrl: string;
};

type PollToken = {
  kind: "poll";
  taskId: string;
  createdAt: number;
  reference?: GitHubUpload;
};

type ImageToken = {
  kind: "image";
  imageUrl: string;
  createdAt: number;
};

type SignedToken = PollToken | ImageToken;

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  try {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname.endsWith("/health")) {
      return await health();
    }
    if (!authorized(request)) {
      return json({ error: "Not authorized" }, 401);
    }
    if (request.method === "POST" && url.pathname.endsWith("/v1/deepseek")) {
      return await deepSeek(request);
    }
    if (request.method === "POST" && url.pathname.endsWith("/v1/assets")) {
      return await storeAsset(request);
    }
    if (request.method === "GET" && url.pathname.endsWith("/v1/products")) {
      return await loadProducts();
    }
    if (request.method === "PUT" && url.pathname.endsWith("/v1/products/sync")) {
      return await syncProduct(request);
    }
    if (request.method === "DELETE" && url.pathname.endsWith("/v1/products")) {
      return await deleteProduct(url);
    }
    if (
      request.method === "POST" &&
      url.pathname.endsWith("/v1/flux-pro-1.1")
    ) {
      return await submit(request, publicBase(url));
    }
    if (
      request.method === "GET" &&
      url.pathname.endsWith("/v1/get_result")
    ) {
      return await poll(url, publicBase(url));
    }
    if (request.method === "GET" && url.pathname.endsWith("/v1/image")) {
      return await image(url);
    }
    return json({ error: "Not found" }, 404);
  } catch (error) {
    console.error(error);
    if (error instanceof HttpError) {
      return json({ error: error.message }, error.status);
    }
    return json({ error: `FLUX proxy request failed: ${errorMessage(error)}` }, 502);
  }
});

function authorized(request: Request): boolean {
  const expected = requiredSecret("APP_CLIENT_TOKEN");
  const received = request.headers.get("x-app-token") ?? "";
  if (received.length !== expected.length) return false;
  let difference = 0;
  for (let index = 0; index < expected.length; index++) {
    difference |= expected.charCodeAt(index) ^ received.charCodeAt(index);
  }
  return difference === 0;
}

async function health(): Promise<Response> {
  const apiKey = requiredSecret("FLUXAPI_KEY");
  const response = await fetch(
    `${fluxApiBase}/api/v1/flux/kontext/record-info?taskId=auth-check`,
    { headers: fluxHeaders(apiKey) },
  );
  const payload = await responseObject(response);
  const authenticated = response.ok && payload.code !== 401;
  return json({
    status: authenticated ? "ok" : "misconfigured",
    authenticated,
    provider: "FluxAPI.ai",
    referenceUploads: githubConfigured(),
    ...(authenticated
      ? {}
      : { error: `FluxAPI.ai returned HTTP ${response.status}: ${payload.msg ?? "authentication failed"}` }),
  });
}

async function deepSeek(request: Request): Promise<Response> {
  const apiKey = requiredSecret("DEEPSEEK_API_KEY");
  const body = await request.text();
  const upstream = await fetch(deepSeekApiUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body,
  });
  const headers = new Headers(corsHeaders);
  headers.set("Content-Type", upstream.headers.get("content-type") ?? "application/json");
  return new Response(upstream.body, { status: upstream.status, headers });
}

async function storeAsset(request: Request): Promise<Response> {
  const incoming = await request.json() as Record<string, unknown>;
  if (typeof incoming.bytes !== "string" || !incoming.bytes) {
    throw new HttpError(400, "Image bytes are required.");
  }
  const productId = safePathPart(incoming.product_id, "unassigned");
  const kind = safePathPart(incoming.kind, "image");
  const upload = await uploadPermanentAsset(incoming.bytes, productId, kind);
  return json({ url: upload.downloadUrl });
}

async function loadProducts(): Promise<Response> {
  const productsUrl = restUrl("products");
  productsUrl.searchParams.set("select", "*");
  productsUrl.searchParams.set("order", "created_at.desc");
  const messagesUrl = restUrl("chat_messages");
  messagesUrl.searchParams.set("select", "*");
  messagesUrl.searchParams.set("order", "product_id.asc,position.asc");

  const [productsResponse, messagesResponse] = await Promise.all([
    fetch(productsUrl, { headers: serviceRoleHeaders() }),
    fetch(messagesUrl, { headers: serviceRoleHeaders() }),
  ]);
  if (!productsResponse.ok || !messagesResponse.ok) {
    throw new Error(
      `Database load failed (${productsResponse.status}/${messagesResponse.status}).`,
    );
  }
  const products = await productsResponse.json() as Array<Record<string, unknown>>;
  const messages = await messagesResponse.json() as Array<Record<string, unknown>>;
  const grouped = new Map<string, Array<Record<string, unknown>>>();
  for (const message of messages) {
    const productId = String(message.product_id ?? "");
    const current = grouped.get(productId) ?? [];
    current.push(message);
    grouped.set(productId, current);
  }
  return json({
    products: products.map((product) => ({
      ...product,
      messages: grouped.get(String(product.id ?? "")) ?? [],
    })),
  });
}

async function syncProduct(request: Request): Promise<Response> {
  const incoming = await request.json() as Record<string, unknown>;
  const product = objectValue(incoming.product);
  const messages = Array.isArray(incoming.messages) ? incoming.messages : [];
  if (!product || typeof product.id !== "string" || !product.id) {
    throw new HttpError(400, "A product id is required.");
  }
  const response = await fetch(`${requiredSecret("SUPABASE_URL")}/rest/v1/rpc/sync_product`, {
    method: "POST",
    headers: serviceRoleHeaders(true),
    body: JSON.stringify({ product_payload: product, messages_payload: messages }),
  });
  if (!response.ok) {
    throw new Error(`Database sync failed (${response.status}): ${await response.text()}`);
  }
  return json({ saved: true, id: product.id });
}

async function deleteProduct(url: URL): Promise<Response> {
  const productId = url.searchParams.get("id")?.trim();
  if (!productId) throw new HttpError(400, "A product id is required.");
  const endpoint = restUrl("products");
  endpoint.searchParams.set("id", `eq.${productId}`);
  const response = await fetch(endpoint, {
    method: "DELETE",
    headers: serviceRoleHeaders(),
  });
  if (!response.ok) {
    throw new Error(`Database delete failed (${response.status}): ${await response.text()}`);
  }
  return json({ deleted: true, id: productId });
}

async function submit(request: Request, base: string): Promise<Response> {
  const apiKey = requiredSecret("FLUXAPI_KEY");
  const incoming = await request.json() as Record<string, unknown>;
  const prompt = typeof incoming.prompt === "string" ? incoming.prompt.trim() : "";
  if (!prompt) return json({ error: "A non-empty prompt is required." }, 400);

  let reference: GitHubUpload | undefined;
  if (typeof incoming.image_prompt === "string" && incoming.image_prompt) {
    reference = await uploadReference(incoming.image_prompt);
  }

  try {
    const response = await fetch(`${fluxApiBase}/api/v1/flux/kontext/generate`, {
      method: "POST",
      headers: fluxHeaders(apiKey, true),
      body: JSON.stringify({
        prompt,
        aspectRatio: aspectRatio(incoming.width, incoming.height),
        model: "flux-kontext-pro",
        outputFormat: "jpeg",
        promptUpsampling: incoming.prompt_upsampling === true,
        safetyTolerance: incoming.safety_tolerance ?? 2,
        enableTranslation: true,
        ...(reference ? { inputImage: reference.downloadUrl } : {}),
      }),
    });
    const payload = await responseObject(response);
    const data = objectValue(payload.data);
    const taskId = typeof data?.taskId === "string" ? data.taskId : "";
    if (!response.ok || payload.code !== 200 || !taskId) {
      if (reference) await deleteReference(reference);
      return json(
        { error: payload.msg ?? "FluxAPI.ai did not create the task." },
        upstreamStatus(response, payload),
      );
    }

    const token = await signToken({
      kind: "poll",
      taskId,
      createdAt: Date.now(),
      ...(reference ? { reference } : {}),
    });
    return json({ id: taskId, polling_url: `${base}/v1/get_result?token=${token}` });
  } catch (error) {
    if (reference) await deleteReference(reference);
    throw error;
  }
}

async function poll(url: URL, base: string): Promise<Response> {
  const generation = await verifyToken(url.searchParams.get("token"), "poll") as PollToken;
  const apiKey = requiredSecret("FLUXAPI_KEY");
  const endpoint = new URL(`${fluxApiBase}/api/v1/flux/kontext/record-info`);
  endpoint.searchParams.set("taskId", generation.taskId);
  const response = await fetch(endpoint, { headers: fluxHeaders(apiKey) });
  const payload = await responseObject(response);
  if (!response.ok || payload.code !== 200) {
    return json(
      { error: payload.msg ?? "FluxAPI.ai polling failed." },
      upstreamStatus(response, payload),
    );
  }

  const data = objectValue(payload.data);
  if (!data) throw new Error("FluxAPI.ai returned invalid task data.");
  if (data.successFlag === 0) return json({ status: "Pending" });

  if (generation.reference) await deleteReference(generation.reference);
  if (data.successFlag === 1) {
    const result = objectValue(data.response);
    const imageUrl = typeof result?.resultImageUrl === "string"
      ? result.resultImageUrl
      : "";
    if (!imageUrl) throw new Error("FluxAPI.ai completed without an image URL.");
    const imageToken = await signToken({
      kind: "image",
      imageUrl,
      createdAt: Date.now(),
    });
    return json({
      status: "Ready",
      result: { sample: `${base}/v1/image?token=${imageToken}` },
    });
  }
  return json({
    status: "Failed",
    details: data.errorMessage ?? "FluxAPI.ai generation failed.",
  });
}

async function image(url: URL): Promise<Response> {
  const payload = await verifyToken(url.searchParams.get("token"), "image") as ImageToken;
  const response = await fetch(payload.imageUrl);
  if (!response.ok) {
    return json({ error: `Generated image download failed (${response.status}).` }, 502);
  }
  const headers = new Headers(corsHeaders);
  headers.set("Content-Type", response.headers.get("content-type") ?? "image/jpeg");
  headers.set("Cache-Control", "private, max-age=600");
  return new Response(response.body, { status: 200, headers });
}

async function uploadReference(encoded: string): Promise<GitHubUpload> {
  const token = requiredSecret("GITHUB_TOKEN");
  const repository = requiredSecret("GITHUB_REPOSITORY");
  if (!repository.includes("/")) throw new Error("GITHUB_REPOSITORY must be owner/repo.");
  const bytes = decodeBase64(encoded.includes(",") ? encoded.split(",").pop()! : encoded);
  if (bytes.length > 10 * 1024 * 1024) {
    throw new Error("Reference images must be 10 MB or smaller.");
  }
  const branch = Deno.env.get("GITHUB_BRANCH")?.trim() || "main";
  const prefix = (Deno.env.get("GITHUB_UPLOAD_PATH")?.trim() || "flux-references")
    .replace(/^\/+|\/+$/g, "");
  const path = `${prefix}/${Date.now()}-${randomId().slice(0, 10)}.${imageExtension(bytes)}`;
  const response = await fetch(`${githubApiBase}/repos/${repository}/contents/${path}`, {
    method: "PUT",
    headers: githubHeaders(token),
    body: JSON.stringify({
      message: "Add temporary FLUX reference image",
      content: encodeBase64(bytes),
      branch,
    }),
  });
  const payload = await responseObject(response);
  const content = objectValue(payload.content);
  if (!response.ok || typeof content?.download_url !== "string" || typeof content?.sha !== "string") {
    throw new Error(`GitHub reference upload failed (${response.status}): ${payload.message ?? "invalid response"}`);
  }
  return { path, sha: content.sha, downloadUrl: content.download_url };
}

async function uploadPermanentAsset(
  encoded: string,
  productId: string,
  kind: string,
): Promise<GitHubUpload> {
  const token = requiredSecret("GITHUB_TOKEN");
  const repository = requiredSecret("GITHUB_REPOSITORY");
  if (!repository.includes("/")) throw new Error("GITHUB_REPOSITORY must be owner/repo.");
  const bytes = decodeBase64(encoded.includes(",") ? encoded.split(",").pop()! : encoded);
  if (bytes.length > 10 * 1024 * 1024) {
    throw new HttpError(413, "Images must be 10 MB or smaller.");
  }
  const branch = Deno.env.get("GITHUB_BRANCH")?.trim() || "main";
  const path = `app-images/${productId}/${kind}/${Date.now()}-${randomId().slice(0, 10)}.${imageExtension(bytes)}`;
  const response = await fetch(`${githubApiBase}/repos/${repository}/contents/${path}`, {
    method: "PUT",
    headers: githubHeaders(token),
    body: JSON.stringify({
      message: `Store Life Style AI ${kind} image`,
      content: encodeBase64(bytes),
      branch,
    }),
  });
  const payload = await responseObject(response);
  const content = objectValue(payload.content);
  if (!response.ok || typeof content?.download_url !== "string" || typeof content?.sha !== "string") {
    throw new Error(`GitHub image upload failed (${response.status}): ${payload.message ?? "invalid response"}`);
  }
  return { path, sha: content.sha, downloadUrl: content.download_url };
}

async function deleteReference(upload: GitHubUpload): Promise<void> {
  try {
    const token = requiredSecret("GITHUB_TOKEN");
    const repository = requiredSecret("GITHUB_REPOSITORY");
    const branch = Deno.env.get("GITHUB_BRANCH")?.trim() || "main";
    await fetch(`${githubApiBase}/repos/${repository}/contents/${upload.path}`, {
      method: "DELETE",
      headers: githubHeaders(token),
      body: JSON.stringify({
        message: "Remove temporary FLUX reference image",
        sha: upload.sha,
        branch,
      }),
    });
  } catch (error) {
    console.error(`Could not clean up ${upload.path}: ${errorMessage(error)}`);
  }
}

async function signToken(payload: SignedToken): Promise<string> {
  const encoded = base64Url(new TextEncoder().encode(JSON.stringify(payload)));
  const signature = await hmac(new TextEncoder().encode(encoded));
  return `${encoded}.${base64Url(signature)}`;
}

async function verifyToken(token: string | null, kind: SignedToken["kind"]): Promise<SignedToken> {
  if (!token) throw new HttpError(404, "Unknown or expired generation token.");
  const [encoded, signature, extra] = token.split(".");
  if (!encoded || !signature || extra) throw new HttpError(404, "Invalid generation token.");
  const valid = await crypto.subtle.verify(
    "HMAC",
    await signingKey(),
    fromBase64Url(signature),
    new TextEncoder().encode(encoded),
  );
  if (!valid) throw new HttpError(404, "Invalid generation token.");
  const payload = JSON.parse(new TextDecoder().decode(fromBase64Url(encoded))) as SignedToken;
  if (payload.kind !== kind || Date.now() - payload.createdAt > 15 * 60 * 1000) {
    throw new HttpError(404, "Unknown or expired generation token.");
  }
  return payload;
}

let cachedSigningKey: Promise<CryptoKey> | undefined;
function signingKey(): Promise<CryptoKey> {
  cachedSigningKey ??= crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(requiredSecret("PROXY_SIGNING_SECRET")),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
  return cachedSigningKey;
}

async function hmac(value: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.sign("HMAC", await signingKey(), value));
}

function publicBase(url: URL): string {
  const marker = url.pathname.lastIndexOf("/v1/");
  const healthMarker = url.pathname.endsWith("/health")
    ? url.pathname.length - "/health".length
    : -1;
  const end = marker >= 0 ? marker : healthMarker >= 0 ? healthMarker : url.pathname.length;
  return `${url.origin}${url.pathname.slice(0, end)}`.replace(/\/+$/, "");
}

function aspectRatio(width: unknown, height: unknown): string {
  if (typeof width !== "number" || typeof height !== "number" || height === 0) return "1:1";
  const ratio = width / height;
  return ratio > 1.15 ? "4:3" : ratio < 0.86 ? "3:4" : "1:1";
}

function fluxHeaders(apiKey: string, jsonBody = false): HeadersInit {
  return {
    accept: "application/json",
    Authorization: `Bearer ${apiKey}`,
    ...(jsonBody ? { "Content-Type": "application/json" } : {}),
  };
}

function githubHeaders(token: string): HeadersInit {
  return {
    accept: "application/vnd.github+json",
    Authorization: `Bearer ${token}`,
    "X-GitHub-Api-Version": "2022-11-28",
    "Content-Type": "application/json",
  };
}

function githubConfigured(): boolean {
  return Boolean(Deno.env.get("GITHUB_TOKEN")?.trim() && Deno.env.get("GITHUB_REPOSITORY")?.trim());
}

function restUrl(table: string): URL {
  return new URL(`${requiredSecret("SUPABASE_URL")}/rest/v1/${table}`);
}

function serviceRoleHeaders(jsonBody = false): HeadersInit {
  const key = requiredSecret("SUPABASE_SERVICE_ROLE_KEY");
  return {
    apikey: key,
    Authorization: `Bearer ${key}`,
    ...(jsonBody ? { "Content-Type": "application/json" } : {}),
  };
}

function safePathPart(value: unknown, fallback: string): string {
  if (typeof value !== "string") return fallback;
  const safe = value.trim().replace(/[^A-Za-z0-9_-]+/g, "-").replace(/^-+|-+$/g, "");
  return safe || fallback;
}

function requiredSecret(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`${name} is not configured.`);
  return value;
}

async function responseObject(response: Response): Promise<Record<string, unknown>> {
  const value = await response.json();
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Upstream returned an invalid JSON response.");
  }
  return value as Record<string, unknown>;
}

function objectValue(value: unknown): Record<string, any> | undefined {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, any>
    : undefined;
}

function upstreamStatus(response: Response, payload: Record<string, unknown>): number {
  if (!response.ok) return response.status;
  return payload.code === 401 ? 401 : 502;
}

function json(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function randomId(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(18));
  return base64Url(bytes);
}

function imageExtension(bytes: Uint8Array): string {
  if (bytes.length >= 4 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) return "png";
  if (bytes.length >= 12 && new TextDecoder().decode(bytes.slice(0, 4)) === "RIFF" && new TextDecoder().decode(bytes.slice(8, 12)) === "WEBP") return "webp";
  return "jpg";
}

function decodeBase64(value: string): Uint8Array {
  const binary = atob(value);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function encodeBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunk = 0x8000;
  for (let index = 0; index < bytes.length; index += chunk) {
    binary += String.fromCharCode(...bytes.subarray(index, index + chunk));
  }
  return btoa(binary);
}

function base64Url(bytes: Uint8Array): string {
  return encodeBase64(bytes).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function fromBase64Url(value: string): Uint8Array {
  const base64 = value.replaceAll("-", "+").replaceAll("_", "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  return decodeBase64(base64);
}

class HttpError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}
