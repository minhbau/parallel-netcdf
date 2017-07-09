/*
 *  Copyright (C) 2014, Northwestern University and Argonne National Laboratory
 *  See COPYRIGHT notice in top-level directory.
 */
/* $Id$ */

#ifdef HAVE_CONFIG_H
# include <config.h>
#endif

#include <stdio.h>
#include <unistd.h>
#ifdef HAVE_STDLIB_H
#include <stdlib.h>
#endif
#include <string.h> /* memcpy() */
#include <assert.h>

#include <mpi.h>

#include <pnc_debug.h>
#include <common.h>
#include "nc.h"
#include "ncx.h"
#include "ncmpidtype.h"
#ifdef ENABLE_SUBFILING
#include "subfile.h"
#endif

/* for write case, buf needs to swapped back if swapped previously */
#define FINAL_CLEAN_UP {                                                       \
    if (is_buf_swapped) /* byte-swap back to buf's original contents */        \
        ncmpio_in_swapn(buf, bnelems, ncmpix_len_nctype(varp->type));          \
                                                                               \
    if (cbuf != NULL && cbuf != buf) NCI_Free(cbuf);                           \
}

/*----< ncmpio_getput_vard() >------------------------------------------------*/
static int
ncmpio_getput_vard(NC               *ncp,
                   NC_var           *varp,
                   MPI_Datatype      filetype,  /* data type of the variable */
                   void             *buf,
                   MPI_Offset        bufcount,
                   MPI_Datatype      buftype,  /* data type of the bufer */
                   int               rw_flag,
                   int               io_method)
{
    void *cbuf=NULL;
    int i, isderived, el_size, mpireturn, status=NC_NOERR, err=NC_NOERR;
    int buftype_is_contig=0, filetype_is_contig=1, need_swap=0, is_buf_swapped=0;
    int filetype_size=0, buftype_size=0;
    MPI_Offset btnelems=0, bnelems=0, offset=0, orig_bufcount=bufcount;
    MPI_Status mpistatus;
    MPI_Datatype ptype, orig_buftype=buftype;
    MPI_File fh=MPI_FILE_NULL;
    MPI_Aint lb, extent=0, true_lb, true_extent;

    if (filetype == MPI_DATATYPE_NULL) { /* this process does zero-length I/O */
        if (io_method == INDEP_IO) return NC_NOERR;
        bufcount = 0;
        goto err_check;
    }

    if (bufcount == 0 && buftype != MPI_DATATYPE_NULL) {
        /* if this process has nothing to read/write */
        if (io_method == INDEP_IO) return NC_NOERR;
        goto err_check;
    }

#ifdef ENABLE_SUBFILING
    /* call a separate routine if variable is stored in subfiles */
    if (varp->num_subfiles > 1) {
        printf("This feature for subfiling is yet to implement\n");
        DEBUG_RETURN_ERROR(NC_ENOTSUPPORT)
    }
#endif

    /* PROBLEM: argument filetype_size is a 4-byte integer, cannot be used
     * for largefiletypes */
    mpireturn = MPI_Type_size(filetype, &filetype_size);
    if (mpireturn != MPI_SUCCESS) {
        err = ncmpio_handle_error(mpireturn, "MPI_Type_size");
        goto err_check;
    }

    if (filetype_size == 0) { /* zero-length request */
        if (io_method == INDEP_IO) return NC_NOERR;
        bufcount = 0;
        goto err_check;
    }

    MPI_Type_get_true_extent(filetype, &true_lb, &true_extent);
    MPI_Type_get_extent(filetype, &lb, &extent);

    if (!IS_RECVAR(varp)) {
        /* for fixed-size variable, extent should not be larger than the
         * variabe size */
        MPI_Offset var_size = varp->xsz;
        for (i=0; i<varp->ndims; i++)
            var_size *= varp->shape[i];

        if (extent > var_size) {
            DEBUG_ASSIGN_ERROR(err, NC_ETYPESIZE)
            goto err_check;
        }
    }

    cbuf = (void*) buf;

    /* find the element type of filetype */
    err = ncmpio_dtype_decode(filetype, &ptype, &el_size, &btnelems,
                              &isderived, &filetype_is_contig);
    if (err != NC_NOERR) goto err_check;

    /* element type of filetype must be the same as variable's type */
    if (ptype != ncmpio_nc2mpitype(varp->type)) {
        DEBUG_ASSIGN_ERROR(err, NC_ETYPE_MISMATCH)
        goto err_check;
    }

    if (bufcount != (int)bufcount) {
        DEBUG_ASSIGN_ERROR(err, NC_EINTOVERFLOW)
        goto err_check;
    }

    if (buftype == MPI_DATATYPE_NULL) {
        /* In this case, bufcount is ignored and will be set to the size of
         * filetype. Note buf's data type must match the data type of variable
         * defined in the file - no data conversion will be done.
         */
        /* set buftype to the variable's data type */
        buftype = ncmpio_nc2mpitype(varp->type);
        MPI_Type_size(buftype, &buftype_size);
        bufcount = filetype_size / buftype_size;
        buftype_is_contig = 1;
        bnelems = bufcount;
    }
    else {
        MPI_Offset outsize;

        /* find whether buftype is contiguous */
        err = ncmpio_dtype_decode(buftype, &ptype, &el_size, &btnelems,
                                  &isderived, &buftype_is_contig);
        if (err != NC_NOERR) goto err_check;

        err = NCMPII_ECHAR(varp->type, ptype);
        if (err != NC_NOERR) goto err_check;

        if (btnelems != (int)btnelems) {
            DEBUG_ASSIGN_ERROR(err, NC_EINTOVERFLOW)
            goto err_check;
        }

        bnelems      = bufcount * btnelems;
        buftype_size = el_size  * (int)btnelems;
        outsize      = bufcount * buftype_size;

        if (outsize != filetype_size) {
            DEBUG_ASSIGN_ERROR(err, NC_ETYPESIZE_MISMATCH)
            goto err_check;
        }

        /* if buf is not contiguous, we need to pack it to one, cbuf */
        if (!buftype_is_contig && bnelems > 0) {
            cbuf = NCI_Malloc((size_t)outsize);

            if (rw_flag == WRITE_REQ) {
                /* pack buf into cbuf, a contiguous buffer */
                int position = 0;
                MPI_Pack(buf, (int)bufcount, buftype, cbuf, (int)outsize, &position,
                         MPI_COMM_SELF);
            }
            buftype = ptype;
            bufcount *= bnelems;
            buftype_size = el_size;
        }
    }

    /* Check if we need byte swap cbuf in-place or (into cbuf) */
    need_swap = ncmpio_need_swap(varp->type, ptype);
    if (need_swap) {
        if (rw_flag == WRITE_REQ) {
#ifdef DISABLE_IN_PLACE_SWAP
            if (cbuf == buf) {
#else
            if (cbuf == buf && filetype_size <= NC_BYTE_SWAP_BUFFER_SIZE) {
#endif
                /* allocate cbuf and copy buf to cbuf, cbuf is to be freed */
                cbuf = NCI_Malloc((size_t)filetype_size);
                memcpy(cbuf, buf, (size_t)filetype_size);
            }
            /* perform array in-place byte swap on cbuf */
            ncmpio_in_swapn(cbuf, bnelems, ncmpix_len_nctype(varp->type));
            is_buf_swapped = (cbuf == buf) ? 1 : 0;
            /* is_buf_swapped indicates if the contents of the original user
             * buffer, buf, have been changed, i.e. byte swapped. */
        }
    }
    /* no type conversion */

    /* set fileview's displacement to the variable's starting file offset */
    offset = varp->begin;

err_check:
    /* check API error from any proc before going into a collective call.
     * optimization: to avoid MPI_Allreduce to check parameters at
     * every call, we assume caller does the right thing most of the
     * time.  If caller passed in bad parameters, we'll still conduct a
     * zero-byte operation (everyone has to participate in the
     * collective I/O call) but return error */
    if (err != NC_NOERR || bufcount == 0 || filetype_size == 0) {
        if (io_method == INDEP_IO) {
            FINAL_CLEAN_UP  /* swap back put buffer and free temp buffers */
            return err;
        }
        /* else for COLL_IO, must participate successive collective calls */
        offset = 0;
        bufcount = 0;
    }
    status = err;

    if (io_method == COLL_IO)
        fh = ncp->collective_fh;
    else
        fh = ncp->independent_fh;

    /* set the file view */
    err = ncmpio_file_set_view(ncp, fh, &offset, filetype);
    if (err != NC_NOERR) {
        bufcount = 0; /* skip this request */
        if (status == NC_NOERR) status = err;
    }

    if (rw_flag == WRITE_REQ) {
        if (io_method == COLL_IO) {
            TRACE_IO(MPI_File_write_at_all)(fh, offset, cbuf, (int)bufcount, buftype, &mpistatus);
            if (mpireturn != MPI_SUCCESS)
                return ncmpio_handle_error(mpireturn, "MPI_File_write_at_all");
            else
                ncp->put_size += bufcount * buftype_size;
        }
        else { /* io_method == INDEP_IO */
            TRACE_IO(MPI_File_write_at)(fh, offset, cbuf, (int)bufcount, buftype, &mpistatus);
            if (mpireturn != MPI_SUCCESS)
                return ncmpio_handle_error(mpireturn, "MPI_File_write_at");
            else
                ncp->put_size += bufcount * buftype_size;
        }
    }
    else {  /* rw_flag == READ_REQ */
        if (io_method == COLL_IO) {
            TRACE_IO(MPI_File_read_at_all)(fh, offset, cbuf, (int)bufcount, buftype, &mpistatus);
            if (mpireturn != MPI_SUCCESS)
                return ncmpio_handle_error(mpireturn, "MPI_File_read_at_all");
            else
                ncp->get_size += bufcount * buftype_size;
        }
        else { /* io_method == INDEP_IO */
            TRACE_IO(MPI_File_read_at)(fh, offset, cbuf, (int)bufcount, buftype, &mpistatus);
            if (mpireturn != MPI_SUCCESS)
                return ncmpio_handle_error(mpireturn, "MPI_File_read_at");
            else
                ncp->get_size += bufcount * buftype_size;
        }
    }

    /* No longer need to reset the file view, as the root's fileview includes
     * the whole file header.
     TRACE_IO(MPI_File_set_view)(fh, 0, MPI_BYTE, MPI_BYTE, "native", MPI_INFO_NULL);
     */

    if (rw_flag == READ_REQ) {
        if (need_swap)
            /* perform array in-place byte swap on cbuf */
            ncmpio_in_swapn(cbuf, bnelems, ncmpix_len_nctype(varp->type));

        if (!buftype_is_contig && bnelems > 0) {
            /* unpack cbuf, a contiguous buffer, to buf using buftype */
            int position = 0;
            MPI_Offset insize = bnelems * el_size;
            if (insize != (int)insize) {
                if (status == NC_NOERR) DEBUG_ASSIGN_ERROR(status, NC_EINTOVERFLOW)
            }
            else
                MPI_Unpack(cbuf, (int)insize, &position, buf, (int)orig_bufcount,
                           orig_buftype, MPI_COMM_SELF);
        }
    }
    else { /* WRITE_REQ */
        if (IS_RECVAR(varp)) {
            /* update header's number of records in memory */
            MPI_Offset new_numrecs;

            /* since filetype's LB is required to be == varp->begin for vard
             * API, we can simply use extent to calculate new_numrecs */
            new_numrecs = extent / ncp->recsize;
            if (extent % ncp->recsize) new_numrecs++;

            if (io_method == INDEP_IO) {
                /* For independent put, we delay the sync for numrecs until
                 * the next collective call, such as end_indep(), sync(),
                 * enddef(), or close(). This is because if we update numrecs
                 * to file now, race condition can happen. Note numrecs in
                 * memory may be inconsistent and obsolete till then.
                 */
                if (ncp->numrecs < new_numrecs) {
                    ncp->numrecs = new_numrecs;
                    set_NC_ndirty(ncp);
                }
            }
            else { /* COLL_IO: sync numrecs in memory and file */
                /* new_numrecs may be different among processes.
                 * First, find the max numrecs among all processes.
                 */
                MPI_Offset max_numrecs;
                TRACE_COMM(MPI_Allreduce)(&new_numrecs, &max_numrecs, 1,
                                          MPI_OFFSET, MPI_MAX, ncp->comm);
                if (mpireturn != MPI_SUCCESS) {
                    err = ncmpio_handle_error(mpireturn, "MPI_Allreduce");
                    if (status == NC_NOERR) status = err;
                }
                /* In collective mode, ncp->numrecs is always sync-ed among
                   processes */
                if (ncp->numrecs < max_numrecs) {
                    err = ncmpio_write_numrecs(ncp, max_numrecs);
                    if (status == NC_NOERR) status = err;
                    ncp->numrecs = max_numrecs;
                }
            }
        }

        if (NC_doFsync(ncp)) { /* NC_SHARE is set */
            TRACE_IO(MPI_File_sync)(fh);
            if (io_method == COLL_IO)
                TRACE_COMM(MPI_Barrier)(ncp->comm);
        }
    }

    FINAL_CLEAN_UP  /* swap back the put buffer and free temp buffers */

    return status;
}

/*----< ncmpio_get_vard() >--------------------------------------------------*/
int
ncmpio_get_vard(void         *ncdp,
                int           varid,
                MPI_Datatype  filetype,  /* access layout to the variable in file */
                void         *buf,
                MPI_Offset    bufcount,
                MPI_Datatype  buftype,   /* data type of the buffer */
                int           io_method) /* COLL_IO or INDEP_IO */
{
    int     err, status;
    NC     *ncp=(NC*)ncdp;
    NC_var *varp=NULL;

    status = ncmpio_sanity_check(ncp, varid, NULL, NULL, NULL, bufcount,
                                 buftype, API_VARD, 1, 1, READ_REQ, io_method,
                                 &varp);
    if (status != NC_NOERR) {
        if (io_method == INDEP_IO ||
            status == NC_EBADID    || status == NC_EPERM ||
            status == NC_EINDEFINE || status == NC_EINDEP)
            return status; /* fatal error, cannot continue */

        /* for collective API, participate the collective I/O with zero-length
         * request for this process */
        err = ncmpio_getput_zero_req(ncp, READ_REQ);
        assert(err == NC_NOERR);

        /* return the error code from sanity check */
        return status;
    }

    return ncmpio_getput_vard(ncp, varp, filetype, buf, bufcount, buftype,
                              READ_REQ, io_method);
}

/*----< ncmpio_put_vard() >--------------------------------------------------*/
int
ncmpio_put_vard(void         *ncdp,
                int           varid,
                MPI_Datatype  filetype,  /* access layout to the variable in file */
                const void   *buf,
                MPI_Offset    bufcount,
                MPI_Datatype  buftype,   /* data type of the buffer */
                int           io_method) /* COLL_IO or INDEP_IO */
{
    int     err, status;
    NC     *ncp=(NC*)ncdp;
    NC_var *varp=NULL;

    status = ncmpio_sanity_check(ncp, varid, NULL, NULL, NULL, bufcount,
                                 buftype, API_VARD, 1, 1, WRITE_REQ, io_method,
                                 &varp);
    if (status != NC_NOERR) {
        if (io_method == INDEP_IO ||
            status == NC_EBADID    || status == NC_EPERM ||
            status == NC_EINDEFINE || status == NC_EINDEP)
            return status; /* fatal error, cannot continue */

        /* for collective API, participate the collective I/O with zero-length
         * request for this process */
        err = ncmpio_getput_zero_req(ncp, WRITE_REQ);
        assert(err == NC_NOERR);

        /* return the error code from sanity check */
        return status;
    }

    return ncmpio_getput_vard(ncp, varp, filetype, (void*)buf, bufcount,
                              buftype, WRITE_REQ, io_method);
}