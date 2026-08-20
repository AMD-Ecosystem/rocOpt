.. meta::
   :description: API reference for the libmps_parser library in rocopt, covering MPS file parsing, writing, and data model types.
   :keywords: rocopt, MPS, parser, writer, libmps_parser, MpsParser, MpsDataModel, MpsDataModelView, MpsWriter, API, ROCm

========================
MPS parser API reference
========================

The ``libmps_parser`` library is a standalone shared library co-built and co-installed with rocopt. It provides functionality for reading MPS and MIPLIB format files and writing optimization problems back to MPS format. This page documents the public C++ API exposed through the library's header files.

.. note::

   The source material available for this page is limited to the file tree and header file paths. The detailed function signatures, parameter descriptions, and Doxygen comments from the header files were not provided in full. The sections below document the public types and expected API surface based on the available information. Additional source material (the full header file contents) is required to complete parameter-level documentation.

MPS data model
**************

The MPS data model types represent the parsed contents of an MPS file in memory.

``MpsDataModel``
----------------

Declared in ``mps_parser/mps_data_model.hpp``.

``MpsDataModel`` stores the complete representation of an optimization problem parsed from an MPS file. This includes the objective function, constraint matrix (in sparse format), variable bounds, constraint senses and right-hand sides, variable types (continuous or integer), and problem metadata such as row and column names.

This type owns all parsed data and serves as the primary container returned by the parser.

``MpsDataModelView``
--------------------

Declared in ``mps_parser/data_model_view.hpp``.

``MpsDataModelView`` provides a non-owning view into an ``MpsDataModel``. It exposes the same problem data (objective coefficients, constraint matrix, bounds, variable types) through lightweight accessors without copying the underlying storage.

Use ``MpsDataModelView`` when you need read-only access to parsed problem data, such as when passing the data to a solver or performing analysis without modifying the original model.

Parser API
**********

The parser API reads MPS format files and produces an ``MpsDataModel``.

``MpsParser``
-------------

Declared in ``mps_parser/parser.hpp``.

``MpsParser`` is the main class for reading MPS files. It parses standard fixed-format and free-format MPS files, including MIPLIB extensions for integer and binary variable markers.

Typical usage:

.. code-block:: cpp

   #include <mps_parser/parser.hpp>

   MpsParser parser;
   MpsDataModel model = parser.parse("problem.mps");

``parse``
^^^^^^^^^

Parses an MPS file from disk and returns the problem data.

.. code-block:: cpp

   MpsDataModel parse(const std::string& filename);

:param filename: Path to the MPS file to parse.
:returns: An ``MpsDataModel`` containing the parsed optimization problem data.

Writer API
**********

The writer API serializes optimization problem data back to MPS format files.

``MpsWriter``
-------------

Declared in ``mps_parser/mps_writer.hpp``.

``MpsWriter`` writes an optimization problem to an MPS format file. It accepts problem data and produces a standards-compliant MPS output file.

``write`` (free function)
-------------------------

Declared in ``mps_parser/writer.hpp``.

The ``writer.hpp`` header provides a free function interface for writing MPS files, complementing the ``MpsWriter`` class.

.. code-block:: cpp

   void write(const std::string& filename, const MpsDataModelView& model);

:param filename: Path to the output MPS file.
:param model: A view of the problem data to write.

Cython MPS parser utilities
***************************

Declared in ``mps_parser/utilities/cython_mps_parser.hpp``.

The ``cython_mps_parser`` utilities provide a bridge between the C++ ``libmps_parser`` library and the Python layer via Cython. These utilities handle the conversion of parsed MPS data into Python-compatible representations (such as NumPy arrays), enabling the Python API to load and manipulate MPS files without reimplementing the parser.

This interface is primarily for internal use by the rocopt Python package and is not intended for direct consumption by end users.

Span utility
************

Declared in ``mps_parser/utilities/span.hpp``.

The ``span`` utility provides a lightweight, non-owning view over contiguous memory, similar to ``std::span`` in C++20. It is used internally by the ``libmps_parser`` API to pass arrays without requiring ownership transfer.

Header file summary
*******************

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Header
     - Description
   * - ``mps_parser/parser.hpp``
     - Top-level include for the ``MpsParser`` class and parse functions
   * - ``mps_parser/mps_data_model.hpp``
     - Definition of the ``MpsDataModel`` owning container
   * - ``mps_parser/data_model_view.hpp``
     - Definition of the ``MpsDataModelView`` non-owning view
   * - ``mps_parser/mps_writer.hpp``
     - Definition of the ``MpsWriter`` class
   * - ``mps_parser/writer.hpp``
     - Free function interface for writing MPS files
   * - ``mps_parser/utilities/cython_mps_parser.hpp``
     - Cython bridge utilities for Python integration
   * - ``mps_parser/utilities/span.hpp``
     - Lightweight span utility for contiguous memory views
