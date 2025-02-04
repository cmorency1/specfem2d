!========================================================================
!
!                            S P E C F E M 2 D
!                            -----------------
!
! Copyright Universite de Pau et des Pays de l'Adour and CNRS, France.
! Contributors: Dimitri Komatitsch, dimitri DOT komatitsch aT univ-pau DOT fr
!               Nicolas Le Goff, nicolas DOT legoff aT univ-pau DOT fr
!               Roland Martin, roland DOT martin aT univ-pau DOT fr
!               Christina Morency, cmorency aT princeton DOT edu
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

  subroutine compute_forces_poro_solid(displs_poroelastic,displw_poroelastic,accels_poroelastic,epsilondev_s,iphase)

! compute forces for the solid poroelastic part

  use constants, only: CUSTOM_REAL,NDIM,NGLLX,NGLLZ,NGLJ, &
    CPML_X_ONLY,CPML_Z_ONLY,IRIGHT,ILEFT,IBOTTOM,ITOP, &
    TWO,ONE,HALF,ZERO,FOUR_THIRDS, &
    ALPHA_LDDRK,BETA_LDDRK,ALPHA_RK4,BETA_RK4

  use specfem_par, only: nglob,nspec,nglob_poroelastic,b_nspec_poroelastic, &
                         phistore,tortstore,kappaarraystore,mufr_store, &
                         ATTENUATION_VISCOELASTIC,deltat, &
                         ibool,ispec_is_poroelastic, &
                         xix,xiz,gammax,gammaz,jacobian, &
                         e11,e13,hprime_xx,hprimewgll_xx,hprime_zz,hprimewgll_zz,wxgll,wzgll, &
                         inv_tau_sigma_nu2,phi_nu2,Mu_nu2,N_SLS, &
                         SIMULATION_TYPE, &
                         e11_LDDRK,e13_LDDRK, &
                         e11_initial_rk,e13_initial_rk,e11_force_RK, e13_force_RK, &
                         time_stepping_scheme,i_stage

  use specfem_par, only: displs_poroelastic_old

  ! overlapping communication
  use specfem_par, only: nspec_inner_poroelastic,nspec_outer_poroelastic,phase_ispec_inner_poroelastic

  implicit none

  real(kind=CUSTOM_REAL), dimension(NDIM,nglob_poroelastic), intent(in) :: displs_poroelastic,displw_poroelastic
  real(kind=CUSTOM_REAL), dimension(NDIM,nglob_poroelastic), intent(inout) :: accels_poroelastic

  real(kind=CUSTOM_REAL), dimension(4,NGLLX,NGLLZ,b_nspec_poroelastic),intent(out) :: epsilondev_s

  integer,intent(in) :: iphase

  ! local variables
  integer :: ispec,i,j,k,iglob
  integer :: i_sls

  ! spatial derivatives
  real(kind=CUSTOM_REAL) :: dux_dxi,dux_dgamma,duz_dxi,duz_dgamma
  real(kind=CUSTOM_REAL) :: dwx_dxi,dwx_dgamma,dwz_dxi,dwz_dgamma
  real(kind=CUSTOM_REAL) :: dux_dxl,duz_dxl,dux_dzl,duz_dzl
  real(kind=CUSTOM_REAL) :: dwx_dxl,dwz_dxl,dwx_dzl,dwz_dzl
  real(kind=CUSTOM_REAL) :: sigma_xx,sigma_xz,sigma_zz
  real(kind=CUSTOM_REAL) :: sigmap

  real(kind=CUSTOM_REAL), dimension(NGLLX,NGLLZ) :: tempx1,tempx2,tempz1,tempz2
  real(kind=CUSTOM_REAL), dimension(NGLLX,NGLLZ) :: tempx1p,tempx2p,tempz1p,tempz2p

  real(kind=CUSTOM_REAL), dimension(4,NGLLX,NGLLZ) :: epsilondev_loc

! Jacobian matrix and determinant
  real(kind=CUSTOM_REAL) :: xixl,xizl,gammaxl,gammazl,jacobianl

! material properties of the poroelastic medium
  real(kind=CUSTOM_REAL) :: mu_relaxed_viscoelastic,lambda_relaxed_viscoelastic,lambdalplus2mu_relaxed_viscoel
  real(kind=CUSTOM_REAL) :: mu_G,lambdal_G,lambdalplus2mul_G

  double precision :: phi,tort,kappa_s,kappa_f,kappa_fr,mu_fr
  double precision :: D_biot,H_biot,C_biot,M_biot

