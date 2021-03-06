#ifdef HAVE_CONFIG_H
#include "config.h"
#endif


#undef  _CUBE_VEL
#define _SPHERE_VEL
module shal_movie_mod
#ifndef PIO_INTERP
  ! ---------------------
  use kinds, only : real_kind
  ! ---------------------
  use dimensions_mod, only : np, ne, nelem, nelemd, nlev, nelemdmax, &
       GlobalUniqueCols, npsq 
  ! ---------------------
  use hybrid_mod, only : hybrid_t
  ! ---------------------
#ifdef _MPI
  use parallel_mod, only : mpireal_t, mpi_max, iam, abortmp, mpi_sum, mpiinteger_t
#else
  use parallel_mod, only : iam, abortmp
#endif
  ! ---------------------
  use time_mod, only : timelevel_t
  ! ---------------------
  use control_mod, only : test_case, runtype, kmass, geometry
  ! ---------------------
  use element_mod, only : element_t
  ! ---------------------
  use coordinate_systems_mod, only : cartesian2d_t, spherical_polar_t
  ! ---------------------
  use physical_constants, only : omega, g, rearth, dd_pi, g
  use derivative_mod, only : derivative_t, vorticity
  ! ---------------------

!  use interpolate_mod
  ! ---------------------
  use common_io_mod, only : &
       output_start_time,   &
       output_end_time,     &
       output_frequency,    &
       output_dir,          &
       max_output_variables,&
       max_output_streams,  &
       nf_selectedvar, &
       nf_handle, &
       nfsizekind, &
       get_current_varnames, &
       nf_int, &
       nf_double, &
       varname_len, &
       PIOFS

  use netcdf_io_mod, only : &
       nf_output_init_begin,&
       nf_output_register_dims, &
       nf_output_register_variables,&
       nf_variable_attributes, &
       nf_global_attribute, &
       nf_output_init_complete,  &
       nf_advance_frame, &
       nf_close_all, &
       nf_get_frame, &
       nf_put_var => nf_put_var_netcdf, &
       iodesc2d, iodesc3d, iodescT

  use pio, only : PIO_InitDecomp, pio_setdebuglevel, pio_double, pio_closefile, & 
                  pio_iotask_rank
  ! ---------------------
  use dof_mod, only : UniqueNcolsP, Uniquepoints, UniqueCoords, CreateUniqueIndex
  ! ---------------------

    use common_movie_mod, only: varrequired, vartype, varnames, varcnt, vardims, &
	dimnames, maxdims

    use viscosity_mod, only: compute_zeta_C0_contra, compute_div_C0_contra, compute_pv_C0_contra, compute_eta_C0_contra


implicit none




private
  public :: shal_movie_init
  public :: shal_movie_output
  public :: shal_movie_finish
  public :: setvarnames

! local size of variable block for output
  type(nf_handle), target, save :: ncdf(max_output_streams)
  integer :: nxyp
