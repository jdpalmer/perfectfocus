// app — event loop, keybindings, edit modes.
import "event";
import "term";
import "screen";
import "model";
import "store";
import "ui";
import "crash";
import "str";
import "os";
import "fs";

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum AppEditKind {
	EditNone = 0,
	EditTitle = 1,
	EditCc = 2,
	EditFilterText = 3,
	EditNewTitle = 4,
	EditFilterCc = 5,
	/* focus: @attn or #tag */
	EditKillConfirm = 6
};

struct App {
	TaskStore store;
	ViewFilter filter;
	int visible[VisibleMax];
	int visible_count;
	UiState ui;
	char db_path[1024];
	AppEditKind edit_kind;
	int kill_idx;
	/* store index pending EditKillConfirm */
	bool running;
	bool import_only;
	bool add_only;
	char add_title[TaskTitleCap];
	char add_attn[TaskCcCap];
	char add_tags[TaskTagsCap];
	int64_t db_mtime_ns;
	bool db_mtime_ok;
};

static App g_app;

static char[..] db_path_view() {
	return ranged(g_app.db_path, strlen(g_app.db_path));
}

static void note_db_mtime() {
	auto (info, ok) = fs_stat(db_path_view());
	g_app.db_mtime_ok = ok;
	g_app.db_mtime_ns = ok ? info.mtime_ns: 0;
}

static void refresh_visible() {
	g_app.visible_count = g_app.store.build_visible(&g_app.filter, ranged(g_app.visible, VisibleMax));
	g_app.ui.visible_count = g_app.visible_count;
	ui_clamp(&g_app.ui);
}

static void select_task_id(const char[..] id) {
	int i = 0;
	if (len(id) == 0) {
		return;
	}
	for (; i < g_app.visible_count; i++) {
		Task* t = g_app.store.get(g_app.visible[i]);
		if (t != NULL && t.id.eq(id)) {
			g_app.ui.selected = i;
			ui_clamp(&g_app.ui);
			return;
		}
	}
}

static void capture_id(char[..] dst, const Task* t) {
	cstr_reset(dst);
	if (t != NULL) {
		(void)cstr_write(dst, t.id);
	}
}

static void mark_saved() {
	ui_set_status(&g_app.ui, "saved");
}

/* Persist without clobbering a status flash message. */
static bool save_db_quiet() {
	if (!g_app.store.save(db_path_view())) {
		ui_set_status(&g_app.ui, "save failed");
		return false;
	}
	note_db_mtime();
	return true;
}

static bool save_db() {
	if (!save_db_quiet()) {
		return false;
	}
	mark_saved();
	return true;
}

static TaskStore g_incoming;

/* When the DB file changes, merge by id + updated (task-level LWW). */
static bool maybe_reload_db() {
	char id[TaskIdCap] = { 0 };
	if (g_app.ui.editing) {
		return false;
	}
	auto (info, ok) = fs_stat(db_path_view());
	if (!ok) {
		return false;
	}
	if (g_app.db_mtime_ok && info.mtime_ns == g_app.db_mtime_ns) {
		return false;
	}
	capture_id(ranged(id, sizeof(id)), ui_selected_task(&g_app.ui));
	if (!g_incoming.load(db_path_view())) {
		/* Keep last-good mtime so a partial Syncthing write is retried. */
		ui_set_status(&g_app.ui, "reload failed");
		return true;
	}
	bool changed = g_app.store.merge(&g_incoming);
	note_db_mtime();
	if (changed && save_db_quiet()) {
		ui_set_status(&g_app.ui, "merged");
	}
	refresh_visible();
	select_task_id(ranged(id, cstr_zlen(ranged(id, sizeof(id)))));
	return true;
}

static void crash_cleanup() {
	term_close();
}

static void app_term_on_paste(char[..] data) {
	event_enqueue(event_paste(ptr(data), len(data)));
}

static void app_term_on_resize() {
	event_enqueue(event_resize());
}

static void begin_edit(AppEditKind kind, const char[..] prompt, const char[..] initial) {
	g_app.edit_kind = kind;
	ui_begin_edit(&g_app.ui, prompt, initial);
}

static void cancel_edit() {
	g_app.edit_kind = EditNone;
	g_app.kill_idx = -1;
	ui_end_edit(&g_app.ui);
}

