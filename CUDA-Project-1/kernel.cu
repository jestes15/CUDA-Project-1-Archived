﻿// Inlcusion of header files for running CUDA in Visual Studio Pro 2019 (v142)
#include "cuda_runtime.h"
#include "device_launch_parameters.h"

// Inclusion of the required CUDA libriaries and header files
#include <curand.h>
#include <cuda.h>

// Inclusion of headers from the standard library in C
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <math.h>

#include <cmath>
#include <iostream>

#define CURAND_RNG_NON_DEFAULT 24

// Windows implementation of the Linux sys/time.h fnuctions needed in this program
#include <sys/timeb.h>
#include <sys/types.h>
#include <winsock2.h>

#define __need_clock_t
#include <time.h>

/* Structure describing CPU time used by a process and its children.  */
struct tms
{
    clock_t tms_utime;          /* User CPU time.  */
    clock_t tms_stime;          /* System CPU time.  */

    clock_t tms_cutime;         /* User CPU time of dead children.  */
    clock_t tms_cstime;         /* System CPU time of dead children.  */
};

// CUDA 8+ requirment
struct timezone {
    int tz_minuteswest; /* minutes west of Greenwich */
    int tz_dsttime; /* type of DST correction */
};

int gettimeofday(struct timeval* t, void* timezone)
{
    struct _timeb timebuffer;
    _ftime(&timebuffer);
    t->tv_sec = timebuffer.time;
    t->tv_usec = 1000 * timebuffer.millitm;
    return 0;
}

/* Store the CPU time used by this process and all its
   dead children (and their dead children) in BUFFER.
   Return the elapsed real time, or (clock_t) -1 for errors.
   All times are in CLK_TCKths of a second.  */
clock_t times(struct tms* __buffer) {

    __buffer->tms_utime = clock();
    __buffer->tms_stime = 0;
    __buffer->tms_cstime = 0;
    __buffer->tms_cutime = 0;
    return __buffer->tms_utime;
}
typedef long long suseconds_t;

// Check method for checking the error status of a CUDA call
#define CUDA_CALL(x) do { if((x)!=cudaSuccess) { \
    printf("Error at %s:%d\n",__FILE__,__LINE__);\
    return EXIT_FAILURE;}} while(0)

// Check method for checking the error status of a cuRAND call
#define CURAND_CALL(x) do { if((x)!=CURAND_STATUS_SUCCESS) { \
    printf("Error at %s:%d\n",__FILE__,__LINE__);\
    return EXIT_FAILURE;}} while(0)

// The kernel, which runs on the GPU when called
__global__ void addKernel(int* a, int* b, int* c, int N)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < N) c[i] = a[i] * b[i];
}

// Function for generating the same results as the GPU kernel, used for verification of results
__host__ void KernelCPUEd(int* a, int* b, int* c, size_t size)
{
    for (int i = 0; i < size; i++)
        c[i] = a[i] * b[i];
}

// Program to convert a float array to an integer array
__host__ void FtoIArray(int* dst, float* src, int nElem) {
    for (int i = 0; i < nElem; i++)
        dst[i] = (int)(src[i] * 1000);
}

// Function for verifying the array generated by the kernel is correct
__host__ bool inline CHECK(int* a, int* b, size_t size)
{
    double epsilon = 1.0E-8;
    for (int x = 0; x < size; x++)
    {
        if (a[x] - b[x] > epsilon)
            return true;
    }
    return false;
}

__host__ double cpuSecond()
{
    struct timeval tp;
    gettimeofday(&tp, NULL);
    return ((double)tp.tv_sec + (double)tp.tv_usec * 1.e-6);
}

