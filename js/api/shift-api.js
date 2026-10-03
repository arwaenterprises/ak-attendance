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
            const labors = data || [];
            await ShiftAPI.applyCurrentShift(labors);
            return { success: true, data: labors };
        } catch (error) {
            console.error('Get labors for shifts error:', error);
            return { success: false, error: error.message };
        }
    },

    // Sets labor.shift_id on each labor to the shift valid TODAY (this device's date), from the move history.
    // laborers.shift_id is only a snapshot written when a move is saved; it is wrong when the database date differs
    // from the admin's date (UTC vs local) and never changes by itself when a move dated in the future arrives.
    // Same rule as the reports: the latest move up to the date wins. If the history cannot be read, the snapshot stays.
    async applyCurrentShift(labors, dateStr) {
        try {
            const d = new Date();
            const today = dateStr || (d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0'));
            const latest = {};
            for (let from = 0; ; from += 1000) {
                const { data, error } = await supabaseClient.from('shift_assignments')
                    .select('labor_id, shift_id, from_date')
                    .eq('client_id', AUTH.getClientId()).lte('from_date', today)
                    .order('from_date', { ascending: true }).order('id').range(from, from + 999);
                if (error) throw error;
                (data || []).forEach(a => { latest[a.labor_id] = a.shift_id; });   // ascending: the last one wins
                if (!data || data.length < 1000) break;
            }
            labors.forEach(l => { if (latest[l.labor_id]) l.shift_id = latest[l.labor_id]; });
        } catch (error) {
            console.warn('Could not read the shift history, showing the saved shift', error);
        }
        return labors;
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
