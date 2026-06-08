defmodule Phoenix.LiveViewTest.Support.ParkLive do
  use Phoenix.LiveView, namespace: Phoenix.LiveViewTest

  def render(assigns) do
    ~H"""
    <p id="connected">connected:{inspect(@connected)}</p>
    <p id="sentinel">sentinel:{inspect(Map.get(assigns, :sentinel))}</p>
    """
  end

  def mount(_params, _session, socket) do
    {:ok, assign(socket, connected: Phoenix.LiveView.connected?(socket), sentinel: :from_mount)}
  end
end

defmodule Phoenix.LiveViewTest.Support.ParkRecordPid do
  def on_mount(:default, _params, %{"test_pid" => test_pid}, socket) do
    send(test_pid, {:on_mount_called, self()})
    {:cont, socket}
  end
end

defmodule Phoenix.LiveViewTest.Support.ParkHaltMount do
  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    {:halt, push_navigate(socket, to: "/park/plain")}
  end
end

defmodule Phoenix.LiveViewTest.Support.ParkContRedirect do
  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    {:cont, push_navigate(socket, to: "/park/plain")}
  end
end

defmodule Phoenix.LiveViewTest.Support.ParkOrderA do
  def on_mount(:default, _params, %{"test_pid" => test_pid}, socket) do
    send(test_pid, {:order, :A})
    {:cont, socket}
  end
end

defmodule Phoenix.LiveViewTest.Support.ParkOrderB do
  def on_mount(:default, _params, %{"test_pid" => test_pid}, socket) do
    send(test_pid, {:order, :B})
    {:cont, socket}
  end
end

defmodule Phoenix.LiveViewTest.Support.ParkAttachInMount do
  import Phoenix.LiveView

  def on_mount(:default, _params, %{"test_pid" => test_pid}, socket) do
    socket =
      attach_hook(socket, :park_info_hook, :handle_info, fn
        {:hooked, val}, sock ->
          send(test_pid, {:hook_fired, val})
          {:cont, sock}

        _msg, sock ->
          {:cont, sock}
      end)

    {:cont, socket}
  end
end

defmodule Phoenix.LiveViewTest.Support.ParkAttachInMountLive do
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
# view.mount/3 ran on the warm branch.
defmodule Phoenix.LiveViewTest.Support.ParkSentinelLive do
  use Phoenix.LiveView, namespace: Phoenix.LiveViewTest

  def render(assigns) do
    ~H"""
    <p id="sentinel">sentinel:{inspect(Map.get(assigns, :sentinel))}</p>
    <p id="scratch">scratch:{inspect(Map.get(assigns, :scratch_assign))}</p>
    """
  end

  def mount(_params, session, socket) do
    send(Map.get(session, "test_pid") || self(), {:view_mount_ran, self()})
    {:ok, assign(socket, sentinel: :from_view_mount, scratch_assign: nil)}
  end
end

# Assigns :scratch_assign on the scratch socket; after warm it must not leak
# onto the real socket, though the side-effect message must still be received.
defmodule Phoenix.LiveViewTest.Support.ParkScratchHook do
  def on_mount(:default, _params, %{"test_pid" => test_pid}, socket) do
    send(test_pid, {:side_effect, :ran})
    {:cont, Phoenix.Component.assign(socket, scratch_assign: :from_hook)}
  end
end