// Entry point to the program
int main(void) {
    size_t nElem = 1<<24;
    size_t nBytes = nElem * sizeof(int);
    size_t nBytesF = nElem * sizeof(float);

    int* h_A, * h_B, * h_C, * GpuRef;
    int* d_A, * d_B, * d_C;
    
    float* devNumGen, * devNumGen2, * h_AR, * h_BR;

    curandGenerator_t gen, gen2;

    // Allocation of memory on the host for transferring data from host to device and vice versa
    h_A = (int*)malloc(nBytes);
    h_B = (int*)malloc(nBytes);
    h_C = (int*)malloc(nBytes);
    GpuRef = (int*)malloc(nBytes);
    
    // ALlovation of memory on the device for storage of data needed by the kernel during runtime
    CUDA_CALL(cudaMalloc((int**)&d_A, nBytes));
    CUDA_CALL(cudaMalloc((int**)&d_B, nBytes));
    CUDA_CALL(cudaMalloc((int**)&d_C, nBytes));

    // Allocation of memory on host and device for testing the CUDA number generator
    h_AR = (float*)malloc(nBytes);
    h_BR = (float*)malloc(nBytes);
    CUDA_CALL(cudaMalloc((float**)&devNumGen, nBytesF));
    CUDA_CALL(cudaMalloc((float**)&devNumGen2, nBytesF));

    // CUDA number generator function calls and return values
    CURAND_CALL(curandCreateGenerator(&gen, CURAND_RNG_PSEUDO_DEFAULT));
    CURAND_CALL(curandCreateGenerator(&gen2, CURAND_RNG_PSEUDO_DEFAULT));

    CURAND_CALL(curandSetPseudoRandomGeneratorSeed(gen, time(NULL)));
    CURAND_CALL(curandSetPseudoRandomGeneratorSeed(gen2, time(NULL)+1));

    CURAND_CALL(curandGenerateUniform(gen, devNumGen, nElem));
    CURAND_CALL(curandGenerateUniform(gen2, devNumGen2, nElem));

    // Transfer random numbers generated on device to host
    CUDA_CALL(cudaMemcpy(h_AR, devNumGen, nBytesF, cudaMemcpyDeviceToHost));
    CUDA_CALL(cudaMemcpy(h_BR, devNumGen2, nBytesF, cudaMemcpyDeviceToHost));

    FtoIArray(h_A, h_AR, nElem);
    FtoIArray(h_B, h_BR, nElem);

    // Transfer of populated arrays to the device for use by the kernel
    CUDA_CALL(cudaMemcpy(d_A, h_A, nBytes, cudaMemcpyHostToDevice));
    CUDA_CALL(cudaMemcpy(d_B, h_B, nBytes, cudaMemcpyHostToDevice));

    // Calculate block indices
    int iLen = 1024;
    dim3 block(iLen);
    dim3 grid((nElem + block.x - 1) / block.x);

    // Kernel call to run the calculation n the GPU, uses 1 block and nElem amount of threads in the block
    // Max threads in a block for RTX 2060 is 1024 threads
    double iStart = cpuSecond();
    addKernel<<<grid, block>>>(d_A, d_B, d_C, nElem);
    CUDA_CALL(cudaDeviceSynchronize());
    double iEnd = cpuSecond() - iStart;

    printf("Execution time of the GPU kernel <<<%d, %d>>>: %g\n", grid.x, block.x, iEnd);

    // Verification function that the kernel on the GPU is performing properly
    double iStartCPU = cpuSecond();
    KernelCPUEd(h_A, h_B, h_C, nElem);
    double iEndCPU = cpuSecond() - iStart;
    printf("Execution time of the CPU function %g\n", iEndCPU);

    // Transfer of data from Device to the host
    CUDA_CALL(cudaDeviceSynchronize());
    CUDA_CALL(cudaMemcpy(GpuRef, d_C, nBytes, cudaMemcpyDeviceToHost));
    
    // Verification of data, compares data generated on the host to the data generated on the device
    // If the data is different, goto Exit is called and memory is freed, the the program ends
    if (CHECK(h_C, GpuRef, nElem))
    {
        std::cout << "The arrays are not the same" << std::endl;
        goto Exit;
    }

    // An output for the data generated
    /*
    for (int index = 0; index < nElem; index++)
    {
        printf("The result of %d * %d is %d\n", h_A[index], h_B[index], GpuRef[index]);
    }
    */

Exit:
    // Destroy the cuRAND number generator
    CURAND_CALL(curandDestroyGenerator(gen));
    CURAND_CALL(curandDestroyGenerator(gen2));

    //Free device memory
    CUDA_CALL(cudaFree(d_A));
    CUDA_CALL(cudaFree(d_B));
    CUDA_CALL(cudaFree(d_C));
    CUDA_CALL(cudaFree(devNumGen));
    CUDA_CALL(cudaFree(devNumGen2));

    //Free host memory
    free(h_A);
    free(h_B);
    free(h_C);
    free(GpuRef);
    free(h_AR);
    free(h_BR);

    // Allows for the user to see the output when running in Visual Studio Pro 2019 (v142)
    char a;
    scanf("%c", &a);
    
    return 0;
}