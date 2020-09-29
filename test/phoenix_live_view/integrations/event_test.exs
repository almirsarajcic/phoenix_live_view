defmodule Phoenix.LiveView.EventTest do
  use ExUnit.Case

  import Phoenix.ConnTest

  import Phoenix.LiveViewTest

  alias Phoenix.LiveView
  alias Phoenix.LiveViewTest.{Endpoint}

  @endpoint Endpoint

  setup_all do
    ExUnit.CaptureLog.capture_log(fn -> Endpoint.start_link() end)
    :ok
  end

  setup config do
    {:ok,
     conn: Plug.Test.init_test_session(Phoenix.ConnTest.build_conn(), config[:session] || %{})}
  end

  describe "push_event" do
    test "sends updates with general assigns diff", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/events")

      GenServer.call(
        view.pid,
        {:run,
         fn socket ->
           new_socket =
             socket
             |> LiveView.assign(count: 123)
             |> LiveView.push_event("my-event", %{one: 1})

           {:reply, :ok, new_socket}
         end}
      )

      assert_push_event(view, "my-event", %{one: 1})
      assert render(view) =~ "count: 123"
    end

    test "sends updates with no assigns diff", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/events")

      GenServer.call(
        view.pid,
        {:run,
         fn socket ->
           {:reply, :ok, LiveView.push_event(socket, "my-event", %{two: 2})}
         end}
      )

      assert_push_event(view, "my-event", %{two: 2})
      assert render(view) =~ "count: 0"
    end
  end

  describe "replies" do
    test "sends reply from handle_event with general assigns diff", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/events")

      assert render_hook(view, :reply, %{count: 456, reply: %{"val" => "my-reply"}}) =~
               "count: 456"

      assert_reply(view, %{"val" => "my-reply"})
    end

    test "sends reply from handle_event with no assigns diff", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/events")
      assert render_hook(view, :reply, %{reply: %{"val" => "nodiff"}}) =~ "count: 0"
      assert_reply(view, %{"val" => "nodiff"})
    end

    test "raises when trying to reply outside of handle_event", %{conn: conn} do
      Process.flag(:trap_exit, true)
      {:ok, view, _html} = live(conn, "/events")
      pid = view.pid
      Process.monitor(pid)

      assert ExUnit.CaptureLog.capture_log(fn ->
               send(
                 view.pid,
                 {:run,
                  fn socket ->
                    {:reply, :boom, socket}
                  end}
               )

               assert_receive {:DOWN, _ref, :process, ^pid, _reason}
             end) =~ "Got: {:reply, :boom"
    end
  end
end
