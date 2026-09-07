defmodule GSMLG.Commander.CapabilityRegistryTest do
  use ExUnit.Case, async: true

  alias GSMLG.Commander.CapabilityRegistry
  alias GSMLG.Commander.Protocol.Capability

  test "starts with the built-in PTY capability when configured" do
    descriptor = GSMLG.Commander.PTYCapability.descriptor()

    registry =
      start_supervised!(
        {CapabilityRegistry,
         name: nil, initial_capabilities: [{descriptor, GSMLG.Commander.PTYCapability}]}
      )

    assert [{^descriptor, GSMLG.Commander.PTYCapability}] = CapabilityRegistry.list(registry)
    assert descriptor.id == "pty.shell"
    assert descriptor.operations == []
  end

  test "registers validated descriptors and notifies subscribers" do
    registry = start_supervised!({CapabilityRegistry, name: nil})
    assert :ok = CapabilityRegistry.subscribe(registry)

    descriptor = descriptor()
    handler = fn _request -> {:ok, %{}} end

    assert :ok = CapabilityRegistry.register(registry, descriptor, handler)
    assert_receive {:commander_capabilities_changed, [^descriptor]}
    assert [{^descriptor, ^handler}] = CapabilityRegistry.list(registry)
    assert {:ok, {^descriptor, ^handler}} = CapabilityRegistry.fetch(registry, "browser.control")
  end

  test "rejects descriptors that do not satisfy the wire contract" do
    registry = start_supervised!({CapabilityRegistry, name: nil})

    assert {:error, %{code: "unknown_capability_version"}} =
             CapabilityRegistry.register(registry, %{descriptor() | version: 2}, fn _ -> :ok end)
  end

  defp descriptor do
    %Capability{
      id: "browser.control",
      version: 1,
      backend: "cloakbrowser",
      operations: ["manager.status"],
      limits: %{"max_sessions" => 1},
      workflows: ["gemini.deep_research/v1"]
    }
  end
end
