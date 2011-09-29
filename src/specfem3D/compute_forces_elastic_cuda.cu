#include <stdio.h>
#include <cuda.h>
#include <cublas.h>
#include <mpi.h>

#include <sys/time.h>
#include <sys/resource.h>

#include "mesh_constants_cuda.h"

// #include "epik_user.h"

typedef float real;


#define NGLL2 25

__constant__ float d_hprime_xx[NGLL2];
__constant__ float d_hprimewgll_xx[NGLL2];
__constant__ float d_wgllwgll_xy[NGLL2];
__constant__ float d_wgllwgll_xz[NGLL2];
__constant__ float d_wgllwgll_yz[NGLL2];

#define MAXDEBUG 1
#define ENABLE_VERY_SLOW_ERROR_CHECKING

#if MAXDEBUG == 1
#define LOG(x) printf("%s\n",x)
#define PRINT5(var,offset) for(;print_count<5;print_count++) printf("var(%d)=%2.20f\n",print_count,var[offset+print_count]);
#define PRINT10(var) if(print_count<10) { printf("var=%1.20e\n",var); print_count++; }
#define PRINT10i(var) if(print_count<10) { printf("var=%d\n",var); print_count++; }
#else
#define LOG(x) // printf("%s\n",x);
#define PRINT5(var,offset) // for(i=0;i<10;i++) printf("var(%d)=%f\n",i,var[offset+i]);
#endif

void Kernel_2(int nb_blocks_to_compute, Mesh* mp, int d_iphase,
	      int COMPUTE_AND_STORE_STRAIN,int SIMULATION_TYPE);



double get_time()
{
    struct timeval t;
    struct timezone tzp;
    gettimeofday(&t, &tzp);
    return t.tv_sec + t.tv_usec*1e-6;
}


// prepares a device array with with all inter-element edge-nodes -- this
// is followed by a memcpy and MPI operations
__global__ void prepare_boundary_accel_on_device(float* d_accel, float* d_send_accel_buffer,
						 int num_interfaces_ext_mesh, int max_nibool_interfaces_ext_mesh,
						 int* d_nibool_interfaces_ext_mesh,
						 int* d_ibool_interfaces_ext_mesh) {

  int id = threadIdx.x + blockIdx.x*blockDim.x + blockIdx.y*gridDim.x*blockDim.x;
  int bx = blockIdx.y*gridDim.x+blockIdx.x;
  int tx = threadIdx.x;
  int iinterface=0;  
  
  for( iinterface=0; iinterface < num_interfaces_ext_mesh; iinterface++) {
    if(id<d_nibool_interfaces_ext_mesh[iinterface]) {
      d_send_accel_buffer[3*(id + max_nibool_interfaces_ext_mesh*iinterface)] =
	d_accel[3*(d_ibool_interfaces_ext_mesh[id+max_nibool_interfaces_ext_mesh*iinterface]-1)];
      d_send_accel_buffer[3*(id + max_nibool_interfaces_ext_mesh*iinterface)+1] =
	d_accel[3*(d_ibool_interfaces_ext_mesh[id+max_nibool_interfaces_ext_mesh*iinterface]-1)+1];
      d_send_accel_buffer[3*(id + max_nibool_interfaces_ext_mesh*iinterface)+2] =
	d_accel[3*(d_ibool_interfaces_ext_mesh[id+max_nibool_interfaces_ext_mesh*iinterface]-1)+2];
    }
  }  

}

// prepares and transfers the inter-element edge-nodes to the host to be MPI'd
extern "C" void transfer_boundary_accel_from_device_(int* size, long* Mesh_pointer_f, float* accel,
					  float* send_accel_buffer,
					  int* num_interfaces_ext_mesh,
					  int* max_nibool_interfaces_ext_mesh,
					  int* nibool_interfaces_ext_mesh,
					  int* ibool_interfaces_ext_mesh,
					  int* FORWARD_OR_ADJOINT)
					  
{
  Mesh* mp = (Mesh*)(*Mesh_pointer_f); //get mesh pointer out of fortran integer container
  

  
  int blocksize = 256;
  int size_padded = ((int)ceil(((double)*max_nibool_interfaces_ext_mesh)/((double)blocksize)))*blocksize;
  int num_blocks_x = size_padded/blocksize;
  int num_blocks_y = 1;
  while(num_blocks_x > 65535) {
    num_blocks_x = ceil(num_blocks_x/2.0);
    num_blocks_y = num_blocks_y*2;
  }
  
  dim3 grid(num_blocks_x,num_blocks_y);
  dim3 threads(blocksize,1,1);
  
  //timing for memory xfer
  // cudaEvent_t start, stop; 
  // float time; 
  // cudaEventCreate(&start); 
  // cudaEventCreate(&stop); 
  // cudaEventRecord( start, 0 );
  if(*FORWARD_OR_ADJOINT == 1) {
  prepare_boundary_accel_on_device<<<grid,threads>>>(mp->d_accel,mp->d_send_accel_buffer,
						     *num_interfaces_ext_mesh,
						     *max_nibool_interfaces_ext_mesh,
						     mp->d_nibool_interfaces_ext_mesh,
						     mp->d_ibool_interfaces_ext_mesh);
  }
  else if(*FORWARD_OR_ADJOINT == 3) {
    prepare_boundary_accel_on_device<<<grid,threads>>>(mp->d_b_accel,mp->d_send_accel_buffer,
						     *num_interfaces_ext_mesh,
						     *max_nibool_interfaces_ext_mesh,
						     mp->d_nibool_interfaces_ext_mesh,
						     mp->d_ibool_interfaces_ext_mesh);
  }
  
#ifdef ENABLE_VERY_SLOW_ERROR_CHECKING
  exit_on_cuda_error("prepare_adjoint_constants_device");  
  // // sync and check to catch errors from previous async operations
  // cudaThreadSynchronize();
  
  // // printf("Elapsed time for xfer d->h: %f\n",end-start);
  // cudaError_t err = cudaGetLastError();
  // if (err != cudaSuccess)
  //   {
  //     fprintf(stderr,"Error launching/running prepare_boundary_kernel: %s\n", cudaGetErrorString(err));
  //     exit(1);
  //   }
#endif

  
  cudaMemcpy(send_accel_buffer,mp->d_send_accel_buffer,
	     3* *max_nibool_interfaces_ext_mesh* *num_interfaces_ext_mesh*sizeof(real),cudaMemcpyDeviceToHost);
  
  // finish timing of kernel+memcpy
  // cudaEventRecord( stop, 0 );
  // cudaEventSynchronize( stop );
  // cudaEventElapsedTime( &time, start, stop );
  // cudaEventDestroy( start );
  // cudaEventDestroy( stop );
  // printf("boundary xfer d->h Time: %f ms\n",time);
  
}
__global__ void assemble_boundary_accel_on_device(float* d_accel, float* d_send_accel_buffer,
						 int num_interfaces_ext_mesh, int max_nibool_interfaces_ext_mesh,
						 int* d_nibool_interfaces_ext_mesh,
						 int* d_ibool_interfaces_ext_mesh) {

  int id = threadIdx.x + blockIdx.x*blockDim.x + blockIdx.y*gridDim.x*blockDim.x;
  int bx = blockIdx.y*gridDim.x+blockIdx.x;
  int tx = threadIdx.x;
  int iinterface=0;  

  for( iinterface=0; iinterface < num_interfaces_ext_mesh; iinterface++) {
    if(id<d_nibool_interfaces_ext_mesh[iinterface]) {

      // for testing atomic operations against not atomic operations (0.1ms vs. 0.04 ms)
      // d_accel[3*(d_ibool_interfaces_ext_mesh[id+max_nibool_interfaces_ext_mesh*iinterface]-1)] +=
      // d_send_accel_buffer[3*(id + max_nibool_interfaces_ext_mesh*iinterface)];
      // d_accel[3*(d_ibool_interfaces_ext_mesh[id+max_nibool_interfaces_ext_mesh*iinterface]-1)+1] +=
      // d_send_accel_buffer[3*(id + max_nibool_interfaces_ext_mesh*iinterface)+1];
      // d_accel[3*(d_ibool_interfaces_ext_mesh[id+max_nibool_interfaces_ext_mesh*iinterface]-1)+2] +=
      // d_send_accel_buffer[3*(id + max_nibool_interfaces_ext_mesh*iinterface)+2];
      
      
      atomicAdd(&d_accel[3*(d_ibool_interfaces_ext_mesh[id+max_nibool_interfaces_ext_mesh*iinterface]-1)],
		d_send_accel_buffer[3*(id + max_nibool_interfaces_ext_mesh*iinterface)]);
      atomicAdd(&d_accel[3*(d_ibool_interfaces_ext_mesh[id+max_nibool_interfaces_ext_mesh*iinterface]-1)+1],
		d_send_accel_buffer[3*(id + max_nibool_interfaces_ext_mesh*iinterface)+1]);
      atomicAdd(&d_accel[3*(d_ibool_interfaces_ext_mesh[id+max_nibool_interfaces_ext_mesh*iinterface]-1)+2],
		d_send_accel_buffer[3*(id + max_nibool_interfaces_ext_mesh*iinterface)+2]);
    }
  }
  // ! This step is done via previous function transfer_and_assemble...
  // ! do iinterface = 1, num_interfaces_ext_mesh
  // !   do ipoin = 1, nibool_interfaces_ext_mesh(iinterface)
  // !     array_val(:,ibool_interfaces_ext_mesh(ipoin,iinterface)) = &
  // !          array_val(:,ibool_interfaces_ext_mesh(ipoin,iinterface)) + buffer_recv_vector_ext_mesh(:,ipoin,iinterface)
  // !   enddo
  // ! enddo
}


