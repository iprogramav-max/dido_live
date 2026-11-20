begin;

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

do $$
begin
  if exists (
    select 1
    from public.conversations c
    where c.kind = 'personal'
      and (
        c.direct_key !~
          '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        or split_part(c.direct_key, ':', 1) >=
          split_part(c.direct_key, ':', 2)
        or (
          select count(*)
          from public.conversation_members m
          where m.conversation_id = c.id
        ) <> 2
        or not exists (
          select 1
          from public.conversation_members m
          where m.conversation_id = c.id
            and m.user_id::text = split_part(c.direct_key, ':', 1)
        )
        or not exists (
          select 1
          from public.conversation_members m
          where m.conversation_id = c.id
            and m.user_id::text = split_part(c.direct_key, ':', 2)
        )
      )
  ) then
    raise exception
      'Personal conversations must be repaired to contain exactly the two users in direct_key before applying this migration.';
  end if;
end
$$;

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

create or replace function public.assert_personal_conversation_has_two_members()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_conversation_id text;
  v_direct_key text;
  v_kind text;
  v_first_user text;
  v_second_user text;
begin
  if tg_table_name = 'conversations' then
    v_conversation_id := case when tg_op = 'DELETE' then old.id else new.id end;
  else
    v_conversation_id := case
      when tg_op = 'DELETE' then old.conversation_id
      else new.conversation_id
    end;
  end if;

  select c.kind, c.direct_key
  into v_kind, v_direct_key
  from public.conversations c
  where c.id = v_conversation_id;

  if not found or v_kind <> 'personal' then
    return null;
  end if;

  if v_direct_key !~
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  then
    raise exception 'Personal conversation % has an invalid direct_key.',
      v_conversation_id
      using errcode = '23514';
  end if;

  v_first_user := split_part(v_direct_key, ':', 1);
  v_second_user := split_part(v_direct_key, ':', 2);

  if v_first_user >= v_second_user
    or (
      select count(*)
      from public.conversation_members m
      where m.conversation_id = v_conversation_id
    ) <> 2
    or not exists (
      select 1 from public.conversation_members m
      where m.conversation_id = v_conversation_id
        and m.user_id::text = v_first_user
    )
    or not exists (
      select 1 from public.conversation_members m
      where m.conversation_id = v_conversation_id
        and m.user_id::text = v_second_user
    )
  then
    raise exception
      'Personal conversation % must contain exactly the two users in direct_key.',
      v_conversation_id
      using errcode = '23514';
  end if;

  return null;
end
$$;

drop trigger if exists personal_conversation_members_count
  on public.conversations;
create constraint trigger personal_conversation_members_count
after insert or update or delete on public.conversations
deferrable initially deferred
for each row
execute function public.assert_personal_conversation_has_two_members();

drop trigger if exists personal_conversation_member_count
  on public.conversation_members;
create constraint trigger personal_conversation_member_count
after insert or update or delete on public.conversation_members
deferrable initially deferred
for each row
execute function public.assert_personal_conversation_has_two_members();

create or replace function public.delete_personal_conversations_for_deleted_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.webrtc_rooms r
  set status = 'ended'
  where r.status in ('waiting', 'answered')
    and exists (
      select 1
      from public.webrtc_room_participants p
      where p.room_id = r.id
        and p.user_id = old.id
    );

  delete from public.conversations c
  where c.kind = 'personal'
    and exists (
      select 1
      from public.conversation_members m
      where m.conversation_id = c.id
        and m.user_id = old.id
    );
  return old;
end
$$;

drop trigger if exists delete_personal_conversations_for_deleted_user
  on auth.users;
create trigger delete_personal_conversations_for_deleted_user
before delete on auth.users
for each row
execute function public.delete_personal_conversations_for_deleted_user();

create or replace function public.open_direct_conversation(p_peer_id uuid)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_direct_key text;
  v_conversation_id text;
  v_peer_name text;
begin
  if v_user_id is null or p_peer_id is null or p_peer_id = v_user_id then
    raise exception 'Choose another signed-in user for a personal conversation.'
      using errcode = '22023';
  end if;

  select p.display_name into v_peer_name
  from public.profiles p
  where p.id = p_peer_id;

  if v_peer_name is null then
    raise exception 'The selected profile does not exist.'
      using errcode = '22023';
  end if;

  v_direct_key :=
    least(v_user_id, p_peer_id)::text || ':' ||
    greatest(v_user_id, p_peer_id)::text;

  insert into public.conversations (
    id, kind, name, direct_key, created_by
  )
  values (
    gen_random_uuid()::text, 'personal', v_peer_name, v_direct_key, v_user_id
  )
  on conflict (direct_key) do nothing
  returning id into v_conversation_id;

  if v_conversation_id is null then
    select c.id into v_conversation_id
    from public.conversations c
    where c.direct_key = v_direct_key;
  end if;

  insert into public.conversation_members (conversation_id, user_id, role)
  values
    (v_conversation_id, v_user_id, 'member'),
    (v_conversation_id, p_peer_id, 'member')
  on conflict (conversation_id, user_id) do nothing;

  return v_conversation_id;
