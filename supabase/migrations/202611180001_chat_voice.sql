create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 32),
  avatar_url text,
  updated_at timestamptz not null default now()
);

create table if not exists public.conversations (
  id text primary key,
  kind text not null check (kind in ('general', 'group', 'personal')),
  name text not null check (char_length(name) between 1 and 80),
  direct_key text unique,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  check ((kind = 'personal') = (direct_key is not null))
);

insert into public.conversations (id, kind, name)
values ('general', 'general', 'Canal general')
on conflict (id) do nothing;

create table if not exists public.conversation_members (
  conversation_id text not null
    references public.conversations (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role text not null default 'member' check (role in ('admin', 'member')),
  created_at timestamptz not null default now(),
  primary key (conversation_id, user_id)
);

create table if not exists public.chat_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id text not null
    references public.conversations (id) on delete cascade,
  sender_id uuid not null references auth.users (id) on delete cascade,
  body text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now()
);

create index if not exists chat_messages_conversation_created_idx
  on public.chat_messages (conversation_id, created_at);

alter table public.webrtc_rooms
  add column if not exists conversation_id text;
alter table public.webrtc_rooms
  add column if not exists created_by uuid references auth.users (id) on delete set null;
alter table public.webrtc_ice_candidates
  add column if not exists conversation_id text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'webrtc_rooms_conversation_id_fkey'
      and conrelid = 'public.webrtc_rooms'::regclass
  ) then
    alter table public.webrtc_rooms
      add constraint webrtc_rooms_conversation_id_fkey
      foreign key (conversation_id)
      references public.conversations (id)
      on delete cascade;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'webrtc_ice_candidates_conversation_id_fkey'
      and conrelid = 'public.webrtc_ice_candidates'::regclass
  ) then
    alter table public.webrtc_ice_candidates
      add constraint webrtc_ice_candidates_conversation_id_fkey
      foreign key (conversation_id)
      references public.conversations (id)
      on delete cascade;
  end if;
end
$$;

create unique index if not exists webrtc_rooms_one_active_per_conversation_idx
  on public.webrtc_rooms (conversation_id)
  where conversation_id is not null
    and status in ('waiting', 'answered');
create index if not exists webrtc_ice_candidates_conversation_created_idx
  on public.webrtc_ice_candidates (conversation_id, created_at);

create or replace function public.is_conversation_member(p_conversation_id text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.conversation_members m
    where m.conversation_id = p_conversation_id
      and m.user_id = auth.uid()
  );
$$;

revoke all on function public.is_conversation_member(text) from public;
grant execute on function public.is_conversation_member(text) to authenticated;

alter table public.profiles enable row level security;
alter table public.conversations enable row level security;
alter table public.conversation_members enable row level security;
alter table public.chat_messages enable row level security;
alter table public.webrtc_rooms enable row level security;
alter table public.webrtc_ice_candidates enable row level security;

grant usage on schema public to authenticated;
grant select, insert, update on public.profiles to authenticated;
grant select, insert, update on public.conversations to authenticated;
grant select, insert, delete on public.conversation_members to authenticated;
grant select, insert on public.chat_messages to authenticated;
grant select, insert, update on public.webrtc_rooms to authenticated;
grant select, insert on public.webrtc_ice_candidates to authenticated;

do $$
declare
  existing_policy record;
begin
  for existing_policy in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in ('webrtc_rooms', 'webrtc_ice_candidates')
  loop
    execute format(
      'drop policy if exists %I on %I.%I',
      existing_policy.policyname,
      existing_policy.schemaname,
      existing_policy.tablename
    );
  end loop;
end
$$;

drop policy if exists "profiles_read_authenticated" on public.profiles;
create policy "profiles_read_authenticated"
  on public.profiles for select to authenticated
  using (true);

drop policy if exists "profiles_insert_self" on public.profiles;
create policy "profiles_insert_self"
  on public.profiles for insert to authenticated
  with check (id = auth.uid());

drop policy if exists "profiles_update_self" on public.profiles;
create policy "profiles_update_self"
  on public.profiles for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

drop policy if exists "conversations_read_members" on public.conversations;
create policy "conversations_read_members"
  on public.conversations for select to authenticated
  using (
    id = 'general'
    or created_by = auth.uid()
    or public.is_conversation_member(id)
    or (
      kind = 'personal'
      and (
        direct_key like auth.uid()::text || ':%'
        or direct_key like '%:' || auth.uid()::text
      )
    )
  );

drop policy if exists "conversations_create_self" on public.conversations;
create policy "conversations_create_self"
  on public.conversations for insert to authenticated
  with check (
    created_by = auth.uid()
    and kind in ('group', 'personal')
  );

drop policy if exists "conversations_update_creator" on public.conversations;
create policy "conversations_update_creator"
  on public.conversations for update to authenticated
  using (created_by = auth.uid())
  with check (created_by = auth.uid());

