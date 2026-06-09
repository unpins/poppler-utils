/* See unpin_data_vfs.h. Reads the embedded poppler-data ZIP via miniz.
 *
 * The ZIP is compiled in as a C array (unpin_data_blob[] / _len) from a header
 * generated at build time with `xxd -i` (see ./poppler.nix). A C array rather
 * than an .incbin'd .S so the embed is identical across all 9 targets (no
 * per-arch asm section/dialect or .incbin cwd issues). Read-only; the archive
 * is opened once, lazily, from the in-memory blob. */
#include "unpin_data_vfs.h"
#include "miniz.h"
#include "unpin_data_blob.h" /* const unsigned char unpin_data_blob[]; const unsigned int unpin_data_blob_len; */

#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#  include <io.h>
#endif

static mz_zip_archive g_zip;
static int g_state; /* 0 = uninit, 1 = ready, 2 = failed */

static void vfs_init(void)
{
    if (g_state) {
        return;
    }
    g_state = mz_zip_reader_init_mem(&g_zip, unpin_data_blob, (size_t)unpin_data_blob_len, 0) ? 1 : 2;
}

char **unpin_data_list(const char *prefix, int want_dirs)
{
    vfs_init();

    char **out = NULL;
    size_t n = 0, cap = 0;
    if (g_state != 1) {
        return (char **)calloc(1, sizeof(char *));
    }

    size_t plen = strlen(prefix);
    mz_uint count = mz_zip_reader_get_num_files(&g_zip);
    for (mz_uint i = 0; i < count; i++) {
        char name[1024];
        if (!mz_zip_reader_get_filename(&g_zip, i, name, (mz_uint)sizeof(name))) {
            continue;
        }
        if (strncmp(name, prefix, plen) != 0) {
            continue;
        }
        const char *rest = name + plen;
        if (!*rest) {
            continue;
        }
        const char *slash = strchr(rest, '/');
        char leaf[1024];
        if (want_dirs) {
            if (!slash) {
                continue; /* a file directly under prefix — not a subdir */
            }
            size_t l = (size_t)(slash - rest);
            if (l == 0 || l >= sizeof(leaf)) {
                continue;
            }
            memcpy(leaf, rest, l);
            leaf[l] = '\0';
        } else {
            if (slash) {
                continue; /* nested deeper — not a direct file */
            }
            snprintf(leaf, sizeof(leaf), "%s", rest);
        }

        int dup = 0;
        for (size_t k = 0; k < n; k++) {
            if (strcmp(out[k], leaf) == 0) {
                dup = 1;
                break;
            }
        }
        if (dup) {
            continue;
        }
        if (n + 1 >= cap) {
            cap = cap ? cap * 2 : 16;
            char **grown = (char **)realloc(out, (cap + 1) * sizeof(char *));
            if (!grown) {
                break;
            }
            out = grown;
        }
        out[n++] = strdup(leaf);
    }

    if (!out) {
        out = (char **)calloc(1, sizeof(char *));
    } else {
        out[n] = NULL;
    }
    return out;
}

void unpin_data_list_free(char **list)
{
    if (!list) {
        return;
    }
    for (char **p = list; *p; ++p) {
        free(*p);
    }
    free(list);
}

FILE *unpin_data_fopen(const char *key)
{
    vfs_init();
    if (g_state != 1) {
        return NULL;
    }
    int idx = mz_zip_reader_locate_file(&g_zip, key, NULL, 0);
    if (idx < 0) {
        return NULL;
    }
    size_t outlen = 0;
    void *buf = mz_zip_reader_extract_to_heap(&g_zip, (mz_uint)idx, &outlen, 0);
    if (!buf) {
        return NULL;
    }

#if defined(_WIN32)
    /* mingw has no fmemopen; materialize to a tmpfile() (auto-deleted on close,
     * created in the user temp dir). poppler reads it sequentially, then
     * fclose() drops it. */
    FILE *f = tmpfile();
    if (!f) {
        free(buf);
        return NULL;
    }
    if (outlen && fwrite(buf, 1, outlen, f) != outlen) {
        fclose(f);
        free(buf);
        return NULL;
    }
    free(buf);
    rewind(f);
    return f;
#else
    /* POSIX: fmemopen serves the inflated buffer as a read-only stream with no
     * temp file. fmemopen does not take ownership of `buf`; it is intentionally
     * leaked (a handful of small CMap/encoding buffers per short-lived run —
     * reclaimed at process exit). */
    FILE *f = fmemopen(buf, outlen, "rb");
    if (!f) {
        free(buf);
        return NULL;
    }
    return f;
#endif
}
