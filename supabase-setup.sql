create table if not exists public.stock_opname_state (
  id text primary key check (id = 'stock-opname-team'),
  data jsonb not null,
  updated_at timestamptz not null default now(),
  version bigint not null default 1,
  updated_by uuid not null references auth.users(id)
);

create or replace function public.get_stock_opname_storage_usage()
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'measuredAt', pg_catalog.statement_timestamp(),
    'databaseBytes', pg_catalog.pg_database_size(pg_catalog.current_database()),
    'tables', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'schema', schema_info.nspname,
          'table', relation.relname,
          'bytes', pg_catalog.pg_total_relation_size(relation.oid)
        )
        order by schema_info.nspname, relation.relname
      )
      from pg_catalog.pg_class as relation
      join pg_catalog.pg_namespace as schema_info on schema_info.oid = relation.relnamespace
      where schema_info.nspname = 'public'
        and relation.relkind in ('r', 'm', 'p')
    ), '[]'::jsonb),
    'buckets', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'bucketId', bucket_usage.bucket_id,
          'bytes', bucket_usage.bytes,
          'objects', bucket_usage.objects
        )
        order by bucket_usage.bucket_id
      )
      from (
        select
          storage_object.bucket_id,
          sum(case
            when coalesce(storage_object.metadata ->> 'size', '') ~ '^[0-9]+$'
              then (storage_object.metadata ->> 'size')::bigint
            else 0
          end)::bigint as bytes,
          count(*)::bigint as objects
        from storage.objects as storage_object
        group by storage_object.bucket_id
      ) as bucket_usage
    ), '[]'::jsonb)
  );
$$;

revoke all on function public.get_stock_opname_storage_usage() from public, anon, authenticated;
grant execute on function public.get_stock_opname_storage_usage() to service_role;

alter table public.stock_opname_state
  add column if not exists version bigint not null default 1;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
    and not exists (
      select 1
        from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'stock_opname_state'
    ) then
    alter publication supabase_realtime add table public.stock_opname_state;
  end if;
end;
$$;

create table if not exists public.stock_opname_usernames (
  username text primary key check (username = lower(username) and username ~ '^[a-z0-9][a-z0-9._-]{2,29}$'),
  email text not null unique check (email = lower(email)),
  created_at timestamptz not null default now()
);

create or replace function public.list_stock_opname_chat_mentions()
returns table (username text)
language sql
stable
security definer
set search_path = ''
as $$
  select account.username
    from public.stock_opname_usernames as account
   where auth.uid() is not null
   order by account.username;
$$;

revoke all on function public.list_stock_opname_chat_mentions() from public;
revoke all on function public.list_stock_opname_chat_mentions() from anon;
grant execute on function public.list_stock_opname_chat_mentions() to authenticated;

create table if not exists public.stock_opname_device_sessions (
  user_id uuid primary key references auth.users(id) on delete cascade,
  session_id uuid not null,
  updated_at timestamptz not null default now()
);

alter table public.stock_opname_state enable row level security;
alter table public.stock_opname_usernames enable row level security;
alter table public.stock_opname_device_sessions enable row level security;

revoke all on table public.stock_opname_state from anon;
revoke all on table public.stock_opname_state from authenticated;
grant select, insert, update on table public.stock_opname_state to authenticated;
revoke all on table public.stock_opname_usernames from anon;
revoke all on table public.stock_opname_usernames from authenticated;
grant select on table public.stock_opname_usernames to service_role;
revoke all on table public.stock_opname_device_sessions from anon;
revoke all on table public.stock_opname_device_sessions from authenticated;

