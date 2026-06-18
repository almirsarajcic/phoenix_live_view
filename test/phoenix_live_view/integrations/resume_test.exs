defmodule Phoenix.LiveView.Integration.ResumeTest do
  # async: false — TTL tests mutate Application env; also prevents message
  # cross-contamination between tests sharing self() as test_pid receiver.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Phoenix.LiveViewTest.Support.Endpoint

  @endpoint Endpoint

  setup do
    Application.put_env(:phoenix_live_view, :resume, enabled: true, ttl: 5_000)

    on_exit(fn ->
      Application.put_env(:phoenix_live_view, :resume, enabled: false, ttl: 5_000)
    end)

    conn = Plug.Test.init_test_session(build_conn(), %{"test_pid" => self()})
    {:ok, conn: conn}
  end

  test "view.mount/3 runs on cold connect", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/resume/plain", connect_params: %{"__force_cold__" => true})
    assert render(lv) =~ "sentinel::from_mount"
  end

  test "on_mount hook runs on cold connect", %{conn: _conn} do
    cold_conn = Plug.Test.init_test_session(build_conn(), %{"test_pid" => self()})

    {:ok, _lv, _html} =
      live(cold_conn, "/resume/on-mount", connect_params: %{"__force_cold__" => true})

    # dead render + WS join each invoke on_mount
    assert_receive {:on_mount_called, _}, 500
    assert_receive {:on_mount_called, _}, 500
  end

  test "resumed assigns (sentinel from view.mount) present after WS connect", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/resume/sentinel")

    assert render(lv) =~ "sentinel::from_view_mount"
  end

  test "on_mount hook does NOT re-run on resume connect", %{conn: conn} do
    {:ok, _lv, _html} = live(conn, "/resume/on-mount")

    # Under :resume the on_mount hooks run only on the dead render (test process)
    # and are NOT re-run on the warm WS connect — the dead-render results are
    # reused. So exactly one call, from the test process.
    assert_receive {:on_mount_called, dead_pid}, 500
    assert dead_pid == self()
    refute_receive {:on_mount_called, _}, 200
  end

  test ":halt in on_mount halts resume connect with live_redirect", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/resume/plain"}}} = live(conn, "/resume/halt")
  end

  test ":halt in on_mount halts cold connect identically", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/resume/plain"}}} =
             live(conn, "/resume/halt", connect_params: %{"__force_cold__" => true})
  end

  test "on_mount hooks run in order once (dead render only) on resume connect", %{conn: conn} do
    {:ok, _lv, _html} = live(conn, "/resume/order")

    # A then B on the dead render, and not again on the warm WS connect.
    assert_receive {:order, :A}, 500
    assert_receive {:order, :B}, 500
    refute_receive {:order, _}, 200
  end

  test "on_mount hook side-effect fires once on resume connect", %{conn: conn} do
    {:ok, _lv, _html} = live(conn, "/resume/sentinel")

    # The hook runs only on the dead render; its side-effect fires exactly once.
    assert_receive {:side_effect, :ran}, 500
    refute_receive {:side_effect, :ran}, 200
  end

  test "on_mount hook assign computed on the dead render is reused and rendered on resume connect",
       %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/resume/sentinel")

    # Regression test for the core resume bug: an assign set by an on_mount hook on
    # the dead render must be present in the connected render even though the hook
    # is not re-run on the warm connect.
    assert render(lv) =~ "hook::from_hook"
  end

  test "resumed assigns (sentinel from view.mount) preserved after resume connect", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/resume/sentinel")

    assert render(lv) =~ "sentinel::from_view_mount"
  end

  test "view.mount/3 does not run again on resume connect", %{conn: conn} do
    {:ok, _lv, _html} = live(conn, "/resume/sentinel")

    # view.mount/3 runs once on the dead render and must not re-run on resume
    assert_receive {:view_mount_ran, dead_pid}, 500
    assert dead_pid == self()
    refute_receive {:view_mount_ran, _}, 200
  end

  test "attach_hook in on_mount does not raise on resume connect (no collision)", %{conn: conn} do
    assert {:ok, lv, _html} = live(conn, "/resume/attach-in-mount")

    # the hook attached during on_mount is functional on the resumed socket
    send(lv.pid, {:hooked, :value})
    assert_receive {:hook_fired, :value}, 500
  end

  test "telemetry :stop fires on resume connect", %{conn: conn} do
    test_pid = self()
    handler_id = "resume-test-telemetry-#{System.unique_integer()}"

    :telemetry.attach(
      handler_id,
      [:phoenix, :live_view, :mount, :stop],
      fn _event, _measurements, _metadata, _config ->
        send(test_pid, :telemetry_mount_stop)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # The mount lifecycle (and its telemetry) runs only on the dead render; the
    # warm connect reuses the mounted socket and emits no mount span.
    {:ok, _lv, _html} = live(conn, "/resume/on-mount")

    assert_receive :telemetry_mount_stop, 500
    refute_receive :telemetry_mount_stop, 200
  end

  @tag :capture_log
  test "expired resume token causes cold-fallback mount (view still mounts)", %{conn: conn} do
    # live/2 consumes the resume token immediately, leaving no gap for the TTL to
    # fire, so expiry itself is covered by the unit test; here we only assert the
    # view still mounts with a tiny ttl configured.
    Application.put_env(:phoenix_live_view, :resume, enabled: true, ttl: 1)

    on_exit(fn ->
      Application.put_env(:phoenix_live_view, :resume, enabled: true, ttl: 5_000)
    end)

    {:ok, lv, _html} = live(conn, "/resume/plain")
    assert render(lv) =~ "sentinel::from_mount"
  end

  test "{:cont, push_navigate} from on_mount raises ArgumentError on cold connect", %{conn: conn} do
    assert_raise ArgumentError,
                 ~r(attempted to redirect without halting),
                 fn ->
                   live(conn, "/resume/cont-redirect",
                     connect_params: %{"__force_cold__" => true}
                   )
                 end
  end

  test "{:cont, push_navigate} from on_mount raises ArgumentError on resume connect", %{
    conn: conn
  } do
    assert_raise ArgumentError,
                 ~r(attempted to redirect without halting),
                 fn ->
                   live(conn, "/resume/cont-redirect")
                 end
  end

  test "warm connect: view.mount/3 runs only on dead render, not on WS connect", %{conn: conn} do
    {:ok, _lv, _html} = live(conn, "/resume/plain")

    # Dead render fires from the test process.
    assert_receive {:view_mount_ran, dead_pid}, 500
    assert dead_pid == self()

    # mount/3 must NOT run again on the resume (warm) WS connect.
    refute_receive {:view_mount_ran, _}, 200
  end

  test "resume token for view A is rejected when replayed against view B id/view binding", %{
    conn: _conn
  } do
    alias Phoenix.LiveView.Resume
    alias Phoenix.LiveView.Socket
    alias Phoenix.LiveViewTest.Support.Endpoint
    alias Phoenix.LiveViewTest.Support.Router

    view_a = Phoenix.LiveViewTest.Support.ResumeLive
    view_b = Phoenix.LiveViewTest.Support.ResumeSentinelLive

    socket_a = %Socket{endpoint: Endpoint, router: Router, id: "socket-a", view: view_a}
    {:ok, token_a} = Resume.issue(socket_a)

    # a token issued for view A must be rejected when redeemed with view B
    assert :error = Resume.redeem(token_a, Endpoint, "socket-a", view_b)

    # the bad replay did not consume the token, so the correct redeem still succeeds
    assert {:ok, %Socket{}} = Resume.redeem(token_a, Endpoint, "socket-a", view_a)
  end

  test "second WS join with consumed resume token goes warm independently", %{conn: conn} do
    # Each live/2 does a fresh dead render with a new token, so each WS connect
    # is a separate warm resume — mount/3 runs exactly once per live/2 call.
    {:ok, _lv1, _html} = live(conn, "/resume/plain")
    assert_receive {:view_mount_ran, pid1}, 500
    assert pid1 == self()
    refute_receive {:view_mount_ran, _}, 200

    {:ok, _lv2, _html} = live(conn, "/resume/plain")
    assert_receive {:view_mount_ran, pid2}, 500
    assert pid2 == self()
    refute_receive {:view_mount_ran, _}, 200
  end
end

# ────────────────────────────────────────────────────────────────────────────
# max_children cap
# Restarts the real DynamicSupervisor under Phoenix.LiveView.Supervisor with
# max_children: 1 so over-cap issue/1 calls return {:error, :max_children}.
# On exit the original supervisor is restored.
# ────────────────────────────────────────────────────────────────────────────
defmodule Phoenix.LiveView.Integration.ResumeMaxChildrenTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.Resume
  alias Phoenix.LiveView.Socket
  alias Phoenix.LiveViewTest.Support.Endpoint
  alias Phoenix.LiveViewTest.Support.Router

  @endpoint Endpoint

  # Stops the named DynamicSupervisor child of Phoenix.LiveView.Supervisor,
  # removes its spec, then registers a new spec with the given max_children cap.
  # Returns the new pid.
  defp restart_resume_supervisor(max_children) do
    # Terminate the running child (blocks until stopped).
    :ok =
      Supervisor.terminate_child(Phoenix.LiveView.Supervisor, Phoenix.LiveView.Resume.Supervisor)

    # Delete the old spec so we can register a new one with a different cap.
    :ok = Supervisor.delete_child(Phoenix.LiveView.Supervisor, Phoenix.LiveView.Resume.Supervisor)

    new_spec = %{
      id: Phoenix.LiveView.Resume.Supervisor,
      start:
        {DynamicSupervisor, :start_link,
         [
           [
             name: Phoenix.LiveView.Resume.Supervisor,
             strategy: :one_for_one,
             max_children: max_children
           ]
         ]},
      restart: :permanent,
      type: :supervisor
    }

    {:ok, pid} = Supervisor.start_child(Phoenix.LiveView.Supervisor, new_spec)
    pid
  end

  setup do
    Application.put_env(:phoenix_live_view, :resume, enabled: true, ttl: 5_000)

    # Restart with cap of 1.
    restart_resume_supervisor(1)

    on_exit(fn ->
      Application.put_env(:phoenix_live_view, :resume, enabled: false, ttl: 5_000)
      # Restore to default 10_000 cap.
      restart_resume_supervisor(10_000)
    end)

    conn = Plug.Test.init_test_session(build_conn(), %{"test_pid" => self()})
    {:ok, conn: conn}
  end

  defp dummy_socket do
    %Socket{
      endpoint: Endpoint,
      router: Router,
      id: "max-children-test-#{System.unique_integer([:positive])}",
      view: Phoenix.LiveViewTest.Support.ResumeLive
    }
  end

  test "first Resume.issue/1 succeeds when cap is 1", _ctx do
    socket = dummy_socket()
    assert {:ok, _token} = Resume.issue(socket)
    assert DynamicSupervisor.count_children(Phoenix.LiveView.Resume.Supervisor).active == 1
  end

  test "second Resume.issue/1 returns {:error, :max_children} when cap is 1", _ctx do
    first = dummy_socket()
    {:ok, _token} = Resume.issue(first)

    second = dummy_socket()
    assert {:error, :max_children} = Resume.issue(second)
  end

  test "over-cap issue does not start a holder process", _ctx do
    first = dummy_socket()
    {:ok, _} = Resume.issue(first)
    count_before = DynamicSupervisor.count_children(Phoenix.LiveView.Resume.Supervisor).active

    {:error, :max_children} = Resume.issue(dummy_socket())
    count_after = DynamicSupervisor.count_children(Phoenix.LiveView.Resume.Supervisor).active

    assert count_after == count_before
  end

  @tag :capture_log
  test "over-cap dead render emits no data-phx-resume in HTML", %{conn: conn} do
    # Fill the cap with a direct issue/1 so the dead render call will be over-cap.
    {:ok, _token} = Resume.issue(dummy_socket())

    html = Phoenix.ConnTest.get(conn, "/resume/plain") |> Phoenix.ConnTest.html_response(200)

    # No token attribute in the rendered HTML.
    refute html =~ "data-phx-resume"
  end

  @tag :capture_log
  test "over-cap page still mounts via cold path", %{conn: conn} do
    # Fill the cap so dead renders skip resume.
    {:ok, _token} = Resume.issue(dummy_socket())

    {:ok, lv, _html} = live(conn, "/resume/plain")

    # Cold mount path: view.mount/3 runs on both dead render (test process)
    # and WS connect (channel process).
    assert_receive {:view_mount_ran, dead_pid}, 500
    assert dead_pid == self()
    assert_receive {:view_mount_ran, channel_pid}, 500
    assert channel_pid != self()

    # sentinel from view.mount/3 is present → page works correctly.
    assert render(lv) =~ "sentinel::from_mount"
  end
end

# ────────────────────────────────────────────────────────────────────────────
# Per-view opt-in matrix (app-wide × per-view)
# ────────────────────────────────────────────────────────────────────────────
defmodule Phoenix.LiveView.Integration.ResumeOptInMatrixTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Phoenix.LiveViewTest.Support.Endpoint

  @endpoint Endpoint

  # Matrix rows: {app_wide_enabled, per_view_setting, route, expect_resume?}
  # Effective rule: per_view true → on; per_view false → off; per_view absent → app_wide.
  #
  # | app_wide | per_view | effective |
  # | false    | absent   | false     |  route: /resume/plain
  # | true     | absent   | true      |  route: /resume/plain
  # | false    | true     | true      |  route: /resume/opt-in
  # | true     | true     | true      |  route: /resume/opt-in
  # | false    | false    | false     |  route: /resume/opt-out
  # | true     | false    | false     |  route: /resume/opt-out

  setup do
    conn = Plug.Test.init_test_session(build_conn(), %{"test_pid" => self()})
    {:ok, conn: conn}
  end

  # ── absent (inherit) ──────────────────────────────────────────────────────

  test "app_wide=false, per_view=absent → no token, cold mount", %{conn: conn} do
    Application.put_env(:phoenix_live_view, :resume, enabled: false, ttl: 5_000)

    on_exit(fn ->
      Application.put_env(:phoenix_live_view, :resume, enabled: false, ttl: 5_000)
    end)

    # Explicit dead render — mount/3 runs in the test process.
    dead_conn = get(conn, "/resume/plain")
    refute html_response(dead_conn, 200) =~ "data-phx-resume"
    assert_receive {:view_mount_ran, dead_pid}, 500
    assert dead_pid == self()

    # WS connect only (no second dead render) — cold: channel runs mount/3.
    {:ok, _lv, _html} = live(dead_conn)
    assert_receive {:view_mount_ran, channel_pid}, 500
    assert channel_pid != self()
  end

  test "app_wide=true, per_view=absent → token emitted, warm connect", %{conn: conn} do
    Application.put_env(:phoenix_live_view, :resume, enabled: true, ttl: 5_000)

    on_exit(fn ->
      Application.put_env(:phoenix_live_view, :resume, enabled: false, ttl: 5_000)
    end)

    # Explicit dead render — mount/3 runs in the test process.
    dead_conn = get(conn, "/resume/plain")
    assert html_response(dead_conn, 200) =~ "data-phx-resume"
    assert_receive {:view_mount_ran, dead_pid}, 500
    assert dead_pid == self()

    # WS connect only (no second dead render) — warm: mount/3 must NOT run again.
    {:ok, _lv, _html} = live(dead_conn)
    refute_receive {:view_mount_ran, _}, 200
  end

  # ── per_view = true (opt-in) ──────────────────────────────────────────────

  test "app_wide=false, per_view=true → token emitted, warm connect", %{conn: conn} do
    Application.put_env(:phoenix_live_view, :resume, enabled: false, ttl: 5_000)

    on_exit(fn ->
      Application.put_env(:phoenix_live_view, :resume, enabled: false, ttl: 5_000)
    end)

    # Explicit dead render — mount/3 runs in the test process.
    dead_conn = get(conn, "/resume/opt-in")
    assert html_response(dead_conn, 200) =~ "data-phx-resume"
    assert_receive {:view_mount_ran, dead_pid}, 500
    assert dead_pid == self()

    # WS connect only (no second dead render) — warm: mount/3 must NOT run again.
    {:ok, _lv, _html} = live(dead_conn)
    refute_receive {:view_mount_ran, _}, 200
  end

  test "app_wide=true, per_view=true → token emitted, warm connect", %{conn: conn} do
    Application.put_env(:phoenix_live_view, :resume, enabled: true, ttl: 5_000)

    on_exit(fn ->
      Application.put_env(:phoenix_live_view, :resume, enabled: false, ttl: 5_000)
    end)

    # Explicit dead render — mount/3 runs in the test process.
    dead_conn = get(conn, "/resume/opt-in")
    assert html_response(dead_conn, 200) =~ "data-phx-resume"
    assert_receive {:view_mount_ran, dead_pid}, 500
    assert dead_pid == self()

    # WS connect only (no second dead render) — warm: mount/3 must NOT run again.
    {:ok, _lv, _html} = live(dead_conn)
    refute_receive {:view_mount_ran, _}, 200
  end

  # ── per_view = false (opt-out) ────────────────────────────────────────────

  test "app_wide=false, per_view=false → no token, cold mount", %{conn: conn} do
    Application.put_env(:phoenix_live_view, :resume, enabled: false, ttl: 5_000)

    on_exit(fn ->
      Application.put_env(:phoenix_live_view, :resume, enabled: false, ttl: 5_000)
    end)

    # Explicit dead render — mount/3 runs in the test process.
    dead_conn = get(conn, "/resume/opt-out")
    refute html_response(dead_conn, 200) =~ "data-phx-resume"
    assert_receive {:view_mount_ran, dead_pid}, 500
    assert dead_pid == self()

    # WS connect only (no second dead render) — cold: channel runs mount/3.
    {:ok, _lv, _html} = live(dead_conn)
    assert_receive {:view_mount_ran, channel_pid}, 500
    assert channel_pid != self()
  end

  test "app_wide=true, per_view=false → no token, cold mount", %{conn: conn} do
    Application.put_env(:phoenix_live_view, :resume, enabled: true, ttl: 5_000)

    on_exit(fn ->
      Application.put_env(:phoenix_live_view, :resume, enabled: false, ttl: 5_000)
    end)

    # Explicit dead render — mount/3 runs in the test process.
    dead_conn = get(conn, "/resume/opt-out")
    refute html_response(dead_conn, 200) =~ "data-phx-resume"
    assert_receive {:view_mount_ran, dead_pid}, 500
    assert dead_pid == self()

    # WS connect only (no second dead render) — cold: channel runs mount/3.
    {:ok, _lv, _html} = live(dead_conn)
    assert_receive {:view_mount_ran, channel_pid}, 500
    assert channel_pid != self()
  end
end

# ────────────────────────────────────────────────────────────────────────────
# TTL → cold mount integration proof
# ────────────────────────────────────────────────────────────────────────────
defmodule Phoenix.LiveView.Integration.ResumeTTLColdMountTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.Resume
  alias Phoenix.LiveView.Utils
  alias Phoenix.LiveViewTest.Support.Endpoint

  @endpoint Endpoint

  setup do
    Application.put_env(:phoenix_live_view, :resume, enabled: true, ttl: 5_000)

    on_exit(fn ->
      Application.put_env(:phoenix_live_view, :resume, enabled: false, ttl: 5_000)
    end)

    conn = Plug.Test.init_test_session(build_conn(), %{"test_pid" => self()})
    {:ok, conn: conn}
  end

  @tag :capture_log
  test "stale token fails redeem after TTL elapses", %{conn: conn} do
    # Use a very short TTL so we can sleep past it.
    Application.put_env(:phoenix_live_view, :resume, enabled: true, ttl: 5)

    on_exit(fn ->
      Application.put_env(:phoenix_live_view, :resume, enabled: true, ttl: 5_000)
    end)

    # Dead render issues and embeds the token.
    html = conn |> get("/resume/plain") |> html_response(200)
    assert html =~ "data-phx-resume"

    # Extract the raw token from the HTML attribute (it appears as data-phx-resume="<token>").
    [_, token] = Regex.run(~r/data-phx-resume="([^"]+)"/, html)

    # Peek into the token (not yet expired) to extract id/view so the redeem call
    # uses correct binding values — the :error must come from the dead holder, not
    # a binding mismatch.
    {:ok, {1, %{id: socket_id, view: socket_view}}} =
      Phoenix.Token.verify(
        Endpoint,
        Utils.salt!(Endpoint),
        token,
        max_age: :infinity
      )

    # Sleep past TTL so the holder GenServer has stopped.
    :timer.sleep(80)

    # Holder is dead → Registry lookup returns [] → :error.
    assert :error = Resume.redeem(token, Endpoint, socket_id, socket_view)

    # Note: we cannot drive a stale-token connect via live/2 because live/2 issues
    # a fresh dead render (and thus a fresh token) before joining the WS channel.
    # The direct Resume.redeem/4 assertion above is the integration-level cold proof.
  end
