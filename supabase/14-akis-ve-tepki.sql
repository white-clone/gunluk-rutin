-- Günlük Rutin: akış (seri dönüm noktaları, ortak işler), tepkiler, mesaj tonu
-- 13-ekip-ortak-isler.sql'den sonra bir kez çalıştırılır. Tekrar çalıştırmak güvenlidir.

alter table public.profiles
  add column if not exists message_tone text not null default 'samimi',
  add column if not exists notify_reactions boolean not null default true,
  add column if not exists notify_milestones boolean not null default true;
alter table public.profiles drop constraint if exists profiles_tone_chk;
alter table public.profiles add constraint profiles_tone_chk check (message_tone in ('samimi', 'sade', 'esprili'));
grant update (message_tone, notify_reactions, notify_milestones) on public.profiles to authenticated;

-- Olaylar: kind 'seri' (value = gün), kind 'ortak' (ekipte ortak iş bitirildi; ref = ortak iş)
create table if not exists public.events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('seri', 'ortak')),
  value int,
  team_id uuid references public.teams(id) on delete cascade,
  ref uuid,
  task_name text,
  created_at timestamptz not null default now()
);
create index if not exists events_user_idx on public.events (user_id, created_at desc);
create index if not exists events_team_idx on public.events (team_id, created_at desc);
alter table public.events enable row level security;
revoke all on public.events from anon, authenticated;

-- Tepkiler: olay başına kişi başı bir tepki
create table if not exists public.reactions (
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  emoji text not null check (emoji in ('alkis', 'harika', 'guclu', 'sevgi')),
  note text check (char_length(note) <= 80),
  created_at timestamptz not null default now(),
  primary key (event_id, user_id)
);
alter table public.reactions enable row level security;
revoke all on public.reactions from anon, authenticated;

-- Olayı görebilir miyim? Seri: kendim ya da ilerlemesini paylaşan arkadaşım. Ortak iş: ekibimdeyse.
create or replace function public.olay_gorur_mu(e public.events)
returns boolean language sql stable security definer set search_path = '' as $$
  select e.user_id = auth.uid()
      or (e.kind = 'seri' and public.arkadas_mi(auth.uid(), e.user_id)
          and exists (select 1 from public.profiles p where p.id = e.user_id and p.share_progress))
      or (e.kind = 'ortak' and e.team_id is not null and public.ekip_uyesi_mi(e.team_id));
$$;
revoke all on function public.olay_gorur_mu(public.events) from public, anon, authenticated;

-- Seri dönüm noktası olayı (uygulama, gün tamamlanıp seri dönüm noktasına ulaşınca çağırır)
create or replace function public.seri_olayi(p_gun int)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or p_gun not in (3, 7, 14, 21, 30, 50, 100, 200, 365) then return; end if;
  -- aynı dönüm noktası iki gün içinde tekrar yazılmaz
  if exists (select 1 from public.events where user_id = auth.uid() and kind = 'seri' and value = p_gun
             and created_at > now() - interval '2 days') then return; end if;
  insert into public.events (user_id, kind, value) values (auth.uid(), 'seri', p_gun);
end $$;

