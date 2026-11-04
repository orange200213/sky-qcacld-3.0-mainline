#ifndef _QCA_MAINLINE_STRING_COMPAT_H
#define _QCA_MAINLINE_STRING_COMPAT_H
#include_next <linux/string.h>
#ifndef strlcpy
static inline size_t qca_strlcpy(char *dst, const char *src, size_t size)
{
	size_t len = 0;
	if (size) {
		while (len + 1 < size && src[len]) {
			dst[len] = src[len];
			len++;
		}
		dst[len] = '\0';
	}
	while (src[len])
		len++;
	return len;
}
#define strlcpy qca_strlcpy
#endif
#endif
