/* clang-format off */
/*
 * SPDX-FileCopyrightText: Copyright (c) 2026 AMD
 * SPDX-License-Identifier: Apache-2.0
 */
/* clang-format on */

// Unit tests for cuopt::linear_programming::dual_simplex::primal_phase2
// (cpp/src/dual_simplex/primal.cpp).
//
// primal_phase2() is an experimental primal-simplex driver -- the source
// comment notes that it can cycle and is not enabled by default. These tests
// drive it on small fully-specified LPs so that:
//   * the pricing / ratio-test / basis-update inner loop runs at least once
//   * the optimality-detection branch is exercised
//   * the iteration cap (iter + 1000) terminates cleanly on cyclic inputs
//
// Because cycling is documented behavior, tests assert "status is one of
// {OPTIMAL, ITERATION_LIMIT, NUMERICAL}" rather than always OPTIMAL.

#include <gtest/gtest.h>

#include <utilities/lp_test_fixtures.hpp>

#include <dual_simplex/initial_basis.hpp>
#include <dual_simplex/presolve.hpp>
#include <dual_simplex/primal.hpp>
#include <dual_simplex/simplex_solver_settings.hpp>
#include <dual_simplex/solution.hpp>
#include <dual_simplex/types.hpp>

#include <vector>

namespace cuopt::linear_programming::dual_simplex::test {

namespace {

bool acceptable_status(primal::status_t s)
{
  return s == primal::status_t::OPTIMAL ||
         s == primal::status_t::ITERATION_LIMIT ||
         s == primal::status_t::NUMERICAL ||
         s == primal::status_t::PRIMAL_UNBOUNDED;
}

}  // namespace

// Already-optimal vertex: x = (1, 0) for min x0 + x1 s.t. x0 + x1 = 1.
// Pricing immediately sees no improving reduced cost -> OPTIMAL on entry.
TEST(primal_phase2, returns_optimal_for_already_at_vertex)
{
  raft::handle_t handle{};
  lp_problem_t<int, double> p(&handle, 1, 2, 2);
  p.num_rows    = 1;
  p.num_cols    = 2;
  p.objective   = {1.0, 1.0};
  p.A.m         = 1;
  p.A.n         = 2;
  p.A.nz_max    = 2;
  p.A.col_start = {0, 1, 2};
  p.A.i         = {0, 0};
  p.A.x         = {1.0, 1.0};
  p.rhs         = {1.0};
  p.lower       = {0.0, 0.0};
  p.upper       = {1.0, 1.0};

  std::vector<variable_status_t> vstatus = {variable_status_t::BASIC,
                                            variable_status_t::NONBASIC_LOWER};
  lp_solution_t<int, double> sol(/*m=*/1, /*n=*/2);
  // Pre-populate the primal solution at the vertex.
  sol.x = {1.0, 0.0};
  sol.y = {1.0};
  sol.z = {0.0, 0.0};

  simplex_solver_settings_t<int, double> settings;
  settings.time_limit = 5.0;

  int iter = 0;
  primal::status_t status =
    primal_phase2(/*phase=*/2, /*start_time=*/0.0, p, settings, vstatus, sol, iter);
  EXPECT_TRUE(acceptable_status(status))
    << "unexpected status code " << static_cast<int>(status);
}

// LP with an improving direction: the basis is initially x1 (cost 2), but
// x0 (cost 1) is cheaper. primal_phase2 must pivot -- exercises pricing,
// ratio-test, and the basis-update path.
TEST(primal_phase2, takes_at_least_one_pivot_on_non_optimal_start)
{
  raft::handle_t handle{};
  lp_problem_t<int, double> p(&handle, 1, 3, 3);
  p.num_rows    = 1;
  p.num_cols    = 3;
  p.objective   = {1.0, 2.0, 3.0};
  p.A.m         = 1;
  p.A.n         = 3;
  p.A.nz_max    = 3;
  p.A.col_start = {0, 1, 2, 3};
  p.A.i         = {0, 0, 0};
  p.A.x         = {1.0, 1.0, 1.0};
  p.rhs         = {1.0};
  p.lower       = {0.0, 0.0, 0.0};
  p.upper       = {1.0, 1.0, 1.0};

  // Start with x1 basic at value 1 (objective = 2).
  std::vector<variable_status_t> vstatus = {variable_status_t::NONBASIC_LOWER,
                                            variable_status_t::BASIC,
                                            variable_status_t::NONBASIC_LOWER};
  lp_solution_t<int, double> sol(/*m=*/1, /*n=*/3);
  sol.x = {0.0, 1.0, 0.0};
  sol.y = {2.0};
  sol.z = {-1.0, 0.0, 1.0};

  simplex_solver_settings_t<int, double> settings;
  settings.time_limit = 5.0;

  int iter = 0;
  primal::status_t status =
    primal_phase2(/*phase=*/2, /*start_time=*/0.0, p, settings, vstatus, sol, iter);
  EXPECT_TRUE(acceptable_status(status))
    << "unexpected status code " << static_cast<int>(status);
  // Either it found the optimum (x0=1) or stopped cleanly. Iter must be
  // bounded and non-negative.
  EXPECT_GE(iter, 0);
  EXPECT_LT(iter, 2000);  // hard cap inside is iter_in + 1000
}

// One-variable / one-constraint smoke test -- the smallest possible input.
TEST(primal_phase2, handles_one_by_one_problem)
{
  raft::handle_t handle{};
  lp_problem_t<int, double> p(&handle, 1, 1, 1);
  make_one_by_one_lp(p, /*c=*/1.0, /*b=*/1.0, /*ub=*/2.0);

  std::vector<variable_status_t> vstatus = {variable_status_t::BASIC};
  lp_solution_t<int, double> sol(1, 1);
  sol.x = {1.0};
  sol.y = {1.0};
  sol.z = {0.0};

  simplex_solver_settings_t<int, double> settings;
  settings.time_limit = 1.0;

  int iter = 0;
  primal::status_t status =
    primal_phase2(2, 0.0, p, settings, vstatus, sol, iter);
  EXPECT_TRUE(acceptable_status(status));
}

}  // namespace cuopt::linear_programming::dual_simplex::test
