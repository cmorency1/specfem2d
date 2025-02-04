/*
!========================================================================
!
!                            S P E C F E M 2 D
!                            -----------------
!
!     Main historical authors: Dimitri Komatitsch and Jeroen Tromp
!                              CNRS, France
!                       and Princeton University, USA
!                 (there are currently many more authors!)
!                           (c) October 2017
!
! This software is a computer program whose purpose is to solve
! the two-dimensional viscoelastic anisotropic or poroelastic wave equation
! using a spectral-element method (SEM).
!
! This program is free software; you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation; either version 3 of the License, or
! (at your option) any later version.
!
! This program is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License along
! with this program; if not, write to the Free Software Foundation, Inc.,
! 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
!
! The full text of the license is available in file "LICENSE".
!
!========================================================================
*/

#include "mesh_constants_cuda.h"
#include "smooth_cuda.h"


extern "C"
void FC_FUNC_(prepare_arrays_gpu,
              PREPARE_arrays_GPU)(long * Container,
                                  realw * xstore_me,
                                  realw * zstore_me,
                                  realw * sigma_h2_inv,
                                  realw * sigma_v2_inv,
                                  realw * h_criterion,
                                  realw * v_criterion,
                                  int * nspec_me,
                                  int * nker,
                                  realw * wgll_sq){

  Smooth_data* sp = (Smooth_data*)malloc( sizeof(Smooth_data) );
  *Container = (long)sp;

  copy_todevice_realw((void**)&sp->x_me,xstore_me, NGLL2*(*nspec_me));
  copy_todevice_realw((void**)&sp->z_me,zstore_me, NGLL2*(*nspec_me));
  copy_todevice_realw((void**)&sp->wgll_sq,wgll_sq, NGLL2);

  sp->sigma_h2_inv= *sigma_h2_inv;
  sp->sigma_v2_inv= *sigma_v2_inv;
  sp->h_criterion = *h_criterion;
  sp->v_criterion = *v_criterion;
  sp->nspec_me =  *nspec_me;
  sp->nker = *nker;

  print_CUDA_error_if_any(cudaMalloc((void**)&sp->data_smooth,NGLL2*(*nspec_me)*(*nker)*sizeof(realw)),2000);
  print_CUDA_error_if_any(cudaMemset(sp->data_smooth,0,NGLL2*(*nspec_me)*(*nker)*sizeof(realw)),2001);

  print_CUDA_error_if_any(cudaMalloc((void**)&sp->normalisation,NGLL2*(*nspec_me)*sizeof(realw)),2002);
  print_CUDA_error_if_any(cudaMemset(sp->normalisation,0,NGLL2*(*nspec_me)*sizeof(realw)),2003);
}

/* ----------------------------------------------------------------------------------------------- */

extern "C"
void FC_FUNC_(compute_smooth,
              COMPUTE_SMOOTH)(long * smooth_pointer,
                              realw * jacobian,
                              realw * xstore_other,
                              realw * zstore_other,
                              realw * data_other,
                              const int * nspec_other){
  realw * x_other;
  realw * z_other;
  realw * d_data_other;
  realw * d_jacobian;

  Smooth_data * sp = (Smooth_data*)*smooth_pointer;

  copy_todevice_realw((void**)&x_other,xstore_other,NGLL2*(*nspec_other));
  copy_todevice_realw((void**)&z_other,zstore_other,NGLL2*(*nspec_other));
  copy_todevice_realw((void**)&d_jacobian,jacobian,NGLL2*(*nspec_other));

  dim3 grid(sp->nspec_me,1);
  dim3 threads(NGLL2,1,1);

  for (int i=0;i<sp->nker;i++){
    copy_todevice_realw((void**)&d_data_other,&data_other[NGLL2*(*nspec_other)*i],NGLL2*(*nspec_other));
    process_smooth<<<grid,threads>>>(sp->x_me,
                                     sp->z_me,
                                     x_other,
                                     z_other,
                                     d_data_other,
                                     sp->sigma_h2_inv,
                                     sp->sigma_v2_inv,
                                     i,
                                     sp->nspec_me,
                                     *nspec_other,
                                     sp->v_criterion,
                                     sp->h_criterion,
                                     d_jacobian,
                                     sp->data_smooth,
                                     sp->normalisation,
                                     sp->wgll_sq);
    cudaFree(d_data_other);
  }

  synchronize_cuda();
  cudaFree(x_other);
  cudaFree(z_other);
  cudaFree(d_jacobian);
}

/* ----------------------------------------------------------------------------------------------- */

extern "C"
void FC_FUNC_(get_smooth,
              GET_SMOOTH)(long * smooth_pointer,realw * data_smooth){

  Smooth_data * sp = (Smooth_data*)*smooth_pointer;
  dim3 grid(sp->nspec_me,1);
  dim3 threads(NGLL2,1,1);

  normalize_data<<<grid,threads>>>(sp->data_smooth,sp->normalisation,sp->nker,sp->nspec_me);
  print_CUDA_error_if_any(cudaMemcpy(data_smooth, sp->data_smooth,
                                       NGLL2*sp->nspec_me*sizeof(int)*sp->nker, cudaMemcpyDeviceToHost),98012);

  cudaFree(sp->x_me);
  cudaFree(sp->z_me);
  cudaFree(sp->data_smooth);
  cudaFree(sp->wgll_sq);
  cudaFree(sp->normalisation);
  free(sp);
}

