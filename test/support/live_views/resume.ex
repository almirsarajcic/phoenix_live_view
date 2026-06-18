defmodule Phoenix.LiveViewTest.Support.ResumeLive do
  use Phoenix.LiveView, namespace: Phoenix.LiveViewTest

  def render(assigns) do
    ~H"""
    <p id="connected">connected:{inspect(@connected)}</p>
    <p id="sentinel">sentinel:{inspect(Map.get(assigns, :sentinel))}</p>
    """
  end

  def mount(_params, session, socket) do
    send(Map.get(session, "test_pid") || self(), {:view_mount_ran, self()})
    {:ok, assign(socket, connected: Phoenix.LiveView.connected?(socket), sentinel: :from_mount)}
  end
end

defmodule Phoenix.LiveViewTest.Support.ResumeRecordPid do
  def on_mount(:default, _params, %{"test_pid" => test_pid}, socket) do
    send(test_pid, {:on_mount_called, self()})
    {:cont, socket}
  end
end

defmodule Phoenix.LiveViewTest.Support.ResumeHaltMount do
  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    {:halt, push_navigate(socket, to: "/resume/plain")}
  end
end

defmodule Phoenix.LiveViewTest.Support.ResumeContRedirect do
  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    {:cont, push_navigate(socket, to: "/resume/plain")}
  end
end

defmodule Phoenix.LiveViewTest.Support.ResumeOrderA do
  def on_mount(:default, _params, %{"test_pid" => test_pid}, socket) do
    send(test_pid, {:order, :A})
    {:cont, socket}
  end
end

defmodule Phoenix.LiveViewTest.Support.ResumeOrderB do
  def on_mount(:default, _params, %{"test_pid" => test_pid}, socket) do
    send(test_pid, {:order, :B})
    {:cont, socket}
  end
end

defmodule Phoenix.LiveViewTest.Support.ResumeAttachInMount do
  import Phoenix.LiveView

  def on_mount(:default, _params, %{"test_pid" => test_pid}, socket) do
    socket =
      attach_hook(socket, :resume_info_hook, :handle_info, fn
        {:hooked, val}, sock ->
          send(test_pid, {:hook_fired, val})
          {:cont, sock}

        _msg, sock ->
          {:cont, sock}
      end)

    {:cont, socket}
  end
end

defmodule Phoenix.LiveViewTest.Support.ResumeAttachInMountLive do
  use Phoenix.LiveView, namespace: Phoenix.LiveViewTest

  def render(assigns) do
    ~H"""
    <p id="status">ready</p>
    """
  end

  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  def handle_info(msg, socket) do
    {:noreply, assign(socket, last_msg: msg)}
  end
end

# Sends {:view_mount_ran, self()} from mount/3 so tests can detect whether
# view.mount/3 ran on the resume branch. Renders both a mount-set assign
# (:sentinel) and a hook-set assign (:hook_assign, see ResumeReuseHook) so the
# warm path can be proven to reuse BOTH the mount and the on_mount results.
defmodule Phoenix.LiveViewTest.Support.ResumeSentinelLive do
  use Phoenix.LiveView, namespace: Phoenix.LiveViewTest

  def render(assigns) do
    ~H"""
    <p id="sentinel">sentinel:{inspect(Map.get(assigns, :sentinel))}</p>
    <p id="hook">hook:{inspect(Map.get(assigns, :hook_assign))}</p>
    """
  end

  def mount(_params, session, socket) do
    send(Map.get(session, "test_pid") || self(), {:view_mount_ran, self()})
    {:ok, assign(socket, sentinel: :from_view_mount)}
  end
end

# Assigns :hook_assign and emits a {:side_effect, :ran} message. On a warm
# (resumed) connect the on_mount hook does NOT re-run: the dead-render assign is
# reused (so :hook_assign is rendered) and the side-effect fires exactly once.
defmodule Phoenix.LiveViewTest.Support.ResumeReuseHook do
  def on_mount(:default, _params, %{"test_pid" => test_pid}, socket) do
    send(test_pid, {:side_effect, :ran})
    {:cont, Phoenix.Component.assign(socket, hook_assign: :from_hook)}
  end
end

# Per-view opt-in: resume: true overrides app-wide disabled
defmodule Phoenix.LiveViewTest.Support.ResumeOptInLive do
  use Phoenix.LiveView, namespace: Phoenix.LiveViewTest, resume: true

  def render(assigns) do
    ~H"""
    <p id="sentinel">sentinel:{inspect(Map.get(assigns, :sentinel))}</p>
    """
  end

  def mount(_params, session, socket) do
    send(Map.get(session, "test_pid") || self(), {:view_mount_ran, self()})
    {:ok, assign(socket, sentinel: :from_mount)}
  end
end

# Per-view opt-out: resume: false overrides app-wide enabled
defmodule Phoenix.LiveViewTest.Support.ResumeOptOutLive do
  use Phoenix.LiveView, namespace: Phoenix.LiveViewTest, resume: false

  def render(assigns) do
    ~H"""
    <p id="sentinel">sentinel:{inspect(Map.get(assigns, :sentinel))}</p>
    """
  end

  def mount(_params, session, socket) do
    send(Map.get(session, "test_pid") || self(), {:view_mount_ran, self()})
    {:ok, assign(socket, sentinel: :from_mount)}
  end
end

