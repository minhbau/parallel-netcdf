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
 * src/dispatchers/var_getput.m4
 *
 * ncmpi_iget_var<kind>()        : dispatcher->iget_var()
 * ncmpi_iput_var<kind>()        : dispatcher->iput_var()
 * ncmpi_iget_var<kind>_<type>() : dispatcher->iget_var()
 * ncmpi_iput_var<kind>_<type>() : dispatcher->iput_var()
 */

#ifdef HAVE_CONFIG_H
# include <config.h>
#endif

#include <stdio.h>
#include <unistd.h>
#ifdef HAVE_STDLIB_H
#include <stdlib.h>
#endif
#include <limits.h> /* INT_MAX */
#include <assert.h>

#include <string.h> /* memcpy() */
#include <mpi.h>

#include <pnc_debug.h>
#include <common.h>
#include "ncmpio_NC.h"

/*----< ncmpio_abuf_malloc() >-----------------------------------------------*/
/* allocate memory space from the attached buffer pool */
int
ncmpio_abuf_malloc(NC *ncp, MPI_Offset nbytes, void **buf, int *abuf_index)
{
    /* extend the table size if more entries are needed */
    if (ncp->abuf->tail + 1 == ncp->abuf->table_size) {
        ncp->abuf->table_size += NC_ABUF_DEFAULT_TABLE_SIZE;
        ncp->abuf->occupy_table = (NC_buf_status*)
                   NCI_Realloc(ncp->abuf->occupy_table,
                   (size_t)ncp->abuf->table_size * sizeof(NC_buf_status));
    }
    /* mark the new entry is used and store the requested buffer size */
    ncp->abuf->occupy_table[ncp->abuf->tail].is_used  = 1;
    ncp->abuf->occupy_table[ncp->abuf->tail].req_size = nbytes;
    *abuf_index = ncp->abuf->tail;

    *buf = (char*)ncp->abuf->buf + ncp->abuf->size_used;
    ncp->abuf->size_used += nbytes;
    ncp->abuf->tail++;

    return NC_NOERR;
}

/*----< ncmpio_abuf_dealloc() >----------------------------------------------*/
/* deallocate (actually un-register) memory space from the attached buffer
 * pool
 */
int
ncmpio_abuf_dealloc(NC *ncp, int abuf_index)
{
    assert(abuf_index == ncp->abuf->tail - 1);

    /* mark the tail entry un-used */
    ncp->abuf->size_used -= ncp->abuf->occupy_table[abuf_index].req_size;
    ncp->abuf->occupy_table[abuf_index].req_size = 0;
    ncp->abuf->occupy_table[abuf_index].is_used  = 0;
    ncp->abuf->tail--;

    return NC_NOERR;
}

/*----< ncmpio_add_record_requests() >---------------------------------------*/
/* check if this is a record variable. if yes, add a new request for each
 * record into the list. Hereinafter, treat each request as a non-record
 * variable request
 */
int
ncmpio_add_record_requests(NC_req           *reqs,
                           MPI_Offset        num_recs,
                           const MPI_Offset *stride)
{
    char      *xbuf;
    int        i, ndims;
    size_t     dims_chunk;
    MPI_Offset rec_bufsize, *count;

    ndims = reqs[0].lead->varp->ndims;
    dims_chunk = (stride == NULL) ? ndims * 2 : ndims * 3;

    /* start[]/count[]/stride[] have been copied to reqs[0] */

    count = reqs[0].start + ndims;
    count[0] = 1; /* each non-lead request accesses one record only */

    /* calculate request size in bytes */
    rec_bufsize = reqs[0].nelems * reqs[0].lead->varp->xsz;

    /* add new requests, one per record */
    xbuf = reqs[0].xbuf + rec_bufsize;
    for (i=1; i<num_recs; i++) {
        /* copy start/count/stride */
        reqs[i].start = reqs[i-1].start + dims_chunk;
        memcpy(reqs[i].start, reqs[i-1].start, dims_chunk * sizeof(MPI_Offset));

        /* jump to next stride */
        reqs[i].start[0] += (stride == NULL) ? 1 : stride[0];

        reqs[i].nelems = reqs[0].nelems;
        reqs[i].lead   = reqs[0].lead;
        reqs[i].xbuf   = xbuf;
        xbuf          += rec_bufsize;
    }

    return NC_NOERR;
}

