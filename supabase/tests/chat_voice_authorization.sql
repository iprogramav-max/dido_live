begin;

create extension if not exists pgtap with schema extensions;

insert into auth.users (
  id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  raw_app_meta_data,
  raw_user_meta_data
)
values
  (
    'd1d00000-0000-4000-8000-000000000001',
    'authenticated',
    'authenticated',
    'dido-authz-1@example.invalid',
    crypt('temporary-test-password', gen_salt('bf')),
    now(),
    '{"provider":"email","providers":["email"]}',
    '{"display_name":"Auth test one"}'
  ),
  (
    'd1d00000-0000-4000-8000-000000000002',
    'authenticated',
    'authenticated',
    'dido-authz-2@example.invalid',
    crypt('temporary-test-password', gen_salt('bf')),
    now(),
    '{"provider":"email","providers":["email"]}',
    '{"display_name":"Auth test two"}'
  ),
  (
    'd1d00000-0000-4000-8000-000000000003',
    'authenticated',
    'authenticated',
    'dido-authz-3@example.invalid',
    crypt('temporary-test-password', gen_salt('bf')),
    now(),
    '{"provider":"email","providers":["email"]}',
    '{"display_name":"Auth test three"}'
  );

insert into public.profiles (id, display_name)
values
  ('d1d00000-0000-4000-8000-000000000001', 'Auth test one'),
  ('d1d00000-0000-4000-8000-000000000002', 'Auth test two'),
  ('d1d00000-0000-4000-8000-000000000003', 'Auth test three');

select extensions.plan(29);

set local role authenticated;

select set_config(
  'request.jwt.claim.sub',
  'd1d00000-0000-4000-8000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config(
  'test.personal_conversation_id',
  public.open_direct_conversation(
    'd1d00000-0000-4000-8000-000000000002'
  ),
  true
);

select extensions.throws_ok(
  format(
    'select public.start_or_join_voice_call(%L, %L::jsonb)',
    current_setting('test.personal_conversation_id'),
    '{"sdp":"missing-offer-type"}'
  ),
  '22023',
  'A valid WebRTC offer is required.',
  'an offer without a type is rejected'
);
select extensions.throws_ok(
  format(
    'select public.start_or_join_voice_call(%L, %L::jsonb)',
    current_setting('test.personal_conversation_id'),
    '{"type":"answer","sdp":"wrong-offer-type"}'
  ),
  '22023',
  'A valid WebRTC offer is required.',
  'an offer with a non-offer type is rejected'
);

insert into public.chat_messages (conversation_id, sender_id, body)
values (
  current_setting('test.personal_conversation_id'),
  auth.uid(),
  'private message for two participants'
);

select set_config(
  'test.personal_room',
  public.start_or_join_voice_call(
    current_setting('test.personal_conversation_id'),
    '{"type":"offer","sdp":"test-offer"}'::jsonb
  )->>'id',
  true
);

select set_config(
  'test.personal_caller_retry',
  public.start_or_join_voice_call(
    current_setting('test.personal_conversation_id'),
    '{"type":"offer","sdp":"repeated-caller-offer"}'::jsonb
  )::text,
  true
);
select extensions.is(
  current_setting('test.personal_caller_retry')::jsonb->>'id',
  current_setting('test.personal_room'),
  'a repeated caller request returns the same room'
);
select extensions.is(
  current_setting('test.personal_caller_retry')::jsonb->>'role',
  'caller',
  'a repeated caller request returns the same role'
);
select extensions.is(
  (
    select status = 'waiting' and answer is null
    from public.webrtc_rooms
    where id = current_setting('test.personal_room')::uuid
  ),
  true,
  'a repeated request does not end a call waiting for its answer'
);

insert into public.webrtc_ice_candidates (
  room_id, conversation_id, sender, candidate
)
values (
  current_setting('test.personal_room')::uuid,
  current_setting('test.personal_conversation_id'),
  'caller',
  '{"candidate":"test-caller-candidate"}'::jsonb
);

select extensions.is(
  (
    select count(*)::integer
    from public.conversation_members
    where conversation_id = current_setting('test.personal_conversation_id')
  ),
  2,
  'personal conversation creation adds exactly two participants'
);

select set_config(
  'request.jwt.claim.sub',
  'd1d00000-0000-4000-8000-000000000002',
  true
);

