!> Regrid columns for the adaptive coordinate
module coord_adapt

! This file is part of MOM6. See LICENSE.md for the license.

use MOM_EOS,           only : calculate_density_derivs
use MOM_error_handler, only : MOM_error, FATAL
use MOM_variables,     only : ocean_grid_type, thermo_var_ptrs
use MOM_verticalGrid,  only : verticalGrid_type

implicit none ; private

#include <MOM_memory.h>

!> Control structure for adaptive coordinates (coord_adapt).
type, public :: adapt_CS ; private

  !> Number of layers/levels
  integer :: nk

  !> Nominal near-surface resolution
  real, allocatable, dimension(:) :: coordinateResolution

  !> Ratio of optimisation and diffusion timescales
  real :: adaptTimeRatio = 1e-1

  !> Nondimensional coefficient determining how much optimisation to apply
  real :: adaptAlpha     = 1.0

  !> Near-surface zooming depth
  real :: adaptZoom      = 200.0

  !> Near-surface zooming coefficient
  real :: adaptZoomCoeff = 0.0

  !> Stratification-dependent diffusion coefficient
  real :: adaptBuoyCoeff = 0.0

  !> Reference density difference for stratification-dependent diffusion
  real :: adaptDrho0     = 0.5

  !> If true, form a HYCOM1-like mixed layet by preventing interfaces
  !! from becoming shallower than the depths set by coordinateResolution
  logical :: adaptDoMin  = .false.
end type adapt_CS

public init_coord_adapt, set_adapt_params, build_adapt_column, end_coord_adapt

contains

!> Initialise an adapt_CS with parameters
subroutine init_coord_adapt(CS, nk, coordinateResolution)
  type(adapt_CS),     pointer    :: CS !< Unassociated pointer to hold the control structure
  integer,            intent(in) :: nk !< Number of layers in the grid
  real, dimension(:), intent(in) :: coordinateResolution !< Nominal near-surface resolution (m)

  if (associated(CS)) call MOM_error(FATAL, "init_coord_adapt: CS already associated")
  allocate(CS)
  allocate(CS%coordinateResolution(nk))

  CS%nk = nk
  CS%coordinateResolution(:) = coordinateResolution(:)
end subroutine init_coord_adapt

!> Clean up the coordinate control structure
subroutine end_coord_adapt(CS)
  type(adapt_CS), pointer :: CS  !< The control structure for this module

  ! nothing to do
  if (.not. associated(CS)) return
  deallocate(CS%coordinateResolution)
  deallocate(CS)
end subroutine end_coord_adapt

!> This subtroutine can be used to set the parameters for coord_adapt module
subroutine set_adapt_params(CS, adaptTimeRatio, adaptAlpha, adaptZoom, adaptZoomCoeff, &
                            adaptBuoyCoeff, adaptDrho0, adaptDoMin)
  type(adapt_CS),    pointer    :: CS  !< The control structure for this module
  real,    optional, intent(in) :: adaptTimeRatio !< Ratio of optimisation and diffusion timescales
  real,    optional, intent(in) :: adaptAlpha     !< Nondimensional coefficient determining
                                                  !! how much optimisation to apply
  real,    optional, intent(in) :: adaptZoom      !< Near-surface zooming depth, in m
  real,    optional, intent(in) :: adaptZoomCoeff !< Near-surface zooming coefficient
  real,    optional, intent(in) :: adaptBuoyCoeff !< Stratification-dependent diffusion coefficient
  real,    optional, intent(in) :: adaptDrho0  !< Reference density difference for
                                               !! stratification-dependent diffusion
  logical, optional, intent(in) :: adaptDoMin  !< If true, form a HYCOM1-like mixed layer by
                                               !! preventing interfaces from becoming shallower than
                                               !! the depths set by coordinateResolution

  if (.not. associated(CS)) call MOM_error(FATAL, "set_adapt_params: CS not associated")

  if (present(adaptTimeRatio)) CS%adaptTimeRatio = adaptTimeRatio
  if (present(adaptAlpha)) CS%adaptAlpha = adaptAlpha
  if (present(adaptZoom)) CS%adaptZoom = adaptZoom
  if (present(adaptZoomCoeff)) CS%adaptZoomCoeff = adaptZoomCoeff
  if (present(adaptBuoyCoeff)) CS%adaptBuoyCoeff = adaptBuoyCoeff
  if (present(adaptDrho0)) CS%adaptDrho0 = adaptDrho0
  if (present(adaptDoMin)) CS%adaptDoMin = adaptDoMin
end subroutine set_adapt_params

