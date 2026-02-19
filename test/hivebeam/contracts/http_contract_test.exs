defmodule Hivebeam.Contracts.HttpContractTest do
  use ExUnit.Case, async: true

  alias Hivebeam.Gateway.HTTP.Router
  alias Hivebeam.Test.ContractHelpers

  test "openapi paths/methods match router contract routes" do
    openapi = ContractHelpers.read_json(ContractHelpers.contract_path("openapi.json"))

    openapi_routes =
      openapi
      |> Map.fetch!("paths")
      |> Enum.flat_map(fn {path, operations} ->
        Enum.flat_map(operations, fn {method, _spec} ->
          if method in ["get", "post", "delete", "put", "patch", "head", "options"] do
            [{String.upcase(method), normalize_openapi_path(path)}]
          else
            []
          end
        end)
      end)
      |> MapSet.new()

    router_routes =
      Router.contract_routes()
      |> MapSet.new()

    assert openapi_routes == router_routes
  end

  test "openapi declares bearer auth security scheme" do
    openapi = ContractHelpers.read_json(ContractHelpers.contract_path("openapi.json"))

    scheme = get_in(openapi, ["components", "securitySchemes", "bearerAuth"])
    assert is_map(scheme)
    assert scheme["type"] == "http"
    assert scheme["scheme"] == "bearer"
  end

  test "http examples satisfy selected openapi component schemas" do
    openapi = ContractHelpers.read_json(ContractHelpers.contract_path("openapi.json"))
    examples = ContractHelpers.read_json(ContractHelpers.contract_path("examples.http.json"))

    schemas = get_in(openapi, ["components", "schemas"])

    create_session_schema =
      ContractHelpers.compile_inline_schema(Map.fetch!(schemas, "CreateSessionRequest"))

    prompt_schema =
      ContractHelpers.compile_inline_schema(Map.fetch!(schemas, "PromptRequest"))

    approval_schema =
      ContractHelpers.compile_inline_schema(Map.fetch!(schemas, "ApprovalRequest"))

    session_schema =
      ContractHelpers.compile_inline_schema(Map.fetch!(schemas, "Session"))

    error_schema =
      ContractHelpers.compile_inline_schema(Map.fetch!(schemas, "Error"))

    ContractHelpers.validate!(
      create_session_schema,
      get_in(examples, ["requests", "create_session"]),
      "create_session request example"
    )

    ContractHelpers.validate!(
      prompt_schema,
      get_in(examples, ["requests", "prompt"]),
      "prompt request example"
    )

    ContractHelpers.validate!(
      approval_schema,
      get_in(examples, ["requests", "approval"]),
      "approval request example"
    )

    ContractHelpers.validate!(
      session_schema,
      get_in(examples, ["responses", "session"]),
      "session response example"
    )

    ContractHelpers.validate!(
      error_schema,
      get_in(examples, ["responses", "error_not_found"]),
      "error response example"
    )
  end

  defp normalize_openapi_path(path) do
    Regex.replace(~r/\{([^}]+)\}/, path, ":\\1")
  end
end