/*----< ncmpio_igetput_varm() >-----------------------------------------------*/
int
ncmpio_igetput_varm(NC               *ncp,
                    NC_var           *varp,
                    const MPI_Offset  start[],
                    const MPI_Offset  count[],
                    const MPI_Offset  stride[],
                    const MPI_Offset  imap[],
                    void             *buf,      /* user buffer */
                    MPI_Offset        bufcount,
                    MPI_Datatype      buftype,
                    int              *reqid,    /* out, can be NULL */
                    int               reqMode)
{
    void *xbuf=NULL;
    int i, err=NC_NOERR, abuf_index=-1, el_size, memChunk;
    int buftype_is_contig, need_convert, free_xbuf=0;
    int need_swap, in_place_swap, need_swap_back_buf=0;
    MPI_Offset nelems=0, nbytes, *ptr;
    MPI_Datatype itype, imaptype;
    NC_lead_req *lead_req;
    NC_req *req;

    /* decode buftype to obtain the followings:
     * itype:    internal element data type (MPI primitive type) in buftype
     * bufcount: If it is -1, then this is called from a high-level API and in
     *           this case buftype will be an MPI primitive data type.
     *           If it is >=0, then this is called from a flexible API.
     * nelems:   number of array elements in this request, also the number of
     *           itypes in user buffer, buf
     * nbytes:   number of bytes (in external data representation) to read from
     *           or write to the file
     * el_size:  byte size of itype
     * buftype_is_contig: whether buftype is contiguous
     */
    err = ncmpii_buftype_decode(varp->ndims, varp->xtype, count, bufcount,
                                buftype, &itype, &el_size, &nelems,
                                &nbytes, &buftype_is_contig);
    if (err != NC_NOERR) return err;

#ifndef ENABLE_LARGE_REQ
    if (nbytes > INT_MAX) DEBUG_RETURN_ERROR(NC_EMAX_REQ)
#endif

    if (nelems == 0) { /* zero-length request, mark this as a NULL request */
        *reqid = NC_REQ_NULL;
        return NC_NOERR;
    }

    /* check if type conversion and Endianness byte swap is needed */
    need_convert = ncmpii_need_convert(ncp->format, varp->xtype, itype);
    need_swap    = NEED_BYTE_SWAP(varp->xtype, itype);

    /* check if we can do byte swap in place */
    if (fIsSet(ncp->flags, NC_MODE_SWAP_ON))
        in_place_swap = 1;
    else if (fIsSet(ncp->flags, NC_MODE_SWAP_OFF))
        in_place_swap = 0;
    else { /* mode is auto */
        if (nbytes <= NC_BYTE_SWAP_BUFFER_SIZE)
            in_place_swap = 0;
        else
            in_place_swap = 1;
    }

    /* check whether this is a true varm call, if yes, imaptype will be a
     * newly created MPI derived data type from imap[] and itype, otherwise
     * it is set to MPI_DATATYPE_NULL
     */
    err = ncmpii_create_imaptype(varp->ndims, count, imap, itype, &imaptype);
    if (err != NC_NOERR) return err;

    if (fIsSet(reqMode, NC_REQ_WR)) { /* pack request to xbuf */
#if 1
        if (fIsSet(reqMode, NC_REQ_NBB)) {
            /* for bput call, check if the remaining buffer space is sufficient
             * to accommodate this request and allocate a space for xbuf
             */
            if (ncp->abuf->size_allocated - ncp->abuf->size_used < nbytes)
                DEBUG_RETURN_ERROR(NC_EINSUFFBUF)
            err = ncmpio_abuf_malloc(ncp, nbytes, &xbuf, &abuf_index);
            if (err != NC_NOERR) return err;
            need_swap_back_buf = 0; /* no need to byte-swap user buffer */
        }
        else {
            if (!buftype_is_contig || imaptype != MPI_DATATYPE_NULL ||
                need_convert || (need_swap && in_place_swap == 0)) {
                /* cannot use buf for I/O, must allocate xbuf */
                xbuf = NCI_Malloc((size_t)nbytes);
                free_xbuf = 1;
                if (xbuf == NULL) DEBUG_RETURN_ERROR(NC_ENOMEM)
                need_swap_back_buf = 0; /* no need to byte-swap user buffer */
            }
            else { /* when user buf is used as xbuf, we need to byte-swap buf
                    * back to its original contents */
                xbuf = buf;
                if (need_swap) need_swap_back_buf = 1;
            }
        }

        /* pack user buffer, buf, to xbuf which will be used to write to file.
         * In the meanwhile, perform byte-swap and type-conversion if required.
         */
        err = ncmpio_pack_xbuf(ncp->format, varp, bufcount, buftype,
                               buftype_is_contig, nelems, itype, imaptype,
                               need_convert, need_swap, nbytes, buf, xbuf);
        if (err != NC_NOERR && err != NC_ERANGE) {
            if (fIsSet(reqMode, NC_REQ_NBB))
                ncmpio_abuf_dealloc(ncp, abuf_index);
            else if (free_xbuf)
                NCI_Free(xbuf);
            return err;
        }
#else
        void *cbuf=NULL, *lbuf=NULL;
        int position;

        /* attached buffer allocation logic
         * if (fIsSet(reqMode, NC_REQ_NBB))
         *     if contig && no imap && no convert
         *         buf   ==   lbuf   ==   cbuf    ==     xbuf memcpy-> abuf
         *                                               abuf
         *     if contig && no imap &&    convert
         *         buf   ==   lbuf   ==   cbuf convert-> xbuf == abuf
         *                                               abuf
         *     if contig &&    imap && no convert
         *         buf   ==   lbuf pack-> cbuf    ==     xbuf == abuf
         *                                abuf
         *     if contig &&    imap &&    convert
         *         buf   ==   lbuf pack-> cbuf convert-> xbuf == abuf
         *                                               abuf
         *  if noncontig && no imap && no convert
         *         buf pack-> lbuf   ==   cbuf    ==     xbuf == abuf
         *                    abuf
         *  if noncontig && no imap &&    convert
         *         buf pack-> lbuf   ==   cbuf convert-> xbuf == abuf
         *                                               abuf
         *  if noncontig &&    imap && no convert
         *         buf pack-> lbuf pack-> cbuf    ==     xbuf == abuf
         *                                abuf
         *  if noncontig &&    imap &&    convert
         *         buf pack-> lbuf pack-> cbuf convert-> xbuf == abuf
         *                                               abuf
         */

        MPI_Offset ibufsize = nelems * el_size;
        if (ibufsize != (int)ibufsize) DEBUG_RETURN_ERROR(NC_EINTOVERFLOW)

        /* Step 1: if buftype is not contiguous, i.e. a noncontiguous MPI
         * derived datatype, pack buf into a contiguous buffer, lbuf,
         */
        if (!buftype_is_contig) { /* buftype is not contiguous */
            if (imaptype == MPI_DATATYPE_NULL && !need_convert)
                /* in this case, lbuf will later become xbuf */
                lbuf = xbuf;
            else {
                /* in this case, allocate lbuf and it will be freed before
                 * constructing xbuf */
                lbuf = NCI_Malloc((size_t)ibufsize);
                if (lbuf == NULL) DEBUG_RETURN_ERROR(NC_ENOMEM)
            }

            /* pack buf into lbuf based on buftype */
            if (bufcount > INT_MAX) DEBUG_RETURN_ERROR(NC_EINTOVERFLOW)
            position = 0;
            MPI_Pack(buf, (int)bufcount, buftype, lbuf, (int)ibufsize,
                     &position, MPI_COMM_SELF);
        }
        else /* for contiguous case, we reuse buf */
            lbuf = buf;

        /* Step 2: if imap is non-contiguous, pack lbuf to cbuf */
        if (imaptype != MPI_DATATYPE_NULL) { /* true varm */
            if (!need_convert)
                /* in this case, cbuf will later become xbuf */
                cbuf = xbuf;
            else {
                /* in this case, allocate cbuf and cbuf will be freed before
                 * constructing xbuf */
                cbuf = NCI_Malloc((size_t)ibufsize);
                if (cbuf == NULL) DEBUG_RETURN_ERROR(NC_ENOMEM)
            }

            /* pack lbuf to cbuf based on imaptype */
            position = 0;
            MPI_Pack(lbuf, 1, imaptype, cbuf, (int)ibufsize, &position,
                     MPI_COMM_SELF);
            MPI_Type_free(&imaptype);

            /* lbuf is no longer needed */
            if (lbuf != buf) NCI_Free(lbuf);
        }
        else /* not a true varm call: reuse lbuf */
            cbuf = lbuf;

        /* Step 3: type-convert and byte-swap cbuf to xbuf, and xbuf will be
         * used in MPI write function to write to file
         */
        if (need_convert) {
            /* user buf type does not match nc var type defined in file */
            void *fillp; /* fill value in internal representation */

            /* find the fill value */
            fillp = NCI_Malloc((size_t)varp->xsz);
            ncmpio_inq_var_fill(varp, fillp);

            /* datatype conversion + byte-swap from cbuf to xbuf */
            DATATYPE_PUT_CONVERT(ncp->format, varp->xtype, xbuf, cbuf, nelems,
                                 itype, fillp, err)
            NCI_Free(fillp);

            /* The only error codes returned from DATATYPE_PUT_CONVERT are
             * NC_EBADTYPE or NC_ERANGE. Bad varp->xtype and itype have been
             * sanity checked at the dispatchers, so NC_EBADTYPE is not
             * possible. Thus, the only possible error is NC_ERANGE.
             * NC_ERANGE can be caused by one or more elements of buf that is
             * out of range representable by the external data type, it is not
             * considered a fatal error. The request must continue to finish.
             */
            if (cbuf != buf) NCI_Free(cbuf);
#if 0
            if (err != NC_NOERR && err != NC_ERANGE) {
                if (fIsSet(reqMode, NC_REQ_NBB)) abuf_dealloc(ncp, abuf_index);
                else                             NCI_Free(xbuf);
                return err;
            }
#endif
        }
        else {
/*
            if (xbuf == NULL) xbuf = cbuf;
            else if (cbuf == buf) memcpy(xbuf, cbuf, (size_t)nbytes);
*/
            if (cbuf == buf && xbuf != buf) memcpy(xbuf, cbuf, (size_t)nbytes);

            if (need_swap) {
                /* perform array in-place byte swap on xbuf */
                ncmpii_in_swapn(xbuf, nelems, varp->xsz);

                if (xbuf == buf) need_swap_back_buf = 1;
                /* when user buf is used as xbuf, we need to byte-swap buf
                 * back to its original contents */
            }
        }
#endif
    }
    else { /* read request */
        /* Type conversion and byte swap for read are done at wait call. */
        if (buftype_is_contig && imaptype == MPI_DATATYPE_NULL && !need_convert)
            xbuf = buf;  /* there is no buffered read APIs (bget_var, etc.) */
        else {
            xbuf = NCI_Malloc((size_t)nbytes);
            free_xbuf = 1;
        }
    }

    /* add a new nonblocking request to the request queue */

    if (fIsSet(reqMode, NC_REQ_WR)) {
        /* allocate or expand the size of lead write request queue */
        if (ncp->numLeadPutReqs % NC_REQUEST_CHUNK == 0) {
            NC_lead_req *old = ncp->put_lead_list;
            ncp->put_lead_list = (NC_lead_req*) NCI_Realloc(ncp->put_lead_list,
                                 (ncp->numLeadPutReqs + NC_REQUEST_CHUNK) *
                                 sizeof(NC_lead_req));
            /* non-lead requests must also update their member lead */
            for (i=0; i<ncp->numPutReqs; i++)
                ncp->put_list[i].lead = ncp->put_lead_list +
                                        (ncp->put_list[i].lead - old);
        }

        lead_req = ncp->put_lead_list + ncp->numLeadPutReqs;

        lead_req->flag = 0;
        if (need_swap_back_buf) fSet(lead_req->flag, NC_REQ_BUF_BYTE_SWAP);

        /* the new request ID will be an even number (max of write ID + 2) */
        lead_req->id = 0;
        if (ncp->numLeadPutReqs > 0)
            lead_req->id = ncp->put_lead_list[ncp->numLeadPutReqs-1].id + 2;
        ncp->numLeadPutReqs++;

        /* allocate or expand the size of non-lead write request queue */
        int add_reqs = IS_RECVAR(varp) ? (int)count[0] : 1;
        int rem = ncp->numPutReqs % NC_REQUEST_CHUNK;
        if (rem) rem = NC_REQUEST_CHUNK - rem;

        if (ncp->put_list == NULL || add_reqs > rem) {
            size_t req_alloc, nChunks;
            req_alloc = ncp->numPutReqs + add_reqs;
            nChunks = req_alloc / NC_REQUEST_CHUNK;
            if (req_alloc % NC_REQUEST_CHUNK) nChunks++;
            req_alloc = nChunks * NC_REQUEST_CHUNK * sizeof(NC_req);
            ncp->put_list = (NC_req*) NCI_Realloc(ncp->put_list, req_alloc);
        }
        req = ncp->put_list + ncp->numPutReqs;
        lead_req->nonlead_off = ncp->numPutReqs;
        req->lead = lead_req;
        ncp->numPutReqs++;
    }
    else {  /* read request */
        /* allocate or expand the size of lead read request queue */
        if (ncp->numLeadGetReqs % NC_REQUEST_CHUNK == 0) {
            NC_lead_req *old = ncp->get_lead_list;
            ncp->get_lead_list = (NC_lead_req*) NCI_Realloc(ncp->get_lead_list,
                                 (ncp->numLeadGetReqs + NC_REQUEST_CHUNK) *
                                 sizeof(NC_lead_req));
            /* non-lead requests must also update their member lead */
            for (i=0; i<ncp->numGetReqs; i++)
                ncp->get_list[i].lead = ncp->get_lead_list +
                                        (ncp->get_list[i].lead - old);
        }

        lead_req = ncp->get_lead_list + ncp->numLeadGetReqs;

        lead_req->flag = 0;
        if (need_convert) fSet(lead_req->flag, NC_REQ_BUF_TYPE_CONVERT);
        if (need_swap)    fSet(lead_req->flag, NC_REQ_BUF_BYTE_SWAP);

        /* the new request ID will be an odd number (max of read ID + 2) */
        lead_req->id = 1;
        if (ncp->numLeadGetReqs > 0)
            lead_req->id = ncp->get_lead_list[ncp->numLeadGetReqs-1].id + 2;
        ncp->numLeadGetReqs++;

        /* allocate or expand the size of non-lead read request queue */
        int add_reqs = IS_RECVAR(varp) ? (int)count[0] : 1;
        int rem = ncp->numGetReqs % NC_REQUEST_CHUNK;
        if (rem) rem = NC_REQUEST_CHUNK - rem;

        if (ncp->get_list == NULL || add_reqs > rem) {
            size_t req_alloc, nChunks;
            req_alloc = ncp->numGetReqs + add_reqs;
            nChunks = req_alloc / NC_REQUEST_CHUNK;
            if (req_alloc % NC_REQUEST_CHUNK) nChunks++;
            req_alloc = nChunks * NC_REQUEST_CHUNK * sizeof(NC_req);
            ncp->get_list = (NC_req*) NCI_Realloc(ncp->get_list, req_alloc);
        }
        req = ncp->get_list + ncp->numGetReqs;
        lead_req->nonlead_off = ncp->numGetReqs;
        req->lead = lead_req;
        ncp->numGetReqs++;
    }

    /* set other properties for the lead request */

    lead_req->varp        = varp;
    lead_req->buf         = buf;
    lead_req->bufcount    = bufcount;
    lead_req->itype       = itype;
    lead_req->imaptype    = imaptype;
    lead_req->abuf_index  = abuf_index;
    lead_req->status      = NULL;
    lead_req->nelems      = nelems;
    lead_req->xbuf        = xbuf;
    lead_req->buftype     = MPI_DATATYPE_NULL;

    /* only lead request free xbuf (when xbuf != buf) */
    if (free_xbuf) fSet(lead_req->flag, NC_REQ_XBUF_TO_BE_FREED);

    if (stride == NULL) fSet(lead_req->flag, NC_REQ_STRIDE_NULL);
    else {
        int i;
        for (i=0; i<varp->ndims; i++)
            if (stride[i] > 1) break;
        if (i == varp->ndims) { /* all 1s */
            fSet(lead_req->flag, NC_REQ_STRIDE_NULL);
            stride = NULL;
        }
    }

    /* for read requst and buftype is not contiguous, we duplicate buftype for
     * later in the wait call to unpack buffer based on buftype
     */
    if (buftype_is_contig)
        fSet(lead_req->flag, NC_REQ_BUF_TYPE_IS_CONTIG);
    else if (fIsSet(reqMode, NC_REQ_RD))
        MPI_Type_dup(buftype, &lead_req->buftype);

    /* allocate a single array to store start/count/stride */
    memChunk = (stride == NULL) ? 2 : 3;
    memChunk *= varp->ndims * SIZEOF_MPI_OFFSET;
    if (IS_RECVAR(varp) && count[0] > 1)
        lead_req->start = (MPI_Offset*) NCI_Malloc(memChunk * count[0]);
    else
        lead_req->start = (MPI_Offset*) NCI_Malloc(memChunk);

    /* set the properties of non-lead request */
    req->xbuf = xbuf;

    /* copy over start/count/stride */
    req->start = lead_req->start;
    ptr = req->start;
    memcpy(ptr, start, varp->ndims * SIZEOF_MPI_OFFSET);
    ptr += varp->ndims;
    memcpy(ptr, count, varp->ndims * SIZEOF_MPI_OFFSET);
    if (stride != NULL) {
        ptr += varp->ndims;
        memcpy(ptr, stride, varp->ndims * SIZEOF_MPI_OFFSET);
    }
    req->nelems = nelems;

    if (IS_RECVAR(varp)) {
        /* save the last record number accessed */
        lead_req->nonlead_num = count[0];
        if (stride == NULL)
            lead_req->max_rec = start[0] + count[0];
        else
            lead_req->max_rec = start[0] + stride[0] * (count[0] - 1) + 1;

        if (count[0] > 1) {
            /* If this is a record variable and the number of requesting
             * records is more than 1, we split this lead request into multiple
             * non-lead requests, one for each record. count[0] in all non-lead
             * requests are set to 1.
             */
            req->nelems /= count[0];

            /* add (count[0]-1) number of (sub)requests */
            ncmpio_add_record_requests(req, count[0], stride);

            if (fIsSet(reqMode, NC_REQ_WR)) ncp->numPutReqs += count[0] - 1;
            else                            ncp->numGetReqs += count[0] - 1;
        }
    }
    else { /* fixed-size variable */
        lead_req->max_rec     = -1;
        lead_req->nonlead_num = 1;
    }

    /* return the request ID */
    if (reqid != NULL) *reqid = lead_req->id;

    return err;
}

