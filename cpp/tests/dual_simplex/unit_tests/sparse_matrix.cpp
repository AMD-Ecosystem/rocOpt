/* clang-format off */
/*
 * SPDX-FileCopyrightText: Copyright (c) 2026 AMD
 * SPDX-License-Identifier: Apache-2.0
 */
/* clang-format on */

// Unit tests for cuopt::linear_programming::dual_simplex::sparse_matrix.
//
// sparse_matrix.cpp implements a host-only CSC/CSR sparse linear-algebra
// kernel set (matrix construction, conversion, transpose, permutation,
// multiplication, addition, vector products, hashing, IO). Most of these
// kernels are reachable from the LP solver only along narrow code paths
// (folding, basis updates, presolve), so existing ctest coverage of
// sparse_matrix.cpp is ~36% line / ~36% branch.
//
// These tests exercise each public operation directly with hand-built
// matrices whose contents we know in closed form, so we can assert on the
// numerical output rather than just "it didn't crash".
//
// The reference matrix used throughout most tests is:
//
//     A = | 1.0  0.0  2.0  0.0 |
//         | 0.0 -3.0  0.0  4.0 |     (3 rows x 4 cols, 6 nonzeros)
//         | 5.0  0.0  6.0  0.0 |
//
// CSC: col_start = [0,2,3,5,6], i = [0,2,1,0,2,1], x = [1,5,-3,2,6,4].

#include <gtest/gtest.h>

#include <dual_simplex/sparse_matrix.hpp>
#include <dual_simplex/sparse_vector.hpp>

#include <algorithm>
#include <cstdio>
#include <string>
#include <vector>

