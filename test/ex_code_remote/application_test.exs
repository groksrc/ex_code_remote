defmodule ExCodeRemote.ApplicationTest do
  use ExUnit.Case, async: false

  test "Registry is running" do
    assert Process.whereis(ExCodeRemote.AgentRegistry) != nil
  end

  test "DynamicSupervisor is running" do
    assert Process.whereis(ExCodeRemote.AgentSupervisor) != nil
  end

  test "application supervisor is running" do
    assert Process.whereis(ExCodeRemote.Supervisor) != nil
  end
end