// FORWARD_OR_ADJOINT == 1 for accel, and == 3 for b_accel
extern "C"
void transfer_and_assemble_accel_to_device_(long* Mesh_pointer, real* accel,
					    real* buffer_recv_vector_ext_mesh,
					    int* num_interfaces_ext_mesh,
					    int* max_nibool_interfaces_ext_mesh,
					    int* nibool_interfaces_ext_mesh,
					    int* ibool_interfaces_ext_mesh,int* FORWARD_OR_ADJOINT) {
  Mesh* mp = (Mesh*)(*Mesh_pointer); //get mesh pointer out of fortran integer container
  
  cudaMemcpy(mp->d_send_accel_buffer, buffer_recv_vector_ext_mesh, 3* *max_nibool_interfaces_ext_mesh* *num_interfaces_ext_mesh*sizeof(real), cudaMemcpyHostToDevice);

  int blocksize = 256;
  int size_padded = ((int)ceil(((double)*max_nibool_interfaces_ext_mesh)/((double)blocksize)))*blocksize;
  int num_blocks_x = size_padded/blocksize;
  int num_blocks_y = 1;
  while(num_blocks_x > 65535) {
    num_blocks_x = ceil(num_blocks_x/2.0);
    num_blocks_y = num_blocks_y*2;
  }

  double start_time = get_time();
  dim3 grid(num_blocks_x,num_blocks_y);
  dim3 threads(blocksize,1,1);
  // cudaEvent_t start, stop; 
  // float time; 
  // cudaEventCreate(&start); 
  // cudaEventCreate(&stop); 
  // cudaEventRecord( start, 0 );
  if(*FORWARD_OR_ADJOINT == 1) { //assemble forward accel
    assemble_boundary_accel_on_device<<<grid,threads>>>(mp->d_accel, mp->d_send_accel_buffer,
							*num_interfaces_ext_mesh,
							*max_nibool_interfaces_ext_mesh,
							mp->d_nibool_interfaces_ext_mesh,
							mp->d_ibool_interfaces_ext_mesh);
  }
  else if(*FORWARD_OR_ADJOINT == 3) { //assemble adjoint accel
    assemble_boundary_accel_on_device<<<grid,threads>>>(mp->d_b_accel, mp->d_send_accel_buffer,
							*num_interfaces_ext_mesh,
							*max_nibool_interfaces_ext_mesh,
							mp->d_nibool_interfaces_ext_mesh,
							mp->d_ibool_interfaces_ext_mesh);
  }

  // cudaEventRecord( stop, 0 );
  // cudaEventSynchronize( stop );
  // cudaEventElapsedTime( &time, start, stop );
  // cudaEventDestroy( start );
  // cudaEventDestroy( stop );
  // printf("Boundary Assemble Kernel Execution Time: %f ms\n",time);
#ifdef ENABLE_VERY_SLOW_ERROR_CHECKING
  // sync and check to catch errors from previous async operations
  cudaThreadSynchronize();
  double end_time = get_time();
  //printf("Elapsed time: %e\n",end_time-start_time);
  cudaError_t err = cudaGetLastError();
  if (err != cudaSuccess)
    {
      fprintf(stderr,"Error launching/running prepare_boundary_kernel: %s\n", cudaGetErrorString(err));
      exit(1);
    }
#endif
  
}





extern "C" void compute_forces_elastic_cuda_(long* Mesh_pointer_f,
					     int* iphase,
					     int* nspec_outer_elastic,
					     int* nspec_inner_elastic,
					     int* COMPUTE_AND_STORE_STRAIN,
					     int* SIMULATION_TYPE) {
  
  // EPIK_TRACER("compute_forces_elastic_cuda");
  //printf("Running compute_forces\n");
  
  Mesh* mp = (Mesh*)(*Mesh_pointer_f); // get Mesh from fortran integer wrapper

  int num_elements;
  
  if( *iphase == 1 )
    num_elements = *nspec_outer_elastic;
  else
    num_elements = *nspec_inner_elastic;  
  int myrank;
  
  /* MPI_Comm_rank(MPI_COMM_WORLD,&myrank); */
  /* if(myrank==0) { */
  
  

  Kernel_2(num_elements, mp, *iphase, *COMPUTE_AND_STORE_STRAIN,*SIMULATION_TYPE);
  
  
  cudaThreadSynchronize();
/* MPI_Barrier(MPI_COMM_WORLD); */
}

