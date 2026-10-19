// Dawam Attendance - day rules shared by the reports (daily, overtime, 3PL) and the terminal's month screen
//
// Working day: Present (P) when the database says so (the full required hours were worked, or the administrator approved
// the day), otherwise Absent (A). There is no half day (migration 022).
// Friday (F) and holidays (NH) are always paid, punched or not. Only the sandwich rule (Settings) can change that:
// absent on the last working day before AND on the first working day after a run of Fridays / holidays -> the whole run is Absent.
// A run that holds a holiday follows the holiday switch, a run of Fridays only follows the Friday switch.
const AttendanceRules = {
    // 'YYYY-MM-DD' arithmetic without time zones
    addDays(dateStr, n) {
        const d = new Date(dateStr + 'T00:00:00Z');
        d.setUTCDate(d.getUTCDate() + n);
        return d.toISOString().slice(0, 10);
    },
    isFriday(dateStr) { return new Date(dateStr + 'T00:00:00Z').getUTCDay() === 5; },
    // the device's own date (not the UTC date)
    today() {
        const d = new Date();
        return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
    },

    // 'NH' for an active holiday, 'F' for a Friday, null for a working day. holidays = { 'YYYY-MM-DD': name }
    offDay(dateStr, holidays) {
        if (holidays && holidays[dateStr]) return 'NH';
        return this.isFriday(dateStr) ? 'F' : null;
    },

    // the two switches of the Settings page (a switch that was never saved is shown ON there, so it counts as on)
    sandwichSwitches(settings) {
        const on = v => String(v == null ? 'true' : v) !== 'false';
        return { friday: on(settings && settings.sandwich_rule_friday), nh: on(settings && settings.sandwich_rule_nh) };
    },

    // status of a WORKING day from its daily_attendance row (none = no punch = Absent)
    workingStatus(record) {
        if (!record) return 'A';
        if (record.approved_by && String(record.approved_by).trim()) return record.final_status === 'A' ? 'A' : 'P';
        return record.final_status === 'P' ? 'P' : 'A';
    },

    // Is this Friday / holiday Absent because of the sandwich rule?
    //   statusOf(dateStr) -> 'P' | 'A' for a working day, or null when it is not known (before joining, after leaving, today or later)
    sandwiched(dateStr, holidays, switches, statusOf) {
        if (!this.offDay(dateStr, holidays)) return false;
        let hasHoliday = false;
        let before = dateStr, after = dateStr;
        for (let i = 0; i < 40 && this.offDay(before, holidays); i++) { if (holidays && holidays[before]) hasHoliday = true; before = this.addDays(before, -1); }
        for (let i = 0; i < 40 && this.offDay(after, holidays); i++) { if (holidays && holidays[after]) hasHoliday = true; after = this.addDays(after, 1); }
        if (!(hasHoliday ? switches.nh : switches.friday)) return false;
        return statusOf(before) === 'A' && statusOf(after) === 'A';
    }
};