-- Ortak iş bitince akışa olay düşer; geri alınınca olay da kalkar
create or replace function public.ortak_is_bitir(p_id uuid, p_bitti boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare e public.team_tasks;
begin
  update public.team_tasks t
  set done = p_bitti, done_by = case when p_bitti then auth.uid() end, done_at = case when p_bitti then now() end
  where t.id = p_id and public.ekip_uyesi_mi(t.team_id)
  returning * into e;
  if e.id is null then return; end if;
  delete from public.events where kind = 'ortak' and ref = p_id;
  if p_bitti then
    insert into public.events (user_id, kind, team_id, ref, task_name) values (auth.uid(), 'ortak', e.team_id, e.id, e.name);
  end if;
end $$;

-- Akış: son 30 gün; tepki sayıları, benim tepkim ve kimin ne gönderdiği
create or replace function public.akis()
returns table (id uuid, user_id uuid, ad text, kind text, value int, task_name text, team_name text,
               created_at timestamptz, benim boolean, tepkim text, notum text, sayilar jsonb, tepkiler jsonb, son_tepki timestamptz)
language sql stable security definer set search_path = '' as $$
  select e.id, e.user_id, coalesce(n.nickname, p.full_name), e.kind, e.value, e.task_name, t.name,
         e.created_at, e.user_id = auth.uid(), mr.emoji, mr.note,
         coalesce((select jsonb_object_agg(x.emoji, x.c) from (select r.emoji, count(*) c from public.reactions r
                   where r.event_id = e.id group by r.emoji) x), '{}'::jsonb),
         coalesce((select jsonb_agg(jsonb_build_object('ad', coalesce(n2.nickname, g.full_name), 'emoji', r.emoji, 'not', r.note)
                   order by r.created_at desc)
                   from public.reactions r join public.profiles g on g.id = r.user_id
                   left join public.nicknames n2 on n2.owner = auth.uid() and n2.target = r.user_id
                   where r.event_id = e.id), '[]'::jsonb),
         (select max(r.created_at) from public.reactions r where r.event_id = e.id)
  from public.events e
  join public.profiles p on p.id = e.user_id
  left join public.teams t on t.id = e.team_id
  left join public.nicknames n on n.owner = auth.uid() and n.target = e.user_id
  left join public.reactions mr on mr.event_id = e.id and mr.user_id = auth.uid()
  where e.created_at > now() - interval '30 days' and public.olay_gorur_mu(e)
  order by e.created_at desc
  limit 200;
$$;

-- Tepki ver, değiştir ya da kaldır (p_emoji boş = kaldır). Kendi olayına tepki verilmez.
create or replace function public.tepki_ver(p_event uuid, p_emoji text, p_not text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare e public.events;
begin
  select * into e from public.events where id = p_event;
  if e.id is null or not public.olay_gorur_mu(e) then raise exception 'olay_yok' using errcode = '42501'; end if;
  if e.user_id = auth.uid() then raise exception 'kendi_olayin'; end if;
  if p_emoji is null then
    delete from public.reactions where event_id = p_event and user_id = auth.uid();
    return;
  end if;
  insert into public.reactions (event_id, user_id, emoji, note)
  values (p_event, auth.uid(), p_emoji, nullif(left(trim(coalesce(p_not, '')), 80), ''))
  on conflict (event_id, user_id) do update set emoji = excluded.emoji, note = excluded.note;
end $$;

-- Bildirim metinleri
create or replace function public.tepki_adi(p text)
returns text language sql immutable set search_path = '' as $$
  select case p when 'alkis' then '👏 Alkış' when 'harika' then '🔥 Harika' when 'guclu' then '💪 Güçlü' else '❤️ Sevgiler' end;
$$;
create or replace function public.olay_metni(p_kind text, p_value int, p_task text)
returns text language sql immutable set search_path = '' as $$
  select case when p_kind = 'seri' then p_value || ' günlük serin için' else '"' || coalesce(p_task, 'Ortak iş') || '" işini bitirdiğin için' end;
$$;
revoke all on function public.tepki_adi(text), public.olay_metni(text, int, text) from public, anon, authenticated;

revoke all on function public.seri_olayi(int), public.ortak_is_bitir(uuid, boolean), public.akis(), public.tepki_ver(uuid, text, text) from public;
grant execute on function public.seri_olayi(int), public.ortak_is_bitir(uuid, boolean), public.akis(), public.tepki_ver(uuid, text, text) to authenticated;

-- ---------- Hatırlatmalar: akşam seri uyarısı, tepki ve arkadaş dönüm noktası bildirimleri ----------
-- Tepki ve dönüm noktası bildirimleri, 5 dakikada bir çalışan görevde bir önceki 5 dakikada oluşanlar için gönderilir.
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
           case
             -- seri varsa uyarı: "5 günlük serin tehlikede · 2 iş kaldı · 1 izin hakkın var"
             when p.streak > 0 then format('%s günlük serin tehlikede · %s iş kaldı%s', p.streak,
                    pl.n - coalesce(cardinality(d.done), 0),
                    case when iz.hak > 0 then format(' · %s izin hakkın var', iz.hak) else '' end)
             when coalesce(cardinality(d.done), 0) = 0
             then format('Bugün henüz başlamadın. %s işin seni bekliyor.', pl.n)
             else format('%s iş kaldı.', pl.n - cardinality(d.done))
           end,
           'aksam'::text
    from public.profiles p
    join (select k.user_id, count(*)::int as n from public.tasks k
          where k.type = 'daily' and (k.days & bit) <> 0 group by k.user_id) pl on pl.user_id = p.id
    left join public.day_logs d on d.user_id = p.id and d.day = gun
    cross join lateral (select 2 - count(*)::int as hak from public.day_logs z
                        where z.user_id = p.id and z.frozen and date_trunc('month', z.day) = date_trunc('month', gun)) iz
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
    -- tepki: olayın sahibine, son 5 dakikada gelen tepkiler
    select e.user_id, g.full_name || ' ' || public.tepki_adi(r.emoji) || ' gönderdi',
           coalesce(nullif(r.note, ''), public.olay_metni(e.kind, e.value, e.task_name)), 'tepki-' || e.id || '-' || r.user_id
    from public.reactions r
    join public.events e on e.id = r.event_id
    join public.profiles p on p.id = e.user_id
    join public.profiles g on g.id = r.user_id
    where p.notify_reactions and r.created_at at time zone 'Europe/Istanbul' >= dilim - interval '5 minutes'
      and r.created_at at time zone 'Europe/Istanbul' < dilim
      and exists (select 1 from public.push_subscriptions s where s.user_id = e.user_id)
  union all
    -- arkadaşın seri dönüm noktası: arkadaşlarına (ilerlemesini paylaşıyorsa)
    select f.uid, coalesce(n.nickname, a.full_name) || ' ' || e.value || ' günlük seriye ulaştı',
           'Tebrik etmek için Arkadaşlar → Akış', 'seri-' || e.id
    from public.events e
    join public.profiles a on a.id = e.user_id
    join (select fr.requester as x, fr.addressee as uid from public.friendships fr where fr.status = 'accepted'
          union all select fr.addressee, fr.requester from public.friendships fr where fr.status = 'accepted') f on f.x = e.user_id
    join public.profiles p on p.id = f.uid
    left join public.nicknames n on n.owner = f.uid and n.target = e.user_id
    where e.kind = 'seri' and a.share_progress and p.notify_milestones
      and e.created_at at time zone 'Europe/Istanbul' >= dilim - interval '5 minutes'
      and e.created_at at time zone 'Europe/Istanbul' < dilim
      and exists (select 1 from public.push_subscriptions s where s.user_id = f.uid)
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