create or replace function public.claim_stock_opname_device_session(p_session_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
begin
  if current_user_id is null then
    raise exception 'Authentication is required to claim a device session.' using errcode = '28000';
  end if;
  if p_session_id is null then
    raise exception 'A device session ID is required.' using errcode = '22023';
  end if;

  insert into public.stock_opname_device_sessions (user_id, session_id, updated_at)
  values (current_user_id, p_session_id, pg_catalog.now())
  on conflict (user_id) do update
    set session_id = excluded.session_id,
        updated_at = excluded.updated_at;
  return true;
end;
$$;

create or replace function public.is_stock_opname_device_session_active(p_session_id uuid)
returns boolean
language sql
security definer
set search_path = ''
as $$
  select auth.uid() is not null
    and exists (
      select 1
        from public.stock_opname_device_sessions
       where user_id = auth.uid()
         and session_id = p_session_id
    );
$$;

revoke all on function public.claim_stock_opname_device_session(uuid) from public;
revoke all on function public.claim_stock_opname_device_session(uuid) from anon;
grant execute on function public.claim_stock_opname_device_session(uuid) to authenticated;
revoke all on function public.is_stock_opname_device_session_active(uuid) from public;
revoke all on function public.is_stock_opname_device_session_active(uuid) from anon;
grant execute on function public.is_stock_opname_device_session_active(uuid) to authenticated;

drop policy if exists "Team members can read shared stock opname state" on public.stock_opname_state;
create policy "Team members can read shared stock opname state"
  on public.stock_opname_state for select to authenticated
  using (auth.uid() is not null);

drop policy if exists "Team members can create shared stock opname state" on public.stock_opname_state;
create policy "Team members can create shared stock opname state"
  on public.stock_opname_state for insert to authenticated
  with check (
    auth.uid() = updated_by
    and (
      (
        coalesce(data -> 'resources' -> 'brands', '[]'::jsonb) = '[]'::jsonb
        and coalesce(data -> 'resources' -> 'picNames', '[]'::jsonb) = '[]'::jsonb
        and coalesce(data -> 'resources' -> 'androidApp', 'null'::jsonb) = 'null'::jsonb
      )
      or (
        coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'super_admin'
        and coalesce(auth.jwt() -> 'app_metadata' ->> 'owner_username', '') = 'indra'
      )
    )
  );

drop policy if exists "Team members can update shared stock opname state" on public.stock_opname_state;
create policy "Team members can update shared stock opname state"
  on public.stock_opname_state for update to authenticated
  using (auth.uid() is not null)
  with check (auth.uid() = updated_by);

create or replace function public.set_stock_opname_state_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  new.version = old.version + 1;
  return new;
end;
$$;

drop trigger if exists set_stock_opname_state_updated_at on public.stock_opname_state;
create trigger set_stock_opname_state_updated_at
  before update on public.stock_opname_state
  for each row execute function public.set_stock_opname_state_updated_at();

create or replace function public.guard_stock_opname_workspace_membership()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  current_user_id text := auth.uid()::text;
  current_user_names text[] := array_remove(array[
    lower(nullif(btrim(auth.jwt() -> 'user_metadata' ->> 'username'), '')),
    lower(nullif(btrim(auth.jwt() -> 'app_metadata' ->> 'username'), '')),
    lower(nullif(btrim(auth.jwt() ->> 'email'), ''))
  ], null);
  is_workspace_super_admin boolean :=
    coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'super_admin'
    and coalesce(auth.jwt() -> 'app_metadata' ->> 'owner_username', '') = 'indra';
  is_workspace_resource_admin boolean :=
    coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'resource_admin';
  old_workspace_ids text[];
  new_workspace_ids text[];
  removed_workspace jsonb;
  removed_session_id text;
  removed_owner_id text;
  removed_owner_names text[];
begin
  if coalesce(old.data -> 'resources', '{}'::jsonb) is distinct from coalesce(new.data -> 'resources', '{}'::jsonb)
    and (
    not is_workspace_super_admin
    and not (
      is_workspace_resource_admin
      and (new.data - 'resources') is not distinct from (old.data - 'resources')
      and jsonb_typeof(new.data -> 'resources') = 'object'
      and (coalesce(new.data -> 'resources', '{}'::jsonb) - 'brands' - 'picNames' - 'androidApp')
        is not distinct from
        (coalesce(old.data -> 'resources', '{}'::jsonb) - 'brands' - 'picNames' - 'androidApp')
    )
  ) then
    raise exception 'Only the workspace owner or a resource admin can manage shared stock opname resources.'
      using errcode = '42501';
  end if;

  select array_agg(workspace.value ->> 'id' order by workspace.value ->> 'id')
    into old_workspace_ids
    from jsonb_array_elements(coalesce(old.data -> 'workspaces', '[]'::jsonb)) as workspace(value);
  select array_agg(workspace.value ->> 'id' order by workspace.value ->> 'id')
    into new_workspace_ids
    from jsonb_array_elements(coalesce(new.data -> 'workspaces', '[]'::jsonb)) as workspace(value);

  if old_workspace_ids is distinct from new_workspace_ids then
    for removed_workspace in
      select old_workspace.value
        from jsonb_array_elements(coalesce(old.data -> 'workspaces', '[]'::jsonb)) as old_workspace(value)
       where not exists (
         select 1
           from jsonb_array_elements(coalesce(new.data -> 'workspaces', '[]'::jsonb)) as new_workspace(value)
          where new_workspace.value ->> 'id' = old_workspace.value ->> 'id'
       )
    loop
      removed_session_id := removed_workspace -> 'data' -> 'activeSession' ->> 'id';
      removed_owner_id := coalesce(
        nullif(removed_workspace -> 'data' -> 'activeSession' ->> 'createdByUserId', ''),
        nullif(removed_workspace ->> 'scheduleOwnerUserId', '')
      );
      removed_owner_names := array_remove(array[
        lower(nullif(btrim(removed_workspace -> 'data' -> 'activeSession' ->> 'createdByUsername'), '')),
        lower(nullif(btrim(removed_workspace ->> 'scheduleOwnerUsername'), ''))
      ], null);
      if (
        coalesce(removed_workspace ->> 'startedAt', '') <> ''
        or coalesce(removed_workspace -> 'data' -> 'activeSession' ->> 'status', 'active') <> 'active'
        or jsonb_array_length(coalesce(removed_workspace -> 'data' -> 'products', '[]'::jsonb)) > 0
        or jsonb_array_length(coalesce(removed_workspace -> 'data' -> 'scanEvents', '[]'::jsonb)) > 0
        or jsonb_array_length(coalesce(removed_workspace -> 'data' -> 'manualEntries', '[]'::jsonb)) > 0
        or jsonb_array_length(coalesce(removed_workspace -> 'data' -> 'workbookFiles', '[]'::jsonb)) > 0
      ) and not (
        coalesce(removed_workspace -> 'data' -> 'activeSession' ->> 'status', 'active') = 'active'
        and (
          (
            (
              is_workspace_super_admin
              or coalesce(removed_owner_id = current_user_id, false)
              or (removed_owner_id is null and removed_owner_names && current_user_names)
            )
            and not exists (
              select 1
                from jsonb_array_elements(coalesce(removed_workspace -> 'data' -> 'workbookFiles', '[]'::jsonb)) as workbook(value)
               where workbook.value ->> 'sessionId' = removed_session_id
            )
            and not exists (
              select 1
                from jsonb_array_elements(coalesce(old.data -> 'workbookFiles', '[]'::jsonb)) as workbook(value)
               where workbook.value ->> 'sessionId' = removed_session_id
            )
          )
          or exists (
            select 1
              from jsonb_array_elements(coalesce(new.data -> 'sessions', '[]'::jsonb)) as archived(value)
             where archived.value ->> 'id' = removed_session_id
               and archived.value ->> 'workspaceId' = removed_workspace ->> 'id'
               and archived.value ->> 'status' = 'completed'
               and (
                 archived.value ->> 'createdByUserId' = current_user_id
                 or is_workspace_super_admin
                 or (
                   archived.value ->> 'createdByUserId' = removed_owner_id
                   and exists (
                     select 1
                       from jsonb_array_elements_text(coalesce(removed_workspace -> 'picNames', '[]'::jsonb)) as pic(name)
                      where lower(btrim(pic.name)) = any(current_user_names)
                   )
                 )
               )
               and archived.value -> 'snapshot' -> 'activeSession' ->> 'id' = removed_session_id
               and archived.value -> 'snapshot' -> 'activeSession' ->> 'status' = 'completed'
               and (
                 archived.value -> 'snapshot' -> 'activeSession' ->> 'createdByUserId' = archived.value ->> 'createdByUserId'
                 or is_workspace_super_admin
               )
               and nullif(archived.value -> 'snapshot' -> 'activeSession' ->> 'finishedAt', '') is not null
               and not exists (
                 select 1
                   from (
                     select workbook.value
                       from jsonb_array_elements(coalesce(removed_workspace -> 'data' -> 'workbookFiles', '[]'::jsonb)) as workbook(value)
                      where workbook.value ->> 'sessionId' = removed_session_id
                     union
                     select workbook.value
                       from jsonb_array_elements(coalesce(old.data -> 'workbookFiles', '[]'::jsonb)) as workbook(value)
                      where workbook.value ->> 'sessionId' = removed_session_id
                   ) as source_workbook
                  where not exists (
                    select 1
                      from jsonb_array_elements(coalesce(archived.value -> 'workbooks', '[]'::jsonb)) as archived_workbook(value)
                     where archived_workbook.value = source_workbook.value
                  )
               )
          )
        )
      ) then
        raise exception 'Schedule cards can only be removed by their owner without an uploaded workbook or together with a complete archive.'
          using errcode = '42501';
      end if;
    end loop;
  end if;

  return new;
end;
$$;

drop trigger if exists guard_stock_opname_workspace_membership on public.stock_opname_state;
create trigger guard_stock_opname_workspace_membership
  before update on public.stock_opname_state
  for each row execute function public.guard_stock_opname_workspace_membership();

create or replace function public.is_stock_opname_master_row_deletion(
  old_workspace_data jsonb,
  new_workspace_data jsonb,
  p_workspace_id text
)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  old_products jsonb := coalesce(old_workspace_data -> 'products', '[]'::jsonb);
  new_products jsonb := coalesce(new_workspace_data -> 'products', '[]'::jsonb);
  expected_products jsonb;
  old_product jsonb;
  new_product jsonb;
  removed_product jsonb;
  removed_count integer := 0;
  matching_sku_count integer;
  product_id text;
  normalized_sku text;
  expected_serial_master jsonb;
  expected_entries jsonb;
  activity jsonb;
  history_index integer;
  entry_key text;
begin
  if (old_workspace_data - array[
      'products', 'serialMaster', 'scanEvents', 'manualEntries',
      'pjEntries', 'inboundEntries', 'historyEvents'
    ]) is distinct from
     (new_workspace_data - array[
      'products', 'serialMaster', 'scanEvents', 'manualEntries',
      'pjEntries', 'inboundEntries', 'historyEvents'
    ])
    or old_workspace_data -> 'activeSession' is distinct from new_workspace_data -> 'activeSession'
    or coalesce(old_workspace_data -> 'activeSession' ->> 'status', 'active') <> 'active'
    or not exists (
      select 1
        from jsonb_array_elements(coalesce(old_workspace_data -> 'workbookFiles', '[]'::jsonb)) as workbook(value)
       where workbook.value ->> 'sessionId' = old_workspace_data -> 'activeSession' ->> 'id'
    )
    or jsonb_array_length(old_products) <> jsonb_array_length(new_products) + 1 then
    return false;
  end if;

  for new_product in select value from jsonb_array_elements(new_products)
  loop
    if new_product ->> 'id' is null then
      return false;
    end if;
    select value into old_product
      from jsonb_array_elements(old_products)
      where value ->> 'id' = new_product ->> 'id'
      limit 1;
    if old_product is null or old_product is distinct from new_product then
      return false;
    end if;
  end loop;

  for old_product in select value from jsonb_array_elements(old_products)
  loop
    if not exists (
      select 1
        from jsonb_array_elements(new_products) as product(value)
       where product.value ->> 'id' = old_product ->> 'id'
    ) then
      removed_count := removed_count + 1;
      removed_product := old_product;
    end if;
  end loop;
  product_id := removed_product ->> 'id';
  normalized_sku := regexp_replace(lower(btrim(coalesce(removed_product ->> 'sku', ''))), '[^a-z0-9]', '', 'g');
  if removed_count <> 1 or product_id is null or normalized_sku = '' then
    return false;
  end if;

  select coalesce(jsonb_agg(product.value order by product.ordinality), '[]'::jsonb)
    into expected_products
    from jsonb_array_elements(old_products) with ordinality as product(value, ordinality)
   where product.value ->> 'id' is distinct from product_id;
  if expected_products is distinct from new_products then
    return false;
  end if;

  select count(*) into matching_sku_count
    from jsonb_array_elements(old_products) as product(value)
   where regexp_replace(lower(btrim(coalesce(product.value ->> 'sku', ''))), '[^a-z0-9]', '', 'g') = normalized_sku;

  select coalesce(jsonb_object_agg(serial.key, serial.value), '{}'::jsonb)
    into expected_serial_master
    from jsonb_each(coalesce(old_workspace_data -> 'serialMaster', '{}'::jsonb)) as serial(key, value)
   where serial.value ->> 'productId' is distinct from product_id
     and not (
       serial.value ->> 'productId' is null
       and matching_sku_count = 1
       and regexp_replace(lower(btrim(coalesce(serial.value ->> 'sku', ''))), '[^a-z0-9]', '', 'g') = normalized_sku
     );
  if expected_serial_master is distinct from coalesce(new_workspace_data -> 'serialMaster', '{}'::jsonb) then
    return false;
  end if;

  foreach entry_key in array array['scanEvents', 'manualEntries', 'pjEntries', 'inboundEntries']
  loop
    select coalesce(jsonb_agg(entry.value order by entry.ordinality), '[]'::jsonb)
      into expected_entries
      from jsonb_array_elements(coalesce(old_workspace_data -> entry_key, '[]'::jsonb))
        with ordinality as entry(value, ordinality)
     where entry.value ->> 'productId' is distinct from product_id
       and not (
         entry.value ->> 'productId' is null
         and matching_sku_count = 1
         and regexp_replace(lower(btrim(coalesce(entry.value ->> 'sku', ''))), '[^a-z0-9]', '', 'g') = normalized_sku
       );
    if expected_entries is distinct from coalesce(new_workspace_data -> entry_key, '[]'::jsonb) then
      return false;
    end if;
  end loop;

  if jsonb_array_length(coalesce(new_workspace_data -> 'historyEvents', '[]'::jsonb))
      <> jsonb_array_length(coalesce(old_workspace_data -> 'historyEvents', '[]'::jsonb)) + 1 then
    return false;
  end if;
  for history_index in 0..jsonb_array_length(coalesce(old_workspace_data -> 'historyEvents', '[]'::jsonb)) - 1
  loop
    if (old_workspace_data -> 'historyEvents' -> history_index)
        is distinct from (new_workspace_data -> 'historyEvents' -> history_index) then
      return false;
    end if;
  end loop;
  activity := new_workspace_data -> 'historyEvents'
    -> jsonb_array_length(coalesce(old_workspace_data -> 'historyEvents', '[]'::jsonb));
  if activity ->> 'type' is distinct from 'Master VEF item deleted'
    or activity ->> 'workspaceId' is distinct from p_workspace_id
    or activity ->> 'sessionId' is distinct from old_workspace_data -> 'activeSession' ->> 'id'
    or coalesce(activity ->> 'id', '') = ''
    or coalesce(activity ->> 'createdAt', '') = ''
    or coalesce(activity ->> 'description', '') = ''
    or (activity - array['id', 'type', 'description', 'workspaceId', 'sessionId', 'createdAt']) <> '{}'::jsonb then
    return false;
  end if;
  return true;
end;
$$;

create or replace function public.guard_stock_opname_session_ownership()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  current_user_id text := auth.uid()::text;
  current_user_names text[] := array_remove(array[
    lower(nullif(btrim(auth.jwt() -> 'user_metadata' ->> 'username'), '')),
    lower(nullif(btrim(auth.jwt() -> 'app_metadata' ->> 'username'), '')),
    lower(nullif(btrim(auth.jwt() ->> 'email'), ''))
  ], null);
  is_workspace_super_admin boolean :=
    coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'super_admin'
    and coalesce(auth.jwt() -> 'app_metadata' ->> 'owner_username', '') = 'indra';
  is_resource_admin boolean :=
    coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'resource_admin';
  old_workspace jsonb;
  new_workspace jsonb;
  old_workspace_data jsonb;
  new_workspace_data jsonb;
  old_active_session jsonb;
  new_active_session jsonb;
  old_owner_id text;
  new_owner_id text;
  old_session_id text;
  new_session_id text;
  old_session_has_data boolean;
  is_current_user_pic boolean;
  old_archive jsonb;
  new_archive jsonb;
  previous_archive_workspace jsonb;
  workspace_id text;
  archive_id text;
  changed_workspace_id text;
  changed_workspace_data jsonb;
  canonical_workspace_data jsonb;
  snapshot_key text;
begin
  if is_workspace_super_admin or current_user_id is null then
    return new;
  end if;

  if is_resource_admin and exists (
    select 1
      from jsonb_array_elements(coalesce(new.data -> 'workspaces', '[]'::jsonb)) as new_item(value)
      join jsonb_array_elements(coalesce(old.data -> 'workspaces', '[]'::jsonb)) as old_item(value)
        on old_item.value ->> 'id' = new_item.value ->> 'id'
     where old_item.value -> 'data' is distinct from new_item.value -> 'data'
       and coalesce(old_item.value -> 'data' -> 'activeSession' ->> 'status', 'active') = 'active'
       and old_item.value -> 'data' -> 'activeSession' ->> 'createdByUserId' is not null
       and old_item.value -> 'data' -> 'activeSession' ->> 'createdByUserId' <> current_user_id
       and not exists (
         select 1
           from jsonb_array_elements_text(coalesce(old_item.value -> 'picNames', '[]'::jsonb)) as pic(name)
          where lower(btrim(pic.name)) = any(current_user_names)
       )
  ) then
    if old.data ->> 'currentWorkspaceId' is distinct from new.data ->> 'currentWorkspaceId'
      or (old.data - array[
        'workspaces', 'products', 'serialMaster', 'scanEvents', 'manualEntries',
        'pjEntries', 'inboundEntries', 'historyEvents', 'workbookFiles',
        'activeSession', 'countMode', 'importFile', 'importMessage',
        'importDownloadedAt', 'importUploadedAt', 'layouts', 'layoutQuantities',
        'layoutNumbers'
      ]) is distinct from
      (new.data - array[
        'workspaces', 'products', 'serialMaster', 'scanEvents', 'manualEntries',
        'pjEntries', 'inboundEntries', 'historyEvents', 'workbookFiles',
        'activeSession', 'countMode', 'importFile', 'importMessage',
        'importDownloadedAt', 'importUploadedAt', 'layouts', 'layoutQuantities',
        'layoutNumbers'
      ])
      or jsonb_array_length(coalesce(old.data -> 'workspaces', '[]'::jsonb))
        <> jsonb_array_length(coalesce(new.data -> 'workspaces', '[]'::jsonb)) then
      raise exception 'Resource admins may only delete one active Master VEF item.'
        using errcode = '42501';
    end if;

    for new_workspace in
      select value from jsonb_array_elements(coalesce(new.data -> 'workspaces', '[]'::jsonb))
    loop
      workspace_id := new_workspace ->> 'id';
      select value into old_workspace
        from jsonb_array_elements(coalesce(old.data -> 'workspaces', '[]'::jsonb))
        where value ->> 'id' = workspace_id
        limit 1;
      if old_workspace is null or (old_workspace - 'data') is distinct from (new_workspace - 'data') then
        raise exception 'Resource admins may only delete one active Master VEF item.'
          using errcode = '42501';
      end if;
      if old_workspace -> 'data' is distinct from new_workspace -> 'data' then
        if old_workspace -> 'data' -> 'activeSession' ->> 'createdByUserId' is null
          or old_workspace -> 'data' -> 'activeSession' ->> 'createdByUserId' = current_user_id
          or coalesce(old_workspace -> 'data' -> 'activeSession' ->> 'status', 'active') <> 'active'
          or exists (
            select 1
              from jsonb_array_elements_text(coalesce(old_workspace -> 'picNames', '[]'::jsonb)) as pic(name)
             where lower(btrim(pic.name)) = any(current_user_names)
          ) then
          raise exception 'Resource admins may only delete one active Master VEF item.'
            using errcode = '42501';
        end if;
        if changed_workspace_id is not null
          or not public.is_stock_opname_master_row_deletion(
            coalesce(old_workspace -> 'data', '{}'::jsonb),
            coalesce(new_workspace -> 'data', '{}'::jsonb),
            workspace_id
          ) then
          raise exception 'Resource admins may only delete one active Master VEF item.'
            using errcode = '42501';
        end if;
        changed_workspace_id := workspace_id;
        changed_workspace_data := new_workspace -> 'data';
        canonical_workspace_data := old_workspace -> 'data';
      end if;
    end loop;

    if changed_workspace_id is null then
      raise exception 'Resource admins may only delete one active Master VEF item.'
        using errcode = '42501';
    end if;
    if old.data ->> 'currentWorkspaceId' = changed_workspace_id then
      foreach snapshot_key in array array[
        'products', 'serialMaster', 'scanEvents', 'manualEntries', 'pjEntries',
        'inboundEntries', 'historyEvents', 'workbookFiles', 'activeSession',
        'countMode', 'importFile', 'importMessage', 'importDownloadedAt',
        'importUploadedAt', 'layouts', 'layoutQuantities', 'layoutNumbers'
      ]
      loop
        if old.data -> snapshot_key is distinct from canonical_workspace_data -> snapshot_key
          or new.data -> snapshot_key is distinct from changed_workspace_data -> snapshot_key then
          raise exception 'Resource admins may only delete one active Master VEF item.'
            using errcode = '42501';
        end if;
      end loop;
    elsif (old.data - 'workspaces') is distinct from (new.data - 'workspaces') then
      raise exception 'Resource admins may only delete one active Master VEF item.'
        using errcode = '42501';
    end if;
    return new;
  end if;

  for new_workspace in
    select value from jsonb_array_elements(coalesce(new.data -> 'workspaces', '[]'::jsonb))
  loop
    workspace_id := new_workspace ->> 'id';
    select value into old_workspace
      from jsonb_array_elements(coalesce(old.data -> 'workspaces', '[]'::jsonb))
      where value ->> 'id' = workspace_id
      limit 1;
    if old_workspace is null then
      continue;
    end if;

    old_workspace_data := coalesce(old_workspace -> 'data', '{}'::jsonb);
    new_workspace_data := coalesce(new_workspace -> 'data', '{}'::jsonb);
    old_active_session := coalesce(old_workspace_data -> 'activeSession', '{}'::jsonb);
    new_active_session := coalesce(new_workspace_data -> 'activeSession', '{}'::jsonb);
    old_owner_id := old_active_session ->> 'createdByUserId';
    new_owner_id := new_active_session ->> 'createdByUserId';
    old_session_id := old_active_session ->> 'id';
    new_session_id := new_active_session ->> 'id';
    old_session_has_data :=
      jsonb_array_length(coalesce(old_workspace_data -> 'products', '[]'::jsonb)) > 0
      or jsonb_array_length(coalesce(old_workspace_data -> 'scanEvents', '[]'::jsonb)) > 0
      or exists (
        select 1
        from jsonb_array_elements(coalesce(old_workspace_data -> 'workbookFiles', '[]'::jsonb)) as workbook(value)
        where workbook.value ->> 'sessionId' = old_session_id
      );
    is_current_user_pic := exists (
      select 1
      from jsonb_array_elements_text(coalesce(old_workspace -> 'picNames', '[]'::jsonb)) as pic(name)
      where lower(btrim(pic.name)) = any(current_user_names)
    );

    if (old_workspace -> 'name') is distinct from (new_workspace -> 'name')
      or (old_workspace -> 'picNames') is distinct from (new_workspace -> 'picNames')
      or (old_workspace -> 'month') is distinct from (new_workspace -> 'month')
      or (old_workspace -> 'period') is distinct from (new_workspace -> 'period')
      or (old_workspace -> 'startedAt') is distinct from (new_workspace -> 'startedAt')
      or (old_workspace -> 'scheduleCreatedAt') is distinct from (new_workspace -> 'scheduleCreatedAt')
      or (old_workspace -> 'scheduleOwnerUserId') is distinct from (new_workspace -> 'scheduleOwnerUserId')
      or (old_workspace -> 'scheduleOwnerUsername') is distinct from (new_workspace -> 'scheduleOwnerUsername')
      or (old_workspace -> 'schedulePlaceholder') is distinct from (new_workspace -> 'schedulePlaceholder') then
      if coalesce(old_active_session ->> 'status', 'active') = 'active'
        and (old_session_has_data or coalesce(old_workspace ->> 'startedAt', '') <> '')
        and old_owner_id is distinct from current_user_id then
        raise exception 'This active stock opname session belongs to another user.'
          using errcode = '42501';
      end if;
    end if;

    if old_workspace_data is distinct from new_workspace_data then
      if old_session_id is distinct from new_session_id then
        if old_owner_id is not null and old_owner_id is distinct from current_user_id then
          raise exception 'Only the session owner can restart or replace the active session.'
            using errcode = '42501';
        end if;
        if new_owner_id is distinct from current_user_id then
          raise exception 'A new stock opname session must be created by its authenticated owner.'
            using errcode = '42501';
        end if;
        if coalesce(old_active_session ->> 'status', 'active') <> 'completed'
          and old_owner_id is distinct from current_user_id
          and (old_owner_id is not null or old_session_has_data) then
          raise exception 'This active stock opname session belongs to another user.'
            using errcode = '42501';
        end if;
      else
        if old_owner_id is not null
          and old_owner_id is distinct from current_user_id
          and not (coalesce(old_active_session ->> 'status', 'active') = 'active' and is_current_user_pic) then
          raise exception 'This active stock opname session belongs to another user.'
            using errcode = '42501';
        end if;
        if old_owner_id is null and old_session_has_data then
          raise exception 'This legacy stock opname session has no owner; ask the super admin to manage it.'
            using errcode = '42501';
        end if;
        if old_owner_id is distinct from current_user_id
          and is_current_user_pic
          and (
            (old_active_session -> 'status') is distinct from (new_active_session -> 'status')
            or (old_active_session -> 'startedAt') is distinct from (new_active_session -> 'startedAt')
            or (old_active_session -> 'finishedAt') is distinct from (new_active_session -> 'finishedAt')
            or (old_active_session -> 'createdByUsername') is distinct from (new_active_session -> 'createdByUsername')
          ) then
          if coalesce(old_active_session ->> 'status', 'active') <> 'active'
            or new_active_session ->> 'status' is distinct from 'completed'
            or nullif(old_active_session ->> 'finishedAt', '') is not null
            or nullif(new_active_session ->> 'finishedAt', '') is null
            or (old_active_session - 'status' - 'finishedAt') is distinct from (new_active_session - 'status' - 'finishedAt') then
            raise exception 'Assigned PICs may only finish, not restart or replace, the active session.'
              using errcode = '42501';
          end if;
        end if;
        if (old_owner_id is not null and new_owner_id is distinct from old_owner_id)
          or (old_owner_id is null and new_owner_id is not null and new_owner_id is distinct from current_user_id) then
          raise exception 'A stock opname session owner cannot be changed by another user.'
            using errcode = '42501';
        end if;
      end if;
    end if;
  end loop;

  for new_archive in
    select value from jsonb_array_elements(coalesce(new.data -> 'sessions', '[]'::jsonb))
  loop
    archive_id := new_archive ->> 'id';
    select value into old_archive
      from jsonb_array_elements(coalesce(old.data -> 'sessions', '[]'::jsonb))
      where value ->> 'id' = archive_id
      limit 1;
    if old_archive is not null and old_archive is not distinct from new_archive then
      continue;
    end if;

    if old_archive is not null
      and old_archive ->> 'createdByUserId' is distinct from current_user_id then
      raise exception 'Only the stock opname session owner can change or delete its archive.'
        using errcode = '42501';
    end if;
    if new_archive ->> 'createdByUserId' is distinct from current_user_id
      and not exists (
        select 1
          from jsonb_array_elements(coalesce(old.data -> 'workspaces', '[]'::jsonb)) as assigned_workspace(value)
         where assigned_workspace.value ->> 'id' = new_archive ->> 'workspaceId'
           and assigned_workspace.value -> 'data' -> 'activeSession' ->> 'id' = archive_id
           and assigned_workspace.value -> 'data' -> 'activeSession' ->> 'status' = 'active'
           and assigned_workspace.value -> 'data' -> 'activeSession' ->> 'createdByUserId' = new_archive ->> 'createdByUserId'
           and exists (
             select 1
               from jsonb_array_elements_text(coalesce(assigned_workspace.value -> 'picNames', '[]'::jsonb)) as pic(name)
              where lower(btrim(pic.name)) = any(current_user_names)
           )
      ) then
      raise exception 'Only the stock opname session owner can change or create its archive.'
        using errcode = '42501';
    end if;
    if old_archive is null then
      if new_archive -> 'snapshot' -> 'activeSession' ->> 'id' is distinct from archive_id
        or new_archive -> 'snapshot' -> 'activeSession' ->> 'status' is distinct from 'completed'
        or new_archive -> 'snapshot' -> 'activeSession' ->> 'createdByUserId' is distinct from new_archive ->> 'createdByUserId'
        or nullif(new_archive -> 'snapshot' -> 'activeSession' ->> 'finishedAt', '') is null then
        raise exception 'A stock opname archive must contain its matching completed session.'
          using errcode = '42501';
      end if;
      select value into previous_archive_workspace
        from jsonb_array_elements(coalesce(old.data -> 'workspaces', '[]'::jsonb))
        where value ->> 'id' = new_archive ->> 'workspaceId'
        limit 1;
      if previous_archive_workspace is null
        or previous_archive_workspace -> 'data' -> 'activeSession' ->> 'id' is distinct from archive_id
        or coalesce(previous_archive_workspace -> 'data' -> 'activeSession' ->> 'status', 'active') <> 'active'
        or previous_archive_workspace -> 'data' -> 'activeSession' ->> 'createdByUserId' is distinct from new_archive ->> 'createdByUserId'
        or nullif(previous_archive_workspace -> 'data' -> 'activeSession' ->> 'finishedAt', '') is not null
        or (new_archive -> 'snapshot' -> 'activeSession' - 'status' - 'finishedAt')
          is distinct from (previous_archive_workspace -> 'data' -> 'activeSession' - 'status' - 'finishedAt') then
        raise exception 'A stock opname archive must match an active session completed without changing its ownership.'
          using errcode = '42501';
      end if;
    end if;
  end loop;

  for old_archive in
    select value from jsonb_array_elements(coalesce(old.data -> 'sessions', '[]'::jsonb))
  loop
    archive_id := old_archive ->> 'id';
    if not exists (
      select 1 from jsonb_array_elements(coalesce(new.data -> 'sessions', '[]'::jsonb)) as archive(value)
      where archive.value ->> 'id' = archive_id
    ) and old_archive ->> 'createdByUserId' is distinct from current_user_id then
      raise exception 'Only the stock opname session owner can change or delete its archive.'
        using errcode = '42501';
    end if;
  end loop;

  return new;
end;
$$;

drop trigger if exists guard_stock_opname_session_ownership on public.stock_opname_state;
create trigger guard_stock_opname_session_ownership
  before update on public.stock_opname_state
  for each row execute function public.guard_stock_opname_session_ownership();

create or replace function public.guard_stock_opname_chat_messages()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  current_user_id text := auth.uid()::text;
  is_workspace_super_admin boolean :=
    coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'super_admin'
    and coalesce(auth.jwt() -> 'app_metadata' ->> 'owner_username', '') = 'indra';
  old_message jsonb;
  new_message jsonb;
  matching_archive jsonb;
  old_archive jsonb;
  message_id text;
  message_created_at timestamptz;
begin
  if is_workspace_super_admin then
    return new;
  end if;

  for old_message in
    select item.value from jsonb_array_elements(coalesce(old.data -> 'chatMessages', '[]'::jsonb)) as item(value)
  loop
    message_id := old_message ->> 'id';
    select item.value into new_message
      from jsonb_array_elements(coalesce(new.data -> 'chatMessages', '[]'::jsonb)) as item(value)
     where item.value ->> 'id' = message_id
     limit 1;

    if new_message is not null and new_message is not distinct from old_message then
      continue;
    end if;
    if new_message is not null then
      if old_message ->> 'senderId' = current_user_id
        and new_message ->> 'senderId' = current_user_id
        and new_message ->> 'createdAt' = old_message ->> 'createdAt' then
        continue;
      end if;
      raise exception 'Only the message sender or workspace owner can edit a chat message.'
        using errcode = '42501';
    end if;

    select item.value into matching_archive
      from jsonb_array_elements(coalesce(new.data -> 'chatArchiveMessages', '[]'::jsonb)) as item(value)
     where item.value ->> 'id' = message_id
     limit 1;
    if matching_archive is not null and matching_archive is not distinct from old_message
      and (old_message ->> 'createdAt')::timestamptz <= pg_catalog.now() - interval '24 hours' then
      continue;
    end if;

    message_created_at := (old_message ->> 'createdAt')::timestamptz;
    if old_message ->> 'senderId' = current_user_id
      and message_created_at <= pg_catalog.now()
      and message_created_at >= pg_catalog.now() - interval '1 hour' then
      continue;
    end if;
    raise exception 'A chat message can only be deleted by its sender within one hour, or by the workspace owner.'
      using errcode = '42501';
  end loop;

  for new_message in
    select item.value from jsonb_array_elements(coalesce(new.data -> 'chatMessages', '[]'::jsonb)) as item(value)
  loop
    message_id := new_message ->> 'id';
    select item.value into old_message
      from jsonb_array_elements(coalesce(old.data -> 'chatMessages', '[]'::jsonb)) as item(value)
     where item.value ->> 'id' = message_id
     limit 1;
    if old_message is not null then
      continue;
    end if;
    select item.value into old_archive
      from jsonb_array_elements(coalesce(old.data -> 'chatArchiveMessages', '[]'::jsonb)) as item(value)
     where item.value ->> 'id' = message_id
     limit 1;
    if old_archive is not null then
      raise exception 'An archived chat message cannot be restored to the active chat by a team member.'
        using errcode = '42501';
    end if;

    message_created_at := (new_message ->> 'createdAt')::timestamptz;
    if new_message ->> 'senderId' <> current_user_id
      or message_created_at > pg_catalog.now() + interval '5 minutes'
      or message_created_at < pg_catalog.now() - interval '24 hours' then
      raise exception 'A new chat message must belong to the authenticated sender and be less than one day old.'
        using errcode = '42501';
    end if;
  end loop;

  for old_archive in
    select item.value from jsonb_array_elements(coalesce(old.data -> 'chatArchiveMessages', '[]'::jsonb)) as item(value)
  loop
    message_id := old_archive ->> 'id';
    select item.value into new_message
      from jsonb_array_elements(coalesce(new.data -> 'chatArchiveMessages', '[]'::jsonb)) as item(value)
     where item.value ->> 'id' = message_id
     limit 1;
    if new_message is distinct from old_archive then
      raise exception 'Only the workspace owner can edit or delete archived chat messages.'
        using errcode = '42501';
    end if;
  end loop;

  for new_message in
    select item.value from jsonb_array_elements(coalesce(new.data -> 'chatArchiveMessages', '[]'::jsonb)) as item(value)
  loop
    message_id := new_message ->> 'id';
    select item.value into old_archive
      from jsonb_array_elements(coalesce(old.data -> 'chatArchiveMessages', '[]'::jsonb)) as item(value)
     where item.value ->> 'id' = message_id
     limit 1;
    if old_archive is not null then
      continue;
    end if;

    select item.value into old_message
      from jsonb_array_elements(coalesce(old.data -> 'chatMessages', '[]'::jsonb)) as item(value)
     where item.value ->> 'id' = message_id
     limit 1;
    if old_message is null
      or new_message is distinct from old_message
      or (old_message ->> 'createdAt')::timestamptz > pg_catalog.now() - interval '24 hours' then
      raise exception 'A chat archive entry must be an unchanged message older than one day.'
        using errcode = '42501';
    end if;
  end loop;

  return new;
end;
$$;

drop trigger if exists guard_stock_opname_chat_messages on public.stock_opname_state;
create trigger guard_stock_opname_chat_messages
  before update on public.stock_opname_state
  for each row execute function public.guard_stock_opname_chat_messages();

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'stock-opname-workbooks',
  'stock-opname-workbooks',
  false,
  52428800,
  array[
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.ms-excel',
    'text/csv'
  ]
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Team members can read archived stock opname workbooks" on storage.objects;
create policy "Team members can read archived stock opname workbooks"
  on storage.objects for select to authenticated
  using (bucket_id = 'stock-opname-workbooks');

drop policy if exists "Team members can upload archived stock opname workbooks" on storage.objects;
create policy "Team members can upload archived stock opname workbooks"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'stock-opname-workbooks');

