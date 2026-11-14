#include "emulator.h"
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>
#include <limits.h>

int main(void) {
    assert(em_viewport_valid(240, 320));
    assert(em_viewport_valid(428, 541));
    assert(em_viewport_valid(128, 128));
    assert(em_viewport_valid(1920, 1920));
    assert(!em_viewport_valid(127, 320));
    assert(!em_viewport_valid(320, 127));
    assert(!em_viewport_valid(1921, 320));
    assert(!em_viewport_valid(320, 1921));
    assert(!em_viewport_valid(0, 0));
    assert(!em_viewport_valid(-1, 320));
    assert(!em_viewport_valid(INT_MAX, INT_MAX));
    return 0;
}