/* Format Attn "A, B" as "@A, @B " for new-task / title prefill. */
static void attn_to_at_prefill(const char[..] cc, char[..] dst) {
	size_t i = 0;
	size_t off = 0;
	cstr_reset(dst);
	if (ptr(dst) == NULL || cap(dst) < 2) {
		return;
	}
	while (i < len(cc) && off + 2 < cap(dst)) {
		size_t start = 0;
		size_t end = 0;
		while (i < len(cc) && (cc[i] == ' ' || cc[i] == '\t')) {
			i++;
		}
		start = i;
		while (i < len(cc) && cc[i] != ',') {
			i++;
		}
		end = i;
		while (end > start && (cc[end - 1] == ' ' || cc[end - 1] == '\t')) {
			end--;
		}
		if (end > start) {
			size_t n = end - start;
			if (off > 0) {
				if (off + 2 >= cap(dst)) {
					break;
				}
				dst[off++] = ',';
				dst[off++] = ' ';
			}
			if (off + 1 + n + 1 >= cap(dst)) {
				break;
			}
			dst[off++] = '@';
			copy(dst[off .. off + n], cc[start .. start + n]);
			off += n;
			dst[off] = 0;
		}
		if (i < len(cc) && cc[i] == ',') {
			i++;
		}
	}
	if (off > 0 && off + 1 < cap(dst)) {
		dst[off++] = ' ';
		dst[off] = 0;
	}
}

static void do_kill(int idx) {
	if (!g_app.store.kill(idx)) {
		ui_set_status(&g_app.ui, "kill failed");
		return;
	}
	refresh_visible();
	ui_clamp(&g_app.ui);
	ui_set_status(&g_app.ui, "killed");
	(void)save_db_quiet();
}

static bool val_is_all(const char[..] val) {
	return len(val) == 0 || val.eq("*") || val.eq("all");
}

/*
 * First-run only (missing DB): a few real tasks that teach the sheet.
 * Tagged #tutorial so focus/find/kill are obvious.
 */
static bool seed_tutorial_tasks() {
	static const struct {
		const char* status;
		const char* title;
		const char* attn;
	} rows[] = {
		{ "A:Inbox", "Press n to capture — @Ada and #tags go on the same line", "" },
		{ "B:Now", "Press s to cycle status; keep Now small (footer warns past 7)", "" },
		{ "C:Soon", "Press f then #tutorial to focus; / to find; again clears", "" },
		{ "E:Waiting", "Waiting = ball in their court — Attn says who", "Ada" },
		{ "G:Someday", "Press d to delete these when you are done exploring", "" },
	};
	for (int i = 0; i < (int)(sizeof(rows) / sizeof(rows[0])); i++) {
		Task t = { 0 };
		const char[..] title = ranged(rows[i].title, strlen(rows[i].title));
		const char[..] status = ranged(rows[i].status, strlen(rows[i].status));
		const char[..] attn = ranged(rows[i].attn, strlen(rows[i].attn));
		if (!str_set(&t.title, title) || !str_set(&t.status, status)) {
			t.clear();
			return false;
		}
		if (!g_app.store.add(&t)) {
			t.clear();
			return false;
		}
		t.clear();
		int at = g_app.store.count - 1;
		if (at < 0 || !g_app.store.set_tags(at, "#tutorial")) {
			return false;
		}
		if (len(attn) > 0 && !g_app.store.set_cc(at, attn)) {
			return false;
		}
	}
	return true;
}

/*
 * Append Inbox task. title required; tags/attn optional (normalized via setters).
 * On success writes id into id_out (if provided) and returns store index; else -1.
 */
static int add_inbox_task(const char[..] title, const char[..] tags, const char[..] attn, char[..] id_out) {
	Task t = { 0 };
	if (len(title) == 0) {
		return -1;
	}
	if (!str_set(&t.title, title) || !str_set(&t.status, "A:Inbox")) {
		t.clear();
		return -1;
	}
	if (!g_app.store.add(&t)) {
		t.clear();
		return -1;
	}
	t.clear();
	int at = g_app.store.count - 1;
	if (at < 0) {
		return -1;
	}
	if (len(tags) > 0 && !g_app.store.set_tags(at, tags)) {
		(void)g_app.store.remove(at);
		return -1;
	}
	if (len(attn) > 0 && !g_app.store.set_cc(at, attn)) {
		(void)g_app.store.remove(at);
		return -1;
	}
	if (ptr(id_out) != NULL && cap(id_out) > 0) {
		capture_id(id_out, &g_app.store.tasks[at]);
	}
	return at;
}

/* Apply title line: #tags and optional @attn. Rolls back on partial failure. */
static bool apply_title_line(int idx, const char[..] raw) {
	pool p {
		auto (title, tags, attn, ok) = model_parse_task_line(&p, raw);
		Task* t = g_app.store.get(idx);
		char[..] old_title = str_empty();
		char[..] old_tags = str_empty();
		char[..] old_cc = str_empty();
		if (!ok || len(title) == 0 || t == NULL) {
			return false;
		}
		defer str_free(&old_title);
		defer str_free(&old_tags);
		defer str_free(&old_cc);
		if (!str_set(&old_title, t.title) || !str_set(&old_tags, t.tags) || !str_set(&old_cc, t.cc)) {
			return false;
		}
		if (!g_app.store.set_title(idx, title)) {
			return false;
		}
		if (!g_app.store.set_tags(idx, tags)) {
			(void)g_app.store.set_title(idx, old_title);
			(void)g_app.store.set_tags(idx, old_tags);
			return false;
		}
		if (len(attn) > 0 && !g_app.store.set_cc(idx, attn)) {
			(void)g_app.store.set_title(idx, old_title);
			(void)g_app.store.set_tags(idx, old_tags);
			(void)g_app.store.set_cc(idx, old_cc);
			return false;
		}
		return true;
	}
}

