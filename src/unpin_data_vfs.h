/* Embedded poppler-data VFS — reads poppler's CMap / encoding tree from a ZIP
 * blob compiled into the binary (./unpin_data_blob.S incbin'ing a `zip -9` of
 * poppler-data), so the utils need no on-disk share/poppler. miniz reads the
 * blob in memory; GlobalParams.cc (patched, see ./poppler-data-embed.patch)
 * calls these instead of std::filesystem::directory_iterator + openFile.
 *
 * Compiled into libpoppler (added to its CMake sources) so both the per-app
 * CMake links and the multicall relink resolve the symbols. */
#ifndef UNPIN_DATA_VFS_H
#define UNPIN_DATA_VFS_H

#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

/* List the immediate children under `prefix` (which must end with '/').
 * want_dirs != 0 -> distinct first-level subdirectory names (used for cMap/,
 * whose children are per-collection dirs); want_dirs == 0 -> regular files
 * directly under prefix (nameToUnicode/, cidToUnicode/, unicodeMap/).
 * Returns a NULL-terminated, heap-allocated array of strdup'd leaf names
 * (never NULL itself); release with unpin_data_list_free. */
char **unpin_data_list(const char *prefix, int want_dirs);
void unpin_data_list_free(char **list);

/* Open a ZIP-internal entry (key = full internal path, e.g.
 * "cMap/Adobe-Japan1/UniJIS-UCS2-H" or "nameToUnicode/Bulgarian") as a readable
 * FILE*. Returns NULL if the key is absent. */
FILE *unpin_data_fopen(const char *key);

#ifdef __cplusplus
}
#endif

#endif /* UNPIN_DATA_VFS_H */
