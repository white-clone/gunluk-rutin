-- Günlük Rutin: ekibin ortak işleri ve yetkili üyeler
-- 12-hatirlatma-suresi.sql'den sonra bir kez çalıştırılır. Tekrar çalıştırmak güvenlidir.
-- Ortak işleri ekibin bütün üyeleri ekler, düzenler ve bitirir; kimin eklediği ve kimin bitirdiği görünür.
-- Başkan, üyelere "yetkili" rolü verebilir; yetkililer de üyelere bireysel görev dağıtır.

alter table public.team_members add column if not exists yetkili boolean not null default false;

-- Başkan ya da yetkili mi?
create or replace function public.ekip_yetkili_mi(p_team uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.teams where id = p_team and leader = auth.uid())
      or exists (select 1 from public.team_members where team_id = p_team and user_id = auth.uid() and yetkili);
$$;
revoke all on function public.ekip_yetkili_mi(uuid) from public;
grant execute on function public.ekip_yetkili_mi(uuid) to authenticated;

-- Başkan üyeye yetki verir ya da yetkiyi alır
create or replace function public.yetki_ver(p_team uuid, p_uye uuid, p_yetkili boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.teams where id = p_team and leader = auth.uid()) then
    raise exception 'baskan_degil' using errcode = '42501';
  end if;
  update public.team_members set yetkili = coalesce(p_yetkili, false) where team_id = p_team and user_id = p_uye;
  if not found then raise exception 'uye_degil'; end if;
end $$;

-- Ekip üyelerinin yetki bilgisi
create or replace function public.ekip_uyeleri(p_team uuid)
returns table (user_id uuid, yetkili boolean)
language sql stable security definer set search_path = '' as $$
  select m.user_id, m.yetkili or t.leader = m.user_id
  from public.team_members m join public.teams t on t.id = m.team_id
  where m.team_id = p_team and public.ekip_uyesi_mi(p_team);
$$;

-- Görev dağıtabildiğim ekipler (başkanı ya da yetkilisi olduğum)
create or replace function public.ekip_yetkilerim()
returns table (team_id uuid)
language sql stable security definer set search_path = '' as $$
  select t.id from public.teams t where t.leader = auth.uid()
  union
  select m.team_id from public.team_members m where m.user_id = auth.uid() and m.yetkili;
$$;

-- Görev verme ve kaldırma: başkan ya da yetkili
create or replace function public.gorev_ver(p_team uuid, p_uye uuid, p_ad text, p_tur text, p_gunler int,
                                            p_saat time, p_bitis time, p_sure int, p_son date, p_not text default null,
                                            p_hatirlat int default 0)
returns uuid language plpgsql security definer set search_path = '' as $$
declare gid uuid;
begin
  if not public.ekip_yetkili_mi(p_team) then raise exception 'baskan_degil' using errcode = '42501'; end if;
  if not exists (select 1 from public.team_members where team_id = p_team and user_id = p_uye) then
    raise exception 'uye_degil';
  end if;
  if char_length(trim(coalesce(p_ad, ''))) = 0 then raise exception 'ad_bos'; end if;
  insert into public.tasks (user_id, name, type, dur, days, time, end_time, due, team_id, assigned_by, position, assign_note,
                            remind_before, giver_remind)
  values (p_uye, left(trim(p_ad), 80), case when p_tur = 'general' then 'general' else 'daily' end,
          case when p_tur = 'general' then 0 else greatest(0, least(600, coalesce(p_sure, 0))) end,
          case when p_gunler between 1 and 127 then p_gunler else 127 end,
          p_saat, case when p_saat is not null and p_bitis > p_saat then p_bitis end,
          case when p_tur = 'general' then p_son end,
          p_team, auth.uid(),
          coalesce((select max(position) + 1 from public.tasks where user_id = p_uye), 0),
          nullif(left(trim(coalesce(p_not, '')), 500), ''),
          p_hatirlat, case when p_uye <> auth.uid() then p_hatirlat end)
  returning id into gid;
  return gid;
end $$;

create or replace function public.ekip_gorev_sil(p_gorev uuid)
returns void language sql security definer set search_path = '' as $$
  delete from public.tasks k where k.id = p_gorev and k.team_id is not null and public.ekip_yetkili_mi(k.team_id);
$$;