! for attenuation
  real(kind=CUSTOM_REAL) :: phinu2,tauinvnu2,theta_n_u,theta_nsub1_u
  real(kind=CUSTOM_REAL) :: bb,coef0,coef1,coef2

  ! RK
  real(kind=CUSTOM_REAL) :: weight_rk

  real(kind=CUSTOM_REAL) :: e11_sum,e13_sum

  real(kind=CUSTOM_REAL), dimension(NGLLX,NGLLZ,nspec) ::dux_dxl_n,duz_dzl_n,duz_dxl_n,dux_dzl_n, &
                                                         !nsub1 denote discrete time step n-1
                                                         dux_dxl_nsub1,duz_dzl_nsub1,duz_dxl_nsub1,dux_dzl_nsub1
  integer :: num_elements,ispec_p

! implement attenuation
  if (ATTENUATION_VISCOELASTIC) then

    ! safety check
    if (SIMULATION_TYPE == 3) &
      call stop_the_code('ATTENUATION_VISCOELASTIC not fully implemented yet for poroelastic kernel simulations')

! compute Grad(displs_poroelastic) at time step n for attenuation
    call compute_gradient_attenuation(displs_poroelastic,dux_dxl_n,duz_dxl_n, &
           dux_dzl_n,duz_dzl_n,xix,xiz,gammax,gammaz,ibool,ispec_is_poroelastic,hprime_xx,hprime_zz,nspec,nglob)

! compute Grad(displs_poroelastic) at time step n-1 for attenuation
    call compute_gradient_attenuation(displs_poroelastic_old,dux_dxl_nsub1,duz_dxl_nsub1, &
           dux_dzl_nsub1,duz_dzl_nsub1,xix,xiz,gammax,gammaz,ibool,ispec_is_poroelastic,hprime_xx,hprime_zz,nspec,nglob)