contains
  subroutine GetDOF(elem, gcols, nz, compdof)

    type(element_t), intent(in) :: elem(:)
    integer, intent(in) :: gcols, nz
    integer, intent(out) :: compdof(:)
    integer :: k, i, ie, icnt

    icnt=0
    do k=1,nz
       do ie=1,nelemd
          do i=1,elem(ie)%idxp%NumUniquePts
             icnt=icnt+1
             compDOF(icnt)=elem(ie)%idxp%UniquePtOffset+i-1+(k-1)*GCols
          end do
       end do
    end do
  end subroutine GetDOF


  subroutine shal_movie_init(elem, hybrid)
    type (element_t), intent(in)    :: elem(:)
    type (hybrid_t), intent(in)     :: hybrid
    ! Local variables
    integer ie,i,j,k,ios,ii,jj,base
    integer :: v1(4), vstart, gstart
    integer(kind=nfsizekind) :: start(2), count(2)
    integer :: iorank
    integer :: dimsize(maxdims), st,en
    integer, allocatable :: compDOF(:)
    real (kind=real_kind),allocatable, dimension(:) :: latp,lonp
    real(kind=real_kind),allocatable  :: var1(:,:),var2(:,:)
    if (hybrid%par%masterproc) print *,'PIO initialization'
    call nf_output_init_begin(ncdf,hybrid%par%masterproc,hybrid%par%nprocs,hybrid%par%rank, &
         hybrid%par%comm,test_case,runtype)
    nxyp=0
    do ie=1,nelemd
      nxyp=nxyp+elem(ie)%idxP%NumUniquePts
    enddo

    dimsize = (/GlobalUniqueCols,nlev,nelem,0/)
    call nf_output_register_dims(ncdf, maxdims, dimnames, dimsize)

    allocate(compdof(nxyp*nlev), latp(nxyp),lonp(nxyp))
    ! Create the DOF arrays
    call getDOF(elem, GlobalUniqueCols, 1, compdof)
    call PIO_initDecomp(PIOFS, pio_double,(/GlobalUniqueCols/),&
         compDOF(1:nxyp),IOdesc2D)

    call getDOF(elem, GlobalUniqueCols, nlev, compdof)
    call PIO_initDecomp(PIOFS, pio_double,(/GlobalUniqueCols,nlev/),&
         compDOF,IOdesc3D)



! this is a trivial case for the time variable
    iorank=pio_iotask_rank(PIOFS)
    if(iorank==0) then
       compdof(1)=1
    else
       compdof(1)=0
    end if
    start=-1
    count=-1
    call PIO_initDecomp(PIOFS,pio_double,(/1/),&
         compDOF(1:1),IOdescT)
    deallocate(compdof)


    call nf_output_register_variables(ncdf,varcnt,varnames,vardims,vartype,varrequired)
    call nf_global_attribute(ncdf, 'np', np)
    call nf_global_attribute(ncdf, 'ne', ne)
    call nf_variable_attributes(ncdf, 'T', 'Temperature','degrees kelvin')
    call nf_variable_attributes(ncdf, 'time', 'Model elapsed time','days')

if (geometry == "plane") then
    call nf_variable_attributes(ncdf, 'area', 'area weights','m^2','coordinates','x y')
    call nf_variable_attributes(ncdf, 'u', 'x-dir wind component','meters/second')
    call nf_variable_attributes(ncdf, 'v', 'y-dir wind component','meters/second')
    call nf_variable_attributes(ncdf, 'lat', 'column x','m')
    call nf_variable_attributes(ncdf, 'lon', 'column y','m')
else if (geometry == "sphere") then
    call nf_variable_attributes(ncdf, 'area', 'area weights','radians^2','coordinates','lat lon')
    call nf_variable_attributes(ncdf, 'u', 'longitudinal wind component','meters/second')
    call nf_variable_attributes(ncdf, 'v', 'latitudinal wind component','meters/second')
    call nf_variable_attributes(ncdf, 'lat', 'column latitude','degrees_north')
    call nf_variable_attributes(ncdf, 'lon', 'column longitude','degrees_east')
end if

    call nf_output_init_complete(ncdf)

    call PIO_setDebugLevel(0)
    do ios=1,max_output_streams
       if((output_frequency(ios) .gt. 0) ) then

          st=1
          if (hybrid%par%masterproc) print *,'writing coordinates ios=',ios
          do ie=1,nelemdmax
            ! if (par%masterproc .and. mod(ie,1).eq.0 ) print *,'ie=',ie
	    if(ie<=nelemd) then
               en=st+elem(ie)%idxp%NumUniquePts-1
               call UniqueCoords(elem(ie)%idxP, elem(ie)%spherep,latp(st:en), lonp(st:en)) 
               st=en+1
            end if
          enddo

if (geometry == "sphere") then
          latp=latp*90.0D0/asin(1.0D0)
          lonp=lonp*90.0D0/asin(1.0D0)
