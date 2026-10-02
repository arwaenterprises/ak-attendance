// Dawam Attendance - Authentication Module
// Updated for Multi-Client Support (Arwa Enterprises SaaS)

const AUTH = {
    // Internal storage name kept as-is on purpose: renaming it would sign every user out. Not visible to users.
    SESSION_KEY: 'ak_attendance_session',

    // Default client ID (for backward compatibility)
    DEFAULT_CLIENT_ID: '00000000-0000-0000-0000-000000000001',

    // Login: company code + username + password (checked by Supabase Auth)
    async login(clientCode, username, password) {
        return this.loginSupabase(clientCode, username, password);
    },

    // New login (Supabase Auth). The database decides what this person may see (see supabase/migrations).
    async loginSupabase(clientCode, username, password) {
        const code = String(clientCode || '').toUpperCase().trim();
        const user = String(username || '').toLowerCase().trim();
        const invalid = { success: false, error: 'Invalid company code, username or password' };   // one message for every cause: no hints for guessers
        try {
            if (!/^[a-z0-9._-]+$/i.test(code) || !/^[a-z0-9._-]+$/.test(user) || !password) return invalid;
            const email = `${user}@${code.toLowerCase()}.${DAWAM_LOGIN_EMAIL_DOMAIN}`;
            const { data: auth, error: authError } = await supabaseClient.auth.signInWithPassword({ email, password });
            if (authError || !auth || !auth.user) {
                if (authError && (authError.status === 429 || /rate limit/i.test(authError.message || ''))) {
                    return { success: false, error: 'Too many attempts. Please wait a few minutes and try again.' };
                }
                if (authError && /fetch|network/i.test(authError.message || '')) {
                    return { success: false, error: 'Cannot connect to server. Check internet connection.' };
                }
                return invalid;
            }

            // Profile and company: the database only shows this person their own rows
            const { data: userData } = await supabaseClient.from('users')
                .select('id, username, name, role, department_id, status, client_id, permissions')
                .eq('auth_id', auth.user.id).maybeSingle();
            if (!userData) {
                await supabaseClient.auth.signOut({ scope: 'local' });
                return { success: false, error: 'This login is not linked to a company yet. Contact support.' };
            }
            const { data: clientData } = await supabaseClient.from('clients')
                .select('id, business_name, business_name_ar, logo_url, subscription_status, subscription_tier, subscription_end_date, is_active')
                .eq('id', userData.client_id).maybeSingle();
            const expiredMessage = 'Your subscription has expired or the account is inactive. Contact Arwa Enterprises: +91 7021229209';
            if (!clientData) {                       // the database hides the company of an expired / inactive account
                await supabaseClient.auth.signOut({ scope: 'local' });
                return { success: false, error: expiredMessage };
            }
            if (!clientData.is_active) {
                await supabaseClient.auth.signOut({ scope: 'local' });
                return { success: false, error: 'This account has been deactivated. Contact support.' };
            }
            const subscriptionCheck = this.checkSubscriptionStatus(clientData);
            if (!subscriptionCheck.valid) {
                await supabaseClient.auth.signOut({ scope: 'local' });
                return { success: false, error: subscriptionCheck.message };
            }

            const session = {
                userId: userData.id,
                username: userData.username,
                name: userData.name,
                role: userData.role,
                departmentId: userData.department_id,
                permissions: userData.permissions || {},
                clientId: clientData.id,
                clientCode: code,
                clientName: clientData.business_name,
                clientNameAr: clientData.business_name_ar,
                clientLogo: clientData.logo_url,
                clientTier: clientData.subscription_tier,
                clientStatus: clientData.subscription_status,
                loginTime: new Date().toISOString()
            };
            // This copy only drives the screens (names, menus). It is never trusted for access: the database checks every request.
            localStorage.setItem(this.SESSION_KEY, JSON.stringify(session));
            localStorage.setItem('client_id', clientData.id);
            localStorage.setItem('client_code', code);
            localStorage.setItem('client_name', clientData.business_name);
            if (clientData.logo_url) localStorage.setItem('client_logo', clientData.logo_url);

            await this.logAction('LOGIN', 'users', userData.id, null, { username: userData.username, client_id: clientData.id, client_code: code });
            return { success: true, user: session };
        } catch (error) {
            console.error('Login error:', error);
            return { success: false, error: 'Login failed. Check internet connection.' };
        }
    },

    // Check subscription status
    checkSubscriptionStatus(clientData) {
        const now = new Date();
        
        // Premium clients have no expiry check
        if (clientData.subscription_status === 'premium') {
            return { valid: true };
        }
        
        // Check if expired
        if (clientData.subscription_status === 'expired') {
            return { 
                valid: false, 
                message: 'Your subscription has expired. Contact Arwa Enterprises: +91 7021229209' 
            };
        }
        
        // Check end date
        if (clientData.subscription_end_date) {
            const endDate = new Date(clientData.subscription_end_date);
            if (now > endDate) {
                return { 
                    valid: false, 
                    message: 'Your subscription has expired. Contact Arwa Enterprises: +91 7021229209' 
                };
            }
        }
        
        return { valid: true };
    },

    // Logout
    async logout() {
        const session = this.getSession();
        if (session) {
            await this.logAction('LOGOUT', 'users', session.userId, null, { 
                username: session.username,
                client_id: session.clientId 
            });
        }
        
        // New login: end this device's session only (other devices using the same login stay signed in)
        this._loggingOut = true;
        try { await supabaseClient.auth.signOut({ scope: 'local' }); } catch (e) { /* clear the screen copy anyway */ }

        // Clear all session data
        localStorage.removeItem(this.SESSION_KEY);
        localStorage.removeItem('client_id');
        localStorage.removeItem('client_code');
        localStorage.removeItem('client_name');
        localStorage.removeItem('client_logo');
        
        window.location.href = this.getBasePath() + 'index.html';
    },

    // Get current session
    getSession() {
        const session = localStorage.getItem(this.SESSION_KEY);
        return session ? JSON.parse(session) : null;
    },

    // Refresh permissions from DB and update session (call on page load for supervisors)
    async refreshPermissions() {
        const session = this.getSession();
        if (!session || session.role === 'admin') return;
        try {
            const { data } = await supabaseClient
                .from('users')
                .select('permissions')
                .eq('id', session.userId)
                .single();
            if (data) {
                session.permissions = data.permissions || {};
                localStorage.setItem(this.SESSION_KEY, JSON.stringify(session));
            }
        } catch (e) {
            // silently fail — session permissions remain as-is
        }
    },

    // Check if logged in
    isLoggedIn() {
        return this.getSession() !== null;
    },

    // Get current client ID
    getClientId() {
        const session = this.getSession();
        return session?.clientId || localStorage.getItem('client_id') || this.DEFAULT_CLIENT_ID;
    },

    // Get current client info
    getClientInfo() {
        const session = this.getSession();
        return {
            id: session?.clientId || localStorage.getItem('client_id') || this.DEFAULT_CLIENT_ID,
            name: session?.clientName || localStorage.getItem('client_name') || 'Company',
            nameAr: session?.clientNameAr || null,
            logo: session?.clientLogo || localStorage.getItem('client_logo') || null,
            plan: session?.clientTier || 'basic'
        };
    },

    // Get base path (handles subfolder URLs)
    getBasePath() {
        const path = window.location.pathname;
        if (path.includes('/admin/') || path.includes('/labor/') || 
            path.includes('/attendance/') || path.includes('/reports/') || 
            path.includes('/punch/')) {
            return '../';
        }
        return '';
    },

    // Require login (redirect if not logged in)
    requireLogin() {
        if (!this.isLoggedIn()) {
            window.location.href = this.getBasePath() + 'index.html';
            return false;
        }
        return true;
    },

    // Check if user has a specific module permission
    hasPermission(key) {
        const session = this.getSession();
        if (!session) return false;
        if (session.role === 'admin') return true;
        return session.permissions?.[key] === true;
    },

    // Check if user has specific role
    hasRole(allowedRoles) {
        const session = this.getSession();
        if (!session) return false;
        
        if (typeof allowedRoles === 'string') {
            allowedRoles = [allowedRoles];
        }
        
        return allowedRoles.includes(session.role);
    },

    // Check if user can access department
    canAccessDepartment(departmentId) {
        const session = this.getSession();
        if (!session) return false;
        
        // Super admin can access all
        if (session.role === 'admin') return true;
        
        // Others can only access their department
        return session.departmentId === departmentId;
    },

    // Require specific role (redirect if not allowed)
    requireRole(allowedRoles) {
        if (!this.requireLogin()) return false;
        
        if (!this.hasRole(allowedRoles)) {
            alert('Access denied. You do not have permission to view this page.');
            window.location.href = this.getBasePath() + 'dashboard.html';
            return false;
        }
        return true;
    },

    // Get department filter for queries
    getDepartmentFilter() {
        const session = this.getSession();
        if (!session) return null;
        
        // Super admin sees all
        if (session.role === 'admin') return null;
        
        // Others see only their department
        return session.departmentId;
    },

    // Log action to audit log (now includes client_id)
    async logAction(action, tableName, recordId, oldValue, newValue) {
        try {
            const session = this.getSession();
            const clientId = this.getClientId();
            
            await supabaseClient.from('audit_log').insert({
                user_id: session?.userId || null,
                user_name: session?.name || 'System',
                action: action,
                table_name: tableName,
                record_id: recordId?.toString() || null,
                old_value: oldValue,
                new_value: newValue,
                client_id: clientId
            });
        } catch (error) {
            console.error('Audit log error:', error);
        }
    },

    // Display client branding on page
    displayClientBranding() {
        const clientInfo = this.getClientInfo();
        
        // Update company name if element exists
        const nameElement = document.getElementById('company-name');
        if (nameElement) {
            nameElement.textContent = clientInfo.name;
        }
        
        // Update company logo if element exists
        const logoElement = document.getElementById('company-logo');
        if (logoElement && clientInfo.logo) {
            logoElement.src = clientInfo.logo;
            logoElement.style.display = 'block';
        }
        
        // Update page title
        document.title = document.title.replace('Attendance', clientInfo.name + ' - Attendance');
    }
};

