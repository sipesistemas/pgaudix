EXTENSION    = pgaudix
MODULE_big   = pgaudix
OBJS         = src/pgaudix.o

DATA         = pgaudix--0.1.0.sql
PGFILEDESC   = "pgaudix - automatic table auditing with column mirroring"

REGRESS      = pgaudix_test
REGRESS_OPTS = --inputdir=test

PG_CPPFLAGS  = -I$(srcdir)/src

ifdef USE_PGXS
PG_CONFIG    ?= pg_config
PGXS         := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/pgaudix
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
