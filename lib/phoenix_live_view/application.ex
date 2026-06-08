defmodule Phoenix.LiveView.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Phoenix.LiveView.Logger.install()

    warm_mount_cfg = Application.get_env(:phoenix_live_view, :warm_mount, [])
    max_children = Keyword.get(warm_mount_cfg, :max_children, 10_000)

    # Warm-mount (parked-process) infrastructure: holds dead-rendered sockets briefly so
    # the first WS connect can skip a duplicate mount. Opt-in via :warm_mount config.
    children = [
      {Registry, keys: :unique, name: Phoenix.LiveView.Park.Registry},
      {DynamicSupervisor,
       name: Phoenix.LiveView.Park.Supervisor, strategy: :one_for_one, max_children: max_children}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Phoenix.LiveView.Supervisor)
  end
end