! update memory variables with fourth-order Runge-Kutta time scheme for attenuation
! loop over spectral elements
  do ispec = 1,nspec

    if (ispec_is_poroelastic(ispec)) then
       do j = 1,NGLLZ; do i = 1,NGLLX
          theta_n_u = dux_dxl_n(i,j,ispec) + duz_dzl_n(i,j,ispec)
          theta_nsub1_u = dux_dxl_nsub1(i,j,ispec) + duz_dzl_nsub1(i,j,ispec)

          ! loop on all the standard linear solids
          do i_sls = 1,N_SLS
            phinu2 = phi_nu2(i,j,ispec,i_sls)
            tauinvnu2 = inv_tau_sigma_nu2(i,j,ispec,i_sls)

            ! update e1, e11, e13 in convolution formulation with modified recursive convolution scheme on basis of
            ! second-order accurate convolution term calculation from equation (21) of
            ! Shumin Wang, Robert Lee, and Fernando L. Teixeira,
            ! Anisotropic-medium PML for vector FETD with modified basis functions,
            ! IEEE Transactions on Antennas and Propagation, vol. 54, no. 1, (2006)
            ! evolution e1 ! no need since we are just considering shear attenuation
            select case(time_stepping_scheme)
            case (1)
              ! Newmark
              bb = tauinvnu2; coef0 = exp(-bb * deltat)
              if (abs(bb) > 1e-5_CUSTOM_REAL) then
                 coef1 = (1._CUSTOM_REAL - exp(-bb * deltat * 0.5_CUSTOM_REAL)) / bb
                 coef2 = (1._CUSTOM_REAL - exp(-bb * deltat * 0.5_CUSTOM_REAL)) * exp(-bb * deltat * 0.5_CUSTOM_REAL)/ bb
              else
                 coef1 = deltat * 0.5_CUSTOM_REAL
                 coef2 = deltat * 0.5_CUSTOM_REAL
              endif

              e11(i_sls,i,j,ispec) = coef0 * e11(i_sls,i,j,ispec) + &
                                     phinu2 * (coef1 * (dux_dxl_n(i,j,ispec)-theta_n_u/TWO) + &
                                               coef2 * (dux_dxl_nsub1(i,j,ispec)-theta_nsub1_u/TWO))

              e13(i_sls,i,j,ispec) = coef0 * e13(i_sls,i,j,ispec) + &
                                     phinu2 * (coef1 * (dux_dzl_n(i,j,ispec) + duz_dxl_n(i,j,ispec)) + &
                                               coef2 * (dux_dzl_nsub1(i,j,ispec) + duz_dxl_nsub1(i,j,ispec)))

            ! update e1, e11, e13 in ADE formation with LDDRK scheme
            ! evolution e1 ! no need since we are just considering shear attenuation
            case (2)
              ! LDDRK
              e11_LDDRK(i,j,ispec,i_sls) = ALPHA_LDDRK(i_stage) * e11_LDDRK(i,j,ispec,i_sls) + &
                                           deltat * ((dux_dxl_n(i,j,ispec)-theta_n_u/TWO) * phinu2) - &
                                           deltat * (e11(i_sls,i,j,ispec) * tauinvnu2)
              e11(i_sls,i,j,ispec) = e11(i_sls,i,j,ispec)+BETA_LDDRK(i_stage)*e11_LDDRK(i,j,ispec,i_sls)

              e13_LDDRK(i,j,ispec,i_sls) = ALPHA_LDDRK(i_stage) * e13_LDDRK(i,j,ispec,i_sls) + &
                                           deltat * ((dux_dzl_n(i,j,ispec) + duz_dxl_n(i,j,ispec))*phinu2) - &
                                           deltat * (e13(i_sls,i,j,ispec) * tauinvnu2)
              e13(i_sls,i,j,ispec) = e13(i_sls,i,j,ispec)+BETA_LDDRK(i_stage) * e13_LDDRK(i,j,ispec,i_sls)

            ! update e1, e11, e13 in ADE formation with classical Runge-Kutta scheme
            ! evolution e1 ! no need since we are just considering shear attenuation
            case (3)
              ! RK
              ! initial field
              if (i_stage == 1) e11_initial_rk(i,j,ispec,i_sls) = e11(i_sls,i,j,ispec)

              ! intermediate fields
              e11_force_RK(i,j,ispec,i_sls,i_stage) = (dux_dxl_n(i,j,ispec)-theta_n_u/TWO) * phinu2 - &
                                                          e11(i_sls,i,j,ispec) * tauinvnu2

              if (i_stage == 1 .or. i_stage == 2 .or. i_stage == 3) then
                ! note: this prepare the fields for the next stage, i.e., used at istage+1
                weight_rk = ALPHA_RK4(i_stage+1) * deltat
                e11(i_sls,i,j,ispec) = e11_initial_rk(i,j,ispec,i_sls) + weight_rk * e11_force_RK(i,j,ispec,i_sls,i_stage)
              else if (i_stage == 4) then
                ! final update
                e11(i_sls,i,j,ispec) = e11_initial_rk(i,j,ispec,i_sls) + deltat * &
                                       (BETA_RK4(1) * e11_force_RK(i,j,ispec,i_sls,1) + &
                                        BETA_RK4(2) * e11_force_RK(i,j,ispec,i_sls,2) + &
                                        BETA_RK4(3) * e11_force_RK(i,j,ispec,i_sls,3) + &
                                        BETA_RK4(4) * e11_force_RK(i,j,ispec,i_sls,4))
              endif

              ! initial field
              if (i_stage == 1) e13_initial_rk(i,j,ispec,i_sls) = e13(i_sls,i,j,ispec)

              ! intermediate fields
              e13_force_RK(i,j,ispec,i_sls,i_stage) = (dux_dzl_n(i,j,ispec) + duz_dxl_n(i,j,ispec))*phinu2 - &
                                                            e13(i_sls,i,j,ispec) * tauinvnu2

              if (i_stage == 1 .or. i_stage == 2 .or. i_stage == 3) then
                ! note: this prepare the fields for the next stage, i.e., used at istage+1
                weight_rk = ALPHA_RK4(i_stage+1) * deltat
                e13(i_sls,i,j,ispec) = e13_initial_rk(i,j,ispec,i_sls) + weight_rk * e13_force_RK(i,j,ispec,i_sls,i_stage)
              else if (i_stage == 4) then
                ! final update
                e13(i_sls,i,j,ispec) = e13_initial_rk(i,j,ispec,i_sls) + deltat * &
                                       (BETA_RK4(1) * e13_force_RK(i,j,ispec,i_sls,1) + &
                                        BETA_RK4(2) * e13_force_RK(i,j,ispec,i_sls,2) + &
                                        BETA_RK4(3) * e13_force_RK(i,j,ispec,i_sls,3) + &
                                        BETA_RK4(4) * e13_force_RK(i,j,ispec,i_sls,4))
              endif
            case default
              call stop_the_code('Error time scheme not implemented yet in compute_forces_poro_solid.f90')
            end select

          enddo
        enddo; enddo
     endif
   enddo

  endif ! end of test on attenuation

  ! choses inner/outer elements
  if (iphase == 1) then
    num_elements = nspec_outer_poroelastic
  else
    num_elements = nspec_inner_poroelastic
  endif

  ! loop over spectral elements
  do ispec_p = 1,num_elements

    ! returns element id from stored element list
    ispec = phase_ispec_inner_poroelastic(ispec_p,iphase)