end
$$;

create table if not exists public.webrtc_room_participants (
  room_id uuid not null
    references public.webrtc_rooms (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role text not null check (role in ('caller', 'callee')),
  created_at timestamptz not null default now(),
  primary key (room_id, user_id),
  unique (room_id, role)
);

with active_rooms as (
  select
    r.id,
    row_number() over (
      partition by r.conversation_id
      order by r.created_at desc, r.id desc
    ) as position
  from public.webrtc_rooms r
  where r.conversation_id is not null
    and r.status in ('waiting', 'answered')
)
update public.webrtc_rooms r
set status = 'ended'
from active_rooms a
where r.id = a.id
  and (
    a.position > 1
    or not exists (
      select 1
      from public.webrtc_room_participants p
      where p.room_id = r.id
    )
  );

update public.webrtc_rooms r
set status = 'ended'
where r.status in ('waiting', 'answered')
  and not exists (
    select 1
    from public.webrtc_room_participants p
    where p.room_id = r.id
  );

create or replace function public.assert_webrtc_room_participant()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_created_by uuid;
begin
  select r.created_by into v_created_by
  from public.webrtc_rooms r
  where r.id = new.room_id;

  if not found
    or (new.role = 'caller' and new.user_id is distinct from v_created_by)
    or (new.role = 'callee' and new.user_id = v_created_by)
  then
    raise exception 'Invalid participant for WebRTC room %.', new.room_id
      using errcode = '23514';
  end if;

  return new;
end
$$;

drop trigger if exists webrtc_room_participant_matches_creator
  on public.webrtc_room_participants;
create trigger webrtc_room_participant_matches_creator
before insert or update on public.webrtc_room_participants
for each row
execute function public.assert_webrtc_room_participant();

create or replace function public.is_webrtc_room_participant(p_room_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.webrtc_room_participants p
    where p.room_id = p_room_id
      and p.user_id = auth.uid()
  );
$$;

create or replace function public.webrtc_room_role(p_room_id uuid)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p.role
  from public.webrtc_room_participants p
  where p.room_id = p_room_id
    and p.user_id = auth.uid();
$$;

create or replace function public.start_or_join_voice_call(
  p_conversation_id text,
  p_offer jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_conversation public.conversations%rowtype;
  v_room public.webrtc_rooms%rowtype;
  v_role text;
begin
  if v_user_id is null then
    raise exception 'Sign in before starting a voice call.'
      using errcode = '42501';
  end if;

  if jsonb_typeof(p_offer) is distinct from 'object'
    or p_offer->>'type' is distinct from 'offer'
    or coalesce(p_offer->>'sdp', '') = ''
  then
    raise exception 'A valid WebRTC offer is required.'
      using errcode = '22023';
  end if;

  select c.* into v_conversation
  from public.conversations c
  where c.id = p_conversation_id
  for update;

  if not found
    or (
      p_conversation_id <> 'general'
      and not public.is_conversation_member(p_conversation_id)
    )
  then
    raise exception 'You are not a participant in this conversation.'
      using errcode = '42501';
  end if;

  select r.* into v_room
  from public.webrtc_rooms r
  where r.conversation_id = p_conversation_id
    and r.status in ('waiting', 'answered')
  order by r.created_at desc
  limit 1
  for update;

  if found then
    select p.role into v_role
    from public.webrtc_room_participants p
    where p.room_id = v_room.id
      and p.user_id = v_user_id;

    if v_role is not null then
      return to_jsonb(v_room) || jsonb_build_object('role', v_role);
    elsif v_room.status = 'waiting'
      and not exists (
        select 1
        from public.webrtc_room_participants p
        where p.room_id = v_room.id
          and p.role = 'callee'
      )
    then
      insert into public.webrtc_room_participants (room_id, user_id, role)
      values (v_room.id, v_user_id, 'callee');
      v_role := 'callee';
      return to_jsonb(v_room) || jsonb_build_object('role', v_role);
    else
      raise exception
        'This voice call already has two participants; start a new call after one participant ends it.'
        using errcode = '23505';
    end if;
  end if;

  insert into public.webrtc_rooms (
    conversation_id, created_by, offer, status
  )
  values (
    p_conversation_id, v_user_id, p_offer, 'waiting'
  )
  returning * into v_room;

  insert into public.webrtc_room_participants (room_id, user_id, role)
  values (v_room.id, v_user_id, 'caller');

  return to_jsonb(v_room) || jsonb_build_object('role', 'caller');
end
$$;

create or replace function public.answer_voice_call(
  p_room_id uuid,
  p_answer jsonb
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room public.webrtc_rooms%rowtype;
begin
  if jsonb_typeof(p_answer) is distinct from 'object'
    or p_answer->>'type' is distinct from 'answer'
    or coalesce(p_answer->>'sdp', '') = ''
  then
    raise exception 'A valid WebRTC answer is required.'
      using errcode = '22023';
  end if;

  if public.webrtc_room_role(p_room_id) is distinct from 'callee' then
    raise exception 'Only this call''s callee can submit an answer.'
      using errcode = '42501';
  end if;

  select r.* into v_room
  from public.webrtc_rooms r
  where r.id = p_room_id
  for update;

  if not found or v_room.status <> 'waiting' or v_room.answer is not null then
    raise exception 'This voice call is no longer waiting for an answer.'
      using errcode = '23505';
  end if;

  update public.webrtc_rooms
  set answer = p_answer, status = 'answered'
  where id = p_room_id;
end
$$;

create or replace function public.end_voice_call(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_webrtc_room_participant(p_room_id) then
    raise exception 'Only a participant can end this voice call.'
      using errcode = '42501';
  end if;

  update public.webrtc_rooms
  set status = 'ended'
  where id = p_room_id
    and status in ('waiting', 'answered');
end
$$;

create or replace function public.can_view_profile_photo(p_owner_id text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p_owner_id = auth.uid()::text
    or exists (
      select 1
      from public.conversation_members owner_member
      join public.conversation_members viewer_member
        on viewer_member.conversation_id = owner_member.conversation_id
      where owner_member.user_id::text = p_owner_id
        and viewer_member.user_id = auth.uid()
    );
$$;

create index if not exists webrtc_ice_candidates_conversation_created_idx
  on public.webrtc_ice_candidates (conversation_id, created_at);

create unique index if not exists webrtc_rooms_one_active_per_conversation_idx
  on public.webrtc_rooms (conversation_id)
  where conversation_id is not null
    and status in ('waiting', 'answered');

alter table public.profiles enable row level security;
alter table public.conversations enable row level security;
alter table public.conversation_members enable row level security;
alter table public.chat_messages enable row level security;
alter table public.webrtc_rooms enable row level security;
alter table public.webrtc_ice_candidates enable row level security;
alter table public.webrtc_room_participants enable row level security;

revoke all on public.profiles,
  public.conversations,
  public.conversation_members,
  public.chat_messages,
  public.webrtc_rooms,
  public.webrtc_ice_candidates,
  public.webrtc_room_participants
from public, anon, authenticated;

grant usage on schema public to authenticated;
grant select, insert, update on public.profiles to authenticated;
grant select, insert on public.conversations to authenticated;
grant select, insert, delete on public.conversation_members to authenticated;
grant select, insert on public.chat_messages to authenticated;
grant select on public.webrtc_rooms to authenticated;
grant select, insert on public.webrtc_ice_candidates to authenticated;

revoke all on function public.is_conversation_member(text)
  from public, anon, authenticated;
revoke all on function public.assert_personal_conversation_has_two_members()
  from public, anon, authenticated;
revoke all on function public.delete_personal_conversations_for_deleted_user()
  from public, anon, authenticated;
revoke all on function public.open_direct_conversation(uuid)
  from public, anon, authenticated;
revoke all on function public.assert_webrtc_room_participant()
  from public, anon, authenticated;
revoke all on function public.is_webrtc_room_participant(uuid)
  from public, anon, authenticated;
revoke all on function public.webrtc_room_role(uuid)
  from public, anon, authenticated;
revoke all on function public.start_or_join_voice_call(text, jsonb)
  from public, anon, authenticated;
revoke all on function public.answer_voice_call(uuid, jsonb)
  from public, anon, authenticated;
revoke all on function public.end_voice_call(uuid)
  from public, anon, authenticated;
revoke all on function public.can_view_profile_photo(text)
  from public, anon, authenticated;

grant execute on function public.is_conversation_member(text) to authenticated;
grant execute on function public.open_direct_conversation(uuid) to authenticated;
grant execute on function public.is_webrtc_room_participant(uuid)
  to authenticated;
grant execute on function public.webrtc_room_role(uuid) to authenticated;
grant execute on function public.start_or_join_voice_call(text, jsonb)
  to authenticated;
grant execute on function public.answer_voice_call(uuid, jsonb)
  to authenticated;
grant execute on function public.end_voice_call(uuid) to authenticated;
grant execute on function public.can_view_profile_photo(text)
  to anon, authenticated;

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
  );

drop policy if exists "conversations_create_self" on public.conversations;
create policy "conversations_create_self"
  on public.conversations for insert to authenticated
  with check (created_by = auth.uid() and kind = 'group');

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
        and c.kind = 'group'
        and c.created_by = auth.uid()
    )
  );

drop policy if exists "conversation_members_remove" on public.conversation_members;
create policy "conversation_members_remove"
  on public.conversation_members for delete to authenticated
  using (
    exists (
      select 1
      from public.conversations c
      where c.id = conversation_id
        and c.kind = 'group'
        and (c.created_by = auth.uid() or user_id = auth.uid())
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
drop policy if exists "webrtc_rooms_insert_members" on public.webrtc_rooms;
drop policy if exists "webrtc_rooms_update_members" on public.webrtc_rooms;
drop policy if exists "webrtc_rooms_read_participants" on public.webrtc_rooms;
do $$
begin
  if exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'webrtc_rooms'
  ) then
    raise exception
      'Unrecognized policies remain on public.webrtc_rooms; review them and explicitly remove only policies that grant broader access.';
  end if;
end
$$;
create policy "webrtc_rooms_read_participants"
  on public.webrtc_rooms for select to authenticated
  using (public.is_webrtc_room_participant(id));

drop policy if exists "webrtc_ice_public_read" on public.webrtc_ice_candidates;
drop policy if exists "webrtc_ice_public_insert" on public.webrtc_ice_candidates;
drop policy if exists "webrtc_ice_read_members" on public.webrtc_ice_candidates;
drop policy if exists "webrtc_ice_insert_members" on public.webrtc_ice_candidates;
drop policy if exists "webrtc_ice_read_participants"
  on public.webrtc_ice_candidates;
drop policy if exists "webrtc_ice_insert_participants"
  on public.webrtc_ice_candidates;
do $$
begin
  if exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'webrtc_ice_candidates'
  ) then
    raise exception
      'Unrecognized policies remain on public.webrtc_ice_candidates; review them and explicitly remove only policies that grant broader access.';
  end if;
end
$$;
create policy "webrtc_ice_read_participants"
  on public.webrtc_ice_candidates for select to authenticated
  using (public.is_webrtc_room_participant(room_id));

create policy "webrtc_ice_insert_participants"
  on public.webrtc_ice_candidates for insert to authenticated
  with check (
    sender = public.webrtc_room_role(room_id)
    and exists (
      select 1
      from public.webrtc_rooms r
      where r.id = room_id
        and r.conversation_id = webrtc_ice_candidates.conversation_id
        and r.status in ('waiting', 'answered')
    )
  );

insert into storage.buckets (id, name, public)
values ('profile-photos', 'profile-photos', false)
on conflict (id) do update set public = false;

update public.profiles
set avatar_url = split_part(
  split_part(
    split_part(avatar_url, '/storage/v1/object/public/profile-photos/', 2),
    '/storage/v1/object/sign/profile-photos/',
    1
  ),
  '?',
  1
)
where avatar_url like '%/storage/v1/object/public/profile-photos/%';

update public.profiles
set avatar_url = split_part(
  split_part(avatar_url, '/storage/v1/object/sign/profile-photos/', 2),
  '?',
  1
)
where avatar_url like '%/storage/v1/object/sign/profile-photos/%';

drop policy if exists "profile_photos_select_authorized" on storage.objects;
create policy "profile_photos_select_authorized"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'profile-photos'
    and public.can_view_profile_photo((storage.foldername(name))[1])
  );

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

drop policy if exists "profile_photos_restrict_select"
  on storage.objects;
create policy "profile_photos_restrict_select"
  on storage.objects as restrictive for select to public
  using (
    bucket_id <> 'profile-photos'
    or (
      auth.uid() is not null
      and public.can_view_profile_photo((storage.foldername(name))[1])
    )
  );

drop policy if exists "profile_photos_restrict_insert"
  on storage.objects;
create policy "profile_photos_restrict_insert"
  on storage.objects as restrictive for insert to public
  with check (
    bucket_id <> 'profile-photos'
    or (
      auth.uid() is not null
      and (storage.foldername(name))[1] = auth.uid()::text
    )
  );

drop policy if exists "profile_photos_restrict_update"
  on storage.objects;
create policy "profile_photos_restrict_update"
  on storage.objects as restrictive for update to public
  using (
    bucket_id <> 'profile-photos'
    or (
      auth.uid() is not null
      and (storage.foldername(name))[1] = auth.uid()::text
    )
  )
  with check (
    bucket_id <> 'profile-photos'
    or (
      auth.uid() is not null
      and (storage.foldername(name))[1] = auth.uid()::text
    )
  );

drop policy if exists "profile_photos_restrict_delete"
  on storage.objects;
create policy "profile_photos_restrict_delete"
  on storage.objects as restrictive for delete to public
  using (
    bucket_id <> 'profile-photos'
    or (
      auth.uid() is not null
      and (storage.foldername(name))[1] = auth.uid()::text
    )
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

commit;
