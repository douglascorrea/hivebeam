defmodule Hivebeam.Contracts.WsContractTest do
  use ExUnit.Case, async: true

  alias Hivebeam.Test.ContractHelpers

  test "ws examples satisfy client and server schemas" do
    client_schema =
      ContractHelpers.compile_schema(ContractHelpers.contract_path("ws.client.schema.json"))

    server_schema =
      ContractHelpers.compile_schema(ContractHelpers.contract_path("ws.server.schema.json"))

    examples = ContractHelpers.read_json(ContractHelpers.contract_path("examples.ws.json"))

    Enum.each(Map.fetch!(examples, "client"), fn frame ->
      ContractHelpers.validate!(client_schema, frame, "ws client frame")
    end)

    Enum.each(Map.fetch!(examples, "server"), fn frame ->
      ContractHelpers.validate!(server_schema, frame, "ws server frame")
    end)
  end
end