static void apply_edit() {
	int idx = ui_selected_store_index(&g_app.ui);
	char valbuf[UiInputCap] = { 0 };
	AppEditKind kind = g_app.edit_kind;
	snprintf(valbuf, sizeof(valbuf), "%s", g_app.ui.input);
	const char[..] val = ranged(valbuf, strlen(valbuf));
	g_app.edit_kind = EditNone;
	ui_end_edit(&g_app.ui);
	if (kind == EditFilterText) {
		(void)str_set(&g_app.filter.text, val);
		refresh_visible();
		ui_set_status(&g_app.ui, "filter set");
		return;
	}
	if (kind == EditFilterCc) {
		/* One focus: :status / @attn / bare → Attn; # → tag. */
		(void)str_set(&g_app.filter.cc, "");
		(void)str_set(&g_app.filter.tag, "");
		(void)str_set(&g_app.filter.status, "");
		if (val_is_all(val)) {
			ui_set_status(&g_app.ui, "focus cleared");
		} else if (len(val) > 0 && val[0] == ':') {
			pool p {
				auto (st, ok) = model_parse_status_focus(&p, val);
				if (!ok) {
					ui_set_status(&g_app.ui, "unknown status");
					refresh_visible();
					return;
				}
				(void)str_set(&g_app.filter.status, st);
				if (str_eq_cstr(st, "F:Complete")) {
					g_app.filter.show_complete = true;
				}
				ui_set_status(&g_app.ui, "status focus set");
			}
		} else if (len(val) > 0 && val[0] == '#') {
			(void)str_set(&g_app.filter.tag, val);
			ui_set_status(&g_app.ui, "tag focus set");
		} else if (len(val) > 0 && val[0] == '@') {
			(void)str_set(&g_app.filter.cc, val[1 ..]);
			ui_set_status(&g_app.ui, "focus set");
		} else {
			(void)str_set(&g_app.filter.cc, val);
			ui_set_status(&g_app.ui, "focus set");
		}
		refresh_visible();
		return;
	}
	if (kind == EditNewTitle) {
		char id[TaskIdCap] = { 0 };
		pool p {
			auto (title, tags, attn, ok) = model_parse_task_line(&p, val);
			if (!ok || len(title) == 0) {
				ui_set_status(&g_app.ui, "cancelled");
				return;
			}
			int at = add_inbox_task(title, tags, attn, ranged(id, sizeof(id)));
			if (at < 0) {
				ui_set_status(&g_app.ui, "add failed");
				return;
			}
			refresh_visible();
			select_task_id(ranged(id, cstr_zlen(ranged(id, sizeof(id)))));
			ui_set_status(&g_app.ui, "added");
			save_db();
			return;
		}
	}
	if (idx < 0) {
		ui_set_status(&g_app.ui, "no selection");
		return;
	}
	if (kind == EditTitle) {
		if (!apply_title_line(idx, val)) {
			ui_set_status(&g_app.ui, "cancelled");
			return;
		}
	} else if (kind == EditCc) {
		if (!g_app.store.set_cc(idx, val)) {
			ui_set_status(&g_app.ui, "attn failed");
			return;
		}
	} else {
		panic("modfocus: unexpected edit kind");
	}
	(void)save_db();
}

