/* clang-format off */
/*
 * SPDX-FileCopyrightText: Copyright (c) 2026 AMD
 * SPDX-License-Identifier: Apache-2.0
 */
/* clang-format on */

// Unit tests for cuopt::linear_programming::dual_simplex::vector_math.
//
// vector_math.cpp is a small set of host-only numeric helpers (norms, dot
// products, permutation utilities) used throughout the dual_simplex code.
// Coverage was ~50% line because most callers go through inlined or
// header-defined variants; these tests drive every explicitly instantiated
// <int, double> entry point directly.

#include <gtest/gtest.h>

#include <dual_simplex/vector_math.hpp>

#include <cmath>
#include <vector>

namespace cuopt::linear_programming::dual_simplex::test {

TEST(vector_math, vector_norm_inf_returns_max_absolute_entry)
{
  // Templated inline in the header but instantiated here.
  EXPECT_DOUBLE_EQ((vector_norm_inf<int, double>(std::vector<double>{})), 0.0);
  EXPECT_DOUBLE_EQ((vector_norm_inf<int, double>(std::vector<double>{1.0, -2.0, 0.5})), 2.0);
  EXPECT_DOUBLE_EQ((vector_norm_inf<int, double>(std::vector<double>{-7.0})), 7.0);
}

TEST(vector_math, vector_norm2_squared_and_norm2_match_textbook)
{
  std::vector<double> v = {3.0, 4.0};
  EXPECT_DOUBLE_EQ((vector_norm2_squared<int, double>(v)), 25.0);
  EXPECT_DOUBLE_EQ((vector_norm2<int, double>(v)), 5.0);

  EXPECT_DOUBLE_EQ((vector_norm2_squared<int, double>(std::vector<double>{})), 0.0);
  EXPECT_DOUBLE_EQ((vector_norm2<int, double>(std::vector<double>{})), 0.0);
}

TEST(vector_math, vector_norm1_returns_sum_of_absolute_entries)
{
  EXPECT_DOUBLE_EQ((vector_norm1<int, double>(std::vector<double>{})), 0.0);
  EXPECT_DOUBLE_EQ((vector_norm1<int, double>(std::vector<double>{1.0, -2.0, 0.5})), 3.5);
  EXPECT_DOUBLE_EQ((vector_norm1<int, double>(std::vector<double>{-7.0})), 7.0);
}

TEST(vector_math, dot_returns_inner_product)
{
  std::vector<double> a = {1.0, 2.0, 3.0};
  std::vector<double> b = {4.0, -5.0, 6.0};
  EXPECT_DOUBLE_EQ((dot<int, double>(a, b)), 1.0 * 4.0 + 2.0 * -5.0 + 3.0 * 6.0);
  EXPECT_DOUBLE_EQ((dot<int, double>(std::vector<double>{}, std::vector<double>{})), 0.0);
}

TEST(vector_math, sparse_dot_index_value_pair_overload_walks_intersection)
{
  // Two sorted sparse vectors: x has indices {0,2,4}, y has {1,2,3,4}.
  // Dot accumulates values where indices match: (idx 2: 5*-1) + (idx 4: 7*2) = -5 + 14 = 9.
  std::vector<int> xind = {0, 2, 4};
  std::vector<double> xval = {3.0, 5.0, 7.0};
  std::vector<int> yind = {1, 2, 3, 4};
  std::vector<double> yval = {1.0, -1.0, 9.0, 2.0};
  EXPECT_DOUBLE_EQ((sparse_dot<int, double>(xind, xval, yind, yval)), 9.0);

  // Disjoint indices -> 0.
  EXPECT_DOUBLE_EQ((sparse_dot<int, double>(std::vector<int>{0}, std::vector<double>{1.0},
                                             std::vector<int>{1}, std::vector<double>{1.0})),
                   0.0);

  // Empty either side -> 0.
  EXPECT_DOUBLE_EQ((sparse_dot<int, double>(std::vector<int>{}, std::vector<double>{},
                                             yind, yval)),
                   0.0);
  EXPECT_DOUBLE_EQ((sparse_dot<int, double>(xind, xval,
                                             std::vector<int>{}, std::vector<double>{})),
                   0.0);
}

TEST(vector_math, sparse_dot_pointer_overload_with_dense_y_buffer)
{
  // sparse_dot(xind, xval, nx, yind, ny, y_scatter_val):
  //   y_scatter_val is a DENSE buffer indexed by row, not yval[].
  //   Intersection contributes xval[i] * y_scatter_val[xind[i]].
  std::vector<int> xind = {0, 2, 4};
  std::vector<double> xval = {3.0, 5.0, 7.0};
  std::vector<int> yind = {1, 2, 3, 4};
  std::vector<double> y_dense = {0.0, 1.0, -1.0, 9.0, 2.0};

  // Matches at xind=2 -> 5 * y_dense[2] = 5 * -1 = -5
  // Matches at xind=4 -> 7 * y_dense[4] = 7 * 2  = 14
  // Total = 9.
  const int nx = static_cast<int>(xind.size());
  const int ny = static_cast<int>(yind.size());
  EXPECT_DOUBLE_EQ((sparse_dot<int, double>(xind.data(), xval.data(), nx,
                                             yind.data(), ny, y_dense.data())),
                   9.0);
}

TEST(vector_math, sparse_dot_mutable_pointer_overload_matches_const_overload)
{
  // The mutable-pointer overload is a separate explicit instantiation.
  std::vector<int> xind = {0, 2, 4};
  std::vector<double> xval = {3.0, 5.0, 7.0};
  std::vector<int> yind = {1, 2, 3, 4};
  std::vector<double> yval = {1.0, -1.0, 9.0, 2.0};
  const int nx = static_cast<int>(xind.size());
  const int ny = static_cast<int>(yind.size());
  EXPECT_DOUBLE_EQ((sparse_dot<int, double>(xind.data(), xval.data(), nx,
                                             yind.data(), yval.data(), ny)),
                   9.0);
}

TEST(vector_math, permute_vector_computes_x_equals_b_at_p)
{
  // x[k] = b[p[k]]  -- "gather"
  std::vector<int> p = {2, 0, 1};
  std::vector<double> b = {10.0, 20.0, 30.0};
  std::vector<double> x(3, 0.0);
  EXPECT_EQ((permute_vector<int, double>(p, b, x)), 0);
  EXPECT_EQ(x, std::vector<double>({30.0, 10.0, 20.0}));
}

TEST(vector_math, inverse_permute_vector_computes_x_at_p_equals_b)
{
  // x[p[k]] = b[k]  -- "scatter"
  std::vector<int> p = {2, 0, 1};
  std::vector<double> b = {10.0, 20.0, 30.0};
  std::vector<double> x(3, 0.0);
  EXPECT_EQ((inverse_permute_vector<int, double>(p, b, x)), 0);
  // x[2] = 10, x[0] = 20, x[1] = 30
  EXPECT_EQ(x, std::vector<double>({20.0, 30.0, 10.0}));
}

TEST(vector_math, inverse_permutation_inverts_a_permutation)
{
  std::vector<int> p = {2, 0, 1};
  std::vector<int> pinv;  // empty -> resized inside
  EXPECT_EQ(inverse_permutation<int>(p, pinv), 0);
  // pinv[p[k]] = k -> pinv[2]=0, pinv[0]=1, pinv[1]=2
  EXPECT_EQ(pinv, std::vector<int>({1, 2, 0}));

  // Round-trip: pinv applied to a permuted vector recovers the original.
  std::vector<double> b = {10.0, 20.0, 30.0};
  std::vector<double> tmp(3, 0.0);
  std::vector<double> back(3, 0.0);
  permute_vector<int, double>(p, b, tmp);
  permute_vector<int, double>(pinv, tmp, back);
  EXPECT_EQ(back, b);
}

TEST(vector_math, inverse_permutation_handles_pre_sized_output)
{
  // Branch where pinv.size() == n already (no resize taken).
  std::vector<int> p = {1, 0};
  std::vector<int> pinv(2, -1);
  EXPECT_EQ(inverse_permutation<int>(p, pinv), 0);
  EXPECT_EQ(pinv, std::vector<int>({1, 0}));
}

}  // namespace cuopt::linear_programming::dual_simplex::test