include(`utils.m4')dnl
dnl
dnl IGETPUT_API(get/put)
dnl
define(`IGETPUT_API',dnl
`dnl
/*----< ncmpio_i$1_var() >---------------------------------------------------*/
/* start  can be NULL only when api is NC_VAR
 * count  can be NULL only when api is NC_VAR or NC_VAR1
 * stride can be NULL only when api is NC_VAR, NC_VAR1, or NC_VARA
 * imap   can be NULL only when api is NC_VAR, NC_VAR1, NC_VARA, or NC_VARS
 * bufcount is >= 0 when called from a flexible API, is -1 when called from a
 *         high-level API and in this case buftype is an MPI primitive
 *         datatype.
 * buftype is an MPI primitive data type (corresponding to the internal data
 *         type of buf, e.g. short in ncmpi_put_short is mapped to MPI_SHORT)
 *         if called from a high-level APIs. When called from a flexible API
 *         it can be an MPI derived data type or MPI_DATATYPE_NULL. If it is
 *         MPI_DATATYPE_NULL, then it means the data type of buf in memory
 *         matches the variable external data type. In this case, bufcount is
 *         ignored.
 * reqMode indicates modes (NC_REQ_COLL/NC_REQ_INDEP/NC_REQ_WR etc.)
 */
int
ncmpio_i$1_var(void             *ncdp,
               int               varid,
               const MPI_Offset *start,
               const MPI_Offset *count,
               const MPI_Offset *stride,
               const MPI_Offset *imap,
               ifelse(`$1',`put',`const') void *buf,
               MPI_Offset        bufcount,
               MPI_Datatype      buftype,
               int              *reqid,
               int               reqMode)
{
    NC *ncp=(NC*)ncdp;

    /* Note sanity check for ncdp and varid has been done in dispatchers */

    return ncmpio_igetput_varm(ncp, ncp->vars.value[varid], start, count,
                               stride, imap, (void*)buf, bufcount, buftype,
                               reqid, reqMode);
}
')dnl
dnl

IGETPUT_API(put)
IGETPUT_API(get)