static void handle_normal_key(uint32_t key) {
	if (key == 'q' || key == 'Q') {
		if (g_app.store.dirty) {
			save_db();
		}
		g_app.running = false;
		return;
	}
	if (key == TermKeyUp || key == 'k' || key == (TermCTL | (uint32_t)'P')) {
		if (g_app.ui.selected > 0) {
			g_app.ui.selected--;
		}
		return;
	}
	if (key == TermKeyDown || key == 'j' || key == (TermCTL | (uint32_t)'N')) {
		if (g_app.ui.selected + 1 < g_app.visible_count) {
			g_app.ui.selected++;
		}
		return;
	}
	/* jem: S-Up / S-Down page; also PageUp/Down and C-v */
	if (key == (TermSHIFT | TermKeyUp) || key == TermKeyPageUp) {
		g_app.ui.selected -= ui_page_rows();
		ui_clamp(&g_app.ui);
		return;
	}
	if (key == (TermSHIFT | TermKeyDown) || key == TermKeyPageDown || key == (TermCTL | (uint32_t)'V')) {
		g_app.ui.selected += ui_page_rows();
		ui_clamp(&g_app.ui);
		return;
	}
	if (key == 'g') {
		g_app.ui.selected = 0;
		return;
	}
	if (key == 'G') {
		if (g_app.visible_count > 0) {
			g_app.ui.selected = g_app.visible_count - 1;
		}
		return;
	}
	if (key == 'X') {
		g_app.filter.show_complete = !g_app.filter.show_complete;
		refresh_visible();
		ui_set_status(&g_app.ui, g_app.filter.show_complete ? "showing complete": "hiding complete");
		return;
	}
	if (key == 'o' || key == 'O') {
		/* Explicit reorder — edits leave list order alone so rows don't jump. */
		char id[TaskIdCap] = { 0 };
		capture_id(ranged(id, sizeof(id)), ui_selected_task(&g_app.ui));
		if (key == 'O') {
			g_app.store.sort_rev();
			ui_set_status(&g_app.ui, "sorted rev");
		} else {
			g_app.store.sort();
			ui_set_status(&g_app.ui, "sorted");
		}
		refresh_visible();
		select_task_id(ranged(id, cstr_zlen(ranged(id, sizeof(id)))));
		return;
	}
	if (key == '/') {
		/* Toggle: clear find if set; otherwise prompt (same idea as f). */
		if (len(g_app.filter.text) != 0) {
			(void)str_set(&g_app.filter.text, "");
			refresh_visible();
			ui_set_status(&g_app.ui, "find cleared");
			return;
		}
		begin_edit(EditFilterText, "find: ", "");
		return;
	}
	if (key == 'n') {
		/* One field: @attn and #tags in the line; prefill @ from current row. */
		char pre[UiInputCap] = { 0 };
		Task* cur = ui_selected_task(&g_app.ui);
		if (cur != NULL && len(cur.cc) != 0) {
			attn_to_at_prefill(cur.cc, ranged(pre, sizeof(pre)));
		}
		begin_edit(EditNewTitle, "new (@attn #tags): ", ranged(pre, strlen(pre)));
		return;
	}
	int idx = ui_selected_store_index(&g_app.ui);
	Task* t = ui_selected_task(&g_app.ui);
	if (key == 'f') {
		/* Toggle: clear Attn, tag, or status focus; otherwise prompt. */
		if (len(g_app.filter.cc) != 0 || len(g_app.filter.tag) != 0 || len(g_app.filter.status) != 0) {
			(void)str_set(&g_app.filter.cc, "");
			(void)str_set(&g_app.filter.tag, "");
			(void)str_set(&g_app.filter.status, "");
			refresh_visible();
			ui_set_status(&g_app.ui, "focus cleared");
			return;
		}
		begin_edit(EditFilterCc, "focus (@attn #tag :status): ", "");
		return;
	}
	if (idx < 0 || t == NULL) {
		return;
	}
	if (key == 's') {
		if (!g_app.store.cycle_status(idx)) {
			ui_set_status(&g_app.ui, "status failed");
			return;
		}
		refresh_visible();
		ui_set_status(&g_app.ui, t.status);
		(void)save_db_quiet();
		return;
	}
	if (key == 'S') {
		if (!g_app.store.cycle_status_prev(idx)) {
			ui_set_status(&g_app.ui, "status failed");
			return;
		}
		refresh_visible();
		ui_set_status(&g_app.ui, t.status);
		(void)save_db_quiet();
		return;
	}
	if (key == 'x') {
		/* Mark complete (hidden from default view unless X). */
		if (!g_app.store.set_status(idx, "F:Complete")) {
			ui_set_status(&g_app.ui, "complete failed");
			return;
		}
		refresh_visible();
		ui_set_status(&g_app.ui, g_app.filter.show_complete ? "marked F:Complete": "marked F:Complete (hidden; X to show)");
		(void)save_db_quiet();
		return;
	}
	if (key == 'd') {
		g_app.kill_idx = idx;
		begin_edit(EditKillConfirm, "are you sure? y/n ", "");
		return;
	}
	if (key == 't' || key == TermKeyEnter) {
		char joined[UiInputCap] = { 0 };
		if (!model_format_task_line(t.title, t.tags, t.cc, ranged(joined, sizeof(joined)))) {
			begin_edit(EditTitle, "title (@attn #tags): ", t.title);
		} else {
			begin_edit(EditTitle, "title (@attn #tags): ", ranged(joined, strlen(joined)));
		}
		return;
	}
	if (key == 'a') {
		begin_edit(EditCc, "attn: ", t.cc);
		return;
	}
}

