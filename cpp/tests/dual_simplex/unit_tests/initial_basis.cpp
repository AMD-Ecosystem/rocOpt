/* clang-format off */
/*
 * SPDX-FileCopyrightText: Copyright (c) 2026 AMD
 * SPDX-License-Identifier: Apache-2.0
 */
/* clang-format on */

// Unit tests for cuopt::linear_programming::dual_simplex::initial_basis_selection
// (cpp/src/dual_simplex/initial_basis.cpp).
//
// initial_basis_selection() picks an initial basis for the dual simplex solver
// by combining find_singletons() (when settings.eliminate_singletons is true)
// and right_looking_lu_row_permutation_only(). Currently 0% line coverage
// because no existing unit test calls it directly.
//
// Output contract:
//   - vstatus[k]  becomes BASIC for the chosen basis columns and stays at its
//                 input value otherwise (typically NONBASIC_*).
//   - dependent_rows lists rows beyond the rank of the candidate set.
//   - return value = pivot count (rank).

#include <gtest/gtest.h>

#include <utilities/lp_test_fixtures.hpp>

#include <dual_simplex/initial_basis.hpp>
#include <dual_simplex/presolve.hpp>
#include <dual_simplex/simplex_solver_settings.hpp>
#include <dual_simplex/types.hpp>

#include <numeric>
#include <vector>

