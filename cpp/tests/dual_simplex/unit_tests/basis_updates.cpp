/* clang-format off */
/*
 * SPDX-FileCopyrightText: Copyright (c) 2026 AMD
 * SPDX-License-Identifier: Apache-2.0
 */
/* clang-format on */

// Unit tests for cuopt::linear_programming::dual_simplex::basis_update_t and
// basis_update_mpf_t (cpp/src/dual_simplex/basis_updates.cpp).
//
// These two classes implement Forrest-Tomlin (FT) and middle-product-form (MPF)
// rank-1 updates to an LU factorization of a basis matrix B. They are normally
// only exercised through the inner loop of the simplex solver, so the existing
// ctest suite touches a small slice (~38% line). These tests construct L and U
// directly (lower- and upper-triangular CSC matrices) and round-trip the
// solve/update API.
//
// The reference factorization throughout is:
//
//     L = | 1 0 |     U = | 3 4 |     P = identity      B = L*U = | 3  4 |
//         | 2 1 |         | 0 5 |                                  | 6 13 |
//
// |B| = 15. B^{-1} = (1/15) * [[ 13, -4 ], [ -6,  3 ]].

#include <gtest/gtest.h>

#include <dual_simplex/basis_updates.hpp>
#include <dual_simplex/sparse_matrix.hpp>
#include <dual_simplex/sparse_vector.hpp>

#include <cmath>
#include <vector>