__global__ void Kernel_test(float* d_debug_output,int* d_phase_ispec_inner_elastic, int num_phase_ispec_elastic, int d_iphase, int* d_ibool);

__global__ void Kernel_2_impl(int nb_blocks_to_compute,int NGLOB, int* d_ibool,int* d_phase_ispec_inner_elastic, int num_phase_ispec_elastic, int d_iphase,float* d_displ, float* d_accel, float* d_xix, float* d_xiy, float* d_xiz, float* d_etax, float* d_etay, float* d_etaz, float* d_gammax, float* d_gammay, float* d_gammaz, float* d_kappav, float* d_muv,float* d_debug,int COMPUTE_AND_STORE_STRAIN,float* epsilondev_xx,float* epsilondev_yy,float* epsilondev_xy,float* epsilondev_xz,float* epsilondev_yz,float* epsilon_trace_over_3,int SIMULATION_TYPE);

void Kernel_2(int nb_blocks_to_compute, Mesh* mp, int d_iphase,
	      int COMPUTE_AND_STORE_STRAIN,int SIMULATION_TYPE)
  {
    
#ifdef ENABLE_VERY_SLOW_ERROR_CHECKING
    // sync and check to catch errors from previous async operations
    cudaThreadSynchronize();
    cudaError_t err = cudaGetLastError();
    if (err != cudaSuccess)
      {
	fprintf(stderr,"Error before kernel Kernel 2: %s\n", cudaGetErrorString(err));
	exit(1);
      }
#endif
    
    /* if the grid can handle the number of blocks, we let it be 1D */
    /* grid_2_x = nb_elem_color; */
    /* nb_elem_color is just how many blocks we are computing now */    

    int num_blocks_x = nb_blocks_to_compute;
    int num_blocks_y = 1;
    while(num_blocks_x > 65535) {
      num_blocks_x = ceil(num_blocks_x/2.0);
      num_blocks_y = num_blocks_y*2;
    }
    
    int threads_2 = 128;//BLOCK_SIZE_K2;
    dim3 grid_2(num_blocks_x,num_blocks_y);    

    // debugging
    //printf("Starting with grid %dx%d for %d blocks\n",num_blocks_x,num_blocks_y,nb_blocks_to_compute);
    float* d_debug, *h_debug;
    h_debug = (float*)calloc(128,sizeof(float));
    cudaMalloc((void**)&d_debug,128*sizeof(float));
    cudaMemcpy(d_debug,h_debug,128*sizeof(float),cudaMemcpyHostToDevice);
    
    // Cuda timing
    // cudaEvent_t start, stop; 
    // float time; 
    // cudaEventCreate(&start); 
    // cudaEventCreate(&stop); 
    // cudaEventRecord( start, 0 );
    
    Kernel_2_impl<<< grid_2, threads_2, 0, 0 >>>(nb_blocks_to_compute,mp->NGLOB_AB, mp->d_ibool,
						 mp->d_phase_ispec_inner_elastic,
						 mp->d_num_phase_ispec_elastic, d_iphase,
						 mp->d_displ, mp->d_accel,
						 mp->d_xix, mp->d_xiy, mp->d_xiz,
						 mp->d_etax, mp->d_etay, mp->d_etaz,
						 mp->d_gammax, mp->d_gammay, mp->d_gammaz,
						 mp->d_kappav, mp->d_muv,d_debug,
						 COMPUTE_AND_STORE_STRAIN,
						 mp->d_epsilondev_xx,
						 mp->d_epsilondev_yy,
						 mp->d_epsilondev_xy,
						 mp->d_epsilondev_xz,
						 mp->d_epsilondev_yz,
						 mp->d_epsilon_trace_over_3,
						 // 1);
						 SIMULATION_TYPE);
    

    // cudaMemcpy(h_debug,d_debug,128*sizeof(float),cudaMemcpyDeviceToHost);
    // int procid;
    // MPI_Comm_rank(MPI_COMM_WORLD,&procid);
    // if(procid==0) {
    //   for(int i=0;i<17;i++) {
    // 	printf("cudadebug[%d] = %e\n",i,h_debug[i]);
    //   }
    // }
    free(h_debug);
    cudaFree(d_debug);
 #ifdef ENABLE_VERY_SLOW_ERROR_CHECKING
    exit_on_cuda_error("Kernel_2_impl");
 #endif
    
    if(SIMULATION_TYPE == 3) {
      Kernel_2_impl<<< grid_2, threads_2, 0, 0 >>>(nb_blocks_to_compute,mp->NGLOB_AB, mp->d_ibool,
						   mp->d_phase_ispec_inner_elastic,
						   mp->d_num_phase_ispec_elastic, d_iphase,
						   mp->d_b_displ, mp->d_b_accel,
						   mp->d_xix, mp->d_xiy, mp->d_xiz,
						   mp->d_etax, mp->d_etay, mp->d_etaz,
						   mp->d_gammax, mp->d_gammay, mp->d_gammaz,
						   mp->d_kappav, mp->d_muv,d_debug,
						   COMPUTE_AND_STORE_STRAIN,
						   mp->d_b_epsilondev_xx,
						   mp->d_b_epsilondev_yy,
						   mp->d_b_epsilondev_xy,
						   mp->d_b_epsilondev_xz,
						   mp->d_b_epsilondev_yz,
						   mp->d_b_epsilon_trace_over_3,
						   SIMULATION_TYPE);
    }
    
    // cudaEventRecord( stop, 0 );
    // cudaEventSynchronize( stop );
    // cudaEventElapsedTime( &time, start, stop );
    // cudaEventDestroy( start );
    // cudaEventDestroy( stop );
    // printf("Kernel2 Execution Time: %f ms\n",time);
    
    // cudaMemcpy(h_debug,d_debug,128*sizeof(float),cudaMemcpyDeviceToHost);
    // for(int i=0;i<10;i++) {
    // printf("debug[%d]=%e\n",i,h_debug[i]);
    // }            
    
    /* cudaThreadSynchronize(); */
    /* LOG("Kernel 2 finished"); */
#ifdef ENABLE_VERY_SLOW_ERROR_CHECKING    
    exit_on_cuda_error("Kernel_2_impl SIM_TYPE==3");    
 #endif    

  }

