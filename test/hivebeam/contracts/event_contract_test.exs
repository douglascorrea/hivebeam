defmodule Hivebeam.Contracts.EventContractTest do
  use ExUnit.Case, async: true

  alias Hivebeam.Test.ContractHelpers

  test "event examples satisfy event schema" do
    event_schema =
      ContractHelpers.compile_schema(ContractHelpers.contract_path("event.schema.json"))

    http_examples = ContractHelpers.read_json(ContractHelpers.contract_path("examples.http.json"))
    ws_examples = ContractHelpers.read_json(ContractHelpers.contract_path("examples.ws.json"))

    Enum.each(Map.fetch!(http_examples, "events"), fn event ->
      ContractHelpers.validate!(event_schema, event, "http event example")
    end)

    Enum.each(Map.fetch!(ws_examples, "events"), fn event ->
      ContractHelpers.validate!(event_schema, event, "ws event example")
    end)

    Enum.each(Map.fetch!(ws_examples, "server"), fn frame ->
      if frame["type"] == "event" do
        ContractHelpers.validate!(event_schema, frame["data"], "ws server event frame data")
      end
    end)
  end
end
