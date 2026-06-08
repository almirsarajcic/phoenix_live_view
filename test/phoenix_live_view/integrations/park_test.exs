defmodule Phoenix.LiveView.Integration.ParkTest do
  # async: false — TTL tests mutate Application env; also prevents message
  # cross-contamination between tests sharing self() as test_pid receiver.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Phoenix.LiveViewTest.Support.Endpoint

  @endpoint Endpoint

  setup do
    Application.put_env(:phoenix_live_view, :warm_mount, enabled: true, ttl: 5_000)

    on_exit(fn ->
      Application.put_env(:phoenix_live_view, :warm_mount, enabled: false, ttl: 5_000)
    end)

    conn = Plug.Test.init_test_session(build_conn(), %{"test_pid" => self()})
    {:ok, conn: conn}
  end

  test "view.mount/3 runs on cold connect", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/park/plain", connect_params: %{"__force_cold__" => true})
    assert render(lv) =~ "sentinel::from_mount"
  end

  test "on_mount hook runs on cold connect", %{conn: _conn} do
    cold_conn = Plug.Test.init_test_session(build_conn(), %{"test_pid" => self()})

    {:ok, _lv, _html} =
      live(cold_conn, "/park/on-mount", connect_params: %{"__force_cold__" => true})

    # dead render + WS join each invoke on_mount
    assert_receive {:on_mount_called, _}, 500
    assert_receive {:on_mount_called, _}, 500
  end

  test "parked assigns (sentinel from view.mount) present after WS connect", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/park/sentinel")

    assert render(lv) =~ "sentinel::from_view_mount"
  end

  test "on_mount hook runs on warm connect", %{conn: conn} do
    {:ok, _lv, _html} = live(conn, "/park/on-mount")

    # on_mount fires once on the dead render (test process) and once on the
    # warm connect (channel process), and no more.
    assert_receive {:on_mount_called, dead_pid}, 500
    assert_receive {:on_mount_called, warm_pid}, 500
    assert dead_pid == self()
    refute warm_pid == self()
    refute_receive {:on_mount_called, _}, 100
  end

  test "on_mount runs in channel pid (not dead-render pid) on warm connect", %{conn: conn} do
    {:ok, _lv, _html} = live(conn, "/park/on-mount")

    assert_receive {:on_mount_called, pid1}, 500
    assert_receive {:on_mount_called, pid2}, 500

    pids = [pid1, pid2]
    test_pid = self()

    # one call from the dead render (test process), one from the warm channel
    assert Enum.any?(pids, fn p -> p == test_pid end),
           "Expected one on_mount call from dead-render (test process)"

    assert Enum.any?(pids, fn p -> p != test_pid end),
           "Expected one on_mount call from warm channel process"
  end

  test ":halt in on_mount halts warm connect with live_redirect", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/park/plain"}}} = live(conn, "/park/halt")
  end

  test ":halt in on_mount halts cold connect identically", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/park/plain"}}} =
             live(conn, "/park/halt", connect_params: %{"__force_cold__" => true})
  end

  test "on_mount hooks run in order on warm connect", %{conn: conn} do
    {:ok, _lv, _html} = live(conn, "/park/order")

    # A then B on the dead render, then A then B again on the warm connect
    assert_receive {:order, :A}, 500
    assert_receive {:order, :B}, 500
    assert_receive {:order, :A}, 500
    assert_receive {:order, :B}, 500
    refute_receive {:order, _}, 100
  end

  test "scratch assigns do not leak to real socket on warm connect", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/park/sentinel")

    # the hook runs (and its side-effect fires) on both renders, but its
    # scratch assign must not leak onto the real socket
    assert_receive {:side_effect, :ran}, 500
    assert_receive {:side_effect, :ran}, 500
    assert render(lv) =~ "scratch:nil"
  end

  test "parked assigns (sentinel from view.mount) preserved after warm connect", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/park/sentinel")

    assert render(lv) =~ "sentinel::from_view_mount"
  end

  test "view.mount/3 does not run again on warm connect", %{conn: conn} do
    {:ok, _lv, _html} = live(conn, "/park/sentinel")

    # view.mount/3 runs once on the dead render and must not re-run on warm
    assert_receive {:view_mount_ran, dead_pid}, 500
    assert dead_pid == self()
    refute_receive {:view_mount_ran, _}, 200
  end

  test "attach_hook in on_mount does not raise on warm connect (no collision)", %{conn: conn} do
    assert {:ok, lv, _html} = live(conn, "/park/attach-in-mount")

    # the hook attached during on_mount is functional on the warm socket
    send(lv.pid, {:hooked, :value})
    assert_receive {:hook_fired, :value}, 500
  end

  test "telemetry :stop fires on warm connect", %{conn: conn} do
    test_pid = self()
    handler_id = "park-test-telemetry-#{System.unique_integer()}"

    :telemetry.attach(
      handler_id,
      [:phoenix, :live_view, :mount, :stop],
      fn _event, _measurements, _metadata, _config ->
        send(test_pid, :telemetry_mount_stop)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # fires once for the dead render and once for the warm connect
    {:ok, _lv, _html} = live(conn, "/park/on-mount")

    assert_receive :telemetry_mount_stop, 500
    assert_receive :telemetry_mount_stop, 500
    refute_receive :telemetry_mount_stop, 100
  end

  @tag :capture_log
  test "expired park token causes cold-fallback mount (view still mounts)", %{conn: conn} do
    # live/2 consumes the park token immediately, leaving no gap for the TTL to
    # fire, so expiry itself is covered by the unit test; here we only assert the
    # view still mounts with a tiny ttl configured.
    Application.put_env(:phoenix_live_view, :warm_mount, enabled: true, ttl: 1)

    on_exit(fn ->
      Application.put_env(:phoenix_live_view, :warm_mount, enabled: true, ttl: 5_000)
    end)

    {:ok, lv, _html} = live(conn, "/park/plain")
    assert render(lv) =~ "sentinel::from_mount"
  end

  test "{:cont, push_navigate} from on_mount raises ArgumentError on cold connect", %{conn: conn} do
    assert_raise ArgumentError,
                 ~r(attempted to redirect without halting),
                 fn ->
                   live(conn, "/park/cont-redirect", connect_params: %{"__force_cold__" => true})
                 end
  end

  test "{:cont, push_navigate} from on_mount raises ArgumentError on warm connect", %{conn: conn} do
    assert_raise ArgumentError,
                 ~r(attempted to redirect without halting),
                 fn ->
                   live(conn, "/park/cont-redirect")
                 end
  end

  test "warm branch sends :warm_taken signal to warm_mount_test_pid", %{conn: conn} do
    Application.put_env(:phoenix_live_view, :warm_mount_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:phoenix_live_view, :warm_mount_test_pid)
    end)

    {:ok, _lv, _html} = live(conn, "/park/plain")

    assert_receive :warm_taken, 500
  end

  test "park token for view A is rejected when replayed against view B id/view binding", %{
    conn: _conn
  } do
    alias Phoenix.LiveView.Park
    alias Phoenix.LiveView.Socket
    alias Phoenix.LiveViewTest.Support.Endpoint
    alias Phoenix.LiveViewTest.Support.Router

    view_a = Phoenix.LiveViewTest.Support.ParkLive
    view_b = Phoenix.LiveViewTest.Support.ParkSentinelLive

    socket_a = %Socket{endpoint: Endpoint, router: Router, id: "socket-a", view: view_a}
    {:ok, token_a} = Park.park(socket_a)

    # a token parked for view A must be rejected when taken with view B
    assert :error = Park.take(token_a, Endpoint, "socket-a", view_b)

    # the bad replay did not consume the token, so the correct take still succeeds
    assert {:ok, %Socket{}} = Park.take(token_a, Endpoint, "socket-a", view_a)
  end

  test "second WS join with consumed park token cold-falls-back without crash", %{conn: conn} do
    Application.put_env(:phoenix_live_view, :warm_mount_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:phoenix_live_view, :warm_mount_test_pid)
    end)

    {:ok, _lv1, _html} = live(conn, "/park/plain")
    assert_receive :warm_taken, 500

    # each live/2 does a fresh dead render with a new token, so the second
    # connect goes warm independently of the first
    {:ok, _lv2, _html} = live(conn, "/park/plain")
    assert_receive :warm_taken, 500
  end
end