!---
!--- poroelastic spectral element
!---

    if (.not. ispec_is_poroelastic(ispec)) cycle

    ! first double loop over GLL points to compute and store gradients
    do j = 1,NGLLZ
      do i = 1,NGLLX
        ! derivative along x and along z for u_s and w
        dux_dxi = ZERO
        duz_dxi = ZERO

        dux_dgamma = ZERO
        duz_dgamma = ZERO

        dwx_dxi = ZERO
        dwz_dxi = ZERO

        dwx_dgamma = ZERO
        dwz_dgamma = ZERO

        ! first double loop over GLL points to compute and store gradients
        ! we can merge the two loops because NGLLX == NGLLZ
        do k = 1,NGLLX
          dux_dxi = dux_dxi + displs_poroelastic(1,ibool(k,j,ispec))*hprime_xx(i,k)
          duz_dxi = duz_dxi + displs_poroelastic(2,ibool(k,j,ispec))*hprime_xx(i,k)
          dux_dgamma = dux_dgamma + displs_poroelastic(1,ibool(i,k,ispec))*hprime_zz(j,k)
          duz_dgamma = duz_dgamma + displs_poroelastic(2,ibool(i,k,ispec))*hprime_zz(j,k)

          dwx_dxi = dwx_dxi + displw_poroelastic(1,ibool(k,j,ispec))*hprime_xx(i,k)
          dwz_dxi = dwz_dxi + displw_poroelastic(2,ibool(k,j,ispec))*hprime_xx(i,k)
          dwx_dgamma = dwx_dgamma + displw_poroelastic(1,ibool(i,k,ispec))*hprime_zz(j,k)
          dwz_dgamma = dwz_dgamma + displw_poroelastic(2,ibool(i,k,ispec))*hprime_zz(j,k)
        enddo

        xixl = xix(i,j,ispec)
        xizl = xiz(i,j,ispec)
        gammaxl = gammax(i,j,ispec)
        gammazl = gammaz(i,j,ispec)

        ! derivatives of displacement
        dux_dxl = dux_dxi*xixl + dux_dgamma*gammaxl
        dux_dzl = dux_dxi*xizl + dux_dgamma*gammazl

        duz_dxl = duz_dxi*xixl + duz_dgamma*gammaxl
        duz_dzl = duz_dxi*xizl + duz_dgamma*gammazl

        dwx_dxl = dwx_dxi*xixl + dwx_dgamma*gammaxl
        dwx_dzl = dwx_dxi*xizl + dwx_dgamma*gammazl

        dwz_dxl = dwz_dxi*xixl + dwz_dgamma*gammaxl
        dwz_dzl = dwz_dxi*xizl + dwz_dgamma*gammazl

        ! get poroelastic parameters of current spectral element
        phi = phistore(i,j,ispec)
        kappa_s = kappaarraystore(1,i,j,ispec)
        kappa_f = kappaarraystore(2,i,j,ispec)
        kappa_fr = kappaarraystore(3,i,j,ispec)
        mu_fr = mufr_store(i,j,ispec)

        ! Biot coefficients for the input phi
        call get_poroelastic_Biot_coeff(phi,kappa_s,kappa_f,kappa_fr,mu_fr,D_biot,H_biot,C_biot,M_biot)

        !The RHS has the form : div T -phi/c div T_f + phi/ceta_fk^-1.partial t w
        !where T = G:grad u_s + C_biot div w I
        !and T_f = C_biot div u_s I + M_biot div w I
        mu_G = mu_fr
        lambdal_G = H_biot - 2._CUSTOM_REAL*mu_fr
        lambdalplus2mul_G = lambdal_G + TWO*mu_G

        ! compute stress tensor (include attenuation or anisotropy if needed)
        if (ATTENUATION_VISCOELASTIC) then