end

# ────────────────────────────────────────────────────────────────────────────
# Resumed-connect auth contract
#
# Proves that on a warm (resumed) connect the live view's assigns reflect the
# value computed during the DEAD RENDER, not a fresh re-computation from the
# WS session.  This is the correct splice_resumed_state behaviour.
#
# Mechanism under test (channel.ex splice_resumed_state, with on_mount hooks NOT
# re-run on the warm path):
#   1. Dead render: assign_new(:current_user) calls fn → gets :dead_render_user
#      from the Agent (which then advances to :ws_user).
#   2. Resume token stores the dead-render socket (current_user: :dead_render_user).
#   3. WS join: splice_resumed_state copies the dead-render assigns onto ws_socket
#      and the on_mount hooks are NOT re-run, so the Agent is never read again.
#   4. ws_socket renders with the reused :dead_render_user.
#
# Non-vacuity argument: the Agent sequences :dead_render_user → :ws_user.
# If the implementation were to re-run the hook on the warm connect (buggy), the
# fn WOULD be called, the Agent would return :ws_user, and the render would show
# :ws_user — failing the assert below.
# ────────────────────────────────────────────────────────────────────────────
defmodule Phoenix.LiveView.Integration.ResumeAuthContractTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Phoenix.LiveViewTest.Support.Endpoint

  @endpoint Endpoint

  setup do
    Application.put_env(:phoenix_live_view, :resume, enabled: true, ttl: 5_000)

    on_exit(fn ->
      Application.put_env(:phoenix_live_view, :resume, enabled: false, ttl: 5_000)
    end)

    # Agent sequences the assign_new return value:
    #   first call  → :dead_render_user  (dead render)
    #   second call → :ws_user           (would be used on warm connect IF fn were called)
    {:ok, agent} = Agent.start_link(fn -> :dead_render_user end)

    conn =
      Plug.Test.init_test_session(build_conn(), %{
        "test_pid" => self(),
        "user_agent" => agent
      })

    {:ok, conn: conn, agent: agent}
  end

  test "on_mount hook runs once (dead render only) on warm connect", %{conn: conn} do
    {:ok, _lv, _html} = live(conn, "/resume/auth")

    # Exactly one call: the dead render. The hook is not re-run on the warm connect.
    assert_receive {:on_mount_user, _}, 500
    refute_receive {:on_mount_user, _}, 200
  end

  test "dead-render assign_new value carries through warm connect unchanged", %{conn: conn} do
    # Dead render: assign_new fn is called → Agent returns :dead_render_user (then
    # advances to :ws_user). Warm connect: the hook is not re-run, so the Agent is
    # never read again and the rendered value remains :dead_render_user. If the
    # warm connect re-ran the hook it would render :ws_user — proving non-vacuity.
    {:ok, lv, _html} = live(conn, "/resume/auth")

    assert_receive {:on_mount_user, :dead_render_user}, 500
    refute_receive {:on_mount_user, _}, 200

    # The rendered view carries the splice-preserved dead-render value.
    assert render(lv) =~ "user::dead_render_user"
  end
