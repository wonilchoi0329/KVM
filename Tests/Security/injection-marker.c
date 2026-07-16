#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>

__attribute__((constructor))
static void markInjection(void) {
    const char *path = getenv("HOSTHOP_INJECTION_MARKER");
    if (path == NULL) return;
    int descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (descriptor >= 0) close(descriptor);
}
