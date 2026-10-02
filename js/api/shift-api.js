// Dawam Attendance - Shift API (Shift Management: Day / Night shifts, moving labors, history)
const ShiftAPI = {
    async getAll() {
        try {
            const { data, error } = await supabaseClient.from('shifts').select('*').eq('client_id', AUTH.getClientId()).order('is_night').order('name');
            if (error) throw error;
            return { success: true, data: data || [] };
        } catch (error) {
            console.error('Get shifts error:', error);
            return { success: false, error: error.message };
        }
    },

    // name, start_time, end_time, required_hours (number or null), status
    async update(id, fields) {
        try {
            const allowed = {};
            ['name', 'start_time', 'end_time', 'required_hours', 'status'].forEach(k => { if (k in fields) allowed[k] = fields[k]; });
            const { data, error } = await supabaseClient.from('shifts').update(allowed).eq('client_id', AUTH.getClientId()).eq('id', id).select().single();
            if (error) throw error;
            return { success: true, data };
        } catch (error) {
            console.error('Update shift error:', error);
            return { success: false, error: error.message };
        }
    },

    // Active labors with their current shift and department name
    async getLabors() {
        try {
            const { data, error } = await supabaseClient.from('laborers')
                .select('labor_id, name, department_id, shift_id, status, departments:department_id (id, name)')
                .eq('client_id', AUTH.getClientId()).eq('status', 'active').order('labor_id').limit(2000);
            if (error) throw error;
            return { success: true, data: data || [] };
        } catch (error) {
            console.error('Get labors for shifts error:', error);
            return { success: false, error: error.message };
        }
    },

    // Move labors to a shift from a date (the database checks that you are the administrator of this company)
    async assign(laborIds, shiftId, fromDate) {
        try {
            const { data, error } = await supabaseClient.rpc('assign_shift', { p_labor_ids: laborIds, p_shift_id: shiftId, p_from: fromDate });
            if (error) throw error;
            return { success: true, data };
        } catch (error) {
            console.error('Assign shift error:', error);
            return { success: false, error: error.message };
        }
    },

    // The moves that were made (the starting entries from 2000-01-01 are not moves)
    async history(limit = 100) {
        try {
            const { data, error } = await supabaseClient.from('shift_assignments')
                .select('id, labor_id, shift_id, from_date, created_at')
                .eq('client_id', AUTH.getClientId()).gt('from_date', '2000-01-01')
                .order('created_at', { ascending: false }).limit(limit);
            if (error) throw error;
            return { success: true, data: data || [] };
        } catch (error) {
            console.error('Shift history error:', error);
            return { success: false, error: error.message };
        }
    }
};