# Auth live view: template renders @current_user populated by ResumeAuthHook via assign_new.
# mount/3 is intentionally minimal — the hook's assign_new(:current_user) is the asserted path.
defmodule Phoenix.LiveViewTest.Support.ResumeAuthLive do
  use Phoenix.LiveView, namespace: Phoenix.LiveViewTest

  def render(assigns) do
    ~H"""
    <p id="user">user:{inspect(Map.get(assigns, :current_user))}</p>
    """
  end

  def mount(_params, _session, socket) do
    {:ok, socket}
  end
end

# LiveView with on_connect/1 — signals the test process each time a WS connect fires.
# Also records whether the session's test_pid was set so on_connect assignment tests work.
defmodule Phoenix.LiveViewTest.Support.ResumeOnConnectLive do
  use Phoenix.LiveView, namespace: Phoenix.LiveViewTest

  def render(assigns) do
    ~H"""
    <p id="label">label:{inspect(Map.get(assigns, :label))}</p>
    """
  end

  def mount(_params, session, socket) do
    send(Map.get(session, "test_pid") || self(), {:view_mount_ran, self()})
    {:ok, assign(socket, label: nil, test_pid: Map.get(session, "test_pid"))}
  end

  def on_connect(socket) do
    if pid = socket.assigns[:test_pid], do: send(pid, {:on_connect_ran, self()})
    {:ok, assign(socket, label: :from_on_connect)}
  end
end

# on_mount hook for the auth contract test.
#
# Uses an Agent as a sequenced value source so that a (buggy) fresh re-computation
# on the warm connect would be DISTINGUISHABLE from the reused dead-render value:
#   - dead render: Agent returns :dead_render_user (then advances to :ws_user).
#   - warm connect (Option A): the hook does NOT run again, so the Agent is never
#     read a second time and the rendered value stays :dead_render_user.
#
# The hook sends {:on_mount_user, assigned_value} so the test can assert it runs
# exactly once and reports :dead_render_user.
defmodule Phoenix.LiveViewTest.Support.ResumeAuthHook do
  import Phoenix.Component, only: [assign_new: 3]

  def on_mount(:default, _params, session, socket) do
    test_pid = Map.get(session, "test_pid")
    agent = Map.get(session, "user_agent")

    socket =
      assign_new(socket, :current_user, fn ->
        if agent do
          Agent.get_and_update(agent, fn
            :dead_render_user -> {:dead_render_user, :ws_user}
            other -> {other, other}
          end)
        else
          :no_agent
        end
      end)

    if test_pid, do: send(test_pid, {:on_mount_user, socket.assigns.current_user})

    {:cont, socket}
  end
end

# LiveView whose handle_params calls push_patch during the initial mount sequence.
# Used to prove that the warm flag survives through the live_patch reply arm.
defmodule Phoenix.LiveViewTest.Support.ResumePatchLive do
  use Phoenix.LiveView, namespace: Phoenix.LiveViewTest

  def render(assigns) do
    ~H"""
    <p id="sentinel">sentinel:{inspect(Map.get(assigns, :sentinel))}</p>
    <p id="patched">patched:{inspect(Map.get(assigns, :patched))}</p>
    """
  end

  def mount(_params, session, socket) do
    test_pid = Map.get(session, "test_pid")
    send(test_pid || self(), {:view_mount_ran, self()})
    {:ok, assign(socket, sentinel: :from_view_mount, patched: false, test_pid: test_pid)}
  end

  # Connect-time navigation belongs in on_connect/1 under resume: it must not run
  # on the dead render (so the GET returns 200 with a resume token) and must fire
  # once per connect. handle_params/3 is NOT re-run on the initial warm connect, so
  # a connected?-guarded push_patch in handle_params would never fire there.
  def on_connect(socket) do
    {:ok, Phoenix.LiveView.push_patch(socket, to: "/resume/patch?patched=true")}
  end

  def handle_params(params, _uri, socket) do
    if pid = socket.assigns[:test_pid], do: send(pid, {:handle_params_ran, params})
    {:noreply, assign(socket, patched: Map.get(params, "patched") == "true")}
  end
end

# Proves handle_params/3 reuse on a warm connect: it runs on the dead render and
# on later live navigation, but is NOT re-invoked on the initial resumed connect
# (the dead-render result is reused). Sends {:handle_params_ran, connected?} per call.
defmodule Phoenix.LiveViewTest.Support.ResumeHandleParamsLive do
  use Phoenix.LiveView, namespace: Phoenix.LiveViewTest

  def render(assigns) do
    ~H"""
    <p id="q">q:{inspect(Map.get(assigns, :q))}</p>
    """
  end

  def mount(_params, session, socket) do
    {:ok, assign(socket, q: nil, test_pid: Map.get(session, "test_pid"))}
  end

  def handle_params(params, _uri, socket) do
    if pid = socket.assigns[:test_pid] do
      send(pid, {:handle_params_ran, Phoenix.LiveView.connected?(socket)})
    end

    {:noreply, assign(socket, q: Map.get(params, "q"))}
  end
end

# LiveView whose on_connect/1 returns a bad value (not {:ok, socket}).
# Used to assert that an ArgumentError is raised with the expected message.
defmodule Phoenix.LiveViewTest.Support.ResumeBadOnConnectLive do
  use Phoenix.LiveView, namespace: Phoenix.LiveViewTest

  def render(assigns) do
    ~H"""
    <p>bad on_connect</p>
    """
  end

  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  def on_connect(_socket) do
    :bad_return
  end
end
