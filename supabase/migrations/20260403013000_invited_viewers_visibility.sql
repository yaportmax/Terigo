alter table public.route_lists
    drop constraint if exists route_lists_visibility_check;

alter table public.route_lists
    add constraint route_lists_visibility_check
    check (visibility in ('private', 'invited_viewers', 'link_view'));