/* Replace input[start..end) with done; advances caret. */
static void replace_input_span(int start, int end, const char[..] done) {
	UiState* ui = &g_app.ui;
	int dlen = (int)len(done);
	int new_len = ui.input_len - (end - start) + dlen;
	char buf[sizeof(ui.input)] = { 0 };
	if (new_len < 0 || new_len >= (int) sizeof(ui.input)) {
		return;
	}
	if (start > 0) {
		memcpy(buf, ui.input, start);
	}
	if (dlen > 0) {
		memcpy(buf + start, ptr(done), dlen);
	}
	memcpy(buf + start + dlen, ui.input + end, ui.input_len - end);
	buf[new_len] = 0;
	memcpy(ui.input, buf, new_len + 1);
	ui.input_len = new_len;
	ui.input_cursor = start + dlen;
}

/* Token at caret: comma_only → Attn names; else space/comma-bounded (#tags / focus). */
static(int, int) input_token_span(bool comma_only) {
	UiState* ui = &g_app.ui;
	int start = ui.input_cursor;
	int end = ui.input_cursor;
	while (start > 0) {
		char c = ui.input[start - 1];
		if (comma_only) {
			if (c == ',') {
				break;
			}
		} else if (c == ',' || c == ' ' || c == '\t') {
			break;
		}
		start--;
	}
	if (comma_only) {
		while (start < end && (ui.input[start] == ' ' || ui.input[start] == '\t')) {
			start++;
		}
		while (end < ui.input_len && ui.input[end] != ',') {
			end++;
		}
	} else {
		while (end < ui.input_len && ui.input[end] != ',' && ui.input[end] != ' ' && ui.input[end] != '\t') {
			end++;
		}
	}
	return (start, end);
}

/* Run attn or tag complete over input[start..end); true if the span changed. */
static bool apply_complete(int start, int end, bool tag) {
	UiState* ui = &g_app.ui;
	char prefix[64] = { 0 };
	char done[64] = { 0 };
	int plen = end - start;
	if (plen < 0) {
		plen = 0;
	}
	if (plen >= (int) sizeof(prefix)) {
		plen = (int) sizeof(prefix) - 1;
	}
	if (plen > 0) {
		memcpy(prefix, ui.input + start, plen);
	}
	prefix[plen] = 0;
	if (tag) {
		if (!g_app.store.tag_complete(ranged(prefix, (size_t)plen), ranged(done, sizeof(done)))) {
			return false;
		}
	} else if (!g_app.store.attn_complete(ranged(prefix, (size_t)plen), ranged(done, sizeof(done)))) {
		return false;
	}
	replace_input_span(start, end, ranged(done, cstr_zlen(ranged(done, sizeof(done)))));
	return true;
}

/* Tab-complete the Attn token at the caret (comma-separated short names). */
static void complete_attn_token() {
	auto (start, end) = input_token_span(true);
	(void)apply_complete(start, end, false);
}

/* Tab-complete a #tag token (space/comma-bounded). */
static void complete_tag_token() {
	auto (start, end) = input_token_span(false);
	(void)apply_complete(start, end, true);
}

/* Complete @Name token: strip @ for lookup, write @Name back. */
static bool apply_at_complete(int start, int end) {
	UiState* ui = &g_app.ui;
	char prefix[64] = { 0 };
	char done[64] = { 0 };
	char out[66] = { 0 };
	int plen = end - start;
	if (plen < 0) {
		plen = 0;
	}
	if (plen >= (int) sizeof(prefix)) {
		plen = (int) sizeof(prefix) - 1;
	}
	if (plen > 0) {
		memcpy(prefix, ui.input + start, plen);
	}
	prefix[plen] = 0;
	const char[..] want = (plen > 0 && prefix[0] == '@') ? ranged(prefix + 1, (size_t)(plen - 1)): ranged(prefix, (size_t)plen);
	if (!g_app.store.attn_complete(want, ranged(done, sizeof(done)))) {
		return false;
	}
	out[0] = '@';
	{
		size_t n = cstr_zlen(ranged(done, sizeof(done)));
		if (n + 2 > sizeof(out)) {
			n = sizeof(out) - 2;
		}
		if (n > 0) {
			memcpy(out + 1, done, n);
		}
		out[n + 1] = 0;
		replace_input_span(start, end, ranged(out, n + 1));
	}
	return true;
}

/* Focus prompt: #… → tag; @… → Attn; else Attn, then tag fallback. */
static void complete_focus_token() {
	UiState* ui = &g_app.ui;
	auto (start, end) = input_token_span(false);
	if (start < ui.input_len && ui.input[start] == '#') {
		(void)apply_complete(start, end, true);
		return;
	}
	if (start < ui.input_len && ui.input[start] == '@') {
		(void)apply_at_complete(start, end);
		return;
	}
	if (apply_complete(start, end, false)) {
		return;
	}
	(void)apply_complete(start, end, true);
}

/* Title / new-task line: Tab completes @attn and #tags. */
static void complete_task_line_token() {
	UiState* ui = &g_app.ui;
	auto (start, end) = input_token_span(false);
	if (start < ui.input_len && ui.input[start] == '#') {
		(void)apply_complete(start, end, true);
		return;
	}
	if (start < ui.input_len && ui.input[start] == '@') {
		(void)apply_at_complete(start, end);
	}
}