drop policy if exists "Team members can delete archived stock opname workbooks" on storage.objects;
drop policy if exists "Session owners and super admins can delete archived stock opname workbooks" on storage.objects;
create policy "Session owners and super admins can delete archived stock opname workbooks"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'stock-opname-workbooks'
    and (
      (
        coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'super_admin'
        and coalesce(auth.jwt() -> 'app_metadata' ->> 'owner_username', '') = 'indra'
      )
      or exists (
        select 1
        from public.stock_opname_state as opname,
          jsonb_array_elements(coalesce(opname.data -> 'workspaces', '[]'::jsonb)) as workspace(value)
        where opname.id = 'stock-opname-team'
          and workspace.value ->> 'id' = split_part(storage.objects.name, '/', 1)
          and workspace.value -> 'data' -> 'activeSession' ->> 'id' = split_part(storage.objects.name, '/', 2)
          and workspace.value -> 'data' -> 'activeSession' ->> 'createdByUserId' = auth.uid()::text
      )
      or exists (
        select 1
        from public.stock_opname_state as opname,
          jsonb_array_elements(coalesce(opname.data -> 'sessions', '[]'::jsonb)) as archived(value)
        where opname.id = 'stock-opname-team'
          and archived.value ->> 'id' = split_part(storage.objects.name, '/', 2)
          and archived.value ->> 'workspaceId' = split_part(storage.objects.name, '/', 1)
          and archived.value ->> 'createdByUserId' = auth.uid()::text
      )
    )
  );

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'stock-opname-chat-attachments',
  'stock-opname-chat-attachments',
  false,
  52428800,
  null
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Team members can read chat attachments" on storage.objects;
create policy "Team members can read chat attachments"
  on storage.objects for select to authenticated
  using (bucket_id = 'stock-opname-chat-attachments');