! Dissipation only controlled by frame share attenuation in poroelastic (see Morency & Tromp, GJI 2008).
! attenuation is implemented following the memory variable formulation of
! J. M. Carcione, Seismic modeling in viscoelastic media, Geophysics,
! vol. 58(1), p. 110-120 (1993). More details can be found in
! J. M. Carcione, D. Kosloff and R. Kosloff, Wave propagation simulation in a linear
! viscoelastic medium, Geophysical Journal International, vol. 95, p. 597-611 (1988).

! When implementing viscoelasticity according to the Carcione 1993 paper, attenuation is
! non-causal rather than causal i.e. wave speed up instead of slowing down
! when attenuation is turned on. We fixed that issue (which is not incorrect but non traditional)
! by taking the unrelaxed state (infinite frequency) as a reference instead of the relaxed state (zero frequency)
! and also using equations in Carcione's 2007 book.
! See file doc/old_problem_attenuation_reference_Specfem2D_fixed_by_Xie_Zhinan.pdf
! and doc/how_we_modified_Carcione_1993_to_make_it_causal_and_include_the_missing_1_over_L_factor.pdf

! See also J. M. Carcione, Seismic modeling in viscoelastic media, Geophysics,
! vol. 58(1), p. 110-120 (1993) for two memory-variable mechanisms (page 112).