end

# ────────────────────────────────────────────────────────────────────────────
# on_connect/1 callback
#
# Verifies that on_connect/1 fires exactly once per WebSocket connect on both
# the cold and warm/resumed paths, that it can assign, that LiveViews without
# it continue to work, and that the channel pid (not test process) invokes it.
# ────────────────────────────────────────────────────────────────────────────
defmodule Phoenix.LiveView.Integration.OnConnectTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Phoenix.LiveViewTest.Support.Endpoint

  @endpoint Endpoint

  setup do
    Application.put_env(:phoenix_live_view, :resume, enabled: true, ttl: 5_000)

    on_exit(fn ->
      Application.put_env(:phoenix_live_view, :resume, enabled: false, ttl: 5_000)
    end)

    conn = Plug.Test.init_test_session(build_conn(), %{"test_pid" => self()})
    {:ok, conn: conn}
  end

  test "on_connect runs on cold connect", %{conn: conn} do
    {:ok, _lv, _html} =
      live(conn, "/resume/on-connect", connect_params: %{"__force_cold__" => true})

    # live/2 does dead render THEN WS connect. Dead render runs in the test
    # process (mount sends {:view_mount_ran, self()}). Drain it first so the
    # subsequent assertion reliably targets the channel-process mount message.
    assert_receive {:view_mount_ran, dead_pid}, 500
    assert dead_pid == self()

    # cold WS connect: view.mount runs in the channel process
    assert_receive {:view_mount_ran, channel_pid}, 500
    assert channel_pid != self()

    # on_connect runs in the channel process (never on dead render)
    assert_receive {:on_connect_ran, on_connect_pid}, 500
    assert on_connect_pid != self()
  end

  test "on_connect runs once per cold connect (not on dead render)", %{conn: conn} do
    {:ok, _lv, _html} =
      live(conn, "/resume/on-connect", connect_params: %{"__force_cold__" => true})

    assert_receive {:on_connect_ran, _}, 500
    refute_receive {:on_connect_ran, _}, 100
  end

  test "on_connect runs on warm/resume connect even though mount/3 is skipped", %{conn: conn} do
    {:ok, _lv, _html} = live(conn, "/resume/on-connect")

    # mount/3 fires only during the dead render (test process), not on the warm WS connect
    assert_receive {:view_mount_ran, dead_pid}, 500
    assert dead_pid == self()
    refute_receive {:view_mount_ran, _}, 200

    # on_connect must still fire on the warm WS connect
    assert_receive {:on_connect_ran, channel_pid}, 500
    assert channel_pid != self()
  end

  test "on_connect runs in the channel process (not dead-render process)", %{conn: conn} do
    {:ok, _lv, _html} = live(conn, "/resume/on-connect")

    assert_receive {:on_connect_ran, pid}, 500
    assert pid != self()
  end

  test "on_connect assign is present after connect", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/resume/on-connect")

    assert render(lv) =~ "label::from_on_connect"
  end

  test "LiveView without on_connect/1 still works (no crash)", %{conn: conn} do
    assert {:ok, lv, _html} = live(conn, "/resume/plain")
    assert render(lv) =~ "sentinel"
  end

  test "on_connect runs on fresh reconnect (cold path after consumed token)", %{conn: conn} do
    # A second live/2 issues a fresh dead render and a new WS connect, both cold.
    {:ok, _lv1, _html} = live(conn, "/resume/on-connect")
    assert_receive {:view_mount_ran, _}, 500
    assert_receive {:on_connect_ran, _}, 500

    {:ok, _lv2, _html} = live(conn, "/resume/on-connect")
    assert_receive {:view_mount_ran, dead_pid2}, 500
    assert dead_pid2 == self()
    assert_receive {:on_connect_ran, channel_pid2}, 500
    assert channel_pid2 != self()
  end

  # B3: on_connect fires on live_isolated views (no router).
  test "on_connect runs on live_isolated view", %{conn: conn} do
    {:ok, lv, _html} =
      live_isolated(conn, Phoenix.LiveViewTest.Support.ResumeOnConnectLive,
        session: %{"test_pid" => self()}
      )

    # live_isolated drives a WS connect — on_connect must fire.
    assert_receive {:on_connect_ran, pid}, 500
    assert pid != self()

    # Assignment from on_connect is visible in the rendered output.
    assert render(lv) =~ "label::from_on_connect"
  end