__global__ void Kernel_test(float* d_debug_output,int* d_phase_ispec_inner_elastic, int num_phase_ispec_elastic, int d_iphase, int* d_ibool) {
  int bx = blockIdx.x;
  int tx = threadIdx.x;
  int working_element;
  int ispec;
  int NGLL3_ALIGN = 128;
  if(tx==0 && bx==0) {

    d_debug_output[0] = 420.0;

    d_debug_output[2] = num_phase_ispec_elastic;
    d_debug_output[3] = d_iphase;
    working_element = d_phase_ispec_inner_elastic[bx + num_phase_ispec_elastic*(d_iphase-1)]-1;
    d_debug_output[4] = working_element;
    d_debug_output[5] = d_phase_ispec_inner_elastic[0];
    /* d_debug_output[1] = d_ibool[working_element*NGLL3_ALIGN + tx]-1; */
  }
  /* d_debug_output[1+tx+128*bx] = 69.0; */
  
}

// double precision temporary variables leads to 10% performance
// decrease in Kernel_2_impl (not very much..)
typedef float reald;

// doesn't seem to change the performance.
// #define MANUALLY_UNROLLED_LOOPS

__global__ void Kernel_2_impl(int nb_blocks_to_compute,int NGLOB, int* d_ibool,int* d_phase_ispec_inner_elastic, int num_phase_ispec_elastic, int d_iphase,float* d_displ, float* d_accel, float* d_xix, float* d_xiy, float* d_xiz, float* d_etax, float* d_etay, float* d_etaz, float* d_gammax, float* d_gammay, float* d_gammaz, float* d_kappav, float* d_muv,float* d_debug,int COMPUTE_AND_STORE_STRAIN,float* epsilondev_xx,float* epsilondev_yy,float* epsilondev_xy,float* epsilondev_xz,float* epsilondev_yz,float* epsilon_trace_over_3,int SIMULATION_TYPE)
{
    
  /* int bx = blockIdx.y*blockDim.x+blockIdx.x; //possible bug in original code*/
  int bx = blockIdx.y*gridDim.x+blockIdx.x;
  /* int bx = blockIdx.x; */
  int tx = threadIdx.x;

  
  
  const int NGLLX = 5;
  /* const int NGLL2 = 25; */
  const int NGLL3 = 125;
  const int NGLL3_ALIGN = 128;
    
  int K = (tx/NGLL2);
  int J = ((tx-K*NGLL2)/NGLLX);
  int I = (tx-K*NGLL2-J*NGLLX);
    
  int active,offset;
  int iglob = 0;
  int working_element;
  reald tempx1l,tempx2l,tempx3l,tempy1l,tempy2l,tempy3l,tempz1l,tempz2l,tempz3l;
  reald xixl,xiyl,xizl,etaxl,etayl,etazl,gammaxl,gammayl,gammazl,jacobianl;
  reald duxdxl,duxdyl,duxdzl,duydxl,duydyl,duydzl,duzdxl,duzdyl,duzdzl;
  reald duxdxl_plus_duydyl,duxdxl_plus_duzdzl,duydyl_plus_duzdzl;
  reald duxdyl_plus_duydxl,duzdxl_plus_duxdzl,duzdyl_plus_duydzl;
  reald fac1,fac2,fac3,lambdal,mul,lambdalplus2mul,kappal;
  reald sigma_xx,sigma_yy,sigma_zz,sigma_xy,sigma_xz,sigma_yz;

#ifndef MANUALLY_UNROLLED_LOOPS
    int l;
    float hp1,hp2,hp3;
#endif
    
    __shared__ reald s_dummyx_loc[NGLL3];
    __shared__ reald s_dummyy_loc[NGLL3];
    __shared__ reald s_dummyz_loc[NGLL3];
    
    __shared__ reald s_tempx1[NGLL3];
    __shared__ reald s_tempx2[NGLL3];
    __shared__ reald s_tempx3[NGLL3];
    __shared__ reald s_tempy1[NGLL3];
    __shared__ reald s_tempy2[NGLL3];
    __shared__ reald s_tempy3[NGLL3];
    __shared__ reald s_tempz1[NGLL3];
    __shared__ reald s_tempz2[NGLL3];
    __shared__ reald s_tempz3[NGLL3];
    
// use only NGLL^3 = 125 active threads, plus 3 inactive/ghost threads,
// because we used memory padding from NGLL^3 = 125 to 128 to get coalescent memory accesses
    active = (tx < NGLL3 && bx < nb_blocks_to_compute) ? 1:0;
    
// copy from global memory to shared memory
// each thread writes one of the NGLL^3 = 125 data points
    if (active) {
      // iphase-1 and working_element-1 for Fortran->C array conventions
      working_element = d_phase_ispec_inner_elastic[bx + num_phase_ispec_elastic*(d_iphase-1)]-1;
      // iglob = d_ibool[working_element*NGLL3_ALIGN + tx]-1;                 
      iglob = d_ibool[working_element*125 + tx]-1;
      
#ifdef USE_TEXTURES
        s_dummyx_loc[tx] = tex1Dfetch(tex_displ, iglob);
        s_dummyy_loc[tx] = tex1Dfetch(tex_displ, iglob + NGLOB);
        s_dummyz_loc[tx] = tex1Dfetch(tex_displ, iglob + 2*NGLOB);
#else
	// changing iglob indexing to match fortran row changes fast style
	s_dummyx_loc[tx] = d_displ[iglob*3];
	s_dummyy_loc[tx] = d_displ[iglob*3 + 1];
        s_dummyz_loc[tx] = d_displ[iglob*3 + 2];
#endif
    }

// synchronize all the threads (one thread for each of the NGLL grid points of the
// current spectral element) because we need the whole element to be ready in order
// to be able to compute the matrix products along cut planes of the 3D element below
    __syncthreads();

#ifndef MAKE_KERNEL2_BECOME_STUPID_FOR_TESTS

    if (active) {

#ifndef MANUALLY_UNROLLED_LOOPS

        tempx1l = 0.f;
        tempx2l = 0.f;
        tempx3l = 0.f;

        tempy1l = 0.f;
        tempy2l = 0.f;
        tempy3l = 0.f;

        tempz1l = 0.f;
        tempz2l = 0.f;
        tempz3l = 0.f;

        for (l=0;l<NGLLX;l++) {
            hp1 = d_hprime_xx[l*NGLLX+I];
            offset = K*NGLL2+J*NGLLX+l;
            tempx1l += s_dummyx_loc[offset]*hp1;
            tempy1l += s_dummyy_loc[offset]*hp1;
            tempz1l += s_dummyz_loc[offset]*hp1;
	    
            hp2 = d_hprime_xx[l*NGLLX+J];
            offset = K*NGLL2+l*NGLLX+I;
            tempx2l += s_dummyx_loc[offset]*hp2;
            tempy2l += s_dummyy_loc[offset]*hp2;
            tempz2l += s_dummyz_loc[offset]*hp2;

            hp3 = d_hprime_xx[l*NGLLX+K];
            offset = l*NGLL2+J*NGLLX+I;
            tempx3l += s_dummyx_loc[offset]*hp3;
            tempy3l += s_dummyy_loc[offset]*hp3;
            tempz3l += s_dummyz_loc[offset]*hp3;

	    // if(working_element == 169 && tx == 0) {
	    //   atomicAdd(&d_debug[0],1.0);
	    //   d_debug[1+3*l] = tempz3l;
	    //   d_debug[2+3*l] = s_dummyz_loc[offset];	      
	    //   d_debug[3+3*l] = hp3;	      
	    // }
	    
        }
#else

            tempx1l = s_dummyx_loc[K*NGLL2+J*NGLLX]*d_hprime_xx[I]
                    + s_dummyx_loc[K*NGLL2+J*NGLLX+1]*d_hprime_xx[NGLLX+I]
                    + s_dummyx_loc[K*NGLL2+J*NGLLX+2]*d_hprime_xx[2*NGLLX+I]
                    + s_dummyx_loc[K*NGLL2+J*NGLLX+3]*d_hprime_xx[3*NGLLX+I]
                    + s_dummyx_loc[K*NGLL2+J*NGLLX+4]*d_hprime_xx[4*NGLLX+I];	    
	    
            tempy1l = s_dummyy_loc[K*NGLL2+J*NGLLX]*d_hprime_xx[I]
                    + s_dummyy_loc[K*NGLL2+J*NGLLX+1]*d_hprime_xx[NGLLX+I]
                    + s_dummyy_loc[K*NGLL2+J*NGLLX+2]*d_hprime_xx[2*NGLLX+I]
                    + s_dummyy_loc[K*NGLL2+J*NGLLX+3]*d_hprime_xx[3*NGLLX+I]
                    + s_dummyy_loc[K*NGLL2+J*NGLLX+4]*d_hprime_xx[4*NGLLX+I];

            tempz1l = s_dummyz_loc[K*NGLL2+J*NGLLX]*d_hprime_xx[I]
                    + s_dummyz_loc[K*NGLL2+J*NGLLX+1]*d_hprime_xx[NGLLX+I]
                    + s_dummyz_loc[K*NGLL2+J*NGLLX+2]*d_hprime_xx[2*NGLLX+I]
                    + s_dummyz_loc[K*NGLL2+J*NGLLX+3]*d_hprime_xx[3*NGLLX+I]
                    + s_dummyz_loc[K*NGLL2+J*NGLLX+4]*d_hprime_xx[4*NGLLX+I];

            tempx2l = s_dummyx_loc[K*NGLL2+I]*d_hprime_xx[J]
                    + s_dummyx_loc[K*NGLL2+NGLLX+I]*d_hprime_xx[NGLLX+J]
                    + s_dummyx_loc[K*NGLL2+2*NGLLX+I]*d_hprime_xx[2*NGLLX+J]
                    + s_dummyx_loc[K*NGLL2+3*NGLLX+I]*d_hprime_xx[3*NGLLX+J]
                    + s_dummyx_loc[K*NGLL2+4*NGLLX+I]*d_hprime_xx[4*NGLLX+J];

            tempy2l = s_dummyy_loc[K*NGLL2+I]*d_hprime_xx[J]
                    + s_dummyy_loc[K*NGLL2+NGLLX+I]*d_hprime_xx[NGLLX+J]
                    + s_dummyy_loc[K*NGLL2+2*NGLLX+I]*d_hprime_xx[2*NGLLX+J]
                    + s_dummyy_loc[K*NGLL2+3*NGLLX+I]*d_hprime_xx[3*NGLLX+J]
                    + s_dummyy_loc[K*NGLL2+4*NGLLX+I]*d_hprime_xx[4*NGLLX+J];

            tempz2l = s_dummyz_loc[K*NGLL2+I]*d_hprime_xx[J]
                    + s_dummyz_loc[K*NGLL2+NGLLX+I]*d_hprime_xx[NGLLX+J]
                    + s_dummyz_loc[K*NGLL2+2*NGLLX+I]*d_hprime_xx[2*NGLLX+J]
                    + s_dummyz_loc[K*NGLL2+3*NGLLX+I]*d_hprime_xx[3*NGLLX+J]
                    + s_dummyz_loc[K*NGLL2+4*NGLLX+I]*d_hprime_xx[4*NGLLX+J];

            tempx3l = s_dummyx_loc[J*NGLLX+I]*d_hprime_xx[K]
                    + s_dummyx_loc[NGLL2+J*NGLLX+I]*d_hprime_xx[NGLLX+K]
                    + s_dummyx_loc[2*NGLL2+J*NGLLX+I]*d_hprime_xx[2*NGLLX+K]
                    + s_dummyx_loc[3*NGLL2+J*NGLLX+I]*d_hprime_xx[3*NGLLX+K]
                    + s_dummyx_loc[4*NGLL2+J*NGLLX+I]*d_hprime_xx[4*NGLLX+K];

            tempy3l = s_dummyy_loc[J*NGLLX+I]*d_hprime_xx[K]
                    + s_dummyy_loc[NGLL2+J*NGLLX+I]*d_hprime_xx[NGLLX+K]
                    + s_dummyy_loc[2*NGLL2+J*NGLLX+I]*d_hprime_xx[2*NGLLX+K]
                    + s_dummyy_loc[3*NGLL2+J*NGLLX+I]*d_hprime_xx[3*NGLLX+K]
                    + s_dummyy_loc[4*NGLL2+J*NGLLX+I]*d_hprime_xx[4*NGLLX+K];

            tempz3l = s_dummyz_loc[J*NGLLX+I]*d_hprime_xx[K]
                    + s_dummyz_loc[NGLL2+J*NGLLX+I]*d_hprime_xx[NGLLX+K]
                    + s_dummyz_loc[2*NGLL2+J*NGLLX+I]*d_hprime_xx[2*NGLLX+K]
                    + s_dummyz_loc[3*NGLL2+J*NGLLX+I]*d_hprime_xx[3*NGLLX+K]
                    + s_dummyz_loc[4*NGLL2+J*NGLLX+I]*d_hprime_xx[4*NGLLX+K];

#endif

// compute derivatives of ux, uy and uz with respect to x, y and z
        offset = working_element*NGLL3_ALIGN + tx;

        xixl = d_xix[offset];
        xiyl = d_xiy[offset];
        xizl = d_xiz[offset];
        etaxl = d_etax[offset];
        etayl = d_etay[offset];
        etazl = d_etaz[offset];
        gammaxl = d_gammax[offset];
        gammayl = d_gammay[offset];
        gammazl = d_gammaz[offset];

        duxdxl = xixl*tempx1l + etaxl*tempx2l + gammaxl*tempx3l;	
	duxdyl = xiyl*tempx1l + etayl*tempx2l + gammayl*tempx3l;
        duxdzl = xizl*tempx1l + etazl*tempx2l + gammazl*tempx3l;

        duydxl = xixl*tempy1l + etaxl*tempy2l + gammaxl*tempy3l;
        duydyl = xiyl*tempy1l + etayl*tempy2l + gammayl*tempy3l;
        duydzl = xizl*tempy1l + etazl*tempy2l + gammazl*tempy3l;

        duzdxl = xixl*tempz1l + etaxl*tempz2l + gammaxl*tempz3l;
        duzdyl = xiyl*tempz1l + etayl*tempz2l + gammayl*tempz3l;
        duzdzl = xizl*tempz1l + etazl*tempz2l + gammazl*tempz3l;

	
	
        duxdxl_plus_duydyl = duxdxl + duydyl;
        duxdxl_plus_duzdzl = duxdxl + duzdzl;
        duydyl_plus_duzdzl = duydyl + duzdzl;
        duxdyl_plus_duydxl = duxdyl + duydxl;
        duzdxl_plus_duxdzl = duzdxl + duxdzl;
        duzdyl_plus_duydzl = duzdyl + duydzl;

	if(COMPUTE_AND_STORE_STRAIN) {
	  float templ = 1.0f/3.0f * (duxdxl + duydyl + duzdzl);
	  epsilondev_xx[offset] = duxdxl - templ;
	  epsilondev_yy[offset] = duydyl - templ;
	  epsilondev_xy[offset] = 0.5 * duxdyl_plus_duydxl;
	  epsilondev_xz[offset] = 0.5 * duzdxl_plus_duxdzl;
	  epsilondev_yz[offset] = 0.5 * duzdyl_plus_duydzl;
	  if(SIMULATION_TYPE == 3) {
	    epsilon_trace_over_3[tx + working_element*125] = templ;
	  }
	}

// compute elements with an elastic isotropic rheology
        kappal = d_kappav[offset];
        mul = d_muv[offset];

        lambdalplus2mul = kappal + 1.33333333333333333333f * mul;  // 4./3. = 1.3333333
        lambdal = lambdalplus2mul - 2.f*mul;

// compute the six components of the stress tensor sigma
        sigma_xx = lambdalplus2mul*duxdxl + lambdal*duydyl_plus_duzdzl;
        sigma_yy = lambdalplus2mul*duydyl + lambdal*duxdxl_plus_duzdzl;
        sigma_zz = lambdalplus2mul*duzdzl + lambdal*duxdxl_plus_duydyl;
	
        sigma_xy = mul*duxdyl_plus_duydxl;
        sigma_xz = mul*duzdxl_plus_duxdzl;
        sigma_yz = mul*duzdyl_plus_duydzl;

        jacobianl = 1.f / (xixl*(etayl*gammazl-etazl*gammayl)-xiyl*(etaxl*gammazl-etazl*gammaxl)+xizl*(etaxl*gammayl-etayl*gammaxl));

// form the dot product with the test vector
        s_tempx1[tx] = jacobianl * (sigma_xx*xixl + sigma_xy*xiyl + sigma_xz*xizl);	
	s_tempy1[tx] = jacobianl * (sigma_xy*xixl + sigma_yy*xiyl + sigma_yz*xizl);
        s_tempz1[tx] = jacobianl * (sigma_xz*xixl + sigma_yz*xiyl + sigma_zz*xizl);

        s_tempx2[tx] = jacobianl * (sigma_xx*etaxl + sigma_xy*etayl + sigma_xz*etazl);
        s_tempy2[tx] = jacobianl * (sigma_xy*etaxl + sigma_yy*etayl + sigma_yz*etazl);
        s_tempz2[tx] = jacobianl * (sigma_xz*etaxl + sigma_yz*etayl + sigma_zz*etazl);

        s_tempx3[tx] = jacobianl * (sigma_xx*gammaxl + sigma_xy*gammayl + sigma_xz*gammazl);
        s_tempy3[tx] = jacobianl * (sigma_xy*gammaxl + sigma_yy*gammayl + sigma_yz*gammazl);
        s_tempz3[tx] = jacobianl * (sigma_xz*gammaxl + sigma_yz*gammayl + sigma_zz*gammazl);
	
    }

// synchronize all the threads (one thread for each of the NGLL grid points of the
// current spectral element) because we need the whole element to be ready in order
// to be able to compute the matrix products along cut planes of the 3D element below
    __syncthreads();

    if (active) {

#ifndef MANUALLY_UNROLLED_LOOPS

        tempx1l = 0.f;
        tempy1l = 0.f;
        tempz1l = 0.f;

        tempx2l = 0.f;
        tempy2l = 0.f;
        tempz2l = 0.f;

        tempx3l = 0.f;
        tempy3l = 0.f;
        tempz3l = 0.f;

        for (l=0;l<NGLLX;l++) {	  	  
	  
	  fac1 = d_hprimewgll_xx[I*NGLLX+l];
	  offset = K*NGLL2+J*NGLLX+l;
	  tempx1l += s_tempx1[offset]*fac1;
	  tempy1l += s_tempy1[offset]*fac1;
	  tempz1l += s_tempz1[offset]*fac1;
	    
	  fac2 = d_hprimewgll_xx[J*NGLLX+l];
	  offset = K*NGLL2+l*NGLLX+I;
	  tempx2l += s_tempx2[offset]*fac2;
	  tempy2l += s_tempy2[offset]*fac2;
	  tempz2l += s_tempz2[offset]*fac2;

	  fac3 = d_hprimewgll_xx[K*NGLLX+l];
	  offset = l*NGLL2+J*NGLLX+I;
	  tempx3l += s_tempx3[offset]*fac3;
	  tempy3l += s_tempy3[offset]*fac3;
	  tempz3l += s_tempz3[offset]*fac3;

	  if(working_element == 169)
	    if(l==0)
	      if(I+J+K == 0) {
		// atomicAdd(&d_debug[0],1.0);
		// d_debug[0] = fac3;
		// d_debug[1] = offset;
		// d_debug[2] = s_tempz3[offset];
	      }
        }
#else

            tempx1l = s_tempx1[K*NGLL2+J*NGLLX]*d_hprimewgll_xx[I*NGLLX]
                    + s_tempx1[K*NGLL2+J*NGLLX+1]*d_hprimewgll_xx[I*NGLLX+1]
                    + s_tempx1[K*NGLL2+J*NGLLX+2]*d_hprimewgll_xx[I*NGLLX+2]
                    + s_tempx1[K*NGLL2+J*NGLLX+3]*d_hprimewgll_xx[I*NGLLX+3]
                    + s_tempx1[K*NGLL2+J*NGLLX+4]*d_hprimewgll_xx[I*NGLLX+4];
	    
            tempy1l = s_tempy1[K*NGLL2+J*NGLLX]*d_hprimewgll_xx[I*NGLLX]
                    + s_tempy1[K*NGLL2+J*NGLLX+1]*d_hprimewgll_xx[I*NGLLX+1]
                    + s_tempy1[K*NGLL2+J*NGLLX+2]*d_hprimewgll_xx[I*NGLLX+2]
                    + s_tempy1[K*NGLL2+J*NGLLX+3]*d_hprimewgll_xx[I*NGLLX+3]
                    + s_tempy1[K*NGLL2+J*NGLLX+4]*d_hprimewgll_xx[I*NGLLX+4];

            tempz1l = s_tempz1[K*NGLL2+J*NGLLX]*d_hprimewgll_xx[I*NGLLX]
                    + s_tempz1[K*NGLL2+J*NGLLX+1]*d_hprimewgll_xx[I*NGLLX+1]
                    + s_tempz1[K*NGLL2+J*NGLLX+2]*d_hprimewgll_xx[I*NGLLX+2]
                    + s_tempz1[K*NGLL2+J*NGLLX+3]*d_hprimewgll_xx[I*NGLLX+3]
                    + s_tempz1[K*NGLL2+J*NGLLX+4]*d_hprimewgll_xx[I*NGLLX+4];

            tempx2l = s_tempx2[K*NGLL2+I]*d_hprimewgll_xx[J*NGLLX]
                    + s_tempx2[K*NGLL2+NGLLX+I]*d_hprimewgll_xx[J*NGLLX+1]
                    + s_tempx2[K*NGLL2+2*NGLLX+I]*d_hprimewgll_xx[J*NGLLX+2]
                    + s_tempx2[K*NGLL2+3*NGLLX+I]*d_hprimewgll_xx[J*NGLLX+3]
                    + s_tempx2[K*NGLL2+4*NGLLX+I]*d_hprimewgll_xx[J*NGLLX+4];

            tempy2l = s_tempy2[K*NGLL2+I]*d_hprimewgll_xx[J*NGLLX]
                    + s_tempy2[K*NGLL2+NGLLX+I]*d_hprimewgll_xx[J*NGLLX+1]
                    + s_tempy2[K*NGLL2+2*NGLLX+I]*d_hprimewgll_xx[J*NGLLX+2]
                    + s_tempy2[K*NGLL2+3*NGLLX+I]*d_hprimewgll_xx[J*NGLLX+3]
                    + s_tempy2[K*NGLL2+4*NGLLX+I]*d_hprimewgll_xx[J*NGLLX+4];

            tempz2l = s_tempz2[K*NGLL2+I]*d_hprimewgll_xx[J*NGLLX]
                    + s_tempz2[K*NGLL2+NGLLX+I]*d_hprimewgll_xx[J*NGLLX+1]
                    + s_tempz2[K*NGLL2+2*NGLLX+I]*d_hprimewgll_xx[J*NGLLX+2]
                    + s_tempz2[K*NGLL2+3*NGLLX+I]*d_hprimewgll_xx[J*NGLLX+3]
                    + s_tempz2[K*NGLL2+4*NGLLX+I]*d_hprimewgll_xx[J*NGLLX+4];

            tempx3l = s_tempx3[J*NGLLX+I]*d_hprimewgll_xx[K*NGLLX]
                    + s_tempx3[NGLL2+J*NGLLX+I]*d_hprimewgll_xx[K*NGLLX+1]
                    + s_tempx3[2*NGLL2+J*NGLLX+I]*d_hprimewgll_xx[K*NGLLX+2]
                    + s_tempx3[3*NGLL2+J*NGLLX+I]*d_hprimewgll_xx[K*NGLLX+3]
                    + s_tempx3[4*NGLL2+J*NGLLX+I]*d_hprimewgll_xx[K*NGLLX+4];

            tempy3l = s_tempy3[J*NGLLX+I]*d_hprimewgll_xx[K*NGLLX]
                    + s_tempy3[NGLL2+J*NGLLX+I]*d_hprimewgll_xx[K*NGLLX+1]
                    + s_tempy3[2*NGLL2+J*NGLLX+I]*d_hprimewgll_xx[K*NGLLX+2]
                    + s_tempy3[3*NGLL2+J*NGLLX+I]*d_hprimewgll_xx[K*NGLLX+3]
                    + s_tempy3[4*NGLL2+J*NGLLX+I]*d_hprimewgll_xx[K*NGLLX+4];

            tempz3l = s_tempz3[J*NGLLX+I]*d_hprimewgll_xx[K*NGLLX]
                    + s_tempz3[NGLL2+J*NGLLX+I]*d_hprimewgll_xx[K*NGLLX+1]
                    + s_tempz3[2*NGLL2+J*NGLLX+I]*d_hprimewgll_xx[K*NGLLX+2]
                    + s_tempz3[3*NGLL2+J*NGLLX+I]*d_hprimewgll_xx[K*NGLLX+3]
                    + s_tempz3[4*NGLL2+J*NGLLX+I]*d_hprimewgll_xx[K*NGLLX+4];

#endif

        fac1 = d_wgllwgll_yz[K*NGLLX+J];
        fac2 = d_wgllwgll_xz[K*NGLLX+I];
        fac3 = d_wgllwgll_xy[J*NGLLX+I];

#ifdef USE_TEXTURES
        d_accel[iglob] = tex1Dfetch(tex_accel, iglob) - (fac1*tempx1l + fac2*tempx2l + fac3*tempx3l);
        d_accel[iglob + NGLOB] = tex1Dfetch(tex_accel, iglob + NGLOB) - (fac1*tempy1l + fac2*tempy2l + fac3*tempy3l);
        d_accel[iglob + 2*NGLOB] = tex1Dfetch(tex_accel, iglob + 2*NGLOB) - (fac1*tempz1l + fac2*tempz2l + fac3*tempz3l);
#else
	/* OLD/To be implemented version that uses coloring to get around race condition. About 1.6x faster */
	// d_accel[iglob*3] -= (fac1*tempx1l + fac2*tempx2l + fac3*tempx3l);
        // d_accel[iglob*3 + 1] -= (fac1*tempy1l + fac2*tempy2l + fac3*tempy3l);
        // d_accel[iglob*3 + 2] -= (fac1*tempz1l + fac2*tempz2l + fac3*tempz3l);		

	if(iglob*3+2 == 41153) {
	  // int ot = d_debug[5];
	  // d_debug[0+1+ot] = d_accel[iglob*3+2];
	  // // d_debug[1+1+ot] = fac1*tempz1l;
	  // // d_debug[2+1+ot] = fac2*tempz2l;
	  // // d_debug[3+1+ot] = fac3*tempz3l;
	  // d_debug[1+1+ot] = fac1;
	  // d_debug[2+1+ot] = fac2;
	  // d_debug[3+1+ot] = fac3;
	  // d_debug[4+1+ot] = d_accel[iglob*3+2]-(fac1*tempz1l + fac2*tempz2l + fac3*tempz3l);
	  // atomicAdd(&d_debug[0],1.0);
	  // d_debug[6+ot] = d_displ[iglob*3+2];
	}
	
	atomicAdd(&d_accel[iglob*3],-(fac1*tempx1l + fac2*tempx2l + fac3*tempx3l));		
	atomicAdd(&d_accel[iglob*3+1],-(fac1*tempy1l + fac2*tempy2l + fac3*tempy3l));
	atomicAdd(&d_accel[iglob*3+2],-(fac1*tempz1l + fac2*tempz2l + fac3*tempz3l));
	
#endif
    }

#else  // of #ifndef MAKE_KERNEL2_BECOME_STUPID_FOR_TESTS
        d_accel[iglob] -= 0.00000001f;
        d_accel[iglob + NGLOB] -= 0.00000001f;
        d_accel[iglob + 2*NGLOB] -= 0.00000001f;
#endif // of #ifndef MAKE_KERNEL2_BECOME_STUPID_FOR_TESTS
}

