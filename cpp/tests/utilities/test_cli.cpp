/* clang-format off */
/*
 * SPDX-FileCopyrightText: Copyright (c) 2025-2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
 * SPDX-License-Identifier: Apache-2.0
 */
/* clang-format on */

#include <gtest/gtest.h>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

static std::string get_cuopt_cli_path()
{
  // Resolve at runtime: the test binary lives at <build>/tests/utilities/CLI_TEST
  // and cuopt_cli lives at <build>/cuopt_cli.
  auto self = std::filesystem::canonical("/proc/self/exe");
  auto cli  = self.parent_path().parent_path().parent_path() / "cuopt_cli";
  if (std::filesystem::exists(cli)) { return cli.string(); }
  return "cuopt_cli";
}

class cli_test_t : public ::testing::Test {
 protected:
  void SetUp() override
  {
    test_dir = std::filesystem::temp_directory_path() / "cuopt_cli_test";
    std::filesystem::create_directories(test_dir);

    mps_file = test_dir / "test.mps";
    std::ofstream mps(mps_file);
    mps << "NAME          TEST\n"
        << "ROWS\n"
        << " N  OBJ\n"
        << " L  R1\n"
        << " L  R2\n"
        << "COLUMNS\n"
        << "    X1        OBJ        1\n"
        << "    X1        R1         1\n"
        << "    X2        OBJ        2\n"
        << "    X2        R2         1\n"
        << "    X3        OBJ        3\n"
        << "    X3        R1         1\n"
        << "    X4        OBJ        4\n"
        << "    X4        R2         1\n"
        << "    X5        OBJ        5\n"
        << "    X5        R1         1\n"
        << "RHS\n"
        << "    RHS1      R1         5\n"
        << "    RHS1      R2         3\n"
        << "ENDATA\n";
    mps.close();

    // Initial solution file -- named differently from the CLI's output (test.sol)
    // to avoid false positives where SetUp-created files satisfy output checks.
    sol_file = test_dir / "initial.sol";
    std::ofstream sol(sol_file);
    sol << "# Status: Optimal\n"
        << "# Objective value: 1.0\n"
        << "X1 1.0\n"
        << "X2 2.0\n"
        << "X3 3.0\n"
        << "X4 4.0\n"
        << "X5 5.0\n";
    sol.close();
  }

  void TearDown() override { std::filesystem::remove_all(test_dir); }

  std::filesystem::path test_dir;
  std::filesystem::path mps_file;
  std::filesystem::path sol_file;

  std::string run_cli(const std::vector<std::string>& args)
  {
    std::stringstream cmd;
    cmd << get_cuopt_cli_path() << " ";
    for (const auto& arg : args) {
      cmd << arg << " ";
    }
    cmd << "2>&1";

    FILE* pipe = popen(cmd.str().c_str(), "r");
    if (!pipe) { throw std::runtime_error("popen() failed!"); }

    std::string result;
    char buffer[128];
    while (fgets(buffer, sizeof(buffer), pipe) != nullptr) {
      result += buffer;
    }

    pclose(pipe);
    return result;
  }
};

TEST_F(cli_test_t, basic_usage)
{
  auto expected_sol_file = test_dir / "test.sol";
  std::filesystem::remove(expected_sol_file);

  auto output = run_cli({mps_file.string()});

  EXPECT_TRUE(std::filesystem::exists(expected_sol_file))
    << "CLI did not create solution file. Output:\n"
    << output;

  std::ifstream sol(expected_sol_file);
  std::string content((std::istreambuf_iterator<char>(sol)), std::istreambuf_iterator<char>());
  EXPECT_TRUE(content.find("Status:") != std::string::npos);
  EXPECT_TRUE(content.find("Objective value:") != std::string::npos);
  EXPECT_TRUE(output.find("RAM (available/total):") != std::string::npos);
}

TEST_F(cli_test_t, with_initial_solution)
{
  auto expected_sol_file = test_dir / "test.sol";
  std::filesystem::remove(expected_sol_file);

  auto output = run_cli({mps_file.string(), "--initial-solution", sol_file.string()});

  EXPECT_TRUE(std::filesystem::exists(expected_sol_file))
    << "CLI did not create solution file. Output:\n"
    << output;

  std::ifstream sol(expected_sol_file);
  std::string content((std::istreambuf_iterator<char>(sol)), std::istreambuf_iterator<char>());
  EXPECT_TRUE(content.find("Status:") != std::string::npos);
  EXPECT_TRUE(content.find("Objective value:") != std::string::npos);
}

TEST_F(cli_test_t, invalid_mps_file)
{
  auto invalid_file = test_dir / "invalid.mps";
  std::ofstream invalid(invalid_file);
  invalid << "INVALID CONTENT";
  invalid.close();

  auto output = run_cli({invalid_file.string()});
  EXPECT_TRUE(output.find("Parsing MPS failed") != std::string::npos ||
              output.find("MPS parser") != std::string::npos)
    << "Expected MPS parsing error. Output:\n"
    << output;
}

TEST_F(cli_test_t, missing_required_argument)
{
  auto output = run_cli({});
  EXPECT_TRUE(output.find("0 provided") != std::string::npos ||
              output.find("Usage") != std::string::npos)
    << "Expected usage/argument error. Output:\n"
    << output;
}

TEST_F(cli_test_t, unrecognized_argument)
{
  auto output = run_cli({mps_file.string(), "--dummy-argument"});
  EXPECT_TRUE(output.find("Unknown argument: --dummy-argument") != std::string::npos)
    << "Expected unknown argument error. Output:\n"
    << output;
}

TEST_F(cli_test_t, wrong_parameter_type)
{
  auto output = run_cli({mps_file.string(), "--time-limit", "invalid"});
  EXPECT_TRUE(output.find("error") != std::string::npos ||
              output.find("Error") != std::string::npos)
    << "Expected type conversion error for --time-limit. Output:\n"
    << output;

  output = run_cli({mps_file.string(), "--iteration-limit", "abc"});
  EXPECT_TRUE(output.find("error") != std::string::npos ||
              output.find("Error") != std::string::npos)
    << "Expected type conversion error for --iteration-limit. Output:\n"
    << output;
}

TEST_F(cli_test_t, partial_solution_file)
{
  auto partial_sol_file = test_dir / "partial.sol";
  std::ofstream partial(partial_sol_file);
  partial << "X1 1.0\nX3 2.0\n";
  partial.close();

  auto output = run_cli({mps_file.string(), "--initial-solution", partial_sol_file.string()});
  EXPECT_TRUE(output.find("Variable not found in solution:") != std::string::npos)
    << "Expected partial solution warning. Output:\n"
    << output;

  auto expected_sol_file = test_dir / "test.sol";
  if (std::filesystem::exists(expected_sol_file)) {
    std::ifstream sol(expected_sol_file);
    std::string content((std::istreambuf_iterator<char>(sol)), std::istreambuf_iterator<char>());
    EXPECT_TRUE(content.find("Status:") != std::string::npos);
    EXPECT_TRUE(content.find("Objective value:") != std::string::npos);
  }
}

int main(int argc, char** argv)
{
  ::testing::InitGoogleTest(&argc, argv);
  return RUN_ALL_TESTS();
}
