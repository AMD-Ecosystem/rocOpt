===============================
Third-Party Modeling Languages
===============================


--------------------------
AMPL Support
--------------------------

AMPL can be used with near zero code changes: simply switch to cuOpt as a solver to solve linear and mixed-integer programming problems. Please refer to the `AMPL documentation <https://www.ampl.com/>`_ for more information. Also, see the example notebook in the `colab <https://colab.research.google.com/drive/1eEQik_pae4g_tJQ61QJFlO1fFBXazpBr?usp=sharing>`_.

--------------------------
GAMS and GAMSPy Support
--------------------------

.. TODO(rocopt): replace GAMS solver-link reference with rocOpt-specific guide when available
.. TODO(rocopt): replace cuopt-examples reference with rocOpt examples repo URL when available

GAMS and GAMSPy models can be used with near zero code changes after setting up the solver link: simply switch to cuOpt as a solver to solve linear and mixed-integer programming problems (e.g. ``gams trnsport lp=cuopt``).

--------------------------
PuLP Support
--------------------------

.. TODO(rocopt): replace cuopt-examples reference with rocOpt examples repo URL when available

PuLP can be used with near zero code changes: simply switch to cuOpt as a solver to solve linear and mixed-integer programming problems.
Please refer to the `PuLP documentation <https://pypi.org/project/PuLP/>`_ for more information.

--------------------------
JuMP Support
--------------------------

.. TODO(rocopt): replace JuMP solver-link reference with rocOpt-specific guide when available

JuMP can be used with near zero code changes: simply switch to cuOpt as a solver to solve linear and mixed-integer programming problems.
