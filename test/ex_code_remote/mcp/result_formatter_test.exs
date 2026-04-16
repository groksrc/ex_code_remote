defmodule ExCodeRemote.MCP.ResultFormatterTest do
  use ExUnit.Case, async: true

  alias ExCodeRemote.MCP.ResultFormatter

  describe "successful results" do
    test "stdout only" do
      assert {:ok, "hello world"} =
               ResultFormatter.format({:ok, %{output: "hello world", error: nil, exit_code: nil}})
    end

    test "stdout with exit code" do
      assert {:ok, "done\n[exit_code: 0]"} =
               ResultFormatter.format({:ok, %{output: "done", error: nil, exit_code: 0}})
    end

    test "stdout, stderr, and exit code" do
      assert {:ok, "output\n[stderr]: warning\n[exit_code: 1]"} =
               ResultFormatter.format({:ok, %{output: "output", error: "warning", exit_code: 1}})
    end

    test "no stdout, no stderr, exit code zero" do
      assert {:ok, "[exit_code: 0]"} =
               ResultFormatter.format({:ok, %{output: nil, error: nil, exit_code: 0}})
    end

    test "completely empty result" do
      assert {:ok, "(no output)"} =
               ResultFormatter.format({:ok, %{output: nil, error: nil, exit_code: nil}})
    end

    test "empty string output becomes (no output)" do
      assert {:ok, "(no output)"} =
               ResultFormatter.format({:ok, %{output: "", error: nil, exit_code: nil}})
    end

    test "empty string stderr is not included" do
      assert {:ok, "hello\n[exit_code: 0]"} =
               ResultFormatter.format({:ok, %{output: "hello", error: "", exit_code: 0}})
    end

    test "whitespace-only output is trimmed to (no output)" do
      assert {:ok, "(no output)"} =
               ResultFormatter.format({:ok, %{output: "  \n  ", error: nil, exit_code: nil}})
    end
  end

  describe "error results" do
    test "not connected" do
      {:error, msg} = ResultFormatter.format({:error, :not_connected})
      assert msg =~ "not connected" or msg =~ "No agents"
    end

    test "agent disconnected" do
      {:error, msg} = ResultFormatter.format({:error, :agent_disconnected})
      assert msg =~ "disconnected"
    end

    test "timeout" do
      {:error, msg} = ResultFormatter.format({:error, :timeout})
      assert msg =~ "timed out"
    end

    test "unknown error atom produces generic message" do
      {:error, msg} = ResultFormatter.format({:error, :something_weird})
      assert msg =~ "Unexpected error"
      assert msg =~ "something weird"
    end

    test "unknown error term produces generic message" do
      {:error, msg} = ResultFormatter.format({:error, "string error"})
      assert msg =~ "Unexpected error"
    end
  end
end