// New login: the screen copy of the session is only valid while the Auth session behind it is valid
// (expired for good, signed out elsewhere, refresh refused). Otherwise go back to the login page.
AUTH.endSessionAndGoToLogin = function () {
    localStorage.removeItem(AUTH.SESSION_KEY);
    localStorage.removeItem('client_id');
    localStorage.removeItem('client_code');
    localStorage.removeItem('client_name');
    localStorage.removeItem('client_logo');
    window.location.href = AUTH.getBasePath() + 'index.html';
};
{
    document.addEventListener('DOMContentLoaded', async function () {
        if (!AUTH.isLoggedIn()) return;
        try {
            const { data } = await supabaseClient.auth.getSession();
            if (!data || !data.session) AUTH.endSessionAndGoToLogin();
            // a saved TERMINAL login (left by an older version that shared the saved session) is not an administrator: sign in again
            else if (/^terminal@/i.test(data.session.user.email || '')) {
                await supabaseClient.auth.signOut({ scope: 'local' });
                AUTH.endSessionAndGoToLogin();
            }
        } catch (e) { /* offline: keep working; the next online request refreshes or ends the session */ }
    });
    supabaseClient.auth.onAuthStateChange(function (event) {
        if (event === 'SIGNED_OUT' && !AUTH._loggingOut && AUTH.isLoggedIn()) AUTH.endSessionAndGoToLogin();
    });
}

// Auto-display client branding when DOM is ready
document.addEventListener('DOMContentLoaded', function() {
    if (AUTH.isLoggedIn()) {
        AUTH.displayClientBranding();
    }
});
