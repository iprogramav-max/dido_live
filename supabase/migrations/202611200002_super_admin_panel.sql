begin;

create table if not exists public.app_admins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  added_at timestamptz not null default now(),
  added_by uuid references auth.users (id) on delete set null
);

create table if not exists public.app_user_access (
  user_id uuid primary key references auth.users (id) on delete cascade,
  suspended boolean not null default false,
  courtesy_premium boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users (id) on delete set null
);

create table if not exists public.app_user_usage_daily (
  user_id uuid not null references auth.users (id) on delete cascade,
  usage_day date not null default current_date,
  foreground_seconds integer not null default 0
    check (foreground_seconds between 0 and 86400),
  last_used_at timestamptz not null default now(),
  last_heartbeat_at timestamptz not null default now(),
  primary key (user_id, usage_day)
);

create index if not exists app_user_usage_daily_day_user_idx
  on public.app_user_usage_daily (usage_day desc, user_id);

create table if not exists public.app_admin_audit_log (
  id bigint generated always as identity primary key,
  actor_id uuid not null references auth.users (id) on delete restrict,
  target_user_id uuid not null references auth.users (id) on delete restrict,
  action text not null check (
    action in ('suspended', 'reactivated', 'courtesy_premium_granted',
      'courtesy_premium_removed')
  ),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists app_admin_audit_log_created_idx
  on public.app_admin_audit_log (created_at desc);

alter table public.app_admins enable row level security;
alter table public.app_user_access enable row level security;
alter table public.app_user_usage_daily enable row level security;
alter table public.app_admin_audit_log enable row level security;

revoke all on public.app_admins, public.app_user_access,
  public.app_user_usage_daily, public.app_admin_audit_log
from public, anon, authenticated;

create or replace function public.is_app_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select auth.uid() is not null and exists (
    select 1 from public.app_admins a where a.user_id = auth.uid()
  );
$$;

create or replace function public.is_app_account_active()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select auth.uid() is not null and not exists (
    select 1
    from public.app_user_access a
    where a.user_id = auth.uid() and a.suspended
  );
$$;

create or replace function public.record_app_activity(p_foreground_seconds integer)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_recorded boolean := false;
begin
  if v_user_id is null or not public.is_app_account_active() then
    raise exception 'An active signed-in account is required.'
      using errcode = '42501';
  end if;
  if p_foreground_seconds not between 1 and 120 then
    raise exception 'Foreground time must be between 1 and 120 seconds.'
      using errcode = '22023';
  end if;

  insert into public.app_user_usage_daily (
    user_id, usage_day, foreground_seconds, last_used_at, last_heartbeat_at
  ) values (
    v_user_id, current_date, 0, now(), now() - interval '1 minute'
  )
  on conflict (user_id, usage_day) do nothing;

  update public.app_user_usage_daily
  set foreground_seconds = least(86400, foreground_seconds + p_foreground_seconds),
      last_used_at = now(),
      last_heartbeat_at = now()
  where user_id = v_user_id
    and usage_day = current_date
    and last_heartbeat_at <= now() - interval '45 seconds';
  v_recorded := found;
  return v_recorded;
end
$$;

create or replace function public.get_app_admin_dashboard(
  p_limit integer default 100,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_result jsonb;
begin
  if not public.is_app_admin() then
    raise exception 'Only a Dido Live super administrator can view this panel.'
      using errcode = '42501';
  end if;
  if p_limit not between 1 and 100 or p_offset < 0 then
    raise exception 'Invalid account page.' using errcode = '22023';
  end if;

  with registered as (
    select u.id, u.email, u.created_at,
      p.display_name,
      coalesce(a.suspended, false) as suspended,
      coalesce(a.courtesy_premium, false) as courtesy_premium,
      usage.last_used_at,
      coalesce(usage.foreground_seconds, 0) as foreground_seconds
    from auth.users u
    left join public.profiles p on p.id = u.id
    left join public.app_user_access a on a.user_id = u.id
    left join lateral (
      select max(d.last_used_at) as last_used_at,
        sum(d.foreground_seconds)::integer as foreground_seconds
      from public.app_user_usage_daily d
      where d.user_id = u.id
    ) usage on true
    where coalesce(u.raw_app_meta_data ->> 'provider', 'email') <> 'anonymous'
  ),
  daily_activity as (
    select day::date as day,
      count(distinct d.user_id)::integer as active_users
    from generate_series(current_date - 29, current_date, interval '1 day') day
    left join public.app_user_usage_daily d on d.usage_day = day::date
    left join auth.users u on u.id = d.user_id
      and coalesce(u.raw_app_meta_data ->> 'provider', 'email') <> 'anonymous'
    where d.user_id is null or u.id is not null
    group by day
  ),
  account_page as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', id,
      'email', email,
      'display_name', coalesce(display_name, split_part(email, '@', 1), 'Usuario'),
      'created_at', created_at,
      'suspended', suspended,
      'courtesy_premium', courtesy_premium,
      'last_used_at', last_used_at,
      'foreground_minutes', round(foreground_seconds / 60.0)::integer
    ) order by created_at desc), '[]'::jsonb) as accounts
    from (
      select * from registered
      order by created_at desc
      limit p_limit offset p_offset
    ) page
  )
  select jsonb_build_object(
    'registered_accounts', (select count(*) from registered),
    'active_today', (
      select count(distinct d.user_id)
      from public.app_user_usage_daily d
      join auth.users u on u.id = d.user_id
      where d.usage_day = current_date
        and coalesce(u.raw_app_meta_data ->> 'provider', 'email') <> 'anonymous'
    ),
    'active_last_7_days', (
      select count(distinct d.user_id)
      from public.app_user_usage_daily d
      join auth.users u on u.id = d.user_id
      where d.usage_day >= current_date - 6
        and coalesce(u.raw_app_meta_data ->> 'provider', 'email') <> 'anonymous'
    ),
    'courtesy_premium_accounts', (
      select count(*) from public.app_user_access a
      join auth.users u on u.id = a.user_id
      where a.courtesy_premium
        and coalesce(u.raw_app_meta_data ->> 'provider', 'email') <> 'anonymous'
    ),
    'activity_by_day', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'day', day, 'active_users', active_users
      ) order by day), '[]'::jsonb)
      from daily_activity
    ),
    'recent_audit', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'actor_email', actor.email,
        'target_email', target.email,
        'action', log.action,
        'created_at', log.created_at
      ) order by log.created_at desc), '[]'::jsonb)
      from (
        select * from public.app_admin_audit_log
        order by created_at desc
        limit 25
      ) log
      join auth.users actor on actor.id = log.actor_id
      join auth.users target on target.id = log.target_user_id
    ),
    'accounts', (select accounts from account_page),
    'offset', p_offset,
    'limit', p_limit
  ) into v_result;
  return v_result;
