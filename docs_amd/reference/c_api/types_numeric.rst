Integer and Floating-Point Types
================================

.. role:: py(code)
   :language: c
   :class: highlight

cuOpt may be built with 32 or 64 bit integer and floating-point types. The C API
uses a ``typedef`` for floating point and integer types to abstract the size of
these types.

``#include <cuopt_c.h>``

.. doxygentypedef:: cuopt_int_t
    :project: cuopt

.. doxygentypedef:: cuopt_float_t
    :project: cuopt

You may use the following functions to determine the number of bytes used to
represent these types in your build.

.. doxygenfunction:: cuOptGetIntSize
    :project: cuopt

.. doxygenfunction:: cuOptGetFloatSize
    :project: cuopt
