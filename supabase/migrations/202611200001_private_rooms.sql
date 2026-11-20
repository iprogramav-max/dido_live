begin;

create extension if not exists pgcrypto;

-- General starts fresh. The old conversation remains in place but is no
-- longer globally readable; its prior members must be assigned deliberately.
insert into public.conversations (id, kind, name)
values ('general-v2', 'general', 'General')
on conflict (id) do nothing;

update public.conversations
set name = 'General anterior (privado; requiere asignación)'
where id = 'general';

alter table public.chat_messages
  add column if not exists text_color text not null default '#E8EDF2'
    check (text_color in ('#E8EDF2', '#50E3D2', '#FFB86B', '#A9C6FF', '#E6A8FF')),
  add column if not exists pinned_at timestamptz,
  add column if not exists pinned_by uuid references auth.users (id) on delete set null;

create table if not exists public.private_rooms (
  id uuid primary key default gen_random_uuid(),
  conversation_id text not null unique
    references public.conversations (id) on delete cascade,
  owner_id uuid not null references auth.users (id) on delete restrict,
  name text not null check (char_length(name) between 1 and 50),
  image_path text,
  description text not null default '' check (char_length(description) <= 500),
  welcome_text text not null default '' check (char_length(welcome_text) <= 500),
  max_members integer not null default 50 check (max_members between 2 and 50),
  requires_approval boolean not null default false,
  voice_member_limit smallint not null default 2 check (voice_member_limit = 2),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.room_members (
  room_id uuid not null references public.private_rooms (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role text not null default 'member'
    check (role in ('owner', 'admin', 'member')),
  muted_until timestamptz,
  joined_at timestamptz not null default now(),
  primary key (room_id, user_id)
);

create table if not exists public.room_bans (
  room_id uuid not null references public.private_rooms (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  blocked_by uuid not null references auth.users (id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (room_id, user_id)
);

create table if not exists public.room_invitations (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.private_rooms (id) on delete cascade,
  code_hash bytea not null unique,
  entry_mode text not null check (entry_mode in ('direct', 'approval')),
  created_by uuid not null references auth.users (id) on delete restrict,
  expires_at timestamptz not null,
  max_uses integer not null default 50 check (max_uses between 1 and 1000),
  used_count integer not null default 0 check (used_count >= 0),
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.room_join_requests (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.private_rooms (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  invitation_id uuid references public.room_invitations (id) on delete set null,
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  created_at timestamptz not null default now(),
  reviewed_by uuid references auth.users (id) on delete set null,
  reviewed_at timestamptz
);

create unique index if not exists room_join_requests_pending_user_idx
  on public.room_join_requests (room_id, user_id)
  where status = 'pending';
create index if not exists room_members_user_idx
  on public.room_members (user_id, room_id);
create index if not exists room_invitations_room_idx
  on public.room_invitations (room_id, created_at desc);

create table if not exists public.room_invitation_attempts (
  user_id uuid not null references auth.users (id) on delete cascade,
  attempted_at timestamptz not null default now()
);
revoke all on public.room_invitation_attempts from public, anon, authenticated;
create index if not exists room_invitation_attempts_user_time_idx
  on public.room_invitation_attempts (user_id, attempted_at desc);

create or replace function public.is_private_room_member(p_room_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select auth.uid() is not null and exists (
    select 1
    from public.room_members rm
    where rm.room_id = p_room_id
      and rm.user_id = auth.uid()
  );
$$;

create or replace function public.is_private_room_admin(p_room_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select auth.uid() is not null and exists (
    select 1
    from public.room_members rm
    where rm.room_id = p_room_id
      and rm.user_id = auth.uid()
      and rm.role in ('owner', 'admin')
  );
$$;

create or replace function public.is_conversation_member(p_conversation_id text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select auth.uid() is not null and exists (
    select 1
    from public.conversation_members cm
    left join public.private_rooms pr
      on pr.conversation_id = cm.conversation_id
    left join public.room_members rm
      on rm.room_id = pr.id and rm.user_id = auth.uid()
    where cm.conversation_id = p_conversation_id
      and cm.user_id = auth.uid()
      and (pr.id is null or rm.user_id is not null)
  );
$$;

create or replace function public.is_private_room_muted(p_conversation_id text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.private_rooms pr
    join public.room_members rm on rm.room_id = pr.id
    where pr.conversation_id = p_conversation_id
      and rm.user_id = auth.uid()
      and rm.muted_until > now()
  );
$$;

create or replace function public.sync_private_room_membership()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_conversation_id text;
  v_room_id uuid;
begin
  v_room_id := case when tg_op = 'DELETE' then old.room_id else new.room_id end;
  select pr.conversation_id
  into v_conversation_id
  from public.private_rooms pr
  where pr.id = v_room_id;

  if tg_op = 'DELETE' then
    delete from public.conversation_members
    where conversation_id = v_conversation_id and user_id = old.user_id;
    update public.webrtc_rooms r
    set status = 'ended'
    where r.conversation_id = v_conversation_id
      and r.status in ('waiting', 'answered')
      and exists (
        select 1
        from public.webrtc_room_participants p
        where p.room_id = r.id and p.user_id = old.user_id
      );
    return old;
  end if;

  insert into public.conversation_members (conversation_id, user_id, role)
  values (
    v_conversation_id,
    new.user_id,
    case when new.role in ('owner', 'admin') then 'admin' else 'member' end
  )
  on conflict (conversation_id, user_id)
  do update set role = excluded.role;

  if new.muted_until is distinct from old.muted_until
    and new.muted_until > now()
  then
    update public.webrtc_rooms r
    set status = 'ended'
    where r.conversation_id = v_conversation_id
      and r.status in ('waiting', 'answered')
      and exists (
        select 1
        from public.webrtc_room_participants p
        where p.room_id = r.id and p.user_id = new.user_id
      );
  end if;
  return new;
end
$$;

drop trigger if exists room_members_sync_conversation_members
  on public.room_members;
create trigger room_members_sync_conversation_members
after insert or update or delete on public.room_members
for each row execute function public.sync_private_room_membership();

create or replace function public.create_private_room(
  p_name text,
  p_description text default '',
  p_welcome_text text default '',
  p_max_members integer default 50,
  p_requires_approval boolean default false,
  p_image_path text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_room_id uuid := gen_random_uuid();
  v_conversation_id text := 'room_' || gen_random_uuid()::text;
begin
  if v_user_id is null then
    raise exception 'Sign in to create a room.' using errcode = '42501';
  end if;
  if coalesce(char_length(trim(p_name)), 0) not between 1 and 50
    or coalesce(char_length(p_description), 0) > 500
    or coalesce(char_length(p_welcome_text), 0) > 500
    or p_max_members not between 2 and 50
  then
    raise exception 'Room name, description, welcome message, or member cap is invalid.'
      using errcode = '22023';
  end if;

  insert into public.conversations (id, kind, name, created_by)
  values (v_conversation_id, 'group', trim(p_name), v_user_id);
  insert into public.private_rooms (
    id, conversation_id, owner_id, name, description, welcome_text,
    max_members, requires_approval, image_path
  ) values (
    v_room_id, v_conversation_id, v_user_id, trim(p_name),
    coalesce(p_description, ''), coalesce(p_welcome_text, ''),
    p_max_members, coalesce(p_requires_approval, false), p_image_path
  );
  insert into public.room_members (room_id, user_id, role)
  values (v_room_id, v_user_id, 'owner');
  return jsonb_build_object(
    'id', v_room_id,
    'conversation_id', v_conversation_id,
    'name', trim(p_name),
    'max_members', p_max_members,
    'voice_member_limit', 2
  );
end
$$;

create or replace function public.create_room_invitation(
  p_room_id uuid,
  p_entry_mode text,
  p_expires_in_hours integer default 168,
  p_max_uses integer default 50
)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_code text := encode(gen_random_bytes(18), 'hex');
begin
  if not public.is_private_room_admin(p_room_id) then
    raise exception 'Only a room owner or administrator may create invitations.'
      using errcode = '42501';
  end if;
  if p_entry_mode not in ('direct', 'approval')
    or p_expires_in_hours not between 1 and 720
    or p_max_uses not between 1 and 1000
  then
    raise exception 'Invitation settings are invalid.' using errcode = '22023';
  end if;
  insert into public.room_invitations (
    room_id, code_hash, entry_mode, created_by, expires_at, max_uses
  ) values (
    p_room_id, digest(v_code, 'sha256'), p_entry_mode, auth.uid(),
    now() + make_interval(hours => p_expires_in_hours), p_max_uses
  );
  return v_code;
end
$$;

create or replace function public.revoke_room_invitation(p_invitation_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room_id uuid;
begin
  select room_id into v_room_id
  from public.room_invitations
  where id = p_invitation_id
  for update;
  if v_room_id is null or not public.is_private_room_admin(v_room_id) then
    raise exception 'Only a room owner or administrator may revoke invitations.'
      using errcode = '42501';
  end if;
  update public.room_invitations
  set revoked_at = coalesce(revoked_at, now())
  where id = p_invitation_id;
end
$$;

create or replace function public.redeem_room_invitation(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_invitation public.room_invitations%rowtype;
  v_room public.private_rooms%rowtype;
  v_request_id uuid;
begin
  if v_user_id is null then
    raise exception 'Sign in before redeeming an invitation.'
      using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_user_id::text, 0));
  delete from public.room_invitation_attempts
  where attempted_at < now() - interval '1 day';
  if (
    select count(*) from public.room_invitation_attempts a
    where a.user_id = v_user_id
      and a.attempted_at > now() - interval '10 minutes'
  ) >= 10 then
    return jsonb_build_object(
      'status', 'rate_limited',
      'message', 'Too many invitation attempts. Try again in ten minutes.'
    );
  end if;
  insert into public.room_invitation_attempts (user_id) values (v_user_id);

  if coalesce(char_length(p_code), 0) not between 24 and 128 then
    return jsonb_build_object(
      'status', 'invalid',
      'message', 'Invitation code is invalid or expired.'
    );
  end if;
  select i.* into v_invitation
  from public.room_invitations i
  where i.code_hash = digest(p_code, 'sha256')
    and i.revoked_at is null
    and i.expires_at > now()
    and i.used_count < i.max_uses
  for update;
  if not found then
    return jsonb_build_object(
      'status', 'invalid',
      'message', 'Invitation code is invalid or expired.'
    );
  end if;

  select r.* into v_room
  from public.private_rooms r
  where r.id = v_invitation.room_id
  for update;
  if exists (
    select 1 from public.room_bans b
    where b.room_id = v_room.id and b.user_id = v_user_id
  ) then
    raise exception 'You are blocked from rejoining this room.'
      using errcode = '42501';
  end if;
  if public.is_private_room_member(v_room.id) then
    return jsonb_build_object(
      'status', 'member', 'room_id', v_room.id,
      'conversation_id', v_room.conversation_id
    );
  end if;
  if (
    select count(*) from public.room_members rm where rm.room_id = v_room.id
  ) >= v_room.max_members then
    raise exception 'This room has reached its member limit.' using errcode = '23514';
  end if;

  update public.room_invitations
  set used_count = used_count + 1
  where id = v_invitation.id;
  if v_invitation.entry_mode = 'approval' then
    insert into public.room_join_requests (room_id, user_id, invitation_id)
    values (v_room.id, v_user_id, v_invitation.id)
    on conflict (room_id, user_id) where status = 'pending'
    do update set created_at = now()
    returning id into v_request_id;
    return jsonb_build_object(
      'status', 'pending', 'request_id', v_request_id, 'room_id', v_room.id
    );
  end if;

  insert into public.room_members (room_id, user_id, role)
  values (v_room.id, v_user_id, 'member');
  return jsonb_build_object(
    'status', 'joined', 'room_id', v_room.id,
    'conversation_id', v_room.conversation_id
  );
end
$$;

create or replace function public.review_room_join_request(
  p_request_id uuid,
  p_approve boolean
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_request public.room_join_requests%rowtype;
  v_room public.private_rooms%rowtype;
begin
  select q.* into v_request
  from public.room_join_requests q
  where q.id = p_request_id and q.status = 'pending'
  for update;
  if not found or not public.is_private_room_admin(v_request.room_id) then
    raise exception 'Only a room owner or administrator may review this request.'
      using errcode = '42501';
  end if;
  select r.* into v_room
  from public.private_rooms r
  where r.id = v_request.room_id
  for update;
  if exists (
    select 1 from public.room_bans b
    where b.room_id = v_room.id and b.user_id = v_request.user_id
  ) then
    raise exception 'This account is blocked from rejoining the room.'
      using errcode = '42501';
  end if;
  if p_approve and (
    select count(*) from public.room_members rm where rm.room_id = v_room.id
  ) >= v_room.max_members then
    raise exception 'This room has reached its member limit.' using errcode = '23514';
  end if;
  update public.room_join_requests
  set status = case when p_approve then 'approved' else 'rejected' end,
      reviewed_by = auth.uid(),
      reviewed_at = now()
  where id = v_request.id;
  if p_approve then
    insert into public.room_members (room_id, user_id, role)
    values (v_room.id, v_request.user_id, 'member')
    on conflict (room_id, user_id) do nothing;
  end if;
end
$$;

create or replace function public.remove_room_member(
  p_room_id uuid,
  p_user_id uuid,
  p_block_reentry boolean default false
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_target_role text;
begin
  if not public.is_private_room_admin(p_room_id) then
    raise exception 'Only a room owner or administrator may remove members.'
      using errcode = '42501';
  end if;
  select rm.role into v_target_role
  from public.room_members rm
  where rm.room_id = p_room_id and rm.user_id = p_user_id;
  if not found or v_target_role = 'owner' then
    raise exception 'The owner cannot be removed from the room.'
      using errcode = '42501';
  end if;
  if v_target_role = 'admin'
    and not exists (
      select 1 from public.private_rooms r
      where r.id = p_room_id and r.owner_id = auth.uid()
    )
  then
    raise exception 'Only the owner can remove an administrator.'
      using errcode = '42501';
  end if;
  delete from public.room_members
  where room_id = p_room_id and user_id = p_user_id;
  if p_block_reentry then
    insert into public.room_bans (room_id, user_id, blocked_by)
    values (p_room_id, p_user_id, auth.uid())
    on conflict (room_id, user_id)
    do update set blocked_by = excluded.blocked_by, created_at = now();
  end if;
end
$$;

create or replace function public.leave_private_room(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_private_room_member(p_room_id) then return; end if;
  if exists (
    select 1 from public.room_members rm
    where rm.room_id = p_room_id and rm.user_id = auth.uid() and rm.role = 'owner'
  ) then
    raise exception 'Transfer ownership before leaving the room.'
      using errcode = '23514';
  end if;
  delete from public.room_members
  where room_id = p_room_id and user_id = auth.uid();
end
$$;

create or replace function public.transfer_private_room_owner(
  p_room_id uuid,
  p_new_owner_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not exists (
    select 1 from public.private_rooms r
    where r.id = p_room_id and r.owner_id = auth.uid()
    for update
  ) then
    raise exception 'Only the current owner can transfer ownership.'
      using errcode = '42501';
  end if;
  if p_new_owner_id = auth.uid() then
    raise exception 'Choose another room member to transfer ownership.'
      using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.room_members rm
    where rm.room_id = p_room_id and rm.user_id = p_new_owner_id
  ) then
    raise exception 'The new owner must already be a room member.'
      using errcode = '22023';
  end if;
  update public.room_members
  set role = case when user_id = auth.uid() then 'admin' else 'owner' end
  where room_id = p_room_id and user_id in (auth.uid(), p_new_owner_id);
  update public.private_rooms
  set owner_id = p_new_owner_id, updated_at = now()
  where id = p_room_id;
end
$$;

create or replace function public.set_private_room_admin(
  p_room_id uuid,
  p_user_id uuid,
  p_make_admin boolean
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not exists (
    select 1 from public.private_rooms r
    where r.id = p_room_id and r.owner_id = auth.uid()
  ) then
    raise exception 'Only the room owner can manage administrators.'
      using errcode = '42501';
  end if;
  update public.room_members
  set role = case when p_make_admin then 'admin' else 'member' end
  where room_id = p_room_id and user_id = p_user_id and role <> 'owner';
  if not found then
    raise exception 'The selected account is not a room member.'
      using errcode = '22023';
  end if;
end
$$;

create or replace function public.update_private_room(
  p_room_id uuid,
  p_name text,
  p_description text,
  p_welcome_text text,
  p_max_members integer,
  p_requires_approval boolean,
  p_image_path text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_conversation_id text;
begin
  if not exists (
    select 1 from public.private_rooms r
    where r.id = p_room_id and r.owner_id = auth.uid()
  ) then
    raise exception 'Only the room owner may edit the room.'
      using errcode = '42501';
  end if;
  if coalesce(char_length(trim(p_name)), 0) not between 1 and 50
    or coalesce(char_length(p_description), 0) > 500
    or coalesce(char_length(p_welcome_text), 0) > 500
    or p_max_members not between 2 and 50
  then
    raise exception 'Room settings are invalid.' using errcode = '22023';
  end if;
  select conversation_id into v_conversation_id
  from public.private_rooms where id = p_room_id;
  if (
    select count(*) from public.room_members where room_id = p_room_id
  ) > p_max_members then
    raise exception 'The member limit cannot be lower than the current membership.'
      using errcode = '23514';
  end if;
  update public.private_rooms
  set name = trim(p_name),
      description = p_description,
      welcome_text = p_welcome_text,
      max_members = p_max_members,
      requires_approval = p_requires_approval,
      image_path = p_image_path,
      updated_at = now()
  where id = p_room_id;
  update public.conversations set name = trim(p_name)
  where id = v_conversation_id;
end
$$;

create or replace function public.mute_private_room_member(
  p_room_id uuid,
  p_user_id uuid,
  p_muted_until timestamptz
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_private_room_admin(p_room_id) then
    raise exception 'Only a room owner or administrator may mute members.'
      using errcode = '42501';
  end if;
  if exists (
    select 1
    from public.room_members target
    join public.private_rooms r on r.id = target.room_id
    where target.room_id = p_room_id
      and target.user_id = p_user_id
      and target.role = 'admin'
      and r.owner_id <> auth.uid()
  ) then
    raise exception 'Only the owner may mute an administrator.'
      using errcode = '42501';
  end if;
  update public.room_members
  set muted_until = p_muted_until
  where room_id = p_room_id and user_id = p_user_id and role <> 'owner';
  if not found then
    raise exception 'The selected account is not a room member.'
      using errcode = '22023';
  end if;
end
$$;

create or replace function public.pin_room_message(
  p_room_id uuid,
  p_message_id uuid,
  p_pin boolean
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_conversation_id text;
begin
  if not public.is_private_room_admin(p_room_id) then
    raise exception 'Only a room owner or administrator may pin an announcement.'
      using errcode = '42501';
  end if;
  select conversation_id into v_conversation_id
  from public.private_rooms where id = p_room_id;
  update public.chat_messages
  set pinned_at = case when p_pin then now() else null end,
      pinned_by = case when p_pin then auth.uid() else null end
  where id = p_message_id and conversation_id = v_conversation_id;
  if not found then
    raise exception 'Message not found in this room.' using errcode = '22023';
  end if;
end
$$;

create or replace function public.pin_chat_message(
  p_message_id uuid,
  p_pin boolean
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_message public.chat_messages%rowtype;
  v_room_id uuid;
  v_is_admin boolean := false;
begin
  select m.* into v_message
  from public.chat_messages m
  where m.id = p_message_id
  for update;
  if not found or (
    v_message.conversation_id <> 'general-v2'
    and not public.is_conversation_member(v_message.conversation_id)
  ) then
    raise exception 'Message is not available in this conversation.'
      using errcode = '42501';
  end if;

  if v_message.sender_id <> auth.uid() then
    select pr.id into v_room_id
    from public.private_rooms pr
    where pr.conversation_id = v_message.conversation_id;
    if v_room_id is not null then
      v_is_admin := public.is_private_room_admin(v_room_id);
    else
      select exists (
        select 1
        from public.conversation_members cm
        join public.conversations c on c.id = cm.conversation_id
        where cm.conversation_id = v_message.conversation_id
          and cm.user_id = auth.uid()
          and (cm.role = 'admin' or c.created_by = auth.uid())
      ) into v_is_admin;
    end if;
    if not v_is_admin then
      raise exception 'Only the sender or a room administrator can pin this message.'
        using errcode = '42501';
    end if;
  end if;

  update public.chat_messages
  set pinned_at = case when p_pin then now() else null end,
      pinned_by = case when p_pin then auth.uid() else null end
  where id = p_message_id;
end
$$;

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
    join public.webrtc_rooms r on r.id = p.room_id
    where p.room_id = p_room_id
      and p.user_id = auth.uid()
      and r.status in ('waiting', 'answered')
      and (
        r.conversation_id = 'general-v2'
        or public.is_conversation_member(r.conversation_id)
      )
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
  join public.webrtc_rooms r on r.id = p.room_id
  where p.room_id = p_room_id
    and p.user_id = auth.uid()
    and r.status in ('waiting', 'answered')
    and (
      r.conversation_id = 'general-v2'
      or public.is_conversation_member(r.conversation_id)
    );
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
    raise exception 'Sign in before starting a voice call.' using errcode = '42501';
  end if;
  if jsonb_typeof(p_offer) is distinct from 'object'
    or p_offer->>'type' is distinct from 'offer'
    or coalesce(p_offer->>'sdp', '') = ''
  then
    raise exception 'A valid WebRTC offer is required.' using errcode = '22023';
  end if;
  select c.* into v_conversation
  from public.conversations c
  where c.id = p_conversation_id
  for update;
  if not found or (
    p_conversation_id <> 'general-v2'
    and not public.is_conversation_member(p_conversation_id)
  ) then
    raise exception 'You are not a member of this conversation.'
      using errcode = '42501';
  end if;
  if public.is_private_room_muted(p_conversation_id) then
    raise exception 'You are muted in this room.' using errcode = '42501';
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
    where p.room_id = v_room.id and p.user_id = v_user_id;
    if v_role is not null then
      return to_jsonb(v_room) || jsonb_build_object('role', v_role);
    elsif v_room.status = 'waiting'
      and not exists (
        select 1 from public.webrtc_room_participants p
        where p.room_id = v_room.id and p.role = 'callee'
      )
    then
      insert into public.webrtc_room_participants (room_id, user_id, role)
      values (v_room.id, v_user_id, 'callee');
      return to_jsonb(v_room) || jsonb_build_object('role', 'callee');
    else
      raise exception 'This voice call already has two participants. End it before starting another.'
        using errcode = '23505';
    end if;
  end if;

  insert into public.webrtc_rooms (conversation_id, created_by, offer, status)
  values (p_conversation_id, v_user_id, p_offer, 'waiting')
  returning * into v_room;
  insert into public.webrtc_room_participants (room_id, user_id, role)
  values (v_room.id, v_user_id, 'caller');
  return to_jsonb(v_room) || jsonb_build_object('role', 'caller');
end
$$;

alter table public.private_rooms enable row level security;
alter table public.room_members enable row level security;
alter table public.room_bans enable row level security;
alter table public.room_invitations enable row level security;
alter table public.room_join_requests enable row level security;

revoke all on public.private_rooms, public.room_members, public.room_bans,
  public.room_invitations, public.room_join_requests
from public, anon, authenticated;
grant select on public.private_rooms, public.room_members to authenticated;
grant select on public.room_join_requests, public.room_invitations,
  public.room_bans to authenticated;
grant delete on public.chat_messages to authenticated;

revoke all on function public.is_private_room_member(uuid),
  public.is_private_room_admin(uuid), public.is_private_room_muted(text),
  public.sync_private_room_membership(), public.create_private_room(text,text,text,integer,boolean,text),
  public.create_room_invitation(uuid,text,integer,integer),
  public.revoke_room_invitation(uuid),
  public.redeem_room_invitation(text),
  public.review_room_join_request(uuid,boolean),
  public.remove_room_member(uuid,uuid,boolean),
  public.leave_private_room(uuid),
  public.transfer_private_room_owner(uuid,uuid),
  public.set_private_room_admin(uuid,uuid,boolean),
  public.update_private_room(uuid,text,text,text,integer,boolean,text),
  public.mute_private_room_member(uuid,uuid,timestamptz),
  public.pin_room_message(uuid,uuid,boolean),
  public.pin_chat_message(uuid,boolean)
from public, anon, authenticated;
grant execute on function public.is_private_room_member(uuid),
  public.is_private_room_admin(uuid), public.is_private_room_muted(text),
  public.create_private_room(text,text,text,integer,boolean,text),
  public.create_room_invitation(uuid,text,integer,integer),
  public.revoke_room_invitation(uuid),
  public.redeem_room_invitation(text),
  public.review_room_join_request(uuid,boolean),
  public.remove_room_member(uuid,uuid,boolean),
  public.leave_private_room(uuid),
  public.transfer_private_room_owner(uuid,uuid),
  public.set_private_room_admin(uuid,uuid,boolean),
  public.update_private_room(uuid,text,text,text,integer,boolean,text),
  public.mute_private_room_member(uuid,uuid,timestamptz),
  public.pin_room_message(uuid,uuid,boolean),
  public.pin_chat_message(uuid,boolean)
to authenticated;

drop policy if exists "conversations_read_members" on public.conversations;
create policy "conversations_read_members"
  on public.conversations for select to authenticated
  using (
    id = 'general-v2'
    or created_by = auth.uid()
    or public.is_conversation_member(id)
  );

drop policy if exists "profiles_read_authenticated" on public.profiles;
drop policy if exists "profiles_read_authorized_contacts" on public.profiles;
create policy "profiles_read_authorized_contacts"
  on public.profiles for select to authenticated
  using (
    id = auth.uid()
    or exists (
      select 1
      from public.conversation_members own_membership
      join public.conversation_members peer_membership
        on peer_membership.conversation_id = own_membership.conversation_id
      where own_membership.user_id = auth.uid()
        and peer_membership.user_id = profiles.id
        and own_membership.conversation_id <> 'general'
    )
  );

drop policy if exists "conversation_members_read" on public.conversation_members;
create policy "conversation_members_read"
  on public.conversation_members for select to authenticated
  using (
    user_id = auth.uid()
    or public.is_conversation_member(conversation_id)
  );

drop policy if exists "conversation_members_remove" on public.conversation_members;
create policy "conversation_members_remove"
  on public.conversation_members for delete to authenticated
  using (
    not exists (
      select 1 from public.private_rooms pr
      where pr.conversation_id = conversation_members.conversation_id
    )
    and (
      user_id = auth.uid()
      or exists (
        select 1 from public.conversations c
        where c.id = conversation_members.conversation_id
          and c.created_by = auth.uid()
      )
    )
  );

drop policy if exists "chat_messages_read_members" on public.chat_messages;
create policy "chat_messages_read_members"
  on public.chat_messages for select to authenticated
  using (
    conversation_id = 'general-v2'
    or public.is_conversation_member(conversation_id)
  );

drop policy if exists "chat_messages_insert_members" on public.chat_messages;
create policy "chat_messages_insert_members"
  on public.chat_messages for insert to authenticated
  with check (
    sender_id = auth.uid()
    and not public.is_private_room_muted(conversation_id)
    and (
      conversation_id = 'general-v2'
      or public.is_conversation_member(conversation_id)
    )
  );

drop policy if exists "chat_messages_delete_own" on public.chat_messages;
create policy "chat_messages_delete_own"
  on public.chat_messages for delete to authenticated
  using (
    sender_id = auth.uid()
    and (
      conversation_id = 'general-v2'
      or public.is_conversation_member(conversation_id)
    )
  );

drop policy if exists "private_rooms_members_read" on public.private_rooms;
create policy "private_rooms_members_read"
  on public.private_rooms for select to authenticated
  using (public.is_private_room_member(id));

drop policy if exists "room_members_room_read" on public.room_members;
create policy "room_members_room_read"
  on public.room_members for select to authenticated
  using (public.is_private_room_member(room_id));

drop policy if exists "room_requests_read_involved" on public.room_join_requests;
create policy "room_requests_read_involved"
  on public.room_join_requests for select to authenticated
  using (
    user_id = auth.uid()
    or public.is_private_room_admin(room_id)
  );

drop policy if exists "room_bans_admin_read" on public.room_bans;
create policy "room_bans_admin_read"
  on public.room_bans for select to authenticated
  using (public.is_private_room_admin(room_id));

drop policy if exists "room_invitations_admin_read" on public.room_invitations;
create policy "room_invitations_admin_read"
  on public.room_invitations for select to authenticated
  using (public.is_private_room_admin(room_id));

do $$
declare
  v_table text;
begin
  if to_regprocedure('public.is_app_account_active()') is not null then
    foreach v_table in array array[
      'private_rooms', 'room_members', 'room_bans',
      'room_invitations', 'room_join_requests'
    ]
    loop
      execute format(
        'drop policy if exists app_account_active on public.%I',
        v_table
      );
      execute format(
        'create policy app_account_active on public.%I as restrictive for all to authenticated using (public.is_app_account_active()) with check (public.is_app_account_active())',
        v_table
      );
    end loop;
  end if;
end
$$;

grant execute on function public.is_webrtc_room_participant(uuid),
  public.webrtc_room_role(uuid),
  public.start_or_join_voice_call(text,jsonb)
to authenticated;

commit;