namespace cuopt::linear_programming::dual_simplex::test {

namespace {

using csc_d   = csc_matrix_t<int, double>;
using csr_d   = csr_matrix_t<int, double>;
using svec_d  = sparse_vector_t<int, double>;

// Populate `A` with the canonical 3x4 reference matrix shown above.
void make_reference_matrix(csc_d& A)
{
  A.resize(3, 4, 6);
  A.col_start = {0, 2, 3, 5, 6};
  A.i         = {0, 2, 1, 0, 2, 1};
  A.x         = {1.0, 5.0, -3.0, 2.0, 6.0, 4.0};
}

// Build a 3x3 diagonal matrix with values {a, b, c} on the diagonal.
void make_diag3(csc_d& A, double a, double b, double c)
{
  A.resize(3, 3, 3);
  A.col_start = {0, 1, 2, 3};
  A.i         = {0, 1, 2};
  A.x         = {a, b, c};
}

// Read a single (i, j) entry from a CSC matrix; returns 0 if absent.
double get(const csc_d& A, int row, int col)
{
  for (int p = A.col_start[col]; p < A.col_start[col + 1]; ++p) {
    if (A.i[p] == row) { return A.x[p]; }
  }
  return 0.0;
}

}  // namespace

// ----------------------------------------------------------------------------
// Construction / sizing
// ----------------------------------------------------------------------------

TEST(sparse_matrix, construction_sets_dimensions_and_buffer_sizes)
{
  csc_d A(3, 4, 6);
  EXPECT_EQ(A.m, 3);
  EXPECT_EQ(A.n, 4);
  EXPECT_EQ(A.nz_max, 6);
  EXPECT_EQ(static_cast<int>(A.col_start.size()), 5);  // n + 1
  EXPECT_EQ(static_cast<int>(A.i.size()), 6);
  EXPECT_EQ(static_cast<int>(A.x.size()), 6);
}

TEST(sparse_matrix, resize_updates_dimensions_and_buffers)
{
  csc_d A(1, 1, 1);
  A.resize(5, 7, 12);
  EXPECT_EQ(A.m, 5);
  EXPECT_EQ(A.n, 7);
  EXPECT_EQ(A.nz_max, 12);
  EXPECT_EQ(static_cast<int>(A.col_start.size()), 8);
  EXPECT_EQ(static_cast<int>(A.i.size()), 12);
  EXPECT_EQ(static_cast<int>(A.x.size()), 12);
}

TEST(sparse_matrix, reallocate_changes_only_value_buffers)
{
  csc_d A(3, 4, 6);
  A.col_start = {0, 2, 3, 5, 6};
  A.reallocate(20);
  EXPECT_EQ(A.nz_max, 20);
  EXPECT_EQ(static_cast<int>(A.i.size()), 20);
  EXPECT_EQ(static_cast<int>(A.x.size()), 20);
  EXPECT_EQ(static_cast<int>(A.col_start.size()), 5);  // unchanged
  EXPECT_EQ(A.col_start[4], 6);                        // unchanged
}

TEST(sparse_matrix, nnz_returns_col_start_n)
{
  csc_d A(3, 4, 6);
  make_reference_matrix(A);
  EXPECT_EQ(A.nnz(), 6);
}

// ----------------------------------------------------------------------------
// COO -> CSC, CSC <-> CSR, transpose, cumulative_sum
// ----------------------------------------------------------------------------

TEST(sparse_matrix, coo_to_csc_round_trip)
{
  // Provide COO entries in arbitrary order; coo_to_csc() should bucket them
  // by column and produce the canonical reference CSC.
  const std::vector<int> Ai    = {2, 0, 1, 0, 2, 1};
  const std::vector<int> Aj    = {0, 0, 1, 2, 2, 3};
  const std::vector<double> Ax = {5.0, 1.0, -3.0, 2.0, 6.0, 4.0};

  csc_d A(3, 4, 6);
  EXPECT_EQ(coo_to_csc(Ai, Aj, Ax, A), 0);

  EXPECT_EQ(A.col_start, std::vector<int>({0, 2, 3, 5, 6}));
  EXPECT_DOUBLE_EQ(get(A, 0, 0), 1.0);
  EXPECT_DOUBLE_EQ(get(A, 2, 0), 5.0);
  EXPECT_DOUBLE_EQ(get(A, 1, 1), -3.0);
  EXPECT_DOUBLE_EQ(get(A, 0, 2), 2.0);
  EXPECT_DOUBLE_EQ(get(A, 2, 2), 6.0);
  EXPECT_DOUBLE_EQ(get(A, 1, 3), 4.0);
}

TEST(sparse_matrix, csc_to_csr_to_csc_round_trip)
{
  csc_d A(3, 4, 6);
  make_reference_matrix(A);

  csr_d Arow(0, 0, 0);
  EXPECT_EQ(A.to_compressed_row(Arow), 0);
  EXPECT_EQ(Arow.m, 3);
  EXPECT_EQ(Arow.n, 4);
  EXPECT_EQ(Arow.row_start, std::vector<int>({0, 2, 4, 6}));

  csc_d B(0, 0, 0);
  EXPECT_EQ(Arow.to_compressed_col(B), 0);
  // Each CSC->CSR->CSC pass leaves rows sorted within columns. Our reference
  // matrix is already in that canonical order, so B should match A bitwise.
  EXPECT_EQ(B.col_start, A.col_start);
  EXPECT_EQ(B.i, A.i);
  EXPECT_EQ(B.x, A.x);
}

TEST(sparse_matrix, transpose_swaps_dimensions_and_double_transpose_is_identity)
{
  csc_d A(3, 4, 6);
  make_reference_matrix(A);

  csc_d AT(0, 0, 0);
  EXPECT_EQ(A.transpose(AT), 0);
  EXPECT_EQ(AT.m, 4);
  EXPECT_EQ(AT.n, 3);
  EXPECT_DOUBLE_EQ(get(AT, 0, 0), 1.0);   // (0,0) <-> (0,0)
  EXPECT_DOUBLE_EQ(get(AT, 0, 2), 5.0);   // (2,0) <-> (0,2)
  EXPECT_DOUBLE_EQ(get(AT, 1, 1), -3.0);  // (1,1) <-> (1,1)
  EXPECT_DOUBLE_EQ(get(AT, 3, 1), 4.0);   // (1,3) <-> (3,1)

  csc_d ATT(0, 0, 0);
  EXPECT_EQ(AT.transpose(ATT), 0);
  EXPECT_EQ(ATT.m, A.m);
  EXPECT_EQ(ATT.n, A.n);
  for (int j = 0; j < A.n; ++j) {
    for (int i = 0; i < A.m; ++i) {
      EXPECT_DOUBLE_EQ(get(ATT, i, j), get(A, i, j));
    }
  }
}

TEST(sparse_matrix, cumulative_sum_writes_prefix_sums_and_overwrites_inout)
{
  std::vector<int> inout  = {3, 1, 4};
  std::vector<int> output(4, -1);
  cumulative_sum(inout, output);
  EXPECT_EQ(output, std::vector<int>({0, 3, 4, 8}));
  EXPECT_EQ(inout, std::vector<int>({0, 3, 4}));  // overwritten with prefix sums
}

// ----------------------------------------------------------------------------
// Column extraction, append, scatter
// ----------------------------------------------------------------------------

TEST(sparse_matrix, load_a_column_returns_nnz_and_writes_dense_entries)
{
  csc_d A(3, 4, 6);
  make_reference_matrix(A);

  std::vector<double> col(3, 0.0);
  EXPECT_EQ(A.load_a_column(0, col), 2);
  EXPECT_DOUBLE_EQ(col[0], 1.0);
  EXPECT_DOUBLE_EQ(col[1], 0.0);
  EXPECT_DOUBLE_EQ(col[2], 5.0);

  std::fill(col.begin(), col.end(), 0.0);
  EXPECT_EQ(A.load_a_column(2, col), 2);
  EXPECT_DOUBLE_EQ(col[0], 2.0);
  EXPECT_DOUBLE_EQ(col[2], 6.0);
}

TEST(sparse_matrix, append_column_dense_drops_zeros_and_grows_n)
{
  // Start with a 3x0 matrix that has capacity for 6 nonzeros. append_column()
  // writes to col_start[n+1] in place and does NOT grow col_start itself --
  // the caller must size it to (planned_n + 1) up front.
  csc_d A(3, 0, 6);
  A.col_start.assign(3, 0);

  A.append_column(std::vector<double>{1.0, 0.0, 5.0});
  EXPECT_EQ(A.n, 1);
  EXPECT_EQ(A.col_start[A.n], 2);  // 2 nonzeros so far

  A.append_column(std::vector<double>{0.0, -3.0, 0.0});
  EXPECT_EQ(A.n, 2);
  EXPECT_EQ(A.col_start[A.n], 3);

  EXPECT_DOUBLE_EQ(get(A, 0, 0), 1.0);
  EXPECT_DOUBLE_EQ(get(A, 2, 0), 5.0);
  EXPECT_DOUBLE_EQ(get(A, 1, 1), -3.0);
}

TEST(sparse_matrix, append_column_sparse_vector_drops_zeros)
{
  // col_start must be sized for the final n (here we'll have 1 col -> size 2).
  csc_d A(3, 0, 4);
  A.col_start.assign(2, 0);

  // sparse_vector_t with explicit (n, nz) ctor.
  svec_d v(3, 3);
  v.i = {0, 1, 2};
  v.x = {7.0, 0.0, -2.0};  // the 0.0 must be filtered out

  A.append_column(v);
  EXPECT_EQ(A.n, 1);
  EXPECT_EQ(A.col_start[A.n], 2);
  EXPECT_DOUBLE_EQ(get(A, 0, 0), 7.0);
  EXPECT_DOUBLE_EQ(get(A, 2, 0), -2.0);
  EXPECT_DOUBLE_EQ(get(A, 1, 0), 0.0);  // zero was filtered
}

TEST(sparse_matrix, append_column_raw_pointer_overload)
{
  // col_start must be sized for the final n (here we'll have 1 col -> size 2).
  csc_d A(3, 0, 4);
  A.col_start.assign(2, 0);

  // Note the contract: the third overload of append_column takes
  //   (i_t x_nz, i_t* i, f_t* x)
  // and reads x[i[k]] -- i.e. `i` lists the rows to copy and `x` is a
  // dense buffer indexed by row.
  std::vector<int> rows  = {0, 2};
  std::vector<double> dense_x = {9.0, 0.0, 11.0};

  A.append_column(static_cast<int>(rows.size()), rows.data(), dense_x.data());
  EXPECT_EQ(A.n, 1);
  EXPECT_EQ(A.col_start[A.n], 2);
  EXPECT_DOUBLE_EQ(get(A, 0, 0), 9.0);
  EXPECT_DOUBLE_EQ(get(A, 2, 0), 11.0);
}

TEST(sparse_matrix, scatter_dense_basic_accumulates_alpha_times_column)
{
  csc_d A(3, 4, 6);
  make_reference_matrix(A);

  std::vector<double> y(3, 0.0);
  scatter_dense<int, double>(A, /*j=*/0, /*alpha=*/2.0, y);
  EXPECT_DOUBLE_EQ(y[0], 2.0);   // 2 * A(0,0) = 2 * 1
  EXPECT_DOUBLE_EQ(y[1], 0.0);
  EXPECT_DOUBLE_EQ(y[2], 10.0);  // 2 * A(2,0) = 2 * 5

  scatter_dense<int, double>(A, /*j=*/2, /*alpha=*/-1.0, y);
  EXPECT_DOUBLE_EQ(y[0], 0.0);   // 2 + (-1)*2
  EXPECT_DOUBLE_EQ(y[2], 4.0);   // 10 + (-1)*6
}

TEST(sparse_matrix, scatter_dense_with_marks_records_unique_indices)
{
  csc_d A(3, 4, 6);
  make_reference_matrix(A);

  std::vector<double> y(3, 0.0);
  std::vector<int> mark(3, 0);
  std::vector<int> indices;

  scatter_dense<int, double>(A, /*j=*/0, /*alpha=*/1.0, y, mark, indices);
  // col 0 touches rows 0 and 2.
  EXPECT_EQ(indices.size(), 2u);
  EXPECT_EQ(mark[0], 1);
  EXPECT_EQ(mark[1], 0);
  EXPECT_EQ(mark[2], 1);
  EXPECT_DOUBLE_EQ(y[0], 1.0);
  EXPECT_DOUBLE_EQ(y[2], 5.0);

  // Scattering col 2 (rows 0, 2) again must NOT push duplicate indices.
  scatter_dense<int, double>(A, /*j=*/2, /*alpha=*/1.0, y, mark, indices);
  EXPECT_EQ(indices.size(), 2u);  // still {0, 2}
  EXPECT_DOUBLE_EQ(y[0], 3.0);    // 1 + 2
  EXPECT_DOUBLE_EQ(y[2], 11.0);   // 5 + 6
}

// ----------------------------------------------------------------------------
// Structural mutation: remove_column(s) / remove_row / csr remove_rows
// ----------------------------------------------------------------------------

TEST(sparse_matrix, remove_single_column_drops_column_and_compacts_buffers)
{
  csc_d A(3, 4, 6);
  make_reference_matrix(A);

  EXPECT_EQ(A.remove_column(/*col=*/1), 0);  // drop the (-3.0) column
  // n is NOT decremented by remove_column (matches existing semantics).
  // col_start is shifted left for indices > col.
  EXPECT_DOUBLE_EQ(get(A, 0, 0), 1.0);
  EXPECT_DOUBLE_EQ(get(A, 2, 0), 5.0);
  // The OLD col 2 is now at index 1; col 3 is at index 2.
  EXPECT_DOUBLE_EQ(A.x[A.col_start[1] + 0], 2.0);
  EXPECT_DOUBLE_EQ(A.x[A.col_start[1] + 1], 6.0);
  EXPECT_DOUBLE_EQ(A.x[A.col_start[2] + 0], 4.0);
  EXPECT_EQ(A.col_start[3], 5);  // 6 - 1 after shifting
}

TEST(sparse_matrix, remove_columns_marker_drops_marked_columns_and_updates_n)
{
  csc_d A(3, 4, 6);
  make_reference_matrix(A);

  // Mark cols 1 and 3 for removal -> result should keep cols 0 and 2.
  std::vector<int> marker = {0, 1, 0, 1};
  EXPECT_EQ(A.remove_columns(marker), 0);
  EXPECT_EQ(A.n, 2);
  EXPECT_EQ(A.col_start, std::vector<int>({0, 2, 4}));
  EXPECT_DOUBLE_EQ(get(A, 0, 0), 1.0);
  EXPECT_DOUBLE_EQ(get(A, 2, 0), 5.0);
  EXPECT_DOUBLE_EQ(get(A, 0, 1), 2.0);
  EXPECT_DOUBLE_EQ(get(A, 2, 1), 6.0);
}

TEST(sparse_matrix, remove_row_drops_entries_and_renumbers_higher_rows)
{
  csc_d A(3, 4, 6);
  make_reference_matrix(A);

  EXPECT_EQ(A.remove_row(/*row=*/1), 0);
  // m is NOT decremented by remove_row.
  // Original (1, 1) and (1, 3) entries vanish; rows >= 2 shift down by 1.
  // New layout: col 0 i=[0,1] x=[1,5], col 1 empty, col 2 i=[0,1] x=[2,6], col 3 empty.
  EXPECT_EQ(A.col_start, std::vector<int>({0, 2, 2, 4, 4}));
  EXPECT_DOUBLE_EQ(A.x[0], 1.0);
  EXPECT_DOUBLE_EQ(A.x[1], 5.0);
  EXPECT_DOUBLE_EQ(A.x[2], 2.0);
  EXPECT_DOUBLE_EQ(A.x[3], 6.0);
  EXPECT_EQ(A.i, std::vector<int>({0, 1, 0, 1, /* tail (junk after compact) */ 2, 1}));
}

TEST(sparse_matrix, csr_remove_rows_drops_marked_rows)
{
  csc_d A(3, 4, 6);
  make_reference_matrix(A);

  csr_d Arow(0, 0, 0);
  ASSERT_EQ(A.to_compressed_row(Arow), 0);

  std::vector<int> marker = {0, 1, 0};  // drop the middle row
  csr_d Aout(0, 0, 0);
  EXPECT_EQ(Arow.remove_rows(marker, Aout), 0);
  EXPECT_EQ(Aout.m, 2);
  EXPECT_EQ(Aout.n, 4);
  // Surviving rows: original rows 0 and 2.
  EXPECT_EQ(Aout.row_start, std::vector<int>({0, 2, 4}));
  EXPECT_EQ(Aout.j, std::vector<int>({0, 2, 0, 2}));
  EXPECT_DOUBLE_EQ(Aout.x[0], 1.0);
  EXPECT_DOUBLE_EQ(Aout.x[1], 2.0);
  EXPECT_DOUBLE_EQ(Aout.x[2], 5.0);
  EXPECT_DOUBLE_EQ(Aout.x[3], 6.0);
}

// ----------------------------------------------------------------------------
// Permutation
// ----------------------------------------------------------------------------

TEST(sparse_matrix, permute_rows_with_identity_preserves_matrix)
{
  csc_d A(3, 4, 6);
  make_reference_matrix(A);

  csc_d C(3, 4, 0);
  std::vector<int> identity = {0, 1, 2};  // pinv == identity
  EXPECT_EQ(A.permute_rows(identity, C), 0);

  for (int j = 0; j < A.n; ++j) {
    for (int i = 0; i < A.m; ++i) {
      EXPECT_DOUBLE_EQ(get(C, i, j), get(A, i, j));
    }
  }
}

TEST(sparse_matrix, permute_rows_reverse_swaps_top_and_bottom_rows)
{
  csc_d A(3, 4, 6);
  make_reference_matrix(A);

  csc_d C(3, 4, 0);
  // pinv[i] gives the destination row of source row i.
  // Reverse permutation: row 0 -> 2, row 1 -> 1, row 2 -> 0.
  std::vector<int> pinv = {2, 1, 0};
  EXPECT_EQ(A.permute_rows(pinv, C), 0);

  EXPECT_DOUBLE_EQ(get(C, 2, 0), 1.0);  // was A(0,0)
  EXPECT_DOUBLE_EQ(get(C, 0, 0), 5.0);  // was A(2,0)
  EXPECT_DOUBLE_EQ(get(C, 1, 1), -3.0);
  EXPECT_DOUBLE_EQ(get(C, 1, 3), 4.0);
}

TEST(sparse_matrix, permute_rows_and_cols_combined)
{
  csc_d A(3, 4, 6);
  make_reference_matrix(A);

  csc_d C(3, 4, 0);
  std::vector<int> pinv = {2, 1, 0};         // reverse rows
  std::vector<int> q    = {3, 2, 1, 0};      // reverse cols
  EXPECT_EQ(A.permute_rows_and_cols(pinv, q, C), 0);

  // Original A(1,3)=4 with reverse_row->1, reverse_col(0)=3, so C(1,0)=4.
  EXPECT_DOUBLE_EQ(get(C, 1, 0), 4.0);
  // Original A(0,2)=2 ends up at C(2,1). Original A(2,2)=6 ends up at C(0,1).
  EXPECT_DOUBLE_EQ(get(C, 2, 1), 2.0);
  EXPECT_DOUBLE_EQ(get(C, 0, 1), 6.0);
  // Original A(1,1)=-3 stays in the middle column on reverse: q[2]=1 means
  // dest col 2 sources from src col 1; row reverse maps 1->1.
  EXPECT_DOUBLE_EQ(get(C, 1, 2), -3.0);
}

// ----------------------------------------------------------------------------
// norm1, hash, is_diagonal, compare, csr check_matrix
// ----------------------------------------------------------------------------

TEST(sparse_matrix, norm1_returns_max_column_absolute_sum)
{
  csc_d A(3, 4, 6);
  make_reference_matrix(A);
  // col absolute sums = {6, 3, 8, 4}; max = 8.
  EXPECT_DOUBLE_EQ(A.norm1(), 8.0);
}

TEST(sparse_matrix, hash_is_consistent_for_equal_matrices_and_changes_on_perturbation)
{
  csc_d A(3, 4, 6);
  csc_d B(3, 4, 6);
  make_reference_matrix(A);
  make_reference_matrix(B);
  EXPECT_EQ(A.hash(), B.hash());

  B.x[0] += 1.0;
  EXPECT_NE(A.hash(), B.hash());
}

TEST(sparse_matrix, is_diagonal_csc_recognizes_diagonal_and_non_diagonal)
{
  csc_d D(3, 3, 3);
  make_diag3(D, 1.0, 2.0, 3.0);
  EXPECT_TRUE(D.is_diagonal());

  csc_d N(3, 3, 4);
  N.col_start = {0, 2, 3, 4};
  N.i         = {0, 1, 1, 2};
  N.x         = {1.0, 9.0, 2.0, 3.0};
  EXPECT_FALSE(N.is_diagonal());
}

TEST(sparse_matrix, is_diagonal_csr_recognizes_diagonal_and_non_diagonal)
{
  csc_d D(3, 3, 3);
  make_diag3(D, 1.0, 2.0, 3.0);
  csr_d Drow(0, 0, 0);
  ASSERT_EQ(D.to_compressed_row(Drow), 0);
  EXPECT_TRUE(Drow.is_diagonal());

  csc_d N(3, 3, 4);
  N.col_start = {0, 2, 3, 4};
  N.i         = {0, 1, 1, 2};
  N.x         = {1.0, 9.0, 2.0, 3.0};
  csr_d Nrow(0, 0, 0);
  ASSERT_EQ(N.to_compressed_row(Nrow), 0);
  EXPECT_FALSE(Nrow.is_diagonal());
}

TEST(sparse_matrix, compare_runs_silently_on_equal_matrices)
{
  csc_d A(3, 4, 6);
  csc_d B(3, 4, 6);
  make_reference_matrix(A);
  make_reference_matrix(B);

  testing::internal::CaptureStdout();
  A.compare(B);
  std::string out = testing::internal::GetCapturedStdout();
  EXPECT_TRUE(out.empty()) << "compare() should be silent on equal matrices, got: " << out;
}

TEST(sparse_matrix, csr_check_matrix_runs_on_well_formed_csr)
{
  csc_d A(3, 4, 6);
  make_reference_matrix(A);
  csr_d Arow(0, 0, 0);
  ASSERT_EQ(A.to_compressed_row(Arow), 0);
  // No repeated j within any row -> no errors printed; just verify no crash.
  ASSERT_NO_FATAL_FAILURE(Arow.check_matrix("ref"));
}

// ----------------------------------------------------------------------------
// Multiplication / addition / dot products
// ----------------------------------------------------------------------------

TEST(sparse_matrix, multiply_with_identity_preserves_left_operand)
{
  csc_d A(3, 4, 6);
  make_reference_matrix(A);

  csc_d I(4, 4, 4);
  I.col_start = {0, 1, 2, 3, 4};
  I.i         = {0, 1, 2, 3};
  I.x         = {1.0, 1.0, 1.0, 1.0};

  csc_d C(3, 4, 0);
  EXPECT_EQ(multiply(A, I, C), 0);
  EXPECT_EQ(C.m, 3);
  EXPECT_EQ(C.n, 4);
  for (int j = 0; j < A.n; ++j) {
    for (int i = 0; i < A.m; ++i) {
      EXPECT_DOUBLE_EQ(get(C, i, j), get(A, i, j))
        << "mismatch at (" << i << "," << j << ")";
    }
  }
}

TEST(sparse_matrix, multiply_two_diagonal_matrices_gives_componentwise_product)
{
  csc_d A(3, 3, 3);
  make_diag3(A, 2.0, 3.0, 4.0);
  csc_d B(3, 3, 3);
  make_diag3(B, 5.0, 6.0, 7.0);

  csc_d C(3, 3, 0);
  EXPECT_EQ(multiply(A, B, C), 0);
  EXPECT_EQ(C.m, 3);
  EXPECT_EQ(C.n, 3);
  EXPECT_DOUBLE_EQ(get(C, 0, 0), 10.0);  // 2 * 5
  EXPECT_DOUBLE_EQ(get(C, 1, 1), 18.0);  // 3 * 6
  EXPECT_DOUBLE_EQ(get(C, 2, 2), 28.0);  // 4 * 7
}

TEST(sparse_matrix, add_with_alpha_and_beta_combines_entries)
{
  csc_d A(3, 3, 3);
  make_diag3(A, 1.0, 2.0, 3.0);
  csc_d B(3, 3, 3);
  make_diag3(B, 10.0, 20.0, 30.0);

  csc_d C(3, 3, 0);
  EXPECT_EQ(add(A, B, /*alpha=*/2.0, /*beta=*/-1.0, C), 0);
  EXPECT_DOUBLE_EQ(get(C, 0, 0), 2.0 * 1.0 + -1.0 * 10.0);  // -8
  EXPECT_DOUBLE_EQ(get(C, 1, 1), 2.0 * 2.0 + -1.0 * 20.0);  // -16
  EXPECT_DOUBLE_EQ(get(C, 2, 2), 2.0 * 3.0 + -1.0 * 30.0);  // -24
}

TEST(sparse_matrix, sparse_dot_with_csc_column_matches_dense_dot_on_intersection)
{
  csc_d Y(3, 4, 6);
  make_reference_matrix(Y);

  // x = (rows {0, 2}, vals {10, 30}); y_col = 0 has rows {0, 2}, vals {1, 5}.
  // Dot = 10*1 + 30*5 = 160.
  std::vector<int> xind    = {0, 2};
  std::vector<double> xval = {10.0, 30.0};
  EXPECT_DOUBLE_EQ((sparse_dot<int, double>(xind, xval, Y, /*y_col=*/0)), 160.0);

  // y_col = 1 only has row 1 -> intersection with x is empty -> dot = 0.
  EXPECT_DOUBLE_EQ((sparse_dot<int, double>(xind, xval, Y, /*y_col=*/1)), 0.0);
}

TEST(sparse_matrix, matrix_vector_multiply_y_equals_alpha_A_x_plus_beta_y)
{
  csc_d A(3, 4, 6);
  make_reference_matrix(A);

  std::vector<double> x = {1.0, 1.0, 1.0, 1.0};
  std::vector<double> y = {0.0, 0.0, 0.0};

  // y <- 1 * A * x + 0 * y
  EXPECT_EQ(matrix_vector_multiply(A, /*alpha=*/1.0, x, /*beta=*/0.0, y), 0);
  EXPECT_DOUBLE_EQ(y[0], 3.0);   // 1 + 2
  EXPECT_DOUBLE_EQ(y[1], 1.0);   // -3 + 4
  EXPECT_DOUBLE_EQ(y[2], 11.0);  // 5 + 6

  // y <- 2 * A * x + 0.5 * y -> {2*3 + 0.5*3, 2*1 + 0.5*1, 2*11 + 0.5*11}
  EXPECT_EQ(matrix_vector_multiply(A, /*alpha=*/2.0, x, /*beta=*/0.5, y), 0);
  EXPECT_DOUBLE_EQ(y[0], 7.5);
  EXPECT_DOUBLE_EQ(y[1], 2.5);
  EXPECT_DOUBLE_EQ(y[2], 27.5);
}

TEST(sparse_matrix, matrix_transpose_vector_multiply_y_equals_alpha_AT_x_plus_beta_y)
{
  csc_d A(3, 4, 6);
  make_reference_matrix(A);

  std::vector<double> x = {1.0, 1.0, 1.0};
  std::vector<double> y = {0.0, 0.0, 0.0, 0.0};

  // y <- 1 * A^T * x + 0 * y
  EXPECT_EQ(matrix_transpose_vector_multiply(A, /*alpha=*/1.0, x, /*beta=*/0.0, y), 0);
  EXPECT_DOUBLE_EQ(y[0], 6.0);   // 1 + 5
  EXPECT_DOUBLE_EQ(y[1], -3.0);
  EXPECT_DOUBLE_EQ(y[2], 8.0);   // 2 + 6
  EXPECT_DOUBLE_EQ(y[3], 4.0);
}

// ----------------------------------------------------------------------------
// IO smoke tests (verify functions emit *something* without crashing)
// ----------------------------------------------------------------------------

TEST(sparse_matrix, print_matrix_to_file_emits_nonempty_output)
{
  csc_d A(3, 4, 6);
  make_reference_matrix(A);

  // Write to /dev/null first to verify the FILE* overload doesn't crash.
  if (FILE* devnull = std::fopen("/dev/null", "w")) {
    A.print_matrix(devnull);
    std::fclose(devnull);
  }

  // Then exercise the no-arg overload via gtest's stdout capture.
  testing::internal::CaptureStdout();
  A.print_matrix();
  std::string out = testing::internal::GetCapturedStdout();
  EXPECT_NE(out.find("ijx = ["), std::string::npos);
  EXPECT_NE(out.find("A = sparse"), std::string::npos);
}

TEST(sparse_matrix, write_matrix_market_to_file_does_not_crash)
{
  csc_d A(3, 4, 6);
  make_reference_matrix(A);

  if (FILE* devnull = std::fopen("/dev/null", "w")) {
    A.write_matrix_market(devnull);
    std::fclose(devnull);
  }
}

}  // namespace cuopt::linear_programming::dual_simplex::test
