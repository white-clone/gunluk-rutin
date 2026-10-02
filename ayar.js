// Supabase bağlantısı. Bu anahtar tarayıcıda herkese açık olacak şekilde tasarlandı;
// veriyi veritabanındaki erişim kuralları (RLS) korur.
window.SUPABASE_URL = 'https://foxacfsypoceaiqlrcwv.supabase.co';
window.SUPABASE_KEY = 'sb_publishable_jkae9u_gWBchCbjLwBjLRA_EU_APVDp';
window.sb = supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
});

// Tema tercihi her sayfada aynı anahtardan okunur.
(() => {
  try {
    const t = (JSON.parse(localStorage.getItem('gunluk-rutin-ui')) || {}).theme;
    if (t === 'light' || t === 'dark') document.documentElement.setAttribute('data-theme', t);
  } catch (e) {}
})();

window.hataMesaji = err => {
  const m = String((err && (err.message || err.error_description)) || '');
  const c = String((err && err.code) || '');
  const s = m + ' ' + c;
  if (/cok_fazla_deneme/.test(s)) return 'Bu isimle çok fazla yanlış deneme yapıldı. 10 dakika sonra tekrar dene ya da e-postanla giriş yap.';
  if (/Invalid login credentials|invalid_credentials/i.test(s)) return 'E-posta ya da şifre hatalı.';
  if (/already registered|already been registered|user_already_exists/i.test(s)) return 'Bu e-posta ile zaten bir hesap var. Giriş yapmayı dene.';
  if (/Password should be|weak_password/i.test(s)) return 'Şifre en az 8 karakter olmalı.';
  if (/same_password|should be different/i.test(s)) return 'Yeni şifre eskisiyle aynı olamaz.';
  if (/rate limit|too many|over_request_rate_limit|over_email_send_rate_limit/i.test(s)) return 'Çok fazla deneme yapıldı. Birkaç dakika sonra tekrar dene.';
  if (/email_address_invalid|invalid.*email|Unable to validate email/i.test(s)) return 'Geçerli bir e-posta adresi gir.';
  if (/Email not confirmed|email_not_confirmed/i.test(s)) return 'Önce e-postana gelen bağlantıyla hesabını doğrula.';
  if (/Failed to fetch|NetworkError|Load failed/i.test(s)) return 'Sunucuya ulaşılamadı. İnternet bağlantını kontrol et.';
  return 'Bir sorun oluştu. ' + (m || 'Tekrar dene.');
};

// Şifre alanlarındaki "Göster" düğmeleri
document.addEventListener('click', e => {
  const b = e.target.closest('[data-show]');
  if (!b) return;
  const input = document.getElementById(b.dataset.show);
  const show = input.type === 'password';
  input.type = show ? 'text' : 'password';
  b.textContent = show ? 'Gizle' : 'Göster';
});
