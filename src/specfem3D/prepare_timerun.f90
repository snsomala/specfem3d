!=====================================================================
!
!               S p e c f e m 3 D  V e r s i o n  2 . 0
!               ---------------------------------------
!
!          Main authors: Dimitri Komatitsch and Jeroen Tromp
!    Princeton University, USA and University of Pau / CNRS / INRIA
! (c) Princeton University / California Institute of Technology and University of Pau / CNRS / INRIA
!                            April 2011
!
! This program is free software; you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation; either version 2 of the License, or
! (at your option) any later version.
!
! This program is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License along
! with this program; if not, write to the Free Software Foundation, Inc.,
! 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
!
!=====================================================================
!
! United States and French Government Sponsorship Acknowledged.

  subroutine prepare_timerun()

  use specfem_par
  use specfem_par_acoustic
  use specfem_par_elastic
  use specfem_par_poroelastic
  use specfem_par_movie

  implicit none
  character(len=256) :: plot_file
  integer :: ier

  ! flag for any movie simulation
  if( EXTERNAL_MESH_MOVIE_SURFACE .or. EXTERNAL_MESH_CREATE_SHAKEMAP .or. &
     MOVIE_SURFACE .or. CREATE_SHAKEMAP .or. MOVIE_VOLUME .or. PNM_GIF_IMAGE ) then
    MOVIE_SIMULATION = .true.
  else
    MOVIE_SIMULATION = .false.
  endif

  ! user info
  if(myrank == 0) then

    write(IMAIN,*)
    if(ATTENUATION) then
      write(IMAIN,*) 'incorporating attenuation using ',N_SLS,' standard linear solids'
      if(USE_OLSEN_ATTENUATION) then
        write(IMAIN,*) 'using Olsen''s attenuation'
      else
        write(IMAIN,*) 'not using Olsen''s attenuation'
      endif
    else
      write(IMAIN,*) 'no attenuation'
    endif

    write(IMAIN,*)
    if(ANISOTROPY) then
      write(IMAIN,*) 'incorporating anisotropy'
    else
      write(IMAIN,*) 'no anisotropy'
    endif

    write(IMAIN,*)
    if(OCEANS) then
      write(IMAIN,*) 'incorporating the oceans using equivalent load'
    else
      write(IMAIN,*) 'no oceans'
    endif

    write(IMAIN,*)
    if(GRAVITY) then
      write(IMAIN,*) 'incorporating gravity'
    else
      write(IMAIN,*) 'no gravity'
    endif

    write(IMAIN,*)
    if(ACOUSTIC_SIMULATION) then
      write(IMAIN,*) 'incorporating acoustic simulation'
    else
      write(IMAIN,*) 'no acoustic simulation'
    endif

    write(IMAIN,*)
    if(ELASTIC_SIMULATION) then
      write(IMAIN,*) 'incorporating elastic simulation'
    else
      write(IMAIN,*) 'no elastic simulation'
    endif

    write(IMAIN,*)
    if(POROELASTIC_SIMULATION) then
      write(IMAIN,*) 'incorporating poroelastic simulation'
    else
      write(IMAIN,*) 'no poroelastic simulation'
    endif
    write(IMAIN,*)

    write(IMAIN,*)
    if(MOVIE_SIMULATION) then
      write(IMAIN,*) 'incorporating movie simulation'
    else
      write(IMAIN,*) 'no movie simulation'
    endif
    write(IMAIN,*)

  endif

  ! synchronize all the processes before assembling the mass matrix
  ! to make sure all the nodes have finished to read their databases
  call sync_all()

  ! sets up mass matrices
  call prepare_timerun_mass_matrices()

  ! initialize acoustic arrays to zero
  if( ACOUSTIC_SIMULATION ) then
    potential_acoustic(:) = 0._CUSTOM_REAL
    potential_dot_acoustic(:) = 0._CUSTOM_REAL
    potential_dot_dot_acoustic(:) = 0._CUSTOM_REAL
    ! put negligible initial value to avoid very slow underflow trapping
    if(FIX_UNDERFLOW_PROBLEM) potential_acoustic(:) = VERYSMALLVAL
  endif

  ! initialize elastic arrays to zero/verysmallvall
  if( ELASTIC_SIMULATION ) then
    displ(:,:) = 0._CUSTOM_REAL
    veloc(:,:) = 0._CUSTOM_REAL
    accel(:,:) = 0._CUSTOM_REAL
    ! put negligible initial value to avoid very slow underflow trapping
    if(FIX_UNDERFLOW_PROBLEM) displ(:,:) = VERYSMALLVAL
  endif


  ! distinguish between single and double precision for reals
  if(CUSTOM_REAL == SIZE_REAL) then
    deltat = sngl(DT)
  else
    deltat = DT
  endif
  deltatover2 = deltat/2._CUSTOM_REAL
  deltatsqover2 = deltat*deltat/2._CUSTOM_REAL

  ! seismograms
  if (nrec_local > 0) then
    ! allocate seismogram array
    allocate(seismograms_d(NDIM,nrec_local,NSTEP),stat=ier)
    if( ier /= 0 ) stop 'error allocating array seismograms_d'
    allocate(seismograms_v(NDIM,nrec_local,NSTEP),stat=ier)
    if( ier /= 0 ) stop 'error allocating array seismograms_v'
    allocate(seismograms_a(NDIM,nrec_local,NSTEP),stat=ier)
    if( ier /= 0 ) stop 'error allocating array seismograms_a'

    ! initialize seismograms
    seismograms_d(:,:,:) = 0._CUSTOM_REAL
    seismograms_v(:,:,:) = 0._CUSTOM_REAL
    seismograms_a(:,:,:) = 0._CUSTOM_REAL
  endif

  ! synchronize all the processes
  call sync_all()

  ! prepares attenuation arrays
  call prepare_timerun_attenuation()

  ! prepares gravity arrays
  call prepare_timerun_gravity()

  ! initializes PML arrays
  if( ABSORBING_CONDITIONS  ) then
    if (SIMULATION_TYPE /= 1 .and. ABSORB_USE_PML )  then
      write(IMAIN,*) 'NOTE: adjoint simulations and PML not supported yet...'
    else
      if( ABSORB_USE_PML ) then
        call PML_initialize()
      endif
    endif
  endif

  ! opens source time function file
  if(PRINT_SOURCE_TIME_FUNCTION .and. myrank == 0) then
    ! print the source-time function
    if(NSOURCES == 1) then
      plot_file = '/plot_source_time_function.txt'
    else
     if(NSOURCES < 10) then
        write(plot_file,"('/plot_source_time_function',i1,'.txt')") NSOURCES
      else
        write(plot_file,"('/plot_source_time_function',i2,'.txt')") NSOURCES
      endif
    endif
    open(unit=IOSTF,file=trim(OUTPUT_FILES)//plot_file,status='unknown')
  endif

  ! user output
  if(myrank == 0) then
    write(IMAIN,*)
    write(IMAIN,*) '           time step: ',sngl(DT),' s'
    write(IMAIN,*) 'number of time steps: ',NSTEP
    write(IMAIN,*) 'total simulated time: ',sngl(NSTEP*DT),' seconds'
    write(IMAIN,*)
  endif

  ! prepares ADJOINT simulations
  call prepare_timerun_adjoint()

  ! prepares noise simulations
  call prepare_timerun_noise()

  ! prepares GPU arrays
  if(GPU_MODE) call prepare_timerun_GPU()

  end subroutine prepare_timerun

!
!-------------------------------------------------------------------------------------------------
!

  subroutine prepare_timerun_mass_matrices()

  use specfem_par
  use specfem_par_acoustic
  use specfem_par_elastic
  use specfem_par_poroelastic
  implicit none

! the mass matrix needs to be assembled with MPI here once and for all
  if(ACOUSTIC_SIMULATION) then
    call assemble_MPI_scalar_ext_mesh(NPROC,NGLOB_AB,rmass_acoustic, &
                        num_interfaces_ext_mesh,max_nibool_interfaces_ext_mesh, &
                        nibool_interfaces_ext_mesh,ibool_interfaces_ext_mesh,&
                        my_neighbours_ext_mesh)

    ! fill mass matrix with fictitious non-zero values to make sure it can be inverted globally
    where(rmass_acoustic <= 0._CUSTOM_REAL) rmass_acoustic = 1._CUSTOM_REAL
    rmass_acoustic(:) = 1._CUSTOM_REAL / rmass_acoustic(:)

  endif ! ACOUSTIC_SIMULATION

  if(ELASTIC_SIMULATION) then
    call assemble_MPI_scalar_ext_mesh(NPROC,NGLOB_AB,rmass, &
                        num_interfaces_ext_mesh,max_nibool_interfaces_ext_mesh, &
                        nibool_interfaces_ext_mesh,ibool_interfaces_ext_mesh, &
                        my_neighbours_ext_mesh)

    ! fill mass matrix with fictitious non-zero values to make sure it can be inverted globally
    where(rmass <= 0._CUSTOM_REAL) rmass = 1._CUSTOM_REAL
    rmass(:) = 1._CUSTOM_REAL / rmass(:)

    if(OCEANS ) then
      if( minval(rmass_ocean_load(:)) <= 0._CUSTOM_REAL) &
        call exit_MPI(myrank,'negative ocean load mass matrix term')
      rmass_ocean_load(:) = 1. / rmass_ocean_load(:)
    endif

  endif ! ELASTIC_SIMULATION

  if(POROELASTIC_SIMULATION) then

    stop 'poroelastic simulation not implemented yet'
    ! but would be something like this...
    call assemble_MPI_scalar_ext_mesh(NPROC,NGLOB_AB,rmass_solid_poroelastic, &
                        num_interfaces_ext_mesh,max_nibool_interfaces_ext_mesh, &
                        nibool_interfaces_ext_mesh,ibool_interfaces_ext_mesh, &
                        my_neighbours_ext_mesh)

    call assemble_MPI_scalar_ext_mesh(NPROC,NGLOB_AB,rmass_fluid_poroelastic, &
                        num_interfaces_ext_mesh,max_nibool_interfaces_ext_mesh, &
                        nibool_interfaces_ext_mesh,ibool_interfaces_ext_mesh, &
                        my_neighbours_ext_mesh)

    ! fills mass matrix with fictitious non-zero values to make sure it can be inverted globally
    where(rmass_solid_poroelastic <= 0._CUSTOM_REAL) rmass_solid_poroelastic = 1._CUSTOM_REAL
    where(rmass_fluid_poroelastic <= 0._CUSTOM_REAL) rmass_fluid_poroelastic = 1._CUSTOM_REAL
    rmass_solid_poroelastic(:) = 1._CUSTOM_REAL / rmass_solid_poroelastic(:)
    rmass_fluid_poroelastic(:) = 1._CUSTOM_REAL / rmass_fluid_poroelastic(:)

  endif ! POROELASTIC_SIMULATION

  if(myrank == 0) write(IMAIN,*) 'end assembling MPI mass matrix'


  end subroutine prepare_timerun_mass_matrices

!
!-------------------------------------------------------------------------------------------------
!

  subroutine prepare_timerun_attenuation()

  use specfem_par
  use specfem_par_acoustic
  use specfem_par_elastic
  use specfem_par_poroelastic
  implicit none

  ! local parameters
  double precision, dimension(N_SLS) :: tau_sigma_dble
  double precision :: f_c_source
  double precision :: MIN_ATTENUATION_PERIOD,MAX_ATTENUATION_PERIOD
  real(kind=CUSTOM_REAL):: scale_factorl
  integer :: i,j,k,ispec,ier
  real(kind=CUSTOM_REAL), dimension(:,:,:,:), allocatable :: scale_factor

  ! if attenuation is on, shift shear moduli to center frequency of absorption period band, i.e.
  ! rescale mu to average (central) frequency for attenuation
  if(ATTENUATION) then

    ! initializes arrays
    one_minus_sum_beta(:,:,:,:) = 1._CUSTOM_REAL
    factor_common(:,:,:,:,:) = 1._CUSTOM_REAL

    allocate( scale_factor(NGLLX,NGLLY,NGLLZ,NSPEC_ATTENUATION_AB),stat=ier)
    if( ier /= 0 ) call exit_mpi(myrank,'error allocation scale_factor')
    scale_factor(:,:,:,:) = 1._CUSTOM_REAL

    ! reads in attenuation arrays
    open(unit=27, file=prname(1:len_trim(prname))//'attenuation.bin', &
          status='old',action='read',form='unformatted',iostat=ier)
    if( ier /= 0 ) then
      print*,'error: could not open ',prname(1:len_trim(prname))//'attenuation.bin'
      call exit_mpi(myrank,'error opening attenuation.bin file')
    endif
    read(27) ispec
    if( ispec /= NSPEC_ATTENUATION_AB ) then
      close(27)
      print*,'error: attenuation file array ',ispec,'should be ',NSPEC_ATTENUATION_AB
      call exit_mpi(myrank,'error attenuation array dimensions, please recompile and rerun generate_databases')
    endif
    read(27) one_minus_sum_beta
    read(27) factor_common
    read(27) scale_factor
    close(27)


    ! gets stress relaxation times tau_sigma, i.e.
    ! precalculates tau_sigma depending on period band (constant for all Q_mu), and
    ! determines central frequency f_c_source of attenuation period band
    call get_attenuation_constants(min_resolved_period,tau_sigma_dble,&
              f_c_source,MIN_ATTENUATION_PERIOD,MAX_ATTENUATION_PERIOD)

    ! determines alphaval,betaval,gammaval for runge-kutta scheme
    if(CUSTOM_REAL == SIZE_REAL) then
      tau_sigma(:) = sngl(tau_sigma_dble(:))
    else
      tau_sigma(:) = tau_sigma_dble(:)
    endif
    call get_attenuation_memory_values(tau_sigma,deltat,alphaval,betaval,gammaval)

    ! shifts shear moduli
    do ispec = 1,NSPEC_AB

      ! skips non elastic elements
      if( ispec_is_elastic(ispec) .eqv. .false. ) cycle

      ! determines attenuation factors for each GLL point
      do k=1,NGLLZ
        do j=1,NGLLY
          do i=1,NGLLX

            ! scales only mu moduli
            scale_factorl = scale_factor(i,j,k,ispec)
            mustore(i,j,k,ispec) = mustore(i,j,k,ispec) * scale_factorl

          enddo
        enddo
      enddo
    enddo

    deallocate(scale_factor)

    ! statistics
    ! user output
    if( myrank == 0 ) then
      write(IMAIN,*)
      write(IMAIN,*) "attenuation: "
      write(IMAIN,*) "  reference period (s)   : ",sngl(1.0/ATTENUATION_f0_REFERENCE), &
                    " frequency: ",sngl(ATTENUATION_f0_REFERENCE)
      write(IMAIN,*) "  period band min/max (s): ",sngl(MIN_ATTENUATION_PERIOD),sngl(MAX_ATTENUATION_PERIOD)
      write(IMAIN,*) "  central period (s)     : ",sngl(1.0/f_c_source), &
                    " frequency: ",sngl(f_c_source)
      write(IMAIN,*)
    endif

    ! clear memory variables if attenuation
    ! initialize memory variables for attenuation
    epsilondev_xx(:,:,:,:) = 0._CUSTOM_REAL
    epsilondev_yy(:,:,:,:) = 0._CUSTOM_REAL
    epsilondev_xy(:,:,:,:) = 0._CUSTOM_REAL
    epsilondev_xz(:,:,:,:) = 0._CUSTOM_REAL
    epsilondev_yz(:,:,:,:) = 0._CUSTOM_REAL

    R_xx(:,:,:,:,:) = 0._CUSTOM_REAL
    R_yy(:,:,:,:,:) = 0._CUSTOM_REAL
    R_xy(:,:,:,:,:) = 0._CUSTOM_REAL
    R_xz(:,:,:,:,:) = 0._CUSTOM_REAL
    R_yz(:,:,:,:,:) = 0._CUSTOM_REAL

    if(FIX_UNDERFLOW_PROBLEM) then
      R_xx(:,:,:,:,:) = VERYSMALLVAL
      R_yy(:,:,:,:,:) = VERYSMALLVAL
      R_xy(:,:,:,:,:) = VERYSMALLVAL
      R_xz(:,:,:,:,:) = VERYSMALLVAL
      R_yz(:,:,:,:,:) = VERYSMALLVAL
    endif
  endif

  end subroutine prepare_timerun_attenuation

!
!-------------------------------------------------------------------------------------------------
!

  subroutine prepare_timerun_gravity()

! precomputes gravity factors

  use specfem_par
  use specfem_par_acoustic
  use specfem_par_elastic
  use specfem_par_poroelastic
  implicit none

  ! local parameters
  double precision RICB,RCMB,RTOPDDOUBLEPRIME, &
    R80,R220,R400,R600,R670,R771,RMOHO,RMIDDLE_CRUST,ROCEAN
  double precision :: rspl_gravity(NR),gspl(NR),gspl2(NR)
  double precision :: radius,g,dg ! radius_km
  !double precision :: g_cmb_dble,g_icb_dble
  double precision :: rho,drhodr,vp,vs,Qkappa,Qmu
  integer :: nspl_gravity !int_radius
  integer :: i,j,k,iglob,ier

  ! sets up weights needed for integration of gravity
  do k=1,NGLLZ
    do j=1,NGLLY
      do i=1,NGLLX
        wgll_cube(i,j,k) = sngl( wxgll(i)*wygll(j)*wzgll(k) )
      enddo
    enddo
  enddo

  ! store g, rho and dg/dr=dg using normalized radius in lookup table every 100 m
  ! get density and velocity from PREM model using dummy doubling flag
  ! this assumes that the gravity perturbations are small and smooth
  ! and that we can neglect the 3D model and use PREM every 100 m in all cases
  ! this is probably a rather reasonable assumption
  if(GRAVITY) then

    ! allocates gravity arrays
    allocate( minus_deriv_gravity(NGLOB_AB), &
             minus_g(NGLOB_AB), stat=ier)
    if( ier /= 0 ) stop 'error allocating gravity arrays'

    ! sets up spline table
    call make_gravity(nspl_gravity,rspl_gravity,gspl,gspl2, &
                          ROCEAN,RMIDDLE_CRUST,RMOHO,R80,R220,R400,R600,R670, &
                          R771,RTOPDDOUBLEPRIME,RCMB,RICB)

    ! pre-calculates gravity terms for all global points
    do iglob = 1,NGLOB_AB

      ! normalized radius ( zstore values given in m, negative values for depth)
      radius = ( R_EARTH + zstore(iglob) ) / R_EARTH
      call spline_evaluation(rspl_gravity,gspl,gspl2,nspl_gravity,radius,g)

      ! use PREM density profile to calculate gravity (fine for other 1D models)
      call model_prem_iso(radius,rho,drhodr,vp,vs,Qkappa,Qmu, &
                        RICB,RCMB,RTOPDDOUBLEPRIME, &
                        R600,R670,R220,R771,R400,R80,RMOHO,RMIDDLE_CRUST,ROCEAN)

      dg = 4.0d0*rho - 2.0d0*g/radius

      ! re-dimensionalize
      g = g * R_EARTH*(PI*GRAV*RHOAV) ! in m / s^2 ( should be around 10 m/s^2 )
      dg = dg * R_EARTH*(PI*GRAV*RHOAV) / R_EARTH ! gradient d/dz g , in 1/s^2

      minus_deriv_gravity(iglob) = - dg
      minus_g(iglob) = - g ! in negative z-direction

      ! debug
      !if( iglob == 1 .or. iglob == 1000 .or. iglob == 10000 ) then
      !  ! re-dimensionalize
      !  radius = radius * R_EARTH ! in m
      !  vp = vp * R_EARTH*dsqrt(PI*GRAV*RHOAV)  ! in m / s
      !  rho = rho  * RHOAV  ! in kg / m^3
      !  print*,'gravity: radius=',radius,'g=',g,'depth=',radius-R_EARTH
      !  print*,'vp=',vp,'rho=',rho,'kappa=',(vp**2) * rho
      !  print*,'minus_g..=',minus_g(iglob)
      !endif
    enddo

  else

    ! allocates dummy gravity arrays
    allocate( minus_deriv_gravity(0), &
             minus_g(0), stat=ier)
    if( ier /= 0 ) stop 'error allocating gravity arrays'

  endif

  end subroutine prepare_timerun_gravity


!
!-------------------------------------------------------------------------------------------------
!

  subroutine prepare_timerun_adjoint()

! prepares adjoint simulations

  use specfem_par
  use specfem_par_acoustic
  use specfem_par_elastic
  use specfem_par_poroelastic
  implicit none
  ! local parameters
  integer :: ier
  integer(kind=8) :: filesize

! seismograms
  if (nrec_local > 0 .and. SIMULATION_TYPE == 2 ) then
    ! allocate Frechet derivatives array
    allocate(Mxx_der(nrec_local),Myy_der(nrec_local), &
            Mzz_der(nrec_local),Mxy_der(nrec_local), &
            Mxz_der(nrec_local),Myz_der(nrec_local), &
            sloc_der(NDIM,nrec_local),stat=ier)
    if( ier /= 0 ) stop 'error allocating array Mxx_der and following arrays'
    Mxx_der = 0._CUSTOM_REAL
    Myy_der = 0._CUSTOM_REAL
    Mzz_der = 0._CUSTOM_REAL
    Mxy_der = 0._CUSTOM_REAL
    Mxz_der = 0._CUSTOM_REAL
    Myz_der = 0._CUSTOM_REAL
    sloc_der = 0._CUSTOM_REAL

    allocate(seismograms_eps(NDIM,NDIM,nrec_local,NSTEP),stat=ier)
    if( ier /= 0 ) stop 'error allocating array seismograms_eps'
    seismograms_eps(:,:,:,:) = 0._CUSTOM_REAL
  endif

! timing
  if (SIMULATION_TYPE == 3) then

    ! backward/reconstructed wavefields: time stepping is in time-reversed sense
    ! (negative time increments)
    if(CUSTOM_REAL == SIZE_REAL) then
      b_deltat = - sngl(DT)
    else
      b_deltat = - DT
    endif
    b_deltatover2 = b_deltat/2._CUSTOM_REAL
    b_deltatsqover2 = b_deltat*b_deltat/2._CUSTOM_REAL

  endif

! attenuation backward memories
  if( ATTENUATION .and. SIMULATION_TYPE == 3 ) then

    ! precompute Runge-Kutta coefficients if attenuation
    call get_attenuation_memory_values(tau_sigma,b_deltat,b_alphaval,b_betaval,b_gammaval)

  endif

! initializes adjoint kernels and reconstructed/backward wavefields
  if (SIMULATION_TYPE == 3)  then
    ! elastic domain
    if( ELASTIC_SIMULATION ) then
      rho_kl(:,:,:,:)   = 0._CUSTOM_REAL
      mu_kl(:,:,:,:)    = 0._CUSTOM_REAL
      kappa_kl(:,:,:,:) = 0._CUSTOM_REAL

      if ( APPROXIMATE_HESS_KL ) &
        hess_kl(:,:,:,:)   = 0._CUSTOM_REAL

      ! reconstructed/backward elastic wavefields
      b_displ = 0._CUSTOM_REAL
      b_veloc = 0._CUSTOM_REAL
      b_accel = 0._CUSTOM_REAL
      if(FIX_UNDERFLOW_PROBLEM) b_displ = VERYSMALLVAL

      ! memory variables if attenuation
      if( ATTENUATION ) then
         b_R_xx = 0._CUSTOM_REAL
         b_R_yy = 0._CUSTOM_REAL
         b_R_xy = 0._CUSTOM_REAL
         b_R_xz = 0._CUSTOM_REAL
         b_R_yz = 0._CUSTOM_REAL
         b_epsilondev_xx = 0._CUSTOM_REAL
         b_epsilondev_yy = 0._CUSTOM_REAL
         b_epsilondev_xy = 0._CUSTOM_REAL
         b_epsilondev_xz = 0._CUSTOM_REAL
         b_epsilondev_yz = 0._CUSTOM_REAL
      endif

    endif

    ! acoustic domain
    if( ACOUSTIC_SIMULATION ) then
      rho_ac_kl(:,:,:,:)   = 0._CUSTOM_REAL
      kappa_ac_kl(:,:,:,:) = 0._CUSTOM_REAL

      if ( APPROXIMATE_HESS_KL ) &
        hess_ac_kl(:,:,:,:)   = 0._CUSTOM_REAL

      ! reconstructed/backward acoustic potentials
      b_potential_acoustic = 0._CUSTOM_REAL
      b_potential_dot_acoustic = 0._CUSTOM_REAL
      b_potential_dot_dot_acoustic = 0._CUSTOM_REAL
      if(FIX_UNDERFLOW_PROBLEM) b_potential_acoustic = VERYSMALLVAL

    endif
  endif

! initialize Moho boundary index
  if (SAVE_MOHO_MESH .and. SIMULATION_TYPE == 3) then
    ispec2D_moho_top = 0
    ispec2D_moho_bot = 0
  endif

! stacey absorbing fields will be reconstructed for adjoint simulations
! using snapshot files of wavefields
  if( ABSORBING_CONDITIONS ) then

    ! opens absorbing wavefield saved/to-be-saved by forward simulations
    if( num_abs_boundary_faces > 0 .and. (SIMULATION_TYPE == 3 .or. &
          (SIMULATION_TYPE == 1 .and. SAVE_FORWARD)) ) then

      b_num_abs_boundary_faces = num_abs_boundary_faces

      ! elastic domains
      if( ELASTIC_SIMULATION) then
        ! allocates wavefield
        allocate(b_absorb_field(NDIM,NGLLSQUARE,b_num_abs_boundary_faces),stat=ier)
        if( ier /= 0 ) stop 'error allocating array b_absorb_field'

        ! size of single record
        b_reclen_field = CUSTOM_REAL * NDIM * NGLLSQUARE * num_abs_boundary_faces

        ! check integer size limit: size of b_reclen_field must fit onto an 4-byte integer
        if( num_abs_boundary_faces > 2147483647 / (CUSTOM_REAL * NDIM * NGLLSQUARE) ) then
          print *,'reclen needed exceeds integer 4-byte limit: ',b_reclen_field
          print *,'  ',CUSTOM_REAL, NDIM, NGLLSQUARE, num_abs_boundary_faces
          print*,'bit size fortran: ',bit_size(b_reclen_field)
          call exit_MPI(myrank,"error b_reclen_field integer limit")
        endif

        ! total file size
        filesize = b_reclen_field
        filesize = filesize*NSTEP

        if (SIMULATION_TYPE == 3) then
          ! opens existing files

          ! uses fortran routines for reading
          !open(unit=IOABS,file=trim(prname)//'absorb_field.bin',status='old',&
          !      action='read',form='unformatted',access='direct', &
          !      recl=b_reclen_field+2*4,iostat=ier )
          !if( ier /= 0 ) call exit_mpi(myrank,'error opening proc***_absorb_field.bin file')
          ! uses c routines for faster reading
          call open_file_abs_r(0,trim(prname)//'absorb_field.bin', &
                              len_trim(trim(prname)//'absorb_field.bin'), &
                              filesize)

        else
          ! opens new file
          ! uses fortran routines for writing
          !open(unit=IOABS,file=trim(prname)//'absorb_field.bin',status='unknown',&
          !      form='unformatted',access='direct',&
          !      recl=b_reclen_field+2*4,iostat=ier )
          !if( ier /= 0 ) call exit_mpi(myrank,'error opening proc***_absorb_field.bin file')
          ! uses c routines for faster writing (file index 0 for acoutic domain file)
          call open_file_abs_w(0,trim(prname)//'absorb_field.bin', &
                              len_trim(trim(prname)//'absorb_field.bin'), &
                              filesize)

        endif
      endif

      ! acoustic domains
      if( ACOUSTIC_SIMULATION) then
        ! allocates wavefield
        allocate(b_absorb_potential(NGLLSQUARE,b_num_abs_boundary_faces),stat=ier)
        if( ier /= 0 ) stop 'error allocating array b_absorb_potential'

        ! size of single record
        b_reclen_potential = CUSTOM_REAL * NGLLSQUARE * num_abs_boundary_faces

        ! check integer size limit: size of b_reclen_potential must fit onto an 4-byte integer
        if( num_abs_boundary_faces > 2147483647 / (CUSTOM_REAL * NGLLSQUARE) ) then
          print *,'reclen needed exceeds integer 4-byte limit: ',b_reclen_potential
          print *,'  ',CUSTOM_REAL, NGLLSQUARE, num_abs_boundary_faces
          print*,'bit size fortran: ',bit_size(b_reclen_potential)
          call exit_MPI(myrank,"error b_reclen_potential integer limit")
        endif

        ! total file size (two lines to implicitly convert to 8-byte integers)
        filesize = b_reclen_potential
        filesize = filesize*NSTEP

        ! debug check size limit
        !if( NSTEP > 2147483647 / b_reclen_potential ) then
        !  print *,'file size needed exceeds integer 4-byte limit: ',b_reclen_potential,NSTEP
        !  print *,'  ',CUSTOM_REAL, NGLLSQUARE, num_abs_boundary_faces,NSTEP
        !  print*,'file size fortran: ',filesize
        !  print*,'file bit size fortran: ',bit_size(filesize)
        !endif

        if (SIMULATION_TYPE == 3) then
          ! opens existing files
          ! uses fortran routines for reading
          !open(unit=IOABS_AC,file=trim(prname)//'absorb_potential.bin',status='old',&
          !      action='read',form='unformatted',access='direct', &
          !      recl=b_reclen_potential+2*4,iostat=ier )
          !if( ier /= 0 ) call exit_mpi(myrank,'error opening proc***_absorb_potential.bin file')

          ! uses c routines for faster reading
          call open_file_abs_r(1,trim(prname)//'absorb_potential.bin', &
                              len_trim(trim(prname)//'absorb_potential.bin'), &
                              filesize)

        else
          ! opens new file
          ! uses fortran routines for writing
          !open(unit=IOABS_AC,file=trim(prname)//'absorb_potential.bin',status='unknown',&
          !      form='unformatted',access='direct',&
          !      recl=b_reclen_potential+2*4,iostat=ier )
          !if( ier /= 0 ) call exit_mpi(myrank,'error opening proc***_absorb_potential.bin file')
          ! uses c routines for faster writing (file index 1 for acoutic domain file)
          call open_file_abs_w(1,trim(prname)//'absorb_potential.bin', &
                              len_trim(trim(prname)//'absorb_potential.bin'), &
                              filesize)

        endif
      endif
    else
      ! needs dummy array
      b_num_abs_boundary_faces = 1
      if( ELASTIC_SIMULATION ) then
        allocate(b_absorb_field(NDIM,NGLLSQUARE,b_num_abs_boundary_faces),stat=ier)
        if( ier /= 0 ) stop 'error allocating array b_absorb_field'
      endif

      if( ACOUSTIC_SIMULATION ) then
        allocate(b_absorb_potential(NGLLSQUARE,b_num_abs_boundary_faces),stat=ier)
        if( ier /= 0 ) stop 'error allocating array b_absorb_potential'
      endif
    endif
  else ! ABSORBING_CONDITIONS
    ! needs dummy array
    b_num_abs_boundary_faces = 1
    if( ELASTIC_SIMULATION ) then
      allocate(b_absorb_field(NDIM,NGLLSQUARE,b_num_abs_boundary_faces),stat=ier)
      if( ier /= 0 ) stop 'error allocating array b_absorb_field'
    endif

    if( ACOUSTIC_SIMULATION ) then
      allocate(b_absorb_potential(NGLLSQUARE,b_num_abs_boundary_faces),stat=ier)
      if( ier /= 0 ) stop 'error allocating array b_absorb_potential'
    endif
  endif


  end subroutine prepare_timerun_adjoint

!
!-------------------------------------------------------------------------------------------------
!

  subroutine prepare_timerun_noise()

! prepares noise simulations

  use specfem_par
  use specfem_par_acoustic
  use specfem_par_elastic
  use specfem_par_poroelastic
  use specfem_par_movie
  implicit none
  ! local parameters
  integer :: ier

  ! for noise simulations
  if ( NOISE_TOMOGRAPHY /= 0 ) then

    ! checks if free surface is defined
    if( num_free_surface_faces == 0 ) then
      stop 'error: noise simulations need a free surface'
    endif

    ! allocates arrays
    allocate(noise_sourcearray(NDIM,NGLLX,NGLLY,NGLLZ,NSTEP),stat=ier)
    if( ier /= 0 ) call exit_mpi(myrank,'error allocating noise source array')

    allocate(normal_x_noise(NGLLSQUARE*num_free_surface_faces),stat=ier)
    if( ier /= 0 ) stop 'error allocating array normal_x_noise'
    allocate(normal_y_noise(NGLLSQUARE*num_free_surface_faces),stat=ier)
    if( ier /= 0 ) stop 'error allocating array normal_y_noise'
    allocate(normal_z_noise(NGLLSQUARE*num_free_surface_faces),stat=ier)
    if( ier /= 0 ) stop 'error allocating array normal_z_noise'
    allocate(mask_noise(NGLLSQUARE*num_free_surface_faces),stat=ier)
    if( ier /= 0 ) stop 'error allocating array mask_noise'
    allocate(noise_surface_movie(NDIM,NGLLSQUARE,num_free_surface_faces),stat=ier)
    if( ier /= 0 ) stop 'error allocating array noise_surface_movie'

    ! initializes
    noise_sourcearray(:,:,:,:,:) = 0._CUSTOM_REAL
    normal_x_noise(:)            = 0._CUSTOM_REAL
    normal_y_noise(:)            = 0._CUSTOM_REAL
    normal_z_noise(:)            = 0._CUSTOM_REAL
    mask_noise(:)                = 0._CUSTOM_REAL
    noise_surface_movie(:,:,:) = 0._CUSTOM_REAL

    ! sets up noise source for master receiver station
    call read_parameters_noise(myrank,nrec,NSTEP,NGLLSQUARE*num_free_surface_faces, &
                               islice_selected_rec,xi_receiver,eta_receiver,gamma_receiver,nu, &
                               noise_sourcearray,xigll,yigll,zigll, &
                               ibool, &
                               xstore,ystore,zstore, &
                               irec_master_noise,normal_x_noise,normal_y_noise,normal_z_noise,mask_noise, &
                               NSPEC_AB,NGLOB_AB, &
                               num_free_surface_faces,free_surface_ispec,free_surface_ijk, &
                               ispec_is_acoustic)

    ! checks flags for noise simulation
    call check_parameters_noise(myrank,NOISE_TOMOGRAPHY,SIMULATION_TYPE,SAVE_FORWARD, &
                                LOCAL_PATH, &
                                num_free_surface_faces,NSTEP)
  endif

  end subroutine prepare_timerun_noise

!
!-------------------------------------------------------------------------------------------------
!

  subroutine prepare_timerun_GPU()

  use specfem_par
  use specfem_par_acoustic
  use specfem_par_elastic
  use specfem_par_poroelastic
  use specfem_par_movie

  implicit none
  real :: free_mb,used_mb,total_mb
  integer :: ncuda_devices,ncuda_devices_min,ncuda_devices_max

  ! GPU_MODE now defined in Par_file
  if(myrank == 0 ) then
    write(IMAIN,*)
    write(IMAIN,*) "GPU_MODE Active. Preparing Fields and Constants on Device."
    write(IMAIN,*)
  endif

  ! initializes GPU and outputs info to files for all processes
  call prepare_cuda_device(myrank,ncuda_devices)

  ! collects min/max of local devices found for statistics
  call sync_all()
  call min_all_i(ncuda_devices,ncuda_devices_min)
  call max_all_i(ncuda_devices,ncuda_devices_max)

  ! prepares general fields on GPU
  call prepare_constants_device(Mesh_pointer, &
                                  NGLLX, NSPEC_AB, NGLOB_AB, &
                                  xix, xiy, xiz, etax,etay,etaz, gammax, gammay, gammaz, &
                                  kappastore, mustore,ibool, &
                                  num_interfaces_ext_mesh, max_nibool_interfaces_ext_mesh, &
                                  nibool_interfaces_ext_mesh, ibool_interfaces_ext_mesh, &
                                  hprime_xx, hprime_yy, hprime_zz, &
                                  hprimewgll_xx, hprimewgll_yy, hprimewgll_zz, &
                                  wgllwgll_xy, wgllwgll_xz, wgllwgll_yz, &
                                  ABSORBING_CONDITIONS, &
                                  abs_boundary_ispec, abs_boundary_ijk, &
                                  abs_boundary_normal, &
                                  abs_boundary_jacobian2Dw, &
                                  num_abs_boundary_faces, &
                                  ispec_is_inner, &
                                  NSOURCES, nsources_local, &
                                  sourcearrays, islice_selected_source, ispec_selected_source, &
                                  number_receiver_global, ispec_selected_rec, &
                                  nrec, nrec_local, &
                                  SIMULATION_TYPE, &
                                  USE_MESH_COLORING_GPU, &
                                  nspec_acoustic,nspec_elastic)


  ! prepares fields on GPU for acoustic simulations
  if( ACOUSTIC_SIMULATION ) then
    call prepare_fields_acoustic_device(Mesh_pointer,rmass_acoustic,rhostore,kappastore, &
                                  num_phase_ispec_acoustic,phase_ispec_inner_acoustic, &
                                  ispec_is_acoustic, &
                                  NOISE_TOMOGRAPHY,num_free_surface_faces, &
                                  free_surface_ispec,free_surface_ijk, &
                                  ABSORBING_CONDITIONS,b_reclen_potential,b_absorb_potential, &
                                  ELASTIC_SIMULATION, num_coupling_ac_el_faces, &
                                  coupling_ac_el_ispec,coupling_ac_el_ijk, &
                                  coupling_ac_el_normal,coupling_ac_el_jacobian2Dw, &
                                  num_colors_outer_acoustic,num_colors_inner_acoustic, &
                                  num_elem_colors_acoustic)

    if( SIMULATION_TYPE == 3 ) &
      call prepare_fields_acoustic_adj_dev(Mesh_pointer, &
                                  SIMULATION_TYPE, &
                                  APPROXIMATE_HESS_KL)

  endif

  ! prepares fields on GPU for elastic simulations
  if( ELASTIC_SIMULATION ) then
    call prepare_fields_elastic_device(Mesh_pointer, NDIM*NGLOB_AB, &
                                  rmass,rho_vp,rho_vs, &
                                  num_phase_ispec_elastic,phase_ispec_inner_elastic, &
                                  ispec_is_elastic, &
                                  ABSORBING_CONDITIONS,b_absorb_field,b_reclen_field, &
                                  SIMULATION_TYPE,SAVE_FORWARD, &
                                  COMPUTE_AND_STORE_STRAIN, &
                                  epsilondev_xx,epsilondev_yy,epsilondev_xy, &
                                  epsilondev_xz,epsilondev_yz, &
                                  ATTENUATION, &
                                  size(R_xx), &
                                  R_xx,R_yy,R_xy,R_xz,R_yz, &
                                  one_minus_sum_beta,factor_common, &
                                  alphaval,betaval,gammaval, &
                                  OCEANS,rmass_ocean_load, &
                                  NOISE_TOMOGRAPHY, &
                                  free_surface_normal,free_surface_ispec,free_surface_ijk, &
                                  num_free_surface_faces, &
                                  ACOUSTIC_SIMULATION, &
                                  num_colors_outer_elastic,num_colors_inner_elastic, &
                                  num_elem_colors_elastic, &
                                  ANISOTROPY, &
                                  c11store,c12store,c13store,c14store,c15store,c16store, &
                                  c22store,c23store,c24store,c25store,c26store, &
                                  c33store,c34store,c35store,c36store, &
                                  c44store,c45store,c46store,c55store,c56store,c66store)

    if( SIMULATION_TYPE == 3 ) &
      call prepare_fields_elastic_adj_dev(Mesh_pointer, NDIM*NGLOB_AB, &
                                  SIMULATION_TYPE, &
                                  COMPUTE_AND_STORE_STRAIN, &
                                  epsilon_trace_over_3, &
                                  b_epsilondev_xx,b_epsilondev_yy,b_epsilondev_xy, &
                                  b_epsilondev_xz,b_epsilondev_yz, &
                                  b_epsilon_trace_over_3, &
                                  ATTENUATION,size(R_xx), &
                                  b_R_xx,b_R_yy,b_R_xy,b_R_xz,b_R_yz, &
                                  b_alphaval,b_betaval,b_gammaval, &
                                  APPROXIMATE_HESS_KL)

  endif

  ! prepares needed receiver array for adjoint runs
  if( SIMULATION_TYPE == 2 .or. SIMULATION_TYPE == 3 ) &
    call prepare_sim2_or_3_const_device(Mesh_pointer, &
                                       islice_selected_rec,size(islice_selected_rec), &
                                       nadj_rec_local,nrec,myrank)

  ! prepares fields on GPU for noise simulations
  if ( NOISE_TOMOGRAPHY > 0 ) then
    ! note: noise tomography is only supported for elastic domains so far.

    ! copies noise  arrays to GPU
    call prepare_fields_noise_device(Mesh_pointer, NSPEC_AB, NGLOB_AB, &
                                  free_surface_ispec, &
                                  free_surface_ijk, &
                                  num_free_surface_faces, &
                                  SIMULATION_TYPE,NOISE_TOMOGRAPHY, &
                                  NSTEP,noise_sourcearray, &
                                  normal_x_noise,normal_y_noise,normal_z_noise, &
                                  mask_noise,free_surface_jacobian2Dw)

  endif ! NOISE_TOMOGRAPHY

  ! prepares gravity arrays
  if( GRAVITY ) then
    call prepare_fields_gravity_device(Mesh_pointer,GRAVITY, &
                                    minus_deriv_gravity,minus_g,wgll_cube,&
                                    ACOUSTIC_SIMULATION,rhostore)
  endif
  
  ! sends initial data to device

  ! puts acoustic initial fields onto GPU
  if( ACOUSTIC_SIMULATION ) then
    call transfer_fields_ac_to_device(NGLOB_AB,potential_acoustic, &
                          potential_dot_acoustic,potential_dot_dot_acoustic,Mesh_pointer)
    if( SIMULATION_TYPE == 3 ) &
      call transfer_b_fields_ac_to_device(NGLOB_AB,b_potential_acoustic, &
                          b_potential_dot_acoustic,b_potential_dot_dot_acoustic,Mesh_pointer)
  endif

  ! puts elastic initial fields onto GPU
  if( ELASTIC_SIMULATION ) then
    ! transfer forward and backward fields to device with initial values
    call transfer_fields_el_to_device(NDIM*NGLOB_AB,displ,veloc,accel,Mesh_pointer)
    if(SIMULATION_TYPE == 3) &
      call transfer_b_fields_to_device(NDIM*NGLOB_AB,b_displ,b_veloc,b_accel,Mesh_pointer)
  endif

  ! outputs GPU usage to files for all processes
  call output_free_device_memory(myrank)

  ! outputs usage for main process
  if( myrank == 0 ) then
    write(IMAIN,*)"  GPU number of devices per node: min =",ncuda_devices_min
    write(IMAIN,*)"                                  max =",ncuda_devices_max
    write(IMAIN,*)

    call get_free_device_memory(free_mb,used_mb,total_mb)
    write(IMAIN,*)"  GPU usage: free  =",free_mb," MB",nint(free_mb/total_mb*100.0),"%"
    write(IMAIN,*)"             used  =",used_mb," MB",nint(used_mb/total_mb*100.0),"%"
    write(IMAIN,*)"             total =",total_mb," MB",nint(total_mb/total_mb*100.0),"%"
    write(IMAIN,*)
  endif

  end subroutine prepare_timerun_GPU
