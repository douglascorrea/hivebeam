defmodule Hivebeam.Gateway.Store do
  @moduledoc false
  use GenServer

  alias Hivebeam.Gateway.Config

  @session_table :hb_gateway_sessions
  @counter_table :hb_gateway_counters
  @request_table :hb_gateway_requests

  @session_dets :hb_gateway_session_index
  @event_dets :hb_gateway_event_log
  @request_dets :hb_gateway_request_index

  @default_limit 200
  @max_limit 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec upsert_session(map()) :: {:ok, map()} | {:error, term()}
  def upsert_session(session) when is_map(session) do
    GenServer.call(__MODULE__, {:upsert_session, session})
  end

  @spec get_session(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_session(gateway_session_key) when is_binary(gateway_session_key) do
    case :ets.lookup(@session_table, gateway_session_key) do
      [{^gateway_session_key, session}] -> {:ok, session}
      _ -> {:error, :not_found}
    end
  end

  @spec close_session(String.t()) :: {:ok, map()} | {:error, term()}
  def close_session(gateway_session_key) when is_binary(gateway_session_key) do
    GenServer.call(__MODULE__, {:close_session, gateway_session_key})
  end

  @spec append_event(String.t(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def append_event(gateway_session_key, kind, source, payload)
      when is_binary(gateway_session_key) and is_binary(kind) and is_binary(source) and
             is_map(payload) do
    GenServer.call(__MODULE__, {:append_event, gateway_session_key, kind, source, payload})
  end

  @spec read_events(String.t(), integer(), pos_integer()) ::
          {:ok, %{events: [map()], next_after_seq: integer(), has_more: boolean()}}
          | {:error, term()}
  def read_events(gateway_session_key, after_seq, limit)
      when is_binary(gateway_session_key) and is_integer(after_seq) and is_integer(limit) and
             limit > 0 do
    GenServer.call(__MODULE__, {:read_events, gateway_session_key, after_seq, limit})
  end

  @spec put_request(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def put_request(gateway_session_key, request_id, record)
      when is_binary(gateway_session_key) and is_binary(request_id) and is_map(record) do
    GenServer.call(__MODULE__, {:put_request, gateway_session_key, request_id, record})
  end

  @spec get_request(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_request(gateway_session_key, request_id)
      when is_binary(gateway_session_key) and is_binary(request_id) do
    case :ets.lookup(@request_table, {gateway_session_key, request_id}) do
      [{{^gateway_session_key, ^request_id}, record}] -> {:ok, record}
      _ -> {:error, :not_found}
    end
  end

  @spec update_request(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_request(gateway_session_key, request_id, attrs)
      when is_binary(gateway_session_key) and is_binary(request_id) and is_map(attrs) do
    GenServer.call(__MODULE__, {:update_request, gateway_session_key, request_id, attrs})
  end

  @spec prune_session_events(String.t()) :: :ok | {:error, term()}
  def prune_session_events(gateway_session_key) when is_binary(gateway_session_key) do
    GenServer.call(__MODULE__, {:prune_session_events, gateway_session_key})
  end

  @impl true
  def init(opts) do
    data_dir = Keyword.get(opts, :data_dir, Config.data_dir())
    max_events = Keyword.get(opts, :max_events_per_session, Config.max_events_per_session())

    with :ok <- File.mkdir_p(data_dir),
         {:ok, session_tab} <- create_table(@session_table),
         {:ok, counter_tab} <- create_table(@counter_table),
         {:ok, request_tab} <- create_table(@request_table),
         {:ok, session_ref} <-
           open_dets(@session_dets, Path.join(data_dir, "session_index.dets"), :set),
         {:ok, event_ref} <- open_dets(@event_dets, Path.join(data_dir, "event_log.dets"), :set),
         {:ok, request_ref} <-
           open_dets(@request_dets, Path.join(data_dir, "request_index.dets"), :set) do
      state = %{
        data_dir: data_dir,
        max_events_per_session: max_events,
        session_table: session_tab,
        counter_table: counter_tab,
        request_table: request_tab,
        session_ref: session_ref,
        event_ref: event_ref,
        request_ref: request_ref
      }

      rehydrate(state)
      {:ok, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    _ = :dets.close(state.session_ref)
    _ = :dets.close(state.event_ref)
    _ = :dets.close(state.request_ref)
    :ok
  rescue
    _ -> :ok
  end

  @impl true
  def handle_call({:upsert_session, session}, _from, state) do
    gateway_session_key = Map.fetch!(session, :gateway_session_key)
    session = session |> normalize_session() |> Map.put(:gateway_session_key, gateway_session_key)

    :ets.insert(state.session_table, {gateway_session_key, session})
    :ets.insert(state.counter_table, {gateway_session_key, Map.get(session, :last_seq, 0) + 1})
    :ok = :dets.insert(state.session_ref, {gateway_session_key, session})

    {:reply, {:ok, session}, state}
  end

  def handle_call({:close_session, gateway_session_key}, _from, state) do
    case lookup_session(state, gateway_session_key) do
      {:ok, session} ->
        updated =
          session
          |> Map.put(:status, "closed")
          |> Map.put(:connected, false)
          |> Map.put(:in_flight, false)
          |> Map.put(:updated_at, now_iso())

        :ets.insert(state.session_table, {gateway_session_key, updated})
        :ok = :dets.insert(state.session_ref, {gateway_session_key, updated})
        {:reply, {:ok, updated}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:append_event, gateway_session_key, kind, source, payload}, _from, state) do
    with {:ok, session} <- lookup_session(state, gateway_session_key) do
      next_seq = next_seq(state, gateway_session_key, session)
      ts = now_iso()

      event = %{
        gateway_session_key: gateway_session_key,
        seq: next_seq,
        ts: ts,
        kind: kind,
        source: source,
        payload: payload
      }

      :ok = :dets.insert(state.event_ref, {{gateway_session_key, next_seq}, event})
      :ets.insert(state.counter_table, {gateway_session_key, next_seq + 1})

      updated_session =
        session
        |> Map.put(:last_seq, next_seq)
        |> Map.put(:updated_at, ts)

      :ets.insert(state.session_table, {gateway_session_key, updated_session})
      :ok = :dets.insert(state.session_ref, {gateway_session_key, updated_session})

      state =
        if rem(next_seq, 25) == 0 do
          _ = maybe_prune_session_events(state, gateway_session_key, updated_session)
          state
        else
          state
        end

      {:reply, {:ok, event}, state}
    else
      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:read_events, gateway_session_key, after_seq, limit}, _from, state) do
    limit = clamp_limit(limit)

    events =
      :dets.foldl(
        fn
          {{^gateway_session_key, seq}, event}, acc when is_integer(seq) and seq > after_seq ->
            [event | acc]

          _, acc ->
            acc
        end,
        [],
        state.event_ref
      )
      |> Enum.sort_by(&Map.get(&1, :seq, 0))

    {selected, has_more} =
      if length(events) > limit do
        {Enum.take(events, limit), true}
      else
        {events, false}
      end

    next_after_seq =
      case List.last(selected) do
        nil -> after_seq
        event -> Map.get(event, :seq, after_seq)
      end

    {:reply, {:ok, %{events: selected, next_after_seq: next_after_seq, has_more: has_more}},
     state}
  end

  def handle_call({:put_request, gateway_session_key, request_id, record}, _from, state) do
    now = now_iso()

    normalized =
      record
      |> Map.put(:gateway_session_key, gateway_session_key)
      |> Map.put(:request_id, request_id)
      |> Map.put_new(:created_at, now)
      |> Map.put(:updated_at, now)

    :ets.insert(state.request_table, {{gateway_session_key, request_id}, normalized})
    :ok = :dets.insert(state.request_ref, {{gateway_session_key, request_id}, normalized})

    {:reply, {:ok, normalized}, state}
  end

  def handle_call({:update_request, gateway_session_key, request_id, attrs}, _from, state) do
    key = {gateway_session_key, request_id}

    case :ets.lookup(state.request_table, key) do
      [{^key, existing}] ->
        updated =
          existing
          |> Map.merge(attrs)
          |> Map.put(:updated_at, now_iso())

        :ets.insert(state.request_table, {key, updated})
        :ok = :dets.insert(state.request_ref, {key, updated})

        {:reply, {:ok, updated}, state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:prune_session_events, gateway_session_key}, _from, state) do
    result =
      case lookup_session(state, gateway_session_key) do
        {:ok, session} -> maybe_prune_session_events(state, gateway_session_key, session)
        _ -> :ok
      end

    {:reply, result, state}
  end

  defp create_table(name) do
    :ets.new(name, [:named_table, :set, :public, read_concurrency: true, write_concurrency: true])
    {:ok, name}
  rescue
    ArgumentError ->
      {:ok, name}
  end

  defp open_dets(name, file_path, type) do
    :dets.open_file(name, type: type, file: String.to_charlist(file_path), auto_save: 1_000)
  end

  defp rehydrate(state) do
    _ =
      :dets.foldl(
        fn {gateway_session_key, session}, _acc ->
          :ets.insert(state.session_table, {gateway_session_key, session})

          :ets.insert(
            state.counter_table,
            {gateway_session_key, Map.get(session, :last_seq, 0) + 1}
          )

          :ok
        end,
        :ok,
        state.session_ref
      )

    _ =
      :dets.foldl(
        fn {key, record}, _acc ->
          :ets.insert(state.request_table, {key, record})
          :ok
        end,
        :ok,
        state.request_ref
      )

    :ok
  end

  defp lookup_session(state, gateway_session_key) do
    case :ets.lookup(state.session_table, gateway_session_key) do
      [{^gateway_session_key, session}] -> {:ok, session}
      _ -> {:error, :not_found}
    end
  end

  defp next_seq(state, gateway_session_key, session) do
    case :ets.lookup(state.counter_table, gateway_session_key) do
      [{^gateway_session_key, number}] when is_integer(number) and number > 0 -> number
      _ -> Map.get(session, :last_seq, 0) + 1
    end
  end

  defp maybe_prune_session_events(state, gateway_session_key, session) do
    max_events = state.max_events_per_session
    last_seq = Map.get(session, :last_seq, 0)

    if is_integer(max_events) and max_events > 0 and last_seq > max_events do
      threshold = last_seq - max_events

      keys_to_delete =
        :dets.foldl(
          fn
            {{^gateway_session_key, seq}, _event}, acc when seq <= threshold ->
              [{gateway_session_key, seq} | acc]

            _, acc ->
              acc
          end,
          [],
          state.event_ref
        )

      Enum.each(keys_to_delete, fn key ->
        :ok = :dets.delete(state.event_ref, key)
      end)

      :ok
    else
      :ok
    end
  end

  defp now_iso do
    DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  end

  defp normalize_session(session) do
    now = now_iso()

    session
    |> Map.put_new(:status, "creating")
    |> Map.put_new(:created_at, now)
    |> Map.put_new(:updated_at, now)
    |> Map.put_new(:connected, false)
    |> Map.put_new(:in_flight, false)
    |> Map.put_new(:last_seq, 0)
  end

  defp clamp_limit(limit) when is_integer(limit) and limit > 0 do
    limit
    |> max(1)
    |> min(@max_limit)
  end

  defp clamp_limit(_), do: @default_limit
end
