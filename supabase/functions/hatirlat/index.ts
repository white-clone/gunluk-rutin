// Sabah, akşam ve haftalık hatırlatmaları gönderir. Yalnızca pg_cron çağırır;
// çağrı, veritabanındaki gizli 'cron' anahtarını x-cron başlığında taşımalıdır.
import { createClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';

const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json' } });

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
    k = await oku();
  }
  webpush.setVapidDetails('https://white-clone.github.io/gunluk-rutin/', k!.publicKey, k!.privateKey);
}

async function gonder(userId: string, payload: Record<string, unknown>) {
  const { data: subs } = await sb.from('push_subscriptions').select('endpoint, p256dh, auth').eq('user_id', userId);
  let n = 0;
  for (const s of subs ?? []) {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, JSON.stringify(payload), { TTL: 6 * 3600 });
      n++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) await sb.from('push_subscriptions').delete().eq('endpoint', s.endpoint);
    }
  }
  return n;
}

Deno.serve(async (req) => {
  const { data: gizli } = await sb.rpc('ayar_oku', { p_ad: 'cron' });
  if (!gizli || req.headers.get('x-cron') !== gizli) return json({ error: 'yetki_yok' }, 401);
  const { tur } = await req.json().catch(() => ({ tur: '' }));
  if (!['sabah', 'aksam', 'haftalik'].includes(tur)) return json({ error: 'tur_gecersiz' }, 400);
  await vapid();
  const { data: rows, error } = await sb.rpc('hatirlatma_listesi', { p_tur: tur });
  if (error) return json({ error: error.message }, 500);
  let n = 0;
  for (const r of rows ?? []) {
    n += await gonder(r.user_id, { title: r.baslik, body: r.govde, url: './', tag: `hatirlat-${tur}` });
  }
  return json({ kisi: rows?.length ?? 0, bildirim: n });
});