endif
          call nf_put_var(ncdf(ios),latp,start(1:1),count(1:1),name='lat', iodescin=iodesc2d)
          call nf_put_var(ncdf(ios),lonp,start(1:1),count(1:1),name='lon', iodescin=iodesc2d)



          st=1
          do ie=1,nelemd
             en=st+elem(ie)%idxp%NumUniquePts-1
             call UniquePoints(elem(ie)%idxp,elem(ie)%spheremp(:,:),latp(st:en))
             st=en+1
          enddo
          call nf_put_var(ncdf(ios),latp,start(1:1), count(1:1), name='area')

          if (hybrid%par%masterproc) print *,'done.'
       end if
    end do
    deallocate(latp)
    deallocate(lonp)
    
    
  end subroutine shal_movie_init

  subroutine shal_movie_output(elem,tl,hybrid, phimean, nets, nete,deriv)
    use time_mod, only : Timelevel_t, time_at
    use derivative_mod, only : vorticity_sphere

    integer,          intent(in)    :: nets,nete  
    type (derivative_t),intent(in)  :: deriv 
    type (element_t), intent(inout) :: elem(:)
    type (TimeLevel_t), intent(in)  :: tl
    type (hybrid_t), intent(in)     :: hybrid
    real (kind=real_kind), intent(in) :: phimean
    real (kind=real_kind) :: varptmp(np,np,nlev), varptmp2(np,np,nlev,nets:nete)
    integer :: ios, ierr, istat(4)
    real*8              :: st_write, et_write, dt_write, dt_write_global
    integer :: vcntv2d, vcntv3d, vcntp3d,vcntp2d, ie, k
    character(len=varname_len), pointer :: output_varnames(:)
    character(len=2) :: vname
    real(kind=real_kind),parameter :: dayspersec=1./(3600.*24.)
    integer(kind=nfsizekind) :: start(3), count(3), start2d(2),count2d(2)
    integer :: ncnt 

    real (kind=real_kind)  :: varp2d(npsq)
    real (kind=real_kind)  :: varp3d(npsq,nlev)

