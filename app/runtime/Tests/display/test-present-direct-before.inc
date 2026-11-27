/* test-present-direct.sh --self-test: PresentFrame and the vsync queue skip code of ui/cocoa.m as main had them before the fix (a direct frame skipped with tiles on waited in present_pend). Not used by QEMU. */
typedef struct PresentFrame {
    IOSurfaceRef surf;
    GLint filter;
    double flushed;                     /* reached QEMU's present */
    bool linear;                        /* drawn in linear light (extra brightness) */
    OmacvmPTFrame *pt;                  /* tiled present: tile updates (surf NULL) */
} PresentFrame;
static void present_frame_put(PresentFrame *f)
{
    if (f->surf) {
        surface_put(f->surf);
    }
    if (f->pt) {
        if (f->pt->base) {
            surface_put(f->pt->base);
        }
        for (unsigned i = 0; i < f->pt->n; i++) {
            surface_put(f->pt->up[i].buf);
        }
        g_free(f->pt);
    }
    *f = (PresentFrame){ 0 };
}
static void present_frame_absorb(PresentFrame *newer, PresentFrame *older)
{
    if (!older->surf && !older->pt) {
        return;
    }
    if (!newer->pt) {
        present_frame_put(older);
        return;
    }
    OmacvmPTFrame whole = { .base = older->surf };
    OmacvmPTFrame *o = older->pt ? older->pt : &whole;
    bool had_base = newer->pt->base != NULL;
    void *freed[OMACVM_PT_MAX + 1];
    unsigned nf = omacvm_pt_absorb(newer->pt, o, freed);
    for (unsigned i = 0; i < nf; i++) {
        surface_put(freed[i]);
    }
    if (!had_base && newer->pt->base) {
        /* the whole frame is shown as OLDER would have shown it */
        newer->filter = older->filter;
        newer->linear = older->linear;
    }
    g_free(older->pt);
    *older = (PresentFrame){ 0 };
}
static PresentFrame present_pend;
static void present_frame_skip(PresentFrame *older, PresentFrame *next)
{
    if (present_tiles_on <= 0) {
        present_frame_put(older);
    } else if (next) {
        present_frame_absorb(next, older);
    } else {
        present_frame_absorb(older, &present_pend);
        present_pend = *older;
        *older = (PresentFrame){ 0 };
    }
}
