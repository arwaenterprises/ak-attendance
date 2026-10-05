// Dawam Attendance - Department API
const DepartmentAPI = {
    // Get all departments
    async getAll() {
        try {
            const { data, error } = await supabaseClient
                .from('departments')
                .select('*')
                .eq('client_id', AUTH.getClientId())
                .order('name');

            if (error) throw error;
            return { success: true, data: data || [] };
        } catch (error) {
            console.error('Get departments error:', error);
            return { success: false, error: error.message };
        }
    },

    // Get active departments only
    async getActive() {
        try {
            const { data, error } = await supabaseClient
                .from('departments')
                .select('*')
                .eq('client_id', AUTH.getClientId())
                .eq('status', 'active')
                .order('name');

            if (error) throw error;
            return { success: true, data: data || [] };
        } catch (error) {
            console.error('Get active departments error:', error);
            return { success: false, error: error.message };
        }
    },

    // Get single department by ID
    async getById(id) {
        try {
            const { data, error } = await supabaseClient
                .from('departments')
                .select('*')
                .eq('client_id', AUTH.getClientId())
                .eq('id', id)
                .single();

            if (error) throw error;
            return { success: true, data };
        } catch (error) {
            console.error('Get department error:', error);
            return { success: false, error: error.message };
        }
    },

    // Create new department
    async create(department) {
        try {
            const { data, error } = await supabaseClient
                .from('departments')
                .insert({
                    name: department.name.trim(),
                    code: department.code.toUpperCase().trim(),
                    status: department.status || 'active',
                    ...(department.min_hours_full_day ? { min_hours_full_day: department.min_hours_full_day } : {}),
                    client_id: AUTH.getClientId()
                })
                .select()
                .single();

            if (error) throw error;

            // Audit log
            await AUTH.logAction('CREATE', 'departments', data.id, null, data);

            return { success: true, data };
        } catch (error) {
            console.error('Create department error:', error);
            return { success: false, error: error.message };
        }
    },

    // Update department
    async update(id, updates) {
        try {
            // Get old value for audit
            const { data: oldData } = await supabaseClient
                .from('departments')
                .select('*')
                .eq('client_id', AUTH.getClientId())
                .eq('id', id)
                .single();

            const { data, error } = await supabaseClient
                .from('departments')
                .update({
                    name: updates.name?.trim(),
                    code: updates.code?.toUpperCase().trim(),
                    // switching a department OFF is done by deactivate_department() below (its labors go with it), never by a plain status update
                    status: (updates.status === 'inactive' && oldData && oldData.status === 'active') ? 'active' : updates.status,
                    ...(updates.min_hours_full_day ? { min_hours_full_day: updates.min_hours_full_day } : {})
                })
                .eq('client_id', AUTH.getClientId())
                .eq('id', id)
                .select()
                .single();

            if (error) throw error;

            let deactivated = null;
            if (updates.status === 'inactive' && oldData && oldData.status === 'active') {
                const off = await this.deactivate(id, updates.lastWorkingDate);
                if (!off.success) throw new Error(off.error);
                deactivated = off.data;
                data.status = 'inactive';
            }

            // Audit log
            await AUTH.logAction('UPDATE', 'departments', id, oldData, data);

            return { success: true, data, deactivated };
        } catch (error) {
            console.error('Update department error:', error);
            return { success: false, error: error.message };
        }
    },

    // The administrator's own calendar date (the database date can be a day away because of time zones)
    localToday() {
        const d = new Date();
        return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
    },

    // Switch a department off together with its active labors; their last working day is `dateStr` (default: today)
    async deactivate(id, dateStr) {
        try {
            const { data, error } = await supabaseClient.rpc('deactivate_department', { p_dept: id, p_date: dateStr || this.localToday() });
            if (error) throw error;
            return { success: true, data };
        } catch (error) {
            console.error('Deactivate department error:', error);
            return { success: false, error: error.message };
        }
    },

    // Number of ACTIVE labors per department: { departmentId: count }
    async getActiveLaborCounts() {
        try {
            const counts = {};
            for (let from = 0; ; from += 1000) {
                const { data, error } = await supabaseClient.from('laborers').select('department_id')
                    .eq('client_id', AUTH.getClientId()).eq('status', 'active').order('labor_id').range(from, from + 999);
                if (error) throw error;
                (data || []).forEach(l => { counts[l.department_id] = (counts[l.department_id] || 0) + 1; });
                if (!data || data.length < 1000) break;
            }
            return { success: true, data: counts };
        } catch (error) {
            console.error('Labor counts error:', error);
            return { success: false, error: error.message };
        }
    },

    // Active labors of one department (for the "Move labors" window)
    async getActiveLabors(departmentId) {
        try {
            const { data, error } = await supabaseClient.from('laborers').select('labor_id, name')
                .eq('client_id', AUTH.getClientId()).eq('department_id', departmentId).eq('status', 'active').order('labor_id').limit(2000);
            if (error) throw error;
            return { success: true, data: data || [] };
        } catch (error) {
            console.error('Get department labors error:', error);
            return { success: false, error: error.message };
        }
    },

    // Move labors to another ACTIVE department (the database checks that you are the administrator of this company)
    async moveLabors(laborIds, departmentId) {
        try {
            const { data, error } = await supabaseClient.rpc('move_labors_to_department', { p_labor_ids: laborIds, p_dept: departmentId });
            if (error) throw error;
            await AUTH.logAction('UPDATE', 'laborers', departmentId, null, { moved: laborIds, to_department: departmentId });
            return { success: true, data };
        } catch (error) {
            console.error('Move labors error:', error);
            return { success: false, error: error.message };
        }
    },

    // Delete department (only if no laborers/users assigned)
    async delete(id) {
        try {
            // Check for assigned laborers
            const { count: laborerCount } = await supabaseClient
                .from('laborers')
                .select('*', { count: 'exact', head: true })
                .eq('client_id', AUTH.getClientId())
                .eq('department_id', id);

            if (laborerCount > 0) {
                return { success: false, error: 'Cannot delete: Department has laborers assigned' };
            }

            // Check for assigned users
            const { count: userCount } = await supabaseClient
                .from('users')
                .select('*', { count: 'exact', head: true })
                .eq('client_id', AUTH.getClientId())
                .eq('department_id', id);

            if (userCount > 0) {
                return { success: false, error: 'Cannot delete: Department has users assigned' };
            }

            // Get old value for audit
            const { data: oldData } = await supabaseClient
                .from('departments')
                .select('*')
                .eq('client_id', AUTH.getClientId())
                .eq('id', id)
                .single();

            const { error } = await supabaseClient
                .from('departments')
                .delete()
                .eq('client_id', AUTH.getClientId())
                .eq('id', id);

            if (error) throw error;

            // Audit log
            await AUTH.logAction('DELETE', 'departments', id, oldData, null);

            return { success: true };
        } catch (error) {
            console.error('Delete department error:', error);
            return { success: false, error: error.message };
        }
    }
};