static void handle_event(Event* ev) {
	if (ev == NULL) {
		return;
	}
	if (ev.kind == EventQuit) {
		g_app.running = false;
		return;
	}
	if (ev.kind == EventResize) {
		term_refresh_size();
		screen_ensure_size();
		screen_invalidate();
		return;
	}
	if (ev.kind == EventKey) {
		uint32_t key = ev.key_code;
		/* jem: C-l → cmd_refresh / display_invalidate */
		if (key == (TermCTL | (uint32_t)'L') || key == (uint32_t)('L' - '@')) {
			screen_invalidate();
			return;
		}
		if (g_app.ui.editing) {
			if (g_app.edit_kind == EditKillConfirm) {
				int idx = g_app.kill_idx;
				if (key == 'y' || key == 'Y') {
					cancel_edit();
					do_kill(idx);
				} else if (key == 'n' || key == 'N' || key == 0x1B || key == (TermCTL | (uint32_t)'G') || key == (uint32_t)('G' - '@')) {
					cancel_edit();
					ui_set_status(&g_app.ui, "cancelled");
				}
				/* ignore other keys until y/n */
				return;
			}
			if (g_app.edit_kind == EditCc && (key == '\t' || key == TermKeyTab)) {
				complete_attn_token();
				return;
			}
			if (g_app.edit_kind == EditFilterCc && (key == '\t' || key == TermKeyTab)) {
				complete_focus_token();
				return;
			}
			if ((g_app.edit_kind == EditTitle || g_app.edit_kind == EditNewTitle) && (key == '\t' || key == TermKeyTab)) {
				complete_task_line_token();
				return;
			}
			if (ui_edit_handle_key(&g_app.ui, key)) {
				if (g_app.ui.edit_cancelled) {
					cancel_edit();
					ui_set_status(&g_app.ui, "cancelled");
				} else {
					apply_edit();
				}
			}
			return;
		}
		handle_normal_key(key);
		return;
	}
}

static void usage() {
	fprintf(stderr, "usage: modfocus [--db path] [--import seed.json]\n");
	fprintf(stderr, "       modfocus [--db path] add [--attn name] [--tag name]... title...\n");
	fprintf(stderr, "  MFDB env overrides default config path\n");
	fprintf(stderr, "  add captures into A:Inbox; @attn and #tags in the title are parsed\n");
	fprintf(stderr, "  Kitty keyboard protocol preferred (Kitty, Ghostty, …); other TTYs work with basic keys\n");
}

/* Join args[from..] into dst with spaces; false if empty or won't fit. */
static bool join_title_args(const char[..][..] args, size_t from, char[..] dst) {
	size_t i = from;
	size_t off = 0;
	if (ptr(dst) == NULL || cap(dst) == 0) {
		return false;
	}
	dst[0] = 0;
	for (; i < len(args); i++) {
		const char[..] a = args[i];
		size_t n = len(a);
		size_t need = n + (off > 0 ? 1: 0);
		if (off + need + 1 > cap(dst)) {
			fprintf(stderr, "modfocus: title too long (max %d)\n", TaskTitleCap - 1);
			return false;
		}
		if (off > 0) {
			dst[off] = ' ';
			off++;
		}
		if (n > 0) {
			copy(dst[off .. off + n], a[0 .. n]);
			off += n;
		}
		dst[off] = 0;
	}
	return off > 0;
}

static bool append_add_tag(const char[..] raw) {
	size_t have = strlen(g_app.add_tags);
	size_t start = 0;
	if (len(raw) == 0) {
		return true;
	}
	if (raw[0] == '#') {
		start = 1;
	}
	if (start >= len(raw)) {
		return true;
	}
	size_t n = len(raw) - start;
	if (n > TagNameCap) {
		n = TagNameCap;
	}
	if (have + 1 + 1 + n >= sizeof(g_app.add_tags)) {
		fprintf(stderr, "modfocus: tags too long (max %d)\n", TaskTagsCap - 1);
		return false;
	}
	if (have > 0) {
		g_app.add_tags[have++] = ' ';
	}
	g_app.add_tags[have++] = '#';
	memcpy(g_app.add_tags + have, ptr(raw) + start, n);
	have += n;
	g_app.add_tags[have] = 0;
	return true;
}

