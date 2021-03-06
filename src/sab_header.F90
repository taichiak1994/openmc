module sab_header

  use, intrinsic :: ISO_FORTRAN_ENV

  use algorithm, only: find, sort
  use constants
  use dict_header, only: DictIntInt
  use distribution_univariate, only: Tabular
  use error,       only: warning, fatal_error
  use hdf5, only: HID_T, HSIZE_T, SIZE_T
  use h5lt, only: h5ltpath_valid_f, h5iget_name_f
  use hdf5_interface, only: read_attribute, get_shape, open_group, close_group, &
       open_dataset, read_dataset, close_dataset, get_datasets
  use secondary_correlated, only: CorrelatedAngleEnergy
  use stl_vector, only: VectorInt, VectorReal
  use string, only: to_str, str_to_int

  implicit none

!===============================================================================
! DISTENERGYSAB contains the secondary energy/angle distributions for inelastic
! thermal scattering collisions which utilize a continuous secondary energy
! representation.
!===============================================================================

  type DistEnergySab
    integer              :: n_e_out
    real(8), allocatable :: e_out(:)
    real(8), allocatable :: e_out_pdf(:)
    real(8), allocatable :: e_out_cdf(:)
    real(8), allocatable :: mu(:,:)
  end type DistEnergySab

!===============================================================================
! SALPHABETA contains S(a,b) data for thermal neutron scattering, typically off
! of light isotopes such as water, graphite, Be, etc
!===============================================================================

  type SabData
    ! threshold for S(a,b) treatment (usually ~4 eV)
    real(8) :: threshold_inelastic
    real(8) :: threshold_elastic = ZERO

    ! Inelastic scattering data
    integer :: n_inelastic_e_in  ! # of incoming E for inelastic
    integer :: n_inelastic_e_out ! # of outgoing E for inelastic
    integer :: n_inelastic_mu    ! # of outgoing angles for inelastic
    real(8), allocatable :: inelastic_e_in(:)
    real(8), allocatable :: inelastic_sigma(:)
    ! The following are used only if secondary_mode is 0 or 1
    real(8), allocatable :: inelastic_e_out(:,:)
    real(8), allocatable :: inelastic_mu(:,:,:)
    ! The following is used only if secondary_mode is 3
    ! The different implementation is necessary because the continuous
    ! representation has a variable number of outgoing energy points for each
    ! incoming energy
    type(DistEnergySab), allocatable :: inelastic_data(:) ! One for each Ein

    ! Elastic scattering data
    integer :: elastic_mode   ! elastic mode (discrete/exact)
    integer :: n_elastic_e_in ! # of incoming E for elastic
    integer :: n_elastic_mu   ! # of outgoing angles for elastic
    real(8), allocatable :: elastic_e_in(:)
    real(8), allocatable :: elastic_P(:)
    real(8), allocatable :: elastic_mu(:,:)
  end type SabData

  type SAlphaBeta
    character(100) :: name     ! name of table, e.g. lwtr.10t
    real(8)        :: awr      ! weight of nucleus in neutron masses
    real(8), allocatable :: kTs(:)  ! temperatures in MeV (k*T)
    character(10), allocatable :: nuclides(:) ! List of valid nuclides
    integer :: secondary_mode    ! secondary mode (equal/skewed/continuous)

    ! cross sections and distributions at each temperature
    type(SabData), allocatable :: data(:)
  contains
    procedure :: from_hdf5 => salphabeta_from_hdf5
  end type SAlphaBeta

