// Dawam Attendance - Roles and salaries
// RoleAPI: the company's list of roles (name, default monthly salary, overtime rate per hour, one default role).
// SalaryAPI: the salary history of each labor ("from this date on"); the salary on a day is the latest entry up to that day.
const RoleAPI = {
    // The administrator's own calendar date (the database date can be a day away because of time zones)
    localToday() {
        const d = new Date();
        return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
    },

    async getAll() {
        try {
            const { data, error } = await supabaseClient.from('roles').select('*').eq('client_id', AUTH.getClientId()).order('name');
            if (error) throw error;
            return { success: true, data: data || [] };
        } catch (error) {
            console.error('Get roles error:', error);
            return { success: false, error: error.message };
        }
    },

    async getActive() {
        const r = await this.getAll();
        return r.success ? { success: true, data: r.data.filter(x => x.status === 'active') } : r;
    },

    async create(role) {
        try {
            const { data, error } = await supabaseClient.from('roles').insert({
                client_id: AUTH.getClientId(),
                name: role.name.trim(),
                default_monthly_salary: Number(role.defaultSalary) || 0,
                ot_rate_per_hour: Number(role.otRate) || 0,
                status: role.status || 'active'
            }).select().single();
            if (error) throw error;
            await AUTH.logAction('CREATE', 'roles', data.id, null, data);
            return { success: true, data };
        } catch (error) {
            return { success: false, error: error.code === '23505' ? 'A role with this name already exists' : error.message };
        }
    },

    // name, otRate, status (the default SALARY changes through changeSalary, which asks from which day)
    async update(id, fields) {
        try {
            const upd = {};
            if (fields.name !== undefined) upd.name = fields.name.trim();
            if (fields.otRate !== undefined) upd.ot_rate_per_hour = Number(fields.otRate) || 0;
            if (fields.status !== undefined) upd.status = fields.status;
            const { data, error } = await supabaseClient.from('roles').update(upd).eq('client_id', AUTH.getClientId()).eq('id', id).select().single();
            if (error) throw error;
            await AUTH.logAction('UPDATE', 'roles', id, null, data);
            return { success: true, data };
        } catch (error) {
            return { success: false, error: error.code === '23505' ? 'A role with this name already exists' : error.message };
        }
    },

    // Make this the role new labors get when none is chosen (the old default is switched off first: one default per company)
    async setDefault(id) {
        try {
            const cid = AUTH.getClientId();
            const off = await supabaseClient.from('roles').update({ is_default: false }).eq('client_id', cid).eq('is_default', true);
            if (off.error) throw off.error;
            const { error } = await supabaseClient.from('roles').update({ is_default: true, status: 'active' }).eq('client_id', cid).eq('id', id);
            if (error) throw error;
            return { success: true };
        } catch (error) {
            return { success: false, error: error.message };
        }
    },

    async remove(id) {
        try {
            const { error } = await supabaseClient.from('roles').delete().eq('client_id', AUTH.getClientId()).eq('id', id);
            if (error) throw error;
            await AUTH.logAction('DELETE', 'roles', id, null, null);
            return { success: true };
        } catch (error) {
            return { success: false, error: error.code === '23503' ? 'This role still has labors. Give them another role first.' : error.message };
        }
    },

    // Change the default salary of a role from a date; applyToLabors = also the active labors who are on the current default (personal salaries stay)
    async changeSalary(id, amount, fromDate, applyToLabors) {
        try {
            const { data, error } = await supabaseClient.rpc('change_role_salary', { p_role: id, p_amount: Number(amount), p_from: fromDate, p_apply: !!applyToLabors });
            if (error) throw error;
            return { success: true, data };
        } catch (error) {
            return { success: false, error: error.message };
        }
    },

    // Number of labors per role: { roleId: { active, all } }
    async getLaborCounts() {
        try {
            const counts = {};
            for (let from = 0; ; from += 1000) {
                const { data, error } = await supabaseClient.from('laborers').select('role_id, status')
                    .eq('client_id', AUTH.getClientId()).order('labor_id').range(from, from + 999);
                if (error) throw error;
                (data || []).forEach(l => { const c = counts[l.role_id] = counts[l.role_id] || { active: 0, all: 0 }; c.all++; if (l.status === 'active') c.active++; });
                if (!data || data.length < 1000) break;
            }
            return { success: true, data: counts };
        } catch (error) {
            return { success: false, error: error.message };
        }
    }
};

const SalaryAPI = {
    // The history of one labor, newest first: [{ from_date, monthly_salary }]
    async getHistory(laborId) {
        try {
            const { data, error } = await supabaseClient.from('labor_salaries').select('from_date, monthly_salary, created_at')
                .eq('client_id', AUTH.getClientId()).eq('labor_id', laborId).order('from_date', { ascending: false });
            if (error) throw error;
            return { success: true, data: data || [] };
        } catch (error) {
            return { success: false, error: error.message };
        }
    },

    // Set the salary of labors from a date (the database checks that you are the administrator of this company)
    async setSalary(laborIds, amount, fromDate) {
        try {
            const { data, error } = await supabaseClient.rpc('set_labor_salary', { p_labor_ids: laborIds, p_amount: Number(amount), p_from: fromDate });
            if (error) throw error;
            return { success: true, data };
        } catch (error) {
            return { success: false, error: error.message };
        }
    },

    // Puts labor.current_salary on every labor: the salary valid TODAY (this device's date), from the history.
    // (laborers.monthly_salary is only a copy written when a change is saved; the history is the truth.) Administrators only: others get nothing.
    async applyCurrent(labors, dateStr) {
        try {
            const today = dateStr || RoleAPI.localToday();
            const latest = {};
            for (let from = 0; ; from += 1000) {
                const { data, error } = await supabaseClient.from('labor_salaries').select('labor_id, monthly_salary, from_date')
                    .eq('client_id', AUTH.getClientId()).lte('from_date', today).order('from_date', { ascending: true }).order('id').range(from, from + 999);
                if (error) throw error;
                (data || []).forEach(s => { latest[s.labor_id] = s.monthly_salary; });
                if (!data || data.length < 1000) break;
            }
            labors.forEach(l => { l.current_salary = latest[l.labor_id] != null ? Number(latest[l.labor_id]) : (l.monthly_salary != null ? Number(l.monthly_salary) : null); });
        } catch (error) {
            console.warn('Could not read the salary history', error);
        }
        return labors;
    }
};