select extensions.is(
  (
    select count(*)::integer
    from public.chat_messages
    where conversation_id = current_setting('test.personal_conversation_id')
  ),
  1,
  'the second personal participant can read the chat'
);

select set_config(
  'test.personal_join_role',
  public.start_or_join_voice_call(
    current_setting('test.personal_conversation_id'),
    '{"type":"offer","sdp":"unused-callee-offer"}'::jsonb
  )->>'role',
  true
);

select set_config(
  'test.personal_callee_retry',
  public.start_or_join_voice_call(
    current_setting('test.personal_conversation_id'),
    '{"type":"offer","sdp":"repeated-callee-offer"}'::jsonb
  )::text,
  true
);
select extensions.is(
  current_setting('test.personal_callee_retry')::jsonb->>'id',
  current_setting('test.personal_room'),
  'a repeated callee request returns the same room'
);
select extensions.is(
  current_setting('test.personal_callee_retry')::jsonb->>'role',
  'callee',
  'a repeated callee request returns the same role'
);

select extensions.throws_ok(
  format(
    'select public.answer_voice_call(%L::uuid, %L::jsonb)',
    current_setting('test.personal_room'),
    '{"sdp":"missing-answer-type"}'
  ),
  '22023',
  'A valid WebRTC answer is required.',
  'an answer without a type is rejected'
);
select extensions.throws_ok(
  format(
    'select public.answer_voice_call(%L::uuid, %L::jsonb)',
    current_setting('test.personal_room'),
    '{"type":"offer","sdp":"wrong-answer-type"}'
  ),
  '22023',
  'A valid WebRTC answer is required.',
  'an answer with a non-answer type is rejected'
);

select public.answer_voice_call(
  current_setting('test.personal_room')::uuid,
  '{"type":"answer","sdp":"test-answer"}'::jsonb
);

insert into public.webrtc_ice_candidates (
  room_id, conversation_id, sender, candidate
)
values (
  current_setting('test.personal_room')::uuid,
  current_setting('test.personal_conversation_id'),
  'callee',
  '{"candidate":"test-callee-candidate"}'::jsonb
);

select extensions.is(
  current_setting('test.personal_join_role'),
  'callee',
  'the second personal participant joins as callee'
);
select extensions.is(
  (
    select count(*)::integer
    from public.webrtc_ice_candidates
    where room_id = current_setting('test.personal_room')::uuid
  ),
  2,
  'both personal-call participants can exchange ICE candidates'
);
select extensions.is(
  public.can_view_profile_photo(
    'd1d00000-0000-4000-8000-000000000001'
  ),
  true,
  'a personal conversation participant can access the other participant photo'
);

select set_config(
  'request.jwt.claim.sub',
  'd1d00000-0000-4000-8000-000000000003',
  true
);

select extensions.is(
  (
    select count(*)::integer
    from public.chat_messages
    where conversation_id = current_setting('test.personal_conversation_id')
  ),
  0,
  'a third account cannot read a personal chat'
);
select extensions.is(
  (
    select count(*)::integer
    from public.webrtc_rooms
    where id = current_setting('test.personal_room')::uuid
  ),
  0,
  'a third account cannot read personal-call signaling'
);
select extensions.is(
  (
    select count(*)::integer
    from public.webrtc_ice_candidates
    where room_id = current_setting('test.personal_room')::uuid
  ),
  0,
  'a third account cannot read personal-call ICE candidates'
);
select extensions.is(
  public.can_view_profile_photo(
    'd1d00000-0000-4000-8000-000000000001'
  ),
  false,
  'a third account cannot access a private-conversation photo'
);

