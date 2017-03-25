#
# Copyright (C) 2012, Northwestern University and Argonne National Laboratory
# See COPYRIGHT notice in top-level directory.
#
# $Id$
#
# @configure_input@

SUFFIXES = .o .f90

AM_DEFAULT_SOURCE_EXT = .f90
AM_FCFLAGS = -I$(top_builddir)/src/binding/f77 $(FC_MODINC)$(top_builddir)/src/binding/f90 $(FC_MODINC)../common
LDADD = ${top_builddir}/src/libs/libpnetcdf.la ../common/libtestutils.la

TESTPROGRAMS = tst_f90 \
               tst_io \
               f90tst_vars \
               tst_types2 \
               tst_f90_cdf5 \
               f90tst_vars2 \
               f90tst_vars3 \
               f90tst_vars4 \
               tst_flarge \
               f90tst_parallel \
               f90tst_parallel2 \
               f90tst_parallel3 \
               f90tst_parallel4 \
               test_intent

check_PROGRAMS = $(TESTPROGRAMS)

# autimake 1.11.3 has not yet implemented AM_TESTS_ENVIRONMENT
# For newer versions, we can use AM_TESTS_ENVIRONMENT instead
# AM_TESTS_ENVIRONMENT  = TESTPROGRAMS="$(TESTPROGRAMS)" ; export TESTPROGRAMS;
# AM_TESTS_ENVIRONMENT += TESTSEQRUN="$(TESTSEQRUN)" ; export TESTSEQRUN;
# AM_TESTS_ENVIRONMENT += TESTOUTDIR="$(TESTOUTDIR)" ; export TESTOUTDIR;
TESTS_ENVIRONMENT  = TESTPROGRAMS="$(TESTPROGRAMS)" ; export TESTPROGRAMS;
TESTS_ENVIRONMENT += TESTSEQRUN="$(TESTSEQRUN)" ; export TESTSEQRUN;
TESTS_ENVIRONMENT += TESTOUTDIR="$(TESTOUTDIR)" ; export TESTOUTDIR;

TESTS = seq_runs.sh

EXTRA_DIST = seq_runs.sh

CLEANFILES  = *.nc *.$(FC_MODEXT) core core.* *.gcda *.gcno *.gcov gmon.out

../common/libtestutils.la:
	set -e; cd ../common && $(MAKE) $(MFLAGS) tests

PARALLEL_PROGS = f90tst_parallel \
                 f90tst_parallel2 \
                 f90tst_parallel3 \
                 f90tst_parallel4

ptest ptest4: $(PARALLEL_PROGS)
	set -e ; for i in $(PARALLEL_PROGS); do ( \
	$(TESTMPIRUN4) ./$$i $(TESTOUTDIR)/testfile.nc ; \
	) ; done

ptest2: $(PARALLEL_PROGS)
	set -e ; for i in $(PARALLEL_PROGS); do ( \
	$(TESTMPIRUN2) ./$$i $(TESTOUTDIR)/testfile.nc ; \
	) ; done

ptest8: $(PARALLEL_PROGS)
	set -e ; for i in $(PARALLEL_PROGS); do ( \
	$(TESTMPIRUN8) ./$$i $(TESTOUTDIR)/testfile.nc ; \
	) ; done

ptest10: $(PARALLEL_PROGS)
	set -e ; for i in $(PARALLEL_PROGS); do ( \
	$(TESTMPIRUN10) ./$$i $(TESTOUTDIR)/testfile.nc ; \
	) ; done

ptests: ptest2 ptest4 ptest8 ptest10
ptest6:

# build check targets but not invoke
tests-local: all $(check_PROGRAMS)

.PHONY: ptest ptests ptest2 ptest4 ptest6 ptest8 ptest10

dist-hook:
	-rm -rf `find $(distdir) -name .svn`
