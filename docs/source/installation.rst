Installation
============

After cloning the repository enter 'QSW_MPI/src' and build the Fortran shared object libraries:

.. code-block:: bash

    make

After this the QSW_MPI package may be used by importing the 'QSW_MPI' folder to python's system path at runtime:

.. code-block:: python

    import sys
    sys.path.append('path_to/QSW_MPI')
    import qsw_mpi as qsw

Or, to install 'QSW_MPI' as normal, in the 'QSW_MPI' folder generate a distribution archive:

.. code-block:: python

    python3 setup.py sdist bdist_wheel

Enter the newly created 'QSW_MPI/dist' folder which should contain the archive 'qsw_mpi-0.0.1.tar.gz'. For with the QSW_MPI can be installed using pip3:

.. code-block:: bash

    pip3 install qsw_mpi-0.0.1.tar.gz