contains

  subroutine salphabeta_from_hdf5(this, group_id, temperature, tolerance)
    class(SAlphaBeta), intent(inout) :: this
    integer(HID_T),    intent(in)    :: group_id
    type(VectorReal),  intent(in)    :: temperature ! list of temperatures
    real(8),           intent(in)    :: tolerance

    integer :: i, j
    integer :: t
    integer :: n_energy, n_energy_out, n_mu
    integer :: i_closest
    integer :: n_temperature
    integer :: hdf5_err
    integer(SIZE_T) :: name_len, name_file_len
    integer(HID_T) :: T_group
    integer(HID_T) :: elastic_group
    integer(HID_T) :: inelastic_group
    integer(HID_T) :: dset_id
    integer(HID_T) :: kT_group
    integer(HSIZE_T) :: dims2(2)
    integer(HSIZE_T) :: dims3(3)
    real(8), allocatable :: temp(:,:)
    character(20) :: type
    logical :: exists
    type(CorrelatedAngleEnergy) :: correlated_dist

    character(MAX_WORD_LEN) :: temp_str
    character(MAX_FILE_LEN), allocatable :: dset_names(:)
    real(8), allocatable :: temps_available(:) ! temperatures available
    real(8) :: temp_desired
    real(8) :: temp_actual
    type(VectorInt) :: temps_to_read

    ! Get name of table from group
    name_len = len(this % name)
    call h5iget_name_f(group_id, this % name, name_len, name_file_len, hdf5_err)

    ! Get rid of leading '/'
    this % name = trim(this % name(2:))

    call read_attribute(this % awr, group_id, 'atomic_weight_ratio')
    call read_attribute(this % nuclides, group_id, 'nuclides')
    call read_attribute(type, group_id, 'secondary_mode')
    select case (type)
    case ('equal')
      this % secondary_mode = SAB_SECONDARY_EQUAL
    case ('skewed')
      this % secondary_mode = SAB_SECONDARY_SKEWED
    case ('continuous')
      this % secondary_mode = SAB_SECONDARY_CONT
    end select

    ! Read temperatures
    kT_group = open_group(group_id, 'kTs')

    ! Determine temperatures available
    call get_datasets(kT_group, dset_names)
    allocate(temps_available(size(dset_names)))
    do i = 1, size(dset_names)
      ! Read temperature value
      call read_dataset(temps_available(i), kT_group, trim(dset_names(i)))
      temps_available(i) = temps_available(i) / K_BOLTZMANN
    end do

    ! Determine actual temperatures to read
    TEMP_LOOP: do i = 1, temperature % size()
      temp_desired = temperature % data(i)
      i_closest = minloc(abs(temps_available - temp_desired), dim=1)
      temp_actual = temps_available(i_closest)
      if (abs(temp_actual - temp_desired) < tolerance) then
        if (find(temps_to_read, nint(temp_actual)) == -1) then
          call temps_to_read % push_back(nint(temp_actual))
        end if
      else
        call fatal_error("Nuclear data library does not contain cross sections &
             &for " // trim(this % name) // " at or near " // &
             trim(to_str(nint(temp_desired))) // " K.")
      end if
    end do TEMP_LOOP

    ! TODO: If using interpolation, add a block to add bounding temperatures for
    ! each

    ! Sort temperatures to read
    call sort(temps_to_read)

    n_temperature = temps_to_read % size()
    allocate(this % kTs(n_temperature))
    allocate(this % data(n_temperature))

    do t = 1, n_temperature
      ! Get temperature as a string
      temp_str = trim(to_str(temps_to_read % data(t))) // "K"

      ! Read exact temperature value
      call read_dataset(this % kTs(t), kT_group, temp_str)

      ! Open group for temperature i
      T_group = open_group(group_id, temp_str)

      ! Coherent elastic data
      call h5ltpath_valid_f(T_group, 'elastic', .true., exists, hdf5_err)
      if (exists) then
        ! Read cross section data
        elastic_group = open_group(T_group, 'elastic')
        dset_id = open_dataset(elastic_group, 'xs')
        call read_attribute(type, dset_id, 'type')
        call get_shape(dset_id, dims2)
        allocate(temp(dims2(1), dims2(2)))
        call read_dataset(temp, dset_id)
        call close_dataset(dset_id)

        ! Set cross section data and type
        this % data(t) % n_elastic_e_in = int(dims2(1), 4)
        allocate(this % data(t) % elastic_e_in(this % data(t) % n_elastic_e_in))
        allocate(this % data(t) % elastic_P(this % data(t) % n_elastic_e_in))
        this % data(t) % elastic_e_in(:) = temp(:, 1)
        this % data(t) % elastic_P(:) = temp(:, 2)
        select case (type)
        case ('tab1')
          this % data(t) % elastic_mode = SAB_ELASTIC_DISCRETE
        case ('bragg')
          this % data(t) % elastic_mode = SAB_ELASTIC_EXACT
        end select
        deallocate(temp)

        ! Set elastic threshold
        this % data(t) % threshold_elastic = this % data(t) % elastic_e_in(&
             this % data(t) % n_elastic_e_in)

        ! Read angle distribution
        if (this % data(t) % elastic_mode /= SAB_ELASTIC_EXACT) then
          dset_id = open_dataset(elastic_group, 'mu_out')
          call get_shape(dset_id, dims2)
          this % data(t) % n_elastic_mu = int(dims2(1), 4)
          allocate(this % data(t) % elastic_mu(dims2(1), dims2(2)))
          call read_dataset(this % data(t) % elastic_mu, dset_id)
          call close_dataset(dset_id)
        end if

        call close_group(elastic_group)
      end if

      ! Inelastic data
      call h5ltpath_valid_f(T_group, 'inelastic', .true., exists, hdf5_err)
      if (exists) then
        ! Read type of inelastic data
        inelastic_group = open_group(T_group, 'inelastic')

        ! Read cross section data
        dset_id = open_dataset(inelastic_group, 'xs')
        call get_shape(dset_id, dims2)
        allocate(temp(dims2(1), dims2(2)))
        call read_dataset(temp, dset_id)
        call close_dataset(dset_id)

        ! Set cross section data
        this % data(t) % n_inelastic_e_in = int(dims2(1), 4)
        allocate(this % data(t) % inelastic_e_in(this % data(t) % n_inelastic_e_in))
        allocate(this % data(t) % inelastic_sigma(this % data(t) % n_inelastic_e_in))
        this % data(t) % inelastic_e_in(:) = temp(:, 1)
        this % data(t) % inelastic_sigma(:) = temp(:, 2)
        deallocate(temp)

        ! Set inelastic threshold
        this % data(t) % threshold_inelastic = this % data(t) % inelastic_e_in(&
             this % data(t) % n_inelastic_e_in)

        if (this % secondary_mode /= SAB_SECONDARY_CONT) then
          ! Read energy distribution
          dset_id = open_dataset(inelastic_group, 'energy_out')
          call get_shape(dset_id, dims2)
          this % data(t) % n_inelastic_e_out = int(dims2(1), 4)
          allocate(this % data(t) % inelastic_e_out(dims2(1), dims2(2)))
          call read_dataset(this % data(t) % inelastic_e_out, dset_id)
          call close_dataset(dset_id)

          ! Read angle distribution
          dset_id = open_dataset(inelastic_group, 'mu_out')
          call get_shape(dset_id, dims3)
          this % data(t) % n_inelastic_mu = int(dims3(1), 4)
          allocate(this % data(t) % inelastic_mu(dims3(1), dims3(2), dims3(3)))
          call read_dataset(this % data(t) % inelastic_mu, dset_id)
          call close_dataset(dset_id)
        else
          ! Read correlated angle-energy distribution
          call correlated_dist % from_hdf5(inelastic_group)

          ! Convert to S(a,b) native format
          n_energy = size(correlated_dist % energy)
          allocate(this % data(t) % inelastic_data(n_energy))
          do i = 1, n_energy
            associate (edist => correlated_dist % distribution(i))
              ! Get number of outgoing energies for incoming energy i
              n_energy_out = size(edist % e_out)
              this % data(t) % inelastic_data(i) % n_e_out = n_energy_out
              allocate(this % data(t) % inelastic_data(i) % e_out(n_energy_out))
              allocate(this % data(t) % inelastic_data(i) % e_out_pdf(n_energy_out))
              allocate(this % data(t) % inelastic_data(i) % e_out_cdf(n_energy_out))

              ! Copy outgoing energy distribution
              this % data(t) % inelastic_data(i) % e_out(:) = edist % e_out
              this % data(t) % inelastic_data(i) % e_out_pdf(:) = edist % p
              this % data(t) % inelastic_data(i) % e_out_cdf(:) = edist % c

              do j = 1, n_energy_out
                select type (adist => edist % angle(j) % obj)
                type is (Tabular)
                  ! On first pass, allocate space for angles
                  if (j == 1) then
                    n_mu = size(adist % x)
                    this % data(t) % n_inelastic_mu = n_mu
                    allocate(this % data(t) % inelastic_data(i) % mu(&
                         n_mu, n_energy_out))
                  end if

                  ! Copy outgoing angles
                  this % data(t) % inelastic_data(i) % mu(:, j) = adist % x
                end select
              end do
            end associate
          end do
        end if

        call close_group(inelastic_group)
      end if
      call close_group(T_group)
    end do

    call close_group(kT_group)
  end subroutine salphabeta_from_hdf5

end module sab_header
