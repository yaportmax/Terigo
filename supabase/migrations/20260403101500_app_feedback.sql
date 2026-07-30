create table if not exists public.app_feedback (
    id uuid primary key default gen_random_uuid(),
    account_id uuid not null references public.app_accounts(id) on delete cascade,
    session_id uuid references public.app_sessions(id) on delete set null,
    strava_athlete_id bigint not null,
    display_name text not null,
    message text not null,
    source_screen text not null default 'unknown',
    app_version text,
    build_number text,
    created_at timestamptz not null default timezone('utc', now())
);

create index if not exists app_feedback_account_created_idx
    on public.app_feedback(account_id, created_at desc);

alter table public.app_feedback enable row level security;

comment on table public.app_feedback is 'Temporary in-app tester feedback collected from signed-in Terigo accounts.';
