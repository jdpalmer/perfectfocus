// ui — planner paint: filters, table, footer.
import "model";
import "screen";
import "style";
import "term";
import "str";
import "utf8";

#include <stdio.h>
#include <string.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum {
	UiColHeaderRow = 0,
	UiFooterRows = 1,
	/* Room for "title #tags" when editing. */
	UiInputCap = TaskTitleCap + TaskTagsCap + 2
};

/* Root VERSION (no Make step); trailing newline stripped at display time. */
const char[..] app_version =
#embed "../VERSION"
;

struct UiState {
	TaskStore* store;
	ViewFilter* filter;
	int[..] visible;
	int visible_count;
	int selected;
	/* index into visible[] */
	int scroll;
	char mode_line[160];
	char prompt[80];
	char input[UiInputCap];
	int input_len;
	int input_cursor;
	/* caret within input[0..input_len] */
	bool editing;
	bool edit_cancelled;
	/* true when Esc / C-g finished the prompt */
};

void ui_init(UiState* ui, TaskStore* store, ViewFilter* filter, int[..] visible) {
	if (ui == NULL) {
		return;
	}
	memset(ui, 0, sizeof(*ui));
	ui.store = store;
	ui.filter = filter;
	ui.visible = visible;
	ui.selected = 0;
	ui.scroll = 0;
	ui.mode_line[0] = 0;
}

void ui_set_status(UiState* ui, const char[..] msg) {
	if (ui == NULL) {
		return;
	}
	(void)cstr_write(ranged(ui.mode_line, sizeof(ui.mode_line)), msg);
}

/* Fill [col, col+width) with UTF-8 text by display columns; pad with spaces. */
static void put_clipped(int row, int col, int width, const char[..] text, TextStyle st) {
	int filled = 0;
	size_t i = 0;
	if (width <= 0) {
		return;
	}
	while (i < len(text) && filled < width) {
		auto (r, sz) = text.decode_rune(i);
		int w = 0;
		if (sz == 0) {
			break;
		}
		w = rune_display_width(r);
		if (w <= 0) {
			w = 1;
		}
		if (filled + w > width) {
			break;
		}
		screen_put_rune(row, col + filled, r, st);
		for (int k = 1; k < w; k++) {
			screen_put_rune(row, col + filled + k, 0, st);
		}
		filled += w;
		i += sz;
	}
	while (filled < width) {
		screen_put_rune(row, col + filled, (uint32_t)' ', st);
		filled++;
	}
}

/* Paint one rune at display column; pads wide glyphs. Advances *filled. */
static void put_rune_cols(int row, int col, int width, int* filled, uint32_t r, TextStyle st) {
	int w = rune_display_width(r);
	if (filled == NULL || *filled >= width) {
		return;
	}
	if (w <= 0) {
		w = 1;
	}
	if (*filled + w > width) {
		return;
	}
	screen_put_rune(row, col + *filled, r, st);
	for (int k = 1; k < w; k++) {
		screen_put_rune(row, col + *filled + k, 0, st);
	}
	*filled += w;
}

/* Paint label with mnemonic letter in blue+bold (same bg). */
static void put_mnemonic(int row, int col, int width, const char[..] text, char mnemonic, TextStyle st) {
	int marked_col = -1;
	char want = mnemonic;
	TextStyle hot = text_style_make(TermColorBlue, text_style_bg(st), TextStyleBold);
	int filled = 0;
	size_t i = 0;
	if (width <= 0) {
		return;
	}
	if (want >= 'A' && want <= 'Z') {
		want = (char)(want - 'A' + 'a');
	}
	{
		int dcol = 0;
		size_t at = 0;
		while (at < len(text)) {
			auto (r, sz) = text.decode_rune(at);
			int w = 0;
			if (sz == 0) {
				break;
			}
			w = rune_display_width(r);
			if (w <= 0) {
				w = 1;
			}
			if (marked_col < 0 && r < 128) {
				char low = (char)r;
				if (low >= 'A' && low <= 'Z') {
					low = (char)(low - 'A' + 'a');
				}
				if (low == want) {
					marked_col = dcol;
				}
			}
			dcol += w;
			at += sz;
		}
	}
	while (i < len(text) && filled < width) {
		auto (r, sz) = text.decode_rune(i);
		int w = 0;
		TextStyle use = st;
		if (sz == 0) {
			break;
		}
		w = rune_display_width(r);
		if (w <= 0) {
			w = 1;
		}
		if (filled + w > width) {
			break;
		}
		if (filled == marked_col) {
			use = hot;
		}
		put_rune_cols(row, col, width, &filled, r, use);
		i += sz;
	}
	while (filled < width) {
		screen_put_rune(row, col + filled, (uint32_t)' ', st);
		filled++;
	}
}