!    real(kind=real_kind)                      :: v1,v2
    real (kind=real_kind), dimension(np,np,2) :: vco 
    real (kind=real_kind)                     :: rad2deg
    real (kind=real_kind)                     :: lenscale
    integer                                   :: i,j,st,en,jj,cindex
    real (kind=real_kind), dimension(np,np)   :: v1, v2

    real (kind=real_kind),pointer :: field1(:,:,:),field2(:,:,:,:)
    real (kind=real_kind) :: var3d(nxyp,nlev)
    character(len=280) :: namell
    real (kind=real_kind) :: var2d(nxyp)
    
    lenscale = rearth 

    allocate(field1(np,np,nets:nete))


    do ios=1,max_output_streams
       ! intel compiler creashes when taking module(*,0), so test 
       ! on output_frequency(ios) > 0 in seperate if statement:
       if (output_frequency(ios) .gt. 0) then
       if(  (output_start_time(ios) .le. tl%nstep) .and. &
            (output_end_time(ios) .ge. tl%nstep) .and. MODULO(tl%nstep,output_frequency(ios)) .eq. 0) then

          output_varnames => get_current_varnames(ios)
          start2d(1)=1
          start2d(2)=nf_get_frame(ncdf(ios))
          count2d(1)=0
          count2d(2)=1
          start(1)=1
          start(2)=1
          count(1)=0
          count(2)=nlev
          start(3)=nf_get_frame(ncdf(ios))
          count(3)=1

          if(nf_selectedvar('ps', output_varnames)) then
             ! todo - upgrade this code - see 'geop' example below
             ! stop 'ps output code not upgraded for PIO'
             ! do ie=1,nelemdmax
             !    if(ie<=nelemd) then
             !       start2d(1) = elem(ie)%idxP%UniquePtOffset
             !       count2d(1) = elem(ie)%idxP%NumUniquePts
             !       ncnt = count2d(1)
             !       call UniquePoints(elem(ie)%idxP,elem(ie)%state%ps,varp2D)
             !    else
             !       ncnt=1
             !       count2d=0
             !    end if
             !    call nf_put_var(ncdf(ios),varp2d(1:ncnt),start2d,count2d,name='ps')
             ! enddo

             if (hybrid%par%masterproc) print *,'output: ps'

             st=1
             do ie=1,nelemd
                en=st+elem(ie)%idxp%NumUniquePts-1
                   call UniquePoints(elem(ie)%idxp,elem(ie)%state%ps(:,:),var2d(st:en))
                st=en+1
             enddo
             count2D(1)=-1  ! ignored by PIO
             start2D(1)=-1  ! ignored by PIO
             start2D(2)=nf_get_frame(ncdf(ios))
             count2D(2)=1

             call nf_put_var(ncdf(ios),var2d,start2D, count2D, name='ps')

          endif

	  if(nf_selectedvar('zeta', output_varnames)) then
             if (hybrid%par%masterproc) print *,'output: zeta'

             call compute_zeta_C0_contra(varptmp2, elem, hybrid%par,tl%n0)
             st=1
             do ie=1,nelemd
                 en=st+elem(ie)%idxp%NumUniquePts-1
                 call UniquePoints(elem(ie)%idxp,nlev,varptmp2(:,:,:,ie),var3d(st:en,:))
                 st=en+1
             enddo

             count(1:2)=-1  ! ignored by PIO
             start(1:2)=-1  ! ignored by PIO
             start(3)=nf_get_frame(ncdf(ios))
             count(3)=1

             call nf_put_var(ncdf(ios),var3d,start, count, name='zeta')
	  endif 

    if(nf_selectedvar('eta', output_varnames)) then
             if (hybrid%par%masterproc) print *,'output: eta'

             call compute_eta_C0_contra(varptmp2, elem, hybrid%par,tl%n0)
             st=1
             do ie=1,nelemd
                 en=st+elem(ie)%idxp%NumUniquePts-1
                 call UniquePoints(elem(ie)%idxp,nlev,varptmp2(:,:,:,ie),var3d(st:en,:))
                 st=en+1
             enddo

             count(1:2)=-1  ! ignored by PIO
             start(1:2)=-1  ! ignored by PIO
             start(3)=nf_get_frame(ncdf(ios))
             count(3)=1

             call nf_put_var(ncdf(ios),var3d,start, count, name='eta')
	  endif 
    
    if(nf_selectedvar('pv', output_varnames)) then
             if (hybrid%par%masterproc) print *,'output: pv'

             call compute_pv_C0_contra(varptmp2, elem, phimean, hybrid%par,tl%n0)
             st=1
             do ie=1,nelemd
                 en=st+elem(ie)%idxp%NumUniquePts-1
                 call UniquePoints(elem(ie)%idxp,nlev,varptmp2(:,:,:,ie),var3d(st:en,:))
                 st=en+1
             enddo

             count(1:2)=-1  ! ignored by PIO
             start(1:2)=-1  ! ignored by PIO
             start(3)=nf_get_frame(ncdf(ios))
             count(3)=1

             call nf_put_var(ncdf(ios),var3d,start, count, name='pv')
    endif 
    
	  if(nf_selectedvar('div', output_varnames)) then
             if (hybrid%par%masterproc) print *,'output: divergence'

             call compute_div_C0_contra(varptmp2, elem, hybrid%par, tl%n0)
             st=1
             do ie=1,nelemd
                 en=st+elem(ie)%idxp%NumUniquePts-1
                 call UniquePoints(elem(ie)%idxp,nlev,varptmp2(:,:,:,ie),var3d(st:en,:))
                 st=en+1
             enddo

             count(1:2)=-1  ! ignored by PIO
             start(1:2)=-1  ! ignored by PIO
             start(3)=nf_get_frame(ncdf(ios))
             count(3)=1

             call nf_put_var(ncdf(ios),var3d,start, count, name='div')
	  endif 

          if(nf_selectedvar('geop', output_varnames)) then
             if (hybrid%par%masterproc) print *,'output: geop'

             st=1
             do ie=1,nelemd
                en=st+elem(ie)%idxp%NumUniquePts-1
                   do k=1,nlev
                      varptmp(:,:,k) = (elem(ie)%state%p(:,:,k,tl%n0) + elem(ie)%state%ps + phimean)/g
                   end do
                   if (kmass.ne.-1) then
                      ! p(:,:,kmass) = is the density, 
                      ! other levels are tracers.  Output concentration:
                      if(k.ne.kmass) &
                           varptmp(:,:,k)=varptmp(:,:,k)/elem(ie)%state%p(:,:,kmass,tl%n0)
                   endif
                   call UniquePoints(elem(ie)%idxp,nlev,varptmp,var3d(st:en,:))
                st=en+1
             enddo
             count(1:2)=-1  ! ignored by PIO
             start(1:2)=-1  ! ignored by PIO
             start(3)=nf_get_frame(ncdf(ios))
             count(3)=1

             call nf_put_var(ncdf(ios),var3d,start, count, name='geop')
          endif



          if(nf_selectedvar('u', output_varnames)) then
             if (hybrid%par%masterproc) print *,'output: u'

             st=1
             do ie=1,nelemd
                en=st+elem(ie)%idxp%NumUniquePts-1
                   do k=1,nlev
                      varptmp(:,:,k) = elem(ie)%D(:,:,1,1)*elem(ie)%state%v(:,:,1,k,tl%n0)+ &
                           elem(ie)%D(:,:,1,2)*elem(ie)%state%v(:,:,2,k,tl%n0)
                   end do
                   call UniquePoints(elem(ie)%idxp,nlev,varptmp,var3d(st:en,:))
                st=en+1
             enddo

             count(1:2)=-1  ! ignored by PIO
             start(1:2)=-1  ! ignored by PIO
             start(3)=nf_get_frame(ncdf(ios))
             count(3)=1

             call nf_put_var(ncdf(ios),var3d,start, count, name='u')
          endif

          if(nf_selectedvar('v', output_varnames)) then
             if (hybrid%par%masterproc) print *,'output: v'

             st=1
             do ie=1,nelemd
                en=st+elem(ie)%idxp%NumUniquePts-1
                   do k=1,nlev
                      varptmp(:,:,k) = elem(ie)%D(:,:,2,1)*elem(ie)%state%v(:,:,1,k,tl%n0)+ &
                           elem(ie)%D(:,:,2,2)*elem(ie)%state%v(:,:,2,k,tl%n0)
                   end do
                   call UniquePoints(elem(ie)%idxp,nlev,varptmp,var3d(st:en,:))
                st=en+1
             enddo

             count(1:2)=-1  ! ignored by PIO
             start(1:2)=-1  ! ignored by PIO
             start(3)=nf_get_frame(ncdf(ios))
             count(3)=1

             call nf_put_var(ncdf(ios),var3d,start, count, name='v')
          endif

          count(3) = 1
          call nf_put_var(ncdf(ios),real(dayspersec*time_at(tl%nstep),kind=real_kind),&
                  start(3:3),count(3:3),name='time')
          call nf_advance_frame(ncdf(ios))

       end if
       end if
    end do

    deallocate(field1)

  end subroutine shal_movie_output

  subroutine shal_movie_finish
    integer :: istat(4)

    call nf_close_all(ncdf)
    istat=0
  end subroutine shal_movie_finish

! 
! Called by control_mod to set the list of variables available in this model
!
  subroutine setvarnames(nlvarnames)
    character*(*), intent(out) :: nlvarnames(:)
    nlvarnames(1:varcnt) = varnames
  end subroutine setvarnames


#endif
end module shal_movie_mod


