dnl Process this m4 file to produce 'C' language file.
dnl
dnl If you see this line, you can ignore the next one.
/* Do not edit this file. It is produced from the corresponding .m4 source */
dnl
/*
 *  Copyright (C) 2003, Northwestern University and Argonne National Laboratory
 *  See COPYRIGHT notice in top-level directory.
 */
/* $Id$ */

/*
 * This file implements the corresponding APIs defined in
 * src/dispatchers/attribute.c and src/dispatchers/attr_getput.m4
 *
 * ncmpi_inq_att()     : dispatcher->inq_att()
 * ncmpi_inq_attid()   : dispatcher->inq_attid()
 * ncmpi_inq_attname() : dispatcher->inq_attname()
 * ncmpi_copy_att()    : dispatcher->copy_att()
 * ncmpi_rename_att()  : dispatcher->rename_att()
 * ncmpi_del_att()     : dispatcher->del_att()
 * ncmpi_put_att()     : dispatcher->put_att()
 * ncmpi_get_att()     : dispatcher->get_att()
 */

#ifdef HAVE_CONFIG_H
# include <config.h>
#endif

#include <stdio.h>
#ifdef HAVE_STDLIB_H
#include <stdlib.h>
#endif
#include <string.h>
#include <assert.h>

#include <mpi.h>

#include <pnc_debug.h>
#include <common.h>
#include "nc.h"
#include "ncx.h"
#include "utf8proc.h"