namespace cuopt::linear_programming::dual_simplex::test {

namespace {

int count_basic(const std::vector<variable_status_t>& vstatus)
{
  int n = 0;
  for (auto v : vstatus) {
    if (v == variable_status_t::BASIC) ++n;
  }
  return n;
}

}  // namespace

// Identity-style LP: A is 3x3 identity, every column should be picked into
// the basis -> rank = 3.
TEST(initial_basis_selection, picks_identity_columns_into_full_rank_basis)
{
  raft::handle_t handle{};
  lp_problem_t<int, double> p(&handle, 3, 3, 3);
  p.num_rows    = 3;
  p.num_cols    = 3;
  p.objective   = {1.0, 1.0, 1.0};
  p.A.m         = 3;
  p.A.n         = 3;
  p.A.nz_max    = 3;
  p.A.col_start = {0, 1, 2, 3};
  p.A.i         = {0, 1, 2};
  p.A.x         = {1.0, 1.0, 1.0};
  p.rhs         = {1.0, 1.0, 1.0};
  p.lower       = {0.0, 0.0, 0.0};
  p.upper       = {inf, inf, inf};

  simplex_solver_settings_t<int, double> settings;
  std::vector<int> candidate_columns(3);
  std::iota(candidate_columns.begin(), candidate_columns.end(), 0);

  std::vector<variable_status_t> vstatus(3, variable_status_t::NONBASIC_LOWER);
  std::vector<int> dependent_rows;

  int rank = initial_basis_selection(p, settings, candidate_columns,
                                     /*start_time=*/0.0, vstatus, dependent_rows);
  EXPECT_EQ(rank, 3);
  EXPECT_EQ(count_basic(vstatus), 3);
  EXPECT_TRUE(dependent_rows.empty());
}

// LP with a redundant column: 3 rows, 4 cols; A = [I | e_0]. Rank = 3,
// only 3 of the 4 candidates can become BASIC. The duplicate of column 0
// should be left non-BASIC (its vstatus untouched).
TEST(initial_basis_selection, leaves_redundant_column_non_basic)
{
  raft::handle_t handle{};
  lp_problem_t<int, double> p(&handle, 3, 4, 4);
  p.num_rows    = 3;
  p.num_cols    = 4;
  p.objective   = {1.0, 1.0, 1.0, 1.0};
  p.A.m         = 3;
  p.A.n         = 4;
  p.A.nz_max    = 4;
  p.A.col_start = {0, 1, 2, 3, 4};
  p.A.i         = {0, 1, 2, 0};   // last column duplicates column 0
  p.A.x         = {1.0, 1.0, 1.0, 1.0};
  p.rhs         = {1.0, 1.0, 1.0};
  p.lower       = {0.0, 0.0, 0.0, 0.0};
  p.upper       = {inf, inf, inf, inf};

  simplex_solver_settings_t<int, double> settings;
  std::vector<int> candidate_columns = {0, 1, 2, 3};
  std::vector<variable_status_t> vstatus(4, variable_status_t::NONBASIC_LOWER);
  std::vector<int> dependent_rows;

  int rank = initial_basis_selection(p, settings, candidate_columns, 0.0,
                                     vstatus, dependent_rows);
  EXPECT_EQ(rank, 3);
  EXPECT_EQ(count_basic(vstatus), 3);
}

// Subset of candidates: only columns {0, 2} are eligible. A is full 3x3 ID,
// so the basis can include at most these 2 + slack/repair handled outside.
// Expect rank == 2.
TEST(initial_basis_selection, restricts_to_provided_candidate_set)
{
  raft::handle_t handle{};
  lp_problem_t<int, double> p(&handle, 3, 3, 3);
  p.num_rows    = 3;
  p.num_cols    = 3;
  p.objective   = {1.0, 1.0, 1.0};
  p.A.m         = 3;
  p.A.n         = 3;
  p.A.nz_max    = 3;
  p.A.col_start = {0, 1, 2, 3};
  p.A.i         = {0, 1, 2};
  p.A.x         = {1.0, 1.0, 1.0};
  p.rhs         = {1.0, 1.0, 1.0};
  p.lower       = {0.0, 0.0, 0.0};
  p.upper       = {inf, inf, inf};

  simplex_solver_settings_t<int, double> settings;
  std::vector<int> candidate_columns = {0, 2};  // skip column 1
  std::vector<variable_status_t> vstatus(2, variable_status_t::NONBASIC_LOWER);
  std::vector<int> dependent_rows;

  int rank = initial_basis_selection(p, settings, candidate_columns, 0.0,
                                     vstatus, dependent_rows);
  EXPECT_EQ(rank, 2);
  EXPECT_EQ(count_basic(vstatus), 2);
  EXPECT_FALSE(dependent_rows.empty()) << "row 1 must show up as dependent";
}

// Disable singleton elimination to drive the alternative pre-LU path.
// Same identity LP; result must still be rank 3.
TEST(initial_basis_selection, with_eliminate_singletons_disabled)
{
  raft::handle_t handle{};
  lp_problem_t<int, double> p(&handle, 3, 3, 3);
  p.num_rows    = 3;
  p.num_cols    = 3;
  p.objective   = {1.0, 1.0, 1.0};
  p.A.m         = 3;
  p.A.n         = 3;
  p.A.nz_max    = 3;
  p.A.col_start = {0, 1, 2, 3};
  p.A.i         = {0, 1, 2};
  p.A.x         = {1.0, 1.0, 1.0};
  p.rhs         = {1.0, 1.0, 1.0};
  p.lower       = {0.0, 0.0, 0.0};
  p.upper       = {inf, inf, inf};

  simplex_solver_settings_t<int, double> settings;
  settings.eliminate_singletons = 0;  // exercise the no-singleton-presolve branch

  std::vector<int> candidate_columns = {0, 1, 2};
  std::vector<variable_status_t> vstatus(3, variable_status_t::NONBASIC_LOWER);
  std::vector<int> dependent_rows;

  int rank = initial_basis_selection(p, settings, candidate_columns, 0.0,
                                     vstatus, dependent_rows);
  EXPECT_EQ(rank, 3);
  EXPECT_EQ(count_basic(vstatus), 3);
}

// Dense small LP: the diet fixture A = 3x3 with entries [1..9] column-major.
// That matrix is rank-deficient (row3 = 2*row2 - row1, det A = 0), so
// initial_basis_selection should detect rank 2 and mark exactly 2 columns
// basic. This exercises the rank-deficient code path on a dense input.
TEST(initial_basis_selection, on_dense_rank_deficient_lp_detects_rank_two)
{
  raft::handle_t handle{};
  lp_problem_t<int, double> p(&handle, 3, 3, 9);
  make_diet_lp(p);

  simplex_solver_settings_t<int, double> settings;
  std::vector<int> candidate_columns = {0, 1, 2};
  std::vector<variable_status_t> vstatus(3, variable_status_t::NONBASIC_LOWER);
  std::vector<int> dependent_rows;

  int rank = initial_basis_selection(p, settings, candidate_columns, 0.0,
                                     vstatus, dependent_rows);
  EXPECT_EQ(rank, 2);
  EXPECT_EQ(count_basic(vstatus), 2);
  EXPECT_FALSE(dependent_rows.empty());
}

// Degenerate 1x1 problem: the smallest non-trivial input.
TEST(initial_basis_selection, on_one_by_one_problem)
{
  raft::handle_t handle{};
  lp_problem_t<int, double> p(&handle, 1, 1, 1);
  make_one_by_one_lp(p);

  simplex_solver_settings_t<int, double> settings;
  std::vector<int> candidate_columns = {0};
  std::vector<variable_status_t> vstatus(1, variable_status_t::NONBASIC_LOWER);
  std::vector<int> dependent_rows;

  int rank = initial_basis_selection(p, settings, candidate_columns, 0.0,
                                     vstatus, dependent_rows);
  EXPECT_EQ(rank, 1);
  EXPECT_EQ(vstatus[0], variable_status_t::BASIC);
}

}  // namespace cuopt::linear_programming::dual_simplex::test
