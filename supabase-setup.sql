create table if not exists public.stock_opname_state (
  id text primary key check (id = 'stock-opname-team'),
  data jsonb not null,
  updated_at timestamptz not null default now(),
  version bigint not null default 1,
  updated_by uuid not null references auth.users(id)
);

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

alter table public.stock_opname_state enable row level security;
alter table public.stock_opname_usernames enable row level security;

revoke all on table public.stock_opname_state from anon;
revoke all on table public.stock_opname_state from authenticated;
grant select, insert, update on table public.stock_opname_state to authenticated;
revoke all on table public.stock_opname_usernames from anon;
revoke all on table public.stock_opname_usernames from authenticated;
grant select on table public.stock_opname_usernames to service_role;

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
      ) then
        raise exception 'Schedule cards can only be removed by their owner while the active session has no uploaded workbook.'
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

create or replace function public.guard_stock_opname_session_ownership()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  current_user_id text := auth.uid()::text;
  is_workspace_super_admin boolean :=
    coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'super_admin'
    and coalesce(auth.jwt() -> 'app_metadata' ->> 'owner_username', '') = 'indra';
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
  old_archive jsonb;
  new_archive jsonb;
  archive_workspace jsonb;
  previous_archive_workspace jsonb;
  workspace_id text;
  archive_id text;
begin
  if is_workspace_super_admin or current_user_id is null then
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

    if (old_workspace -> 'name') is distinct from (new_workspace -> 'name')
      or (old_workspace -> 'picNames') is distinct from (new_workspace -> 'picNames') then
      if coalesce(old_active_session ->> 'status', 'active') = 'active'
        and old_session_has_data
        and old_owner_id is distinct from current_user_id then
        raise exception 'This active stock opname session belongs to another user.'
          using errcode = '42501';
      end if;
    end if;

    if old_workspace_data is distinct from new_workspace_data then
      if old_session_id is distinct from new_session_id then
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
        if old_owner_id is not null and old_owner_id is distinct from current_user_id then
          raise exception 'This active stock opname session belongs to another user.'
            using errcode = '42501';
        end if;
        if old_owner_id is null and old_session_has_data then
          raise exception 'This legacy stock opname session has no owner; ask the super admin to manage it.'
            using errcode = '42501';
        end if;
        if new_owner_id is not null and new_owner_id is distinct from current_user_id then
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
    if new_archive ->> 'createdByUserId' is distinct from current_user_id then
      raise exception 'Only the stock opname session owner can change or create its archive.'
        using errcode = '42501';
    end if;
    if old_archive is null then
      select value into archive_workspace
        from jsonb_array_elements(coalesce(new.data -> 'workspaces', '[]'::jsonb))
        where value ->> 'id' = new_archive ->> 'workspaceId'
        limit 1;
      if archive_workspace is null
        or archive_workspace -> 'data' -> 'activeSession' ->> 'id' is distinct from archive_id
        or archive_workspace -> 'data' -> 'activeSession' ->> 'status' is distinct from 'completed'
        or archive_workspace -> 'data' -> 'activeSession' ->> 'createdByUserId' is distinct from current_user_id then
        select value into previous_archive_workspace
          from jsonb_array_elements(coalesce(old.data -> 'workspaces', '[]'::jsonb))
          where value ->> 'id' = new_archive ->> 'workspaceId'
          limit 1;
        if previous_archive_workspace is null
          or previous_archive_workspace -> 'data' -> 'activeSession' ->> 'id' is distinct from archive_id
          or previous_archive_workspace -> 'data' -> 'activeSession' ->> 'status' is distinct from 'active'
          or previous_archive_workspace -> 'data' -> 'activeSession' ->> 'createdByUserId' is distinct from current_user_id then
          raise exception 'A stock opname archive must match a completed session owned by the current user.'
            using errcode = '42501';
        end if;
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
