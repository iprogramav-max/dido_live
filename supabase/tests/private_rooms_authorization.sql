begin;

create extension if not exists pgtap with schema extensions;

insert into auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data
)
values
  (
    'd2d00000-0000-4000-8000-000000000001', 'authenticated',
    'authenticated', 'room-owner@example.invalid',
    crypt('temporary-test-password', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}', '{"display_name":"Owner"}'
  ),
  (
    'd2d00000-0000-4000-8000-000000000002', 'authenticated',
    'authenticated', 'room-member@example.invalid',
    crypt('temporary-test-password', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}', '{"display_name":"Member"}'
  ),
  (
    'd2d00000-0000-4000-8000-000000000003', 'authenticated',
    'authenticated', 'other-room@example.invalid',
    crypt('temporary-test-password', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}', '{"display_name":"Other"}'
  );

insert into public.profiles (id, display_name)
values
  ('d2d00000-0000-4000-8000-000000000001', 'Owner'),
  ('d2d00000-0000-4000-8000-000000000002', 'Member'),
  ('d2d00000-0000-4000-8000-000000000003', 'Other');

select extensions.plan(18);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub', 'd2d00000-0000-4000-8000-000000000001', true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config(
  'test.private_room',
  public.create_private_room(
    'Familia', 'Private room', 'Welcome', 50, true, null
  )::text,
  true
);
select set_config(
  'test.room_id',
  (current_setting('test.private_room')::jsonb ->> 'id'),
  true
);
select set_config(
  'test.conversation_id',
  (current_setting('test.private_room')::jsonb ->> 'conversation_id'),
  true
);
select set_config(
  'test.invite_code',
  public.create_room_invitation(
    current_setting('test.room_id')::uuid, 'approval', 168, 50
  ),
  true
);
select is(
  (current_setting('test.private_room')::jsonb ->> 'voice_member_limit')::int,
  2,
  'room capacity is independent from the two-person voice limit'
);
select is(length(current_setting('test.invite_code')), 36,
  'invitation code is generated as a random one-time secret');

select set_config(
  'request.jwt.claim.sub', 'd2d00000-0000-4000-8000-000000000002', true
);
select set_config(
  'test.join_result',
  public.redeem_room_invitation(current_setting('test.invite_code')),
  true
);
select is(
  current_setting('test.join_result')::jsonb ->> 'status',
  'pending',
  'approval invitation creates a pending request, not membership'
);

select set_config(
  'request.jwt.claim.sub', 'd2d00000-0000-4000-8000-000000000001', true
);
select set_config(
  'test.request_id',
  (
    select id::text from public.room_join_requests
    where room_id = current_setting('test.room_id')::uuid
      and user_id = 'd2d00000-0000-4000-8000-000000000002'
      and status = 'pending'
  ),
  true
);
select lives_ok(
  format(
    'select public.review_room_join_request(%L::uuid, true)',
    current_setting('test.request_id')
  ),
  'room owner can approve a pending request'
);
select lives_ok(
  format(
    'select public.transfer_private_room_owner(%L::uuid, %L::uuid)',
    current_setting('test.room_id'),
    'd2d00000-0000-4000-8000-000000000002'
  ),
  'current owner can transfer ownership to a member'
);

select set_config(
  'request.jwt.claim.sub', 'd2d00000-0000-4000-8000-000000000002', true
);
select ok(
  public.is_private_room_member(current_setting('test.room_id')::uuid),
  'approved user becomes a room member'
);
insert into public.chat_messages (
  conversation_id, sender_id, body
)
values (
  current_setting('test.conversation_id'), auth.uid(), 'Familia message'
);
select is(
  (select owner_id::text from public.private_rooms
   where id = current_setting('test.room_id')::uuid),
  'd2d00000-0000-4000-8000-000000000002',
  'ownership transfer is reflected in the room'
);

select set_config(
  'request.jwt.claim.sub', 'd2d00000-0000-4000-8000-000000000003', true
);
select ok(
  not public.is_private_room_member(current_setting('test.room_id')::uuid),
  'third account remains outside the private room'
);
select is(
  (select count(*)::int from public.private_rooms
   where id = current_setting('test.room_id')::uuid),
  0,
  'third account cannot read the private room or member list'
);
select is(
  (select count(*)::int from public.profiles
   where id = 'd2d00000-0000-4000-8000-000000000001'),
  0,
  'third account cannot read profiles outside shared conversations'
);
select is(
  (select count(*)::int from public.chat_messages
   where conversation_id = current_setting('test.conversation_id')),
  0,
  'third account cannot read private room chat'
);
select is(
  (select count(*)::int from public.conversations where id = 'general'),
  0,
  'new accounts cannot read the previous General history'
);
select is(
  (select count(*)::int from public.conversations where id = 'general-v2'),
  1,
  'fresh General remains available to a single account'
);
select throws_ok(
  format(
    'select public.start_or_join_voice_call(%L, %L::jsonb)',
    current_setting('test.conversation_id'),
    '{"type":"offer","sdp":"test-sdp"}'
  ),
  '42501',
  'You are not a member of this conversation.',
  'third account cannot start or join room voice'
);

reset role;
insert into public.room_members (room_id, user_id, role)
values (
  current_setting('test.room_id')::uuid,
  'd2d00000-0000-4000-8000-000000000003',
  'member'
);
set local role authenticated;
select set_config(
  'request.jwt.claim.sub', 'd2d00000-0000-4000-8000-000000000002', true
);
select lives_ok(
  format(
    'select public.remove_room_member(%L::uuid, %L::uuid, true)',
    current_setting('test.room_id'),
    'd2d00000-0000-4000-8000-000000000003'
  ),
  'room owner can remove and block re-entry separately'
);
select set_config(
  'request.jwt.claim.sub', 'd2d00000-0000-4000-8000-000000000003', true
);
select ok(
  not public.is_private_room_member(current_setting('test.room_id')::uuid),
  'removed account loses room membership immediately'
);
select throws_ok(
  format(
    'select public.redeem_room_invitation(%L)',
    current_setting('test.invite_code')
  ),
  '42501',
  'You are blocked from rejoining this room.',
  'blocked account cannot re-enter with an unexpired invitation'
);
select is(
  (
    select count(*)::int
    from generate_series(1, 10) attempt_number
    cross join lateral public.redeem_room_invitation(repeat('x', 36))
      as attempt(result)
    where attempt.result ->> 'status' = 'invalid'
  ),
  10,
  'invalid invitation attempts are recorded instead of rolled back'
);
select is(
  public.redeem_room_invitation(repeat('x', 36)) ->> 'status',
  'rate_limited',
  'the server rate-limits the eleventh invitation attempt'
);

select * from extensions.finish();
rollback;