end
$$;

create or replace function public.admin_update_user_access(
  p_target_user_id uuid,
  p_suspended boolean,
  p_courtesy_premium boolean
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_old_suspended boolean := false;
  v_old_premium boolean := false;
begin
  if not public.is_app_admin() then
    raise exception 'Only a Dido Live super administrator can change account access.'
      using errcode = '42501';
  end if;
  if p_target_user_id is null or not exists (
    select 1 from auth.users u where u.id = p_target_user_id
  ) then
    raise exception 'The selected account does not exist.' using errcode = '22023';
  end if;
  if p_target_user_id = auth.uid() and p_suspended then
    raise exception 'You cannot suspend your own super administrator account.'
      using errcode = '42501';
  end if;

  select coalesce(a.suspended, false), coalesce(a.courtesy_premium, false)
  into v_old_suspended, v_old_premium
  from (select 1) seed
  left join public.app_user_access a on a.user_id = p_target_user_id;

  insert into public.app_user_access (
    user_id, suspended, courtesy_premium, updated_at, updated_by
  ) values (
    p_target_user_id, p_suspended, p_courtesy_premium, now(), auth.uid()
  )
  on conflict (user_id) do update
  set suspended = excluded.suspended,
      courtesy_premium = excluded.courtesy_premium,
      updated_at = now(),
      updated_by = auth.uid();

  update auth.users
  set banned_until = case
    when p_suspended then 'infinity'::timestamptz
    else null
  end
  where id = p_target_user_id;

  if v_old_suspended is distinct from p_suspended then
    insert into public.app_admin_audit_log (
      actor_id, target_user_id, action, details
    ) values (
      auth.uid(), p_target_user_id,
      case when p_suspended then 'suspended' else 'reactivated' end,
      jsonb_build_object('previous', v_old_suspended, 'current', p_suspended)
    );
  end if;
  if v_old_premium is distinct from p_courtesy_premium then
    insert into public.app_admin_audit_log (
      actor_id, target_user_id, action, details
    ) values (
      auth.uid(), p_target_user_id,
      case when p_courtesy_premium
        then 'courtesy_premium_granted'
        else 'courtesy_premium_removed'
      end,
      jsonb_build_object('previous', v_old_premium, 'current', p_courtesy_premium)
    );
  end if;
end
$$;

revoke all on function public.is_app_admin(),
  public.is_app_account_active(),
  public.record_app_activity(integer),
  public.get_app_admin_dashboard(integer,integer),
  public.admin_update_user_access(uuid,boolean,boolean)
from public, anon, authenticated;
grant execute on function public.is_app_admin(),
  public.is_app_account_active(),
  public.record_app_activity(integer),
  public.get_app_admin_dashboard(integer,integer),
  public.admin_update_user_access(uuid,boolean,boolean)
to authenticated;

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'profiles', 'conversations', 'conversation_members', 'chat_messages',
    'webrtc_rooms', 'webrtc_ice_candidates', 'webrtc_room_participants',
    'private_rooms', 'room_members', 'room_bans', 'room_invitations',
    'room_join_requests'
  ]
  loop
    if to_regclass(format('public.%I', v_table)) is not null then
      execute format(
        'drop policy if exists app_account_active on public.%I',
        v_table
      );
      execute format(
        'create policy app_account_active on public.%I as restrictive for all to authenticated using (public.is_app_account_active()) with check (public.is_app_account_active())',
        v_table
      );
    end if;
  end loop;
end
$$;

drop policy if exists app_account_active_on_storage on storage.objects;
create policy app_account_active_on_storage
  on storage.objects as restrictive for all to authenticated
  using (public.is_app_account_active())
  with check (public.is_app_account_active());

comment on table public.app_user_usage_daily is
  'Aggregated foreground usage only; never stores chat or voice content.';
comment on table public.app_admin_audit_log is
  'Audit trail for super administrator access and courtesy premium changes.';

-- Bootstrap only after review: add the owner's auth.users UUID through the
-- Supabase SQL editor as the database owner. Do not expose this table to clients.
-- insert into public.app_admins (user_id) values ('<owner-auth-user-uuid>');

commit;
