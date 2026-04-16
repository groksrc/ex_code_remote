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
      assert msg =~ "No agent" and msg =~ "connected"
    end

    test "not connected includes machine name when context provided" do
      {:error, msg} =
        ResultFormatter.format({:error, :not_connected}, %{machine: "my-box"})

      assert msg =~ "'my-box'"
    end

    test "agent disconnected includes command context" do
      {:error, msg} =
        ResultFormatter.format({:error, :agent_disconnected}, %{
          command: "make build",
          machine: "ci-1"
        })

      assert msg =~ "disconnected"
      assert msg =~ "make build"
      assert msg =~ "ci-1"
    end

    test "server-side timeout reports waited duration including slack" do
      {:error, msg} =
        ResultFormatter.format({:error, :timeout}, %{
          command: "sleep 200",
          machine: "my-laptop",
          timeout: 60
        })

      assert msg =~ "No response from agent after 65 seconds"
      assert msg =~ "may still be running"
      assert msg =~ "sleep 200"
      assert msg =~ "my-laptop"
    end

    test "server-side timeout without ctx falls back to generic phrasing" do
      {:error, msg} = ResultFormatter.format({:error, :timeout})
      assert msg =~ "No response from agent"
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

  describe "agent-reported timeout" do
    test "explicit headline with duration from ctx" do
      {:error, msg} =
        ResultFormatter.format(
          {:ok,
           %{
             status: "timeout",
             output: nil,
             error: "Command timed out after 60 seconds",
             exit_code: -1
           }},
          %{
            command: "sleep 65",
            machine: "my-laptop",
            timeout: 60,
            working_dir: "/tmp"
          }
        )

      assert msg =~ "Command timed out after 60 seconds"
      assert msg =~ "agent killed the process"
      assert msg =~ "Command: sleep 65"
      assert msg =~ "Machine: my-laptop"
      assert msg =~ "Working directory: /tmp"
      assert msg =~ "[exit_code: -1]"
      assert msg =~ "(no output captured before kill)"
    end

    test "extracts duration from agent message when ctx has none" do
      {:error, msg} =
        ResultFormatter.format(
          {:ok,
           %{
             status: "timeout",
             output: nil,
             error: "Command timed out after 30 seconds",
             exit_code: -1
           }},
          %{}
        )

      assert msg =~ "after 30 seconds"
    end

    test "includes partial output when the agent captured some" do
      {:error, msg} =
        ResultFormatter.format(
          {:ok,
           %{
             status: "timeout",
             output: "starting work\nstep 1 done\n",
             error: "Command timed out after 60 seconds",
             exit_code: -1
           }},
          %{command: "long_thing"}
        )

      assert msg =~ "Partial output captured before kill"
      assert msg =~ "starting work"
      assert msg =~ "step 1 done"
      refute msg =~ "(no output captured before kill)"
    end

    test "no duration in either ctx or message still produces a clear headline" do
      {:error, msg} =
        ResultFormatter.format(
          {:ok, %{status: "timeout", output: nil, error: "weird thing", exit_code: -1}},
          %{}
        )

      assert msg =~ "Command timed out"
      assert msg =~ "agent killed the process"
    end
  end

  describe "ctx-aware backwards compatibility" do
    test "successful result ignores ctx" do
      assert {:ok, "hello"} =
               ResultFormatter.format(
                 {:ok, %{output: "hello", error: nil, exit_code: nil}},
                 %{command: "echo hello", machine: "x"}
               )
    end
  end
end