select extensions.throws_ok(
  format(
    'select public.start_or_join_voice_call(%L, %L::jsonb)',
    current_setting('test.personal_conversation_id'),
    '{"type":"offer","sdp":"unauthorized"}'
  ),
  '42501',
  'You are not a participant in this conversation.',
  'a third account cannot join a personal call'
);
select extensions.throws_ok(
  format(
    'insert into public.chat_messages (conversation_id, sender_id, body) values (%L, auth.uid(), %L)',
    current_setting('test.personal_conversation_id'),
    'unauthorized message'
  ),
  '42501',
  'new row violates row-level security policy for table "chat_messages"',
  'a third account cannot write to a personal chat'
);
select extensions.throws_ok(
  format(
    'insert into public.webrtc_ice_candidates (room_id, conversation_id, sender, candidate) values (%L::uuid, %L, %L, %L::jsonb)',
    current_setting('test.personal_room'),
    current_setting('test.personal_conversation_id'),
    'caller',
    '{"candidate":"unauthorized"}'
  ),
  '42501',
  'new row violates row-level security policy for table "webrtc_ice_candidates"',
  'a third account cannot inject ICE into a personal call'
);
select extensions.throws_ok(
  format(
    'select public.answer_voice_call(%L::uuid, %L::jsonb)',
    current_setting('test.personal_room'),
    '{"type":"answer","sdp":"unauthorized"}'
  ),
  '42501',
  'Only this call''s callee can submit an answer.',
  'a third account cannot answer a personal call'
);
select extensions.throws_ok(
  format(
    'insert into public.conversation_members (conversation_id, user_id, role) values (%L, auth.uid(), %L)',
    current_setting('test.personal_conversation_id'),
    'member'
  ),
  '42501',
  'new row violates row-level security policy for table "conversation_members"',
  'a third account cannot add itself to a personal conversation'
);

select set_config(
  'request.jwt.claim.sub',
  'd1d00000-0000-4000-8000-000000000001',
  true
);
select set_config(
  'test.general_room',
  public.start_or_join_voice_call(
    'general',
    '{"type":"offer","sdp":"test-general-offer"}'::jsonb
  )->>'id',
  true
);
insert into public.webrtc_ice_candidates (
  room_id, conversation_id, sender, candidate
)
values (
  current_setting('test.general_room')::uuid,
  'general',
  'caller',
  '{"candidate":"test-general-caller-candidate"}'::jsonb
);

select set_config(
  'request.jwt.claim.sub',
  'd1d00000-0000-4000-8000-000000000002',
  true
);
select public.start_or_join_voice_call(
  'general',
  '{"type":"offer","sdp":"unused-general-callee-offer"}'::jsonb
);
select set_config(
  'request.jwt.claim.sub',
  'd1d00000-0000-4000-8000-000000000003',
  true
);
select extensions.throws_ok(
  format(
    'select public.start_or_join_voice_call(%L, %L::jsonb)',
    'general',
    '{"type":"offer","sdp":"third-general-offer-before-answer"}'
  ),
  '23505',
  'This voice call already has two participants; start a new call after one participant ends it.',
  'a third General user cannot join before the callee submits an answer'
);

select set_config(
  'request.jwt.claim.sub',
  'd1d00000-0000-4000-8000-000000000002',
  true
);
select public.answer_voice_call(
  current_setting('test.general_room')::uuid,
  '{"type":"answer","sdp":"test-general-answer"}'::jsonb
);
insert into public.webrtc_ice_candidates (
  room_id, conversation_id, sender, candidate
)
values (
  current_setting('test.general_room')::uuid,
  'general',
  'callee',
  '{"candidate":"test-general-callee-candidate"}'::jsonb
);

select set_config(
  'request.jwt.claim.sub',
  'd1d00000-0000-4000-8000-000000000003',
  true
);
select extensions.is(
  (
    select count(*)::integer
    from public.webrtc_rooms
    where id = current_setting('test.general_room')::uuid
  ),
  0,
  'a third General user cannot read a two-person call'
);
select extensions.is(
  (
    select count(*)::integer
    from public.webrtc_ice_candidates
    where room_id = current_setting('test.general_room')::uuid
  ),
  0,
  'a third General user cannot read call ICE candidates'
);
select extensions.throws_ok(
  format(
    'select public.start_or_join_voice_call(%L, %L::jsonb)',
    'general',
    '{"type":"offer","sdp":"third-general-offer"}'
  ),
  '23505',
  'This voice call already has two participants; start a new call after one participant ends it.',
  'a third General user cannot join an occupied call'
);
select extensions.throws_ok(
  format(
    'insert into public.webrtc_ice_candidates (room_id, conversation_id, sender, candidate) values (%L::uuid, %L, %L, %L::jsonb)',
    current_setting('test.general_room'),
    'general',
    'caller',
    '{"candidate":"third-general-candidate"}'
  ),
  '42501',
  'new row violates row-level security policy for table "webrtc_ice_candidates"',
  'a third General user cannot inject ICE into the call'
);
select extensions.throws_ok(
  format(
    'select public.end_voice_call(%L::uuid)',
    current_setting('test.general_room')
  ),
  '42501',
  'Only a participant can end this voice call.',
  'a third General user cannot end the call'
);

reset role;
select * from extensions.finish();
rollback;
