/*
 * Test for omacvm-cocoa-present-direct.patch: a frame of the guest's own
 * IOSurface (a direct frame) that the vsync queue skips gives the buffer back
 * at once, also with the tiled present on.
 *
 * test-present-direct.sh takes PresentFrame and the queue's skip code
 * (present_frame_put, present_frame_absorb, present_pend, present_frame_skip)
 * from a ui/cocoa.m and builds them here with the tiled present's rules
 * (ui/omacvm-present-tiles.h) and stand-ins for IOSurfaces that count their
 * use. After a tick, the direct present sends the guest's buffer again only
 * when nothing uses it (IOSurfaceGetUseCount in cocoa_gl_present), so a skipped
 * direct frame must leave its buffer's use at 0. A drawn whole frame that is
 * skipped with nothing queued after it waits in present_pend: the next tile
 * frame lies over it (test-present-skip.sh tests the rest of its way). No QEMU,
 * no GL, no display.
 *
 *   cc -DHAVE_DIRECT=0|1 -IDIR test-present-direct.c -o t && ./t
 *   DIR holds omacvm-present-tiles.h and present-frames.inc; HAVE_DIRECT=0 for
 *   code before the patch, which has no PresentFrame.direct (the sh wants it to fail).
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef int GLint;
#define GL_NEAREST 0x2600

/* An IOSurface: its use count (IOSurfaceIncrementUseCount) and references (CFRetain). */
typedef struct Surface {
    int use, refs;
} *IOSurfaceRef;

/* as cocoa.m's surface_put: IOSurfaceDecrementUseCount, CFRelease */
static void surface_put(IOSurfaceRef s)
{
    s->use--;
    s->refs--;
}
static void g_free(void *p) { free(p); }
static int present_tiles_on;

#include "omacvm-present-tiles.h"
#include "present-frames.inc"

static int fails;
static void check(const char *what, bool ok)
{
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    fails += !ok;
}

/* A frame as cocoa_gl_present_send queues it: the surface retained and in use. */
static PresentFrame frame(struct Surface *s, bool direct)
{
    s->use++;
    s->refs++;
    PresentFrame f = { .surf = s, .filter = GL_NEAREST };
#if HAVE_DIRECT
    f.direct = direct;
#else
    (void)direct;
#endif
    return f;
}

static bool free_again(const struct Surface *s) { return s->use == 0 && s->refs == 0; }
static bool pend_empty(void) { return !present_pend.surf && !present_pend.pt; }

int main(void)
{
    struct Surface guest = { 0 }, drawn = { 0 };

    /* The trim after a tick skips the last frame of a scroll: nothing is queued after it. */
    present_tiles_on = 1;
    PresentFrame f = frame(&guest, true);
    present_frame_skip(&f, NULL);
    check("tiles on: a direct frame skipped with none after it gives the guest's buffer back",
          free_again(&guest));
    check("tiles on: ... and does not wait in present_pend", pend_empty());
    present_frame_put(&present_pend);

    /* A drop or a merge with a newer frame queued. */
    guest = (struct Surface){ 0 };
    drawn = (struct Surface){ 0 };
    f = frame(&guest, true);
    PresentFrame next = frame(&drawn, false);
    present_frame_skip(&f, &next);
    check("tiles on: a direct frame skipped before a newer one gives the guest's buffer back",
          free_again(&guest) && next.surf == &drawn && drawn.use == 1);
    present_frame_put(&next);

    /* A drawn whole frame skipped with none after it: the next tile frame lies over it. */
    drawn = (struct Surface){ 0 };
    PresentFrame w = frame(&drawn, false);
    present_frame_skip(&w, NULL);
    check("tiles on: a drawn whole frame skipped with none after it waits in present_pend",
          present_pend.surf == &drawn && drawn.use == 1);
    PresentFrame t = { .filter = GL_NEAREST, .pt = calloc(1, sizeof(OmacvmPTFrame)) };
    present_frame_absorb(&t, &present_pend);
    check("tiles on: ... and the next tile frame takes it as its whole frame",
          t.pt->base == &drawn && drawn.use == 1 && pend_empty());
    present_frame_put(&t);
    check("tiles on: ... which gives it back once shown", free_again(&drawn));

    /* Without the tiled present too. */
    present_tiles_on = 0;
    guest = (struct Surface){ 0 };
    f = frame(&guest, true);
    present_frame_skip(&f, NULL);
    check("tiles off: a direct frame skipped gives the guest's buffer back",
          !present_tiles_on && free_again(&guest) && pend_empty());

    printf("%s\n", fails ? "test-present-direct: FAIL" : "test-present-direct: all ok");
    return fails != 0;
}
