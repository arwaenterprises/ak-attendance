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

// Visible reminder when running against staging
if (DAWAM_IS_STAGING) {
    document.addEventListener('DOMContentLoaded', () => {
        const b = document.createElement('div');
        b.textContent = 'STAGING';
        b.style.cssText = 'position:fixed;top:0;left:0;z-index:99999;background:#e53e3e;color:#fff;font:700 10px sans-serif;padding:2px 6px;border-bottom-right-radius:6px;pointer-events:none';
        document.body.appendChild(b);
    });
}

const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// Test connection
async function testConnection() {
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