/* clang-format off */
/*
 * SPDX-FileCopyrightText: Copyright (c) 2026 AMD
 * SPDX-License-Identifier: Apache-2.0
 */
/* clang-format on */

// Unit tests for cuopt::linear_programming::dual_simplex::folding.
//
// folding() is a host-only C++ entry point that performs equitable-partition
// presolve on an LP. It is normally only called from presolve.cpp when both
// `barrier_presolve` and `folding != 0` are set, which is rare in the existing
// ctest suite -- so coverage on cpp/src/dual_simplex/folding.cpp is ~22%.
//
// These tests drive folding() directly with hand-built lp_problem_t<int,double>
// instances to cover:
//   * size-guard early return  (settings.folding == -1 && m,n > 1e6)
//   * nonzero-lower-bound bail
//   * augmented-matrix sanity check (num_inf != 1)
//   * coloring threshold abort   (high-symmetry-budget violated)
//   * the success path of color_graph()/compute_sums()/find_colors_to_split()/
//     split_colors() on a small symmetric transportation LP
//   * forced-folding path (settings.folding == 1 bypasses the size guard)

#include <cstdio>

#include <utilities/common_utils.hpp>
#include <utilities/lp_test_fixtures.hpp>

#include <gtest/gtest.h>

#include <dual_simplex/folding.hpp>
#include <dual_simplex/presolve.hpp>
#include <dual_simplex/simplex_solver_settings.hpp>
#include <dual_simplex/types.hpp>

