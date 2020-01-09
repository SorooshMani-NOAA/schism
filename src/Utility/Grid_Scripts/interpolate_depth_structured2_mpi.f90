!   Copyright 2014 College of William and Mary
!
!   Licensed under the Apache License, Version 2.0 (the "License");
!   you may not use this file except in compliance with the License.
!   You may obtain a copy of the License at
!
!     http://www.apache.org/licenses/LICENSE-2.0
!
!   Unless required by applicable law or agreed to in writing, software
!   distributed under the License is distributed on an "AS IS" BASIS,
!   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
!   See the License for the specific language governing permissions and
!   limitations under the License.

!     Interpolate depths from structured grid DEMs (.asc) to unstructured grid in
!     parallel (in overlapping regions, the depth from larger rank/DEM prevails)
!     Inputs: 1st few lines of inputs below; 
!             dem_????.asc (ordered properly for precedence);
!             hgrid.old (unstructured grid, mixed tri and quads)
!     Output: hgrid.new (for pts outside the DEMs or the DEM depth is junk there, 
!                        the original depths are preserved).
!     mpif90 -O2 -mcmodel=medium -CB -g -traceback -o interpolate_depth_structured2_mpi interpolate_depth_structured2_mpi.f90

      program load_dems
      implicit real*8(a-h,o-z)
      include 'mpif.h'
      character*5 cha1
      character*9 cha2
      character*12 cha3,fdb
      integer :: myrank,myrank2,errcode,color,comm,mycomm,itmp,ierr,i,j,k,nproc,nm(4)
      real(kind=8), allocatable :: dp1(:,:),x0(:),y0(:),dp0(:),dpout(:)

      call MPI_INIT(errcode)
      call mpi_comm_dup(MPI_COMM_WORLD,comm,errcode)
      call mpi_comm_size(comm,nproc,ierr)
      call MPI_COMM_RANK(comm, myrank, errcode)
      print *, 'Hello from ', myrank

!     Inputs
!      print*, 'Reverse the sign of the depth? (1: no; -1: yes; say yes)'
!      read*, ih
!      print*, 'Add vertical const. to outputs (i.e. change of vdatum):'
!      read*, vshift
      ndems=20 !# of DEMs
      if(nproc+1<ndems) then
        print*, 'Please use more cores than DEMs:',nproc+1,ndems
        call mpi_abort(comm,0,j)
      endif
      ih=-1
      vshift=0

      open(14,file='hgrid.old',status='old')
      read(14,*)
      read(14,*)ne,np
      allocate(x0(np),y0(np),dp0(np))
      do i=1,np
        read(14,*)j,x0(i),y0(i),dp0(i)
      enddo !i

      do irank=0,ndems-1
        if(irank==myrank) then
          fdb='dem_0000'
          lfdb=len_trim(fdb)
          write(fdb(lfdb-3:lfdb),'(i4.4)') irank

          open(62,file=trim(adjustl(fdb))//'.asc',status='old')
          open(19,file=trim(adjustl(fdb))//'.out',status='replace') !temp output from each rank
          read(62,*) cha1,nx !# of nodes in x
          read(62,*) cha1,ny !# of nodes in y
          read(62,*) cha2,xmin
          read(62,*) cha2,ymin
          read(62,*) cha2,dxy
          read(62,*) cha3,fill_value
          dx=dxy
          dy=dxy
    
          allocate(dp1(nx,ny),stat=istat)
          if(istat/=0) then
            print*, 'Failed to allocate (1)'
            call mpi_abort(comm,0,j) 
          endif
    
!         Coordinates for upper left corner (the starting point for *.asc)
          ymax=ymin+(ny-1)*dy
!         xmax
          xmax=xmin+(nx-1)*dx
    
!         .asc starts from upper left corner and goes along x
          do iy=1,ny
            read(62,*)(dp1(ix,ny-iy+1),ix=1,nx)
!            write(99,*)'line read in:',iy+6
          enddo !iy
          close(62)
       
          do i=1,np
!            read(14,*)j,x,y,dp
            x=x0(i); y=y0(i)
    
            !Interpolate
            if(x.gt.xmax.or.x.lt.xmin.or.y.gt.ymax.or.y.lt.ymin) then
!              write(13,101)j,x,y,dp
!              dpout(i)=dp0(i)
            else !inside structured grid
              x2=x 
              y2=y 
              ix=(x2-xmin)/dx+1 !i-index of the lower corner of the parent box 
              iy=(y2-ymin)/dy+1
              if(ix.lt.1.or.ix.gt.nx.or.iy.lt.1.or.iy.gt.ny) then
                print*, 'Impossible:',i,ix,iy
                call mpi_abort(comm,0,j)
              endif
    
              if(ix.eq.nx) then !for pts right on the right bnd
                ix=nx-1
                xrat=1
              else
                xrat=(x2-xmin)/dx-ix+1
              endif
              if(iy.eq.ny) then !for pts right on the upper bnd
                iy=ny-1
                yrat=1
              else
                yrat=(y2-ymin)/dy-iy+1
              endif
              if(xrat.lt.0.or.xrat.gt.1.or.yrat.lt.0.or.yrat.gt.1) then
                print*, 'ratios out of bound:',i,xrat,yrat
                call mpi_abort(comm,0,j)
              endif
     
              if(abs(dp1(ix,iy)-fill_value)<1.e-2.or.abs(dp1(ix+1,iy)-fill_value)<1.e-2.or. &
         &abs(dp1(ix,iy+1)-fill_value)<1.e-2.or.abs(dp1(ix+1,iy+1)-fill_value)<1.e-2) then
!                dpout(i)=dp0(i)
!                write(13,101)j,x,y,dp
              else !all valid
                hy1=dp1(ix,iy)*(1-xrat)+xrat*dp1(ix+1,iy)
                hy2=dp1(ix,iy+1)*(1-xrat)+xrat*dp1(ix+1,iy+1)
                h=hy1*(1-yrat)+hy2*yrat
                h=h*ih+vshift

                !Write temp output (in 'valid' region only)
                write(19,*)i,h
              endif !junk
    
            endif
          enddo !i=1,np
        endif !irank==myrank
      enddo !irank
      close(19)

      call mpi_barrier(comm,ierr)

      !Combine on rank 0
      if(myrank==0) then
        do irank=0,ndems-1
          fdb='dem_0000'
          lfdb=len_trim(fdb)
          write(fdb(lfdb-3:lfdb),'(i4.4)') irank
          open(19,file=trim(adjustl(fdb))//'.out',status='old')
          lines=0
          do
            read(19,*,end=100,err=100)i,dp0(i)
            lines=lines+1
          enddo

100       print*, lines,' lines read from rank ',irank
          close(19)
        enddo !irank

        open(13,file='hgrid.new',status='replace')
        write(13,*)'Bathymetry loaded grid'
        write(13,*)ne,np
        do i=1,np
          write(13,101)i,x0(i),y0(i),dp0(i)
        enddo !i
        do i=1,ne
          read(14,*)j,k,(nm(l),l=1,k)
          write(13,*)j,k,(nm(l),l=1,k)
        enddo !i
        close(13)
      endif !myrank=0
101   format(i9,2(1x,e24.16),1x,f13.6)
      close(14)

      call MPI_FINALIZE(errcode)
      end program