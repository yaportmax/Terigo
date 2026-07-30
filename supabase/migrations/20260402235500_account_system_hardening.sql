insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
    'route-shared-gpx',
    'route-shared-gpx',
    false,
    20971520,
    array['application/gpx+xml', 'application/xml', 'text/xml', 'text/plain']
)
on conflict (id) do update
set
    public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

alter table public.shared_route_snapshots
    add column if not exists gpx_storage_bucket text,
    add column if not exists gpx_storage_path text,
    add column if not exists gpx_file_size_bytes bigint;

create unique index if not exists shared_route_snapshots_storage_path_idx
    on public.shared_route_snapshots(gpx_storage_bucket, gpx_storage_path)
    where gpx_storage_bucket is not null and gpx_storage_path is not null;