include(`foreach.m4')dnl
include(`utils.m4')dnl

/*----< x_len_NC_attrV() >---------------------------------------------------*/
/* How much space will 'nelems' of 'xtype' take in external representation.
 * Note the space is aligned in 4-byte boundary.
 */
inline static MPI_Offset
x_len_NC_attrV(nc_type    xtype,
               MPI_Offset nelems)
{
    switch(xtype) {
        case NC_BYTE:
        case NC_CHAR:
        case NC_UBYTE:  return _RNDUP(nelems, 4);
        case NC_SHORT:
        case NC_USHORT: return ((nelems + nelems%2) * 2);
        case NC_INT:
        case NC_UINT:
        case NC_FLOAT:  return (nelems * 4);
        case NC_DOUBLE:
        case NC_INT64:
        case NC_UINT64: return (nelems * 8);
        default: fprintf(stderr, "Error: bad type(%d) in %s\n",xtype,__func__);
    }
    return 0;
}

/*----< ncmpio_new_NC_attr() >-----------------------------------------------*/
/*
 * IN:  name is an already normalized attribute name (NULL terminated)
 * OUT: (*attrp)->xvalue is malloc-ed
 */
int
ncmpio_new_NC_attr(char        *name,
                   nc_type      xtype,
                   MPI_Offset   nelems,
                   NC_attr    **attrp)
{
    *attrp = (NC_attr*) NCI_Malloc(sizeof(NC_attr));
    if (*attrp == NULL ) DEBUG_RETURN_ERROR(NC_ENOMEM)

    (*attrp)->xtype    = xtype;
    (*attrp)->xsz      = 0;
    (*attrp)->nelems   = nelems;
    (*attrp)->xvalue   = NULL;
    (*attrp)->name     = name;
    (*attrp)->name_len = strlen(name);

    if (nelems > 0) {
        /* obtain 4-byte aligned size of space to store the values */
        MPI_Offset xsz = x_len_NC_attrV(xtype, nelems);
        (*attrp)->xsz    = xsz;
        (*attrp)->xvalue = NCI_Malloc((size_t)xsz);
        if ((*attrp)->xvalue == NULL) {
            NCI_Free(*attrp);
            *attrp = NULL;
            DEBUG_RETURN_ERROR(NC_ENOMEM)
        }
    }
    return NC_NOERR;
}

/*----< dup_NC_attr() >------------------------------------------------------*/
/* duplicate an NC_attr object */
static int
dup_NC_attr(const NC_attr *rattrp, NC_attr **attrp)
{
    char *name;

    /* rattrp->name has already been normalized */
    name = (char*) NCI_Malloc(strlen(rattrp->name)+1);
    if (name == NULL) DEBUG_RETURN_ERROR(NC_ENOMEM)
    strcpy(name, rattrp->name);

    return ncmpio_new_NC_attr(name, rattrp->xtype, rattrp->nelems, attrp);
}

/* attrarray */

/*----< ncmpio_free_NC_attrarray() >-----------------------------------------*/
/* Free NC_attrarray values. */
void
ncmpio_free_NC_attrarray(NC_attrarray *ncap)
{
    int i;

    assert(ncap != NULL);

    for (i=0; i<ncap->ndefined; i++) {
        if (ncap->value[i]->xvalue != NULL)
            NCI_Free(ncap->value[i]->xvalue);
        NCI_Free(ncap->value[i]->name);
        NCI_Free(ncap->value[i]);
    }

    /* attributes can be deleted, thus ncap->value can be allocated but
     * ncap->ndefined == 0 */
    if (ncap->value != NULL) {
        NCI_Free(ncap->value);
        ncap->value = NULL;
    }
    ncap->ndefined = 0;
}

/*----< ncmpio_dup_NC_attrarray() >------------------------------------------*/
int
ncmpio_dup_NC_attrarray(NC_attrarray *ncap, const NC_attrarray *ref)
{
    int i, status=NC_NOERR;

    assert(ref != NULL);
    assert(ncap != NULL);

    if (ref->ndefined == 0) { /* return now, if no attribute is defined */
        ncap->ndefined = 0;
        ncap->value    = NULL;
        return NC_NOERR;
    }

    if (ref->ndefined > 0) {
        size_t alloc_size = _RNDUP(ref->ndefined, NC_ARRAY_GROWBY);
        ncap->value = (NC_attr **) NCI_Calloc(alloc_size, sizeof(NC_attr*));
        if (ncap->value == NULL) DEBUG_RETURN_ERROR(NC_ENOMEM)
    }

    ncap->ndefined = 0;
    for (i=0; i<ref->ndefined; i++) {
        status = dup_NC_attr(ref->value[i], &ncap->value[i]);
        if (status != NC_NOERR) {
            ncmpio_free_NC_attrarray(ncap);
            return status;
        }
        ncap->ndefined++;
    }

    assert(ncap->ndefined == ref->ndefined);

    return NC_NOERR;
}

/*----< incr_NC_attrarray() >------------------------------------------------*/
/* Add a new handle at the end of an array of handles */
static int
incr_NC_attrarray(NC_attrarray *ncap, NC_attr *newelemp)
{
    assert(ncap != NULL);
    assert(newelemp != NULL);

    if (ncap->ndefined % NC_ARRAY_GROWBY == 0) {
        /* grow the array to accommodate the new handle */
        NC_attr **vp;
        size_t alloc_size = (size_t)ncap->ndefined + NC_ARRAY_GROWBY;

        vp = (NC_attr **) NCI_Realloc(ncap->value, alloc_size*sizeof(NC_attr*));
        if (vp == NULL) DEBUG_RETURN_ERROR(NC_ENOMEM)

        ncap->value = vp;
    }

    ncap->value[ncap->ndefined++] = newelemp;

    return NC_NOERR;
}

/* End attrarray per se */

/*----< NC_attrarray0() >----------------------------------------------------*/
/* Given ncp and varid, return pointer to array of attributes
 * else NULL on error. This can also be used to validate varid.
 */
static NC_attrarray *
NC_attrarray0(NC *ncp, int varid)
{
    if (varid == NC_GLOBAL) /* Global attribute */
        return &ncp->attrs;

    if (varid >= 0 && varid < ncp->vars.ndefined)
        return &ncp->vars.value[varid]->attrs;

    return NULL;
}

/*----< ncmpio_NC_findattr() >------------------------------------------------*/
/* Step thru NC_ATTRIBUTE array, seeking match on name.
 * return match or -1 if Not Found.
 */
int
ncmpio_NC_findattr(const NC_attrarray *ncap,
                   const char         *name) /* normalized string */
{
    int i;
    size_t nchars;

    assert(ncap != NULL);

    if (ncap->ndefined == 0) return -1; /* none created yet */

    /* already checked before entering this API
    if (name == NULL || *name == 0) return -1;
    */

    /* for now, we assume the number of attributes is small and use the
     * following linear search. If the number is expected to be large, then
     * we can use the name hashing used in variables and dimensions.
     */
    nchars = strlen(name);
    for (i=0; i<ncap->ndefined; i++) {
        if (ncap->value[i]->name_len == nchars &&
            strcmp(ncap->value[i]->name, name) == 0)
            return i;
    }

    return -1;
}

/*----< NC_lookupattr() >----------------------------------------------------*/
/* Look up by ncid, ncap, and name */
static int
NC_lookupattr(const NC_attrarray  *ncap,
              const char          *name,   /* normalized attribute name */
              NC_attr            **attrpp) /* modified on return */
{
    int indx;

    /* requires validity of ncid and ncap already been checked */

    indx = ncmpio_NC_findattr(ncap, name);
    if (indx == -1) DEBUG_RETURN_ERROR(NC_ENOTATT)

    if (attrpp != NULL)
        *attrpp = ncap->value[indx];

    return NC_NOERR;
}

/* Public */

/*----< ncmpio_inq_attname() >-----------------------------------------------*/
/* This is an independent subroutine */
int
ncmpio_inq_attname(void *ncdp,
                   int   varid,
                   int   attid,
                   char *name)   /* out */
{
    NC *ncp=(NC*)ncdp;
    NC_attrarray *ncap;
    NC_attr *attrp;

    /* check varid and get pointer to the NC_attrarray */
    ncap = NC_attrarray0(ncp, varid);
    if (ncap == NULL) DEBUG_RETURN_ERROR(NC_ENOTVAR)

    /* check attribute ID */
    if ((attid < 0) || ncap->ndefined == 0 || attid >= ncap->ndefined)
        DEBUG_RETURN_ERROR(NC_ENOTATT)

    assert(ncap->value != NULL);

    attrp = ncap->value[attid];

    if (name == NULL) DEBUG_RETURN_ERROR(NC_EINVAL)

    /* in PnetCDF, attrp->name is always NULL character terminated */
    strcpy(name, attrp->name);

    return NC_NOERR;
}

/*----< ncmpio_inq_attid() >-------------------------------------------------*/
/* This is an independent subroutine */
int
ncmpio_inq_attid(void       *ncdp,
                 int         varid,
                 const char *name,
                 int        *attidp)  /* out */
{
    int indx;
    char *nname=NULL; /* normalized name */
    NC *ncp=(NC*)ncdp;
    NC_attrarray *ncap;

    ncap = NC_attrarray0(ncp, varid);
    if (ncap == NULL) DEBUG_RETURN_ERROR(NC_ENOTVAR)

    /* create a normalized character string */
    nname = (char *)ncmpii_utf8proc_NFC((const unsigned char *)name);
    if (nname == NULL) DEBUG_RETURN_ERROR(NC_ENOMEM)

    indx = ncmpio_NC_findattr(ncap, nname);
    NCI_Free(nname);
    if (indx == -1) DEBUG_RETURN_ERROR(NC_ENOTATT)

    if (attidp != NULL) *attidp = indx;

    return NC_NOERR;
}

/*----< ncmpio_inq_att() >---------------------------------------------------*/
/* This is an independent subroutine */
int
ncmpio_inq_att(void       *ncdp,
               int         varid,
               const char *name, /* input, attribute name */
               nc_type    *datatypep,
               MPI_Offset *lenp)
{
    int err=NC_NOERR;
    char *nname=NULL;    /* normalized name */
    NC *ncp=(NC*)ncdp;
    NC_attr *attrp;
    NC_attrarray *ncap;

    ncap = NC_attrarray0(ncp, varid);
    if (ncap == NULL) DEBUG_RETURN_ERROR(NC_ENOTVAR)

    /* create a normalized character string */
    nname = (char *)ncmpii_utf8proc_NFC((const unsigned char *)name);
    if (nname == NULL) DEBUG_RETURN_ERROR(NC_ENOMEM)

    err = NC_lookupattr(ncap, nname, &attrp);
    NCI_Free(nname);
    if (err != NC_NOERR) DEBUG_RETURN_ERROR(err)

    if (datatypep != NULL) *datatypep = attrp->xtype;

    if (lenp != NULL) *lenp = attrp->nelems;

    return NC_NOERR;
}

/*----< ncmpio_rename_att() >-------------------------------------------------*/
/* This API is collective. If the new name is longer than the old name, this
 * API must be called in define mode.
 */
int
ncmpio_rename_att(void       *ncdp,
                  int         varid,
                  const char *name,
                  const char *newname)
{
    int indx, err=NC_NOERR;
    char *nname=NULL;    /* normalized name */
    char *nnewname=NULL; /* normalized newname */
    size_t nnewname_len=0;
    NC *ncp=(NC*)ncdp;
    NC_attrarray *ncap=NULL;
    NC_attr *attrp=NULL;

    ncap = NC_attrarray0(ncp, varid);
    if (ncap == NULL) {
        DEBUG_ASSIGN_ERROR(err, NC_ENOTVAR)
        goto err_check;
    }

    /* create a normalized character string */
    nname = (char *)ncmpii_utf8proc_NFC((const unsigned char *)name);
    if (nname == NULL) {
        DEBUG_ASSIGN_ERROR(err, NC_ENOMEM)
        goto err_check;
    }

    indx = ncmpio_NC_findattr(ncap, nname);
    NCI_Free(nname);
    if (indx < 0) {
        DEBUG_ASSIGN_ERROR(err, NC_ENOTATT)
        goto err_check;
    }

    attrp = ncap->value[indx];

    /* create a normalized character string */
    nnewname = (char *)ncmpii_utf8proc_NFC((const unsigned char *)newname);
    if (nnewname == NULL) {
        DEBUG_ASSIGN_ERROR(err, NC_ENOMEM)
        goto err_check;
    }
    nnewname_len = strlen(nnewname);

    if (ncmpio_NC_findattr(ncap, nnewname) >= 0) {
        /* name in use */
        DEBUG_ASSIGN_ERROR(err, NC_ENAMEINUSE)
        goto err_check;
    }

    if (! NC_indef(ncp) && attrp->name_len < nnewname_len) {
        /* when data mode, nnewname cannot be longer than the old one */
        DEBUG_ASSIGN_ERROR(err, NC_ENOTINDEFINE)
        goto err_check;
    }

err_check:
    if (ncp->safe_mode) {
        int minE, mpireturn;

        /* check error code across processes */
        TRACE_COMM(MPI_Allreduce)(&err, &minE, 1, MPI_INT, MPI_MIN, ncp->comm);
        if (mpireturn != MPI_SUCCESS) {
            if (nnewname != NULL) NCI_Free(nnewname);
            return ncmpii_error_mpi2nc(mpireturn, "MPI_Allreduce");
        }
        if (minE != NC_NOERR) {
            if (nnewname != NULL) NCI_Free(nnewname);
            return minE;
        }
    }

    if (err != NC_NOERR) {
        if (nnewname != NULL) NCI_Free(nnewname);
        return err;
    }

    assert(attrp != NULL);

    /* replace the old name with new name */
    NCI_Free(attrp->name);
    attrp->name     = nnewname;
    attrp->name_len = nnewname_len;

    if (! NC_indef(ncp)) { /* when file is in data mode */
        /* Let root write the entire header to the file. Note that we cannot
         * just update the variable name in its space occupied in the file
         * header, because if the file space occupied by the name shrinks, all
         * the metadata following it must be moved ahead.
         */
        err = ncmpio_write_header(ncp);
        if (err != NC_NOERR) DEBUG_RETURN_ERROR(err)
    }

    return err;
}


/*----< ncmpio_copy_att() >---------------------------------------------------*/
/* This API is collective for processes that opened ncdp_out.
 * If the attribute does not exist in ncdp_out, then this API must be called
 * when ncdp_out is in define mode.
 * If the attribute does exist in ncdp_out and the attribute in ncdp_in is
 * larger than the one in ncdp_out, then this API must be called when ncdp_out
 * is in define mode.
 */
int
ncmpio_copy_att(void       *ncdp_in,
                int         varid_in,
                const char *name,
                void       *ncdp_out,
                int         varid_out)
{
    int indx=0, err=NC_NOERR;
    char *nname=NULL;    /* normalized name */
    NC *ncp_in=(NC*)ncdp_in, *ncp_out=(NC*)ncdp_out;
    NC_attrarray *ncap_out=NULL, *ncap_in;
    NC_attr *iattrp=NULL, *attrp=NULL;

    ncap_in = NC_attrarray0(ncp_in, varid_in);
    if (ncap_in == NULL) {
        DEBUG_ASSIGN_ERROR(err, NC_ENOTVAR)
        goto err_check;
    }

    ncap_out = NC_attrarray0(ncp_out, varid_out);
    if (ncap_out == NULL) {
        DEBUG_ASSIGN_ERROR(err, NC_ENOTVAR)
        goto err_check;
    }

    /* create a normalized character string */
    nname = (char *)ncmpii_utf8proc_NFC((const unsigned char *)name);
    if (nname == NULL) {
        DEBUG_ASSIGN_ERROR(err, NC_ENOMEM)
        goto err_check;
    }

    err = NC_lookupattr(ncap_in, nname, &iattrp);
    if (err != NC_NOERR) {
        assert(iattrp == NULL);
        DEBUG_TRACE_ERROR(err)
        goto err_check;
    }

    if (iattrp->xsz != (int)iattrp->xsz) {
        DEBUG_ASSIGN_ERROR(err, NC_EINTOVERFLOW)
        goto err_check;
    }

    indx = ncmpio_NC_findattr(ncap_out, nname);

    if (indx >= 0) { /* name in use in ncap_out */
        if (ncdp_in == ncdp_out && varid_in == varid_out)
            /* self copy is not considered an error */
            goto err_check;

        if (!NC_indef(ncp_out) &&  /* not allowed in data mode */
            iattrp->xsz > ncap_out->value[indx]->xsz) {
            DEBUG_ASSIGN_ERROR(err, NC_ENOTINDEFINE)
            goto err_check;
        }
    }
    else { /* attribute does not exit in ncdp_out */
        if (!NC_indef(ncp_out)) {
            /* add new attribute is not allowed in data mode */
            DEBUG_ASSIGN_ERROR(err, NC_ENOTINDEFINE)
            goto err_check;
        }
        /* Note we no longer limit the number of attributes, as CDF file
         * formats impose no such limit. Thus, the value of NC_MAX_ATTRS has
         * been changed NC_MAX_INT, as NC_attrarray.ndefined is of type signed
         * int and so is natts argument in ncmpi_inq_varnatts()
         */
        if (ncap_out->ndefined == NC_MAX_ATTRS) {
            DEBUG_ASSIGN_ERROR(err, NC_EMAXATTS)
            goto err_check;
        }
    }

err_check:
    if (ncp_out->safe_mode) {
        int minE, mpireturn;

        /* check the error code across processes */
        TRACE_COMM(MPI_Allreduce)(&err, &minE, 1, MPI_INT, MPI_MIN,
                                  ncp_out->comm);
        if (mpireturn != MPI_SUCCESS) {
            if (nname != NULL) NCI_Free(nname);
            return ncmpii_error_mpi2nc(mpireturn, "MPI_Allreduce");
        }
        if (minE != NC_NOERR) {
            if (nname != NULL) NCI_Free(nname);
            return minE;
        }
    }

    if (err != NC_NOERR) {
        if (nname != NULL) NCI_Free(nname);
        return err;
    }
    assert(ncap_out != NULL);
    assert(nname != NULL);

    if (indx >= 0) { /* name in use in ncdp_out */
        NCI_Free(nname);
        if (ncdp_in == ncdp_out && varid_in == varid_out) {
            /* self copy is not considered an error */
            return NC_NOERR;
        }

        /* reuse existing attribute array slot without redef */
        attrp = ncap_out->value[indx];

        if (iattrp->xsz > attrp->xsz) {
            if (attrp->xvalue != NULL) NCI_Free(attrp->xvalue);
            attrp->xvalue = NCI_Malloc((size_t)iattrp->xsz);
            if (attrp->xvalue == NULL) DEBUG_RETURN_ERROR(NC_ENOMEM)
        }
        attrp->xsz    = iattrp->xsz;
        attrp->xtype  = iattrp->xtype;
        attrp->nelems = iattrp->nelems;
    }
    else { /* attribute does not exit in ncdp_out */
        err = ncmpio_new_NC_attr(nname, iattrp->xtype, iattrp->nelems, &attrp);
        if (err != NC_NOERR) return err;

        err = incr_NC_attrarray(ncap_out, attrp);
        if (err != NC_NOERR) return err;
    }

    if (iattrp->xsz > 0)
        memcpy(attrp->xvalue, iattrp->xvalue, (size_t)iattrp->xsz);

    if (!NC_indef(ncp_out)) { /* called in data mode */
        /* Let root write the entire header to the file. Note that we
         * cannot just update the variable name in its space occupied in
         * the file header, because if the file space occupied by the name
         * shrinks, all the metadata following it must be moved ahead.
         */
        err = ncmpio_write_header(ncp_out); /* update file header */
        if (err != NC_NOERR) DEBUG_RETURN_ERROR(err)
    }

    return err;
}

/*----< ncmpio_del_att() >---------------------------------------------------*/
/* This is a collective subroutine and must be called in define mode */
int
ncmpio_del_att(void       *ncdp,
               int         varid,
               const char *name)
{
    int err=NC_NOERR, attrid=-1;
    char *nname=NULL; /* normalized name */
    NC *ncp=(NC*)ncdp;
    NC_attrarray *ncap=NULL;

    /* check NC_ENOTVAR */
    ncap = NC_attrarray0(ncp, varid);
    if (ncap == NULL) {
        DEBUG_ASSIGN_ERROR(err, NC_ENOTVAR)
        goto err_check;
    }

    /* create a normalized character string */
    nname = (char *)ncmpii_utf8proc_NFC((const unsigned char *)name);
    if (nname == NULL) {
        DEBUG_ASSIGN_ERROR(err, NC_ENOMEM)
        goto err_check;
    }

    attrid = ncmpio_NC_findattr(ncap, nname);
    NCI_Free(nname);
    if (attrid == -1) {
        DEBUG_ASSIGN_ERROR(err, NC_ENOTATT)
        goto err_check;
    }

err_check:
    if (ncp->safe_mode) {
        int minE, mpireturn;

        /* find min error code across processes */
        TRACE_COMM(MPI_Allreduce)(&err, &minE, 1, MPI_INT, MPI_MIN,ncp->comm);
        if (mpireturn != MPI_SUCCESS)
            return ncmpii_error_mpi2nc(mpireturn, "MPI_Allreduce");
        if (minE != NC_NOERR) return minE;
    }

    if (err != NC_NOERR) return err;
    assert(ncap != NULL);

    /* delete attribute */
    if (ncap->value[attrid]->xvalue != NULL)
        NCI_Free(ncap->value[attrid]->xvalue);
    NCI_Free(ncap->value[attrid]->name);
    NCI_Free(ncap->value[attrid]);

    /* shuffle down */
    for (; attrid < ncap->ndefined-1; attrid++)
        ncap->value[attrid] = ncap->value[attrid+1];

    /* decrement count */
    ncap->ndefined--;

    return NC_NOERR;
}

/*----< ncmpio_get_att_text() >----------------------------------------------*/
/* This is an independent subroutine.
 * Note this API will never return NC_ERANGE error, as text is not convertible
 * to numerical types.
 */
static int
ncmpio_get_att_text(void       *ncdp,
                    int         varid,
                    const char *name,
                    char       *buf)
{
    int      err=NC_NOERR;
    char    *nname=NULL; /* normalized name */
    NC      *ncp=(NC*)ncdp;
    NC_attr *attrp;
    NC_attrarray *ncap=NULL;
    const void *xp;

    /* check if varid is valid */
    ncap = NC_attrarray0(ncp, varid);
    if (ncap == NULL) DEBUG_RETURN_ERROR(NC_ENOTVAR)

    if (name == NULL || *name == 0 || strlen(name) > NC_MAX_NAME)
        DEBUG_RETURN_ERROR(NC_EBADNAME)

    /* create a normalized character string */
    nname = (char *)ncmpii_utf8proc_NFC((const unsigned char *)name);
    if (nname == NULL) DEBUG_RETURN_ERROR(NC_ENOMEM)

    err = NC_lookupattr(ncap, nname, &attrp);
    NCI_Free(nname);
    if (err != NC_NOERR) DEBUG_RETURN_ERROR(err)

    if (attrp->nelems == 0) return NC_NOERR;

    /* No character conversions are allowed. */
    if (attrp->xtype != NC_CHAR) DEBUG_RETURN_ERROR(NC_ECHAR)

    if (buf == NULL) DEBUG_RETURN_ERROR(NC_EINVAL)

    /* must use xp, as ncmpix_pad_getn_text moves xp ahead */
    xp = attrp->xvalue;
    return ncmpix_pad_getn_text(&xp, attrp->nelems, (char*)buf);
}

dnl
dnl GET_ATT(fntype)
dnl
define(`GET_ATT',dnl
`dnl
/*----< ncmpio_get_att_$1() >------------------------------------------------*/
/* This is an independent subroutine */
static int
ncmpio_get_att_$1(void           *ncdp,
                  int             varid,
                  const char     *name,
                  FUNC2ITYPE($1) *buf)
{
    int            err=NC_NOERR;
    char           *nname=NULL; /* normalized name */
    NC             *ncp=(NC*)ncdp;
    NC_attr        *attrp;
    NC_attrarray   *ncap=NULL;
    const void     *xp;
    MPI_Offset      nelems;

    /* sanity checks for varid and name has been done in dispatcher */

    /* create a normalized character string */
    nname = (char *)ncmpii_utf8proc_NFC((const unsigned char *)name);
    if (nname == NULL) DEBUG_RETURN_ERROR(NC_ENOMEM)

    /* obtain NC_attrarray object pointer, varp. Note sanity check for ncdp and
     * varid has been done in dispatchers */
    if (varid == NC_GLOBAL) ncap = &ncp->attrs;
    else                    ncap = &ncp->vars.value[varid]->attrs;

    /* whether the attr exists (check NC_ENOTATT) */
    err = NC_lookupattr(ncap, nname, &attrp);
    NCI_Free(nname);
    if (err != NC_NOERR) DEBUG_RETURN_ERROR(err)

    if (attrp->nelems == 0) return NC_NOERR;
    nelems = attrp->nelems;

    /* No character conversions are allowed. */
    if (attrp->xtype == NC_CHAR) DEBUG_RETURN_ERROR(NC_ECHAR)

    if (buf == NULL) DEBUG_RETURN_ERROR(NC_EINVAL)

    xp = attrp->xvalue;

    switch(attrp->xtype) {
        /* possible error returned in this switch block is NC_ERANGE */
        case NC_BYTE:
            ifelse(`$1',`uchar',
           `if (ncp->format < 5) { /* no NC_ERANGE check */
                /* note this is not ncmpix_getn_NC_BYTE_$1 */
                return ncmpix_pad_getn_NC_UBYTE_$1(&xp, nelems, buf);
            } else')
                return ncmpix_pad_getn_NC_BYTE_$1 (&xp, nelems, buf);
        case NC_UBYTE:
            return ncmpix_pad_getn_NC_UBYTE_$1 (&xp, nelems, buf);
        case NC_SHORT:
            return ncmpix_pad_getn_NC_SHORT_$1 (&xp, nelems, buf);
        case NC_USHORT:
            return ncmpix_pad_getn_NC_USHORT_$1(&xp, nelems, buf);
        case NC_INT:
            return ncmpix_getn_NC_INT_$1       (&xp, nelems, buf);
        case NC_UINT:
            return ncmpix_getn_NC_UINT_$1      (&xp, nelems, buf);
        case NC_FLOAT:
            return ncmpix_getn_NC_FLOAT_$1     (&xp, nelems, buf);
        case NC_DOUBLE:
            return ncmpix_getn_NC_DOUBLE_$1    (&xp, nelems, buf);
        case NC_INT64:
            return ncmpix_getn_NC_INT64_$1     (&xp, nelems, buf);
        case NC_UINT64:
            return ncmpix_getn_NC_UINT64_$1    (&xp, nelems, buf);
        case NC_CHAR:
            return NC_ECHAR; /* NC_ECHAR already checked earlier */
        default:
            /* this error is unlikely, but an internal error if happened */
            fprintf(stderr, "Error: bad attrp->xtype(%d) in %s\n",
                    attrp->xtype,__func__);
            return NC_EBADTYPE;
    }
}
')dnl

foreach(`iType', (schar,uchar,short,ushort,int,uint,float,double,longlong,ulonglong),
        `GET_ATT(iType)
')

/*----< ncmpio_get_att() >---------------------------------------------------*/
/* This is an independent subroutine */
/* user buffer data type matches the external type defined in file */
int
ncmpio_get_att(void         *ncdp,
               int           varid,
               const char   *name,
               void         *buf,
               MPI_Datatype  itype)
{
    int err=NC_NOERR;

    if (itype == MPI_DATATYPE_NULL) {
        /* this is for the API ncmpi_get_att() where the internal and external
         * data types match (inquire attribute's external data type)
         */
        nc_type dtype;
        err = ncmpio_inq_att(ncdp, varid, name, &dtype, NULL);
        if (err != NC_NOERR) DEBUG_RETURN_ERROR(err)
        itype = ncmpii_nc2mpitype(dtype);
    }

    switch(itype) {
        case MPI_CHAR:
             return ncmpio_get_att_text     (ncdp, varid, name, (char*)buf);
        case MPI_SIGNED_CHAR:
             return ncmpio_get_att_schar    (ncdp, varid, name, (signed char*)buf);
        case MPI_UNSIGNED_CHAR:
             return ncmpio_get_att_uchar    (ncdp, varid, name, (unsigned char*)buf);
        case MPI_SHORT:
             return ncmpio_get_att_short    (ncdp, varid, name, (short*)buf);
        case MPI_UNSIGNED_SHORT:
             return ncmpio_get_att_ushort   (ncdp, varid, name, (unsigned short*)buf);
        case MPI_INT:
             return ncmpio_get_att_int      (ncdp, varid, name, (int*)buf);
        case MPI_UNSIGNED:
             return ncmpio_get_att_uint     (ncdp, varid, name, (unsigned int*)buf);
        case MPI_FLOAT:
             return ncmpio_get_att_float    (ncdp, varid, name, (float*)buf);
        case MPI_DOUBLE:
             return ncmpio_get_att_double   (ncdp, varid, name, (double*)buf);
        case MPI_LONG_LONG_INT:
             return ncmpio_get_att_longlong (ncdp, varid, name, (long long*)buf);
        case MPI_UNSIGNED_LONG_LONG:
             return ncmpio_get_att_ulonglong(ncdp, varid, name, (unsigned long long*)buf);
        default: return NC_EBADTYPE;
    }
}

dnl
dnl PUTN_ITYPE(_pad, itype)
dnl
define(`PUTN_ITYPE',dnl
`dnl
/*----< ncmpix_putn_$1() >---------------------------------------------------*/
/* This is a collective subroutine */
inline static int
ncmpix_putn_$1(void       **xpp,    /* buffer to be written to file */
               MPI_Offset   nelems, /* no. elements in user buffer */
               const $1    *buf,    /* user buffer of type $1 */
               nc_type      xtype,  /* external NC type */
               void        *fillp)  /* fill value in internal representation */
{
    switch(xtype) {
        case NC_BYTE:
            return ncmpix_pad_putn_NC_BYTE_$1  (xpp, nelems, buf, fillp);
        case NC_UBYTE:
            return ncmpix_pad_putn_NC_UBYTE_$1 (xpp, nelems, buf, fillp);
        case NC_SHORT:
            return ncmpix_pad_putn_NC_SHORT_$1 (xpp, nelems, buf, fillp);
        case NC_USHORT:
            return ncmpix_pad_putn_NC_USHORT_$1(xpp, nelems, buf, fillp);
        case NC_INT:
            return ncmpix_putn_NC_INT_$1       (xpp, nelems, buf, fillp);
        case NC_UINT:
            return ncmpix_putn_NC_UINT_$1      (xpp, nelems, buf, fillp);
        case NC_FLOAT:
            return ncmpix_putn_NC_FLOAT_$1     (xpp, nelems, buf, fillp);
        case NC_DOUBLE:
            return ncmpix_putn_NC_DOUBLE_$1    (xpp, nelems, buf, fillp);
        case NC_INT64:
            return ncmpix_putn_NC_INT64_$1     (xpp, nelems, buf, fillp);
        case NC_UINT64:
            return ncmpix_putn_NC_UINT64_$1    (xpp, nelems, buf, fillp);
        case NC_CHAR:
            return NC_ECHAR; /* NC_ECHAR check is done earlier */
        default: fprintf(stderr, "Error: bad xtype(%d) in %s\n",xtype,__func__);
            return NC_EBADTYPE;
    }
}
')dnl

foreach(`iType', (schar,uchar,short,ushort,int,uint,float,double,longlong,ulonglong),
        `PUTN_ITYPE(iType)
')


/* For netCDF, the type mapping between file types and buffer types
 * are based on netcdf4. Check APIs of nc_put_att_xxx from source files
 *     netCDF/netcdf-x.x.x/libdispatch/att.c
 *     netCDF/netcdf-x.x.x/libsrc4/nc4attr.c
 *
 * Note that schar means signed 1-byte integers in attributes. Hence the call
 * below is illegal (NC_ECHAR will return), indicating the error on trying
 * type conversion between characters and numbers.
 *
 * ncmpi_put_att_schar(ncid, varid, "attr name", NC_CHAR, strlen(attrp), attrp);
 *
 * This rule and mapping apply for variables as well. See APIs of
 * nc_put_vara_xxx from source files
 *     netCDF/netcdf-x.x.x/libdispatch/var.c
 *     netCDF/netcdf-x.x.x/libsrc4/nc4var.c
 *
 */

dnl
dnl PUT_ATT(fntype)
dnl
define(`PUT_ATT',dnl
`dnl
/*----< ncmpio_put_att_$1() >------------------------------------------------*/
/* This is a collective subroutine, all arguments should be consistent among
 * all processes.
 *
 * If attribute name has already existed, it means to overwrite the attribute.
 * In this case, if the new attribute is larger than the old one, then this
 * API must be called when the file is in define mode.
 *
 * Note from netCDF user guide:
 * Attributes are always single values or one-dimensional arrays. This works
 * out well for a string, which is a one-dimensional array of ASCII characters
 *
 * Note ncmpio_put_att_text will never return NC_ERANGE error, as text is not
 * convertible to numerical types.
 */
static int
ncmpio_put_att_$1(void       *ncdp,
                  int         varid,
                  const char *name,     /* attribute name */
                  ifelse(`$1',`text',,`nc_type xtype,')
                  MPI_Offset  nelems,   /* number of elements in buf */
                  const FUNC2ITYPE($1) *buf) /* user write buffer */
{
    int indx=0, err=NC_NOERR;
    char *nname=NULL; /* normalized name */
    MPI_Offset xsz=0;
    NC *ncp=(NC*)ncdp;
    NC_attrarray *ncap=NULL;
    NC_attr *attrp=NULL;
    ifelse(`$1',`text', `nc_type xtype=NC_CHAR;')

    /* sanity checks for varid, name, xtype has been done in dispatcher */

    /* If this is the _FillValue attribute, then let PnetCDF return the
     * same error codes as netCDF
     */
    if (varid != NC_GLOBAL && !strcmp(name, _FillValue)) {
        NC_var *varp;
        err = ncmpio_NC_lookupvar(ncp, varid, &varp);
        if (err != NC_NOERR) {
            DEBUG_TRACE_ERROR(err)
            goto err_check;
        }

        /* Fill value must be of the same data type */
        if (xtype != varp->xtype) {
            DEBUG_ASSIGN_ERROR(err, NC_EBADTYPE)
            goto err_check;
        }

        /* Fill value must have exactly one value */
        if (nelems != 1) {
            DEBUG_ASSIGN_ERROR(err, NC_EINVAL)
            goto err_check;
        }

        /* Only allow for variables defined in initial define mode */
        if (ncp->old != NULL && varid < ncp->old->vars.ndefined) {
            DEBUG_ASSIGN_ERROR(err, NC_ELATEFILL)
            goto err_check;
        }
    }

    xsz = x_len_NC_attrV(xtype, nelems);
    /* xsz is the total size of this attribute */

    if (xsz != (int)xsz) {
        DEBUG_ASSIGN_ERROR(err, NC_EINTOVERFLOW)
        goto err_check;
    }

    /* create a normalized character string */
    nname = (char *)ncmpii_utf8proc_NFC((const unsigned char *)name);
    if (nname == NULL) {
        DEBUG_ASSIGN_ERROR(err, NC_ENOMEM)
        goto err_check;
    }

    /* obtain NC_attrarray object pointer, varp. Note sanity check for ncdp and
     * varid has been done in dispatchers */
    if (varid == NC_GLOBAL) ncap = &ncp->attrs;
    else                    ncap = &ncp->vars.value[varid]->attrs;

    /* check whether attribute already exists */
    indx = ncmpio_NC_findattr(ncap, nname);

    if (indx >= 0) { /* name in use */
        /* xsz is the total size of this attribute */
        if (!NC_indef(ncp) && xsz > ncap->value[indx]->xsz) {
            /* The new attribute requires a larger space, which is not allowed
             * in data mode */
            DEBUG_ASSIGN_ERROR(err, NC_ENOTINDEFINE)
            goto err_check;
        }
    }
    else { /* attribute does not exit in ncid */
        if (!NC_indef(ncp)) {
            /* add new attribute is not allowed in data mode */
            DEBUG_ASSIGN_ERROR(err, NC_ENOTINDEFINE)
            goto err_check;
        }
        /* Note we no longer limit the number of attributes, as CDF file formats
         * impose no such limit. Thus, the value of NC_MAX_ATTRS has been
         * changed NC_MAX_INT, as NC_attrarray.ndefined is of type signed int
         * and so is natts argument in ncmpi_inq_varnatts()
         */
        if (ncap->ndefined == NC_MAX_ATTRS) {
            DEBUG_ASSIGN_ERROR(err, NC_EMAXATTS)
            goto err_check;
        }
    }

err_check:
    if (ncp->safe_mode) { /* check the error code across processes */
        int minE, mpireturn;

        TRACE_COMM(MPI_Allreduce)(&err, &minE, 1, MPI_INT, MPI_MIN, ncp->comm);
        if (mpireturn != MPI_SUCCESS) {
            if (nname != NULL) NCI_Free(nname);
            return ncmpii_error_mpi2nc(mpireturn, "MPI_Allreduce");
        }
        if (minE != NC_NOERR) {
            if (nname != NULL) NCI_Free(nname);
            return minE;
        }
        /* argument consistency check has been done at the dispatchers */
    }

    if (err != NC_NOERR) {
        if (nname != NULL) NCI_Free(nname);
        return err;
    }
    assert(ncap != NULL);
    assert(nname != NULL);

    if (indx >= 0) { /* name in use */
        NCI_Free(nname);
        attrp = ncap->value[indx]; /* convenience */

        if (xsz > attrp->xsz) { /* new attribute requires a larger space */
            if (attrp->xvalue != NULL) NCI_Free(attrp->xvalue);
            attrp->xvalue = NCI_Malloc((size_t)xsz);
            if (attrp->xvalue == NULL) DEBUG_RETURN_ERROR(NC_ENOMEM)
        }
        attrp->xsz    = xsz;
        attrp->xtype  = xtype;
        attrp->nelems = nelems;
    }
    else { /* attribute does not exit in ncid */
        err = ncmpio_new_NC_attr(nname, xtype, nelems, &attrp);
        if (err != NC_NOERR) return err;

        err = incr_NC_attrarray(ncap, attrp);
        if (err != NC_NOERR) return err;
    }

    if (nelems != 0 && buf != NULL) { /* non-zero length attribute */
        /* using xp below to prevent change the pointer attr->xvalue, as
         * ncmpix_pad_putn_<type>() advances the first argument with nelems
         * elements. Note that attrp->xvalue is malloc-ed with a buffer of
         * size that is aligned with a 4-byte boundary.
         */
        void *xp = attrp->xvalue;
        ifelse(`$1',`text',,`dnl
        unsigned char fill[8]; /* fill value in internal representation */

        /* find the fill value */
        err = ncmpio_inq_default_fill_value(xtype, &fill);
        if (err != NC_NOERR) DEBUG_RETURN_ERROR(err)')

        ifelse(`$1',`text', `err = ncmpix_pad_putn_text(&xp, nelems, buf);',
               `$1',`uchar',`
        if (ncp->format < 5 && xtype == NC_BYTE) { /* no NC_ERANGE check */
            err = ncmpio_inq_default_fill_value(NC_UBYTE, &fill);
            if (err != NC_NOERR) DEBUG_RETURN_ERROR(err)
            err = ncmpix_putn_uchar(&xp, nelems, buf, NC_UBYTE, &fill);
        } else
            err = ncmpix_putn_$1(&xp, nelems, buf, xtype, &fill);',
        `err = ncmpix_putn_$1(&xp, nelems, buf, xtype, &fill);')

        /* no immediately return error code here? Strange ...
         * Instead, we continue and call incr_NC_attrarray() to add
         * this attribute (for create case) as it is legal. But if
         * we return error and reject this attribute, then nc_test will
         * fail with this error message below:
         * FAILURE at line 252 of test_read.c: ncmpi_inq: wrong number
         * of global atts returned, 3
         * Check netCDF-4, it is doing the same thing!
         *
         * One of the error codes returned from ncmpix_pad_putn_<type>() is
         * NC_ERANGE, meaning one or more elements are type overflow.
         * Should we reject the entire attribute array if only part of
         * the array overflow? For netCDF4, the answer is NO.
         */
/*
        if (err != NC_NOERR) {
            if (attrp->xvalue != NULL) NCI_Free(attrp->xvalue);
            NCI_Free(attrp->name);
            NCI_Free(attrp);
            DEBUG_RETURN_ERROR(err)
        }
*/
    }

    if (!NC_indef(ncp)) { /* called in data mode */
        /* Let root write the entire header to the file. Note that we
         * cannot just update the attribute in its space occupied in the
         * file header, because if the file space occupied by the attribute
         * shrinks, all the metadata following it must be moved ahead.
         */
        int status;
        status = ncmpio_write_header(ncp); /* update file header */
        if (err == NC_NOERR) err = status;
    }

    return err;
}
')dnl

foreach(`iType', (text,schar,uchar,short,ushort,int,uint,float,double,longlong,ulonglong),
        `PUT_ATT(iType)
')

/*----< ncmpio_put_att() >---------------------------------------------------*/
/* This is a collective subroutine, all arguments should be consistent among
 * all processes.
 */
int
ncmpio_put_att(void         *ncdp,
               int           varid,
               const char   *name,
               nc_type       xtype,  /* external (file/NC) data type */
               MPI_Offset    nelems,
               const void   *buf,
               MPI_Datatype  itype)  /* internal (memory) data type */
{
    switch(itype) {
        case MPI_CHAR:
             return ncmpio_put_att_text     (ncdp, varid, name,        nelems, buf);
        case MPI_SIGNED_CHAR:
             return ncmpio_put_att_schar    (ncdp, varid, name, xtype, nelems, buf);
        case MPI_UNSIGNED_CHAR:
             return ncmpio_put_att_uchar    (ncdp, varid, name, xtype, nelems, buf);
        case MPI_SHORT:
             return ncmpio_put_att_short    (ncdp, varid, name, xtype, nelems, buf);
        case MPI_UNSIGNED_SHORT:
             return ncmpio_put_att_ushort   (ncdp, varid, name, xtype, nelems, buf);
        case MPI_INT:
             return ncmpio_put_att_int      (ncdp, varid, name, xtype, nelems, buf);
        case MPI_UNSIGNED:
             return ncmpio_put_att_uint     (ncdp, varid, name, xtype, nelems, buf);
        case MPI_FLOAT:
             return ncmpio_put_att_float    (ncdp, varid, name, xtype, nelems, buf);
        case MPI_DOUBLE:
             return ncmpio_put_att_double   (ncdp, varid, name, xtype, nelems, buf);
        case MPI_LONG_LONG_INT:
             return ncmpio_put_att_longlong (ncdp, varid, name, xtype, nelems, buf);
        case MPI_UNSIGNED_LONG_LONG:
             return ncmpio_put_att_ulonglong(ncdp, varid, name, xtype, nelems, buf);
        default: return NC_EBADTYPE;
    }
}

