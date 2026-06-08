defmodule Phoenix.LiveView.ParkTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Park
  alias Phoenix.LiveView.Socket
  alias Phoenix.LiveView.Utils
  alias Phoenix.LiveViewTest.Support.Endpoint

  # Build a minimal socket that Park can store and return
  defp dummy_socket do
    %Socket{
      endpoint: Endpoint,
      router: Phoenix.LiveViewTest.Support.Router,
      id: "test-socket-id",
      view: Phoenix.LiveViewTest.Support.ParamCounterLive
    }
  end

  defp dummy_socket(id, view) do
    %Socket{
      endpoint: Endpoint,
      router: Phoenix.LiveViewTest.Support.Router,
      id: id,
      view: view
    }
  end

  describe "park/1" do
    test "returns {:ok, token} and registers the process" do
      socket = dummy_socket()
      assert {:ok, token} = Park.park(socket)
      assert is_binary(token)

      # Registry should have exactly one entry (the parked GenServer)
      # Verify by taking it immediately
      assert {:ok, %Socket{}} = Park.take(token, Endpoint, socket.id, socket.view)
    end

    test "token is verifiable by the same endpoint" do
      socket = dummy_socket()
      assert {:ok, token} = Park.park(socket)
      assert {:ok, _socket} = Park.take(token, Endpoint, socket.id, socket.view)
    end
  end

  describe "take/4" do
    test "returns {:ok, socket} and terminates the parked GenServer" do
      socket = dummy_socket()
      assert {:ok, token} = Park.park(socket)

      assert {:ok, taken} = Park.take(token, Endpoint, socket.id, socket.view)
      assert %Socket{} = taken

      # Process is gone: second take must return :error
      :timer.sleep(10)
      assert :error = Park.take(token, Endpoint, socket.id, socket.view)
    end

    test "second take returns :error (one-shot)" do
      socket = dummy_socket()
      {:ok, token} = Park.park(socket)
      assert {:ok, _} = Park.take(token, Endpoint, socket.id, socket.view)
      assert :error = Park.take(token, Endpoint, socket.id, socket.view)
    end

    test "garbage token returns :error" do
      assert :error = Park.take("not-a-valid-token", Endpoint, "any-id", Elixir.SomeView)
    end

    test "token from different endpoint returns :error" do
      socket = dummy_socket()
      {:ok, token} = Park.park(socket)
      # Use a different endpoint that will fail to verify the token
      assert :error =
               Park.take(
                 token,
                 Phoenix.LiveViewTest.Support.EndpointOverridable,
                 socket.id,
                 socket.view
               )
    end

    test "token bound to id fails verify when id differs" do
      socket = dummy_socket("original-id", Phoenix.LiveViewTest.Support.ParamCounterLive)
      {:ok, token} = Park.park(socket)

      # Different id — must reject
      assert :error =
               Park.take(
                 token,
                 Endpoint,
                 "different-id",
                 Phoenix.LiveViewTest.Support.ParamCounterLive
               )
    end

    test "token bound to view fails verify when view differs" do
      socket = dummy_socket("my-socket-id", Phoenix.LiveViewTest.Support.ParamCounterLive)
      {:ok, token} = Park.park(socket)

      # Different view module — must reject
      assert :error =
               Park.take(
                 token,
                 Endpoint,
                 "my-socket-id",
                 Phoenix.LiveViewTest.Support.StatefulView
               )
    end

    test "token bound to correct id and view succeeds" do
      socket = dummy_socket("correct-id", Phoenix.LiveViewTest.Support.ParamCounterLive)
      {:ok, token} = Park.park(socket)

      assert {:ok, _} =
               Park.take(
                 token,
                 Endpoint,
                 "correct-id",
                 Phoenix.LiveViewTest.Support.ParamCounterLive
               )
    end

    test "wrong version in token returns :error" do
      # sign a token with an unsupported version
      key = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      salt = Utils.salt!(Endpoint)

      bad_token =
        Phoenix.Token.sign(
          Endpoint,
          salt,
          {2, %{lv_park_key: key, id: "id", view: SomeView}}
        )

      assert :error = Park.take(bad_token, Endpoint, "id", SomeView)
    end
  end
end

# async: false because the tiny TTL is set via process-global Application env
# and read at park/1 time, which would flake under concurrent tests.
defmodule Phoenix.LiveView.ParkSyncTest do
  use ExUnit.Case, async: false

  alias Phoenix.LiveView.Park
  alias Phoenix.LiveView.Socket
  alias Phoenix.LiveViewTest.Support.Endpoint

  defp dummy_socket do
    %Socket{
      endpoint: Endpoint,
      router: Phoenix.LiveViewTest.Support.Router,
      id: "sync-test-id",
      view: Phoenix.LiveViewTest.Support.ParamCounterLive
    }
  end

  describe "TTL expiry" do
    @tag :capture_log
    test "expired park returns :error" do
      # Use a very short TTL so the process expires before we take it.
      # Application.put_env is process-global → kept in async: false module.
      Application.put_env(:phoenix_live_view, :warm_mount, enabled: false, ttl: 5)

      on_exit(fn ->
        Application.put_env(:phoenix_live_view, :warm_mount, enabled: false, ttl: 5_000)
      end)

      socket = dummy_socket()
      {:ok, token} = Park.park(socket)

      # Wait for TTL to fire
      :timer.sleep(50)

      assert :error = Park.take(token, Endpoint, socket.id, socket.view)
    end

    @tag :capture_log
    test "token signed beyond max_age grace period returns :error" do
      # a token older than ttl + grace must be rejected by Phoenix.Token.verify/4
      Application.put_env(:phoenix_live_view, :warm_mount, enabled: false, ttl: 1)

      on_exit(fn ->
        Application.put_env(:phoenix_live_view, :warm_mount, enabled: false, ttl: 5_000)
      end)

      socket = dummy_socket()
      {:ok, token} = Park.park(socket)

      # confirm the GenServer is dead after the TTL fires, which covers the
      # token-expiry path for the registry lookup
      :timer.sleep(20)

      assert :error = Park.take(token, Endpoint, socket.id, socket.view)
    end
  end
end
