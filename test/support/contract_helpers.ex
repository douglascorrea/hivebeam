defmodule Hivebeam.Test.ContractHelpers do
  alias ExJsonSchema.Schema
  alias ExJsonSchema.Validator

  @root Path.expand("../../", __DIR__)

  @spec contract_path(String.t()) :: String.t()
  def contract_path(name) when is_binary(name) do
    Path.join([@root, "api", "v1", name])
  end

  @spec read_json(String.t()) :: map()
  def read_json(path) when is_binary(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end

  @spec compile_schema(String.t()) :: map()
  def compile_schema(path) when is_binary(path) do
    path
    |> read_json()
    |> Schema.resolve()
  end

  @spec compile_inline_schema(map()) :: map()
  def compile_inline_schema(schema) when is_map(schema) do
    Schema.resolve(schema)
  end

  @spec validate!(map(), term(), String.t()) :: :ok
  def validate!(schema, payload, label) do
    case Validator.validate(schema, payload) do
      :ok ->
        :ok

      {:error, errors} ->
        formatted = Enum.map_join(errors, "\n", &Exception.message/1)
        raise ExUnit.AssertionError, message: "#{label} failed schema validation:\n#{formatted}"
    end
  end
end
