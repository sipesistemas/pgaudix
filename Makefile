EXTENSION    = pgaudix
MODULE_big   = pgaudix
OBJS         = src/pgaudix.o

DATA         = pgaudix--0.2.0.sql
PGFILEDESC   = "pgaudix - automatic table auditing with column mirroring"

REGRESS      = pgaudix_test
REGRESS_OPTS = --inputdir=test

PG_CPPFLAGS  = -I$(srcdir)/src

# Inside the dev container make runs as root, and there is no "root" database
# role; connect as postgres unless the caller set PGUSER explicitly.
ifeq ($(shell id -u),0)
export PGUSER ?= postgres
endif

ifdef USE_PGXS
PG_CONFIG    ?= pg_config
PG_MAJOR     := $(shell $(PG_CONFIG) --version | sed -E 's/^[^0-9]*([0-9]+).*/\1/')
# Virtual generated columns exist since PostgreSQL 18
ifeq ($(shell test $(PG_MAJOR) -ge 18 && echo yes),yes)
REGRESS      += pgaudix_generated
endif
PGXS         := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/pgaudix
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