! and J. M. Carcione, D. Kosloff and R. Kosloff, Wave propagation simulation
! in a linear viscoelastic medium, Geophysical Journal International,
! vol. 95, p. 597-611 (1988) for two memory-variable mechanisms (page 604).

          ! compute unrelaxed elastic coefficients from formulas in Carcione 2007 page 125
          lambda_relaxed_viscoelastic = (lambdal_G + mu_G) - mu_G / Mu_nu2(i,j,ispec)
          mu_relaxed_viscoelastic = mu_G / Mu_nu2(i,j,ispec)
          lambdalplus2mu_relaxed_viscoel = lambda_relaxed_viscoelastic + TWO*mu_relaxed_viscoelastic

          ! compute the stress using the unrelaxed Lame parameters (Carcione 2007 page 125)
          sigma_xx = (lambdal_G + 2.0*mu_G)*dux_dxl + lambdal_G*duz_dzl + C_biot*(dwx_dxl + dwz_dzl)
          sigma_xz = mu_G*(duz_dxl + dux_dzl)
          sigma_zz = (lambdal_G + 2.0*mu_G)*duz_dzl + lambdal_G*dux_dxl + C_biot*(dwx_dxl + dwz_dzl)

          sigmap = C_biot*(dux_dxl + duz_dzl) + M_biot*(dwx_dxl + dwz_dzl)

          ! add the memory variables using the relaxed parameters (Carcione 2007 page 125)
          ! beware: there is a bug in Carcione's equation (2c) of his 1993 paper for sigma_zz, we fixed it in the code below
          e11_sum = 0._CUSTOM_REAL
          e13_sum = 0._CUSTOM_REAL

          do i_sls = 1,N_SLS
            e11_sum = e11_sum + e11(i_sls,i,j,ispec)
            e13_sum = e13_sum + e13(i_sls,i,j,ispec)
          enddo

          ! mu_G is the relaxed modulus. Note that it is defined as the
          ! frame modulus (in compute_forces_poro_solid.f90), which Christina Morency noted
          ! mu_fr, which is in her case equivalent to the solid phase shear
          ! modulus, and whose value is entered in Par_file for example
          sigma_xx = sigma_xx + TWO * mu_relaxed_viscoelastic * e11_sum
          sigma_xz = sigma_xz + mu_relaxed_viscoelastic * e13_sum
          sigma_zz = sigma_zz - TWO * mu_relaxed_viscoelastic * e11_sum

        else

          ! no attenuation
          sigma_xx = lambdalplus2mul_G*dux_dxl + lambdal_G*duz_dzl + C_biot*(dwx_dxl + dwz_dzl)
          sigma_xz = mu_G*(duz_dxl + dux_dzl)
          sigma_zz = lambdalplus2mul_G*duz_dzl + lambdal_G*dux_dxl + C_biot*(dwx_dxl + dwz_dzl)

          sigmap = C_biot*(dux_dxl + duz_dzl) + M_biot*(dwx_dxl + dwz_dzl)

        endif

        ! kernels calculation
        if (SIMULATION_TYPE == 3) then
          epsilondev_loc(1,i,j) = dux_dxl
          epsilondev_loc(2,i,j) = duz_dzl
          epsilondev_loc(3,i,j) = dux_dzl
          epsilondev_loc(4,i,j) = 0.5_CUSTOM_REAL * (duz_dxl + dux_dzl)

        ! see now in compute_kernels_po() routine...
        !  iglob = ibool(i,j,ispec)
        !  dsxx =  dux_dxl
        !  dsxz = HALF * (duz_dxl + dux_dzl)
        !  dszz =  duz_dzl
        !
        !  dwxx =  dwx_dxl
        !  dwxz = HALF * (dwz_dxl + dwx_dzl)
        !  dwzz =  dwz_dzl
        !
        !  b_dsxx =  b_dux_dxl
        !  b_dsxz = HALF * (b_duz_dxl + b_dux_dzl)
        !  b_dszz =  b_duz_dzl
        !
        !  b_dwxx =  b_dwx_dxl
        !  b_dwxz = HALF * (b_dwz_dxl + b_dwx_dzl)
        !  b_dwzz =  b_dwz_dzl
        !
        !  B_k(iglob) = (dux_dxl + duz_dzl) *  (b_dux_dxl + b_duz_dzl) * (H_biot - FOUR_THIRDS * mu_fr)
        !  mufr_k(iglob) = (dsxx * b_dsxx + dszz * b_dszz + &
        !                  2._CUSTOM_REAL * dsxz * b_dsxz - &
        !                  1._CUSTOM_REAL/3._CUSTOM_REAL * (dux_dxl + duz_dzl) * (b_dux_dxl + b_duz_dzl) ) * mu_fr
        endif

        jacobianl = jacobian(i,j,ispec)

        ! weak formulation term based on stress tensor (symmetric form)
        ! also add GLL integration weights
        tempx1(i,j) = wzgll(j)*jacobianl*(sigma_xx*xixl+sigma_xz*xizl)
        tempz1(i,j) = wzgll(j)*jacobianl*(sigma_xz*xixl+sigma_zz*xizl)

        tempx2(i,j) = wxgll(i)*jacobianl*(sigma_xx*gammaxl+sigma_xz*gammazl)
        tempz2(i,j) = wxgll(i)*jacobianl*(sigma_xz*gammaxl+sigma_zz*gammazl)

        tempx1p(i,j) = wzgll(j)*jacobianl*sigmap*xixl
        tempz1p(i,j) = wzgll(j)*jacobianl*sigmap*xizl

        tempx2p(i,j) = wxgll(i)*jacobianl*sigmap*gammaxl
        tempz2p(i,j) = wxgll(i)*jacobianl*sigmap*gammazl
      enddo
    enddo

!
! second double-loop over GLL to compute all the terms
!
    do j = 1,NGLLZ
      do i = 1,NGLLX
        iglob = ibool(i,j,ispec)

        ! get poroelastic parameters of current spectral element
        phi = phistore(i,j,ispec)
        tort = tortstore(i,j,ispec)

        ! along x direction and z direction
        ! and assemble the contributions
        ! we can merge the two loops because NGLLX == NGLLZ
        do k = 1,NGLLX
          accels_poroelastic(1,iglob) = accels_poroelastic(1,iglob) - ( (tempx1(k,j) - phi/tort*tempx1p(k,j)) &
                                        *hprimewgll_xx(k,i) + (tempx2(i,k) - phi/tort*tempx2p(i,k))*hprimewgll_zz(k,j))

          accels_poroelastic(2,iglob) = accels_poroelastic(2,iglob) - ( (tempz1(k,j) - phi/tort*tempz1p(k,j)) &
                                        *hprimewgll_xx(k,i) + (tempz2(i,k) - phi/tort*tempz2p(i,k))*hprimewgll_zz(k,j))
        enddo
      enddo ! second loop over the GLL points
    enddo

    ! save deviatoric strain for kernels
    if (SIMULATION_TYPE == 3) then
      epsilondev_s(:,:,:,ispec) = epsilondev_loc(:,:,:)
    endif

  enddo ! end of loop over all spectral elements

  end subroutine compute_forces_poro_solid