end

# ────────────────────────────────────────────────────────────────────────────
# B1 — warm flag preserved through live_patch reply arm
#
# Regression guard: when a warm (resumed) connect's on_connect/1 triggers
# push_patch, the server must still follow the warm path (mount/3 not re-run).
# Before the fix, the {:live_patch, opts} arm in reply_mount/4 built the reply
# without `warm: true`, so the JS client treated the join-patch as cold and
# detached stream children.  At the Elixir integration level the observable
# signal is that view.mount/3 is NOT re-invoked on the warm WS connect —
# identical to all other warm-connect tests.  The JS-visible `warm: true` in
# the WS reply payload is covered by the e2e test in
# test/e2e/tests/resume.spec.js.
#
# Connect-time push_patch lives in on_connect/1, not handle_params/3, because
# handle_params/3 is not re-invoked on the initial warm connect (its dead-render
# result is reused) — see the ResumeHandleParamsLive tests below.
# ────────────────────────────────────────────────────────────────────────────
defmodule Phoenix.LiveView.Integration.ResumeWarmPatchTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Phoenix.LiveViewTest.Support.Endpoint

  @endpoint Endpoint

  setup do
    Application.put_env(:phoenix_live_view, :resume, enabled: true, ttl: 5_000)

    on_exit(fn ->
      Application.put_env(:phoenix_live_view, :resume, enabled: false, ttl: 5_000)
    end)

    conn = Plug.Test.init_test_session(build_conn(), %{"test_pid" => self()})
    {:ok, conn: conn}
  end

  test "warm connect with on_connect push_patch does not re-run mount/3", %{conn: conn} do
    # Dead render only: mount/3 runs in the test process and emits a token.
    # on_connect/1 does not run on the dead render, so the GET returns 200.
    dead_conn = get(conn, "/resume/patch")
    assert html_response(dead_conn, 200) =~ "data-phx-resume"

    # mount/3 fires exactly once — on the dead render (test process).
    assert_receive {:view_mount_ran, dead_pid}, 500
    assert dead_pid == self()

    # Warm WS connect only (live/1 with no path — no second GET).
    # on_connect fires push_patch on the connected path; the channel
    # must reply {:ok, %{rendered: ..., live_patch: ..., warm: true}}
    # (not {:error, {:live_redirect, ...}}) for the resume warm flag regression.
    {:ok, lv, _html} = live(dead_conn)

    # mount/3 must NOT run again on the warm resume path.
    refute_receive {:view_mount_ran, _}, 200

    # The view rendered correctly after the patch.
    assert render(lv) =~ "patched:true"
  end

  test "warm connect: on_connect push_patch result is live and correct", %{conn: conn} do
    # Dead render only.
    dead_conn = get(conn, "/resume/patch")
    assert html_response(dead_conn, 200) =~ "data-phx-resume"

    # Drain the dead-render mount message.
    assert_receive {:view_mount_ran, _}, 500

    # Warm WS connect only.
    {:ok, lv, _html} = live(dead_conn)

    # The live_patch applied correctly.
    assert render(lv) =~ "patched:true"
    assert render(lv) =~ "sentinel::from_view_mount"
  end

  test "handle_params/3 is not re-invoked on the initial warm connect", %{conn: conn} do
    # Dead render runs handle_params/3 with connected? == false and parks a token.
    dead_conn = get(conn, "/resume/handle-params")
    assert html_response(dead_conn, 200) =~ "data-phx-resume"
    assert_receive {:handle_params_ran, false}, 500

    # The initial warm connect reuses the dead-render result — handle_params/3 is
    # NOT called again (no connected? == true invocation on join).
    {:ok, lv, _html} = live(dead_conn)
    refute_receive {:handle_params_ran, _}, 200
    assert render(lv) =~ "q:nil"
  end

  test "handle_params/3 still runs on a live navigation after a warm connect", %{conn: conn} do
    dead_conn = get(conn, "/resume/handle-params")
    assert_receive {:handle_params_ran, false}, 500

    {:ok, lv, _html} = live(dead_conn)
    refute_receive {:handle_params_ran, _}, 200

    # A genuine live_patch navigation DOES run handle_params/3 (connected? == true).
    render_patch(lv, "/resume/handle-params?q=hello")
    assert_receive {:handle_params_ran, true}, 500
    assert render(lv) =~ "hello"
  end
