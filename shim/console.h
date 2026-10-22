#pragma once
#include <stdint.h>

/* Defaults are the spes/topaz 1080x2400 splash; build.sh overrides them from
 * SHIM_FB_BASE/SHIM_FB_W/SHIM_FB_H for other panels (fog: 720x1650). */
#ifndef FB_BASE
#define FB_BASE		0x5c000000UL	/* reserved-memory cont_splash_region */
#endif
#ifndef FB_W
#define FB_W		1080
#endif
#ifndef FB_H
#define FB_H		2400
#endif
#ifndef FB_STRIDE
#define FB_STRIDE	(FB_W * 4)	/* a8r8g8b8, matches mainline simplefb */
#endif

#define RED	0xffff0000U
#define BLUE	0xff0000a0U
#define WHITE	0xffffffffU
#define YELLOW	0xffffff00U
#define GREEN	0xff00ff00U

extern volatile uint32_t *con_fb;

void con_clear(uint32_t bg);
void con_skip(void);
void con_str(const char *label, const char *s);
void con_hex(const char *label, uint64_t v);
/* label, then "a=xxxxxxxx b=xxxxxxxx" style pairs of 32-bit values */
void con_hex2(const char *label, const char *a, uint32_t va, const char *b, uint32_t vb);
