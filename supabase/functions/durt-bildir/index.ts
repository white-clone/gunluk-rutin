// Dürtme bildirimi gönderir. Uygulama önce public.durt() ile kaydı açar, sonra bu fonksiyonu çağırır.
// { anahtar: true } ile çağrılırsa bildirim aboneliği için gereken açık VAPID anahtarını döndürür.
// { gorev_id } ile çağrılırsa ekip başkanının verdiği yeni görevi üyeye bildirir.
// { plan_id } ile çağrılırsa arkadaşlarla yeni paylaşılan planı, henüz haber verilmemiş arkadaşlara bildirir.
import { createClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';

const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

// VAPID anahtarları ilk ihtiyaçta üretilip gizli ayarlara yazılır; sonra hep aynısı kullanılır.
async function vapid() {
  const oku = async () => {
    const [a, b] = await Promise.all([
      sb.rpc('ayar_oku', { p_ad: 'vapid_public' }),
      sb.rpc('ayar_oku', { p_ad: 'vapid_private' }),
    ]);
    return a.data && b.data ? { publicKey: a.data as string, privateKey: b.data as string } : null;
  };
  let k = await oku();
  if (!k) {
    const yeni = webpush.generateVAPIDKeys();
    await sb.rpc('ayar_yaz', { p_ad: 'vapid_public', p_deger: yeni.publicKey });
    await sb.rpc('ayar_yaz', { p_ad: 'vapid_private', p_deger: yeni.privateKey });
    k = await oku(); // aynı anda üretildiyse ilk yazılan geçerli
  }
  webpush.setVapidDetails('https://white-clone.github.io/gunluk-rutin/', k!.publicKey, k!.privateKey);
  return k!;
}

async function gonder(userId: string, payload: Record<string, unknown>) {
  const { data: subs } = await sb.from('push_subscriptions').select('endpoint, p256dh, auth').eq('user_id', userId);
  let n = 0;
  for (const s of subs ?? []) {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, JSON.stringify(payload), { TTL: 3600 });
      n++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) await sb.from('push_subscriptions').delete().eq('endpoint', s.endpoint);
    }
  }
  return n;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const body = await req.json().catch(() => ({}));
    const k = await vapid();
    if (body.anahtar) return json({ publicKey: k.publicKey });

    const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
    const { data: { user } } = await sb.auth.getUser(token);
    if (!user) return json({ error: 'giris_gerekli' }, 401);

    if (body.plan_id) {
      const { data: shares } = await sb.from('task_friend_shares').select('friend_id')
        .eq('task_id', body.plan_id).eq('shared_by', user.id).is('notified_at', null);
      if (!shares?.length) return json({ gonderildi: 0 });
      await sb.from('task_friend_shares').update({ notified_at: new Date().toISOString() })
        .eq('task_id', body.plan_id).eq('shared_by', user.id).is('notified_at', null);
      const { data: plan } = await sb.from('tasks').select('name, due, time, end_time').eq('id', body.plan_id).single();
      const { data: prof } = await sb.from('profiles').select('full_name').eq('id', user.id).single();
      const zaman = [plan?.due, plan?.time ? String(plan.time).slice(0, 5) + (plan?.end_time ? '–' + String(plan.end_time).slice(0, 5) : '') : ''].filter(Boolean).join(' · ');
      let n = 0;
      for (const s of shares) {
        const { data: nick } = await sb.from('nicknames').select('nickname').eq('owner', s.friend_id).eq('target', user.id).maybeSingle();
        n += await gonder(s.friend_id, {
          title: `${nick?.nickname || prof?.full_name || 'Bir arkadaşın'} seninle bir plan paylaştı`,
          body: [plan?.name, zaman].filter(Boolean).join(' · '),
          url: './', tag: `plan-${body.plan_id}`,
        });
      }
      return json({ gonderildi: n });
    }

    if (body.gorev_id) {
      const { data: gorev } = await sb.from('tasks').select('id, user_id, name, team_id, assigned_by')
        .eq('id', body.gorev_id).eq('assigned_by', user.id).is('notified_at', null).maybeSingle();
      if (!gorev) return json({ error: 'gorev_yok' }, 404);
      await sb.from('tasks').update({ notified_at: new Date().toISOString() }).eq('id', gorev.id);
      const [{ data: ekip }, { data: lider }] = await Promise.all([
        sb.from('teams').select('name').eq('id', gorev.team_id).single(),
        sb.from('profiles').select('full_name').eq('id', user.id).single(),
      ]);
      const n = await gonder(gorev.user_id, {
        title: `Yeni görev: ${gorev.name}`,
        body: [ekip?.name, lider?.full_name].filter(Boolean).join(' · '),
        url: './', tag: `gorev-${gorev.id}`,
      });
      return json({ gonderildi: n });
    }

    const { data: poke } = await sb.from('pokes').select('*')
      .eq('id', body.poke_id).eq('sender', user.id).is('pushed_at', null).maybeSingle();
    if (!poke) return json({ error: 'durtme_yok' }, 404);
    await sb.from('pokes').update({ pushed_at: new Date().toISOString() }).eq('id', poke.id);

    // Alıcı, gönderene lakap taktıysa bildirimde o lakap görünür
    const [{ data: nick }, { data: prof }] = await Promise.all([
      sb.from('nicknames').select('nickname').eq('owner', poke.target).eq('target', poke.sender).maybeSingle(),
      sb.from('profiles').select('full_name').eq('id', poke.sender).single(),
    ]);
    const ad = nick?.nickname || prof?.full_name || 'Bir arkadaşın';
    const govde = [poke.task_name, poke.note].filter(Boolean).join(' · ') || 'Bugünkü işlerini hatırlatıyor.';
    const n = await gonder(poke.target, { title: `${ad} seni dürttü`, body: govde, url: './#arkadaslar', tag: `durt-${poke.sender}` });
    return json({ gonderildi: n });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