drop policy if exists "Team members can upload their own chat attachments" on storage.objects;
create policy "Team members can upload their own chat attachments"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'stock-opname-chat-attachments'
    and split_part(name, '/', 1) = auth.uid()::text
  );

drop policy if exists "Team members can delete their own chat attachments" on storage.objects;
create policy "Team members can delete their own chat attachments"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'stock-opname-chat-attachments'
    and (
      split_part(name, '/', 1) = auth.uid()::text
      or (
        coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'super_admin'
        and coalesce(auth.jwt() -> 'app_metadata' ->> 'owner_username', '') = 'indra'
      )
    )
  );

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'stock-opname-app-downloads',
  'stock-opname-app-downloads',
  true,
  52428800,
  array['application/vnd.android.package-archive']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Public can read the Android app download" on storage.objects;
create policy "Public can read the Android app download"
  on storage.objects for select to anon, authenticated
  using (bucket_id = 'stock-opname-app-downloads' and name = 'latest.apk');

drop policy if exists "Workspace owner can upload the Android app" on storage.objects;
create policy "Workspace owner can upload the Android app"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'stock-opname-app-downloads'
    and name = 'latest.apk'
    and (
      (
        coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'super_admin'
        and coalesce(auth.jwt() -> 'app_metadata' ->> 'owner_username', '') = 'indra'
      )
      or coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'resource_admin'
    )
  );

drop policy if exists "Workspace owner can replace the Android app" on storage.objects;
create policy "Workspace owner can replace the Android app"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'stock-opname-app-downloads'
    and name = 'latest.apk'
    and (
      (
        coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'super_admin'
        and coalesce(auth.jwt() -> 'app_metadata' ->> 'owner_username', '') = 'indra'
      )
      or coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'resource_admin'
    )
  )
  with check (
    bucket_id = 'stock-opname-app-downloads'
    and name = 'latest.apk'
    and (
      (
        coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'super_admin'
        and coalesce(auth.jwt() -> 'app_metadata' ->> 'owner_username', '') = 'indra'
      )
      or coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'resource_admin'
    )
  );

drop policy if exists "Workspace owner can delete the Android app" on storage.objects;
create policy "Workspace owner can delete the Android app"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'stock-opname-app-downloads'
    and name = 'latest.apk'
    and (
      (
        coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'super_admin'
        and coalesce(auth.jwt() -> 'app_metadata' ->> 'owner_username', '') = 'indra'
      )
      or coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'resource_admin'
    )
  );