static int table_top() {
	return UiColHeaderRow + 1;
}

static int table_height(int rows) {
	int h = rows - table_top() - UiFooterRows;
	if (h < 3) {
		h = 3;
	}
	return h;
}

int ui_page_rows() {
	return table_height(screen_rows());
}

void ui_clamp(UiState* ui) {
	if (ui == NULL) {
		return;
	}
	if (ui.visible_count <= 0) {
		ui.selected = 0;
		ui.scroll = 0;
		return;
	}
	if (ui.selected < 0) {
		ui.selected = 0;
	}
	if (ui.selected >= ui.visible_count) {
		ui.selected = ui.visible_count - 1;
	}
	int th = table_height(screen_rows());
	if (ui.selected < ui.scroll) {
		ui.scroll = ui.selected;
	}
	if (ui.selected >= ui.scroll + th) {
		ui.scroll = ui.selected - th + 1;
	}
	if (ui.scroll < 0) {
		ui.scroll = 0;
	}
}

Task* ui_selected_task(UiState* ui) {
	if (ui == NULL || ui.store == NULL || ptr(ui.visible) == NULL) {
		return NULL;
	}
	if (ui.visible_count <= 0 || ui.selected < 0 || ui.selected >= ui.visible_count) {
		return NULL;
	}
	int idx = ui.visible[ui.selected];
	return ui.store.get(idx);
}

int ui_selected_store_index(UiState* ui) {
	if (ui == NULL || ptr(ui.visible) == NULL) {
		return -1;
	}
	if (ui.visible_count <= 0 || ui.selected < 0 || ui.selected >= ui.visible_count) {
		return -1;
	}
	return ui.visible[ui.selected];
}

static void col_widths(int cols, int* w_status, int* w_task, int* w_cc) {
	/* Status vocab is short (A:Inbox … G:Someday); keep title room. */
	int status = 10;
	int cc = 16;
	int gaps = 2;
	int task = cols - status - cc - gaps;
	if (task < 16) {
		cc = 12;
		task = cols - status - cc - gaps;
	}
	if (task < 12) {
		task = 12;
	}
	*w_status = status;
	*w_task = task;
	*w_cc = cc;
}

static void paint_col_header(int cols) {
	TextStyle st = screen_style_header();
	int w_status = 0;
	int w_task = 0;
	int w_cc = 0;
	int c = 0;
	col_widths(cols, &w_status, &w_task, &w_cc);
	screen_fill_row(UiColHeaderRow, st);
	put_mnemonic(UiColHeaderRow, c, w_status, "Status", 's', st);
	c += w_status + 1;
	/* Attn before Task — who, then what. */
	put_mnemonic(UiColHeaderRow, c, w_cc, "Attn", 'a', st);
	c += w_cc + 1;
	put_mnemonic(UiColHeaderRow, c, w_task, "Task", 't', st);
}

/* Paint one task through const Task* (status / attn / title+#tags). */
static void paint_task_row(int screen_row, int c, int w_status, int w_cc, int w_task, const Task* t, TextStyle st, bool selected, bool done) {
	char letter = ' ';
	if (t == NULL) {
		return;
	}
	if (len(t.status) > 0) {
		letter = t.status[0];
	}
	{
		TextStyle sst = st;
		if (!selected && !done) {
			sst = screen_style_status(letter);
		}
		put_clipped(screen_row, c, w_status, t.status, sst);
	}
	c += w_status + 1;
	{
		const char[..] attn = len(t.cc) == 0 ? str_from_cstr("-"): t.cc;
		TextStyle attn_st = st;
		if (len(t.cc) == 0) {
			TermColor bg = text_style_bg(st);
			if (str_eq_cstr(t.status, "E:Waiting")) {
				attn_st = text_style_make(TermColorRed, bg, TextStyleBold);
			} else {
				attn_st = text_style_make(TermColorBase01, bg, 0);
			}
		}
		put_clipped(screen_row, c, w_cc, attn, attn_st);
	}
	c += w_cc + 1;
	{
		TermColor bg = text_style_bg(st);
		TextStyle tag_st = text_style_make(TermColorBase01, bg, 0);
		int filled = 0;
		size_t i = 0;
		while (i < len(t.title) && filled < w_task) {
			auto (r, sz) = t.title.decode_rune(i);
			int before = filled;
			if (sz == 0) {
				break;
			}
			put_rune_cols(screen_row, c, w_task, &filled, r, st);
			if (filled == before) {
				break;
			}
			i += sz;
		}
		if (len(t.title) > 0 && len(t.tags) > 0) {
			int gap = 2;
			while (gap > 0 && filled < w_task) {
				screen_put_rune(screen_row, c + filled, (uint32_t)' ', st);
				filled++;
				gap--;
			}
		}
		i = 0;
		while (i < len(t.tags) && filled < w_task) {
			auto (r, sz) = t.tags.decode_rune(i);
			int before = filled;
			if (sz == 0) {
				break;
			}
			put_rune_cols(screen_row, c, w_task, &filled, r, tag_st);
			if (filled == before) {
				break;
			}
			i += sz;
		}
		while (filled < w_task) {
			screen_put_rune(screen_row, c + filled, (uint32_t)' ', st);
			filled++;
		}
	}
}

