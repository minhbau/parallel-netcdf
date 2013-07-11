/*********************************************************************
 *
 *  Copyright (C) 2013, Northwestern University
 *  See COPYRIGHT notice in top-level directory.
 *
 *********************************************************************/
/* $Id$ */

#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <mpi.h>
#include <pnetcdf.h>

#define NY 4
#define NX 10
#define NDIMS 2

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *
 * This example shows how to use a single call of ncmpi_put_varn_float_all()
 * to write a sequence of one-element requests with arbitrary array indices.
 *
 * The compile and run commands are given below, together with an ncmpidump of
 * the output file.
 *
 *    % mpicc -g -o put_varn_float put_varn_float.c -lpnetcdf
 *    % mpiexec -l -n 4 put_varn_float testfile.nc
 *    % ncmpidump testfile.nc
 *    netcdf testfile {
 *    // file format: CDF-5 (big variables)
 *    dimensions:
 *             Y = 4 ;
 *             X = 10 ;
 *    variables:
 *             int var(Y, X) ;
 *    data:
 *
 *     var =
 *       3, 3, 3, 1, 1, 0, 0, 2, 1, 1,
 *       0, 2, 2, 2, 3, 1, 1, 2, 2, 2,
 *       1, 1, 2, 3, 3, 3, 0, 0, 1, 1,
 *       0, 0, 0, 2, 1, 1, 1, 3, 3, 3 ;
 *    }
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */


#define ERR {if(err!=NC_NOERR)printf("Error at line=%d: %s\n", __LINE__, ncmpi_strerror(err));}