__global__ void kernel_3_cuda_device(real* veloc,
				     real* accel, int size,
				     real deltatover2, real* rmass);

extern "C" void kernel_3_cuda_(long* Mesh_pointer,int* size_F, float* deltatover2_F, int* SIMULATION_TYPE_f, float* b_deltatover2) {
   Mesh* mp = (Mesh*)(*Mesh_pointer); // get Mesh from fortran integer wrapper
   int size = *size_F;
   int SIMULATION_TYPE = *SIMULATION_TYPE_f;
   real deltatover2 = *deltatover2_F;
   int blocksize=128;
   int size_padded = ((int)ceil(((double)size)/((double)blocksize)))*blocksize;
   int num_blocks_x = size_padded/blocksize;
   int num_blocks_y = 1;
   while(num_blocks_x > 65535) {
     num_blocks_x = ceil(num_blocks_x/2.0);
     num_blocks_y = num_blocks_y*2;
   }
   dim3 grid(num_blocks_x,num_blocks_y);
   dim3 threads(blocksize,1,1);
   
   kernel_3_cuda_device<<< grid, threads>>>(mp->d_veloc, mp->d_accel, size, deltatover2, mp->d_rmass);

   if(SIMULATION_TYPE == 3) {
     kernel_3_cuda_device<<< grid, threads>>>(mp->d_b_veloc, mp->d_b_accel, size, *b_deltatover2,mp->d_rmass);
   }
   
#ifdef ENABLE_VERY_SLOW_ERROR_CHECKING

   //printf("checking updatedispl_kernel launch...with %dx%d blocks\n",num_blocks_x,num_blocks_y);
   // sync and check to catch errors from previous async operations
   cudaThreadSynchronize();
   MPI_Barrier(MPI_COMM_WORLD);
   cudaError_t err = cudaGetLastError();
   if (err != cudaSuccess)
     {
       fprintf(stderr,"Error after kernel 3: %s\n", cudaGetErrorString(err));
       exit(1);
     }
#endif
}

 __global__ void kernel_3_cuda_device(real* veloc,
					real* accel, int size,
					real deltatover2, real* rmass) {
    int id = threadIdx.x + blockIdx.x*blockDim.x + blockIdx.y*gridDim.x*blockDim.x;

    /* because of block and grid sizing problems, there is a small */
    /* amount of buffer at the end of the calculation */
    if(id < size) {
      accel[3*id] = accel[3*id]*rmass[id]; 
      accel[3*id+1] = accel[3*id+1]*rmass[id]; 
      accel[3*id+2] = accel[3*id+2]*rmass[id];
      
      veloc[3*id] = veloc[3*id] + deltatover2*accel[3*id];
      veloc[3*id+1] = veloc[3*id+1] + deltatover2*accel[3*id+1];
      veloc[3*id+2] = veloc[3*id+2] + deltatover2*accel[3*id+2];      
    }
  }