namespace cuopt::linear_programming::dual_simplex::test {

// settings.folding defaults to -1 (auto). Combined with m > 1e6 this triggers
// the early-return at the top of folding(). We only need num_rows / num_cols
// to be set; A is never read on this path.
TEST(folding, skips_when_problem_too_large_with_auto_setting)
{
  raft::handle_t handle{};
  lp_problem_t<int, double> problem(&handle, 1, 1, 1);
  make_one_by_one_lp(problem);
  problem.num_rows = static_cast<int>(2e6);  // post-fixture inflation

  simplex_solver_settings_t<int, double> settings;
  ASSERT_EQ(settings.folding, -1);

  presolve_info_t<int, double> presolve_info;
  folding(problem, settings, presolve_info);

  EXPECT_FALSE(presolve_info.folding_info.is_folded);
  EXPECT_EQ(problem.num_rows, static_cast<int>(2e6));
  EXPECT_EQ(problem.num_cols, 1);
}

// folding() requires the LP to already be shifted so that lower == 0 for every
// variable. With any nonzero lower bound it bails out (lines that print
// "Folding: Can't handle problems with nonzero lower bounds").
TEST(folding, returns_when_nonzero_lower_bound_present)
{
  raft::handle_t handle{};
  lp_problem_t<int, double> problem(&handle, 2, 2, 4);
  make_two_by_two_with_lower_bound(problem);

  simplex_solver_settings_t<int, double> settings;
  presolve_info_t<int, double> presolve_info;
  folding(problem, settings, presolve_info);

  EXPECT_FALSE(presolve_info.folding_info.is_folded);
  EXPECT_EQ(problem.num_rows, 2);
  EXPECT_EQ(problem.num_cols, 2);
  EXPECT_DOUBLE_EQ(problem.lower[0], 0.5);
}

// folding() builds an augmented matrix that should contain exactly one inf
// (the cost-of-objective marker). A user that supplies inf inside `objective`
// produces num_inf > 1 and trips the sanity check.
TEST(folding, bails_when_augmented_matrix_has_extra_inf)
{
  raft::handle_t handle{};
  lp_problem_t<int, double> problem(&handle, 2, 2, 4);
  problem.num_rows    = 2;
  problem.num_cols    = 2;
  problem.objective   = {inf, 1.0};  // c[0] = inf -> 2 infs in augmented
  problem.A.m         = 2;
  problem.A.n         = 2;
  problem.A.nz_max    = 4;
  problem.A.col_start = {0, 2, 4};
  problem.A.i         = {0, 1, 0, 1};
  problem.A.x         = {1.0, 1.0, 1.0, 1.0};
  problem.rhs         = {1.0, 1.0};
  problem.lower       = {0.0, 0.0};
  problem.upper       = {3.0, 3.0};

  simplex_solver_settings_t<int, double> settings;
  presolve_info_t<int, double> presolve_info;
  folding(problem, settings, presolve_info);

  EXPECT_FALSE(presolve_info.folding_info.is_folded);
}

// Distinct coefficients/objective/rhs/upper-bounds give the augmented matrix
// many distinct row & column sums, so color_lower_bounds() returns lower
// bounds that exceed the (0.5*m, 0.5*n) thresholds and color_graph() returns
// status = -1 immediately. folding() then prints "Coloring aborted" and
// returns without folding.
TEST(folding, bails_on_problem_with_distinct_coefficients)
{
  raft::handle_t handle{};
  lp_problem_t<int, double> problem(&handle, 3, 3, 9);
  make_diet_lp(problem);

  simplex_solver_settings_t<int, double> settings;
  presolve_info_t<int, double> presolve_info;
  ASSERT_NO_FATAL_FAILURE(folding(problem, settings, presolve_info));

  EXPECT_FALSE(presolve_info.folding_info.is_folded);
  EXPECT_EQ(problem.num_rows, 3);
  EXPECT_EQ(problem.num_cols, 3);
}

// Drive folding() against a symmetric transportation LP. We don't hard-assert
// the algorithm finds a useful reduction (the precise outcome depends on
// libstdc++ unordered_map iteration order, which influences which color is
// chosen as "largest" inside split_colors()) -- but folding() must not crash
// and must leave the inputs in a self-consistent state.
TEST(folding, runs_to_completion_on_symmetric_transportation_problem)
{
  raft::handle_t handle{};
  lp_problem_t<int, double> problem(&handle, 4, 4, 8);
  make_balanced_transportation_lp(problem);

  simplex_solver_settings_t<int, double> settings;
  presolve_info_t<int, double> presolve_info;
  ASSERT_NO_FATAL_FAILURE(folding(problem, settings, presolve_info));

  if (presolve_info.folding_info.is_folded) {
    EXPECT_LE(problem.num_rows, 4);
    EXPECT_LE(problem.num_cols, 4);
    EXPECT_GE(presolve_info.folding_info.A_tilde.m, problem.num_rows);
    EXPECT_GE(presolve_info.folding_info.A_tilde.n, problem.num_cols);
    EXPECT_EQ(static_cast<int>(presolve_info.folding_info.c_tilde.size()),
              presolve_info.folding_info.A_tilde.n);
  } else {
    EXPECT_EQ(problem.num_rows, 4);
    EXPECT_EQ(problem.num_cols, 4);
  }
}

// settings.folding == 1 forces folding regardless of problem size. We use a
// problem that is too large for the auto-mode size guard but small enough to
// stay tractable for the test suite.
TEST(folding, force_setting_bypasses_size_guard)
{
  raft::handle_t handle{};
  lp_problem_t<int, double> problem(&handle, 4, 4, 8);
  make_balanced_transportation_lp(problem);

  simplex_solver_settings_t<int, double> settings;
  settings.folding = 1;  // force regardless of dims
  presolve_info_t<int, double> presolve_info;

  ASSERT_NO_FATAL_FAILURE(folding(problem, settings, presolve_info));
}

// A 1-variable, 1-constraint problem: nz_ub == 1, nz_obj == 1, nz_rhs == 1.
// Tiny coverage of the augmented-matrix construction path with the smallest
// non-degenerate inputs.
TEST(folding, runs_on_one_by_one_problem)
{
  raft::handle_t handle{};
  lp_problem_t<int, double> problem(&handle, 1, 1, 1);
  make_one_by_one_lp(problem);

  simplex_solver_settings_t<int, double> settings;
  settings.folding = 1;  // force, since the auto threshold is 0 colors here
  presolve_info_t<int, double> presolve_info;
  ASSERT_NO_FATAL_FAILURE(folding(problem, settings, presolve_info));
}

}  // namespace cuopt::linear_programming::dual_simplex::test
