-- Günlük Rutin: görev başına "kaç dakika önce hatırlatılsın"
-- 11-ekipten-arkadas.sql'den sonra bir kez çalıştırılır. Tekrar çalıştırmak güvenlidir.
-- remind_before: işin sahibinin seçimi (dakika; boş = hatırlatma yok). Seçenekler: 0, 5, 10, 15, 30, 60, 1440.
-- giver_remind: görevi veren başkanın kendisi için seçtiği süre.
-- plan_reminders: paylaşılan plan için alıcının kendi seçimi (satır yoksa paylaşanın seçimi geçerli).

alter table public.tasks add column if not exists remind_before int default 0;
alter table public.tasks add column if not exists giver_remind int;
alter table public.tasks drop constraint if exists tasks_remind_chk;
alter table public.tasks add constraint tasks_remind_chk
  check (remind_before in (0, 5, 10, 15, 30, 60, 1440) and giver_remind in (0, 5, 10, 15, 30, 60, 1440));

grant insert (id, user_id, name, type, dur, days, pokeable, due, done, done_at, position, time, end_time, note, remind_before) on public.tasks to authenticated;
grant update (id, user_id, name, type, dur, days, pokeable, due, done, done_at, position, time, end_time, note, remind_before) on public.tasks to authenticated;

create table if not exists public.plan_reminders (
  task_id uuid not null references public.tasks(id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  remind_before int check (remind_before in (0, 5, 10, 15, 30, 60, 1440)),
  primary key (task_id, user_id)
);
alter table public.plan_reminders enable row level security;
revoke all on public.plan_reminders from anon, authenticated;

-- Benimle paylaşılan planın hatırlatmasını kendim seçerim (p_dk boş = hatırlatma yok)
create or replace function public.plan_hatirlat(p_task uuid, p_dk int)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists (
    select 1 from public.task_shares s where s.task_id = p_task and public.ekip_uyesi_mi(s.team_id)
    union all
    select 1 from public.task_friend_shares f where f.task_id = p_task and f.friend_id = auth.uid()
  ) then raise exception 'plan_yok' using errcode = '42501'; end if;
  insert into public.plan_reminders (task_id, user_id, remind_before) values (p_task, auth.uid(), p_dk)
  on conflict (task_id, user_id) do update set remind_before = excluded.remind_before;
end $$;

-- Benimle paylaşılan planlarda geçerli hatırlatma: kendi seçimim, yoksa paylaşanınki
create or replace function public.plan_hatirlatmalarim()
returns table (task_id uuid, dk int)
language sql stable security definer set search_path = '' as $$
  select k.id, case when r.task_id is not null then r.remind_before else k.remind_before end
  from public.tasks k
  left join public.plan_reminders r on r.task_id = k.id and r.user_id = auth.uid()
  where exists (select 1 from public.task_shares s where s.task_id = k.id and public.ekip_uyesi_mi(s.team_id))
     or exists (select 1 from public.task_friend_shares f where f.task_id = k.id and f.friend_id = auth.uid());
$$;

-- Görev verirken hatırlatma süresi: üyenin görevine varsayılan olur, başkanın kendi hatırlatması da bu süredir
drop function if exists public.gorev_ver(uuid, uuid, text, text, int, time, time, int, date, text);
create or replace function public.gorev_ver(p_team uuid, p_uye uuid, p_ad text, p_tur text, p_gunler int,
                                            p_saat time, p_bitis time, p_sure int, p_son date, p_not text default null,
                                            p_hatirlat int default 0)
returns uuid language plpgsql security definer set search_path = '' as $$
declare gid uuid;
begin
  if not exists (select 1 from public.teams where id = p_team and leader = auth.uid()) then
    raise exception 'baskan_degil' using errcode = '42501';
  end if;
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
revoke all on function public.gorev_ver(uuid, uuid, text, text, int, time, time, int, date, text, int) from public;
grant execute on function public.gorev_ver(uuid, uuid, text, text, int, time, time, int, date, text, int) to authenticated;
revoke all on function public.plan_hatirlat(uuid, int), public.plan_hatirlatmalarim() from public;
grant execute on function public.plan_hatirlat(uuid, int), public.plan_hatirlatmalarim() to authenticated;

-- Bildirim metni: "15 dk sonra başlıyor · 14:00–16:00"
create or replace function public.hatirlatma_metni(p_dk int, p_saat time, p_bitis time)
returns text language sql immutable set search_path = '' as $$
  select case
    when p_dk = 0 then 'Planlanan saat geldi'
    when p_dk = 1440 then 'Yarın bu saatte'
    when p_dk = 60 then '1 saat sonra başlıyor'
    else p_dk || ' dk sonra başlıyor' end
    || ' · ' || to_char(p_saat, 'HH24:MI') || coalesce('–' || to_char(p_bitis, 'HH24:MI'), '');
$$;
revoke all on function public.hatirlatma_metni(int, time, time) from public, anon, authenticated;

-- ---------- Hatırlatmalar: 5 dakikada bir ----------
-- Görev hatırlatması, işin saatinden seçilen süre kadar önceki 5 dakikalık dilimde gönderilir.
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