-- ---------- Ortak işler ----------
create table if not exists public.team_tasks (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 80),
  due date,
  time time,
  end_time time,
  note text check (char_length(note) <= 500),
  remind_before int default 0 check (remind_before in (0, 5, 10, 15, 30, 60, 1440)),
  done boolean not null default false,
  done_by uuid references auth.users(id) on delete set null,
  done_at timestamptz,
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists team_tasks_team_idx on public.team_tasks (team_id);
alter table public.team_tasks enable row level security;
revoke all on public.team_tasks from anon, authenticated;

-- Üyesi olduğum ekiplerin ortak işleri (p_team boşsa hepsi)
create or replace function public.ortak_isler(p_team uuid default null)
returns table (id uuid, team_id uuid, team_name text, name text, due date, saat time, bitis time, note text,
               remind_before int, done boolean, done_at timestamptz, ekleyen_id uuid, ekleyen text, bitiren text)
language sql stable security definer set search_path = '' as $$
  select e.id, e.team_id, t.name, e.name, e.due, e.time, e.end_time, e.note, e.remind_before, e.done, e.done_at,
         e.created_by, c.full_name, d.full_name
  from public.team_tasks e
  join public.teams t on t.id = e.team_id
  left join public.profiles c on c.id = e.created_by
  left join public.profiles d on d.id = e.done_by
  where (p_team is null or e.team_id = p_team) and public.ekip_uyesi_mi(e.team_id)
  order by e.done, e.due nulls last, e.time nulls last, e.created_at;
$$;

-- Ortak iş ekle (p_id boş) ya da düzenle: ekibin her üyesi
create or replace function public.ortak_is_kaydet(p_id uuid, p_team uuid, p_ad text, p_tarih date, p_saat time,
                                                  p_bitis time, p_not text, p_hatirlat int default 0)
returns uuid language plpgsql security definer set search_path = '' as $$
declare rid uuid;
begin
  if char_length(trim(coalesce(p_ad, ''))) = 0 then raise exception 'ad_bos'; end if;
  if p_id is null then
    if not public.ekip_uyesi_mi(p_team) then raise exception 'ekip_uyesi_degil' using errcode = '42501'; end if;
    insert into public.team_tasks (team_id, name, due, time, end_time, note, remind_before)
    values (p_team, left(trim(p_ad), 80), p_tarih, p_saat, case when p_saat is not null and p_bitis > p_saat then p_bitis end,
            nullif(left(trim(coalesce(p_not, '')), 500), ''), p_hatirlat)
    returning id into rid;
  else
    update public.team_tasks e set name = left(trim(p_ad), 80), due = p_tarih, time = p_saat,
           end_time = case when p_saat is not null and p_bitis > p_saat then p_bitis end,
           note = nullif(left(trim(coalesce(p_not, '')), 500), ''), remind_before = p_hatirlat
    where e.id = p_id and public.ekip_uyesi_mi(e.team_id)
    returning e.id into rid;
    if rid is null then raise exception 'ekip_uyesi_degil' using errcode = '42501'; end if;
  end if;
  return rid;
end $$;

-- Ortak işi bitir ya da geri al: ekibin her üyesi; bitiren kişi kaydedilir
create or replace function public.ortak_is_bitir(p_id uuid, p_bitti boolean)
returns void language sql security definer set search_path = '' as $$
  update public.team_tasks e
  set done = p_bitti, done_by = case when p_bitti then auth.uid() end, done_at = case when p_bitti then now() end
  where e.id = p_id and public.ekip_uyesi_mi(e.team_id);
$$;