static void paint_table(UiState* ui, int cols) {
	int top = table_top();
	int th = table_height(screen_rows());
	int row = 0;
	int w_status = 0;
	int w_task = 0;
	int w_cc = 0;
	TextStyle def = screen_style_default();
	col_widths(cols, &w_status, &w_task, &w_cc);
	for (; row < th; row++) {
		int vi = ui.scroll + row;
		int screen_row = top + row;
		TextStyle st = def;
		Task* t = NULL;
		screen_fill_row(screen_row, def);
		if (vi < 0 || vi >= ui.visible_count) {
			continue;
		}
		t = ui.store.get(ui.visible[vi]);
		if (t == NULL) {
			continue;
		}
		bool done = str_eq_cstr(t.status, "F:Complete");
		bool selected = vi == ui.selected;
		if (selected) {
			st = screen_style_selected();
			screen_fill_row(screen_row, st);
		} else if (done) {
			/* Whole-row dim so open tasks pop when +C is on. */
			st = text_style_make(TermColorBase01, TermColorBase03, 0);
			screen_fill_row(screen_row, st);
		}
		paint_task_row(screen_row, 0, w_status, w_cc, w_task, t, st, selected, done);
	}
}

static int count_status(const TaskStore* store, const char[..] status) {
	int n = 0;
	if (store == NULL || store.count <= 0) {
		return 0;
	}
	for (auto t: store.tasks[0 ..(size_t)store.count]) {
		if (t.status.eq(status)) {
			n++;
		}
	}
	return n;
}

/* Blue single-key glyph (narrow footer fallback). */
static void put_hot_key(int row, int col, char key, TextStyle st) {
	TextStyle hot = text_style_make(TermColorBlue, text_style_bg(st), TextStyleBold);
	screen_put_rune(row, col, key, hot);
}

static int footer_hints_width(bool focus_on, bool find_on, bool compact) {
	if (compact) {
		return (int)strlen("n f / o d x X q");
	}
	/* focus(5) vs unfocus(7); /find vs /clear same width */
	(void)find_on;
	int f_len = focus_on ? 7: 5;
	/* new + focus|unfocus + /find + sort + del + xdone + Xall + quit + gaps */
	return 3 + 1 + f_len + 1 + 5 + 1 + 4 + 1 + 3 + 1 + 5 + 1 + 4 + 1 + 4;
}

static void paint_footer_hints(int row, int col, TextStyle st, bool focus_on, bool find_on, bool compact) {
	if (compact) {
		char keys[] = "n f / o d x X q";
		const char[..] keyv = ranged(keys, sizeof(keys) - 1);
		int i = 0;
		for (auto ch: keyv) {
			if (ch == ' ') {
				screen_put_rune(row, col + i, (uint32_t)' ', st);
			} else {
				put_hot_key(row, col + i, ch, st);
			}
			i++;
		}
		return;
	}
	const char* focus_lab = focus_on ? "unfocus": "focus";
	const char* find_lab = find_on ? "/clear": "/find";
	const char* labs[] = {
		"new", focus_lab, find_lab, "sort", "del", "xdone", "Xall", "quit" };
	char mnems[] = {
		'n', 'f', '/', 'o', 'd', 'x', 'X', 'q' };
	int c = col;
	for (int i = 0; i < 8; i++) {
		int w = (int)strlen(labs[i]);
		if (i > 0) {
			screen_put_rune(row, c, (uint32_t)' ', st);
			c++;
		}
		put_mnemonic(row, c, w, ranged(labs[i], strlen(labs[i])), mnems[i], st);
		c += w;
	}
}