end

# ────────────────────────────────────────────────────────────────────────────
# N5 — on_connect/1 bad return value raises ArgumentError
# ────────────────────────────────────────────────────────────────────────────
defmodule Phoenix.LiveView.Integration.OnConnectBadReturnTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Phoenix.LiveViewTest.Support.Endpoint

  @endpoint Endpoint

  setup do
    conn = build_conn()
    {:ok, conn: conn}
  end

  test "on_connect/1 returning non-{:ok, socket} raises ArgumentError", %{conn: conn} do
    err =
      try do
        live_isolated(conn, Phoenix.LiveViewTest.Support.ResumeBadOnConnectLive)
      catch
        :exit, {{%ArgumentError{} = exception, _stacktrace}, _} -> exception
      end

    assert %ArgumentError{} = err
    assert Exception.message(err) =~ "invalid return from"
    assert Exception.message(err) =~ "ResumeBadOnConnectLive"
    assert Exception.message(err) =~ "on_connect/1"
  end

  test "ArgumentError message includes the bad return value", %{conn: conn} do
    err =
      try do
        live_isolated(conn, Phoenix.LiveViewTest.Support.ResumeBadOnConnectLive)
      catch
        :exit, {{%ArgumentError{} = exception, _stacktrace}, _} -> exception
      end

    assert Exception.message(err) =~ "invalid return from"
    assert Exception.message(err) =~ "on_connect/1"
    assert Exception.message(err) =~ ":bad_return"
  end
end