-- Ortak işi sil: ekleyen kişi, başkan ya da yetkili
create or replace function public.ortak_is_sil(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  delete from public.team_tasks e
  where e.id = p_id and public.ekip_uyesi_mi(e.team_id) and (e.created_by = auth.uid() or public.ekip_yetkili_mi(e.team_id));
  if not found then raise exception 'silme_yetkisi_yok' using errcode = '42501'; end if;
end $$;

revoke all on function public.yetki_ver(uuid, uuid, boolean), public.ekip_uyeleri(uuid), public.ekip_yetkilerim(),
  public.gorev_ver(uuid, uuid, text, text, int, time, time, int, date, text, int), public.ekip_gorev_sil(uuid),
  public.ortak_isler(uuid), public.ortak_is_kaydet(uuid, uuid, text, date, time, time, text, int),
  public.ortak_is_bitir(uuid, boolean), public.ortak_is_sil(uuid) from public;
grant execute on function public.yetki_ver(uuid, uuid, boolean), public.ekip_uyeleri(uuid), public.ekip_yetkilerim(),
  public.gorev_ver(uuid, uuid, text, text, int, time, time, int, date, text, int), public.ekip_gorev_sil(uuid),
  public.ortak_isler(uuid), public.ortak_is_kaydet(uuid, uuid, text, date, time, time, text, int),
  public.ortak_is_bitir(uuid, boolean), public.ortak_is_sil(uuid) to authenticated;

-- ---------- Hatırlatmalar: ortak işler de eklendi ----------
drop function if exists public.hatirlatma_listesi(text);
create function public.hatirlatma_listesi(p_tur text)
returns table (user_id uuid, baslik text, govde text, etiket text)
language plpgsql stable security definer set search_path = '' as $$
declare
  yerel timestamp := now() at time zone 'Europe/Istanbul';
  gun date := yerel::date;
  bit int := 1 << (extract(isodow from yerel)::int - 1);
  dilim timestamp := date_trunc('hour', yerel) + floor(extract(minute from yerel) / 5) * interval '5 minutes';
  t0 time := dilim::time;
  t1 time := t0 + interval '5 minutes';
begin
  if p_tur <> 'zaman' then return; end if;
  return query
    -- sabah: kişinin sabah saati bu 5 dakikadaysa
    select p.id, 'Günaydın'::text,
           format('Bugün %s işin var. İlki: %s', count(t.id), (array_agg(t.name order by t.time nulls last, t.position))[1]),
           'sabah'::text
    from public.profiles p
    join public.tasks t on t.user_id = p.id and t.type = 'daily' and (t.days & bit) <> 0
    where p.remind_morning and p.morning_time >= t0 and (p.morning_time < t1 or t1 <= t0)
      and exists (select 1 from public.push_subscriptions s where s.user_id = p.id)
      and not exists (select 1 from public.day_logs d where d.user_id = p.id and d.day = gun and d.frozen)
    group by p.id
  union all
    -- akşam: yalnızca bitmemiş iş varsa
    select p.id, 'Gün bitmeden'::text,
           case when coalesce(cardinality(d.done), 0) = 0
             then format('Bugün henüz başlamadın. %s işin seni bekliyor.', pl.n)
             else format('%s iş kaldı.%s', pl.n - cardinality(d.done),
                         case when p.streak > 0 then format(' Serin %s gün, bozma.', p.streak) else '' end)
           end,
           'aksam'::text
    from public.profiles p
    join (select k.user_id, count(*)::int as n from public.tasks k
          where k.type = 'daily' and (k.days & bit) <> 0 group by k.user_id) pl on pl.user_id = p.id
    left join public.day_logs d on d.user_id = p.id and d.day = gun
    where p.remind_evening and p.evening_time >= t0 and (p.evening_time < t1 or t1 <= t0)
      and exists (select 1 from public.push_subscriptions s where s.user_id = p.id)
      and not coalesce(d.frozen, false)
      and coalesce(cardinality(d.done), 0) < pl.n
  union all
    -- işin sahibi (ekip görevi alan üye de kendi satırıyla buraya girer)
    select t.user_id, t.name, public.hatirlatma_metni(t.remind_before, t.time, t.end_time), 'gorev-' || t.id
    from public.tasks t
    join public.profiles p on p.id = t.user_id
    cross join lateral (select dilim + make_interval(mins => t.remind_before) as w0) w
    where p.remind_tasks and t.time is not null and t.remind_before is not null
      and w.w0::date + t.time >= w.w0 and w.w0::date + t.time < w.w0 + interval '5 minutes'
      and exists (select 1 from public.push_subscriptions s where s.user_id = t.user_id)
      and ((t.type = 'daily' and (t.days & (1 << (extract(isodow from w.w0)::int - 1))) <> 0
            and not exists (select 1 from public.day_logs d where d.user_id = t.user_id and d.day = w.w0::date
                            and (d.frozen or t.id::text = any(d.done))))
        or (t.type = 'general' and t.due = w.w0::date and not t.done))
  union all
    -- görevi veren başkan: üye henüz bitirmediyse
    select t.assigned_by, t.name, u.full_name || ' · ' || public.hatirlatma_metni(t.giver_remind, t.time, t.end_time),
           'verilen-' || t.id
    from public.tasks t
    join public.profiles p on p.id = t.assigned_by
    join public.profiles u on u.id = t.user_id
    cross join lateral (select dilim + make_interval(mins => t.giver_remind) as w0) w
    where p.remind_tasks and t.time is not null and t.giver_remind is not null and t.assigned_by <> t.user_id
      and w.w0::date + t.time >= w.w0 and w.w0::date + t.time < w.w0 + interval '5 minutes'
      and exists (select 1 from public.push_subscriptions s where s.user_id = t.assigned_by)
      and ((t.type = 'daily' and (t.days & (1 << (extract(isodow from w.w0)::int - 1))) <> 0
            and not exists (select 1 from public.day_logs d where d.user_id = t.user_id and d.day = w.w0::date
                            and t.id::text = any(d.done)))
        or (t.type = 'general' and t.due = w.w0::date and not t.done))
  union all
    -- işin paylaşıldığı kişiler (ekip üyeleri ve arkadaşlar), kendi seçtikleri süreyle
    select x.uid, k.name, o.full_name || ' · ' || public.hatirlatma_metni(x.dk, k.time, k.end_time), 'plan-' || k.id
    from (
      select a.task_id, a.uid, case when r.task_id is not null then r.remind_before else k2.remind_before end as dk
      from (
        select s.task_id, m.user_id as uid from public.task_shares s
          join public.team_members m on m.team_id = s.team_id where m.user_id <> s.shared_by
        union
        select f.task_id, f.friend_id from public.task_friend_shares f where public.arkadas_mi(f.shared_by, f.friend_id)
      ) a
      join public.tasks k2 on k2.id = a.task_id
      left join public.plan_reminders r on r.task_id = a.task_id and r.user_id = a.uid
    ) x
    join public.tasks k on k.id = x.task_id
    join public.profiles o on o.id = k.user_id
    join public.profiles p on p.id = x.uid
    cross join lateral (select dilim + make_interval(mins => x.dk) as w0) w
    where p.remind_tasks and k.time is not null and x.dk is not null
      and w.w0::date + k.time >= w.w0 and w.w0::date + k.time < w.w0 + interval '5 minutes'
      and exists (select 1 from public.push_subscriptions s where s.user_id = x.uid)
      and ((k.type = 'daily' and (k.days & (1 << (extract(isodow from w.w0)::int - 1))) <> 0)
        or (k.type = 'general' and k.due = w.w0::date and not k.done))
  union all
    -- ekibin ortak işleri: bütün üyelere, işi ekleyenin seçtiği sürede (bitmediyse)
    select m.user_id, e.name, tm.name || ' · ' || public.hatirlatma_metni(e.remind_before, e.time, e.end_time), 'ortak-' || e.id
    from public.team_tasks e
    join public.teams tm on tm.id = e.team_id
    join public.team_members m on m.team_id = e.team_id
    join public.profiles p on p.id = m.user_id
    cross join lateral (select dilim + make_interval(mins => e.remind_before) as w0) w
    where p.remind_tasks and not e.done and e.time is not null and e.due is not null and e.remind_before is not null
      and e.due = w.w0::date and e.due + e.time >= w.w0 and e.due + e.time < w.w0 + interval '5 minutes'
      and exists (select 1 from public.push_subscriptions s where s.user_id = m.user_id)
  union all
    -- haftalık özet: Pazar 20:00
    select p.id, 'Haftalık özet'::text,
           format('Bu hafta %s/7 gün tamam. Serin %s gün, en uzun serin %s gün.',
                  (select count(*) from public.day_logs d
                    where d.user_id = p.id and d.day > gun - 7 and d.day <= gun
                      and d.total > 0 and cardinality(d.done) >= d.total),
                  p.streak, p.best_streak),
           'haftalik'::text
    from public.profiles p
    where extract(isodow from yerel) = 7 and time '20:00' >= t0 and time '20:00' < t1
      and p.weekly_summary
      and exists (select 1 from public.push_subscriptions s where s.user_id = p.id);
end $$;
revoke all on function public.hatirlatma_listesi(text) from public, anon, authenticated;
grant execute on function public.hatirlatma_listesi(text) to service_role;
