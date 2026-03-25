#ifndef PGAUDIX_H
#define PGAUDIX_H

#include "postgres.h"
#include "fmgr.h"

/* Audit operation codes */
#define AUDIT_OP_INSERT "I"
#define AUDIT_OP_UPDATE "U"
#define AUDIT_OP_DELETE "D"

/* Number of fixed audit metadata columns in the audit table */
#define AUDIT_META_COLS 7

#endif /* PGAUDIX_H */
