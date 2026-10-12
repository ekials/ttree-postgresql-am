
EXTENSION = ttree
MODULE_big = ttree
OBJS = src/ttree.o
DATA = sql/ttree--1.0.sql

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
