// Dawam Attendance - Report API (day rules: database P / A + AttendanceRules for Friday, holidays and the sandwich rule)
const ReportAPI = {
    // Get daily attendance summary (original - only punched laborers)
    async getDailyAttendance(fromDate, toDate, departmentId = null) {
        try {
            const departmentFilter = departmentId || AUTH.getDepartmentFilter();
            
            let query = supabaseClient
                .from('daily_attendance')
                .select(`
                    *,
                    laborers:labor_id (
                        labor_id,
                        name,
                        iqama_number,
                        nationality,
                        date_of_joining,
                        department_id
                    )
                `)
                .eq('client_id', AUTH.getClientId())
                .gte('date', fromDate)
                .lte('date', toDate)
                .order('date', { ascending: false })
                .limit(5000);

            if (departmentFilter) {
                query = query.eq('department_id', departmentFilter);
            }

            const { data, error } = await query;
            if (error) throw error;
            if (data?.length === 5000) console.warn('Daily attendance hit 5000 record limit');
            return { success: true, data: data || [], limited: data?.length === 5000 };
        } catch (error) {
            console.error('Get daily attendance error:', error);
            return { success: false, error: error.message };
        }
    },

    // Read every row of a query page by page (the server returns at most 1000 rows per request)
    async _fetchAll(build) {
        const rows = [];
        for (let from = 0; ; from += 1000) {
            const { data, error } = await build().range(from, from + 999);
            if (error) throw error;
            rows.push(...(data || []));
            if (!data || data.length < 1000) break;
        }
        return rows;
    },

    // The two sandwich-rule switches of this company (Settings page)
    async _sandwichSwitches(clientId) {
        const { data } = await supabaseClient.from('settings').select('key, value').eq('client_id', clientId)
            .in('key', ['sandwich_rule_friday', 'sandwich_rule_nh']);
        const map = {};
        (data || []).forEach(s => { map[s.key] = s.value; });
        return AttendanceRules.sandwichSwitches(map);
    },

    // Get COMPLETE attendance - ALL active laborers (punched + non-punched)
    // Status and hours come from daily_attendance (the database applies the one rule: full required hours = P, else A);
    // Friday / holidays and the sandwich rule come from AttendanceRules (same as the 3PL and the terminal's month screen).
    async getCompleteAttendance(fromDate, toDate, departmentId = null) {
        try {
            const departmentFilter = departmentId || AUTH.getDepartmentFilter();
            const clientId = AUTH.getClientId();

            let laborQuery = supabaseClient
                .from('laborers')
                .select('labor_id, name, iqama_number, department_id, date_of_joining, status, last_working_date, role, shift_id')
                .eq('client_id', clientId)
                // active labors, and labors switched off on or after the first day of the report (they still count up to their last working day)
                .or(`status.eq.active,and(status.eq.inactive,last_working_date.gte.${fromDate})`)
                .limit(2000);

            if (departmentFilter) {
                laborQuery = laborQuery.eq('department_id', departmentFilter);
            }

            const { data: laborers, error: laborError } = await laborQuery;
            if (laborError) throw laborError;
            if (laborers?.length === 2000) console.warn('Complete attendance laborers hit 2000 record limit');

            // 14 days around the report: the working days before / after a Friday or a holiday run (sandwich rule)
            const bufferFromStr = AttendanceRules.addDays(fromDate, -14);
            const bufferToStr = AttendanceRules.addDays(toDate, 14);

            // (no department filter on the attendance rows: a labor moved to another department keeps the days recorded under the old one;
            //  the labor list above already holds only this department's labors)
            const attendancePromise = this._fetchAll(() => supabaseClient
                .from('daily_attendance')
                .select('*')
                .eq('client_id', clientId)
                .gte('date', bufferFromStr)
                .lte('date', bufferToStr)
                .order('date').order('labor_id'));

            // punches: only for the location and the early-leave mark
            const punchesPromise = this._fetchAll(() => supabaseClient
                .from('punch_records')
                .select('labor_id, date, time, location_name, early_out, early_minutes')
                .eq('client_id', clientId)
                .gte('date', fromDate)
                .lte('date', toDate)
                .order('date').order('time').order('id'));

            const deptQuery = supabaseClient
                .from('departments')
                .select('id, name')
                .eq('client_id', clientId);

            const holidayQuery = supabaseClient
                .from('holidays')
                .select('date, name')
                .eq('client_id', clientId)
                .eq('is_active', true)
                .gte('date', bufferFromStr)
                .lte('date', bufferToStr);

            // Shifts and the history of moves (a report must still work if they cannot be read)
            const shiftQuery = supabaseClient.from('shifts').select('id, name, is_night').eq('client_id', clientId);
            const assignQuery = supabaseClient.from('shift_assignments').select('labor_id, shift_id, from_date').eq('client_id', clientId).limit(5000);

            const [
                attendance,
                allPunches,
                { data: departments },
                { data: holidaysData },
                shiftRes,
                assignRes,
                switches
            ] = await Promise.all([attendancePromise, punchesPromise, deptQuery, holidayQuery, shiftQuery, assignQuery, this._sandwichSwitches(clientId)]);

            // shift of a labor on a date: the latest move up to that date, else his current shift, else the Day shift (same rule as the database)
            const shiftMap = {};
            (shiftRes && shiftRes.data || []).forEach(sh => { shiftMap[sh.id] = sh; });
            const dayShift = Object.values(shiftMap).find(sh => !sh.is_night) || null;
            const movesByLabor = {};
            (assignRes && assignRes.data || []).forEach(a => { (movesByLabor[a.labor_id] = movesByLabor[a.labor_id] || []).push(a); });
            Object.values(movesByLabor).forEach(list => list.sort((x, y) => (x.from_date < y.from_date ? -1 : 1)));
            const shiftOf = (labor, dateStr) => {
                let id = null;
                for (const m of (movesByLabor[labor.labor_id] || [])) { if (m.from_date <= dateStr) id = m.shift_id; else break; }
                id = id || labor.shift_id || (dayShift && dayShift.id) || null;
                return shiftMap[id] || null;
            };

            const earlyMap = {};
            const punchLocationMap = {};
            allPunches.forEach(p => {
                const key = `${p.labor_id}_${p.date}`;
                if (p.early_out) earlyMap[key] = Math.max(earlyMap[key] || 0, p.early_minutes || 0);
                if (!punchLocationMap[key]) punchLocationMap[key] = p.location_name || '';
            });

            const deptMap = {};
            (departments || []).forEach(d => { deptMap[d.id] = d.name; });

            const holidayMap = {};
            (holidaysData || []).forEach(h => { holidayMap[h.date] = h.name; });

            const attendanceMap = {};
            attendance.forEach(a => { attendanceMap[`${a.labor_id}_${a.date}`] = a; });

            const today = AttendanceRules.today();
            const statusFor = labor => dateStr => {
                if (dateStr >= today) return null;                                         // not finished yet
                if (labor.date_of_joining && dateStr < labor.date_of_joining) return null;
                if (labor.status === 'inactive' && labor.last_working_date && dateStr > labor.last_working_date) return null;
                return AttendanceRules.workingStatus(attendanceMap[`${labor.labor_id}_${dateStr}`]);
            };

            const result = [];
            for (let dateStr = fromDate; dateStr <= toDate; dateStr = AttendanceRules.addDays(dateStr, 1)) {
                const isFriday = AttendanceRules.isFriday(dateStr);
                const offDay = AttendanceRules.offDay(dateStr, holidayMap);

                for (const labor of laborers) {
                    const key = `${labor.labor_id}_${dateStr}`;
                    const record = attendanceMap[key] || null;

                    if (labor.date_of_joining && dateStr < labor.date_of_joining) continue;
                    // a labor switched off (for example with its department): no rows after the last working day
                    if (labor.status === 'inactive' && labor.last_working_date && dateStr > labor.last_working_date) continue;

                    const approved = !!(record && record.approved_by && String(record.approved_by).trim());
                    let autoStatus, finalStatus;
                    if (offDay) {
                        // Friday / holiday: paid whether punched or not; Absent only by the sandwich rule (the administrator can still approve it)
                        autoStatus = offDay;
                        const sandwiched = AttendanceRules.sandwiched(dateStr, holidayMap, switches, statusFor(labor));
                        finalStatus = sandwiched ? (approved ? AttendanceRules.workingStatus(record) : 'A') : offDay;
                    } else {
                        autoStatus = record && record.auto_status === 'P' ? 'P' : 'A';
                        finalStatus = AttendanceRules.workingStatus(record);
                    }

                    const shift = shiftOf(labor, dateStr) || {};
                    result.push({
                        id: null, approved_by: null, approved_at: null, lop_reason: null, client_id: clientId,
                        ...(record || {}),
                        labor_id: labor.labor_id,
                        department_id: labor.department_id,
                        date: dateStr,
                        first_login: record ? record.first_login : null,
                        last_logout: record ? record.last_logout : null,
                        total_hours: record && Number(record.total_hours) > 0 ? Number(record.total_hours) : null,
                        auto_status: autoStatus,
                        final_status: finalStatus,
                        laborName: labor.name,
                        role: labor.role || 'Labor',
                        iqamaNumber: labor.iqama_number,
                        departmentName: deptMap[labor.department_id] || '-',
                        punchLocation: punchLocationMap[key] || '',
                        shiftName: shift.name || '',
                        isNightShift: !!shift.is_night,
                        earlyOut: key in earlyMap,
                        earlyMinutes: earlyMap[key] || 0,
                        hasRecord: !!record,
                        isFriday,
                        isOffDay: !!offDay
                    });
                }
            }

            result.sort((a, b) => {
                if (a.date !== b.date) return a.date < b.date ? 1 : -1;
                const aNum = parseInt(a.labor_id.replace(/\D/g, '')) || 0;
                const bNum = parseInt(b.labor_id.replace(/\D/g, '')) || 0;
                return aNum - bNum;
            });

            return { success: true, data: result };
        } catch (error) {
            console.error('Get complete attendance error:', error);
            return { success: false, error: error.message };
        }
    },

    // Create absent record and approve LOP (for laborers who didn't punch)
    async createAbsentAndApprove(laborId, date, departmentId, reason, finalStatus = 'P') {
        try {
            const session = AUTH.getSession();
            const clientId = AUTH.getClientId();

            const { data: existing } = await supabaseClient
                .from('daily_attendance')
                .select('id')
                .eq('client_id', clientId)
                .eq('labor_id', laborId)
                .eq('date', date)
                .single();

            if (existing) {
                const { error } = await supabaseClient
                    .from('daily_attendance')
                    .update({
                        final_status: finalStatus,
                        approved_by: session.name,
                        approved_at: new Date().toISOString(),
                        lop_reason: reason
                    })
                    .eq('id', existing.id);

                if (error) throw error;
                return { success: true, recordId: existing.id };
            }

            const { data: newRecord, error: insertError } = await supabaseClient
                .from('daily_attendance')
                .insert({
                    labor_id: laborId,
                    department_id: departmentId,
                    date: date,
                    first_login: null,
                    last_logout: null,
                    total_hours: 0,
                    auto_status: 'A',
                    final_status: finalStatus,
                    approved_by: session.name,
                    approved_at: new Date().toISOString(),
                    lop_reason: reason,
                    client_id: clientId
                })
                .select()
                .single();

            if (insertError) throw insertError;
            return { success: true, recordId: newRecord.id };
        } catch (error) {
            console.error('Create absent and approve error:', error);
            return { success: false, error: error.message };
        }
    },

    // Get absent streak for a labor (consecutive absent days)
    async getAbsentStreak(laborId) {
        try {
            const clientId = AUTH.getClientId();
            const today = new Date();
            const todayStr = today.toISOString().split('T')[0];
            
            const thirtyDaysAgo = new Date(today);
            thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);
            const thirtyDaysAgoStr = thirtyDaysAgo.toISOString().split('T')[0];

            const { data: attendance, error } = await supabaseClient
                .from('daily_attendance')
                .select('date, final_status')
                .eq('client_id', clientId)
                .eq('labor_id', laborId)
                .gte('date', thirtyDaysAgoStr)
                .lte('date', todayStr)
                .order('date', { ascending: false });

            if (error) throw error;

            const attendanceMap = {};
            (attendance || []).forEach(a => {
                attendanceMap[a.date] = a.final_status;
            });

            let streak = 0;
            for (let d = new Date(today); d >= thirtyDaysAgo; d.setDate(d.getDate() - 1)) {
                const dateStr = d.toISOString().split('T')[0];
                const dayOfWeek = d.getDay();
                if (dayOfWeek === 5) continue;

                const status = attendanceMap[dateStr];
                if (!status || status === 'A') {
                    streak++;
                } else {
                    break;
                }
            }

            return { success: true, streak };
        } catch (error) {
            console.error('Get absent streak error:', error);
            return { success: false, streak: 0, error: error.message };
        }
    },

    // Get absent streaks for all active laborers (for Labor Master badge)
    async getAllAbsentStreaks(departmentId = null) {
        try {
            const clientId = AUTH.getClientId();
            const departmentFilter = departmentId || AUTH.getDepartmentFilter();
            const today = new Date();
            const todayStr = today.toISOString().split('T')[0];
            
            const thirtyDaysAgo = new Date(today);
            thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);
            const thirtyDaysAgoStr = thirtyDaysAgo.toISOString().split('T')[0];

            let laborQuery = supabaseClient
                .from('laborers')
                .select('labor_id, date_of_joining')
                .eq('client_id', clientId)
                .eq('status', 'active');

            if (departmentFilter) {
                laborQuery = laborQuery.eq('department_id', departmentFilter);
            }

            const { data: laborers, error: laborError } = await laborQuery;
            if (laborError) throw laborError;

            let attendanceQuery = supabaseClient
                .from('daily_attendance')
                .select('labor_id, date, final_status')
                .eq('client_id', clientId)
                .gte('date', thirtyDaysAgoStr)
                .lte('date', todayStr);

            if (departmentFilter) {
                attendanceQuery = attendanceQuery.eq('department_id', departmentFilter);
            }

            const { data: attendance, error: attError } = await attendanceQuery;
            if (attError) throw attError;

            const attendanceByLabor = {};
            (attendance || []).forEach(a => {
                if (!attendanceByLabor[a.labor_id]) {
                    attendanceByLabor[a.labor_id] = {};
                }
                attendanceByLabor[a.labor_id][a.date] = a.final_status;
            });

            const streaks = {};
            for (const labor of laborers) {
                const laborAttendance = attendanceByLabor[labor.labor_id] || {};
                let streak = 0;
                const doj = labor.date_of_joining ? new Date(labor.date_of_joining) : null;

                for (let d = new Date(today); d >= thirtyDaysAgo; d.setDate(d.getDate() - 1)) {
                    const dateStr = d.toISOString().split('T')[0];
                    const dayOfWeek = d.getDay();
                    if (dayOfWeek === 5) continue;
                    if (doj && d < doj) break;

                    const status = laborAttendance[dateStr];
                    if (!status || status === 'A') {
                        streak++;
                    } else {
                        break;
                    }
                }

                if (streak >= 3) {
                    streaks[labor.labor_id] = streak;
                }
            }

            return { success: true, data: streaks };
        } catch (error) {
            console.error('Get all absent streaks error:', error);
            return { success: false, data: {}, error: error.message };
        }
    },

    // Get attendance for a specific laborer
    async getLaborerAttendance(laborId, fromDate, toDate) {
        try {
            const { data, error } = await supabaseClient
                .from('daily_attendance')
                .select('*')
                .eq('client_id', AUTH.getClientId())
                .eq('labor_id', laborId)
                .gte('date', fromDate)
                .lte('date', toDate)
                .order('date');

            if (error) throw error;
            return { success: true, data: data || [] };
        } catch (error) {
            console.error('Get laborer attendance error:', error);
            return { success: false, error: error.message };
        }
    },

    // Get punch photos for a specific date and laborer
    async getPunchPhotos(laborId, date) {
        try {
            const { data, error } = await supabaseClient
                .from('punch_records')
                .select('id, time, type, photo_url, confidence, location_name')
                .eq('client_id', AUTH.getClientId())
                .eq('labor_id', laborId)
                .eq('date', date)
                .order('time');

            if (error) throw error;
            return { success: true, data: data || [] };
        } catch (error) {
            console.error('Get punch photos error:', error);
            return { success: false, error: error.message };
        }
    },

    // Format time for display (HH:MM AM/PM)
    formatTime12h(timeStr) {
        if (!timeStr) return '';
        try {
            const [hours, minutes] = timeStr.split(':');
            const h = parseInt(hours);
            const ampm = h >= 12 ? 'PM' : 'AM';
            const h12 = h % 12 || 12;
            return `${h12}:${minutes} ${ampm}`;
        } catch {
            return '';
        }
    },

    // Parse time string to minutes
    parseTimeToMinutes(timeStr) {
        if (!timeStr) return 0;
        try {
            const [hours, minutes] = timeStr.split(':').map(Number);
            return hours * 60 + minutes;
        } catch {
            return 0;
        }
    },

    // Format minutes to HH:MM
    formatMinutesToHHMM(minutes) {
        if (!minutes || minutes <= 0) return '';
        const h = Math.floor(minutes / 60);
        const m = Math.round(minutes % 60);
        return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`;
    },

    // Calculate hours between two time strings (handles cross-midnight night shifts)
    calculateHours(firstIn, lastOut) {
        if (!firstIn || !lastOut) return 0;
        try {
            const inMinutes  = this.parseTimeToMinutes(firstIn);
            const outMinutes = this.parseTimeToMinutes(lastOut);
            if (outMinutes > inMinutes) return outMinutes - inMinutes;
            // Cross-midnight: logout time is less than login (night shift spanning midnight)
            // Guard: only treat as cross-midnight if the apparent "backwards" gap exceeds 6h
            if (inMinutes - outMinutes > 6 * 60) {
                return (24 * 60 - inMinutes) + outMinutes;
            }
            return 0;
        } catch {
            return 0;
        }
    },

    // Get monthly summary for 3PL billing
    // Same day rules as the daily report: working day P / A from daily_attendance (the database's one rule), Friday and holidays
    // always paid unless the sandwich rule applies (AttendanceRules). Paid days = P + F + NH.
    async getMonthlyBilling(year, month, departmentId = null, statusFilter = 'active') {
        try {
            const departmentFilter = departmentId || AUTH.getDepartmentFilter();
            const clientId = AUTH.getClientId();

            const lastDay = new Date(year, month, 0).getDate();
            const startDate = `${year}-${String(month).padStart(2, '0')}-01`;
            const endDate = `${year}-${String(month).padStart(2, '0')}-${String(lastDay).padStart(2, '0')}`;

            let laborQuery = supabaseClient
                .from('laborers')
                .select('labor_id, iqama_number, name, date_of_joining, department_id, status, last_working_date, role, monthly_salary')
                .eq('client_id', clientId);

            if (departmentFilter) {
                laborQuery = laborQuery.eq('department_id', departmentFilter);
            }

            if (statusFilter === 'active') {
                laborQuery = laborQuery.or(`status.eq.active,and(status.eq.inactive,last_working_date.gte.${startDate})`);
            } else if (statusFilter === 'inactive') {
                laborQuery = laborQuery.eq('status', 'inactive').lt('last_working_date', startDate);
            }

            const { data: laborers, error: laborError } = await laborQuery;
            if (laborError) throw laborError;

            laborers.sort((a, b) => {
                const aNum = parseInt(a.labor_id.replace(/\D/g, '')) || 0;
                const bNum = parseInt(b.labor_id.replace(/\D/g, '')) || 0;
                return aNum - bNum;
            });

            // 14 days around the month: the working days before / after a Friday or holiday run (sandwich rule)
            const fetchFrom = AttendanceRules.addDays(startDate, -14);
            const fetchTo = AttendanceRules.addDays(endDate, 14);

            // (no department filter here: labors moved between departments keep their earlier days; the labor list above is already filtered)
            const attendance = await this._fetchAll(() => supabaseClient
                .from('daily_attendance')
                .select('labor_id, date, final_status, first_login, last_logout, total_hours, approved_by')
                .eq('client_id', clientId)
                .gte('date', fetchFrom)
                .lte('date', fetchTo)
                .order('date').order('labor_id'));

            const { data: holidaysData } = await supabaseClient
                .from('holidays')
                .select('date, name')
                .eq('client_id', clientId)
                .eq('is_active', true)
                .gte('date', fetchFrom)
                .lte('date', fetchTo);

            const holidayMap = {};
            (holidaysData || []).forEach(h => { holidayMap[h.date] = h.name; });

            const attendanceMap = {};
            attendance.forEach(a => { attendanceMap[`${a.labor_id}_${a.date}`] = a; });

            const switches = await this._sandwichSwitches(clientId);
            const today = AttendanceRules.today();

            // Salary history ("from this date on"), so each day is paid with the salary valid on that day.
            // Only administrators can read it; for anybody else the labor's current salary is used for the whole month.
            const salaryHistory = {};
            try {
                for (let from = 0; ; from += 1000) {
                    const { data: sal, error: salError } = await supabaseClient
                        .from('labor_salaries')
                        .select('labor_id, from_date, monthly_salary')
                        .eq('client_id', clientId)
                        .lte('from_date', endDate)
                        .order('from_date', { ascending: true }).order('id')
                        .range(from, from + 999);
                    if (salError) throw salError;
                    (sal || []).forEach(e => { (salaryHistory[e.labor_id] = salaryHistory[e.labor_id] || []).push({ from: e.from_date, amount: Number(e.monthly_salary) }); });
                    if (!sal || sal.length < 1000) break;
                }
            } catch (e) { console.warn('Salary history not available, using the current salary', e); }
            const salaryOn = (laborer, dateStr) => {
                const list = salaryHistory[laborer.labor_id];
                if (list) { let v = null; for (const e of list) { if (e.from <= dateStr) v = e.amount; else break; } if (v !== null) return v; }
                return Number(laborer.monthly_salary) || 0;
            };

            const reportData = laborers.map(laborer => {
                const doj = laborer.date_of_joining || null;
                const lwd = laborer.last_working_date || null;
                const statusOf = dateStr => {
                    if (dateStr >= today) return null;                                         // not finished yet
                    if ((doj && dateStr < doj) || (lwd && dateStr > lwd)) return null;
                    return AttendanceRules.workingStatus(attendanceMap[`${laborer.labor_id}_${dateStr}`]);
                };
                let salaryAccum = 0;                 // sum over the days of (paid day x salary of that day)
                const salaryValues = new Set();

                const days = {};
                let presentCount = 0;
                let absentCount = 0;
                let fridayCount = 0;
                let holidayCount = 0;
                let totalMinutes = 0;

                for (let day = 1; day <= lastDay; day++) {
                    const dateStr = `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
                    const record = attendanceMap[`${laborer.labor_id}_${dateStr}`] || null;
                    const offDay = AttendanceRules.offDay(dateStr, holidayMap);
                    let firstIn = record ? record.first_login : null;
                    let lastOut = record ? record.last_logout : null;
                    let status;
                    let hours = '';

                    if ((doj && dateStr < doj) || (lwd && dateStr > lwd)) {
                        status = 'A';
                        firstIn = null;
                        lastOut = null;
                    } else if (offDay) {
                        // Friday / holiday: paid whether punched or not, unless the sandwich rule applies (an approval still pays it)
                        status = offDay;
                        if (AttendanceRules.sandwiched(dateStr, holidayMap, switches, statusOf)) {
                            const approved = !!(record && record.approved_by && String(record.approved_by).trim());
                            status = approved ? AttendanceRules.workingStatus(record) : 'A';
                        }
                        firstIn = null;
                        lastOut = null;
                    } else {
                        status = AttendanceRules.workingStatus(record);
                        if (status === 'P' && record && Number(record.total_hours) > 0) {
                            const mins = Math.round(Number(record.total_hours) * 60);
                            hours = this.formatMinutesToHHMM(mins);
                            totalMinutes += mins;
                        }
                    }

                    if (status === 'P') presentCount++;
                    else if (status === 'F') fridayCount++;
                    else if (status === 'NH') holidayCount++;
                    else absentCount++;

                    const paid = status === 'P' || status === 'F' || status === 'NH';
                    const salaryToday = salaryOn(laborer, dateStr);
                    salaryValues.add(salaryToday);
                    if (paid) salaryAccum += salaryToday;

                    days[day] = {
                        status: status,
                        in: this.formatTime12h(firstIn),
                        out: this.formatTime12h(lastOut),
                        hours: hours
                    };
                }

                // P + F + NH
                const totalPaidDays = presentCount + fridayCount + holidayCount;

                // Salary based on the actual days in the month (28/29/30/31); each day uses the salary valid on that day
                const calculatedSalary = Math.round(salaryAccum / lastDay);
                const monthlySalary = salaryOn(laborer, endDate);     // shown: the salary at the end of the month

                return {
                    laborId: laborer.labor_id,
                    iqamaNumber: laborer.iqama_number,
                    name: laborer.name,
                    dateOfJoining: laborer.date_of_joining,
                    lastWorkingDate: laborer.last_working_date,
                    role: laborer.role || 'Labor',
                    monthlySalary: monthlySalary,
                    salaryChanged: salaryValues.size > 1,
                    days,
                    presentCount,
                    absentCount,
                    fridayCount,
                    holidayCount,
                    totalPaidDays,
                    totalHours: this.formatMinutesToHHMM(totalMinutes),
                    totalMinutes,
                    calculatedSalary
                };
            });

            return {
                success: true,
                data: reportData,
                meta: { year, month, totalDays: lastDay, startDate, endDate }
            };
        } catch (error) {
            console.error('Get monthly billing error:', error);
            return { success: false, error: error.message };
        }
    },

    // Get dashboard statistics
    async getDashboardStats(departmentId = null) {
        try {
            const departmentFilter = departmentId || AUTH.getDepartmentFilter();
            const today = DateUtils.today();

            let laborQuery = supabaseClient
                .from('laborers')
                .select('status, face_enrolled', { count: 'exact' })
                .eq('client_id', AUTH.getClientId());

            if (departmentFilter) {
                laborQuery = laborQuery.eq('department_id', departmentFilter);
            }

            const { data: laborers } = await laborQuery;

            const totalLaborers = laborers?.length || 0;
            const activeLaborers = laborers?.filter(l => l.status === 'active').length || 0;
            const faceEnrolled = laborers?.filter(l => l.face_enrolled).length || 0;

            let attendanceQuery = supabaseClient
                .from('daily_attendance')
                .select('final_status')
                .eq('client_id', AUTH.getClientId())
                .eq('date', today);

            if (departmentFilter) {
                attendanceQuery = attendanceQuery.eq('department_id', departmentFilter);
            }

            const { data: todayAttendance } = await attendanceQuery;

            const todayPresent = todayAttendance?.filter(a => a.final_status === 'P').length || 0;
            const todayAbsent = todayAttendance?.filter(a => a.final_status === 'A').length || 0;

            let punchQuery = supabaseClient
                .from('punch_records')
                .select('type')
                .eq('client_id', AUTH.getClientId())
                .eq('date', today);

            if (departmentFilter) {
                punchQuery = punchQuery.eq('department_id', departmentFilter);
            }

            const { data: todayPunches } = await punchQuery;

            const todayLogins = todayPunches?.filter(p => p.type === 'login').length || 0;
            const todayLogouts = todayPunches?.filter(p => p.type === 'logout').length || 0;

            let lopQuery = supabaseClient
                .from('daily_attendance')
                .select('id', { count: 'exact', head: true })
                .eq('client_id', AUTH.getClientId())
                .eq('date', today)
                .eq('final_status', 'A')
                .is('approved_by', null);

            if (departmentFilter) {
                lopQuery = lopQuery.eq('department_id', departmentFilter);
            }

            const { count: pendingLOP } = await lopQuery;

            return {
                success: true,
                data: {
                    totalLaborers,
                    activeLaborers,
                    faceEnrolled,
                    todayPresent,
                    todayAbsent,
                    todayLogins,
                    todayLogouts,
                    currentlyWorking: Math.max(0, todayLogins - todayLogouts),
                    pendingLOP: pendingLOP || 0
                }
            };
        } catch (error) {
            console.error('Get dashboard stats error:', error);
            return { success: false, error: error.message };
        }
    },

    // Approve LOP (single) - works for both existing and new records
    async approveLOP(attendanceId, reason, laborId = null, date = null, departmentId = null, finalStatus = 'P') {
        try {
            if (!attendanceId && laborId && date && departmentId) {
                return await this.createAbsentAndApprove(laborId, date, departmentId, reason, finalStatus);
            }

            const session = AUTH.getSession();

            const { error } = await supabaseClient
                .from('daily_attendance')
                .update({
                    final_status: finalStatus,
                    approved_by: session.name,
                    approved_at: new Date().toISOString(),
                    lop_reason: reason
                })
                .eq('id', attendanceId)
                .eq('client_id', AUTH.getClientId());

            if (error) throw error;
            return { success: true };
        } catch (error) {
            console.error('Approve LOP error:', error);
            return { success: false, error: error.message };
        }
    },

    // Bulk approve LOP (admin only)
    async bulkApproveLOP(attendanceIds, reason) {
        try {
            if (!AUTH.hasRole(['admin', 'super_admin'])) {
                return { success: false, error: 'Only admin can bulk approve' };
            }

            const session = AUTH.getSession();
            
            const { error } = await supabaseClient
                .from('daily_attendance')
                .update({
                    final_status: 'P',
                    approved_by: session.name,
                    approved_at: new Date().toISOString(),
                    lop_reason: reason
                })
                .in('id', attendanceIds)
                .eq('client_id', AUTH.getClientId());

            if (error) throw error;
            return { success: true };
        } catch (error) {
            console.error('Bulk approve LOP error:', error);
            return { success: false, error: error.message };
        }
    },

    // Undo LOP approval (admin only)
    async undoLOP(attendanceId, originalStatus) {
        try {
            if (!AUTH.hasRole(['admin', 'super_admin'])) {
                return { success: false, error: 'Only admin can undo approval' };
            }

            const { error } = await supabaseClient
                .from('daily_attendance')
                .update({
                    final_status: originalStatus || 'A',
                    approved_by: null,
                    approved_at: null,
                    lop_reason: null,
                    lop_request_id: null
                })
                .eq('id', attendanceId)
                .eq('client_id', AUTH.getClientId());

            if (error) throw error;
            return { success: true };
        } catch (error) {
            console.error('Undo LOP error:', error);
            return { success: false, error: error.message };
        }
    },

    // Check if date is still approvable (before 1st of next month)
    isDateApprovable(dateStr) {
        const date = new Date(dateStr);
        const now = new Date();
        const nextMonth = new Date(date.getFullYear(), date.getMonth() + 1, 1);
        return now < nextMonth;
    },

    // Check if a date is frozen
    async isDateFrozen(date) {
        try {
            const clientId = AUTH.getClientId();
            
            const { data, error } = await supabaseClient
                .from('attendance_freeze')
                .select('id')
                .eq('client_id', clientId)
                .eq('date', date)
                .single();

            if (error && error.code !== 'PGRST116') {
                throw error;
            }

            return { success: true, frozen: !!data };
        } catch (error) {
            console.error('Check freeze error:', error);
            return { success: false, frozen: false };
        }
    },

    // Freeze a date (admin or supervisor with freeze_day permission)
    async freezeDate(date) {
        try {
            if (!AUTH.hasRole(['admin', 'super_admin']) && !AUTH.hasPermission('freeze_day')) {
                return { success: false, error: 'Only admin can freeze attendance' };
            }

            const clientId = AUTH.getClientId();
            const session = AUTH.getSession();

            const { error } = await supabaseClient
                .from('attendance_freeze')
                .insert({
                    client_id: clientId,
                    date: date,
                    frozen_by: session.name
                });

            if (error) {
                if (error.code === '23505') {
                    return { success: false, error: 'This date is already frozen' };
                }
                throw error;
            }

            return { success: true };
        } catch (error) {
            console.error('Freeze date error:', error);
            return { success: false, error: error.message };
        }
    },

    // Get frozen dates for a range
    async getFrozenDates(fromDate, toDate) {
        try {
            const clientId = AUTH.getClientId();

            const { data, error } = await supabaseClient
                .from('attendance_freeze')
                .select('date, frozen_by, frozen_at')
                .eq('client_id', clientId)
                .gte('date', fromDate)
                .lte('date', toDate);

            if (error) throw error;

            return { success: true, data: data || [] };
        } catch (error) {
            console.error('Get frozen dates error:', error);
            return { success: false, data: [] };
        }
    }
};
