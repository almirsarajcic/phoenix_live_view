defmodule Phoenix.LiveView.Park do
  @moduledoc false

  use GenServer, restart: :temporary

  alias Phoenix.LiveView.Socket
  alias Phoenix.LiveView.Utils

  @park_token_vsn 1

  @type token :: String.t()

  @doc false
  @spec park(Socket.t()) :: {:ok, token()} | {:error, term()}
  def park(%Socket{endpoint: endpoint, id: id, view: view} = socket) do
    key = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    case DynamicSupervisor.start_child(
           Phoenix.LiveView.Park.Supervisor,
           {__MODULE__, %{socket: socket, key: key}}
         ) do
      {:ok, _pid} ->
        # The token embeds the socket id and view so take/4 can reject
        # cross-view replays, and is verified with a TTL-scoped max_age.
        token =
          Phoenix.Token.sign(
            endpoint,
            Utils.salt!(endpoint),
            {@park_token_vsn, %{lv_park_key: key, id: id, view: view}}
          )

        {:ok, token}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec take(token(), module(), String.t(), module()) :: {:ok, Socket.t()} | :error
  def take(token, endpoint, expected_id, expected_view) do
    result =
      try do
        Phoenix.Token.verify(
          endpoint,
          Utils.salt!(endpoint),
          token,
          max_age: div(ttl_ms(), 1000) + 5
        )
      rescue
        _ -> {:error, :invalid}
      end

    case result do
      {:ok, {@park_token_vsn, %{lv_park_key: key, id: id, view: view}}}
      when id == expected_id and view == expected_view ->
        case Registry.lookup(Phoenix.LiveView.Park.Registry, key) do
          [{pid, _}] ->
            try do
              GenServer.call(pid, :take, 1_000)
            catch
              :exit, {reason, _} when reason in [:noproc, :normal, :timeout] -> :error
              :exit, :timeout -> :error
              :exit, _ -> :error
            end

          [] ->
            :error
        end

      _ ->
        :error
    end
  end

  @doc false
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(%{key: key} = arg) do
    GenServer.start_link(__MODULE__, arg,
      name: {:via, Registry, {Phoenix.LiveView.Park.Registry, key}}
    )
  end

  @impl GenServer
  def init(%{key: key, socket: socket}) do
    ttl_ref = Process.send_after(self(), :ttl_expired, ttl_ms())
    {:ok, %{key: key, socket: socket, ttl_ref: ttl_ref}}
  end

  @impl GenServer
  def handle_call(:take, _from, state) do
    Process.cancel_timer(state.ttl_ref)
    # The unique Registry auto-deregisters on exit, so stopping unregisters us.
    {:stop, :normal, {:ok, state.socket}, state}
  end

  @impl GenServer
  def handle_info(:ttl_expired, state) do
    {:stop, :normal, state}
  end

  defp warm_mount_config, do: Application.get_env(:phoenix_live_view, :warm_mount, [])

  # ttl is configured in milliseconds.
  defp ttl_ms do
    Keyword.get(warm_mount_config(), :ttl, 5_000)
  end
end