void setConst_hprime_xx(float* array)
{

  cudaError_t err = cudaMemcpyToSymbol(d_hprime_xx, array, NGLL2*sizeof(float));
  if (err != cudaSuccess)
    {
      fprintf(stderr, "Error in setConst_hprime_xx: %s\n", cudaGetErrorString(err));
      fprintf(stderr, "The problem is maybe -arch sm_13 instead of -arch sm_11 in the Makefile, please doublecheck\n");
      exit(1);
    }
}

void setConst_hprimewgll_xx(float* array)
{
  cudaError_t err = cudaMemcpyToSymbol(d_hprimewgll_xx, array, NGLL2*sizeof(float));
  if (err != cudaSuccess)
    {
      fprintf(stderr, "Error in setConst_hprime_xx: %s\n", cudaGetErrorString(err));
      exit(1);
    }
}

void setConst_wgllwgll_xy(float* array,Mesh* mp)
{
  cudaError_t err = cudaMemcpyToSymbol(d_wgllwgll_xy, array, NGLL2*sizeof(float));
  if (err != cudaSuccess)
    {
      fprintf(stderr, "Error in setConst_wgllwgll_xy: %s\n", cudaGetErrorString(err));
      exit(1);
    }
  
  // mp->d_wgllwgll_xy = d_wgllwgll_xy; // this doesn't work, use
  // following cudaGetSymbolAddress
  err = cudaGetSymbolAddress((void**)&(mp->d_wgllwgll_xy),"d_wgllwgll_xy");
  printf("setting up mp->d_wgllwgll_xy\n");
  if(err != cudaSuccess) {
    fprintf(stderr, "Error with d_wgllwgll_xy: %s\n", cudaGetErrorString(err));
    exit(1);
  }
}