subroutine build_adapt_column(CS, G, GV, tv, i, j, zInt, tInt, sInt, h, zNext)
  type(adapt_CS),                              intent(in)    :: CS   !< The control structure for this module
  type(ocean_grid_type),                       intent(in)    :: G    !< The ocean's grid structure
  type(verticalGrid_type),                     intent(in)    :: GV   !< The ocean's vertical grid structure
  type(thermo_var_ptrs),                       intent(in)    :: tv   !< A structure pointing to various
                                                                     !! thermodynamic variables
  integer,                                     intent(in)    :: i    !< The i-index of the column to work on
  integer,                                     intent(in)    :: j    !< The j-index of the column to work on
  real, dimension(SZI_(G),SZJ_(G),SZK_(GV)+1), intent(in)    :: zInt !< Interface heights, in H (m or kg m-2).
  real, dimension(SZI_(G),SZJ_(G),SZK_(GV)+1), intent(in)    :: tInt !< Interface temperatures, in C
  real, dimension(SZI_(G),SZJ_(G),SZK_(GV)+1), intent(in)    :: sInt !< Interface salinities, in psu
  real, dimension(SZI_(G),SZJ_(G),SZK_(GV)),   intent(in)    :: h    !< Layer thicknesses, in H (usually m or kg m-2)
  real, dimension(SZK_(GV)+1),                 intent(inout) :: zNext !< updated interface positions

  ! Local variables
  integer :: k, nz
  real :: h_up, b1, b_denom_1, d1, depth, drdz, nominal_z, stretching
  real, dimension(SZK_(GV)+1) :: alpha, beta, del2sigma ! drho/dT and drho/dS
  real, dimension(SZK_(GV)) :: kGrid, c1 ! grid diffusivity on layers, and tridiagonal work array

  nz = CS%nk

  ! set bottom and surface of zNext
  zNext(1) = 0.
  zNext(nz+1) = zInt(i,j,nz+1)

  ! local depth for scaling diffusivity
  depth = G%bathyT(i,j) * G%Zd_to_m*GV%m_to_H

  ! initialize del2sigma to zero
  del2sigma(:) = 0.

  ! calculate del-squared of neutral density by a
  ! stencilled finite difference
  ! TODO: this needs to be adjusted to account for vanished layers near topography

  ! up (j-1)
  if (G%mask2dT(i,j-1) > 0.) then
    call calculate_density_derivs( &
         0.5 * (tInt(i,j,2:nz) + tInt(i,j-1,2:nz)), &
         0.5 * (sInt(i,j,2:nz) + sInt(i,j-1,2:nz)), &
         0.5 * (zInt(i,j,2:nz) + zInt(i,j-1,2:nz)) * GV%H_to_Pa, &
         alpha, beta, 2, nz - 1, tv%eqn_of_state)

    del2sigma(2:nz) = del2sigma(2:nz) + &
         (alpha(2:nz) * (tInt(i,j-1,2:nz) - tInt(i,j,2:nz)) + &
          beta(2:nz)  * (sInt(i,j-1,2:nz) - sInt(i,j,2:nz)))
  endif
  ! down (j+1)
  if (G%mask2dT(i,j+1) > 0.) then
    call calculate_density_derivs( &
         0.5 * (tInt(i,j,2:nz) + tInt(i,j+1,2:nz)), &
         0.5 * (sInt(i,j,2:nz) + sInt(i,j+1,2:nz)), &
         0.5 * (zInt(i,j,2:nz) + zInt(i,j+1,2:nz)) * GV%H_to_Pa, &
         alpha, beta, 2, nz - 1, tv%eqn_of_state)

    del2sigma(2:nz) = del2sigma(2:nz) + &
         (alpha(2:nz) * (tInt(i,j+1,2:nz) - tInt(i,j,2:nz)) + &
          beta(2:nz)  * (sInt(i,j+1,2:nz) - sInt(i,j,2:nz)))
  endif
  ! left (i-1)
  if (G%mask2dT(i-1,j) > 0.) then
    call calculate_density_derivs( &
         0.5 * (tInt(i,j,2:nz) + tInt(i-1,j,2:nz)), &
         0.5 * (sInt(i,j,2:nz) + sInt(i-1,j,2:nz)), &
         0.5 * (zInt(i,j,2:nz) + zInt(i-1,j,2:nz)) * GV%H_to_Pa, &
         alpha, beta, 2, nz - 1, tv%eqn_of_state)

    del2sigma(2:nz) = del2sigma(2:nz) + &
         (alpha(2:nz) * (tInt(i-1,j,2:nz) - tInt(i,j,2:nz)) + &
          beta(2:nz)  * (sInt(i-1,j,2:nz) - sInt(i,j,2:nz)))
  endif
  ! right (i+1)
  if (G%mask2dT(i+1,j) > 0.) then
    call calculate_density_derivs( &
         0.5 * (tInt(i,j,2:nz) + tInt(i+1,j,2:nz)), &
         0.5 * (sInt(i,j,2:nz) + sInt(i+1,j,2:nz)), &
         0.5 * (zInt(i,j,2:nz) + zInt(i+1,j,2:nz)) * GV%H_to_Pa, &
         alpha, beta, 2, nz - 1, tv%eqn_of_state)

    del2sigma(2:nz) = del2sigma(2:nz) + &
         (alpha(2:nz) * (tInt(i+1,j,2:nz) - tInt(i,j,2:nz)) + &
          beta(2:nz)  * (sInt(i+1,j,2:nz) - sInt(i,j,2:nz)))
  endif

  ! at this point, del2sigma contains the local neutral density curvature at
  ! h-points, on interfaces
  ! we need to divide by drho/dz to give an interfacial displacement
  !
  ! a positive curvature means we're too light relative to adjacent columns,
  ! so del2sigma needs to be positive too (push the interface deeper)
  call calculate_density_derivs(tInt(i,j,:), sInt(i,j,:), zInt(i,j,:) * GV%H_to_Pa, &
       alpha, beta, 1, nz + 1, tv%eqn_of_state)
  do K = 2, nz
    ! TODO make lower bound here configurable
    del2sigma(K) = del2sigma(K) * (0.5 * (h(i,j,k-1) + h(i,j,k))) / &
         max(alpha(K) * (tv%T(i,j,k) - tv%T(i,j,k-1)) + &
             beta(K)  * (tv%S(i,j,k) - tv%S(i,j,k-1)), 1e-20)

    ! don't move the interface so far that it would tangle with another
    ! interface in the direction we're moving (or exceed a Nyquist limit
    ! that could cause oscillations of the interface)
    h_up = merge(h(i,j,k), h(i,j,k-1), del2sigma(K) > 0.)
    del2sigma(K) = 0.5 * CS%adaptAlpha * &
         sign(min(abs(del2sigma(K)), 0.5 * h_up), del2sigma(K))

    ! update interface positions so we can diffuse them
    zNext(K) = zInt(i,j,K) + del2sigma(K)
  enddo

  ! solve diffusivity equation to smooth grid
  ! upper diagonal coefficients: -kGrid(2:nz)
  ! lower diagonal coefficients: -kGrid(1:nz-1)
  ! diagonal coefficients:       1 + (kGrid(1:nz-1) + kGrid(2:nz))
  !
  ! first, calculate the diffusivities within layers
  do k = 1, nz
    ! calculate the dr bit of drdz
    drdz = 0.5 * (alpha(K) + alpha(K+1)) * (tInt(i,j,K+1) - tInt(i,j,K)) + &
         0.5 * (beta(K)  + beta(K+1))  * (sInt(i,j,K+1) - sInt(i,j,K))
    ! divide by dz from the new interface positions
    drdz = drdz / (zNext(K) - zNext(K+1) + GV%H_subroundoff)
    ! don't do weird stuff in unstably-stratified regions
    drdz = max(drdz, 0.)

    ! set vertical grid diffusivity
    kGrid(k) = (CS%adaptTimeRatio * nz**2 * depth) * &
         (CS%adaptZoomCoeff / (CS%adaptZoom * GV%m_to_H + 0.5*(zNext(K) + zNext(K+1))) + &
         (CS%adaptBuoyCoeff * drdz / CS%adaptDrho0) + &
         max(1.0 - CS%adaptZoomCoeff - CS%adaptBuoyCoeff, 0.0) / depth)
  enddo

  ! initial denominator (first diagonal element)
  b1 = 1.0
  ! initial Q_1 = 1 - q_1 = 1 - 0/1
  d1 = 1.0
  ! work on all interior interfaces
  do K = 2, nz
    ! calculate numerator of Q_k
    b_denom_1 = 1. + d1 * kGrid(k-1)
    ! update denominator for k
    b1 = 1.0 / (b_denom_1 + kGrid(k))

    ! calculate q_k
    c1(K) = kGrid(k) * b1
    ! update Q_k = 1 - q_k
    d1 = b_denom_1 * b1

    ! update RHS
    zNext(K) = b1 * (zNext(K) + kGrid(k-1)*zNext(K-1))
  enddo
  ! final substitution
  do K = nz, 2, -1
    zNext(K) = zNext(K) + c1(K)*zNext(K+1)
  enddo

  if (CS%adaptDoMin) then
    nominal_z = 0.
    stretching = zInt(i,j,nz+1) / depth

    do k = 2, nz+1
      nominal_z = nominal_z + CS%coordinateResolution(k-1) * stretching
      ! take the deeper of the calculated and nominal positions
      zNext(K) = max(zNext(K), nominal_z)
      ! interface can't go below topography
      zNext(K) = min(zNext(K), zInt(i,j,nz+1))
    enddo
  endif
end subroutine build_adapt_column

end module coord_adapt
