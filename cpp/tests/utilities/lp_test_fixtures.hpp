/* clang-format off */
/*
 * SPDX-FileCopyrightText: Copyright (c) 2026 AMD
 * SPDX-License-Identifier: Apache-2.0
 */
/* clang-format on */

#pragma once

// Reusable lp_problem_t<int,double> builders for cpp/src/dual_simplex unit
// tests. Centralized so coverage tests for folding.cpp / presolve.cpp /
// basis_updates.cpp / branch_and_bound.cpp / solve.cpp don't repeat the same
// 30-line CSC matrix population by hand.
//
// All builders are inline to keep this header-only -- the test sources that
// include it get an in-TU definition. They are intentionally NOT templated;
// the dual_simplex code only instantiates <int, double> in libcuopt.so, so
// other floating-point types would not link anyway.

#include <dual_simplex/presolve.hpp>
#include <dual_simplex/types.hpp>

#include <vector>

namespace cuopt::linear_programming::dual_simplex::test {

// Build a balanced transportation LP:
//   minimize  sum_{i,j} x_{i,j}
//   subject to sum_j x_{i,j} = capacity            for each supply i
//              sum_i x_{i,j} = capacity            for each demand j
//              0 <= x_{i,j} <= upper_bound
//
// num_supplies * num_demands variables (column order: x_{0,0}, x_{0,1}, ..., x_{S-1,D-1}).
// num_supplies + num_demands constraints (row order: supply rows, then demand rows).
//
// The augmented matrix produced by folding.cpp has a non-trivial automorphism
// between supplies/demands and between variables. This exercises the
// iterative-refinement loop in `color_graph()`.
inline void make_balanced_transportation_lp(lp_problem_t<int, double>& p,
                                            int num_supplies   = 2,
                                            int num_demands    = 2,
                                            double capacity    = 10.0,
                                            double upper_bound = 8.0)
{
  const int m  = num_supplies + num_demands;
  const int n  = num_supplies * num_demands;
  const int nz = 2 * n;  // each variable touches one supply row and one demand row

  p.num_rows = m;
  p.num_cols = n;
  p.objective.assign(n, 1.0);

  p.A.m         = m;
  p.A.n         = n;
  p.A.nz_max    = nz;
  p.A.col_start.assign(n + 1, 0);
  p.A.i.assign(nz, 0);
  p.A.x.assign(nz, 1.0);

  int col = 0;
  int q   = 0;
  for (int i = 0; i < num_supplies; ++i) {
    for (int j = 0; j < num_demands; ++j) {
      p.A.col_start[col] = q;
      p.A.i[q++]         = i;                  // supply row
      p.A.i[q++]         = num_supplies + j;   // demand row
      ++col;
    }
  }
  p.A.col_start[n] = q;

  p.rhs.assign(m, capacity);
  p.lower.assign(n, 0.0);
  p.upper.assign(n, upper_bound);
}

// Build a small LP with all-distinct A entries / objective / rhs / upper bounds.
// color_lower_bounds() returns many distinct row & column sums that exceed the
// (0.5*m, 0.5*n) thresholds in color_graph(), forcing folding() to bail with
// status = -1 immediately.
inline void make_diet_lp(lp_problem_t<int, double>& p)
{
  p.num_rows  = 3;
  p.num_cols  = 3;
  p.objective = {1.0, 2.0, 3.0};

  p.A.m         = 3;
  p.A.n         = 3;
  p.A.nz_max    = 9;
  p.A.col_start = {0, 3, 6, 9};
  p.A.i         = {0, 1, 2, 0, 1, 2, 0, 1, 2};
  p.A.x         = {1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0};

  p.rhs   = {10.0, 11.0, 12.0};
  p.lower = {0.0, 0.0, 0.0};
  p.upper = {5.0, 6.0, 7.0};
}

// Smallest non-degenerate LP -- 1 constraint, 1 variable.
//   minimize  c * x
//   subject to x = b
//              0 <= x <= ub
inline void make_one_by_one_lp(lp_problem_t<int, double>& p,
                               double c  = 2.0,
                               double b  = 3.0,
                               double ub = 5.0)
{
  p.num_rows    = 1;
  p.num_cols    = 1;
  p.objective   = {c};
  p.A.m         = 1;
  p.A.n         = 1;
  p.A.nz_max    = 1;
  p.A.col_start = {0, 1};
  p.A.i         = {0};
  p.A.x         = {1.0};
  p.rhs         = {b};
  p.lower       = {0.0};
  p.upper       = {ub};
}

// Two-variable, two-constraint LP with a nonzero lower bound on x0.
// Useful for triggering the "nonzero lower bound" guard in folding(),
// and as a small standard-form LP for presolve / basis-update tests.
inline void make_two_by_two_with_lower_bound(lp_problem_t<int, double>& p)
{
  p.num_rows    = 2;
  p.num_cols    = 2;
  p.objective   = {1.0, 1.0};
  p.A.m         = 2;
  p.A.n         = 2;
  p.A.nz_max    = 4;
  p.A.col_start = {0, 2, 4};
  p.A.i         = {0, 1, 0, 1};
  p.A.x         = {1.0, 1.0, 1.0, 1.0};
  p.rhs         = {1.0, 1.0};
  p.lower       = {0.5, 0.0};
  p.upper       = {1.0, 1.0};
}

}  // namespace cuopt::linear_programming::dual_simplex::test