drop policy if exists "conversation_members_read" on public.conversation_members;
create policy "conversation_members_read"
  on public.conversation_members for select to authenticated
  using (
    user_id = auth.uid()
    or public.is_conversation_member(conversation_id)
  );

drop policy if exists "conversation_members_add" on public.conversation_members;
create policy "conversation_members_add"
  on public.conversation_members for insert to authenticated
  with check (
    exists (
      select 1
      from public.conversations c
      where c.id = conversation_id
        and (
          c.created_by = auth.uid()
          or (
            c.kind = 'personal'
            and user_id = auth.uid()
            and (
              c.direct_key like auth.uid()::text || ':%'
              or c.direct_key like '%:' || auth.uid()::text
            )
          )
        )
    )
  );

drop policy if exists "conversation_members_remove" on public.conversation_members;
create policy "conversation_members_remove"
  on public.conversation_members for delete to authenticated
  using (
    user_id = auth.uid()
    or exists (
      select 1
      from public.conversations c
      where c.id = conversation_id
        and c.created_by = auth.uid()
    )
  );

drop policy if exists "chat_messages_read_members" on public.chat_messages;
create policy "chat_messages_read_members"
  on public.chat_messages for select to authenticated
  using (
    conversation_id = 'general'
    or public.is_conversation_member(conversation_id)
  );

drop policy if exists "chat_messages_insert_members" on public.chat_messages;
create policy "chat_messages_insert_members"
  on public.chat_messages for insert to authenticated
  with check (
    sender_id = auth.uid()
    and (
      conversation_id = 'general'
      or public.is_conversation_member(conversation_id)
    )
  );

drop policy if exists "webrtc_rooms_public_read" on public.webrtc_rooms;
drop policy if exists "webrtc_rooms_public_insert" on public.webrtc_rooms;
drop policy if exists "webrtc_rooms_public_update" on public.webrtc_rooms;
drop policy if exists "webrtc_rooms_read_members" on public.webrtc_rooms;
create policy "webrtc_rooms_read_members"
  on public.webrtc_rooms for select to authenticated
  using (
    conversation_id is not null
    and (
      conversation_id = 'general'
      or public.is_conversation_member(conversation_id)
    )
  );

drop policy if exists "webrtc_rooms_insert_members" on public.webrtc_rooms;
create policy "webrtc_rooms_insert_members"
  on public.webrtc_rooms for insert to authenticated
  with check (
    created_by = auth.uid()
    and (
      conversation_id = 'general'
      or public.is_conversation_member(conversation_id)
    )
  );

drop policy if exists "webrtc_rooms_update_members" on public.webrtc_rooms;
create policy "webrtc_rooms_update_members"
  on public.webrtc_rooms for update to authenticated
  using (
    conversation_id is not null
    and (
      conversation_id = 'general'
      or public.is_conversation_member(conversation_id)
    )
  )
  with check (
    conversation_id is not null
    and (
      conversation_id = 'general'
      or public.is_conversation_member(conversation_id)
    )
  );

drop policy if exists "webrtc_ice_public_read" on public.webrtc_ice_candidates;
drop policy if exists "webrtc_ice_public_insert" on public.webrtc_ice_candidates;
drop policy if exists "webrtc_ice_read_members" on public.webrtc_ice_candidates;
create policy "webrtc_ice_read_members"
  on public.webrtc_ice_candidates for select to authenticated
  using (
    conversation_id is not null
    and exists (
      select 1
      from public.webrtc_rooms r
      where r.id = room_id
        and r.conversation_id = webrtc_ice_candidates.conversation_id
        and (
          r.conversation_id = 'general'
          or public.is_conversation_member(r.conversation_id)
        )
    )
  );

drop policy if exists "webrtc_ice_insert_members" on public.webrtc_ice_candidates;
create policy "webrtc_ice_insert_members"
  on public.webrtc_ice_candidates for insert to authenticated
  with check (
    conversation_id is not null
    and exists (
      select 1
      from public.webrtc_rooms r
      where r.id = room_id
        and r.conversation_id = webrtc_ice_candidates.conversation_id
        and (
          r.conversation_id = 'general'
          or public.is_conversation_member(r.conversation_id)
        )
    )
  );

insert into storage.buckets (id, name, public)
values ('profile-photos', 'profile-photos', true)
on conflict (id) do update set public = true;

drop policy if exists "profile_photos_insert_own" on storage.objects;
create policy "profile_photos_insert_own"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'profile-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "profile_photos_update_own" on storage.objects;
create policy "profile_photos_update_own"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'profile-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'profile-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "profile_photos_delete_own" on storage.objects;
create policy "profile_photos_delete_own"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'profile-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'profiles',
    'conversation_members',
    'chat_messages',
    'webrtc_rooms',
    'webrtc_ice_candidates'
  ]
  loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = table_name
    ) then
      execute format(
        'alter publication supabase_realtime add table public.%I',
        table_name
      );
    end if;
  end loop;
end
$$;
