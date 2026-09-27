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
    poster_image_url
  ) values (
    v_product_id,
    coalesce(product_payload->>'name', 'Product'),
    coalesce(product_payload->>'description', ''),
    coalesce(product_payload->>'reference_description', ''),
    coalesce(product_payload->>'detected_color_set', ''),
    coalesce((product_payload->>'product_name_detected')::boolean, false),
    nullif(product_payload->>'product_image_url', ''),
    nullif(product_payload->>'color_set_image_url', ''),
    nullif(product_payload->>'poster_image_url', '')
  )
  on conflict (id) do update set
    name = excluded.name,
    description = excluded.description,
    reference_description = excluded.reference_description,
    detected_color_set = excluded.detected_color_set,
    product_name_detected = excluded.product_name_detected,
    product_image_url = excluded.product_image_url,
    color_set_image_url = excluded.color_set_image_url,
    poster_image_url = excluded.poster_image_url;

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
      message->>'id',
      v_product_id,
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
