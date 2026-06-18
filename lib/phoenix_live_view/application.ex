defmodule Phoenix.LiveView.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Phoenix.LiveView.Logger.install()

    resume_cfg = Application.get_env(:phoenix_live_view, :resume, [])
    max_children = Keyword.get(resume_cfg, :max_children, 10_000)

    # Resume infrastructure: holds dead-rendered sockets briefly so the first
    # WS connect can skip a duplicate mount. Opt-in via :resume config.
    children = [
      {Registry, keys: :unique, name: Phoenix.LiveView.Resume.Registry},
      {DynamicSupervisor,
       name: Phoenix.LiveView.Resume.Supervisor,
       strategy: :one_for_one,
       max_children: max_children}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Phoenix.LiveView.Supervisor)
  end
end
