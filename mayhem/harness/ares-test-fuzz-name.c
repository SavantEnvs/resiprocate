/* Wider ares name harness: upstream's ares-test-fuzz-name.c only calls ares_mkquery() on the
 * NUL-terminated input. This one also expands the input as a wire-format name (with and without
 * a packet around it) and expands the name it just encoded. */
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "ares.h"
#include "ares_nameser.h"

static void expand(const unsigned char *enc, const unsigned char *abuf, int alen) {
  char *s = NULL;
  long enclen = 0;
  if (ares_expand_name(enc, abuf, alen, &s, &enclen) == ARES_SUCCESS)
    ares_free_string(s);
}

int LLVMFuzzerTestOneInput(const unsigned char *data,
                           unsigned long size) {
  // ares_mkquery wants a NUL-terminated name; the copy keeps the harness input untouched.
  char *name = malloc(size + 1);
  name[size] = '\0';
  memcpy(name, data, size);

  static const int types[] = {ns_t_a, ns_t_aaaa, ns_t_ptr, ns_t_srv, ns_t_naptr};
  int type = types[size % (sizeof(types) / sizeof(types[0]))];
  unsigned char *buf = NULL;
  int buflen = 0;
  if (ares_mkquery(name, ns_c_in, type, 1234, (int)(size & 1), &buf, &buflen) == ARES_SUCCESS) {
    // The question name starts right after the 12-byte DNS header.
    if (buflen > 12) expand(buf + 12, buf, buflen);
  }
  free(buf);
  free(name);

  // Raw input as a packet: names at the start, after a 12-byte header, and via a compression pointer.
  if (size > 0) expand(data, data, (int)size);
  if (size > 12) expand(data + 12, data, (int)size);
  if (size > 1) expand(data + size / 2, data, (int)size);
  return 0;
}