void setConst_wgllwgll_xz(float* array,Mesh* mp)
{
  cudaError_t err = cudaMemcpyToSymbol(d_wgllwgll_xz, array, NGLL2*sizeof(float));
  if (err != cudaSuccess)
    {
      fprintf(stderr, "Error in  setConst_wgllwgll_xz: %s\n", cudaGetErrorString(err));
      exit(1);
    }
  // mp->d_wgllwgll_xz = d_wgllwgll_xz;
  err = cudaGetSymbolAddress((void**)&(mp->d_wgllwgll_xz),"d_wgllwgll_xz");
  if(err != cudaSuccess) {
    fprintf(stderr, "Error with d_wgllwgll_xz: %s\n", cudaGetErrorString(err));
    exit(1);
  }
}

void setConst_wgllwgll_yz(float* array,Mesh* mp)
{
  cudaError_t err = cudaMemcpyToSymbol(d_wgllwgll_yz, array, NGLL2*sizeof(float));
  if (err != cudaSuccess)
    {
      fprintf(stderr, "Error in setConst_wgllwgll_yz: %s\n", cudaGetErrorString(err));
      exit(1);
    }
  // mp->d_wgllwgll_yz = d_wgllwgll_yz;
  err = cudaGetSymbolAddress((void**)&(mp->d_wgllwgll_yz),"d_wgllwgll_yz");
  if(err != cudaSuccess) {
    fprintf(stderr, "Error with d_wgllwgll_yz: %s\n", cudaGetErrorString(err));
    exit(1);
  }
}