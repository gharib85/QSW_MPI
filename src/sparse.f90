!   QSW_MPI -  A package for parallel Quantum Stochastic Walk simulation.
!   Copyright (C) 2019 Edric Matwiejew
!
!   This program is free software: you can redistribute it and/or modify
!   it under the terms of the GNU General Public License as published by
!   the Free Software Foundation, either version 3 of the License, or
!   (at your option) any later version.
!
!   This program is distributed in the hope that it will be useful,
!   but WITHOUT ANY WARRANTY; without even the implied warranty of
!   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
!   GNU General Public License for more details.
!
!   You should have received a copy of the GNU General Public License
!   along with this program.  If not, see <https://www.gnu.org/licenses/>.

!
!   Module: Sparse_Operations
!
!> @brief MPI parallel sparse BLAS operations.
!
module Sparse

    use :: ISO_Precisions
    use :: mpi

    implicit none

    !> @brief Compressed sparse rows (CSR) complex matrix derived type.
    !
    !> @warning *Sparse_Operations.mod* requiers that the entries for each row are
    !> stored in acessending order. This condition may not be enforced
    !> external sparse libraries.

    type, public  :: CSR

        integer :: rows
        integer :: columns
        character(len=2) :: structure
        integer, dimension(:), pointer :: row_starts
        integer, dimension(:), pointer :: col_indexes
        complex(dp), dimension(:), pointer :: values

        integer, dimension(:), pointer :: local_col_inds
        integer, dimension(:), pointer :: RHS_send_inds
        integer, dimension(:), pointer :: num_send_inds
        integer, dimension(:), pointer :: send_disps
        integer, dimension(:), pointer :: num_rec_inds
        integer, dimension(:), pointer :: rec_disps

    end type CSR

    contains

    !
    ! Subroutine: Generate_Partition_Table
    !
    !> @brief Determines a matrix/vector partition scheme.
    !>
    !> @details A given number of rows is divided evenly (if possible) over an
    !> MPI communicator of size *N* nodes. If even division is not possible the
    !> remainder is given to the node of highest rank.
    !>
    !> Array *partition_table* is of size N + 1 and follows a format similar to
    !> that of the *row_start* array in the *CSR* data type:
    !>
    !>> (starting row for rank 0, starting row for rank 1, ..., rows + 1)
    !>
    !> As such the number of rows at a node is given by:
    !>
    !>> partition_table(rank + 2) - partition_table(rank + 1)
    !>
    !> @note Must be called from within an MPI instance.
    !
    !> @todo send row data to MPI communicator from root process.

    subroutine Generate_Partition_Table(rows, partition_table, MPI_communicator)

        integer, intent(in) :: rows !< @param Number of matrix/vector rows.
        integer, intent(out), dimension(:), allocatable :: partition_table !< @param Start/Finish of partitions.
        integer, intent(in) :: MPI_communicator !< @param MPI communicator over which to distribute.

        integer :: remainder

        integer :: i

        ! MPI environment
        integer :: flock ! size of MPI communicator.
        integer :: ierr

        call MPI_comm_size(mpi_communicator, flock, ierr)

        allocate(partition_table(flock + 1))

        do i = 1, flock + 1
            partition_table(i) = (i - 1)*rows/flock + 1
        enddo

        remainder = rows - partition_table(flock + 1)

        do i = 1, remainder
            partition_table(flock - mod(i, flock):flock + 1) = &
                partition_table(flock - mod(i, flock):flock + 1) + 1
        enddo

        partition_table(flock + 1) = rows + 1

    end subroutine Generate_Partition_Table

    subroutine Distribute_Dense_Vector( v, &
                                        partition_table, &
                                        root, &
                                        v_local, &
                                        MPI_communicator)

        complex(dp), dimension(:), intent(in) :: v !< @param Array to distribute.
        integer, dimension(:), intent(in) :: partition_table !< @param MPI communicator partitioning scheme.
        integer, intent(in) :: root !< @param Node from which the array is distributed.
        complex(dp), dimension(:), allocatable, intent(out) :: v_local !< @param Local array partition.
        integer, intent(in) :: mpi_communicator !< @param MPI communicator over which to distribute.

        integer :: lb_send, ub_send, lb_recv, ub_recv

        integer :: i

        ! MPI ENVIRONMENT
        integer :: flock, rank
        integer, dimension(:), allocatable :: requests_out
        integer :: buff_size
        integer :: ierr

        call MPI_comm_size(MPI_communicator, flock, ierr)
        call MPI_comm_rank(MPI_communicator, rank, ierr)

        allocate(requests_out(0:flock - 1))

        if (rank == root) then
            do i = 0, flock - 1
                if (i /= root) then
                    lb_send = partition_table(i + 1)
                    ub_send = partition_table(i + 2) - 1
                    buff_size = ub_send - lb_send + 1

                    call MPI_Isend( v(lb_send:ub_send), buff_size, &
                               MPI_double_complex, i, &
                               rank*10 + i, MPI_communicator, &
                               requests_out(i), ierr)
                endif
            enddo
        endif


        lb_recv = partition_table(rank + 1)
        ub_recv = partition_table(rank + 2) - 1

        allocate(v_local(lb_recv:ub_recv))
        if (rank == root) then
            v_local = v(lb_recv:ub_recv)
        else
            buff_size = ub_recv - lb_recv + 1
            call MPI_recv(  v_local(lb_recv:ub_recv), buff_size, &
                            MPI_double_complex, root, &
                            root*10 + rank, MPI_communicator, &
                            MPI_status_ignore, ierr)
        endif

        call mpi_barrier(MPI_communicator, ierr)

    end subroutine Distribute_Dense_Vector

    !
    !   subroutine: Distribute_CSR_Matrix
    !
    !> @brief Distribute complex CSR matrix over an MPI communicator.
    !>
    !> @details CSR matrix is partitioned following a scheme given by
    !> the *partition_table* array, see @ref generate_partition_table for more.
    !>
    !> @note Must be called from within an MPI instance.

    subroutine Distribute_CSR_Matrix(   A, &
                                        partition_table, &
                                        root, &
                                        A_local, &
                                        MPI_communicator)

        type(CSR), intent(in) :: A  !< @param CSR matrix to distribute.
        integer, dimension(:), intent(in) :: partition_table    !< @param MPI communicator paritioning scheme.
        integer, intent(in) :: root !< @param Node from which A is distributed.
        type(CSR), intent(out) :: A_local !< @param Local CSR parition.
        integer, intent(in) :: MPI_communicator !< @param MPU communicator over which to distribute.

        integer, dimension(:), allocatable :: block_lens, disps
        integer, dimension(:), allocatable :: block_lens_vals, disps_vals

        integer :: lb, ub, lb_vals, ub_vals

        integer :: i

        !MPI ENVIRONMENT
        integer :: rank, flock
        integer :: ierr

        call MPI_comm_size(MPI_communicator, flock, ierr)
        call MPI_comm_rank(MPI_communicator, rank, ierr)


        if (rank == root) then
            A_local%rows = A%rows
            A_local%columns = A%columns
        endif

        call MPI_bcast( A_local%rows, &
                        1, &
                        MPI_integer, &
                        root, &
                        MPI_communicator, &
                        ierr)

        call MPI_bcast( A_local%columns, &
                        1, &
                        MPI_integer, &
                        root, &
                        MPI_communicator, &
                        ierr)

        allocate(block_lens(flock))
        allocate(disps(flock))

        do i = 1, flock
            block_lens(i) = partition_table(i + 1) - partition_table(i) + 1
        enddo

        disps = 0

        do i = 2, flock
            disps(i) = disps(i - 1) + block_lens(i - 1) - 1
        enddo

        lb = partition_table(rank + 1)
        ub = partition_table(rank + 2)

        allocate(A_local%row_starts(lb:ub))

        call MPI_scatterv(  A%row_starts, &
                            block_lens, &
                            disps, &
                            MPI_integer, &
                            A_local%row_starts, &
                            block_lens(rank + 1), &
                            MPI_integer, &
                            root, &
                            MPI_communicator, &
                            ierr)

        lb_vals = A_local%row_starts(lb)
        ub_vals = A_local%row_starts(ub) - 1

        allocate(A_local%col_indexes(lb_vals:ub_vals))
        allocate(A_local%values(lb_vals:ub_vals))

        allocate(block_lens_vals(flock))
        allocate(disps_vals(flock))

        if (rank == root) then

            do i = 1, flock

                block_lens_vals(i) = A%row_starts(partition_table(i + 1)) &
                                        - A%row_starts(partition_table(i))

            enddo

        endif

        call MPI_bcast( block_lens_vals, &
                        flock, &
                        MPI_integer, &
                        root, &
                        MPI_communicator, &
                        ierr)

        disps_vals = 0

        do i = 2, flock

            disps_vals(i) = disps_vals(i - 1) + block_lens_vals(i - 1)

        enddo


        call MPI_scatterv(  A%col_indexes, &
                            block_lens_vals, &
                            disps_vals, &
                            MPI_integer, &
                            A_local%col_indexes, &
                            block_lens_vals(rank + 1), &
                            MPI_integer, &
                            root, &
                            MPI_communicator, &
                            ierr)

        call MPI_scatterv(  A%values, &
                            block_lens_vals, &
                            disps_vals, &
                            MPI_double_complex, &
                            A_local%values, &
                            block_lens_vals(rank + 1), &
                            MPI_double_complex, &
                            root, &
                            MPI_communicator, &
                            ierr)

    end subroutine Distribute_CSR_Matrix

    !
    !   subroutine: Gather_Dense_Vector
    !
    !> @brief Gather a 1D double precision complex array distributed over an MPI
    !> communicator.
    !>
    !> @details The array is partitioned following a scheme given by
    !> the *partition_table* array, see @ref generate_partition_table for more.
    !>
    !> @note Must be called from within an MPI instance.
    !>
    !> @todo rewriting Distribute_dense_vector with MPI_scatterv

    subroutine Gather_Dense_Vector( u_local, &
                                    partition_table, &
                                    root, &
                                    u, &
                                    MPI_communicator)

        complex(dp), dimension(:), intent(in) :: u_local !< @param Array to gather.
        integer, dimension(:), intent(in) :: partition_table !< @param MPI communicator partitioning scheme.
        integer, intent(in) :: root !< @param Node to which the array is gathered.
        complex(dp), dimension(:), intent(out) :: u !< @param Gathered array.
        integer, intent(in) :: mpi_communicator !< @param MPI communicator over which to gather.

        integer, dimension(:), allocatable :: block_lens, disps
        integer :: lb, ub
        integer :: i

        !MPI ENVIRONMENT
        integer :: rank, flock
        integer :: ierr

        call MPI_comm_size(MPI_communicator, flock, ierr)
        call MPI_comm_rank(MPI_communicator, rank, ierr)

        allocate(block_lens(flock))
        allocate(disps(flock))

        do i = 1, flock

            block_lens(i) = partition_table(i + 1) - partition_table(i)

        enddo

        disps = 0

        do i = 2, flock

            disps(i) = disps(i - 1) + block_lens(i - 1)

        enddo

        lb = partition_table(rank + 1)
        ub = partition_table(rank + 2)

        call MPI_gatherv(   u_local, &
                            block_lens(rank + 1), &
                            MPI_double_complex, &
                            u, &
                            block_lens, &
                            disps, &
                            MPI_double_complex, &
                            root, &
                            MPI_communicator, &
                            ierr)

    end subroutine Gather_Dense_Vector

    subroutine Scatter_Dense_Maxtrix(   A, &
                                        partition_table, &
                                        root, &
                                        A_local, &
                                        MPI_communicator)

        complex(dp), dimension(:,:), intent(in) :: A
        integer, dimension(:), intent(in) :: partition_table
        integer, intent(in) :: root
        complex(dp), dimension(:,:), allocatable, intent(out) :: A_local
        integer, intent(in) :: MPI_communicator

        integer :: rec_lb, rec_ub
        integer :: send_lb, send_ub
        integer :: rec_row, rec_col
        integer :: send_row, send_col
        integer :: i

        !MPI ENVIRONMENT
        integer, dimension(:), allocatable :: requests_out
        integer, dimension(MPI_status_size) :: status
        integer :: rank, flock
        integer :: ierr

        call MPI_comm_size(MPI_communicator, flock, ierr)
        call MPI_comm_rank(MPI_communicator, rank, ierr)

        rec_lb = partition_table(rank + 1)
        rec_ub = partition_table(rank + 2) - 1

        rec_row = rec_ub - rec_lb + 1
        rec_col = size(A,2)

        CALL mpi_bcast( rec_col, &
                        1, &
                        MPI_integer, &
                        root, &
                        MPI_comm_world, &
                        ierr)

        allocate(requests_out(0:flock-1))


        if (rank == root) then

            send_col = rec_col

            do i = 0, flock - 1

                if (i /= root) then

                send_lb = partition_table(i + 1)
                send_ub = partition_table(i + 2) - 1

                send_row = partition_table(i + 2) - partition_table(i + 1)

                call MPI_send( A(send_lb:send_ub, 1:rec_col), &
                                send_row*send_col, &
                                MPI_double_complex, &
                                i, &
                                i*10, &
                                MPI_communicator, &
                                ierr)

            endif

            enddo

        else

            allocate(A_local(rec_lb:rec_ub, rec_col))

            call MPI_Recv(  A_local(rec_lb:rec_ub, 1:rec_col), &
                            rec_row*rec_col, &
                            MPI_double_complex, &
                            root, &
                            rank*10, &
                            MPI_communicator, &
                            status, &
                            ierr)

        endif

        if (rank == root) then

            allocate(A_local(rec_lb:rec_ub, rec_col))

            A_local = A(rec_lb:rec_ub, :)

        endif

        call mpi_barrier(MPI_communicator, ierr)

    end subroutine Scatter_Dense_Maxtrix

    subroutine Gather_Dense_Matrix( A_local, &
                                    partition_table, &
                                    root, &
                                    A, &
                                    MPI_communicator)

        complex(dp), dimension(:,:), intent(in) :: A_local
        integer, dimension(:), intent(in) :: partition_table
        integer, intent(in) :: root
        complex(dp), dimension(:,:), intent(out) :: A
        integer, intent(in) :: MPI_communicator

        integer :: rec_lb, rec_ub
        integer :: send_row, send_col
        integer :: rec_row, rec_col
        logical, dimension(:), allocatable :: received
        integer :: i

        !MPI ENVIRONMENT
        integer, dimension(MPI_status_size) :: status
        integer :: rank, flock
        integer :: ierr

        call MPI_comm_size(MPI_communicator, flock, ierr)
        call MPI_comm_rank(MPI_communicator, rank, ierr)

        if (rank /= root) then

            send_row = partition_table(rank + 2) - partition_table(rank + 1)
            send_col = size(A_local, 2)

            call MPI_send(  A_local, &
                            send_row*send_col, &
                            MPI_double_complex, &
                            root, &
                            rank*10, &
                            MPI_communicator, &
                            ierr)

        else

            if (flock > 1) then

                rec_col = size(A_local, 2)

                rec_lb = partition_table(rank + 1)
                rec_ub = partition_table(rank + 2) - 1

                A(rec_lb:rec_ub, :) = A_local

                allocate(received(0:flock - 1))

                received = .false.

                received(rank) = .true.

                do

                    do i = 0, flock - 1

                        if (.not. received(i)) then

                            call MPI_Iprobe(    i, &
                                                i*10, &
                                                MPI_communicator, &
                                                received(i), &
                                                status, &
                                                ierr)

                            if (received (i)) then

                                rec_lb = partition_table(i + 1)
                                rec_ub = partition_table(i + 2) - 1

                                rec_row = rec_ub - rec_lb + 1

                                call MPI_Recv(  A(rec_lb:rec_ub, :), &
                                                rec_row*rec_col, &
                                                MPI_double_complex, &
                                                i, &
                                                i*10, &
                                                MPI_communicator, &
                                                status, &
                                                ierr)
                            endif

                        endif

                    enddo

                    if(all(received)) exit

                enddo

            else

                A = A_local

            endif

        endif

    end subroutine Gather_Dense_Matrix


    subroutine Merge_Dagger(column_indexes, &
                            row_indexes, &
                            values, &
                            start, &
                            mid, &
                            finish)

        integer, intent(inout), dimension(:) :: column_indexes
        integer, intent(inout), dimension(:) :: row_indexes
        complex(dp), intent(inout), dimension(:) :: values
        integer, intent(in) :: start
        integer, intent(in) :: mid
        integer, intent(in) :: finish

        integer, dimension(:), allocatable :: col_ind_temp
        integer, dimension(:), allocatable :: row_ind_temp
        complex(dp), dimension(:), allocatable :: val_temp
        integer :: i, j, k

        allocate(col_ind_temp(finish - start + 1))
        allocate(row_ind_temp(finish - start + 1))
        allocate(val_temp(finish - start + 1))

        i = start
        j = mid + 1
        k = 1

        do while (i <= mid .and. j <= finish)

            if (column_indexes(i) <= column_indexes(j)) then
                col_ind_temp(k) = column_indexes(i)
                row_ind_temp(k) = row_indexes(i)
                val_temp(k) = values(i)
                k = k + 1
                i = i + 1
            else
                col_ind_temp(k) = column_indexes(j)
                row_ind_temp(k) = row_indexes(j)
                val_temp(k) = values(j)
                k = k + 1
                j = j+ 1
            endif

        enddo

        do while (i <= mid)
            col_ind_temp(k) = column_indexes(i)
            row_ind_temp(k) = row_indexes(i)
            val_temp(k) = values(i)
            k = k + 1
            i = i + 1
        enddo

        do while (j <= finish)
            col_ind_temp(k) = column_indexes(j)
            row_ind_temp(k) = row_indexes(j)
            val_temp(k) = values(j)
            k = k + 1
            j = j + 1
        enddo

        do i = start, finish
            column_indexes(i) = col_ind_temp(i - start + 1)
            row_indexes(i) = row_ind_temp(i - start + 1)
            values(i) = val_temp(i - start + 1)
        enddo

    end subroutine Merge_Dagger

    subroutine Insertion_Sort_Dagger(   column_indexes, &
                                        row_indexes, &
                                        values)

        integer, intent(inout), dimension(:) :: column_indexes
        integer, intent(inout), dimension(:) :: row_indexes
        complex(dp), intent(inout), dimension(:) :: values

        integer :: col_ind_temp
        integer :: row_ind_temp
        complex(dp) :: val_temp

        integer :: i, j

        do i = 2, size(column_indexes)

            col_ind_temp = column_indexes(i)
            row_ind_temp = row_indexes(i)
            val_temp = values(i)

            j = i - 1

            do while (j >= 1)

                if (column_indexes(j) <= col_ind_temp) exit
                    column_indexes(j + 1) = column_indexes(j)
                    row_indexes(j + 1) = row_indexes(j)
                    values(j + 1) = values(j)
                    j = j - 1
            enddo
            column_indexes(j + 1) = col_ind_temp
            row_indexes(j + 1) = row_ind_temp
            values(j + 1) = val_temp

        enddo

    end subroutine Insertion_Sort_Dagger

    recursive subroutine Merge_Sort_Dagger( column_indexes, &
                                            row_indexes, &
                                            values, &
                                            start, &
                                            finish)

        integer, intent(inout), dimension(:) :: column_indexes
        integer, intent(inout), dimension(:) :: row_indexes
        complex(dp), intent(inout), dimension(:) :: values
        integer, intent(in) :: start
        integer, intent(in) :: finish

        integer :: mid

        if (start < finish) then
            if (finish - start >= 512) then

                mid = (start + finish) / 2

                call Merge_Sort_Dagger( column_indexes, &
                                        row_indexes, &
                                        values, &
                                        start, &
                                        mid)

                call Merge_Sort_Dagger( column_indexes, &
                                        row_indexes, &
                                        values, &
                                        mid + 1, &
                                        finish)

                call Merge_Dagger(  column_indexes, &
                                    row_indexes, &
                                    values, &
                                    start, &
                                    mid, &
                                    finish)

            else
                call insertion_sort_Dagger( column_indexes(start:finish), &
                                            row_indexes(start:finish), &
                                            values(start:finish))
            endif
        endif

    end subroutine Merge_Sort_Dagger

    subroutine CSR_Dagger(A, partition_table, A_T, MPI_communicator)

        type(CSR), intent(in) :: A
        integer, dimension(:), intent(in) :: partition_table
        type(CSR), intent(out) :: A_T
        integer, intent(in) :: MPI_communicator

        integer :: lb, ub
        integer :: element_lb_T, element_ub_T

        integer :: nz

        integer, dimension(:), allocatable :: row_indexes, column_indexes
        integer, dimension(:), allocatable :: column_indexes_in
        complex(dp), dimension(:), allocatable :: values

        integer, dimension(:), allocatable :: send_counts, rec_counts
        integer, dimension(:), allocatable :: send_disps, rec_disps

        integer, dimension(:), allocatable :: elements_per_rank
        integer, dimension(:), allocatable :: elements_per_rank_temp

        integer, dimension(:), allocatable :: mapping_disps
        integer, dimension(:), allocatable :: column_indexes_out, row_indexes_out
        complex(dp), dimension(:), allocatable :: values_out

        integer, dimension(:), allocatable :: target_rank

        integer :: i, j

        !MPI_Environment
        integer :: rank
        integer :: flock
        integer :: ierr

        call MPI_comm_size(MPI_communicator, flock, ierr)
        call MPI_comm_rank(MPI_communicator, rank, ierr)

        lb = partition_table(rank + 1)
        ub = partition_table(rank +2) - 1

        nz = size(A%col_indexes)

        A_T%rows = A%rows
        A_T%columns = A%columns

        allocate(column_indexes(A%row_starts(lb):A%row_starts(ub + 1) - 1))
        allocate(row_indexes(A%row_starts(lb):A%row_starts(ub + 1) - 1))
        allocate(values(A%row_starts(lb):A%row_starts(ub + 1) - 1))

        do i = lb, ub
            do j = A%row_starts(i), A%row_starts(i + 1) - 1
                row_indexes(j) = i
            enddo
        enddo

        do i = A%row_starts(lb), A%row_starts(ub + 1) - 1
            column_indexes(i) = A%col_indexes(i)
        enddo

        do i = A%row_starts(lb), A%row_starts(ub + 1) - 1
            values(i) = A%values(i)
        enddo

        allocate(send_counts(flock))

        send_counts = 0

        allocate(target_rank(A%row_starts(lb):A%row_starts(ub + 1) - 1))

        do i = lbound(column_indexes, 1), ubound(column_indexes, 1)

            do j = flock, 1, -1
                if (column_indexes(i) >= partition_table(j)) then
                    send_counts(j) = send_counts(j) + 1
                    target_rank(i) = j
                    exit
                endif
            enddo
        enddo

        allocate(send_disps(flock))

        send_disps(1) = 0

        do i = 2, flock
            send_disps(i) = send_disps(i - 1) + send_counts(i - 1)
        enddo

        allocate(mapping_disps(flock))

        mapping_disps = 0

        allocate(column_indexes_out(A%row_starts(lb):A%row_starts(ub + 1) - 1))
        allocate(row_indexes_out(A%row_starts(lb):A%row_starts(ub + 1) - 1))
        allocate(values_out(A%row_starts(lb):A%row_starts(ub + 1) - 1))

        do i = lb, ub
            do j = A%row_starts(i), A%row_starts(i + 1) - 1

                column_indexes_out(A%row_starts(lb) + send_disps(target_rank(j))  &
                    + mapping_disps(target_rank(j))) = column_indexes(j)

                values_out(A%row_starts(lb) + send_disps(target_rank(j))  &
                    + mapping_disps(target_rank(j))) = conjg(values(j))

                row_indexes_out(A%row_starts(lb) + send_disps(target_rank(j))  &
                    + mapping_disps(target_rank(j))) = row_indexes(j)

                mapping_disps(target_rank(j)) = mapping_disps(target_rank(j)) + 1

            enddo
        enddo

        allocate(rec_counts(flock))

        call MPI_alltoall(  send_counts, &
                            1, &
                            MPI_integer, &
                            rec_counts, &
                            1, &
                            MPI_integer, &
                            MPI_communicator, &
                            ierr)

        allocate(elements_per_rank_temp(flock))

        elements_per_rank_temp = 0
        elements_per_rank_temp(rank + 1) = sum(rec_counts)

        allocate(elements_per_rank(flock + 1))

        elements_per_rank(1) = 1
        elements_per_rank(2:flock + 1) = 0

        call mpi_allreduce( elements_per_rank_temp, &
                            elements_per_rank(2:flock + 1), &
                            flock, &
                            mpi_integer, &
                            mpi_sum, &
                            mpi_communicator, &
                            ierr)

        do i = 2, flock + 1
           elements_per_rank(i) = elements_per_rank(i) + elements_per_rank(i - 1)
        enddo

        element_lb_T = elements_per_rank(rank + 1)
        element_ub_T = elements_per_rank(rank + 2) - 1

        allocate(column_indexes_in(element_lb_T:element_ub_T))
        allocate(A_T%col_indexes(element_lb_T:element_ub_T))
        allocate(A_T%values(element_lb_T:element_ub_T))

        allocate(rec_disps(flock))

        rec_disps(1) = 0

        do i = 2, flock
            rec_disps(i) = rec_disps(i - 1) + rec_counts(i - 1)
        enddo

        call MPI_alltoallv( column_indexes_out, &
                            send_counts, &
                            send_disps, &
                            MPI_integer, &
                            column_indexes_in, &
                            rec_counts, &
                            rec_disps, &
                            MPI_integer, &
                            MPI_communicator, &
                            ierr)

        call MPI_alltoallv( row_indexes_out, &
                            send_counts, &
                            send_disps, &
                            MPI_integer, &
                            A_T%col_indexes, &
                            rec_counts, &
                            rec_disps, &
                            MPI_integer, &
                            MPI_communicator, &
                            ierr)

        call MPI_alltoallv( values_out, &
                            send_counts, &
                            send_disps, &
                            MPI_double_complex, &
                            A_T%values, &
                            rec_counts, &
                            rec_disps, &
                            MPI_double_complex, &
                            MPI_communicator, &
                            ierr)

        call Merge_Sort_Dagger( column_indexes_in, &
                                A_T%col_indexes, &
                                A_T%values, &
                                1, &
                                size(column_indexes_in))

        allocate(A_T%row_starts(lb:ub+1))

        A_T%row_starts(lb) = elements_per_rank(rank + 1)
        A_T%row_starts(lb + 1:ub + 1) = 0

        do i = element_lb_T, element_ub_T
            A_T%row_starts(column_indexes_in(i) + 1) = &
                A_T%row_starts(column_indexes_in(i) + 1) + 1
        enddo

        do i = lb + 1, ub + 1
            A_T%row_starts(i) = A_T%row_starts(i) + A_T%row_starts(i - 1)
        enddo

        call MPI_barrier(MPI_communicator, ierr)

    end subroutine CSR_Dagger

    subroutine Reconcile_Communications(A, &
                                        partition_table, &
                                        MPI_communicator)

        type(CSR), intent(inout) :: A
        integer, dimension(:), intent(in) :: partition_table
        integer, intent(in) :: MPI_communicator

        integer :: lb, ub, lb_elements, ub_elements

        integer :: total_rec_inds
        integer, dimension(:), allocatable :: RHS_rec_inds
        integer :: node

        integer, dimension(:), allocatable :: mapping_offsets

        integer :: i, j

        !real(dp) :: start, finish

        !MPI ENVIRONMENT
        integer :: rank
        integer :: flock
        integer :: ierr

        call mpi_comm_size( mpi_communicator, &
                            flock, &
                            ierr)

        call mpi_comm_rank( mpi_communicator, &
                            rank, &
                            ierr)

        lb = partition_table(rank + 1)
        ub = partition_table(rank + 2) - 1

        lb_elements = lbound(A%col_indexes, 1)
        ub_elements = ubound(A%col_indexes, 1)

        ! Determine the number of unique RHS indexes to recieve from each node
        ! and their total.

        allocate(A%num_rec_inds(flock))
        A%num_rec_inds = 0

        !allocate(RHS_rec_inds(0))

        total_rec_inds = 0

        do i = lb_elements, ub_elements

            if ((A%col_indexes(i) < lb) .or. (A%col_indexes(i) > ub)) then

                    do j = flock, 1, -1

                        if (A%col_indexes(i) >= partition_table(j)) then
                            node = j
                            exit
                        endif

                    enddo

                    A%num_rec_inds(node) = A%num_rec_inds(node) + 1
                    total_rec_inds = total_rec_inds + 1

            endif
        enddo

        ! Calculate the offset of the external elements in the 1D receive buffer.

        allocate(A%rec_disps(flock))

        A%rec_disps = 0
        do i = 2, flock
            A%rec_disps(i) = A%rec_disps(i - 1) + A%num_rec_inds(i - 1)
        enddo

        ! Create an ordered list of unique RHS receive indexes. Remap CSR column
        ! indexes pointing to external RHS vector elements such that their
        ! access occurs with the same efficiency as the local RHS elements.

        allocate(A%local_col_inds(lb_elements:ub_elements))
        do i = lb_elements, ub_elements
            A%local_col_inds(i) = A%col_indexes(i)
        enddo

        !deallocate(RHS_rec_inds)
        allocate(RHS_rec_inds(total_rec_inds))
        RHS_rec_inds = 0

        allocate(mapping_offsets(flock))
        mapping_offsets = 1

        do i = lb_elements, ub_elements

            if ((A%local_col_inds(i) < lb) .or. (A%local_col_inds(i) > ub)) then

                !if (.not. any(A%local_col_inds(i) == RHS_rec_inds)) then

                    do j = flock, 1, -1

                        if (A%local_col_inds(i) >= partition_table(j)) then
                            node = j
                            exit
                        endif

                    enddo

                    RHS_rec_inds(A%rec_disps(node) + mapping_offsets(node)) = A%local_col_inds(i)

                    A%local_col_inds(i) = ub + A%rec_disps(node) &
                        + mapping_offsets(node)

                    mapping_offsets(node) = mapping_offsets(node) + 1

            endif
        enddo

        allocate(A%num_send_inds(flock))

        call MPI_alltoall(  A%num_rec_inds, &
                            1, &
                            MPI_integer, &
                            A%num_send_inds, &
                            1, &
                            MPI_integer, &
                            MPI_communicator, &
                            ierr)

        allocate(A%RHS_send_inds(sum(A%num_send_inds)))
        allocate(A%send_disps(flock))

        ! Calculate the offset of the local send elements in the 1D send buffer.

        A%send_disps = 0
        do i = 2, flock
            A%send_disps(i) = A%send_disps(i - 1) + A%num_send_inds(i - 1)
        enddo

        ! Obtain which RHS indexes to send to each node from the locally
        ! determined receive elements.

        call MPI_alltoallv( RHS_rec_inds, &
                            A%num_rec_inds, &
                            A%rec_disps, &
                            MPI_integer, &
                            A%RHS_send_inds, &
                            A%num_send_inds, &
                            A%send_disps, &
                            MPI_integer, &
                            MPI_communicator, &
                            ierr)

    end subroutine Reconcile_Communications

    !
    !   subroutine: SpMM
    !
    !> @brief MPI parallel CSR sparse-matrix dense-matrix multiplication.
    !>
    !> @details Computes A^(n)*B = C where *A* is a matrix, *B*, *C* are matrices
    !> and *n* is an integer.
    !>
    !> *CSR* matrix *A* and matrix *B* must be paritioned as given by
    !> *partition_table*, see @ref sparse_parts::generate_partition_table for more.
    !>
    !> @warning *spmm* requires that the *col_index* and *value* arrays of the CSR
    !> data type are stored in accending column order for each row subsection.


    subroutine SpMM(A, &
                    n, &
                    B_local, &
                    partition_table, &
                    rank, &
                    C_local, &
                    mpi_communicator)

        type(CSR), intent(inout) :: A !< @param Local CSR array partition.
        integer, intent(in) :: n !< @param Exponent on A.
        complex(dp), dimension(:,:), intent(in) :: B_local !< @param Local input dense matrix partition.
        integer, dimension(:), intent(in) :: partition_table !< @param MPI communicator partition scheme.
        integer, intent(in) :: rank
        complex(dp), &
        dimension(partition_table(rank + 1):partition_table(rank + 2) - 1, size(B_local, 2)), &
            intent(out) :: C_local  !< Local output matrix partition.
        integer, intent(in) :: mpi_communicator !< @param MPI communicator handel.

        complex(dp), dimension(:,:), allocatable :: B_resize
        complex(dp), dimension(:), allocatable :: rec_values, send_values

        integer :: num_rec, num_send
        integer :: lb, ub, lb_resize, ub_resize

        integer ::  B_col

        integer :: i, j, k, l

        ! MPI environment
        integer :: ierr

        lb = partition_table(rank + 1)
        ub = partition_table(rank + 2) - 1

        num_rec = sum(A%num_rec_inds)
        num_send = sum(A%num_send_inds)

        lb_resize = ub + 1
        ub_resize = ub + num_rec

        B_col = size(B_local, 2)

        allocate(B_resize(lb:ub_resize, B_col))

        B_resize(lb:ub,:) = B_local

        allocate(rec_values(num_rec))
        allocate(send_values(num_send))

        do l = 1, n

            do j = 1, B_col

                do i = 1, num_send
                    send_values(i) = B_resize(A%RHS_send_inds(i), j)
                enddo

                call MPI_alltoallv( send_values, &
                                    A%num_send_inds, &
                                    A%send_disps, &
                                    MPI_double_complex, &
                                    rec_values, &
                                    A%num_rec_inds, &
                                    A%rec_disps, &
                                    MPI_double_complex, &
                                    MPI_communicator, &
                                    ierr)

                B_resize(lb_resize:ub_resize, j) = rec_values

            enddo

            C_local = 0

            do i = lb, ub
                do j = A%row_starts(i), A%row_starts(i + 1) - 1
                    do k = 1, B_col
                        C_local(i, k) = A%values(j)*B_resize(A%local_col_inds(j), k) &
                            + C_local(i, k)
                    enddo
                enddo
            enddo

            if (l < n) then
                B_resize(lb:ub,:) = C_local
            endif

        enddo

    end subroutine SpMM

    !
    !   subroutine: SpMV_Series
    !
    !> @brief MPI parallel CSR sparse-matrix dense-vector series multiplication.
    !>
    !> @details Computes A^(n)*u = v where *A* is a matrix, *u*, *v* are vectors,
    !> *n* is an integer and is given by n = max_it - start_it + 1.
    !> This SpMV varient is designed to be called repeatedly
    !> from within a loop, such that additional operations may be performed on
    !> *v* between iterations. Various optimisation assocaited arrays  are saved
    !> and are deallocated after the final iteration as given by *max_it*.
    !>
    !> *CSR* matrix *A* and vector *u* must be paritioned as given by
    !> *partition_table*, see @ref sparse_parts::generate_partition_table for more.
    !>
    !> @warning *spmv_series* requires that the *col_index* and *value* arrays of the CSR
    !> data type are stored in accending column order for each row subsection.

    subroutine SpMV_Series( A, &
                            u_local, &
                            partition_table, &
                            start_it, &
                            current_it, &
                            max_it, &
                            rank, &
                            v_local, &
                            mpi_communicator)

        type(CSR), intent(in) :: A !< @param Local CSR array partition.
        complex(dp), dimension(:), intent(inout) :: u_local !< @param Local input vector partition.
        integer, dimension(:), intent(in) :: partition_table !< @param MPI communicator partition scheme.
        integer, intent(in) :: start_it !< @param starting multiplication index.
        integer, intent(in) :: current_it !< @param Current multiplication index
        integer, intent(in) :: max_it !< @param Final multiplication index.
        integer, intent(in) :: rank
        integer, intent(in) :: mpi_communicator !< @param MPI communicator handel.
        complex(dp), dimension(partition_table(rank + 1):partition_table(rank + 2) - 1), &
            intent(inout) :: v_local !< @param Local output vector partition.

        complex(dp), dimension(:), allocatable, save :: u_resize
        complex(dp), dimension(:), allocatable, save :: send_values
        complex(dp), dimension(:), allocatable, save :: rec_values

        integer :: lb, ub, lb_resize, ub_resize
        integer :: num_send, num_rec

        integer :: i, j

        ! MPI environment
        integer :: ierr

        real(dp), save :: start_calc, finish_calc, start_comm, finish_comm, calc, comm, start_guff, finish_guff, guff
        real(dp), save :: start_send, end_send, send

        start_guff = MPI_wtime()

        lb = partition_table(rank + 1)
        ub = partition_table(rank + 2) - 1

        num_rec = sum(A%num_rec_inds)
        num_send = sum(A%num_send_inds)

        lb_resize = ub + 1
        ub_resize = ub + num_rec

        if ((start_it == current_it) .and. allocated(u_resize)) then
            deallocate(u_resize)
            deallocate(rec_values)
            deallocate(send_values)
        endif

        if (.not. allocated(u_resize)) then
            !comm = 0
            !calc = 0
            allocate(u_resize(lb:ub_resize))
            allocate(rec_values(num_rec))
            allocate(send_values(num_send))
        endif

        !Calling with start_it = 0 and max_it = 0 clears the saved arrays if need.
        if ((start_it == 0) .and. (max_it == 0)) then
            if (allocated(u_resize)) then
                deallocate(u_resize)
                deallocate(rec_values)
                deallocate(send_values)
            endif
            !write(*,*) "calc", calc, "comm", comm, "sum", calc + comm, "guff", guff, "Allreduce + calc", send + calc, "ALL", send
            return
        endif

        u_resize(lb:ub) = u_local

        finish_guff = MPI_wtime()

        guff = guff + finish_guff - start_guff

        start_comm = MPI_wtime()

        do i = 1, num_send
            send_values(i) = u_resize(A%RHS_send_inds(i))
        enddo

        start_send = MPI_wtime()

        call MPI_alltoallv( send_values, &
                            A%num_send_inds, &
                            A%send_disps, &
                            MPI_double_complex, &
                            rec_values, &
                            A%num_rec_inds, &
                            A%rec_disps, &
                            MPI_double_complex, &
                            MPI_communicator, &
                            ierr)

        end_send = MPI_wtime()
        send = send + end_send - start_send

        finish_comm = MPI_wtime()

        u_resize(lb_resize:ub_resize) = rec_values

        comm = comm + finish_comm - start_comm

        start_calc = MPI_wtime()

        v_local = 0

        do i = lb, ub
            do j = A%row_starts(i), A%row_starts(i + 1) - 1

                v_local(i) = A%values(j)*u_resize(A%local_col_inds(j)) &
                    + v_local(i)

            enddo
        enddo

        finish_calc = MPI_wtime()

        calc = calc + finish_calc - start_calc

        if (current_it == max_it) then
            deallocate(u_resize)
            deallocate(rec_values)
            deallocate(send_values)
            !write(*,*) "calc", calc, "comm", comm, "sum", calc + comm, "guff", guff
            !write(*,*) "AllReduce", send
        endif

    end subroutine SpMV_Series

    subroutine Reconcile_Communications_A(A, &
                                        partition_table, &
                                        MPI_communicator)

        type(CSR), intent(inout) :: A
        integer, dimension(:), intent(in) :: partition_table
        integer, intent(in) :: MPI_communicator

        integer :: lb, ub, lb_elements, ub_elements

        integer :: node

        integer :: i, j

        !MPI ENVIRONMENT
        integer :: rank
        integer :: flock
        integer :: ierr

        call mpi_comm_size( mpi_communicator, flock, ierr)

        call mpi_comm_rank( mpi_communicator, rank, ierr)

        lb = partition_table(rank + 1)
        ub = partition_table(rank + 2) - 1

        lb_elements = lbound(A%col_indexes, 1)
        ub_elements = ubound(A%col_indexes, 1)

        ! Determine the number of unique RHS indexes to recieve from each node
        ! and their total.

        A%num_rec_inds = 0

        do i = lb_elements, ub_elements

            if ((A%col_indexes(i) < lb) .or. (A%col_indexes(i) > ub)) then

                    do j = flock, 1, -1

                        if (A%col_indexes(i) >= partition_table(j)) then
                            node = j
                            exit
                        endif

                    enddo

                    A%num_rec_inds(node) = A%num_rec_inds(node) + 1

            endif
        enddo

        ! Calculate the offset of the external elements in the 1D receive buffer.

        A%rec_disps = 0
        do i = 2, flock
            A%rec_disps(i) = A%rec_disps(i - 1) + A%num_rec_inds(i - 1)
        enddo

        call MPI_alltoall(  A%num_rec_inds, &
                            1, &
                            MPI_integer, &
                            A%num_send_inds, &
                            1, &
                            MPI_integer, &
                            MPI_communicator, &
                            ierr)

        A%send_disps = 0
        do i = 2, flock
            A%send_disps(i) = A%send_disps(i - 1) + A%num_send_inds(i - 1)
        enddo

    end subroutine Reconcile_Communications_A

    subroutine Reconcile_Communications_B(A, &
                                        partition_table, &
                                        MPI_communicator)

        type(CSR), intent(inout) :: A
        integer, dimension(:), intent(in) :: partition_table
        integer, intent(in) :: MPI_communicator

        integer :: lb, ub, lb_elements, ub_elements

        integer, dimension(:), allocatable :: RHS_rec_inds
        integer :: node

        integer, dimension(:), allocatable :: mapping_offsets

        integer :: i, j

        integer :: rank
        integer :: flock
        integer :: ierr

        call mpi_comm_size( mpi_communicator, &
                            flock, &
                            ierr)

        call mpi_comm_rank( mpi_communicator, &
                            rank, &
                            ierr)

        lb = partition_table(rank + 1)
        ub = partition_table(rank + 2) - 1

        lb_elements = lbound(A%col_indexes, 1)
        ub_elements = ubound(A%col_indexes, 1)

        do i = lb_elements, ub_elements
            A%local_col_inds(i) = A%col_indexes(i)
        enddo

        allocate(RHS_rec_inds(sum(A%num_rec_inds)))
        RHS_rec_inds = 0

        allocate(mapping_offsets(flock))
        mapping_offsets = 1

        do i = lb_elements, ub_elements

            if ((A%local_col_inds(i) < lb) .or. (A%local_col_inds(i) > ub)) then

                    do j = flock, 1, -1

                        if (A%local_col_inds(i) >= partition_table(j)) then
                            node = j
                            exit
                        endif

                    enddo

                    RHS_rec_inds(A%rec_disps(node) + mapping_offsets(node)) = A%local_col_inds(i)

                    A%local_col_inds(i) = ub + A%rec_disps(node) &
                        + mapping_offsets(node)

                    mapping_offsets(node) = mapping_offsets(node) + 1

            endif
        enddo

        call MPI_alltoallv( RHS_rec_inds, &
                            A%num_rec_inds, &
                            A%rec_disps, &
                            MPI_integer, &
                            A%RHS_send_inds, &
                            A%num_send_inds, &
                            A%send_disps, &
                            MPI_integer, &
                            MPI_communicator, &
                            ierr)

    end subroutine Reconcile_Communications_B

    subroutine Merge_CSR(   column_indexes, &
                            values, &
                            start, &
                            mid, &
                            finish)

        integer, intent(inout), dimension(:) :: column_indexes
        complex(dp), intent(inout), dimension(:) :: values
        integer, intent(in) :: start
        integer, intent(in) :: mid
        integer, intent(in) :: finish

        integer, dimension(:), allocatable :: col_ind_temp
        complex(dp), dimension(:), allocatable :: val_temp
        integer :: i, j, k

        allocate(col_ind_temp(finish - start + 1))
        allocate(val_temp(finish - start + 1))

        i = start
        j = mid + 1
        k = 1

        do while (i <= mid .and. j <= finish)

            if (column_indexes(i) <= column_indexes(j)) then
                col_ind_temp(k) = column_indexes(i)
                val_temp(k) = values(i)
                k = k + 1
                i = i + 1
            else
                col_ind_temp(k) = column_indexes(j)
                val_temp(k) = values(j)
                k = k + 1
                j = j+ 1
            endif

        enddo

        do while (i <= mid)
            col_ind_temp(k) = column_indexes(i)
            val_temp(k) = values(i)
            k = k + 1
            i = i + 1
        enddo

        do while (j <= finish)
            col_ind_temp(k) = column_indexes(j)
            val_temp(k) = values(j)
            k = k + 1
            j = j + 1
        enddo

        do i = start, finish
            column_indexes(i) = col_ind_temp(i - start + 1)
            values(i) = val_temp(i - start + 1)
        enddo

    end subroutine Merge_CSR

    subroutine Insertion_Sort_CSR(   column_indexes, &
                                        values)

        integer, intent(inout), dimension(:) :: column_indexes
        complex(dp), intent(inout), dimension(:) :: values

        integer :: col_ind_temp
        complex(dp) :: val_temp

        integer :: i, j

        do i = 2, size(column_indexes)

            col_ind_temp = column_indexes(i)
            val_temp = values(i)

            j = i - 1

            do while (j >= 1)

                if (column_indexes(j) <= col_ind_temp) exit
                    column_indexes(j + 1) = column_indexes(j)
                    values(j + 1) = values(j)
                    j = j - 1
            enddo
            column_indexes(j + 1) = col_ind_temp
            values(j + 1) = val_temp

        enddo

    end subroutine Insertion_Sort_CSR

    recursive subroutine Merge_Sort_CSR( column_indexes, &
                                            values, &
                                            start, &
                                            finish)

        integer, intent(inout), dimension(:) :: column_indexes
        complex(dp), intent(inout), dimension(:) :: values
        integer, intent(in) :: start
        integer, intent(in) :: finish

        integer :: mid

        if (start < finish) then
            if (finish - start >= 512) then

                mid = (start + finish) / 2

                call Merge_Sort_CSR( column_indexes, &
                                        values, &
                                        start, &
                                        mid)

                call Merge_Sort_CSR( column_indexes, &
                                        values, &
                                        mid + 1, &
                                        finish)

                call Merge_CSR(  column_indexes, &
                                    values, &
                                    start, &
                                    mid, &
                                    finish)

            else
                call insertion_sort_CSR( column_indexes(start:finish), &
                                            values(start:finish))
            endif
        endif

    end subroutine Merge_Sort_CSR

    subroutine Sort_CSR(A)

        type(CSR), intent(inout) :: A

        integer :: i

        do i = lbound(A%row_starts,1), ubound(A%row_starts,1) - 1

            call Merge_Sort_CSR(A%col_indexes(A%row_starts(i):A%row_starts(i + 1) - 1), &
                                A%values(A%row_starts(i):A%row_starts(i + 1) - 1), &
                                1, &
                                A%row_starts(i + 1) - A%row_starts(i))

        enddo

    end subroutine Sort_CSR

end module Sparse
