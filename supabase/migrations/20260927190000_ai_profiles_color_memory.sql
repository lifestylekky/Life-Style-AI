alter table public.products
  add column if not exists memory_summary text not null default '',
  add column if not exists memory_last_message_id text,
  add column if not exists color_variants jsonb not null default '[]'::jsonb;

create table if not exists public.ai_prompt_profiles (
  key text primary key,
  category text not null,
  title text not null,
  content text not null,
  enabled boolean not null default true,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.ai_prompt_profiles enable row level security;
revoke all on table public.ai_prompt_profiles from anon, authenticated;

drop trigger if exists ai_prompt_profiles_set_updated_at on public.ai_prompt_profiles;
create trigger ai_prompt_profiles_set_updated_at
before update on public.ai_prompt_profiles
for each row execute function public.set_updated_at();

insert into public.ai_prompt_profiles (key, category, title, content) values
('assistant_profile', 'identity', 'Life Style assistant profile', $prompt$
You are Life Style AI, an expert ecommerce product-studio assistant for a Sri Lankan fashion and undergarment retailer. Be concise, practical, visually precise, and commercially useful. Reply in the user's casual Tanglish style when appropriate. Use the supplied product record and memory, but never invent specifications. Inspect only images explicitly attached to the current request.
$prompt$),
('product_image', 'generation', 'Ecommerce product image prompt', $prompt$
Create one production-ready English FLUX prompt for a premium ecommerce product image. Preserve the selected reference product's identity, construction, material, colours, patterns, proportions, and visible branding. Specify composition, camera angle, lighting, background, placement, realistic material detail, clean shadows, and commercial retouching. Do not invent extra products, text, logos, watermarks, hands, or props unless explicitly requested. Return only the final FLUX prompt.
$prompt$),
('color_detection', 'analysis', 'Structured colour extraction', $prompt$
Inspect only the supplied product reference. Return valid JSON with this exact shape: {"summary":"a concise customer-friendly colour-set report","colors":[{"name":"commercial colour name","hex":"#RRGGBB","generation_instruction":"precise instruction to recolour the same product while preserving everything else"}]}. List each distinct saleable colour one by one. The summary must use the headings PRIMARY, SECONDARY, ACCENTS, UNDERTONE, and LISTING COLOURS. Do not use markdown fences or add text outside JSON.
$prompt$),
('color_variant', 'generation', 'Single colour variant prompt', $prompt$
Create one production-ready English FLUX editing prompt. Change the selected reference product to the requested colour while preserving the exact product category, construction, silhouette, material texture, patterns, proportions, stitching, trims, branding, camera, pose, composition, lighting, and background. Change nothing except colour unless the request explicitly requires a physically consistent trim adjustment. Return only the final prompt.
$prompt$),
('poster', 'generation', 'Poster master prompt', $prompt$
Create one master English FLUX prompt for a finished ecommerce poster using only the explicitly supplied references. Preserve product identity, construction, material, colours, patterns, proportions, and branding. Specify hierarchy, placement, background, lighting, camera treatment, negative space, and premium commercial retouching. Do not invent logos, unreadable copy, extra products, hands, or people unless explicitly requested. Return only the final prompt.
$prompt$),
('product_name', 'catalogue', 'Product naming', $prompt$
Identify the actual ecommerce product name and category from the supplied image. Return only a natural 2-5 word name using visible material or construction plus the real category. Prefer an exact visible product name when reliable. Never make colour the main name. Do not mention background, model, gender, brand, punctuation, or explanations.
$prompt$),
('reference_match', 'safety', 'Product reference identity check', $prompt$
Compare image 1, the saved product, with image 2, the newly attached reference. Decide whether they depict the same underlying sellable product or a colour/design variant of it. Return only SAME when category, construction, silhouette, and essential design match. Return only DIFFERENT when they are different products. Ignore background, model, pose, lighting, and colour changes.
$prompt$),
('memory_summary', 'memory', 'Product conversation memory', $prompt$
Update the product memory using the previous memory and newest exchange. Return at most 100 words. Prioritize the newest confirmed product facts, user preferences, sizes, prices, colours, generation decisions, and unresolved requests. Remove superseded facts. Do not mention that this is a summary and do not use markdown headings.
$prompt$),
('description_catalogue', 'description', 'Catalogue description', $prompt$
Write an accurate catalogue description using the exact product name/category found in the reference notes when present. Extract sizes, tiered prices, material, and colours without inventing facts. Return a clean product name, a concise paragraph, then Material, Available sizes, Colours, Price, Ideal for, and Care fields.
$prompt$),
('description_whatsapp', 'description', 'Life Style WhatsApp listing', $prompt$
Return only a WhatsApp-ready listing in this structure:
🛍 *<EXACT PRODUCT NAME>*
📦 _<EXACT CATEGORY>_

For every size/price tier repeat:
📏 Sizes: *<sizes>*
💰 Price: *LKR <price using keycap emoji digits>/-*

📍 *Location*: _12, Main Street, Kattankudy 03_
📞 *Contact*: _0767051440 / 0768509808_
💬 *WhatsApp Group*: https://chat.whatsapp.com/D6oa6LZ5zeB4mApF25EPrb

🛺 *Island Wide Delivery Available.*
✨ *Life Style* ✨
_Specialist in UnderGarments_

Use *text* for bold and _text_ for italic exactly. Preserve the exact product name and category from reference notes when present. Convert price digits to keycap emoji digits (0️⃣1️⃣2️⃣3️⃣4️⃣5️⃣6️⃣7️⃣8️⃣9️⃣). Never invent missing sizes or prices.
$prompt$),
('description_social', 'description', 'Social product caption', $prompt$
Write a concise social caption using the exact product name/category from the reference notes when present. Extract sizes, prices, material, and colours without inventing facts. End with 3-5 relevant hashtags.
$prompt$)
on conflict (key) do update set
  category = excluded.category,
  title = excluded.title,
  content = excluded.content,
  enabled = true,
  version = public.ai_prompt_profiles.version + 1;

create or replace function public.sync_product(
  product_payload jsonb,
  messages_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_product_id text := product_payload->>'id';
  message jsonb;
begin
  insert into public.products (
    id, name, description, reference_description, detected_color_set,
    product_name_detected, product_image_url, color_set_image_url,
    poster_image_url, memory_summary, memory_last_message_id, color_variants
  ) values (
    v_product_id,
    coalesce(product_payload->>'name', 'Product'),
    coalesce(product_payload->>'description', ''),
    coalesce(product_payload->>'reference_description', ''),
    coalesce(product_payload->>'detected_color_set', ''),
    coalesce((product_payload->>'product_name_detected')::boolean, false),
    nullif(product_payload->>'product_image_url', ''),
    nullif(product_payload->>'color_set_image_url', ''),
    nullif(product_payload->>'poster_image_url', ''),
    coalesce(product_payload->>'memory_summary', ''),
    nullif(product_payload->>'memory_last_message_id', ''),
    coalesce(product_payload->'color_variants', '[]'::jsonb)
  )
  on conflict (id) do update set
    name = excluded.name,
    description = excluded.description,
    reference_description = excluded.reference_description,
    detected_color_set = excluded.detected_color_set,
    product_name_detected = excluded.product_name_detected,
    product_image_url = excluded.product_image_url,
    color_set_image_url = excluded.color_set_image_url,
    poster_image_url = excluded.poster_image_url,
    memory_summary = excluded.memory_summary,
    memory_last_message_id = excluded.memory_last_message_id,
    color_variants = excluded.color_variants;

  delete from public.chat_messages
  where chat_messages.product_id = v_product_id
    and not (chat_messages.id = any (
      coalesce(
        array(select item->>'id' from jsonb_array_elements(messages_payload) item),
        array[]::text[]
      )
    ));

  for message in select value from jsonb_array_elements(messages_payload)
  loop
    insert into public.chat_messages (
      id, product_id, position, text, is_user, image_urls, prompt,
      generation_prompt, image_width, image_height, model_label,
      is_image_generation_request, action_name, kind, progress
    ) values (
      message->>'id', v_product_id,
      coalesce((message->>'position')::integer, 0),
      coalesce(message->>'text', ''),
      coalesce((message->>'is_user')::boolean, false),
      coalesce(array(select jsonb_array_elements_text(message->'image_urls')), array[]::text[]),
      nullif(message->>'prompt', ''),
      nullif(message->>'generation_prompt', ''),
      nullif(message->>'image_width', '')::integer,
      nullif(message->>'image_height', '')::integer,
      nullif(message->>'model_label', ''),
      coalesce((message->>'is_image_generation_request')::boolean, false),
      coalesce(message->>'action_name', 'chat'),
      coalesce(message->>'kind', 'text'),
      coalesce((message->>'progress')::integer, 0)
    )
    on conflict (id) do update set
      position = excluded.position,
      text = excluded.text,
      is_user = excluded.is_user,
      image_urls = excluded.image_urls,
      prompt = excluded.prompt,
      generation_prompt = excluded.generation_prompt,
      image_width = excluded.image_width,
      image_height = excluded.image_height,
      model_label = excluded.model_label,
      is_image_generation_request = excluded.is_image_generation_request,
      action_name = excluded.action_name,
      kind = excluded.kind,
      progress = excluded.progress;
  end loop;

  return jsonb_build_object('id', v_product_id, 'saved', true);
end;
$$;

revoke all on function public.sync_product(jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.sync_product(jsonb, jsonb) to service_role;
