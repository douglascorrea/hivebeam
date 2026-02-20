defmodule Hivebeam.Gateway.SLO do
  @moduledoc false
  use GenServer

  require Logger

  alias Hivebeam.Gateway.Config

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec record_session_create_duration(non_neg_integer()) :: :ok
  def record_session_create_duration(duration_ms)
      when is_integer(duration_ms) and duration_ms >= 0 do
    cast_if_started({:session_create_duration, duration_ms})
  end

  def record_session_create_duration(_duration_ms), do: :ok

  @spec record_worker_exit(term()) :: :ok
  def record_worker_exit(reason) do
    cast_if_started({:worker_exit, reason})
  end

  @spec snapshot() :: map()
  def snapshot do
    case Process.whereis(__MODULE__) do
      nil ->
        %{
          session_create_samples: [],
          worker_exits: 0,
          worker_crashes: 0
        }

      _pid ->
        GenServer.call(__MODULE__, :snapshot)
    end
  end

  @impl true
  def init(_opts) do
    state = %{
      session_create_samples: [],
      worker_exits: 0,
      worker_crashes: 0,
      report_interval_ms: Config.slo_report_interval_ms(),
      session_create_p95_threshold_ms: Config.slo_session_create_p95_threshold_ms(),
      worker_crash_rate_threshold: Config.slo_worker_crash_rate_threshold()
    }

    {:ok, schedule_report(state)}
  end

  @impl true
  def handle_cast({:session_create_duration, duration_ms}, state) do
    {:noreply, %{state | session_create_samples: [duration_ms | state.session_create_samples]}}
  end

  def handle_cast({:worker_exit, reason}, state) do
    worker_crashes =
      if crash_reason?(reason), do: state.worker_crashes + 1, else: state.worker_crashes

    {:noreply,
     %{
       state
       | worker_exits: state.worker_exits + 1,
         worker_crashes: worker_crashes
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       session_create_samples: Enum.reverse(state.session_create_samples),
       worker_exits: state.worker_exits,
       worker_crashes: state.worker_crashes
     }, state}
  end

  @impl true
  def handle_info(:report, state) do
    p95 = percentile95(state.session_create_samples)

    crash_rate =
      if state.worker_exits == 0 do
        0.0
      else
        state.worker_crashes / state.worker_exits
      end

    if is_integer(p95) and p95 > state.session_create_p95_threshold_ms do
      Logger.warning(
        "gateway_slo session_create_p95_ms=#{p95} threshold_ms=#{state.session_create_p95_threshold_ms}"
      )
    end

    if crash_rate > state.worker_crash_rate_threshold do
      Logger.warning(
        "gateway_slo worker_crash_rate=#{Float.round(crash_rate, 4)} threshold=#{state.worker_crash_rate_threshold} exits=#{state.worker_exits} crashes=#{state.worker_crashes}"
      )
    end

    :telemetry.execute(
      [:hivebeam, :gateway, :slo, :report],
      %{
        session_create_p95_ms: p95 || 0,
        worker_crash_rate: crash_rate,
        worker_exits: state.worker_exits,
        worker_crashes: state.worker_crashes
      },
      %{
        threshold_session_create_p95_ms: state.session_create_p95_threshold_ms,
        threshold_worker_crash_rate: state.worker_crash_rate_threshold
      }
    )

    next_state =
      state
      |> Map.put(:session_create_samples, [])
      |> Map.put(:worker_exits, 0)
      |> Map.put(:worker_crashes, 0)
      |> schedule_report()

    {:noreply, next_state}
  end

  defp percentile95([]), do: nil

  defp percentile95(samples) do
    sorted = Enum.sort(samples)
    count = length(sorted)
    idx = max(ceil(count * 0.95) - 1, 0)
    Enum.at(sorted, idx)
  end

  defp crash_reason?(:normal), do: false
  defp crash_reason?(:shutdown), do: false
  defp crash_reason?({:shutdown, _reason}), do: false
  defp crash_reason?(_reason), do: true

  defp schedule_report(state) do
    Process.send_after(self(), :report, state.report_interval_ms)
    state
  end

  defp cast_if_started(message) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.cast(__MODULE__, message)
    end
  end
end