int main(int argc, char** argv) {
    int i, rank, nprocs, err;
    int ncid, cmode, varid, dimid[2], num_reqs;
    float *buffer;
    MPI_Offset **starts;

    MPI_Init(&argc, &argv);
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &nprocs);

    if (argc != 2) {
        if (!rank) printf("Usage: %s filename\n",argv[0]);
        MPI_Finalize();
        return 0;
    }
    if (nprocs != 4 && rank == 0)
        printf("Warning: this program is intended to run on 4 processes\n");

    /* create a new file for writing ----------------------------------------*/
    cmode = NC_CLOBBER;
    err = ncmpi_create(MPI_COMM_WORLD, argv[1], cmode, MPI_INFO_NULL, &ncid);
    ERR

    /* create a global array of size NY * NX */
    err = ncmpi_def_dim(ncid, "Y", NY, &dimid[0]);
    ERR
    err = ncmpi_def_dim(ncid, "X", NX, &dimid[1]);
    ERR
    err = ncmpi_def_var(ncid, "var", NC_FLOAT, NDIMS, dimid, &varid);
    ERR
    err = ncmpi_enddef(ncid);
    ERR

    /* pick arbitrary numbers of requests for 4 processes */
    num_reqs = 1;
    if (rank == 0)     num_reqs = 8;
    else if (rank ==1) num_reqs = 13;
    else if (rank ==2) num_reqs = 9;
    else if (rank ==3) num_reqs = 10;

    starts    = (MPI_Offset**) malloc(num_reqs *        sizeof(MPI_Offset*));
    starts[0] = (MPI_Offset*)  calloc(num_reqs * NDIMS, sizeof(MPI_Offset));
    for (i=1; i<num_reqs; i++)
        starts[i] = starts[i-1] + NDIMS;

    /* assign arbitrary starts */
    const int y=0, x=1;
    if (rank == 0) {
        starts[0][y] = 0; starts[0][x] = 5;
        starts[1][y] = 1; starts[1][x] = 0;
        starts[2][y] = 2; starts[2][x] = 6;
        starts[3][y] = 3; starts[3][x] = 0;
        starts[4][y] = 0; starts[4][x] = 6;
        starts[5][y] = 2; starts[5][x] = 7;
        starts[6][y] = 3; starts[6][x] = 1;
        starts[7][y] = 3; starts[7][x] = 2;
        /* rank 0 is writing the following locations: ("-" means skip)
                  -  -  -  -  -  0  0  -  -  - 
                  0  -  -  -  -  -  -  -  -  - 
                  -  -  -  -  -  -  0  0  -  - 
                  0  0  0  -  -  -  -  -  -  - 
         */
    } else if (rank ==1) {
        starts[ 0][y] = 0; starts[ 0][x] = 3;
        starts[ 1][y] = 0; starts[ 1][x] = 8;
        starts[ 2][y] = 1; starts[ 2][x] = 5;
        starts[ 3][y] = 2; starts[ 3][x] = 0;
        starts[ 4][y] = 2; starts[ 4][x] = 8;
        starts[ 5][y] = 3; starts[ 5][x] = 4;
        starts[ 6][y] = 0; starts[ 6][x] = 4;
        starts[ 7][y] = 0; starts[ 7][x] = 9;
        starts[ 8][y] = 1; starts[ 8][x] = 6;
        starts[ 9][y] = 2; starts[ 9][x] = 1;
        starts[10][y] = 2; starts[10][x] = 9;
        starts[11][y] = 3; starts[11][x] = 5;
        starts[12][y] = 3; starts[12][x] = 6;
        /* rank 1 is writing the following locations: ("-" means skip)
                  -  -  -  1  1  -  -  -  1  1 
                  -  -  -  -  -  1  1  -  -  - 
                  1  1  -  -  -  -  -  -  1  1 
                  -  -  -  -  1  1  1  -  -  - 
         */
    } else if (rank ==2) {
        starts[0][y] = 0; starts[0][x] = 7;
        starts[1][y] = 1; starts[1][x] = 1;
        starts[2][y] = 1; starts[2][x] = 7;
        starts[3][y] = 2; starts[3][x] = 2; 
        starts[4][y] = 3; starts[4][x] = 3;
        starts[5][y] = 1; starts[5][x] = 2;
        starts[6][y] = 1; starts[6][x] = 8;
        starts[7][y] = 1; starts[7][x] = 3;
        starts[8][y] = 1; starts[8][x] = 9;
        /* rank 2 is writing the following locations: ("-" means skip)
                  -  -  -  -  -  -  -  2  -  - 
                  -  2  2  2  -  -  -  2  2  2 
                  -  -  2  -  -  -  -  -  -  - 
                  -  -  -  2  -  -  -  -  -  - 
         */
    } else if (rank ==3) {
        starts[0][y] = 0; starts[0][x] = 0;
        starts[1][y] = 1; starts[1][x] = 4;
        starts[2][y] = 2; starts[2][x] = 3;
        starts[3][y] = 3; starts[3][x] = 7;
        starts[4][y] = 0; starts[4][x] = 1;
        starts[5][y] = 2; starts[5][x] = 4;
        starts[6][y] = 3; starts[6][x] = 8;
        starts[7][y] = 0; starts[7][x] = 2;
        starts[8][y] = 2; starts[8][x] = 5;
        starts[9][y] = 3; starts[9][x] = 9;
        /* rank 3 is writing the following locations: ("-" means skip)
                  3  3  3  -  -  -  -  -  -  - 
                  -  -  -  -  3  -  -  -  -  - 
                  -  -  -  3  3  3  -  -  -  - 
                  -  -  -  -  -  -  -  3  3  3 
         */
    }

    /* allocate I/O buffer and initialize its contents */
    buffer = (float*) malloc(num_reqs * sizeof(float));
    for (i=0; i<num_reqs; i++) buffer[i] =  (float)rank;

    /* set the buffer pointers to different offsets to the I/O buffer */
    err = ncmpi_put_varn_float_all(ncid, varid, num_reqs, starts, NULL, buffer);
    ERR

    err = ncmpi_close(ncid);
    ERR

    free(buffer);
    free(starts[0]);
    free(starts);

    MPI_Finalize();
    return 0;
}
