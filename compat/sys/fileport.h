#ifndef FILZA_COMPAT_SYS_FILEPORT_H
#define FILZA_COMPAT_SYS_FILEPORT_H

#include <sys/_types.h>
#include <sys/cdefs.h>

__BEGIN_DECLS

#ifndef _FILEPORT_T
#define _FILEPORT_T
typedef __darwin_mach_port_t fileport_t;
#define FILEPORT_NULL ((fileport_t)0)
#endif

int fileport_makeport(int descriptor, fileport_t *port);
int fileport_makefd(fileport_t port);

__END_DECLS

#endif
