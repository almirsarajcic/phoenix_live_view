defmodule Phoenix.LiveView.Resume do
  @moduledoc false

  use GenServer, restart: :temporary

  require Logger

  alias Phoenix.LiveView.Socket
  alias Phoenix.LiveView.Utils

  @resume_token_vsn 1

  @type token :: String.t()

  @doc false
  @spec issue(Socket.t()) :: {:ok, token()} | {:error, term()}
  def issue(%Socket{endpoint: endpoint, id: id, view: view} = socket) do
    key = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    case DynamicSupervisor.start_child(
           Phoenix.LiveView.Resume.Supervisor,
           {__MODULE__, %{socket: socket, key: key}}
         ) do
      {:ok, _pid} ->
        # The token embeds the socket id and view so redeem/4 can reject
        # cross-view replays, and is verified with a TTL-scoped max_age.
        token =
          Phoenix.Token.sign(
            endpoint,
            Utils.salt!(endpoint),
            {@resume_token_vsn, %{lv_resume_key: key, id: id, view: view}}
          )

        {:ok, token}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec redeem(token(), module(), String.t(), module()) :: {:ok, Socket.t()} | :error
  def redeem(token, endpoint, expected_id, expected_view) do
    case Phoenix.Token.verify(
           endpoint,
           Utils.salt!(endpoint),
           token,
           max_age: div(ttl_ms(), 1000) + 5
         ) do
      {:ok, {@resume_token_vsn, %{lv_resume_key: key, id: id, view: view}}}
      when id == expected_id and view == expected_view ->
        case Registry.lookup(Phoenix.LiveView.Resume.Registry, key) do
          [{pid, _}] ->
            try do
              GenServer.call(pid, :redeem, 1_000)
            catch
              # :noproc — holder gone between lookup and call
              # :normal — holder stopped cleanly (TTL fired)
              # :timeout — GenServer.call timeout exits as {:timeout, {GenServer, :call, _}};
              #             matched here as {reason, _} with reason = :timeout
              :exit, {reason, _} when reason in [:noproc, :normal, :timeout] ->
                :error

              :exit, reason ->
                Logger.warning(
                  "Phoenix.LiveView.Resume.redeem unexpected exit: #{inspect(reason)}"
                )

                :error
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
      name: {:via, Registry, {Phoenix.LiveView.Resume.Registry, key}}
    )
  end

  @impl GenServer
  def init(%{key: key, socket: socket}) do
    ttl_ref = Process.send_after(self(), :ttl_expired, ttl_ms())
    {:ok, %{key: key, socket: socket, ttl_ref: ttl_ref}}
  end

  @impl GenServer
  def handle_call(:redeem, _from, state) do
    Process.cancel_timer(state.ttl_ref)
    # The unique Registry auto-deregisters on exit, so stopping unregisters us.
    {:stop, :normal, {:ok, state.socket}, state}
  end

  @impl GenServer
  def handle_info(:ttl_expired, state) do
    {:stop, :normal, state}
  end

  @doc false
  # Returns true when resume is effectively enabled for the given view config map.
  # Per-view true/false wins; absent inherits the app-wide :enabled flag (default off).
  @spec enabled?(map()) :: boolean()
  def enabled?(view_config) do
    case Map.get(view_config, :resume, :inherit) do
      true -> true
      false -> false
      _ -> Keyword.get(resume_config(), :enabled, false)
    end
  end

  defp resume_config, do: Application.get_env(:phoenix_live_view, :resume, [])

  # ttl is configured in milliseconds.
  defp ttl_ms do
    Keyword.get(resume_config(), :ttl, 5_000)
  end
end
