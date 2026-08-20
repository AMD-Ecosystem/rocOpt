Status Codes
============

.. role:: py(code)
   :language: c
   :class: highlight

Every function in the C API returns a status code that indicates success or
failure. The following status codes are defined.

``#include <cuopt_c.h>``

.. doxygendefine:: CUOPT_SUCCESS
    :project: cuopt

.. doxygendefine:: CUOPT_INVALID_ARGUMENT
    :project: cuopt

.. doxygendefine:: CUOPT_MPS_FILE_ERROR
    :project: cuopt

.. doxygendefine:: CUOPT_MPS_PARSE_ERROR
    :project: cuopt

.. doxygendefine:: CUOPT_VALIDATION_ERROR
    :project: cuopt

.. doxygendefine:: CUOPT_OUT_OF_MEMORY
    :project: cuopt

.. doxygendefine:: CUOPT_RUNTIME_ERROR
    :project: cuopt