namespace cuopt::linear_programming::dual_simplex::test {

namespace {

using csc_d  = csc_matrix_t<int, double>;
using svec_d = sparse_vector_t<int, double>;

// L = [[1,0],[2,1]] in CSC: cols of L.
// col 0: rows {0,1} vals {1,2}; col 1: row {1} val {1}.
void make_L(csc_d& L)
{
  L.resize(2, 2, 3);
  L.col_start = {0, 2, 3};
  L.i         = {0, 1, 1};
  L.x         = {1.0, 2.0, 1.0};
}

// U = [[3,4],[0,5]] in CSC.
// col 0: row {0} val {3}; col 1: rows {0,1} vals {4,5}.
void make_U(csc_d& U)
{
  U.resize(2, 2, 3);
  U.col_start = {0, 1, 3};
  U.i         = {0, 0, 1};
  U.x         = {3.0, 4.0, 5.0};
}

}  // namespace

// ----------------------------------------------------------------------------
// basis_update_t (Forrest-Tomlin)
// ----------------------------------------------------------------------------

TEST(basis_update_t, b_solve_dense_returns_inverse_times_rhs)
{
  csc_d L(0, 0, 0);
  csc_d U(0, 0, 0);
  make_L(L);
  make_U(U);
  std::vector<int> p = {0, 1};

  basis_update_t<int, double> bu(L, U, p);

  // B*x = b, with b chosen so x = [1, 0] (i.e. column 0 of B = [3, 6]).
  std::vector<double> rhs = {3.0, 6.0};
  std::vector<double> sol(2, 0.0);
  EXPECT_EQ(bu.b_solve(rhs, sol), 0);
  EXPECT_NEAR(sol[0], 1.0, 1e-12);
  EXPECT_NEAR(sol[1], 0.0, 1e-12);

  // b = column 1 of B = [4, 13] -> x = [0, 1].
  rhs = {4.0, 13.0};
  EXPECT_EQ(bu.b_solve(rhs, sol), 0);
  EXPECT_NEAR(sol[0], 0.0, 1e-12);
  EXPECT_NEAR(sol[1], 1.0, 1e-12);
}

TEST(basis_update_t, b_solve_dense_with_Lsol_output)
{
  csc_d L(0, 0, 0);
  csc_d U(0, 0, 0);
  make_L(L);
  make_U(U);
  std::vector<int> p = {0, 1};

  basis_update_t<int, double> bu(L, U, p);
  std::vector<double> rhs  = {3.0, 6.0};
  std::vector<double> sol(2, 0.0);
  std::vector<double> Lsol(2, 0.0);
  EXPECT_EQ(bu.b_solve(rhs, sol, Lsol), 0);
  EXPECT_NEAR(sol[0], 1.0, 1e-12);
  EXPECT_NEAR(sol[1], 0.0, 1e-12);
  // Lsol satisfies L * Lsol = P*b = [3,6]. From L row 0: Lsol[0] = 3.
  // Row 1: 2*Lsol[0] + Lsol[1] = 6 -> Lsol[1] = 0.
  EXPECT_NEAR(Lsol[0], 3.0, 1e-12);
  EXPECT_NEAR(Lsol[1], 0.0, 1e-12);
}

TEST(basis_update_t, b_transpose_solve_dense_gives_left_inverse)
{
  csc_d L(0, 0, 0);
  csc_d U(0, 0, 0);
  make_L(L);
  make_U(U);
  std::vector<int> p = {0, 1};

  basis_update_t<int, double> bu(L, U, p);
  // B^T*y = c with c = column 0 of B^T = [3, 4] -> y = [1, 0].
  std::vector<double> rhs = {3.0, 4.0};
  std::vector<double> sol(2, 0.0);
  EXPECT_EQ(bu.b_transpose_solve(rhs, sol), 0);
  EXPECT_NEAR(sol[0], 1.0, 1e-12);
  EXPECT_NEAR(sol[1], 0.0, 1e-12);
}

TEST(basis_update_t, l_solve_and_l_transpose_solve_round_trip)
{
  csc_d L(0, 0, 0);
  csc_d U(0, 0, 0);
  make_L(L);
  make_U(U);
  std::vector<int> p = {0, 1};

  basis_update_t<int, double> bu(L, U, p);

  // Forward: L*x = [1, 0] -> x[0]=1, x[1]=-2 (since 2*1 + x[1] = 0).
  std::vector<double> rhs = {1.0, 0.0};
  EXPECT_EQ(bu.l_solve(rhs), 0);
  EXPECT_NEAR(rhs[0], 1.0, 1e-12);
  EXPECT_NEAR(rhs[1], -2.0, 1e-12);

  // L^T = [[1,2],[0,1]] is upper triangular. L^T * x = [1, 0] -> x[1]=0, x[0]=1.
  std::vector<double> rhs2 = {1.0, 0.0};
  EXPECT_EQ(bu.l_transpose_solve(rhs2), 0);
  EXPECT_NEAR(rhs2[0], 1.0, 1e-12);
  EXPECT_NEAR(rhs2[1], 0.0, 1e-12);
}

TEST(basis_update_t, u_solve_and_u_transpose_solve_dense)
{
  csc_d L(0, 0, 0);
  csc_d U(0, 0, 0);
  make_L(L);
  make_U(U);
  std::vector<int> p = {0, 1};

  basis_update_t<int, double> bu(L, U, p);

  // U*x = [3, 5]. Backward sub: x[1] = 5/5 = 1; x[0] = (3 - 4*1)/3 = -1/3.
  std::vector<double> rhs = {3.0, 5.0};
  EXPECT_EQ(bu.u_solve(rhs), 0);
  EXPECT_NEAR(rhs[0], -1.0 / 3.0, 1e-12);
  EXPECT_NEAR(rhs[1], 1.0, 1e-12);

  // U^T*x = [3, 4]. Forward sub: x[0] = 3/3 = 1; x[1] = (4 - 4*1)/5 = 0.
  std::vector<double> rhs2 = {3.0, 4.0};
  EXPECT_EQ(bu.u_transpose_solve(rhs2), 0);
  EXPECT_NEAR(rhs2[0], 1.0, 1e-12);
  EXPECT_NEAR(rhs2[1], 0.0, 1e-12);
}

TEST(basis_update_t, multiply_lu_rebuilds_basis)
{
  csc_d L(0, 0, 0);
  csc_d U(0, 0, 0);
  make_L(L);
  make_U(U);
  std::vector<int> p = {0, 1};
  basis_update_t<int, double> bu(L, U, p);

  // multiply_lu() requires B to already be sized to (m, m); it asserts
  // out.m == m and only resizes col_start internally.
  csc_d B(2, 2, 4);
  EXPECT_EQ(bu.multiply_lu(B), 0);
  // Recovered B = P*L*U  with P = I -> B = L*U = [[3,4],[6,13]].
  ASSERT_EQ(B.m, 2);
  ASSERT_EQ(B.n, 2);

  auto get = [&](int row, int col) {
    for (int q = B.col_start[col]; q < B.col_start[col + 1]; ++q) {
      if (B.i[q] == row) return B.x[q];
    }
    return 0.0;
  };
  EXPECT_NEAR(get(0, 0), 3.0, 1e-12);
  EXPECT_NEAR(get(1, 0), 6.0, 1e-12);
  EXPECT_NEAR(get(0, 1), 4.0, 1e-12);
  EXPECT_NEAR(get(1, 1), 13.0, 1e-12);
}

TEST(basis_update_t, num_updates_starts_at_zero_and_row_permutation_matches_init)
{
  csc_d L(0, 0, 0);
  csc_d U(0, 0, 0);
  make_L(L);
  make_U(U);
  std::vector<int> p = {0, 1};
  basis_update_t<int, double> bu(L, U, p);
  EXPECT_EQ(bu.num_updates(), 0);
  EXPECT_EQ(bu.row_permutation(), p);
}

TEST(basis_update_t, reset_replaces_factorization_in_place)
{
  csc_d L(0, 0, 0);
  csc_d U(0, 0, 0);
  make_L(L);
  make_U(U);
  std::vector<int> p = {0, 1};
  basis_update_t<int, double> bu(L, U, p);

  // Reset to a different factorization: 1x1 with value 7.
  csc_d L2(1, 1, 1);
  L2.col_start = {0, 1};
  L2.i         = {0};
  L2.x         = {1.0};
  csc_d U2(1, 1, 1);
  U2.col_start = {0, 1};
  U2.i         = {0};
  U2.x         = {7.0};
  std::vector<int> p2 = {0};

  EXPECT_EQ(bu.reset(L2, U2, p2), 0);
  EXPECT_EQ(bu.num_updates(), 0);
  EXPECT_EQ(bu.row_permutation(), p2);

  // B = [[7]]; B*x = [14] -> x = [2].
  std::vector<double> rhs = {14.0};
  std::vector<double> sol(1, 0.0);
  EXPECT_EQ(bu.b_solve(rhs, sol), 0);
  EXPECT_NEAR(sol[0], 2.0, 1e-12);
}

TEST(basis_update_t, sparse_b_solve_matches_dense)
{
  csc_d L(0, 0, 0);
  csc_d U(0, 0, 0);
  make_L(L);
  make_U(U);
  std::vector<int> p = {0, 1};
  basis_update_t<int, double> bu(L, U, p);

  // Sparse rhs = [3, 6]: indices {0, 1}, values {3, 6}.
  svec_d rhs;
  rhs.n = 2;
  rhs.i = {0, 1};
  rhs.x = {3.0, 6.0};
  svec_d sol;
  EXPECT_EQ(bu.b_solve(rhs, sol), 0);

  // Recover dense from sparse.
  std::vector<double> dense(2, 0.0);
  for (size_t k = 0; k < sol.i.size(); ++k) dense[sol.i[k]] = sol.x[k];
  EXPECT_NEAR(dense[0], 1.0, 1e-12);
  EXPECT_NEAR(dense[1], 0.0, 1e-12);
}

// ----------------------------------------------------------------------------
// basis_update_mpf_t (Middle Product Form)
// ----------------------------------------------------------------------------

TEST(basis_update_mpf_t, dense_b_solve_matches_explicit_inverse)
{
  csc_d L(0, 0, 0);
  csc_d U(0, 0, 0);
  make_L(L);
  make_U(U);
  std::vector<int> p = {0, 1};

  basis_update_mpf_t<int, double> bu(L, U, p, /*refactor_frequency=*/100);

  std::vector<double> rhs = {3.0, 6.0};
  std::vector<double> sol(2, 0.0);
  EXPECT_EQ(bu.b_solve(rhs, sol), 0);
  EXPECT_NEAR(sol[0], 1.0, 1e-12);
  EXPECT_NEAR(sol[1], 0.0, 1e-12);
}

TEST(basis_update_mpf_t, b_solve_with_optional_Lsol_output)
{
  csc_d L(0, 0, 0);
  csc_d U(0, 0, 0);
  make_L(L);
  make_U(U);
  std::vector<int> p = {0, 1};
  basis_update_mpf_t<int, double> bu(L, U, p, 100);

  std::vector<double> rhs  = {3.0, 6.0};
  std::vector<double> sol(2, 0.0);
  std::vector<double> Lsol(2, 0.0);
  EXPECT_EQ(bu.b_solve(rhs, sol, Lsol, /*need_Lsol=*/true), 0);
  EXPECT_NEAR(sol[0], 1.0, 1e-12);
  EXPECT_NEAR(sol[1], 0.0, 1e-12);
  EXPECT_NEAR(Lsol[0], 3.0, 1e-12);
  EXPECT_NEAR(Lsol[1], 0.0, 1e-12);
}

TEST(basis_update_mpf_t, b_transpose_solve_dense)
{
  csc_d L(0, 0, 0);
  csc_d U(0, 0, 0);
  make_L(L);
  make_U(U);
  std::vector<int> p = {0, 1};
  basis_update_mpf_t<int, double> bu(L, U, p, 100);

  std::vector<double> rhs = {3.0, 4.0};
  std::vector<double> sol(2, 0.0);
  EXPECT_EQ(bu.b_transpose_solve(rhs, sol), 0);
  EXPECT_NEAR(sol[0], 1.0, 1e-12);
  EXPECT_NEAR(sol[1], 0.0, 1e-12);
}

TEST(basis_update_mpf_t, b_transpose_solve_with_optional_UTsol_output)
{
  csc_d L(0, 0, 0);
  csc_d U(0, 0, 0);
  make_L(L);
  make_U(U);
  std::vector<int> p = {0, 1};
  basis_update_mpf_t<int, double> bu(L, U, p, 100);

  std::vector<double> rhs   = {3.0, 4.0};
  std::vector<double> sol(2, 0.0);
  std::vector<double> UTsol(2, 0.0);
  EXPECT_EQ(bu.b_transpose_solve(rhs, sol, UTsol), 0);
  EXPECT_NEAR(sol[0], 1.0, 1e-12);
  EXPECT_NEAR(sol[1], 0.0, 1e-12);
}

TEST(basis_update_mpf_t, l_u_dense_solve_round_trip)
{
  csc_d L(0, 0, 0);
  csc_d U(0, 0, 0);
  make_L(L);
  make_U(U);
  std::vector<int> p = {0, 1};
  basis_update_mpf_t<int, double> bu(L, U, p, 100);

  std::vector<double> v = {1.0, 0.0};
  EXPECT_EQ(bu.l_solve(v), 0);
  EXPECT_NEAR(v[0], 1.0, 1e-12);
  EXPECT_NEAR(v[1], -2.0, 1e-12);

  std::vector<double> v2 = {1.0, 0.0};
  EXPECT_EQ(bu.l_transpose_solve(v2), 0);
  EXPECT_NEAR(v2[0], 1.0, 1e-12);
  EXPECT_NEAR(v2[1], 0.0, 1e-12);

  std::vector<double> v3 = {3.0, 5.0};
  EXPECT_EQ(bu.u_solve(v3), 0);
  EXPECT_NEAR(v3[1], 1.0, 1e-12);
  EXPECT_NEAR(v3[0], -1.0 / 3.0, 1e-12);

  std::vector<double> v4 = {3.0, 4.0};
  EXPECT_EQ(bu.u_transpose_solve(v4), 0);
  EXPECT_NEAR(v4[0], 1.0, 1e-12);
  EXPECT_NEAR(v4[1], 0.0, 1e-12);
}

TEST(basis_update_mpf_t, multiply_lu_rebuilds_basis)
{
  csc_d L(0, 0, 0);
  csc_d U(0, 0, 0);
  make_L(L);
  make_U(U);
  std::vector<int> p = {0, 1};
  basis_update_mpf_t<int, double> bu(L, U, p, 100);

  csc_d B(0, 0, 0);
  bu.multiply_lu(B);
  ASSERT_EQ(B.m, 2);
  ASSERT_EQ(B.n, 2);

  auto get = [&](int row, int col) {
    for (int q = B.col_start[col]; q < B.col_start[col + 1]; ++q) {
      if (B.i[q] == row) return B.x[q];
    }
    return 0.0;
  };
  EXPECT_NEAR(get(0, 0), 3.0, 1e-12);
  EXPECT_NEAR(get(1, 0), 6.0, 1e-12);
  EXPECT_NEAR(get(0, 1), 4.0, 1e-12);
  EXPECT_NEAR(get(1, 1), 13.0, 1e-12);
}

TEST(basis_update_mpf_t, default_constructor_then_resize_then_reset)
{
  // Exercise the default n-only ctor + resize() path used elsewhere.
  basis_update_mpf_t<int, double> bu(/*n=*/3, /*refactor_frequency=*/50);
  EXPECT_EQ(bu.num_updates(), 0);

  bu.resize(2);
  EXPECT_EQ(bu.num_updates(), 0);

  csc_d L(0, 0, 0);
  csc_d U(0, 0, 0);
  make_L(L);
  make_U(U);
  std::vector<int> p = {0, 1};

  EXPECT_EQ(bu.reset(L, U, p), 0);
  EXPECT_EQ(bu.num_updates(), 0);
  EXPECT_EQ(bu.row_permutation(), p);

  // After reset() the factorization is the L,U pair -> b_solve must work.
  std::vector<double> rhs = {3.0, 6.0};
  std::vector<double> sol(2, 0.0);
  EXPECT_EQ(bu.b_solve(rhs, sol), 0);
  EXPECT_NEAR(sol[0], 1.0, 1e-12);
  EXPECT_NEAR(sol[1], 0.0, 1e-12);
}

TEST(basis_update_mpf_t, reset_stats_and_print_stats_smoke)
{
  csc_d L(0, 0, 0);
  csc_d U(0, 0, 0);
  make_L(L);
  make_U(U);
  std::vector<int> p = {0, 1};
  basis_update_mpf_t<int, double> bu(L, U, p, 100);

  // Drive a solve so statistics counters are non-zero.
  std::vector<double> rhs = {3.0, 6.0};
  std::vector<double> sol(2, 0.0);
  ASSERT_EQ(bu.b_solve(rhs, sol), 0);

  testing::internal::CaptureStdout();
  bu.print_stats();
  std::string out = testing::internal::GetCapturedStdout();
  // print_stats() emits 8 percentage lines.
  EXPECT_NE(out.find("sparse L"), std::string::npos);
  EXPECT_NE(out.find("dense  U"), std::string::npos);

  bu.reset_stats();  // no return value to assert; just verify it doesn't crash
}

TEST(basis_update_mpf_t, estimate_solution_density_tracks_call_count)
{
  basis_update_mpf_t<int, double> bu(/*n=*/10, /*refactor_frequency=*/50);
  int num_calls = 0;
  bool use_hyper = false;
  // First call: average_growth = max(1, 0/0) but division by zero is masked
  // by the max(1.0, ...) clamp. predicted_nz = rhs_nz * 1 = rhs_nz.
  double pred = bu.estimate_solution_density(/*rhs_nz=*/2.0, /*sum=*/0.0,
                                             num_calls, use_hyper);
  EXPECT_DOUBLE_EQ(pred, 2.0);
  EXPECT_EQ(num_calls, 1);
  // 2 / 10 = 0.2, threshold 0.05 -> NOT hypersparse.
  EXPECT_FALSE(use_hyper);

  // High density -> not hypersparse.
  pred = bu.estimate_solution_density(8.0, 5.0, num_calls, use_hyper);
  EXPECT_EQ(num_calls, 2);
  EXPECT_FALSE(use_hyper);

  // Very low density -> hypersparse.
  num_calls = 0;
  pred = bu.estimate_solution_density(0.1, 0.0, num_calls, use_hyper);
  EXPECT_TRUE(use_hyper);
}

}  // namespace cuopt::linear_programming::dual_simplex::test