enum { NowSoftCap = 7 };

static void paint_footer(UiState* ui, int cols) {
	int row = screen_rows() - 1;
	TextStyle st = screen_style_header();
	TextStyle a_hot = text_style_make(TermColorRed, text_style_bg(st), TextStyleBold);
	char pre[64] = { 0 };
	char a_bit[48] = { 0 };
	char rest[192] = { 0 };
	char line[512] = { 0 };
	int total = ui.store != NULL ? ui.store.count: 0;
	int b_now = count_status(ui.store, "B:Now");
	bool focus_on = ui.filter != NULL && len(ui.filter.cc) != 0;
	bool tag_on = ui.filter != NULL && len(ui.filter.tag) != 0;
	bool status_on = ui.filter != NULL && len(ui.filter.status) != 0;
	bool find_on = ui.filter != NULL && len(ui.filter.text) != 0;
	bool a_over = b_now > NowSoftCap;
	bool compact = false;
	int rn = 0;
	screen_fill_row(row, st);
	if (ui.editing) {
		snprintf(line, sizeof(line), " %s%s", ui.prompt, ui.input);
		put_clipped(row, 0, cols, ranged(line, strlen(line)), st);
		return;
	}
	{
		const char[..] ver = app_version;
		size_t vlen = len(ver);
		while (vlen > 0 && (ver[vlen - 1] == '\n' || ver[vlen - 1] == '\r')) {
			vlen--;
		}
		snprintf(pre, sizeof(pre), "ModFocus %.*s %d/%d ", (int)vlen, ptr(ver), ui.visible_count, total);
	}
	if (a_over) {
		snprintf(a_bit, sizeof(a_bit), "B:%d:demote?", b_now);
	} else {
		snprintf(a_bit, sizeof(a_bit), "B:%d", b_now);
	}
	if (ui.filter != NULL) {
		if (focus_on && rn < (int) sizeof(rest)) {
			/* Mirror #tag: @ on each Attn name ("Brian, Jessica" → "@Brian, @Jessica"). */
			char atbuf[160] = { 0 };
			size_t ai = 0;
			size_t ao = 0;
			const char[..] cc = ui.filter.cc;
			while (ai < len(cc) && ao + 2 < sizeof(atbuf)) {
				size_t start = 0;
				size_t end = 0;
				while (ai < len(cc) && (cc[ai] == ' ' || cc[ai] == '\t')) {
					ai++;
				}
				start = ai;
				while (ai < len(cc) && cc[ai] != ',') {
					ai++;
				}
				end = ai;
				while (end > start && (cc[end - 1] == ' ' || cc[end - 1] == '\t')) {
					end--;
				}
				if (end > start) {
					size_t n = end - start;
					if (ao > 0) {
						if (ao + 2 >= sizeof(atbuf)) {
							break;
						}
						atbuf[ao++] = ',';
						atbuf[ao++] = ' ';
					}
					if (ao + 1 + n >= sizeof(atbuf)) {
						break;
					}
					atbuf[ao++] = '@';
					memcpy(atbuf + ao, ptr(cc) + start, n);
					ao += n;
					atbuf[ao] = 0;
				}
				if (ai < len(cc) && cc[ai] == ',') {
					ai++;
				}
			}
			if (ao > 0) {
				rn += snprintf(rest + rn, sizeof(rest) - (size_t)rn, " %s", atbuf);
			}
		}
		if (tag_on && rn < (int) sizeof(rest)) {
			const char[..] tg = ui.filter.tag;
			if (len(tg) > 0 && tg[0] == '#') {
				rn += snprintf(rest + rn, sizeof(rest) - (size_t)rn, " %.*s", (int)len(tg), ptr(tg));
			} else {
				rn += snprintf(rest + rn, sizeof(rest) - (size_t)rn, " #%.*s", (int)len(tg), ptr(tg));
			}
		}
		if (status_on && rn < (int) sizeof(rest)) {
			const char[..] stf = ui.filter.status;
			rn += snprintf(rest + rn, sizeof(rest) - (size_t)rn, " :%.*s", (int)len(stf), ptr(stf));
		}
		if (ui.filter.show_complete && rn < (int) sizeof(rest)) {
			rn += snprintf(rest + rn, sizeof(rest) - (size_t)rn, " +C");
		}
		if (find_on && rn < (int) sizeof(rest)) {
			rn += snprintf(rest + rn, sizeof(rest) - (size_t)rn, " /%.*s", (int)len(ui.filter.text), ptr(ui.filter.text));
		}
	}
	if (strlen(ui.mode_line) != 0 && rn < (int) sizeof(rest)) {
		rn += snprintf(rest + rn, sizeof(rest) - (size_t)rn, " %s", ui.mode_line);
	}
	(void)rn;
	int right_cols = footer_hints_width(focus_on || status_on || tag_on, find_on, false) + 1;
	if (cols - right_cols < 12) {
		compact = true;
		right_cols = footer_hints_width(focus_on || status_on || tag_on, find_on, true) + 1;
	}
	int left_cols = cols - right_cols;
	if (left_cols < 8) {
		left_cols = cols;
		right_cols = 0;
	}
	{
		int c = 0;
		int pre_w = (int)strlen(pre);
		int a_w = (int)strlen(a_bit);
		int rest_w = (int)strlen(rest);
		put_clipped(row, c, 1, " ", st);
		c = 1;
		if (c < left_cols && pre_w > 0) {
			int w = pre_w;
			if (c + w > left_cols) {
				w = left_cols - c;
			}
			put_clipped(row, c, w, ranged(pre, (size_t)pre_w), st);
			c += w;
		}
		if (c < left_cols && a_w > 0) {
			int w = a_w;
			if (c + w > left_cols) {
				w = left_cols - c;
			}
			put_clipped(row, c, w, ranged(a_bit, (size_t)a_w), a_over ? a_hot: st);
			c += w;
		}
		if (c < left_cols && rest_w > 0) {
			int w = rest_w;
			if (c + w > left_cols) {
				w = left_cols - c;
			}
			put_clipped(row, c, w, ranged(rest, (size_t)rest_w), st);
			c += w;
		}
		if (c < left_cols) {
			put_clipped(row, c, left_cols - c, "", st);
		}
	}
	if (right_cols > 0) {
		int c = cols - (right_cols - 1);
		if (c < left_cols) {
			c = left_cols;
		}
		paint_footer_hints(row, c, st, focus_on || status_on || tag_on, find_on, compact);
	}
}

