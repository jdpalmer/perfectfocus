// json/util.mc — buffers, number scan (package-private).
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

struct JsonScanner {
	const char *p;
};

static bool json_byte_digit(char c) {
	return c >= '0' && c <= '9';
}

static bool json_is_number_char(char c) {
	return json_byte_digit(c) || c == '.' || c == '+' || c == '-' ||
		c == 'e' || c == 'E';
}

/* JSON-style double scan (jem.c util_scan scan_double); no __builtin overflow. */
static bool json_scan_double(JsonScanner *s, double *out) {
	double sign = 1.0;
	uint64_t significand = 0;
	int32_t exponent_offset = 0;
	bool has_digits = false;
	int32_t i = 0;

	if (s == NULL || s.p == NULL || out == NULL) {
		return false;
	}
	const char *p = s.p;
	if (*p == '-') {
		sign = -1.0;
		p++;
	}
	if (!json_byte_digit(*p)) {
		return false;
	}
	while (json_byte_digit(*p)) {
		uint64_t digit = *p - '0';
		if (significand > (((uint64_t)0 - 1) / 10)) {
			return false;
		}
		significand = significand * 10;
		if (significand > (((uint64_t)0 - 1) - digit)) {
			return false;
		}
		significand = significand + digit;
		has_digits = true;
		p++;
	}
	if (*p == '.') {
		p++;
		if (!json_byte_digit(*p)) {
			return false;
		}
		while (json_byte_digit(*p)) {
			uint64_t digit = *p - '0';
			if (significand > (((uint64_t)0 - 1) / 10)) {
				return false;
			}
			significand = significand * 10;
			if (significand > (((uint64_t)0 - 1) - digit)) {
				return false;
			}
			significand = significand + digit;
			exponent_offset--;
			p++;
		}
	}
	if (*p == 'e' || *p == 'E') {
		int32_t exp_sign = 1;
		int32_t parsed_exp = 0;
		p++;
		if (*p == '-') {
			exp_sign = -1;
			p++;
		} else if (*p == '+') {
			p++;
		}
		if (!json_byte_digit(*p)) {
			return false;
		}
		while (json_byte_digit(*p)) {
			int32_t digit = *p - '0';
			if (parsed_exp > (2147483647 / 10)) {
				return false;
			}
			parsed_exp = parsed_exp * 10 + digit;
			p++;
		}
		exponent_offset = exponent_offset + (parsed_exp * exp_sign);
	}
	if (!has_digits) {
		return false;
	}
	*out = sign * (double)significand * pow(10.0, exponent_offset);
	s.p = p;
	(void)i;
	return true;
}

/* Ensure capacity for a trailing NUL without growing len (C-boundary handoff). */
static bool json_ensure_cstr(char[..] *s) {
	if (s == NULL) {
		return false;
	}
	size_t n = len(*s);
	if (!str_reserve(s, n + 1)) {
		return false;
	}
	{
		char[..] z = ranged(ptr(*s), n + 1, cap(*s));
		z[n] = 0;
	}
	return true;
}

static bool json_buffer_append_char(char[..] *buffer, char c) {
	if (buffer == NULL) {
		return false;
	}
	return str_append_byte(buffer, c);
}

static bool json_buffer_append_bytes(char[..] *buffer, const char *bytes, size_t nbytes) {
	if (buffer == NULL) {
		return false;
	}
	if (bytes == NULL && nbytes != 0) {
		return false;
	}
	if (nbytes == 0) {
		return true;
	}
	return str_append(buffer, ranged(bytes, nbytes));
}

static bool json_buffer_append_number(char[..] *buffer, double number) {
	char stack_buf[64] = {0};

	if (buffer == NULL) {
		return false;
	}
	int written = snprintf(stack_buf, sizeof(stack_buf), "%.17g", number);
	if (written < 0) {
		return false;
	}
	if ((size_t)written < sizeof(stack_buf)) {
		return json_buffer_append_bytes(buffer, stack_buf, written);
	}
	char[..] heap = {0};
	if (!str_reserve(&heap, (size_t)written + 1)) {
		return false;
	}
	written = snprintf(ptr(heap), (size_t)written + 1, "%.17g", number);
	if (written < 0) {
		str_free(&heap);
		return false;
	}
	heap = ranged(ptr(heap), (size_t)written, cap(heap));
	bool ok = str_append(buffer, heap);
	str_free(&heap);
	return ok;
}

static void json_buffer_discard(char[..] *buffer) {
	if (buffer == NULL) {
		return;
	}
	str_free(buffer);
}

/* Copy bytes into an owned slice and reserve a trailing NUL for C APIs. */
static bool json_dup_bytes(char[..] *dst, const char *src, size_t nbytes) {
	if (dst == NULL) {
		return false;
	}
	if (src == NULL && nbytes != 0) {
		return false;
	}
	*dst = str_empty();
	if (nbytes != 0) {
		if (!str_append(dst, ranged(src, nbytes))) {
			str_free(dst);
			return false;
		}
	}
	if (!json_ensure_cstr(dst)) {
		str_free(dst);
		return false;
	}
	return true;
}

static char json_hex_digit(unsigned int value) {
	if (value < 10) {
		return (char)('0' + value);
	}
	return (char)('a' + value - 10);
}
