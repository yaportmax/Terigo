alter table public.app_accounts
    add column if not exists pending_contact_email citext,
    add column if not exists contact_email_verified_at timestamptz;

update public.app_accounts
set pending_contact_email = contact_email
where contact_email is not null
  and pending_contact_email is null
  and contact_email_verified_at is null;

update public.app_accounts
set contact_email = null
where contact_email is not null
  and contact_email_verified_at is null;