void ui_paint(UiState* ui) {
	if (ui == NULL) {
		return;
	}
	/* jem display_update: refresh size every paint so resize is not only
	 * dependent on a CSI event being dequeued. */
	if (term_refresh_size()) {
		screen_invalidate();
	}
	screen_ensure_size();
	int cols = screen_cols();
	ui_clamp(ui);
	/* Overwrite cells only — do not clear. put_rune + screen_sync emit diffs
	 * (jem display lesson); a full clear dirties every row each frame. */
	paint_col_header(cols);
	paint_table(ui, cols);
	paint_footer(ui, cols);
	if (ui.editing) {
		int cursor_row = screen_rows() - 1;
		int cursor_col = 1;
		cursor_col += ranged(ui.prompt, strlen(ui.prompt)).prefix_cols(strlen(ui.prompt));
		cursor_col += ranged(ui.input, ui.input_len).prefix_cols(ui.input_cursor);
		if (cursor_col >= cols) {
			cursor_col = cols - 1;
		}
		if (cursor_col < 0) {
			cursor_col = 0;
		}
		screen_present(cursor_row, cursor_col);
	} else {
		int cursor_row = table_top() + (ui.selected - ui.scroll);
		screen_present(cursor_row, 0);
	}
}

void ui_begin_edit(UiState* ui, const char[..] prompt, const char[..] initial) {
	if (ui == NULL) {
		return;
	}
	ui.editing = true;
	ui.edit_cancelled = false;
	(void)cstr_write(ranged(ui.prompt, sizeof(ui.prompt)), prompt);
	(void)cstr_write(ranged(ui.input, sizeof(ui.input)), initial);
	ui.input_len = (int)cstr_zlen(ranged(ui.input, sizeof(ui.input)));
	ui.input_cursor = ui.input_len;
}

void ui_end_edit(UiState* ui) {
	if (ui == NULL) {
		return;
	}
	ui.editing = false;
	ui.edit_cancelled = false;
	ui.prompt[0] = 0;
	ui.input[0] = 0;
	ui.input_len = 0;
	ui.input_cursor = 0;
}

