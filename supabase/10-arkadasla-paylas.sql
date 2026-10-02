-- Günlük Rutin: ekip olmadan, işi doğrudan arkadaşlarla paylaşma (ortak plan)
-- 9-notlar.sql'den sonra bir kez çalıştırılır. Tekrar çalıştırmak güvenlidir.

create table if not exists public.task_friend_shares (
  task_id uuid not null references public.tasks(id) on delete cascade,
  friend_id uuid not null references auth.users(id) on delete cascade,
  shared_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  notified_at timestamptz,
  primary key (task_id, friend_id)
);
create index if not exists task_friend_shares_friend_idx on public.task_friend_shares (friend_id);
alter table public.task_friend_shares enable row level security;
revoke all on public.task_friend_shares from anon, authenticated;

-- Kendi işini bir arkadaşınla paylaş (yalnızca kabul edilmiş arkadaşlar)
create or replace function public.arkadasla_paylas(p_task uuid, p_friend uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.tasks where id = p_task and user_id = auth.uid() and team_id is null) then
    raise exception 'gorev_senin_degil' using errcode = '42501';
  end if;
  if not public.arkadas_mi(auth.uid(), p_friend) then raise exception 'arkadas_degil' using errcode = '42501'; end if;
  insert into public.task_friend_shares (task_id, friend_id, shared_by) values (p_task, p_friend, auth.uid())
  on conflict do nothing;
end $$;

create or replace function public.arkadas_paylasimi_kaldir(p_task uuid, p_friend uuid)
returns void language sql security definer set search_path = '' as $$
  delete from public.task_friend_shares where task_id = p_task and friend_id = p_friend and shared_by = auth.uid();
$$;

-- Kendi işlerimin hangi arkadaşlarla paylaşıldığı
create or replace function public.arkadas_paylasimlarim()
returns table (task_id uuid, friend_id uuid)
language sql stable security definer set search_path = '' as $$
  select s.task_id, s.friend_id from public.task_friend_shares s where s.shared_by = auth.uid();
$$;

-- Arkadaşlarımın benimle paylaştığı planlar; paylaşan kişi, ona taktığım lakapla görünür
create or replace function public.ortak_planlar()
returns table (task_id uuid, name text, type text, due date, days int, saat time, bitis time, owner_name text)
language sql stable security definer set search_path = '' as $$
  select k.id, k.name, k.type, k.due, k.days, k.time, k.end_time, coalesce(n.nickname, p.full_name)
  from public.task_friend_shares s
  join public.tasks k on k.id = s.task_id
  join public.profiles p on p.id = k.user_id
  left join public.nicknames n on n.owner = auth.uid() and n.target = k.user_id
  where s.friend_id = auth.uid()
    and public.arkadas_mi(auth.uid(), k.user_id)
    and (k.type = 'daily' or not k.done)
  order by k.due nulls first, k.time nulls last, k.name;
$$;

-- Arkadaşlıktan çıkınca karşılıklı plan paylaşımları da kalkar
create or replace function public.arkadas_sil(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare f public.friendships;
begin
  delete from public.friendships where id = p_id and auth.uid() in (requester, addressee) returning * into f;
  if f.id is not null then
    delete from public.nicknames
      where (owner = f.requester and target = f.addressee) or (owner = f.addressee and target = f.requester);
    delete from public.task_friend_shares
      where (shared_by = f.requester and friend_id = f.addressee) or (shared_by = f.addressee and friend_id = f.requester);
  end if;
end $$;

revoke all on function public.arkadasla_paylas(uuid, uuid), public.arkadas_paylasimi_kaldir(uuid, uuid),
  public.arkadas_paylasimlarim(), public.ortak_planlar() from public;
grant execute on function public.arkadasla_paylas(uuid, uuid), public.arkadas_paylasimi_kaldir(uuid, uuid),
  public.arkadas_paylasimlarim(), public.ortak_planlar() to authenticated;
