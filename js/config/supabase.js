// Dawam Attendance - Supabase Configuration
// Environment switch: ONLY localhost / 127.0.0.1 / staging.* hosts use the staging project.
// Every other address (including the live site and any unexpected address) uses LIVE, so a mistake can never send real users to staging.
const DAWAM_IS_STAGING = ['localhost', '127.0.0.1'].includes(location.hostname) || location.hostname.startsWith('staging.');
const SUPABASE_URL = DAWAM_IS_STAGING
    ? 'https://jbfdaeyqsszoacrijldk.supabase.co'
    : 'https://kyktwzwiraipwyglkhva.supabase.co';
const SUPABASE_ANON_KEY = DAWAM_IS_STAGING
    ? 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImpiZmRhZXlxc3N6b2FjcmlqbGRrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTA5NDg5OTksImV4cCI6MjEwNjUyNDk5OX0.h3Cb8TJfkppvpsmh65Zkb_0W0F3VxJf1O8ISpp7M5UA'
    : 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt5a3R3endpcmFpcHd5Z2xraHZhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzIwMTA2MTcsImV4cCI6MjA4NzU4NjYxN30.acOQWJkfE6Ew9PVyEKNeGxs7ri7QH_AarpPcoT34RBY';

// Login system. Staging uses the new Supabase Auth login (ROADMAP security step S2); the live site keeps the old login
// until the planned cutover (S5). One place to switch: change this line when the live database is ready.
const DAWAM_AUTH_MODE = 'supabase';
// Login email = <username>@<company code>.<this domain>. The app builds it; nothing is ever sent to it.
// Must match supabase/migrations/002_auth_login.sql (checked by tests/static-checks.js).
const DAWAM_LOGIN_EMAIL_DOMAIN = 'dawam.arwaenterprises.com';

// Visible reminder when running against staging
if (DAWAM_IS_STAGING) {
    document.addEventListener('DOMContentLoaded', () => {
        const b = document.createElement('div');
        b.textContent = 'STAGING';
        b.style.cssText = 'position:fixed;top:0;left:0;z-index:99999;background:#e53e3e;color:#fff;font:700 10px sans-serif;padding:2px 6px;border-bottom-right-radius:6px;pointer-events:none';
        document.body.appendChild(b);
    });
}

// The punch terminal and the administrator are different logins on the SAME website, so their saved sessions must not share one place:
// otherwise opening the terminal link in the administrator's browser replaced the administrator's session and every list came back empty.
const DAWAM_IS_TERMINAL_PAGE = /\/punch\//.test(location.pathname);
const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY,
    DAWAM_IS_TERMINAL_PAGE ? { auth: { storageKey: 'dawam-terminal-auth' } } : undefined);

// Test connection
async function testConnection() {
    // New login: the public key may not read any table any more, so a table read is no longer a valid test.
    // A failed sign-in reports network problems itself.
    if (DAWAM_AUTH_MODE === 'supabase') return navigator.onLine !== false;
    try {
        const { data, error } = await supabaseClient.from('settings').select('key').limit(1);
        if (error) throw error;
        console.log('✅ Supabase connected successfully');
        return true;
    } catch (error) {
        console.error('❌ Supabase connection failed:', error.message);
        return false;
    }
}