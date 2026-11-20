begin;

create extension if not exists pgtap with schema extensions;

insert into auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data
)
values
  (
    'a1d00000-0000-4000-8000-000000000001', 'authenticated',
    'authenticated', 'admin-panel-owner@example.invalid',
    crypt('temporary-test-password', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}', '{"display_name":"Owner"}'
  ),
  (
    'a1d00000-0000-4000-8000-000000000002', 'authenticated',
    'authenticated', 'admin-panel-member@example.invalid',
    crypt('temporary-test-password', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}', '{"display_name":"Member"}'
  );
insert into public.profiles (id, display_name)
values
  ('a1d00000-0000-4000-8000-000000000001', 'Owner'),
  ('a1d00000-0000-4000-8000-000000000002', 'Member');
insert into public.app_admins (user_id)
values ('a1d00000-0000-4000-8000-000000000001');

select extensions.plan(8);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub', 'a1d00000-0000-4000-8000-000000000001', true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
select ok(public.is_app_admin(), 'the explicitly bootstrapped owner is an admin');
select is(
  public.get_app_admin_dashboard(10, 0) ->> 'registered_accounts',
  (select count(*)::text from auth.users
   where coalesce(raw_app_meta_data ->> 'provider', 'email') <> 'anonymous'),
  'dashboard counts registered accounts and excludes anonymous guests'
);
select ok(public.record_app_activity(60),
  'foreground usage can be recorded through the server');
select lives_ok(
  $query$
    select public.admin_update_user_access(
      'a1d00000-0000-4000-8000-000000000002', true, true
    )
  $query$,
  'super admin can suspend an account and grant courtesy premium'
);
select is(
  (select count(*)::int from public.app_admin_audit_log
   where actor_id = auth.uid()
     and target_user_id = 'a1d00000-0000-4000-8000-000000000002'),
  2,
  'both access changes are attributed in the audit log'
);
select is(
  (select banned_until::text from auth.users
   where id = 'a1d00000-0000-4000-8000-000000000002'),
  'infinity',
  'suspension also blocks future Supabase Auth sessions'
);

select set_config(
  'request.jwt.claim.sub', 'a1d00000-0000-4000-8000-000000000002', true
);
select ok(not public.is_app_admin(), 'ordinary accounts are not admins');
select throws_ok(
  $query$
    select public.admin_update_user_access(
      'a1d00000-0000-4000-8000-000000000001', false, false
    )
  $query$,
  '42501',
  'Only a Dido Live super administrator can change account access.',
  'ordinary accounts cannot change access or premium'
);

select * from extensions.finish();
rollback;
