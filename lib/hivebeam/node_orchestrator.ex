defmodule Hivebeam.NodeOrchestrator do
  @moduledoc false

  @compose_file "docker-compose.yml"
  @default_provider "codex"
  @default_cookie "hivebeam_cookie"
  @default_bind_ip_remote "0.0.0.0"
  @default_remote_timeout_ms 120_000
  @native_runtime_subdir ".hivebeam/nodes"

  @dist_port_base 9100
  @tcp_port_base 5051
  @debug_port_base 1455
  @epmd_port_base 4369

  @type runtime :: %{
          name: String.t(),
          provider: String.t(),
          slot: pos_integer(),
          docker: boolean(),
          remote: String.t() | nil,
          remote_path: String.t(),
          cwd: String.t(),
          project_name: String.t(),
          bind_ip: String.t(),
          host_ip: String.t(),
          node_name: String.t(),
          cookie: String.t(),
          dist_port: pos_integer(),
          tcp_port: pos_integer(),
          debug_port: pos_integer(),
          epmd_port: pos_integer(),
          compose_file: String.t(),
          remote_timeout_ms: pos_integer(),
          pid_file: String.t(),
          log_file: String.t(),
          meta_file: String.t()
        }

  @spec up(keyword()) :: {:ok, runtime(), String.t()} | {:error, term()}
  def up(opts) do
    with {:ok, runtime} <- build_runtime(opts),
         :ok <- ensure_remote_path(runtime),
         :ok <- ensure_local_bind_ip_if_needed(runtime),
         :ok <- ensure_compose_file_if_needed(runtime),
         {:ok, output} <- run_up(runtime) do
      _ = persist_runtime_metadata(runtime)
      {:ok, runtime, output}
    end
  end

  @spec down(keyword()) :: {:ok, runtime(), String.t()} | {:error, term()}
  def down(opts) do
    with {:ok, runtime} <- build_runtime(Keyword.put_new(opts, :hydrate_metadata, true)),
         :ok <- ensure_remote_path(runtime),
         :ok <- ensure_compose_file_if_needed(runtime),
         {:ok, output} <- run_down(runtime) do
      {:ok, runtime, output}
    end
  end

  @spec ls(keyword()) ::
          {:ok, %{projects: [String.t()]}}
          | {:ok, %{nodes: [%{name: String.t(), status: String.t(), pid: String.t() | nil}]}}
          | {:ok, %{runtime: runtime(), running: boolean(), services: [String.t()]}}
          | {:ok,
             %{runtime: runtime(), running: boolean(), status: String.t(), pid: String.t() | nil}}
          | {:error, term()}
  def ls(opts) do
    case Keyword.get(opts, :name) do
      nil ->
        with {:ok, runtime} <- build_runtime([name: "node1"] ++ opts),
             :ok <- ensure_remote_path(runtime),
             result <- list_all(runtime) do
          result
        end

      _name ->
        with {:ok, runtime} <- build_runtime(Keyword.put_new(opts, :hydrate_metadata, true)),
             :ok <- ensure_remote_path(runtime),
             :ok <- ensure_compose_file_if_needed(runtime),
             result <- inspect_one(runtime) do
          result
        end
    end
  end

  @spec build_runtime(keyword()) :: {:ok, runtime()} | {:error, term()}
  def build_runtime(opts) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    hydrate_metadata? = Keyword.get(opts, :hydrate_metadata, false)

    with {:ok, name} <- required_string(opts, :name) do
      opts =
        if hydrate_metadata? do
          hydrate_opts_from_runtime_metadata(opts, cwd, name)
        else
          opts
        end

      slot = normalize_slot(Keyword.get(opts, :slot), name)
      provider = normalize_provider(Keyword.get(opts, :provider, @default_provider))
      docker = Keyword.get(opts, :docker, false) == true
      remote = normalize_optional_string(Keyword.get(opts, :remote))
      remote_path = normalize_remote_path(Keyword.get(opts, :remote_path), cwd)
      bind_ip = resolve_bind_ip(Keyword.get(opts, :bind_ip), remote, slot, docker)
      host_ip = resolve_host_ip(Keyword.get(opts, :host_ip), remote, bind_ip)
      project_name = "hivebeam_#{name}"
      compose_file = Keyword.get(opts, :compose_file, @compose_file)
      cookie = normalize_cookie(Keyword.get(opts, :cookie, @default_cookie))
      dist_port = normalize_port(Keyword.get(opts, :dist_port), @dist_port_base, slot)
      tcp_port = normalize_port(Keyword.get(opts, :tcp_port), @tcp_port_base, slot)
      debug_port = normalize_port(Keyword.get(opts, :debug_port), @debug_port_base, slot)
      epmd_port = normalize_epmd_port(Keyword.get(opts, :epmd_port))
      node_name = "#{provider}@#{host_ip}"

      runtime_dir = Path.join(remote_path, @native_runtime_subdir)
      pid_file = Path.join(runtime_dir, "#{name}.pid")
      log_file = Path.join(runtime_dir, "#{name}.log")
      meta_file = Path.join(runtime_dir, "#{name}.json")

      runtime = %{
        name: name,
        provider: provider,
        slot: slot,
        docker: docker,
        remote: remote,
        remote_path: remote_path,
        cwd: cwd,
        project_name: project_name,
        bind_ip: bind_ip,
        host_ip: host_ip,
        node_name: node_name,
        cookie: cookie,
        dist_port: dist_port,
        tcp_port: tcp_port,
        debug_port: debug_port,
        epmd_port: epmd_port,
        compose_file: compose_file,
        remote_timeout_ms: Keyword.get(opts, :remote_timeout_ms, @default_remote_timeout_ms),
        pid_file: pid_file,
        log_file: log_file,
        meta_file: meta_file
      }

      {:ok, runtime}
    end
  end

  @spec compose_env(runtime()) :: %{String.t() => String.t()}
  def compose_env(runtime) do
    %{
      "HIVEBEAM_ACP_PROVIDER" => runtime.provider,
      "HIVEBEAM_CODEX_BRIDGE_NAME" => bridge_name_for_provider(runtime.provider),
      "HIVEBEAM_NODE_NAME" => runtime.node_name,
      "HIVEBEAM_COOKIE" => runtime.cookie,
      "HIVEBEAM_ERL_DIST_PORT" => Integer.to_string(runtime.dist_port),
      "HIVEBEAM_BIND_IP" => runtime.bind_ip,
      "HIVEBEAM_EPMD_HOST_PORT" => Integer.to_string(runtime.epmd_port),
      "HIVEBEAM_TCP_HOST_PORT" => Integer.to_string(runtime.tcp_port),
      "HIVEBEAM_DEBUG_HOST_PORT" => Integer.to_string(runtime.debug_port)
    }
    |> maybe_put_passthrough_env("CODEX_ACP_GIT_REPO")
    |> maybe_put_passthrough_env("CODEX_ACP_GIT_REF")
  end

  @spec compose_args(runtime(), :up | :down | :status) :: [String.t()]
  def compose_args(runtime, :up) do
    [
      "compose",
      "-f",
      runtime.compose_file,
      "-p",
      runtime.project_name,
      "up",
      "-d",
      "--build"
    ]
  end

  def compose_args(runtime, :down) do
    [
      "compose",
      "-f",
      runtime.compose_file,
      "-p",
      runtime.project_name,
      "down",
      "--remove-orphans"
    ]
  end

  def compose_args(runtime, :status) do
    [
      "compose",
      "-f",
      runtime.compose_file,
      "-p",
      runtime.project_name,
      "ps",
      "--status",
      "running",
      "--services"
    ]
  end

  defp run_up(%{docker: true} = runtime), do: run_compose(runtime, :up)
  defp run_up(runtime), do: run_native_up(runtime)

  defp run_down(%{docker: true} = runtime), do: run_compose(runtime, :down)
  defp run_down(runtime), do: run_native_down(runtime)

  defp list_all(%{docker: true} = runtime) do
    with {:ok, projects} <- list_projects(runtime) do
      {:ok, %{projects: projects}}
    end
  end

  defp list_all(runtime) do
    with {:ok, nodes} <- list_native_nodes(runtime) do
      {:ok, %{nodes: nodes}}
    end
  end

  defp inspect_one(%{docker: true} = runtime) do
    with {:ok, running, services} <- compose_status(runtime) do
      {:ok, %{runtime: runtime, running: running, services: services}}
    end
  end

  defp inspect_one(runtime) do
    with {:ok, status} <- native_status(runtime) do
      {:ok,
       %{
         runtime: runtime,
         running: status.status == "running",
         status: status.status,
         pid: status.pid
       }}
    end
  end

  defp ensure_compose_file_if_needed(%{docker: false}), do: :ok

  defp ensure_compose_file_if_needed(runtime) do
    path = Path.join(runtime.remote_path, runtime.compose_file)

    if File.exists?(path) do
      :ok
    else
      {:error, {:compose_file_missing, path}}
    end
  end

  defp ensure_remote_path(%{remote: nil}), do: :ok

  defp ensure_remote_path(runtime) do
    command = "test -d #{shell_escape(runtime.remote_path)}"

    case System.cmd("ssh", [runtime.remote, command], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, _code} ->
        {:error,
         {:remote_path_missing,
          "Remote path #{runtime.remote_path} not found on #{runtime.remote}. #{String.trim(output)}"}}
    end
  end

  defp run_compose(runtime, mode) do
    args = compose_args(runtime, mode)
    env_map = compose_env(runtime)

    if runtime.remote do
      run_remote(runtime, args, env_map)
    else
      run_local(runtime, args, env_map)
    end
  end

  defp compose_status(runtime) do
    args = compose_args(runtime, :status)
    env_map = compose_env(runtime)

    with {:ok, output} <-
           if(runtime.remote,
             do: run_remote(runtime, args, env_map),
             else: run_local(runtime, args, env_map)
           ) do
      services =
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      {:ok, services != [], services}
    end
  end

  defp run_native_up(runtime) do
    command = native_up_shell(runtime)
    env_map = native_env(runtime)

    if runtime.remote do
      run_remote_shell(runtime, command, env_map)
    else
      run_local_shell(runtime, command, env_map)
    end
  end

  defp run_native_down(runtime) do
    command = native_down_shell(runtime)

    if runtime.remote do
      run_remote_shell(runtime, command, %{})
    else
      run_local_shell(runtime, command, %{})
    end
  end

  defp native_status(runtime) do
    command = native_status_shell(runtime)

    with {:ok, output} <-
           if(runtime.remote,
             do: run_remote_shell(runtime, command, %{}),
             else: run_local_shell(runtime, command, %{})
           ) do
      {:ok, parse_status_output(output)}
    end
  end

  defp list_native_nodes(runtime) do
    command = native_list_shell(runtime)

    with {:ok, output} <-
           if(runtime.remote,
             do: run_remote_shell(runtime, command, %{}),
             else: run_local_shell(runtime, command, %{})
           ) do
      nodes =
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&parse_native_node_line/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.name)

      {:ok, nodes}
    end
  end

  defp parse_status_output(output) do
    pairs =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&String.contains?(&1, "="))
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, "=", parts: 2) do
          [key, value] -> Map.put(acc, key, value)
          _ -> acc
        end
      end)

    %{
      status: Map.get(pairs, "status", "stopped"),
      pid: Map.get(pairs, "pid")
    }
  end

  defp parse_native_node_line(line) do
    case String.split(line, "|", parts: 3) do
      [name, status, pid] ->
        %{name: name, status: status, pid: if(pid == "", do: nil, else: pid)}

      _ ->
        nil
    end
  end

  defp native_up_shell(runtime) do
    erl_aflags =
      "-name #{runtime.node_name} -setcookie #{runtime.cookie} -kernel inet_dist_listen_min #{runtime.dist_port} inet_dist_listen_max #{runtime.dist_port} -connect_all false"

    bridge_task = bridge_mix_task(runtime.provider)

    run =
      "mix deps.get && mix compile && ERL_AFLAGS=#{shell_escape(erl_aflags)} exec mix #{shell_escape(bridge_task)}"

    """
    mkdir -p #{shell_escape(Path.dirname(runtime.pid_file))} &&
    if [ -f #{shell_escape(runtime.pid_file)} ] && kill -0 "$(cat #{shell_escape(runtime.pid_file)})" 2>/dev/null; then
      echo "already_running=$(cat #{shell_escape(runtime.pid_file)})";
    else
      nohup sh -lc #{shell_escape(run)} >> #{shell_escape(runtime.log_file)} 2>&1 &
      echo $! > #{shell_escape(runtime.pid_file)};
      echo "started=$(cat #{shell_escape(runtime.pid_file)})";
    fi
    """
    |> String.replace("\n", " ")
  end

  defp native_down_shell(runtime) do
    """
    if [ -f #{shell_escape(runtime.pid_file)} ]; then
      pid="$(cat #{shell_escape(runtime.pid_file)})";
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true;
        sleep 1;
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true;
      fi;
      rm -f #{shell_escape(runtime.pid_file)};
      echo "stopped=$pid";
    else
      echo "stopped=none";
    fi
    """
    |> String.replace("\n", " ")
  end

  defp native_status_shell(runtime) do
    """
    if [ -f #{shell_escape(runtime.pid_file)} ]; then
      pid="$(cat #{shell_escape(runtime.pid_file)})";
      if kill -0 "$pid" 2>/dev/null; then
        echo "status=running";
      else
        echo "status=stale";
      fi;
      echo "pid=$pid";
    else
      echo "status=stopped";
    fi
    """
    |> String.replace("\n", " ")
  end

  defp native_list_shell(runtime) do
    runtime_dir = Path.dirname(runtime.pid_file)

    """
    dir=#{shell_escape(runtime_dir)};
    if [ -d "$dir" ]; then
      for file in "$dir"/*.pid; do
        [ -e "$file" ] || continue;
        name="$(basename "$file" .pid)";
        pid="$(cat "$file" 2>/dev/null)";
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
          status="running";
        else
          status="stale";
        fi;
        echo "$name|$status|$pid";
      done;
    fi
    """
    |> String.replace("\n", " ")
  end

  defp native_env(runtime) do
    %{
      "HIVEBEAM_ACP_PROVIDER" => runtime.provider,
      "HIVEBEAM_CODEX_BRIDGE_NAME" => bridge_name_for_provider(runtime.provider),
      "HIVEBEAM_NODE_NAME" => runtime.node_name,
      "HIVEBEAM_COOKIE" => runtime.cookie,
      "HIVEBEAM_ERL_DIST_PORT" => Integer.to_string(runtime.dist_port),
      "HIVEBEAM_BIND_IP" => runtime.bind_ip
    }
    |> maybe_put_passthrough_env("CODEX_ACP_GIT_REPO")
    |> maybe_put_passthrough_env("CODEX_ACP_GIT_REF")
  end

  defp list_projects(runtime) do
    command = "docker ps --format '{{.Label \"com.docker.compose.project\"}}'"

    with {:ok, output} <-
           if(runtime.remote,
             do: run_remote_shell(runtime, command, %{}),
             else: run_local_shell(runtime, command, %{})
           ) do
      projects =
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.uniq()
        |> Enum.filter(&String.starts_with?(&1, "hivebeam_"))
        |> Enum.sort()

      {:ok, projects}
    end
  end

  defp run_local(runtime, args, env_map) do
    options = [cd: runtime.remote_path, env: Map.to_list(env_map), stderr_to_stdout: true]

    case System.cmd("docker", args, options) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {:command_failed, {"docker", args, code, output}}}
    end
  end

  defp run_remote(runtime, args, env_map) do
    command =
      render_shell_command(
        runtime,
        "docker #{Enum.map_join(args, " ", &shell_escape/1)}",
        env_map
      )

    run_remote_command(runtime, command)
  end

  defp run_local_shell(runtime, command, env_map) do
    env_prefix = render_env_prefix(env_map)
    full_command = "#{env_prefix}#{command}"

    case System.cmd("sh", ["-lc", full_command], cd: runtime.remote_path, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {:command_failed, {"sh", ["-lc", full_command], code, output}}}
    end
  end

  defp run_remote_shell(runtime, command, env_map) do
    full_command = render_shell_command(runtime, command, env_map)
    run_remote_command(runtime, full_command)
  end

  defp render_shell_command(runtime, command, env_map) do
    env_prefix = render_env_prefix(env_map)
    "cd #{shell_escape(runtime.remote_path)} && #{env_prefix}#{command}"
  end

  defp run_remote_command(runtime, command) do
    case System.cmd("ssh", [runtime.remote, command], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output}

      {output, code} ->
        {:error, {:command_failed, {"ssh", [runtime.remote, command], code, output}}}
    end
  end

  defp render_env_prefix(env_map) when map_size(env_map) == 0, do: ""

  defp render_env_prefix(env_map) do
    env_map
    |> Enum.map(fn {key, value} ->
      "#{key}=#{shell_escape(value)}"
    end)
    |> Enum.join(" ")
    |> Kernel.<>(" ")
  end

  defp shell_escape(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("'", "'\"'\"'")

    "'#{escaped}'"
  end

  defp required_string(opts, key) do
    case normalize_optional_string(Keyword.get(opts, key)) do
      nil -> {:error, {:missing_option, key}}
      value -> {:ok, value}
    end
  end

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_optional_string(value) when is_atom(value),
    do: value |> Atom.to_string() |> String.trim()

  defp normalize_optional_string(value), do: value |> to_string() |> String.trim()

  defp normalize_provider(nil), do: @default_provider

  defp normalize_provider(value) do
    value
    |> normalize_optional_string()
    |> case do
      nil -> @default_provider
      provider -> String.downcase(provider)
    end
  end

  defp normalize_cookie(nil), do: @default_cookie

  defp normalize_cookie(value) do
    value
    |> normalize_optional_string()
    |> case do
      nil -> @default_cookie
      cookie -> cookie
    end
  end

  defp normalize_remote_path(nil, cwd), do: cwd

  defp normalize_remote_path(value, cwd) do
    case normalize_optional_string(value) do
      nil -> cwd
      path -> path
    end
  end

  defp hydrate_opts_from_runtime_metadata(opts, cwd, name) do
    remote = normalize_optional_string(Keyword.get(opts, :remote))
    remote_path = normalize_remote_path(Keyword.get(opts, :remote_path), cwd)

    case load_runtime_metadata(name, remote, remote_path) do
      {:ok, meta} ->
        opts
        |> put_opt_if_missing_from_meta(:provider, meta, "provider")
        |> put_opt_if_missing_from_meta(:slot, meta, "slot")
        |> put_opt_if_missing_from_meta(:docker, meta, "docker")
        |> put_opt_if_missing_from_meta(:bind_ip, meta, "bind_ip")
        |> put_opt_if_missing_from_meta(:host_ip, meta, "host_ip")
        |> put_opt_if_missing_from_meta(:cookie, meta, "cookie")
        |> put_opt_if_missing_from_meta(:dist_port, meta, "dist_port")
        |> put_opt_if_missing_from_meta(:tcp_port, meta, "tcp_port")
        |> put_opt_if_missing_from_meta(:debug_port, meta, "debug_port")
        |> put_opt_if_missing_from_meta(:epmd_port, meta, "epmd_port")
        |> put_opt_if_missing_from_meta(:compose_file, meta, "compose_file")

      :error ->
        opts
    end
  end

  defp put_opt_if_missing_from_meta(opts, key, meta, meta_key) do
    if Keyword.has_key?(opts, key) do
      opts
    else
      case Map.get(meta, meta_key) do
        nil -> opts
        value -> Keyword.put(opts, key, value)
      end
    end
  end

  defp load_runtime_metadata(name, remote, remote_path) do
    path = runtime_metadata_path(name, remote_path)

    raw_result =
      if is_nil(remote) do
        if File.exists?(path), do: File.read(path), else: :error
      else
        command = "if [ -f #{shell_escape(path)} ]; then cat #{shell_escape(path)}; fi"

        case System.cmd("ssh", [remote, command], stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          _ -> :error
        end
      end

    with {:ok, raw} <- raw_result,
         trimmed when is_binary(trimmed) and trimmed != "" <- String.trim(raw),
         {:ok, meta} <- Jason.decode(trimmed) do
      {:ok, meta}
    else
      _ -> :error
    end
  end

  defp runtime_metadata_path(name, remote_path) do
    Path.join([remote_path, @native_runtime_subdir, "#{name}.json"])
  end

  defp persist_runtime_metadata(runtime) do
    payload = %{
      "provider" => runtime.provider,
      "slot" => runtime.slot,
      "docker" => runtime.docker,
      "bind_ip" => runtime.bind_ip,
      "host_ip" => runtime.host_ip,
      "cookie" => runtime.cookie,
      "dist_port" => runtime.dist_port,
      "tcp_port" => runtime.tcp_port,
      "debug_port" => runtime.debug_port,
      "epmd_port" => runtime.epmd_port,
      "compose_file" => runtime.compose_file
    }

    case Jason.encode(payload) do
      {:ok, encoded} ->
        persist_runtime_metadata_json(runtime, encoded)

      _ ->
        :error
    end
  end

  defp persist_runtime_metadata_json(runtime, encoded) do
    command =
      "mkdir -p #{shell_escape(Path.dirname(runtime.meta_file))} && printf %s #{shell_escape(encoded)} > #{shell_escape(runtime.meta_file)}"

    if runtime.remote do
      case run_remote_command(runtime, "sh -lc #{shell_escape(command)}") do
        {:ok, _output} -> :ok
        _ -> :error
      end
    else
      with :ok <- File.mkdir_p(Path.dirname(runtime.meta_file)),
           :ok <- File.write(runtime.meta_file, encoded) do
        :ok
      else
        _ -> :error
      end
    end
  end

  defp normalize_slot(value, name) do
    case value do
      number when is_integer(number) and number > 0 ->
        number

      _ ->
        derive_slot_from_name(name)
    end
  end

  defp derive_slot_from_name(name) do
    case Regex.run(~r/(\d+)$/, name, capture: :all_but_first) do
      [digits] ->
        case Integer.parse(digits) do
          {number, ""} when number > 0 -> number
          _ -> 1
        end

      _ ->
        1
    end
  end

  defp normalize_port(value, _base, _slot) when is_integer(value) and value > 0, do: value
  defp normalize_port(_value, base, slot), do: base + slot - 1
  defp normalize_epmd_port(value) when is_integer(value) and value > 0, do: value
  defp normalize_epmd_port(_value), do: @epmd_port_base

  defp resolve_bind_ip(value, nil, slot, true) do
    case normalize_optional_string(value) do
      nil -> "127.0.0.#{10 + slot}"
      ip -> ip
    end
  end

  defp resolve_bind_ip(value, nil, slot, false) do
    case normalize_optional_string(value) do
      nil -> "127.0.0.#{10 + slot}"
      ip -> ip
    end
  end

  defp resolve_bind_ip(value, _remote, _slot, _docker) do
    case normalize_optional_string(value) do
      nil -> @default_bind_ip_remote
      ip -> ip
    end
  end

  defp resolve_host_ip(value, nil, bind_ip) do
    case normalize_optional_string(value) do
      nil -> bind_ip
      ip -> ip
    end
  end

  defp resolve_host_ip(value, remote, _bind_ip) do
    case normalize_optional_string(value) do
      nil -> remote_host(remote)
      ip -> ip
    end
  end

  defp remote_host(remote) do
    remote
    |> String.split("@")
    |> List.last()
    |> String.split(":")
    |> List.first()
  end

  defp maybe_put_passthrough_env(env_map, key) do
    case System.get_env(key) do
      value when is_binary(value) and value != "" ->
        Map.put(env_map, key, value)

      _ ->
        env_map
    end
  end

  defp bridge_mix_task("codex"), do: "codex.bridge.run"
  defp bridge_mix_task("claude"), do: "claude.bridge.run"
  defp bridge_mix_task(_provider), do: "agents.bridge.run"

  defp bridge_name_for_provider("codex"), do: "Hivebeam.CodexBridge"
  defp bridge_name_for_provider("claude"), do: "Hivebeam.ClaudeBridge"
  defp bridge_name_for_provider(_provider), do: "Hivebeam.CodexBridge"

  defp ensure_local_bind_ip_if_needed(%{docker: true, remote: nil, bind_ip: bind_ip}) do
    if local_bind_ip_available?(bind_ip) do
      :ok
    else
      {:error, {:local_bind_ip_unavailable, bind_ip}}
    end
  end

  defp ensure_local_bind_ip_if_needed(_runtime), do: :ok

  defp local_bind_ip_available?(bind_ip) do
    case :os.type() do
      {:unix, :darwin} ->
        bind_ip == "127.0.0.1" or darwin_loopback_alias?(bind_ip)

      _ ->
        true
    end
  end

  defp darwin_loopback_alias?(bind_ip) do
    case System.cmd("ifconfig", ["lo0"], stderr_to_stdout: true) do
      {output, 0} ->
        String.contains?(output, "inet #{bind_ip} ")

      _ ->
        false
    end
  end
end