static bool parse_add_args(const char[..][..] args, size_t i) {
	g_app.add_only = true;
	g_app.add_title[0] = 0;
	g_app.add_attn[0] = 0;
	g_app.add_tags[0] = 0;
	for (; i < len(args); i++) {
		const char[..] a = args[i];
		if (a.eq("--attn") || a.eq("-a")) {
			i++;
			if (i >= len(args)) {
				fprintf(stderr, "modfocus: --attn needs a name\n");
				return false;
			}
			if (len(args[i]) >= sizeof(g_app.add_attn)) {
				fprintf(stderr, "modfocus: attn too long (max %d)\n", TaskCcCap - 1);
				return false;
			}
			(void)cstr_write(ranged(g_app.add_attn, sizeof(g_app.add_attn)), args[i]);
			continue;
		}
		if (a.eq("--tag") || a.eq("-t")) {
			i++;
			if (i >= len(args)) {
				fprintf(stderr, "modfocus: --tag needs a name\n");
				return false;
			}
			if (!append_add_tag(args[i])) {
				return false;
			}
			continue;
		}
		if (len(a) > 0 && a[0] == '-') {
			fprintf(stderr, "modfocus: unknown add option %.*s\n", (int)len(a), ptr(a));
			usage();
			return false;
		}
		return join_title_args(args, i, ranged(g_app.add_title, sizeof(g_app.add_title)));
	}
	fprintf(stderr, "modfocus: add needs a title\n");
	usage();
	return false;
}

/*
 * (continue, exit_status). continue false → exit with exit_status
 * (0 for --help, 1 for usage/arg errors).
 */
static(bool, int) parse_args(const char[..][..] args, char[..] import_path) {
	size_t i = 1;
	if (ptr(import_path) != NULL && cap(import_path) > 0) {
		(void)snprintf(ptr(import_path), cap(import_path), "%s", "");
	}
	for (; i < len(args); i++) {
		const char[..] a = args[i];
		if (a.eq("--help") || a.eq("-h")) {
			usage();
			return (false, 0);
		}
		if (a.eq("--db")) {
			i++;
			if (i >= len(args)) {
				fprintf(stderr, "modfocus: --db needs a path\n");
				return (false, 1);
			}
			(void)cstr_write(ranged(g_app.db_path, sizeof(g_app.db_path)), args[i]);
			continue;
		}
		if (a.eq("--import")) {
			i++;
			if (i >= len(args) || ptr(import_path) == NULL) {
				fprintf(stderr, "modfocus: --import needs a path\n");
				return (false, 1);
			}
			(void)cstr_write(import_path, args[i]);
			g_app.import_only = true;
			continue;
		}
		if (a.eq("add")) {
			if (g_app.import_only) {
				fprintf(stderr, "modfocus: add and --import cannot be combined\n");
				return (false, 1);
			}
			if (!parse_add_args(args, i + 1)) {
				return (false, 1);
			}
			return (true, 0);
		}
		fprintf(stderr, "modfocus: unknown arg %.*s\n", (int)len(a), ptr(a));
		usage();
		return (false, 1);
	}
	return (true, 0);
}

/* Load-or-create DB, append Inbox task, save; no TUI. */
static bool cli_add_task() {
	if (strlen(g_app.add_title) == 0) {
		fprintf(stderr, "modfocus: add needs a title\n");
		return false;
	}
	pool p {
		auto (title, tags, attn, ok) = model_parse_task_line(&p, ranged(g_app.add_title, strlen(g_app.add_title)));
		char[..] merged_tags = { 0 };
		char[..] merged_attn = { 0 };
		if (!ok || len(title) == 0) {
			fprintf(stderr, "modfocus: add needs a title\n");
			return false;
		}
		/* Merge #tags / @attn from the line with --tag / --attn flags. */
		if (len(tags) > 0 && !p.append(&merged_tags, tags)) {
			fprintf(stderr, "modfocus: tags failed\n");
			return false;
		}
		if (strlen(g_app.add_tags) != 0) {
			if (len(merged_tags) > 0 && !p.append(&merged_tags, " ")) {
				fprintf(stderr, "modfocus: tags failed\n");
				return false;
			}
			if (!p.append(&merged_tags, ranged(g_app.add_tags, strlen(g_app.add_tags)))) {
				fprintf(stderr, "modfocus: tags failed\n");
				return false;
			}
		}
		if (len(attn) > 0 && !p.append(&merged_attn, attn)) {
			fprintf(stderr, "modfocus: attn failed\n");
			return false;
		}
		if (strlen(g_app.add_attn) != 0) {
			if (len(merged_attn) > 0 && !p.append(&merged_attn, " ")) {
				fprintf(stderr, "modfocus: attn failed\n");
				return false;
			}
			if (!p.append(&merged_attn, ranged(g_app.add_attn, strlen(g_app.add_attn)))) {
				fprintf(stderr, "modfocus: attn failed\n");
				return false;
			}
		}
		(void)store_recover_primary(db_path_view());
		if (!g_app.store.load(db_path_view())) {
			if (store_path_is_file(db_path_view())) {
				fprintf(stderr, "modfocus: load failed (refusing to overwrite)\n");
				return false;
			}
			g_app.store.init();
		}
		char id[TaskIdCap] = { 0 };
		int at = add_inbox_task(title, merged_tags, merged_attn, ranged(id, sizeof(id)));
		if (at < 0) {
			fprintf(stderr, "modfocus: add failed\n");
			return false;
		}
		/* Re-read disk and LWW-merge so a concurrent TUI/other save is kept. */
		{
			static TaskStore disk;
			disk.init();
			if (disk.load(db_path_view())) {
				(void)g_app.store.merge(&disk);
			}
		}
		if (!g_app.store.save(db_path_view())) {
			fprintf(stderr, "modfocus: save failed\n");
			return false;
		}
		if (strlen(id) != 0) {
			fprintf(stderr, "modfocus: added %s\n", id);
			printf("%s\n", id);
		} else {
			fprintf(stderr, "modfocus: added\n");
		}
		return true;
	}
}