static void edit_clamp_cursor(UiState* ui) {
	if (ui.input_cursor < 0) {
		ui.input_cursor = 0;
	}
	if (ui.input_cursor > ui.input_len) {
		ui.input_cursor = ui.input_len;
	}
}

static bool key_is_ctl(uint32_t key, char letter) {
	uint32_t want = (uint32_t)TermCTL | (uint32_t)letter;
	if (key == want) {
		return true;
	}
	/* Raw C0 controls: C-a = 0x01 … C-z = 0x1A */
	if (letter >= 'A' && letter <= 'Z' && key == (uint32_t)(letter - '@')) {
		return true;
	}
	if (letter >= 'a' && letter <= 'z' && key == (uint32_t)(letter - 'a' + 1)) {
		return true;
	}
	return false;
}

bool ui_edit_handle_key(UiState* ui, uint32_t key) {
	if (ui == NULL || !ui.editing) {
		return false;
	}
	if (key == (uint32_t)TermKeyEnter || key == '\r' || key == '\n' || key_is_ctl(key, 'M') || key_is_ctl(key, 'J')) {
		ui.edit_cancelled = false;
		return true;
		/* accept */
	}
	if (key == 0x1B || key_is_ctl(key, 'G')) {
		/* escape / C-g cancel */
		ui.edit_cancelled = true;
		return true;
	}
	/* Motion — jem/emacs style, by UTF-8 rune */
	{
		const char[..] line = ranged(ui.input, ui.input_len);
		if (key == (uint32_t)TermKeyLeft || key_is_ctl(key, 'B')) {
			if (ui.input_cursor > 0) {
				ui.input_cursor = (int)line.prev_offset(ui.input_cursor);
			}
			return false;
		}
		if (key == (uint32_t)TermKeyRight || key_is_ctl(key, 'F')) {
			if (ui.input_cursor < ui.input_len) {
				ui.input_cursor = (int)line.next_offset(ui.input_cursor);
			}
			return false;
		}
	}
	if (key == (uint32_t)TermKeyHome || key_is_ctl(key, 'A')) {
		ui.input_cursor = 0;
		return false;
	}
	if (key == (uint32_t)TermKeyEnd || key_is_ctl(key, 'E')) {
		ui.input_cursor = ui.input_len;
		return false;
	}
	/* Deletion */
	if (key == 127 || key == 8 || key_is_ctl(key, 'H')) {
		/* backspace one rune */
		if (ui.input_cursor > 0) {
			const char[..] line = ranged(ui.input, ui.input_len);
			int start = (int)line.prev_offset(ui.input_cursor);
			int del = ui.input_cursor - start;
			memmove(ui.input + start, ui.input + ui.input_cursor, ui.input_len - ui.input_cursor + 1);
			ui.input_len -= del;
			ui.input_cursor = start;
			ui.input[ui.input_len] = 0;
		}
		return false;
	}
	if (key == (uint32_t)TermKeyDelete || key_is_ctl(key, 'D')) {
		if (ui.input_cursor < ui.input_len) {
			const char[..] line = ranged(ui.input, ui.input_len);
			int end = (int)line.next_offset(ui.input_cursor);
			int del = end - ui.input_cursor;
			memmove(ui.input + ui.input_cursor, ui.input + end, ui.input_len - end + 1);
			ui.input_len -= del;
			ui.input[ui.input_len] = 0;
		}
		return false;
	}
	if (key_is_ctl(key, 'K')) {
		/* kill to end of line */
		ui.input[ui.input_cursor] = 0;
		ui.input_len = ui.input_cursor;
		return false;
	}
	if (key_is_ctl(key, 'U')) {
		/* kill whole line */
		ui.input[0] = 0;
		ui.input_len = 0;
		ui.input_cursor = 0;
		return false;
	}
	/* Insert printable rune at caret (ASCII or Unicode). */
	if ((key >= 32 && key < 0x7F) || (key >= 0xA0 && key < 0x110000)) {
		char bytes[4] = { 0 };
		size_t nbytes = utf8_encode_rune(key, ranged(bytes, sizeof(bytes)));
		if (nbytes > 0 && ui.input_len + (int)nbytes < (int)sizeof(ui.input)) {
			int i = ui.input_cursor;
			memmove(ui.input + i + (int)nbytes, ui.input + i, ui.input_len - i + 1);
			memcpy(ui.input + i, bytes, nbytes);
			ui.input_len += (int)nbytes;
			ui.input_cursor += (int)nbytes;
			edit_clamp_cursor(ui);
		}
		return false;
	}
	return false;
}
