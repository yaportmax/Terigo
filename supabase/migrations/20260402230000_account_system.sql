create extension if not exists pgcrypto;
create extension if not exists citext;

create table if not exists public.app_accounts (
    id uuid primary key default gen_random_uuid(),
    strava_athlete_id bigint not null unique,
    display_name text not null,
    avatar_url text,
    contact_email citext unique,
    created_at timestamptz not null default timezone('utc', now()),
    updated_at timestamptz not null default timezone('utc', now())
);

create table if not exists public.app_sessions (
    id uuid primary key default gen_random_uuid(),
    account_id uuid not null references public.app_accounts(id) on delete cascade,
    session_token_hash text not null unique,
    device_platform text not null default 'ios',
    app_version text,
    build_number text,
    created_at timestamptz not null default timezone('utc', now()),
    last_used_at timestamptz not null default timezone('utc', now()),
    expires_at timestamptz not null
);

create table if not exists public.route_lists (
    id uuid primary key default gen_random_uuid(),
    owner_account_id uuid not null references public.app_accounts(id) on delete cascade,
    client_list_id text,
    name text not null,
    list_description text not null default '',
    visibility text not null default 'private' check (visibility in ('private', 'link_view')),
    collaboration_mode text not null default 'owner_only' check (collaboration_mode in ('owner_only', 'link_editors', 'invited_editors')),
    share_token text not null unique default encode(gen_random_bytes(18), 'hex'),
    remote_revision integer not null default 1,
    created_at timestamptz not null default timezone('utc', now()),
    updated_at timestamptz not null default timezone('utc', now()),
    deleted_at timestamptz
);

create unique index if not exists route_lists_owner_client_list_idx
    on public.route_lists(owner_account_id, client_list_id)
    where client_list_id is not null and deleted_at is null;

create table if not exists public.route_list_members (
    id uuid primary key default gen_random_uuid(),
    list_id uuid not null references public.route_lists(id) on delete cascade,
    account_id uuid not null references public.app_accounts(id) on delete cascade,
    role text not null check (role in ('owner', 'editor', 'viewer')),
    created_at timestamptz not null default timezone('utc', now()),
    updated_at timestamptz not null default timezone('utc', now()),
    unique(list_id, account_id)
);

create table if not exists public.route_list_invites (
    id uuid primary key default gen_random_uuid(),
    list_id uuid not null references public.route_lists(id) on delete cascade,
    invited_email citext not null,
    role text not null check (role in ('editor', 'viewer')),
    created_at timestamptz not null default timezone('utc', now()),
    accepted_at timestamptz,
    unique(list_id, invited_email)
);

create table if not exists public.shared_route_snapshots (
    id uuid primary key default gen_random_uuid(),
    owner_account_id uuid not null references public.app_accounts(id) on delete cascade,
    strava_route_id bigint not null,
    route_name text not null,
    route_description text not null default '',
    distance_meters double precision not null default 0,
    elevation_gain_meters double precision not null default 0,
    estimated_moving_time double precision not null default 0,
    sport_kind text not null default 'other',
    surface_kind text,
    display_location text not null default '',
    is_private_on_strava boolean not null default false,
    summary_polyline text not null default '',
    detail_polyline text,
    gpx_payload text,
    created_at timestamptz not null default timezone('utc', now()),
    updated_at timestamptz not null default timezone('utc', now()),
    unique(owner_account_id, strava_route_id)
);

create table if not exists public.route_list_routes (
    id uuid primary key default gen_random_uuid(),
    list_id uuid not null references public.route_lists(id) on delete cascade,
    shared_route_snapshot_id uuid references public.shared_route_snapshots(id) on delete set null,
    strava_route_id bigint not null,
    route_name text not null,
    route_description text not null default '',
    distance_meters double precision not null default 0,
    elevation_gain_meters double precision not null default 0,
    estimated_moving_time double precision not null default 0,
    sport_kind text not null default 'other',
    surface_kind text,
    display_location text not null default '',
    summary_polyline text not null default '',
    detail_polyline text,
    shareability_status text not null default 'viewable' check (shareability_status in ('viewable', 'downloadable', 'blocked_private_not_downloaded', 'view_only')),
    shareability_message text,
    sort_order integer not null default 0,
    created_at timestamptz not null default timezone('utc', now()),
    unique(list_id, strava_route_id)
);

create table if not exists public.route_list_followers (
    id uuid primary key default gen_random_uuid(),
    list_id uuid not null references public.route_lists(id) on delete cascade,
    account_id uuid not null references public.app_accounts(id) on delete cascade,
    created_at timestamptz not null default timezone('utc', now()),
    unique(list_id, account_id)
);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at = timezone('utc', now());
    return new;
end;
$$;

drop trigger if exists app_accounts_set_updated_at on public.app_accounts;
create trigger app_accounts_set_updated_at
before update on public.app_accounts
for each row execute function public.set_updated_at();

drop trigger if exists route_lists_set_updated_at on public.route_lists;
create trigger route_lists_set_updated_at
before update on public.route_lists
for each row execute function public.set_updated_at();

drop trigger if exists route_list_members_set_updated_at on public.route_list_members;
create trigger route_list_members_set_updated_at
before update on public.route_list_members
for each row execute function public.set_updated_at();

drop trigger if exists shared_route_snapshots_set_updated_at on public.shared_route_snapshots;
create trigger shared_route_snapshots_set_updated_at
before update on public.shared_route_snapshots
for each row execute function public.set_updated_at();

alter table public.app_accounts enable row level security;
alter table public.app_sessions enable row level security;
alter table public.route_lists enable row level security;
alter table public.route_list_members enable row level security;
alter table public.route_list_invites enable row level security;
alter table public.shared_route_snapshots enable row level security;
alter table public.route_list_routes enable row level security;
alter table public.route_list_followers enable row level security;

comment on table public.app_accounts is 'Terigo accounts keyed off Strava identity. Access is mediated by edge functions.';
comment on table public.route_lists is 'Backend-synced lists. Visibility and collaboration are enforced via edge functions.';