int app_run(const char[..][..] args) {
	char import_path[1024] = { 0 };
	memset(&g_app, 0, sizeof(g_app));
	g_app.store.init();
	g_app.filter.init();
	ui_init(&g_app.ui, &g_app.store, &g_app.filter, ranged(g_app.visible, VisibleMax));
	g_app.edit_kind = EditNone;
	g_app.kill_idx = -1;
	g_app.running = true;
	pool p {
		auto (path, ok) = store_default_path(&p);
		if (ok) {
			(void)cstr_write(ranged(g_app.db_path, sizeof(g_app.db_path)), path);
		} else {
			snprintf(g_app.db_path, sizeof(g_app.db_path), "tasks.json");
		}
	}
	{
		auto (go, status) = parse_args(args, ranged(import_path, sizeof(import_path)));
		if (!go) {
			return status;
		}
	}
	if (strlen(import_path) != 0) {
		if (!store_import_file(&g_app.store, ranged(import_path, strlen(import_path)), db_path_view())) {
			fprintf(stderr, "modfocus: import failed: %s\n", import_path);
			return 1;
		}
		fprintf(stderr, "modfocus: imported %d tasks into %s\n", g_app.store.count, g_app.db_path);
		if (g_app.import_only) {
			return 0;
		}
	} else if (g_app.add_only) {
		return cli_add_task() ? 0: 1;
	} else {
		(void)store_recover_primary(db_path_view());
		if (!g_app.store.load(db_path_view())) {
			if (store_path_is_file(db_path_view())) {
				fprintf(stderr, "modfocus: load failed: %s\n", g_app.db_path);
				return 1;
			}
			/* Truly missing — first run: seed a short #tutorial list. */
			g_app.store.init();
			if (!seed_tutorial_tasks() || !save_db_quiet()) {
				fprintf(stderr, "modfocus: tutorial seed failed\n");
				return 1;
			}
			ui_set_status(&g_app.ui, "tutorial");
		}
	}
	note_db_mtime();
	refresh_visible();
	crash_init(crash_cleanup);
	{
		TermConfig cfg = { 0 };
		cstr_write(cfg.prog, "modfocus");
		cstr_write(cfg.title, "ModFocus");
		cfg.require_kitty = false;
		cfg.mouse = false;
		cfg.allow_non_tty = false;
		cfg.reserve_bottom = 0;
		cfg.on_paste = app_term_on_paste;
		cfg.on_resize = app_term_on_resize;
		if (!term_open(cfg)) {
			fprintf(stderr, "modfocus: term_open failed (need a TTY)\n");
			return 1;
		}
	}
	defer term_close();
	screen_init();
	defer screen_shutdown();
	bool need_paint = true;
	while (g_app.running) {
		Event ev = { EventNone };
		if (need_paint) {
			ui_paint(&g_app.ui);
			need_paint = false;
			/* Drain keys that arrived during paint (jem harvest pattern). */
			for (;;) {
				auto (key, ok) = term_try_read_key(0);
				if (!ok) {
					break;
				}
				event_enqueue(event_key(key));
			}
		}
		while (event_try_dequeue(&ev)) {
			handle_event(&ev);
			event_free(&ev);
			need_paint = true;
			if (!g_app.running) {
				break;
			}
		}
		if (!g_app.running) {
			break;
		}
		if (need_paint) {
			continue;
		}
		if (maybe_reload_db()) {
			need_paint = true;
			continue;
		}
		/* Proactive resize: jem paints every tick and catches size via ioctl in
		 * display_update. We only paint on demand, so poll size here — many
		 * hosts never send a resize CSI (or only after the next key). */
		if (term_refresh_size()) {
			screen_ensure_size();
			screen_invalidate();
			need_paint = true;
			continue;
		}
		{
			/* Resize CSI enqueues EventResize with no key; jem continues when
			 * the queue is non-empty so those events are not stranded. */
			auto (key, ok) = term_try_read_key(100);
			if (ok) {
				event_enqueue(event_key(key));
			}
			if (ok || event_queue_len() > 0) {
				continue;
			}
		}
	}
	if (g_app.store.dirty) {
		if (!save_db()) {
			return 1;
		}
	}
	return 0;
}
